# rtlnet_eth_protocol — protocol wrapper

| Item | Value |
|---|---|
| Core | `rtlnet_eth_protocol` |
| Document revision | 10-22-2026 |
| Language | SystemVerilog-2012 |
| Contract | `documentation/rtlnet_architecture.md` sections 4, 5, 6.1, 7.4-7.6, 9, 12, 15.3, 15.4 |
| Sources | `hdl/rtlnet_eth_protocol.sv` (top), `hdl/rtlnet_eth_protocol_ingress.sv` (axis_clk ingress), `hdl/rtlnet_eth_protocol_regs.sv` (register file), `hdl/rtlnet_eth_protocol.f` |
| Verification | Active-HDL 11.1: `tb_rtlnet_eth_protocol` (three clock pairs, GENERIC), `tb_rtlnet_eth_protocol_regs`, driver host test |

The wrapper sits on the MAC client streams. It owns the node address, drops frames that are not for the
node, queues frames between the MAC clock and the protocol clock, presents one frame at a time to every
protocol leaf, and returns their replies to the MAC through a fixed-priority, per-frame arbiter. Leaves
never see the MAC or each other.

```
 axis_clk                                                    | proto_clk
 s_axis -> u_ingress: u_in_slice -> filter F1..F4 -> drop -> u_ingress_fifo -> dequeue (GAP 16 / WAIT / PASS)
             ^ u_filt_cfg_sync (MAC, FILTER_ENABLE)          |      |  fan-out: one frame to every leaf
           counters FRAMES/FILTERED/DROPPED -> u_cnt_*_sync -+->    v
                                                             |   leaf 0 UDP  1 ICMP  2 ARP  3 DHCP  4 iperf
 m_axis <- u_out_slice <- u_egress_fifo <-------------------+--- u_arb_slice <- arbiter (fixed priority, per frame)
 EGRESS_FRAMES counter -> u_cnt_egress_sync -------------->  |   u_regs: address, CTRL, STATUS, counters
 s_axi (s_axi_aclk) -> u_axil_cdc ------------------------>  |   u_axil_slave -> window decode (addr[15:12])
```

## 1. Interface (architecture 15.3)

| Group | Ports |
|---|---|
| clocks | `axis_clk`, `proto_clk`, `app_clk`, `s_axi_aclk` |
| resets | `axis_resetn`, `proto_resetn`, `app_resetn`, `s_axi_aresetn` (synchronous, active low, one per clock, all from one assertion) |
| from MAC RX (axis_clk) | in `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`; out `s_axis_tready` (a flop; never back-pressures) |
| to MAC TX (axis_clk) | out `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`; in `m_axis_tready` (may stall at any time) |
| application RX (app_clk) | out `m_axis_app_tdata[63:0]`, `m_axis_app_tkeep[7:0]`, `m_axis_app_tvalid`, `m_axis_app_tlast`; in `m_axis_app_tready` |
| application TX (app_clk) | in `s_axis_app_tdata[63:0]`, `s_axis_app_tkeep[7:0]`, `s_axis_app_tvalid`, `s_axis_app_tlast`; out `s_axis_app_tready` |
| registers | `s_axi_*` AXI4-Lite slave, `ADDR_W` 16 (the 64 KiB sub-map of architecture 6.1), 32-bit data |
| status (proto_clk, registered, LEDs only) | `stat_ip_valid` (effective IP is not 0.0.0.0), `stat_dhcp_bound` (effective IP is a DHCP lease), `ev_rx_frame` (one clock per frame delivered to the leaves), `ev_tx_frame` (one clock per frame written to the egress queue) |

The application streams belong to the UDP socket leaf; with `UDP_ENABLE = 0` they are idle
(`m_axis_app_tvalid` 0, `s_axis_app_tready` 1).

