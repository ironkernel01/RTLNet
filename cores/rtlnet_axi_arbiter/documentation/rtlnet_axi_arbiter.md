# rtlnet_axi_arbiter — N:1 AXI4 arbiter for the DDR3 port

| Item | Value |
|---|---|
| Core | `rtlnet_axi_arbiter` |
| Document revision | 11-09-2026 |
| Language | SystemVerilog-2012 (RTL, benches), C11 (driver) |
| Position | between the DMA masters and the CPU caches and the memory-controller AXI port (`documentation/gige.md` sections 5.1, 6, 7) |
| Register map revision | `VERSION` = `0x11092026`, `ID` = `0x41524254` ("ARBT") |
| Verification | Active-HDL 11.1: `tb_rtlnet_axi_arbiter` (8 configurations + negative control); host driver test |
| Synthesis | Vivado 2026.1 out of context, xc7a200tsbg484-1: PASS, 0 critical warnings; 1374 LUT, 1042 FF, 0 BRAM (3 masters, 128-bit, no narrow master) |

The arbiter shares the one AXI4 port of the DDR3 controller between up to eight masters. Arbitration is per transaction
and separate for writes and reads. A burst the memory controller cannot execute (not INCR, not full width unless the master is in `NARROW_MASK`, crossing a
4 KiB boundary) is never forwarded: the arbiter answers it with SLVERR and counts it.

Contents: 1 interface, 2 arbitration, 3 burst rules and error responses, 4 registers, 5 clocks and crossings,
6 resources, 7 verification, 8 integration guide, 9 limitations.

---

## 1. Interface

### 1.1 Ports

All data ports are packed vectors, master `i` at `[i*W +: W]`, on one clock.

| Group | Ports | Domain | Rule |
|---|---|---|---|
| clock, reset | `clk`, `resetn`, `s_axi_aclk`, `s_axi_aresetn` | `clk`, `s_axi_aclk` | synchronous, active low; the two resets release from one assertion |
| master AW | `s_awid`, `s_awaddr`, `s_awlen[7:0]`, `s_awsize[2:0]`, `s_awburst[1:0]`, `s_awvalid`; out `s_awready` | `clk` | no lock, cache, prot, qos, region or user |
| master W | `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`; out `s_wready` | `clk` | beats follow the AW order of the arbiter |
| master B | out `s_bid`, `s_bresp[1:0]`, `s_bvalid`; in `s_bready` | `clk` | the master's own ID |
| master AR | `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arvalid`; out `s_arready` | `clk` | |
| master R | out `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`; in `s_rready` | `clk` | the master's own ID |
| memory AW | out `m_axi_awid[ID_W+IDX_W-1:0]`, `m_axi_awaddr`, `m_axi_awlen`, `m_axi_awsize`, `m_axi_awburst`, `m_axi_awvalid`; in `m_axi_awready` | `clk` | registered; `awlock` 0, `awcache` 4'b0011, `awprot` 3'b000, `awqos` 0 |
| memory W | out `m_axi_wdata`, `m_axi_wstrb`, `m_axi_wlast`, `m_axi_wvalid`; in `m_axi_wready` | `clk` | head master's beat, valid held until ready |
| memory B | in `m_axi_bid`, `m_axi_bresp`, `m_axi_bvalid`; out `m_axi_bready` | `clk` | master index in the upper ID bits |
| memory AR, R | as AW and for R as B | `clk` | `arlock`, `arcache`, `arprot`, `arqos` as AW |
| registers | `s_axi_aw*`, `s_axi_w*`, `s_axi_b*`, `s_axi_ar*`, `s_axi_r*` (AXI4-Lite, 12-bit address, 32-bit data) | `s_axi_aclk` | 4 KiB window, crossing in section 5 |
| status | `err_irq` | `clk` | level, high while `STATUS.ERR` is set |

