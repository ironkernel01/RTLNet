# RTLNet on the Digilent Nexys Video

This folder is the board design for the Digilent Nexys Video (Artix-7 XC7A200T-1SBG484C, Realtek RTL8211E RGMII PHY,
512 MiB DDR3L). The board-independent cores are under `cores/`; this folder is the only
board design today.

The design is the RTLNet Ethernet stack, the MicroBlaze V network path running lwIP, the DDR3 path, the test-pattern
video source and the two-engine H.264 Constrained Baseline encoder, on one 90 MHz clock. The board guide with the design,
the measurements and the build log is `documentation/rtlnet_nexys_video.md`.

## IronForge Linux integration

IronForge uses the RTLNet MAC and MDIO cores in its Nexys Video FPGA design.
Its MicroBlaze U-Boot and Linux images, DMA drivers, boot media and board tests
live in IronForge. The standalone RTLNet image and test commands below use
the RTLNet firmware and lwIP CLI.

See the [IronForge integration and board checks](documentation/rtlnet_nexys_video.md#ironforge-linux-integration)
and the [IronForge Nexys Video commands](https://github.com/ironkernel01/IronForge/blob/main/platforms/nexys-video/COMMANDS.md).

## Folders

| Folder | Contents |
|---|---|
| `hdl/` | board top, system registers, clock beacon, filelists |
| `constraints/` | XDC files (full design, CPU only, RGMII) |
| `ip/` | `rtlnet_ddr_mig.prj`, the MIG project of the board (passed to `rtlnet_ddr_mig_create` of `cores/rtlnet_ddr`) |
| `scripts/` | build, program, JTAG ELF load and the hardware tests (CLI, network, TCP, stream, offload) |
| `testbench/` | board benches and `regression.txt` (picked up by `scripts/rtlnet_regression.ps1`) |
| `documentation/` | the board guide |

Related folders: `cpu/microblaze_v_h264/` (CPU block design, firmware, host tests) and `demos/` (ready-to-run
bitstreams, see `demos/README.md`).

## Build, program, outputs

All paths are from the repository root. Everything under `boards/nexys_video/build/` is git-ignored except the three
files named below; it exists after you build.

### Build command lines

Prefix of every command: `powershell -NoProfile -ExecutionPolicy Bypass -File`.

| Command | Result |
|---|---|
| `boards/nexys_video/scripts/build.ps1 -Network` | untagged build: synthesis, implementation, bitstream, firmware build, firmware merged into the bitstream; output in `boards/nexys_video/build/` |
| `build.ps1 -Network -Tag <tag> -Image` | tagged release image; output in `boards/nexys_video/build/<tag>/` (not programmed by the script) |
| `build.ps1 -Network -Tag <tag>` | tagged hardware variant without firmware (`rtlnet_nexys_video_hw.bit`) |
| `build.ps1 -Network -HighProfile full` or `demo`, with `-Tag <tag> -Image` | High profile variants; needs the private High profile repository, stops with a message without it |
| `build.ps1 ... -Program` or `-Test` | also program the board, or also run `cli_test.ps1` |
| `cmd /c demos\demorelease.bat` | copies the images of the tags named in each `demos/<demo>/release.txt` into `demos/<demo>/<board>/` |

### Files of a build folder (`build/` or `build/<tag>/`)

| File | Content |
|---|---|
| `rtlnet_nexys_video.bit` | bitstream with the firmware merged in (untagged builds and `-Image` builds) |
| `rtlnet_nexys_video_hw.bit` | bitstream without firmware (the BRAM holds no program yet) |
| `rtlnet_nexys_video.mmi` | memory map of the LMB BRAM, used by the merge |
| `rtlnet_nexys_video.xsa` | hardware platform for the firmware BSP (a firmware build needs it, so a new checkout builds the bitstream once first) |
| `build_info.txt` | source revision, dirty flag, tool version, build time, timing (WNS, WHS, WPWS), utilization, CDC census |
| `build_bitstream.log` | the Vivado log of the build |
| `reports/` | `post_synth_utilization.rpt`, `post_route_utilization.rpt`, `post_route_utilization_hier.rpt`, `post_route_timing_summary.rpt`, `post_route_cdc.rpt`, `post_route_methodology.rpt`, `post_route_drc.rpt`, `post_route_clock_networks.rpt`, `post_route_clock_interaction.rpt`, `post_route_io.rpt`, `post_route_check_timing.rpt`; `failing_setup.rpt` and `failing_hold.rpt` only when a path fails |
| `post_synth.dcp`, `post_route.dcp` | design checkpoints |
| `bd/`, `ip/` | the generated MicroBlaze block design and the generated DDR3 controller IP (from `ip/rtlnet_ddr_mig.prj`) |

The firmware build writes into `cpu/microblaze_v_h264/firmware/build/`: `firmware.elf` (the image merged into the bitstream),
`firmware_ddr.elf` (`build.ps1 -Ddr` in `cpu/microblaze_v_h264/firmware/`, loaded with `scripts/jtag_load_elf.ps1`), `menu.exe` (CLI
desktop harness), `ws/` (the generated BSP), `ratectl_test.log`.

### Program

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 -Bit boards/nexys_video/build/<tag>/rtlnet_nexys_video.bit
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 -Bit demos/<demo name>/nexys_video/rtlnet_nexys_video.bit
```

The first form programs `build/rtlnet_nexys_video.bit`, the image of an untagged build; it exists after such a build (no build output is tracked in git, the released images are under `demos/`). The image goes to the FPGA only; a power cycle removes it.

### Where the test scripts write

| Script | Output |
|---|---|
| `cli_test.ps1` | `build/cli_test_transcript.txt` |
| `net_test.ps1` | `build/net_test_transcript.txt` |
| `phase1_gate.ps1` | `build/phase1_gate_transcript.txt` |
| `stream_test.ps1` | `build/<prefix>_stream_transcript.txt` and, per run, `build/<name>_ts.txt`, `_decode.txt`, `_psnr.txt`, `_reorder.txt`, `_trim.txt`, `_headtrim.txt`, `<prefix>_<mode>_poll.txt`, `<prefix>_<mode>_history.txt` (the prefix is `phase2c_gop<N>`, or the `-FilePrefix` value) |
| `release_stream_gates.ps1` | `build/phase2i_<label>_gates_summary.txt` |
| `tcp_test.ps1`, `offload_bench.ps1`, `offload_profile.ps1` | the console only |
| `stream_check_selftest.ps1` | the console (`STREAM_CHECK_SELFTEST: PASS`); it is a regression entry |
| `hp_expiry_test.ps1` | `build/<prefix>_summary.txt` and the files named in its header (High profile demo image only) |

Simulation results of the board benches go to `.sim/<bench>/` like every bench (root README).

## Ethernet demo design

A second, small design for the same board: 10/100/1000 Ethernet with a simple MicroBlaze V and firmware for DHCP, ARP, ping, UDP and
lwIP TCP; no DDR3, MIG, camera, video or H.264. Top `hdl/rtlnet_nexys_video_eth_top.sv` (filelist `hdl/rtlnet_nexys_video_eth.f`), pins
`constraints/rtlnet_nexys_video_eth.xdc` with the shared `rtlnet_nexys_video_rgmii.xdc`, bench `testbench/tb_rtlnet_nexys_video_eth.sv`,
CPU and firmware `cpu/microblaze_v_ethernet/` (board independent, shared with the Arty A7-100 later). The H.264 flow above is not touched.

Clocks (`COMMON_CLK` parameter of the top, build option `-CommonClk`): 2 (default) = one 100 MHz system clock for the CPU, the protocol cores and the MAC client
side; besides it only the RGMII receive clock, `clk125`/`clk125_90` (RGMII transmit side) and `clk200` (IDELAYCTRL) exist; 0 = the multi-clock tree (62.5 and
50 MHz protocol clocks, CPU on its own clock). The CPU's frame buffers are a dual-port block RAM
on the CPU's data-side LMB (`-LmbBuf 1`, `-BufKb 128`). Details: `cpu/microblaze_v_ethernet/documentation/rtlnet_cpu_eth.md` sections 2, 2a and 6c.

```powershell
# bitstream, firmware and merge; output boards/nexys_video/build/<tag>/rtlnet_nexys_video_eth.bit (and .mmi, .xsa, build_info.txt)
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/build_ethernet.ps1 -Tag eth_dev -CommonClk 2 [-Program]
# hardware tests of the board-independent set (console on <COM port>, PC adapter <name>)
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/microblaze_v_ethernet/test/run_all.ps1 -Port <COM port> -Nic <adapter> -LinkMbps 1000
```

## Measured on hardware (100 Mb/s link)

| Traffic | Rate |
|---|---|
| UDP iperf PC -> board (RTL server) | 94.0 / 94.4 Mb/s, 0 lost |
| TCP iperf PC -> board (lwIP) | 94.8 Mb/s |
| TCP iperf board -> PC (`-R`) | 94.9 Mb/s |
| TCP iperf `-d` (both at once) | 27.0 + 93.8 Mb/s |
| TCP iperf + UDP iperf 20 Mb/s together | TCP 72-74, UDP 20.9 Mb/s, 0 lost |
| MicroBlaze load at TCP line rate | 35 % (100 MHz, no caches, BRAM only) |
| Broadcast storm limiter | 10 frames per 100 ms toward the CPU, under a 400 frame/s flood |

The video, encoder and gigabit results are in the board guide and in `demos/`. The released Ethernet image
(`rtlnet_nexys_video_eth.bit`) is in `demos/ethernet/nexys_video/`. See the [RTLNet Specification](../../documentation/rtnet_specification.md) for the current release measurements.

### Release image `eth_rel` (11-14-2026)

Build `eth_rel` (git 2c2c686b, tree clean, one 100 MHz clock, 512 KiB LMB, 128 KiB frame buffer): WNS +0.154 ns, WHS +0.012 ns, WPWS +0.264 ns; 23891 LUT, 33968 FF, 228.5 block RAM tiles, 6 DSP. Hardware campaign through a switch at 1000, 100 and 10 Mb/s:

| Test | 1000 Mb/s | 100 Mb/s | 10 Mb/s |
|---|---|---|---|
| `run_all.ps1` | PASS 8/8 | PASS 8/8 | PASS 8/8 |
| TCP iperf PC to board / board to PC, mean of 3 x 10 s (Mb/s) | 349.7 / 283.3 | 94.7 / 94.6 | 9.5 / 9.5 |
| UDP iperf PC to board / board to PC (Mb/s) | 942.0 / 944.0 | 94.1 / 94.4 | 9.4 / 9.4 |
| UDP echo 64 B mean / p99 (ms) | 0.163 / 0.208 | 0.163 / 0.205 | 1.287 / 1.357 |

`flood_test.ps1`: `FLOOD_TEST: PASS 95/95` (1000 frames per second, all kinds) and `PASS 50/50` (20000, four kinds). The captures and run instructions are in `demos/ethernet/`. The [RTLNet Specification](../../documentation/rtnet_specification.md) compares the released board configurations.

The November 20 physical retest of the released standalone Ethernet image
verified 1000 Mb/s full duplex, DHCP, UDP and TCP echo, and TCP iperf at
335 Mb/s PC to board and 280 Mb/s board to PC.
[Standalone Ethernet demo retest](documentation/rtlnet_nexys_video.md#standalone-ethernet-demo-retest-11-20-2026)

## Quick start

Run from the repository root in PowerShell.

```powershell
# Full simulation regression (cores, board benches, firmware host tests)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1

# Bitstream with the network stack, firmware merged into the bitstream
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/build.ps1 -Network

# Program the board over JTAG
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1

# Hardware tests (board on the USB-UART CLI and a wired NIC)
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/cli_test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/net_test.ps1 -Nic Ethernet -Speed 100
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/tcp_test.ps1
```

The CLI is on the board's USB-UART (115200 8N1). It is hierarchical, in a lightweight switch style; type `?` for help.

Tools beyond the ones of the root README: the MicroBlaze GCC and BSP from the Vitis install (lwIP 2.2.0 is compiled in place
from it; only the RTLNet-specific files live in `cpu/microblaze_v_h264/firmware/src/lwip/`) and iperf 2.2.x on the PC.

## Status

- Programming is JTAG only. Quad-SPI flash boot is not set up.
- `build.ps1 -HighProfile` needs the private High profile netlist repository and stops with a clear message without it;
  the default build is the public Constrained Baseline design.
