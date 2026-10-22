# Nexys Video board — RTLNet board top, build and bring-up

| Item | Value |
|---|---|
| Board | Digilent Nexys Video, XC7A200T-1SBG484C, Realtek RTL8211E-VL |
| Document revision | 10-22-2026 |
| Top | `boards/nexys_video/hdl/rtlnet_nexys_video_top.sv` (`rtlnet_nexys_video_top`) |
| Builds | network (`build.ps1 -Network`, `RTLNET_WITH_NETWORK`: MAC, MDIO, protocol wrapper with ARP/ICMP/DHCP/iperf/UDP socket leaves, UDP echo) and CPU-only (default); both built, timing met, on hardware |
| Tools | Vivado 2025.2, MicroBlaze GCC 13.3, Active-HDL 11.1 |
| Firmware | one image for both builds (`firmware/nexys_video`); absent cores are probed and reported "not present in this build" |

## 1. Files

| File | Content |
|---|---|
| `hdl/rtlnet_nexys_video_top.sv` | board top: pins, MMCM + BUFGs, reset tree, CPU core, decoder, system registers, stubs, MDIO IOBUF, PHY power-on reset, network instances under `RTLNET_WITH_NETWORK` |
| `hdl/rtlnet_nexys_video_sysregs.sv` | system registers (window SYS) |
| `hdl/rtlnet_nexys_video_clk_beacon.sv` | divide-by-32 beacon per clock for the clock monitor |
| `hdl/rtlnet_nexys_video.f`, `hdl/rtlnet_nexys_video_network.f` | filelists (CPU-only; network cores) |
| `constraints/rtlnet_nexys_video.xdc` | pins, I/O standards, `sys_clk` 10 ns, asynchronous pin false paths, configuration |
| `constraints/rtlnet_nexys_video_cpu_only.xdc` | CPU-only build: RGMII receive pins as asynchronous levels |
| `constraints/rtlnet_nexys_video_rgmii.xdc` | network build: RGMII timing (read after synthesis, section 5.1) |
| `scripts/build_bitstream.tcl` | non-project build with gates (section 5) |
| `scripts/build.ps1` | firmware + bitstream + merge (+ `-Network`, `-Program`, `-Test`) |
| `scripts/merge_elf.ps1` | updatemem: firmware ELF into the LMB BRAM |
| `scripts/program.ps1`, `scripts/program.tcl` | JTAG programming (hw_server, `program_hw_devices`) |
| `scripts/cli_test.ps1` | console test over the USB-UART (COM4), either build |
| `scripts/net_test.ps1` | hardware network test: board side over the CLI, host side from the PC NIC when it is up |
| `testbench/tb_rtlnet_nexys_video_top.sv` (+ `.f`) | CPU-only board bench with the CPU BFM |
| `testbench/tb_rtlnet_nexys_video_net.sv` (+ `.f`) | network board bench: BFM + RTL8211E model, ARP / ICMP / UDP echo / DHCP at 10/100/1000 |
| `testbench/regression.txt` | board regression lines (both benches, negative controls) |
| `../../scripts/rtlnet_constrain_cdc.tcl` | crossing constraints and report_cdc waivers by cell name |

## 2. Clocks and resets

| Clock | MMCM output | Frequency | Measured on the board (CLK_MEAS) |
|---|---|---|---|
| `sys_clk` | R4 input | 100 MHz | — |
| `clk125` | CLKOUT0 /8 | 125 MHz | 124.992 / 125.008 MHz |
| `clk125_90` | CLKOUT1 /8, 90 deg | 125 MHz | 124.992 / 125.008 MHz |
| `clk200` | CLKOUT2 /5 | 200 MHz | 200.000 MHz |
| `axis_clk` | CLKOUT3 /16 | 62.5 MHz | 62.512 MHz |
| `proto_clk` (= app_clk) | CLKOUT4 /20 | 50 MHz | 50.000 MHz |
| `cpu_clk` | CLKOUT5 /10 | 100 MHz | reference |

VCO 1000 MHz (M = 10, D = 1), feedback through `u_bufg_fb`, `RST` tied low. The clock monitor counts
both edges of each beacon per 1 ms of cpu_clk (resolution 16 kHz, hence the ±16 kHz readings).

