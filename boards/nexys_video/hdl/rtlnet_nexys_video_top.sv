// -----------------------------------------------------------------------------
// File: rtlnet_nexys_video_top.sv
// Purpose: the Nexys Video board top ("Top.sv") of RTLNet: pins, the one
//   MMCM and its global buffers, the reset tree, the CPU core, the RTLNet
//   AXI4-Lite address decoder, the board system registers, the PHY MDIO pad
//   buffer and, with RTLNET_WITH_NETWORK defined, the network cores.
// Overview:
//   * Clocks (architecture section 9): MMCME2_ADV u_mmcm, 100 MHz in, VCO
//     1000 MHz; CLKOUT0 clk125, CLKOUT1 clk125_90 (90 deg), CLKOUT2 clk200,
//     CLKOUT3 axis_clk 62.5 MHz, CLKOUT4 proto_clk 50 MHz, CLKOUT5 cpu_clk
//     100 MHz, each on a BUFG; feedback through BUFG u_bufg_fb.
//   * Resets: one assertion, rst_arstn = cpu_resetn (button, low = pressed)
//     AND mmcm_locked, enters one rtlnet_reset_sync per clock. Glitch argument
//     for the AND: either input low asserts every domain at once (safe in any
//     order); release needs rst_arstn high for STAGES consecutive clocks of
//     each domain, so a short high glitch cannot release a domain.
//     app_clk = proto_clk, app_resetn = proto_resetn.
//   * CPU core u_cpu (rtlnet_cpu_microblaze; with RTLNET_MICROBLAZE_SIM_STUB defined, the
//     simulation stub rtlnet_microblaze_sim_stub with the same ports, for the board
//     bench) masters u_decoder (rtlnet_axil_decoder) over the RTLNet window
//     0x44A0_0000 (architecture section 6.1):
//       slave 0 SYS        0x44A0_0000   4 KiB  u_sysregs
//       slave 1 MAC        0x44A0_1000   4 KiB  u_mac       (stub without network)
//       slave 2 MDIO       0x44A0_2000   4 KiB  u_mdio      (stub without network)
//       slave 3 ECHO       0x44A0_3000   4 KiB  u_echo      (stub without network)
//       slave 4 PROTOCOL   0x44A1_0000  64 KiB  u_protocol  (stub without network)
//       slave 5 CLASSIFIER 0x44A2_0000   4 KiB  reserved: always the stub
//     A stub answers every access OKAY with read data 0, so firmware probing a
//     core's ID reads 0 ("not present"); other addresses get DECERR.
//   * PHY: the board top owns the eth_mdio IOBUF. Without the network cores
//     the MDIO pad is released, MDC is low, the RGMII outputs are idle and
//     eth_rst_b is released POR_RESET_MS milliseconds after cpu_clk reset
//     release (a register output), so the PHY runs and links. With the network
//     cores rtlnet_mdio drives MDC, MDIO and the PHY reset.
//   * CPU network path (cpu_axis_ethernet_stream, architecture 7.4): the CPU
//     core's AXI DMA streams m_axis_eth_* / s_axis_eth_* (cpu_clk) connect to
//     the protocol wrapper's s_axis_cpu_eth_* / m_axis_cpu_eth_* with
//     cpu_axis_clk = cpu_clk and cpu_axis_resetn = the cpu_clk reset. Without
//     the network cores the CPU receive stream is idle and every frame the CPU
//     sends is accepted and discarded (tready held 1), so a DMA transmit
//     completes on either bitstream.
//   * LEDs: led[0] MMCM locked, led[7:1] system-register bits (led[1] is the
//     firmware heartbeat by convention).
//   * MMCM, BUFG and IOBUF primitives appear in this file only.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: CPU network path between u_cpu and u_protocol.
// Clocks: sysclk (100 MHz pin) -> MMCM; clk125, clk125_90, clk200, axis_clk,
//   proto_clk, cpu_clk as above; the MAC's receive clock is internal to it.
// Pins: names, balls, banks and I/O standards from the Digilent
//   Nexys-Video-Master.xdc (Rev. A); constraints in
//   boards/nexys_video/constraints/rtlnet_nexys_video.xdc.
// -----------------------------------------------------------------------------
module rtlnet_nexys_video_top #(
  parameter logic [31:0] BUILD_ID     = 32'h0000_0000,  // git hash (build script: git rev-parse --short=8 HEAD)
  parameter logic        BUILD_DIRTY  = 1'b0,           // build tree had uncommitted changes
  parameter int          MS_CYCLES    = 100_000,        // cpu_clk clocks per millisecond (bench may shorten)
  parameter int          POR_RESET_MS = 20              // PHY reset hold after reset release, CPU-only build
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

  // RTL8211E reset and side band: eth_rst_b U7 (bank 34, 3.3 V, LVCMOS33,
  // active low, safe level low = PHY held in reset); eth_int_b Y14 and
  // eth_pme_b W14 (bank 13, 2.5 V, LVCMOS25, active low, asynchronous).
  output logic       eth_rst_b,
  input  logic       eth_int_b,
  input  logic       eth_pme_b
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam int          CPU_CLK_HZ   = 100_000_000;
  localparam int          PROTO_CLK_HZ = 50_000_000;
  localparam int          NUM_SLV      = 6;
  localparam int          AW           = 32;
  localparam int          SLV_SYS      = 0;
  localparam int          SLV_MAC      = 1;
  localparam int          SLV_MDIO     = 2;
  localparam int          SLV_ECHO     = 3;
  localparam int          SLV_PROT     = 4;
  localparam int          SLV_CLS      = 5;
  localparam logic [31:0] RTLNET_BASE  = 32'h44A0_0000;
  localparam logic [31:0] WIN_4K       = 32'h0000_1000;
  localparam logic [31:0] WIN_64K      = 32'h0001_0000;
  // Slave i at [i*AW +: AW]; listed highest index first.
  localparam logic [NUM_SLV*AW-1:0] SLAVE_BASE = {
    RTLNET_BASE + 32'h0002_0000,    // 5 CLASSIFIER (reserved)
    RTLNET_BASE + 32'h0001_0000,    // 4 PROTOCOL
    RTLNET_BASE + 32'h0000_3000,    // 3 ECHO
    RTLNET_BASE + 32'h0000_2000,    // 2 MDIO
    RTLNET_BASE + 32'h0000_1000,    // 1 MAC
    RTLNET_BASE + 32'h0000_0000     // 0 SYS
  };
  localparam logic [NUM_SLV*AW-1:0] SLAVE_SIZE = {WIN_4K, WIN_64K, WIN_4K, WIN_4K, WIN_4K, WIN_4K};
