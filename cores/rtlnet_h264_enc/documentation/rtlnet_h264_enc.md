# rtlnet_h264_enc: H.264 encoder core, phase 2b-2 (Intra16x16, transform, quantizer, CAVLC, I_PCM fallback)

Revision: 11-09-2026

## 1. Purpose and scope

`cores/rtlnet_h264_enc` encodes one picture per start into an H.264 Constrained Baseline Annex B stream
(ITU-T Rec. H.264 (06/2026), profile_idc 66, constraint_set1_flag 1, CAVLC, deblocking off). Phase 2b-1 proved the pipeline
with I_PCM macroblocks; phase 2b-2 adds the lossy coder: Intra16x16 luma prediction (vertical, horizontal, DC, plane) and
chroma prediction by SAD, the 4x4 integer transform with the luma and chroma DC transforms, the quantizer, CAVLC residual
coding and the rebuild loop (dequantizer, inverse transform, prediction add), so the rebuilt picture equals what a decoder
shows. Every I slice macroblock is Intra16x16 unless it falls back to I_PCM (section 3.3). The read DMA with 4:2:2 to 4:2:0
conversion, the bit packer with emulation prevention, the NAL and slice syntax, the write DMA into a compressed ring, the
index ring and the rebuilt-picture write are unchanged from phase 2b-1.

Two video modes run on one build, selected by registers (VIDEO_MODE of the camera design):

| Mode | Frame | Macroblocks | Cropping | level_idc | Bands at NUM_ENGINES = 2 |
|---|---|---|---|---|---|
| 0 = 720p30 (default) | 1280x720 | 80 x 45 | none | 31 | 23 and 22 rows |
| 1 = 1080p30 | 1920x1080 coded as 1920x1088 | 120 x 68 | bottom 8 lines (frame_crop_bottom_offset 4) | 40 | 34 and 34 rows |

## 2. Clocking and engine count

* `enc_clk` carries the engines, their memory ports and the register file. The board runs it from the MIG `ui_clk`,
  90.000 MHz (the one system clock of the board); the out-of-context synthesis check constrains it to 11.111 ns.
* `s_axi_aclk` (cpu_clk) carries only the AXI4-Lite slave side of `rtlnet_axil_cdc`. Both resets release from one assertion.
* `NUM_ENGINES = 2` is the default. 1080p30 needs 8160 x 30 = 244 800 macroblocks per second. Two engines at 100 MHz have a
  budget of 90e6 / (8160 x 30) x 2 = 735 clocks per macroblock per engine (816 at 100 MHz); one engine has 367. Section 11.1 lists the measured
  clocks per macroblock: 373 for smooth content, at most 500 on dense content at QP 12 and above. Each engine codes a
  horizontal band of macroblock rows as its own slice(s).
* A band split is a register property: the first `NUM_ENGINES - 1` engines take `ceil(MB_H / NUM_ENGINES)` rows, the last
  engine the rest. `SLICES` is the slice count of the whole picture and must be a multiple of `NUM_ENGINES`; each engine
  codes `SLICES / NUM_ENGINES` slices of whole macroblock rows inside its band.

## 3. Block hierarchy and pipeline

```
rtlnet_h264_top                      top: registers, the engine array, completion aggregation
  rtlnet_axil_cdc                    s_axi_aclk -> enc_clk AXI4-Lite crossing (rtlnet_common)
  rtlnet_axil_slave                  AXI4-Lite to strobes (rtlnet_common)
  rtlnet_h264_enc_regs               register file (strobe interface), engine windows
  rtlnet_h264_engine  x NUM_ENGINES  one engine, one AXI4 master
    rtlnet_h264_rd_dma               16 read bursts per macroblock, 2 beats each
      rtlnet_h264_c422to420          YUYV 4:2:2 rows to 4:2:0 macroblock rows
    rtlnet_ram_core                  source macroblock buffer (2 banks of 24 words of 16 bytes)
    rtlnet_h264_mb_enc               stage A: mode decision, transform, quantizer, rebuild loop, I_PCM copy
      rtlnet_h264_ipred              Intra16x16 / chroma prediction candidates, SAD, mode decision
      rtlnet_h264_fwdq               forward 4x4 transform and AC quantizer (4 lanes, 3 stages)
      rtlnet_h264_dcq_luma           luma DC: 4x4 Hadamard, quantizer, inverse Hadamard and scaling
      rtlnet_h264_dcq_chroma  x 2    chroma DC (Cb, Cr): 2x2 transform, quantizer, inverse and scaling
      rtlnet_h264_invq               dequantizer and inverse 4x4 transform of the rebuild loop
      rtlnet_ram_core                line RAM: rebuilt bottom row of the macroblock row above
    rtlnet_ram_core  x 2             coefficient buffer copies (2 banks of 128 words of 48 bits): stage A read-back, stage B read
    rtlnet_ram_core                  rebuilt macroblock buffer (2 banks of 96 words of 4 samples)
    rtlnet_h264_mb_cavlc             stage B: macroblock layer syntax, nC, two block coders, I_PCM layer
      rtlnet_h264_cavlc_blk  x 2     CAVLC residual block coder (ping-pong), coeff_token / total_zeros / run_before tables
      rtlnet_ram_core                upper-neighbour total_coeff line RAM
    rtlnet_h264_recon_wr             rebuilt-picture rows, 32 single-beat writes per macroblock
    rtlnet_h264_bitpack              ue/se, fields, start codes, trailing bits, emulation prevention
    rtlnet_h264_ring_wr              byte gather, word FIFO (rtlnet_ram_core), bursts, index entries, pointers
    rtlnet_h264_wr_master            ring / index / rebuilt write requests onto AW, W, B
  rtlnet_h264_pkg                    shared constants
```

Files: `hdl/rtlnet_h264_top.sv` (top), `hdl/rtlnet_h264_enc_regs.sv`, `hdl/rtlnet_h264_engine.sv` (one engine), the
datapath modules above, `hdl/rtlnet_h264_enc.f` (compile order), `driver/rtlnet_h264_enc.{h,c}`, `testbench/`.
`rtlnet_h264_mb_pcm` of phase 2b-1 is gone: the I_PCM macroblock layer is written by stage B like any other.

### 3.1 Macroblock pipeline

The fetch sequencer fills two source banks through the read DMA. Stage A codes one macroblock from a source bank into a
coefficient bank and a rebuilt bank; the source bank is released when A is done. Stage B turns the coefficient bank of the
previous macroblock into packer commands meanwhile, and the rebuilt-picture writer drains the rebuilt bank. A starts the next
macroblock when a source bank is full and a coefficient and a rebuilt bank are free, so the throughput is the larger of the
two stages. A cannot run further ahead: the neighbours of the next macroblock (left column, bottom row of the row above)
come from its own rebuild.

Stage A phases (`rtlnet_h264_mb_enc`):

