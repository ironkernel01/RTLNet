# Network board bench: the Nexys Video top with RTLNET_WITH_NETWORK, the CPU
# core replaced by its simulation stub, the RTL8211E model on the PHY pins (paths relative
# to the repository root). RTLNET_SIM_RXC_INSERTION_NS: AMD pin-layer RXC
# insertion for simulation (cores/rtlnet_eth_mac/documentation section 7).
+define+RTLNET_MICROBLAZE_SIM_STUB
+define+RTLNET_DDR_SIM
+define+RTLNET_WITH_NETWORK
+define+RTLNET_SIM_RXC_INSERTION_NS=1.536
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f boards/nexys_video/hdl/rtlnet_nexys_video_network.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
-f cores/rtlnet_axi_arbiter/hdl/rtlnet_axi_arbiter.f
-f cores/rtlnet_axi_cdc/hdl/rtlnet_axi_cdc.f
-f cores/rtlnet_ddr/hdl/rtlnet_ddr_sim.f
-f cores/rtlnet_csi2_rx/hdl/rtlnet_csi2_rx.f
-f cores/rtlnet_vdma_s2mm/hdl/rtlnet_vdma_s2mm.f
-f cores/rtlnet_framebuf/hdl/rtlnet_framebuf.f
-f cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc.f
cores/rtlnet_eth_protocol/testbench/rtlnet_tb_eth_frames_pkg.sv
cores/rtlnet_eth_mac/testbench/rtlnet_rtl8211e_model.sv
microblaze/rtlnet_microblaze_sim_stub.sv
boards/nexys_video/hdl/rtlnet_nexys_video_clk_beacon.sv
boards/nexys_video/hdl/rtlnet_nexys_video_sysregs.sv
boards/nexys_video/hdl/rtlnet_nexys_video_top.sv
boards/nexys_video/testbench/tb_rtlnet_nexys_video_net.sv
