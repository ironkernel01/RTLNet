# RTLNet Ethernet CPU (MicroBlaze V) -- core and firmware guide

| Item | Value |
|---|---|
| Document revision | 11-17-2026 |
| Folder | `cpu/microblaze_v_ethernet/` |
| Wrapper module | `rtlnet_cpu_eth` (`hdl/rtlnet_cpu_eth.sv`), block design `rtlnet_cpu_eth_bd` (`hdl/rtlnet_cpu_eth_bd.tcl`), simulation stub `rtlnet_cpu_eth_sim_stub` |
| Board dependence | none: the folder names no board, pin, part, PHY type or clock rate |
| First board | Nexys Video (`boards/nexys_video/hdl/rtlnet_nexys_video_eth_top.sv`) |
| Second board | Arty A7-100T (`boards/arty_a7_100/hdl/rtlnet_arty_a7_100_eth_top.sv`, MII, 10/100): the same sources, `-LmbKb 256 -BufKb 64`; simulated, built with timing met and measured on the board at 10 and 100 Mb/s (section 6a, release image `arty_rel`) |

## 1. Purpose

A small MicroBlaze V system for the RTLNet Ethernet cores: it runs the firmware for DHCP, ARP, ping, UDP and lwIP TCP on the
CPU network path of `rtlnet_eth_protocol`, and a hierarchical CLI on the USB-UART. There is no DDR3, no cache, no video and
no H.264. The CPU, its firmware and its tests are one self-contained folder, independent of `cpu/microblaze_v_h264/`
(nothing is included from it); shared drivers stay in `cores/<core>/driver` and are compiled from there.

```
cpu/microblaze_v_ethernet/
  hdl/          rtlnet_cpu_eth.sv (wrapper), rtlnet_cpu_eth_bd.tcl (block design procedure),
                rtlnet_cpu_eth_sysregs.sv (system registers), rtlnet_cpu_eth.f (filelist)
  rtlnet_cpu_eth_sim_stub.sv   simulation stand-in for the CPU core (board benches)
  driver/       rtlnet_cpu_eth.h (address map, interrupts), rtlnet_cpu_eth_sysregs.h (register map)
  firmware/     src/ (platform, board facts, PHY table, network manager, CPU path, offload, lwIP port),
                cli/ (MenuBuilder CLI: cli_commands.txt, gen_menu.py, check_menu.py, generated tables, MenuDocumentation.md),
                host/ (desktop harness with scripted session), test/ (host unit tests, regression.txt), bsp/, build.ps1
  test/         board-independent hardware tests (PowerShell 5.1 and Python 3): console, link, ping, ARP, DHCP, UDP echo,
                UDP iperf, TCP echo, TCP throughput, the protection profile flood test (flood_test.ps1, eth_flood_test.py), and run_all.ps1
  documentation/ this document
```

## 2. Block design (`rtlnet_cpu_eth_bd_create <bd_dir> <cpu_clk_hz> <lmb_kb> [<axi_bram_kb> [<cpu_opt> <cpu_btc> <cpu_muldiv> [<lmb_buf>]]]`)

The procedure takes the clock frequency, the memory sizes and the processor options as arguments; the board build script passes them
(`boards/nexys_video/scripts/build_ethernet.tcl`: `-CommonClk`, `-CpuClkHz`, `-LmbKb` 512, `-BufKb` 128, `-CpuOpt`, `-CpuBtc`, `-CpuMuldiv`, `-LmbBuf` 1;
`boards/arty_a7_100/scripts/build_ethernet.tcl`: the same without `-CommonClk`, defaults `-LmbKb` 256 and `-BufKb` 64). The design is named `rtlnet_cpu_eth_bd` because the generated
module takes the design name and must not collide with the wrapper `rtlnet_cpu_eth`; the generated wrapper is
`rtlnet_cpu_eth_bd_wrapper`, the processor path in the bitstream is `u_cpu/u_bd/rtlnet_cpu_eth_bd_i/microblaze_0`.

| Cell | Configuration |
|---|---|
| `microblaze_0` | MicroBlaze V (`microblaze_riscv`), RV32IMC with Zicsr, Zba, Zbb, Zbs, barrel shifter, multiplier and divider, no MMU, no FPU, no caches, debug enabled, no bus exceptions, reset vector 0; pipeline `cpu_opt` 0 performance (default), 1 area, 2 frequency; branch target cache `cpu_btc` 0..7; `cpu_muldiv` 0..2 (values of the 2026.1 IP) |
| `lmb_bram` (+ ILMB/DLMB) | `<lmb_kb>` KiB at 0x0000_0000: code, data, heap, stack and the lwIP pools. This is the RAM-instancing parameter of the design (`*_KB` rule); 512 KiB for the firmware as built (about 346 KiB used) |
| `mdm_0` | MDM RISC-V, serial JTAG debug, no JTAG UART, no AXI slave |
| `axi_uartlite_0` | console, 115200 8N1 |
| `axi_timer_0`, `axi_intc_0` | time base (timer 0 free running, timer 1 a 1 ms interrupt), interrupt controller |
| `axi_dma_0` + `axi_bram_ctrl_0` + `axi_bram` + `dlmb_buf_cntlr` | CPU network path DMA (simple mode, 64-bit streams, data realignment on MM2S) and its `<axi_bram_kb>` KiB frame buffer RAM (128 KiB for the Ethernet design): one true dual-port block RAM, port A on the AXI BRAM controller `axi_bram_ctrl_0` (32-bit; the 64-bit DMA channels are width-converted in `axi_mem`), port B on a second LMB BRAM controller `dlmb_buf_cntlr` on the data-side LMB (CPU access in 1-2 clocks). With `lmb_buf` 0 (the earlier layout, not the firmware of this tree) the block RAM is single-port and the CPU reaches it over `M_AXI_DP` (about 16 clocks per access) |
| `axi_periph`, `axi_mem` | interconnects: CPU to five peripherals (six with `lmb_buf` 0: the buffer RAM path); both DMA channels to the AXI side of the buffer RAM |
| ports | `clk`, `resetn`, `uart` (rxd, txd), `irq[7:0]`, `M_AXI_RTLNET` (AXI4-Lite master, 32-bit), `S_AXIS_ETH` / `M_AXIS_ETH` (RTLNet frame streams, 64-bit) |

### Address map

| Address | Size | Peripheral |
|---|---|---|
| 0x0000_0000 | `lmb_kb` KiB | LMB block RAM (instructions and data) |
| 0x4040_0000 | 64 KiB | AXI DMA registers |
| 0x4060_0000 | 64 KiB | AXI UART Lite |
| 0x4120_0000 | 64 KiB | AXI INTC |
| 0x41C0_0000 | 64 KiB | AXI Timer |
| 0x44A0_0000 | 1 MiB | RTLNet register window (`M_AXI_RTLNET`), table below |
| 0x0010_0000 | `axi_bram_kb` KiB | frame buffer RAM, CPU view: data-side LMB, data only (DMA frame buffers, lwIP heap); linker section `.axi_bram` |
| 0xC000_0000 | `axi_bram_kb` KiB | the same bytes, DMA view: the address the AXI DMA is programmed with (through `axi_bram_ctrl_0`); the CPU does not use it |

The two views are a fixed offset apart: DMA address = CPU address + `RTLNET_CPU_BUF_DMA_OFFSET` (0xBFF0_0000, `driver/rtlnet_cpu_eth.h`). The firmware
links the frame buffers and lwIP's heap at the CPU view and adds the offset in exactly two places, `rtlnet_lwip_netif.c` `DMA_ADDR()` for the S2MM and
MM2S transfers. `axi_bram_kb` 128 holds the 36 KiB of frame buffers (16 receive, 2 transmit buffers of 2 KiB) and the 64 KiB lwIP heap that zero-copy
transmit needs (about 100 KiB); the 64 KiB of the earlier layout did not hold both. Block RAM cost of the 128 KiB: 32 tiles (RAMB36) against 16 for 64 KiB.

