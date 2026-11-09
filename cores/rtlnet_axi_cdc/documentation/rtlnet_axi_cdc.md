# rtlnet_axi_cdc — AXI4 clock-domain bridge

| Item | Value |
|---|---|
| Core | `rtlnet_axi_cdc` (with `rtlnet_axi_cdc_ser`, `rtlnet_axi_cdc_des`) |
| Document revision | 11-09-2026 |
| Language | SystemVerilog-2012 |
| Position | between an AXI4 master in one clock and an AXI4 slave in an unrelated clock: the CPU cache port (`cpu_clk`) into the DDR3 controller (`ui_clk`), later the H.264 engine DMA (150 MHz) into `ui_clk` |
| Verification | Active-HDL: `tb_rtlnet_axi_cdc`, 10 configurations plus a negative control |
| Synthesis | Vivado 2026.1 out of context, xc7a200tsbg484-1: 0 critical warnings; 863 LUT (320 as distributed RAM), 1207 FF, 3 BRAM tiles (128-bit, `ID_W` 2, `ADDR_W` 29, `MAX_BURST_BEATS` 16) |

The core carries the five AXI4 channels (AW, W, B, AR, R) across two clocks of any frequency and any phase relation.
Each channel is one `rtlnet_packet_fifo`; those FIFOs are the only crossings. A burst is stored whole in the source clock
and released to the destination clock when complete.

---

## 1. Interface

### 1.1 Ports

| Group | Ports | Domain |
|---|---|---|
| slave clock, reset | `s_clk`, `s_resetn` | `s_clk`, synchronous, active low |
| slave AW | `s_axi_awid`, `awaddr`, `awlen[7:0]`, `awsize[2:0]`, `awburst[1:0]`, `awlock`, `awcache[3:0]`, `awprot[2:0]`, `awqos[3:0]`, `awvalid`; out `awready` | `s_clk` |
| slave W | `s_axi_wdata`, `wstrb`, `wlast`, `wvalid`; out `wready` | `s_clk` |
| slave B | out `s_axi_bid`, `bresp[1:0]`, `bvalid`; in `bready` | `s_clk` |
| slave AR | as AW with `ar` prefix | `s_clk` |
| slave R | out `s_axi_rid`, `rdata`, `rresp[1:0]`, `rlast`, `rvalid`; in `rready` | `s_clk` |
| master clock, reset | `m_clk`, `m_resetn` | `m_clk`, synchronous, active low |
| master AW, W, B, AR, R | the same signals with the `m_axi_` prefix, directions as an AXI4 master | `m_clk` |

All fields are carried unchanged, `AxSIZE`, `AxBURST`, `AxLOCK`, `AxCACHE`, `AxPROT` and `AxQOS` included. There is no
`AxREGION` and no user signal.

### 1.2 Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_W` | 29 | address width |
| `DATA_W` | 128 | 32, 64 or 128 (`$fatal` otherwise) |
| `ID_W` | 2 | ID width, 1..32 |
| `MAX_BURST_BEATS` | 16 | longest burst carried in beats (`AxLEN` + 1), 1..256 |
| `AW_RAM_STYLE`, `B_RAM_STYLE`, `AR_RAM_STYLE` | `"distributed"` | FIFO storage, `"block"` or `"distributed"` |
| `W_RAM_STYLE`, `R_RAM_STYLE` | `"block"` | same, for the data FIFOs |
| `AW_FIFO_KB`, `B_FIFO_KB`, `AR_FIFO_KB`, `W_FIFO_KB`, `R_FIFO_KB` | 1 | storage per FIFO in kilobytes (128 words of 73 bits per KB) |

Sizing rules, all checked at elaboration (`$fatal`):

* A W or R burst occupies `WORDS * MAX_BURST_BEATS` words, rounded up to a power of two (the slot). The FIFO needs at
  least two slots: `W_FIFO_KB * 128 >= 2 * slot`. `WORDS` is 1 for 32 and 64-bit data and 2 for 128-bit data (a W beat
  is `DATA_W + DATA_W/8` bits, an R beat `DATA_W + ID_W + 2` bits, 72 payload bits per word).
