# rtlnet_eth_protocol — protocol wrapper

| Item | Value |
|---|---|
| Core | `rtlnet_eth_protocol` |
| Document revision | 10-22-2026 |
| Language | SystemVerilog-2012 |
| Contract | `documentation/rtlnet_architecture.md` sections 4, 5, 6.1, 7.4-7.6, 9, 12, 13, 15.3, 15.4 |
| Sources | `hdl/rtlnet_eth_protocol.sv` (top), `hdl/rtlnet_eth_protocol_ingress.sv` (axis_clk ingress), `hdl/rtlnet_eth_protocol_regs.sv` (register file), `hdl/rtlnet_eth_protocol.f` |
| Verification | Active-HDL 11.1: `tb_rtlnet_eth_protocol` (ARP + ICMP, three clock pairs, GENERIC, no-CPU build), `tb_rtlnet_eth_protocol_cpu` (every leaf and the CPU network path, three clock pairs, GENERIC), `tb_rtlnet_eth_protocol_regs`, driver host test; `testbench/rtlnet_tb_leaf_claim_monitor.sv` is the claim-rule checker every leaf bench uses |

The wrapper sits on the MAC client streams. It owns the node address, drops frames that are not for the
node, queues frames between the MAC clock and the protocol clock, presents one frame at a time to every
protocol leaf, and returns their replies to the MAC through a fixed-priority, per-frame arbiter. Leaves
never see the MAC or each other. Every frame no enabled leaf claims is copied to the CPU network path
(`cpu_axis_ethernet_stream`, section 3.6); the CPU's own frames join the arbiter as its lowest-priority source.

```
 axis_clk                                                    | proto_clk
 s_axis -> u_ingress: u_in_slice -> filter F1..F4 -> drop -> u_ingress_fifo -> dequeue (GAP 16 / WAIT / PASS)
             ^ u_filt_cfg_sync (MAC, FILTER_ENABLE)          |      |  fan-out: one frame to every leaf
           counters FRAMES/FILTERED/DROPPED -> u_cnt_*_sync -+->    v
                                                             |   leaf 0 UDP  1 ICMP  2 ARP  3 DHCP  4 iperf
 m_axis <- u_out_slice <- u_egress_fifo <-------------------+--- u_arb_slice <- arbiter (fixed priority, per frame)
 EGRESS_FRAMES counter -> u_cnt_egress_sync -------------->  |   u_regs: address, CTRL, STATUS, counters
 s_axi (s_axi_aclk) -> [u_cpu_axil_dec] -> u_axil_cdc ---->  |   u_axil_slave -> window decode (addr[15:12])
                          | 0x8000 window                   |
 cpu_axis_clk             v                                  |
 m_axis_cpu_eth <- u_cpu_offload (RX trailer) <- u_cpu_classifier (or u_cpu_rx_slice) <- u_cpu_rx_fifo <- copy + claim verdict
 s_axis_cpu_eth -> u_cpu_offload (TX checksum insert) -> u_cpu_tx_guard -> u_cpu_tx_fifo --+--> discard gate -> u_cpu_tx_slice -> arbiter source 5
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
| CPU clock | `cpu_axis_clk` (cpu_clk), `cpu_axis_resetn` (synchronous, active low, from the same assertion as the other resets) |
| `cpu_axis_ethernet_stream` ingress: unclaimed frames to the CPU (cpu_axis_clk) | out `m_axis_cpu_eth_tdata[63:0]`, `m_axis_cpu_eth_tkeep[7:0]`, `m_axis_cpu_eth_tvalid`, `m_axis_cpu_eth_tlast`; in `m_axis_cpu_eth_tready`. Whole frames as received (destination MAC to the last payload or pad byte, no FCS); registered outputs |
| `cpu_axis_ethernet_stream` egress: frames from the CPU (cpu_axis_clk) | in `s_axis_cpu_eth_tdata[63:0]`, `s_axis_cpu_eth_tkeep[7:0]`, `s_axis_cpu_eth_tvalid`, `s_axis_cpu_eth_tlast`; out `s_axis_cpu_eth_tready` (falls only between frames). Complete Ethernet frames of 14..1518 bytes without FCS (the MAC pads to 60 and appends the FCS) |
| status (proto_clk, registered, LEDs only) | `stat_ip_valid` (effective IP is not 0.0.0.0), `stat_dhcp_bound` (effective IP is a DHCP lease), `ev_rx_frame` (one clock per frame delivered to the leaves), `ev_tx_frame` (one clock per frame written to the egress queue) |

The application streams belong to the UDP socket leaf; with `UDP_ENABLE = 0` they are idle
(`m_axis_app_tvalid` 0, `s_axis_app_tready` 1). With `CPU_PATH_ENABLE = 0` the CPU streams are idle
(`m_axis_cpu_eth_tvalid` 0, `s_axis_cpu_eth_tready` 1: every CPU beat is consumed and ignored) and
`cpu_axis_clk` is unused.

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
| `CPU_PATH_ENABLE` | 1 | build the CPU network path (0: no CPU queues, CPU streams idle) |
| `CPU_RX_FIFO_KB` | 16 | `u_cpu_rx_fifo` (8 slots of one 1518-byte frame) |
| `CPU_TX_FIFO_KB` | 8 | `u_cpu_tx_fifo` (4 slots) |
| `CPU_CLASSIFIER_ENABLE` | 1 | build `u_cpu_classifier` (`rtlnet_classifier`) between `u_cpu_rx_fifo` and `m_axis_cpu_eth` and its register window 0x8000; 0: the queue drives `m_axis_cpu_eth` through `u_cpu_rx_slice` and 0x8000 reads 0 |
| `CPU_TCP_OFFLOAD_ENABLE` | 1 | build `u_cpu_offload` (`rtlnet_tcp_offload`): IPv4/TCP/UDP checksum insert on the CPU transmit stream (between `s_axis_cpu_eth` and `u_cpu_tx_guard`) and checksum check plus an 8-byte trailer beat on the CPU receive stream (between the classifier and `m_axis_cpu_eth`); registers at window 0x9000; 0: both streams pass as before and 0x9000 reads 0 |
| `CPU_TCP_OFFLOAD_ACK_COALESCE` | 0 | `u_cpu_offload` builds the ACK coalescer (`ACK_COALESCE`, `cores/rtlnet_tcp_offload` section 12); needs `CTRL.rx_csum` in the core; off after reset |
| `CPU_TCP_OFFLOAD_RX_BATCH` | 0 | `u_cpu_offload` builds the receive batcher (`RX_BATCH`): consecutive CPU receive frames, each with its trailer, in one DMA transfer |
| `CPU_TCP_OFFLOAD_ACK_FLOWS` | 4 | coalescer flow table entries; `CPU_AXIS_CLK_HZ` also sets the core's microsecond tick (`CLK_HZ`) |
| `CPU_AXIS_CLK_HZ` | 100 000 000 | `cpu_axis_clk` frequency, passed to the classifier as `AXIS_CLK_HZ` (policer millisecond tick) |
| `RAM_STYLE` | `"block"` | every buffer (queues and leaf buffers) |

Until `cores/rtlnet_classifier` lands, build and simulate with `CPU_CLASSIFIER_ENABLE = 0` (the enabled branch is
written to the classifier's section 2 port list; its filelist is added to `hdl/rtlnet_eth_protocol.f` when the core
exists). The classifier is drop-all at power-up: with it built, nothing reaches `m_axis_cpu_eth` until firmware
configures it (`cores/rtlnet_classifier/driver`).

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
| 8 | 0x8000 | `u_cpu_classifier` (`rtlnet_classifier`), decoded in `s_axi_aclk` by `u_cpu_axil_dec` ahead of the wrapper's crossing; reads 0 when not built | — |
| 9 | 0x9000 | `u_cpu_offload` (`rtlnet_tcp_offload`, `cores/rtlnet_tcp_offload/documentation`), decoded the same way; reads 0 when not built | — |
| 6, 7, 9-15 | | unused: read 0, writes ignored | |

An absent leaf's window reads 0. Every access is answered OKAY; a write with `wstrb != 4'hF` is ignored
(`rtlnet_axil_slave`).

