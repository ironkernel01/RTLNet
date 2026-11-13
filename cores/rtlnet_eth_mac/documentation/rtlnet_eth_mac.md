# rtlnet_eth_mac — 10/100/1000 Mb/s RGMII Ethernet MAC

> Paths under `boards/`, `microblaze/` and `demos/` in this guide, and the board results it quotes, are on the `nexys_video_h264_baseline` branch; `main` holds the board-independent cores only.

| Item | Value |
|---|---|
| Core | `rtlnet_eth_mac` |
| Document revision | 10-22-2026 |
| Register map revision | `VERSION` = `0x10222026` |
| Language | SystemVerilog-2012 (RTL, benches), C11 (driver) |
| Target | Digilent Nexys Video, Artix-7 XC7A200T-1SBG484C, Realtek RTL8211E (RGMII, MDIO address 1) |
| Technology | `cores/rtlnet_common/hdl/rtlnet_technology.svh` (AMD default; `RTLNET_TECH_GENERIC` builds the behavioural pin layer) |
| Verification | Active-HDL 11.1: `tb_rtlnet_eth_mac_gmii`, `tb_rtlnet_eth_mac` at 1000/100/10 Mb/s (AMD and GENERIC); host test of the driver |

The MAC connects the RTL8211E RGMII pins to the RTLNet stream (architecture section 4). It runs full duplex at
10, 100 and 1000 Mb/s with one set of byte engines paced by a byte clock enable, checks and strips the FCS on
receive, pads and appends the FCS on transmit, and queues whole frames in store-and-forward packet FIFOs that
are also the clock crossings. The speed is a register written by firmware from the PHY's PHYSR (MDIO is
bit-banged by firmware through `rtlnet_mdio`); an RXC rate detector qualifies that speed before the receive
path may run. The MAC has no address register: the protocol wrapper owns the node's addresses.

---

## 1. Files

