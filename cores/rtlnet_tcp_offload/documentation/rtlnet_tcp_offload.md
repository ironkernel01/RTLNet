# rtlnet_tcp_offload — IPv4 / TCP / UDP checksum offload

| Item | Value |
|---|---|
| Core | `rtlnet_tcp_offload` |
| Document revision | 10-22-2026 |
| Register ID / VERSION | `"TCPO"` = `0x5443504F` / `0x10222026` |
| Planned protocol sub-map slot | `0x9000` (`0x44A1_9000`); **documented, not wired in this revision** |
| Clock | one stream clock `clk` (the CPU stream clock); register file crossing from `s_axi_aclk` inside the core |
| Verification | `tb_rtlnet_tcp_offload` (4906 checks, 5 regression entries), driver host test (69 checks) |
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
| `TX_BUF_KB` | 4 | TX frame buffer in kilobytes (`rtlnet_packet_fifo`, 2 KiB slots: 4 = two frames) |
| `RAM_STYLE` | `"block"` | TX frame buffer RAM style |
| `SB_RAM_STYLE` | `"distributed"` | TX sideband queue RAM style |
| `MAX_FRAME_BYTES` | 1518 | largest frame; must give 256-word slots (1025..2048) |

## 3. Register map (4 KiB window)

Offsets and bits are defined once, in `driver/rtlnet_tcp_offload.h`; `hdl/rtlnet_tcp_offload_pkg.sv` mirrors them.

| Offset | Name | Access | Content |
|---:|---|---|---|
| 0x000 | `ID` | RO | `0x5443504F` |
| 0x004 | `VERSION` | RO | `0x10222026` |
| 0x008 | `CAPS` | RO | bit0 `TX_PRESENT`, bit1 `RX_PRESENT`, bit2 `INS_IP`, bit3 `INS_TCP`, bit4 `INS_UDP`, bit5 `VLAN`, [15:8] `TX_BUF_KB`, [26:16] largest frame in bytes. Reset value (default build) `0x05EE_043F` |
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

(The firmware side is phase B of the task and is not part of this revision.)

## 9. Verification

`tb_rtlnet_tcp_offload` (`regression.txt`: default technology, GENERIC, `TX_BUF_KB` 8, 16, negative control).
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
* Phase B (planned): instance in the protocol wrapper's CPU path (RX after the classifier, before S2MM; TX after
  MM2S, before the CPU TX FIFO), sub-map slot `0x9000`, `CPU_CAPS` discovery bits, firmware zero-copy options.

## 12. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version: egress insert, ingress trailer, registers, counters, driver, bench, timing gate |
