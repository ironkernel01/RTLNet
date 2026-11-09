# rtlnet_h264_enc: H.264 encoder core, phase 2b-1 (I_PCM pipeline)

Revision: 11-09-2026

## 1. Purpose and scope

`cores/rtlnet_h264_enc` encodes one picture per start into an H.264 Constrained Baseline Annex B stream
(ITU-T Rec. H.264 (06/2026), profile_idc 66, constraint_set1_flag 1, CAVLC, deblocking off). Phase 2b-1 proves the whole
pipeline with I_PCM macroblocks as the only macroblock type: read DMA with 4:2:2 to 4:2:0 conversion, macroblock coder,
bit packer with emulation prevention, NAL and slice syntax, write DMA into a compressed ring, an index ring, and the
rebuilt-picture write. The intra prediction, transform, quantizer and CAVLC coder of phase 2b-2 replace
`rtlnet_h264_mb_pcm` behind the same start/done and packer-command interface. The rebuilt-picture path and the rings stay.

Two video modes run on one build, selected by registers (VIDEO_MODE of the camera design):

| Mode | Frame | Macroblocks | Cropping | level_idc | Bands at NUM_ENGINES = 2 |
|---|---|---|---|---|---|
| 0 = 720p30 (default) | 1280x720 | 80 x 45 | none | 31 | 23 and 22 rows |
| 1 = 1080p30 | 1920x1080 coded as 1920x1088 | 120 x 68 | bottom 8 lines (frame_crop_bottom_offset 4) | 40 | 34 and 34 rows |

## 2. Clocking and engine count

* `enc_clk` carries the engines, their memory ports and the register file. The board runs it from the MIG `ui_clk`,
  100 MHz; the out-of-context synthesis check constrains it to 10.000 ns.
* `s_axi_aclk` (cpu_clk) carries only the AXI4-Lite slave side of `rtlnet_axil_cdc`. Both resets release from one assertion.
* `NUM_ENGINES = 2` is the default. One engine codes one macroblock in 391 clocks (section 9), 1080p30 needs
  8160 x 30 = 244 800 macroblocks per second, so one engine at 100 MHz has 408 clocks per macroblock, a 4 % margin
  that the 415-clock worst intervals exceed. Two engines at 100 MHz have a budget of 100e6 / (8160 x 30) x 2 = 816 clocks
  per macroblock per engine. Each engine codes a horizontal band of macroblock rows as its own slice(s).
* A band split is a register property: the first `NUM_ENGINES - 1` engines take `ceil(MB_H / NUM_ENGINES)` rows, the last
  engine the rest. `SLICES` is the slice count of the whole picture and must be a multiple of `NUM_ENGINES`; each engine
  codes `SLICES / NUM_ENGINES` slices of whole macroblock rows inside its band.

## 3. Block hierarchy

```
rtlnet_h264_top                      top: registers, the engine array, completion aggregation
  rtlnet_axil_cdc                    s_axi_aclk -> enc_clk AXI4-Lite crossing (rtlnet_common)
  rtlnet_axil_slave                  AXI4-Lite to strobes (rtlnet_common)
  rtlnet_h264_enc_regs               register file (strobe interface), engine windows
  rtlnet_h264_engine  x NUM_ENGINES  one engine, one AXI4 master
    rtlnet_h264_rd_dma               16 read bursts per macroblock, 2 beats each
      rtlnet_h264_c422to420          YUYV 4:2:2 rows to 4:2:0 macroblock rows
    rtlnet_ram_core  x 2             macroblock buffer copies (coder read, rebuilt-writer read), 2 banks of 24 words
    rtlnet_h264_mb_pcm               I_PCM macroblock layer into packer commands
    rtlnet_h264_recon_wr             rebuilt-picture rows, 32 single-beat writes per macroblock
    rtlnet_h264_bitpack              ue/se, fields, start codes, trailing bits, emulation prevention
    rtlnet_h264_ring_wr              byte gather, word FIFO (rtlnet_ram_core), bursts, index entries, pointers
    rtlnet_h264_wr_master            ring / index / rebuilt write requests onto AW, W, B
  rtlnet_h264_pkg                    shared constants
```

