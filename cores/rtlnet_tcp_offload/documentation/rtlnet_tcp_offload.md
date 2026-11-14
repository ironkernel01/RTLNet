# rtlnet_tcp_offload — IPv4 / TCP / UDP checksum offload

| Item | Value |
|---|---|
| Core | `rtlnet_tcp_offload` |
| Document revision | 11-14-2026 |
| License | source-available (see `LICENSE.md`) |
| Register ID / VERSION | `"TCPO"` = `0x5443504F` / `0x10222026` |
| Protocol sub-map slot | `0x9000` (`0x44A1_9000`), instance `u_cpu_offload` in `rtlnet_eth_protocol` (`CPU_TCP_OFFLOAD_ENABLE`); wrapper `CPU_CAPS` bit 17 = TX present, bit 18 = RX present |
| Optional receive features | `ACK_COALESCE`, `RX_BATCH` (default 0 = not built, netlist unchanged), section 12 |
| Clock | one stream clock `clk` (the CPU stream clock); register file crossing from `s_axi_aclk` inside the core |
| Verification | `tb_rtlnet_tcp_offload` (4907 checks, 5 regression entries), `tb_rtlnet_tcp_offload_feat` (receive features, 5 entries, section 13), driver host test (4449 checks) |
| Synthesis (xc7a200t-3, 250 MHz) | WNS +0.281 ns, own logic <= 2 LUT levels, 1867 LUT, 3613 FF, 1.5 BRAM tiles |

## 1. Purpose

The CPU network stack (lwIP on the MicroBlaze) spends most of its cycles on the Internet checksum. This core sits
on the CPU DMA stream and does that work in logic:

* **Egress** (CPU DMA MM2S -> offload -> CPU TX FIFO): inserts the IPv4 header checksum and the TCP or UDP checksum
  into the frames the CPU sends. The CPU leaves the fields unfilled (any content is ignored).
* **Ingress** (classifier output -> offload -> AXI DMA S2MM): verifies the IPv4 header checksum and the TCP or UDP
  checksum while a frame streams and appends an 8-byte **trailer beat** that carries the result. Nothing is
  dropped in hardware; the CPU decides from the trailer.

Both paths are bit-exact pass-through at power-up (`CTRL = 0`), so firmware that does not know the core is not
affected. Only the pieces the CPU uses are offloaded: IPv4 header, TCP, UDP. ICMP and every other checksum stay in
software.

Two optional receive blocks cut the CPU's per-frame work further (section 12): **ACK coalescing** (hardware holds back pure TCP
ACKs of a flow and forwards only the newest per interval) and **receive batching** (consecutive frames, each with its trailer,
leave as one DMA transfer). Both are parameters, off after reset, and change nothing in lwIP's TCP logic.

```
          CPU DMA MM2S                                                         CPU TX FIFO
   s_axis_tx --> [in slice] --> [packet FIFO TX_BUF_KB] --> [patch] --> [out slice] --> m_axis_tx
                        \                ^   sideband queue (checksums, positions)
                         `--> [engine, TX mode] ---------'
          classifier                                                                CPU DMA S2MM
   s_axis_rx --> [in slice] --> [delay line RX_DELAY beats] --> [pad / trailer] --> [out slice] --> m_axis_rx
                        \                                  ^
                         `--> [engine, RX mode] -> trailer-'
   AXI4-Lite (s_axi_aclk) --> [rtlnet_axil_cdc] --> [register file, counters] (clk)
```

## 2. Interface

| Group | Ports |
|---|---|
| clocks, resets | `clk`, `resetn` (stream), `s_axi_aclk`, `s_axi_aresetn` (registers); each reset synchronous, active low, asserted together |
| TX in (from the DMA) | `s_axis_tx_tdata[63:0]`, `_tkeep[7:0]`, `_tvalid`, `_tlast`; out `_tready` (a flop) |
| TX out (to the CPU TX FIFO) | out `m_axis_tx_tdata[63:0]`, `_tkeep[7:0]`, `_tvalid`, `_tlast`; in `_tready` (all outputs are flops) |
| RX in (from the classifier) | `s_axis_rx_t*` as above |
| RX out (to the DMA) | `m_axis_rx_t*` as above |
| registers | `s_axi_*` AXI4-Lite slave, `ADDR_W` 12 |

All four streams are the RTLNet stream (64-bit `tdata`, `tkeep` contiguous on the last beat, `tlast`, no `tuser`).

| Parameter | Default | Meaning |
|---|---|---|
| `TX_BUF_KB` | 8 | TX frame buffer in kilobytes (`rtlnet_packet_fifo`, 2 KiB slots: 8 = four frames, full rate for every size) |
| `RAM_STYLE` | `"block"` | TX frame buffer RAM style |
| `SB_RAM_STYLE` | `"distributed"` | TX sideband queue RAM style |
| `MAX_FRAME_BYTES` | 1518 | largest frame; must give 256-word slots (1025..2048) |
| `ACK_COALESCE` | 0 | 1 builds the ACK coalescer (`rtlnet_tcp_offload_ackco`, section 12.1) |
| `ACK_FLOWS` | 4 | coalescer flow table entries, 2..16 |
| `ACK_RAM_STYLE` | `"distributed"` | coalescer slot RAM, `(ACK_FLOWS + 2) x 128` bytes (a flow count, not kilobytes: under 1 KB) |
| `RX_BATCH` | 0 | 1 builds the receive batcher (`rtlnet_tcp_offload_batch`, section 12.2) |
| `RX_BATCH_MAX_FRAME_BYTES` | 2048 | largest frame the batch byte limit keeps room for (multiple of 8) |
| `CLK_HZ` | 100000000 | `clk` frequency, for the microsecond tick of the two features |

## 3. Register map (4 KiB window)

Offsets and bits are defined once, in `driver/rtlnet_tcp_offload.h`; `hdl/rtlnet_tcp_offload_pkg.sv` mirrors them.

