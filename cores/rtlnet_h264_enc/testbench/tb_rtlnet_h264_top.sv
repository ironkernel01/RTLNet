// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_top.sv
// Purpose: bench of rtlnet_h264_top: loads input frames into a memory model, programs the core through its
//   AXI4-Lite port, runs one or two pictures, plays the firmware's part (reads the index ring, copies each
//   slice out of the compressed ring, advances the read pointers), and writes the Annex B stream and the
//   rebuilt planes for the decoder harness (scripts in this directory).
// Overview:
//   * Configuration by defines: TB_MBW, TB_MBH (picture size in macroblocks), TB_SLICES, TB_PICS (pictures per run),
//     TB_QP, TB_RING_KB (compressed ring size), TB_CONSUMER_DELAY (clocks between firmware polls),
//     TB_LAT (memory read latency), TB_GAP (percent of clocks without ready/valid on the memory port),
//     TB_MEM_LOG2 (memory model size in 16-byte words, power of two).
//   * Plusargs: +INPFX=<path prefix>: the input of picture n is the hex file <prefix><n>.hex, loaded into the one input buffer
//     just before the picture starts; +GOP=<string of I and P, one letter per picture> (default all I): an I picture is an IDR
//     picture (frame_num 0, idr_pic_id counting the IDR pictures), a P picture is a non-IDR picture with frame_num counting the
//     pictures since the last IDR modulo 16, coded against the previous picture's rebuilt picture; +OUT=<path prefix>
//     for <prefix>_stream.hex, <prefix>_rec<n>.hex and <prefix>_info.txt, +INJECT flips one bit of one residual
//     (coefficient or sample) byte inside the first slice, after the rebuilt picture is written (the harness negative
//     control: every decoder must then differ from the rebuilt picture or report an error), +INJECT_FAILURE forces a
//     failed check (the bench negative control).
//   * TB_PCM (define, 1; the MB_MODE note): the bench writes MB_MODE (register 0x03C, bit 0 = 1) before the pictures, which selects the
//     I_PCM macroblock mode (debug fallback). With TB_PCM undefined the register is not written (reset value 0 =
//     intra 16x16 macroblocks, and an RTL without the register works too).
//   * Two rebuilt buffers: picture n writes buffer n mod 2 (RY/RU base registers) and a P picture reads the other one as its
//     reference (REF_Y_BASE / REF_U_BASE), so the previous picture's rebuilt tiles stay in the memory model; every picture's
//     rebuilt planes are dumped after it is done.
//   * Input memory format: packed YUYV 4:2:2, byte order Y0 U0 Y1 V0, line stride MBW * 32 bytes, as
//     128-bit words, byte 0 in bits [7:0], one word per hex line ($readmemh).
//   * Memory map built from the picture size (all 4 KiB aligned): the input buffer, the two rebuilt pictures as macroblock tiles
//     (luma 256 B and chroma 128 B per macroblock, raster order, luma and chroma tile areas of each), compressed ring, index ring
//     (64 records of 128 bytes). The input lines are padded to a multiple of 128 bytes (the strip burst size): the
//     generator's dense hex file is spread to that stride after loading. The rebuilt planes are de-tiled when they are
//     dumped (dense planes: Y stride MBW * 16, Cb and Cr stride ceil16(MBW * 8)), so the decoder harness compares them
//     unchanged.
//   * Burst monitor (tb_h264_burst_mon) on every encoder AXI port: fails on any single-beat read, index or rebuilt-picture
//     write and prints the beat-count histogram per master at the end; +INJECT_BURST forces one single-beat AW into the
//     monitor's view (its negative control: the bench must then fail).
//   * Checks: register reads, no error flag, per-slice index entries and the picture entry, NAL framing and the
//     slice header's first_mb_in_slice against an independent computation, read-pointer protocol, the AXI protocol
//     checks of the memory model, and the RTL assertions.
//   * TB_DEBUG_MB (define): prints one DBGMB line per macroblock of engine 0 (mode, skip, coded block pattern, size estimate), for
//     the investigation of the mode decision; it reads internal signals of the engine and is off by default.
//   * Motion statistics (phase 2c-2): +EXPMV_X=<n> +EXPMV_Y=<n> (whole samples) name the expected motion vector of a panning sequence; at
//     the end of every P picture the bench prints `MVSTAT pic<n> interior=<I> true=<T>`: I the macroblocks (all engines) whose
//     block at that vector lies inside the picture, T those among them that the encoder coded as inter with exactly that vector (a
//     P_Skip counts with its skip vector). The harness requires T >= 90 % of I for every P picture. TB_SR (define, default 16) sets the
//     search range of the core (0: only the vector (0, 0), the phase 2c-1 behaviour: the baseline of the bits gate).
//   * Race-free: every bench output changes at the falling clock edge and every input is sampled there.
// Language: SystemVerilog-2012 (simulation only; Verilator 5 --timing and Active-HDL).
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-10-2026: tiled rebuilt picture, 128-byte index records, padded input stride, burst monitor.
//   * 11-10-2026: phase 2c-1: GOPs of I and P pictures, two rebuilt buffers, one input buffer reloaded per picture.
//   * 11-10-2026: phase 2c-2: motion statistics (MVSTAT), TB_SR.
// Clocks: enc_clk 150 MHz, s_axi_aclk 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_MBW
  `define TB_MBW 11
`endif
`ifndef TB_MBH
  `define TB_MBH 9
`endif
`ifndef TB_SLICES
  `define TB_SLICES 1
`endif
`ifndef TB_PICS
  `define TB_PICS 1
`endif
`ifndef TB_QP
  `define TB_QP 26
`endif
`ifndef TB_RING_KB
  `define TB_RING_KB 4096
`endif
`ifndef TB_CONSUMER_DELAY
  `define TB_CONSUMER_DELAY 0
`endif
`ifndef TB_LAT
  `define TB_LAT 20
`endif
`ifndef TB_GAP
  `define TB_GAP 20
`endif
`ifndef TB_ENGINES
  `define TB_ENGINES 1
`endif
`ifndef TB_MEM_LOG2
  `define TB_MEM_LOG2 20
`endif
`ifndef TB_HIGH_PROFILE
  `define TB_HIGH_PROFILE 1'b0
`endif
`ifndef TB_SR
  `define TB_SR 16
`endif

