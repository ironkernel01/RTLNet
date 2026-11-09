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
//   * CPU-path classifier (protocol sub-map 0x8000): drop-all after reset (an
//     unclaimed datagram never reaches the CPU, counted as MODE_DROPPED); the
//     stand-in's cls_config_bcast_storm (the driver's register sequence)
//     configures a limit of 3 broadcasts per 2 ms; a unicast datagram still
//     reaches the CPU; a burst of 8 broadcasts passes exactly 3 byte-exact and
//     drops 5 (policer 0 SEEN/PASSED/DROPPED, classifier counters).
//   * CPU network path (cpu_axis_ethernet_stream) through the simulation
//     stand-in's DMA tasks: the frames the leaves claimed (ARP, ICMP, UDP
//     echo) never reach the CPU; a UDP datagram to a port no socket owns is
//     unclaimed and arrives at the CPU byte-exact; a frame the CPU sends
//     leaves on the PHY unchanged (padded to 60); the wrapper's CPU counters
//     (CPU_RX_FRAMES, CPU_RX_CLAIMED, CPU_TX_FRAMES) agree.
//   * CPU-path checksum offload (protocol sub-map 0x9000, discovery through CPU_CAPS bits 16..18): the
//     stand-in's txo_config (the driver's register sequence) enables TX insert and RX trailer; a frame the
//     CPU sends with garbage IPv4/TCP/UDP checksums leaves the PHY with correct ones; a TCP segment for an
//     unclaimed port reaches the CPU padded to 8 bytes plus a trailer (length, sum 0xFFFF, flags verified,
//     L4 offset 34, marker 0xA5), a corrupted one with the L4-bad flags; counters agree; with CTRL 0 both
//     directions pass frames unchanged.
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
// Revision: 11-09-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: CPU network path checks.
//   * 10-22-2026: CPU-path classifier enabled: drop-all, configuration, broadcast limiting, unicast unaffected.
//   * 11-09-2026: DDR3 pins of the board top connected (rtlnet_ddr_sim behind them).
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
  localparam logic [31:0] CLS        = WIN + 32'h1_8000;               // CPU-path classifier (protocol sub-map 0x8000)
  localparam logic [31:0] OFL        = WIN + 32'h1_9000;               // CPU-path checksum offload (protocol sub-map 0x9000)
  localparam int          STORM_LIMIT  = 3;                            // broadcasts passed per window
  localparam int          STORM_WINDOW = 2;                            // window in ms (policer tick from 100 MHz)
  localparam int          STORM_BURST  = 8;                            // broadcasts sent in one burst
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
  wire  [15:0] ddr3_dq;
  wire  [1:0]  ddr3_dqs_n;
  wire  [1:0]  ddr3_dqs_p;
  wire  [14:0] ddr3_addr;
  wire  [2:0]  ddr3_ba;
  wire         ddr3_ras_n;
  wire         ddr3_cas_n;
  wire         ddr3_we_n;
  wire         ddr3_reset_n;
  wire  [0:0]  ddr3_ck_p;
  wire  [0:0]  ddr3_ck_n;
  wire  [0:0]  ddr3_cke;
  wire  [1:0]  ddr3_dm;
  wire  [0:0]  ddr3_odt;
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
    .eth_pme_b   (1'b1),
    .ddr3_dq     (ddr3_dq),
    .ddr3_dqs_n  (ddr3_dqs_n),
    .ddr3_dqs_p  (ddr3_dqs_p),
    .ddr3_addr   (ddr3_addr),
    .ddr3_ba     (ddr3_ba),
    .ddr3_ras_n  (ddr3_ras_n),
    .ddr3_cas_n  (ddr3_cas_n),
    .ddr3_we_n   (ddr3_we_n),
    .ddr3_reset_n(ddr3_reset_n),
    .ddr3_ck_p   (ddr3_ck_p),
    .ddr3_ck_n   (ddr3_ck_n),
    .ddr3_cke    (ddr3_cke),
    .ddr3_dm     (ddr3_dm),
    .ddr3_odt    (ddr3_odt)
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

  // Ethernet / IPv4 / TCP frame (20-byte TCP header, no options). good = correct IPv4 and TCP checksums,
  // else both fields hold garbage (what the firmware sends when the offload inserts them).
  function automatic bytes_t tcp_frame(input bit [47:0] dst_mac, input bit [47:0] src_mac, input bit [31:0] src_ip,
                                       input bit [31:0] dst_ip, input bit [15:0] sport, input bit [15:0] dport,
                                       input bytes_t payload, input bit good);
    bytes_t q;
    bytes_t ip;
    bytes_t seg;
    bytes_t ps;
    bit [15:0] c;
    push16(seg, sport); push16(seg, dport); push32(seg, 32'h1000_0001); push32(seg, 32'h2000_0002);
    push16(seg, 16'h5018); push16(seg, 16'h1000); push16(seg, 16'h0000); push16(seg, 16'h0000);
    for (int i = 0; i < $size(payload); i++) seg.push_back(payload[i]);
    ip = ipv4_header(16'(20 + seg.size()), 16'h4321, 8'd6, src_ip, dst_ip);
    if (good) begin
      push32(ps, src_ip); push32(ps, dst_ip); ps.push_back(8'h00); ps.push_back(8'd6); push16(ps, 16'(seg.size()));
      for (int i = 0; i < $size(seg); i++) ps.push_back(seg[i]);
      c = inet_checksum(ps, 0, ps.size());
      seg[16] = c[15:8]; seg[17] = c[7:0];
    end else begin
      ip[10] = 8'hDE; ip[11] = 8'hAD;
      seg[16] = 8'hBE; seg[17] = 8'hEF;
    end
    q = eth_header(dst_mac, src_mac, 16'h0800);
    for (int i = 0; i < $size(ip); i++) q.push_back(ip[i]);
    for (int i = 0; i < $size(seg); i++) q.push_back(seg[i]);
    return q;
  endfunction

  // Frame as the receive offload delivers it: padded to a multiple of 8 with zeros plus the 8-byte trailer.
  function automatic bytes_t with_trailer(input bytes_t f, input bit [15:0] sum, input bit [15:0] flags, input bit [7:0] l4off);
    bytes_t q;
    q = f;
    while ((q.size() % 8) != 0) q.push_back(8'h00);
    q.push_back(f.size() & 8'hFF); q.push_back((f.size() >> 8) & 8'hFF);
    q.push_back(sum[7:0]); q.push_back(sum[15:8]);
    q.push_back(flags[7:0]); q.push_back(flags[15:8]);
    q.push_back(l4off); q.push_back(8'hA5);
    return q;
  endfunction

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
    bytes_t      bcast;
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
    check_reg(CLS, 32'h434C_5346, "CPU-path classifier ID");
    check_reg(CLS + 32'h00C, 32'h0, "classifier CTRL: MODE drop-all after reset");

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

    // CPU network path: claimed frames stay out of the CPU queue. The CPU-path
    // classifier powers up drop-all: an unclaimed datagram (no socket on port
    // 9999) is judged and dropped before the firmware configures it.
    tb_check(dut.u_cpu.eth_rx_frames == 0, $sformatf("claimed frames reached the CPU: %0d", dut.u_cpu.eth_rx_frames));
    payload = rand_bytes(seed, 77);
    req = udp_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'd40001, 16'd9999, payload);
    u_phy.inject(req);
    begin
      bytes_t cpu_f;
      bit     cpu_ok;
      string  why;
      dut.u_cpu.eth_get(cpu_f, 40_000, cpu_ok);
      tb_check(!cpu_ok, "classifier drop-all: unclaimed datagram dropped before configuration");
      rd(PROT + 32'h054, d);
      tb_check(d == 1, $sformatf("CPU_RX_FRAMES %0d, expected 1 (committed, then dropped by the classifier)", d));
      check_reg(CLS + 32'h080, 32'd1, "classifier FRAMES before configuration");
      check_reg(CLS + 32'h084, 32'd0, "classifier PASSED before configuration");
      check_reg(CLS + 32'h088, 32'd1, "classifier DROPPED before configuration");
      check_reg(CLS + 32'h08C, 32'd1, "classifier MODE_DROPPED before configuration");

      // The firmware's configuration (rtlnet_classifier_config_bcast_storm register sequence).
      begin
        logic [1:0] r;
        dut.u_cpu.cls_config_bcast_storm(CLS, STORM_LIMIT, STORM_WINDOW, r);
        tb_check(r == 2'b00, $sformatf("classifier configuration resp %b", r));
      end
      rd(CLS + 32'h010, d);
      tb_check((d & 32'h0000_0301) == 32'h0000_0100, $sformatf("classifier STATUS 0x%08x: MODE pass-all, not clearing", d));

      // Unicast to the CPU is unaffected by the limiter.
      u_phy.inject(req);
      dut.u_cpu.eth_get(cpu_f, 200_000, cpu_ok);
      tb_check(cpu_ok, "CPU path: unclaimed UDP datagram reached the CPU after configuration");
      if (cpu_ok) begin
        tb_check(bytes_equal(cpu_f, req, why), $sformatf("CPU path receive: %s", why));
      end
      tb_check(dut.u_cpu.eth_rx_keep_errors == 0, "CPU path receive: tkeep legal on every beat");

      // Broadcast burst: STORM_LIMIT pass, the rest are dropped (one policer window).
      for (int i = 0; i < STORM_BURST; i++) begin
        payload = rand_bytes(seed, 60);
        bcast = udp_frame(48'hFFFF_FFFF_FFFF, HOST_MAC, HOST_IP, 32'hFFFF_FFFF, 16'd40002, 16'd9999, payload);
        u_phy.inject(bcast);
        if (i < STORM_LIMIT) begin
          dut.u_cpu.eth_get(cpu_f, 200_000, cpu_ok);
          tb_check(cpu_ok && bytes_equal(cpu_f, bcast, why), $sformatf("broadcast %0d passed to the CPU byte-exact", i));
        end
      end
      // Wait until the wrapper has committed every frame of the burst (the line is slow at 10 Mb/s).
      polls = 0;
      do begin
        #(20_000);
        rd(PROT + 32'h054, d);
        polls++;
      end while (d < 2 + STORM_BURST && polls < 200);
      dut.u_cpu.eth_get(cpu_f, 40_000, cpu_ok);
      tb_check(!cpu_ok, "broadcast beyond the limit never reaches the CPU");
      check_reg(CLS + 32'h100 + 32'h0C, STORM_BURST, "policer 0 SEEN (broadcasts only)");
      check_reg(CLS + 32'h100 + 32'h10, STORM_LIMIT, "policer 0 PASSED");
      check_reg(CLS + 32'h100 + 32'h14, STORM_BURST - STORM_LIMIT, "policer 0 DROPPED");
      check_reg(CLS + 32'h080, 32'd2 + STORM_BURST, "classifier FRAMES after the burst");
      check_reg(CLS + 32'h084, 32'd1 + STORM_LIMIT, "classifier PASSED after the burst");
      check_reg(CLS + 32'h088, 32'd1 + STORM_BURST - STORM_LIMIT, "classifier DROPPED after the burst");
      check_reg(CLS + 32'h090, STORM_BURST - STORM_LIMIT, "classifier POLICE_DROPPED");
      check_reg(CLS + 32'h094, STORM_BURST, "classifier MAC table hits: the broadcasts only");
    end
    rd(PROT + 32'h054, d);
    tb_check(d == 2 + STORM_BURST, $sformatf("CPU_RX_FRAMES %0d, expected %0d", d, 2 + STORM_BURST));
    rd(PROT + 32'h058, d);
    tb_check(d >= 3, $sformatf("CPU_RX_CLAIMED %0d, expected at least 3 (ARP, ICMP, UDP echo)", d));
    // CPU transmit: a 50-byte frame leaves on the wire, padded to 60.
    payload = rand_bytes(seed, 8);
    req = udp_frame(HOST_MAC, BOARD_MAC, BOARD_IP, HOST_IP, 16'd9999, 16'd40001, payload);
    dut.u_cpu.eth_send(req);
    expect_frame(req, "CPU path transmit", got);
    rd(PROT + 32'h060, d);
    tb_check(d == 1, $sformatf("CPU_TX_FRAMES %0d, expected 1", d));

    // CPU-path checksum offload (protocol sub-map 0x9000): discovery, then transmit insert and receive trailer.
    begin
      bytes_t good_tcp;
      bytes_t bad_tcp;
      bytes_t pay;
      bytes_t cpu_f;
      bit     cpu_ok;
      string  why;
      logic [1:0] r;
      rd(PROT + 32'h034, d);
      tb_check(d[18:16] == 3'b111, $sformatf("CPU_CAPS 0x%08x: classifier, offload TX and RX present", d));
      check_reg(OFL, 32'h5443_504F, "CPU-path offload ID");
      check_reg(OFL + 32'h004, 32'h1022_2026, "CPU-path offload VERSION");
      rd(OFL + 32'h008, d);
      tb_check(d[5:0] == 6'h3F, $sformatf("offload CAPS 0x%08x", d));
      check_reg(OFL + 32'h00C, 32'h0, "offload CTRL powers up 0");
      rd(OFL + 32'h010, d);
      tb_check(d[1:0] == 2'b11, $sformatf("offload STATUS 0x%08x: both paths idle", d));

      // Enabled the way the firmware does it (driver register sequence).
      dut.u_cpu.txo_config(OFL, 32'h7, r);
      tb_check(r == 2'b00, $sformatf("offload configuration resp %b", r));

      // Transmit: garbage checksums leave the board correct.
      pay = rand_bytes(seed, 33);
      f = tcp_frame(HOST_MAC, BOARD_MAC, BOARD_IP, HOST_IP, 16'd9999, 16'd40001, pay, 1'b0);
      dut.u_cpu.eth_send(f);
      expect_frame(tcp_frame(HOST_MAC, BOARD_MAC, BOARD_IP, HOST_IP, 16'd9999, 16'd40001, pay, 1'b1), "TX offload: TCP", got);
      pay = rand_bytes(seed, 21);
      req = udp_frame(HOST_MAC, BOARD_MAC, BOARD_IP, HOST_IP, 16'd9999, 16'd40001, pay, 16'h0001, 1'b0);
      f = req;
      f[24] = 8'h12; f[25] = 8'h34; f[40] = 8'h56; f[41] = 8'h78;
      dut.u_cpu.eth_send(f);
      expect_frame(udp_frame(HOST_MAC, BOARD_MAC, BOARD_IP, HOST_IP, 16'd9999, 16'd40001, pay, 16'h0001, 1'b1),
                   "TX offload: UDP", got);
      check_reg(OFL + 32'h040, 32'd3, "offload TX_FRAMES (the earlier CPU frame passed through unpatched)");
      check_reg(OFL + 32'h044, 32'd2, "offload TX_IP_PATCHED");
      check_reg(OFL + 32'h048, 32'd2, "offload TX_L4_PATCHED");

      // Receive: a TCP segment for a port no hardware leaf owns reaches the CPU with the trailer.
      pay = rand_bytes(seed, 61);
      good_tcp = tcp_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'd40005, 16'd5001, pay, 1'b1);
      u_phy.inject(good_tcp);
      dut.u_cpu.eth_get(cpu_f, 200_000, cpu_ok);
      tb_check(cpu_ok, "RX offload: good TCP segment reached the CPU");
      if (cpu_ok) begin
        tb_check(bytes_equal(cpu_f, with_trailer(good_tcp, 16'hFFFF, 16'h00E3, 8'd34), why),
                 $sformatf("RX offload: good TCP segment with verified trailer: %s", why));
      end
      bad_tcp = good_tcp;
      bad_tcp[60] = bad_tcp[60] ^ 8'h10;
      u_phy.inject(bad_tcp);
      dut.u_cpu.eth_get(cpu_f, 200_000, cpu_ok);
      tb_check(cpu_ok, "RX offload: corrupted TCP segment reached the CPU");
      if (cpu_ok) begin
        tb_check(cpu_f.size() == good_tcp.size() + 8 + (8 - good_tcp.size() % 8) % 8, "RX offload: corrupted segment length");
        tb_check(cpu_f[cpu_f.size() - 8 + 4] == 8'hA3 && cpu_f[cpu_f.size() - 8 + 5] == 8'h00,
                 $sformatf("RX offload: corrupted segment flags 0x%02x%02x (verified, L4 bad)",
                           cpu_f[cpu_f.size() - 8 + 5], cpu_f[cpu_f.size() - 8 + 4]));
      end
      check_reg(OFL + 32'h060, 32'd2, "offload RX_FRAMES");
      check_reg(OFL + 32'h064, 32'd1, "offload RX_VERIFIED");
      check_reg(OFL + 32'h06C, 32'd1, "offload RX_L4_BAD");
      check_reg(OFL + 32'h068, 32'd0, "offload RX_IP_BAD");

      // Disabled again: both paths pass frames unchanged.
      dut.u_cpu.txo_config(OFL, 32'h0, r);
      tb_check(r == 2'b00, $sformatf("offload disable resp %b", r));
      rd(OFL + 32'h010, d);
      tb_check(d[1:0] == 2'b11, $sformatf("offload STATUS 0x%08x after traffic", d));
      u_phy.inject(good_tcp);
      dut.u_cpu.eth_get(cpu_f, 200_000, cpu_ok);
      tb_check(cpu_ok && bytes_equal(cpu_f, good_tcp, why), $sformatf("RX offload off: frame unchanged: %s", why));
      f = tcp_frame(HOST_MAC, BOARD_MAC, BOARD_IP, HOST_IP, 16'd9999, 16'd40001, pay, 1'b0);
      dut.u_cpu.eth_send(f);
      expect_frame(f, "TX offload off: garbage checksums left as sent", got);
    end

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
    tb_check(d - rx_good0 == 7 + 1 + STORM_BURST + 3, $sformatf("MAC RX_GOOD advanced %0d, expected %0d", d - rx_good0, 7 + 1 + STORM_BURST + 3));
    rd(MAC + 32'h024, d);
    tb_check(d == 0, $sformatf("MAC RX_BAD %0d", d));
    rd(MAC + 32'h02C, d);
    tb_check(d - tx0 == 7 + 3, $sformatf("MAC TX_FRAMES advanced %0d, expected 10", d - tx0));
    check_reg(ARP + 32'h024, 32'd2, "ARP REPLIES_SENT");
    check_reg(ICMP + 32'h024, 32'd1, "ICMP ECHO_REPLIES");
    tb_check(phy_viol == 0, $sformatf("PHY model RGMII TX timing violations: %0d", phy_viol));
    tb_check(dut.u_cpu.axil_timeouts == 0, "no AXI4-Lite timeouts");

    tb_verdict("tb_rtlnet_nexys_video_net");
  end

endmodule