| Offset | Name | Access | Content |
|---:|---|---|---|
| 0x000 | `ID` | RO | `0x5443504F` |
| 0x004 | `VERSION` | RO | `0x10222026` |
| 0x008 | `CAPS` | RO | bit0 `TX_PRESENT`, bit1 `RX_PRESENT`, bit2 `INS_IP`, bit3 `INS_TCP`, bit4 `INS_UDP`, bit5 `VLAN`, [15:8] `TX_BUF_KB`, [26:16] largest frame in bytes. Reset value (default build, 8 KB) `0x05EE_083F` |
| 0x00C | `CTRL` | RW | bit0 `tx_ip_csum`, bit1 `tx_l4_csum`, bit2 `rx_csum`. Power-up 0. Reads back exactly as written; bits 31:3 read 0 |
| 0x010 | `STATUS` | RO | bit0 `TX_IDLE`: TX buffer, sideband queue and pipeline empty and no frame in progress. bit1 `RX_IDLE`: RX delay line empty and no trailer pending |
| 0x014 | `LATENCY` | RO | [7:0] TX: clocks from the final beat accepted to the sideband entry written (18); [15:8] RX delay-line beats (17) |
| 0x018 | `CNT_CLEAR` | WO | write bit 0 = 1 clears every counter; reads 0 |
| 0x040 | `TX_FRAMES` | RO | frames passed through the TX path (every frame) |
| 0x044 | `TX_IP_PATCHED` | RO | IPv4 header checksum inserted |
| 0x048 | `TX_L4_PATCHED` | RO | TCP / UDP checksum inserted |
| 0x04C | `TX_SKIPPED` | RO | `tx_l4_csum` on, valid IPv4 header, but fragment or protocol not TCP/UDP |
| 0x050 | `TX_MALFORMED` | RO | an insert is on, the frame is IPv4, but IHL < 5, the header runs past the frame, or the segment lies outside the frame / is shorter than its header |
| 0x054 | `TX_DROPPED` | RO | frame longer than a buffer slot (more than 256 beats), dropped |
| 0x060 | `RX_FRAMES` | RO | frames that received a trailer |
| 0x064 | `RX_VERIFIED` | RO | IPv4 header and L4 checksum both checked and good |
| 0x068 | `RX_IP_BAD` | RO | IPv4 frame whose header is malformed or whose header checksum is bad |
| 0x06C | `RX_L4_BAD` | RO | TCP/UDP segment checked and its checksum bad |
| 0x070 | `RX_UNVERIFIED` | RO | L4 check not possible (not IP, fragment, other protocol, UDP checksum 0, malformed) |

The registers of the two receive features (`CTRL` bits 3 and 4, `STATUS` bits 2 and 3, `CAPS` bits 6 and 7, `CAPS2`, the
configuration registers 0x020..0x030 and the counters 0x080 / 0x0A0) are appended in section 12.3; in a build without them they
read 0 and ignore writes, and every register above is unchanged.

Counters are 32-bit and wrap. Undefined offsets read 0 and ignore writes. CTRL is sampled by each datapath at the
first beat of every frame (the first beat the core accepts into its buffer / delay line), so a CTRL write changes
the behaviour for frames that start a few clocks after the write response, never mid-frame.

## 4. Egress design (`rtlnet_tcp_offload_tx`)

Store-and-forward: the checksum fields precede the data they cover.

1. An input `rtlnet_axis_reg_slice` registers the stream (registered `tready`). The beats go into the frame
   buffer `u_tx_fifo` (`rtlnet_packet_fifo`, `TX_BUF_KB`, back-pressure only between frames, never drops) and, one
   register later, into the checksum engine.
2. The engine (section 6) sums the IPv4 header and the pseudo-header plus segment. 18 clocks after the final
   beat was accepted one **sideband entry** per frame is written to a small queue (`rtlnet_ram_core`,
   `SB_RAM_STYLE`, twice as deep as the number of frame slots): `ip_en`, `l4_en`, tag, the beat and a 2-lane mask of
   the L4 checksum field, the IPv4 checksum, the L4 checksum. The CTRL value sampled at the frame's first beat
   decides `ip_en` / `l4_en`.
3. The frame leaves the buffer only when its sideband entry is valid. For each beat taken, the beat's patch flags
   are registered with it (beat 3 for the IPv4 field, the entry's beat for the L4 field; the IPv4 field is at frame
   byte 24/25, or 28/29 with a VLAN tag; the L4 field at TCP +16 or UDP +6 from the L4 start). A registered
   byte-lane replace between the patch register and the output slice overwrites those two bytes.
4. Rules:
   * The existing checksum field contents are ignored (treated as zero in the sum).
   * Bytes after `14 (+4) + IP total length` (Ethernet padding) are never summed.
   * UDP result `0x0000` is sent as `0xFFFF`; a TCP result of `0x0000` stays.
   * One 802.1Q tag (`0x8100`) is understood. IP options (IHL 5..15) are summed with the header.
   * L4 is skipped (counted `TX_SKIPPED`) for fragments (MF set or fragment offset non-zero) and protocols other
     than TCP (6) / UDP (17). Frames that fail the length rules are left unpatched and counted `TX_MALFORMED`:
     IHL < 5, header longer than the frame, total length beyond the frame, L4 shorter than 20 (TCP) / 8 (UDP).
   * Frames of 32 bytes or fewer are never treated as IPv4 (the engine needs five beats); everything else (non-IP,
     other EtherTypes) passes untouched.
   * A frame longer than a buffer slot (256 beats, 2048 bytes) is dropped and counted `TX_DROPPED`, exactly as the
     packet FIFO drops it. Frames of 1519..2048 bytes pass.
5. Disabled (`tx_ip_csum = tx_l4_csum = 0`) the entry has both enables clear and every byte passes untouched.
6. A frame keeps the CTRL value it started with: clearing a CTRL bit while frames sit in the buffer does not change
   those frames (bench case 9). `STATUS.TX_IDLE` tells firmware when none is left.

**Throughput.** One beat per clock in, one beat per clock out, with the packet FIFO's one idle clock between
frames on the read side. Latency is fixed: **23 clocks from the final input beat to the first output beat** (any
frame size). The patch needs the whole frame, so the number of frame slots decides whether this latency is hidden:
frame *n+2* can only start writing when frame *n* has left, and frame *n+1* must be complete + 23 clocks before it
can follow frame *n*.

| `TX_BUF_KB` (slots) | 1514-byte frames, period | 64-byte frames, period | line rate |
|---|---:|---:|---|
| 4 (2) | 200 clocks (190 beats) | 18 clocks (8 beats) | 95 % for maximum frames, 44 % for minimum frames |
| 8 (4) | 191 clocks | 9 clocks | full (FIFO idle clock only) |
| 16 (8) | 191 clocks | 9 clocks | full |

At the CPU path's 100 MHz clock the 4 KB default carries 6 Gb/s of maximum frames, far above any lwIP rate;
**a 10G build uses `TX_BUF_KB >= 8`** (four slots) to keep line rate for minimum-size frames.

## 5. Ingress design (`rtlnet_tcp_offload_rx`)

Cut-through: no frame store.

1. The frame's beats go through an input slice into a delay line of `RX_DELAY` = 17 beats (data in
   `rtlnet_shift_reg_core`, the valid chain in flip-flops) while the engine (RX mode) runs over the same beats.
   The engine's result reaches the trailer register in the clock the frame's final beat reaches the end of the line.
2. The line and the engine advance together (line time): they stop while the output slice cannot take a beat or a
   trailer is pending, so back-pressure from the DMA stalls both and the result stays aligned with the frame.
