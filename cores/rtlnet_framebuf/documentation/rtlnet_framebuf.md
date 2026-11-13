# rtlnet_framebuf — tear-free frame-buffer slot manager

| Item | Value |
|---|---|
| Core | `rtlnet_framebuf` |
| Document revision | 11-09-2026 |
| Language | SystemVerilog-2012 (RTL, benches), C11 (driver) |
| Position | slot ownership between the write DMA and the frame readers |
| Register map revision | `VERSION` = `0x11092026`, `ID` = `0x46425546` ("FBUF") |
| Verification | Active-HDL 11.1: `tb_rtlnet_framebuf` (5 configurations + negative control), `tb_rtlnet_video_path`, host driver test |
| Synthesis | Vivado 2026.1 out of context, xc7a200tsbg484-1: PASS, 0 critical warnings; 763 LUT, 713 FF, 0 BRAM |

N slots of one frame each sit in DDR3 at byte offset `FB_BASE` + i x `2**SLOT_LOG2`. The core hands out ownership and
carries the metadata of each published frame; the pixel data move between DDR3 and the DMAs. With N = readers + 2 the writer
never waits: one slot is "latest", each reader holds one, and one is being written. A frame is dropped, and counted, only
when a reader stops releasing.

Contents: 1 interface, 2 behaviour, 3 registers, 4 clocks and crossings, 5 resources, 6 verification, 7 integration,
8 limitations.

---

## 1. Interface

### 1.1 Ports

| Group | Ports | Domain | Rule |
|---|---|---|---|
| clock, reset | `clk`, `resetn`, `s_axi_aclk`, `s_axi_aresetn` | `clk` (`ui_clk`), `s_axi_aclk` | synchronous, active low; both resets release from one assertion |
| writer | in `w_req`; out `w_rsp_valid`, `w_rsp_ok`, `w_rsp_base[ADDR_W-1:0]`; in `w_done`, `w_done_good`, `w_done_frame_num`, `w_done_timestamp`, `w_done_width`, `w_done_height`, `w_done_src_pattern` | `clk` | from `rtlnet_vdma_s2mm`; request is a level held until the answer pulse (rising edge acts); `w_done` a one-clock pulse |
| readers | per port i: in `r_take[i]`, `r_release[i]` (one-clock pulses); out `r_rsp_valid[i]` (pulse), `r_rsp_ok[i]`, `r_holds[i]`, `r_slot[i*8 +: 8]`, `r_base`, `r_frame_num`, `r_timestamp`, `r_width`, `r_height`, `r_src_pattern` | `clk` | the slot, base and metadata describe the held frame while `r_holds` is high |
| registers | `s_axi_aw*`, `s_axi_w*`, `s_axi_b*`, `s_axi_ar*`, `s_axi_r*` (AXI4-Lite, 12-bit address) | `s_axi_aclk` | 4 KiB window, crossing in section 4 |

Source flag: 1 pattern, 0 camera (the same encoding as `rtlnet_csi2_rx` `STATUS[0]`).

### 1.2 Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `N` | 3 | slots, 2..8 |
| `NUM_READERS` | 1 | external reader ports, 1..7; the firmware is one more reader through the registers |
| `ADDR_W` | 29 | DDR3 byte address bits |
| `SLOT_LOG2` | 22 | log2 of the slot size (4 MiB: a 1080p YUV422 frame is 3.96 MiB) |
| `FB_BASE` | 0x1000_0000 | DDR3 byte offset of slot 0, a multiple of the slot size (`$fatal` otherwise); the CPU address is the DDR3 window base + this offset (0x9000_0000 on the board) |

`N` = readers + 2 is the sizing rule: with the encoder as the one reader port, 3 slots. The firmware reader is a
debug reader outside that formula: with it and the encoder both holding different slots the writer can find no free slot
and drops the frame, which the counters show.

---

## 2. Behaviour

**Writer.** At the rising edge of `w_req` the manager takes the first slot after the last one written, in rotation, that is
not "latest" and that no reader holds, and answers one clock later with its base (`w_rsp_ok` 1). With no such slot the frame
is dropped: `w_rsp_ok` 0 and `DROPPED` counts it. A held slot or "latest" is never granted. At `w_done` a good frame is
published: its slot becomes "latest" with the frame's frame number, timestamp, width, height and source flag, and `PUBLISHED`
counts it; a frame that is not good is counted in `BAD`, publishes nothing and returns its slot to the pool ("latest"
unchanged). Frames therefore publish in the order they finish.

**Readers.** `r_take` takes the latest published slot with a reference count and answers one clock later (`r_rsp_ok` 1 and
the slot outputs, or 0 when nothing is published or the reader already holds a slot). A take and a publish in the same clock
take the previous "latest". The reader holds the slot until `r_release`. Several readers may hold the same slot; the reference
count of a slot is the number of holders and is readable per slot.

**Firmware reader.** `CTRL.FW_TAKE` and `CTRL.FW_RELEASE` act as `r_take` and `r_release` of one more holder. A take with
nothing published, a take while holding and a release while not holding set the sticky `STATUS.FW_ERR`. The `FW_*` registers
describe the held frame and stay constant while it is held; the `LATEST_*` registers are a live view that can change between
two reads, so a consumer takes the frame first.

---

## 3. Registers

