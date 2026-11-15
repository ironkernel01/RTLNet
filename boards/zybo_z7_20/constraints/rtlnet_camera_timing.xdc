# Purpose: timing constraints of the camera receiver inputs: forwarded HS clock, HS data input delays, LP pins.
# Overview: the sensor modes run 280 Mb/s (720p) and 420 Mb/s (1080p) per lane; the HS clock is constrained for the fastest mode
#   (210 MHz DDR clock, UI 2.380952 ns, 1 ps resolution). Data changes between 0.15 and 0.85 UI after each clock edge (the input
#   delay model of the Pcam 5C reference design), on both clock edges. The static model cannot hold the IDELAY tap that software
#   sets at run time (RX_TAPS): the hold check of the two ISERDESE2 DDLY inputs fails statically (deviation DPHY_HS_INPUT of the
#   build gate) and the capture margin is measured on the board by the tap sweep (scripts/rx_test.ps1 -Action sweep).
#   Vivado derives the byte clock (divide by 4) at the BUFR output itself (clock g_cam.byte_clk); an explicit generated clock would
#   override it (Constraints 18-1056). The IODELAY group rtlnet_csi2_dly (IDELAYE2 and IDELAYCTRL) is set by an attribute in the RTL.
#   The LP pins are asynchronous to every clock by definition; they pass a two-flop synchronizer and a two-sample glitch filter.
# Revision: 11-15-2026.
create_clock -period 4.762 -name rtlnet_dphy_hs -waveform {0 2.381} [get_ports dphy_hs_clock_clk_p]
set rtlnet_hs_data [get_ports {dphy_data_hs_p[*] dphy_data_hs_n[*]}]
set_input_delay -clock rtlnet_dphy_hs -min 0.357 $rtlnet_hs_data
set_input_delay -clock rtlnet_dphy_hs -max 2.024 $rtlnet_hs_data
set_input_delay -clock rtlnet_dphy_hs -clock_fall -min -add_delay 0.357 $rtlnet_hs_data
set_input_delay -clock rtlnet_dphy_hs -clock_fall -max -add_delay 2.024 $rtlnet_hs_data
set_false_path -from [get_ports {dphy_clk_lp_p dphy_clk_lp_n dphy_data_lp_p[*] dphy_data_lp_n[*]}]
