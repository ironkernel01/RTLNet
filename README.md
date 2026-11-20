# RTLNet integration and design guide

RTLNet implements an Ethernet/IPv4 stack in SystemVerilog. ARP, ICMP echo, DHCP and UDP run in hardware. A protected CPU network path adds lwIP TCP. The Ethernet images run on Nexys Video and Arty A7-100T. A separate Nexys media image connects companion IronCapture and IronH264 cores through DDR and streams encoded color bars over Ethernet.

[RTLNet Specification (PDF)](documentation/rtnet_specification.pdf) · [Markdown](documentation/rtnet_specification.md) · [Architecture](documentation/rtlnet_architecture.md) · [Contributing](documentation/rtlnet_contributing.md)

The repository has one branch, `main`. Folders separate the board-independent cores (`cores/`) from the board design
(`boards/`, `cpu/`) and the released demonstration images (`demos/`); see "Folders" and "Repository layout rule".

This Markdown guide connects RTL, drivers and reference firmware for engineers and AI coding assistants such as Claude and Codex. Choose the board and traffic path first. A hardware UDP service and a CPU TCP service share the PHY and MAC, but use different queues, configuration and counters.

## Integrating a network endpoint

| Work area | Start here | Contract |
|---|---|---|
| Board and PHY | [Nexys Video](boards/nexys_video/README.md), [Arty A7-100T](boards/arty_a7_100/README.md), [MDIO driver](cores/rtlnet_mdio/driver/) | Match RGMII or MII, PHY clock/reset, full-duplex link speed and pin constraints. |
| Hardware UDP service | [Socket interface](cores/rtlnet_udp_socket/documentation/rtlnet_udp_socket.md), [UDP echo example](cores/rtlnet_udp_echo/) | Bind a local port, consume two metadata beats and payload, then return destination metadata and payload through the TX stream. |
| CPU service | [Ethernet firmware](cpu/microblaze_v_ethernet/firmware/), [classifier](cores/rtlnet_classifier/), [checksum offload](cores/rtlnet_tcp_offload/) | Unclaimed traffic admitted to the CPU passes through DMA and lwIP. Application sockets, classifier allow rules and checksum status must agree. |
| Media over Ethernet | [Nexys media integration](boards/nexys_video/), [dependency manifest](media-sources.json), [source resolver](scripts/resolve_media.ps1) | IronCapture supplies the source, IronH264 the encoder. The reference uses internal color bars, DDR and MPEG-TS over UDP. |

1. Check MDIO discovery, negotiated speed and MAC RX/TX counters before starting higher-layer services. Configure a local MAC and IPv4 address or enable the hardware DHCP client. Verify ARP and ICMP echo.
2. At the MAC client boundary use 64-bit AXI4-Stream, first wire byte in bits 7:0, contiguous final TKEEP and TLAST on the final beat. Keep valid data stable until ready. The MAC handles FCS and padding. At the socket boundary use the [UDP metadata layout](cores/rtlnet_udp_socket/documentation/rtlnet_udp_socket.md) and exchange application payloads.
3. For CPU traffic, check the enabled hardware leaves, classifier rules, DMA ownership and lwIP listener. When a service stalls, compare MAC RX, protocol claims, classifier drops, checksum results and CPU DMA completion in that order. Successful hardware ping can coexist with a blocked TCP service.
4. Issuing CPU accesses to the Ethernet boards uses the common 32-bit AXI4-Lite map. SYS, MAC, MDIO and UDP echo begin at `0x44A00000`, `0x44A01000`, `0x44A02000` and `0x44A03000`. The protocol window begins at `0x44A10000`. The [architecture guide](documentation/rtlnet_architecture.md) gives subwindows, port conventions and clock domains.
5. Change a network core in its owning directory and update its C register definitions and self-checking bench together. For a firmware service change, test both permitted and dropped traffic. For a media dependency change, pin the accepted tree, run the resolver, build the Nexys Baseline image and decode its UDP stream. For an Ethernet-only change, verify both link directions with UDP loss counts and TCP throughput at the negotiated speed.

## Integrating a 10 Gb/s packet path

Use a 64-bit MAC-client AXI4-Stream at 156.25 MHz for 10.00 Gb/s in each direction. Place the classifier at main ingress to inspect all frames. In a passing configuration with a ready output it can inspect legal frames losslessly at 100% line rate. The default block-RAM configuration closed timing out of context on XC7A200T-1 (+1.515 ns setup, +0.059 ns hold). Set the stream clock parameter to the actual frequency so policing windows remain calibrated. Preserve byte order, TKEEP and TLAST at the MAC boundary.

