# Ethernet Demo on the Arty A7-100T

Revision 11-17-2026

The RTLNet Ethernet stack on a Digilent Arty A7-100T: 10/100 Mb/s MII (TI DP83848J PHY), hardware ARP, ICMP echo, DHCP client, UDP echo and a UDP iperf 2 server in FPGA fabric, plus lwIP TCP (echo on port 7, iperf 2 server on port 5001) on a small MicroBlaze V. One 100 MHz system clock runs the CPU and the protocol blocks; the CPU runs from 256 KiB of on-chip block RAM with no caches. A classifier with per-class policers (in distributed RAM on this board) protects the CPU from floods; `classifier firewall enable` turns it into a default-deny firewall in which only ARP and the ports of the running TCP services reach the CPU. The console is a hierarchical, switch-style CLI on the USB-UART. There is no time limit and no netlist in this image.
License: `LICENSE.md` in the repository root.

The image file is `rtlnet_arty_a7_100_eth.bit`: the hardware of `boards/arty_a7_100/scripts/build_ethernet.ps1 -Tag arty_rel` with the firmware merged in by `build_ethernet.ps1 -Tag arty_fw2 -SkipBitstream` (`build_info.txt` lists both revisions). The firmware runs in its small-memory profile.

## What you need

- Digilent Arty A7-100T and one micro-USB cable (J10: power, JTAG and the USB-UART).
- An Ethernet cable from the board (J9) to a switch or hub of the network of the PC. **Auto-MDIX is off on this board** (strap resistor): use a straight-through cable to a switch; a direct connection to a PC needs a crossover cable unless the PC port does auto-MDIX. A DHCP server on the network gives the board its address.
- Vivado 2026.1 with its free license, to program the board.
- A terminal on the board's serial port at 115200 baud, 8N1 (the FT2232HQ shows two interfaces: JTAG and one COM port).
- For the tests: PowerShell and iperf 2 (`iperf.exe`) on the PC.

## Jumpers

| Jumper | Setting |
|---|---|
| JP1 | any position for JTAG programming; the SPI position only boots from the Quad-SPI flash, which this demo does not use |
| JP2 (CK_RST) | when shorted, the USB-UART bridge can pull the board's RESET line when a program opens the COM port, which restarts the design. No restart was seen when the test scripts or a console opened the port many times in the campaign (the uptime counter kept running across the opens) (the jumper position of the tested board was not recorded); if the design restarts at every open, remove the jumper |

## Steps

