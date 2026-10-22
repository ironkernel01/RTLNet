// -----------------------------------------------------------------------------
// File: tb_rtlnet_tcp_offload.sv
// Purpose: self-checking bench for rtlnet_tcp_offload (egress checksum insert,
//   ingress checksum trailer, registers, throughput).
// Cases:
//   1. Registers: ID / VERSION / CAPS, CTRL power-up 0 and read back exactly as
//      written, STATUS idle bits, undefined offsets read 0 and ignore writes,
//      CNT_CLEAR clears every counter and reads 0.
//   2. Pass-through (CTRL = 0): random frames of every kind leave bit-exact on
//      both paths (no trailer on RX).
//   3. TX insert (IP only, L4 only, both), random frames with random garbage in
//      the checksum fields, random source gaps and sink stalls: output equals the
//      software reference (RFC 1071 sums written by the bench), every other byte
//      untouched; counters equal the reference counts.
//   4. RX checksum: random good and corrupted frames: data bytes bit-exact, the
//      final beat padded with zero bytes to 8, the trailer at roundup8(length)
//      with every field equal to the reference; counters equal the reference.
//   5. RX enable toggled during continuous traffic: each frame leaves entirely
//      as pass-through or entirely with a trailer, in step with the CTRL writes.
//   6. TX and RX traffic together with different stall patterns.
//   7. Throughput: back-to-back frames, no source gaps, no sink stalls; the
//      period between frames is measured and checked (TX: payload beats + the
//      packet FIFO idle clock; RX: payload beats + 1 trailer beat, 0 disabled).
//   8. STATUS idle falls while a frame is in flight and rises after it left.
// Reference model: parse_frame / ref_tx / ref_rx below are written from the
//   protocol rules (byte offsets, RFC 1071 inet_sum from rtlnet_tb_pkg) and share
//   no code with the RTL.
// Variants (defines): TB_TXO_BUF16 builds with TX_BUF_KB = 16 (eight slots) so
//   small frames also run at full rate; RTLNET_TECH_GENERIC the behavioural RAM.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Run: powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_tcp_offload
//        -Filelist cores/rtlnet_tcp_offload/testbench/tb_rtlnet_tcp_offload.f
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_tcp_offload;

  import rtlnet_tb_pkg::*;

`ifdef TB_TXO_BUF16
  localparam int TX_KB = 16;
`elsif TB_TXO_BUF8
  localparam int TX_KB = 8;
