# rtlnet_icmp — ICMP echo responder leaf

| Item | Value |
|---|---|
| Core | `rtlnet_icmp` |
| Document revision | 10-22-2026 |
| Language | SystemVerilog-2012 |
| Standards | RFC 792 (echo), RFC 791 (IPv4 header), RFC 1071 (checksum), RFC 894 (Ethernet II, padding) |
| Contract | `documentation/rtlnet_architecture.md` sections 7.5, 7.6, 15.4 |
| Verification | Active-HDL 11.1: `tb_rtlnet_icmp` (AMD and GENERIC), driver host test |

The ICMP leaf answers an echo request (ping) addressed to the node's IPv4 address with an echo reply:
addresses swapped, type 0, both checksums correct, the data returned byte for byte. It stores the
request's message in a payload RAM while it arrives and replays it. It is leaf index 1 of
`rtlnet_eth_protocol` (arbiter priority 2 of 5, register window `0x2000`).

## 1. Interface

Ports are exactly the leaf contract of architecture 15.4; no leaf-specific ports.

| Group | Ports | Notes |
|---|---|---|
| clock, reset | `clk`, `resetn` | `proto_clk`; synchronous, active low |
| enable | `enable` | wrapper `CTRL.LEAF_ENABLE` bit 1; sampled at a frame's first beat |
| frame in | `s_axis_t*` | RTLNet stream; `s_axis_tready` is a flop that is 1 from the first clock on |
| frame out | `m_axis_t*` | outputs of one `rtlnet_axis_reg_slice` (`u_tx_slice`); no gaps inside a reply |
| address | `local_mac[47:0]`, `local_ip[31:0]` | wrapper `proto_clk` registers; one reading per frame |
| status | `busy` | registered, section 3.4 |
| registers | `reg_wr_en`, `reg_wr_addr[11:0]`, `reg_wr_data`, `reg_rd_en`, `reg_rd_addr[11:0]`, `reg_rd_data` | read data valid the clock after `reg_rd_en` |

| Parameter | Default | Meaning |
|---|---|---|
| `ICMP_BUF_KB` | 2 | payload RAM in kilobytes, a power of two (`$fatal` otherwise). RAM words = `ICMP_BUF_KB * 128` (64 bit) |
| `RAM_STYLE` | `"block"` | `rtlnet_ram_core` style, `"block"` or `"distributed"` |

Derived: `MAX_PAYLOAD_BYTES = min(1472, ICMP_BUF_KB * 1024 - 2)` (the RAM holds frame bytes 40 on: the
sequence number and the data). `ICMP_BUF_KB = 2` gives 1472, the payload of a 1500-byte IP datagram;
`ICMP_BUF_KB = 1` gives 1022.

## 2. Register map

Offsets inside the leaf window (protocol sub-map `0x2000`). Defined in `driver/rtlnet_icmp.h`, mirrored
by localparams in `hdl/rtlnet_icmp.sv`.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | `0x49434D50` | "ICMP" |
| 0x004 | `VERSION` | RO | `0x10222026` | register-map date code |
| 0x008 | `CAPS` | RO | `0x000205C0` (defaults) | `[15:0]` `MAX_PAYLOAD_BYTES`, `[23:16]` `ICMP_BUF_KB` |
| 0x00C | `CTRL` | W | 0 | bit 0 `CNT_CLEAR`: self-clearing pulse, clears the four counters; reads 0 |
| 0x010 | `STATUS` | RO | 1 | bit 0 `ENABLED`, bit 1 `BUSY` |
| 0x020 | `ECHO_REQUESTS` | RO | 0 | echo requests (IPv4, IHL 5, protocol 1, type 8 code 0) to the local IP that were taken |
| 0x024 | `ECHO_REPLIES` | RO | 0 | replies whose last beat was handed to the output slice |
| 0x028 | `DROPPED_CHECKSUM` | RO | 0 | requests whose ICMP checksum is wrong (size correct) |
| 0x02C | `DROPPED_SIZE` | RO | 0 | requests whose Total Length is out of range, or whose frame is shorter than the Total Length or longer than padding explains |

Identity once idle: `ECHO_REQUESTS = ECHO_REPLIES + DROPPED_CHECKSUM + DROPPED_SIZE`. Counters are 32 bit
and wrap; undefined offsets read 0.

