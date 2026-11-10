# Nexys Video board — RTLNet board top, build and bring-up

| Item | Value |
|---|---|
| Board | Digilent Nexys Video, XC7A200T-1SBG484C, Realtek RTL8211E-VL |
| Document revision | 11-09-2026 |
| Top | `boards/nexys_video/hdl/rtlnet_nexys_video_top.sv` (`rtlnet_nexys_video_top`) |
| Builds | network (`build.ps1 -Network`, `RTLNET_WITH_NETWORK`: MAC, MDIO, protocol wrapper with ARP/ICMP/DHCP/iperf/UDP socket leaves, CPU network path with its classifier, UDP echo) and CPU-only (default); both built, timing met, on hardware |
| Tools | Vivado 2026.1, GNU GCC 13.4 (RISC-V, MicroBlaze V), Active-HDL 11.1 |
| Firmware | one image for both builds (`microblaze/firmware`, standalone BSP generated from the build's XSA, lwIP TCP echo on the CPU network path); absent cores are probed and reported "not present in this build" |

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
| `scripts/build.ps1` | bitstream + XSA, firmware (BSP from the XSA) + merge (+ `-Network`, `-Program`, `-Test`) |
| `scripts/merge_elf.ps1` | updatemem: firmware ELF into the LMB BRAM |
| `scripts/program.ps1`, `scripts/program.tcl` | JTAG programming (hw_server, `program_hw_devices`) |
| `scripts/cli_test.ps1` | console test over the USB-UART (COM4), either build; Phase 1 adds the video commands |
| `scripts/phase1_gate.ps1` | Phase 1 board gate: color bars with no firmware writes, `framebuffer crc` against the C model at 720p30 and 1080p30, arbiter errors 0 |
| `scripts/net_test.ps1` | hardware network test: board side over the CLI, host side from the PC NIC when it is up |
| `../../scripts/rtlnet_board.ps1`, `../../scripts/rtlnet_board_lock.ps1` | machine-wide board lock shared with the other session that uses the board (section 5.3) |
| `scripts/tcp_test.ps1` | hardware test of the CPU network path: lwIP TCP echo, TCP iperf (rtlnet_lwiperf: PC -> board, `-R`, `-r`, `-d`), both together with the RTL UDP iperf |
| `testbench/tb_rtlnet_nexys_video_top.sv` (+ `.f`) | CPU-only board bench with the MicroBlaze simulation stub |
| `testbench/tb_rtlnet_nexys_video_net.sv` (+ `.f`) | network board bench: sim stub + RTL8211E model, ARP / ICMP / UDP echo / DHCP at 10/100/1000 |
| `testbench/regression.txt` | board regression lines (both benches, negative controls) |
| `../../scripts/rtlnet_constrain_cdc.tcl` | crossing constraints and report_cdc waivers by cell name |

## 2. Clocks and resets

| Clock | MMCM output | Frequency | Measured on the board (CLK_MEAS) |
|---|---|---|---|
| `sys_clk` | R4 input | 100 MHz | — (MMCM input only) |
| `clk125` | CLKOUT0 /8 | 125 MHz | 124.992 / 125.008 MHz |
| `clk125_90` | CLKOUT1 /8, 90 deg | 125 MHz | 124.992 / 125.008 MHz |
| `clk200` | CLKOUT2 /5 | 200 MHz | 200.000 MHz |
| `axis_clk` | CLKOUT3 /16 | 62.5 MHz | 62.512 MHz |
| `proto_clk` (= app_clk) | CLKOUT4 /20 | 50 MHz | 50.000 MHz |
| `cpu_clk` | CLKOUT5 /10 | 100 MHz | reference |
| `ddr_sys_clk` | CLKOUT6 /10 through BUFG `u_bufg_ddrsys` | 100 MHz | MIG PLL input (the oscillator pad cannot feed the MMCM and the MIG PLL together: Place 30-172) |
| `ui_clk` | MIG user clock (PLL inside the IP) | 100 MHz | DDR3 AXI4 side, arbiter, the `u_ddr_cdc` bridge master side, `ddr_resetn` domain |

VCO 1000 MHz (M = 10, D = 1), feedback through `u_bufg_fb`, `RST` tied low. The clock monitor counts
both edges of each beacon per 1 ms of cpu_clk (resolution 16 kHz, hence the ±16 kHz readings).

Reset: `rst_arstn = cpu_resetn & mmcm_locked` into `u_rst_clk125`, `u_rst_clk125_90` (beacon only),
`u_rst_clk200`, `u_rst_axis`, `u_rst_proto`, `u_rst_cpu` (`rtlnet_reset_sync`, 4 stages). The AND is
the one LUT on asynchronous clear pins (methodology LUTAR-1, waived by rule in the build with its
glitch argument). `u_rst_ddr` (clk `ui_clk`) takes `rst_arstn` alone; the MIG ui reset (`ui_resetn_mig`) is ANDed after the chain, so no LUT drives its clear pins. The PHY reset `eth_rst_b` is a register: low after reset release, high 20 ms later
(CPU-only build; the MDIO core owns it in the network build).

## 3. RTLNet window and system registers

Decoder `u_decoder` (`rtlnet_axil_decoder`, N = 10), windows of architecture 6.1: SYS 0x44A0_0000,
MAC 0x44A0_1000, MDIO 0x44A0_2000, ECHO 0x44A0_3000, ARBITER 0x44A0_4000, and the Phase 1 video cores CSI2 0x44A0_5000
(`rtlnet_csi2_rx`), S2MM 0x44A0_6000 (`rtlnet_vdma_s2mm`), FRAMEBUF 0x44A0_7000 (`rtlnet_framebuf`), PROTOCOL 0x44A1_0000 (64 KiB),
CLASSIFIER 0x44A2_0000 (reserved for a main-ingress classifier; the CPU-path classifier is inside the protocol
wrapper at PROTOCOL + 0x8000 = 0x44A1_8000; the checksum offload `rtlnet_tcp_offload` at PROTOCOL + 0x9000 =
0x44A1_9000). Windows without a core are `rtlnet_axil_slave` stubs: OKAY,
read data 0. Other addresses in the 1 MiB window: DECERR.

System registers (single definition `microblaze/firmware/src/rtlnet_nexys_video_sysregs.h`):

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

`powershell -File boards/nexys_video/scripts/build.ps1 [-Network] [-Program] [-Test] [-Tag <name>]` runs
`build_bitstream.tcl` (which also writes the hardware export `rtlnet_nexys_video.xsa`), then the firmware
build on a BSP generated from that XSA (with the CLI table check and the harness demo,
`microblaze/documentation/rtlnet_cpu_microblaze.md` section 5), through
`scripts/rtlnet_vivado.ps1`, and `merge_elf.ps1`. Outputs in `boards/nexys_video/build/`:
`rtlnet_nexys_video.bit` (to program), `rtlnet_nexys_video_hw.bit` (no firmware),
`rtlnet_nexys_video.mmi`, `build_info.txt`, `post_synth.dcp`, `post_route.dcp`, `reports/`. With `-Tag <name>` only the bitstream step runs and every output goes to `build/<name>/` (for example `-Tag cpu` for the CPU-only gate build), so the network image files stay as they are.

Exit codes of `build_bitstream.tcl`: 99 arguments, 11 missing file, 12 block design, 10 synthesis
error or critical warning, 13 CDC constraint script, 25/26 opt/place, 30 route, 20 timing (setup WNS,
hold WHS, pulse width, any failing endpoint; threshold 0), 21 utilization above 80 %, 22 check_timing
(no_clock, unconstrained endpoints, loops, multiple clocks), 23 latches or user asynchronous
clear/preset endpoints outside `rtlnet_reset_sync`, the vendor block design and the vendor DDR3 controller (`u_ddr/g_amd.u_ddr/u_mig`), 27 report_cdc
Critical/Warning or an unwaived methodology finding, 24 critical warnings during implementation,
40 write_bitstream, 41 write_mem_info, 42 write_hw_platform.

Methodology waivers (printed on every run, each an explicit rule with its reason):

| Rule | Scope | Reason |
|---|---|---|
| LUTAR-1 | the reset AND: the LUT `u_rst_*/pipe[*]_i_1*` and every pin it drives a `u_rst_*/pipe_reg[*]/CLR` | `rst_arstn = cpu_resetn & mmcm_locked` into the `rtlnet_reset_sync` chains only; glitch argument in the board top header |
| LUTAR-1 | LUT and pins inside `u_cpu/u_bd/` | vendor MDM JTAG control logic |
| TIMING-9 | any | allowed only because report_cdc (gated) has no Critical/Warning finding left; the asynchronous groups are the MDM BSCAN clocks of the vendor IP |
| TIMING-47 | false paths between `rgmii_rxc_v` and `rgmii_rxc` | RGMII same-edge capture: the opposite-edge setup and same-edge hold pairs describe no capture (MAC documentation section 6) |
| LUTAR-1 | the AMD MIG IP (`u_ddr/g_amd.u_ddr/u_mig`): the LUT `u_iodelay_ctrl/rstdiv2_sync_r[11]_i_1` and every pin it drives, a `u_ddr3_infrastructure/rstdiv0_sync_r1_reg_rep*/PRE` | vendor-generated reset logic of the memory controller (reset synchronizer, no user logic); required target |
| PDRC-190 | the AMD MIG IP: the 12 cells `temp_mon_enabled.u_tempmon/device_temp_sync_r5_reg[0..11]` | vendor-generated temperature monitor synchronizer, placement fixed by the IP; each of the 12 indices is a required target |
| XDCB-5 | the AMD MIG IP: its `set_max_delay -to [get_pins -hier ... device_temp_sync_r1_reg[*]/D]` constraint | vendor IP constraint text; required target |

A waiver marked required lists its targets in `build_bitstream.tcl`; a required target that matches no finding fails
the build (exit 27), so a stale waiver or a changed IP is never silent. The build prints `required waiver <rule>: n of m
targets matched` on every run.

CDC-8 inside the MIG (`u_iodelay_ctrl/rst_ref_sync_r_reg[0][*]` and `u_ddr3_infrastructure/rstdiv0_sync_r_reg[*]`,
first stages of the vendor reset synchronizers) is cleared by setting `ASYNC_REG TRUE` on exactly those cells after
synthesis (`build_bitstream.tcl`); a missing target fails the build. It is a property change, not a waiver.

The report_cdc gate parses the ID summary of `report_cdc -details` (the clock-pair summary of a plain
`report_cdc` carries no IDs; the gate fails when the ID table is missing).

CDC constraints (`scripts/rtlnet_constrain_cdc.tcl`, sourced after synthesis): classes sync, reset,
gray, fifo, axil_cdc by cell name; per-class counts and a per-instance list
(`build/reports/cdc_instances.txt`) are written; `::rtlnet_cdc_required` is `{sync reset axil_cdc fifo}` for the
CPU-only build and all five for the network build (zero matches of a required class is an error);
`::rtlnet_cdc_expect` pins the instance counts (network: fifo 15, axil_cdc 6, gray 6; CPU-only: 5, 1,
0; the five DDR3 bridge FIFOs `u_ddr_cdc/u_{aw,w,b,ar,r}_fifo` are in both builds; the fourth `rtlnet_axil_cdc` is the CPU-path classifier's register crossing, the fifth the checksum offload's, the sixth the DDR3 arbiter's (the only one in the CPU-only build), the
tenth fifo the offload's TX buffer; the synchronizers of the crossings are counted in the sync class), so a crossing added or lost by a core change fails the build until reviewed. For the findings
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

`microblaze/firmware/src/rtlnet_netmgr.c` (called from `main.c`): probes every core; MDIO core
init, MDC calibration against the AXI timer, wait for the core's PHY power-on reset plus 30 ms,
RTL8211E ID check, RX delay on (page 0xA4 register 28, read back), advertisement (full duplex
10/100/1000 by default) and AN restart; MAC init; CPU-path classifier (`cpupath_init`: `rtlnet_classifier_init` at
0x44A1_8000, then `rtlnet_classifier_config_bcast_storm(10, 100)`, before the MAC receive path is enabled and before
`InitLWIP`; the classifier is drop-all until then); protocol addresses (MAC kept from the wrapper's
reset value, static 192.169.1.220/24, gateway 192.169.1.1); DHCP AUTO flag; iperf port 5001; socket 0
open on port 7 with connect-on-receive; UDP echo on socket 0. Link monitor every 250 ms (PHYSR):
link up programs the MAC speed, RX/TX enable (unless `shutdown`), LINK_UP, waits for the receive
path, prints `%LINK: eth0 up, <speed> Mb/s <duplex> duplex`, and starts DHCP when `auto` is set and
no lease is held; link down clears LINK_UP and prints `%LINK: eth0 down`; DHCP lease changes print
`%DHCP: bound ...` / `%DHCP: lease lost`. LEDs: led[2] link, led[3] DHCP lease (the `led` command can
override them until the next event).

### 5.3 Board lock

The board and its `hw_server` are shared with another Claude session (project Commodore64). Every script that touches
the board (`program.ps1`, `jtag_load_elf.ps1`, `cli_test.ps1`, `net_test.ps1`, `tcp_test.ps1`, `offload_bench.ps1`,
`offload_profile.ps1`, and `build.ps1` with `-Program` or `-Test`) calls `Enter-RtlnetBoardLock` first
(`scripts/rtlnet_board_lock.ps1`, default 60 minutes). The lock is the file `%LOCALAPPDATA%\IronKernel\nexys_video.lock`
with the JSON fields `session` ("rtlnet"), `purpose`, `start` (ISO time), `expected_minutes`, `pid` and `host`.

- A board session spans several runs (program, load, tests), so the lock is not delete-on-close and the scripts never
  release it. `pid` is the nearest long-lived ancestor of the script (first `claude*`, `node` or `Code` process up the
  parent chain; else the parent of the PowerShell process), not the short-lived script.
- A lock is stale when its `pid` no longer exists or the time is past `start + expected_minutes + 30` minutes. A script
  that takes a stale lock prints `RTLNET_BOARD_LOCK: taking stale lock of session ...`.
- A live, unexpired lock of another session ends the script at once with exit code 3 and a line naming holder, purpose
  and start. The scripts never wait and never take the lock over. A lock of session "rtlnet" is reused and its start
  time refreshed. The file is created with `FileMode.CreateNew` (atomic), retried once after removing a stale lock.
- Command line: `rtlnet_board.ps1 take -Purpose "<text>" -Minutes <n>`, `rtlnet_board.ps1 show`, `rtlnet_board.ps1 release`
  (removes the lock only when it belongs to "rtlnet"). A board session ends with `release`.
- Test: `build/board_lock_test.txt` runs the four negative paths against a fake lock file (`$env:RTLNET_BOARD_LOCK`
  overrides the path for tests only): foreign live pid refused (and `program.ps1` refuses before it starts Vivado), foreign
  dead pid taken as stale, expired lock taken as stale, own session reused with its start refreshed; plus a lock inside the
  30 minute grace refused, and `release` leaving a foreign lock alone. Last line `LOCK TEST PASS`.

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

### 6.3 CPU-only build with the CPU network path hardware

CPU-only build of commit 874f3966 (tree clean), 10-22-2026, Vivado 2025.2: the block design with the
512 KiB LMB, the AXI DMA and the 128 KiB AXI BRAM; firmware on the BSP generated from this build's XSA.

| Item | Result |
|---|---|
| Synthesis / implementation | 0 critical warnings; `rtlnet_build: PASS` |
| Timing (post-route) | WNS +0.701 ns, WHS +0.014 ns, WPWS +2.000 ns; 0 failing setup, hold and pulse-width endpoints (with the 256 KiB LMB: WNS +1.142 ns, WHS +0.020 ns) |
| Utilization (post-route) | 5294 LUTs (3.96 %), 5564 FFs (2.08 %), 162 BRAM tiles (44.38 %: LMB 128 + AXI BRAM 32 RAMB36 + 2), 3 DSP48 |
| CDC | sync 7 / 34, reset 6 / 24, gray/fifo/axil_cdc 0 as expected; report_cdc Info only |
| Methodology | LUTAR-1 x3, TIMING-9, all waived by rule; no other finding |
| XSA | `rtlnet_nexys_video.xsa` written; BSP generated with the Vitis 2025.2 Python API (`RTLNET_BSP: PASS`) |
| Firmware | `firmware.elf` text 139304 B, data 2104 B, bss 127732 B (lwIP heap and pools in the LMB), + 2 KiB heap, 8 KiB stack: 271 KiB of the 512 KiB LMB; 12 KiB of DMA buffers in the AXI BRAM |
| Merge | updatemem 0 warnings; the MMI lists the LMB (0..524287, 128 RAMB36) and the AXI BRAM address spaces |
| JTAG | `program.ps1`: programmed in 3.0 s, DONE high |
| Console | `cli_test.ps1` on COM4: PASS 27/27 (the 15 earlier steps plus show cpu-path, show tcp, show storm-control, show classifier, tcp echo port change and restore, show running-config) |
| Start-up line | `Network cores not in this build. CPU path: DMA ok.`; `show cpu-path`: AXI DMA found by XAxiDma at 0x4040_0000, S2MM armed (status 0x00000000), MM2S halted (0x00000001) |
| Time base | XTmrCtr 1 ms interrupt through XIntc: firmware uptime equals the hardware UPTIME_MS register (10200 ms both) |
| Soft restart | `reload`: banner again, firmware uptime restarted (2487 ms against 35309 ms hardware), interrupts running again |
| Host harness | `menu.exe --demo` TEST PASS 248 checks; `--inject-failure` TEST FAIL |
| Board bench | `tb_rtlnet_nexys_video_top` TEST PASS 74 checks with `rtlnet_microblaze_sim_stub` |

### 6.4 Network build with the CPU network path

Network build of commit a9e043e6 (tree clean), 10-22-2026: protocol wrapper with the CPU path
(`CPU_PATH_ENABLE` 1, `CPU_RX_FIFO_KB` 32, `CPU_TX_FIFO_KB` 8, `CPU_CLASSIFIER_ENABLE` 0 until the classifier
core lands), u_cpu's DMA streams on `s_axis_cpu_eth_*` / `m_axis_cpu_eth_*` in cpu_clk.

| Item | Result |
|---|---|
| Timing (post-route) | WNS +0.221 ns, WHS +0.018 ns, WPWS +0.264 ns; 0 failing endpoints |
| Utilization | 16169 LUTs (12.08 %), 21183 FFs (7.92 %), 196.5 BRAM tiles (53.84 %), 5 DSP48 |
| CDC | fifo 9, gray 6, axil_cdc 3 instances, as expected (`build_bitstream.tcl`) |
| Firmware | text 153724 B, data 2104 B, bss 151624 B (lwIP with the echo and iperf servers): 307 KiB of 512 KiB; after the TCP throughput tuning (`microblaze/documentation/rtlnet_cpu_microblaze.md` section 9.10): text 162356 B, data 2104 B, bss 238280 B, 381 KiB of 512 KiB |
| Console | `cli_test.ps1` PASS 27/27; start-up: `PHY: RTL8211E ID 0x001CC915, RX delay 0xAD77 -> 0xAD77, MDC half period 266 ns, LEDs LINK steady, ACT blink, USER off; EEE off, auto-negotiation restarted`, `CPU path: DMA ok, classifier absent, lwIP up (TCP echo, TCP iperf)` |
| PHY LEDs / EEE | `show phy`: LCR 0x0070, LACR 0x0010 (read back), MMD 7.60 = 0x0000 (EEE not advertised); the LED behaviour itself was not observed (no view of the board) |
| lwIP identity | `show tcp`: netif MAC 02:49:4b:52:4e:01, IPv4 192.169.1.199 / 24, gateway 192.169.1.1 (the DHCP lease), "RTL identity: matches" |
| TCP echo alone | `tcp_echo_client.py`, 4 connections x 76 messages (1 B .. 64 KiB, 2.36 MB each way), byte-exact: PASS, 14.0 Mbit/s each way over Wi-Fi with the 16 KiB FIFO; 15.7 Mbit/s (4 x 38 messages) over the wired PC NIC with the 32 KiB FIFO |
| TCP iperf alone | iperf 2.2.2 `-c 192.169.1.199 -t 10` (PC wired NIC 192.169.1.178): 68.4 Mbit/s PC -> board; after the tuning (send buffer 24 x MSS, window 8 x MSS, word-wise netif copies, 32-bit checksum) 87.6 / 87.8 Mbit/s |
| iperf board -> PC modes (`rtlnet_lwiperf`, classifier image, `-t 10`, two runs each) | `-R` (reverse on the same connection): 29.3 Mbit/s, 29.3 Mbit/s; `-r` (tradeoff, board connects back to the PC's listener): PC -> board 68.6 Mbit/s, then board -> PC 27.3 / 27.1 Mbit/s; `-d` (dual): PC -> board 31.4 / 31.5 Mbit/s while board -> PC 15.6 / 15.6 Mbit/s; no firewall block of the connect-back. Before `rtlnet_lwiperf` (install lwiperf) `-r` and `-R` did not work. After the tuning: `-R` 82.7 / 82.7 Mbit/s; `-r` board -> PC 79.6 Mbit/s; `-d` PC -> board 21.3 Mbit/s while board -> PC 60.4 Mbit/s (sum 81.7). The earlier `-R` rate was the CPU copying the frame into the AXI BRAM byte by byte (307 us per frame), not the window |
| Together | TCP echo (2 connections x 76 messages) PASS, TCP iperf 51.6 Mbit/s, RTL UDP iperf `-u -b 20M` 20.9 Mbit/s, 0/17828 lost; `tcp_test.ps1`: TCP_TEST PASS 5/5. After the tuning: TCP iperf 70.8 / 70.8 Mbit/s with the UDP iperf (20.9 Mbit/s, 0/17833 and 0/17834 lost) |
| Board counters after the runs | DMA receive 165436 frames, no pbuf 0, errors 0; transmit 164660, timeouts 0; wrapper: CPU FIFO drops 4 of 165439 frames to the CPU; lwIP heap max 21668 of 32768, pbuf pool max 2 of 32 |
| CPU RX FIFO | 16 KiB: four echo connections overflowed it (24 drops, 0.4 s retransmission stalls); 32 KiB: 4 drops over the whole test, no stall in the echo latencies |

The TCP numbers are CPU bound: every received frame is copied from the AXI BRAM into a pool pbuf
(uncached 32-bit reads over AXI), lwIP checksums it in software, and every ACK or echo segment is copied back
into a DMA buffer; the 100 MHz MicroBlaze has no caches. CPU load was not instrumented.

### 6.5 Network build with the CPU-path classifier

Network build of commit 7fe67e42 (tree clean), 10-22-2026, Vivado 2025.2, `build.ps1 -Network`:
`CPU_CLASSIFIER_ENABLE` 1 (`u_protocol/g_cpu.g_classifier.u_cpu_classifier`, `AXIS_CLK_HZ` 100 MHz, defaults of the
core), firmware on the classifier driver.

| Item | Result |
|---|---|
| Synthesis / implementation | 0 critical warnings; `rtlnet_build: PASS`; bitstream build 1470 s (the regression ran on the same machine), firmware 83 s, merge 26 s |
| Timing (post-route) | WNS +0.119 ns, WHS +0.011 ns, WPWS +0.264 ns; 0 failing setup, hold and pulse-width endpoints (before the classifier: +0.221 / +0.018 / +0.264) |
| Intra-clock WNS | cpu_clk +0.119 (worst), clk125 +1.145, axis_clk +2.131, clk200 +2.614, proto_clk +5.110, clk125_90 +5.466, rgmii_rxc +2.779 ns |
| Utilization (post-route) | 19515 LUTs (14.59 %), 27339 FFs (10.22 %), 226.5 BRAM tiles (62.05 %), 5 DSP48; the classifier adds 3346 LUTs, 6156 FFs, 30 BRAM tiles (the out-of-context figures of its documentation: 3351 / 6217 / 30) |
| CDC constraints | before (commit a9e043e6) / after: sync 26 instances, 118 first stages / 28, 120; reset 8 / 32 / unchanged; gray 6 / 192 / unchanged; fifo 9 / 88 / unchanged; axil_cdc 3 instances, 200 constrained cells / 4, 279. New: `u_cpu_classifier/u_regs/u_axil_cdc` (79 cells) and its `u_req_sync`, `u_ack_sync`. `::rtlnet_cdc_expect` now `fifo 9 axil_cdc 4 gray 6`; 41 report_cdc waivers (was 32) |
| report_cdc | waived CDC-1 x159, CDC-6 x236, CDC-15 x237, all inside the crossing primitives; Info only otherwise; no unwaived Critical/Warning |
| Firmware | `firmware.elf` text 159348 B, data 2104 B, bss 151344 B; harness `menu.exe --demo` TEST PASS 292 checks |
| Merge / JTAG | updatemem 0 warnings; `program.ps1` programmed in 3.8 s, DONE high |

Board simulation (Active-HDL 11.1) with the classifier enabled: `tb_rtlnet_nexys_video_net` TEST PASS, 107 checks at
10, 100 and 1000 Mb/s: the classifier reads "CLSF" at 0x44A1_8000 and MODE drop-all; an unclaimed datagram is
committed to the CPU FIFO and dropped (classifier FRAMES 1, DROPPED 1, MODE_DROPPED 1, nothing at the CPU); after the
stand-in's `cls_config_bcast_storm` (the driver's register sequence, ID check included) a unicast datagram reaches the
CPU byte-exact; a burst of 8 broadcasts with a limit of 3 per 2 ms passes exactly 3 (byte-exact) and drops 5 (policer 0
SEEN 8 / PASSED 3 / DROPPED 5, classifier PASSED / DROPPED / POLICE_DROPPED, MAC table hits 8, wrapper CPU_RX_FRAMES);
perturbing the expected PASSED count gives TEST FAIL. Full regression `scripts/rtlnet_regression.ps1`: 69 passed,
0 failed.

Hardware (board at 192.169.1.199 by DHCP, PC wired NIC "Ethernet" 192.169.1.178):

| Check | Result |
|---|---|
| Start-up | `show classifier`: hardware MODE pass-all, STATUS 0x00000100, 16 + 16 entries, 2 rules, 4 policers, 64 bytes compared, delay line 31 beats, verdict latency 23 clocks (the build parameters of the classifier documentation) |
| `cli_test.ps1` | `CLI_TEST: PASS 27/27` |
| `net_test.ps1 -Nic Ethernet -Speed 100` | `NET_TEST: PASS 25/25` (ping 0/64/1472 x20 no loss, UDP echo client 200 datagrams, iperf UDP 90 Mb/s PC -> board 94.1 Mbit/s 0/40093 lost, board -> PC 94.4 Mbit/s 0/40126 lost, 10 Mb/s forced and restored) |
| `tcp_test.ps1` | `TCP_TEST: PASS 5/5` before `rtlnet_lwiperf` (echo 4 connections 9.6 Mbit/s, TCP iperf 68.6 Mbit/s PC -> board, together: echo PASS, iperf 51.5 Mbit/s, UDP 20.9 Mbit/s 0/17837 lost); with `rtlnet_lwiperf` `TCP_TEST: PASS 8/8` (also `-R` 29.3, `-r` 27.3 and `-d` 15.6 Mbit/s board -> PC; together: echo PASS, iperf 51.3 Mbit/s, UDP 20.9 Mbit/s 0/17835 lost); after the TCP throughput tuning `TCP_TEST: PASS 8/8` (echo 7.2 Mbit/s, PC -> board 87.8, `-R` 82.7, `-r` 79.6, `-d` 60.7 Mbit/s board -> PC; together: echo PASS, iperf 68.6 Mbit/s, UDP 20.9 Mbit/s 0/17820 lost), `CLI_TEST: PASS 27/27`, `NET_TEST: PASS 25/25` |
| `show phy` | LCR 0x0070, LACR 0x0010 (read back, ext page 0x2C), EEE: MMD 7.60 = 0x0000 (off); RX delay 0x8575 -> 0xAD75; 100 Mb/s full duplex, partner 10h/10f/100h/100f |
| Broadcast flood | see below |

Broadcast flood (`microblaze/firmware/test/bcast_flood.py --rate 400 --seconds 10 --bind 192.169.1.178`, 2000
datagrams to 192.169.1.255 and 2000 to 255.255.255.255, UDP port 9, 64 B), with `ping` of the board once a second
and `tcp_echo_client.py --conns 2` in a loop (20 runs of 76 messages, 589408 bytes each way) running at the same
time; counters cleared (`clear counters`) before, read after:

| Counter | Value |
|---|---|
| `show storm-control` | 10 frames per 100 ms: seen 4000, passed 1004, dropped 2996 (seen = passed + dropped; 10 per window x 100 windows = 1000, plus 4 from window boundaries); CPU FIFO drops 0 |
| `show classifier` | frames 15518, passed 12522, dropped 2996 (mode 0, policers 2996, overrun 0); MAC table hits 4000; policer 0 seen 4000 / passed 1004 / dropped 2996 |
| Wrapper RX | delivered 15532, to CPU 15518, claimed by a leaf 14, CPU FIFO drops 0; DMA receive 12522 frames = classifier PASSED, no pbuf 0, errors 0 |
| Ping during the flood | 14 sent, 14 received, 0 lost, < 1 ms |
| TCP echo during the flood | 20 consecutive runs PASS byte-exact, 16.8 Mbit/s typical (three runs at 8.8 .. 9.0 Mbit/s) |
| Classifier STATUS after the flood | 0x00010100: the sticky STALL_SEEN bit is set (the delay line met output back-pressure while the CPU path was loaded); no frame was lost to it (OVERRUN_DROPPED 0, CPU FIFO drops 0) |

Per policer window the board passes 10 broadcasts; unicast TCP and ICMP frames pass unchanged.

After the TCP throughput tuning (firmware rebuilt `-Werror` clean, same bitstream) a flood at 400 datagrams per second for 10 s with ping and `tcp_echo_client.py --conns 2` in a loop gave seen 3999, passed 1010, dropped 2989, ping 14/14, 20 of 20 echo runs PASS (17 at 26.7 to 27.1 Mbit/s), CPU FIFO drops 2; at 2000 per second for 12 s with a four-connection echo test and an iperf stream also running: passed 1210 of 23752, ping 12/12, echo PASS, iperf 78.7 Mbit/s, CPU FIFO drops 374 (the larger TCP window of 8 x MSS per connection exceeds the 32 KiB CPU FIFO when five connections run together; TCP retransmits).

After the rebase onto the lwiperf merge (firmware rebuilt `-Werror` clean, merged into the same bitstream, text 159.6 KB) the console test passed 27/27, `tcp_test.ps1` 5/5 (iperf `-R` now returns 29.3 Mbit/s board -> PC) and a second flood gave seen 4002, passed 1013, dropped 2989, ping 14/14, TCP echo PASS.

### 6.6 Network build with the checksum offload

Network build of commit eb6754b6 (tree clean), 10-22-2026, Vivado 2025.2, `build.ps1 -Network`:
`CPU_TCP_OFFLOAD_ENABLE` 1 (`u_protocol/g_cpu.g_offload.u_cpu_offload`, defaults of the core: `TX_BUF_KB` 8), window
0x44A1_9000, the AXI DMA with the MM2S data realignment engine (transmit buffers at any byte address).

| Item | Result |
|---|---|
| Timing (post-route) | WNS +0.221 ns, WHS +0.020 ns, WPWS +0.264 ns; 0 failing endpoints |
| Utilization (post-route) | 21771 LUTs (16.27 %), 31209 FFs (11.66 %), 229 BRAM tiles (62.74 %), 5 DSP48 (2256 LUTs, 3870 FFs and 2.5 BRAM tiles more than the build of section 6.5: the offload and the DMA realignment engine) |
| CDC constraints | fifo 10 (96 cells), axil_cdc 5 (331), gray 6 (192), sync 30 (122), reset 8 (32); `::rtlnet_cdc_expect` `fifo 10 axil_cdc 5 gray 6` |
| Firmware | default image (zero-copy receive on, transmit off; rebased onto the throughput tuning of microblaze documentation 9.10): text 167408 B, data 2108 B, bss 263336 B (36864 B of it the AXI BRAM section), 387 KiB of the 512 KiB LMB; images for the four zero-copy combinations (`rtlnet_nexys_video_rx<0|1>_tx<0|1>.bit`, `-Define RTLNET_NETIF_ZERO_COPY_RX/_TX`; AXI BRAM sections 12288 / 36864 / 77952 / 102528 B) |
| Host tests | `build.ps1 -Demo`: TEST PASS 364 checks (discovery of none / TX only / RX only / both builds, mismatch cases, the order of CTRL / STATUS / lwIP-flag writes, receive policy, CLI); `-LwipTest` LWIPERF_LOOPBACK PASS 69; `-NetifTest` NETIF_HOST PASS for the four zero-copy combinations (64 / 78 / 62 / 80 checks) |

Board simulation: `tb_rtlnet_nexys_video_net` TEST PASS, 141 checks at 10, 100 and 1000 Mb/s, including the offload
section through the CPU path: TCP and UDP frames from the DMA stand-in leave with correct IPv4 and L4 checksums
(CTRL tx bits), received frames carry a verified trailer (good, and a corrupted L4 checksum flagged), and with CTRL 0
both directions are bit-exact pass-through. Full regression `scripts/rtlnet_regression.ps1`: 76 passed, 0 failed.

Hardware (board 192.169.1.199 by DHCP, PC wired NIC 192.169.1.178, `iperf.exe -t 10`, mean of two runs, Mbit/s;
`offload_bench.ps1` once per firmware image, the CLI switches the offload at run time; the images differ in the
zero-copy options RX / TX; the measurements, the CPU profile and the analysis are in
`microblaze/documentation/rtlnet_cpu_microblaze.md` section 9.11):

| Zero-copy RX / TX | Offload | plain | `-R` | `-d` (PC -> board + board -> PC) | plain + UDP 20M (TCP / UDP) |
|---|---|---|---|---|---|
| off / off | off | 86.8 | 81.9 | 21.1 + 60.0 | 70.2 / 20.9 |
| off / off | on | 94.9 | 94.8 | 30.2 + 86.0 | 74.3 / 20.9 |
| **on / off (default)** | off | 89.6 | 81.4 | 21.2 + 60.0 | 72.0 / 20.9 |
| **on / off (default)** | **on** | **94.8** | **94.9** | **26.4 + 93.7** | **74.3 / 20.9** |
| off / on | off | 82.0 | 58.8 | 17.6 + 47.3 | 66.8 / 20.9 |
| off / on | on | 94.8 | 90.4 | 23.9 + 68.5 | 74.3 / 20.9 |
| on / on | off | 84.4 | 61.8 | 17.6 + 47.0 | 68.6 / 20.9 |
| on / on | on | 94.9 | 90.2 | 27.2 + 77.1 | 74.3 / 20.9 |

Default image (zero-copy receive on, transmit off, offload on at boot; AXI BRAM section 36864 of 131072 B):
`cli_test.ps1` `CLI_TEST: PASS 28/28`; `net_test.ps1 -Nic Ethernet -Speed 100` `NET_TEST: PASS 25/25`; `tcp_test.ps1`
`TCP_TEST: PASS 8/8` (PC -> board 94.8, `-R` 94.8, `-r` 94.8, `-d` 93.8 + 27.0 Mbit/s board -> PC + PC -> board,
together: TCP 72.2 Mbit/s, RTL UDP 20.9 Mbit/s 0/17825 lost); `offload_bench.ps1` `OFFLOAD_BENCH: PASS 19/19`
(hardware counters: tx ip and l4 patched 492467, rx verified 361494, no bad checksum, no policy drop, no `MISMATCH`
line); broadcast flood (400 per second, 10 s) with ping and a two-connection echo loop: storm limiter passed 1003
and dropped 2995 of 3998 (limit holds), ping 14/14, 8/8 echo runs PASS at 22.5 to 23.2 Mbit/s, CPU FIFO drops 35 of
9022 frames, `show offload` clean (verified 6027, bad 0). The offload turns the 100 Mb/s link into the limit
(94.9 Mbit/s TCP goodput in one direction, 120 Mbit/s sum with `-d`) and the receive zero-copy leaves the CPU 65 %
idle at that rate (35 % busy, against 81 % copying). Zero-copy transmit costs throughput (`-R` 90.4 Mbit/s) and is off.

### 6.7 Phase 0a: MicroBlaze V in place of the classic MicroBlaze (11-09-2026)

The processor of the block design is MicroBlaze V (`microblaze_riscv` 1.0: RV32IMC, Zicsr, Zba/Zbb/Zbs, performance
pipeline, no caches, debug through `mdm_riscv` 1.0, serial JTAG interface, without the JTAG UART); address map, interrupt numbering,
exported ports and the 100 MHz clock are unchanged, except that the unused MDM register window 0x4140_0000 no longer
exists (`microblaze/documentation/rtlnet_cpu_microblaze.md`). Network
build, Vivado 2026.1, `build.ps1 -Network` flow (bitstream, XSA, firmware, updatemem). Both images were measured on the
same board (JTAG, COM3) with the PC on its Wi-Fi adapter (192.168.68.84) and the board on the router at 1000 Mb/s by
DHCP (192.168.68.68); no wired PC adapter was connected, so the iperf rates carry Wi-Fi variation. The baseline is the
classic image built 11-08-2026 (commit 9a7a69dc). The MicroBlaze V column comes from the plain `build.ps1 -Network`
run (repository scripts unchanged, `RTLNET_BUILD: PASS`, CDC gate passed); transcripts are
`boards/nexys_video/build/phase0a_fix_*.txt`.

| Check | Classic MicroBlaze 11.0 | MicroBlaze V |
|---|---|---|
| Post-route WNS / WHS / WPWS | 0.064 / 0.022 / 0.264 ns | 0.221 / 0.025 / 0.264 ns |
| LUT / FF / BRAM tiles / DSP | 21727 / 31197 / 228.5 / 5 | 22762 / 31553 / 228.5 / 6 |
| Firmware text / data / bss (bytes) | 162356 / 2104 / 238280 | 112502 / 1128 / 263688 |
| `show interfaces` | `eth0 is up, 1000 Mb/s full duplex` | `eth0 is up, 1000 Mb/s full duplex` |
| `cli_test.ps1 -Port COM3` | `CLI_TEST: PASS 28/28` | `CLI_TEST: PASS 28/28` |
| `net_test.ps1 -Port COM3 -Nic Wi-Fi -Speed 1000` | `NET_TEST: PASS 25/25` | `NET_TEST: PASS 25/25` |
| UDP iperf `-u -b 900M`, PC to board / board to PC | 461 Mbit/s, 0/203645 lost / 944 Mbit/s, 2/401242 lost | 412 Mbit/s, 0/174955 lost / 944 Mbit/s, 0/401242 lost |
| `tcp_test.ps1 -Board 192.168.68.68` | `TCP_TEST: PASS 8/8` | `TCP_TEST: PASS 8/8` |
| TCP iperf PC to board (Mbit/s) | 67.5 | 68.5 |
| TCP iperf `-R` / `-r` / `-d` board to PC (Mbit/s) | 98.0 / 95.2 / 88.0 | 97.7 / 94.1 / 86.9 |
| Together: echo, TCP iperf, UDP iperf | echo PASS, 63.2, 20.9 Mbit/s 0/17836 lost | echo PASS, 63.4, 20.9 Mbit/s 0/17820 lost |

Board benches (`rtlnet_regression.ps1 -Match "nexys_video|microblaze"`): 6 passed, 0 failed, among them
`tb_rtlnet_nexys_video_net` at 10, 100 and 1000 Mb/s (`TEST PASS ... checks=141`) and
`tb_rtlnet_nexys_video_top` (`checks=74`); the benches use `rtlnet_microblaze_sim_stub`, never the processor.
Firmware host tests: `build.ps1 -Demo` `TEST PASS: menu_demo checks=364`; `-NetifTest` `NETIF_HOST: PASS` for all four
zero-copy combinations (checks 64, 110, 62, 112).

Points that differ from the classic image:

1. The first MicroBlaze V build stopped at the CDC gate of `build_bitstream.tcl` with `CDC-15 Warning x8` (exit 27, log
   `phase0a_mbv_build_bitstream_cdcfail.log.txt`): the JTAG UART FIFOs of `mdm_riscv`
   (`MDM_Core_I1/JTAG_CONTROL_I/Use_UART.TX_FIFO_I` and `RX_FIFO_I` to `tdo_reg`) cross between the BSCAN clock and
   `clk`. Nothing in the firmware uses the JTAG UART (the console is `axi_uartlite_0`), so the block design sets
   `mdm_0` `C_USE_UART` 0 and drops its AXI slave, its `axi_periph` master port and its address segment
   (0x4140_0000); `axi_periph` has 6 masters. The unmodified gate and waiver script now pass on the plain
   `build.ps1 -Network` build.
2. `write_mem_info` labels the MicroBlaze V processor `Big` in the MMI; updatemem places the ELF words identically for
   `Big` and `Little` (the two output bitstreams differ only in their header), and `merge_elf.ps1` accepts both.
3. The RISC-V start-up code clears memory from the start of `.bss` to `_end`, so the linker script keeps `_end` at
   the end of the LMB image and places `.axi_bram` after it; with `_end` behind the AXI BRAM section the start-up code clears about
   3 GB of address space and the image never prints.
4. MicroBlaze V halts when its first AXI read follows the reset within a few clocks (a hand-written 3-instruction probe
   hung; the same probe with a delay of about 20 clocks ran; the BSP start-up code reaches its first AXI access after many more clocks, so the firmware is not affected).
5. XSDB of Vitis 2026.1 names the MicroBlaze V debug module `RISC-V at USER2` with the child target `Hart #0`, not
   `MicroBlaze #0`. The hart is a second-level target behind the BSCAN-to-JTAG bridge of `mdm_riscv` and appears one to
   two seconds after `connect`; a plain `targets` right after `connect` lists only `BSCAN JTAG at USER2`, which looked
   like a missing processor. No hardware change is needed (`C_DEBUG_INTERFACE` stays serial, `C_JTAG_CHAIN` 2 = USER2).
   `targets -set -nocase -filter {name =~ "Hart*"} -timeout 15` waits for the hart. Proof on the programmed image:
   `connect`, that `targets` line, `targets` (lists `1 xc7a200t`, `2 BSCAN JTAG at USER2`, `3 RISC-V at USER2`,
   `4* Hart #0 (Running)`), `stop`, `rrd pc` (`pc: 00003bb0`), `rrd a0`, `rst -system -stop`, `dow firmware.elf` into the LMB,
   `con`; the console then prints the banner, `CPU path: DMA ok ... lwIP up` and the `rtlnet>` prompt, DHCP binds and
   the link comes up at 1000 Mb/s. The reset before `dow` is needed: a running image continued from a plain
   `stop`/`dow`/`con` sits in its trap handler on the stale peripheral state and prints nothing. The sequence is
   `boards/nexys_video/scripts/jtag_load_elf.tcl`, started by `jtag_load_elf.ps1 -Elf <elf> -Port COM3`
   (`JTAG_LOAD_ELF: PASS`).
6. The build log holds 393 warnings (baseline 391), 0 critical warnings; the `mdm_riscv` constraint file
   contributes `Vivado_Tcl 4-919` warnings (waivers on empty object lists).
7. The linker warning about one RWX segment is silenced with `-Wl,--no-warn-rwx-segments` (one LMB holds code and data).
   The `.bss` of 263688 bytes is the lwIP pools and buffers (`memp_memory_PBUF_POOL_base` 99 KB, `ram_heap` 64 KB,
   `g_parsed` 35 KB, `g_rx_buf` 32 KB): the same symbols and sizes as in the tracked classic ELF of commit 8794331
   (`.bss` 263364 bytes), so the move to MicroBlaze V adds 324 bytes of `.bss`, not 25 KB; the 238280 bytes of the
   baseline column belong to an earlier firmware configuration.
8. `build.ps1 -LwipTest` stops in the host compile of `test/lwiperf_loopback/lwiperf_loopback_test.c` line 101
   (`timespec_get`, `TIME_UTC` undeclared): the host gcc of the install is MinGW-w64 9.5.0 (msvcrt), whose C runtime has
   no C11 `timespec_get`. The test file and the host toolchain are unchanged by the port, so the failure does not come from it.

### 6.8 Phase 0 stage 1: DDR3 with MicroBlaze V caches (11-09-2026)

The network image gains the DDR3 path: `u_ddr` (`rtlnet_ddr`, MIG, 512 MiB, 128-bit AXI4 on `ui_clk`), `u_arb`
(`rtlnet_axi_arbiter`, one master) and the bridge `u_ddr_cdc` (`rtlnet_axi_cdc`, `cpu_clk` to `ui_clk`, `MAX_BURST_BEATS`
16, ID width 1). MicroBlaze V runs 8 KiB instruction and 8 KiB write-through data caches over `0x8000_0000..0x9FFF_FFFF`;
the block design's SmartConnect `sc_ddr` has one clock (`cpu_clk`) and exports the 128-bit `M_AXI_DDR`. Build
`build.ps1 -Network` (log `phase0_ddr_build_run6.log.txt`, transcript `phase0_ddr_build_run6.txt`, `RTLNET_BUILD: PASS`),
board measurements on the same setup as section 6.7 (JTAG, COM3, 1000 Mb/s, PC on Wi-Fi). The build reaches this result with Explore
placement and routing directives and a post-route `phys_opt_design` while setup slack is negative.

| Check | Phase 0a (MicroBlaze V, no DDR3) | Phase 0 stage 1 |
|---|---|---|
| Post-route WNS / WHS / WPWS | 0.221 / 0.025 / 0.264 ns | 0.221 / 0.051 / 0.000 ns |
| LUT / FF / BRAM tiles / DSP | 22762 / 31553 / 228.5 / 6 | 32353 / 41937 / 239.5 / 6 |
| Utilization (LUT / FF / BRAM / DSP) | 17.0 / 11.8 / 62.6 / 0.8 % | 24.18 / 15.67 / 65.62 / 0.81 % |
| Firmware text / data / bss (bytes) | 112502 / 1128 / 263688 | 118450 / 1128 / 267792 |
| `rtlnet_cdc` | PASS | PASS: fifo 15 (160 cells), axil_cdc 6 (382), gray 6 (192), sync 33, reset 9 |
| report_cdc | clean | no unwaived finding; waived by the CDC script: CDC-1 x159, CDC-6 x238, CDC-15 x237 |
| CLI_TEST | PASS 28/28 | PASS 33/33 |
| `show ddr` after calibration | none | `Calibration : done`, arbiter `errors 0`, illegal-burst flag clear |
| `ddr test` (16 MiB) | none | data bus, address bus and random fill PASS; write 28.39 MB/s, read 12.90 MB/s |
| `ddr test 64` | none | PASS; write 28.39 MB/s, read 12.90 MB/s |
| `show ddr` after both tests | none | AW bursts 16779338, AR bursts 16787808, errors 0, wait cycles 5, illegal-burst flag clear |
| NET_TEST (`-Nic Wi-Fi -Speed 1000`) | PASS 25/25 | PASS 25/25 |
| UDP iperf `-u -b 900M`, PC to board / board to PC | 412 Mbit/s, 0/174955 lost / 944 Mbit/s, 0/401242 lost | 360 Mbit/s, 0/165977 lost / 943 Mbit/s, 0/401242 lost |
| TCP_TEST | PASS 8/8 | PASS 8/8 |
| TCP iperf PC to board (Mbit/s) | 68.5 | 68.1 |
| TCP iperf `-R` / `-r` / `-d` board to PC (Mbit/s) | 97.7 / 94.1 / 86.9 | 98.0 / 96.3 / 88.9 |
| Together: echo, TCP iperf, UDP iperf | echo PASS, 63.4, 20.9 Mbit/s 0/17820 lost | echo PASS, 64.2, 21.0 Mbit/s 0/17827 lost |

The `ddr test` rates are the MicroBlaze V data cache path (32-bit stores written through, 4-beat line fills), not the
controller's bandwidth. The 12 PDRC-190 findings of the MIG temperature monitor, the LUTAR-1 of its reset logic and the XDCB-5 of its
constraint are waived per section 5 (each a required target; the build printed `required waiver LUTAR-1: 1 of 1`,
`PDRC-190: 12 of 12`, `XDCB-5: 1 of 1`). The first build with the bridge in front of the arbiter replaced the SmartConnect clock crossing
(which had produced 386 CDC-15 and a TIMING-11 inside `sc_ddr`) and cleared both. CDC-8 inside the MIG was cleared with
ASYNC_REG on the first two stages of each reset chain; with ASYNC_REG on every stage (12 and 15 cells) the build reported two PDRC-190
findings on the chains (`phase0_ddr_build_run5.log.txt`). The CPU-only build counts (`fifo 5 axil_cdc 1 gray 0`) were not built in this
run.

Board benches: `rtlnet_regression.ps1`, `RTLNET_REGRESSION` summary in `phase0_ddr_regression.txt`; `tb_rtlnet_nexys_video_top`
(`checks=124`) now writes and reads DDR3 through `u_ddr_cdc`, the arbiter and the memory model with the stub's
`ddr_write`/`ddr_read` tasks (single beat, partial strobe, 4-beat burst). Transcripts: `phase0_ddr_cli.txt`, `phase0_ddr_net.txt`,
`phase0_ddr_tcp.txt`, `phase0_ddr_program.txt`.

### 6.9 Phase 0 stage 2: JTAG development flow, DDR3 image and 32-bit program counter (11-09-2026)

Changes: `build.ps1 -Ddr` and `jtag_load_elf` (`microblaze/documentation/rtlnet_cpu_microblaze.md` section 9.12); the block design sets
`C_PC_WIDTH` 32; `build.ps1 -Tag <name>` writes a variant build into `build/<name>/` without touching the network image.

Finding: `C_PC_WIDTH` was 19 (propagated from the 512 KiB ILMB, `C_I_AXI` 0), so the first load of `firmware_ddr.elf` ran
the LMB release image (a jump to `0x8000_0000` wrapped to `0x0`; the banner had no DDR3 line). With 32 the DDR3 image runs.

Cost of the 32-bit program counter (same sources otherwise; stage 1 values from section 6.8):

| Build | LUT | FF | BRAM tiles | WNS / WHS / WPWS (ns) |
|---|---|---|---|---|
| Network, 19-bit PC (stage 1) | 32353 | 41937 | 239.5 | 0.221 / 0.051 / 0.000 |
| Network, 32-bit PC (`phase0_dev_net_build.txt`, 924 s) | 32521 (+168) | 42307 (+370) | 239.5 | 0.152 / 0.008 / 0.000 |
| CPU-only, 19-bit PC | 16015 | 16414 | 174 | 0.052 / 0.008 / 0.000 |
| CPU-only, 32-bit PC (`build.ps1 -Tag cpu`, `phase0_dev_cpu_build.txt`, 684 s) | 16158 (+143) | 16747 (+333) | 174 | 0.196 / 0.010 / 0.000 |

Both 32-bit builds print `RTLNET_BUILD: PASS` with 0 failing endpoints, utilization 24.31 % (network) and 11.97 % to 12.08 % (CPU-only), no unwaived
methodology finding. CDC gates: network `fifo 15 axil_cdc 6 gray 6`, CPU-only `fifo 5 axil_cdc 1 gray 0` (`rtlnet_cdc: PASS`, counts as expected). The
CPU-only build used `-Tag cpu`; `git status` shows the network files changed only by the network rebuild.

Board (JTAG, COM3, 1000 Mb/s, PC on Wi-Fi: `-Nic Wi-Fi -Speed 1000`, DHCP lease 192.168.68.68, mask 255.255.252.0, router 192.168.68.1):

| Step | Result | Log |
|---|---|---|
| `program.ps1` | PASS | `phase0_dev_program.txt` |
| `jtag_load_elf.ps1 -Elf firmware_ddr.elf` | `JTAG_LOAD_ELF: PASS`, banner "DDR3 image", download verified, calibrated 2 ms after the reset | `phase0_dev_load_ddr.txt` |
| DDR3 image, `cli_test.ps1` | FAIL 5/33: `ddr test` x3 refused by design; `show ddr` x2 report the illegal-burst flag SET (below); 28 other checks pass | `phase0_dev_cli_ddr.txt` |
| DDR3 image, `net_test.ps1` | PASS 25/25 | `phase0_dev_net_ddr.txt` |
| DDR3 image, `tcp_test.ps1 -Board 192.168.68.68` | FAIL 2/8: both TCP echo tests return zero bytes inside a payload (`echo differs at offset 989 (sent 0x6E, got 0x00)`); the four iperf runs and UDP pass | `phase0_dev_tcp_ddr.txt` |
| Release LMB ELF through the same script | `JTAG_LOAD_ELF: PASS`, banner "LMB image" | `phase0_dev_load_lmb.txt` |
| LMB image, `cli_test.ps1` | PASS 33/33 | `phase0_dev_cli_lmb.txt` |
| LMB image, `net_test.ps1` | PASS 25/25 | `phase0_dev_net_lmb.txt` |
| LMB image, `tcp_test.ps1` | PASS 8/8 (a first run failed the first echo connection with a connect timeout; the second run passed all 8) | `phase0_dev_tcp_lmb.txt` |
| `program.ps1`, then `cli_test.ps1` (release state) | PASS, PASS 33/33 | `phase0_dev_program_final.txt`, `phase0_dev_cli_final.txt` |

| Rate (Mbit/s) | DDR3 image | LMB image |
|---|---|---|
| UDP `-u` 900M, PC to board (0 lost) | 438 | 467 |
| UDP `-u -R`, board to PC (0 lost) | 944 | 943 |
| TCP iperf PC to board | 50.6 | 65.1 (59.2 in the first run) |
| TCP iperf `-R` / `-r` / `-d` board to PC | 45.5 / 41.3 / 34.2 | 96.7 / 94.3 / 86.4 |
| Together: TCP iperf / UDP iperf | 50.3 / 20.9 | 60.6 / 20.9 |

`rst -system` does not reset the MIG: a sentinel word written to DDR3 before the reset reads back unchanged after it and
CLK_STATUS bit 1 is already set (`phase0_dev_load_ddr.txt`). The DDR3 arbiter's registers survive too, so the script clears its status and counters.

Open finding in the DDR3 image (before the WRAP change below): the arbiter answers illegal bursts of master 0 (the CPU caches) with SLVERR while the image runs. The counter
stays 0 while the firmware idles, and grows with console activity: 12 errors per `show version`, repeatable, never when the code runs from
the LMB (`ddr test` then reports `errors 0`). The sticky flag sets, and zero bytes in the TCP echo payload fit write bursts that the arbiter
discards. A `debug read` of DDR3 words at line offsets 0, 4 and 0x14 returns the right data, so reads are not the cause. Candidates: the burst
type or size the CPU's write-through data cache or the SmartConnect emits for sub-word or unaligned stores (the `ddr test` uses word stores only,
and stage 1 tested sub-word stores only in simulation). The next step is a hardware probe or a bench of the SmartConnect plus arbiter with byte and
halfword stores; the release (LMB) flow is not affected.


#### Phase 0 stage 3: WRAP bursts and the illegal-burst capture (11-09-2026)

Changes: `rtlnet_axi_arbiter` gets `WRAP_MASK` (legal WRAP of 2, 4, 8, 16 beats at a size-aligned address, forwarded unchanged) and a sticky capture of the first
illegal burst (`CAP_INFO`, `CAP_ADDR`, `CAP_ADDR_HI`; `cores/rtlnet_axi_arbiter/documentation/rtlnet_axi_arbiter.md` sections 3.1, 4, 7); the board top sets
`WRAP_MASK` 1 for the CPU master; `show ddr` prints the wrap mask and the capture; `show version` prints an `Image` line (LMB or DDR3) and `cli_test.ps1` skips the three `ddr test` steps
in the DDR3 image (listed as skipped, not counted as passed). The arbiter bench has 4 new regression entries (11 configurations and 2 negative controls),
all existing entries pass. The generated MIG supports WRAP (arbiter document section 7.1).

Build (`build.ps1 -Network`, `phase0_wrap_build.txt`, 998 s bitstream): `rtlnet_cdc: PASS` (`fifo 15 axil_cdc 6 gray 6`), 0 failing endpoints, `RTLNET_BUILD: PASS`.

| Network build | LUT | FF | BRAM tiles | WNS / WHS / WPWS (ns) | Utilization |
|---|---|---|---|---|---|
| before (32-bit PC, `phase0_dev_net_build.txt`) | 32521 | 42307 | 239.5 | 0.152 / 0.008 / 0.000 | 24.31 % |
| after (`WRAP_MASK`, capture) | 32605 (+84) | 42358 (+51) | 239.5 | 0.071 / 0.049 / 0.000 | 24.37 % |

Board (lock held; JTAG, COM3, 1000 Mb/s, `-Nic Wi-Fi -Speed 1000`, 192.168.68.68):

| Step | Result | Log |
|---|---|---|
| `program.ps1` | PASS | `phase0_wrap_program.txt` |
| `jtag_load_elf.ps1 -Elf firmware_ddr.elf` | `JTAG_LOAD_ELF: PASS`, banner "DDR3 image" | `phase0_wrap_load_ddr.txt` |
| `show ddr` right after the load | `errors 0`, `First illegal : none captured` (the load script clears status and counters) | `phase0_wrap_show_ddr_1.txt` |
| DDR3 image, `cli_test.ps1` | `CLI_TEST: FAIL 2/30 (3 skipped: not counted as passed)`: the two `show ddr` steps see the illegal-burst flag set (`errors 3`) | `phase0_wrap_cli_ddr.txt` |
| DDR3 image, `net_test.ps1` | `NET_TEST: PASS 25/25` | `phase0_wrap_net_ddr.txt` |
| DDR3 image, `tcp_test.ps1` | `TCP_TEST: FAIL 2/8`: both TCP echo tests return a zero byte inside a payload (`size 5840: echo differs at offset 3073 (sent 0x79, got 0x00)`); four iperf runs and UDP pass | `phase0_wrap_tcp_ddr.txt` |
| DDR3 image, `show ddr` after the tests | `errors 96`, flag set, capture unchanged | `phase0_wrap_show_ddr_2.txt` |
| `program.ps1`, release image | PASS | `phase0_wrap_program_release.txt` |
| release image, `cli_test.ps1` | `CLI_TEST: PASS 33/33` | `phase0_wrap_cli_release.txt` |
| release image, `net_test.ps1` | `NET_TEST: PASS 25/25` | `phase0_wrap_net_release.txt` |
| release image, `tcp_test.ps1` | `TCP_TEST: PASS 8/8` | `phase0_wrap_tcp_release.txt` |

Found cause. (1) The 12 illegal bursts per `show version` were WRAP bursts: after the change `clear counters` and two `show version` leave `errors 0` and an empty capture
(`phase0_wrap_show_ddr_3.txt`). (2) Errors remain: the first capture after the `cli_test` run reads (printed by `show ddr`)

```
First illegal   : write (AW) master 0 addr 0x000000000001CFFD len 0 size 2 burst 1 (INCR) failed: 4KiB
```

that is `CAP_INFO` = valid, write, master 0, `AxSIZE` 2, `AxLEN` 0, INCR, failed rule 4 KiB only; `CAP_ADDR` 0x0001CFFD (offset in the 512 MiB window; CPU address 0x8001CFFD),
`CAP_ADDR_HI` 0. It is one 32-bit-size beat at a byte address ending in 01 at page offset 0xFFD (a sub-word store from the write-through data cache). The beat holds bytes 0xFFD..0xFFF, so it is a legal AXI
burst, but the arbiter evaluates `addr[11:0] + (len + 1) * bytes` from the unaligned address (0xFFD + 4 > 4096) and answers SLVERR, so the store is dropped. The rule has to use the
size-aligned start address (beat addresses after the first are aligned). The same error repeats for other sub-word stores at page offsets 0xFFD to 0xFFF of a size-2 burst; only the first illegal burst is captured, so the
other 95 of the 96 errors after `tcp_test` are not individually identified. The zero bytes in the TCP echo payload are consistent with dropped sub-word stores but are not proven to have this
cause. No further fix was made in this revision (the capture identified the rule; the change is a one-line size-aligned address in `burst_fail` and a bench case).

Rates (Mbit/s, this run):

| Rate (Mbit/s) | DDR3 image | LMB (release) image |
|---|---|---|
| UDP `-u` 900M, PC to board | 392.0 (15 of 173023 lost) | 408.0 (0 lost) |
| UDP `-u -R`, board to PC | 943.0 (13 of 401242 lost) | 944.0 (0 lost) |
| TCP iperf PC to board | 50.6 | 60.9 |
| TCP iperf `-R` / `-r` / `-d` board to PC | 42.6 / 38.1 / 32.2 | 90.9 / 84.6 / 69.6 |
| Together: TCP iperf / UDP iperf | 50.7 / 20.9 | 58.0 / 20.9 |

The UDP loss and the lower rates of the DDR3 image come with the dropped stores and the slower DDR3 code path; the lost datagrams are not attributed.

Regression: `scripts/rtlnet_regression.ps1` (`phase0_wrap_regression.txt`): `RTLNET_REGRESSION: 100 passed, 0 failed`.

#### Phase 0 close-out: unaligned INCR starts (11-09-2026)

Change: `rtlnet_axi_arbiter` `burst_fail()` measures the 4 KiB rule of an INCR burst from the start address rounded down to the burst's size (AXI: the first beat may start
unaligned, later beats are aligned), so a size-2 single beat at 0xFFD is legal. The bench memory model `rtlnet_tb_axi4_mem` had the same unaligned span in its 4 KiB check and now uses the
aligned start (its beat addresses and strobe merge already handled an unaligned first beat). The arbiter bench adds random unaligned INCR starts for every master and directed accepts
(size 2 len 0 at 0xFFD and 0xFFF, len 3 at 0xFF1, size 4 len 0 at 0xFF1) and rejects (size 2 len 1 at 0xFFD, size 4 len 1 at 0xFF1) with data and strobe checks; restoring the old span fails
the bench (62232 and 58967 fails). Arbiter synthesis: `rtlnet_synth_check: PASS rtlnet_axi_arbiter`, 0 critical warnings. Regression: `RTLNET_REGRESSION: 100 passed, 0 failed`
(`phase0_unaligned_regression.txt`).

