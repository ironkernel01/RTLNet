# Nexys Video board — RTLNet board top, build and bring-up

| Item | Value |
|---|---|
| Board | Digilent Nexys Video, XC7A200T-1SBG484C, Realtek RTL8211E-VL |
| Document revision | 10-22-2026 |
| Top | `boards/nexys_video/hdl/rtlnet_nexys_video_top.sv` (`rtlnet_nexys_video_top`) |
| Builds | CPU-only (default, built and on hardware); network (`RTLNET_WITH_NETWORK`, written, elaborated against port stubs, not built) |
| Tools | Vivado 2025.2, MicroBlaze GCC 13.3, Active-HDL 11.1 |

## 1. Files

| File | Content |
|---|---|
| `hdl/rtlnet_nexys_video_top.sv` | board top: pins, MMCM + BUFGs, reset tree, CPU core, decoder, system registers, stubs, MDIO IOBUF, PHY power-on reset, network instances under `RTLNET_WITH_NETWORK` |
| `hdl/rtlnet_nexys_video_sysregs.sv` | system registers (window SYS) |
| `hdl/rtlnet_nexys_video_clk_beacon.sv` | divide-by-32 beacon per clock for the clock monitor |
| `hdl/rtlnet_nexys_video.f`, `hdl/rtlnet_nexys_video_network.f` | filelists (CPU-only; network cores) |
| `constraints/rtlnet_nexys_video.xdc` | pins, I/O standards, `sys_clk` 10 ns, asynchronous pin false paths, configuration |
| `constraints/rtlnet_nexys_video_cpu_only.xdc` | CPU-only build: RGMII receive pins as asynchronous levels |
| `scripts/build_bitstream.tcl` | non-project build with gates (section 5) |
| `scripts/build.ps1` | firmware + bitstream + merge (+ `-Program`, `-Test`) |
| `scripts/merge_elf.ps1` | updatemem: firmware ELF into the LMB BRAM |
| `scripts/program.ps1`, `scripts/program.tcl` | JTAG programming (hw_server, `program_hw_devices`) |
| `scripts/cli_test.ps1` | console test over the USB-UART (COM4) |
| `testbench/tb_rtlnet_nexys_video_top.sv` (+ `.f`, `regression.txt`) | board bench with the CPU BFM |
| `../../scripts/rtlnet_constrain_cdc.tcl` | crossing constraints by cell name |

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

Methodology waivers (printed on every run): LUTAR-1 on the reset AND (every driven pin must be a
`u_rst_*/pipe_reg[*]/CLR`), LUTAR-1 inside the vendor MDM, TIMING-9 (vendor MDM BSCAN clock groups)
only while report_cdc has no Critical/Warning finding.

CDC constraints (`scripts/rtlnet_constrain_cdc.tcl`, sourced after synthesis): classes sync, reset,
gray, fifo, axil_cdc by cell name; per-class counts printed; `::rtlnet_cdc_required` is
`{sync reset}` for the CPU-only build and all five for the network build (zero matches of a required
class is an error).

## 6. Results

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
| Host harness | `menu.exe --demo` TEST PASS 202 checks; `--inject-failure` TEST FAIL |

Also exercised by hand on the board: `show ?`, `sh?`, the ambiguous `show i`, `no ?` in config-if,
Ctrl-C, Ctrl-Z, up-arrow recall, `!!`, backspace, `reload` (banner again, firmware uptime restarted,
hardware UPTIME_MS continuing). The PHY leaves reset (rst_n 1) and its receive clock toggles.

## 7. Network integration checklist

1. Filelists `cores/rtlnet_eth_mac/hdl/rtlnet_eth_mac.f`, `cores/rtlnet_mdio/hdl/rtlnet_mdio.f`,
   `cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol.f`, `cores/rtlnet_udp_echo/hdl/rtlnet_udp_echo.f`
   (listed in `hdl/rtlnet_nexys_video_network.f`); then `build.ps1 -Network`.
2. Instances already in the top under `RTLNET_WITH_NETWORK` (ports per section 15, elaborated against
   port stubs on 10-22-2026): `u_mac` (`rtlnet_eth_mac`, RGMII pins, decoder slave 1),
   `u_mdio` (`rtlnet_mdio`, MDC, MDIO through `u_mdio_iobuf`, `eth_rst_b`, `eth_int_b`, irq[0], slave 2),
   `u_protocol` (`rtlnet_eth_protocol`, MAC RX/TX streams, app_clk = proto_clk, slave 4, 16-bit window
   address), `u_echo` (`rtlnet_udp_echo` on the socket payload streams, slave 3). The classifier window
   stays a stub. NET_STATUS carries the MAC/protocol status levels (synchronized in the system
   registers); the `ev_*` pulses are unconnected.
3. Constraints to add to `constraints/rtlnet_nexys_video.xdc` (network build only, e.g. a
   `rtlnet_nexys_video_rgmii.xdc` read when `network 1`): `create_clock -period 8.000` on `eth_rxck`
   (125 MHz; 10/100 rates are slower and covered); `set_input_delay -clock` rxck (min/max, both edges)
   on `eth_rxd[*]`/`eth_rxctl` from the RTL8211E RGMII timing with the PHY RX delay on; a
   `create_generated_clock` on `eth_txck` from the MAC's TXC ODDR under `u_mac/u_rgmii_io` (source
   clk125_90) and `set_output_delay` on `eth_txd[*]`/`eth_txctl` against it; the IDELAYCTRL /
   IODELAY group of the pin layer if the MAC does not set it; no clock groups (crossings are the
   MAC's packet FIFOs and `rtlnet_axil_cdc`, constrained by the CDC script).
4. The CDC script then requires gray, fifo and axil_cdc matches; check the printed counts against the
   number of FIFOs (`u_*_fifo`) and register crossings in the cores.
5. Firmware: the same image runs; the core probes report "present" once the IDs read back, and each
   core's driver (`cores/<core>/driver`) is wired into `cli/cli_commands.c` (show/config callbacks)
   and the main loop (link monitor, MAC speed follow, DHCP on link-up).

## 8. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version: CPU-only board top, build flow, bring-up |
