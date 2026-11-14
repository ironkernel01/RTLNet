# IronKernel RTLNet

RTLNet is a library of FPGA cores in SystemVerilog: a line-rate Ethernet/IPv4 stack (MAC, ARP, ICMP, DHCP, UDP, iperf
UDP, classifier), an optional soft-CPU network path for TCP, a DDR3 memory path, a video capture and frame-buffer
path, and an H.264 encoder. Every core has the same layout, an AXI4-Lite register slave, a C driver, an Active-HDL bench
and a core guide. The cores are vendor-neutral RTL (AMD is the default technology); a board design ties them together.

The repository has one branch, `main`. Folders separate the board-independent cores (`cores/`) from the board design
(`boards/`, `cpu/`) and the released demonstration images (`demos/`); see "Folders" and "Repository layout rule".

## Cores

Every core has the same layout: `hdl/`, `driver/` (C), `testbench/` and `documentation/`.

| Core | Function |
|---|---|
| `cores/rtlnet_common` | Shared library: technology include, RAM wrapper (`rtlnet_ram_core`), shift register (`rtlnet_shift_reg_core`), synchronizers, packet FIFO, AXI4-Lite slave/CDC/decoder |
| `cores/rtlnet_eth_mac` | 10/100/1000 Mb/s RGMII MAC: FCS, padding, IFG, store-and-forward queues |
| `cores/rtlnet_mdio` | Bit-banged MDIO (Clause 22 and Clause 45) plus the RTL8211E driver (LEDs, EEE off) |
| `cores/rtlnet_eth_protocol` | Protocol wrapper: MAC filter, queues, leaf fan-out, arbiter, address registers, CPU network path |
| `cores/rtlnet_arp` | ARP responder |
| `cores/rtlnet_icmp` | ICMP echo (ping) |
| `cores/rtlnet_dhcp` | DHCP client |
| `cores/rtlnet_iperf` | iperf 2 UDP server |
| `cores/rtlnet_udp_socket` | UDP socket layer with N bound ports |
| `cores/rtlnet_udp_echo` | UDP echo application |
| `cores/rtlnet_classifier` | Configurable L2-L4 filter/classifier with policers. It drops everything at power-up until configured; the first configuration is the broadcast storm limiter |
| `cores/rtlnet_tcp_offload` | Checksum offload on the CPU DMA streams: inserts IPv4/TCP/UDP checksums on transmit, and checks them on receive with an 8-byte result trailer |
| `cores/rtlnet_axi_arbiter` | N:1 AXI4 arbiter in front of the DDR3 port |
| `cores/rtlnet_axi_cdc` | AXI4 clock-domain bridge |
| `cores/rtlnet_ddr` | DDR3 memory controller behind a vendor-neutral AXI4 slave; the MIG project file comes from the board |
| `cores/rtlnet_csi2_rx` | CSI-2 capture core: test-pattern generator and video source switch |
| `cores/rtlnet_vdma_s2mm` | 2D video write DMA |
| `cores/rtlnet_framebuf` | Tear-free frame-buffer slot manager |
| `cores/rtlnet_h264_enc` | H.264 encoder (Constrained Baseline, in-loop deblocking filter, interrupt-driven driver layer); a default-off seam for an optional High profile extension |

## Where to find the files

Paths are from the repository root. "Built" means the file is git-ignored or produced by a script and exists only after
you run it.

| What | Path |
|---|---|
| Demo bitstreams (firmware included), one folder per demo and board | `demos/<demo name>/<board>/rtlnet_<board>.bit` |
| Demo build record (source revision, timing, utilization) | `demos/<demo name>/<board>/build_info.txt` |
| Steps to run a demo | `demos/<demo name>/<board>/README.md` |
| Demo brief (Markdown and PDF), demo pictures | `demos/<demo name>/<demo name>_brief.md`, `.pdf`, `demos/<demo name>/images/` |
| Demo guide and index (what is in `demos/`, what to connect, how to run) | `demos/README.md`, `demos/demos.md` |
| License of a time-limited demo package | `demos/LICENSE_DEMO.md` |
| The High profile demo (bitstream, README, brief) | `demos/h264_high_profile_demo/` |
| Refresh the demo folders from the board build folders | `demos/demorelease.bat`; it reads `demos/<demo name>/release.txt` and copies `boards/<board>/build/<tag>/rtlnet_<board>.bit` and `build_info.txt` into `demos/<demo name>/<board>/` |
| Build the PDF of a demo brief | `demos/build_brief_pdf.ps1` (writes next to the brief) |
| Board build output: bitstream with firmware, bitstream without firmware, `.mmi`, `.xsa`, `build_info.txt`, `build_bitstream.log`, `reports/` (timing, utilization, CDC, DRC), checkpoints | `boards/nexys_video/build/` for an untagged build, `boards/nexys_video/build/<tag>/` for `build.ps1 -Tag <tag> -Image`. Built, git-ignored (the released images are the tracked files under `demos/`). The file list is in `boards/nexys_video/README.md` |
| Firmware image (merged into the bitstream), DDR3 development image | `cpu/microblaze_v_h264/firmware/build/firmware.elf`, `cpu/microblaze_v_h264/firmware/build/firmware_ddr.elf` (both built, git-ignored) |
| Firmware host tests and the CLI desktop harness | scripts in `cpu/microblaze_v_h264/firmware/test/` (listed in their `regression.txt`); `cpu/microblaze_v_h264/firmware/build/menu.exe` and `ratectl_test.log` are built |
| Generated CLI documentation | `cpu/microblaze_v_h264/firmware/cli/MenuDocumentation.md` (generated from `cli_commands.txt` by `gen_menu.py`, checked by `check_menu.py`) |
| Simulation logs of one bench (Active-HDL) | `.sim/<bench>[_<tag>]/simulation.log`; Verilator runs in `.sim/verilator/<bench>[_<tag>]/` (built, git-ignored) |
| Regression result | the last line printed by `scripts/rtlnet_regression.ps1` (`RTLNET_REGRESSION: <n> passed, <m> failed`); the lists are `scripts/rtlnet_regression.txt` and every `regression.txt` under `cores/`, `cpu/` and `boards/` (the last two are optional folders) |
| Host tools built by the core tests (C models, decoders) | `%LOCALAPPDATA%\RTLNet\tools\<name>` (override with `RTLNET_TOOLS_DIR`) |
| Product brief | `documentation/rtlnet_product_brief.pdf` (source `.md`; rebuild with `documentation/build_pdf.ps1`) |
| Architecture, contributing rules and repository layout rules | `documentation/rtlnet_architecture.md`, `documentation/rtlnet_contributing.md` |
| Core documents | `cores/<core>/documentation/<core>.md` |
| Board document and board guide | `boards/nexys_video/documentation/rtlnet_nexys_video.md`, `boards/nexys_video/README.md`; CPU documents in `cpu/microblaze_v_h264/documentation/` |
| Drawings (PowerPoint and PNG) | `diagrams/out/`, `diagrams/out/png/`; sources in `diagrams/src/` |
| Board test scripts and their output | scripts in `boards/nexys_video/scripts/`; transcripts and captures in `boards/nexys_video/build/` (names in `boards/nexys_video/README.md`) |
| License | `LICENSE.md` |

