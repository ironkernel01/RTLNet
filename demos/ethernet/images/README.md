# Ethernet demo images

Revision 11-17-2026

Captures of the campaign of the Ethernet demo on the Nexys Video (image `eth_fw2`: hardware git 2c2c686b, firmware git f82d4f1, 11-17-2026). Each picture is a rendering of the console or test text (`cpu/microblaze_v_ethernet/test/render_capture.py`); the IP and MAC addresses in them are replaced by documentation values (192.0.2.x, 00:00:5E:00:53:xx). The [RTLNet Specification](../../../documentation/rtnet_specification.md) summarizes these measurements.

| File | Shows |
|---|---|
| `ethernet_console.png` | `show version`, `show system`, `show interfaces`, `show ip` after start-up: firmware build, 100 MHz clock, link up at 1000 Mb/s |
| `ethernet_perf_1000.png` | Results at 1000 Mb/s: ping, UDP echo latency, UDP iperf both ways with the zero-loss sweep, TCP echo and TCP iperf, the mean, minimum and maximum of three 10 s TCP runs and the TCP echo latency, with the firewall off and on |
| `ethernet_classifier.png` | `show classifier` after the flood tests (firewall off): the four policer classes with their limits and the drop counts, block RAM build, firewall disabled |
| `ethernet_firewall.png` | Firewall session: `tcp echo port 23`, `iperf tcp disable`, `classifier firewall enable`, `show classifier` with the Firewall block (one slot, 15 free, drop count) and the matching `show running-config` lines |
| `ethernet_firewall_test.png` | `firewall_test.ps1` at 1000 Mb/s: the 21 checks of the four steps, `FIREWALL_TEST: PASS 21/21` |
| `ethernet_portscan.png` | Port scan at 1000 Mb/s with the firewall off and on: 199 closed TCP ports, 100 closed UDP ports and the allowed ports 7 and 5001, with the board's counters |
| `ethernet_fwflood.png` | Floods at 1000 Mb/s with the firewall off and on: frames sent, TCP echo rounds, and the board's counters (reached, dropped by the firewall, passed to the CPU) |
| `ethernet_verdicts.png` | The three `ETH_SUITE` verdict lines (1000 Mb/s with `LINK_TEST`, 100 and 10 Mb/s) with the verdict of each script including `FIREWALL_TEST`, and the two `FLOOD_TEST` verdicts |
| `ethernet_offload.png` | `show offload` after the TCP runs at 1000 Mb/s: hardware checksums, frames sent in place, ACK coalescing counters, receive batching off |
| `ethernet_perf_100.png` | The same results as `ethernet_perf_1000.png` at 100 Mb/s, firewall off and on |
| `ethernet_perf_10.png` | The same results at 10 Mb/s, firewall off and on |
| `ethernet_runcfg.png` | `show running-config`: interface, DHCP, sockets, TCP echo and iperf, and the four classifier policers |
| `ethernet_flood1000.png` | `flood_test.ps1` at 1000 frames per second, all eight kinds, `FLOOD_TEST: PASS 95/95` |
| `ethernet_flood100000.png` | `flood_test.ps1` at 100000 frames per second offered (udp-closed, udp-bcast-net, mcast, icmp-bcast), `FLOOD_TEST: PASS 50/50` |

## Arty A7-100T captures

Captures of the campaign of the Ethernet demo on the Arty A7-100T (image `arty_fw2`: hardware git ab3e1d17, firmware git f82d4f1, 11-17-2026), rendered and redacted the same way. The [RTLNet Specification](../../../documentation/rtnet_specification.md) summarizes these measurements.

| File | Shows |
|---|---|
| `ethernet_arty_console.png` | `show version`, `show system`, `show phy`, `show interfaces`, `show ip`: board ARTY, 100 MHz clock, link modes 10 and 100, PHY DP83848 ID 0x20005C90 at MDIO address 1, link up at 100 Mb/s |
| `ethernet_arty_perf_100.png` | Results at 100 Mb/s: ping, UDP echo latency, UDP iperf both ways with the zero-loss sweep, TCP echo and TCP iperf, the mean, minimum and maximum of three 10 s TCP runs and the TCP echo latency, with the firewall off and on |
| `ethernet_arty_perf_10.png` | The same results at 10 Mb/s |
| `ethernet_arty_classifier.png` | `show classifier` after the flood tests: the four policer classes with their limits and the drop counts, distributed RAM build, firewall disabled |
| `ethernet_arty_firewall.png` | Firewall session: `tcp echo port 23`, `iperf tcp disable`, `classifier firewall enable`, `show classifier` with the Firewall block (one slot, 7 free, drop count) and the matching `show running-config` lines |
| `ethernet_arty_firewall_test.png` | `firewall_test.ps1` at 100 Mb/s: the 21 checks of the four steps, `FIREWALL_TEST: PASS 21/21` |
| `ethernet_arty_verdicts.png` | The two `ETH_SUITE` verdict lines (100 Mb/s with `LINK_TEST`, 10 Mb/s) with the verdict of each script including `FIREWALL_TEST`, and the two `FLOOD_TEST` verdicts |
| `ethernet_arty_offload.png` | `show offload` after the TCP runs at 100 Mb/s: hardware checksums, frames sent in place and copied, ACK coalescing counters, receive batching off |
| `ethernet_arty_flood1000.png` | `flood_test.ps1` at 1000 frames per second, all eight kinds, `FLOOD_TEST: PASS 95/95` |
| `ethernet_arty_flood100000.png` | `flood_test.ps1` at 100000 frames per second offered (udp-closed, udp-bcast-net, mcast, icmp-bcast), `FLOOD_TEST: PASS 50/50` |