## 3. Design

### 3.1 Accept rules

| Rule | Value |
|---|---|
| EtherType | 0x0800 |
| version/IHL | 0x45 (no IP options) |
| protocol | 1 |
| destination IP | `local_ip` (the reading taken at beat 3) |
| type, code | 8, 0 |
| IP Total Length | 28 .. `MAX_PAYLOAD_BYTES + 28` |
| frame length | the frame holds every byte the Total Length promises and is longer only by Ethernet padding: extra bytes in the message's last beat, or a frame of at most 64 bytes |
| ICMP checksum | the RFC 1071 sum of the whole message is 0xFFFF |
| one at a time | the frame's first beat found the leaf enabled and idle |

Not checked: the Ethernet destination (wrapper filter), the request's IP header checksum (documented
deviation from RFC 1122 3.2.1.2: the MAC's FCS covers the frame), the fragment fields (echoed), the TTL
(the reply uses 64).

### 3.2 State machine

One registered state variable `state`:

| State | Bytes | Does |
|---|---|---|
| `S_IDLE` | 0-7 | takes a frame's first beat if enabled and not inside another frame (`in_frame`) |
| `S_RX_B1` | 8-15 | source MAC low, EtherType, version/IHL, ToS |
| `S_RX_B2` | 16-23 | Total Length, Identification, flags/fragment, protocol |
| `S_RX_B3` | 24-31 | source IP, destination IP high; one reading of `local_mac`/`local_ip`; the message's last byte index |
| `S_RX_B4` | 32-39 | destination IP low, type, code, checksum, identifier; the sum starts with the identifier |
| `S_RX_B5` | 40-47 | payload word 0 into the RAM and the sum; a bad header goes to `S_RX_DROP` (an echo request for us with a bad Total Length is counted `DROPPED_SIZE` here) |
| `S_RX_PAYLOAD` | 48.. | payload words into the RAM while inside the message; padding lanes masked out of the sum |
| `S_RX_DROP` | 48.. | drain to `tlast`, nothing sent |
| `S_CHECK` | one clock | judge (header, length, checksum), count, compute both reply checksums |
| `S_TX_B0..S_TX_B4` | reply 0-39 | header beats from the captured fields |
| `S_TX_PAYLOAD` | reply 40.. | RAM words; the last word's `tkeep` from the Total Length |

### 3.3 Payload RAM and checksums

`u_payload_ram` is one `rtlnet_ram_core` (`CLOCKING "COMMON"`, latency 1). It is written one word per
payload beat inside the message and read only in the transmit states, so a word is never read in the
clock it is written. The write is gated by the RAM size as well as by the Total Length bound, so no frame
can write past the buffer; a simulation-only `$fatal` reports any write request past it.

`sum_rest` is the RFC 1071 sum of the message from the identifier on (beat 4 lanes 6-7, then every payload
lane inside the message). The request is good when `fold(sum_rest + checksum + type/code) == 0xFFFF`. The
reply checksum is `~fold(sum_rest)` — the full recompute over the reply (type 0, code 0), so the
all-zero message correctly gives 0xFFFF. The reply IP header checksum is
`rtlnet_pkg::ipv4_header_checksum` over ToS, Total Length, Identification, flags, TTL 64, protocol 1,
source = local IP, destination = the request's source.

### 3.4 Busy and latency

`busy` rises one clock after the last beat of a frame that reaches `S_CHECK` and falls on rejection or when
the reply's last beat is handed to the slice. A header rejected at beat 5 (`S_RX_DROP`) never raises it.
The reply's first beat leaves the slice 3 clocks after the clock in which the request's last beat is
accepted, whatever the size. A frame that starts while the leaf is not idle is ignored whole, including a
valid request in its tail; the stored payload is never overwritten.

### 3.5 Clocks and resets

One clock, `proto_clk`; no crossing in this core.

## 4. Verification

`testbench/tb_rtlnet_icmp.sv`, filelist `testbench/tb_rtlnet_icmp.f`, regression `testbench/regression.txt`.
Two harnesses in parallel: `ICMP_BUF_KB = 2` (full suite) and `ICMP_BUF_KB = 1` (the buffer bound).
Each has its own 50 MHz clock, source, sink (stream rules), `rtlnet_tb_leaf_busy_monitor` and a local
busy-rise check (at most 12 clocks). Requests and expected replies are built by the bench with
`rtlnet_tb_pkg` and its RFC 1071 `inet_checksum`; every received reply is also checked independently
(IP header and ICMP sums fold to 0xFFFF). The model `icmp_classify` decides every frame.