Files: `hdl/rtlnet_h264_top.sv` (top), `hdl/rtlnet_h264_enc_regs.sv`, `hdl/rtlnet_h264_engine.sv` (one engine), the
datapath modules above, `hdl/rtlnet_h264_enc.f` (compile order), `driver/rtlnet_h264_enc.{h,c}`, `testbench/`.

Engine pipeline per macroblock: the fetch sequencer fills one macroblock-buffer bank through the read DMA while the coder
and the rebuilt-picture writer drain the other bank; a bank is released when both finish. The coder emits one sample byte
per clock (384 samples) and is the throughput limit. The write master serves three requesters round robin, one burst per
grant: ring bursts (id 0), index entries (id 1) and rebuilt rows (id 2).

## 4. Parameters of `rtlnet_h264_top`

| Parameter | Default | Meaning |
|---|---|---|
| NUM_ENGINES | 2 | slice-band engines, 1..4 |
| MAX_MB_W, MAX_MB_H | 120, 68 | widest and tallest picture in macroblocks (1920x1088); range-checks and CAPS |
| ADDR_W | 32 | only 32 supported (elaboration `$fatal`) |
| ID_W | 4 | AXI ID width of each engine port |
| MB_BUF_KB | 1 | macroblock buffer per copy, KiB (two banks of 24 words use 768 B) |
| FIFO_KB | 1 | ring word FIFO per engine, KiB (64 words of 16 bytes plus strobes) |
| RAM_STYLE | "block" | `rtlnet_ram_core` style, "block" or "distributed" |

All memories are instances of `rtlnet_ram_core`. Both buffers are small, so `"distributed"` (LUTRAM) is the default; the
synthesis check shows 0 block RAM. Frame size, band split, slice count and QP come from registers, not parameters, so one
build codes both video modes.

## 5. Ports of `rtlnet_h264_top`

| Group | Ports |
|---|---|
| Clocks and resets | `enc_clk`, `enc_resetn` (synchronous, active low); `s_axi_aclk`, `s_axi_aresetn` |
| AXI4-Lite slave, `s_axi_aclk` | `s_axi_aw*`, `w*`, `b*`, `ar*`, `r*`, 12-bit address (4 KiB window), 32-bit data |
| AXI4 masters, `enc_clk` | `m_axi_aw*`, `w*`, `b*`, `ar*`, `r*` as packed vectors, engine e at `[e*W +: W]`, arbiter style; 128-bit data, ADDR_W 32, ID_W 4 |
| Interrupt | `irq`, level on `enc_clk`: `CTRL.IRQ_EN` and (`STATUS.DONE` or `STATUS.ERR`) |

Every burst is INCR, size 16 bytes (full width), at most 16 beats, and never crosses 4 KiB (`rtlnet_axi_arbiter` rejects
anything else from a non-narrow master). Read bursts are 2 beats from a 32-byte aligned address. Ring bursts end at 16 beats, at
4 KiB, at the ring end and at the end of a NAL unit. Index and rebuilt-picture writes are single beats. Simulation
assertions in `rtlnet_h264_wr_master` and `rtlnet_h264_engine` check the burst rules, and the bench places the real
`rtlnet_axi_arbiter` between the engines and the memory model.

## 6. Register map (offsets in the 4 KiB window)