12-bit address; offsets are defined in `driver/rtlnet_framebuf.h` and mirrored in `hdl/rtlnet_framebuf_regs.sv`. Counters are
32-bit, wrap, and clear on `CTRL.CNT_CLEAR` (an event in the clock of a clear is dropped); the slot state is not cleared.
Undefined offsets read 0.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | 0x46425546 | "FBUF" |
| 0x004 | `VERSION` | RO | 0x11092026 | register map date code |
| 0x008 | `CAPS` | RO | 0x001D1613 | `[3:0]` N, `[7:4]` reader ports, `[15:8]` log2 of the slot size, `[23:16]` address width |
| 0x00C | `CTRL` | WO | 0 | `[0]` FW_TAKE, `[1]` FW_RELEASE (one-clock commands), `[16]` CNT_CLEAR; reads 0 |
| 0x010 | `STATUS` | RO, FW_ERR W1C | 0 | `[0]` LATEST_VALID, `[1]` FW_HOLDS, `[2]` WRITING, `[3]` FW_ERR (sticky), `[15:8]` latest slot, `[23:16]` slot the firmware holds, `[31:24]` slot the writer owns (last owned when idle) |
| 0x014 | `FB_BASE` | RO | 0x10000000 | DDR3 byte offset of slot 0 |
| 0x018 | `SLOT_BYTES` | RO | 0x00400000 | bytes per slot |
| 0x020 | `LATEST_BASE` | RO | 0 | DDR3 byte offset of the latest published slot |
| 0x024 | `LATEST_FRAME` | RO | 0 | its frame number |
| 0x028 | `LATEST_TS` | RO | 0 | its timestamp (`ui_clk` cycles) |
| 0x02C | `LATEST_WH` | RO | 0 | `[31:16]` height, `[15:0]` width |
| 0x030 | `LATEST_SRC` | RO | 0 | `[0]` source flag |
| 0x040 to 0x050 | `FW_BASE`, `FW_FRAME`, `FW_TS`, `FW_WH`, `FW_SRC` | RO | 0 | the same, for the frame the firmware holds (0 when none) |
| 0x060 | `PUBLISHED` | RO | 0 | frames published |
| 0x064 | `DROPPED` | RO | 0 | frames dropped for want of a free slot |
| 0x068 | `BAD` | RO | 0 | frames reported not good |
| 0x06C | `FW_TAKES` | RO | 0 | successful firmware takes |
| 0x080 + 4 i | `REFCNT[i]` | RO | 0 | reference count of slot i (holders) |

Driver: `rtlnet_framebuf_probe`, `_read_state`, `_fw_take` (polls `STATUS` bounded; `ERR_NO_FRAME`, `ERR_TIMEOUT`),
`_fw_release`, `_clear`.

---

## 4. Clocks and crossings

Everything is in `clk` (`ui_clk`); the register window is on `s_axi_aclk` behind `rtlnet_axil_cdc` and `rtlnet_axil_slave`
(one added `rtlnet_axil_cdc` instance per build). The slot state, metadata and reference counts are a few register words (N
entries), deliberately flops and not a RAM.

---

## 5. Resources

Vivado 2026.1, out-of-context synthesis, xc7a200tsbg484-1 (`.sim/synth/rtlnet_framebuf.log`), N = 3, one reader port:

| Resource | Used |
|---|---|
| Slice LUT | 763 (0.57 %) |
| Slice register | 713 (0.26 %) |
| Block RAM | 0 |

---

## 6. Verification

`tb_rtlnet_framebuf` drives a random writer (frames of random length, 85 % good, random width, height, source flag), external
readers (random take, hold, release, takes while holding) and the firmware reader through the register window (on a 9.7 ns clock
against the 10 ns core clock). A shadow model in the bench is updated every clock from the pins and the holders' state.

| Group | Proves |
|---|---|
| slot grant | granted if and only if a slot exists that is neither "latest" nor held, and it is the first such slot in rotation after the last written; otherwise dropped and counted |
| safety (every clock) | the slot the writer owns is never held by any reader and is never "latest"; every reference count equals the number of holders of the slot |
| publish | a good frame becomes "latest" with its metadata; a bad frame is counted and publishes nothing |
| readers | a take returns the slot that was latest in the clock of its pulse (the previous one when a frame is published in the same clock) with that frame's metadata and base; a take while holding is refused |
| firmware reader | take, poll, `FW_*` registers equal the model, unchanged while held, release; take with nothing published, take while holding and release while not holding set `FW_ERR`, which clears by writing 1 |
| registers | ID, CAPS, FB_BASE, SLOT_BYTES, PUBLISHED, DROPPED, BAD, FW_TAKES against the model, REFCNT 0 when everyone has released, LATEST_* describe the last published frame, CNT_CLEAR |

Configurations (`testbench/regression.txt`): `n3_nr1` (the board, 42,529 checks), `n3_nr1_slow` (long holds force drops, 26,125),
`n4_nr2` (71,182), `n5_nr3_slow` (66,887), `n2_nr1` (15,462), `neg` (`+INJECT_FAILURE`, expected failure).

Mutation (RTL restored to the identical SHA-256 afterwards): the "not latest" test removed from the slot search fails the bench,
"slot answer ok=1, expected 0" (1,758 failed checks).

Host: `testbench/test_rtlnet_framebuf_driver.c` (`rtlnet_framebuf_driver_test.ps1`).

---

## 7. Integration guide

1. Connect `w_*` to `rtlnet_vdma_s2mm`, set `N` to the readers + 2 and `FB_BASE` to a region of DDR3 that nothing else uses
   (on the board 0x1000_0000, above the firmware's DDR3 memory test of the default size).
2. A reader port is one `r_take` / `r_release` pair: take at the reader's frame start, release at its frame end. Tie an unused
   port off (`r_take` 0).
3. Firmware reads a frame through the CPU data cache: take it, invalidate the cache lines of the frame, read, release.

---

## 8. Limitations

- Ownership only; no data movement, no frame-number continuity check.
- A held slot is held until released: a reader that never releases starves the writer into dropping frames (counted).
- The firmware reader is outside the N = readers + 2 sizing rule.
- Slot size is a power of two and `FB_BASE` a multiple of it.
