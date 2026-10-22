# Network board bench: the Nexys Video top with RTLNET_WITH_NETWORK, the CPU
# core replaced by its BFM, the RTL8211E model on the PHY pins (paths relative
# to the repository root). RTLNET_SIM_RXC_INSERTION_NS: AMD pin-layer RXC
# insertion for simulation (cores/rtlnet_eth_mac/documentation section 7).
+define+RTLNET_CPU_BFM
+define+RTLNET_WITH_NETWORK
+define+RTLNET_SIM_RXC_INSERTION_NS=1.536
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f boards/nexys_video/hdl/rtlnet_nexys_video_network.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
cores/rtlnet_eth_protocol/testbench/rtlnet_tb_eth_frames_pkg.sv
cores/rtlnet_eth_mac/testbench/rtlnet_rtl8211e_model.sv
microblaze/testbench/rtlnet_cpu_bfm.sv
boards/nexys_video/hdl/rtlnet_nexys_video_clk_beacon.sv
boards/nexys_video/hdl/rtlnet_nexys_video_sysregs.sv
boards/nexys_video/hdl/rtlnet_nexys_video_top.sv
boards/nexys_video/testbench/tb_rtlnet_nexys_video_net.sv
