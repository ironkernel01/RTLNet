# -----------------------------------------------------------------------------
# File: rtlnet_nexys_video.xdc
# Purpose: pin, I/O standard, primary clock and configuration constraints of
#   the RTLNet Nexys Video board top (rtlnet_nexys_video_top).
# Overview:
#   * Balls and I/O standards from the Digilent Nexys-Video-Master.xdc (Rev. A).
#     Banks 15/16 run at the VADJ default of 1.2 V (SET_VADJ/VADJ_EN are not
#     driven), so switches and buttons are LVCMOS12.
#   * One primary clock: sysclk 100 MHz on R4. The MMCM outputs and the DDR3
#     controller's clocks are derived clocks Vivado creates from it; no clock
#     groups are declared.
#   * DDR3 SDRAM pins (banks 34/35) as the MIG project generates them; the
#     controller's own constraints come with its generated IP.
#   * Clock-domain crossings are bounded by scripts/rtlnet_constrain_cdc.tcl
#     (cell-name based), sourced by the build after synthesis.
#   * Asynchronous board pins (buttons, switches, UART, PHY side band, LEDs,
#     PHY reset, MDIO/MDC) have no timing relationship to any internal clock:
#     inputs enter rtlnet_sync chains or the UART oversampler, outputs are
#     register driven and slow; they are false paths here.
#   * The RGMII interface timing block (input delays on eth_rxd/eth_rxctl
#     against eth_rxck, generated clock and output delays on eth_txck) is
#     added at network integration, together with the MAC pin-layer cells
#     (u_mac/u_rgmii_io/...). In the CPU-only build those pins are idle.
# Revision: 11-09-2026
#   * 10-22-2026: initial version.
#   * 11-09-2026: DDR3 SDRAM pins (from the MIG project of cores/rtlnet_ddr); false path to ddr3_reset_n.
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
set_property -dict { PACKAGE_PIN W14   IOSTANDARD LVCMOS25 } [get_ports { eth_pme_b }]
set_property -dict { PACKAGE_PIN U7    IOSTANDARD LVCMOS33 } [get_ports { eth_rst_b }]

