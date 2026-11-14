# Nexys Video Ethernet demo top (rtlnet_nexys_video_eth_top), sources in compile order (paths relative to the repository root).
# No DDR3, video or H.264 cores. The block design rtlnet_cpu_eth and its wrapper are created by the build.
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_eth_mac/hdl/rtlnet_eth_mac.f
-f cores/rtlnet_mdio/hdl/rtlnet_mdio.f
-f cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol.f
-f cores/rtlnet_udp_echo/hdl/rtlnet_udp_echo.f
-f cpu/microblaze_v_ethernet/hdl/rtlnet_cpu_eth.f
boards/nexys_video/hdl/rtlnet_nexys_video_eth_top.sv