### 1.2 Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `NUM_MASTERS` | 3 | masters, 1..8 (`$fatal` outside) |
| `ADDR_W` | 32 | address width, 12..64 |
| `DATA_W` | 128 | 32, 64 or 128 (`$fatal` otherwise); a beat is `DATA_W/8` bytes |
| `ID_W` | 4 | master-side ID width, 1..15; the memory-side ID is `ID_W + IDX_W` bits |
| `HIGH_PRIO_MASK` | `'b1` | masters that win over the round-robin group |
| `NARROW_MASK` | `'0` | masters whose bursts may use any `AxSIZE` up to the full width (a write-through CPU cache issues 32-bit stores); the other masters must use the full width |
| `MAX_OUTSTANDING` | 8 | bursts in flight per direction, whole arbiter, 1..255 |

`IDX_W` = `$clog2(NUM_MASTERS)`, at least 1; the master index is in the upper ID bits.

---

## 2. Arbitration

Write and read arbitrate independently, once per transaction, on the AW and AR channel.

1. A master that requests and is not blocked (section 3) takes part.
2. If any high-priority master (`HIGH_PRIO_MASK`) requests, the lowest-index one wins.
3. Otherwise a round-robin pointer picks the first requesting master at or after it. The pointer moves to the master
   after each round-robin grant; a high-priority grant does not move it.
4. A grant waits while the window is closed: for writes, the W-order queue (depth `MAX_OUTSTANDING`) is full or
   `MAX_OUTSTANDING` writes are in flight; for reads, `MAX_OUTSTANDING` reads are in flight. The memory-side AW
   (AR) register must also be free or accepted in the same clock.

A granted legal burst is registered into the memory-side AW (AR) port with the master index added to the upper ID bits.
One AW (AR) is accepted per clock.

Write data: the granted master's index is pushed into the W-order queue at the AW grant. The W channel connects to the
master at the head of that queue until its WLAST beat is accepted, then the entry pops. There is no W interleaving; a
master may present W before its AW is granted and waits.

Responses: B and R are routed by the upper ID bits and carry the master's original ID. The memory controller must
answer in order of acceptance for each ID (it does for the DDR3 controller).

Wait cycles: a clock with `awvalid` or `arvalid` high and not granted counts in the master's `WAIT_CYCLES`.

Starvation: a high-priority master that requests continuously holds off the round-robin group by design. Within the
round-robin group a waiting master sees at most `NUM_MASTERS - 1` grants of other round-robin masters.

---

## 3. Burst rules and error responses

Checked on every granted AW and AR:

| Rule | Legal value |
|---|---|
| burst | INCR (`2'b01`) |
| size | master not in `NARROW_MASK`: `log2(DATA_W/8)`, a full-width beat; master in `NARROW_MASK`: any `AxSIZE` from 0 up to `log2(DATA_W/8)` |
| 4 KiB boundary | `addr[11:0] + (len + 1) * 2^AxSIZE <= 4096`, with the burst's own size (full-width masters: `2^AxSIZE` = `DATA_W/8`) |

A narrow transfer is forwarded unchanged (size, strobes, address); the memory controller places the data on the byte
lanes of the beat address. Narrow single beats and bursts from a write-through data cache take this path. Without the
mask bit such a store is answered SLVERR and dropped.

An illegal burst is not forwarded. The arbiter takes the AW (AR) and answers it itself:

- Write: the W beats up to WLAST are accepted and discarded (in the W-order position of the AW), then BRESP = SLVERR
  with the burst's ID.
- Read: `len + 1` beats with RRESP = SLVERR, RDATA 0, RLAST on the last, with the burst's ID.

The answer is delivered after every earlier forwarded transaction of that master in the same direction has been
answered. Until then the master's further AW (AR) are not arbitrated, so same-ID order holds and no forwarded response of
that master can collide with the answer. Each illegal burst counts once in the master's `ERRORS`, sets the sticky
`STATUS.ERR` and drives `err_irq` high. In simulation a `$error` reports the master index, address, len, size and burst.

