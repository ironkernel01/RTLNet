// -----------------------------------------------------------------------------
// File: tb_rtlnet_nexys_video_net.sv
// Purpose: network board bench of the Nexys Video top: the real board top
//   built with RTLNET_WITH_NETWORK (MAC, MDIO, protocol wrapper with every
//   leaf, UDP echo), the CPU core replaced by rtlnet_microblaze_sim_stub (RTLNET_MICROBLAZE_SIM_STUB),
//   and the RTL8211E model (cores/rtlnet_eth_mac/testbench) on the RGMII and
//   MDIO pins with a pull-up on MDIO, at 100 Mb/s (+SPEED=1000 for gigabit).
// Overview (checks):
//   * Every core's ID through its decoder window.
//   * PHY bring-up the way the firmware does it: MDIO bit-banged through the
//     MDIO core's BITBANG register (Clause 22 frames, the driver's bit
//     sequence), PHYID 0x001C/0xC915, RX delay on (page 0xA4 register 28 bits
//     13 and 11, read back), link up at the partner speed in PHYSR.
//   * MAC: CTRL speed + RX/TX enable + LINK_UP, receive path qualified.
//   * Socket 0 on UDP port 7 with connect-on-receive, UDP echo on socket 0.
//   * ARP request for the static address -> 42-byte reply (RFC 826 swap).
//   * ICMP echo request (56-byte payload) -> echo reply, checksums recomputed.
//   * UDP datagram to port 7 -> echoed to the sender with the same payload.
//   * DHCP: START; the bench is the server: DISCOVER captured (xid, chaddr,
//     options), OFFER injected, REQUEST captured (options 50/54), ACK
//     injected; the leaf is bound and the wrapper's effective address switches
//     to the lease; an ARP request for the leased address is answered.
//   * MAC counters (RX good / TX frames) match the traffic; no RGMII timing
//     violation at the PHY model; no FCS or preamble error on any frame.
// The board top runs with MS_CYCLES = 1000 and POR_RESET_MS = 1 so the PHY
// power-on reset is 1 ms. The AMD pin layer needs RTLNET_SIM_RXC_INSERTION_NS
// (filelist define, MAC documentation section 7).
// Ends with one anchored verdict line from rtlnet_tb_pkg::tb_verdict.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_nexys_video_net;

  import rtlnet_tb_pkg::*;
  import rtlnet_tb_eth_frames_pkg::*;

  localparam logic [31:0] WIN        = 32'h44A0_0000;
  localparam logic [31:0] SYS        = WIN + 32'h0_0000;
  localparam logic [31:0] MAC        = WIN + 32'h0_1000;
  localparam logic [31:0] MDIO       = WIN + 32'h0_2000;
  localparam logic [31:0] ECHO       = WIN + 32'h0_3000;
  localparam logic [31:0] PROT       = WIN + 32'h1_0000;
  localparam logic [31:0] ARP        = WIN + 32'h1_1000;
  localparam logic [31:0] ICMP       = WIN + 32'h1_2000;
  localparam logic [31:0] DHCP       = WIN + 32'h1_3000;
  localparam logic [31:0] IPRF       = WIN + 32'h1_4000;
  localparam logic [31:0] UDPS       = WIN + 32'h1_5000;
  localparam logic [47:0] BOARD_MAC  = 48'h02_49_4B_52_4E_01;   // rtlnet_pkg default
  localparam logic [31:0] BOARD_IP   = 32'hC0A9_01DC;          // 192.169.1.220
  localparam logic [47:0] HOST_MAC   = 48'h02_00_00_00_00_32;
  localparam logic [31:0] HOST_IP    = 32'hC0A9_0132;          // 192.169.1.50
  localparam logic [47:0] SRV_MAC    = 48'h02_00_00_00_00_01;
  localparam logic [31:0] SRV_IP     = 32'hC0A9_0101;          // 192.169.1.1
  localparam logic [31:0] LEASE_IP   = 32'hC0A9_014D;          // 192.169.1.77
  localparam int          PHYAD      = 1;
  localparam int          FRAME_TMO  = 400_000;                 // ns per expected frame at 100/1000 Mb/s (x10 at 10)

  // Board pins.
  logic       sysclk = 1'b0;
  logic       cpu_resetn = 1'b1;
  logic       uart_tx_in = 1'b1;
  wire        uart_rx_out;
  wire  [7:0] led;
  logic [7:0] sw = 8'h00;
  wire        eth_rxck;
  wire        eth_rxctl;
  wire  [3:0] eth_rxd;
  wire        eth_txck;
  wire        eth_txctl;
  wire  [3:0] eth_txd;
  wire        eth_mdc;
  wire        eth_mdio;
  wire        eth_rst_b;
  wire        phy_link_up;
  wire  [1:0] phy_link_speed;
  wire        phy_rxdly_on;
  wire        phy_txdly_on;
  int         phy_viol;
  int         speed_mbps;
  logic [1:0] partner_code;

  pullup (eth_mdio);

  always #5.0 sysclk = ~sysclk;

  // Device under test: board top with the network cores and the MicroBlaze simulation stub.
  rtlnet_nexys_video_top #(
    .BUILD_ID     (32'hBEEF_0001),
    .BUILD_DIRTY  (1'b0),
    .MS_CYCLES    (1000),
    .POR_RESET_MS (1)
  ) dut (
    .sysclk      (sysclk),
    .cpu_resetn  (cpu_resetn),
    .uart_tx_in  (uart_tx_in),
    .uart_rx_out (uart_rx_out),
    .led         (led),
    .sw          (sw),
    .btnc        (1'b0),
    .btnd        (1'b0),
    .btnl        (1'b0),
    .btnr        (1'b0),
    .btnu        (1'b0),
    .eth_rxck    (eth_rxck),
    .eth_rxctl   (eth_rxctl),
    .eth_rxd     (eth_rxd),
    .eth_txck    (eth_txck),
    .eth_txctl   (eth_txctl),
    .eth_txd     (eth_txd),
    .eth_mdc     (eth_mdc),
    .eth_mdio    (eth_mdio),
    .eth_rst_b   (eth_rst_b),
    .eth_int_b   (1'b1),
    .eth_pme_b   (1'b1)
  );

  // RTL8211E model: Nexys Video straps (PHYAD 1, no clock delays), short
  // settle and link-up times for simulation; the link partner speed is set
  // at run time from +SPEED.
  rtlnet_rtl8211e_model #(
    .PHYAD                 (PHYAD),
    .RESET_SETTLE_NS       (5_000),
    .LINK_UP_DELAY_NS      (20_000),
    .SPEED_CHANGE_DELAY_NS (20_000),
    .SOFT_RESET_NS         (60_000)
  ) u_phy (
    .phy_rst_n     (eth_rst_b),
    .mdc           (eth_mdc),
    .mdio          (eth_mdio),
    .rxc           (eth_rxck),
    .rxd           (eth_rxd),
    .rx_ctl        (eth_rxctl),
    .txc           (eth_txck),
    .txd           (eth_txd),
    .tx_ctl        (eth_txctl),
    .link_up       (phy_link_up),
    .link_speed    (phy_link_speed),
    .rxdly_on      (phy_rxdly_on),
    .txdly_on      (phy_txdly_on),
    .tx_viol_count (phy_viol)
  );

  // ---------------------------------------------------------------------------
  // Register access through the sim stub
  // ---------------------------------------------------------------------------
  task automatic rd(input logic [31:0] addr, output logic [31:0] data);
    logic [1:0] r;
    dut.u_cpu.axil_read(addr, data, r);
    if (r != 2'b00) tb_error($sformatf("read 0x%08x resp %b", addr, r));
  endtask

  task automatic wr(input logic [31:0] addr, input logic [31:0] data);
    logic [1:0] r;
    dut.u_cpu.axil_write(addr, data, 4'hF, r);
    if (r != 2'b00) tb_error($sformatf("write 0x%08x resp %b", addr, r));
  endtask

  task automatic check_reg(input logic [31:0] addr, input logic [31:0] want, input string what);
    logic [31:0] d;
    rd(addr, d);
    tb_check(d == want, $sformatf("%s: read 0x%08x, expected 0x%08x", what, d, want));
  endtask

  // ---------------------------------------------------------------------------
  // Clause 22 MDIO through the MDIO core's BITBANG register: the bit sequence
  // of cores/rtlnet_mdio/driver/rtlnet_mdio.c (out_bit, in_bit, idle_slot).
  // BITBANG [0] MDC, [1] drive, [2] data out; read [0] synchronized MDIO.
  // ---------------------------------------------------------------------------
  localparam logic [31:0] BB = MDIO + 32'h014;

  task automatic mdio_out_bit(input bit b);
    wr(BB, {29'd0, b, 1'b1, 1'b0});
    wr(BB, {29'd0, b, 1'b1, 1'b1});
  endtask

  task automatic mdio_in_bit(output bit b);
    logic [31:0] d;
    wr(BB, 32'd0);
    rd(BB, d);
    b = d[0];
    wr(BB, 32'd1);
  endtask

  task automatic mdio_write(input logic [4:0] reg_a, input logic [15:0] v);
    logic [31:0] w;
    for (int i = 0; i < 32; i++) mdio_out_bit(1'b1);
    w = {2'b01, 2'b01, 5'(PHYAD), reg_a, 2'b10, v};
    for (int i = 31; i >= 0; i--) mdio_out_bit(w[i]);
    wr(BB, 32'd0);
  endtask

  task automatic mdio_read(input logic [4:0] reg_a, output logic [15:0] v, output bit ok);
    logic [13:0] h;
    bit ta;
    bit b;
    for (int i = 0; i < 32; i++) mdio_out_bit(1'b1);
    h = {2'b01, 2'b10, 5'(PHYAD), reg_a};
    for (int i = 13; i >= 0; i--) mdio_out_bit(h[i]);
    mdio_in_bit(b);
    mdio_in_bit(ta);
    v = '0;
    for (int i = 15; i >= 0; i--) begin
      mdio_in_bit(b);
      v[i] = b;
    end
    wr(BB, 32'd0);
    ok = (ta == 1'b0);
  endtask

  // ---------------------------------------------------------------------------
  // Frames
  // ---------------------------------------------------------------------------
  task automatic expect_frame(input bytes_t exp, input string what, output bytes_t got);
    bit fcs_ok;
    bit pre_ok;
    bit err;
    bit ok;
    string why;
    bytes_t head;
    u_phy.get_tx_frame(got, fcs_ok, pre_ok, err, (speed_mbps == 10) ? 10 * FRAME_TMO : FRAME_TMO, ok);
    tb_check(ok, $sformatf("%s: no frame from the board", what));
    if (!ok) return;
    tb_check(fcs_ok && pre_ok && !err, $sformatf("%s: fcs_ok %0d pre_ok %0d err %0d", what, fcs_ok, pre_ok, err));
    tb_check(got.size() >= 60, $sformatf("%s: %0d bytes, below the 60-byte minimum", what, got.size()));
    if ($size(exp) > 0) begin
      for (int i = 0; i < $size(exp) && i < $size(got); i++) head.push_back(got[i]);
      tb_check(bytes_equal(head, exp, why), $sformatf("%s: %s", what, why));
      for (int i = $size(exp); i < $size(got); i++) begin
        if (got[i] != 8'h00) begin
          tb_error($sformatf("%s: pad byte %0d is 0x%02x", what, i, got[i]));
          break;
        end
      end
    end
  endtask

  // BOOTP/DHCP server message from the bench (op 2), options given.
  function automatic bytes_t dhcp_server_msg(input bit [31:0] xid, input bit [47:0] chaddr, input bit [7:0] msg_type);
    bytes_t b;
    b.push_back(8'd2); b.push_back(8'd1); b.push_back(8'd6); b.push_back(8'd0);
    push32(b, xid);
    push16(b, 16'd0); push16(b, 16'h8000);
    push32(b, 32'd0); push32(b, LEASE_IP); push32(b, SRV_IP); push32(b, 32'd0);
    push48(b, chaddr);
    for (int i = 0; i < 10 + 64 + 128; i++) b.push_back(8'h00);
    push32(b, 32'h6382_5363);
    b.push_back(8'd53); b.push_back(8'd1); b.push_back(msg_type);
    b.push_back(8'd54); b.push_back(8'd4); push32(b, SRV_IP);
    b.push_back(8'd1);  b.push_back(8'd4); push32(b, 32'hFFFF_FF00);
    b.push_back(8'd3);  b.push_back(8'd4); push32(b, SRV_IP);
    b.push_back(8'd51); b.push_back(8'd4); push32(b, 32'd3600);
    b.push_back(8'd255);
    return b;
  endfunction

  // Value of a DHCP option in a captured client message (from byte 282).
  function automatic int dhcp_option(input bytes_t f, input bit [7:0] code, output bytes_t val);
    int i;
    i = 282;
    while (i < $size(f)) begin
      if (f[i] == 8'd255) return 0;
      if (f[i] == 8'd0) begin
        i++;
        continue;
      end
      if (i + 1 >= $size(f)) return 0;
      if (f[i] == code) begin
        for (int k = 0; k < f[i + 1] && i + 2 + k < $size(f); k++) val.push_back(f[i + 2 + k]);
        return 1;
      end
      i = i + 2 + f[i + 1];
    end
    return 0;
  endfunction

  initial begin : watchdog
    #(40_000_000);
    tb_error("watchdog: bench did not finish in 40 ms");
    tb_verdict("tb_rtlnet_nexys_video_net");
  end

  initial begin : main
    logic [31:0] d;
    logic [15:0] v;
    bit          ok;
    bytes_t      f;
    bytes_t      got;
    bytes_t      req;
    bytes_t      payload;
    bytes_t      opt;
    bytes_t      empty;
    bit [31:0]   xid;
    int          seed;
    int          polls;
    logic [31:0] rx_good0;
    logic [31:0] tx0;

    seed = 7;
    speed_mbps = 100;
    if ($value$plusargs("SPEED=%d", speed_mbps)) $display("bench: link partner at %0d Mb/s", speed_mbps);
    partner_code = (speed_mbps == 1000) ? 2'b10 : (speed_mbps == 10) ? 2'b00 : 2'b01;
    u_phy.set_partner_speed(partner_code);
    wait (dut.mmcm_locked === 1'b1);
    dut.u_cpu.wait_reset_release();

    // Identity of every core.
    check_reg(SYS,  32'h4E58_5644, "SYS ID");
    check_reg(SYS + 32'h008, 32'h0508_0801, "SYS CAPS (network build)");
    check_reg(MAC,  32'h4D41_4331, "MAC ID");
    check_reg(MDIO, 32'h4D44_494F, "MDIO ID");
    check_reg(ECHO, 32'h4543_484F, "ECHO ID");
    check_reg(PROT, 32'h5052_4F54, "PROT ID");
    check_reg(ARP,  32'h4152_5031, "ARP ID");
    check_reg(ICMP, 32'h4943_4D50, "ICMP ID");
    check_reg(DHCP, 32'h4448_4350, "DHCP ID");
    check_reg(IPRF, 32'h4950_5246, "IPRF ID");
    check_reg(UDPS, 32'h5544_5053, "UDPS ID");
    check_reg(WIN + 32'h2_0000, 32'h0, "classifier window stub");

    // PHY power-on reset done (MDIO STATUS.POR_DONE), then the settle time.
    polls = 0;
    do begin
      #(10_000);
      rd(MDIO + 32'h010, d);
      polls++;
    end while (d[2] == 1'b0 && polls < 500);
    tb_check(d[2] == 1'b1, "MDIO POR_DONE");
    tb_check(eth_rst_b === 1'b1, "PHY reset released by the MDIO core");
    #(10_000);

    // PHY identity and RX delay, as rtlnet_phy_rtl8211e_init does.
    mdio_read(5'd2, v, ok);
    tb_check(ok && v == 16'h001C, $sformatf("PHYID1 0x%04x ok %0d", v, ok));
    mdio_read(5'd3, v, ok);
    tb_check(ok && v == 16'hC915, $sformatf("PHYID2 0x%04x ok %0d", v, ok));
    mdio_write(5'd31, 16'h0007);
    mdio_write(5'd30, 16'h00A4);
    mdio_read(5'd28, v, ok);
    mdio_write(5'd28, v | 16'h2800);
    mdio_read(5'd28, v, ok);
    tb_check(ok && (v & 16'h2800) == 16'h2800, $sformatf("page 0xA4 reg 28 read back 0x%04x", v));
    mdio_write(5'd31, 16'h0000);
    tb_check(phy_rxdly_on === 1'b1, "PHY RX clock delay on");

    // Link up at the partner speed (PHYSR 17: link 10, resolved 11, speed 15:14).
    polls = 0;
    do begin
      mdio_read(5'd17, v, ok);
      polls++;
    end while (!(v[10] && v[11]) && polls < 40);
    tb_check(v[10] && v[11], $sformatf("PHYSR link/resolved 0x%04x", v));
    tb_check(v[15:14] == partner_code, $sformatf("PHYSR speed %b, expected %b", v[15:14], partner_code));

    // MAC: speed from PHYSR, RX/TX enable, LINK_UP; receive path qualified.
    wr(MAC + 32'h00C, {23'd0, 1'b1, 2'b00, v[15:14], 2'b00, 2'b11});
    polls = 0;
    do begin
      rd(MAC + 32'h010, d);
      polls++;
    end while (!(d[0] && !d[2]) && polls < 5000);
    tb_check(d[0] && !d[2], $sformatf("MAC STATUS 0x%08x: RX_CLK_OK and receive path running", d));
    rd(MAC + 32'h020, rx_good0);
    rd(MAC + 32'h02C, tx0);

    // Socket 0 on port 7 with connect-on-receive; UDP echo on socket 0.
    wr(UDPS + 32'h104, 32'd7);
    wr(UDPS + 32'h100, 32'h3);
    wr(ECHO + 32'h00C, 32'h1);
    check_reg(UDPS + 32'h100, 32'h3, "socket 0 CTRL");
    check_reg(ECHO + 32'h00C, 32'h1, "echo CTRL");

    // ARP request for the static address.
    req = arp_request(HOST_MAC, HOST_IP, BOARD_IP);
    u_phy.inject(pad60(req));
    expect_frame(arp_reply(req, BOARD_MAC, BOARD_IP), "ARP reply", got);

    // ICMP echo request, 56-byte payload.
    payload = rand_bytes(seed, 56);
    req = echo_request(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'h1234, 16'd1, payload);
    u_phy.inject(req);
    expect_frame(echo_reply(req, BOARD_MAC, BOARD_IP), "ICMP echo reply", got);

    // UDP datagram to port 7: echoed to the sender.
    payload = rand_bytes(seed, 100);
    req = udp_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'd40000, 16'd7, payload);
    u_phy.inject(req);
    expect_frame(empty, "UDP echo", got);
    if (got.size() >= 42 + 100) begin
      tb_check(get48(got, 0) == HOST_MAC && get48(got, 6) == BOARD_MAC, "UDP echo: MAC addresses");
      tb_check(get16(got, 12) == 16'h0800 && got[23] == 8'd17, "UDP echo: IPv4/UDP");
      tb_check(get32(got, 26) == BOARD_IP && get32(got, 30) == HOST_IP, "UDP echo: IP addresses");
      tb_check(inet_sum(got, 14, 20) == 16'hFFFF, "UDP echo: IP header checksum");
      tb_check(get16(got, 34) == 16'd7 && get16(got, 36) == 16'd40000, "UDP echo: ports swapped");
      tb_check(get16(got, 38) == 16'd108, $sformatf("UDP echo: UDP length %0d", get16(got, 38)));
      ok = 1;
      for (int i = 0; i < 100; i++) if (got[42 + i] != payload[i]) ok = 0;
      tb_check(ok, "UDP echo: payload returned unchanged");
    end else begin
      tb_error($sformatf("UDP echo: frame of %0d bytes", got.size()));
    end
    check_reg(ECHO + 32'h014, 32'd1, "echo ECHOED_DATAGRAMS");

    // DHCP with the bench as server.
    wr(DHCP + 32'h00C, 32'h1);
    expect_frame(empty, "DHCP DISCOVER", got);
    tb_check(got.size() >= 300 && get48(got, 0) == 48'hFFFF_FFFF_FFFF && get16(got, 34) == 16'd68 &&
             get16(got, 36) == 16'd67 && got[42] == 8'd1, "DISCOVER: broadcast, UDP 68 -> 67, op 1");
    xid = get32(got, 46);
    tb_check(get48(got, 70) == BOARD_MAC, "DISCOVER: chaddr = board MAC");
    opt.delete();
    tb_check(dhcp_option(got, 8'd53, opt) && opt.size() == 1 && opt[0] == 8'd1, "DISCOVER: option 53 = 1");
    rd(DHCP + 32'h02C, d);
    tb_check(d == xid, $sformatf("XID register 0x%08x = DISCOVER xid 0x%08x", d, xid));

    f = udp_frame(48'hFFFF_FFFF_FFFF, SRV_MAC, SRV_IP, 32'hFFFF_FFFF, 16'd67, 16'd68,
                  dhcp_server_msg(xid, BOARD_MAC, 8'd2));
    u_phy.inject(f);
    expect_frame(empty, "DHCP REQUEST", got);
    opt.delete();
    tb_check(got.size() >= 300 && dhcp_option(got, 8'd53, opt) && opt.size() == 1 && opt[0] == 8'd3,
             "REQUEST: option 53 = 3");
    opt.delete();
    tb_check(dhcp_option(got, 8'd50, opt) && opt.size() == 4 && {opt[0], opt[1], opt[2], opt[3]} == LEASE_IP,
             "REQUEST: option 50 = offered address");
    opt.delete();
    tb_check(dhcp_option(got, 8'd54, opt) && opt.size() == 4 && {opt[0], opt[1], opt[2], opt[3]} == SRV_IP,
             "REQUEST: option 54 = server");
    tb_check(get32(got, 46) == xid, "REQUEST: same xid");

    f = udp_frame(48'hFFFF_FFFF_FFFF, SRV_MAC, SRV_IP, 32'hFFFF_FFFF, 16'd67, 16'd68,
                  dhcp_server_msg(xid, BOARD_MAC, 8'd5));
    u_phy.inject(f);
    polls = 0;
    do begin
      rd(DHCP + 32'h010, d);
      polls++;
    end while (d[8] == 1'b0 && polls < 2000);
    tb_check(d[8] == 1'b1 && d[2:0] == 3'd3, $sformatf("DHCP STATUS 0x%08x: bound", d));
    check_reg(DHCP + 32'h014, LEASE_IP, "LEASE_IP");
    check_reg(DHCP + 32'h018, 32'hFFFF_FF00, "LEASE_MASK");
    check_reg(DHCP + 32'h01C, SRV_IP, "LEASE_ROUTER");
    check_reg(DHCP + 32'h024, 32'd3600, "LEASE_TIME_S");
    check_reg(PROT + 32'h028, LEASE_IP, "effective IP = lease");
    rd(PROT + 32'h010, d);
    tb_check(d[0] && d[1] && d[2], $sformatf("protocol STATUS 0x%08x: IP from DHCP, valid, lease", d));

    // The leased address now answers ARP.
    req = arp_request(HOST_MAC, HOST_IP, LEASE_IP);
    u_phy.inject(pad60(req));
    expect_frame(arp_reply(req, BOARD_MAC, LEASE_IP), "ARP reply for the leased address", got);

    // Counters and PHY-side timing.
    rd(MAC + 32'h020, d);
    tb_check(d - rx_good0 == 6, $sformatf("MAC RX_GOOD advanced %0d, expected 6", d - rx_good0));
    rd(MAC + 32'h024, d);
    tb_check(d == 0, $sformatf("MAC RX_BAD %0d", d));
    rd(MAC + 32'h02C, d);
    tb_check(d - tx0 == 6, $sformatf("MAC TX_FRAMES advanced %0d, expected 6", d - tx0));
    check_reg(ARP + 32'h024, 32'd2, "ARP REPLIES_SENT");
    check_reg(ICMP + 32'h024, 32'd1, "ICMP ECHO_REPLIES");
    tb_check(phy_viol == 0, $sformatf("PHY model RGMII TX timing violations: %0d", phy_viol));
    tb_check(dut.u_cpu.axil_timeouts == 0, "no AXI4-Lite timeouts");

    tb_verdict("tb_rtlnet_nexys_video_net");
  end

endmodule