### 2.2 Wrapper registers (window 0)

Defined in `driver/rtlnet_eth_protocol.h`, mirrored by localparams in `hdl/rtlnet_eth_protocol_regs.sv`.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | `0x50524F54` | "PROT" |
| 0x004 | `VERSION` | RO | `0x10222026` | register-map date code |
| 0x008 | `CAPS` | RO | build | `[4:0]` LEAF_PRESENT (bit i = leaf index i built), bit 5 `CPU_PATH_PRESENT`, `[15:8]` `INGRESS_FIFO_KB`, `[23:16]` `EGRESS_FIFO_KB`, `[31:24]` `NUM_SOCKETS` (0 without the UDP leaf) |
| 0x00C | `CTRL` | RW | `0x00001F03` masked | bit 0 `FILTER_ENABLE` (1; 0 = promiscuous), bit 1 `CPU_PATH_ENABLE` (1; stored masked by `CPU_PATH_PRESENT`), `[12:8]` `LEAF_ENABLE` (bit 8+i = leaf index i; reset = present leaves; stored masked by LEAF_PRESENT), bit 16 `CNT_CLEAR` (self-clearing pulse, reads 0). Write CTRL read-modify-write: a write without bit 1 turns the CPU path off |
| 0x010 | `STATUS` | RO | | bit 0 `IP_FROM_DHCP`, bit 1 `IP_VALID`, bit 2 `LEASE_VALID`, `[12:8]` `LEAF_BUSY`, bit 16 `INGRESS_PENDING` (a frame waits in the ingress queue), bit 17 `EGRESS_FULL`, bit 18 `DELIVERING` (a frame is being delivered to the leaves), bit 19 `ARBITER_ACTIVE` (a leaf or the CPU holds the grant), bit 20 `CPU_RX_FULL` (the CPU RX queue has no free slot), bit 21 `CPU_RX_PENDING` (a CPU copy waits for its claim verdict), bit 22 `CPU_TX_PENDING` (a CPU frame waits at the CPU TX queue output) |
| 0x014 | `LOCAL_MAC_HI` | RW | `0x00000249` | `[15:0]` MAC octets 0-1. A write is staged; reads return the MAC in use |
| 0x018 | `LOCAL_MAC_LO` | RW | `0x4B524E01` | MAC octets 2-5. The write commits staged HI and LO as one 48-bit change |
| 0x01C | `STATIC_IP` | RW | `0xC0A901DC` | 192.169.1.220 |
| 0x020 | `NETMASK` | RW | `0xFFFFFF00` | 255.255.255.0 |
| 0x024 | `GATEWAY` | RW | `0xC0A90101` | 192.169.1.1 |
| 0x028 | `EFFECTIVE_IP` | RO | `STATIC_IP` | the address the leaves use |
| 0x02C | `EFFECTIVE_MASK` | RO | `NETMASK` | the mask the UDP socket leaf uses |
| 0x030 | `EFFECTIVE_GATEWAY` | RO | `GATEWAY` | the gateway the UDP socket leaf uses |
| 0x034 | `CPU_CAPS` | RO | build | `[7:0]` `CPU_RX_FIFO_KB`, `[15:8]` `CPU_TX_FIFO_KB`, bit 16 `CPU_CLASSIFIER_PRESENT`, bit 17 `CPU_TCP_OFFLOAD_TX_PRESENT` (checksum insert), bit 18 `CPU_TCP_OFFLOAD_RX_PRESENT` (checksum check and trailer); 0 without the CPU path. Firmware reads these bits first and then confirms the block's own ID and CAPS at its window (the offload core's `CAPS.TX_PRESENT` / `CAPS.RX_PRESENT` must equal bits 17 / 18, else the block is treated as absent) |
| 0x040 | `INGRESS_FRAMES` | RO | 0 | frames that passed the filter and were stored whole |
| 0x044 | `INGRESS_FILTERED` | RO | 0 | frames discarded by the destination filter |
| 0x048 | `INGRESS_DROPPED` | RO | 0 | frames that passed the filter but found no free slot, or were longer than one slot |
| 0x04C | `EGRESS_FRAMES` | RO | 0 | frames accepted by the MAC (`m_axis` last-beat handshakes) |
| 0x050 | `DELIVERED_FRAMES` | RO | 0 | frames dequeued to the leaves (proto_clk, last beat) |
| 0x054 | `CPU_RX_FRAMES` | RO | 0 | unclaimed frames committed to the CPU RX queue (proto_clk, at the verdict) |
| 0x058 | `CPU_RX_CLAIMED` | RO | 0 | copies dropped because an enabled leaf claimed the frame |
| 0x05C | `CPU_RX_DROPPED` | RO | 0 | unclaimed frames lost because the CPU RX queue had no free slot at their first beat |
| 0x060 | `CPU_TX_FRAMES` | RO | 0 | CPU frames the arbiter handed to the egress queue (proto_clk) |
| 0x064 | `CPU_TX_DISCARDED` | RO | 0 | CPU frames read and discarded while `CPU_PATH_ENABLE` was 0 (proto_clk) |
| 0x068 | `CPU_TX_REJECTED` | RO | 0 | CPU frames rejected by the guard: under 14 or over 1518 bytes, or illegal `tkeep` (cpu_axis_clk, crossed by `u_cnt_cpu_reject_sync`) |