Overflow of every queue and counter is gated in logic; a simulation check reports an attempt.

---

## 4. Registers

12-bit address. Offsets are defined in `driver/rtlnet_axi_arbiter.h`; the RTL (`hdl/rtlnet_axi_arbiter_regs.sv`) mirrors
them. Counters are 32-bit, wrap, reset to 0 and clear on `CTRL.CNT_CLEAR`. Writes are full-word only (a partial write is
answered OKAY and ignored). Undefined offsets read 0 and ignore writes.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | 0x41524254 | "ARBT" |
| 0x004 | `VERSION` | RO | 0x11092026 | register map date code |
| 0x008 | `CAPS` | RO | build | `[3:0]` NUM_MASTERS, `[11:4]` DATA_W/8, `[15:12]` ID_W, `[23:16]` MAX_OUTSTANDING, `[31:24]` HIGH_PRIO_MASK |
| 0x00C | `CTRL` | WO | 0 | `[16]` CNT_CLEAR (self-clearing, reads 0; clears every counter, not `STATUS.ERR`) |
| 0x010 | `STATUS` | RO, ERR W1C | 0 | `[0]` ERR sticky, write 1 to clear (a new error in the same clock keeps it set); `[1]` write in flight; `[2]` read in flight |
| 0x014 | `NARROW` | RO | build | `[7:0]` NARROW_MASK (the `CAPS` word has no free bits; undefined bits read 0) |

Per master `n` at `0x100 + 0x20 * n` (`n` below NUM_MASTERS; other windows read 0):

| Offset | Name | Counts |
|---:|---|---|
| +0x00 | `AW_BURSTS` | legal write bursts forwarded to the memory controller |
| +0x04 | `AR_BURSTS` | legal read bursts forwarded |
| +0x08 | `W_BEATS` | write data beats forwarded |
| +0x0C | `R_BEATS` | read data beats returned by the memory controller (SLVERR beats not counted) |
| +0x10 | `ERRORS` | illegal bursts answered by the arbiter |
| +0x14 | `WAIT_CYCLES` | clocks with `awvalid` or `arvalid` high and not granted |

"Write in flight" and "read in flight" are set from the grant of a burst (forwarded or illegal) until its response is
delivered. Driver: `rtlnet_axi_arbiter_probe`, `_read_counters`, `_clear`, `_err_status`, `_err_clear`.

---

## 5. Clocks and crossings

All arbitration and data logic is in `clk` (the memory-controller user clock, 100 MHz). The register file is in `clk`
too. The CPU register port is on `s_axi_aclk` behind `rtlnet_axil_cdc` (whole-transaction toggle crossing, constrained
by `scripts/rtlnet_constrain_cdc.tcl`) and `rtlnet_axil_slave`, the same pattern as `rtlnet_udp_echo`. `err_irq` is a
`clk` flop output; a consumer in another domain synchronizes it. Both resets must come from one assertion. The core has
no other crossing.

---

## 6. Resources

Vivado 2026.1, out-of-context synthesis, xc7a200tsbg484-1 (`scripts/rtlnet_synth_check.tcl`), 3 masters, 128-bit data,
`MAX_OUTSTANDING` 8:

| Resource | Used |
|---|---|
| Slice LUT | 1365 (1.01 %) |
| Slice register | 1047 (0.39 %) |
| Block RAM | 0 |

The W-order queue is a shift queue in flops (8 entries of 4 bits); it is deliberately not a RAM. The data paths are
combinational multiplexers from the packed vectors to the registered memory-side AW/AR ports and the memory-side W
port; the W mux is the widest (`NUM_MASTERS` x `DATA_W`).

---

## 7. Verification

