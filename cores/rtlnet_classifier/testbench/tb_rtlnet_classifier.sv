// -----------------------------------------------------------------------------
// File: tb_rtlnet_classifier.sv
// Purpose: self-checking bench for rtlnet_classifier against an independent
//   reference model of the specification (cores/rtlnet_classifier/
//   documentation/rtlnet_classifier.md).
// Overview:
//   * Build configurations (defines): default 64-byte match depth (16/16
//     entries, 2 lanes, 2 rules, 4 policers); TB_CLS_M128 (128 bytes, 4
//     lanes); TB_CLS_M40 (40 bytes, 8/4 entries, 4 rules, 2 policers).
//     AXIS_CLK_HZ is 100 kHz in the bench (100 clocks per millisecond) so
//     policer windows are short; axis_clk 100 MHz and s_axi_aclk 76.9 MHz
//     are unrelated clocks.
//   * Model: the bench keeps its own copy of every register it writes and
//     computes, for every frame it sends, the field values (untagged and
//     VLAN-aware offsets, absent bytes), every table hit, the tuple hits, the
//     rule matches, the match / MODE decision, the policer choice and budget,
//     and every counter. Output frames must equal the frames the model passes,
//     byte for byte and in order.
//   * Timing: every accepted input beat and every output beat is time
//     stamped; with a gap-free source and a ready sink each beat must leave
//     exactly DELAY_BEATS + 2 clocks after it was accepted (ingress register,
//     line, output slice), DELAY_BEATS read from the LATENCY register and
//     checked against MATCH_DEPTH_BYTES / 8 + VERDICT_LATENCY and the DUT
//     localparam.
//   * Phases: identification; power-up drop-all; each MODE; the broadcast
//     storm configuration (exactly LIMIT broadcasts per window, unicast
//     unaffected, several windows, limit/window changes, limit 0, disable);
//     directed field-table, tuple, rule-operator, absent-byte, rule
//     combination and policer-priority checks (each expectation hand-written
//     and also compared with the model); delay-line exactness over frame
//     lengths; back-to-back 60-byte frames at full rate; overrun of
//     back-to-back runts; CLEAR_TABLES, readback and the update protocol;
//     random configurations with random frames, source gaps and sink stalls
//     (RANDOM_CONFIGS x FRAMES_PER_CONFIG frames); counters and identities.
//   * Plusargs: +INJECT_FAILURE (negative control), +SEED=<n>, +PERTURB=<k>
//     (proves checks can fail: 1 expected latency +1, 2 model range upper
//     bound exclusive, 3 model storm limit +1, 4 model LT as LE, 5 model
//     drops VLAN awareness, 6 model counter FRAMES +1).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_classifier;

  import rtlnet_tb_pkg::*;

  // ---------------------------------------------------------------------------
  // Build configuration.
  // ---------------------------------------------------------------------------
`ifdef TB_CLS_M128
  localparam int MDB   = 128;
  localparam int TE    = 16;
  localparam int TU    = 16;
  localparam int LANES = 4;
  localparam int NR    = 2;
  localparam int NP    = 4;
`elsif TB_CLS_M40
  localparam int MDB   = 40;
  localparam int TE    = 8;
  localparam int TU    = 4;
  localparam int LANES = 2;
  localparam int NR    = 4;
  localparam int NP    = 2;
