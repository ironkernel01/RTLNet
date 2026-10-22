// -----------------------------------------------------------------------------
// File: rtlnet_cpu_bfm.sv
// Purpose: bus-functional model of the RTLNet CPU core: the port list of
//   rtlnet_cpu_microblaze (architecture section 15.6) driven by scripted
//   tasks, so a board bench runs the real board top without a processor.
// Overview:
//   * Instanced by the board top in place of the CPU core when the bench
//     defines RTLNET_CPU_BFM (same instance name u_cpu); the bench calls the
//     tasks hierarchically, e.g. dut.u_cpu.axil_read(addr, data, resp).
//   * AXI4-Lite master on clk: axil_write(addr, data, strb, resp) drives AW and
//     W together and waits for B; axil_read(addr, data, resp) drives AR and
//     waits for R. One transaction at a time, every response returned to the
//     caller (OKAY 2'b00, DECERR 2'b11); a transaction that does not complete
//     in TIMEOUT clocks returns resp 2'b10 and increments axil_timeouts.
//   * UART model, 8N1 at BAUD (bit time CLK_HZ / BAUD clocks of clk):
//     uart_send(byte) transmits on uart_txd (the console output of the CPU);
//     a receiver process samples uart_rxd at mid-bit and appends every byte
//     to uart_rx_q (framing errors counted in uart_rx_errors); uart_get(byte,
//     timeout_clks, ok) pops the oldest byte.
//   * irq[7:0] is observable as an input; wait_irq(mask, timeout, ok) waits
//     for any masked bit.
//   * Simulation only; never synthesized.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (cpu_clk); resetn synchronous to clk, active low.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_cpu_bfm #(
  parameter int CLK_HZ  = 100_000_000,
  parameter int BAUD    = 115_200,
  parameter int TIMEOUT = 20_000            // clocks per AXI4-Lite transaction
)(
  // cpu_clk (100 MHz) and its synchronous active-low reset from the board top.
  input  logic        clk,
  input  logic        resetn,

  // Console: uart_rxd from the USB-UART bridge (idle high), uart_txd to it.
  input  logic        uart_rxd,
  output logic        uart_txd,

  // AXI4-Lite register master, clk domain, 32-bit address and data.
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

  // Interrupt requests, level, active high (observed only).
  input  logic [7:0]  irq
);

  localparam int BIT_CLKS = CLK_HZ / BAUD;

  byte unsigned uart_rx_q[$];
  int           uart_rx_errors = 0;
  int           axil_timeouts  = 0;

  initial begin
    m_axi_awaddr  = '0;
    m_axi_awvalid = 1'b0;
    m_axi_wdata   = '0;
    m_axi_wstrb   = '0;
    m_axi_wvalid  = 1'b0;
    m_axi_bready  = 1'b0;
    m_axi_araddr  = '0;
    m_axi_arvalid = 1'b0;
    m_axi_rready  = 1'b0;
    uart_txd      = 1'b1;
  end

  // Wait until the board top releases the CPU reset.
  task automatic wait_reset_release();
    while (resetn !== 1'b1) @(posedge clk);
    @(posedge clk);
  endtask

  // AXI4-Lite write: AW and W together, then B.
  task automatic axil_write(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb,
                            output logic [1:0] resp);
    int  t;
    bit  aw_ok;
    bit  w_ok;
    @(posedge clk);
    m_axi_awaddr  <= addr;
    m_axi_awvalid <= 1'b1;
    m_axi_wdata   <= data;
    m_axi_wstrb   <= strb;
    m_axi_wvalid  <= 1'b1;
    aw_ok = 0;
    w_ok  = 0;
    t     = 0;
    while (!(aw_ok && w_ok) && t < TIMEOUT) begin
      @(posedge clk);
      if (m_axi_awvalid && m_axi_awready) begin aw_ok = 1; m_axi_awvalid <= 1'b0; end
      if (m_axi_wvalid && m_axi_wready)   begin w_ok  = 1; m_axi_wvalid  <= 1'b0; end
      t++;
    end
    m_axi_bready <= 1'b1;
    while (!(m_axi_bvalid && m_axi_bready) && t < TIMEOUT) begin
      @(posedge clk);
      t++;
    end
    resp = (t < TIMEOUT) ? m_axi_bresp : 2'b10;
    if (t >= TIMEOUT) axil_timeouts++;
    m_axi_awvalid <= 1'b0;
    m_axi_wvalid  <= 1'b0;
    m_axi_bready  <= 1'b0;
  endtask

  // AXI4-Lite read: AR, then R.
  task automatic axil_read(input logic [31:0] addr, output logic [31:0] data, output logic [1:0] resp);
    int t;
    @(posedge clk);
    m_axi_araddr  <= addr;
    m_axi_arvalid <= 1'b1;
    t = 0;
    while (t < TIMEOUT) begin
      @(posedge clk);
      t++;
      if (m_axi_arvalid && m_axi_arready) begin
        m_axi_arvalid <= 1'b0;
        break;
      end
    end
    m_axi_rready <= 1'b1;
    while (!(m_axi_rvalid && m_axi_rready) && t < TIMEOUT) begin
      @(posedge clk);
      t++;
    end
    data = m_axi_rdata;
    resp = (t < TIMEOUT) ? m_axi_rresp : 2'b10;
    if (t >= TIMEOUT) axil_timeouts++;
    m_axi_arvalid <= 1'b0;
    m_axi_rready  <= 1'b0;
  endtask

  // UART transmit of one byte on uart_txd: start bit, 8 data bits LSB first,
  // stop bit.
  task automatic uart_send(input byte unsigned b);
    uart_txd <= 1'b0;
    repeat (BIT_CLKS) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      uart_txd <= b[i];
      repeat (BIT_CLKS) @(posedge clk);
    end
    uart_txd <= 1'b1;
    repeat (BIT_CLKS) @(posedge clk);
  endtask

  // Pop the oldest received byte, waiting up to timeout_clks.
  task automatic uart_get(output byte unsigned b, input int timeout_clks, output bit ok);
    int t;
    t = 0;
    while ($size(uart_rx_q) == 0 && t < timeout_clks) begin
      @(posedge clk);
      t++;
    end
    ok = ($size(uart_rx_q) > 0);
    b  = ok ? uart_rx_q.pop_front() : 8'h00;
  endtask

  // Wait for any interrupt bit in mask.
  task automatic wait_irq(input logic [7:0] mask, input int timeout_clks, output bit ok);
    int t;
    t = 0;
    while ((irq & mask) == 8'h00 && t < timeout_clks) begin
      @(posedge clk);
      t++;
    end
    ok = ((irq & mask) != 8'h00);
  endtask

  // UART receiver model on uart_rxd: start-bit edge, mid-bit sampling.
  initial begin : uart_rx_model
    byte unsigned b;
    forever begin
      @(negedge uart_rxd);
      repeat (BIT_CLKS / 2) @(posedge clk);
      if (uart_rxd !== 1'b0) continue;
      for (int i = 0; i < 8; i++) begin
        repeat (BIT_CLKS) @(posedge clk);
        b[i] = uart_rxd;
      end
      repeat (BIT_CLKS) @(posedge clk);
      if (uart_rxd !== 1'b1) uart_rx_errors++;
      else uart_rx_q.push_back(b);
    end
  end

endmodule