| Phase | Clocks | Work |
|---|---|---|
| TOP, PREP | about 20 | neighbours from the line RAM and registers into `ipred`; plane parameters and DC values |
| SAD | 96 + 10 | 96 row segments (16 luma blocks, 4 Cb, 4 Cr blocks, 4 rows each) accumulate the SAD of every legal mode; the mode decision |
| PASS1 | 96 + about 20 | source minus prediction, forward transform, AC quantizer, levels into the coefficient RAM; the 24 DC coefficients into the DC units |
| CHK | 3 | fallback decision (section 3.3) |
| DCW | 6 | DC levels into the coefficient RAM; the coded block pattern |
| PASS3 | 96 + about 15 | rebuild: levels, dequantizer, inverse transform, prediction add and clip, into the rebuilt RAM; left column and bottom row captured |
| LINE | 2 | bottom row into the line RAM |

The fixed cost is about 373 clocks per macroblock. A fallback macroblock replaces DCW and PASS3 by the I_PCM copy (about 100 clocks).

Stage B (`rtlnet_h264_mb_cavlc`): a reader fetches the next block (4 words of the coefficient RAM, 1 for a chroma DC block)
into a raster buffer while the blocks before it are coded; the dispatcher applies the zigzag order, counts the non-zero levels
(TotalCoeff) and computes nC of the block at dispatch, then starts one of two block coders. The coders work in ping-pong in
block order; the output follows the same order, so the second coder has done its analysis (non-zero mask, trailing ones,
coeff_token) and holds its first command when the first coder finishes. Per block coder (`rtlnet_h264_cavlc_blk`): PRE,
trailing ones (one per clock, at most 3), coeff_token with the trailing-one signs, levels (two per clock), total_zeros, run_before
codes (two per clock), FIN. nC needs only the neighbours' TotalCoeff, which the dispatcher counts directly from the levels, so
a block does not wait for its predecessor's coder.

### 3.2 Throughput design

Stage B was the limit of the first 2b-2 implementation (one block coder with one command per level and one per run_before:
822 clocks per macroblock on random content against the 816-clock budget). The measured causes were about 10 clocks of
per-block overhead (27 blocks per macroblock) and two clocks per non-zero coefficient. The changes, with the reasons:

* **Two block coders in ping-pong** with in-order command merge. The per-block overhead (PRE, trailing ones, coeff_token,
  the first level pipeline stages) of block k+1 overlaps the commands of block k. This is a cheap change (the coder is small)
  and needs no change of the packer interface. The dispatcher counts TotalCoeff from the levels at dispatch, which removes
  the only dependency between consecutive blocks.
* **Two levels per clock**: the second level code uses the suffixLength that follows from the first; both fields go out in
  one 32-bit packer command when their lengths add up to at most 32 bits (always true unless both levels are large escapes),
  otherwise in two commands in two clocks.
* **Two run_before codes per clock**: a run_before code has at most 11 bits, two fit one command; the second code is coded only
  while zerosLeft stays above zero after the first.
* **Per-macroblock I_PCM fallback** caps the bits of a macroblock at the I_PCM size (3081 bits, 386 bytes). With the packer's
  one byte per clock this also caps the packer time of a macroblock at about 390 clocks, so a wider packer (for example 4 bytes
  per clock with emulation prevention) is not needed: the packer is no longer the limit at the 650-clock budget.
* Deeper buffering between A and B (more coefficient banks) is not needed either: the averages (section 11.1) are far
  inside the budget. The two banks absorb one macroblock of peak.

Results (section 11.1): at QP 12 and above, every content in the test set averages at most 500 clocks per macroblock
(`PIC_CYC / macroblocks`; limit 650), and smooth content stays at 373 to 380 (limit 500). Below QP 12 only correctness is
specified.

### 3.3 I_PCM fallback and the QP clamp

Stage A decides per macroblock, after the quantizer (state CHK), whether it codes the macroblock as I_PCM:

* any quantized level at the baseline limit: the quantizers clamp a level to +-2047 (12 bits; baseline `level_prefix` is at
  most 15, so a level is coded with at most 28 bits), and a clamped level makes the coded macroblock differ from the source
  at low QP; or
* the estimate of the CAVLC size of the macroblock exceeds the I_PCM size, `EST_LIMIT` = 3072 bits.

The estimate is `21 + 16 x (non-empty blocks) + sum over levels of cost(bit length of |level|)`, with the costs
1, 5, 5, 6, 13, 16, 16, 18, 34, 71, 71 bits for bit lengths 1 to 11 (a least-squares fit to the coded sizes of 3721 macroblocks
of the 176x144 content and QP set; root-mean-square error 220 bits, the fit is conservative for the dense macroblocks that
decide). It is an estimate, not a bound: the exact size needs the suffixLength history of every block, which is only known
when stage B codes the macroblock, after stage A has rebuilt it and the neighbours depend on the choice. Over the 3721
macroblocks, the coded size of every macroblock below the limit stays at or under 3125 bits; the Level limit is 3200 bits
per macroblock layer (128 + RawMbBits). The estimate accepts a macroblock only when it is at or below the limit, so the fallback
also happens on QP 0 content for macroblocks the estimate cannot prove smaller than I_PCM.

A fallback macroblock: stage A copies the source macroblock into the rebuilt bank and into the coefficient bank (96 words, one
sample word of 4 samples in each, first sample in the top byte: the I_PCM sample order of the stream); the left column and the
bottom row of the rebuilt macroblock are captured from the source, so the neighbours of the next macroblocks see the source
samples, which is what a decoder reconstructs. Stage B writes `mb_type` ue(v) = 25, `pcm_alignment_zero_bit`s, and the 96
words as 32-bit packer fields (no intra chroma mode, no `mb_qp_delta`), and counts 16 coefficients in every block for its
neighbours' nC (clause 9.2.1). MB_MODE bit 0 forces the fallback for every macroblock (debug mode, exact rebuilt picture).

**Root cause of the failure the first 2b-2 implementation showed on QP 0 content.** With `qcif_checker_q0` (0/255 checkerboards,
QP 0) the rebuilt picture decoded consistently in all three decoders, but its PSNR against the source was 18.3 dB (luma 16.5 dB).
Flat high-contrast cells give 4x4-block DC coefficients of up to 16 x 127; the luma DC Hadamard sums 16 of them, and the DC level
at QP 0 is (16 x 16 x 127 x 13107) >> 17, about 3250, above the clamp of 2047. The clamped level reconstructs a different
block: the encoder coded the wrong content, and since the rebuild uses the clamped levels the decoders agree with it. Evidence:
a debug count of macroblocks with a level at the clamp (32 of 99 in that picture) marked exactly the macroblocks that had a
maximum rebuilt error above 6 (error map: rows 0 and 1 columns 5, 7 to 10; row 2 columns 5, 7, 9; row 3 column 10; row 4
column 5; row 5 columns 0, 2, 3, 5; row 6 columns 1 to 3; row 7 column 0; row 8 column 1: errors of 20 to 175 on the same
macroblocks; every other macroblock showed an error of at most 1). With the fallback the picture reaches 84.4 dB (luma), and the
macroblocks coded as I_PCM are exact. The earlier one-macroblock decoder mismatch was the same cause: a level at the clamp.

