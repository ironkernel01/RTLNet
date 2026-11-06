<style>
  .markdown-body h1, .markdown-body h2 { color: #1381ee; border-bottom: 2px solid #1381ee; }
  .markdown-body h3 { color: #242424; }
  .markdown-body table th { background: #e8f2fd; }
  .brief-band { background: #1381ee; color: #ffffff; padding: 10px 14px; margin: 6px 0 14px 0; font-size: 15px; }
  .brief-cols { display: flex; gap: 18px; }
  .brief-cols > div { flex: 1; }
  .markdown-body table { font-size: 12px; }
  .markdown-body table td, .markdown-body table th { padding: 4px 8px; }
  .markdown-body table td:first-child { white-space: nowrap; }
  .markdown-body table.num td:not(:first-child) { text-align: right; }
</style>

<table style="width:100%; border:none; margin:0; padding:0;">
<tr>
<td style="text-align:left; border:none; padding:0; width:50%;"><img src="pdf/ironkernel_logo.png" alt="IronKernel Embedded" style="width:231px; margin:0;"></td>
<td style="text-align:right; border:none; padding:0; width:50%; vertical-align:bottom;"><strong>Product Brief</strong><br>Revision 11-06-2026</td>
</tr>
</table>

<h1 style="font-size:30px; margin-top:18px;">RTLNet Ethernet/IPv4 Stack for FPGAs</h1>

<div class="brief-band">An Ethernet and IPv4 network stack in SystemVerilog: ARP, ICMP, DHCP, UDP and iperf answered
in logic at line rate, and TCP on an optional soft CPU with hardware checksum offload.</div>

IronKernel RTLNet gives an FPGA design its own network interface without a processor in the data path. The
Ethernet MAC, ARP, ICMP echo, the DHCP client, UDP sockets and an iperf 2 UDP server are RTL cores that answer
the network in logic. Frames the logic does not claim go to an optional soft CPU over AXI DMA, where lwIP 2.2.0
serves TCP; a classifier and a checksum offload core sit on that path. On the reference board, a Digilent Nexys
Video with an AMD Artix-7 XC7A200T and a Realtek RTL8211E PHY, UDP iperf runs at 94.4 Mbit/s with no loss and
TCP at 94.9 Mbit/s on a 100 Mb/s link, with the MicroBlaze 35 % busy. Every data path is a 64-bit AXI4-Stream,
the width a 10G/25G MAC needs, and every core has an AXI4-Lite register slave and a C driver. Vendor-specific
cells live in four mapped files chosen by one include file, so the protocol logic carries over to another
FPGA family unchanged.

<div class="brief-cols">
<div>

### Highlights

- ARP, ping, DHCP, UDP sockets and UDP iperf in logic: no CPU cycles, no software latency
- TCP through lwIP on a soft CPU, at 94.9 Mbit/s each way on a 100 Mb/s link
- Hardware checksum offload: IPv4, TCP and UDP checksums inserted on transmit and checked on receive; the CPU is 35 % busy at TCP line rate, against 81 % with a receive copy
- Frame classifier on the CPU path: L2 to L4 tables, rules and policers, drop-all until configured; the broadcast storm limiter holds 10 frames per 100 ms under a 400 frame/s flood
- Vendor-neutral SystemVerilog-2012; one include file selects AMD, Altera, Lattice or a generic model
- 64-bit AXI4-Stream and AXI4-Lite on every core; the protocol layer is sized for a 10G/25G MAC
- Firmware finds the optional blocks from capability bits and configures lwIP from what the hardware reports
- Network-switch style command line on the USB-UART
- 76 of 76 simulation benches pass, each with a forced-failure control

</div>
<div>

### At a glance

| Item | Value |
|---|---|
| Line rates | 10/100/1000 Mb/s RGMII; 10 and 100 tested on hardware, 1000 in simulation |
| In RTL | Ethernet II, ARP, IPv4, ICMP echo, DHCP client, UDP, iperf 2 UDP |
| On the CPU | TCP (lwIP 2.2.0), TCP iperf 2, TCP echo |
| FPGA | AMD Artix-7 XC7A200T-1 (Digilent Nexys Video) |
| PHY | Realtek RTL8211E, RGMII; MDIO Clause 22 and 45 |
| Full build | 21,771 LUTs (16 %), 31,209 FFs (12 %), CPU included |
| Clocks | MAC 125 MHz, stream 62.5 MHz, protocol 50 MHz, CPU 100 MHz |
| Languages | SystemVerilog-2012, C11 |
| Tools | AMD Vivado and Vitis 2025.2, Aldec Active-HDL 11.1 |

</div>
</div>

<div style="page-break-after: always;"></div>

## How it works

**Figure 1.** RTLNet in the FPGA (product-brief, sheet 1)

<img src="../diagrams/out/png/product-brief-1.png" alt="RTLNet cores in the FPGA and what they connect to" style="width:72%;">

Each received frame passes the MAC's FCS check and the protocol wrapper's destination-MAC filter, and the
wrapper then presents it to every protocol leaf at once. A leaf that answers or accepts the frame raises a claim
pulse; a frame that no leaf claims is copied to the CPU path, through the classifier and the receive checksum
check, into the CPU's DMA buffers. Replies from the leaves and frames from the CPU meet at a fixed-priority
arbiter that switches only between frames. The leaves never stall the stream: a full queue drops and counts
whole frames.

| Area | Features |
|---|---|
| Ethernet MAC | 10/100/1000 Mb/s RGMII; FCS, padding, inter-frame gap; 8 KiB RX and TX queues; speed from the PHY status |
| PHY management | MDIO, Clause 22 and 45; RTL8211E driver: RX delay, auto-negotiation, forced speed, loopback, register dump |
| Protocol wrapper | destination-MAC filter; 16 KiB ingress and 8 KiB egress queues; DHCP lease or static address as the node address |
| ARP, ICMP, DHCP | ARP replies; ping replies up to 1472-byte payloads; DHCP client with renew and lease loss |
| UDP sockets | 4 sockets (a parameter), connect-on-receive, 16 KiB receive and 8 KiB transmit payload buffers; payload AXI4-Stream to user logic with two metadata beats |
| iperf 2 | UDP server in RTL with server report and `-R` reverse stream; TCP server in firmware with `-R`, `-r` and `-d` |
| Frame classifier | MAC, EtherType, VLAN, IP and port tables (single, range, mask), tuple ACL, byte-mask rule engines; policers in frames per period; drop-all at power-up |
| Checksum offload | transmit: IPv4 header and TCP/UDP checksums written into the frame, with one 802.1Q tag; receive: cut-through check and an 8-byte result trailer; bit-exact pass-through at power-up |
| Soft CPU | MicroBlaze at 100 MHz from block RAM, AXI DMA, lwIP raw API; any CPU with the same ports replaces it |
| Command line | switch-style modes on the USB-UART: `show interfaces`, `show ip`, `show storm-control`, `show offload`; configuration of interface, DHCP, sockets and classifier |
| Build options | buffer sizes as `*_KB` parameters; each leaf and each CPU-path block enabled per build; elaboration stops on a size a core cannot build |

<div style="page-break-after: always;"></div>

## Measured on hardware

Nexys Video on a 100 Mb/s link to a PC wired NIC, iperf 2.2.2, 10 s runs. The 100 Mb/s ceiling for
1470-byte UDP payloads is 95.6 Mbit/s.

| Traffic | Result |
|---|---|
| UDP iperf, PC to board (RTL server) | 94.1 Mbit/s, 0 of 40,093 datagrams lost |
| UDP iperf, board to PC (`-R`, RTL) | 94.4 Mbit/s, 0 of 40,126 datagrams lost |
| TCP iperf, PC to board (lwIP) | 94.8 Mbit/s |
| TCP iperf, board to PC (`-R`) | 94.9 Mbit/s |
| TCP iperf, both directions (`-d`) | board to PC 93.8, PC to board 27.0 Mbit/s |
| TCP and UDP iperf together | TCP 72.2 Mbit/s, RTL UDP 20.9 Mbit/s with 0 of 17,825 lost |
| MicroBlaze load at TCP line rate | 35 % with zero-copy receive and offload; 81 % with a receive copy |
| Broadcast flood, 400 frames/s for 10 s | 1,003 of 3,998 broadcasts reach the CPU; ping 14 of 14, TCP echo 8 of 8 runs pass |

| TCP iperf, Mbit/s | Offload off | Offload on |
|---|---|---|
| PC to board | 89.6 | 94.8 |
| Board to PC (`-R`) | 81.4 | 94.9 |
| Both directions (`-d`), board to PC + PC to board | 60.0 + 21.2 | 93.7 + 26.4 |

## Resources

Vivado 2025.2, XC7A200T-1, default parameters. Core rows are out-of-context synthesis; the protocol wrapper row
contains the five leaves and the CPU-path queues.

<table class="num">
<thead><tr><th>Core</th><th>LUTs</th><th>FFs</th><th>Block RAM tiles</th></tr></thead>
<tbody>
<tr><td>Ethernet MAC</td><td>1,104</td><td>1,682</td><td>5</td></tr>
<tr><td>MDIO</td><td>57</td><td>97</td><td>0</td></tr>
<tr><td>Protocol wrapper with every leaf</td><td>9,432</td><td>12,737</td><td>24.5</td></tr>
<tr><td>&nbsp;&nbsp;of which ARP / ICMP / DHCP</td><td>314 / 860 / 1,287</td><td>547 / 771 / 1,804</td><td>0 / 1 / 1</td></tr>
<tr><td>&nbsp;&nbsp;of which iperf / UDP sockets</td><td>2,661 / 2,640</td><td>3,694 / 2,601</td><td>0 / 8.5</td></tr>
<tr><td>UDP echo application</td><td>279</td><td>648</td><td>0</td></tr>
<tr><td>Frame classifier (implemented)</td><td>3,351</td><td>6,217</td><td>30</td></tr>
<tr><td>Checksum offload</td><td>1,867</td><td>3,613</td><td>1.5</td></tr>
<tr><td>Full board build, post-route</td><td>21,771 (16.3 %)</td><td>31,209 (11.7 %)</td><td>229 (62.7 %), 162 of them CPU memory</td></tr>
</tbody>
</table>

<div style="page-break-after: always;"></div>

## Verification

| Evidence | Result |
|---|---|
| Simulation regression (Active-HDL) | 76 benches run, 76 passed; each bench checks against oracles independent of the RTL (bit-serial CRC-32, RFC 1071 checksum, bench-built frames) and runs once more with a forced failure that must report `TEST FAIL` |
| Board bench | the real board top against an RTL8211E RGMII and MDIO model at 10, 100 and 1000 Mb/s: 141 checks pass |
| Firmware host tests | discovery, offload configuration and command line: 364 checks pass; lwIP iperf loopback 69; network interface tests for the four zero-copy builds |
| Hardware tests | command line 28 of 28, network 25 of 25 (ping sweep to 1472 bytes, UDP echo, UDP iperf, forced 10 Mb/s), TCP 8 of 8, checksum offload 19 of 19 with 492,467 frames patched, 361,494 verified and no bad checksum |
| Timing | full build post-route: WNS +0.221 ns, no failing setup, hold or pulse-width endpoint; the checksum offload closes at 250 MHz out of context on a -3 Artix-7 |
| Clock crossings | every crossing uses one of six crossing cores; a constraint script finds each one by name, bounds it, and fails the build when the count differs from the expected census |

## Offerings

| Offering | Contents |
|---|---|
| Source license | SystemVerilog cores, C drivers, Active-HDL benches, firmware and core guides, per project, with 12 months of updates and support; units are royalty-free |
| Evaluation bitstream | the full stack and command line for the Digilent Nexys Video, with the PC test scripts |
| Engineering services | port to your FPGA family, board and PHY; protocol leaves or user logic on the UDP socket streams; bring-up on your network |

### Hardware needed

RTLNet needs an FPGA I/O bank with DDR input and output registers for RGMII, an RGMII PHY with MDIO, and a
clock source for 125 MHz; the reference design uses the PHY's receive delay and a 90-degree transmit clock. The RTL protocols run with no
processor. The TCP path needs a soft or hard CPU with a DMA engine and about 430 KiB of on-chip memory for code,
lwIP pools and DMA buffers (reference build: 387 KiB of local memory and 36 KiB of DMA buffers).

### Limits

- 1000 Mb/s is verified in simulation and constrained for timing; its hardware test waits for a gigabit link
  partner.
- The RGMII pin layer exists for AMD 7-series and as a generic model; a port to another family adds that
  family's pin-layer file.
- The MAC is 10/100/1000 Mb/s. A 10G/25G MAC connects to the same 64-bit stream and is not part of the release.
- The board loads over JTAG; boot from Quad-SPI flash is not set up.
