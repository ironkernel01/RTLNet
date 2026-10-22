# RTLNet Ethernet Stack — System Architecture

| Item | Value |
|---|---|
| Product line | IronKernel RTLNet |
| Document revision | 10-22-2026 |
| First target | Digilent Nexys Video (Artix-7 XC7A200T-1SBG484C, Realtek RTL8211E RGMII PHY) |
| Toolchain | Vivado 2025.2 (synthesis, implementation), Aldec Active-HDL 11.1 (simulation), MicroBlaze GCC 13.3 |
| Languages | SystemVerilog-2012 for all RTL and benches (`.sv`), C11 for drivers and firmware |

This document is the contract every RTLNet core is built against. A core that follows it can be dropped into
any RTLNet carrier, retargeted to another FPGA vendor, and widened from the 1G MAC to a 10G/25G MAC without
touching the protocol layer.

---

## 1. Scope

The first RTLNet build is an RTL Ethernet/IPv4 stack on the Nexys Video. It contains no TCP and no software
network stack: every protocol runs in logic, and the CPU only configures and monitors.

| Function | Core | Notes |
|---|---|---|
| 10/100/1000 Mb/s MAC, RGMII | `rtlnet_eth_mac` | full duplex, FCS insert/check, pad, IFG, store-and-forward queues |
| PHY management | `rtlnet_mdio` | bit-banged Clause 22 MDIO from a GPIO register core; the C driver is the MDIO master |
| Protocol wrapper | `rtlnet_eth_protocol` | destination-MAC filter, ingress/egress packet queues, leaf fan-out, arbiter, local address registers |
| ARP responder | `rtlnet_arp` | RFC 826 replies for the local IPv4 address |
| ICMP echo (ping) | `rtlnet_icmp` | RFC 792 echo reply, payload up to 1472 bytes |
| DHCP client | `rtlnet_dhcp` | RFC 2131 DISCOVER/OFFER/REQUEST/ACK, renew, lease loss |
| iperf 2 UDP server | `rtlnet_iperf` | `iperf -c <board> -u` with server report; `-R` reverse stream |
| UDP socket layer | `rtlnet_udp_socket` | N bound ports, payload streams to and from applications |
| UDP echo server | `rtlnet_udp_echo` | application on the socket payload streams: returns every datagram to its sender |
| Frame filter/classifier | `rtlnet_classifier` | **designed, not built yet** (section 13) |
| CPU core | `rtlnet_cpu_microblaze` | MicroBlaze block design behind a vendor-neutral core port list; replaceable by a Nios V / RISC-V core with the same ports |
| Board top | `boards/nexys_video/hdl/rtlnet_nexys_video_top.sv` | the Nexys Video "Top.sv": clocks, resets, pins, CPU core, address decode, LEDs |

Hardware test constraint (10-22-2026): the board is cabled to a 10/100 router. 10 and 100 Mb/s are tested on
hardware; 1000 Mb/s is built, simulated and constrained, and is hardware-tested when a gigabit switch is fitted.

---

## 2. Repository layout

Every core has exactly four sub-folders:

```
cores/<core>/hdl            synthesizable RTL
cores/<core>/driver         C driver: the one file that owns this core's registers (<core>.h, <core>.c)
cores/<core>/testbench      self-checking Active-HDL benches, filelists
cores/<core>/documentation  core guide: interface, register map, design, verification record
```

```
RTLNet/
  documentation/                  system documents (this file)
  cores/
    rtlnet_common/                shared primitives (RAM core, FIFOs, synchronizers, AXI-Lite plumbing)
    rtlnet_eth_mac/               10/100/1000 RGMII MAC
    rtlnet_mdio/                  MDIO GPIO core + Clause 22 / RTL8211E driver
    rtlnet_eth_protocol/          protocol wrapper
    rtlnet_arp/  rtlnet_icmp/  rtlnet_dhcp/  rtlnet_iperf/
    rtlnet_udp_socket/  rtlnet_udp_echo/
    rtlnet_classifier/            documentation only until it is built
    rtlnet_cpu_microblaze/        CPU core: MicroBlaze block design Tcl + SystemVerilog wrapper; bus-functional model
  boards/nexys_video/             board top ("Top.sv"), XDC, build scripts, board bench
  firmware/nexys_video/           MicroBlaze CLI application (start-up, UART, menu, commands)
  scripts/                        shared simulation and constraint scripts
```