RTLNet window as decoded by the board top (`rtlnet_axil_decoder`): SYS 0x44A0_0000 (4 KiB), MAC 0x44A0_1000, MDIO 0x44A0_2000,
UDP echo 0x44A0_3000, protocol wrapper 0x44A1_0000 (64 KiB; leaves ARP 0x1000, ICMP 0x2000, DHCP 0x3000, iperf 0x4000, UDP sockets
0x5000, classifier 0x8000, checksum offload 0x9000 inside it). Other addresses answer DECERR.

### Interrupt map (INTC inputs)

| Input | Source |
|---|---|
| 0 | `irq[0]`: `rtlnet_mdio` |
| 1..7 | `irq[1..7]`: free (tied 0 by the Nexys Video top) |
| 8 | AXI Timer |
| 9 | UART Lite |
| 10 | DMA MM2S |
| 11 | DMA S2MM |

## 2a. Clock tree (board top parameter `COMMON_CLK`)

The Nexys Video top (`rtlnet_nexys_video_eth_top.sv`) has one MMCM (100 MHz in, VCO 1000 MHz). Besides the system clock only the clocks the RGMII
interface and the I/O primitives force exist: the RGMII receive clock of the PHY (inside `u_mac`, not the top's), `clk125` and `clk125_90` (RGMII
transmit side: MAC transmit clock and TXC forwarding) and `clk200` (IDELAYCTRL reference). `COMMON_CLK` chooses what runs the CPU, the protocol and the MAC
client side:

| `COMMON_CLK` | Clocks | State |
|---|---|---|
| 2 (default) | ONE system clock, `CPU_CLK_HZ` = 100 MHz: `axis_clk = proto_clk = cpu_clk` (nets of one buffer), one reset release; the MMCM outputs for the 62.5 and 50 MHz clocks are unused | builds, closes and runs on the board: image `eth_cc100c` (section 6c) |
| 0 | multi-clock tree: `axis_clk` 62.5 MHz (MAC client, protocol filter), `proto_clk` 50 MHz (leaves, UDP echo), `cpu_clk` `CPU_CLK_HZ` (CPU, AXI4-Lite, DMA, CPU path) | builds and closes (development image `eth_dev`, WNS +0.221 ns); kept buildable |

In both modes the cores keep their clock-crossing parts: they have no same-clock option (only `rtlnet_axil_cdc` has `SYNC`, which no Ethernet core exposes). With one
system clock they are correct but cost a few clocks of latency and block RAM; making them pass-throughs is a later saving. The constraint files declare
no clock group and no false path between the system clocks; `rtlnet_constrain_cdc.tcl` bounds the crossings by cell name, and the paths between logic that
shares a clock are timed normally. The build's CDC census expects the same FIFO, Gray and bridge instances in all modes:

| Crossing element | Instances | Clocks it joins (mode 0) | Same-clock option in the core |
|---|---|---|---|
| `rtlnet_packet_fifo` `u_mac/u_rx_fifo` | 1 | RGMII receive clock -> `axis_clk` | none; the receive clock is always asynchronous |
| `rtlnet_packet_fifo` `u_mac/u_tx_fifo` + Gray `u_mac/u_tx_count_sync` | 1 + 1 | `axis_clk` -> `clk125` | none (kept; correct on one clock) |
| `u_protocol/u_ingress_fifo`, `u_egress_fifo` + four Gray frame counters | 2 + 4 | `axis_clk` <-> `proto_clk` | none (kept) |
| `u_protocol/g_cpu.u_cpu_rx_fifo`, `u_cpu_tx_fifo` + Gray `u_cnt_cpu_reject_sync` | 2 + 1 | `proto_clk` <-> `cpu_clk` | none (kept) |
| `u_protocol/g_cpu.g_offload.u_cpu_offload/u_tx/u_tx_fifo` | 1 | CPU path stream | none (core of the offload; not touched) |
| UDP socket layer `u_rx_fifo`, `u_tx_fifo`, `u_tx_desc_fifo` | 3 | `proto_clk` <-> `app_clk` (the same clock in every mode) | none (kept) |
| `rtlnet_axil_cdc` in `u_mac`, `u_protocol`, `u_echo`, the classifier and the checksum offload register blocks | 5 | `cpu_clk` -> `clk125` / `proto_clk` | `SYNC` parameter exists in the common block, not exposed by these cores (kept) |
| `rtlnet_reset_sync` | 7 (mode 0), 5 (mode 2) | one per clock plus the MAC's two receive-clock chains | n/a |
| `rtlnet_sync` level synchronizers (board pins, MAC status, MDIO) | 28 | asynchronous pins and status levels | n/a |

## 3. System registers (`rtlnet_cpu_eth_sysregs.sv`, window SYS)

AXI4-Lite slave, single definition of the map in `driver/rtlnet_cpu_eth_sysregs.h`. Parameters set by the board top: `BUILD_ID`,
`BUILD_DIRTY`, `BOARD_ID` (four ASCII characters), `CPU_CLK_HZ`, `LINK_CAPS`, `NUM_LED`, `NUM_SW`, `NUM_BTN`, `MS_CYCLES`.

| Offset | Register | Access | Content |
|---|---|---|---|
| 0x000 | ID | RO | `ETHS` (0x45544853) |
| 0x004 | VERSION | RO | 0x11142026 |
| 0x008 | CAPS | RO | [15:8] LEDs, [23:16] switches, [31:24] buttons |
| 0x00C | BUILD_ID | RO | git hash, first 8 hex digits |
| 0x010 | BUILD_DIRTY | RO | bit 0: tree had uncommitted changes |
| 0x014 | BOARD_ID | RO | four ASCII characters naming the board (Nexys Video: `NXVD`, Arty A7-100T: `ARTY`) |
| 0x018 | CPU_CLK_HZ | RO | frequency of `clk` |
| 0x01C | LINK_CAPS | RO | bit 0 10 Mb/s, bit 1 100 Mb/s, bit 2 1000 Mb/s, full duplex; half duplex is never offered |
| 0x020 | UPTIME_MS | RO | milliseconds since reset release (a one-clock `tick_ms` pulse also leaves the block) |
| 0x024 | LEDS | RW | bits [NUM_LED-1:1]; bit 0 reads 0 (the top drives LED 0 from the clock lock) |
| 0x028 / 0x02C | SWITCHES / BUTTONS | RO | synchronized levels |
| 0x030 | SCRATCH | RW | |
| 0x034 | CLK_STATUS | RO | bit 0 clocks locked |
| 0x038 | PHY_STATUS | RO | bit 0 interrupt pin (active low), bit 1 PHY reset as driven, bit 2 MDIO pad |
| 0x03C | NET_STATUS | RO | link up, speed, RXC ok, IP valid, DHCP bound |

### How the board facts reach the firmware

The firmware has no board-specific source file and no `#ifdef BOARD`. `rtlnet_board.c` reads `BOARD_ID`, `CPU_CLK_HZ`, `LINK_CAPS`
and the I/O counts from the registers above; the BSP's `xparameters.h` carries the CPU clock the timers are programmed from. The
supported link modes set what `speed auto` advertises. The MDIO addresses and the PHY type are found at run time (next section).

## 4. PHY driver table (`firmware/src/rtlnet_phy.[ch]`)

`rtlnet_phy_find` scans the Clause 22 bus (PHYAD 1..31, then 0) and reads PHYID1/PHYID2; `rtlnet_phy_select` picks the table entry whose
masked ID matches (the revision bits are masked). Each entry gives the driver functions `init`, `advertise_set`, `advertise_get`,
`autoneg_restart`, `status` and an optional `show_details` for `show phy`.

| ID (masked) | Driver |
|---|---|
| 0x001CC91x | RTL8211E (`cores/rtlnet_mdio/driver/rtlnet_phy_rtl8211e.c`): RX clock delay, LEDs, EEE off |
| 0x20005C9x | DP83848 (Arty A7-100T, `cores/rtlnet_mdio/driver/rtlnet_phy_dp83848.c`): 10/100 full duplex only, PHYSTS (register 0x10) for link, speed and duplex, no gigabit register is touched. Measured on the board: ID 0x20005C90 at MDIO address 1 (the reference manual says 1, the strap resistors read from the schematic say 5; the scan finds 1) |
| any other | generic Clause 22: BMCR, BMSR, ANAR, ANLPAR, GBCR/GBSR (when BMSR extended status shows 1000BASE-T), speed and duplex resolved from the advertised and partner abilities; the ID is printed at boot and in `show phy` |