Build (`build.ps1 -Network`, `phase0_unaligned_build.txt`): `rtlnet_cdc: PASS` (`fifo 15 axil_cdc 6 gray 6`), `RTLNET_BUILD: PASS`.

| Network build | LUT | FF | BRAM tiles | WNS / WHS / WPWS (ns) | Utilization |
|---|---|---|---|---|---|
| before (stage 3, `phase0_wrap_build.txt`) | 32605 | 42358 | 239.5 | 0.071 / 0.049 / 0.000 | 24.37 % |
| after (aligned-start 4 KiB rule) | 32600 (-5) | 42345 (-13) | 239.5 | 0.103 / 0.008 / 0.000 | 24.36 % |

Board (lock held; JTAG, COM3, 1000 Mb/s, `-Nic Wi-Fi -Speed 1000`, 192.168.68.68):

| Step | Result | Log |
|---|---|---|
| `program.ps1`, `build.ps1 -Ddr` firmware, `jtag_load_elf.ps1` | PASS, banner "DDR3 image" | `phase0_unaligned_program.txt`, `phase0_unaligned_fw_ddr.txt`, `phase0_unaligned_load_ddr.txt` |
| `enable`, `clear counters`, `show ddr` | `errors 0`, `First illegal : none captured` | `phase0_unaligned_show_ddr_3.txt` |
| DDR3 image, `cli_test.ps1` | `CLI_TEST: PASS 30/30 (3 skipped: not counted as passed)` | `phase0_unaligned_cli_ddr.txt` |
| DDR3 image, `net_test.ps1` | `NET_TEST: PASS 25/25` on the second run (the first run failed only `iperf -u -R` at 900 Mb/s, 40750 of 401242 lost; log `phase0_unaligned_net_ddr_run1_fail.txt`) | `phase0_unaligned_net_ddr.txt` |
| DDR3 image, `tcp_test.ps1` | `TCP_TEST: PASS 8/8`, both TCP echo tests pass (the zero bytes are gone) | `phase0_unaligned_tcp_ddr.txt` |
| DDR3 image, `show ddr` after the tests | arbiter `errors 0`, illegal-burst flag clear, `First illegal : none captured` | `phase0_unaligned_show_ddr_2.txt` |
| `program.ps1`, release image | PASS | `phase0_unaligned_program_release.txt` |
| release image, `cli_test.ps1` | `CLI_TEST: PASS 33/33` | `phase0_unaligned_cli_release.txt` |
| release image, `net_test.ps1` | `NET_TEST: PASS 25/25` | `phase0_unaligned_net_release.txt` |
| release image, `tcp_test.ps1` | `TCP_TEST: PASS 8/8` on the second run (the first run failed the first echo connection with a connect timeout, as in an earlier run after programming; log `phase0_unaligned_tcp_release_run1_fail.txt`) | `phase0_unaligned_tcp_release.txt` |

