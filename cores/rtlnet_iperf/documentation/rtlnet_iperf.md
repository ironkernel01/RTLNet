# rtlnet_iperf — iperf 2 UDP server leaf

| Item | Value |
|---|---|
| Core | `rtlnet_iperf` (protocol leaf 4 of `rtlnet_eth_protocol`) |
| Document revision | 10-22-2026 |
| Register map revision | `VERSION` = `0x10222026` |
| Language | SystemVerilog-2012 (RTL, bench), C11 (driver) |
| Protocol | iperf 2.2.x UDP test (server side), RFC 3550 6.4.1 jitter, RFC 791, RFC 768, RFC 1071 |
| Verification | `tb_rtlnet_iperf` (Active-HDL 11.1, AMD and GENERIC), host driver test |

A PC running the stock iperf 2 client measures the board without a TCP stack:

- `iperf -c <board> -u ...` — the leaf counts the datagrams (bytes, loss, out-of-order, jitter, computed the way
  the iperf 2 server computes them) and answers the client's end-of-test datagram (FIN) with the 128-byte server
  report, sent to the client's source port.
- `iperf -c <board> -u -R ...` — the leaf streams datagrams to the client's source port for the requested time
  at the requested rate and ends the stream with one datagram carrying the negated sequence number.

## 1. Files

| File | Content |
|---|---|
| `hdl/rtlnet_iperf.sv` | the leaf |
| `hdl/rtlnet_iperf_div.sv` | 64/32-bit sequential divider used by the leaf (mean jitter, pacing rate) |
| `hdl/rtlnet_iperf.f` | the leaf's own sources (compile after `rtlnet_common.f`) |
| `hdl/rtlnet_iperf_synth.f` | `rtlnet_common.f` + the leaf, for the out-of-context synthesis check |
| `driver/rtlnet_iperf.h`, `.c` | register map (the one definition) and driver |
| `testbench/tb_rtlnet_iperf.sv`, `.f` | self-checking bench (the bench is the iperf client) |
| `testbench/test_rtlnet_iperf_driver.c` | host unit test of the driver |
| `testbench/regression.txt` | regression entries (AMD, GENERIC, `+INJECT_FAILURE`) |

## 2. Interface

The port list is the leaf contract of `documentation/rtlnet_architecture.md` 7.5 and 15.4 (no leaf-specific ports).

| Group | Ports | Rule |
|---|---|---|
| clock, reset | `clk`, `resetn` | `proto_clk` (`CLK_HZ`), synchronous, active low |
| enable | `enable` | 0: frames ignored, nothing sent, a pending report dropped, a running stream stopped without its final datagram |
| frame in | `s_axis_*` | RTLNet stream; `s_axis_tready` constant 1 |
| frame out | `m_axis_*` | registered outputs of one `rtlnet_axis_reg_slice`; no gap inside a frame |
| address | `local_mac[47:0]`, `local_ip[31:0]` | destination match and source of every frame sent (one reading per frame) |
| status | `busy` | registered: high from the clock after a last beat until that frame's accounting is done (10 clocks for a data datagram, about 140 for a FIN or a `-R` request, which use the divider) |
| claim | `claim` | registered one-clock pulse for every datagram the classify step accounts (section 6.2), three clocks after its last beat |
| registers | `reg_wr_en`, `reg_wr_addr[11:0]`, `reg_wr_data`, `reg_rd_en`, `reg_rd_addr[11:0]`, `reg_rd_data` | read data valid the clock after `reg_rd_en` and held |

## 3. Parameters

| Parameter | Default | Rule |
|---|---|---|
| `CLK_HZ` | 50 000 000 | `proto_clk` in hertz, at least 2 MHz, below 262.144 MHz (CAPS field); the microsecond time base is exact on average for any value (fraction accumulator) |
| `UDP_PORT` | 5001 | reset value of the `UDP_PORT` register |
| `MAX_DGRAM_BYTES` | 1472 | largest reverse-stream payload, 16 .. 9000 |
| `IDLE_TIMEOUT_MS` | 3000 | a receive flow silent this long is closed without a report |
| `BYTE_MODE_MS` | 10 000 | reverse-stream duration when the client asks for a byte count (`-n`) |