| File | Content |
|---|---|
| `hdl/rtlnet_eth_mac.sv` | top: port list of architecture section 15.1, crossings, receive-path reset, chains |
| `hdl/rtlnet_eth_mac_regs.sv` | register file in `axis_clk`, counters, status outputs |
| `hdl/rtlnet_gmii_rx.sv` | GMII receiver: SFD, CRC-32 residue check, FCS strip, 8 -> 64 packing, verdict |
| `hdl/rtlnet_gmii_tx.sv` | GMII transmitter: 64 -> 8, preamble/SFD, pad to 60, FCS, interframe gap, discard when disabled |
| `hdl/rtlnet_eth_rxc_rate.sv` | RXC rate detector (clk125) |
| `hdl/rtlnet_rgmii_fabric.sv` | fabric part of every pin layer: 10/100 nibble pairing aligned on the SFD, in-band decode, TX pacing, TXC pattern |
| `hdl/rtlnet_rgmii_io_amd7.sv` | AMD 7-series pin layer (`` `RTLNET_RGMII_IO `` for AMD): IBUF, BUFIO, BUFR, IDELAYCTRL, IDELAYE2, IDDR, ODDR — the only file with vendor primitives |
| `hdl/rtlnet_rgmii_io_generic.sv` | behavioural pin layer (GENERIC), same ports |
| `hdl/rtlnet_eth_mac.f` | filelist (includes `cores/rtlnet_common/hdl/rtlnet_common.f` first) |
| `driver/rtlnet_eth_mac.h`, `.c` | register map (single source of offsets and bits) and driver |
| `driver/test/test_rtlnet_eth_mac.c`, `Makefile` | host unit test against a mocked register map; `mb-gcc` compile target |
| `testbench/tb_rtlnet_eth_mac_gmii.sv`, `.f` | GMII-level unit bench |
| `testbench/tb_rtlnet_eth_mac.sv`, `.f` | full-MAC bench with the pin layer and the PHY model |
| `testbench/rtlnet_rtl8211e_model.sv` | RTL8211E RGMII/MDIO model (section 9), reusable by the MDIO driver tests and the board bench |
| `testbench/regression.txt` | regression lines |

## 2. Interface (architecture section 15.1)

```
eth_rxc -> u_rgmii_io (`RTLNET_RGMII_IO) -> GMII byte + ce (rx_clk) -> u_gmii_rx -> u_rx_guard (60..MAX)
        -> u_rx_fifo (rx_clk -> axis_clk, drop when full) -> u_rx_slice -> m_axis_rx
s_axis_tx -> u_tx_slice -> u_tx_guard (14..MAX) -> u_tx_fifo (axis_clk -> clk125) -> u_gmii_tx (ce)
        -> u_rgmii_io -> eth_txc / eth_txd / eth_txctl
s_axi (s_axi_aclk) -> u_axil_cdc -> u_axil_slave (axis_clk) -> u_regs
```

| Group | Ports | Rule |
|---|---|---|
| clocks | `clk125`, `clk125_90`, `clk200`, `axis_clk`, `s_axi_aclk` | `clk125`/`clk125_90` (90 deg)/`clk200`/`axis_clk` from one MMCM; `s_axi_aclk` = cpu_clk |
| resets | `clk125_resetn`, `clk200_resetn`, `axis_resetn`, `s_axi_aresetn` | synchronous to their clocks, active low, released from one assertion (both sides of each FIFO and of the register crossing reset together) |
| RGMII pins | in `rgmii_rxc`, `rgmii_rxd[3:0]`, `rgmii_rx_ctl`; out `rgmii_txc`, `rgmii_txd[3:0]`, `rgmii_tx_ctl` | 2.5 V bank; RXC centred on the data by the PHY RX delay; TXC 2 ns after the data |
| RX client (axis_clk) | out `m_axis_rx_tdata[63:0]`, `m_axis_rx_tkeep[7:0]`, `m_axis_rx_tvalid`, `m_axis_rx_tlast`; in `m_axis_rx_tready` | good whole frames only, destination MAC to the last payload/pad byte (receive padding kept, FCS stripped); every output a flop |
| TX client (axis_clk) | in `s_axis_tx_tdata[63:0]`, `s_axis_tx_tkeep[7:0]`, `s_axis_tx_tvalid`, `s_axis_tx_tlast`; out `s_axis_tx_tready` | 14..`MAX_FRAME_BYTES` bytes, no FCS; the MAC pads to 60 and appends the FCS; `tready` is a flop |
| registers | `s_axi_*` AXI4-Lite slave, 12-bit address (`awaddr`, `awvalid`, `awready`, `wdata`, `wstrb`, `wvalid`, `wready`, `bresp`, `bvalid`, `bready`, `araddr`, `arvalid`, `arready`, `rdata`, `rresp`, `rvalid`, `rready`) | architecture section 5 |
| status (axis_clk, registered) | `stat_link_up`, `stat_speed[1:0]`, `stat_rx_clk_ok`, `ev_rx_good`, `ev_rx_bad`, `ev_tx_frame` | see below |

Status outputs: `stat_link_up` = `CTRL.LINK_UP` (the firmware's link flag); `stat_speed` = `CTRL.SPEED` (00 10M,
01 100M, 10 1000M); `stat_rx_clk_ok` = RXC qualified for that speed; `ev_rx_good` pulses one `axis_clk` clock per
frame delivered on `m_axis_rx` (last-beat handshake), `ev_rx_bad` per frame dropped as bad or for overflow,
`ev_tx_frame` per frame sent on the wire. The pulse counts equal the counters exactly (checked by the bench).

## 3. Parameters

| Parameter | Default | Meaning |
|---|---:|---|
| `RX_FIFO_KB` | 8 | RX packet FIFO storage in KiB; 1518-byte frames take 2 KiB slots, so 8 KiB holds 4 frames (4/8/16/32 legal) |
| `TX_FIFO_KB` | 8 | TX packet FIFO storage in KiB (same rule) |
| `MAX_FRAME_BYTES` | 1518 | client frame limit without FCS, receive and transmit (guards and FIFO slots) |
| `RX_IDELAY_TAP` | 12 | RXD/RX_CTL IDELAYE2 fixed tap (0..31; about 78 ps per tap at 200 MHz); retune from post-route STA |
| `RAM_STYLE` | `"block"` | FIFO storage through `rtlnet_ram_core`: `"block"` or `"distributed"` |

Illegal sizes stop elaboration (`$fatal` in a generate branch, synthesis and simulation): FIFO sizes that do not
give at least two power-of-two slots, `MAX_FRAME_BYTES` below 60, a tap outside 0..31, or values that do not fit
the `CAPS` fields.

## 4. Register map

Offsets and bits are defined once in `driver/rtlnet_eth_mac.h`; `hdl/rtlnet_eth_mac_regs.sv` mirrors them.
32-bit registers in `axis_clk`, reached through `rtlnet_axil_cdc`. Writes are full-word only (`wstrb = 4'hF`;
others are answered OKAY and ignored); undefined offsets read 0 and ignore writes.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | `0x4D414331` | `"MAC1"` (`rtlnet_pkg::id4`) |
| 0x004 | `VERSION` | RO | `0x10222026` | register map date code |
| 0x008 | `CAPS` | RO | `0x05EE0808` | [7:0] `RX_FIFO_KB`, [15:8] `TX_FIFO_KB`, [31:16] `MAX_FRAME_BYTES` |
| 0x00C | `CTRL` | RW | `0x00000000` | bit 0 `RX_EN`, bit 1 `TX_EN`, bits 5:4 `SPEED` (00 10M, 01 100M, 10 1000M, 11 runs as 1000M), bit 8 `LINK_UP` (drives `stat_link_up`), bit 16 `CNT_CLEAR` (write 1: clear all counters; reads 0) |
| 0x010 | `STATUS` | RO | — | bit 0 `RX_CLK_OK` (RXC in band for `CTRL.SPEED`, two windows), bit 1 `IDELAY_RDY`, bit 2 `RX_IN_RESET` (receive path held in reset), bits 5:4 speed in effect in the MAC clocks, bit 8 in-band link, bits 10:9 in-band speed, bit 11 in-band full duplex (in-band fields: debug only) |
| 0x014 | `RX_CLK_RATE` | RO | 0 | [9:0] RXC/16 transitions in the last 4096-clk125 window: nominal 512 / 102 / 10 at 1000 / 100 / 10 Mb/s |
| 0x018 | `RX_IDELAY_TAP` | RO | `RX_IDELAY_TAP` | the data tap of this build |
| 0x020 | `RX_GOOD` | RO | 0 | frames delivered on `m_axis_rx` |
| 0x024 | `RX_BAD` | RO | 0 | frames dropped as bad: FCS error, RX_ER, runt (< 60 bytes, or 1..4 bytes after the SFD), oversize, illegal tkeep |
| 0x028 | `RX_OVERFLOW` | RO | 0 | frames dropped because the RX FIFO was full |
| 0x02C | `TX_FRAMES` | RO | 0 | frames sent on the wire (discarded frames are not counted) |

Counters are 32-bit and wrap. They are exact: `RX_GOOD`, `RX_BAD` and `RX_OVERFLOW` count `axis_clk` events one
for one (the last-beat handshake and the RX FIFO's `bad_frame` / `overflow` pulses); `TX_FRAMES` is the clk125
frame total crossed with `rtlnet_gray_sync` minus a base captured at the last clear. An event in the same clock as
`CNT_CLEAR` is counted after the clear.

Firmware sequence (driver functions in brackets): read PHYSR over MDIO; `CTRL.SPEED` to the PHY speed
(`set_speed`); `RX_EN`/`TX_EN` (`enable`); `LINK_UP` (`set_link`); wait for `RX_CLK_OK && !RX_IN_RESET`
(`wait_rx_ready`, bounded). On every PHYSR speed change write the new speed; the MAC resets its receive path by
itself.

## 5. Design

### 5.1 Receive

* Pin layer: RXC -> IBUF -> BUFIO (the five IDDR clocks only) and -> BUFR = `rx_clk`. RXD/RX_CTL -> IBUF ->
  IDELAYE2 (FIXED, `RX_IDELAY_TAP`) -> IDDR (`SAME_EDGE_PIPELINED`). No delay and no MMCM on the clock: RXC stops
  on link loss. RGMII mapping: low nibble and RX_DV on the rising edge, high nibble and RX_DV xor RX_ER on the
  falling edge.
* **The MAC relies on the PHY's internal RX clock delay** (RTL8211E extension page 0xA4 register 28, bits 13 and 11
  set by the MDIO driver; the Nexys Video straps RXDLY = 0). With it RXD/RX_CTL arrive centred on RXC (datasheet
  Rev. 1.6 Table 65: data to clock output setup and hold at least 1.2 ns each).
* 1000 Mb/s: one byte `{Q2, Q1}` per `rx_clk`, `gmii_rx_ce` = 1. 10/100: one nibble per RXC cycle (rising-edge
  sample); bytes are paired aligned on the SFD (a 0xD nibble after a 0x5 nibble), not on the rise of RX_DV, so an
  odd number of preamble nibbles is received correctly; `gmii_rx_ce` pulses once per byte and stays 1 while RX_DV is
  low; RX_DV falling with half a byte held delivers an errored final byte.
* `rtlnet_gmii_rx`: states `S_IDLE`, `S_PREAMBLE`, `S_DATA`, `S_FLUSH`. A 4-byte delay line keeps the FCS from the
  client; a staging byte makes the final client byte known before it is packed; the CRC-32 register over every byte
  after the SFD must equal the residue 0xDEBB20E3. The final beat, its tkeep and the verdict are presented together
  in `S_FLUSH`. Strobes are single-cycle (forced low while `ce` = 0). A frame with 1..4 bytes after the SFD is
  emitted as one bad 1-byte beat (counted in `RX_BAD`); a preamble with no SFD produces nothing.
* `u_rx_guard` (60..`MAX_FRAME_BYTES`, tkeep rules) ORs the receiver's verdict; `u_rx_fifo` (`DROP_WHEN_FULL` = 1)
  drops a bad frame whole and counts it; a frame meeting a full queue is consumed and counted as overflow.
* In-band status (RXD while RX_CTL is low on both edges: {duplex, speed, link}) is decoded into `STATUS` only. It
  gates nothing.

### 5.2 Receive-path reset

The receive engine (`rx_clk`: pairing, `u_gmii_rx`, `u_rx_guard`, the RX FIFO write side) and the RX FIFO read
side (`axis_clk`) are held in reset unless all of:

1. `CTRL.RX_EN` = 1,
2. the rate detector reports RXC in the band of `CTRL.SPEED` (`RX_CLK_OK`),
3. IDELAYCTRL `RDY` = 1.

`rtlnet_eth_rxc_rate` (clk125) counts the transitions of RXC/16 (a free-running `rx_clk` counter, crossed with
`rtlnet_sync`) over 4096 clk125 cycles (32.768 us). Bands: 1000 Mb/s 448..576 (nominal 512), 100 Mb/s 88..116
(102.4), 10 Mb/s 8..13 (10.24); they do not overlap, so an RXC at another speed than `CTRL.SPEED` never qualifies.
`RX_CLK_OK` rises after two consecutive in-band windows and falls at the first window out of band. A change of the
speed clears it at once, so **every speed change passes the receive path through reset**, even when RXC keeps
running.

The three conditions are combined in a clk125 register (`rx_run_req`), crossed into `axis_clk`, and applied by
`rx_path_on` at an `m_axis_rx` frame boundary: a frame partly delivered from the RX FIFO completes (it is already
whole in the FIFO), and no new frame starts once `rx_path_on` has fallen. `rx_path_on` is the asynchronous-assert
input of two `rtlnet_reset_sync` instances (`rx_clk` and `axis_clk`), so both FIFO sides enter reset together and
the `rx_clk` side asserts with RXC stopped; release follows RXC. With RXC absent, at the wrong rate, RX disabled or
the delay controller not ready, no frame is admitted or counted, good or bad (checked by the bench).

### 5.3 Transmit

* `u_tx_fifo` (`DROP_WHEN_FULL` = 0) publishes only whole frames, so the transmitter never underflows (a
  simulation-only `$error` makes a violation visible); `s_axis_tx_tready` falls only between frames when the FIFO is
  full.
* `rtlnet_gmii_tx`: states `S_IDLE`, `S_PREAMBLE`, `S_DATA`, `S_PAD`, `S_FCS`, `S_DISCARD`; double-buffered
  downsizer with a same-edge swap; `s_ready` qualified by `ce` so each FIFO pop is latched. Wire format: 7 x 0x55,
  0xD5, the frame, 0x00 padding to 60, the FCS (~CRC, low octet first), then 12 byte times with TX_EN low (exactly
  12 when frames are queued, at every speed).
* **Transmit enable**: with `CTRL.TX_EN` = 0, every frame that reaches the head of the TX FIFO is consumed (one beat
  per byte enable) and not sent, and not counted in `TX_FRAMES`. `s_axis_tx` keeps flowing, the protocol layer is
  never blocked, and no stale frame goes out when `TX_EN` returns to 1. A frame already on the wire when `TX_EN` falls
  completes. GMII stays idle and TXC keeps running.
* Pin layer: TXD/TX_CTL through ODDR (`SAME_EDGE`) on clk125 from one fabric register stage, held at 0 by the ODDR
  reset while `clk125_resetn` is low. TXC through an ODDR on `clk125_90` whose D1/D2 come only from a `clk125_90`
  retiming register (the clk125 -> clk125_90 transfer is flop to flop, 2 ns); TXC is free-running.
* 1000 Mb/s: TXC = 125 MHz, 2 ns after each data edge (the PHY TX delay stays off): setup 2 ns, hold 2 ns at the
  PHY. 10/100: byte enable once per 10 / 100 clk125 cycles, one nibble per TXC cycle (low first), TXC patterned from
  `clk125_90`: rising edge 25 % (100) / 26.5 % (10) into the nibble, falling edge 75 % / 76.5 %. Smallest setup /
  hold measured by the PHY model at its pins in the full-MAC bench: 2.0 / 2.0 ns at 1000 Mb/s, 10.0 / 10.0 ns at
  100 Mb/s, 106.0 / 94.0 ns at 10 Mb/s (at 10/100 the hold is set by TX_CTL at the TXC falling edge); TXC period
  8.0 / 40.0 / 400.0 ns.

### 5.4 Clocks, resets and crossings

| Domain | Contents |
|---|---|
| `clk125` | transmit engine, TX FIFO read side, TX pacing and data registers, rate detector, `rx_run_req`, control filter |
| `clk125_90` | TXC retiming register and the TXC ODDR only |
| `clk200` | IDELAYCTRL reference |
| `rx_clk` (BUFR of RXC) | 10/100 pairing, receiver, RX guard, RX FIFO write side, RXC probe counter, in-band registers |
| `axis_clk` | client slices, TX guard, FIFO client sides, register file, status, `rx_path_on` |
| `s_axi_aclk` | AXI4-Lite slave side of `u_axil_cdc` |

| Crossing | Primitive (instance) |
|---|---|
| frames rx_clk -> axis_clk | `rtlnet_packet_fifo` `u_rx_fifo` |
| frames axis_clk -> clk125 | `rtlnet_packet_fifo` `u_tx_fifo` |
| registers s_axi_aclk -> axis_clk | `rtlnet_axil_cdc` `u_axil_cdc` |
| `{RX_EN, TX_EN, SPEED}` axis_clk -> clk125 | `rtlnet_sync` `u_ctrl_sync` + two-sample stability filter |
| speed clk125 -> rx_clk | `rtlnet_sync` `u_speed_rx_sync` + filter (no reset: settled long before the receive reset releases) |
| IDELAYCTRL RDY -> clk125 / axis_clk | `rtlnet_sync` `u_idelay_rdy_sync`, `u_idelay_rdy_axis_sync` |
| RXC/16 probe rx_clk -> clk125 | `rtlnet_sync` `u_rxc_rate/u_probe_sync` |
| `rx_run_req` clk125 -> axis_clk | `rtlnet_sync` `u_rx_run_sync` |
| receive reset axis_clk -> rx_clk / axis_clk | `rtlnet_reset_sync` `u_rx_reset_sync`, `u_rx_m_reset_sync` |
| rate verdict, rate count, speed in effect -> axis_clk | `rtlnet_sync` `u_rate_ok_sync`, `u_rate_sync` (10 bits, + filter; the source holds 32.8 us), `u_speed_axis_sync` (+ filter) |
| in-band status rx_clk -> axis_clk | `rtlnet_sync` `u_inband_sync` + filter |
| frames sent clk125 -> axis_clk | `rtlnet_gray_sync` `u_tx_count_sync` |
| IDDR (BUFIO) -> fabric (BUFR) | same IBUF source: an ordinary timed path, no exception |
| clk125 -> clk125_90 TXC pattern | related clocks of one MMCM: timed, 2 ns |

The multi-bit level crossings are taken only when two consecutive synchronized samples agree, so no torn value is
used (the same filter the protocol wrapper uses for its MAC address copy). The only asynchronous-reset registers
after synthesis are the eight `pipe` flops of the two `rtlnet_reset_sync` instances (synthesis report: 8 registers
with asynchronous reset).

## 6. Board constraints

Recommended XDC block for the board top (`boards/nexys_video`). Port names are the Nexys Video master XDC names;
the MAC's cells are found by name under `u_rgmii_io`, so the block holds for any MAC instance path (with more than
one MAC in a design, prefix the patterns with the instance name). XDC has no Tcl control flow: keep the lines flat.

```tcl
# ---- RGMII pins: Nexys Video bank 13, 2.5 V (Nexys-Video-Master.xdc) ------------------------------
set_property -dict {PACKAGE_PIN V13  IOSTANDARD LVCMOS25} [get_ports eth_rxck]   ;# IO_L13P_T2_MRCC_13
set_property -dict {PACKAGE_PIN W10  IOSTANDARD LVCMOS25} [get_ports eth_rxctl]
set_property -dict {PACKAGE_PIN AB16 IOSTANDARD LVCMOS25} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN AA15 IOSTANDARD LVCMOS25} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN AB15 IOSTANDARD LVCMOS25} [get_ports {eth_rxd[2]}]
set_property -dict {PACKAGE_PIN AB11 IOSTANDARD LVCMOS25} [get_ports {eth_rxd[3]}]
set_property -dict {PACKAGE_PIN AA14 IOSTANDARD LVCMOS25 SLEW FAST} [get_ports eth_txck]
set_property -dict {PACKAGE_PIN V10  IOSTANDARD LVCMOS25 SLEW FAST} [get_ports eth_txctl]
set_property -dict {PACKAGE_PIN Y12  IOSTANDARD LVCMOS25 SLEW FAST} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN W12  IOSTANDARD LVCMOS25 SLEW FAST} [get_ports {eth_txd[1]}]
set_property -dict {PACKAGE_PIN W11  IOSTANDARD LVCMOS25 SLEW FAST} [get_ports {eth_txd[2]}]
set_property -dict {PACKAGE_PIN Y11  IOSTANDARD LVCMOS25 SLEW FAST} [get_ports {eth_txd[3]}]

# ---- Receive clock and the PHY's launch clock -------------------------------------------------------
# RXC at its fastest (1000 Mb/s); BUFIO/BUFR outputs are derived from it by Vivado.
create_clock -name rgmii_rxc -period 8.000 [get_ports eth_rxck]
# Virtual clock: RXC at the pins, the reference of the input delays.
create_clock -name rgmii_rxc_v -period 8.000

# ---- Input delays: RTL8211E Rev. 1.6 Table 65, PHY RX delay on (TsetupT, TholdT >= 1.2 ns) ----------
# The nibble for an RXC edge is valid from 1.2 ns before that edge (max -1.2) and the next nibble starts
# no earlier than 1.2 ns after it, i.e. half a period (4 ns) after its own edge minus 2.8 (min -2.8).
set_input_delay -clock rgmii_rxc_v -max -1.200 [get_ports {eth_rxd[*] eth_rxctl}]
set_input_delay -clock rgmii_rxc_v -min -2.800 [get_ports {eth_rxd[*] eth_rxctl}]
set_input_delay -clock rgmii_rxc_v -clock_fall -max -1.200 -add_delay [get_ports {eth_rxd[*] eth_rxctl}]
set_input_delay -clock rgmii_rxc_v -clock_fall -min -2.800 -add_delay [get_ports {eth_rxd[*] eth_rxctl}]

# ---- Same-edge capture (IDDR SAME_EDGE_PIPELINED): each nibble is checked on the edge it belongs to ---
set_multicycle_path -setup 0  -from [get_clocks rgmii_rxc_v] -to [get_clocks rgmii_rxc]
set_multicycle_path -hold  -1 -from [get_clocks rgmii_rxc_v] -to [get_clocks rgmii_rxc]
# Remove the opposite-edge setup pairs and the same-edge hold pairs (they describe no real capture).
set_false_path -setup -rise_from [get_clocks rgmii_rxc_v] -fall_to [get_clocks rgmii_rxc]
set_false_path -setup -fall_from [get_clocks rgmii_rxc_v] -rise_to [get_clocks rgmii_rxc]
set_false_path -hold  -rise_from [get_clocks rgmii_rxc_v] -rise_to [get_clocks rgmii_rxc]
set_false_path -hold  -fall_from [get_clocks rgmii_rxc_v] -fall_to [get_clocks rgmii_rxc]

# ---- Forwarded TXC: the clk125_90 ODDR in the pin layer, found by cell name ---------------------------
create_generated_clock -name rgmii_txc -multiply_by 1 \
  -source [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ */u_rgmii_io/u_txc_oddr}] -filter {REF_PIN_NAME == C}] \
  [get_ports eth_txck]

# ---- Output delays: RTL8211E Table 65, PHY TX delay off, receiver setup and hold 1.0 ns ---------------
# TXC rises 2 ns after each data edge (90 degrees); the default edge pairing checks that 2 ns window.
set_output_delay -clock rgmii_txc -max  1.000 [get_ports {eth_txd[*] eth_txctl}]
set_output_delay -clock rgmii_txc -min -1.000 [get_ports {eth_txd[*] eth_txctl}]
set_output_delay -clock rgmii_txc -clock_fall -max  1.000 -add_delay [get_ports {eth_txd[*] eth_txctl}]
set_output_delay -clock rgmii_txc -clock_fall -min -1.000 -add_delay [get_ports {eth_txd[*] eth_txctl}]

# ---- IDELAYE2 and their IDELAYCTRL in one group ---------------------------------------------------------
set_property IODELAY_GROUP rtlnet_rgmii [get_cells -hierarchical -filter {NAME =~ */u_rgmii_io/u_idelayctrl}]
set_property IODELAY_GROUP rtlnet_rgmii [get_cells -hierarchical -filter {NAME =~ */u_rgmii_io/*u_rxd_idelay}]
set_property IODELAY_GROUP rtlnet_rgmii [get_cells -hierarchical -filter {NAME =~ */u_rgmii_io/u_rx_ctl_idelay}]
```

Notes on the block:

* **IOB packing.** The receive and transmit registers are IDDR/ODDR primitives, which are ILOGIC/OLOGIC cells:
  they are in the IOB by construction, so no `IOB` property is set (an `IOB` property on a fabric flop raises a
  critical warning). Check the placed design: 5 IDDR in ILOGIC, 6 ODDR in OLOGIC, 5 IDELAYE2, 1 IDELAYCTRL,
  1 BUFIO, 1 BUFR.
* **Region.** `eth_rxck` must stay on the clock-capable pin V13 in bank 13 with RXD/RX_CTL: BUFIO and BUFR are
  region-local, so every `rx_clk` register places in that clock region.
* **No clock groups.** `rgmii_rxc`, the MMCM clocks and `cpu_clk` meet only in the RTLNet crossing primitives;
  `scripts/rtlnet_constrain_cdc.tcl` bounds them by cell name (architecture section 9): Gray pointers of
  `u_rx_fifo`/`u_tx_fifo` and `u_tx_count_sync` (max delay + bus skew of the source period), first stages of every
  `rtlnet_sync` (false path to `g_bit[*].sync_ff_reg[0]`), the `pipe_reg` clear pins of `u_rx_reset_sync` and
  `u_rx_m_reset_sync`, and the `req_*_hold` / `rsp_*_hold` bundles of `u_axil_cdc`. A blanket asynchronous group
  would override those bounds.
* **Timed, no exception.** IDDR -> first `rx_clk` register (BUFIO/BUFR of one IBUF) and the TXC pattern register
  clk125 -> `clk125_90` (2 ns) are ordinary related-clock paths.
* **10/100.** The constraints describe 1000 Mb/s, the tightest case. At 10/100 the TX edges are placed by the TXC
  pattern 10 ns (100) and 94 ns (10) or more from any data change, and RXC is 5 or 50 times slower.
* **Tap.** `RX_IDELAY_TAP` = 12 is the starting point for this layout (PHY RX delay on, BUFIO clock, data tap). The
  window closes when, in every corner, `Dclk - Ddata >= tsu - 1.2` (setup, same edge) and `Dclk - Ddata <= 1.2 - th`
  (hold, the opposite edge half a period earlier), Dclk = IBUF + BUFIO to the IDDR, Ddata = IBUF + IDELAYE2. Sweep the
  tap on the routed board design and keep the min-max point; board trace skew between RXC and RXD is not in this
  budget (layout not available).
* `eth_mdc`/`eth_mdio` belong to `rtlnet_mdio` (a slow bit-banged interface: false paths there).

## 7. Simulation-only RXC insertion

The unisim IBUF/BUFIO/BUFR models have no delay while the unisim IDELAYE2 adds 600 ps plus 78 ps per tap (1.536 ns
at tap 12). With the PHY model's 2 ns RX clock delay the IDDR clock edge would then sit 0.464 ns after the data
change instead of on the eye centre. The macro `RTLNET_SIM_RXC_INSERTION_NS` (in nanoseconds, bench command line
only) delays the IDDR clock alone (`rxc_iddr` in `rtlnet_rgmii_io_amd7.sv`) by that amount, which restores 2.0 ns
of setup and 2.0 ns of hold; `rx_clk` stays undelayed so the fabric registers take the previous IDDR output, as the
timed hardware path does. It is the one simulation-only construct of the pin layer, fenced by `ifdef` with the
hardware path in the `else` branch, and is never defined for synthesis. The AMD regression lines define it as
1.536; the GENERIC pin layer needs no insertion.

## 8. Verification

Runner: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_run_sim.ps1 -Bench <tb> -Filelist
cores/rtlnet_eth_mac/testbench/<tb>.f [-Tag t] [-Defines D] [-PlusArgs P]`; all lines of `testbench/regression.txt`
with `scripts/rtlnet_regression.ps1 -Match tb_rtlnet_eth_mac`.

| Bench | What it proves |
|---|---|
| `tb_rtlnet_eth_mac_gmii` | `rtlnet_gmii_rx`/`rtlnet_gmii_tx` with the MAC's guard + packet FIFO chain, at byte clock enables always-1, 1-in-10 and irregular (random garbage on the GMII inputs while ce is low): 24 good RX frames (60..1518 bytes, preambles of 0..7 octets, minimum gaps) byte-exact and in order with sink stalls; bad FCS, RX_ER mid-frame, RX_ER on the SFD alone, runt, oversize and SFD+3-byte frames each counted once on the FIFO's `bad_frame`; a preamble with no SFD and RX_ER with RX_DV low ignored; the receiver's `m_valid` never on two consecutive clocks; drop-when-full 4 stored / 2 overflow; 24 TX frames (14..1518) with 7 x 0x55 + 0xD5, zero padding to 60, FCS equal to the independent serial oracle (`rtlnet_tb_pkg::crc32_serial_fcs`), gaps >= 12 and exactly 12 byte times when queued, `gmii_tx_er` 0, TX FIFO pops = ceil(len/8) per frame, one `frame_sent` per frame; transmit disabled: frames consumed with the same pop count, nothing sent, source never blocked, then sending resumes |
| `tb_rtlnet_eth_mac` | the whole MAC with its pin layer against `rtlnet_rtl8211e_model`, registers through `rtlnet_tb_axil_master`, MDIO bit-banged by the bench: PHY reset pin, ID/BMCR/BMSR/ANAR/GBCR, soft reset (bit 15 seen set, then clear), RX delay through page 0xA4 register 28 with read-back, PHYSR; MAC ID/VERSION/CAPS/tap/reset values; RXC/speed mismatch (no admission, no counter change, `RX_CLK_RATE` = the true rate); running checks (STATUS, in-band status, status outputs); RX byte-exact including a short preamble; bad FCS, runt, oversize, RX_ER, dangling nibble (10/100) dropped and counted exactly; TX frames 14..1518 with preamble, padding, FCS, no TX_ER, gap >= 12 byte times, setup/hold >= 1 ns at the PHY (>= 20 % of the nibble at 10/100), nominal TXC period; PHY loopback; RX overflow 4 stored / 2 dropped; TX disable discards without blocking; RX disable and a mismatching speed write reset the receive path; CNT_CLEAR; ev_* pulse counts = counters; PHY link resolution (1000 advertisement dropped from GBCR, or 100 from ANAR, with restart-AN; forced 10 Mb/s with AN off; ANLPAR) followed by the MAC, then the defaults restored; with WALK a live speed walk (1000 -> 100 -> 10 -> 1000 or 10 -> 1000 -> 100 -> 10): link drop resets the receive path, firmware follows PHYSR, traffic in both directions at each step; zero PHY timing violations |
| `driver/test` | the driver against a mocked register map: identity rejection with no write, init, CAPS decode, speed codes, enable/link bits preserved across writes, invalid speed rejected with no write, status decode, bounded ready poll (stops when ready, polls exactly the bound otherwise), counter read and clear |

Results (10-22-2026, Active-HDL 11.1, Vivado 2025.2 unisim and XPM models):

| Line | Configuration | Result |
|---|---|---|
| `tb_rtlnet_eth_mac_gmii` | AMD (XPM RAM model) | PASS, 649 checks |
| `tb_rtlnet_eth_mac_gmii` `generic` | `RTLNET_TECH_GENERIC` | PASS, 649 checks |
| `tb_rtlnet_eth_mac_gmii` `neg` | `+INJECT_FAILURE` | TEST FAIL as required |
| `tb_rtlnet_eth_mac` `g1000` | AMD pin layer, 1000 Mb/s | PASS, 461 checks |
| `tb_rtlnet_eth_mac` `g100` | AMD, 100 Mb/s | PASS, 385 checks |
| `tb_rtlnet_eth_mac` `g10` | AMD, 10 Mb/s | PASS, 292 checks |
| `tb_rtlnet_eth_mac` `walk1000` | AMD, 1000 then 100, 10, 1000 | PASS, 708 checks |
| `tb_rtlnet_eth_mac` `walk10` | AMD, 10 then 1000, 100, 10 | PASS, 535 checks |
| `tb_rtlnet_eth_mac` `neg` | `+INJECT_FAILURE` | TEST FAIL as required |
| `tb_rtlnet_eth_mac` `gen1000` | GENERIC pin layer, 1000 Mb/s | PASS, 461 checks |
| `tb_rtlnet_eth_mac` `gen100` | GENERIC, 100 then 1000, 10, 100 | PASS, 628 checks |
| `test_rtlnet_eth_mac` (host gcc) | `-std=c11 -Wall -Wextra -Werror` | PASS, 41 checks |
| `mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c` | driver | compiles, no warning |

Deliberate failures (each check class shown failing once on a perturbed copy of the bench, originals unchanged):
GMII bench — expected FCS flipped, RX expectation shifted by one frame, bad-frame count +1, required minimum gap
13, pop count +1 byte, overflow count 3: each produced its CHECK FAILED lines. Full-MAC bench — RX expectation
shifted, TX expectation without padding, mismatch speed equal to the true speed, gap 13 byte times, RX_BAD + 1,
model FCS oracle flipped; in a second run the model's setup limit raised to 2.5 ns (at 1000 Mb/s) and the 10/100
margin based on a 4x nibble: each failed. Driver test — a wrong speed shift and an off-by-one poll loop: 7 checks
failed.

## 9. RTL8211E model user guide (`testbench/rtlnet_rtl8211e_model.sv`)

A behavioural model of the RTL8211E-VB/VL at its RGMII and MDIO pins, written from the datasheet Rev. 1.6 and the
Nexys Video board facts. Statements the datasheet leaves open are marked (verify) in the source. Needs
`rtlnet_tb_pkg` (for `bytes_t` and the serial CRC oracle).

### 9.1 Parameters

| Parameter | Default | Meaning |
|---|---:|---|
| `NAME` | `"rtl8211e"` | message prefix |
| `PHYAD` | 1 | PHY address strap (Nexys Video: 1); address 0 always answers; `PHYAD` 0 answers every address |
| `RXDLY_STRAP`, `TXDLY_STRAP` | 0, 0 | RGMII clock delay straps (Nexys Video: no delay); register 28 bit 13 overrides them |
| `DELAY_PS` | 2000 | internal RGMII clock delay (datasheet Table 13: 2 ns) |
| `SKEW_PS` | 0 | extra skew on RXC and on the TX sampling clock (what-if timing) |
| `PARTNER_SPEED` | 2'b10 | link partner's highest speed (00 10M, 01 100M, 10 1000M); run time: `set_partner_speed` |
| `INBAND_STATUS` | 1 | drive {duplex, speed, link} on idle RXD (the board PHY does) |
| `RESET_SETTLE_NS` | 30 000 000 | reset release to MDIO access (datasheet 30 ms); shorten in benches |
| `LINK_UP_DELAY_NS` | 2 000 000 000 | MDIO access or relink to link up (stands in for auto-negotiation, verify) |
| `SPEED_CHANGE_DELAY_NS` | 2 000 000 000 | link-down time on a partner speed change |
| `SOFT_RESET_NS` | 20 000 | BMCR.15 reads 1 this long after a software reset (verify) |
| `RX_SETUP_PS`, `RX_HOLD_PS` | 1000, 1000 | TX capture setup/hold limits (Table 65: 1.0 ns at the receiver) |
| `IFG_BYTES` | 12 | idle byte times after each injected frame |
| `RX_ER_BYTE` | 40 | byte after the SFD that carries RX_ER with `FAULT_RX_ER` |
| `MDIO_OUT_DELAY_NS` | 10 | MDC rising edge to read data on MDIO |
| `VERBOSE` | 0 | print link, MDIO and capture events |

The full-MAC bench uses `RESET_SETTLE_NS` 5 000, `LINK_UP_DELAY_NS` 20 000, `SPEED_CHANGE_DELAY_NS` 20 000,
`SOFT_RESET_NS` 60 000 (longer than one 25.6 us MDIO frame, so the bench can see bit 15 set).

### 9.2 Ports

| Port | Dir | Meaning |
|---|---|---|
| `phy_rst_n` | in | PHYRSTB: low stops RXC, idles RXD/RX_CTL, restores every register default, ignores MDIO; after release `RESET_SETTLE_NS` then `LINK_UP_DELAY_NS` |
| `mdc`, `mdio` | in, inout | Clause 22 management; `mdio` is open drain: provide a `pullup` in the bench (the board has one) |
| `rxc`, `rxd[3:0]`, `rx_ctl` | out | RGMII receive |
| `txc`, `txd[3:0]`, `tx_ctl` | in | RGMII transmit |
| `link_up`, `link_speed[1:0]` | out | model-only: link state and speed code |
| `rxdly_on`, `txdly_on` | out | model-only: effective RX/TX clock delay (strap or register 28) |
| `tx_viol_count` | out (int) | model-only: TX setup/hold violations so far |

Hierarchically readable after `get_tx_frame`: `last_gap_ns` (TX_EN low time before the frame; -1 for the first),
`last_setup_min_ns`, `last_hold_min_ns` (smallest setup/hold in the frame), `tx_period_ns` (last TXC period),
`rx_frames_sent`, `tx_frames_seen`.

### 9.3 Tasks

| Task | Use |
|---|---|
| `inject(frame, faults = 0)` | queue a frame (no FCS); the model appends the FCS (serial oracle) and sends 7 x 0x55, 0xD5, frame, FCS, then `IFG_BYTES` idle at the link speed |
| `inject_raw(bytes, faults = 0)` | queue bytes after the SFD as given (to send a bad FCS) |
| `wait_rx_idle(timeout_ns, ok)` | wait until every queued frame has left the pins |
| `get_tx_frame(frame, fcs_ok, pre_ok, err, timeout_ns, got)` | next captured TX frame without its FCS; `fcs_ok` from the serial oracle, `pre_ok` = 7 x 0x55 + 0xD5, `err` = TX_ER or a dangling nibble |
| `set_partner_speed(code)` | link partner speed change: link drops for `SPEED_CHANGE_DELAY_NS`, comes back at the new resolved speed |
| `set_cable(connected)` | cable unplug (0) / plug (1) |
| `force_rxc_speed(code)` | RXC and RX framing at another speed than PHYSR reports (11 = follow the link) |

Fault mask bits for `inject`: 1 `FAULT_RX_ER` (RX_ER on byte `RX_ER_BYTE`), 2 `FAULT_DANGLING` (10/100: one extra
nibble 0x3 after the last byte), 4 `FAULT_SHORT_PREAMBLE` (10/100: 14 instead of 15 preamble nibbles, so an
alignment on RX_DV would pair the wrong nibbles; 1000: 3 preamble octets).

### 9.4 Behaviour

* **Link resolution.** BMCR.12 = 1: the highest speed advertised by both sides (local 1000 from GBCR 9.9/9.8, 100
  from ANAR 4.8/4.7, 10 from ANAR 4.6/4.5; partner up to `PARTNER_SPEED`), full duplex; nothing advertised = no
  link. BMCR.12 = 0: forced speed {0.6, 0.13} and duplex 0.8. Power-down (0.11) keeps the link down. A software
  reset, restart-AN, or a change of BMCR bits 13/12/11/8/6 relinks after `LINK_UP_DELAY_NS`.
* **Registers.** BMCR 0 (RW, 0x1140; 15 reset as above then BMCR = 0x1140, 9 self-clears; a software reset restores
  BMCR only, verify), BMSR 1 (0x7949; 0x796D while linked; link bit real-time, not latching, verify), PHYID1 2
  (0x001C), PHYID2 3 (0xC915), ANAR 4 (RW, 0x05E1), ANLPAR 5 (while linked with AN: 0x45E1 / 0x41E1 / 0x4061 for a
  1000 / 100 / 10 partner, model values), GBCR 9 (RW, 0x0200), GBSR 10 (0x3800 while linked at 1000, model value),
  PHYSR 17 (15:14 speed, 13 duplex, 11 resolved, 10 link, 1 local receiver ok), 28 (extension page 0xA4 register:
  RW, reset 0x8575 as read on the board; reached only with PAGSEL = 7 and EPAGSR = 0xA4), EPAGSR 30 (RW 7:0), PAGSEL
  31 (RW 2:0). Other registers read 0 and ignore writes. Page selection does not remap registers 0..17.
* **RGMII delays.** Register 28 bit 13 = 1: bit 11 = RX delay, bit 12 = TX delay; else the straps. The RX delay
  delays the RXC pin by `DELAY_PS` (the delay sits on the clock, datasheet Fig. 33); the TX delay delays the PHY's
  sampling of TXC (Fig. 32).
* **RX timing.** RXD/RX_CTL change on the internal clock edges; with the delay on the RXC pin edge follows 2 ns
  later (data centred at 1000 Mb/s). 10/100: one nibble per rising edge; RX_CTL on the falling edge = RX_DV xor
  RX_ER.
* **TX checks.** Setup and hold at every sampling edge (both edges at 1000; rising edge for TXD and both edges for
  TX_CTL at 10/100) against `RX_SETUP_PS`/`RX_HOLD_PS`; violations are printed and counted.
* **Loopback.** BMCR.14: each captured frame with a good preamble is also sent back on RX.
* Not modelled: MII/GMII pins, the analog side, auto-negotiation pages, LEDs, INTB/PMEB, EEE (the low-power-idle
  code the board PHY sends with an EEE partner), interrupts, MDIO timing checks.

### 9.5 Typical use

```systemverilog
wire mdio;
pullup (mdio);
rtlnet_rtl8211e_model #(.PHYAD(1), .RESET_SETTLE_NS(5_000), .LINK_UP_DELAY_NS(20_000),
                        .SPEED_CHANGE_DELAY_NS(20_000)) u_phy (
  .phy_rst_n(eth_rst_n), .mdc(eth_mdc), .mdio(mdio),
  .rxc(eth_rxck), .rxd(eth_rxd), .rx_ctl(eth_rxctl), .txc(eth_txck), .txd(eth_txd), .tx_ctl(eth_txctl),
  .link_up(), .link_speed(), .rxdly_on(), .txdly_on(), .tx_viol_count(phy_viol));