module tb_rtlnet_h264_top;

  import rtlnet_tb_pkg::*;

  localparam int MBW      = `TB_MBW;
  localparam int MBH      = `TB_MBH;
  localparam int SLICES   = `TB_SLICES;
  localparam int PICS     = `TB_PICS;
  localparam int NE       = `TB_ENGINES;
  localparam int SE       = SLICES / NE;
  localparam int MID_W    = 4 + ((NE > 1) ? $clog2(NE) : 1);
  localparam int QP       = `TB_QP;
  localparam int RING_KB  = `TB_RING_KB;
  localparam int IDX_ENTRIES = 64;
  localparam int IDX_REC     = 128;      // bytes per index record
  localparam int STRIP_BYTES = 128;      // input line padding (RD_STRIP_MB * 32)
`ifndef TB_MAX_CLK
  `define TB_MAX_CLK 150_000_000
`endif
  localparam int MAX_CLK  = `TB_MAX_CLK;

  // Register offsets (mirror driver/rtlnet_h264_enc.h).
  localparam logic [11:0] R_ID = 12'h000, R_VERSION = 12'h004, R_CAPS = 12'h008, R_CTRL = 12'h00C,
                          R_STATUS = 12'h010, R_ERR_CODE = 12'h014, R_MB_W = 12'h020, R_MB_H = 12'h024,
                          R_SLICES = 12'h028, R_QP = 12'h02C, R_FRAME_NUM = 12'h030, R_IDR_PIC_ID = 12'h034,
                          R_PIC_CFG = 12'h038, R_MB_MODE = 12'h03C, R_IN_BASE = 12'h040, R_IN_STRIDE = 12'h044, R_RY_BASE = 12'h048,
                          R_RU_BASE = 12'h050, R_REFY_BASE = 12'h054, R_REFU_BASE = 12'h058,
                          R_RING_BASE = 12'h060, R_RING_SIZE = 12'h064, R_RING_WPTR = 12'h068,
                          R_RING_RPTR = 12'h06C, R_RING_FILL = 12'h070, R_IDX_BASE = 12'h078,
                          R_IDX_ENTRIES = 12'h07C, R_IDX_WPTR = 12'h080, R_IDX_RPTR = 12'h084,
                          R_PIC_COUNT = 12'h090, R_SLICE_COUNT = 12'h094, R_MB_COUNT = 12'h098,
                          R_CYC_LAST = 12'h09C, R_CYC_MAX = 12'h0A0, R_PIC_CYC = 12'h0A4, R_RD_CYC = 12'h0A8,
                          R_PK_CYC = 12'h0AC, R_WR_CYC = 12'h0B0;

  // Clocks and reset.
  logic enc_clk = 1'b0;
  logic s_clk   = 1'b0;
  logic resetn  = 1'b0;
  always #3.333 enc_clk = ~enc_clk;
  always #5.0   s_clk   = ~s_clk;

  // AXI4-Lite master signals (s_clk).
  logic [11:0] awaddr = '0;
  logic        awvalid_l = 1'b0;
  logic        awready_l;
  logic [31:0] wdata_l = '0;
  logic        wvalid_l = 1'b0;
  logic        wready_l;
  logic [1:0]  bresp_l;
  logic        bvalid_l;
  logic [11:0] araddr = '0;
  logic        arvalid_l = 1'b0;
  logic        arready_l;
  logic [31:0] rdata_l;
  logic [1:0]  rresp_l;
  logic        rvalid_l;

  // Encoder-side memory ports (one per engine, packed) and the memory-controller side behind the arbiter.
  logic [NE*4-1:0]   e_awid, e_bid, e_arid;
  logic [NE*32-1:0]  e_awaddr, e_araddr;
  logic [NE*8-1:0]   e_awlen, e_arlen;
  logic [NE*3-1:0]   e_awsize, e_arsize;
  logic [NE*2-1:0]   e_awburst, e_arburst, e_bresp, e_rresp;
  logic [NE-1:0]     e_awvalid, e_awready, e_wlast, e_wvalid, e_wready, e_bvalid, e_bready;
  logic [NE-1:0]     e_arvalid, e_arready, e_rlast, e_rvalid, e_rready;
  logic [NE*128-1:0] e_wdata, e_rdata;
  logic [NE*16-1:0]  e_wstrb;
  logic [NE*4-1:0]   e_rid;
  logic [MID_W-1:0]  awid, bid, arid, rid;
  logic [31:0]       awaddr_m, araddr_m;
  logic [7:0]        awlen, arlen;
  logic [2:0]        awsize, arsize;
  logic [1:0]        awburst, arburst, bresp_m, rresp_m;
  logic              awvalid_m, awready_m, wlast, wvalid_m, wready_m, bvalid_m, bready_m;
  logic              arvalid_m, arready_m, rlast, rvalid_m, rready_m;
  logic [127:0]      wdata_m, rdata_m;
  logic [15:0]       wstrb_m;
  logic              irq;

  rtlnet_h264_top #(.NUM_ENGINES(NE), .SR(`TB_SR), .HIGH_PROFILE(`TB_HIGH_PROFILE)) dut (
    .enc_clk(enc_clk), .enc_resetn(resetn), .s_axi_aclk(s_clk), .s_axi_aresetn(resetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid_l), .s_axi_awready(awready_l),
    .s_axi_wdata(wdata_l), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid_l), .s_axi_wready(wready_l),
    .s_axi_bresp(bresp_l), .s_axi_bvalid(bvalid_l), .s_axi_bready(1'b1),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid_l), .s_axi_arready(arready_l),
    .s_axi_rdata(rdata_l), .s_axi_rresp(rresp_l), .s_axi_rvalid(rvalid_l), .s_axi_rready(1'b1),
    .m_axi_awid(e_awid), .m_axi_awaddr(e_awaddr), .m_axi_awlen(e_awlen), .m_axi_awsize(e_awsize),
    .m_axi_awburst(e_awburst), .m_axi_awvalid(e_awvalid), .m_axi_awready(e_awready),
    .m_axi_wdata(e_wdata), .m_axi_wstrb(e_wstrb), .m_axi_wlast(e_wlast), .m_axi_wvalid(e_wvalid),
    .m_axi_wready(e_wready), .m_axi_bid(e_bid), .m_axi_bresp(e_bresp), .m_axi_bvalid(e_bvalid),
    .m_axi_bready(e_bready),
    .m_axi_arid(e_arid), .m_axi_araddr(e_araddr), .m_axi_arlen(e_arlen), .m_axi_arsize(e_arsize),
    .m_axi_arburst(e_arburst), .m_axi_arvalid(e_arvalid), .m_axi_arready(e_arready),
    .m_axi_rdata(e_rdata), .m_axi_rresp(e_rresp), .m_axi_rlast(e_rlast), .m_axi_rvalid(e_rvalid),
    .m_axi_rready(e_rready), .irq(irq)
  );

  // The shared DDR3 arbiter (rtlnet_axi_arbiter) sits between the engines and the memory model: it checks the same
  // burst rules a non-narrow master must meet (INCR, full width, no 4 KiB crossing) and rejects any other burst.
  logic [11:0] arb_s_awaddr = '0;
  logic [31:0] arb_s_wdata = '0;
  logic [11:0] arb_s_araddr = '0;
  logic        arb_s_awready, arb_s_wready, arb_s_bvalid, arb_s_arready, arb_s_rvalid;
  logic [1:0]  arb_s_bresp, arb_s_rresp;
  logic [31:0] arb_s_rdata;

  rtlnet_axi_arbiter #(
    .NUM_MASTERS(NE), .ADDR_W(32), .DATA_W(128), .ID_W(4), .HIGH_PRIO_MASK('0), .MAX_OUTSTANDING(8)
  ) u_arb (
    .clk(enc_clk), .resetn(resetn), .s_axi_aclk(s_clk), .s_axi_aresetn(resetn),
    .s_awid(e_awid), .s_awaddr(e_awaddr), .s_awlen(e_awlen), .s_awsize(e_awsize), .s_awburst(e_awburst),
    .s_awvalid(e_awvalid), .s_awready(e_awready),
    .s_wdata(e_wdata), .s_wstrb(e_wstrb), .s_wlast(e_wlast), .s_wvalid(e_wvalid), .s_wready(e_wready),
    .s_bid(e_bid), .s_bresp(e_bresp), .s_bvalid(e_bvalid), .s_bready(e_bready),
    .s_arid(e_arid), .s_araddr(e_araddr), .s_arlen(e_arlen), .s_arsize(e_arsize), .s_arburst(e_arburst),
    .s_arvalid(e_arvalid), .s_arready(e_arready),
    .s_rid(e_rid), .s_rdata(e_rdata), .s_rresp(e_rresp), .s_rlast(e_rlast), .s_rvalid(e_rvalid), .s_rready(e_rready),
    .m_axi_awid(awid), .m_axi_awaddr(awaddr_m), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
    .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(), .m_axi_awvalid(awvalid_m),
    .m_axi_awready(awready_m),
    .m_axi_wdata(wdata_m), .m_axi_wstrb(wstrb_m), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid_m),
    .m_axi_wready(wready_m),
    .m_axi_bid(bid), .m_axi_bresp(bresp_m), .m_axi_bvalid(bvalid_m), .m_axi_bready(bready_m),
    .m_axi_arid(arid), .m_axi_araddr(araddr_m), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst),
    .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(), .m_axi_arvalid(arvalid_m),
    .m_axi_arready(arready_m),
    .m_axi_rid(rid), .m_axi_rdata(rdata_m), .m_axi_rresp(rresp_m), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid_m),
    .m_axi_rready(rready_m),
    .s_axi_awaddr(arb_s_awaddr), .s_axi_awvalid(1'b0), .s_axi_awready(arb_s_awready),
    .s_axi_wdata(arb_s_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(1'b0), .s_axi_wready(arb_s_wready),
    .s_axi_bresp(arb_s_bresp), .s_axi_bvalid(arb_s_bvalid), .s_axi_bready(1'b1),
    .s_axi_araddr(arb_s_araddr), .s_axi_arvalid(1'b0), .s_axi_arready(arb_s_arready),
    .s_axi_rdata(arb_s_rdata), .s_axi_rresp(arb_s_rresp), .s_axi_rvalid(arb_s_rvalid), .s_axi_rready(1'b1)
  );

  tb_h264_axi_mem #(.WORDS_LOG2(`TB_MEM_LOG2), .ID_W(MID_W), .READ_LAT(`TB_LAT), .GAP_PCT(`TB_GAP)) u_mem (
    .clk(enc_clk), .resetn(resetn),
    .awid(awid), .awaddr(awaddr_m), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid_m),
    .awready(awready_m), .wdata(wdata_m), .wstrb(wstrb_m), .wlast(wlast), .wvalid(wvalid_m), .wready(wready_m),
    .bid(bid), .bresp(bresp_m), .bvalid(bvalid_m), .bready(bready_m),
    .arid(arid), .araddr(araddr_m), .arlen(arlen), .arsize(arsize), .arburst(arburst), .arvalid(arvalid_m),
    .arready(arready_m), .rid(rid), .rdata(rdata_m), .rresp(rresp_m), .rlast(rlast), .rvalid(rvalid_m),
    .rready(rready_m)
  );

  // ---------------------------------------------------------------------------
  // AXI4-Lite tasks (s_clk, race-free)
  // ---------------------------------------------------------------------------
  task automatic reg_write(input logic [11:0] addr, input logic [31:0] data);
    bit a_hs, w_hs, a_done, w_done;
    int t;
    @(negedge s_clk);
    awaddr = addr; awvalid_l = 1'b1; wdata_l = data; wvalid_l = 1'b1;
    a_done = 0; w_done = 0; t = 0;
    while (!(a_done && w_done) && t < 20000) begin
      a_hs = !a_done && awready_l;
      w_hs = !w_done && wready_l;
      @(negedge s_clk);
      if (a_hs) begin awvalid_l = 1'b0; a_done = 1; end
      if (w_hs) begin wvalid_l = 1'b0; w_done = 1; end
      t++;
    end
    t = 0;
    while (!bvalid_l && t < 20000) begin @(negedge s_clk); t++; end
    tb_check(bvalid_l && (bresp_l == 2'b00), $sformatf("register write 0x%03x response", addr));
    @(negedge s_clk);
  endtask

  task automatic reg_read(input logic [11:0] addr, output logic [31:0] data);
    bit hs;
    int t;
    @(negedge s_clk);
    araddr = addr; arvalid_l = 1'b1;
    hs = 0; t = 0;
    while (!hs && t < 20000) begin
      hs = arready_l;
      @(negedge s_clk);
      t++;
    end
    arvalid_l = 1'b0;
    t = 0;
    while (!rvalid_l && t < 20000) begin @(negedge s_clk); t++; end
    data = rdata_l;
    tb_check(rvalid_l && (rresp_l == 2'b00), $sformatf("register read 0x%03x response", addr));
    @(negedge s_clk);
  endtask

  // ---------------------------------------------------------------------------
  // Memory map
  // ---------------------------------------------------------------------------
  function automatic int unsigned align4k(input int unsigned v);
    return (v + 4095) & ~32'hFFF;
  endfunction

  int unsigned IN_STRIDE, IN_SIZE, RY_STRIDE, RY_SIZE, RC_STRIDE, RC_SIZE;
  int unsigned IN0_BASE, RYA_BASE, RUA_BASE, RYB_BASE, RUB_BASE, RING_BASE, RING_SIZE, IDX_BASE, MEM_END;
  int unsigned IN_DENSE;

  task automatic build_map();
    IN_DENSE  = MBW * 32;
    IN_STRIDE = (IN_DENSE + STRIP_BYTES - 1) / STRIP_BYTES * STRIP_BYTES;
    IN_SIZE   = IN_STRIDE * MBH * 16;
    RY_STRIDE = MBW * 16;
    RY_SIZE   = RY_STRIDE * MBH * 16;
    RC_STRIDE = ((MBW * 8) + 15) & ~15;
    RC_SIZE   = RC_STRIDE * MBH * 8;
    IN0_BASE  = 0;
    RYA_BASE  = align4k(IN0_BASE + IN_SIZE);
    RUA_BASE  = align4k(RYA_BASE + MBW * MBH * 256);
    RYB_BASE  = align4k(RUA_BASE + MBW * MBH * 128);
    RUB_BASE  = align4k(RYB_BASE + MBW * MBH * 256);
    RING_BASE = align4k(RUB_BASE + MBW * MBH * 128);
    RING_SIZE = RING_KB * 1024;
    IDX_BASE  = align4k(RING_BASE + RING_SIZE);
    MEM_END   = IDX_BASE + IDX_ENTRIES * IDX_REC;
  endtask

  // ---------------------------------------------------------------------------
  // Reference slice geometry and bit reader
  // ---------------------------------------------------------------------------
  // Band of engine e: the first NE-1 engines take ceil(MBH / NE) rows, the last the rest.
  function automatic int band_first_row(input int e);
    return e * ((MBH + NE - 1) / NE);
  endfunction

  function automatic int band_rows_of(input int e);
    if (e < NE - 1) return (MBH + NE - 1) / NE;
    return MBH - (NE - 1) * ((MBH + NE - 1) / NE);
  endfunction

  // Slice g of the picture (engine g / SE, local slice g % SE): whole rows inside the band, the first band_rows % SE
  // slices one row taller.
  function automatic int slice_first_mb(input int g);
    int e, sl, q, r, rows;
    e  = g / SE;
    sl = g % SE;
    q  = band_rows_of(e) / SE;
    r  = band_rows_of(e) % SE;
    rows = band_first_row(e) + sl * q + ((sl < r) ? sl : r);
    return rows * MBW;
  endfunction

  // ue(v) read from a byte queue starting at bit position pos (clause 9.1), pos advances.
  function automatic int read_ue(ref byte unsigned data[$], input int base, ref int pos);
    int zeros;
    int val;
    zeros = 0;
    while (((data[base + (pos / 8)] >> (7 - (pos % 8))) & 1) == 0) begin
      zeros++;
      pos++;
    end
    pos++;
    val = 0;
    for (int i = 0; i < zeros; i++) begin
      val = (val << 1) | ((data[base + (pos / 8)] >> (7 - (pos % 8))) & 1);
      pos++;
    end
    return (1 << zeros) - 1 + val;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  byte unsigned stream[$];
  byte unsigned estream[4][$];
  string in0_file, in1_file, out_prefix;
  bit    have_in0, have_in1, have_out, inject;
  logic [31:0] v;
  int    idx_rd [4];
  int    ring_rd [4];
  int    slices_done [4];
  int    pic_stream_start;
  int    clocks;
  int    cur_pic;
  bit    pic_is_p;
  string gop;
  string inpfx;
  int    idr_count;
  int    since_idr;
  int    eng_pic_bytes [4];
  // Motion statistics (+EXPMV_X, +EXPMV_Y).
  int    exp_x, exp_y;
  bit    have_exp;
  int    mv_idx [4];
  int    mv_int [4];
  int    mv_true [4];

  function automatic logic [127:0] mem_word(input int unsigned byte_addr);
    return u_mem.mem[byte_addr >> 4];
  endfunction

  // Register window of engine e: 0x100 * e plus the offset.
  function automatic logic [11:0] ereg(input int e, input logic [11:0] off);
    return 12'(e * 256) + off;
  endfunction

  function automatic int unsigned ring_base_e(input int e);
    return RING_BASE + e * (RING_SIZE / NE);
  endfunction

  function automatic int unsigned ring_size_e();
    return RING_SIZE / NE;
  endfunction

  function automatic int unsigned idx_base_e(input int e);
    return IDX_BASE + e * (IDX_ENTRIES / NE) * IDX_REC;
  endfunction

  function automatic int idx_entries_e();
    return IDX_ENTRIES / NE;
  endfunction

  function automatic byte unsigned mem_byte(input int unsigned byte_addr);
    logic [127:0] w;
    w = u_mem.mem[byte_addr >> 4];
    return w[8*(byte_addr & 15) +: 8];
  endfunction

  // De-tile the rebuilt picture into dense planes (Y stride MBW * 16, Cb and Cr stride RC_STRIDE) and dump them as 16-byte
  // hex lines: Y plane, Cb plane, Cr plane. Luma tile of macroblock m: 16 rows of 16 bytes at RY_BASE + 256 * m. Chroma tile:
  // Cb rows 0..7 (8 bytes each) then Cr rows 0..7 at RU_BASE + 128 * m.
  byte unsigned plane_y [];
  byte unsigned plane_u [];
  byte unsigned plane_v [];

  task automatic dump_rec(input int p);
    integer f;
    string  name;
    logic [127:0] w;
    int unsigned RY_BASE, RU_BASE;
    RY_BASE = (p % 2 == 0) ? RYA_BASE : RYB_BASE;
    RU_BASE = (p % 2 == 0) ? RUA_BASE : RUB_BASE;
    plane_y = new[RY_SIZE];
    plane_u = new[RC_SIZE];
    plane_v = new[RC_SIZE];
    for (int i = 0; i < RY_SIZE; i++) plane_y[i] = 8'h00;
    for (int i = 0; i < RC_SIZE; i++) begin plane_u[i] = 8'h00; plane_v[i] = 8'h00; end
    for (int my = 0; my < MBH; my++) begin
      for (int mx = 0; mx < MBW; mx++) begin
        int unsigned m;
        m = my * MBW + mx;
        for (int y = 0; y < 16; y++)
          for (int x = 0; x < 16; x++)
            plane_y[(my * 16 + y) * RY_STRIDE + mx * 16 + x] = mem_byte(RY_BASE + 256 * m + y * 16 + x);
        for (int y = 0; y < 8; y++)
          for (int x = 0; x < 8; x++) begin
            plane_u[(my * 8 + y) * RC_STRIDE + mx * 8 + x] = mem_byte(RU_BASE + 128 * m + y * 8 + x);
            plane_v[(my * 8 + y) * RC_STRIDE + mx * 8 + x] = mem_byte(RU_BASE + 128 * m + 64 + y * 8 + x);
          end
      end
    end
    name = $sformatf("%s_rec%0d.hex", out_prefix, p);
    f = $fopen(name, "w");
    for (int a = 0; a < RY_SIZE; a += 16) begin
      for (int b = 0; b < 16; b++) w[8*b +: 8] = plane_y[a + b];
      $fdisplay(f, "%032x", w);
    end
    for (int a = 0; a < RC_SIZE; a += 16) begin
      for (int b = 0; b < 16; b++) w[8*b +: 8] = plane_u[a + b];
      $fdisplay(f, "%032x", w);
    end
    for (int a = 0; a < RC_SIZE; a += 16) begin
      for (int b = 0; b < 16; b++) w[8*b +: 8] = plane_v[a + b];
      $fdisplay(f, "%032x", w);
    end
    $fclose(f);
  endtask

  // The generator's hex file is dense (line stride MBW * 32); spread its lines to the padded stride, last line first so no
  // line overwrites a source line that is still to be moved.
  task automatic spread_lines(input int unsigned base);
    if (IN_STRIDE != IN_DENSE) begin
      for (int y = MBH * 16 - 1; y >= 0; y--) begin
        for (int w = (IN_DENSE / 16) - 1; w >= 0; w--) u_mem.mem[(base + y * IN_STRIDE) / 16 + w] = u_mem.mem[(base + y * IN_DENSE) / 16 + w];
        for (int w = IN_DENSE / 16; w < (IN_STRIDE / 16); w++) u_mem.mem[(base + y * IN_STRIDE) / 16 + w] = '0;
      end
    end
  endtask

  task automatic dump_stream();
    integer f;
    logic [127:0] w;
    f = $fopen($sformatf("%s_stream.hex", out_prefix), "w");
    for (int i = 0; i < stream.size(); i += 16) begin
      w = '0;
      for (int b = 0; b < 16; b++) if ((i + b) < stream.size()) w[8*b +: 8] = stream[i + b];
      $fdisplay(f, "%032x", w);
    end
    $fclose(f);
    f = $fopen($sformatf("%s_info.txt", out_prefix), "w");
    $fdisplay(f, "stream_bytes=%0d", stream.size());
    $fdisplay(f, "mbw=%0d", MBW);
    $fdisplay(f, "mbh=%0d", MBH);
    $fdisplay(f, "slices=%0d", SLICES);
    $fdisplay(f, "engines=%0d", NE);
    $fdisplay(f, "pics=%0d", PICS);
    $fdisplay(f, "ry_stride=%0d", RY_STRIDE);
    $fdisplay(f, "rc_stride=%0d", RC_STRIDE);
    $fdisplay(f, "ry_size=%0d", RY_SIZE);
    $fdisplay(f, "rc_size=%0d", RC_SIZE);
    $fclose(f);
  endtask

  // Firmware's part for engine e: consume every index entry that is visible; n receives the number consumed.
  task automatic consume_entries(input int e, output int n);
    logic [31:0] wp;
    logic [127:0] en;
    int unsigned off, len, end_pos, rsz, pos;
    logic [127:0] w;
    n = 0;
    reg_read(ereg(e, R_IDX_WPTR), wp);
    rsz = ring_size_e();
    while (idx_rd[e] != int'(wp)) begin
      en = mem_word(idx_base_e(e) + idx_rd[e] * IDX_REC);
      off = en[31:0];
      len = en[63:32];
      if (en[120]) begin
        // Picture entry of this engine: the engine's NAL units of the picture.
        tb_check(en[95:80] == 16'(SE), $sformatf("engine %0d picture entry slice count %0d", e, en[95:80]));
        tb_check(en[112], "picture entry last-slice flag");
        tb_check(en[79:64] == 16'(cur_pic), $sformatf("picture entry picture number %0d", en[79:64]));
        tb_check(int'(len) == eng_pic_bytes[e], $sformatf("engine %0d picture entry length %0d, bytes %0d", e, len, eng_pic_bytes[e]));
      end else begin
        end_pos = (off + len) % rsz;
        tb_check(en[95:80] == 16'(e * SE + slices_done[e]),
                 $sformatf("engine %0d slice entry number %0d, expected %0d", e, en[95:80], e * SE + slices_done[e]));
        tb_check(en[79:64] == 16'(cur_pic), $sformatf("slice entry picture number %0d", en[79:64]));
        tb_check(en[103:96] == (pic_is_p ? 8'd5 : 8'd7), $sformatf("slice entry type %0d", en[103:96]));
        tb_check(en[113] == !pic_is_p, "slice entry IDR flag");
        tb_check(en[111:104] == 8'(QP), $sformatf("slice entry QP %0d", en[111:104]));
        tb_check(en[112] == (slices_done[e] == SE - 1), "slice entry last flag");
        tb_check(int'(len) < int'(rsz), "slice length below the ring size");
        pos = ring_rd[e];
        while (pos != end_pos) begin
          w = mem_word(ring_base_e(e) + (pos & 32'hFFFFFFF0));
          estream[e].push_back(w[8*(pos & 15) +: 8]);
          eng_pic_bytes[e]++;
          pos = (pos + 1) % rsz;
        end
        ring_rd[e] = end_pos;
        slices_done[e]++;
      end
      idx_rd[e] = (idx_rd[e] + 1) % idx_entries_e();
      n++;
    end
    if (n > 0) begin
      reg_write(ereg(e, R_RING_RPTR), 32'(ring_rd[e]));
      reg_write(ereg(e, R_IDX_RPTR), 32'(idx_rd[e]));
    end
  endtask

  // Check the NAL framing and the first_mb_in_slice of every slice of a picture in the stream.
  task automatic check_picture_stream(input int start_byte);
    int pos;
    int sl;
    int bitpos;
    int first_mb;
    int stype;
    int unsigned b0;
    pos = start_byte;
    tb_check((stream[pos] == 0) && (stream[pos+1] == 0) && (stream[pos+2] == 0) && (stream[pos+3] == 1), "AUD start code");
    tb_check((stream[pos+4] == 8'h09) && (stream[pos+5] == 8'hF0), $sformatf("AUD payload %02x %02x", stream[pos+4], stream[pos+5]));
    pos += 6;
    for (sl = 0; sl < SLICES; sl++) begin
      tb_check((stream[pos] == 0) && (stream[pos+1] == 0) && (stream[pos+2] == 0) && (stream[pos+3] == 1),
               $sformatf("slice %0d start code", sl));
      b0 = stream[pos+4];
      tb_check(b0[7] == 1'b0 && b0[6:5] == 2'b11, "NAL header nal_ref_idc");
      tb_check(b0[4:0] == (pic_is_p ? 5'd1 : 5'd5), $sformatf("NAL unit type %0d, expected %0d", b0[4:0], pic_is_p ? 1 : 5));
      bitpos = 0;
      first_mb = read_ue(stream, pos + 5, bitpos);
      stype = read_ue(stream, pos + 5, bitpos);
      tb_check(first_mb == slice_first_mb(sl), $sformatf("slice %0d first_mb_in_slice %0d, expected %0d", sl, first_mb,
                                                       slice_first_mb(sl)));
      tb_check(stype == (pic_is_p ? 5 : 7), $sformatf("slice %0d slice_type %0d", sl, stype));
      pos += 4;
      while ((pos + 3) < stream.size() && !((stream[pos] == 0) && (stream[pos+1] == 0) && (stream[pos+2] == 1))) pos++;
      if ((pos + 3) < stream.size()) pos -= 1;
    end
  endtask

  task automatic run_picture(input int p);
    logic [31:0] st, c;
    int t, n, got_done;
    int total_entries [4];
    bit all_entries;
    cur_pic = p;
    for (int e = 0; e < 4; e++) begin
      mv_idx[e] = 0;
      mv_int[e] = 0;
      mv_true[e] = 0;
    end
    pic_is_p = (gop.len() > p) && (gop.getc(p) == "P");
    pic_stream_start = stream.size();
    for (int e = 0; e < NE; e++) begin
      slices_done[e] = 0;
      eng_pic_bytes[e] = 0;
      total_entries[e] = 0;
      estream[e].delete();
    end
    // Input: the picture's hex file into the one input buffer.
    begin
      string fname;
      fname = $sformatf("%s%0d.hex", inpfx, p);
      $readmemh(fname, u_mem.mem, IN0_BASE >> 4);
      spread_lines(IN0_BASE);
    end
    if (!pic_is_p) begin
      reg_write(R_FRAME_NUM, 32'd0);
      reg_write(R_IDR_PIC_ID, 32'(idr_count));
      idr_count++;
      since_idr = 0;
    end else begin
      since_idr++;
      reg_write(R_FRAME_NUM, 32'(since_idr % 16));
    end
    // Rebuilt picture of buffer p mod 2; a P picture reads the other buffer (the previous picture).
    reg_write(R_RY_BASE, (p % 2 == 0) ? RYA_BASE : RYB_BASE);
    reg_write(R_RU_BASE, (p % 2 == 0) ? RUA_BASE : RUB_BASE);
    reg_write(R_REFY_BASE, (p % 2 == 0) ? RYB_BASE : RYA_BASE);
    reg_write(R_REFU_BASE, (p % 2 == 0) ? RUB_BASE : RUA_BASE);
    reg_write(R_PIC_CFG, {19'd0, 5'd4, 6'd0, pic_is_p, !pic_is_p});
    reg_write(R_IN_BASE, IN0_BASE);
    reg_write(R_CTRL, 32'h1);
    got_done = 0;
    all_entries = 0;
    t = 0;
    while (!(got_done && all_entries) && t < 400000) begin
      reg_read(R_STATUS, st);
      if (st[1]) got_done = 1;
      tb_check(!st[2], "STATUS.ERR set");
      repeat (`TB_CONSUMER_DELAY) @(negedge s_clk);
      all_entries = 1;
      for (int e = 0; e < NE; e++) begin
        consume_entries(e, n);
        total_entries[e] += n;
        if (total_entries[e] != SE + 1) all_entries = 0;
      end
      t++;
    end
    tb_check(got_done && all_entries, $sformatf("picture %0d: done %0d, all index entries seen %0d", p, got_done, all_entries));
    reg_write(R_STATUS, 32'h2);
    // The picture: the access unit delimiter and the slices of engine 0, then those of the later engines.
    for (int e = 0; e < NE; e++) for (int i = 0; i < estream[e].size(); i++) stream.push_back(estream[e][i]);
    check_picture_stream(pic_stream_start);
    dump_rec(p);
    reg_read(R_PIC_COUNT, c);
    tb_check(int'(c) == (p + 1), $sformatf("PIC_COUNT %0d", c));
    if (have_exp && pic_is_p) begin
      int ti, tt;
      ti = 0;
      tt = 0;
      for (int e = 0; e < NE; e++) begin
        ti += mv_int[e];
        tt += mv_true[e];
      end
      $display("MVSTAT pic%0d interior=%0d true=%0d", p, ti, tt);
    end
    for (int e = 0; e < NE; e++) begin
      reg_read(ereg(e, R_PIC_CYC), c);  $display("STAT pic%0d eng%0d PIC_CYC=%0d type=%s", p, e, c, pic_is_p ? "P" : "I");
      reg_read(ereg(e, R_MB_COUNT), c); $display("STAT pic%0d eng%0d MB_COUNT=%0d", p, e, c);
      tb_check(int'(c) == MBW * band_rows_of(e), $sformatf("engine %0d MB_COUNT %0d", e, c));
      reg_read(ereg(e, R_CYC_LAST), c); $display("STAT pic%0d eng%0d CYC_LAST=%0d", p, e, c);
      reg_read(ereg(e, R_CYC_MAX), c);  $display("STAT pic%0d eng%0d CYC_MAX=%0d", p, e, c);
      reg_read(ereg(e, R_RD_CYC), c);   $display("STAT pic%0d eng%0d RD_CYC=%0d", p, e, c);
      reg_read(ereg(e, R_PK_CYC), c);   $display("STAT pic%0d eng%0d PK_CYC=%0d", p, e, c);
      reg_read(ereg(e, R_WR_CYC), c);   $display("STAT pic%0d eng%0d WR_CYC=%0d", p, e, c);
      reg_read(ereg(e, R_IDX_WPTR), c);
      tb_check(int'(c) == idx_rd[e], "index pointer");
    end
  endtask

  initial begin
    have_in0 = $value$plusargs("INPFX=%s", inpfx);
    have_in1 = 1'b0;
    have_out = $value$plusargs("OUT=%s", out_prefix);
    have_exp = $test$plusargs("EXPMV_X");
    exp_x = 0;
    exp_y = 0;
    if (have_exp) begin
      if (!$value$plusargs("EXPMV_X=%d", exp_x)) exp_x = 0;
      if (!$value$plusargs("EXPMV_Y=%d", exp_y)) exp_y = 0;
    end
    if (!$value$plusargs("GOP=%s", gop)) gop = "";
    idr_count = 0;
    since_idr = 0;
    inject   = $test$plusargs("INJECT");
    build_map();
    tb_check(have_in0 && have_out, "plusargs +INPFX and +OUT are required");
    tb_check(MEM_END <= (16 << `TB_MEM_LOG2), $sformatf("memory model too small: need %0d bytes", MEM_END));
    tb_check((SLICES % NE) == 0, "TB_SLICES must be a multiple of TB_ENGINES");
    for (int e = 0; e < 4; e++) begin
      idx_rd[e] = 0;
      ring_rd[e] = 0;
    end
    resetn = 1'b0;
    repeat (8) @(negedge s_clk);
    resetn = 1'b1;
    repeat (8) @(negedge s_clk);

    reg_read(R_ID, v);
    tb_check(v == 32'h48323634, $sformatf("ID %08x", v));
    reg_read(R_CAPS, v);
    tb_check(v[7:0] == 8'd120 && v[15:8] == 8'd68 && v[19:16] == 4'(NE), $sformatf("CAPS %08x", v));

    reg_write(R_MB_W, MBW);
    reg_write(R_MB_H, MBH);
    reg_write(R_SLICES, SLICES);
    reg_write(R_QP, QP);
`ifdef TB_HP_ENABLE
    reg_write(12'h0C0, 32'h1);     // HP_CTRL.hp_enable: the High profile module codes the pictures
`endif
`ifdef TB_PCM
    reg_write(R_MB_MODE, 32'h1);
`endif
    reg_write(R_IN_STRIDE, IN_STRIDE);
    reg_write(R_RING_BASE, RING_BASE);
    reg_write(R_RING_SIZE, RING_SIZE);
    reg_write(R_IDX_BASE, IDX_BASE);
    reg_write(R_IDX_ENTRIES, IDX_ENTRIES);
    reg_write(R_CTRL, 32'h2);
    reg_read(R_MB_W, v);
    tb_check(int'(v) == MBW, "MB_W readback");

    for (int p = 0; p < PICS; p++) run_picture(p);

    if (inject) begin
      // Negative control: flip one bit of a residual byte of the first slice, well past the slice header and the first
      // macroblock header (byte 150 of the stream, or the middle of a short stream), clear of emulation-prevention bytes.
      int k;
      k = (stream.size() > 300) ? 150 : (stream.size() / 2);
      while ((stream[k-1] <= 3) || (stream[k] <= 3) || (stream[k+1] <= 3) || ((stream[k] ^ 8'h40) <= 3)) k++;
      stream[k] = stream[k] ^ 8'h40;
      $display("NOTE: INJECT flips bit 6 of stream byte %0d", k);
    end
    dump_stream();
    $display("STAT ring_stall_cycles=%0d", stall_cycles);
    // Burst shapes: one single-beat ring tail is possible per slice end, ring wrap or 4 KiB end.
    u_bmon.report(2 * SE * PICS + (stream.size() / (RING_SIZE / NE)) + 4);
    tb_check(u_bmon.viol_count == 0, "burst monitor reported a violation");
`ifdef TB_EXPECT_STALL
    tb_check(stall_cycles > 0, "the ring-full guard never stalled the writer");
`endif
    $display("NOTE: stream %0d bytes, %0d picture(s) %0dx%0d macroblocks, %0d slice(s), %0d engine(s)", stream.size(), PICS, MBW, MBH, SLICES, NE);
    tb_verdict("tb_rtlnet_h264_top");
  end

  // Burst monitor on the engine ports, with its negative control: +INJECT_BURST shows the monitor one single-beat AW (ID 2,
  // the rebuilt-picture writer) in addition to the real traffic.
  logic [NE-1:0] mon_awvalid, mon_awready;
  logic [NE*8-1:0] mon_awlen;
  logic [NE*4-1:0] mon_awid;
  logic [NE*4-1:0] mon_arid;
  logic [NE*8-1:0] mon_arlen;
  logic [NE-1:0]   mon_arvalid, mon_arready;
  bit inj_burst, inj_burst_ref;
  int unsigned inj_cnt = 0;
  initial begin
    inj_burst     = $test$plusargs("INJECT_BURST");
    inj_burst_ref = $test$plusargs("INJECT_BURST_REF");
  end
  always @(posedge enc_clk) if (resetn) inj_cnt <= inj_cnt + 1;
  always_comb begin
    mon_awvalid = e_awvalid;
    mon_awready = e_awready;
    mon_awlen   = e_awlen;
    mon_awid    = e_awid;
    mon_arid    = e_arid;
    mon_arlen   = e_arlen;
    mon_arvalid = e_arvalid;
    mon_arready = e_arready;
    // Negative control of the reference-read check: one 4-beat reference AR shown to the monitor.
    if (inj_burst_ref && (inj_cnt == 30000)) begin
      mon_arvalid[0]    = 1'b1;
      mon_arready[0]    = 1'b1;
      mon_arlen[7:0]    = 8'd3;
      mon_arid[3:0]     = 4'd1;
    end
    if (inj_burst && (inj_cnt == 20000)) begin
      mon_awvalid[0]     = 1'b1;
      mon_awready[0]     = 1'b1;
      mon_awlen[7:0]     = 8'd0;
      mon_awid[3:0]      = 4'd2;
    end
  end
  tb_h264_burst_mon #(.NE(NE), .ID_W(4)) u_bmon (
    .clk(enc_clk), .resetn(resetn), .awid(mon_awid), .awlen(mon_awlen), .awvalid(mon_awvalid), .awready(mon_awready),
    .arid(mon_arid), .arlen(mon_arlen), .arvalid(mon_arvalid), .arready(mon_arready)
  );

`ifdef TB_DEBUG_MB
  always @(posedge enc_clk) if (resetn && (cur_pic == 1) && (dut.g_engine[0].u_engine.me_start || dut.g_engine[0].u_engine.me_done || dut.g_engine[0].u_engine.a_go || dut.g_engine[0].u_engine.a_done))
    $display("DBGEV t=%0d me_start %0d me_done %0d a_go %0d a_done %0d xh %0d xc %0d xfull %b me_x %0d a_x %0d sfull %b ch %0d me_ch %0d", clocks,
             dut.g_engine[0].u_engine.me_start, dut.g_engine[0].u_engine.me_done, dut.g_engine[0].u_engine.a_go, dut.g_engine[0].u_engine.a_done,
             dut.g_engine[0].u_engine.xh, dut.g_engine[0].u_engine.xc, dut.g_engine[0].u_engine.xfull, dut.g_engine[0].u_engine.me_x,
             dut.g_engine[0].u_engine.a_x, dut.g_engine[0].u_engine.sfull, dut.g_engine[0].u_engine.ch, dut.g_engine[0].u_engine.me_ch);
  always @(posedge enc_clk) if (resetn && dut.g_engine[0].u_engine.u_search.mb_done)
    $display("DBGME pic%0d t=%0d vector (%0d,%0d) pc %0d ev %0d", cur_pic, clocks, dut.g_engine[0].u_engine.u_search.mb_vx,
             dut.g_engine[0].u_engine.u_search.mb_vy, dut.g_engine[0].u_engine.u_search.pc, dut.g_engine[0].u_engine.u_search.ev_cnt);
  always @(posedge enc_clk) if (resetn && dut.g_engine[0].u_engine.a_done)
    $display("DBGMB pic%0d x%0d inter %0d skip %0d pcm %0d cbp4 %0d cbpc %0d est %0d nb %0d nbdc %0d mvd %0d,%0d", cur_pic,
      dut.g_engine[0].u_engine.a_x, dut.g_engine[0].u_engine.a_inter, dut.g_engine[0].u_engine.a_skip, dut.g_engine[0].u_engine.a_pcm,
      dut.g_engine[0].u_engine.a_cbp4, dut.g_engine[0].u_engine.a_cbpc, dut.g_engine[0].u_engine.u_mb_enc.est_tot,
      dut.g_engine[0].u_engine.u_mb_enc.nb_q, dut.g_engine[0].u_engine.u_mb_enc.nb_dc, dut.g_engine[0].u_engine.a_mvdx, dut.g_engine[0].u_engine.a_mvdy);
`endif

`ifdef TB_DUMP_MB
  // Macroblock dump of stage B's input (the descriptor, the coefficient RAM words it reads and the slice events), one text
  // line per item, for the reference models of entropy coders (+DUMP=<file>): S (slice start), M (macroblock), W (coefficient
  // RAM word read by the entropy coder), D (clocks the entropy coder took for the macroblock: stage B's start to its done), E (slice
  // end). W lines follow their M line; idx is the word index inside the bank.
  integer dmp_f;
  initial begin
    string dmp_name;
    dmp_f = 0;
    if ($value$plusargs("DUMP=%s", dmp_name)) dmp_f = $fopen(dmp_name, "w");
  end
  genvar gd;
  generate
    for (gd = 0; gd < NE; gd++) begin : g_dump
      logic [4:0] dst_q;
      int         t_go;
      logic       drd_q;
      logic [9:0] dra_q;
      always @(posedge enc_clk) begin
        if (resetn && (dmp_f != 0)) begin
          dst_q <= dut.g_engine[gd].u_engine.st;
          if ((dut.g_engine[gd].u_engine.st == 5'd7) && (dst_q != 5'd7))
            $fdisplay(dmp_f, "S %0d %0d %0d %0d %0d %0d %0d", gd, dut.g_engine[gd].u_engine.mbn, dut.g_engine[gd].u_engine.cfg_qp,
                      dut.g_engine[gd].u_engine.e_p, dut.g_engine[gd].u_engine.e_idr, dut.g_engine[gd].u_engine.e_frame_num,
                      dut.g_engine[gd].u_engine.e_idr_pic_id);
          if ((dut.g_engine[gd].u_engine.st == 5'd18) && (dst_q != 5'd18)) $fdisplay(dmp_f, "E %0d", gd);
          if (dut.g_engine[gd].u_engine.b_go) begin
            logic bbk;
            bbk = dut.g_engine[gd].u_engine.bb;
            $fdisplay(dmp_f, "M %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", gd,
                      dut.g_engine[gd].u_engine.bi_x[bbk], dut.g_engine[gd].u_engine.bi_avt[bbk], dut.g_engine[gd].u_engine.bi_avl[bbk],
                      dut.g_engine[gd].u_engine.bi_pcm[bbk], dut.g_engine[gd].u_engine.bi_mode[bbk], dut.g_engine[gd].u_engine.bi_cbpc[bbk],
                      dut.g_engine[gd].u_engine.bi_cbpl[bbk], dut.g_engine[gd].u_engine.bi_cm[bbk], dut.g_engine[gd].u_engine.bi_inter[bbk],
                      dut.g_engine[gd].u_engine.bi_skip[bbk], dut.g_engine[gd].u_engine.bi_cbp4[bbk],
                      $signed(dut.g_engine[gd].u_engine.bi_mvdx[bbk]), $signed(dut.g_engine[gd].u_engine.bi_mvdy[bbk]), dut.g_engine[gd].u_engine.cof_base_b);
          end
          if (dut.g_engine[gd].u_engine.b_go) t_go <= clocks;
          if (dut.g_engine[gd].u_engine.b_done) $fdisplay(dmp_f, "D %0d %0d", gd, clocks - t_go);
          drd_q <= dut.g_engine[gd].u_engine.cofb_rd_en;
          dra_q <= 10'(dut.g_engine[gd].u_engine.cofb_raddr) - 10'(dut.g_engine[gd].u_engine.cof_base_b);
          if (drd_q) $fdisplay(dmp_f, "W %0d %0d %012x", gd, dra_q, dut.g_engine[gd].u_engine.cofb_rdata);
        end
      end
    end
  endgenerate
  final begin
    if (dmp_f != 0) $fclose(dmp_f);
  end
`endif

  // Motion statistics: the final vector of every macroblock of every engine, in band raster order.
  genvar ge;
  generate
    for (ge = 0; ge < NE; ge++) begin : g_mvmon
      always @(posedge enc_clk) begin
        if (resetn && have_exp && dut.g_engine[ge].u_engine.a_done && pic_is_p) begin
          int mcol, mrow;
          mcol = mv_idx[ge] % MBW;
          mrow = band_first_row(ge) + (mv_idx[ge] / MBW);
          mv_idx[ge] = mv_idx[ge] + 1;
          if (((16 * mcol + exp_x) >= 0) && ((16 * mcol + exp_x + 16) <= 16 * MBW) &&
              ((16 * mrow + exp_y) >= 0) && ((16 * mrow + exp_y + 16) <= 16 * MBH)) begin
            mv_int[ge] = mv_int[ge] + 1;
            if (dut.g_engine[ge].u_engine.a_inter && (int'(dut.g_engine[ge].u_engine.u_mb_enc.mv_upd_x) == 4 * exp_x) &&
                (int'(dut.g_engine[ge].u_engine.u_mb_enc.mv_upd_y) == 4 * exp_y)) mv_true[ge] = mv_true[ge] + 1;
          end
        end
      end
    end
  endgenerate

  // Ring-full stall observation (the full guard).
  int unsigned stall_cycles = 0;
  always @(posedge enc_clk) if (resetn && (|dut.eng_stall)) stall_cycles++;

  // Watchdog on clock count.
  initial begin
    clocks = 0;
    forever begin
      @(posedge enc_clk);
      clocks++;
      if (clocks > MAX_CLK) begin
        $display("WATCHDOG engine0: st %0d ft %0d sfull %b xfull %b cfull %b rfull %b search st %0d ld_g %0d tot %0d win_busy %0d me_left %0d me_active %0d a_busy %0d b_busy %0d",
                 dut.g_engine[0].u_engine.st, dut.g_engine[0].u_engine.ft, dut.g_engine[0].u_engine.sfull, dut.g_engine[0].u_engine.xfull,
                 dut.g_engine[0].u_engine.cfull, dut.g_engine[0].u_engine.rfull, dut.g_engine[0].u_engine.u_search.st,
                 dut.g_engine[0].u_engine.u_search.ld_g, dut.g_engine[0].u_engine.u_search.tot_cols, dut.g_engine[0].u_engine.u_search.win_busy,
                 dut.g_engine[0].u_engine.me_left, dut.g_engine[0].u_engine.me_active, dut.g_engine[0].u_engine.a_busy, dut.g_engine[0].u_engine.b_busy);
        tb_error("watchdog: simulation limit reached");
        tb_verdict("tb_rtlnet_h264_top");
      end
    end
  end

endmodule
