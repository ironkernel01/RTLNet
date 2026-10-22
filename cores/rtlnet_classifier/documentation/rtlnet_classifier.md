# rtlnet_classifier — configurable frame filter / classifier

| Item | Value |
|---|---|
| Core | `rtlnet_classifier` |
| Status | Built and verified (10-22-2026): RTL `hdl/`, driver `driver/`, bench `testbench/`; as-built details and deviations in section 10 |
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
policer stages). As built (section 10.2): `VERDICT_LATENCY = WIN + 15` with `WIN = max(TABLE_ENTRIES, TUPLE_ENTRIES) /
TABLE_LANES`, so the defaults give `VERDICT_LATENCY` = 23 and `DELAY_BEATS` = 31 (the original estimate of 8 / 16
predates the two-LUT-level pipelining of section 6a). An elaboration `$fatal` stops a parameter set whose verdict
could arrive after the frame's first beat leaves the delay line.

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

The delay line is `DELAY_BEATS` slots. `{tdata, tkeep, tlast}` (73 bits) live in one `rtlnet_shift_reg_core`
(`u_delay_line`: on AMD a LUT shift-register RAM of `SRLC32E` instances with a registered output; the technology comes
from `rtlnet_technology.svh`). The per-slot valid bits cannot live in a LUT shift register (it has no reset), so they
are a `DELAY_BEATS`-bit flip-flop shift chain that clears on reset — a warm reset can never release stale beats. The
line **shifts every clock**: an accepted input beat
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
| delay line | `rtlnet_shift_reg_core` (SRL data path, registered output) + flip-flop valid chain; shift enable = one registered signal (`line_hold`), output gate = registered verdict bit AND slot valid |
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
| 0x010 | `STATUS` | RO | bit0 `CLEARING`, bits 9:8 current MODE, bit16 delay-line stall seen (sticky, cleared by `CNT_CLEAR`) |
| 0x014 | `LATENCY` | RO | as built: bits 7:0 `DELAY_BEATS`, bits 15:8 `VERDICT_LATENCY` |
| 0x020 + 4t | `TABLE_MODE[t]` | RW | 4.2; t = 0 MAC, 1 ETHERTYPE, 2 VLAN, 3 IP, 4 PORT, 5 TUPLE |
| 0x040 + 4r | `RULE_MODE[r]` | RW | 5.2 |
| 0x080..0x0FC | counters | RO | 0x080 `FRAMES`, 0x084 `PASSED`, 0x088 `DROPPED`, 0x08C `MODE_DROPPED`, 0x090 `POLICE_DROPPED`, 0x094 + 4t `TABLE_HIT[t]` (6), 0x0AC + 4r `RULE_HIT[r]` (4), as built: 0x0BC `OVERRUN_DROPPED` |
| 0x100 + 0x20p | `POLICER[p]` | RW/RO | `+0` CTRL (bit0 ENABLE), `+4` LIMIT_PKTS, `+8` WINDOW_MS, `+C` SEEN, `+10` PASSED, `+14` DROPPED, as built: `+18` BUDGET (RO, frames left in the window) |
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

## 10. As built (10-22-2026)

### 10.1 Files and modules

