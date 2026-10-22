// -----------------------------------------------------------------------------
// File: rtlnet_cpu_microblaze.sv
// Purpose: the RTLNet CPU core: a vendor-neutral port list (architecture
//   section 15.6) around the MicroBlaze block design `rtlnet_cpu`
//   (microblaze/hdl/rtlnet_cpu_bd.tcl).
// Overview:
//   * The block design holds MicroBlaze, 256 KiB LMB BRAM, MDM, UART Lite
//     (115200 8N1), AXI Timer, AXI INTC, the AXI DMA with its 128 KiB AXI
//     BRAM and the interconnects; its exported AXI4-Lite master M_AXI_RTLNET
//     (0x44A0_0000, 1 MiB) is this core's m_axi_* register master, full
//     32-bit addresses.
//   * Ethernet frames (cpu_axis_ethernet_stream, architecture 7.4): the DMA
//     MM2S stream M_AXIS_ETH is m_axis_eth_* (frames the CPU sends, to the
//     protocol wrapper's s_axis_cpu_eth_*), the S2MM stream S_AXIS_ETH is
//     s_axis_eth_* (unclaimed frames from the wrapper's m_axis_cpu_eth_*).
//     RTLNet stream format: 64-bit tdata, byte 0 in [7:0], tkeep contiguous
//     from bit 0 on the last beat, tlast; complete Ethernet frames without FCS.
//   * The console receive pin is asynchronous to clk. The UART Lite of the
//     block design synchronizes it with its own two-stage ASYNC_REG chain
//     (UARTLITE_RX_I/INPUT_DOUBLE_REGS3), so it connects straight through; a
//     replacement processor must synchronize its receive pin the same way.
//   * AWPROT/ARPROT of the block design are not used by RTLNet slaves and stay
//     inside this wrapper.
//   * A replacement processor (Nios V, another RISC-V) is a different file with
//     this exact port list; the board top does not change. The bus-functional
//     model rtlnet_microblaze_sim_stub.sv (top of microblaze/) has the same ports.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: m_axis_eth_* / s_axis_eth_* frame streams (AXI DMA).
// Clocks: clk (cpu_clk 100 MHz) only; resetn synchronous to clk, active low.
// -----------------------------------------------------------------------------
module rtlnet_cpu_microblaze (
  // cpu_clk (100 MHz) and its synchronous active-low reset from the board top.
  input  logic        clk,
  input  logic        resetn,

  // Console: uart_rxd from the USB-UART bridge (asynchronous, idle high),
  // uart_txd to it (115200 8N1).
  input  logic        uart_rxd,
  output logic        uart_txd,

  // AXI4-Lite register master, clk domain, 32-bit address and data, into the
  // board top's rtlnet_axil_decoder.
  output logic [31:0] m_axi_awaddr,
  output logic        m_axi_awvalid,
  input  logic        m_axi_awready,
  output logic [31:0] m_axi_wdata,
  output logic [3:0]  m_axi_wstrb,
  output logic        m_axi_wvalid,
  input  logic        m_axi_wready,
  input  logic [1:0]  m_axi_bresp,
  input  logic        m_axi_bvalid,
  output logic        m_axi_bready,
  output logic [31:0] m_axi_araddr,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [31:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready,

  // Interrupt requests, level, active high, synchronous to clk (INTC inputs
  // 0..7).
  input  logic [7:0]  irq,

  // Ethernet frames to the network, clk domain, RTLNet stream (AXI DMA MM2S;
  // to the protocol wrapper's s_axis_cpu_eth_*).
  output logic [63:0] m_axis_eth_tdata,
  output logic [7:0]  m_axis_eth_tkeep,
  output logic        m_axis_eth_tvalid,
  output logic        m_axis_eth_tlast,
  input  logic        m_axis_eth_tready,

  // Ethernet frames from the network, clk domain, RTLNet stream (AXI DMA
  // S2MM; from the protocol wrapper's m_axis_cpu_eth_*).
  input  logic [63:0] s_axis_eth_tdata,
  input  logic [7:0]  s_axis_eth_tkeep,
  input  logic        s_axis_eth_tvalid,
  input  logic        s_axis_eth_tlast,
  output logic        s_axis_eth_tready
);

  // MicroBlaze subsystem, Tcl-generated block design wrapper.
  rtlnet_cpu_wrapper u_bd (
    .clk                  (clk),
    .resetn               (resetn),
    .uart_rxd             (uart_rxd),
    .uart_txd             (uart_txd),
    .irq                  (irq),
    .M_AXI_RTLNET_awaddr  (m_axi_awaddr),
    .M_AXI_RTLNET_awprot  (),
    .M_AXI_RTLNET_awvalid (m_axi_awvalid),
    .M_AXI_RTLNET_awready (m_axi_awready),
    .M_AXI_RTLNET_wdata   (m_axi_wdata),
    .M_AXI_RTLNET_wstrb   (m_axi_wstrb),
    .M_AXI_RTLNET_wvalid  (m_axi_wvalid),
    .M_AXI_RTLNET_wready  (m_axi_wready),
    .M_AXI_RTLNET_bresp   (m_axi_bresp),
    .M_AXI_RTLNET_bvalid  (m_axi_bvalid),
    .M_AXI_RTLNET_bready  (m_axi_bready),
    .M_AXI_RTLNET_araddr  (m_axi_araddr),
    .M_AXI_RTLNET_arprot  (),
    .M_AXI_RTLNET_arvalid (m_axi_arvalid),
    .M_AXI_RTLNET_arready (m_axi_arready),
    .M_AXI_RTLNET_rdata   (m_axi_rdata),
    .M_AXI_RTLNET_rresp   (m_axi_rresp),
    .M_AXI_RTLNET_rvalid  (m_axi_rvalid),
    .M_AXI_RTLNET_rready  (m_axi_rready),
    .M_AXIS_ETH_tdata     (m_axis_eth_tdata),
    .M_AXIS_ETH_tkeep     (m_axis_eth_tkeep),
    .M_AXIS_ETH_tvalid    (m_axis_eth_tvalid),
    .M_AXIS_ETH_tlast     (m_axis_eth_tlast),
    .M_AXIS_ETH_tready    (m_axis_eth_tready),
    .S_AXIS_ETH_tdata     (s_axis_eth_tdata),
    .S_AXIS_ETH_tkeep     (s_axis_eth_tkeep),
    .S_AXIS_ETH_tvalid    (s_axis_eth_tvalid),
    .S_AXIS_ETH_tlast     (s_axis_eth_tlast),
    .S_AXIS_ETH_tready    (s_axis_eth_tready)
  );

endmodule