Generated output (Vivado runs, Active-HDL work directories, firmware objects, bitstreams) is never committed;
release bitstreams go in `releases/`.

---

## 3. Coding rules

The rules are those of the FPGA coding guide and the embedded C guide that govern this work. The points that
recur in every RTLNet file:

- **SystemVerilog.** Every RTL and bench file is SystemVerilog-2012 (`.sv`); synthesizable code keeps to the
  subset every FPGA and ASIC synthesis tool accepts (`logic`, `always_ff`, `always_comb`, packages, `localparam`,
  functions; no classes, no interfaces in synthesizable ports).
- **Vendor neutral.** Generic cores contain no vendor primitive, no vendor macro and no vendor-only attribute
  used for function. Vendor-specific circuits live in the mapped files of section 8, which take the
  technology from the single include file `rtlnet_technology.svh` (default AMD); no technology parameter is
  passed between cores. The MicroBlaze block design is the one AMD-only block, and it is hidden inside the CPU core.
- **Naming.** Module and file names are `rtlnet_<name>`; ports are lowercase with an interface-role prefix
  (`s_axis_*`, `m_axis_*`, `s_axi_*`, `rgmii_*`, `eth_*`) and direction is carried by `input`/`output`.
  AXI signal names follow the AMBA spelling so vendor tools infer the interfaces. Constants are `ALL_CAPS`,
  FSM states `S_*` localparams.
- **Active-low marker.** The trailing `n` of the AMBA convention, uniformly: `aresetn`, `resetn`, `arstn`,
  `eth_rst_n` at the top. No `_b` suffixes inside RTLNet (board XDC pin names keep their vendor spelling).
- **Resets.** Synchronous, active-low reset in every ordinary process. The only asynchronous-assert processes
  are inside `rtlnet_reset_sync` (named exception). External resets enter through it.
- **Clocked blocks use `<=` only.** Sequential logic is `always_ff`, combinational logic `assign` or `always_comb`.
- **FSMs.** One registered state variable, one clocked process, `S_*` localparams, a `default` that recovers.
- **Port groups.** Every port list is split into commented groups (clock domain, protocol, polarity, width
  contract). Board tops name the ball, net, I/O standard and bank in the group comment.
- **Header block.** Every file starts with a header: purpose, behaviours, clocks, revision as a `MM-DD-YYYY`
  date code with a change list, language version.
- **No company names.** RTLNet sources, comments, docs and commit messages name no other company or client.
  Silicon and tool vendors (AMD/Xilinx, Intel/Altera, Lattice, Realtek, Digilent) are named only where a part
  or tool is meant.

---

## 4. The common stream bus

Every data path between RTLNet cores is the **RTLNet stream**: AXI4-Stream with 64-bit `tdata`, the width the
10G/25G MAC needs (one beat per 156.25 MHz clock at 10G, 390.625 MHz at 25G). The 1G MAC uses the same bus at
62.5 MHz. The protocol layer therefore runs unchanged on any of the three MACs.

| Signal | Width | Rule |
|---|---|---|
| `tdata` | 64 | frame byte 0 in `tdata[7:0]`, byte 1 in `[15:8]` ... byte 7 in `[63:56]`; beat `k` holds bytes `8k..8k+7` |
| `tkeep` | 8 | every non-final beat `8'hFF`; the final beat contiguous from bit 0 (`01,03,07,0F,1F,3F,7F,FF`) |
| `tlast` | 1 | marks the final beat; frames are delivered whole or not at all |
| `tvalid`/`tready` | 1 / 1 | AXI4-Stream handshake; data held stable while `tvalid && !tready` |
| `tuser`, `tid`, `tdest` | — | not used: an errored frame is dropped, not flagged |

Frame content at the MAC client boundary: destination MAC through the last payload or pad byte. No preamble,
no SFD, no FCS. The MAC pads short transmit frames to 60 bytes and keeps receive padding. Multi-byte network
fields are big-endian on the wire, so a 16-bit field at an even frame offset `2m` sits in lanes `2m mod 8`
(high byte) and `2m+1 mod 8` (low byte); cores use the shared `be16/be32/be48` helpers of `rtlnet_pkg`.

Throughput rule: `64 bits x f_clk` must exceed the line rate. 1G: `f >= 31.25 MHz` (62.5 MHz used).
10G: 156.25 MHz. 25G: 390.625 MHz.

