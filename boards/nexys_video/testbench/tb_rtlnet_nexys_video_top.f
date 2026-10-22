# Board bench of the CPU-only Nexys Video top, CPU core replaced by its simulation stub
# (paths relative to the repository root).
+define+RTLNET_MICROBLAZE_SIM_STUB
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
microblaze/rtlnet_microblaze_sim_stub.sv
boards/nexys_video/hdl/rtlnet_nexys_video_clk_beacon.sv
boards/nexys_video/hdl/rtlnet_nexys_video_sysregs.sv
boards/nexys_video/hdl/rtlnet_nexys_video_top.sv
boards/nexys_video/testbench/tb_rtlnet_nexys_video_top.sv
