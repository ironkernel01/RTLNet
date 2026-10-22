# tb_rtlnet_eth_protocol_cpu: wrapper bench with every leaf and the CPU network path (paths relative to the repository root).
-f cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
cores/rtlnet_eth_protocol/testbench/rtlnet_tb_eth_frames_pkg.sv
cores/rtlnet_eth_protocol/testbench/rtlnet_tb_leaf_claim_monitor.sv
cores/rtlnet_eth_protocol/testbench/tb_rtlnet_eth_protocol_cpu.sv