The stream at the socket/application boundary (section 7.7) is the same bus with two metadata beats ahead of
the payload; it is still a plain AXI4-Stream.

---

## 5. The common register bus

Control and status use **AXI4-Lite**, 32-bit data, single outstanding transaction, `wstrb` honoured as "all
or nothing" (a write with `wstrb != 4'hF` is ignored and still answered OKAY), all responses OKAY. Every core
exposes one `s_axi_*` slave with a 12-bit address (4 KiB window) unless stated.

Inside a core, `rtlnet_axil_slave` converts AXI4-Lite into a one-cycle write strobe and a one-cycle read
strobe; the core's register file answers `reg_rd_data` on the next clock (registered read mux).

When the register file lives in a clock other than the CPU's, the core puts `rtlnet_axil_cdc` in front of
its slave: the whole AXI4-Lite transaction crosses as a held bundle with a toggle request and a toggle
acknowledge, so each register file is a plain single-clock block.

Standard header, every core:

| Offset | Name | Access | Content |
|---:|---|---|---|
| 0x000 | `ID` | RO | 32-bit core code (four ASCII characters, e.g. `"MAC1"` = `0x4D414331`) |
| 0x004 | `VERSION` | RO | date code of the register map revision as `0xMMDDYYYY` hex digits (10-22-2026 = `0x10222026`) |
| 0x008 | `CAPS` | RO | build parameters the driver needs (sizes, enables) |
| 0x00C... | core-specific | | `CTRL` at 0x00C and `STATUS` at 0x010 where the core has them |

Counters are 32-bit, wrap, and clear through a `CNT_CLEAR` pulse bit. Self-clearing pulse bits read 0.
Undefined offsets read 0 and ignore writes. Register offsets and bit positions live once, in the core's
driver header, mirrored by `localparam`s in its register file with a pointer comment to the header.

---

## 6. System block diagram

```
                 Nexys Video
  100 MHz osc --> MMCM (board top): clk125, clk125_90, clk200, axis_clk 62.5, proto_clk 50, cpu_clk 100
                                                                                       |
   USB-UART <--> +------------- rtlnet_cpu_microblaze (CPU core, cpu_clk) ------------+
   JTAG    <-->  |  MicroBlaze, 128 KiB LMB BRAM, MDM (debug), AXI UART Lite 115200, |
                 |  AXI Timer, AXI interconnect, M_AXI_RTLNET exported (AXI4-Lite)  |
                 +-------------------------------------------------------------------+
                                     | AXI4-Lite, cpu_clk
                          rtlnet_axil_decoder (board top)
        +-----------+-----------+-------------+-----------------------------+------------+
        | SYS       | MAC       | MDIO        | PROTOCOL (64 KiB window)    | UDP ECHO   |
        v           v           v             v                             v
   board regs  rtlnet_eth_mac  rtlnet_mdio  rtlnet_eth_protocol            rtlnet_udp_echo
               (RGMII pins)    (MDC/MDIO,    | filter, queues, arbiter      ^      |
                   |  ^         PHY reset)   | ARP ICMP DHCP iperf UDP-sock |      |
                   |  |                      |   payload streams ----------+------+
                   v  |                      v
              m_axis_rx --> [classifier, future] --> s_axis (protocol) ; m_axis (protocol) --> s_axis_tx
```

### 6.1 Address map

MicroBlaze sees the RTLNet window at `0x44A0_0000`, 1 MiB. Offsets inside the window:

| Offset | Size | Block | Clock of its register file |
|---:|---:|---|---|
| 0x0_0000 | 4 KiB | board system registers (`ID`, `VERSION`, build id, LEDs, switches, buttons) | cpu_clk |
| 0x0_1000 | 4 KiB | `rtlnet_eth_mac` | axis_clk (through `rtlnet_axil_cdc`) |
| 0x0_2000 | 4 KiB | `rtlnet_mdio` | cpu_clk |
| 0x0_3000 | 4 KiB | `rtlnet_udp_echo` | app clock (through `rtlnet_axil_cdc`) |
| 0x1_0000 | 64 KiB | `rtlnet_eth_protocol` (sub-map below) | proto_clk (one `rtlnet_axil_cdc`, then an internal decoder) |
| 0x2_0000 | 4 KiB | `rtlnet_classifier` (reserved) | axis_clk |

