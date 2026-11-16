// -----------------------------------------------------------------------------
// File: rtlnet_vdma_s2mm.sv
// Purpose: 2D write DMA of the video path: writes a YUV422 word stream as a
//   frame of lines into a frame-buffer slot of DDR3 through AXI4 INCR bursts of at most MAX_BURST_BEATS beats of AXI_DATA_W bits.
// Overview:
//   * Stream in: 32-bit words of two pixels, tuser = first word of a frame, tlast = last word of a line, with the frame
//     sideband (width and height in pixels, frame number, timestamp, source flag) stable from the first word of a frame
//     until the next one. AXI_DATA_W / 32 words pack into one beat (four for 128 bits, two for 64 bits), word 0 in the low
//     bytes (memory order Y0 Cb Y1 Cr). The bytes in memory are the same for both widths; only the beat size changes.
//   * Frame control (one registered FSM, fs): at a first word the core captures the sideband and checks the geometry
//     (width a nonzero multiple of 8 pixels = one beat, height nonzero, stride a multiple of 16 and at least the line
//     bytes; STRIDE 0 means packed). A frame is not written (its words are consumed and discarded up to the next first
//     word, counted in FRAMES_DROPPED) when the core is disabled, the geometry is bad (STATUS.CFG_ERR) or the frame
//     buffer has no slot. Otherwise fb_req asks the frame buffer for a slot; its answer (fb_rsp_valid, fb_rsp_ok,
//     fb_rsp_base, a DDR3 byte offset) starts the write or drops the frame.
//   * A frame line is width/2 words. A misplaced tlast (early or missing) marks the frame bad (STATUS.LINE_ERR) but the
//     geometry follows the word counts. A first word that arrives before the frame is complete (a cut-off frame) marks it
//     bad and the core pads the rest of the frame with zero words, so the write side always completes a whole frame
//     and the DDR3 write stream stays consistent; the frame is reported not good.
//   * Write side: line n starts at base + n * stride. Bursts follow the line from its start; the length is the least
//     of MAX_BURST_BEATS, the beats left in the line and the beats to the next 4 KiB boundary, so a burst never crosses
//     4 KiB. A beat is AXI_DATA_W / 8 bytes: with 64 bits a burst of the same beat count carries half the bytes, and
//     MAX_BURST_BEATS 16 is the AXI3 limit of the Zynq HP ports (AWLEN is 4 bits there). A burst's AW is issued only when all its beats are already in the beat FIFO (a W channel that never starves
//     keeps the shared arbiter's W path free for the other masters). W beats follow AW in order. Outstanding bursts are
//     bounded (W queue of 4, 7 awaiting B). The beat FIFO is one rtlnet_ram_core (FIFO_KB kilobytes, common clock).
//   * Done: when the last burst's response has arrived, fb_done pulses for one clock with fb_done_good = frame complete,
//     every line end where expected and every write response OKAY, and the sideband of the frame. The frame buffer
//     publishes only a good frame.
//   * AXI4 master: AW and W only (no read channel); ID constant 0; size log2(AXI_DATA_W / 8) (full width), burst INCR, strobes
//     all ones. awlen never exceeds 15 (MAX_BURST_BEATS is at most 16), so the master meets AXI3 as well; the user of an AXI3
//     port takes awlen[3:0] and drives WID equal to the (constant) AWID.
//   * Registers on s_axi_aclk behind rtlnet_axil_cdc and rtlnet_axil_slave (4 KiB window); rtlnet_vdma_s2mm_regs holds the
//     register file, offsets in driver/rtlnet_vdma_s2mm.h.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: AXI_DATA_W parameter (128 default, 64): beat size, packer, beat FIFO and burst size follow it.
//   * 11-09-2026: initial version.
// Clocks: clk (datapath, FIFO, registers; the memory-controller user clock); s_axi_aclk (AXI4-Lite slave side of the
//   register crossing only).
// -----------------------------------------------------------------------------
module rtlnet_vdma_s2mm #(
  parameter bit    AXIL_SYNC = 1'b0,   // 1: s_axi_aclk is clk (register window without a clock crossing)
  parameter int    ADDR_W          = 29,        // DDR3 byte address bits
  parameter int    ID_W            = 1,
  parameter int    AXI_DATA_W      = 128,       // memory data width in bits: 128 or 64
  parameter int    MAX_BURST_BEATS = 16,        // 1..16 beats of AXI_DATA_W bits
  parameter int    FIFO_KB         = 2,         // beat FIFO, kilobytes (power of two beats, at least 2 bursts)
  parameter string RAM_STYLE       = "block"
)(
  // Core clock and its reset (synchronous, active low); the AXI4-Lite clock and its reset (released from the same
  // assertion).
  input  logic                clk,
  input  logic                resetn,
  input  logic                s_axi_aclk,
  input  logic                s_axi_aresetn,

  // Video stream in, clk domain, with the frame sideband.
  input  logic [31:0]         s_axis_tdata,
  input  logic                s_axis_tvalid,
  output logic                s_axis_tready,
  input  logic                s_axis_tlast,
  input  logic                s_axis_tuser,
  input  logic [15:0]         s_width,
  input  logic [15:0]         s_height,
  input  logic [31:0]         s_frame_num,
  input  logic [31:0]         s_timestamp,
  input  logic                s_src_pattern,

  // Frame-buffer slot interface, clk domain: fb_req is held until fb_rsp_valid (a one-clock pulse) answers; fb_done pulses
  // once per written frame.
  output logic                fb_req,
  input  logic                fb_rsp_valid,
  input  logic                fb_rsp_ok,
  input  logic [ADDR_W-1:0]   fb_rsp_base,
  output logic                fb_done,
  output logic                fb_done_good,
  output logic [31:0]         fb_done_frame_num,
  output logic [31:0]         fb_done_timestamp,
  output logic [15:0]         fb_done_width,
  output logic [15:0]         fb_done_height,
  output logic                fb_done_src_pattern,

  // AXI4 master write channels, clk domain.
  output logic [ID_W-1:0]     m_axi_awid,
  output logic [ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]          m_axi_awlen,
  output logic [2:0]          m_axi_awsize,
  output logic [1:0]          m_axi_awburst,
  output logic                m_axi_awvalid,
  input  logic                m_axi_awready,
  output logic [AXI_DATA_W-1:0]   m_axi_wdata,
  output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
  output logic                m_axi_wlast,
  output logic                m_axi_wvalid,
  input  logic                m_axi_wready,
  input  logic [ID_W-1:0]     m_axi_bid,
  input  logic [1:0]          m_axi_bresp,
  input  logic                m_axi_bvalid,
  output logic                m_axi_bready,

  // AXI4-Lite register slave, s_axi_aclk domain, 12-bit byte address, 32-bit data.
  input  logic [11:0]         s_axi_awaddr,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,
  input  logic [31:0]         s_axi_wdata,
  input  logic [3:0]          s_axi_wstrb,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready,
  input  logic [11:0]         s_axi_araddr,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,
  output logic [31:0]         s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready
);

  localparam int          BEAT_BYTES   = AXI_DATA_W / 8;
  localparam int          BEAT_SHIFT   = $clog2(BEAT_BYTES);
  localparam int          WPB          = AXI_DATA_W / 32;                  // stream words per beat
  localparam logic [1:0]  PK_LAST      = 2'(WPB - 1);
  localparam int          BPL_SH       = $clog2(AXI_DATA_W / 16);          // pixels per beat = 2**BPL_SH
  localparam int          BPL_W        = 16 - BPL_SH;                      // bits of the beats per line (13 for 128 bits)
  localparam int          TP_W         = $clog2(4096 / BEAT_BYTES) + 1;    // bits of the beats to the next 4 KiB boundary (9 for 128 bits)
  localparam int          FIFO_BEATS   = FIFO_KB * 1024 / BEAT_BYTES;
  localparam int          PTR_W        = $clog2(FIFO_BEATS);
  localparam int          WQ_DEPTH     = 4;
  localparam int          WQ_PTR_W     = 2;
  localparam int          MAX_B_OUT    = 7;
  localparam int          PAGE_BEATS   = 4096 / BEAT_BYTES;          // beats per 4 KiB page
  localparam logic [1:0]  RESP_OKAY    = 2'b00;
  localparam logic [2:0]  AXI_SIZE     = 3'(BEAT_SHIFT);
  localparam logic [1:0]  AXI_INCR     = 2'b01;

  generate
    if (AXI_DATA_W != 128 && AXI_DATA_W != 64) begin : g_bad_width
      $fatal(1, "rtlnet_vdma_s2mm: AXI_DATA_W=%0d, must be 128 or 64", AXI_DATA_W);
    end
    if (MAX_BURST_BEATS < 1 || MAX_BURST_BEATS > 16) begin : g_bad_burst
      $fatal(1, "rtlnet_vdma_s2mm: MAX_BURST_BEATS=%0d, must be 1..16", MAX_BURST_BEATS);
    end
    if (FIFO_BEATS < 2 * MAX_BURST_BEATS || (FIFO_BEATS & (FIFO_BEATS - 1)) != 0) begin : g_bad_fifo
      $fatal(1, "rtlnet_vdma_s2mm: FIFO_KB=%0d gives %0d beats; need a power of two of at least two bursts",
             FIFO_KB, FIFO_BEATS);
    end
  endgenerate

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
  // State
  // ---------------------------------------------------------------------------
  localparam logic [2:0] F_IDLE    = 3'd0;   // wait for the first word of a frame
  localparam logic [2:0] F_REQ     = 3'd1;   // slot requested
  localparam logic [2:0] F_ACTIVE  = 3'd2;   // words from the stream
  localparam logic [2:0] F_PAD     = 3'd3;   // zero words complete a cut-off frame
  localparam logic [2:0] F_DRAIN   = 3'd4;   // all words in, wait for the last write response
  localparam logic [2:0] F_DONE    = 3'd5;   // fb_done pulse
  localparam logic [2:0] F_DISCARD = 3'd6;   // consume and discard up to the next first word

  logic [2:0]          fs;
  logic                enable;
  logic [31:0]         stride_reg;

  // Frame sideband and geometry.
  logic [15:0]         sb_width;
  logic [15:0]         sb_height;
  logic [31:0]         sb_frame;
  logic [31:0]         sb_ts;
  logic                sb_src;
  logic [14:0]         wpl;            // words per line
  logic [BPL_W-1:0]    bpl;            // beats per line
  logic [ADDR_W-1:0]   stride_q;       // line stride, bytes
  logic                cfg_ok;
  logic [16:0]         width_bytes;
  logic [31:0]         stride_eff;

  // Stream-side counters.
  logic [14:0]         w_in_line;
  logic [15:0]         l_done;
  logic                first_word;
  logic                disc_first;
  logic                f_bad;
  logic                f_axi_bad;
  logic                early_sof;
  logic                pack_room;
  logic                wacc;
  logic [31:0]         wdat;
  logic                exp_last;
  logic                last_of_frame;

  // Packer and beat FIFO.
  logic [1:0]          pk_cnt;
  logic [AXI_DATA_W-1:0] pk;
  logic [PTR_W:0]      wptr;
  logic [PTR_W:0]      rptr;
  logic [PTR_W:0]      occ;
  logic                fifo_wr;
  logic [AXI_DATA_W-1:0] fifo_wdata;
  logic [AXI_DATA_W-1:0] fifo_rdata;
  logic                fifo_rd;
  logic                rd_valid;

  // Write session (address generation).
  logic                ws_active;
  logic                all_issued;
  logic [ADDR_W-1:0]   line_addr;
  logic [BPL_W-1:0]    beat_in_line;
  logic [15:0]         lines_left;
  logic [PTR_W:0]      uncommitted;
  logic [ADDR_W-1:0]   cur_addr;       // registered: address of the next burst
  logic [BPL_W-1:0]    rem_beats;      // registered: beats left in the line
  logic [TP_W-1:0]     to_page;        // registered: beats to the next 4 KiB boundary
  logic [4:0]          burst_len;      // registered: length of the next burst in beats
  logic                last_in_line;   // registered: the next burst ends the line
  logic [4:0]          len_n;
  logic [1:0]          calc_cnt;       // clocks since the address state last changed (the burst values are valid at 3)
  logic                aw_load;
  logic [3:0]          b_out;

  // W channel.
  logic [4:0]          wq_len [WQ_DEPTH];
  logic [WQ_PTR_W-1:0] wq_wp;
  logic [WQ_PTR_W-1:0] wq_rp;
  logic [2:0]          wq_cnt;
  logic                w_active;
  logic [4:0]          w_left;
  logic                wfire;
  logic                w_load;
  logic                wq_push;

  // Events.
  logic                ev_cfg_err;
  logic                ev_axi_err;
  logic                ev_line_err;
  logic                ev_frame_ok;
  logic                ev_frame_bad;
  logic                ev_frame_drop;
  logic                ev_frame_start;

  // ---------------------------------------------------------------------------
  // Geometry check on the sideband of a first word
  // ---------------------------------------------------------------------------
  assign width_bytes = {s_width, 1'b0};
  assign stride_eff  = (stride_reg == 32'd0) ? 32'(width_bytes) : stride_reg;
  assign cfg_ok      = (s_width != 16'd0) && (s_width[2:0] == 3'd0) && (s_height != 16'd0) &&
                       (stride_eff >= 32'(width_bytes)) && (stride_eff[3:0] == 4'd0) &&
                       (stride_eff < (32'd1 << ADDR_W));

  // ---------------------------------------------------------------------------
  // Frame control
  // ---------------------------------------------------------------------------
  assign fb_req              = (fs == F_REQ);
  assign fb_done             = (fs == F_DONE);
  assign fb_done_good        = !f_bad && !f_axi_bad;
  assign fb_done_frame_num   = sb_frame;
  assign fb_done_timestamp   = sb_ts;
  assign fb_done_width       = sb_width;
  assign fb_done_height      = sb_height;
  assign fb_done_src_pattern = sb_src;

  assign early_sof     = s_axis_tvalid && s_axis_tuser && !first_word;
  assign exp_last      = (w_in_line == (wpl - 15'd1));
  assign last_of_frame = exp_last && (l_done == (sb_height - 16'd1));
  assign pack_room     = (pk_cnt != PK_LAST) || (occ != (PTR_W+1)'(FIFO_BEATS));

  // A word is accepted from the stream while active, or generated as zero while padding.
  assign wacc = ((fs == F_ACTIVE) && s_axis_tvalid && !early_sof && pack_room) ||
                ((fs == F_PAD) && pack_room);
  assign wdat = (fs == F_PAD) ? 32'd0 : s_axis_tdata;

  always_comb begin
    case (fs)
      F_IDLE:    s_axis_tready = !s_axis_tuser;      // a stray word before a first word is consumed
      F_ACTIVE:  s_axis_tready = pack_room && !early_sof;
      F_DISCARD: s_axis_tready = disc_first || !s_axis_tuser;
      default:   s_axis_tready = 1'b0;
    endcase
  end

  assign ev_cfg_err     = (fs == F_IDLE) && s_axis_tvalid && s_axis_tuser && enable && !cfg_ok;
  assign ev_frame_drop  = ((fs == F_IDLE) && s_axis_tvalid && s_axis_tuser && (!enable || !cfg_ok)) ||
                          ((fs == F_REQ) && fb_rsp_valid && !fb_rsp_ok);
  assign ev_frame_start = (fs == F_REQ) && fb_rsp_valid && fb_rsp_ok;
  assign ev_frame_ok    = (fs == F_DONE) && fb_done_good;
  assign ev_frame_bad   = (fs == F_DONE) && !fb_done_good;
  assign ev_line_err    = ((fs == F_ACTIVE) && wacc && (s_axis_tlast != exp_last)) || ((fs == F_ACTIVE) && early_sof);
  assign ev_axi_err     = m_axi_bvalid && m_axi_bready && (m_axi_bresp != RESP_OKAY);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      fs         <= F_IDLE;
      sb_width   <= '0;
      sb_height  <= '0;
      sb_frame   <= '0;
      sb_ts      <= '0;
      sb_src     <= 1'b0;
      wpl        <= '0;
      bpl        <= '0;
      stride_q   <= '0;
      w_in_line  <= '0;
      l_done     <= '0;
      first_word <= 1'b0;
      disc_first <= 1'b0;
      f_bad      <= 1'b0;
      f_axi_bad  <= 1'b0;
    end else begin
      if (ev_axi_err) f_axi_bad <= 1'b1;
      case (fs)
        F_IDLE: begin
          if (s_axis_tvalid && s_axis_tuser) begin
            sb_width   <= s_width;
            sb_height  <= s_height;
            sb_frame   <= s_frame_num;
            sb_ts      <= s_timestamp;
            sb_src     <= s_src_pattern;
            wpl        <= s_width[15:1];
            bpl        <= s_width[15:BPL_SH];
            stride_q   <= stride_eff[ADDR_W-1:0];
            f_bad      <= 1'b0;
            f_axi_bad  <= 1'b0;
            if (enable && cfg_ok) begin
              fs <= F_REQ;
            end else begin
              fs         <= F_DISCARD;
              disc_first <= 1'b1;
            end
          end
        end
        F_REQ: begin
          if (fb_rsp_valid) begin
            if (fb_rsp_ok) begin
              fs         <= F_ACTIVE;
              w_in_line  <= '0;
              l_done     <= '0;
              first_word <= 1'b1;
            end else begin
              fs         <= F_DISCARD;
              disc_first <= 1'b1;
            end
          end
        end
        F_ACTIVE: begin
          if (early_sof) begin
            f_bad <= 1'b1;            // cut-off frame: complete it with zero words, report it not good
            fs    <= F_PAD;
          end else if (wacc) begin
            first_word <= 1'b0;
            if (s_axis_tlast != exp_last) f_bad <= 1'b1;
            if (exp_last) begin
              w_in_line <= '0;
              l_done    <= l_done + 16'd1;
              if (last_of_frame) fs <= F_DRAIN;
            end else begin
              w_in_line <= w_in_line + 15'd1;
            end
          end
        end
        F_PAD: begin
          if (wacc) begin
            if (exp_last) begin
              w_in_line <= '0;
              l_done    <= l_done + 16'd1;
              if (last_of_frame) fs <= F_DRAIN;
            end else begin
              w_in_line <= w_in_line + 15'd1;
            end
          end
        end
        F_DRAIN: begin
          if (all_issued && (b_out == 4'd0) && !m_axi_awvalid) fs <= F_DONE;
        end
        F_DONE: begin
          fs <= F_IDLE;
        end
        F_DISCARD: begin
          if (s_axis_tvalid && s_axis_tready) disc_first <= 1'b0;
          if (!disc_first && s_axis_tvalid && s_axis_tuser) fs <= F_IDLE;
        end
        default: fs <= F_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Packer and beat FIFO
  // ---------------------------------------------------------------------------
  assign occ        = wptr - rptr;
  assign fifo_wr    = wacc && (pk_cnt == PK_LAST);
  assign fifo_wdata = {wdat, pk[AXI_DATA_W-1:32]};

  always_ff @(posedge clk) begin
    if (!resetn) begin
      pk_cnt <= '0;
      pk     <= '0;
      wptr   <= '0;
    end else if (wacc) begin
      pk     <= {wdat, pk[AXI_DATA_W-1:32]};
      pk_cnt <= (WPB == 4) ? (pk_cnt + 2'd1) : {1'b0, !pk_cnt[0]};
      if (pk_cnt == PK_LAST) wptr <= wptr + (PTR_W+1)'(1);
    end
  end

  rtlnet_ram_core #(
    .RAM_STYLE    (RAM_STYLE),
    .CLOCKING     ("COMMON"),
    .DATA_W       (AXI_DATA_W),
    .ADDR_W       (PTR_W),
    .READ_LATENCY (1)
  ) u_beat_ram (
    .wr_clk    (clk),
    .wr_en     (fifo_wr),
    .wr_addr   (wptr[PTR_W-1:0]),
    .wr_data   (fifo_wdata),
    .rd_clk    (clk),
    .rd_resetn (resetn),
    .rd_en     (fifo_rd),
    .rd_addr   (rptr[PTR_W-1:0]),
    .rd_data   (fifo_rdata)
  );

  // Read-ahead: the RAM output register holds the next W beat; a new read issues when it is empty or being consumed.
  assign fifo_rd = (occ != '0) && (!rd_valid || wfire);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      rptr     <= '0;
      rd_valid <= 1'b0;
    end else begin
      if (fifo_rd) rptr <= rptr + (PTR_W+1)'(1);
      rd_valid <= fifo_rd || (rd_valid && !wfire);
    end
  end

  // ---------------------------------------------------------------------------
  // Write session: AW generation
  // ---------------------------------------------------------------------------
  // The next burst is computed in three registered steps from the address state (line address and beat in line): address and
  // beats left, then the beats to the 4 KiB boundary, then the length. The state is stable for at least three clocks before a
  // burst is issued (calc_cnt), so no step is a long combinational path. A burst needs a few clocks of this; at one stream
  // word per clock a 16-beat burst takes 64 clocks to fill, so the issue rate is not limited by it.
  always_ff @(posedge clk) begin
    cur_addr  <= line_addr + (ADDR_W'(beat_in_line) << BEAT_SHIFT);
    rem_beats <= bpl - beat_in_line;
    to_page   <= TP_W'(PAGE_BEATS) - {1'b0, cur_addr[11:BEAT_SHIFT]};
    burst_len <= len_n;
    last_in_line <= (BPL_W'(len_n) == rem_beats);
  end

  always_comb begin
    len_n = 5'(MAX_BURST_BEATS);
    if (rem_beats < BPL_W'(len_n))  len_n = rem_beats[4:0];
    if (to_page   < TP_W'(len_n))   len_n = to_page[4:0];
  end

  assign aw_load = ws_active && !all_issued && (!m_axi_awvalid || m_axi_awready) && (wq_cnt < 3'(WQ_DEPTH)) &&
                   (b_out < 4'(MAX_B_OUT)) && (calc_cnt == 2'd3) && (uncommitted >= (PTR_W+1)'(burst_len));
  assign wq_push = aw_load;

  assign m_axi_awid    = '0;
  assign m_axi_awsize  = AXI_SIZE;
  assign m_axi_awburst = AXI_INCR;
  assign m_axi_bready  = 1'b1;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      ws_active     <= 1'b0;
      all_issued    <= 1'b0;
      line_addr     <= '0;
      beat_in_line  <= '0;
      lines_left    <= '0;
      uncommitted   <= '0;
      b_out         <= '0;
      m_axi_awvalid <= 1'b0;
      m_axi_awaddr  <= '0;
      m_axi_awlen   <= '0;
      calc_cnt      <= '0;
    end else begin
      // Beats written to the FIFO and not yet committed to an AW.
      case ({fifo_wr, aw_load})
        2'b10:   uncommitted <= uncommitted + (PTR_W+1)'(1);
        2'b01:   uncommitted <= uncommitted - (PTR_W+1)'(burst_len);
        2'b11:   uncommitted <= uncommitted + (PTR_W+1)'(1) - (PTR_W+1)'(burst_len);
        default: ;
      endcase
      // Outstanding bursts: one more at each AW load, one fewer at each response.
      case ({aw_load, m_axi_bvalid})
        2'b10:   b_out <= b_out + 4'd1;
        2'b01:   b_out <= b_out - 4'd1;
        default: ;
      endcase
      if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 1'b0;
      if (calc_cnt != 2'd3) calc_cnt <= calc_cnt + 2'd1;
      if (ev_frame_start) begin
        calc_cnt     <= 2'd0;
        ws_active    <= 1'b1;
        all_issued   <= 1'b0;
        line_addr    <= fb_rsp_base;
        beat_in_line <= '0;
        lines_left   <= sb_height;
        uncommitted  <= '0;
      end
      if (aw_load) begin
        calc_cnt      <= 2'd0;
        m_axi_awvalid <= 1'b1;
        m_axi_awaddr  <= cur_addr;
        m_axi_awlen   <= 8'(burst_len) - 8'd1;
        if (last_in_line) begin
          beat_in_line <= '0;
          line_addr    <= line_addr + stride_q;
          lines_left   <= lines_left - 16'd1;
          if (lines_left == 16'd1) all_issued <= 1'b1;
        end else begin
          beat_in_line <= beat_in_line + BPL_W'(burst_len);
        end
      end
      if (fs == F_DONE) ws_active <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // W channel
  // ---------------------------------------------------------------------------
  assign m_axi_wdata  = fifo_rdata;
  assign m_axi_wstrb  = '1;
  assign m_axi_wvalid = rd_valid && w_active;
  assign m_axi_wlast  = (w_left == 5'd1);
  assign wfire        = m_axi_wvalid && m_axi_wready;
  assign w_load       = (wq_cnt != 3'd0) && (!w_active || (wfire && (w_left == 5'd1)));

  always_ff @(posedge clk) begin
    if (!resetn) begin
      wq_wp    <= '0;
      wq_rp    <= '0;
      wq_cnt   <= '0;
      w_active <= 1'b0;
      w_left   <= '0;
      for (int i = 0; i < WQ_DEPTH; i++) wq_len[i] <= '0;
    end else begin
      if (wq_push) begin
        wq_len[wq_wp] <= burst_len;
        wq_wp         <= wq_wp + 1'b1;
      end
      case ({wq_push, w_load})
        2'b10:   wq_cnt <= wq_cnt + 3'd1;
        2'b01:   wq_cnt <= wq_cnt - 3'd1;
        default: ;
      endcase
      if (w_load) begin
        w_active <= 1'b1;
        w_left   <= wq_len[wq_rp];
        wq_rp    <= wq_rp + 1'b1;
      end else if (wfire) begin
        if (w_left == 5'd1) w_active <= 1'b0;
        w_left <= w_left - 5'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Simulation checks (inert in synthesis)
  // ---------------------------------------------------------------------------
  // synthesis translate_off
  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      if (fifo_wr && (occ == (PTR_W+1)'(FIFO_BEATS)))
        $error("rtlnet_vdma_s2mm: beat FIFO overflow");
      if (fifo_rd && (occ == '0))
        $error("rtlnet_vdma_s2mm: beat FIFO underflow");
      if (wq_push && (wq_cnt == 3'(WQ_DEPTH)))
        $error("rtlnet_vdma_s2mm: W queue overflow");
      if (m_axi_bvalid && (b_out == 4'd0) && !aw_load)
        $error("rtlnet_vdma_s2mm: write response with no burst outstanding");
      if (aw_load && ((13'(cur_addr[11:0]) + 13'(burst_len << BEAT_SHIFT)) > 13'd4096))
        $error("rtlnet_vdma_s2mm: burst crosses a 4 KiB boundary addr 0x%0h len %0d", cur_addr, burst_len);
    end
  end
  // synthesis translate_on

  rtlnet_vdma_s2mm_regs #(
    .MAX_BURST_BEATS (MAX_BURST_BEATS),
    .BEAT_BYTES      (BEAT_BYTES),
    .ADDR_W          (ADDR_W)
  ) u_regs (
    .clk            (clk),
    .resetn         (resetn),
    .reg_wr_en      (reg_wr_en),
    .reg_wr_addr    (reg_wr_addr),
    .reg_wr_data    (reg_wr_data),
    .reg_rd_en      (reg_rd_en),
    .reg_rd_addr    (reg_rd_addr),
    .reg_rd_data    (reg_rd_data),
    .enable         (enable),
    .stride         (stride_reg),
    .st_busy        (fs != F_IDLE),
    .ev_cfg_err     (ev_cfg_err),
    .ev_axi_err     (ev_axi_err),
    .ev_line_err    (ev_line_err),
    .ev_frame_ok    (ev_frame_ok),
    .ev_frame_bad   (ev_frame_bad),
    .ev_frame_drop  (ev_frame_drop),
    .ev_burst       (m_axi_awvalid && m_axi_awready),
    .ev_beat        (wfire),
    .ev_frame_start (ev_frame_start),
    .frame_base     (fb_rsp_base)
  );

endmodule