3. With `CTRL.rx_csum` set at the frame's first beat the final data beat leaves with its bytes beyond `tkeep`
   forced to zero and `tkeep = 0xFF`, `tlast` clear; one trailer beat (`tkeep = 0xFF`, `tlast`) follows. The
   trailer therefore sits at byte offset `roundup8(frame_len)` and the DMA transfer is `roundup8(frame_len) + 8` bytes.
   **Every** frame gets one, IP or not.
4. With `rx_csum` clear the stream is bit-exact (only the delay-line latency). The enable is sampled at each
   frame's first beat, so a change takes effect only at a frame boundary.

**Cost.** One beat per frame (the trailer): the final data beat is padded in place, so there is no padding beat.
Measured with no source gaps and no sink stalls: 1514-byte frames repeat every 191 clocks (190 + 1), 64-byte frames
every 9 (8 + 1); disabled, 190 and 8. First-beat latency is 19 clocks.

### 5.1 Trailer layout (64-bit little-endian word)

| Bits | Field |
|---|---|
| [15:0] | frame length in bytes (before padding), valid to 3072 |
| [31:16] | folded ones'-complement sum of pseudo-header + segment, **checksum field included**: `0xFFFF` for a correct segment. 0 unless a TCP/UDP segment inside the frame was summed |
| [47:32] | flags (below), upper bits 0 |
| [55:48] | L4 offset from the frame start (`14 (+4) + 4*IHL`); 0 unless the IPv4 header is valid |
| [63:56] | marker `0xA5` (upper nibble `0xA`: trailer, lower nibble `5`: layout version) |

| Flag | Meaning |
|---|---|
| b0 `is_ipv4` | EtherType IPv4 (after one VLAN tag), version 4, frame longer than 32 bytes |
| b1 `is_tcp`, b2 `is_udp` | `is_ipv4` and protocol 6 / 17 |
| b3 `vlan` | 802.1Q tag present (any frame of 14 bytes or more) |
| b4 `fragment` | `is_ipv4` and (MF set or fragment offset non-zero) |
| b5 `ip_ok` | IHL >= 5, header inside the frame, header checksum good |
| b6 `l4_ok` | `verified` and the segment checksum good |
| b7 `verified` | both checks were possible: valid header, TCP/UDP, not a fragment, segment inside the frame and long enough, UDP checksum field not zero |

Counters: `RX_VERIFIED` = b7 & b5 & b6; `RX_IP_BAD` = b0 & !b5; `RX_L4_BAD` = b7 & !b6; `RX_UNVERIFIED` = !b7.
The driver (`rtlnet_tcp_offload_trailer_parse`, `rtlnet_tcp_offload_rx_verdict`) validates the trailer position and
marker and maps the flags to pass / drop. The DMA buffer must hold `roundup8(1522) + 8` bytes.

## 6. Checksum engine (`rtlnet_tcp_offload_analyze`)

One streaming engine per path (TX mode masks the checksum fields out of the sums; RX mode keeps them and adds a
third tree that sums the L4 checksum field alone to detect UDP checksum 0). It parses while the frame passes:

* **Capture / derive.** Beats 1..3 hold every header field (both the untagged and the tagged offsets are captured; the
  tag selects later): EtherType, version/IHL, total length, fragment word, protocol. Derived values come in three
  register stages (`E` = 14 or 18): `4*IHL`, the L4 end `E + total length`, the L4 checksum field offset, and their
  beat/lane forms.
* **Masks.** Per beat the engine builds per-lane byte masks for the IPv4 header `[E, E + 4*IHL)` (minus the IPv4
  checksum word in TX mode), the pseudo-header address bytes (`E+12 .. E+20`) and the L4 range `[E + 4*IHL, E + total length)`
  (minus the L4 checksum field in TX mode) from the beat index with registered subtract / flag / lane / combine stages.
* **Sums.** The data beat, delayed by `rtlnet_shift_reg_core`, is masked and its four aligned 16-bit words summed
  (two 17-bit adders, one 18-bit adder), accumulated in 26 bits (256 beats of four words fit). The pseudo-header
  length + protocol is added after the last beat; folds finish the sum. All adders are one LUT level plus a carry chain.
* **Decisions.** Parallel to the sums: frame length, header end and segment end against the frame length, L4
  length against 20 (TCP) / 8 (UDP), IHL >= 5, version, EtherType, protocol class, fragment flag.
* **Latency.** `ANALYZE_LAT` = 16 enabled clocks from the clock the final beat is offered to the clock the result record
  is on the outputs (checked in simulation). Header fields from beats 0..3 are valid at the context stage for
  every beat from beat 4 on even when beats arrive back-to-back; the context for a frame's final beat is read before
  the next frame's first fields can reach the derived registers (the minimum frame spacing is two clocks from the final beat to
  the next frame's beat 1). The bench runs 160 back-to-back 5- and 6-beat frames and random gap / stall patterns.

Stage timeline (clock in which a beat offered in clock *c* is visible):

| Clock | Registers |
|---|---|
| c+1 | P1 beat, position flags, valid |
| c+2 | header capture (raw words, compare flags) |
| c+3 | D1 select by tag |
| c+4 | D2 `4*IHL` sum, L4 end, protocol class |
| c+5 | D3 beat/lane forms; context P5 reads D3 at c+4 |
| c+6..c+9 | M1 distance subtract, M2 flags, M3 lane masks, M4 combined masks |
| c+10, c+11, c+12 | S1 pair sums, S2 sum, S3 accumulate |
| c+13..c+15 | J1 header fold / segment add, J2 fold, J3 fold |
| c+16 | result record |

## 7. Clocks, resets, crossings

One stream clock. The AXI4-Lite slave crosses into it with one `rtlnet_axil_cdc` (`u_regs/u_axil_cdc`; its
`rtlnet_sync` instances are the two `sync` crossings); the TX frame buffer is a single-clock `rtlnet_packet_fifo`
instance `u_tx/u_tx_fifo` (matched by `scripts/rtlnet_constrain_cdc.tcl`, class `fifo`). Counters and CTRL live in the
stream clock, so no counter crossing exists. Expected `rtlnet_constrain_cdc.tcl` counts for the core: `sync 2`,
`axil_cdc 1`, `fifo 1`. Reset: all registers synchronous, active low; data registers are not reset (valid chains
and state are).

## 8. lwIP mapping

lwIP is built with `LWIP_CHECKSUM_CTRL_PER_NETIF = 1`; the netif's flags follow the CTRL value **read back** from the core:

| CTRL bit | lwIP flags |
|---|---|
| `tx_ip_csum` | `NETIF_CHECKSUM_GEN_IP` cleared (hardware inserts) |
| `tx_l4_csum` | `NETIF_CHECKSUM_GEN_TCP` and `NETIF_CHECKSUM_GEN_UDP` cleared |
| `rx_csum` | `NETIF_CHECKSUM_CHECK_IP`, `_CHECK_TCP`, `_CHECK_UDP` cleared, the netif parses the trailer |
| (none) | `GEN_ICMP` / `CHECK_ICMP` stay on: ICMP is not offloaded |

