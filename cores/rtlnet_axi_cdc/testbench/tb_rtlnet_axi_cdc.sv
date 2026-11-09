// -----------------------------------------------------------------------------
// File: tb_rtlnet_axi_cdc.sv
// Purpose: self-checking bench for rtlnet_axi_cdc: a random AXI4 master on s_clk,
//   the AXI4 memory model rtlnet_tb_axi4_mem as the far-side slave on m_clk, two
//   unrelated clocks.
// Cases:
//   1. Phase A: concurrent random writes (own region, random strobes, IDs 0..2^ID_W-1,
//      lock/cache/prot/qos random) and random reads (preloaded read-only region), bursts
//      of 1..16 beats, a share of 1-beat bursts, and (TB_BIG) 256-beat bursts. AW and W run
//      independently (W may lead AW). Random valid and ready gaps on both sides (TB_GAP).
//   2. Per-beat checks: every AW, AR and W beat leaving the master port equals the beat
//      the slave port accepted (all fields, in order); every B returns the ID of its AW in
//      order with OKAY; every R beat has the right ID, data, RESP and RLAST.
//   3. After phase A drains: the memory model's contents equal the bench's reference memory
//      (strobes merged in AW order), and its AW/W/AR/R counters equal the issued counts.
//   4. Phase B: random reads over the written region against the reference memory.
//   5. With TB_GAP = 0: one isolated 1-beat write and read, latency printed in ns and clocks.
// Configuration (defines, defaults in brackets): TB_DW data width [128], TB_AW address width
//   [29], TB_IDW ID width [2], TB_SPER and TB_MPER s_clk and m_clk period in ps [10000],
//   TB_MAXB MAX_BURST_BEATS [16], TB_FKB W and R FIFO kilobytes [1], TB_GAP 1 for random gaps
//   [1], TB_N transactions per direction in phase A [1200], TB_BIG 1 for 256-beat bursts [0],
//   TB_LAT memory read latency in clocks [0].
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Run: powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_axi_cdc
//        -Filelist cores/rtlnet_axi_cdc/testbench/tb_rtlnet_axi_cdc.f
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_DW
  `define TB_DW 128
`endif
`ifndef TB_AW
  `define TB_AW 29
`endif
`ifndef TB_IDW
  `define TB_IDW 2
`endif
`ifndef TB_SPER
  `define TB_SPER 10000
`endif
`ifndef TB_MPER
  `define TB_MPER 10000
`endif
`ifndef TB_MAXB
  `define TB_MAXB 16
`endif
`ifndef TB_FKB
  `define TB_FKB 1
`endif
`ifndef TB_GAP
  `define TB_GAP 1
`endif
`ifndef TB_N
  `define TB_N 1200
`endif
`ifndef TB_BIG
  `define TB_BIG 0
`endif
`ifndef TB_LAT
  `define TB_LAT 0
`endif

