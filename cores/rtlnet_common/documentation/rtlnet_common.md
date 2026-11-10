# rtlnet_common — shared primitives

| Item | Value |
|---|---|
| Core | `rtlnet_common` |
| Document revision | 10-22-2026 |
| Language | SystemVerilog-2012 |
| Technology selection | `hdl/rtlnet_technology.svh` (one include file for the whole tree) |
| Verification | Active-HDL 11.1: `tb_rtlnet_packet_fifo`, `tb_rtlnet_axil`, `tb_rtlnet_primitives` (AMD and GENERIC technologies) |

Every RTLNet core is built from these modules. They carry every clock-domain crossing, every memory and the
AXI4-Lite plumbing, so a retarget to another FPGA vendor or an ASIC touches this folder only.

## 1. Files

| File | Module / content |
|---|---|
| `rtlnet_technology.svh` | the technology selection: `RTLNET_TECH_AMD` (default), `_ALTERA`, `_LATTICE`, `_GENERIC`; derives `` `RTLNET_TARGET ``, `` `RTLNET_SYNC_ATTR ``, `` `RTLNET_RGMII_IO `` |
| `rtlnet_pkg.sv` | stream geometry, protocol numbers, `be16/be32/be48`, `keep_bytes`, `keep_mask`, `keep_through_lane`, `crc32_byte`, `crc32_bytes`, `csum_fold16`, `beat_word_sum`, `ipv4_header_checksum`, `id4`, `clog2i`, default MAC/IP |
| `rtlnet_ram_core.sv` | the one RAM: simple dual port, `RAM_STYLE` block/distributed, `READ_LATENCY` 1/2, `CLOCKING` common/independent |
| `rtlnet_shift_reg_core.sv` | the one fixed-delay shift register: AMD = LUT shift-register RAM (direct `SRLC32E` instances, cascaded, registered output); Altera MLAB / Lattice distributed / generic register array; no reset on the storage |
| `rtlnet_sync.sv` | level synchronizer, `WIDTH` chains of `STAGES` flops |
| `rtlnet_reset_sync.sv` | asynchronous-assert, synchronous-release reset (the one named asynchronous exception) |
| `rtlnet_pulse_sync.sv` | toggle event crossing |
| `rtlnet_gray_sync.sv` | coherent counter crossing (Gray code) |
| `rtlnet_axis_reg_slice.sv` | AXI4-Stream register slice, every output a flop |
| `rtlnet_packet_fifo.sv` | dual-clock whole-frame store-and-forward FIFO, `FIFO_KB` |
| `rtlnet_frame_guard.sv` | length and `tkeep` legality verdict for a packet FIFO |
| `rtlnet_axil_slave.sv` | AXI4-Lite to register strobes |
| `rtlnet_axil_cdc.sv` | AXI4-Lite clock crossing (held bundle + toggles) |
| `rtlnet_axil_decoder.sv` | 1-to-N AXI4-Lite address decoder |
| `rtlnet_common.f` | compile order |

## 2. Technology mapping

`rtlnet_technology.svh` is included by every mapped file; nothing passes a technology parameter. Select a
technology with a command-line define (`+define+RTLNET_TECH_GENERIC` in a simulator, `verilog_define` in
Vivado, `VERILOG_MACRO` in Quartus) or by changing the file's default branch.

| Macro | AMD | Altera | Lattice | Generic |
|---|---|---|---|---|
| `RTLNET_TARGET` | `"AMD"` | `"ALTERA"` | `"LATTICE"` | `"GENERIC"` |
| `RTLNET_SYNC_ATTR` | `ASYNC_REG`, `SHREG_EXTRACT="NO"`, `DONT_TOUCH` | `altera_attribute` synchronizer identification, don't merge, preserve | `syn_preserve`, `syn_srlstyle="registers"` | `keep` |
| `RTLNET_RGMII_IO` | `rtlnet_rgmii_io_amd7` | `rtlnet_rgmii_io_altera` | `rtlnet_rgmii_io_lattice` | `rtlnet_rgmii_io_generic` |

`rtlnet_ram_core` maps as:

| Technology | Implementation |
|---|---|
| AMD | `xpm_memory_sdpram`, `MEMORY_PRIMITIVE` = `RAM_STYLE`, write mode no-change (block) or read-first (distributed) |
| Altera | inferred array, `ramstyle = "no_rw_check, M20K"` (block) or `"no_rw_check, MLAB"` (distributed) |
| Lattice | inferred array, `syn_ramstyle = "block_ram"` or `"distributed"` |
| Generic | behavioural array (simulation, ASIC front end; an ASIC flow replaces this branch with its macro wrapper) |

Read timing is identical on every technology: `rd_data` shows the word `READ_LATENCY` clocks after a clock
with `rd_en` high and holds until the next read; `rd_resetn` clears the output to zero. With latency 2 the
second stage loads one clock after each read (AMD: `regceb` = registered `rd_en`), so a cleared output stays
cleared until a read completes. The bench checks this on the AMD XPM model and the generic model.

## 3. Packet FIFO

Storage `FIFO_KB` kilobytes (`DEPTH_WORDS = FIFO_KB * 128` words of 73 bits: `{last, keep, data}`). Slot size is
one `MAX_FRAME_BYTES` frame rounded up to a power of two words: 1518 bytes is 190 words, a 256-word (2 KiB)
slot. The queue needs at least two slots, and a power-of-two count:

| `FIFO_KB` | Slots (1518-byte frames) |
|---:|---:|
| 4 | 2 |
| 8 | 4 |
| 16 | 8 |
| 32 | 16 |

Any other size stops elaboration with `$fatal`, in synthesis and simulation alike.

Rules: a frame is published only on a good last beat; `s_bad` on any accepted beat, an oversize frame, or (drop
mode) a full queue drops it whole. `DROP_WHEN_FULL = 0`: `s_ready` falls only between frames when full.
`DROP_WHEN_FULL = 1`: `s_ready` stays high and a frame meeting a full queue is consumed and counted on
`overflow`. The read side has no bubble inside a frame and one idle clock between frames. Both sides must be
reset together. The Gray pointers `s_gray -> s_gray_m1` and `m_gray -> m_gray_s1` are the crossings the
constraint script bounds; instance names `u_*_fifo` are part of that interface.

## 4. Crossings and their constraints

| Primitive | Crossing | Constraint (scripts/rtlnet_constrain_cdc.tcl) |
|---|---|---|
| `rtlnet_sync` | levels | false path to the D pin of `g_bit[*].sync_ff_reg[0]` |
| `rtlnet_reset_sync` | reset release | false path to the CLR/PRE pins of `pipe_reg[*]` |
| `rtlnet_pulse_sync` | events (toggle) | via its `rtlnet_sync` |
| `rtlnet_gray_sync` | counters | `set_max_delay -datapath_only` + `set_bus_skew` of one source period, `gray_src_reg` to `gray_dst_ff_reg[0]` |
| `rtlnet_packet_fifo` | frames | as above per Gray direction ; the FIFO RAM data path (RAM cells to the read data registers) `set_max_delay -datapath_only` of the read period (needed once the two clocks differ in frequency; equal periods had hidden the missing constraint) |
| `rtlnet_axil_cdc` | register transactions | toggles via `rtlnet_sync`; `req_*_hold` and `rsp_*_hold` bundles `set_max_delay -datapath_only` of the destination period |
| `rtlnet_axil_cdc` with `SYNC` 1 | none | a pass-through when both sides run on one clock (no flop, nothing to constrain); `rtlnet_constrain_cdc.tcl` neither counts nor constrains such an instance. Cells of the crossing sit in generate block `g_cdc` |

Event spacing limits: `rtlnet_pulse_sync` needs source events at least `STAGES + 1` destination periods apart;
`rtlnet_gray_sync` needs the count to step by at most 1 per source clock.

## 5. AXI4-Lite

`rtlnet_axil_slave` turns a transaction into `reg_wr_en` (full-word writes only; a write with `wstrb != 4'hF`
is answered OKAY and ignored) or `reg_rd_en` with `reg_rd_data` due one clock later. `rtlnet_axil_cdc` carries
one transaction at a time between clocks. `rtlnet_axil_decoder` routes by power-of-two windows and answers an
unmapped address with DECERR.

