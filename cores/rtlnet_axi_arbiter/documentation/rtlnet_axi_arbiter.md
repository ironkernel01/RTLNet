# rtlnet_axi_arbiter — N:1 AXI4 arbiter for the DDR3 port

| Item | Value |
|---|---|
| Core | `rtlnet_axi_arbiter` |
| Document revision | 11-12-2026 |
| Language | SystemVerilog-2012 (RTL, benches), C11 (driver) |
| Position | between the DMA masters and the CPU caches and the memory-controller AXI port |
| Register map revision | `VERSION` = `0x11092026`, `ID` = `0x41524254` ("ARBT") |
| Verification | Active-HDL 11.1: `tb_rtlnet_axi_arbiter` (16 configurations + 4 negative controls: 11 configurations and 2 controls of 11-09-2026, 5 with `ADDR_REG` 0 and 2 latency controls of 11-12-2026); host driver test |
| Synthesis | Vivado 2026.1 out of context, xc7a200tsbg484-1: PASS, 0 critical warnings; 1477 LUT, 1096 FF, 0 BRAM (3 masters, 128-bit, no narrow or WRAP master, state of 11-09-2026); section 6 has the board configuration before and after the two-clock grant of 11-12-2026 |

The arbiter shares the one AXI4 port of the DDR3 controller between up to eight masters. Arbitration is per transaction
and separate for writes and reads. A burst the memory controller cannot execute (not INCR unless the master is in `WRAP_MASK` and the burst is a legal WRAP, not full width unless the master is in
`NARROW_MASK`, crossing a 4 KiB boundary) is never forwarded: the arbiter answers it with SLVERR, counts it and captures the first one
(direction, master, address, len, size, burst type, failed rule) in read-only registers.

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
| `NARROW_MASK` | `'0` | masters whose bursts may use any `AxSIZE` up to the full width (the CPU's former write-through cache issued 32-bit stores; since 11-10-2026 the data cache is write-back and its stores are 4-beat full-width bursts, measured on the board, so the bit is a margin on the board and unused by stores); the other masters must use the full width |
| `WRAP_MASK` | `'0` | masters whose WRAP bursts of 2, 4, 8 or 16 beats at a size-aligned address are legal (the CPU caches fill a line critical word first); for every other master a WRAP is illegal |
| `MAX_OUTSTANDING` | 8 | bursts in flight per direction, whole arbiter, 1..255 |
| `ADDR_REG` | 1 | 1 = put a register slice on every master's AW and AR channel (one clock more latency per burst address; it cuts the timing paths from the masters into the grant logic); 0 = leave the slices out (the grant still takes two clocks) |

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

Two-clock grant (11-12-2026, timing). The grant is split so that no master signal reaches the output registers through the whole decision:

* With `ADDR_REG` 1 every master's AW and AR pass a register slice (`rtlnet_axi_arbiter_slice`: a main and a skid register, full throughput, the
  ready towards the master comes from a flop, nothing behind the slice depends on the master's valid or address fields in the same clock).
* Clock 1: the request mask and the pick of steps 1 to 3 run on the offered requests, the burst legality of every master's offered burst
  is evaluated beside them, and the winner's index and its legality flags are registered (the registered grant).
* Clock 2: the registered grant fires when the window of step 4 is open: counters, W-order queue push, error state and the memory-side AW (AR)
  register load from the winner's fields, the round-robin pointer moves, and the slice (or the master with `ADDR_REG` 0) receives its ready.
  A registered grant that cannot fire is chosen again from the current requests in every clock, so a high-priority master that arrives meanwhile
  still wins; once the grant fires the winner's offered burst is consumed and the next grant starts with clock 1.
* The order of grants for the same arrival order is the order of the one-clock arbiter; what changes is the time. One AW (AR) is granted per
  two clocks and direction (every burst of the encoder and the video DMA has 8 beats or more; the CPU caches issue 1- and 4-beat bursts and wait
  two clocks more per address).
* Latency from the clock a master's valid is first high to the clock the memory-side valid is first high, with the arbiter idle (measured by
  the bench, both directions, every master): **3 clocks with `ADDR_REG` 1, 2 with `ADDR_REG` 0**; the arbiter before 11-12-2026 took 1.