`tb_rtlnet_axi_arbiter` drives `NUM_MASTERS` bench masters (random legal bursts, several IDs, random strobes) through
the arbiter into `rtlnet_tb_axi4_mem` (`cores/rtlnet_common/testbench`, the AXI4 memory model for every DDR3 bench; it
checks valid/payload stability, WLAST, 4 KiB, INCR and full width on its input). Registers are read through
`rtlnet_tb_axil_master` on a 7.3 ns clock against the 10 ns data clock. A reference memory in the bench predicts every
read beat (writes land in it when their B arrives; a master never overlaps its own outstanding bursts, the shared
region is written only in a fill phase).

| Group | Proves |
|---|---|
| registers | ID, VERSION, CAPS and NARROW for the configuration, reset values, undefined offsets and the window above NUM_MASTERS read 0, read-only registers ignore writes, a partial write to CTRL does nothing |
| data integrity | at least 2400 legal bursts per configuration (len 0..255, boundary-ending and page-filling bursts, own and shared regions), zero read mismatches; saturated and with random gaps |
| ID routing | every B and R reaches its master with the right ID, per-ID order |
| W order | each W beat at the memory port equals the pattern of its own burst; AW, W and AR streams at the memory port equal the grant order |
| priority | a high-priority master is granted whenever it requests; the lowest high-priority index wins |
| round robin | grants of other round-robin masters seen by a waiting master, at most `NUM_MASTERS - 1` |
| limits | in flight per direction never above `MAX_OUTSTANDING`, at the master side and at the memory port |
| narrow masters | the narrow configurations: 40 % of a narrow master's legal bursts use a size below the full width (size-aligned start, strobes limited to the active byte lanes, single beats and bursts, some ending exactly on the 4 KiB boundary by their own size); the reference memory and the memory model follow the burst's own size; directed narrow single beats and bursts; a narrow burst crossing 4 KiB by its own size is answered SLVERR (read and write) and never reaches the memory model; the `NARROW` register |
| illegal bursts | FIXED, WRAP, narrow (for masters outside `NARROW_MASK`), 4 KiB crossing, read and write, each after 3 outstanding legal bursts of the same master and followed by 2; never reaches the memory model; SLVERR of the right length after the earlier answers; ERRORS, `STATUS.ERR` sticky, `err_irq`, write-1-to-clear (writing 0 to bit 0 does not clear); then 15 % random illegal bursts in the legal traffic of all masters |
| counters | all six counters of every master against the bench's own counts after each phase, CNT_CLEAR, `STATUS` in-flight bits |
| reset | reset in the middle of traffic (bursts in flight), registers and `err_irq` back to 0, then clean traffic |

Results (11-09-2026), `tb_rtlnet_axi_arbiter` via `scripts/rtlnet_run_sim.ps1` (defines in
`testbench/regression.txt`):