Protocol sub-map (offset inside 0x1_0000):

| Offset | Block |
|---:|---|
| 0x0000 | wrapper: local MAC, static IP, effective IP, netmask, gateway, filter mode, ingress counters, leaf enables |
| 0x1000 | ARP |
| 0x2000 | ICMP |
| 0x3000 | DHCP |
| 0x4000 | iperf |
| 0x5000 | UDP socket layer |

Other MicroBlaze peripherals sit in the block design's own map (UART Lite `0x4060_0000`, Timer
`0x41C0_0000`, MDM `0x4140_0000`, LMB BRAM `0x0000_0000`).

---

## 7. Cores

### 7.1 `rtlnet_common`

| Module | Role |
|---|---|
| `rtlnet_pkg.sv` | stream constants, EtherTypes, IP protocol numbers, `be16/be32/be48`, `keep_bytes`, `keep_mask`, CRC-32 byte and word functions, ones'-complement helpers, default MAC/IP |
| `rtlnet_technology.svh` | the single technology selection include (section 8) |
| `rtlnet_ram_core.sv` | the generic RAM (section 8) |
| `rtlnet_sync.sv` | level synchronizer, N stages, every vendor's attributes |
| `rtlnet_reset_sync.sv` | asynchronous-assert, synchronous-release reset synchronizer (the named exception) |
| `rtlnet_pulse_sync.sv` | toggle-based single-event crossing |
| `rtlnet_gray_sync.sv` | Gray-coded counter crossing, used for counters read in another clock |
| `rtlnet_axis_reg_slice.sv` | AXI4-Stream register slice, all outputs registered |
| `rtlnet_packet_fifo.sv` | dual-clock store-and-forward whole-frame FIFO, size in KiB, RAM through `rtlnet_ram_core` |
| `rtlnet_frame_guard.sv` | length and `tkeep` legality check feeding a packet FIFO |
| `rtlnet_axil_slave.sv` | AXI4-Lite to register-strobe bridge |
| `rtlnet_axil_cdc.sv` | AXI4-Lite clock-domain crossing (held bundle, toggle request/acknowledge) |
| `rtlnet_axil_decoder.sv` | one AXI4-Lite master to N slaves by address window |

### 7.2 `rtlnet_eth_mac` — 10/100/1000 RGMII MAC

```
eth_rxc -> rtlnet_rgmii_io_<target> -> GMII byte + ce (rx_clk) -> rtlnet_gmii_rx (SFD, CRC, strip FCS, 8->64)
        -> rx frame guard (min 60) -> RX packet FIFO (rx_clk -> axis_clk, drop when full) -> m_axis_rx
s_axis_tx -> tx frame guard (min 14) -> TX packet FIFO (axis_clk -> clk125) -> rtlnet_gmii_tx (preamble,
        pad 60, FCS, IFG; byte clock enable) -> rtlnet_rgmii_io_<target> -> eth_txc/txd/txctl
```

- One set of byte-level modules runs all three speeds through a byte clock enable; the pin layer converts
  RGMII DDR (1000) or one nibble per clock (10/100) to bytes, aligning 10/100 on the SFD.
- **The MAC speed is a register written by firmware** from the PHY status read over MDIO (PHYSR). The MAC never
  takes speed from RGMII in-band status (kept as a debug register only).
- An RXC rate detector qualifies the firmware speed: the receive side is held in reset until RXC is measured in
  the band of the selected speed and the delay controller is ready. A speed change resets the receive path.
- Registers in `axis_clk`: `CTRL` (TX/RX enable, speed, software reset, promiscuous debug), `STATUS` (RXC
  present, measured RXC rate, in-band link/speed, delay ready), frame counters (RX good, RX bad, RX overflow,
  TX frames), `RX_DELAY_TAP` readback.
- Pin-layer timing: PHY RX delay on (set by the MDIO driver), FPGA TX skew from a 90-degree `clk125_90`.

### 7.3 `rtlnet_mdio` — PHY management by bit-banged MDIO

The RTL is a GPIO register core: `MDC` output, `MDIO` output data and output enable, `MDIO` input through a
3-stage synchronizer, the PHY reset output and the PHY interrupt input. The board top owns the MDIO tri-state
buffer. The C driver is the MDIO master:

