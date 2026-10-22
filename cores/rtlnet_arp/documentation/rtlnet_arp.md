# rtlnet_arp — ARP responder leaf

| Item | Value |
|---|---|
| Core | `rtlnet_arp` |
| Document revision | 10-22-2026 |
| Language | SystemVerilog-2012 |
| Standards | RFC 826 (ARP), RFC 894 (Ethernet II framing) |
| Contract | `documentation/rtlnet_architecture.md` sections 7.5, 7.6, 15.4 |
| Verification | Active-HDL 11.1: `tb_rtlnet_arp` (AMD and GENERIC), driver host test |

The ARP leaf answers an ARP request for the node's own IPv4 address with a 42-byte unicast ARP reply and
ignores every other frame. It keeps no translation table. It is leaf index 2 of `rtlnet_eth_protocol`
(arbiter priority 3 of 5, register window `0x1000`), which supplies `proto_clk`, the destination-MAC
filter, one frame at a time and the transmit arbitration.

## 1. Interface

Ports are exactly the leaf contract of architecture 15.4; the ARP leaf has no leaf-specific ports.

| Group | Ports | Notes |
|---|---|---|
| clock, reset | `clk`, `resetn` | `proto_clk`; synchronous, active low |
| enable | `enable` | wrapper `CTRL.LEAF_ENABLE` bit 2; sampled at a frame's first beat |
| frame in | `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`, `s_axis_tready` | RTLNet stream; `s_axis_tready` is a flop that is 1 from the first clock on |
| frame out | `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`, `m_axis_tready` | outputs of one `rtlnet_axis_reg_slice` (`u_tx_slice`); a started reply has no gaps |
| address | `local_mac[47:0]`, `local_ip[31:0]` | wrapper `proto_clk` registers; MAC octet 0 in `[47:40]`, IP first octet in `[31:24]` |
| status | `busy` | registered, see section 3.4 |
| claim | `claim` | registered one-clock pulse for every request this leaf answers, see section 3.4 |
| registers | `reg_wr_en`, `reg_wr_addr[11:0]`, `reg_wr_data[31:0]`, `reg_rd_en`, `reg_rd_addr[11:0]`, `reg_rd_data[31:0]` | read data registered, valid the clock after `reg_rd_en` |

| Parameter | Default | Meaning |
|---|---|---|
| `REPLY_DELAY_CYCLES` | 1250 | `clk` cycles from the decision to the first reply beat (`$fatal` if negative). The wrapper passes `PROTO_CLK_HZ / 40000` = 25 us, 1250 at 50 MHz |

## 2. Register map

Offsets inside the leaf window (protocol sub-map `0x1000`). Defined in `driver/rtlnet_arp.h`, mirrored by
localparams in `hdl/rtlnet_arp.sv`.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | `0x41525031` | "ARP1" |
| 0x004 | `VERSION` | RO | `0x10222026` | register-map date code |
| 0x008 | `CAPS` | RO | `REPLY_DELAY_CYCLES` | the reply delay in `proto_clk` cycles |
| 0x00C | `CTRL` | W | 0 | bit 0 `CNT_CLEAR`: self-clearing pulse, clears the three counters; reads 0 |
| 0x010 | `STATUS` | RO | 1 | bit 0 `ENABLED` (the `enable` input), bit 1 `BUSY` |
| 0x020 | `REQUESTS_FOR_US` | RO | 0 | valid requests for the local IP that were taken (frame started enabled and idle) |
| 0x024 | `REPLIES_SENT` | RO | 0 | replies whose last beat was handed to the output slice |
| 0x028 | `IGNORED` | RO | 0 | ARP frames (EtherType 0x0806) that were not answered: a rule failed, not for us, truncated, or the frame started while busy or disabled |

Counters are 32 bit and wrap. Once idle, `REQUESTS_FOR_US = REPLIES_SENT`. Undefined offsets read 0 and
ignore writes.

## 3. Design

### 3.1 Accept rules (RFC 826 "Packet Reception")

A frame is answered when all hold; otherwise it is dropped silently:

| Rule | Bytes | Value |
|---|---|---|
| EtherType | 12-13 | 0x0806 |
| `ar$hrd` | 14-15 | 0x0001 (Ethernet) |
| `ar$pro` | 16-17 | 0x0800 (IPv4) |
| `ar$hln`, `ar$pln` | 18, 19 | 6, 4 (optional in the RFC, checked strictly) |
| `ar$op` | 20-21 | 1 (request) |
| `ar$tpa` | 38-41 | `local_ip` |
| length | | bytes 40-41 present in `tkeep` (a request is 42 bytes; anything after is padding) |
| one at a time | | the frame's first beat found the leaf enabled, idle, and not deciding |

