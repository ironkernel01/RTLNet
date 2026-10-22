# rtlnet_udp_socket — UDP socket layer

| Item | Value |
|---|---|
| Core | `rtlnet_udp_socket` |
| Document revision | 10-22-2026 |
| Language | SystemVerilog-2012 (RTL, benches), C11 (driver) |
| Position | protocol leaf 0 of `rtlnet_eth_protocol` (highest arbiter priority), architecture sections 7.5, 7.7, 15.4 |
| Register map revision | `VERSION` = `0x10222026`, `ID` = `0x55445053` ("UDPS") |
| Verification | Active-HDL 11.1: `tb_rtlnet_udp_socket` (4 configurations + negative control), `tb_rtlnet_udp_echo` (with the echo core); host driver test |
| Synthesis | Vivado 2025.2 out of context, xc7a200tsbg484-1: PASS, 0 critical warnings |

The socket layer gives FPGA applications UDP without a CPU in the data path. `NUM_SOCKETS` sockets are each bound to a
local UDP port. A received datagram for an enabled socket is delivered to the application as two metadata beats and its
payload, realigned to byte 0. The application sends a datagram the same way, and the layer builds the Ethernet, IPv4 and
UDP headers.

Contents: 1 interface, 2 the application stream, 3 registers, 4 design, 5 clocks, resets and crossings, 6 buffers,
latency and resources, 7 verification, 8 application developer's guide, 9 limitations, 10 revision history.

---

## 1. Interface

### 1.1 Ports

The leaf contract ports (architecture 7.5 / 15.4) come first, then the leaf-specific ports.

| Group | Ports | Domain | Rule |
|---|---|---|---|
| clock, reset | `clk`, `resetn` | proto_clk | synchronous, active low |
| enable | `enable` | proto_clk | wrapper leaf-enable; low: frames ignored, application datagrams dropped and counted |
| frame in | `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`; out `s_axis_tready` | proto_clk | `s_axis_tready` is constant 1 |
| frame out | `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`; in `m_axis_tready` | proto_clk | output of one `rtlnet_axis_reg_slice`; a started frame has no gaps |
| address | `local_mac[47:0]`, `local_ip[31:0]` | proto_clk | MAC octet 0 in `[47:40]`, IP first octet in `[31:24]` |
| status | `busy` | proto_clk | registered; see 4.2 |
| registers | `reg_wr_en`, `reg_wr_addr[11:0]`, `reg_wr_data[31:0]`, `reg_rd_en`, `reg_rd_addr[11:0]`, `reg_rd_data[31:0]` | proto_clk | read data valid the clock after `reg_rd_en` |
| application clock | `app_clk`, `app_resetn` | app_clk | `app_resetn` released with `resetn` from one assertion |
| application RX | out `m_axis_app_tdata[63:0]`, `m_axis_app_tkeep[7:0]`, `m_axis_app_tvalid`, `m_axis_app_tlast`; in `m_axis_app_tready` | app_clk | received datagrams (section 2) |
| application TX | in `s_axis_app_tdata[63:0]`, `s_axis_app_tkeep[7:0]`, `s_axis_app_tvalid`, `s_axis_app_tlast`; out `s_axis_app_tready` | app_clk | datagrams to send (section 2) |
| subnet | `local_mask[31:0]`, `local_gateway[31:0]` | proto_clk | `local_mask` gives the subnet broadcast address; `local_gateway` is not used by this revision (section 9) |

### 1.2 Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `NUM_SOCKETS` | 4 | sockets, 1..60 (`$fatal` outside) |
| `UDP_RX_BUF_KB` | 16 | RX packet FIFO, KiB; one datagram per 2 KiB slot, so 16 KiB holds 8 datagrams of any size (4, 8, 16, 32, ... allowed) |
| `UDP_TX_BUF_KB` | 8 | TX payload FIFO, KiB; one payload per 2 KiB slot, so 8 KiB holds 4 |
| `RAM_STYLE` | `"block"` | `"block"` or `"distributed"`, for all three FIFOs |

The technology comes from `rtlnet_technology.svh`; no technology parameter exists.

---

## 2. The application stream

