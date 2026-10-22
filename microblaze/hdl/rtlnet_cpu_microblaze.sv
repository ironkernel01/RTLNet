// -----------------------------------------------------------------------------
// File: rtlnet_cpu_microblaze.sv
// Purpose: the RTLNet CPU core: a vendor-neutral port list (architecture
//   section 15.6) around the MicroBlaze block design `rtlnet_cpu`
//   (microblaze/hdl/rtlnet_cpu_bd.tcl).
// Overview:
//   * The block design holds MicroBlaze, 128 KiB LMB BRAM, MDM, UART Lite
//     (115200 8N1), AXI Timer, AXI INTC and the interconnect; its exported
//     AXI4-Lite master M_AXI_RTLNET (0x44A0_0000, 1 MiB) is this core's
//     m_axi_* register master, full 32-bit addresses.
//   * The console receive pin is asynchronous to clk. The UART Lite of the
//     block design synchronizes it with its own two-stage ASYNC_REG chain
//     (UARTLITE_RX_I/INPUT_DOUBLE_REGS3), so it connects straight through; a
//     replacement processor must synchronize its receive pin the same way.
//   * AWPROT/ARPROT of the block design are not used by RTLNet slaves and stay
//     inside this wrapper.
//   * A replacement processor (Nios V, another RISC-V) is a different file with
//     this exact port list; the board top does not change. The bus-functional
//     model testbench/rtlnet_cpu_bfm.sv has the same ports.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
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
  input  logic [7:0]  irq
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
    .M_AXI_RTLNET_rready  (m_axi_rready)
  );

endmodule
