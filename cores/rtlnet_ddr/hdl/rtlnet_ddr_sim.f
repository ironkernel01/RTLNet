# rtlnet_ddr for benches that define RTLNET_DDR_SIM: the wrapper and the simulation model, not the AMD
# file and not the MIG IP (paths relative to the repository root). The bench list also holds
# rtlnet_tb_common.f (rtlnet_tb_axi4_mem, rtlnet_tb_pkg), before this list.
-f cores/rtlnet_common/hdl/rtlnet_common.f
cores/rtlnet_ddr/testbench/rtlnet_ddr_sim.sv
cores/rtlnet_ddr/hdl/rtlnet_ddr.sv
