# RTLNet Ethernet Stack — System Architecture

| Item | Value |
|---|---|
| Product line | IronKernel RTLNet |
| Ethernet reference boards | Digilent Nexys Video (Artix-7 XC7A200T, RTL8211E RGMII) and Arty A7-100T (Artix-7 XC7A100T, DP83848J MII) |
| Toolchain | Vivado 2026.1 (synthesis, implementation), Aldec Active-HDL 11.1 (simulation), MicroBlaze GCC 13.4 |
| Languages | SystemVerilog-2012 for all RTL and benches (`.sv`), C11 for drivers and firmware |

This guide describes the packet interfaces, register conventions and board integrations of RTLNet. The Ethernet-only images run the shared networking firmware from local RAM. The Nexys media image adds a DDR path and companion capture and encoder IP.

---

## 1. Scope

The Nexys Video and Arty A7-100T Ethernet designs implement the same RTL Ethernet/IPv4 stack. ARP, ICMP, DHCP, UDP and iperf UDP run
in logic. TCP runs in lwIP on the MicroBlaze through the CPU network path, with hardware checksum offload; the
CPU also configures and monitors the RTL.

| Function | Core | Notes |
|---|---|---|
| 10/100/1000 Mb/s MAC, RGMII | `rtlnet_eth_mac` | full duplex, FCS insert/check, pad, IFG, store-and-forward queues |
| 10/100 Mb/s MAC, MII | `rtlnet_eth_mac_mii` | Arty A7-100T, full duplex, separate MII receive and transmit clocks |
| PHY management | `rtlnet_mdio` | bit-banged Clause 22 and Clause 45 MDIO from a GPIO register core; the C driver is the MDIO master |
| Protocol wrapper | `rtlnet_eth_protocol` | destination-MAC filter, ingress/egress packet queues, leaf fan-out, arbiter, local address registers |
| ARP responder | `rtlnet_arp` | RFC 826 replies for the local IPv4 address |
| ICMP echo (ping) | `rtlnet_icmp` | RFC 792 echo reply, payload up to 1472 bytes |
| DHCP client | `rtlnet_dhcp` | RFC 2131 DISCOVER/OFFER/REQUEST/ACK, renew, lease loss |
| iperf 2 UDP server | `rtlnet_iperf` | `iperf -c <board> -u` with server report; `-R` reverse stream (RTL) |
| iperf 2 TCP server | firmware (`rtlnet_lwiperf`, the RTLNet copy of lwIP's iperf server, on lwIP) | `iperf -c <board>` on TCP port 5001 through the CPU network path; `-R`, `-r` and `-d` measure board -> PC |
| UDP socket layer | `rtlnet_udp_socket` | N bound ports, payload streams to and from applications |
| UDP echo server | `rtlnet_udp_echo` | application on the socket payload streams: returns every datagram to its sender |
| Frame filter/classifier | `rtlnet_classifier` | on the CPU receive path: configurable L2-L4 filter with policers, drop-all until configured, broadcast storm limiter at boot (section 13) |
| Checksum offload | `rtlnet_tcp_offload` | on the CPU DMA stream: inserts IPv4 / TCP / UDP checksums into frames the CPU sends (store-and-forward patch); checks them on frames the CPU receives and appends an 8-byte trailer beat with the result (cut-through) |
| CPU network path | `rtlnet_eth_protocol` CPU port + board-selected CPU subsystem | every frame no enabled leaf claims goes to the CPU (`cpu_axis_ethernet_stream`, AXI DMA); the CPU sends frames back the same way; lwIP runs a TCP echo server on it; the CPU-path classifier and the checksum offload sit on the two streams |
| Processor subsystem | Ethernet or media MicroBlaze V configuration | AXI DMA carries CPU-path frames. lwIP handles TCP echo and iperf 2. |
| Board integration | Nexys Video and Arty A7-100T | Board logic connects the PHY, clocks, resets, local memory and registers. |

Wired tests confirmed 10/100/1000 Mb/s operation on Nexys Video and 10/100 Mb/s on Arty. With the CPU-path firewall enabled on the gigabit Nexys link, UDP reached 942 Mb/s from PC to board and 944 Mb/s in reverse, with zero reported loss. The [product brief](rtlnet_product_brief.md) gives both boards’ throughput and the test conditions.

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
    rtlnet_eth_mac/               10/100/1000 RGMII and 10/100 MII MACs
    rtlnet_mdio/                  MDIO GPIO core + Clause 22/45 access and RTL8211E / DP83848 drivers
    rtlnet_eth_protocol/          protocol wrapper
    rtlnet_arp/  rtlnet_icmp/  rtlnet_dhcp/  rtlnet_iperf/
    rtlnet_udp_socket/  rtlnet_udp_echo/
    rtlnet_classifier/            configurable frame filter
    rtlnet_tcp_offload/           IPv4 / TCP / UDP checksum insert (TX) and check with trailer (RX) on the CPU path
    rtlnet_axi_arbiter/           N:1 AXI4 arbiter in front of the DDR3 controller (illegal-burst guard, per-master counters)
    rtlnet_ddr/                   DDR3 controller behind a vendor-neutral AXI4 slave (MIG IP generated from the board's project file)
    rtlnet_axi_cdc/               AXI clock-domain crossing for DDR clients
    rtlnet_vdma_s2mm/             stream-to-memory frame writer for the Nexys media design
    rtlnet_framebuf/              on-chip frame memory for the Ethernet DMA path
  ip/                             local bindings to the IronCapture receiver and IronH264 encoder
  media-sources.json              companion repositories, revisions and expected core trees
  cpu/microblaze_v_ethernet/      shared Ethernet firmware and processor subsystem
  cpu/microblaze_v_h264/          Nexys media firmware and processor subsystem
  boards/nexys_video/             RGMII Ethernet and DDR-backed media designs
  boards/arty_a7_100/             MII Ethernet design
  demos/                          published Ethernet and Nexys media images
  scripts/                        simulation, synthesis and dependency resolution
```

The Ethernet-only designs use local RAM. The Nexys media build uses IronCapture's internal color bars, a DDR frame writer and the IronH264 encoder to stream compressed video over Ethernet. Its external camera input is tied off. The physical-camera Linux reference belongs to IronForge. Run `scripts/resolve_media.ps1` to bind the companion cores before building a media image.

Generated output (Vivado runs, Active-HDL work directories, firmware objects, bitstreams) is never committed;
released bitstreams go in `demos/`.

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

The packet data path uses AXI4-Stream with 64-bit `tdata` between the MAC, protocol wrapper and applications. Both Ethernet reference designs use the same byte ordering and frame boundary rules.

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

At one accepted 64-bit beat per cycle the raw transport capacity is `64 × f_clk` bits per second. Backpressure, frame gaps and protocol overhead reduce the application rate.

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

## 6. Board integration

The released Ethernet images share this CPU-visible map. The MAC block implements RGMII on Nexys Video and MII on Arty A7-100T. Software can inspect the same protocol and protection counters on both boards.

| Base address | Block | Use |
|---|---|---|
| `0x40400000` | AXI DMA | Simple-mode transmit and receive channels for CPU network frames |
| `0x44A00000` | System registers | Board capabilities, identification and diagnostics |
| `0x44A01000` | MAC | Configure the MAC and read link and frame counters |
| `0x44A02000` | MDIO | Drive PHY management transactions |
| `0x44A03000` | UDP echo | Control and observe the echo application |
| `0x44A10000` | Protocol window, 64 KiB | Wrapper at offset zero. ARP, ICMP, DHCP, UDP iperf and UDP sockets occupy successive 4 KiB windows from `0x1000` to `0x5000`. |
| `0x44A18000` | Classifier | CPU receive rules and policers inside the protocol window |
| `0x44A19000` | Checksum offload | CPU-path checksum control and statistics inside the protocol window |

**Nexys multi-clock example**

The diagram and address table describe the earlier multi-clock Nexys integration. The released Ethernet-only designs use the board-specific address decoder and a 100 MHz system domain. The released Nexys media design runs its main system at 90 MHz.

```
                 Nexys Video
  100 MHz osc --> MMCM (board top): clk125, clk125_90, clk200, axis_clk 62.5, proto_clk 50, cpu_clk 100
                                                                                       |
   USB-UART <--> +------------- rtlnet_cpu_microblaze (CPU core, cpu_clk) ------------+
   JTAG    <-->  |  MicroBlaze (8 KiB I + 8 KiB D cache over the DDR3 window), 512  |
                 |  KiB LMB BRAM, MDM, AXI UART Lite, AXI Timer, AXI DMA, AXI BRAM, |
                 |  M_AXI_RTLNET exported (AXI4-Lite), M_AXI_DDR exported (128-bit) |
                 +-------------------------------------------------------------------+
                         | AXI4-Lite, cpu_clk                  | AXI4 128-bit, cpu_clk (SmartConnect inside)
                         |                                  rtlnet_axi_cdc (u_ddr_cdc, cpu_clk -> ui_clk)
                rtlnet_axil_decoder (board top)         rtlnet_axi_arbiter --> rtlnet_ddr (MIG, DDR3 pins)
   +-----------+-----------+-------------+--------------------------+------------+-------------+
   | SYS       | MAC       | MDIO        | PROTOCOL (64 KiB window) | UDP ECHO   | ARBITER     |
   v           v           v             v                          v            v (registers)
   board regs  rtlnet_eth_mac  rtlnet_mdio  rtlnet_eth_protocol            rtlnet_udp_echo
               (RGMII pins)    (MDC/MDIO,    | filter, queues, arbiter      ^      |
                   |  ^         PHY reset)   | ARP ICMP DHCP iperf UDP-sock |      |
                   |  |                      |   payload streams ----------+------+
                   v  |                      v
              m_axis_rx --> s_axis (protocol) ; m_axis (protocol) --> s_axis_tx
```

### 6.1 Address map for the multi-clock example

MicroBlaze sees the RTLNet window at `0x44A0_0000`, 1 MiB. Offsets inside the window:

| Offset | Size | Block | Clock of its register file |
|---:|---:|---|---|
| 0x0_0000 | 4 KiB | board system registers (`ID`, `VERSION`, build id, LEDs, switches, buttons) | cpu_clk |
| 0x0_1000 | 4 KiB | `rtlnet_eth_mac` | axis_clk (through `rtlnet_axil_cdc`) |
| 0x0_2000 | 4 KiB | `rtlnet_mdio` | cpu_clk |
| 0x0_3000 | 4 KiB | `rtlnet_udp_echo` | app clock (through `rtlnet_axil_cdc`) |
| 0x0_4000 | 4 KiB | `rtlnet_axi_arbiter` (DDR3 arbiter, ID `ARBT`) | ui_clk (through `rtlnet_axil_cdc`) |
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
| 0x8000 | `rtlnet_classifier` (CPU path, section 7.4) |
| 0x9000 | `rtlnet_tcp_offload` (CPU path, section 14; `0x44A1_9000`, `u_cpu_offload`, `CPU_TCP_OFFLOAD_ENABLE`; reads 0 when not built) |

Other MicroBlaze addresses sit in the block design's own map (LMB BRAM `0x0000_0000` 512 KiB, AXI DMA registers
`0x4040_0000`, UART Lite `0x4060_0000`, interrupt controller `0x4120_0000`, Timer `0x41C0_0000`, DDR3 SDRAM
`0x8000_0000` 512 MiB through the instruction and data caches and `M_AXI_DDR`, AXI BRAM `0xC000_0000` 128 KiB). The
single source of these addresses for firmware is `cpu/microblaze_v_h264/driver/rtlnet_cpu_microblaze.h`.

---

## 7. Cores

### 7.1 `rtlnet_common`

| Module | Role |
|---|---|
| `rtlnet_pkg.sv` | stream constants, EtherTypes, IP protocol numbers, `be16/be32/be48`, `keep_bytes`, `keep_mask`, CRC-32 byte and word functions, ones'-complement helpers, default MAC/IP |
| `rtlnet_technology.svh` | the single technology selection include (section 8) |
| `rtlnet_ram_core.sv` | the generic RAM (section 8) |
| `rtlnet_shift_reg_core.sv` | the generic fixed-delay shift register (AMD: LUT shift-register RAM, `SRLC32E`) |
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

The Arty design uses `rtlnet_eth_mac_mii` with four data pins per direction. It shares the 64-bit client stream with the RGMII MAC and operates at 10 or 100 Mb/s.

### 7.3 `rtlnet_mdio` — PHY management by bit-banged MDIO

The RTL is a GPIO register core: `MDC` output, `MDIO` output data and output enable, `MDIO` input through a
3-stage synchronizer, the PHY reset output and the PHY interrupt input. The board top owns the MDIO tri-state
buffer. The C driver is the MDIO master:

- `rtlnet_mdio.c`: Clause 22 frame engine (32-bit preamble, ST, OP, PHYAD, REGAD, TA, 16 data bits, idle slot),
  MDC half-period from a calibrated delay loop, read/write, PHY hardware reset sequence (10 ms low + 30 ms
  settle, with margin).
- `rtlnet_phy_rtl8211e.c`: ID check (0x001C/0xC915), RX-delay enable (page 0xA4 register 28, read-modify-write
  of bits 13/11, readback), auto-negotiation enable/restart, advertisement selection (10/100/1000, full duplex only: the half-duplex bits are always written 0),
  forced speed, status decode from BMSR/PHYSR, loopback, register dump.

The MDIO driver also supports native Clause 45 transactions and MMD access through Clause 22. The Arty `rtlnet_phy_dp83848` driver manages the 10/100 MII PHY.

The Nexys CLI uses the driver to report link, speed, duplex and partner abilities, to set the link speed (`speed`, by the
advertised full-duplex modes), and to keep the MAC speed register in step with PHYSR.

### 7.4 `rtlnet_eth_protocol` — protocol wrapper

The wrapper has a MAC-client clock (`axis_clk`) and a protocol-leaf clock (`proto_clk`). Board logic can drive both with the system clock. Only the input slice, the destination-MAC filter, the ingress queue write side and the egress
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

**CPU network path (`cpu_axis_ethernet_stream`).** The dequeue controller presents every frame to the leaves and,
in parallel, copies it toward the CPU RX packet FIFO (`u_cpu_rx_fifo`, `proto_clk` to `cpu_axis_clk`). The copy's
last beat is held until the frame's claim verdict is final: the moment the dequeue controller would admit the next
frame (gap elapsed and no leaf busy). If any enabled leaf pulsed `claim` for the frame, the copy is dropped (written
with `s_bad`); otherwise it is committed and the CPU receives it on `m_axis_cpu_eth_*`. A full CPU RX FIFO drops the
frame and counts it; the leaves are never back-pressured. The CPU transmits complete Ethernet frames (no FCS) on
`s_axis_cpu_eth_*` into the CPU TX packet FIFO (`u_cpu_tx_fifo`, `cpu_axis_clk` to `proto_clk`), which is the
lowest-priority arbiter source. With `CTRL.CPU_PATH_ENABLE` clear nothing is copied and CPU frames are discarded.
The CPU network stack (lwIP) uses the same MAC and the wrapper's effective IP; the hardware leaves answer ARP
requests and pings for that address, so lwIP only ever sees what no leaf claims (TCP, ARP replies to its own
requests, other UDP, other ICMP).

**CPU-path classifier and the broadcast storm limiter.** `m_axis_cpu_eth_*` is the output of an `rtlnet_classifier`
instance (`u_cpu_classifier`, `cpu_axis_clk`) placed after `u_cpu_rx_fifo`, so every frame headed to the CPU passes the
configurable MAC / EtherType / L2 / L3 / L4 filter of section 13. At power-up the filter is **drop-all** until the C
driver configures it; the firmware's first configuration is the broadcast storm limiter (destination
`FF:FF:FF:FF:FF:FF` policed to 10 frames per 100 ms, every other frame passes). The hardware leaves are never
filtered. Registers: protocol sub-map window 0x8000, decoded in `s_axi_aclk` ahead of the wrapper's own register
crossing; driver `cores/rtlnet_classifier/driver`. CLI: `show storm-control`, `show classifier`; config-if
`storm-control broadcast <packets> <milliseconds>`, `storm-control broadcast enable|disable`; privileged
`classifier ...` commands for modes, tables, the tuple ACL, rules and policers.

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
| claim | `claim` | registered one-clock pulse for each frame the leaf consumes (answers, or accepts as its own), issued after that frame's last beat and no later than the clock its `busy` falls (or within 12 clocks when it never raises `busy`); frames no leaf claims go to the CPU path |

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
| `rtlnet_shift_reg_core` | direct `SRLC32E` instances (LUT shift-register RAM), cascaded through `Q31`, registered output | Altera: inferred array, `ramstyle` MLAB; Lattice: `syn_srlstyle` distributed; GENERIC: register array |
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

## 9. Clocks and resets in the multi-clock Nexys example

| Clock | Source | Frequency | Domain contents |
|---|---|---|---|
| `sys_clk` | 100 MHz oscillator R4 | 100 MHz | MMCM input only |
| `ddr_sys_clk` | MMCM CLKOUT6 through BUFG `u_bufg_ddrsys` | 100 MHz | DDR3 controller PLL input (MIG "No Buffer"; the pad cannot feed both the MMCM and the controller PLL, Place 30-172) |
| `clk125` | MMCM CLKOUT0 | 125 MHz | MAC TX byte engine, TX FIFO read, RGMII TX ODDRs, RXC rate detector |
| `clk125_90` | MMCM CLKOUT1, 90 deg | 125 MHz | TXC forwarding ODDR and its retiming flops; the board clock monitor (its own `rtlnet_reset_sync`) |
| `clk200` | MMCM CLKOUT2 | 200 MHz | IDELAYCTRL reference |
| `axis_clk` | MMCM CLKOUT3 | 62.5 MHz | MAC client side and registers, protocol filter, queue fast sides |
| `proto_clk` | MMCM CLKOUT4 | 50 MHz | protocol leaves, wrapper registers, socket layer, UDP echo |
| `cpu_clk` | MMCM CLKOUT5 | 100 MHz | MicroBlaze subsystem, AXI4-Lite decoder, MDIO core, system registers |
| `ui_clk` | DDR3 controller (MIG PLL from `ddr_sys_clk`, BUFG inside the IP) | 100 MHz | DDR3 AXI4 side: controller, `rtlnet_axi_arbiter` datapath and register file, the `rtlnet_axi_cdc` master side (`u_ddr_cdc`) |
| `rx_clk` | PHY RXC via BUFR | 125 / 25 / 2.5 MHz | MAC receive engine, RX FIFO write; stops on link loss |

One external reset (`cpu_resetn` button AND `mmcm_locked`) enters `rtlnet_reset_sync` once per domain. Packet
FIFOs require both sides to reset together; every FIFO's two resets derive from one assertion. The `ui_clk` domain
adds the controller's own reset: its `rtlnet_reset_sync` takes the board assertion AND the MIG ui reset, and the same
assertion resets the controller (`sys_rstn`), so a button press recalibrates the DDR3. The arbiter's register
crossing, the calibration flag (`rtlnet_sync` into cpu_clk, CLK_STATUS bit 1) and the DDR3 bridge `u_ddr_cdc`
(`rtlnet_axi_cdc`, five `rtlnet_packet_fifo` instances) are the only `ui_clk` crossings. The CPU's `M_AXI_DDR` (128-bit,
`cpu_clk`) crosses to `ui_clk` in `u_ddr_cdc` ahead of the arbiter; the SmartConnect in the CPU block design has one
clock.

Every crossing is one of: `rtlnet_packet_fifo` (Gray frame counters), `rtlnet_sync`, `rtlnet_pulse_sync`,
`rtlnet_gray_sync`, `rtlnet_axil_cdc`, `rtlnet_reset_sync`. `scripts/rtlnet_constrain_cdc.tcl` finds each by
instance/cell name and bounds it (`set_max_delay -datapath_only` of the source period plus `set_bus_skew` for
Gray and bundle crossings, first-stage false paths for level synchronizers, reset-pin false paths). No blanket
asynchronous clock groups.

---

## 10. CPU core and firmware

The Ethernet-only subsystem uses 512 KiB of firmware RAM and 128 KiB of frame storage on Nexys, or 256 KiB and 64 KiB respectively on Arty. The following port list describes the DDR-capable media CPU wrapper, `rtlnet_cpu_microblaze`.

| Port group | Ports |
|---|---|
| clock, reset | `clk` (cpu_clk, 100 MHz), `resetn` (synchronous, active low) |
| console | `uart_rxd` (from the USB-UART bridge), `uart_txd` (to it) |
| register master | `m_axi_*` AXI4-Lite master, 32-bit address and data, into `rtlnet_axil_decoder` |
| DDR3 master | `m_axi_ddr_*` 128-bit AXI4 master on `clk` (instruction and data caches), into `rtlnet_axi_cdc` and `rtlnet_axi_arbiter` |
| interrupts | `irq[7:0]` level inputs (PHY interrupt, DHCP event, ...) |

`rtlnet_cpu_microblaze.sv` wraps the block design `rtlnet_cpu` (Tcl-generated from
`cpu/microblaze_v_h264/hdl/rtlnet_cpu_bd.tcl`): MicroBlaze (little endian, 32-bit, no MMU, hardware
multiplier/divider/barrel shifter, 8 KiB instruction and 8 KiB write-through data cache over the DDR3 window only),
512 KiB LMB BRAM, MDM (JTAG debug), AXI UART Lite (115200 8N1), AXI Timer, AXI interconnect, the exported AXI4-Lite
master, a SmartConnect that joins the two cache masters into the exported 128-bit `M_AXI_DDR` and an interrupt controller. A Nios V core would be
`rtlnet_cpu_niosv.sv` around a Platform Designer system with the same ports; the RTL below the decoder does
not change. `cpu/microblaze_v_h264/rtlnet_microblaze_sim_stub.sv` (module `rtlnet_microblaze_sim_stub`, the simulation stand-in for the CPU) has the same ports and drives scripted
AXI4-Lite transactions for the board bench.

The block design also carries an AXI DMA (simple mode, 64-bit streams, data realignment engine on MM2S only (transmit buffers at any byte address; the DMA buffers and lwIP's heap are in the AXI BRAM), `S2MM` from `s_axis_eth_*`, `MM2S` to
`m_axis_eth_*`, both interrupts on the INTC) and an AXI BRAM for the DMA buffers; the LMB BRAM (512 KiB) holds code,
stack, heap and the lwIP pools. **All firmware code and data run from internal block RAM**; the DDR3 window
(`0x8000_0000`, 512 MiB) is used by the `ddr test` memory test and is the frame store of the camera design.
The MicroBlaze caches (8 KiB instruction, 8 KiB write-through data) cover only the DDR3 window: code runs from the
single-cycle LMB and the DMA buffers are accessed uncached, so the DMA path has no coherence handling; software that
shares the DDR3 window with another master flushes or invalidates the data cache around the access.

Firmware (`cpu/microblaze_v_h264/firmware`) is C11 built with `mb-gcc` against a standalone BSP that is **generated at build time
from the hardware export (XSA) by the Vitis tools in the AMD install** (standalone OS, `axidma`, `uartlite`,
`tmrctr`, `intc` drivers and the `lwip220` library, NO_SYS raw API). Nothing from the install is copied into the
repository; the generated BSP lives in the ignored build folder. Layers:

| Layer | Owns |
|---|---|
| BSP (generated) | start-up, vectors, Xilinx drivers, `xil_printf`, lwIP core |
| platform (`cpu/microblaze_v_h264/firmware/src`) | UART console on XUartLite, millisecond tick on XTmrCtr, interrupt setup on XIntc |
| RTLNet drivers | `cores/<core>/driver/*.c`, compiled in place, the only code that touches each core's registers |
| network | `rtlnet_netmgr.c` (PHY/MAC/DHCP management), `src/lwip/rtlnet_lwip_netif.c` (lwIP netif on the AXI DMA and the `cpu_axis_ethernet_stream`), `src/lwip/rtlnet_tcp_echo.c` (lwIP raw-API TCP echo server, port 7), TCP iperf server on port 5001 (`src/lwip/rtlnet_lwiperf.c`, the RTLNet copy of lwIP's `lwiperf` with the reverse, tradeoff and dual modes; the UDP iperf server on port 5001 is the RTL iperf leaf) |
| CLI | `menu.c`, `cli_commands.c` (MenuBuilder hierarchical rules) |

CLI: a light network-switch style hierarchy built on the MenuBuilder rules
(`cpu/microblaze_v_h264/firmware/cli/MenuBuilder_hierarchical.md`, command source `cli_commands.txt`):

| Mode (prompt) | Entered by | Examples |
|---|---|---|
| exec `rtlnet>` | power-up | `show version`, `show system`, `show interfaces`, `show ip`, `enable` |
| privileged `rtlnet#` | `enable` | everything in exec, `debug read/write`, `phy read/write/dump`, `reload`, `configure terminal` |
| config `rtlnet(config)#` | `configure terminal` | `ip address`, `ip gateway`, `mac-address`, `interface eth0`, `dhcp`, `socket <n>` |
| config-if `rtlnet(config-if)#` | `interface eth0` | `speed 10/100/auto` (full duplex; `auto` advertises 10/100/1000 and takes the best rate; the only link control), `shutdown` |
| config-dhcp / config-sock | `dhcp`, `socket <n>` | `start`, `stop`, `auto`; `port`, `remote`, `connect-on-rx` |

`exit` leaves one level, `end` (or Ctrl-Z) returns to privileged exec, `?` lists the commands of the current
mode or the next keywords of a partial command, unique prefixes are accepted (`sh ver`).

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
- Board bench: the real board top (MicroBlaze replaced by `cpu/microblaze_v_h264/rtlnet_microblaze_sim_stub.sv`) against an RTL8211E
  RGMII/MDIO model at 10, 100 and 1000 Mb/s.

Hardware: Vivado batch build with exit-code gates (synthesis, timing setup and hold, CDC report, utilization),
JTAG programming, CLI over COM port, host tests from the PC (`arping`, `ping -l` sweep, `iperf -c -u`,
UDP echo and bidirectional iperf 2). Nexys hardware tests cover 10, 100 and 1,000 Mb/s. Arty hardware tests cover 10 and 100 Mb/s. The Ethernet release records give negotiated speeds, loss counts and firewall settings.

---

## 12. Packet-stream bandwidth

The released RGMII design supports up to 1 Gb/s and the MII design up to 100 Mb/s. A 64-bit interface transferring one beat every cycle carries 10 Gb/s at 156.25 MHz or 25 Gb/s at 390.625 MHz before overhead. Those figures are interface arithmetic. No 10G or 25G MAC implementation, timing closure or board throughput is claimed here.

---

## 13. `rtlnet_classifier`

A configurable MAC / EtherType / layer-2 / layer-3 / layer-4 filter on an RTLNet stream, built on a shift-register
delay line: each frame is delayed by `MATCH_DEPTH_BYTES` (default 64) plus the verdict latency while field tables (MAC,
EtherType, VLAN, IP, port: single, range or data/mask, source/destination/either/both), a tuple ACL table (protocol,
IP/mask, port ranges) and positional byte-by-byte mask+operator rule engines judge its first bytes; at the end of the
delay line the original frame is presented with its valid set or cleared by the combined decision. A global mode
selects drop-all (power-up), pass-all, pass-on-match or drop-on-match; classify-only entries feed policers (X frames per
Y ms). Everything is configured through the AXI4-Lite slave by the C driver. First instance: the CPU path of section
7.4, whose first firmware configuration is the broadcast storm limiter. Full specification:
`cores/rtlnet_classifier/documentation/rtlnet_classifier.md`.

## 14. `rtlnet_tcp_offload`

Checksum offload on the CPU DMA stream, one stream clock (the CPU stream clock). Egress (DMA MM2S -> offload -> CPU TX
FIFO) is store-and-forward: the frame is written whole into an `rtlnet_packet_fifo` (`TX_BUF_KB`, default 8 = four
maximum frames) while a streaming engine sums the IPv4 header and the TCP / UDP pseudo-header plus segment; a sideband
queue carries the two checksums and their byte positions, and a registered byte-lane replace writes them into the frame
as it leaves (IPv4 field at frame byte 24/25, +4 with one 802.1Q tag; L4 field at TCP +16 / UDP +6 from the L4 start;
existing field contents ignored, UDP `0x0000` sent as `0xFFFF`, Ethernet padding past the IP total length excluded,
fragments and other protocols skipped and counted, malformed lengths counted). Ingress (classifier output ->
offload -> DMA S2MM) is cut-through: the frame passes a delay line of 17 beats while the engine finishes, then the final
data beat is padded to 8 bytes (`tkeep` all ones, pad bytes 0) and one trailer beat with `tlast` follows, always at
byte offset `roundup8(frame_len)`: frame length, folded L4 sum, flags (is_ipv4, is_tcp, is_udp, vlan, fragment,
ip_ok, l4_ok, verified), L4 offset, marker `0xA5`. The hardware drops nothing; the CPU stack reads the trailer. Registers
(ID `"TCPO"`): `CTRL` bits `tx_ip_csum`, `tx_l4_csum`, `rx_csum` (power-up 0 = both paths bit-exact pass-through), `STATUS`
idle bits, `CAPS` (`TX_PRESENT`, `RX_PRESENT`, insert types, buffer size), counters. Full specification, latency
and throughput table, trailer layout, lwIP mapping and verification record:
`cores/rtlnet_tcp_offload/documentation/rtlnet_tcp_offload.md`. It is instanced in the protocol wrapper's CPU path as
`u_cpu_offload` (RX between the classifier and the CPU DMA S2MM stream, TX between the CPU DMA MM2S stream and the
CPU TX FIFO), registers at sub-map `0x9000`, and advertised by wrapper `CPU_CAPS` bit 17 (TX) and bit 18 (RX), next to
bit 16 for the classifier. Firmware discovers the blocks through those bits, confirms each block's own ID and CAPS, and
configures lwIP from what is present (`rtlnet_offload_apply`); a build without a block is a firmware no-op for it.
The `TX_ENABLE` / `RX_ENABLE` single-path builds are future work.

## 15. Core port lists (integration contract)

These port lists are binding: cores are built in parallel and connected by the board top by name. All resets
are **synchronous, active low**, generated in the board top by one `rtlnet_reset_sync` per clock from one
assertion (button AND MMCM lock), so the two sides of every packet FIFO reset together. A core that owns an
internal clock (the MAC's `rx_clk`) generates that domain's reset itself. AXI4-Lite slaves are 32-bit data,
`s_axi_aclk` = `cpu_clk`; a core whose registers live in another clock puts `rtlnet_axil_cdc` inside itself.

### 15.1 `rtlnet_eth_mac`

| Group | Ports |
|---|---|
| clocks | `clk125`, `clk125_90`, `clk200`, `axis_clk`, `s_axi_aclk` |
| resets | `clk125_resetn`, `clk200_resetn`, `axis_resetn`, `s_axi_aresetn` |
| RGMII pins | in `rgmii_rxc`, `rgmii_rxd[3:0]`, `rgmii_rx_ctl`; out `rgmii_txc`, `rgmii_txd[3:0]`, `rgmii_tx_ctl` |
| RX client (axis_clk) | out `m_axis_rx_tdata[63:0]`, `m_axis_rx_tkeep[7:0]`, `m_axis_rx_tvalid`, `m_axis_rx_tlast`; in `m_axis_rx_tready` |
| TX client (axis_clk) | in `s_axis_tx_tdata[63:0]`, `s_axis_tx_tkeep[7:0]`, `s_axis_tx_tvalid`, `s_axis_tx_tlast`; out `s_axis_tx_tready` |
| registers | `s_axi_*` slave, `ADDR_W` 12 |
| status (axis_clk, registered) | `stat_link_up` (firmware-set link flag), `stat_speed[1:0]` (00 10M, 01 100M, 10 1000M), `stat_rx_clk_ok`, `ev_rx_good`, `ev_rx_bad`, `ev_tx_frame` (one-clock pulses, for LEDs) |

Parameters: `RX_FIFO_KB` 8, `TX_FIFO_KB` 8, `MAX_FRAME_BYTES` 1518, `RX_IDELAY_TAP` 12, `RAM_STYLE` "block".
The pin layer is `` `RTLNET_RGMII_IO `` (AMD: `rtlnet_rgmii_io_amd7`), instanced inside the MAC with a fixed
instance name `u_rgmii_io`; the board XDC names its cells by that path.

### 15.2 `rtlnet_mdio`

| Group | Ports |
|---|---|
| clock, reset | `clk` (cpu_clk), `resetn` |
| registers | `s_axi_*` slave, `ADDR_W` 12 |
| MDIO pins (board top owns the IOBUF) | out `mdc`, `mdio_o`, `mdio_t` (1 = release the line); in `mdio_i` (asynchronous) |
| PHY control | out `phy_rst_n` (register; held low `POR_RESET_MS` after reset, then released; firmware can pulse it); in `phy_int_n` (asynchronous) |
| interrupt | out `irq` (level: PHY interrupt asserted and enabled) |

Parameters: `CLK_HZ` 100_000_000, `POR_RESET_MS` 20.

### 15.3 `rtlnet_eth_protocol`

| Group | Ports |
|---|---|
| clocks | `axis_clk`, `proto_clk`, `app_clk`, `s_axi_aclk` |
| resets | `axis_resetn`, `proto_resetn`, `app_resetn`, `s_axi_aresetn` |
| from MAC RX (axis_clk) | in `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`; out `s_axis_tready` (a flop, never back-pressures) |
| to MAC TX (axis_clk) | out `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`; in `m_axis_tready` |
| application RX, socket payload out (app_clk) | out `m_axis_app_tdata[63:0]`, `m_axis_app_tkeep[7:0]`, `m_axis_app_tvalid`, `m_axis_app_tlast`; in `m_axis_app_tready` |
| application TX, socket payload in (app_clk) | in `s_axis_app_tdata[63:0]`, `s_axis_app_tkeep[7:0]`, `s_axis_app_tvalid`, `s_axis_app_tlast`; out `s_axis_app_tready` |
| registers | `s_axi_*` slave, `ADDR_W` 16 (64 KiB sub-map of section 6.1) |
| CPU clock | `cpu_axis_clk` (cpu_clk), `cpu_axis_resetn` |
| `cpu_axis_ethernet_stream` ingress: unclaimed frames to the CPU (cpu_axis_clk) | out `m_axis_cpu_eth_tdata[63:0]`, `m_axis_cpu_eth_tkeep[7:0]`, `m_axis_cpu_eth_tvalid`, `m_axis_cpu_eth_tlast`; in `m_axis_cpu_eth_tready` |
| `cpu_axis_ethernet_stream` egress: frames from the CPU (cpu_axis_clk) | in `s_axis_cpu_eth_tdata[63:0]`, `s_axis_cpu_eth_tkeep[7:0]`, `s_axis_cpu_eth_tvalid`, `s_axis_cpu_eth_tlast`; out `s_axis_cpu_eth_tready` |
| status (proto_clk, registered, LEDs only) | `stat_ip_valid`, `stat_dhcp_bound`, `ev_rx_frame`, `ev_tx_frame` |

Parameters: `PROTO_CLK_HZ` 50_000_000, `INGRESS_FIFO_KB` 16, `EGRESS_FIFO_KB` 8, `ARP_ENABLE`/`ICMP_ENABLE`/
`DHCP_ENABLE`/`IPERF_ENABLE`/`UDP_ENABLE` 1, `ICMP_BUF_KB` 2, `DHCP_BUF_KB` 1, `IPERF_PORT` 5001,
`NUM_SOCKETS` 4, `UDP_RX_BUF_KB` 16, `UDP_TX_BUF_KB` 8, `CPU_PATH_ENABLE` 1, `CPU_RX_FIFO_KB` 16, `CPU_TX_FIFO_KB` 8,
`CPU_CLASSIFIER_ENABLE` 1, `CPU_TCP_OFFLOAD_ENABLE` 1, `CPU_AXIS_CLK_HZ` 100_000_000,
`RAM_STYLE` "block". Queue instance names `u_ingress_fifo`, `u_egress_fifo`, `u_cpu_rx_fifo`, `u_cpu_tx_fifo`; the CPU-path classifier
instance is `u_cpu_classifier` (section 13, registers at sub-map 0x8000), the checksum offload instance is
`u_cpu_offload` (section 14, registers at sub-map 0x9000). `CPU_CAPS` (0x034): `[7:0]` `CPU_RX_FIFO_KB`, `[15:8]`
`CPU_TX_FIFO_KB`, bit 16 classifier, bit 17 offload TX, bit 18 offload RX; 0 without the CPU path. Arbiter
priority: UDP socket, ICMP, ARP, DHCP, iperf, CPU.

### 15.4 Leaves (instanced inside `rtlnet_eth_protocol`)

Every leaf has exactly the contract ports of section 7.5:

```
module rtlnet_<leaf> #(...) (
  input  logic        clk, resetn,                       // proto_clk
  input  logic        enable,
  input  logic [63:0] s_axis_tdata,  input logic [7:0] s_axis_tkeep,
  input  logic        s_axis_tvalid, s_axis_tlast,  output logic s_axis_tready,
  output logic [63:0] m_axis_tdata,  output logic [7:0] m_axis_tkeep,
  output logic        m_axis_tvalid, m_axis_tlast,  input  logic m_axis_tready,
  input  logic [47:0] local_mac,     input  logic [31:0] local_ip,
  output logic        busy,
  output logic        claim,                             // one-clock pulse per consumed frame
  input  logic        reg_wr_en,     input  logic [11:0] reg_wr_addr, input logic [31:0] reg_wr_data,
  input  logic        reg_rd_en,     input  logic [11:0] reg_rd_addr, output logic [31:0] reg_rd_data
  <leaf-specific ports below>
);
```

| Leaf | Module | Leaf-specific ports | Parameters |
|---|---|---|---|
| ARP | `rtlnet_arp` | none | `REPLY_DELAY_CYCLES` 1250 |
| ICMP | `rtlnet_icmp` | none | `ICMP_BUF_KB` 2, `RAM_STYLE` |
| DHCP | `rtlnet_dhcp` | out `lease_valid` (level), `lease_ip[31:0]`, `lease_mask[31:0]`, `lease_router[31:0]`, `lease_server[31:0]`, `lease_time_s[31:0]` (all registered, change only on an ACK or a lease loss) | `MS_CYCLES` 50_000, `DHCP_BUF_KB` 1, `RAM_STYLE` |
| iperf | `rtlnet_iperf` | none | `CLK_HZ` 50_000_000, `UDP_PORT` 5001, `MAX_DGRAM_BYTES` 1472 |
| UDP socket | `rtlnet_udp_socket` | `app_clk`, `app_resetn`, the two application streams of 15.3 (`m_axis_app_*`, `s_axis_app_*`), in `local_mask[31:0]`, `local_gateway[31:0]` | `NUM_SOCKETS` 4, `UDP_RX_BUF_KB` 16, `UDP_TX_BUF_KB` 8, `RAM_STYLE` |

`local_ip` is the wrapper's effective address (the DHCP lease while `lease_valid`, else the static address).
DHCP control (start, stop, renew now, auto-start) lives in the DHCP leaf's own registers.

### 15.5 `rtlnet_udp_echo`

| Group | Ports |
|---|---|
| clocks, resets | `app_clk`, `app_resetn`, `s_axi_aclk`, `s_axi_aresetn` |
| from socket layer (app_clk) | in `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`; out `s_axis_tready` |
| to socket layer (app_clk) | out `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`; in `m_axis_tready` |
| registers | `s_axi_*` slave, `ADDR_W` 12 (internal `rtlnet_axil_cdc` to `app_clk`) |

### 15.6 `rtlnet_cpu_microblaze` (in `cpu/microblaze_v_h264/`)

| Group | Ports |
|---|---|
| clock, reset | `clk` (cpu_clk 100 MHz), `resetn` |
| console | in `uart_rxd`, out `uart_txd` |
| register master | `m_axi_*` AXI4-Lite master, 32-bit address |
| DDR3 master | `m_axi_ddr_*` AXI4 master on `clk` (the board top crosses it to `ui_clk` in `rtlnet_axi_cdc`): `awaddr[31:0]`, `awlen`, `awsize`, `awburst`, `awlock`, `awcache`, `awprot`, `awqos`, `awvalid`/`awready`, `wdata[127:0]`, `wstrb[15:0]`, `wlast`, `wvalid`/`wready`, `bresp`, `bvalid`/`bready`, the AR channel likewise, `rdata[127:0]`, `rresp`, `rlast`, `rvalid`/`rready`; no ID signals |
| interrupts | in `irq[7:0]` |
| Ethernet frames to the network (clk) | out `m_axis_eth_tdata[63:0]`, `m_axis_eth_tkeep[7:0]`, `m_axis_eth_tvalid`, `m_axis_eth_tlast`; in `m_axis_eth_tready` (AXI DMA MM2S; to the wrapper's `s_axis_cpu_eth_*`) |
| Ethernet frames from the network (clk) | in `s_axis_eth_tdata[63:0]`, `s_axis_eth_tkeep[7:0]`, `s_axis_eth_tvalid`, `s_axis_eth_tlast`; out `s_axis_eth_tready` (AXI DMA S2MM; from the wrapper's `m_axis_cpu_eth_*`) |

### 15.7 `rtlnet_tcp_offload`

| Group | Ports |
|---|---|
| clocks, resets | `clk` (cpu_axis_clk), `resetn`, `s_axi_aclk` (cpu_clk), `s_axi_aresetn` |
| TX in, frames from the CPU DMA MM2S (clk) | in `s_axis_tx_tdata[63:0]`, `s_axis_tx_tkeep[7:0]`, `s_axis_tx_tvalid`, `s_axis_tx_tlast`; out `s_axis_tx_tready` (a flop) |
| TX out, frames to the CPU TX FIFO (clk) | out `m_axis_tx_tdata[63:0]`, `m_axis_tx_tkeep[7:0]`, `m_axis_tx_tvalid`, `m_axis_tx_tlast`; in `m_axis_tx_tready` |
| RX in, frames from the classifier (clk) | in `s_axis_rx_tdata[63:0]`, `s_axis_rx_tkeep[7:0]`, `s_axis_rx_tvalid`, `s_axis_rx_tlast`; out `s_axis_rx_tready` (a flop) |
| RX out, frames and trailers to the CPU DMA S2MM (clk) | out `m_axis_rx_tdata[63:0]`, `m_axis_rx_tkeep[7:0]`, `m_axis_rx_tvalid`, `m_axis_rx_tlast`; in `m_axis_rx_tready` |
| registers | `s_axi_*` slave, `ADDR_W` 12 (internal `rtlnet_axil_cdc` to `clk`) |

Parameters: `TX_BUF_KB` 8, `RAM_STYLE` "block", `SB_RAM_STYLE` "distributed", `MAX_FRAME_BYTES` 1518. Instance names the
constraints depend on: `u_regs/u_axil_cdc`, `u_tx/u_tx_fifo`. Expected CDC census: `sync 2`, `axil_cdc 1`, `fifo 1`.
All outputs are registered. In the CPU path the instance sits between `u_cpu_classifier` and the DMA S2MM stream (RX)
and between the DMA MM2S stream and `u_cpu_tx_fifo` (TX).

## 16. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial architecture; all RTL in SystemVerilog; CPU as a replaceable core; one technology include file; Active-HDL simulation; CPU port list, BD address map and CLI hierarchy aligned with the built cores |
| 10-22-2026 | CPU network path (`cpu_axis_ethernet_stream`, leaf `claim`), AXI DMA, lwIP TCP echo server, `cpu/microblaze_v_h264/` folder, BSP generated from the AMD install |
| 10-22-2026 | Broadcast storm limiter on the CPU path (default 10 frames / 100 ms) |
| 11-13-2026 | Link speed: `speed 10/100/auto`, full duplex only (no half-duplex advertisement), `duplex` removed |
| 10-22-2026 | `rtlnet_tcp_offload`: checksum insert on the CPU TX stream, check with trailer on the CPU RX stream (core built; sub-map slot 0x9000 planned) |
| 10-22-2026 | `rtlnet_tcp_offload` integrated in the protocol wrapper's CPU path (`u_cpu_offload`, window 0x9000, `CPU_CAPS` bits 16..18); default `TX_BUF_KB` 8; firmware discovery, `rtlnet_offload_apply`, receive trailer policy, zero-copy options; AXI DMA realignment engine on MM2S |
| 11-09-2026 | MicroBlaze V block design without the JTAG UART: the MDM address 0x4140_0000 is unmapped |
| 11-09-2026 | DDR3 (Phase 0 stage 1): `rtlnet_ddr` (MIG, 512 MiB) and `rtlnet_axi_arbiter` in the board top; MicroBlaze V caches (8 KiB I, 8 KiB write-through D over `0x8000_0000..0x9FFF_FFFF`), SmartConnect and the exported 128-bit `M_AXI_DDR`; arbiter window `0x44A0_4000`; `ui_clk` domain; firmware `show ddr`, `ddr test`; the CPU's `M_AXI_DDR` runs on `cpu_clk` and crosses to `ui_clk` in the board top's `rtlnet_axi_cdc` (`u_ddr_cdc`), so the SmartConnect has one clock |
| 11-09-2026 | DDR3 controller `sys_clk` is MMCM CLKOUT6 through a BUFG (`ddr_sys_clk`); the arbiter's CPU master sets `NARROW_MASK` for the write-through data cache's 32-bit stores |
| 11-13-2026 | The MIG project file moved to `boards/nexys_video/ip/` and is an argument of `rtlnet_ddr_mig_create`; section 2 notes where each folder lives |
| 11-13-2026 | The repository is one branch, `main`; board-independent code and a board are separated by folder (`cores/`, `boards/<board>/`, `cpu/microblaze_v_h264/`, `demos/`), layout rules in `rtlnet_contributing.md` section 8 |
| 11-14-2026 | The MicroBlaze CPU moved from `microblaze/` to `cpu/microblaze_v_h264/`; `cpu/` holds one folder per CPU, each independent with its own block design, firmware, CLI and tests |