Effective address: while the DHCP leaf is built, enabled (`LEAF_ENABLE` bit 3) and its `lease_valid` is
high, `EFFECTIVE_IP/MASK/GATEWAY` are its `lease_ip`, `lease_mask`, `lease_router` and
`STATUS.IP_FROM_DHCP` is 1; otherwise they are `STATIC_IP`, `NETMASK`, `GATEWAY`.

Counter identities (once traffic has stopped and the counters have crossed, a few clocks):

- ingress: frames offered at `s_axis` = `INGRESS_FILTERED + INGRESS_FRAMES + INGRESS_DROPPED`, and
  `DELIVERED_FRAMES` = `INGRESS_FRAMES` (every stored frame is dequeued);
- CPU side, for frames dequeued while `CPU_PATH_ENABLE` was set: `DELIVERED_FRAMES` = `CPU_RX_CLAIMED +
  CPU_RX_FRAMES + CPU_RX_DROPPED` (a claimed frame is counted as claimed even when the CPU queue was full; frames
  dequeued with the path off are counted only in `DELIVERED_FRAMES`). With the classifier built, `CPU_RX_FRAMES`
  counts frames entering the classifier; its own counters say how many it passed.

`CNT_CLEAR` restarts every counter of the window together (each register reads its free-running source minus a
base taken at the clear).

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
| `g_cpu.u_cpu_rx_fifo` | proto_clk / cpu_axis_clk | `CPU_RX_FIFO_KB` 16 | 8 | 4 RAMB36 + 1 RAMB18 |
| `g_cpu.u_cpu_tx_fifo` | cpu_axis_clk / proto_clk | `CPU_TX_FIFO_KB` 8 | 4 | 2 RAMB36 + 1 RAMB18 |

All are `rtlnet_packet_fifo` with `DROP_WHEN_FULL = 0`. The egress queue never drops: a full queue
back-pressures the arbiter slice, the arbiter and the granted source. `u_out_slice` registers the MAC side.
The CPU RX queue is written only from a frame's first beat on when it has a free slot (section 3.6), so it never
stalls the leaves; the CPU TX queue back-pressures the CPU between frames.

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
`m_axis_tlast`, data and keep to 0, `busy` and `claim` to 0, its read data to 0 and its `s_axis_tready` to 1
(and, for DHCP, the lease outputs to 0; for UDP, the application ports idle).

Every leaf's `claim` (architecture 7.5) lands in `leaf_claim[index]`; the CPU path masks it with `LEAF_ENABLE`.
What each leaf claims:

| Leaf | Claims (one registered pulse per frame) | When |
|---|---|---|
| ARP | a request for `local_ip` it answers (taken while enabled and idle, every RFC 826 check passed) | the clock after the last beat (one clock before `busy` rises) |
| ICMP | an echo request it answers (every check passed in `S_CHECK`, including size and checksum) | two clocks after the last beat, `busy` high |
| DHCP | a BOOTP reply for the current xid and `chaddr` that the client machine accepts in its state: OFFER with option 54 while SELECTING, ACK or NAK while REQUESTING or RENEWING (the frames `OFFERS_RX`, `ACKS_RX`, `NAKS_RX` count) | the clock `busy` falls |
| iperf | a datagram to `UDP_PORT` that the classify step accounts: data or FIN of the open flow, the first datagram of a new flow, a repeated FIN (report resent), an accepted `-R` request | three clocks after the last beat, `busy` high |
| UDP socket | a datagram whose header passes the beat-4 rules and whose destination port matches an enabled socket (delivered, dropped for a full FIFO, or dropped by a late length/checksum verdict) | the clock after the last beat, `busy` high |

Every leaf gates `claim` with `enable` in the clock it is issued, so a disabled leaf never claims.

### 3.5 Arbiter (proto_clk)

Six sources: the leaves at their indices 0..4 and the CPU (`u_cpu_tx_slice`) as source 5. One-hot `grant`
(bit 0 idle, bit i+1 source i). At idle the lowest-index source with `tvalid` high is granted (UDP, ICMP, ARP,
DHCP, iperf, CPU); the grant holds until that source's last beat is taken by `u_arb_slice` (no preemption), then
returns to idle for one clock, so a waiting reply is picked between two frames of a streaming source. Only the
granted source sees `tready`; the others hold their output. The decision reads only registered `tvalid` flags
(every source is a register slice).

### 3.6 CPU network path (architecture 7.4)