Not checked: the Ethernet destination (the wrapper's filter does it), `ar$sha`/`ar$spa` (a gratuitous
or probe request for the local address is answered like any other), `ar$tha`.

### 3.2 State machines

Receive machine `rx_state` — one state per beat: `S_RX_B0` (bytes 0-7; decides `frame_taken`),
`S_RX_B1` (EtherType, `ar$hrd`), `S_RX_B2` (`ar$pro`, `ar$hln`, `ar$pln`, `ar$op`, `ar$sha` high),
`S_RX_B3` (`ar$sha` low, `ar$spa`), `S_RX_B4` (`ar$tpa` high), `S_RX_B5` (`ar$tpa` low, the verdict),
`S_RX_TAIL` (padding to `tlast`). A last beat anywhere returns to `S_RX_B0`. The check fields are
captured for every frame; the reply fields (`ar$sha`, `ar$spa`) only for a taken frame, so a frame that
arrives during a reply never disturbs it. At the last beat of a taken, valid request `rx_frame_end`
pulses (the decision).

Transmit machine `tx_state` — `S_TX_IDLE` (on the decision: latch `local_mac`/`local_ip` once into
`reply_mac`/`reply_ip`, load the delay, raise `busy`), `S_TX_DELAY` (`REPLY_DELAY_CYCLES + 1` clocks),
`S_TX_B0..S_TX_B5` (one reply beat each, advanced when the slice takes it; `busy` falls when B5 is taken).
Both machines have a `default` branch that returns to idle.

### 3.3 Reply

The RFC 826 swap, 42 bytes, no padding (the MAC pads to 60):

| Beat | Bytes | Content |
|---|---|---|
| B0 | 0-7 | destination = request `ar$sha`; source MAC octets 0-1 |
| B1 | 8-15 | source MAC octets 2-5; EtherType 0x0806; `ar$hrd` 1 |
| B2 | 16-23 | `ar$pro` 0x0800, `ar$hln` 6, `ar$pln` 4, `ar$op` 2, `ar$sha` octets 0-1 = local MAC |
| B3 | 24-31 | `ar$sha` octets 2-5; `ar$spa` = local IP |
| B4 | 32-39 | `ar$tha` = request `ar$sha`; `ar$tpa` octets 0-1 = request `ar$spa` |
| B5 | 40-41 | `ar$tpa` octets 2-3; `tkeep` 0x03, `tlast` |

### 3.4 Busy and latency

`busy` rises two clocks after the request's last beat (decision registered, then `busy`), well inside
the 12-clock rule, and stays high through the delay and the reply until the last beat is handed to the
slice. Frames that are not answered never raise `busy`. The reply's first beat leaves the slice
`REPLY_DELAY_CYCLES + 4` clocks after the clock in which the request's last beat is accepted (measured
by the bench). One request at a time: a frame that starts while a reply is pending is ignored whole and
counted in `IGNORED` if it is ARP.

`claim` (architecture 7.5) pulses for one clock in the clock after the last beat of every request the leaf
answers (a taken frame, enabled and idle at its first beat, every RFC 826 check passed, `ar$tpa = local_ip`),
one clock before `busy` rises; it is gated by `enable` in that clock, so a disabled leaf never claims. Ignored ARP
frames, requests for another address and frames that started while busy are not claimed, so the wrapper copies
them to the CPU network path.

### 3.5 Clocks and resets

One clock, `proto_clk`. The address inputs are `proto_clk` registers of the wrapper; there is no
crossing in this core.

## 4. Verification

`testbench/tb_rtlnet_arp.sv`, filelist `testbench/tb_rtlnet_arp.f`, regression `testbench/regression.txt`.
Four `tb_rtlnet_arp_unit` harnesses run in parallel with `REPLY_DELAY_CYCLES` 0, 5, 40 and 1250 (the last
a short suite). Each has its own 50 MHz clock, `rtlnet_tb_axis_src`, `rtlnet_tb_axis_sink` (stream rules
at the output), `rtlnet_tb_leaf_busy_monitor`, and a local check that `busy` rises at most 12 clocks after
an input frame's last beat.

