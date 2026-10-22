# rtlnet_dhcp — DHCP client leaf

| Item | Value |
|---|---|
| Core | `rtlnet_dhcp` (protocol leaf 3 of `rtlnet_eth_protocol`) |
| Document revision | 10-22-2026 |
| Register map revision | `VERSION` = `0x10222026` |
| Language | SystemVerilog-2012 (RTL, bench), C11 (driver) |
| Standards | RFC 2131, RFC 2132, RFC 791, RFC 768, RFC 1071, RFC 894 |
| Verification | `tb_rtlnet_dhcp` (Active-HDL 11.1, AMD and GENERIC), host driver test |

The leaf obtains an IPv4 lease with DISCOVER / OFFER / REQUEST / ACK, holds it, renews it at T1, drops it when
it expires, when the server refuses the renewal or when firmware stops it, and releases it to the server with a
DHCPRELEASE on STOP. Firmware drives it only through registers; the lease leaves on registered level outputs
that the protocol wrapper turns into the node's effective address.

## 1. Files

| File | Content |
|---|---|
| `hdl/rtlnet_dhcp.sv` | the leaf |
| `hdl/rtlnet_dhcp.f` | the leaf's own sources (compile after `rtlnet_common.f`) |
| `hdl/rtlnet_dhcp_synth.f` | `rtlnet_common.f` + the leaf, for the out-of-context synthesis check |
| `driver/rtlnet_dhcp.h`, `.c` | register map (the one definition) and driver |
| `testbench/tb_rtlnet_dhcp.sv`, `.f` | self-checking bench (the bench is the DHCP server) |
| `testbench/test_rtlnet_dhcp_driver.c` | host unit test of the driver against a register model |
| `testbench/regression.txt` | regression entries (AMD, GENERIC, `+INJECT_FAILURE`) |

## 2. Interface

The port list is the leaf contract of `documentation/rtlnet_architecture.md` sections 7.5 and 15.4.

