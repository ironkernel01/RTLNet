# RTLNet Ethernet CPU (MicroBlaze V) -- core and firmware guide

| Item | Value |
|---|---|
| Document revision | 11-14-2026 |
| Folder | `cpu/microblaze_v_ethernet/` |
| Wrapper module | `rtlnet_cpu_eth` (`hdl/rtlnet_cpu_eth.sv`), block design `rtlnet_cpu_eth_bd` (`hdl/rtlnet_cpu_eth_bd.tcl`), simulation stub `rtlnet_cpu_eth_sim_stub` |
| Board dependence | none: the folder names no board, pin, part, PHY type or clock rate |
| First board | Nexys Video (`boards/nexys_video/hdl/rtlnet_nexys_video_eth_top.sv`); a second board, the Arty A7-100 (MII, 10/100), uses the same sources |

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
                UDP iperf, TCP echo, TCP throughput, and run_all.ps1
  documentation/ this document
```

## 2. Block design (`rtlnet_cpu_eth_bd_create <bd_dir> <cpu_clk_hz> <lmb_kb> [<axi_bram_kb> [<cpu_opt> <cpu_btc> <cpu_muldiv> [<lmb_buf>]]]`)

The procedure takes the clock frequency, the memory sizes and the processor options as arguments; the board build script passes them
(`boards/nexys_video/scripts/build_ethernet.tcl`: `-CommonClk`, `-CpuClkHz`, `-LmbKb` 512, `-BufKb` 128, `-CpuOpt`, `-CpuBtc`, `-CpuMuldiv`, `-LmbBuf` 1). The design is named `rtlnet_cpu_eth_bd` because the generated
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
| 0x014 | BOARD_ID | RO | four ASCII characters naming the board (Nexys Video: `NXVD`) |
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
| any other | generic Clause 22: BMCR, BMSR, ANAR, ANLPAR, GBCR/GBSR (when BMSR extended status shows 1000BASE-T), speed and duplex resolved from the advertised and partner abilities; the ID is printed at boot and in `show phy` |

To add a PHY (the DP83848 of the Arty A7-100 next): write its driver file under `cores/rtlnet_mdio/driver/`, add one line to
`g_drivers` in `rtlnet_phy.c`, and list the file in `firmware/build.ps1` and `firmware/Makefile`. Nothing else changes.

## 5. Firmware

| File | Role |
|---|---|
| `src/rtlnet_platform.[ch]`, `rtlnet_txring.[ch]`, `rtlnet_fmt.[ch]` | console (interrupt-driven transmit ring), time, interrupts, LEDs, restart, small printf |
| `src/rtlnet_board.[ch]` | system registers, board facts, core probing, raw debug access |
| `src/rtlnet_phy.[ch]` | PHY driver selection by ID (section 4) |
| `src/rtlnet_netmgr.[ch]` | running configuration, PHY bring-up, link monitor (MAC speed follows the PHY), DHCP and lease events, `InitLWIP` |
| `src/rtlnet_cpupath.[ch]`, `rtlnet_offload.[ch]` | classifier (broadcast storm limiter) and TCP checksum offload on the CPU path |
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
| user exec | `show version`, `show system`, `show interfaces`, `show phy`, `show ip`, `show arp`, `show dhcp`, `show iperf`, `show sockets`, `show counters`, `show tcp`, `show cpu-path`, `show offload` |
| privileged exec (`enable`) | `show running-config`, `disable`, `debug read|write`, `phy read|write|dump|reset`, `clear counters`, `led <n> on|off`, `reload` |
| `configure terminal` | `ip default-gateway`, `echo enable|socket`, `iperf port`, `iperf tcp enable|disable|port`, `tcp echo enable|disable|port`, `offload <what> <state>`, `interface eth0`, `ip dhcp`, `socket <n>` |
| `interface eth0` | `speed`, `shutdown`, `no shutdown`, `ip address`, `ip netmask`, `mac-address` |
| `ip dhcp` | `start`, `stop`, `renew`, `auto`, `no auto` |
| `socket <n>` | `open`, `close`, `remote`, `connect-on-receive` |

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
| Board bench, 10/100/1000 with negative control | `boards/nexys_video/testbench/tb_rtlnet_nexys_video_eth.sv` (`regression.txt`) | 154 checks per speed, 155 with `INJECT_FAILURE` (expected failure) |
| CLI tables | `firmware/cli/check_menu.py` | `CHECK PASS` |
| CLI desktop session | `firmware/build.ps1 -NoFirmware -Demo` | `TEST PASS` |
| DMA netif, lwiperf loopback, txring | `firmware/test/regression.txt` | `NETIF_HOST`, `LWIPERF_LOOPBACK`, `TXRING_TEST`, `PHY_HOST_TEST` (25 checks, mock MDIO bus) PASS |
| Hardware tests | `test/run_all.ps1 -Port <COM> -Nic <adapter> -LinkMbps 10|100|1000` | results table `test/out/results_<speed>.txt` and `.csv` |
| Board bench modes | `tb_rtlnet_nexys_video_eth`: `COMMON_CLK` 2 (tags g10, g100, g1000, neg), 0 (g10mc, g100mc, g1000mc) | 154 checks each, 155 with `INJECT_FAILURE` (expected failure) |
| Hardware suite on the final image `eth_cc100c` | `run_all.ps1 -LinkMbps 10`, `100`, `1000` | ETH_SUITE: PASS 8/8 scripts at each speed |

## 6a. Small memory (256 KiB LMB) and the Arty A7-100 budget

`build.ps1 -LmbKb 256` defines `RTLNET_SMALL_MEM` and selects the small-memory lwIP profile of `src/lwip/lwipopts.h` (heap 24 KiB, 24-buffer
pool, `TCP_WND` 4 x MSS, `TCP_SND_BUF` 12 x MSS, 96 TCP segments, 6 PCBs): `.bss` 232 KiB -> 168 KiB (172 KB incl. the 36 KiB in the AXI BRAM), the
image uses about 250 KiB of the 256 KiB LMB. Measured on the Nexys Video at 1000 Mb/s (same hardware, 512 KiB LMB image with the 256 KiB firmware):

| Firmware | TCP iperf PC -> board | TCP iperf board -> PC | TCP echo (4 + 8 connections) |
|---|---|---|---|
| 512 KiB profile (default) | 311 Mbit/s | 106 Mbit/s | PASS, 8 connections 0.03 s |
| 256 KiB small-memory profile | 176 Mbit/s | 106 Mbit/s | PASS, 8 connections 1.02 s |

Block RAM of the dev image (`post_route_utilization_hier.rpt`, 212.5 tiles of 365; Arty A7-100 has 135):

| Module | Tiles | Parameter that sizes it |
|---|---|---|
| `lmb_bram` (CPU code and data) | 128 | `lmb_kb` of `rtlnet_cpu_eth_bd_create` (256 KiB = 64 tiles) |
| AXI BRAM + DMA (rest of `u_cpu`) | 19 | `axi_bram_kb` (64), DMA internals 3 |
| `u_protocol` | 60.5 | below |
| - CPU-path classifier | 30 | `CPU_CLASSIFIER_ENABLE` (0 removes it and the storm limiter; the firmware then runs without it) |
| - CPU receive FIFO | 8.5 | `CPU_RX_FIFO_KB` (32) |
| - UDP socket layer | 8 | `UDP_RX_BUF_KB` (16), `UDP_TX_BUF_KB` (8), `NUM_SOCKETS` |
| - ingress FIFO | 4.5 | `INGRESS_FIFO_KB` (16) |
| - checksum offload, ICMP, DHCP, egress, CPU TX FIFO, rest | about 9.5 | `CPU_TX_FIFO_KB`, `ICMP_BUF_KB`, `DHCP_BUF_KB`, `EGRESS_FIFO_KB` |
| `u_mac` | 5 | `RX_FIFO_KB`, `TX_FIFO_KB` (8 each) |

The CPU-path classifier (`cores/rtlnet_classifier`, `CPU_CLASSIFIER_ENABLE` 1) stays in every design, enabled and unchanged: it keeps lwIP from being
overloaded on a real network. Its 30 tiles are a fixed cost, so the block RAM has to come from elsewhere. Estimated sets for the Arty A7-100 (135 tiles,
10/100 Mb/s only). These are ESTIMATES from the table above and from scaling each FIFO with its size; no Arty build has been run, nothing here is measured:

| Item | Nexys Video image (tiles) | Set A: measured firmware profile (tiles) | Set B: tiny firmware profile, not built (tiles) |
|---|---|---|---|
| `lmb_bram` | 128 (512 KiB) | 64 (`lmb_kb` 256, small-memory profile of this section) | 32 (`lmb_kb` 128; needs a new lwIP profile with a smaller pool and heap, about 100 KiB of image: not built) |
| frame buffer RAM + DMA internals (3) | 35 (128 KiB) | 11 (`axi_bram_kb` 32: 8 receive + 2 transmit buffers of 2 KiB = 20 KiB, transmit by copy, heap in the LMB) | 11 (same) |
| CPU-path classifier | 30 | 30 (kept, unchanged) | 30 (kept, unchanged) |
| CPU receive FIFO | 8.5 (32 KiB) | 2.5 (`CPU_RX_FIFO_KB` 8: a 100 Mb/s link needs a tenth of the window) | 2.5 |
| UDP socket layer | 8 | 1.5 (`NUM_SOCKETS` 2, `UDP_RX_BUF_KB` 2, `UDP_TX_BUF_KB` 2) | 1.5 |
| ingress FIFO | 4.5 (16 KiB) | 2.5 (`INGRESS_FIFO_KB` 8) | 2.5 |
| checksum offload, ICMP, DHCP, egress, CPU TX FIFO, rest | 9.5 | 6 (`CPU_TX_FIFO_KB` 4, `EGRESS_FIFO_KB` 4, `ICMP_BUF_KB` 1, `DHCP_BUF_KB` 1) | 6 |
| `u_mac` | 5 (8 KiB FIFOs) | 2.5 (`RX_FIFO_KB`, `TX_FIFO_KB` 4) | 2.5 |
| Total | 228.5 (212.5 measured with the 64 KiB buffer RAM of the earlier layout) | about 120 of 135 | about 88 of 135 |

Set A reaches the target of at most 120 tiles only just (15 tiles of margin) and uses nothing that is not already a parameter; Set B has the margin
(about 47 tiles) but needs the smaller firmware profile, which has to be sized by a measurement first. What else can give block RAM: small buffers in
distributed RAM through the RAM wrapper's `RAM_STYLE "distributed"` option (a protocol-wrapper parameter that applies to every buffer of the wrapper;
the ICMP and DHCP buffers and the egress and CPU transmit FIFOs are small enough to cost only LUTs, about 2 tiles for the four); the single-clock
top (`COMMON_CLK` 2) saves no block RAM, because the cores keep their asynchronous FIFOs (0 tiles; it does remove two clock buffers and the 62.5 and 50 MHz
domains); the dual-port frame buffer of the Nexys design costs the same tiles as a single-port RAM of its size, so Set A uses it too at 32 KiB (8 tiles).

## 6b. TCP throughput tuning (Nexys Video, 1000 Mb/s, PC to board / board to PC)

| # | Attempt | Result |
|---|---|---|
| 0 | baseline: 512 KiB LMB, hardware checksum insert and verify on, receive zero-copy on, transmit zero-copy off, `-O2` on the frame path | 311 / 106 Mbit/s |
| - | `show offload` after a 5 s run each way: TX frames 113013, ip and l4 patched 113012 (skipped 0); RX frames 157925, verified 157916, bad 0, lwIP flags GEN/CHECK hw for ip, udp, tcp | hardware checksum is in use in both directions; no software checksum |
| 1 | transmit zero-copy on (`-DRTLNET_NETIF_ZERO_COPY_TX=1`) | does not link: lwIP's heap (64 KiB) must live in the 64 KiB AXI BRAM that also holds the frame buffers (overflow 36992 bytes); earlier measurements on the H.264 design had it slower; not pursued |
| 2 | small-memory profile (section 6a) | 176 / 106 Mbit/s (cost of the smaller window and pool) |
| 3 | board to PC limit, from the code: every transmitted frame is copied once into the AXI BRAM by `axi_put_chain` (word writes, about 16 cycles per 32-bit access over `M_AXI_DP`, 365 words per 1460-byte segment, about 5800 cycles of about 11000 per frame at 100 MHz) | the remaining cost is the CPU's AXI access latency, not a checksum or an extra memcpy; the lever is hardware (a wider or LMB-attached transmit buffer, or a faster CPU clock) |

| 4 | hardware: `-CpuOpt 2` (Frequency pipeline), `-CpuBtc 4` (branch target cache size 4), CPU clock 125 MHz (tag `eth_f125`; the same firmware) | WNS +0.009 ns, WHS +0.009 ns, WPWS +0.264 ns, LUT 22784, FF 31294, BRAM 212.5; 333 / 132 Mbit/s (+7 % / +25 %); timing met with no margin (post-route WNS -0.101 ns, recovered by the post-route phys_opt) |
| 5 | same options at 100 MHz, other BTC sizes, `cpu_muldiv` 2 | not built |
| 6 | one 100 MHz system clock (`COMMON_CLK` 2: CPU, protocol and MAC client side on one clock; `cpu_opt` 0, the same firmware as `eth_dev`) | 314 / 106 Mbit/s; hardware UDP iperf 940 / 944; UDP echo 64 B mean 0.174 ms (`eth_dev` multi-clock: 309 / 106, 942 / 944, 0.173 ms): the clock tree changes nothing measurable, it removes the 62.5 and 50 MHz domains |
| 7 | dual-port frame buffer RAM on the data-side LMB (128 KiB, section 2) and zero-copy transmit on (final image `eth_cc100c`) | 347 / 191 Mbit/s (+10 % / +80 % over 6); UDP iperf 943 / 944; UDP echo 64 B mean 0.165 ms; `show offload` counters in 6d |

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

Intermediate builds with a subset of the core changes failed by -1.478, -0.154 and -0.107 ns (each time the paths named in the table). The margin of the final build is thin (below +0.15 ns); a build with another placer directive (`RTLNET_PLACE_DIRECTIVE`) was not run. CDC census of the build: FIFO 10, Gray 6, AXI4-Lite bridges 5, reset synchronizers 5, level synchronizers 28; `report_cdc`: only the Gray-code waivers.

## 6d. Hardware checksum counters (`show offload`) with the dual-port buffer

`show offload` after `clear counters` and one `tcp_throughput_test` run (5 s each way, 1000 Mb/s, image `eth_cc100b`, the same design apart from the timing changes of the cores):

| Counter | Before | After |
|---|---|---|
| TX frames / ip patched / l4 patched / skipped / malformed | 0 / 0 / 0 / 0 / 0 | 156614 / 156614 / 156614 / 0 / 0 (every transmitted frame got its checksums from the hardware) |
| RX frames / verified / ip bad / l4 bad / unverified | 0 / 0 / 0 / 0 / 0 | 190450 / 190436 / 0 / 0 / 14 (the 14 unverified frames are not TCP/UDP) |
| lwIP checksum flags | GEN ip, udp, tcp hw; icmp sw; CHECK ip, udp, tcp hw; icmp sw | unchanged: no software checksum for IP, TCP or UDP |
| Frames sent in place (zero-copy transmit) / copied | 0 / 0 | 74702 / 81912 (the copies are chained pbufs: header and data in separate pbufs, ARP, ICMP) |
| DMA receive no-pbuf / errors, DMA transmit timeouts / errors | 0 | 0 |

With the small-memory firmware (`-LmbKb 256`, same hardware) at `speed 100`: TCP iperf 94.5 Mbit/s PC to board and 94.9 Mbit/s board to PC (line rate, as measured
with the first image of the 100 Mb/s test).


## 7. Limitations

* The LMB is sized by `lmb_kb`; the firmware needs about 346 KiB (`.bss` 232 KiB mostly lwIP pools), so 512 KiB.
* The generic PHY driver resolves only full-duplex modes; a partner that does not auto-negotiate (parallel detection, half duplex)
  shows no usable link.
* `arp -d` in the ARP test needs an elevated shell; without it the test checks the existing entry.

## 8. Revision history

* 11-14-2026: clock tree section 2a (`COMMON_CLK`), dual-port frame buffer RAM on the data-side LMB with its address map, processor options, the 125 MHz study (6c), the Arty estimate with the classifier kept (6a).
* 11-14-2026: first version (derived from the H.264 demo CPU with the DDR3 path, caches and video removed).