Reset: `rst_arstn = cpu_resetn & mmcm_locked` into `u_rst_clk125`, `u_rst_clk125_90` (beacon only),
`u_rst_clk200`, `u_rst_axis`, `u_rst_proto`, `u_rst_cpu` (`rtlnet_reset_sync`, 4 stages). The AND is
the one LUT on asynchronous clear pins (methodology LUTAR-1, waived by rule in the build with its
glitch argument). The PHY reset `eth_rst_b` is a register: low after reset release, high 20 ms later
(CPU-only build; the MDIO core owns it in the network build).

## 3. RTLNet window and system registers

Decoder `u_decoder` (`rtlnet_axil_decoder`, N = 6), windows of architecture 6.1: SYS 0x44A0_0000,
MAC 0x44A0_1000, MDIO 0x44A0_2000, ECHO 0x44A0_3000, PROTOCOL 0x44A1_0000 (64 KiB),
CLASSIFIER 0x44A2_0000 (reserved). Windows without a core are `rtlnet_axil_slave` stubs: OKAY,
read data 0. Other addresses in the 1 MiB window: DECERR.

System registers (single definition `firmware/nexys_video/src/rtlnet_nexys_video_sysregs.h`):

| Offset | Name | Access | Content |
|---:|---|---|---|
| 0x000 | ID | RO | "NXVD" 0x4E585644 |
| 0x004 | VERSION | RO | 0x10222026 |
| 0x008 | CAPS | RO | [0] network build, [15:8] LEDs (8), [23:16] switches (8), [31:24] buttons (5) |
| 0x00C | BUILD_ID | RO | git hash (`git rev-parse --short=8 HEAD`, generic `BUILD_ID`) |
| 0x010 | BUILD_DIRTY | RO | [0] tree had changes at build time |
| 0x014 | LEDS | RW | [7:1] drive led[7:1] (led[1] firmware heartbeat); [0] reads 0 (led[0] = MMCM lock) |
| 0x018 | SWITCHES | RO | sw[7:0], synchronized |
| 0x01C | BUTTONS | RO | [0] C, [1] D, [2] L, [3] R, [4] U, synchronized |
| 0x020 | CLK_STATUS | RO | [0] MMCM locked; [12:8] clock i measured nonzero |
| 0x024 | SCRATCH | RW | scratch |
| 0x028 | UPTIME_MS | RO | milliseconds since cpu_clk reset release |
| 0x02C | CPU_CLK_HZ | RO | 100000000 |
| 0x030 | PHY_STATUS | RO | [0] int_n, [1] pme_n, [2] rst_n as driven, [3] MDIO pad, [4] rxctl, [8:5] rxd, [9] rxck (CPU-only) |
| 0x034 | NET_STATUS | RO | [0] link up, [2:1] speed, [3] RXC ok, [4] IP valid, [5] DHCP bound (network build) |
| 0x040 + 4i | CLK_MEAS[i] | RO | beacon edges per ms of clk125, clk125_90, clk200, axis_clk, proto_clk; f(kHz) = 16 x value |

## 4. Pins

As the Digilent master XDC (names kept): `sysclk` R4 (master XDC name `clk`, schematic net SYSCLK),
`cpu_resetn` G4, `uart_tx_in` V18 (bridge TXD into the FPGA), `uart_rx_out` AA19, `led[7:0]`
T14 T15 T16 U16 V15 W16 W15 Y13, `sw[7:0]` E22 F21 G21 G22 H17 J16 K13 M17, `btnc/d/l/r/u`
B22 D22 C22 D14 F15, RGMII `eth_rxck` V13, `eth_rxctl` W10, `eth_rxd` AB16 AA15 AB15 AB11,
`eth_txck` AA14, `eth_txctl` V10, `eth_txd` Y12 W12 W11 Y11, `eth_mdc` AA16, `eth_mdio` Y16,
`eth_int_b` Y14, `eth_pme_b` W14, `eth_rst_b` U7 (bank 34, 3.3 V). Banks 15/16 at the VADJ default
1.2 V (LVCMOS12), bank 13 2.5 V, bank 14/34 3.3 V, bank 35 1.5 V. The UART direction was confirmed on
hardware.

## 5. Build flow and gates

`powershell -File boards/nexys_video/scripts/build.ps1 [-Network] [-Program] [-Test]` runs the
firmware build (with the CLI table check and the harness demo), `build_bitstream.tcl` through
`scripts/rtlnet_vivado.ps1`, and `merge_elf.ps1`. Outputs in `boards/nexys_video/build/`:
`rtlnet_nexys_video.bit` (to program), `rtlnet_nexys_video_hw.bit` (no firmware),
`rtlnet_nexys_video.mmi`, `build_info.txt`, `post_synth.dcp`, `post_route.dcp`, `reports/`.