| File | Module | Content |
|---|---|---|
| `hdl/rtlnet_classifier.sv` | `rtlnet_classifier` | top: ports and parameters of section 2, derived localparams, elaboration checks, instances |
| `hdl/rtlnet_classifier_pkg.sv` | `rtlnet_classifier_pkg` | register map (mirror of the driver header), bit layouts, operator codes, pipeline stage counts |
| `hdl/rtlnet_classifier_regs.sv` | `rtlnet_classifier_regs` | `u_axil_cdc` (`rtlnet_axil_cdc`), `u_axil_slave` (`rtlnet_axil_slave`), control registers, configuration write bus, clear sequence, readback mirror `u_mirror_ram`, read path |
| `hdl/rtlnet_classifier_line.sv` | `rtlnet_classifier_line` | ingress skid stage, registered line enable, `u_delay_line` (`rtlnet_shift_reg_core`), valid / start-of-frame flip-flop chains, verdict queue, gate, `u_out_slice` (`rtlnet_axis_reg_slice`), engine tap |
| `hdl/rtlnet_classifier_extract.sv` | `rtlnet_classifier_extract` | field capture, header flags, judge acceptance, per-table snapshot |
| `hdl/rtlnet_classifier_table.sv` | `rtlnet_classifier_table` | one field table (instances `u_tbl_mac`, `u_tbl_ethertype`, `u_tbl_vlan`, `u_tbl_ip`, `u_tbl_port`) |
| `hdl/rtlnet_classifier_tuple.sv` | `rtlnet_classifier_tuple` | tuple (ACL) table `u_tuple` |
| `hdl/rtlnet_classifier_hitacc.sv` | `rtlnet_classifier_hitacc` | lane reduce, window accumulation, lowest-index policing hit, result latch (shared by tables and tuple) |
| `hdl/rtlnet_classifier_rule.sv` | `rtlnet_classifier_rule` | one positional rule engine (`g_rule[r].u_rule`) |
| `hdl/rtlnet_classifier_combiner.sv` | `rtlnet_classifier_combiner` | token pipeline, match, MODE, policer selection and policers, verdicts, counters |
| `hdl/rtlnet_classifier.f` | | filelist (starts with `-f cores/rtlnet_common/hdl/rtlnet_common.f`) |
| `driver/rtlnet_classifier.h/.c` | | C driver (section 8, 10.6) |
| `driver/test/` | | host unit test `test_rtlnet_classifier_host.c`, `build_test.ps1`, `Makefile` |
| `testbench/tb_rtlnet_classifier.sv/.f`, `regression.txt` | | bench and regression list |
| `testbench/rtlnet_classifier_timing.tcl` | | out-of-context implementation and LUT-level gate (section 10.8) |

### 10.2 Frame path and latency

| Quantity | Value (formula; defaults) |
|---|---|
| `WIN` (table words per frame) | `max(TABLE_ENTRIES, TUPLE_ENTRIES) / TABLE_LANES`; 8 |
| `JUDGE_GAP` (clocks between accepted judges) | `max(WIN, 4)`; 8 |
| `VERDICT_LATENCY` | tap 1 + capture 2 + snapshot 1 + (`WIN` - 1) + table 7 + combiner 3 + policer 1 + queue 1 = `WIN + 15`; 23 |
| `DELAY_BEATS` | `MATCH_DEPTH_BYTES / 8 + VERDICT_LATENCY`; 31 |
| s_axis to m_axis, gap-free frame, ready sink | `DELAY_BEATS + 2` clocks (ingress register + line + output slice); 33 clocks = 330 ns at 100 MHz |
| `MATCH_DEPTH_BYTES` 128, `TABLE_LANES` 4 (bench build m128) | `WIN` 4, `VERDICT_LATENCY` 19, `DELAY_BEATS` 35 |
| `MATCH_DEPTH_BYTES` 40, entries 8/4, lanes 2 (bench build m40) | `WIN` 4, `VERDICT_LATENCY` 19, `DELAY_BEATS` 24 |
| Throughput | one beat per clock; back-to-back 60-byte frames with no idle clock (bench) |

All of these are localparams computed from the stage counts in `rtlnet_classifier_pkg`; `LATENCY` (0x014) reports
`DELAY_BEATS` and `VERDICT_LATENCY` of the build.

Judge: a frame's decision starts at its "judge" beat, beat `MATCH_DEPTH_BYTES / 8 - 1` or the final beat of a
shorter frame. The extractor snapshots every table field in the clock after the capture is complete; each table
reads its words on a free-running rotating address and compares the snapshot during the `WIN` clocks after it loads,
so every entry is seen once whatever the rotation phase (the lowest-index policing hit is still found: section 6.3).
The rule engines judge each beat as it enters the line and finish 8 clocks after the judge beat; the combiner
takes the rule results into a per-frame token and the table results `WIN + 6` clocks after the snapshot.

### 10.3 Deviations from sections 1..9, and why