- `rtlnet_mdio.c`: Clause 22 frame engine (32-bit preamble, ST, OP, PHYAD, REGAD, TA, 16 data bits, idle slot),
  MDC half-period from a calibrated delay loop, read/write, PHY hardware reset sequence (10 ms low + 30 ms
  settle, with margin).
- `rtlnet_phy_rtl8211e.c`: ID check (0x001C/0xC915), RX-delay enable (page 0xA4 register 28, read-modify-write
  of bits 13/11, readback), auto-negotiation enable/restart, advertisement selection (10/100/1000, half/full),
  forced speed, status decode from BMSR/PHYSR, loopback, register dump.

The CLI uses the driver to report link, speed, duplex and partner abilities, to configure advertisement and
forced speed, and to keep the MAC speed register in step with PHYSR.

### 7.4 `rtlnet_eth_protocol` — protocol wrapper

Two clocks: `axis_clk` (MAC client, scales to 156.25/390.625 MHz) and `proto_clk` (the leaves, 50 MHz on the
Nexys Video). Only the input slice, the destination-MAC filter, the ingress queue write side and the egress
queue read side run on `axis_clk`. Everything else is `proto_clk`.

```
s_axis (axis_clk) -> slice -> filter (local MAC | broadcast | promiscuous) -> ingress packet FIFO
  -> dequeue controller (gap, wait-not-busy, pass) -> fan-out to every leaf (proto_clk)
  -> leaf replies -> arbiter (fixed priority, per frame) -> slice -> egress packet FIFO -> m_axis (axis_clk)
```

The wrapper owns the node's address: `LOCAL_MAC` and `STATIC_IP` registers; the effective IP is the DHCP lease
while one is held, else the static IP. The address is a `proto_clk` register, so leaves read it with no
crossing; only the filter's copy of the MAC crosses into `axis_clk` (level synchronizer plus a two-sample
stability filter). Ingress counters (filtered, queued, dropped) count in `axis_clk` and reach the register file
through `rtlnet_gray_sync`.

### 7.5 The leaf contract

Every protocol leaf (ARP, ICMP, DHCP, iperf, UDP socket) is a `proto_clk` module with:

| Port group | Ports | Rule |
|---|---|---|
| clock, reset | `clk`, `resetn` | `proto_clk`, synchronous active low |
| frame in | `s_axis_t*` (RTLNet stream) | `s_axis_tready` is held 1: a leaf never stalls the fan-out |
| frame out | `m_axis_t*` (RTLNet stream) | output of one `rtlnet_axis_reg_slice`; a started frame completes without gaps |
| address | `local_mac[47:0]`, `local_ip[31:0]` | `proto_clk` registers from the wrapper; MAC octet 0 in `[47:40]`, IP first octet in `[31:24]` |
| status | `busy` | registered; rises within 12 clocks of the last beat of any frame the leaf acts on, held until it can take a new frame |
| registers | `reg_wr_en`, `reg_wr_addr[11:0]`, `reg_wr_data`, `reg_rd_en`, `reg_rd_addr[11:0]`, `reg_rd_data` | the wrapper's internal register bus (already in `proto_clk`); read data valid the clock after `reg_rd_en` |
| enable | `enable` | from the wrapper's leaf-enable register; a disabled leaf ignores frames and sends nothing |

The wrapper guarantees one frame at a time, at least 16 idle clocks after each frame, and no frame while any
leaf is busy. A leaf is still self-protecting: a frame that starts while it is not idle is ignored whole.

Arbiter priority: UDP socket, ICMP, ARP, DHCP, iperf.

### 7.6 Protocol leaves

| Leaf | Accepts | Sends | Buffers |
|---|---|---|---|
| ARP | EtherType 0x0806, Ethernet/IPv4, request for the local IP | 42-byte unicast reply | none |
| ICMP | IPv4 (IHL 5), protocol 1, echo request to the local IP, good ICMP checksum | echo reply | payload RAM, `ICMP_BUF_KB` (default 2) |
| DHCP | UDP 67 -> 68, BOOTP reply for the local MAC and current `xid` | 342-byte DISCOVER/REQUEST | receive RAM, `DHCP_BUF_KB` (default 1) |
| iperf | UDP to `IPERF_PORT` (5001) | 170-byte server report; `-R` stream | none |
| UDP socket | UDP to an enabled socket's local port | datagrams from the application | RX and TX payload packet FIFOs, `UDP_RX_BUF_KB`, `UDP_TX_BUF_KB` |

