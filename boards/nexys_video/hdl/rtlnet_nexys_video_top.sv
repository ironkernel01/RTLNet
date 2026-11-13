// -----------------------------------------------------------------------------
// File: rtlnet_nexys_video_top.sv
// Purpose: the Nexys Video board top ("Top.sv") of RTLNet: pins, the one
//   MMCM and its global buffers, the reset tree, the CPU core, the RTLNet
//   AXI4-Lite address decoder, the board system registers, the PHY MDIO pad
//   buffer and, with RTLNET_WITH_NETWORK defined, the network cores.
// Overview:
//   * Clocks (architecture section 9): MMCME2_ADV u_mmcm, 100 MHz in, VCO
//     1000 MHz; CLKOUT0 clk125, CLKOUT1 clk125_90 (90 deg), CLKOUT2 clk200,
//     CLKOUT3 axis_clk 62.5 MHz, CLKOUT4 proto_clk 50 MHz, each on a BUFG; feedback through BUFG u_bufg_fb. A second MMCME2_ADV
//     u_mmcm2 (same input, VCO 100 MHz / 5 x 36 = 720 MHz, CLKOUT0 /7) makes the MIG's input clock, exactly 102.857 MHz (the memory
//     controller at a 2778 ps memory clock needs a 9723 ps input period; its PLL multiplies by 14 to 1440 MHz). The memory
//     controller's 4:1 user clock ui_clk is then exactly 1440 / 16 = 90.000 MHz and is the one system clock: CPU (ui_clk is ui_clk),
//     AXI4-Lite, DDR3 arbiter and all its masters, frame buffer, video DMA, bar generator, H.264 engines, system registers.
//   * DDR3 (cores/rtlnet_ddr, cores/rtlnet_axi_arbiter): u_ddr is the MIG memory
//     controller (512 MiB, 128-bit AXI4 on ui_clk 90 MHz) with sys_clk = MMCM2
//     CLKOUT0 (102.857 MHz, BUFG u_bufg_ddrsys; MIG "No Buffer") and ref_clk = clk200.
//     (The sysclk pad net directly into the MIG PLL is rejected by the placer,
//     Place 30-172: the clock-capable pin and the PLL are not a legal pair.) The CPU's M_AXI_DDR (caches, 0x8000_0000, ui_clk = ui_clk) goes
//     directly into u_arb (rtlnet_axi_arbiter, master 0) and u_ddr; the arbiter's
//     registers are decoder slave 6. The ui_clk reset ddr_resetn is an
//     rtlnet_reset_sync (clk ui_clk) of rst_arstn, ANDed with the MIG ui reset after the chain;
//     init_calib_complete enters the system registers through rtlnet_sync.
//   * Video path (ui_clk): u_csi2 (rtlnet_csi2_rx) sends 720p30 or 1080p30 color bars (the camera
//     stream input is tied off, valid 0) into u_s2mm (rtlnet_vdma_s2mm), which writes each frame into a slot granted by u_fb
//     (rtlnet_framebuf, 3 slots of 4 MiB at DDR3 offset 0x1000_0000, CPU address 0x9000_0000) through arbiter master 1 (fixed top
//     priority: HIGH_PRIO_MASK 2'b10); master 0 stays the CPU caches (NARROW_MASK and WRAP_MASK bit 0). The framebuf reader port
//     is tied off in Phase 1; the firmware reads the latest slot through the framebuf register window. The three register
//     windows cross from ui_clk to ui_clk inside each core (rtlnet_axil_cdc).
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
//       slave 6 ARBITER    0x44A0_4000   4 KiB  u_arb       (DDR3 arbiter)
//       slave 7 CSI2       0x44A0_5000   4 KiB  u_csi2      (color bars, source switch; camera stubbed)
//       slave 8 S2MM       0x44A0_6000   4 KiB  u_s2mm      (video write DMA, arbiter master 1)
//       slave 9 FRAMEBUF   0x44A0_7000   4 KiB  u_fb        (tear-free frame buffer, 3 slots at DDR3 offset 0x1000_0000)
//     A stub answers every access OKAY with read data 0, so firmware probing a
//     core's ID reads 0 ("not present"); other addresses get DECERR.
//   * PHY: the board top owns the eth_mdio IOBUF. Without the network cores
//     the MDIO pad is released, MDC is low, the RGMII outputs are idle and
//     eth_rst_b is released POR_RESET_MS milliseconds after ui_clk reset
//     release (a register output), so the PHY runs and links. With the network
//     cores rtlnet_mdio drives MDC, MDIO and the PHY reset.
//   * CPU network path (cpu_axis_ethernet_stream, architecture 7.4): the CPU
//     core's AXI DMA streams m_axis_eth_* / s_axis_eth_* (ui_clk) connect to
//     the protocol wrapper's s_axis_cpu_eth_* / m_axis_cpu_eth_* with
//     cpu_axis_clk = ui_clk and cpu_axis_resetn = the ui_clk reset. Without
//     the network cores the CPU receive stream is idle and every frame the CPU
//     sends is accepted and discarded (tready held 1), so a DMA transmit
//     completes on either bitstream.
//   * LEDs: led[0] MMCM locked, led[7:1] system-register bits (led[1] is the
//     firmware heartbeat by convention).
//   * MMCM, BUFG and IOBUF primitives appear in this file only (the MIG clocking is inside its IP).
// Language: SystemVerilog-2012.
// Revision: 11-12-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: CPU network path between u_cpu and u_protocol.
//   * 11-09-2026: DDR3 memory controller, AXI4 arbiter (decoder slave 6), CPU DDR3 master, DDR3 pins,
//     calibration status into the system registers.
//   * 11-09-2026: u_ddr_cdc (rtlnet_axi_cdc) between the CPU DDR3 master (ui_clk) and the arbiter (ui_clk).
//   * 11-09-2026: the MIG ui reset is ANDed after the ui_clk reset chain (no LUT on the chain's asynchronous pin).
//   * 11-09-2026: u_arb WRAP_MASK 1 (the CPU caches' WRAP line fills are legal).
//   * 11-09-2026: Phase 1 video path: u_csi2, u_s2mm, u_fb (decoder slaves 7 to 9), the arbiter takes a second master.
//   * 11-09-2026: one system clock, ui_clk = 90.000 MHz (MIG at 2778 ps, input from u_mmcm2 at 102.857 MHz); ui_clk is ui_clk, the
//     CPU reset is the ui_clk reset ddr_resetn, u_ddr_cdc and the encoder bridges are gone, the register windows of the cores on ui_clk
//     run without a clock crossing (AXIL_SYNC 1).
//   * 11-09-2026: Phase 2b-3: u_h264 (rtlnet_h264_top, decoder slave 10, 0x44A0_8000), two engine masters on the arbiter (masters 2 and 3),
//     the MIG project's AXI ID width goes from 2 to 4 bits (arbiter ID_W 2 + IDX_W 2).
//   * 11-12-2026: the encoder's irq output goes to the CPU interrupt input irq[1] (cpu_irq = {6'd0, h264_irq, mdio_irq}).
// Clocks: sysclk (100 MHz pin) -> MMCM and MMCM2 (-> MIG PLL); clk125, clk125_90, clk200, axis_clk,
//   proto_clk as above; ui_clk (MIG user clock, 90 MHz) = ui_clk; the MAC's
//   receive clock is internal to it.
// Pins: names, balls, banks and I/O standards from the Digilent
//   Nexys-Video-Master.xdc (Rev. A); constraints in
//   boards/nexys_video/constraints/rtlnet_nexys_video.xdc.
// -----------------------------------------------------------------------------
module rtlnet_nexys_video_top #(
  parameter logic [31:0] BUILD_ID     = 32'h0000_0000,  // git hash (build script: git rev-parse --short=8 HEAD)
  parameter logic        BUILD_DIRTY  = 1'b0,           // build tree had uncommitted changes
  parameter bit          HIGH_PROFILE = 1'b0,           // 0 = CAVLC Baseline encoder; 1 = add the High profile netlist (CABAC entropy coding), build.ps1 -HighProfile
  parameter bit          HP_T8        = 1'b1,           // only with HIGH_PROFILE = 1: 1 = include the 8x8 transform; 0 = leave it out (build.ps1 -HpTools cabac)
  parameter bit          HP_T8_AUTO   = 1'b1,           // only with HP_T8 = 1: 1 = include the per-macroblock 4x4 / 8x8 choice; 0 = leave it out (build.ps1 -HpTools cabac|t8)
  parameter int          MS_CYCLES    = 90_000,         // ui_clk clocks per millisecond (bench may shorten)
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
  input  logic       eth_pme_b,

  // DDR3 SDRAM MT41K256M16 (16 bit, one rank), banks 34 and 35 (1.5 V), SSTL15
  // (differential strobes and clock DIFF_SSTL15), balls and properties from the MIG
  // project (cores/rtlnet_ddr/ip/rtlnet_ddr_mig.prj) in the board XDC.
  inout  wire  [15:0] ddr3_dq,
  inout  wire  [1:0]  ddr3_dqs_n,
  inout  wire  [1:0]  ddr3_dqs_p,
  output logic [14:0] ddr3_addr,
  output logic [2:0]  ddr3_ba,
  output logic        ddr3_ras_n,
  output logic        ddr3_cas_n,
  output logic        ddr3_we_n,
  output logic        ddr3_reset_n,
  output logic [0:0]  ddr3_ck_p,
  output logic [0:0]  ddr3_ck_n,
  output logic [0:0]  ddr3_cke,
  output logic [1:0]  ddr3_dm,
  output logic [0:0]  ddr3_odt
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam int          CPU_CLK_HZ   = 90_000_000;
  localparam int          PROTO_CLK_HZ = 50_000_000;
  localparam int          NUM_SLV      = 11;
  localparam int          AW           = 32;
  localparam int          SLV_SYS      = 0;
  localparam int          SLV_MAC      = 1;
  localparam int          SLV_MDIO     = 2;
  localparam int          SLV_ECHO     = 3;
  localparam int          SLV_PROT     = 4;
  localparam int          SLV_CLS      = 5;
  localparam int          SLV_ARB      = 6;
  localparam int          SLV_CSI2     = 7;
  localparam int          SLV_S2MM     = 8;
  localparam int          SLV_FB       = 9;
  localparam int          SLV_H264     = 10;
  localparam logic [31:0] FB_BASE_OFF  = 32'h1000_0000;     // DDR3 byte offset of frame-buffer slot 0
  localparam int          FB_SLOT_LOG2 = 22;                // 4 MiB per slot
  localparam int          DDR_ADDR_W   = 29;           // 512 MiB
  localparam int          DDR_DATA_W   = 128;
  localparam int          ARB_ID_W     = 2;            // slave-side ID width: the encoder's write master tells its ring, index and picture writes apart by bid[1:0]
  localparam int          DDR_ID_W     = ARB_ID_W + 2; // arbiter memory-side ID (IDX_W = 2 for four masters)
  localparam logic [31:0] RTLNET_BASE  = 32'h44A0_0000;
  localparam logic [31:0] WIN_4K       = 32'h0000_1000;
  localparam logic [31:0] WIN_64K      = 32'h0001_0000;
  // Slave i at [i*AW +: AW]; listed highest index first.
  localparam logic [NUM_SLV*AW-1:0] SLAVE_BASE = {
    RTLNET_BASE + 32'h0000_8000,    // 10 H264
    RTLNET_BASE + 32'h0000_7000,    // 9 FRAMEBUF
    RTLNET_BASE + 32'h0000_6000,    // 8 S2MM
    RTLNET_BASE + 32'h0000_5000,    // 7 CSI2
    RTLNET_BASE + 32'h0000_4000,    // 6 ARBITER
    RTLNET_BASE + 32'h0002_0000,    // 5 CLASSIFIER (reserved)
    RTLNET_BASE + 32'h0001_0000,    // 4 PROTOCOL
    RTLNET_BASE + 32'h0000_3000,    // 3 ECHO
    RTLNET_BASE + 32'h0000_2000,    // 2 MDIO
    RTLNET_BASE + 32'h0000_1000,    // 1 MAC
    RTLNET_BASE + 32'h0000_0000     // 0 SYS
  };
  localparam logic [NUM_SLV*AW-1:0] SLAVE_SIZE = {WIN_4K, WIN_4K, WIN_4K, WIN_4K, WIN_4K, WIN_4K, WIN_64K, WIN_4K, WIN_4K, WIN_4K, WIN_4K};