**Copy.** In the clocks the dequeue controller presents a frame to the leaves it also writes it into
`u_cpu_rx_fifo` (`CPU_RX_FIFO_KB`, `proto_clk` to `cpu_axis_clk`, `DROP_WHEN_FULL = 0`). At the frame's first beat
`CTRL.CPU_PATH_ENABLE` and the queue's `s_ready` are sampled: path on and a free slot, the copy is written; path
on and no slot, nothing of the frame is written (counted at the verdict if the frame is unclaimed); path off,
the frame is not tracked. A started copy is never refused (the queue's `s_ready` stays high inside a frame;
a simulation `$error` reports otherwise), so the leaves are never stalled.

**Claim verdict.** The copy's last beat is held in `cp_hold_data`/`cp_hold_keep`. `leaf_claim` pulses (masked
by `LEAF_ENABLE`) accumulate in `cp_claimed` from the frame's first beat. The verdict is taken in the clock the
dequeue controller admits the next frame (`DQ_WAIT` with no leaf busy, `dq_admit`), so the 16-clock gap has
elapsed and every leaf's `busy` has fallen; a claim pulse in that same clock counts (the DHCP leaf claims in the
clock its `busy` falls). The held beat is written in the verdict clock with `s_bad` = claimed: a claimed copy is
dropped inside the queue, an unclaimed one is committed. The next frame's first beat comes one clock later at
the earliest, so the two writes never meet. Per-frame latency added to the CPU copy: the gap plus the slowest
leaf's busy time; the leaves see no added latency.

| Verdict (path on at the first beat) | Queue write | Counter |
|---|---|---|
| a leaf claimed | held last beat with `s_bad` (copy dropped) | `CPU_RX_CLAIMED` |
| unclaimed, copy written | held last beat, good | `CPU_RX_FRAMES` |
| unclaimed, no slot at the first beat | nothing | `CPU_RX_DROPPED` |

**Output.** `u_cpu_rx_fifo` read side (`cpu_axis_clk`) -> `u_cpu_classifier` (`rtlnet_classifier`, `AXIS_CLK_HZ =
CPU_AXIS_CLK_HZ`) -> `m_axis_cpu_eth`; with `CPU_CLASSIFIER_ENABLE = 0`, `u_cpu_rx_slice` (`rtlnet_axis_reg_slice`)
instead. The classifier's registers are reached at 0x8000-0x8FFF: `u_cpu_axil_dec` (`rtlnet_axil_decoder`, `N` 2,
`s_axi_aclk`) sends that window to the classifier's own AXI4-Lite slave (it crosses internally) and the rest of the
64 KiB sub-map (slave 1, size 0 = 64 KiB in 16 address bits; the lower index wins) to `u_axil_cdc`. Without the
classifier there is no decoder and the window reads 0 like any unused window.

**Checksum offload.** `u_cpu_offload` (`rtlnet_tcp_offload`, `cpu_axis_clk`) sits on the two CPU streams. Receive:
classifier (or `u_cpu_rx_slice`) -> `s_axis_rx` ... `m_axis_rx` -> `m_axis_cpu_eth`; with `CTRL.rx_csum` set every frame
leaves padded to 8 bytes with one trailer beat (length, folded L4 sum, flags, L4 offset, marker `0xA5`); the CPU DMA buffer
holds `roundup8(1522) + 8` bytes. Transmit: `s_axis_cpu_eth` -> `s_axis_tx` ... `m_axis_tx` -> `u_cpu_tx_guard` and
`u_cpu_tx_fifo` (store and forward in the offload's own 8 KB buffer; the checksum fields of IPv4/TCP/UDP frames are
inserted when `CTRL.tx_ip_csum` / `tx_l4_csum` are set, otherwise the frame is bit-exact). Power-up CTRL is 0: both
streams are pass-through. Its registers are reached at 0x9000-0x9FFF through `u_cpu_axil_dec` (`N` 3: classifier at
0x8000, offload at 0x9000, the rest of the sub-map to `u_axil_cdc`); a window whose block is not built is answered by a
null `rtlnet_axil_slave` (reads 0, OKAY, writes ignored). The offload adds buffering to a stalled CPU stream
(input slice, the 17-beat delay line, output slice: about 21 beats), so a stalled CPU holds one more small frame in the
path before `CPU_RX_DROPPED` counts. `CPU_TX_FRAMES` and the guard see the offload's output.

**Transmit.** `s_axis_cpu_eth` -> `u_cpu_tx_guard` (`rtlnet_frame_guard`, 14..1518 bytes, legal `tkeep`) ->
`u_cpu_tx_fifo` (`CPU_TX_FIFO_KB`, `cpu_axis_clk` to `proto_clk`, `DROP_WHEN_FULL = 0`, so `s_axis_cpu_eth_tready`
falls only between frames and the CPU's DMA is simply held) -> discard gate -> `u_cpu_tx_slice` -> arbiter source 5.
A rejected frame is dropped whole inside the queue and counted in `cpu_axis_clk` (`CPU_TX_REJECTED`, crossed by
`u_cnt_cpu_reject_sync`). The discard gate samples `CTRL.CPU_PATH_ENABLE` at each frame's first beat on the read
side: off, the whole frame is read and dropped (`CPU_TX_DISCARDED`); frames already queued when the path is
turned off are discarded too. `CPU_TX_FRAMES` counts frames the arbiter takes. The CPU source never blocks a
leaf for longer than one frame (no preemption) and loses every decision against a waiting leaf frame.

### 3.7 Register path

`u_axil_cdc` (`rtlnet_axil_cdc`, `ADDR_W` 16) carries each AXI4-Lite transaction from `s_axi_aclk` to
`proto_clk`; `u_axil_slave` (`rtlnet_axil_slave`, `ADDR_W` 16) turns it into one-clock strobes. Writes and
reads are steered by `addr[15:12]`; each leaf gets `reg_*_addr[11:0]`. The read window is registered at
`reg_rd_en` and selects the window's registered read data in the next clock (the clock in which the slave
samples it). Every register file is a single-clock block in `proto_clk`.

### 3.8 Clocks, resets, crossings

