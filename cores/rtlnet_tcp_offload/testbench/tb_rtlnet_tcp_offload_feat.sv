// -----------------------------------------------------------------------------
// File: tb_rtlnet_tcp_offload_feat.sv
// Purpose: self-checking bench for the two optional receive features of rtlnet_tcp_offload: ACK coalescing
//   (ACK_COALESCE) and receive batching (RX_BATCH), alone and together, plus the built-but-disabled case.
// Variants (defines): TB_FEAT_ACK builds ACK_COALESCE only, TB_FEAT_BATCH RX_BATCH only, default both.
// Cases:
//   R   registers: CAPS / CAPS2 bits, defaults, read-back, counters clear, CTRL bits of the feature.
//   P   built but disabled: random frames leave exactly as the plain core (trailer, one frame per transfer);
//       with rx_csum off the frames leave bit-exact without trailer even with the feature bits set.
//   A   ACK coalescing, directed (variants with ACK_COALESCE): coalesced run, timestamp option, duplicate ACKs,
//       window updates, older ACK, lower sequence (keep-alive shape), SACK / MSS / odd option layout, every flag
//       combination, payload segments (short and long), bad checksum, fragment, IP options, VLAN, interleaved
//       flows, table eviction, ordering against data of the same flow, frames of other flows not delayed, timer
//       flush with measured latency, count limit, sequence-number wrap, disable flushes, counters and the
//       invariant candidates = dropped + forwarded.
//   AR  ACK coalescing, random: 5 flows over a 4-entry table, thousands of mixed frames with random source gaps and
//       sink stalls; the output order and every counter equal a bench model written from the rules
//       (timer huge: only arrival order decides).
//   B   batching, directed (variants with RX_BATCH): single frame leaves after the timer, count limit, byte limit,
//       exact fit, maximum frames, back-to-back batches, close on disable, frame without trailer, minimum and
//       maximum sizes, trailer contents, backpressure.
//   AB  both features: random model run; frames recovered from the transfers by a backward walk equal the model.
// Reference: parse_frame / ref_rx are the checksum model of tb_rtlnet_tcp_offload (shares no code with the RTL);
//   the coalescing model below is written from the rules of the document.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-14-2026
//   * 11-14-2026: initial version.
// Run: powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_tcp_offload_feat
//        -Filelist cores/rtlnet_tcp_offload/testbench/tb_rtlnet_tcp_offload_feat.f
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_tcp_offload_feat;

  import rtlnet_tb_pkg::*;

`ifdef TB_FEAT_ACK
  localparam int F_ACK = 1;
  localparam int F_BAT = 0;
`elsif TB_FEAT_BATCH
  localparam int F_ACK = 0;
  localparam int F_BAT = 1;
