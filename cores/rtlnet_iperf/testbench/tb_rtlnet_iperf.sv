// -----------------------------------------------------------------------------
// File: tb_rtlnet_iperf.sv
// Purpose: self-checking bench for rtlnet_iperf. The bench is the iperf 2
//   client and the network: it drives the leaf's frame input the way the
//   protocol wrapper does (one frame at a time, >= 16 idle clocks, never while
//   busy), collects every frame the leaf sends, and drives the register port.
// Reference models (written from the iperf 2 server algorithm, not from the
//   RTL): per datagram with sequence magnitude p > 0, a datagram with
//   p != PacketID + 1 is out of order when p < PacketID + 1, else a gap of
//   p - PacketID - 1 adds to Lost; PacketID = max(PacketID, p); in-order
//   datagrams (FIN included) update the RFC 3550 estimator from the second
//   one on and add it to a sum; the report carries datagrams = PacketID,
//   error_cnt = max(Lost - OutofOrder, 0), outorder_cnt, bytes, the mean
//   estimator as jitter1/jitter2 and the first-to-FIN duration. Two estimator
//   forms run side by side: the specified fixed-point form (8 fraction bits,
//   floor), compared exactly, and a real-valued form, which the fixed-point
//   mean must stay within 1 us of. Arrival times are known exactly because
//   every datagram's last beat is placed on a whole-microsecond clock.
// Cases:
//   1  register map: ID, VERSION, CAPS, CTRL reset (REVERSE_ALLOWED 1),
//      UDP_PORT reset 5001 and write, undefined offsets 0, read-only writes,
//      read latency 1, RX_BYTES_HI latched by the RX_BYTES_LO read.
//   2  plain flow and FIN: report byte-exact (all fields), counters, duration.
//   3  loss and reordering: a literal 50 % loss (50 lost of 101), reorder,
//      duplicates (subtracted from lost, clamped at 0), a lost last datagram,
//      300 random drops/swaps/duplicates; report and registers vs. the model.
//   4  jitter: controlled arrival and send times, report jitter vs. both models,
//      JITTER_US16 vs. the fixed model, a seconds rollover in the sender time.
//   5  FIN rules: repeated FIN resends the same report, an unknown FIN is
//      ignored, a late datagram behind the FIN opens no flow, sequence 1 opens a
//      new one; 32-bit sequence (no client header) and its FIN; another source
//      ignored while a flow is open.
//   6  ignored traffic: other MAC, other IP, other port, broadcast MAC, IHL 6,
//      MF, fragment offset, TCP, UDP length < 24, UDP length past the frame, ARP;
//      leaf disabled.
//   7  idle timeout: a silent flow closes without a report; its late FIN is
//      ignored; a new flow starts from zero.
//   8  reverse (-R): paced stream (rate honoured to the datagram), byte mode,
//      length clamps (0 -> 1470, over the maximum, under 16), header repeats
//      ignored, a request from another client restarts the stream, the final
//      datagram -(n + 1) exactly once and last, a receive flow and its report
//      while streaming, random and long output stalls, REVERSE_ALLOWED off.
//   9  UDP_PORT register change; CNT_CLEAR; a frame overlapping the FIN
//      accounting is skipped whole.
//   10 DUT B at 33.333333 MHz (fractional microsecond time base): flow duration
//      exact to the microsecond; MAX_DGRAM_BYTES 100 clamps the stream.
//   Claim (leaf contract 7.5): rtlnet_tb_leaf_claim_monitor on DUT A and B
//   (timing, one per frame, never while disabled); every flow claims each of
//   its datagrams and its FIN; FIN retries and the open flow's datagrams claim
//   one each; the late datagram, the unknown FIN, another source while a flow
//   is open, every ignored-traffic frame and a -R request with REVERSE_ALLOWED
//   off claim nothing; an accepted -R request claims one.
//   Run-wide: rtlnet_tb_leaf_busy_monitor, the sink's stream-rule checks, busy
//   low 16 clocks after the last beat of every data datagram.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: claim checks.
// Clocks: clk 50 MHz (DUT A, CLK_HZ 50 000 000: 50 clocks per microsecond);
//   clk_b 33.333 MHz (DUT B).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_iperf;

  import rtlnet_tb_pkg::*;

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------
  localparam int US          = 50;                 // DUT A clocks per microsecond
  localparam int IDLE_MS     = 3;
  localparam int BYTE_MS     = 20;
  localparam int MAX_DGRAM   = 1472;
  localparam int JF          = 16;                 // fraction bits of the fixed-point estimator

  localparam bit [47:0] DUT_MAC  = 48'h02_49_50_52_46_01;
  localparam bit [31:0] DUT_IP   = {8'd172, 8'd16, 8'd5, 8'd20};
  localparam bit [47:0] MAC_A    = 48'h02_AA_00_00_00_0A;
  localparam bit [31:0] IP_A     = {8'd172, 8'd16, 8'd5, 8'd100};
  localparam bit [15:0] PORT_A   = 16'd51234;
  localparam bit [47:0] MAC_B    = 48'h02_BB_00_00_00_0B;
  localparam bit [31:0] IP_B     = {8'd172, 8'd16, 8'd5, 8'd101};
  localparam bit [15:0] PORT_B   = 16'd40001;
  localparam bit [15:0] SRV_PORT = 16'd5001;

  // Client test header values of iperf 2.2.x (payloads.h): flags, rate.
  localparam bit [31:0] FLAGS_U  = 32'h4801_00A0;  // EXTEND | SEQNO64B | header length bits
  localparam bit [31:0] FLAGS_R  = 32'hEC01_00A0;  // + VERSION1 | UDPTESTS | VERSION2
  localparam bit [15:0] UPPER_R  = 16'h0400;       // REVERSE
  localparam bit [31:0] RATE_10M = 32'h00A0_0000;

  // Register offsets (driver header contract, written here again).
  localparam bit [11:0] R_ID = 12'h000, R_VERSION = 12'h004, R_CAPS = 12'h008, R_CTRL = 12'h00C;
  localparam bit [11:0] R_STATUS = 12'h010, R_PORT = 12'h014, R_RXD = 12'h018, R_RXB_LO = 12'h01C;
  localparam bit [11:0] R_RXB_HI = 12'h020, R_LOST = 12'h024, R_OOO = 12'h028, R_TXD = 12'h02C;
  localparam bit [11:0] R_JIT = 12'h030, R_RATE = 12'h034, R_DUR = 12'h038, R_REPS = 12'h03C;
  localparam bit [31:0] C_REV = 32'h1, C_CLEAR = 32'h1_0000;

  // ---------------------------------------------------------------------------
  // Clocks, reset, DUT A, stream models, monitors
  // ---------------------------------------------------------------------------
  logic clk = 1'b0;
  logic clk_b = 1'b0;
  logic resetn = 1'b0;
  always #10 clk = ~clk;
  always #15 clk_b = ~clk_b;
  longint cyc = 0;
  longint cyc_b = 0;
  always @(posedge clk) cyc <= cyc + 1;
  always @(posedge clk_b) cyc_b <= cyc_b + 1;

  logic [63:0] s_tdata, m_tdata;
  logic [7:0]  s_tkeep, m_tkeep;
  logic        s_tlast, s_tvalid, s_tready, m_tlast, m_tvalid, m_tready, busy;
  logic        claim;
  logic        claim_b;
  logic        enable = 1'b1;
  logic        reg_wr_en = 1'b0;
  logic [11:0] reg_wr_addr = '0;
  logic [31:0] reg_wr_data = '0;
  logic        reg_rd_en = 1'b0;
  logic [11:0] reg_rd_addr = '0;
  logic [31:0] reg_rd_data;

  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(3)) u_src (
    .clk(clk), .tdata(s_tdata), .tkeep(s_tkeep), .tlast(s_tlast), .tvalid(s_tvalid), .tready(s_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(17), .NAME("iperf_tx")) u_sink (
    .clk(clk), .resetn(resetn), .tdata(m_tdata), .tkeep(m_tkeep), .tlast(m_tlast), .tvalid(m_tvalid), .tready(m_tready));

  rtlnet_iperf #(
    .CLK_HZ(50_000_000), .UDP_PORT(5001), .MAX_DGRAM_BYTES(MAX_DGRAM), .IDLE_TIMEOUT_MS(IDLE_MS), .BYTE_MODE_MS(BYTE_MS)
  ) dut_a (
    .clk(clk), .resetn(resetn), .enable(enable),
    .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid), .s_axis_tlast(s_tlast),
    .s_axis_tready(s_tready),
    .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid), .m_axis_tlast(m_tlast),
    .m_axis_tready(m_tready),
    .local_mac(DUT_MAC), .local_ip(DUT_IP), .busy(busy), .claim(claim),
    .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data));

  rtlnet_tb_leaf_busy_monitor #(.NAME("iperf_a")) u_busy_mon (
    .clk(clk), .resetn(resetn), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
    .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast), .busy(busy));
  rtlnet_tb_leaf_claim_monitor #(.NAME("iperf_a")) u_claim_mon (
    .clk(clk), .resetn(resetn), .enable(enable), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
    .busy(busy), .claim(claim));

  // DUT B: 33.333333 MHz, MAX_DGRAM_BYTES 100.
  logic [63:0] sb_tdata, mb_tdata;
  logic [7:0]  sb_tkeep, mb_tkeep;
  logic        sb_tlast, sb_tvalid, sb_tready, mb_tlast, mb_tvalid, mb_tready, busy_b;
  logic        rb_rd_en = 1'b0;
  logic [11:0] rb_rd_addr = '0;
  logic [31:0] rb_rd_data;
  logic        resetn_b = 1'b0;

  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(8)) u_src_b (
    .clk(clk_b), .tdata(sb_tdata), .tkeep(sb_tkeep), .tlast(sb_tlast), .tvalid(sb_tvalid), .tready(sb_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(4), .NAME("iperf_b_tx")) u_sink_b (
    .clk(clk_b), .resetn(resetn_b), .tdata(mb_tdata), .tkeep(mb_tkeep), .tlast(mb_tlast), .tvalid(mb_tvalid),
    .tready(mb_tready));

  rtlnet_iperf #(
    .CLK_HZ(33_333_333), .UDP_PORT(5001), .MAX_DGRAM_BYTES(100), .IDLE_TIMEOUT_MS(IDLE_MS), .BYTE_MODE_MS(BYTE_MS)
  ) dut_b (
    .clk(clk_b), .resetn(resetn_b), .enable(1'b1),
    .s_axis_tdata(sb_tdata), .s_axis_tkeep(sb_tkeep), .s_axis_tvalid(sb_tvalid), .s_axis_tlast(sb_tlast),
    .s_axis_tready(sb_tready),
    .m_axis_tdata(mb_tdata), .m_axis_tkeep(mb_tkeep), .m_axis_tvalid(mb_tvalid), .m_axis_tlast(mb_tlast),
    .m_axis_tready(mb_tready),
    .local_mac(DUT_MAC), .local_ip(DUT_IP), .busy(busy_b), .claim(claim_b),
    .reg_wr_en(1'b0), .reg_wr_addr(12'd0), .reg_wr_data(32'd0),
    .reg_rd_en(rb_rd_en), .reg_rd_addr(rb_rd_addr), .reg_rd_data(rb_rd_data));

  rtlnet_tb_leaf_busy_monitor #(.NAME("iperf_b")) u_busy_mon_b (
    .clk(clk_b), .resetn(resetn_b), .s_tvalid(sb_tvalid), .s_tready(sb_tready), .s_tlast(sb_tlast),
    .m_tvalid(mb_tvalid), .m_tready(mb_tready), .m_tlast(mb_tlast), .busy(busy_b));
  rtlnet_tb_leaf_claim_monitor #(.NAME("iperf_b")) u_claim_mon_b (
    .clk(clk_b), .resetn(resetn_b), .enable(1'b1), .s_tvalid(sb_tvalid), .s_tready(sb_tready), .s_tlast(sb_tlast),
    .busy(busy_b), .claim(claim_b));

  // Claims of DUT A since claim_mark (the bench's per-case expectations).
  int claim_mark = 0;
  task automatic claims_expect(input int n, input string what);
    repeat (20) @(posedge clk);
    tb_check(u_claim_mon.claims - claim_mark == n, $sformatf("%s: %0d claims, expected %0d", what,
             u_claim_mon.claims - claim_mark, n));
    claim_mark = u_claim_mon.claims;
  endtask

  // Cycle of every input last beat (DUT A and B).
  longint in_tlast_cyc = 0;
  longint in_tlast_cyc_b = 0;
  always @(posedge clk)   if (resetn && s_tvalid && s_tready && s_tlast) in_tlast_cyc = cyc;
  always @(posedge clk_b) if (resetn_b && sb_tvalid && sb_tready && sb_tlast) in_tlast_cyc_b = cyc_b;

  // Start cycle of every frame DUT A sends.
  longint tx_start_q[$];
  bit     tx_in_frame = 0;
  always @(posedge clk) begin
    if (resetn && m_tvalid && m_tready) begin
      if (!tx_in_frame) tx_start_q.push_back(cyc);
      tx_in_frame = !m_tlast;
    end
  end

  initial begin
    #500ms;
    tb_error("watchdog: bench did not finish");
    tb_verdict("tb_rtlnet_iperf");
  end

  // ---------------------------------------------------------------------------
  // Register access
  // ---------------------------------------------------------------------------
  task automatic reg_write(input bit [11:0] a, input bit [31:0] d);
    @(posedge clk);
    reg_wr_en <= 1'b1; reg_wr_addr <= a; reg_wr_data <= d;
    @(posedge clk);
    reg_wr_en <= 1'b0;
  endtask

  task automatic reg_read(input bit [11:0] a, output bit [31:0] d);
    bit [31:0] d2;
    while (busy || (cyc < in_tlast_cyc + 12)) @(posedge clk);
    @(posedge clk);
    reg_rd_en <= 1'b1; reg_rd_addr <= a;
    @(posedge clk);
    reg_rd_en <= 1'b0;
    #1 d = reg_rd_data;
    @(posedge clk);
    #1 d2 = reg_rd_data;
    if (d2 !== d) tb_error($sformatf("reg 0x%03h: read data did not hold", a));
  endtask

  task automatic reg_expect(input bit [11:0] a, input bit [31:0] exp, input string what);
    bit [31:0] d;
    reg_read(a, d);
    tb_check(d === exp, $sformatf("%s: reg 0x%03h = %08h (%0d), expected %08h (%0d)", what, a, d, d, exp, exp));
  endtask

  // ---------------------------------------------------------------------------
  // Datagram and frame builders
  // ---------------------------------------------------------------------------
  typedef struct {
    bit [47:0] smac;
    bit [31:0] sip;
    bit [15:0] sport;
    bit [47:0] dmac;
    bit [31:0] dip;
    bit [15:0] dport;
    longint    seq;           // signed sequence; negative = FIN
    bit        seq64;         // id2 carries the high word
    bit [31:0] tv_sec;
    bit [31:0] tv_usec;
    int        plen;          // UDP payload bytes
    bit [31:0] flags;
    bit [31:0] mbuflen;
    bit [31:0] mamount;
    bit [15:0] upper;
    bit [31:0] lrate;
  } dg_t;

  function automatic dg_t dg_new(input bit rev, input bit [47:0] smac, input bit [31:0] sip, input bit [15:0] sport,
                                 input int plen);
    dg_t d;
    d.smac = smac; d.sip = sip; d.sport = sport; d.dmac = DUT_MAC; d.dip = DUT_IP; d.dport = SRV_PORT;
    d.seq = 1; d.seq64 = 1; d.tv_sec = 32'd1_790_000_000; d.tv_usec = 32'd100_000; d.plen = plen;
    d.flags = rev ? FLAGS_R : FLAGS_U; d.mbuflen = 32'd1470; d.mamount = 32'hFFFF_FED4;   // -t 3
    d.upper = rev ? UPPER_R : 16'h0000; d.lrate = RATE_10M;
    return d;
  endfunction

  function automatic bytes_t dg_payload(input dg_t d);
    bytes_t p;
    bit [63:0] s;
    s = d.seq;
    push32(p, s[31:0]);
    push32(p, d.tv_sec);
    push32(p, d.tv_usec);
    push32(p, d.seq64 ? s[63:32] : 32'd0);
    push32(p, d.flags); push32(p, 32'd1); push32(p, 32'd5001); push32(p, d.mbuflen);
    push32(p, 32'd0); push32(p, d.mamount); push32(p, 32'd0); push32(p, 32'd0);
    push16(p, d.upper); push16(p, 16'd0); push32(p, 32'h0002_0002); push32(p, 32'h0002_0003); push32(p, 32'd0);
    push32(p, d.lrate); push32(p, 32'd0); push32(p, 32'd0); push32(p, 32'd0);
    while (p.size() > d.plen) void'(p.pop_back());
    while (p.size() < d.plen) p.push_back(8'h30 + (p.size() % 10));
    return p;
  endfunction

  bit [15:0] in_ident = 16'h0100;

  function automatic bytes_t dg_frame(input dg_t d);
    in_ident++;
    return pad60(udp_frame(d.dmac, d.smac, d.sip, d.dip, d.sport, d.dport, dg_payload(d), in_ident));
  endfunction

  function automatic void patch16(ref bytes_t f, input int at, input bit [15:0] v);
    f[at] = v[15:8]; f[at + 1] = v[7:0];
  endfunction

  function automatic void fix_ip_csum(ref bytes_t f, input int hlen);
    bit [15:0] c;
    patch16(f, 24, 16'h0000);
    c = inet_checksum(f, 14, hlen);
    patch16(f, 24, c);
  endfunction

  // Expected 170-byte server report.
  function automatic bytes_t report_frame(input bit [47:0] cmac, input bit [31:0] cip, input bit [15:0] cport,
                                          input bit [15:0] sport, input bit [15:0] ident, input longint bytes,
                                          input bit [31:0] stop_sec, input bit [31:0] stop_usec,
                                          input bit [31:0] lost, input bit [31:0] ooo, input bit [31:0] dgrams,
                                          input bit [31:0] j1, input bit [31:0] j2);
    bytes_t p;
    bytes_t udp;
    bytes_t f;
    bit [63:0] b;
    b = bytes;
    for (int i = 0; i < 16; i++) p.push_back(8'h00);
    push32(p, 32'h8800_0000);
    push32(p, b[63:32]); push32(p, b[31:0]);
    push32(p, stop_sec); push32(p, stop_usec);
    push32(p, lost); push32(p, ooo); push32(p, dgrams);
    push32(p, j1); push32(p, j2);
    while (p.size() < 128) p.push_back(8'h00);
    push16(udp, sport); push16(udp, cport); push16(udp, 16'd136); push16(udp, 16'd0);
    for (int i = 0; i < $size(p); i++) udp.push_back(p[i]);
    f = eth_header(cmac, DUT_MAC, 16'h0800);
    begin
      bytes_t ip;
      ip = ipv4_header(16'd156, ident, 8'd17, DUT_IP, cip, 8'd64, 16'h0000, 8'h00);
      for (int i = 0; i < $size(ip); i++) f.push_back(ip[i]);
    end
    for (int i = 0; i < $size(udp); i++) f.push_back(udp[i]);
    return f;
  endfunction

  // ---------------------------------------------------------------------------
  // Reference model of the iperf 2 server accounting (one flow)
  // ---------------------------------------------------------------------------
  longint m_packet_id;
  longint m_lost;
  longint m_ooo;
  longint m_bytes;
  int     m_dgrams;
  bit     m_have_transit;
  longint m_last_transit;
  longint m_jq;            // fixed point, JF fraction bits
  longint m_jsum;
  longint m_jcnt;
  real    m_jr;            // real-valued estimator
  real    m_jrsum;
  longint m_first_us;
  longint m_last_us;

  function automatic void model_open(input longint arrival_us);
    m_packet_id = 0; m_lost = 0; m_ooo = 0; m_bytes = 0; m_dgrams = 0; m_have_transit = 0; m_last_transit = 0;
    m_jq = 0; m_jsum = 0; m_jcnt = 0; m_jr = 0.0; m_jrsum = 0.0; m_first_us = arrival_us; m_last_us = arrival_us;
  endfunction

  // One datagram: p = magnitude, arrival in microseconds, sent time in us.
  function automatic void model_dgram(input longint p, input int plen, input longint arrival_us, input longint sent_us);
    bit ooo;
    longint transit;
    longint d;
    longint diff;
    real dr;
    m_dgrams++;
    m_bytes += plen;
    m_last_us = arrival_us;
    ooo = 0;
    if (p > 0) begin
      if (p != m_packet_id + 1) begin
        if (p < m_packet_id + 1) begin
          m_ooo++;
          ooo = 1;
        end else begin
          m_lost += p - m_packet_id - 1;
        end
      end
      if (p > m_packet_id) m_packet_id = p;
      if (!ooo) begin
        transit = arrival_us - sent_us;
        if (m_have_transit) begin
          d = transit - m_last_transit;
          if (d < 0) d = -d;
          diff = (d << JF) - m_jq;
          m_jq = m_jq + (diff >>> 4);
          m_jsum += m_jq;
          m_jcnt++;
          dr = d;
          m_jr = m_jr + (dr - m_jr) / 16.0;
          m_jrsum += m_jr;
        end
        m_last_transit = transit;
        m_have_transit = 1;
      end
    end
  endfunction

  // Sign of the 64-bit sequence of a frame the leaf sent (bytes 54-57 = id2).
  function automatic bit is_final(input bytes_t f);
    bit [31:0] id2;
    id2 = get32(f, 54);
    return id2[31];
  endfunction

  function automatic bit [31:0] model_err();
    return (m_lost > m_ooo) ? 32'(m_lost - m_ooo) : 32'd0;
  endfunction

  // ---------------------------------------------------------------------------
  // Stream helpers
  // ---------------------------------------------------------------------------
  longint last_in_end = 0;
  bit [15:0] cur_port = 16'd50000;  // client source port of the latest run_flow (a fresh one per test)
  bit [15:0] exp_ident = 16'd0;    // IP identification of the next DUT A frame

  // Send like the wrapper (gap >= 16 clocks after the last frame, not busy).
  task automatic send(input bytes_t f);
    while ((cyc - in_tlast_cyc) < 17 || busy) @(posedge clk);
    u_src.send(f);
  endtask

  // Send so the last beat is taken exactly at clock `target`; checks the gap
  // and busy rules first (the schedule must leave room).
  task automatic send_at(input bytes_t f, input longint target);
    int nb;
    nb = (f.size() + 7) / 8;
    tb_check(target - nb - in_tlast_cyc >= 17, $sformatf("bench schedule: gap before a frame (%0d)", target - nb - in_tlast_cyc));
    while (cyc < target - nb) @(posedge clk);
    tb_check(!busy, "bench schedule: frame sent while busy");
    u_src.send(f);
    @(posedge clk);
    tb_check(in_tlast_cyc == target, $sformatf("bench schedule: last beat at %0d, planned %0d", in_tlast_cyc, target));
  endtask

  task automatic get_frame(output bytes_t f, input int timeout, output bit ok);
    longint t;
    u_sink.get(f, timeout, ok);
    if (ok && tx_start_q.size() > 0) t = tx_start_q.pop_front();
  endtask

  task automatic expect_report(input bit [47:0] cmac, input bit [31:0] cip, input bit [15:0] cport,
                               input bit [15:0] sport, input longint bytes, input bit [31:0] stop_sec,
                               input bit [31:0] stop_usec, input bit [31:0] lost, input bit [31:0] ooo,
                               input bit [31:0] dgrams, input bit [31:0] j1, input bit [31:0] j2,
                               input string what);
    bytes_t f;
    bytes_t e;
    bit ok;
    bit same;
    string why;
    get_frame(f, 3000, ok);
    tb_check(ok, {what, ": no report"});
    if (ok) begin
      e = report_frame(cmac, cip, cport, sport, exp_ident, bytes, stop_sec, stop_usec, lost, ooo, dgrams, j1, j2);
      same = bytes_equal(f, e, why);
      tb_check(same, {what, ": report ", why});
      if (!same && f.size() >= 98) begin
        $display("  got: bytes %0d stop %0d.%06d lost %0d ooo %0d dgrams %0d jitter %0d.%06d", get32(f, 66),
                 get32(f, 70), get32(f, 74), get32(f, 78), get32(f, 82), get32(f, 86), get32(f, 90), get32(f, 94));
        $display("  exp: bytes %0d stop %0d.%06d lost %0d ooo %0d dgrams %0d jitter %0d.%06d", bytes, stop_sec,
                 stop_usec, lost, ooo, dgrams, j1, j2);
      end
      tb_check(inet_sum(f, 14, 20) == 16'hFFFF, {what, ": report IPv4 checksum"});
      exp_ident++;
    end
  endtask

  task automatic expect_silence(input int cycles, input string what);
    bit none;
    u_sink.expect_none(cycles, none);
    tb_check(none, {what, ": unexpected frame"});
    while (u_sink.frames.size() > 0) begin
      bytes_t f;
      bit ok;
      get_frame(f, 1, ok);
      exp_ident++;
    end
  endtask

  // Busy must be low 16 clocks after the last beat of a data datagram.
  task automatic check_busy_window(input string what);
    while (cyc < in_tlast_cyc + 16) @(posedge clk);
    tb_check(busy === 1'b0, {what, ": busy still high 16 clocks after a data datagram"});
  endtask

  // ---------------------------------------------------------------------------
  // Flow runner: sends the datagrams of one flow in the order given, each with
  // a whole-microsecond arrival, feeds the model, sends the FIN and checks the
  // report and the registers. ids[] are the signed sequence numbers in arrival
  // order (the FIN is added); arr_us[] the arrival offsets in microseconds;
  // sent_us[] the sender's time offsets.
  // ---------------------------------------------------------------------------
  task automatic run_flow(input longint ids[$], input longint arr_us[$], input longint snd_us[$],
                          input int plen, input longint fin_mag, input string what);
    dg_t d;
    bytes_t f;
    longint base;
    longint fin_arr;
    longint q;
    longint mean_us;
    longint sent;
    bit [31:0] rd;
    real mean_real;
    int c0;
    cur_port++;
    c0 = u_claim_mon.claims;
    base = ((cyc / US) + 20) * US;
    for (int i = 0; i < $size(ids); i++) begin
      d = dg_new(0, MAC_A, IP_A, cur_port, plen);
      d.seq = ids[i];
      sent = 64'd1_000_000 * 1_790_000_000 + 100_000 + snd_us[i];
      d.tv_sec = 32'(sent / 1_000_000);
      d.tv_usec = 32'(sent % 1_000_000);
      f = dg_frame(d);
      if (i == 0) model_open(arr_us[i]);
      send_at(f, base + arr_us[i] * US);
      model_dgram(ids[i] < 0 ? -ids[i] : ids[i], plen, arr_us[i], sent);
      check_busy_window({what, $sformatf(" datagram %0d", i)});
    end
    reg_expect(R_STATUS, 32'h0001_0001, {what, " rx_active during the flow"});
    // FIN: arrival 2 ms after the last datagram's arrival offset.
    fin_arr = arr_us[$size(arr_us) - 1] + 200;
    d = dg_new(0, MAC_A, IP_A, cur_port, plen);
    d.seq = -fin_mag;
    sent = 64'd1_000_000 * 1_790_000_000 + 100_000 + snd_us[$size(snd_us) - 1] + 200;
    d.tv_sec = 32'(sent / 1_000_000);
    d.tv_usec = 32'(sent % 1_000_000);
    send_at(dg_frame(d), base + fin_arr * US);
    model_dgram(fin_mag, plen, fin_arr, sent);
    q = (m_jcnt == 0) ? 0 : (m_jsum / m_jcnt);
    mean_us = q >>> JF;
    expect_report(MAC_A, IP_A, cur_port, SRV_PORT, m_bytes, 32'((fin_arr - arr_us[0]) / 1_000_000),
                  32'((fin_arr - arr_us[0]) % 1_000_000), model_err(), 32'(m_ooo), 32'(m_packet_id),
                  32'(mean_us / 1_000_000), 32'(mean_us % 1_000_000), what);
    if (m_jcnt > 0) begin
      real mean_fixed;
      mean_real  = m_jrsum / m_jcnt;
      mean_fixed = q / 65536.0;
      tb_check((mean_real - mean_fixed) > -0.01 && (mean_real - mean_fixed) < 0.01,
               $sformatf("%s: fixed-point mean jitter %0f us vs real-valued %0f us", what, mean_fixed, mean_real));
    end
    reg_expect(R_RXD, 32'(m_dgrams), {what, " RX_DATAGRAMS"});
    reg_expect(R_RXB_LO, 32'(m_bytes), {what, " RX_BYTES_LO"});
    reg_expect(R_RXB_HI, 32'd0, {what, " RX_BYTES_HI"});
    reg_expect(R_LOST, model_err(), {what, " RX_LOST"});
    reg_expect(R_OOO, 32'(m_ooo), {what, " RX_OUTOFORDER"});
    reg_expect(R_JIT, 32'(m_jq >>> (JF - 4)), {what, " JITTER_US16"});
    reg_expect(R_DUR, 32'(fin_arr - arr_us[0]), {what, " LAST_DURATION_US"});
    reg_expect(R_RATE, (plen >= 80) ? RATE_10M : 32'd0, {what, " REQ_RATE_BPS"});
    reg_expect(R_STATUS, 32'h0001_0000, {what, " flow closed"});
    tb_check(u_claim_mon.claims - c0 == $size(ids) + 1, $sformatf("%s: %0d claims, expected %0d (every datagram and the FIN)",
             what, u_claim_mon.claims - c0, $size(ids) + 1));
  endtask

  // Regular schedule: ids in order, arrivals every `gap` us with optional
  // random arrival jitter, sender every `gap` us.
  task automatic regular(input int n, input int gap, input int arr_jit, output longint ids[$],
                         output longint arr[$], output longint snd[$]);
    longint a;
    ids = {}; arr = {}; snd = {};
    a = 0;
    for (int i = 0; i < n; i++) begin
      ids.push_back(i + 1);
      snd.push_back(i * gap);
      a = i * gap + ((arr_jit > 0) ? $urandom_range(0, arr_jit) : 0);
      if (arr.size() > 0 && a <= arr[arr.size() - 1] + 8) a = arr[arr.size() - 1] + 8;
      arr.push_back(a);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Case 1: registers
  // ---------------------------------------------------------------------------
  task automatic case_registers();
    bit [31:0] d;
    reg_expect(R_ID, 32'h4950_5246, "ID");
    reg_expect(R_VERSION, 32'h1022_2026, "VERSION");
    reg_expect(R_CAPS, (32'd50_000 << 14) | 32'd1472, "CAPS");
    reg_expect(R_CTRL, 32'h1, "CTRL reset (REVERSE_ALLOWED)");
    reg_expect(R_PORT, 32'd5001, "UDP_PORT reset");
    reg_expect(R_STATUS, 32'h0001_0000, "STATUS reset");
    reg_write(R_PORT, 32'hABCD_1234);
    reg_expect(R_PORT, 32'h0000_1234, "UDP_PORT 16 bits");
    reg_write(R_PORT, 32'd5001);
    reg_write(R_CTRL, 32'h0);
    reg_expect(R_CTRL, 32'h0, "REVERSE_ALLOWED off");
    reg_write(R_CTRL, C_REV | C_CLEAR);
    reg_expect(R_CTRL, C_REV, "CNT_CLEAR reads 0");
    reg_write(R_ID, 32'h1); reg_write(R_RXD, 32'h55); reg_write(R_CAPS, 32'h0);
    reg_expect(R_ID, 32'h4950_5246, "ID read-only");
    reg_expect(R_RXD, 32'h0, "RX_DATAGRAMS read-only");
    for (int a = 12'h040; a <= 12'h0FC; a += 4) begin
      reg_read(12'(a), d);
      tb_check(d == 0, $sformatf("undefined offset 0x%03h reads %08h", a, d));
    end
    reg_expect(12'hFFC, 32'h0, "undefined 0xFFC");
    @(posedge clk);
    reg_rd_en <= 1'b1; reg_rd_addr <= R_VERSION;
    @(posedge clk);
    reg_rd_en <= 1'b1; reg_rd_addr <= R_PORT;
    #1 tb_check(reg_rd_data == 32'h1022_2026, "read latency: VERSION one clock after reg_rd_en");
    @(posedge clk);
    reg_rd_en <= 1'b0;
    #1 tb_check(reg_rd_data == 32'd5001, "read latency: UDP_PORT one clock after reg_rd_en");
    expect_silence(200, "registers");
  endtask

  // ---------------------------------------------------------------------------
  // Case 2: plain flow
  // ---------------------------------------------------------------------------
  task automatic case_plain();
    longint ids[$];
    longint arr[$];
    longint snd[$];
    regular(40, 30, 0, ids, arr, snd);
    run_flow(ids, arr, snd, 1470, 41, "plain 40 x 1470");
    regular(25, 12, 3, ids, arr, snd);
    run_flow(ids, arr, snd, 100, 26, "plain 25 x 100, arrival jitter");
    reg_expect(R_REPS, 2, "REPORTS_SENT after two flows");
  endtask

  // ---------------------------------------------------------------------------
  // Case 3: loss and reordering
  // ---------------------------------------------------------------------------
  task automatic case_loss();
    longint ids[$];
    longint arr[$];
    longint snd[$];
    longint t;
    // Literal: ids 1..100, only even ids arrive, FIN 101: iperf prints 50/101.
    ids = {}; arr = {}; snd = {};
    for (int i = 2; i <= 100; i += 2) begin ids.push_back(i); arr.push_back(i * 10); snd.push_back(i * 10); end
    run_flow(ids, arr, snd, 200, 101, "50 % loss");
    tb_check(m_packet_id == 101 && model_err() == 50, "model: the literal 50 lost of 101");
    // Reorder: 1 2 4 3 5 7 6 8 (two late datagrams, no loss in the end).
    ids = {1, 2, 4, 3, 5, 7, 6, 8}; arr = {0, 10, 20, 30, 40, 50, 60, 70}; snd = {0, 10, 30, 20, 40, 60, 50, 70};
    run_flow(ids, arr, snd, 300, 9, "reorder");
    tb_check(model_err() == 0 && m_ooo == 2, "model: reorder gives 0 lost, 2 out of order");
    // Duplicates with no loss: clamped at 0.
    ids = {1, 2, 2, 3, 3, 3, 4}; arr = {0, 10, 20, 30, 40, 50, 60}; snd = {0, 10, 10, 20, 20, 20, 30};
    run_flow(ids, arr, snd, 300, 5, "duplicates");
    tb_check(model_err() == 0 && m_ooo == 3, "model: duplicates clamp the lost count at 0");
    // Duplicate subtracted from a loss: 1 3 3 4 (2 lost, 1 duplicate) -> 0 lost.
    ids = {1, 3, 3, 4}; arr = {0, 10, 20, 30}; snd = {0, 20, 20, 30};
    run_flow(ids, arr, snd, 64, 5, "duplicate against a loss");
    // Last datagram lost: 1..9, FIN 11.
    regular(9, 10, 0, ids, arr, snd);
    run_flow(ids, arr, snd, 64, 11, "last datagram lost");
    tb_check(model_err() == 1, "model: a lost last datagram counts");
    // 300 random: drops 10 %, adjacent swaps 5 %, duplicates 3 %.
    ids = {}; arr = {}; snd = {};
    t = 0;
    for (int i = 1; i <= 300; i++) begin
      int r;
      r = $urandom_range(0, 99);
      if (r < 10) continue;
      ids.push_back(i);
      snd.push_back(i * 10);
      if (r >= 90 && r < 93) begin ids.push_back(i); snd.push_back(i * 10); end
      if (r >= 93 && ids.size() >= 2) begin
        longint x;
        x = ids[ids.size() - 1]; ids[ids.size() - 1] = ids[ids.size() - 2]; ids[ids.size() - 2] = x;
        x = snd[snd.size() - 1]; snd[snd.size() - 1] = snd[snd.size() - 2]; snd[snd.size() - 2] = x;
      end
    end
    for (int i = 0; i < $size(ids); i++) begin
      t = t + 6 + $urandom_range(0, 8);
      arr.push_back(t);
    end
    run_flow(ids, arr, snd, 120, 301, "300 random drops, swaps, duplicates");
    $display("tb_rtlnet_iperf: random flow lost=%0d ooo=%0d datagrams=%0d", model_err(), m_ooo, m_packet_id);
  endtask

  // ---------------------------------------------------------------------------
  // Case 4: jitter
  // ---------------------------------------------------------------------------
  task automatic case_jitter();
    longint ids[$];
    longint arr[$];
    longint snd[$];
    // Steady sender, arrivals with up to 40 us of random delay.
    regular(200, 50, 40, ids, arr, snd);
    run_flow(ids, arr, snd, 100, 201, "jitter 0..40 us");
    tb_check(m_jsum > 0, "model: nonzero jitter");
    // Sender time crossing a second boundary (tv_usec wraps, tv_sec steps).
    ids = {}; arr = {}; snd = {};
    for (int i = 0; i < 30; i++) begin
      ids.push_back(i + 1);
      snd.push_back(899_000 + i * 200);        // the sender's tv_usec wraps at i = 5
      arr.push_back(i * 200 + ((i % 3) * 7));
    end
    run_flow(ids, arr, snd, 100, 31, "jitter across a sender second");
    // A large constant offset change (one step of 500 us) and quiet afterwards.
    ids = {}; arr = {}; snd = {};
    for (int i = 0; i < 40; i++) begin
      ids.push_back(i + 1);
      snd.push_back(i * 100);
      arr.push_back(i * 100 + ((i >= 20) ? 500 : 0));
    end
    run_flow(ids, arr, snd, 100, 41, "jitter step");
  endtask

  // ---------------------------------------------------------------------------
  // Case 5: FIN rules, 32-bit sequence, other source
  // ---------------------------------------------------------------------------
  task automatic case_fin_rules();
    longint ids[$];
    longint arr[$];
    longint snd[$];
    dg_t d;
    bytes_t f;
    bytes_t rep1;
    bytes_t rep2;
    bit ok;
    string why;
    bit same;
    bit [31:0] reps;
    regular(10, 20, 0, ids, arr, snd);
    run_flow(ids, arr, snd, 500, 11, "flow before FIN retries");
    reg_read(R_REPS, reps);
    claim_mark = u_claim_mon.claims;
    // Repeated FIN (the client repeats every 10 ms): the same report again.
    d = dg_new(0, MAC_A, IP_A, cur_port, 500);
    d.seq = -12;
    send(dg_frame(d));
    get_frame(rep1, 3000, ok);
    tb_check(ok, "FIN retry: report resent");
    if (ok) begin
      rep2 = report_frame(MAC_A, IP_A, cur_port, SRV_PORT, exp_ident, m_bytes,
                          32'((m_last_us - m_first_us) / 1_000_000), 32'((m_last_us - m_first_us) % 1_000_000),
                          model_err(), 32'(m_ooo), 32'(m_packet_id), 32'd0,
                          32'(((m_jcnt == 0) ? 0 : (m_jsum / m_jcnt)) >>> JF));
      same = bytes_equal(rep1, rep2, why);
      tb_check(same, {"FIN retry: identical report ", why});
      exp_ident++;
    end
    reg_expect(R_REPS, reps + 1, "REPORTS_SENT counts the resend");
    claims_expect(1, "FIN retry");
    // A late data datagram of the finished flow opens nothing; the next FIN
    // retry still gets the original report.
    d.seq = 7;
    send(dg_frame(d));
    expect_silence(300, "late datagram after the FIN");
    claims_expect(0, "late datagram after the FIN");
    reg_expect(R_STATUS, 32'h0001_0000, "late datagram opens no flow");
    d.seq = -13;
    send(dg_frame(d));
    get_frame(rep1, 3000, ok);
    tb_check(ok && rep1.size() == 170 && get32(rep1, 86) == 32'(m_packet_id), "FIN retry after the late datagram");
    if (ok) exp_ident++;
    claims_expect(1, "FIN retry after the late datagram");
    // An unknown FIN (other client) is ignored.
    d = dg_new(0, MAC_B, IP_B, PORT_B, 500);
    d.seq = -50;
    send(dg_frame(d));
    expect_silence(300, "unknown FIN");
    claims_expect(0, "unknown FIN");
    // 32-bit sequence: short datagrams without the client header (flags read 0).
    ids = {}; arr = {}; snd = {};
    for (int i = 0; i < 12; i++) begin ids.push_back(i + 1); arr.push_back(i * 15); snd.push_back(i * 15); end
    begin
      longint base;
      base = ((cyc / US) + 20) * US;
      model_open(0);
      for (int i = 0; i < $size(ids); i++) begin
        d = dg_new(0, MAC_A, IP_A, PORT_A, 40);
        d.seq = ids[i]; d.seq64 = 0;
        d.tv_usec = 32'(100_000 + snd[i]);
        send_at(dg_frame(d), base + arr[i] * US);
        model_dgram(ids[i], 40, arr[i], 64'd1_000_000 * 1_790_000_000 + 100_000 + snd[i]);
      end
      // 32-bit FIN: id = -13 as a 32-bit word, id2 = 0 (seq64 = 0 keeps it 0).
      d.seq = -13; d.seq64 = 0;
      d.tv_usec = 32'(100_000 + 200);
      send_at(dg_frame(d), base + 400 * US);
      model_dgram(13, 40, 400, 64'd1_000_000 * 1_790_000_000 + 100_000 + 200);
      expect_report(MAC_A, IP_A, PORT_A, SRV_PORT, m_bytes, 0, 400, model_err(), 32'(m_ooo), 32'(m_packet_id),
                    0, 32'(((m_jcnt == 0) ? 0 : (m_jsum / m_jcnt)) >>> JF), "32-bit sequence flow");
    end
    claims_expect(13, "32-bit sequence flow and its FIN");
    // Another source while a flow is open is ignored.
    d = dg_new(0, MAC_A, IP_A, PORT_A, 200);
    d.seq = 1;
    send(dg_frame(d));
    d = dg_new(0, MAC_B, IP_B, PORT_B, 200);
    d.seq = 1;
    send(dg_frame(d));
    d.seq = -2;
    send(dg_frame(d));
    expect_silence(500, "other source while a flow is open");
    reg_expect(R_RXD, 1, "other source not counted");
    claims_expect(1, "open flow's first datagram claimed, other source not");
    d = dg_new(0, MAC_A, IP_A, PORT_A, 200);
    d.seq = -2;
    send(dg_frame(d));
    get_frame(f, 3000, ok);
    tb_check(ok && f.size() == 170 && get32(f, 86) == 2 && get32(f, 66) == 400, "open flow's FIN answered");
    if (ok) exp_ident++;
    claims_expect(1, "open flow's FIN");
  endtask

  // ---------------------------------------------------------------------------
  // Case 6: ignored traffic, leaf disabled
  // ---------------------------------------------------------------------------
  task automatic case_ignored();
    dg_t d;
    bytes_t f;
    claim_mark = u_claim_mon.claims;
    for (int which = 0; which < 12; which++) begin
      d = dg_new(0, MAC_A, IP_A, PORT_A, 200);
      d.seq = 1;
      case (which)
        0: d.dmac = 48'h02_49_50_52_46_02;
        1: d.dip = DUT_IP + 1;
        2: d.dport = 16'd5002;
        3: d.dmac = 48'hFFFF_FFFF_FFFF;
        default: begin end
      endcase
      f = dg_frame(d);
      case (which)
        4: begin f[23] = 8'd6; fix_ip_csum(f, 20); end                       // TCP
        5: begin patch16(f, 20, 16'h2000); fix_ip_csum(f, 20); end           // MF
        6: begin patch16(f, 20, 16'h0010); fix_ip_csum(f, 20); end           // fragment offset
        7: begin patch16(f, 38, 16'd23); end                                 // UDP length < 24
        8: begin patch16(f, 38, 16'd400); end                                // UDP length past the frame
        9: begin f[14] = 8'h46; fix_ip_csum(f, 20); end                      // IHL 6
        10: begin patch16(f, 12, 16'h0806); end                              // EtherType ARP
        11: begin enable = 1'b0; end                                         // leaf disabled
        default: begin end
      endcase
      send(f);
      d.seq = -2;
      f = dg_frame(d);
      case (which)
        4: begin f[23] = 8'd6; fix_ip_csum(f, 20); end
        5: begin patch16(f, 20, 16'h2000); fix_ip_csum(f, 20); end
        6: begin patch16(f, 20, 16'h0010); fix_ip_csum(f, 20); end
        7: begin patch16(f, 38, 16'd23); end
        8: begin patch16(f, 38, 16'd400); end
        9: begin f[14] = 8'h46; fix_ip_csum(f, 20); end
        10: begin patch16(f, 12, 16'h0806); end
        default: begin end
      endcase
      send(f);
      expect_silence(400, $sformatf("ignored traffic %0d", which));
      reg_expect(R_STATUS, (which == 11) ? 32'h0 : 32'h0001_0000, $sformatf("ignored traffic %0d: no flow", which));
      claims_expect(0, $sformatf("ignored traffic %0d", which));
      enable = 1'b1;
    end
    // A real ARP request to the DUT is not iperf.
    f = eth_header(48'hFFFF_FFFF_FFFF, MAC_A, 16'h0806);
    push16(f, 16'd1); push16(f, 16'h0800); f.push_back(8'd6); f.push_back(8'd4); push16(f, 16'd1);
    push48(f, MAC_A); push32(f, IP_A); push48(f, 48'd0); push32(f, DUT_IP);
    send(pad60(f));
    expect_silence(300, "ARP request");
    claims_expect(0, "ARP request");
    // UDP length exactly the frame (no padding): accepted.
    d = dg_new(0, MAC_A, IP_A, PORT_A, 88);
    d.seq = 1;
    send(dg_frame(d));
    d.seq = -2;
    send(dg_frame(d));
    begin
      bit ok;
      get_frame(f, 3000, ok);
      tb_check(ok && f.size() == 170 && get32(f, 66) == 176, "88-byte datagrams accepted");
      if (ok) exp_ident++;
    end
    claims_expect(2, "88-byte datagram and FIN");
  endtask

  // ---------------------------------------------------------------------------
  // Case 7: idle timeout
  // ---------------------------------------------------------------------------
  task automatic case_idle();
    dg_t d;
    longint ids[$];
    longint arr[$];
    longint snd[$];
    d = dg_new(0, MAC_A, IP_A, PORT_A, 300);
    for (int i = 1; i <= 5; i++) begin d.seq = i; send(dg_frame(d)); end
    reg_expect(R_STATUS, 32'h0001_0001, "flow open before the idle timeout");
    repeat (IDLE_MS * 1000 * US - 2000) @(posedge clk);
    reg_expect(R_STATUS, 32'h0001_0001, "flow still open just before the timeout");
    repeat (4000) @(posedge clk);
    reg_expect(R_STATUS, 32'h0001_0000, "flow closed by the idle timeout");
    reg_expect(R_RXD, 5, "counters kept after the idle timeout");
    d.seq = -6;
    send(dg_frame(d));
    expect_silence(500, "FIN after the idle timeout");
    regular(6, 40, 0, ids, arr, snd);
    run_flow(ids, arr, snd, 300, 7, "new flow after the idle timeout");
  endtask

  // ---------------------------------------------------------------------------
  // Case 8: reverse stream
  // ---------------------------------------------------------------------------
  // Collect one stream to (cmac, cip, cport): returns data datagrams counted,
  // checks every datagram on the fly and the final one exactly once and last.
  // Reports seen in between are counted and checked for their destination.
  task automatic collect_stream(input bit [47:0] cmac, input bit [31:0] cip, input bit [15:0] cport,
                                input bit [15:0] sport, input int len, input int timeout,
                                output int n, output int reports, output longint first_cyc, output longint gap_max,
                                output longint gap_min, input string what);
    bytes_t f;
    bit ok;
    bit done;
    longint t;
    longint prev_t;
    bit [63:0] seq;
    bit [31:0] ts_prev;
    bit [31:0] tu_prev;
    n = 0; reports = 0; done = 0; prev_t = 0; gap_max = 0; gap_min = 64'h7FFF_FFFF; first_cyc = 0;
    ts_prev = 0; tu_prev = 0;
    while (!done) begin
      u_sink.get(f, timeout, ok);
      if (!ok) begin
        tb_error({what, ": stream stopped without a final datagram"});
        done = 1;
      end else begin
        t = (tx_start_q.size() > 0) ? tx_start_q.pop_front() : 0;
        if (f.size() == 170 && get16(f, 36) != cport) begin
          reports++;
          exp_ident++;
          continue;
        end
        tb_check(f.size() == 42 + len, $sformatf("%s: datagram length %0d, expected %0d", what, f.size(), 42 + len));
        if (f.size() < 58) begin exp_ident++; continue; end
        tb_check(get48(f, 0) == cmac && get48(f, 6) == DUT_MAC && get16(f, 12) == 16'h0800, {what, ": Ethernet"});
        tb_check(f[14] == 8'h45 && get16(f, 16) == 16'(28 + len) && get16(f, 18) == exp_ident && get16(f, 20) == 0 &&
                 f[22] == 8'd64 && f[23] == 8'd17 && get32(f, 26) == DUT_IP && get32(f, 30) == cip, {what, ": IPv4"});
        tb_check(inet_sum(f, 14, 20) == 16'hFFFF, {what, ": IPv4 checksum"});
        tb_check(get16(f, 34) == sport && get16(f, 36) == cport && get16(f, 38) == 16'(8 + len) && get16(f, 40) == 0,
                 {what, ": UDP header"});
        exp_ident++;
        seq = {get32(f, 54), get32(f, 42)};
        tb_check(get32(f, 50) < 32'd1_000_000, {what, ": tv_usec range"});
        tb_check({get32(f, 46), get32(f, 50)} >= {ts_prev, tu_prev}, {what, ": timestamps move forward"});
        ts_prev = get32(f, 46); tu_prev = get32(f, 50);
        begin
          bit zeros;
          zeros = 1;
          for (int i = 58; i < f.size(); i++) if (f[i] != 8'h00) zeros = 0;
          tb_check(zeros, {what, ": payload after the datagram header is zero"});
        end
        if (seq[63]) begin
          tb_check(seq == 64'd0 - 64'(n + 1), $sformatf("%s: final datagram id %0d, expected -%0d", what, $signed(seq), n + 1));
          done = 1;
        end else begin
          n++;
          tb_check(seq == 64'(n), $sformatf("%s: datagram id %0d, expected %0d", what, seq, n));
          if (n == 1) first_cyc = t;
          else begin
            if (t - prev_t > gap_max) gap_max = t - prev_t;
            if (t - prev_t < gap_min) gap_min = t - prev_t;
          end
          prev_t = t;
        end
      end
    end
  endtask

  task automatic reverse_request(input bit [47:0] smac, input bit [31:0] sip, input bit [15:0] sport,
                                 input bit [31:0] mbuflen, input bit [31:0] mamount, input bit [31:0] rate);
    dg_t d;
    d = dg_new(1, smac, sip, sport, 1470);
    d.mbuflen = mbuflen; d.mamount = mamount; d.lrate = rate;
    send(dg_frame(d));
  endtask

  task automatic case_reverse();
    int n;
    int reps;
    longint t0;
    longint gmax;
    longint gmin;
    bit [31:0] d;
    // Paced: 100-byte payload at 8 Mbit/s = one datagram per 100 us for 10 ms.
    claim_mark = u_claim_mon.claims;
    reverse_request(MAC_A, IP_A, PORT_A, 32'd100, 32'hFFFF_FFFF, 32'd8_000_000);
    claims_expect(1, "-R request");
    repeat (300) @(posedge clk);
    reg_expect(R_STATUS, 32'h0001_0002, "tx_active during the stream");
    reg_expect(R_RATE, 32'd8_000_000, "REQ_RATE_BPS of the -R request");
    collect_stream(MAC_A, IP_A, PORT_A, SRV_PORT, 100, 20000, n, reps, t0, gmax, gmin, "paced stream");
    tb_check(n >= 100 && n <= 101, $sformatf("paced stream: %0d datagrams in 10 ms at 100 us", n));
    // The first gap depends on the microsecond phase of the start; the rest are exact.
    tb_check(gmin > 99 * US && gmax == 100 * US, $sformatf("paced stream spacing %0d..%0d clocks", gmin, gmax));
    reg_expect(R_TXD, n, "TX_DATAGRAMS (final datagram excluded)");
    reg_expect(R_STATUS, 32'h0001_0000, "stream ended");
    expect_silence(2000, "nothing after the final datagram");
    // Unpaced, byte mode (mAmount >= 0: BYTE_MODE_MS), mBufLen 0 -> 1470, random stalls.
    u_sink.ready_pct = 60;
    reverse_request(MAC_A, IP_A, PORT_A, 32'd0, 32'd1_000_000, 32'd0);
    collect_stream(MAC_A, IP_A, PORT_A, SRV_PORT, 1470, 20000, n, reps, t0, gmax, gmin, "byte mode, 1470 default");
    tb_check(n > 100, $sformatf("byte-mode stream %0d datagrams", n));
    u_sink.ready_pct = 100;
    // Over the maximum: clamped to MAX_DGRAM_BYTES; long stalls.
    u_sink.ready_pct = 4;
    reverse_request(MAC_A, IP_A, PORT_A, 32'd9000, 32'hFFFF_FFFF, 32'd0);
    collect_stream(MAC_A, IP_A, PORT_A, SRV_PORT, MAX_DGRAM, 400000, n, reps, t0, gmax, gmin, "clamped to the maximum");
    u_sink.ready_pct = 100;
    // Under 16: clamped to 16 (frame 58 bytes); header repeats from the client
    // being served are ignored; a receive flow with its report goes out between
    // stream datagrams.
    reverse_request(MAC_A, IP_A, PORT_A, 32'd5, 32'hFFFF_FFFE, 32'd4_000_000);
    fork
      collect_stream(MAC_A, IP_A, PORT_A, SRV_PORT, 16, 20000, n, reps, t0, gmax, gmin, "16-byte stream");
      begin
        dg_t g;
        repeat (200) @(posedge clk);
        reverse_request(MAC_A, IP_A, PORT_A, 32'd5, 32'hFFFF_FFFE, 32'd4_000_000);   // repeat: ignored
        g = dg_new(0, MAC_B, IP_B, PORT_B, 200);
        for (int i = 1; i <= 5; i++) begin g.seq = i; send(dg_frame(g)); end
        g.seq = -6;
        send(dg_frame(g));
      end
    join
    tb_check(n >= 625 && n <= 626, $sformatf("16-byte stream: %0d datagrams in 20 ms at 32 us", n));
    tb_check(reps == 1, $sformatf("one report interleaved with the stream (%0d)", reps));
    // A request from another client restarts the stream towards it.
    reverse_request(MAC_A, IP_A, PORT_A, 32'd200, 32'hFFFF_FFFF, 32'd0);
    repeat (3000) @(posedge clk);
    reverse_request(MAC_B, IP_B, PORT_B, 32'd300, 32'hFFFF_FFFF, 32'd24_000_000);
    begin
      bytes_t f;
      bit ok;
      int na;
      bit finished;
      na = 0;
      finished = 0;
      // Drain the first client's datagrams up to the restart (no final for it).
      while (!finished) begin
        u_sink.get(f, 20000, ok);
        if (!ok) begin tb_error("restart: stream lost"); finished = 1; end
        else begin
          if (get48(f, 0) == MAC_A) begin
            if (tx_start_q.size() > 0) void'(tx_start_q.pop_front());
            tb_check(!is_final(f), "restart: no final datagram to the first client");
            na++;
            exp_ident++;
          end else begin
            tb_check(get48(f, 0) == MAC_B && f.size() == 342 && get32(f, 42) == 1, "restart: second client's first datagram");
            u_sink.frames.push_front(f);                 // collect_stream checks it
            finished = 1;
          end
        end
      end
      tb_check(na > 5, $sformatf("restart: first client received %0d datagrams", na));
      collect_stream(MAC_B, IP_B, PORT_B, SRV_PORT, 300, 20000, n, reps, t0, gmax, gmin, "restarted stream");
      tb_check(n >= 100 && n <= 101, $sformatf("restarted stream: %0d datagrams at 100 us", n));
    end
    // REVERSE_ALLOWED off: the request starts nothing and opens no flow.
    reg_write(R_CTRL, 32'h0);
    claim_mark = u_claim_mon.claims;
    reverse_request(MAC_A, IP_A, PORT_A, 32'd100, 32'hFFFF_FFFF, 32'd0);
    expect_silence(5000, "REVERSE_ALLOWED off");
    claims_expect(0, "-R request with REVERSE_ALLOWED off");
    reg_expect(R_STATUS, 32'h0001_0000, "REVERSE_ALLOWED off: no stream, no flow");
    reg_write(R_CTRL, C_REV);
    // Disabling the leaf stops a stream with no final datagram.
    reverse_request(MAC_A, IP_A, PORT_A, 32'd100, 32'hFFFF_FFFF, 32'd0);
    repeat (2000) @(posedge clk);
    enable = 1'b0;
    repeat (400) @(posedge clk);
    while (u_sink.frames.size() > 0) begin
      bytes_t f;
      bit ok;
      get_frame(f, 1, ok);
      tb_check(!is_final(f), "disable: no final datagram");
      exp_ident++;
    end
    expect_silence(3000, "disabled leaf sends nothing");
    reg_read(R_STATUS, d);
    tb_check(d == 32'h0, "disabled: stream stopped");
    enable = 1'b1;
    expect_silence(1000, "re-enabled: nothing owed");
  endtask

  // ---------------------------------------------------------------------------
  // Case 9: UDP_PORT, CNT_CLEAR, overlapping frame
  // ---------------------------------------------------------------------------
  task automatic case_port_clear();
    dg_t d;
    bytes_t f;
    bit ok;
    reg_write(R_PORT, 32'd6001);
    d = dg_new(0, MAC_A, IP_A, PORT_A, 200);
    d.seq = 1;
    send(dg_frame(d));
    reg_expect(R_STATUS, 32'h0001_0000, "old port ignored after the change");
    d.dport = 16'd6001;
    for (int i = 1; i <= 3; i++) begin d.seq = i; send(dg_frame(d)); end
    reg_expect(R_RXD, 3, "new port counted");
    d.seq = -4;
    send(dg_frame(d));
    get_frame(f, 3000, ok);
    tb_check(ok && f.size() == 170 && get16(f, 34) == 16'd6001 && get16(f, 36) == PORT_A && get32(f, 86) == 4,
             "report from the new port");
    if (ok) exp_ident++;
    // Overlap: a datagram whose first beat comes 8 clocks after the FIN's last
    // beat (the accounting divides then) is skipped whole.
    d.seq = 1;
    send(dg_frame(d));
    d.seq = -2;
    send(dg_frame(d));
    repeat (8) @(posedge clk);
    d = dg_new(0, MAC_B, IP_B, PORT_B, 200);
    d.dport = 16'd6001;
    d.seq = 1;
    u_src.send(dg_frame(d));
    get_frame(f, 3000, ok);
    tb_check(ok && f.size() == 170 && get32(f, 86) == 2, "report after the overlap");
    if (ok) exp_ident++;
    reg_expect(R_STATUS, 32'h0001_0000, "overlapping frame skipped: no flow opened");
    reg_write(R_PORT, 32'd5001);
    reg_write(R_CTRL, C_REV | C_CLEAR);
    reg_expect(R_RXD, 0, "CNT_CLEAR RX_DATAGRAMS");
    reg_expect(R_RXB_LO, 0, "CNT_CLEAR RX_BYTES_LO");
    reg_expect(R_LOST, 0, "CNT_CLEAR RX_LOST");
    reg_expect(R_OOO, 0, "CNT_CLEAR RX_OUTOFORDER");
    reg_expect(R_TXD, 0, "CNT_CLEAR TX_DATAGRAMS");
    reg_expect(R_REPS, 0, "CNT_CLEAR REPORTS_SENT");
    reg_expect(R_CTRL, C_REV, "CNT_CLEAR keeps REVERSE_ALLOWED");
    // CNT_CLEAR in the middle of a flow does not disturb its report.
    begin
      longint ids[$];
      longint arr[$];
      longint snd[$];
      d = dg_new(0, MAC_A, IP_A, PORT_A, 100);
      for (int i = 1; i <= 4; i++) begin d.seq = i; send(dg_frame(d)); end
      reg_write(R_CTRL, C_REV | C_CLEAR);
      d.seq = 5; send(dg_frame(d));
      reg_expect(R_RXD, 1, "CNT_CLEAR mid-flow: view restarts");
      d.seq = -6; send(dg_frame(d));
      get_frame(f, 3000, ok);
      tb_check(ok && get32(f, 86) == 6 && get32(f, 66) == 600 && get32(f, 78) == 0, "mid-flow CNT_CLEAR: report intact");
      if (ok) exp_ident++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Case 10: DUT B (33.333333 MHz, MAX_DGRAM_BYTES 100)
  // ---------------------------------------------------------------------------
  task automatic case_dut_b();
    dg_t d;
    bytes_t f;
    bit ok;
    longint t1;
    longint t2;
    longint exp_us;
    bit [31:0] dur;
    @(posedge clk_b);
    rb_rd_en <= 1'b1; rb_rd_addr <= R_CAPS;
    @(posedge clk_b);
    rb_rd_en <= 1'b0;
    #1 tb_check(rb_rd_data == ((32'd33_333 << 14) | 32'd100), $sformatf("DUT B CAPS %08h", rb_rd_data));
    // Duration: first datagram, then the FIN 666 667 clocks later (20 ms).
    d = dg_new(0, MAC_A, IP_A, PORT_A, 100);
    d.seq = 1;
    repeat (20) @(posedge clk_b);
    u_src_b.send(dg_frame(d));
    @(posedge clk_b);
    t1 = in_tlast_cyc_b;
    for (int i = 2; i <= 22; i++) begin
      d.seq = i;
      while (cyc_b < t1 + (i - 1) * 30_000) @(posedge clk_b);
      u_src_b.send(dg_frame(d));
    end
    d.seq = -23;
    while (cyc_b < t1 + 666_667 - 18) @(posedge clk_b);
    u_src_b.send(dg_frame(d));
    @(posedge clk_b);
    t2 = in_tlast_cyc_b;
    u_sink_b.get(f, 3000, ok);
    exp_us = ((t2 - t1) * 30) / 1000;
    if (ok) dur = get32(f, 70) * 1_000_000 + get32(f, 74);
    tb_check(ok && f.size() == 170, "DUT B report");
    tb_check(ok && (dur == exp_us || dur == exp_us + 1 || dur + 1 == exp_us),
             $sformatf("DUT B duration %0d us for %0d clocks of 30 ns (%0d us)", dur, t2 - t1, exp_us));
    // Stream clamp: mBufLen 1470 > MAX_DGRAM_BYTES 100.
    d = dg_new(1, MAC_A, IP_A, PORT_A, 1470);
    d.mamount = 32'hFFFF_FFFF; d.lrate = 32'd8_000_000;
    repeat (40) @(posedge clk_b);
    u_src_b.send(dg_frame(d));
    begin
      int n;
      bit fin_seen;
      n = 0;
      fin_seen = 0;
      while (!fin_seen) begin
        u_sink_b.get(f, 20000, ok);
        if (!ok) begin tb_error("DUT B stream stopped"); fin_seen = 1; end
        else begin
          if (f.size() != 142) tb_error($sformatf("DUT B datagram length %0d", f.size()));
          if (is_final(f)) fin_seen = 1;
          else n++;
        end
      end
      tb_check(n >= 100 && n <= 101, $sformatf("DUT B 100-byte stream: %0d datagrams at 100 us", n));
    end
  endtask

  // ---------------------------------------------------------------------------
  // Sequence
  // ---------------------------------------------------------------------------
  initial begin
    repeat (10) @(posedge clk);
    resetn <= 1'b1;
    resetn_b <= 1'b1;
    repeat (10) @(posedge clk);
    case_registers();
    case_plain();
    case_loss();
    case_jitter();
    case_fin_rules();
    case_ignored();
    case_idle();
    case_reverse();
    case_port_clear();
    case_dut_b();
    tb_check(u_sink.frames.size() == 0, "no unchecked frame left");
    tb_check(u_busy_mon.ready_errors == 0 && u_busy_mon_b.ready_errors == 0, "s_axis_tready held 1");
    $display("tb_rtlnet_iperf: frames_from_dut_a=%0d", exp_ident);
    tb_verdict("tb_rtlnet_iperf");
  end

endmodule
