# rtlnet_classifier — configurable frame filter / classifier

| Item | Value |
|---|---|
| Core | `rtlnet_classifier` |
| Status | Specification of the core being built (10-22-2026) |
| Language | SystemVerilog-2012 (RTL), C11 (driver) |
| Clock | `axis_clk` of the stream it filters (`cpu_axis_clk` 100 MHz on the CPU path; the MAC client clock on a main-ingress instance) |
| Registers | AXI4-Lite, `s_axi_aclk`, 4 KiB window, internal `rtlnet_axil_cdc` to `axis_clk`; protocol sub-map 0x8000 for the CPU-path instance |
| First instance | inside `rtlnet_eth_protocol`, after `u_cpu_rx_fifo` (`u_cpu_classifier`): every frame headed to the CPU is filtered |
| Power-up state | **drop-all**, tables and rules cleared, until the C driver configures it |
| First driver configuration | **broadcast storm limiter**: destination `FF:FF:FF:FF:FF:FF` policed to 10 frames per 100 ms, every other frame passes |

## 1. Purpose and structure

A configurable MAC / EtherType / layer-2 / layer-3 / layer-4 filter that decides, for every frame, whether it passes,
is dropped or is rate-limited, at line rate and without modifying it, and counts what matched. All configuration
goes through the AXI4-Lite slave and is done by the C driver (`driver/rtlnet_classifier.c`).

Its structure follows a proven Ethernet-filter architecture on the 64-bit RTLNet stream: the ingress frame enters a
**shift-register delay line** of `MATCH_DEPTH_BYTES` (default 64) while the field tables, the tuple table and the
byte-by-byte mask+match rule engines judge those first bytes in parallel; when the frame reaches the end of the delay
line its decision is final, and the original frame is presented with its valid set (pass) or cleared (drop) by the
logical combination of the comparisons:

```
                     +--> field extractor --+--> FIELD TABLES  (MAC, ETHERTYPE, VLAN, IP, PORT) ------+
                     |                      +--> TUPLE TABLE   (proto + IP/mask + port ranges) -------+
s_axis --> accept ---+--> first MATCH_DEPTH_BYTES --> RULE ENGINES (per-byte mask + operator + value) +--> COMBINER --> POLICERS --> verdict FIFO --+
                     |                                                                                     (global MODE)                           |
                     +--> SHIFT-REGISTER DELAY LINE (DELAY_BEATS slots of {data, keep, last, valid}) -------------------------> valid gate --> slice --> m_axis
```

| Engine | Judges |
|---|---|
| Field tables | one header field per table against a list of entries: single value, range (entry pair = low/high) or data/mask (entry pair = value/mask); source, destination, either or both |
| Tuple table | each entry is one complete L3/L4 combination: IP protocol, source IP/mask, destination IP/mask, source port range, destination port range — "TCP from 192.169.1.0/24 to this host port 22" is one entry |
| Rule engines | the first 64 frame bytes by position: per byte a bit mask, an operator and a compare value (any L2/L3 data/mask pattern) |
| Combiner | forms `match` from the enabled gating engines and applies the global `MODE`: drop-all, pass-all, pass-on-match, drop-on-match |
| Policers | rate-limit frames that passed and hit a policing entry: `LIMIT_PKTS` frames per `WINDOW_MS` |

Every table and rule can be **gating** (it takes part in `match`) or **classify-only** (its hits select a policer and
are counted, nothing else) — the broadcast storm limiter is a classify-only MAC entry plus a policer under `MODE`
pass-all.

## 2. Interface

| Group | Ports |
|---|---|
| clocks, resets | `axis_clk`, `axis_resetn`, `s_axi_aclk`, `s_axi_aresetn` (both synchronous, active low) |
| frames in (axis_clk) | `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`, out `s_axis_tready` (a flop) |
| frames out (axis_clk) | `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`, in `m_axis_tready` (an `rtlnet_axis_reg_slice` output) |
| registers | `s_axi_*` AXI4-Lite slave, `ADDR_W` 12 |
| events (axis_clk) | `ev_pass`, `ev_drop` (one pulse per verdict) |