**QP clamp.** Below QP 12 the quantized levels of dense content are large and macroblocks are over the clock budget: a
macroblock with many levels above 15 costs about 30 bits each and stage B at two levels per clock cannot code it within 650 clocks
on average. The driver therefore writes `max(QP, RTLNET_H264_QP_MIN_REALTIME)` into the QP register, with
`RTLNET_H264_QP_MIN_REALTIME` = 12 (a constant of `driver/rtlnet_h264_enc.h`). The hardware is correct below 12 (tested at QP 0 and
18), only slower; laboratory runs write the register directly.

## 4. Parameters of `rtlnet_h264_top`

| Parameter | Default | Meaning |
|---|---|---|
| NUM_ENGINES | 2 | slice-band engines, 1..4 |
| MAX_MB_W, MAX_MB_H | 120, 68 | widest and tallest picture in macroblocks (1920x1088); range-checks and CAPS |
| ADDR_W | 32 | only 32 supported (elaboration `$fatal`) |
| ID_W | 4 | AXI ID width of each engine port |
| MB_BUF_KB | 1 | source macroblock buffer, KiB (two banks of 24 words use 768 B) |
| REC_BUF_KB | 1 | rebuilt macroblock buffer, KiB (two banks of 96 words of 4 samples) |
| COEF_BUF_KB | 1 | coefficient buffer per copy, KiB (two banks of 128 words of 48 bits) |
| LINE_KB | 4 | line RAM of stage A, KiB (two 16-byte words per macroblock column) |
| FIFO_KB | 1 | ring word FIFO per engine, KiB (64 words of 16 bytes plus strobes) |
| RAM_STYLE | "block" | `rtlnet_ram_core` style, "block" or "distributed" |

All memories are instances of `rtlnet_ram_core`. Frame size, band split, slice count and QP come from registers, not
parameters, so one build codes both video modes.

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
| 0x02C | QP | RW | slice QP 0..51; `slice_qp_delta = QP - 26` (reset 26). The driver writes at least `RTLNET_H264_QP_MIN_REALTIME` (12) |
| 0x030 | FRAME_NUM | RW | frame_num written in `log2_max_frame_num` bits |
| 0x034 | IDR_PIC_ID | RW | idr_pic_id of an IDR picture |
| 0x038 | PIC_CFG | RW | [0] IDR picture (reset 1), [12:8] log2_max_frame_num (reset 4, range 4..16) |
| 0x03C | MB_MODE | RW | [0] 1 = every macroblock is I_PCM (debug, exact rebuilt picture), 0 = Intra16x16 with the per-macroblock I_PCM fallback (reset 0) |
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
| 0x0AC | PK_CYC | RO | clocks the macroblock coder (stage A or stage B) was busy |
| 0x0B0 | WR_CYC | RO | clocks the write master was busy |

Engine windows: the per-engine registers (0x068 .. 0x088 and 0x098 .. 0x0B0) of engine e are at `0x100 x e + offset`;
window 0 is engine 0. Writes to RING_RPTR and IDX_RPTR in window e go to engine e. The configured ring and index ring are
split into `NUM_ENGINES` equal shares, engine e using share e: `RING_SIZE / NUM_ENGINES` bytes from
`RING_BASE + e x RING_SIZE / NUM_ENGINES`, and `IDX_ENTRIES / NUM_ENGINES` entries from
`IDX_BASE + 16 x e x IDX_ENTRIES / NUM_ENGINES`.

Rules: write the configuration while the core is idle, at least a few clocks before START (the check is registered); write
RING_RESET once after changing RING_BASE or RING_SIZE and before the first picture. START with an illegal configuration
sets ERR with code 1 and starts nothing. `STATUS.DONE` sets when every engine has finished. A ring share must hold the
largest slice NAL unit (about 400 bytes per macroblock row-slice macroblock in the worst case, I_PCM): the firmware reads a slice
after its index entry appears, which is after the whole NAL unit is in the ring.

## 7. Memory formats

**Input frame**, packed YUYV 4:2:2, 2 bytes per pixel, line stride `IN_STRIDE`. Byte order per pixel pair: `Y0 U0 Y1 V0`.
One macroblock row is 32 bytes (16 pixels), two 16-byte beats; byte 0 of a beat is the low byte of the 128-bit word.
Conversion to 4:2:0: luma passes through; each chroma sample is `(a + b + 1) >> 1` of the same column in the two vertically
adjacent rows (rows 2r and 2r+1 of the macroblock), rounding up.

**Source macroblock buffer** (per bank, 16-byte words): words 0..15 the luma rows (pixel i in byte i); words 16..23 chroma rows,
Cb(0..7) in bytes 0..7 and Cr(0..7) in bytes 8..15.

**Rebuilt macroblock buffer** (32-bit words of 4 samples, per bank of 128): luma word `4 y + bx`, Cb word `64 + 2 y + bx`, Cr word
`80 + 2 y + bx`.

**Coefficient buffer** (48-bit words, 4 signed 12-bit levels each, per bank of 128 words): words 0..3 luma DC level matrix
rows; word `4 + 4 tag + row` for the 24 blocks (tag = `4 by + bx` luma, `16 + 2 by + bx` Cb, `20 + 2 by + bx` Cr), the
coefficient row `row` of the block in raster order (position (0,0) of AC blocks holds 0); word 100 Cb DC, word 101 Cr DC. For an
I_PCM macroblock words 0..95 hold the sample words (low 32 bits, first sample in the top byte) in stream order.

**Rebuilt picture**: three planes, 8-bit samples. Luma at `RY_BASE`, line pitch `RY_STRIDE`; Cb at `RU_BASE` and Cr at
`RV_BASE`, line pitch `RC_STRIDE`, width/2 samples per line. The rebuilt picture is the decoder's output for the stream
(what JM, OpenH264 and FFmpeg decode, byte for byte). A luma row is one 16-byte write with full strobes; a chroma row is an
8-byte write into the low or high half of the 16-byte word (address bit 3) with an 8-bit strobe. The same planes later serve
as the reference buffer.

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
* Macroblock layer (clause 7.3.5), Intra16x16 macroblock: `mb_type` ue(v) = 1 + prediction mode + 4 x cbp_chroma + 12 x (cbp_luma
  != 0) (Table 7-11), `intra_chroma_pred_mode` ue(v), `mb_qp_delta` se(v) = 0, `Intra16x16DCLevel` (always, nC of luma block 0),
  the 16 `Intra16x16ACLevel` blocks when the luma cbp is 15 (zigzag positions 1..15, luma4x4BlkIdx order), the two
  `ChromaDCLevel` blocks (nC = -1) when cbp_chroma is not 0, the eight `ChromaACLevel` blocks when cbp_chroma is 2. Every block is
  `residual_block_cavlc` (clause 9.2): `coeff_token` (Tables 9-5 with the nC class of clause 9.2.1), the trailing-one signs,
  the level codes (`level_prefix` and `level_suffix`, suffixLength adaptation, escape at prefix 15), `total_zeros` (Tables
  9-7 to 9-9), `run_before` (Table 9-10). Slice QP only: `mb_qp_delta` is 0.
