# Purpose: create the forwarded HS clock before vendor input delays are read.
# Overview: 210 MHz DDR covers the fastest selectable sensor mode; 1 ps resolution.
# Revision: 11-14-2026.
create_clock -period 4.762 -name rtlnet_dphy_hs -waveform {0 2.381} [get_ports dphy_hs_clock_clk_p]
