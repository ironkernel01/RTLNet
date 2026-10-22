// -----------------------------------------------------------------------------
// File: tb_rtlnet_dhcp.sv
// Purpose: self-checking bench for rtlnet_dhcp. The bench is the DHCP server
//   and the network: it drives the leaf's frame input the way the protocol
//   wrapper does (one frame at a time, >= 16 idle clocks, never while busy),
//   collects every frame the leaf sends and drives the register port.
// Cases:
//   1  register map: ID, VERSION, CAPS, CTRL AUTO level, pulse bits read 0,
//      undefined offsets read 0, read-only writes ignored, read latency 1.
//   2  acquisition with realistic OFFER/ACK option sets: DISCOVER and REQUEST
//      byte-exact against bench-built frames (independent RFC 1071 oracle),
//      lease outputs and registers, counters; server frames broadcast and
//      unicast.
//   3  retransmission: DISCOVER and REQUEST backoff 1x, 2x, 4x, cap, same xid,
//      MAX_TRIES sends then FAIL; restart with a new xid.
//   4  NAK: restart with a new xid, MAX_TRIES NAKs give FAIL, wrong-xid NAK
//      ignored.
//   5  ignored frames, each followed by a proof the client still waits (a good
//      OFFER answered): wrong xid (high, low), wrong chaddr (first, last), UDP
//      ports, op 1, cookie bytes, MF, fragment offset, IHL 6, TCP, EtherType
//      ARP and IPv6, other unicast MAC, a real ARP frame, an ICMP frame, ACK
//      while selecting, OFFER without 54, no option 53, no end option, option
//      past the datagram, IP length past the frame, frame longer than the RAM,
//      stale end option behind a cut frame, leaf disabled, a frame overlapping
//      a busy parse.
//   6  option parsing: pad runs at every beat alignment, reordered and
//      repeated options, two routers, zero-length and too-short options, long
//      unknown options, missing mask/router/lease/54, end option on the last
//      datagram byte, short-lease clamp.
//   7  renewal: T1 = lease/2 from the ACK, renewing REQUEST byte-exact, retries
//      every RENEW_RETRY_S with the same xid, expiry -> lease_valid falls and a
//      DISCOVER follows; renew ACK reloads new values; NAK while renewing;
//      RENEW_NOW; START while bound keeps the lease until it runs out.
//   8  STOP: DHCPRELEASE byte-exact (server MAC from the ACK), lease cleared;
//      STOP without a lease sends nothing; infinite lease never renews.
//   9  output stalls (random and long) on every frame type; CNT_CLEAR.
//   10 DUT B (DHCP_BUF_KB 2, distributed RAM) takes an 1100-byte OFFER that
//      DUT A ignores; DUT C (default parameters) reports its CAPS and is silent.
//   Run-wide: rtlnet_tb_leaf_busy_monitor, the sink's stream-rule checks, lease
//   outputs change only on a binding ACK or a lease loss and read 0 without a
//   lease, s_axis_tready always 1.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk 50 MHz (proto_clk). DUT A/B MS_CYCLES = 20: 1 ms = 20 clocks,
//   1 s = 20 000 clocks.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_dhcp;

  import rtlnet_tb_pkg::*;

  // ---------------------------------------------------------------------------
  // Configuration (bench literals, independent of the RTL)
  // ---------------------------------------------------------------------------
  localparam int MS          = 20;            // clocks per DUT millisecond
  localparam int SEC         = 1000 * MS;
  localparam int FIRST_MS    = 200;
  localparam int CAP_MS      = 800;
  localparam int TRIES       = 5;
  localparam int RETRY_S     = 2;
  localparam int LEASE_MIN   = 4;
  localparam int FRAME_LEN   = 342;

  localparam bit [47:0] CLIENT_MAC = 48'h02_1A_2B_3C_4D_5E;
  localparam bit [47:0] OTHER_MAC  = 48'h02_1A_2B_3C_4D_5F;
  localparam bit [47:0] SERVER_MAC = 48'h02_99_88_77_66_55;
  localparam bit [47:0] BCAST_MAC  = 48'hFF_FF_FF_FF_FF_FF;
  localparam bit [31:0] SERVER_IP  = {8'd10, 8'd20, 8'd0, 8'd1};
  localparam bit [31:0] SERVER_IP2 = {8'd10, 8'd20, 8'd0, 8'd2};
  localparam bit [31:0] OFFER_IP   = {8'd10, 8'd20, 8'd0, 8'd57};
  localparam bit [31:0] OFFER_IP2  = {8'd10, 8'd20, 8'd0, 8'd99};
  localparam bit [31:0] MASK_24    = 32'hFFFF_FF00;
  localparam bit [31:0] MASK_16    = 32'hFFFF_0000;
  localparam bit [31:0] ROUTER_IP  = {8'd10, 8'd20, 8'd0, 8'd254};
  localparam bit [31:0] ROUTER_IP2 = {8'd10, 8'd20, 8'd0, 8'd253};
  localparam bit [31:0] DNS_IP     = {8'd10, 8'd20, 8'd0, 8'd1};
  localparam bit [31:0] BCAST_IP   = 32'hFFFF_FFFF;
  localparam bit [31:0] LONG_LEASE = 32'd86400;

  // Register offsets (from the driver header contract, written here again).
  localparam bit [11:0] R_ID = 12'h000, R_VERSION = 12'h004, R_CAPS = 12'h008, R_CTRL = 12'h00C;
  localparam bit [11:0] R_STATUS = 12'h010, R_IP = 12'h014, R_MASK = 12'h018, R_ROUTER = 12'h01C;
  localparam bit [11:0] R_SERVER = 12'h020, R_TIME = 12'h024, R_ELAPSED = 12'h028, R_XID = 12'h02C;
  localparam bit [11:0] R_DISC = 12'h030, R_OFFERS = 12'h034, R_REQS = 12'h038, R_ACKS = 12'h03C;
  localparam bit [11:0] R_NAKS = 12'h040, R_LOST = 12'h044, R_RELS = 12'h048;
  localparam bit [31:0] C_START = 32'h1, C_STOP = 32'h2, C_AUTO = 32'h4, C_RENEW = 32'h8, C_CLEAR = 32'h1_0000;
  localparam int ST_INIT = 0, ST_SEL = 1, ST_REQ = 2, ST_BOUND = 3, ST_RENEW = 4, ST_FAIL = 5;

  // Frame kinds the client sends.
  localparam int K_DISC = 0, K_SEL = 1, K_REN = 2, K_REL = 3;

  // ---------------------------------------------------------------------------
  // Clock, reset, DUT A with its stream models and monitors
  // ---------------------------------------------------------------------------
  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #10 clk = ~clk;
  longint cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  logic [63:0] s_tdata;
  logic [7:0]  s_tkeep;
  logic        s_tlast, s_tvalid, s_tready;
  logic [63:0] m_tdata;
  logic [7:0]  m_tkeep;
  logic        m_tlast, m_tvalid, m_tready;
  logic        busy;
  logic        enable = 1'b1;
  logic        reg_wr_en = 1'b0;
  logic [11:0] reg_wr_addr = '0;
  logic [31:0] reg_wr_data = '0;
  logic        reg_rd_en = 1'b0;
  logic [11:0] reg_rd_addr = '0;
  logic [31:0] reg_rd_data;
  logic        lease_valid;
  logic [31:0] lease_ip, lease_mask, lease_router, lease_server, lease_time_s;

  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(11)) u_src (
    .clk(clk), .tdata(s_tdata), .tkeep(s_tkeep), .tlast(s_tlast), .tvalid(s_tvalid), .tready(s_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(23), .NAME("dhcp_tx")) u_sink (
    .clk(clk), .resetn(resetn), .tdata(m_tdata), .tkeep(m_tkeep), .tlast(m_tlast), .tvalid(m_tvalid), .tready(m_tready));

  rtlnet_dhcp #(
    .MS_CYCLES(MS), .DHCP_BUF_KB(1), .RAM_STYLE("block"), .OFFER_TIMEOUT_MS(FIRST_MS), .RETRY_CAP_MS(CAP_MS),
    .MAX_TRIES(TRIES), .RENEW_RETRY_S(RETRY_S), .LEASE_MIN_S(LEASE_MIN)
  ) dut_a (
    .clk(clk), .resetn(resetn), .enable(enable),
    .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid), .s_axis_tlast(s_tlast),
    .s_axis_tready(s_tready),
    .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid), .m_axis_tlast(m_tlast),
    .m_axis_tready(m_tready),
    .local_mac(CLIENT_MAC), .local_ip(32'hC0A8_0164), .busy(busy),
    .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data),
    .lease_valid(lease_valid), .lease_ip(lease_ip), .lease_mask(lease_mask), .lease_router(lease_router),
    .lease_server(lease_server), .lease_time_s(lease_time_s));

  rtlnet_tb_leaf_busy_monitor #(.NAME("dhcp_a")) u_busy_mon (
    .clk(clk), .resetn(resetn), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
    .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast), .busy(busy));

  // DUT B: 2 KiB distributed receive RAM, same timing. Own stream models.
  logic [63:0] sb_tdata, mb_tdata;
  logic [7:0]  sb_tkeep, mb_tkeep;
  logic        sb_tlast, sb_tvalid, sb_tready, mb_tlast, mb_tvalid, mb_tready, busy_b;
  logic        rb_wr_en = 1'b0;
  logic [11:0] rb_wr_addr = '0;
  logic [31:0] rb_wr_data = '0;
  logic        lease_valid_b;
  logic [31:0] lease_ip_b, lease_mask_b, lease_router_b, lease_server_b, lease_time_b, rb_rd_data;

  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(5)) u_src_b (
    .clk(clk), .tdata(sb_tdata), .tkeep(sb_tkeep), .tlast(sb_tlast), .tvalid(sb_tvalid), .tready(sb_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(9), .NAME("dhcp_b_tx")) u_sink_b (
    .clk(clk), .resetn(resetn), .tdata(mb_tdata), .tkeep(mb_tkeep), .tlast(mb_tlast), .tvalid(mb_tvalid),
    .tready(mb_tready));

  rtlnet_dhcp #(
    .MS_CYCLES(MS), .DHCP_BUF_KB(2), .RAM_STYLE("distributed"), .OFFER_TIMEOUT_MS(FIRST_MS),
    .RETRY_CAP_MS(CAP_MS), .MAX_TRIES(TRIES), .RENEW_RETRY_S(RETRY_S), .LEASE_MIN_S(LEASE_MIN)
  ) dut_b (
    .clk(clk), .resetn(resetn), .enable(1'b1),
    .s_axis_tdata(sb_tdata), .s_axis_tkeep(sb_tkeep), .s_axis_tvalid(sb_tvalid), .s_axis_tlast(sb_tlast),
    .s_axis_tready(sb_tready),
    .m_axis_tdata(mb_tdata), .m_axis_tkeep(mb_tkeep), .m_axis_tvalid(mb_tvalid), .m_axis_tlast(mb_tlast),
    .m_axis_tready(mb_tready),
    .local_mac(CLIENT_MAC), .local_ip(32'd0), .busy(busy_b),
    .reg_wr_en(rb_wr_en), .reg_wr_addr(rb_wr_addr), .reg_wr_data(rb_wr_data),
    .reg_rd_en(1'b0), .reg_rd_addr(12'd0), .reg_rd_data(rb_rd_data),
    .lease_valid(lease_valid_b), .lease_ip(lease_ip_b), .lease_mask(lease_mask_b), .lease_router(lease_router_b),
    .lease_server(lease_server_b), .lease_time_s(lease_time_b));

  rtlnet_tb_leaf_busy_monitor #(.NAME("dhcp_b")) u_busy_mon_b (
    .clk(clk), .resetn(resetn), .s_tvalid(sb_tvalid), .s_tready(sb_tready), .s_tlast(sb_tlast),
    .m_tvalid(mb_tvalid), .m_tready(mb_tready), .m_tlast(mb_tlast), .busy(busy_b));

  // DUT C: default parameters, never fed; register port only.
  logic        rc_rd_en = 1'b0;
  logic [11:0] rc_rd_addr = '0;
  logic [31:0] rc_rd_data;
  logic [63:0] mc_tdata;
  logic [7:0]  mc_tkeep;
  logic        mc_tvalid, mc_tlast, sc_tready, busy_c, lease_valid_c;
  logic [31:0] lc_ip, lc_mask, lc_router, lc_server, lc_time;

  rtlnet_dhcp dut_c (
    .clk(clk), .resetn(resetn), .enable(1'b1),
    .s_axis_tdata(64'd0), .s_axis_tkeep(8'd0), .s_axis_tvalid(1'b0), .s_axis_tlast(1'b0), .s_axis_tready(sc_tready),
    .m_axis_tdata(mc_tdata), .m_axis_tkeep(mc_tkeep), .m_axis_tvalid(mc_tvalid), .m_axis_tlast(mc_tlast),
    .m_axis_tready(1'b1),
    .local_mac(CLIENT_MAC), .local_ip(32'd0), .busy(busy_c),
    .reg_wr_en(1'b0), .reg_wr_addr(12'd0), .reg_wr_data(32'd0),
    .reg_rd_en(rc_rd_en), .reg_rd_addr(rc_rd_addr), .reg_rd_data(rc_rd_data),
    .lease_valid(lease_valid_c), .lease_ip(lc_ip), .lease_mask(lc_mask), .lease_router(lc_router),
    .lease_server(lc_server), .lease_time_s(lc_time));

  // ---------------------------------------------------------------------------
  // Run-wide monitors
  // ---------------------------------------------------------------------------
  // Start cycle of every frame DUT A sends (first beat accepted), in order.
  longint tx_start_q[$];
  bit     tx_in_frame = 0;
  always @(posedge clk) begin
    if (resetn && m_tvalid && m_tready) begin
      if (!tx_in_frame) tx_start_q.push_back(cyc);
      tx_in_frame = !m_tlast;
    end
  end

  // Lease outputs: change only while the bench expects a binding ACK, or with
  // the fall of lease_valid; all zero without a lease. DUT C never sends.
  bit          allow_change = 0;
  int          bundle_changes = 0;
  int          valid_falls = 0;
  int          mon_errors = 0;
  logic [159:0] prev_bundle = '0;
  logic         prev_valid = 1'b0;
  always @(posedge clk) begin
    if (resetn) begin
      if ({lease_ip, lease_mask, lease_router, lease_server, lease_time_s} !== prev_bundle) begin
        bundle_changes++;
        if (!allow_change && !(prev_valid && !lease_valid)) begin
          mon_errors++;
          tb_error($sformatf("lease outputs changed without a binding ACK or lease loss @%0d", cyc));
        end
      end
      if (prev_valid && !lease_valid) valid_falls++;
      if (!lease_valid && ({lease_ip, lease_mask, lease_router, lease_server, lease_time_s} !== '0) && mon_errors < 4) begin
        mon_errors++;
        tb_error("lease outputs not zero while lease_valid is 0");
      end
      if (sc_tready !== 1'b1 || mc_tvalid !== 1'b0 || busy_c !== 1'b0) begin
        if (mon_errors < 4) tb_error("DUT C (default parameters, never fed) was not quiet");
        mon_errors++;
      end
    end
    prev_bundle <= {lease_ip, lease_mask, lease_router, lease_server, lease_time_s};
    prev_valid  <= lease_valid;
  end

  // Watchdog.
  initial begin
    #900ms;
    tb_error("watchdog: bench did not finish");
    tb_verdict("tb_rtlnet_dhcp");
  end

  // ---------------------------------------------------------------------------
  // Register access (the wrapper's register bus timing)
  // ---------------------------------------------------------------------------
  task automatic reg_write(input bit [11:0] a, input bit [31:0] d);
    @(posedge clk);
    reg_wr_en   <= 1'b1;
    reg_wr_addr <= a;
    reg_wr_data <= d;
    @(posedge clk);
    reg_wr_en   <= 1'b0;
  endtask

  // reg_rd_en high for one clock; the data is sampled just after the next edge
  // (valid one clock after reg_rd_en) and must still hold one clock later.
  task automatic reg_read(input bit [11:0] a, output bit [31:0] d);
    bit [31:0] d2;
    @(posedge clk);
    reg_rd_en   <= 1'b1;
    reg_rd_addr <= a;
    @(posedge clk);
    reg_rd_en   <= 1'b0;
    #1;
    d = reg_rd_data;
    @(posedge clk);
    #1;
    d2 = reg_rd_data;
    if (d2 !== d) tb_error($sformatf("reg 0x%03h: read data did not hold (%08h then %08h)", a, d, d2));
  endtask

  task automatic reg_expect(input bit [11:0] a, input bit [31:0] exp, input string what);
    bit [31:0] d;
    reg_read(a, d);
    tb_check(d === exp, $sformatf("%s: reg 0x%03h = %08h, expected %08h", what, a, d, exp));
  endtask

  task automatic expect_state(input int st, input string what);
    bit [31:0] d;
    reg_read(R_STATUS, d);
    tb_check(d[2:0] == st, $sformatf("%s: state %0d, expected %0d", what, d[2:0], st));
  endtask

  task automatic ctrl(input bit [31:0] bits);
    reg_write(R_CTRL, bits);
  endtask

  // ---------------------------------------------------------------------------
  // Frame builders (wire order). Client frames are the expected output; server
  // frames are the stimulus.
  // ---------------------------------------------------------------------------
  function automatic void push_n(ref bytes_t q, input int n, input byte unsigned v = 8'h00);
    for (int i = 0; i < n; i++) q.push_back(v);
  endfunction

  function automatic void append(ref bytes_t q, input bytes_t t);
    for (int i = 0; i < $size(t); i++) q.push_back(t[i]);
  endfunction

  // Expected client frame (342 bytes): kind, xid, IP identification, ciaddr,
  // requested IP, server identifier, Ethernet destination.
  function automatic bytes_t client_frame(input int kind, input bit [31:0] xid, input bit [15:0] ident,
                                          input bit [31:0] ciaddr, input bit [31:0] req_ip,
                                          input bit [31:0] server, input bit [47:0] dmac);
    bytes_t b;
    bytes_t udp;
    bytes_t ip;
    bytes_t f;
    bit [31:0] sip;
    bit [31:0] dip;
    b.push_back(8'd1); b.push_back(8'd1); b.push_back(8'd6); b.push_back(8'd0);   // op, htype, hlen, hops
    push32(b, xid);
    push16(b, 16'd0);                                                             // secs
    push16(b, (kind == K_DISC || kind == K_SEL) ? 16'h8000 : 16'h0000);           // flags
    push32(b, (kind == K_REN || kind == K_REL) ? ciaddr : 32'd0);                 // ciaddr
    push_n(b, 12);                                                                // yiaddr, siaddr, giaddr
    push48(b, CLIENT_MAC); push_n(b, 10);                                         // chaddr
    push_n(b, 64 + 128);                                                          // sname, file
    push32(b, 32'h6382_5363);                                                     // cookie
    b.push_back(8'd53); b.push_back(8'd1);
    b.push_back((kind == K_DISC) ? 8'd1 : ((kind == K_REL) ? 8'd7 : 8'd3));
    b.push_back(8'd61); b.push_back(8'd7); b.push_back(8'd1); push48(b, CLIENT_MAC);
    if (kind == K_REL) push_n(b, 6);
    else begin
      b.push_back(8'd55); b.push_back(8'd4); b.push_back(8'd1); b.push_back(8'd3); b.push_back(8'd6); b.push_back(8'd51);
    end
    if (kind == K_SEL) begin b.push_back(8'd50); b.push_back(8'd4); push32(b, req_ip); end
    else push_n(b, 6);
    if (kind == K_SEL || kind == K_REL) begin b.push_back(8'd54); b.push_back(8'd4); push32(b, server); end
    else push_n(b, 6);
    b.push_back(8'd255);
    while (b.size() < 300) b.push_back(8'h00);
    push16(udp, 16'd68); push16(udp, 16'd67); push16(udp, 16'd308); push16(udp, 16'd0);
    append(udp, b);
    sip = (kind == K_REN || kind == K_REL) ? ciaddr : 32'd0;
    dip = (kind == K_REL) ? server : BCAST_IP;
    ip = ipv4_header(16'd328, ident, 8'd17, sip, dip, 8'd64, 16'h0000, 8'h00);
    f = eth_header(dmac, CLIENT_MAC, 16'h0800);
    append(f, ip);
    append(f, udp);
    return f;
  endfunction

  // Server frame description; opts are passed separately.
  typedef struct {
    bit [47:0] eth_dst;
    bit [47:0] eth_src;
    bit [15:0] ethertype;
    bit [7:0]  ver_ihl;
    bit [15:0] frag;
    bit [7:0]  proto;
    bit [31:0] ip_src;
    bit [31:0] ip_dst;
    bit [15:0] sport;
    bit [15:0] dport;
    bit [7:0]  op;
    bit [31:0] xid;
    bit [31:0] yiaddr;
    bit [47:0] chaddr;
    bit [31:0] cookie;
    int        bootp_min;     // zero padding after the options up to this many BOOTP bytes
    int        ip_len_adj;    // added to the IP total length (inconsistency tests)
    int        trunc;         // > 0: cut the frame to this many bytes
  } srv_t;

  function automatic srv_t srv_default(input bit [31:0] xid, input bit [31:0] yiaddr);
    srv_t s;
    s.eth_dst = BCAST_MAC; s.eth_src = SERVER_MAC; s.ethertype = 16'h0800; s.ver_ihl = 8'h45; s.frag = 16'h4000;
    s.proto = 8'd17; s.ip_src = SERVER_IP; s.ip_dst = BCAST_IP; s.sport = 16'd67; s.dport = 16'd68; s.op = 8'd2;
    s.xid = xid; s.yiaddr = yiaddr; s.chaddr = CLIENT_MAC; s.cookie = 32'h6382_5363; s.bootp_min = 300;
    s.ip_len_adj = 0; s.trunc = 0;
    return s;
  endfunction

  function automatic bytes_t srv_frame(input srv_t s, input bytes_t opts);
    bytes_t b;
    bytes_t udp;
    bytes_t ip;
    bytes_t f;
    bit [15:0] c;
    int tl;
    b.push_back(s.op); b.push_back(8'd1); b.push_back(8'd6); b.push_back(8'd0);
    push32(b, s.xid); push16(b, 16'd0); push16(b, 16'h8000);
    push32(b, 32'd0); push32(b, s.yiaddr); push32(b, SERVER_IP); push32(b, 32'd0);
    push48(b, s.chaddr); push_n(b, 10);
    push_n(b, 192);
    push32(b, s.cookie);
    append(b, opts);
    while (b.size() < s.bootp_min) b.push_back(8'h00);
    push16(udp, s.sport); push16(udp, s.dport); push16(udp, 16'(8 + b.size())); push16(udp, 16'd0);
    append(udp, b);
    if (s.ver_ihl == 8'h45) begin
      ip = ipv4_header(16'(20 + udp.size() + s.ip_len_adj), 16'h1234, s.proto, s.ip_src, s.ip_dst, 8'd128, s.frag);
    end else begin
      // IPv4 header with one option word (IHL 6): four NOP options.
      tl = 24 + udp.size() + s.ip_len_adj;
      ip.push_back(s.ver_ihl); ip.push_back(8'h00); push16(ip, 16'(tl)); push16(ip, 16'h1234); push16(ip, s.frag);
      ip.push_back(8'd128); ip.push_back(s.proto); push16(ip, 16'h0000); push32(ip, s.ip_src); push32(ip, s.ip_dst);
      push_n(ip, 4, 8'h01);
      c = inet_checksum(ip, 0, 24);
      ip[10] = c[15:8]; ip[11] = c[7:0];
    end
    f = eth_header(s.eth_dst, s.eth_src, s.ethertype);
    append(f, ip);
    append(f, udp);
    f = pad60(f);
    if (s.trunc > 0) begin
      while (f.size() > s.trunc) void'(f.pop_back());
    end
    return f;
  endfunction

  // Option helpers.
  function automatic bytes_t o_type(input byte unsigned t);
    bytes_t q;
    q.push_back(8'd53); q.push_back(8'd1); q.push_back(t);
    return q;
  endfunction

  function automatic bytes_t o_addr(input byte unsigned code, input bit [31:0] v);
    bytes_t q;
    q.push_back(code); q.push_back(8'd4); push32(q, v);
    return q;
  endfunction

  function automatic bytes_t o_raw(input byte unsigned code, input int len, input byte unsigned fill);
    bytes_t q;
    q.push_back(code); q.push_back(8'(len));
    for (int i = 0; i < len; i++) q.push_back(8'(fill + i));
    return q;
  endfunction

  function automatic bytes_t o_pad(input int n);
    bytes_t q;
    for (int i = 0; i < n; i++) q.push_back(8'd0);
    return q;
  endfunction

  function automatic bytes_t cat(input bytes_t a, input bytes_t b);
    bytes_t q;
    q = a;
    for (int i = 0; i < $size(b); i++) q.push_back(b[i]);
    return q;
  endfunction

  // A realistic home-router option set: type, server, lease, T1, T2, mask,
  // broadcast, router, two DNS servers, domain name, (ACK) host name, end.
  function automatic bytes_t router_opts(input byte unsigned t, input bit [31:0] lease, input bit [31:0] mask,
                                         input bit [31:0] router);
    bytes_t q;
    bytes_t d;
    q = o_type(t);
    q = cat(q, o_addr(8'd54, SERVER_IP));
    q = cat(q, o_addr(8'd51, lease));
    q = cat(q, o_addr(8'd58, lease >> 1));
    q = cat(q, o_addr(8'd59, (lease >> 3) * 7));
    q = cat(q, o_addr(8'd1, mask));
    q = cat(q, o_addr(8'd28, 32'h0A14_00FF));
    q = cat(q, o_addr(8'd3, router));
    d.push_back(8'd6); d.push_back(8'd8); push32(d, DNS_IP); push32(d, 32'h0808_0808);
    q = cat(q, d);
    d = {};
    d.push_back(8'd15); d.push_back(8'd8);
    d.push_back("h"); d.push_back("o"); d.push_back("m"); d.push_back("e"); d.push_back(".");
    d.push_back("l"); d.push_back("a"); d.push_back("n");
    q = cat(q, d);
    if (t == 8'd5) begin
      d = {};
      d.push_back(8'd12); d.push_back(8'd6);
      d.push_back("r"); d.push_back("t"); d.push_back("l"); d.push_back("n"); d.push_back("e"); d.push_back("t");
      q = cat(q, d);
    end
    q.push_back(8'd255);
    return q;
  endfunction

  // ---------------------------------------------------------------------------
  // Stream helpers
  // ---------------------------------------------------------------------------
  longint last_in_end = 0;
  bit [15:0] exp_ident = 16'd0;    // IP identification of the next client frame

  // Send like the wrapper: at least 16 idle clocks after the previous frame and
  // never while the leaf is busy.
  task automatic send(input bytes_t f);
    while ((cyc - last_in_end) < 17 || busy) @(posedge clk);
    u_src.send(f);
    last_in_end = cyc;
  endtask

  // Next frame DUT A sent, with the cycle its first beat was accepted.
  task automatic get_frame(output bytes_t f, output longint start, input int timeout, output bit ok);
    u_sink.get(f, timeout, ok);
    start = 0;
    if (ok && tx_start_q.size() > 0) start = tx_start_q.pop_front();
  endtask

  // Check one received client frame byte-exact; updates exp_ident.
  task automatic check_client(input bytes_t f, input int kind, input bit [31:0] xid, input bit [31:0] ciaddr,
                              input bit [31:0] req_ip, input bit [31:0] server, input bit [47:0] dmac,
                              input string what);
    bytes_t e;
    string why;
    bit same;
    e = client_frame(kind, xid, exp_ident, ciaddr, req_ip, server, dmac);
    same = bytes_equal(f, e, why);
    tb_check(same, {what, ": ", why});
    tb_check(f.size() == FRAME_LEN, $sformatf("%s: length %0d", what, f.size()));
    if (f.size() >= 34) tb_check(inet_sum(f, 14, 20) == 16'hFFFF, {what, ": IPv4 header checksum does not fold to 0xFFFF"});
    exp_ident++;
  endtask

  // Wait for one client frame of a kind; returns its xid.
  task automatic expect_client(input int kind, input bit [31:0] ciaddr, input bit [31:0] req_ip,
                               input bit [31:0] server, input bit [47:0] dmac, input int timeout,
                               output bit [31:0] xid, output longint start, input string what);
    bytes_t f;
    bit ok;
    get_frame(f, start, timeout, ok);
    tb_check(ok, {what, ": no frame"});
    xid = 0;
    if (ok && f.size() >= 50) begin
      xid = get32(f, 46);
      check_client(f, kind, xid, ciaddr, req_ip, server, dmac, what);
    end
  endtask

  task automatic expect_silence(input int cycles, input string what);
    bit none;
    u_sink.expect_none(cycles, none);
    tb_check(none, {what, ": unexpected frame"});
    if (!none) begin
      bytes_t f;
      bit ok;
      longint t;
      while (u_sink.frames.size() > 0) begin
        get_frame(f, t, 1, ok);
        exp_ident++;
      end
    end
  endtask

  task automatic wait_cycles(input longint n);
    repeat (n) @(posedge clk);
  endtask

  // One full acquisition on DUT A: START, DISCOVER, OFFER, REQUEST, ACK.
  // Returns the xid used. The ACK is sent with allow_change set.
  task automatic acquire(input bytes_t offer_opts, input bytes_t ack_opts, input bit [31:0] yi,
                         input bit [31:0] exp_server, output bit [31:0] xid, input string what);
    bit [31:0] x2;
    longint t;
    srv_t s;
    ctrl(C_START);
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 200, xid, t, {what, " DISCOVER"});
    s = srv_default(xid, yi);
    send(srv_frame(s, offer_opts));
    expect_client(K_SEL, 0, yi, exp_server, BCAST_MAC, 3000, x2, t, {what, " REQUEST"});
    tb_check(x2 == xid, {what, ": REQUEST xid differs from the DISCOVER's"});
    allow_change = 1;
    send(srv_frame(s, ack_opts));
    wait_cycles(1500);
    allow_change = 0;
  endtask

  task automatic expect_lease(input bit valid, input bit [31:0] ip, input bit [31:0] mask, input bit [31:0] router,
                              input bit [31:0] server, input bit [31:0] lt, input string what);
    tb_check(lease_valid === valid, $sformatf("%s: lease_valid %0b", what, lease_valid));
    tb_check(lease_ip === ip, $sformatf("%s: lease_ip %08h, expected %08h", what, lease_ip, ip));
    tb_check(lease_mask === mask, $sformatf("%s: lease_mask %08h, expected %08h", what, lease_mask, mask));
    tb_check(lease_router === router, $sformatf("%s: lease_router %08h, expected %08h", what, lease_router, router));
    tb_check(lease_server === server, $sformatf("%s: lease_server %08h, expected %08h", what, lease_server, server));
    tb_check(lease_time_s === lt, $sformatf("%s: lease_time_s %0d, expected %0d", what, lease_time_s, lt));
    reg_expect(R_IP, ip, {what, " LEASE_IP"});
    reg_expect(R_MASK, mask, {what, " LEASE_MASK"});
    reg_expect(R_ROUTER, router, {what, " LEASE_ROUTER"});
    reg_expect(R_SERVER, server, {what, " LEASE_SERVER"});
    reg_expect(R_TIME, lt, {what, " LEASE_TIME_S"});
  endtask

  // Return DUT A to INIT with no lease and no frame in flight.
  task automatic quiesce(input string what);
    ctrl(C_STOP);
    wait_cycles(300);
    while (u_sink.frames.size() > 0) begin
      bytes_t f;
      bit ok;
      longint t;
      get_frame(f, t, 1, ok);
      exp_ident++;
    end
    expect_state(ST_INIT, {what, " quiesce"});
  endtask

  // ---------------------------------------------------------------------------
  // Case 1: register map
  // ---------------------------------------------------------------------------
  task automatic case_registers();
    bit [31:0] d;
    reg_expect(R_ID, 32'h4448_4350, "ID");
    reg_expect(R_VERSION, 32'h1022_2026, "VERSION");
    reg_expect(R_CAPS, 32'h0001_0501, "CAPS (1 KiB, 5 tries, release)");
    reg_expect(R_CTRL, 32'h0, "CTRL after reset");
    reg_expect(R_STATUS, 32'h0001_0000, "STATUS after reset (INIT, enabled)");
    ctrl(C_AUTO);
    reg_expect(R_CTRL, C_AUTO, "CTRL AUTO readback");
    ctrl(C_AUTO | C_CLEAR);
    reg_expect(R_CTRL, C_AUTO, "CTRL pulse bits read 0");
    ctrl(32'h0);
    reg_expect(R_CTRL, 32'h0, "CTRL AUTO cleared");
    reg_expect(12'h04C, 32'h0, "undefined 0x04C");
    reg_expect(12'h100, 32'h0, "undefined 0x100");
    reg_expect(12'hFFC, 32'h0, "undefined 0xFFC");
    reg_write(R_ID, 32'hDEAD_BEEF);
    reg_write(R_IP, 32'h1234_5678);
    reg_write(R_DISC, 32'h55);
    reg_expect(R_ID, 32'h4448_4350, "ID after a write");
    reg_expect(R_IP, 32'h0, "LEASE_IP after a write");
    reg_expect(R_DISC, 32'h0, "DISCOVERS_SENT after a write");
    reg_expect(R_XID, 32'h0, "XID after reset");
    expect_silence(500, "register case");
    // Read latency exactly one clock: the value of a new address is present
    // right after the edge that follows reg_rd_en and not before it.
    @(posedge clk);
    reg_rd_en <= 1'b1; reg_rd_addr <= R_VERSION;
    @(posedge clk);
    reg_rd_en <= 1'b1; reg_rd_addr <= R_ID;
    #1 d = reg_rd_data;
    tb_check(d == 32'h1022_2026, "read latency: VERSION one clock after its reg_rd_en");
    @(posedge clk);
    reg_rd_en <= 1'b0;
    #1 d = reg_rd_data;
    tb_check(d == 32'h4448_4350, "read latency: ID one clock after its reg_rd_en");
    // DUT C (defaults): CAPS 1 KiB, 5 tries.
    @(posedge clk);
    rc_rd_en <= 1'b1; rc_rd_addr <= R_CAPS;
    @(posedge clk);
    rc_rd_en <= 1'b0;
    #1 tb_check(rc_rd_data == 32'h0001_0501, $sformatf("DUT C CAPS %08h", rc_rd_data));
  endtask

  // ---------------------------------------------------------------------------
  // Case 2: acquisition with the realistic option set, broadcast then unicast
  // ---------------------------------------------------------------------------
  task automatic case_acquire();
    bit [31:0] xid;
    bit [31:0] xid2;
    bit [31:0] d;
    srv_t s;
    longint t;
    acquire(router_opts(8'd2, LONG_LEASE, MASK_24, ROUTER_IP), router_opts(8'd5, LONG_LEASE, MASK_24, ROUTER_IP),
            OFFER_IP, SERVER_IP, xid, "acq broadcast");
    expect_lease(1, OFFER_IP, MASK_24, ROUTER_IP, SERVER_IP, LONG_LEASE, "acq broadcast");
    expect_state(ST_BOUND, "acq broadcast");
    reg_expect(R_XID, xid, "XID register");
    reg_expect(R_DISC, 1, "DISCOVERS_SENT");
    reg_expect(R_OFFERS, 1, "OFFERS_RX");
    reg_expect(R_REQS, 1, "REQUESTS_SENT");
    reg_expect(R_ACKS, 1, "ACKS_RX");
    reg_expect(R_NAKS, 0, "NAKS_RX");
    reg_expect(R_LOST, 0, "LEASES_LOST");
    reg_read(R_STATUS, d);
    tb_check(d[8] == 1 && d[9] == 0, "STATUS bound 1 fail 0");
    tb_check(bundle_changes == 1, $sformatf("lease outputs changed %0d times on one ACK", bundle_changes));
    wait_cycles(3 * SEC);
    reg_read(R_ELAPSED, d);
    tb_check(d == 3, $sformatf("LEASE_ELAPSED_S %0d after 3 s", d));
    expect_silence(100, "bound with a 1-day lease");
    // A second acquisition while bound, server frames unicast to the offered
    // address and MAC: START keeps the lease until the new ACK, which reloads it.
    ctrl(C_START);
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 200, xid2, t, "acq unicast DISCOVER");
    tb_check(xid2 != xid, "START takes a new xid");
    tb_check(lease_valid == 1, "START keeps the lease valid");
    s = srv_default(xid2, OFFER_IP2);
    s.eth_dst = CLIENT_MAC;
    s.ip_dst = OFFER_IP2;
    s.ip_src = SERVER_IP2;
    send(srv_frame(s, cat(o_type(8'd2), cat(o_addr(8'd54, SERVER_IP2), cat(o_addr(8'd51, 32'd7200),
                       cat(o_addr(8'd1, MASK_16), cat(o_addr(8'd3, ROUTER_IP2), o_pad(0))))))));
    // (no end option above: the OFFER is ignored; the retransmitted DISCOVER follows)
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, FIRST_MS * MS + 2 * MS, xid, t, "OFFER without end option ignored");
    tb_check(xid == xid2, "retransmission keeps the xid");
    send(srv_frame(s, cat(o_type(8'd2), cat(o_addr(8'd54, SERVER_IP2), cat(o_addr(8'd51, 32'd7200),
                       cat(o_addr(8'd1, MASK_16), cat(o_addr(8'd3, ROUTER_IP2), o_pad(1))))))
                   ));
    expect_silence(1200, "second OFFER without end option ignored");
    begin
      bytes_t opts;
      opts = cat(o_type(8'd2), cat(o_addr(8'd54, SERVER_IP2), cat(o_addr(8'd51, 32'd7200),
                 cat(o_addr(8'd1, MASK_16), o_addr(8'd3, ROUTER_IP2)))));
      opts.push_back(8'd255);
      send(srv_frame(s, opts));
      expect_client(K_SEL, 0, OFFER_IP2, SERVER_IP2, BCAST_MAC, 3000, xid, t, "acq unicast REQUEST");
      opts[2] = 8'd5;
      allow_change = 1;
      send(srv_frame(s, opts));
      wait_cycles(1500);
      allow_change = 0;
    end
    expect_lease(1, OFFER_IP2, MASK_16, ROUTER_IP2, SERVER_IP2, 32'd7200, "acq unicast");
    tb_check(valid_falls == 0, "no lease loss in the acquisition cases");
    quiesce("acq");
  endtask

  // ---------------------------------------------------------------------------
  // Case 3: retransmission and backoff
  // ---------------------------------------------------------------------------
  task automatic case_retransmit();
    bit [31:0] xid;
    bit [31:0] x;
    longint t0;
    longint t;
    int waits[5];
    srv_t s;
    waits[0] = FIRST_MS; waits[1] = 2 * FIRST_MS; waits[2] = CAP_MS; waits[3] = CAP_MS; waits[4] = CAP_MS;
    ctrl(C_CLEAR);
    ctrl(C_START);
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 200, xid, t0, "retx DISCOVER 1");
    for (int i = 1; i < TRIES; i++) begin
      expect_client(K_DISC, 0, 0, 0, BCAST_MAC, (waits[i-1] + 2) * MS, x, t, $sformatf("retx DISCOVER %0d", i + 1));
      tb_check(x == xid, $sformatf("retx DISCOVER %0d keeps the xid", i + 1));
      tb_check((t - t0) >= (waits[i-1] - 1) * MS && (t - t0) <= (waits[i-1] + 1) * MS + 10,
               $sformatf("retx DISCOVER %0d spacing %0d clocks, expected %0d ms", i + 1, t - t0, waits[i-1]));
      t0 = t;
    end
    expect_silence((CAP_MS - 2) * MS, "after the last DISCOVER");
    wait_cycles(4 * MS);
    expect_state(ST_FAIL, "DISCOVER tries exhausted");
    begin
      bit [31:0] d;
      reg_read(R_STATUS, d);
      tb_check(d[9] == 1 && d[8] == 0, "STATUS fail 1 bound 0");
    end
    expect_silence(2 * CAP_MS * MS, "FAIL is silent");
    reg_expect(R_DISC, TRIES, "DISCOVERS_SENT after the tries");
    // REQUEST retransmission: OFFER answered, then no ACK.
    ctrl(C_START);
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 200, x, t, "retx restart DISCOVER");
    tb_check(x != xid, "restart after FAIL takes a new xid");
    expect_state(ST_SEL, "restart after FAIL");
    xid = x;
    s = srv_default(xid, OFFER_IP);
    send(srv_frame(s, router_opts(8'd2, LONG_LEASE, MASK_24, ROUTER_IP)));
    expect_client(K_SEL, 0, OFFER_IP, SERVER_IP, BCAST_MAC, 3000, x, t0, "retx REQUEST 1");
    for (int i = 1; i < TRIES; i++) begin
      expect_client(K_SEL, 0, OFFER_IP, SERVER_IP, BCAST_MAC, (waits[i-1] + 2) * MS, x, t,
                    $sformatf("retx REQUEST %0d", i + 1));
      tb_check(x == xid, $sformatf("retx REQUEST %0d keeps the xid", i + 1));
      tb_check((t - t0) >= (waits[i-1] - 1) * MS && (t - t0) <= (waits[i-1] + 1) * MS + 10,
               $sformatf("retx REQUEST %0d spacing %0d clocks", i + 1, t - t0));
      t0 = t;
    end
    expect_silence((CAP_MS + 4) * MS, "after the last REQUEST");
    expect_state(ST_FAIL, "REQUEST tries exhausted");
    reg_expect(R_REQS, TRIES, "REQUESTS_SENT after the tries");
    tb_check(lease_valid == 0, "no lease after FAIL");
    quiesce("retx");
  endtask

  // ---------------------------------------------------------------------------
  // Case 4: NAK handling
  // ---------------------------------------------------------------------------
  task automatic case_nak();
    bit [31:0] xid;
    bit [31:0] x;
    bit [31:0] prev;
    longint t;
    srv_t s;
    int falls0;
    falls0 = valid_falls;
    ctrl(C_CLEAR);
    ctrl(C_START);
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 200, xid, t, "nak DISCOVER");
    for (int n = 1; n <= TRIES; n++) begin
      s = srv_default(xid, OFFER_IP);
      send(srv_frame(s, router_opts(8'd2, LONG_LEASE, MASK_24, ROUTER_IP)));
      expect_client(K_SEL, 0, OFFER_IP, SERVER_IP, BCAST_MAC, 3000, x, t, $sformatf("nak REQUEST %0d", n));
      if (n == 1) begin
        // A NAK with another xid is ignored.
        s.xid = xid ^ 32'h0000_0100;
        send(srv_frame(s, cat(o_type(8'd6), cat(o_addr(8'd54, SERVER_IP), o_raw(8'd255, 0, 0)))));
        expect_silence(800, "NAK with a wrong xid ignored");
        expect_state(ST_REQ, "NAK with a wrong xid ignored");
        s.xid = xid;
      end
      begin
        bytes_t nak;
        nak = cat(o_type(8'd6), o_addr(8'd54, SERVER_IP));
        nak.push_back(8'd56); nak.push_back(8'd4); nak.push_back("n"); nak.push_back("o"); nak.push_back("p"); nak.push_back("e");
        nak.push_back(8'd255);
        send(srv_frame(s, nak));
      end
      if (n < TRIES) begin
        prev = xid;
        expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 3000, xid, t, $sformatf("DISCOVER after NAK %0d", n));
        tb_check(xid != prev, $sformatf("NAK %0d: new xid", n));
      end
    end
    expect_silence(400, "after the last NAK");
    expect_state(ST_FAIL, "MAX_TRIES NAKs");
    reg_expect(R_NAKS, TRIES, "NAKS_RX");
    reg_expect(R_LOST, 0, "a NAK while requesting loses no lease");
    tb_check(valid_falls == falls0, "no lease_valid fall in the NAK case");
    quiesce("nak");
  endtask

  // ---------------------------------------------------------------------------
  // Case 5: ignored frames; each is followed by a good OFFER that is answered.
  // ---------------------------------------------------------------------------
  int ignored_cases = 0;

  task automatic ignored_one(input int which);
    bit [31:0] xid;
    bit [31:0] x;
    bit [31:0] offers_before;
    longint t;
    srv_t s;
    srv_t g;
    bytes_t opts;
    bytes_t bad;
    string name;
    bit skip_proof;
    skip_proof = 0;
    ctrl(C_START);
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 200, xid, t, $sformatf("ignored %0d DISCOVER", which));
    reg_read(R_OFFERS, offers_before);
    s = srv_default(xid, OFFER_IP);
    opts = router_opts(8'd2, LONG_LEASE, MASK_24, ROUTER_IP);
    case (which)
      0:  begin name = "wrong xid high"; s.xid = xid ^ 32'h8000_0000; end
      1:  begin name = "wrong xid low"; s.xid = xid ^ 32'h0000_0001; end
      2:  begin name = "wrong chaddr first octet"; s.chaddr = CLIENT_MAC ^ 48'h01_00_00_00_00_00; end
      3:  begin name = "wrong chaddr last octet"; s.chaddr = OTHER_MAC; end
      4:  begin name = "UDP source port 1067"; s.sport = 16'd1067; end
      5:  begin name = "UDP destination port 69"; s.dport = 16'd69; end
      6:  begin name = "BOOTP op 1"; s.op = 8'd1; end
      7:  begin name = "cookie byte 278"; s.cookie = 32'h6282_5363; end
      8:  begin name = "cookie byte 281"; s.cookie = 32'h6382_5362; end
      9:  begin name = "IP MF set"; s.frag = 16'h2000; end
      10: begin name = "IP fragment offset"; s.frag = 16'h0001; end
      11: begin name = "IHL 6"; s.ver_ihl = 8'h46; end
      12: begin name = "protocol TCP"; s.proto = 8'd6; end
      13: begin name = "EtherType ARP"; s.ethertype = 16'h0806; end
      14: begin name = "EtherType IPv6"; s.ethertype = 16'h86DD; end
      15: begin name = "other unicast MAC"; s.eth_dst = OTHER_MAC; end
      16: begin name = "ACK while selecting"; opts[2] = 8'd5; end
      17: begin name = "OFFER without option 54"; opts = cat(o_type(8'd2), o_addr(8'd51, LONG_LEASE)); opts.push_back(8'd255); end
      18: begin name = "no option 53"; opts = cat(o_addr(8'd54, SERVER_IP), o_addr(8'd51, LONG_LEASE)); opts.push_back(8'd255); end
      19: begin name = "no end option"; void'(opts.pop_back()); s.bootp_min = 0; end
      20: begin name = "option past the datagram"; void'(opts.pop_back()); opts.push_back(8'd43); opts.push_back(8'd200); s.bootp_min = 0; end
      21: begin name = "IP total length past the frame"; s.ip_len_adj = 40; end
      22: begin name = "frame longer than the RAM"; s.bootp_min = 1100 - 42; end
      23: begin name = "leaf disabled"; end
      24: begin name = "ARP frame"; end
      25: begin name = "ICMP echo frame"; end
      26: begin name = "stale end option behind a cut frame"; end
      27: begin name = "frame overlapping a busy parse"; end
      28: begin name = "cut frame (tlast before the cookie)"; s.trunc = 200; end
      default: name = "?";
    endcase
    case (which)
      23: begin
        enable = 1'b0;
        send(srv_frame(s, opts));
        expect_silence(1000, "leaf disabled: OFFER");
        enable = 1'b1;
      end
      24: begin
        bad = eth_header(BCAST_MAC, SERVER_MAC, 16'h0806);
        push16(bad, 16'd1); push16(bad, 16'h0800); bad.push_back(8'd6); bad.push_back(8'd4); push16(bad, 16'd1);
        push48(bad, SERVER_MAC); push32(bad, SERVER_IP); push48(bad, 48'd0); push32(bad, OFFER_IP);
        send(pad60(bad));
      end
      25: begin
        bytes_t pl;
        bytes_t icmp;
        bit [15:0] c;
        push_n(pl, 32, 8'hA5);
        icmp.push_back(8'd8); icmp.push_back(8'd0); push16(icmp, 16'd0); push16(icmp, 16'd7); push16(icmp, 16'd1);
        append(icmp, pl);
        c = inet_checksum(icmp, 0, icmp.size());
        icmp[2] = c[15:8]; icmp[3] = c[7:0];
        bad = eth_header(CLIENT_MAC, SERVER_MAC, 16'h0800);
        append(bad, ipv4_header(16'(20 + icmp.size()), 16'h55, 8'd1, SERVER_IP, OFFER_IP));
        append(bad, icmp);
        send(pad60(bad));
      end
      26: begin
        // Frame A: wrong xid, long, with an end option near its end; frame B:
        // the right xid, shorter, no end option inside its IP datagram. The RAM
        // still holds A's end option behind B's last byte.
        srv_t a;
        bytes_t oa;
        a = s;
        a.xid = xid ^ 32'h00FF_0000;
        oa = cat(o_type(8'd2), o_addr(8'd54, SERVER_IP));
        oa = cat(oa, o_pad(560));
        oa.push_back(8'd255);
        send(srv_frame(a, oa));
        bad = srv_frame(s, cat(o_type(8'd2), cat(o_addr(8'd54, SERVER_IP), o_addr(8'd51, LONG_LEASE))));
        send(bad);
      end
      27: begin
        // A wrong-xid OFFER with a long option list keeps the walk busy; a good
        // OFFER started 20 clocks after its last beat (breaking the wrapper's
        // busy rule) must be ignored whole.
        srv_t a;
        bytes_t oa;
        a = s;
        a.xid = xid ^ 32'h0000_8000;
        oa = cat(o_type(8'd2), o_addr(8'd54, SERVER_IP));
        oa = cat(oa, o_pad(200));
        oa.push_back(8'd255);
        while ((cyc - last_in_end) < 17 || busy) @(posedge clk);
        u_src.send(srv_frame(a, oa));
        repeat (20) @(posedge clk);
        tb_check(busy === 1'b1, "overlap: the leaf is still busy parsing");
        u_src.send(srv_frame(s, opts));
        last_in_end = cyc;
      end
      default: begin
        send(srv_frame(s, opts));
      end
    endcase
    expect_silence(1000, {"ignored: ", name});
    expect_state(ST_SEL, {"ignored: ", name, " (state)"});
    reg_expect(R_OFFERS, offers_before, {"ignored: ", name, " (OFFERS_RX)"});
    // Proof the client still waits: the good OFFER is answered.
    g = srv_default(xid, OFFER_IP);
    send(srv_frame(g, router_opts(8'd2, LONG_LEASE, MASK_24, ROUTER_IP)));
    expect_client(K_SEL, 0, OFFER_IP, SERVER_IP, BCAST_MAC, 3000, x, t, {"after ignored: ", name});
    tb_check(x == xid, {"after ignored: ", name, " xid"});
    ignored_cases++;
    quiesce(name);
  endtask

  task automatic case_ignored();
    for (int i = 0; i <= 28; i++) ignored_one(i);
    tb_check(ignored_cases == 29, $sformatf("ignored cases run %0d", ignored_cases));
  endtask

  // ---------------------------------------------------------------------------
  // Case 6: option parsing
  // ---------------------------------------------------------------------------
  task automatic opt_case(input bytes_t offer, input bytes_t ack, input bit [31:0] mask, input bit [31:0] router,
                          input bit [31:0] server, input bit [31:0] lt, input string what);
    bit [31:0] xid;
    acquire(offer, ack, OFFER_IP, SERVER_IP, xid, what);
    expect_lease(1, OFFER_IP, mask, router, server, lt, what);
    expect_state(ST_BOUND, what);
    quiesce(what);
    // The release goes to the bound server; quiesce drained it.
  endtask

  task automatic case_options();
    bytes_t o;
    bytes_t a;
    bytes_t d;
    // Pad runs before the first option and between options, at every beat
    // alignment of the following option code.
    for (int k = 0; k < 8; k++) begin
      o = cat(o_pad(k), cat(o_type(8'd2), cat(o_pad((k + 3) % 8), cat(o_addr(8'd54, SERVER_IP),
          cat(o_pad(7 - k), cat(o_addr(8'd51, 32'd3000), cat(o_pad(k), cat(o_addr(8'd1, MASK_24),
          cat(o_pad(1), o_addr(8'd3, ROUTER_IP))))))))));
      o.push_back(8'd255);
      a = o;
      a[k + 2] = 8'd5;
      opt_case(o, a, MASK_24, ROUTER_IP, SERVER_IP, 32'd3000, $sformatf("pad alignment %0d", k));
    end
    // Reordered options, unknown long options, a zero-length option, two routers.
    o = cat(o_raw(8'd43, 40, 8'h10), cat(o_addr(8'd3, ROUTER_IP2), cat(o_raw(8'd99, 0, 0), cat(o_addr(8'd1, MASK_16),
        cat(o_addr(8'd51, 32'd5000), cat(o_addr(8'd54, SERVER_IP), o_type(8'd2)))))));
    d = {};
    d.push_back(8'd3); d.push_back(8'd8); push32(d, ROUTER_IP); push32(d, ROUTER_IP2);
    a = cat(o_raw(8'd43, 40, 8'h10), cat(d, cat(o_raw(8'd99, 0, 0), cat(o_addr(8'd1, MASK_16),
        cat(o_addr(8'd51, 32'd5000), cat(o_addr(8'd54, SERVER_IP), o_type(8'd5)))))));
    o.push_back(8'd255); a.push_back(8'd255);
    opt_case(o, a, MASK_16, ROUTER_IP, SERVER_IP, 32'd5000, "reordered, unknown, zero-length, two routers");
    // Repeated options: the later one wins; a too-short lease option is skipped.
    o = cat(o_type(8'd2), o_addr(8'd54, SERVER_IP));
    o.push_back(8'd255);
    a = cat(o_type(8'd1), cat(o_addr(8'd1, MASK_16), cat(o_addr(8'd1, MASK_24), cat(o_raw(8'd51, 3, 8'h01),
        cat(o_addr(8'd51, 32'd6000), cat(o_raw(8'd51, 2, 8'h07), o_type(8'd5)))))));
    a.push_back(8'd255);
    opt_case(o, a, MASK_24, 32'd0, SERVER_IP, 32'd6000, "repeated options, short option, missing router");
    // Missing mask, router, lease time and server identifier in the ACK: mask
    // and router 0, lease 3600 s, server from the OFFER.
    o = cat(o_type(8'd2), o_addr(8'd54, SERVER_IP));
    o.push_back(8'd255);
    a = o_type(8'd5);
    a.push_back(8'd255);
    opt_case(o, a, 32'd0, 32'd0, SERVER_IP, 32'd3600, "missing options");
    // Option 53 longer than 1 (first byte taken); end option on the last byte
    // of the IP datagram (no BOOTP padding).
    begin
      bit [31:0] xid;
      bit [31:0] x;
      longint t;
      srv_t s;
      ctrl(C_START);
      expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 200, xid, t, "exact end DISCOVER");
      s = srv_default(xid, OFFER_IP);
      s.bootp_min = 0;
      o = cat(o_raw(8'd53, 2, 8'd2), o_addr(8'd54, SERVER_IP));
      o.push_back(8'd255);
      send(srv_frame(s, o));
      expect_client(K_SEL, 0, OFFER_IP, SERVER_IP, BCAST_MAC, 3000, x, t, "end option on the last datagram byte");
      // Short lease raised to LEASE_MIN_S.
      a = cat(o_type(8'd5), cat(o_addr(8'd54, SERVER_IP), o_addr(8'd51, 32'd2)));
      a.push_back(8'd255);
      allow_change = 1;
      send(srv_frame(s, a));
      wait_cycles(1500);
      allow_change = 0;
      expect_lease(1, OFFER_IP, 32'd0, 32'd0, SERVER_IP, LEASE_MIN, "lease 2 s raised to LEASE_MIN_S");
      quiesce("exact end");
    end
  endtask

  // ---------------------------------------------------------------------------
  // Case 7: renewal, expiry, NAK while renewing, RENEW_NOW, START while bound
  // ---------------------------------------------------------------------------
  task automatic case_renew();
    bit [31:0] xid;
    bit [31:0] rx;
    bit [31:0] x;
    longint t_ack;
    longint t;
    srv_t s;
    bytes_t a;
    int lost0;
    int falls0;
    ctrl(C_CLEAR);
    falls0 = valid_falls;
    // Lease 13 s: T1 at 6 s, retries at 8, 10, 12 s, expiry at 13 s.
    acquire(router_opts(8'd2, 32'd13, MASK_24, ROUTER_IP), router_opts(8'd5, 32'd13, MASK_24, ROUTER_IP),
            OFFER_IP, SERVER_IP, xid, "renew acquisition");
    t_ack = cyc - 1500;
    expect_lease(1, OFFER_IP, MASK_24, ROUTER_IP, SERVER_IP, 32'd13, "lease 13 s");
    expect_client(K_REN, OFFER_IP, 0, 0, BCAST_MAC, 7 * SEC, rx, t, "renew REQUEST at T1");
    tb_check((t - t_ack) >= 6 * SEC - 2 * MS && (t - t_ack) <= 6 * SEC + 2 * MS + 1600,
             $sformatf("renew at %0d clocks after the ACK, expected 6 s", t - t_ack));
    tb_check(rx != xid, "renewal takes a new xid");
    expect_state(ST_RENEW, "after T1");
    tb_check(lease_valid == 1, "renewing keeps the lease");
    for (int i = 0; i < 3; i++) begin
      expect_client(K_REN, OFFER_IP, 0, 0, BCAST_MAC, RETRY_S * SEC + 4 * MS, x, t, $sformatf("renew retry %0d", i + 1));
      tb_check(x == rx, $sformatf("renew retry %0d keeps the xid", i + 1));
    end
    // Expiry at 13 s: lease_valid falls, a DISCOVER follows with a new xid.
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, SEC + 4 * MS, x, t, "DISCOVER after expiry");
    tb_check((t - t_ack) >= 13 * SEC - 2 * MS && (t - t_ack) <= 13 * SEC + 2 * MS + 1600,
             $sformatf("expiry at %0d clocks after the ACK", t - t_ack));
    tb_check(x != rx, "DISCOVER after expiry has a new xid");
    tb_check(lease_valid == 0, "lease_valid fell at expiry");
    tb_check(valid_falls == falls0 + 1, "exactly one lease_valid fall at expiry");
    reg_expect(R_LOST, 1, "LEASES_LOST after expiry");
    expect_lease(0, 0, 0, 0, 0, 0, "after expiry");
    // New lease 13 s; renew ACK at T1 with a 21 s lease and new mask/router.
    xid = x;
    s = srv_default(xid, OFFER_IP);
    send(srv_frame(s, router_opts(8'd2, 32'd13, MASK_24, ROUTER_IP)));
    expect_client(K_SEL, 0, OFFER_IP, SERVER_IP, BCAST_MAC, 3000, x, t, "re-acquire REQUEST");
    allow_change = 1;
    send(srv_frame(s, router_opts(8'd5, 32'd13, MASK_24, ROUTER_IP)));
    wait_cycles(1500);
    allow_change = 0;
    t_ack = cyc - 1500;
    expect_client(K_REN, OFFER_IP, 0, 0, BCAST_MAC, 7 * SEC, rx, t, "second renew REQUEST");
    s = srv_default(rx, OFFER_IP);
    s.eth_dst = CLIENT_MAC;
    s.ip_dst = OFFER_IP;
    allow_change = 1;
    send(srv_frame(s, router_opts(8'd5, 32'd21, MASK_16, ROUTER_IP2)));
    wait_cycles(1500);
    allow_change = 0;
    t_ack = cyc - 1500;
    expect_lease(1, OFFER_IP, MASK_16, ROUTER_IP2, SERVER_IP, 32'd21, "renew ACK reloads");
    expect_state(ST_BOUND, "renew ACK");
    tb_check(valid_falls == falls0 + 1, "renew ACK: no lease_valid fall");
    reg_expect(R_ELAPSED, 0, "LEASE_ELAPSED_S restarts at the renew ACK");
    // T1 of the new lease at 10 s; answer with a NAK: the lease is lost.
    expect_client(K_REN, OFFER_IP, 0, 0, BCAST_MAC, 11 * SEC, rx, t, "third renew REQUEST");
    tb_check((t - t_ack) >= 10 * SEC - 2 * MS && (t - t_ack) <= 10 * SEC + 2 * MS + 1600,
             $sformatf("second T1 at %0d clocks", t - t_ack));
    s = srv_default(rx, OFFER_IP);
    a = cat(o_type(8'd6), o_addr(8'd54, SERVER_IP));
    a.push_back(8'd255);
    send(srv_frame(s, a));
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 3000, x, t, "DISCOVER after NAK while renewing");
    tb_check(lease_valid == 0, "NAK while renewing drops the lease");
    tb_check(valid_falls == falls0 + 2, "one more lease_valid fall for the NAK");
    reg_expect(R_LOST, 2, "LEASES_LOST after the renewing NAK");
    reg_expect(R_NAKS, 1, "NAKS_RX after the renewing NAK");
    expect_state(ST_SEL, "after the renewing NAK");
    quiesce("renew 1");
    // RENEW_NOW while bound.
    acquire(router_opts(8'd2, LONG_LEASE, MASK_24, ROUTER_IP), router_opts(8'd5, LONG_LEASE, MASK_24, ROUTER_IP),
            OFFER_IP, SERVER_IP, xid, "renew-now acquisition");
    ctrl(C_RENEW);
    expect_client(K_REN, OFFER_IP, 0, 0, BCAST_MAC, 200, rx, t, "RENEW_NOW REQUEST");
    expect_state(ST_RENEW, "RENEW_NOW");
    s = srv_default(rx, OFFER_IP);
    allow_change = 1;
    send(srv_frame(s, router_opts(8'd5, LONG_LEASE, MASK_24, ROUTER_IP)));
    wait_cycles(1500);
    allow_change = 0;
    expect_state(ST_BOUND, "ACK to RENEW_NOW");
    quiesce("renew now");
    // START while bound: the lease stays until it runs out in SELECTING.
    lost0 = valid_falls;
    acquire(router_opts(8'd2, 32'd9, MASK_24, ROUTER_IP), router_opts(8'd5, 32'd9, MASK_24, ROUTER_IP),
            OFFER_IP, SERVER_IP, xid, "start-while-bound acquisition");
    t_ack = cyc - 1500;
    wait_cycles(SEC);
    ctrl(C_START);
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 200, x, t, "START while bound");
    tb_check(lease_valid == 1, "START while bound keeps lease_valid");
    tb_check(valid_falls == lost0, "no lease_valid fall on START");
    // No server: DISCOVERs until FAIL (3 s), then nothing until expiry at 9 s.
    for (int i = 1; i < TRIES; i++) expect_client(K_DISC, 0, 0, 0, BCAST_MAC, (CAP_MS + 4) * MS, x, t, "no-server DISCOVER");
    while ((cyc - t_ack) < 9 * SEC - 4 * MS) @(posedge clk);
    tb_check(lease_valid == 1, "lease still valid just before expiry");
    wait_cycles(30 * MS);
    tb_check(lease_valid == 0, "lease expired in FAIL/SELECTING");
    tb_check(valid_falls == lost0 + 1, "exactly one lease_valid fall at the expiry after START");
    expect_silence(2 * SEC, "no frame at the expiry outside RENEWING");
    quiesce("start while bound");
  endtask

  // ---------------------------------------------------------------------------
  // Case 8: STOP and RELEASE, infinite lease
  // ---------------------------------------------------------------------------
  task automatic case_stop();
    bit [31:0] xid;
    bit [31:0] x;
    longint t;
    int falls0;
    ctrl(C_CLEAR);
    acquire(router_opts(8'd2, LONG_LEASE, MASK_24, ROUTER_IP), router_opts(8'd5, LONG_LEASE, MASK_24, ROUTER_IP),
            OFFER_IP, SERVER_IP, xid, "stop acquisition");
    falls0 = valid_falls;
    ctrl(C_STOP);
    expect_client(K_REL, OFFER_IP, 0, SERVER_IP, SERVER_MAC, 200, x, t, "RELEASE");
    tb_check(lease_valid == 0, "STOP drops the lease");
    tb_check(valid_falls == falls0 + 1, "one lease_valid fall on STOP");
    expect_lease(0, 0, 0, 0, 0, 0, "after STOP");
    expect_state(ST_INIT, "after STOP");
    reg_expect(R_RELS, 1, "RELEASES_SENT");
    reg_expect(R_LOST, 0, "STOP is not a lost lease");
    ctrl(C_STOP);
    expect_silence(500, "STOP without a lease sends nothing");
    reg_expect(R_RELS, 1, "RELEASES_SENT unchanged");
    // A late ACK for the released exchange is ignored in INIT.
    begin
      srv_t s;
      s = srv_default(xid, OFFER_IP);
      send(srv_frame(s, router_opts(8'd5, LONG_LEASE, MASK_24, ROUTER_IP)));
      expect_silence(800, "ACK in INIT ignored");
      tb_check(lease_valid == 0, "ACK in INIT does not bind");
    end
    // Infinite lease: no renewal, no expiry.
    acquire(router_opts(8'd2, 32'hFFFF_FFFF, MASK_24, ROUTER_IP), router_opts(8'd5, 32'hFFFF_FFFF, MASK_24, ROUTER_IP),
            OFFER_IP, SERVER_IP, xid, "infinite acquisition");
    expect_lease(1, OFFER_IP, MASK_24, ROUTER_IP, SERVER_IP, 32'hFFFF_FFFF, "infinite lease");
    expect_silence(12 * SEC, "infinite lease never renews");
    expect_state(ST_BOUND, "infinite lease");
    quiesce("infinite");
  endtask

  // ---------------------------------------------------------------------------
  // Case 9: output stalls and CNT_CLEAR
  // ---------------------------------------------------------------------------
  task automatic case_stalls();
    bit [31:0] xid;
    bit [31:0] x;
    longint t;
    u_sink.ready_pct = 30;
    acquire(router_opts(8'd2, 32'd13, MASK_24, ROUTER_IP), router_opts(8'd5, 32'd13, MASK_24, ROUTER_IP),
            OFFER_IP, SERVER_IP, xid, "stalled acquisition");
    expect_client(K_REN, OFFER_IP, 0, 0, BCAST_MAC, 7 * SEC, x, t, "stalled renew");
    u_sink.ready_pct = 3;
    ctrl(C_STOP);
    expect_client(K_REL, OFFER_IP, 0, SERVER_IP, SERVER_MAC, 40000, x, t, "long-stalled RELEASE");
    u_sink.ready_pct = 50;
    ctrl(C_START);
    expect_client(K_DISC, 0, 0, 0, BCAST_MAC, 2000, x, t, "stalled DISCOVER");
    u_sink.ready_pct = 100;
    quiesce("stalls");
    ctrl(C_CLEAR);
    reg_expect(R_DISC, 0, "CNT_CLEAR DISCOVERS_SENT");
    reg_expect(R_OFFERS, 0, "CNT_CLEAR OFFERS_RX");
    reg_expect(R_REQS, 0, "CNT_CLEAR REQUESTS_SENT");
    reg_expect(R_ACKS, 0, "CNT_CLEAR ACKS_RX");
    reg_expect(R_NAKS, 0, "CNT_CLEAR NAKS_RX");
    reg_expect(R_LOST, 0, "CNT_CLEAR LEASES_LOST");
    reg_expect(R_RELS, 0, "CNT_CLEAR RELEASES_SENT");
  endtask

  // ---------------------------------------------------------------------------
  // Case 10: DUT B takes an 1100-byte OFFER (2 KiB distributed RAM)
  // ---------------------------------------------------------------------------
  task automatic case_dut_b();
    bytes_t f;
    bytes_t opts;
    bit ok;
    bit [31:0] xid;
    srv_t s;
    @(posedge clk);
    rb_wr_en <= 1'b1; rb_wr_addr <= R_CTRL; rb_wr_data <= C_START;
    @(posedge clk);
    rb_wr_en <= 1'b0;
    u_sink_b.get(f, 200, ok);
    tb_check(ok && f.size() == FRAME_LEN, "DUT B DISCOVER");
    xid = ok ? get32(f, 46) : 0;
    s = srv_default(xid, OFFER_IP);
    s.bootp_min = 1100 - 42;
    opts = router_opts(8'd2, LONG_LEASE, MASK_24, ROUTER_IP);
    void'(opts.pop_back());
    opts = cat(opts, o_raw(8'd43, 255, 8'h00));
    opts = cat(opts, o_raw(8'd43, 255, 8'h80));
    opts.push_back(8'd255);
    repeat (20) @(posedge clk);
    u_src_b.send(srv_frame(s, opts));
    u_sink_b.get(f, 6000, ok);
    tb_check(ok && f.size() == FRAME_LEN && f[284] == 8'd3 && get32(f, 302) == OFFER_IP,
             "DUT B answers an 1100-byte OFFER with a REQUEST");
    repeat (40) @(posedge clk);
    opts[2] = 8'd5;
    u_src_b.send(srv_frame(s, opts));
    repeat (6000) @(posedge clk);
    tb_check(lease_valid_b == 1 && lease_ip_b == OFFER_IP && lease_mask_b == MASK_24 && lease_router_b == ROUTER_IP,
             "DUT B bound from an 1100-byte ACK");
  endtask

  // ---------------------------------------------------------------------------
  // Sequence
  // ---------------------------------------------------------------------------
  initial begin
    repeat (10) @(posedge clk);
    resetn <= 1'b1;
    repeat (10) @(posedge clk);
    case_registers();
    case_acquire();
    case_retransmit();
    case_nak();
    case_ignored();
    case_options();
    case_renew();
    case_stop();
    case_stalls();
    case_dut_b();
    tb_check(u_sink.frames.size() == 0, "no unchecked frame left");
    tb_check(u_busy_mon.ready_errors == 0, "s_axis_tready held 1");
    $display("tb_rtlnet_dhcp: ignored_cases=%0d frames_checked=%0d lease_valid_falls=%0d", ignored_cases, exp_ident,
             valid_falls);
    tb_verdict("tb_rtlnet_dhcp");
  end

endmodule