Write data: the granted master's index is pushed into the W-order queue at the AW grant. The W channel connects to the
master at the head of that queue until its WLAST beat is accepted, then the entry pops. There is no W interleaving; a
master may present W before its AW is granted and waits.

Responses: B and R are routed by the upper ID bits and carry the master's original ID. The memory controller must
answer in order of acceptance for each ID (it does for the DDR3 controller).

Wait cycles: a clock with a request inside the arbiter (the output of the slice with `ADDR_REG` 1, the master's `awvalid` or `arvalid` with 0) high and not granted counts in the master's `WAIT_CYCLES`; a request has at least one such clock, because the grant takes two.

Starvation: a high-priority master that requests continuously holds off the round-robin group by design. Within the
round-robin group a waiting master sees at most `NUM_MASTERS - 1` grants of other round-robin masters.

---

## 3. Burst rules and error responses

Checked on every granted AW and AR:

| Rule | Legal value |
|---|---|
| burst | INCR (`2'b01`); for a master in `WRAP_MASK` also WRAP (`2'b10`) with `len + 1` of 2, 4, 8 or 16 beats and a start address aligned to `2^AxSIZE` |
| size | master not in `NARROW_MASK`: `log2(DATA_W/8)`, a full-width beat; master in `NARROW_MASK`: any `AxSIZE` from 0 up to `log2(DATA_W/8)` |
| 4 KiB boundary | INCR: `aligned_start + (len + 1) * 2^AxSIZE <= 4096`, with `aligned_start = addr[11:0]` rounded down to `2^AxSIZE` and the burst's own size (full-width masters: `2^AxSIZE` = `DATA_W/8`). AXI places the bytes of an INCR burst between the size-aligned start and the end of the last beat; only the first beat may start unaligned (the strobes select its lanes) and every later beat is aligned. An unaligned start therefore adds nothing to the span. Accepted: size 2, len 0 at 0xFFD or 0xFFF; size 2, len 3 at 0xFF1 (aligned start 0xFF0, ends exactly at 0x1000); size 4 (128-bit), len 0 at 0xFF1. Rejected: size 2, len 1 at 0xFFD (aligned start 0xFFC + 8 > 4096); size 4, len 1 at 0xFF1. Not applied to a WRAP: a legal WRAP container is at most 16 beats * 16 bytes = 256 bytes, a power of two aligned to its own size, so it lies inside one 4 KiB page and the rule cannot be violated |

A narrow transfer is forwarded unchanged (size, strobes, address); the memory controller places the data on the byte
lanes of the beat address. Narrow single beats and bursts from a write-through data cache take this path. Without the
mask bit such a store is answered SLVERR and dropped.

A legal WRAP is forwarded unchanged (address, len, size, burst type); the memory controller wraps the beat address inside the
`len + 1` beat container. The size rule applies to a WRAP as to an INCR burst (full width unless the master is in `NARROW_MASK`).
A WRAP stays illegal for a master outside `WRAP_MASK`, with `len` 0 (one beat), `len` 2 (three beats) or any other length
that is not 1, 3, 7 or 15, and at a start address not aligned to the size. The failed-rule flags of the capture report a bad WRAP
as a burst-type failure.

An illegal burst is not forwarded. The arbiter takes the AW (AR) and answers it itself:

- Write: the W beats up to WLAST are accepted and discarded (in the W-order position of the AW), then BRESP = SLVERR
  with the burst's ID.
- Read: `len + 1` beats with RRESP = SLVERR, RDATA 0, RLAST on the last, with the burst's ID.

The answer is delivered after every earlier forwarded transaction of that master in the same direction has been
answered. Until then the master's further AW (AR) are not arbitrated, so same-ID order holds and no forwarded response of
that master can collide with the answer. Each illegal burst counts once in the master's `ERRORS`, sets the sticky
`STATUS.ERR` and drives `err_irq` high. In simulation a `$error` reports the master index, address, len, size, burst and the failed-rule flags.

### 3.1 First-illegal-burst capture

The first illegal AW or AR after a clear is held in `CAP_INFO`, `CAP_ADDR` and `CAP_ADDR_HI` until `STATUS.ERR` is cleared
(write 1) or `CTRL.CNT_CLEAR` is written. Later illegal bursts are counted in `ERRORS` and do not overwrite the capture.
An illegal burst in the clock of a clear is captured as the first of the next period. When an illegal AW and AR are granted
in one clock the AW is captured (the AR is counted). `AxCACHE` is not captured: the arbiter has no `AxCACHE` input (it drives a constant on the memory side).

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
| 0x018 | `WRAP` | RO | build | `[7:0]` WRAP_MASK |
| 0x040 | `CAP_INFO` | RO | 0 | first illegal burst: `[0]` valid, `[1]` direction (0 AW write, 1 AR read), `[4:2]` master, `[7:5]` AxSIZE, `[15:8]` AxLEN, `[17:16]` AxBURST (0 FIXED, 1 INCR, 2 WRAP), `[20:18]` failed rules: bit 18 burst type, bit 19 size, bit 20 4 KiB (several may be set); 0 when nothing is captured; cleared by `STATUS.ERR` (W1C) or `CTRL.CNT_CLEAR` |
| 0x044 | `CAP_ADDR` | RO | 0 | captured address `[31:0]` |
| 0x048 | `CAP_ADDR_HI` | RO | 0 | captured address `[63:32]` (0 for a 32-bit address bus) |

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
delivered. Driver: `rtlnet_axi_arbiter_probe`, `_read_counters`, `_clear`, `_err_status`, `_err_clear`, `_read_capture`.
The firmware command `show ddr` prints the wrap mask and the capture (`First illegal   : none captured`, or direction, master,
address, len, size, burst and the failed rules).

---

## 5. Clocks and crossings

All arbitration and data logic is in `clk` (the memory-controller user clock, 90 MHz on the Nexys Video; `AXIL_SYNC` 1 there, so the register window runs on `clk` without a clock crossing). The register file is in `clk`
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

(State of 11-09-2026.) Board configuration (`testbench/arb_synth.tcl`: 4 masters, 29-bit address, 128-bit data, `ID_W` 2, `HIGH_PRIO_MASK` 0010, `NARROW_MASK` 0001, `WRAP_MASK` 0001,
`MAX_OUTSTANDING` 8, `clk` 90 MHz, every input and output timed against `clk`, post-synthesis estimate without placement), before and after the two-clock grant:

| Version | LUT | FF | Worst path levels | Worst slack (WNS) | Worst path |
|---|---|---|---|---|---|
| before 11-12-2026 (one-clock grant) | 1,793 | 1,225 | 14 | +0.341 ns | `rd_err_pend_reg` to `m_axi_araddr_reg/CE` (the read grant) |
| `ADDR_REG` 1 (default) | 2,072 | 1,957 | 7 | +6.313 ns | slice register to `g1_ar_fail_reg` (the legality evaluation); every other endpoint has 3 levels or fewer |
| `ADDR_REG` 0 | 1,857 | 1,237 | 4 (of the 40 worst endpoints) | +6.044 ns | register file reset to `cap_addr_q` |

The slices and the registered grant cost 279 LUT and 732 FF with `ADDR_REG` 1, 64 LUT and 12 FF with `ADDR_REG` 0. The 4 KiB check was
rewritten from `aligned_start + bytes > 4096` to the carry of `aligned_start + (len << size)` (the same predicate; the bench's own `exp_fail` agrees
in every case), which removed 3 levels from the legality path.

The W-order queue is a shift queue in flops (8 entries of 4 bits); it is deliberately not a RAM. The data paths are
combinational multiplexers from the register slices (from the packed vectors with `ADDR_REG` 0) to the registered memory-side AW/AR ports, driven by the registered grant index, and the
combinational memory-side W port; the W mux is the widest (`NUM_MASTERS` x `DATA_W`).

---

## 7. Verification

11-12-2026 (two-clock grant): the bench takes a grant from the arbiter's own fire signals (`dut.aw_fire`, `dut.ar_fire`, and the master index the arbiter chose); a descriptor waits in a per-master queue
from the handshake on the master's port (the slice accepts it, or with `ADDR_REG` 0 the grant) until its grant. Priority and round robin are checked against the requests of the clock before the fire
(what the pick saw), `WAIT_CYCLES` against the requests inside the arbiter. New directed cases (`directed_grants`): the latency of a lone burst of every master in both directions (3 or 2 clocks)
and back-to-back 8-beat bursts of every master at once with the monitors on. `TB_ADDR_REG` selects the parameter: the regression runs the 11 configurations of 11-09-2026 with `ADDR_REG` 1 and five with
`ADDR_REG` 0 (3 masters 128- and 64-bit, 5 masters, a narrow and WRAP master, 1 master), the two controls of 11-09-2026 and two latency controls (`INJECT_LATENCY` adds a clock to the expected latency: the bench must fail).
Result: `RTLNET_REGRESSION` for `axi_arbiter`: 20 passed, 0 failed.

`tb_rtlnet_axi_arbiter` drives `NUM_MASTERS` bench masters (random legal bursts, several IDs, random strobes) through
the arbiter into `rtlnet_tb_axi4_mem` (`cores/rtlnet_common/testbench`, the AXI4 memory model for every DDR3 bench; it
checks valid/payload stability, WLAST, 4 KiB, INCR and full width on its input). Registers are read through
`rtlnet_tb_axil_master` on a 7.3 ns clock against the 10 ns data clock. A reference memory in the bench predicts every
read beat (writes land in it when their B arrives; a master never overlaps its own outstanding bursts, the shared
region is written only in a fill phase).

| Group | Proves |
|---|---|
| registers | ID, VERSION, CAPS, NARROW and WRAP for the configuration, capture registers 0 after reset, reset values, undefined offsets and the window above NUM_MASTERS read 0, read-only registers ignore writes, a partial write to CTRL does nothing |
| data integrity | at least 2400 legal bursts per configuration (len 0..255, boundary-ending and page-filling bursts, own and shared regions), zero read mismatches; saturated and with random gaps |
| ID routing | every B and R reaches its master with the right ID, per-ID order |
| W order | each W beat at the memory port equals the pattern of its own burst; AW, W and AR streams at the memory port equal the grant order |
| priority | a high-priority master is granted whenever it requests; the lowest high-priority index wins |
| round robin | grants of other round-robin masters seen by a waiting master, at most `NUM_MASTERS - 1` |
| limits | in flight per direction never above `MAX_OUTSTANDING`, at the master side and at the memory port |
| narrow masters | the narrow configurations: 40 % of a narrow master's legal bursts use a size below the full width (size-aligned start, strobes limited to the active byte lanes, single beats and bursts, some ending exactly on the 4 KiB boundary by their own size); the reference memory and the memory model follow the burst's own size; directed narrow single beats and bursts; a narrow burst crossing 4 KiB by its own size is answered SLVERR (read and write) and never reaches the memory model; the `NARROW` register |
| unaligned INCR starts | 30 % of the legal INCR bursts of every master start inside their first transfer (the first beat's strobes cover only the lanes from the start address to the end of the aligned transfer; the reference memory and the memory model follow); directed accepts for narrow masters (size 2: len 0 at 0xFFD and 0xFFF, len 3 at 0xFF1) and for every master at full size (len 0 at the last word + 1, len 1 at the word before it + 1), each written with both strobe modes and read back at the same bytes and as full words; directed rejects (size 2 len 1 at 0xFFD for narrow masters, full size len 1 at the last word + 1) answered SLVERR, never forwarded; the bench's `exp_fail` and the memory model's 4 KiB check use the size-aligned start |
| illegal bursts | FIXED, WRAP, narrow (for masters outside `NARROW_MASK`), 4 KiB crossing, read and write, each after 3 outstanding legal bursts of the same master and followed by 2; never reaches the memory model; SLVERR of the right length after the earlier answers; ERRORS, `STATUS.ERR` sticky, `err_irq`, write-1-to-clear (writing 0 to bit 0 does not clear); then 15 % random illegal bursts in the legal traffic of all masters |
| WRAP (`TB_WRAP` configurations) | masters in `WRAP_MASK`: 25 % of their legal bursts are WRAP of 2, 4, 8 or 16 beats (full size; a narrow master also smaller sizes) in the random traffic, the reference memory and `rtlnet_tb_axi4_mem` (`ALLOW_WRAP`, default 0) both model the wrap addressing and the read data is checked beat by beat; directed: every length at every start offset (2 + 4 + 8 + 16 = 30 starts per size), WRAP write, WRAP read at another start and an INCR read of the whole container; directed illegal WRAPs, read and write, between legal bursts of the same master: len 0, len 2 (three beats), misaligned start (masters in the mask) and a WRAP of the legal form from a master outside the mask; SLVERR of the right length, `ERRORS`, never reaches the memory model; a WRAP from every master when `WRAP_MASK` is 0 (all other configurations, memory model `ALLOW_WRAP` 0) |
| capture | CAP_INFO and CAP_ADDR empty after reset and after a clear; the first illegal burst of every kind (FIXED, WRAP legal-form outside the mask, narrow size, 4 KiB, narrow 4 KiB, WRAP len 0, len 2, misaligned), read and write, on rotating masters, with every field and the failed-rule flags against the bench's own rule model; a second illegal burst does not replace the first; `STATUS.ERR` write 1 and `CTRL.CNT_CLEAR` clear it; the registers ignore writes; reset clears it |
| counters | all six counters of every master against the bench's own counts after each phase, CNT_CLEAR, `STATUS` in-flight bits |
| reset | reset in the middle of traffic (bursts in flight), registers and `err_irq` back to 0, then clean traffic |

Results (11-09-2026), `tb_rtlnet_axi_arbiter` via `scripts/rtlnet_run_sim.ps1` (defines in
`testbench/regression.txt`):

| Tag | Masters | Data | Latency, gaps | Result |
|---|---|---|---|---|
| `nm3_dw128_lat0` | 3 | 128 | 0, none | `TEST PASS: tb_rtlnet_axi_arbiter checks=315041` |
| `nm3_dw128_lat20` | 3 | 128 | 20, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=437171` |
| `nm1_dw128_lat20` | 1 | 128 | 20, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=361874` |
| `nm5_dw64_lat0` | 5 (HP mask 0x09) | 64 | 0, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=571431` |
| `nm5_dw128_lat20` | 5 (HP mask 0x09) | 128 | 20, none | `TEST PASS: tb_rtlnet_axi_arbiter checks=393715` |
| `nm3_dw64_lat20` | 3 | 64 | 20, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=497008` |
| `nm3_dw128_nar2` | 3 (master 1 narrow, `NARROW_MASK` 0x2) | 128 | 20, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=437307` |
| `nm1_dw128_nar1` | 1 (narrow, `NARROW_MASK` 0x1) | 128 | 0, none | `TEST PASS: tb_rtlnet_axi_arbiter checks=292292` |
| `nm3_dw128_wrap1` | 3 (master 0 in `WRAP_MASK`, masters 1 and 2 outside) | 128 | 20, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=381422` (344 legal and 24 illegal WRAP bursts) |
| `nm1_dw128_wrap1_nar1` | 1 (narrow and WRAP, the board configuration) | 128 | 0, random | `TEST PASS: tb_rtlnet_axi_arbiter checks=321590` (860 legal, 17 illegal) |
| `nm3_dw64_wrap6_nar2` | 3 (masters 1 and 2 in `WRAP_MASK`, master 1 narrow) | 64 | 20, none | `TEST PASS: tb_rtlnet_axi_arbiter checks=350984` (819 legal, 29 illegal) |
| `neg` | 3 | 128 | `+INJECT_FAILURE` | `TEST FAIL: tb_rtlnet_axi_arbiter fails=1 checks=34900` as required |
| `neg_wrap` | 3 (master 0 in `WRAP_MASK`) | 128 | `+INJECT_FAILURE` | `TEST FAIL: tb_rtlnet_axi_arbiter fails=1 checks=42468` as required |

Measured in the runs: in flight reaches `MAX_OUTSTANDING` (8) in both directions at the master side and at the memory
port; the worst round-robin wait is 1 grant (3 masters), 2 grants (5 masters, limit 4).

WRAP and capture mutations (`nm3_dw128_wrap1`, RTL restored afterwards, the unmutated run passes with checks=381422): WRAP accepted for a
master outside `WRAP_MASK` (530 fails; first "AW at the memory port with no granted write behind it"), WRAP length check removed (1551 fails),
WRAP alignment check removed (1342 fails), capture overwritten by every later illegal burst (2 fails: "stickiness: CAP_INFO keeps the first illegal burst").

Mutations, each failing the bench (RTL restored afterwards); first the full-width set: B routed to master 0 (4405 fails), round-robin pointer
frozen (master 2 waited 160 grants), high priority ignored (1668), 4 KiB check removed (1877), in-flight limit removed
(2443), W order taken from the second queue entry (10807), illegal answer before earlier writes complete (34),
illegal read one beat too long (953). Narrow set (`nm3_dw128_nar2` and `nm1_dw128_nar1`): 4 KiB check removed (1835 and 423 fails), 4 KiB check skipped for narrow masters only (1873 and 423), 4 KiB span computed with the full-width size (52019 fails in `nm3_dw128_nar2`).

Unaligned-start mutation (`nm3_dw128_nar2` and `nm1_dw128_lat0`, RTL restored afterwards): the span computed from the unaligned `addr[11:0]` again fails the bench (62232 and 58967 fails; first "write bursts in flight 9 exceed MAX_OUTSTANDING" and "master 0: legal write B resp 2"). The restored RTL passes `nm3_dw128_nar2` with checks=404467.

Driver: `testbench/test_rtlnet_axi_arbiter_driver.c` runs the driver against a register model (read-only header and
counters, self-clearing CNT_CLEAR, write-1-to-clear ERR, the capture registers, undefined offsets 0):
`DRIVER TEST PASS: rtlnet_axi_arbiter checks=21` (host gcc 10.0.0 from the AMD install,
`-std=c11 -Wall -Wextra -Werror`).

Synthesis: `rtlnet_synth_check: PASS rtlnet_axi_arbiter`, 0 critical warnings (defaults, 3 masters: 1477 LUT, 1096 FF; and the board
configuration `NUM_MASTERS=1 NARROW_MASK=1 WRAP_MASK=1`: PASS, 0 critical warnings).

The bench sets `dut.sim_quiet_illegal` so the illegal-burst report is a note and the log has no error lines; with
`+ARB_SHOW_ERRORS` the report is the `$error` described in section 3 (checked once:
`illegal write burst master 0 addr 0x42f0 len 1 size 4 burst 0`).

Run: `powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_axi_arbiter -Filelist cores/rtlnet_axi_arbiter/testbench/tb_rtlnet_axi_arbiter.f -Tag <tag> -Defines <defines of the tag>`.

---

### 7.1 Memory-controller WRAP support

The generated AMD MIG AXI slave (`boards/nexys_video/build/ip/rtlnet_ddr_mig/rtlnet_ddr_mig/user_design/rtl/axi/`, 7 series MIG v4.2) handles WRAP:

- `mig_7series_v4_2_axi_mc_cmd_translator.v` decodes INCR and WRAP in parallel and selects by `axburst[1]` (`cmd_byte_addr`, `next_pending`, `ignore_begin`, `ignore_end`),
  so WRAP (`2'b10`) reaches `mig_7series_v4_2_axi_mc_wrap_cmd.v`.
- `axi_mc_wrap_cmd` forms each command address from the start address with the 4-bit beat-index field (`axaddr[C_AXSIZE+:4]`) replaced by a counter that
  steps by `C_MC_BURST_LEN` and wraps under the mask `axlen[3:0]` (`int_addr_p = (int_addr_t & ~axlen) | (int_addr_t_inc & axlen)`). That is the AXI wrap
  for `len + 1` of 2, 4, 8 and 16 beats, critical word first, at the full data width (`C_AXSIZE` is a static parameter, the beat size of the 128-bit port).
- The same `len` and `size` rules therefore hold at the MIG as in the arbiter: lengths 1, 3, 7, 15, start aligned to the beat. A narrow WRAP is not part of the
  memory-controller port (the arbiter forwards a narrow WRAP only for a master in both `NARROW_MASK` and `WRAP_MASK`, as the bench configurations `nm1_dw128_wrap1_nar1` and `nm3_dw64_wrap6_nar2` model; the board's
  caches reach the MIG through the SmartConnect upsizer at full width).

On the board the DDR3 image boots, runs and executes `show version` with 0 illegal bursts after the change (12 per `show version` before), and the instruction
cache's critical-word-first line fills return correct code and data (the console and `net_test` pass from DDR3).

### 7.2 Board, DDR3 image (11-09-2026)

Board configuration `NUM_MASTERS` 1, `NARROW_MASK` 1, `WRAP_MASK` 1. Logs in `boards/nexys_video/build/phase0_wrap_*.txt`
(`rtlnet_nexys_video.md` section 6.9). The first-illegal-burst capture identified the cause of the illegal bursts the DDR3 image produced:

- 12 illegal bursts per `show version` before the change were WRAP line fills of the CPU caches (the hypothesis; the first capture of that run was
  not taken, the proof is the effect): with `WRAP_MASK` 1, `clear counters` followed by two `show version` leaves `errors 0` and `First illegal : none captured`
  (`phase0_wrap_show_ddr_3.txt`).
- A second source remains. After `cli_test` the capture reads `First illegal : write (AW) master 0 addr 0x000000000001CFFD len 0 size 2 burst 1 (INCR) failed: 4KiB`
  (`CAP_INFO` valid 1, direction AW, master 0, size 2, len 0, burst INCR, failed rules = 4 KiB only; `CAP_ADDR` 0x0001CFFD, `CAP_ADDR_HI` 0). The burst is a single
  32-bit-size beat at a byte address with low bits `01` at page offset 0xFFD. Its first beat covers bytes 0xFFD..0xFFF inside the page, so it is legal AXI, but the
  arbiter's 4 KiB rule computes `addr[11:0] + (len + 1) * 4` from the unaligned start address (0xFFD + 4 > 4096) and rejects it. The rule needs the size-aligned start
  address (AXI beat addresses after the first are aligned). Fixed afterwards (section 3, 4 KiB rule from the size-aligned start; bench and memory model follow).
  After the fix and a network rebuild the DDR3 image runs `cli_test`, `net_test` and `tcp_test` with arbiter `errors 0` and `First illegal : none captured`
  (`boards/nexys_video/build/phase0_unaligned_*.txt`, `rtlnet_nexys_video.md` section 6.9, Phase 0 close-out).

---

## 8. Integration guide

To attach a new master:

1. Raise `NUM_MASTERS` (at most 8) and widen the packed vectors: the new master is the next slice of every `s_*` port.
   Its index in the upper memory-side ID bits is its slice number.
2. Issue only INCR bursts of full width (`AxSIZE` = `log2(DATA_W/8)`), none crossing a 4 KiB boundary. Split a longer
   transfer at the boundary in the DMA. A master that needs narrow transfers (a CPU cache) gets its bit in
   `NARROW_MASK`; its bursts must still be INCR (or a legal WRAP, below) and not cross a 4 KiB boundary by their own size.
   A master that fills cache lines critical word first gets its bit in `WRAP_MASK`; its WRAP bursts must have 2, 4, 8 or 16 beats
   and a size-aligned start. The memory controller must implement WRAP (the AMD MIG AXI slave does: section 7.1).
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

- INCR bursts, and WRAP bursts for masters in `WRAP_MASK`; full width except for masters in `NARROW_MASK`; no FIXED, exclusive (lock) or QoS transfers.
- Address alignment is checked for a WRAP only; the memory controller handles an unaligned INCR start.
- The capture holds one burst (the first); `AxCACHE` is not captured.
- A master with an unanswered illegal burst is not arbitrated in that direction until the answer is delivered.
- Grants are one per two clocks and per direction (section 2); a legal grant needs the memory-side register free or accepted in its second clock.
- With `ADDR_REG` 0 a master must hold `AxVALID` and its address fields until the ready (AXI4 rule): the grant is registered one clock before the burst is taken.
- A continuously requesting high-priority master can starve the round-robin group.
- The memory controller must return responses in order per ID (reordering across different IDs is allowed).
- No W-order skid: a master's W beat is accepted only when the memory controller accepts it (legal burst) or at once
  (illegal burst).
- Resets of the two clock domains must come from one assertion.

## 10. Board master mix (11-10-2026)

Board configuration unchanged (`NARROW_MASK` 1, `WRAP_MASK` 1 for master 0). Beats per burst measured with the per-master counters after a 60 s 1080p30 stream: video DMA 16.0,
encoder engines 12.0 writes (ring, index record, tiles) and 8.0 reads, CPU writes 4.0 (64-byte line write-back), CPU reads 1.0 (open, see `cpu/microblaze_v_h264/documentation/rtlnet_cpu_microblaze.md` section 11). No error captured.
