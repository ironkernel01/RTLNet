<style>
  .markdown-body h1, .markdown-body h2 { color: #1381ee; border-bottom: 2px solid #1381ee; }
  .markdown-body h3 { color: #242424; }
  .markdown-body table th { background: #e8f2fd; }
  .brief-band { background: #1381ee; color: #ffffff; padding: 10px 14px; margin: 6px 0 14px 0; font-size: 15px; }
  .brief-cols { display: flex; gap: 18px; }
  .brief-cols > div { flex: 1; }
  .markdown-body table { font-size: 12px; }
  .markdown-body table td, .markdown-body table th { padding: 1px 6px; line-height: 1.25; }
  .markdown-body { line-height: 1.38; }
  .markdown-body p, .markdown-body li { margin-bottom: 5px; }
  .markdown-body ul, .markdown-body ol, .markdown-body table { margin-bottom: 8px; }
  .markdown-body li + li { margin-top: 2px; }
  @page { size: letter; margin: 10mm 11mm; }
  .markdown-body table + p { margin-top: 4px; }
  .markdown-body .small p, .markdown-body .small li { font-size: 12px; }
  .markdown-body h2 { margin-top: 10px; margin-bottom: 6px; }
  .markdown-body table td:first-child { white-space: nowrap; }
  .markdown-body table.num td:not(:first-child) { text-align: right; }
</style>

<table style="width:100%; border:none; margin:0; padding:0;">
<tr>
<td style="text-align:left; border:none; padding:0; width:50%;"><img src="../../documentation/pdf/ironkernel_logo.png" alt="IronKernel Embedded" style="width:231px; margin:0;"></td>
<td style="text-align:right; border:none; padding:0; width:50%; vertical-align:bottom;"><strong>Demo Brief</strong><br>Revision 11-14-2026</td>
</tr>
</table>

<h1 style="font-size:30px; margin-top:18px;">RTLNet Ethernet Demo for the Nexys Video</h1>

<div class="brief-band">A ready-to-run FPGA image: 10/100/1000 Mb/s Ethernet with ARP, ping, DHCP, UDP echo and UDP iperf 2 in FPGA fabric, and lwIP TCP echo and iperf 2 on a small MicroBlaze V, with a switch-style console.</div>

This demo is a prebuilt bitstream of the IronKernel RTLNet Ethernet stack, with its firmware inside, for a Digilent Nexys Video (AMD Artix-7 XC7A200T). The RGMII MAC and the protocol blocks (ARP, ICMP echo, DHCP client, UDP echo, UDP iperf 2 server) are RTL and work with no CPU in the data path. A small MicroBlaze V at 100 MHz, with no DDR3, no caches, no video and no H.264, runs lwIP for TCP (echo on port 7, iperf 2 server on port 5001) and the console on the USB-UART. Programming takes one script; the image has no time limit.

<div class="brief-cols">
<div>

### Highlights

- Hardware ARP, ICMP echo, DHCP client, UDP echo and UDP iperf 2 server in FPGA fabric; the UDP paths reach line rate
- lwIP TCP echo (port 7) and TCP iperf 2 server (port 5001) on a MicroBlaze V without DDR3 or caches
- 10/100/1000 Mb/s RGMII, full duplex; `speed 10|100|auto` is the only link control; half duplex is never advertised
- Hierarchical, switch-style console (`show ip`, `show phy`, `show counters`, `configure terminal`, `interface eth0`)
- Hardware tests for every service and speed: `cpu/microblaze_v_ethernet/test/run_all.ps1`
- No build needed: the free Vivado license programs the board over JTAG
- Source-available: the RTL, the CPU and the firmware are in the repository, and this image has no time limit

</div>
<div>

### At a glance

| Item | Value |
|---|---|
| Ethernet | 10/100/1000 Mb/s RGMII, full duplex |
| Hardware protocols | ARP, ICMP echo, DHCP client, UDP echo, UDP iperf 2 server |
| TCP | lwIP: echo port 7, iperf 2 server port 5001 |
| CPU | MicroBlaze V, 100 MHz, no DDR3, no caches |
| Console | USB-UART, 115200 8N1 |
| FPGA | xc7a200tsbg484-1 |
| Utilization | TBD(release) |
| Routed timing | TBD(release) |
| Time limit | none |
| License | `LICENSE.md` |

</div>
</div>

## License

The RTLNet sources and this image are under the RTLNet source-available license (`LICENSE.md`).

**Free, no fee:**

- Evaluation and development, including prototypes and demonstrations that are not sold
- Research and teaching
- Hobby and personal projects
- A commercial product whose complete design sources are public under the RTLNet license and whose changes to RTLNet files are offered back as pull requests

**Paid license from IronKernel (ironkernel.com), before the product ships:**

- A commercial product whose design sources are not public

A paid license carries no royalty and no per-unit fee. This demo contains no paid extension and no netlist.

<div class="small">

## How it works

The block diagram is described here; the drawing is added with the release.

```
 PC  <--- Ethernet cable --->  RTL8211E PHY (RGMII)
                                      |
                       RGMII MAC, 10/100/1000 Mb/s
                                      |
                       protocol wrapper (hardware)
          +-------------+-------------+-------------+
          |             |             |             |
     ARP, ICMP echo  DHCP client  UDP echo    UDP iperf 2 server
          |
          +--- frames and TCP segments for the CPU --- AXI DMA, checksum offload
                                      |
                  MicroBlaze V 100 MHz (BRAM only): lwIP TCP, console
                                      |
                              USB-UART (115200 8N1)
```

1. The MAC receives frames from the PHY and the protocol wrapper answers ARP requests, ping, DHCP and the UDP echo and UDP iperf 2 ports in fabric. The CPU sees none of this traffic.
2. Frames the wrapper does not handle (TCP, for example) go to the CPU through an AXI DMA; the checksum offload takes the TCP checksum work from the CPU on transmit and receive.
3. lwIP on the MicroBlaze V serves TCP echo on port 7 and the TCP iperf 2 server on port 5001. The CPU has block RAM only: no DDR3 and no caches.
4. The firmware reads the PHY by MDIO and sets the advertised modes: `speed auto` advertises every full-duplex mode; half duplex is never advertised.

## What you need and run it

A Nexys Video with its 12 V supply, two micro-USB cables (PROG, UART), an Ethernet cable to a network with DHCP, Vivado 2026.1 with its free license and a terminal at 115200 baud 8N1.

1. Program the board: `powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 -Bit demos/ethernet/nexys_video/rtlnet_nexys_video_eth.bit`
2. Open the serial console. The banner `RTLNet Ethernet demo -- rtlnet-eth-fw` and the DHCP lease line appear.
3. `show ip` prints the address; `ping` it from the PC.
4. `show interfaces`, `show phy`, `show arp`, `show counters`, `show tcp`, `show iperf` and `show offload` print the state of each part. `configure terminal`, `interface eth0`, `speed 10|100|auto` sets the link speed.
5. The tests of `cpu/microblaze_v_ethernet/test/` (`run_all.ps1 -Port <COM> -Nic <adapter> -LinkMbps 10|100|1000`) run every service against the board.

## Device utilization and timing

The dev image (the release values are TBD(release)) on the XC7A200T:

<table class="num">
<thead><tr><th></th><th>LUTs</th><th>Flip-flops</th><th>Block RAM tiles</th><th>DSP blocks</th></tr></thead>
<tbody>
<tr><td>Dev image</td><td>22,505</td><td>31,258</td><td>212.5</td><td>6</td></tr>
<tr><td>Share of the device (dev image)</td><td>16.82 %</td><td>11.68 %</td><td>58.22 %</td><td>-</td></tr>
<tr><td>Release image</td><td>TBD(release)</td><td>TBD(release)</td><td>TBD(release)</td><td>TBD(release)</td></tr>
</tbody>
</table>

Routed timing, dev image: WNS +0.221 ns, WHS +0.013 ns, WPWS +0.264 ns. Release image: WNS, WHS and WPWS TBD(release). The CPU clock is 100 MHz.

## Measured performance

Method: a PC with a wired Gigabit-class network adapter is connected to the board through an unmanaged switch. The tests are the scripts of `cpu/microblaze_v_ethernet/test/` (`run_all.ps1`, one run per link speed); throughput is measured with iperf 2 (UDP and TCP, both directions); latency with a UDP echo of small datagrams; ping with the PC's ping tool. The release campaign sets every value; until then each cell is TBD(release).

<table class="num">
<thead><tr><th>Test</th><th>10 Mb/s</th><th>100 Mb/s</th><th>1000 Mb/s</th></tr></thead>
<tbody>
<tr><td>Ping, loss and round trip</td><td>TBD(release)</td><td>TBD(release)</td><td>TBD(release)</td></tr>
<tr><td>UDP echo, mean and p99 latency, loss</td><td>TBD(release)</td><td>TBD(release)</td><td>TBD(release)</td></tr>
<tr><td>UDP iperf 2, PC to board, Mbit/s and loss</td><td>TBD(release)</td><td>TBD(release)</td><td>TBD(release)</td></tr>
<tr><td>UDP iperf 2, board to PC, Mbit/s and loss</td><td>TBD(release)</td><td>TBD(release)</td><td>TBD(release)</td></tr>
<tr><td>TCP iperf 2, PC to board, Mbit/s</td><td>TBD(release)</td><td>TBD(release)</td><td>TBD(release)</td></tr>
<tr><td>TCP iperf 2, board to PC, Mbit/s</td><td>TBD(release)</td><td>TBD(release)</td><td>TBD(release)</td></tr>
</tbody>
</table>

Indicative values on the development image at 1000 Mb/s, not release values: ping with no loss and under 1 ms; UDP echo mean 0.17 ms, p99 0.24 to 0.31 ms, no loss; UDP iperf 944 Mbit/s in both directions with no loss; TCP iperf 311 Mbit/s PC to board and 106 Mbit/s board to PC.

## Captures

The pictures (console sessions and test results) are in `images/`. They are added with the release.

## Console commands

| Command | Effect |
|---|---|
| `show version`, `show interfaces`, `show phy` | firmware; interface state; link speed, advertised modes and the partner's modes |
| `show ip`, `show dhcp`, `show arp` | address; DHCP client and lease; ARP table |
| `show counters`, `show tcp`, `show iperf`, `show offload` | frame and protocol counters; TCP connections; iperf server counters; checksum offload counters |
| `configure terminal`, `interface eth0` | configuration mode and the interface |
| `speed 10\|100\|auto` | the only link control; `auto` advertises every full-duplex mode, half duplex is never advertised |
| `ip dhcp`, `renew` | DHCP on the interface; ask for the lease again |

## Arty A7-100 (10/100)

The design is built out for the Digilent Arty A7-100 (10/100 Mb/s MII), but it is not yet tested on the hardware. The demo for that board is added when the hardware test has run.

## Limits

- TCP is limited by the soft CPU: the MicroBlaze V runs at 100 MHz with block RAM only, so TCP iperf stays well below line rate at 1000 Mb/s. The UDP paths (echo, iperf 2, ping, ARP, DHCP) are in hardware and reach line rate.
- The link is full duplex only; half duplex is never advertised.
- The demo has no DDR3, no video and no H.264; it is the network stack alone.
- The image has no time limit. It loads over JTAG only; a power cycle removes it.
- The performance table holds placeholders until the release campaign has run.
</div>