To add a PHY: write its driver file under `cores/rtlnet_mdio/driver/`, add one line to
`g_drivers` in `rtlnet_phy.c`, and list the file in `firmware/build.ps1` and `firmware/Makefile`. Nothing else changes.

## 5. Firmware

| File | Role |
|---|---|
| `src/rtlnet_platform.[ch]`, `rtlnet_txring.[ch]`, `rtlnet_fmt.[ch]` | console (interrupt-driven transmit ring), time, interrupts, LEDs, restart, small printf |
| `src/rtlnet_board.[ch]` | system registers, board facts, core probing, raw debug access |
| `src/rtlnet_phy.[ch]` | PHY driver selection by ID (section 4) |
| `src/rtlnet_netmgr.[ch]` | running configuration, PHY bring-up, link monitor (MAC speed follows the PHY), DHCP and lease events, `InitLWIP` |
| `src/rtlnet_cpupath.[ch]`, `rtlnet_offload.[ch]` | classifier (broadcast storm limiter at boot) and TCP checksum offload on the CPU path |
| `src/rtlnet_protect.[ch]` | classifier protection profile (four policed traffic classes), installed after `cpupath_init`; section 5a |
| `src/lwip/` | lwIP port: DMA netif, TCP echo (port 7), lwiperf (TCP, port 5001), options |
| `cli/` | MenuBuilder hierarchical CLI; the command set is `cli/cli_commands.txt`, the generated reference `cli/MenuDocumentation.md` |
| `host/` | desktop harness: the CLI and network manager against a register model, scripted session (`TEST PASS`) |
| `build.ps1` | CLI table check, BSP from the XSA of the board build, link into `<OutDir>/firmware.elf`, host harness and tests |

### CLI

Link control is `speed 10`, `speed 100` and `speed auto` (interface eth0). `auto` advertises every full-duplex mode in `LINK_CAPS`
and is the power-up default; `10` and `100` advertise only that mode; half duplex is never advertised; the link always
auto-negotiates. There is no duplex, autoneg or advertise command.

| Mode | Commands |
|---|---|
| user exec | `show version`, `show system`, `show interfaces`, `show phy`, `show ip`, `show arp`, `show dhcp`, `show iperf`, `show sockets`, `show counters`, `show tcp`, `show cpu-path`, `show offload`, `show classifier` |
| privileged exec (`enable`) | `show running-config`, `disable`, `debug read|write`, `phy read|write|dump|reset`, `clear counters`, `led <n> on|off`, `reload` |
| `configure terminal` | `ip default-gateway`, `echo enable|socket`, `iperf port`, `iperf tcp enable|disable|port`, `tcp echo enable|disable|port`, `offload <what> <state>`, `classifier policer <class> <frames> <window-ms>`, `classifier firewall enable|disable`, `classifier acl`, `no classifier acl`, `interface eth0`, `ip dhcp`, `socket <n>` |
| `interface eth0` | `speed`, `shutdown`, `no shutdown`, `ip address`, `ip netmask`, `mac-address` |
| `ip dhcp` | `start`, `stop`, `renew`, `auto`, `no auto` |
| `socket <n>` | `open`, `close`, `remote`, `connect-on-receive` |

Boot defaults of the receive features of the checksum offload core (`offload ack-coalesce|rx-batch <on|off> [timer-us] [limit]`, section 6e):
ACK coalescing is on at boot with a 500 microsecond timer and the core's default limit of 8 ACKs, when the build has the feature (CAPS bit);
receive batching is off at boot and stays available through the command. `InitLWIP` calls `rtlnet_offload_boot_features` after the
checksum offload request; a build without the feature writes nothing, and a build without the receive offload leaves it off. `show running-config`
lists only what differs from these defaults: `offload ack-coalesce off`, or `offload ack-coalesce on <timer> <limit>` for another setting, and
`offload rx-batch on <timer> <frames>` while batching is on; `show offload` always shows the state, timer, limit and counters.

### 5a. Protection profile of the CPU path

The classifier on the CPU receive stream stays in `MODE` pass-all (no whitelist: the protocol ingress filter admits only the
station MAC and broadcast) and the firmware polices four traffic classes with the classifier's four policers, each with its own
limit in frames per window. `protect_install` (`src/rtlnet_protect.c`) installs the profile through the classifier driver
(`rtlnet_classifier_config_protect`) once per boot after `cpupath_init`, before lwIP sees a frame. Defaults, per 100 ms window:

| Class | Limit | What is policed (classifier document, section 13) |
|---|---:|---|
| `arp` | 20 | ARP requests for other hosts and ARP replies (requests for the board's own address are answered and claimed by the ARP leaf) |
| `icmp` | 10 | ICMP the hardware responder did not answer: other types, bad frames, requests that began while it was busy, requests to other addresses |
| `udp` | 10 | UDP datagrams no hardware leaf claimed (closed ports); lwIP answers each with an ICMP port unreachable |
| `broadcast` | 10 | other broadcast frames; the limit is the storm-control default of the earlier firmware |

A frame in several classes counts once, in the order ARP, ICMP, UDP, broadcast. Multicast has no class: the protocol ingress
filter discards every multicast frame, so none reaches the CPU path. TCP and every other frame pass unpoliced. The worst case of the four
limits together is 500 frames per second, about 5 % of the CPU at the 110 microseconds per answered frame of section 6b; the reasoning
is in the classifier document, section 13.3. The profile fits the small classifier of section 6a (8 entries, 1 rule, 4 policers); a
classifier too small for it keeps the broadcast storm limiter of `cpupath_init` and the boot message and `show classifier` say so.

CLI: `show classifier` prints the built sizes (table and tuple entries, rules, policers, lanes, matched bytes, RAM style), the
mode, the profile state, and per class the limit, window, seen, passed and dropped counts. `classifier policer <broadcast|udp|arp|icmp>
<frames> <window-ms>` (configuration mode) changes one class (frames 0..100000, window 1..60000 ms; frames 0 drops the whole
class). `clear counters` clears the classifier and every policer counter; `show running-config` lists the four limits. There is no
generic rule or table editor; the whitelist is the firewall of section 5b.

Hardware test: `test/flood_test.ps1 -Port <COM> -Nic <adapter> [-Board <ip>] [-Kinds ...] [-Seconds 10] [-Rate 1000]` runs one flood per kind with normal
sockets (Python standard library, iphlpapi through ctypes): UDP to the board (closed port, echo port), UDP broadcast (limited and subnet),
UDP multicast to a group the board never joined, ICMP echo (to the board and to the subnet broadcast) and ARP (SendARP), while one TCP echo
connection exchanges data, the board is pinged and the console answers `show classifier` and `show system`. Pass per flood: frames sent, no TCP
error, every console answer within `-ConsoleBoundMs` (3000), ping loss within `-MaxPingLossPct` (40), uptime advanced (no reset), the policed
class (udp, icmp) shows drops when the frames that reached the board exceed its policer rate (otherwise the row reads "generator below policer
limit: not exercised" and passes), the other classes drop at most `-OtherDropTolerance`. Multicast: no class counts it, and every multicast frame
the MAC received is counted as `filtered` (the MAC rx-good delta of `show counters` minus the delta of `ingress`, the frames that passed the
filter, equals the `filtered` delta, and is above zero). For the multicast and broadcast kinds the test reports frames sent against frames that
reached the board. `icmp-bcast` runs 32 sender threads by default (4 stay below the policer). The `broadcast` class (broadcast that is not ARP,
ICMP or UDP) cannot be exercised with sockets; `udp-echo` and `icmp-board` are answered by hardware; `arp` is reported, not required (SendARP
blocks per call and the request on the wire is not verified), unless `-RequireArp`.

Measured on the Nexys Video (image `eth_m1` with the firmware of section 6e, 1000 Mb/s through a switch, 10 s per flood, one TCP echo connection
running, policer limits of section 5a). Both passes end with `FLOOD_TEST: PASS` (95 of 95 rows at 1000 frames per second, 50 of 50 at 20000 for
udp-closed, udp-bcast-net, mcast and icmp-bcast); every TCP echo byte exact, console answers within 250 ms, no reset:

| Kind | Rate offered | Frames sent | Reached the board | Policed class: passed / dropped |
|---|---:|---:|---:|---|
| udp-closed (unicast, closed port) | 1000 per s | 10000 | 10001 | udp: 1011 / 8990 |
| udp-closed | 20000 per s | 200000 | 199602 | udp: 1010 / 198592 |
| udp-bcast-lim (255.255.255.255) | 1000 per s | 10000 | 5051 | udp: 598 / 4453 |
| udp-bcast-net (subnet broadcast) | 1000 per s | 10000 | 4868 | udp: 579 / 4289 |
| udp-bcast-net | 20000 per s | 200000 | 4998 | udp: 280 / 4718 |
| mcast (group the board never joined) | 1000 per s | 10000 | 5049 | none: `filtered` +5049, MAC rx good +26613, ingress +21564 |
| mcast | 20000 per s | 200000 | 5401 | none: `filtered` +5401, MAC rx good +26646, ingress +21245 |
| icmp-bcast (32 threads) | 1000 per s | 672 | 672 | icmp: 309 / 363 |
| icmp-bcast (32 threads) | 20000 per s | 800 | 800 | icmp: 292 / 508 |

Observation of this network: broadcast and multicast frames arrive at the board at about 500 to 550 frames per second whatever the offered rate
(1000 or 20000 per second give 4900 to 5400 frames in 10 s), while a unicast flood arrives at the full rate. The limit is upstream of the board (the
switch or the PC adapter); the board's counters show exactly what arrived. The same upstream limit shows as ping loss of 11 to 33 % during a 20000
per second multicast or broadcast flood, including the multicast flood that the board discards at the ingress filter, so that loss does not come from
the CPU path (hence the `-MaxPingLossPct` default of 40). A broadcast ICMP echo flood needs 32 sender threads to exceed the policer rate (at 4
threads the 88 frames of a 10 s run all pass: reported as not exercised). With about 500 frames per second arriving against a policer rate of 100 per
second (10 per 100 ms), the udp class drops 88 to 94 % of the broadcast frames that reach it.

### 5b. Firewall of the CPU path (11-16-2026; measured on the Arty A7-100T and the Nexys Video 11-17-2026)

`classifier firewall enable` makes the CPU path default-deny: only ARP and an allow list reach lwIP, the classifier drops everything
else in hardware (register mapping, frame classes and driver: classifier document, section 14). The firewall is off at boot, so the
power-up behaviour of section 5a is unchanged. Hardware leaves (ARP responder, ICMP echo, UDP echo, DHCP, iperf and socket leaves)
are in front of the classifier and keep working; a ping is still answered. With the firewall on, a TCP connect to a port that is not
in the list gets no RST and a UDP datagram to a closed port gets no ICMP port unreachable.

| Command (mode) | Effect |
|---|---|
| `classifier firewall enable` (config) | firewall on; refused, with the needed and available slot counts and before any register write, when the allow list does not fit |
| `classifier firewall disable` (config) | firewall off; the protection profile of section 5a is back |
| `classifier acl [<n>] tcp|udp|any src <ip>/<len> dst <ip>/<len> [sport <lo>[-<hi>]] [dport <lo>[-<hi>]] gate|classify|police <p>` (config) | ACL entry; the index is limited to the tuple slots behind the profile's two (0..13 on the Nexys Video, 0..5 on the Arty A7-100), firewall on or off; with the firewall on every entry allows its traffic |
| `no classifier acl [<n>]` (config) | clears one ACL entry |

The allow list is composed, in this order, from:

| Source | Entries |
|---|---|
| Services | TCP echo (`tcp echo port`), TCP iperf server (`iperf tcp port`), and the listener of an iperf dual or tradeoff session while it waits for the connect-back: protocol, destination port, any source. A service is left out when an ACL entry already covers its protocol and port |
| Client flows | the connections the board opens (iperf connect-back): TCP from the remote address (/32) and port to the local port; added right after `tcp_connect`, removed on close or error |
| ACL entries | every `classifier acl` entry; a police action keeps its policer |

The EtherType entries of the configuration are not applied while the firewall is on (the Ethernet firmware has no command for them).
The list is limited by the tuple slots of the classifier: 16 on the Nexys Video build, 8 on the small classifier of the Arty A7-100.
An entry that does not fit stays blocked and is counted in `show classifier`.

Live update: with the firewall on, a change of a service port, a service enable or disable, a client flow or an ACL entry is written to
the hardware as the difference against a shadow of the allow slots (`rtlnet_classifier_tuple_live_clear` for a removed entry, then
`rtlnet_classifier_tuple_live_set` into a free slot, value words first and `VALID` last). The tables are not disabled and `MODE` is not
written, so no allowed frame is dropped and established connections are not disturbed. Any other classifier edit rewrites the whole
state (`hw_sync`): clear, profile, MAC entries, policers, the firewall or the ACL entries behind the profile's two tuple slots, and `MODE`
as the last write. The firewall owner is `src/rtlnet_firewall.[ch]`; `rtlnet_cpupath.c` is the only owner of the classifier context.
An earlier firmware kept a second classifier context in `rtlnet_protect.c`, and a classifier edit then wiped the protection profile;
the whole-state rewrite now re-installs the profile with its current limits, so an edit never drops it.

Worked example: only ARP and telnet-port access to the echo server.

```
rtlnet# configure terminal
rtlnet(config)# tcp echo port 23
rtlnet(config)# iperf tcp disable
rtlnet(config)# classifier firewall enable
rtlnet(config)# end
rtlnet# show classifier
```

The Firewall block at the end of the `show classifier` output (the build, mode, profile and class lines before it are as in section 5a;
the dropped count is an example):

```
Firewall (CPU path)
  State           : enabled (default deny)
  Allowed         : ARP (policer arp 20 per 100 ms), and the allow list below
  Slot 0  tcp-echo   : tcp src 0.0.0.0/0 dst 0.0.0.0/0 sport 0-65535 dport 23-23
  Free slots      : 15 of 16
  Dropped         : 37 frames (not ARP and not allowed)
```

`show running-config` lists the session (the services are listed by their own commands, the flows are dynamic and not listed):

```
tcp echo port 23
iperf tcp disable
classifier firewall enable
```

`classifier firewall enable` is the last classifier line, so a replay configures the ACL entries first. Optional: restrict the echo
server to one subnet. The ACL entry replaces the any-source service entry of its port:

```
rtlnet(config)# classifier acl 0 tcp src 192.0.2.0/24 dst 0.0.0.0/0 dport 23 gate
```

The slot then reads `Slot 0  acl 0      : tcp src 192.0.2.0/24 dst 0.0.0.0/0 sport 0-65535 dport 23-23` and `show running-config` lists
`classifier acl 0 tcp src 192.0.2.0/24 dst 0.0.0.0/0 dport 23-23 gate`. `no classifier acl 0` brings the service entry back.

Verification: the host harness (`firmware/host`, firewall session) passes 499 checks (TCP echo port 23 with the iperf server
disabled, enable, live port change writing only tuple words, a flow added and removed, a source-restricted ACL replacing the service entry,
capacity refusal on the 8-tuple build, the profile kept after an ACL edit, the `show classifier` wording with the firewall on and off, disable restoring the profile image, no pass-all write
before the last write; negative control TEST FAIL); the lwIP iperf loopback passes 69 checks; the Arty target build links with the
LMB at 239,888 of 262,144 bytes. Hardware test: `test/firewall_test.ps1 -Port <COM> -Nic <adapter> [-Board <ip>]`: firewall off, a closed
TCP port is refused and UDP datagrams to a closed port are answered with ICMP port unreachable (counted on the board: the CPU-path DMA tx
counter rises by one per probe, because the default Windows Firewall rules drop that ICMP before the PC socket sees it; Windows reports a
refused connect after about 2 s, hence `-RefuseMs` 3000); firewall on, echo on port 7 works while TCP connects to ports 5001 and 23 time out,
UDP datagrams to a closed port get no answer, ping is answered and the drop count rises; echo moved to port 23; the configuration restored.

Hardware: Arty A7-100T, image `arty_fw2` (hardware `arty_rel`, firmware f82d4f1), 11-17-2026, LAN through a switch: `firewall_test.ps1` PASS 21/21 at 100 and at 10 Mb/s; `ETH_SUITE` PASS 10/10 (100 Mb/s, with the link test) and 9/9 (10 Mb/s); TCP iperf with the firewall on 94.4 / 94.9 Mb/s, the same as with it off (94.5 / 94.9); `FLOOD_TEST` PASS 95/95 and 50/50 (firewall off); with the firewall on, every flood frame that reached the board was dropped by the classifier (957,174 of 957,712 at 100,000 per second offered, the rest the TCP echo segments and filtered frames), the TCP echo stayed byte-exact and the console answered within 267 ms.

Hardware: Nexys Video, image `eth_fw2` (hardware `eth_rel`, firmware f82d4f1), 11-17-2026, LAN through a switch: `firewall_test.ps1` PASS 21/21 at 1000, 100 and 10 Mb/s; `ETH_SUITE` PASS 10/10 (1000 Mb/s, with the link test), 9/9 (100 Mb/s) and 9/9 (10 Mb/s); ping, UDP echo, UDP iperf, TCP echo and TCP throughput pass with the firewall on at all three speeds, with the figures of the firewall-off runs (TCP iperf at 1000 Mb/s 337.7 / 280.3 Mb/s on, 336.0 / 281.0 off); a port scan (199 closed TCP ports, 100 closed UDP ports) is answered with 199 RST and 100 ICMP port unreachable with the firewall off and with nothing with it on (600 SYN frames and 103 datagrams dropped by the classifier), the allowed ports 7 and 5001 connecting in both states; with the firewall on, all 1,000,000 frames of a 100,000 per second unicast flood reached the board and were dropped by the classifier, the TCP echo kept 21,107 rounds in 10 s against 21,084 with the firewall off.

With the firewall on, the `Profile` line of `show classifier` reads "firewall on: only ARP and the allow list pass; the arp and broadcast
policers apply", and the `udp` and `icmp` rows read "firewall on: judged by the allow list, not policed" (their tuple slots carry the allow
list, so those two policers see no frame); with the firewall off the profile wording and the four class rows are shown.

### Build

```
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/firmware/build.ps1 -Xsa <board xsa> -OutDir <dir> -LmbKb 512 -Demo
```

`-Xsa` is the hardware export of whichever board build; `-OutDir` keeps two boards' BSPs and ELFs apart. Host-only runs
(`-NoFirmware`): `-Demo` (scripted CLI session with its negative control), `-NetifTest`, `-LwipTest`; the same entries are in
`firmware/test/regression.txt`.

## 6. Verification

| What | Where | Result |
|---|---|---|
| Board bench, 10/100/1000 with negative control | `boards/nexys_video/testbench/tb_rtlnet_nexys_video_eth.sv` (`regression.txt`) | 178 checks per speed, 179 with `INJECT_FAILURE` (expected failure) |
| CLI tables | `firmware/cli/check_menu.py` | `CHECK PASS` |
| CLI desktop session | `firmware/build.ps1 -NoFirmware -Demo` | `TEST PASS` (385 checks, including the protection profile on the default, the small and a too-small classifier, `show classifier`, `classifier policer`, running-config, clear counters) |
| Protection profile on the board top | `boards/nexys_video/testbench/tb_rtlnet_nexys_video_eth.sv` (stand-in task `cls_config_protect`) | broadcast, UDP, ARP and ICMP classes each above their limit with unicast TCP segments interleaved: exactly the limits and every TCP segment reach the CPU, byte-exact and in order; per-policer and per-table counters |
| Protection profile on the board | `test/flood_test.ps1` on `eth_m1`, section 5a | `FLOOD_TEST: PASS 95/95` at 1000 frames per second (all kinds), `PASS 50/50` at 20000 (udp-closed, udp-bcast-net, mcast, icmp-bcast) |
| DMA netif, lwiperf loopback, txring | `firmware/test/regression.txt` | `NETIF_HOST`, `LWIPERF_LOOPBACK`, `TXRING_TEST`, `PHY_HOST_TEST` (25 checks, mock MDIO bus) PASS |
| Hardware tests | `test/run_all.ps1 -Port <COM> -Nic <adapter> -LinkMbps 10|100|1000` | results table `test/out/results_<speed>.txt` and `.csv` |
| Board bench modes | `tb_rtlnet_nexys_video_eth`: `COMMON_CLK` 2 (tags g10, g100, g1000, neg), 0 (g10mc, g100mc, g1000mc) | 154 checks each, 155 with `INJECT_FAILURE` (expected failure) |
| Hardware suite on the final image `eth_cc100c` | `run_all.ps1 -LinkMbps 10`, `100`, `1000` | ETH_SUITE: PASS 8/8 scripts at each speed |
| Release campaign on `eth_rel` (11-14-2026, Nexys Video through a switch) | `run_all.ps1 -LinkMbps 1000`, `100`, `10`; `flood_test.ps1 -Rate 1000` (all kinds) and `-Rate 20000` (four kinds) | `ETH_SUITE: PASS 8/8 scripts` at each speed; `FLOOD_TEST: PASS 95/95` and `PASS 50/50`; TCP iperf (mean of 3 x 10 s) PC to board / board to PC 349.7 / 283.3 Mb/s at 1000, 94.7 / 94.6 at 100, 9.5 / 9.5 at 10 Mb/s; UDP iperf 942.0 / 944.0 (71 of 401242 datagrams lost board to PC) at 1000, 94.1 / 94.4 at 100, 9.4 / 9.4 at 10, zero loss otherwise; UDP echo 64 B mean 0.163 ms at 100 and 1000, 1.287 ms at 10; TCP echo 64 B mean 0.198 / 0.231 / 1.350 ms at 1000 / 100 / 10; with ACK coalescing off board to PC reads 257.7 and with receive batching 30 us PC to board reads 314.7 Mb/s; details in `demos/ethernet/ethernet_brief.md` |
| Arty A7-100T board bench, 10 and 100 Mb/s with negative control | `boards/arty_a7_100/testbench/tb_rtlnet_arty_a7_100_eth.sv` (`regression.txt`: `m100`, `m10`, `neg`) | 338 checks per speed, 339 with `INJECT_FAILURE` (expected failure) |
| Arty A7-100T build `arty_dev`, firmware `-LmbKb 256 -BufKb 64` | `boards/arty_a7_100/scripts/build_ethernet.ps1 -Tag arty_dev` | timing met (WNS +0.290 ns), 105.5 of 135 block RAM tiles, `RTLNET_FW: PASS`, `RTLNET_BUILD_ETH: PASS`; superseded by the release build `arty_rel` below; hardware results in the next row |
| Arty A7-100T release image `arty_rel` on the board, 10 and 100 Mb/s | `boards/arty_a7_100/scripts/program.ps1 -Tag arty_rel`, then `test/run_all.ps1 -LinkMbps 100` and `10`, `test/link_test.ps1 -AutoMbps 100`, `test/flood_test.ps1` | `ETH_SUITE: PASS 8/8 scripts` at 100 and at 10 Mb/s (no script or firmware change); `LINK_TEST: PASS 18/18`; `FLOOD_TEST: PASS 95/95` (all kinds, 1000 per s) and `PASS 50/50` (four kinds, 100000 per s offered); TCP iperf 94.8 / 94.9 Mb/s (PC to board / board to PC) at 100 and 9.5 / 9.5 Mb/s at 10 (mean of 3 x 10 s); UDP iperf 93.9 / 94.4 Mb/s at 100, 9.4 / 9.4 at 10, no loss; TCP echo 64 B mean 0.231 ms (100) and 0.429 ms (10); UDP echo 64 B mean 0.174 ms and 0.361 ms |

## 6a. Small memory (256 KiB LMB) and the Arty A7-100 budget

`build.ps1 -LmbKb 256` defines `RTLNET_SMALL_MEM` and selects the small-memory lwIP profile of `src/lwip/lwipopts.h` (heap 24 KiB, 24-buffer
pool, `TCP_WND` 4 x MSS, `TCP_SND_BUF` 12 x MSS, 96 TCP segments, 6 PCBs): `.bss` 232 KiB -> 168 KiB (172 KB incl. the 36 KiB in the AXI BRAM), the
image uses about 250 KiB of the 256 KiB LMB. Measured on the Nexys Video at 1000 Mb/s (same hardware, 512 KiB LMB image with the 256 KiB firmware):

| Firmware | TCP iperf PC -> board | TCP iperf board -> PC | TCP echo (4 + 8 connections) |
|---|---|---|---|
| 512 KiB profile (default) | 311 Mb/s | 106 Mb/s | PASS, 8 connections 0.03 s |
| 256 KiB small-memory profile | 176 Mb/s | 106 Mb/s | PASS, 8 connections 1.02 s |

Block RAM of the dev image (`post_route_utilization_hier.rpt`, 212.5 tiles of 365; Arty A7-100 has 135):

| Module | Tiles | Parameter that sizes it |
|---|---|---|
| `lmb_bram` (CPU code and data) | 128 | `lmb_kb` of `rtlnet_cpu_eth_bd_create` (256 KiB = 64 tiles) |
| AXI BRAM + DMA (rest of `u_cpu`) | 19 | `axi_bram_kb` (64), DMA internals 3 |
| `u_protocol` | 60.5 | below |
| - CPU-path classifier | 30 | `CPU_CLASSIFIER_ENABLE` (0 removes it and the storm limiter; the firmware then runs without it); `CLS_RAM_STYLE` `"distributed"` makes it 0 tiles |
| - CPU receive FIFO | 8.5 | `CPU_RX_FIFO_KB` (32) |
| - UDP socket layer | 8 | `UDP_RX_BUF_KB` (16), `UDP_TX_BUF_KB` (8), `NUM_SOCKETS` |
| - ingress FIFO | 4.5 | `INGRESS_FIFO_KB` (16) |
| - checksum offload, ICMP, DHCP, egress, CPU TX FIFO, rest | about 9.5 | `CPU_TX_FIFO_KB`, `ICMP_BUF_KB`, `DHCP_BUF_KB`, `EGRESS_FIFO_KB` |
| `u_mac` | 5 | `RX_FIFO_KB`, `TX_FIFO_KB` (8 each) |

The CPU-path classifier (`cores/rtlnet_classifier`, `CPU_CLASSIFIER_ENABLE` 1) stays in every design, enabled and unchanged: it keeps lwIP from being
overloaded on a real network. Its 30 tiles with block RAM are a fixed cost, so on the Arty A7-100T (135 tiles, 10/100 Mb/s only) the classifier uses its
distributed-RAM option (`CLS_RAM_STYLE` `"distributed"`, small profile) and the rest of the memory is sized down by existing parameters. Measured build
`arty_dev` (`boards/arty_a7_100/`, `-LmbKb 256 -BufKb 64`, post-route `post_route_utilization_hier.rpt` and a per-cell count of the RAMB36/RAMB18 instances):

| Item | Nexys Video image (tiles) | Arty A7-100T build `arty_dev`, measured (tiles) | Parameter |
|---|---|---|---|
| `lmb_bram` | 128 (512 KiB) | 64 | `lmb_kb` 256, small-memory firmware profile of this section |
| frame buffer RAM | 32 (128 KiB) | 16 | `axi_bram_kb` 64 (60 KiB used: frame buffers and the lwIP heap) |
| AXI DMA internals | 3 | 3 | fixed |
| CPU-path classifier | 30 | 0 | `CLS_RAM_STYLE` `"distributed"`, `CLS_TABLE_ENTRIES` 8, `CLS_TUPLE_ENTRIES` 8, `CLS_NUM_RULES` 1, `CLS_NUM_POLICERS` 4, `CLS_MATCH_DEPTH_BYTES` 64 (4670 LUT, 1500 as memory) |
| CPU receive FIFO | 8.5 (32 KiB) | 4.5 | `CPU_RX_FIFO_KB` 16 |
| UDP socket layer | 8 | 5.0 | `NUM_SOCKETS` 4, `UDP_RX_BUF_KB` 8, `UDP_TX_BUF_KB` 4 |
| ingress FIFO | 4.5 (16 KiB) | 2.5 | `INGRESS_FIFO_KB` 8 |
| checksum offload (transmit side) | 2.5 | 2.5 | fixed |
| egress FIFO, CPU transmit FIFO | about 3 | 3.0 | `EGRESS_FIFO_KB` 4, `CPU_TX_FIFO_KB` 4 |
| ICMP and DHCP buffers | about 4 | 2.0 | `ICMP_BUF_KB` 1, `DHCP_BUF_KB` 1 |
| `u_mac` FIFOs | 5 (8 KiB FIFOs) | 3.0 | `RX_FIFO_KB`, `TX_FIFO_KB` 4 |
| Total | 228.5 (212.5 measured with the 64 KiB buffer RAM of the earlier layout) | 105.5 of 135 (78.2 %) | 29.5 tiles free |

The earlier estimate for this set was about 108 tiles (target at most 110); the build gives 105.5. The firmware needs 229 KiB of the 256 KiB LMB
(stack and heap areas included) and 60 KiB of the 64 KiB frame buffer RAM. What else could give block RAM, not needed so far: the tiny firmware profile
(`lmb_kb` 128, about 32 tiles less, needs a new lwIP profile and a measurement), `NUM_SOCKETS` 2 with smaller UDP buffers (about 3.5 tiles), `RAM_STYLE`
`"distributed"` for the small buffers of the protocol wrapper (about 2 tiles). The single-clock top saves no block RAM, because the cores keep their asynchronous
FIFOs (0 tiles); the dual-port frame buffer costs the same tiles as a single-port RAM of its size.

Other results of the Arty build (post-route, 100 MHz single clock, Vivado 2026.1): WNS +0.290 ns, WHS +0.005 ns, WPWS +3.000 ns, LUT 24986 (39.4 %), FF 36050
(28.4 %), DSP 6, no critical warning, `report_cdc` clean apart from the Gray-code waivers. The MII interface (DP83848 datasheet numbers at 100 Mb/s: receive delay 10 to 30 ns,
transmit setup 10 ns, hold 0 ns): receive setup +6.30 ns, hold +10.43 ns; transmit setup +20.65 ns, hold +2.86 ns. The first MII MAC synthesis showed one
core warning, recorded in the MAC document, section 13.4. The release build `arty_rel` has WNS +0.142 ns, WHS +0.051 ns, WPWS +3.000 ns, LUT 24981, FF 36059, 105.5 block RAM tiles.

**Measured on the board (`arty_rel`, 11-14-2026).** The first image ran without a fix: the 25 MHz reference clock from the FPGA is accepted by the PHY, the scan finds the DP83848 at MDIO address 1, `speed auto` links at 100 Mb/s full duplex through a switch, DHCP, ping, UDP and TCP work. The tests ran at 10 and 100 Mb/s with the board-neutral scripts unchanged (`run_all.ps1 -Port <COM> -Nic <adapter> -LinkMbps 10|100`; the speed is set and restored by the script). In the small-memory profile lwIP keeps data segments by reference, so every TCP data frame is copied: `show offload` after the six 10 s TCP runs reads frames sent in place 244116, copied 243694 (chained pbufs 243694, outside the buffer RAM 0) at 100 Mb/s and 25065 / 24414 at 10 Mb/s (the in-place frames are ACKs and other single-buffer frames), with ACK coalescing on (121859 candidates, 80561 dropped, 41298 forwarded at 100 Mb/s) and receive batching off. TCP still reaches the line rate of both links (94.8 / 94.9 and 9.5 / 9.5 Mb/s). The lwIP heap of the profile peaked at 23224 of 24576 bytes with 18 allocation failures counted after the suites (every test passed); the frame buffer RAM can be raised to 128 KiB (`-BufKb 128`, 29.5 tiles are free) if a load needs it, no result required it. Not verified: boot from the Quad-SPI flash, a direct cable to a PC (the PHY's auto-MDIX is off), JP2 with a terminal (no restart was seen on repeated COM port opens).

## 6b. TCP throughput tuning (Nexys Video, 1000 Mb/s, PC to board / board to PC)

| # | Attempt | Result |
|---|---|---|
| 0 | baseline: 512 KiB LMB, hardware checksum insert and verify on, receive zero-copy on, transmit zero-copy off, `-O2` on the frame path | 311 / 106 Mb/s |
| - | `show offload` after a 5 s run each way: TX frames 113013, ip and l4 patched 113012 (skipped 0); RX frames 157925, verified 157916, bad 0, lwIP flags GEN/CHECK hw for ip, udp, tcp | hardware checksum is in use in both directions; no software checksum |
| 1 | transmit zero-copy on (`-DRTLNET_NETIF_ZERO_COPY_TX=1`) | does not link: lwIP's heap (64 KiB) must live in the 64 KiB AXI BRAM that also holds the frame buffers (overflow 36992 bytes); earlier measurements on the H.264 design had it slower; not pursued |
| 2 | small-memory profile (section 6a) | 176 / 106 Mb/s (cost of the smaller window and pool) |
| 3 | board to PC limit, from the code: every transmitted frame is copied once into the AXI BRAM by `axi_put_chain` (word writes, about 16 cycles per 32-bit access over `M_AXI_DP`, 365 words per 1460-byte segment, about 5800 cycles of about 11000 per frame at 100 MHz) | the remaining cost is the CPU's AXI access latency, not a checksum or an extra memcpy; the lever is hardware (a wider or LMB-attached transmit buffer, or a faster CPU clock) |

| 4 | hardware: `-CpuOpt 2` (Frequency pipeline), `-CpuBtc 4` (branch target cache size 4), CPU clock 125 MHz (tag `eth_f125`; the same firmware) | WNS +0.009 ns, WHS +0.009 ns, WPWS +0.264 ns, LUT 22784, FF 31294, BRAM 212.5; 333 / 132 Mb/s (+7 % / +25 %); timing met with no margin (post-route WNS -0.101 ns, recovered by the post-route phys_opt) |
| 5 | same options at 100 MHz, other BTC sizes, `cpu_muldiv` 2 | not built |
| 6 | one 100 MHz system clock (`COMMON_CLK` 2: CPU, protocol and MAC client side on one clock; `cpu_opt` 0, the same firmware as `eth_dev`) | 314 / 106 Mb/s; hardware UDP iperf 940 / 944; UDP echo 64 B mean 0.174 ms (`eth_dev` multi-clock: 309 / 106, 942 / 944, 0.173 ms): the clock tree changes nothing measurable, it removes the 62.5 and 50 MHz domains |
| 7 | dual-port frame buffer RAM on the data-side LMB (128 KiB, section 2) and zero-copy transmit on (final image `eth_cc100c`) | 347 / 191 Mb/s (+10 % / +80 % over 6); UDP iperf 943 / 944; UDP echo 64 B mean 0.165 ms; `show offload` counters in 6d |

CPU configuration options of `rtlnet_cpu_eth_bd_create` (`cpu_opt`, `cpu_btc`, `cpu_muldiv`; queried from the 2026.1 IP: `C_OPTIMIZATION` 0 Performance, 1 Area,
2 Frequency; `C_BRANCH_TARGET_CACHE_SIZE` 0..7; `C_USE_MULDIV` 0..2), exposed as `build_ethernet.ps1 -CpuOpt -CpuBtc -CpuMuldiv`. See the hand-back for the variant builds.

## 6c. One 100 MHz system clock: builds

The default image runs the CPU, the protocol cores and the MAC client side on one 100 MHz clock (`COMMON_CLK` 2). Without any core change the single-clock build failed
(WNS -1.478 ns, 189 failing endpoints): several protocol leaves were written for 50 MHz. The smallest set of core changes that closes it, each
behaviour-compatible at the core's ports and each failing path it fixes:

| Core | Change | Failing path without it (WNS) |
|---|---|---|
| `rtlnet_common` | new `rtlnet_ipv4_csum_pipe` (three-stage IPv4 header checksum), bench `tb_rtlnet_ipv4_csum_pipe` | n/a |
| `rtlnet_iperf` | header checksum from the pipe; the checksum state takes four clocks | `tx_len` to `tx_csum`: -1.478 ns |
| `rtlnet_icmp` | reply header checksum from the pipe (settled before `S_CHECK`); the payload keep mask is a register (`rx_keep_q`); the request counters act one clock after `S_CHECK` on flags registered in it (latency of the reply unchanged, bench unchanged) | `local_ip_snap` to `reply_ip_checksum`: -1.407 ns; then `cnt_drop_checksum` clock enable and `sum_rest`: about -0.15 ns |
| `rtlnet_udp_socket_tx` | header checksum from the pipe | `h_dst_ip` to `h_csum`: -1.340 ns |
| `rtlnet_dhcp` | header checksum from the pipe; the option walk takes the RAM byte through a register (three clocks per byte instead of two) | `tx_dip` to `tx_csum`: -1.060 ns; then RAM to `opt_pos`: -0.107 ns |
| `rtlnet_udp_socket_rx` | beat-4 header checksum test as an equality against the complement of the folded partial sum; the pseudo-header register part of the UDP checksum folded separately and joined in the final equality | ingress FIFO RAM to `ev_*`, `cap_active`, `claim_pend`, `state`: -1.04 to -1.45 ns; then `csum_acc`: about -0.1 ns |

Builds of the tree (post-route, `build_ethernet.ps1`, 100 MHz single clock unless noted):

| Tag | Content | WNS | WHS | WPWS | LUT / FF / BRAM tiles / DSP |
|---|---|---|---|---|---|
| `eth_dev` | multi-clock, CPU 100 MHz (before this work) | +0.221 ns | +0.013 ns | +0.264 ns | 22505 / 31258 / 212.5 / 6 |
| `eth_cc100c` | single clock, 128 KiB dual-port frame buffer on the LMB, zero-copy transmit, the core changes above (final tree) | +0.037 ns | +0.013 ns | +0.264 ns | 22179 / 31720 / 228.5 / 6 |
| `eth_rel` (release, git 2c2c686b, tree clean) | the release image of `demos/ethernet`: single clock, 512 KiB LMB, 128 KiB dual-port frame buffer, ACK coalescing on at boot, protection profile | +0.154 ns | +0.012 ns | +0.264 ns | 23891 / 33968 / 228.5 / 6 |
| `arty_dev` (xc7a100t, Arty A7-100T, section 6a) | single 100 MHz clock, MII, 256 KiB LMB, 64 KiB frame buffer, classifier in distributed RAM | +0.290 ns | +0.005 ns | +3.000 ns | 24986 / 36050 / 105.5 / 6 |
| `arty_rel` (release, git ab3e1d17, tree clean; programmed and measured on the Arty A7-100T) | the same configuration, current firmware, ACK coalescing on at boot | +0.142 ns | +0.051 ns | +3.000 ns | 24981 / 36059 / 105.5 / 6 |

Intermediate builds with a subset of the core changes failed by -1.478, -0.154 and -0.107 ns (each time the paths named in the table). The margin of the final build is thin (below +0.15 ns); a build with another placer directive (`RTLNET_PLACE_DIRECTIVE`) was not run. CDC census of the build: FIFO 10, Gray 6, AXI4-Lite bridges 5, reset synchronizers 5, level synchronizers 28; `report_cdc`: only the Gray-code waivers.

## 6d. Hardware checksum counters (`show offload`) with the dual-port buffer

`show offload` after `clear counters` and one `tcp_throughput_test` run (5 s each way, 1000 Mb/s, image `eth_cc100b`, the same design apart from the timing changes of the cores):

| Counter | Before | After |
|---|---|---|
| TX frames / ip patched / l4 patched / skipped / malformed | 0 / 0 / 0 / 0 / 0 | 156614 / 156614 / 156614 / 0 / 0 (every transmitted frame got its checksums from the hardware) |
| RX frames / verified / ip bad / l4 bad / unverified | 0 / 0 / 0 / 0 / 0 | 190450 / 190436 / 0 / 0 / 14 (the 14 unverified frames are not TCP/UDP) |
| lwIP checksum flags | GEN ip, udp, tcp hw; icmp sw; CHECK ip, udp, tcp hw; icmp sw | unchanged: no software checksum for IP, TCP or UDP |
| Frames sent in place (zero-copy transmit) / copied | 0 / 0 | 74702 / 81912 (one counter over both directions: the in-place frames are the pure ACKs of the PC to board run, the copies are the data segments of the board to PC run, section 6f) |
| DMA receive no-pbuf / errors, DMA transmit timeouts / errors | 0 | 0 |

With the small-memory firmware (`-LmbKb 256`, same hardware) at `speed 100`: TCP iperf 94.5 Mb/s PC to board and 94.9 Mb/s board to PC (line rate, as measured
with the first image of the 100 Mb/s test).


## 6e. Receive features: ACK coalescing and receive batching (Nexys Video, 1000 Mb/s)

The checksum offload core can hold back and merge the pure TCP ACKs on the receive path (ACK coalescing: per flow, a timer in microseconds and a
limit of ACKs per forwarded ACK) and deliver received frames to the CPU in batches (receive batching: a timer, a frame limit and a byte limit).
Both work on the receive trailer, so `offload rx` must be on; `offload ack-coalesce|rx-batch on|off [timer-us] [limit]` switches them, `show offload`
shows state, configuration and counters. Measured on image `eth_m1` (the firmware before section 6f, 1000 Mb/s through a switch, iperf 2, 10 s runs,
mean of 3, `clear counters` before the last run; ACK limit 8 and batch limit 16 frames; echo: 2000 TCP requests of 64 bytes, mean round trip):

| Setting | PC to board (Mb/s) | Board to PC (Mb/s) | TCP echo 64 B mean (ms) |
|---|---:|---:|---:|
| both off | 344.7 (repeat 344.3) | 194 (repeat 194) | 0.200 |
| ACK coalescing 200 us | 347.7 | 218 | |
| ACK coalescing 300 us | 347.7 | 224 | |
| ACK coalescing 500 us | 346.0 | 227 | 0.200 |
| ACK coalescing 1000 us | 346.0 | 146 | |
| batching 10 us | 346.0 | 195 | 0.234 |
| batching 30 us | 311.7 | 195 | 0.232 |
| batching 100 us | 267.0 | 195 | 0.301 |
| batching 300 us | 204.7 | 195 | |
| ACK coalescing 500 us and batching 30 us | 313.3 | 226 | 0.236 |

Result and recommendation: ACK coalescing at 500 microseconds raises board to PC throughput by 17 % (194 to 227 Mb/s) with no change of PC to
board throughput or latency and no error; shorter timers give less, and 1000 microseconds collapses it (146 Mb/s, the held ACKs stall the sender's
window). It is therefore on at boot with 500 microseconds and the default limit. Receive batching never raises throughput: from 30 microseconds
it costs 10 to 40 % of the PC to board throughput, and every setting adds 0.03 to 0.10 ms to the round trip; it is off at boot and stays available
through the CLI. The ACK counters after one 10 s board to PC run (500 us): 107535 candidates, 90679 dropped, 16856 forwarded (15932 by the timer).

## 6f. Zero-copy transmit of TCP data (board to PC)

`netif_linkoutput` sends a frame in place only when it is one pbuf inside the frame buffer RAM (`p->next == NULL`, simple-mode DMA, one contiguous
buffer); everything else is copied into a transmit buffer. lwIP's heap lies in that RAM (map file of `eth_m1`: `.axi_bram` at 0x00100000, 0x19080 bytes,
`rtlnet_lwip_heap` at its start), so the cause of the copies was not the heap placement. The iperf server queued its data segments by reference
(`tcp_write` without `TCP_WRITE_FLAG_COPY`, payload a constant array in the LMB): each segment is a chain of a header pbuf (heap) and a payload
reference (ROM), never one buffer. The netif counters tell the two reasons apart (`show offload`: "copied N (chained pbufs a, outside the buffer RAM b)").
One 10 s board to PC run on the earlier image: frames sent in place 3, copied 190972, of them chained pbufs 190972, outside the buffer RAM 0. The
code was not changed by the receive-feature merge; the earlier "half in place" figure (section 6d) was a counter over both directions of a run, where
the PC to board ACKs are single pbufs.

The data segments of the iperf server are now copied by `tcp_write` (`TCP_WRITE_FLAG_COPY`, option `RTLNET_LWIPERF_TX_COPY`, on with zero-copy
transmit and the 512 KiB profile) into one contiguous pbuf in the heap, and the frame is sent from there: the copy is made once, by the CPU
over the data-side LMB (1 to 2 clocks per word) instead of word by word into the transmit buffer, and a retransmission needs no copy. The
small-memory profile keeps the references (its 24 KiB heap cannot hold a full send queue of copies). Same image, same setup, ACK coalescing 500 us
(the boot default):

| Image | PC to board (Mb/s, 3 runs) | Board to PC (Mb/s, 3 runs) | Frames sent in place / copied, board to PC run |
|---|---|---|---|
| references (before) | 347, 349, 348 | 223, 223, 223 | 3 / 190972 |
| copy by `tcp_write` (after) | 349, 348, 345 | 285, 284, 282 | 242397 / 0 |
| copy by `tcp_write`, final image, repeat | 343, 340, 344 | 283, 282, 282 | 242875 / 0 |

The PC to board run sends only pure ACKs (single pbufs): in place 147687 and copied 0 after, 149034 and 0 before. A gather transmit would need a
scatter-gather DMA; the simple-mode DMA of the design sends one contiguous buffer.

## 7. Limitations

* The LMB is sized by `lmb_kb`; the firmware needs about 346 KiB (`.bss` 232 KiB mostly lwIP pools), so 512 KiB.
* The generic PHY driver resolves only full-duplex modes; a partner that does not auto-negotiate (parallel detection, half duplex)
  shows no usable link.
* `arp -d` in the ARP test needs an elevated shell; without it the test checks the existing entry.

## 8. Revision history

* 11-17-2026: section 5b measured on the Arty A7-100T (image `arty_fw2`) and on the Nexys Video (image `eth_fw2`, 10/100/1000 Mb/s); `firewall_test.ps1` counts the ICMP port unreachable on the board; `show classifier` names the firewall in the `Profile` line and the `udp` and `icmp` rows while it is on.
* 11-16-2026: firewall of the CPU path (section 5b): `classifier firewall enable|disable`, `classifier acl`, `no classifier acl`, allow list from services, client flows and ACL entries, live update, fix of the protection profile wipe on a classifier edit; host harness, `test/firewall_test.ps1` written, not yet run on hardware.
* 11-14-2026: Arty A7-100T measured on the board: release image `arty_rel`, DP83848 found at MDIO address 1, `ETH_SUITE` 8/8 at 10 and 100 Mb/s, flood tests, in-place and copied counters (section 6a, verification and build rows, PHY table).
* 11-14-2026: release build `eth_rel` and the release campaign results (sections 6 and 6c); the demo documents are in `demos/ethernet/`.
* 11-14-2026: ACK coalescing on at boot (500 us), receive batching off (CLI section, measured matrix in 6e); data segments of the iperf server copied into one pbuf in the frame buffer RAM and sent in place (6f); flood test criteria, default thread count and measured table (5a).
* 11-14-2026: Arty A7-100T build-out: second board, `ARTY` board ID, DP83848 row of the PHY table, section 6a changed from an estimate to the measured `arty_dev` build (105.5 of 135 tiles), verification and build rows.
* 11-14-2026: clock tree section 2a (`COMMON_CLK`), dual-port frame buffer RAM on the data-side LMB with its address map, processor options, the 125 MHz study (6c), the Arty estimate with the classifier kept (6a).
* 11-14-2026: first version (derived from the H.264 demo CPU with the DDR3 path, caches and video removed).
* 11-14-2026: protection profile of the CPU path (section 5a, `show classifier`, `classifier policer`, `test/flood_test.ps1`); Arty recommendation keeps the classifier with distributed RAM (section 6a).
