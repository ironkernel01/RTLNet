# -----------------------------------------------------------------------------
# File: rtlnet_nexys_video_eth.xdc
# Purpose: pin, I/O standard, primary clock and configuration constraints of the Nexys Video Ethernet demo top
#   (rtlnet_nexys_video_eth_top); read with rtlnet_nexys_video_rgmii.xdc (RGMII timing) by build_ethernet.tcl.
# Overview:
#   * Balls and I/O standards from the Digilent Nexys-Video-Master.xdc (Rev. A), the same as rtlnet_nexys_video.xdc
#     without the DDR3 pins and without eth_pme_b (not a port of this top). Banks 15/16 run at the VADJ default of
#     1.2 V (SET_VADJ/VADJ_EN are not driven), so switches and buttons are LVCMOS12.
#   * One primary clock: sysclk 100 MHz on R4. The MMCM outputs are derived clocks Vivado creates from it; no clock
#     groups are declared.
#   * Clock-domain crossings are bounded by scripts/rtlnet_constrain_cdc.tcl (cell-name based), sourced by the build
#     after synthesis.
#   * Asynchronous board pins (buttons, switches, UART, PHY side band, LEDs, PHY reset, MDIO/MDC) have no timing
#     relationship to any internal clock: inputs enter rtlnet_sync chains or the UART oversampler, outputs are
#     register driven and slow; they are false paths here. The RGMII timing block is in rtlnet_nexys_video_rgmii.xdc.
# Revision: 11-14-2026
#   * 11-14-2026: initial version (rtlnet_nexys_video.xdc without the DDR3 section).
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Clock: 100 MHz oscillator, R4, bank 34 (3.3 V), MRCC.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN R4    IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports sysclk]

# ---------------------------------------------------------------------------
# CPU RESET button, G4, bank 35 (1.5 V), low while pressed.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN G4    IOSTANDARD LVCMOS15 } [get_ports { cpu_resetn }]

# ---------------------------------------------------------------------------
# USB-UART bridge, bank 14 (3.3 V). uart_tx_in = bridge TXD into the FPGA,
# uart_rx_out = FPGA transmit into the bridge RXD.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V18   IOSTANDARD LVCMOS33 } [get_ports { uart_tx_in }]
set_property -dict { PACKAGE_PIN AA19  IOSTANDARD LVCMOS33 } [get_ports { uart_rx_out }]

# ---------------------------------------------------------------------------
# LEDs LD0..LD7, bank 13 (2.5 V).
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN T14   IOSTANDARD LVCMOS25 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN T15   IOSTANDARD LVCMOS25 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN T16   IOSTANDARD LVCMOS25 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN U16   IOSTANDARD LVCMOS25 } [get_ports { led[3] }]
set_property -dict { PACKAGE_PIN V15   IOSTANDARD LVCMOS25 } [get_ports { led[4] }]
set_property -dict { PACKAGE_PIN W16   IOSTANDARD LVCMOS25 } [get_ports { led[5] }]
set_property -dict { PACKAGE_PIN W15   IOSTANDARD LVCMOS25 } [get_ports { led[6] }]
set_property -dict { PACKAGE_PIN Y13   IOSTANDARD LVCMOS25 } [get_ports { led[7] }]

# ---------------------------------------------------------------------------
# Push buttons, bank 16 (VADJ 1.2 V), high while pressed.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN B22   IOSTANDARD LVCMOS12 } [get_ports { btnc }]
set_property -dict { PACKAGE_PIN D22   IOSTANDARD LVCMOS12 } [get_ports { btnd }]
set_property -dict { PACKAGE_PIN C22   IOSTANDARD LVCMOS12 } [get_ports { btnl }]
set_property -dict { PACKAGE_PIN D14   IOSTANDARD LVCMOS12 } [get_ports { btnr }]
set_property -dict { PACKAGE_PIN F15   IOSTANDARD LVCMOS12 } [get_ports { btnu }]

