// -----------------------------------------------------------------------------
// File: tb_rtlnet_arp.sv
// Purpose: self-checking unit bench of the rtlnet_arp leaf (RFC 826 responder)
//   against the leaf contract (documentation/rtlnet_architecture.md 7.5, 15.4).
// Overview:
//   * Four tb_rtlnet_arp_unit harnesses run in parallel, REPLY_DELAY_CYCLES 0,
//     5, 40 and the default 1250 (short suite). Each harness drives the leaf
//     with rtlnet_tb_axis_src, collects replies with rtlnet_tb_axis_sink and
//     carries rtlnet_tb_leaf_busy_monitor plus a local busy-rise check
//     (busy rises at most 12 clocks after the last beat of an input frame).
//   * Oracles are bench-built: requests and the expected reply are built from
//     rtlnet_tb_pkg byte-queue builders, and a bench reference model
//     (arp_classify) decides for every frame whether it must be answered,
//     counted as ignored, or is not ARP at all.
//   * Cases: valid requests of 42..1500 bytes with zero and non-zero padding,
//     gappy input, cycle-exact latency (delay + 4), random and held output
//     stalls, requests during the delay and while the reply is pending
//     (ignored, first reply intact), every accept rule wrong in turn with a
//     good request chained behind it, truncated requests, the leaf disabled,
//     a changed local address, 150 random mutated frames, register readback
//     and the counter values against the model, CNT_CLEAR.
//   * +INJECT_FAILURE forces TEST FAIL (negative control).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: each harness has its own 50 MHz leaf clock.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_arp_unit #(
  parameter int    DELAY      = 5,
  parameter bit    FULL_SUITE = 1'b1,
  parameter int    SEED       = 1,
  parameter string NAME       = "arp"
)(
  output logic done
);

  import rtlnet_tb_pkg::*;

  localparam logic [47:0] PEER_MAC      = 48'h02_11_22_33_44_55;
  localparam logic [31:0] PEER_IP       = 32'hC0A90109;
  localparam logic [47:0] DUT_MAC_A     = 48'h02_49_4B_52_4E_01;
  localparam logic [31:0] DUT_IP_A      = 32'hC0A901DC;          // 192.169.1.220
  // Low byte 0: an absent byte 41 reads as zero, so only tkeep rejects a 41-byte request.
  localparam logic [31:0] DUT_IP_B      = 32'hC0A80700;
  localparam logic [47:0] DUT_MAC_B     = 48'h0E_DE_AD_BE_EF_42;
  localparam int          LAT_FIXED     = 4;                     // latency minus DELAY, clk cycles
  localparam int          RISE_LIMIT    = 12;
  localparam int          ANSWER        = 2;
  localparam int          IGNORED_ARP   = 1;
  localparam int          NOT_ARP       = 0;

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
  rtlnet_arp #(.REPLY_DELAY_CYCLES(DELAY)) dut (
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

  // Request source and reply sink.
  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(SEED)) u_src (
    .clk(clk), .tdata(s_tdata), .tkeep(s_tkeep), .tlast(s_tlast), .tvalid(s_tvalid), .tready(s_tready));

  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(SEED + 7), .NAME({NAME, " sink"})) u_sink (
    .clk(clk), .resetn(resetn), .tdata(m_tdata), .tkeep(m_tkeep), .tlast(m_tlast), .tvalid(m_tvalid),
    .tready(m_tready));

  // The shared leaf-contract checker.
  rtlnet_tb_leaf_busy_monitor #(.NAME(NAME), .RISE_LIMIT(RISE_LIMIT), .STUCK_LIMIT(DELAY + 20000)) u_busy_mon (
    .clk(clk), .resetn(resetn), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
    .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast), .busy(busy));

  // ---------------------------------------------------------------------------
  // Local monitors: cycle counter, last input beat, first reply beat, busy
  // rise latency.
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
  // Register port tasks (read data is due one clock after reg_rd_en).
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
  // Frame builders and the reference model.
  // ---------------------------------------------------------------------------
  function automatic bytes_t arp_frame(input bit [47:0] sha, input bit [31:0] spa, input bit [31:0] tpa,
                                       input bit [15:0] et = 16'h0806, input bit [15:0] htype = 16'h0001,
                                       input bit [15:0] ptype = 16'h0800, input bit [7:0] hlen = 8'd6,
                                       input bit [7:0] plen = 8'd4, input bit [15:0] oper = 16'h0001);
    bytes_t q;
    q = eth_header(48'hFFFF_FFFF_FFFF, sha, et);
    push16(q, htype); push16(q, ptype); q.push_back(hlen); q.push_back(plen); push16(q, oper);
    push48(q, sha); push32(q, spa); push48(q, 48'h0); push32(q, tpa);
    return q;
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

  // The reply a correct leaf sends for request req.
  function automatic bytes_t arp_reply(input bytes_t req, input bit [47:0] mac, input bit [31:0] ip);
    bytes_t q;
    q = eth_header(get48(req, 22), mac, 16'h0806);
    push16(q, 16'h0001); push16(q, 16'h0800); q.push_back(8'd6); q.push_back(8'd4); push16(q, 16'h0002);
    push48(q, mac); push32(q, ip); push48(q, get48(req, 22)); push32(q, get32(req, 28));
    return q;
  endfunction

  // Reference model: ANSWER, IGNORED_ARP (an ARP frame not answered) or NOT_ARP.
  function automatic int arp_classify(input bytes_t f, input bit [31:0] ip, input bit taken);
    bit is_arp;
    bit ok;
    is_arp = (f.size() >= 14) && (get16(f, 12) == 16'h0806);
    ok = taken && is_arp && (f.size() >= 42) && (get16(f, 14) == 16'h0001) && (get16(f, 16) == 16'h0800) &&
         (f[18] == 8'd6) && (f[19] == 8'd4) && (get16(f, 20) == 16'h0001) && (get32(f, 38) == ip);
    if (ok)     return ANSWER;
    if (is_arp) return IGNORED_ARP;
    return NOT_ARP;
  endfunction

  // ---------------------------------------------------------------------------
  // Expected counters, kept by the bench from the model.
  // ---------------------------------------------------------------------------
  int exp_requests = 0;
  int exp_replies  = 0;
  int exp_ignored  = 0;

  function automatic void account(input int cls);
    if (cls == ANSWER) begin
      exp_requests++;
      exp_replies++;
    end else if (cls == IGNORED_ARP) begin
      exp_ignored++;
    end
  endfunction

  // Wait until the leaf is idle (busy low and no reply beat pending).
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

  // Check one received reply against the expected one.
  task automatic check_reply(input string tag, input bytes_t req, input bit [47:0] mac, input bit [31:0] ip);
    bytes_t got;
    bit     ok;
    string  why;
    u_sink.get(got, 40000 + 4 * DELAY, ok);
    tb_check(ok, $sformatf("%s: %s: a reply arrived", NAME, tag));
    if (ok) tb_check(bytes_equal(got, arp_reply(req, mac, ip), why),
                     $sformatf("%s: %s: reply byte-exact (%s) got %s", NAME, tag, why, hexdump(got)));
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
    cls = arp_classify(f, local_ip, enable);
    account(cls);
    u_src.send(f);
    if (cls == ANSWER) begin
      check_reply(tag, f, local_mac, local_ip);
    end else begin
      expect_none(tag, 80 + DELAY + 8);
    end
    wait_idle(50000 + DELAY);
  endtask

  task automatic check_counters(input string tag);
    reg_expect(12'h020, 32'(exp_requests), {tag, " REQUESTS_FOR_US"});
    reg_expect(12'h024, 32'(exp_replies), {tag, " REPLIES_SENT"});
    reg_expect(12'h028, 32'(exp_ignored), {tag, " IGNORED"});
  endtask

  // ---------------------------------------------------------------------------
  // The cases.
  // ---------------------------------------------------------------------------
  int lens[8] = '{42, 43, 46, 48, 60, 64, 100, 1500};
  int rng = SEED * 7919;

  initial begin
    bytes_t       p1;
    bytes_t       p2;
    bytes_t       p3;
    int           lat;
    logic [31:0]  v;
    int           cls;
    int           n;
    bit [31:0]    r;

    done = 1'b0;
    repeat (10) @(posedge clk);
    resetn <= 1'b1;
    repeat (5) @(posedge clk);
    tb_check(s_tready === 1'b1, $sformatf("%s: s_axis_tready held at 1 after reset", NAME));
    tb_check(busy === 1'b0 && m_tvalid === 1'b0, $sformatf("%s: idle after reset", NAME));

    // ---- Register map: header, status, counters at reset; writes to RO ignored.
    reg_expect(12'h000, 32'h41525031, "ID");
    reg_expect(12'h004, 32'h10222026, "VERSION");
    reg_expect(12'h008, 32'(DELAY), "CAPS (REPLY_DELAY_CYCLES)");
    reg_expect(12'h00C, 32'h0, "CTRL");
    reg_expect(12'h010, 32'h1, "STATUS (enabled, not busy)");
    reg_expect(12'h3FC, 32'h0, "undefined offset");
    reg_write(12'h000, 32'hFFFF_FFFF);
    reg_expect(12'h000, 32'h41525031, "ID after a write");
    check_counters("reset");

    // ---- Valid requests of every length class, zero and 0xA5 padding.
    for (int i = 0; i < (FULL_SUITE ? 8 : 2); i++) begin
      p1 = pad_to(arp_frame({PEER_MAC[47:8], 8'(i)}, {PEER_IP[31:8], 8'(i + 1)}, local_ip), lens[i],
                  (i == 3 || i == 5) ? 8'hA5 : 8'h00);
      send_and_judge($sformatf("request of %0d bytes", lens[i]), p1);
    end

    // ---- Latency: last request beat to first reply beat = DELAY + LAT_FIXED.
    p1 = arp_frame(PEER_MAC, PEER_IP, local_ip);
    send_and_judge("latency probe 42 bytes", p1);
    lat = first_out_cyc - last_in_cyc;
    tb_check(lat == DELAY + LAT_FIXED, $sformatf("%s: latency %0d clocks, expected %0d", NAME, lat, DELAY + LAT_FIXED));
    p1 = pad_to(arp_frame(PEER_MAC, PEER_IP, local_ip), 60, 8'h00);
    send_and_judge("latency probe 60 bytes", p1);
    lat = first_out_cyc - last_in_cyc;
    tb_check(lat == DELAY + LAT_FIXED, $sformatf("%s: latency %0d clocks, expected %0d", NAME, lat, DELAY + LAT_FIXED));
    reg_expect(12'h008, 32'(DELAY), "CAPS");

    if (FULL_SUITE) begin
      // ---- Gappy input.
      u_src.gap_pct = 35;
      for (int i = 0; i < 4; i++) begin
        p1 = pad_to(arp_frame({PEER_MAC[47:8], 8'(40 + i)}, PEER_IP, local_ip), 60 + 8 * i, 8'h5A);
        send_and_judge("gappy request", p1);
      end
      u_src.gap_pct = 0;

      // ---- Output back-pressure: random 50 %, random 12 %, then a held stall.
      for (int k = 0; k < 2; k++) begin
        u_sink.ready_pct = (k == 0) ? 50 : 12;
        for (int i = 0; i < 4; i++) begin
          p1 = pad_to(arp_frame({PEER_MAC[47:8], 8'(60 + i)}, {PEER_IP[31:8], 8'(k)}, local_ip), 42 + 18 * (i % 2),
                      8'h00);
          send_and_judge($sformatf("back-pressure %0d%%", u_sink.ready_pct), p1);
        end
      end
      u_sink.ready_pct = 0;
      p1 = arp_frame(48'h02_AA_00_00_00_01, PEER_IP, local_ip);
      account(ANSWER);
      u_src.send(p1);
      repeat (DELAY + 300) @(posedge clk);
      tb_check(m_tvalid === 1'b1 && busy === 1'b1, $sformatf("%s: held stall: reply waiting, busy high", NAME));
      tb_check(u_sink.frames.size() == 0, $sformatf("%s: held stall: nothing completed", NAME));
      u_sink.ready_pct = 100;
      check_reply("held stall released", p1, local_mac, local_ip);
      wait_idle(1000);

      // ---- Requests during the delay and while the reply is pending: ignored whole,
      // the first reply intact (its sender fields differ from every later frame).
      u_sink.ready_pct = 0;
      p1 = arp_frame(48'h02_10_10_10_10_10, 32'h0A0A0A0A, local_ip);
      p2 = pad_to(arp_frame(48'h0E_21_22_23_24_25, 32'h0B0B0B0B, local_ip), 100, 8'h00);
      p3 = pad_to(arp_frame(48'h0E_31_32_33_34_35, 32'h0C0C0C0C, local_ip), 60, 8'h00);
      account(ANSWER);
      account(IGNORED_ARP);
      account(IGNORED_ARP);
      u_src.send(p1);
      u_src.send(p2);                                  // chained: first beat right behind p1's last
      repeat (DELAY + 50) @(posedge clk);
      u_src.send(p3);                                  // while the reply is pending at the port
      repeat (100) @(posedge clk);
      u_sink.ready_pct = 100;
      check_reply("first reply with requests during delay/pending", p1, local_mac, local_ip);
      expect_none("requests during delay/pending", DELAY + 300);
      wait_idle(1000);
      // A long request starting right behind a short one and ending after the reply.
      p1 = arp_frame(48'h02_10_10_10_10_11, 32'h0A0A0A0B, local_ip);
      p2 = pad_to(arp_frame(48'h0E_41_42_43_44_45, 32'h0D0D0D0D, local_ip), 400, 8'h00);
      account(ANSWER);
      account(IGNORED_ARP);
      u_src.send(p1);
      u_src.send(p2);
      check_reply("first reply with a long request behind it", p1, local_mac, local_ip);
      expect_none("long request behind the first", DELAY + 300);
      wait_idle(1000);
      check_counters("after the one-at-a-time cases");

      // ---- Every accept rule wrong in turn, a good request chained right behind it.
      local_ip = DUT_IP_B;
      repeat (4) @(posedge clk);
      for (int k = 0; k < 21; k++) begin
        n = 60;
        case (k)
          0:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip, 16'h0800);
          1:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip, 16'h0806, 16'h0002);
          2:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip, 16'h0806, 16'h0100);
          3:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip, 16'h0806, 16'h0001, 16'h86DD);
          4:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip, 16'h0806, 16'h0001, 16'h0800, 8'd8);
          5:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip, 16'h0806, 16'h0001, 16'h0800, 8'd6, 8'd6);
          6:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip, 16'h0806, 16'h0001, 16'h0800, 8'd6, 8'd4, 16'h0002);
          7:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip, 16'h0806, 16'h0001, 16'h0800, 8'd6, 8'd4, 16'h0000);
          8:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip, 16'h0806, 16'h0001, 16'h0800, 8'd6, 8'd4, 16'h0100);
          9:  p1 = arp_frame(PEER_MAC, PEER_IP, local_ip ^ 32'h0000_0001);
          10: p1 = arp_frame(PEER_MAC, PEER_IP, local_ip ^ 32'h0000_0100);
          11: p1 = arp_frame(PEER_MAC, PEER_IP, local_ip ^ 32'h0001_0000);
          12: p1 = arp_frame(PEER_MAC, PEER_IP, local_ip ^ 32'h8000_0000);
          13: p1 = arp_frame(PEER_MAC, PEER_IP, PEER_IP);
          default: begin
            p1 = arp_frame(PEER_MAC, PEER_IP, local_ip);
            n = (k == 14) ? 1 : (k == 15) ? 8 : (k == 16) ? 16 : (k == 17) ? 24 : (k == 18) ? 32 :
                (k == 19) ? 40 : 41;
          end
        endcase
        p1 = (n == 60) ? pad_to(p1, 60, 8'h00) : trunc_to(p1, n);
        p2 = pad_to(arp_frame({PEER_MAC[47:8], 8'(100 + k)}, {PEER_IP[31:8], 8'(k)}, local_ip), 60, 8'h00);
        cls = arp_classify(p1, local_ip, 1'b1);
        tb_check(cls != ANSWER, $sformatf("%s: model rejects wrong-rule case %0d", NAME, k));
        account(cls);
        account(ANSWER);
        u_src.send(p1);
        if (k % 2 == 1) repeat (1) @(posedge clk);     // zero or one idle clock between the two
        u_src.send(p2);
        check_reply($sformatf("good request behind wrong rule %0d", k), p2, local_mac, local_ip);
        expect_none($sformatf("wrong rule %0d", k), DELAY + 100);
        wait_idle(1000);
      end
      p1 = pad_to(arp_frame(PEER_MAC, PEER_IP, local_ip), 60, 8'hFF);
      send_and_judge("control: 0xFF padding", p1);
      check_counters("after the accept rules");

      // ---- Disabled leaf: a valid request is ignored (and counted), then answered again.
      enable = 1'b0;
      reg_expect(12'h010, 32'h0, "STATUS while disabled");
      p1 = pad_to(arp_frame(PEER_MAC, PEER_IP, local_ip), 60, 8'h00);
      send_and_judge("disabled leaf", p1);
      enable = 1'b1;
      send_and_judge("re-enabled leaf", p1);

      // ---- Changed local address: the reply carries the new MAC and IP, the old IP is not answered.
      local_mac = DUT_MAC_B;
      local_ip  = DUT_IP_A ^ 32'h0000_00FF;
      repeat (2) @(posedge clk);
      p1 = pad_to(arp_frame(PEER_MAC, PEER_IP, local_ip), 60, 8'h00);
      send_and_judge("new local address", p1);
      p1 = pad_to(arp_frame(PEER_MAC, PEER_IP, DUT_IP_A), 60, 8'h00);
      send_and_judge("old local address", p1);

      // ---- Random mutated frames, random gaps and stalls, judged by the model.
      for (int i = 0; i < 150; i++) begin
        r = $urandom(rng);
        rng++;
        u_sink.ready_pct = (r[1:0] == 2'd0) ? 40 : 100;
        u_src.gap_pct    = r[2] ? 20 : 0;
        p1 = arp_frame({PEER_MAC[47:8], 8'(i)}, {PEER_IP[31:8], 8'(i)}, local_ip);
        case (r[6:3])
          4'd0: p1[12 + r[7]]      = p1[12 + r[7]] ^ (8'd1 << r[10:8]);        // EtherType
          4'd1: p1[14 + r[7]]      = p1[14 + r[7]] ^ (8'd1 << r[10:8]);        // ar$hrd
          4'd2: p1[16 + r[7]]      = p1[16 + r[7]] ^ (8'd1 << r[10:8]);        // ar$pro
          4'd3: p1[18 + r[7]]      = p1[18 + r[7]] ^ (8'd1 << r[10:8]);        // ar$hln / ar$pln
          4'd4: p1[20 + r[7]]      = p1[20 + r[7]] ^ (8'd1 << r[10:8]);        // ar$op
          4'd5: p1[38 + r[8:7]]    = p1[38 + r[8:7]] ^ (8'd1 << r[11:9]);      // ar$tpa
          4'd6: p1[22 + (r % 20)]  = p1[22 + (r % 20)] ^ 8'h5A;                // sender and target fields
          4'd7: p1[r[11:7] % 12]   = p1[r[11:7] % 12] ^ 8'hFF;                 // Ethernet addresses (not checked)
          default: ;
        endcase
        n = (r[14:12] == 3'd0) ? (1 + (r[22:15] % 41)) : (r[14:12] == 3'd1) ? 42 :
            (r[14:12] == 3'd2) ? (42 + (r[22:15] % 100)) : (r[14:12] == 3'd3) ? 300 : 60;
        p1 = (n < 42) ? trunc_to(p1, n) : pad_to(p1, n, r[23] ? 8'h99 : 8'h00);
        send_and_judge($sformatf("random frame %0d (%0d bytes)", i, n), p1);
      end
      u_sink.ready_pct = 100;
      u_src.gap_pct    = 0;
    end

    // ---- Counters against the model, then CNT_CLEAR.
    wait_idle(DELAY + 1000);
    check_counters("final");
    reg_write(12'h00C, 32'h1);
    exp_requests = 0;
    exp_replies  = 0;
    exp_ignored  = 0;
    check_counters("after CNT_CLEAR");
    reg_expect(12'h00C, 32'h0, "CTRL reads 0 after the pulse");
    tb_check(busy_rises >= (FULL_SUITE ? 40 : 4), $sformatf("%s: busy rose for the replies (%0d)", NAME, busy_rises));
    done = 1'b1;
  end

endmodule

module tb_rtlnet_arp;

  import rtlnet_tb_pkg::*;

  logic done0;
  logic done1;
  logic done2;
  logic done3;

  tb_rtlnet_arp_unit #(.DELAY(0),    .FULL_SUITE(1'b1), .SEED(11), .NAME("arp_d0"))    u_unit0 (.done(done0));
  tb_rtlnet_arp_unit #(.DELAY(5),    .FULL_SUITE(1'b1), .SEED(23), .NAME("arp_d5"))    u_unit1 (.done(done1));
  tb_rtlnet_arp_unit #(.DELAY(40),   .FULL_SUITE(1'b1), .SEED(37), .NAME("arp_d40"))   u_unit2 (.done(done2));
  tb_rtlnet_arp_unit #(.DELAY(1250), .FULL_SUITE(1'b0), .SEED(41), .NAME("arp_d1250")) u_unit3 (.done(done3));

  // Verdict when every harness is done; watchdog otherwise.
  initial begin
    fork
      begin
        wait (done0 === 1'b1 && done1 === 1'b1 && done2 === 1'b1 && done3 === 1'b1);
      end
      begin
        #50ms;
        tb_error("watchdog: harnesses did not finish");
      end
    join_any
    tb_verdict("tb_rtlnet_arp");
  end

endmodule