Ordering (one firmware function, never mismatched):

* TX bit **on**: write CTRL, read it back, then clear the matching `GEN_*` flag. Safe because the hardware
  overwrites the field and ignores what lwIP put there.
* TX bit **off**: set the `GEN_*` flag first, poll `STATUS.TX_IDLE` (bounded) so frames queued without a software
  checksum have left, then clear the CTRL bit.
* RX bit **on**: write CTRL, read it back, accept trailers once the first valid marker arrives, then clear the
  `CHECK_*` flags. RX bit **off**: set the `CHECK_*` flags first, then clear CTRL; frames already in buffers still
  carry trailers, so the netif keys off the marker per frame while the bit changes.
* The S2MM buffer holds `roundup8(1522) + 8` bytes; the netif reads the trailer at the end of the transfer, checks
  the marker and uses the trailer's frame length. Policy: IPv4 frame with a bad header, or a verified segment with
  a bad checksum -> drop and count; verified and good -> pass; unverified -> pass.
* `IP_REASSEMBLY 0`: fragments are never verified.

Firmware (as built, `cpu/microblaze_v_h264/firmware/src/rtlnet_offload.c`, `src/lwip/rtlnet_lwip_netif.c`):

* **Discovery** (`rtlnet_features_discover`, once at boot, before the classifier boot configuration): wrapper
  ID/VERSION, `CAPS.CPU_PATH_PRESENT`, `CPU_CAPS` bits 16..18, then the block's own header: classifier `"CLSF"` and
  VERSION; offload `"TCPO"`, VERSION and `CAPS.TX_PRESENT` / `CAPS.RX_PRESENT` equal to bits 17 / 18. A mismatch is
  printed and the block counts as absent. `show offload` and `show version` print the result.
* **`rtlnet_offload_apply(want)`** is the only function that writes CTRL and sets the netif checksum flags
  (`InitLWIP` calls it with "everything present" before the netif comes up; the CLI `offload tx-ip|tx-l4|rx|all on|off`
  calls it with the changed request). It masks the request by what is present and follows the orders above; the lwIP
  flags are always computed from the CTRL read-back (`rtlnet_offload_flags_for`), and `show offload` prints a
  `MISMATCH` line if the netif's flags ever differ from what the read-back implies. TX idle polling is bounded
  (`RTLNET_OFFLOAD_IDLE_POLLS`); on a timeout the CTRL bit stays on and the software checksum flags are restored.
* **Netif receive** (`rtlnet_offload_rx_frame`): trailer found by marker and length consistency; policy verified good
  or unverified -> pass, IPv4 header bad or verified L4 bad -> drop and count, rx_csum on and no trailer -> drop and
  count. The pbuf length is the trailer's frame length. State machine OFF / ARMING / ON / DRAINING as described above.
* **Zero copy** (compile-time, `lwipopts.h`; receive default on, transmit default off, measurements in the
  throughput table of the board documentation 6.6): `RTLNET_NETIF_ZERO_COPY_RX` hands the DMA buffer to lwIP
  as a custom `PBUF_REF` pbuf (16 buffers of 2048 bytes in the AXI BRAM, free list, S2MM armed from the free list);
  `RTLNET_NETIF_ZERO_COPY_TX` puts lwIP's heap in the AXI BRAM and DMAs a single-pbuf frame in place (MM2S has a data
  realignment engine, so any byte address works; the pbuf stays referenced until the transfer is done); chained pbufs
  and pbufs outside the AXI BRAM are copied.
* Measured on the Nexys Video (100 Mb/s, PC iperf 2): with the offload on, plain and `-R` TCP reach 94.9 Mbit/s
  (86.8 / 81.9 without); with zero-copy receive the CPU is 35 % busy at that rate (81 % with the receive copy);
  zero-copy transmit lowers `-R` to 90.4 Mbit/s (lwIP heap in the AXI BRAM) and is off by default (tables:
  `cpu/microblaze_v_h264/documentation/rtlnet_cpu_microblaze.md` 9.11, `boards/nexys_video/documentation/rtlnet_nexys_video.md` 6.6).
* Tests: host demo (`build.ps1 -Demo`: discovery of the none / TX only / RX only / both builds and the mismatch
  cases, the order of every CTRL / STATUS / lwIP-flag change, receive policy, CLI) and the netif test on real lwIP with
  a mock AXI DMA (`build.ps1 -NetifTest`, four zero-copy combinations).

## 9. Verification

`tb_rtlnet_tcp_offload` (`regression.txt`: default technology, GENERIC, `TX_BUF_KB` 4, 16, negative control; default 8).
The reference model (`parse_frame`, `ref_tx`, `ref_rx`) is written from the protocol rules with the RFC 1071 sum
of `rtlnet_tb_pkg` and shares no code with the RTL.

| Case | What it proves |
|---|---|
| 1 registers | ID/VERSION/CAPS, CTRL reset 0 and exact read-back, STATUS idle, undefined offsets, read-only ID, `CNT_CLEAR` |
| 2 pass-through | CTRL = 0: 200 random frames bit-exact on both paths (no trailer), with and without gaps / stalls |
| 3 TX insert | ip only, l4 only, both: random TCP / UDP / ICMP / ARP / VLAN / fragment / padded-minimum / odd-length / malformed / IHL 5..12 frames with random checksum garbage and junk past `tkeep`; output equals reference, other bytes untouched, counters equal |
| 3b directed | checksums that compute to zero: UDP -> `0xFFFF`, TCP stays 0, IPv4 header sum zero, with and without VLAN |
| 3c | 160 back-to-back 5- and 6-beat frames on both paths |
| 4 RX | good and corrupted frames, UDP checksum 0, zero sums: data bit-exact, zero padding, trailer at `roundup8(len)`, every trailer field equals reference, counters equal |
| 5 toggles | CTRL changed during continuous traffic on both paths: each frame follows the CTRL value at its first beat |
| 6 | TX and RX together with different stall patterns |
| 7 throughput | periods in sections 4 and 5, checked; latencies printed |
| 8, 9 | `TX_IDLE` falls with a frame in flight, stays low with buffered frames, rises after the drain; buffered frames keep their insert after CTRL is cleared |

Fifteen single-edit RTL mutants were run against the bench (pseudo-header mask, tagged IPv4 lanes, padding mask, flag
order, IHL offset, UDP zero mapping, TCP zero forced to `0xFFFF`, L4 field not excluded from the sum, UDP checksum 0
ignored, L4 offset ungated, patch register hold, fragment flag ungated, enable not frame-sampled, CTRL applied late at
readout, CTRL resampled every beat); each fails the bench. Three of them survived the first version of the bench and
led to the directed zero-sum frames, the toggle case keyed on the first-beat time, and the buffered-frame case 9.