Exit codes of `build_bitstream.tcl`: 99 arguments, 11 missing file, 12 block design, 10 synthesis
error or critical warning, 13 CDC constraint script, 25/26 opt/place, 30 route, 20 timing (setup WNS,
hold WHS, pulse width, any failing endpoint; threshold 0), 21 utilization above 80 %, 22 check_timing
(no_clock, unconstrained endpoints, loops, multiple clocks), 23 latches or user asynchronous
clear/preset endpoints outside `rtlnet_reset_sync` and the vendor block design, 27 report_cdc
Critical/Warning or an unwaived methodology finding, 24 critical warnings during implementation,
40 write_bitstream, 41 write_mem_info.

Methodology waivers (printed on every run, each an explicit rule with its reason):

| Rule | Scope | Reason |
|---|---|---|
| LUTAR-1 | the reset AND: the LUT `u_rst_*/pipe[*]_i_1*` and every pin it drives a `u_rst_*/pipe_reg[*]/CLR` | `rst_arstn = cpu_resetn & mmcm_locked` into the `rtlnet_reset_sync` chains only; glitch argument in the board top header |
| LUTAR-1 | LUT and pins inside `u_cpu/u_bd/` | vendor MDM JTAG control logic |
| TIMING-9 | any | allowed only because report_cdc (gated) has no Critical/Warning finding left; the asynchronous groups are the MDM BSCAN clocks of the vendor IP |
| TIMING-47 | false paths between `rgmii_rxc_v` and `rgmii_rxc` | RGMII same-edge capture: the opposite-edge setup and same-edge hold pairs describe no capture (MAC documentation section 6) |

The report_cdc gate parses the ID summary of `report_cdc -details` (the clock-pair summary of a plain
`report_cdc` carries no IDs; the gate fails when the ID table is missing).

CDC constraints (`scripts/rtlnet_constrain_cdc.tcl`, sourced after synthesis): classes sync, reset,
gray, fifo, axil_cdc by cell name; per-class counts and a per-instance list
(`build/reports/cdc_instances.txt`) are written; `::rtlnet_cdc_required` is `{sync reset}` for the
CPU-only build and all five for the network build (zero matches of a required class is an error);
`::rtlnet_cdc_expect` pins the instance counts (network: fifo 7, axil_cdc 3, gray 5; CPU-only: 0, 0,
0), so a crossing added or lost by a core change fails the build until reviewed. For the findings
report_cdc cannot recognize the script creates native waivers (`create_waiver -type CDC`), scoped to
one instance's source and destination registers with the protocol as the reason: CDC-6 on every Gray
bus (`gray_src` -> `gray_dst_ff[0]`, FIFO `s_gray`/`m_gray` -> `*_m1`/`*_s1`) and on the FIFO event
toggles (`events_s` -> `events_m1`), CDC-1 and CDC-15 on the `rtlnet_axil_cdc` held bundles
(`req_*_hold`, `rsp_*_hold`). report_cdc lists them as waived; anything else still fails the gate.

### 5.1 RGMII constraints (network build)

`constraints/rtlnet_nexys_video_rgmii.xdc`, read after synthesis (it names pin-layer cells), from the
MAC's board constraints block: `rgmii_rxc` 8 ns on `eth_rxck` plus the virtual launch clock
`rgmii_rxc_v`; input delays -1.2 / -2.8 ns on both edges (PHY RX delay on, RTL8211E Table 65
setup/hold >= 1.2 ns); same-edge multicycle 0 / -1 and four edge-pair false paths; `rgmii_txc`
generated on `eth_txck` from `*/u_rgmii_io/u_txc_oddr` (clk125_90); output delays +-1.0 ns on both
edges; IODELAY group `rtlnet_rgmii` on the IDELAYCTRL and the five IDELAYE2; SLEW FAST on the transmit
pins. IOB packing: the IDDR/ODDR are ILOGIC/OLOGIC cells. MDC/MDIO/PHY reset/interrupt stay false
paths (`rtlnet_nexys_video.xdc`). No clock groups.

### 5.2 Firmware network manager