| Section | Specification | As built | Reason |
|---|---|---|---|
| 2, 6a | `VERDICT_LATENCY` 8 (estimate), `DELAY_BEATS` 16 | 23 and 31 with the defaults (formula above) | the two-LUT-level stages of 6a (register-to-register compare lanes, merge, side hit, entry hit, reduce, accumulate, latch; three combiner stages) do not fit the original estimate; the derivation is mechanical as 6a requires |
| 4.4 | each table starts scanning when its fields are captured (MAC beat 1, ... IP/port beat 4) | all tables compare at the judge beat, on a rotating read address | the scan then needs no per-table start and no field double-buffering; with `MATCH_DEPTH_BYTES` 64 it costs 2 clocks of latency against a beat-5 start (VLAN-aware ports are in beat 5) |
| 4.4 | `$fatal` on scan clocks + capture beat against the minimum frame time at the configured clock and line rate | `$fatal` when `WIN` > 8 (8 clocks = one 60-byte frame at one beat per clock) | the core has no line-rate parameter; one beat per clock is the worst case of every RTLNet build |
| 6.4 | the line shifts every clock; with no input beat a bubble enters | identical while the source is gap-free; while a frame is being received and its next beat is not yet offered, the line holds (no bubble enters inside a frame) | with bubbles inside a frame, the first beat reaches the end of the line before the frame's later beats are judged (a 1 Gb/s MAC on a 62.5 MHz stream offers one beat in four clocks); holding keeps "the verdict is present when the frame arrives" true for any source. Between frames the line still flushes freely, so a frame's tail never waits for the next frame's start, only for the gaps inside the next frame |
| 6.4 | back-to-back frames of any size | frames whose judge beat comes less than `JUDGE_GAP` clocks after the previous accepted judge are dropped and counted (`OVERRUN_DROPPED`, 0x0BC) | the tables finish one frame per `WIN` clocks and the policer budget feedback needs 4 clocks. This can only happen to a frame shorter than 57 bytes (8 beats) following another frame closely; legal Ethernet frames (60 bytes or more) are never affected |
| 7 | counters reach the register clock through `rtlnet_gray_sync` | the register file runs in `axis_clk` behind `rtlnet_axil_cdc` (as section 7 also states), so counters are read in their own clock; no Gray crossing exists | the two statements of section 7 conflict; the `rtlnet_axil_cdc` placement was kept |
| 7 | table words RW | the engines' memories are write-only from the register side; reads come from a readback mirror (`u_mirror_ram`, 1024 x 32, written with every defined entry word and cleared with the tables): every defined word reads back as written, undefined offsets read 0 | `rtlnet_ram_core` port B belongs to the engine |
| 7 | additions | `LATENCY` (0x014), `OVERRUN_DROPPED` (0x0BC), policer `BUDGET` (+0x18) | visibility of the derived latency, the overrun drop and the current window |
| 7 | power-up: every entry invalid | after reset and after `CLEAR_TABLES` a 1024-clock clear sequence writes zero to every engine and mirror word (`STATUS.CLEARING`; entry writes are ignored meanwhile; the driver waits for it) | a warm reset must not leave valid entries in the memories, which have no reset |
| 2 | parameter ranges | `TABLE_ENTRIES`, `TUPLE_ENTRIES` in {2, 4, 8, 16} (16 is the register-map limit), `TABLE_LANES` in {2, 4}, `NUM_RULES` 1..4 and `NUM_RULES x RULE_STRIDE` <= 0x400, `NUM_POLICERS` 1..4 (the policer fields are 2 bits), `AXIS_CLK_HZ` >= 4000 | each limit is an elaboration `$fatal` |

### 10.4 Semantics fixed by the build (the specification left them open)

* Field values are in number order (first wire byte most significant): MAC `00:11:22:33:44:55` = `0x001122334455`.
* VLAN field: `{PCP, VID}` (15 bits) in data/mask compare, `VID` (PCP forced to 0) in single and range compare;
  present only on a tagged frame. ETHERTYPE and VLAN have no destination side (an entry with only `DST_EN` never
  hits). A non-VLAN-aware table on a tagged frame sees EtherType 0x8100, so its IP and port fields are absent.