| Group | Ports | Rule |
|---|---|---|
| clock, reset | `clk`, `resetn` | `proto_clk`, synchronous, active low |
| enable | `enable` | 0: every frame is ignored and nothing is sent (a pending frame request is dropped); timers and register commands keep running |
| frame in | `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`, `s_axis_tready` | RTLNet stream; `s_axis_tready` is constant 1 |
| frame out | `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`, `m_axis_tready` | registered outputs of one `rtlnet_axis_reg_slice`; 342-byte frames without gaps |
| address | `local_mac[47:0]`, `local_ip[31:0]` | MAC octet 0 in `[47:40]`; `local_ip` is not used (the frames carry 0.0.0.0 or the leaf's own `lease_ip`, which is the effective address while `lease_valid`) |
| status | `busy` | registered: high while a captured frame is received or parsed, and for the clock after the last beat of every frame |
| claim | `claim` | registered one-clock pulse for every BOOTP reply the client machine accepts (section 5.2), in the clock `busy` falls |
| registers | `reg_wr_en`, `reg_wr_addr[11:0]`, `reg_wr_data[31:0]`, `reg_rd_en`, `reg_rd_addr[11:0]`, `reg_rd_data[31:0]` | read data valid the clock after `reg_rd_en` and held until the next read |
| lease | `lease_valid`, `lease_ip[31:0]`, `lease_mask[31:0]`, `lease_router[31:0]`, `lease_server[31:0]`, `lease_time_s[31:0]` | registered; first octet in `[31:24]`; load on a binding ACK, clear to 0 on a lease loss, change at no other time; 0 while `lease_valid` is 0 |

## 3. Parameters

| Parameter | Default | Rule |
|---|---|---|
| `MS_CYCLES` | 50 000 | `proto_clk` cycles per millisecond, at least 8 |
| `DHCP_BUF_KB` | 1 | receive RAM in KiB: 1, 2, 4, 8 or 16 (`DHCP_BUF_KB * 128` words of 64 bits). 1 KiB holds the 590-byte RFC 2131 maximum message (576-byte datagram) |
| `RAM_STYLE` | `"block"` | `"block"` or `"distributed"`, passed to `rtlnet_ram_core` |
| `OFFER_TIMEOUT_MS` | 4000 | first retransmission wait (RFC 2131 4.1), 1 .. `RETRY_CAP_MS` |
| `RETRY_CAP_MS` | 64 000 | backoff ceiling (RFC 2131 4.1), at most 65 535 |
| `MAX_TRIES` | 5 | sends per phase, and NAKs per acquisition, before `S_FAIL`; 1 .. 15 |
| `RENEW_RETRY_S` | 60 | seconds between renewing REQUESTs; 1 .. 65 535 |
| `LEASE_MIN_S` | 10 | shortest lease accepted; a shorter one is raised to it (at least 2, so T1 >= 1 s) |

Illegal values stop elaboration with `$fatal` in a generate block (synthesis and simulation). The wrapper passes
`MS_CYCLES`, `DHCP_BUF_KB` and `RAM_STYLE`; the others keep their defaults. With the defaults a missing server
gives DISCOVERs at 0, 4, 12, 28 and 60 s and `S_FAIL` at 124 s.

## 4. Register map

Offsets and bits are defined once, in `driver/rtlnet_dhcp.h`; the RTL mirrors them.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | `0x44484350` | "DHCP" |
| 0x004 | `VERSION` | RO | `0x10222026` | register map date code |
| 0x008 | `CAPS` | RO | build | `[7:0]` `DHCP_BUF_KB`, `[11:8]` `MAX_TRIES`, `[16]` 1 = DHCPRELEASE on STOP |
| 0x00C | `CTRL` | RW | 0 | `[0]` START pulse, `[1]` STOP pulse, `[2]` AUTO level, `[3]` RENEW_NOW pulse, `[16]` CNT_CLEAR pulse. Pulse bits read 0. Every write also writes AUTO |
| 0x010 | `STATUS` | RO | `0x00010000` | `[2:0]` state (0 INIT, 1 SELECTING, 2 REQUESTING, 3 BOUND, 4 RENEWING, 5 FAIL), `[8]` bound (= `lease_valid`), `[9]` fail, `[16]` `enable` |
| 0x014 | `LEASE_IP` | RO | 0 | `lease_ip` |
| 0x018 | `LEASE_MASK` | RO | 0 | option 1 (0 when the ACK had none) |
| 0x01C | `LEASE_ROUTER` | RO | 0 | first address of option 3 (0 when none) |
| 0x020 | `LEASE_SERVER` | RO | 0 | option 54 of the ACK, else the OFFER's |
| 0x024 | `LEASE_TIME_S` | RO | 0 | lease in seconds (option 51, 3600 when missing, raised to `LEASE_MIN_S`; `0xFFFFFFFF` infinite) |
| 0x028 | `LEASE_ELAPSED_S` | RO | 0 | whole seconds since the binding ACK (saturates) |
| 0x02C | `XID` | RO | 0 | transaction id in use |
| 0x030 | `DISCOVERS_SENT` | RO | 0 | DHCPDISCOVER frames sent |
| 0x034 | `OFFERS_RX` | RO | 0 | OFFERs taken (matching xid, option 54, in SELECTING) |
| 0x038 | `REQUESTS_SENT` | RO | 0 | DHCPREQUEST frames sent (selecting and renewing) |
| 0x03C | `ACKS_RX` | RO | 0 | binding ACKs |
| 0x040 | `NAKS_RX` | RO | 0 | NAKs acted on (REQUESTING or RENEWING, matching xid) |
| 0x044 | `LEASES_LOST` | RO | 0 | involuntary lease losses (expiry, NAK while renewing; STOP not counted) |
| 0x048 | `RELEASES_SENT` | RO | 0 | DHCPRELEASE frames sent |

Undefined offsets read 0 and ignore writes. Counters are 32-bit, wrap, and clear on CNT_CLEAR. AUTO is the
firmware's auto-start intent (the leaf has no link input): the link monitor reads it and calls START after link-up.

## 5. Design

### 5.1 Client machine (RFC 2131 4.4, Figure 5)

One registered state (`STATUS[2:0]`). Priority in every clock: reset, STOP, a restart, a binding ACK, the state's
own rule. A lease loss is applied in parallel. Each timer is cleared in the assignment that makes its transition.

| State | Behaviour |
|---|---|
| `S_INIT` | after reset and after STOP; waits for START |
| `S_SELECTING` | DISCOVER sent; takes the first OFFER with option 54 and the current xid and answers with the selecting REQUEST (options 50, 54) |
| `S_REQUESTING` | REQUEST sent; waits for ACK or NAK |
| `S_BOUND` | lease held; at T1 = lease/2 (or RENEW_NOW) takes a new xid, sends the renewing REQUEST, goes `S_RENEWING` |
| `S_RENEWING` | renewing REQUEST resent every `RENEW_RETRY_S` with the same xid until ACK, NAK or expiry |
| `S_FAIL` | `MAX_TRIES` sends without an answer, or the `MAX_TRIES`-th NAK of one acquisition; waits for START |

| Event | Effect |
|---|---|
| START (any state) | new xid (free-running counter XOR `local_mac[31:0]`), DISCOVER, `S_SELECTING`; a held lease stays valid |
| STOP (any state) | lease released (DHCPRELEASE when one was held), outputs cleared, `S_INIT` |
| timeout in SELECTING / REQUESTING | resend with the same xid; wait doubles from `OFFER_TIMEOUT_MS` up to `RETRY_CAP_MS`; after `MAX_TRIES` sends `S_FAIL` |
| ACK in REQUESTING or RENEWING | lease outputs load on one edge, `lease_valid` 1, elapsed time restarts, `S_BOUND` |
| NAK in REQUESTING | restart (new xid, DISCOVER); the `MAX_TRIES`-th gives `S_FAIL`; no lease loss |
| NAK in RENEWING | lease loss, restart |
| expiry in RENEWING | lease loss, restart |
| expiry in any other state (after a START or in FAIL) | lease loss, state unchanged |
| infinite lease (`0xFFFFFFFF`) | no T1, no expiry |

### 5.2 Receive machine

`S_RX_IDLE` takes the first beat of a frame only while the client expects a reply (SELECTING, REQUESTING,
RENEWING) and the leaf is enabled; `S_RX_HDR` checks each header beat as it passes (beat 1 EtherType and
version/IHL, beat 2 fragment and protocol, beat 4 ports, beat 5 op, beats 8-9 `chaddr`, beats 34-35 cookie) and
captures source MAC, IP total length, xid, `yiaddr`; every captured beat is written to the receive RAM one clock
behind the bus; `S_RX_TAIL` takes the rest of the frame while it fits; `S_RX_END` (the last word is being
written) judges the length; `S_OPT_CODE`, `S_OPT_LEN`, `S_OPT_DATA` walk the options; `S_RX_DONE` hands the result
to the client machine. A frame boundary tracker skips the rest of a rejected frame, and a frame that starts while
the machine is not idle is ignored whole (simulation prints a warning).

Accept rules (all, otherwise the frame has no effect): Ethernet destination local MAC or broadcast, EtherType
0x0800, byte 14 = 0x45, MF = 0 and offset = 0 (DF ignored), protocol 17, UDP 67 to 68, BOOTP op 2, `chaddr` = local
MAC, cookie 99.130.83.99 at bytes 278-281, frame not longer than the RAM, IP total length inside the frame, an end
option inside the IP datagram, no option running past it, option 53 present, and at the end of the walk the
current xid. Not checked: IP destination, `siaddr`, `giaddr`, IP and UDP checksums (the MAC's FCS covers the frame).

Option walk: from byte 282, one byte per two clocks (the RAM read latency), bounded by the last byte of the IP
datagram (`14 + total length - 1`), so Ethernet padding and the bytes an earlier, longer frame left in the RAM are
never read. 0 pad, 255 end, else code, length, data. Taken: 53 (first data byte, length >= 1), 54, 51, 1, 3 (first
four data bytes, length >= 4; a router list gives its first address). Every other option, and a wanted one that is
too short, is skipped by its length; a repeated option replaces the earlier one. A 590-byte message parses in
about 650 clocks; `busy` covers it.

`claim` (architecture 7.5): the clock after the verdict, which is the clock `busy` falls, for a parsed reply with the
current xid and `chaddr` that the client machine accepts in its state: an OFFER with option 54 while SELECTING, an ACK
while REQUESTING or RENEWING, a NAK while REQUESTING or RENEWING (exactly the frames `OFFERS_RX`, `ACKS_RX` and
`NAKS_RX` count). Gated by `enable`. Every ignored frame (wrong xid, an ACK while SELECTING, an OFFER while
REQUESTING, any rule of the accept list failed) is not claimed, so the wrapper copies it to the CPU network path.

### 5.3 Transmit machine

`S_TX_IDLE` takes a pending request and copies its descriptor (`local_mac`, xid and the client's `req_*` fields,
one reading per frame); `S_TX_CSUM` computes the IPv4 header checksum with `rtlnet_pkg::ipv4_header_checksum`;
`S_TX_BEAT` loads one of 43 beats whenever the slice input is empty or being taken. One pending flag: two requests
before pickup give one frame of the later kind.

Frame (342 bytes = 14 Ethernet + 20 IPv4 + 8 UDP + 300 BOOTP; `tkeep` 0x3F on beat 42):

| Bytes | Field | DISCOVER | selecting REQUEST | renewing REQUEST | RELEASE |
|---|---|---|---|---|---|
| 0-5 | Ethernet destination | broadcast | broadcast | broadcast | server MAC (source of the binding ACK) |
| 6-13 | source, EtherType | local MAC, 0x0800 | same | same | same |
| 14-25 | IPv4 0x45, ToS 0, length 328, ident (+1 per frame), flags 0, TTL 64, UDP, checksum | | | | |
| 26-29 | IP source | 0.0.0.0 | 0.0.0.0 | lease | lease |
| 30-33 | IP destination | 255.255.255.255 | same | same | server |
| 34-41 | UDP 68 -> 67, length 308, checksum 0 | | | | |
| 42-45 | op 1, htype 1, hlen 6, hops 0 | | | | |
| 46-49 | xid | new per acquisition | the acquisition's | new per renewal | new |
| 50-53 | secs 0, flags | 0x8000 | 0x8000 | 0 | 0 |
| 54-57 | `ciaddr` | 0 | 0 | lease | lease |
| 58-69 | `yiaddr`, `siaddr`, `giaddr` | 0 | 0 | 0 | 0 |
| 70-75, 76-277 | `chaddr` = local MAC, zeros | | | | |
| 278-281 | cookie 63 82 53 63 | | | | |
| 282-284 | option 53 | 1 | 3 | 3 | 7 |
| 285-293 | option 61: 7, 1, MAC | | | | |
| 294-299 | option 55: 4, 1, 3, 6, 51 | yes | yes | yes | six pad bytes |
| 300-305 | option 50: 4, offered address | pads | yes | pads | pads |
| 306-311 | option 54: 4, server | pads | yes | pads | yes |
| 312 | end (255); 313-341 zero | | | | |

### 5.4 Timers

A free-running prescaler gives a millisecond tick; a millisecond-of-second counter restarted by the binding ACK
gives the second tick, so T1 and expiry fall on whole seconds from the ACK.

### 5.5 Deviations from RFC 2131 (deliberate)

| Deviation | Detail |
|---|---|
| `S_FAIL` | not in Figure 5 (the RFC client retries forever); firmware restarts with START (AUTO intent) |
| no INIT-REBOOT / REBOOTING | every START is a full DISCOVER (3.2, 4.4.2) |
| no REBINDING, no T2 | the renewal is the broadcast form (`ciaddr` set, no options 50/54) from T1 until expiry; expiry while renewing restarts with DISCOVER (4.4.5) |
| T1 = lease/2 | options 58 and 59 are not read |
| renewal retry | every `RENEW_RETRY_S`, not half the remaining time (4.4.5) |
| retransmission | start 4 s, doubled, cap 64 s, but not randomised by +-1 s (4.1) |
| no DECLINE, no ARP probe | the first OFFER with a server identifier is taken (3.1, 4.4.1) |
| `secs` field | always 0 |
| short lease | raised to `LEASE_MIN_S` (protects the network from a lease-0 exchange loop) |
| missing option 51 | 3600 s |
| options read | 53, 54, 51, 1, 3; 6 requested only; option 52 (overload) not handled |
| timing origin | T1 and expiry from the ACK, not from the REQUEST (4.4.1) |
| receive checks | no IP destination, checksum or `giaddr` check |
| renewal xid | a new xid per renewal |

## 6. Clocks, resets, crossings

One clock (`proto_clk`), one synchronous reset; the receive RAM content is not reset. No crossings: the
wrapper's address, register bus and lease consumers are all in `proto_clk`.

## 7. Verification

`tb_rtlnet_dhcp` drives the leaf like the wrapper (one frame at a time, >= 16 idle clocks, never while busy) and is
the DHCP server. `MS_CYCLES` 20 (1 s = 20 000 clocks at 50 MHz), `OFFER_TIMEOUT_MS` 200, `RETRY_CAP_MS` 800,
`RENEW_RETRY_S` 2, `LEASE_MIN_S` 4. Expected client frames are built byte by byte in the bench and their IPv4
header is judged by the independent RFC 1071 oracle of `rtlnet_tb_pkg`. Server frames carry a realistic
home-router option set (53, 54, 51, 58, 59, 1, 28, 3, 6 with two servers, 15, and 12 in the ACK).

| Case | Proves |
|---|---|
| registers | ID, VERSION, CAPS, CTRL AUTO level, pulse bits read 0, undefined offsets 0, read-only writes ignored, read data exactly one clock after `reg_rd_en` and held; DUT C (default parameters) CAPS |
| acquisition | DISCOVER and REQUEST byte-exact, one lease-output change on the ACK, registers and counters, `LEASE_ELAPSED_S`; START while bound keeps the lease; unicast server frames; an OFFER without end option ignored and the DISCOVER retransmitted with the same xid |
| retransmission | DISCOVER and REQUEST spacing 1x, 2x, 4x (cap), cap, byte-exact, same xid, exactly `MAX_TRIES` sends, then FAIL and silence; START after FAIL takes a new xid |
| NAK | wrong-xid NAK ignored; each NAK restarts with a new xid; the `MAX_TRIES`-th gives FAIL; `NAKS_RX`; no lease loss |
| ignored frames (29) | wrong xid high/low, `chaddr` first/last octet, UDP source/destination port, op 1, cookie byte 278/281, MF, fragment offset, IHL 6, TCP, EtherType ARP/IPv6, other unicast MAC, ACK while selecting, OFFER without 54, no option 53, no end option, option past the datagram, IP length past the frame, frame longer than the RAM (1100 bytes), leaf disabled, a real ARP frame, an ICMP echo frame, stale end option behind a cut frame, a frame overlapping a busy parse, a frame cut before the cookie; each followed by a good OFFER that is answered |
| options | pad runs at all 8 beat alignments, reordered options, unknown 40-byte option, zero-length option, two routers, repeated options (later wins), too-short option 51, missing 1/3/51/54, option 53 of length 2, end option on the last datagram byte, lease 2 s raised to `LEASE_MIN_S` |
| renewal | T1 at 6 s of a 13 s lease, renewing REQUEST byte-exact with a new xid, retries every 2 s with the same xid, expiry at 13 s: `lease_valid` falls once, outputs 0, DISCOVER; renew ACK with new mask/router/lease reloads; second T1 at 10 s; NAK while renewing drops the lease; RENEW_NOW; START while bound, then no server: lease runs out in FAIL with exactly one fall and no frame |
| STOP | DHCPRELEASE byte-exact (unicast to the ACK's source MAC and the server IP), outputs cleared, `RELEASES_SENT`; STOP without lease sends nothing; ACK in INIT ignored; infinite lease silent for 12 s |
| stalls | `m_axis_tready` 30 %, 3 % and 50 % on REQUEST, renewal, RELEASE, DISCOVER; CNT_CLEAR of all seven counters |
| DUT B | `DHCP_BUF_KB` 2, distributed RAM: binds from an 1100-byte OFFER/ACK that DUT A ignores |
| run-wide | `rtlnet_tb_leaf_busy_monitor`, sink stream rules, lease outputs change only on a binding ACK or a lease loss and are 0 without a lease, DUT C silent |
| claim | `rtlnet_tb_leaf_claim_monitor` (`cores/rtlnet_eth_protocol/testbench`) on DUT A and B: never X, one pulse per frame at most, after the last beat and no later than the clock `busy` falls, never while disabled; each of the 29 ignored frames gives no claim and the proof OFFER behind it exactly one; at every quiesce and before CNT_CLEAR the claims since the last CNT_CLEAR equal `OFFERS_RX + ACKS_RX + NAKS_RX`; DUT B claims its OFFER and ACK (2); DUT C never claims |

Results (10-22-2026, Active-HDL 11.1):

| Run | Result |
|---|---|
| `tb_rtlnet_dhcp` (AMD XPM RAM) | PASS, 1198 checks |
| `tb_rtlnet_dhcp` `RTLNET_TECH_GENERIC` | PASS, 1198 checks |
| `tb_rtlnet_dhcp` `+INJECT_FAILURE` | TEST FAIL as required |
| mutation runs (RTL perturbed in a scratch copy, bench unchanged) | all 6 detected: DISCOVER flags 0; cookie byte 281 unchecked; NAK while renewing keeps the lease; xid not compared; backoff not doubled; busy never raised |
| claim mutations | claim on every parsed message for the xid (the state condition removed): 29 failing checks (first "ACK while selecting"); claim one clock late (after `busy` fell): 10 failing checks (the claim monitor's timing rule) |
| `test_rtlnet_dhcp_driver` (host gcc 16.2) | PASS, 74 checks |
| `mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c` | clean |

## 8. Synthesis

Out of context, Vivado 2025.2, `xc7a200tsbg484-1`, default parameters (`scripts/rtlnet_synth_check.tcl` with
`hdl/rtlnet_dhcp_synth.f`), 10-22-2026: PASS, 0 critical warnings.

| Resource | Used |
|---|---:|
| Slice LUTs | 1287 |
| Slice registers | 1804 |
| Block RAM | 1 RAMB36 |
| DSP | 0 |

The remaining warnings are the expected ones: `local_ip` and unused register-bus bits have no load, and
`s_axis_tready` is constant.

## 9. Limitations

- One DHCP server exchange at a time; the first OFFER wins.
- The frames carry no host name, vendor class or parameter beyond 1, 3, 6, 51.
- No hardware test yet (simulation only).

## 10. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version |
| 10-22-2026 | `claim` output (architecture 7.5, CPU network path); claim checks in the bench |
