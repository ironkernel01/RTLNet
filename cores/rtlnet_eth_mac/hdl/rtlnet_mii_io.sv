// -----------------------------------------------------------------------------
// File: rtlnet_mii_io.sv
// Purpose: IronKernel RTLNet vendor-neutral SDR MII to GMII byte conversion.
// Overview: low-first nibble TX with one byte enable every two PHY clocks;
//   RX aligns on SFD regardless of preamble parity, ORs nibble errors and
//   marks a dangling final nibble bad. No DDR or vendor primitive is used.
// Language: SystemVerilog-2012, source-available.
// Revision: 11-14-2026
//   * 11-14-2026: add SDR MII nibble pairing and transmit serialization.
// Clocks: mii_rx_clk and mii_tx_clk, both PHY-sourced (25 or 2.5 MHz).
// -----------------------------------------------------------------------------
module rtlnet_mii_io (
  // PHY receive domain, synchronous active-low reset; SDR inputs.
  input logic mii_rx_clk,
  input logic rx_resetn,
  input logic [3:0] mii_rxd,
  input logic mii_rx_dv,
  input logic mii_rx_er,
  output logic [7:0] gmii_rxd,
  output logic gmii_rx_dv,
  output logic gmii_rx_er,
  output logic gmii_rx_ce,
  // PHY transmit domain, synchronous active-low reset; byte engine interface.
  input logic mii_tx_clk,
  input logic tx_resetn,
  input logic [7:0] gmii_txd,
  input logic gmii_tx_en,
  output logic tx_ce,
  // SDR outputs launch after a rising edge and are sampled on the next rising edge.
  output logic [3:0] mii_txd,
  output logic mii_tx_en
);
  localparam logic [3:0] NIB_PREAMBLE = 4'h5;
  localparam logic [3:0] NIB_SFD_HIGH = 4'hD;
  logic [3:0] rx_nib_a;
  logic rx_dv_a;
  logic rx_er_a;
  logic rx_aligned;
  logic rx_have_lo;
  logic [3:0] rx_lo_nib;
  logic rx_lo_er;
  logic [3:0] rx_prev_nib;
  logic rx_prev_ok;
  logic rx_pre_er;
  logic tx_high;
  // The engine advances while the previous byte's high nibble is emitted.
  assign tx_ce = tx_high;
  // Alternate low and high nibble; the byte remains stable between enables.
  always_ff @(posedge mii_tx_clk) begin
    if (!tx_resetn) begin
      tx_high <= 1'b0;
      mii_txd <= '0;
      mii_tx_en <= 1'b0;
    end else begin
      tx_high <= !tx_high;
      mii_txd <= tx_high ? gmii_txd[7:4] : gmii_txd[3:0];
      mii_tx_en <= gmii_tx_en;
    end
  end
  // Sample and align on the SFD, preserving errors from either nibble and preamble.
  always_ff @(posedge mii_rx_clk) begin
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
      rx_nib_a <= mii_rxd;
      rx_dv_a  <= mii_rx_dv;
      rx_er_a  <= mii_rx_er;
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

endmodule