* Macroblock layer of a fallback macroblock: `mb_type` ue(v) = 25 (I_PCM), `pcm_alignment_zero_bit`s to the byte boundary, 256
  luma samples, 64 Cb samples, 64 Cr samples, 8 bits each, raster order. A PCM sample value of 0 is allowed: clause 7.4.5 states
  `pcm_sample_luma` and `pcm_sample_chroma` as sample values without a restriction in this edition, and emulation prevention
  protects any zero run.
* Slice end: `rbsp_slice_trailing_bits` (clause 7.3.2.8): one stop bit and zeros to alignment.
* A second IDR picture uses `frame_num` 0 (clause 7.4.3) and a new `idr_pic_id`, as the 2-picture runs do.
* SPS and PPS are written by firmware: `rtlnet_h264_enc_write_sps_pps()`. SPS: profile_idc 66, constraint_set1_flag 1,
  level_idc from the frame size and rate (Table A-1: 31 for 720p30, 40 for 1080p30), `pic_order_cnt_type` 2,
  `max_num_ref_frames` 1, `frame_mbs_only_flag` 1, frame cropping 1088 to 1080 (`frame_crop_bottom_offset` 4). PPS: CAVLC
  (`entropy_coding_mode_flag` 0), `deblocking_filter_control_present_flag` 1, `pic_init_qp` 26 (`pic_init_qp_minus26` 0).

Quantization: forward AC `level = (|W| x MF + f) >> qbits`, `qbits = 15 + QP/6`, `f = 2^qbits / 3` (intra), luma DC on the
Hadamard of the 16 block DCs with `qbits + 1` and `2 f`, chroma DC on the 2x2 transform of the four DCs with QPc = table of
clause 8.5.8 for `chroma_qp_index_offset` 0; dequantization and the inverse transforms are the clause 8.5 integer arithmetic.

## 9. Driver

`driver/rtlnet_h264_enc.{h,c}` (C, `rtlnet_mmio.h` for register access): `probe`, `get_mode` / `set_mode` (0 = 720p30,
default; 1 = 1080p30: writes MB_W, MB_H, fills the SPS parameters), `band_rows` (the ceil split), `configure`, `ring_reset`,
`start_picture`, `wait_done`, `status`, `clear_status`, `set_read_pointers`, `index_wptr`, `decode_index_entry`,
`read_stats` and `write_sps_pps`. `configure` writes `max(cfg->qp, RTLNET_H264_QP_MIN_REALTIME)` into the QP register
(`RTLNET_H264_QP_MIN_REALTIME` = 12, section 3.3); `cfg->mb_pcm` writes MB_MODE. The host test
`testbench/test_rtlnet_h264_enc_driver.c` checks the register writes against a register model (including the QP clamp at 5, 12
and 51) and checks the SPS and PPS bytes with an independent bit reader (fields, emulation prevention, level, cropping,
rejections), including the 720p30 and 1080p30 modes and the bands (23/22 and 34/34).

## 10. Verification flow (Verilator)

All H.264 RTL benches run in Verilator 5.050 (MSYS2 UCRT64, g++ 16.2), through `scripts/rtlnet_run_verilator.ps1`
(`--binary --timing`, with `-MAKEFLAGS 'OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2'` for the gcc 16 libstdc++ link issue at
-Os). The runner scans for `TEST PASS: <bench>` (a missing token, a `%Error` or a `TEST FAIL` fails). Regression lines carry
`sim=verilator`; a `script:` line runs a host script (decoder harness, driver test, lint).

* RAM model: the benches compile `rtlnet_ram_core` with `RTLNET_TECH_GENERIC` (the runner defines it). The generic branch is
  a registered-read array with a clocked write: read latency 1, the output register holds while `rd_en` is low,
  `rd_resetn` clears it, and a read in the clock of a write to the same address returns the old word. That is the
  behavior of the AMD branch (xpm_memory_sdpram, READ_LATENCY_B 1, `read_first` for distributed RAM, `no_change`
  for block RAM in common clock mode) the board uses, so the encoder sees the same cycle behavior in both.
* Benches are race-free for Verilator: bench outputs change at the falling clock edge and inputs are sampled there.
* Lint gate: `testbench/h264_lint.ps1` runs `verilator --lint-only -Wall` on the encoder RTL (not the benches) and a
  text scan for multi-edge sensitivity lists.
* Unit benches, each with a `+INJECT_FAILURE` negative control: `tb_rtlnet_h264_bitpack`, `tb_rtlnet_h264_c422`,
  `tb_rtlnet_h264_cavlc` (CAVLC block coder against a reference written from clause 9.2 and the tables, 37 885 checks, random
  blocks of all `nC` classes, `maxNumCoeff` 4, 15 and 16, levels up to 2047, random back-pressure; the CAVLC tables are also
  cross-checked against OpenH264 and JM, 0 mismatches), `tb_rtlnet_h264_mbcavlc` (macroblock layer, nC, the neighbours across
  macroblocks and slices, I_PCM macroblocks inside the pictures with a random bit offset for the alignment), `tb_rtlnet_h264_xform`
  (forward and inverse transform, quantizers and the DC units, 274 372 checks) and `tb_rtlnet_h264_ipred` (prediction candidates, SAD
  and mode decision, 54 241 checks).