* `is_ipv4`: EtherType 0x0800 and byte `0x45` at the selected offsets. `has_l4`: `is_ipv4`, protocol 6 or 17, and
  not a fragment (MF = 0 and fragment offset = 0). A field is present when its last byte was received within the
  first `min(48, MATCH_DEPTH_BYTES)` bytes (so with 40 bytes the VLAN-aware L4 ports are absent, as section 2 says).
* Range and data/mask pairs: the control word of the even entry governs the pair; the odd entry supplies only values.
  `COMPARE` 11 never hits.
* Tuple: a non-IPv4 frame never hits; a port range 0..65535 is "any" and also matches a frame without L4 ports
  (ICMP, fragments); any other range requires `has_l4`.
* Rules: the reference combination: OR of the contributions of the enabled gating rules (`match`, or `!match` for an
  exclude rule), AND of `!match` when every enabled gating rule is an exclude rule, 1 with none.
* Policers: a write to `CTRL`, `LIMIT_PKTS` or `WINDOW_MS` restarts the window and reloads the budget; each policer
  has its own millisecond prescaler, so windows are exact from the restart (to within the 4-clock decision
  pipeline). `SEEN`/`PASSED`/`DROPPED` count frames policed by an enabled policer. A policer index at or above
  `NUM_POLICERS` acts as disabled.
* Hit counters count judged frames that hit an enabled table or matched an enabled rule (gating or classify-only);
  an overrun frame counts only in `FRAMES`, `DROPPED` and `OVERRUN_DROPPED`.
* Rule updates: each rule keeps a per-byte don't-care vector beside its buffer; its suffix AND settles
  `MATCH_DEPTH_BYTES / 8 + 8` clocks after a write, which the driver covers (rule disabled, `RTLNET_CLS_SETTLE_READS`
  register reads before re-enabling).

### 10.5 Register map summary (as built)

| Offset | Name | Bits |
|---:|---|---|
| 0x000 | `ID` | `0x434C5346` ("CLSF") |
| 0x004 | `VERSION` | `0x10222026` |
| 0x008 | `CAPS` | [4:0] `TABLE_ENTRIES`, [9:5] `TUPLE_ENTRIES`, [12:10] `NUM_RULES`, [15:13] `NUM_POLICERS`, [20:16] `TABLE_LANES`, [26:21] `MATCH_DEPTH_BYTES / 8` |
| 0x00C | `CTRL` | [1:0] `MODE` (reset 0), bit8 `CLEAR_TABLES` (pulse), bit16 `CNT_CLEAR` (pulse) |
| 0x010 | `STATUS` | bit0 `CLEARING`, [9:8] `MODE`, bit16 `STALL_SEEN` |
| 0x014 | `LATENCY` | [7:0] `DELAY_BEATS`, [15:8] `VERDICT_LATENCY` |
| 0x020 + 4t | `TABLE_MODE[t]` | bit0 `ENABLE`, bit1 `EXCLUDE`, [3:2] `COMPARE`, bit4 `CLASSIFY`, bit7 `VLAN_AWARE` |
| 0x040 + 4r | `RULE_MODE[r]` | bit0 `ENABLE`, bit1 `EXCLUDE`, bit2 `CLASSIFY`, bit3 `POLICE_EN`, [5:4] `POLICER` |
| 0x080..0x0BC | counters | `FRAMES`, `PASSED`, `DROPPED`, `MODE_DROPPED`, `POLICE_DROPPED`, `TABLE_HIT[0..5]`, `RULE_HIT[0..3]`, `OVERRUN_DROPPED` |
| 0x100 + 0x20p | `POLICER[p]` | `+0` CTRL bit0 `ENABLE`, `+4` `LIMIT_PKTS`, `+8` `WINDOW_MS`, `+C` `SEEN`, `+10` `PASSED`, `+14` `DROPPED`, `+18` `BUDGET` |
| 0x400 + 0x100t + 0x10e | field entry | `+0` `SRC_VALUE[31:0]`; `+4` [31] `VALID`, [30] `SRC_EN`, [29] `DST_EN`, [28] `BOTH`, [27] `PROTO_EN`, [26] `POLICE_EN`, [25:24] `POLICER`, [23:16] `PROTO`, [15:0] `SRC_VALUE[47:32]`; `+8` `DST_VALUE[31:0]`; `+C` [15:0] `DST_VALUE[47:32]` |
| 0x900 + 0x20e | tuple entry | `+0` [31] `VALID`, [30] `PROTO_EN`, [29] `POLICE_EN`, [9:8] `POLICER`, [7:0] `PROTO`; `+4` `SRC_IP`; `+8` `SRC_MASK`; `+C` `DST_IP`; `+10` `DST_MASK`; `+14` {`SPORT_HI`, `SPORT_LO`}; `+18` {`DPORT_HI`, `DPORT_LO`} |
| 0xC00 + `RULE_STRIDE` r + 4b | rule byte | [7:0] `COMPARE`, [11:8] `OP`, [31:24] `MASK`; `RULE_STRIDE` = max(0x100, 4 x MATCH_DEPTH_BYTES rounded up to a power of two) |

