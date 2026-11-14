// -----------------------------------------------------------------------------
// File: rtlnet_nexys_video_eth_top.sv
// Purpose: the Nexys Video Ethernet demo top: 10/100/1000 Mb/s Ethernet (RGMII, RTL8211E) with the RTLNet network
//   cores and a small MicroBlaze V CPU running DHCP, ARP, ping, UDP and lwIP TCP. No DDR3, no camera, no video and no
//   H.264: pins, one MMCM and its global buffers, the reset tree, the Ethernet CPU core rtlnet_cpu_eth, the RTLNet
//   AXI4-Lite address decoder, the board-independent system registers, the PHY MDIO pad buffer and the network cores.
// Overview:
//   * Clocks (architecture section 9): MMCME2_ADV u_mmcm, 100 MHz in, VCO 1000 MHz; CLKOUT0 clk125, CLKOUT1 clk125_90
//     (90 deg), CLKOUT2 clk200, CLKOUT3 axis_clk 62.5 MHz, CLKOUT4 proto_clk 50 MHz, CLKOUT5 cpu_clk (CPU_CLK_HZ,
//     100 MHz by default; the divider is 1000 MHz / CPU_CLK_HZ), each on a BUFG; feedback through BUFG u_bufg_fb. cpu_clk is the CPU, AXI4-Lite, system
//     register, MDIO and CPU-path stream clock.
//   * Resets: one assertion, rst_arstn = cpu_resetn (button, low = pressed) AND mmcm_locked, enters one
//     rtlnet_reset_sync per clock. Glitch argument for the AND: either input low asserts every domain at once (safe in
//     any order); release needs rst_arstn high for STAGES consecutive clocks of each domain, so a short high glitch
//     cannot release a domain.
//   * CPU core u_cpu (rtlnet_cpu_eth; with RTLNET_CPU_ETH_SIM_STUB defined, the simulation stub rtlnet_cpu_eth_sim_stub
//     with the same ports, for the board bench) masters u_decoder (rtlnet_axil_decoder) over the RTLNet window
//     0x44A0_0000 (architecture section 6.1):
//       slave 0 SYS        0x44A0_0000   4 KiB  u_sysregs (rtlnet_cpu_eth_sysregs)
//       slave 1 MAC        0x44A0_1000   4 KiB  u_mac
//       slave 2 MDIO       0x44A0_2000   4 KiB  u_mdio
//       slave 3 ECHO       0x44A0_3000   4 KiB  u_echo
//       slave 4 PROTOCOL   0x44A1_0000  64 KiB  u_protocol (ARP, ICMP, DHCP, iperf, UDP sockets, CPU-path
//                                                classifier and checksum offload in its sub-map)
//     Other addresses inside the 1 MiB window get DECERR.
//   * Network path: u_mac (rtlnet_eth_mac, RGMII) <-> u_protocol (rtlnet_eth_protocol) <-> u_echo (rtlnet_udp_echo on
//     the socket payload streams); the CPU network path (cpu_axis_ethernet_stream, architecture 7.4) joins the CPU core's
//     AXI DMA streams m_axis_eth_* / s_axis_eth_* to the protocol wrapper's s_axis_cpu_eth_* / m_axis_cpu_eth_* on
//     cpu_clk.
//   * PHY: the board top owns the eth_mdio IOBUF; rtlnet_mdio drives MDC, MDIO and the PHY reset.
//   * Board facts for the firmware: BOARD_ID (ASCII "NXVD"), CPU_CLK_HZ and LINK_CAPS (10/100/1000 full duplex) are
//     parameters of u_sysregs; the firmware reads them from its registers.
//   * LEDs: led[0] clocks locked, led[7:1] system-register bits (led[1] is the firmware heartbeat by convention,
//     led[2] link, led[3] DHCP lease).
//   * MMCM, BUFG and IOBUF primitives appear in this file only.
// Language: SystemVerilog-2012.
// Revision: 11-14-2026
//   * 11-14-2026: initial version (network part of rtlnet_nexys_video_top with the DDR3, video and H.264 parts removed).
// Clocks: sysclk (100 MHz pin) -> MMCM -> clk125, clk125_90, clk200, axis_clk, proto_clk, cpu_clk; the MAC's receive
//   clock is internal to it.
// Pins: names, balls, banks and I/O standards from the Digilent Nexys-Video-Master.xdc (Rev. A); constraints in
//   boards/nexys_video/constraints/rtlnet_nexys_video_eth.xdc and rtlnet_nexys_video_rgmii.xdc.
// -----------------------------------------------------------------------------
module rtlnet_nexys_video_eth_top #(
  parameter logic [31:0] BUILD_ID     = 32'h0000_0000,  // git hash (build script: git rev-parse --short=8 HEAD)
  parameter logic        BUILD_DIRTY  = 1'b0,           // build tree had uncommitted changes
  parameter int          CPU_CLK_HZ   = 100_000_000,    // cpu_clk = MMCM CLKOUT5 = 1000 MHz / (1000 MHz / CPU_CLK_HZ); the build script
                                                        // passes the same value to the block design (build_ethernet.tcl)
  parameter int          MS_CYCLES    = 0,              // cpu_clk clocks per millisecond; 0 = CPU_CLK_HZ / 1000 (bench may shorten)
  parameter int          POR_RESET_MS = 20              // PHY reset hold after reset release
)(
  // System clock: 100 MHz oscillator, ball R4, net SYSCLK, bank 34 (3.3 V),
  // LVCMOS33, MRCC input; feeds only the MMCM.
  input  logic       sysclk,

  // CPU RESET push button: ball G4, net CPU_RESETN, bank 35 (1.5 V), LVCMOS15;
  // low while pressed, asynchronous.
  input  logic       cpu_resetn,

  // USB-UART bridge (FT232R), bank 14 (3.3 V), LVCMOS33, 115200 8N1, names from
  // the bridge's point of view: uart_tx_in ball V18 (bridge TXD -> FPGA receive,
  // asynchronous, idle high); uart_rx_out ball AA19 (FPGA transmit -> bridge RXD).
  input  logic       uart_tx_in,
  output logic       uart_rx_out,

  // User LEDs LD0..LD7, bank 13 (2.5 V), LVCMOS25, active high:
  // led[0] T14, [1] T15, [2] T16, [3] U16, [4] V15, [5] W16, [6] W15, [7] Y13.
  output logic [7:0] led,

  // Slide switches SW0..SW7, banks 16/15 (VADJ, 1.2 V default), LVCMOS12,
  // asynchronous levels: sw[0] E22, [1] F21, [2] G21, [3] G22, [4] H17,
  // [5] J16, [6] K13, [7] M17.
  input  logic [7:0] sw,

  // Push buttons, bank 16 (VADJ 1.2 V), LVCMOS12, high while pressed,
  // asynchronous: btnc B22, btnd D22, btnl C22, btnr D14, btnu F15.
  input  logic       btnc,
  input  logic       btnd,
  input  logic       btnl,
  input  logic       btnr,
  input  logic       btnu,

  // RTL8211E RGMII receive (PHY -> FPGA), bank 13 (2.5 V), LVCMOS25:
  // eth_rxck V13 (MRCC, receive clock 125/25/2.5 MHz), eth_rxctl W10,
  // eth_rxd[0] AB16, [1] AA15, [2] AB15, [3] AB11.
  input  logic       eth_rxck,
  input  logic       eth_rxctl,
  input  logic [3:0] eth_rxd,

  // RTL8211E RGMII transmit (FPGA -> PHY), bank 13 (2.5 V), LVCMOS25:
  // eth_txck AA14, eth_txctl V10, eth_txd[0] Y12, [1] W12, [2] W11, [3] Y11.
  output logic       eth_txck,
  output logic       eth_txctl,
  output logic [3:0] eth_txd,

  // RTL8211E management, bank 13 (2.5 V), LVCMOS25: eth_mdc AA16 (FPGA ->
  // PHY clock), eth_mdio Y16 (bidirectional, open-drain style, pulled up on
  // the board; the IOBUF below is its only driver).
  output logic       eth_mdc,
  inout  wire        eth_mdio,

  // RTL8211E reset and interrupt: eth_rst_b U7 (bank 34, 3.3 V, LVCMOS33,
  // active low, safe level low = PHY held in reset); eth_int_b Y14
  // (bank 13, 2.5 V, LVCMOS25, active low, asynchronous).
  output logic       eth_rst_b,
  input  logic       eth_int_b
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam int          CPU_CLK_DIV  = 1_000_000_000 / CPU_CLK_HZ;
  localparam int          MS_CLKS      = (MS_CYCLES == 0) ? (CPU_CLK_HZ / 1000) : MS_CYCLES;
  localparam int          PROTO_CLK_HZ = 50_000_000;
  localparam int          NUM_SLV      = 5;
  localparam int          AW           = 32;
  localparam int          SLV_SYS      = 0;
  localparam int          SLV_MAC      = 1;
  localparam int          SLV_MDIO     = 2;
  localparam int          SLV_ECHO     = 3;
  localparam int          SLV_PROT     = 4;
  localparam logic [31:0] RTLNET_BASE  = 32'h44A0_0000;
  localparam logic [31:0] WIN_4K       = 32'h0000_1000;
  localparam logic [31:0] WIN_64K      = 32'h0001_0000;
  localparam logic [31:0] BOARD_ID     = 32'h4E58_5644;  // "NXVD"
  localparam logic [2:0]  LINK_CAPS    = 3'b111;         // 10, 100 and 1000 Mb/s, full duplex
  // Slave i at [i*AW +: AW]; listed highest index first.
  localparam logic [NUM_SLV*AW-1:0] SLAVE_BASE = {
    RTLNET_BASE + 32'h0001_0000,    // 4 PROTOCOL
    RTLNET_BASE + 32'h0000_3000,    // 3 ECHO
    RTLNET_BASE + 32'h0000_2000,    // 2 MDIO
    RTLNET_BASE + 32'h0000_1000,    // 1 MAC
    RTLNET_BASE + 32'h0000_0000     // 0 SYS
  };
  localparam logic [NUM_SLV*AW-1:0] SLAVE_SIZE = {WIN_64K, WIN_4K, WIN_4K, WIN_4K, WIN_4K};

  generate
    if (CPU_CLK_DIV * CPU_CLK_HZ != 1_000_000_000) begin : g_bad_cpu_clk
      $fatal(1, "rtlnet_nexys_video_eth_top: CPU_CLK_HZ=%0d is not 1000 MHz / an integer", CPU_CLK_HZ);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic clkfb;
  logic clkfb_bufg;
  logic clk125_mmcm;
  logic clk125_90_mmcm;
  logic clk200_mmcm;
  logic axis_clk_mmcm;
  logic proto_clk_mmcm;
  logic cpu_clk_mmcm;
  logic clk125;                // 125 MHz, 0 deg: MAC transmit, RXC rate detector
  logic clk125_90;             // 125 MHz, 90 deg: RGMII TXC forwarding only
  logic clk200;                // 200 MHz: IDELAYCTRL reference
  logic axis_clk;              // 62.5 MHz: MAC client side, protocol filter
  logic proto_clk;             // 50 MHz: protocol leaves, UDP echo (app_clk)
  logic cpu_clk;               // CPU_CLK_HZ: CPU, AXI4-Lite, system registers, MDIO, CPU-path streams
  logic mmcm_locked;
  logic rst_arstn;
  logic clk125_resetn;
  logic clk200_resetn;
  logic axis_resetn;
  logic proto_resetn;
  logic cpu_resetn_sync;       // cpu_clk reset, released synchronously

  // ---------------------------------------------------------------------------
  // CPU register master and decoder ports
  // ---------------------------------------------------------------------------
  logic [31:0]           cpu_awaddr;
  logic                  cpu_awvalid;
  logic                  cpu_awready;
  logic [31:0]           cpu_wdata;
  logic [3:0]            cpu_wstrb;
  logic                  cpu_wvalid;
  logic                  cpu_wready;
  logic [1:0]            cpu_bresp;
  logic                  cpu_bvalid;
  logic                  cpu_bready;
  logic [31:0]           cpu_araddr;
  logic                  cpu_arvalid;
  logic                  cpu_arready;
  logic [31:0]           cpu_rdata;
  logic [1:0]            cpu_rresp;
  logic                  cpu_rvalid;
  logic                  cpu_rready;
  logic [7:0]            cpu_irq;

  // CPU network path (cpu_clk): eth_tx = frames the CPU sends, eth_rx = frames to the CPU.
  logic [63:0]           cpu_eth_tx_tdata;
  logic [7:0]            cpu_eth_tx_tkeep;
  logic                  cpu_eth_tx_tvalid;
  logic                  cpu_eth_tx_tlast;
  logic                  cpu_eth_tx_tready;
  logic [63:0]           cpu_eth_rx_tdata;
  logic [7:0]            cpu_eth_rx_tkeep;
  logic                  cpu_eth_rx_tvalid;
  logic                  cpu_eth_rx_tlast;
  logic                  cpu_eth_rx_tready;

  logic [NUM_SLV*AW-1:0] dec_awaddr;
  logic [NUM_SLV-1:0]    dec_awvalid;
  logic [NUM_SLV-1:0]    dec_awready;
  logic [NUM_SLV*32-1:0] dec_wdata;
  logic [NUM_SLV*4-1:0]  dec_wstrb;
  logic [NUM_SLV-1:0]    dec_wvalid;
  logic [NUM_SLV-1:0]    dec_wready;
  logic [NUM_SLV*2-1:0]  dec_bresp;
  logic [NUM_SLV-1:0]    dec_bvalid;
  logic [NUM_SLV-1:0]    dec_bready;
  logic [NUM_SLV*AW-1:0] dec_araddr;
  logic [NUM_SLV-1:0]    dec_arvalid;
  logic [NUM_SLV-1:0]    dec_arready;
  logic [NUM_SLV*32-1:0] dec_rdata;
  logic [NUM_SLV*2-1:0]  dec_rresp;
  logic [NUM_SLV-1:0]    dec_rvalid;
  logic [NUM_SLV-1:0]    dec_rready;

  // ---------------------------------------------------------------------------
  // Network path signals
  // ---------------------------------------------------------------------------
  logic [63:0] mac_rx_tdata;
  logic [7:0]  mac_rx_tkeep;
  logic        mac_rx_tvalid;
  logic        mac_rx_tlast;
  logic        mac_rx_tready;
  logic [63:0] mac_tx_tdata;
  logic [7:0]  mac_tx_tkeep;
  logic        mac_tx_tvalid;
  logic        mac_tx_tlast;
  logic        mac_tx_tready;
  logic [63:0] app_rx_tdata;
  logic [7:0]  app_rx_tkeep;
  logic        app_rx_tvalid;
  logic        app_rx_tlast;
  logic        app_rx_tready;
  logic [63:0] app_tx_tdata;
  logic [7:0]  app_tx_tkeep;
  logic        app_tx_tvalid;
  logic        app_tx_tlast;
  logic        app_tx_tready;
  logic        mac_stat_link_up;
  logic [1:0]  mac_stat_speed;
  logic        mac_stat_rx_clk_ok;
  logic        prot_stat_ip_valid;
  logic        prot_stat_dhcp_bound;
  logic        mdio_irq;

  // Board status, PHY pins
  logic [7:0]  led_fw;
  logic        tick_ms;
  logic [5:0]  net_status;
  logic        mdio_o;
  logic        mdio_t;
  logic        mdio_i;
  logic        phy_rst_n;

  // Clock generation: one MMCM, VCO = 100 MHz x 10 = 1000 MHz.
  // CLKOUT0 /8 = 125 MHz, CLKOUT1 /8 at 90 deg (2 ns) = 125 MHz,
  // CLKOUT2 /5 = 200 MHz, CLKOUT3 /16 = 62.5 MHz, CLKOUT4 /20 = 50 MHz,
  // CLKOUT5 /CPU_CLK_DIV = cpu_clk. RST tied low: the oscillator runs before
  // configuration ends, and the button resets logic, not the MMCM.
  MMCME2_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .COMPENSATION         ("ZHOLD"),
    .STARTUP_WAIT         ("FALSE"),
    .DIVCLK_DIVIDE        (1),
    .CLKFBOUT_MULT_F      (10.000),
    .CLKFBOUT_PHASE       (0.000),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKIN1_PERIOD        (10.000),
    .CLKIN2_PERIOD        (10.000),
    .REF_JITTER1          (0.010),
    .REF_JITTER2          (0.010),
    .CLKOUT4_CASCADE      ("FALSE"),
    .CLKOUT0_DIVIDE_F     (8.000),
    .CLKOUT0_PHASE        (0.000),
    .CLKOUT0_DUTY_CYCLE   (0.500),
    .CLKOUT0_USE_FINE_PS  ("FALSE"),
    .CLKOUT1_DIVIDE       (8),
    .CLKOUT1_PHASE        (90.000),
    .CLKOUT1_DUTY_CYCLE   (0.500),
    .CLKOUT1_USE_FINE_PS  ("FALSE"),
    .CLKOUT2_DIVIDE       (5),
    .CLKOUT2_PHASE        (0.000),
    .CLKOUT2_DUTY_CYCLE   (0.500),
    .CLKOUT2_USE_FINE_PS  ("FALSE"),
    .CLKOUT3_DIVIDE       (16),
    .CLKOUT3_PHASE        (0.000),
    .CLKOUT3_DUTY_CYCLE   (0.500),
    .CLKOUT3_USE_FINE_PS  ("FALSE"),
    .CLKOUT4_DIVIDE       (20),
    .CLKOUT4_PHASE        (0.000),
    .CLKOUT4_DUTY_CYCLE   (0.500),
    .CLKOUT4_USE_FINE_PS  ("FALSE"),
    .CLKOUT5_DIVIDE       (CPU_CLK_DIV),
    .CLKOUT5_PHASE        (0.000),
    .CLKOUT5_DUTY_CYCLE   (0.500),
    .CLKOUT5_USE_FINE_PS  ("FALSE")
  ) u_mmcm (
    .CLKIN1       (sysclk),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clkfb_bufg),
    .CLKFBOUT     (clkfb),
    .CLKFBOUTB    (),
    .CLKOUT0      (clk125_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (clk125_90_mmcm),
    .CLKOUT1B     (),
    .CLKOUT2      (clk200_mmcm),
    .CLKOUT2B     (),
    .CLKOUT3      (axis_clk_mmcm),
    .CLKOUT3B     (),
    .CLKOUT4      (proto_clk_mmcm),
    .CLKOUT5      (cpu_clk_mmcm),
    .CLKOUT6      (),
    .LOCKED       (mmcm_locked),
    .RST          (1'b0),
    .PWRDWN       (1'b0),
    .DADDR        (7'd0),
    .DCLK         (1'b0),
    .DEN          (1'b0),
    .DI           (16'd0),
    .DWE          (1'b0),
    .DO           (),
    .DRDY         (),
    .PSCLK        (1'b0),
    .PSEN         (1'b0),
    .PSINCDEC     (1'b0),
    .PSDONE       (),
    .CLKINSTOPPED (),
    .CLKFBSTOPPED ()
  );

  // Global clock buffers: feedback and the fabric clocks.
  BUFG u_bufg_fb        (.I(clkfb),          .O(clkfb_bufg));
  BUFG u_bufg_clk125    (.I(clk125_mmcm),    .O(clk125));
  BUFG u_bufg_clk125_90 (.I(clk125_90_mmcm), .O(clk125_90));
  BUFG u_bufg_clk200    (.I(clk200_mmcm),    .O(clk200));
  BUFG u_bufg_axis      (.I(axis_clk_mmcm),  .O(axis_clk));
  BUFG u_bufg_proto     (.I(proto_clk_mmcm), .O(proto_clk));
  BUFG u_bufg_cpu       (.I(cpu_clk_mmcm),   .O(cpu_clk));

  // The one reset assertion: button pressed or MMCM not locked.
  assign rst_arstn = cpu_resetn & mmcm_locked;

  // Reset release into clk125 (MAC transmit side; clk125_90 only forwards TXC).
  rtlnet_reset_sync u_rst_clk125 (.clk(clk125), .arstn(rst_arstn), .resetn(clk125_resetn));

  // Reset release into clk200.
  rtlnet_reset_sync u_rst_clk200 (.clk(clk200), .arstn(rst_arstn), .resetn(clk200_resetn));

  // Reset release into axis_clk.
  rtlnet_reset_sync u_rst_axis (.clk(axis_clk), .arstn(rst_arstn), .resetn(axis_resetn));

  // Reset release into proto_clk (also app_clk).
  rtlnet_reset_sync u_rst_proto (.clk(proto_clk), .arstn(rst_arstn), .resetn(proto_resetn));

  // Reset release into cpu_clk: the CPU, the decoder, MDIO, the system registers and the CPU-path streams.
  rtlnet_reset_sync u_rst_cpu (.clk(cpu_clk), .arstn(rst_arstn), .resetn(cpu_resetn_sync));

  // ---------------------------------------------------------------------------
  // CPU core
  // ---------------------------------------------------------------------------
`ifdef RTLNET_CPU_ETH_SIM_STUB
  // Board bench: simulation stub in place of the processor.
  rtlnet_cpu_eth_sim_stub #(
    .CLK_HZ (CPU_CLK_HZ)
  ) u_cpu (
`else
  // MicroBlaze subsystem: console on the USB-UART, register master into the
  // decoder, interrupts from the cores.
  rtlnet_cpu_eth u_cpu (
`endif
    .clk           (cpu_clk),
    .resetn        (cpu_resetn_sync),
    .uart_rxd      (uart_tx_in),
    .uart_txd      (uart_rx_out),
    .m_axi_awaddr  (cpu_awaddr),
    .m_axi_awvalid (cpu_awvalid),
    .m_axi_awready (cpu_awready),
    .m_axi_wdata   (cpu_wdata),
    .m_axi_wstrb   (cpu_wstrb),
    .m_axi_wvalid  (cpu_wvalid),
    .m_axi_wready  (cpu_wready),
    .m_axi_bresp   (cpu_bresp),
    .m_axi_bvalid  (cpu_bvalid),
    .m_axi_bready  (cpu_bready),
    .m_axi_araddr  (cpu_araddr),
    .m_axi_arvalid (cpu_arvalid),
    .m_axi_arready (cpu_arready),
    .m_axi_rdata   (cpu_rdata),
    .m_axi_rresp   (cpu_rresp),
    .m_axi_rvalid  (cpu_rvalid),
    .m_axi_rready  (cpu_rready),
    .irq           (cpu_irq),
    .m_axis_eth_tdata  (cpu_eth_tx_tdata),
    .m_axis_eth_tkeep  (cpu_eth_tx_tkeep),
    .m_axis_eth_tvalid (cpu_eth_tx_tvalid),
    .m_axis_eth_tlast  (cpu_eth_tx_tlast),
    .m_axis_eth_tready (cpu_eth_tx_tready),
    .s_axis_eth_tdata  (cpu_eth_rx_tdata),
    .s_axis_eth_tkeep  (cpu_eth_rx_tkeep),
    .s_axis_eth_tvalid (cpu_eth_rx_tvalid),
    .s_axis_eth_tlast  (cpu_eth_rx_tlast),
    .s_axis_eth_tready (cpu_eth_rx_tready)
  );

  // RTLNet window decoder: one transaction at a time to the window that owns
  // the address; unmapped addresses inside the 1 MiB window get DECERR.
  rtlnet_axil_decoder #(
    .N          (NUM_SLV),
    .ADDR_W     (AW),
    .SLAVE_BASE (SLAVE_BASE),
    .SLAVE_SIZE (SLAVE_SIZE)
  ) u_decoder (
    .aclk          (cpu_clk),
    .aresetn       (cpu_resetn_sync),
    .s_axi_awaddr  (cpu_awaddr),
    .s_axi_awvalid (cpu_awvalid),
    .s_axi_awready (cpu_awready),
    .s_axi_wdata   (cpu_wdata),
    .s_axi_wstrb   (cpu_wstrb),
    .s_axi_wvalid  (cpu_wvalid),
    .s_axi_wready  (cpu_wready),
    .s_axi_bresp   (cpu_bresp),
    .s_axi_bvalid  (cpu_bvalid),
    .s_axi_bready  (cpu_bready),
    .s_axi_araddr  (cpu_araddr),
    .s_axi_arvalid (cpu_arvalid),
    .s_axi_arready (cpu_arready),
    .s_axi_rdata   (cpu_rdata),
    .s_axi_rresp   (cpu_rresp),
    .s_axi_rvalid  (cpu_rvalid),
    .s_axi_rready  (cpu_rready),
    .m_axi_awaddr  (dec_awaddr),
    .m_axi_awvalid (dec_awvalid),
    .m_axi_awready (dec_awready),
    .m_axi_wdata   (dec_wdata),
    .m_axi_wstrb   (dec_wstrb),
    .m_axi_wvalid  (dec_wvalid),
    .m_axi_wready  (dec_wready),
    .m_axi_bresp   (dec_bresp),
    .m_axi_bvalid  (dec_bvalid),
    .m_axi_bready  (dec_bready),
    .m_axi_araddr  (dec_araddr),
    .m_axi_arvalid (dec_arvalid),
    .m_axi_arready (dec_arready),
    .m_axi_rdata   (dec_rdata),
    .m_axi_rresp   (dec_rresp),
    .m_axi_rvalid  (dec_rvalid),
    .m_axi_rready  (dec_rready)
  );

  // Board-independent system registers (window SYS): identity, board facts for the firmware, LEDs, switches,
  // buttons, uptime, network status.
  rtlnet_cpu_eth_sysregs #(
    .BUILD_ID    (BUILD_ID),
    .BUILD_DIRTY (BUILD_DIRTY),
    .BOARD_ID    (BOARD_ID),
    .CPU_CLK_HZ  (CPU_CLK_HZ),
    .MS_CYCLES   (MS_CLKS),
    .LINK_CAPS   (LINK_CAPS),
    .NUM_LED     (8),
    .NUM_SW      (8),
    .NUM_BTN     (5)
  ) u_sysregs (
    .clk               (cpu_clk),
    .resetn            (cpu_resetn_sync),
    .s_axi_awaddr      (dec_awaddr[SLV_SYS*AW +: 12]),
    .s_axi_awvalid     (dec_awvalid[SLV_SYS]),
    .s_axi_awready     (dec_awready[SLV_SYS]),
    .s_axi_wdata       (dec_wdata[SLV_SYS*32 +: 32]),
    .s_axi_wstrb       (dec_wstrb[SLV_SYS*4 +: 4]),
    .s_axi_wvalid      (dec_wvalid[SLV_SYS]),
    .s_axi_wready      (dec_wready[SLV_SYS]),
    .s_axi_bresp       (dec_bresp[SLV_SYS*2 +: 2]),
    .s_axi_bvalid      (dec_bvalid[SLV_SYS]),
    .s_axi_bready      (dec_bready[SLV_SYS]),
    .s_axi_araddr      (dec_araddr[SLV_SYS*AW +: 12]),
    .s_axi_arvalid     (dec_arvalid[SLV_SYS]),
    .s_axi_arready     (dec_arready[SLV_SYS]),
    .s_axi_rdata       (dec_rdata[SLV_SYS*32 +: 32]),
    .s_axi_rresp       (dec_rresp[SLV_SYS*2 +: 2]),
    .s_axi_rvalid      (dec_rvalid[SLV_SYS]),
    .s_axi_rready      (dec_rready[SLV_SYS]),
    .sw_async          (sw),
    .btn_async         ({btnu, btnr, btnl, btnd, btnc}),
    .clk_locked_async  (mmcm_locked),
    .phy_async         ({mdio_i, eth_int_b}),
    .phy_rst_n         (phy_rst_n),
    .net_status_async  (net_status),
    .led_fw            (led_fw),
    .tick_ms           (tick_ms)
  );

  // MDIO pad: the only driver of eth_mdio; mdio_t = 1 releases the line.
  IOBUF u_mdio_iobuf (
    .I  (mdio_o),
    .T  (mdio_t),
    .O  (mdio_i),
    .IO (eth_mdio)
  );

  // LEDs: lock indicator on led[0], firmware bits on led[7:1].
  assign led = {led_fw[7:1], mmcm_locked};

  // ---------------------------------------------------------------------------
  // Network cores: MAC, MDIO, protocol wrapper, UDP echo (architecture 15.1-15.5)
  // ---------------------------------------------------------------------------

  // 10/100/1000 RGMII MAC; its pin layer u_rgmii_io is named by the board XDC.
  rtlnet_eth_mac #(
    .RX_FIFO_KB      (8),
    .TX_FIFO_KB      (8),
    .MAX_FRAME_BYTES (1518),
    .RX_IDELAY_TAP   (12),
    .RAM_STYLE       ("block")
  ) u_mac (
    .clk125            (clk125),
    .clk125_90         (clk125_90),
    .clk200            (clk200),
    .axis_clk          (axis_clk),
    .s_axi_aclk        (cpu_clk),
    .clk125_resetn     (clk125_resetn),
    .clk200_resetn     (clk200_resetn),
    .axis_resetn       (axis_resetn),
    .s_axi_aresetn     (cpu_resetn_sync),
    .rgmii_rxc         (eth_rxck),
    .rgmii_rxd         (eth_rxd),
    .rgmii_rx_ctl      (eth_rxctl),
    .rgmii_txc         (eth_txck),
    .rgmii_txd         (eth_txd),
    .rgmii_tx_ctl      (eth_txctl),
    .m_axis_rx_tdata   (mac_rx_tdata),
    .m_axis_rx_tkeep   (mac_rx_tkeep),
    .m_axis_rx_tvalid  (mac_rx_tvalid),
    .m_axis_rx_tlast   (mac_rx_tlast),
    .m_axis_rx_tready  (mac_rx_tready),
    .s_axis_tx_tdata   (mac_tx_tdata),
    .s_axis_tx_tkeep   (mac_tx_tkeep),
    .s_axis_tx_tvalid  (mac_tx_tvalid),
    .s_axis_tx_tlast   (mac_tx_tlast),
    .s_axis_tx_tready  (mac_tx_tready),
    .s_axi_awaddr      (dec_awaddr[SLV_MAC*AW +: 12]),
    .s_axi_awvalid     (dec_awvalid[SLV_MAC]),
    .s_axi_awready     (dec_awready[SLV_MAC]),
    .s_axi_wdata       (dec_wdata[SLV_MAC*32 +: 32]),
    .s_axi_wstrb       (dec_wstrb[SLV_MAC*4 +: 4]),
    .s_axi_wvalid      (dec_wvalid[SLV_MAC]),
    .s_axi_wready      (dec_wready[SLV_MAC]),
    .s_axi_bresp       (dec_bresp[SLV_MAC*2 +: 2]),
    .s_axi_bvalid      (dec_bvalid[SLV_MAC]),
    .s_axi_bready      (dec_bready[SLV_MAC]),
    .s_axi_araddr      (dec_araddr[SLV_MAC*AW +: 12]),
    .s_axi_arvalid     (dec_arvalid[SLV_MAC]),
    .s_axi_arready     (dec_arready[SLV_MAC]),
    .s_axi_rdata       (dec_rdata[SLV_MAC*32 +: 32]),
    .s_axi_rresp       (dec_rresp[SLV_MAC*2 +: 2]),
    .s_axi_rvalid      (dec_rvalid[SLV_MAC]),
    .s_axi_rready      (dec_rready[SLV_MAC]),
    .stat_link_up      (mac_stat_link_up),
    .stat_speed        (mac_stat_speed),
    .stat_rx_clk_ok    (mac_stat_rx_clk_ok),
    .ev_rx_good        (),
    .ev_rx_bad         (),
    .ev_tx_frame       ()
  );

  // PHY management GPIO core: MDC/MDIO through the pad buffer, PHY reset.
  rtlnet_mdio #(
    .CLK_HZ       (CPU_CLK_HZ),
    .POR_RESET_MS (POR_RESET_MS)
  ) u_mdio (
    .clk           (cpu_clk),
    .resetn        (cpu_resetn_sync),
    .s_axi_awaddr  (dec_awaddr[SLV_MDIO*AW +: 12]),
    .s_axi_awvalid (dec_awvalid[SLV_MDIO]),
    .s_axi_awready (dec_awready[SLV_MDIO]),
    .s_axi_wdata   (dec_wdata[SLV_MDIO*32 +: 32]),
    .s_axi_wstrb   (dec_wstrb[SLV_MDIO*4 +: 4]),
    .s_axi_wvalid  (dec_wvalid[SLV_MDIO]),
    .s_axi_wready  (dec_wready[SLV_MDIO]),
    .s_axi_bresp   (dec_bresp[SLV_MDIO*2 +: 2]),
    .s_axi_bvalid  (dec_bvalid[SLV_MDIO]),
    .s_axi_bready  (dec_bready[SLV_MDIO]),
    .s_axi_araddr  (dec_araddr[SLV_MDIO*AW +: 12]),
    .s_axi_arvalid (dec_arvalid[SLV_MDIO]),
    .s_axi_arready (dec_arready[SLV_MDIO]),
    .s_axi_rdata   (dec_rdata[SLV_MDIO*32 +: 32]),
    .s_axi_rresp   (dec_rresp[SLV_MDIO*2 +: 2]),
    .s_axi_rvalid  (dec_rvalid[SLV_MDIO]),
    .s_axi_rready  (dec_rready[SLV_MDIO]),
    .mdc           (eth_mdc),
    .mdio_o        (mdio_o),
    .mdio_t        (mdio_t),
    .mdio_i        (mdio_i),
    .phy_rst_n     (phy_rst_n),
    .phy_int_n     (eth_int_b),
    .irq           (mdio_irq)
  );

  // Protocol wrapper with its leaves (ARP, ICMP, DHCP, iperf, UDP sockets).
  rtlnet_eth_protocol #(
    .PROTO_CLK_HZ    (PROTO_CLK_HZ),
    .INGRESS_FIFO_KB (16),
    .EGRESS_FIFO_KB  (8),
    .ARP_ENABLE      (1),
    .ICMP_ENABLE     (1),
    .DHCP_ENABLE     (1),
    .IPERF_ENABLE    (1),
    .UDP_ENABLE      (1),
    .ICMP_BUF_KB     (2),
    .DHCP_BUF_KB     (1),
    .IPERF_PORT      (5001),
    .NUM_SOCKETS     (4),
    .UDP_RX_BUF_KB   (16),
    .UDP_TX_BUF_KB   (8),
    .CPU_PATH_ENABLE (1),
    .CPU_RX_FIFO_KB  (32),            // holds the open TCP windows of several lwIP connections
    .CPU_TX_FIFO_KB  (8),
    // CPU-path classifier (cores/rtlnet_classifier, registers at protocol sub-map 0x8000): drop-all
    // until the firmware configures it (broadcast storm limiter at boot).
    .CPU_CLASSIFIER_ENABLE (1),
    // CPU-path checksum offload (cores/rtlnet_tcp_offload, registers at protocol sub-map 0x9000): inserts the
    // IPv4/TCP/UDP checksums of CPU transmit frames, appends a checksum trailer to CPU receive frames; power-up
    // CTRL 0 is a pass-through.
    .CPU_TCP_OFFLOAD_ENABLE (1),
    // Receive batching and ACK coalescing on the CPU receive stream (cores/rtlnet_tcp_offload): the firmware
    // enables them through CTRL.rx_batch / CTRL.ack_coalesce (power-up 0 = plain trailer stream). Ethernet demo only.
    .CPU_TCP_OFFLOAD_ACK_COALESCE (1),
    .CPU_TCP_OFFLOAD_RX_BATCH     (1),
    .CPU_TCP_OFFLOAD_ACK_FLOWS    (4),
    .CPU_AXIS_CLK_HZ (CPU_CLK_HZ),
    .RAM_STYLE       ("block")
  ) u_protocol (
    .axis_clk          (axis_clk),
    .proto_clk         (proto_clk),
    .app_clk           (proto_clk),
    .s_axi_aclk        (cpu_clk),
    .axis_resetn       (axis_resetn),
    .proto_resetn      (proto_resetn),
    .app_resetn        (proto_resetn),
    .s_axi_aresetn     (cpu_resetn_sync),
    .s_axis_tdata      (mac_rx_tdata),
    .s_axis_tkeep      (mac_rx_tkeep),
    .s_axis_tvalid     (mac_rx_tvalid),
    .s_axis_tlast      (mac_rx_tlast),
    .s_axis_tready     (mac_rx_tready),
    .m_axis_tdata      (mac_tx_tdata),
    .m_axis_tkeep      (mac_tx_tkeep),
    .m_axis_tvalid     (mac_tx_tvalid),
    .m_axis_tlast      (mac_tx_tlast),
    .m_axis_tready     (mac_tx_tready),
    .m_axis_app_tdata  (app_rx_tdata),
    .m_axis_app_tkeep  (app_rx_tkeep),
    .m_axis_app_tvalid (app_rx_tvalid),
    .m_axis_app_tlast  (app_rx_tlast),
    .m_axis_app_tready (app_rx_tready),
    .s_axis_app_tdata  (app_tx_tdata),
    .s_axis_app_tkeep  (app_tx_tkeep),
    .s_axis_app_tvalid (app_tx_tvalid),
    .s_axis_app_tlast  (app_tx_tlast),
    .s_axis_app_tready (app_tx_tready),
    .s_axi_awaddr      (dec_awaddr[SLV_PROT*AW +: 16]),
    .s_axi_awvalid     (dec_awvalid[SLV_PROT]),
    .s_axi_awready     (dec_awready[SLV_PROT]),
    .s_axi_wdata       (dec_wdata[SLV_PROT*32 +: 32]),
    .s_axi_wstrb       (dec_wstrb[SLV_PROT*4 +: 4]),
    .s_axi_wvalid      (dec_wvalid[SLV_PROT]),
    .s_axi_wready      (dec_wready[SLV_PROT]),
    .s_axi_bresp       (dec_bresp[SLV_PROT*2 +: 2]),
    .s_axi_bvalid      (dec_bvalid[SLV_PROT]),
    .s_axi_bready      (dec_bready[SLV_PROT]),
    .s_axi_araddr      (dec_araddr[SLV_PROT*AW +: 16]),
    .s_axi_arvalid     (dec_arvalid[SLV_PROT]),
    .s_axi_arready     (dec_arready[SLV_PROT]),
    .s_axi_rdata       (dec_rdata[SLV_PROT*32 +: 32]),
    .s_axi_rresp       (dec_rresp[SLV_PROT*2 +: 2]),
    .s_axi_rvalid      (dec_rvalid[SLV_PROT]),
    .s_axi_rready      (dec_rready[SLV_PROT]),
    .cpu_axis_clk           (cpu_clk),
    .cpu_axis_resetn        (cpu_resetn_sync),
    .m_axis_cpu_eth_tdata   (cpu_eth_rx_tdata),
    .m_axis_cpu_eth_tkeep   (cpu_eth_rx_tkeep),
    .m_axis_cpu_eth_tvalid  (cpu_eth_rx_tvalid),
    .m_axis_cpu_eth_tlast   (cpu_eth_rx_tlast),
    .m_axis_cpu_eth_tready  (cpu_eth_rx_tready),
    .s_axis_cpu_eth_tdata   (cpu_eth_tx_tdata),
    .s_axis_cpu_eth_tkeep   (cpu_eth_tx_tkeep),
    .s_axis_cpu_eth_tvalid  (cpu_eth_tx_tvalid),
    .s_axis_cpu_eth_tlast   (cpu_eth_tx_tlast),
    .s_axis_cpu_eth_tready  (cpu_eth_tx_tready),
    .stat_ip_valid     (prot_stat_ip_valid),
    .stat_dhcp_bound   (prot_stat_dhcp_bound),
    .ev_rx_frame       (),
    .ev_tx_frame       ()
  );

  // UDP echo application on the socket payload streams (app_clk = proto_clk).
  rtlnet_udp_echo u_echo (
    .app_clk       (proto_clk),
    .app_resetn    (proto_resetn),
    .s_axi_aclk    (cpu_clk),
    .s_axi_aresetn (cpu_resetn_sync),
    .s_axis_tdata  (app_rx_tdata),
    .s_axis_tkeep  (app_rx_tkeep),
    .s_axis_tvalid (app_rx_tvalid),
    .s_axis_tlast  (app_rx_tlast),
    .s_axis_tready (app_rx_tready),
    .m_axis_tdata  (app_tx_tdata),
    .m_axis_tkeep  (app_tx_tkeep),
    .m_axis_tvalid (app_tx_tvalid),
    .m_axis_tlast  (app_tx_tlast),
    .m_axis_tready (app_tx_tready),
    .s_axi_awaddr  (dec_awaddr[SLV_ECHO*AW +: 12]),
    .s_axi_awvalid (dec_awvalid[SLV_ECHO]),
    .s_axi_awready (dec_awready[SLV_ECHO]),
    .s_axi_wdata   (dec_wdata[SLV_ECHO*32 +: 32]),
    .s_axi_wstrb   (dec_wstrb[SLV_ECHO*4 +: 4]),
    .s_axi_wvalid  (dec_wvalid[SLV_ECHO]),
    .s_axi_wready  (dec_wready[SLV_ECHO]),
    .s_axi_bresp   (dec_bresp[SLV_ECHO*2 +: 2]),
    .s_axi_bvalid  (dec_bvalid[SLV_ECHO]),
    .s_axi_bready  (dec_bready[SLV_ECHO]),
    .s_axi_araddr  (dec_araddr[SLV_ECHO*AW +: 12]),
    .s_axi_arvalid (dec_arvalid[SLV_ECHO]),
    .s_axi_arready (dec_arready[SLV_ECHO]),
    .s_axi_rdata   (dec_rdata[SLV_ECHO*32 +: 32]),
    .s_axi_rresp   (dec_rresp[SLV_ECHO*2 +: 2]),
    .s_axi_rvalid  (dec_rvalid[SLV_ECHO]),
    .s_axi_rready  (dec_rready[SLV_ECHO])
  );

  assign cpu_irq    = {7'd0, mdio_irq};   // irq[0] MDIO (INTC input 0)
  assign net_status = {prot_stat_dhcp_bound, prot_stat_ip_valid, mac_stat_rx_clk_ok, mac_stat_speed, mac_stat_link_up};
  assign eth_rst_b  = phy_rst_n;

endmodule
