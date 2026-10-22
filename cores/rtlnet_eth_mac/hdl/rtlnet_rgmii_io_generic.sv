// -----------------------------------------------------------------------------
// File: rtlnet_rgmii_io_generic.sv
// Purpose: behavioural RGMII pin layer of the RTLNet MAC for the GENERIC
//   technology (simulation, ASIC front end), selected by `RTLNET_RGMII_IO
//   when RTLNET_TECH_GENERIC is defined. Same ports and parameter as
//   rtlnet_rgmii_io_amd7; no vendor primitive.
// Overview:
//   * rx_clk is rgmii_rxc itself (no clock buffer model, no delay element);
//     the PHY's internal RX delay centres RXC on the data, as on hardware.
//   * DDR input register (same-edge pipelined): the rising-edge sample and
//     the falling-edge sample of one RXC cycle appear on q1/q2 at the next
//     rising edge, the same latency as the AMD IDDR in SAME_EDGE_PIPELINED.
//   * DDR output register (same edge): D1 and D2 are registered on the
//     rising edge; the output is D1 for the high phase and D2 for the low
//     phase. Built as a rising-edge and a falling-edge register combined by
//     XOR, so no clock is used as data. TXD/TX_CTL are held low while
//     clk125_resetn is low; TXC is free-running.
//   * The negative-edge registers are the DDR input/output exception of the
//     coding rules (negative edges only for DDR I/O). RX_IDELAY_TAP is
//     accepted and has no effect; idelay_rdy rises one clk200 clock after
//     clk200_resetn releases.
//   * The fabric logic is rtlnet_rgmii_fabric, shared with every family.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk125, clk125_90, clk200, rx_clk (output: rgmii_rxc).
// -----------------------------------------------------------------------------
module rtlnet_rgmii_io_generic #(
  parameter int RX_IDELAY_TAP = 12                 // accepted for port compatibility, no effect
)(
  // Transmit clocks from one MMCM: clk125 (0 deg) with its synchronous
  // active-low reset, clk125_90 (90 deg) for the forwarded TXC.
  input  logic       clk125,
  input  logic       clk125_resetn,
  input  logic       clk125_90,

  // Delay-controller reference clock and its synchronous active-low reset.
  input  logic       clk200,
  input  logic       clk200_resetn,

  // Speed codes (00 10M, 01 100M, 10 1000M): tx_speed in clk125, rx_speed in
  // rx_clk.
  input  logic [1:0] tx_speed,
  input  logic [1:0] rx_speed,

  // RGMII pins (RXC centred on RXD/RX_CTL; TXC 2 ns after TXD/TX_CTL).
  input  logic       rgmii_rxc,
  input  logic [3:0] rgmii_rxd,
  input  logic       rgmii_rx_ctl,
  output logic       rgmii_txc,
  output logic [3:0] rgmii_txd,
  output logic       rgmii_tx_ctl,

  // Receive clock out and the receive-path reset (synchronous, active low).
  output logic       rx_clk,
  input  logic       rx_resetn,

  // GMII receive to the MAC, rx_clk domain; in-band status debug only.
  output logic [7:0] gmii_rxd,
  output logic       gmii_rx_dv,
  output logic       gmii_rx_er,
  output logic       gmii_rx_ce,
  output logic       inband_link,
  output logic [1:0] inband_speed,
  output logic       inband_duplex,

  // Delay-controller ready (clk200 register).
  output logic       idelay_rdy,

  // GMII transmit from the MAC, clk125 domain, and its byte clock enable.
  input  logic [7:0] gmii_txd,
  input  logic       gmii_tx_en,
  input  logic       gmii_tx_er,
  output logic       tx_ce
);

  // ---------------------------------------------------------------------------
  // Signals
  // ---------------------------------------------------------------------------
  logic [4:0] rx_rise   = '0;    // {rx_ctl, rxd} sampled on the RXC rising edge
  logic [4:0] rx_fall   = '0;    // sampled on the RXC falling edge
  logic [4:0] rx_q1     = '0;    // pipelined pair, presented on the rising edge
  logic [4:0] rx_q2     = '0;
  logic [4:0] tx_rise   = '0;    // {tx_ctl, txd}: rising-edge register of the XOR DDR output
  logic [4:0] tx_d2_hold = '0;   // D2 captured on the rising edge
  logic [4:0] tx_fall   = '0;    // falling-edge register of the XOR DDR output
  logic       txc_rise  = 1'b0;
  logic       txc_d2_hold = 1'b0;
  logic       txc_fall  = 1'b0;
  logic       idelay_rdy_r = 1'b0;
  logic [3:0] txd_d1;
  logic [3:0] txd_d2;
  logic       txctl_d1;
  logic       txctl_d2;
  logic       txc_d1;
  logic       txc_d2;

  assign rx_clk = rgmii_rxc;

  // DDR input register, rising half: sample, then present the pair.
  always_ff @(posedge rgmii_rxc) begin
    rx_rise <= {rgmii_rx_ctl, rgmii_rxd};
    rx_q1   <= rx_rise;
    rx_q2   <= rx_fall;
  end

  // DDR input register, falling half (DDR I/O negative-edge exception).
  always_ff @(negedge rgmii_rxc) begin
    rx_fall <= {rgmii_rx_ctl, rgmii_rxd};
  end

  // Delay-controller ready stand-in.
  always_ff @(posedge clk200) begin
    if (!clk200_resetn) idelay_rdy_r <= 1'b0;
    else                idelay_rdy_r <= 1'b1;
  end

  assign idelay_rdy = idelay_rdy_r;

  // Fabric logic shared by every family's pin layer.
  rtlnet_rgmii_fabric u_fabric (
    .clk125        (clk125),
    .clk125_resetn (clk125_resetn),
    .clk125_90     (clk125_90),
    .tx_speed      (tx_speed),
    .gmii_txd      (gmii_txd),
    .gmii_tx_en    (gmii_tx_en),
    .gmii_tx_er    (gmii_tx_er),
    .tx_ce         (tx_ce),
    .txd_d1        (txd_d1),
    .txd_d2        (txd_d2),
    .txctl_d1      (txctl_d1),
    .txctl_d2      (txctl_d2),
    .txc_d1        (txc_d1),
    .txc_d2        (txc_d2),
    .rx_clk        (rx_clk),
    .rx_resetn     (rx_resetn),
    .rx_speed      (rx_speed),
    .rxd_q1        (rx_q1[3:0]),
    .rxd_q2        (rx_q2[3:0]),
    .rxctl_q1      (rx_q1[4]),
    .rxctl_q2      (rx_q2[4]),
    .gmii_rxd      (gmii_rxd),
    .gmii_rx_dv    (gmii_rx_dv),
    .gmii_rx_er    (gmii_rx_er),
    .gmii_rx_ce    (gmii_rx_ce),
    .inband_link   (inband_link),
    .inband_speed  (inband_speed),
    .inband_duplex (inband_duplex)
  );

  // DDR output register for TXD/TX_CTL, rising half: q = rise ^ fall = D1.
  always_ff @(posedge clk125) begin
    if (!clk125_resetn) begin
      tx_rise    <= tx_fall;
      tx_d2_hold <= '0;
    end else begin
      tx_rise    <= {txctl_d1, txd_d1} ^ tx_fall;
      tx_d2_hold <= {txctl_d2, txd_d2};
    end
  end

  // Falling half: q = rise ^ fall = D2 (DDR I/O negative-edge exception).
  always_ff @(negedge clk125) begin
    tx_fall <= tx_d2_hold ^ tx_rise;
  end

  assign {rgmii_tx_ctl, rgmii_txd} = tx_rise ^ tx_fall;

  // DDR output register for TXC on clk125_90 (free-running).
  always_ff @(posedge clk125_90) begin
    txc_rise    <= txc_d1 ^ txc_fall;
    txc_d2_hold <= txc_d2;
  end

  always_ff @(negedge clk125_90) begin
    txc_fall <= txc_d2_hold ^ txc_rise;
  end

  assign rgmii_txc = txc_rise ^ txc_fall;

endmodule
