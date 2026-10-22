// -----------------------------------------------------------------------------
// File: tb_rtlnet_udp_echo.sv
// Purpose: self-checking bench for rtlnet_udp_echo on the real socket layer:
//   rtlnet_udp_socket (leaf, proto_clk) with its application streams looped
//   through rtlnet_udp_echo (app_clk), registers through AXI4-Lite on a
//   100 MHz CPU clock.
// Cases:
//   1. Echo register reset values; a partial write is ignored.
//   2. Disabled (reset state): datagrams consumed and counted in DISCARDED.
//   3. Socket select: only the selected socket is echoed, others discarded;
//      SOCKET_ANY echoes all three sockets; a broadcast datagram is answered
//      to its sender's unicast address.
//   4. Every length 0..64 and up to 1472: the reply is the request with the
//      addresses swapped (bench-built frame from rtlnet_tb_pkg), byte-exact,
//      identification counting up, with random reply-side stalls.
//   5. 120 random datagrams on random sockets with up to three in flight and
//      random stalls, all answered in order.
//   6. Overload: reply side stalled while 30 datagrams arrive; the replies
//      are an in-order subsequence of the requests, the socket layer counts
//      the rest as RX FIFO drops, and traffic resumes (no deadlock).
//   7. Disable mid-run, counters ECHOED_DATAGRAMS / ECHOED_BYTES / DISCARDED
//      against the bench's own count, CNT_CLEAR.
//   Always on: rtlnet_tb_leaf_busy_monitor on the socket layer.
//   Clocks: proto_clk 50 MHz, app_clk 62.5 MHz (default) or proto_clk itself
//   (+define+TB_APP_PROTO, the Nexys Video configuration), s_axi_aclk 100 MHz.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Run: powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_udp_echo
//        -Filelist cores/rtlnet_udp_echo/testbench/tb_rtlnet_udp_echo.f
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_udp_echo;

  import rtlnet_tb_pkg::*;

  localparam string BENCH   = "tb_rtlnet_udp_echo";
  localparam int    TMO     = 60000;
  localparam int    MAX_PAY = 1472;

  // Echo registers (driver/rtlnet_udp_echo.h).
  localparam logic [11:0] E_ID = 12'h000, E_VERSION = 12'h004, E_CAPS = 12'h008, E_CTRL = 12'h00C,
                          E_STATUS = 12'h010, E_ECHOED = 12'h014, E_BYTES = 12'h018, E_DISCARDED = 12'h01C;
  localparam logic [31:0] CTRL_ENABLE = 32'h1, CTRL_ANY = 32'h2, CTRL_CLEAR = 32'h0001_0000;

  localparam bit [47:0] LOCAL_MAC = 48'h02_49_4B_52_4E_01;
  localparam bit [31:0] LOCAL_IP  = {8'd192, 8'd168, 8'd1, 8'd220};
  localparam bit [31:0] MASK      = 32'hFFFF_FF00;
  localparam bit [31:0] GATEWAY   = {8'd192, 8'd168, 8'd1, 8'd1};
  localparam bit [47:0] PEER_MAC  = 48'h00_11_22_33_44_55;
  localparam bit [31:0] PEER_IP   = {8'd192, 8'd168, 8'd1, 8'd10};

  // Sockets: index -> local port.
  localparam bit [15:0] PORT0 = 16'd7;
  localparam bit [15:0] PORT1 = 16'd5000;
  localparam bit [15:0] PORT2 = 16'd6000;

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic proto_clk = 1'b0;
  logic cpu_clk   = 1'b0;
  logic arstn     = 1'b0;
  logic proto_resetn;
  logic app_resetn;
  logic cpu_resetn;

  always #10.0 proto_clk = ~proto_clk;
  initial begin
    #1.3;
    forever #5.0 cpu_clk = ~cpu_clk;
  end
`ifdef TB_APP_PROTO
  wire app_clk;
  assign app_clk = proto_clk;
`else
  logic app_clk = 1'b0;
  initial begin
    #3.7;
    forever #8.0 app_clk = ~app_clk;
  end
