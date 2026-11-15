// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx.sv
// Purpose: MIPI CSI-2 camera receiver core of IronKernel: D-PHY pins in (two data lanes and a clock lane), YUV422 video stream out, with a
//   75 percent color-bar generator and a source switch in front of the stream. With CAMERA_RX = 0 the camera comes in through the s_cam_*
//   port (the core is then the register block, the generator and the switch).
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
//   * Camera receiver (CAMERA_RX = 1), in the order of the data: rtlnet_csi2_rx_dphy (byte clock domain: HS clock, LP states, settle,
//     byte alignment, lane deskew) -> rtlnet_csi2_rx_packet (ECC, CRC, filter, RAW10 unpacking) -> rtlnet_csi2_rx_cdc (byte clock to clk FIFO)
//     -> rtlnet_csi2_rx_bayer (frame conditioning to the mode geometry, black level, white balance, demosaic, gamma) -> rtlnet_csi2_rx_yuv
//     -> the camera input of the source switch. Event pulses of the byte clock domain (ECC, CRC, truncation, wrong data type, orphan line,
//     word count, frame, start-of-transmission error, FIFO overflow) cross through rtlnet_pulse_sync into the 12 event counters of the
//     register block; the bayer size error and the loss of the HS clock are counted in clk. The mode geometry (WIDTH_720 x HEIGHT_720, WIDTH_1080
//     x HEIGHT_1080) is taken from VIDEO_MODE at the start of each frame: change VIDEO_MODE while the camera is not streaming.
//   * Registers on s_axi_aclk behind rtlnet_axil_cdc and rtlnet_axil_slave (4 KiB window); rtlnet_csi2_rx_regs holds the
//     register file, offsets in driver/rtlnet_csi2_rx.h.
//   * The receiver is proven in simulation only (benches of the core folder); it has not run on hardware yet.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: camera receiver inside the core (CAMERA_RX), D-PHY pins and ref_clk ports, geometry parameters.
//   * 11-10-2026: PATTERN and PATTERN_FRAME registers, moving test patterns (rtlnet_csi2_rx_pattern).
//   * 11-09-2026: initial version (Phase 1: registers, color bars, source switch).
// Clocks: clk (generator, switch, registers, video stream, bayer and yuv; the memory-controller user clock); s_axi_aclk (AXI4-Lite slave
//   side of the register crossing only); ref_clk (200 MHz IDELAY reference and LP/clock monitor, CAMERA_RX only); byte_clk (derived from the
//   HS clock inside rtlnet_csi2_rx_dphy, CAMERA_RX only). Crossings: registers s_axi_aclk <-> clk (rtlnet_axil_cdc); configuration levels
//   clk -> ref_clk and byte_clk (2-flop synchronizers inside rtlnet_csi2_rx_dphy and rtlnet_csi2_rx_packet, written while idle); pixel entries
//   byte_clk -> clk (rtlnet_csi2_rx_cdc, Gray-coded pointers); event pulses byte_clk -> clk (rtlnet_pulse_sync); status levels ref_clk and
//   byte_clk -> clk (rtlnet_sync).
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_csi2_rx #(
  parameter bit    AXIL_SYNC = 1'b0,   // 1: s_axi_aclk is clk (register window without a clock crossing)
  parameter int PERIOD_RESET      = 3_000_000,   // clocks per frame at reset: 30.000 fps at 90 MHz
  parameter int PERIOD_MIN_720    = 3_000_000,   // 750 lines * LINE_PERIOD_720
  parameter int PERIOD_MIN_1080   = 2_999_250,   // 1125 lines * LINE_PERIOD_1080
  parameter int LINE_PERIOD_720   = 4000,        // clocks per line at 720p30
  parameter int LINE_PERIOD_1080  = 2666,        // clocks per line at 1080p30
  parameter int CAM_TIMEOUT_RESET = 2,           // frame periods
  parameter bit    CAMERA_RX       = 1'b0,        // 1: the internal CSI-2 receiver (D-PHY pins) feeds the source switch
  parameter string DPHY_TARGET     = `RTLNET_TARGET,   // "AMD": 7-series primitives in the D-PHY front end, else behavioural
  parameter bit    NONCONT_CLOCK   = 1'b0,        // 1: the sensor stops the HS clock between bursts
  parameter bit    IDELAYCTRL_INST = 1'b1,        // 1: IDELAYCTRL inside the front end
  parameter int    FIFO_KB         = 4,           // byte clock to clk FIFO: kilobytes of 8-byte words (power of two entries)
  parameter int    LINE_KB         = 8,           // Bayer line buffers: kilobytes of 4-byte words (pixels per line = 256 * LINE_KB)
  parameter string RAM_STYLE       = "block",     // "block" | "distributed" for both RAMs
  parameter int    WIDTH_720       = 1280,        // frame geometry of the two modes
  parameter int    HEIGHT_720      = 720,
  parameter int    WIDTH_1080      = 1920,
  parameter int    HEIGHT_1080     = 1080
)(
  // Core clock and its reset (synchronous, active low); the AXI4-Lite clock and its reset (released from the same
  // assertion).
  input  logic        clk,
  input  logic        resetn,
  input  logic        s_axi_aclk,
  input  logic        s_axi_aresetn,

  // External camera stream (CAMERA_RX = 0), clk domain; tied off (valid 0) by a board without a camera. Not used with CAMERA_RX = 1.
  input  logic [31:0] s_cam_tdata,
  input  logic        s_cam_tvalid,
  output logic        s_cam_tready,
  input  logic        s_cam_tlast,
  input  logic        s_cam_tuser,
  input  logic        cam_clk_running,           // camera byte clock detected, already synchronized to clk (CAMERA_RX = 0)

  // CSI-2 camera pins and reference clock (CAMERA_RX = 1; leave unconnected otherwise). HS pairs, and the two LP pins of each lane.
  input  logic        ref_clk,                   // 200 MHz IDELAY reference
  input  logic        dphy_clk_p,
  input  logic        dphy_clk_n,
  input  logic        dphy_clk_lp_p,
  input  logic        dphy_clk_lp_n,
  input  logic [1:0]  dphy_dat_p,
  input  logic [1:0]  dphy_dat_n,
  input  logic [1:0]  dphy_dat_lp_p,
  input  logic [1:0]  dphy_dat_lp_n,

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
  localparam int          PIX_720_W    = WIDTH_720;
  localparam int          PIX_720_H    = HEIGHT_720;
  localparam int          PIX_1080_W   = WIDTH_1080;
  localparam int          PIX_1080_H   = HEIGHT_1080;
  localparam logic [1:0]  MODE_1080P30 = 2'd1;
  localparam logic [1:0]  SRC_CAMERA   = 2'd1;

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
  logic [2:0]  pattern_sel;
  logic [7:0]  pattern_speed;
  logic        pat_restart;
  logic [31:0] pat_frame;

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

  // Camera stream after the source mux, and the camera receiver signals.
  logic [31:0] cam_tdata_i;
  logic        cam_tvalid_i;
  logic        cam_tlast_i;
  logic        cam_tuser_i;
  logic        cam_run_i;
  logic        rx_enable, rx_soft_reset, rx_bit_rev, px_gamma;
  logic [1:0]  rx_lane_en, rx_vc, px_phase;
  logic [4:0]  rx_tap0, rx_tap1;
  logic [7:0]  rx_settle;
  logic [5:0]  rx_dt;
  logic [9:0]  px_black;
  logic [11:0] px_gain_r, px_gain_g, px_gain_b;
  logic [11:0] rx_st;
  logic [15:0] rx_lines, rx_pixels;
  logic [11:0] rx_ev;

  rtlnet_csi2_rx_regs #(
    .NUM_MODES       (NUM_MODES),
    .CAMERA_PRESENT  (CAMERA_RX),
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
    .pattern      (pattern_sel),
    .pat_speed    (pattern_speed),
    .pat_restart  (pat_restart),
    .st_pattern   (!sel_cam),
    .st_clk_run   (cam_run_i),
    .ev_overrun   (ev_overrun),
    .frame_count  (frame_count),
    .act_mode     (act_mode),
    .pat_frame    (pat_frame),
    .rx_enable    (rx_enable),
    .rx_soft_reset(rx_soft_reset),
    .rx_lane_en   (rx_lane_en),
    .rx_bit_rev   (rx_bit_rev),
    .rx_tap0      (rx_tap0),
    .rx_tap1      (rx_tap1),
    .rx_settle    (rx_settle),
    .rx_vc        (rx_vc),
    .rx_dt        (rx_dt),
    .px_black     (px_black),
    .px_gain_r    (px_gain_r),
    .px_gain_g    (px_gain_g),
    .px_gain_b    (px_gain_b),
    .px_phase     (px_phase),
    .px_gamma     (px_gamma),
    .rx_st        (rx_st),
    .rx_lines     (rx_lines),
    .rx_pixels    (rx_pixels),
    .rx_ev        (rx_ev)
  );

  // ---------------------------------------------------------------------------
  // Camera receiver
  // ---------------------------------------------------------------------------
  logic        sw_tready;     // the source switch accepts a camera word (feeds the external port and the internal yuv stage)

  generate
    if (CAMERA_RX) begin : g_cam
      logic        rx_rstn;          // clk domain reset of the receiver path: system reset and soft reset
      logic        byte_clk, byte_resetn, byte_resetn_g;
      logic        p_valid, p_first, p_end, ev_sot;
      logic [15:0] p_data;
      logic        st_clk_running, st_dlyctl_rdy;
      logic [1:0]  st_hs, st_locked, st_lp_d0, st_lp_d1;
      logic        e_valid;
      logic [45:0] e_data;
      logic        pk_ecc_corr, pk_ecc_unc, pk_crc, pk_trunc, pk_dt, pk_frame, pk_orphan, pk_len, pk_in_frame;
      logic        ev_ovf;
      logic        m_valid, m_ready;
      logic [45:0] m_data;
      logic [23:0] rgb_data;
      logic        rgb_valid, rgb_ready, rgb_sof, rgb_eol;
      logic        bay_size_err;
      logic        yuv_fmt_err;
      logic [31:0] y_data;
      logic        y_valid, y_last, y_user;
      logic [11:0] cfg_w, cfg_h;
      logic [11:0] ev_b;              // byte-domain events, in counter order
      logic [11:0] ev_c;              // the same, crossed into clk
      logic        clk_running_s;
      logic        clk_running_q;
      logic [1:0]  hs_s, locked_s, lp0_s, lp1_s;
      logic        dly_s, inframe_s;

      always_ff @(posedge clk) begin
        if (!resetn) rx_rstn <= 1'b0;
        else         rx_rstn <= !rx_soft_reset;
      end

      assign cfg_w = (video_mode == MODE_1080P30) ? 12'(WIDTH_1080) : 12'(WIDTH_720);
      assign cfg_h = (video_mode == MODE_1080P30) ? 12'(HEIGHT_1080) : 12'(HEIGHT_720);

      rtlnet_csi2_rx_dphy #(
        .TARGET(DPHY_TARGET), .NONCONT_CLOCK(NONCONT_CLOCK), .IDELAYCTRL_INST(IDELAYCTRL_INST)
      ) u_dphy (
        .ref_clk(ref_clk), .arstn(rx_rstn),
        .hs_clk_p(dphy_clk_p), .hs_clk_n(dphy_clk_n), .hs_dat_p(dphy_dat_p), .hs_dat_n(dphy_dat_n),
        .lp_clk({dphy_clk_lp_p, dphy_clk_lp_n}),
        .lp_d0({dphy_dat_lp_p[0], dphy_dat_lp_n[0]}), .lp_d1({dphy_dat_lp_p[1], dphy_dat_lp_n[1]}),
        .cfg_tap0(rx_tap0), .cfg_tap1(rx_tap1), .cfg_settle(rx_settle), .cfg_lane_en(rx_lane_en), .cfg_enable(rx_enable),
        .cfg_bit_rev(rx_bit_rev),
        .byte_clk(byte_clk), .byte_resetn(byte_resetn), .byte_resetn_g(byte_resetn_g),
        .p_valid(p_valid), .p_data(p_data), .p_first(p_first), .p_end(p_end), .ev_sot(ev_sot),
        .st_clk_running(st_clk_running), .st_hs(st_hs), .st_locked(st_locked), .st_lp_d0(st_lp_d0), .st_lp_d1(st_lp_d1),
        .st_dlyctl_rdy(st_dlyctl_rdy)
      );

      rtlnet_csi2_rx_packet u_packet (
        .byte_clk(byte_clk), .byte_resetn(byte_resetn), .cfg_vc(rx_vc), .cfg_dt(rx_dt),
        .p_valid(p_valid), .p_data(p_data), .p_first(p_first), .p_end(p_end),
        .e_valid(e_valid), .e_data(e_data),
        .ev_ecc_corr(pk_ecc_corr), .ev_ecc_unc(pk_ecc_unc), .ev_crc(pk_crc), .ev_trunc(pk_trunc), .ev_dt(pk_dt),
        .ev_frame(pk_frame), .ev_orphan(pk_orphan), .ev_len(pk_len), .st_in_frame(pk_in_frame)
      );

      rtlnet_csi2_rx_cdc #(.RAM_STYLE(RAM_STYLE), .FIFO_KB(FIFO_KB)) u_cdc_fifo (
        .w_clk(byte_clk), .w_resetn(byte_resetn_g), .w_valid(e_valid), .w_data(e_data), .ev_overflow(ev_ovf),
        .r_clk(clk), .r_resetn(rx_rstn), .m_valid(m_valid), .m_data(m_data), .m_ready(m_ready)
      );

      rtlnet_csi2_rx_bayer #(.RAM_STYLE(RAM_STYLE), .LINE_KB(LINE_KB)) u_bayer (
        .clk(clk), .resetn(rx_rstn),
        .e_valid(m_valid), .e_data(m_data), .e_ready(m_ready),
        .cfg_w(cfg_w), .cfg_h(cfg_h), .cfg_black(px_black), .cfg_gain_r(px_gain_r), .cfg_gain_g(px_gain_g), .cfg_gain_b(px_gain_b),
        .cfg_phase(px_phase), .cfg_gamma(px_gamma),
        .o_data(rgb_data), .o_valid(rgb_valid), .o_ready(rgb_ready), .o_sof(rgb_sof), .o_eol(rgb_eol),
        .ev_size_err(bay_size_err), .meas_lines(rx_lines), .meas_pixels(rx_pixels)
      );

      rtlnet_csi2_rx_yuv u_yuv (
        .clk(clk), .resetn(rx_rstn),
        .s_axis_tdata(rgb_data), .s_axis_tvalid(rgb_valid), .s_axis_tready(rgb_ready), .s_axis_tuser(rgb_sof), .s_axis_tlast(rgb_eol),
        .m_axis_tdata(y_data), .m_axis_tvalid(y_valid), .m_axis_tready(sw_tready), .m_axis_tuser(y_user), .m_axis_tlast(y_last),
        .format_error(yuv_fmt_err)
      );

      // Event pulses of the byte clock domain into clk, in the order of the counters of the register map: 0 ecc corrected, 1 ecc
      // uncorrectable, 2 crc, 3 sot, 4 frames, 5 data type, 6 truncated, 7 fifo overflow, (8 frame size and 11 clock loss are made in clk),
      // 9 orphan line, 10 word count.
      assign ev_b = {1'b0, pk_len, pk_orphan, 1'b0, ev_ovf, pk_trunc, pk_dt, pk_frame, ev_sot, pk_crc, pk_ecc_unc, pk_ecc_corr};
      for (genvar i = 0; i < 12; i++) begin : g_ev
        if (i == 8 || i == 11) begin : g_none
          assign ev_c[i] = 1'b0;
        end else begin : g_sync
          rtlnet_pulse_sync u_ev_sync (
            .src_clk(byte_clk), .src_resetn(byte_resetn_g), .src_pulse(ev_b[i]),
            .dst_clk(clk), .dst_resetn(rx_rstn), .dst_pulse(ev_c[i])
          );
        end
      end

      // Status levels into clk.
      rtlnet_sync #(.WIDTH(1 + 2 + 2 + 2 + 2 + 1 + 1), .STAGES(2)) u_st_sync (
        .clk(clk), .resetn(rx_rstn),
        .d({st_clk_running, st_hs, st_locked, st_lp_d0, st_lp_d1, st_dlyctl_rdy, pk_in_frame}),
        .q({clk_running_s, hs_s, locked_s, lp0_s, lp1_s, dly_s, inframe_s})
      );

      always_ff @(posedge clk) begin
        if (!rx_rstn) clk_running_q <= 1'b0;
        else          clk_running_q <= clk_running_s;
      end

      assign rx_st = {lp1_s, lp0_s, yuv_fmt_err, inframe_s, dly_s, locked_s, hs_s, clk_running_s};
      assign rx_ev = {clk_running_q && !clk_running_s, ev_c[10], ev_c[9], bay_size_err, ev_c[7:0]};

      assign cam_tdata_i  = y_data;
      assign cam_tvalid_i = y_valid;
      assign cam_tlast_i  = y_last;
      assign cam_tuser_i  = y_user;
      assign cam_run_i    = clk_running_s;
    end else begin : g_nocam
      assign rx_st        = '0;
      assign rx_lines     = '0;
      assign rx_pixels    = '0;
      assign rx_ev        = '0;
      assign cam_tdata_i  = s_cam_tdata;
      assign cam_tvalid_i = s_cam_tvalid;
      assign cam_tlast_i  = s_cam_tlast;
      assign cam_tuser_i  = s_cam_tuser;
      assign cam_run_i    = cam_clk_running;
    end
  endgenerate

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
    .pattern  (pattern_sel),
    .speed    (pattern_speed),
    .restart  (pat_restart),
    .busy     (gen_busy),
    .pat_frame (pat_frame),
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
  assign in_tdata     = sel_cam ? cam_tdata_i  : pat_tdata;
  assign in_tvalid    = sel_cam ? cam_tvalid_i : pat_tvalid;
  assign in_tlast     = sel_cam ? cam_tlast_i  : pat_tlast;
  assign in_tuser     = sel_cam ? cam_tuser_i  : pat_tuser;
  assign stage_ready  = !m_axis_tvalid || m_axis_tready;
  // A camera word is part of a frame only when the frame began with a start-of-frame word.
  assign accept       = !sel_cam || out_busy || in_tuser;
  assign push         = in_tvalid && stage_ready && accept && !abort_cam;
  assign pat_tready   = !sel_cam && stage_ready;
  // Camera words are consumed when not selected, when they are not part of a frame, and when the stage takes them.
  assign sw_tready    = !sel_cam || !accept || stage_ready || abort_cam;
  assign s_cam_tready = sw_tready;
  assign cam_sof_seen = cam_tvalid_i && sw_tready && cam_tuser_i;
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
