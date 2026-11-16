# rtlnet_vdma_s2mm — 2D video write DMA

| Item | Value |
|---|---|
| Core | `rtlnet_vdma_s2mm` |
| Document revision | 11-15-2026 |
| Language | SystemVerilog-2012 (RTL, benches), C11 (driver) |
| Position | between `rtlnet_csi2_rx` and the DDR3 arbiter; slot owner `rtlnet_framebuf` |
| Register map revision | `VERSION` = `0x11092026`, `ID` = `0x53324D4D` ("S2MM") |
| Verification | Active-HDL 11.1: `tb_rtlnet_vdma_s2mm` (6 configurations at 128 bits and 6 at 64 bits, negative controls and bus mutations), `tb_rtlnet_video_path`, host driver test |
| Synthesis | Vivado 2026.1 out of context, xc7a200tsbg484-1: PASS, 0 critical warnings; 595 LUT, 1038 FF, 2 RAMB36 (2 KiB beat FIFO) |

The core writes a video stream (32-bit words of two YUV422 pixels) as a frame of lines into a frame-buffer slot of DDR3 with
AXI4 INCR bursts of at most 16 beats of `AXI_DATA_W` bits (128 by default, 64 for an AXI3 port such as a Zynq HP port; the bytes in memory are the same). One design serves every write-side video client; the `rtlnet_vdma_mm2s` read
DMA is a separate core.

Contents: 1 interface, 2 behaviour, 3 registers, 4 clocks and crossings, 5 resources, 6 verification, 7 integration,
8 limitations.

---

## 1. Interface

### 1.1 Ports

| Group | Ports | Domain | Rule |
|---|---|---|---|
| clock, reset | `clk`, `resetn`, `s_axi_aclk`, `s_axi_aresetn` | `clk` (`ui_clk`), `s_axi_aclk` | synchronous, active low; both resets release from one assertion |
| video stream | `s_axis_tdata[31:0]`, `s_axis_tvalid`, `s_axis_tlast`, `s_axis_tuser`; out `s_axis_tready` | `clk` | `tuser` = first word of a frame, `tlast` = last word of a line |
| frame sideband | `s_width[15:0]`, `s_height[15:0]`, `s_frame_num[31:0]`, `s_timestamp[31:0]`, `s_src_pattern` | `clk` | pixels; stable from the first word of a frame until the next first word |
| slot interface | out `fb_req`; in `fb_rsp_valid`, `fb_rsp_ok`, `fb_rsp_base[ADDR_W-1:0]`; out `fb_done`, `fb_done_good`, `fb_done_frame_num`, `fb_done_timestamp`, `fb_done_width`, `fb_done_height`, `fb_done_src_pattern` | `clk` | `fb_req` is held until the answer pulse; `fb_done` is a one-clock pulse; base is a DDR3 byte offset |
| AXI4 write master | `m_axi_aw*`, `m_axi_w*` (`AXI_DATA_W` bits), `m_axi_b*` | `clk` | AWID 0, size log2(`AXI_DATA_W` / 8) (full width), burst INCR, strobes all ones, no read channel, AWLEN at most 15 (an AXI3 port takes `awlen[3:0]` and drives WID = AWID) |
| registers | `s_axi_aw*`, `s_axi_w*`, `s_axi_b*`, `s_axi_ar*`, `s_axi_r*` (AXI4-Lite, 12-bit address) | `s_axi_aclk` | 4 KiB window, crossing in section 4 |

### 1.2 Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_W` | 29 | DDR3 byte address bits (512 MiB) |
| `ID_W` | 1 | AXI ID width (the ID is constant 0) |
| `AXI_DATA_W` | 128 | memory data width in bits, 128 or 64 (`$fatal` otherwise); the stream words per beat (4 or 2), the beat FIFO width, the burst size and the 4 KiB arithmetic follow it |
| `MAX_BURST_BEATS` | 16 | longest burst in beats of `AXI_DATA_W` bits, 1..16 (`$fatal` outside); 16 beats are 256 bytes at 128 bits and 128 bytes at 64 bits |
| `FIFO_KB` | 2 | beat FIFO size in kilobytes: a power of two beats, at least two bursts (`$fatal` otherwise) |
| `RAM_STYLE` | "block" | passed to `rtlnet_ram_core` ("block" or "distributed") |

---

## 2. Behaviour

**Frame control.** At a first word the core captures the sideband and checks the geometry: width a nonzero multiple of 8
pixels (one 16-byte beat), height nonzero, stride (register, 0 = packed = line bytes) at least the line bytes and a multiple
of 16. A frame is not written, its words are consumed up to the next first word and `FRAMES_DROPPED` counts it, when
`CTRL.ENABLE` is 0, when the geometry is bad (`STATUS.CFG_ERR`) or when the frame buffer answers `fb_rsp_ok` 0 (no free
slot). Otherwise `fb_req` asks for a slot and the answer's base starts the write. A stray word before a first word is
consumed.

