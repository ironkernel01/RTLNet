# Board bench of the CPU-only Nexys Video top, CPU core replaced by its simulation stub
# (paths relative to the repository root). RTLNET_DDR_SIM: the DDR3 controller is the AXI4 memory model
# rtlnet_ddr_sim (cores/rtlnet_ddr/testbench) with a 2000-clock calibration delay.
+define+RTLNET_MICROBLAZE_SIM_STUB
+define+RTLNET_DDR_SIM
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
-f cores/rtlnet_axi_arbiter/hdl/rtlnet_axi_arbiter.f
-f cores/rtlnet_axi_cdc/hdl/rtlnet_axi_cdc.f
-f cores/rtlnet_ddr/hdl/rtlnet_ddr_sim.f
-f cores/rtlnet_csi2_rx/hdl/rtlnet_csi2_rx.f
-f cores/rtlnet_vdma_s2mm/hdl/rtlnet_vdma_s2mm.f
-f cores/rtlnet_framebuf/hdl/rtlnet_framebuf.f
-f cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc.f
cpu/microblaze_v_h264/rtlnet_microblaze_sim_stub.sv
boards/nexys_video/hdl/rtlnet_nexys_video_clk_beacon.sv
boards/nexys_video/hdl/rtlnet_nexys_video_sysregs.sv
boards/nexys_video/hdl/rtlnet_nexys_video_top.sv
boards/nexys_video/testbench/tb_rtlnet_nexys_video_top.sv
