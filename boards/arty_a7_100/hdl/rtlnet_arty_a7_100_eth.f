# Arty A7-100T Ethernet demo top (rtlnet_arty_a7_100_eth_top), sources in compile order (paths relative to the repository root).
# 10/100 MII MAC, no DDR3, video or H.264 cores. The block design rtlnet_cpu_eth_bd and its wrapper are created by the build.
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_eth_mac/hdl/rtlnet_eth_mac_mii.f
-f cores/rtlnet_mdio/hdl/rtlnet_mdio.f
-f cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol.f
-f cores/rtlnet_udp_echo/hdl/rtlnet_udp_echo.f
-f cpu/microblaze_v_ethernet/hdl/rtlnet_cpu_eth.f
boards/arty_a7_100/hdl/rtlnet_arty_a7_100_eth_top.sv
