# -----------------------------------------------------------------------------
# File: rtlnet_arty_a7_100_eth.xdc
# Purpose: pin, I/O standard, clock, MII interface timing and configuration constraints of the Arty A7-100T Ethernet demo top
#   (rtlnet_arty_a7_100_eth_top), read by build_ethernet.tcl.
# Overview:
#   * Balls and I/O standards from the Digilent Arty-A7-100-Master.xdc (Rev. D and Rev. E). Every board I/O of this design is
#     LVCMOS33 (banks 14, 15, 16, 35 at 3.3 V).
#   * Primary clock here: sys_clk 100 MHz on E3. The MMCM outputs (system clock, 25 MHz reference) are derived clocks Vivado
#     creates from sys_clk. No clock groups are declared: scripts/rtlnet_constrain_cdc.tcl bounds every crossing by cell name.
#   * The PHY's MII clocks (outputs of the DP83848J), the MII interface timing and the PHY reference clock output (ball G18, to
#     the DP83848 X1 input, forwarded through an ODDR) are in rtlnet_arty_a7_100_mii.xdc, read after synthesis.
#   * Asynchronous board pins (button, switches, UART, MDIO, LEDs, PHY reset, MDC) have no timing relationship to any internal
#     clock: inputs enter rtlnet_sync chains or the UART oversampler, outputs are register driven and slow; false paths here.
# Revision: 11-14-2026
#   * 11-14-2026: initial version.
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Clock: 100 MHz oscillator, E3, bank 35 (3.3 V), MRCC.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports sysclk]

# ---------------------------------------------------------------------------
# RESET button ck_rst, C2, bank 35 (3.3 V), low while pressed.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN C2    IOSTANDARD LVCMOS33 } [get_ports { cpu_resetn }]

# ---------------------------------------------------------------------------
# USB-UART bridge, bank 16 (3.3 V). uart_tx_in = bridge TXD into the FPGA (A9),
# uart_rx_out = FPGA transmit into the bridge RXD (D10).
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN A9    IOSTANDARD LVCMOS33 } [get_ports { uart_tx_in }]
set_property -dict { PACKAGE_PIN D10   IOSTANDARD LVCMOS33 } [get_ports { uart_rx_out }]

# ---------------------------------------------------------------------------
# LEDs LD4..LD7 (XDC names led[0..3]), banks 35 and 14 (3.3 V).
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN H5    IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN J5    IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN T9    IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

# ---------------------------------------------------------------------------
# Push buttons BTN0..BTN3, bank 16 (3.3 V), high while pressed.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN D9    IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN C9    IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN B9    IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN B8    IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

# ---------------------------------------------------------------------------
# Slide switches SW0..SW3, bank 16 (3.3 V).
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN A8    IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN C11   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN C10   IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN A10   IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]

# ---------------------------------------------------------------------------
# DP83848J Ethernet PHY, MII, bank 15 (3.3 V). The Digilent XDC labels this block "SMSC Ethernet PHY"; the part is the TI
# DP83848J (reference manual section 6, schematic sheet 8). eth_col (D17) and eth_crs (G14) are not used by the full-duplex MAC.
# ---------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN F15   IOSTANDARD LVCMOS33 } [get_ports { eth_rx_clk }]
set_property -dict { PACKAGE_PIN G16   IOSTANDARD LVCMOS33 } [get_ports { eth_rx_dv }]
set_property -dict { PACKAGE_PIN C17   IOSTANDARD LVCMOS33 } [get_ports { eth_rxerr }]
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { eth_rxd[0] }]
set_property -dict { PACKAGE_PIN E17   IOSTANDARD LVCMOS33 } [get_ports { eth_rxd[1] }]
set_property -dict { PACKAGE_PIN E18   IOSTANDARD LVCMOS33 } [get_ports { eth_rxd[2] }]
set_property -dict { PACKAGE_PIN G17   IOSTANDARD LVCMOS33 } [get_ports { eth_rxd[3] }]
set_property -dict { PACKAGE_PIN H16   IOSTANDARD LVCMOS33 } [get_ports { eth_tx_clk }]
set_property -dict { PACKAGE_PIN H15   IOSTANDARD LVCMOS33 } [get_ports { eth_tx_en }]
set_property -dict { PACKAGE_PIN H14   IOSTANDARD LVCMOS33 } [get_ports { eth_txd[0] }]
set_property -dict { PACKAGE_PIN J14   IOSTANDARD LVCMOS33 } [get_ports { eth_txd[1] }]
set_property -dict { PACKAGE_PIN J13   IOSTANDARD LVCMOS33 } [get_ports { eth_txd[2] }]
set_property -dict { PACKAGE_PIN H17   IOSTANDARD LVCMOS33 } [get_ports { eth_txd[3] }]
set_property -dict { PACKAGE_PIN F16   IOSTANDARD LVCMOS33 } [get_ports { eth_mdc }]
set_property -dict { PACKAGE_PIN K13   IOSTANDARD LVCMOS33 } [get_ports { eth_mdio }]
set_property -dict { PACKAGE_PIN C16   IOSTANDARD LVCMOS33 } [get_ports { eth_rstn }]
set_property -dict { PACKAGE_PIN G18   IOSTANDARD LVCMOS33 SLEW FAST } [get_ports { eth_ref_clk }]

# The MII clocks, the MII interface timing and the reference clock output are in rtlnet_arty_a7_100_mii.xdc, read after synthesis.

# ---------------------------------------------------------------------------
# Asynchronous board pins: no timing relationship to any internal clock.
# Inputs are captured by rtlnet_sync chains (switches, buttons, MDIO) or the UART Lite receiver behind the CPU core's
# rtlnet_sync; the reset button only asserts rtlnet_reset_sync chains.
# Outputs are register driven (LEDs, UART transmit, PHY reset, MDC, MDIO).
# ---------------------------------------------------------------------------
set_false_path -from [get_ports {cpu_resetn uart_tx_in sw[*] btn[*] eth_mdio}]
set_false_path -to   [get_ports {led[*] uart_rx_out eth_rstn eth_mdc eth_mdio}]

# ---------------------------------------------------------------------------
# Configuration: 3.3 V configuration bank, Quad-SPI flash (x4, 33 MHz), compressed bitstream.
# ---------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