**Lines.** A line is W/2 words; line n is written at base + n x stride. A `tlast` that is early or missing marks the frame
not good (`STATUS.LINE_ERR`) but the geometry follows the word counts, so the write stream stays consistent. A first word
that arrives before the frame is complete (a cut-off camera frame) marks it not good and the core pads the rest of the frame
with zero words, so the write side always finishes a whole frame; the frame is reported not good and the new frame starts
after it.

**Write side.** The next burst is computed in three registered steps from the address state (line address and beat in line):
address and beats left in the line, beats to the next 4 KiB boundary, then the length; an AW needs the state stable for three
clocks, so no step is a long combinational path (the first implementation computed it in one clock and failed timing at 100 MHz
with WNS -1.061 ns; a 16-beat burst takes 64 clocks to fill at one stream word per clock, so the issue rate is not limited by
the three clocks). Words pack four to a beat, word 0 in the low bytes (memory order Y0 Cb Y1 Cr). Bursts follow the line from
its start; the length is the least of `MAX_BURST_BEATS`, the beats left in the line and the beats to the next 4 KiB boundary,
so a burst never crosses 4 KiB (with a packed 1,280-pixel line: five bursts of 16 beats; 1,920 pixels: fifteen). An AW is
issued only when all its beats are already in the FIFO, so W never starves and the shared arbiter's W path is never held by
this master. W beats follow AW in order (queue of 4); at most 7 bursts await their response. The FIFO is one `rtlnet_ram_core`.

**Done.** When the last response has arrived `fb_done` pulses once with `fb_done_good` = frame complete, every line end where
expected and every response OKAY, and the frame's sideband. A response other than OKAY sets `STATUS.AXI_ERR` and marks the frame
not good.

---

## 3. Registers

12-bit address; offsets are defined in `driver/rtlnet_vdma_s2mm.h` and mirrored in `hdl/rtlnet_vdma_s2mm_regs.sv`. Counters
are 32-bit, wrap, and clear on `CTRL.CNT_CLEAR` (an event in the clock of a clear is dropped). Undefined offsets read 0.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | 0x53324D4D | "S2MM" |
| 0x004 | `VERSION` | RO | 0x11092026 | register map date code |
| 0x008 | `CAPS` | RO | 0x001D1010 | `[7:0]` maximum burst beats, `[15:8]` bytes per beat, `[23:16]` address width |
| 0x00C | `CTRL` | RW | 1 | `[0]` ENABLE (resets to 1, the core runs with no firmware writes), `[16]` CNT_CLEAR (self-clearing, reads 0) |
| 0x010 | `STATUS` | RO, flags W1C | 0 | `[0]` BUSY (a frame is in progress), `[1]` CFG_ERR, `[2]` AXI_ERR, `[3]` LINE_ERR (flags sticky, write 1 to clear) |
| 0x014 | `STRIDE` | RW | 0 | bytes between line starts, 0 = packed; a value that is not a multiple of 16 or is below the line bytes drops the frame (CFG_ERR) |
| 0x018 | `FRAMES_OK` | RO | 0 | frames written and reported good |
| 0x01C | `FRAMES_BAD` | RO | 0 | frames reported not good |
| 0x020 | `FRAMES_DROPPED` | RO | 0 | frames not written (disabled, bad geometry, no slot) |
| 0x024 | `BURSTS` | RO | 0 | write bursts issued |
| 0x028 | `BEATS` | RO | 0 | write data beats sent |
| 0x02C | `LAST_BASE` | RO | 0 | DDR3 byte offset of the slot written last |

Driver: `rtlnet_vdma_s2mm_probe`, `_read_state`, `_enable`, `_set_stride` (rejects a value that is not a multiple of 16),
`_clear`, `_err_clear`.

---

## 4. Clocks and crossings

Everything is in `clk` (`ui_clk`); the register window is on `s_axi_aclk` behind `rtlnet_axil_cdc` and `rtlnet_axil_slave`
(one added `rtlnet_axil_cdc` instance per build). The beat FIFO is one clock domain: no FIFO or Gray crossing.

---

## 5. Resources

Vivado 2026.1, out-of-context synthesis, xc7a200tsbg484-1 (`.sim/synth/rtlnet_vdma_s2mm.log`), defaults (2 KiB FIFO):

| Resource | Used |
|---|---|
| Slice LUT | 595 (0.44 %) |
| Slice register | 1038 (0.39 %) |
| Block RAM tiles | 2 (the 128 x 128-bit beat FIFO; with `AXI_DATA_W` 64 the FIFO is 256 x 64 bits, the same 2 KiB) |

---

## 6. Verification

`tb_rtlnet_vdma_s2mm` drives the core with a stream of unique hashed words (random valid gaps), a frame-buffer stub that
answers each request with a chosen base and ok flag, and `rtlnet_tb_axi4_mem` with random AW, W and B readiness (the memory
model checks 4 KiB crossings, INCR, full width, WLAST and the stability of valid and payload). An AW monitor compares every
burst with the bench's own splitter.

