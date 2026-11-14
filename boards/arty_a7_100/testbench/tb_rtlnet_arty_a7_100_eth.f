# Arty A7-100T Ethernet demo board bench: the Arty Ethernet top with the CPU core replaced by its simulation stub, the DP83848
# MII data model and a Clause 22 MDIO slave on the PHY pins (paths relative to the repository root).
+define+RTLNET_CPU_ETH_SIM_STUB
-f cores/rtlnet_common/hdl/rtlnet_common.f
-f cores/rtlnet_eth_mac/hdl/rtlnet_eth_mac_mii.f
-f cores/rtlnet_mdio/hdl/rtlnet_mdio.f
-f cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol.f
-f cores/rtlnet_udp_echo/hdl/rtlnet_udp_echo.f
-f cores/rtlnet_common/testbench/rtlnet_tb_common.f
cores/rtlnet_eth_protocol/testbench/rtlnet_tb_eth_frames_pkg.sv
cores/rtlnet_eth_mac/testbench/rtlnet_dp83848_model.sv
cores/rtlnet_mdio/testbench/rtlnet_tb_mdio_slave.sv
cpu/microblaze_v_ethernet/hdl/rtlnet_cpu_eth_sysregs.sv
cpu/microblaze_v_ethernet/rtlnet_cpu_eth_sim_stub.sv
boards/arty_a7_100/hdl/rtlnet_arty_a7_100_eth_top.sv
boards/arty_a7_100/testbench/tb_rtlnet_arty_a7_100_eth.sv