A minimum frame occupies 84 byte times on the wire including preamble and inter-frame gap. A 10 Gb/s link can present 14.88 million such frames/s. The classifier receives 60 client bytes after FCS removal, requiring eight cycles, or 19.53 million frames/s of classifier capacity. Its regression checks continuous input readiness and back-to-back output for legal minimum frames. Compare passed, mode-dropped, police-dropped and overrun counters during integration.

Use a 10 Gb/s MAC and PCS/PHY appropriate to the target board. Steer selected control and application traffic into a bounded service queue. ARP, DHCP, ICMP, UDP sockets, echo and iperf can share the 10 Gb/s bus. Each leaf only needs to service its selected packets at the provisioned rate. When clocking a leaf directly at 156.25 MHz, close timing on that instance. For a slower service domain, cross with a whole-frame FIFO and size it for bursts. Keep service backpressure isolated from the inline forwarding path. The Nexys and Arty Ethernet references place the classifier on the CPU branch and use 1 Gb/s and 100 Mb/s PHYs respectively. See the [classifier verification and timing record](cores/rtlnet_classifier/documentation/rtlnet_classifier.md).

## Cores

Use each Markdown guide for the core interface, configuration and verification. For a change, open the guide beside its `hdl/` implementation and the corresponding testbench. Register-controlled cores also supply C driver definitions.

| Core integration guide | What to connect, configure or verify |
|---|---|
| [rtlnet_eth_mac](cores/rtlnet_eth_mac/documentation/rtlnet_eth_mac.md) | Select RGMII on Nexys or MII on Arty. Feed the negotiated PHY speed to the MAC. Check receive clock, FCS errors, queue drops and transmitted frames. |
| [rtlnet_mdio](cores/rtlnet_mdio/documentation/rtlnet_mdio.md) | Drive PHY reset and management over MDC/MDIO. Identify the PHY and read its negotiated speed and duplex before enabling the MAC. |
| [rtlnet_eth_protocol](cores/rtlnet_eth_protocol/documentation/rtlnet_eth_protocol.md) | Set the local MAC and IPv4 address, enable leaves and connect the application and CPU clocks. Trace ingress filtering, leaf claims, unclaimed RX frames and transmit arbitration. |
| [rtlnet_arp](cores/rtlnet_arp/documentation/rtlnet_arp.md) | Enable the hardware responder for the active local IPv4 address. Test a peer ARP request and compare the returned IP and MAC. |
| [rtlnet_icmp](cores/rtlnet_icmp/documentation/rtlnet_icmp.md) | Send an IPv4 echo request to the configured address. Check the echoed payload and both checksums. |
| [rtlnet_dhcp](cores/rtlnet_dhcp/documentation/rtlnet_dhcp.md) | Start address acquisition and monitor lease state. Exercise renewal and expiry when using the lease as the effective node address. |
| [rtlnet_udp_socket](cores/rtlnet_udp_socket/documentation/rtlnet_udp_socket.md) | Bind a local port per enabled socket. Implement the two metadata beats, declared payload length and stream handshakes. Compare socket drops against application backpressure. |
| [rtlnet_udp_echo](cores/rtlnet_udp_echo/documentation/rtlnet_udp_echo.md) | Use this application as a socket client example. Send short and maximum-length datagrams and compare the returned payload byte for byte. |
| [rtlnet_iperf](cores/rtlnet_iperf/documentation/rtlnet_iperf.md) | Use an iperf 2 UDP peer to exercise receive and reverse-transmit paths. Compare bytes, sequencing and reported loss at the negotiated link speed. |
| [rtlnet_classifier](cores/rtlnet_classifier/documentation/rtlnet_classifier.md) | Choose a CPU admission policy, read built table capacities, configure field tables or ACL tuples and set fixed-window policers. Sections 13 and 14 describe storm protection and the default-deny firewall, including live rule updates. |
| [rtlnet_tcp_offload](cores/rtlnet_tcp_offload/documentation/rtlnet_tcp_offload.md) | Pair TX checksum insertion with the lwIP checksum configuration. On RX allocate room for the eight-byte status trailer, inspect its flags and remove it before delivering the frame to lwIP. |
| [rtlnet_common](cores/rtlnet_common/documentation/rtlnet_common.md) | Use the common packet FIFO, RAM, reset and AXI4-Lite primitives. Select synchronous or crossing variants according to the clocks on each interface. |
| [rtlnet_vdma_s2mm](cores/rtlnet_vdma_s2mm/documentation/rtlnet_vdma_s2mm.md) | Set line geometry and stride, supply a writable slot and verify end-of-line and end-of-frame handling before publishing a DDR frame. |
| [rtlnet_framebuf](cores/rtlnet_framebuf/documentation/rtlnet_framebuf.md) | Allocate and commit a writer slot, acquire the completed slot for a reader and release it when finished. The manager tracks ownership and metadata. |
| [rtlnet_axi_arbiter](cores/rtlnet_axi_arbiter/documentation/rtlnet_axi_arbiter.md) | Map DDR requesters to master ports, configure priorities and inspect per-master service under simultaneous traffic. |
| [rtlnet_axi_cdc](cores/rtlnet_axi_cdc/documentation/rtlnet_axi_cdc.md) | Cross the five memory-mapped AXI channels between clock domains. Follow the reset and FIFO requirements in the core guide. |
| [rtlnet_ddr](cores/rtlnet_ddr/documentation/rtlnet_ddr.md) | Connect the board memory controller and wait for calibration before issuing memory transactions. Check the board-specific width, clock and address range. |