| Tag | Masters | Data | Latency, gaps | Result |
|---|---|---|---|---|
| `nm3_dw128_lat0` | 3 | 128 | 0, none | `TEST PASS: tb_rtlnet_axi_arbiter checks=321066` |
| `nm3_dw128_lat20` | 3 | 128 | 20, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=407074` |
| `nm1_dw128_lat20` | 1 | 128 | 20, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=347401` |
| `nm5_dw64_lat0` | 5 (HP mask 0x09) | 64 | 0, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=571462` |
| `nm5_dw128_lat20` | 5 (HP mask 0x09) | 128 | 20, none | `TEST PASS: tb_rtlnet_axi_arbiter checks=365260` |
| `nm3_dw64_lat20` | 3 | 64 | 20, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=502231` |
| `nm3_dw128_nar2` | 3 (master 1 narrow, `NARROW_MASK` 0x2) | 128 | 20, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=438434` |
| `nm1_dw128_nar1` | 1 (narrow, `NARROW_MASK` 0x1) | 128 | 0, none | `TEST PASS: tb_rtlnet_axi_arbiter checks=284380` |
| `neg` | 3 | 128 | `+INJECT_FAILURE` | `TEST FAIL: tb_rtlnet_axi_arbiter fails=1 checks=30167` as required |

Measured in the runs: in flight reaches `MAX_OUTSTANDING` (8) in both directions at the master side and at the memory
port; the worst round-robin wait is 1 grant (3 masters), 2 grants (5 masters, limit 4).

Mutations, each failing the bench (RTL restored afterwards); first the full-width set: B routed to master 0 (4405 fails), round-robin pointer
frozen (master 2 waited 160 grants), high priority ignored (1668), 4 KiB check removed (1877), in-flight limit removed
(2443), W order taken from the second queue entry (10807), illegal answer before earlier writes complete (34),
illegal read one beat too long (953). Narrow set (`nm3_dw128_nar2` and `nm1_dw128_nar1`): 4 KiB check removed (1835 and 423 fails), 4 KiB check skipped for narrow masters only (1873 and 423), 4 KiB span computed with the full-width size (52019 fails in `nm3_dw128_nar2`).

Driver: `testbench/test_rtlnet_axi_arbiter_driver.c` runs the driver against a register model (read-only header and
counters, self-clearing CNT_CLEAR, write-1-to-clear ERR, undefined offsets 0):
`DRIVER TEST PASS: rtlnet_axi_arbiter checks=15` (host gcc 10.0.0 from the AMD install,
`-std=c11 -Wall -Wextra -Werror`).

Synthesis: `rtlnet_synth_check: PASS rtlnet_axi_arbiter`, 0 critical warnings.

The bench sets `dut.sim_quiet_illegal` so the illegal-burst report is a note and the log has no error lines; with
`+ARB_SHOW_ERRORS` the report is the `$error` described in section 3 (checked once:
`illegal write burst master 0 addr 0x42f0 len 1 size 4 burst 0`).

Run: `powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_axi_arbiter -Filelist cores/rtlnet_axi_arbiter/testbench/tb_rtlnet_axi_arbiter.f -Tag <tag> -Defines <defines of the tag>`.

---

## 8. Integration guide

To attach a new master:

1. Raise `NUM_MASTERS` (at most 8) and widen the packed vectors: the new master is the next slice of every `s_*` port.
   Its index in the upper memory-side ID bits is its slice number.
2. Issue only INCR bursts of full width (`AxSIZE` = `log2(DATA_W/8)`), none crossing a 4 KiB boundary. Split a longer
   transfer at the boundary in the DMA. A master that needs narrow transfers (a CPU cache) gets its bit in
   `NARROW_MASK`; its bursts must still be INCR and not cross a 4 KiB boundary by their own size.
3. Use any `ID_W`-bit IDs. Responses for one ID arrive in order; the master may keep several IDs outstanding.
4. A master may raise `wvalid` before its AW is granted; it must hold valid and payload until ready, as AXI requires.
5. Decide priority: set the master's bit in `HIGH_PRIO_MASK` only for a stream that must not wait (the capture writer);
   all other masters share the round-robin slots.
6. Read `ERRORS` and `STATUS.ERR` after bring-up; a non-zero count is a DMA address or length bug. A master that
   receives SLVERR must treat its burst as not executed.
7. Map the 4 KiB register window in the CPU address map and call `rtlnet_axi_arbiter_probe` with its base address.

The memory-controller wrapper connects to the `m_axi_*` ports; widths follow `ID_W + IDX_W`.

---

## 9. Limitations

- INCR bursts only, full width except for masters in `NARROW_MASK`; no FIXED, WRAP, exclusive (lock) or QoS transfers.
- Address alignment is not checked; the memory controller handles an unaligned start.
- A master with an unanswered illegal burst is not arbitrated in that direction until the answer is delivered.
- Grants are one per clock and per direction; a legal grant needs the memory-side register free or accepted that clock.
- A continuously requesting high-priority master can starve the round-robin group.
- The memory controller must return responses in order per ID (reordering across different IDs is allowed).
- No W-order skid: a master's W beat is accepted only when the memory controller accepts it (legal burst) or at once
  (illegal burst).
- Resets of the two clock domains must come from one assertion.
