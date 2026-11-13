// -----------------------------------------------------------------------------
// File: tb_rtlnet_axi_arbiter.sv
// Purpose: self-checking bench for rtlnet_axi_arbiter in front of the AXI4
//   memory model rtlnet_tb_axi4_mem, registers through AXI4-Lite on a CPU clock
//   unrelated to the data clock.
// Cases:
//   1. Header registers (ID, VERSION, CAPS), reset values, undefined offsets,
//      writes to read-only registers ignored.
//   2. Data integrity: every master issues random legal bursts (len 0..255
//      within 4 KiB, own region and a shared region, random strobes, several
//      IDs). A reference memory in the bench predicts every read beat. A fill
//      phase writes the shared region (each master owns its pages), then a
//      mixed phase reads it everywhere. Saturated (no gaps) and gapped
//      (random ready and valid gaps) runs.
//   3. Always on in legal-only phases: ID routing and per-ID order of every B
//      and R, W order at the memory port (each beat equals the pattern of its
//      own burst), the memory-side AW/W/AR streams equal the grant order,
//      priority (a high-priority master is granted whenever it requests),
//      round robin (grants of other round-robin masters a waiting master sees,
//      at most NUM_MASTERS - 1), in-flight at most MAX_OUTSTANDING per
//      direction.
//   4. Illegal bursts: FIXED, WRAP, narrow size and 4 KiB crossing, each for
//      read and write, with earlier legal traffic of the same master
//      outstanding and legal traffic after: never reaches the memory model,
//      answered after the earlier responses with SLVERR of the right length,
//      ERRORS counters, STATUS.ERR sticky, err_irq, write-1-to-clear. Then
//      random illegal bursts mixed into the legal traffic of all masters.
//   5. Registers against the bench's own counts on s_axi_aclk (7.3 ns against
//      the 10 ns data clock): every counter of every master, CNT_CLEAR,
//      STATUS in-flight bits.
//   6. Reset in the middle of traffic, then clean traffic again.
//   7. WRAP (TB_WRAP mask of masters in WRAP_MASK): legal WRAP bursts of 2, 4, 8, 16 beats mixed into the
//      random traffic of those masters (data checked beat by beat through the wrap-aware bench model and the
//      memory model), directed legal WRAP writes and reads at every start offset of every length (and narrow
//      sizes for a narrow master) with an INCR read-back of the container; directed illegal WRAPs rejected
//      with SLVERR (len 0, len 2 = 3 beats, misaligned start, and a legal-form WRAP from a master not in the
//      mask); the WRAP register.
//   9. Unaligned INCR starts (AXI: the span runs from the size-aligned start): random 30 % of the INCR
//      bursts start inside their first transfer (first-beat strobes limited to the upper lanes), directed
//      accepts (size 2 len 0 at 0xFFD and 0xFFF, len 3 at 0xFF1, full size len 0 at the last word + 1) with
//      the data and strobes checked by write, same-byte read and full-width read of the words, and rejects
//      (size 2 len 1 at 0xFFD, full size len 1 at the last word + 1).
//   8. First-illegal-burst capture registers (CAP_INFO, CAP_ADDR, CAP_ADDR_HI): cleared state, the first
//      illegal burst of each kind captured with every field and the failed rule, a second illegal burst does
//      not overwrite it, STATUS.ERR clear and CTRL.CNT_CLEAR clear it, reset clears it.
// Configuration (defines, defaults in brackets): TB_NM masters [3], TB_DW data
//   width [128], TB_HP high-priority mask [1], TB_LAT memory read latency in
//   clocks [0], TB_GAP 1 for random ready/valid gaps on the memory model and
//   the masters [0], TB_SIZE burst count scale in percent [100], TB_NARROW mask of
//   masters that may issue narrow transfers [0], TB_WRAP mask of masters in WRAP_MASK [0], TB_ADDR_REG the ADDR_REG
//   parameter of the arbiter (register slices on the AW and AR channels) [1].
//   Grants: the arbiter grants in two clocks (registered grant, then fire). The bench takes a grant from the arbiter's own
//   fire signals (dut.aw_fire, dut.ar_fire) with the master it chose; a master's descriptor waits in a per-master queue from
//   the handshake on its port (accepted by the slice or the grant itself) until its grant. Priority and round robin are
//   checked against the requests of the clock before the fire (the requests the pick saw), WAIT_CYCLES against the
//   requests inside the arbiter (after the slices).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-12-2026
//   * 11-12-2026: TB_ADDR_REG; grants taken from the arbiter's fire signals (two-clock grant, register slices); directed cases of
//     simultaneous requests, back-to-back bursts and the grant latency.
//   * 11-09-2026: initial version.
//   * 11-09-2026: TB_NARROW (NARROW_MASK): narrow legal traffic with strobes, directed narrow
//     cases, narrow burst crossing 4 KiB, NARROW register.
//   * 11-09-2026: TB_WRAP (WRAP_MASK): legal and illegal WRAP bursts, WRAP register, capture registers.
//   * 11-09-2026: unaligned INCR starts, random and directed; 4 KiB rule from the size-aligned start.
// Run: powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_axi_arbiter
//        -Filelist cores/rtlnet_axi_arbiter/testbench/tb_rtlnet_axi_arbiter.f
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_NM
  `define TB_NM 3
`endif
`ifndef TB_DW
  `define TB_DW 128
`endif
`ifndef TB_HP
  `define TB_HP 1
`endif
`ifndef TB_LAT
  `define TB_LAT 0
`endif
`ifndef TB_GAP
  `define TB_GAP 0
`endif
`ifndef TB_SIZE
  `define TB_SIZE 100
`endif
`ifndef TB_NARROW
  `define TB_NARROW 0
`endif
`ifndef TB_WRAP
  `define TB_WRAP 0
`endif
`ifndef TB_ADDR_REG
  `define TB_ADDR_REG 1
`endif

