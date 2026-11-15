# Ethernet demo images

Revision 11-14-2026

Captures of the release campaign of the Ethernet demo (image `eth_rel`, git 2c2c686b, Nexys Video, 11-14-2026). Each picture is a rendering of the console or test text (`cpu/microblaze_v_ethernet/test/render_capture.py`); the IP and MAC addresses in them are replaced by documentation values (192.0.2.x, 00:00:5E:00:53:xx). The brief (`../nexys_video/ethernet_nexys_video_brief.md`) uses the first six.

| File | Shows |
|---|---|
| `ethernet_console.png` | `show version`, `show system`, `show interfaces`, `show ip` after start-up: firmware build, 100 MHz clock, link up at 1000 Mb/s |
| `ethernet_perf_1000.png` | Results at 1000 Mb/s: UDP echo latency, UDP iperf both ways with the zero-loss sweep, TCP echo and TCP iperf, and the mean, minimum and maximum of three 10 s TCP runs |
| `ethernet_classifier.png` | `show classifier` after the flood test: the four policer classes with their limits and the drop counts |
| `ethernet_verdicts.png` | The three `ETH_SUITE` verdict lines (1000, 100 and 10 Mb/s) with the verdict of each of the eight scripts |
| `ethernet_offload.png` | `show offload` after the TCP runs: hardware checksums, frames sent in place, ACK coalescing counters, receive batching off |
| `ethernet_flood20000.png` | `flood_test.ps1` at 20000 frames per second (udp-closed, udp-bcast-net, mcast, icmp-bcast) and the verdict `FLOOD_TEST: PASS 50/50` |
| `ethernet_flood1000.png` | `flood_test.ps1` at 1000 frames per second, all eight kinds, `FLOOD_TEST: PASS 95/95` |
| `ethernet_perf_100.png` | The same results at 100 Mb/s |
| `ethernet_perf_10.png` | The same results at 10 Mb/s |
| `ethernet_runcfg.png` | `show running-config`: interface, DHCP, sockets, TCP echo and iperf, and the four classifier policers |

## Arty A7-100T captures

Captures of the campaign of the Ethernet demo on the Arty A7-100T (image `arty_rel`, git ab3e1d17, 11-14-2026), rendered and redacted the same way. The Arty brief (`../arty_a7_100/ethernet_arty_a7_100_brief.md`) uses all of them.

| File | Shows |
|---|---|
| `ethernet_arty_console.png` | `show version`, `show system`, `show phy`, `show interfaces`, `show ip`: board ARTY, 100 MHz clock, link modes 10 and 100, PHY DP83848 ID 0x20005C90 at MDIO address 1, link up at 100 Mb/s |
| `ethernet_arty_perf_100.png` | Results at 100 Mb/s: ping, UDP echo latency, UDP iperf both ways with the zero-loss sweep, TCP echo and TCP iperf, the mean, minimum and maximum of three 10 s TCP runs and the TCP echo latency |
| `ethernet_arty_perf_10.png` | The same results at 10 Mb/s |
| `ethernet_arty_classifier.png` | `show classifier` after the flood tests: the four policer classes with their limits and the drop counts, distributed RAM build |
| `ethernet_arty_verdicts.png` | The two `ETH_SUITE` verdict lines (100 and 10 Mb/s) with the verdict of each of the eight scripts, `LINK_TEST` and the two `FLOOD_TEST` verdicts |
| `ethernet_arty_offload.png` | `show offload` after the TCP runs at 100 Mb/s: hardware checksums, frames sent in place and copied, ACK coalescing counters, receive batching off |
| `ethernet_arty_flood1000.png` | `flood_test.ps1` at 1000 frames per second, all eight kinds, `FLOOD_TEST: PASS 95/95` |
| `ethernet_arty_flood100000.png` | `flood_test.ps1` at 100000 frames per second offered (udp-closed, udp-bcast-net, mcast, icmp-bcast), `FLOOD_TEST: PASS 50/50` |