initial begin
  u_phy.set_partner_speed(2'b01);               // a 100 Mb/s partner
  // firmware/driver: MDIO reg 31 = 7, reg 30 = 0xA4, reg 28 |= 0x2800, reg 31 = 0; poll PHYSR
  u_phy.inject(frame);                          // frame without FCS
  u_phy.get_tx_frame(f, fcs_ok, pre_ok, err, 100_000, got);
end
```

## 10. Synthesis

`rtlnet_synth_check` (out of context, `xc7a200tsbg484-1`, Vivado 2025.2, default parameters), 10-22-2026:
`rtlnet_synth_check: PASS rtlnet_eth_mac`, **0 critical warnings**.

| Resource | Used |
|---|---:|
| Slice LUTs (logic) | 1104 |
| Slice registers | 1682 (8 with asynchronous reset: the two `rtlnet_reset_sync` chains) |
| Block RAM tiles | 5 (4 RAMB36E1 + 2 RAMB18E1: two 8 KiB packet FIFOs of 73-bit words) |
| IDELAYE2 / IDELAYCTRL | 5 / 1 |
| IDDR (ILOGIC) / ODDR (OLOGIC) | 5 / 6 |
| BUFIO / BUFR | 1 / 1 |
| IBUF | 6 |

Implementation and timing of the RGMII constraints (section 6) are board-top work and were not run here.

## 11. Limitations

* Full duplex only; no half duplex, carrier extension, pause frames, VLAN awareness or jumbo frames (beyond
  `MAX_FRAME_BYTES` up to the FIFO slot size).
* The rate detector assumes `clk125` = 125 MHz.
* A client that stalls `m_axis_rx` in the middle of a frame postpones the receive-path reset until that frame
  completes (the reset is applied at a frame boundary so frames are never truncated).
* A PHY that stops RXC in low-power idle (EEE) would reset the receive path; the frame after each wake is then lost
  (the board PHY kept RXC running in the recorded observations).
* Frames ending one to four bytes after the SFD count in `RX_BAD`; bursts with no SFD are not counted.
* Architecture section 7.2 also lists a software-reset and a promiscuous-debug CTRL bit; this register map (CTRL bits
  0, 1, 5:4, 8, 16) has neither: there is no address filter in the MAC, and the receive path resets through RX_EN or
  a speed write. The tap readback of section 7.2 is `RX_IDELAY_TAP` (0x018).
* Not run: hardware, implementation/STA of the RGMII interface, the tap sweep, a MicroBlaze link of the driver.

## 12. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version: RTL, pin layers (AMD 7-series, generic), register map 0x10222026, driver, PHY model, benches |