## 4. Register map

Offsets and bits are defined once, in `driver/rtlnet_iperf.h`; the RTL mirrors them.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | `0x49505246` | "IPRF" |
| 0x004 | `VERSION` | RO | `0x10222026` | |
| 0x008 | `CAPS` | RO | build | `[13:0]` `MAX_DGRAM_BYTES`, `[31:14]` `CLK_HZ / 1000` |
| 0x00C | `CTRL` | RW | 1 | `[0]` REVERSE_ALLOWED (level), `[16]` CNT_CLEAR (pulse, reads 0). Every write also writes REVERSE_ALLOWED |
| 0x010 | `STATUS` | RO | `0x00010000` | `[0]` rx_active (a receive flow is open), `[1]` tx_active (a reverse stream runs), `[16]` `enable` |
| 0x014 | `UDP_PORT` | RW | `UDP_PORT` | `[15:0]` server port (receive match, source port of every frame sent) |
| 0x018 | `RX_DATAGRAMS` | RO | 0 | datagrams of the current/last flow, FIN included |
| 0x01C | `RX_BYTES_LO` | RO | 0 | UDP payload bytes `[31:0]`; a read latches `[63:32]` |
| 0x020 | `RX_BYTES_HI` | RO | 0 | `[63:32]` latched by the last `RX_BYTES_LO` read |
| 0x024 | `RX_LOST` | RO | 0 | `max(sum of gaps - out of order, 0)`, as the report's `error_cnt` |
| 0x028 | `RX_OUTOFORDER` | RO | 0 | late and duplicate datagrams |
| 0x02C | `TX_DATAGRAMS` | RO | 0 | data datagrams of the current/last reverse stream (final datagram not counted) |
| 0x030 | `JITTER_US16` | RO | 0 | current RFC 3550 estimator J of the flow, microseconds x 16 |
| 0x034 | `REQ_RATE_BPS` | RO | 0 | rate field (`lRate`) of the last client header that opened a flow or a stream |
| 0x038 | `LAST_DURATION_US` | RO | 0 | first datagram to FIN of the last finished flow |
| 0x03C | `REPORTS_SENT` | RO | 0 | server reports sent, resends included |

The `RX_*` values restart at 0 when a flow opens, `TX_DATAGRAMS` when a stream starts; CNT_CLEAR clears all
statistics registers without touching the flow (the report is computed from separate flow state).

## 5. Wire format (iperf 2.2.x)

Every UDP datagram starts with `{id, tv_sec, tv_usec, id2}` (16 bytes, big-endian). The client test header follows
from payload offset 16 and is read only when the UDP length says it is complete (>= 88): `flags` @16, `mBufLen`
@28, `mAmount` @36 (negative: time in 10 ms units), `upperflags` @48, `lRate` @64. The sequence number is the
signed 64-bit `{id2, id}` when the flow's first datagram has SEQNO64B (`0x08000000`), else the signed 32-bit `id`.
A negative sequence is the FIN; its magnitude is the next sequence number.

