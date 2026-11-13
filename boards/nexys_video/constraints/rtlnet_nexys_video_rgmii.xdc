# -----------------------------------------------------------------------------
# File: rtlnet_nexys_video_rgmii.xdc
# Purpose: RGMII interface timing of the Nexys Video network build (MAC
#   rtlnet_eth_mac, pin layer u_mac/u_rgmii_io = rtlnet_rgmii_io_amd7) against
#   the RTL8211E. Read by build_bitstream.tcl after synthesis, network build
#   only (the CPU-only build reads rtlnet_nexys_video_cpu_only.xdc instead).
# Overview (from the MAC's "Board constraints", cores/rtlnet_eth_mac/
#   documentation/rtlnet_eth_mac.md section 6):
#   * Receive: rgmii_rxc 8 ns on eth_rxck (1000 Mb/s, the tightest case; the
#     BUFIO/BUFR clocks derive from it) and the virtual launch clock
#     rgmii_rxc_v. PHY RX delay on (set by the firmware through MDIO), so the
#     data is centred on RXC: RTL8211E Rev. 1.6 Table 65 setup/hold >= 1.2 ns.
#     Same-edge capture (IDDR SAME_EDGE_PIPELINED): multicycle 0/-1 and false
#     paths for the edge pairs that describe no capture.
#   * Transmit: rgmii_txc generated on eth_txck from the TXC ODDR on
#     clk125_90 (u_mac/u_rgmii_io/u_txc_oddr), output delays +-1.0 ns (PHY TX
#     delay off, receiver setup/hold 1.0 ns); TXC is 2 ns after each data edge.
#   * IDELAYE2 and IDELAYCTRL in one IODELAY group. IOB packing: IDDR/ODDR
#     are ILOGIC/OLOGIC cells, in the IOB by construction (no IOB property).
#   * Slew FAST on the transmit pins (2.5 V bank 13).
#   * No clock groups: rgmii_rxc, rx_clk and the MMCM clocks meet only in the
#     RTLNet crossing primitives bounded by scripts/rtlnet_constrain_cdc.tcl.
#   * eth_mdc/eth_mdio/eth_rst_b/eth_int_b stay false paths
#     (rtlnet_nexys_video.xdc): bit-banged management and slow side band.
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------

set_property SLEW FAST [get_ports {eth_txck eth_txctl eth_txd[*]}]

# ---- Receive clock and the PHY's launch clock --------------------------------
create_clock -name rgmii_rxc -period 8.000 [get_ports eth_rxck]
create_clock -name rgmii_rxc_v -period 8.000

# ---- Input delays (PHY RX delay on, TsetupT/TholdT >= 1.2 ns) ------------------
set_input_delay -clock rgmii_rxc_v -max -1.200 [get_ports {eth_rxd[*] eth_rxctl}]
set_input_delay -clock rgmii_rxc_v -min -2.800 [get_ports {eth_rxd[*] eth_rxctl}]
set_input_delay -clock rgmii_rxc_v -clock_fall -max -1.200 -add_delay [get_ports {eth_rxd[*] eth_rxctl}]
set_input_delay -clock rgmii_rxc_v -clock_fall -min -2.800 -add_delay [get_ports {eth_rxd[*] eth_rxctl}]

# ---- Same-edge capture -----------------------------------------------------------
set_multicycle_path -setup 0  -from [get_clocks rgmii_rxc_v] -to [get_clocks rgmii_rxc]
set_multicycle_path -hold  -1 -from [get_clocks rgmii_rxc_v] -to [get_clocks rgmii_rxc]
set_false_path -setup -rise_from [get_clocks rgmii_rxc_v] -fall_to [get_clocks rgmii_rxc]
set_false_path -setup -fall_from [get_clocks rgmii_rxc_v] -rise_to [get_clocks rgmii_rxc]
set_false_path -hold  -rise_from [get_clocks rgmii_rxc_v] -rise_to [get_clocks rgmii_rxc]
set_false_path -hold  -fall_from [get_clocks rgmii_rxc_v] -fall_to [get_clocks rgmii_rxc]

# ---- Forwarded TXC ---------------------------------------------------------------
create_generated_clock -name rgmii_txc -multiply_by 1 -source [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ */u_rgmii_io/u_txc_oddr}] -filter {REF_PIN_NAME == C}] [get_ports eth_txck]

# ---- Output delays (PHY TX delay off, receiver setup/hold 1.0 ns) -----------------
set_output_delay -clock rgmii_txc -max  1.000 [get_ports {eth_txd[*] eth_txctl}]
set_output_delay -clock rgmii_txc -min -1.000 [get_ports {eth_txd[*] eth_txctl}]
set_output_delay -clock rgmii_txc -clock_fall -max  1.000 -add_delay [get_ports {eth_txd[*] eth_txctl}]
set_output_delay -clock rgmii_txc -clock_fall -min -1.000 -add_delay [get_ports {eth_txd[*] eth_txctl}]

# ---- IODELAY group ------------------------------------------------------------------
set_property IODELAY_GROUP rtlnet_rgmii [get_cells -hierarchical -filter {NAME =~ */u_rgmii_io/u_idelayctrl}]
set_property IODELAY_GROUP rtlnet_rgmii [get_cells -hierarchical -filter {NAME =~ */u_rgmii_io/*u_rxd_idelay}]
set_property IODELAY_GROUP rtlnet_rgmii [get_cells -hierarchical -filter {NAME =~ */u_rgmii_io/u_rx_ctl_idelay}]
