# rtlnet_classifier — frame filter / classifier (design specification)

| Item | Value |
|---|---|
| Core | `rtlnet_classifier` |
| Status | **Designed, not built.** This document is the specification the RTL will be written against. |
| Document revision | 10-22-2026 |
| Clock | `axis_clk` (the MAC client clock: 62.5 MHz on the Nexys Video, 156.25 / 390.625 MHz on 10G / 25G) |
| Registers | AXI4-Lite, `s_axi_aclk`, 4 KiB window at RTLNet offset 0x2_0000 (internal `rtlnet_axil_cdc`) |
| Placement | between `rtlnet_eth_mac.m_axis_rx` and `rtlnet_eth_protocol.s_axis` (ingress), optionally a second instance before `rtlnet_eth_mac.s_axis_tx` (egress) |

## 1. Purpose and structure

Decide, for every frame, whether it passes or is dropped, at line rate and without modifying it, and count what
matched. The core is organised as **three engines that judge the same frame in parallel and a combiner**:

```
                     +--> field extractor --> TABLE ENGINE (MAC / VLAN / IP / PORT tables) --> table_pass --+
s_axis --> accept ---+                                                                                      +--> COMBINER --> verdict FIFO --+
                     +--> 64-byte window ---> RULE ENGINES 0..NUM_RULES-1 (positional byte ALU) --> rule_pass +                               |
                     |                                                                                                                       v
                     +--> data FIFO (store-and-forward, DATA_FIFO_KB) -----------------------------------------------------> release FSM --> slice --> m_axis
```

| Engine | Judges | Configured by |
|---|---|---|
| Table engine | header fields against value tables: MAC, VLAN, IPv4 address, L4 port; single values or ranges; source, destination, either or both | four tables of `TABLE_ENTRIES` entries plus one mode register per table |
| Rule engines (`NUM_RULES`, default 2) | the first 64 bytes by position: per byte a bit mask, an operator and a compare byte | one 64-entry compare buffer plus one mode register per rule |
| Combiner | `verdict = table_pass AND rule_pass`, then block-all and bypass | the global control register |

Every engine has an enable and an include/exclude sense, so the same hardware expresses "admit only these" and
"drop these".

## 2. Interface

| Group | Ports |
|---|---|
| clocks, resets | `axis_clk`, `axis_resetn`, `s_axi_aclk`, `s_axi_aresetn` |
| frames in (axis_clk) | `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`, out `s_axis_tready` (a flop) |
| frames out (axis_clk) | `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`, in `m_axis_tready` (output of an `rtlnet_axis_reg_slice`) |
| registers | `s_axi_*`, `ADDR_W` 12 |
| events (axis_clk) | `ev_pass`, `ev_drop` (one pulse per verdict) |

| Parameter | Default | Meaning |
|---|---|---|
| `TABLE_ENTRIES` | 16 | entries per table (MAC, VLAN, IP, PORT) |
| `TABLE_LANES` | 2 | entries compared per clock per table (scan time = `TABLE_ENTRIES / TABLE_LANES` clocks; section 4.3) |
| `NUM_RULES` | 2 | positional rule engines |
| `TABLE_MODE` | `"RAM"` | `"RAM"` (programmable) or `"ROM"` (built-in defaults, no write path) |
| `DATA_FIFO_KB` | 4 | data FIFO size (store-and-forward) |
| `RAM_STYLE` | `"block"` | tables, compare buffers and FIFO |

## 3. Field extractor

Captures, as the beats arrive, the fields the table engine compares (byte offsets of an untagged frame; with VLAN
processing enabled for a table and EtherType 0x8100 at bytes 12..13, the L3/L4 offsets move by 4):

| Field | Bytes (untagged) | Width |
|---|---|---|
| destination MAC, source MAC | 0..5, 6..11 | 48, 48 |
| VLAN TPID + TCI | 12..15 (valid when 12..13 = 0x8100) | VID 12 bits (+ PCP 3) |
| EtherType | 12..13 (16..17 tagged) | 16 |
| source / destination IPv4 | 26..29 / 30..33 | 32, 32 |
| IP protocol | 23 | 8 |
| source / destination port (TCP/UDP) | 34..35 / 36..37 | 16, 16 |

