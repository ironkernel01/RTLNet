# rtlnet_classifier — frame filter / classifier (design specification)

| Item | Value |
|---|---|
| Core | `rtlnet_classifier` |
| Status | **Designed, not built.** This document is the specification the RTL will be written against. |
| Document revision | 10-22-2026 |
| Clock | `axis_clk` (the MAC client clock: 62.5 MHz on the Nexys Video, 156.25 / 390.625 MHz on 10G / 25G) |
| Registers | AXI4-Lite, `s_axi_aclk`, 12-bit window at RTLNet offset 0x2_0000 |
| Placement | between `rtlnet_eth_mac.m_axis_rx` and `rtlnet_eth_protocol.s_axis` (architecture section 13) |

## 1. Purpose

Decide, for every received frame, whether it is passed to the protocol layer or dropped, and count what each
rule matched — in line rate, without touching the frame. Typical uses: admit only the traffic a product
expects (ARP, ICMP, DHCP, one UDP port range), drop a flood, measure traffic classes, and later steer frames
to different consumers.

The classifier never edits a frame, never emits a partial frame, and fails closed: when enabled with no rule
selected it drops everything.

## 2. Interface

| Group | Ports |
|---|---|
| clocks, resets | `axis_clk`, `axis_resetn`, `s_axi_aclk`, `s_axi_aresetn` |
| frames in (axis_clk) | `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`, out `s_axis_tready` (a flop) |
| frames out (axis_clk) | `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`, in `m_axis_tready` — the output of an `rtlnet_axis_reg_slice` |
| registers | `s_axi_*`, `ADDR_W` 12 (internal `rtlnet_axil_cdc` to `axis_clk`, plus the snapshot handshake of section 7) |
| events (axis_clk) | `ev_pass`, `ev_drop` (one pulse per frame verdict), `ev_rule_hit[NUM_RULES-1:0]` |

| Parameter | Default | Meaning |
|---|---|---|
| `NUM_RULES` | 8 | rules evaluated in parallel on every frame |
| `HEADER_BYTES` | 64 | bytes of each frame compared (multiple of 8) |
| `NUM_FIELDS` | 4 | range-compare field units per rule (section 4.2) |
| `TABLE_MODE` | `"RAM"` | `"RAM"` (firmware-programmable) or `"ROM"` (rules fixed at build, no write path) |
| `DATA_FIFO_KB` | 1 | data FIFO size; must hold `HEADER_BYTES` + the verdict latency + margin |
| `RAM_STYLE` | `"block"` | rule table and FIFO RAM style |

## 3. Rule model

A rule has three parts. A frame **hits** a rule when the rule is enabled and all of its active parts agree.

### 3.1 Value/mask window

`HEADER_BYTES` value bytes and as many mask bytes: the window part agrees when
`((frame_byte[i] ^ value[i]) & mask[i]) == 0` for every byte `i` (bitwise, so a mask can select single bits).
A byte the frame does not carry compares as `0x00`, so a short frame cannot match vacuously.

### 3.2 Field compare units

`NUM_FIELDS` units, each comparing one big-endian 16-bit field of the window against a range:

| Field | Bits | Meaning |
|---|---|---|
| `OFFSET` | 6 | byte offset of the field's first byte in the window (0..62) |
| `OP` | 3 | 0 off, 1 `==`, 2 `!=`, 3 `<`, 4 `>`, 5 `in [LO, HI]`, 6 `not in [LO, HI]` |
| `LO`, `HI` | 16, 16 | operands (`LO` alone for the single-operand operators) |

Field units express what a mask cannot: port ranges (`UDP dst in [5000, 5100]`), "any EtherType below 0x0600"
(802.3 length), IP total-length bounds.

### 3.3 VLAN normalization

With `CTRL.VLAN_SKIP` set, a frame whose bytes 12..13 are 0x8100 has the 4-byte tag removed from the compare
window (bytes 16.. move to 12..), so the same rules match tagged and untagged frames; the tag's VID is
available to field units at a fixed pseudo-offset 62 (the last window word).

