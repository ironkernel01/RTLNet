# rtlnet_h264_enc synthesizable sources, compile order (paths relative to the repository root): the core and the stand-in of
# rtlnet_h264_hp (no High profile tools). A build with the delivered netlist lists rtlnet_h264_enc_core.f and the black box
# hp/rtlnet_h264_hp_bb.sv instead.
-f cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc_core.f
cores/rtlnet_h264_enc/hdl/hp/rtlnet_h264_hp_stub.sv
