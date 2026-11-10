// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx.sv
// Purpose: capture core of the OV5640 GigE camera design, Phase 1 part (documentation/gige.md sections 5.1, 5.4): the
//   register block, the 75 percent color-bar generator and the source switch, with one YUV422 video stream out. The
//   camera front end (D-PHY capture, CSI-2 decode, SCCB) is Phase 3; its post-FIFO camera stream joins through the
//   s_cam_* port, which the board ties off (valid 0) until then.
// Overview:
//   * Output stream m_axis_*: 32-bit words of two YUV422 pixels in memory byte order {Cr, Y1, Cb, Y0}, tuser = first
//     word of a frame, tlast = last word of a line. With the stream, registered and stable from the clock the first word
//     of a frame is presented until the next frame's first word: m_frame_num (FRAME_COUNT after this frame started),
//     m_timestamp (free-running clk count at the frame start), m_width, m_height (pixels, of the mode in effect for
//     the frame) and m_src_pattern (1 pattern, 0 camera). One registered output stage holds the word.
//   * Frame timing: a free-running frame timer ticks every FRAME_PERIOD clocks (the value latched at the previous tick, so
//     a change takes effect at the next frame). On a tick with the pattern selected and no frame in progress the generator
//     starts one frame in the mode of VIDEO_MODE at that tick; a tick that finds a frame still running counts as an
//     overrun (STATUS.OVERRUN) and starts nothing. The reset value 3,000,000 gives 30.000 frames per second at the 90 MHz ui_clk.
//   * Source switch (SOURCE): in auto the camera is used when the camera byte clock runs (cam_clk_running) and a camera
//     frame start arrived within CAM_TIMEOUT frame periods; otherwise the pattern. The selection changes only between
//     frames. A camera frame that is in progress when the camera is no longer selected (cut off) is abandoned: its
//     output is closed at once, the pattern frame that follows starts a new frame, and the downstream DMA never
//     publishes the short frame. A camera word that is not part of a frame that began with a start-of-frame word is
//     discarded. While the pattern is selected the camera stream is accepted and discarded.
//   * Registers on s_axi_aclk behind rtlnet_axil_cdc and rtlnet_axil_slave (4 KiB window); rtlnet_csi2_rx_regs holds the
//     register file, offsets in driver/rtlnet_csi2_rx.h.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version (Phase 1: registers, color bars, source switch).
// Clocks: clk (generator, switch, registers, video stream; the memory-controller user clock); s_axi_aclk (AXI4-Lite slave
//   side of the register crossing only).
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx #(
  parameter bit    AXIL_SYNC = 1'b0,   // 1: s_axi_aclk is clk (register window without a clock crossing)
  parameter int PERIOD_RESET      = 3_000_000,   // clocks per frame at reset: 30.000 fps at 90 MHz
  parameter int PERIOD_MIN_720    = 3_000_000,   // 750 lines * LINE_PERIOD_720
  parameter int PERIOD_MIN_1080   = 2_999_250,   // 1125 lines * LINE_PERIOD_1080
  parameter int LINE_PERIOD_720   = 4000,        // clocks per line at 720p30
  parameter int LINE_PERIOD_1080  = 2666,        // clocks per line at 1080p30
  parameter int CAM_TIMEOUT_RESET = 2            // frame periods
)(
  // Core clock and its reset (synchronous, active low); the AXI4-Lite clock and its reset (released from the same
  // assertion).
  input  logic        clk,
  input  logic        resetn,
  input  logic        s_axi_aclk,
  input  logic        s_axi_aresetn,

  // Camera stream, clk domain (Phase 3: after the byte-clock CDC FIFO). Tied off (valid 0) in Phase 1.
  input  logic [31:0] s_cam_tdata,
  input  logic        s_cam_tvalid,
  output logic        s_cam_tready,
  input  logic        s_cam_tlast,
  input  logic        s_cam_tuser,
  input  logic        cam_clk_running,           // camera byte clock detected, already synchronized to clk

  // Video stream out, clk domain, with the frame sideband (see above).
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  output logic        m_axis_tuser,
  output logic [31:0] m_frame_num,
  output logic [31:0] m_timestamp,
  output logic [15:0] m_width,
  output logic [15:0] m_height,
  output logic        m_src_pattern,

  // AXI4-Lite register slave, s_axi_aclk domain, 12-bit byte address, 32-bit data.
  input  logic [11:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [11:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready
);

  localparam int          NUM_MODES    = 2;
  localparam int          PIX_720_W    = 1280;
  localparam int          PIX_720_H    = 720;
  localparam int          PIX_1080_W   = 1920;
  localparam int          PIX_1080_H   = 1080;
  localparam logic [1:0]  MODE_1080P30 = 2'd1;
  localparam logic [1:0]  SRC_CAMERA   = 2'd1;
  localparam logic [1:0]  SRC_PATTERN  = 2'd2;

  // ---------------------------------------------------------------------------
  // Register access
  // ---------------------------------------------------------------------------
  logic [11:0] c_awaddr;
  logic        c_awvalid;
  logic        c_awready;
  logic [31:0] c_wdata;
  logic [3:0]  c_wstrb;
  logic        c_wvalid;
  logic        c_wready;
  logic [1:0]  c_bresp;
  logic        c_bvalid;
  logic        c_bready;
  logic [11:0] c_araddr;
  logic        c_arvalid;
  logic        c_arready;
  logic [31:0] c_rdata;
  logic [1:0]  c_rresp;
  logic        c_rvalid;
  logic        c_rready;
  logic        reg_wr_en;
  logic [11:0] reg_wr_addr;
  logic [31:0] reg_wr_data;
  logic        reg_rd_en;
  logic [11:0] reg_rd_addr;
  logic [31:0] reg_rd_data;

  // Register clock -> clk crossing of whole AXI4-Lite transactions.
  rtlnet_axil_cdc #(.ADDR_W(12), .SYNC(AXIL_SYNC)) u_axil_cdc (
    .s_clk         (s_axi_aclk),
    .s_resetn      (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .m_clk         (clk),
    .m_resetn      (resetn),
    .m_axi_awaddr  (c_awaddr),
    .m_axi_awvalid (c_awvalid),
    .m_axi_awready (c_awready),
    .m_axi_wdata   (c_wdata),
    .m_axi_wstrb   (c_wstrb),
    .m_axi_wvalid  (c_wvalid),
    .m_axi_wready  (c_wready),
    .m_axi_bresp   (c_bresp),
    .m_axi_bvalid  (c_bvalid),
    .m_axi_bready  (c_bready),
    .m_axi_araddr  (c_araddr),
    .m_axi_arvalid (c_arvalid),
    .m_axi_arready (c_arready),
    .m_axi_rdata   (c_rdata),
    .m_axi_rresp   (c_rresp),
    .m_axi_rvalid  (c_rvalid),
    .m_axi_rready  (c_rready)
  );

  // AXI4-Lite to register strobes in clk.
  rtlnet_axil_slave #(.ADDR_W(12)) u_axil_slave (
    .s_axi_aclk    (clk),
    .s_axi_aresetn (resetn),
    .s_axi_awaddr  (c_awaddr),
    .s_axi_awvalid (c_awvalid),
    .s_axi_awready (c_awready),
    .s_axi_wdata   (c_wdata),
    .s_axi_wstrb   (c_wstrb),
    .s_axi_wvalid  (c_wvalid),
    .s_axi_wready  (c_wready),
    .s_axi_bresp   (c_bresp),
    .s_axi_bvalid  (c_bvalid),
    .s_axi_bready  (c_bready),
    .s_axi_araddr  (c_araddr),
    .s_axi_arvalid (c_arvalid),
    .s_axi_arready (c_arready),
    .s_axi_rdata   (c_rdata),
    .s_axi_rresp   (c_rresp),
    .s_axi_rvalid  (c_rvalid),
    .s_axi_rready  (c_rready),
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data)
  );

  // ---------------------------------------------------------------------------
  // Register file and datapath state
  // ---------------------------------------------------------------------------
  logic [1:0]  video_mode;
  logic [1:0]  source;
  logic [31:0] frame_period;
  logic [31:0] cam_timeout;

  logic        sel_cam;            // selected source: 1 camera, 0 pattern
  logic        want_cam;
  logic        cam_alive;
  logic [31:0] cam_idle_frames;
  logic [31:0] fcnt;
  logic [31:0] period_eff;
  logic        tick;
  logic [31:0] ts_cnt;
  logic [31:0] frame_count;
  logic [1:0]  act_mode;
  logic [1:0]  gen_mode;
  logic        out_busy;
  logic [10:0] line_cnt;
  logic        between;
  logic        abort_cam;
  logic        gen_start;
  logic        gen_busy;
  logic        ev_overrun;

  logic [31:0] pat_tdata;
  logic        pat_tvalid;
  logic        pat_tready;
  logic        pat_tlast;
  logic        pat_tuser;

  logic [31:0] in_tdata;
  logic        in_tvalid;
  logic        in_tlast;
  logic        in_tuser;
  logic        stage_ready;
  logic        accept;
  logic        push;
  logic        cam_sof_seen;
  logic [10:0] act_height;

  rtlnet_csi2_rx_regs #(
    .NUM_MODES       (NUM_MODES),
    .CAMERA_PRESENT  (1'b0),
    .PERIOD_RESET    (PERIOD_RESET),
    .PERIOD_MIN_720  (PERIOD_MIN_720),
    .PERIOD_MIN_1080 (PERIOD_MIN_1080),
    .CAM_TIMEOUT_RST (CAM_TIMEOUT_RESET)
  ) u_regs (
    .clk          (clk),
    .resetn       (resetn),
    .reg_wr_en    (reg_wr_en),
    .reg_wr_addr  (reg_wr_addr),
    .reg_wr_data  (reg_wr_data),
    .reg_rd_en    (reg_rd_en),
    .reg_rd_addr  (reg_rd_addr),
    .reg_rd_data  (reg_rd_data),
    .video_mode   (video_mode),
    .source       (source),
    .frame_period (frame_period),
    .cam_timeout  (cam_timeout),
    .st_pattern   (!sel_cam),
    .st_clk_run   (cam_clk_running),
    .ev_overrun   (ev_overrun),
    .frame_count  (frame_count),
    .act_mode     (act_mode)
  );

  // ---------------------------------------------------------------------------
  // Frame timer and source selection
  // ---------------------------------------------------------------------------
  assign tick      = (fcnt == (period_eff - 32'd1));
  assign cam_alive = cam_clk_running && (cam_idle_frames < cam_timeout);
  assign want_cam  = (source == SRC_CAMERA) || ((source == 2'd0) && cam_alive);
  assign between   = !gen_busy && !out_busy;
  assign abort_cam = sel_cam && out_busy && !want_cam;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      fcnt            <= '0;
      period_eff      <= 32'(PERIOD_RESET);
      ts_cnt          <= '0;
      cam_idle_frames <= '1;           // no camera frame seen: auto starts on the pattern
    end else begin
      ts_cnt <= ts_cnt + 32'd1;
      if (tick) begin
        fcnt       <= '0;
        period_eff <= frame_period;
      end else begin
        fcnt <= fcnt + 32'd1;
      end
      if (cam_sof_seen)                                    cam_idle_frames <= '0;
      else if (tick && (cam_idle_frames != '1))            cam_idle_frames <= cam_idle_frames + 32'd1;
    end
  end

  // The selection changes between frames; a camera frame cut off by the selection is closed at once.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      sel_cam <= 1'b0;
    end else if (between || abort_cam) begin
      sel_cam <= want_cam;
    end
  end

  // ---------------------------------------------------------------------------
  // Pattern generator
  // ---------------------------------------------------------------------------
  assign gen_start  = tick && !sel_cam && !gen_busy && !out_busy;
  assign ev_overrun = tick && !sel_cam && (gen_busy || out_busy);

  rtlnet_csi2_rx_pattern #(
    .LINE_PERIOD_720  (LINE_PERIOD_720),
    .LINE_PERIOD_1080 (LINE_PERIOD_1080)
  ) u_pattern (
    .clk      (clk),
    .resetn   (resetn),
    .start    (gen_start),
    .mode     (video_mode),
    .busy     (gen_busy),
    .m_tdata  (pat_tdata),
    .m_tvalid (pat_tvalid),
    .m_tready (pat_tready),
    .m_tlast  (pat_tlast),
    .m_tuser  (pat_tuser)
  );

  always_ff @(posedge clk) begin
    if (!resetn)         gen_mode <= '0;
    else if (gen_start)  gen_mode <= video_mode;
  end

  // ---------------------------------------------------------------------------
  // Source switch and the registered output stage
  // ---------------------------------------------------------------------------
  assign in_tdata     = sel_cam ? s_cam_tdata  : pat_tdata;
  assign in_tvalid    = sel_cam ? s_cam_tvalid : pat_tvalid;
  assign in_tlast     = sel_cam ? s_cam_tlast  : pat_tlast;
  assign in_tuser     = sel_cam ? s_cam_tuser  : pat_tuser;
  assign stage_ready  = !m_axis_tvalid || m_axis_tready;
  // A camera word is part of a frame only when the frame began with a start-of-frame word.
  assign accept       = !sel_cam || out_busy || in_tuser;
  assign push         = in_tvalid && stage_ready && accept && !abort_cam;
  assign pat_tready   = !sel_cam && stage_ready;
  // Camera words are consumed when not selected, when they are not part of a frame, and when the stage takes them.
  assign s_cam_tready = !sel_cam || !accept || stage_ready || abort_cam;
  assign cam_sof_seen = s_cam_tvalid && s_cam_tready && s_cam_tuser;
  assign act_height   = (act_mode == MODE_1080P30) ? 11'(PIX_1080_H) : 11'(PIX_720_H);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      m_axis_tdata  <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tlast  <= 1'b0;
      m_axis_tuser  <= 1'b0;
      m_frame_num   <= '0;
      m_timestamp   <= '0;
      m_width       <= '0;
      m_height      <= '0;
      m_src_pattern <= 1'b0;
      frame_count   <= '0;
      act_mode      <= '0;
      out_busy      <= 1'b0;
      line_cnt      <= '0;
    end else begin
      if (m_axis_tvalid && m_axis_tready) m_axis_tvalid <= 1'b0;
      if (abort_cam) out_busy <= 1'b0;
      if (push) begin
        m_axis_tdata  <= in_tdata;
        m_axis_tvalid <= 1'b1;
        m_axis_tlast  <= in_tlast;
        m_axis_tuser  <= in_tuser;
        if (in_tuser) begin
          frame_count   <= frame_count + 32'd1;
          m_frame_num   <= frame_count + 32'd1;
          m_timestamp   <= ts_cnt;
          m_src_pattern <= !sel_cam;
          act_mode      <= sel_cam ? video_mode : gen_mode;
          m_width       <= ((sel_cam ? video_mode : gen_mode) == MODE_1080P30) ? 16'(PIX_1080_W) : 16'(PIX_720_W);
          m_height      <= ((sel_cam ? video_mode : gen_mode) == MODE_1080P30) ? 16'(PIX_1080_H) : 16'(PIX_720_H);
          out_busy      <= 1'b1;
          line_cnt      <= 11'd0;
        end else if (in_tlast) begin
          line_cnt <= line_cnt + 11'd1;
          if (line_cnt + 11'd1 == act_height) out_busy <= 1'b0;
        end
      end
    end
  end

endmodule