`ifdef RTLNET_WITH_NETWORK
  localparam logic        NETWORK      = 1'b1;
  localparam logic [NUM_SLV-1:0] STUB_MASK = 11'b000_0010_0000;   // classifier only
`else
  localparam logic        NETWORK      = 1'b0;
  localparam logic [NUM_SLV-1:0] STUB_MASK = 11'b000_0011_1110;   // every window but SYS, ARBITER, the video cores and the encoder
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
  logic clkfb2;
  logic clkfb2_bufg;
  logic mmcm1_locked;
  logic mmcm2_locked;
  logic ddr_sys_clk_mmcm;
  logic ddr_sys_clk;           // 102.857 MHz: MIG PLL input (MMCM2 CLKOUT0)
  logic clk125;                // 125 MHz, 0 deg: MAC transmit, RXC rate detector
  logic clk125_90;             // 125 MHz, 90 deg: RGMII TXC forwarding only
  logic clk200;                // 200 MHz: IDELAYCTRL reference
  logic axis_clk;              // 62.5 MHz: MAC client side, protocol filter
  logic proto_clk;             // 50 MHz: protocol leaves, UDP echo (app_clk)
  logic mmcm_locked;
  logic rst_arstn;
  logic clk125_resetn;
  logic clk125_90_resetn;
  logic clk200_resetn;
  logic axis_resetn;
  logic proto_resetn;
  logic ui_clk;                // 90 MHz: MIG user clock, the system clock
  logic ui_resetn_mig;         // MIG ui reset, active low, synchronous to ui_clk
  logic ddr_resetn_sync;       // ui_clk reset chain of rst_arstn, released synchronously
  logic ddr_resetn;            // ui_clk reset: ddr_resetn_sync and the MIG ui reset
  logic ddr_calib;             // init_calib_complete, ui_clk domain

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

  // CPU DDR3 master (ui_clk domain, 128-bit, no IDs) and the arbiter's memory side.
  logic [31:0]           cpu_ddr_awaddr;
  logic [7:0]            cpu_ddr_awlen;
  logic [2:0]            cpu_ddr_awsize;
  logic [1:0]            cpu_ddr_awburst;
  logic                  cpu_ddr_awlock;
  logic [3:0]            cpu_ddr_awcache;
  logic [2:0]            cpu_ddr_awprot;
  logic [3:0]            cpu_ddr_awqos;
  logic                  cpu_ddr_awvalid;
  logic                  cpu_ddr_awready;
  logic [127:0]          cpu_ddr_wdata;
  logic [15:0]           cpu_ddr_wstrb;
  logic                  cpu_ddr_wlast;
  logic                  cpu_ddr_wvalid;
  logic                  cpu_ddr_wready;
  logic [1:0]            cpu_ddr_bresp;
  logic                  cpu_ddr_bvalid;
  logic                  cpu_ddr_bready;
  logic [31:0]           cpu_ddr_araddr;
  logic [7:0]            cpu_ddr_arlen;
  logic [2:0]            cpu_ddr_arsize;
  logic [1:0]            cpu_ddr_arburst;
  logic                  cpu_ddr_arlock;
  logic [3:0]            cpu_ddr_arcache;
  logic [2:0]            cpu_ddr_arprot;
  logic [3:0]            cpu_ddr_arqos;
  logic                  cpu_ddr_arvalid;
  logic                  cpu_ddr_arready;
  logic [127:0]          cpu_ddr_rdata;
  logic [1:0]            cpu_ddr_rresp;
  logic                  cpu_ddr_rlast;
  logic                  cpu_ddr_rvalid;
  logic                  cpu_ddr_rready;

  // The CPU's DDR3 port as the arbiter's slave port 0 (ui_clk, ID width ARB_ID_W).
  logic [ARB_ID_W-1:0]   br_awid;
  logic [DDR_ADDR_W-1:0] br_awaddr;
  logic [7:0]            br_awlen;
  logic [2:0]            br_awsize;
  logic [1:0]            br_awburst;
  logic                  br_awvalid;
  logic                  br_awready;
  logic [DDR_DATA_W-1:0] br_wdata;
  logic [DDR_DATA_W/8-1:0] br_wstrb;
  logic                  br_wlast;
  logic                  br_wvalid;
  logic                  br_wready;
  logic [ARB_ID_W-1:0]   br_bid;
  logic [1:0]            br_bresp;
  logic                  br_bvalid;
  logic                  br_bready;
  logic [ARB_ID_W-1:0]   br_arid;
  logic [DDR_ADDR_W-1:0] br_araddr;
  logic [7:0]            br_arlen;
  logic [2:0]            br_arsize;
  logic [1:0]            br_arburst;
  logic                  br_arvalid;
  logic                  br_arready;
  logic [ARB_ID_W-1:0]   br_rid;
  logic [DDR_DATA_W-1:0] br_rdata;
  logic [1:0]            br_rresp;
  logic                  br_rlast;
  logic                  br_rvalid;
  logic                  br_rready;

  logic [DDR_ID_W-1:0]   mem_awid;
  logic [DDR_ADDR_W-1:0] mem_awaddr;
  logic [7:0]            mem_awlen;
  logic [2:0]            mem_awsize;
  logic [1:0]            mem_awburst;
  logic                  mem_awlock;
  logic [3:0]            mem_awcache;
  logic [2:0]            mem_awprot;
  logic [3:0]            mem_awqos;
  logic                  mem_awvalid;
  logic                  mem_awready;
  logic [DDR_DATA_W-1:0] mem_wdata;
  logic [DDR_DATA_W/8-1:0] mem_wstrb;
  logic                  mem_wlast;
  logic                  mem_wvalid;
  logic                  mem_wready;
  logic [DDR_ID_W-1:0]   mem_bid;
  logic [1:0]            mem_bresp;
  logic                  mem_bvalid;
  logic                  mem_bready;
  logic [DDR_ID_W-1:0]   mem_arid;
  logic [DDR_ADDR_W-1:0] mem_araddr;
  logic [7:0]            mem_arlen;
  logic [2:0]            mem_arsize;
  logic [1:0]            mem_arburst;
  logic                  mem_arlock;
  logic [3:0]            mem_arcache;
  logic [2:0]            mem_arprot;
  logic [3:0]            mem_arqos;
  logic                  mem_arvalid;
  logic                  mem_arready;
  logic [DDR_ID_W-1:0]   mem_rid;
  logic [DDR_DATA_W-1:0] mem_rdata;
  logic [1:0]            mem_rresp;
  logic                  mem_rlast;
  logic                  mem_rvalid;
  logic                  mem_rready;

  // Video path (ui_clk): csi2_rx -> s2mm stream with its sideband, s2mm <-> framebuf slot interface, s2mm AXI4 write
  // master (arbiter master 1).
  logic [31:0]           vid_tdata;
  logic                  vid_tvalid;
  logic                  vid_tready;
  logic                  vid_tlast;
  logic                  vid_tuser;
  logic [31:0]           vid_frame_num;
  logic [31:0]           vid_timestamp;
  logic [15:0]           vid_width;
  logic [15:0]           vid_height;
  logic                  vid_src_pattern;
  logic                  fb_req;
  logic                  fb_rsp_valid;
  logic                  fb_rsp_ok;
  logic [DDR_ADDR_W-1:0] fb_rsp_base;
  logic                  fb_done;
  logic                  fb_done_good;
  logic [31:0]           fb_done_frame_num;
  logic [31:0]           fb_done_timestamp;
  logic [15:0]           fb_done_width;
  logic [15:0]           fb_done_height;
  logic                  fb_done_src_pattern;
  logic [ARB_ID_W-1:0]   v_awid;
  logic [DDR_ADDR_W-1:0] v_awaddr;
  logic [7:0]            v_awlen;
  logic [2:0]            v_awsize;
  logic [1:0]            v_awburst;
  logic                  v_awvalid;
  logic                  v_awready;
  logic [DDR_DATA_W-1:0] v_wdata;
  logic [DDR_DATA_W/8-1:0] v_wstrb;
  logic                  v_wlast;
  logic                  v_wvalid;
  logic                  v_wready;
  logic [ARB_ID_W-1:0]   v_bid;
  logic [1:0]            v_bresp;
  logic                  v_bvalid;
  logic                  v_bready;
  logic                  v_arready_nc;               // the video master has no read channel
  logic [ARB_ID_W-1:0]   v_rid_nc;
  logic [DDR_DATA_W-1:0] v_rdata_nc;
  logic [1:0]            v_rresp_nc;
  logic                  v_rlast_nc;
  logic                  v_rvalid_nc;
  logic                  cam_tready_nc;
  // H.264 encoder masters. h_*: the two engine masters (engine 0 in the low half, 32-bit addresses); e_*: the same with the
  // arbiter's DDR_ADDR_W-bit address (every encoder buffer lies below 512 MiB, so the upper address bits are zero).
  logic [2*ARB_ID_W-1:0] h_awid;
  logic [2*32-1:0] h_awaddr;
  logic [2*8-1:0] h_awlen;
  logic [2*3-1:0] h_awsize;
  logic [2*2-1:0] h_awburst;
  logic [1:0] h_awvalid;
  logic [1:0] h_awready;
  logic [2*DDR_DATA_W-1:0] h_wdata;
  logic [2*DDR_DATA_W/8-1:0] h_wstrb;
  logic [1:0] h_wlast;
  logic [1:0] h_wvalid;
  logic [1:0] h_wready;
  logic [2*ARB_ID_W-1:0] h_bid;
  logic [2*2-1:0] h_bresp;
  logic [1:0] h_bvalid;
  logic [1:0] h_bready;
  logic [2*ARB_ID_W-1:0] h_arid;
  logic [2*32-1:0] h_araddr;
  logic [2*8-1:0] h_arlen;
  logic [2*3-1:0] h_arsize;
  logic [2*2-1:0] h_arburst;
  logic [1:0] h_arvalid;
  logic [1:0] h_arready;
  logic [2*DDR_DATA_W-1:0] h_rdata;
  logic [2*2-1:0] h_rresp;
  logic [1:0] h_rlast;
  logic [1:0] h_rvalid;
  logic [1:0] h_rready;
  logic [2*ARB_ID_W-1:0] e_awid;
  logic [2*DDR_ADDR_W-1:0] e_awaddr;
  logic [2*8-1:0] e_awlen;
  logic [2*3-1:0] e_awsize;
  logic [2*2-1:0] e_awburst;
  logic [1:0] e_awvalid;
  logic [1:0] e_awready;
  logic [2*DDR_DATA_W-1:0] e_wdata;
  logic [2*DDR_DATA_W/8-1:0] e_wstrb;
  logic [1:0] e_wlast;
  logic [1:0] e_wvalid;
  logic [1:0] e_wready;
  logic [2*ARB_ID_W-1:0] e_bid;
  logic [2*2-1:0] e_bresp;
  logic [1:0] e_bvalid;
  logic [1:0] e_bready;
  logic [2*ARB_ID_W-1:0] e_arid;
  logic [2*DDR_ADDR_W-1:0] e_araddr;
  logic [2*8-1:0] e_arlen;
  logic [2*3-1:0] e_arsize;
  logic [2*2-1:0] e_arburst;
  logic [1:0] e_arvalid;
  logic [1:0] e_arready;
  logic [2*DDR_DATA_W-1:0] e_rdata;
  logic [2*ARB_ID_W-1:0] e_rid;
  logic [2*2-1:0] e_rresp;
  logic [1:0] e_rlast;
  logic [1:0] e_rvalid;
  logic [1:0] e_rready;
  logic                    h264_irq;       // rtlnet_h264_top irq: level, ui_clk, CPU interrupt input irq[1] (INTC input RTLNET_CPU_IRQ_H264)

  // CPU network path (ui_clk): eth_tx = frames the CPU sends, eth_rx =
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
    .CLKOUT5      (),
    .CLKOUT6      (),
    .LOCKED       (mmcm1_locked),
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


  // Second MMCM: the memory controller's input clock, exactly 102.857142 MHz = 100 MHz x 36 / 5 / 7 (VCO 720 MHz). The controller
  // at a 2778 ps memory clock requires a 9723 ps input period (102.848 MHz); its PLL multiplies by 14 (VCO 1440 MHz), CLKOUT1 /4 gives the
  // 360 MHz memory clock and CLKOUT3 /16 the 90.000 MHz ui_clk. One MMCM at VCO 1000 MHz cannot make this input (integer output dividers
  // above CLKOUT0, and CLKOUT0 is the 125 MHz clock).
  MMCME2_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .COMPENSATION         ("ZHOLD"),
    .STARTUP_WAIT         ("FALSE"),
    .DIVCLK_DIVIDE        (5),
    .CLKFBOUT_MULT_F      (36.000),
    .CLKFBOUT_PHASE       (0.000),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKIN1_PERIOD        (10.000),
    .CLKIN2_PERIOD        (10.000),
    .REF_JITTER1          (0.010),
    .REF_JITTER2          (0.010),
    .CLKOUT4_CASCADE      ("FALSE"),
    .CLKOUT0_DIVIDE_F     (7.000),
    .CLKOUT0_PHASE        (0.000),
    .CLKOUT0_DUTY_CYCLE   (0.500),
    .CLKOUT0_USE_FINE_PS  ("FALSE")
  ) u_mmcm2 (
    .CLKIN1       (sysclk),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .CLKFBIN      (clkfb2_bufg),
    .CLKFBOUT     (clkfb2),
    .CLKFBOUTB    (),
    .CLKOUT0      (ddr_sys_clk_mmcm),
    .CLKOUT0B     (),
    .CLKOUT1      (),
    .CLKOUT1B     (),
    .CLKOUT2      (),
    .CLKOUT2B     (),
    .CLKOUT3      (),
    .CLKOUT3B     (),
    .CLKOUT4      (),
    .CLKOUT5      (),
    .CLKOUT6      (),
    .LOCKED       (mmcm2_locked),
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

  assign mmcm_locked = mmcm1_locked & mmcm2_locked;

  // Global clock buffers: feedbacks and the fabric clocks.
  BUFG u_bufg_fb        (.I(clkfb),          .O(clkfb_bufg));
  BUFG u_bufg_clk125    (.I(clk125_mmcm),    .O(clk125));
  BUFG u_bufg_clk125_90 (.I(clk125_90_mmcm), .O(clk125_90));
  BUFG u_bufg_clk200    (.I(clk200_mmcm),    .O(clk200));
  BUFG u_bufg_axis      (.I(axis_clk_mmcm),  .O(axis_clk));
  BUFG u_bufg_proto     (.I(proto_clk_mmcm), .O(proto_clk));
  BUFG u_bufg_fb2       (.I(clkfb2),         .O(clkfb2_bufg));
  BUFG u_bufg_ddrsys    (.I(ddr_sys_clk_mmcm), .O(ddr_sys_clk));

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

  // Reset release into ui_clk: the board reset assertion enters the chain (no logic on the
  // asynchronous pin); the MIG ui reset (low while the controller clock tree is unlocked, a
  // ui_clk flop output) is ANDed into the released, synchronous reset. Either low asserts every
  // ui_clk register; release needs the chain released and the MIG reset released.
  rtlnet_reset_sync u_rst_ddr (.clk(ui_clk), .arstn(rst_arstn), .resetn(ddr_resetn_sync));
  assign ddr_resetn = ddr_resetn_sync & ui_resetn_mig;

  // There is no separate CPU clock: the CPU, the decoder, MDIO and the system registers run on ui_clk, and their reset is the ui_clk reset
  // ddr_resetn (released after the MIG PLL locks, before the DDR3 calibration completes; the firmware waits for CLK_STATUS.DDR_CALIB before
  // it touches DDR3, and the controller holds every access until it is ready). 
  // Clock beacons for the system-register clock monitor, one per MMCM output
  // other than ui_clk (the measuring clock).
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
    .clk           (ui_clk),
    .resetn        (ddr_resetn),
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
    .m_axi_ddr_awaddr  (cpu_ddr_awaddr),
    .m_axi_ddr_awlen   (cpu_ddr_awlen),
    .m_axi_ddr_awsize  (cpu_ddr_awsize),
    .m_axi_ddr_awburst (cpu_ddr_awburst),
    .m_axi_ddr_awlock  (cpu_ddr_awlock),
    .m_axi_ddr_awcache (cpu_ddr_awcache),
    .m_axi_ddr_awprot  (cpu_ddr_awprot),
    .m_axi_ddr_awqos   (cpu_ddr_awqos),
    .m_axi_ddr_awvalid (cpu_ddr_awvalid),
    .m_axi_ddr_awready (cpu_ddr_awready),
    .m_axi_ddr_wdata   (cpu_ddr_wdata),
    .m_axi_ddr_wstrb   (cpu_ddr_wstrb),
    .m_axi_ddr_wlast   (cpu_ddr_wlast),
    .m_axi_ddr_wvalid  (cpu_ddr_wvalid),
    .m_axi_ddr_wready  (cpu_ddr_wready),
    .m_axi_ddr_bresp   (cpu_ddr_bresp),
    .m_axi_ddr_bvalid  (cpu_ddr_bvalid),
    .m_axi_ddr_bready  (cpu_ddr_bready),
    .m_axi_ddr_araddr  (cpu_ddr_araddr),
    .m_axi_ddr_arlen   (cpu_ddr_arlen),
    .m_axi_ddr_arsize  (cpu_ddr_arsize),
    .m_axi_ddr_arburst (cpu_ddr_arburst),
    .m_axi_ddr_arlock  (cpu_ddr_arlock),
    .m_axi_ddr_arcache (cpu_ddr_arcache),
    .m_axi_ddr_arprot  (cpu_ddr_arprot),
    .m_axi_ddr_arqos   (cpu_ddr_arqos),
    .m_axi_ddr_arvalid (cpu_ddr_arvalid),
    .m_axi_ddr_arready (cpu_ddr_arready),
    .m_axi_ddr_rdata   (cpu_ddr_rdata),
    .m_axi_ddr_rresp   (cpu_ddr_rresp),
    .m_axi_ddr_rlast   (cpu_ddr_rlast),
    .m_axi_ddr_rvalid  (cpu_ddr_rvalid),
    .m_axi_ddr_rready  (cpu_ddr_rready),
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
    .aclk          (ui_clk),
    .aresetn       (ddr_resetn),
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
    .clk               (ui_clk),
    .resetn            (ddr_resetn),
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
    .ddr_calib_async   (ddr_calib),
    .phy_async         ({mdio_i, eth_pme_b, eth_int_b}),
    .rgmii_rx_async    (rgmii_rx_levels),
    .phy_rst_n         (phy_rst_n),
    .net_status_async  (net_status),
    .clk_beacon_async  (clk_beacon),
    .led_fw            (led_fw),
    .tick_ms           (tick_ms)
  );

  // The CPU's M_AXI_DDR (ui_clk) goes straight to arbiter master 0: no clock crossing. The CPU port has no IDs (ID tied 0); bursts
  // are 1 beat (instruction line) and 4 beats (data line fill) with WRAP fills and 32-bit stores (arbiter masks NARROW and WRAP).
  assign br_awid    = {ARB_ID_W{1'b0}};
  assign br_awaddr  = cpu_ddr_awaddr[DDR_ADDR_W-1:0];
  assign br_awlen   = cpu_ddr_awlen;
  assign br_awsize  = cpu_ddr_awsize;
  assign br_awburst = cpu_ddr_awburst;
  assign br_awvalid = cpu_ddr_awvalid;
  assign cpu_ddr_awready = br_awready;
  assign br_wdata   = cpu_ddr_wdata;
  assign br_wstrb   = cpu_ddr_wstrb;
  assign br_wlast   = cpu_ddr_wlast;
  assign br_wvalid  = cpu_ddr_wvalid;
  assign cpu_ddr_wready = br_wready;
  assign cpu_ddr_bresp  = br_bresp;
  assign cpu_ddr_bvalid = br_bvalid;
  assign br_bready  = cpu_ddr_bready;
  assign br_arid    = {ARB_ID_W{1'b0}};
  assign br_araddr  = cpu_ddr_araddr[DDR_ADDR_W-1:0];
  assign br_arlen   = cpu_ddr_arlen;
  assign br_arsize  = cpu_ddr_arsize;
  assign br_arburst = cpu_ddr_arburst;
  assign br_arvalid = cpu_ddr_arvalid;
  assign cpu_ddr_arready = br_arready;
  assign cpu_ddr_rdata   = br_rdata;
  assign cpu_ddr_rresp   = br_rresp;
  assign cpu_ddr_rlast   = br_rlast;
  assign cpu_ddr_rvalid  = br_rvalid;
  assign br_rready  = cpu_ddr_rready;

  // DDR3 memory path. u_arb: master 0 the CPU caches, master 1 the video write DMA u_s2mm (fixed top priority),
  // ui_clk datapath and register file,
  // register port on ui_clk (window ARBITER). The bridge carries a one-bit ID, always 0. The CPU byte address is 0x8000_0000 + offset; the
  // low 29 bits address the 512 MiB.
  rtlnet_axi_arbiter #(
    .AXIL_SYNC       (1'b1),
    .NUM_MASTERS     (4),
    .ADDR_W          (DDR_ADDR_W),
    .DATA_W          (DDR_DATA_W),
    .ID_W            (ARB_ID_W),
    .HIGH_PRIO_MASK  (4'b0010),  // master 1, the video write DMA, wins over the round-robin group (a frame must not stall)
    .NARROW_MASK     (4'b0001),  // master 0: the CPU's write-through data cache issues 32-bit stores
    .WRAP_MASK       (4'b0001),  // master 0: the CPU caches fill critical word first (WRAP bursts of 2..16 beats)
    .MAX_OUTSTANDING (8)
  ) u_arb (
    .clk           (ui_clk),
    .resetn        (ddr_resetn),
    .s_axi_aclk    (ui_clk),
    .s_axi_aresetn (ddr_resetn),
    .s_awid        ({e_awid, v_awid, br_awid}),
    .s_awaddr      ({e_awaddr, v_awaddr, br_awaddr}),
    .s_awlen       ({e_awlen, v_awlen, br_awlen}),
    .s_awsize      ({e_awsize, v_awsize, br_awsize}),
    .s_awburst     ({e_awburst, v_awburst, br_awburst}),
    .s_awvalid     ({e_awvalid, v_awvalid, br_awvalid}),
    .s_awready     ({e_awready, v_awready, br_awready}),
    .s_wdata       ({e_wdata, v_wdata, br_wdata}),
    .s_wstrb       ({e_wstrb, v_wstrb, br_wstrb}),
    .s_wlast       ({e_wlast, v_wlast, br_wlast}),
    .s_wvalid      ({e_wvalid, v_wvalid, br_wvalid}),
    .s_wready      ({e_wready, v_wready, br_wready}),
    .s_bid         ({e_bid, v_bid, br_bid}),
    .s_bresp       ({e_bresp, v_bresp, br_bresp}),
    .s_bvalid      ({e_bvalid, v_bvalid, br_bvalid}),
    .s_bready      ({e_bready, v_bready, br_bready}),
    .s_arid        ({e_arid, {ARB_ID_W{1'b0}}, br_arid}),
    .s_araddr      ({e_araddr, {DDR_ADDR_W{1'b0}}, br_araddr}),
    .s_arlen       ({e_arlen, 8'd0, br_arlen}),
    .s_arsize      ({e_arsize, 3'd4, br_arsize}),
    .s_arburst     ({e_arburst, 2'b01, br_arburst}),
    .s_arvalid     ({e_arvalid, 1'b0, br_arvalid}),
    .s_arready     ({e_arready, v_arready_nc, br_arready}),
    .s_rid         ({e_rid, v_rid_nc, br_rid}),
    .s_rdata       ({e_rdata, v_rdata_nc, br_rdata}),
    .s_rresp       ({e_rresp, v_rresp_nc, br_rresp}),
    .s_rlast       ({e_rlast, v_rlast_nc, br_rlast}),
    .s_rvalid      ({e_rvalid, v_rvalid_nc, br_rvalid}),
    .s_rready      ({e_rready, 1'b1, br_rready}),
    .m_axi_awid    (mem_awid),
    .m_axi_awaddr  (mem_awaddr),
    .m_axi_awlen   (mem_awlen),
    .m_axi_awsize  (mem_awsize),
    .m_axi_awburst (mem_awburst),
    .m_axi_awlock  (mem_awlock),
    .m_axi_awcache (mem_awcache),
    .m_axi_awprot  (mem_awprot),
    .m_axi_awqos   (mem_awqos),
    .m_axi_awvalid (mem_awvalid),
    .m_axi_awready (mem_awready),
    .m_axi_wdata   (mem_wdata),
    .m_axi_wstrb   (mem_wstrb),
    .m_axi_wlast   (mem_wlast),
    .m_axi_wvalid  (mem_wvalid),
    .m_axi_wready  (mem_wready),
    .m_axi_bid     (mem_bid),
    .m_axi_bresp   (mem_bresp),
    .m_axi_bvalid  (mem_bvalid),
    .m_axi_bready  (mem_bready),
    .m_axi_arid    (mem_arid),
    .m_axi_araddr  (mem_araddr),
    .m_axi_arlen   (mem_arlen),
    .m_axi_arsize  (mem_arsize),
    .m_axi_arburst (mem_arburst),
    .m_axi_arlock  (mem_arlock),
    .m_axi_arcache (mem_arcache),
    .m_axi_arprot  (mem_arprot),
    .m_axi_arqos   (mem_arqos),
    .m_axi_arvalid (mem_arvalid),
    .m_axi_arready (mem_arready),
    .m_axi_rid     (mem_rid),
    .m_axi_rdata   (mem_rdata),
    .m_axi_rresp   (mem_rresp),
    .m_axi_rlast   (mem_rlast),
    .m_axi_rvalid  (mem_rvalid),
    .m_axi_rready  (mem_rready),
    .s_axi_awaddr  (dec_awaddr[SLV_ARB*AW +: 12]),
    .s_axi_awvalid (dec_awvalid[SLV_ARB]),
    .s_axi_awready (dec_awready[SLV_ARB]),
    .s_axi_wdata   (dec_wdata[SLV_ARB*32 +: 32]),
    .s_axi_wstrb   (dec_wstrb[SLV_ARB*4 +: 4]),
    .s_axi_wvalid  (dec_wvalid[SLV_ARB]),
    .s_axi_wready  (dec_wready[SLV_ARB]),
    .s_axi_bresp   (dec_bresp[SLV_ARB*2 +: 2]),
    .s_axi_bvalid  (dec_bvalid[SLV_ARB]),
    .s_axi_bready  (dec_bready[SLV_ARB]),
    .s_axi_araddr  (dec_araddr[SLV_ARB*AW +: 12]),
    .s_axi_arvalid (dec_arvalid[SLV_ARB]),
    .s_axi_arready (dec_arready[SLV_ARB]),
    .s_axi_rdata   (dec_rdata[SLV_ARB*32 +: 32]),
    .s_axi_rresp   (dec_rresp[SLV_ARB*2 +: 2]),
    .s_axi_rvalid  (dec_rvalid[SLV_ARB]),
    .s_axi_rready  (dec_rready[SLV_ARB]),
    .err_irq       ()
  );

  // Video path. u_csi2: color bars at 720p30 (reset default) or 1080p30, camera front end not built (stream input tied off,
  // valid 0); u_s2mm: 2D write DMA into the slot u_fb grants; u_fb: three 4 MiB slots at DDR3 offset FB_BASE_OFF. All three run
  // on ui_clk with the ui_clk reset; their AXI4-Lite windows come from ui_clk through the rtlnet_axil_cdc inside each core.
  rtlnet_csi2_rx #(
    .AXIL_SYNC (1'b1)
  ) u_csi2 (
    .clk             (ui_clk),
    .resetn          (ddr_resetn),
    .s_axi_aclk      (ui_clk),
    .s_axi_aresetn   (ddr_resetn),
    .s_cam_tdata     (32'd0),
    .s_cam_tvalid    (1'b0),
    .s_cam_tready    (cam_tready_nc),
    .s_cam_tlast     (1'b0),
    .s_cam_tuser     (1'b0),
    .cam_clk_running (1'b0),
    .m_axis_tdata    (vid_tdata),
    .m_axis_tvalid   (vid_tvalid),
    .m_axis_tready   (vid_tready),
    .m_axis_tlast    (vid_tlast),
    .m_axis_tuser    (vid_tuser),
    .m_frame_num     (vid_frame_num),
    .m_timestamp     (vid_timestamp),
    .m_width         (vid_width),
    .m_height        (vid_height),
    .m_src_pattern   (vid_src_pattern),
    .s_axi_awaddr    (dec_awaddr[SLV_CSI2*AW +: 12]),
    .s_axi_awvalid   (dec_awvalid[SLV_CSI2]),
    .s_axi_awready   (dec_awready[SLV_CSI2]),
    .s_axi_wdata     (dec_wdata[SLV_CSI2*32 +: 32]),
    .s_axi_wstrb     (dec_wstrb[SLV_CSI2*4 +: 4]),
    .s_axi_wvalid    (dec_wvalid[SLV_CSI2]),
    .s_axi_wready    (dec_wready[SLV_CSI2]),
    .s_axi_bresp     (dec_bresp[SLV_CSI2*2 +: 2]),
    .s_axi_bvalid    (dec_bvalid[SLV_CSI2]),
    .s_axi_bready    (dec_bready[SLV_CSI2]),
    .s_axi_araddr    (dec_araddr[SLV_CSI2*AW +: 12]),
    .s_axi_arvalid   (dec_arvalid[SLV_CSI2]),
    .s_axi_arready   (dec_arready[SLV_CSI2]),
    .s_axi_rdata     (dec_rdata[SLV_CSI2*32 +: 32]),
    .s_axi_rresp     (dec_rresp[SLV_CSI2*2 +: 2]),
    .s_axi_rvalid    (dec_rvalid[SLV_CSI2]),
    .s_axi_rready    (dec_rready[SLV_CSI2])
  );

  rtlnet_vdma_s2mm #(
    .AXIL_SYNC       (1'b1),
    .ADDR_W          (DDR_ADDR_W),
    .ID_W            (ARB_ID_W),
    .MAX_BURST_BEATS (16),
    .FIFO_KB         (2),
    .RAM_STYLE       ("block")
  ) u_s2mm (
    .clk                 (ui_clk),
    .resetn              (ddr_resetn),
    .s_axi_aclk          (ui_clk),
    .s_axi_aresetn       (ddr_resetn),
    .s_axis_tdata        (vid_tdata),
    .s_axis_tvalid       (vid_tvalid),
    .s_axis_tready       (vid_tready),
    .s_axis_tlast        (vid_tlast),
    .s_axis_tuser        (vid_tuser),
    .s_width             (vid_width),
    .s_height            (vid_height),
    .s_frame_num         (vid_frame_num),
    .s_timestamp         (vid_timestamp),
    .s_src_pattern       (vid_src_pattern),
    .fb_req              (fb_req),
    .fb_rsp_valid        (fb_rsp_valid),
    .fb_rsp_ok           (fb_rsp_ok),
    .fb_rsp_base         (fb_rsp_base),
    .fb_done             (fb_done),
    .fb_done_good        (fb_done_good),
    .fb_done_frame_num   (fb_done_frame_num),
    .fb_done_timestamp   (fb_done_timestamp),
    .fb_done_width       (fb_done_width),
    .fb_done_height      (fb_done_height),
    .fb_done_src_pattern (fb_done_src_pattern),
    .m_axi_awid          (v_awid),
    .m_axi_awaddr        (v_awaddr),
    .m_axi_awlen         (v_awlen),
    .m_axi_awsize        (v_awsize),
    .m_axi_awburst       (v_awburst),
    .m_axi_awvalid       (v_awvalid),
    .m_axi_awready       (v_awready),
    .m_axi_wdata         (v_wdata),
    .m_axi_wstrb         (v_wstrb),
    .m_axi_wlast         (v_wlast),
    .m_axi_wvalid        (v_wvalid),
    .m_axi_wready        (v_wready),
    .m_axi_bid           (v_bid),
    .m_axi_bresp         (v_bresp),
    .m_axi_bvalid        (v_bvalid),
    .m_axi_bready        (v_bready),
    .s_axi_awaddr        (dec_awaddr[SLV_S2MM*AW +: 12]),
    .s_axi_awvalid       (dec_awvalid[SLV_S2MM]),
    .s_axi_awready       (dec_awready[SLV_S2MM]),
    .s_axi_wdata         (dec_wdata[SLV_S2MM*32 +: 32]),
    .s_axi_wstrb         (dec_wstrb[SLV_S2MM*4 +: 4]),
    .s_axi_wvalid        (dec_wvalid[SLV_S2MM]),
    .s_axi_wready        (dec_wready[SLV_S2MM]),
    .s_axi_bresp         (dec_bresp[SLV_S2MM*2 +: 2]),
    .s_axi_bvalid        (dec_bvalid[SLV_S2MM]),
    .s_axi_bready        (dec_bready[SLV_S2MM]),
    .s_axi_araddr        (dec_araddr[SLV_S2MM*AW +: 12]),
    .s_axi_arvalid       (dec_arvalid[SLV_S2MM]),
    .s_axi_arready       (dec_arready[SLV_S2MM]),
    .s_axi_rdata         (dec_rdata[SLV_S2MM*32 +: 32]),
    .s_axi_rresp         (dec_rresp[SLV_S2MM*2 +: 2]),
    .s_axi_rvalid        (dec_rvalid[SLV_S2MM]),
    .s_axi_rready        (dec_rready[SLV_S2MM])
  );

  rtlnet_framebuf #(
    .AXIL_SYNC   (1'b1),
    .N           (3),
    .NUM_READERS (1),
    .ADDR_W      (DDR_ADDR_W),
    .SLOT_LOG2   (FB_SLOT_LOG2),
    .FB_BASE     (FB_BASE_OFF)
  ) u_fb (
    .clk                (ui_clk),
    .resetn             (ddr_resetn),
    .s_axi_aclk         (ui_clk),
    .s_axi_aresetn      (ddr_resetn),
    .w_req              (fb_req),
    .w_rsp_valid        (fb_rsp_valid),
    .w_rsp_ok           (fb_rsp_ok),
    .w_rsp_base         (fb_rsp_base),
    .w_done             (fb_done),
    .w_done_good        (fb_done_good),
    .w_done_frame_num   (fb_done_frame_num),
    .w_done_timestamp   (fb_done_timestamp),
    .w_done_width       (fb_done_width),
    .w_done_height      (fb_done_height),
    .w_done_src_pattern (fb_done_src_pattern),
    .r_take             (1'b0),                  // the encoder takes this reader port in a later phase
    .r_release          (1'b0),
    .r_rsp_valid        (),
    .r_rsp_ok           (),
    .r_holds            (),
    .r_slot             (),
    .r_base             (),
    .r_frame_num        (),
    .r_timestamp        (),
    .r_width            (),
    .r_height           (),
    .r_src_pattern      (),
    .s_axi_awaddr       (dec_awaddr[SLV_FB*AW +: 12]),
    .s_axi_awvalid      (dec_awvalid[SLV_FB]),
    .s_axi_awready      (dec_awready[SLV_FB]),
    .s_axi_wdata        (dec_wdata[SLV_FB*32 +: 32]),
    .s_axi_wstrb        (dec_wstrb[SLV_FB*4 +: 4]),
    .s_axi_wvalid       (dec_wvalid[SLV_FB]),
    .s_axi_wready       (dec_wready[SLV_FB]),
    .s_axi_bresp        (dec_bresp[SLV_FB*2 +: 2]),
    .s_axi_bvalid       (dec_bvalid[SLV_FB]),
    .s_axi_bready       (dec_bready[SLV_FB]),
    .s_axi_araddr       (dec_araddr[SLV_FB*AW +: 12]),
    .s_axi_arvalid      (dec_arvalid[SLV_FB]),
    .s_axi_arready      (dec_arready[SLV_FB]),
    .s_axi_rdata        (dec_rdata[SLV_FB*32 +: 32]),
    .s_axi_rresp        (dec_rresp[SLV_FB*2 +: 2]),
    .s_axi_rvalid       (dec_rvalid[SLV_FB]),
    .s_axi_rready       (dec_rready[SLV_FB])
  );

  // The engine masters connect to arbiter masters 2 and 3 directly (one clock). The engine address is 32 bits wide; its low DDR_ADDR_W bits
  // reach the arbiter (every encoder buffer lies below 512 MiB). The engines use no read-data ID.
  for (genvar ge = 0; ge < 2; ge++) begin : g_enc
    assign e_awid[ge*ARB_ID_W +: ARB_ID_W]            = h_awid[ge*ARB_ID_W +: ARB_ID_W];
    assign e_awaddr[ge*DDR_ADDR_W +: DDR_ADDR_W]      = h_awaddr[ge*32 +: DDR_ADDR_W];
    assign e_awlen[ge*8 +: 8]                         = h_awlen[ge*8 +: 8];
    assign e_awsize[ge*3 +: 3]                        = h_awsize[ge*3 +: 3];
    assign e_awburst[ge*2 +: 2]                       = h_awburst[ge*2 +: 2];
    assign e_awvalid[ge]                              = h_awvalid[ge];
    assign h_awready[ge]                              = e_awready[ge];
    assign e_wdata[ge*DDR_DATA_W +: DDR_DATA_W]       = h_wdata[ge*DDR_DATA_W +: DDR_DATA_W];
    assign e_wstrb[ge*DDR_DATA_W/8 +: DDR_DATA_W/8]   = h_wstrb[ge*DDR_DATA_W/8 +: DDR_DATA_W/8];
    assign e_wlast[ge]                                = h_wlast[ge];
    assign e_wvalid[ge]                               = h_wvalid[ge];
    assign h_wready[ge]                               = e_wready[ge];
    assign h_bid[ge*ARB_ID_W +: ARB_ID_W]             = e_bid[ge*ARB_ID_W +: ARB_ID_W];
    assign h_bresp[ge*2 +: 2]                         = e_bresp[ge*2 +: 2];
    assign h_bvalid[ge]                               = e_bvalid[ge];
    assign e_bready[ge]                               = h_bready[ge];
    assign e_arid[ge*ARB_ID_W +: ARB_ID_W]            = h_arid[ge*ARB_ID_W +: ARB_ID_W];
    assign e_araddr[ge*DDR_ADDR_W +: DDR_ADDR_W]      = h_araddr[ge*32 +: DDR_ADDR_W];
    assign e_arlen[ge*8 +: 8]                         = h_arlen[ge*8 +: 8];
    assign e_arsize[ge*3 +: 3]                        = h_arsize[ge*3 +: 3];
    assign e_arburst[ge*2 +: 2]                       = h_arburst[ge*2 +: 2];
    assign e_arvalid[ge]                              = h_arvalid[ge];
    assign h_arready[ge]                              = e_arready[ge];
    assign h_rdata[ge*DDR_DATA_W +: DDR_DATA_W]       = e_rdata[ge*DDR_DATA_W +: DDR_DATA_W];
    assign h_rresp[ge*2 +: 2]                         = e_rresp[ge*2 +: 2];
    assign h_rlast[ge]                                = e_rlast[ge];
    assign h_rvalid[ge]                               = e_rvalid[ge];
    assign e_rready[ge]                               = h_rready[ge];
  end

  // Phase 2b-3: the H.264 encoder, two engines on ui_clk, masters 2 and 3 of the arbiter (round robin); the register window comes
  // from ui_clk through the core's rtlnet_axil_cdc. The firmware holds a frame-buffer slot for each picture, points IN_BASE at it
  // and places the rebuilt picture, the rings and the index rings in DDR3 above the frame buffer (rtlnet_nexys_video.md, 6.11).
  rtlnet_h264_top #(
    .AXIL_SYNC   (1'b1),
    .NUM_ENGINES (2),
    .ADDR_W      (32),
    .ID_W        (ARB_ID_W),
    .RAM_STYLE   ("block"),
    .HIGH_PROFILE(HIGH_PROFILE),
    .HP_T8       (HP_T8),
    .HP_T8_AUTO  (HP_T8_AUTO)
  ) u_h264 (
    .enc_clk        (ui_clk),
    .enc_resetn     (ddr_resetn),
    .s_axi_aclk     (ui_clk),
    .s_axi_aresetn  (ddr_resetn),
    .s_axi_awaddr   (dec_awaddr[SLV_H264*AW +: 12]),
    .s_axi_awvalid  (dec_awvalid[SLV_H264]),
    .s_axi_awready  (dec_awready[SLV_H264]),
    .s_axi_wdata    (dec_wdata[SLV_H264*32 +: 32]),
    .s_axi_wstrb    (dec_wstrb[SLV_H264*4 +: 4]),
    .s_axi_wvalid   (dec_wvalid[SLV_H264]),
    .s_axi_wready   (dec_wready[SLV_H264]),
    .s_axi_bresp    (dec_bresp[SLV_H264*2 +: 2]),
    .s_axi_bvalid   (dec_bvalid[SLV_H264]),
    .s_axi_bready   (dec_bready[SLV_H264]),
    .s_axi_araddr   (dec_araddr[SLV_H264*AW +: 12]),
    .s_axi_arvalid  (dec_arvalid[SLV_H264]),
    .s_axi_arready  (dec_arready[SLV_H264]),
    .s_axi_rdata    (dec_rdata[SLV_H264*32 +: 32]),
    .s_axi_rresp    (dec_rresp[SLV_H264*2 +: 2]),
    .s_axi_rvalid   (dec_rvalid[SLV_H264]),
    .s_axi_rready   (dec_rready[SLV_H264]),
    .m_axi_awid     (h_awid),
    .m_axi_awaddr   (h_awaddr),
    .m_axi_awlen    (h_awlen),
    .m_axi_awsize   (h_awsize),
    .m_axi_awburst  (h_awburst),
    .m_axi_awvalid  (h_awvalid),
    .m_axi_awready  (h_awready),
    .m_axi_wdata    (h_wdata),
    .m_axi_wstrb    (h_wstrb),
    .m_axi_wlast    (h_wlast),
    .m_axi_wvalid   (h_wvalid),
    .m_axi_wready   (h_wready),
    .m_axi_bid      (h_bid),
    .m_axi_bresp    (h_bresp),
    .m_axi_bvalid   (h_bvalid),
    .m_axi_bready   (h_bready),
    .m_axi_arid     (h_arid),
    .m_axi_araddr   (h_araddr),
    .m_axi_arlen    (h_arlen),
    .m_axi_arsize   (h_arsize),
    .m_axi_arburst  (h_arburst),
    .m_axi_arvalid  (h_arvalid),
    .m_axi_arready  (h_arready),
    .m_axi_rdata    (h_rdata),
    .m_axi_rresp    (h_rresp),
    .m_axi_rlast    (h_rlast),
    .m_axi_rvalid   (h_rvalid),
    .m_axi_rready   (h_rready),
    .irq            (h264_irq)
  );

  // DDR3 controller: sys_clk is MMCM2 CLKOUT0 (ddr_sys_clk, 102.857 MHz), ref_clk clk200.
  // sys_rstn is the board reset assertion: a button press recalibrates the memory.
  rtlnet_ddr #(
    .ADDR_W (DDR_ADDR_W),
    .DATA_W (DDR_DATA_W),
    .ID_W   (DDR_ID_W)
  ) u_ddr (
    .sys_clk             (ddr_sys_clk),
    .ref_clk             (clk200),
    .sys_rstn            (rst_arstn),
    .ui_clk              (ui_clk),
    .ui_resetn           (ui_resetn_mig),
    .s_axi_aresetn       (ddr_resetn),
    .init_calib_complete (ddr_calib),
    .s_axi_awid          (mem_awid),
    .s_axi_awaddr        (mem_awaddr),
    .s_axi_awlen         (mem_awlen),
    .s_axi_awsize        (mem_awsize),
    .s_axi_awburst       (mem_awburst),
    .s_axi_awlock        (mem_awlock),
    .s_axi_awcache       (mem_awcache),
    .s_axi_awprot        (mem_awprot),
    .s_axi_awqos         (mem_awqos),
    .s_axi_awvalid       (mem_awvalid),
    .s_axi_awready       (mem_awready),
    .s_axi_wdata         (mem_wdata),
    .s_axi_wstrb         (mem_wstrb),
    .s_axi_wlast         (mem_wlast),
    .s_axi_wvalid        (mem_wvalid),
    .s_axi_wready        (mem_wready),
    .s_axi_bid           (mem_bid),
    .s_axi_bresp         (mem_bresp),
    .s_axi_bvalid        (mem_bvalid),
    .s_axi_bready        (mem_bready),
    .s_axi_arid          (mem_arid),
    .s_axi_araddr        (mem_araddr),
    .s_axi_arlen         (mem_arlen),
    .s_axi_arsize        (mem_arsize),
    .s_axi_arburst       (mem_arburst),
    .s_axi_arlock        (mem_arlock),
    .s_axi_arcache       (mem_arcache),
    .s_axi_arprot        (mem_arprot),
    .s_axi_arqos         (mem_arqos),
    .s_axi_arvalid       (mem_arvalid),
    .s_axi_arready       (mem_arready),
    .s_axi_rid           (mem_rid),
    .s_axi_rdata         (mem_rdata),
    .s_axi_rresp         (mem_rresp),
    .s_axi_rlast         (mem_rlast),
    .s_axi_rvalid        (mem_rvalid),
    .s_axi_rready        (mem_rready),
    .ddr3_dq             (ddr3_dq),
    .ddr3_dqs_n          (ddr3_dqs_n),
    .ddr3_dqs_p          (ddr3_dqs_p),
    .ddr3_addr           (ddr3_addr),
    .ddr3_ba             (ddr3_ba),
    .ddr3_ras_n          (ddr3_ras_n),
    .ddr3_cas_n          (ddr3_cas_n),
    .ddr3_we_n           (ddr3_we_n),
    .ddr3_reset_n        (ddr3_reset_n),
    .ddr3_ck_p           (ddr3_ck_p),
    .ddr3_ck_n           (ddr3_ck_n),
    .ddr3_cke            (ddr3_cke),
    .ddr3_dm             (ddr3_dm),
    .ddr3_odt            (ddr3_odt)
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
          .s_axi_aclk    (ui_clk),
          .s_axi_aresetn (ddr_resetn),
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
    .s_axi_aclk        (ui_clk),
    .clk125_resetn     (clk125_resetn),
    .clk200_resetn     (clk200_resetn),
    .axis_resetn       (axis_resetn),
    .s_axi_aresetn     (ddr_resetn),
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
    .clk           (ui_clk),
    .resetn        (ddr_resetn),
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
    .s_axi_aclk        (ui_clk),
    .axis_resetn       (axis_resetn),
    .proto_resetn      (proto_resetn),
    .app_resetn        (proto_resetn),
    .s_axi_aresetn     (ddr_resetn),
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
    .cpu_axis_clk           (ui_clk),
    .cpu_axis_resetn        (ddr_resetn),
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
    .s_axi_aclk    (ui_clk),
    .s_axi_aresetn (ddr_resetn),
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

  assign cpu_irq         = {6'd0, h264_irq, mdio_irq};   // irq[0] MDIO, irq[1] H.264 encoder (INTC inputs 0 and 1)
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
  // ui_clk reset release, then release it (register output to the pin).
  always_ff @(posedge ui_clk) begin
    if (!ddr_resetn) begin
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

  assign cpu_irq           = {6'd0, h264_irq, 1'b0};
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