The extractor also flags `is_vlan`, `is_ipv4` (EtherType 0x0800, IHL 5) and `has_l4` (protocol 6 or 17, not a
fragment), so an IP or port table never matches a frame that does not carry that field. Fields of a frame shorter
than the field read as absent (no match), never as zero.

## 4. Table engine

### 4.1 Tables and entries

Four tables (index 0 MAC, 1 VLAN, 2 IP, 3 PORT), each with `TABLE_ENTRIES` entries in its own `rtlnet_ram_core`.
An entry holds:

| Field | Bits | Meaning |
|---|---|---|
| `SRC_VALUE` | 48 | value compared with the frame's source field (MAC 48, VLAN VID 12, IP 32, port 16, zero-extended) |
| `DST_VALUE` | 48 | value compared with the frame's destination field (unused by VLAN) |
| `SRC_EN`, `DST_EN` | 1, 1 | compare the source field / the destination field |
| `BOTH` | 1 | with both enabled: 1 = source AND destination must match, 0 = either matches |
| `VALID` | 1 | entry in use |

### 4.2 Table mode register (one per table)

| Bit | Name | Meaning |
|---|---|---|
| 0 | `ENABLE` | 0: the table always passes |
| 1 | `EXCLUDE` | 0: pass frames that match an entry (include); 1: pass frames that match no entry (exclude) |
| 2 | `RANGE` | 0: each entry is a single value; 1: entries are pairs (2k = low bound, 2k+1 = high bound), a field matches when `low <= field <= high` |
| 7 | `VLAN_AWARE` | shift the L3/L4 field offsets by 4 on tagged frames |

`table_pass = AND over the four tables of (ENABLE ? (EXCLUDE ? !hit : hit) : 1)`.

### 4.3 Scan

Each table is scanned from entry 0 to `TABLE_ENTRIES - 1`, `TABLE_LANES` entries per clock, all four tables in
parallel, starting as soon as the table's field is captured (MAC after beat 1, VLAN after beat 1, IP after beat 4,
port after beat 4). Single mode compares `==`; range mode compares `>=` and `<=` on the pair in the same clock
(no second pass). With the defaults (16 entries, 2 lanes) a table finishes 8 clocks after its field is captured,
so the table verdict is ready about 13 clocks after a frame's first beat; a minimum frame at 1 Gb/s on the 62.5 MHz
client clock lasts 42 clocks, so the engine sustains line rate with margin. 10G/25G builds raise `TABLE_LANES`
(16 lanes = one clock per table) — the check `scan clocks + capture beat < minimum frame clocks` is an elaboration
`$fatal` given the configured clock and line rate.

## 5. Rule engines

### 5.1 Compare buffer (one per rule, 64 entries, one per frame byte 0..63)

| Bits | Field | Meaning |
|---|---|---|
| 7:0 | `COMPARE` | compare byte |
| 11:8 | `OP` | `1000` `==`, `1001` `!=`, `1010` `<`, `1011` `>`, `1100` `<=`, `1101` `>=`, anything else: don't care (byte always passes) |
| 31:24 | `MASK` | bit mask applied to the frame byte before the compare (`(frame_byte & MASK) OP COMPARE`) |

A rule matches when every one of its 64 bytes passes. Bytes the frame does not carry compare as absent: a
don't-care byte passes, any other operator fails, so a short frame cannot match by being short.

### 5.2 Rule mode register (one per rule)

| Bit | Name | Meaning |
|---|---|---|
| 0 | `ENABLE` | rule takes part |
| 1 | `EXCLUDE` | 0: rule passes frames that match; 1: rule passes frames that do not match |

### 5.3 Datapath