Registers per leaf: enable, counters of frames accepted, answered and dropped, and the leaf's own controls
(ARP reply delay; DHCP request/renew/release, lease result, state; iperf statistics and port; socket table).

### 7.7 `rtlnet_udp_socket` and the application stream

`NUM_SOCKETS` (default 4) sockets. Each socket register set: `CTRL` (enable, connect-on-receive), `LOCAL_PORT`,
`REMOTE_IP`, `REMOTE_PORT`, `REMOTE_MAC` (high/low), counters (RX datagrams, RX drops, TX datagrams).

Receive: a frame for the local IP (IPv4, IHL 5, not a fragment, protocol 17) whose destination port matches an
enabled socket has its payload realigned to byte 0 and written, with two metadata beats, into the RX payload
FIFO (dual clock, `proto_clk` to `app_clk`). A datagram that does not fit is dropped and counted. With
connect-on-receive set, the socket's remote IP, port and MAC follow the last datagram received.

Transmit: the application writes two metadata beats and the payload into the TX payload FIFO (`app_clk` to
`proto_clk`); the layer builds Ethernet, IPv4 and UDP headers (IP checksum computed, UDP checksum 0 = none per
RFC 768) and sends the datagram.

Application stream (both directions), RTLNet stream format:

| Beat | `tdata[63:32]` | `tdata[31:16]` | `tdata[15:0]` |
|---|---|---|---|
| meta 0 | remote IPv4 address (first octet in [63:56]) | remote UDP port | payload length in bytes |
| meta 1 | `[63:56]` socket index, `[55:48]` flags, `[47:0]` remote MAC (octet 0 in [47:40]) | | |
| payload | payload bytes, byte 0 in `[7:0]`, `tkeep` on the last beat, `tlast` | | |

Transmit flag bit 0 `USE_SOCKET_REMOTE`: ignore the remote fields of the metadata and use the socket's
registers. A zero-length datagram is two metadata beats with `tlast` on meta 1.

### 7.8 `rtlnet_udp_echo`

An application on the socket streams: every datagram received on the selected socket (or any socket) is sent
back with the metadata unchanged, so it returns to its sender. Registers: enable, socket select/any, counters
(echoed, dropped while disabled). Runs on `app_clk` (the Nexys Video uses `proto_clk`).

---

## 8. Vendor targeting

**One include file selects the technology for the whole tree:**
`cores/rtlnet_common/hdl/rtlnet_technology.svh`. It defines exactly one of `RTLNET_TECH_AMD` (default),
`RTLNET_TECH_ALTERA`, `RTLNET_TECH_LATTICE`, `RTLNET_TECH_GENERIC`, chosen by a tool command-line define
(`+define+RTLNET_TECH_ALTERA`) or by changing its default branch, and derives:

| Macro | Use |
|---|---|
| `` `RTLNET_TARGET `` | technology string read by `rtlnet_ram_core` |
| `` `RTLNET_SYNC_ATTR `` | attribute instance on every synchronizer register (no merge, no SRL packing, placed together) |
| `` `RTLNET_RGMII_IO `` | RGMII pin-layer module for the family, instanced by the MAC |

No core takes a technology parameter and none is passed down the hierarchy. Only per-buffer choices are
parameters: `RAM_STYLE` and the `*_KB` sizes.

| Mapped file | AMD implementation | Other technologies |
|---|---|---|
| `rtlnet_ram_core` | direct instance of `xpm_memory_sdpram` (`MEMORY_PRIMITIVE` = `"block"` or `"distributed"`) | Altera: inferred array, `ramstyle` M20K / MLAB; Lattice: inferred array, `syn_ramstyle` block_ram / distributed; GENERIC/ASIC: behavioural model, replaced by a compiled-macro wrapper |
| `rtlnet_sync`, `rtlnet_reset_sync`, `rtlnet_gray_sync`, packet FIFO pointers | `ASYNC_REG`, `SHREG_EXTRACT="NO"`, `DONT_TOUCH` | Quartus synchronizer identification + preserve; Synplify `syn_preserve`, `syn_srlstyle="registers"`; ASIC library attributes when the back-port starts |
| `rtlnet_rgmii_io_<family>` | `rtlnet_rgmii_io_amd7.sv`: IDELAYE2, IDDR, ODDR, BUFIO, BUFR, IDELAYCTRL | one file per family with the same ports (Intel GPIO DDR, Lattice IDDRX1F/ODDRX1F, generic behavioural) |
| MMCM, IOBUF | board top only | per board |

`rtlnet_ram_core` interface (simple dual port, common or independent clocks, synchronous read, output
register(s) with synchronous active-low reset):

| Parameter | Meaning |
|---|---|
| `RAM_STYLE` | `"block"` (default) or `"distributed"` |
| `DATA_W`, `ADDR_W` | word width and address bits (depth `2**ADDR_W`) |
| `READ_LATENCY` | 1 (default) or 2 |
| `CLOCKING` | `"COMMON"` or `"INDEPENDENT"` |

Every buffer in a core states its size as a total-kilobyte parameter (`*_BUF_KB`, `*_FIFO_KB`); the core
derives the depth from it and stops elaboration with `$fatal` on a size it cannot build.

## 9. Clocks and resets (Nexys Video)

| Clock | Source | Frequency | Domain contents |
|---|---|---|---|
| `sys_clk` | 100 MHz oscillator R4 | 100 MHz | MMCM input only |
| `clk125` | MMCM CLKOUT0 | 125 MHz | MAC TX byte engine, TX FIFO read, RGMII TX ODDRs, RXC rate detector |
| `clk125_90` | MMCM CLKOUT1, 90 deg | 125 MHz | TXC forwarding ODDR and its retiming flops only |
| `clk200` | MMCM CLKOUT2 | 200 MHz | IDELAYCTRL reference |
| `axis_clk` | MMCM CLKOUT3 | 62.5 MHz | MAC client side and registers, protocol filter, queue fast sides |
| `proto_clk` | MMCM CLKOUT4 | 50 MHz | protocol leaves, wrapper registers, socket layer, UDP echo |
| `cpu_clk` | MMCM CLKOUT5 | 100 MHz | MicroBlaze subsystem, AXI4-Lite decoder, MDIO core, system registers |
| `rx_clk` | PHY RXC via BUFR | 125 / 25 / 2.5 MHz | MAC receive engine, RX FIFO write; stops on link loss |

One external reset (`cpu_resetn` button AND `mmcm_locked`) enters `rtlnet_reset_sync` once per domain. Packet
FIFOs require both sides to reset together; every FIFO's two resets derive from one assertion.

Every crossing is one of: `rtlnet_packet_fifo` (Gray frame counters), `rtlnet_sync`, `rtlnet_pulse_sync`,
`rtlnet_gray_sync`, `rtlnet_axil_cdc`, `rtlnet_reset_sync`. `scripts/rtlnet_constrain_cdc.tcl` finds each by
instance/cell name and bounds it (`set_max_delay -datapath_only` of the source period plus `set_bus_skew` for
Gray and bundle crossings, first-stage false paths for level synchronizers, reset-pin false paths). No blanket
asynchronous clock groups.

---

## 10. CPU core and firmware

The processor is a core like any other, `rtlnet_cpu_microblaze`, instanced in the board top. Its port list is
vendor neutral so another soft or hard processor drops in with a wrapper of the same ports:

| Port group | Ports |
|---|---|
| clock, reset | `clk` (cpu_clk, 100 MHz), `resetn` (synchronous, active low) |
| console | `uart_rxd` (from the USB-UART bridge), `uart_txd` (to it) |
| register master | `m_axi_*` AXI4-Lite master, 32-bit address and data, into `rtlnet_axil_decoder` |
| interrupts | `irq[7:0]` level inputs (PHY interrupt, DHCP event, ...) |
| status | `cpu_reset_out_n` (processor-side reset request, for debug) |

`rtlnet_cpu_microblaze.sv` wraps the block design `rtlnet_cpu` (Tcl-generated from
`cores/rtlnet_cpu_microblaze/hdl/rtlnet_cpu_bd.tcl`): MicroBlaze (little endian, 32-bit, no MMU, hardware
multiplier/divider/barrel shifter), 128 KiB LMB BRAM, MDM (JTAG debug), AXI UART Lite (115200 8N1), AXI Timer,
AXI interconnect, the exported AXI4-Lite master and an interrupt controller. A Nios V core would be
`rtlnet_cpu_niosv.sv` around a Platform Designer system with the same ports; the RTL below the decoder does
not change. `cores/rtlnet_cpu_microblaze/testbench/rtlnet_cpu_bfm.sv` has the same ports and drives scripted
AXI4-Lite transactions for the board bench.

Firmware (`firmware/nexys_video`) is freestanding C11 built with `mb-gcc` (own start-up, linker script, no
vendor BSP); the ELF is merged into the bitstream BRAM with `updatemem`. Layers:

| Layer | Files | Owns |
|---|---|---|
| start-up | `crt0.S`, `rtlnet_fw.ld` | vectors, stack, `.bss` clear, `main` |
| platform | `uart.c`, `timer.c`, `mmio.h` | UART Lite, AXI timer, register access |
| drivers | `cores/<core>/driver/*.c` | one file per core, the only code that touches that core's registers |
| CLI | `menu.c`, `menu.h` (MenuBuilder rules), `cli_commands.c` | command parsing and help; no register access |
| application | `main.c`, `netmgr.c` | link monitor (MDIO poll, MAC speed follow), DHCP start on link-up |

CLI command families: `HELP`/`?`, `SYS INFO`, `PHY STATUS|DUMP|READ|WRITE|RESET|AUTONEG|SPEED|ADVERTISE`,
`MAC STATUS|COUNTERS|SPEED|CLEAR`, `NET SHOW|IP|MAC|GW|MASK`, `DHCP START|STATUS|AUTO`, `ARP STATUS`,
`ICMP STATUS`, `IPERF STATUS|PORT`, `SOCK SHOW|OPEN|CLOSE`, `ECHO STATUS|ON|OFF`.

---

## 11. Verification

- Simulator: Aldec Active-HDL 11.1 batch (`vsimsa`, `alog -sv2k12`, `asim`), one seat, serialized by the
  runner's lock. Runner `scripts/rtlnet_run_sim.ps1 -Bench <tb> -Filelist <core>/testbench/<tb>.f`. The AMD
  XPM and UNISIM sources are compiled in place from the Vivado install into `.sim/xlib` on first use.
- Every bench is self-checking and ends with exactly one anchored line `TEST PASS: <bench> checks=<n>` or
  `TEST FAIL: <bench> ...`. The runner fails on a missing pass token (crash, timeout, elaboration error).
- `+INJECT_FAILURE` forces a failure; each bench is run once with it and must report `TEST FAIL`.
- Oracles are independent of the RTL: a bit-serial CRC-32, an RFC 1071 checksum, bench-built expected frames.
- Leaf benches include the shared busy-rule monitor.
- Board bench: the real board top (MicroBlaze replaced by an AXI4-Lite bus-functional model) against an RTL8211E
  RGMII/MDIO model at 10, 100 and 1000 Mb/s.

Hardware: Vivado batch build with exit-code gates (synthesis, timing setup and hold, CDC report, utilization),
JTAG programming, CLI over COM port, host tests from the PC (`arping`, `ping -l` sweep, `iperf -c -u`,
UDP echo client script), all at 10 and 100 Mb/s until a gigabit partner is available.

---

## 12. Scaling to 10G/25G

The protocol wrapper, every leaf, the socket layer and the applications use only the RTLNet stream and
`proto_clk`; the MAC side of the wrapper is `axis_clk`. Moving to a 10G/25G MAC changes the MAC instance and
the `axis_clk` frequency (156.25 / 390.625 MHz); the wrapper's `axis_clk` logic is limited to one or two LUT
levels per stage for that reason. `proto_clk` throughput (64 x 50 MHz = 3.2 Gb/s on Artix-7) bounds the
leaves; a 10G build raises `proto_clk` or widens the leaf fan-out, which is a parameter change, not a
re-architecture.

---

## 13. `rtlnet_classifier` (designed, built later)

A pass/drop filter of whole frames on the MAC receive stream, between `rtlnet_eth_mac.m_axis_rx` and
`rtlnet_eth_protocol.s_axis` (`axis_clk`). It compares the first 64 bytes of a frame against value/mask rules
(`((data ^ value) & mask) == 0` per bit), one-hot rule select, fail-closed when enabled with no rule, ROM or RAM
rule table (the RAM through `rtlnet_ram_core`), store-and-forward data FIFO plus a verdict FIFO, AXI4-Lite rule
programming and per-rule counters crossed by snapshot handshake. Address window 0x2_0000. Until it is built the
two streams connect directly.

---

## 14. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial architecture; all RTL in SystemVerilog; CPU as a replaceable core; one technology include file; Active-HDL simulation |
