# tb_rtlnet_h264_top sources, compile order (paths relative to the repository root).
-f cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc.f
-f cores/rtlnet_axi_arbiter/hdl/rtlnet_axi_arbiter.f
cores/rtlnet_common/testbench/rtlnet_tb_pkg.sv
cores/rtlnet_h264_enc/testbench/tb_h264_axi_mem.sv
cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_top.sv