| Group | Proves |
|---|---|
| layout | every byte of every frame in memory equals the stream (Y0 Cb Y1 Cr, word 0 in the low bytes), no other word is written, the burst sequence (address, length) equals the bench's splitter |
| stride | packed (STRIDE 0), 256 x 8 at stride 1,024, 8 x 20 at stride 16 (single-beat lines) |
| 4 KiB rule | base 0xF80 with 512 x 6 at stride 1,040: lines wander across pages, the first burst is cut at the page end; no burst crosses 4 KiB or exceeds the maximum |
| geometry | width 12 pixels, stride below the line bytes, stride not a multiple of 16, height 0: dropped, `CFG_ERR`, nothing written; the next frame is normal |
| no slot, disabled | no slot (frame buffer answers not ok) and `CTRL.ENABLE` 0: the frame is discarded, nothing is written, `FRAMES_DROPPED` counts it |
| line errors | missing tlast and early tlast: frame not good, `LINE_ERR`, data still follow the word counts |
| cut-off frame | a first word after 3 of 8 lines: the 3 lines are written, the rest padded with zero beats, `fb_done` not good, the next frame is written and good |
| write error | a SLVERR response (injected in the response path): frame not good, `AXI_ERR` |
| registers | ID, CAPS, ENABLE reset, STRIDE, FRAMES_OK / BAD / DROPPED against the bench's counts, BURSTS and BEATS against the memory model's, LAST_BASE, STATUS write-1-to-clear, CNT_CLEAR keeps ENABLE |
| sideband | `fb_done` carries frame number, timestamp, width, height and source flag of its frame |

Configurations (`testbench/regression.txt`): `gap` (random gaps), `nogap`, `burst8` (`MAX_BURST_BEATS` 8), `burst4_fkb1` (4 beats, 1 KiB
FIFO), `full` (adds real 1280x720 and 1920x1080 packed frames, 587,825 checks), `neg` (`+INJECT_FAILURE`, expected failure).

With `AXI_DATA_W` 128 the synthesized netlist is that of the 128-bit core: out-of-context synthesis before and after the parameter gives the same EDIF (cells, nets and connections) apart from the time stamp and the added generic annotations (595 LUT, 1038 FF, 2 RAMB36).

With the define `TB_AXI_W=64` the same scenario runs with 64-bit beats (entries `w64_gap`, `w64_nogap`, `w64_burst8`, `w64_burst4_fkb1`, `w64_full`, `w64_neg`). The
expected memory image is built byte by byte from the stream words, independent of the width, and after every frame the CRC-32 of the memory model's bytes
(`mem_crc32()`, ascending byte address, the same for any word size) must equal the CRC of that expected image: the bytes of a frame written at 64 bits are the bytes written at 128 bits.
The bench's splitter and the AW monitor use the beat size (a 64-bit burst of the same beat count carries half the bytes), the memory model limits a burst to 16 beats (AXI3), and the
monitor requires `AWLEN` at most 15 and size 3. Bus mutations between the core and the memory model, each of which must fail the bench: `+MUT_LEN` (a burst of more than 16 beats: "burst of 32 beats
exceeds the limit 16"), `+MUT_SIZE` (beat size: "size 2 is not full width 3"), `+MUT_4K` ("crosses a 4 KiB boundary"), `+MUT_STRB` (one strobe bit cleared: wrong byte, CRC mismatch); entries `w64_mut_len`, `w64_mut_size`, `w64_mut_4k`,
`w64_mut_strb`, `mut_len`, `mut_strb`.

Mutation (RTL restored to the identical SHA-256 afterwards): the 4 KiB limit on the burst length removed fails the bench,
"AW beats 16, expected 8 (addr 0x400f80)" (32 failed checks).

Host: `testbench/test_rtlnet_vdma_s2mm_driver.c` (`rtlnet_vdma_s2mm_driver_test.ps1`).

---

## 7. Integration guide

1. Connect the stream and sideband from `rtlnet_csi2_rx`, the slot interface to `rtlnet_framebuf`, the AXI4 write channels to
   an arbiter master port (fixed top priority: a frame must not wait). The ID is 0; leave the arbiter's read channel for this master idle.
2. Slot bases are DDR3 byte offsets aligned to 16 bytes; the lines of a frame must fit the slot (`STRIDE` x `s_height`).
3. A source that cannot stall (a camera) is buffered upstream; the core stalls its stream only while it waits for the slot
   answer or the beat FIFO is full.

---

## 8. Limitations

- Write only; INCR bursts of full width; no narrow transfers; no read channel; `AXI_DATA_W` is 128 or 64.
- Width in multiples of 8 pixels (16 bytes, one beat at 128 bits, two at 64 bits), the line start addresses and the stride in multiples of 16 bytes at both widths.
- A cut-off frame is completed with zero words before the next frame starts (up to one frame time of stall).
- The beat count of the FIFO bounds the lookahead; `FIFO_KB` must hold two bursts.