`firmware/nexys_video/src/rtlnet_netmgr.c` (called from `main.c`): probes every core; MDIO core
init, MDC calibration against the AXI timer, wait for the core's PHY power-on reset plus 30 ms,
RTL8211E ID check, RX delay on (page 0xA4 register 28, read back), advertisement (full duplex
10/100/1000 by default) and AN restart; MAC init; protocol addresses (MAC kept from the wrapper's
reset value, static 192.169.1.220/24, gateway 192.169.1.1); DHCP AUTO flag; iperf port 5001; socket 0
open on port 7 with connect-on-receive; UDP echo on socket 0. Link monitor every 250 ms (PHYSR):
link up programs the MAC speed, RX/TX enable (unless `shutdown`), LINK_UP, waits for the receive
path, prints `%LINK: eth0 up, <speed> Mb/s <duplex> duplex`, and starts DHCP when `auto` is set and
no lease is held; link down clears LINK_UP and prints `%LINK: eth0 down`; DHCP lease changes print
`%DHCP: bound ...` / `%DHCP: lease lost`. LEDs: led[2] link, led[3] DHCP lease (the `led` command can
override them until the next event).

## 6. Results

### 6.1 Network build

Network build of commit d2aa3977 (tree clean), 10-22-2026, Vivado 2025.2, `build.ps1 -Network`:

| Item | Result |
|---|---|
| Synthesis / implementation | 0 critical warnings; bitstream build 694 s |
| Timing (post-route) | WNS +0.221 ns, WHS +0.017 ns, WPWS +0.264 ns; 0 failing setup, hold and pulse-width endpoints |
| RGMII interface (1000 Mb/s budget) | receive `rgmii_rxc_v` -> `rgmii_rxc` setup +0.221 / hold +0.243 ns (tap 12); transmit clk125 -> `rgmii_txc` setup +0.269 / hold +0.274 ns |
| Intra-clock WNS | cpu_clk +1.936, proto_clk +2.375, clk125 +1.514, axis_clk +4.675, rgmii_rxc +3.014 ns |
| Utilization (post-route) | 12783 LUTs (9.55 %), 16902 FFs (6.32 %), 54.5 BRAM tiles (14.93 %), 5 DSP48 (0.68 %) |
| By instance (LUT / FF / RAMB36 + RAMB18) | u_protocol 8505 / 11659 / 15 + 5; u_cpu 2451 / 2094 / 32 + 0; u_mac 1064 / 1679 / 4 + 2; u_echo 296 / 648; u_sysregs 252 / 533; u_decoder 136 / 130; u_mdio 49 / 98 |
| CDC constraints | sync 26 instances / 118 first stages; reset 8 / 32 CLR pins (6 board + 2 MAC); gray 5 / 160; fifo 7 / 68; axil_cdc 3 / 200; counts equal the expectation; 32 report_cdc waivers created |
| report_cdc | unwaived: Info only (CDC-3, CDC-9); waived endpoints CDC-1 x159, CDC-6 x188, CDC-15 x237, all inside the crossing primitives; every clock pair "Safely Timed", 0 unsafe, 0 unknown |
| Methodology | LUTAR-1 x3, TIMING-9 x1, TIMING-47 x4, all matched by the waivers of section 5 |
| Asynchronous clear endpoints | 32 in `rtlnet_reset_sync` (24 board, 8 MAC), 45 vendor block design, 0 elsewhere; 0 latches |
| Firmware | `firmware.elf` text 51856 B, data 4 B, bss + stack 23520 B |

Board simulation (Active-HDL 11.1, `scripts/rtlnet_regression.ps1 -Match tb_rtlnet_nexys_video`):

| Line | Result |
|---|---|
| `tb_rtlnet_nexys_video_top` | TEST PASS, 74 checks |
| `tb_rtlnet_nexys_video_top` `neg` | TEST FAIL as required |
| `tb_rtlnet_nexys_video_net` `g100` | TEST PASS, 74 checks: core IDs, MDIO bring-up through the MDIO core (PHYID, RX delay with read-back, PHYSR), MAC qualified, ARP reply, ICMP echo reply (56-byte payload), UDP echo on port 7 (100 bytes), DHCP DISCOVER/OFFER/REQUEST/ACK with the bench as server, lease 192.169.1.77 with the effective IP switched, ARP for the lease, MAC counters 6 RX / 6 TX, no PHY timing violation |
| `tb_rtlnet_nexys_video_net` `g1000` | TEST PASS, 74 checks |
| `tb_rtlnet_nexys_video_net` `g10` | TEST PASS, 74 checks (a first run with a 400 us frame timeout failed at the DHCP REQUEST, which proves the checks fail; the timeout is now x10 at 10 Mb/s) |
| `tb_rtlnet_nexys_video_net` `neg` | TEST FAIL as required |