module tb_rtlnet_axi_arbiter;

  import rtlnet_tb_pkg::*;

  localparam string BENCH = "tb_rtlnet_axi_arbiter";

  localparam int NM    = `TB_NM;
  localparam int DW    = `TB_DW;
  localparam int AW    = 32;
  localparam int IDW   = 4;
  localparam int MAXO  = 8;
  localparam int IDXW  = (NM > 1) ? $clog2(NM) : 1;
  localparam int MIDW  = IDW + IDXW;
  localparam int BYTES = DW / 8;
  localparam int SIZEF = $clog2(BYTES);
  localparam logic [NM-1:0] HPM = `TB_HP;
  localparam logic [NM-1:0] NARM = `TB_NARROW;
  localparam logic [NM-1:0] WRAPM = `TB_WRAP;
  localparam int GAPS  = `TB_GAP;
  localparam int LAT   = `TB_LAT;
  localparam bit ADDRREG = `TB_ADDR_REG;

  localparam int OUTS_M    = 12;         // outstanding bursts per master and direction
  localparam int IDS       = 4;          // IDs used per master
  localparam int PAGE      = 4096;
  localparam int OWN_PAGES = 16;
  localparam int SH_PAGES  = 16;
  localparam int OWN_SIZE  = OWN_PAGES * PAGE;
  localparam int SH_BASE   = 32'h0010_0000;
  localparam int TMO_CLK   = 4000000;

  localparam int KIND_LEGAL  = 0;
  localparam int KIND_FIXED  = 1;
  localparam int KIND_WRAP   = 2;
  localparam int KIND_NARROW = 3;
  localparam int KIND_X4K    = 4;
  localparam int KIND_NX4K   = 5;     // narrow-size burst that crosses 4 KiB by its own size
  localparam int KIND_WRAP0  = 6;     // WRAP of one beat (len 0), master in WRAP_MASK
  localparam int KIND_WRAP2  = 7;     // WRAP of three beats (len 2), master in WRAP_MASK
  localparam int KIND_WRAPMIS = 8;    // WRAP of legal length at a misaligned start, master in WRAP_MASK

  localparam int MODE_OWN   = 0;
  localparam int MODE_FILL  = 1;
  localparam int MODE_MIXED = 2;

  localparam logic [11:0] R_ID = 12'h000, R_VERSION = 12'h004, R_CAPS = 12'h008, R_CTRL = 12'h00C, R_STATUS = 12'h010,
                      R_NARROW = 12'h014, R_WRAP = 12'h018, R_CAP_INFO = 12'h040, R_CAP_ADDR = 12'h044,
                      R_CAP_ADDRH = 12'h048;
  localparam logic [31:0] CTRL_CNT_CLEAR = 32'h0001_0000;

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic clk     = 1'b0;
  logic cpu_clk = 1'b0;
  logic arstn   = 1'b0;
  logic resetn;
  logic cpu_resetn;

  always #5.0 clk = ~clk;
  initial begin
    #1.3;
    forever #3.65 cpu_clk = ~cpu_clk;
  end

  rtlnet_reset_sync u_rst_d (.clk(clk),     .arstn(arstn), .resetn(resetn));
  rtlnet_reset_sync u_rst_c (.clk(cpu_clk), .arstn(arstn), .resetn(cpu_resetn));

  // ---------------------------------------------------------------------------
  // DUT, memory model, register master
  // ---------------------------------------------------------------------------
  wire [NM*IDW-1:0]  s_awid;
  wire [NM*AW-1:0]   s_awaddr;
  wire [NM*8-1:0]    s_awlen;
  wire [NM*3-1:0]    s_awsize;
  wire [NM*2-1:0]    s_awburst;
  wire [NM-1:0]      s_awvalid;
  wire [NM-1:0]      s_awready;
  wire [NM*DW-1:0]   s_wdata;
  wire [NM*BYTES-1:0] s_wstrb;
  wire [NM-1:0]      s_wlast;
  wire [NM-1:0]      s_wvalid;
  wire [NM-1:0]      s_wready;
  wire [NM*IDW-1:0]  s_bid;
  wire [NM*2-1:0]    s_bresp;
  wire [NM-1:0]      s_bvalid;
  wire [NM-1:0]      s_bready;
  wire [NM*IDW-1:0]  s_arid;
  wire [NM*AW-1:0]   s_araddr;
  wire [NM*8-1:0]    s_arlen;
  wire [NM*3-1:0]    s_arsize;
  wire [NM*2-1:0]    s_arburst;
  wire [NM-1:0]      s_arvalid;
  wire [NM-1:0]      s_arready;
  wire [NM*IDW-1:0]  s_rid;
  wire [NM*DW-1:0]   s_rdata;
  wire [NM*2-1:0]    s_rresp;
  wire [NM-1:0]      s_rlast;
  wire [NM-1:0]      s_rvalid;
  wire [NM-1:0]      s_rready;

  wire [MIDW-1:0]    m_awid, m_bid, m_arid, m_rid;
  wire [AW-1:0]      m_awaddr, m_araddr;
  wire [7:0]         m_awlen, m_arlen;
  wire [2:0]         m_awsize, m_arsize;
  wire [1:0]         m_awburst, m_arburst, m_bresp, m_rresp;
  wire               m_awvalid, m_awready, m_wvalid, m_wready, m_wlast, m_bvalid, m_bready;
  wire               m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
  wire [DW-1:0]      m_wdata, m_rdata;
  wire [BYTES-1:0]   m_wstrb;

  logic [11:0] awaddr;  logic awvalid, awready;
  logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid, wready;
  logic [1:0]  bresp;   logic bvalid, bready;
  logic [11:0] araddr;  logic arvalid, arready;
  logic [31:0] rdata;   logic [1:0] rresp; logic rvalid, rready;
  logic        err_irq;

  rtlnet_axi_arbiter #(.NUM_MASTERS(NM), .ADDR_W(AW), .DATA_W(DW), .ID_W(IDW), .HIGH_PRIO_MASK(HPM),
                       .NARROW_MASK(NARM), .WRAP_MASK(WRAPM), .MAX_OUTSTANDING(MAXO), .ADDR_REG(ADDRREG)) dut (
    .clk(clk), .resetn(resetn), .s_axi_aclk(cpu_clk), .s_axi_aresetn(cpu_resetn),
    .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize), .s_awburst(s_awburst),
    .s_awvalid(s_awvalid), .s_awready(s_awready),
    .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid), .s_wready(s_wready),
    .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
    .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize), .s_arburst(s_arburst),
    .s_arvalid(s_arvalid), .s_arready(s_arready),
    .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
    .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
    .m_axi_awburst(m_awburst), .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(),
    .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
    .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid),
    .m_axi_wready(m_wready),
    .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
    .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
    .m_axi_arburst(m_arburst), .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(),
    .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
    .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
    .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
    .err_irq(err_irq)
  );

  localparam int MEM_PCT = (GAPS != 0) ? 55 : 100;

  rtlnet_tb_axi4_mem #(.ADDR_W(AW), .DATA_W(DW), .ID_W(MIDW), .READ_LATENCY(LAT), .AW_READY_PCT(MEM_PCT),
                       .W_READY_PCT(MEM_PCT), .AR_READY_PCT(MEM_PCT), .B_VALID_PCT(MEM_PCT), .R_VALID_PCT(MEM_PCT),
                       .SEED(7), .CHECK_FULL_WIDTH(NARM == '0), .ALLOW_WRAP(WRAPM != '0)) u_mem (
    .clk(clk), .resetn(resetn),
    .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
    .awvalid(m_awvalid), .awready(m_awready),
    .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
    .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
    .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst),
    .arvalid(m_arvalid), .arready(m_arready),
    .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready)
  );

  rtlnet_tb_axil_master #(.ADDR_W(12)) u_axi (
    .aclk(cpu_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .araddr(araddr), .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp),
    .rvalid(rvalid), .rready(rready));

  initial begin
    dut.sim_quiet_illegal = 1'b1;
    if ($test$plusargs("ARB_SHOW_ERRORS")) dut.sim_quiet_illegal = 1'b0;
  end

  initial begin
    #(400ms);
    tb_error("watchdog timeout");
    tb_verdict(BENCH);
  end

  // ---------------------------------------------------------------------------
  // Descriptors, patterns, reference memory
  // ---------------------------------------------------------------------------
  typedef struct {
    int              g;
    int              kind;
    bit              is_wr;
    int              id;
    bit [AW-1:0]     addr;
    int              len;
    bit [2:0]        size;
    bit [1:0]        burst;
    int              serial;
    int              smode;
    int              beat;
  } desc_t;

  logic [DW-1:0] ref_mem [bit [AW-1:0]];

  int unsigned lcg_state = 32'h2468_ACE1;

  function automatic int rnd(input int range);
    lcg_state = lcg_state * 32'd1103515245 + 32'd12345;
    return int'((lcg_state >> 8) % range);
  endfunction

  function automatic bit pct(input int p);
    return rnd(100) < p;
  endfunction

  function automatic int unsigned hash32(input int unsigned x);
    int unsigned v;
    v = x + 32'h6D2B79F5;
    v = v ^ (v << 13);
    v = v ^ (v >> 17);
    v = v ^ (v << 5);
    v = v * 32'h9E3779B1;
    v = v ^ (v >> 15);
    return v;
  endfunction

  // Write data of beat k of write serial s of master g, and its byte strobes.
  function automatic bit [DW-1:0] pat_data(input int g, input int s, input int k);
    bit [DW-1:0] d;
    for (int c = 0; c < DW / 32; c++) begin
      d[c*32 +: 32] = hash32((32'(g) * 32'h0100_0193) ^ (32'(s) * 32'h85EB_CA6B) ^ (32'(k) * 32'hC2B2_AE35) ^ 32'(c));
    end
    return d;
  endfunction

  function automatic bit [BYTES-1:0] pat_strb(input int g, input int s, input int k, input int mode);
    bit [BYTES-1:0] st;
    int unsigned    h;
    if (mode == 0) begin
      st = '1;
    end else begin
      h  = hash32((32'(g) * 32'h0100_0193) ^ (32'(s) * 32'h1B87_3593) ^ (32'(k) * 32'hCC9E_2D51) ^ 32'h5555);
      st = BYTES'(h);
      if (k % 5 == 0) st = '1;
    end
    return st;
  endfunction

  function automatic bit [AW-1:0] word_key(input bit [AW-1:0] a, input int beat);
    return (a >> SIZEF) + AW'(beat);
  endfunction

  function automatic bit [DW-1:0] ref_word(input bit [AW-1:0] k);
    return ref_mem.exists(k) ? ref_mem[k] : '0;
  endfunction

  // Size-aware beat geometry (a full-size beat reduces to the word at addr + b words).
  // A WRAP burst wraps inside its (len + 1) * 2**size byte container, aligned to its own size.
  function automatic bit [AW-1:0] beat_addr(input desc_t d, input int b);
    bit [AW-1:0] a;
    bit [AW-1:0] total;
    bit [AW-1:0] lower;
    a = d.addr;
    if (d.burst == 2'b10) begin
      total = AW'(d.len + 1) << d.size;
      lower = d.addr & ~(total - AW'(1));
      a     = lower + (((d.addr >> d.size << d.size) - lower + (AW'(b) << d.size)) & (total - AW'(1)));
    end else if (b > 0) begin
      a = (d.addr >> d.size << d.size) + (AW'(b) << d.size);
    end
    return a;
  endfunction

  // Lowest and highest word key a burst touches (a WRAP is not monotonic: scan its beats).
  function automatic bit [AW-1:0] key_lo(input desc_t d);
    bit [AW-1:0] r;
    r = beat_addr(d, 0) >> SIZEF;
    if (d.burst == 2'b10) begin
      for (int b = 1; b <= d.len; b++) if ((beat_addr(d, b) >> SIZEF) < r) r = beat_addr(d, b) >> SIZEF;
    end
    return r;
  endfunction

  function automatic bit [AW-1:0] key_hi(input desc_t d);
    bit [AW-1:0] r;
    r = (d.burst == 2'b10) ? (beat_addr(d, 0) >> SIZEF) : (beat_addr(d, d.len) >> SIZEF);
    if (d.burst == 2'b10) begin
      for (int b = 1; b <= d.len; b++) if ((beat_addr(d, b) >> SIZEF) > r) r = beat_addr(d, b) >> SIZEF;
    end
    return r;
  endfunction

  function automatic bit [AW-1:0] beat_key(input desc_t d, input int b);
    return beat_addr(d, b) >> SIZEF;
  endfunction

  // Byte lanes a beat drives: the lanes from the beat address (unaligned only on the first beat of
  // an INCR burst) to the end of its size-aligned transfer; all of them for an aligned full-size beat.
  function automatic bit [BYTES-1:0] lane_mask(input desc_t d, input int b);
    bit [BYTES-1:0] m;
    int             nb;
    int             off;
    int             aoff;
    if (int'(d.size) > SIZEF) begin
      m = '1;
    end else begin
      nb   = 1 << d.size;
      off  = int'(beat_addr(d, b) % BYTES);
      aoff = off / nb * nb;
      m    = '0;
      for (int l = off; l < aoff + nb; l++) m[l] = 1'b1;
    end
    return m;
  endfunction

  function automatic bit [BYTES-1:0] exp_strb(input desc_t d, input int b);
    return pat_strb(d.g, d.serial, b, d.smode) & lane_mask(d, b);
  endfunction

  function automatic bit [DW-1:0] lane_bits(input desc_t d, input int b);
    bit [BYTES-1:0] m;
    bit [DW-1:0]    v;
    m = lane_mask(d, b);
    v = '0;
    for (int l = 0; l < BYTES; l++) if (m[l]) v[l*8 +: 8] = 8'hFF;
    return v;
  endfunction

  // A write lands in the reference memory when its B arrives.
  task automatic ref_apply_write(input desc_t d);
    bit [AW-1:0] k;
    bit [DW-1:0] w;
    bit [DW-1:0] nd;
    bit [BYTES-1:0] st;
    for (int b = 0; b <= d.len; b++) begin
      k  = beat_key(d, b);
      w  = ref_word(k);
      nd = pat_data(d.g, d.serial, b);
      st = exp_strb(d, b);
      for (int l = 0; l < BYTES; l++) begin
        if (st[l]) w[l*8 +: 8] = nd[l*8 +: 8];
      end
      ref_mem[k] = w;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Traffic control and expectations
  // ---------------------------------------------------------------------------
  bit          run          = 1'b0;     // masters active; low flushes every master
  int          bursts_left  [NM];
  bit          idle_m       [NM];
  desc_t       inject_q [$];
  int          mode_sel     = MODE_OWN;
  int          p_wr         = 50;
  int          p_ill        = 0;
  int          p_gen        = 100;
  int          p_aw         = 100;
  int          p_w          = 100;
  int          p_ar         = 100;
  int          p_bready     = 100;
  int          p_rready     = 100;
  int          len_cap      = 255;
  bit          mon_en       = 1'b0;     // priority and round-robin monitors
  int          serial_g     [NM];

  int exp_aw   [NM];
  int exp_ar   [NM];
  int exp_w    [NM];
  int exp_r    [NM];
  int exp_err  [NM];
  int exp_wait [NM];

  // Grant-order queues for the memory-side monitors.
  desc_t aw_chk_q [$];
  desc_t w_chk_q  [$];
  desc_t ar_chk_q [$];
  // Descriptors accepted on a master's port and not yet granted, per master (FIFO: the slice keeps the order of one master).
  desc_t aw_pend_q [NM][$];
  desc_t ar_pend_q [NM][$];

  int tot_legal_wr   = 0;
  int tot_legal_rd   = 0;
  int tot_ill        = 0;
  int tot_wrap_legal = 0;   // legal WRAP bursts granted
  int tot_wrap_ill   = 0;   // illegal WRAP bursts answered
  int wr_if          = 0;
  int rd_if          = 0;
  int wr_if_max      = 0;
  int rd_if_max      = 0;
  int mem_wr_if      = 0;
  int mem_rd_if      = 0;
  int mem_wr_if_max  = 0;
  int mem_rd_if_max  = 0;
  int mem_aw_base    = 0;
  int mem_ar_base    = 0;
  int rr_wait_max_aw = 0;
  int rr_wait_max_ar = 0;
  int hp_grants      = 0;
  int hp_contended   = 0;
  int rr_grants      = 0;
  int aw_wait_c [NM];
  int ar_wait_c [NM];
  int status_busy_seen = 0;
  int integrity_bursts = 0;
  int wm_beat      = 0;    // beat index inside the write at the head of w_chk_q

  // Bench state reset: expectations and monitors, at the start and after a DUT reset.
  task automatic clear_expectations();
    for (int g = 0; g < NM; g++) begin
      exp_aw[g] = 0; exp_ar[g] = 0; exp_w[g] = 0; exp_r[g] = 0; exp_err[g] = 0; exp_wait[g] = 0;
      aw_wait_c[g] = 0; ar_wait_c[g] = 0;
    end
    aw_chk_q.delete(); w_chk_q.delete(); ar_chk_q.delete();
    for (int g = 0; g < NM; g++) begin aw_pend_q[g].delete(); ar_pend_q[g].delete(); end
    wr_if = 0; rd_if = 0; mem_wr_if = 0; mem_rd_if = 0; wm_beat = 0;
    inject_q.delete();
  endtask

  task automatic zero_counts_only();
    for (int g = 0; g < NM; g++) begin
      exp_aw[g] = 0; exp_ar[g] = 0; exp_w[g] = 0; exp_r[g] = 0; exp_err[g] = 0; exp_wait[g] = 0;
    end
  endtask

  initial begin
    for (int g = 0; g < NM; g++) begin
      bursts_left[g] = 0;
      idle_m[g]      = 1'b1;
      serial_g[g]    = 0;
    end
    clear_expectations();
  end

  // Wait counts: a clock with an address request inside the arbiter (after the slice) and not granted.
  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      for (int g = 0; g < NM; g++) begin
        if ((dut.a_awvalid[g] === 1'b1 && dut.a_awready[g] !== 1'b1) || (dut.a_arvalid[g] === 1'b1 && dut.a_arready[g] !== 1'b1)) begin
          exp_wait[g]++;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Descriptor construction
  // ---------------------------------------------------------------------------
  // Legal burst address and length: aligned start, no 4 KiB crossing, lengths
  // skewed short, some bursts ending exactly on the boundary or filling a page.
  function automatic void legal_range(input int g, input bit wr, input int mode, output bit [AW-1:0] addr, output int len);
    int base;
    int page;
    int cnt;
    int sel;
    int idx;
    int nb;
    int off;
    int maxb;
    int l0;
    int r;
    if (wr && mode == MODE_FILL && pct(70)) begin
      cnt = 0;
      for (int p = 0; p < SH_PAGES; p++) if ((p % NM) == g) cnt++;
      sel = rnd(cnt);
      idx = 0;
      page = 0;
      for (int p = 0; p < SH_PAGES; p++) begin
        if ((p % NM) == g) begin
          if (idx == sel) page = p;
          idx++;
        end
      end
      base = SH_BASE + page * PAGE;
    end else if (!wr && mode == MODE_MIXED && pct(40)) begin
      base = SH_BASE + rnd(SH_PAGES) * PAGE;
    end else begin
      base = g * OWN_SIZE + rnd(OWN_PAGES) * PAGE;
    end
    r = rnd(100);
    if (r < 8) begin
      // Ends exactly on the 4 KiB boundary.
      nb  = 1 + rnd(((PAGE / BYTES) < 64) ? (PAGE / BYTES) : 64);
      off = PAGE - nb * BYTES;
      l0  = nb - 1;
    end else if (r < 11) begin
      off = 0;
      l0  = 255;
    end else begin
      off = rnd(PAGE / BYTES) * BYTES;
      r   = rnd(100);
      if (r < 55)      l0 = rnd(8);
      else if (r < 85) l0 = 8 + rnd(56);
      else             l0 = 64 + rnd(192);
    end
    if (l0 > len_cap) l0 = len_cap;
    maxb = (PAGE - off) / BYTES;
    if (l0 > maxb - 1) l0 = maxb - 1;
    addr = AW'(base + off);
    len  = l0;
  endfunction

  // One descriptor of the given kind. Illegal kinds use the master's own region.
  function automatic desc_t build_desc(input int g, input bit wr, input int kind, input int mode);
    desc_t       d;
    bit [AW-1:0] a;
    int          l;
    int          nb;
    int          k;
    int          sz;
    int          page;
    bit [AW-1:0] pg;
    // A narrow transfer is legal for a narrow master: that kind becomes FIXED there.
    if (kind == KIND_NARROW && NARM[g]) kind = KIND_FIXED;
    // A WRAP of the legal form is legal for a master in WRAP_MASK: that kind becomes one of the illegal forms there.
    if (kind == KIND_WRAP && WRAPM[g]) kind = KIND_WRAP0 + rnd(3);
    d.g     = g;
    d.kind  = kind;
    d.is_wr = wr;
    d.id    = rnd(IDS);
    d.smode = pct(70) ? 0 : 1;
    d.beat  = 0;
    d.size  = 3'(SIZEF);
    d.burst = 2'b01;
    d.serial = 0;
    page = g * OWN_SIZE + rnd(OWN_PAGES) * PAGE;
    case (kind)
      KIND_LEGAL: begin
        legal_range(g, wr, mode, a, l);
        // A narrow master issues narrow bursts too: 40 % of its legal bursts, size
        // 0 .. full - 1, size-aligned start. Part of them end exactly on the 4 KiB
        // boundary by their own size, which a full-width calculation would reject.
        if (NARM[g] && SIZEF > 0 && pct(40)) begin
          sz = rnd(SIZEF);
          d.size = 3'(sz);
          pg = a >> 12 << 12;
          a  = a >> sz << sz;
          if (pct(30)) begin
            if (l > 63) l = 63;
            a = pg + AW'(PAGE) - (AW'(l + 1) << sz);
          end
        end
        // A master in WRAP_MASK issues legal WRAP bursts too: 25 % of its legal bursts, 2, 4, 8 or 16 beats,
        // full size (a narrow master also smaller sizes), start aligned to the size anywhere in the page.
        if (WRAPM[g] && pct(25)) begin
          case (rnd(4))
            0: l = 1;
            1: l = 3;
            2: l = 7;
            default: l = 15;
          endcase
          sz = SIZEF;
          if (NARM[g] && SIZEF > 0 && pct(40)) sz = rnd(SIZEF);
          pg = a >> 12 << 12;
          d.size  = 3'(sz);
          d.burst = 2'b10;
          a = pg + (AW'(rnd(PAGE >> sz)) << sz);
        end
        // Unaligned INCR start, 30 % of the INCR bursts: a start inside the first transfer. The size-aligned
        // start, and so the 4 KiB result, does not change; the first beat drives only the upper lanes.
        if (d.burst == 2'b01 && pct(30)) a = a + AW'(rnd(1 << d.size));
      end
      KIND_FIXED: begin
        d.burst = 2'b00;
        a = AW'(page + rnd(PAGE / BYTES / 2) * BYTES);
        l = rnd(16);
      end
      KIND_WRAP: begin
        d.burst = 2'b10;
        a = AW'(page + rnd(PAGE / BYTES / 2) * BYTES);
        case (rnd(4))
          0: l = 1;
          1: l = 3;
          2: l = 7;
          default: l = 15;
        endcase
      end
      KIND_WRAP0: begin
        d.burst = 2'b10;
        a = AW'(page + rnd(PAGE / BYTES / 2) * BYTES);
        l = 0;
      end
      KIND_WRAP2: begin
        d.burst = 2'b10;
        a = AW'(page + rnd(PAGE / BYTES / 2) * BYTES);
        l = 2;
      end
      KIND_WRAPMIS: begin
        d.burst = 2'b10;
        a = AW'(page + rnd(PAGE / BYTES / 2) * BYTES + 1);
        case (rnd(4))
          0: l = 1;
          1: l = 3;
          2: l = 7;
          default: l = 15;
        endcase
      end
      KIND_NARROW: begin
        sz = (SIZEF > 0) ? rnd(SIZEF) : 0;
        d.size = 3'(sz);
        a = AW'(page + (rnd(PAGE / BYTES / 2) * BYTES) + (rnd(BYTES) >> sz << sz));
        l = rnd(16);
      end
      KIND_NX4K: begin
        sz = (SIZEF > 0) ? rnd(SIZEF) : 0;
        d.size = 3'(sz);
        l  = 1 + rnd(15);
        nb = 1 + rnd(l);
        a  = AW'(page + PAGE - (nb << sz));
      end
      default: begin   // KIND_X4K
        l  = 1 + rnd(15);
        nb = 1 + rnd(l);
        a  = AW'(page + PAGE - nb * BYTES);
      end
    endcase
    d.addr = a;
    d.len  = l;
    return d;
  endfunction

  // Legal narrow burst: size sz (clamped below the full width), len + 1 beats,
  // size-aligned start in the master's own region, either low in a page or
  // ending exactly on the 4 KiB boundary by its own size.
  function automatic desc_t build_narrow_desc(input int g, input bit wr, input int sz, input int len, input int at_end);
    desc_t d;
    int    s;
    int    page;
    s = (SIZEF > 0) ? ((sz < SIZEF) ? sz : SIZEF - 1) : 0;
    d.g      = g;
    d.kind   = KIND_LEGAL;
    d.is_wr  = wr;
    d.id     = rnd(IDS);
    d.smode  = 1;
    d.beat   = 0;
    d.size   = 3'(s);
    d.burst  = 2'b01;
    d.serial = 0;
    d.len    = len;
    page     = g * OWN_SIZE + (3 + at_end) * PAGE;
    d.addr   = (at_end != 0) ? AW'(page + PAGE - ((len + 1) << s)) : AW'(page + 16 * (1 + rnd(8)));
    return d;
  endfunction

  // Legal WRAP burst of len + 1 beats (2, 4, 8, 16), size sz, starting at beat start_beat of its container, in
  // the master's own page 6 + (tag % 8); the container is placed at 3 container sizes into the page.
  function automatic desc_t build_wrap_desc(input int g, input bit wr, input int len, input int sz, input int start_beat,
                                            input int tag);
    desc_t       d;
    bit [AW-1:0] cont;
    bit [AW-1:0] base;
    d.g      = g;
    d.kind   = KIND_LEGAL;
    d.is_wr  = wr;
    d.id     = rnd(IDS);
    d.smode  = start_beat & 1;
    d.beat   = 0;
    d.size   = 3'(sz);
    d.burst  = 2'b10;
    d.serial = 0;
    d.len    = len;
    cont     = AW'(len + 1) << sz;
    base     = AW'(g * OWN_SIZE + (6 + (tag % 8)) * PAGE) + cont * 3;
    d.addr   = base + (AW'(start_beat) << sz);
    return d;
  endfunction

  // Unaligned INCR burst (directed): size sz (clamped to the full width), len + 1 beats, start at byte offset off
  // of page 14 + (tag % 2) of the master's own region. legal = 0 builds the kind that the arbiter must reject.
  function automatic desc_t build_unal_desc(input int g, input bit wr, input int sz, input int len, input int off,
                                            input bit legal, input int smode, input int tag);
    desc_t d;
    d.g      = g;
    d.kind   = legal ? KIND_LEGAL : ((sz < SIZEF) ? KIND_NX4K : KIND_X4K);
    d.is_wr  = wr;
    d.id     = rnd(IDS);
    d.smode  = smode;
    d.beat   = 0;
    d.size   = 3'((sz < SIZEF) ? sz : SIZEF);
    d.burst  = 2'b01;
    d.serial = 0;
    d.len    = len;
    d.addr   = AW'(g * OWN_SIZE + (14 + (tag % 2)) * PAGE + off);
    return d;
  endfunction

  // INCR full-width read of every word an INCR burst touches (the strobe check: lanes the write did not drive
  // keep their earlier value in the reference).
  function automatic desc_t build_word_read(input desc_t w);
    desc_t       d;
    bit [AW-1:0] first;
    bit [AW-1:0] last;
    first = w.addr & ~AW'(BYTES - 1);
    last  = beat_addr(w, w.len) & ~AW'(BYTES - 1);
    d.g      = w.g;
    d.kind   = KIND_LEGAL;
    d.is_wr  = 1'b0;
    d.id     = rnd(IDS);
    d.smode  = 0;
    d.beat   = 0;
    d.size   = 3'(SIZEF);
    d.burst  = 2'b01;
    d.serial = 0;
    d.addr   = first;
    d.len    = int'((last - first) / BYTES);
    return d;
  endfunction

  // INCR full-width read of every word of the container of a WRAP burst.
  function automatic desc_t build_container_read(input desc_t w);
    desc_t       d;
    bit [AW-1:0] cont;
    bit [AW-1:0] base;
    bit [AW-1:0] first;
    bit [AW-1:0] last;
    cont  = AW'(w.len + 1) << w.size;
    base  = w.addr & ~(cont - AW'(1));
    first = base & ~AW'(BYTES - 1);
    last  = (base + cont - AW'(1)) & ~AW'(BYTES - 1);
    d.g      = w.g;
    d.kind   = KIND_LEGAL;
    d.is_wr  = 1'b0;
    d.id     = rnd(IDS);
    d.smode  = 0;
    d.beat   = 0;
    d.size   = 3'(SIZEF);
    d.burst  = 2'b01;
    d.serial = 0;
    d.addr   = first;
    d.len    = int'((last - first) / BYTES);
    return d;
  endfunction

  // Failed-rule flags the arbiter must report for an illegal burst, {4 KiB, size, burst type}: the bench's
  // own statement of the rules, not shared with the RTL.
  function automatic bit [2:0] exp_fail(input desc_t d);
    bit [2:0] f;
    bit       aligned;
    bit       wrap_legal;
    int       span;
    aligned    = ((d.addr & ((AW'(1) << d.size) - AW'(1))) == '0);
    wrap_legal = WRAPM[d.g] && (d.burst == 2'b10) && (d.len == 1 || d.len == 3 || d.len == 7 || d.len == 15) && aligned;
    f[0] = !((d.burst == 2'b01) || wrap_legal);
    f[1] = NARM[d.g] ? (int'(d.size) > SIZEF) : (int'(d.size) != SIZEF);
    span = int'(d.addr[11:0] >> d.size << d.size) + ((d.len + 1) << d.size);   // AXI: from the size-aligned start
    f[2] = (d.burst != 2'b10) && (span > PAGE);
    return f;
  endfunction

  // Directed case: earlier legal bursts, one illegal burst, later legal bursts,
  // all of one master and one direction.
  task automatic inject_case(input int g, input bit wr, input int kind, input int n_pre, input int n_post);
    for (int i = 0; i < n_pre; i++) inject_q.push_back(build_desc(g, wr, KIND_LEGAL, MODE_OWN));
    inject_q.push_back(build_desc(g, wr, kind, MODE_OWN));
    for (int i = 0; i < n_post; i++) inject_q.push_back(build_desc(g, wr, KIND_LEGAL, MODE_OWN));
  endtask

  // ---------------------------------------------------------------------------
  // Channel bookkeeping shared by the master models
  // ---------------------------------------------------------------------------
  task automatic note_aw_grant(input desc_t d);
    aw_pend_q[d.g].push_back(d);
  endtask

  task automatic do_aw_grant(input desc_t d);
    if (d.burst == 2'b10) begin
      if (d.kind == KIND_LEGAL) tot_wrap_legal++;
      else                      tot_wrap_ill++;
    end
    if (d.kind == KIND_LEGAL) begin
      exp_aw[d.g]++;
      tot_legal_wr++;
      aw_chk_q.push_back(d);
      w_chk_q.push_back(d);
      wr_if++;
      if (wr_if > wr_if_max) wr_if_max = wr_if;
      tb_check(wr_if <= MAXO, $sformatf("write bursts in flight %0d exceed MAX_OUTSTANDING %0d", wr_if, MAXO));
    end else begin
      exp_err[d.g]++;
      tot_ill++;
    end
  endtask

  task automatic note_ar_grant(input desc_t d);
    ar_pend_q[d.g].push_back(d);
  endtask

  task automatic do_ar_grant(input desc_t d);
    if (d.burst == 2'b10) begin
      if (d.kind == KIND_LEGAL) tot_wrap_legal++;
      else                      tot_wrap_ill++;
    end
    if (d.kind == KIND_LEGAL) begin
      exp_ar[d.g]++;
      tot_legal_rd++;
      ar_chk_q.push_back(d);
      rd_if++;
      if (rd_if > rd_if_max) rd_if_max = rd_if;
      tb_check(rd_if <= MAXO, $sformatf("read bursts in flight %0d exceed MAX_OUTSTANDING %0d", rd_if, MAXO));
    end else begin
      exp_err[d.g]++;
      tot_ill++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Master models: one generate block per master
  // ---------------------------------------------------------------------------
  for (genvar gi = 0; gi < NM; gi++) begin : m
    localparam int G = gi;

    logic            aw_valid, w_valid, ar_valid;
    logic            b_ready, r_ready;
    logic [IDW-1:0]  aw_id, ar_id;
    logic [AW-1:0]   aw_addr, ar_addr;
    logic [7:0]      aw_len, ar_len;
    logic [2:0]      aw_size, ar_size;
    logic [1:0]      aw_burst, ar_burst;
    logic [DW-1:0]   w_data;
    logic [BYTES-1:0] w_strb;
    logic            w_last;

    assign s_awid[G*IDW +: IDW]     = aw_id;
    assign s_awaddr[G*AW +: AW]     = aw_addr;
    assign s_awlen[G*8 +: 8]        = aw_len;
    assign s_awsize[G*3 +: 3]       = aw_size;
    assign s_awburst[G*2 +: 2]      = aw_burst;
    assign s_awvalid[G]             = aw_valid;
    assign s_wdata[G*DW +: DW]      = w_data;
    assign s_wstrb[G*BYTES +: BYTES] = w_strb;
    assign s_wlast[G]               = w_last;
    assign s_wvalid[G]              = w_valid;
    assign s_bready[G]              = b_ready;
    assign s_arid[G*IDW +: IDW]     = ar_id;
    assign s_araddr[G*AW +: AW]     = ar_addr;
    assign s_arlen[G*8 +: 8]        = ar_len;
    assign s_arsize[G*3 +: 3]       = ar_size;
    assign s_arburst[G*2 +: 2]      = ar_burst;
    assign s_arvalid[G]             = ar_valid;
    assign s_rready[G]              = r_ready;

    desc_t aw_q  [$];
    desc_t w_q   [$];
    desc_t ar_q  [$];
    desc_t b_exp [$];
    desc_t r_exp [$];
    desc_t busy  [$];
    desc_t aw_cur, w_cur, ar_cur;
    bit    aw_pres = 1'b0, w_pres = 1'b0, ar_pres = 1'b0, w_have = 1'b0;
    int    w_beat  = 0;
    int    wr_out  = 0;
    int    rd_out  = 0;

    initial begin
      aw_valid = 1'b0; w_valid = 1'b0; ar_valid = 1'b0; b_ready = 1'b0; r_ready = 1'b0;
      aw_id = '0; aw_addr = '0; aw_len = '0; aw_size = '0; aw_burst = '0;
      ar_id = '0; ar_addr = '0; ar_len = '0; ar_size = '0; ar_burst = '0;
      w_data = '0; w_strb = '0; w_last = 1'b0;
    end

    // A range conflicts with a busy range of this master when they overlap and
    // either is a write.
    function automatic bit conflicts(input desc_t d);
      bit [AW-1:0] lo;
      bit [AW-1:0] hi;
      bit [AW-1:0] blo;
      bit [AW-1:0] bhi;
      lo = key_lo(d);
      hi = key_hi(d);
      for (int i = 0; i < busy.size(); i++) begin
        blo = key_lo(busy[i]);
        bhi = key_hi(busy[i]);
        if (!(hi < blo || lo > bhi) && (d.is_wr || busy[i].is_wr)) return 1'b1;
      end
      return 1'b0;
    endfunction

    task automatic busy_remove(input desc_t d);
      for (int i = 0; i < busy.size(); i++) begin
        if (busy[i].serial == d.serial && busy[i].is_wr == d.is_wr && busy[i].kind == KIND_LEGAL) begin
          busy.delete(i);
          return;
        end
      end
    endtask

    // Generator: random bursts, or the head of the directed queue when it is
    // this master's. Also flushes everything while run is low.
    always @(posedge clk) begin
      desc_t d;
      bit    have;
      bit    from_inj;
      if (!run) begin
        aw_q.delete(); w_q.delete(); ar_q.delete(); b_exp.delete(); r_exp.delete(); busy.delete();
        wr_out = 0; rd_out = 0;
      end else begin
        have     = 1'b0;
        from_inj = 1'b0;
        if (inject_q.size() > 0 && inject_q[0].g == G) begin
          d = inject_q[0]; have = 1'b1; from_inj = 1'b1;
        end else if (bursts_left[G] > 0 && pct(p_gen)) begin
          bit wr;
          wr = pct(p_wr);
          if (p_ill > 0 && pct(p_ill)) d = build_desc(G, wr, 1 + rnd(5), mode_sel);
          else                         d = build_desc(G, wr, KIND_LEGAL, mode_sel);
          have = 1'b1;
        end
        if (have) begin
          bit ok;
          ok = d.is_wr ? (wr_out < OUTS_M) : (rd_out < OUTS_M);
          if (ok && d.kind == KIND_LEGAL && conflicts(d)) ok = 1'b0;
          if (ok) begin
            d.serial = serial_g[G];
            serial_g[G]++;
            if (d.kind == KIND_LEGAL) busy.push_back(d);
            if (d.is_wr) begin
              aw_q.push_back(d); w_q.push_back(d); b_exp.push_back(d); wr_out++;
            end else begin
              ar_q.push_back(d); r_exp.push_back(d); rd_out++;
            end
            if (from_inj) void'(inject_q.pop_front());
            else          bursts_left[G]--;
          end
        end
      end
      idle_m[G] = (bursts_left[G] == 0) && (inject_q.size() == 0) && (aw_q.size() == 0) && (w_q.size() == 0) &&
                  (ar_q.size() == 0) && (b_exp.size() == 0) && (r_exp.size() == 0) && !aw_pres && !w_pres &&
                  !ar_pres && !w_have;
    end

    // AW driver.
    always @(posedge clk) begin
      if (!run) begin
        aw_valid <= 1'b0;
        aw_pres   = 1'b0;
      end else begin
        if (aw_pres && s_awready[G] === 1'b1) begin
          note_aw_grant(aw_cur);
          aw_pres = 1'b0;
          aw_valid <= 1'b0;
        end
        if (!aw_pres && aw_q.size() > 0 && pct(p_aw)) begin
          aw_cur   = aw_q.pop_front();
          aw_id   <= IDW'(aw_cur.id);
          aw_addr <= aw_cur.addr;
          aw_len  <= 8'(aw_cur.len);
          aw_size <= aw_cur.size;
          aw_burst <= aw_cur.burst;
          aw_valid <= 1'b1;
          aw_pres   = 1'b1;
        end
      end
    end

    // W driver: the beats of each write in AW order, independent of the AW
    // handshake (W may lead AW).
    always @(posedge clk) begin
      if (!run) begin
        w_valid <= 1'b0;
        w_pres   = 1'b0;
        w_have   = 1'b0;
        w_beat   = 0;
      end else begin
        if (w_pres && s_wready[G] === 1'b1) begin
          if (w_cur.kind == KIND_LEGAL) exp_w[G]++;
          if (w_beat == w_cur.len) begin
            w_have = 1'b0;
            w_beat = 0;
          end else begin
            w_beat++;
          end
          w_pres = 1'b0;
          w_valid <= 1'b0;
        end
        if (!w_pres) begin
          if (!w_have && w_q.size() > 0) begin
            w_cur  = w_q.pop_front();
            w_have = 1'b1;
            w_beat = 0;
          end
          if (w_have && pct(p_w)) begin
            w_data  <= pat_data(G, w_cur.serial, w_beat);
            w_strb  <= (w_cur.kind == KIND_LEGAL) ? exp_strb(w_cur, w_beat) : '1;
            w_last  <= (w_beat == w_cur.len);
            w_valid <= 1'b1;
            w_pres   = 1'b1;
          end
        end
      end
    end

    // AR driver.
    always @(posedge clk) begin
      if (!run) begin
        ar_valid <= 1'b0;
        ar_pres   = 1'b0;
      end else begin
        if (ar_pres && s_arready[G] === 1'b1) begin
          note_ar_grant(ar_cur);
          ar_pres = 1'b0;
          ar_valid <= 1'b0;
        end
        if (!ar_pres && ar_q.size() > 0 && pct(p_ar)) begin
          ar_cur   = ar_q.pop_front();
          ar_id   <= IDW'(ar_cur.id);
          ar_addr <= ar_cur.addr;
          ar_len  <= 8'(ar_cur.len);
          ar_size <= ar_cur.size;
          ar_burst <= ar_cur.burst;
          ar_valid <= 1'b1;
          ar_pres   = 1'b1;
        end
      end
    end

    // B channel: responses by ID, in per-ID order; an illegal write's answer
    // comes after every earlier write of this master.
    always @(posedge clk) begin
      if (!run) begin
        b_ready <= 1'b0;
      end else begin
        b_ready <= pct(p_bready);
        if (s_bvalid[G] === 1'b1 && b_ready === 1'b1) begin
          int          pos;
          int          bid;
          desc_t       d;
          bid = int'(s_bid[G*IDW +: IDW]);
          pos = -1;
          for (int i = 0; i < b_exp.size(); i++) begin
            if (pos < 0 && b_exp[i].id == bid) pos = i;
          end
          tb_check(pos >= 0, $sformatf("master %0d: B with ID %0d, no write outstanding with that ID", G, bid));
          if (pos >= 0) begin
            d = b_exp[pos];
            if (d.kind == KIND_LEGAL) begin
              tb_check(s_bresp[G*2 +: 2] === 2'b00, $sformatf("master %0d: legal write B resp %0d", G, s_bresp[G*2 +: 2]));
              ref_apply_write(d);
              busy_remove(d);
              wr_if--;
            end else begin
              tb_check(s_bresp[G*2 +: 2] === 2'b10, $sformatf("master %0d: illegal write (kind %0d) B resp %0d, want SLVERR", G,
                                                              d.kind, s_bresp[G*2 +: 2]));
              tb_check(pos == 0, $sformatf("master %0d: illegal write answered with %0d earlier write(s) outstanding", G, pos));
            end
            b_exp.delete(pos);
            wr_out--;
          end
        end
      end
    end

    // R channel: beats by ID against the reference memory; an illegal read's
    // len + 1 SLVERR beats come after every earlier read of this master.
    always @(posedge clk) begin
      if (!run) begin
        r_ready <= 1'b0;
      end else begin
        r_ready <= pct(p_rready);
        if (s_rvalid[G] === 1'b1 && r_ready === 1'b1) begin
          int            pos;
          int            rid;
          desc_t         d;
          bit [DW-1:0]   want;
          bit            last_exp;
          rid = int'(s_rid[G*IDW +: IDW]);
          pos = -1;
          for (int i = 0; i < r_exp.size(); i++) begin
            if (pos < 0 && r_exp[i].id == rid) pos = i;
          end
          tb_check(pos >= 0, $sformatf("master %0d: R with ID %0d, no read outstanding with that ID", G, rid));
          if (pos >= 0) begin
            d = r_exp[pos];
            last_exp = (d.beat == d.len);
            tb_check(s_rlast[G] === last_exp, $sformatf("master %0d: RLAST %0b on beat %0d of %0d (ID %0d)", G, s_rlast[G],
                                                        d.beat, d.len + 1, rid));
            if (d.kind == KIND_LEGAL) begin
              want = ref_word(beat_key(d, d.beat)) & lane_bits(d, d.beat);
              tb_check(s_rresp[G*2 +: 2] === 2'b00, $sformatf("master %0d: legal read R resp %0d", G, s_rresp[G*2 +: 2]));
              tb_check((s_rdata[G*DW +: DW] & lane_bits(d, d.beat)) === want, $sformatf("master %0d: read data mismatch addr 0x%0h beat %0d got 0x%0h want 0x%0h",
                                                              G, d.addr, d.beat, s_rdata[G*DW +: DW], want));
              exp_r[G]++;
            end else begin
              tb_check(s_rresp[G*2 +: 2] === 2'b10, $sformatf("master %0d: illegal read (kind %0d) R resp %0d, want SLVERR", G,
                                                              d.kind, s_rresp[G*2 +: 2]));
              tb_check(s_rdata[G*DW +: DW] === '0, $sformatf("master %0d: illegal read RDATA not 0", G));
              tb_check(pos == 0, $sformatf("master %0d: illegal read answered with %0d earlier read(s) outstanding", G, pos));
            end
            if (last_exp) begin
              if (d.kind == KIND_LEGAL) begin
                busy_remove(d);
                rd_if--;
              end
              r_exp.delete(pos);
              rd_out--;
            end else begin
              r_exp[pos].beat = d.beat + 1;
            end
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Memory-side monitors: AW, W and AR at the memory port equal the grant order
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      if (m_awvalid === 1'b1 && m_awready === 1'b1) begin
        mem_wr_if++;
        if (mem_wr_if > mem_wr_if_max) mem_wr_if_max = mem_wr_if;
        tb_check(mem_wr_if <= MAXO, $sformatf("memory-side writes in flight %0d exceed MAX_OUTSTANDING", mem_wr_if));
        if (aw_chk_q.size() == 0) begin
          tb_error("AW at the memory port with no granted write behind it");
        end else begin
          desc_t d;
          d = aw_chk_q.pop_front();
          tb_check(m_awid === MIDW'((d.g << IDW) | d.id) && m_awaddr === d.addr && int'(m_awlen) == d.len &&
                   m_awsize === d.size && m_awburst === d.burst,
                   $sformatf("memory AW id 0x%0h addr 0x%0h len %0d differs from the grant order (master %0d addr 0x%0h len %0d)",
                             m_awid, m_awaddr, m_awlen, d.g, d.addr, d.len));
        end
      end
      if (m_wvalid === 1'b1 && m_wready === 1'b1) begin
        if (w_chk_q.size() == 0) begin
          tb_error("W beat at the memory port with no granted write behind it");
        end else begin
          desc_t d;
          d = w_chk_q[0];
          tb_check(m_wdata === pat_data(d.g, d.serial, wm_beat) &&
                   m_wstrb === exp_strb(d, wm_beat),
                   $sformatf("W beat %0d at the memory port is not beat %0d of master %0d write serial %0d (interleave or misroute)",
                             wm_beat, wm_beat, d.g, d.serial));
          tb_check(m_wlast === (wm_beat == d.len), $sformatf("WLAST %0b on beat %0d of %0d at the memory port", m_wlast,
                                                            wm_beat, d.len + 1));
          if (wm_beat == d.len) begin
            void'(w_chk_q.pop_front());
            wm_beat = 0;
          end else begin
            wm_beat++;
          end
        end
      end
      if (m_bvalid === 1'b1 && m_bready === 1'b1) begin
        mem_wr_if--;
      end
      if (m_arvalid === 1'b1 && m_arready === 1'b1) begin
        mem_rd_if++;
        if (mem_rd_if > mem_rd_if_max) mem_rd_if_max = mem_rd_if;
        tb_check(mem_rd_if <= MAXO, $sformatf("memory-side reads in flight %0d exceed MAX_OUTSTANDING", mem_rd_if));
        if (ar_chk_q.size() == 0) begin
          tb_error("AR at the memory port with no granted read behind it");
        end else begin
          desc_t d;
          d = ar_chk_q.pop_front();
          tb_check(m_arid === MIDW'((d.g << IDW) | d.id) && m_araddr === d.addr && int'(m_arlen) == d.len &&
                   m_arsize === d.size && m_arburst === d.burst,
                   $sformatf("memory AR id 0x%0h addr 0x%0h len %0d differs from the grant order (master %0d addr 0x%0h len %0d)",
                             m_arid, m_araddr, m_arlen, d.g, d.addr, d.len));
        end
      end
      if (m_rvalid === 1'b1 && m_rready === 1'b1 && m_rlast === 1'b1) begin
        mem_rd_if--;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Grant monitor, priority and round-robin monitors
  // ---------------------------------------------------------------------------
  // The grant of a clock is the arbiter's fire with the master it chose; the bench processes it a picosecond after the edge, after the master
  // models have taken their handshakes of that edge (with ADDR_REG 0 the handshake and the grant are the same clock). The monitors compare the
  // grant with the requests of the clock before (aw_req and ar_req of the arbiter: what the pick saw, a master with an unanswered illegal
  // burst excluded) and count, for every round-robin master, the grants of other round-robin masters it saw while it waited.
  logic [NM-1:0] aw_req_d1 = '0;
  logic [NM-1:0] ar_req_d1 = '0;
  int            grant_aw_n = 0;
  int            grant_ar_n = 0;
  always @(posedge clk) begin
    logic [NM-1:0] v;
    logic [NM-1:0] hpv;
    int            gi;
    int            low;
    bit            rr_valid;
    bit            f_aw;
    bit            f_ar;
    int            ix_aw;
    int            ix_ar;
    logic [NM-1:0] rq_aw;
    logic [NM-1:0] rq_ar;
    f_aw  = (resetn === 1'b1) && (dut.aw_fire === 1'b1);
    f_ar  = (resetn === 1'b1) && (dut.ar_fire === 1'b1);
    ix_aw = int'(dut.aw_idx);
    ix_ar = int'(dut.ar_idx);
    rq_aw = aw_req_d1;
    rq_ar = ar_req_d1;
    aw_req_d1 = dut.aw_req;
    ar_req_d1 = dut.ar_req;
    #1ps;
    if (f_aw) begin
      grant_aw_n++;
      if (aw_pend_q[ix_aw].size() == 0) tb_error($sformatf("AW grant of master %0d with no burst accepted from it", ix_aw));
      else begin
        desc_t d;
        d = aw_pend_q[ix_aw].pop_front();
        do_aw_grant(d);
      end
    end
    if (f_ar) begin
      grant_ar_n++;
      if (ar_pend_q[ix_ar].size() == 0) tb_error($sformatf("AR grant of master %0d with no burst accepted from it", ix_ar));
      else begin
        desc_t d;
        d = ar_pend_q[ix_ar].pop_front();
        do_ar_grant(d);
      end
    end
    if (mon_en && resetn === 1'b1) begin
      // AW channel.
      v = rq_aw; hpv = v & HPM;
      gi = f_aw ? ix_aw : -1;
      if (gi >= 0) begin
        low = -1;
        for (int i = NM - 1; i >= 0; i--) if (hpv[i]) low = i;
        rr_valid = ((v & ~HPM) != '0);
        tb_check(v[gi] === 1'b1, $sformatf("AW grant of master %0d which did not request in the clock before", gi));
        if (hpv != '0) begin
          tb_check(gi == low, $sformatf("AW arbitration: master %0d granted while high-priority master %0d requests", gi, low));
          hp_grants++;
          if (rr_valid) hp_contended++;
        end else begin
          rr_grants++;
        end
        for (int i = 0; i < NM; i++) begin
          if (!HPM[i]) begin
            if (gi == i) begin
              if (aw_wait_c[i] > rr_wait_max_aw) rr_wait_max_aw = aw_wait_c[i];
              tb_check(aw_wait_c[i] <= NM - 1, $sformatf("AW round robin: master %0d waited %0d grants of others", i, aw_wait_c[i]));
              aw_wait_c[i] = 0;
            end else if (v[i] === 1'b1 && !HPM[gi]) begin
              aw_wait_c[i]++;
            end
          end
        end
      end
      for (int i = 0; i < NM; i++) if (v[i] !== 1'b1) aw_wait_c[i] = 0;
      // AR channel.
      v = rq_ar; hpv = v & HPM;
      gi = f_ar ? ix_ar : -1;
      if (gi >= 0) begin
        low = -1;
        for (int i = NM - 1; i >= 0; i--) if (hpv[i]) low = i;
        tb_check(v[gi] === 1'b1, $sformatf("AR grant of master %0d which did not request in the clock before", gi));
        if (hpv != '0) begin
          tb_check(gi == low, $sformatf("AR arbitration: master %0d granted while high-priority master %0d requests", gi, low));
        end
        for (int i = 0; i < NM; i++) begin
          if (!HPM[i]) begin
            if (gi == i) begin
              if (ar_wait_c[i] > rr_wait_max_ar) rr_wait_max_ar = ar_wait_c[i];
              tb_check(ar_wait_c[i] <= NM - 1, $sformatf("AR round robin: master %0d waited %0d grants of others", i, ar_wait_c[i]));
              ar_wait_c[i] = 0;
            end else if (v[i] === 1'b1 && !HPM[gi]) begin
              ar_wait_c[i]++;
            end
          end
        end
      end
      for (int i = 0; i < NM; i++) if (v[i] !== 1'b1) ar_wait_c[i] = 0;
    end
  end

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function automatic bit all_idle();
    for (int g = 0; g < NM; g++) if (!idle_m[g]) return 1'b0;
    return 1'b1;
  endfunction

  task automatic wait_idle(input string what);
    int quiet;
    int t;
    quiet = 0;
    t     = 0;
    while (quiet < 40 && t < TMO_CLK) begin
      @(posedge clk);
      t++;
      if (all_idle()) quiet++;
      else            quiet = 0;
    end
    tb_check(quiet >= 40, {what, ": traffic did not drain"});
  endtask

  task automatic reg_expect(input logic [11:0] a, input logic [31:0] exp, input string what);
    logic [31:0] d;
    u_axi.rd(a, d);
    tb_check(d === exp, $sformatf("%s: register 0x%03x = 0x%08x, expected 0x%08x", what, a, d, exp));
  endtask

  task automatic reg_zero_check(input string what);
    for (int g = 0; g < NM; g++) begin
      for (int o = 0; o < 6; o++) reg_expect(12'h100 + 12'(g * 32 + o * 4), 32'd0, {what, " counter after clear"});
    end
  endtask

  // Every counter of every master against the bench's counts.
  task automatic check_counters(input string what);
    for (int g = 0; g < NM; g++) begin
      reg_expect(12'h100 + 12'(g * 32) + 12'h00, 32'(exp_aw[g]),   $sformatf("%s master %0d AW_BURSTS", what, g));
      reg_expect(12'h100 + 12'(g * 32) + 12'h04, 32'(exp_ar[g]),   $sformatf("%s master %0d AR_BURSTS", what, g));
      reg_expect(12'h100 + 12'(g * 32) + 12'h08, 32'(exp_w[g]),    $sformatf("%s master %0d W_BEATS", what, g));
      reg_expect(12'h100 + 12'(g * 32) + 12'h0C, 32'(exp_r[g]),    $sformatf("%s master %0d R_BEATS", what, g));
      reg_expect(12'h100 + 12'(g * 32) + 12'h10, 32'(exp_err[g]),  $sformatf("%s master %0d ERRORS", what, g));
      reg_expect(12'h100 + 12'(g * 32) + 12'h14, 32'(exp_wait[g]), $sformatf("%s master %0d WAIT_CYCLES", what, g));
    end
  endtask

  // The memory model saw exactly the legal bursts, none of the illegal ones.
  task automatic check_memory_counts(input string what);
    tb_check(u_mem.aw_count - mem_aw_base == tot_legal_wr, $sformatf("%s: memory model took %0d writes, %0d were legal", what,
                                                                    u_mem.aw_count - mem_aw_base, tot_legal_wr));
    tb_check(u_mem.ar_count - mem_ar_base == tot_legal_rd, $sformatf("%s: memory model took %0d reads, %0d were legal", what,
                                                                    u_mem.ar_count - mem_ar_base, tot_legal_rd));
  endtask

  // Run one traffic phase to completion: n bursts per master.
  task automatic traffic(input int n, input string what);
    for (int g = 0; g < NM; g++) bursts_left[g] = n;
    run = 1'b1;
    wait_idle(what);
  endtask

  // Grant latency monitor: clocks from the first clock a master's AW (AR) valid is high to the first clock the master-side valid is high.
  int  lat_cnt  = 0;
  int  lat_in   = -1;
  int  lat_out  = -1;
  bit  lat_arm  = 1'b0;
  bit  lat_wr   = 1'b0;
  int  lat_g    = 0;
  always @(posedge clk) begin
    lat_cnt <= lat_cnt + 1;
    if (lat_arm) begin
      if (lat_in < 0 && (lat_wr ? (s_awvalid[lat_g] === 1'b1) : (s_arvalid[lat_g] === 1'b1))) lat_in = lat_cnt;
      if (lat_in >= 0 && lat_out < 0 && (lat_wr ? (m_awvalid === 1'b1) : (m_arvalid === 1'b1))) lat_out = lat_cnt;
    end
  end

  // Directed grant cases. (1) Latency of a lone burst of every master, both directions: 3 clocks from the master's valid to the master-side
  // valid with ADDR_REG 1, 2 with ADDR_REG 0. (2) Back-to-back 8-beat bursts of every master at once, saturated, with the priority and
  // round-robin monitors on: the grant order and the data are checked by the always-on monitors, the register counters afterwards.
  task automatic directed_grants();
    int exp_lat;
    exp_lat = (ADDRREG ? 3 : 2) + ($test$plusargs("INJECT_LATENCY") ? 1 : 0);
    set_gaps(1'b0);
    mode_sel = MODE_OWN; p_wr = 50;
    for (int g = 0; g < NM; g++) begin
      for (int dir = 0; dir < 2; dir++) begin
        lat_g = g; lat_wr = (dir == 0); lat_in = -1; lat_out = -1; lat_arm = 1'b1;
        inject_q.push_back(build_desc(g, (dir == 0), KIND_LEGAL, MODE_OWN));
        run = 1'b1;
        wait_idle("grant latency");
        lat_arm = 1'b0;
        tb_check(lat_in >= 0 && lat_out >= 0 && (lat_out - lat_in) == exp_lat,
                 $sformatf("grant latency master %0d %s: %0d clocks, expected %0d", g, (dir == 0) ? "AW" : "AR", lat_out - lat_in, exp_lat));
      end
    end
    mon_en = 1'b1;
    len_cap = 7;
    traffic(scaled(80), "back-to-back 8-beat bursts");
    len_cap = 255;
    mon_en = 1'b0;
    check_counters("after the directed grant cases");
    check_memory_counts("after the directed grant cases");
  endtask

  function automatic int scaled(input int n);
    int v;
    v = (n * `TB_SIZE) / 100;
    return (v < 1) ? 1 : v;
  endfunction

  // Gaps on or off for the masters.
  task automatic set_gaps(input bit on);
    p_aw     = on ? 60 : 100;
    p_w      = on ? 65 : 100;
    p_ar     = on ? 60 : 100;
    p_bready = on ? 55 : 100;
    p_rready = on ? 60 : 100;
    p_gen    = on ? 50 : 100;
  endtask

  // Directed legal WRAP traffic: every length and start offset, per master in WRAP_MASK (full size, a narrow master
  // also byte and half-width sizes): WRAP write, WRAP read at another start, INCR read of the whole container.
  task automatic directed_wrap_legal();
    int lens [4];
    int sizes [3];
    int n_sizes;
    int tag;
    desc_t w;
    int n_start;
    lens[0] = 1; lens[1] = 3; lens[2] = 7; lens[3] = 15;
    tag = 0;
    for (int g = 0; g < NM; g++) begin
      if (WRAPM[g]) begin
        n_sizes = 1;
        sizes[0] = SIZEF;
        if (NARM[g] && SIZEF > 0) begin
          sizes[1] = 0;
          n_sizes  = 2;
          if (SIZEF > 1) begin
            sizes[2] = SIZEF - 1;
            n_sizes  = 3;
          end
        end
        for (int si = 0; si < n_sizes; si++) begin
          for (int li = 0; li < 4; li++) begin
            n_start = lens[li] + 1;
            for (int s = 0; s < n_start; s++) begin
              w = build_wrap_desc(g, 1'b1, lens[li], sizes[si], s, tag);
              inject_q.push_back(w);
              inject_q.push_back(build_wrap_desc(g, 1'b0, lens[li], sizes[si], (s * 3 + 1) % n_start, tag));
              inject_q.push_back(build_container_read(w));
              tag++;
              run = 1'b1;
              if ((s % 4) == 3) wait_idle("directed legal WRAP");
            end
            run = 1'b1;
            wait_idle("directed legal WRAP");
          end
        end
      end
    end
  endtask

  // Directed unaligned INCR starts. Accepted (each write with smode 0 and 1, then a read of the same bytes and a
  // full-width read of the words): a narrow master at size 2 len 0 at 0xFFD and 0xFFF, len 3 at 0xFF1 (aligned
  // start 0xFF0, ends exactly at 0x1000); every master at the full size len 0 at the last word + 1 and len 1 at
  // the word before it + 1. Rejected: size 2 len 1 at 0xFFD (aligned start 0xFFC + 8 > 4096, narrow masters) and
  // the full size len 1 at the last word + 1 (every master). Returns the number of rejected bursts issued.
  task automatic directed_unaligned(output int n_ill);
    int    tag;
    desc_t w;
    n_ill = 0;
    tag   = 0;
    for (int g = 0; g < NM; g++) begin
      for (int sm = 0; sm < 2; sm++) begin
        if (NARM[g] && SIZEF >= 2) begin
          w = build_unal_desc(g, 1'b1, 2, 0, PAGE - 3, 1'b1, sm, tag);
          inject_q.push_back(w);
          inject_q.push_back(build_unal_desc(g, 1'b0, 2, 0, PAGE - 3, 1'b1, sm, tag));
          inject_q.push_back(build_word_read(w));
          tag++;
          w = build_unal_desc(g, 1'b1, 2, 0, PAGE - 1, 1'b1, sm, tag);
          inject_q.push_back(w);
          inject_q.push_back(build_unal_desc(g, 1'b0, 2, 0, PAGE - 1, 1'b1, sm, tag));
          inject_q.push_back(build_word_read(w));
          tag++;
          w = build_unal_desc(g, 1'b1, 2, 3, PAGE - 15, 1'b1, sm, tag);
          inject_q.push_back(w);
          inject_q.push_back(build_unal_desc(g, 1'b0, 2, 3, PAGE - 15, 1'b1, sm, tag));
          inject_q.push_back(build_word_read(w));
          tag++;
        end
        w = build_unal_desc(g, 1'b1, SIZEF, 0, PAGE - BYTES + 1, 1'b1, sm, tag);
        inject_q.push_back(w);
        inject_q.push_back(build_unal_desc(g, 1'b0, SIZEF, 0, PAGE - BYTES + 1, 1'b1, sm, tag));
        inject_q.push_back(build_word_read(w));
        tag++;
        w = build_unal_desc(g, 1'b1, SIZEF, 1, PAGE - 2 * BYTES + 1, 1'b1, sm, tag);
        inject_q.push_back(w);
        inject_q.push_back(build_unal_desc(g, 1'b0, SIZEF, 1, PAGE - 2 * BYTES + 1, 1'b1, sm, tag));
        inject_q.push_back(build_word_read(w));
        tag++;
        run = 1'b1;
        wait_idle($sformatf("directed unaligned INCR master %0d", g));
      end
      for (int dir = 0; dir < 2; dir++) begin
        if (NARM[g] && SIZEF >= 2) begin
          inject_q.push_back(build_unal_desc(g, 1'b1, 2, 0, PAGE - 3, 1'b1, 0, tag));
          inject_q.push_back(build_unal_desc(g, (dir == 0), 2, 1, PAGE - 3, 1'b0, 0, tag));
          inject_q.push_back(build_unal_desc(g, 1'b0, 2, 0, PAGE - 3, 1'b1, 0, tag));
          n_ill++;
        end
        inject_q.push_back(build_unal_desc(g, 1'b1, SIZEF, 0, PAGE - BYTES + 1, 1'b1, 0, tag));
        inject_q.push_back(build_unal_desc(g, (dir == 0), SIZEF, 1, PAGE - BYTES + 1, 1'b0, 0, tag));
        inject_q.push_back(build_unal_desc(g, 1'b0, SIZEF, 0, PAGE - BYTES + 1, 1'b1, 0, tag));
        n_ill++;
        run = 1'b1;
        wait_idle($sformatf("directed unaligned INCR rejected master %0d dir %0d", g, dir));
      end
    end
  endtask

  // Directed illegal WRAPs, read and write, each between legal bursts of the same master: a master in WRAP_MASK
  // with len 0, len 2 and a misaligned start; a master not in the mask with a WRAP of the legal form.
  // Returns the number of illegal bursts issued.
  task automatic directed_wrap_illegal(output int n_ill);
    n_ill = 0;
    for (int g = 0; g < NM; g++) begin
      for (int dir = 0; dir < 2; dir++) begin
        if (WRAPM[g]) begin
          for (int k = KIND_WRAP0; k <= KIND_WRAPMIS; k++) begin
            inject_case(g, (dir == 0), k, 2, 2);
            run = 1'b1;
            wait_idle($sformatf("illegal WRAP kind %0d master %0d dir %0d", k, g, dir));
            n_ill++;
          end
        end else begin
          inject_case(g, (dir == 0), KIND_WRAP, 2, 2);
          run = 1'b1;
          wait_idle($sformatf("illegal WRAP from master %0d outside WRAP_MASK dir %0d", g, dir));
          n_ill++;
        end
      end
    end
  endtask

  // One capture check: clear, no capture, one illegal burst, the capture holds exactly that burst.
  task automatic capture_case(input desc_t d, input string what);
    logic [31:0] info;
    logic [31:0] want;
    u_axi.wr(R_STATUS, 32'h1);
    reg_expect(R_CAP_INFO, 32'h0, {what, ": CAP_INFO after STATUS.ERR clear"});
    reg_expect(R_CAP_ADDR, 32'h0, {what, ": CAP_ADDR after STATUS.ERR clear"});
    inject_q.push_back(d);
    run = 1'b1;
    wait_idle(what);
    repeat (10) @(posedge clk);
    want = '0;
    want[0]     = 1'b1;
    want[1]     = !d.is_wr;
    want[4:2]   = 3'(d.g);
    want[7:5]   = d.size;
    want[15:8]  = 8'(d.len);
    want[17:16] = d.burst;
    want[20:18] = exp_fail(d);
    tb_check(exp_fail(d) != 3'b000, {what, ": bench expects at least one failed rule"});
    reg_expect(R_CAP_INFO, want, {what, ": CAP_INFO"});
    reg_expect(R_CAP_ADDR, 32'(d.addr), {what, ": CAP_ADDR"});
    reg_expect(R_CAP_ADDRH, 32'h0, {what, ": CAP_ADDR_HI"});
  endtask

  // Capture registers: each kind of illegal burst, read and write, on rotating masters; stickiness of the first;
  // clears; ERRORS counters follow.
  task automatic directed_capture();
    desc_t d;
    desc_t d2;
    logic [31:0] info0;
    logic [31:0] a0;
    logic [31:0] v;
    int    g;
    int    n;
    n = 0;
    g = 0;
    for (int dir = 0; dir < 2; dir++) begin
      for (int k = KIND_FIXED; k <= KIND_WRAPMIS; k++) begin
        d = build_desc(g, (dir == 0), k, MODE_OWN);
        capture_case(d, $sformatf("capture kind %0d dir %0d master %0d", d.kind, dir, g));
        n++;
        g = (g + 1) % NM;
      end
    end
    // Stickiness: the second illegal burst does not replace the first; STATUS.ERR clear and CNT_CLEAR clear it.
    d  = build_desc(0, 1'b1, KIND_X4K, MODE_OWN);
    d2 = build_desc((NM > 1) ? 1 : 0, 1'b0, KIND_FIXED, MODE_OWN);
    capture_case(d, "stickiness first burst");
    u_axi.rd(R_CAP_INFO, info0);
    u_axi.rd(R_CAP_ADDR, a0);
    inject_q.push_back(d2);
    run = 1'b1;
    wait_idle("stickiness second burst");
    repeat (10) @(posedge clk);
    reg_expect(R_CAP_INFO, info0, "stickiness: CAP_INFO keeps the first illegal burst");
    reg_expect(R_CAP_ADDR, a0, "stickiness: CAP_ADDR keeps the first illegal burst");
    u_axi.wr(R_STATUS, 32'h0000_0001);
    reg_expect(R_CAP_INFO, 32'h0, "CAP_INFO cleared by STATUS.ERR");
    inject_q.push_back(d2);
    run = 1'b1;
    wait_idle("capture before CNT_CLEAR");
    repeat (10) @(posedge clk);
    u_axi.rd(R_CAP_INFO, v);
    tb_check(v[0] === 1'b1, "capture valid before CNT_CLEAR");
    u_axi.wr(R_CTRL, CTRL_CNT_CLEAR);
    zero_counts_only();
    reg_expect(R_CAP_INFO, 32'h0, "CAP_INFO cleared by CTRL.CNT_CLEAR");
    reg_expect(R_CAP_ADDR, 32'h0, "CAP_ADDR cleared by CTRL.CNT_CLEAR");
    u_axi.wr(R_STATUS, 32'h0000_0001);
    // Read-only: writes do not change it.
    inject_q.push_back(d2);
    run = 1'b1;
    wait_idle("capture before write attempt");
    repeat (10) @(posedge clk);
    u_axi.rd(R_CAP_INFO, info0);
    u_axi.wr(R_CAP_INFO, 32'hFFFF_FFFF);
    u_axi.wr(R_CAP_ADDR, 32'hFFFF_FFFF);
    u_axi.wr(R_CAP_ADDRH, 32'hFFFF_FFFF);
    u_axi.wr(R_WRAP, 32'hFFFF_FFFF);
    reg_expect(R_CAP_INFO, info0, "CAP_INFO after write attempt");
    reg_expect(R_WRAP, 32'(WRAPM), "WRAP after write attempt");
    u_axi.wr(R_STATUS, 32'h0000_0001);
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin : main
    logic [31:0] d;
    logic [1:0]  resp;
    int          per;
    int          bursts_before;
    int          errs_before;
    int          polls;
    int          cs;
    int          n_dir;
    int          n_wrap_ill;
    int          n_unal_ill;

    #100;
    arstn = 1'b1;
    repeat (30) @(posedge clk);
    mem_aw_base = u_mem.aw_count;
    mem_ar_base = u_mem.ar_count;

    // ---- 1. Header and reset values --------------------------------------------
    reg_expect(R_ID,      32'h4152_4254, "ID");
    reg_expect(R_VERSION, 32'h1109_2026, "VERSION");
    reg_expect(R_CAPS,    {8'(HPM), 8'(MAXO), 4'(IDW), 8'(BYTES), 4'(NM)}, "CAPS");
    reg_expect(R_NARROW,  32'(NARM), "NARROW");
    reg_expect(R_WRAP,    32'(WRAPM), "WRAP");
    reg_expect(R_CAP_INFO, 32'h0, "CAP_INFO reset");
    reg_expect(R_CAP_ADDR, 32'h0, "CAP_ADDR reset");
    reg_expect(R_CAP_ADDRH, 32'h0, "CAP_ADDR_HI reset");
    reg_expect(R_CTRL,    32'h0, "CTRL reset");
    reg_expect(R_STATUS,  32'h0, "STATUS reset");
    tb_check(err_irq === 1'b0, "err_irq low after reset");
    reg_zero_check("reset");
    reg_expect(12'h020,           32'h0, "undefined offset 0x020");
    reg_expect(12'h0FC,           32'h0, "undefined offset 0x0FC");
    reg_expect(12'h118,           32'h0, "undefined offset inside master 0 window");
    reg_expect(12'h11C,           32'h0, "undefined offset inside master 0 window");
    reg_expect(12'h100 + 12'(NM * 32), 32'h0, "master window above NUM_MASTERS");
    reg_expect(12'h2F4,           32'h0, "undefined offset 0x2F4");
    reg_expect(12'hFFC,           32'h0, "undefined offset 0xFFC");
    u_axi.wr(R_ID,      32'hFFFF_FFFF);
    u_axi.wr(R_VERSION, 32'hFFFF_FFFF);
    u_axi.wr(R_CAPS,    32'hFFFF_FFFF);
    u_axi.wr(R_NARROW,  32'hFFFF_FFFF);
    u_axi.wr(12'h100,   32'hFFFF_FFFF);
    reg_expect(R_ID,      32'h4152_4254, "ID after write attempt");
    reg_expect(R_VERSION, 32'h1109_2026, "VERSION after write attempt");
    reg_expect(R_NARROW,  32'(NARM), "NARROW after write attempt");
    reg_expect(12'h100,   32'h0, "read-only counter after write attempt");
    u_axi.write32(R_CTRL, CTRL_CNT_CLEAR, 4'h3, resp);
    reg_expect(R_STATUS,  32'h0, "partial write to CTRL has no effect");

    // ---- 2. Data integrity ------------------------------------------------------
    // Fill: each master writes its pages of the shared region.
    per = scaled(((2400 + NM - 1) / NM) / 5);
    mode_sel = MODE_FILL; p_wr = 100; p_ill = 0; len_cap = 255;
    set_gaps(1'b0);
    mon_en = 1'b1;
    traffic(per, "fill");
    check_counters("after fill");
    check_memory_counts("after fill");
    // Saturated mixed traffic, shared region read everywhere.
    per = scaled((((2400 + NM - 1) / NM) * 2) / 5);
    mode_sel = MODE_MIXED; p_wr = 50;
    for (int g = 0; g < NM; g++) bursts_left[g] = per;
    run = 1'b1;
    repeat (400) @(posedge clk);
    u_axi.rd(R_STATUS, d);
    if (d[2:1] == 2'b11) status_busy_seen++;
    wait_idle("saturated mixed");
    tb_check(status_busy_seen > 0, "STATUS write/read in-flight bits seen set under saturated traffic");
    u_axi.rd(R_STATUS, d);
    tb_check(d[2:1] == 2'b00, $sformatf("STATUS in-flight bits clear when idle (0x%08x)", d));
    check_counters("after saturated mixed");
    check_memory_counts("after saturated mixed");
    // Gapped mixed traffic.
    set_gaps(1'b1);
    traffic(per, "gapped mixed");
    mon_en = 1'b0;
    check_counters("after gapped mixed");
    check_memory_counts("after gapped mixed");
    tb_check(tot_legal_wr + tot_legal_rd >= 2000 * `TB_SIZE / 100, $sformatf("only %0d legal bursts, need at least 2000",
                                                                            tot_legal_wr + tot_legal_rd));
    tb_check(tot_ill == 0, "no illegal bursts in the data-integrity phases");
    integrity_bursts = tot_legal_wr + tot_legal_rd;

    // Long bursts only, saturated: fills the in-flight limit at the memory port.
    set_gaps(1'b0);
    len_cap = 255; mode_sel = MODE_MIXED; p_wr = 50;
    mon_en = 1'b1;
    traffic(scaled(24), "long bursts");
    mon_en = 1'b0;
    check_counters("after long bursts");

    // ---- 3. CNT_CLEAR ------------------------------------------------------------
    u_axi.write32(R_CTRL, CTRL_CNT_CLEAR, 4'h7, resp);
    check_counters("partial write to CTRL does not clear");
    u_axi.wr(R_CTRL, CTRL_CNT_CLEAR);
    reg_expect(R_CTRL, 32'h0, "CNT_CLEAR reads 0 (self-clearing)");
    zero_counts_only();
    check_counters("after CNT_CLEAR");
    traffic(scaled(10), "after clear");
    check_counters("after clear and traffic");

    // ---- 4. Illegal bursts -------------------------------------------------------
    // Directed: each kind, read and write, on rotating masters.
    set_gaps(1'b0);
    mode_sel = MODE_OWN;
    reg_expect(R_STATUS, 32'h0, "STATUS.ERR clear before the illegal cases");
    tb_check(err_irq === 1'b0, "err_irq low before the illegal cases");
    errs_before = tot_ill;
    cs = 0;
    n_dir = 0;
    for (int kind = KIND_FIXED; kind <= KIND_NX4K; kind++) begin
      for (int dir = 0; dir < 2; dir++) begin
        int g;
        int tries;
        g = cs % NM;
        // A narrow-size burst is legal for a narrow master: use a full-width one,
        // and skip the kind when every master is narrow.
        tries = 0;
        while (kind == KIND_NARROW && NARM[g] && tries < NM) begin
          g = (g + 1) % NM;
          tries++;
        end
        if (kind == KIND_NARROW && NARM[g]) continue;
        cs++;
        n_dir++;
        inject_case(g, (dir == 0), kind, 3, 2);
        run = 1'b1;
        wait_idle($sformatf("illegal case kind %0d dir %0d", kind, dir));
        if (cs == 1) begin
          repeat (10) @(posedge clk);
          tb_check(err_irq === 1'b1, "err_irq high after the first illegal burst");
          u_axi.rd(R_STATUS, d);
          tb_check(d[0] === 1'b1, "STATUS.ERR set after the first illegal burst");
        end
      end
    end
    // Narrow masters only: a legal narrow single beat and burst with strobes, directed,
    // then a narrow burst crossing 4 KiB by its own size (an error) and one that ends on
    // the boundary by its own size (legal; a full-width span would cross).
    if (NARM != '0) begin
      for (int g = 0; g < NM; g++) begin
        if (NARM[g]) begin
          inject_q.push_back(build_narrow_desc(g, 1'b1, 0, 0, 0));
          inject_q.push_back(build_narrow_desc(g, 1'b1, 1, 7, 0));
          inject_q.push_back(build_narrow_desc(g, 1'b1, 2, 31, 1));
          inject_q.push_back(build_narrow_desc(g, 1'b0, 0, 0, 0));
          inject_q.push_back(build_narrow_desc(g, 1'b0, 1, 7, 0));
          inject_q.push_back(build_narrow_desc(g, 1'b0, 2, 31, 1));
          run = 1'b1;
          wait_idle("directed narrow legal");
          for (int dir = 0; dir < 2; dir++) begin
            inject_case(g, (dir == 0), KIND_NX4K, 2, 2);
            run = 1'b1;
            wait_idle("directed narrow crossing 4 KiB");
            n_dir++;
          end
        end
      end
    end
    // Unaligned INCR starts: the accepted ones reach the memory model, the rejected ones do not.
    directed_unaligned(n_unal_ill);
    n_dir += n_unal_ill;
    tb_check(tot_ill - errs_before == n_dir, $sformatf("%0d directed illegal bursts issued, %0d counted", n_dir,
                                                       tot_ill - errs_before));
    check_counters("after directed illegal bursts");
    check_memory_counts("after directed illegal bursts");
    u_axi.rd(R_STATUS, d);
    tb_check(d[0] === 1'b1 && err_irq === 1'b1, "STATUS.ERR sticky and err_irq high after the illegal cases");
    u_axi.wr(R_STATUS, 32'hFFFF_FFFE);
    u_axi.rd(R_STATUS, d);
    tb_check(d[0] === 1'b1 && err_irq === 1'b1, "STATUS.ERR not cleared by writing 0 to bit 0");
    u_axi.wr(R_STATUS, 32'h0000_0001);
    u_axi.rd(R_STATUS, d);
    tb_check(d[0] === 1'b0 && err_irq === 1'b0, "STATUS.ERR and err_irq cleared by writing 1");
    // A second error sets it again; counters keep counting through the clear.
    inject_case(0, 1'b1, KIND_X4K, 0, 0);
    run = 1'b1;
    wait_idle("single illegal write");
    repeat (10) @(posedge clk);
    u_axi.rd(R_STATUS, d);
    tb_check(d[0] === 1'b1 && err_irq === 1'b1, "STATUS.ERR set again by a new illegal burst");
    u_axi.wr(R_STATUS, 32'h1);
    check_counters("after the second illegal burst");

    // Directed WRAP and capture phases (the capture phase runs in every configuration).
    if (WRAPM != '0) begin
      mon_en = 1'b1;
      directed_wrap_legal();
      mon_en = 1'b0;
      check_counters("after directed legal WRAP");
      check_memory_counts("after directed legal WRAP");
    end
    errs_before = tot_ill;
    directed_wrap_illegal(n_wrap_ill);
    tb_check(tot_ill - errs_before == n_wrap_ill, $sformatf("%0d directed illegal WRAPs issued, %0d counted", n_wrap_ill,
                                                           tot_ill - errs_before));
    check_counters("after directed illegal WRAP");
    check_memory_counts("after directed illegal WRAP");
    u_axi.wr(R_STATUS, 32'h1);
    directed_capture();
    check_counters("after the capture cases");
    check_memory_counts("after the capture cases");

    // Random illegal bursts mixed into legal traffic of all masters (gapped).
    set_gaps(1'b1);
    mode_sel = MODE_MIXED; p_ill = 15; p_wr = 50;
    traffic((scaled(60) < 24) ? 24 : scaled(60), "mixed illegal");   // enough bursts for illegal ones at 15 %
    p_ill = 0;
    check_counters("after mixed illegal traffic");
    check_memory_counts("after mixed illegal traffic");
    tb_check(err_irq === 1'b1, "err_irq high after mixed illegal traffic");
    u_axi.wr(R_STATUS, 32'h1);
    tb_check(err_irq === 1'b0, "err_irq low after clear");

    // Directed grant cases: latency and back-to-back bursts of every master.
    directed_grants();

    // ---- 5. Reset in the middle of traffic ----------------------------------------
    set_gaps(1'b0);
    mode_sel = MODE_OWN; p_wr = 50; len_cap = 255;
    for (int g = 0; g < NM; g++) bursts_left[g] = 400;
    run = 1'b1;
    polls = 0;
    while ((u_mem.aw_count - mem_aw_base < 20 || u_mem.ar_count - mem_ar_base < 20) && polls < 200000) begin
      @(posedge clk);
      polls++;
    end
    repeat (37) @(posedge clk);
    tb_check(wr_if > 0 || rd_if > 0, "traffic in flight when reset is applied");
    arstn = 1'b0;
    run   = 1'b0;
    repeat (8) @(posedge clk);
    arstn = 1'b1;
    repeat (12) @(posedge clk);
    tb_check(resetn === 1'b1, "arbiter reset released");
    u_mem.clear_memory();
    ref_mem.delete();
    clear_expectations();
    for (int g = 0; g < NM; g++) bursts_left[g] = 0;
    tot_legal_wr = 0; tot_legal_rd = 0; tot_ill = 0;
    mem_aw_base = u_mem.aw_count;
    mem_ar_base = u_mem.ar_count;
    repeat (10) @(posedge clk);
    reg_expect(R_STATUS, 32'h0, "STATUS after reset");
    tb_check(err_irq === 1'b0, "err_irq low after reset");
    reg_zero_check("after reset");
    reg_expect(R_CAP_INFO, 32'h0, "CAP_INFO after reset");
    reg_expect(R_WRAP, 32'(WRAPM), "WRAP after reset");
    reg_expect(R_ID, 32'h4152_4254, "ID after reset");
    // Clean traffic again, both gap settings.
    mon_en = 1'b1;
    mode_sel = MODE_FILL; p_wr = 100;
    traffic(scaled(10), "fill after reset");
    mode_sel = MODE_MIXED; p_wr = 50;
    traffic(scaled(60), "saturated after reset");
    set_gaps(1'b1);
    traffic(scaled(60), "gapped after reset");
    mon_en = 1'b0;
    check_counters("after reset and clean traffic");
    check_memory_counts("after reset and clean traffic");

    $display("BENCH_STATS: NM=%0d DW=%0d LAT=%0d integrity_bursts=%0d (all legal, checked beat by beat)", NM, DW, LAT,
             integrity_bursts);
    $display("BENCH_STATS: max_wr_inflight=%0d max_rd_inflight=%0d mem_side_max_wr=%0d mem_side_max_rd=%0d", wr_if_max, rd_if_max,
             mem_wr_if_max, mem_rd_if_max);
    $display("BENCH_STATS: rr_wait_max_aw=%0d rr_wait_max_ar=%0d (limit %0d) hp_grants=%0d hp_contended=%0d rr_grants=%0d",
             rr_wait_max_aw, rr_wait_max_ar, NM - 1, hp_grants, hp_contended, rr_grants);
    $display("BENCH_STATS: WRAPM=%0d legal_wrap_bursts=%0d illegal_wrap_bursts=%0d", int'(WRAPM), tot_wrap_legal, tot_wrap_ill);
    tb_check(wr_if_max <= MAXO && rd_if_max <= MAXO, "in-flight maxima within MAX_OUTSTANDING");
    if (WRAPM != '0) tb_check(tot_wrap_legal >= 60, $sformatf("only %0d legal WRAP bursts exercised", tot_wrap_legal));
    tb_check(tot_wrap_ill >= 4, $sformatf("only %0d illegal WRAP bursts exercised", tot_wrap_ill));
    tb_verdict(BENCH);
  end

endmodule
