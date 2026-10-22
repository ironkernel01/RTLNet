# tb_rtlnet_dhcp: DHCP client leaf bench (paths relative to the repository root).
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
-f cores/rtlnet_dhcp/hdl/rtlnet_dhcp.f
cores/rtlnet_eth_protocol/testbench/rtlnet_tb_leaf_claim_monitor.sv
cores/rtlnet_dhcp/testbench/tb_rtlnet_dhcp.sv