### Companion IP used in the Nexys media design

IronCapture provides the receiver and internal pattern generator. IronH264 supplies the Baseline encoder. Resolve the pinned siblings before building the media image. The resolver creates local bindings under `ip/`. For the source revisions and binding procedure, see the [media manifest](media-sources.json) and [Nexys board guide](boards/nexys_video/README.md).

## Where to find the files

Paths are from the repository root. "Built" means the file is git-ignored or produced by a script and exists only after
you run it.

| What | Path |
|---|---|
| Demo bitstreams (firmware included), one folder per demo and board | `demos/<demo name>/<board>/rtlnet_<board>.bit` |
| Demo build record (source revision, timing, utilization) | `demos/<demo name>/<board>/build_info.txt` |
| Steps to run a demo | `demos/<demo name>/<board>/README.md` |
| Demo captures and pattern frames | `demos/<demo name>/images/` |
| Demo guide and index (what is in `demos/`, what to connect, how to run) | `demos/README.md`, `demos/demos.md` |
| License of a time-limited demo package | `demos/LICENSE_DEMO.md` |
| The High profile demo (bitstream, README) | `demos/h264_high_profile_demo/` |
| The Ethernet demo (10/100/1000, hardware ARP, ping, DHCP, UDP echo and iperf 2, lwIP TCP; bitstream `rtlnet_nexys_video_eth.bit`, README; no time limit) | `demos/ethernet/` |
| Refresh the demo folders from the board build folders | `demos/demorelease.bat`; it reads `demos/<demo name>/release.txt` and copies `boards/<board>/build/<tag>/rtlnet_<board>.bit` and `build_info.txt` into `demos/<demo name>/<board>/` |
| Board build output: bitstream with firmware, bitstream without firmware, `.mmi`, `.xsa`, `build_info.txt`, `build_bitstream.log`, `reports/` (timing, utilization, CDC, DRC), checkpoints | `boards/nexys_video/build/` for an untagged build, `boards/nexys_video/build/<tag>/` for `build.ps1 -Tag <tag> -Image`. Built, git-ignored (the released images are the tracked files under `demos/`). The file list is in `boards/nexys_video/README.md` |
| Firmware image (merged into the bitstream), DDR3 development image | `cpu/microblaze_v_h264/firmware/build/firmware.elf`, `cpu/microblaze_v_h264/firmware/build/firmware_ddr.elf` (both built, git-ignored) |
| Firmware host tests and the CLI desktop harness | scripts in `cpu/microblaze_v_h264/firmware/test/` (listed in their `regression.txt`); `cpu/microblaze_v_h264/firmware/build/menu.exe` and `ratectl_test.log` are built |
| Generated CLI documentation | `cpu/microblaze_v_h264/firmware/cli/MenuDocumentation.md` (generated from `cli_commands.txt` by `gen_menu.py`, checked by `check_menu.py`) |
| Simulation logs of one bench (Active-HDL) | `.sim/<bench>[_<tag>]/simulation.log`; Verilator runs in `.sim/verilator/<bench>[_<tag>]/` (built, git-ignored) |
| Regression result | the last line printed by `scripts/rtlnet_regression.ps1` (`RTLNET_REGRESSION: <n> passed, <m> failed`); the lists are `scripts/rtlnet_regression.txt` and every `regression.txt` under `cores/`, `cpu/` and `boards/` (the last two are optional folders) |
| Host tools built by the core tests (C models, decoders) | `%LOCALAPPDATA%\RTLNet\tools\<name>` (override with `RTLNET_TOOLS_DIR`) |
| Consolidated RTLNet Specification | `documentation/rtnet_specification.pdf` (source `.md`; rebuild with `documentation/build_pdf.ps1`) |
| Architecture, contributing rules and repository layout rules | `documentation/rtlnet_architecture.md`, `documentation/rtlnet_contributing.md` |
| Core documents | `cores/<core>/documentation/<core>.md` |
| Board document and board guide | `boards/nexys_video/documentation/rtlnet_nexys_video.md`, `boards/nexys_video/README.md`; CPU documents in `cpu/microblaze_v_h264/documentation/` |
| Drawings (PowerPoint and PNG) | `diagrams/out/`, `diagrams/out/png/`; sources in `diagrams/src/` |
| Ethernet demo (10/100/1000, DHCP, ARP, ping, UDP, lwIP TCP): board top, build, CPU, firmware and hardware tests | `boards/nexys_video/hdl/rtlnet_nexys_video_eth_top.sv`, `boards/nexys_video/scripts/build_ethernet.ps1`, `cpu/microblaze_v_ethernet/` (guide `cpu/microblaze_v_ethernet/documentation/rtlnet_cpu_eth.md`, tests `cpu/microblaze_v_ethernet/test/`) |
| Board test scripts and their output | scripts in `boards/nexys_video/scripts/`; transcripts and captures in `boards/nexys_video/build/` (names in `boards/nexys_video/README.md`) |
| License | `LICENSE.md` |