`endif

  rtlnet_reset_sync u_rst_p (.clk(proto_clk), .arstn(arstn), .resetn(proto_resetn));
  rtlnet_reset_sync u_rst_a (.clk(app_clk),   .arstn(arstn), .resetn(app_resetn));
  rtlnet_reset_sync u_rst_c (.clk(cpu_clk),   .arstn(arstn), .resetn(cpu_resetn));

  // ---------------------------------------------------------------------------
  // Socket layer + echo
  // ---------------------------------------------------------------------------
  logic [63:0] s_tdata;   logic [7:0] s_tkeep;   logic s_tvalid, s_tlast, s_tready;
  logic [63:0] m_tdata;   logic [7:0] m_tkeep;   logic m_tvalid, m_tlast, m_tready;
  logic [63:0] rx_tdata;  logic [7:0] rx_tkeep;  logic rx_tvalid, rx_tlast, rx_tready;
  logic [63:0] tx_tdata;  logic [7:0] tx_tkeep;  logic tx_tvalid, tx_tlast, tx_tready;
  logic        busy;
  logic        reg_wr_en = 1'b0;
  logic [11:0] reg_wr_addr = '0;
  logic [31:0] reg_wr_data = '0;
  logic        reg_rd_en = 1'b0;
  logic [11:0] reg_rd_addr = '0;
  logic [31:0] reg_rd_data;

  logic [11:0] awaddr;  logic awvalid, awready;
  logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid, wready;
  logic [1:0]  bresp;   logic bvalid, bready;
  logic [11:0] araddr;  logic arvalid, arready;
  logic [31:0] rdata;   logic [1:0] rresp; logic rvalid, rready;

  rtlnet_udp_socket #(.NUM_SOCKETS(4), .UDP_RX_BUF_KB(16), .UDP_TX_BUF_KB(8), .RAM_STYLE("block")) u_socket (
    .clk(proto_clk), .resetn(proto_resetn), .enable(1'b1),
    .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid), .s_axis_tlast(s_tlast),
    .s_axis_tready(s_tready),
    .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid), .m_axis_tlast(m_tlast),
    .m_axis_tready(m_tready),
    .local_mac(LOCAL_MAC), .local_ip(LOCAL_IP), .busy(busy),
    .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data),
    .app_clk(app_clk), .app_resetn(app_resetn),
    .m_axis_app_tdata(rx_tdata), .m_axis_app_tkeep(rx_tkeep), .m_axis_app_tvalid(rx_tvalid),
    .m_axis_app_tlast(rx_tlast), .m_axis_app_tready(rx_tready),
    .s_axis_app_tdata(tx_tdata), .s_axis_app_tkeep(tx_tkeep), .s_axis_app_tvalid(tx_tvalid),
    .s_axis_app_tlast(tx_tlast), .s_axis_app_tready(tx_tready),
    .local_mask(MASK), .local_gateway(GATEWAY)
  );

  rtlnet_udp_echo dut (
    .app_clk(app_clk), .app_resetn(app_resetn), .s_axi_aclk(cpu_clk), .s_axi_aresetn(cpu_resetn),
    .s_axis_tdata(rx_tdata), .s_axis_tkeep(rx_tkeep), .s_axis_tvalid(rx_tvalid), .s_axis_tlast(rx_tlast),
    .s_axis_tready(rx_tready),
    .m_axis_tdata(tx_tdata), .m_axis_tkeep(tx_tkeep), .m_axis_tvalid(tx_tvalid), .m_axis_tlast(tx_tlast),
    .m_axis_tready(tx_tready),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
  );

  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(3)) u_src (
    .clk(proto_clk), .tdata(s_tdata), .tkeep(s_tkeep), .tlast(s_tlast), .tvalid(s_tvalid), .tready(s_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(41), .NAME("replies")) u_sink (
    .clk(proto_clk), .resetn(proto_resetn), .tdata(m_tdata), .tkeep(m_tkeep), .tlast(m_tlast),
    .tvalid(m_tvalid), .tready(m_tready));
  rtlnet_tb_axil_master #(.ADDR_W(12)) u_axi (
    .aclk(cpu_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .araddr(araddr), .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp),
    .rvalid(rvalid), .rready(rready));

  rtlnet_tb_leaf_busy_monitor #(.NAME("udp_socket")) u_busy_mon (
    .clk(proto_clk), .resetn(proto_resetn), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
    .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast), .busy(busy));

  initial begin
    #(300ms);
    tb_error("watchdog timeout");
    tb_verdict(BENCH);
  end

  // ---------------------------------------------------------------------------
  // Bench state and helpers
  // ---------------------------------------------------------------------------
  int          exp_echoed    = 0;
  int          exp_bytes     = 0;
  int          exp_discarded = 0;
  int          exp_ident     = 0;
  int unsigned lcg_state     = 32'h1357_9BDF;

  function automatic int unsigned rnd(input int unsigned range);
    lcg_state = lcg_state * 32'd1103515245 + 32'd12345;
    return (lcg_state >> 8) % range;
  endfunction

  function automatic bytes_t payload_bytes(input int n, input int seed);
    bytes_t q;
    for (int i = 0; i < n; i++) q.push_back(8'((i * 29 + seed * 11 + (i >> 4) + 3) & 8'hFF));
    return q;
  endfunction

  function automatic bit [15:0] sock_port(input int s);
    return (s == 0) ? PORT0 : ((s == 1) ? PORT1 : PORT2);
  endfunction

  // Request from the peer, padded like a NIC does.
  function automatic bytes_t request(input bit [31:0] dst_ip, input bit [15:0] sport, input bit [15:0] dport,
                                     input bytes_t payload);
    bytes_t f;
    f = udp_frame(LOCAL_MAC, PEER_MAC, PEER_IP, dst_ip, sport, dport, payload, 16'h4321);
    while (f.size() < 60) f.push_back(8'h5A);
    return f;
  endfunction

  task automatic reg_wr(input logic [11:0] a, input logic [31:0] d);
    @(posedge proto_clk);
    reg_wr_en <= 1'b1; reg_wr_addr <= a; reg_wr_data <= d;
    @(posedge proto_clk);
    reg_wr_en <= 1'b0;
  endtask

  task automatic reg_rd(input logic [11:0] a, output logic [31:0] d);
    @(posedge proto_clk);
    reg_rd_en <= 1'b1; reg_rd_addr <= a;
    @(posedge proto_clk);
    reg_rd_en <= 1'b0;
    @(posedge proto_clk);
    #1;
    d = reg_rd_data;
  endtask

  task automatic axi_expect(input logic [11:0] a, input logic [31:0] exp, input string what);
    logic [31:0] d;
    u_axi.rd(a, d);
    tb_check(d === exp, $sformatf("%s: echo reg 0x%03x = 0x%08x, expected 0x%08x", what, a, d, exp));
  endtask

  task automatic wrapper_send(input bytes_t f);
    while (busy) @(posedge proto_clk);
    u_src.idle(16);
    u_src.send(f);
  endtask

  // The reply to a request on socket s: addresses swapped, payload unchanged.
  task automatic expect_reply(input int s, input bit [15:0] peer_port, input bytes_t payload, input string what);
    bytes_t got;
    bytes_t exp;
    bit     ok;
    string  why;
    u_sink.get(got, TMO, ok);
    tb_check(ok, {what, ": no reply"});
    if (!ok) return;
    exp = udp_frame(PEER_MAC, LOCAL_MAC, LOCAL_IP, PEER_IP, sock_port(s), peer_port, payload, 16'(exp_ident));
    exp_ident++;
    tb_check(bytes_equal(got, exp, why), {what, ": reply ", why, " got ", hexdump(got, 48)});
    if (got.size() >= 42) tb_check(inet_sum(got, 14, 20) == 16'hFFFF, {what, ": IPv4 header checksum"});
  endtask

  task automatic expect_no_reply(input string what);
    bit none;
    u_sink.expect_none(600, none);
    tb_check(none, {what, ": unexpected reply"});
    if (!none) u_sink.frames.delete();
  endtask

  task automatic check_echo_counters(input string what);
    repeat (300) @(posedge proto_clk);
    axi_expect(E_ECHOED,    exp_echoed,    {what, " ECHOED_DATAGRAMS"});
    axi_expect(E_BYTES,     exp_bytes,     {what, " ECHOED_BYTES"});
    axi_expect(E_DISCARDED, exp_discarded, {what, " DISCARDED"});
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin : main
    bytes_t      pl;
    logic [31:0] d;
    logic [1:0]  resp;
    int          lens[$];

    #100;
    arstn = 1'b1;
    repeat (20) @(posedge proto_clk);

    // ---- 1. Echo registers ----------------------------------------------------
    axi_expect(E_ID,        32'h4543_484F, "ID");
    axi_expect(E_VERSION,   32'h1022_2026, "VERSION");
    axi_expect(E_CAPS,      32'd1472, "CAPS");
    axi_expect(E_CTRL,      32'h0, "CTRL reset");
    axi_expect(E_STATUS,    32'h0, "STATUS reset");
    axi_expect(E_ECHOED,    32'h0, "ECHOED reset");
    axi_expect(E_BYTES,     32'h0, "BYTES reset");
    axi_expect(E_DISCARDED, 32'h0, "DISCARDED reset");
    axi_expect(12'h020,     32'h0, "undefined offset");
    u_axi.write32(E_CTRL, 32'h0000_0103, 4'h3, resp);
    tb_check(resp == 2'b00, "partial write answered OKAY");
    axi_expect(E_CTRL, 32'h0, "partial write ignored");
    u_axi.wr(E_CTRL, 32'h0000_AB02);
    axi_expect(E_CTRL, 32'h0000_AB02, "CTRL read-back (socket, any)");
    u_axi.wr(E_CTRL, 32'h0);

    // Socket layer: three sockets.
    reg_wr(12'h104, PORT0); reg_wr(12'h100, 32'h1);
    reg_wr(12'h144, PORT1); reg_wr(12'h140, 32'h1);
    reg_wr(12'h184, PORT2); reg_wr(12'h180, 32'h1);

    // ---- 2. Disabled: consumed and discarded ------------------------------------
    for (int i = 0; i < 3; i++) begin
      wrapper_send(request(LOCAL_IP, 16'd30000, PORT0, payload_bytes(10 * i, i)));
      exp_discarded++;
    end
    expect_no_reply("echo disabled");
    check_echo_counters("disabled");

    // ---- 3/4. Socket 0 selected: every length 0..64 and large ones ----------------
    u_axi.wr(E_CTRL, CTRL_ENABLE | (32'd0 << 8));
    axi_expect(E_STATUS, 32'h1, "STATUS enabled");
    u_sink.ready_pct = 60;
    for (int L = 0; L <= 64; L++) lens.push_back(L);
    lens.push_back(100); lens.push_back(511); lens.push_back(1000); lens.push_back(1471); lens.push_back(MAX_PAY);
    for (int i = 0; i < $size(lens); i++) begin
      pl = payload_bytes(lens[i], 50 + i);
      wrapper_send(request(LOCAL_IP, 16'(31000 + i), PORT0, pl));
      expect_reply(0, 16'(31000 + i), pl, $sformatf("echo len %0d", lens[i]));
      exp_echoed++; exp_bytes += lens[i];
    end
    // Other sockets discarded while socket 0 is selected.
    wrapper_send(request(LOCAL_IP, 16'd32000, PORT1, payload_bytes(20, 1)));
    wrapper_send(request(LOCAL_IP, 16'd32001, PORT2, payload_bytes(0, 1)));
    exp_discarded += 2;
    expect_no_reply("unselected sockets");
    // Broadcast request answered to the sender.
    pl = payload_bytes(12, 2);
    wrapper_send(request(32'hFFFF_FFFF, 16'd32002, PORT0, pl));
    expect_reply(0, 16'd32002, pl, "broadcast request");
    exp_echoed++; exp_bytes += 12;
    check_echo_counters("socket 0 selected");

    // Socket 1 selected.
    u_axi.wr(E_CTRL, CTRL_ENABLE | (32'd1 << 8));
    pl = payload_bytes(33, 3);
    wrapper_send(request(LOCAL_IP, 16'd33000, PORT1, pl));
    expect_reply(1, 16'd33000, pl, "socket 1 selected");
    wrapper_send(request(LOCAL_IP, 16'd33001, PORT0, pl));
    expect_no_reply("socket 0 while socket 1 selected");
    exp_echoed++; exp_bytes += 33; exp_discarded++;

    // SOCKET_ANY.
    u_axi.wr(E_CTRL, CTRL_ENABLE | CTRL_ANY | (32'd3 << 8));
    for (int s = 0; s < 3; s++) begin
      pl = payload_bytes(7 + s * 40, 4 + s);
      wrapper_send(request(LOCAL_IP, 16'(34000 + s), sock_port(s), pl));
      expect_reply(s, 16'(34000 + s), pl, $sformatf("SOCKET_ANY socket %0d", s));
      exp_echoed++; exp_bytes += 7 + s * 40;
    end
    check_echo_counters("socket select");

    // ---- 5. Random stream, up to three in flight -----------------------------------
    begin
      bytes_t req_pl[$];
      int     req_sock[$];
      int     base;
      for (int i = 0; i < 120; i++) begin
        req_pl.push_back(payload_bytes((rnd(4) == 0) ? rnd(MAX_PAY + 1) : rnd(200), 200 + i));
        req_sock.push_back(rnd(3));
      end
      u_sink.ready_pct = 70;
      base = u_sink.frame_count;
      fork
        for (int i = 0; i < 120; i++) begin
          // At most three requests without a reply.
          wait (u_sink.frame_count - base >= i - 2);
          wrapper_send(request(LOCAL_IP, 16'(35000 + i), sock_port(req_sock[i]), req_pl[i]));
          u_src.idle(rnd(30));
        end
        for (int i = 0; i < 120; i++)
          expect_reply(req_sock[i], 16'(35000 + i), req_pl[i], $sformatf("random stream %0d", i));
      join
      for (int i = 0; i < 120; i++) begin
        exp_echoed++; exp_bytes += req_pl[i].size();
      end
    end
    check_echo_counters("random stream");

    // ---- 6. Overload with the reply side stalled ------------------------------------
    begin
      int     base_frames;
      int     drops;
      int     replies;
      int     next_req;
      bytes_t got;
      bit     ok;
      bytes_t req_pl[$];
      for (int i = 0; i < 30; i++) req_pl.push_back(payload_bytes(100 + 10 * i, 400 + i));
      reg_rd(12'h01C, d);
      drops = -int'(d);
      u_sink.ready_pct = 0;
      for (int i = 0; i < 30; i++) wrapper_send(request(LOCAL_IP, 16'(36000 + i), PORT0, req_pl[i]));
      repeat (2000) @(posedge proto_clk);
      u_sink.ready_pct = 100;
      // Collect replies until the stream goes quiet; each matches a later request than the last.
      replies  = 0;
      next_req = 0;
      ok       = 1'b1;
      while (ok) begin
        u_sink.get(got, 5000, ok);
        if (ok) begin
          int     port;
          bytes_t exp;
          string  why;
          port = int'(get16(got, 36)) - 36000;
          tb_check(port >= next_req && port < 30, $sformatf("overload: reply port %0d out of order", port));
          if (port >= next_req && port < 30) begin
            exp = udp_frame(PEER_MAC, LOCAL_MAC, LOCAL_IP, PEER_IP, PORT0, 16'(36000 + port), req_pl[port],
                            16'(exp_ident));
            tb_check(bytes_equal(got, exp, why), {"overload reply ", why});
            next_req = port + 1;
            exp_echoed++; exp_bytes += req_pl[port].size();
          end
          exp_ident++;
          replies++;
        end
      end
      reg_rd(12'h01C, d);
      drops += int'(d);
      tb_check(replies + drops == 30, $sformatf("overload: %0d replies + %0d RX FIFO drops != 30", replies, drops));
      tb_check(drops > 0, "overload: the stall produced RX FIFO drops");
      // Buffering: 8 RX FIFO slots + 4 TX payload slots (the datagram the echo
      // holds still occupies its RX slot).
      tb_check(replies >= 12, $sformatf("overload: only %0d replies buffered", replies));
      // Traffic resumes.
      pl = payload_bytes(64, 9);
      wrapper_send(request(LOCAL_IP, 16'd37000, PORT0, pl));
      expect_reply(0, 16'd37000, pl, "after overload");
      exp_echoed++; exp_bytes += 64;
    end
    check_echo_counters("overload");

    // ---- 7. Disable, counters, clear ------------------------------------------------
    u_axi.wr(E_CTRL, CTRL_ANY);
    wrapper_send(request(LOCAL_IP, 16'd38000, PORT2, payload_bytes(5, 1)));
    exp_discarded++;
    expect_no_reply("disabled again");
    check_echo_counters("disabled again");
    u_axi.wr(E_CTRL, CTRL_CLEAR | CTRL_ANY);
    axi_expect(E_CTRL, 32'h2, "CNT_CLEAR reads 0, SOCKET_ANY kept");
    exp_echoed = 0; exp_bytes = 0; exp_discarded = 0;
    check_echo_counters("after CNT_CLEAR");
    reg_rd(12'h020, d);
    tb_check(d == exp_ident, $sformatf("socket TX_FRAMES %0d equals replies %0d", d, exp_ident));

    tb_verdict(BENCH);
  end

endmodule