| Offset | Name | Access | Meaning |
|---|---|---|---|
| 0x000 | ID | RO | "H264" = 0x48323634 |
| 0x004 | VERSION | RO | 0x11092026 |
| 0x008 | CAPS | RO | [7:0] MAX_MB_W, [15:8] MAX_MB_H, [19:16] NUM_ENGINES |
| 0x00C | CTRL | RW | bit 0 START (self-clearing), bit 1 RING_RESET (self-clearing), bit 8 IRQ_EN |
| 0x010 | STATUS | RW | bit 0 BUSY, bit 1 DONE (W1C), bit 2 ERR (W1C), bit 3 RING_STALL (live, any engine) |
| 0x014 | ERR_CODE | RO | first error since the last ERR clear: 1 config, 2 AXI response, 3 read pointer, 4 start while busy |
| 0x020 | MB_W | RW | picture width in macroblocks |
| 0x024 | MB_H | RW | picture height in macroblocks |
| 0x028 | SLICES | RW | slices per picture, a multiple of NUM_ENGINES |
| 0x02C | QP | RW | slice QP 0..51; `slice_qp_delta = QP - 26` (reset 26) |
| 0x030 | FRAME_NUM | RW | frame_num written in `log2_max_frame_num` bits |
| 0x034 | IDR_PIC_ID | RW | idr_pic_id of an IDR picture |
| 0x038 | PIC_CFG | RW | [0] IDR picture (reset 1), [12:8] log2_max_frame_num (reset 4, range 4..16) |
| 0x040 | IN_BASE | RW | input frame base, multiple of 32 |
| 0x044 | IN_STRIDE | RW | input line stride in bytes, multiple of 32, at least MB_W x 32 |
| 0x048 | RY_BASE | RW | rebuilt luma plane base, multiple of 16 |
| 0x04C | RY_STRIDE | RW | rebuilt luma stride, multiple of 16, at least MB_W x 16 |
| 0x050 | RU_BASE | RW | rebuilt Cb plane base |
| 0x054 | RV_BASE | RW | rebuilt Cr plane base |
| 0x058 | RC_STRIDE | RW | rebuilt chroma stride, multiple of 16, at least MB_W x 8 |
| 0x060 | RING_BASE | RW | compressed ring base, multiple of 16 (all engines) |
| 0x064 | RING_SIZE | RW | compressed ring size in bytes, multiple of 16 x NUM_ENGINES, each share at least 1024 |
| 0x068 | RING_WPTR | RO | byte offset after the last burst whose write response arrived |
| 0x06C | RING_RPTR | RW | byte offset firmware consumed up to |
| 0x070 | RING_FILL | RO | bytes written and not consumed |
| 0x078 | IDX_BASE | RW | index ring base, multiple of 16 |
| 0x07C | IDX_ENTRIES | RW | index ring entries (all engines), at least NUM_ENGINES |
| 0x080 | IDX_WPTR | RO | index of the next entry to be written (visible after its write response) |
| 0x084 | IDX_RPTR | RW | index firmware consumed up to |
| 0x088 | IDX_FILL | RO | entries written and not consumed |
| 0x090 | PIC_COUNT | RO | pictures completed (low 16 bits stamp the entries) |
| 0x094 | SLICE_COUNT | RO | slices completed |
| 0x098 | MB_COUNT | RO | macroblocks coded by this engine in the current or last picture |
| 0x09C | CYC_LAST | RO | clocks between the last two macroblock starts |
| 0x0A0 | CYC_MAX | RO | largest such interval in the picture |
| 0x0A4 | PIC_CYC | RO | clocks from start to done |
| 0x0A8 | RD_CYC | RO | clocks the read DMA was busy |
| 0x0AC | PK_CYC | RO | clocks the macroblock coder was busy |
| 0x0B0 | WR_CYC | RO | clocks the write master was busy |

Engine windows: the per-engine registers (0x068 .. 0x088 and 0x098 .. 0x0B0) of engine e are at `0x100 x e + offset`;
window 0 is engine 0. Writes to RING_RPTR and IDX_RPTR in window e go to engine e. The configured ring and index ring are
split into `NUM_ENGINES` equal shares, engine e using share e: `RING_SIZE / NUM_ENGINES` bytes from
`RING_BASE + e x RING_SIZE / NUM_ENGINES`, and `IDX_ENTRIES / NUM_ENGINES` entries from
`IDX_BASE + 16 x e x IDX_ENTRIES / NUM_ENGINES`.

Rules: write the configuration while the core is idle, at least a few clocks before START (the check is registered); write
RING_RESET once after changing RING_BASE or RING_SIZE and before the first picture. START with an illegal configuration
sets ERR with code 1 and starts nothing. `STATUS.DONE` sets when every engine has finished.

## 7. Memory formats

**Input frame**, packed YUYV 4:2:2, 2 bytes per pixel, line stride `IN_STRIDE`. Byte order per pixel pair: `Y0 U0 Y1 V0`.
One macroblock row is 32 bytes (16 pixels), two 16-byte beats; byte 0 of a beat is the low byte of the 128-bit word.
Conversion to 4:2:0: luma passes through; each chroma sample is `(a + b + 1) >> 1` of the same column in the two vertically
adjacent rows (rows 2r and 2r+1 of the macroblock), rounding up.

