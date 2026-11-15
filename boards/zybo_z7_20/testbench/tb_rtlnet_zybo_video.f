# Purpose: integrated camera-to-encoder board bench inputs.
# Overview: GP BFM, two HP memories and the D-PHY transmitter model of the camera receiver benches. Revision: 11-15-2026.
-f boards/zybo_z7_20/hdl/rtlnet_zybo_video.f
cores/rtlnet_common/testbench/rtlnet_tb_pkg.sv
cores/rtlnet_common/testbench/rtlnet_tb_axil_master.sv
-f cores/rtlnet_csi2_rx/testbench/rtlnet_csi2_tb_common.f
boards/zybo_z7_20/testbench/tb_rtlnet_zybo_video.sv
