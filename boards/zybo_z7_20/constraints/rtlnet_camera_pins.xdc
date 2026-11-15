# Purpose: Pcam pins from Digilent Zybo-Z7 release XDC.
# Revision: 11-14-2026.
#MIPI
set_property PACKAGE_PIN G20 [get_ports {cam_gpio_tri_io[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {cam_gpio_tri_io[0]}]
set_property PULLUP true [get_ports {cam_gpio_tri_io[0]}]

set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} [get_ports cam_iic_scl_io]
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports cam_iic_sda_io]

set_property INTERNAL_VREF 0.6 [get_iobanks 35]

set_property -dict {PACKAGE_PIN J19 IOSTANDARD HSUL_12} [get_ports dphy_clk_lp_n]
set_property -dict {PACKAGE_PIN H20 IOSTANDARD HSUL_12} [get_ports dphy_clk_lp_p]

set_property -dict {PACKAGE_PIN M18 IOSTANDARD HSUL_12} [get_ports {dphy_data_lp_n[0]}]
set_property -dict {PACKAGE_PIN L19 IOSTANDARD HSUL_12} [get_ports {dphy_data_lp_p[0]}]
set_property -dict {PACKAGE_PIN L20 IOSTANDARD HSUL_12} [get_ports {dphy_data_lp_n[1]}]
set_property -dict {PACKAGE_PIN J20 IOSTANDARD HSUL_12} [get_ports {dphy_data_lp_p[1]}]

set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVDS_25} [get_ports dphy_hs_clock_clk_n]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVDS_25} [get_ports dphy_hs_clock_clk_p]

set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVDS_25} [get_ports {dphy_data_hs_n[0]}]
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVDS_25} [get_ports {dphy_data_hs_p[0]}]
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVDS_25} [get_ports {dphy_data_hs_n[1]}]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVDS_25} [get_ports {dphy_data_hs_p[1]}]


