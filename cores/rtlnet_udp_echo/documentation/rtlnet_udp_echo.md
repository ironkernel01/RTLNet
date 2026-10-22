# rtlnet_udp_echo — UDP echo server

| Item | Value |
|---|---|
| Core | `rtlnet_udp_echo` |
| Document revision | 10-22-2026 |
| Language | SystemVerilog-2012 (RTL, bench), C11 (driver), Python 3 (host client) |
| Position | application on the `rtlnet_udp_socket` streams (architecture sections 7.7, 7.8, 15.5); board window 0x0_3000 |
| Register map revision | `VERSION` = `0x10222026`, `ID` = `0x4543484F` ("ECHO") |
| Verification | Active-HDL 11.1: `tb_rtlnet_udp_echo` (socket layer + echo; three configurations + negative control); host driver test; host client exercised on localhost |
| Synthesis | Vivado 2025.2 out of context, xc7a200tsbg484-1: PASS, 0 critical warnings |

Every datagram the socket layer delivers on the selected socket (or on any socket) goes back to its sender with the
payload unchanged. It is the reference application for the socket streams and the board's UDP loopback test.

---

## 1. Interface

| Group | Ports | Domain |
|---|---|---|
| clocks, resets | `app_clk`, `app_resetn`, `s_axi_aclk`, `s_axi_aresetn` | synchronous, active low; both resets from one assertion |
| from socket layer | in `s_axis_tdata[63:0]`, `s_axis_tkeep[7:0]`, `s_axis_tvalid`, `s_axis_tlast`; out `s_axis_tready` | app_clk; connects to the layer's `m_axis_app_*` |
| to socket layer | out `m_axis_tdata[63:0]`, `m_axis_tkeep[7:0]`, `m_axis_tvalid`, `m_axis_tlast`; in `m_axis_tready` | app_clk; connects to the layer's `s_axis_app_*`; registered (one `rtlnet_axis_reg_slice`) |
| registers | `s_axi_*` AXI4-Lite slave, 12-bit address, 32-bit data | s_axi_aclk; internal `rtlnet_axil_cdc` to app_clk |

No parameters. Stream format: `rtlnet_udp_socket.md` section 2.

---

## 2. Registers

Offsets and bits defined in `driver/rtlnet_udp_echo.h`. Counters 32-bit, wrapping, cleared by `CNT_CLEAR`. Undefined
offsets read 0; a write with `wstrb != 0xF` is ignored (answered OKAY).

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | 0x4543484F | "ECHO" |
| 0x004 | `VERSION` | RO | 0x10222026 | |
| 0x008 | `CAPS` | RO | 0x000005C0 | `[15:0]` largest datagram payload (1472) |
| 0x00C | `CTRL` | RW | 0 | `[0]` ENABLE, `[1]` SOCKET_ANY, `[15:8]` SOCKET index, `[16]` CNT_CLEAR (W, self-clearing, reads 0); every CTRL write reloads bits 15:0 |
| 0x010 | `STATUS` | RO | 0 | `[0]` ENABLE, `[1]` inside a datagram |
| 0x014 | `ECHOED_DATAGRAMS` | RO | 0 | datagrams sent back |
| 0x018 | `ECHOED_BYTES` | RO | 0 | payload bytes sent back |
| 0x01C | `DISCARDED` | RO | 0 | datagrams consumed and not echoed (disabled or another socket) |

The selection is sampled at each datagram's meta 1, so a CTRL change applies from the next datagram.

---

## 3. Design

```
s_axis --> E_META0 --> E_META1 --+--(echo)--> E_OUT0 --> E_OUT1 --+--(length > 0)--> E_PAY --> E_META0
                                 |                                 +--(length 0)------------> E_META0
                                 +--(not echoed)--> E_DISCARD --> E_META0
E_OUT0/E_OUT1/E_PAY --> u_out_slice --> m_axis
```