Driver: `driver/test/build_test.ps1` (host gcc -pedantic -Werror, 69 checks, negative control, `mb-gcc -Werror` compile).

## 10. Synthesis

`rtlnet_synth_check.tcl` (xc7a200tsbg484-1): PASS, 0 critical warnings. Timing gate
`testbench/rtlnet_tcp_offload_timing.tcl` (out of context, implementation, `clk` 4.000 ns = 250 MHz, `s_axi_aclk` 10 ns,
xc7a200tsbg484-3, the 10G stand-in):

| Result | Value |
|---|---|
| WNS / WHS | +0.281 ns / +0.085 ns, 0 failing endpoints |
| LUT levels, own logic | at most 2 (7413 `clk` endpoints analysed: 2672 with 0, 3668 with 1, 687 with 2) |
| LUT levels, shared `rtlnet_common` | 3 inside `rtlnet_axil_cdc` / `rtlnet_axil_slave` and in the write-side control of `rtlnet_packet_fifo` (not gated; reported for the owners of those modules) |
| Utilization | 1867 LUT (1520 logic, 315 shift register, 32 distributed RAM), 3613 FF, 1.5 BRAM tiles (RAMB36 + RAMB18, the 4 KiB TX buffer) |

## 11. Limitations and future work

* One 802.1Q tag; QinQ and IPv6 are not offloaded (they pass, TX untouched, RX unverified).
* TX frames longer than 2048 bytes are dropped (as the packet FIFO does); RX length is exact to 3072 bytes.
* **Future work (deferred, not implemented):** parameters `TX_ENABLE` / `RX_ENABLE` (default 1) that turn a path
  into a plain wire with no buffer, no pipeline and no logic (CTRL bits read 0 and ignore writes, counters read 0);
  the single-path and none-present builds with their bench, synthesis and host-test cases; the wrapper parameters
  `CPU_TCP_OFFLOAD_TX_ENABLE` / `CPU_TCP_OFFLOAD_RX_ENABLE`; the "same firmware binary on all builds" proof. The
  CAPS bits `TX_PRESENT` / `RX_PRESENT` and the wrapper `CPU_CAPS` bits 17 / 18 are in place for them and read 1.
* Receive features: the ACK coalescer holds pure ACKs only for the allow-listed shapes (no options, or NOP NOP timestamp, IHL 5,
  untagged); every other ACK passes unchanged, so a peer that sends SACK or window-scale options in its ACKs is not coalesced.
  The batcher's byte guarantee is for frames up to `RX_BATCH_MAX_FRAME_BYTES`. Both need `CTRL.rx_csum`.
* Integrated in the protocol wrapper's CPU path (RX after the classifier, before the DMA S2MM; TX after the DMA MM2S,
  before the CPU TX FIFO) with the `CPU_CAPS` bits 17 / 18 (phase B).

## 12. Receive features: ACK coalescing and receive batching

Two optional blocks sit on the receive path between the trailer stage and the DMA. Both are parameters (`ACK_COALESCE`,
`RX_BATCH`, default 0 = not built: the netlist, the registers and the stream of the checksum-only core are unchanged, which
is what the H.264 design instantiates), both are off after reset (`CTRL` bits 3 and 4 = 0) and then pass the stream
bit-exact, and both work on the trailer, so `CTRL.rx_csum` must be on while they are. They exist because the soft CPU's
cost per frame, not the link, limits TCP: a frame costs one DMA transfer, one lwIP input and, for a bulk sender, one
acknowledgement frame per two segments received from the peer.

```
classifier -> [rx: delay line, trailer] -> [ackco] -> [batch] -> AXI DMA S2MM
                 sideband "frame has a trailer" (m_axis_trl) rides with every beat through a ninth lane
```

`rtlnet_tcp_offload_rx` gets the parameter `SIDEBAND` (set when either feature is built); its output slice then carries one
extra bit per beat, `1` for every beat of a frame that has a trailer (the padded data beats and the trailer), so the two
blocks can tell a trailer from frame data that happens to end in `0xA5`. A frame that started while `rx_csum` was off has no
trailer and bypasses both blocks unchanged.

Clock: the CPU stream clock `clk`, as the rest of the core. One microsecond tick (`CLK_HZ / 1_000_000` clocks, parameter
`CLK_HZ`, default 100 MHz) is shared by the two blocks.

### 12.1 ACK coalescing (`rtlnet_tcp_offload_ackco`)

While the board sends bulk TCP, the peer returns a stream of pure ACKs. The block holds the newest pure ACK of a flow and
forwards it after a timer, dropping the ACKs it replaces.

**Candidate.** A frame is a coalescing candidate when the trailer says (flags `& 0xFF == 0xE3`): IPv4, TCP, not UDP, not
VLAN, not a fragment, IPv4 header checksum good, TCP checksum checked and good; and the frame bytes say: EtherType `0x0800`,
IP version/IHL `0x45` (no IP options), TCP flags byte exactly `0x10` (ACK; SYN, FIN, RST, PSH, URG, ECE, CWR and the NS bit all
clear), IP total length 40 (no TCP options) or 52 with exactly the options `01 01 08 0A` (NOP, NOP, timestamp), the frame at
least `14 + total length` bytes, and the frame short enough to be staged (at most 9 data beats and the trailer). The option
test is an allow-list: any other layout (SACK blocks, MSS, window scale, timestamp after the NOPs, any padding) makes the frame
a non-candidate, so no option the block does not know can be swallowed. The flow key is the 4-tuple (source and destination
address and port).

**State.** `ACK_FLOWS` entries (default 4, 2..16). Per entry: key, held slot, held ack and sequence number, coalesce count,
start time, last candidate ack, LRU rank. A candidate of an unknown flow takes an invalid entry, else the least recently used
one; a held ACK of the victim is forwarded first (counted as an ordering flush).

**Rules for a candidate N of a known flow** (sequence numbers compared in 32-bit sequence space, `(a - b)` as a signed value):

| Held ACK H | Condition | Action |
|---|---|---|
| yes | `ack(N) > ack(H)` and `seq(N) >= seq(H)` | H is dropped (`ACK_DROPPED`), N is held, count + 1. When the count reaches `ACK_LIMIT`, N is forwarded at once instead (`ACK_FL_LIMIT`) |
| yes | same ack (duplicate ACK, window update), lower ack, or lower seq (keep-alive shape, old ACK) | H is forwarded, then N is forwarded at once; order kept (`ACK_FL_ORDER`) |
| no | `ack(N)` equal to or lower than the last candidate ack of the flow | N is forwarded at once |
| no | otherwise | N is held; its timer starts |

Why these rules are safe for TCP:

* **Equal acknowledgement numbers are never dropped, and never delayed behind a later frame.** Duplicate ACKs (fast
  retransmit counts three of them) and window updates (same ack, new window) reach the CPU in order and at once. This also
  covers the zero-window case: the ACK that re-opens a window carries the same ack number as the one that closed it.
* **A newer ACK replaces an older one only when it acknowledges more.** It carries the newest window and the newest
  timestamp options (TSval / TSecr), so lwIP's window, RTT and PAWS state after the coalesced ACK equal the state after the
  whole run. A smaller window with a larger ack is also the newest information.
* **Lower sequence number.** A keep-alive probe has `seq = snd_nxt - 1`; a pure ACK with a lower sequence number than the held
  one is never merged: the held ACK is forwarded first and the probe follows at once, so the reply a probe asks for is not
  delayed behind a timer and its sequence number is not lost.
* **SACK and every unknown option are forwarded untouched** (allow-list above), so loss recovery sees every SACK block.
* **Delayed ACK interplay.** The peer's delayed-ACK timer is untouched; the block adds at most `ACK_TIMER` microseconds to the
  newest ACK of a run and nothing to any other frame. With the default 200 us the added delay is far below a delayed-ACK
  timer (40 ms or more) and below one wire time of a 1500-byte frame at 10 Mb/s. The count limit forces an ACK out after at
  most `ACK_LIMIT` replacements, so ACK clocking is never starved.
* **lwIP counts ACKs for congestion window growth** (slow start adds one MSS per ACK, congestion avoidance `MSS*MSS/cwnd`).
  Coalescing reduces the number of ACKs, so the window grows more slowly by the coalescing ratio; the demo's send buffer (24 MSS)
  bounds the window anyway. `ACK_LIMIT` is the control to trade ratio against growth.

**Ordering.** Any non-candidate frame whose flow can be read (IPv4, IHL 5, TCP, not a fragment, not VLAN: data, bad checksum,
other flags, options not on the allow-list) first forwards the held ACK of its own flow. A TCP frame whose flow cannot be read
(VLAN tag, IP options, fragment) and a frame that carries no trailer forward every held ACK. Frames of other flows and frames
that are not TCP over IPv4 (ARP, ICMP, UDP, IPv6, ...) are never delayed and never reordered against a held ACK. Within a flow
the order of every frame is preserved.

**Flush.** A held ACK is forwarded when its age (time since it became held, not restarted by a replacement) reaches `ACK_TIMER`
(microseconds; 0 forwards at the next opportunity), when the count limit is reached, by the rules above, and when the feature
is switched off (every held ACK, in table order). A timer flush also forgets the flow's last ack, so an idle flow starts clean;
switching the feature off forgets the whole table.

**Datapath.** The first `ACK_HEAD_BEATS` (10) beats of every frame are staged in a slot of 16 beats of one RAM
(`rtlnet_ram_core`, `ACK_RAM_STYLE`, default distributed; `(ACK_FLOWS + 2)` slots of 128 bytes = 768 bytes for four flows; the
parameter is a flow count, not a kilobyte count, because the block is smaller than one kilobyte). A frame of up to 10 beats
(the candidates and every short frame) is decided as a whole; a longer frame is decided on its head and its tail passes
cut-through after the head. Slots are never copied: a held ACK stays in its slot, a replaced one frees its slot, a forwarded one
goes into a small emit queue that a second state machine reads out into the output slice.

```
state (input):  ARB -> CAP (beats into the slot RAM, fields into registers) -> DEC1 (key compares, sequence compares)
                -> DEC2 (decision) -> FLUSH (held ACKs, one per clock, into the emit queue) -> FINAL (hold / replace /
                forward the staged frame) -> ARB            (long frame: FINAL -> TAIL: pass the tail through -> ARB)
ARB also: expired timers and "feature off" start a FLUSH; the table is cleared while the feature is off.

timeline of one run (T = ACK_TIMER, 1 us ticks):
  rx output   : A1 ....... A2 ... A3 ..............................   (frame + trailer)
  held slot   : [A1       ][A2 replaced A1][A3 replaced A2 ...... ]  timer started when A1 was held
  output      :                                                  A3  (at t(A1 held) + T)
  counters    : CAND 3, DROPPED 2, FWD 1, FL_TIMER 1
```

Cost per frame: about `beats + 5` clocks between frames, with the head drain of a long frame stalling the input for about
10 clocks; far below the 64-byte frame rate of 1 Gb/s at the 100 MHz CPU stream clock. With the feature switched off every frame
still takes the staging path, unchanged in content (latency grows by about 20 clocks).

**Choosing the timer.** ACKs are only merged when they arrive closer together than `ACK_TIMER`. A peer that acknowledges every
second segment of a 106 Mb/s stream (1460-byte segments, one every 110 us) sends an ACK about every 220 us: the default 200 us
then merges almost nothing, while 500..1000 us merges two to five ACKs per forwarded ACK. The cost is the delay of the newest
ACK, which must stay well below the time the sender needs to use its window (35 KB of send buffer at 106 Mb/s: about 2.6 ms; at
1 Gb/s: 280 us, so a timer near 100 us is the limit there). Measure with `offload ack-coalesce on <timer> <limit>` and the counters
of `show offload`.

### 12.2 Receive batching (`rtlnet_tcp_offload_batch`)

Today every CPU-path frame is one DMA transfer. With batching, consecutive frames leave as one transfer.

**Format of a batch (one DMA transfer, one `tlast`):**

```
offset 0                                                       transfer length (multiple of 8)
| frame 1 (padded to 8) | trailer 1 | frame 2 (padded to 8) | trailer 2 | ... | frame n (padded) | trailer n |
                                                                                                   tlast
```

Every trailer is the unchanged 8-byte trailer of section 5.1; its length field gives the frame boundary. The firmware cannot walk
forward (the length stands after the frame), so it walks **backwards** from the end of the transfer: the last 8 bytes are
trailer n, its length gives the start of frame n, the 8 bytes before that are trailer n-1, and so on until offset 0. With
batching switched off, or for a lone frame, the transfer is `[frame padded][trailer]`, the stream of section 5 (a batch of one).

**How a batch closes.** The trailer beat of a batched frame is held in a register until the next beat shows what follows:

* the next frame starts and no limit has been reached: the held beat leaves with `tlast` clear and the batch continues
  (one clock of bubble per frame);
* a limit, the timer, the switch-off, or a frame without trailer closes the batch: the held beat leaves with `tlast` set.

Limits (registers):

| Register | Meaning |
|---|---|
| `BAT_FRAMES` | frames per batch, at most (0 and 1: every frame alone) |
| `BAT_BYTES` | bytes per batch, at most: **no transfer is longer than this value** for frames of at most `RX_BATCH_MAX_FRAME_BYTES` (default 2048). After a frame the batch is closed when `bytes + roundup8(RX_BATCH_MAX_FRAME_BYTES) + 8 > BAT_BYTES`, so any next frame fits. The firmware sets `BAT_BYTES` to the size of its DMA buffer. A frame longer than `RX_BATCH_MAX_FRAME_BYTES` (the MAC passes at most 1518 bytes) is outside the guarantee |
| `BAT_TIMER` | microseconds a batch waits, counted from the moment the trailer of its first frame was held; a single frame on an idle line leaves after this time at most (0: at once) |