Hardware (board cabled to a 10/100 router at 192.169.1.1), network image d2aa3977:

| Check | Result |
|---|---|
| Start-up | `Network: MAC ok, MDIO ok, PHY ok (ID 0x001CC915, RX delay reg 0xAD77 -> 0xAD77), protocol ok` |
| PHY | RTL8211E ID 0x001CC915, RX delay on, AN complete, partner 10h/10f/100h/100f, MDC half period 346 ns |
| Link | `%LINK: eth0 up, 100 Mb/s full duplex, MAC receive ready`; MAC RXC rate 102-103, receive path running |
| DHCP | `%DHCP: bound 192.169.1.199 mask 255.255.255.0 router 192.169.1.1 lease 43200 s`; effective IP switched; renew and stop/start (release, discover, offer, request, ack) both worked |
| Traffic | renew: MAC rx good / tx +1 each, RX_BAD 0; the router ARPed the board and got replies (ARP requests = replies) |
| 10 Mb/s | `speed 10` (advertise 10f): link down/up, 10 Mb/s full duplex, RXC rate 10, renew + stop/start DHCP + ARP replies; `speed auto` back to 100 Mb/s |
| Scripts | `net_test.ps1`: PASS 18/18 board-side, 4 host checks BLOCKED (PC NIC disconnected); `cli_test.ps1`: PASS 15/15 |

#### Host-side network tests, 10-22-2026

PC on the bench network over Wi-Fi (`IronKernel`, PC 192.169.1.130, router 192.169.1.1); board DHCP lease
192.169.1.199. `net_test.ps1 -Nic "Wi-Fi 2" -Speed <n>`, with the link forced from the CLI for 10 Mb/s
(`interface eth0` / `speed 10`) and `speed auto` restored afterwards.

| Check | 100 Mb/s (auto) | 10 Mb/s (forced) |
|---|---|---|
| link, MAC RXC qualified, PHY ID / RX delay, PHYSR speed | pass | pass (RXC rate 11) |
| DHCP lease, effective IP from the lease, renew moves counters, RX_BAD 0 | pass | pass |
| `ping -l 0 / 64 / 1472 -n 20` | 0 lost each | 0 lost each |
| board ARP entry on the PC | pass | pass |
| `udp_echo_client.py`, 200 datagrams to port 7, byte-exact | PASS | PASS |
| iperf 2.2.2 UDP, PC to board (`-u -b 90M` / `9M`, 1470 B, 5 s) | 93.7 Mbit/s, 57/40050 lost (0.14 %) | 9.4 Mbit/s, 0/3999 lost |
| iperf 2.2.2 UDP, board to PC (`-u -R`) | 92.0 Mbit/s, 269/40126 lost (0.67 %) | 9.4 Mbit/s, 0/4014 lost |
| summary | `NET_TEST: PASS 25/25` | `NET_TEST: PASS 16/16` |

The 100 Mb/s iperf losses are outside the board: after a run the board reads MAC `rx bad 0`, `rx overflow 0`,
protocol ingress `dropped 0`, and the iperf leaf's own loss count equals the client's (64 of 40111 in the
characterization run), i.e. datagrams lost on the PC's Wi-Fi leg or in the router before they reached the board.
At 10 Mb/s, where the Wi-Fi leg has ample headroom, nothing is lost in either direction. The client offers about
94 Mbit/s whatever `-b` asks (the 1470-byte ceiling on 100 Mb/s Ethernet is 95.6 Mbit/s).

iperf binary: iperf 2.2.2 (pthreads, community build) at `C:\IronKernel\tools\iperf\iperf.exe`, outside the
repository; `net_test.ps1` finds it there (or via `-Iperf <path>` or PATH).

1000 Mb/s on hardware still needs a gigabit link partner (the router is 10/100).
| Cold start | after JTAG configuration: link up 100 Mb/s and a DHCP lease acquired from scratch (discover/offer/request/ack 1 each), MAC rx 2 / tx 2 |
| Host tests (arp, ping 0/64/1472 x20, UDP echo client, iperf -u) | not run: the PC's wired NIC "Ethernet" (ASIX USB, 192.169.1.178) is disconnected; no iperf 2 binary on PATH |

