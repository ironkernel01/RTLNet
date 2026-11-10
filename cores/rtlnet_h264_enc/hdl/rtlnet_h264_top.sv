// -----------------------------------------------------------------------------
// File: rtlnet_h264_top.sv
// Purpose: H.264 Constrained Baseline encoder core (documentation/gige.md section 10), phase 2b-1: the whole
//   encoder pipeline with I_PCM macroblocks, from the packed YUYV 4:2:2 input frame in memory to the
//   Annex B stream in a compressed ring, the index ring and the rebuilt 4:2:0 picture.
// Overview:
//   * NUM_ENGINES engines, one per slice band (default 2: two engines at 100 MHz carry 1080p30). The picture size,
//     the slice count and the QP are registers, so one build codes 720p30 (80x45 macroblocks, bands of 23 and 22 rows)
//     and 1080p30 (120x68, bands of 34 and 34 rows). The first NUM_ENGINES-1 engines take ceil(MB_H / NUM_ENGINES) rows,
//     the last engine the rest. Each engine codes SLICES / NUM_ENGINES slices and writes its own compressed ring and index
//     ring (the configured rings split equally); engine 0 writes the access unit delimiter. Firmware reads the rings
//     in engine order to form the picture.
//   * Registers on s_axi_aclk behind rtlnet_axil_cdc and rtlnet_axil_slave (4 KiB window, offsets in
//     driver/rtlnet_h264_enc.h); the register file lives in enc_clk. s_axi_aresetn and enc_resetn come from
//     one assertion.
//   * One AXI4 master per engine on enc_clk (vector ports, arbiter style), 128-bit data, for every memory access: INCR full-width bursts of at most 16
//     beats that never cross 4 KiB. The board runs enc_clk from the MIG ui_clk, so these ports reach the DDR3 arbiter directly.
//   * SPS and PPS are written by firmware (driver rtlnet_h264_enc_write_sps_pps()); the core writes the access
//     unit delimiter, the slice NAL units and their index entries.
//   * irq is a level on enc_clk: high while CTRL.IRQ_EN and (STATUS.DONE or STATUS.ERR).
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: enc_clk (engine, memory port, register file); s_axi_aclk (AXI4-Lite slave side of the register
//   crossing only).
// -----------------------------------------------------------------------------
module rtlnet_h264_top #(
  parameter bit    AXIL_SYNC = 1'b0,   // 1: s_axi_aclk is clk (register window without a clock crossing)
  parameter int    NUM_ENGINES = 2,      // slice-band engines, 1..4 (two carry 1080p30 at 100 MHz)
  parameter int    MAX_MB_W    = 120,    // widest picture in macroblocks (1920 / 16)
  parameter int    MAX_MB_H    = 68,     // tallest picture in macroblocks (1088 / 16)
  parameter int    ADDR_W      = 32,
  parameter int    ID_W        = 4,
  parameter int    RD_STRIP_MB = 4,      // macroblocks per input-read burst strip: row bursts of 2 * RD_STRIP_MB beats (2, 4 or 8)
  parameter int    MB_BUF_KB   = 4,      // strip buffer: two halves of RD_STRIP_MB macroblock banks of 32 words (needs >= RD_STRIP_MB KiB)
  parameter int    REC_BUF_KB  = 1,      // rebuilt macroblock buffer: two banks of 96 words of 4 samples
  parameter int    COEF_BUF_KB = 1,      // coefficient buffer: two banks of 102 words of 48 bits (needs 1)
  parameter int    LINE_KB     = 4,      // rebuilt bottom-row line buffer: 2 x 16 bytes per macroblock column
  parameter int    FIFO_KB     = 1,      // compressed-ring word FIFO
  parameter string RAM_STYLE   = "block"  // "block" | "distributed", for every engine memory (RAM instancing rule)
)(
  // Engine clock (MIG ui_clk, 100 MHz) and its reset (synchronous, active low); the register clock and its
  // reset (synchronous, active low, released with enc_resetn from the same assertion).
  input  logic              enc_clk,
  input  logic              enc_resetn,
  input  logic              s_axi_aclk,
  input  logic              s_axi_aresetn,

  // AXI4-Lite slave, s_axi_aclk domain: register window, 4 KiB.
  input  logic [11:0]       s_axi_awaddr,
  input  logic              s_axi_awvalid,
  output logic              s_axi_awready,
  input  logic [31:0]       s_axi_wdata,
  input  logic [3:0]        s_axi_wstrb,
  input  logic              s_axi_wvalid,
  output logic              s_axi_wready,
  output logic [1:0]        s_axi_bresp,
  output logic              s_axi_bvalid,
  input  logic              s_axi_bready,
  input  logic [11:0]       s_axi_araddr,
  input  logic              s_axi_arvalid,
  output logic              s_axi_arready,
  output logic [31:0]       s_axi_rdata,
  output logic [1:0]        s_axi_rresp,
  output logic              s_axi_rvalid,
  input  logic              s_axi_rready,

  // AXI4 masters, enc_clk domain, one per engine, packed as vectors (engine e at [e*W +: W]) for the DDR3
  // arbiter: input-frame reads, compressed-ring, index and rebuilt-picture writes. INCR full-width bursts of at
  // most 16 beats that never cross 4 KiB.
  output logic [NUM_ENGINES*ID_W-1:0]   m_axi_awid,
  output logic [NUM_ENGINES*ADDR_W-1:0] m_axi_awaddr,
  output logic [NUM_ENGINES*8-1:0]      m_axi_awlen,
  output logic [NUM_ENGINES*3-1:0]      m_axi_awsize,
  output logic [NUM_ENGINES*2-1:0]      m_axi_awburst,
  output logic [NUM_ENGINES-1:0]        m_axi_awvalid,
  input  logic [NUM_ENGINES-1:0]        m_axi_awready,
  output logic [NUM_ENGINES*128-1:0]    m_axi_wdata,
  output logic [NUM_ENGINES*16-1:0]     m_axi_wstrb,
  output logic [NUM_ENGINES-1:0]        m_axi_wlast,
  output logic [NUM_ENGINES-1:0]        m_axi_wvalid,
  input  logic [NUM_ENGINES-1:0]        m_axi_wready,
  input  logic [NUM_ENGINES*ID_W-1:0]   m_axi_bid,
  input  logic [NUM_ENGINES*2-1:0]      m_axi_bresp,
  input  logic [NUM_ENGINES-1:0]        m_axi_bvalid,
  output logic [NUM_ENGINES-1:0]        m_axi_bready,
  output logic [NUM_ENGINES*ID_W-1:0]   m_axi_arid,
  output logic [NUM_ENGINES*ADDR_W-1:0] m_axi_araddr,
  output logic [NUM_ENGINES*8-1:0]      m_axi_arlen,
  output logic [NUM_ENGINES*3-1:0]      m_axi_arsize,
  output logic [NUM_ENGINES*2-1:0]      m_axi_arburst,
  output logic [NUM_ENGINES-1:0]        m_axi_arvalid,
  input  logic [NUM_ENGINES-1:0]        m_axi_arready,
  input  logic [NUM_ENGINES*128-1:0]    m_axi_rdata,
  input  logic [NUM_ENGINES*2-1:0]      m_axi_rresp,
  input  logic [NUM_ENGINES-1:0]        m_axi_rlast,
  input  logic [NUM_ENGINES-1:0]        m_axi_rvalid,
  output logic [NUM_ENGINES-1:0]        m_axi_rready,

  // Picture-done and error interrupt, enc_clk domain, level.
  output logic              irq
);

  import rtlnet_h264_pkg::*;

  generate
    if (NUM_ENGINES < 1 || NUM_ENGINES > 4) begin : g_bad_engines
      $fatal(1, "rtlnet_h264_top: NUM_ENGINES=%0d, must be 1..4", NUM_ENGINES);
    end
    if (ADDR_W != 32) begin : g_bad_addr
      $fatal(1, "rtlnet_h264_top: ADDR_W=%0d, only 32 is supported", ADDR_W);
    end
    if (RD_STRIP_MB != 2 && RD_STRIP_MB != 4 && RD_STRIP_MB != 8) begin : g_bad_strip
      $fatal(1, "rtlnet_h264_top: RD_STRIP_MB=%0d, must be 2, 4 or 8", RD_STRIP_MB);
    end
    if (MB_BUF_KB < RD_STRIP_MB) begin : g_bad_mbbuf
      $fatal(1, "rtlnet_h264_top: MB_BUF_KB=%0d, the strip buffer needs at least RD_STRIP_MB=%0d KiB", MB_BUF_KB, RD_STRIP_MB);
    end
  endgenerate

  // Register crossing wires (enc_clk side).
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

  // Register file outputs.
  logic        start;
  logic        ring_reset;
  logic [7:0]  cfg_mb_w;
  logic [7:0]  cfg_mb_h;
  logic [7:0]  cfg_slices;
  logic [31:0] cfg_in_base;
  logic [31:0] cfg_in_stride;
  logic [31:0] cfg_ry_base;
  logic [31:0] cfg_ru_base;
  logic [5:0]  cfg_qp;
  logic        cfg_mb_pcm;
  logic [15:0] cfg_frame_num;
  logic [15:0] cfg_idr_pic_id;
  logic        cfg_idr;
  logic [4:0]  cfg_log2_fn;
  logic [15:0] cfg_pic_no;
  logic [31:0] cfg_ring_base;
  logic [31:0] cfg_ring_size;
  logic [31:0] cfg_idx_base;
  logic [31:0] cfg_idx_entries;
  logic [NUM_ENGINES-1:0]    rptr_wr;
  logic [NUM_ENGINES*32-1:0] rptr_val;
  logic [NUM_ENGINES-1:0]    idx_rptr_wr;
  logic [NUM_ENGINES*32-1:0] idx_rptr_val;

  // Per-engine status and statistics, packed (engine e at [e*32 +: 32]).
  logic [NUM_ENGINES-1:0]    eng_busy;
  logic [NUM_ENGINES-1:0]    eng_done;
  logic [NUM_ENGINES-1:0]    eng_slice;
  logic [NUM_ENGINES-1:0]    eng_err_cfg;
  logic [NUM_ENGINES-1:0]    eng_err_axi;
  logic [NUM_ENGINES-1:0]    eng_err_rp;
  logic [NUM_ENGINES-1:0]    eng_err_bsy;
  logic [NUM_ENGINES-1:0]    eng_stall;
  logic [NUM_ENGINES*32-1:0] eng_wptr;
  logic [NUM_ENGINES*32-1:0] eng_fill;
  logic [NUM_ENGINES*32-1:0] eng_iwptr;
  logic [NUM_ENGINES*32-1:0] eng_ifill;
  logic [NUM_ENGINES*32-1:0] eng_mbs;
  logic [NUM_ENGINES*32-1:0] eng_clast;
  logic [NUM_ENGINES*32-1:0] eng_cmax;
  logic [NUM_ENGINES*32-1:0] eng_pcyc;
  logic [NUM_ENGINES*32-1:0] eng_rcyc;
  logic [NUM_ENGINES*32-1:0] eng_kcyc;
  logic [NUM_ENGINES*32-1:0] eng_wcyc;

  // Picture completion: every engine must report done; busy stays high until the combined done pulse.
  logic [NUM_ENGINES-1:0]    done_flags;
  logic                      done_all;
  logic                      busy_all;

  // Slice bands, from the picture-size and slice registers: the first NUM_ENGINES-1 engines code
  // ceil(MB_H / NUM_ENGINES) rows each, the last engine the rest. Each engine codes SLICES / NUM_ENGINES slices (SLICES
  // not a multiple of NUM_ENGINES gives 0, which an engine rejects at start), and owns an equal share of the ring and
  // of the index ring.
  logic [7:0]  rows_c;
  logic [7:0]  band_first [NUM_ENGINES];
  logic [7:0]  band_rows  [NUM_ENGINES];
  logic [7:0]  eng_slices_w;
  logic [7:0]  slice_base [NUM_ENGINES];
  logic [31:0] ring_size_e;
  logic [31:0] idx_entries_e;

  always_comb begin
    rows_c        = 8'((int'(cfg_mb_h) + NUM_ENGINES - 1) / NUM_ENGINES);
    eng_slices_w  = ((int'(cfg_slices) % NUM_ENGINES) == 0) ? 8'(int'(cfg_slices) / NUM_ENGINES) : 8'd0;
    ring_size_e   = cfg_ring_size / 32'(NUM_ENGINES);
    idx_entries_e = cfg_idx_entries / 32'(NUM_ENGINES);
    for (int k = 0; k < NUM_ENGINES; k++) begin
      band_first[k] = 8'(k * int'(rows_c));
      if ((k * int'(rows_c)) >= int'(cfg_mb_h)) band_rows[k] = 8'd0;
      else if (k < NUM_ENGINES - 1)             band_rows[k] = rows_c;
      else                                      band_rows[k] = 8'(int'(cfg_mb_h) - k * int'(rows_c));
      slice_base[k] = 8'(k * int'(eng_slices_w));
    end
  end

  assign busy_all = (|eng_busy) || done_all;

  always_ff @(posedge enc_clk) begin
    if (!enc_resetn) begin
      done_flags <= '0;
      done_all   <= 1'b0;
    end else begin
      done_all <= 1'b0;
      if (start) begin
        done_flags <= '0;
      end else begin
        done_flags <= done_flags | eng_done;
        if (((done_flags | eng_done) == {NUM_ENGINES{1'b1}}) && (done_flags != {NUM_ENGINES{1'b1}})) done_all <= 1'b1;
      end
    end
  end

  rtlnet_axil_cdc #(.ADDR_W(12), .SYNC(AXIL_SYNC)) u_axil_cdc (
    .s_clk(s_axi_aclk), .s_resetn(s_axi_aresetn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .m_clk(enc_clk), .m_resetn(enc_resetn),
    .m_axi_awaddr(c_awaddr), .m_axi_awvalid(c_awvalid), .m_axi_awready(c_awready),
    .m_axi_wdata(c_wdata), .m_axi_wstrb(c_wstrb), .m_axi_wvalid(c_wvalid), .m_axi_wready(c_wready),
    .m_axi_bresp(c_bresp), .m_axi_bvalid(c_bvalid), .m_axi_bready(c_bready),
    .m_axi_araddr(c_araddr), .m_axi_arvalid(c_arvalid), .m_axi_arready(c_arready),
    .m_axi_rdata(c_rdata), .m_axi_rresp(c_rresp), .m_axi_rvalid(c_rvalid), .m_axi_rready(c_rready)
  );

  rtlnet_axil_slave #(.ADDR_W(12)) u_axil_slave (
    .s_axi_aclk(enc_clk), .s_axi_aresetn(enc_resetn),
    .s_axi_awaddr(c_awaddr), .s_axi_awvalid(c_awvalid), .s_axi_awready(c_awready),
    .s_axi_wdata(c_wdata), .s_axi_wstrb(c_wstrb), .s_axi_wvalid(c_wvalid), .s_axi_wready(c_wready),
    .s_axi_bresp(c_bresp), .s_axi_bvalid(c_bvalid), .s_axi_bready(c_bready),
    .s_axi_araddr(c_araddr), .s_axi_arvalid(c_arvalid), .s_axi_arready(c_arready),
    .s_axi_rdata(c_rdata), .s_axi_rresp(c_rresp), .s_axi_rvalid(c_rvalid), .s_axi_rready(c_rready),
    .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data)
  );

  rtlnet_h264_enc_regs #(.MAX_MB_W(MAX_MB_W), .MAX_MB_H(MAX_MB_H), .NUM_ENGINES(NUM_ENGINES)) u_regs (
    .clk(enc_clk), .resetn(enc_resetn),
    .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data),
    .start(start), .ring_reset(ring_reset),
    .cfg_mb_w(cfg_mb_w), .cfg_mb_h(cfg_mb_h), .cfg_slices(cfg_slices),
    .cfg_in_base(cfg_in_base), .cfg_in_stride(cfg_in_stride),
    .cfg_ry_base(cfg_ry_base), .cfg_ru_base(cfg_ru_base),
    .cfg_qp(cfg_qp), .cfg_mb_pcm(cfg_mb_pcm), .cfg_frame_num(cfg_frame_num),
    .cfg_idr_pic_id(cfg_idr_pic_id),
    .cfg_idr(cfg_idr), .cfg_log2_fn(cfg_log2_fn), .cfg_pic_no(cfg_pic_no),
    .cfg_ring_base(cfg_ring_base), .cfg_ring_size(cfg_ring_size), .cfg_idx_base(cfg_idx_base),
    .cfg_idx_entries(cfg_idx_entries),
    .rptr_wr(rptr_wr), .rptr_val(rptr_val), .idx_rptr_wr(idx_rptr_wr), .idx_rptr_val(idx_rptr_val),
    .busy(busy_all), .done(done_all), .slice_pulse(|eng_slice),
    .err_cfg(|eng_err_cfg), .err_axi(|eng_err_axi), .err_rptr(|eng_err_rp), .err_busy(|eng_err_bsy),
    .ring_stall(eng_stall), .ring_wptr(eng_wptr), .ring_fill(eng_fill), .idx_wptr(eng_iwptr),
    .idx_fill(eng_ifill), .st_mb_count(eng_mbs), .st_cyc_last(eng_clast), .st_cyc_max(eng_cmax),
    .st_pic_cyc(eng_pcyc), .st_rd_cyc(eng_rcyc), .st_pk_cyc(eng_kcyc), .st_wr_cyc(eng_wcyc),
    .irq(irq)
  );

  genvar e;
  generate
    for (e = 0; e < NUM_ENGINES; e++) begin : g_engine
      rtlnet_h264_engine #(
        .ADDR_W(ADDR_W), .ID_W(ID_W), .MAX_MB_W(MAX_MB_W), .MAX_MB_H(MAX_MB_H), .MB_BUF_KB(MB_BUF_KB), .RD_STRIP_MB(RD_STRIP_MB),
        .REC_BUF_KB(REC_BUF_KB), .COEF_BUF_KB(COEF_BUF_KB), .LINE_KB(LINE_KB), .FIFO_KB(FIFO_KB), .EMIT_AUD(e == 0), .RAM_STYLE(RAM_STYLE)
      ) u_engine (
        .clk(enc_clk), .resetn(enc_resetn),
        .start(start), .busy(eng_busy[e]), .done(eng_done[e]), .err_cfg(eng_err_cfg[e]), .err_axi(eng_err_axi[e]),
        .err_rptr(eng_err_rp[e]), .err_busy(eng_err_bsy[e]),
        .cfg_mb_w(cfg_mb_w), .cfg_mb_h(cfg_mb_h), .eng_slices(eng_slices_w), .slice_base(slice_base[e]),
        .cfg_in_base(cfg_in_base),
        .cfg_in_stride(cfg_in_stride), .cfg_ry_base(cfg_ry_base),
        .cfg_ru_base(cfg_ru_base), .cfg_qp(cfg_qp), .cfg_mb_pcm(cfg_mb_pcm),
        .cfg_frame_num(cfg_frame_num), .cfg_idr_pic_id(cfg_idr_pic_id), .cfg_idr(cfg_idr), .cfg_log2_fn(cfg_log2_fn),
        .cfg_pic_no(cfg_pic_no), .band_first_row(band_first[e]), .band_rows(band_rows[e]),
        .cfg_ring_base(cfg_ring_base + 32'(e) * ring_size_e), .cfg_ring_size(ring_size_e),
        .cfg_idx_base(cfg_idx_base + 32'(e) * idx_entries_e * 32'(IDX_REC_BYTES)), .cfg_idx_entries(idx_entries_e),
        .ring_reset(ring_reset), .rptr_wr(rptr_wr[e]), .rptr_val(rptr_val[e*32 +: 32]),
        .idx_rptr_wr(idx_rptr_wr[e]), .idx_rptr_val(idx_rptr_val[e*32 +: 32]),
        .ring_wptr(eng_wptr[e*32 +: 32]), .ring_fill(eng_fill[e*32 +: 32]), .idx_wptr(eng_iwptr[e*32 +: 32]),
        .idx_fill(eng_ifill[e*32 +: 32]), .ring_stall(eng_stall[e]), .st_mb_count(eng_mbs[e*32 +: 32]),
        .st_slice_pulse(eng_slice[e]), .st_cyc_last(eng_clast[e*32 +: 32]), .st_cyc_max(eng_cmax[e*32 +: 32]),
        .st_pic_cyc(eng_pcyc[e*32 +: 32]), .st_rd_cyc(eng_rcyc[e*32 +: 32]), .st_pk_cyc(eng_kcyc[e*32 +: 32]),
        .st_wr_cyc(eng_wcyc[e*32 +: 32]),
        .m_arid(m_axi_arid[e*ID_W +: ID_W]), .m_araddr(m_axi_araddr[e*ADDR_W +: ADDR_W]),
        .m_arlen(m_axi_arlen[e*8 +: 8]), .m_arsize(m_axi_arsize[e*3 +: 3]), .m_arburst(m_axi_arburst[e*2 +: 2]),
        .m_arvalid(m_axi_arvalid[e]), .m_arready(m_axi_arready[e]),
        .m_rdata(m_axi_rdata[e*128 +: 128]), .m_rresp(m_axi_rresp[e*2 +: 2]), .m_rlast(m_axi_rlast[e]),
        .m_rvalid(m_axi_rvalid[e]), .m_rready(m_axi_rready[e]),
        .m_awid(m_axi_awid[e*ID_W +: ID_W]), .m_awaddr(m_axi_awaddr[e*ADDR_W +: ADDR_W]),
        .m_awlen(m_axi_awlen[e*8 +: 8]), .m_awsize(m_axi_awsize[e*3 +: 3]), .m_awburst(m_axi_awburst[e*2 +: 2]),
        .m_awvalid(m_axi_awvalid[e]), .m_awready(m_axi_awready[e]),
        .m_wdata(m_axi_wdata[e*128 +: 128]), .m_wstrb(m_axi_wstrb[e*16 +: 16]), .m_wlast(m_axi_wlast[e]),
        .m_wvalid(m_axi_wvalid[e]), .m_wready(m_axi_wready[e]),
        .m_bid(m_axi_bid[e*ID_W +: ID_W]), .m_bresp(m_axi_bresp[e*2 +: 2]), .m_bvalid(m_axi_bvalid[e]),
        .m_bready(m_axi_bready[e])
      );
    end
  endgenerate

endmodule