| Parameter | Default | Use |
|---|---|---|
| `PROTO_CLK_HZ` | 50 000 000 | ARP reply delay `PROTO_CLK_HZ / 40000` (25 us; 1250 at 50 MHz), DHCP `MS_CYCLES = PROTO_CLK_HZ / 1000`, iperf `CLK_HZ` |
| `INGRESS_FIFO_KB` | 16 | ingress queue (8 slots of one 1518-byte frame); 4, 8, 16, 32 ... are legal (`rtlnet_packet_fifo`) |
| `EGRESS_FIFO_KB` | 8 | egress queue (4 slots) |
| `ARP_ENABLE`, `ICMP_ENABLE`, `DHCP_ENABLE`, `IPERF_ENABLE`, `UDP_ENABLE` | 1 | instance the leaf (0: its outputs are tied idle) |
| `ICMP_BUF_KB` | 2 | to `rtlnet_icmp` |
| `DHCP_BUF_KB` | 1 | to `rtlnet_dhcp` |
| `IPERF_PORT` | 5001 | to `rtlnet_iperf.UDP_PORT` (`MAX_DGRAM_BYTES` 1472) |
| `NUM_SOCKETS`, `UDP_RX_BUF_KB`, `UDP_TX_BUF_KB` | 4, 16, 8 | to `rtlnet_udp_socket` |
| `RAM_STYLE` | `"block"` | every buffer (queues and leaf buffers) |

## 2. Register map

### 2.1 Sub-map windows (address bits 15..12)

| Window | Offset | Register file | Leaf index |
|---:|---:|---|---:|
| 0 | 0x0000 | wrapper (below) | — |
| 1 | 0x1000 | `rtlnet_arp` (`cores/rtlnet_arp/documentation`) | 2 |
| 2 | 0x2000 | `rtlnet_icmp` (`cores/rtlnet_icmp/documentation`) | 1 |
| 3 | 0x3000 | `rtlnet_dhcp` | 3 |
| 4 | 0x4000 | `rtlnet_iperf` | 4 |
| 5 | 0x5000 | `rtlnet_udp_socket` | 0 |
| 6-15 | | unused: read 0, writes ignored | |