* Encoder bench `tb_rtlnet_h264_top`: loads the input image into a memory model (`tb_h264_axi_mem`, behind the real
  `rtlnet_axi_arbiter`), programs the registers over AXI4-Lite, plays the firmware (polls the index rings, copies each
  slice out of each engine's ring, advances the read pointers), checks index entries, NAL framing, `first_mb_in_slice`
  against an independent band/slice computation, and dumps the stream and the rebuilt planes. `+INJECT` corrupts one byte
  of the dumped stream after the rebuilt picture is written.
* Decoder harness `testbench/h264_harness.ps1`: generates the input (`h264_gen.py`: bars, gradient, noise, zeros, square, gradnoise,
  zoneplate, edges, checker, photo), writes SPS/PPS with the driver (`h264_spspps_tool`), runs the bench, assembles the stream
  (`h264_check.py`), decodes with JM `ldecod`, OpenH264 `h264dec` and FFmpeg (`-f rawvideo -pix_fmt yuv420p`), and compares each decoded
  YUV byte for byte with the rebuilt YUV. It prints PSNR (Y, Cb, Cr, overall) of the rebuilt picture against the 4:2:0 source and the
  bits per picture, and enforces the floor of its (pattern, QP) pair from `h264_psnr_floors.txt` (about 1 dB below the measured
  value; `-Measure` prints candidate lines). `TEST PASS: rtlnet_h264_top_<config>` needs all three decoders byte-identical and the
  floor met; `-Inject` runs the negative control (all three comparisons must fail); `-Pcm` runs the global I_PCM mode (the rebuilt
  picture must equal the source exactly). `ffprobe` and OpenH264 report the decoded size per config (1280x720 and 1920x1080, which
  proves the cropping). PNGs per config are written to `.sim/h264/<config>/png/` (`src_<n>`, `jm_<n>`, `oh_<n>`, `ff_<n>`, `side_<n>`).
* `testbench/h264_mutation.ps1`: 13 mutations, each restored byte for byte (SHA-256 checked) (section 11.4).
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
`powershell -NoProfile -ExecutionPolicy Bypass -File cores/rtlnet_h264_enc/testbench/h264_harness.ps1 [-Config <names or wildcards>] [-Inject] [-Pcm] [-Measure]`.
Configurations: the QCIF structure checks `qcif_s1`, `qcif_s3`, `qcif_bars`, `qcif_2pic`, `qcif_zeros`, `qcif_ring` (16 KiB ring and a slow
consumer), `qcif_e2_s2`, `qcif_e2_s4`, `qcif_e2_2pic` (QP 28); the content and QP matrix `qcif_<pattern>_q<QP>`; and `<720p|1080p>_e<engines>_s<slices>_q<QP>`
with 1 and 2 engines, 1, 2 and 4 slices of the whole picture, QP 18, 28, 38 and 51 (the slice count is for the whole picture).

## 11. Results (11-09-2026)

### 11.1 Throughput

Clocks per macroblock = `PIC_CYC / MB_COUNT` of an engine (CYC_LAST and CYC_MAX are the clocks between macroblock starts; PIC_CYC
includes the slice headers and the pipeline fill). Budget at 1080p30 on 2 engines at 100 MHz: 816. Required: at most 650 for every
content at QP 12 and above, at most 500 for typical content.

| Content (176x144 unless noted) | CYC_LAST | CYC_MAX | clocks / MB |
|---|---|---|---|
| bars, gradient, photo QP 28 (typical) | 378 | 378 | 381 |
| edges QP 18 | 378 | 400 | 382 |
| noise QP 38 (dense, lossy) | 468 | 506 | 484 |
| zeros pattern QP 28 | 487 | 502 | 452 |
| noise QP 18, 28 (dense; I_PCM fallback for most macroblocks) | 386 to 432 | 499 | 389 to 437 |
| checker QP 0 / noise QP 0 (below the clamp) | 437 / 432 | 498 / 432 | 413 / 437 |
| 720p, 1080p, 1 and 2 engines (smooth synthetic content) | 378 | 378 to 417 | 378 |

The largest picture average at QP 12 and above over all 90 engine rows is 484 clocks per macroblock (`qcif_noise_q38`); typical
content is 378 to 382. For comparison the first 2b-2 implementation needed 822 clocks per macroblock on noise at QP 28 and 828 on the
zeros pattern, and the packer-limited I_PCM coder of 2b-1 needed 391. The measured peaks per macroblock (CYC_MAX) stay at or
below 506. Cycles of every harness configuration:

| Config | Engine | MBs | CYC_LAST | CYC_MAX | PIC_CYC | PIC_CYC / MB |
|---|---|---|---|---|---|---|
| qcif_s1 | 0 | 99 | 386 | 386 | 38539 | 389 |
| qcif_s3 | 0 | 99 | 386 | 815 | 38931 | 393 |
| qcif_bars | 0 | 99 | 378 | 378 | 37712 | 381 |
| qcif_2pic | 0 | 99 | 378 | 417 | 37780 | 382 |
| qcif_zeros | 0 | 99 | 487 | 502 | 44769 | 452 |
| qcif_ring | 0 | 99 | 492 | 7717 | 59912 | 605 |
| qcif_e2_s2 | 0 | 55 | 378 | 378 | 21144 | 384 |
| qcif_e2_s2 | 1 | 44 | 378 | 378 | 16993 | 386 |
| qcif_e2_s4 | 0 | 55 | 386 | 815 | 21813 | 397 |
| qcif_e2_s4 | 1 | 44 | 386 | 815 | 17561 | 399 |
| qcif_e2_2pic | 0 | 55 | 378 | 378 | 21117 | 384 |
| qcif_e2_2pic | 1 | 44 | 378 | 378 | 16973 | 386 |
| qcif_photo_q0 | 0 | 99 | 463 | 488 | 44740 | 452 |
| qcif_photo_q18 | 0 | 99 | 378 | 378 | 37748 | 381 |
| qcif_photo_q28 | 0 | 99 | 378 | 378 | 37712 | 381 |
| qcif_photo_q38 | 0 | 99 | 378 | 378 | 37718 | 381 |
| qcif_photo_q51 | 0 | 99 | 378 | 378 | 37736 | 381 |
| qcif_gradnoise_q0 | 0 | 99 | 449 | 525 | 47202 | 477 |
| qcif_gradnoise_q18 | 0 | 99 | 423 | 458 | 43643 | 441 |
| qcif_gradnoise_q28 | 0 | 99 | 378 | 378 | 37746 | 381 |
| qcif_gradnoise_q38 | 0 | 99 | 378 | 378 | 37744 | 381 |
| qcif_gradnoise_q51 | 0 | 99 | 378 | 378 | 37741 | 381 |
| qcif_zoneplate_q18 | 0 | 99 | 378 | 421 | 38168 | 386 |
| qcif_zoneplate_q28 | 0 | 99 | 378 | 378 | 37937 | 383 |
| qcif_zoneplate_q38 | 0 | 99 | 378 | 378 | 37860 | 382 |
| qcif_edges_q0 | 0 | 99 | 378 | 432 | 39023 | 394 |
| qcif_edges_q18 | 0 | 99 | 378 | 400 | 37867 | 382 |
| qcif_edges_q28 | 0 | 99 | 378 | 384 | 37774 | 382 |
| qcif_edges_q38 | 0 | 99 | 378 | 380 | 37757 | 381 |
| qcif_checker_q0 | 0 | 99 | 437 | 498 | 40903 | 413 |
| qcif_checker_q18 | 0 | 99 | 378 | 390 | 37949 | 383 |
| qcif_checker_q28 | 0 | 99 | 378 | 378 | 37932 | 383 |
| qcif_checker_q38 | 0 | 99 | 378 | 378 | 37890 | 383 |
| qcif_noise_q0 | 0 | 99 | 432 | 432 | 43309 | 437 |
| qcif_noise_q38 | 0 | 99 | 468 | 506 | 47950 | 484 |
| qcif_gradient_q28 | 0 | 99 | 378 | 378 | 37722 | 381 |
| qcif_gradient_q51 | 0 | 99 | 378 | 378 | 37741 | 381 |
| qcif_bars_q18 | 0 | 99 | 378 | 378 | 37741 | 381 |
| qcif_bars_q51 | 0 | 99 | 378 | 378 | 37736 | 381 |
| qcif_zeros_q38 | 0 | 99 | 475 | 519 | 46297 | 468 |
| 720p_e1_s1_q18 | 0 | 3600 | 378 | 378 | 1361154 | 378 |
| 720p_e1_s1_q28 | 0 | 3600 | 378 | 378 | 1361163 | 378 |
| 720p_e1_s1_q38 | 0 | 3600 | 378 | 378 | 1361158 | 378 |
| 720p_e1_s1_q51 | 0 | 3600 | 378 | 378 | 1361129 | 378 |
| 720p_e1_s2_q18 | 0 | 3600 | 378 | 417 | 1361147 | 378 |
| 720p_e1_s2_q28 | 0 | 3600 | 378 | 696 | 1361634 | 378 |
| 720p_e1_s2_q38 | 0 | 3600 | 378 | 420 | 1361141 | 378 |
| 720p_e1_s2_q51 | 0 | 3600 | 378 | 417 | 1361178 | 378 |
| 720p_e2_s2_q18 | 0 | 1840 | 378 | 378 | 695858 | 378 |
| 720p_e2_s2_q18 | 1 | 1760 | 378 | 378 | 665662 | 378 |
| 720p_e2_s2_q28 | 0 | 1840 | 378 | 378 | 695902 | 378 |
| 720p_e2_s2_q28 | 1 | 1760 | 378 | 378 | 665843 | 378 |
| 720p_e2_s2_q38 | 0 | 1840 | 378 | 378 | 695862 | 378 |
| 720p_e2_s2_q38 | 1 | 1760 | 378 | 378 | 665645 | 378 |
| 720p_e2_s2_q51 | 0 | 1840 | 378 | 378 | 695929 | 378 |
| 720p_e2_s2_q51 | 1 | 1760 | 378 | 378 | 665714 | 378 |
| 720p_e2_s4_q18 | 0 | 1840 | 378 | 521 | 696005 | 378 |
| 720p_e2_s4_q18 | 1 | 1760 | 378 | 526 | 665824 | 378 |
| 720p_e2_s4_q28 | 0 | 1840 | 378 | 549 | 696060 | 378 |
| 720p_e2_s4_q28 | 1 | 1760 | 378 | 541 | 665825 | 378 |
| 720p_e2_s4_q38 | 0 | 1840 | 378 | 417 | 695901 | 378 |
| 720p_e2_s4_q38 | 1 | 1760 | 378 | 537 | 665821 | 378 |
| 720p_e2_s4_q51 | 0 | 1840 | 378 | 534 | 696027 | 378 |
| 720p_e2_s4_q51 | 1 | 1760 | 378 | 535 | 665837 | 378 |
| 1080p_e1_s1_q18 | 0 | 8160 | 378 | 378 | 3084833 | 378 |
| 1080p_e1_s1_q28 | 0 | 8160 | 378 | 378 | 3085035 | 378 |
| 1080p_e1_s1_q38 | 0 | 8160 | 378 | 378 | 3084853 | 378 |
| 1080p_e1_s1_q51 | 0 | 8160 | 378 | 378 | 3084829 | 378 |
| 1080p_e1_s2_q18 | 0 | 8160 | 378 | 417 | 3084859 | 378 |
| 1080p_e1_s2_q28 | 0 | 8160 | 378 | 615 | 3085225 | 378 |
| 1080p_e1_s2_q38 | 0 | 8160 | 378 | 417 | 3084849 | 378 |
| 1080p_e1_s2_q51 | 0 | 8160 | 378 | 527 | 3085036 | 378 |
| 1080p_e2_s2_q18 | 0 | 4080 | 378 | 378 | 1542631 | 378 |
| 1080p_e2_s2_q18 | 1 | 4080 | 378 | 378 | 1542669 | 378 |
| 1080p_e2_s2_q28 | 0 | 4080 | 378 | 378 | 1542609 | 378 |
| 1080p_e2_s2_q28 | 1 | 4080 | 378 | 378 | 1542651 | 378 |
| 1080p_e2_s2_q38 | 0 | 4080 | 378 | 378 | 1542569 | 378 |
| 1080p_e2_s2_q38 | 1 | 4080 | 378 | 378 | 1542623 | 378 |
| 1080p_e2_s2_q51 | 0 | 4080 | 378 | 378 | 1542642 | 378 |
| 1080p_e2_s2_q51 | 1 | 4080 | 378 | 378 | 1542681 | 378 |
| 1080p_e2_s4_q18 | 0 | 4080 | 378 | 417 | 1542647 | 378 |
| 1080p_e2_s4_q18 | 1 | 4080 | 378 | 417 | 1542662 | 378 |
| 1080p_e2_s4_q28 | 0 | 4080 | 378 | 636 | 1542845 | 378 |
| 1080p_e2_s4_q28 | 1 | 4080 | 378 | 757 | 1543180 | 378 |
| 1080p_e2_s4_q38 | 0 | 4080 | 378 | 417 | 1542601 | 378 |
| 1080p_e2_s4_q38 | 1 | 4080 | 378 | 420 | 1542646 | 378 |
| 1080p_e2_s4_q51 | 0 | 4080 | 378 | 426 | 1542613 | 378 |
| 1080p_e2_s4_q51 | 1 | 4080 | 378 | 417 | 1542644 | 378 |
| qcif_noise_q18 | 0 | 99 | 432 | 499 | 43224 | 437 |
| qcif_noise_q51 | 0 | 99 | 378 | 378 | 37834 | 382 |

### 11.2 Verification results

* Unit benches (Verilator, each with its negative control): bitpack, c422, cavlc (37 912 checks), mbcavlc (1 921 checks, 120+ I_PCM
  macroblocks), xform (298 436 checks, including the decoded-tag outputs of `invq`), ipred (54 241 checks) all pass; the six
  `_neg` entries fail as required. Host driver test passes (QP clamp at 5, 12, 51 included).
* Decoder harness: all configurations print `TEST PASS: rtlnet_h264_top_<config>`: JM, OpenH264 and FFmpeg byte-identical to the
  rebuilt picture and PSNR at or above the floor of the (pattern, QP) pair. ffprobe and OpenH264 report 1280x720 and 1920x1080 for the
  large pictures. The negative control (`qcif_s1`, `qcif_e2_s4`, `qcif_photo_q28`, `qcif_edges_q18` with one corrupted stream byte)
  fails all three decoder comparisons. The global I_PCM mode (`-Pcm`, `qcif_s1`, `qcif_s3`, `qcif_e2_s4`) reproduces the source exactly.
* `scripts/rtlnet_regression.ps1 -Match h264`: 17 passed, 0 failed. Lint: 0 warnings.

### 11.3 PSNR and bits per picture

PSNR of the rebuilt picture (equal to what the three decoders output) against the 4:2:0 source. `inf` is an exact plane.
QP 0 checker and noise: checker 86 dB (the saturated macroblocks are I_PCM), noise lossless.

| Config | bits per picture | PSNR Y (dB) | Cb | Cr | all |
|---|---|---|---|---|---|
| qcif_s1 | 184056 | 33.70 | 33.79 | 33.88 | 33.75 |
| qcif_s3 | 4288 | 47.11 | 43.34 | 46.35 | 46.10 |
| qcif_bars | 2600 | 51.41 | 44.93 | 46.39 | 48.54 |
| qcif_2pic pic 0 | 6184 | 51.34 | 44.93 | 46.30 | 48.49 |
| qcif_2pic pic 1 | 4136 | 59.64 | 56.95 | 56.95 | 58.54 |
| qcif_zeros | 172984 | 35.45 | 35.03 | 34.94 | 35.29 |
| qcif_ring | 184256 | 33.70 | 33.81 | 33.85 | 33.74 |
| qcif_e2_s2 | 3560 | 48.01 | 44.20 | 47.18 | 46.97 |
| qcif_e2_s4 | 184448 | 33.70 | 33.80 | 33.85 | 33.74 |
| qcif_e2_2pic pic 0 | 4392 | 51.38 | 44.93 | 46.35 | 48.51 |
| qcif_e2_2pic pic 1 | 3992 | 59.64 | 56.95 | 56.95 | 58.54 |
| qcif_photo_q0 | 135608 | 66.53 | 66.33 | 64.94 | 66.19 |
| qcif_photo_q18 | 24616 | 44.47 | 50.41 | 50.50 | 45.72 |
| qcif_photo_q28 | 6616 | 40.37 | 45.34 | 46.46 | 41.55 |
| qcif_photo_q38 | 2560 | 36.15 | 41.56 | 42.90 | 37.40 |
| qcif_photo_q51 | 1440 | 30.42 | 38.95 | 41.79 | 31.96 |
| qcif_gradnoise_q0 | 246528 | 65.82 | 66.37 | 65.58 | 65.87 |
| qcif_gradnoise_q18 | 101024 | 43.45 | 43.49 | 43.62 | 43.49 |
| qcif_gradnoise_q28 | 28528 | 34.10 | 37.05 | 37.19 | 34.89 |
| qcif_gradnoise_q38 | 2064 | 30.79 | 36.04 | 35.17 | 31.88 |
| qcif_gradnoise_q51 | 1736 | 28.34 | 34.29 | 35.35 | 29.63 |
| qcif_zoneplate_q18 | 152744 | 43.72 | 51.88 | 52.72 | 45.19 |
| qcif_zoneplate_q28 | 97184 | 34.46 | 41.65 | 44.39 | 35.92 |
| qcif_zoneplate_q38 | 53432 | 25.64 | 38.09 | 38.48 | 27.28 |
| qcif_edges_q0 | 140080 | 78.95 | inf | inf | 80.71 |
| qcif_edges_q18 | 80120 | 49.41 | 55.36 | 53.27 | 50.50 |
| qcif_edges_q28 | 53360 | 39.85 | 44.38 | 46.46 | 41.03 |
| qcif_edges_q38 | 34440 | 30.32 | 38.70 | 37.99 | 31.75 |
| qcif_checker_q0 | 261128 | 84.39 | inf | inf | 86.15 |
| qcif_checker_q18 | 125328 | 51.80 | 51.10 | inf | 52.44 |
| qcif_checker_q28 | 77712 | 41.17 | 42.06 | 39.53 | 40.98 |
| qcif_checker_q38 | 54088 | 33.32 | 37.33 | 28.46 | 32.38 |
| qcif_noise_q0 | 305832 | inf | inf | inf | inf |
| qcif_noise_q38 | 114592 | 23.64 | 26.56 | 26.37 | 24.40 |
| qcif_gradient_q28 | 2848 | 49.24 | 45.32 | 47.83 | 48.07 |
| qcif_gradient_q51 | 1760 | 31.26 | 37.76 | 36.95 | 32.52 |
| qcif_bars_q18 | 3800 | 60.94 | 55.69 | 55.42 | 58.34 |
| qcif_bars_q51 | 1544 | 29.72 | 34.64 | 35.69 | 30.90 |
| qcif_zeros_q38 | 114616 | 26.04 | 27.12 | 26.85 | 26.33 |
| 720p_e1_s1_q18 | 406840 | 44.74 | 54.26 | 55.05 | 46.29 |
| 720p_e1_s1_q28 | 939696 | 33.98 | 37.10 | 37.11 | 34.80 |
| 720p_e1_s1_q38 | 513616 | 32.86 | 47.62 | 44.55 | 34.51 |
| 720p_e1_s1_q51 | 532752 | 15.16 | 40.42 | 40.48 | 16.92 |
| 720p_e1_s2_q18 | 30568 | inf | inf | inf | inf |
| 720p_e1_s2_q28 | 2573960 | 41.54 | 41.94 | 39.53 | 41.19 |
| 720p_e1_s2_q38 | 32792 | 41.56 | 44.53 | 49.82 | 42.66 |
| 720p_e1_s2_q51 | 116936 | 10.34 | 12.39 | 34.87 | 11.47 |
| 720p_e2_s2_q18 | 1267696 | 51.29 | inf | 72.39 | 53.04 |
| 720p_e2_s2_q28 | 3410960 | 34.68 | 48.12 | 48.62 | 36.35 |
| 720p_e2_s2_q38 | 30176 | 48.13 | 51.14 | 49.35 | 48.71 |
| 720p_e2_s2_q51 | 1059752 | 19.75 | 31.88 | 33.22 | 21.40 |
| 720p_e2_s4_q18 | 410752 | 44.74 | 54.28 | 55.09 | 46.29 |
| 720p_e2_s4_q28 | 940704 | 33.98 | 37.09 | 37.11 | 34.79 |
| 720p_e2_s4_q38 | 519352 | 32.84 | 47.62 | 46.35 | 34.52 |
| 720p_e2_s4_q51 | 538608 | 15.16 | 40.42 | 40.48 | 16.91 |
| 1080p_e1_s1_q18 | 66176 | inf | inf | inf | inf |
| 1080p_e1_s1_q28 | 5821824 | 41.66 | 41.87 | 39.53 | 41.25 |
| 1080p_e1_s1_q38 | 69488 | 42.27 | 44.63 | 51.80 | 43.34 |
| 1080p_e1_s1_q51 | 86376 | 29.40 | 35.41 | 35.29 | 30.64 |
| 1080p_e1_s2_q18 | 2188888 | 53.80 | inf | 63.67 | 55.45 |
| 1080p_e1_s2_q28 | 7732544 | 34.71 | 48.67 | 48.84 | 36.38 |
| 1080p_e1_s2_q38 | 66656 | 48.13 | 51.14 | 49.37 | 48.71 |
| 1080p_e1_s2_q51 | 2397704 | 19.80 | 31.84 | 33.22 | 21.44 |
| 1080p_e2_s2_q18 | 863472 | 44.77 | 55.98 | 57.37 | 46.39 |
| 1080p_e2_s2_q28 | 2164648 | 34.09 | 37.15 | 37.14 | 34.90 |
| 1080p_e2_s2_q38 | 827712 | 35.38 | 47.62 | 43.64 | 36.92 |
| 1080p_e2_s2_q51 | 1218504 | 15.16 | 41.03 | 40.52 | 16.91 |
| 1080p_e2_s4_q18 | 68792 | inf | inf | inf | inf |
| 1080p_e2_s4_q28 | 5796376 | 41.64 | 41.98 | 39.53 | 41.26 |
| 1080p_e2_s4_q38 | 70144 | 42.21 | 44.82 | 50.01 | 43.26 |
| 1080p_e2_s4_q51 | 86656 | 29.41 | 35.44 | 35.29 | 30.65 |
| qcif_noise_q18 | 293824 | 47.45 | 47.39 | 47.39 | 47.43 |
| qcif_noise_q51 | 39504 | 11.77 | 22.75 | 22.77 | 13.36 |

### 11.4 Mutations

13 mutations of the RTL, each caught and each file restored with an identical SHA-256: emulation prevention off (bitpack bench and I_PCM
zeros picture), chroma rounding floor (c422 bench and I_PCM picture), wrong `first_mb_in_slice`, ring-full guard removed, one wrong quant
multiplier (xform bench; invisible to a decoder), wrong coeff_token entry, plane prediction rounding, nC from the wrong neighbour (mbcavlc
bench and `qcif_gradnoise_q18`), DC prediction with a missing neighbour (ipred bench and `qcif_edges_q18`), I_PCM fallback never taken
(`qcif_checker_q0` fails its PSNR floor), saturated DC level flag removed (`qcif_checker_q0`, the root cause of section 3.3), I_PCM
macroblock counted as 0 coefficients for nC (mbcavlc bench), level pair merge limit exceeded (cavlc bench).

### 11.5 Out-of-context synthesis

`xc7a200tsbg484-1`, `enc_clk` 100 MHz, `h264_synth.tcl` (defaults, NUM_ENGINES 2): PASS, 0 critical warnings, post-synthesis WNS +0.344 ns
(estimated net delays, no placement; worst path `invq` decoded tag into the `ipred` plane multiplier).

| NUM_ENGINES | RAM_STYLE | LUT | of which LUTRAM | FF | RAMB36 | RAMB18 | DSP | WNS |
|---|---|---|---|---|---|---|---|---|
| 2 (default) | "block" | 38 815 | 264 | 25 173 | 18 | 2 | 74 | +0.344 ns |

The transform units are the bulk (about 6300 LUT and 28 DSP per engine for `fwdq`, `invq` and the DC units); sharing one dequantizer
multiplier array between the AC and DC paths is not done. Timing fixes found by the synthesis check: the size estimate is pipelined
(level costs registered, then summed), the second level pair merge decision is registered (a fourth level stage), and the `ipred` query
port selects registered decoded fields (`invq` outputs the decoded tag).

## 12. Open points

* The register-crossing constraints of `rtlnet_axil_cdc` (`scripts/rtlnet_constrain_cdc.tcl`) apply in the board build.
* The fallback estimate (section 3.3) is a fitted estimate, not a bound; it is calibrated on 176x144 synthetic content.
* LUT use of the transform units (38.8 k LUT for two engines) can be reduced by sharing the dequantizer multipliers.

## 13. Board integration (phase 2b-3, 11-09-2026)

`rtlnet_h264_top` is instance `u_h264` of the Nexys Video top (`NUM_ENGINES` 2, `ID_W` 2, `RAM_STYLE` "block", `AXIL_SYNC` 1). The CPU,
the DDR3 arbiter and its masters, the frame buffer, the video DMA and the bar generator, and both engines run on the one system clock `ui_clk`
(90.000 MHz, the MIG user clock). The engine masters connect to arbiter masters 2 and 3 with no clock crossing and no `rtlnet_axi_cdc`; the
register window is decoder slave 10 (0x44A0_8000) and runs without a crossing too (`rtlnet_axil_cdc` with `SYNC` 1, a pass-through; the
`AXIL_SYNC` parameter of the core passes it on). With `AXIL_SYNC` 0 (default) `s_axi_aclk` may be another clock and the core keeps its one
`rtlnet_axil_cdc`. Facts that integration added:

* **ID width.** `rtlnet_h264_wr_master` tells its ring, index and rebuilt-picture write responses apart by `bid[1:0]`, so `ID_W` is at least 2.
  The arbiter's slave-side ID is therefore 2 bits and its memory-side ID 4 bits (2 + `IDX_W` 2 for four masters); the MIG project's AXI ID width
  went from 2 to 4 bits (`rtlnet_ddr.md`).
* **Address width.** The engines drive 32-bit addresses; the board connects the low 29 bits to the 512 MiB arbiter. Every buffer lies below
  512 MiB (map in `rtlnet_nexys_video.md` 6.11).
* **Frame-buffer reader.** The frame-buffer reader port is not used. The firmware holds a slot for the whole picture through its own
  reader (`FW_TAKE`/`FW_RELEASE`), points `IN_BASE` at it and releases it at `STATUS.DONE`. One take covers both engines.
* **Budget at 90 MHz.** 735 clocks per macroblock per engine for 1080p30 against 378 to 484 measured in simulation (and 391 to 415 for I_PCM).
  Out-of-context synthesis at 11.111 ns (`h264_synth.tcl`, two engines): 39,489 LUT, 25,377 FF, 18 RAMB36 + 2 RAMB18, 74 DSP, post-synthesis
  WNS +1.455 ns, 0 critical warnings.
* **Timing fixes found in the board build** (first run at 100 MHz, before the single-clock decision). With the Phase 1 design around it, the encoder's
  decisions failed 100 MHz timing by up to 0.56 ns:
  * `rtlnet_h264_dcq_luma`: the Hadamard butterfly read its 16:1 operand multiplexers and formed the four-operand sums in one clock. The
    operands are now registered in the issue clock and the sums written back in the next, and a butterfly phase takes 5 clocks. The latency
    from `start` to `done` is 34 clocks (was 30); the bench checks 34.
  * `rtlnet_h264_ipred`: the serial first-best search took three chained 20-bit compares. Clock 1 registers the six pairwise `<=` results of
    the candidate totals, clock 2 picks the earliest legal minimum (the same result, ties to the earlier of DC, V, H, Plane). `dec_done` comes
    5 clocks after `dec_start` (was 4).
  The macroblock budget (section 11.1) grows by at most 5 clocks per macroblock; the picture-level counters are measured on the board (`show encoder`).

### 13.1 Synthesis and board measurements (11-10-2026)

Out-of-context synthesis of `rtlnet_h264_top` (2 engines) at 11.111 ns: WNS +1.455 ns, 39,489 LUT, 25,377 FF, 18 RAMB36 + 2 RAMB18, 74 DSP (`boards/nexys_video/build/phase2b3_h264_synth90.txt`). In the board build (one 90 MHz clock) the encoder region has +0.459 ns setup slack.

On the board (QP 28, color bars): 720p30 codes every picture at 859 to 880 clocks per macroblock per engine (fits its budget of 1,666) and streams without drops. 1080p30 needs at most 735 clocks per macroblock per engine; the board shows 928 to 929, so 25 % of the pictures are dropped. The busy-cycle counters show the rebuilt-picture write path (`rtlnet_h264_recon_wr`, 32 single-beat writes per macroblock) taking 3.4 to 3.6 million of the 3.8 million clocks of a picture; the simulation (fast memory model) measures about 373 per macroblock. Open.
