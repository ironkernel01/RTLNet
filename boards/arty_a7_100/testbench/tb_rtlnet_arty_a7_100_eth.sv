// -----------------------------------------------------------------------------
// File: tb_rtlnet_arty_a7_100_eth.sv
// Purpose: board bench of the Arty A7-100T Ethernet demo top: the real board top rtlnet_arty_a7_100_eth_top (MII MAC, MDIO,
//   protocol wrapper with every leaf, UDP echo, CPU network path), the CPU core replaced by rtlnet_cpu_eth_sim_stub
//   (RTLNET_CPU_ETH_SIM_STUB), the DP83848 MII data model (rtlnet_dp83848_model, cores/rtlnet_eth_mac/testbench) on the MII
//   pins and a Clause 22 MDIO slave (rtlnet_tb_mdio_slave, cores/rtlnet_mdio/testbench) with DP83848 register values on
//   the MDIO pin (pull-up on MDIO). +SPEED=10|100 sets the link partner speed (default 100).
// Overview (checks):
//   * The board-independent system registers (cpu/microblaze_v_ethernet): ID "ETHS", CAPS (4 LEDs, 4 switches,
//     4 buttons), BOARD_ID "ARTY", CPU_CLK_HZ 100 MHz, LINK_CAPS 10/100 full duplex, BUILD_ID, LEDS and SCRATCH
//     write and read back, the switch and button levels; an address outside the five windows gives DECERR.
//   * Every core's ID through its decoder window.
//   * The 25 MHz PHY reference clock on eth_ref_clk (period measured) is running when the PHY reset (eth_rstn) is released:
//     the number of reference clock edges before the release is counted and compared with the reset hold of the MDIO core.
//   * PHY bring-up the way the firmware does it: the MDIO bus is scanned for the PHY ID (the slave answers at address 5, not
//     at 1: nothing is hard-coded), PHYID 0x2000/0x5C9x, ANAR write and read back (MDIO bit-banged through the MDIO core's
//     BITBANG register, Clause 22 frames, the driver's bit sequence), link up at the partner speed in PHYSTS (register 0x10).
//   * MAC: CTRL speed + RX/TX enable + LINK_UP, receive path qualified; NET_STATUS reports the link and the speed.
//   * Socket 0 on UDP port 7 with connect-on-receive, UDP echo on socket 0.
//   * ARP request for the static address -> 42-byte reply (RFC 826 swap).
//   * ICMP echo request (56-byte payload) -> echo reply, checksums recomputed.
//   * UDP datagram to port 7 -> echoed to the sender with the same payload.
//   * CPU-path classifier (protocol sub-map 0x8000): drop-all after reset; the stand-in's cls_config_bcast_storm
//     configures a limit of 3 broadcasts per 2 ms; a unicast datagram still reaches the CPU; a burst of 8 broadcasts
//     passes exactly 3 byte-exact and drops 5.
//   * CPU-path protection profile (the firmware's rtlnet_classifier_config_protect, stand-in cls_config_protect): broadcast, UDP,
//     ARP and ICMP classes each sent above their limit while unicast TCP segments to the board keep passing; exactly the
//     limit of each class and every TCP segment reach the CPU, byte-exact and in order; counters per policer and per table.
//   * CPU network path (cpu_axis_ethernet_stream) through the simulation stand-in's DMA tasks: claimed frames never
//     reach the CPU; an unclaimed UDP datagram arrives byte-exact; a frame the CPU sends leaves on the PHY unchanged
//     (padded to 60); the wrapper's CPU counters agree.
//   * CPU-path checksum offload (protocol sub-map 0x9000): TX insert and RX trailer, counters, pass-through with CTRL 0.
//   * DHCP: START; the bench is the server (DISCOVER, OFFER, REQUEST, ACK); the leaf is bound and the effective address
//     switches to the lease; an ARP request for the leased address is answered.
//   * MAC counters match the traffic; the PHY model's own wire checks (preamble, SFD, nibble order, FCS, 24-nibble gap)
//     report no failure; no AXI4-Lite timeout.
// The board top runs with MS_CYCLES = 1000 and POR_RESET_MS = 1 so the PHY power-on reset is 1 ms.
// Ends with one anchored verdict line from rtlnet_tb_pkg::tb_verdict; +INJECT_FAILURE is the negative control.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-14-2026
//   * 11-14-2026: initial version (from tb_rtlnet_nexys_video_eth for the Arty A7-100T Ethernet demo top).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_arty_a7_100_eth;

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
  localparam int          PROT_WINDOW    = 50;                         // protection profile window in ms
  localparam int          PROT_LIM_BCAST = 3;                          // profile limits per window (frames passed)
  localparam int          PROT_LIM_UDP   = 2;
  localparam int          PROT_LIM_ARP   = 2;
  localparam int          PROT_LIM_ICMP  = 2;
  localparam int          PROT_N_BCAST   = 6;                          // frames sent per class in the profile phase
  localparam int          PROT_N_UDP     = 5;
  localparam int          PROT_N_ARP     = 5;
  localparam int          PROT_N_ICMP    = 5;
  localparam int          PROT_N_TCP     = 8;                          // unicast TCP segments, never policed
  localparam int          PROT_N_TOTAL   = PROT_N_BCAST + PROT_N_UDP + PROT_N_ARP + PROT_N_ICMP + PROT_N_TCP;
  localparam logic [47:0] BOARD_MAC  = 48'h02_49_4B_52_4E_01;   // rtlnet_pkg default
  localparam logic [31:0] BOARD_IP   = 32'hC0A9_01DC;          // the protocol core's default static address (rtlnet_pkg)
  localparam logic [47:0] HOST_MAC   = 48'h02_00_00_00_00_32;
  localparam logic [31:0] HOST_IP    = 32'hC000_0232;          // 192.0.2.50 (documentation range)
  localparam logic [47:0] SRV_MAC    = 48'h02_00_00_00_00_01;
  localparam logic [31:0] SRV_IP     = 32'hC000_0201;          // 192.0.2.1
  localparam logic [31:0] LEASE_IP   = 32'hC000_024D;          // 192.0.2.77
  localparam int          PHYAD      = 5;                      // where the MDIO slave answers; the bench scans for it
  localparam int          SYS_CLK_HZ   = 100_000_000;
  localparam int          FRAME_TMO  = 400_000;                 // ns per expected frame at 100 Mb/s (x10 at 10)

  // Board pins.
  logic       sysclk = 1'b0;
  logic       cpu_resetn = 1'b1;
  logic       uart_tx_in = 1'b1;
  wire        uart_rx_out;
  wire  [3:0] led;
  logic [3:0] sw = 4'h5;
  wire        eth_rx_clk;
  wire        eth_rx_dv;
  wire        eth_rxerr;
  wire  [3:0] eth_rxd;
  wire        eth_tx_clk;
  wire        eth_tx_en;
  wire  [3:0] eth_txd;
  wire        eth_mdc;
  wire        eth_mdio;
  wire        eth_rstn;
  wire        eth_ref_clk;
  int         speed_mbps;
  logic [1:0] partner_code;

  pullup (eth_mdio);

  always #5.0 sysclk = ~sysclk;

  // Device under test: the Ethernet demo board top with the CPU simulation stub.
  rtlnet_arty_a7_100_eth_top #(
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
    .btn         (4'b1000),
    .eth_rx_clk  (eth_rx_clk),
    .eth_rx_dv   (eth_rx_dv),
    .eth_rxerr   (eth_rxerr),
    .eth_rxd     (eth_rxd),
    .eth_tx_clk  (eth_tx_clk),
    .eth_tx_en   (eth_tx_en),
    .eth_txd     (eth_txd),
    .eth_mdc     (eth_mdc),
    .eth_mdio    (eth_mdio),
    .eth_rstn    (eth_rstn),
    .eth_ref_clk (eth_ref_clk)
  );

  // DP83848 MII data model: both PHY clocks (25 / 2.5 MHz), nibble injection, wire capture and wire checks. The link partner
  // speed comes from +SPEED (the model reads the same plusarg for its clock rate).
  rtlnet_dp83848_model u_phy (
    .mii_rx_clk (eth_rx_clk),
    .mii_tx_clk (eth_tx_clk),
    .mii_rxd    (eth_rxd),
    .mii_rx_dv  (eth_rx_dv),
    .mii_rx_er  (eth_rxerr),
    .mii_txd    (eth_txd),
    .mii_tx_en  (eth_tx_en)
  );

  // Clause 22 MDIO slave with DP83848 identity and PHYSTS: answers at PHYAD only (the strap reading of the schematic
  // differs from the manual's address 1; the bench, like the firmware, scans). The line is the pull-up plus the open-drain
  // slave output.
  logic slv_en;
  logic slv_val;
  rtlnet_tb_mdio_slave #(.PHY_ADDR(5'(PHYAD)), .T_VALID_NS(100)) u_mdio_slave (
    .mdc(eth_mdc), .mdio(eth_mdio), .drive_en(slv_en), .drive_val(slv_val));
  assign eth_mdio = slv_en ? slv_val : 1'bz;

  // PHY side: registers and link-up time (20 us after the reset release).
  initial begin
    #1;
    u_mdio_slave.regs[0]  = 16'h3100;   // BMCR: autonegotiation, 100 Mb/s
    u_mdio_slave.regs[1]  = 16'h7841;   // BMSR: no link yet
    u_mdio_slave.regs[2]  = 16'h2000;   // PHYIDR1
    u_mdio_slave.regs[3]  = 16'h5C90;   // PHYIDR2
    u_mdio_slave.regs[4]  = 16'h01E1;   // ANAR
    u_mdio_slave.regs[5]  = 16'h0000;   // ANLPAR
    u_mdio_slave.regs[16] = 16'h0000;   // PHYSTS
  end
  always @(posedge eth_rstn) begin
    #20_000;
    u_mdio_slave.regs[1]  = 16'h7849;                              // link up, autonegotiation complete
    u_mdio_slave.regs[5]  = 16'h01E1;                              // partner advertises 10/100 full and half
    u_mdio_slave.regs[16] = (speed_mbps == 10) ? 16'h0017 : 16'h0015;   // PHYSTS: link, speed (bit 1 = 10 Mb/s), full duplex, AN complete
  end

  // PHY reference clock monitor: period and the number of edges before the PHY reset is released.
  realtime ref_t0, ref_t1;
  int      ref_edges = 0;
  int      ref_edges_at_release = -1;
  bit      ref_period_ok = 1'b0;
  always @(posedge eth_ref_clk) begin
    ref_edges++;
    ref_t0 = ref_t1;
    ref_t1 = $realtime;
    if (ref_edges > 2 && ref_t1 - ref_t0 > 39.9 && ref_t1 - ref_t0 < 40.1) ref_period_ok = 1'b1;
    if (ref_edges > 2 && (ref_t1 - ref_t0 < 39.9 || ref_t1 - ref_t0 > 40.1)) ref_period_ok = 1'b0;
  end
  always @(posedge eth_rstn) if (ref_edges_at_release < 0) ref_edges_at_release = ref_edges;

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
  logic [4:0] phy_addr = 5'd1;     // set by the bus scan

  task automatic mdio_out_bit(input bit b);
    wr(BB, {29'd0, b, 1'b1, 1'b0});
    wr(BB, {29'd0, b, 1'b1, 1'b1});
  endtask

  task automatic mdio_in_bit(output bit b);
    logic [31:0] d;
    wr(BB, 32'd0);
    #(300);                      // slave output valid delay (100 ns) plus the MDIO input synchronizer; the firmware's MDC is slower still
    rd(BB, d);
    b = d[0];
    wr(BB, 32'd1);
  endtask

  task automatic mdio_write(input logic [4:0] reg_a, input logic [15:0] v);
    logic [31:0] w;
    for (int i = 0; i < 32; i++) mdio_out_bit(1'b1);
    w = {2'b01, 2'b01, phy_addr, reg_a, 2'b10, v};
    for (int i = 31; i >= 0; i--) mdio_out_bit(w[i]);
    wr(BB, 32'd0);
  endtask

  task automatic mdio_read(input logic [4:0] reg_a, output logic [15:0] v, output bit ok);
    logic [13:0] h;
    bit ta;
    bit b;
    for (int i = 0; i < 32; i++) mdio_out_bit(1'b1);
    h = {2'b01, 2'b10, phy_addr, reg_a};
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
    bit ok;
    string why;
    bytes_t head;
    // The PHY model captures the wire frame (preamble, SFD, nibble order, FCS and gap are checked inside the model)
    // and returns the payload without the FCS.
    u_phy.get(got, ok);
    tb_check(ok, $sformatf("%s: no frame from the board", what));
    if (!ok) return;
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

  // Pure TCP ACK (20-byte header, flags ACK, no payload) with correct checksums, padded to 60 bytes.
  function automatic bytes_t ack_frame(input bit [47:0] dst_mac, input bit [47:0] src_mac, input bit [31:0] src_ip,
                                       input bit [31:0] dst_ip, input bit [15:0] sport, input bit [15:0] dport,
                                       input bit [31:0] seq, input bit [31:0] ack);
    bytes_t q;
    bytes_t ip;
    bytes_t seg;
    bytes_t ps;
    bit [15:0] c;
    push16(seg, sport); push16(seg, dport); push32(seg, seq); push32(seg, ack);
    push16(seg, 16'h5010); push16(seg, 16'h2000); push16(seg, 16'h0000); push16(seg, 16'h0000);
    ip = ipv4_header(16'(20 + seg.size()), 16'h4322, 8'd6, src_ip, dst_ip);
    push32(ps, src_ip); push32(ps, dst_ip); ps.push_back(8'h00); ps.push_back(8'd6); push16(ps, 16'(seg.size()));
    for (int i = 0; i < $size(seg); i++) ps.push_back(seg[i]);
    c = inet_checksum(ps, 0, ps.size());
    seg[16] = c[15:8]; seg[17] = c[7:0];
    q = eth_header(dst_mac, src_mac, 16'h0800);
    for (int i = 0; i < $size(ip); i++) q.push_back(ip[i]);
    for (int i = 0; i < $size(seg); i++) q.push_back(seg[i]);
    return pad60(q);
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
    #(400_000_000);
    tb_error("watchdog: bench did not finish in 400 ms");
    tb_verdict("tb_rtlnet_arty_a7_100_eth");
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
    partner_code = (speed_mbps == 10) ? 2'b00 : 2'b01;
    wait (dut.mmcm_locked === 1'b1);
    dut.u_cpu.wait_reset_release();

    // Identity of every core.
    check_reg(SYS,  32'h4554_4853, "SYS ID");
    check_reg(SYS + 32'h004, 32'h1114_2026, "SYS VERSION");
    check_reg(SYS + 32'h008, 32'h0404_0400, "SYS CAPS (4 buttons, 4 switches, 4 LEDs)");
    check_reg(SYS + 32'h00C, 32'hBEEF_0001, "SYS BUILD_ID");
    check_reg(SYS + 32'h010, 32'h0, "SYS BUILD_DIRTY");
    check_reg(SYS + 32'h014, 32'h4152_5459, "SYS BOARD_ID (ARTY)");
    check_reg(SYS + 32'h018, SYS_CLK_HZ, "SYS CPU_CLK_HZ");
    check_reg(SYS + 32'h01C, 32'h3, "SYS LINK_CAPS: 10 and 100 full duplex");
    wr(SYS + 32'h024, 32'h0000_000B);
    check_reg(SYS + 32'h024, 32'h0000_000A, "SYS LEDS write and read back (bit 0 stays 0)");
    wr(SYS + 32'h030, 32'hC0DE_1234);
    check_reg(SYS + 32'h030, 32'hC0DE_1234, "SYS SCRATCH");
    #(1_000);
    check_reg(SYS + 32'h028, 32'h0000_0005, "SYS SWITCHES");
    check_reg(SYS + 32'h02C, 32'h0000_0008, "SYS BUTTONS (btn[3] pressed)");
    check_reg(SYS + 32'h034, 32'h1, "SYS CLK_STATUS: clocks locked");
    tb_check(led === 4'b1011, $sformatf("LED pins %b follow the LEDS register and the clock lock", led));
    begin
      logic [1:0] r;
      logic [31:0] dd;
      dut.u_cpu.axil_read(WIN + 32'h2_0000, dd, r);
      tb_check(r == 2'b11, $sformatf("unmapped window answers DECERR, resp %b", r));
    end
    check_reg(MAC,  32'h4D41_4331, "MAC ID");
    check_reg(MDIO, 32'h4D44_494F, "MDIO ID");
    check_reg(ECHO, 32'h4543_484F, "ECHO ID");
    check_reg(PROT, 32'h5052_4F54, "PROT ID");
    check_reg(ARP,  32'h4152_5031, "ARP ID");
    check_reg(ICMP, 32'h4943_4D50, "ICMP ID");
    check_reg(DHCP, 32'h4448_4350, "DHCP ID");
    check_reg(IPRF, 32'h4950_5246, "IPRF ID");
    check_reg(UDPS, 32'h5544_5053, "UDPS ID");
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
    tb_check(eth_rstn === 1'b1, "PHY reset released by the MDIO core");
    // The 25 MHz reference clock: running at 25 MHz, and for the whole PHY reset hold (POR_RESET_MS = 1 ms is 25000 edges,
    // plus the time the clock ran before the cores left reset).
    tb_check(ref_period_ok, "eth_ref_clk period is 40 ns");
    tb_check(ref_edges_at_release >= 24_000, $sformatf("eth_ref_clk edges before the PHY reset release: %0d, expected at least 24000", ref_edges_at_release));
    #(10_000);

    // Bus scan for the PHY, as rtlnet_phy_find does: PHYID1 at every address, the first one that is not 0xFFFF/0x0000.
    begin
      bit found;
      found = 1'b0;
      for (int a = 1; a < 32 && !found; a++) begin
        phy_addr = 5'(a);
        mdio_read(5'd2, v, ok);
        if (ok && v != 16'hFFFF && v != 16'h0000) found = 1'b1;
      end
      tb_check(found && phy_addr == 5'(PHYAD), $sformatf("PHY found at address %0d, the slave answers at %0d", phy_addr, PHYAD));
    end
    // PHY identity (DP83848J: PHYIDR1 0x2000, PHYIDR2 0x5C9x with the revision nibble masked).
    mdio_read(5'd2, v, ok);
    tb_check(ok && v == 16'h2000, $sformatf("PHYID1 0x%04x ok %0d", v, ok));
    mdio_read(5'd3, v, ok);
    tb_check(ok && (v & 16'hFFF0) == 16'h5C90, $sformatf("PHYID2 0x%04x ok %0d", v, ok));
    // Advertise 10/100 full duplex only (ANAR write, read back).
    mdio_write(5'd4, 16'h0181);
    mdio_read(5'd4, v, ok);
    tb_check(ok && v == 16'h0181, $sformatf("ANAR read back 0x%04x", v));

    // Link up at the partner speed (PHYSTS 0x10: bit 0 link, bit 1 speed 10 Mb/s, bit 2 full duplex, bit 4 AN complete).
    polls = 0;
    do begin
      mdio_read(5'd16, v, ok);
      polls++;
    end while (!(v[0] && v[4]) && polls < 40);
    tb_check(v[0] && v[4] && v[2], $sformatf("PHYSTS link/AN complete/full duplex 0x%04x", v));
    tb_check((v[1] ? 2'b00 : 2'b01) == partner_code, $sformatf("PHYSTS speed10 %0d, expected speed code %b", v[1], partner_code));

    // MAC: speed from PHYSTS, RX/TX enable, LINK_UP; receive path qualified.
    wr(MAC + 32'h00C, {23'd0, 1'b1, 2'b00, partner_code, 2'b00, 2'b11});
    polls = 0;
    do begin
      rd(MAC + 32'h010, d);
      polls++;
    end while (!(d[0] && !d[2]) && polls < 5000);
    tb_check(d[0] && !d[2], $sformatf("MAC STATUS 0x%08x: RX_CLK_OK and receive path running", d));
    #(2_000);
    rd(SYS + 32'h03C, d);
    tb_check(d[0] && d[2:1] == partner_code && d[3], $sformatf("SYS NET_STATUS 0x%08x: link up, speed %b, RXC ok", d, partner_code));
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
    u_phy.send(pad60(req), 0, 15);
    expect_frame(arp_reply(req, BOARD_MAC, BOARD_IP), "ARP reply", got);

    // ICMP echo request, 56-byte payload.
    payload = rand_bytes(seed, 56);
    req = echo_request(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'h1234, 16'd1, payload);
    u_phy.send(req, 0, 15);
    expect_frame(echo_reply(req, BOARD_MAC, BOARD_IP), "ICMP echo reply", got);

    // UDP datagram to port 7: echoed to the sender.
    payload = rand_bytes(seed, 100);
    req = udp_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'd40000, 16'd7, payload);
    u_phy.send(req, 0, 15);
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
    u_phy.send(req, 0, 15);
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
      u_phy.send(req, 0, 15);
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
        u_phy.send(bcast, 0, 15);
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
      u_phy.send(good_tcp, 0, 15);
      dut.u_cpu.eth_get(cpu_f, 200_000, cpu_ok);
      tb_check(cpu_ok, "RX offload: good TCP segment reached the CPU");
      if (cpu_ok) begin
        tb_check(bytes_equal(cpu_f, with_trailer(good_tcp, 16'hFFFF, 16'h00E3, 8'd34), why),
                 $sformatf("RX offload: good TCP segment with verified trailer: %s", why));
      end
      bad_tcp = good_tcp;
      bad_tcp[60] = bad_tcp[60] ^ 8'h10;
      u_phy.send(bad_tcp, 0, 15);
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
      u_phy.send(good_tcp, 0, 15);
      dut.u_cpu.eth_get(cpu_f, 200_000, cpu_ok);
      tb_check(cpu_ok && bytes_equal(cpu_f, good_tcp, why), $sformatf("RX offload off: frame unchanged: %s", why));
      f = tcp_frame(HOST_MAC, BOARD_MAC, BOARD_IP, HOST_IP, 16'd9999, 16'd40001, pay, 1'b0);
      dut.u_cpu.eth_send(f);
      expect_frame(f, "TX offload off: garbage checksums left as sent", got);
    end

    // CPU-path receive batching and ACK coalescing end to end (cores/rtlnet_tcp_offload, ACK_COALESCE / RX_BATCH
    // built for the Ethernet demo): the stub sees one DMA transfer per batch.
    begin
      bytes_t tf [0:2];
      bytes_t ak [0:3];
      bytes_t exp_t;
      bytes_t pay;
      bytes_t cpu_f;
      bit     cpu_ok;
      string  why;
      logic [1:0] r;
      rd(OFL + 32'h008, d);
      tb_check(d[7:6] == 2'b11, $sformatf("offload CAPS 0x%08x: ACK coalescing and batching present", d));
      rd(OFL + 32'h01C, d);
      tb_check(d[7:0] == 8'd4 && d[23:8] == 16'd2056, $sformatf("offload CAPS2 0x%08x: 4 flows, 2056-byte batch reserve", d));
      dut.u_cpu.txo_config(OFL, 32'h1F, r);
      tb_check(r == 2'b00, $sformatf("offload batch enable resp %b", r));
      // Three segments back to back: the frame-count limit closes the batch, one transfer carries the three frames.
      wr(OFL + 32'h02C, 32'd3);
      wr(OFL + 32'h028, 32'd3000);
      exp_t = {};
      for (int k = 0; k < 3; k++) begin
        bytes_t one;
        pay = rand_bytes(seed, 21 + 17 * k);
        tf[k] = tcp_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'd40005, 16'd5001, pay, 1'b1);
        u_phy.send(tf[k], 0, 15);
        one = with_trailer(tf[k], 16'hFFFF, 16'h00E3, 8'd34);
        for (int j = 0; j < one.size(); j++) exp_t.push_back(one[j]);
      end
      dut.u_cpu.eth_get(cpu_f, 600_000, cpu_ok);
      tb_check(cpu_ok, "batch: the transfer arrived");
      if (cpu_ok) tb_check(bytes_equal(cpu_f, exp_t, why), $sformatf("batch: three frames, one transfer: %s", why));
      check_reg(OFL + 32'h0A0, 32'd1, "offload BATCHES");
      check_reg(OFL + 32'h0A4, 32'd3, "offload BATCH_FRAMES");
      check_reg(OFL + 32'h0AC, 32'd1, "offload BATCH_CLOSE_COUNT");
      // A run of pure ACKs of one flow: only the newest leaves, after the coalescing timer, through the batcher.
      wr(OFL + 32'h020, 32'd1000);
      wr(OFL + 32'h02C, 32'd16);
      wr(OFL + 32'h028, 32'd200);
      for (int k = 0; k < 4; k++) begin
        ak[k] = ack_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'd40007, 16'd5001, 32'h5000_0001, 32'h6000_0000 + 32'd1460 * (k + 1));
        u_phy.send(ak[k], 0, 15);
      end
      dut.u_cpu.eth_get(cpu_f, 900_000, cpu_ok);
      tb_check(cpu_ok, "ACK coalescing: the newest ACK arrived");
      if (cpu_ok) tb_check(bytes_equal(cpu_f, with_trailer(ak[3], 16'hFFFF, 16'h00E3, 8'd34), why),
                           $sformatf("ACK coalescing: only the newest ACK, with its trailer: %s", why));
      check_reg(OFL + 32'h080, 32'd4, "offload ACK candidates");
      check_reg(OFL + 32'h084, 32'd3, "offload ACKs dropped");
      check_reg(OFL + 32'h088, 32'd1, "offload ACKs forwarded");
      check_reg(OFL + 32'h08C, 32'd1, "offload ACK flushes by timer");
      dut.u_cpu.eth_get(cpu_f, 20_000, cpu_ok);
      tb_check(!cpu_ok, "ACK coalescing: no further frame");
      rd(OFL + 32'h010, d);
      tb_check(d[3:0] == 4'hF, $sformatf("offload STATUS 0x%08x: all four blocks idle", d));
      dut.u_cpu.txo_config(OFL, 32'h0, r);
      tb_check(r == 2'b00, $sformatf("offload batch disable resp %b", r));
    end

    // CPU-path protection profile (rtlnet_classifier_config_protect register sequence): four classes with
    // their own policers (0 broadcast, 1 UDP, 2 ARP, 3 ICMP) while unicast TCP keeps flowing. Every class is
    // sent above its limit, interleaved with unicast TCP segments to the board: exactly the limit of each class
    // passes, every TCP segment passes byte-exact, and a frame in several classes is counted once (an ARP
    // request is broadcast too, but the ARP rule has priority over the MAC table).
    begin
      bytes_t exp_q [$];
      bytes_t cpu_f;
      bit     cpu_ok;
      string  why;
      logic [1:0] r;
      logic [31:0] c_now;
      int     base_rx;
      int     n_pass;
      int     polls_p;
      int     bad_order;
      dut.u_cpu.cls_config_protect(CLS, PROT_LIM_BCAST, PROT_LIM_UDP, PROT_LIM_ARP, PROT_LIM_ICMP, PROT_WINDOW, r);
      tb_check(r == 2'b00, $sformatf("protection profile configuration resp %b", r));
      wr(CLS + 32'h00C, 32'h0001_0001);                       // CNT_CLEAR, MODE stays PASS_ALL
      rd(CLS + 32'h010, d);
      tb_check((d & 32'h0000_0301) == 32'h0000_0100, $sformatf("classifier STATUS 0x%08x: MODE pass-all after the profile", d));
      rd(PROT + 32'h054, d);
      base_rx = int'(d);
      n_pass = 0;
      for (int i = 0; i < PROT_N_TCP; i++) begin
        if (i < PROT_N_BCAST) begin
          // Broadcast TCP segment: only the broadcast class.
          f = tcp_frame(48'hFFFF_FFFF_FFFF, HOST_MAC, HOST_IP, BOARD_IP, 16'd41000 + 16'(i), 16'd9998, rand_bytes(seed, 20), 1'b1);
          u_phy.send(f, 0, 15);
          if (i < PROT_LIM_BCAST) begin exp_q.push_back(f); n_pass++; end
        end
        if (i < PROT_N_UDP) begin
          // Unicast UDP to a port no hardware leaf owns: the UDP class.
          f = udp_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'd41100 + 16'(i), 16'd9999, rand_bytes(seed, 20));
          u_phy.send(f, 0, 15);
          if (i < PROT_LIM_UDP) begin exp_q.push_back(f); n_pass++; end
        end
        if (i < PROT_N_ARP) begin
          // ARP request for another host (the ARP leaf answers only its own address): broadcast and ARP.
          f = pad60(arp_request(HOST_MAC, HOST_IP, SRV_IP + 32'(i) + 32'd10));
          u_phy.send(f, 0, 15);
          if (i < PROT_LIM_ARP) begin exp_q.push_back(f); n_pass++; end
        end
        if (i < PROT_N_ICMP) begin
          // ICMP type 0 (echo reply) to the board: no leaf claims it, the ICMP class.
          f = echo_request(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'h2222, 16'(i), rand_bytes(seed, 20));
          f[34] = 8'd0;
          u_phy.send(f, 0, 15);
          if (i < PROT_LIM_ICMP) begin exp_q.push_back(f); n_pass++; end
        end
        // Unicast TCP-like segment to the board during the burst: never policed.
        f = tcp_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, 16'd40100 + 16'(i), 16'd5001, rand_bytes(seed, 20), 1'b1);
        u_phy.send(f, 0, 15);
        exp_q.push_back(f);
        n_pass++;
      end
      // Wait until the wrapper has committed every frame of the burst to the CPU queue and the classifier judged it.
      polls_p = 0;
      do begin
        #(20_000);
        rd(PROT + 32'h054, d);
        rd(CLS + 32'h080, c_now);
        polls_p++;
      end while ((int'(d) - base_rx < PROT_N_TOTAL || int'(c_now) < PROT_N_TOTAL) && polls_p < 400);
      tb_check(int'(d) - base_rx == PROT_N_TOTAL, $sformatf("CPU_RX_FRAMES advanced %0d, expected %0d", int'(d) - base_rx, PROT_N_TOTAL));
      // The CPU receives exactly the passing frames, in order, byte-exact.
      bad_order = 0;
      for (int k = 0; k < exp_q.size(); k++) begin
        dut.u_cpu.eth_get(cpu_f, 200_000, cpu_ok);
        if (!cpu_ok || !bytes_equal(cpu_f, exp_q[k], why)) bad_order++;
      end
      tb_check(bad_order == 0, $sformatf("protection profile: %0d of %0d passing frames missing or different (in order)", bad_order, exp_q.size()));
      dut.u_cpu.eth_get(cpu_f, 40_000, cpu_ok);
      tb_check(!cpu_ok, "protection profile: no frame beyond a class limit reaches the CPU");
      // Policer counters: SEEN = sent, PASSED = limit, DROPPED = the rest, per class.
      check_reg(CLS + 32'h100 + 32'h0C, PROT_N_BCAST, "profile broadcast policer SEEN (broadcast TCP only, ARP counted as ARP)");
      check_reg(CLS + 32'h100 + 32'h10, PROT_LIM_BCAST, "profile broadcast policer PASSED");
      check_reg(CLS + 32'h100 + 32'h14, PROT_N_BCAST - PROT_LIM_BCAST, "profile broadcast policer DROPPED");
      check_reg(CLS + 32'h120 + 32'h0C, PROT_N_UDP, "profile UDP policer SEEN");
      check_reg(CLS + 32'h120 + 32'h10, PROT_LIM_UDP, "profile UDP policer PASSED");
      check_reg(CLS + 32'h120 + 32'h14, PROT_N_UDP - PROT_LIM_UDP, "profile UDP policer DROPPED");
      check_reg(CLS + 32'h140 + 32'h0C, PROT_N_ARP, "profile ARP policer SEEN");
      check_reg(CLS + 32'h140 + 32'h10, PROT_LIM_ARP, "profile ARP policer PASSED");
      check_reg(CLS + 32'h140 + 32'h14, PROT_N_ARP - PROT_LIM_ARP, "profile ARP policer DROPPED");
      check_reg(CLS + 32'h160 + 32'h0C, PROT_N_ICMP, "profile ICMP policer SEEN");
      check_reg(CLS + 32'h160 + 32'h10, PROT_LIM_ICMP, "profile ICMP policer PASSED");
      check_reg(CLS + 32'h160 + 32'h14, PROT_N_ICMP - PROT_LIM_ICMP, "profile ICMP policer DROPPED");
      check_reg(CLS + 32'h080, PROT_N_TOTAL, "classifier FRAMES in the profile phase");
      check_reg(CLS + 32'h084, n_pass, "classifier PASSED in the profile phase");
      check_reg(CLS + 32'h090, PROT_N_TOTAL - n_pass, "classifier POLICE_DROPPED in the profile phase");
      check_reg(CLS + 32'h088, PROT_N_TOTAL - n_pass, "classifier DROPPED in the profile phase (all by policers)");
      check_reg(CLS + 32'h0AC, PROT_N_ARP, "RULE_HIT[0]: the ARP rule");
      check_reg(CLS + 32'h094, PROT_N_BCAST + PROT_N_ARP, "MAC table hits: broadcast TCP and the broadcast ARP requests");
      check_reg(CLS + 32'h0A8, PROT_N_UDP + PROT_N_ICMP, "tuple table hits: UDP and ICMP");
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
    u_phy.send(f, 0, 15);
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
    u_phy.send(f, 0, 15);
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
    u_phy.send(pad60(req), 0, 15);
    expect_frame(arp_reply(req, BOARD_MAC, LEASE_IP), "ARP reply for the leased address", got);

    // Counters and PHY-side timing.
    rd(MAC + 32'h020, d);
    tb_check(d - rx_good0 == 7 + 1 + STORM_BURST + 3 + 7 + PROT_N_TOTAL,
             $sformatf("MAC RX_GOOD advanced %0d, expected %0d", d - rx_good0, 7 + 1 + STORM_BURST + 3 + 7 + PROT_N_TOTAL));
    rd(MAC + 32'h024, d);
    tb_check(d == 0, $sformatf("MAC RX_BAD %0d", d));
    rd(MAC + 32'h02C, d);
    tb_check(d - tx0 == 7 + 3, $sformatf("MAC TX_FRAMES advanced %0d, expected 10", d - tx0));
    check_reg(ARP + 32'h024, 32'd2, "ARP REPLIES_SENT");
    check_reg(ICMP + 32'h024, 32'd1, "ICMP ECHO_REPLIES");
    $display("bench: MDIO slave frames read %0d write %0d ignored %0d errors %0d", u_mdio_slave.frames_read, u_mdio_slave.frames_write,
             u_mdio_slave.frames_ignored, u_mdio_slave.frame_errors);
    tb_check(u_mdio_slave.frame_errors == 0, $sformatf("MDIO slave frame errors %0d", u_mdio_slave.frame_errors));
    tb_check(u_phy.pending() == 0, $sformatf("PHY model: %0d unfetched wire frames", u_phy.pending()));
    tb_check(dut.u_cpu.axil_timeouts == 0, "no AXI4-Lite timeouts");

    tb_verdict("tb_rtlnet_arty_a7_100_eth");
  end

endmodule
