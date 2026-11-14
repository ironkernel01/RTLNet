# rtlnet_cpu_eth synthesizable sources (paths relative to the repository root).
# The block design `rtlnet_cpu_eth` is not a source file: the build creates it from
# cpu/microblaze_v_ethernet/hdl/rtlnet_cpu_eth_bd.tcl (rtlnet_cpu_eth_bd_create <dir> <cpu_clk_hz> <lmb_kb>) and adds its
# generated wrapper rtlnet_cpu_eth_wrapper.v. Needs rtlnet_common.f (rtlnet_sync, rtlnet_axil_slave) first.
cpu/microblaze_v_ethernet/hdl/rtlnet_cpu_eth.sv
cpu/microblaze_v_ethernet/hdl/rtlnet_cpu_eth_sysregs.sv