## Folders

| Folder | Contents |
|---|---|
| `cores/` | the board-independent cores above, each with `hdl/`, `driver/`, `testbench/`, `documentation/`; it targets no board |
| `boards/` | one folder per board design; today `boards/nexys_video/` (top, constraints, MIG project file, build and test scripts, board bench, board guide); a second board, an Arty A7-100, is planned as `boards/arty_a7_100/` |
| `cpu/` | one folder per CPU, each independent with its own block design, driver, firmware, CLI, tests and documents; today `cpu/microblaze_v_h264/` (the MicroBlaze V CPU of the H.264 demos: block design, driver, documents, and the firmware with CLI, lwIP application and host tests; written for the Nexys Video today) |
| `demos/` | released demonstration bitstreams, one folder per demo with its brief, `release.txt` and the license of a time-limited demo (`demos/LICENSE_DEMO.md`) |
| `scripts/` | simulation runner, regression, synthesis/timing checks, CDC constraints, Vivado launcher, name check, tool discovery (`rtlnet_tools.ps1`) |
| `documentation/` | `rtlnet_architecture.md` (the system contract: stream and register conventions, address map, port lists), `rtlnet_contributing.md` (rules and repository layout rules), `rtlnet_product_brief.md` and its PDF |
| `diagrams/` | sources (`src/`) and renderings (`out/`) of the drawings |
| `LICENSE.md` | the RTLNet source-available license |

## Repository layout rule

All work is committed on `main`. The folders keep board-independent code apart from a board:

- `cores/` is board-independent. It does not depend on `boards/`, `cpu/` or `demos/`, and the regression of the
  cores runs with those folders absent.
- Each board has one folder under `boards/`; board-specific files (top, constraints, MIG project file, build and test
  scripts) live there.
- Released images are only under `demos/`; no build output is tracked in git.

The measured results of the cores in their guides are results on the Nexys Video. The rules are in
`documentation/rtlnet_contributing.md` section 8.

## Conventions

- **Language:** all RTL and benches are SystemVerilog-2012 (`.sv`). Drivers and firmware are C11.
- **Buses:** a common 64-bit AXI4-Stream data bus (`tdata`/`tkeep`/`tlast`, sized for a 10G/25G MAC) and AXI4-Lite control.
  Every core has an ID/VERSION/CAPS register header.
- **Portability:** the technology is selected in `rtlnet_technology.svh` (AMD default). RAM and shift registers
  go through the common wrappers, so a retarget changes only those files.
- **Timing:** at most two LUT levels per register stage, so the cores can scale to 10G/25G clock rates.

## Tools

- AMD Vivado 2026.1 with the free Vivado Basic license (synthesis, implementation); tools are located by `scripts/rtlnet_tools.ps1` (override with `RTLNET_XILINX`, `RTLNET_ALDEC`, `RTLNET_PYTHON`, `RTLNET_HOST_CC`, `RTLNET_IPERF`)
- Aldec Active-HDL 11.1 (all simulation)
- Python 3 with numpy and a host C compiler for the host-side models and driver tests
- The board design adds the MicroBlaze GCC and BSP from the Vitis install, and iperf 2.2.x on the PC for throughput tests

## Quick start

Run from the repository root in PowerShell.

```powershell
# Full simulation regression (Active-HDL); it also runs the board benches and firmware host tests when boards/ and cpu/ exist
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1

# One bench
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_run_sim.ps1 -Bench <tb> -Filelist <f>
```

Building and programming a bitstream is described in the board guide (`boards/nexys_video/README.md`).

## License

`LICENSE.md` (source-available). Copyright (C) 2026 IronKernel. lwIP-derived files under `cpu/microblaze_v_h264/` keep the lwIP
BSD license.