`else
  localparam int F_ACK = 1;
  localparam int F_BAT = 1;
`endif
  localparam int FLOWS      = 4;
  localparam int MAXF       = 2048;
  localparam int TICK       = 10;                 // clocks per microsecond of the DUT (CLK_HZ = 10 MHz)
  localparam int RESERVE_B  = MAXF + 8;           // bytes a batch keeps free for the next frame

  // ---------------------------------------------------------------------------
  // Clock, reset, DUT
  // ---------------------------------------------------------------------------
  logic clk = 0;
  logic resetn = 0;
  int   cyc = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cyc <= cyc + 1;

  logic [63:0] rx_i_d, rx_o_d, rx_s_d;
  logic [63:0] junk_rx = 64'h0;
  logic [7:0]  rx_i_k, rx_o_k;
  logic        rx_i_v, rx_i_l, rx_i_r, rx_o_v, rx_o_l, rx_o_r;

  logic [11:0] awaddr, araddr;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;

  rtlnet_tcp_offload #(
    .ACK_COALESCE (F_ACK),
    .ACK_FLOWS    (FLOWS),
    .RX_BATCH     (F_BAT),
    .CLK_HZ       (10_000_000)
  ) dut (
    .clk              (clk),
    .resetn           (resetn),
    .s_axi_aclk       (clk),
    .s_axi_aresetn    (resetn),
    .s_axis_tx_tdata  (64'h0),
    .s_axis_tx_tkeep  (8'h00),
    .s_axis_tx_tvalid (1'b0),
    .s_axis_tx_tlast  (1'b0),
    .s_axis_tx_tready (),
    .m_axis_tx_tdata  (),
    .m_axis_tx_tkeep  (),
    .m_axis_tx_tvalid (),
    .m_axis_tx_tlast  (),
    .m_axis_tx_tready (1'b1),
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

  // Bytes beyond tkeep on the final beat carry junk: the DUT must zero them.
  function automatic logic [63:0] lane_mask(input logic [7:0] k);
    logic [63:0] m;
    for (int l = 0; l < 8; l++) m[8*l +: 8] = {8{k[l]}};
    return m;
  endfunction

  assign rx_i_d = rx_s_d | (junk_rx & ~lane_mask(rx_i_k));

  always @(posedge clk) begin
    if (!rx_i_v || rx_i_r) junk_rx <= {$urandom(), $urandom()};
  end

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
                          R_STATUS = 12'h010, R_CLR = 12'h018, R_CAPS2 = 12'h01C,
                          R_ACK_TIMER = 12'h020, R_ACK_LIMIT = 12'h024, R_BAT_TIMER = 12'h028,
                          R_BAT_FRAMES = 12'h02C, R_BAT_BYTES = 12'h030, R_RX = 12'h060,
                          R_CNT_ACK = 12'h080, R_CNT_BAT = 12'h0A0;
  localparam logic [31:0] C_RX = 32'h4, C_ACK = 32'h8, C_BAT = 32'h10;

  // ---------------------------------------------------------------------------
  // Timing monitors: last input beat accepted, first output beat of each transfer
  // ---------------------------------------------------------------------------
  int t_in_last = 0;
  int t_out_first[$];
  int t_out_last[$];
  bit o_mid = 1'b0;

  always @(posedge clk) begin
    if (rx_i_v && rx_i_r && rx_i_l) t_in_last <= cyc;
    if (rx_o_v && rx_o_r) begin
      if (!o_mid) t_out_first.push_back(cyc);
      o_mid <= !rx_o_l;
      if (rx_o_l) t_out_last.push_back(cyc);
    end
  end

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
  // ---------------------------------------------------------------------------
  // Frame builders
  // ---------------------------------------------------------------------------
  function automatic bytes_t rand_bytes(input int n);
    bytes_t q;
    for (int k = 0; k < n; k++) q.push_back(rb());
    return q;
  endfunction

  // Ethernet / IPv4 / TCP frame. flow selects the 4-tuple, flags[8] is the NS bit, optmode: 0 none, 1 NOP NOP
  // timestamp, 2 NOP NOP SACK block, 3 MSS, 5 timestamp then NOP NOP (not the allow-listed order). badmask bit 0 =
  // bad TCP checksum, bit 1 = bad IPv4 header checksum. ihl 6 adds four IP option bytes.
  function automatic bytes_t build_tcp(input int flow, input bit [31:0] seq, input bit [31:0] ack,
                                       input bit [8:0] flags, input bit [15:0] win, input int paylen,
                                       input int optmode, input int badmask, input int ihl,
                                       input bit [15:0] fragw, input bit vlan);
    bytes_t q;
    bytes_t tcp;
    bytes_t opts;
    bytes_t iph;
    bytes_t pseudo;
    bit [31:0] sip;
    bit [31:0] dip;
    bit [15:0] sport;
    bit [15:0] dport;
    bit [15:0] tl;
    bit [15:0] c;
    int do_w;
    sip = 32'h0A000100 + 32'(flow);
    dip = 32'h0A0001FE;
    sport = 16'(5000 + flow);
    dport = 16'd80;
    case (optmode)
      1: begin
        opts.push_back(8'h01); opts.push_back(8'h01); opts.push_back(8'h08); opts.push_back(8'h0A);
        push32(opts, ack ^ 32'h00001234); push32(opts, seq ^ 32'h00005678);
      end
      2: begin
        opts.push_back(8'h01); opts.push_back(8'h01); opts.push_back(8'h05); opts.push_back(8'h0A);
        push32(opts, ack + 32'd100); push32(opts, ack + 32'd200);
      end
      3: begin
        opts.push_back(8'h02); opts.push_back(8'h04); opts.push_back(8'h05); opts.push_back(8'hB4);
      end
      5: begin
        opts.push_back(8'h08); opts.push_back(8'h0A); push32(opts, ack ^ 32'h00001234); push32(opts, seq ^ 32'h00005678);
        opts.push_back(8'h01); opts.push_back(8'h01);
      end
      default: ;
    endcase
    do_w = 5 + opts.size() / 4;
    push16(tcp, sport); push16(tcp, dport); push32(tcp, seq); push32(tcp, ack);
    tcp.push_back({4'(do_w), 3'b000, flags[8]});
    tcp.push_back(flags[7:0]);
    push16(tcp, win); push16(tcp, 16'h0000); push16(tcp, 16'h0000);
    for (int k = 0; k < opts.size(); k++) tcp.push_back(opts[k]);
    for (int k = 0; k < paylen; k++) tcp.push_back(rb());
    // TCP checksum over the pseudo header and the segment.
    push32(pseudo, sip); push32(pseudo, dip); pseudo.push_back(8'h00); pseudo.push_back(8'd6);
    push16(pseudo, 16'(tcp.size()));
    for (int k = 0; k < tcp.size(); k++) pseudo.push_back(tcp[k]);
    c = inet_checksum(pseudo, 0, pseudo.size());
    if (badmask & 1) c = c ^ 16'h0100;
    tcp[16] = c[15:8];
    tcp[17] = c[7:0];
    // IPv4 header.
    tl = 16'(4 * ihl + tcp.size());
    iph.push_back({4'h4, 4'(ihl)}); iph.push_back(8'h00); push16(iph, tl); push16(iph, 16'h1234);
    push16(iph, fragw); iph.push_back(8'd64); iph.push_back(8'd6); push16(iph, 16'h0000);
    push32(iph, sip); push32(iph, dip);
    if (ihl == 6) begin
      iph.push_back(8'h01); iph.push_back(8'h01); iph.push_back(8'h01); iph.push_back(8'h00);
    end
    c = inet_checksum(iph, 0, iph.size());
    if (badmask & 2) c = c ^ 16'h0001;
    iph[10] = c[15:8];
    iph[11] = c[7:0];
    push48(q, 48'h02AABBCCDD01);
    push48(q, 48'h02AABBCCDD10 + 48'(flow));
    if (vlan) begin
      push16(q, 16'h8100);
      push16(q, 16'h0064);
    end
    push16(q, 16'h0800);
    for (int k = 0; k < iph.size(); k++) q.push_back(iph[k]);
    for (int k = 0; k < tcp.size(); k++) q.push_back(tcp[k]);
    while (q.size() < 60) q.push_back(8'h00);
    return q;
  endfunction

  // Pure ACK of a flow (peer to board direction).
  function automatic bytes_t ack_f(input int flow, input bit [31:0] seq, input bit [31:0] ack, input bit [15:0] win,
                                   input int ts);
    return build_tcp(flow, seq, ack, 9'h010, win, 0, ts, 0, 5, 16'h4000, 1'b0);
  endfunction

  function automatic bytes_t arp_f();
    bytes_t q;
    bytes_t c;
    for (int j = 0; j < 12; j++) q.push_back(rb());
    push16(q, 16'h0806);
    c = rand_bytes(28);
    for (int j = 0; j < 28; j++) q.push_back(c[j]);
    while (q.size() < 60) q.push_back(8'h00);
    return q;
  endfunction

  function automatic bytes_t udp_f(input int n);
    return udp_frame(48'h02AABBCCDD01, 48'h02AABBCCDD77, 32'h0A000201, 32'h0A0001FE, 16'd4000, 16'd5000,
                     rand_bytes(n), 16'h0007, 1'b1);
  endfunction

  // Expected output of the plain receive path for one input frame (frame, padding, trailer).
  function automatic bytes_t ex(input bytes_t f);
    bit a, b, c, d;
    return ref_rx(f, a, b, c, d);
  endfunction

  // ---------------------------------------------------------------------------
  // Walk one DMA transfer backwards: trailers give the frame boundaries (independent of the RTL / driver).
  // ---------------------------------------------------------------------------
  task automatic walk(input bytes_t t, output bytes_t fr[$], output bit ok, output string why);
    int pos;
    int len;
    int plen;
    int start;
    bytes_t one;
    fr = {};
    ok = 1'b1;
    why = "";
    pos = t.size();
    while (pos > 0 && ok) begin
      if (pos < 16 || (pos % 8) != 0) begin
        ok = 1'b0;
        why = $sformatf("transfer of %0d bytes, remaining %0d", t.size(), pos);
      end else if (t[pos - 1] != 8'hA5) begin
        ok = 1'b0;
        why = $sformatf("no trailer marker at %0d", pos - 1);
      end else begin
        len = {t[pos - 7], t[pos - 8]};
        plen = (len + 7) / 8 * 8;
        if (len == 0 || pos < plen + 8) begin
          ok = 1'b0;
          why = $sformatf("bad length %0d at %0d", len, pos);
        end else begin
          start = pos - 8 - plen;
          one = {};
          for (int k = start; k < pos; k++) one.push_back(t[k]);
          fr.push_front(one);
          pos = start;
        end
      end
    end
  endtask

  // Everything the sink holds, as frames; per-transfer byte and frame counts. Clears the sink queue.
  int tr_bytes[$];
  int tr_frames[$];

  task automatic collect_frames(output bytes_t fr[$]);
    bytes_t t;
    bytes_t w[$];
    bit ok;
    string why;
    fr = {};
    tr_bytes = {};
    tr_frames = {};
    while (u_rx_sink.frames.size() != 0) begin
      t = u_rx_sink.frames.pop_front();
      walk(t, w, ok, why);
      tb_check(ok, $sformatf("transfer %0d does not walk: %s", tr_bytes.size(), why));
      tr_bytes.push_back(t.size());
      tr_frames.push_back(w.size());
      for (int j = 0; j < w.size(); j++) fr.push_back(w[j]);
    end
  endtask

  task automatic cmp_frames(input string tag, input bytes_t got[$], input bytes_t exp[$]);
    string why;
    tb_check(got.size() == exp.size(), $sformatf("%s: %0d frames out, expected %0d", tag, got.size(), exp.size()));
    for (int i = 0; i < exp.size() && i < got.size(); i++) begin
      tb_check(bytes_equal(got[i], exp[i], why), $sformatf("%s: frame %0d: %s", tag, i, why));
    end
  endtask

  // ---------------------------------------------------------------------------
  // Register helpers and settling
  // ---------------------------------------------------------------------------
  int cnt_a [0:5];
  int cnt_b [0:5];

  task automatic set_ctrl(input logic [31:0] v);
    u_axi.wr(R_CTRL, v);
    repeat (30) @(posedge clk);
  endtask

  task automatic wr_reg(input logic [11:0] a, input logic [31:0] v);
    u_axi.wr(a, v);
    repeat (12) @(posedge clk);
  endtask

  task automatic read_cnt();
    logic [31:0] v;
    for (int i = 0; i < 6; i++) begin
      u_axi.rd(R_CNT_ACK + 12'(4 * i), v);
      cnt_a[i] = int'(v);
      u_axi.rd(R_CNT_BAT + 12'(4 * i), v);
      cnt_b[i] = int'(v);
    end
  endtask

  task automatic clear_cnt();
    u_axi.wr(R_CLR, 32'h1);
    repeat (12) @(posedge clk);
  endtask

  task automatic chk_ack(input string tag, input int c, input int d, input int f, input int t, input int l, input int o);
    read_cnt();
    tb_check(cnt_a[0] == c, $sformatf("%s: ACK candidates %0d, expected %0d", tag, cnt_a[0], c));
    tb_check(cnt_a[1] == d, $sformatf("%s: ACK dropped %0d, expected %0d", tag, cnt_a[1], d));
    tb_check(cnt_a[2] == f, $sformatf("%s: ACK forwarded %0d, expected %0d", tag, cnt_a[2], f));
    tb_check(cnt_a[3] == t, $sformatf("%s: flush by timer %0d, expected %0d", tag, cnt_a[3], t));
    tb_check(cnt_a[4] == l, $sformatf("%s: flush by limit %0d, expected %0d", tag, cnt_a[4], l));
    tb_check(cnt_a[5] == o, $sformatf("%s: flush by ordering %0d, expected %0d", tag, cnt_a[5], o));
    tb_check(cnt_a[0] == cnt_a[1] + cnt_a[2], $sformatf("%s: candidates %0d != dropped %0d + forwarded %0d", tag,
                                                        cnt_a[0], cnt_a[1], cnt_a[2]));
  endtask

  task automatic chk_bat(input string tag, input int b, input int f, input int cb, input int cc, input int ct, input int co);
    read_cnt();
    tb_check(cnt_b[0] == b, $sformatf("%s: batches %0d, expected %0d", tag, cnt_b[0], b));
    tb_check(cnt_b[1] == f, $sformatf("%s: batched frames %0d, expected %0d", tag, cnt_b[1], f));
    tb_check(cnt_b[2] == cb, $sformatf("%s: closes by bytes %0d, expected %0d", tag, cnt_b[2], cb));
    tb_check(cnt_b[3] == cc, $sformatf("%s: closes by count %0d, expected %0d", tag, cnt_b[3], cc));
    tb_check(cnt_b[4] == ct, $sformatf("%s: closes by timer %0d, expected %0d", tag, cnt_b[4], ct));
    tb_check(cnt_b[5] == co, $sformatf("%s: closes other %0d, expected %0d", tag, cnt_b[5], co));
    tb_check(cnt_b[0] == cnt_b[2] + cnt_b[3] + cnt_b[4] + cnt_b[5], $sformatf("%s: batches %0d != sum of closes", tag, cnt_b[0]));
  endtask

  // Wait until every built block reports idle three times in a row with the output quiet.
  task automatic wait_idle();
    logic [31:0] st;
    logic [31:0] mask;
    int ok_cnt;
    mask = 32'h3 | ((F_ACK != 0) ? 32'h4 : 32'h0) | ((F_BAT != 0) ? 32'h8 : 32'h0);
    ok_cnt = 0;
    for (int n = 0; n < 40000 && ok_cnt < 3; n++) begin
      u_axi.rd(R_STATUS, st);
      if ((st & mask) == mask && !rx_o_v) ok_cnt++;
      else ok_cnt = 0;
      repeat (4) @(posedge clk);
    end
    tb_check(ok_cnt >= 3, "core did not become idle");
    repeat (20) @(posedge clk);
  endtask

  // Send a list of frames with the given source gap and sink ready percentages.
  task automatic send_list(input bytes_t inq[$], input int gap, input int rdy);
    u_rx_src.gap_pct = gap;
    u_rx_sink.ready_pct = rdy;
    for (int i = 0; i < inq.size(); i++) u_rx_src.send(inq[i]);
  endtask

  // Wait until the sink has not received a new transfer for 'quiet' clocks.
  task automatic settle(input int quiet);
    int last;
    int n;
    last = -1;
    n = 0;
    while (n < 40) begin
      if (u_rx_sink.frames.size() != last) begin
        last = u_rx_sink.frames.size();
        repeat (quiet) @(posedge clk);
        n++;
      end else n = 100;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Coalescing model, written from the rules of the document
  // ---------------------------------------------------------------------------
  typedef struct {
    bit        cand;
    bit        keyok;
    bit        flushall;
    bit [95:0] key;
    bit [31:0] seq;
    bit [31:0] ack;
  } mi_t;

  typedef struct {
    bit        v;
    bit [95:0] key;
    bit        held;
    int        hidx;
    bit [31:0] hack;
    bit [31:0] hseq;
    int        hcnt;
    bit        lv;
    bit [31:0] lack;
    int        rank;
  } mfl_t;

  mfl_t mf [0:FLOWS-1];
  int   mout [$];
  int   m_c, m_d, m_f, m_t, m_l, m_o;
  int   m_limit = 8;

  function automatic byte unsigned at(input bytes_t f, input int k);
    return (k < f.size()) ? f[k] : 8'h00;
  endfunction

  function automatic bit sgt(input bit [31:0] a, input bit [31:0] b);
    int signed d;
    d = $signed(a - b);
    return d > 0;
  endfunction

  function automatic mi_t model_parse(input bytes_t f);
    mi_t m;
    bytes_t e;
    bit dv, di, dl, du;
    bit [15:0] fl;
    bit [15:0] tl;
    bit et_ok, vlan, ihl45, tcp, fragfree, shape, short;
    bit [7:0] doff;
    bit [7:0] flg;
    int n;
    n = f.size();
    e = ref_rx(f, dv, di, dl, du);
    fl = {e[e.size() - 3], e[e.size() - 4]};
    et_ok = (at(f, 12) == 8'h08) && (at(f, 13) == 8'h00);
    vlan = (at(f, 12) == 8'h81) && (at(f, 13) == 8'h00);
    ihl45 = (at(f, 14) == 8'h45);
    tcp = (at(f, 23) == 8'd6);
    fragfree = (({at(f, 20), at(f, 21)} & 16'h3FFF) == 16'h0000);
    tl = {at(f, 16), at(f, 17)};
    doff = at(f, 46);
    flg = at(f, 47);
    shape = et_ok && ihl45 && tcp && fragfree && (flg == 8'h10) &&
            (((doff == 8'h50) && (tl == 16'd40)) ||
             ((doff == 8'h80) && (tl == 16'd52) && at(f, 54) == 8'h01 && at(f, 55) == 8'h01 && at(f, 56) == 8'h08 &&
              at(f, 57) == 8'h0A));
    short = ((n + 7) / 8 + 1) <= 10;
    m.cand = shape && short && ((fl & 16'h00FF) == 16'h00E3) && (n >= 14 + tl);
    m.keyok = et_ok && ihl45 && tcp && fragfree;
    m.flushall = vlan || (et_ok && tcp && !(ihl45 && fragfree));
    m.key = {at(f, 26), at(f, 27), at(f, 28), at(f, 29), at(f, 30), at(f, 31), at(f, 32), at(f, 33),
             at(f, 34), at(f, 35), at(f, 36), at(f, 37)};
    m.seq = {at(f, 38), at(f, 39), at(f, 40), at(f, 41)};
    m.ack = {at(f, 42), at(f, 43), at(f, 44), at(f, 45)};
    return m;
  endfunction

  task automatic model_reset();
    for (int i = 0; i < FLOWS; i++) begin
      mf[i].v = 1'b0; mf[i].held = 1'b0; mf[i].lv = 1'b0; mf[i].rank = i; mf[i].hcnt = 0; mf[i].hidx = -1;
      mf[i].key = '0; mf[i].hack = '0; mf[i].hseq = '0; mf[i].lack = '0;
    end
    mout = {};
    m_c = 0; m_d = 0; m_f = 0; m_t = 0; m_l = 0; m_o = 0;
  endtask

  task automatic model_flush(input int fi);
    mout.push_back(mf[fi].hidx);
    mf[fi].held = 1'b0;
    m_f++;
    m_o++;
  endtask

  task automatic model_touch(input int fi);
    int r;
    r = mf[fi].rank;
    for (int j = 0; j < FLOWS; j++) if (mf[j].rank < r) mf[j].rank++;
    mf[fi].rank = 0;
  endtask

  task automatic model_frame(input int i, input bytes_t f);
    mi_t m;
    int hit;
    int vic;
    int fi;
    m = model_parse(f);
    if (!m.cand) begin
      if (m.flushall) begin
        for (int j = 0; j < FLOWS; j++) if (mf[j].held) model_flush(j);
      end else if (m.keyok) begin
        hit = -1;
        for (int j = 0; j < FLOWS; j++) if (mf[j].v && mf[j].key == m.key) hit = j;
        if (hit >= 0 && mf[hit].held) model_flush(hit);
      end
      mout.push_back(i);
    end else begin
      m_c++;
      hit = -1;
      for (int j = 0; j < FLOWS; j++) if (mf[j].v && mf[j].key == m.key) hit = j;
      if (hit < 0) begin
        vic = -1;
        for (int j = FLOWS - 1; j >= 0; j--) if (!mf[j].v) vic = j;
        if (vic < 0) for (int j = 0; j < FLOWS; j++) if (mf[j].rank == FLOWS - 1) vic = j;
        if (mf[vic].held) model_flush(vic);
        mf[vic].v = 1'b1; mf[vic].key = m.key; mf[vic].held = 1'b1; mf[vic].hidx = i; mf[vic].hack = m.ack;
        mf[vic].hseq = m.seq; mf[vic].hcnt = 0; mf[vic].lv = 1'b1; mf[vic].lack = m.ack;
        model_touch(vic);
      end else begin
        fi = hit;
        if (mf[fi].held) begin
          if (sgt(m.ack, mf[fi].hack) && !sgt(mf[fi].hseq, m.seq)) begin
            m_d++;
            if (mf[fi].hcnt + 1 >= m_limit) begin
              mout.push_back(i);
              m_f++;
              m_l++;
              mf[fi].held = 1'b0;
            end else begin
              mf[fi].hidx = i; mf[fi].hack = m.ack; mf[fi].hseq = m.seq; mf[fi].hcnt++;
            end
          end else begin
            model_flush(fi);
            mout.push_back(i);
            m_f++;
          end
        end else begin
          if (mf[fi].lv && !sgt(m.ack, mf[fi].lack)) begin
            mout.push_back(i);
            m_f++;
          end else begin
            mf[fi].held = 1'b1; mf[fi].hidx = i; mf[fi].hack = m.ack; mf[fi].hseq = m.seq; mf[fi].hcnt = 0;
          end
        end
        if (!mf[fi].lv || sgt(m.ack, mf[fi].lack)) mf[fi].lack = m.ack;
        mf[fi].lv = 1'b1;
        model_touch(fi);
      end
    end
  endtask

  task automatic model_flush_all();
    for (int j = 0; j < FLOWS; j++) if (mf[j].held) model_flush(j);
  endtask

  // ---------------------------------------------------------------------------
  // Random frame mix for the model runs (5 flows over the 4-entry table)
  // ---------------------------------------------------------------------------
  bit [31:0] g_seq [0:4];
  bit [31:0] g_ack [0:4];
  bit [15:0] g_win [0:4];

  task automatic gen_reset();
    g_ack[0] = 32'h00001000; g_ack[1] = 32'hFFFFFF00; g_ack[2] = 32'h7FFFF000; g_ack[3] = 32'hFFFFE000;
    g_ack[4] = 32'h80000000;
    for (int i = 0; i < 5; i++) begin
      g_seq[i] = 32'h0000A000 + 32'(i) * 32'h01000000;
      g_win[i] = 16'd8192;
    end
  endtask

  task automatic gen_rand(output bytes_t f);
    int k;
    int fl;
    int p;
    bit [8:0] fv;
    int fvs [0:10];
    fvs[0] = 'h018; fvs[1] = 'h011; fvs[2] = 'h014; fvs[3] = 'h004; fvs[4] = 'h002; fvs[5] = 'h012; fvs[6] = 'h030;
    fvs[7] = 'h050; fvs[8] = 'h090; fvs[9] = 'h000; fvs[10] = 'h110;
    fl = rr(0, 4);
    k = rr(0, 29);
    case (k)
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11: begin
        g_ack[fl] = g_ack[fl] + 32'(rr(1, 3000));
        g_win[fl] = 16'(rr(1000, 60000));
        f = ack_f(fl, g_seq[fl], g_ack[fl], g_win[fl], rr(0, 1));
      end
      12, 13: f = ack_f(fl, g_seq[fl], g_ack[fl], g_win[fl], rr(0, 1));
      14: begin
        g_win[fl] = 16'(rr(1000, 60000));
        f = ack_f(fl, g_seq[fl], g_ack[fl], g_win[fl], 0);
      end
      15: f = ack_f(fl, g_seq[fl], g_ack[fl] - 32'(rr(1, 2000)), g_win[fl], 1);
      16: begin
        g_ack[fl] = g_ack[fl] + 32'(rr(1, 3000));
        f = ack_f(fl, g_seq[fl] - 32'(rr(1, 10)), g_ack[fl], g_win[fl], 0);
      end
      17: begin
        g_ack[fl] = g_ack[fl] + 32'(rr(0, 3000));
        f = build_tcp(fl, g_seq[fl], g_ack[fl], 9'h010, g_win[fl], 0, 2, 0, 5, 16'h4000, 1'b0);
      end
      18, 19: begin
        p = rr(1, 200);
        f = build_tcp(fl, g_seq[fl], g_ack[fl], 9'h018, g_win[fl], p, 0, 0, 5, 16'h4000, 1'b0);
        g_seq[fl] = g_seq[fl] + 32'(p);
      end
      20: begin
        fv = 9'(fvs[rr(0, 10)]);
        f = build_tcp(fl, g_seq[fl], g_ack[fl], fv, g_win[fl], 0, 0, 0, 5, 16'h4000, 1'b0);
      end
      21: f = build_tcp(fl, g_seq[fl], g_ack[fl] + 32'd5, 9'h010, g_win[fl], 0, 0, rr(1, 3), 5, 16'h4000, 1'b0);
      22: f = build_tcp(fl, g_seq[fl], g_ack[fl] + 32'd5, 9'h010, g_win[fl], 0, 0, 0, 5, 16'h4000, 1'b1);
      23: f = build_tcp(fl, g_seq[fl], g_ack[fl] + 32'd5, 9'h010, g_win[fl], 0, 0, 0, 6, 16'h4000, 1'b0);
      24: f = build_tcp(fl, g_seq[fl], g_ack[fl] + 32'd5, 9'h010, g_win[fl], 0, 0, 0, 5, rr(0, 1) ? 16'h2000 : 16'h0123, 1'b0);
      25: f = udp_f(rr(0, 200));
      26: f = arp_f();
      27: begin
        p = rr(300, 900);
        f = build_tcp(fl, g_seq[fl], g_ack[fl], 9'h018, g_win[fl], p, 0, 0, 5, 16'h4000, 1'b0);
        g_seq[fl] = g_seq[fl] + 32'(p);
      end
      28: f = build_tcp(fl, g_seq[fl], g_ack[fl] + 32'd1, 9'h010, g_win[fl], 0, 3, 0, 5, 16'h4000, 1'b0);
      default: f = build_tcp(fl, g_seq[fl], g_ack[fl] + 32'd1, 9'h010, g_win[fl], 0, 5, 0, 5, 16'h4000, 1'b0);
    endcase
  endtask

  // ---------------------------------------------------------------------------
  // Test: registers
  // ---------------------------------------------------------------------------
  task automatic test_regs();
    logic [31:0] v;
    logic [31:0] exp_caps;
    logic [31:0] exp_ctrl;
    exp_caps = 32'h05EE083F | ((F_ACK != 0) ? 32'h40 : 32'h0) | ((F_BAT != 0) ? 32'h80 : 32'h0);
    u_axi.rd(R_ID, v);     tb_check(v == 32'h5443504F, $sformatf("ID %08x", v));
    u_axi.rd(R_VER, v);    tb_check(v == 32'h10222026, $sformatf("VERSION %08x", v));
    u_axi.rd(R_CAPS, v);   tb_check(v == exp_caps, $sformatf("CAPS %08x, expected %08x", v, exp_caps));
    u_axi.rd(R_CAPS2, v);
    tb_check(v == (((F_ACK != 0) ? FLOWS : 0) | ((F_BAT != 0) ? (RESERVE_B << 8) : 0)), $sformatf("CAPS2 %08x", v));
    u_axi.rd(R_CTRL, v);   tb_check(v == 0, $sformatf("CTRL after reset %08x", v));
    u_axi.rd(R_STATUS, v);
    tb_check(v == (32'h3 | ((F_ACK != 0) ? 32'h4 : 32'h0) | ((F_BAT != 0) ? 32'h8 : 32'h0)), $sformatf("STATUS %08x", v));
    exp_ctrl = 32'h7 | ((F_ACK != 0) ? C_ACK : 32'h0) | ((F_BAT != 0) ? C_BAT : 32'h0);
    u_axi.wr(R_CTRL, 32'h1F);
    repeat (20) @(posedge clk);
    u_axi.rd(R_CTRL, v);   tb_check(v == exp_ctrl, $sformatf("CTRL write 1F reads %08x, expected %08x", v, exp_ctrl));
    u_axi.wr(R_CTRL, 32'hFFFF_FFFF);
    repeat (20) @(posedge clk);
    u_axi.rd(R_CTRL, v);   tb_check(v == exp_ctrl, $sformatf("CTRL write FFFFFFFF reads %08x, expected %08x", v, exp_ctrl));
    u_axi.wr(R_CTRL, 32'h0);
    repeat (20) @(posedge clk);
    // Defaults and read-back of the configuration registers.
    u_axi.rd(R_ACK_TIMER, v);  tb_check(v == ((F_ACK != 0) ? 200 : 0), $sformatf("ACK_TIMER default %0d", v));
    u_axi.rd(R_ACK_LIMIT, v);  tb_check(v == ((F_ACK != 0) ? 8 : 0), $sformatf("ACK_LIMIT default %0d", v));
    u_axi.rd(R_BAT_TIMER, v);  tb_check(v == ((F_BAT != 0) ? 30 : 0), $sformatf("BAT_TIMER default %0d", v));
    u_axi.rd(R_BAT_FRAMES, v); tb_check(v == ((F_BAT != 0) ? 16 : 0), $sformatf("BAT_FRAMES default %0d", v));
    u_axi.rd(R_BAT_BYTES, v);  tb_check(v == ((F_BAT != 0) ? 8192 : 0), $sformatf("BAT_BYTES default %0d", v));
    wr_reg(R_ACK_TIMER, 32'h0000_1234);  wr_reg(R_ACK_LIMIT, 32'hFFFF_FF55);
    wr_reg(R_BAT_TIMER, 32'h0000_4321);  wr_reg(R_BAT_FRAMES, 32'hFFFF_FF33); wr_reg(R_BAT_BYTES, 32'h0001_2345);
    u_axi.rd(R_ACK_TIMER, v);  tb_check(v == ((F_ACK != 0) ? 32'h1234 : 0), $sformatf("ACK_TIMER %08x", v));
    u_axi.rd(R_ACK_LIMIT, v);  tb_check(v == ((F_ACK != 0) ? 32'h55 : 0), $sformatf("ACK_LIMIT %08x", v));
    u_axi.rd(R_BAT_TIMER, v);  tb_check(v == ((F_BAT != 0) ? 32'h4321 : 0), $sformatf("BAT_TIMER %08x", v));
    u_axi.rd(R_BAT_FRAMES, v); tb_check(v == ((F_BAT != 0) ? 32'h33 : 0), $sformatf("BAT_FRAMES %08x", v));
    u_axi.rd(R_BAT_BYTES, v);  tb_check(v == ((F_BAT != 0) ? 32'h2345 : 0), $sformatf("BAT_BYTES %08x", v));
    // Restore defaults for the cases that follow.
    wr_reg(R_ACK_TIMER, 200);  wr_reg(R_ACK_LIMIT, 8);
    wr_reg(R_BAT_TIMER, 30);   wr_reg(R_BAT_FRAMES, 16); wr_reg(R_BAT_BYTES, 8192);
    // Undefined offsets read 0 and ignore writes.
    for (int a = 12'h034; a < 12'h040; a += 4) begin
      u_axi.rd(12'(a), v); tb_check(v == 0, $sformatf("undefined offset %03x reads %08x", a, v));
    end
    u_axi.wr(12'h0C0, 32'hFFFF_FFFF);
    u_axi.rd(12'h0C0, v); tb_check(v == 0, "0x0C0 reads non-zero");
    u_axi.rd(12'h0FC, v); tb_check(v == 0, "0x0FC reads non-zero");
    u_axi.rd(12'h100, v); tb_check(v == 0, "0x100 reads non-zero");
    read_cnt();
    for (int i = 0; i < 6; i++) tb_check(cnt_a[i] == 0 && cnt_b[i] == 0, $sformatf("counter %0d not zero at reset", i));
  endtask

  // ---------------------------------------------------------------------------
  // Test P: built but disabled
  // ---------------------------------------------------------------------------
  task automatic test_disabled();
    bytes_t inq[$];
    bytes_t expq[$];
    bytes_t got[$];
    bytes_t f;
    string  why;
    logic [31:0] feat;
    feat = ((F_ACK != 0) ? C_ACK : 32'h0) | ((F_BAT != 0) ? C_BAT : 32'h0);
    gen_reset();
    // P1: rx_csum on, the feature bits off: the plain core's output, one frame per transfer.
    clear_cnt();
    set_ctrl(C_RX);
    for (int i = 0; i < 120; i++) begin
      gen_rand(f);
      inq.push_back(f);
      expq.push_back(ex(f));
    end
    send_list(inq, 25, 60);
    wait_idle();
    collect_frames(got);
    cmp_frames("disabled", got, expq);
    tb_check(tr_bytes.size() == inq.size(), $sformatf("disabled: %0d transfers for %0d frames", tr_bytes.size(), inq.size()));
    read_cnt();
    for (int i = 0; i < 6; i++) tb_check(cnt_a[i] == 0 && cnt_b[i] == 0, $sformatf("disabled: feature counter %0d = %0d / %0d", i, cnt_a[i], cnt_b[i]));
    // P2: rx_csum off, the feature bits on: frames leave bit-exact, no trailer.
    set_ctrl(feat);
    send_list(inq, 10, 80);
    wait_idle();
    tb_check(u_rx_sink.frames.size() == inq.size(), $sformatf("raw: %0d frames for %0d", u_rx_sink.frames.size(), inq.size()));
    for (int i = 0; i < inq.size() && u_rx_sink.frames.size() != 0; i++) begin
      f = u_rx_sink.frames.pop_front();
      tb_check(bytes_equal(f, inq[i], why), $sformatf("raw frame %0d: %s", i, why));
    end
    u_rx_sink.frames = {};
    read_cnt();
    for (int i = 0; i < 6; i++) tb_check(cnt_a[i] == 0 && cnt_b[i] == 0, $sformatf("raw: feature counter %0d = %0d / %0d", i, cnt_a[i], cnt_b[i]));
    set_ctrl(32'h0);
  endtask

  // ---------------------------------------------------------------------------
  // Test A: ACK coalescing, directed
  // ---------------------------------------------------------------------------
  // Run one case: send, wait for idle, compare the frames out with the listed inputs, check the counters.
  task automatic ack_case(input string tag, input bytes_t inq[$], input int idx[$], input int c, input int d,
                          input int f, input int t, input int l, input int o);
    bytes_t expq[$];
    bytes_t got[$];
    set_ctrl(C_RX);                 // off and on again: the flow table starts empty
    set_ctrl(C_RX | C_ACK);
    clear_cnt();
    for (int i = 0; i < idx.size(); i++) expq.push_back(ex(inq[idx[i]]));
    send_list(inq, 0, 100);
    wait_idle();
    collect_frames(got);
    cmp_frames(tag, got, expq);
    chk_ack(tag, c, d, f, t, l, o);
  endtask

  task automatic test_ack_directed();
    bytes_t q[$];
    int     idx[$];
    int     fvs [0:10];
    bytes_t f;
    int     t0;
    int     dt;
    logic [31:0] st;
    bytes_t expq[$];
    bytes_t got[$];
    set_ctrl(C_RX | C_ACK);
    wr_reg(R_ACK_TIMER, 200);
    wr_reg(R_ACK_LIMIT, 8);

    // D1 coalesced run: five increasing ACKs leave as the newest one.
    q = {}; for (int k = 1; k <= 5; k++) q.push_back(ack_f(0, 1, 1000 * k, 8192, 0));
    idx = '{4};
    ack_case("D1 run", q, idx, 5, 4, 1, 1, 0, 0);
    // D2 the same with the timestamp option: the newest frame carries the newest TSval.
    q = {}; for (int k = 1; k <= 5; k++) q.push_back(ack_f(0, 1, 1000 * k, 8192, 1));
    idx = '{4};
    ack_case("D2 timestamps", q, idx, 5, 4, 1, 1, 0, 0);
    // D3 duplicate ACKs are never dropped.
    q = {};
    q.push_back(ack_f(0, 1, 100, 8192, 0)); q.push_back(ack_f(0, 1, 200, 8192, 0)); q.push_back(ack_f(0, 1, 200, 8192, 0));
    q.push_back(ack_f(0, 1, 200, 8192, 0)); q.push_back(ack_f(0, 1, 300, 8192, 0));
    idx = '{1, 2, 3, 4};
    ack_case("D3 duplicates", q, idx, 5, 1, 4, 1, 0, 1);
    // D4 window updates (same ACK, new window) are forwarded.
    q = {};
    q.push_back(ack_f(0, 1, 100, 1000, 0)); q.push_back(ack_f(0, 1, 100, 2000, 0)); q.push_back(ack_f(0, 1, 100, 3000, 0));
    idx = '{0, 1, 2};
    ack_case("D4 window updates", q, idx, 3, 0, 3, 0, 0, 1);
    // D5 an older ACK is forwarded after the held one, and does not lower the last ACK seen.
    q = {};
    q.push_back(ack_f(0, 1, 200, 8192, 0)); q.push_back(ack_f(0, 1, 100, 8192, 0)); q.push_back(ack_f(0, 1, 300, 8192, 0));
    idx = '{0, 1, 2};
    ack_case("D5a older ACK", q, idx, 3, 0, 3, 1, 0, 1);
    // D5b a lower sequence number (keep-alive shape) is not coalesced.
    q = {};
    q.push_back(ack_f(0, 5000, 200, 8192, 0)); q.push_back(ack_f(0, 4000, 300, 8192, 0));
    idx = '{0, 1};
    ack_case("D5b lower seq", q, idx, 2, 0, 2, 0, 0, 1);
    // D5c the same sequence number is coalesced.
    q = {};
    q.push_back(ack_f(0, 5000, 200, 8192, 0)); q.push_back(ack_f(0, 5000, 300, 8192, 0));
    idx = '{1};
    ack_case("D5c same seq", q, idx, 2, 1, 1, 1, 0, 0);
    // D6 options other than none / NOP NOP timestamp: not candidates (SACK, MSS, timestamp in another order).
    for (int om = 0; om < 3; om++) begin
      int mode;
      mode = (om == 0) ? 2 : ((om == 1) ? 3 : 5);
      q = {};
      q.push_back(ack_f(0, 1, 100, 8192, 0));
      q.push_back(build_tcp(0, 1, 150, 9'h010, 8192, 0, mode, 0, 5, 16'h4000, 1'b0));
      idx = '{0, 1};
      ack_case($sformatf("D6 option mode %0d", mode), q, idx, 1, 0, 1, 0, 0, 1);
    end
    // D7 flag combinations other than exactly ACK flush the held ACK and are forwarded in order.
    fvs[0] = 'h018; fvs[1] = 'h011; fvs[2] = 'h014; fvs[3] = 'h004; fvs[4] = 'h002; fvs[5] = 'h012; fvs[6] = 'h030;
    fvs[7] = 'h050; fvs[8] = 'h090; fvs[9] = 'h000; fvs[10] = 'h110;
    for (int k = 0; k < 11; k++) begin
      q = {};
      q.push_back(ack_f(0, 1, 100, 8192, 0));
      q.push_back(build_tcp(0, 1, 150, 9'(fvs[k]), 8192, 0, 0, 0, 5, 16'h4000, 1'b0));
      idx = '{0, 1};
      ack_case($sformatf("D7 flags %03x", fvs[k]), q, idx, 1, 0, 1, 0, 0, 1);
    end
    // D8 payload segments (short and long) flush the held ACK.
    for (int pl = 0; pl < 3; pl++) begin
      q = {};
      q.push_back(ack_f(0, 1, 100, 8192, 0));
      q.push_back(build_tcp(0, 1, 150, 9'h010, 8192, (pl == 0) ? 1 : ((pl == 1) ? 10 : 400), 0, 0, 5, 16'h4000, 1'b0));
      idx = '{0, 1};
      ack_case($sformatf("D8 payload %0d", pl), q, idx, 1, 0, 1, 0, 0, 1);
    end
    // D9 bad checksums (TCP, IPv4 header): not candidates, ordering flush.
    for (int bm = 1; bm <= 3; bm++) begin
      q = {};
      q.push_back(ack_f(0, 1, 100, 8192, 0));
      q.push_back(build_tcp(0, 1, 200, 9'h010, 8192, 0, 0, bm, 5, 16'h4000, 1'b0));
      idx = '{0, 1};
      ack_case($sformatf("D9 bad checksum %0d", bm), q, idx, 1, 0, 1, 0, 0, 1);
    end
    // D10 / D11 / D12 frames whose flow cannot be read flush every held ACK: fragment, IP options, VLAN.
    for (int kind = 0; kind < 3; kind++) begin
      q = {};
      q.push_back(ack_f(0, 1, 100, 8192, 0));
      q.push_back(ack_f(1, 1, 100, 8192, 0));
      if (kind == 0)      q.push_back(build_tcp(0, 1, 150, 9'h010, 8192, 0, 0, 0, 5, 16'h2000, 1'b0));
      else if (kind == 1) q.push_back(build_tcp(0, 1, 150, 9'h010, 8192, 0, 0, 0, 6, 16'h4000, 1'b0));
      else                q.push_back(build_tcp(0, 1, 150, 9'h010, 8192, 0, 0, 0, 5, 16'h4000, 1'b1));
      idx = '{0, 1, 2};
      ack_case($sformatf("D10 unreadable flow %0d", kind), q, idx, 2, 0, 2, 0, 0, 2);
    end
    // D13 two interleaved flows.
    q = {};
    for (int k = 1; k <= 3; k++) begin
      q.push_back(ack_f(0, 1, 100 * k, 8192, 0));
      q.push_back(ack_f(1, 1, 100 * k, 8192, 0));
    end
    idx = '{4, 5};
    ack_case("D13 interleaved flows", q, idx, 6, 4, 2, 2, 0, 0);
    // D14 table eviction: the fifth flow takes the oldest entry, whose held ACK is forwarded first.
    set_ctrl(C_RX);
    set_ctrl(C_RX | C_ACK);
    clear_cnt();
    q = {};
    for (int fl = 0; fl < 5; fl++) q.push_back(ack_f(fl, 1, 100, 8192, 0));
    u_rx_sink.ready_pct = 100;
    for (int i = 0; i < q.size(); i++) begin
      u_rx_src.gap_pct = 0;
      u_rx_src.send(q[i]);
      u_rx_src.idle(40);
    end
    wait_idle();
    collect_frames(got);
    expq = {};
    for (int i = 0; i < 5; i++) expq.push_back(ex(q[i]));
    cmp_frames("D14 eviction", got, expq);
    chk_ack("D14 eviction", 5, 0, 5, 4, 0, 1);
    // D15 ordering against data of the same flow; other flows, UDP and ARP are not delayed.
    q = {};
    q.push_back(ack_f(0, 1, 100, 8192, 0));
    q.push_back(build_tcp(0, 1, 100, 9'h018, 8192, 20, 0, 0, 5, 16'h4000, 1'b0));
    q.push_back(ack_f(0, 21, 200, 8192, 0));
    q.push_back(build_tcp(1, 1, 100, 9'h018, 8192, 20, 0, 0, 5, 16'h4000, 1'b0));
    idx = '{0, 1, 3, 2};
    ack_case("D15 ordering", q, idx, 2, 0, 2, 1, 0, 1);
    q = {};
    q.push_back(ack_f(0, 1, 100, 8192, 0));
    q.push_back(udp_f(30));
    q.push_back(arp_f());
    q.push_back(ack_f(0, 1, 200, 8192, 0));
    idx = '{1, 2, 3};
    ack_case("D15b others not delayed", q, idx, 2, 1, 1, 1, 0, 0);
    // D16 timer flush latency: a single ACK leaves about the timer register after it arrived.
    wr_reg(R_ACK_TIMER, 50);
    set_ctrl(C_RX);
    set_ctrl(C_RX | C_ACK);
    clear_cnt();
    t_out_first = {};
    f = ack_f(0, 1, 100, 8192, 0);
    u_rx_src.send(f);
    wait_idle();
    tb_check(t_out_first.size() == 1, "D16: one frame out");
    if (t_out_first.size() == 1) begin
      dt = t_out_first[0] - t_in_last;
      $display("TXO FEAT ack timer 50 us (%0d clocks per us): ACK left %0d clocks after its last beat", TICK, dt);
      tb_check(dt >= 50 * TICK - 30 && dt <= 50 * TICK + 200, $sformatf("D16: timer flush after %0d clocks", dt));
    end
    collect_frames(got);
    chk_ack("D16 timer", 1, 0, 1, 1, 0, 0);
    wr_reg(R_ACK_TIMER, 200);
    // D17 count limit 3: the fourth ACK of a run is forwarded at once.
    wr_reg(R_ACK_LIMIT, 3);
    q = {}; for (int k = 1; k <= 6; k++) q.push_back(ack_f(0, 1, 1000 * k, 8192, 0));
    idx = '{3, 5};
    ack_case("D17 count limit", q, idx, 6, 4, 2, 1, 1, 0);
    wr_reg(R_ACK_LIMIT, 8);
    // D18 sequence-number wrap.
    q = {};
    q.push_back(ack_f(0, 32'hFFFFFF00, 32'hFFFFFFF0, 8192, 0));
    q.push_back(ack_f(0, 32'hFFFFFFF0, 32'hFFFFFFFF, 8192, 0));
    q.push_back(ack_f(0, 32'h00000020, 32'h00000010, 8192, 0));
    idx = '{2};
    ack_case("D18a wrap forward", q, idx, 3, 2, 1, 1, 0, 0);
    q = {};
    q.push_back(ack_f(0, 5, 32'h00000010, 8192, 0));
    q.push_back(ack_f(0, 5, 32'hFFFFFFF0, 8192, 0));
    idx = '{0, 1};
    ack_case("D18b wrap backward", q, idx, 2, 0, 2, 0, 0, 1);
    // D19 switching the feature off forwards every held ACK, STATUS.ACK_IDLE shows a held ACK.
    wr_reg(R_ACK_TIMER, 60000);
    set_ctrl(C_RX);
    set_ctrl(C_RX | C_ACK);
    clear_cnt();
    q = {};
    q.push_back(ack_f(0, 1, 100, 8192, 0));
    q.push_back(ack_f(0, 1, 200, 8192, 0));
    send_list(q, 0, 100);
    repeat (300) @(posedge clk);
    u_axi.rd(R_STATUS, st);
    tb_check((st & 32'h4) == 0, $sformatf("D19: ACK_IDLE set while an ACK is held (STATUS %08x)", st));
    tb_check(u_rx_sink.frames.size() == 0, "D19: a held ACK left before the switch-off");
    set_ctrl(C_RX);
    wait_idle();
    collect_frames(got);
    expq = {};
    expq.push_back(ex(q[1]));
    cmp_frames("D19 disable flush", got, expq);
    chk_ack("D19 disable flush", 2, 1, 1, 0, 0, 1);
    wr_reg(R_ACK_TIMER, 200);
    set_ctrl(32'h0);
  endtask

  // ---------------------------------------------------------------------------
  // Test AR / AB: random runs against the model
  // ---------------------------------------------------------------------------
  task automatic model_run(input string tag, input int n, input int gap, input int rdy, input int limit,
                           input logic [31:0] ctrl, input int bat_frames);
    bytes_t inq[$];
    bytes_t expq[$];
    bytes_t got[$];
    bytes_t f;
    logic [31:0] st;
    int before_flush;
    wr_reg(R_ACK_TIMER, 60000);
    wr_reg(R_ACK_LIMIT, limit);
    if (F_BAT != 0) begin
      wr_reg(R_BAT_FRAMES, bat_frames);
      wr_reg(R_BAT_BYTES, 8192);
      wr_reg(R_BAT_TIMER, 30);
    end
    m_limit = limit;
    gen_reset();
    model_reset();
    clear_cnt();
    for (int i = 0; i < n; i++) begin
      gen_rand(f);
      inq.push_back(f);
      model_frame(i, f);
    end
    before_flush = mout.size();
    model_flush_all();
    set_ctrl(ctrl);
    send_list(inq, gap, rdy);
    settle(2500);
    u_axi.rd(R_STATUS, st);
    tb_check(((st & 32'h4) == 0) == (before_flush < mout.size()), $sformatf("%s: ACK_IDLE %08x with %0d held at the end", tag, st, mout.size() - before_flush));
    // Switch the feature off: the held ACKs are forwarded in table order.
    set_ctrl(ctrl & ~C_ACK);
    wait_idle();
    collect_frames(got);
    for (int i = 0; i < mout.size(); i++) expq.push_back(ex(inq[mout[i]]));
    cmp_frames(tag, got, expq);
    chk_ack(tag, m_c, m_d, m_f, m_t, m_l, m_o);
    if (F_BAT != 0 && (ctrl & C_BAT) != 0) begin
      tb_check(cnt_b[1] == mout.size(), $sformatf("%s: batched frames %0d, expected %0d", tag, cnt_b[1], mout.size()));
      tb_check(cnt_b[0] == tr_bytes.size(), $sformatf("%s: batches %0d, transfers %0d", tag, cnt_b[0], tr_bytes.size()));
      for (int i = 0; i < tr_bytes.size(); i++) begin
        tb_check(tr_bytes[i] <= 8192, $sformatf("%s: transfer %0d has %0d bytes", tag, i, tr_bytes[i]));
        tb_check(tr_frames[i] <= bat_frames, $sformatf("%s: transfer %0d has %0d frames", tag, i, tr_frames[i]));
      end
    end
    $display("TXO FEAT %s: %0d frames in, %0d out (%0d coalesced away), %0d transfers; candidates %0d dropped %0d forwarded %0d limit-flush %0d order-flush %0d",
             tag, n, mout.size(), n - mout.size(), tr_bytes.size(), m_c, m_d, m_f, m_l, m_o);
    set_ctrl(32'h0);
  endtask

  // ---------------------------------------------------------------------------
  // Test B: batching, directed
  // ---------------------------------------------------------------------------
  function automatic bytes_t plain_frame(input int n);
    bytes_t q;
    q = rand_bytes(n);
    if (n >= 14) begin
      q[12] = 8'h88;    // not IP: no checksum work, only the frame and its trailer are of interest
      q[13] = 8'h99;
    end
    return q;
  endfunction

  task automatic bat_case(input string tag, input bytes_t inq[$], input int cnts[$], input int b, input int f, input int cb,
                          input int cc, input int ct, input int co);
    bytes_t expq[$];
    bytes_t got[$];
    clear_cnt();
    for (int i = 0; i < inq.size(); i++) expq.push_back(ex(inq[i]));
    send_list(inq, 0, 100);
    wait_idle();
    collect_frames(got);
    cmp_frames(tag, got, expq);
    tb_check(tr_frames.size() == cnts.size(), $sformatf("%s: %0d transfers, expected %0d", tag, tr_frames.size(), cnts.size()));
    for (int i = 0; i < cnts.size() && i < tr_frames.size(); i++)
      tb_check(tr_frames[i] == cnts[i], $sformatf("%s: transfer %0d holds %0d frames, expected %0d", tag, i, tr_frames[i], cnts[i]));
    chk_bat(tag, b, f, cb, cc, ct, co);
  endtask

  task automatic test_batch();
    bytes_t q[$];
    int     cn[$];
    bytes_t f;
    bytes_t got[$];
    bytes_t expq[$];
    string  why;
    logic [31:0] st;
    int     dt;
    set_ctrl(C_RX | C_BAT);
    wr_reg(R_BAT_TIMER, 50);
    wr_reg(R_BAT_FRAMES, 16);
    wr_reg(R_BAT_BYTES, 8192);
    // BB1 one frame on an idle line leaves when the timer expires, not later.
    clear_cnt();
    t_out_last = {};
    f = plain_frame(200);
    u_rx_src.send(f);
    wait_idle();
    tb_check(t_out_last.size() == 1, "BB1: one transfer out");
    if (t_out_last.size() == 1) begin
      dt = t_out_last[0] - t_in_last;
      $display("TXO FEAT batch timer 50 us: single frame completed %0d clocks after its last input beat", dt);
      tb_check(dt >= 50 * TICK - 30 && dt <= 50 * TICK + 200, $sformatf("BB1: batch timer closed after %0d clocks", dt));
    end
    collect_frames(got);
    expq = {}; expq.push_back(ex(f));
    cmp_frames("BB1 single frame", got, expq);
    chk_bat("BB1", 1, 1, 0, 0, 1, 0);
    wr_reg(R_BAT_TIMER, 100);
    // BB2 count limit 4: ten frames leave as 4, 4, 2.
    wr_reg(R_BAT_FRAMES, 4);
    q = {}; for (int k = 0; k < 10; k++) q.push_back(plain_frame(100 + 20 * k));
    cn = '{4, 4, 2};
    bat_case("BB2 count limit", q, cn, 3, 10, 0, 2, 1, 0);
    // BB2b a count limit of 1 (and 0) keeps every frame alone.
    for (int lim = 0; lim < 2; lim++) begin
      wr_reg(R_BAT_FRAMES, lim);
      q = {}; for (int k = 0; k < 3; k++) q.push_back(plain_frame(60 + k));
      cn = '{1, 1, 1};
      bat_case($sformatf("BB2b count limit %0d", lim), q, cn, 3, 3, 0, 3, 0, 0);
    end
    wr_reg(R_BAT_FRAMES, 32);
    // BB3 byte limit 4096 with 600-byte frames: 616 bytes each, four per batch.
    wr_reg(R_BAT_BYTES, 4096);
    q = {}; for (int k = 0; k < 10; k++) q.push_back(plain_frame(600));
    cn = '{4, 4, 2};
    bat_case("BB3 byte limit", q, cn, 3, 10, 2, 0, 1, 0);
    // BB4 exact fit: 1518-byte frames are 1528 bytes with the trailer; 1528 + 2056 = 3584.
    wr_reg(R_BAT_BYTES, 3584);
    q = {}; for (int k = 0; k < 5; k++) q.push_back(plain_frame(1518));
    cn = '{2, 2, 1};
    bat_case("BB4 exact fit", q, cn, 3, 5, 2, 0, 1, 0);
    wr_reg(R_BAT_BYTES, 3576);
    cn = '{1, 1, 1, 1, 1};
    bat_case("BB4 one beat short", q, cn, 5, 5, 5, 0, 0, 0);
    // BB5 largest frames (2048 bytes): three per 8192-byte batch, never more than the limit.
    wr_reg(R_BAT_BYTES, 8192);
    q = {}; for (int k = 0; k < 7; k++) q.push_back(plain_frame(2048));
    cn = '{3, 3, 1};
    bat_case("BB5 maximum frames", q, cn, 3, 7, 2, 0, 1, 0);
    tb_check(tr_bytes.size() == 3 && tr_bytes[0] == 3 * 2056, $sformatf("BB5: first batch %0d bytes", (tr_bytes.size() > 0) ? tr_bytes[0] : -1));
    // BB5b a 3000-byte frame (more than the reserve) on its own is carried whole.
    q = {}; q.push_back(plain_frame(3000));
    cn = '{1};
    bat_case("BB5b long frame", q, cn, 1, 1, 0, 0, 1, 0);
    // BB6 minimum and maximum sizes, mixed, in one run.
    wr_reg(R_BAT_FRAMES, 16);
    q = {};
    q.push_back(plain_frame(14)); q.push_back(plain_frame(15)); q.push_back(plain_frame(22)); q.push_back(plain_frame(33));
    q.push_back(plain_frame(60)); q.push_back(plain_frame(61)); q.push_back(plain_frame(100)); q.push_back(plain_frame(1514));
    q.push_back(plain_frame(1518)); q.push_back(plain_frame(2048)); q.push_back(plain_frame(14)); q.push_back(plain_frame(60));
    clear_cnt();
    expq = {}; for (int i = 0; i < q.size(); i++) expq.push_back(ex(q[i]));
    send_list(q, 0, 100);
    wait_idle();
    collect_frames(got);
    cmp_frames("BB6 sizes", got, expq);
    for (int i = 0; i < tr_bytes.size(); i++) tb_check(tr_bytes[i] <= 8192, $sformatf("BB6: transfer %0d has %0d bytes", i, tr_bytes[i]));
    // BB7 back-to-back batches from a long burst of small frames: counters add up.
    wr_reg(R_BAT_TIMER, 30);
    q = {}; for (int k = 0; k < 60; k++) q.push_back(plain_frame(64));
    clear_cnt();
    send_list(q, 0, 100);
    wait_idle();
    collect_frames(got);
    expq = {}; for (int i = 0; i < q.size(); i++) expq.push_back(ex(q[i]));
    cmp_frames("BB7 burst", got, expq);
    read_cnt();
    tb_check(cnt_b[1] == 60, $sformatf("BB7: batched frames %0d", cnt_b[1]));
    tb_check(cnt_b[0] == tr_bytes.size(), $sformatf("BB7: batches %0d, transfers %0d", cnt_b[0], tr_bytes.size()));
    tb_check(cnt_b[0] == cnt_b[2] + cnt_b[3] + cnt_b[4] + cnt_b[5], "BB7: closes do not add up");
    for (int i = 0; i < tr_frames.size(); i++) tb_check(tr_frames[i] <= 16, $sformatf("BB7: transfer %0d has %0d frames", i, tr_frames[i]));
    tb_check(tr_frames.size() < 60, "BB7: no batching happened");
    // BB8 backpressure at every stage: random frames, random source gaps and sink stalls.
    gen_reset();
    q = {};
    for (int k = 0; k < 150; k++) begin
      if (rr(0, 2) == 0) gen_rand(f);
      else               f = plain_frame(rr(14, 1518));
      q.push_back(f);
    end
    for (int pass = 0; pass < 3; pass++) begin
      clear_cnt();
      send_list(q, (pass == 0) ? 30 : ((pass == 1) ? 0 : 60), (pass == 0) ? 30 : ((pass == 1) ? 20 : 100));
      wait_idle();
      collect_frames(got);
      expq = {}; for (int i = 0; i < q.size(); i++) expq.push_back(ex(q[i]));
      cmp_frames($sformatf("BB8 backpressure %0d", pass), got, expq);
      for (int i = 0; i < tr_bytes.size(); i++) begin
        tb_check(tr_bytes[i] <= 8192, $sformatf("BB8: transfer %0d has %0d bytes", i, tr_bytes[i]));
        tb_check(tr_frames[i] <= 16, $sformatf("BB8: transfer %0d has %0d frames", i, tr_frames[i]));
      end
      read_cnt();
      tb_check(cnt_b[1] == q.size() && cnt_b[0] == tr_bytes.size(), $sformatf("BB8: counters %0d / %0d", cnt_b[0], cnt_b[1]));
    end
    // BB9 switching the feature off closes an open batch (close "other").
    wr_reg(R_BAT_TIMER, 400);
    clear_cnt();
    q = {}; for (int k = 0; k < 3; k++) q.push_back(plain_frame(120));
    send_list(q, 0, 100);
    repeat (150) @(posedge clk);
    u_axi.rd(R_STATUS, st);
    tb_check((st & 32'h8) == 0, $sformatf("BB9: BATCH_IDLE set with an open batch (STATUS %08x)", st));
    tb_check(u_rx_sink.frames.size() == 0, "BB9: batch left before the timer");
    set_ctrl(C_RX);
    wait_idle();
    collect_frames(got);
    expq = {}; for (int i = 0; i < q.size(); i++) expq.push_back(ex(q[i]));
    cmp_frames("BB9 switch off", got, expq);
    tb_check(tr_frames.size() == 1 && tr_frames[0] == 3, "BB9: the three frames are one transfer");
    chk_bat("BB9", 1, 3, 0, 0, 0, 1);
    // BB10 a frame without trailer (rx_csum switched off) closes the open batch and passes untouched.
    set_ctrl(C_RX | C_BAT);
    clear_cnt();
    q = {}; for (int k = 0; k < 2; k++) q.push_back(plain_frame(90));
    send_list(q, 0, 100);
    repeat (150) @(posedge clk);
    set_ctrl(C_BAT);
    f = plain_frame(77);
    u_rx_src.send(f);
    wait_idle();
    tb_check(u_rx_sink.frames.size() == 2, $sformatf("BB10: %0d transfers", u_rx_sink.frames.size()));
    if (u_rx_sink.frames.size() == 2) begin
      bytes_t t0;
      bytes_t t1;
      bytes_t w[$];
      bit ok;
      t0 = u_rx_sink.frames.pop_front();
      t1 = u_rx_sink.frames.pop_front();
      walk(t0, w, ok, why);
      tb_check(ok && w.size() == 2, $sformatf("BB10: first transfer: %s", why));
      tb_check(bytes_equal(t1, f, why), $sformatf("BB10: raw frame: %s", why));
    end
    u_rx_sink.frames = {};
    chk_bat("BB10", 1, 2, 0, 0, 0, 1);
    // BB11 timer 0: every frame is alone.
    set_ctrl(C_RX | C_BAT);
    wr_reg(R_BAT_TIMER, 0);
    q = {}; for (int k = 0; k < 3; k++) q.push_back(plain_frame(70));
    cn = '{1, 1, 1};
    bat_case("BB11 timer 0", q, cn, 3, 3, 0, 0, 3, 0);
    wr_reg(R_BAT_TIMER, 30);
    set_ctrl(32'h0);
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  initial begin
    resetn = 1'b0;
    repeat (10) @(posedge clk);
    resetn = 1'b1;
    repeat (20) @(posedge clk);
    test_regs();
    test_disabled();
    if (F_ACK != 0) test_ack_directed();
    if (F_ACK != 0) begin
      // AR: ACK coalescing alone (batch bit off): small limit with stalls, then a large limit with a free-running stream.
      model_run("AR limit 5 stalls", 500, 20, 50, 5, C_RX | C_ACK, 16);
      model_run("AR limit 255 free", 400, 0, 100, 255, C_RX | C_ACK, 16);
      model_run("AR limit 2 slow sink", 300, 40, 25, 2, C_RX | C_ACK, 16);
    end
    if (F_BAT != 0) test_batch();
    if (F_ACK != 0 && F_BAT != 0) begin
      model_run("AB batch 6", 500, 15, 60, 5, C_RX | C_ACK | C_BAT, 6);
      model_run("AB batch 16 free", 400, 0, 100, 255, C_RX | C_ACK | C_BAT, 16);
    end
    repeat (50) @(posedge clk);
    tb_verdict("tb_rtlnet_tcp_offload_feat");
  end

  initial begin
    #1000ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_rtlnet_tcp_offload_feat");
  end

endmodule
