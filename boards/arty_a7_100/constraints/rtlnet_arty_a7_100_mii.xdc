# -----------------------------------------------------------------------------
# File: rtlnet_arty_a7_100_mii.xdc
# Purpose: clocks, interface timing and I/O packing of the DP83848J MII interface and the PHY reference clock output of the
#   Arty A7-100T Ethernet demo top; read by build_ethernet.tcl after synthesis (it names a cell: the ODDR u_ref_oddr), before the
#   CDC constraints and implementation.
# Overview:
#   * Clocks: mii_rx_clk (F15, SRCC) and mii_tx_clk (H16, MRCC), both outputs of the PHY, 25 MHz at 100 Mb/s and 2.5 MHz at
#     10 Mb/s; constrained at the 100 Mb/s period of 40 ns (20 ns high, DP83848 T2.4.1 and T2.5.1: 16 to 24 ns). The 10 Mb/s
#     clock of 400 ns only relaxes every path below. Both enter rtlnet_mii_clkbuf (BUFG) inside the MAC. They are not
#     grouped with any other clock: every crossing to the system clock goes through the shared primitives that
#     scripts/rtlnet_constrain_cdc.tcl bounds by cell name.
#   * Receive timing, 100 Mb/s (DP83848 SNLS250E T2.5.2): RXD, RX_DV and RX_ER change 10 to 30 ns after the rising edge of RX_CLK
#     and are sampled on the next rising edge: set_input_delay -max 30 -min 10 against mii_rx_clk. The first receive register of
#     each input (rx_nib_a, rx_dv_a, rx_er_a of rtlnet_mii_io) is packed into the I/O cell by IOB TRUE.
#   * Transmit timing, 100 Mb/s (T2.4.2, T2.4.3): TXD and TX_EN need 10 ns of setup before and 0 ns of hold after the rising edge
#     of TX_CLK: set_output_delay -max 10 -min 0 against mii_tx_clk. The last transmit registers (mii_txd, mii_tx_en of
#     rtlnet_mii_io) are in the I/O cells (IOB TRUE).
#   * 10 Mb/s: the datasheet gives a receive delay of at least 100 ns (T2.12.2), transmit setup 25 ns (T2.11.2) and hold 0 ns
#     (T2.11.3) on a 400 ns clock: more margin in both directions than the 100 Mb/s numbers above, which therefore cover it.
#   * PHY reference clock: the ODDR u_ref_oddr forwards the 25 MHz clock on eth_ref_clk (ball G18, the DP83848 X1 input): a
#     generated clock on the output port, no data timing relationship (the PHY derives its own clocks from it).
# Revision: 11-14-2026
#   * 11-14-2026: initial version.
# -----------------------------------------------------------------------------

create_clock -name mii_rx_clk -period 40.000 -waveform {0.000 20.000} [get_ports eth_rx_clk]
create_clock -name mii_tx_clk -period 40.000 -waveform {0.000 20.000} [get_ports eth_tx_clk]

# Receive: data valid 10 to 30 ns after the RX_CLK rising edge (DP83848 T2.5.2).
set_input_delay -clock mii_rx_clk -max 30.000 [get_ports {eth_rxd[*] eth_rx_dv eth_rxerr}]
set_input_delay -clock mii_rx_clk -min 10.000 [get_ports {eth_rxd[*] eth_rx_dv eth_rxerr}]

# Transmit: 10 ns setup before, 0 ns hold after the TX_CLK rising edge (DP83848 T2.4.2, T2.4.3).
set_output_delay -clock mii_tx_clk -max 10.000 [get_ports {eth_txd[*] eth_tx_en}]
set_output_delay -clock mii_tx_clk -min 0.000  [get_ports {eth_txd[*] eth_tx_en}]

# First receive register and last transmit register in the I/O cells.
set_property IOB TRUE [get_ports {eth_rxd[*] eth_rx_dv eth_rxerr eth_txd[*] eth_tx_en}]

# PHY reference clock forwarded by the ODDR u_ref_oddr (clock out of a DDR register).
create_generated_clock -name eth_ref_clk_out -source [get_pins u_ref_oddr/C] -divide_by 1 [get_ports eth_ref_clk]