## Folders

| Folder | Contents |
|---|---|
| `cores/` | the board-independent cores above, each with `hdl/`, `driver/`, `testbench/`, `documentation/`; it targets no board |
| `boards/` | Nexys Video in `boards/nexys_video/` (Ethernet and media) and Arty A7-100T in `boards/arty_a7_100/` (Ethernet). Each board has its own top, constraints, scripts and board guide |
| `cpu/` | one folder per CPU, each independent with its own block design, driver, firmware, CLI, tests and documents; today `cpu/microblaze_v_h264/` (the MicroBlaze V CPU of the H.264 demos: block design, driver, documents, and the firmware with CLI, lwIP application and host tests; written for the Nexys Video today) and `cpu/microblaze_v_ethernet/` (the board-independent MicroBlaze V of the Ethernet demo: no DDR3, no caches, no video; firmware, CLI, host tests and hardware tests shared by every board) |
| `demos/` | released demonstration bitstreams, one folder per demo with `release.txt` and the license of a time-limited demo (`demos/LICENSE_DEMO.md`) |
| `scripts/` | simulation runner, regression, synthesis/timing checks, CDC constraints, Vivado launcher, name check, tool discovery (`rtlnet_tools.ps1`) |
| `documentation/` | `rtlnet_architecture.md` (the system contract: stream and register conventions, address map, port lists), `rtlnet_contributing.md` (rules and repository layout rules), `rtnet_specification.md` and its PDF |
| `diagrams/` | sources (`src/`) and renderings (`out/`) of the drawings |
| `LICENSE.md` | the RTLNet source-available license |

## Repository layout rule

All work is committed on `main`. The folders keep board-independent code apart from a board:

- `cores/` is board-independent. It does not depend on `boards/`, `cpu/` or `demos/`, and the regression of the
  cores runs with those folders absent.
- Each board has one folder under `boards/`; board-specific files (top, constraints, MIG project file, build and test
  scripts) live there.
- Released images are only under `demos/`; no build output is tracked in git.

Published board measurements identify the Nexys Video or Arty A7-100T image and negotiated link speed. The rules are in
`documentation/rtlnet_contributing.md` section 8.

## Conventions

- **Language:** all RTL and benches are SystemVerilog-2012 (`.sv`). Drivers and firmware are C11.
- **Buses:** a common 64-bit AXI4-Stream data bus (`tdata`/`tkeep`/`tlast`) and AXI4-Lite control.
  Every core has an ID/VERSION/CAPS register header.
- **Portability:** the technology is selected in `rtlnet_technology.svh` (AMD default). RAM and shift registers
  go through the common wrappers, so a retarget changes only those files.
- **Timing:** check post-route setup and hold slack for the chosen board. Nexys RGMII supports up to 1 Gb/s and Arty MII up to 100 Mb/s.

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

The media demos use the receiver from IronCapture and the encoder from IronH264. The exact revisions are in media-sources.json. Run scripts/resolve_media.ps1 with -IronCapture and -IronH264 pointing to the respective checkouts before running the media regressions. The resolver links these checkouts under ip/.