`else
  localparam int TX_KB = 4;
`endif

  // ---------------------------------------------------------------------------
  // Clock, reset, DUT
  // ---------------------------------------------------------------------------
  logic clk = 0;
  logic resetn = 0;
  int   cyc = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cyc <= cyc + 1;

  logic [63:0] tx_i_d, tx_o_d, rx_i_d, rx_o_d;
  logic [63:0] tx_s_d, rx_s_d;           // source data before the unused-lane junk
  logic [63:0] junk_tx = 64'h0, junk_rx = 64'h0;
  logic [7:0]  tx_i_k, tx_o_k, rx_i_k, rx_o_k;
  logic        tx_i_v, tx_i_l, tx_i_r, tx_o_v, tx_o_l, tx_o_r;
  logic        rx_i_v, rx_i_l, rx_i_r, rx_o_v, rx_o_l, rx_o_r;

  logic [11:0] awaddr, araddr;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;

  rtlnet_tcp_offload #(
    .TX_BUF_KB (TX_KB)
  ) dut (
    .clk              (clk),
    .resetn           (resetn),
    .s_axi_aclk       (clk),
    .s_axi_aresetn    (resetn),
    .s_axis_tx_tdata  (tx_i_d),
    .s_axis_tx_tkeep  (tx_i_k),
    .s_axis_tx_tvalid (tx_i_v),
    .s_axis_tx_tlast  (tx_i_l),
    .s_axis_tx_tready (tx_i_r),
    .m_axis_tx_tdata  (tx_o_d),
    .m_axis_tx_tkeep  (tx_o_k),
    .m_axis_tx_tvalid (tx_o_v),
    .m_axis_tx_tlast  (tx_o_l),
    .m_axis_tx_tready (tx_o_r),
    .s_axis_rx_tdata  (rx_i_d),
    .s_axis_rx_tkeep  (rx_i_k),
    .s_axis_rx_tvalid (rx_i_v),
    .s_axis_rx_tlast  (rx_i_l),
    .s_axis_rx_tready (rx_i_r),
    .m_axis_rx_tdata  (rx_o_d),
    .m_axis_rx_tkeep  (rx_o_k),
    .m_axis_rx_tvalid (rx_o_v),
    .m_axis_rx_tlast  (rx_o_l),
    .m_axis_rx_tready (rx_o_r),
    .s_axi_awaddr     (awaddr),
    .s_axi_awvalid    (awvalid),
    .s_axi_awready    (awready),
    .s_axi_wdata      (wdata),
    .s_axi_wstrb      (wstrb),
    .s_axi_wvalid     (wvalid),
    .s_axi_wready     (wready),
    .s_axi_bresp      (bresp),
    .s_axi_bvalid     (bvalid),
    .s_axi_bready     (bready),
    .s_axi_araddr     (araddr),
    .s_axi_arvalid    (arvalid),
    .s_axi_arready    (arready),
    .s_axi_rdata      (rdata),
    .s_axi_rresp      (rresp),
    .s_axi_rvalid     (rvalid),
    .s_axi_rready     (rready)
  );

  // Bytes beyond tkeep on the final beat carry junk: the DUT must ignore them (TX) or zero them (RX).
  function automatic logic [63:0] lane_mask(input logic [7:0] k);
    logic [63:0] m;
    for (int l = 0; l < 8; l++) m[8*l +: 8] = {8{k[l]}};
    return m;
  endfunction

  assign tx_i_d = tx_s_d | (junk_tx & ~lane_mask(tx_i_k));
  assign rx_i_d = rx_s_d | (junk_rx & ~lane_mask(rx_i_k));

  always @(posedge clk) begin
    if (!tx_i_v || tx_i_r) junk_tx <= {rnd(), rnd()};
    if (!rx_i_v || rx_i_r) junk_rx <= {rnd(), rnd()};
  end

  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(11)) u_tx_src (
    .clk(clk), .tdata(tx_s_d), .tkeep(tx_i_k), .tlast(tx_i_l), .tvalid(tx_i_v), .tready(tx_i_r));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(21), .NAME("tx_sink")) u_tx_sink (
    .clk(clk), .resetn(resetn), .tdata(tx_o_d), .tkeep(tx_o_k), .tlast(tx_o_l), .tvalid(tx_o_v), .tready(tx_o_r));
  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(31)) u_rx_src (
    .clk(clk), .tdata(rx_s_d), .tkeep(rx_i_k), .tlast(rx_i_l), .tvalid(rx_i_v), .tready(rx_i_r));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(41), .NAME("rx_sink")) u_rx_sink (
    .clk(clk), .resetn(resetn), .tdata(rx_o_d), .tkeep(rx_o_k), .tlast(rx_o_l), .tvalid(rx_o_v), .tready(rx_o_r));

  rtlnet_tb_axil_master #(.ADDR_W(12)) u_axi (
    .aclk(clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  // ---------------------------------------------------------------------------
  // Register map (mirrors rtlnet_tcp_offload.h)
  // ---------------------------------------------------------------------------
  localparam logic [11:0] R_ID = 12'h000, R_VER = 12'h004, R_CAPS = 12'h008, R_CTRL = 12'h00C,
                          R_STATUS = 12'h010, R_LAT = 12'h014, R_CLR = 12'h018, R_TX = 12'h040, R_RX = 12'h060;
  localparam int NTX = 6;
  localparam int NRX = 5;

  // ---------------------------------------------------------------------------
  // Random numbers (xorshift32, seeded, reproducible across simulators)
  // ---------------------------------------------------------------------------
  int unsigned rs = 32'h2545F491;

  function automatic int unsigned rnd();
    rs = rs ^ (rs << 13);
    rs = rs ^ (rs >> 17);
    rs = rs ^ (rs << 5);
    return rs;
  endfunction

  function automatic int rr(input int lo, input int hi);
    return lo + int'(rnd() % (hi - lo + 1));
  endfunction

  function automatic bit [7:0] rb();
    return rnd() >> 8;
  endfunction

  // ---------------------------------------------------------------------------
  // Reference model
  // ---------------------------------------------------------------------------
  typedef struct {
    bit  tag;
    bit  is_ipv4;
    bit  hdr_valid;
    bit  frag;
    bit  tcp;
    bit  udp;
    bit  l4_cand;
    bit  l4_elig;
    int  E;
    int  hl;
    int  tl;
    int  l4len;
    int  csum_off;     // frame offset of the L4 checksum field
  } info_t;

  // Classify a frame from its bytes. Frames of 32 bytes or fewer are never IPv4 (the engine needs five beats).
  function automatic info_t parse_frame(input bytes_t f);
    info_t i;
    int n;
    int ihl;
    bit et_ok;
    bit [7:0] proto;
    bit [15:0] fw;
    i.tag = 0; i.is_ipv4 = 0; i.hdr_valid = 0; i.frag = 0; i.tcp = 0; i.udp = 0; i.l4_cand = 0; i.l4_elig = 0;
    i.E = 14; i.hl = 0; i.tl = 0; i.l4len = 0; i.csum_off = 0;
    n = f.size();
    i.tag = (n >= 14) && (f[12] == 8'h81) && (f[13] == 8'h00);
    i.E = i.tag ? 18 : 14;
    if (n > 32) begin
      et_ok = i.tag ? (f[16] == 8'h08 && f[17] == 8'h00) : (f[12] == 8'h08 && f[13] == 8'h00);
      i.is_ipv4 = et_ok && (f[i.E][7:4] == 4'h4);
    end
    if (i.is_ipv4) begin
      ihl   = f[i.E][3:0];
      i.hl  = 4 * ihl;
      i.tl  = {f[i.E + 2], f[i.E + 3]};
      proto = f[i.E + 9];
      fw    = {f[i.E + 6], f[i.E + 7]};
      i.frag = ((fw & 16'h3FFF) != 16'h0000);
      i.tcp = (proto == 8'd6);
      i.udp = (proto == 8'd17);
      i.hdr_valid = (ihl >= 5) && (n >= i.E + i.hl);
      i.l4_cand = i.hdr_valid && (i.tcp || i.udp) && !i.frag;
      i.l4len = i.tl - i.hl;
      i.l4_elig = i.l4_cand && (i.tl >= i.hl) && (i.E + i.tl <= n) && (i.l4len >= (i.tcp ? 20 : 8));
      i.csum_off = i.E + i.hl + (i.tcp ? 16 : 6);
    end
    return i;
  endfunction

  // Pseudo-header followed by the segment, as one byte queue.
  function automatic bytes_t pseudo_and_segment(input bytes_t f, input info_t i);
    bytes_t q;
    for (int k = 0; k < 8; k++) q.push_back(f[i.E + 12 + k]);
    q.push_back(8'h00);
    q.push_back(i.tcp ? 8'd6 : 8'd17);
    push16(q, 16'(i.l4len));
    for (int k = i.E + i.hl; k < i.E + i.tl; k++) q.push_back(f[k]);
    return q;
  endfunction

  // Transmit reference: returns the frame as the offload must send it.
  function automatic bytes_t ref_tx(input bytes_t f, input bit ip_en, input bit l4_en,
                                    output bit d_ip, output bit d_l4, output bit d_skip, output bit d_malf);
    info_t i;
    bytes_t e;
    bytes_t ps;
    bit [15:0] c;
    i = parse_frame(f);
    e = f;
    d_ip = ip_en && i.hdr_valid;
    d_l4 = l4_en && i.l4_elig;
    d_skip = l4_en && i.hdr_valid && !i.l4_cand;
    d_malf = (ip_en || l4_en) && i.is_ipv4 && (!i.hdr_valid || (l4_en && i.l4_cand && !i.l4_elig));
    if (d_ip) begin
      e[i.E + 10] = 8'h00;
      e[i.E + 11] = 8'h00;
      c = inet_checksum(e, i.E, i.hl);
      e[i.E + 10] = c[15:8];
      e[i.E + 11] = c[7:0];
    end
    if (d_l4) begin
      ps = pseudo_and_segment(f, i);
      ps[12 + (i.tcp ? 16 : 6)]     = 8'h00;
      ps[12 + (i.tcp ? 16 : 6) + 1] = 8'h00;
      c = inet_checksum(ps, 0, ps.size());
      if (i.udp && c == 16'h0000) c = 16'hFFFF;
      e[i.csum_off]     = c[15:8];
      e[i.csum_off + 1] = c[7:0];
    end
    return e;
  endfunction

  // Receive reference: padded data plus trailer; flag outputs for the counters.
  function automatic bytes_t ref_rx(input bytes_t f, output bit d_verified, output bit d_ipbad, output bit d_l4bad,
                                    output bit d_unver);
    info_t i;
    bytes_t e;
    bytes_t ps;
    bit [15:0] sum;
    bit ip_ok, l4_ok, verified, udp_none;
    bit [15:0] field;
    bit [15:0] flags;
    int n;
    n = f.size();
    i = parse_frame(f);
    sum = 16'h0000;
    ip_ok = 0; l4_ok = 0; verified = 0; udp_none = 0;
    if (i.hdr_valid) ip_ok = (inet_sum(f, i.E, i.hl) == 16'hFFFF);
    if (i.l4_elig) begin
      ps = pseudo_and_segment(f, i);
      sum = inet_sum(ps, 0, ps.size());
      field = {f[i.csum_off], f[i.csum_off + 1]};
      udp_none = i.udp && (field == 16'h0000);
      verified = !udp_none;
      l4_ok = verified && (sum == 16'hFFFF);
    end
    verified = i.hdr_valid && i.l4_elig && verified;
    flags = 16'h0000;
    flags[0] = i.is_ipv4;
    flags[1] = i.is_ipv4 && i.tcp;
    flags[2] = i.is_ipv4 && i.udp;
    flags[3] = i.tag;
    flags[4] = i.is_ipv4 && i.frag;
    flags[5] = ip_ok;
    flags[6] = l4_ok;
    flags[7] = verified;
    e = f;
    while ((e.size() % 8) != 0) e.push_back(8'h00);
    e.push_back(n[7:0]);
    e.push_back(n[15:8]);
    e.push_back(i.l4_elig ? sum[7:0] : 8'h00);
    e.push_back(i.l4_elig ? sum[15:8] : 8'h00);
    e.push_back(flags[7:0]);
    e.push_back(flags[15:8]);
    e.push_back(i.hdr_valid ? 8'(i.E + i.hl) : 8'h00);
    e.push_back(8'hA5);
    d_verified = verified && ip_ok && l4_ok;
    d_ipbad = i.is_ipv4 && !ip_ok;
    d_l4bad = verified && !l4_ok;
    d_unver = !verified;
    return e;
  endfunction

  // ---------------------------------------------------------------------------
  // Frame generation
  // ---------------------------------------------------------------------------
  function automatic bytes_t rand_bytes(input int n);
    bytes_t q;
    for (int k = 0; k < n; k++) q.push_back(rb());
    return q;
  endfunction

  // Ethernet + IPv4 (+ options) + L4 bytes. good = write correct checksums (else random garbage).
  function automatic bytes_t build_ip(input bit tag, input bit [7:0] proto, input int ihl, input int l4len,
                                      input bit [15:0] fragw, input int tl_adj, input bit good, input bit pad_rand,
                                      input bit [3:0] ver = 4'h4);
    bytes_t q;
    bytes_t l4;
    bit [15:0] tl;
    bit d0, d1, d2, d3;
    for (int k = 0; k < 12; k++) q.push_back(rb());
    if (tag) begin
      push16(q, 16'h8100);
      push16(q, {4'h0, 12'(rr(1, 4000))});
    end
    push16(q, 16'h0800);
    l4 = rand_bytes(l4len);
    if (proto == 8'd6 && l4len >= 20) l4[12] = 8'h50;
    if (proto == 8'd17 && l4len >= 8) begin
      l4[4] = (l4len >> 8) & 8'hFF;
      l4[5] = l4len & 8'hFF;
    end
    tl = 16'(ihl * 4 + l4len + tl_adj);
    q.push_back({ver, 4'(ihl)});
    q.push_back(rb());
    push16(q, tl);
    push16(q, {rb(), rb()});
    push16(q, fragw);
    q.push_back(rb());
    q.push_back(proto);
    push16(q, {rb(), rb()});
    push32(q, {rb(), rb(), rb(), rb()});
    push32(q, {rb(), rb(), rb(), rb()});
    for (int k = 0; k < (ihl - 5) * 4; k++) q.push_back(rb());
    for (int k = 0; k < l4.size(); k++) q.push_back(l4[k]);
    if (good) q = ref_tx(q, 1'b1, 1'b1, d0, d1, d2, d3);
    while (q.size() < 60) q.push_back(pad_rand ? rb() : 8'h00);
    return q;
  endfunction

  // One random frame of a random kind.
  function automatic bytes_t gen_frame();
    int k;
    bit tg;
    bit good;
    bytes_t q;
    bytes_t c;
    int p;
    bit [15:0] fw;
    k = rr(0, 17);
    tg = (rr(0, 3) == 0);
    good = (rr(0, 2) != 0);
    case (k)
      0, 1, 2: q = build_ip(tg, 8'd6, 5, 20 + rr(0, 220), 16'h4000, 0, good, 1'b0);
      3:       q = build_ip(tg, 8'd6, rr(5, 12), 20 + rr(0, 100), 16'h0000, 0, good, 1'b1);
      4, 5:    q = build_ip(tg, 8'd17, 5, 8 + rr(0, 300), 16'h4000, 0, good, 1'b0);
      6:       q = build_ip(tg, 8'd17, rr(5, 8), 8 + 2 * rr(0, 80) + 1, 16'h0000, 0, good, 1'b1);
      7:       q = build_ip(tg, 8'd1, 5, 8 + rr(0, 100), 16'h4000, 0, good, 1'b0);
      8: begin
        for (int j = 0; j < 12; j++) q.push_back(rb());
        push16(q, 16'h0806);
        c = rand_bytes(28);
        for (int j = 0; j < 28; j++) q.push_back(c[j]);
        while (q.size() < 60) q.push_back(8'h00);
      end
      9:  begin
        fw = (rr(0, 1) == 0) ? 16'h2000 : 16'h2000 | 16'(rr(1, 100));
        q = build_ip(tg, rr(0, 1) ? 8'd6 : 8'd17, 5, 30 + rr(0, 100), fw, 0, good, 1'b0);
      end
      10: q = build_ip(tg, rr(0, 1) ? 8'd6 : 8'd17, 5, 30 + rr(0, 100), 16'(rr(1, 8000)), 0, good, 1'b0);
      11: q = build_ip(tg, 8'd17, 5, rr(0, 6), 16'h4000, 0, good, 1'b1);
      12: begin
        p = rr(0, 3);
        if (p == 0)      q = build_ip(tg, 8'd6, 5, 20 + rr(0, 60), 16'h0000, rr(1, 200), good, 1'b0);
        else if (p == 1) q = build_ip(tg, 8'd17, 5, 8 + rr(0, 60), 16'h0000, -rr(1, 8), good, 1'b0);
        else if (p == 2) q = build_ip(tg, 8'd6, 5, rr(0, 19), 16'h0000, 0, good, 1'b0);
        else             q = build_ip(tg, 8'd17, rr(5, 6), rr(0, 7), 16'h0000, 0, good, 1'b0);
      end
      13: begin
        p = rr(14, 220);
        q = rand_bytes(p);
        if (rr(0, 3) == 0) begin
          q[12] = 8'h86;
          q[13] = 8'hDD;
        end
      end
      14: begin
        p = rr(0, 2);
        if (p == 0)      q = build_ip(tg, 8'd6, rr(0, 4), 20 + rr(0, 40), 16'h0000, 0, good, 1'b0);
        else if (p == 1) q = build_ip(tg, 8'd6, 5, 20 + rr(0, 40), 16'h0000, 0, good, 1'b0, 4'h6);
        else             q = build_ip(tg, 8'd17, 5, 8 + rr(0, 40), 16'h0000, 0, good, 1'b0, 4'h5);
      end
      15: q = build_ip(tg, rr(0, 1) ? 8'd6 : 8'd17, 5, 1518 - (tg ? 18 : 14) - 20 - 0, 16'h4000, 0, good, 1'b0);
      16: begin
        q = build_ip(tg, 8'd253, 5, 0, 16'h4000, 0, good, 1'b0);
        while (q.size() > (tg ? 38 : 34)) void'(q.pop_back());
      end
      default: q = build_ip(tg, 8'd6, 5, 20 + rr(0, 700), 16'h4000, 0, good, 1'b0);
    endcase
    // Corrupt a good frame sometimes: flip one bit anywhere past the Ethernet header.
    if (good && rr(0, 3) == 0 && q.size() > 40) begin
      p = rr(14, q.size() - 1);
      q[p] = q[p] ^ (8'h01 << rr(0, 7));
    end
    // A frame must not end in the trailer marker by chance in a way that confuses the toggle test.
    if (q[q.size() - 1] == 8'hA5) q[q.size() - 1] = 8'hA4;
    return q;
  endfunction

  // ---------------------------------------------------------------------------
  // Expected counters and register helpers
  // ---------------------------------------------------------------------------
  int exp_tx [0:NTX-1];
  int exp_rx [0:NRX-1];

  task automatic clear_expected();
    for (int i = 0; i < NTX; i++) exp_tx[i] = 0;
    for (int i = 0; i < NRX; i++) exp_rx[i] = 0;
  endtask

  task automatic set_ctrl(input logic [31:0] v);
    u_axi.wr(R_CTRL, v);
  endtask

  task automatic check_counters(input string tag);
    logic [31:0] v;
    for (int i = 0; i < NTX; i++) begin
      u_axi.rd(R_TX + 12'(4 * i), v);
      tb_check(int'(v) == exp_tx[i], $sformatf("%s: TX counter %0d = %0d, expected %0d", tag, i, v, exp_tx[i]));
    end
    for (int i = 0; i < NRX; i++) begin
      u_axi.rd(R_RX + 12'(4 * i), v);
      tb_check(int'(v) == exp_rx[i], $sformatf("%s: RX counter %0d = %0d, expected %0d", tag, i, v, exp_rx[i]));
    end
  endtask

  task automatic clear_counters();
    u_axi.wr(R_CLR, 32'h1);
    clear_expected();
    repeat (8) @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Stream runners
  // ---------------------------------------------------------------------------
  // Send a list of frames through TX and compare with the reference; expected counters accumulate.
  task automatic run_tx_list(input bytes_t inq[$], input bit ip_en, input bit l4_en, input int gap, input int rdy);
    bytes_t expq[$];
    bytes_t e;
    bytes_t got;
    string  why;
    bit d_ip, d_l4, d_skip, d_malf;
    bit ok;
    int count;
    count = inq.size();
    for (int i = 0; i < count; i++) begin
      e = ref_tx(inq[i], ip_en, l4_en, d_ip, d_l4, d_skip, d_malf);
      expq.push_back(e);
      exp_tx[0]++;
      if (d_ip)   exp_tx[1]++;
      if (d_l4)   exp_tx[2]++;
      if (d_skip) exp_tx[3]++;
      if (d_malf) exp_tx[4]++;
    end
    u_tx_src.gap_pct    = gap;
    u_tx_sink.ready_pct = rdy;
    for (int i = 0; i < count; i++) u_tx_src.send(inq[i]);
    for (int i = 0; i < count; i++) begin
      u_tx_sink.get(got, 200000, ok);
      tb_check(ok, $sformatf("TX frame %0d did not arrive", i));
      if (ok) begin
        tb_check(bytes_equal(got, expq[i], why),
                 $sformatf("TX frame %0d (ip=%0d l4=%0d, %0d bytes): %s | got %s | exp %s", i, ip_en, l4_en,
                           expq[i].size(), why, hexdump(got, 100), hexdump(expq[i], 100)));
      end
    end
  endtask

  task automatic run_tx(input int count, input bit ip_en, input bit l4_en, input int gap, input int rdy);
    bytes_t inq[$];
    for (int i = 0; i < count; i++) inq.push_back(gen_frame());
    run_tx_list(inq, ip_en, l4_en, gap, rdy);
  endtask

  task automatic run_rx_list(input bytes_t inq[$], input bit en, input int gap, input int rdy);
    bytes_t expq[$];
    bytes_t e;
    bytes_t got;
    string  why;
    bit d_v, d_i, d_l, d_u;
    bit ok;
    int count;
    count = inq.size();
    for (int i = 0; i < count; i++) begin
      if (en) begin
        e = ref_rx(inq[i], d_v, d_i, d_l, d_u);
        expq.push_back(e);
        exp_rx[0]++;
        if (d_v) exp_rx[1]++;
        if (d_i) exp_rx[2]++;
        if (d_l) exp_rx[3]++;
        if (d_u) exp_rx[4]++;
      end else begin
        expq.push_back(inq[i]);
      end
    end
    u_rx_src.gap_pct    = gap;
    u_rx_sink.ready_pct = rdy;
    for (int i = 0; i < count; i++) u_rx_src.send(inq[i]);
    for (int i = 0; i < count; i++) begin
      u_rx_sink.get(got, 200000, ok);
      tb_check(ok, $sformatf("RX frame %0d did not arrive", i));
      if (ok) begin
        tb_check(bytes_equal(got, expq[i], why),
                 $sformatf("RX frame %0d (en=%0d, %0d bytes): %s | got %s | exp %s", i, en, expq[i].size(), why,
                           hexdump(got, 100), hexdump(expq[i], 100)));
      end
    end
  endtask

  task automatic run_rx(input int count, input bit en, input int gap, input int rdy);
    bytes_t inq[$];
    for (int i = 0; i < count; i++) inq.push_back(gen_frame());
    run_rx_list(inq, en, gap, rdy);
  endtask

  // Directed frames whose checksums compute to zero (UDP zero result sent as 0xFFFF, TCP zero kept,
  // IPv4 header checksum zero), and UDP frames with checksum field zero (none).
  function automatic bytes_t build_zero_sum(input bit tag, input bit udp, input bit ipzero, input int pay_words);
    bytes_t q;
    bytes_t ps;
    info_t  i;
    bit [15:0] s;
    bit [15:0] x;
    q = build_ip(tag, udp ? 8'd17 : 8'd6, 5, (udp ? 8 : 20) + 2 * pay_words, 16'h4000, 0, 1'b0, 1'b0);
    i = parse_frame(q);
    q[i.csum_off]     = 8'h00;
    q[i.csum_off + 1] = 8'h00;
    q[i.E + i.tl - 2] = 8'h00;
    q[i.E + i.tl - 1] = 8'h00;
    ps = pseudo_and_segment(q, i);
    s  = inet_sum(ps, 0, ps.size());
    x  = ~s;
    q[i.E + i.tl - 2] = x[15:8];
    q[i.E + i.tl - 1] = x[7:0];
    if (ipzero) begin
      q[i.E + 10] = 8'h00;
      q[i.E + 11] = 8'h00;
      q[i.E + 4]  = 8'h00;
      q[i.E + 5]  = 8'h00;
      s = inet_sum(q, i.E, i.hl);
      x = ~s;
      q[i.E + 4] = x[15:8];
      q[i.E + 5] = x[7:0];
    end
    return q;
  endfunction

  function automatic bytes_t build_udp_none(input bit tag, input int pay);
    bytes_t q;
    info_t  i;
    bit d0, d1, d2, d3;
    q = build_ip(tag, 8'd17, 5, 8 + pay, 16'h4000, 0, 1'b1, 1'b0);
    i = parse_frame(q);
    q[i.csum_off]     = 8'h00;
    q[i.csum_off + 1] = 8'h00;
    return q;
  endfunction

  // ---------------------------------------------------------------------------
  // Output monitors for the throughput cases
  // ---------------------------------------------------------------------------
  int tx_first_t [$];
  int rx_first_t [$];
  bit tx_mon_first = 1'b1;
  bit rx_mon_first = 1'b1;

  always @(posedge clk) begin
    if (resetn) begin
      if (tx_o_v && tx_o_r) begin
        if (tx_mon_first) tx_first_t.push_back(cyc);
        tx_mon_first <= tx_o_l;
      end
      if (rx_o_v && rx_o_r) begin
        if (rx_mon_first) rx_first_t.push_back(cyc);
        rx_mon_first <= rx_o_l;
      end
    end
  end

  // Average period between first beats over the middle of a burst.
  function automatic real avg_period(input int t [$]);
    int n;
    n = t.size();
    if (n < 6) return 0.0;
    return real'(t[n - 2] - t[2]) / real'(n - 4);
  endfunction

  function automatic int max_period(input int t [$]);
    int m;
    m = 0;
    for (int i = 3; i < t.size() - 1; i++) if (t[i + 1] - t[i] > m) m = t[i + 1] - t[i];
    return m;
  endfunction

  task automatic burst_tx(input int count, input int bytes_n, output real period);
    bytes_t f;
    bytes_t got;
    bit ok;
    bit d_ip, d_l4, d_skip, d_malf;
    tx_first_t = {};
    u_tx_src.gap_pct = 0;
    u_tx_sink.ready_pct = 100;
    f = build_ip(1'b0, 8'd6, 5, bytes_n - 14 - 20, 16'h4000, 0, 1'b0, 1'b0);
    for (int i = 0; i < count; i++) u_tx_src.send(f);
    for (int i = 0; i < count; i++) begin
      u_tx_sink.get(got, 200000, ok);
      tb_check(ok, "burst TX frame missing");
    end
    period = avg_period(tx_first_t);
    exp_tx[0] += count;
    if (f.size() > 0) begin
      bit a, b, c, d;
      void'(ref_tx(f, 1'b1, 1'b1, a, b, c, d));
      if (a) exp_tx[1] += count;
      if (b) exp_tx[2] += count;
    end
  endtask

  task automatic burst_rx(input int count, input int bytes_n, input bit en, output real period);
    bytes_t f;
    bytes_t got;
    bit ok;
    bit v, i, l, u;
    rx_first_t = {};
    u_rx_src.gap_pct = 0;
    u_rx_sink.ready_pct = 100;
    f = build_ip(1'b0, 8'd17, 5, bytes_n - 14 - 20, 16'h4000, 0, 1'b1, 1'b0);
    for (int k = 0; k < count; k++) u_rx_src.send(f);
    for (int k = 0; k < count; k++) begin
      u_rx_sink.get(got, 200000, ok);
      tb_check(ok, "burst RX frame missing");
    end
    period = avg_period(rx_first_t);
    if (en) begin
      void'(ref_rx(f, v, i, l, u));
      exp_rx[0] += count;
      if (v) exp_rx[1] += count;
      if (i) exp_rx[2] += count;
      if (l) exp_rx[3] += count;
      if (u) exp_rx[4] += count;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  logic [31:0] rv;
  real         per;

  initial begin
    #2_000_000_000;
    tb_error("watchdog timeout");
    tb_verdict("tb_rtlnet_tcp_offload");
  end

  initial begin
    clear_expected();
    resetn = 1'b0;
    repeat (20) @(posedge clk);
    resetn <= 1'b1;
    repeat (20) @(posedge clk);

    // ---- 1. Registers -------------------------------------------------------
    u_axi.rd(R_ID, rv);
    tb_check(rv == 32'h5443504F, $sformatf("ID = %08x", rv));
    u_axi.rd(R_VER, rv);
    tb_check(rv == 32'h10222026, $sformatf("VERSION = %08x", rv));
    u_axi.rd(R_CAPS, rv);
    tb_check(rv[5:0] == 6'h3F, $sformatf("CAPS present/insert bits = %02x", rv[5:0]));
    tb_check(rv[15:8] == 8'(TX_KB), $sformatf("CAPS TX_BUF_KB = %0d", rv[15:8]));
    tb_check(rv[26:16] == 11'd1518, $sformatf("CAPS max frame = %0d", rv[26:16]));
    u_axi.rd(R_CTRL, rv);
    tb_check(rv == 32'h0, $sformatf("CTRL power-up = %08x", rv));
    u_axi.rd(R_STATUS, rv);
    tb_check(rv == 32'h3, $sformatf("STATUS idle bits at start = %08x", rv));
    u_axi.rd(R_LAT, rv);
    tb_check(rv[7:0] == 8'd18 && rv[15:8] == 8'd17, $sformatf("LATENCY = %08x", rv));
    for (int v = 0; v < 8; v++) begin
      set_ctrl(32'(v));
      u_axi.rd(R_CTRL, rv);
      tb_check(rv == 32'(v), $sformatf("CTRL write %0d read back %08x", v, rv));
    end
    set_ctrl(32'hFFFF_FFFF);
    u_axi.rd(R_CTRL, rv);
    tb_check(rv == 32'h7, $sformatf("CTRL implemented bits only: %08x", rv));
    set_ctrl(32'h0);
    u_axi.wr(12'h0F0, 32'hDEAD_BEEF);
    u_axi.rd(12'h0F0, rv);
    tb_check(rv == 32'h0, "undefined offset 0x0F0 reads 0");
    u_axi.rd(12'h074, rv);
    tb_check(rv == 32'h0, "undefined offset 0x074 reads 0");
    u_axi.rd(R_CLR, rv);
    tb_check(rv == 32'h0, "CNT_CLEAR reads 0");
    u_axi.wr(R_ID, 32'h1234);
    u_axi.rd(R_ID, rv);
    tb_check(rv == 32'h5443504F, "ID is read-only");

    // ---- 2. Pass-through (CTRL = 0) -----------------------------------------
    clear_counters();
    run_tx(60, 1'b0, 1'b0, 0, 100);
    run_rx(60, 1'b0, 0, 100);
    run_tx(40, 1'b0, 1'b0, 40, 50);
    run_rx(40, 1'b0, 40, 50);
    check_counters("pass-through");

    // ---- 3. TX insert ---------------------------------------------------------
    clear_counters();
    set_ctrl(32'h1);
    run_tx(80, 1'b1, 1'b0, 0, 100);
    run_tx(60, 1'b1, 1'b0, 30, 60);
    check_counters("tx ip only");
    clear_counters();
    set_ctrl(32'h2);
    run_tx(80, 1'b0, 1'b1, 0, 100);
    run_tx(60, 1'b0, 1'b1, 30, 60);
    check_counters("tx l4 only");
    clear_counters();
    set_ctrl(32'h3);
    run_tx(150, 1'b1, 1'b1, 0, 100);
    run_tx(100, 1'b1, 1'b1, 25, 70);
    run_tx(60, 1'b1, 1'b1, 60, 30);
    check_counters("tx both");
    set_ctrl(32'h0);

    // ---- 3b. Directed: checksums that compute to zero --------------------------
    begin
      bytes_t dq[$];
      for (int t = 0; t < 2; t++)
        for (int u = 0; u < 2; u++)
          for (int z = 0; z < 2; z++) dq.push_back(build_zero_sum(t == 1, u == 1, z == 1, 12 + 7 * (t + u + z)));
      clear_counters();
      set_ctrl(32'h3);
      run_tx_list(dq, 1'b1, 1'b1, 0, 100);
      check_counters("tx zero sums");
      set_ctrl(32'h4);
      run_rx_list(dq, 1'b1, 0, 100);
      check_counters("rx zero sums");
      dq = {};
      dq.push_back(build_udp_none(1'b0, 31));
      dq.push_back(build_udp_none(1'b1, 4));
      dq.push_back(build_udp_none(1'b0, 0));
      run_rx_list(dq, 1'b1, 0, 100);
      check_counters("rx udp none");
      set_ctrl(32'h0);
    end

    // ---- 4. RX checksum ---------------------------------------------------------
    clear_counters();
    set_ctrl(32'h4);
    run_rx(150, 1'b1, 0, 100);
    run_rx(100, 1'b1, 25, 70);
    run_rx(60, 1'b1, 60, 30);
    check_counters("rx");
    set_ctrl(32'h0);

    // ---- 5. RX enable toggled during traffic ----------------------------------
    begin
      bytes_t inq[$];
      bytes_t got;
      bytes_t pt;
      bytes_t tr;
      bit ok;
      bit d_v, d_i, d_l, d_u;
      bit is_pt;
      bit is_tr;
      int last_form;
      int changes;
      int n_pt;
      int n_tr;
      string why;
      clear_counters();
      u_rx_src.gap_pct = 20;
      u_rx_sink.ready_pct = 80;
      for (int i = 0; i < 120; i++) inq.push_back(gen_frame());
      set_ctrl(32'h0);
      fork
        begin
          for (int i = 0; i < 120; i++) u_rx_src.send(inq[i]);
        end
        begin
          repeat (400)  @(posedge clk);
          set_ctrl(32'h4);
          repeat (700)  @(posedge clk);
          set_ctrl(32'h0);
          repeat (500)  @(posedge clk);
          set_ctrl(32'h4);
          repeat (300)  @(posedge clk);
          set_ctrl(32'h0);
        end
      join
      last_form = -1;
      changes = 0;
      n_pt = 0;
      n_tr = 0;
      for (int i = 0; i < 120; i++) begin
        u_rx_sink.get(got, 200000, ok);
        tb_check(ok, $sformatf("toggle frame %0d missing", i));
        if (ok) begin
          pt = inq[i];
          tr = ref_rx(inq[i], d_v, d_i, d_l, d_u);
          is_pt = bytes_equal(got, pt, why);
          is_tr = bytes_equal(got, tr, why);
          tb_check(is_pt || is_tr, $sformatf("toggle frame %0d is neither pass-through nor trailer form (%0d bytes)", i, got.size()));
          if (is_tr && !is_pt) begin
            n_tr++;
            if (last_form != 1) changes++;
            last_form = 1;
            exp_rx[0]++;
            if (d_v) exp_rx[1]++;
            if (d_i) exp_rx[2]++;
            if (d_l) exp_rx[3]++;
            if (d_u) exp_rx[4]++;
          end else begin
            n_pt++;
            if (last_form != 0) changes++;
            last_form = 0;
          end
        end
      end
      tb_check(n_pt > 0 && n_tr > 0, $sformatf("toggle test saw pass-through %0d and trailer %0d frames", n_pt, n_tr));
      tb_check(changes <= 5, $sformatf("form changes %0d exceed the 4 CTRL writes (plus the start)", changes));
      repeat (40) @(posedge clk);
      check_counters("rx toggle");
    end

    // ---- 6. TX and RX together --------------------------------------------------
    clear_counters();
    set_ctrl(32'h7);
    fork
      run_tx(80, 1'b1, 1'b1, 35, 65);
      run_rx(80, 1'b1, 10, 90);
    join
    check_counters("tx+rx together");
    set_ctrl(32'h0);

    // ---- 7. Throughput ----------------------------------------------------------
    clear_counters();
    set_ctrl(32'h7);
    burst_tx(14, 1514, per);
    $display("TXO THROUGHPUT tx 1514 bytes: period %f clocks (190 beats)", per);
`ifdef TB_TXO_BUF16
    tb_check(per > 190.0 && per <= 192.1, $sformatf("TX 1514-byte period %f, expected 191", per));
`elsif TB_TXO_BUF8
    tb_check(per > 190.0 && per <= 192.1, $sformatf("TX 1514-byte period %f, expected 191", per));
`else
    tb_check(per > 190.0 && per <= 202.0, $sformatf("TX 1514-byte period %f, expected about 200 with two slots", per));
`endif
    burst_tx(40, 64, per);
    $display("TXO THROUGHPUT tx 64 bytes, TX_BUF_KB %0d: period %f clocks (8 beats)", TX_KB, per);
`ifdef TB_TXO_BUF16
    tb_check(per <= 10.1, $sformatf("TX 64-byte period %f exceeds 10 with eight slots", per));
`endif
    burst_rx(14, 1514, 1'b1, per);
    $display("TXO THROUGHPUT rx 1514 bytes enabled: period %f clocks (190 beats + trailer)", per);
    tb_check(per > 190.9 && per < 191.1, $sformatf("RX 1514-byte period %f, expected 191", per));
    tb_check(max_period(rx_first_t) == 191, $sformatf("RX 1514-byte max period %0d", max_period(rx_first_t)));
    burst_rx(40, 64, 1'b1, per);
    $display("TXO THROUGHPUT rx 64 bytes enabled: period %f clocks (8 beats + trailer)", per);
    tb_check(per > 8.9 && per < 9.1, $sformatf("RX 64-byte period %f, expected 9", per));
    tb_check(max_period(rx_first_t) == 9, $sformatf("RX 64-byte max period %0d", max_period(rx_first_t)));
    check_counters("throughput");
    set_ctrl(32'h0);
    burst_rx(40, 64, 1'b0, per);
    $display("TXO THROUGHPUT rx 64 bytes disabled: period %f clocks (8 beats)", per);
    tb_check(per > 7.9 && per < 8.1, $sformatf("RX 64-byte disabled period %f, expected 8", per));
    burst_rx(14, 1514, 1'b0, per);
    tb_check(per > 189.9 && per < 190.1, $sformatf("RX 1514-byte disabled period %f, expected 190", per));

    // ---- 8. STATUS idle ---------------------------------------------------------
    begin
      bytes_t f;
      bytes_t got;
      bit ok;
      logic [31:0] st_busy;
      logic [31:0] st_idle;
      set_ctrl(32'h7);
      f = build_ip(1'b0, 8'd6, 5, 1400, 16'h4000, 0, 1'b0, 1'b0);
      fork
        begin
          u_tx_src.gap_pct = 0;
          u_tx_sink.ready_pct = 100;
          u_tx_src.send(f);
        end
        begin
          repeat (30) @(posedge clk);
          u_axi.rd(R_STATUS, st_busy);
        end
      join
      tb_check(st_busy[0] == 1'b0, $sformatf("STATUS tx_idle falls while a frame is in flight: %08x", st_busy));
      u_tx_sink.get(got, 200000, ok);
      tb_check(ok, "idle test frame missing");
      repeat (60) @(posedge clk);
      u_axi.rd(R_STATUS, st_idle);
      tb_check(st_idle[1:0] == 2'b11, $sformatf("STATUS idle bits after drain: %08x", st_idle));
      set_ctrl(32'h0);
    end

    repeat (50) @(posedge clk);
    tb_verdict("tb_rtlnet_tcp_offload");
  end

endmodule