### 10.6 Driver API (`driver/rtlnet_classifier.h`)

Every function takes the context filled by `rtlnet_classifier_init` as its first argument (one context per instance,
so the CPU-path and a main-ingress instance can coexist) and returns `RTLNET_CLS_OK` (0) or a negative
`RTLNET_CLS_ERR_ARG / _ID / _TIMEOUT / _RANGE / _NOT_INIT`. Boot sequence of the firmware network manager:

```c
static rtlnet_classifier_t g_cls;
rtlnet_classifier_init(&g_cls, base + 0x8000u);          /* probe ID, VERSION, CAPS, LATENCY; wait CLEARING */
rtlnet_classifier_config_bcast_storm(&g_cls, 10u, 100u);  /* broadcast storm limiter, MODE = PASS_ALL */
```

| Function | Use (CLI) |
|---|---|
| `init`, `get_status`, `set_mode`, `get_mode`, `clear_all` | `classifier mode ...`, `show classifier` |
| `table_mode`, `get_table_mode`, `table_entry_set/get`, `tuple_set/get` | `classifier table ...`, `classifier acl ...` |
| `rule_mode`, `get_rule_mode`, `rule_byte`, `rule_pattern` (whole rule as one data/mask pattern, other bytes don't-care) | `classifier rule ...` |
| `policer_set`, `policer_get` (configuration, counters, budget) | `classifier policer ...`, `show storm-control` |
| `counters`, `clear_counters` | `show classifier` |
| `mac_filter` (single), `ethertype_filter` (range pair), `ipv4_filter` (data/mask pair), `port_filter` (range pair, protocol 0 = any), `acl_add` | helpers; `action` = `RTLNET_CLS_ACT_GATE` or `RTLNET_CLS_ACT_CLASSIFY`, optionally ORed with `RTLNET_CLS_ACT_POLICE(p)` |
| `config_bcast_storm(ctx, limit_pkts, window_ms)` | `storm-control broadcast <packets> <milliseconds>` |
| `bcast_storm_enable(ctx, on)` | `storm-control broadcast enable/disable` |

Every set function follows the update protocol (table or rule disabled while its words change, then restored).
The helpers set the table's `COMPARE` mode (single for MAC, range for EtherType and port, data/mask for IPv4) and
keep its `EXCLUDE` and `VLAN_AWARE` bits; the pair helpers take a pair index (entries 2i, 2i+1).

### 10.7 Verification record (10-22-2026)

| Run | Configuration | Result |
|---|---|---|
| `tb_rtlnet_classifier` | defaults, AMD (XPM / SRLC32E models) | PASS, 17474 checks (67 s) |
| `tb_rtlnet_classifier` generic | defaults, `RTLNET_TECH_GENERIC` | PASS, 17474 checks (60 s) |
| `tb_rtlnet_classifier` m128 | `MATCH_DEPTH_BYTES` 128, `TABLE_LANES` 4, GENERIC | PASS, 17742 checks (75 s) |
| `tb_rtlnet_classifier` m40 | `MATCH_DEPTH_BYTES` 40, entries 8/4, 4 rules, 2 policers, GENERIC | PASS, 13973 checks (59 s) |
| `tb_rtlnet_classifier` neg | `+INJECT_FAILURE` | TEST FAIL as required |
| driver host test | `driver/test/build_test.ps1` | PASS, 571 checks; `--inject-failure` reports TEST FAIL; `mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c` clean |

What the bench proves (each against the independent reference model, with hand-written expectations cross-checked
against the model in the directed phases): power-up drop-all (30 frames, none out); each `MODE`; the broadcast storm
configuration (10 per 100 ms, 3 per 20 ms, 0 per 10 ms; three windows each; exactly `LIMIT` broadcasts pass per
window while every interleaved unicast passes; disabled limiter passes all); every field table in single, range
and data/mask compare with source / destination / either / both, include, exclude, classify-only, VLAN-aware
offsets, the PORT protocol qualifier, absent and truncated fields, fragments, IHL other than 5; tuple entries (TCP
/24 to host port 22, UDP and out-of-range rejections, ICMP with any ports, non-IPv4); every rule operator at its
boundary (compare value one below, equal, one above) with a mask; absent bytes against compare and don't-care
operators, 1-, 13- and 14-byte frames; the rule-combination rule over all 16 include/exclude/classify/disabled
pairs; policer priority (rules, tuple, MAC .. IP, lowest entry) and a disabled policer; every beat leaving exactly
`DELAY_BEATS + 2` clocks after entry for frames of 60 to 1518 bytes including `MATCH_DEPTH_BYTES - 8 .. + 8`; 200
back-to-back 60-byte frames with `s_axis_tready` never low and 1600 output beats at the exact latency; alternating
pass/drop at full rate; overrun of back-to-back 20-byte frames; `CLEAR_TABLES` and readback of every word class; the
update protocol; 10000 random frames under 20 random configurations (tagged/untagged, IPv4 TCP/UDP/ICMP/other,
fragments, options, truncation, random gaps in the source, a random sink) with every counter and identity checked
after each configuration; `STALL_SEEN`. RTL simulation assertions: verdict present at the end of the line, verdict
queue overflow, line shifting a refused beat, ingress ready invariant, rule and table results aligned with the
token stages.

Proof that the checks can fail (each run must report TEST FAIL; all did): `+PERTURB=1` expected latency + 1;
`+PERTURB=2` range upper bound exclusive in the model; `+PERTURB=3` storm limit + 1 in the model; `+PERTURB=4` model
`<` as `<=`; `+PERTURB=5` model ignores VLAN awareness; `+PERTURB=6` model `FRAMES` + 1 per frame; RTL perturbation
(scratch copy of the top) `DELAY_BEATS` = `MATCH_DEPTH_BYTES / 8 + VERDICT_LATENCY - 3`: stopped by the elaboration
`$fatal`; with that check also removed, the late-verdict assertion fires and the bench reports TEST FAIL (`rtlnet_classifier_line: frame reached the end of the delay line before its
verdict`).

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1 -Match classifier`.

### 10.8 Synthesis, implementation and the 6a timing gate

`testbench/rtlnet_classifier_timing.tcl` (run through `scripts/rtlnet_vivado.ps1`): out-of-context synthesis and
implementation of `rtlnet_classifier`, `axis_clk` at the gate period, `s_axi_aclk` 10 ns, the register crossing bound
by `scripts/rtlnet_constrain_cdc.tcl` (classes `sync`, `axil_cdc`); gates on zero failing setup and hold endpoints
(queried with `get_timing_paths`) and on the LUT levels (LUT1..6 and MUXF7/8 counted, carry not) of the worst path
to every `axis_clk` endpoint; writes the vendor `report_design_analysis -logic_level_distribution` as well.

Results (Vivado 2025.2, final RTL, default parameters, `RAM_STYLE` "block"):

| Gate | Part | `axis_clk` | WNS / WHS | Failing setup / hold | LUT levels, classifier logic | Result |
|---|---|---|---|---|---|---|
| 10G structure (6a) | xc7a200tsbg484-1 | 156.25 MHz (6.400 ns) | +1.515 ns / +0.059 ns | 0 / 0 | max 2 (6532 endpoints 0, 5697 at 1, 391 at 2) | PASS |
| CPU path | xc7a200tsbg484-1 | 100 MHz (10.000 ns) | +3.310 ns / +0.047 ns | 0 / 0 | max 2 | PASS |
| 25G structure (6a) | Spartan UltraScale+ at 390.625 MHz | not run | | | | not run: no UltraScale+ device data is installed (`get_parts xcsu*` and every other UltraScale family return nothing; only Artix-7 is installed) |
| stress proxy | xc7a200tsbg484-3 | 250 MHz (4.000 ns) | +0.694 ns / +0.068 ns | 0 / 0 | max 2 | PASS; the worst path is one LUT and 2.83 ns of routing (`u_extract/fl_vlan` selecting the snapshot, high fanout) |

12906 `axis_clk` endpoints analysed per run. Paths entirely inside the shared `rtlnet_common` modules
`rtlnet_axil_cdc` / `rtlnet_axil_slave` (the AXI4-Lite master FSM of the crossing, 6 endpoints) have 3 LUT levels; they
are reported and not gated (section 10.9). The vendor `report_design_analysis -logic_level_distribution` counts carry
cells as levels (32-bit counters show up to 9: one LUT and eight CARRY4) and is kept next to the census
(`<tag>_levels.rpt`).

Utilization after implementation, xc7a200tsbg484-1, defaults: 3351 slice LUTs (3228 logic, 123 SRL: the 73-bit,
31-slot delay line as SRLC32E plus control), 6217 flip-flops, 30 block RAM tiles (58 RAMB18 + 1 RAMB36: two lanes of
per-word entry memories for five field tables and the tuple table, eight lanes per rule, the 4 KiB readback mirror),
4 MUXF7, 0 DSP. `scripts/rtlnet_synth_check.tcl`: PASS, 0 critical warnings.

### 10.9 Open issues

* 390.625 MHz UltraScale+ gate not run: no UltraScale+ part is installed. The structure is at most two LUT levels
  per stage; on Artix-7 -3 it closes at 250 MHz with the critical path dominated by routing of high-fanout
  selects (VLAN-aware field select, snapshot load enable, `shift_q`). A 390 MHz build will likely need those nets
  replicated (phys_opt does part of it) and should be run as soon as a device is installed.
* `rtlnet_axil_cdc` (shared, `rtlnet_common`, outside this core): its master-side FSM has 3 LUT levels in
  `axis_clk` (6 endpoints). It meets 156.25 MHz and 250 MHz with margin; meeting the letter of 6a needs a change in
  `rtlnet_common` (register the request-toggle compare).
* Sub-minimum frames (under 57 bytes) arriving back-to-back are dropped as overruns (10.3); legal Ethernet frames are
  never affected.
* The bench shares one Active-HDL seat; the full regression (5 runs) takes about 5 minutes.

## 11. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Design specification (value/mask window rules) |
| 10-22-2026 | Restructured as field tables + positional rule engines + combiner (single/range, per-byte operator ALU, include/exclude, verdict FIFO) |
| 10-22-2026 | EtherType table, data/mask compare, tuple (ACL) table, classify-only, policers, global MODE with power-up DROP_ALL; first instance on the CPU path; driver API with the broadcast storm limiter as the first default configuration |
| 10-22-2026 | Shift-register delay line of `MATCH_DEPTH_BYTES` (default 64) with verdict-gated valid at its output, in place of a store-and-forward FIFO |
| 10-22-2026 | Binding timing structure for 10G/25G line rates: two LUT levels per stage, pipelined compares and reductions, derived verdict latency |
| 10-22-2026 | As built: RTL, driver, bench and timing gate; section 10 records the as-built latencies, register-map additions (`LATENCY`, `OVERRUN_DROPPED`, `BUDGET`), deviations, verification and timing results |
