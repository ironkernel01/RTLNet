# Purpose: integrated camera-to-encoder board bench inputs.
# Overview: GP BFM, two HP memories and RGB stimulus. Revision: 11-14-2026.
-f boards/zybo_z7_20/hdl/rtlnet_zybo_video.f
cores/rtlnet_common/testbench/rtlnet_tb_pkg.sv
cores/rtlnet_common/testbench/rtlnet_tb_axil_master.sv
boards/zybo_z7_20/testbench/tb_rtlnet_zybo_video.sv