### 3.4 Actions and the verdict

Each rule carries `ACTION` (`PASS` or `DROP`) and `PRIORITY` (its index: rule 0 is highest). The verdict for a
frame is the action of the **highest-priority hitting rule**; with no hit, the global `DEFAULT_ACTION` applies
(reset value `DROP` when the classifier is enabled — fail closed). A rule can also be `COUNT_ONLY`: it counts
its hits but never decides. `CTRL.ENABLE = 0` bypasses the classifier (every frame passes, counters still run).

This combines the strengths of a one-hot "selected rule" filter (simple, deterministic) and an
include/exclude list (several rules active at once): any set of rules can be enabled together and the
priority order settles conflicts.

## 4. Datapath

```
s_axis -> accept (tready flop) --+--> data FIFO (store-and-forward, DATA_FIFO_KB) ----------------+
                                 |                                                                |
                                 +--> window builder (8 beats, zero fill, VLAN skip)               v
                                        -> per-rule mask compare (8 mismatch bits/beat, OR-reduce) release FSM --> slice --> m_axis
                                        -> per-rule field units (extract 16-bit, compare)          ^
                                        -> hit vector -> priority encoder -> verdict FIFO ---------+
```

- **Window builder.** Beats 0..7 of each frame are registered as they are accepted; a frame that ends inside
  the window is completed with synthetic zero beats (at most 7 extra cycles, during which `s_axis_tready` is
  low). The rule each frame is judged against is captured at its first beat, so a rule change takes effect at a
  frame boundary.
- **Mask compare.** Per rule and per beat: `|((data ^ value) & mask)` per byte, eight mismatch bits per beat,
  OR-accumulated over the window. The rule entry for beat `k` is read from the table one beat ahead (table
  RAM latency 2, the second register absorbed into the RAM output register).
- **Field units.** The window is held in a 64-byte register once beat 7 is in; each field unit selects its
  16-bit field with a 6-bit mux (pipelined in two stages) and compares in a third.
- **Verdict.** Hit vector to a priority encoder, one registered stage; the verdict (pass/drop + rule index) is
  pushed into a small verdict FIFO in frame order. Latency from a frame's first beat to its verdict:
  8 beats + 4 clocks.
- **Release FSM.** `S_IDLE` (wait for a verdict), `S_PASS` (stream the frame's beats to the output slice),
  `S_DROP` (pop and discard to `tlast`). On a last beat it takes the next verdict directly, so back-to-back
  frames cost no idle cycle.
- **FIFO sizing rule** (elaboration `$fatal`): data FIFO free space must exceed
  `HEADER_BEATS + VERDICT_LATENCY + PIPE_MARGIN` beats; `s_axis_tready` drops while free space is below that
  margin, so a burst of short frames can back-pressure the MAC's receive FIFO (which drops whole frames when
  full — counted there).
- Timing target: every stage at most two LUT levels so the same RTL closes at 156.25 MHz on Artix-7 and
  390.625 MHz on UltraScale+.

## 5. Rule table storage

One `rtlnet_ram_core` per 32-bit column so every AXI write is a full-width write:

| Table | Words per rule | Content |
|---|---:|---|
| value | `HEADER_BYTES/4` | value bytes, byte `4w` in bits [7:0] |
| mask | `HEADER_BYTES/4` | mask bytes |
| fields | `NUM_FIELDS * 2` | `{OP, OFFSET}` and `{HI, LO}` per unit |
| control | 1 | `ENABLE`, `ACTION`, `COUNT_ONLY` |

`TABLE_MODE = "ROM"` builds the default rules of section 8 into a read-only table (no write path exists, so no
CPU or bus master can change a filter chosen at build time). In RAM mode a loader writes the defaults after
reset and on `CTRL.RELOAD`; while loading, the verdict is forced to drop.

Safe update: the table is written in `s_axi_aclk` and read in `axis_clk` with no coherency, so a rule is
changed by disabling it (or moving traffic to a spare rule), writing it, and enabling it again; the driver does
this sequence.

