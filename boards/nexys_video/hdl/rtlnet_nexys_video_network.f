# Network cores of the Nexys Video build, read before rtlnet_nexys_video.f when the
# build defines RTLNET_WITH_NETWORK (build.ps1 -Network). Each core owns its filelist
# (architecture section 2); none of them is part of the CPU-only build.
-f cores/rtlnet_eth_mac/hdl/rtlnet_eth_mac.f
-f cores/rtlnet_mdio/hdl/rtlnet_mdio.f
-f cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol.f
-f cores/rtlnet_udp_echo/hdl/rtlnet_udp_echo.f