An absent leaf's window reads 0. Every access is answered OKAY; a write with `wstrb != 4'hF` is ignored
(`rtlnet_axil_slave`).

### 2.2 Wrapper registers (window 0)

Defined in `driver/rtlnet_eth_protocol.h`, mirrored by localparams in `hdl/rtlnet_eth_protocol_regs.sv`.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | `0x50524F54` | "PROT" |
| 0x004 | `VERSION` | RO | `0x10222026` | register-map date code |
| 0x008 | `CAPS` | RO | build | `[4:0]` LEAF_PRESENT (bit i = leaf index i built), `[15:8]` `INGRESS_FIFO_KB`, `[23:16]` `EGRESS_FIFO_KB`, `[31:24]` `NUM_SOCKETS` (0 without the UDP leaf) |
| 0x00C | `CTRL` | RW | `0x00001F01` masked | bit 0 `FILTER_ENABLE` (1; 0 = promiscuous), `[12:8]` `LEAF_ENABLE` (bit 8+i = leaf index i; reset = present leaves; stored masked by LEAF_PRESENT), bit 16 `CNT_CLEAR` (self-clearing pulse, reads 0) |
| 0x010 | `STATUS` | RO | | bit 0 `IP_FROM_DHCP`, bit 1 `IP_VALID`, bit 2 `LEASE_VALID`, `[12:8]` `LEAF_BUSY`, bit 16 `INGRESS_PENDING` (a frame waits in the ingress queue), bit 17 `EGRESS_FULL`, bit 18 `DELIVERING` (a frame is being delivered to the leaves), bit 19 `ARBITER_ACTIVE` |
| 0x014 | `LOCAL_MAC_HI` | RW | `0x00000249` | `[15:0]` MAC octets 0-1. A write is staged; reads return the MAC in use |
| 0x018 | `LOCAL_MAC_LO` | RW | `0x4B524E01` | MAC octets 2-5. The write commits staged HI and LO as one 48-bit change |
| 0x01C | `STATIC_IP` | RW | `0xC0A901DC` | 192.169.1.220 |
| 0x020 | `NETMASK` | RW | `0xFFFFFF00` | 255.255.255.0 |
| 0x024 | `GATEWAY` | RW | `0xC0A90101` | 192.169.1.1 |
| 0x028 | `EFFECTIVE_IP` | RO | `STATIC_IP` | the address the leaves use |
| 0x02C | `EFFECTIVE_MASK` | RO | `NETMASK` | the mask the UDP socket leaf uses |
| 0x030 | `EFFECTIVE_GATEWAY` | RO | `GATEWAY` | the gateway the UDP socket leaf uses |
| 0x040 | `INGRESS_FRAMES` | RO | 0 | frames that passed the filter and were stored whole |
| 0x044 | `INGRESS_FILTERED` | RO | 0 | frames discarded by the destination filter |
| 0x048 | `INGRESS_DROPPED` | RO | 0 | frames that passed the filter but found no free slot, or were longer than one slot |
| 0x04C | `EGRESS_FRAMES` | RO | 0 | frames accepted by the MAC (`m_axis` last-beat handshakes) |

Effective address: while the DHCP leaf is built, enabled (`LEAF_ENABLE` bit 3) and its `lease_valid` is
high, `EFFECTIVE_IP/MASK/GATEWAY` are its `lease_ip`, `lease_mask`, `lease_router` and
`STATUS.IP_FROM_DHCP` is 1; otherwise they are `STATIC_IP`, `NETMASK`, `GATEWAY`.

Counter identity (once traffic has stopped and the counters have crossed, a few clocks):
frames offered at `s_axis` = `INGRESS_FILTERED + INGRESS_FRAMES + INGRESS_DROPPED`. `CNT_CLEAR` restarts
all four together.

## 3. Design

### 3.1 Ingress (axis_clk, `rtlnet_eth_protocol_ingress`)

- `u_in_slice` (`rtlnet_axis_reg_slice`, downstream ready tied 1): `s_axis_tready` is a flop, 1 from the
  clock after reset on.
- Filter configuration: the local MAC and `FILTER_ENABLE` are `proto_clk` registers. They cross into
  `axis_clk` once, 49 bits through `u_filt_cfg_sync` (`rtlnet_sync`, 2 stages). A new value is taken only
  when two consecutive synchronized samples are equal and at least 4 clocks after reset (until then the
  reset value, default MAC with the filter on, is used). A change applies to frames that begin after it.
  The MAC register changes all 48 bits in one `proto_clk` edge (staged HI), so the bits of one change
  arrive together.
- Filter stages, one or two LUT levels each: F1 the beat and a first-beat flag; F2 six 16-bit equality
  flags of bytes 0-5 (three against 0xFFFF, three against the MAC); F3 the candidate
  (`!FILTER_ENABLE || broadcast || local MAC`); F4 the per-frame pass latch (first beat takes the
  candidate, later beats the held verdict). Multicast and other unicast frames are discarded and counted.
- Drop decision: the ingress FIFO is built with `DROP_WHEN_FULL = 0`, so its `s_ready` is low only between
  frames while it is full. At a frame's first beat `s_ready` is the verdict: ready, the frame is stored;
  not ready, the frame is dropped whole and `drop_hold` withholds its remaining beats so the FIFO never
  starts storing it half way. The count is exact in `axis_clk` (the FIFO's own overflow event lives in the
  read clock and can merge close events). A simulation `$error` reports a mid-frame beat offered to a
  not-ready FIFO.
- Counters (axis_clk, never cleared): `FILTERED` at the discarded frame's first beat, `FRAMES` at a stored
  frame's last beat, `DROPPED` at the first beat of a frame that found no slot or at the beat where an
  over-slot frame is discarded (`ing_beats` mirrors the FIFO's word count). Each frame is counted once.

### 3.2 Queues

| Instance | Write / read clock | Size | Slots (1518-byte frames) | RAM (AMD) |
|---|---|---|---|---|
| `u_ingress_fifo` | axis_clk / proto_clk | `INGRESS_FIFO_KB` 16 | 8 | 4 RAMB36 + 1 RAMB18 |
| `u_egress_fifo` | proto_clk / axis_clk | `EGRESS_FIFO_KB` 8 | 4 | 2 RAMB36 + 1 RAMB18 |

Both are `rtlnet_packet_fifo` with `DROP_WHEN_FULL = 0`. The egress queue never drops: a full queue
back-pressures the arbiter slice, the arbiter and the granted leaf. `u_out_slice` registers the MAC side.

### 3.3 Dequeue controller (proto_clk)

| State | Action |
|---|---|
| `DQ_GAP` | 16 idle clocks after each frame's last beat and after reset |
| `DQ_WAIT` | until no leaf is busy |
| `DQ_PASS` | `iq_ready` high: one frame to every leaf (`leaf_in_tvalid = iq_valid && DQ_PASS`); back to `DQ_GAP` on its last beat |

This gives the leaf-contract guarantees: one frame at a time, at least 16 idle clocks after each frame
(the busy rule allows 12), no frame while any leaf is busy. A simulation `$error` reports a leaf with
`s_axis_tready` low while a beat is presented. Throughput toward the leaves: 64 bits per `proto_clk`
minus about 18 clocks per frame.

### 3.4 Leaves

| Index | Leaf | Window | Instance (generate) | Parameters passed |
|---:|---|---:|---|---|
| 0 | `rtlnet_udp_socket` | 5 | `g_udp.u_udp_socket` | `NUM_SOCKETS`, `UDP_RX_BUF_KB`, `UDP_TX_BUF_KB`, `RAM_STYLE`; extra ports `app_clk`, `app_resetn`, both application streams, `local_mask`, `local_gateway` |
| 1 | `rtlnet_icmp` | 2 | `g_icmp.u_icmp` | `ICMP_BUF_KB`, `RAM_STYLE` |
| 2 | `rtlnet_arp` | 1 | `g_arp.u_arp` | `REPLY_DELAY_CYCLES = PROTO_CLK_HZ / 40000` |
| 3 | `rtlnet_dhcp` | 3 | `g_dhcp.u_dhcp` | `MS_CYCLES = PROTO_CLK_HZ / 1000`, `DHCP_BUF_KB`, `RAM_STYLE`; outputs `lease_valid`, `lease_ip`, `lease_mask`, `lease_router`, `lease_server`, `lease_time_s` |
| 4 | `rtlnet_iperf` | 4 | `g_iperf.u_iperf` | `CLK_HZ = PROTO_CLK_HZ`, `UDP_PORT = IPERF_PORT`, `MAX_DGRAM_BYTES = 1472` |

Every leaf gets `clk = proto_clk`, `resetn = proto_resetn`, `enable = LEAF_ENABLE[index]` (already masked
by the present leaves), the shared fan-out stream (`iq_data`, `iq_keep`, `leaf_in_tvalid`, `iq_last`),
`local_mac` and `local_ip` (the effective IP) straight from the register file, and its own register
strobes. Indices are fixed whatever is enabled. A disabled leaf's branch ties its `m_axis_tvalid`,
`m_axis_tlast`, data and keep to 0, `busy` to 0, its read data to 0 and its `s_axis_tready` to 1 (and,
for DHCP, the lease outputs to 0; for UDP, the application ports idle).

### 3.5 Arbiter (proto_clk)

One-hot `grant` (bit 0 idle, bit i+1 leaf i). At idle the lowest-index leaf with `m_axis_tvalid` high is
granted (UDP, ICMP, ARP, DHCP, iperf); the grant holds until that leaf's last beat is taken by
`u_arb_slice` (no preemption), then returns to idle for one clock, so a waiting reply is picked between two
frames of a streaming leaf. Only the granted leaf sees `m_axis_tready`; the others hold their output. The
decision reads only registered `tvalid` flags (each leaf's output is a register slice).

### 3.6 Register path

`u_axil_cdc` (`rtlnet_axil_cdc`, `ADDR_W` 16) carries each AXI4-Lite transaction from `s_axi_aclk` to
`proto_clk`; `u_axil_slave` (`rtlnet_axil_slave`, `ADDR_W` 16) turns it into one-clock strobes. Writes and
reads are steered by `addr[15:12]`; each leaf gets `reg_*_addr[11:0]`. The read window is registered at
`reg_rd_en` and selects the window's registered read data in the next clock (the clock in which the slave
samples it). Every register file is a single-clock block in `proto_clk`.

### 3.7 Clocks, resets, crossings

| Crossing | Instance | Primitive | Constraint hook |
|---|---|---|---|
| frames axis_clk -> proto_clk | `u_ingress_fifo` | `rtlnet_packet_fifo` (Gray frame counters) | `*u_ingress_fifo`: `s_gray -> s_gray_m1`, `m_gray -> m_gray_s1` |
| frames proto_clk -> axis_clk | `u_egress_fifo` | `rtlnet_packet_fifo` | `*u_egress_fifo`, same |
| filter MAC + FILTER_ENABLE | `u_ingress/u_filt_cfg_sync` | `rtlnet_sync` 2 stages + two-equal-sample filter | first-stage false path to `g_bit[*].sync_ff_reg[0]` |
| four counters axis_clk -> proto_clk | `u_cnt_frames_sync`, `u_cnt_filtered_sync`, `u_cnt_dropped_sync`, `u_cnt_egress_sync` | `rtlnet_gray_sync` | `gray_src_reg -> gray_dst_ff_reg[0]`, max delay + bus skew of one axis_clk period |
| registers s_axi_aclk -> proto_clk | `u_axil_cdc` | `rtlnet_axil_cdc` | toggles via `rtlnet_sync`; `req_*_hold`/`rsp_*_hold` bundles max delay of the destination period |

No other signal crosses: leaves, arbiter, dequeue controller and register file are all `proto_clk`; the
UDP socket leaf owns its `app_clk` crossings. All four resets must come from one assertion
(`rtlnet_reset_sync` per clock in the board top): both packet FIFOs and `rtlnet_axil_cdc` require their
two sides to reset together.

## 4. Adding a leaf (integration guide)

A leaf is any `proto_clk` module with the exact contract ports of architecture 15.4 (`clk`, `resetn`,
`enable`, `s_axis_*`, `m_axis_*`, `local_mac`, `local_ip`, `busy`, the 12-bit register port, then its own
ports). To add one:

1. Build the leaf to the contract: hold `s_axis_tready` at 1; output through one `rtlnet_axis_reg_slice`
   so a started frame has no gaps and holds while not granted; raise `busy` (a flop) within 12 clocks of
   the last beat of any frame it acts on and hold it until it can take a new frame; ignore a frame that
   starts while it is not idle; register its read data one clock after `reg_rd_en`; ignore frames and
   send nothing while `enable` is low; standard `ID`/`VERSION`/`CAPS` header.
2. Choose a leaf index (the arbiter priority; 0 is highest) and a register window (`addr[15:12]`). Raise
   `N_LEAVES` and the width of `LEAF_PRESENT`/`LEAF_ENABLE`/`LEAF_BUSY` if the index is 5 or above (the CTRL
   and STATUS fields have room up to bit 15 and 7 more windows are free); add `LEAF_<NAME>` and
   `WIN_<NAME>` localparams.
3. Add an `<NAME>_ENABLE` parameter and its bit in `LEAF_PRESENT`.
4. Add the window decode: `leaf_reg_wr_en[LEAF_<NAME>]`, `leaf_reg_rd_en[LEAF_<NAME>]` and a case of the
   read-data mux.
5. Instance the leaf in a `g_<name>` generate branch onto the packed vectors at its index
   (`leaf_tdata[i*64 +: 64]`, `leaf_tkeep[i*8 +: 8]`, `leaf_tvalid[i]`, `leaf_tlast[i]`, `leaf_tready[i]`,
   `leaf_s_tready[i]`, `leaf_busy[i]`, `leaf_rd_data[i*32 +: 32]`) with `proto_clk`/`proto_resetn`, the
   fan-out stream, `local_mac`/`local_ip` and `leaf_enable[i]`. In the `g_no_<name>` branch tie its outputs
   idle (data/keep/valid/last 0, `s_tready` 1, `busy` 0, read data 0) and any outputs it drives.
6. Add the leaf's filelist to `hdl/rtlnet_eth_protocol.f` (a `-f` line) and its window to
   `driver/rtlnet_eth_protocol.h` (`RTLNET_PROTO_WIN_*`, `RTLNET_PROTO_LEAF_*`).
7. If the leaf has its own clock domain, it owns the crossings inside itself, with stable instance names
   the constraint script can find (the UDP socket leaf's `app_clk` FIFOs are the model).
8. Verify: a unit bench with `rtlnet_tb_leaf_busy_monitor`; in `tb_rtlnet_eth_protocol` add a monitor on
   the new index and the leaf's traffic; check `CAPS`, the window's `ID`, and the counter identity.

The DHCP, iperf and UDP socket leaves are already instanced this way against 15.4; their filelists are
commented placeholders in `hdl/rtlnet_eth_protocol.f` until those cores land.

## 5. Verification

### 5.1 `tb_rtlnet_eth_protocol` (wrapper with ARP and ICMP; DHCP, iperf, UDP disabled)

Driven at the MAC client streams with `rtlnet_tb_axis_src`/`rtlnet_tb_axis_sink` and through AXI4-Lite
from `s_axi_aclk` 100 MHz with `rtlnet_tb_axil_master`. Clock pair from `+CLKPAIR`: 1 axis 62.5 MHz /
proto 50 MHz (16.000 / 20.003 ns), 2 axis 156.25 MHz / proto 50 MHz (6.400 / 20.003 ns), 3 axis 50 MHz /
proto 62.5 MHz (20.000 / 16.007 ns); start offsets differ. Expected replies are bench-built
(`testbench/rtlnet_tb_eth_frames_pkg.sv`) and compared byte by byte.

Always-on monitors: `rtlnet_tb_leaf_busy_monitor` on the ICMP and ARP leaves inside the wrapper; at least
16 idle `proto_clk` clocks before every frame toward the leaves; no frame starts while a leaf is busy;
`s_axis_tready` never low after reset; stream rules at `m_axis` (sink).

| Phase | What it proves |
|---|---|
| register map | wrapper ID, VERSION, CAPS (`0x00081006`), CTRL, STATUS, address registers, effective address, counters at reset; ARP and ICMP IDs/CAPS through windows 1 and 2; windows 3, 4, 5, 6, 15 read 0; RO writes and a partial (`wstrb` 0x3) write ignored; LED outputs; application ports idle |
| ARP and ping | ARP request answered byte-exact; pings with payload 0, 64, 1472 and to the broadcast MAC answered byte-exact |
| filter | wrong unicast, two multicasts, one differing bit (bits 0 and 7) in each of the six MAC bytes: filtered and counted; a non-IP frame to the local MAC stored, not answered; 40 wrong-MAC frames back to back with 2 pings inside: only the pings answered; promiscuous (`FILTER_ENABLE` 0): wrong unicast and multicast pings answered; filter restored |
| over-slot | a 2100-byte frame to the local MAC: dropped and counted, the next ping answered |
| ingress full | 40 pings of 1400 bytes at line rate: replies + `INGRESS_DROPPED` = 40, at least one drop, replies in order and byte-exact (62.5/50: 23 + 17; 156.25/50: 14 + 26; 50/62.5: 32 + 8) |
| egress back-pressure | 10 pings with 30 % random ready, then 6 pings and an ARP request with ready held at 0 (`STATUS.EGRESS_FULL` seen, nothing completes): all answered in order after release, nothing dropped |
| address registers | `STATIC_IP` changed: ARP and ping answered for the new IP, not the old; `EFFECTIVE_IP/MASK/GATEWAY` follow; MAC changed (HI staged until LO): the old MAC filtered, replies carry the new MAC |
| leaf enables | ARP disabled: no ARP reply, ping answered; ICMP disabled: no ping reply, ARP answered; absent-leaf bits read 0 |
| mixed burst | ping, ARP, ping, ARP back to back: four replies in order |
| counters | after every phase: `FRAMES + FILTERED + DROPPED` = frames offered, each equal to the bench's expectation, `EGRESS_FRAMES` = frames received; ARP `REPLIES_SENT` and ICMP `ECHO_REPLIES` through their windows; `ev_rx_frame`/`ev_tx_frame` pulse counts; `CNT_CLEAR` and traffic after it |

Results, 10-22-2026: `TEST PASS` with 358 checks (CLKPAIR 1), 340 (CLKPAIR 2), 376 (CLKPAIR 3; the
counts differ with the burst outcome), 358 with `RTLNET_TECH_GENERIC`; `+INJECT_FAILURE` reports
`TEST FAIL`. Compile and elaboration with DHCP, iperf and UDP disabled give only the warning
"Undefined module: rtlnet_udp_socket / rtlnet_dhcp / rtlnet_iperf" (VCP2515) for the unelaborated branches.

Bench sensitivity proven by mutation: comparing only two of the three 16-bit MAC words in F3 fails the
wrong-unicast and per-byte cases (20 failing checks); not counting first-beat drops fails the burst and
the identity; a dequeue gap of 8 fails the 16-clock monitor.

### 5.2 `tb_rtlnet_eth_protocol_regs` (register file)

Drives `rtlnet_eth_protocol_regs` directly in two builds (DHCP present; DHCP absent with the UDP leaf) to
cover what the wrapper bench cannot reach without a DHCP leaf: the effective address follows a lease only
while DHCP is present, enabled and `lease_valid`; the static registers change underneath; a new lease is
used at once and a lost lease returns to the static set; `LEAF_ENABLE` masking; the staged MAC; STATUS bit
mapping; CAPS for both builds; counters minus the `CNT_CLEAR` base, across a 32-bit wrap. Result
10-22-2026: `TEST PASS checks=86`; `+INJECT_FAILURE` fails; with the enable term removed from the DHCP
condition it fails (2 checks).

### 5.3 Driver

`testbench/host_test_rtlnet_eth_protocol.c` runs the driver against a mocked register map (CNT_CLEAR
reads 0, LOCAL_MAC_HI staged): `HOST TEST PASS checks=34`; with the leaf-mask rejection mutated it reports
`HOST TEST FAIL` (3 checks). The driver compiles warning-free with host `gcc` and with
`mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c`.

Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_eth_protocol -Filelist cores/rtlnet_eth_protocol/testbench/tb_rtlnet_eth_protocol.f -Tag p62_50 -PlusArgs CLKPAIR=1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1 -Match rtlnet_eth_protocol
gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver -Icores/rtlnet_eth_protocol/driver cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.c cores/rtlnet_eth_protocol/testbench/host_test_rtlnet_eth_protocol.c -o .sim/host_test_eth_protocol.exe
```

