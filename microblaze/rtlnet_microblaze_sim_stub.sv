// -----------------------------------------------------------------------------
// File: rtlnet_microblaze_sim_stub.sv
// Purpose: Simulation stand-in for the MicroBlaze CPU core (same ports as
//   rtlnet_cpu_microblaze): scripted AXI4-Lite register sequences and DMA
//   frame source/sink tasks; board benches use it instead of simulating the
//   processor.
// Overview:
//   * Instanced by the board top in place of the CPU core when the bench
//     defines RTLNET_MICROBLAZE_SIM_STUB (same instance name u_cpu); the bench
//     calls the tasks hierarchically, e.g. dut.u_cpu.axil_read(addr, data,
//     resp). The firmware (lwIP, TCP echo, CLI) is verified on hardware and in
//     the host harness, never in RTL simulation.
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
//   * Ethernet frame streams (the AXI DMA of the real core), RTLNet stream
//     format: eth_send(frame) drives one frame (byte queue, byte 0 in
//     tdata[7:0], tkeep on the last beat) on m_axis_eth_*; a sink process
//     takes every frame on s_axis_eth_* into eth_rx_q (one byte queue per
//     frame, tkeep honoured; tready follows eth_rx_ready, default 1) and
//     eth_get(frame, timeout_clks, ok) pops the oldest. Counters eth_tx_frames,
//     eth_rx_frames, eth_rx_keep_errors (a non-final beat without tkeep FF or
//     a non-contiguous final tkeep).
//   * Firmware-equivalent register sequences: axil_set_bits(addr, mask) and
//     axil_clear_bits(addr, mask) (read-modify-write, e.g. the protocol
//     wrapper's CPU path enable), cls_config_bcast_storm(base, limit, window)
//     (the classifier register sequence of rtlnet_classifier_config_bcast_storm:
//     clear tables, MAC table classify-only with entry 0 destination
//     FF:FF:FF:FF:FF:FF policed by policer 0, policer 0 = limit/window, MODE
//     PASS_ALL; offsets from cores/rtlnet_classifier/documentation section 7).
//   * Simulation only; never synthesized.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: m_axis_eth_* / s_axis_eth_* frame streams, eth_send/eth_get.
//   * 10-22-2026: renamed from rtlnet_cpu_bfm; register-sequence tasks.
// Clocks: clk (cpu_clk); resetn synchronous to clk, active low.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_microblaze_sim_stub #(
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
  input  logic [7:0]  irq,

  // Ethernet frames to the network, clk domain, RTLNet stream.
  output logic [63:0] m_axis_eth_tdata,
  output logic [7:0]  m_axis_eth_tkeep,
  output logic        m_axis_eth_tvalid,
  output logic        m_axis_eth_tlast,
  input  logic        m_axis_eth_tready,

  // Ethernet frames from the network, clk domain, RTLNet stream.
  input  logic [63:0] s_axis_eth_tdata,
  input  logic [7:0]  s_axis_eth_tkeep,
  input  logic        s_axis_eth_tvalid,
  input  logic        s_axis_eth_tlast,
  output logic        s_axis_eth_tready
);

  localparam int BIT_CLKS = CLK_HZ / BAUD;

  typedef byte unsigned frame_t[$];

  byte unsigned uart_rx_q[$];
  int           uart_rx_errors = 0;
  int           axil_timeouts  = 0;
  frame_t       eth_rx_q[$];
  bit           eth_rx_ready       = 1'b1;
  int           eth_tx_frames      = 0;
  int           eth_rx_frames      = 0;
  int           eth_rx_keep_errors = 0;

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
    m_axis_eth_tdata  = '0;
    m_axis_eth_tkeep  = '0;
    m_axis_eth_tvalid = 1'b0;
    m_axis_eth_tlast  = 1'b0;
  end

  assign s_axis_eth_tready = eth_rx_ready;

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

  // Read-modify-write helpers for firmware-equivalent register sequences.
  task automatic axil_set_bits(input logic [31:0] addr, input logic [31:0] mask, output logic [1:0] resp);
    logic [31:0] v;
    axil_read(addr, v, resp);
    if (resp == 2'b00) axil_write(addr, v | mask, 4'hF, resp);
  endtask

  task automatic axil_clear_bits(input logic [31:0] addr, input logic [31:0] mask, output logic [1:0] resp);
    logic [31:0] v;
    axil_read(addr, v, resp);
    if (resp == 2'b00) axil_write(addr, v & ~mask, 4'hF, resp);
  endtask

  // Classifier broadcast storm configuration, register level (the sequence
  // of rtlnet_classifier_config_bcast_storm). base = the classifier window
  // (0x44A1_8000 for the CPU-path instance). Register offsets: classifier
  // documentation section 7 (CTRL 0x00C, STATUS 0x010, TABLE_MODE[0] 0x020,
  // POLICER[0] 0x100, MAC table entry 0 at 0x400).
  task automatic cls_config_bcast_storm(input logic [31:0] base, input int limit_pkts, input int window_ms,
                                        output logic [1:0] resp);
    localparam logic [31:0] CLS_CTRL         = 32'h00C;
    localparam logic [31:0] CLS_STATUS       = 32'h010;
    localparam logic [31:0] CLS_TABLE_MODE0  = 32'h020;
    localparam logic [31:0] CLS_POL0         = 32'h100;
    localparam logic [31:0] CLS_MAC_E0       = 32'h400;
    localparam logic [31:0] CTRL_CLEAR       = 32'h0000_0100;
    localparam logic [31:0] MODE_PASS_ALL    = 32'h0000_0001;
    localparam logic [31:0] TMODE_EN_CLASSIFY = 32'h0000_0011;   // ENABLE | CLASSIFY, single-value compare
    // Entry word 1: VALID[31] DST_EN[29] POLICE_EN[26] POLICER[25:24]=0; SRC_VALUE[47:32] 0.
    localparam logic [31:0] E0_FLAGS         = 32'hA400_0000;
    logic [31:0] st;
    int          n;
    axil_write(base + CLS_CTRL, CTRL_CLEAR, 4'hF, resp);
    n = 0;
    do begin
      axil_read(base + CLS_STATUS, st, resp);
      n++;
    end while (st[0] && n < 1000);
    axil_write(base + CLS_TABLE_MODE0, 32'h0, 4'hF, resp);
    axil_write(base + CLS_MAC_E0 + 32'h0, 32'h0, 4'hF, resp);
    axil_write(base + CLS_MAC_E0 + 32'h4, E0_FLAGS, 4'hF, resp);
    axil_write(base + CLS_MAC_E0 + 32'h8, 32'hFFFF_FFFF, 4'hF, resp);
    axil_write(base + CLS_MAC_E0 + 32'hC, 32'h0000_FFFF, 4'hF, resp);
    axil_write(base + CLS_TABLE_MODE0, TMODE_EN_CLASSIFY, 4'hF, resp);
    axil_write(base + CLS_POL0 + 32'h4, limit_pkts, 4'hF, resp);
    axil_write(base + CLS_POL0 + 32'h8, window_ms, 4'hF, resp);
    axil_write(base + CLS_POL0 + 32'h0, 32'h1, 4'hF, resp);
    axil_write(base + CLS_CTRL, MODE_PASS_ALL, 4'hF, resp);
  endtask

  // Send one Ethernet frame on m_axis_eth_*: eight bytes per beat, tkeep
  // contiguous on the last beat, tlast; waits for tready on every beat.
  task automatic eth_send(input frame_t frame);
    int n;
    n = $size(frame);
    if (n == 0) return;
    for (int b = 0; b < n; b += 8) begin
      logic [63:0] d;
      logic [7:0]  k;
      d = '0;
      k = '0;
      for (int i = 0; i < 8; i++) begin
        if (b + i < n) begin
          d[8*i +: 8] = frame[b + i];
          k[i]        = 1'b1;
        end
      end
      m_axis_eth_tdata  <= d;
      m_axis_eth_tkeep  <= k;
      m_axis_eth_tlast  <= (b + 8 >= n);
      m_axis_eth_tvalid <= 1'b1;
      @(posedge clk);
      while (!m_axis_eth_tready) @(posedge clk);
    end
    m_axis_eth_tvalid <= 1'b0;
    m_axis_eth_tlast  <= 1'b0;
    eth_tx_frames++;
  endtask

  // Pop the oldest received Ethernet frame, waiting up to timeout_clks.
  task automatic eth_get(output frame_t frame, input int timeout_clks, output bit ok);
    int t;
    t = 0;
    frame = {};
    while ($size(eth_rx_q) == 0 && t < timeout_clks) begin
      @(posedge clk);
      t++;
    end
    ok = ($size(eth_rx_q) > 0);
    if (ok) frame = eth_rx_q.pop_front();
  endtask

  // Frame sink on s_axis_eth_*: collect bytes per tkeep, close the frame on
  // tlast, check the tkeep rule of the RTLNet stream.
  initial begin : eth_rx_model
    frame_t cur;
    cur = {};
    forever begin
      @(posedge clk);
      if (s_axis_eth_tvalid === 1'b1 && s_axis_eth_tready === 1'b1) begin
        bit contiguous;
        contiguous = 1'b1;
        for (int i = 0; i < 8; i++) begin
          if (s_axis_eth_tkeep[i]) begin
            cur.push_back(s_axis_eth_tdata[8*i +: 8]);
            if (i > 0 && !s_axis_eth_tkeep[i-1]) contiguous = 1'b0;
          end
        end
        if (!s_axis_eth_tkeep[0] || !contiguous) eth_rx_keep_errors++;
        if (s_axis_eth_tlast !== 1'b1 && s_axis_eth_tkeep !== 8'hFF) eth_rx_keep_errors++;
        if (s_axis_eth_tlast === 1'b1) begin
          eth_rx_q.push_back(cur);
          eth_rx_frames++;
          cur = {};
        end
      end
    end
  end

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
