// -----------------------------------------------------------------------------
// File: tb_rtlnet_udp_socket.sv
// Purpose: self-checking bench for rtlnet_udp_socket alone: the leaf between a
//   bench "wrapper" (frame source and sink in proto_clk, direct register bus)
//   and a bench application (stream source and sink in app_clk).
// Cases:
//   1. Register reset values, read-back of every socket register, undefined
//      offsets read 0.
//   2. Receive to every socket: payload lengths 0..64 and 100..1472 byte-exact
//      (realignment from byte 42), with and without input gaps, non-zero
//      Ethernet padding never delivered; lowest socket index wins on a shared
//      port; disabled socket and unknown port counted in RX_NO_SOCKET.
//   3. Rejections counted in RX_BAD with nothing delivered: MF set, fragment
//      offset, IHL 6, version 6, UDP/IP length mismatch, total length 27 and
//      1501, truncated frame, bad IPv4 header checksum; ignored (no counter):
//      ARP, ICMP, UDP for another host or another subnet's broadcast.
//   4. Limited and subnet broadcast delivered with the BROADCAST flag; an
//      off-subnet sender with OFF_SUBNET.
//   5. UDP checksum: ignored with CTRL bit 0 clear; with it set, good and zero
//      checksums delivered, bad ones counted in RX_BAD.
//   6. CONNECT_ON_RX follows the last sender; a socket without it keeps its
//      registers.
//   7. RX FIFO full with the application stalled: 12 datagrams, 8 kept in
//      order, 4 counted in RX_FIFO_DROPS and the socket's RX_DROPS.
//   8. Transmit with explicit metadata: lengths 0..64 and up to 1472, frames
//      byte-exact against a bench-built frame (rtlnet_tb_pkg oracle, IPv4
//      checksum by inet_checksum), identification counting from 0, with a
//      stalling sink; USE_SOCKET_REMOTE from written and from learned remote
//      registers.
//   9. Transmit drops: disabled socket, index 4 and 255, length mismatches
//      (short, long, zero-with-payload, length-without-payload, meta 0 only,
//      1473 bytes) counted per socket and globally, never emitted.
//  10. Receive and transmit at the same time (30 datagrams each, random
//      lengths and stalls), a frame starting while the leaf is busy ignored
//      whole, leaf enable low, CNT_CLEAR.
//   Always on: rtlnet_tb_leaf_busy_monitor; busy high within 12 clocks of
//   every input frame's last beat; no gap inside an output frame or an
//   application datagram.
//   Clocks: proto_clk 50 MHz; app_clk 62.5 MHz (default), 100 MHz
//   (+define+TB_APP_100) or 33.3 MHz (+define+TB_APP_33), with a phase offset.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Run: powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_udp_socket
//        -Filelist cores/rtlnet_udp_socket/testbench/tb_rtlnet_udp_socket.f
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_udp_socket;

  import rtlnet_tb_pkg::*;

  localparam string BENCH       = "tb_rtlnet_udp_socket";
  localparam int    NUM_SOCKETS = 4;
  localparam int    RX_SLOTS    = 8;      // UDP_RX_BUF_KB 16 / 2 KiB
  localparam int    TMO         = 40000;  // sink wait, clocks
  localparam int    MAX_PAY     = 1472;

  localparam real PROTO_HALF = 10.0;      // 50 MHz
`ifdef TB_APP_100
  localparam real APP_HALF   = 5.0;       // 100 MHz
`elsif TB_APP_33
  localparam real APP_HALF   = 15.0;      // 33.3 MHz