| Crossing | Instance | Primitive | Constraint hook |
|---|---|---|---|
| frames axis_clk -> proto_clk | `u_ingress_fifo` | `rtlnet_packet_fifo` (Gray frame counters) | `*u_ingress_fifo`: `s_gray -> s_gray_m1`, `m_gray -> m_gray_s1` |
| frames proto_clk -> axis_clk | `u_egress_fifo` | `rtlnet_packet_fifo` | `*u_egress_fifo`, same |
| filter MAC + FILTER_ENABLE | `u_ingress/u_filt_cfg_sync` | `rtlnet_sync` 2 stages + two-equal-sample filter | first-stage false path to `g_bit[*].sync_ff_reg[0]` |
| four counters axis_clk -> proto_clk | `u_cnt_frames_sync`, `u_cnt_filtered_sync`, `u_cnt_dropped_sync`, `u_cnt_egress_sync` | `rtlnet_gray_sync` | `gray_src_reg -> gray_dst_ff_reg[0]`, max delay + bus skew of one axis_clk period |
| registers s_axi_aclk -> proto_clk | `u_axil_cdc` | `rtlnet_axil_cdc` | toggles via `rtlnet_sync`; `req_*_hold`/`rsp_*_hold` bundles max delay of the destination period |
| CPU copies proto_clk -> cpu_axis_clk | `g_cpu.u_cpu_rx_fifo` | `rtlnet_packet_fifo` | `*u_cpu_rx_fifo`, Gray pointers as above |
| CPU frames cpu_axis_clk -> proto_clk | `g_cpu.u_cpu_tx_fifo` | `rtlnet_packet_fifo` | `*u_cpu_tx_fifo`, Gray pointers as above |
| `CPU_TX_REJECTED` cpu_axis_clk -> proto_clk | `g_cpu.u_cnt_cpu_reject_sync` | `rtlnet_gray_sync` | `gray_src_reg -> gray_dst_ff_reg[0]`, one cpu_axis_clk period |
| classifier registers s_axi_aclk -> cpu_axis_clk | inside `g_cpu.g_classifier.u_cpu_classifier` | its own `rtlnet_axil_cdc` | per the classifier guide |
| offload registers s_axi_aclk -> cpu_axis_clk | inside `g_cpu.g_offload.u_cpu_offload` (`u_regs/u_axil_cdc`) | its own `rtlnet_axil_cdc` | per the offload guide; its TX buffer `u_tx/u_tx_fifo` is a single-clock `rtlnet_packet_fifo` (class `fifo`) |

No other signal crosses: leaves, arbiter, dequeue controller, the copy and verdict logic and the register file
are all `proto_clk`; the UDP socket leaf owns its `app_clk` crossings. `cpu_path_enable` is a `proto_clk`
register used only in `proto_clk` (the transmit discard gate is on the queue's read side). All five resets must
come from one assertion (`rtlnet_reset_sync` per clock in the board top): every packet FIFO and
`rtlnet_axil_cdc` require their two sides to reset together. Per wrapper with the CPU path the CDC script finds
two more packet FIFOs and one more Gray counter than before (with the classifier: plus its crossings).

## 4. Adding a leaf (integration guide)

A leaf is any `proto_clk` module with the exact contract ports of architecture 15.4 (`clk`, `resetn`,
`enable`, `s_axis_*`, `m_axis_*`, `local_mac`, `local_ip`, `busy`, `claim`, the 12-bit register port, then its
own ports). To add one:

1. Build the leaf to the contract: hold `s_axis_tready` at 1; output through one `rtlnet_axis_reg_slice`
   so a started frame has no gaps and holds while not granted; raise `busy` (a flop) within 12 clocks of
   the last beat of any frame it acts on and hold it until it can take a new frame; ignore a frame that
   starts while it is not idle; register its read data one clock after `reg_rd_en`; ignore frames and
   send nothing while `enable` is low; pulse `claim` (a flop, one clock) for every frame it consumes, after
   the frame's last beat and no later than the clock `busy` falls (within 12 clocks if it never raises
   `busy`), never while disabled; standard `ID`/`VERSION`/`CAPS` header.
2. Choose a leaf index (the arbiter priority; 0 is highest) and a register window (`addr[15:12]`). Raise
   `N_LEAVES` and the width of `LEAF_PRESENT`/`LEAF_ENABLE`/`LEAF_BUSY` if the index is 5 or above (the CTRL
   and STATUS fields have room up to bit 15 and 7 more windows are free); add `LEAF_<NAME>` and
   `WIN_<NAME>` localparams.
3. Add an `<NAME>_ENABLE` parameter and its bit in `LEAF_PRESENT`.
4. Add the window decode: `leaf_reg_wr_en[LEAF_<NAME>]`, `leaf_reg_rd_en[LEAF_<NAME>]` and a case of the
   read-data mux.
5. Instance the leaf in a `g_<name>` generate branch onto the packed vectors at its index
   (`leaf_tdata[i*64 +: 64]`, `leaf_tkeep[i*8 +: 8]`, `leaf_tvalid[i]`, `leaf_tlast[i]`, `leaf_tready[i]`,
   `leaf_s_tready[i]`, `leaf_busy[i]`, `leaf_claim[i]`, `leaf_rd_data[i*32 +: 32]`) with `proto_clk`/
   `proto_resetn`, the fan-out stream, `local_mac`/`local_ip` and `leaf_enable[i]`. In the `g_no_<name>` branch
   tie its outputs idle (data/keep/valid/last 0, `s_tready` 1, `busy` 0, `claim` 0, read data 0) and any outputs
   it drives. The arbiter source index of the CPU (`SRC_CPU = N_LEAVES`) moves up with `N_LEAVES`.
6. Add the leaf's filelist to `hdl/rtlnet_eth_protocol.f` (a `-f` line) and its window to
   `driver/rtlnet_eth_protocol.h` (`RTLNET_PROTO_WIN_*`, `RTLNET_PROTO_LEAF_*`).