A byte limit that cannot hold even one maximum frame closes the batch after every frame; the batch of a single oversized frame
is carried whole (the limit is a closing rule, not a drop).

```
timeline, BAT_FRAMES 3, three frames back to back:
  rx -> batch :  F1 data.. T1 | F2 data.. T2 | F3 data.. T3
  held trailer:        [T1 ........]  [T2 ........]  [T3]   (T1 leaves when F2's first beat arrives, T2 when F3's)
  output      :  F1 data..      F2 data..      F3 data.. T1 T2 -> in order: F1 T1 F2 T2 F3 T3(tlast, count limit)
single frame, idle line:  F1 data.. [T1 held ........ BAT_TIMER ........] T1(tlast)
```

`STATUS.BAT_IDLE` is 1 when no batch is open and nothing is held. Switching `CTRL.rx_batch` off closes an open batch
(counted `other`); the transfer is delivered, so the firmware can wait on `BAT_IDLE` and then change its buffers.

Events and counters: batches closed, frames carried, closes by byte limit / frame count / timer / other (feature off or a frame
without trailer follows). Priority when several apply at the same close: count, bytes, timer, other. Sum of the closes = batches.

### 12.3 Registers added (all other offsets and bits are those of section 3; the new ones read 0 and ignore writes in a build without the feature)

| Offset | Name | Access | Content |
|---:|---|---|---|
| 0x008 bit 6 / 7 | `CAPS.ACK_COALESCE` / `CAPS.RX_BATCH` | RO | feature built |
| 0x00C bit 3 / 4 | `CTRL.ack_coalesce` / `CTRL.rx_batch` | RW | enable; power-up 0; sampled at a frame's start and when a held item is released. Read back as written in a build that has the feature, 0 otherwise |
| 0x010 bit 2 / 3 | `STATUS.ACK_IDLE` / `STATUS.BAT_IDLE` | RO | no held ACK and no frame inside the coalescer / no batch open |
| 0x01C | `CAPS2` | RO | [7:0] `ACK_FLOWS`, [23:8] bytes the batch limit keeps free for a next frame (`roundup8(RX_BATCH_MAX_FRAME_BYTES) + 8`) |
| 0x020 | `ACK_TIMER` | RW | [15:0] microseconds, reset 200 |
| 0x024 | `ACK_LIMIT` | RW | [7:0] ACKs dropped per forwarded ACK, reset 8 (0 and 1 act as 1) |
| 0x028 | `BAT_TIMER` | RW | [15:0] microseconds, reset 30 |
| 0x02C | `BAT_FRAMES` | RW | [7:0] frames per batch, reset 16 |
| 0x030 | `BAT_BYTES` | RW | [15:0] bytes per batch, reset 8192 |
| 0x080 | `ACK_CAND` | RO | pure-ACK candidates seen |
| 0x084 | `ACK_DROPPED` | RO | held ACKs replaced by a newer one and dropped |
| 0x088 | `ACK_FWD` | RO | candidate ACKs forwarded; at idle `ACK_CAND = ACK_DROPPED + ACK_FWD` |
| 0x08C | `ACK_FL_TIMER` | RO | held ACKs forwarded by the timer |
| 0x090 | `ACK_FL_LIMIT` | RO | candidates forwarded at once because the count limit was reached |
| 0x094 | `ACK_FL_ORDER` | RO | held ACKs forwarded by ordering (later frame of the flow, duplicate / window update / lower ack or seq, eviction, switch-off) |
| 0x0A0 | `BAT_BATCHES` | RO | batches closed |
| 0x0A4 | `BAT_FRAMES_CNT` | RO | frames carried in batches |
| 0x0A8 | `BAT_CL_BYTES` | RO | closed by the byte limit |
| 0x0AC | `BAT_CL_COUNT` | RO | closed by the frame-count limit |
| 0x0B0 | `BAT_CL_TIMER` | RO | closed by the timer |
| 0x0B4 | `BAT_CL_OTHER` | RO | closed by switch-off or a following frame without trailer |

`CNT_CLEAR` clears these counters too. The read path has a second parallel stage for 0x080..0x0FF; the registers of the
checksum-only core are read through the original stage, unchanged. `ID` and `VERSION` are unchanged: the firmware discovers the
features from `CAPS`.

### 12.4 Wrapper and board

`rtlnet_eth_protocol` passes `CPU_TCP_OFFLOAD_ACK_COALESCE`, `CPU_TCP_OFFLOAD_RX_BATCH` and `CPU_TCP_OFFLOAD_ACK_FLOWS` (defaults
0, 0, 4) to `u_cpu_offload`, and `CPU_AXIS_CLK_HZ` as `CLK_HZ`. The Ethernet demo top (`rtlnet_nexys_video_eth_top`) sets both
to 1; the H.264 top keeps the defaults.

### 12.5 What the firmware does

The Ethernet demo firmware (`cpu/microblaze_v_ethernet/firmware`) selects the new paths at run time from the CAPS bits; a bitstream
without them runs the code of the checksum-only firmware.

* **Discovery:** `rtlnet_tcp_offload_init` reads `CAPS` and `CAPS2`; `rtlnet_offload_feat()` reports what is present.
* **Enable (CLI `offload ack-coalesce on [timer] [limit]`, `offload rx-batch on [timer] [frames]`):** rx offload must be on.
  rx-batch: the netif switches its receive memory from 16 buffers of 2 KiB to 4 buffers of 8 KiB (refused while a buffer is on loan
  to lwIP), then `BAT_BYTES` is set to the buffer size and `CTRL.rx_batch` to 1. ack-coalesce: timer and limit, then the bit.
* **Disable:** the bit first, then `STATUS.ACK_IDLE` / `BAT_IDLE` (bounded), then the buffers back to 2 KiB. Turning rx offload off
  switches both features off first.
* **Receive:** one DMA transfer per poll step. `rtlnet_tcp_offload_batch_walk()` splits it (bounds-checked: truncated, bad
  length, misaligned, bad marker, more than 64 frames are refused and the transfer is dropped); each frame goes through the same
  trailer policy as before (bad IPv4 / TCP checksum dropped and counted) and is handed to lwIP as a zero-copy `PBUF_REF` pbuf
  with a reference count per DMA buffer. The buffer returns to the free list when the last pbuf of the batch is freed. A batch
  that finds no buffer left to arm is copied into pool pbufs, so lwIP holding frames cannot starve the channel. `show offload`
  prints configuration and counters of both features and the netif's batch statistics.
