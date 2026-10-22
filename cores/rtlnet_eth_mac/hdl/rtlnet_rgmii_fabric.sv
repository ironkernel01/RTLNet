// -----------------------------------------------------------------------------
// File: rtlnet_rgmii_fabric.sv
// Purpose: the technology-independent fabric logic of every RTLNet RGMII pin
//   layer (rtlnet_rgmii_io_<family>): RGMII nibble pairs to GMII bytes at the
//   three speeds, the in-band status decode, the transmit byte clock enable,
//   the per-edge transmit data and the transmit clock pattern. The pin layer
//   wraps it with its family's DDR input/output registers and clock buffers.
// Overview:
//   * Speed codes (tx_speed, rx_speed): 00 = 10, 01 = 100, 10 = 1000 Mb/s
//     (RTL8211E PHYSR 17.15:14); 11 is reserved and treated as 1000.
//   * RX input: rxd_q1/rxctl_q1 = the RXC rising-edge sample, rxd_q2/rxctl_q2
//     = the falling-edge sample of the same RXC cycle, both presented on one
//     rx_clk edge (DDR input register in same-edge-pipelined mode).
//     RGMII mapping: low nibble on the rising edge, high nibble on the
//     falling edge; RX_CTL rising = RX_DV, falling = RX_DV xor RX_ER.
//   * RX at 1000 Mb/s: gmii_rxd = {q2, q1}, gmii_rx_ce = 1.
//   * RX at 10/100 Mb/s: one nibble per RXC cycle (the rising-edge sample).
//     A stage register takes the nibble, RX_DV and RX_ER, then the pairing
//     aligns on the SFD, not on the rise of RX_DV (a PHY may send an odd
//     number of preamble nibbles): a 0xD nibble right after a 0x5 nibble is
//     the SFD, delivered as the byte 0xD5 (carrying any RX_ER seen since RX_DV
//     rose); every following nibble pair (low first) is one byte with one
//     gmii_rx_ce pulse. Nothing before the SFD is delivered. RX_DV falling
//     with one nibble held delivers it as a final byte with gmii_rx_er = 1.
//     gmii_rx_ce is 1 in every RX_DV-low cycle and 0 between the two nibbles
//     of a byte.
//   * In-band status (debug only, never a frame gate): while RX_CTL is low on
//     both edges (RX_DV = 0 and RX_ER = 0) the rising-edge RXD nibble is
//     {duplex, speed[1:0], link}; the registers hold through frames and
//     through carrier-extend / low-power-idle codes. They are free-running
//     (no reset) so firmware can read them while the receive path is held in
//     reset.
//   * TX pacing (clk125): nibble period N = 5 (100) or 50 (10) cycles, byte
//     period 2N; tx_ce (registered) is high in the last cycle of each byte
//     period, constant 1 at 1000. A speed change restarts the phase counter
//     and the end compare is >=, so a change cannot hang it.
//   * TX data (clk125, one register stage before the output DDR register):
//     1000: D1 = low nibble, D2 = high nibble, TX_CTL D1 = TX_EN, D2 = TX_EN
//     xor TX_ER. 10/100: D1 = D2 = the low nibble for the first N cycles of
//     the byte period and the high nibble for the second N.
//   * TXC pattern {D1, D2} for the output DDR register on clk125_90, computed
//     and registered in clk125 (txc_pattern), then re-registered once on
//     clk125_90 (txc_pattern_90) so the 2 ns clk125 -> clk125_90 path is flop
//     to flop. 1000: 10 (125 MHz). 100: entries 0..4 = 00 11 11 10 00
//     (rising edge 10 ns = 25 % into the 40 ns nibble on the pins, falling
//     edge 30 ns = 75 %). 10: entries 13..37 = 11, else 00 (rising 106 ns =
//     26.5 %, falling 306 ns = 76.5 % of the 400 ns nibble). Derivation: a
//     nibble is on the pins from 16 ns after the first cycle of its byte
//     (gmii_txd -> txd stage -> DDR register); a pattern entry computed in
//     cycle c is on the TXC pin from 8 (c + 2) + 2 ns.
//   * The clk125_90 retiming register and the in-band registers have no
//     reset: each copies its input every clock (recovery is one clock), and a
//     declaration initializer gives the power-up value.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk125 (TX pacing and data), clk125_90 (TXC retiming register only;
//   same MMCM as clk125, 90 degrees), rx_clk (the PHY's RXC through the pin
//   layer's regional buffer; stops on link loss).
// -----------------------------------------------------------------------------
module rtlnet_rgmii_fabric (
  // Transmit clocks: clk125 (0 deg) with its synchronous active-low reset,
  // clk125_90 (90 deg, same MMCM) for the TXC pattern retiming register.
  input  logic       clk125,
  input  logic       clk125_resetn,
  input  logic       clk125_90,

  // Transmit speed code, clk125 domain (00 10M, 01 100M, 10/11 1000M).
  input  logic [1:0] tx_speed,

  // GMII transmit from the MAC, clk125 domain, and the byte clock enable
  // that paces it (1 at 1000, one pulse per byte period at 10/100).
  input  logic [7:0] gmii_txd,
  input  logic       gmii_tx_en,
  input  logic       gmii_tx_er,
  output logic       tx_ce,

  // Output DDR register inputs: TXD/TX_CTL per edge (clk125 registers) and
  // the TXC pattern (clk125_90 registers). D1 = rising-edge half.
  output logic [3:0] txd_d1,
  output logic [3:0] txd_d2,
  output logic       txctl_d1,
  output logic       txctl_d2,
  output logic       txc_d1,
  output logic       txc_d2,

  // Receive clock and the receive-path reset (synchronous, active low).
  input  logic       rx_clk,
  input  logic       rx_resetn,

  // Receive speed code, rx_clk domain.
  input  logic [1:0] rx_speed,

  // Input DDR register outputs, rx_clk domain: rising (q1) and falling (q2)
  // samples of one RXC cycle.
  input  logic [3:0] rxd_q1,
  input  logic [3:0] rxd_q2,
  input  logic       rxctl_q1,
  input  logic       rxctl_q2,

  // GMII receive to the MAC, rx_clk domain, registered.
  output logic [7:0] gmii_rxd,
  output logic       gmii_rx_dv,
  output logic       gmii_rx_er,
  output logic       gmii_rx_ce,

  // In-band status from the idle RXD nibble, rx_clk domain, debug only.
  output logic       inband_link,
  output logic [1:0] inband_speed,
  output logic       inband_duplex
);

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam logic [1:0] SPEED_10       = 2'b00;
  localparam logic [1:0] SPEED_100      = 2'b01;
  localparam logic [3:0] NIB_PREAMBLE   = 4'h5;   // preamble octet nibble, SFD low nibble
  localparam logic [3:0] NIB_SFD_HIGH   = 4'hD;   // SFD 0xD5 high nibble (IEEE 802.3 clause 3.2.2)
  localparam logic [5:0] NIB_CYCLES_100 = 6'd5;   // 40 ns TXC period / 8 ns
  localparam logic [5:0] NIB_CYCLES_10  = 6'd50;  // 400 ns TXC period / 8 ns
  localparam logic [5:0] TXC_RISE_100   = 6'd1;   // first high entry of the 100 Mb/s pattern
  localparam logic [5:0] TXC_HIGH2_100  = 6'd2;   // second high entry
  localparam logic [5:0] TXC_HALF_100   = 6'd3;   // high for the D1 half only
  localparam logic [5:0] TXC_RISE_10    = 6'd13;  // 10 Mb/s: high for entries 13..37
  localparam logic [5:0] TXC_FALL_10    = 6'd38;
  localparam logic [1:0] TXC_GIGABIT    = 2'b10;  // {D1, D2}: one 125 MHz cycle
  localparam logic [1:0] TXC_HIGH       = 2'b11;
  localparam logic [1:0] TXC_LOW        = 2'b00;

  // ---------------------------------------------------------------------------
  // Receive
  // ---------------------------------------------------------------------------
  logic       rx_fast;
  logic [3:0] rx_nib_a;       // stage register: rising-edge nibble
  logic       rx_dv_a;
  logic       rx_er_a;
  logic       rx_aligned;     // SFD found in this frame (10/100)
  logic       rx_have_lo;     // a low nibble is held
  logic [3:0] rx_lo_nib;
  logic       rx_lo_er;
  logic [3:0] rx_prev_nib;    // previous RX_DV nibble (SFD search)
  logic       rx_prev_ok;
  logic       rx_pre_er;      // RX_ER seen before the SFD
  logic       inband_link_r   = 1'b0;   // in-band status registers (free-running)
  logic [1:0] inband_speed_r  = 2'b00;
  logic       inband_duplex_r = 1'b0;

  // ---------------------------------------------------------------------------
  // Transmit
  // ---------------------------------------------------------------------------
  logic [1:0] tx_speed_q;
  logic [5:0] tx_nib_ph;      // clk125 cycles into the nibble period
  logic       tx_hi_nib;      // second (high) nibble of the byte
  logic       tx_fast;
  logic       tx_restart;
  logic [5:0] tx_nib_last;
  logic       tx_ph_end;
  logic [5:0] tx_nib_ph_next;
  logic       tx_hi_nib_next;
  logic [3:0] tx_nib_sel;
  logic [1:0] txc_pattern;                      // clk125
  logic [1:0] txc_pattern_90 = TXC_GIGABIT;     // clk125_90 retiming register (free-running)

  assign rx_fast = rx_speed[1];

  // GMII reconstruction: direct DDR pairs at 1000, SFD-aligned nibble pairing
  // at 10/100.
  always_ff @(posedge rx_clk) begin
    if (!rx_resetn) begin
      rx_nib_a    <= '0;
      rx_dv_a     <= 1'b0;
      rx_er_a     <= 1'b0;
      rx_aligned  <= 1'b0;
      rx_have_lo  <= 1'b0;
      rx_lo_nib   <= '0;
      rx_lo_er    <= 1'b0;
      rx_prev_nib <= '0;
      rx_prev_ok  <= 1'b0;
      rx_pre_er   <= 1'b0;
      gmii_rxd    <= '0;
      gmii_rx_dv  <= 1'b0;
      gmii_rx_er  <= 1'b0;
      gmii_rx_ce  <= 1'b1;
    end else begin
      rx_nib_a <= rxd_q1;
      rx_dv_a  <= rxctl_q1;
      rx_er_a  <= rxctl_q1 ^ rxctl_q2;
      if (rx_fast) begin
        gmii_rxd   <= {rxd_q2, rxd_q1};
        gmii_rx_dv <= rxctl_q1;
        gmii_rx_er <= rxctl_q1 ^ rxctl_q2;
        gmii_rx_ce <= 1'b1;
        rx_aligned <= 1'b0;
        rx_have_lo <= 1'b0;
        rx_prev_ok <= 1'b0;
        rx_pre_er  <= 1'b0;
      end else begin
        gmii_rx_ce <= 1'b1;
        gmii_rx_dv <= 1'b0;
        gmii_rx_er <= 1'b0;
        if (rx_dv_a) begin
          rx_prev_nib <= rx_nib_a;
          rx_prev_ok  <= 1'b1;
          if (!rx_aligned) begin
            rx_pre_er <= rx_pre_er || rx_er_a;
            if (rx_prev_ok && (rx_prev_nib == NIB_PREAMBLE) && (rx_nib_a == NIB_SFD_HIGH)) begin
              rx_aligned <= 1'b1;
              rx_have_lo <= 1'b0;
              gmii_rxd   <= {rx_nib_a, rx_prev_nib};
              gmii_rx_dv <= 1'b1;
              gmii_rx_er <= rx_pre_er || rx_er_a;
            end
          end else if (!rx_have_lo) begin
            rx_lo_nib  <= rx_nib_a;
            rx_lo_er   <= rx_er_a;
            rx_have_lo <= 1'b1;
            gmii_rx_ce <= 1'b0;
          end else begin
            gmii_rxd   <= {rx_nib_a, rx_lo_nib};
            gmii_rx_dv <= 1'b1;
            gmii_rx_er <= rx_lo_er || rx_er_a;
            rx_have_lo <= 1'b0;
          end
        end else begin
          rx_aligned <= 1'b0;
          rx_have_lo <= 1'b0;
          rx_prev_ok <= 1'b0;
          rx_pre_er  <= 1'b0;
          if (rx_aligned && rx_have_lo) begin
            gmii_rxd   <= {NIB_PREAMBLE, rx_lo_nib};
            gmii_rx_dv <= 1'b1;
            gmii_rx_er <= 1'b1;
          end
        end
      end
    end
  end

  // In-band status: sampled only on a normal idle (RX_CTL low on both edges).
  always_ff @(posedge rx_clk) begin
    if (!rxctl_q1 && !rxctl_q2) begin
      inband_link_r   <= rxd_q1[0];
      inband_speed_r  <= rxd_q1[2:1];
      inband_duplex_r <= rxd_q1[3];
    end
  end

  assign inband_link   = inband_link_r;
  assign inband_speed  = inband_speed_r;
  assign inband_duplex = inband_duplex_r;

  // ---------------------------------------------------------------------------
  // Transmit pacing
  // ---------------------------------------------------------------------------
  assign tx_fast        = tx_speed[1];
  assign tx_restart     = tx_fast || (tx_speed != tx_speed_q);
  assign tx_nib_last    = (tx_speed == SPEED_10) ? (NIB_CYCLES_10 - 6'd1) : (NIB_CYCLES_100 - 6'd1);
  assign tx_ph_end      = (tx_nib_ph >= tx_nib_last);
  assign tx_nib_ph_next = (tx_restart || tx_ph_end) ? 6'd0 : (tx_nib_ph + 6'd1);
  assign tx_hi_nib_next = tx_restart ? 1'b0 : (tx_ph_end ? !tx_hi_nib : tx_hi_nib);
  assign tx_nib_sel     = tx_hi_nib ? gmii_txd[7:4] : gmii_txd[3:0];

  // Phase counter and byte clock enable.
  always_ff @(posedge clk125) begin
    if (!clk125_resetn) begin
      tx_speed_q <= 2'b10;
      tx_nib_ph  <= '0;
      tx_hi_nib  <= 1'b0;
      tx_ce      <= 1'b1;
    end else begin
      tx_speed_q <= tx_speed;
      tx_nib_ph  <= tx_nib_ph_next;
      tx_hi_nib  <= tx_hi_nib_next;
      tx_ce      <= tx_fast || (tx_hi_nib_next && (tx_nib_ph_next >= tx_nib_last));
    end
  end

  // Per-edge transmit data, one clk125 stage ahead of the output register.
  always_ff @(posedge clk125) begin
    if (!clk125_resetn) begin
      txd_d1   <= '0;
      txd_d2   <= '0;
      txctl_d1 <= 1'b0;
      txctl_d2 <= 1'b0;
    end else begin
      txd_d1   <= tx_fast ? gmii_txd[3:0] : tx_nib_sel;
      txd_d2   <= tx_fast ? gmii_txd[7:4] : tx_nib_sel;
      txctl_d1 <= gmii_tx_en;
      txctl_d2 <= gmii_tx_en ^ gmii_tx_er;
    end
  end

  // TXC pattern, computed and registered in clk125.
  always_ff @(posedge clk125) begin
    if (!clk125_resetn) begin
      txc_pattern <= TXC_GIGABIT;
    end else if (tx_fast) begin
      txc_pattern <= TXC_GIGABIT;
    end else if (tx_speed == SPEED_100) begin
      if (tx_nib_ph == TXC_RISE_100 || tx_nib_ph == TXC_HIGH2_100) txc_pattern <= TXC_HIGH;
      else if (tx_nib_ph == TXC_HALF_100)                          txc_pattern <= TXC_GIGABIT;
      else                                                         txc_pattern <= TXC_LOW;
    end else begin
      txc_pattern <= ((tx_nib_ph >= TXC_RISE_10) && (tx_nib_ph < TXC_FALL_10)) ? TXC_HIGH : TXC_LOW;
    end
  end

  // Retiming register on clk125_90: the only driver of the TXC output register.
  always_ff @(posedge clk125_90) begin
    txc_pattern_90 <= txc_pattern;
  end

  assign txc_d1 = txc_pattern_90[1];
  assign txc_d2 = txc_pattern_90[0];

endmodule