Both directions use the RTLNet stream (64-bit AXI4-Stream, byte 0 in `tdata[7:0]`) with two metadata beats ahead of
the payload (architecture 7.7):

| Beat | `tdata[63:32]` | `tdata[31:16]` | `tdata[15:0]` | `tkeep` |
|---|---|---|---|---|
| meta 0 | remote IPv4 address, first octet in `[63:56]` | remote UDP port | payload length in bytes, 0..1472 | `0xFF` |
| meta 1 | `[63:56]` socket index, `[55:48]` flags, `[47:0]` remote MAC, octet 0 in `[47:40]` | | | `0xFF` |
| payload | payload byte `8k+i` in lanes `i` of payload beat `k` | | | `0xFF`, last beat contiguous |

`tlast` is on the last payload beat, or on meta 1 for a zero-length datagram. Metadata values are in number order (not
bus order): `meta0 = {ip, port, len}`, `meta1 = {sock, flags, mac}` as 64-bit integers.

| Flag bit | Receive (layer to application) | Transmit (application to layer) |
|---|---|---|
| 0 | `BROADCAST`: sent to 255.255.255.255 or to the subnet broadcast address | `USE_SOCKET_REMOTE`: take destination IP, port and MAC from the socket's `REMOTE_*` registers, ignore the metadata's |
| 1 | `OFF_SUBNET`: the sender is outside `local_ip`/`local_mask` (meta 1 MAC is then the router's) | reserved, write 0 |
| 7:2 | 0 | reserved, write 0 (bit 7 is replaced internally by the length verdict) |

### 2.1 Receive (m_axis_app, app_clk)

A datagram is offered only when it is complete in the RX FIFO (store and forward) and is never offered half: no bubble
inside a datagram, one idle clock between datagrams. The application may stall at any time; while it stalls, the FIFO
fills, and datagrams that find it full are dropped and counted (`RX_FIFO_DROPS` and the socket's `RX_DROPS`).

```
13-byte datagram on socket 1 from 192.168.1.10:40000, MAC 00:11:22:33:44:55

app_clk        _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
tvalid         ____|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|____
tready         ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|___|‾‾‾‾‾‾‾‾‾‾‾‾‾      (one-clock stall: beat P0 held)
tdata          ----< M0  >< M1  >< P0       >< P1  >----
tkeep          ----< FF  >< FF  >< FF       >< 1F  >----
tlast          ______________________________|‾‾‾‾|____

M0 = 0xC0A8010A_9C40_000D   (192.168.1.10, port 40000, length 13)
M1 = 0x01_00_001122334455   (socket 1, flags 0, MAC)
P0 = payload bytes 0..7, P1 = bytes 8..12 (tkeep 0x1F)
```

### 2.2 Transmit (s_axis_app, app_clk)

The application writes meta 0, meta 1 and the payload. `s_axis_app_tready` is low only between datagrams (while the
TX payload FIFO or the descriptor FIFO has no free slot, and for two clocks after each datagram's last beat while its
descriptor is written); once meta 0 is accepted, the rest of the datagram is never stalled.

```
zero-length datagram, then a 5-byte one

app_clk        _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
tvalid         ____|‾‾‾‾‾‾‾‾‾‾|___________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|___
tready         ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|_______|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾      (descriptor write: 2 clocks)
tdata          ----< M0 >< M1 >-----------< M0 >< M1 >< P0 >---
tkeep          ----< FF >< FF >-----------< FF >< FF >< 1F >---
tlast          __________|‾‾‾‾|________________________|‾‾‾‾|___
```

The layer drops a datagram (no frame; counted in the global `TX_DROPS` and, with a valid index, the socket's
`TX_DROPS`) when: the socket index is not below `NUM_SOCKETS`; the socket is disabled; the leaf is disabled; meta 0
carries `tlast`; the length exceeds 1472; or the payload does not match the length (byte count differs, `tlast` on
meta 1 with a non-zero length, a payload after a zero length, a non-final beat with `tkeep != 0xFF`, an empty or
non-contiguous final `tkeep`).

### 2.3 The frame sent

| Field | Value |
|---|---|
| Ethernet destination | meta 1 MAC, or `REMOTE_MAC` with `USE_SOCKET_REMOTE` |
| Ethernet source / EtherType | `local_mac` / 0x0800 |
| IPv4 | version/IHL 0x45, ToS 0, total length L + 28, identification from a counter (0 after reset, +1 per frame sent), flags/fragment 0x4000 (DF), TTL 64, protocol 17, header checksum (`rtlnet_pkg::ipv4_header_checksum`), source `local_ip`, destination meta 0 IP or `REMOTE_IP` |
| UDP | source port = the socket's `LOCAL_PORT`; destination meta 0 port or `REMOTE_PORT`; length L + 8; checksum 0 (RFC 768: no checksum) |
| Payload | from frame byte 42; frames shorter than 60 bytes are padded by the MAC |

---

## 3. Registers

12-bit leaf address (inside the protocol sub-map at 0x5000; board address 0x44A1_5000 on the Nexys Video). Offsets and
bits are defined in `driver/rtlnet_udp_socket.h`; the RTL mirrors them. Counters are 32-bit, wrap, reset to 0 and clear
with `CTRL.CNT_CLEAR`. Undefined offsets read 0 and ignore writes.

### 3.1 Global

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | 0x55445053 | "UDPS" |
| 0x004 | `VERSION` | RO | 0x10222026 | register map date code |
| 0x008 | `CAPS` | RO | 0x01081004 | `[7:0]` NUM_SOCKETS, `[15:8]` UDP_RX_BUF_KB, `[23:16]` UDP_TX_BUF_KB, `[24]` receive checksum check available |
| 0x00C | `CTRL` | RW | 0 | `[0]` RX_CSUM_CHECK (verify non-zero UDP checksums on receive); `[16]` CNT_CLEAR (W, self-clearing, reads 0; clears every global and per-socket counter) |
| 0x010 | `STATUS` | RO | 0x1 | `[0]` leaf enable, `[1]` RX busy, `[2]` TX active, `[3]` RX FIFO full (meaningful between datagrams), `[4]` TX descriptor waiting |
| 0x014 | `RX_NO_SOCKET` | RO | 0 | valid datagram for this node, no enabled socket on its port |
| 0x018 | `RX_BAD` | RO | 0 | UDP for this node rejected: fragment (MF or offset), version/IHL != 0x45, total length outside 28..1500, UDP length != total length - 20, bad IPv4 header checksum, frame shorter than the datagram, bad UDP checksum (with RX_CSUM_CHECK) |
| 0x01C | `RX_FIFO_DROPS` | RO | 0 | socket matched, RX FIFO full |
| 0x020 | `TX_FRAMES` | RO | 0 | frames sent |
| 0x024 | `TX_DROPS` | RO | 0 | every dropped application datagram (including out-of-range socket indexes) |
| 0x028 | `RX_DATAGRAMS` | RO | 0 | datagrams delivered to the application |

### 3.2 Per socket n (0x100 + 0x40 × n)

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| +0x00 | `CTRL` | RW | 0 | `[0]` ENABLE, `[1]` CONNECT_ON_RX |
| +0x04 | `LOCAL_PORT` | RW | 0 | `[15:0]` bound UDP port |
| +0x08 | `REMOTE_IP` | RW | 0 | first octet in `[31:24]` |
| +0x0C | `REMOTE_PORT` | RW | 0 | `[15:0]` |
| +0x10 | `REMOTE_MAC_HI` | RW | 0 | `[15:0]` = MAC octets 0, 1 |
| +0x14 | `REMOTE_MAC_LO` | RW | 0 | `[31:0]` = MAC octets 2..5 |
| +0x18 | `RX_DATAGRAMS` | RO | 0 | delivered on this socket |
| +0x1C | `RX_DROPS` | RO | 0 | matched this socket, RX FIFO full |
| +0x20 | `TX_DATAGRAMS` | RO | 0 | sent from this socket |
| +0x24 | `TX_DROPS` | RO | 0 | dropped: socket disabled, leaf disabled, length mismatch |

With `CONNECT_ON_RX`, every datagram delivered on the socket loads `REMOTE_IP`, `REMOTE_PORT` and `REMOTE_MAC` with
its sender; a register write in the same clock takes precedence. Receive matching uses the lowest-index enabled socket
whose `LOCAL_PORT` equals the destination port.

---

## 4. Design

```
s_axis --> rtlnet_udp_socket_rx (proto_clk) --> u_rx_fifo (proto -> app) --> m_axis_app
              | decision at beat 4, realign 42 -> 0, late verdicts
              v events
          register file / socket table / counters (proto_clk) <--> reg_* bus
              ^ events                     | socket table
              |                            v
m_axis <-- u_out_slice <-- rtlnet_udp_socket_tx (proto_clk) <-- u_tx_fifo      (payload, app -> proto)
                                                            <-- u_tx_desc_fifo (meta 0, meta 1 + verdict)
                                    rtlnet_udp_socket_tx_check (app_clk) <-- s_axis_app
```

| File | Module |
|---|---|
| `hdl/rtlnet_udp_socket_pkg.sv` | frame offsets, limits, metadata field positions, flag bits |
| `hdl/rtlnet_udp_socket_rx.sv` | receive parser, decision, realigning FIFO writer |
| `hdl/rtlnet_udp_socket_tx_check.sv` | application-side split into payload and descriptor, length verdict |
| `hdl/rtlnet_udp_socket_tx.sv` | frame builder |
| `hdl/rtlnet_udp_socket.sv` | top: register file, socket table, counters, FIFOs, output slice |
| `hdl/rtlnet_udp_socket.f` | compile order (includes `rtlnet_common.f`) |

### 4.1 Receive engine

States: `S_IDLE`, `S_HDR` (beats 1..4), `S_META0`, `S_META1`, `S_PAYLOAD`, `S_DRAIN`. Fields are captured by beat
number (beat k = frame bytes 8k..8k+7). The decision is taken on the clock of beat 4 (bytes 32..39, which completes the
destination IP, both ports and the UDP length), in this order:

| Condition | Result |
|---|---|
| leaf disabled, EtherType != 0x0800, protocol != 17, or destination IP not `local_ip`, 255.255.255.255 or `local_ip \| ~local_mask` | ignored, no counter |
| version/IHL != 0x45, MF set, fragment offset != 0, total length < 28 or > 1500, UDP length != total length - 20, IPv4 header checksum does not verify, frame ends at beat 4 | `RX_BAD` |
| no enabled socket with `LOCAL_PORT` = destination port | `RX_NO_SOCKET` |
| RX FIFO has no free slot | `RX_FIFO_DROPS`, socket `RX_DROPS` |
| otherwise | accepted |

The FIFO is in back-pressure mode (`DROP_WHEN_FULL = 0`): between datagrams its `s_ready` is low exactly when it has no
free slot, and the engine's previous datagram is always fully written before the engine is idle again, so `s_ready` at
the decision is the drop verdict and stays valid until the first write. The input is never stalled.

Write order: meta 0 on the clock after the decision, meta 1 on the next, then one payload word per clock it is formed.
Payload word m is frame bytes 42+8m..49+8m: lanes 2..7 of beat 5+m (held in `hold`) joined to lanes 0..1 of beat 6+m.
A word is formed when its last byte arrives; a final word of 1..6 bytes lies wholly in lanes 2..7 of one beat and is
written from `hold` one clock later (`flush_pend`). The first payload word needs beat 6, so it cannot be formed before
meta 1 is written, and the one-word payload register never holds a word for more than one clock (a simulation check
reports an overwrite). Bytes past the UDP length (Ethernet padding) are never written.

Late verdicts act on the datagram's final FIFO beat through the FIFO's `s_bad`, which drops the whole datagram inside
the FIFO: the frame ends before the datagram does (`short_now`: the frame bytes up to the last beat are fewer than
42 + L), or, with `CTRL.RX_CSUM_CHECK`, a non-zero UDP checksum fails (pseudo-header + UDP header + payload, RFC 768 /
RFC 1071, padding lanes masked; a zero checksum means "none" and is accepted). Either counts in `RX_BAD`. A zero-length
datagram writes meta 1 (with `tlast`) only after byte 41 has arrived, so the same verdicts apply.

A frame is taken only if its first beat finds the engine in `S_IDLE`; `in_frame` tracks the input frame boundaries
independently, so a frame that starts while the engine is busy is ignored whole (bench case "frame starting while
busy").

### 4.2 busy

`busy` is a flop, high from the clock after any frame's first beat until the engine is back in `S_IDLE` (end of the
input frame and, for an accepted datagram, its last FIFO write, at most two clocks after the datagram's last byte). It
is therefore high at every input frame's last beat, well inside the 12-clock rule, and covers receive processing only:
transmission never raises it, so the wrapper's dequeue is never held by outgoing traffic.

### 4.3 Transmit path

`rtlnet_udp_socket_tx_check` (app_clk) accepts meta 0 only when both the TX payload FIFO and the descriptor FIFO have a
free slot; then it streams the payload into the payload FIFO unchanged and judges the length (section 2.2). A bad
datagram's final payload beat carries `s_bad`, so it never reaches the read side; a payload longer than a slot is
dropped by the FIFO itself. Two clocks after the final beat it writes the descriptor: word 0 = meta 0, word 1 = meta 1
with flags bit 7 = verdict (a datagram without meta 1 gets socket index 0xFF). A payload frame exists exactly when the
length is non-zero and the verdict is good, which keeps the two FIFOs in step.

`rtlnet_udp_socket_tx` (proto_clk), states `T_IDLE`, `T_DESC1`, `T_DECIDE`, `T_SUM`, `T_WAITPAY`, `T_HDR`, `T_PAY`,
`T_FLUSH`, `T_DISCARD`:

1. Read the two descriptor words.
2. `T_DECIDE`: drop if the verdict is bad, the index is out of range, the socket or the leaf is disabled (a present
   payload frame is then read and discarded in `T_DISCARD`); otherwise register the header fields, snapshot
   `local_mac`/`local_ip`, choose metadata or socket remote fields.
3. `T_SUM`: register the IPv4 header checksum.
4. `T_WAITPAY`: wait until the payload frame is visible (the two FIFOs cross separately); the payload FIFO has no
   bubble inside a frame, so the frame is then offered without gaps.
5. Five header beats from registered fields, then beats 5.. with `{payload word m [47:0], word m-1 [63:48]}` (beat 5
   lanes 0-1 = UDP checksum 0). A final word with 7 or 8 bytes leaves one more beat (`T_FLUSH`); a zero-length datagram
   ends with beat 5 (`tkeep 0x03`).

| Beat | Bytes | Content |
|---|---|---|
| 0 | 0-7 | destination MAC, source MAC octets 0-1 |
| 1 | 8-15 | source MAC 2-5, EtherType 0x0800, 0x45, ToS 0 |
| 2 | 16-23 | total length, identification, 0x4000, TTL 64, protocol 17 |
| 3 | 24-31 | header checksum, source IP, destination IP octets 0-1 |
| 4 | 32-39 | destination IP 2-3, source port, destination port, UDP length |
| 5.. | 40.. | UDP checksum 0x0000, payload |

The output passes one `rtlnet_axis_reg_slice` (`u_out_slice`); `m_axis_tready` is the only stall.

---

## 5. Clocks, resets and crossings

| Domain | Contents |
|---|---|
| proto_clk (`clk`) | receive engine, frame builder, register file, socket table, counters, write side of `u_rx_fifo`, read sides of `u_tx_fifo` and `u_tx_desc_fifo`, output slice |
| app_clk | transmit checker, read side of `u_rx_fifo`, write sides of `u_tx_fifo` and `u_tx_desc_fifo` |

The only crossings are the three `rtlnet_packet_fifo` instances (Gray frame counters, names matching `u_*_fifo` for
`scripts/rtlnet_constrain_cdc.tcl`). `app_clk` may be any frequency, related or not to `proto_clk` (verified at 62.5,
100 and 33.3 MHz against 50 MHz, and equal to `proto_clk`). Both FIFO sides must reset together: `resetn` and
`app_resetn` come from one assertion in the board top (architecture 9, 15). Register writes act in proto_clk; the socket
table is read by both engines without a crossing.

---

## 6. Buffers, latency and resources

| Buffer | Size | Slots | Notes |
|---|---|---|---|
| `u_rx_fifo` | `UDP_RX_BUF_KB` | KB / 2 (8 at 16 KiB) | slot = 16 + 1472 bytes (186 words) rounded to 256 words; one datagram per slot whatever its size |
| `u_tx_fifo` | `UDP_TX_BUF_KB` | KB / 2 (4 at 8 KiB) | payload only, 1472 bytes per slot |
| `u_tx_desc_fifo` | 1 KiB (fixed localparam `TX_DESC_KB`) | 64 | two words per datagram; more slots than the payload FIFO up to `UDP_TX_BUF_KB` = 128 |

Latency (derived from the state machines, not measured): a received datagram is published in the RX FIFO at most two
proto_clk clocks after its last byte; the application sees its first beat after the FIFO's Gray-counter crossing (two
app_clk synchronizer stages plus the RAM read). A transmitted datagram's descriptor is written two app_clk clocks after
its last beat; after the crossing the frame builder needs five proto_clk clocks (`T_IDLE` to `T_WAITPAY`) and the output
slice one more before the first beat appears on `m_axis`. Per frame the builder adds about five idle clocks to the
frame's beats, so it sustains far above 1 Gb/s at 50 MHz (64 bits per clock).

Synthesis, Vivado 2025.2, out of context, xc7a200tsbg484-1, default parameters (10-22-2026, `scripts/rtlnet_synth_check.tcl`):

| Resource | Used |
|---|---|
| Slice LUTs | 2640 (all logic, no LUT RAM) |
| Slice registers | 2601 |
| Block RAM | 8.5 tiles: 7 RAMB36 + 3 RAMB18 (RX FIFO 2048 x 73, TX FIFO 1024 x 73, descriptor FIFO 128 x 73) |
| DSP | 0 |
| Critical warnings | 0 (`rtlnet_synth_check: PASS rtlnet_udp_socket`) |

Warnings (not critical): `s_axis_tready` driven by constant 1 (the contract) and the XPM memory's unused ECC/sleep pins.
Timing was not analysed (the OOC check has no clock constraints); the longest proto_clk path is expected at the beat-4
decision (four 16-bit port compares, the IPv4 header checksum fold and the FIFO ready), designed for 50 MHz.

---

## 7. Verification

### 7.1 `tb_rtlnet_udp_socket` (the leaf alone)

The leaf sits between a bench wrapper (frame source and sink in proto_clk, the register bus driven directly, frames sent
only while `busy` is low and after 16 idle clocks) and a bench application (stream source and sink in app_clk). Oracles:
frames built by `rtlnet_tb_pkg::udp_frame` / `ipv4_header` with `inet_checksum` (independent of the RTL), checked byte
for byte, and every sent frame's IPv4 header summed to 0xFFFF.

| Group | Proves |
|---|---|
| registers | ID, VERSION, CAPS, CTRL, STATUS reset values; read-back and field widths of every socket register; undefined offsets read 0 and ignore writes |
| receive | every payload length 0..64 and 100, 255, 256, 511, 1000, 1465, 1471, 1472 byte-exact; lengths 0..40 and 1472 with 35 % input gaps; unpadded frames with a 40 % ready application; non-zero padding never delivered |
| sockets | shared port: lowest index wins, then the next socket when it is disabled; unknown port and disabled socket in `RX_NO_SOCKET`; CONNECT_ON_RX follows the last sender, a socket without it keeps its registers |
| rejections (`RX_BAD`, nothing delivered) | MF, offset 1, IHL 6, version 6, UDP length - 1, IP length + 1, total length 27, 1501, truncated by 1 byte, truncated inside the final word, zero-length frame of 41 bytes, header checksum; DF clear accepted |
| ignored (no counter) | ARP, ICMP, UDP for another host, another subnet's broadcast, a frame ending in the IP header |
| broadcast | limited and subnet broadcast with `BROADCAST`; an off-subnet sender with `OFF_SUBNET` |
| UDP checksum | bad checksum delivered with the check off; with it on, good checksums (lengths 0..17, 1472, to broadcast) and a zero checksum delivered, bad ones (payload bit, zero-length, last byte) in `RX_BAD` |
| RX FIFO full | application stalled: 12 datagrams, 8 kept and delivered in order, 4 in `RX_FIFO_DROPS` and the socket's `RX_DROPS`; STATUS bit 3 set while full, clear after drain |
| transmit | every length 0..64 and 100..1472 byte-exact against the oracle with a 70 % ready sink, identification from 0 upward; socket 2's port with a gappy application; `USE_SOCKET_REMOTE` from written registers and from CONNECT_ON_RX-learned ones (zero length) |
| transmit drops | disabled socket, index 4, index 255, one byte short, one byte long, one beat short, payload after zero length, length without payload, meta 0 only, 1473 bytes, 2100 bytes (longer than a slot): each counted per socket / globally, none emitted, the next good datagram exact |
| concurrency | 30 random-length transmits and 30 receives at the same time with random stalls on both sinks, all exact and in order |
| protection | a frame starting the clock after the previous one ends (leaf busy) is ignored whole; the next spaced frame is taken |
| enable, clear | leaf disabled: frame ignored, transmit dropped and counted; re-enable; CNT_CLEAR zeroes all 22 counters |
| always on | `rtlnet_tb_leaf_busy_monitor` (tready, reply/busy, stuck, X); busy high within 12 clocks of every input frame's last beat; no gap inside an output frame or an application datagram; stream rules of both sinks; the RTL's simulation checks (FIFO write refused, payload register overwritten, TX bubble) |

Results (10-22-2026), `scripts/rtlnet_regression.ps1 -Match udp_socket`:

| Run | Configuration | Result |
|---|---|---|
| `tb_rtlnet_udp_socket` | app_clk 62.5 MHz, AMD XPM model | PASS, 1104 checks |
| `_app100` | app_clk 100 MHz | PASS, 1104 checks |
| `_app33` | app_clk 33.3 MHz | PASS, 1104 checks |
| `_generic` | `RTLNET_TECH_GENERIC` RAM model | PASS, 1104 checks |
| `_neg` | `+INJECT_FAILURE` | TEST FAIL as required (fails=1) |

Each check group was shown failing against a mutated copy of the RTL (restored afterwards): flush `tkeep` + 1 (134
fails), UDP checksum never bad (22), highest socket index wins (28), fragment offset not checked (25), TTL 63 (216),
transmit length check off (50), CONNECT_ON_RX off (8), `busy` tied low (busy-rise check), a bubble in a header beat
(output-gap check).

### 7.2 With the echo core

`tb_rtlnet_udp_echo` (see `cores/rtlnet_udp_echo/documentation/rtlnet_udp_echo.md`) runs this layer under the echo
application: 120 random datagrams on three sockets, overload with a stalled sink (exactly 12 datagrams buffered, the
rest counted in `RX_FIFO_DROPS`, traffic resumes), and `TX_FRAMES` equal to the replies seen. PASS, 696 checks
(three configurations).

### 7.3 Driver

`testbench/test_rtlnet_udp_socket_driver.c` runs the driver on the PC against a register model (field masks, read-only
counters, self-clearing CNT_CLEAR, window bounds): probe, open order (disable, port, enable), option and index checks,
find-port priority, connect-on-receive read-modify-write, remote MAC layout, counters, clear keeping RX_CSUM_CHECK.
`DRIVER TEST PASS: rtlnet_udp_socket checks=53` (host gcc 16.2, `-std=c11 -Wall -Wextra -Werror`). The driver also
compiles with `mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c` with no message.

Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1 -Match udp_socket
gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver -Icores/rtlnet_udp_socket/driver \
    cores/rtlnet_udp_socket/driver/rtlnet_udp_socket.c cores/rtlnet_udp_socket/testbench/test_rtlnet_udp_socket_driver.c \
    -o test_udps && ./test_udps
```

Not verified: behaviour inside `rtlnet_eth_protocol` (written separately), metastability (zero-delay simulation; the
crossings rely on the packet FIFO), timing closure at 50 MHz, hardware.

---

## 8. Application developer's guide

How to put a new UDP application on the socket streams.

1. **Pick a socket and a port.** Firmware opens it: `rtlnet_udp_socket_open(base, sock, port, options)` (the base is the
   leaf's window). Use `RTLNET_UDPS_OPEN_CONNECT_ON_RX` for a server that answers whoever spoke last; leave it off and
   call `rtlnet_udp_socket_set_remote()` for a fixed peer. The layer does not run ARP: the remote MAC must be the
   next hop's (the peer on the local subnet, else the router); CONNECT_ON_RX learns it from received frames.
2. **Choose the clock.** The application runs on `app_clk` (the wrapper's `app_clk`, `proto_clk` on the Nexys Video).
   All four stream ports and nothing else are in that domain; the layer does every crossing.
3. **Receive.** Watch `m_axis_app_*`. Take meta 0 and meta 1, then the payload; `tlast` ends the datagram (on meta 1
   for length 0). Use meta 1 `[63:56]` to know which socket it came from. Keep `tready` high as much as possible: while
   the application stalls, the 8-slot RX FIFO fills and later datagrams are dropped (counted), never blocked; the
   network side never waits for the application. Never assume a payload size from the port: use meta 0 `[15:0]`.
4. **Transmit.** Present meta 0 (destination IP, port, length), meta 1 (socket index, flags, destination MAC) and
   exactly `length` payload bytes, `tkeep` 0xFF except on the last beat. To answer the sender of a received datagram,
   copy meta 0 and meta 1 and clear the flags byte (what `rtlnet_udp_echo` does), or set `USE_SOCKET_REMOTE` on a
   CONNECT_ON_RX socket. `s_axis_app_tready` may fall between datagrams only; hold `tvalid` and data while it is low.
   Up to 1472 bytes; a mismatch between the length and the payload is dropped and counted in `TX_DROPS`, so a
   `TX_DROPS` count rising during bring-up means a framing bug in the application.
5. **Several applications.** The layer has one RX stream and one TX stream for all sockets. To attach more than one
   application, put a demultiplexer on `m_axis_app_*` that steers each datagram by meta 1 `[63:56]` (decided at meta 1,
   held to `tlast`), and an arbiter on `s_axis_app_*` that grants per datagram (from meta 0 to `tlast`). A receiving
   application that stalls then stalls the others too; give each a small FIFO if they run at different rates.
6. **Do not deadlock.** The transmit path never depends on the receive path, so an application may stall its receive
   side while it waits for transmit `tready`, as the echo does; it must not make transmit wait on a receive that only
   arrives after its own transmission is accepted.
7. **Verify.** Copy `tb_rtlnet_udp_echo` (the layer plus an application, frames in and out at the wrapper side) and
   replace the echo; keep the busy monitor and byte-exact frame checks.

---

## 9. Limitations and deviations

| Item | Behaviour |
|---|---|
| ARP / routing | none: the next-hop MAC comes from the metadata or `REMOTE_MAC`; `local_gateway` is accepted on the port list but not used |
| UDP checksum, transmit | always 0 (RFC 768 allows "no checksum" over IPv4) |
| UDP checksum, receive | not verified unless `CTRL.RX_CSUM_CHECK` is set (default off); the MAC's FCS covers the frame |
| IPv4 header checksum, receive | verified (RFC 1122 3.2.1.2); a bad one counts in `RX_BAD` |
| IP options, fragments, VLAN tags | rejected (`RX_BAD`) / not parsed (a tagged frame's EtherType is 0x8100 and is ignored) |
| Ethernet destination | not checked (the wrapper filters local MAC and broadcast) |
| RX FIFO granularity | one datagram per 2 KiB slot regardless of size: 8 datagrams at 16 KiB |
| Descriptor FIFO | fixed 1 KiB (64 descriptors), not covered by a parameter; with `RAM_STYLE = "block"` it costs about 1.5 block RAM tiles (one RAMB36 and one RAMB18, inferred from the synthesis totals, not reported per instance) |
| Leaf disabled | received frames ignored (not counted); application datagrams consumed and counted as `TX_DROPS` |
| Frames shorter than 42 bytes | ignored when they end before beat 4, `RX_BAD` otherwise |
| Remote register read | the four `REMOTE_*` registers are read one by one; a CONNECT_ON_RX update between two reads gives a mixed view |

---

## 10. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version |
