# Purpose: constraints of the own camera receiver (rtlnet_csi2_rx front end): LP inputs.
# Overview: the HS clock (rtlnet_dphy_hs) and the HS data input delays come from rtlnet_camera_clocks.xdc and
#   rtlnet_camera_timing.xdc, shared with the reference receiver. Vivado derives the byte clock (divide by 4) at the BUFR
#   output itself (clock g_cam.byte_clk); an explicit generated clock would override it (Constraints 18-1056). The IODELAY
#   group rtlnet_csi2_dly (IDELAYE2 and IDELAYCTRL) is set by an attribute in the RTL. The LP pins are asynchronous to every
#   clock by definition; they pass a two-flop synchronizer and a two-sample glitch filter.
# Revision: 11-15-2026.
set_false_path -from [get_ports {dphy_clk_lp_p dphy_clk_lp_n dphy_data_lp_p[*] dphy_data_lp_n[*]}]