| Case | What it proves |
|---|---|
| register map | ID, VERSION, CAPS = delay, CTRL, STATUS, undefined offset 0, RO write ignored, counters 0 |
| lengths | requests of 42, 43, 46, 48, 60, 64, 100, 1500 bytes, zero and 0xA5 padding, answered byte-exact against a bench-built reply |
| latency | 42- and 60-byte requests: first reply beat exactly `delay + 4` clocks after the last request beat |
| gappy input | random idle cycles inside requests |
| back-pressure | random 50 % and 12 % ready, then a held stall: the reply waits with `busy` high and completes intact |
| one at a time | a request chained right behind another, one sent while the reply is pending, a 400-byte request starting right behind a short one: all ignored, the first reply intact (their sender fields differ), counted `IGNORED` |
| accept rules | each wrong in turn (EtherType, `ar$hrd` twice, `ar$pro`, `ar$hln`, `ar$pln`, `ar$op` 2/0/byte-swapped, `ar$tpa` four positions, another host's IP, truncated to 1/8/16/24/32/40/41 bytes) with a good request chained behind it (0 or 1 idle clock): no reply for the wrong one, the good one answered; a 41-byte request is rejected by `tkeep` alone (local IP low byte 0); 0xFF padding answered |
| enable | disabled: a valid request ignored and counted; re-enabled: answered |
| address change | new MAC and IP used in the reply; the old IP no longer answered |
| random | 150 mutated frames (field bit flips, sender/target and Ethernet address changes, truncations, lengths up to 300) with random stalls and gaps, each judged by the bench model `arp_classify` |
| counters | `REQUESTS_FOR_US`, `REPLIES_SENT`, `IGNORED` equal the model's counts at three points; `CNT_CLEAR` zeroes them |
| claim | `rtlnet_tb_leaf_claim_monitor` (`cores/rtlnet_eth_protocol/testbench`) on every harness: never X, at most one pulse per frame, after the last beat, before `busy` falls (or within 12 clocks), never while disabled; every `send_and_judge` frame gives exactly one claim when the model answers it and none otherwise; the cumulative claim count equals the answered requests at every counter check (chained, pending and wrong-rule frames included) |

Results, 10-22-2026: `TEST PASS: tb_rtlnet_arp checks=2830` (AMD), the same with `RTLNET_TECH_GENERIC`;
`+INJECT_FAILURE` reports `TEST FAIL`. Claim sensitivity: with `claim` pulsed at every frame end (the answer
condition removed) the bench reports `TEST FAIL` (212 failing checks). Bench sensitivity proven by mutation: with the `ar$hln` check removed
from the RTL the bench reports `TEST FAIL` (26 failing checks: the wrong-rule case and random frames).

Driver: `testbench/host_test_rtlnet_arp.c` (mocked register window) `HOST TEST PASS checks=7`; the driver
compiles warning-free with host `gcc -std=c11 -Wall -Wextra -Werror` and
`mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c`.

## 5. Synthesis

Vivado 2025.2, out of context, xc7a200tsbg484-1, `scripts/rtlnet_synth_check.tcl`, default parameters:
`rtlnet_synth_check: PASS`, 0 critical warnings. 314 LUT, 547 FF, 0 block RAM, 0 DSP. The remaining
warnings are unused input bits (`s_axis_tkeep[7:2]`, most of `reg_wr_data`).

## 6. Driver

`driver/rtlnet_arp.h`, `driver/rtlnet_arp.c`: `rtlnet_arp_probe`, `rtlnet_arp_get_reply_delay_cycles`,
`rtlnet_arp_get_status`, `rtlnet_arp_read_counters`, `rtlnet_arp_clear_counters`. The base is the protocol
sub-map base plus `RTLNET_PROTO_WIN_ARP` (0x1000). Enable/disable is the wrapper driver's
`rtlnet_eth_protocol_set_leaf_enables`.

## 7. Limitations

- No translation table; the leaf never learns the sender. Untagged Ethernet II only (no VLAN), IPv4 only.
- The reply is 42 bytes; the MAC pads it to the 60-byte minimum.
- A request accepted just before a disable is still answered (the enable is sampled at the first beat).
- Simulator note (Active-HDL 11.1): a size cast whose width is a localparam derived from a parameter,
  `DELAY_W'(REPLY_DELAY_CYCLES)`, loaded 0 inside `always_ff` (observed for 40 and 1250); the RTL uses a
  typed localparam `logic [DELAY_W-1:0] DELAY_LOAD = REPLY_DELAY_CYCLES` instead.

## 8. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version |
| 10-22-2026 | `claim` output (architecture 7.5, CPU network path); claim checks in the bench |