# ---------------------------------------------------------------------------
# Slide switches, banks 16/15 (VADJ 1.2 V).
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN E22   IOSTANDARD LVCMOS12 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN F21   IOSTANDARD LVCMOS12 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN G21   IOSTANDARD LVCMOS12 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN G22   IOSTANDARD LVCMOS12 } [get_ports { sw[3] }]
set_property -dict { PACKAGE_PIN H17   IOSTANDARD LVCMOS12 } [get_ports { sw[4] }]
set_property -dict { PACKAGE_PIN J16   IOSTANDARD LVCMOS12 } [get_ports { sw[5] }]
set_property -dict { PACKAGE_PIN K13   IOSTANDARD LVCMOS12 } [get_ports { sw[6] }]
set_property -dict { PACKAGE_PIN M17   IOSTANDARD LVCMOS12 } [get_ports { sw[7] }]

# ---------------------------------------------------------------------------
# RTL8211E Ethernet PHY. RGMII and management on bank 13 (2.5 V); the PHY
# reset alone is on bank 34 (3.3 V).
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V13   IOSTANDARD LVCMOS25 } [get_ports { eth_rxck }]
set_property -dict { PACKAGE_PIN W10   IOSTANDARD LVCMOS25 } [get_ports { eth_rxctl }]
set_property -dict { PACKAGE_PIN AB16  IOSTANDARD LVCMOS25 } [get_ports { eth_rxd[0] }]
set_property -dict { PACKAGE_PIN AA15  IOSTANDARD LVCMOS25 } [get_ports { eth_rxd[1] }]
set_property -dict { PACKAGE_PIN AB15  IOSTANDARD LVCMOS25 } [get_ports { eth_rxd[2] }]
set_property -dict { PACKAGE_PIN AB11  IOSTANDARD LVCMOS25 } [get_ports { eth_rxd[3] }]
set_property -dict { PACKAGE_PIN AA14  IOSTANDARD LVCMOS25 } [get_ports { eth_txck }]
set_property -dict { PACKAGE_PIN V10   IOSTANDARD LVCMOS25 } [get_ports { eth_txctl }]
set_property -dict { PACKAGE_PIN Y12   IOSTANDARD LVCMOS25 } [get_ports { eth_txd[0] }]
set_property -dict { PACKAGE_PIN W12   IOSTANDARD LVCMOS25 } [get_ports { eth_txd[1] }]
set_property -dict { PACKAGE_PIN W11   IOSTANDARD LVCMOS25 } [get_ports { eth_txd[2] }]
set_property -dict { PACKAGE_PIN Y11   IOSTANDARD LVCMOS25 } [get_ports { eth_txd[3] }]
set_property -dict { PACKAGE_PIN AA16  IOSTANDARD LVCMOS25 } [get_ports { eth_mdc }]
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS25 } [get_ports { eth_mdio }]
set_property -dict { PACKAGE_PIN Y14   IOSTANDARD LVCMOS25 } [get_ports { eth_int_b }]
set_property -dict { PACKAGE_PIN U7    IOSTANDARD LVCMOS33 } [get_ports { eth_rst_b }]

# ---------------------------------------------------------------------------
# Asynchronous board pins: no timing relationship to any internal clock.
# Inputs are captured by rtlnet_sync chains (switches, buttons, PHY side band) or the UART Lite receiver behind the CPU
# core's rtlnet_sync; the reset button only asserts rtlnet_reset_sync chains.
# Outputs are register driven (LEDs, UART transmit, PHY reset, MDC, MDIO).
# ---------------------------------------------------------------------------
set_false_path -from [get_ports {cpu_resetn uart_tx_in sw[*] btnc btnd btnl btnr btnu eth_int_b eth_mdio}]
set_false_path -to   [get_ports {led[*] uart_rx_out eth_rst_b eth_mdc eth_mdio}]

# ---------------------------------------------------------------------------
# Configuration: 3.3 V configuration bank, Quad-SPI flash (x4, 33 MHz),
# compressed bitstream.
# ---------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