`else
  localparam real APP_HALF   = 8.0;       // 62.5 MHz
`endif

  // Register map (driver/rtlnet_udp_socket.h).
  localparam logic [11:0] R_ID = 12'h000, R_VERSION = 12'h004, R_CAPS = 12'h008, R_CTRL = 12'h00C,
                          R_STATUS = 12'h010, R_RX_NO_SOCKET = 12'h014, R_RX_BAD = 12'h018,
                          R_RX_FIFO_DROPS = 12'h01C, R_TX_FRAMES = 12'h020, R_TX_DROPS = 12'h024,
                          R_RX_DATAGRAMS = 12'h028;
  localparam logic [11:0] S_CTRL = 12'h00, S_LOCAL_PORT = 12'h04, S_REMOTE_IP = 12'h08,
                          S_REMOTE_PORT = 12'h0C, S_MAC_HI = 12'h10, S_MAC_LO = 12'h14,
                          S_RX_DG = 12'h18, S_RX_DROPS = 12'h1C, S_TX_DG = 12'h20, S_TX_DROPS = 12'h24;

  // Node and peers.
  localparam bit [47:0] LOCAL_MAC = 48'h02_49_4B_52_4E_01;
  localparam bit [31:0] LOCAL_IP  = {8'd192, 8'd168, 8'd1, 8'd220};
  localparam bit [31:0] MASK      = 32'hFFFF_FF00;
  localparam bit [31:0] GATEWAY   = {8'd192, 8'd168, 8'd1, 8'd1};
  localparam bit [47:0] PEER_MAC  = 48'h00_11_22_33_44_55;
  localparam bit [31:0] PEER_IP   = {8'd192, 8'd168, 8'd1, 8'd10};
  localparam bit [47:0] PEER2_MAC = 48'h00_16_3E_AA_BB_CC;
  localparam bit [31:0] PEER2_IP  = {8'd192, 8'd168, 8'd1, 8'd11};
  localparam bit [47:0] GW_MAC    = 48'h00_0A_0B_0C_0D_0E;
  localparam bit [31:0] FAR_IP    = {8'd10, 8'd0, 8'd0, 8'd5};
  localparam bit [31:0] SUBNET_BC = {8'd192, 8'd168, 8'd1, 8'd255};

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic proto_clk = 1'b0;
  logic app_clk   = 1'b0;
  logic arstn     = 1'b0;
  logic proto_resetn;
  logic app_resetn;

  always #(PROTO_HALF) proto_clk = ~proto_clk;
  initial begin
    #3.7;
    forever #(APP_HALF) app_clk = ~app_clk;
  end

  rtlnet_reset_sync u_rst_p (.clk(proto_clk), .arstn(arstn), .resetn(proto_resetn));
  rtlnet_reset_sync u_rst_a (.clk(app_clk),   .arstn(arstn), .resetn(app_resetn));

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic [63:0] s_tdata;   logic [7:0] s_tkeep;   logic s_tvalid, s_tlast, s_tready;
  logic [63:0] m_tdata;   logic [7:0] m_tkeep;   logic m_tvalid, m_tlast, m_tready;
  logic [63:0] ma_tdata;  logic [7:0] ma_tkeep;  logic ma_tvalid, ma_tlast, ma_tready;
  logic [63:0] sa_tdata;  logic [7:0] sa_tkeep;  logic sa_tvalid, sa_tlast, sa_tready;
  logic        enable = 1'b1;
  logic        busy;
  logic        reg_wr_en = 1'b0;
  logic [11:0] reg_wr_addr = '0;
  logic [31:0] reg_wr_data = '0;
  logic        reg_rd_en = 1'b0;
  logic [11:0] reg_rd_addr = '0;
  logic [31:0] reg_rd_data;

  rtlnet_udp_socket #(
    .NUM_SOCKETS(NUM_SOCKETS), .UDP_RX_BUF_KB(16), .UDP_TX_BUF_KB(8), .RAM_STYLE("block")
  ) dut (
    .clk(proto_clk), .resetn(proto_resetn), .enable(enable),
    .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid), .s_axis_tlast(s_tlast),
    .s_axis_tready(s_tready),
    .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid), .m_axis_tlast(m_tlast),
    .m_axis_tready(m_tready),
    .local_mac(LOCAL_MAC), .local_ip(LOCAL_IP), .busy(busy),
    .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data),
    .app_clk(app_clk), .app_resetn(app_resetn),
    .m_axis_app_tdata(ma_tdata), .m_axis_app_tkeep(ma_tkeep), .m_axis_app_tvalid(ma_tvalid),
    .m_axis_app_tlast(ma_tlast), .m_axis_app_tready(ma_tready),
    .s_axis_app_tdata(sa_tdata), .s_axis_app_tkeep(sa_tkeep), .s_axis_app_tvalid(sa_tvalid),
    .s_axis_app_tlast(sa_tlast), .s_axis_app_tready(sa_tready),
    .local_mask(MASK), .local_gateway(GATEWAY)
  );

  // Bench wrapper side (proto_clk): frame source and reply sink.
  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(3)) u_src (
    .clk(proto_clk), .tdata(s_tdata), .tkeep(s_tkeep), .tlast(s_tlast), .tvalid(s_tvalid), .tready(s_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(17), .NAME("frames")) u_sink (
    .clk(proto_clk), .resetn(proto_resetn), .tdata(m_tdata), .tkeep(m_tkeep), .tlast(m_tlast),
    .tvalid(m_tvalid), .tready(m_tready));

  // Bench application side (app_clk).
  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(5)) u_app_src (
    .clk(app_clk), .tdata(sa_tdata), .tkeep(sa_tkeep), .tlast(sa_tlast), .tvalid(sa_tvalid), .tready(sa_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(29), .NAME("app")) u_app_sink (
    .clk(app_clk), .resetn(app_resetn), .tdata(ma_tdata), .tkeep(ma_tkeep), .tlast(ma_tlast),
    .tvalid(ma_tvalid), .tready(ma_tready));

  // Leaf contract checker.
  rtlnet_tb_leaf_busy_monitor #(.NAME("udp_socket")) u_busy_mon (
    .clk(proto_clk), .resetn(proto_resetn), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
    .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast), .busy(busy));

  // ---------------------------------------------------------------------------
  // Always-on monitors
  // ---------------------------------------------------------------------------
  // busy rises within 12 clocks of every input frame's last beat (or is high).
  int  rise_wait = -1;
  int  rise_errors = 0;
  always @(posedge proto_clk) begin
    if (proto_resetn === 1'b1) begin
      if (s_tvalid && s_tready && s_tlast) rise_wait = 0;
      if (rise_wait >= 0) begin
        if (busy) rise_wait = -1;
        else if (rise_wait == 12) begin
          if (rise_errors < 4) tb_error("busy did not rise within 12 clocks of an input frame's last beat");
          rise_errors++;
          rise_wait = -1;
        end else rise_wait++;
      end
    end
  end

  // No gap inside an output frame or an application datagram.
  bit out_in_frame = 0;
  bit app_in_frame = 0;
  int gap_errors   = 0;
  always @(posedge proto_clk) begin
    if (proto_resetn === 1'b1) begin
      if (out_in_frame && !m_tvalid && gap_errors < 4) begin
        gap_errors++;
        tb_error("gap inside an output frame");
      end
      if (m_tvalid && m_tready) out_in_frame = !m_tlast;
    end
  end
  always @(posedge app_clk) begin
    if (app_resetn === 1'b1) begin
      if (app_in_frame && !ma_tvalid && gap_errors < 4) begin
        gap_errors++;
        tb_error("gap inside an application datagram");
      end
      if (ma_tvalid && ma_tready) app_in_frame = !ma_tlast;
    end
  end

  // Watchdog.
  initial begin
    #(200ms);
    tb_error("watchdog timeout");
    tb_verdict(BENCH);
  end

  // ---------------------------------------------------------------------------
  // Expected counter values
  // ---------------------------------------------------------------------------
  int exp_no_socket = 0, exp_bad = 0, exp_fifo_drops = 0, exp_tx_frames = 0, exp_tx_drops = 0, exp_rx_dg = 0;
  int exp_s_rx[NUM_SOCKETS];
  int exp_s_rxd[NUM_SOCKETS];
  int exp_s_tx[NUM_SOCKETS];
  int exp_s_txd[NUM_SOCKETS];
  int exp_ident = 0;
  int unsigned lcg_state = 32'h2468_ACE1;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function automatic int unsigned rnd(input int unsigned range);
    lcg_state = lcg_state * 32'd1103515245 + 32'd12345;
    return (lcg_state >> 8) % range;
  endfunction

  function automatic bytes_t payload_bytes(input int n, input int seed);
    bytes_t q;
    for (int i = 0; i < n; i++) q.push_back(8'((i * 13 + seed * 7 + (i >> 3) + 1) & 8'hFF));
    return q;
  endfunction

  // Recompute the IPv4 header checksum of a frame after a field edit.
  function automatic void fix_ip_csum(ref bytes_t q);
    bit [15:0] c;
    q[24] = 8'h00;
    q[25] = 8'h00;
    c = inet_checksum(q, 14, 20);
    q[24] = c[15:8];
    q[25] = c[7:0];
  endfunction

  // A received frame as a NIC sends it: padded to 60 bytes with non-zero bytes.
  function automatic bytes_t rx_frame(input bit [47:0] src_mac, input bit [31:0] src_ip, input bit [31:0] dst_ip,
                                      input bit [15:0] sport, input bit [15:0] dport, input bytes_t payload,
                                      input bit with_csum = 1'b0);
    bytes_t f;
    f = udp_frame(LOCAL_MAC, src_mac, src_ip, dst_ip, sport, dport, payload, 16'h1234, with_csum);
    while (f.size() < 60) f.push_back(8'hA5);
    return f;
  endfunction

  // Metadata beats as stream bytes (beat byte 0 = tdata[7:0]).
  function automatic void push_word(ref bytes_t q, input bit [63:0] w);
    for (int i = 0; i < 8; i++) q.push_back(w[8*i +: 8]);
  endfunction

  function automatic bytes_t app_dgram(input bit [63:0] m0, input bit [63:0] m1, input bytes_t payload);
    bytes_t q;
    push_word(q, m0);
    push_word(q, m1);
    for (int i = 0; i < $size(payload); i++) q.push_back(payload[i]);
    return q;
  endfunction

  function automatic bit [63:0] meta0(input bit [31:0] ip, input bit [15:0] port, input bit [15:0] len);
    return {ip, port, len};
  endfunction

  function automatic bit [63:0] meta1(input bit [7:0] sock, input bit [7:0] flags, input bit [47:0] mac);
    return {sock, flags, mac};
  endfunction

  // Register bus (proto_clk): data is read the clock after the strobe.
  task automatic reg_wr(input logic [11:0] a, input logic [31:0] d);
    @(posedge proto_clk);
    reg_wr_en   <= 1'b1;
    reg_wr_addr <= a;
    reg_wr_data <= d;
    @(posedge proto_clk);
    reg_wr_en   <= 1'b0;
  endtask

  task automatic reg_rd(input logic [11:0] a, output logic [31:0] d);
    @(posedge proto_clk);
    reg_rd_en   <= 1'b1;
    reg_rd_addr <= a;
    @(posedge proto_clk);
    reg_rd_en   <= 1'b0;
    @(posedge proto_clk);
    #1;
    d = reg_rd_data;
  endtask

  task automatic reg_expect(input logic [11:0] a, input logic [31:0] exp, input string what);
    logic [31:0] d;
    reg_rd(a, d);
    tb_check(d === exp, $sformatf("%s: reg 0x%03x = 0x%08x, expected 0x%08x", what, a, d, exp));
  endtask

  function automatic logic [11:0] sreg(input int n, input logic [11:0] field);
    return 12'h100 + 12'(n * 12'h40) + field;
  endfunction

  task automatic sock_config(input int n, input bit en, input bit connect, input bit [15:0] port);
    reg_wr(sreg(n, S_LOCAL_PORT), {16'd0, port});
    reg_wr(sreg(n, S_CTRL), {30'd0, connect, en});
  endtask

  task automatic settle(input int cycles = 400);
    repeat (cycles) @(posedge proto_clk);
    while (busy) @(posedge proto_clk);
  endtask

  task automatic check_counters(input string what);
    settle();
    reg_expect(R_RX_NO_SOCKET,  exp_no_socket,  {what, " RX_NO_SOCKET"});
    reg_expect(R_RX_BAD,        exp_bad,        {what, " RX_BAD"});
    reg_expect(R_RX_FIFO_DROPS, exp_fifo_drops, {what, " RX_FIFO_DROPS"});
    reg_expect(R_TX_FRAMES,     exp_tx_frames,  {what, " TX_FRAMES"});
    reg_expect(R_TX_DROPS,      exp_tx_drops,   {what, " TX_DROPS"});
    reg_expect(R_RX_DATAGRAMS,  exp_rx_dg,      {what, " RX_DATAGRAMS"});
    for (int n = 0; n < NUM_SOCKETS; n++) begin
      reg_expect(sreg(n, S_RX_DG),     exp_s_rx[n],  $sformatf("%s sock%0d RX_DATAGRAMS", what, n));
      reg_expect(sreg(n, S_RX_DROPS),  exp_s_rxd[n], $sformatf("%s sock%0d RX_DROPS", what, n));
      reg_expect(sreg(n, S_TX_DG),     exp_s_tx[n],  $sformatf("%s sock%0d TX_DATAGRAMS", what, n));
      reg_expect(sreg(n, S_TX_DROPS),  exp_s_txd[n], $sformatf("%s sock%0d TX_DROPS", what, n));
    end
  endtask

  // Wrapper delivery rules: no frame while the leaf is busy, 16 idle clocks before.
  task automatic wrapper_send(input bytes_t f);
    while (busy) @(posedge proto_clk);
    u_src.idle(16);
    u_src.send(f);
  endtask

  // Next application datagram must be exactly meta 0, meta 1, payload.
  task automatic expect_rx(input bit [7:0] sock, input bit [31:0] ip, input bit [15:0] port, input bit [47:0] mac,
                           input bit [7:0] flags, input bytes_t payload, input string what);
    bytes_t got;
    bytes_t exp;
    bit     ok;
    string  why;
    u_app_sink.get(got, TMO, ok);
    tb_check(ok, {what, ": no datagram delivered"});
    if (!ok) return;
    exp = app_dgram(meta0(ip, port, 16'(payload.size())), meta1(sock, flags, mac), payload);
    tb_check(bytes_equal(got, exp, why), {what, ": datagram ", why, " got ", hexdump(got, 32)});
  endtask

  task automatic expect_no_rx(input string what);
    bit none;
    u_app_sink.expect_none(300, none);
    tb_check(none, {what, ": unexpected datagram delivered"});
    if (!none) u_app_sink.frames.delete();
  endtask

  // Next frame on m_axis must equal the bench-built UDP frame.
  task automatic expect_tx(input bit [47:0] dmac, input bit [31:0] dip, input bit [15:0] sport, input bit [15:0] dport,
                           input bytes_t payload, input string what);
    bytes_t got;
    bytes_t exp;
    bit     ok;
    string  why;
    u_sink.get(got, TMO, ok);
    tb_check(ok, {what, ": no frame sent"});
    if (!ok) return;
    exp = udp_frame(dmac, LOCAL_MAC, LOCAL_IP, dip, sport, dport, payload, 16'(exp_ident));
    exp_ident++;
    tb_check(bytes_equal(got, exp, why), {what, ": frame ", why, " got ", hexdump(got, 48)});
    if (got.size() >= 42) begin
      tb_check(inet_sum(got, 14, 20) == 16'hFFFF, {what, ": IPv4 header checksum does not verify"});
      tb_check(get16(got, 40) == 16'h0000, {what, ": UDP checksum not 0"});
    end
  endtask

  task automatic expect_no_tx(input string what);
    bit none;
    u_sink.expect_none(400, none);
    tb_check(none, {what, ": unexpected frame sent"});
    if (!none) u_sink.frames.delete();
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin : main
    bytes_t      pl;
    bytes_t      f;
    logic [31:0] d;
    int          lens[$];

    for (int n = 0; n < NUM_SOCKETS; n++) begin
      exp_s_rx[n] = 0; exp_s_rxd[n] = 0; exp_s_tx[n] = 0; exp_s_txd[n] = 0;
    end
    #100;
    arstn = 1'b1;
    repeat (20) @(posedge proto_clk);

    // ---- 1. Registers ------------------------------------------------------
    reg_expect(R_ID,      32'h5544_5053, "ID");
    reg_expect(R_VERSION, 32'h1022_2026, "VERSION");
    reg_expect(R_CAPS,    32'h0108_1004, "CAPS");
    reg_expect(R_CTRL,    32'h0000_0000, "CTRL reset");
    reg_expect(R_STATUS,  32'h0000_0001, "STATUS reset");
    reg_expect(12'h02C,   32'h0, "undefined global");
    reg_expect(12'h0FC,   32'h0, "undefined global top");
    reg_expect(12'h200,   32'h0, "socket 4 (absent)");
    reg_expect(sreg(0, 12'h28), 32'h0, "undefined socket field");
    for (int n = 0; n < NUM_SOCKETS; n++) begin
      reg_expect(sreg(n, S_CTRL), 32'h0, $sformatf("sock%0d CTRL reset", n));
      reg_expect(sreg(n, S_LOCAL_PORT), 32'h0, $sformatf("sock%0d LOCAL_PORT reset", n));
      reg_wr(sreg(n, S_REMOTE_IP),   32'hC0A8_0100 + n);
      reg_wr(sreg(n, S_REMOTE_PORT), 32'hFFFF_1000 + n);
      reg_wr(sreg(n, S_MAC_HI),      32'hFFFF_AB00 + n);
      reg_wr(sreg(n, S_MAC_LO),      32'h1234_5600 + n);
      reg_wr(sreg(n, S_CTRL),        32'hFFFF_FFFC);
      reg_expect(sreg(n, S_REMOTE_IP),   32'hC0A8_0100 + n, "REMOTE_IP read-back");
      reg_expect(sreg(n, S_REMOTE_PORT), 32'h0000_1000 + n, "REMOTE_PORT read-back");
      reg_expect(sreg(n, S_MAC_HI),      32'h0000_AB00 + n, "REMOTE_MAC_HI read-back");
      reg_expect(sreg(n, S_MAC_LO),      32'h1234_5600 + n, "REMOTE_MAC_LO read-back");
      reg_expect(sreg(n, S_CTRL),        32'h0, "CTRL bits 31:2 ignored");
      reg_wr(sreg(n, S_REMOTE_IP), 0); reg_wr(sreg(n, S_REMOTE_PORT), 0);
      reg_wr(sreg(n, S_MAC_HI), 0);    reg_wr(sreg(n, S_MAC_LO), 0);
    end
    reg_wr(12'h02C, 32'hDEAD_BEEF);
    reg_expect(12'h02C, 32'h0, "write to undefined offset ignored");
    reg_wr(R_CTRL, 32'h0000_0001);
    reg_expect(R_CTRL, 32'h0000_0001, "CTRL csum bit read-back");
    reg_wr(R_CTRL, 32'h0000_0000);

    // Socket table: 0 -> 5000; 1 -> 7 with CONNECT_ON_RX; 2 -> 7 (shadowed); 3 -> 9000 disabled.
    sock_config(0, 1, 0, 16'd5000);
    sock_config(1, 1, 1, 16'd7);
    sock_config(2, 1, 0, 16'd7);
    sock_config(3, 0, 0, 16'd9000);
    reg_expect(sreg(1, S_CTRL), 32'h3, "sock1 CTRL read-back");
    reg_expect(sreg(3, S_LOCAL_PORT), 32'd9000, "sock3 LOCAL_PORT read-back");

    // ---- 2. Receive, every length 0..64 and large ones ---------------------
    for (int L = 0; L <= 64; L++) lens.push_back(L);
    lens.push_back(100); lens.push_back(255); lens.push_back(256); lens.push_back(511);
    lens.push_back(1000); lens.push_back(1465); lens.push_back(1471); lens.push_back(MAX_PAY);
    for (int i = 0; i < $size(lens); i++) begin
      pl = payload_bytes(lens[i], i);
      wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'(40000 + i), 16'd5000, pl));
      expect_rx(8'd0, PEER_IP, 16'(40000 + i), PEER_MAC, 8'h00, pl, $sformatf("rx len %0d", lens[i]));
      exp_rx_dg++; exp_s_rx[0]++;
    end
    // Gappy input stream.
    u_src.gap_pct = 35;
    for (int L = 0; L <= 40; L++) begin
      pl = payload_bytes(L, 100 + L);
      wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd41000, 16'd5000, pl));
      expect_rx(8'd0, PEER_IP, 16'd41000, PEER_MAC, 8'h00, pl, $sformatf("rx gappy len %0d", L));
      exp_rx_dg++; exp_s_rx[0]++;
    end
    pl = payload_bytes(MAX_PAY, 7);
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd41001, 16'd5000, pl));
    expect_rx(8'd0, PEER_IP, 16'd41001, PEER_MAC, 8'h00, pl, "rx gappy 1472");
    exp_rx_dg++; exp_s_rx[0]++;
    u_src.gap_pct = 0;
    // Exact-length frame (no padding) and stalling application.
    u_app_sink.ready_pct = 40;
    for (int L = 18; L <= 26; L++) begin
      pl = payload_bytes(L, 300 + L);
      wrapper_send(udp_frame(LOCAL_MAC, PEER_MAC, PEER_IP, LOCAL_IP, 16'd42000, 16'd5000, pl));
      expect_rx(8'd0, PEER_IP, 16'd42000, PEER_MAC, 8'h00, pl, $sformatf("rx unpadded len %0d", L));
      exp_rx_dg++; exp_s_rx[0]++;
    end
    u_app_sink.ready_pct = 100;

    // Shared port 7: socket 1 wins; it learns the sender (CONNECT_ON_RX).
    pl = payload_bytes(33, 1);
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd43000, 16'd7, pl));
    expect_rx(8'd1, PEER_IP, 16'd43000, PEER_MAC, 8'h00, pl, "rx shared port -> sock1");
    exp_rx_dg++; exp_s_rx[1]++;
    settle(50);
    reg_expect(sreg(1, S_REMOTE_IP),   PEER_IP, "CONNECT_ON_RX REMOTE_IP");
    reg_expect(sreg(1, S_REMOTE_PORT), 32'd43000, "CONNECT_ON_RX REMOTE_PORT");
    reg_expect(sreg(1, S_MAC_HI),      {16'd0, PEER_MAC[47:32]}, "CONNECT_ON_RX MAC_HI");
    reg_expect(sreg(1, S_MAC_LO),      PEER_MAC[31:0], "CONNECT_ON_RX MAC_LO");
    pl = payload_bytes(5, 2);
    wrapper_send(rx_frame(PEER2_MAC, PEER2_IP, LOCAL_IP, 16'd43001, 16'd7, pl));
    expect_rx(8'd1, PEER2_IP, 16'd43001, PEER2_MAC, 8'h00, pl, "rx sock1 second sender");
    exp_rx_dg++; exp_s_rx[1]++;
    settle(50);
    reg_expect(sreg(1, S_REMOTE_IP),   PEER2_IP, "CONNECT_ON_RX follows last sender IP");
    reg_expect(sreg(1, S_REMOTE_PORT), 32'd43001, "CONNECT_ON_RX follows last sender port");
    reg_expect(sreg(1, S_MAC_LO),      PEER2_MAC[31:0], "CONNECT_ON_RX follows last sender MAC");
    // Socket 1 disabled: socket 2 takes port 7 and keeps its (zero) remote registers.
    reg_wr(sreg(1, S_CTRL), 32'h2);
    pl = payload_bytes(64, 3);
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd43002, 16'd7, pl));
    expect_rx(8'd2, PEER_IP, 16'd43002, PEER_MAC, 8'h00, pl, "rx port 7 -> sock2 with sock1 disabled");
    exp_rx_dg++; exp_s_rx[2]++;
    settle(50);
    reg_expect(sreg(2, S_REMOTE_IP), 32'h0, "sock2 without CONNECT_ON_RX keeps REMOTE_IP");
    reg_wr(sreg(1, S_CTRL), 32'h3);
    // Unknown port, disabled socket.
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd1, 16'd1234, payload_bytes(10, 4)));
    exp_no_socket++;
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd1, 16'd9000, payload_bytes(10, 5)));
    exp_no_socket++;
    expect_no_rx("no socket");
    check_counters("after delivery");

    // ---- 3. Rejections and ignored frames ----------------------------------
    pl = payload_bytes(30, 9);
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl); f[20] = f[20] | 8'h20; fix_ip_csum(f);
    wrapper_send(f); exp_bad++;                                                    // MF
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl); f[21] = 8'h01; fix_ip_csum(f);
    wrapper_send(f); exp_bad++;                                                    // offset 1
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl); f[20] = 8'h00; f[21] = 8'h00;
    fix_ip_csum(f); wrapper_send(f);                                               // DF clear, offset 0: valid
    expect_rx(8'd0, PEER_IP, 16'd2, PEER_MAC, 8'h00, pl, "rx DF clear accepted");
    exp_rx_dg++; exp_s_rx[0]++;
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl); f[14] = 8'h46; fix_ip_csum(f);
    wrapper_send(f); exp_bad++;                                                    // IHL 6
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl); f[14] = 8'h65; fix_ip_csum(f);
    wrapper_send(f); exp_bad++;                                                    // version 6
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl); f[39] = f[39] - 8'd1;
    wrapper_send(f); exp_bad++;                                                    // UDP length - 1
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl); f[17] = f[17] + 8'd1; fix_ip_csum(f);
    wrapper_send(f); exp_bad++;                                                    // IP length + 1
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl);
    f[16] = 8'h00; f[17] = 8'd27; f[38] = 8'h00; f[39] = 8'd7; fix_ip_csum(f);
    wrapper_send(f); exp_bad++;                                                    // total length 27
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, payload_bytes(MAX_PAY + 1, 1));
    wrapper_send(f); exp_bad++;                                                    // total length 1501
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, payload_bytes(100, 1)); void'(f.pop_back());
    wrapper_send(f); exp_bad++;                                                    // truncated by 1 byte
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, payload_bytes(23, 1));
    for (int k = 0; k < 9; k++) void'(f.pop_back());
    wrapper_send(f); exp_bad++;                                                    // truncated in the final word
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, payload_bytes(0, 1));
    while (f.size() > 41) void'(f.pop_back());
    wrapper_send(f); exp_bad++;                                                    // zero length, 41 bytes
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl); f[24] = f[24] ^ 8'h01;
    wrapper_send(f); exp_bad++;                                                    // header checksum
    expect_no_rx("rejected frames");
    // Ignored: ARP, ICMP, UDP for another host, another subnet's broadcast, frame ending in the header.
    f = eth_header(48'hFFFF_FFFF_FFFF, PEER_MAC, 16'h0806);
    for (int k = 0; k < 46; k++) f.push_back(8'(k));
    wrapper_send(f);
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl); f[23] = 8'd1; fix_ip_csum(f);
    wrapper_send(f);
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, {8'd192, 8'd168, 8'd1, 8'd77}, 16'd2, 16'd5000, pl));
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, {8'd192, 8'd168, 8'd2, 8'd255}, 16'd2, 16'd5000, pl));
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd2, 16'd5000, pl);
    while (f.size() > 30) void'(f.pop_back());
    wrapper_send(f);
    expect_no_rx("ignored frames");
    check_counters("after rejections");

    // ---- 4. Broadcast and off-subnet sender ---------------------------------
    pl = payload_bytes(20, 11);
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, 32'hFFFF_FFFF, 16'd44000, 16'd5000, pl));
    expect_rx(8'd0, PEER_IP, 16'd44000, PEER_MAC, 8'h01, pl, "limited broadcast");
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, SUBNET_BC, 16'd44001, 16'd5000, pl));
    expect_rx(8'd0, PEER_IP, 16'd44001, PEER_MAC, 8'h01, pl, "subnet broadcast");
    wrapper_send(rx_frame(GW_MAC, FAR_IP, LOCAL_IP, 16'd44002, 16'd5000, pl));
    expect_rx(8'd0, FAR_IP, 16'd44002, GW_MAC, 8'h02, pl, "off-subnet sender");
    exp_rx_dg += 3; exp_s_rx[0] += 3;

    // ---- 5. UDP checksum ----------------------------------------------------
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd45000, 16'd5000, pl, 1'b1); f[50] = f[50] ^ 8'h80;
    wrapper_send(f);                                                               // check off: delivered
    pl[8] = pl[8] ^ 8'h80;
    expect_rx(8'd0, PEER_IP, 16'd45000, PEER_MAC, 8'h00, pl, "bad UDP checksum ignored when CTRL bit 0 clear");
    pl[8] = pl[8] ^ 8'h80;
    exp_rx_dg++; exp_s_rx[0]++;
    reg_wr(R_CTRL, 32'h1);
    for (int L = 0; L <= 17; L++) begin
      bytes_t p2;
      p2 = payload_bytes(L, 500 + L);
      wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd45001, 16'd5000, p2, 1'b1));
      expect_rx(8'd0, PEER_IP, 16'd45001, PEER_MAC, 8'h00, p2, $sformatf("good UDP checksum len %0d", L));
      exp_rx_dg++; exp_s_rx[0]++;
    end
    begin
      bytes_t p2;
      p2 = payload_bytes(MAX_PAY, 77);
      wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd45002, 16'd5000, p2, 1'b1));
      expect_rx(8'd0, PEER_IP, 16'd45002, PEER_MAC, 8'h00, p2, "good UDP checksum 1472");
      exp_rx_dg++; exp_s_rx[0]++;
      p2 = payload_bytes(13, 78);
      wrapper_send(rx_frame(PEER_MAC, PEER_IP, 32'hFFFF_FFFF, 16'd45003, 16'd5000, p2, 1'b1));
      expect_rx(8'd0, PEER_IP, 16'd45003, PEER_MAC, 8'h01, p2, "good UDP checksum to broadcast");
      exp_rx_dg++; exp_s_rx[0]++;
    end
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd45004, 16'd5000, pl, 1'b0));
    expect_rx(8'd0, PEER_IP, 16'd45004, PEER_MAC, 8'h00, pl, "zero UDP checksum accepted");
    exp_rx_dg++; exp_s_rx[0]++;
    wrapper_send(f); exp_bad++;                                                    // payload bit flipped
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd45005, 16'd5000, payload_bytes(0, 1), 1'b1);
    f[41] = f[41] ^ 8'h01;
    wrapper_send(f); exp_bad++;                                                    // zero length, bad sum
    f = rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd45006, 16'd5000, payload_bytes(7, 1), 1'b1);
    f[48] = f[48] ^ 8'h01;
    wrapper_send(f); exp_bad++;                                                    // 7 bytes, last byte bad
    expect_no_rx("bad UDP checksum with CTRL bit 0 set");
    reg_wr(R_CTRL, 32'h0);
    check_counters("after checksum");

    // ---- 6/7. RX FIFO full with the application stalled ---------------------
    u_app_sink.ready_pct = 0;
    for (int i = 0; i < RX_SLOTS + 4; i++)
      wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'(46000 + i), 16'd5000, payload_bytes(40, 600 + i)));
    exp_fifo_drops += 4; exp_s_rxd[0] += 4; exp_rx_dg += RX_SLOTS; exp_s_rx[0] += RX_SLOTS;
    settle(200);
    reg_rd(R_STATUS, d);
    tb_check(d[3] === 1'b1, "STATUS RX_FIFO_FULL set with the application stalled");
    check_counters("RX FIFO full");
    u_app_sink.ready_pct = 100;
    for (int i = 0; i < RX_SLOTS; i++)
      expect_rx(8'd0, PEER_IP, 16'(46000 + i), PEER_MAC, 8'h00, payload_bytes(40, 600 + i),
                $sformatf("kept datagram %0d after FIFO full", i));
    expect_no_rx("dropped datagrams after FIFO full");
    reg_rd(R_STATUS, d);
    tb_check(d[3] === 1'b0, "STATUS RX_FIFO_FULL clear after drain");

    // ---- 8. Transmit with explicit metadata ---------------------------------
    u_sink.ready_pct = 70;
    for (int L = 0; L <= 64; L++) begin
      pl = payload_bytes(L, 700 + L);
      u_app_src.send(app_dgram(meta0(PEER_IP, 16'(50000 + L), 16'(L)), meta1(8'd0, 8'h00, PEER_MAC), pl));
      expect_tx(PEER_MAC, PEER_IP, 16'd5000, 16'(50000 + L), pl, $sformatf("tx len %0d", L));
      exp_tx_frames++; exp_s_tx[0]++;
    end
    lens = {100, 255, 256, 500, 1000, 1465, 1470, 1471, MAX_PAY};
    for (int i = 0; i < $size(lens); i++) begin
      pl = payload_bytes(lens[i], 800 + i);
      u_app_src.send(app_dgram(meta0(PEER2_IP, 16'd51000, 16'(lens[i])), meta1(8'd0, 8'h00, PEER2_MAC), pl));
      expect_tx(PEER2_MAC, PEER2_IP, 16'd5000, 16'd51000, pl, $sformatf("tx len %0d", lens[i]));
      exp_tx_frames++; exp_s_tx[0]++;
    end
    // Socket 2 source port; gappy application source.
    u_app_src.gap_pct = 30;
    pl = payload_bytes(77, 9);
    u_app_src.send(app_dgram(meta0(FAR_IP, 16'd52000, 16'd77), meta1(8'd2, 8'h00, GW_MAC), pl));
    expect_tx(GW_MAC, FAR_IP, 16'd7, 16'd52000, pl, "tx from sock2, gappy source");
    exp_tx_frames++; exp_s_tx[2]++;
    u_app_src.gap_pct = 0;
    // USE_SOCKET_REMOTE: written registers (socket 0) and learned ones (socket 1).
    reg_wr(sreg(0, S_REMOTE_IP), {8'd192, 8'd168, 8'd1, 8'd33});
    reg_wr(sreg(0, S_REMOTE_PORT), 32'd6000);
    reg_wr(sreg(0, S_MAC_HI), 32'h0000_AABB);
    reg_wr(sreg(0, S_MAC_LO), 32'hCCDD_EEFF);
    pl = payload_bytes(50, 10);
    u_app_src.send(app_dgram(meta0(32'h0102_0304, 16'd1, 16'd50), meta1(8'd0, 8'h01, 48'h1111_2222_3333), pl));
    expect_tx(48'hAABB_CCDD_EEFF, {8'd192, 8'd168, 8'd1, 8'd33}, 16'd5000, 16'd6000, pl, "tx USE_SOCKET_REMOTE");
    exp_tx_frames++; exp_s_tx[0]++;
    pl = payload_bytes(0, 10);
    u_app_src.send(app_dgram(meta0(32'h0, 16'd0, 16'd0), meta1(8'd1, 8'h01, 48'h0), pl));
    expect_tx(PEER2_MAC, PEER2_IP, 16'd7, 16'd43001, pl, "tx USE_SOCKET_REMOTE learned remote, zero length");
    exp_tx_frames++; exp_s_tx[1]++;
    check_counters("after transmit");

    // ---- 9. Transmit drops ---------------------------------------------------
    pl = payload_bytes(10, 11);
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd10), meta1(8'd3, 8'h00, PEER_MAC), pl));
    exp_tx_drops++; exp_s_txd[3]++;                                                // disabled socket
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd10), meta1(8'd4, 8'h00, PEER_MAC), pl));
    exp_tx_drops++;                                                                // index 4
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd0), meta1(8'd255, 8'h00, PEER_MAC), payload_bytes(0, 1)));
    exp_tx_drops++;                                                                // index 255, zero length
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd11), meta1(8'd0, 8'h00, PEER_MAC), pl));
    exp_tx_drops++; exp_s_txd[0]++;                                                // one byte short
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd9), meta1(8'd0, 8'h00, PEER_MAC), pl));
    exp_tx_drops++; exp_s_txd[0]++;                                                // one byte long
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd16), meta1(8'd0, 8'h00, PEER_MAC), pl));
    exp_tx_drops++; exp_s_txd[0]++;                                                // one beat short
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd0), meta1(8'd0, 8'h00, PEER_MAC), payload_bytes(5, 1)));
    exp_tx_drops++; exp_s_txd[0]++;                                                // zero length + payload
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd5), meta1(8'd0, 8'h00, PEER_MAC), payload_bytes(0, 1)));
    exp_tx_drops++; exp_s_txd[0]++;                                                // length, no payload
    begin
      bytes_t m;
      push_word(m, meta0(PEER_IP, 16'd1, 16'd0));
      u_app_src.send(m);
    end
    exp_tx_drops++;                                                                // meta 0 only
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'(MAX_PAY + 1)), meta1(8'd0, 8'h00, PEER_MAC),
                             payload_bytes(MAX_PAY + 1, 2)));
    exp_tx_drops++; exp_s_txd[0]++;                                                // 1473 bytes
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd2100), meta1(8'd0, 8'h00, PEER_MAC),
                             payload_bytes(2100, 3)));
    exp_tx_drops++; exp_s_txd[0]++;                                                // longer than a slot
    pl = payload_bytes(21, 12);
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd53000, 16'd21), meta1(8'd0, 8'h00, PEER_MAC), pl));
    expect_tx(PEER_MAC, PEER_IP, 16'd5000, 16'd53000, pl, "tx good datagram after the drops");
    exp_tx_frames++; exp_s_tx[0]++;
    expect_no_tx("dropped datagrams");
    check_counters("after transmit drops");

    // ---- 10. Simultaneous receive and transmit -------------------------------
    begin
      bytes_t tx_pl[$];
      bytes_t rx_pl[$];
      int     tx_port[$];
      int     id0;
      for (int i = 0; i < 30; i++) begin
        tx_pl.push_back(payload_bytes(rnd(MAX_PAY + 1), 900 + i));
        rx_pl.push_back(payload_bytes(rnd(300), 950 + i));
        tx_port.push_back(54000 + i);
      end
      id0 = exp_ident;
      u_sink.ready_pct = 75;
      u_app_sink.ready_pct = 90;
      fork
        for (int i = 0; i < 30; i++)
          u_app_src.send(app_dgram(meta0(PEER_IP, 16'(tx_port[i]), 16'(tx_pl[i].size())),
                                   meta1(8'd0, 8'h00, PEER_MAC), tx_pl[i]));
        for (int i = 0; i < 30; i++) begin
          wrapper_send(rx_frame(PEER2_MAC, PEER2_IP, LOCAL_IP, 16'(55000 + i), 16'd5000, rx_pl[i]));
          u_src.idle(rnd(40));
        end
        for (int i = 0; i < 30; i++)
          expect_tx(PEER_MAC, PEER_IP, 16'd5000, 16'(tx_port[i]), tx_pl[i], $sformatf("concurrent tx %0d", i));
        for (int i = 0; i < 30; i++)
          expect_rx(8'd0, PEER2_IP, 16'(55000 + i), PEER2_MAC, 8'h00, rx_pl[i], $sformatf("concurrent rx %0d", i));
      join
      tb_check(exp_ident == id0 + 30, "concurrent: 30 frames sent");
      exp_tx_frames += 30; exp_s_tx[0] += 30; exp_rx_dg += 30; exp_s_rx[0] += 30;
      u_sink.ready_pct = 100;
      u_app_sink.ready_pct = 100;
    end
    check_counters("after concurrent traffic");

    // A frame starting while the leaf is busy (no gap after the previous one) is ignored whole.
    pl = payload_bytes(200, 13);
    while (busy) @(posedge proto_clk);
    u_src.idle(16);
    u_src.send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd56000, 16'd5000, pl));
    u_src.send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd56001, 16'd5000, payload_bytes(20, 14)));
    expect_rx(8'd0, PEER_IP, 16'd56000, PEER_MAC, 8'h00, pl, "first of two back-to-back frames");
    expect_no_rx("frame starting while busy");
    exp_rx_dg++; exp_s_rx[0]++;
    // The next well-spaced frame is taken again.
    pl = payload_bytes(3, 15);
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd56002, 16'd5000, pl));
    expect_rx(8'd0, PEER_IP, 16'd56002, PEER_MAC, 8'h00, pl, "frame after the ignored one");
    exp_rx_dg++; exp_s_rx[0]++;

    // Leaf disabled: frames ignored, application datagrams dropped.
    enable = 1'b0;
    reg_expect(R_STATUS, 32'h0, "STATUS with the leaf disabled");
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd57000, 16'd5000, payload_bytes(8, 1)));
    u_app_src.send(app_dgram(meta0(PEER_IP, 16'd1, 16'd8), meta1(8'd0, 8'h00, PEER_MAC), payload_bytes(8, 1)));
    exp_tx_drops++; exp_s_txd[0]++;
    expect_no_rx("leaf disabled receive");
    expect_no_tx("leaf disabled transmit");
    check_counters("leaf disabled");
    enable = 1'b1;
    pl = payload_bytes(9, 16);
    wrapper_send(rx_frame(PEER_MAC, PEER_IP, LOCAL_IP, 16'd57001, 16'd5000, pl));
    expect_rx(8'd0, PEER_IP, 16'd57001, PEER_MAC, 8'h00, pl, "receive after re-enable");
    exp_rx_dg++; exp_s_rx[0]++;
    check_counters("after re-enable");

    // CNT_CLEAR.
    reg_wr(R_CTRL, 32'h0001_0000);
    reg_expect(R_CTRL, 32'h0, "CNT_CLEAR reads 0");
    exp_no_socket = 0; exp_bad = 0; exp_fifo_drops = 0; exp_tx_frames = 0; exp_tx_drops = 0; exp_rx_dg = 0;
    for (int n = 0; n < NUM_SOCKETS; n++) begin
      exp_s_rx[n] = 0; exp_s_rxd[n] = 0; exp_s_tx[n] = 0; exp_s_txd[n] = 0;
    end
    check_counters("after CNT_CLEAR");

    tb_check(u_src.sent > 0 && u_app_src.sent > 0, "stimulus ran");
    tb_verdict(BENCH);
  end

endmodule
