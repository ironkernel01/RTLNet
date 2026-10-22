// -----------------------------------------------------------------------------
// File: rtlnet_tcp_offload.sv
// Purpose: IPv4 / TCP / UDP checksum offload on the CPU DMA stream: inserts the
//   checksums of frames the CPU transmits and computes them for frames the CPU
//   receives, so the CPU's network stack skips that work.
// Overview:
//   * Egress (CPU DMA MM2S -> offload -> CPU TX FIFO): rtlnet_tcp_offload_tx,
//     store and forward, patches the IPv4 header checksum and the TCP / UDP
//     checksum in place (CTRL.tx_ip_csum, CTRL.tx_l4_csum). The existing field
//     contents are ignored. VLAN (one 802.1Q tag) aware.
//   * Ingress (classifier output -> offload -> AXI DMA S2MM): rtlnet_tcp_offload_rx,
//     cut-through, checks the IPv4 header and the TCP / UDP checksum while the
//     frame streams and appends an 8-byte trailer beat with the result
//     (CTRL.rx_csum). Nothing is dropped in hardware.
//   * Both paths are bit-exact pass-through while CTRL is 0 (power-up value).
//   * Registers: standard header ID "TCPO" / VERSION / CAPS, CTRL, STATUS (idle
//     bits), LATENCY, CNT_CLEAR and eleven counters (rtlnet_tcp_offload_regs).
//     Planned protocol sub-map slot 0x9000 (0x44A1_9000), not wired here.
//   * Everything runs in clk (the CPU stream clock); the register file crosses
//     from s_axi_aclk inside rtlnet_tcp_offload_regs.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (stream), s_axi_aclk (registers); each reset synchronous, active
//   low, asserted together.
// -----------------------------------------------------------------------------
module rtlnet_tcp_offload #(
  parameter string RAM_STYLE       = "block",       // TX frame buffer: "block" | "distributed"
  parameter string SB_RAM_STYLE    = "distributed", // TX sideband queue
  parameter int    TX_BUF_KB       = 8,             // TX frame buffer, kilobytes (8 = four maximum frames: full rate)
  parameter int    MAX_FRAME_BYTES = 1518
)(
  // Clocks and resets.
  input  logic        clk,
  input  logic        resetn,
  input  logic        s_axi_aclk,
  input  logic        s_axi_aresetn,

  // TX: frames from the CPU DMA (MM2S), RTLNet stream.
  input  logic [63:0] s_axis_tx_tdata,
  input  logic [7:0]  s_axis_tx_tkeep,
  input  logic        s_axis_tx_tvalid,
  input  logic        s_axis_tx_tlast,
  output logic        s_axis_tx_tready,

  // TX: frames to the CPU TX FIFO, RTLNet stream.
  output logic [63:0] m_axis_tx_tdata,
  output logic [7:0]  m_axis_tx_tkeep,
  output logic        m_axis_tx_tvalid,
  output logic        m_axis_tx_tlast,
  input  logic        m_axis_tx_tready,

  // RX: frames from the classifier, RTLNet stream.
  input  logic [63:0] s_axis_rx_tdata,
  input  logic [7:0]  s_axis_rx_tkeep,
  input  logic        s_axis_rx_tvalid,
  input  logic        s_axis_rx_tlast,
  output logic        s_axis_rx_tready,

  // RX: frames and trailers to the CPU DMA (S2MM), RTLNet stream.
  output logic [63:0] m_axis_rx_tdata,
  output logic [7:0]  m_axis_rx_tkeep,
  output logic        m_axis_rx_tvalid,
  output logic        m_axis_rx_tlast,
  input  logic        m_axis_rx_tready,

  // Registers, AXI4-Lite slave in s_axi_aclk, 12-bit address.
  input  logic [11:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [11:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready
);

  import rtlnet_tcp_offload_pkg::*;

  logic cfg_tx_ip;
  logic cfg_tx_l4;
  logic cfg_rx;
  logic tx_idle;
  logic rx_idle;
  logic [NUM_TX_COUNTERS-1:0] tx_ev;
  logic [NUM_RX_COUNTERS-1:0] rx_ev;

  // Registers, counters and the AXI4-Lite crossing.
  rtlnet_tcp_offload_regs #(
    .TX_BUF_KB       (TX_BUF_KB),
    .MAX_FRAME_BYTES (MAX_FRAME_BYTES)
  ) u_regs (
    .s_axi_aclk    (s_axi_aclk),
    .s_axi_aresetn (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .clk           (clk),
    .resetn        (resetn),
    .cfg_tx_ip     (cfg_tx_ip),
    .cfg_tx_l4     (cfg_tx_l4),
    .cfg_rx        (cfg_rx),
    .tx_idle       (tx_idle),
    .rx_idle       (rx_idle),
    .tx_ev         (tx_ev),
    .rx_ev         (rx_ev)
  );

  // Egress datapath.
  rtlnet_tcp_offload_tx #(
    .RAM_STYLE       (RAM_STYLE),
    .SB_RAM_STYLE    (SB_RAM_STYLE),
    .TX_BUF_KB       (TX_BUF_KB),
    .MAX_FRAME_BYTES (MAX_FRAME_BYTES)
  ) u_tx (
    .clk           (clk),
    .resetn        (resetn),
    .cfg_ip        (cfg_tx_ip),
    .cfg_l4        (cfg_tx_l4),
    .s_axis_tdata  (s_axis_tx_tdata),
    .s_axis_tkeep  (s_axis_tx_tkeep),
    .s_axis_tvalid (s_axis_tx_tvalid),
    .s_axis_tlast  (s_axis_tx_tlast),
    .s_axis_tready (s_axis_tx_tready),
    .m_axis_tdata  (m_axis_tx_tdata),
    .m_axis_tkeep  (m_axis_tx_tkeep),
    .m_axis_tvalid (m_axis_tx_tvalid),
    .m_axis_tlast  (m_axis_tx_tlast),
    .m_axis_tready (m_axis_tx_tready),
    .idle          (tx_idle),
    .ev_frame      (tx_ev[CNT_TX_FRAMES]),
    .ev_ip         (tx_ev[CNT_TX_IP_PATCHED]),
    .ev_l4         (tx_ev[CNT_TX_L4_PATCHED]),
    .ev_skip       (tx_ev[CNT_TX_SKIPPED]),
    .ev_malf       (tx_ev[CNT_TX_MALFORMED]),
    .ev_drop       (tx_ev[CNT_TX_DROPPED])
  );

  // Ingress datapath.
  rtlnet_tcp_offload_rx u_rx (
    .clk           (clk),
    .resetn        (resetn),
    .cfg_rx        (cfg_rx),
    .s_axis_tdata  (s_axis_rx_tdata),
    .s_axis_tkeep  (s_axis_rx_tkeep),
    .s_axis_tvalid (s_axis_rx_tvalid),
    .s_axis_tlast  (s_axis_rx_tlast),
    .s_axis_tready (s_axis_rx_tready),
    .m_axis_tdata  (m_axis_rx_tdata),
    .m_axis_tkeep  (m_axis_rx_tkeep),
    .m_axis_tvalid (m_axis_rx_tvalid),
    .m_axis_tlast  (m_axis_rx_tlast),
    .m_axis_tready (m_axis_rx_tready),
    .idle          (rx_idle),
    .ev_frame      (rx_ev[CNT_RX_FRAMES]),
    .ev_verified   (rx_ev[CNT_RX_VERIFIED]),
    .ev_ip_bad     (rx_ev[CNT_RX_IP_BAD]),
    .ev_l4_bad     (rx_ev[CNT_RX_L4_BAD]),
    .ev_unverified (rx_ev[CNT_RX_UNVERIFIED])
  );

endmodule