## 6. Verification

| Bench | Proves | Result (10-22-2026) |
|---|---|---|
| `tb_rtlnet_shift_reg` | `rtlnet_shift_reg_core` depths 2, 5, 16, 32, 33, 64, 70 with a random shift enable: output = input delayed by exactly DEPTH enabled clocks; a tap shortened by one is caught (27701 fails) | PASS, 27712 checks (AMD SRLC32E and GENERIC); synthesis of 73 x 16 maps to 73 SRLC32E + 73 FF, 0 logic LUTs |
| `tb_rtlnet_packet_fifo` | 150 random frames across unrelated clocks (62.5/50 MHz) with source gaps and sink stalls, byte-exact and in order; runts, flagged-bad and oversize frames dropped with one `bad_frame` each; drop-when-full keeps 4 of 10 with 6 `overflow`; `s_ready` never low inside a frame | PASS, 239 checks (AMD and GENERIC); `+INJECT_FAILURE` reports TEST FAIL |
| `tb_rtlnet_axil` | decoder + CDC (100 to 50.3 and 62.7 MHz) + slave: 300 random accesses against a model, partial write ignored, DECERR on unmapped addresses, window boundaries | PASS, 487 checks |
| `tb_rtlnet_primitives` | CRC-32 functions against an independent serial oracle (200 frames, check value 0xCBF43926, residue 0xDEBB20E3), keep/byte-order helpers, IPv4 checksum; 500 pulses each way; Gray counter monotonic and exact; reset assertion with the clock stopped; RAM core in four configurations including reset | PASS, 1324 checks (AMD and GENERIC) |

Run one bench, or the whole regression:

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_axil -Filelist cores/rtlnet_common/testbench/tb_rtlnet_axil.f
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1
```

### Simulator note (Active-HDL 11.1)

A function containing a `for` loop, called inside a `foreach` loop over a queue, returns a wrong value in this
simulator version (observed 10-22-2026: `crc32_byte` over "123456789" gave 0x8D076785 inside `foreach`, the
correct 0xCBF43926 inside `for`, with identical iteration). RTLNet bench code therefore uses
`for (int i = 0; i < $size(q); i++)`, never `foreach`. Synthesizable RTL never iterates queues and is unaffected.

A width cast whose width is a parameter-derived localparam (`DELAY_W'(REPLY_DELAY_CYCLES)`) loaded 0 inside
`always_ff` in this simulator (observed 10-22-2026 in the ARP leaf). Declare a typed localparam of the target
width instead (`localparam logic [DELAY_W-1:0] DELAY = REPLY_DELAY_CYCLES;`) and assign that.

Active-HDL rejects continuously driven nets passed as `ref` task arguments; pass a selector or sample the net
inside the task instead.

## 7. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version |