| Case | What it proves |
|---|---|
| register map | ID, VERSION, CAPS, CTRL, STATUS, undefined offset 0, RO write ignored |
| realistic ping | 32 bytes with ToS 0xB8, ID 0xBEEF, DF, TTL 37: byte-exact reply (ToS/ID/flags echoed, TTL 64); latency exactly 3 clocks |
| payload sweep | every payload size 0..1472 byte-exact (1473 replies); 1473 rejected and counted `DROPPED_SIZE` |
| small buffer | `ICMP_BUF_KB = 1`: 0, 1, 64, 1021, 1022 answered; 1023 and 1472 rejected; CAPS = `0x000103FE` |
| padding | payloads 0..18 padded to 60 with 0x00 and 0xA5: reply excludes the padding; padded to 64 answered; 65 bytes rejected; 8 extra bytes after a 100-byte payload rejected |
| truncation | a frame 1, 9 or 342 bytes shorter than its Total Length promises: rejected |
| gappy input, back-pressure | random gaps; random 50 % and 12 % ready; a held stall with `busy` high, then the reply intact |
| one at a time | a request chained behind another, a frame with a valid request in its tail, a request while the reply is pending, a 1000-byte request starting during transmission: all ignored, the first reply intact; a frame chained behind a request with 4..20 junk beats then a valid request, for every alignment with the leaf's return to idle: never answered |
| accept rules | each wrong in turn (EtherType, IHL 6, version 6, protocol 17, each destination-IP byte, type 0, type 13, code 1, Total Length 27 and 20, a data bit with a stale checksum) with a good request chained behind: one reply only |
| enable, address | disabled: ignored and not counted; new MAC/IP used, the old IP not answered |
| random | 160 mutated frames (header bit flips, message bytes, Ethernet addresses, IP header checksum, truncations, extra padding) with random stalls and gaps, judged by the model |
| counters | the four counters equal the model at four points; `CNT_CLEAR` zeroes them |

Results, 10-22-2026: `TEST PASS: tb_rtlnet_icmp checks=10166` (AMD), the same with `RTLNET_TECH_GENERIC`;
`+INJECT_FAILURE` reports `TEST FAIL`. Bench sensitivity proven by mutation: without the in-frame tracking
(`!in_frame` removed from `S_IDLE`) the tail-request case answers at 12 junk beats and the bench reports
`TEST FAIL` (7 failing checks); without the 64-byte padding bound it reports `TEST FAIL` (15 failing checks).

Driver: `testbench/host_test_rtlnet_icmp.c` `HOST TEST PASS checks=8`; the driver compiles warning-free with
host `gcc` and `mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c`.

## 5. Synthesis

Vivado 2025.2, out of context, xc7a200tsbg484-1, default parameters: `rtlnet_synth_check: PASS`,
0 critical warnings. 860 LUT, 771 FF, 1 RAMB36 (the 256 x 64 payload RAM), 0 DSP. The remaining warnings
are unused input bits (`reg_wr_data`).

## 6. Driver

`driver/rtlnet_icmp.h`, `driver/rtlnet_icmp.c`: `rtlnet_icmp_probe`, `rtlnet_icmp_get_max_payload`,
`rtlnet_icmp_get_buf_kb`, `rtlnet_icmp_get_status`, `rtlnet_icmp_read_counters`,
`rtlnet_icmp_clear_counters`. Base = protocol sub-map base + `RTLNET_PROTO_WIN_ICMP` (0x2000).

## 7. Limitations

- IPv4 without options, untagged Ethernet II; no fragment reassembly (a fragmented ping fails the length
  or checksum rule and is dropped).
- The request's IP header checksum is not verified (RFC 1122 3.2.1.2 deviation, see 3.1).
- Bytes after the message inside the message's last 8-byte beat are accepted as padding even when the
  frame is longer than 64 bytes (they are neither summed nor echoed).
- A request accepted just before a disable is still answered.

## 8. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version |
