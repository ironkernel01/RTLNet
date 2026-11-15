# Purpose: constrain the forwarded camera clock without the IP's fixed 200 Mb/s example delays.
# Overview: 720p60 uses 280 Mb/s; 1080p15 uses 420 Mb/s per lane.
#   Time the fastest selectable mode: 210 MHz DDR clock, UI 2.380952 ns.
#   Both DDR edges use the Digilent timing model: data changes at 0.15..0.85 UI.
#   Sensor clock assumptions require verification on hardware before release.
# Revision: 11-14-2026. Initial mode-specific timing model.
# The EARLY rtlnet_camera_clocks.xdc creates rtlnet_dphy_hs before vendor delays.
# Values below equal Vivado's rounding to its 1 ps timing resolution.
set rtlnet_hs_data [get_ports {dphy_data_hs_p[*] dphy_data_hs_n[*]}]
set_input_delay -clock rtlnet_dphy_hs -min 0.357 $rtlnet_hs_data
set_input_delay -clock rtlnet_dphy_hs -max 2.024 $rtlnet_hs_data
set_input_delay -clock rtlnet_dphy_hs -clock_fall -min -add_delay 0.357 $rtlnet_hs_data
set_input_delay -clock rtlnet_dphy_hs -clock_fall -max -add_delay 2.024 $rtlnet_hs_data