### 6.2 CPU-only build

CPU-only build of commit f34a8bac (tree clean), 10-22-2026, Vivado 2025.2, `build.ps1 -Test`:

| Item | Result |
|---|---|
| Synthesis / implementation | 0 critical warnings; bitstream build 374 s |
| Timing (post-route) | WNS +1.698 ns, WHS +0.081 ns, WPWS +2.000 ns; 0 failing setup, hold and pulse-width endpoints (worst paths in the MicroBlaze, cpu_clk) |
| Utilization (post-route) | 2869 LUTs (2.14 %), 2848 FFs (1.06 %), 32 RAMB36 (8.77 %), 3 DSP48 (0.41 %) |
| CDC constraints | sync: 7 instances, 34 first stages; reset: 6 instances, 24 CLR pins; gray/fifo/axil_cdc: 0 (not in this build) |
| report_cdc | Info findings only (CDC-3 synchronized 1-bit, CDC-9 synchronized reset) |
| Methodology | LUTAR-1 x3 and TIMING-9, all waived by rule (section 5); no other finding |
| check_timing | no unclocked or unconstrained endpoints; the asynchronous ports carry false paths |
| Asynchronous clear endpoints | 24 in `rtlnet_reset_sync`, 45 inside the vendor block design, 0 elsewhere; 0 latches |
| Firmware | `firmware.elf` text 28308 B, data 4 B, bss + stack 23352 B (8 KiB stack) of the 128 KiB LMB |
| Merge | updatemem 0 warnings; `rtlnet_nexys_video.bit` 1571893 bytes |
| JTAG | `program.ps1`: xc7a200t_0 programmed in 1.9 s, DONE high |
| Console | `cli_test.ps1` on COM4: PASS 15/15 |
| Board bench | `tb_rtlnet_nexys_video_top` TEST PASS 74 checks (3 s); `+INJECT_FAILURE` TEST FAIL; a perturbed clock expectation TEST FAIL |
| Host harness | `menu.exe --demo` TEST PASS 202 checks; `--inject-failure` TEST FAIL (199 checks with the network command set) |

Re-run of the CPU-only build with the network-phase gates (commit 78db4daa, tree clean): PASS, WNS
+0.745 ns, WHS +0.066 ns, 0 failing endpoints, 2862 LUTs, CDC counts fifo/axil_cdc/gray 0 as expected,
report_cdc Info only; the network-phase firmware on it prints "Network cores not in this build." and
`cli_test.ps1` passes 15/15.

Also exercised by hand on the board: `show ?`, `sh?`, the ambiguous `show i`, `no ?` in config-if,
Ctrl-C, Ctrl-Z, up-arrow recall, `!!`, backspace, `reload` (banner again, firmware uptime restarted,
hardware UPTIME_MS continuing). The PHY leaves reset (rst_n 1) and its receive clock toggles.

## 7. Network integration (done 10-22-2026) and what remains

Integrated: `u_mac`, `u_mdio`, `u_protocol` (every leaf), `u_echo` under `RTLNET_WITH_NETWORK`, the
RGMII constraints, the CDC classes and counts, every core driver in the firmware (CLI and network
manager), the network board bench, and the hardware bring-up of section 6.1.

Open:

1. Host-side hardware tests (PC ARP entry, ping sweep 0/64/1472 x20, UDP echo client, iperf -u):
   `net_test.ps1` runs them as soon as the PC NIC "Ethernet" is connected; no iperf 2 binary is on
   this PC (none was downloaded).
2. 1000 Mb/s on hardware needs a gigabit partner (simulated and constrained; the router is 10/100).
3. RX IDELAY tap sweep on hardware (the MAC documentation's procedure); the build meets the 1000 Mb/s
   RGMII budget with tap 12 (balanced +0.22 / +0.24 ns).
4. The `ev_*` pulse outputs of the MAC and the protocol wrapper are unconnected (LED or interrupt use).
5. Interrupts (PHY INTB through `rtlnet_mdio` irq[0]) are wired but the firmware polls.

## 8. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version: CPU-only board top, build flow, bring-up |
| 10-22-2026 | Network integration: RGMII XDC, CDC counts and waivers, network board bench, firmware network manager and driver-backed CLI, hardware results at 100 and 10 Mb/s |
