// -----------------------------------------------------------------------------
// File: rtlnet_arty_a7_100_eth_top.sv
// Purpose: the Arty A7-100T Ethernet demo top: 10/100 Mb/s Ethernet (Clause 22 MII, TI DP83848J) with the RTLNet network
//   cores and a small MicroBlaze V CPU running DHCP, ARP, ping, UDP and lwIP TCP. The same firmware source as the Nexys Video
//   Ethernet demo serves this board. No DDR3, no camera, no video and no H.264: pins, one MMCM and its global buffers, the
//   reset tree, the Ethernet CPU core rtlnet_cpu_eth, the RTLNet AXI4-Lite address decoder, the board-independent system
//   registers, the PHY MDIO pad buffer, the 25 MHz PHY reference clock output and the network cores.
// Overview:
//   * Clocks: MMCME2_ADV u_mmcm, 100 MHz in, VCO 1000 MHz; CLKOUT0 cpu_clk (BUFG u_bufg_cpu, CPU_CLK_HZ = 100 MHz) is the ONE
//     system clock: MAC client side, protocol filter, protocol leaves, UDP echo, checksum offload, CPU, LMB, AXI DMA, AXI4-Lite and
//     every register (axis_clk = proto_clk = cpu_clk, one reset release). CLKOUT1 clk25 (BUFG u_bufg_clk25, 25 MHz) drives the ODDR
//     u_ref_oddr that forwards the PHY reference clock on eth_ref_clk (ball G18, the DP83848 X1 input). The only other clocks are
//     the PHY's own MII receive and transmit clocks (25 MHz at 100 Mb/s, 2.5 MHz at 10 Mb/s) inside u_mac. No 125/200 MHz clock and
//     no IDELAYCTRL.
//   * Resets: one assertion, rst_arstn = cpu_resetn (ck_rst button, low = pressed) AND mmcm_locked, enters rtlnet_reset_sync on
//     cpu_clk. Either input low asserts every domain at once; release needs rst_arstn high for STAGES consecutive clocks.
//   * PHY reference clock before PHY reset release: the reset logic of every core, including rtlnet_mdio and with it eth_rstn, stays
//     asserted until the MMCM has locked, so clk25 runs from before the first release; rtlnet_mdio then keeps eth_rstn low for
//     POR_RESET_MS milliseconds of running clock. The DP83848 needs a stable 25 MHz clock for 167 ms after power-up before its
//     strap options are valid and before the first MDC access (datasheet T2.1.1, T2.1.2): POR_RESET_MS defaults to 200. The board's
//     10 kOhm pull-up on ETH_RSTN lets the PHY out of reset during FPGA configuration, without a clock; the later reset
//     pulse of this top corrects that.
//   * CPU core u_cpu (rtlnet_cpu_eth; with RTLNET_CPU_ETH_SIM_STUB defined, the simulation stub rtlnet_cpu_eth_sim_stub with the
//     same ports, for the board bench) masters u_decoder (rtlnet_axil_decoder) over the RTLNet window 0x44A0_0000, the same map as
//     the Nexys Video top: SYS 0x44A0_0000, MAC 0x44A0_1000, MDIO 0x44A0_2000, ECHO 0x44A0_3000, PROTOCOL 0x44A1_0000 (64 KiB).
//   * Network path: u_mac (rtlnet_eth_mac_mii) <-> u_protocol (rtlnet_eth_protocol) <-> u_echo (rtlnet_udp_echo); the CPU network
//     path joins the CPU core's AXI DMA streams to the protocol wrapper's CPU-path ports on cpu_clk.
//   * PHY: the board top owns the eth_mdio IOBUF; rtlnet_mdio drives MDC, MDIO and the PHY reset. The PHY has no interrupt
//     pin on the FPGA (the board routes none): phy_int_n is tied inactive. The MDIO address is found by the firmware's scan
//     (the manual says 1, the schematic straps read differently); nothing here depends on it.
//   * CPU-path classifier (rtlnet_classifier) stays enabled with the protection profile; its tables are distributed RAM
//     (CLS_RAM_STYLE "distributed", small profile) so that it costs no block RAM tile.
//   * Board facts for the firmware: BOARD_ID (ASCII "ARTY"), CPU_CLK_HZ and LINK_CAPS (10 and 100 Mb/s full duplex) are
//     parameters of u_sysregs. NUM_LED 4, NUM_SW 4, NUM_BTN 4.
//   * LEDs: led[0] clocks locked, led[3:1] system-register bits (led[1] firmware heartbeat by convention, led[2] link,
//     led[3] DHCP lease). The PHY's own LEDs are not routed to the FPGA.
//   * MMCM, BUFG, ODDR and IOBUF primitives appear in this file only (the MII clock buffers are in rtlnet_mii_clkbuf).
// Language: SystemVerilog-2012.
// Revision: 11-14-2026
//   * 11-14-2026: initial version.
// Clocks: sysclk (100 MHz pin) -> MMCM -> cpu_clk (system clock), clk25 (PHY reference output); eth_rx_clk and eth_tx_clk are
//   PHY outputs.
// Pins: names, balls and I/O standards from the Digilent Arty-A7-100-Master.xdc (Rev. D/E); constraints in
//   boards/arty_a7_100/constraints/rtlnet_arty_a7_100_eth.xdc.
// -----------------------------------------------------------------------------
module rtlnet_arty_a7_100_eth_top #(
  parameter logic [31:0] BUILD_ID     = 32'h0000_0000,  // git hash (build script: git rev-parse --short=8 HEAD)
  parameter logic        BUILD_DIRTY  = 1'b0,           // build tree had uncommitted changes
  parameter int          CPU_CLK_HZ   = 100_000_000,    // system clock = MMCM CLKOUT0 = 1000 MHz / (1000 MHz / CPU_CLK_HZ);
                                                        // the build script passes the rate to the block design
  parameter int          MS_CYCLES    = 0,              // cpu_clk clocks per millisecond; 0 = CPU_CLK_HZ / 1000 (bench may shorten)
  parameter int          POR_RESET_MS = 200             // PHY reset hold after reset release (DP83848 strap latch needs 167 ms of clock)
)(
  // System clock: 100 MHz oscillator, ball E3, net CLK100MHZ, bank 35 (3.3 V),
  // LVCMOS33, MRCC input; feeds only the MMCM.
  input  logic       sysclk,

  // RESET push button ck_rst: ball C2, bank 35 (3.3 V), LVCMOS33; low while
  // pressed, asynchronous.
  input  logic       cpu_resetn,

  // USB-UART bridge (FT2232HQ), bank 16 (3.3 V), LVCMOS33, 115200 8N1, names from
  // the bridge's point of view: uart_tx_in ball A9 (bridge TXD -> FPGA receive,
  // asynchronous, idle high); uart_rx_out ball D10 (FPGA transmit -> bridge RXD).
  input  logic       uart_tx_in,
  output logic       uart_rx_out,

  // User LEDs LD4..LD7 (the XDC names them led[0..3]), banks 35/14 (3.3 V),
  // LVCMOS33, active high: led[0] H5, [1] J5, [2] T9, [3] T10.
  output logic [3:0] led,

  // Slide switches SW0..SW3, bank 16 (3.3 V), LVCMOS33, asynchronous levels:
  // sw[0] A8, [1] C11, [2] C10, [3] A10.
  input  logic [3:0] sw,

  // Push buttons BTN0..BTN3, bank 16 (3.3 V), LVCMOS33, high while pressed,
  // asynchronous: btn[0] D9, [1] C9, [2] B9, [3] B8.
  input  logic [3:0] btn,

  // DP83848J MII receive (PHY -> FPGA), bank 15 (3.3 V), LVCMOS33:
  // eth_rx_clk F15 (SRCC, receive clock 25/2.5 MHz), eth_rx_dv G16, eth_rxerr C17,
  // eth_rxd[0] D18, [1] E17, [2] E18, [3] G17. COL (D17) and CRS (G14) are PHY
  // strap pins and unused by the full-duplex MAC: not ports of this top.
  input  logic       eth_rx_clk,
  input  logic       eth_rx_dv,
  input  logic       eth_rxerr,
  input  logic [3:0] eth_rxd,

  // DP83848J MII transmit (FPGA -> PHY), bank 15 (3.3 V), LVCMOS33:
  // eth_tx_clk H16 (MRCC, transmit clock FROM the PHY, 25/2.5 MHz), eth_tx_en H15,
  // eth_txd[0] H14, [1] J14, [2] J13, [3] H17.
  input  logic       eth_tx_clk,
  output logic       eth_tx_en,
  output logic [3:0] eth_txd,

  // DP83848J management, bank 15 (3.3 V), LVCMOS33: eth_mdc F16 (FPGA -> PHY
  // clock), eth_mdio K13 (bidirectional, 1.5 kOhm pull-up on the board; the
  // IOBUF below is its only driver).
  output logic       eth_mdc,
  inout  wire        eth_mdio,

  // PHY reset (active low, ball C16, 10 kOhm pull-up on the board, safe level low =
  // PHY held in reset) and the 25 MHz reference clock the FPGA supplies to the
  // PHY's X1 input (ball G18).
  output logic       eth_rstn,
  output logic       eth_ref_clk
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam int          SYS_CLK_HZ   = CPU_CLK_HZ;   // rate of cpu_clk (CPU, registers, protocol, MAC client side)
  localparam int          CPU_CLK_DIV  = 1_000_000_000 / SYS_CLK_HZ;
  localparam int          MS_CLKS      = (MS_CYCLES == 0) ? (SYS_CLK_HZ / 1000) : MS_CYCLES;
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
  localparam logic [31:0] BOARD_ID     = 32'h4152_5459;  // "ARTY"
  localparam logic [2:0]  LINK_CAPS    = 3'b011;         // 10 and 100 Mb/s, full duplex
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
    if (CPU_CLK_DIV * SYS_CLK_HZ != 1_000_000_000) begin : g_bad_cpu_clk
      $fatal(1, "rtlnet_arty_a7_100_eth_top: CPU_CLK_HZ=%0d is not 1000 MHz / an integer", CPU_CLK_HZ);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic clkfb;
  logic clkfb_bufg;
  logic cpu_clk_mmcm;
  logic clk25_mmcm;
  logic clk25;                 // 25 MHz: PHY reference clock source (ODDR only)
  logic cpu_clk;               // the system clock: CPU, AXI4-Lite, registers, MDIO, protocol, MAC client side
  logic mmcm_locked;
  logic rst_arstn;
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
  logic [3:0]  led_fw;
  logic        tick_ms;
  logic [5:0]  net_status;
  logic        mdio_o;
  logic        mdio_t;
  logic        mdio_i;
  logic        phy_rst_n;
  logic        phy_int_n;

  // Clock generation: one MMCM, VCO = 100 MHz x 10 = 1000 MHz.
  // CLKOUT0 /CPU_CLK_DIV = cpu_clk (100 MHz), CLKOUT1 /40 = 25 MHz PHY reference.
  // RST tied low: the oscillator runs before configuration ends, and the button resets logic, not the MMCM.
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
    .CLKOUT0_DIVIDE_F     (real'(CPU_CLK_DIV)),
    .CLKOUT0_PHASE        (0.000),
    .CLKOUT0_DUTY_CYCLE   (0.500),
    .CLKOUT0_USE_FINE_PS  ("FALSE"),
    .CLKOUT1_DIVIDE       (40),
    .CLKOUT1_PHASE        (0.000),
    .CLKOUT1_DUTY_CYCLE   (0.500),
    .CLKOUT1_USE_FINE_PS  ("FALSE")
  ) u_mmcm (
    .CLKIN1       (sysclk),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clkfb_bufg),
    .CLKFBOUT     (clkfb),
    .CLKFBOUTB    (),
    .CLKOUT0      (cpu_clk_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (clk25_mmcm),
    .CLKOUT1B     (),
    .CLKOUT2      (),
    .CLKOUT2B     (),
    .CLKOUT3      (),
    .CLKOUT3B     (),
    .CLKOUT4      (),
    .CLKOUT5      (),
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

  // Global clock buffers: feedback, system clock, PHY reference source.
  BUFG u_bufg_fb    (.I(clkfb),         .O(clkfb_bufg));
  BUFG u_bufg_cpu   (.I(cpu_clk_mmcm),  .O(cpu_clk));
  BUFG u_bufg_clk25 (.I(clk25_mmcm),    .O(clk25));

  // PHY reference clock out: the DDR output register forwards the 25 MHz clock (D1 = 1, D2 = 0), the standard clock-forwarding
  // structure. The PHY needs 25 MHz +-50 ppm on X1; the MMCM runs from the 100 MHz oscillator.
  ODDR #(
    .DDR_CLK_EDGE ("SAME_EDGE"),
    .INIT         (1'b0),
    .SRTYPE       ("SYNC")
  ) u_ref_oddr (
    .Q  (eth_ref_clk),
    .C  (clk25),
    .CE (1'b1),
    .D1 (1'b1),
    .D2 (1'b0),
    .R  (1'b0),
    .S  (1'b0)
  );

  // The one reset assertion: button pressed or MMCM not locked.
  assign rst_arstn = cpu_resetn & mmcm_locked;

  // One system clock, one reset release: the MAC client side, protocol filter and leaves and the CPU share it.
  rtlnet_reset_sync u_rst_cpu (.clk(cpu_clk), .arstn(rst_arstn), .resetn(cpu_resetn_sync));

  // ---------------------------------------------------------------------------
  // CPU core
  // ---------------------------------------------------------------------------
`ifdef RTLNET_CPU_ETH_SIM_STUB
  // Board bench: simulation stub in place of the processor.
  rtlnet_cpu_eth_sim_stub #(
    .CLK_HZ (SYS_CLK_HZ)
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
    .CPU_CLK_HZ  (SYS_CLK_HZ),
    .MS_CYCLES   (MS_CLKS),
    .LINK_CAPS   (LINK_CAPS),
    .NUM_LED     (4),
    .NUM_SW      (4),
    .NUM_BTN     (4)
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
    .btn_async         (btn),
    .clk_locked_async  (mmcm_locked),
    .phy_async         ({mdio_i, phy_int_n}),
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

  // LEDs: lock indicator on led[0], firmware bits on led[3:1].
  assign led = {led_fw[3:1], mmcm_locked};

  // The board routes no PHY interrupt to the FPGA: the active-low input reads inactive.
  assign phy_int_n = 1'b1;

  // ---------------------------------------------------------------------------
  // Network cores: MAC, MDIO, protocol wrapper, UDP echo
  // ---------------------------------------------------------------------------

  // 10/100 Mb/s MII MAC (Clause 22, full duplex): both PHY clocks come from the DP83848; the client and register side runs on
  // cpu_clk. FIFOs trimmed to 4 KiB each (a 100 Mb/s link, 1518-byte frames).
  rtlnet_eth_mac_mii #(
    .RX_FIFO_KB      (4),
    .TX_FIFO_KB      (4),
    .MAX_FRAME_BYTES (1518),
    .AXIS_CLK_HZ     (SYS_CLK_HZ),
    .RAM_STYLE       ("block")
  ) u_mac (
    .axis_clk          (cpu_clk),
    .s_axi_aclk        (cpu_clk),
    .axis_resetn       (cpu_resetn_sync),
    .s_axi_aresetn     (cpu_resetn_sync),
    .mii_rx_clk        (eth_rx_clk),
    .mii_tx_clk        (eth_tx_clk),
    .mii_rxd           (eth_rxd),
    .mii_rx_dv         (eth_rx_dv),
    .mii_rx_er         (eth_rxerr),
    .mii_txd           (eth_txd),
    .mii_tx_en         (eth_tx_en),
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
    .CLK_HZ       (SYS_CLK_HZ),
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
    .phy_int_n     (phy_int_n),
    .irq           (mdio_irq)
  );

  // Protocol wrapper with its leaves (ARP, ICMP, DHCP, iperf, UDP sockets). Memory trimmed for the xc7a100t (135 RAMB36):
  // the classifier stays, with distributed RAM and the small profile of the firmware (8 table entries, 8 tuple entries, 1 rule,
  // 4 policers); the FIFOs are sized for a 100 Mb/s link.
  rtlnet_eth_protocol #(
    .PROTO_CLK_HZ    (SYS_CLK_HZ),
    .INGRESS_FIFO_KB (8),
    .EGRESS_FIFO_KB  (4),
    .ARP_ENABLE      (1),
    .ICMP_ENABLE     (1),
    .DHCP_ENABLE     (1),
    .IPERF_ENABLE    (1),
    .UDP_ENABLE      (1),
    .ICMP_BUF_KB     (1),
    .DHCP_BUF_KB     (1),
    .IPERF_PORT      (5001),
    .NUM_SOCKETS     (4),
    .UDP_RX_BUF_KB   (8),
    .UDP_TX_BUF_KB   (4),
    .CPU_PATH_ENABLE (1),
    .CPU_RX_FIFO_KB  (16),            // open TCP windows of the small-memory firmware profile (4 x MSS per connection)
    .CPU_TX_FIFO_KB  (4),
    // CPU-path classifier (cores/rtlnet_classifier, registers at protocol sub-map 0x8000): drop-all until the firmware
    // configures it. Always enabled; distributed RAM and the small profile cost no block RAM tile.
    .CPU_CLASSIFIER_ENABLE (1),
    .CLS_TABLE_ENTRIES     (8),
    .CLS_TUPLE_ENTRIES     (8),
    .CLS_TABLE_LANES       (2),
    .CLS_NUM_RULES         (1),
    .CLS_NUM_POLICERS      (4),
    .CLS_MATCH_DEPTH_BYTES (64),
    .CLS_RAM_STYLE         ("distributed"),
    // CPU-path checksum offload (cores/rtlnet_tcp_offload, registers at protocol sub-map 0x9000): inserts the
    // IPv4/TCP/UDP checksums of CPU transmit frames, appends a checksum trailer to CPU receive frames; power-up
    // CTRL 0 is a pass-through.
    .CPU_TCP_OFFLOAD_ENABLE (1),
    .CPU_TCP_OFFLOAD_ACK_COALESCE (1),
    .CPU_TCP_OFFLOAD_RX_BATCH     (1),
    .CPU_TCP_OFFLOAD_ACK_FLOWS    (4),
    .CPU_AXIS_CLK_HZ (SYS_CLK_HZ),
    .RAM_STYLE       ("block")
  ) u_protocol (
    .axis_clk          (cpu_clk),
    .proto_clk         (cpu_clk),
    .app_clk           (cpu_clk),
    .s_axi_aclk        (cpu_clk),
    .axis_resetn       (cpu_resetn_sync),
    .proto_resetn      (cpu_resetn_sync),
    .app_resetn        (cpu_resetn_sync),
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

  // UDP echo application on the socket payload streams.
  rtlnet_udp_echo u_echo (
    .app_clk       (cpu_clk),
    .app_resetn    (cpu_resetn_sync),
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
  assign eth_rstn   = phy_rst_n;

endmodule