| Parameter | Default | Meaning |
|---|---|---|
| `AXIS_CLK_HZ` | 100_000_000 | stream clock in hertz (policer millisecond tick) |
| `TABLE_ENTRIES` | 16 | entries per field table |
| `TUPLE_ENTRIES` | 16 | tuple-table entries |
| `TABLE_LANES` | 2 | entries compared per clock per table (section 4.4) |
| `NUM_RULES` | 2 | positional rule engines |
| `NUM_POLICERS` | 4 | policers |
| `MATCH_DEPTH_BYTES` | 64 | bytes of each frame the rule engines compare and the delay line spans (multiple of 8, 40..256; at least 42 for the L4 fields of a VLAN-tagged frame) |
| `RAM_STYLE` | `"block"` | tables and compare buffers |

Derived: `DELAY_BEATS = MATCH_DEPTH_BYTES / 8 + VERDICT_LATENCY`, where `VERDICT_LATENCY` is the clock count from a
frame's last compared beat to its final verdict (table scan `TABLE_ENTRIES / TABLE_LANES` + capture + combiner +
policer stages; 8 with the defaults, so `DELAY_BEATS` = 16). An elaboration `$fatal` stops a parameter set whose
verdict could arrive after the frame's first beat leaves the delay line.

## 3. Field extractor

Captured as the beats arrive (untagged offsets; a VLAN-aware table on a frame with 0x8100 at bytes 12..13 uses the
offsets after the 4-byte tag):

| Field | Bytes (untagged) | Width |
|---|---|---|
| destination / source MAC | 0..5 / 6..11 | 48 |
| VLAN VID (+PCP) | 14..15 when 12..13 = 0x8100 | 12 (+3) |
| EtherType | 12..13 | 16 |
| IP protocol | 23 | 8 |
| source / destination IPv4 | 26..29 / 30..33 | 32 |
| source / destination L4 port | 34..35 / 36..37 | 16 |

Flags `is_vlan`, `is_ipv4` (EtherType 0x0800, IHL 5), `has_l4` (protocol 6 or 17 and not a fragment). An IP or port
compare against a frame that does not carry the field never hits; bytes beyond a short frame are absent, not zero.

## 4. Field tables and the tuple table

### 4.1 Field tables

Five tables, each `TABLE_ENTRIES` entries in its own `rtlnet_ram_core`: 0 MAC, 1 ETHERTYPE, 2 VLAN, 3 IP, 4 PORT. Entry:

| Field | Bits | Meaning |
|---|---|---|
| `SRC_VALUE` | 48 | source-field value (MAC 48, EtherType 16 (source only), VID 12, IP 32, port 16, zero-extended) |
| `DST_VALUE` | 48 | destination-field value (MAC, IP, port) |
| `SRC_EN`, `DST_EN`, `BOTH` | 1, 1, 1 | compare source, destination; with both: 1 = AND, 0 = OR |
| `PROTO_EN`, `PROTO` | 1, 8 | PORT table only: also require this IP protocol (6 TCP, 17 UDP) |
| `POLICE_EN`, `POLICER` | 1, 2 | a hit sends the frame to this policer |
| `VALID` | 1 | entry in use |

### 4.2 Field-table mode register (one per table)

| Bits | Name | Meaning |
|---|---|---|
| 0 | `ENABLE` | table in use |
| 1 | `EXCLUDE` | the table's contribution to `match` is "no entry hit" instead of "an entry hit" |
| 3:2 | `COMPARE` | 00 single value per entry; 01 range (entries 2k, 2k+1 = low, high); 10 data/mask (entries 2k, 2k+1 = value, mask: `(field & mask) == (value & mask)`) |
| 4 | `CLASSIFY` | classify-only: hits are counted and select policers; the table takes no part in `match` |
| 7 | `VLAN_AWARE` | use the post-tag offsets on tagged frames |

### 4.3 Tuple table (ACL)

`TUPLE_ENTRIES` entries, each one complete combination; an entry hits when every enabled part agrees:

| Field | Bits | Meaning |
|---|---|---|
| `PROTO`, `PROTO_EN` | 8, 1 | IP protocol (6 TCP, 17 UDP, 1 ICMP) |
| `SRC_IP`, `SRC_MASK` | 32, 32 | `(src_ip & SRC_MASK) == (SRC_IP & SRC_MASK)`; mask 0 = any |
| `DST_IP`, `DST_MASK` | 32, 32 | same for the destination |
| `SPORT_LO`, `SPORT_HI` | 16, 16 | source port range (0..65535 = any) |
| `DPORT_LO`, `DPORT_HI` | 16, 16 | destination port range |
| `POLICE_EN`, `POLICER` | 1, 2 | policer selection |
| `VALID` | 1 | entry in use |

Tuple-table mode register: `ENABLE`, `EXCLUDE`, `CLASSIFY` as in 4.2. The tuple table hits when any valid entry hits.

### 4.4 Scan

All six tables scan in parallel, `TABLE_LANES` entries per clock, starting when their fields are captured (MAC after
beat 1, EtherType/VLAN after beat 2, IP/port/tuple after beat 4). Range and mask pairs are compared in one clock. With
the defaults (16 entries, 2 lanes) the table results are ready about 13 clocks after a frame's first beat; a
minimum frame lasts 42 clocks at 1 Gb/s on 62.5 MHz and 107 clocks at 1 Gb/s on 100 MHz, so line rate holds. 10G/25G
builds raise `TABLE_LANES`; an elaboration `$fatal` checks `scan clocks + capture beat` against the minimum frame
time for the configured clock and line rate.

## 5. Rule engines

### 5.1 Compare buffer (one per rule, `MATCH_DEPTH_BYTES` entries = frame bytes 0..MATCH_DEPTH_BYTES-1)

| Bits | Field | Meaning |
|---|---|---|
| 7:0 | `COMPARE` | compare value |
| 11:8 | `OP` | `1000` `==`, `1001` `!=`, `1010` `<`, `1011` `>`, `1100` `<=`, `1101` `>=`, other: don't care |
| 31:24 | `MASK` | `(frame_byte & MASK) OP (COMPARE & MASK)` |