# ---------------------------------------------------------------------------
# DDR3 SDRAM MT41K256M16 (Micron), banks 34 and 35, 1.5 V. Balls, I/O standards,
# slew and input termination exactly as the MIG project
# cores/rtlnet_ddr/ip/rtlnet_ddr_mig.prj generates them (the generated IP
# constraints carry the same values, plus the PHY and timing constraints of the
# controller, so nothing here contradicts them). Bank 35 uses the internal
# VREF (0.75 V); the clock pair has no I/O buffer (the controller instantiates
# its own output primitives). The 100 MHz system clock pad (sysclk, above) also
# feeds the controller PLL; the controller reference clock is the 200 MHz
# MMCM output.
# ---------------------------------------------------------------------------
set_property IO_BUFFER_TYPE NONE [get_ports {ddr3_ck_n[*]}]
set_property IO_BUFFER_TYPE NONE [get_ports {ddr3_ck_p[*]}]
set_property INTERNAL_VREF 0.750 [get_iobanks 35]
set_property -dict { PACKAGE_PIN G2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[0]}]
set_property -dict { PACKAGE_PIN H4  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[1]}]
set_property -dict { PACKAGE_PIN H5  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[2]}]
set_property -dict { PACKAGE_PIN J1  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[3]}]
set_property -dict { PACKAGE_PIN K1  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[4]}]
set_property -dict { PACKAGE_PIN H3  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[5]}]
set_property -dict { PACKAGE_PIN H2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[6]}]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[7]}]
set_property -dict { PACKAGE_PIN E3  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[8]}]
set_property -dict { PACKAGE_PIN B2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[9]}]
set_property -dict { PACKAGE_PIN F3  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[10]}]
set_property -dict { PACKAGE_PIN D2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[11]}]
set_property -dict { PACKAGE_PIN C2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[12]}]
set_property -dict { PACKAGE_PIN A1  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[13]}]
set_property -dict { PACKAGE_PIN E2  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[14]}]
set_property -dict { PACKAGE_PIN B1  IOSTANDARD SSTL15      SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dq[15]}]
set_property -dict { PACKAGE_PIN P6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[14]}]
set_property -dict { PACKAGE_PIN P2  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[13]}]
set_property -dict { PACKAGE_PIN N4  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[12]}]
set_property -dict { PACKAGE_PIN N5  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[11]}]
set_property -dict { PACKAGE_PIN L5  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[10]}]
set_property -dict { PACKAGE_PIN R1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[9]}]
set_property -dict { PACKAGE_PIN M6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[8]}]
set_property -dict { PACKAGE_PIN N2  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[7]}]
set_property -dict { PACKAGE_PIN N3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[6]}]
set_property -dict { PACKAGE_PIN P1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[5]}]
set_property -dict { PACKAGE_PIN L6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[4]}]
set_property -dict { PACKAGE_PIN M1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[3]}]
set_property -dict { PACKAGE_PIN M3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[2]}]
set_property -dict { PACKAGE_PIN M5  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[1]}]
set_property -dict { PACKAGE_PIN M2  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_addr[0]}]
set_property -dict { PACKAGE_PIN L4  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_ba[2]}]
set_property -dict { PACKAGE_PIN K6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_ba[1]}]
set_property -dict { PACKAGE_PIN L3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_ba[0]}]
set_property -dict { PACKAGE_PIN J4  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_ras_n}]
set_property -dict { PACKAGE_PIN K3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_cas_n}]
set_property -dict { PACKAGE_PIN L1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_we_n}]
set_property -dict { PACKAGE_PIN G1  IOSTANDARD LVCMOS15    SLEW FAST } [get_ports {ddr3_reset_n}]
set_property -dict { PACKAGE_PIN J6  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_cke[0]}]
set_property -dict { PACKAGE_PIN K4  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_odt[0]}]
set_property -dict { PACKAGE_PIN G3  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_dm[0]}]
set_property -dict { PACKAGE_PIN F1  IOSTANDARD SSTL15      SLEW FAST } [get_ports {ddr3_dm[1]}]
set_property -dict { PACKAGE_PIN K2  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dqs_p[0]}]
set_property -dict { PACKAGE_PIN J2  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dqs_n[0]}]
set_property -dict { PACKAGE_PIN E1  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dqs_p[1]}]
set_property -dict { PACKAGE_PIN D1  IOSTANDARD DIFF_SSTL15 SLEW FAST IN_TERM UNTUNED_SPLIT_50 } [get_ports {ddr3_dqs_n[1]}]
set_property -dict { PACKAGE_PIN P5  IOSTANDARD DIFF_SSTL15 SLEW FAST } [get_ports {ddr3_ck_p[0]}]
set_property -dict { PACKAGE_PIN P4  IOSTANDARD DIFF_SSTL15 SLEW FAST } [get_ports {ddr3_ck_n[0]}]

# ---------------------------------------------------------------------------
# Asynchronous board pins: no timing relationship to any internal clock.
# Inputs are captured by rtlnet_sync chains (switches, buttons, PHY side band,
# RGMII levels in the CPU-only build) or the UART Lite receiver behind the CPU
# core's rtlnet_sync; the reset button only asserts rtlnet_reset_sync chains.
# Outputs are register driven (LEDs, UART transmit, PHY reset, MDC, MDIO).
# ---------------------------------------------------------------------------
set_false_path -from [get_ports {cpu_resetn uart_tx_in sw[*] btnc btnd btnl btnr btnu eth_int_b eth_pme_b eth_mdio}]
set_false_path -to   [get_ports {led[*] uart_rx_out eth_rst_b eth_mdc eth_mdio}]
# DDR3 RESET# is a static control level set by the controller's calibration sequence, not a clocked signal.
set_false_path -to   [get_ports {ddr3_reset_n}]

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
