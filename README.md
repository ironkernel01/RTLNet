# IronKernel RTLNet

An Ethernet/IPv4 stack in SystemVerilog, with an optional soft-CPU network path that runs lwIP for TCP. The
first target is the Digilent Nexys Video (Artix-7 XC7A200T-1SBG484C, Realtek RTL8211E RGMII PHY).

The RTL protocols (ARP, ICMP, DHCP, UDP, iperf UDP) run at line rate in logic. Frames the RTL does not claim go
to a MicroBlaze over AXI DMA. On the MicroBlaze, lwIP serves TCP echo and TCP iperf, with hardware checksum
offload on the DMA streams.

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

The full simulation regression (Active-HDL) passes 76/76. Details and the full measurement tables are in
`microblaze/documentation/rtlnet_cpu_microblaze.md` and `boards/nexys_video/documentation/rtlnet_nexys_video.md`.

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

Other folders:

| Folder | Contents |
|---|---|
| `microblaze/` | CPU core (block design Tcl, core wrapper, simulation stub) and firmware: CLI, lwIP glue in `firmware/src/lwip/`, TCP echo, TCP iperf (`rtlnet_lwiperf`), network manager, host tests |
| `boards/nexys_video/` | Board top, constraints, board benches, build/program/test scripts and the board guide |
| `documentation/` | `rtlnet_architecture.md` (the system contract: stream and register conventions, address map, port lists) and `rtlnet_contributing.md` (rules) |
| `scripts/` | Simulation runner, regression, synthesis/timing checks, CDC constraints, Vivado launcher, name check |

## Conventions

- **Language:** all RTL and benches are SystemVerilog-2012 (`.sv`). Drivers and firmware are C11.
- **Buses:** a common 64-bit AXI4-Stream data bus (`tdata`/`tkeep`/`tlast`, sized for a 10G/25G MAC) and AXI4-Lite control.
  Every core has an ID/VERSION/CAPS register header.
- **Portability:** the technology is selected in `rtlnet_technology.svh` (AMD default). RAM and shift registers
  go through the common wrappers, so a retarget changes only those files.
- **Timing:** at most two LUT levels per register stage, so the cores can scale to 10G/25G clock rates.
- **Discovery:** the firmware finds the optional blocks (classifier, transmit and receive checksum offload)
  through the protocol wrapper's `CPU_CAPS` bits. `InitLWIP()` configures lwIP from what the hardware reports.

## Tools

- AMD Vivado / Vitis 2025.2 (synthesis, implementation, MicroBlaze GCC, BSP)
- Aldec Active-HDL 11.1 (all simulation)
- lwIP 2.2.0 is compiled in place from the Vitis install. Only the RTLNet-specific files live in
  `microblaze/firmware/src/lwip/`.
- iperf 2.2.x on the PC for throughput tests

## Quick start

Run these from the repository root in PowerShell.

```powershell
# Full simulation regression (Active-HDL)
powershell -File scripts/rtlnet_regression.ps1

# Bitstream with the network stack, firmware merged into the bitstream
powershell -File boards/nexys_video/scripts/build.ps1 -Network

# Program the board over JTAG
powershell -File boards/nexys_video/scripts/program.ps1

# Hardware tests (board on the USB-UART CLI and a wired NIC)
powershell -File boards/nexys_video/scripts/cli_test.ps1
powershell -File boards/nexys_video/scripts/net_test.ps1 -Nic Ethernet -Speed 100
powershell -File boards/nexys_video/scripts/tcp_test.ps1
```

The CLI is on the board's USB-UART (115200 8N1). It is hierarchical, in a lightweight switch style; type `?`
for help.

## Status and open items

- Tested on hardware at 10 and 100 Mb/s. 1000 Mb/s is verified in simulation and waits for a gigabit link
  partner.
- Programming is JTAG only. Quad-SPI flash boot is not set up yet.

Copyright (C) 2026 IronKernel. lwIP-derived files keep the lwIP BSD license.
