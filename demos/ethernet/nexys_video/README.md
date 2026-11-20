# Ethernet Demo on the Nexys Video

Revision 11-17-2026

The RTLNet gigabit Ethernet stack on a Digilent Nexys Video: 10/100/1000 Mb/s RGMII, hardware ARP, ICMP echo, DHCP client, UDP echo and a UDP iperf 2 server in FPGA fabric, plus lwIP TCP (echo on port 7, iperf 2 server on port 5001) on a small MicroBlaze V. One 100 MHz system clock runs the CPU and the protocol blocks; the CPU runs from 512 KiB of on-chip block RAM with no caches. A classifier with per-class policers protects the CPU from floods; `classifier firewall enable` turns it into a default-deny firewall in which only ARP and the ports of the running TCP services reach the CPU. The console is a hierarchical, switch-style CLI on the USB-UART. There is no time limit and no netlist in this image.
License: `LICENSE.md` in the repository root.

The image file is `rtlnet_nexys_video_eth.bit`: the hardware of `boards/nexys_video/scripts/build_ethernet.ps1 -Tag eth_rel` with the firmware merged in by `build_ethernet.ps1 -Tag eth_fw2 -SkipBitstream` (`build_info.txt` lists both revisions). The name differs from the video demos, which use `rtlnet_nexys_video.bit`.

## What you need

- Digilent Nexys Video board, its power supply and two USB cables (PROG for JTAG, UART for the console).
- An Ethernet cable from the board to the network of the PC. A DHCP server on that network gives the board its address.
- Vivado 2026.1 with its free license, to program the board.
- A terminal on the board's USB serial port at 115200 baud, 8N1.
- For the tests: PowerShell, and iperf 2 (`iperf.exe`) on the PC.

## Steps