## 6. Synthesis

Vivado 2025.2, out of context, xc7a200tsbg484-1, `DHCP_ENABLE=0, IPERF_ENABLE=0, UDP_ENABLE=0`, other
parameters default (ARP and ICMP in): `rtlnet_synth_check: PASS`, 0 critical warnings.

| Resource | Used |
|---|---|
| Slice LUTs | 2142 (2069 logic, 73 memory: the filter's data delay line as SRLs) |
| Slice registers | 3544 |
| Block RAM tiles | 8 (7 RAMB36 + 2 RAMB18: ingress 4 + 1, egress 2 + 1, ICMP payload 1) |
| DSP | 0 |

Warnings: constant application ports (UDP disabled), unused inputs, and `filemgmt 56-12` duplicate-file
notices because each nested core filelist includes `rtlnet_common.f` (Vivado reads each file once; the
simulation runner removes duplicates). Timing is not analysed by an out-of-context synthesis.

## 7. Driver

`driver/rtlnet_eth_protocol.h`, `driver/rtlnet_eth_protocol.c` (base = protocol sub-map base):
`probe`, `get_caps`, `get_leaves_present`, `get_status`, `set_mac`/`get_mac` (HI then LO),
`set_static_ip`/`get_static_ip`, `set_netmask`/`get_netmask`, `set_gateway`/`get_gateway`,
`get_effective_ip`/`_mask`/`_gateway`, `ip_from_dhcp`, `set_filter_enable`/`get_filter_enable`,
`set_leaf_enables` (rejects a mask naming an absent leaf, writes nothing)/`get_leaf_enables`,
`read_counters`, `clear_counters` — all prefixed `rtlnet_eth_protocol_`.

## 8. Limitations and open items

- The DHCP, iperf and UDP socket leaves are instanced to the 15.4 contract but not yet simulated or
  synthesized inside the wrapper (they do not exist yet); the effective-address path from a lease is proven
  at the register-file level only.
- `scripts/rtlnet_constrain_cdc.tcl` does not exist yet; section 3.7 lists the instance and register names
  it must bound.
- Untagged Ethernet II, frames up to 1518 bytes (`ETH_MAX_FRAME_BYTES`); a longer frame is dropped and
  counted.
- The filter's MAC copy follows a register change a few `axis_clk` clocks later; frames already in the
  filter keep the previous verdict.
- No metastability or post-route timing evidence: simulation is zero-delay and synthesis is out of context.

## 9. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version |