1. Program the board over JTAG. The image is not written to the flash; it is gone after a power cycle. The script takes the machine-wide board lock and programs only a JTAG target whose chain holds an xc7a100t (another board on the PC is never selected).

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File boards/arty_a7_100/scripts/program.ps1 -Bit demos/ethernet/arty_a7_100/rtlnet_arty_a7_100_eth.bit
   ```

2. Open the serial console. After power-up it prints the banner `RTLNet Ethernet demo -- rtlnet-eth-fw`, `Board ARTY`, the PHY line (`PHY: DP83848 ID 0x20005C90 at address 1 ...`) and, once the server has answered, the DHCP lease.

3. Check the board: `show ip` prints the address, `show phy` the link speed. From the PC: `ping <board address>`.

The CLI is hierarchical like a network switch (`configure terminal`, `interface eth0`, `end`). The `show` commands are `show version`, `show system`, `show interfaces`, `show phy`, `show ip`, `show dhcp`, `show arp`, `show counters`, `show tcp`, `show iperf`, `show offload` and `show classifier`. Link speed is the only link control:

```
configure terminal
interface eth0
speed 100
end
```

`speed` takes `10`, `100` or `auto`. `auto` advertises 10 and 100 Mb/s full duplex (this board has no gigabit mode); half duplex is never advertised.

## Firewall

The CPU path has a default-deny firewall, off at boot. With it on, only ARP and an allow list reach lwIP; every other frame is dropped by the classifier in hardware, so a closed port gives no RST and no ICMP port unreachable. Ping, DHCP, UDP echo and UDP iperf are answered by the hardware in front of the classifier and keep working. The allow list holds up to 8 entries (the tuple slots of this board): the TCP echo and TCP iperf servers while enabled, the TCP connections the board opens, and the `classifier acl` entries. A service port change opens the new port and closes the old one while the firewall stays on. Example: only ARP and the echo server on the telnet port:

```
configure terminal
tcp echo port 23
iperf tcp disable
classifier firewall enable
end
show classifier
```

`classifier firewall disable` returns to the protection profile. The firewall is described in the brief and in `cpu/microblaze_v_ethernet/documentation/rtlnet_cpu_eth.md` section 5b.

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

The tests are the PowerShell scripts of `cpu/microblaze_v_ethernet/test/`. Find the COM port of the board in the Device Manager.

```
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/run_all.ps1 -Port <COM port> -Nic <adapter> -LinkMbps 100
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/run_all.ps1 -Port <COM port> -Nic <adapter> -LinkMbps 10
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/flood_test.ps1 -Port <COM port> -Nic <adapter> -Rate 1000
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/flood_test.ps1 -Port <COM port> -Nic <adapter> -Rate 100000 -Kinds udp-closed,udp-bcast-net,mcast,icmp-bcast
```

`run_all.ps1` includes `firewall_test.ps1`, which also runs alone:

```
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/firewall_test.ps1 -Port <COM port> -Nic <adapter>
```

`-LinkMbps` is `10` or `100` (not 1000). The results land in `cpu/microblaze_v_ethernet/test/out/` (`-OutDir` selects another folder).

## Expected results

Measured on this image (`arty_fw2`, build info in `build_info.txt`) in the campaign of 11-17-2026: the board on a switch to a PC with a Gigabit adapter, iperf 2, 10 s runs (TCP: mean of 3 runs), 64-byte echoes x 2000. The brief (`ethernet_arty_a7_100_brief.md`, `ethernet_arty_a7_100_brief.pdf`) holds the same table with the method.

| Test | 10 Mb/s | 100 Mb/s |
|---|---|---|
| Ping, 64 B x 100, lost | 0 | 0 |
| UDP echo, 64 B, mean / p99, loss | 0.365 / 0.426 ms, 0 | 0.165 / 0.221 ms, 0 |
| UDP iperf PC to board, loss | 9.4 Mb/s, 0 | 94.0 Mb/s, 0 |
| UDP iperf board to PC, loss | 9.4 Mb/s, 0 | 94.4 Mb/s, 0 |
| TCP iperf PC to board, mean (min to max) | 9.5 (9.5 to 9.5) Mb/s | 94.5 (94.3 to 94.7) Mb/s |
| TCP iperf board to PC, mean (min to max) | 9.5 (9.5 to 9.5) Mb/s | 94.9 (94.9 to 94.9) Mb/s |
| TCP iperf with the firewall on, PC to board / board to PC | | 94.4 / 94.9 Mb/s |
| `firewall_test.ps1` | `FIREWALL_TEST: PASS 21/21` | `FIREWALL_TEST: PASS 21/21` |
| `run_all.ps1` | `ETH_SUITE: PASS 9/9 scripts` | `ETH_SUITE: PASS 10/10 scripts` (with `-IncludeLink`) |

Flood test at 100 Mb/s: `FLOOD_TEST: PASS 95/95` (all kinds, 1000 frames per second) and `FLOOD_TEST: PASS 50/50` (four kinds at 100,000 frames per second offered). `link_test.ps1`: `LINK_TEST: PASS 18/18`. With the firewall on, every flood frame that reaches the board is dropped by the classifier and the TCP echo stays byte-exact; a 100,000 per second unicast flood fills the 100 Mb/s wire and slows the echo upstream of the board (brief, section CPU-path firewall).

`build_info.txt` in this folder lists the source revision, the timing result and the utilization of the image: 24,981 LUT, 36,059 flip-flops, 105.5 block RAM tiles, 6 DSP blocks, WNS +0.142 ns at the one 100 MHz system clock.

Not verified: boot from the Quad-SPI flash, a direct cable connection to a PC without a crossover, behavior with JP2 shorted.