Eight byte ALUs per rule work on one 64-bit beat per clock (one `rtlnet_ram_core` word per beat holds the eight
entries of that beat), so the 64-byte window is judged in 8 beats with the verdict two clocks after beat 7 (or
after the frame's last beat when shorter).

### 5.4 Rule combination

`rule_pass` follows the reference behaviour, generalised to `NUM_RULES`:

| Enabled rules | `rule_pass` |
|---|---|
| none | 1 |
| any mix with at least one include rule | OR of the enabled rules' results |
| all enabled rules in exclude mode | AND of their results (a frame passes only if it matches none of them) |

## 6. Combiner, actions, release

`verdict = table_pass AND rule_pass`, then: `CTRL.BLOCK_ALL` forces drop; `CTRL.BYPASS` forces pass (counters still
run). The verdict (pass/drop + which table/rule matched) enters a verdict FIFO in frame order; the release FSM
(`S_IDLE`, `S_PASS`, `S_DROP`) streams or discards each frame from the store-and-forward data FIFO, taking the next
verdict on a last beat so back-to-back frames cost no idle clock. This replaces a fixed delay line: the frame waits
exactly as long as its verdict takes, and a slow verdict can never release an unjudged frame. `s_axis_tready` drops
only when the data FIFO cannot hold one more maximum header window plus the verdict latency.

## 7. Registers (offsets in the 4 KiB window)

| Offset | Name | Access | Content |
|---:|---|---|---|
| 0x000 | `ID` | RO | `"CLSF"` |
| 0x004 | `VERSION` | RO | register-map date code |
| 0x008 | `CAPS` | RO | `TABLE_ENTRIES`, `TABLE_LANES`, `NUM_RULES`, ROM flag |
| 0x00C | `CTRL` | RW | bit0 `BYPASS`, bit1 `BLOCK_ALL`, bit8 `RELOAD` (RAM mode: reload defaults), bit16 `CNT_CLEAR` |
| 0x010 | `STATUS` | RO | `LOADING`, FIFO levels |
| 0x020..0x02C | `TABLE_MODE[t]` | RW | section 4.2, t = 0 MAC, 1 VLAN, 2 IP, 3 PORT |
| 0x030 + 4r | `RULE_MODE[r]` | RW | section 5.2 |
| 0x080..0x0BC | counters | RO | `FRAMES`, `PASSED`, `DROPPED`, `TABLE_HIT[t]`, `RULE_HIT[r]`, `BLOCKED` |
| 0x400 + 0x100t + 0x10e | `TABLE[t].ENTRY[e]` | RW | `+0` SRC_VALUE[31:0], `+4` {flags, SRC_VALUE[47:32]}, `+8` DST_VALUE[31:0], `+C` DST_VALUE[47:32] |
| 0x800 + 0x100r + 4b | `RULE[r].BYTE[b]` | RW | section 5.1 |

Counters count in `axis_clk` and reach the register clock through `rtlnet_gray_sync`. Table and rule memories are
written through the CDC'd register bus into `rtlnet_ram_core` port A and read by the engines on port B; an update of
an entry in use takes effect from the next frame that reads it — the driver disables a table or rule, rewrites it and
re-enables it, so no frame is judged against a half-written entry.

## 8. Defaults (ROM mode, or RAM reload)

| Engine | Default |
|---|---|
| MAC table | include, entries: local MAC (destination), broadcast (destination) |
| VLAN table | disabled |
| IP table | disabled (firmware programs allowed subnets) |
| PORT table | disabled (firmware programs allowed port ranges, e.g. 5000..5100) |
| Rule 0 | disabled (example: EtherType byte 12 `== 0x08`, byte 13 `== 0x06` admits ARP) |
| Rule 1 | disabled |
| `CTRL` | BYPASS = 1 until firmware programs the filter |

## 9. Verification plan

| Bench | Proves |
|---|---|
| `tb_rtlnet_classifier` | every table in single and range mode, source/destination/either/both, include/exclude, VLAN-aware offsets on tagged and untagged frames; every rule operator at its boundaries with masks; short frames never match on absent bytes; the rule-combination table of 5.4; block-all and bypass; back-to-back minimum frames at full rate with a random sink; entry update protocol; RAM reload; ROM mode ignores writes; counters; 10 000 random frames and random configurations against a bench reference model |
| in-system | MAC + classifier + protocol wrapper: admitted traffic answered, excluded traffic dropped and counted |

Gates: synthesis at 62.5 MHz (Artix-7) and an out-of-context check at 156.25 MHz with `TABLE_LANES` 16; zero failing
setup/hold.

## 10. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Design specification (value/mask window rules) |
| 10-22-2026 | Restructured as table engine + positional rule engines + combiner, with single/range field tables, per-byte operator ALU, include/exclude per table and rule, verdict FIFO in place of a delay line |