**Macroblock buffer** (per bank, 16-byte words): words 0..15 the luma rows (pixel i in byte i); words 16..23 chroma rows,
Cb(0..7) in bytes 0..7 and Cr(0..7) in bytes 8..15.

**Rebuilt picture**: three planes, 8-bit samples. Luma at `RY_BASE`, line pitch `RY_STRIDE`; Cb at `RU_BASE` and Cr at
`RV_BASE`, line pitch `RC_STRIDE`, width/2 samples per line. For I_PCM the rebuilt picture equals the PCM samples, which
equal the source 4:2:0 picture. A luma row is one 16-byte write with full strobes; a chroma row is an 8-byte write into the
low or high half of the 16-byte word (address bit 3) with an 8-bit strobe. 2b-2 feeds the rebuild loop through the same
path, and the same planes later serve as the reference buffer.

**Compressed ring**: byte stream of NAL units in order, wrapping at the end of the engine's share. Bytes are written as full
or partial 16-byte words (byte strobes), so the stream is contiguous. The writer stalls, and never overwrites unread
bytes, when the ring holds fewer than 4 bytes of free space (fill at most `size - 3`); firmware advances the read
pointer in steps below the ring size. A read pointer at or beyond the ring size, or a step beyond the data written, is
ignored and sets ERR code 3.

**Index entry**, 16 bytes, four little-endian 32-bit words, at `IDX_BASE`-share `+ 16 x index`:

| Word | Content |
|---|---|
| 0 | byte offset in the ring of the NAL unit's first byte (the start code). Picture entry: of the engine's first NAL unit of the picture (engine 0: the access unit delimiter) |
| 1 | length in bytes, start code and emulation-prevention bytes included. Picture entry: all the engine's NAL units of the picture |
| 2 | [15:0] picture number, [31:16] slice number in the picture (engine 1 numbers its slices after engine 0's). Picture entry: slices in this engine |
| 3 | [7:0] slice type (7), [15:8] QP, [16] last slice of this engine's band, [17] IDR picture, [24] kind: 0 slice entry, 1 picture entry |

A slice entry appears when every byte of the NAL unit is in memory (all write responses back). Each engine writes one
picture entry after its last slice entry. Firmware reads the engine rings in engine order (engine 0 holds the access unit
delimiter and the first slices) and concatenates them to form the picture's Annex B stream.

## 8. Syntax emitted

Per picture, engine 0 writes the access unit delimiter; every engine writes its slices.

* Start codes `00 00 00 01` (Annex B). Emulation prevention (`03` after two zero bytes before a byte 0..3, clause 7.4.1)
  applies to every byte after the NAL header start code, in the packer.
* Access unit delimiter: NAL header 0x09 (nal_ref_idc 0, type 9), primary_pic_type 7, rbsp trailing bits: `00 00 00 01 09 F0`.
* Slice NAL unit: nal_ref_idc 3, nal_unit_type 5 (IDR) or 1. Slice header (clause 7.3.3): `first_mb_in_slice` ue(v),
  `slice_type` ue(v) = 7, `pic_parameter_set_id` ue(v) = 0, `frame_num` u(log2_max_frame_num), `idr_pic_id` ue(v) (IDR only),
  no POC fields (`pic_order_cnt_type` 2), `dec_ref_pic_marking` (IDR: `no_output_of_prior_pics_flag` 0 and
  `long_term_reference_flag` 0; non-IDR: `adaptive_ref_pic_marking_mode_flag` 0), `slice_qp_delta` se(v) = QP - 26,
  `disable_deblocking_filter_idc` ue(v) = 1.
* Macroblock layer (clause 7.3.5), per macroblock: `mb_type` ue(v) = 25 (I_PCM, Table 7-11), `pcm_alignment_zero_bit`s to
  the byte boundary, 256 luma samples, 64 Cb samples, 64 Cr samples, 8 bits each, raster order. A PCM sample value of 0 is
  allowed: clause 7.4.5 states `pcm_sample_luma` and `pcm_sample_chroma` as sample values without a restriction in
  this edition (older editions excluded 0), and emulation prevention protects any zero run.
* Slice end: `rbsp_slice_trailing_bits` (clause 7.3.2.8): one stop bit and zeros to alignment; with I_PCM data the last
  byte is `80`.
* A second IDR picture uses `frame_num` 0 (clause 7.4.3) and a new `idr_pic_id`, as the 2-picture runs do.
* SPS and PPS are written by firmware: `rtlnet_h264_enc_write_sps_pps()`. SPS: profile_idc 66, constraint_set1_flag 1,
  level_idc from the frame size and rate (Table A-1: 31 for 720p30, 40 for 1080p30), `pic_order_cnt_type` 2,
  `max_num_ref_frames` 1, `frame_mbs_only_flag` 1, frame cropping 1088 to 1080 (`frame_crop_bottom_offset` 4). PPS: CAVLC
  (`entropy_coding_mode_flag` 0), `deblocking_filter_control_present_flag` 1, `pic_init_qp` 26 (`pic_init_qp_minus26` 0).

## 9. Driver

`driver/rtlnet_h264_enc.{h,c}` (C, `rtlnet_mmio.h` for register access): `probe`, `get_mode` / `set_mode` (0 = 720p30,
default; 1 = 1080p30: writes MB_W, MB_H, fills the SPS parameters), `band_rows` (the ceil split), `configure`, `ring_reset`,
`start_picture`, `wait_done`, `status`, `clear_status`, `set_read_pointers`, `index_wptr`, `decode_index_entry`,
`read_stats` and `write_sps_pps`. The host test `testbench/test_rtlnet_h264_enc_driver.c` checks the register writes
against a register model and checks the SPS and PPS bytes with an independent bit reader (fields, emulation prevention,
level, cropping, rejections), including the 720p30 and 1080p30 modes and the bands (23/22 and 34/34).

## 10. Verification flow (Verilator)

All H.264 RTL benches run in Verilator 5.050 (MSYS2 UCRT64, g++ 16.2), through `scripts/rtlnet_run_verilator.ps1`
(`--binary --timing`, with `-MAKEFLAGS 'OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2'` for the gcc 16 libstdc++ link issue at
-Os). The runner scans for `TEST PASS: <bench>` (a missing token, a `%Error` or a `TEST FAIL` fails). Active-HDL
stays the simulator of the rest of RTLNet; `tb_rtlnet_h264_bitpack` and `tb_rtlnet_h264_c422` also passed there before the
move. Regression lines carry `sim=verilator`; a `script:` line runs a host script (decoder harness, driver test, lint).

* RAM model: the benches compile `rtlnet_ram_core` with `RTLNET_TECH_GENERIC` (the runner defines it). The generic branch is
  a registered-read array with a clocked write: read latency 1, the output register holds while `rd_en` is low,
  `rd_resetn` clears it, and a read in the clock of a write to the same address returns the old word. That is the
  behavior of the AMD branch (xpm_memory_sdpram, READ_LATENCY_B 1, `read_first` for distributed RAM, `no_change`
  for block RAM in common clock mode) the board uses, so the encoder sees the same cycle behavior in both.
* Benches are race-free for Verilator: bench outputs change at the falling clock edge and inputs are sampled there.
* Lint gate: `testbench/h264_lint.ps1` runs `verilator --lint-only -Wall` on the encoder RTL (not the benches) and a
  text scan for multi-edge sensitivity lists. Result: 0 warnings in `rtlnet_h264_*`. Six declarations carry narrow
  `lint_off UNUSEDSIGNAL` waivers with a reason (a port or signal that is intentionally not read).
* Unit benches: `tb_rtlnet_h264_bitpack` (ue/se, fields, ALIGN, trailing bits, start codes, emulation prevention and the
  first/last/kind sideband against reference functions written from the clause text, directed and random NAL units, random
  back-pressure) and `tb_rtlnet_h264_c422` (YUYV to 4:2:0, rounding, corner values). Each has a `+INJECT_FAILURE` negative control.
* Encoder bench `tb_rtlnet_h264_top`: loads the input image into a memory model (`tb_h264_axi_mem`, behind the real
  `rtlnet_axi_arbiter`), programs the registers over AXI4-Lite, plays the firmware (polls the index rings, copies each
  slice out of each engine's ring, advances the read pointers), checks index entries, NAL framing, `first_mb_in_slice`
  against an independent band/slice computation, and dumps the stream and the rebuilt planes. `+INJECT` corrupts one PCM
  byte of the dumped stream after the rebuilt picture is written.
* Decoder harness `testbench/h264_harness.ps1`: generates the input (`h264_gen.py`: bars, gradient, noise, zeros, square),
  writes SPS/PPS with the driver (`h264_spspps_tool`), runs the bench, assembles the stream (`h264_check.py`), decodes with
  JM `ldecod`, OpenH264 `h264dec` and FFmpeg (`-f rawvideo -pix_fmt yuv420p`), and compares each decoded YUV byte for byte
  with the rebuilt YUV (the first differing macroblock, plane and position print on a mismatch). The rebuilt YUV must also equal the
  generator's 4:2:0 reference (PSNR infinite). It prints `TEST PASS: rtlnet_h264_top_<config>`; `-Inject` runs
  the negative control (all three comparisons must fail). `ffprobe` and OpenH264 report the decoded size per config
  (1280x720 and 1920x1080, which proves the cropping). PNGs per config are written to `.sim/h264/<config>/png/`
  (`src_<n>`, `jm_<n>`, `oh_<n>`, `ff_<n>`, `side_<n>`).
* `testbench/h264_mutation.ps1`: four mutations (emulation prevention off, chroma floor rounding, wrong
  `first_mb_in_slice` for slice 2, ring-full guard removed), each restored byte for byte (SHA-256 checked).
* Synthesis check `testbench/h264_synth.tcl` through `scripts/rtlnet_vivado.ps1`.

### Tool builds (no hardcoded paths)

Tools resolve through `scripts/rtlnet_tools.ps1` (environment overrides: `RTLNET_HOST_CC`, `RTLNET_HOST_CXX`,
`RTLNET_FFMPEG`, `RTLNET_VLC`, `RTLNET_PYTHON`, `RTLNET_MSYS2`, `RTLNET_LDECOD`, `RTLNET_H264DEC`, `RTLNET_TOOLS_DIR`;
sources: `RTLNET_JM_SRC`, `RTLNET_OPENH264_SRC`). Python runs as `python -I`. `testbench/h264_build_decoders.ps1` copies
the read-only reference sources into `%LOCALAPPDATA%\RTLNet\tools\jm` and `...\openh264` and builds with the AMD install's MinGW
gcc 10.0.0 (`tps/mingw`):

```
# JM 19.1 (source/app/ldecod/*.c, source/lib/lcommon/*.c copied to src/; win32.h patched: "#if (_MSC_VER < 1400)" -> "#if 0")
gcc -O2 -w -I src -o bin/ldecod.exe src/*.c -lm -lws2_32
# OpenH264 2.7.0 decoder, no assembly (codec/common, decoder, api, console/dec, console/common copied to src/)
g++ -O2 -w -DNDEBUG -Icodec/api/wels -Icodec/common/inc -Icodec/decoder/core/inc -Icodec/decoder/plus/inc \
    -Icodec/console/common/inc -Icodec/console/dec/inc -Icodec/api -o ../bin/h264dec.exe \
    codec/common/src/*.cpp codec/decoder/core/src/*.cpp codec/decoder/plus/src/welsDecoderExt.cpp \
    codec/console/dec/src/*.cpp codec/console/common/src/read_config.cpp -ld3d9 -lole32 -lwinmm
```

Decoder versions: JM 19.1 (FRExt), OpenH264 2.7.0, FFmpeg 9.0.2. Run the regression entries with
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1 -Match h264`; run the harness alone with
`powershell -NoProfile -ExecutionPolicy Bypass -File cores/rtlnet_h264_enc/testbench/h264_harness.ps1 [-Config <names>] [-Inject]`.
Configurations: `qcif_s1`, `qcif_s3`, `qcif_bars`, `qcif_2pic`, `qcif_zeros`, `qcif_ring` (24 KiB ring and a slow consumer),
`qcif_e2_s2`, `qcif_e2_s4`, `qcif_e2_2pic`, `720p_e1_s1`, `720p_e2_s2` (bands 23 and 22), `720p_e2_s4`, `1080p_e1_s1`,
`1080p_e2_s2`, `1080p_e2_s4`. In `<mode>_e<engines>_s<slices>` the slice count is for the whole picture.

## 11. Results (11-09-2026)

Decoder harness: all 15 configurations print `TEST PASS: rtlnet_h264_top_<config>` with JM, OpenH264 and FFmpeg each
byte-identical to the rebuilt picture, and the rebuilt picture identical to the generator's 4:2:0 reference. FFmpeg and
OpenH264 report 1280x720 for the 720p configs and 1920x1080 for the 1080p configs. The negative control
(`qcif_s1`, `qcif_e2_s2`, `qcif_e2_s4`) fails all three decoder comparisons as required. Mutations: 4 of 4 caught.

Cycles per macroblock (the coder is the limit; clocks between macroblock starts):

| Config | Engine | MBs | CYC_LAST | CYC_MAX | PIC_CYC | RD_CYC / MB | PK_CYC / MB | WR_CYC / MB |
|---|---|---|---|---|---|---|---|---|
| 720p_e1_s1 | 0 | 3600 | 391 | 409 | 1 407 799 | 83 | 388 | 168 |
| 720p_e2_s2 | 0 (23 rows) | 1840 | 391 | 409 | 719 651 | 110 | 388 | 197 |
| 720p_e2_s2 | 1 (22 rows) | 1760 | 391 | 391 | 688 422 | 126 | 388 | 194 |
| 1080p_e1_s1 | 0 | 8160 | 391 | 391 | 3 190 779 | 83 | 388 | 168 |
| 1080p_e2_s4 | 0 (34 rows) | 4080 | 391 | 415 | 1 595 536 | 87 | 388 | 198 |
| 1080p_e2_s4 | 1 (34 rows) | 4080 | 391 | 415 | 1 595 548 | 91 | 388 | 194 |

Per macroblock the clocks go to: coder (packer) 388 (one sample byte per clock plus the macroblock header), read DMA 83 to 126
(latency overlapped with the previous macroblock's coding), write master 168 to 198 (ring bursts, 32 rebuilt-row writes,
index entries). Read, packer and write run in parallel, so the interval is the coder's 391. The 1080p picture takes 1.60 M
clocks per engine at 2 engines (15.96 ms at 100 MHz against the 33.3 ms frame time), 391 clocks per macroblock against the
816-clock budget. A stream rich in zero runs (the `zeros` pattern, 25 % emulation-prevention bytes) lengthens a macroblock to 487
clocks (maximum 510) because the packer writes one byte per clock; real I_PCM pictures stay at 391.

Verilator run times (simulation only, per config; the 14 to 18 s of each harness line is the one-time model build):
720p e1 0.80 s, 720p e2 0.67 s, 1080p e1 1.82 s, 1080p e2 1.4 s. The whole 15-configuration harness runs in about 6 minutes.

Out-of-context synthesis, `xc7a200tsbg484-1`, `enc_clk` 100 MHz (10.000 ns), default MAX_MB_W 120 / MAX_MB_H 68, 0 critical
warnings, post-synthesis timing (net delays estimated, no placement):

| NUM_ENGINES | RAM_STYLE | LUT | of which LUTRAM | FF | RAMB36 | RAMB18 | DSP | WNS |
|---|---|---|---|---|---|---|---|---|
| 2 (default) | "block" (default) | 8318 | 264 | 9096 | 12 | 0 | 0 | +2.528 ns |
| 2 | "distributed" | 9385 | 1336 | 9896 | 0 | 0 | 0 | +2.528 ns |
| 1 | "distributed" | 4938 | 668 | 5361 | 0 | 0 | 0 | +3.517 ns |

With `RAM_STYLE` "block" each engine uses 6 RAMB36: the two 128-bit macroblock banks and the 144-bit compressed-ring FIFO
are each two tiles wide. The board build may pass "distributed" to trade the 12 tiles for about 1,070 LUTs.

`h264_synth.tcl` fails (exit 10) on a critical warning or on a post-synthesis WNS below 0. The pipeline carries extra register
stages (command stage in the engine, four command stages and an output skid in the packer, an input skid and registered
space flags in the ring writer); they cost one clock per macroblock.

## 12. Open points

* The register-crossing constraints of `rtlnet_axil_cdc` (`scripts/rtlnet_constrain_cdc.tcl`) apply in the board build.
* The per-engine master vectors connect to the DDR3 arbiter on `ui_clk` in phase 2b-3, with no `rtlnet_axi_cdc`.
* Phase 2b-2 replaces `rtlnet_h264_mb_pcm`; the 2-engine band split, the rings and the rebuilt-picture path stay.
