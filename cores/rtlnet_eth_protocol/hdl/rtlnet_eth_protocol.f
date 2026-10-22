# rtlnet_eth_protocol synthesizable sources (paths relative to the repository root).
-f cores/rtlnet_common/hdl/rtlnet_common.f
# Protocol leaves that exist; the parallel leaves are added here when they land.
-f cores/rtlnet_arp/hdl/rtlnet_arp.f
-f cores/rtlnet_icmp/hdl/rtlnet_icmp.f
-f cores/rtlnet_dhcp/hdl/rtlnet_dhcp.f
-f cores/rtlnet_iperf/hdl/rtlnet_iperf.f
-f cores/rtlnet_udp_socket/hdl/rtlnet_udp_socket.f
cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol_ingress.sv
cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol_regs.sv
cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol.sv