`else
  localparam int MDB   = 64;
  localparam int TE    = 16;
  localparam int TU    = 16;
  localparam int LANES = 2;
  localparam int NR    = 2;
  localparam int NP    = 4;
`endif
  localparam int CLK_HZ            = 100_000;
  localparam int TICKS             = CLK_HZ / 1000;
  localparam int M                 = MDB / 8;
  localparam int CAP_BYTES         = 8 * ((M < 6) ? M : 6);
  localparam int STRIDE            = (MDB > 64) ? 4 * MDB : 256;    // rule stride in bytes (MDB power of two here)
  localparam int WIN_B             = ((TE > TU) ? TE : TU) / LANES;
  localparam int JUDGE_GAP_B       = (WIN_B > 4) ? WIN_B : 4;
  localparam int RANDOM_CONFIGS    = 20;
  localparam int FRAMES_PER_CONFIG = 500;

  // Register offsets (from the driver header, written out independently).
  localparam logic [11:0] A_ID      = 12'h000;
  localparam logic [11:0] A_VERSION = 12'h004;
  localparam logic [11:0] A_CAPS    = 12'h008;
  localparam logic [11:0] A_CTRL    = 12'h00C;
  localparam logic [11:0] A_STATUS  = 12'h010;
  localparam logic [11:0] A_LATENCY = 12'h014;
  localparam logic [11:0] A_TMODE   = 12'h020;
  localparam logic [11:0] A_RMODE   = 12'h040;
  localparam logic [11:0] A_CNT     = 12'h080;
  localparam logic [11:0] A_POL     = 12'h100;
  localparam logic [11:0] A_ENTRY   = 12'h400;
  localparam logic [11:0] A_TUPLE   = 12'h900;
  localparam logic [11:0] A_RULE    = 12'hC00;

  localparam int T_MAC = 0;
  localparam int T_ET  = 1;
  localparam int T_VL  = 2;
  localparam int T_IP  = 3;
  localparam int T_PO  = 4;
  localparam int T_TU  = 5;

  localparam int C_FRAMES = 0;
  localparam int C_PASSED = 1;
  localparam int C_DROPPED = 2;
  localparam int C_MODE_DROPPED = 3;
  localparam int C_POL_DROPPED = 4;
  localparam int C_THIT = 5;
  localparam int C_RHIT = 11;
  localparam int C_OVR = 15;

  // ---------------------------------------------------------------------------
  // Clocks, resets, DUT.
  // ---------------------------------------------------------------------------
  logic        axis_clk = 1'b0;
  logic        s_axi_aclk = 1'b0;
  logic        axis_resetn = 1'b0;
  logic        s_axi_aresetn = 1'b0;

  always #5    axis_clk = ~axis_clk;
  always #6.5  s_axi_aclk = ~s_axi_aclk;

  logic [63:0] s_tdata;
  logic [7:0]  s_tkeep;
  logic        s_tvalid;
  logic        s_tlast;
  logic        s_tready;
  logic [63:0] m_tdata;
  logic [7:0]  m_tkeep;
  logic        m_tvalid;
  logic        m_tlast;
  logic        m_tready;
  logic        ev_pass;
  logic        ev_drop;

  logic [11:0] awaddr;
  logic        awvalid;
  logic        awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;
  logic [11:0] araddr;
  logic        arvalid;
  logic        arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;

  rtlnet_classifier #(
    .AXIS_CLK_HZ       (CLK_HZ),
    .TABLE_ENTRIES     (TE),
    .TUPLE_ENTRIES     (TU),
    .TABLE_LANES       (LANES),
    .NUM_RULES         (NR),
    .NUM_POLICERS      (NP),
    .MATCH_DEPTH_BYTES (MDB),
    .RAM_STYLE         ("block")
  ) dut (
    .axis_clk      (axis_clk),
    .axis_resetn   (axis_resetn),
    .s_axi_aclk    (s_axi_aclk),
    .s_axi_aresetn (s_axi_aresetn),
    .s_axis_tdata  (s_tdata),
    .s_axis_tkeep  (s_tkeep),
    .s_axis_tvalid (s_tvalid),
    .s_axis_tlast  (s_tlast),
    .s_axis_tready (s_tready),
    .m_axis_tdata  (m_tdata),
    .m_axis_tkeep  (m_tkeep),
    .m_axis_tvalid (m_tvalid),
    .m_axis_tlast  (m_tlast),
    .m_axis_tready (m_tready),
    .s_axi_awaddr  (awaddr),
    .s_axi_awvalid (awvalid),
    .s_axi_awready (awready),
    .s_axi_wdata   (wdata),
    .s_axi_wstrb   (wstrb),
    .s_axi_wvalid  (wvalid),
    .s_axi_wready  (wready),
    .s_axi_bresp   (bresp),
    .s_axi_bvalid  (bvalid),
    .s_axi_bready  (bready),
    .s_axi_araddr  (araddr),
    .s_axi_arvalid (arvalid),
    .s_axi_arready (arready),
    .s_axi_rdata   (rdata),
    .s_axi_rresp   (rresp),
    .s_axi_rvalid  (rvalid),
    .s_axi_rready  (rready),
    .ev_pass       (ev_pass),
    .ev_drop       (ev_drop)
  );

  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(5)) u_src (
    .clk(axis_clk), .tdata(s_tdata), .tkeep(s_tkeep), .tlast(s_tlast), .tvalid(s_tvalid), .tready(s_tready));

  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(9), .NAME("m_axis")) u_sink (
    .clk(axis_clk), .resetn(axis_resetn), .tdata(m_tdata), .tkeep(m_tkeep), .tlast(m_tlast),
    .tvalid(m_tvalid), .tready(m_tready));

  rtlnet_tb_axil_master #(.ADDR_W(12)) u_axil (
    .aclk(s_axi_aclk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  // ---------------------------------------------------------------------------
  // Bench state.
  // ---------------------------------------------------------------------------
  int unsigned seed = 32'h1234_5678;
  int          perturb = 0;
  int          delay_beats = 0;
  int          verdict_latency = 0;

  // Random numbers (LCG, simulator independent).
  function automatic int unsigned rnd();
    seed = seed * 32'd1664525 + 32'd1013904223;
    return seed ^ (seed >> 15);
  endfunction

  function automatic int unsigned rr(input int unsigned n);
    return (n == 0) ? 0 : (rnd() % n);
  endfunction

  // Model configuration.
  typedef struct {
    bit        valid;
    bit        src_en;
    bit        dst_en;
    bit        both;
    bit        proto_en;
    bit        police_en;
    bit [7:0]  proto;
    bit [1:0]  policer;
    bit [47:0] src;
    bit [47:0] dst;
  } ent_t;

  typedef struct {
    bit        valid;
    bit        proto_en;
    bit        police_en;
    bit [7:0]  proto;
    bit [1:0]  policer;
    bit [31:0] sip;
    bit [31:0] smask;
    bit [31:0] dip;
    bit [31:0] dmask;
    bit [15:0] slo;
    bit [15:0] shi;
    bit [15:0] dlo;
    bit [15:0] dhi;
  } tup_t;

  ent_t        ents   [0:4][0:15];
  tup_t        tups   [0:15];
  bit [7:0]    tmode  [0:5];
  bit [7:0]    rmode  [0:3];
  bit [19:0]   rbytes [0:3][0:255];        // {MASK, OP, COMPARE}
  bit          pol_en [0:3];
  int unsigned pol_limit [0:3];
  int unsigned pol_win   [0:3];
  int unsigned budget    [0:3];
  bit [1:0]    gmode;

  // Model counters.
  int unsigned mc   [0:15];
  int unsigned mps  [0:3];
  int unsigned mpp  [0:3];
  int unsigned mpd  [0:3];

  // Expected output and timing bookkeeping.
  bytes_t      exp_frames [$];
  bit          vq [$];
  longint      pass_beat_cyc [$];
  longint      cyc = 0;
  bit          exact_mode = 1'b0;
  int          lat_min = 1 << 30;
  int          lat_max = 0;
  int          lat_bad = 0;
  int          out_beats = 0;
  int          in_stall_cycles = 0;
  int          ev_pass_cnt = 0;
  int          ev_drop_cnt = 0;
  int          overrun_expected = 0;
  longint      last_judge_cyc = -1000;
  longint      last_acc_judge = -1000;
  bit          track_judge = 1'b0;
  bit          judge_q_exp [$];          // per sent frame: expected accepted (not overrun)

  // ---------------------------------------------------------------------------
  // Monitors.
  // ---------------------------------------------------------------------------
  // Cycle counter and verdict events.
  always @(posedge axis_clk) begin
    cyc <= cyc + 1;
    if (axis_resetn) begin
      if (ev_pass) ev_pass_cnt++;
      if (ev_drop) ev_drop_cnt++;
      if (ev_pass && ev_drop) tb_error("ev_pass and ev_drop together");
    end
  end

  // Input monitor: time stamps of accepted beats. The expected verdict of a
  // frame is taken at its first beat, so the beats of a passing frame are
  // awaited at the output as they enter (a long frame leaves before its last
  // beat arrives).
  bit in_mid = 1'b0;
  bit in_pv  = 1'b0;

  always @(posedge axis_clk) begin
    if (axis_resetn) begin
      if (s_tvalid && !s_tready) in_stall_cycles++;
      if (s_tvalid && s_tready) begin
        if (!in_mid) begin
          if (vq.size() == 0) begin
            tb_error("input frame without an expectation");
            in_pv = 1'b0;
          end else begin
            in_pv = vq.pop_front();
          end
        end
        if (in_pv) pass_beat_cyc.push_back(cyc);
        in_mid = !s_tlast;
      end
    end
  end

  // Trace (+TRACE): per judged frame, the engine results seen by the combiner.
  always @(posedge axis_clk) begin
    if ($test$plusargs("TRACE") && axis_resetn) begin
      if (dut.judge_acc || dut.judge_ovr)
        $display("TRACE %0d judge acc=%0d ovr=%0d et=%04x/%0d ip=%08x>%08x/%0d%0d port=%0d>%0d/%0d%0d", cyc,
                 dut.judge_acc, dut.judge_ovr, dut.f_et, dut.f_et_p, dut.f_ip_src, dut.f_ip_dst, dut.f_ip_sp,
                 dut.f_ip_dp, dut.f_port_src, dut.f_port_dst, dut.f_port_sp, dut.f_port_dp);
      if (dut.rule_done[0])
        $display("TRACE %0d rule0 match=%0d", cyc, dut.rule_match[0]);
      if (dut.tbl_done[0])
        $display("TRACE %0d tables hit=%b", cyc, dut.tbl_hit);
      if (dut.v_push)
        $display("TRACE %0d verdict pass=%0d", cyc, dut.v_pass);
    end
  end

  // Output monitor: latency of every output beat.
  always @(posedge axis_clk) begin
    if (axis_resetn && m_tvalid && m_tready) begin
      longint t_in;
      int     lat;
      out_beats++;
      if (pass_beat_cyc.size() == 0) begin
        tb_error("output beat with no passing input beat");
      end else begin
        t_in = pass_beat_cyc.pop_front();
        lat  = int'(cyc - t_in);
        if (lat < lat_min) lat_min = lat;
        if (lat > lat_max) lat_max = lat;
        if (exact_mode) begin
          if (lat != delay_beats + 2 + ((perturb == 1) ? 1 : 0)) begin
            lat_bad++;
            if (lat_bad <= 5) tb_error($sformatf("beat latency %0d, expected DELAY_BEATS + 2 = %0d", lat,
                                                 delay_beats + 2));
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Register access.
  // ---------------------------------------------------------------------------
  // The model applies a configuration to every frame sent after it, so a
  // register write first waits until every sent frame is judged.
  bit traffic_pending = 1'b0;

  task automatic quiesce();
    int t;
    if (traffic_pending) begin
      t = 0;
      while ((vq.size() != 0 || s_tvalid) && t < 100000) begin
        @(posedge axis_clk);
        t++;
      end
      repeat (verdict_latency + 16) @(posedge axis_clk);
      traffic_pending = 1'b0;
    end
  endtask

  task automatic w(input logic [11:0] a, input logic [31:0] d);
    quiesce();
    u_axil.wr(a, d);
  endtask

  task automatic r(input logic [11:0] a, output logic [31:0] d);
    u_axil.rd(a, d);
  endtask

  task automatic r_expect(input logic [11:0] a, input logic [31:0] exp, input string what);
    logic [31:0] d;
    u_axil.rd(a, d);
    tb_check(d === exp, $sformatf("%s: 0x%03x = 0x%08x, expected 0x%08x", what, a, d, exp));
  endtask

  // Wait for STATUS.CLEARING = 0.
  task automatic wait_not_clearing();
    logic [31:0] st;
    int n;
    n = 0;
    st = 32'h1;
    while (st[0] && n < 200) begin
      r(A_STATUS, st);
      n++;
    end
    tb_check(st[0] == 1'b0, "CLEARING ended");
  endtask

  // Model reset (power-up / CLEAR_TABLES state).
  task automatic model_clear();
    for (int t = 0; t < 5; t++) for (int e = 0; e < 16; e++) ents[t][e] = '{default: 0};
    for (int e = 0; e < 16; e++) tups[e] = '{default: 0};
    for (int t = 0; t < 6; t++) tmode[t] = 8'h00;
    for (int i = 0; i < 4; i++) begin
      rmode[i]     = 8'h00;
      pol_en[i]    = 1'b0;
      pol_limit[i] = 0;
      pol_win[i]   = 0;
      budget[i]    = 0;
      for (int b = 0; b < 256; b++) rbytes[i][b] = 20'h0;
    end
    gmode = 2'b00;
  endtask

  task automatic clear_tables();
    w(A_CTRL, 32'h0000_0100);
    model_clear();
    wait_not_clearing();
  endtask

  task automatic set_mode(input bit [1:0] m);
    w(A_CTRL, {30'd0, m});
    gmode = m;
  endtask

  task automatic set_tmode(input int t, input bit [7:0] v);
    w(A_TMODE + 12'(4 * t), {24'd0, v});
    tmode[t] = v & 8'h9F;
  endtask

  task automatic set_rmode(input int rix, input bit [7:0] v);
    w(A_RMODE + 12'(4 * rix), {24'd0, v});
    rmode[rix] = v & 8'h3F;
  endtask

  function automatic logic [31:0] ent_ctrl(input ent_t x);
    return {x.valid, x.src_en, x.dst_en, x.both, x.proto_en, x.police_en, x.policer, x.proto, x.src[47:32]};
  endfunction

  task automatic set_entry(input int t, input int e, input ent_t x);
    logic [11:0] b;
    b = A_ENTRY + 12'(256 * t) + 12'(16 * e);
    w(b + 12'h0, x.src[31:0]);
    w(b + 12'h8, x.dst[31:0]);
    w(b + 12'hC, {16'd0, x.dst[47:32]});
    w(b + 12'h4, ent_ctrl(x));
    ents[t][e] = x;
  endtask

  function automatic logic [31:0] tup_ctrl(input tup_t x);
    return {x.valid, x.proto_en, x.police_en, 19'd0, x.policer, x.proto};
  endfunction

  task automatic set_tuple(input int e, input tup_t x);
    logic [11:0] b;
    b = A_TUPLE + 12'(32 * e);
    w(b + 12'h04, x.sip);
    w(b + 12'h08, x.smask);
    w(b + 12'h0C, x.dip);
    w(b + 12'h10, x.dmask);
    w(b + 12'h14, {x.shi, x.slo});
    w(b + 12'h18, {x.dhi, x.dlo});
    w(b + 12'h00, tup_ctrl(x));
    tups[e] = x;
  endtask

  task automatic set_rbyte(input int rix, input int b, input bit [7:0] mask, input bit [3:0] op, input bit [7:0] v);
    w(A_RULE + 12'(STRIDE * rix) + 12'(4 * b), {mask, 12'd0, op, v});
    rbytes[rix][b] = {mask, op, v};
  endtask

  task automatic set_pol(input int p, input bit en, input int unsigned limit, input int unsigned win);
    logic [11:0] b;
    b = A_POL + 12'(32 * p);
    w(b + 12'h4, limit);
    w(b + 12'h8, win);
    w(b + 12'h0, {31'd0, en});
    pol_en[p]    = en;
    pol_limit[p] = limit;
    pol_win[p]   = win;
    budget[p]    = limit;
  endtask

  // ---------------------------------------------------------------------------
  // Frame builder.
  // ---------------------------------------------------------------------------
  typedef struct {
    bit [47:0] dst;
    bit [47:0] src;
    bit        tagged;
    bit [15:0] tci;
    bit [15:0] etype;
    bit        ip;
    bit [3:0]  ihl;
    bit [7:0]  proto;
    bit [15:0] frag;
    bit [31:0] sip;
    bit [31:0] dip;
    bit [15:0] sport;
    bit [15:0] dport;
    int        plen;
    bit        pad;
    int        trunc;
  } fdesc_t;

  function automatic fdesc_t fd_default();
    fdesc_t d;
    d.dst = 48'h02_00_00_00_00_01;
    d.src = 48'h02_00_00_00_00_02;
    d.tagged = 1'b0;
    d.tci = 16'h0001;
    d.etype = 16'h0800;
    d.ip = 1'b1;
    d.ihl = 4'd5;
    d.proto = 8'd17;
    d.frag = 16'h4000;
    d.sip = 32'hC0A9_0101;
    d.dip = 32'hC0A9_01DC;
    d.sport = 16'd1000;
    d.dport = 16'd53;
    d.plen = 18;
    d.pad = 1'b1;
    d.trunc = 0;
    return d;
  endfunction

  function automatic bytes_t build(input fdesc_t d);
    bytes_t q;
    push48(q, d.dst);
    push48(q, d.src);
    if (d.tagged) begin
      push16(q, 16'h8100);
      push16(q, d.tci);
    end
    push16(q, d.etype);
    if (d.ip) begin
      q.push_back({4'h4, d.ihl});
      q.push_back(8'h00);
      push16(q, 16'(20 + 4 * (d.ihl - 5) + 8 + d.plen));
      push16(q, 16'h1234);
      push16(q, d.frag);
      q.push_back(8'd64);
      q.push_back(d.proto);
      push16(q, 16'h0000);
      push32(q, d.sip);
      push32(q, d.dip);
      for (int i = 5; i < d.ihl; i++) push32(q, 32'h0101_0101);
      push16(q, d.sport);
      push16(q, d.dport);
      push16(q, 16'(8 + d.plen));
      push16(q, 16'h0000);
    end
    for (int i = 0; i < d.plen; i++) q.push_back(8'(rr(256)));
    if (d.pad) q = pad60(q);
    if (d.trunc > 0 && d.trunc < q.size()) begin
      bytes_t t;
      for (int i = 0; i < d.trunc; i++) t.push_back(q[i]);
      q = t;
    end
    return q;
  endfunction

  // ---------------------------------------------------------------------------
  // Reference model.
  // ---------------------------------------------------------------------------
  // Table field widths and destination sides (specification section 4.1).
  function automatic int fw(input int t);
    case (t)
      T_MAC:   return 48;
      T_ET:    return 16;
      T_VL:    return 15;
      T_IP:    return 32;
      default: return 16;
    endcase
  endfunction

  function automatic bit has_dst(input int t);
    return (t == T_MAC) || (t == T_IP) || (t == T_PO);
  endfunction

  // Header bytes seen by the tables: within the frame and the capture.
  function automatic bit pr_(input bytes_t f, input int b);
    return (b < $size(f)) && (b < CAP_BYTES);
  endfunction

  function automatic bit [7:0] by_(input bytes_t f, input int b);
    return pr_(f, b) ? f[b] : 8'h00;
  endfunction

  function automatic bit is_tagged(input bytes_t f);
    return pr_(f, 13) && (f[12] == 8'h81) && (f[13] == 8'h00);
  endfunction

  // IPv4 / L4 classification at the offsets selected by VLAN awareness.
  function automatic void l3(input bytes_t f, input bit aware, output int base, output bit ipv4, output bit l4);
    bit sel;
    bit frag_ok;
    bit pl4;
    sel  = aware && is_tagged(f) && (perturb != 5);
    base = sel ? 18 : 14;
    ipv4 = pr_(f, base) && ({by_(f, base - 2), by_(f, base - 1)} == 16'h0800) && (by_(f, base) == 8'h45);
    frag_ok = pr_(f, base + 7) && (({by_(f, base + 6), by_(f, base + 7)} & 16'h3FFF) == 16'h0000);
    pl4 = pr_(f, base + 9) && ((by_(f, base + 9) == 8'd6) || (by_(f, base + 9) == 8'd17));
    l4  = ipv4 && frag_ok && pl4;
  endfunction

  // Field of table t for frame f.
  function automatic void tfield(input bytes_t f, input int t, output bit [47:0] fs, output bit [47:0] fd,
                                 output bit sp, output bit dp, output bit [7:0] proto);
    int       base;
    bit       ipv4;
    bit       l4;
    bit       aware;
    bit [7:0] b14;
    aware = tmode[t][7];
    l3(f, aware, base, ipv4, l4);
    fs = '0; fd = '0; sp = 0; dp = 0; proto = by_(f, base + 9);
    case (t)
      T_MAC: begin
        fd = {by_(f, 0), by_(f, 1), by_(f, 2), by_(f, 3), by_(f, 4), by_(f, 5)};
        fs = {by_(f, 6), by_(f, 7), by_(f, 8), by_(f, 9), by_(f, 10), by_(f, 11)};
        dp = pr_(f, 5);
        sp = pr_(f, 11);
      end
      T_ET: begin
        if (aware && is_tagged(f) && perturb != 5) begin
          fs = {by_(f, 16), by_(f, 17)};
          sp = pr_(f, 17);
        end else begin
          fs = {by_(f, 12), by_(f, 13)};
          sp = pr_(f, 13);
        end
      end
      T_VL: begin
        b14 = by_(f, 14);
        if (tmode[T_VL][3:2] == 2'b10) fs = {b14[7:5], b14[3:0], by_(f, 15)};
        else                           fs = {b14[3:0], by_(f, 15)};
        sp = is_tagged(f) && pr_(f, 15);
      end
      T_IP: begin
        fs = {by_(f, base + 12), by_(f, base + 13), by_(f, base + 14), by_(f, base + 15)};
        fd = {by_(f, base + 16), by_(f, base + 17), by_(f, base + 18), by_(f, base + 19)};
        sp = ipv4 && pr_(f, base + 15);
        dp = ipv4 && pr_(f, base + 19);
      end
      default: begin
        fs = {by_(f, base + 20), by_(f, base + 21)};
        fd = {by_(f, base + 22), by_(f, base + 23)};
        sp = l4 && pr_(f, base + 21);
        dp = l4 && pr_(f, base + 23);
      end
    endcase
  endfunction

  function automatic bit sides(input ent_t x, input bit s, input bit d);
    if (x.src_en && x.dst_en) return x.both ? (s && d) : (s || d);
    if (x.src_en)             return s;
    if (x.dst_en)             return d;
    return 1'b0;
  endfunction

  // Field table t: hit, and the first policing hit's policer.
  function automatic void m_table(input bytes_t f, input int t, output bit hit, output bit pf, output bit [1:0] pol);
    bit [47:0] fs;
    bit [47:0] fd;
    bit [47:0] wm;
    bit        sp;
    bit        dp;
    bit [7:0]  proto;
    bit [1:0]  cmp;
    ent_t      lo;
    ent_t      hi;
    bit        s;
    bit        d;
    bit        ok;
    tfield(f, t, fs, fd, sp, dp, proto);
    wm  = (48'h1 << fw(t)) - 48'h1;
    cmp = tmode[t][3:2];
    hit = 0; pf = 0; pol = 0;
    if (cmp == 2'b00) begin
      for (int e = 0; e < TE; e++) begin
        lo = ents[t][e];
        s  = sp && (fs == (lo.src & wm));
        d  = has_dst(t) && dp && (fd == (lo.dst & wm));
        ok = lo.valid && sides(lo, s, d) && ((t != T_PO) || !lo.proto_en || (proto == lo.proto));
        if (ok) begin
          hit = 1;
          if (lo.police_en && !pf) begin pf = 1; pol = lo.policer; end
        end
      end
    end else if (cmp == 2'b01 || cmp == 2'b10) begin
      for (int k = 0; k < TE / 2; k++) begin
        lo = ents[t][2 * k];
        hi = ents[t][2 * k + 1];
        if (cmp == 2'b01) begin
          if (perturb == 2) begin
            s = sp && (fs >= (lo.src & wm)) && (fs < (hi.src & wm));
            d = has_dst(t) && dp && (fd >= (lo.dst & wm)) && (fd < (hi.dst & wm));
          end else begin
            s = sp && (fs >= (lo.src & wm)) && (fs <= (hi.src & wm));
            d = has_dst(t) && dp && (fd >= (lo.dst & wm)) && (fd <= (hi.dst & wm));
          end
        end else begin
          s = sp && (((fs ^ lo.src) & hi.src & wm) == 48'h0);
          d = has_dst(t) && dp && (((fd ^ lo.dst) & hi.dst & wm) == 48'h0);
        end
        ok = lo.valid && sides(lo, s, d) && ((t != T_PO) || !lo.proto_en || (proto == lo.proto));
        if (ok) begin
          hit = 1;
          if (lo.police_en && !pf) begin pf = 1; pol = lo.policer; end
        end
      end
    end
  endfunction

  function automatic bit port_ok(input bit [15:0] p, input bit [15:0] lo, input bit [15:0] hi, input bit l4ok);
    return ((lo == 16'h0000) && (hi == 16'hFFFF)) || (l4ok && (p >= lo) && (p <= hi));
  endfunction

  // Tuple table.
  function automatic void m_tuple(input bytes_t f, output bit hit, output bit pf, output bit [1:0] pol);
    int        base;
    bit        ipv4;
    bit        l4;
    bit        ipok;
    bit        l4ok;
    bit [7:0]  proto;
    bit [31:0] sip;
    bit [31:0] dip;
    bit [15:0] sport;
    bit [15:0] dport;
    tup_t      x;
    bit        ok;
    l3(f, tmode[T_TU][7], base, ipv4, l4);
    ipok  = ipv4 && pr_(f, base + 19);
    l4ok  = l4 && pr_(f, base + 23);
    proto = by_(f, base + 9);
    sip   = {by_(f, base + 12), by_(f, base + 13), by_(f, base + 14), by_(f, base + 15)};
    dip   = {by_(f, base + 16), by_(f, base + 17), by_(f, base + 18), by_(f, base + 19)};
    sport = {by_(f, base + 20), by_(f, base + 21)};
    dport = {by_(f, base + 22), by_(f, base + 23)};
    hit = 0; pf = 0; pol = 0;
    for (int e = 0; e < TU; e++) begin
      x  = tups[e];
      ok = x.valid && ipok && (!x.proto_en || (proto == x.proto)) &&
           (((sip ^ x.sip) & x.smask) == 32'h0) && (((dip ^ x.dip) & x.dmask) == 32'h0) &&
           port_ok(sport, x.slo, x.shi, l4ok) && port_ok(dport, x.dlo, x.dhi, l4ok);
      if (ok) begin
        hit = 1;
        if (x.police_en && !pf) begin pf = 1; pol = x.policer; end
      end
    end
  endfunction

  // Rule operator on masked operands.
  function automatic bit op_pass(input bit [3:0] op, input bit [7:0] a, input bit [7:0] b);
    case (op)
      4'b1000: return a == b;
      4'b1001: return a != b;
      4'b1010: return (perturb == 4) ? (a <= b) : (a < b);
      4'b1011: return a > b;
      4'b1100: return a <= b;
      4'b1101: return a >= b;
      default: return 1'b1;
    endcase
  endfunction

  function automatic bit op_dc(input bit [3:0] op);
    return !(op[3] && (op[2:0] <= 3'd5));
  endfunction

  function automatic bit m_rule(input bytes_t f, input int rix);
    bit [7:0] mask;
    bit [3:0] op;
    bit [7:0] v;
    for (int b = 0; b < MDB; b++) begin
      {mask, op, v} = rbytes[rix][b];
      if (b < $size(f)) begin
        if (!op_pass(op, f[b] & mask, v & mask)) return 1'b0;
      end else begin
        if (!op_dc(op)) return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  // Full decision for one judged frame; updates model counters and budgets.
  function automatic bit m_verdict(input bytes_t f, input bit overrun);
    bit       thit [0:5];
    bit       tpf  [0:5];
    bit [1:0] tpol [0:5];
    bit       rm   [0:3];
    bit       tand;
    bit       anyg;
    bit       allex;
    bit       orv;
    bit       andv;
    bit       rc;
    bit       match;
    bit       pass_pre;
    bit       found;
    bit [1:0] pol;
    bit       pass;
    mc[C_FRAMES] += (perturb == 6) ? 2 : 1;
    if (overrun) begin
      mc[C_DROPPED]++;
      mc[C_OVR]++;
      return 1'b0;
    end
    for (int t = 0; t < 5; t++) m_table(f, t, thit[t], tpf[t], tpol[t]);
    m_tuple(f, thit[5], tpf[5], tpol[5]);
    for (int i = 0; i < 4; i++) rm[i] = (i < NR) ? m_rule(f, i) : 1'b0;
    // Hit counters: enabled engines only.
    for (int t = 0; t < 6; t++) if (tmode[t][0] && thit[t]) mc[C_THIT + t]++;
    for (int i = 0; i < NR; i++) if (rmode[i][0] && rm[i]) mc[C_RHIT + i]++;
    // match.
    tand = 1;
    for (int t = 0; t < 6; t++) begin
      if (tmode[t][0] && !tmode[t][4]) tand = tand && (tmode[t][1] ? !thit[t] : thit[t]);
    end
    anyg = 0; allex = 1; orv = 0; andv = 1;
    for (int i = 0; i < NR; i++) begin
      if (rmode[i][0] && !rmode[i][2]) begin
        anyg  = 1;
        allex = allex && rmode[i][1];
        orv   = orv || (rmode[i][1] ? !rm[i] : rm[i]);
        andv  = andv && !rm[i];
      end
    end
    rc    = !anyg ? 1'b1 : (allex ? andv : orv);
    match = tand && rc;
    case (gmode)
      2'b01:   pass_pre = 1'b1;
      2'b10:   pass_pre = match;
      2'b11:   pass_pre = !match;
      default: pass_pre = 1'b0;
    endcase
    if (!pass_pre) begin
      mc[C_DROPPED]++;
      mc[C_MODE_DROPPED]++;
      return 1'b0;
    end
    // Policer: rules, tuple, MAC .. PORT.
    found = 0; pol = 0;
    for (int i = 0; i < NR; i++) begin
      if (!found && rmode[i][0] && rmode[i][3] && rm[i]) begin found = 1; pol = rmode[i][5:4]; end
    end
    if (!found && tmode[T_TU][0] && tpf[5]) begin found = 1; pol = tpol[5]; end
    for (int t = 0; t < 5; t++) begin
      if (!found && tmode[t][0] && tpf[t]) begin found = 1; pol = tpol[t]; end
    end
    pass = 1'b1;
    if (found && (pol < NP) && pol_en[pol]) begin
      mps[pol]++;
      if (budget[pol] > 0) begin
        budget[pol]--;
        mpp[pol]++;
      end else begin
        mpd[pol]++;
        pass = 1'b0;
      end
    end
    if (pass) mc[C_PASSED]++;
    else begin
      mc[C_DROPPED]++;
      mc[C_POL_DROPPED]++;
    end
    return pass;
  endfunction

  // ---------------------------------------------------------------------------
  // Sending and checking.
  // ---------------------------------------------------------------------------
  // Send one frame with its model verdict; short frames get idle clocks
  // around them so no judge comes too soon after another (no overrun).
  task automatic send(input bytes_t f, output bit pv);
    bit runt;
    runt = ($size(f) < 57);
    if (runt) u_src.idle(JUDGE_GAP_B + 2);
    pv = m_verdict(f, 1'b0);
    if ($test$plusargs("TRACE")) $display("TRACE %0d send len=%0d model pass=%0d %s", cyc, $size(f), pv, hexdump(f, 48));
    vq.push_back(pv);
    if (pv) exp_frames.push_back(f);
    traffic_pending = 1'b1;
    u_src.send(f);
    if (runt) u_src.idle(JUDGE_GAP_B + 2);
  endtask

  task automatic send_expect(input bytes_t f, input bit exp, input string what);
    bit pv;
    send(f, pv);
    tb_check(pv == exp, $sformatf("model verdict for %s: %0d, hand expectation %0d", what, pv, exp));
  endtask

  // Wait for the line to empty, then compare every output frame.
  task automatic drain_and_check(input string what);
    bytes_t got;
    bytes_t ex;
    string  why;
    int     t;
    t = 0;
    while ((u_sink.frames.size() < exp_frames.size() || pass_beat_cyc.size() != 0 || vq.size() != 0) &&
           t < 30000) begin
      @(posedge axis_clk);
      t++;
    end
    repeat (delay_beats + 64) @(posedge axis_clk);
    tb_check(u_sink.frames.size() == exp_frames.size(),
             $sformatf("%s: %0d frames out, model passes %0d", what, u_sink.frames.size(), exp_frames.size()));
    while (u_sink.frames.size() > 0 && exp_frames.size() > 0) begin
      got = u_sink.frames.pop_front();
      ex  = exp_frames.pop_front();
      tb_check(bytes_equal(got, ex, why), $sformatf("%s: frame content: %s", what, why));
    end
    u_sink.frames = {};
    exp_frames = {};
  endtask

  // Compare every counter with the model and check the identities.
  task automatic check_counters(input string what);
    logic [31:0] v [0:15];
    logic [31:0] pv;
    for (int i = 0; i < 16; i++) r(A_CNT + 12'(4 * i), v[i]);
    for (int i = 0; i < 16; i++) begin
      if (i >= C_RHIT && i < C_RHIT + 4 && (i - C_RHIT) >= NR) continue;
      tb_check(v[i] == mc[i], $sformatf("%s: counter %0d = %0d, model %0d", what, i, v[i], mc[i]));
    end
    tb_check(v[C_FRAMES] == v[C_PASSED] + v[C_DROPPED], $sformatf("%s: FRAMES = PASSED + DROPPED", what));
    tb_check(v[C_DROPPED] == v[C_MODE_DROPPED] + v[C_POL_DROPPED] + v[C_OVR],
             $sformatf("%s: DROPPED = MODE + POLICE + OVERRUN", what));
    tb_check(ev_pass_cnt == int'(v[C_PASSED]) && ev_drop_cnt == int'(v[C_DROPPED]),
             $sformatf("%s: ev_pass %0d / ev_drop %0d vs counters", what, ev_pass_cnt, ev_drop_cnt));
    for (int p = 0; p < NP; p++) begin
      logic [31:0] s;
      logic [31:0] pp;
      logic [31:0] pd;
      r(A_POL + 12'(32 * p) + 12'h0C, s);
      r(A_POL + 12'(32 * p) + 12'h10, pp);
      r(A_POL + 12'(32 * p) + 12'h14, pd);
      tb_check(s == mps[p] && pp == mpp[p] && pd == mpd[p],
               $sformatf("%s: policer %0d seen/passed/dropped %0d/%0d/%0d, model %0d/%0d/%0d", what, p, s, pp, pd,
                         mps[p], mpp[p], mpd[p]));
      tb_check(s == pp + pd, $sformatf("%s: policer %0d SEEN = PASSED + DROPPED", what, p));
    end
    pv = 0;
  endtask

  // Clear the hardware and model counters.
  task automatic clear_counters();
    logic [31:0] c;
    r(A_CTRL, c);
    w(A_CTRL, (c & 32'h3) | 32'h0001_0000);
    for (int i = 0; i < 16; i++) mc[i] = 0;
    for (int p = 0; p < 4; p++) begin mps[p] = 0; mpp[p] = 0; mpd[p] = 0; end
    ev_pass_cnt = 0;
    ev_drop_cnt = 0;
  endtask

  // ---------------------------------------------------------------------------
  // Pools for random and directed frames.
  // ---------------------------------------------------------------------------
  bit [47:0] mac_pool  [0:5] = '{48'h02_00_00_00_00_01, 48'h02_00_00_00_00_02, 48'h0A_1B_2C_3D_4E_5F,
                                 48'hFF_FF_FF_FF_FF_FF, 48'h01_00_5E_00_00_01, 48'h02_49_4B_52_4E_01};
  bit [15:0] et_pool   [0:5] = '{16'h0800, 16'h0806, 16'h86DD, 16'h88CC, 16'h0842, 16'h0801};
  bit [11:0] vid_pool  [0:4] = '{12'd1, 12'd2, 12'd3, 12'd100, 12'd4095};
  bit [31:0] ip_pool   [0:5] = '{32'hC0A9_0101, 32'hC0A9_01DC, 32'hC0A9_0203, 32'h0A00_0001, 32'h0A00_0002,
                                 32'h0808_0808};
  bit [15:0] port_pool [0:7] = '{16'd22, 16'd53, 16'd80, 16'd443, 16'd1000, 16'd1005, 16'd65535, 16'd0};

  function automatic fdesc_t rand_desc();
    fdesc_t d;
    int     k;
    d = fd_default();
    d.dst    = (rr(8) == 0) ? {rnd(), 16'(rnd())} : mac_pool[rr(6)];
    d.src    = mac_pool[rr(6)];
    d.tagged = (rr(10) < 3);
    d.tci    = {3'(rr(8)), 1'b0, vid_pool[rr(5)]};
    k = rr(20);
    if (k < 13) begin
      d.etype = 16'h0800;
      d.ip = 1'b1;
    end else begin
      d.etype = (k < 15) ? 16'h0806 : et_pool[rr(6)];
      d.ip = (d.etype == 16'h0800);
    end
    d.ihl   = (rr(10) == 0) ? 4'd6 : 4'd5;
    k = rr(20);
    d.proto = (k < 8) ? 8'd6 : (k < 16) ? 8'd17 : (k < 19) ? 8'd1 : 8'(rr(256));
    d.frag  = (rr(10) == 0) ? ((rr(2) == 0) ? 16'h2000 : 16'h00B9) : 16'h4000;
    d.sip   = (rr(6) == 0) ? rnd() : ip_pool[rr(6)];
    d.dip   = (rr(6) == 0) ? rnd() : ip_pool[rr(6)];
    d.sport = (rr(6) == 0) ? 16'(rnd()) : port_pool[rr(8)];
    d.dport = (rr(6) == 0) ? 16'(rnd()) : port_pool[rr(8)];
    d.plen  = (rr(10) == 0) ? int'(rr(1400)) : int'(rr(120));
    d.pad   = (rr(10) != 0);
    d.trunc = (rr(12) == 0) ? int'(1 + rr(70)) : 0;
    return d;
  endfunction

  // Random field-table entry with values near the pools.
  function automatic ent_t rand_entry(input int t, input bit is_hi);
    ent_t      x;
    bit [47:0] v;
    bit [47:0] dv;
    x = '{default: 0};
    case (t)
      T_MAC: begin v = mac_pool[rr(6)]; dv = mac_pool[rr(6)]; end
      T_ET:  begin v = et_pool[rr(6)]; dv = 0; end
      T_VL:  begin v = {3'(rr(8)), vid_pool[rr(5)]}; dv = 0; end
      T_IP:  begin v = ip_pool[rr(6)]; dv = ip_pool[rr(6)]; end
      default: begin v = port_pool[rr(8)]; dv = port_pool[rr(8)]; end
    endcase
    if (is_hi) begin
      // Upper bound or mask partner.
      if (tmode[t][3:2] == 2'b10) begin
        bit [47:0] masks [0:3];
        masks = '{48'hFFFF_FFFF_FFFF, 48'hFFFF_FFFF_FF00, 48'hFFFF_FFFF_0000, 48'(rnd())};
        v  = masks[rr(4)];
        dv = masks[rr(4)];
      end else begin
        v  = v + 48'(rr(12));
        dv = dv + 48'(rr(12));
      end
    end else if (tmode[t][3:2] == 2'b01) begin
      v  = v - 48'(rr(4));
      dv = dv - 48'(rr(4));
    end
    x.valid     = (rr(10) < 8);
    x.src_en    = rr(2);
    x.dst_en    = has_dst(t) ? rr(2) : 1'b0;
    x.both      = rr(2);
    if (!x.src_en && !x.dst_en) x.src_en = 1'b1;
    x.proto_en  = (t == T_PO) && (rr(3) == 0);
    x.proto     = (rr(2) == 0) ? 8'd6 : 8'd17;
    x.police_en = (rr(3) == 0);
    x.policer   = 2'(rr(4));
    x.src       = v;
    x.dst       = dv;
    return x;
  endfunction

  function automatic tup_t rand_tuple();
    tup_t x;
    bit [31:0] masks [0:3];
    masks = '{32'hFFFF_FFFF, 32'hFFFF_FF00, 32'h0000_0000, 32'hFF00_0000};
    x = '{default: 0};
    x.valid     = (rr(10) < 8);
    x.proto_en  = rr(2);
    x.proto     = (rr(3) == 0) ? 8'd1 : (rr(2) == 0) ? 8'd6 : 8'd17;
    x.police_en = (rr(3) == 0);
    x.policer   = 2'(rr(4));
    x.sip       = ip_pool[rr(6)];
    x.smask     = masks[rr(4)];
    x.dip       = ip_pool[rr(6)];
    x.dmask     = masks[rr(4)];
    if (rr(3) == 0) begin x.slo = 16'h0000; x.shi = 16'hFFFF; end
    else begin x.slo = port_pool[rr(8)]; x.shi = x.slo + 16'(rr(30)); if (x.shi < x.slo) x.shi = 16'hFFFF; end
    if (rr(3) == 0) begin x.dlo = 16'h0000; x.dhi = 16'hFFFF; end
    else begin x.dlo = port_pool[rr(8)]; x.dhi = x.dlo + 16'(rr(30)); if (x.dhi < x.dlo) x.dhi = 16'hFFFF; end
    return x;
  endfunction

  // ---------------------------------------------------------------------------
  // Phases.
  // ---------------------------------------------------------------------------
  task automatic phase_ident();
    logic [31:0] v;
    r_expect(A_ID, 32'h434C_5346, "ID");
    r_expect(A_VERSION, 32'h1022_2026, "VERSION");
    r_expect(A_CAPS, (32'(TE) << 0) | (32'(TU) << 5) | (32'(NR) << 10) | (32'(NP) << 13) | (32'(LANES) << 16) |
                     (32'(M) << 21), "CAPS");
    r(A_LATENCY, v);
    delay_beats     = int'(v[7:0]);
    verdict_latency = int'(v[15:8]);
    tb_check(delay_beats == M + verdict_latency,
             $sformatf("DELAY_BEATS %0d = MATCH_DEPTH_BYTES/8 %0d + VERDICT_LATENCY %0d", delay_beats, M,
                       verdict_latency));
    tb_check(delay_beats == dut.DELAY_BEATS && verdict_latency == dut.VERDICT_LATENCY,
             "LATENCY register equals the DUT localparams");
    tb_check(verdict_latency == WIN_B + 14, $sformatf("VERDICT_LATENCY %0d = table words %0d + 14", verdict_latency,
                                                      WIN_B));
    r_expect(A_CTRL, 32'h0, "CTRL power-up");
    r_expect(A_STATUS, 32'h0, "STATUS after the power-up clear");
    for (int t = 0; t < 6; t++) r_expect(A_TMODE + 12'(4 * t), 32'h0, "TABLE_MODE power-up");
    for (int i = 0; i < NR; i++) r_expect(A_RMODE + 12'(4 * i), 32'h0, "RULE_MODE power-up");
    r_expect(12'h200, 32'h0, "undefined offset reads 0");
    w(12'h200, 32'hDEAD_BEEF);
    r_expect(12'h200, 32'h0, "undefined offset ignores writes");
    r_expect(A_ENTRY + 12'h4, 32'h0, "entry cleared at power-up");
    $display("tb: DELAY_BEATS=%0d VERDICT_LATENCY=%0d (MATCH_DEPTH_BYTES=%0d)", delay_beats, verdict_latency, MDB);
  endtask

  // Power-up: nothing passes.
  task automatic phase_powerup();
    fdesc_t d;
    bit     pv;
    exact_mode = 1'b1;
    for (int i = 0; i < 30; i++) begin
      d = rand_desc();
      if (i % 3 == 0) d.dst = 48'hFFFF_FFFF_FFFF;
      send(build(d), pv);
      tb_check(pv == 1'b0, "model: power-up drops");
    end
    drain_and_check("power-up drop-all");
    tb_check(u_sink.frame_count == 0, "no frame left the classifier before configuration");
    check_counters("power-up");
  endtask

  // Each MODE with no engine enabled (match = 1).
  task automatic phase_modes();
    fdesc_t d;
    bit     pv;
    for (int m = 0; m < 4; m++) begin
      set_mode(2'(m));
      for (int i = 0; i < 20; i++) begin
        d = rand_desc();
        send_expect(build(d), (m == 1) || (m == 2), $sformatf("mode %0d", m));
      end
      drain_and_check($sformatf("mode %0d", m));
    end
    check_counters("modes");
  endtask

  // Broadcast storm configuration: MAC table classify-only, entry 0 dst
  // broadcast policed by policer 0, MODE PASS_ALL.
  task automatic phase_storm();
    ent_t   x;
    fdesc_t d;
    bit     pv;
    longint t0;
    int     limits [0:2];
    int     wins   [0:2];
    int     bc_out;
    limits = '{10, 3, 0};
    wins   = '{100, 20, 10};
    clear_tables();
    x = '{default: 0};
    x.valid = 1; x.dst_en = 1; x.police_en = 1; x.policer = 0; x.dst = 48'hFFFF_FFFF_FFFF; x.src = 48'hFFFF_FFFF_FFFF;
    set_entry(T_MAC, 0, x);
    set_tmode(T_MAC, 8'h11);                    // enable, classify, single
    for (int c = 0; c < 3; c++) begin
      set_pol(0, 1'b1, limits[c], wins[c]);
      t0 = cyc;                                  // window restart (within the register crossing)
      if (c == 0) set_mode(2'b01);
      for (int win = 0; win < 3; win++) begin
        int lim_m;
        // Start of window win (+ margin), budget reloads in the model.
        while (cyc < t0 + longint'(win) * wins[c] * TICKS + 300) @(posedge axis_clk);
        lim_m = limits[c] + ((perturb == 3) ? 1 : 0);
        budget[0] = lim_m;
        bc_out = 0;
        for (int i = 0; i < 3 * limits[c] + 6; i++) begin
          d = fd_default();
          d.dst = (i % 2 == 0) ? 48'hFFFF_FFFF_FFFF : 48'h02_00_00_00_00_01;
          send(build(d), pv);
          if (i % 2 == 0 && pv) bc_out++;
          if (i % 2 == 1) tb_check(pv, "model: unicast passes the storm limiter");
        end
        tb_check(bc_out == limits[c], $sformatf("storm: %0d broadcasts pass in window %0d, limit %0d", bc_out, win,
                                                limits[c]));
        tb_check(cyc < t0 + longint'(win + 1) * wins[c] * TICKS, "storm burst inside its window");
        drain_and_check($sformatf("storm limit %0d window %0d", limits[c], win));
      end
    end
    // Disabled policer: every broadcast passes.
    set_pol(0, 1'b0, 0, 10);
    for (int i = 0; i < 20; i++) begin
      d = fd_default();
      d.dst = 48'hFFFF_FFFF_FFFF;
      send_expect(build(d), 1'b1, "storm limiter disabled");
    end
    drain_and_check("storm disabled");
    check_counters("storm");
  endtask

  // Directed field-table checks.
  task automatic phase_tables();
    ent_t   x;
    ent_t   y;
    tup_t   tu;
    fdesc_t d;
    clear_tables();
    set_mode(2'b10);                            // pass on match
    // MAC single, destination only.
    x = '{default: 0};
    x.valid = 1; x.dst_en = 1; x.dst = 48'h02_00_00_00_00_01; x.src = 48'h0A_1B_2C_3D_4E_5F;
    set_entry(T_MAC, 3, x);
    set_tmode(T_MAC, 8'h01);
    d = fd_default(); d.dst = 48'h02_00_00_00_00_01; send_expect(build(d), 1, "MAC dst hit");
    d = fd_default(); d.dst = 48'h02_00_00_00_00_09; send_expect(build(d), 0, "MAC dst miss");
    // Source only, either, both.
    x.dst_en = 0; x.src_en = 1; set_entry(T_MAC, 3, x);
    d = fd_default(); d.src = 48'h0A_1B_2C_3D_4E_5F; send_expect(build(d), 1, "MAC src hit");
    d = fd_default(); send_expect(build(d), 0, "MAC src miss");
    x.dst_en = 1; x.both = 0; set_entry(T_MAC, 3, x);
    d = fd_default(); d.dst = 48'h02_00_00_00_00_01; d.src = 48'h02_00_00_00_00_07; send_expect(build(d), 1, "MAC either dst");
    d = fd_default(); d.dst = 48'h02_00_00_00_00_05; d.src = 48'h0A_1B_2C_3D_4E_5F; send_expect(build(d), 1, "MAC either src");
    x.both = 1; set_entry(T_MAC, 3, x);
    d = fd_default(); d.dst = 48'h02_00_00_00_00_01; d.src = 48'h02_00_00_00_00_07; send_expect(build(d), 0, "MAC both one side");
    d = fd_default(); d.dst = 48'h02_00_00_00_00_01; d.src = 48'h0A_1B_2C_3D_4E_5F; send_expect(build(d), 1, "MAC both sides");
    // Exclude.
    set_tmode(T_MAC, 8'h03);
    d = fd_default(); d.dst = 48'h02_00_00_00_00_01; d.src = 48'h0A_1B_2C_3D_4E_5F; send_expect(build(d), 0, "MAC exclude hit");
    d = fd_default(); send_expect(build(d), 1, "MAC exclude miss");
    // Classify-only: no part in match.
    set_tmode(T_MAC, 8'h11);
    d = fd_default(); send_expect(build(d), 1, "MAC classify-only");
    set_tmode(T_MAC, 8'h00);
    // ETHERTYPE range pair 0/1 = 0x0800..0x0806.
    x = '{default: 0}; y = '{default: 0};
    x.valid = 1; x.src_en = 1; x.src = 48'h0800; y.src = 48'h0806;
    set_entry(T_ET, 1, y); set_entry(T_ET, 0, x);
    set_tmode(T_ET, 8'h05);
    d = fd_default(); d.etype = 16'h0806; d.ip = 0; send_expect(build(d), 1, "ETHERTYPE range high bound");
    d = fd_default(); d.etype = 16'h0807; d.ip = 0; send_expect(build(d), 0, "ETHERTYPE range above");
    d = fd_default(); d.etype = 16'h07FF; d.ip = 0; send_expect(build(d), 0, "ETHERTYPE range below");
    d = fd_default(); send_expect(build(d), 1, "ETHERTYPE range low bound");
    // Tagged frame: EtherType 0x8100 without VLAN awareness, inner with it.
    d = fd_default(); d.tagged = 1; send_expect(build(d), 0, "ETHERTYPE tagged, not aware");
    set_tmode(T_ET, 8'h85);
    d = fd_default(); d.tagged = 1; send_expect(build(d), 1, "ETHERTYPE tagged, VLAN-aware");
    set_tmode(T_ET, 8'h00);
    // VLAN table data/mask on PCP only: value PCP 5, mask 0x7000.
    x = '{default: 0}; y = '{default: 0};
    x.valid = 1; x.src_en = 1; x.src = 48'h5000; y.src = 48'h7000;
    set_entry(T_VL, 1, y); set_entry(T_VL, 0, x);
    set_tmode(T_VL, 8'h09);
    d = fd_default(); d.tagged = 1; d.tci = 16'hA064; send_expect(build(d), 1, "VLAN PCP 5 mask");
    d = fd_default(); d.tagged = 1; d.tci = 16'h6064; send_expect(build(d), 0, "VLAN PCP 3 mask");
    d = fd_default(); send_expect(build(d), 0, "VLAN untagged never hits");
    // VLAN single VID 100.
    x.src = 48'd100; set_entry(T_VL, 0, x);
    set_tmode(T_VL, 8'h01);
    d = fd_default(); d.tagged = 1; d.tci = 16'hE064; send_expect(build(d), 1, "VLAN VID 100 any PCP");
    d = fd_default(); d.tagged = 1; d.tci = 16'hE065; send_expect(build(d), 0, "VLAN VID 101");
    set_tmode(T_VL, 8'h00);
    // IP data/mask destination 192.169.1.0/24, VLAN awareness.
    x = '{default: 0}; y = '{default: 0};
    x.valid = 1; x.dst_en = 1; x.dst = 48'hC0A9_0100; y.dst = 48'hFFFF_FF00;
    set_entry(T_IP, 5, y); set_entry(T_IP, 4, x);
    set_tmode(T_IP, 8'h09);
    d = fd_default(); d.dip = 32'hC0A9_01FE; send_expect(build(d), 1, "IP /24 hit");
    d = fd_default(); d.dip = 32'hC0A9_02FE; send_expect(build(d), 0, "IP /24 miss");
    d = fd_default(); d.tagged = 1; send_expect(build(d), 0, "IP tagged, not aware");
    set_tmode(T_IP, 8'h89);
    d = fd_default(); d.tagged = 1; send_expect(build(d), 1, "IP tagged, VLAN-aware");
    d = fd_default(); d.ihl = 6; send_expect(build(d), 0, "IP with options is not IHL 5");
    d = fd_default(); d.etype = 16'h0806; d.ip = 1; send_expect(build(d), 0, "IP field of a non-IPv4 frame");
    set_tmode(T_IP, 8'h00);
    // PORT range 50..60 destination, UDP only.
    x = '{default: 0}; y = '{default: 0};
    x.valid = 1; x.dst_en = 1; x.dst = 48'd50; y.dst = 48'd60; x.proto_en = 1; x.proto = 8'd17;
    set_entry(T_PO, 1, y); set_entry(T_PO, 0, x);
    set_tmode(T_PO, 8'h05);
    d = fd_default(); d.dport = 16'd53; send_expect(build(d), 1, "PORT UDP 53");
    d = fd_default(); d.dport = 16'd53; d.proto = 8'd6; send_expect(build(d), 0, "PORT TCP 53, UDP qualifier");
    d = fd_default(); d.dport = 16'd60; send_expect(build(d), 1, "PORT upper bound");
    d = fd_default(); d.dport = 16'd61; send_expect(build(d), 0, "PORT above");
    d = fd_default(); d.dport = 16'd53; d.frag = 16'h2000; send_expect(build(d), 0, "PORT of a fragment");
    d = fd_default(); d.dport = 16'd53; d.trunc = 37; d.pad = 0; send_expect(build(d), 0, "PORT field cut short");
    set_tmode(T_PO, 8'h00);
    // Tuple: TCP from 192.169.1.0/24 to 192.169.1.220 port 22.
    tu = '{default: 0};
    tu.valid = 1; tu.proto_en = 1; tu.proto = 8'd6; tu.sip = 32'hC0A9_0100; tu.smask = 32'hFFFF_FF00;
    tu.dip = 32'hC0A9_01DC; tu.dmask = 32'hFFFF_FFFF; tu.slo = 16'h0000; tu.shi = 16'hFFFF; tu.dlo = 16'd22;
    tu.dhi = 16'd22;
    set_tuple(2, tu);
    set_tmode(T_TU, 8'h01);
    d = fd_default(); d.proto = 8'd6; d.sip = 32'hC0A9_0177; d.dport = 16'd22; send_expect(build(d), 1, "ACL TCP /24 port 22");
    d = fd_default(); d.proto = 8'd17; d.sip = 32'hC0A9_0177; d.dport = 16'd22; send_expect(build(d), 0, "ACL UDP");
    d = fd_default(); d.proto = 8'd6; d.sip = 32'hC0A9_0277; d.dport = 16'd22; send_expect(build(d), 0, "ACL source outside /24");
    d = fd_default(); d.proto = 8'd6; d.sip = 32'hC0A9_0177; d.dport = 16'd23; send_expect(build(d), 0, "ACL port 23");
    // ICMP entry with any ports matches a frame without L4 ports.
    tu = '{default: 0};
    tu.valid = 1; tu.proto_en = 1; tu.proto = 8'd1; tu.sip = 0; tu.smask = 0; tu.dip = 0; tu.dmask = 0;
    tu.slo = 0; tu.shi = 16'hFFFF; tu.dlo = 0; tu.dhi = 16'hFFFF;
    set_tuple(3, tu);
    d = fd_default(); d.proto = 8'd1; send_expect(build(d), 1, "ACL ICMP any ports");
    d = fd_default(); d.ip = 0; d.etype = 16'h0806; send_expect(build(d), 0, "ACL non-IPv4 frame");
    set_tmode(T_TU, 8'h00);
    drain_and_check("tables");
    check_counters("tables");
  endtask

  // Every rule operator at its boundary with a mask.
  task automatic phase_rules();
    fdesc_t d;
    bytes_t f;
    bit [3:0] ops [0:6];
    int       b;
    ops = '{4'b1000, 4'b1001, 4'b1010, 4'b1011, 4'b1100, 4'b1101, 4'b0000};
    clear_tables();
    set_mode(2'b10);
    b = 37;                                      // UDP destination port low byte (53 = 0x35)
    for (int k = 0; k < 7; k++) begin
      for (int dv = -1; dv <= 1; dv++) begin
        bit       exp;
        bit [7:0] cmpv;
        bit [7:0] mv;
        cmpv = 8'h35 + 8'(dv);
        set_rmode(0, 8'h00);
        set_rbyte(0, b, 8'hFF, ops[k], cmpv);
        set_rbyte(0, 36, 8'h0F, 4'b1000, 8'hF0);     // port high byte 0x00 & 0x0F == 0xF0 & 0x0F
        set_rmode(0, 8'h01);
        repeat (40) @(posedge axis_clk);
        mv = 8'h35;
        case (ops[k])
          4'b1000: exp = (mv == cmpv);
          4'b1001: exp = (mv != cmpv);
          4'b1010: exp = (mv <  cmpv);
          4'b1011: exp = (mv >  cmpv);
          4'b1100: exp = (mv <= cmpv);
          4'b1101: exp = (mv >= cmpv);
          default: exp = 1'b1;
        endcase
        d = fd_default();
        send_expect(build(d), exp, $sformatf("rule op %b compare 0x%02x vs byte 0x35", ops[k], cmpv));
      end
    end
    // Absent bytes: rule on byte MDB-1; a 60-byte frame lacks it when MDB > 60.
    set_rmode(0, 8'h00);
    set_rbyte(0, 36, 8'h00, 4'b0000, 8'h00);
    set_rbyte(0, b, 8'h00, 4'b0000, 8'h00);
    set_rbyte(0, MDB - 1, 8'h00, 4'b1101, 8'h00);   // >= 0 under mask 0: passes only when present
    set_rmode(0, 8'h01);
    repeat (40) @(posedge axis_clk);
    d = fd_default(); d.plen = 18;
    f = build(d);
    send_expect(f, ($size(f) >= MDB), "absent byte fails >= 0");
    d = fd_default(); d.plen = 200;
    send_expect(build(d), 1, "present byte passes >= 0");
    set_rmode(0, 8'h00);
    set_rbyte(0, MDB - 1, 8'h00, 4'b0111, 8'h00);    // reserved operator code: don't-care
    set_rmode(0, 8'h01);
    repeat (40) @(posedge axis_clk);
    d = fd_default(); d.trunc = 20; d.pad = 0;
    send_expect(build(d), 1, "absent byte passes don't-care");
    // A short frame: every byte beyond it absent; byte 0 compared.
    set_rmode(0, 8'h00);
    set_rbyte(0, 0, 8'hFF, 4'b1000, 8'h02);
    set_rbyte(0, 13, 8'hFF, 4'b1000, 8'h00);         // EtherType low byte 0x00
    set_rmode(0, 8'h01);
    repeat (40) @(posedge axis_clk);
    d = fd_default(); d.trunc = 14; d.pad = 0; send_expect(build(d), 1, "14-byte frame, bytes 0 and 13 equal");
    d = fd_default(); d.trunc = 13; d.pad = 0; send_expect(build(d), 0, "13-byte frame lacks byte 13");
    d = fd_default(); d.trunc = 1;  d.pad = 0; send_expect(build(d), 0, "1-byte frame");
    drain_and_check("rules");
    check_counters("rules");
  endtask

  // The rule-combination rule.
  task automatic phase_combination();
    fdesc_t d;
    bit [7:0] modes [0:3];
    clear_tables();
    if (NR < 2) return;
    set_mode(2'b10);
    // Rule 0: dst MAC byte 5 == 0x01; rule 1: dst MAC byte 5 == 0x02.
    set_rbyte(0, 5, 8'hFF, 4'b1000, 8'h01);
    set_rbyte(1, 5, 8'hFF, 4'b1000, 8'h02);
    modes = '{8'h01, 8'h03, 8'h05, 8'h00};          // include, exclude, classify, disabled
    for (int a = 0; a < 4; a++) begin
      for (int c = 0; c < 4; c++) begin
        set_rmode(0, modes[a]);
        set_rmode(1, modes[c]);
        repeat (40) @(posedge axis_clk);
        for (int v = 1; v <= 3; v++) begin
          bit m0;
          bit m1;
          bit g0;
          bit g1;
          bit exp;
          m0 = (v == 1);
          m1 = (v == 2);
          g0 = (a < 2);
          g1 = (c < 2);
          if (!g0 && !g1)                               exp = 1;
          else if ((!g0 || a == 1) && (!g1 || c == 1))  exp = (!g0 || !m0) && (!g1 || !m1);
          else                                          exp = (g0 && ((a == 1) ? !m0 : m0)) ||
                                                              (g1 && ((c == 1) ? !m1 : m1));
          d = fd_default();
          d.dst = {40'h02_00_00_00_00, 8'(v)};
          send_expect(build(d), exp, $sformatf("rules %0d/%0d frame %0d", a, c, v));
        end
      end
    end
    drain_and_check("rule combination");
    check_counters("rule combination");
  endtask

  // Policer priority: rules, tuple, MAC .. PORT; policer 0 drops (limit 0),
  // the others pass.
  task automatic phase_priority();
    ent_t   x;
    tup_t   tu;
    fdesc_t d;
    clear_tables();
    set_mode(2'b01);
    for (int p = 0; p < NP; p++) set_pol(p, 1'b1, (p == 0) ? 0 : 1000000, 1000);
    // MAC entry 1 polices with policer 1, entry 0 with policer NP-1 (lower index wins).
    x = '{default: 0};
    x.valid = 1; x.dst_en = 1; x.dst = 48'h02_00_00_00_00_01; x.police_en = 1; x.policer = 1;
    set_entry(T_MAC, 0, x);
    x.policer = 0;
    set_entry(T_MAC, 1, x);
    set_tmode(T_MAC, 8'h11);
    d = fd_default(); send_expect(build(d), 1, "MAC lowest entry picks policer");
    // IP table polices with policer 0 (drop), but MAC comes first.
    x = '{default: 0};
    x.valid = 1; x.src_en = 1; x.src = 48'hC0A9_0101; x.police_en = 1; x.policer = 0;
    set_entry(T_IP, 0, x);
    set_tmode(T_IP, 8'h11);
    d = fd_default(); send_expect(build(d), 1, "MAC before IP");
    d = fd_default(); d.dst = 48'h02_00_00_00_00_33; send_expect(build(d), 0, "IP policer 0 drops");
    // Tuple before MAC: tuple entry polices with policer 0.
    tu = '{default: 0};
    tu.valid = 1; tu.police_en = 1; tu.policer = 0; tu.slo = 0; tu.shi = 16'hFFFF; tu.dlo = 0; tu.dhi = 16'hFFFF;
    set_tuple(0, tu);
    set_tmode(T_TU, 8'h11);
    d = fd_default(); send_expect(build(d), 0, "tuple before MAC");
    // Rule before tuple: rule 0 matches everything, polices with policer 1.
    set_rmode(0, 8'h00 | 8'h04 | 8'h08 | 8'h10 | 8'h01);  // enable, classify, police, policer 1
    repeat (40) @(posedge axis_clk);
    d = fd_default(); send_expect(build(d), 1, "rule before tuple");
    // Disabled policer passes.
    set_rmode(0, 8'h00);
    set_pol(0, 1'b0, 0, 1000);
    d = fd_default(); send_expect(build(d), 1, "disabled policer passes");
    drain_and_check("priority");
    check_counters("priority");
  endtask

  // Delay-line exactness over frame lengths, and back-to-back minimum
  // frames at full rate.
  task automatic phase_delay();
    fdesc_t d;
    bit     pv;
    longint t_first;
    longint t_last;
    int     lens [0:9];
    int     ob0;
    int     st0;
    lens = '{60, 61, 64, 65, MDB - 8, MDB, MDB + 1, MDB + 8, 300, 1518};
    clear_tables();
    set_mode(2'b01);
    exact_mode = 1'b1;
    lat_bad = 0;
    for (int i = 0; i < 10; i++) begin
      for (int k = 0; k < 3; k++) begin
        d = fd_default();
        d.plen = 0; d.pad = 0; d.ip = 0; d.etype = 16'h88B5;
        d.plen = lens[i] - 14;
        send(build(d), pv);
      end
    end
    drain_and_check("delay lengths");
    tb_check(lat_bad == 0, "every beat left exactly DELAY_BEATS + 2 clocks after entry");
    // Back-to-back 60-byte frames: no input stall, no output gap.
    st0 = in_stall_cycles;
    ob0 = out_beats;
    t_first = -1;
    for (int i = 0; i < 200; i++) begin
      d = fd_default();
      d.plen = 18;
      send(build(d), pv);
    end
    drain_and_check("back-to-back 60-byte frames");
    tb_check(in_stall_cycles == st0, $sformatf("back-to-back: s_axis_tready low for %0d clocks", in_stall_cycles - st0));
    tb_check(out_beats - ob0 == 200 * 8, "back-to-back: 1600 output beats");
    tb_check(lat_bad == 0, "back-to-back: every beat exactly DELAY_BEATS + 2 clocks");
    // Every other frame dropped (MAC table gating), still full rate in.
    begin
      ent_t x;
      x = '{default: 0};
      x.valid = 1; x.dst_en = 1; x.dst = 48'h02_00_00_00_00_01;
      set_entry(T_MAC, 0, x);
      set_tmode(T_MAC, 8'h01);
      set_mode(2'b10);
    end
    st0 = in_stall_cycles;
    for (int i = 0; i < 100; i++) begin
      d = fd_default();
      d.dst = (i % 2 == 0) ? 48'h02_00_00_00_00_01 : 48'h02_00_00_00_00_02;
      send(build(d), pv);
    end
    drain_and_check("back-to-back alternating verdicts");
    tb_check(in_stall_cycles == st0, "alternating verdicts: no input stall");
    tb_check(lat_bad == 0, "alternating verdicts: every passed beat exactly DELAY_BEATS + 2 clocks");
    check_counters("delay");
    exact_mode = 1'b0;
  endtask

  // Back-to-back runts: frames judged sooner than JUDGE_GAP clocks after
  // the previous accepted one are overrun and dropped.
  task automatic phase_overrun();
    fdesc_t d;
    bytes_t f;
    longint judge_t;
    longint last_acc;
    int     n_ovr;
    clear_tables();
    set_mode(2'b01);
    clear_counters();
    last_acc = -1000;
    n_ovr = 0;
    // 3-beat frames (20 bytes), gap-free: judge every 3 clocks.
    for (int i = 0; i < 30; i++) begin
      bit acc;
      bit pv;
      d = fd_default(); d.trunc = 20; d.pad = 0;
      f = build(d);
      judge_t = 3 * i + 2;
      acc = (judge_t - last_acc >= JUDGE_GAP_B);
      if (acc) last_acc = judge_t;
      else n_ovr++;
      pv = m_verdict(f, !acc);
      traffic_pending = 1'b1;
      vq.push_back(pv);
      if (pv) exp_frames.push_back(f);
      u_src.send(f);
    end
    u_src.idle(20);
    drain_and_check("overrun runts");
    check_counters("overrun");
    tb_check(n_ovr > 0, "overrun case exercised");
  endtask

  // CLEAR_TABLES, readback and the update protocol.
  task automatic phase_clear();
    ent_t   x;
    tup_t   tu;
    fdesc_t d;
    logic [31:0] v;
    clear_tables();
    x = '{default: 0};
    x.valid = 1; x.src_en = 1; x.dst_en = 1; x.both = 1; x.proto_en = 1; x.proto = 8'h11; x.police_en = 1;
    x.policer = 2; x.src = 48'h1122_3344_5566; x.dst = 48'h7788_99AA_BBCC;
    for (int t = 0; t < 5; t++) set_entry(t, TE - 1, x);
    tu = '{default: 0};
    tu.valid = 1; tu.sip = 32'h0102_0304; tu.smask = 32'hFFFF_0000; tu.dip = 32'h0506_0708; tu.dmask = 32'hFF00_FF00;
    tu.slo = 16'd10; tu.shi = 16'd20; tu.dlo = 16'd30; tu.dhi = 16'd40; tu.proto = 8'd6; tu.proto_en = 1;
    set_tuple(TU - 1, tu);
    set_rbyte(NR - 1, MDB - 1, 8'hA5, 4'b1011, 8'h5A);
    set_tmode(T_IP, 8'h9F);
    set_rmode(NR - 1, 8'h3F);
    set_pol(NP - 1, 1'b1, 77, 33);
    set_mode(2'b11);
    // Readback of every written word.
    for (int t = 0; t < 5; t++) begin
      logic [11:0] b;
      b = A_ENTRY + 12'(256 * t) + 12'(16 * (TE - 1));
      r_expect(b + 12'h0, 32'h3344_5566, "entry SRC_LO readback");
      r_expect(b + 12'h4, ent_ctrl(x), "entry CTRL readback");
      r_expect(b + 12'h8, 32'h99AA_BBCC, "entry DST_LO readback");
      r_expect(b + 12'hC, 32'h0000_7788, "entry DST_HI readback");
    end
    r_expect(A_TUPLE + 12'(32 * (TU - 1)) + 12'h00, tup_ctrl(tu), "tuple CTRL readback");
    r_expect(A_TUPLE + 12'(32 * (TU - 1)) + 12'h10, 32'hFF00_FF00, "tuple DST_MASK readback");
    r_expect(A_TUPLE + 12'(32 * (TU - 1)) + 12'h18, {16'd40, 16'd30}, "tuple DPORT readback");
    r_expect(A_RULE + 12'(STRIDE * (NR - 1)) + 12'(4 * (MDB - 1)), 32'hA500_0B5A, "rule byte readback");
    r_expect(A_TMODE + 12'(4 * T_IP), 32'h9F, "TABLE_MODE readback");
    r_expect(A_RMODE + 12'(4 * (NR - 1)), 32'h3F, "RULE_MODE readback");
    r_expect(A_POL + 12'(32 * (NP - 1)) + 12'h4, 32'd77, "LIMIT readback");
    r_expect(A_POL + 12'(32 * (NP - 1)) + 12'h8, 32'd33, "WINDOW readback");
    r_expect(A_POL + 12'(32 * (NP - 1)) + 12'h18, 32'd77, "BUDGET after restart");
    r_expect(A_CTRL, 32'h3, "CTRL MODE readback");
    if (TE < 16) r_expect(A_ENTRY + 12'(16 * TE) + 12'h4, 32'h0, "entry beyond TABLE_ENTRIES reads 0");
    // CLEAR_TABLES returns to the power-up state.
    w(A_CTRL, 32'h0000_0100);
    r(A_STATUS, v);
    tb_check(v[0] == 1'b1, "STATUS.CLEARING during the clear sequence");
    model_clear();
    wait_not_clearing();
    r_expect(A_CTRL, 32'h0, "CTRL after CLEAR_TABLES");
    r_expect(A_TMODE + 12'(4 * T_IP), 32'h0, "TABLE_MODE after CLEAR_TABLES");
    r_expect(A_RMODE + 12'(4 * (NR - 1)), 32'h0, "RULE_MODE after CLEAR_TABLES");
    r_expect(A_POL + 12'(32 * (NP - 1)), 32'h0, "policer disabled after CLEAR_TABLES");
    r_expect(A_ENTRY + 12'(256 * T_PO) + 12'(16 * (TE - 1)) + 12'h4, 32'h0, "entry invalid after CLEAR_TABLES");
    r_expect(A_RULE + 12'(STRIDE * (NR - 1)) + 12'(4 * (MDB - 1)), 32'h0, "rule byte zero after CLEAR_TABLES");
    for (int i = 0; i < 10; i++) begin
      d = rand_desc();
      send_expect(build(d), 0, "drop-all after CLEAR_TABLES");
    end
    drain_and_check("clear");
    // Update protocol: entry replaced with the table disabled, then enabled.
    set_mode(2'b10);
    x = '{default: 0};
    x.valid = 1; x.dst_en = 1; x.dst = 48'h02_00_00_00_00_01;
    set_entry(T_MAC, 2, x);
    set_tmode(T_MAC, 8'h01);
    d = fd_default(); send_expect(build(d), 1, "before update");
    drain_and_check("before update");
    set_tmode(T_MAC, 8'h00);
    x.dst = 48'h02_00_00_00_00_02;
    set_entry(T_MAC, 2, x);
    set_tmode(T_MAC, 8'h01);
    d = fd_default(); send_expect(build(d), 0, "after update, old value");
    d = fd_default(); d.dst = 48'h02_00_00_00_00_02; send_expect(build(d), 1, "after update, new value");
    drain_and_check("update protocol");
    check_counters("clear");
  endtask

  // Random configurations and frames with source gaps and sink stalls.
  task automatic phase_random();
    fdesc_t d;
    bit     pv;
    int     npass;
    int     nframes;
    logic [31:0] st;
    npass = 0;
    nframes = 0;
    for (int c = 0; c < RANDOM_CONFIGS; c++) begin
      clear_tables();
      clear_counters();
      for (int t = 0; t < 6; t++) begin
        bit [7:0] m;
        m = 8'h00;
        m[0] = (rr(10) < 6);
        m[1] = (rr(4) == 0);
        m[3:2] = (t == T_TU) ? 2'b00 : ((rr(20) == 0) ? 2'b11 : 2'(rr(3)));
        m[4] = (rr(5) == 0);
        m[7] = rr(2);
        tmode[t] = m;                    // compare mode known to the entry generator
        if (t < 5) begin
          for (int e = 0; e < TE; e++) begin
            ent_t x;
            x = rand_entry(t, (m[3:2] != 2'b00) && (e % 2 == 1));
            if (x.valid || (m[3:2] != 2'b00)) set_entry(t, e, x);
          end
        end else begin
          for (int e = 0; e < TU; e++) begin
            tup_t x;
            x = rand_tuple();
            if (x.valid) set_tuple(e, x);
          end
        end
        set_tmode(t, m);
      end
      for (int i = 0; i < NR; i++) begin
        bit [7:0] m;
        int       nb;
        nb = 1 + rr(3);
        for (int k = 0; k < nb; k++) begin
          int       b;
          bytes_t   s;
          bit [3:0] ops [0:6];
          ops = '{4'b1000, 4'b1001, 4'b1010, 4'b1011, 4'b1100, 4'b1101, 4'b0101};
          s = build(rand_desc());
          b = (rr(4) == 0) ? int'(rr(MDB)) : int'(rr(42));
          set_rbyte(i, b, (rr(3) == 0) ? 8'(rnd()) : 8'hFF, ops[rr(7)], (b < $size(s)) ? s[b] : 8'(rnd()));
        end
        m = 8'h00;
        m[0] = (rr(2) == 0);
        m[1] = (rr(3) == 0);
        m[2] = (rr(6) == 0);
        m[3] = (rr(3) == 0);
        m[5:4] = 2'(rr(4));
        set_rmode(i, m);
      end
      for (int p = 0; p < NP; p++) set_pol(p, rr(2), (rr(2) == 0) ? 0 : 1000000, 1000);
      set_mode((rr(10) == 0) ? 2'b00 : (rr(10) < 2) ? 2'b01 : (rr(2) == 0) ? 2'b10 : 2'b11);
      repeat (60) @(posedge axis_clk);
      u_src.gap_pct    = (c % 3 == 0) ? 0 : int'(rr(30));
      u_sink.ready_pct = (c % 3 == 0) ? 100 : 40 + int'(rr(60));
      for (int i = 0; i < FRAMES_PER_CONFIG; i++) begin
        d = rand_desc();
        send(build(d), pv);
        nframes++;
        if (pv) npass++;
      end
      u_src.gap_pct = 0;
      drain_and_check($sformatf("random config %0d", c));
      check_counters($sformatf("random config %0d", c));
      u_sink.ready_pct = 100;
    end
    $display("tb: random phase %0d frames, %0d passed", nframes, npass);
    tb_check(nframes == RANDOM_CONFIGS * FRAMES_PER_CONFIG, "random frame count");
    tb_check(npass > nframes / 10 && npass < nframes - nframes / 10, "random verdict mix");
    r(A_STATUS, st);
    tb_check(st[16] == 1'b1, "STATUS.STALL_SEEN after sink stalls");
  endtask

  // ---------------------------------------------------------------------------
  // Main.
  // ---------------------------------------------------------------------------
  initial begin : main
    if ($value$plusargs("SEED=%d", seed)) $display("tb: seed %0d", seed);
    if ($value$plusargs("PERTURB=%d", perturb)) $display("tb: PERTURB %0d", perturb);
    for (int i = 0; i < 16; i++) mc[i] = 0;
    for (int p = 0; p < 4; p++) begin mps[p] = 0; mpp[p] = 0; mpd[p] = 0; end
    model_clear();
    repeat (20) @(posedge axis_clk);
    axis_resetn   = 1'b1;
    s_axi_aresetn = 1'b1;
    repeat (10) @(posedge axis_clk);
    wait_not_clearing();
    phase_ident();
    phase_powerup();
    phase_modes();
    phase_storm();
    phase_tables();
    phase_rules();
    if ($test$plusargs("STOP_RULES")) tb_verdict("tb_rtlnet_classifier");
    phase_combination();
    phase_priority();
    phase_delay();
    phase_overrun();
    phase_clear();
    phase_random();
    $display("tb: latency min %0d max %0d (DELAY_BEATS + 2 = %0d), %0d output beats", lat_min, lat_max,
             delay_beats + 2, out_beats);
    tb_verdict("tb_rtlnet_classifier");
  end

  // Watchdog.
  initial begin : watchdog
    #(400ms);
    tb_error("watchdog: bench did not finish");
    tb_verdict("tb_rtlnet_classifier");
  end

endmodule
