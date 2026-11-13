# RTLNet on the Digilent Nexys Video

This folder is the board design for the Digilent Nexys Video (Artix-7 XC7A200T-1SBG484C, Realtek RTL8211E RGMII PHY,
512 MiB DDR3L). It is on the `nexys_video_h264_baseline` branch and the branches stacked on it; `main` holds only the
board-independent cores.

The design is the RTLNet Ethernet stack, the MicroBlaze V network path running lwIP, the DDR3 path, the test-pattern
video source and the two-engine H.264 Constrained Baseline encoder, on one 90 MHz clock. The board guide with the design,
the measurements and the build log is `documentation/rtlnet_nexys_video.md`.

## Folders

| Folder | Contents |
|---|---|
| `hdl/` | board top, system registers, clock beacon, filelists |
| `constraints/` | XDC files (full design, CPU only, RGMII) |
| `ip/` | `rtlnet_ddr_mig.prj`, the MIG project of the board (passed to `rtlnet_ddr_mig_create` of `cores/rtlnet_ddr`) |
| `scripts/` | build, program, JTAG ELF load and the hardware tests (CLI, network, TCP, stream, offload) |
| `testbench/` | board benches and `regression.txt` (picked up by `scripts/rtlnet_regression.ps1`) |
| `documentation/` | the board guide |

Other folders of this branch: `microblaze/` (CPU block design, firmware, host tests) and `demos/` (ready-to-run
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
| `rtlnet_nexys_video.bit` | bitstream with the firmware merged in (untagged builds and `-Image` builds); the untagged one is tracked in git |
| `rtlnet_nexys_video_hw.bit` | bitstream without firmware (the BRAM holds no program yet) |
| `rtlnet_nexys_video.mmi` | memory map of the LMB BRAM, used by the merge; tracked for the untagged build |
| `rtlnet_nexys_video.xsa` | hardware platform for the firmware BSP; tracked for the untagged build |
| `build_info.txt` | source revision, dirty flag, tool version, build time, timing (WNS, WHS, WPWS), utilization, CDC census |
| `build_bitstream.log` | the Vivado log of the build |
| `reports/` | `post_synth_utilization.rpt`, `post_route_utilization.rpt`, `post_route_utilization_hier.rpt`, `post_route_timing_summary.rpt`, `post_route_cdc.rpt`, `post_route_methodology.rpt`, `post_route_drc.rpt`, `post_route_clock_networks.rpt`, `post_route_clock_interaction.rpt`, `post_route_io.rpt`, `post_route_check_timing.rpt`; `failing_setup.rpt` and `failing_hold.rpt` only when a path fails |
| `post_synth.dcp`, `post_route.dcp` | design checkpoints |
| `bd/`, `ip/` | the generated MicroBlaze block design and the generated DDR3 controller IP (from `ip/rtlnet_ddr_mig.prj`) |

The firmware build writes into `microblaze/firmware/build/`: `firmware.elf` (the image merged into the bitstream; tracked),
`firmware_ddr.elf` (`build.ps1 -Ddr` in `microblaze/firmware/`, loaded with `scripts/jtag_load_elf.ps1`), `menu.exe` (CLI
desktop harness), `ws/` (the generated BSP), `ratectl_test.log`.

### Program

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 -Bit boards/nexys_video/build/<tag>/rtlnet_nexys_video.bit
powershell -NoProfile -ExecutionPolicy Bypass -File boards/nexys_video/scripts/program.ps1 -Bit demos/<demo name>/nexys_video/rtlnet_nexys_video.bit
```

The first form programs `build/rtlnet_nexys_video.bit`. The image goes to the FPGA only; a power cycle removes it.

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
| `hp_expiry_test.ps1` | `build/<prefix>_summary.txt` and the files named in its header (highprofile branch only) |

Simulation results of the board benches go to `.sim/<bench>/` like every bench (root README).

## Measured on hardware (100 Mb/s link)

| Traffic | Rate |
|---|---|
| UDP iperf PC -> board (RTL server) | 94.0 / 94.4 Mbit/s, 0 lost |
| TCP iperf PC -> board (lwIP) | 94.8 Mbit/s |
| TCP iperf board -> PC (`-R`) | 94.9 Mbit/s |
| TCP iperf `-d` (both at once) | 27.0 + 93.8 Mbit/s |
| TCP iperf + UDP iperf 20 Mbit/s together | TCP 72-74, UDP 20.9 Mbit/s, 0 lost |
| MicroBlaze load at TCP line rate | 35 % (100 MHz, no caches, BRAM only) |
| Broadcast storm limiter | 10 frames per 100 ms toward the CPU, under a 400 frame/s flood |

The video, encoder and gigabit results are in the board guide and in `demos/`.

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
from it; only the RTLNet-specific files live in `microblaze/firmware/src/lwip/`) and iperf 2.2.x on the PC.

## Status

- Programming is JTAG only. Quad-SPI flash boot is not set up.
- `build.ps1 -HighProfile` needs the private High profile netlist repository and stops with a clear message without it;
  the default build is the public Constrained Baseline design.