1. Program the board over JTAG. The image is not written to the flash; it is gone after a power cycle.

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 -Bit demos/ethernet/nexys_video/rtlnet_nexys_video_eth.bit
   ```

2. Open the serial console. After power-up it prints the banner `RTLNet Ethernet demo -- rtlnet-eth-fw` and a line with the DHCP lease once the server has answered.

3. Check the board: `show ip` prints the address, `show phy` the link speed. From the PC: `ping <board address>`.

## CLI quick start

The CLI is hierarchical like a network switch: `configure terminal` enters configuration mode, `interface eth0` the interface, `end` returns.

| Command | Effect |
|---|---|
| `show version` | firmware name and build |
| `show interfaces` | state and link of `eth0` |
| `show phy` | link speed, duplex, advertised modes and the partner's modes |
| `show ip` | address, mask, gateway |
| `show dhcp` | DHCP client state and lease |
| `show arp` | the hardware ARP table |
| `show counters` | frame and protocol counters |
| `show tcp` | lwIP TCP connections |
| `show iperf` | UDP and TCP iperf server counters |
| `show offload` | checksum offload, ACK coalescing and receive batching counters |
| `show classifier` | mode, protection profile, per-class counters and the Firewall block |
| `classifier firewall enable` / `disable` (configuration mode) | the default-deny firewall of the CPU path; off at boot |
| `classifier acl ...` / `no classifier acl` (configuration mode) | ACL entries 0..13; with the firewall on every entry is an allow entry |
| `ip dhcp` / `renew` (in interface mode) | use DHCP / ask for the lease again |

Link speed is the only link control:

```
configure terminal
interface eth0
speed 100
end
```

`speed` takes `10`, `100` or `auto`. `auto` advertises every full-duplex mode (10, 100 and 1000 Mb/s) and takes the best rate both sides support; half duplex is never advertised. `show phy` prints the result.

## Firewall

The CPU path has a default-deny firewall, off at boot. With it on, only ARP and an allow list reach lwIP; every other frame is dropped by the classifier in hardware, so a closed port gives no RST and no ICMP port unreachable. Ping, DHCP, UDP echo and UDP iperf are answered by the hardware in front of the classifier and keep working. The allow list holds up to 16 entries (the tuple slots of this board): the TCP echo and TCP iperf servers while enabled, the TCP connections the board opens, and the `classifier acl` entries. A service port change opens the new port and closes the old one while the firewall stays on. Example: only ARP and the echo server on the telnet port:

```
configure terminal
tcp echo port 23
iperf tcp disable
classifier firewall enable
end
show classifier
```

`classifier firewall disable` returns to the protection profile. The firewall is described in the [RTLNet Specification](../../../documentation/rtnet_specification.md#cpu-path-firewall) and in `cpu/microblaze_v_ethernet/documentation/rtlnet_cpu_eth.md` section 5b.

## Services in the image

| Service | Where | Port |
|---|---|---|
| ARP, ICMP echo (ping) | FPGA fabric | - |
| DHCP client | FPGA fabric | UDP 68 |
| UDP echo | FPGA fabric | UDP 7 |
| UDP iperf 2 server | FPGA fabric | UDP 5001 |
| TCP echo | lwIP on the MicroBlaze V | TCP 7 |
| TCP iperf 2 server | lwIP on the MicroBlaze V | TCP 5001 |

## Hardware tests

The tests are PowerShell scripts in `cpu/microblaze_v_ethernet/test/`. They need the board running this image, its console on a COM port and a PC adapter on the same network.

```
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/run_all.ps1 -Port <COM port> -Nic <adapter> -LinkMbps 1000
```

`-LinkMbps` is `10`, `100` or `1000` and selects the speed the run sets and checks. Run it three times for the three speeds. The individual scripts are `console_test`, `link_test`, `ping_test`, `arp_test`, `dhcp_test`, `udp_echo_test`, `udp_iperf_test`, `tcp_echo_test`, `tcp_throughput_test` and `firewall_test` (`run_all.ps1` runs `link_test` with `-IncludeLink`). `flood_test` runs the protection profile test; `firewall_test.ps1` also runs alone. The results land in `cpu/microblaze_v_ethernet/test/out/results_<speed>.txt` and `.csv`.

## Expected results

Measured on this image (`eth_fw2`, build info in `build_info.txt`) in the campaign of 11-17-2026: the board on a switch to a PC with a Gigabit adapter, iperf 2, 10 s runs (TCP: mean of 3 runs), 64-byte echoes x 2000, firewall off. The [RTLNet Specification](../../../documentation/rtnet_specification.md) compares the released Ethernet images and explains the measurement conditions.

| Test | 10 Mb/s | 100 Mb/s | 1000 Mb/s |
|---|---|---|---|
| Ping, 64 B x 100, lost | 0 | 0 | 0 |
| UDP echo, 64 B, mean / p99, loss | 1.303 / 1.363 ms, 0 | 0.174 / 0.230 ms, 0 | 0.171 / 0.238 ms, 0 |
| UDP iperf PC to board, loss | 9.4 Mb/s, 0 | 94.0 Mb/s, 0 | 943.0 Mb/s, 0 |
| UDP iperf board to PC, loss | 9.4 Mb/s, 0 | 94.4 Mb/s, 0 | 944.0 Mb/s, 0.005 % (20 of 401,242) |
| TCP iperf PC to board, mean (min to max) | 9.5 (9.5 to 9.5) Mb/s | 94.7 (94.5 to 94.9) Mb/s | 336.0 (332.0 to 343.0) Mb/s |
| TCP iperf board to PC, mean (min to max) | 9.5 (9.5 to 9.5) Mb/s | 94.9 (94.9 to 94.9) Mb/s | 281.0 (281.0 to 281.0) Mb/s |
| TCP iperf with the firewall on, PC to board / board to PC | 9.5 / 9.5 Mb/s | 94.5 / 94.9 Mb/s | 337.7 / 280.3 Mb/s |
| `firewall_test.ps1` | `FIREWALL_TEST: PASS 21/21` | `FIREWALL_TEST: PASS 21/21` | `FIREWALL_TEST: PASS 21/21` |
| `run_all.ps1` | `ETH_SUITE: PASS 9/9 scripts` | `ETH_SUITE: PASS 9/9 scripts` | `ETH_SUITE: PASS 10/10 scripts` (with `-IncludeLink`) |

The UDP paths are in hardware and reach the line rate of the link; TCP is limited by the soft CPU (100 MHz MicroBlaze V, block RAM only) at 1000 Mb/s. With the firewall on, the same services give the same figures. Your numbers depend on the PC, the adapter and the switch.

## Protection profile test

`flood_test.ps1` floods the board with UDP, broadcast, multicast, ICMP and ARP frames from the PC while one TCP echo connection runs; the classifier policers hold the flood away from the CPU.

```
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/flood_test.ps1 -Port <COM port> -Nic <adapter> -Rate 1000
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/flood_test.ps1 -Port <COM port> -Nic <adapter> -Rate 100000 -Kinds udp-closed,udp-bcast-net,mcast,icmp-bcast
```

Campaign of 11-17-2026 (1000 Mb/s link, firewall off): `FLOOD_TEST: PASS 95/95` (all kinds at 1000 frames per second) and `FLOOD_TEST: PASS 50/50` (four kinds at 100,000 frames per second offered). `show classifier` prints the per-class counters afterward. With the firewall on, every frame of a 1,000,000-frame unicast flood to a closed port reaches the board and is dropped by the classifier while the TCP echo runs unchanged; a port scan of 199 closed TCP ports and 100 closed UDP ports gets no answer (see the CPU-path firewall section of the specification).

`build_info.txt` in this folder lists the source revision, the timing result and the utilization of the image: 23,891 LUT, 33,968 flip-flops, 228.5 block RAM tiles, 6 DSP blocks, WNS +0.154 ns at the one 100 MHz system clock.
