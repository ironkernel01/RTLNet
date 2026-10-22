# tb_rtlnet_iperf: iperf 2 UDP server leaf bench (paths relative to the repository root).
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
-f cores/rtlnet_iperf/hdl/rtlnet_iperf.f
cores/rtlnet_eth_protocol/testbench/rtlnet_tb_leaf_claim_monitor.sv
cores/rtlnet_iperf/testbench/tb_rtlnet_iperf.sv