`ifdef RTLNET_WITH_NETWORK
  localparam logic        NETWORK      = 1'b1;
  localparam logic [NUM_SLV-1:0] STUB_MASK = 6'b10_0000;   // classifier only
`else
  localparam logic        NETWORK      = 1'b0;
  localparam logic [NUM_SLV-1:0] STUB_MASK = 6'b11_1110;   // every window but SYS
`endif

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
  logic cpu_clk;               // 100 MHz: CPU, decoder, MDIO, system registers
  logic mmcm_locked;
  logic rst_arstn;
  logic clk125_resetn;
  logic clk125_90_resetn;
  logic clk200_resetn;
  logic axis_resetn;
  logic proto_resetn;
  logic cpu_resetn_sync;

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

  // CPU network path (cpu_clk): eth_tx = frames the CPU sends, eth_rx =
  // frames to the CPU.
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
  // Board status, PHY pins
  // ---------------------------------------------------------------------------
  logic [7:0]  led_fw;
  logic        tick_ms;
  logic [4:0]  clk_beacon;
  logic [5:0]  net_status;
  logic [5:0]  rgmii_rx_levels;
  logic        mdio_o;
  logic        mdio_t;
  logic        mdio_i;
  logic        phy_rst_n;

  // Clock generation: one MMCM, VCO = 100 MHz x 10 = 1000 MHz.
  // CLKOUT0 /8 = 125 MHz, CLKOUT1 /8 at 90 deg (2 ns) = 125 MHz,
  // CLKOUT2 /5 = 200 MHz, CLKOUT3 /16 = 62.5 MHz, CLKOUT4 /20 = 50 MHz,
  // CLKOUT5 /10 = 100 MHz. RST tied low: the oscillator runs before
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
    .CLKOUT5_DIVIDE       (10),
    .CLKOUT5_PHASE        (0.000),
    .CLKOUT5_DUTY_CYCLE   (0.500),
    .CLKOUT5_USE_FINE_PS  ("FALSE"),
    .CLKOUT6_DIVIDE       (10),
    .CLKOUT6_PHASE        (0.000),
    .CLKOUT6_DUTY_CYCLE   (0.500),
    .CLKOUT6_USE_FINE_PS  ("FALSE")
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

  // Global clock buffers: feedback and the six fabric clocks.
  BUFG u_bufg_fb        (.I(clkfb),          .O(clkfb_bufg));
  BUFG u_bufg_clk125    (.I(clk125_mmcm),    .O(clk125));
  BUFG u_bufg_clk125_90 (.I(clk125_90_mmcm), .O(clk125_90));
  BUFG u_bufg_clk200    (.I(clk200_mmcm),    .O(clk200));
  BUFG u_bufg_axis      (.I(axis_clk_mmcm),  .O(axis_clk));
  BUFG u_bufg_proto     (.I(proto_clk_mmcm), .O(proto_clk));
  BUFG u_bufg_cpu       (.I(cpu_clk_mmcm),   .O(cpu_clk));

  // The one reset assertion: button pressed or MMCM not locked.
  assign rst_arstn = cpu_resetn & mmcm_locked;

  // Reset release into clk125.
  rtlnet_reset_sync u_rst_clk125 (.clk(clk125), .arstn(rst_arstn), .resetn(clk125_resetn));

  // Reset release into clk125_90 (its clock beacon only; the MAC uses clk125_resetn).
  rtlnet_reset_sync u_rst_clk125_90 (.clk(clk125_90), .arstn(rst_arstn), .resetn(clk125_90_resetn));

  // Reset release into clk200.
  rtlnet_reset_sync u_rst_clk200 (.clk(clk200), .arstn(rst_arstn), .resetn(clk200_resetn));

  // Reset release into axis_clk.
  rtlnet_reset_sync u_rst_axis (.clk(axis_clk), .arstn(rst_arstn), .resetn(axis_resetn));

  // Reset release into proto_clk (also app_clk).
  rtlnet_reset_sync u_rst_proto (.clk(proto_clk), .arstn(rst_arstn), .resetn(proto_resetn));

  // Reset release into cpu_clk.
  rtlnet_reset_sync u_rst_cpu (.clk(cpu_clk), .arstn(rst_arstn), .resetn(cpu_resetn_sync));

  // Clock beacons for the system-register clock monitor, one per MMCM output
  // other than cpu_clk (the measuring clock).
  rtlnet_nexys_video_clk_beacon u_beacon_clk125 (
    .clk(clk125), .resetn(clk125_resetn), .beacon(clk_beacon[0]));
  rtlnet_nexys_video_clk_beacon u_beacon_clk125_90 (
    .clk(clk125_90), .resetn(clk125_90_resetn), .beacon(clk_beacon[1]));
  rtlnet_nexys_video_clk_beacon u_beacon_clk200 (
    .clk(clk200), .resetn(clk200_resetn), .beacon(clk_beacon[2]));
  rtlnet_nexys_video_clk_beacon u_beacon_axis (
    .clk(axis_clk), .resetn(axis_resetn), .beacon(clk_beacon[3]));
  rtlnet_nexys_video_clk_beacon u_beacon_proto (
    .clk(proto_clk), .resetn(proto_resetn), .beacon(clk_beacon[4]));

  // ---------------------------------------------------------------------------
  // CPU core
  // ---------------------------------------------------------------------------
`ifdef RTLNET_MICROBLAZE_SIM_STUB
  // Board bench: simulation stub in place of the processor.
  rtlnet_microblaze_sim_stub u_cpu (
`else
  // MicroBlaze subsystem: console on the USB-UART, register master into the
  // decoder, interrupts from the cores.
  rtlnet_cpu_microblaze u_cpu (
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

  // Board system registers (window SYS).
  rtlnet_nexys_video_sysregs #(
    .BUILD_ID    (BUILD_ID),
    .BUILD_DIRTY (BUILD_DIRTY),
    .NETWORK     (NETWORK),
    .CPU_CLK_HZ  (CPU_CLK_HZ),
    .MS_CYCLES   (MS_CYCLES),
    .NUM_CLK     (5)
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
    .mmcm_locked_async (mmcm_locked),
    .phy_async         ({mdio_i, eth_pme_b, eth_int_b}),
    .rgmii_rx_async    (rgmii_rx_levels),
    .phy_rst_n         (phy_rst_n),
    .net_status_async  (net_status),
    .clk_beacon_async  (clk_beacon),
    .led_fw            (led_fw),
    .tick_ms           (tick_ms)
  );

  // Stub windows: OKAY, read data 0, writes ignored (cores not in this build,
  // and the reserved classifier window).
  genvar gs;
  generate
    for (gs = 1; gs < NUM_SLV; gs++) begin : g_stub
      if (STUB_MASK[gs]) begin : g_on
        logic        stub_wr_en;
        logic [11:0] stub_wr_addr;
        logic [31:0] stub_wr_data;
        logic        stub_rd_en;
        logic [11:0] stub_rd_addr;

        // Empty window: the shared slave bridge with a constant-zero register file.
        rtlnet_axil_slave #(
          .ADDR_W (12)
        ) u_stub (
          .s_axi_aclk    (cpu_clk),
          .s_axi_aresetn (cpu_resetn_sync),
          .s_axi_awaddr  (dec_awaddr[gs*AW +: 12]),
          .s_axi_awvalid (dec_awvalid[gs]),
          .s_axi_awready (dec_awready[gs]),
          .s_axi_wdata   (dec_wdata[gs*32 +: 32]),
          .s_axi_wstrb   (dec_wstrb[gs*4 +: 4]),
          .s_axi_wvalid  (dec_wvalid[gs]),
          .s_axi_wready  (dec_wready[gs]),
          .s_axi_bresp   (dec_bresp[gs*2 +: 2]),
          .s_axi_bvalid  (dec_bvalid[gs]),
          .s_axi_bready  (dec_bready[gs]),
          .s_axi_araddr  (dec_araddr[gs*AW +: 12]),
          .s_axi_arvalid (dec_arvalid[gs]),
          .s_axi_arready (dec_arready[gs]),
          .s_axi_rdata   (dec_rdata[gs*32 +: 32]),
          .s_axi_rresp   (dec_rresp[gs*2 +: 2]),
          .s_axi_rvalid  (dec_rvalid[gs]),
          .s_axi_rready  (dec_rready[gs]),
          .reg_wr_en     (stub_wr_en),
          .reg_wr_addr   (stub_wr_addr),
          .reg_wr_data   (stub_wr_data),
          .reg_rd_en     (stub_rd_en),
          .reg_rd_addr   (stub_rd_addr),
          .reg_rd_data   (32'd0)
        );
      end
    end
  endgenerate

  // MDIO pad: the only driver of eth_mdio; mdio_t = 1 releases the line.
  IOBUF u_mdio_iobuf (
    .I  (mdio_o),
    .T  (mdio_t),
    .O  (mdio_i),
    .IO (eth_mdio)
  );

  // LEDs: lock indicator on led[0], firmware bits on led[7:1].
  assign led = {led_fw[7:1], mmcm_locked};

`ifdef RTLNET_WITH_NETWORK
  // ---------------------------------------------------------------------------
  // Network build: MAC, MDIO, protocol wrapper, UDP echo (architecture 15.1-15.5)
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

  assign cpu_irq         = {7'd0, mdio_irq};
  assign net_status      = {prot_stat_dhcp_bound, prot_stat_ip_valid, mac_stat_rx_clk_ok,
                            mac_stat_speed, mac_stat_link_up};
  assign rgmii_rx_levels = 6'd0;
  assign eth_rst_b       = phy_rst_n;

`else
  // ---------------------------------------------------------------------------
  // CPU-only build: PHY pins idle, PHY released after the power-on delay.
  // ---------------------------------------------------------------------------
  localparam int POR_W = $clog2(POR_RESET_MS + 1);

  logic [POR_W-1:0] por_ms;

  // PHY power-on reset: hold eth_rst_b low POR_RESET_MS milliseconds after
  // cpu_clk reset release, then release it (register output to the pin).
  always_ff @(posedge cpu_clk) begin
    if (!cpu_resetn_sync) begin
      por_ms    <= '0;
      phy_rst_n <= 1'b0;
    end else if (tick_ms) begin
      if (por_ms == POR_W'(POR_RESET_MS)) begin
        phy_rst_n <= 1'b1;
      end else begin
        por_ms <= por_ms + 1'b1;
      end
    end
  end

  assign cpu_irq           = 8'd0;
  assign net_status        = 6'd0;
  // CPU network path without the protocol wrapper: no frames to the CPU;
  // frames from the CPU are accepted and discarded.
  assign cpu_eth_rx_tdata  = 64'd0;
  assign cpu_eth_rx_tkeep  = 8'd0;
  assign cpu_eth_rx_tvalid = 1'b0;
  assign cpu_eth_rx_tlast  = 1'b0;
  assign cpu_eth_tx_tready = 1'b1;
  assign rgmii_rx_levels = {eth_rxck, eth_rxd, eth_rxctl};
  assign eth_rst_b       = phy_rst_n;
  assign eth_mdc         = 1'b0;
  assign mdio_o          = 1'b1;
  assign mdio_t          = 1'b1;
  assign eth_txck        = 1'b0;
  assign eth_txctl       = 1'b0;
  assign eth_txd         = 4'd0;
`endif

endmodule