7. If the leaf has its own clock domain, it owns the crossings inside itself, with stable instance names
   the constraint script can find (the UDP socket leaf's `app_clk` FIFOs are the model).
8. Verify: a unit bench with `rtlnet_tb_leaf_busy_monitor` and `rtlnet_tb_leaf_claim_monitor`
   (`testbench/rtlnet_tb_leaf_claim_monitor.sv` of this core) and a per-frame claim expectation; in
   `tb_rtlnet_eth_protocol_cpu` add both monitors on the new index, the leaf's traffic (claimed, not copied)
   and its expected claim count; check `CAPS`, the window's `ID`, and the counter identities.

## 5. Verification

### 5.1 `tb_rtlnet_eth_protocol` (wrapper with ARP and ICMP; DHCP, iperf, UDP disabled; CPU path built)

Driven at the MAC client streams with `rtlnet_tb_axis_src`/`rtlnet_tb_axis_sink` and through AXI4-Lite
from `s_axi_aclk` 100 MHz with `rtlnet_tb_axil_master`. Clock pair from `+CLKPAIR`: 1 axis 62.5 MHz /
proto 50 MHz (16.000 / 20.003 ns), 2 axis 156.25 MHz / proto 50 MHz (6.400 / 20.003 ns), 3 axis 50 MHz /
proto 62.5 MHz (20.000 / 16.007 ns); start offsets differ. Expected replies are bench-built
(`testbench/rtlnet_tb_eth_frames_pkg.sv`) and compared byte by byte.

Always-on monitors: `rtlnet_tb_leaf_busy_monitor` and `rtlnet_tb_leaf_claim_monitor` on the ICMP and ARP
leaves inside the wrapper; at least 16 idle `proto_clk` clocks before every frame toward the leaves; no frame
starts while a leaf is busy; `s_axis_tready` never low after reset; stream rules at `m_axis` and
`m_axis_cpu_eth` (sinks). The CPU path is built (`CPU_CLASSIFIER_ENABLE` 0), `cpu_axis_clk` 9.997 ns, the CPU sink
always ready, the CPU source idle; `+define+TB_NO_CPU_PATH` builds `CPU_PATH_ENABLE = 0`.

| Phase | What it proves |
|---|---|
| register map | wrapper ID, VERSION, CAPS (`0x00081026`; `0x00081006` without the CPU path), CPU_CAPS (`0x00000810` / 0), the 0x8000 window reads 0, CTRL, STATUS, address registers, effective address, counters at reset; ARP and ICMP IDs/CAPS through windows 1 and 2; windows 3, 4, 5, 6, 15 read 0; RO writes and a partial (`wstrb` 0x3) write ignored; LED outputs; application ports idle |
| ARP and ping | ARP request answered byte-exact; pings with payload 0, 64, 1472 and to the broadcast MAC answered byte-exact |
| filter | wrong unicast, two multicasts, one differing bit (bits 0 and 7) in each of the six MAC bytes: filtered and counted; a non-IP frame to the local MAC stored, not answered; 40 wrong-MAC frames back to back with 2 pings inside: only the pings answered; promiscuous (`FILTER_ENABLE` 0): wrong unicast and multicast pings answered; filter restored |
| over-slot | a 2100-byte frame to the local MAC: dropped and counted, the next ping answered |
| ingress full | 40 pings of 1400 bytes at line rate: replies + `INGRESS_DROPPED` = 40, at least one drop, replies in order and byte-exact (62.5/50: 23 + 17; 156.25/50: 14 + 26; 50/62.5: 32 + 8) |
| egress back-pressure | 10 pings with 30 % random ready, then 6 pings and an ARP request with ready held at 0 (`STATUS.EGRESS_FULL` seen, nothing completes): all answered in order after release, nothing dropped |
| address registers | `STATIC_IP` changed: ARP and ping answered for the new IP, not the old; `EFFECTIVE_IP/MASK/GATEWAY` follow; MAC changed (HI staged until LO): the old MAC filtered, replies carry the new MAC |
| leaf enables | ARP disabled: no ARP reply, ping answered; ICMP disabled: no ping reply, ARP answered; absent-leaf bits read 0 |
| mixed burst | ping, ARP, ping, ARP back to back: four replies in order |
| counters | after every phase: `FRAMES + FILTERED + DROPPED` = frames offered, each equal to the bench's expectation, `EGRESS_FRAMES` = frames received; ARP `REPLIES_SENT` and ICMP `ECHO_REPLIES` through their windows; `ev_rx_frame`/`ev_tx_frame` pulse counts; `CNT_CLEAR` and traffic after it |
| CPU path | claims = ARP replies and ICMP replies; `DELIVERED_FRAMES` = frames toward the leaves; `CPU_RX_FRAMES` = frames received at `m_axis_cpu_eth` (non-zero with the path, zero without); after `CNT_CLEAR` `DELIVERED = CPU_RX_CLAIMED + CPU_RX_FRAMES + CPU_RX_DROPPED` and the ping is claimed; without the path the CPU streams stay idle/ready and the CPU counters 0 |

Results, 10-22-2026: `TEST PASS` with 376 checks (CLKPAIR 1), 358 (CLKPAIR 2), 394 (CLKPAIR 3; the
counts differ with the burst outcome), 376 with `RTLNET_TECH_GENERIC`, 376 with `TB_NO_CPU_PATH`;
`+INJECT_FAILURE` reports `TEST FAIL`. Compilation warns only "Undefined module" (VCP2515) for the vendor
models resolved from the compiled libraries at elaboration (`xpm_memory_sdpram`, `SRLC32E`) and for
`rtlnet_classifier` in the unelaborated `g_classifier` branch.

Bench sensitivity proven by mutation: comparing only two of the three 16-bit MAC words in F3 fails the
wrong-unicast and per-byte cases (20 failing checks); not counting first-beat drops fails the burst and
the identity; a dequeue gap of 8 fails the 16-clock monitor.

### 5.2 `tb_rtlnet_eth_protocol_cpu` (every leaf and the CPU network path)

The wrapper with ARP, ICMP, DHCP, iperf and the UDP socket leaf and the CPU path (`CPU_CLASSIFIER_ENABLE` 0), driven
at the MAC streams (`axis_clk`, `+CLKPAIR` as 5.1), the CPU streams (`cpu_axis_clk` 9.997 ns, unrelated to
`proto_clk`), the socket application streams (`app_clk = proto_clk`) and AXI4-Lite. Every frame copied to the CPU is
compared byte for byte with the frame offered at `s_axis`; every CPU frame at `m_axis` with the frame the CPU sent.
Monitors: busy and claim monitors on all five leaves inside the wrapper, sink stream rules on the three outputs.

| Phase | What it proves |
|---|---|
| register map | CAPS `0x0408103F`, CPU_CAPS `0x00000810`, CTRL `0x00001F03`, STATUS, CPU counters 0, 0x8000 reads 0 |
| claimed, not copied | ARP request for us and three pings answered byte-exact; nothing at `m_axis_cpu_eth` |
| to the CPU | ARP reply to us, TCP SYN to our IP, UDP to an unknown port (60 and 1514 bytes), ARP request for another IP (broadcast), ICMP echo reply and timestamp request to us, IPv6 to our MAC: each byte-exact at `m_axis_cpu_eth`, nothing at `m_axis` |
| every leaf | UDP to an enabled socket port: delivered to the application, claimed, not copied; UDP to the iperf port (sequence 1): claimed, not copied; UDP to another port: copied; DHCP START, DISCOVER out, an OFFER with a wrong xid copied, the OFFER for `XID` claimed (REQUEST out) and not copied, STOP |
| CPU stalled | CPU sink ready 0, 12 unclaimed frames: `STATUS.CPU_RX_FULL`, `CPU_RX_DROPPED` +4, a ping answered meanwhile; after the release the 8 kept frames arrive in order, byte-exact, nothing else |
| CPU transmit | 14, 15, 60, 61, 1000, 1517, 1518-byte frames byte-exact, `CPU_TX_FRAMES` +7; 20 CPU frames interleaved with 10 pings under 30 % egress ready: every frame, each stream in order, byte-exact; priority with egress held (6 CPU frames, then a ping and a socket datagram): both leave before the sixth CPU frame; 10- and 1600-byte CPU frames rejected (`CPU_TX_REJECTED` +2), the next frame sent |
| path disabled | `CTRL.CPU_PATH_ENABLE` 0: unknown UDP not copied, ARP answered, three CPU frames discarded (`CPU_TX_DISCARDED` +3, `CPU_TX_FRAMES` and `CPU_RX_FRAMES` unchanged, `DELIVERED` +2); re-enabled: copy and send again |
| identities (after every phase) | ingress identity with no drops; `DELIVERED_FRAMES = INGRESS_FRAMES`; `DELIVERED` (minus frames dequeued with the path off) `= CPU_RX_CLAIMED + CPU_RX_FRAMES + CPU_RX_DROPPED`; `CPU_RX_CLAIMED` = the claim pulses seen (minus those with the path off); `CPU_RX_FRAMES` = frames received by the CPU; `EGRESS_FRAMES` = frames received at `m_axis`; per-leaf claim counts equal the bench's expectations (udp 1, icmp 15, arp 2, dhcp 1, iperf 1) |

Results, 10-22-2026: `TEST PASS checks=288` at CLKPAIR 1, 2 and 3 and with `RTLNET_TECH_GENERIC`;
`+INJECT_FAILURE` reports `TEST FAIL`.

Bench sensitivity proven by mutation (RTL perturbed, run, restored):

| Mutation | Result |
|---|---|
| claimed copies committed (`s_bad` of the held beat tied 0) | TEST FAIL, 12 checks (first "ARP request for us: not copied to the CPU") |
| claim in the verdict clock ignored (only the accumulated `cp_claimed`) | TEST FAIL, 5 checks (the DHCP OFFER, claimed in the clock its busy falls, leaks to the CPU) |
| arbiter picks the highest index (CPU first) | TEST FAIL (priority: the socket datagram after the last CPU frame) |
| copy started without checking the CPU queue's free slot | stops on the wrapper's `$error` "CPU RX queue refused a beat of a started copy" |
| CPU frames never discarded while the path is off | TEST FAIL, 3 checks |

### 5.3 `tb_rtlnet_eth_protocol_regs` (register file)

Drives `rtlnet_eth_protocol_regs` directly in two builds (DHCP present; DHCP absent with the UDP leaf) to
cover what the wrapper bench cannot reach without a DHCP leaf: the effective address follows a lease only
while DHCP is present, enabled and `lease_valid`; the static registers change underneath; a new lease is
used at once and a lost lease returns to the static set; `LEAF_ENABLE` masking; the staged MAC; STATUS bit
mapping; CAPS for both builds; counters minus the `CNT_CLEAR` base, across a 32-bit wrap. A third instance
with the CPU path present covers CAPS bit 5, CPU_CAPS, `CTRL.CPU_PATH_ENABLE` (reset 1, cleared, set; masked to 0
where absent) and its output, STATUS bits 20-22 and the seven DELIVERED/CPU counters minus the clear base. Result
10-22-2026: `TEST PASS checks=122`; `+INJECT_FAILURE` fails; with the enable term removed from the DHCP
condition it fails (2 checks).

### 5.4 Leaf claim monitor

`testbench/rtlnet_tb_leaf_claim_monitor.sv` checks the claim rule on any leaf: never X, a one-clock pulse, at most
one per ended frame, never in the clock of a last beat, not after the clock `busy` falls (if `busy` was high since
the last beat), within 12 clocks of the last beat when `busy` never rose, never while `enable` is low; `claims`
counts the pulses for the bench's per-frame expectations. Used by the five leaf benches and both wrapper benches.

### 5.5 Driver

`testbench/host_test_rtlnet_eth_protocol.c` runs the driver against a mocked register map (CNT_CLEAR
reads 0, LOCAL_MAC_HI staged): `HOST TEST PASS checks=50` (CPU path: presence, enable rejected when absent and
writing nothing, read-modify-write keeping the filter, CPU and leaf bits, queue sizes, the seven counters); with
the leaf-mask rejection mutated it reports `HOST TEST FAIL` (3 checks); with the absent-path rejection removed
(2 checks). The driver compiles warning-free with host `gcc` and with
`mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c`.

Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_eth_protocol -Filelist cores/rtlnet_eth_protocol/testbench/tb_rtlnet_eth_protocol.f -Tag p62_50 -PlusArgs CLKPAIR=1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_eth_protocol_cpu -Filelist cores/rtlnet_eth_protocol/testbench/tb_rtlnet_eth_protocol_cpu.f -Tag p62_50 -PlusArgs CLKPAIR=1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1 -Match rtlnet_eth_protocol
gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver -Icores/rtlnet_eth_protocol/driver cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.c cores/rtlnet_eth_protocol/testbench/host_test_rtlnet_eth_protocol.c -o .sim/host_test_eth_protocol.exe
```

## 6. Synthesis

Vivado 2025.2, out of context, xc7a200tsbg484-1, `scripts/rtlnet_synth_check.tcl` through `scripts/rtlnet_vivado.ps1`,
10-22-2026. Every leaf built (ARP, ICMP, DHCP, iperf, UDP socket), other parameters default, `CPU_CLASSIFIER_ENABLE=0`
(the classifier core is not in the tree yet): `rtlnet_synth_check: PASS`, 0 critical warnings, with the CPU path and
without it (`CPU_PATH_ENABLE=0`) for the cost of the path.

| Resource | CPU path built | `CPU_PATH_ENABLE=0` | CPU path cost |
|---|---:|---:|---:|
| Slice LUTs | 9432 (9359 logic, 73 memory) | 8983 (8910 logic, 73 memory) | +449 |
| Slice registers | 12737 | 11727 | +1010 |
| Block RAM tiles | 24.5 (21 RAMB36 + 7 RAMB18) | 17.5 (15 RAMB36 + 5 RAMB18) | +7 (CPU RX 4 + 1, CPU TX 2 + 1) |
| DSP | 2 | 2 | 0 |

Warnings: unconnected XPM ports, removed unused registers, and `filemgmt 56-12` duplicate-file notices because each
nested core filelist includes `rtlnet_common.f` (Vivado reads each file once; the simulation runner removes
duplicates). The earlier ARP+ICMP-only build (2142 LUTs, 3544 registers, 8 BRAM tiles) is superseded by this one.
Timing is not analysed by an out-of-context synthesis.

## 7. Driver

`driver/rtlnet_eth_protocol.h`, `driver/rtlnet_eth_protocol.c` (base = protocol sub-map base):
`probe`, `get_caps`, `get_leaves_present`, `get_status`, `set_mac`/`get_mac` (HI then LO),
`set_static_ip`/`get_static_ip`, `set_netmask`/`get_netmask`, `set_gateway`/`get_gateway`,
`get_effective_ip`/`_mask`/`_gateway`, `ip_from_dhcp`, `set_filter_enable`/`get_filter_enable`,
`set_leaf_enables` (rejects a mask naming an absent leaf, writes nothing)/`get_leaf_enables`,
`read_counters`, `clear_counters` (every counter of the window), `cpu_path_present`, `set_cpu_path_enable`
(rejects an enable when the path is not built, writes nothing)/`get_cpu_path_enable`,
`get_cpu_rx_fifo_kb`/`get_cpu_tx_fifo_kb`, `read_cpu_counters` (`rtlnet_eth_protocol_cpu_counters_t`: delivered,
CPU RX frames/claimed/dropped, CPU TX frames/discarded/rejected) — all prefixed `rtlnet_eth_protocol_`. Every
CTRL change is a read-modify-write, so the filter, CPU path and leaf-enable bits are kept by the others. The
classifier window is `RTLNET_PROTO_WIN_CLASSIFIER` (0x8000); its registers belong to the classifier driver.

## 8. Limitations and open items

- The effective-address path from a DHCP lease is proven at the register-file level and by the board bench; the
  wrapper benches stop the DHCP client before an ACK.
- `u_cpu_classifier` is instanced to the classifier's section 2 port list but not compiled here: the core is
  built in parallel. Until its filelist is added to `hdl/rtlnet_eth_protocol.f`, build with
  `CPU_CLASSIFIER_ENABLE = 0` (the default 1 does not elaborate without it).
- With `CPU_PATH_ENABLE = 1` the board top must drive `cpu_axis_clk`/`cpu_axis_resetn` and connect both CPU
  streams; left open, the CPU queues' read/write sides never reset and simulation stops on the packet FIFO's
  X check.
- A frame that a leaf accepts while enabled and that loses its `enable` before the claim pulse is answered by
  the leaf and also copied to the CPU (the claim is gated by `enable` at the pulse).
- `CPU_RX_DROPPED` counts unclaimed frames that found no free slot at their first beat; a frame claimed by a
  leaf is counted as claimed whatever the queue state.
- Untagged Ethernet II, frames up to 1518 bytes (`ETH_MAX_FRAME_BYTES`); a longer frame is dropped and
  counted.
- The filter's MAC copy follows a register change a few `axis_clk` clocks later; frames already in the
  filter keep the previous verdict.
- No metastability or post-route timing evidence: simulation is zero-delay and synthesis is out of context.

## 9. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version |
| 10-22-2026 | Checksum offload on the CPU path: `u_cpu_offload` (`CPU_TCP_OFFLOAD_ENABLE`) on both CPU streams, window 0x9000 (decoder `N` 3 with null slaves for absent windows), `CPU_CAPS` bits 16..18, driver `rtlnet_eth_protocol_get_cpu_features`, benches check CPU_CAPS and the window for builds with and without each block |
| 10-22-2026 | Leaf `claim` inputs; CPU network path (`u_cpu_rx_fifo` with the claim verdict, `u_cpu_tx_fifo` as arbiter source 5, CTRL bit 1, CAPS bit 5, CPU_CAPS, STATUS bits 20-22, DELIVERED and six CPU counters); `u_cpu_classifier` hook with its 0x8000 window (`CPU_CLASSIFIER_ENABLE`, `CPU_AXIS_CLK_HZ`); `tb_rtlnet_eth_protocol_cpu`; claim monitor; driver CPU-path functions |
