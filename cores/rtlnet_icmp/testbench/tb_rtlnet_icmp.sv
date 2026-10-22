// -----------------------------------------------------------------------------
// File: tb_rtlnet_icmp.sv
// Purpose: self-checking unit bench of the rtlnet_icmp leaf (ICMP echo
//   responder) against the leaf contract (documentation/rtlnet_architecture.md
//   7.5, 7.6, 15.4).
// Overview:
//   * Two tb_rtlnet_icmp_unit harnesses run in parallel: ICMP_BUF_KB = 2 (the
//     default, full suite with the payload sweep 0..1472) and ICMP_BUF_KB = 1
//     (the buffer bound follows the parameter: 1022 answered, 1023 dropped).
//     Each drives the leaf with rtlnet_tb_axis_src, collects replies with
//     rtlnet_tb_axis_sink and carries rtlnet_tb_leaf_busy_monitor plus a local
//     busy-rise check (at most 12 clocks after the last beat of a frame).
//   * Oracles are independent of the RTL: requests and the expected reply are
//     built byte by byte with rtlnet_tb_pkg builders and its RFC 1071
//     inet_checksum (full recompute of both reply checksums); a bench model
//     (icmp_classify) decides for every frame: answered, dropped for its
//     size, dropped for its checksum, or not an echo request for us.
//   * Cases: register readback, a realistic ping field by field, the payload
//     sweep 0..1472 byte-exact, 1473 rejected, Ethernet padding (zero, 0xA5,
//     up to 64 bytes; more is rejected), truncated and over-long frames, every
//     accept rule wrong in turn with a good request chained behind it, a
//     request during a pending reply and a frame whose tail carries a valid
//     request (ignored whole), random and held output stalls, gappy input,
//     the leaf disabled, a changed local address, 160 random mutated frames,
//     latency (3 clocks), the counters against the model and CNT_CLEAR.
//   * +INJECT_FAILURE forces TEST FAIL (negative control).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: each harness has its own 50 MHz leaf clock.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_icmp_unit #(
  parameter int    BUF_KB     = 2,
  parameter bit    FULL_SUITE = 1'b1,
  parameter int    SEED       = 1,
  parameter string NAME       = "icmp"
)(
  output logic done
);

  import rtlnet_tb_pkg::*;

  localparam logic [47:0] PEER_MAC    = 48'h02_11_22_33_44_55;
  localparam logic [31:0] PEER_IP     = 32'hC0A90109;
  localparam logic [47:0] DUT_MAC_A   = 48'h02_49_4B_52_4E_01;
  localparam logic [31:0] DUT_IP_A    = 32'hC0A901DC;            // 192.169.1.220
  localparam logic [47:0] DUT_MAC_B   = 48'h0E_DE_AD_BE_EF_42;
  localparam logic [31:0] DUT_IP_B    = 32'h0A000017;
  localparam int          MAX_PAYLOAD = (BUF_KB * 1024 - 2 < 1472) ? (BUF_KB * 1024 - 2) : 1472;
  localparam int          LAT_FIXED   = 3;
  localparam int          RISE_LIMIT  = 12;
  localparam int          ANSWER      = 3;
  localparam int          DROP_SIZE   = 2;
  localparam int          DROP_CSUM   = 1;
  localparam int          OTHER       = 0;

  // ---------------------------------------------------------------------------
  // Clock, reset, DUT and bench components.
  // ---------------------------------------------------------------------------
  logic        clk = 1'b0;
  logic        resetn = 1'b0;
  logic        enable = 1'b1;
  logic [47:0] local_mac = DUT_MAC_A;
  logic [31:0] local_ip = DUT_IP_A;

  always #10.0 clk = ~clk;

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
  logic        busy;

  logic        reg_wr_en = 1'b0;
  logic [11:0] reg_wr_addr = '0;
  logic [31:0] reg_wr_data = '0;
  logic        reg_rd_en = 1'b0;
  logic [11:0] reg_rd_addr = '0;
  logic [31:0] reg_rd_data;

  // The leaf under test.
  rtlnet_icmp #(.ICMP_BUF_KB(BUF_KB), .RAM_STYLE("block")) dut (
    .clk           (clk),
    .resetn        (resetn),
    .enable        (enable),
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
    .local_mac     (local_mac),
    .local_ip      (local_ip),
    .busy          (busy),
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data)
  );

  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(SEED)) u_src (
    .clk(clk), .tdata(s_tdata), .tkeep(s_tkeep), .tlast(s_tlast), .tvalid(s_tvalid), .tready(s_tready));

  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(SEED + 7), .NAME({NAME, " sink"})) u_sink (
    .clk(clk), .resetn(resetn), .tdata(m_tdata), .tkeep(m_tkeep), .tlast(m_tlast), .tvalid(m_tvalid),
    .tready(m_tready));

  rtlnet_tb_leaf_busy_monitor #(.NAME(NAME), .RISE_LIMIT(RISE_LIMIT), .STUCK_LIMIT(20000)) u_busy_mon (
    .clk(clk), .resetn(resetn), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
    .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast), .busy(busy));

  // ---------------------------------------------------------------------------
  // Local monitors: cycle count, last input beat, first reply beat, busy rise.
  // ---------------------------------------------------------------------------
  int  cyc = 0;
  int  last_in_cyc = 0;
  int  first_out_cyc = -1;
  bit  out_in_frame = 1'b0;
  bit  busy_q = 1'b0;
  int  busy_rises = 0;

  always @(posedge clk) begin
    cyc++;
    if (resetn) begin
      if (s_tvalid && s_tready && s_tlast) last_in_cyc = cyc;
      if (m_tvalid && !out_in_frame) begin
        out_in_frame  = 1'b1;
        first_out_cyc = cyc;
      end
      if (m_tvalid && m_tready && m_tlast) out_in_frame = 1'b0;
      if (busy && !busy_q) begin
        busy_rises++;
        tb_check(cyc - last_in_cyc <= RISE_LIMIT,
                 $sformatf("%s: busy rose %0d clocks after the last input beat", NAME, cyc - last_in_cyc));
      end
      busy_q = busy;
    end
  end

  // ---------------------------------------------------------------------------
  // Register port tasks.
  // ---------------------------------------------------------------------------
  task automatic reg_write(input logic [11:0] addr, input logic [31:0] data);
    @(posedge clk);
    reg_wr_en   <= 1'b1;
    reg_wr_addr <= addr;
    reg_wr_data <= data;
    @(posedge clk);
    reg_wr_en   <= 1'b0;
  endtask

  task automatic reg_read(input logic [11:0] addr, output logic [31:0] data);
    @(posedge clk);
    reg_rd_en   <= 1'b1;
    reg_rd_addr <= addr;
    @(posedge clk);
    reg_rd_en   <= 1'b0;
    @(posedge clk);
    data = reg_rd_data;
  endtask

  task automatic reg_expect(input logic [11:0] addr, input logic [31:0] exp, input string what);
    logic [31:0] v;
    reg_read(addr, v);
    tb_check(v === exp, $sformatf("%s: %s = 0x%08x, expected 0x%08x", NAME, what, v, exp));
  endtask

  // ---------------------------------------------------------------------------
  // Frame builders (bench oracles).
  // ---------------------------------------------------------------------------
  int rng = SEED * 104729;

  function automatic bytes_t random_bytes(input int n);
    bytes_t q;
    for (int i = 0; i < n; i++) begin
      q.push_back(8'($urandom(rng)));
      rng++;
    end
    return q;
  endfunction

  // Ethernet/IPv4/ICMP echo frame with correct checksums (type, code settable).
  function automatic bytes_t echo_frame(input bit [47:0] dst_mac, input bit [47:0] src_mac, input bit [31:0] src_ip,
                                        input bit [31:0] dst_ip, input bit [15:0] icmp_id, input bit [15:0] icmp_seq,
                                        input bytes_t data, input bit [7:0] icmp_type = 8'd8,
                                        input bit [7:0] tos = 8'h00, input bit [15:0] ip_id = 16'h1234,
                                        input bit [15:0] flags = 16'h0000, input bit [7:0] ttl = 8'd128);
    bytes_t q;
    bytes_t ip;
    bytes_t icmp;
    bit [15:0] c;
    icmp.push_back(icmp_type); icmp.push_back(8'd0); push16(icmp, 16'h0000); push16(icmp, icmp_id);
    push16(icmp, icmp_seq);
    for (int i = 0; i < $size(data); i++) icmp.push_back(data[i]);
    c = inet_checksum(icmp, 0, icmp.size());
    icmp[2] = c[15:8]; icmp[3] = c[7:0];
    q  = eth_header(dst_mac, src_mac, 16'h0800);
    ip = ipv4_header(16'(20 + icmp.size()), ip_id, 8'd1, src_ip, dst_ip, ttl, flags, tos);
    for (int i = 0; i < $size(ip); i++)   q.push_back(ip[i]);
    for (int i = 0; i < $size(icmp); i++) q.push_back(icmp[i]);
    return q;
  endfunction

  function automatic bytes_t ping(input bit [31:0] dst_ip, input int payload_len, input bit [15:0] seq);
    return echo_frame(DUT_MAC_A, PEER_MAC, PEER_IP, dst_ip, 16'h4D2E, seq, random_bytes(payload_len));
  endfunction

  function automatic bytes_t pad_to(input bytes_t q, input int n, input byte unsigned v);
    bytes_t r;
    r = q;
    while (r.size() < n) r.push_back(v);
    return r;
  endfunction

  function automatic bytes_t trunc_to(input bytes_t q, input int n);
    bytes_t r;
    for (int i = 0; i < n && i < $size(q); i++) r.push_back(q[i]);
    return r;
  endfunction

  // The reply a correct leaf sends for request req: 14 + Total Length bytes,
  // both checksums recomputed over the reply (RFC 1071).
  function automatic bytes_t echo_reply(input bytes_t req, input bit [47:0] mac, input bit [31:0] ip);
    bytes_t    q;
    bytes_t    hdr;
    bytes_t    icmp;
    bit [15:0] total;
    bit [15:0] c;
    total = get16(req, 16);
    q   = eth_header(get48(req, 6), mac, 16'h0800);
    hdr = ipv4_header(total, get16(req, 18), 8'd1, ip, get32(req, 26), 8'd64, get16(req, 20), req[15]);
    for (int i = 0; i < $size(hdr); i++) q.push_back(hdr[i]);
    icmp.push_back(8'd0); icmp.push_back(8'd0); push16(icmp, 16'h0000);
    for (int i = 38; i < 14 + total; i++) icmp.push_back(req[i]);
    c = inet_checksum(icmp, 0, icmp.size());
    icmp[2] = c[15:8]; icmp[3] = c[7:0];
    for (int i = 0; i < $size(icmp); i++) q.push_back(icmp[i]);
    return q;
  endfunction

  // Reference model of the accept rules (see the RTL header).
  function automatic int icmp_classify(input bytes_t f, input bit [31:0] ip, input bit taken);
    int        len;
    int        total;
    int        last_f;
    int        last_m;
    bit        echo_for_us;
    bit        len_ok;
    len = f.size();
    if (!taken || len <= 40) return OTHER;
    echo_for_us = (get16(f, 12) == 16'h0800) && (f[14] == 8'h45) && (f[23] == 8'd1) && (get32(f, 30) == ip) &&
                  (f[34] == 8'd8) && (f[35] == 8'd0);
    if (!echo_for_us) return OTHER;
    total = get16(f, 16);
    if (total < 28 || total > MAX_PAYLOAD + 28) return DROP_SIZE;
    last_f = (len - 1) / 8;
    last_m = (13 + total) / 8;
    len_ok = ((last_f == last_m) && (len >= 14 + total)) || ((last_f > last_m) && (last_f <= 7));
    if (!len_ok) return DROP_SIZE;
    if (inet_sum(f, 34, total - 20) != 16'hFFFF) return DROP_CSUM;
    return ANSWER;
  endfunction

  // ---------------------------------------------------------------------------
  // Expected counters, from the model.
  // ---------------------------------------------------------------------------
  int exp_requests = 0;
  int exp_replies  = 0;
  int exp_csum     = 0;
  int exp_size     = 0;

  function automatic void account(input int cls);
    if (cls != OTHER) exp_requests++;
    if (cls == ANSWER)    exp_replies++;
    if (cls == DROP_CSUM) exp_csum++;
    if (cls == DROP_SIZE) exp_size++;
  endfunction

  task automatic wait_idle(input int max_cycles);
    int t;
    t = 0;
    while ((busy || m_tvalid) && t < max_cycles) begin
      @(posedge clk);
      t++;
    end
    tb_check(!busy && !m_tvalid, $sformatf("%s: leaf idle within %0d clocks", NAME, max_cycles));
    repeat (4) @(posedge clk);
  endtask

  task automatic check_reply(input string tag, input bytes_t req, input bit [47:0] mac, input bit [31:0] ip);
    bytes_t got;
    bit     ok;
    string  why;
    u_sink.get(got, 60000, ok);
    tb_check(ok, $sformatf("%s: %s: a reply arrived", NAME, tag));
    if (ok) tb_check(bytes_equal(got, echo_reply(req, mac, ip), why),
                     $sformatf("%s: %s: reply byte-exact (%s) got %s", NAME, tag, why, hexdump(got)));
    // Independent checksum verification of the received reply (RFC 1071: sums fold to 0xFFFF).
    if (ok && got.size() >= 42) begin
      tb_check(inet_sum(got, 14, 20) == 16'hFFFF, $sformatf("%s: %s: reply IP header checksum", NAME, tag));
      tb_check(inet_sum(got, 34, got.size() - 34) == 16'hFFFF, $sformatf("%s: %s: reply ICMP checksum", NAME, tag));
    end
  endtask

  task automatic expect_none(input string tag, input int cycles);
    bit none;
    u_sink.expect_none(cycles, none);
    tb_check(none, $sformatf("%s: %s: no reply", NAME, tag));
    if (!none) begin
      bytes_t junk;
      bit     ok;
      u_sink.get(junk, 1, ok);
    end
  endtask

  // Send one frame to an idle leaf and check the model's outcome.
  task automatic send_and_judge(input string tag, input bytes_t f);
    int cls;
    cls = icmp_classify(f, local_ip, enable);
    account(cls);
    u_src.send(f);
    if (cls == ANSWER) check_reply(tag, f, local_mac, local_ip);
    else               expect_none(tag, 60);
    wait_idle(40000);
  endtask

  task automatic check_counters(input string tag);
    reg_expect(12'h020, 32'(exp_requests), {tag, " ECHO_REQUESTS"});
    reg_expect(12'h024, 32'(exp_replies), {tag, " ECHO_REPLIES"});
    reg_expect(12'h028, 32'(exp_csum), {tag, " DROPPED_CHECKSUM"});
    reg_expect(12'h02C, 32'(exp_size), {tag, " DROPPED_SIZE"});
  endtask

  // ---------------------------------------------------------------------------
  // The cases.
  // ---------------------------------------------------------------------------
  initial begin
    bytes_t      p1;
    bytes_t      p2;
    bytes_t      p3;
    bytes_t      d;
    int          lat;
    int          cls;
    int          n;
    bit [31:0]   r;

    done = 1'b0;
    repeat (10) @(posedge clk);
    resetn <= 1'b1;
    repeat (5) @(posedge clk);
    tb_check(s_tready === 1'b1, $sformatf("%s: s_axis_tready held at 1 after reset", NAME));

    // ---- Register map.
    reg_expect(12'h000, 32'h49434D50, "ID");
    reg_expect(12'h004, 32'h10222026, "VERSION");
    reg_expect(12'h008, {8'd0, 8'(BUF_KB), 16'(MAX_PAYLOAD)}, "CAPS");
    reg_expect(12'h00C, 32'h0, "CTRL");
    reg_expect(12'h010, 32'h1, "STATUS");
    reg_expect(12'hFFC, 32'h0, "undefined offset");
    reg_write(12'h008, 32'hFFFF_FFFF);
    reg_expect(12'h008, {8'd0, 8'(BUF_KB), 16'(MAX_PAYLOAD)}, "CAPS after a write");
    check_counters("reset");

    // ---- A realistic ping with non-zero ToS, ID, flags and TTL; cycle-exact latency.
    p1 = echo_frame(DUT_MAC_A, PEER_MAC, PEER_IP, local_ip, 16'h0001, 16'h0017, random_bytes(32), 8'd8, 8'hB8,
                    16'hBEEF, 16'h4000, 8'd37);
    send_and_judge("realistic 32-byte ping", p1);
    lat = first_out_cyc - last_in_cyc;
    tb_check(lat == LAT_FIXED, $sformatf("%s: latency %0d clocks, expected %0d", NAME, lat, LAT_FIXED));

    // ---- Payload sizes: the full sweep (default buffer) or the bound of the small buffer.
    if (FULL_SUITE) begin
      for (int s = 0; s <= MAX_PAYLOAD; s++) send_and_judge($sformatf("payload %0d", s), ping(local_ip, s, 16'(s)));
    end else begin
      send_and_judge("payload 0", ping(local_ip, 0, 16'd0));
      send_and_judge("payload 1", ping(local_ip, 1, 16'd1));
      send_and_judge("payload 64", ping(local_ip, 64, 16'd2));
      send_and_judge("payload max-1", ping(local_ip, MAX_PAYLOAD - 1, 16'd3));
      send_and_judge("payload max", ping(local_ip, MAX_PAYLOAD, 16'd4));
      send_and_judge("payload 1472 on the small buffer", ping(local_ip, 1472, 16'd6));
    end
    p1 = ping(local_ip, MAX_PAYLOAD + 1, 16'd5);
    tb_check(icmp_classify(p1, local_ip, 1'b1) == DROP_SIZE, $sformatf("%s: model drops max+1", NAME));
    send_and_judge("payload max+1 rejected", p1);
    check_counters("after the sizes");

    if (FULL_SUITE) begin
      // ---- Ethernet padding: zero and 0xA5 up to 60, up to 64, beyond 64 rejected.
      for (int s = 0; s <= 18; s++) begin
        send_and_judge($sformatf("payload %0d zero-padded", s), pad_to(ping(local_ip, s, 16'(100 + s)), 60, 8'h00));
        send_and_judge($sformatf("payload %0d 0xA5-padded", s), pad_to(ping(local_ip, s, 16'(200 + s)), 60, 8'hA5));
      end
      send_and_judge("payload 4 padded to 64", pad_to(ping(local_ip, 4, 16'd300), 64, 8'h5A));
      p1 = pad_to(ping(local_ip, 4, 16'd301), 65, 8'h5A);
      tb_check(icmp_classify(p1, local_ip, 1'b1) == DROP_SIZE, $sformatf("%s: model drops 65-byte padding", NAME));
      send_and_judge("payload 4 padded to 65 rejected", p1);
      send_and_judge("payload 100 plus 8 extra bytes rejected", pad_to(ping(local_ip, 100, 16'd302), 150, 8'h00));
      send_and_judge("payload 100 truncated by 1 byte", trunc_to(ping(local_ip, 100, 16'd303), 141));
      send_and_judge("payload 100 truncated by 9 bytes", trunc_to(ping(local_ip, 100, 16'd304), 133));
      send_and_judge("payload 600 truncated to 300", trunc_to(ping(local_ip, 600, 16'd305), 300));

      // ---- Gappy input.
      u_src.gap_pct = 30;
      for (int i = 0; i < 6; i++) send_and_judge("gappy input", ping(local_ip, 13 * i + 1, 16'(400 + i)));
      u_src.gap_pct = 0;

      // ---- Output back-pressure, then a held stall.
      for (int k = 0; k < 2; k++) begin
        u_sink.ready_pct = (k == 0) ? 50 : 12;
        for (int i = 0; i < 4; i++) send_and_judge("back-pressure", ping(local_ip, 7 + 101 * i, 16'(500 + i)));
      end
      u_sink.ready_pct = 0;
      p1 = ping(local_ip, 200, 16'd600);
      account(ANSWER);
      u_src.send(p1);
      repeat (500) @(posedge clk);
      tb_check(m_tvalid === 1'b1 && busy === 1'b1, $sformatf("%s: held stall: reply waiting, busy high", NAME));
      u_sink.ready_pct = 100;
      check_reply("held stall released", p1, local_mac, local_ip);
      wait_idle(1000);

      // ---- One request at a time: a request right behind the first, one while the reply
      // is pending, and a frame whose tail carries a complete valid request, all ignored.
      u_sink.ready_pct = 0;
      p1 = ping(local_ip, 64, 16'd700);
      p2 = ping(local_ip, 64, 16'd701);
      p3 = random_bytes(64);
      d  = ping(local_ip, 16, 16'd702);
      for (int i = 0; i < $size(d); i++) p3.push_back(d[i]);
      account(ANSWER);
      u_src.send(p1);
      u_src.send(p2);                                    // chained: no idle clock
      repeat (40) @(posedge clk);
      u_src.send(p3);
      repeat (60) @(posedge clk);
      u_src.send(ping(local_ip, 8, 16'd703));
      repeat (60) @(posedge clk);
      u_sink.ready_pct = 100;
      check_reply("first reply with requests during the reply", p1, local_mac, local_ip);
      expect_none("requests during the reply", 400);
      wait_idle(1000);
      // A frame that starts during transmission and is still running when the reply ends.
      p1 = ping(local_ip, 300, 16'd710);
      p2 = ping(local_ip, 1000, 16'd711);
      account(ANSWER);
      u_src.send(p1);
      repeat (8) @(posedge clk);
      u_src.send(p2);
      check_reply("first reply with a long frame during it", p1, local_mac, local_ip);
      expect_none("long frame during the reply", 400);
      wait_idle(1000);
      // A frame chained right behind a request, J junk beats then a complete valid
      // request, for every J around the clock in which the leaf returns to idle:
      // the whole frame is ignored (in-frame tracking), whatever the alignment.
      for (int j = 4; j <= 20; j++) begin
        p1 = ping(local_ip, 40, 16'(720 + j));
        p2 = random_bytes(8 * j);
        d  = ping(local_ip, 16, 16'(760 + j));
        for (int i = 0; i < $size(d); i++) p2.push_back(d[i]);
        account(ANSWER);
        u_src.send(p1);
        u_src.send(p2);
        check_reply($sformatf("request before a tail request, %0d junk beats", j), p1, local_mac, local_ip);
        expect_none($sformatf("tail request behind %0d junk beats", j), 200);
        wait_idle(1000);
      end
      check_counters("after the one-at-a-time cases");

      // ---- Every accept rule wrong in turn, a good request chained behind it.
      for (int k = 0; k < 14; k++) begin
        p1 = ping(local_ip, 24, 16'(800 + k));
        case (k)
          0:  begin p1[12] = 8'h86; p1[13] = 8'hDD; end                          // EtherType
          1:  p1[14] = 8'h46;                                                    // version/IHL (options)
          2:  p1[14] = 8'h65;                                                    // version 6
          3:  p1[23] = 8'd17;                                                    // protocol UDP
          4:  p1[30] = p1[30] ^ 8'h01;                                           // destination IP byte 0
          5:  p1[31] = p1[31] ^ 8'h80;                                           // byte 1
          6:  p1[32] = p1[32] ^ 8'h10;                                           // byte 2
          7:  p1[33] = p1[33] ^ 8'h01;                                           // byte 3
          8:  p1 = echo_frame(DUT_MAC_A, PEER_MAC, PEER_IP, local_ip, 1, 2, random_bytes(24), 8'd0);   // type 0
          9:  p1 = echo_frame(DUT_MAC_A, PEER_MAC, PEER_IP, local_ip, 1, 2, random_bytes(24), 8'd13);  // type 13
          10: p1[35] = 8'd1;                                                     // code 1
          11: begin p1[16] = 8'h00; p1[17] = 8'd27; end                          // Total Length 27
          12: begin p1[16] = 8'h00; p1[17] = 8'd20; end                          // Total Length 20
          default: p1[45] = p1[45] ^ 8'h04;                                      // a data bit: checksum bad
        endcase
        p1 = pad_to(p1, 60, 8'h00);
        p2 = ping(local_ip, 30 + k, 16'(900 + k));
        cls = icmp_classify(p1, local_ip, 1'b1);
        tb_check(cls != ANSWER, $sformatf("%s: model rejects wrong-rule case %0d", NAME, k));
        account(cls);
        account(ANSWER);
        u_src.send(p1);
        if (k % 2 == 1) repeat (1) @(posedge clk);
        u_src.send(p2);
        check_reply($sformatf("good request behind wrong rule %0d", k), p2, local_mac, local_ip);
        expect_none($sformatf("wrong rule %0d", k), 200);
        wait_idle(1000);
      end
      check_counters("after the accept rules");

      // ---- Disabled leaf (not counted), re-enabled.
      enable = 1'b0;
      reg_expect(12'h010, 32'h0, "STATUS while disabled");
      send_and_judge("disabled leaf", ping(local_ip, 10, 16'd1000));
      enable = 1'b1;
      send_and_judge("re-enabled leaf", ping(local_ip, 10, 16'd1001));

      // ---- Changed local address.
      local_mac = DUT_MAC_B;
      local_ip  = DUT_IP_B;
      repeat (2) @(posedge clk);
      send_and_judge("new local address", ping(DUT_IP_B, 40, 16'd1100));
      send_and_judge("old local address", ping(DUT_IP_A, 40, 16'd1101));

      // ---- Random mutated frames with random stalls and gaps, judged by the model.
      for (int i = 0; i < 160; i++) begin
        r = $urandom(rng);
        rng++;
        u_sink.ready_pct = (r[1:0] == 2'd0) ? 40 : 100;
        u_src.gap_pct    = r[2] ? 20 : 0;
        n  = (r[5:3] == 3'd0) ? 0 : (r[5:3] == 3'd1) ? (r[16:8] % 20) : (r[16:8] % 400);
        p1 = ping(local_ip, n, 16'(i));
        case (r[20:17])
          4'd0: p1[12 + r[21]]     = p1[12 + r[21]] ^ (8'd1 << r[24:22]);    // EtherType
          4'd1: p1[14]             = p1[14] ^ (8'd1 << r[24:22]);            // version/IHL
          4'd2: p1[23]             = p1[23] ^ (8'd1 << r[24:22]);            // protocol
          4'd3: p1[30 + r[22:21]]  = p1[30 + r[22:21]] ^ (8'd1 << r[25:23]); // destination IP
          4'd4: p1[34 + r[21]]     = p1[34 + r[21]] ^ (8'd1 << r[24:22]);    // type / code
          4'd5: p1[16 + r[21]]     = p1[16 + r[21]] ^ (8'd1 << r[24:22]);    // Total Length
          4'd6: p1[34 + (r % (p1.size() - 34))] = p1[34 + (r % (p1.size() - 34))] ^ 8'h20;   // message byte
          4'd7: p1[r[26:22] % 12]  = p1[r[26:22] % 12] ^ 8'hFF;              // Ethernet addresses (not checked)
          4'd8: p1[24 + r[21]]     = p1[24 + r[21]] ^ 8'h01;                 // IP header checksum (not checked)
          default: ;
        endcase
        if (r[28:27] == 2'd0)      p1 = trunc_to(p1, p1.size() - 1 - (r[31:29] % 8));
        else if (r[28:27] == 2'd1) p1 = pad_to(p1, (p1.size() < 60) ? 60 : p1.size() + 1 + r[31:29], 8'h3C);
        send_and_judge($sformatf("random frame %0d (%0d bytes)", i, p1.size()), p1);
      end
      u_sink.ready_pct = 100;
      u_src.gap_pct    = 0;
    end

    // ---- Counters against the model, then CNT_CLEAR.
    wait_idle(1000);
    check_counters("final");
    reg_write(12'h00C, 32'h1);
    exp_requests = 0;
    exp_replies  = 0;
    exp_csum     = 0;
    exp_size     = 0;
    check_counters("after CNT_CLEAR");
    tb_check(busy_rises >= 5, $sformatf("%s: busy rose for the replies (%0d)", NAME, busy_rises));
    done = 1'b1;
  end

endmodule

module tb_rtlnet_icmp;

  import rtlnet_tb_pkg::*;

  logic done0;
  logic done1;

  tb_rtlnet_icmp_unit #(.BUF_KB(2), .FULL_SUITE(1'b1), .SEED(5),  .NAME("icmp_2kb")) u_unit0 (.done(done0));
  tb_rtlnet_icmp_unit #(.BUF_KB(1), .FULL_SUITE(1'b0), .SEED(17), .NAME("icmp_1kb")) u_unit1 (.done(done1));

  // Verdict when both harnesses are done; watchdog otherwise.
  initial begin
    fork
      begin
        wait (done0 === 1'b1 && done1 === 1'b1);
      end
      begin
        #400ms;
        tb_error("watchdog: harnesses did not finish");
      end
    join_any
    tb_verdict("tb_rtlnet_icmp");
  end

endmodule
