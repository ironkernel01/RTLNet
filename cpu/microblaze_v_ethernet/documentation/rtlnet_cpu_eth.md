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

## 2. Block design (`rtlnet_cpu_eth_bd_create <bd_dir> <cpu_clk_hz> <lmb_kb> [<axi_bram_kb>]`)

The procedure takes the clock frequency and the memory sizes as arguments; the board build script passes them
(`boards/nexys_video/scripts/build_ethernet.tcl`: 100 MHz, 512 KiB LMB). The design is named `rtlnet_cpu_eth_bd` because the generated
module takes the design name and must not collide with the wrapper `rtlnet_cpu_eth`; the generated wrapper is
`rtlnet_cpu_eth_bd_wrapper`, the processor path in the bitstream is `u_cpu/u_bd/rtlnet_cpu_eth_bd_i/microblaze_0`.

| Cell | Configuration |
|---|---|
| `microblaze_0` | MicroBlaze V (`microblaze_riscv`), RV32IMC with Zicsr, Zba, Zbb, Zbs, performance pipeline, barrel shifter, multiplier and divider, no MMU, no FPU, no caches, debug enabled, no bus exceptions, reset vector 0 |
| `lmb_bram` (+ ILMB/DLMB) | `<lmb_kb>` KiB at 0x0000_0000: code, data, heap, stack and the lwIP pools. This is the RAM-instancing parameter of the design (`*_KB` rule); 512 KiB for the firmware as built (about 346 KiB used) |
| `mdm_0` | MDM RISC-V, serial JTAG debug, no JTAG UART, no AXI slave |
| `axi_uartlite_0` | console, 115200 8N1 |
| `axi_timer_0`, `axi_intc_0` | time base (timer 0 free running, timer 1 a 1 ms interrupt), interrupt controller |
| `axi_dma_0` + `axi_bram_ctrl_0` + `axi_bram` | CPU network path DMA (simple mode, 64-bit streams, data realignment on MM2S) and its `<axi_bram_kb>` KiB buffer RAM (64 KiB default) shared with the CPU data side |
| `axi_periph`, `axi_mem` | interconnects: CPU to six peripherals; CPU and both DMA channels to the buffer RAM |
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
| 0xC000_0000 | `axi_bram_kb` KiB | AXI BRAM (DMA frame buffers, lwIP heap) |

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

Recommended Arty set (10/100, no core edits): `lmb_kb` 256 (small-memory firmware), `axi_bram_kb` 64, `CPU_CLASSIFIER_ENABLE` 0, `INGRESS_FIFO_KB` 8,
`CPU_RX_FIFO_KB` 16, `UDP_RX_BUF_KB` 8, MAC FIFOs 4 KiB each. Estimate: 64 + 19 + 30.5 (protocol without classifier, with the smaller FIFOs about 21.5)
+ 4 = about 108 tiles (target <= 110). With the classifier kept the estimate is about 138 tiles, which does not fit the target.

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

CPU configuration options of `rtlnet_cpu_eth_bd_create` (`cpu_opt`, `cpu_btc`, `cpu_muldiv`; queried from the 2026.1 IP: `C_OPTIMIZATION` 0 Performance, 1 Area,
2 Frequency; `C_BRANCH_TARGET_CACHE_SIZE` 0..7; `C_USE_MULDIV` 0..2), exposed as `build_ethernet.ps1 -CpuOpt -CpuBtc -CpuMuldiv`. See the hand-back for the variant builds.

## 7. Limitations

* The LMB is sized by `lmb_kb`; the firmware needs about 346 KiB (`.bss` 232 KiB mostly lwIP pools), so 512 KiB.
* The generic PHY driver resolves only full-duplex modes; a partner that does not auto-negotiate (parallel detection, half duplex)
  shows no usable link.
* `arp -d` in the ARP test needs an elevated shell; without it the test checks the existing entry.

## 8. Revision history

* 11-14-2026: first version (derived from the H.264 demo CPU with the DDR3 path, caches and video removed).