A rule matches when all `MATCH_DEPTH_BYTES` bytes pass (absent bytes of a shorter frame fail every operator except
don't-care). Eight byte ALUs per rule judge one beat per clock as the beats enter the delay line; the result is ready
two clocks after the last compared beat (beat `MATCH_DEPTH_BYTES/8 - 1`, or a shorter frame's last beat).

### 5.2 Rule mode register (one per rule)

| Bits | Name | Meaning |
|---|---|---|
| 0 | `ENABLE` | rule in use |
| 1 | `EXCLUDE` | the rule's contribution is "did not match" |
| 2 | `CLASSIFY` | classify-only |
| 3 | `POLICE_EN` | a matching frame goes to `POLICER` |
| 5:4 | `POLICER` | policer index |

## 6. Combiner, modes, policers, release

### 6.1 Match

`match = AND over every enabled, non-classify engine (6 tables, NUM_RULES rules) of its contribution`, where a
table's contribution is `hit` (or `!hit` with `EXCLUDE`) and the rules combine as in the reference behaviour: the OR
of the enabled include rules, except that when every enabled rule is an exclude rule the rules combine by AND (a frame
must match none of them). With no gating engine enabled, `match` is 1.

### 6.2 Global mode (`CTRL.MODE[1:0]`)

| `MODE` | Name | Verdict before policing |
|---|---|---|
| 00 | `DROP_ALL` (**power-up**) | drop every frame |
| 01 | `PASS_ALL` | pass every frame |
| 10 | `PASS_ON_MATCH` | pass when `match`, else drop |
| 11 | `DROP_ON_MATCH` | drop when `match`, else pass |

### 6.3 Policers

A frame that the mode passes is policed when it hit at least one entry or rule with `POLICE_EN` (gating or
classify-only); the first policing hit in priority order (rules, tuple table, then field tables, lower index first)
picks the policer. Policer `p` holds a budget reloaded to `LIMIT_PKTS[p]` at the start of every `WINDOW_MS[p]` ms
window (millisecond tick from `AXIS_CLK_HZ`); a policed frame passes while the budget is above zero and is dropped
otherwise. A write to `LIMIT_PKTS`/`WINDOW_MS` restarts the window; `WINDOW_MS` 0 acts as 1; `LIMIT_PKTS` 0 drops every
policed frame; a disabled policer passes. Per-policer counters `SEEN`, `PASSED`, `DROPPED` (`SEEN = PASSED + DROPPED`).

### 6.4 Delay line and valid gating

The delay line is `DELAY_BEATS` slots, each `{tdata, tkeep, tlast, slot_valid}`, plain registers (a vendor tool may
map them to shift-register primitives; no primitive is instanced). It **shifts every clock**: an accepted input beat
enters slot 0, otherwise an empty slot (bubble) enters, so every beat leaves exactly `DELAY_BEATS` clocks after it
entered and a frame's tail never waits for the next frame. The only stall is output back-pressure: while the last
slot holds a beat that the output slice cannot take, the whole line holds and `s_axis_tready` is low (registered).

Each frame's verdict is pushed into a small verdict FIFO (depth `DELAY_BEATS`, frame order) as soon as it is final.
When a frame's first beat reaches the last slot its verdict is popped and applied to every beat of that frame as it
leaves: pass sets the output `tvalid`, drop clears it (the beats are consumed and discarded). Because the line delay
is at least the verdict latency, a verdict is always present when its frame arrives at the output — a simulation-only
assertion makes any violation visible and the elaboration check of section 2 makes it impossible by construction.
Back-to-back frames, including minimum 60-byte frames, flow with no idle clock. A frame longer than
`MATCH_DEPTH_BYTES` is judged on its first `MATCH_DEPTH_BYTES` bytes and its remaining beats follow it through the
line under the same verdict.

## 6a. Timing structure (binding: the same RTL must close at 10G/25G line rates)

The classifier is written for 390.625 MHz on UltraScale+ (25G, one 64-bit beat per clock) and 156.25 MHz on Artix-7
(10G), so throughput never depends on a slower clock. Rules for every stage of the frame path:

| Rule | Implementation |
|---|---|
| at most **two LUT levels** between registers on every `axis_clk` path (a LUT6 plus at most one LUT/carry segment) | every operator below is split into registered stages; the stage count is part of `VERDICT_LATENCY` |
| no wide equality in one stage | a 48-bit compare is three 16-bit compares (one LUT level each, registered) then a registered 3-input AND |
| no wide magnitude compare in one stage | range and `< > <= >=` compares use 16-bit lanes with registered lane results (less, equal) combined in a second registered stage (32/48-bit fields: lane results merged most-significant first) |
| byte ALU | stage 1: `(byte & MASK)` and `COMPARE & MASK` registered; stage 2: `==`/`<` per byte (8-bit carry, one LUT level) registered; stage 3: operator select registered |
| 64-byte AND reduction | 8 bytes per beat AND-reduced in one LUT level per beat, then a running per-frame accumulator (one AND per clock) |
| table scan | each lane compare is the pipelined compare above; per-table hit is an OR of `TABLE_LANES` registered lane hits, accumulated over the scan |
| combiner and priority | engine contributions registered; `match` is a two-stage AND/OR tree; the policer priority encoder over (rules + 6 tables) is a two-stage registered encoder |
| policers | budget decrement and window compare registered separately (the window counter compare is a registered terminal-count flag) |
| RAM reads | `rtlnet_ram_core` with `READ_LATENCY` 2 for tables and compare buffers |
| fanout | control registers that fan out to many lanes (MODE, table modes, compare buffer outputs) are registered locally per engine, with `(* max_fanout *)`-free replication by explicit duplicate registers so no vendor attribute is required |
| delay line | plain registers, shift enable = one registered signal (`line_hold`), output gate = registered verdict bit AND slot valid |
| `s_axis_tready` | a flop; the output side uses an `rtlnet_axis_reg_slice` so the downstream ready reaches only `line_hold` |

`VERDICT_LATENCY` is a localparam computed from these stage counts (no hand-entered number), and
`DELAY_BEATS = MATCH_DEPTH_BYTES / 8 + VERDICT_LATENCY` follows it, so deeper pipelining can never release a frame
before its decision.

Gates: Vivado out-of-context synthesis + implementation of `rtlnet_classifier` alone with clock constraints —
156.25 MHz on xc7a200t-1 (10G rate on Artix-7) and 390.625 MHz on an UltraScale+ part available in the installed
Vivado (Spartan UltraScale+) — with zero failing setup/hold endpoints and a logic-level report (`report_design_analysis
-logic_level_distribution`) showing no `axis_clk` path above two LUT levels plus carry. The CPU-path instance runs at
100 MHz on the Nexys Video.

## 7. Registers (4 KiB window)

| Offset | Name | Access | Content |
|---:|---|---|---|
| 0x000 | `ID` | RO | `"CLSF"` |
| 0x004 | `VERSION` | RO | register-map date code |
| 0x008 | `CAPS` | RO | `TABLE_ENTRIES`, `TUPLE_ENTRIES`, `NUM_RULES`, `NUM_POLICERS`, `TABLE_LANES`, `MATCH_DEPTH_BYTES` |
| 0x00C | `CTRL` | RW | bits 1:0 `MODE` (reset 00 = DROP_ALL), bit8 `CLEAR_TABLES` (pulse: invalidate every entry, disable every table/rule/policer, MODE back to DROP_ALL), bit16 `CNT_CLEAR` |
| 0x010 | `STATUS` | RO | `CLEARING`, current MODE, delay-line stall seen (sticky) |
| 0x020 + 4t | `TABLE_MODE[t]` | RW | 4.2; t = 0 MAC, 1 ETHERTYPE, 2 VLAN, 3 IP, 4 PORT, 5 TUPLE |
| 0x040 + 4r | `RULE_MODE[r]` | RW | 5.2 |
| 0x080..0x0FC | counters | RO | `FRAMES`, `PASSED`, `DROPPED`, `MODE_DROPPED`, `POLICE_DROPPED`, `TABLE_HIT[t]` (6), `RULE_HIT[r]` |
| 0x100 + 0x20p | `POLICER[p]` | RW/RO | `+0` CTRL (bit0 ENABLE), `+4` LIMIT_PKTS, `+8` WINDOW_MS, `+C` SEEN, `+10` PASSED, `+14` DROPPED |
| 0x400 + 0x100t + 0x10e | `TABLE[t].ENTRY[e]` | RW | t = 0..4: `+0` SRC_VALUE[31:0], `+4` {VALID, SRC_EN, DST_EN, BOTH, PROTO_EN, POLICE_EN, POLICER, PROTO, SRC_VALUE[47:32]}, `+8` DST_VALUE[31:0], `+C` DST_VALUE[47:32] |
| 0x900 + 0x20e | `TUPLE.ENTRY[e]` | RW | `+0` {VALID, PROTO_EN, POLICE_EN, POLICER, PROTO}, `+4` SRC_IP, `+8` SRC_MASK, `+C` DST_IP, `+10` DST_MASK, `+14` {SPORT_HI, SPORT_LO}, `+18` {DPORT_HI, DPORT_LO} |
| 0xC00 + 0x100r + 4b | `RULE[r].BYTE[b]` | RW | 5.1 (b = 0..MATCH_DEPTH_BYTES-1; with more than 64 bytes the rule stride grows, see CAPS) |

Live counters count in `axis_clk` and reach the register clock by `rtlnet_gray_sync`. Table, tuple and rule memories
are written on `rtlnet_ram_core` port A from the register side and read by the engines on port B; the driver updates an
entry by disabling its table or rule, writing, and re-enabling, so no frame is judged against a half-written entry.
Power-up and `CLEAR_TABLES`: every entry invalid, every table/rule/policer disabled, `MODE` = DROP_ALL.

## 8. C driver (`driver/rtlnet_classifier.h/.c`)

The only way the filter is configured. API (all bounded, named error codes):

| Function | Purpose |
|---|---|
| `rtlnet_classifier_init(ctx, base)` | probe ID/CAPS |
| `..._set_mode(mode)` / `..._get_mode` | DROP_ALL, PASS_ALL, PASS_ON_MATCH, DROP_ON_MATCH |
| `..._clear_all()` | `CLEAR_TABLES` and wait (back to the power-up state) |
| `..._table_mode(table, enable, exclude, compare, classify, vlan_aware)` | 4.2 |
| `..._table_entry_set/get(table, index, const rtlnet_cls_entry_t *)` | field-table entry with the update protocol |
| `..._tuple_set/get(index, const rtlnet_cls_tuple_t *)` | tuple (ACL) entry |
| `..._rule_mode(rule, ...)`, `..._rule_byte(rule, byte, mask, op, value)`, `..._rule_pattern(rule, offset, len, data, mask)` | positional rules |
| `..._policer_set/get(p, enable, limit_pkts, window_ms)` | 6.3 |
| `..._counters(rtlnet_cls_counters_t *)`, `..._clear_counters()` | statistics |
| helpers | `..._mac_filter(index, mac, which, action)`, `..._ethertype_filter(index, lo, hi, action)`, `..._ipv4_filter(index, which, addr, mask, action)`, `..._port_filter(index, proto, which, lo, hi, action)`, `..._acl_add(index, proto, src/mask, dst/mask, sport range, dport range, action)` with `action` = gate-match / classify / police(p) |
| `..._config_bcast_storm(limit_pkts, window_ms)` | **the first default configuration**: clear, MAC table classify-only with entry 0 destination FF:FF:FF:FF:FF:FF policed by policer 0, policer 0 = limit/window, `MODE` = PASS_ALL |
| `..._bcast_storm_enable(on)` | enable/disable policer 0 |

The firmware network manager calls `rtlnet_classifier_config_bcast_storm(10, 100)` at boot, after probing, before the
CPU network path is used; until then the CPU receives nothing (drop-all).

## 9. Verification plan

| Bench | Proves |
|---|---|
| `tb_rtlnet_classifier` | power-up drop-all (nothing passes before configuration); each MODE; the broadcast storm configuration polices exactly `LIMIT` broadcasts per window while unicast passes, across several windows and limit/window changes; every field table in single, range and data/mask compare with source/destination/either/both, include/exclude, classify-only, VLAN-aware offsets; the PORT table protocol qualifier; tuple entries (TCP/UDP, masked IPs, port ranges, any-fields); every rule operator at its boundaries with masks; absent bytes never match; the delay line releases each frame exactly `DELAY_BEATS` clocks after entry with valid set or cleared by its verdict, frames shorter and longer than `MATCH_DEPTH_BYTES`, `MATCH_DEPTH_BYTES` 64 and 128; the rule-combination rule; policer priority; `CLEAR_TABLES`; back-to-back minimum frames at full rate with a random sink; entry update protocol; counters and identities; 10 000 random frames under random configurations against a bench reference model |
| driver host test | every driver function against a register model, including `config_bcast_storm` |
| in-system (wrapper bench) | CPU path: drop-all before configuration, broadcast storm limited after it, TCP to the host passes |

Gates: section 6a (156.25 MHz Artix-7 and 390.625 MHz UltraScale+ out-of-context with logic-level report; 100 MHz in
the board build); zero failing setup/hold.

## 10. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Design specification (value/mask window rules) |
| 10-22-2026 | Restructured as field tables + positional rule engines + combiner (single/range, per-byte operator ALU, include/exclude, verdict FIFO) |
| 10-22-2026 | EtherType table, data/mask compare, tuple (ACL) table, classify-only, policers, global MODE with power-up DROP_ALL; first instance on the CPU path; driver API with the broadcast storm limiter as the first default configuration |
| 10-22-2026 | Shift-register delay line of `MATCH_DEPTH_BYTES` (default 64) with verdict-gated valid at its output, in place of a store-and-forward FIFO |
| 10-22-2026 | Binding timing structure for 10G/25G line rates: two LUT levels per stage, pipelined compares and reductions, derived verdict latency |