The board stays in the release (LMB) state.

| Rate (Mbit/s) | DDR3 image | LMB (release) image |
|---|---|---|
| UDP `-u` 900M, PC to board | 476 (0 lost) | 293 (0 lost) |
| UDP `-u -R`, board to PC | 944 (0 lost) | 944 (1 of 401242 lost) |
| TCP iperf PC to board | 49.4 | 65.1 |
| TCP iperf `-R` / `-r` / `-d` board to PC | 42.0 / 39.3 / 32.3 | 94.2 / 88.1 / 85.6 |
| Together: TCP iperf / UDP iperf | 45.2 / 20.9 | 59.0 / 20.9 |

The DDR3 image gives about 25 to 55 % lower TCP rates than the LMB image (code and data in DDR3 behind 8 KiB caches); the release firmware stays in the LMB. Phase 0 is complete: the DDR3-linked ELF loads over
JTAG, runs the console, `net_test` and `tcp_test` with 0 arbiter errors, and the release image passes all three tests.

### 6.10 Phase 1: color bars into the frame buffer (11-09-2026)

Change: three cores on `ui_clk` (`documentation/gige.md` sections 5 and 6): `u_csi2` (`rtlnet_csi2_rx`: register block, 75 % color bars at 720p30
or 1080p30, source switch; the camera stream input is tied off, valid 0), `u_s2mm` (`rtlnet_vdma_s2mm`: 2D write DMA, INCR bursts of at most 16 beats
that never cross 4 KiB) and `u_fb` (`rtlnet_framebuf`: 3 slots of 4 MiB at DDR3 offset 0x1000_0000, CPU address 0x9000_0000, the reader port tied off, the
firmware reads through the register window). `u_s2mm` is arbiter master 1 at fixed top priority (`HIGH_PRIO_MASK` 2'b10); `NUM_MASTERS` 2 with `NARROW_MASK`
and `WRAP_MASK` 2'b01, so the CPU caches stay master 0 and keep both. Register windows on the existing decoder (slaves 7 to 9: 0x44A0_5000, 0x44A0_6000, 0x44A0_7000), each core
crossing from `cpu_clk` through its own `rtlnet_axil_cdc`. Bench: the board bench reads the three windows' ID, CAPS and reset values and a rejected `VIDEO_MODE` write through the decoder and the
crossings, and the arbiter's two-master CAPS (`0x02081102`); the unmapped test address is now 0x44A0_8000.

CDC gate (`build_bitstream.tcl`): only `rtlnet_axil_cdc` grows, +1 per video core (`u_csi2`, `u_s2mm`, `u_fb`), so the expectation goes
`axil_cdc 6` to `9` (network) and `1` to `4` (CPU-only), with the reason in the script; `fifo` and `gray` are unchanged (the write DMA's beat FIFO is one clock
domain, no new packet FIFO or Gray crossing). The gate is not relaxed and nothing is waived. The `sync` class lists 6 more instances (the two toggle synchronizers of each added crossing).

First build (`phase1_build_run1_timingfail.txt`): timing gate failed, WNS -1.061 ns with 171 failing endpoints, all in `u_s2mm` (the AW address,
burst length and 4 KiB split computed in one clock). Fix: the next burst is computed in three registered steps (documentation `rtlnet_vdma_s2mm.md`); the benches pass unchanged.

Build (`build.ps1 -Network`, `phase1_build.txt`): `rtlnet_cdc: PASS` (`fifo 15 axil_cdc 9 gray 6`), `RTLNET_BUILD: PASS`.

| Network build | LUT | FF | BRAM tiles | WNS / WHS / WPWS (ns) | CDC classes (instances) |
|---|---|---|---|---|---|
| before (Phase 0 close-out, `phase0_final_build_info_before.txt`) | 32600 (24.36 %) | 42345 (15.82 %) | 239.5 (65.62 %) | 0.103 / 0.008 / 0.000 | fifo 15, sync 33, axil_cdc 6, gray 6, reset 9 |
| first Phase 1 build (timing failed) | | | | -1.061 / 0.050 / 0.000 | |
| after (u_csi2, u_s2mm, u_fb) | 34135 (25.51 %) | 44743 (16.72 %) | 241.5 (66.16 %) | 0.101 / 0.008 / 0.000 | fifo 15, sync 39, axil_cdc 9, gray 6, reset 9 |
| delta | +1535 | +2398 | +2.0 (the 2 KiB beat FIFO) | | axil_cdc +3, sync +6 |

CPU-only variant (`build.ps1 -Tag cpu`, `phase1_cpu_build.txt`, outputs in `build/cpu/`): `rtlnet_cdc: PASS` (`fifo 5 axil_cdc 4 gray 0`, the three video cores' crossings counted), `RTLNET_BUILD: PASS`, WNS 0.269 ns, WHS 0.007 ns, WPWS 0.000 ns, 17833 LUT (13.33 %), 19189 FF (7.17 %), 176 BRAM tiles (48.22 %), 4 DSP; not programmed (no firmware merge).

Firmware (`phase1_fw_build.txt`, release image, LMB): text 124,692, data 1,128, bss 268,816 bytes (385 KiB of the 512 KiB LMB). The host harness demo passes with the new commands
(`TEST PASS: menu_demo checks=412`).

Board (lock held; JTAG, COM3, 1000 Mb/s, `-Nic Wi-Fi -Speed 1000`, 192.168.68.68; release image):

| Step | Result | Log |
|---|---|---|
| `program.ps1` | PASS | `phase1_program.txt` |
| `phase1_gate.ps1` (no firmware writes before step b) | `PHASE1_GATE: PASS 19/19` | `phase1_gate.txt`, `phase1_gate_transcript.txt` |
| `show camera` after programming, no writes | 720p30, source pattern, 30.00 fps period 3,333,333; FRAME_COUNT 29.908 fps over 124 frames (4 s of the PC clock, tolerance 0.3) | `phase1_gate.txt` |
| `framebuffer crc` at 720p30 | board `0x6D3DF810` (1280x720, 1,843,200 bytes), C model `0x6D3DF810` | `phase1_gate.txt` |
| `camera mode 1080p30`, `framebuffer crc` twice | board `0x8ED9EC2B` and `0x8ED9EC2B` (frames 853 and 878, 4,147,200 bytes), C model `0x8ED9EC2B` | `phase1_gate.txt` |
| `show ddr` | arbiter 2 masters, high-priority mask 0x02; master 0 and master 1 `errors 0`, illegal-burst flag clear | `phase1_gate.txt`, `phase1_final_state.txt` |
| `show framebuffer` | published above 0, dropped 0, bad 0, firmware holds none, reference counts 0 | `phase1_gate.txt`, `phase1_final_state.txt` |
| `camera rate 15`, `camera rate 30`, `camera source`, bad inputs | 15.027 fps measured against 15.000 from the period; bad mode, rate 0 and rate 31 rejected, nothing changed | `phase1_gate.txt` |
| `cli_test.ps1` | `CLI_TEST: PASS 47/47` (the 30 earlier steps with the 2-master `show ddr`, `ddr test` 16 and 64 MiB with the video DMA running, and 14 video steps) | `phase1_cli_test.txt` |
| `net_test.ps1` | `NET_TEST: PASS 25/25` (UDP 900 Mbit/s PC to board 436 Mbit/s 0 lost, board to PC 942 Mbit/s 574 of 401242 lost) | `phase1_net_test.txt` |
| `tcp_test.ps1` | `TCP_TEST: PASS 8/8` (TCP iperf PC to board 68.9 Mbit/s, `-R` 96.8, `-r` 87.7, `-d` 87.3; together 64.6 TCP and 20.9 UDP) | `phase1_tcp_test.txt` |
| `show ddr`, `show camera`, `show framebuffer`, `framebuffer crc` after all tests | master 0 and master 1 `errors 0`, `First illegal : none captured`; 8,250 frames published, dropped 0, bad 0; CRC `0x6D3DF810` | `phase1_final_state.txt` |

Observation: `STATUS.OVERRUN` of `rtlnet_csi2_rx` was set at the first `show camera` after programming (the first frame waits for the DDR3 calibration, so
a frame tick found it still running); cleared by writing 1 it stayed clear over 20 s idle, `ddr test 64`, `framebuffer crc` and two mode changes
(`phase1_overrun_probe.txt`). The flag is startup-only and does not count a lost or bad frame.

### 6.11 Phase 2b-3: H.264 streaming on one 90 MHz system clock (11-09-2026, status: bitstream gate open)

Change: `u_h264` (`rtlnet_h264_top`, two engines, decoder slave 10, 0x44A0_8000) as arbiter masters 2 and 3 (`NUM_MASTERS` 4, `ARB_ID_W` 2, memory-side ID 4 bits),
and one system clock: the MIG runs at a 2778 ps memory clock (360 MHz, 4:1), so `ui_clk` = 1440 / 16 = 90.000 MHz. The MIG needs a 9723 ps input
period (the wizard turns a 100 MHz input into 102.848 MHz), which a second MMCM `u_mmcm2` makes exactly: 100 MHz x 36 / 5 / 7 = 102.857143 MHz (VCO 720 MHz); `ui_clk` is then exactly 90.000 MHz (0 ppm
against the oscillator). `cpu_clk` is `ui_clk` (one net); the CPU reset is `ddr_resetn`, released after the MIG PLL locks and before the DDR3 calibration completes
(the firmware waits for `CLK_STATUS.DDR_CALIB`: `venc_start`, `ddr test`, `show ddr` check it). `u_ddr_cdc` and the encoder bridges do not exist; the register windows of the
arbiter, csi2, s2mm, framebuf and h264 use `rtlnet_axil_cdc` with `SYNC` 1 (pass-through). clk125, clk125_90, clk200, axis_clk and proto_clk are unchanged.
Pattern timing at 90 MHz: `FRAME_PERIOD` 3,000,000 (30.000 fps), line periods 4,000 (720p) and 2,666 (1080p), minimums 3,000,000 and 2,999,250; the PTS step is `FRAME_PERIOD / 1000` = 3000.

Memory map (DDR3 offsets): frame buffer 0x1000_0000 (3 slots, N = 3: the firmware is the only reader, one take per picture for both engines),
rebuilt picture 0x1100_0000 / 0x1130_0000 / 0x1138_0000 (phase 2b-3; tiled since 2b-4, section 6.12), compressed rings 0x1200_0000 (8 MiB, 4 MiB per engine), index rings 0x1300_0000.

CDC gate (`build_bitstream.tcl`): network `fifo 15 axil_cdc 9 gray 6` before (Phase 1) and `fifo 10 axil_cdc 5 gray 6` now: the five FIFOs of `u_ddr_cdc` are gone (the CPU
shares the arbiter clock) and the four register crossings of the arbiter, csi2, s2mm and framebuf are SYNC pass-throughs; the encoder adds none; the MAC, protocol, echo, classifier
and offload crossings stay. CPU-only build: `fifo 5 axil_cdc 4` before, 0 and 0 now (it lists only `sync` and `reset` as required). The script gained the
packet-FIFO RAM data path (`set_max_delay -datapath_only`, destination period) because equal 100 MHz periods had hidden its absence, and accepts the `g_cdc` prefix of the cells of `rtlnet_axil_cdc`.

Clock interaction (post-synthesis checkpoint, `report_clock_interaction`): before the CDC constraints `ui_clk` (clk_pll_i) against axis_clk, proto_clk, clk200 and clk125/125_90 was
"Timed (unsafe)" (no common phase, hold up to -2.09 ns); after them every pair with axis_clk, proto_clk, clk125 and rgmii_rxc is "Max Delay Datapath Only" or "False Path" (reset synchronizers),
the pairs inside the MIG and the JTAG (MDM) groups are unchanged. Remaining: clk200 -> ui_clk, "Partial False Path (unsafe)", 12 of 13 endpoints: the MIG temperature monitor (see open point).

Bench (Active-HDL, `tb_rtlnet_nexys_video_top`, `+VIDEO_PATH`): bars into the frame buffer, firmware take, a QCIF-sized picture (11 x 9 macroblocks, 2 engines, 2 slices) from the top-left of the 720p frame at QP 28, stream head,
index rings, rebuilt luma PSNR against the source (floor 30 dB) and the arbiter counters: PASS (169,682 checks). `rtlnet_ddr_sim` has its own 90 MHz `ui_clk`.

Build (`build.ps1 -Network -SkipFirmware -Tag s90b`): WNS +0.221 ns, WHS +0.051 ns, WPWS +0.131 ns, 0 failing endpoints; 71,482 LUT (53.4 %), 68,114 FF, 257.5 RAMB tiles (70.6 %), 80 DSP.
Per-region setup slack (post-route checkpoint): CPU 0.550, arbiter 0.307, H.264 0.459, MIG 0.604, frame buffer 0.854, video DMA 1.388, csi2 1.619 ns.
The history before the single clock: the first 100 MHz builds failed (CPU region -0.63 ns, arbiter -0.57, encoder -0.56; after pipelining the butterfly of `rtlnet_h264_dcq_luma`, the mode decision of `rtlnet_h264_ipred` and
the arbiter's event inputs: CPU -0.42, arbiter -0.06, encoder -0.07; placer directives EarlyBlockPlacement -0.47 and WLDrivenBlockPlacement -0.36); a dual 90 MHz plan with separate `cpu_clk`/`enc_clk` failed at -4.5 ns because the 90/100 MHz crossings were timed as related clocks.

Open point (blocks the bitstream): `report_cdc` raises one CDC-6 Warning, exit 27: the AMD MIG temperature monitor (`u_tempmon`, 12-bit `temperature_reg` in clk200 into `device_temp_sync_r1_reg` in the controller clock). It was
"safely timed" while ui_clk and clk200 were both multiples of 100 MHz; with ui_clk fed from 102.857 MHz the clocks have no common phase. The IP's own XDC bounds it (`set_max_delay 20`). Options (decision needed, none applied): a narrow CDC-6 waiver for those
registers; the MIG option `XADC_En` Disabled (no temperature compensation, the input tied to 0); or ref_clk (clk200) from `u_mmcm2` at 198.62 MHz (VCO 720 / 3.625) so that the clocks are related.

Resolution of the open point (11-10-2026): a narrow CDC-6 waiver on the 12 `device_temp_sync_r1_reg` D pins plus `set_max_delay -datapath_only` from clk200 to those pins (bounded by one `ui_clk` period; removes TIMING-51; the objects are named by full path and clock pin so TIMING-28 and XDCB-5 do not fire). Checked on the s90b checkpoint: TIMING-51 0 findings, slack +4.24 ns, report_cdc Info only. A second DRC finding (AVAL-139, MIG extra-clock MMCM CLKOUT0 `DIVIDE_F` 3.595) is removed with `UIExtraClocks` 0 in `rtlnet_ddr_mig.prj` (`ui_clk` unchanged, CLKFBOUT); the generated MIG has CLKIN_PERIOD 9723, CLKFBOUT_MULT 14, CLKOUT3_DIVIDE 16, MMCM_MULT_F 8, tCK 2778, UI_EXTRA_CLOCKS FALSE.

Final build (`build.ps1 -Network`, `RTLNET_BUILD: PASS`, log `build/phase2b3_build_final5.txt`): WNS +0.221 ns, WHS +0.007 ns, WPWS +0.131 ns, 0 failing endpoints; 71,468 LUT (53.41 %), 68,114 FF, 257.5 RAMB tiles (70.55 %, 222 RAMB36 + 71 RAMB18), 80 DSP; CDC `fifo 10 axil_cdc 5 gray 6` as expected, CDC-6 waiver on 12 pins printed. Firmware (release, LMB): text 136,064, data 1,128, bss 282,312 bytes; `XPAR_CPU_CORE_CLOCK_FREQ_HZ` 90000000; merged into the bitstream by updatemem. The firmware PTS step was computed for 100 MHz (step 2700) and is now `FRAME_PERIOD x 90000 / cpu_clk_hz` (3000).

Board results (release image, 11-10-2026): `phase1_gate` PASS 19/19 (the first run after programming failed only b2, 10.378 fps, a measurement taken right after the load; the rerun gave 29.978 fps; CRC equal to the C model at 720p30 and 1080p30). `cli_test` PASS 55/55. `show ddr`: errors 0 on all masters; frame buffer drops 0.
`stream_test`, 60 s each, QP 28:
* 720p30: PASS on every check: 1802 pictures, 0 dropped, 0 continuity errors, 0 PTS gaps (step 3000), ffprobe h264 Constrained Baseline 1280x720 30.00 fps, PSNR minimum 51.14 dB (floor 30), bit rate 1037 kb/s, TS-mux CPU load 3.5 % (3.6 % with picture handling), 0 UDP drops. The VLC snapshot on `udp://@:5004` shows the eight color bars, equal to the decoded PNG (`phase2b3_decoded_720p30.png`).
* 1080p30: FAIL. 1344 pictures sent, 459 dropped (frame numbers skipped, 25 %), 22.4 pictures per second, PTS steps of 6000 where a picture is dropped; the decoded pictures are correct (PSNR minimum 51.09 dB), bit rate 1621 kb/s, TS-mux load 5.6 %, no continuity errors. Cause: `show encoder` reports 928 to 929 clocks per macroblock per engine against the 735 budget (720p: 859 and 880, which fit its 1,800 macroblock budget of 1,666 clocks per macroblock). Busy cycles show the write path (`recon_wr`: 32 single-beat writes per macroblock) at 3.4 to 3.6 million of 3.8 million picture cycles, against about 373 per macroblock in simulation. Open.
* net_test and tcp_test could not run: the PC NIC `Ethernet` (the direct link, board 192.169.1.199) is Disconnected; the stream used the board's DHCP lease on the LAN. The 100 MHz TCP figures (68.9 and 96.8 Mbit/s) were not re-measured.

### 6.12 Phase 2b-4: burst-only DDR3 access (11-10-2026)

Changes: tiled rebuilt picture with burst writes, strip input reads, 128-byte index records (`rtlnet_h264_enc.md` section 14), 64-byte cache lines and a write-back data cache
(`rtlnet_cpu_microblaze.md` section 11). Memory map: rebuilt picture A luma 0x1100_0000 and chroma 0x1120_0000 (256 B and 128 B tiles per macroblock), picture B reserved at
0x1140_0000 / 0x1160_0000, rings 0x1200_0000, index records 0x1300_0000.

Build (`build.ps1 -Network`, `RTLNET_BUILD: PASS`, log `build/phase2b4_build.txt`): WNS +0.002 ns, WHS +0.050 ns, WPWS +0.131 ns; 71,413 LUT (53.37 %), 69,004 FF, 259.5 RAMB tiles (71.10 %, was 257.5), 80 DSP;
CDC `fifo 10 axil_cdc 5 gray 6` unchanged; waivers as before; timing, CDC and methodology gates unchanged. Firmware: rebuilt on the new XSA and merged (updatemem 0 warnings).
Out-of-context encoder: WNS +1.455 ns, 38,995 LUT (-494), 25,759 FF (+382), 22 RAMB36 (+4), 2 RAMB18, 74 DSP.

Board (release image, QP 28): `phase1_gate` PASS 19/19, `cli_test` PASS 55/55, `stream_test` 60 s per mode PASS 14/14: 720p30 1805 pictures, 0 dropped, 0 continuity errors, 0 PTS gaps, PSNR minimum 51.14 dB, 1037 kb/s,
3.3 % TS-mux load, 423 and 425 clocks per macroblock; 1080p30 1802 pictures, 0 dropped (was 459 dropped), 0 continuity errors, 0 PTS gaps, PSNR minimum 51.09 dB, 2210 kb/s, 7.0 % load,
435 clocks per macroblock on both engines (was 928; budget 735). `show ddr`: errors 0 on all four masters, no illegal burst captured. Arbiter counters after the 1080p30 run:
engine 0 AW 14,837,273 bursts / 178,131,158 beats (12.0 per burst), AR 29,604,480 / 236,835,840 (8.0 per burst); engine 1 the same; video DMA 16.0 beats per burst.
CPU master 0: writes 4.0 beats per burst (`ddr test`), reads 1 beat per burst (open point in `rtlnet_cpu_microblaze.md` section 11).
`ddr test 16`: PASS, write 24.28 MB/s, read 19.58 MB/s. `net_test` and `tcp_test` could not run meaningfully: the PC NIC `Ethernet` (direct link) is Disconnected (BLOCKED, not counted as a failure of this work).
Transcripts: `build/phase2b3_stream_transcript.txt`, `build/phase2b4_ddr_test.txt`.

Wide cache bus (11-10-2026, `rtlnet_cpu_microblaze.md` section 11.1; 512-bit cache buses, 32 KiB caches, CPU AXI BRAM 64 KiB; build at 1e1ba48 plus this change, `build/phase2b5_build.txt`): WNS +0.169 ns, WHS +0.008 ns, WPWS +0.131 ns; 75,041 LUT (56.08 %), 74,024 FF, 270.5 RAMB tiles (74.11 %), 80 DSP; CDC `fifo 10 axil_cdc 5 gray 6` unchanged.
Board (release image, QP 28): `phase1_gate` PASS 19/19, `cli_test` PASS 55/55, `ddr test 16` PASS and `show ddr` master 0 AR 264,698 bursts / 1,058,792 beats = 4.0 per burst (was 1.0), AW 4.0 beats per burst, errors 0 (`build/phase2b5_ddr_test.txt`).
`stream_test` 60 s per mode PASS 15/15 (`build/phase2b5_stream_test.txt`): 720p30 1804 pictures, 0 dropped, 0 continuity errors, 0 PTS gaps, PSNR minimum 51.14 dB, 1037 kb/s, TS-mux load 3.2 % (was 3.3 %), 423 and 425 clocks per macroblock;
1080p30 1802 pictures, 0 dropped, 0 continuity errors, 0 PTS gaps, PSNR minimum 51.08 dB, 3143 kb/s (was 2210), TS-mux load 9.8 % (was 7.0 %), 435 and 436 clocks per macroblock.
`net_test` and `tcp_test` skipped: the direct PC NIC `Ethernet` is Disconnected.

## 7. Network integration (done 10-22-2026) and what remains

Integrated: `u_mac`, `u_mdio`, `u_protocol` (every leaf, the CPU network path and its classifier), `u_echo` under
`RTLNET_WITH_NETWORK`, the RGMII constraints, the CDC classes and counts, every core driver in the firmware (CLI and
network manager), the network board bench, and the hardware bring-up and host tests of sections 6.1, 6.4 and 6.5.

Open:

1. 1000 Mb/s on hardware needs a gigabit partner (simulated and constrained; the router is 10/100).
2. RX IDELAY tap sweep on hardware (the MAC documentation's procedure); the build meets the 1000 Mb/s RGMII budget with
   tap 12 (balanced +0.22 / +0.24 ns).
3. The `ev_*` pulse outputs of the MAC, the protocol wrapper and the classifier (`ev_pass`, `ev_drop`) are unconnected
   (LED or interrupt use).
4. Interrupts (PHY INTB through `rtlnet_mdio` irq[0], DMA) are wired but the firmware polls.
5. The CPU-path classifier is configured as a whole by the firmware (`hw_sync`): a CLI change drops CPU-bound frames
   for about 100 us. The 0x44A2_0000 main-ingress classifier window stays a stub.
6. The LED behaviour of the RTL8211E (LINK steady, ACT blink) is configured and read back but was not observed.
7. The classifier STALL_SEEN flag under load (section 6.5) is not analysed beyond the absence of any drop.

## 8. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version: CPU-only board top, build flow, bring-up |
| 10-22-2026 | Network integration: RGMII XDC, CDC counts and waivers, network board bench, firmware network manager and driver-backed CLI, hardware results at 100 and 10 Mb/s |
| 10-22-2026 | `microblaze/` folder; CPU core with AXI DMA, AXI BRAM, 512 KiB LMB; XSA export; BSP-based firmware with lwIP; CPU-only hardware checkpoint (section 6.3) |
| 10-22-2026 | Checksum offload (`rtlnet_tcp_offload`) enabled in the network build (`CPU_TCP_OFFLOAD_ENABLE` 1, window 0x44A1_9000), CDC expectation `fifo 10 axil_cdc 5 gray 6`, MM2S data realignment engine in the block design, firmware zero-copy options, `show offload` step in `cli_test.ps1`, `offload_bench.ps1`; build and hardware results of section 6.6 (default: zero-copy receive on, transmit off) |
| 10-22-2026 | CPU-path classifier enabled in the network build (`CPU_CLASSIFIER_ENABLE` 1), CDC expectation `axil_cdc 4`, firmware on the classifier driver, bench checks for drop-all and broadcast limiting, hardware results of section 6.5; open items refreshed |
| 11-09-2026 | Phase 0a: MicroBlaze V replaces the classic MicroBlaze in the block design; hardware results of section 6.7 |
| 11-09-2026 | Phase 0a follow-up: JTAG UART removed (CDC gate passes unmodified), JTAG load of an ELF into MicroBlaze V (`jtag_load_elf.ps1`), new measurements in section 6.7 |
| 11-09-2026 | Phase 0 stage 1: DDR3 (`rtlnet_ddr`, `rtlnet_axi_arbiter`, bridge `u_ddr_cdc`), MicroBlaze V caches; build gates (MIG ASYNC_REG, three required MIG waivers, fifo 15 / CPU-only 5); results in section 6.8 |
| 11-09-2026 | Phase 0 stage 3: arbiter `WRAP_MASK` and illegal-burst capture, board top `WRAP_MASK` 1, `show ddr` capture, machine-wide board lock (section 5.3), `cli_test` skips `ddr test` in the DDR3 image; results in section 6.9 |
| 11-09-2026 | Phase 0 stage 2: `C_PC_WIDTH` 32, `build.ps1 -Tag` variant builds, `jtag_load_elf` with calibration wait, download check and `-Image`, DDR3 image (`build.ps1 -Ddr`); CPU-only counts `fifo 5 axil_cdc 1 gray 0` built and passing; results and the open arbiter finding in section 6.9 |
| 11-09-2026 | Phase 1 (section 6.10): video cores `u_csi2`, `u_s2mm`, `u_fb` on decoder slaves 7 to 9, arbiter with two masters, CDC expectation `axil_cdc 9` (network) and `4` (CPU-only), firmware video commands and the Phase 1 gate |
| 11-10-2026 | Wide cache bus (512-bit cache buses, 32 KiB caches, AXI BRAM 64 KiB): build and board results in section 6.12 |
