# tb_rtlnet_h264_search sources, compile order (paths relative to the repository root).
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
cores/rtlnet_h264_enc/hdl/rtlnet_h264_pkg.sv
cores/rtlnet_h264_enc/hdl/rtlnet_h264_cinterp.sv
cores/rtlnet_h264_enc/hdl/rtlnet_h264_sad16.sv
cores/rtlnet_h264_enc/hdl/rtlnet_h264_mvpred.sv
cores/rtlnet_h264_enc/hdl/rtlnet_h264_mvpred_s1.sv
cores/rtlnet_h264_enc/hdl/rtlnet_h264_mvpred_s2.sv
cores/rtlnet_h264_enc/hdl/rtlnet_h264_mvpred_s3.sv
cores/rtlnet_h264_enc/hdl/rtlnet_h264_mvctx.sv
cores/rtlnet_h264_enc/hdl/rtlnet_h264_search.sv
cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_search.sv