Server report (170-byte frame, 128-byte payload, to the client MAC/IP/source port from the leaf's MAC/IP/port, TTL
64, flags 0, IP identification from the leaf's counter, UDP checksum 0):

| Payload offset | Frame byte | Field | Value |
|---:|---:|---|---|
| 0 | 42 | datagram header | 16 zero bytes |
| 16 | 58 | `flags` | `0x88000000` (HEADER_VERSION1, HEADER_SEQNO64B) |
| 20 | 62 | `total_len1` | bytes `[63:32]` |
| 24 | 66 | `total_len2` | bytes `[31:0]` |
| 28 | 70 | `stop_sec` | duration, seconds |
| 32 | 74 | `stop_usec` | duration, microseconds |
| 36 | 78 | `error_cnt` | `max(Lost - OutofOrder, 0)` |
| 40 | 82 | `outorder_cnt` | OutofOrder |
| 44 | 86 | `datagrams` | PacketID (highest sequence, FIN included) |
| 48 | 90 | `jitter1` | mean jitter, whole seconds |
| 52 | 94 | `jitter2` | mean jitter, microseconds |
| 56 | 98 | extensions | zero |

Reverse datagram (42 + L bytes): payload `id` @0, `tv_sec` @4, `tv_usec` @8 (the leaf's own time since reset),
`id2` @12, zero to the end. The final datagram has the same length and the 64-bit two's complement of
`n + 1` (n = data datagrams sent).

## 6. Design

### 6.1 Machines

| Machine | States | Role |
|---|---|---|
| capture | `S_CAP_IDLE`, `S_CAP_RUN`, `S_CAP_SKIP` | fields by beat index (beats 0-13); the last beat stores the frame length and the arrival time (`us32`, `sec`, `usec`) and pulses `rx_done`. A frame that starts while disabled or while the previous frame's accounting runs is skipped whole (simulation prints a warning) |
| accounting | `S_AC_IDLE`, `CLASSIFY`, `OPEN`, `COUNT`, `ORDER`, `TRANSIT`, `DELTA`, `JITTER`, `FIN`, `MEAN`, `SPLIT`, `REPORT`, `RESEND`, `REVERSE`, `RATE` | one step per clock; `MEAN`, `SPLIT` and `RATE` wait for the divider (64 clocks each) |
| reverse | `S_RV_IDLE`, `S_RV_RUN` | stream duration in 10 ms units |
| transmit | `S_TX_IDLE`, `S_TX_CSUM`, `S_TX_BEAT` | picks a pending report first, then a stream datagram the token bucket allows, then the owed final datagram; checksum by `rtlnet_pkg::ipv4_header_checksum`; one beat per clock while the slice takes them |

### 6.2 Accept rules and flow rules

A datagram counts only with: local MAC, EtherType 0x0800, IHL 5, MF = 0 and offset 0 (DF ignored), UDP, local IP,
destination port = `UDP_PORT`, UDP length >= 24 and inside the frame, frame reaching byte 64. No checksum is
verified (the MAC's FCS covers the frame).

| Situation | Action |
|---|---|
| flow open, same client (IP and UDP port) | count it (data or FIN) |
| flow open, other source | ignored |
| no flow, `-R` request (VERSION2 and REVERSE), REVERSE_ALLOWED | start the stream, unless it already runs to the same client (header repeats ignored); another client restarts it |
| no flow, `-R` request, REVERSE_ALLOWED 0 | ignored (no stream, no flow) |
| no flow, data from the client of the flow just reported, sequence not 1 | ignored (a late datagram behind the FIN opens no flow) |
| no flow, other data | open a flow (counters and estimator from zero) |
| no flow, FIN from the client of the flow just reported | resend the latched report (the client repeats its FIN every 10 ms until it hears one) |
| no flow, any other FIN | ignored |
| open flow silent for `IDLE_TIMEOUT_MS` | closed, no report, statistics kept |

`claim` (architecture 7.5) pulses in the clock after `S_AC_CLASSIFY` takes a datagram to `UDP_PORT`: data or FIN of
the open flow, the first datagram of a new flow, a repeated FIN of the closed flow (report resent), an accepted `-R`
request. It comes three clocks after the last beat while `busy` is high and is gated by `enable`. Datagrams the rules
above ignore (another source while a flow is open, a late datagram behind the FIN, a FIN of no known flow, a `-R`
request while REVERSE_ALLOWED is off or from the client being served) and every non-iperf frame are not claimed, so
the wrapper copies them to the CPU network path.

### 6.3 Accounting (as the iperf 2 server's `Reporter.c`)

Per datagram with sequence magnitude p > 0, `PacketID` starting at 0:

1. `p != PacketID + 1`: `p < PacketID + 1` is out of order (`OutofOrder += 1`, duplicates included), otherwise
   `Lost += p - PacketID - 1`; then `PacketID = max(PacketID, p)`.
2. In-order datagrams only (the FIN included, as the iperf server reports it like any datagram):
   `transit = arrival - sent` (microseconds, `sent = tv_sec * 10^6 + tv_usec`, modulo 2^32); from the second
   in-order datagram `J += (|transit - last transit| - J) / 16` and the new J is added to a running sum;
   `last transit = transit`.
3. FIN: `datagrams = PacketID`, `error_cnt = max(Lost - OutofOrder, 0)`, bytes = sum of UDP payload lengths (FIN
   included), duration = FIN arrival - first arrival, jitter = sum of J samples / number of samples (the iperf
   server reports this mean, not the final estimator), split into seconds and microseconds by the divider.

J is kept in fixed point, microseconds with 16 fraction bits, updated with an arithmetic shift (floor); the bench
shows the mean stays within 0.01 us of the real-valued computation. Arrival times have the leaf's 1 us resolution.

### 6.4 Reverse stream

Length `mBufLen` (1470 when 0) clamped to 16 .. `MAX_DGRAM_BYTES`; duration `|mAmount| x 10 ms` when `mAmount` is
negative, else `BYTE_MODE_MS`; rate `lRate` bit/s of UDP payload by a token bucket in 1/65536 bit units refilled
every microsecond (`lRate * 65536 / 10^6`, one divider pass at the start), capped at two datagrams; the first
datagram goes at once; `lRate` 0 sends as fast as `m_axis_tready` allows. Receive counting and reports continue
during a stream (a report goes out between two datagrams).

### 6.5 Deviations (deliberate)

| Deviation | Detail |
|---|---|
| UDP only | no TCP test |
| no `-r`/`-d` | tradeoff and dual tests (VERSION1 without VERSION2) are treated as plain receive flows |
| no enhanced report | the `-e` transit extension fields are zero |
| 32-bit counters | sequence magnitudes, Lost, OutofOrder, datagrams are 32 bit (report fields are 32 bit too) |
| byte mode | `-n` runs `BYTE_MODE_MS`; the byte count is not honoured |
| rate | the upper rate word (rates >= 2^32 bit/s) is ignored |
| time base | arrival and stream timestamps are the leaf's microseconds since reset |

## 7. Clocks, resets, crossings

One clock, one synchronous reset; no crossings.

## 8. Verification

`tb_rtlnet_iperf` is the iperf client: it drives the leaf like the wrapper (one frame at a time, >= 16 idle clocks,
never while busy) with the iperf 2.2.x client header values (flags `0x480100A0` / `0xEC0100A0`, upperflags
`0x0400`, rate 10 Mbit). Every datagram of an accounting flow is placed so its last beat falls on a
whole-microsecond clock, so arrival times are known exactly. Two references written from the iperf server
algorithm (not from the RTL): a fixed-point model compared exactly (report, registers, `JITTER_US16`) and a
real-valued model the mean jitter must match within 0.01 us. Expected reports are built byte by byte and the IPv4
header is judged by the independent RFC 1071 oracle.

| Case | Proves |
|---|---|
| registers | ID, VERSION, CAPS, CTRL reset 1, UDP_PORT reset 5001 and 16-bit write, CNT_CLEAR reads 0, read-only writes, 48 undefined offsets read 0, read latency exactly 1 |
| plain flows | 40 x 1470 and 25 x 100 bytes with arrival jitter: report byte-exact, every register, busy low 16 clocks after every data datagram |
| loss / reorder | the literal 50 % case (even ids of 1..100, FIN 101: 50 lost of 101), reorder (0 lost, 2 out of order), duplicates clamped at 0, duplicate against a loss, a lost last datagram, 300 datagrams with random drops, swaps and duplicates |
| jitter | 200 datagrams with 0..40 us random delay, the sender's `tv_usec` wrapping into the next second, a 500 us step |
| FIN rules | FIN retry resends the identical report; a late datagram behind the FIN opens nothing; a second retry still gets the report; an unknown FIN is ignored; 32-bit sequence flow (no client header) with its 32-bit FIN; another source ignored while a flow is open |
| ignored traffic | other MAC, other IP, other port, broadcast MAC, TCP, MF, fragment offset, UDP length < 24, UDP length past the frame, IHL 6, EtherType ARP, leaf disabled, a real ARP request; 88-byte datagrams accepted |
| idle timeout | open just before 3 ms, closed after, counters kept, late FIN ignored, new flow from zero |
| reverse | 100 B at 8 Mbit/s: 100-101 datagrams in 10 ms, spacing exactly 100 us; byte mode with `mBufLen` 0 (1470) under 60 % ready; 9000 clamped to 1472 under 4 % ready; 5 clamped to 16 at 4 Mbit/s (625 datagrams in 20 ms) with a header repeat ignored and a receive flow whose report goes out between datagrams; a second client restarts the stream (no final datagram for the first); every datagram checked (Ethernet, IPv4 with checksum, UDP, id sequence, timestamps, zero payload) and the final `-(n + 1)` datagram exactly once and last; REVERSE_ALLOWED off; disable stops the stream with no final datagram |
| port / clear | UDP_PORT 6001: old port ignored, report from 6001; a frame starting 8 clocks after a FIN is skipped whole; CNT_CLEAR of every statistic, also in the middle of a flow without disturbing its report |
| DUT B | 33.333333 MHz (fractional time base), `MAX_DGRAM_BYTES` 100: 20 ms flow duration exact to 1 us; `mBufLen` 1470 clamped to 100, 100-101 datagrams at 8 Mbit/s |
| run-wide | `rtlnet_tb_leaf_busy_monitor` on both DUTs, sink stream rules, IP identification of every frame |
| claim | `rtlnet_tb_leaf_claim_monitor` on both DUTs (timing, one per frame, never while disabled); every `run_flow` claims each datagram and its FIN; FIN retry 1, late datagram 0, FIN retry after it 1, unknown FIN 0, the 32-bit flow 13, another source while a flow is open 0 (the open flow's datagram 1, its FIN 1), each ignored-traffic case 0, a real ARP request 0, the 88-byte pair 2, an accepted `-R` request 1, a `-R` request with REVERSE_ALLOWED off 0 |

Results (10-22-2026, Active-HDL 11.1):

| Run | Result |
|---|---|
| `tb_rtlnet_iperf` (AMD) | PASS, 40 514 checks |
| `tb_rtlnet_iperf` `RTLNET_TECH_GENERIC` | PASS, 40 514 checks |
| `tb_rtlnet_iperf` `+INJECT_FAILURE` | TEST FAIL as required |
| mutation runs (RTL perturbed in a scratch copy) | all 6 detected: duplicates not out of order; jitter updated on out-of-order datagrams; report datagrams = count instead of PacketID; no final datagram; busy never raised; error_cnt without the out-of-order subtraction |
| claim mutation | claim for every datagram to the port (`classify_take` replaced by `is_iperf`): 4 failing checks (first "late datagram after the FIN") |
| `test_rtlnet_iperf_driver` (host gcc 16.2) | PASS, 48 checks |
| `mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c` | clean |

## 9. Synthesis

Out of context, Vivado 2025.2, `xc7a200tsbg484-1`, default parameters, 10-22-2026: PASS, 0 critical warnings.

| Resource | Used |
|---|---:|
| Slice LUTs | 2661 |
| Slice registers | 3694 |
| Block RAM | 0 |
| DSP | 2 (`tv_sec * 10^6`) |

Remaining warnings: unused upper `reg_wr_data` bits and the constant `s_axis_tready`.

## 10. Limitations

- One receive flow and one reverse stream at a time.
- No hardware test yet (simulation only).

## 11. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version |
| 10-22-2026 | `claim` output (architecture 7.5, CPU network path); claim checks in the bench |