module tb_rtlnet_axi_cdc;

  import rtlnet_tb_pkg::*;

  localparam string BENCH = "tb_rtlnet_axi_cdc";

  localparam int DW    = `TB_DW;
  localparam int AW    = `TB_AW;
  localparam int IDW   = `TB_IDW;
  localparam int MAXB  = `TB_MAXB;
  localparam int GAPS  = `TB_GAP;
  localparam int NTXN  = `TB_N;
  localparam int BIG   = `TB_BIG;
  localparam int BYTES = DW / 8;
  localparam int SIZEF = $clog2(BYTES);
  localparam int PAGE  = 4096;
  localparam int WPP   = PAGE / BYTES;            // words per page
  localparam int REG_PAGES = 16;
  localparam int DRV_PCT = (GAPS != 0) ? 60 : 100;
  localparam int MEM_PCT = (GAPS != 0) ? 55 : 100;
  localparam real SHALF  = `TB_SPER / 2000.0;
  localparam real MHALF  = `TB_MPER / 2000.0;
  localparam bit [AW-1:0] RBASE = AW'(64'h0000_000A_0800_0000);   // read-only region, preloaded
  localparam bit [AW-1:0] WBASE = AW'(64'h0000_0005_0200_0000);   // write region

  // ---------------------------------------------------------------------------
  // Clocks and resets: odd phase offset, one assertion for both resets
  // ---------------------------------------------------------------------------
  logic s_clk = 1'b0;
  logic m_clk = 1'b0;
  logic arstn = 1'b0;
  logic s_resetn, m_resetn;

  initial begin
    #1.37;
    forever #(SHALF) s_clk = ~s_clk;
  end
  initial begin
    forever #(MHALF) m_clk = ~m_clk;
  end

  rtlnet_reset_sync u_rst_s (.clk(s_clk), .arstn(arstn), .resetn(s_resetn));
  rtlnet_reset_sync u_rst_m (.clk(m_clk), .arstn(arstn), .resetn(m_resetn));

  // ---------------------------------------------------------------------------
  // DUT and memory model
  // ---------------------------------------------------------------------------
  logic [IDW-1:0]   s_awid;    logic [AW-1:0] s_awaddr;  logic [7:0] s_awlen;  logic [2:0] s_awsize;
  logic [1:0]       s_awburst; logic s_awlock;           logic [3:0] s_awcache; logic [2:0] s_awprot;
  logic [3:0]       s_awqos;   logic s_awvalid, s_awready;
  logic [DW-1:0]    s_wdata;   logic [BYTES-1:0] s_wstrb; logic s_wlast, s_wvalid, s_wready;
  logic [IDW-1:0]   s_bid;     logic [1:0] s_bresp;      logic s_bvalid, s_bready;
  logic [IDW-1:0]   s_arid;    logic [AW-1:0] s_araddr;  logic [7:0] s_arlen;  logic [2:0] s_arsize;
  logic [1:0]       s_arburst; logic s_arlock;           logic [3:0] s_arcache; logic [2:0] s_arprot;
  logic [3:0]       s_arqos;   logic s_arvalid, s_arready;
  logic [IDW-1:0]   s_rid;     logic [DW-1:0] s_rdata;   logic [1:0] s_rresp;  logic s_rlast, s_rvalid, s_rready;

  logic [IDW-1:0]   m_awid;    logic [AW-1:0] m_awaddr;  logic [7:0] m_awlen;  logic [2:0] m_awsize;
  logic [1:0]       m_awburst; logic m_awlock;           logic [3:0] m_awcache; logic [2:0] m_awprot;
  logic [3:0]       m_awqos;   logic m_awvalid, m_awready;
  logic [DW-1:0]    m_wdata;   logic [BYTES-1:0] m_wstrb; logic m_wlast, m_wvalid, m_wready;
  logic [IDW-1:0]   m_bid;     logic [1:0] m_bresp;      logic m_bvalid, m_bready;
  logic [IDW-1:0]   m_arid;    logic [AW-1:0] m_araddr;  logic [7:0] m_arlen;  logic [2:0] m_arsize;
  logic [1:0]       m_arburst; logic m_arlock;           logic [3:0] m_arcache; logic [2:0] m_arprot;
  logic [3:0]       m_arqos;   logic m_arvalid, m_arready;
  logic [IDW-1:0]   m_rid;     logic [DW-1:0] m_rdata;   logic [1:0] m_rresp;  logic m_rlast, m_rvalid, m_rready;

  rtlnet_axi_cdc #(.ADDR_W(AW), .DATA_W(DW), .ID_W(IDW), .MAX_BURST_BEATS(MAXB),
                   .W_FIFO_KB(`TB_FKB), .R_FIFO_KB(`TB_FKB)) dut (
    .s_clk(s_clk), .s_resetn(s_resetn),
    .s_axi_awid(s_awid), .s_axi_awaddr(s_awaddr), .s_axi_awlen(s_awlen), .s_axi_awsize(s_awsize),
    .s_axi_awburst(s_awburst), .s_axi_awlock(s_awlock), .s_axi_awcache(s_awcache), .s_axi_awprot(s_awprot),
    .s_axi_awqos(s_awqos), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
    .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wlast(s_wlast), .s_axi_wvalid(s_wvalid),
    .s_axi_wready(s_wready),
    .s_axi_bid(s_bid), .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
    .s_axi_arid(s_arid), .s_axi_araddr(s_araddr), .s_axi_arlen(s_arlen), .s_axi_arsize(s_arsize),
    .s_axi_arburst(s_arburst), .s_axi_arlock(s_arlock), .s_axi_arcache(s_arcache), .s_axi_arprot(s_arprot),
    .s_axi_arqos(s_arqos), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
    .s_axi_rid(s_rid), .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rlast(s_rlast),
    .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready),
    .m_clk(m_clk), .m_resetn(m_resetn),
    .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
    .m_axi_awburst(m_awburst), .m_axi_awlock(m_awlock), .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot),
    .m_axi_awqos(m_awqos), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
    .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wvalid(m_wvalid),
    .m_axi_wready(m_wready),
    .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
    .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
    .m_axi_arburst(m_arburst), .m_axi_arlock(m_arlock), .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot),
    .m_axi_arqos(m_arqos), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
    .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
    .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
  );

  rtlnet_tb_axi4_mem #(.ADDR_W(AW), .DATA_W(DW), .ID_W(IDW), .READ_LATENCY(`TB_LAT), .AW_READY_PCT(MEM_PCT),
                       .W_READY_PCT(MEM_PCT), .AR_READY_PCT(MEM_PCT), .B_VALID_PCT(MEM_PCT), .R_VALID_PCT(MEM_PCT),
                       .SEED(11)) u_mem (
    .clk(m_clk), .resetn(m_resetn),
    .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
    .awvalid(m_awvalid), .awready(m_awready),
    .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
    .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
    .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst),
    .arvalid(m_arvalid), .arready(m_arready),
    .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready)
  );

  // ---------------------------------------------------------------------------
  // Random numbers, patterns, reference memory
  // ---------------------------------------------------------------------------
  typedef struct {
    bit [IDW-1:0] id;
    bit [AW-1:0]  addr;
    int           len;
    bit           lock;
    bit [3:0]     cache;
    bit [2:0]     prot;
    bit [3:0]     qos;
  } txn_t;

  typedef struct {
    bit [DW-1:0]    data;
    bit [BYTES-1:0] strb;
    bit             last;
  } wbeat_t;

  typedef struct {
    bit [IDW-1:0] id;
    bit [DW-1:0]  data;
    bit           last;
  } rexp_t;

  txn_t   aw_l [$];
  wbeat_t w_l  [$];
  txn_t   ar_l [$];
  rexp_t  rexp_l [$];
  logic [DW-1:0] ref_mem [bit [AW-1:0]];

  int unsigned lcg_state = 32'h1357_9BDF;
  int unsigned data_ctr  = 0;

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

  // Preloaded read data of the word with key k.
  function automatic bit [DW-1:0] patt(input bit [AW-1:0] k);
    bit [DW-1:0] d;
    for (int c = 0; c < DW / 32; c++) d[c*32 +: 32] = hash32(32'(k) * 32'h0100_0193 + 32'(c) + 32'(k >> 32));
    return d;
  endfunction

  function automatic bit [DW-1:0] ref_word(input bit [AW-1:0] k);
    return ref_mem.exists(k) ? ref_mem[k] : '0;
  endfunction

  // Random burst inside one page of the 16-page region at base.
  task automatic mk_burst(input bit [AW-1:0] base, output bit [AW-1:0] addr, output int len);
    int page, r, off;
    page = rnd(REG_PAGES);
    r    = rnd(100);
    if (BIG != 0 && r < 6)  len = 255;
    else if (r < 40)        len = 0;
    else                    len = rnd(16);
    if (len + 1 > MAXB) len = MAXB - 1;
    off  = rnd(WPP - len);
    addr = base + AW'(page * PAGE) + AW'(off * BYTES);
  endtask

  task automatic mk_txn(input bit [AW-1:0] base, output txn_t t);
    t.id    = IDW'(rnd(1 << IDW));
    mk_burst(base, t.addr, t.len);
    t.lock  = rnd(2);
    t.cache = 4'(rnd(16));
    t.prot  = 3'(rnd(8));
    t.qos   = 4'(rnd(16));
  endtask

  task automatic gen_writes(input int n);
    for (int i = 0; i < n; i++) begin
      txn_t t;
      mk_txn(WBASE, t);
      aw_l.push_back(t);
      for (int k = 0; k <= t.len; k++) begin
        wbeat_t      b;
        bit [AW-1:0] key;
        bit [DW-1:0] old;
        for (int c = 0; c < DW / 32; c++) b.data[c*32 +: 32] = hash32(data_ctr + 32'(c));
        data_ctr = data_ctr + 32'd16;
        if (rnd(2) == 0) b.strb = '1;
        else for (int l = 0; l < BYTES; l++) b.strb[l] = rnd(2);
        b.last = (k == t.len);
        w_l.push_back(b);
        key = (t.addr >> SIZEF) + AW'(k);
        old = ref_word(key);
        for (int l = 0; l < BYTES; l++) begin
          if (b.strb[l]) old[l*8 +: 8] = b.data[l*8 +: 8];
        end
        ref_mem[key] = old;
      end
    end
  endtask

  // Reads of a region; from_ref selects the reference memory (written region) over the preload pattern.
  task automatic gen_reads(input int n, input bit [AW-1:0] base, input bit from_ref);
    for (int i = 0; i < n; i++) begin
      txn_t t;
      mk_txn(base, t);
      ar_l.push_back(t);
      for (int k = 0; k <= t.len; k++) begin
        rexp_t       e;
        bit [AW-1:0] key;
        key    = (t.addr >> SIZEF) + AW'(k);
        e.id   = t.id;
        e.data = from_ref ? ref_word(key) : patt(key);
        e.last = (k == t.len);
        rexp_l.push_back(e);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Slave-side master: AW, W, AR drivers, B and R checkers (s_clk)
  // ---------------------------------------------------------------------------
  int aw_i = 0, w_i = 0, ar_i = 0, b_chk = 0, r_chk = 0;
  real t_aw_s, t_w_s, t_ar_s, t_b_s, t_r_s;

  always @(posedge s_clk) begin
    if (!s_resetn) begin
      s_awvalid <= 1'b0; s_wvalid <= 1'b0; s_arvalid <= 1'b0;
      s_bready  <= 1'b0; s_rready <= 1'b0;
    end else begin
      if (s_awvalid && s_awready) t_aw_s = $realtime;
      if (s_wvalid  && s_wready && s_wlast) t_w_s = $realtime;
      if (s_arvalid && s_arready) t_ar_s = $realtime;

      if (!s_awvalid || s_awready) begin
        if (aw_i < aw_l.size() && pct(DRV_PCT)) begin
          s_awvalid <= 1'b1;
          s_awid    <= aw_l[aw_i].id;
          s_awaddr  <= aw_l[aw_i].addr;
          s_awlen   <= 8'(aw_l[aw_i].len);
          s_awsize  <= 3'(SIZEF);
          s_awburst <= 2'b01;
          s_awlock  <= aw_l[aw_i].lock;
          s_awcache <= aw_l[aw_i].cache;
          s_awprot  <= aw_l[aw_i].prot;
          s_awqos   <= aw_l[aw_i].qos;
          aw_i++;
        end else s_awvalid <= 1'b0;
      end

      if (!s_wvalid || s_wready) begin
        if (w_i < w_l.size() && pct(DRV_PCT)) begin
          s_wvalid <= 1'b1;
          s_wdata  <= w_l[w_i].data;
          s_wstrb  <= w_l[w_i].strb;
          s_wlast  <= w_l[w_i].last;
          w_i++;
        end else s_wvalid <= 1'b0;
      end

      if (!s_arvalid || s_arready) begin
        if (ar_i < ar_l.size() && pct(DRV_PCT)) begin
          s_arvalid <= 1'b1;
          s_arid    <= ar_l[ar_i].id;
          s_araddr  <= ar_l[ar_i].addr;
          s_arlen   <= 8'(ar_l[ar_i].len);
          s_arsize  <= 3'(SIZEF);
          s_arburst <= 2'b01;
          s_arlock  <= ar_l[ar_i].lock;
          s_arcache <= ar_l[ar_i].cache;
          s_arprot  <= ar_l[ar_i].prot;
          s_arqos   <= ar_l[ar_i].qos;
          ar_i++;
        end else s_arvalid <= 1'b0;
      end

      s_bready <= pct(DRV_PCT);
      s_rready <= pct(DRV_PCT);

      if (s_bvalid && s_bready) begin
        t_b_s = $realtime;
        if (b_chk >= aw_l.size()) begin
          tb_error("B with no outstanding write");
        end else begin
          tb_check(s_bid === aw_l[b_chk].id, $sformatf("B %0d: id %0d, expected %0d", b_chk, s_bid, aw_l[b_chk].id));
          tb_check(s_bresp === 2'b00, $sformatf("B %0d: resp %0d, expected OKAY", b_chk, s_bresp));
        end
        b_chk++;
      end

      if (s_rvalid && s_rready) begin
        t_r_s = $realtime;
        if (r_chk >= rexp_l.size()) begin
          tb_error("R beat with no outstanding read");
        end else begin
          tb_check(s_rid === rexp_l[r_chk].id, $sformatf("R beat %0d: id %0d, expected %0d", r_chk, s_rid, rexp_l[r_chk].id));
          tb_check(s_rdata === rexp_l[r_chk].data,
                   $sformatf("R beat %0d: data %0h, expected %0h", r_chk, s_rdata, rexp_l[r_chk].data));
          tb_check(s_rresp === 2'b00, $sformatf("R beat %0d: resp %0d", r_chk, s_rresp));
          tb_check(s_rlast === rexp_l[r_chk].last, $sformatf("R beat %0d: last %0b, expected %0b", r_chk, s_rlast, rexp_l[r_chk].last));
        end
        r_chk++;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Master-side monitors (m_clk): every beat leaving equals the beat that entered
  // ---------------------------------------------------------------------------
  int aw_mon = 0, w_mon = 0, ar_mon = 0;
  real t_aw_m, t_w_m, t_ar_m, t_b_m, t_r_m;

  always @(posedge m_clk) begin
    if (m_resetn) begin
      if (m_awvalid && m_awready) begin
        t_aw_m = $realtime;
        if (aw_mon >= aw_l.size()) tb_error("AW leaves the master port that never entered");
        else begin
          tb_check(m_awid === aw_l[aw_mon].id && m_awaddr === aw_l[aw_mon].addr && int'(m_awlen) == aw_l[aw_mon].len &&
                   m_awsize === 3'(SIZEF) && m_awburst === 2'b01,
                   $sformatf("AW %0d: id/addr/len/size/burst altered (%0h/%0h/%0d)", aw_mon, m_awid, m_awaddr, m_awlen));
          tb_check(m_awlock === aw_l[aw_mon].lock && m_awcache === aw_l[aw_mon].cache && m_awprot === aw_l[aw_mon].prot &&
                   m_awqos === aw_l[aw_mon].qos, $sformatf("AW %0d: lock/cache/prot/qos altered", aw_mon));
        end
        aw_mon++;
      end
      if (m_wvalid && m_wready) begin
        if (m_wlast) t_w_m = $realtime;
        if (w_mon >= w_l.size()) tb_error("W beat leaves the master port that never entered");
        else begin
          tb_check(m_wdata === w_l[w_mon].data && m_wstrb === w_l[w_mon].strb && m_wlast === w_l[w_mon].last,
                   $sformatf("W beat %0d altered: data %0h strb %0h last %0b", w_mon, m_wdata, m_wstrb, m_wlast));
        end
        w_mon++;
      end
      if (m_arvalid && m_arready) begin
        t_ar_m = $realtime;
        if (ar_mon >= ar_l.size()) tb_error("AR leaves the master port that never entered");
        else begin
          tb_check(m_arid === ar_l[ar_mon].id && m_araddr === ar_l[ar_mon].addr && int'(m_arlen) == ar_l[ar_mon].len &&
                   m_arsize === 3'(SIZEF) && m_arburst === 2'b01 && m_arlock === ar_l[ar_mon].lock &&
                   m_arcache === ar_l[ar_mon].cache && m_arprot === ar_l[ar_mon].prot && m_arqos === ar_l[ar_mon].qos,
                   $sformatf("AR %0d altered: id %0h addr %0h len %0d", ar_mon, m_arid, m_araddr, m_arlen));
        end
        ar_mon++;
      end
      if (m_bvalid && m_bready) t_b_m = $realtime;
      if (m_rvalid && m_rready) t_r_m = $realtime;
    end
  end

  // ---------------------------------------------------------------------------
  // Sequence
  // ---------------------------------------------------------------------------
  task automatic wait_drain(input string what);
    int guard;
    guard = 0;
    while (!(b_chk == aw_l.size() && r_chk == rexp_l.size() && ar_mon == ar_l.size() && aw_mon == aw_l.size() &&
             w_mon == w_l.size()) && guard < 4000000) begin
      @(posedge s_clk);
      guard++;
    end
    if (guard >= 4000000) begin
      tb_error($sformatf("%s: timeout (aw %0d/%0d w %0d/%0d ar %0d/%0d b %0d/%0d r %0d/%0d)", what,
                         aw_mon, aw_l.size(), w_mon, w_l.size(), ar_mon, ar_l.size(), b_chk, aw_l.size(), r_chk, rexp_l.size()));
      tb_verdict(BENCH);
    end
    repeat (50) @(posedge s_clk);
  endtask

  task automatic compare_memory(input string what);
    bit [AW-1:0] k;
    int          nwords;
    nwords = 0;
    if (ref_mem.first(k)) begin
      do begin
        tb_check(u_mem.peek(k << SIZEF) === ref_mem[k], $sformatf("%s: memory word key %0h = %0h, expected %0h", what, k,
                                                               u_mem.peek(k << SIZEF), ref_mem[k]));
        nwords++;
      end while (ref_mem.next(k));
    end
    tb_check(nwords > 0, $sformatf("%s: reference memory empty", what));
  endtask

  task automatic print_latency;
    $display("LATENCY (ns, s_clk %0d ps, m_clk %0d ps): AW s->m %0.1f  W(last) s->m %0.1f  B m->s %0.1f  AR s->m %0.1f  R(1 beat) m->s %0.1f  read AR->R %0.1f",
             `TB_SPER, `TB_MPER, t_aw_m - t_aw_s, t_w_m - t_w_s, t_b_s - t_b_m, t_ar_m - t_ar_s, t_r_s - t_r_m, t_r_s - t_ar_s);
  endtask

  initial begin
    // Preload the read-only region.
    for (int w = 0; w < (REG_PAGES * PAGE) / BYTES; w++) u_mem.poke(RBASE + AW'(w * BYTES), patt((RBASE >> SIZEF) + AW'(w)));
    s_awvalid = 1'b0; s_wvalid = 1'b0; s_arvalid = 1'b0; s_bready = 1'b0; s_rready = 1'b0;
    s_awid = '0; s_awaddr = '0; s_awlen = '0; s_awsize = '0; s_awburst = '0; s_awlock = 1'b0; s_awcache = '0;
    s_awprot = '0; s_awqos = '0; s_wdata = '0; s_wstrb = '0; s_wlast = 1'b0;
    s_arid = '0; s_araddr = '0; s_arlen = '0; s_arsize = '0; s_arburst = '0; s_arlock = 1'b0; s_arcache = '0;
    s_arprot = '0; s_arqos = '0;
    #200;
    arstn = 1'b1;
    repeat (20) @(posedge s_clk);

    // Phase A: concurrent random writes and reads.
    gen_writes(NTXN);
    gen_reads(NTXN, RBASE, 1'b0);
    wait_drain("phase A");
    tb_check(u_mem.aw_count == aw_l.size() && u_mem.w_beats == w_l.size(), "phase A: memory write counters differ from issued");
    tb_check(u_mem.ar_count == ar_l.size() && u_mem.r_beats == rexp_l.size(), "phase A: memory read counters differ from issued");
    compare_memory("phase A");

    // Phase B: read back the written region.
    gen_reads(NTXN / 3, WBASE, 1'b1);
    wait_drain("phase B");
    tb_check(u_mem.ar_count == ar_l.size() && u_mem.r_beats == rexp_l.size(), "phase B: memory read counters differ from issued");

    // Isolated 1-beat write and read for the latency figures.
    if (GAPS == 0) begin
      begin
        txn_t   t;
        wbeat_t b;
        t.id = IDW'(1); t.addr = WBASE; t.len = 0; t.lock = 1'b0; t.cache = 4'h3; t.prot = 3'h0; t.qos = 4'h0;
        b.data = patt(64'h55); b.strb = '1; b.last = 1'b1;
        aw_l.push_back(t); w_l.push_back(b);
        ref_mem[t.addr >> SIZEF] = b.data;
        wait_drain("latency write");
        gen_reads(1, WBASE, 1'b1);
        wait_drain("latency read");
        print_latency();
      end
    end

    tb_check(aw_l.size() + ar_l.size() >= 2000, "fewer than 2000 transactions issued");
    $display("TRANSACTIONS: %0d writes (%0d beats), %0d reads (%0d beats)", aw_l.size(), w_l.size(), ar_l.size(), rexp_l.size());
    tb_verdict(BENCH);
  end

  initial begin
    #(900ms);
    tb_error("watchdog timeout");
    tb_verdict(BENCH);
  end

endmodule
