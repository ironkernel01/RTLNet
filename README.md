# IronKernel RTLNet

RTLNet is a library of FPGA cores in SystemVerilog: a line-rate Ethernet/IPv4 stack (MAC, ARP, ICMP, DHCP, UDP, iperf
UDP, classifier), an optional soft-CPU network path for TCP, a DDR3 memory path, a video capture and frame-buffer
path, and an H.264 encoder. Every core has the same layout, an AXI4-Lite register slave, a C driver, an Active-HDL bench
and a core guide. The cores are vendor-neutral RTL (AMD is the default technology); a board design ties them together.

This branch (`main`) holds everything that targets no specific board. A board design lives on its own branch (see
"Branches").

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

Paths are from the repository root. "Branch" says where the path exists: `main` paths exist on every branch; "baseline and
later" means `nexys_video_h264_baseline` and `nexys_video_h264_highprofile`. "Built" means the file is git-ignored or
produced by a script and exists only after you run it.

| What | Branch | Path |
|---|---|---|
| Demo bitstreams (firmware included), one folder per demo and board | baseline and later | `demos/<demo name>/<board>/rtlnet_<board>.bit` |
| Demo build record (source revision, timing, utilization) | baseline and later | `demos/<demo name>/<board>/build_info.txt` |
| Steps to run a demo | baseline and later | `demos/<demo name>/<board>/README.md` |
| Demo brief (Markdown and PDF), demo pictures | baseline and later | `demos/<demo name>/<demo name>_brief.md`, `.pdf`, `demos/<demo name>/images/` |
| Demo guide and index (what is in `demos/`, what to connect, how to run) | baseline and later | `demos/README.md`, `demos/demos.md` |
| License of a time-limited demo package | highprofile only | `demos/LICENSE_DEMO.md` |
| The High profile demo (bitstream, README, brief) | highprofile only | `demos/h264_high_profile_demo/` |
| Refresh the demo folders from the board build folders | baseline and later | `demos/demorelease.bat`; it reads `demos/<demo name>/release.txt` and copies `boards/<board>/build/<tag>/rtlnet_<board>.bit` and `build_info.txt` into `demos/<demo name>/<board>/` |
| Build the PDF of a demo brief | baseline and later | `demos/build_brief_pdf.ps1` (writes next to the brief) |
| Board build output: bitstream with firmware, bitstream without firmware, `.mmi`, `.xsa`, `build_info.txt`, `build_bitstream.log`, `reports/` (timing, utilization, CDC, DRC), checkpoints | baseline and later | `boards/nexys_video/build/` for an untagged build, `boards/nexys_video/build/<tag>/` for `build.ps1 -Tag <tag> -Image`. Built, git-ignored (the released images are the tracked files under `demos/`). The file list is in `boards/nexys_video/README.md` |
| Firmware image (merged into the bitstream), DDR3 development image | baseline and later | `microblaze/firmware/build/firmware.elf`, `microblaze/firmware/build/firmware_ddr.elf` (both built, git-ignored) |
| Firmware host tests and the CLI desktop harness | baseline and later | scripts in `microblaze/firmware/test/` (listed in their `regression.txt`); `microblaze/firmware/build/menu.exe` and `ratectl_test.log` are built |
| Generated CLI documentation | baseline and later | `microblaze/firmware/cli/MenuDocumentation.md` (generated from `cli_commands.txt` by `gen_menu.py`, checked by `check_menu.py`) |
| Simulation logs of one bench (Active-HDL) | main | `.sim/<bench>[_<tag>]/simulation.log`; Verilator runs in `.sim/verilator/<bench>[_<tag>]/` (built, git-ignored) |
| Regression result | main | the last line printed by `scripts/rtlnet_regression.ps1` (`RTLNET_REGRESSION: <n> passed, <m> failed`); the lists are `scripts/rtlnet_regression.txt` and every `regression.txt` under `cores/`, and on board branches under `microblaze/` and `boards/` |
| Host tools built by the core tests (C models, decoders) | main | `%LOCALAPPDATA%\RTLNet\tools\<name>` (override with `RTLNET_TOOLS_DIR`) |
| Product brief | main | `documentation/rtlnet_product_brief.pdf` (source `.md`; rebuild with `documentation/build_pdf.ps1`) |
| Architecture, contributing rules and branch rules | main | `documentation/rtlnet_architecture.md`, `documentation/rtlnet_contributing.md` |
| Core documents | main | `cores/<core>/documentation/<core>.md` |
| Board document and board guide | baseline and later | `boards/nexys_video/documentation/rtlnet_nexys_video.md`, `boards/nexys_video/README.md`; CPU documents in `microblaze/documentation/` |
| Drawings (PowerPoint and PNG) | main (product brief); baseline and later (demo drawings) | `diagrams/out/`, `diagrams/out/png/`; sources in `diagrams/src/` |
| Board test scripts and their output | baseline and later | scripts in `boards/nexys_video/scripts/`; transcripts and captures in `boards/nexys_video/build/` (names in `boards/nexys_video/README.md`) |
| License | main | `LICENSE.md` |

## Folders on `main`

| Folder | Contents |
|---|---|
| `cores/` | the cores above, each with `hdl/`, `driver/`, `testbench/`, `documentation/` |
| `scripts/` | simulation runner, regression, synthesis/timing checks, CDC constraints, Vivado launcher, name check, tool discovery (`rtlnet_tools.ps1`) |
| `documentation/` | `rtlnet_architecture.md` (the system contract: stream and register conventions, address map, port lists), `rtlnet_contributing.md` (rules and branch rules), `rtlnet_product_brief.md` and its PDF |
| `diagrams/` | sources and renderings of the drawings of the generic documents |
| `LICENSE.md` | the RTLNet source-available license |

## Branches

| Branch | Contents |
|---|---|
| `main` | board-independent RTL: `cores/`, generic `scripts/`, generic `documentation/`, `diagrams/`, license |
| `nexys_video_h264_baseline` | `main` plus the design for the Digilent Nexys Video with the public Constrained Baseline encoder: `boards/nexys_video/` (top, constraints, scripts, board guide), `microblaze/` (CPU block design, firmware), `demos/` |
| `nexys_video_h264_highprofile` | `nexys_video_h264_baseline` plus the High profile demonstration material (the 30-minute demo image, its brief and test scripts); it never holds High profile sources or a netlist |
| further boards | each board gets its own branch from `main` in the same way |

To get a board design, check out the board branch (`git checkout nexys_video_h264_baseline`). The measured results of
the cores in their guides are results on that board.

Merges go one way: `main` into `nexys_video_h264_baseline`, that into `nexys_video_h264_highprofile`, never the other
way. A file belongs to exactly one layer, and nothing board-specific is on `main`. The rules are in
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
- The board branches add the MicroBlaze GCC and BSP from the Vitis install, and iperf 2.2.x on the PC for throughput tests

## Quick start

Run from the repository root in PowerShell.

```powershell
# Full simulation regression (Active-HDL); on a board branch it also runs the board benches and firmware host tests
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1

# One bench
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_run_sim.ps1 -Bench <tb> -Filelist <f>
```

Building and programming a bitstream is described in the board guide of the board branch
(`boards/nexys_video/README.md` on `nexys_video_h264_baseline`).

## License

`LICENSE.md` (source-available). Copyright (C) 2026 IronKernel. lwIP-derived files on the board branches keep the lwIP
BSD license.