| State | Input ready | Output | Leaves when |
|---|---|---|---|
| `E_META0` | 1 | — | meta 0 taken (a meta 0 with `tlast` is counted as discarded) |
| `E_META1` | 1 | — | meta 1 taken; echo if `ENABLE && (SOCKET_ANY \|\| index == SOCKET)` |
| `E_OUT0` | 0 | meta 0 unchanged (destination = the sender's IP and port, length kept) | slice accepts |
| `E_OUT1` | 0 | meta 1 with the flags byte cleared (socket index and sender MAC kept; `USE_SOCKET_REMOTE` = 0) | slice accepts |
| `E_PAY` | slice ready | the input beats unchanged (cut-through) | last beat |
| `E_DISCARD` | 1 | — | last beat |

The flags byte is cleared because receive flags (`BROADCAST`, `OFF_SUBNET`) have no transmit meaning and bit 0 would
otherwise route the reply through the socket's remote registers. A broadcast request is answered to its sender's
unicast address.

Back-pressure: a stall on `m_axis` stops `s_axis` (the input ready during a payload is the slice's registered ready).
The socket layer's transmit path drains independently of its receive path, so the loop cannot deadlock; under a long
stall the socket layer buffers 12 datagrams (8 in its RX FIFO, 4 in its TX payload FIFO; the datagram being echoed keeps
its RX slot) and counts the rest in its `RX_FIFO_DROPS`. A disabled echo consumes at full rate, so the RX FIFO never
backs up behind it.

Clocks: app_clk carries the engine and the register file; s_axi_aclk only the slave side of `u_axil_cdc`. The only
crossing is `rtlnet_axil_cdc` (held bundle with toggle request/acknowledge, `req_*_hold` / `rsp_*_hold` for the
constraint script). On the Nexys Video `app_clk` is `proto_clk`.

Synthesis, Vivado 2025.2, out of context, xc7a200tsbg484-1 (10-22-2026): 279 LUTs, 648 registers, no block RAM, no DSP,
0 critical warnings (`rtlnet_synth_check: PASS rtlnet_udp_echo`); two warnings, both Synth 8-6014 "unused sequential
element `s_axi_wready_reg` removed" inside the common `rtlnet_axil_cdc` and `rtlnet_axil_slave`.

---

## 4. Verification

`tb_rtlnet_udp_echo`: the real `rtlnet_udp_socket` (sockets 0, 1, 2 on ports 7, 5000, 6000) looped through the echo;
frames enter and leave at the wrapper side of the layer (proto_clk 50 MHz), the echo registers are driven by
`rtlnet_tb_axil_master` at 100 MHz. Each reply is compared byte for byte with a frame the bench builds with
`rtlnet_tb_pkg::udp_frame` (addresses swapped, the socket's port as source, identification counting up) and its IPv4
header is summed to 0xFFFF.

| Group | Proves |
|---|---|
| registers | reset values, partial write ignored, CTRL read-back |
| disabled | three datagrams consumed, no reply, `DISCARDED` = 3 |
| sizes | every payload length 0..64 and 100, 511, 1000, 1471, 1472 echoed byte-exact with a 60 % ready sink |
| selection | other sockets discarded while socket 0 is selected; socket 1 selected; SOCKET_ANY echoes all three; a broadcast request answered to the sender |
| random stream | 120 datagrams, random sizes (a quarter up to 1472) on random sockets, up to three in flight, 70 % ready sink, all in order |
| overload | reply side stalled while 30 datagrams arrive: the replies are an in-order subsequence, replies + socket `RX_FIFO_DROPS` = 30, exactly 12 buffered, the next datagram is answered (no deadlock) |
| counters | `ECHOED_DATAGRAMS`, `ECHOED_BYTES`, `DISCARDED` against the bench's count after each group; disable mid-run; CNT_CLEAR keeps SOCKET_ANY; socket `TX_FRAMES` equals the replies |
| always on | `rtlnet_tb_leaf_busy_monitor` on the socket layer, sink stream rules |

Results (10-22-2026), `scripts/rtlnet_regression.ps1 -Match udp_echo`:

| Run | Configuration | Result |
|---|---|---|
| `tb_rtlnet_udp_echo` | app_clk 62.5 MHz | PASS, 696 checks |
| `_appproto` | app_clk = proto_clk (Nexys Video) | PASS, 696 checks |
| `_generic` | `RTLNET_TECH_GENERIC` | PASS, 696 checks |
| `_neg` | `+INJECT_FAILURE` | TEST FAIL as required |

Mutations of the echo RTL, each reported as TEST FAIL and then restored: flags not cleared (broadcast reply misrouted),
socket select ignored (156 fails), byte counter off by one, enable ignored (229), back-pressure ignored (overload count
check).

Driver: `testbench/test_rtlnet_udp_echo_driver.c` against a register model: probe, select socket / any keeping ENABLE,
index 256 rejected without a write, counters, clear keeping the configuration. `DRIVER TEST PASS: rtlnet_udp_echo
checks=18`; `mb-gcc -mlittle-endian -mcpu=v11.0 -std=c11 -Wall -Wextra -Werror -c` clean.

Not verified: hardware, the core inside the board top, timing at the board clocks.

---

## 5. Firmware and host use

Firmware (CLI `ECHO ON|OFF|STATUS`):

```c
rtlnet_udp_socket_open(UDPS_BASE, 0u, 7u, 0u);   /* socket 0 on UDP port 7 */
rtlnet_udp_echo_select_socket(ECHO_BASE, 0u);
rtlnet_udp_echo_enable(ECHO_BASE, 1);
```

Host: `testbench/udp_echo_client.py` (Python 3, standard library only) sends N datagrams to `<ip>:<port>`, waits for
each reply, compares it byte for byte, and reports answered, lost (and late), mismatched, and round-trip latency (min,
average, p50, p99, max). Payloads derive from the sequence number and size, so a late reply to an earlier datagram is
recognised. Exit status 0 on a pass, 1 on loss above `--max-loss` or any mismatch, 2 on bad arguments.

```
python cores/rtlnet_udp_echo/testbench/udp_echo_client.py 192.168.1.220 -p 7 -n 1473 --sweep
python cores/rtlnet_udp_echo/testbench/udp_echo_client.py 192.168.1.220 -p 7 -n 1000 --max-size 1472 --timeout 0.5
python cores/rtlnet_udp_echo/testbench/udp_echo_client.py 192.168.1.220 --sizes 0,1,64,512,1472 -n 50 -v
```

Checked on localhost against a scratch echo server (10-22-2026): a 1473-size sweep all answered; a server dropping every
tenth datagram reported 5 of 50 lost and FAIL; one corrupting every seventh reported 5 mismatches and FAIL. Not yet run
against the board.

---

## 6. Limitations

| Item | Behaviour |
|---|---|
| One socket or all | the selection is one socket index or SOCKET_ANY, not a set |
| Reply path | the reply is always addressed from the metadata (sender's IP, port, MAC); the socket's remote registers are not used |
| Payload | echoed unchanged up to 1472 bytes (the socket layer's limit) |

## 7. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version |
