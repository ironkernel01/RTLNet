# Ethernet demo board bench: the Nexys Video Ethernet top with the CPU core replaced by its simulation stub,
# the RTL8211E model on the PHY pins (paths relative to the repository root). RTLNET_SIM_RXC_INSERTION_NS: AMD pin-layer
# RXC insertion for simulation (cores/rtlnet_eth_mac/documentation section 7).
+define+RTLNET_CPU_ETH_SIM_STUB
+define+RTLNET_SIM_RXC_INSERTION_NS=1.536
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_eth_mac/hdl/rtlnet_eth_mac.f
-f cores/rtlnet_mdio/hdl/rtlnet_mdio.f
-f cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol.f
-f cores/rtlnet_udp_echo/hdl/rtlnet_udp_echo.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
cores/rtlnet_eth_protocol/testbench/rtlnet_tb_eth_frames_pkg.sv
cores/rtlnet_eth_mac/testbench/rtlnet_rtl8211e_model.sv
cpu/microblaze_v_ethernet/hdl/rtlnet_cpu_eth_sysregs.sv
cpu/microblaze_v_ethernet/rtlnet_cpu_eth_sim_stub.sv
boards/nexys_video/hdl/rtlnet_nexys_video_eth_top.sv
boards/nexys_video/testbench/tb_rtlnet_nexys_video_eth.sv