## 6. Registers (offsets in the 4 KiB window)

| Offset | Name | Access | Content |
|---:|---|---|---|
| 0x000 | `ID` | RO | `"CLSF"` |
| 0x004 | `VERSION` | RO | register-map date code |
| 0x008 | `CAPS` | RO | `NUM_RULES`, `HEADER_BYTES`, `NUM_FIELDS`, ROM flag |
| 0x00C | `CTRL` | RW | bit0 `ENABLE`, bit1 `DEFAULT_ACTION` (1 pass), bit2 `VLAN_SKIP`, bit8 `RELOAD`, bit9 `SNAP`, bit10 `SNAP_CLEAR` |
| 0x010 | `STATUS` | RO | `LOADING`, `SNAP_BUSY`, `ROM`, `axis_resetn` seen |
| 0x014 | `RULE_ENABLE` | RW | one bit per rule |
| 0x020..0x02C | `CNT_FRAMES`, `CNT_PASS`, `CNT_DROP`, `CNT_DEFAULT` | RO | snapshot counters |
| 0x040 + 4r | `CNT_RULE[r]` | RO | snapshot: frames hitting rule r (whether or not it decided) |
| 0x100 + 4r | `RULE_CTRL[r]` | RW | `ACTION`, `COUNT_ONLY` |
| 0x400 + 0x80r + 4w | `RULE_VALUE[r][w]` | RW/RO(ROM) | value words |
| 0x800 + 0x80r + 4w | `RULE_MASK[r][w]` | RW/RO(ROM) | mask words |
| 0xC00 + 0x20r + 8u | `RULE_FIELD[r][u]` | RW/RO(ROM) | `{OP, OFFSET}`, `{HI, LO}` |

## 7. Counters and crossing

Live counters count in `axis_clk`. Firmware reads snapshot copies taken by a toggle request/acknowledge
handshake (`SNAP`, optionally `SNAP_CLEAR`); the snapshot bus is held stable from the acknowledge to the next
request and bounded by `set_max_delay -datapath_only` in `scripts/rtlnet_constrain_cdc.tcl`. The clear flag is
set one clock before the request toggles, so the destination never sees a new request with a stale clear flag.

## 8. Default rules

| Rule | Purpose | Window / fields | Action |
|---|---|---|---|
| 0 | ARP | bytes 12..13 = `08 06` | PASS |
| 1 | ICMP to IPv4 | 12..13 = `08 00`, 14 = `45`, 23 = `01` | PASS |
| 2 | DHCP server to client | IPv4/UDP (IHL 5), field: UDP dst (offset 36) `== 68` | PASS |
| 3 | iperf | IPv4/UDP, field: UDP dst `== 5001` | PASS |
| 4 | UDP sockets | IPv4/UDP, field: UDP dst `in [LO, HI]` (firmware sets the socket range) | PASS |
| 5 | broadcast flood guard | dst MAC `FF..FF`, EtherType not ARP | COUNT_ONLY |
| 6, 7 | spare | empty | — |

With the defaults enabled and `DEFAULT_ACTION = DROP`, the node accepts exactly the traffic its leaves serve.

## 9. Verification plan

| Bench | Proves |
|---|---|
| `tb_rtlnet_classifier` unit | every operator of the field units at its boundaries; mask bits singly; zero fill of short frames (a frame too short to carry a keyed byte never matches); priority between overlapping rules; COUNT_ONLY; DEFAULT_ACTION both ways; bypass; VLAN skip on tagged and untagged frames; back-to-back minimum frames at full rate with a random sink; rule change at a frame boundary; RAM loader and RELOAD; ROM mode rejects writes; snapshot counters including SNAP_CLEAR; 10 000 random frames against a bench reference model of the rule semantics |
| in-system | MAC + classifier + protocol wrapper: ping and ARP pass, an unexpected UDP port is dropped and counted |

Gates: synthesis at 62.5 MHz on Artix-7 and an out-of-context check at 156.25 MHz; zero failing setup/hold.

## 10. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Design specification |