* Default 128-bit, 16 beats: slot 32 words, 1 KB gives 4 slots. 128-bit with 256 beats: slot 512 words, 8 KB gives 2
  slots.
* AW, AR and B beats are one-word frames while `ADDR_W + ID_W + 25 <= 72` (default: 56 bits) and use a 2-word slot, so 1
  KB holds 64 queued requests. A wider address (for example `ADDR_W` 64) uses two words per beat; the FIFO sizes follow.
* A burst longer than `MAX_BURST_BEATS` is not supported: a simulation `$fatal` at AW or AR, and in hardware the FIFO
  would drop the frame. The CPU use on this board is 128-bit with 1-beat (I-cache line) and 4-beat bursts, so the
  defaults carry it with margin.

---

## 2. Behaviour

### 2.1 Structure

```
s_clk                                         m_clk
AW  ser -> u_aw_fifo ------------------------> des -> AW
W   ser -> u_w_fifo  (frame ends on WLAST) --> des -> W
AR  ser -> u_ar_fifo ------------------------> des -> AR
B   des <- u_b_fifo  <------------------------ ser <- B
R   des <- u_r_fifo  (frame ends on RLAST) <-- ser <- R
```

`rtlnet_axi_cdc_ser` turns a beat into words of `{keep[7:0], data[63:0]}` in the clock of the writing side;
`rtlnet_axi_cdc_des` rebuilds the beat from the words in the clock of the reading side. Both are single-clock logic.
The FIFO word format is the `rtlnet_packet_fifo` stream format; the core ties `s_bad` low.

### 2.2 Ordering

Each channel is one in-order queue, so every ordering AXI requires is kept, per ID and across IDs: AW, W and AR leave in
the order they entered, and B and R return in the order the master-side slave answers them. The core does not reorder
and does not interleave read data of different bursts. W data may lead its AW (and may follow it); the two channels are
independent queues. No ordering between reads and writes is promised or needed.

### 2.3 Back pressure and store and forward

* A burst is committed to the destination clock on its last beat (`WLAST`, `RLAST`), so the destination sees a whole
  burst. The write side of a FIFO stalls only between frames and only while every slot is full; a burst in progress is
  never stalled.
* A slot returns to the writer after the reader accepted its last beat, so a stalled reader backs the writer up through
  `ready`. Nothing is dropped.
* The core does not check that `WLAST` agrees with `AWLEN`. A W burst longer than the slot is a simulation `$fatal`.

### 2.4 Reset

Both resets release from one assertion. A reset during traffic empties every FIFO and holding register: queued
requests, data and responses are discarded and transactions in flight are lost, so the AXI master on the slave side must be
reset together with the core. Resetting one side only is not supported.

---

## 3. Latency and throughput

Measured in the bench with an idle bridge and a zero-latency memory model (`s_clk` and `m_clk` both 100 MHz, 1.37 ns
phase offset; the result moves by one clock with the phase):

| Path | Time | Clocks (10 ns) |
|---|---|---|
| AW, first beat `s_axi_awvalid`/`awready` to `m_axi_awvalid` with `awready` | 58.6 ns | about 6 |
| AR, same | 58.6 ns | about 6 |
| W, 1-beat burst, handshake to `m_axi_wvalid` | 78.6 ns | about 8 (store and forward, 2 words) |
| B, `m_axi_bvalid` handshake to `s_axi_bvalid` handshake | 51.4 ns | about 5 |
| R, 1-beat burst, `m_axi_rvalid` handshake to `s_axi_rvalid` handshake | 71.4 ns | about 7 |
| read round trip, `s_axi_arvalid` to `s_axi_rvalid` | 140 ns | about 14 including the memory model |

A path has these contributions: 1 clock in `rtlnet_axi_cdc_ser`, 1 to write the RAM and publish the frame count, 2 to 3
destination clocks in the Gray synchronizer, 1 to 2 to read the FIFO RAM, 1 in `rtlnet_axi_cdc_des`, plus
`WORDS - 1` clocks to gather a beat. A multi-beat burst adds its length in words once (store and forward): a 4-beat
128-bit write adds 8 source clocks before the destination sees the first beat, a 4-beat read adds 8 destination clocks.

