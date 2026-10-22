// -----------------------------------------------------------------------------
// File: rtlnet_rgmii_io_amd7.sv
// Purpose: RGMII pin layer of the RTLNet MAC for AMD 7-series devices
//   (selected by `RTLNET_RGMII_IO in rtlnet_technology.svh). The only RTLNet
//   MAC file with vendor primitives: IBUF, BUFIO, BUFR, IDELAYCTRL, IDELAYE2,
//   IDDR and ODDR. The fabric logic (nibble pairing, in-band decode, transmit
//   pacing, TXC pattern) is rtlnet_rgmii_fabric, shared with every family.
// Overview:
//   * Receive clock: rgmii_rxc -> IBUF -> BUFIO (the five IDDR clock pins
//     only) and -> BUFR (bypass) = rx_clk, the fabric receive clock. No delay
//     element and no MMCM on the clock: RXC stops on link loss, and BUFIO and
//     BUFR from one IBUF are phase-related, so the IDDR-to-fabric hand-off is
//     an ordinary timed path. RXC must use a clock-capable pin in the bank of
//     RXD/RX_CTL, and every rx_clk register places in that clock region.
//   * Receive data: rgmii_rxd[3:0] / rgmii_rx_ctl -> IBUF -> IDELAYE2 (FIXED,
//     RX_IDELAY_TAP taps, 200 MHz reference, about 78 ps per tap) -> IDDR
//     (SAME_EDGE_PIPELINED: rising and falling samples of one RXC cycle on Q1
//     and Q2 at the same edge).
//   * Receive timing relies on the PHY's internal RX clock delay (RTL8211E
//     extension page 0xA4 register 28, enabled by the MDIO driver): RXD/RX_CTL
//     arrive centred on RXC (datasheet Rev. 1.6 Table 65: data to clock output
//     setup and hold at least 1.2 ns each with the integrated delay). The data
//     tap balances the BUFIO insertion; it is a parameter so a rebuild retunes
//     it from STA.
//   * IDELAYCTRL: reference clk200; its RST is the vendor's active-high
//     polarity, inverted at this instance (named exception); RDY is the
//     idelay_rdy output (IDELAYE2 delays are valid only while RDY is high).
//   * Transmit: TXD/TX_CTL leave through ODDR (SAME_EDGE) on clk125 from the
//     fabric's per-edge registers, held in output reset while clk125_resetn
//     is low (R = !clk125_resetn, the vendor's active-high polarity). TXC
//     leaves through an ODDR on clk125_90 whose D1/D2 come only from the
//     fabric's clk125_90 retiming register; it is free-running (R = 0) so the
//     PHY receiver stays locked independent of the MAC reset. At 1000 Mb/s
//     TXC is 2 ns (90 degrees) after the data edges, the whole TX skew (PHY TX
//     delay off); at 10/100 TXC is the fabric's pattern.
//   * Simulation-only RXC insertion: the unisim IBUF/BUFIO/BUFR models have
//     no delay while the unisim IDELAYE2 adds 600 ps + 78 ps per tap (1.536 ns
//     at tap 12), so the IDDR clock would sit 0.464 ns after the data change
//     instead of on the eye centre. Defining RTLNET_SIM_RXC_INSERTION_NS
//     (nanoseconds, bench command line only) delays the IDDR clock alone by
//     that amount; rx_clk stays undelayed so the fabric registers take the
//     previous IDDR output, as the timed hardware path does. Synthesis never
//     defines the macro and uses the plain BUFIO output.
// Language: SystemVerilog-2012; AMD 7-series UNISIM primitives.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk125 (TX data ODDR, fabric pacing), clk125_90 (TXC ODDR and its
//   retiming register), clk200 (IDELAYCTRL), rx_clk (output: BUFR of RXC).
// -----------------------------------------------------------------------------
module rtlnet_rgmii_io_amd7 #(
  parameter int RX_IDELAY_TAP = 12                 // RXD/RX_CTL IDELAYE2 fixed tap, 0..31
)(
  // Transmit clocks from one MMCM: clk125 (0 deg) with its synchronous
  // active-low reset, clk125_90 (90 deg) for the forwarded TXC.
  input  logic       clk125,
  input  logic       clk125_resetn,
  input  logic       clk125_90,

  // IDELAYCTRL reference clock (200 MHz) and its synchronous active-low reset.
  input  logic       clk200,
  input  logic       clk200_resetn,

  // Speed codes (00 10M, 01 100M, 10 1000M): tx_speed in clk125, rx_speed in
  // rx_clk. Set by firmware from PHYSR, never from the in-band status.
  input  logic [1:0] tx_speed,
  input  logic [1:0] rx_speed,

  // RGMII pins to the Realtek RTL8211E (2.5 V bank). RXC arrives centred on
  // RXD/RX_CTL (PHY RX delay on); TXC leaves 2 ns after TXD/TX_CTL (PHY TX
  // delay off).
  input  logic       rgmii_rxc,
  input  logic [3:0] rgmii_rxd,
  input  logic       rgmii_rx_ctl,
  output logic       rgmii_txc,
  output logic [3:0] rgmii_txd,
  output logic       rgmii_tx_ctl,

  // Receive clock out (BUFR of RXC) and the receive-path reset, synchronous
  // to rx_clk, active low.
  output logic       rx_clk,
  input  logic       rx_resetn,

  // GMII receive to the MAC, rx_clk domain, registered; gmii_rx_ce is the
  // byte clock enable. In-band status is debug only.
  output logic [7:0] gmii_rxd,
  output logic       gmii_rx_dv,
  output logic       gmii_rx_er,
  output logic       gmii_rx_ce,
  output logic       inband_link,
  output logic [1:0] inband_speed,
  output logic       inband_duplex,

  // IDELAYCTRL ready (clk200-derived level; the MAC synchronizes it).
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
  logic       rxc_ibuf;
  logic       rxc_bufio;
  logic       rxc_iddr;          // IDDR clock: BUFIO output (plus the simulation insertion)
  logic [3:0] rxd_ibuf;
  logic [3:0] rxd_dly;
  logic [3:0] rxd_q1;
  logic [3:0] rxd_q2;
  logic       rxctl_ibuf;
  logic       rxctl_dly;
  logic       rxctl_q1;
  logic       rxctl_q2;
  logic [3:0] txd_d1;
  logic [3:0] txd_d2;
  logic       txctl_d1;
  logic       txctl_d2;
  logic       txc_d1;
  logic       txc_d2;

  // ---------------------------------------------------------------------------
  // Receive clock: IBUF -> BUFIO (IDDR clock) and IBUF -> BUFR (rx_clk).
  // ---------------------------------------------------------------------------
  IBUF u_rxc_ibuf (
    .I (rgmii_rxc),
    .O (rxc_ibuf)
  );

  BUFIO u_rxc_bufio (
    .I (rxc_ibuf),
    .O (rxc_bufio)
  );

  // Regional fabric clock, no division; CE/CLR at their pass-through values.
  BUFR #(
    .BUFR_DIVIDE ("BYPASS"),
    .SIM_DEVICE  ("7SERIES")
  ) u_rxc_bufr (
    .I   (rxc_ibuf),
    .CE  (1'b1),
    .CLR (1'b0),
    .O   (rx_clk)
  );

`ifdef RTLNET_SIM_RXC_INSERTION_NS
  // Simulation only (header): BUFIO insertion missing from the unisim models.
  assign #(`RTLNET_SIM_RXC_INSERTION_NS) rxc_iddr = rxc_bufio;
`else
  assign rxc_iddr = rxc_bufio;
`endif

  // ---------------------------------------------------------------------------
  // IDELAYCTRL for the bank's IDELAYE2 instances (active-high RST inverted
  // here: the one polarity exception of this file).
  // ---------------------------------------------------------------------------
  IDELAYCTRL u_idelayctrl (
    .REFCLK (clk200),
    .RST    (!clk200_resetn),
    .RDY    (idelay_rdy)
  );

  // ---------------------------------------------------------------------------
  // Receive data lanes: IBUF -> IDELAYE2 (fixed tap) -> IDDR.
  // ---------------------------------------------------------------------------
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi++) begin : g_rxd
      IBUF u_rxd_ibuf (
        .I (rgmii_rxd[gi]),
        .O (rxd_ibuf[gi])
      );

      // Fixed data delay balancing the BUFIO clock insertion.
      IDELAYE2 #(
        .IDELAY_TYPE           ("FIXED"),
        .IDELAY_VALUE          (RX_IDELAY_TAP),
        .DELAY_SRC             ("IDATAIN"),
        .HIGH_PERFORMANCE_MODE ("TRUE"),
        .SIGNAL_PATTERN        ("DATA"),
        .REFCLK_FREQUENCY      (200.0),
        .PIPE_SEL              ("FALSE"),
        .CINVCTRL_SEL          ("FALSE")
      ) u_rxd_idelay (
        .C           (clk200),
        .REGRST      (1'b0),
        .LD          (1'b0),
        .CE          (1'b0),
        .INC         (1'b0),
        .CINVCTRL    (1'b0),
        .CNTVALUEIN  (5'd0),
        .IDATAIN     (rxd_ibuf[gi]),
        .DATAIN      (1'b0),
        .LDPIPEEN    (1'b0),
        .DATAOUT     (rxd_dly[gi]),
        .CNTVALUEOUT ()
      );

      // Rising (Q1) and falling (Q2) samples of one RXC cycle on one edge.
      IDDR #(
        .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED"),
        .INIT_Q1      (1'b0),
        .INIT_Q2      (1'b0),
        .SRTYPE       ("SYNC")
      ) u_rxd_iddr (
        .C  (rxc_iddr),
        .CE (1'b1),
        .S  (1'b0),
        .R  (1'b0),
        .D  (rxd_dly[gi]),
        .Q1 (rxd_q1[gi]),
        .Q2 (rxd_q2[gi])
      );
    end
  endgenerate

  IBUF u_rx_ctl_ibuf (
    .I (rgmii_rx_ctl),
    .O (rxctl_ibuf)
  );

  // RX_CTL lane, same delay and capture as the data lanes.
  IDELAYE2 #(
    .IDELAY_TYPE           ("FIXED"),
    .IDELAY_VALUE          (RX_IDELAY_TAP),
    .DELAY_SRC             ("IDATAIN"),
    .HIGH_PERFORMANCE_MODE ("TRUE"),
    .SIGNAL_PATTERN        ("DATA"),
    .REFCLK_FREQUENCY      (200.0),
    .PIPE_SEL              ("FALSE"),
    .CINVCTRL_SEL          ("FALSE")
  ) u_rx_ctl_idelay (
    .C           (clk200),
    .REGRST      (1'b0),
    .LD          (1'b0),
    .CE          (1'b0),
    .INC         (1'b0),
    .CINVCTRL    (1'b0),
    .CNTVALUEIN  (5'd0),
    .IDATAIN     (rxctl_ibuf),
    .DATAIN      (1'b0),
    .LDPIPEEN    (1'b0),
    .DATAOUT     (rxctl_dly),
    .CNTVALUEOUT ()
  );

  IDDR #(
    .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED"),
    .INIT_Q1      (1'b0),
    .INIT_Q2      (1'b0),
    .SRTYPE       ("SYNC")
  ) u_rx_ctl_iddr (
    .C  (rxc_iddr),
    .CE (1'b1),
    .S  (1'b0),
    .R  (1'b0),
    .D  (rxctl_dly),
    .Q1 (rxctl_q1),
    .Q2 (rxctl_q2)
  );

  // ---------------------------------------------------------------------------
  // Fabric logic shared by every family's pin layer.
  // ---------------------------------------------------------------------------
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
    .rxd_q1        (rxd_q1),
    .rxd_q2        (rxd_q2),
    .rxctl_q1      (rxctl_q1),
    .rxctl_q2      (rxctl_q2),
    .gmii_rxd      (gmii_rxd),
    .gmii_rx_dv    (gmii_rx_dv),
    .gmii_rx_er    (gmii_rx_er),
    .gmii_rx_ce    (gmii_rx_ce),
    .inband_link   (inband_link),
    .inband_speed  (inband_speed),
    .inband_duplex (inband_duplex)
  );

  // ---------------------------------------------------------------------------
  // Transmit: TXD / TX_CTL ODDR on clk125, TXC ODDR on clk125_90.
  // ---------------------------------------------------------------------------
  generate
    for (gi = 0; gi < 4; gi++) begin : g_txd
      ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
      ) u_txd_oddr (
        .C  (clk125),
        .CE (1'b1),
        .S  (1'b0),
        .R  (!clk125_resetn),
        .D1 (txd_d1[gi]),
        .D2 (txd_d2[gi]),
        .Q  (rgmii_txd[gi])
      );
    end
  endgenerate

  ODDR #(
    .DDR_CLK_EDGE ("SAME_EDGE"),
    .INIT         (1'b0),
    .SRTYPE       ("SYNC")
  ) u_tx_ctl_oddr (
    .C  (clk125),
    .CE (1'b1),
    .S  (1'b0),
    .R  (!clk125_resetn),
    .D1 (txctl_d1),
    .D2 (txctl_d2),
    .Q  (rgmii_tx_ctl)
  );

  // Forwarded TXC: free-running, driven only by the clk125_90 retiming register.
  ODDR #(
    .DDR_CLK_EDGE ("SAME_EDGE"),
    .INIT         (1'b0),
    .SRTYPE       ("SYNC")
  ) u_txc_oddr (
    .C  (clk125_90),
    .CE (1'b1),
    .S  (1'b0),
    .R  (1'b0),
    .D1 (txc_d1),
    .D2 (txc_d2),
    .Q  (rgmii_txc)
  );

endmodule