* The DMA channel stays in simple mode, polled; no interrupt is added (section 12.6).

### 12.6 What one frame costs today, and the transmit side

Reading the firmware and the block design: the S2MM channel is a simple-mode transfer armed per frame (`XAxiDma_SimpleTransfer`)
and **polled** from the main loop (`rtlnet_netif_poll`: status register read, buffer length read, re-arm). The DMA interrupts are wired
to the interrupt controller but stay disabled (`dma_reset` disables them). So "one frame, one interrupt" is not what happens: it is
one frame, one polled completion and one re-arm (register writes over the CPU's slow AXI path), plus one lwIP input per frame.
Batching removes the completion, the re-arm and the buffer bookkeeping for all but one frame per batch; it does not remove the
lwIP input per frame. Transmit is the same: one simple MM2S transfer per frame, completion polled in `netif_linkoutput` and
`tx_reap`; there is no transmit ring or interrupt for Ethernet frames (`rtlnet_txring` is the console character ring), so
transmit completions are not batched and no small change gives one interrupt per several frames: that needs the scatter-gather
DMA with a descriptor ring and interrupt coalescing, a block design change that is not made here.

## 13. Verification of the receive features

`tb_rtlnet_tcp_offload_feat` (`regression.txt`: both, ACK only, batch only, generic technology, negative control). It builds the core
with the features at `CLK_HZ` 10 MHz (10 clocks per "microsecond"), reuses the checksum reference of section 9, and checks:

| Case | What it proves |
|---|---|
| R registers | CAPS / CAPS2 bits, defaults, read-back, undefined offsets, counters 0 at reset, `STATUS` idle bits |
| P built, disabled | random frames leave exactly as the plain core, one frame per transfer, feature counters 0; with `rx_csum` off and the feature bits set the frames leave bit-exact without trailer |
| D1-D19 ACK, directed | coalesced run; timestamps; duplicate ACKs; window updates; older ACK; lower and equal sequence number; SACK, MSS and timestamp-after-NOP layouts; eleven flag combinations (PSH, FIN, RST, SYN, URG, ECE, CWR, NS, none); short and long payload; bad TCP and IPv4 checksums; fragment, IP options and VLAN (flush every held ACK); two interleaved flows; table eviction; ordering against data of the same flow, other flows, UDP, ARP not delayed; timer flush latency measured; count limit; sequence-number wrap both ways; switch-off flush and `ACK_IDLE`; counters and `CAND = DROPPED + FWD` in every case |
| AR ACK, random | 300..500 mixed frames (pure ACKs with and without timestamps, duplicates, window updates, old ACKs, lower seq, SACK, MSS, data, every flag, bad checksums, VLAN, IP options, fragments, UDP, ARP, long frames) over 5 flows and a 4-entry table, source gaps and sink stalls, timer huge so only arrival order decides: the output order and all counters equal a bench model written from the rules |
| B batching, directed | single frame and measured timer close; count limit 4, 1 and 0; byte limit; exact fit (one beat above / below the closing rule); maximum frames 2048 bytes; a 3000-byte frame; minimum and maximum frame sizes in one run; back-to-back batches with counters adding up; backpressure at source and sink in three patterns; switch-off closes an open batch; a frame without trailer closes it; timer 0 |
| AB both | random model run with batching behind the coalescer: frames recovered by a backward walk equal the model, transfers within the limits, counters equal |

Negative controls: the `INJECT_FAILURE` run, and 21 single-edit RTL mutants of `ackco`, `batch` and `rx` were run against the
bench (replace rule without the sequence check, sequence compare not wrap-aware, duplicate ACK held, `l4_ok` ignored, any option
layout accepted, no flush-all, no ordering flush, limit and count off by one, timer ignored, victim not LRU, flags not exact,
byte limit off by one, `tlast` on every trailer, timer late, frame without trailer joins the batch, data beats not counted,
keep wrong on tail and last beat, sideband stuck): 20 fail the bench; the survivor (IHL test removed) is redundant with the total
length and header checks of the trailer flags and is kept as defence. The board bench `tb_rtlnet_nexys_video_eth` runs one batch
of three frames (count limit) and one coalesced run of four pure ACKs through the protocol wrapper, the MAC and the CPU stub.

Driver: `driver/test/build_test.ps1` (host gcc `-Werror -pedantic`, 4449 checks including the batch walker on hand-built batches,
malformed input — truncated, bad length, misaligned, bad marker, too many frames, stray bytes — 300 random batches and 4000 random
buffers, negative control, `mb-gcc -Werror`). Firmware: `build.ps1 -NoFirmware -NetifTest` (batch path in all four zero-copy
combinations) and `-Demo` (CLI).

## 14. Resource estimate of the receive features

Not yet measured: the synthesis check of the feature build (`rtlnet_synth_check.tcl`, `rtlnet_tcp_offload`, `ACK_COALESCE=1,RX_BATCH=1`) was
queued behind other jobs when this section was written. The estimate below comes from the register and RAM counts of the RTL; the
measured numbers replace it (a build without the features is the 1867 LUT / 3613 FF / 1.5 BRAM of section 10, unchanged).

| Block | LUT (estimate) | FF (estimate) | RAM |
|---|---:|---:|---|
| `rtlnet_tcp_offload_ackco` (4 flows) | 900..1300 | 1400..1700 | 768 bytes distributed (about 130 LUT as RAM, counted in the LUT column) |
| `rtlnet_tcp_offload_batch` | 100..150 | 220..260 | none |
| registers and counters (12 counters, 5 configuration registers, second read stage) | 450..600 | 480..550 | none |
| `rtlnet_tcp_offload_rx` sideband (ninth lane of the output slice) | about 10 | about 20 | none |
| Total added | 1450..2050 | 2100..2500 | no block RAM |

Flip-flop budget of the coalescer: per flow about 230 (key 96, held ack and sequence 64, last ack 32, start time 16, count 8, slot
number, flags, LRU rank), times `ACK_FLOWS`, plus about 330 for the fields parsed from the staged frame, the emit queue, both state
machines and the 72-bit output slice. `ACK_FLOWS` 8 adds about 1000 FF and 400 LUT; the slot RAM grows by 128 bytes per flow. No
single path is expected above three LUT levels (the widest is the 96-bit key compare and the 32-bit sequence compares, which are
registered in `S_DEC1` before the decision), well inside the 10 ns clock of the CPU stream; the 250 MHz timing gate of section 10
covers the checksum-only core and does not apply to these blocks.


## 15. Revision history

| Revision | Change |
|---|---|
| 11-14-2026 | Optional receive features: ACK coalescing and receive batching (parameters, registers, counters, driver, bench, firmware, Ethernet demo hook-up) |
| 10-22-2026 | Initial version: egress insert, ingress trailer, registers, counters, driver, bench, timing gate |
