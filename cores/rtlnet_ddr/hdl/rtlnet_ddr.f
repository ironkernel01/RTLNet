# rtlnet_ddr synthesizable sources, compile order (paths relative to the repository root). The MIG IP
# rtlnet_ddr_mig is not a file: the build generates it (cores/rtlnet_ddr/ip/rtlnet_ddr_mig.tcl).
-f cores/rtlnet_common/hdl/rtlnet_common.f
cores/rtlnet_ddr/hdl/rtlnet_ddr_amd.sv
cores/rtlnet_ddr/hdl/rtlnet_ddr.sv