Throughput of the data channels is one beat per `WORDS` clocks of the slower clock when the FIFOs do not fill (128-bit
data: one beat per 2 clocks, 1.6 GB/s at 100 MHz); the FIFOs add one idle clock between frames. Address and response
channels take one beat per about 2 to 3 clocks.

---

## 4. Clock-domain crossings and constraints

The core contains no crossing other than the five `rtlnet_packet_fifo` instances, and no combinational path between
the clocks. Every crossing falls under class `fifo` of `scripts/rtlnet_constrain_cdc.tcl`, which matches
`rtlnet_packet_fifo` instances named `u_*_fifo`.

| Instance | Writes in | Reads in | Class |
|---|---|---|---|
| `u_aw_fifo` | `s_clk` | `m_clk` | fifo |
| `u_w_fifo` | `s_clk` | `m_clk` | fifo |
| `u_ar_fifo` | `s_clk` | `m_clk` | fifo |
| `u_b_fifo` | `m_clk` | `s_clk` | fifo |
| `u_r_fifo` | `m_clk` | `s_clk` | fifo |

For each instance the script bounds `s_gray` to `s_gray_m1`, `m_gray` to `m_gray_s1` and the event toggles
`events_s` to `events_m1`, and creates the report_cdc waivers for exactly those registers. A build that contains one
core instance sets `::rtlnet_cdc_expect {fifo 5}` (plus its other crossings). The core uses no `sync`, `reset`, `gray`
or `axil_cdc` instance and needs no new constraint, class or waiver. The RAM inside each FIFO is read and written in
different clocks; the FIFO's slot ownership (frame counters) keeps the two sides off the same slot, which is why the
packet FIFO needs only the pointer constraints.

The FIFO overflow and bad-frame event pulses are not brought out; in simulation any pulse is a `$fatal`.

---

## 5. Resources

Vivado 2026.1, out-of-context synthesis, xc7a200tsbg484-1 (`scripts/rtlnet_synth_check.tcl`), 128-bit data, `ID_W` 2,
`ADDR_W` 29, `MAX_BURST_BEATS` 16, defaults (W and R in block RAM, AW, AR and B in distributed RAM, 1 KB each):

| Resource | Used |
|---|---|
| Slice LUT | 863 (320 as distributed RAM) |
| Slice register | 1207 |
| Block RAM | 3 tiles (2 RAMB36, 2 RAMB18) |
| Critical warnings | 0 |

---

## 6. Verification

`cores/rtlnet_axi_cdc/testbench/tb_rtlnet_axi_cdc.sv` drives random AXI4 traffic into the slave port and
`rtlnet_tb_axi4_mem` on the master port, with random valid and ready gaps on both sides and every beat
checked at both ports.

| Check | Detail |
|---|---|
| Write path | every AW, W beat and AR leaving the master port equals the beat that entered, all fields and strobes, in order |
| Write result | memory model contents equal a reference memory with strobes merged; counters equal the issued counts |
| B | one B per AW, ID and OKAY, in order |
| R | every beat's ID, data, RESP and RLAST against the preload or the written reference |
| Traffic | at least 2000 transactions per configuration; bursts of 1 to 16 beats; 256 beats in the big configuration; random strobes, IDs, lock/cache/prot/qos; reads and writes concurrent; W leading AW |
| Clocks | 100/100 (1.37 ns offset), 150/100, 100/150, 33/200 (`s_clk`/`m_clk`), 128-bit; the same pairs at 32-bit, with `ADDR_W` 64 for the 33/200 case (two-word AW) |

Negative control: `+INJECT_FAILURE` (`neg` entry, `expectfail`). Mutations run on 128-bit, 150/100: `WLAST` forced low
into the W frame (caught: the FIFO drops the overlong frame, simulation `$fatal`), two B ID bits swapped (caught: 601
failed checks), the beat-gather `in_ready` forced high (caught: 17467 failed checks), the packet FIFO write guard
removed (caught: overflow `$fatal`). Each source was restored byte-identical.
