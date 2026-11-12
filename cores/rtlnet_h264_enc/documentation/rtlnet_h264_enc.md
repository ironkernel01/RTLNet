# rtlnet_h264_enc: H.264 encoder core, phases 2b-2 to 2c-2 (Intra16x16, I_PCM fallback, P pictures with integer-pel motion search)

Revision: 11-11-2026 (High profile seam, CABAC slice syntax, section 17; phase 2c-2: integer-pel motion search, section 16; phase 2c-1: P pictures without motion search, section 15; phase 2b-4: burst-only DDR3 access, section 14)

## 1. Purpose and scope

`cores/rtlnet_h264_enc` encodes one picture per start into an H.264 Constrained Baseline Annex B stream
(ITU-T Rec. H.264 (06/2026), profile_idc 66, constraint_set1_flag 1, CAVLC, deblocking off). Phase 2b-1 proved the pipeline
with I_PCM macroblocks; phase 2b-2 adds the lossy coder: Intra16x16 luma prediction (vertical, horizontal, DC, plane) and
chroma prediction by SAD, the 4x4 integer transform with the luma and chroma DC transforms, the quantizer, CAVLC residual
coding and the rebuild loop (dequantizer, inverse transform, prediction add), so the rebuilt picture equals what a decoder
shows. Every I slice macroblock is Intra16x16 unless it falls back to I_PCM (section 3.3). The read DMA with 4:2:2 to 4:2:0
conversion, the bit packer with emulation prevention, the NAL and slice syntax, the write DMA into a compressed ring, the
index ring and the rebuilt-picture write are unchanged from phase 2b-1. Phase 2c-1 adds P pictures (slice_type 5): every
macroblock is P_Skip, P_L0_16x16 at the motion vector (0,0) with its residual, Intra16x16 or I_PCM, predicted from the co-located
macroblock of the previous picture's rebuilt tiles; there is no motion search (section 15). Phase 2c-2 replaces the co-located reference by an integer-pel
motion search of the 16 x 16 partition (range +-16, section 16). A register bit selects the picture type.

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
    rtlnet_h264_rd_dma               16 row bursts per strip of RD_STRIP_MB macroblocks (8 beats at the default 4)
      rtlnet_h264_c422to420          YUYV 4:2:2 rows to 4:2:0 macroblock rows (row held per macroblock of the strip)
    rtlnet_ram_core                  strip buffer (2 halves of RD_STRIP_MB banks of 24 words of 16 bytes, 32-word pitch)
    rtlnet_h264_search               P pictures (2c-2): window loader, motion search, prediction generator, one macroblock ahead of stage A
      rtlnet_ram_core  x 2           search window (even and odd slots, 128 bit), WIN_KB each
      rtlnet_ram_core                source rows buffer of the search (8 words, distributed)
      rtlnet_h264_mvctx              the search's own vector context (approximate predictor and neighbour candidates), MV_LINE_KB
      rtlnet_h264_sad16              16 samples per clock sum of absolute differences
      rtlnet_h264_cinterp            chroma bilinear interpolation, clause 8.4.2.2.2
    rtlnet_ram_core                  prediction buffer (2 banks of 24 of 32 words of 16 bytes), REF_BUF_KB
    rtlnet_h264_mb_enc               stage A: mode decision, transform, quantizer, rebuild loop, I_PCM copy
      rtlnet_h264_ipred              Intra16x16 / chroma prediction candidates, SAD, mode decision, inter SAD
      rtlnet_h264_mvctx              P pictures: motion vector context (neighbours' vectors), mvp and the skip vector
        rtlnet_h264_mvpred           median predictor and P_Skip vector (clauses 8.4.1.3, 8.4.1.1), combinational
        rtlnet_ram_core              motion vector line RAM (one 32-bit word per macroblock column), MV_LINE_KB
      rtlnet_h264_fwdq               forward 4x4 transform and AC quantizer (4 lanes, 3 stages; inter modes: rounding 1/6, DC position)
      rtlnet_h264_dcq_luma           luma DC: 4x4 Hadamard, quantizer, inverse Hadamard and scaling
      rtlnet_h264_dcq_chroma  x 2    chroma DC (Cb, Cr): 2x2 transform, quantizer, inverse and scaling
      rtlnet_h264_invq               dequantizer and inverse 4x4 transform of the rebuild loop
      rtlnet_ram_core                line RAM: rebuilt bottom row of the macroblock row above
    rtlnet_ram_core  x 2             coefficient buffer copies (2 banks of 128 words of 48 bits): stage A read-back, stage B read
    rtlnet_ram_core                  rebuilt macroblock buffer (2 banks of 96 words of 4 samples)
    rtlnet_h264_mb_cavlc             stage B: macroblock layer syntax (I and P slices), skip run, nC, two block coders, I_PCM layer
      rtlnet_h264_cavlc_blk  x 2     CAVLC residual block coder (ping-pong), coeff_token / total_zeros / run_before tables
      rtlnet_ram_core                upper-neighbour total_coeff line RAM
      rtlnet_ram_core                tile staging buffer (32 x 128 bits)
    rtlnet_h264_recon_wr             rebuilt-picture tiles: one 16-beat luma burst and one 8-beat chroma burst per macroblock
    rtlnet_h264_bitpack              ue/se, fields, start codes, trailing bits, emulation prevention
    rtlnet_h264_ring_wr              byte gather, word FIFO (rtlnet_ram_core), bursts, index entries, pointers
    rtlnet_h264_wr_master            ring / index record / rebuilt tile burst requests onto AW, W, B
  rtlnet_h264_pkg                    shared constants
```

Files: `hdl/rtlnet_h264_top.sv` (top), `hdl/rtlnet_h264_enc_regs.sv`, `hdl/rtlnet_h264_engine.sv` (one engine), the
datapath modules above (phase 2c-1 adds `rtlnet_h264_mvctx.sv` and `rtlnet_h264_mvpred.sv`; phase 2c-2 adds `rtlnet_h264_search.sv`, `rtlnet_h264_sad16.sv`
and `rtlnet_h264_cinterp.sv` and removes `rtlnet_h264_ref_dma.sv`),
`hdl/rtlnet_h264_enc.f` (compile order), `driver/rtlnet_h264_enc.{h,c}`, `testbench/`.
`rtlnet_h264_mb_pcm` of phase 2b-1 is gone: the I_PCM macroblock layer is written by stage B like any other.

### 3.1 Macroblock pipeline

The fetch sequencer fills the two halves of the strip buffer through the read DMA, one strip of up to `RD_STRIP_MB`
macroblocks (one macroblock row, left to right) per start. Stage A codes one macroblock from its bank of the current strip half into a
coefficient bank and a rebuilt bank; the strip half is released when A is done with its last macroblock (the last macroblock of the
strip: `a_x mod RD_STRIP_MB = RD_STRIP_MB - 1` or the last of the row). Stage B turns the coefficient bank of the
previous macroblock into packer commands meanwhile, and the rebuilt-picture writer drains the rebuilt bank. A starts the next
macroblock when its strip half is full and a coefficient and a rebuilt bank are free, so the throughput is the larger of the
two stages. A cannot run further ahead: the neighbours of the next macroblock (left column, bottom row of the row above)
come from its own rebuild.

Stage A phases (`rtlnet_h264_mb_enc`):

| Phase | Clocks | Work |
|---|---|---|
| TOP, PREP | about 20 | neighbours from the line RAM and registers into `ipred`; plane parameters and DC values |
| SAD | 96 + 10 | 96 row segments (16 luma blocks, 4 Cb, 4 Cr blocks, 4 rows each) accumulate the SAD of every legal mode (and, in P pictures, of the reference macroblock); the mode decision |
| PASS1 | 96 + about 20 | source minus prediction, forward transform, AC quantizer, levels into the coefficient RAM; the 24 DC coefficients into the DC units |
| MD1, MD2 | 3 | P pictures only: inter against intra cost (section 15.2) |
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
| RD_STRIP_MB | 4 | macroblocks per input-read burst strip, 2, 4 or 8: row bursts of 2 x RD_STRIP_MB beats (8 beats = 128 bytes at 4) |
| REF_BUF_KB | 1 | prediction buffer per engine, KiB (two banks of 32 words of 16 bytes, 24 used per bank; at least 1; written by the search since 2c-2) |
| MV_LINE_KB | 1 | motion vector line RAM per engine and per user (stage A's context and the search's), KiB (one 32-bit word per macroblock column and one more; at least MAX_MB_W + 1 words) |
| WIN_KB | 4 | each of the two search window RAMs per engine, KiB (144 words of 16 bytes are used; at least 4) |
| SR | 16 | motion search range, whole samples, 0 to 16 (0: only the vector (0,0), the 2c-1 behaviour) |
| MB_BUF_KB | 4 | strip buffer, KiB (two halves of RD_STRIP_MB banks of 32 words of 16 bytes = 2 x RD_STRIP_MB x 512 B; at least RD_STRIP_MB) |
| REC_BUF_KB | 1 | rebuilt macroblock buffer, KiB (two banks of 96 words of 4 samples) |
| COEF_BUF_KB | 1 | coefficient buffer per copy, KiB (two banks of 128 words of 48 bits) |
| LINE_KB | 4 | line RAM of stage A, KiB (two 16-byte words per macroblock column) |
| FIFO_KB | 1 | ring word FIFO per engine, KiB (64 words of 16 bytes plus strobes) |
| RAM_STYLE | "block" | `rtlnet_ram_core` style, "block" or "distributed" |
| HIGH_PROFILE | 0 | 1 instances the High profile extension `rtlnet_h264_hp` (a netlist delivered separately) in every engine; 0 builds the Constrained Baseline encoder (section 17) |

All memories are instances of `rtlnet_ram_core`. Frame size, band split, slice count and QP come from registers, not
parameters, so one build codes both video modes.

## 5. Ports of `rtlnet_h264_top`

| Group | Ports |
|---|---|
| Clocks and resets | `enc_clk`, `enc_resetn` (synchronous, active low); `s_axi_aclk`, `s_axi_aresetn` |
| AXI4-Lite slave, `s_axi_aclk` | `s_axi_aw*`, `w*`, `b*`, `ar*`, `r*`, 12-bit address (4 KiB window), 32-bit data |
| AXI4 masters, `enc_clk` | `m_axi_aw*`, `w*`, `b*`, `ar*`, `r*` as packed vectors, engine e at `[e*W +: W]`, arbiter style; 128-bit data, ADDR_W 32, ID_W 4 |
| Interrupt | `irq`, level on `enc_clk`: `CTRL.IRQ_EN` and an enabled `IRQ_STATUS` bit (picture done, error, ring stall, profile change, license lost, picture start; section 18) |

In P pictures the AR channel also carries the search window reads (AXI ID 1; the input strips use ID 0): per macroblock one column of reference tiles,
a 16-beat luma tile burst and an 8-beat chroma tile burst for each of the rows r - 1, r, r + 1 that exist, from addresses that are multiples of 256 and 128 (section 16.2). Every burst is INCR, size 16 bytes (full width), at most 16 beats, and never crosses 4 KiB (`rtlnet_axi_arbiter` rejects
anything else from a non-narrow master). The core issues bursts only (section 14): read bursts are `2 x RD_STRIP_MB` beats (8 at the default;
fewer, but at least 2, for the last strip of a macroblock row whose width is not a multiple of `RD_STRIP_MB`) from an address that is a
multiple of `32 x RD_STRIP_MB`; the rebuilt picture is written as a 16-beat luma tile burst and an 8-beat chroma tile burst per macroblock; an
index record is one 8-beat burst; ring bursts are 16 beats and end earlier only at 4 KiB, at the ring end and at the end of a slice NAL
unit (the one place a short burst, down to a single beat, remains: the last burst of a slice, the ring end remainder and the 4 KiB
remainder). Simulation assertions in `rtlnet_h264_wr_master` and `rtlnet_h264_engine` check the burst rules, the bench monitor
`tb_h264_burst_mon` checks the shapes and prints the histogram per master (section 14), and the bench places the real
`rtlnet_axi_arbiter` between the engines and the memory model.

## 6. Register map (offsets in the 4 KiB window)

| Offset | Name | Access | Meaning |
|---|---|---|---|
| 0x000 | ID | RO | "H264" = 0x48323634 |
| 0x004 | VERSION | RO | 0x11122C03 (11-12-2026: the interrupt registers; 0x11102C02 (11-10-2026, phase 2c-2: motion search, no register change; 0x11102C01 was phase 2c-1: P pictures; 0x11102026 the tiled rebuilt picture with 128-byte index records, all of them without the interrupt registers) |
| 0x008 | CAPS | RO | [7:0] MAX_MB_W, [15:8] MAX_MB_H, [19:16] NUM_ENGINES, [20] HP_SEAM (HIGH_PROFILE build), [21] IRQ (the interrupt registers exist), [31:24] mask of the implemented interrupt sources |
| 0x00C | CTRL | RW | bit 0 START (self-clearing), bit 1 RING_RESET (self-clearing), bit 8 IRQ_EN (the global interrupt enable, reset 0) |
| 0x010 | STATUS | RW | bit 0 BUSY, bit 1 DONE (W1C), bit 2 ERR (W1C), bit 3 RING_STALL (live, any engine) |
| 0x014 | ERR_CODE | RO | first error since the last ERR clear: 1 config, 2 AXI response, 3 read pointer, 4 start while busy |
| 0x0C0 | HP_CTRL | RW | HIGH_PROFILE builds, else 0: bit 0 hp_enable (a write of 1 is ignored while hp_caps is 0; accepted when the module offers a tool), bit 1 hp_t8_enable (the 8x8 transform of inter macroblocks; a write of 1 is ignored while hp_caps bit 1 is 0), bit 2 hp_t8_auto (with bit 1: the module chooses the 4x4 or the 8x8 transform per macroblock, 17.7; a write of 1 is ignored without bit 1 or while hp_caps bit 2 is 0) |
| 0x0C4 | HP_STATUS | RW | HIGH_PROFILE builds, else 0: [0] module present, [1] licensed, [2] active, [3] enable, [4] PROFILE_CHG (sticky, W1C), [5] 8x8 transform enable, [6] adaptive choice (hp_t8_auto), [11:8] hp_caps (bit 0 CABAC, bit 1 8x8 transform, bit 2 adaptive choice), [31:16] license seconds left (0xFFFF unlimited) |
| 0x0C8 | HP_T8_COUNT | RO | HIGH_PROFILE builds, else 0: [15:0] macroblocks of the last picture coded with the 8x8 transform, [31:16] with the 4x4 transform (inter macroblocks with a coded luma block, the engines added) |
| 0x0D0 | IRQ_STATUS | RW | sticky interrupt event bits, write 1 to clear (section 18) |
| 0x0D4 | IRQ_ENABLE | RW | one enable bit per interrupt source, reset 0 |
| 0x0D8 | IRQ_FORCE | WO | a written 1 sets the status bit (self-test) |
| 0x020 | MB_W | RW | picture width in macroblocks |
| 0x024 | MB_H | RW | picture height in macroblocks |
| 0x028 | SLICES | RW | slices per picture, a multiple of NUM_ENGINES |
| 0x02C | QP | RW | slice QP 0..51; `slice_qp_delta = QP - 26` (reset 26). The driver writes at least `RTLNET_H264_QP_MIN_REALTIME` (12) |
| 0x030 | FRAME_NUM | RW | frame_num written in `log2_max_frame_num` bits |
| 0x034 | IDR_PIC_ID | RW | idr_pic_id of an IDR picture |
| 0x038 | PIC_CFG | RW | [0] IDR picture (reset 1), [1] P picture (reset 0; never with [0]: START is rejected with ERR_CODE 1), [12:8] log2_max_frame_num (reset 4, range 4..16) |
| 0x03C | MB_MODE | RW | [0] 1 = every macroblock is I_PCM (debug, exact rebuilt picture), 0 = Intra16x16 with the per-macroblock I_PCM fallback (reset 0) |
| 0x040 | IN_BASE | RW | input frame base, multiple of 32 x RD_STRIP_MB (128) |
| 0x044 | IN_STRIDE | RW | input line stride in bytes, multiple of 128, at least MB_W x 32 |
| 0x048 | RY_BASE | RW | rebuilt picture luma tile base, multiple of 256 (256 bytes per macroblock) |
| 0x04C | reserved | RO | reads 0, writes ignored (was RY_STRIDE) |
| 0x050 | RU_BASE | RW | rebuilt picture chroma tile base (Cb then Cr), multiple of 128 (128 bytes per macroblock) |
| 0x054 | REF_Y_BASE | RW | reference picture luma tile base (P pictures; the previous picture's rebuilt tiles), multiple of 256 (was reserved, RV_BASE) |
| 0x058 | REF_U_BASE | RW | reference picture chroma tile base (P pictures), multiple of 128 (was reserved, RC_STRIDE) |
| 0x060 | RING_BASE | RW | compressed ring base, multiple of 16 (all engines) |
| 0x064 | RING_SIZE | RW | compressed ring size in bytes, multiple of 16 x NUM_ENGINES, each share at least 1024 |
| 0x068 | RING_WPTR | RO | byte offset after the last burst whose write response arrived |
| 0x06C | RING_RPTR | RW | byte offset firmware consumed up to |
| 0x070 | RING_FILL | RO | bytes written and not consumed |
| 0x078 | IDX_BASE | RW | index ring base, multiple of 128 |
| 0x07C | IDX_ENTRIES | RW | index ring records of 128 bytes (all engines), at least NUM_ENGINES |
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
`IDX_BASE + 128 x e x IDX_ENTRIES / NUM_ENGINES`.

P pictures (phase 2c-1): PIC_CFG[1] = 1 codes the picture as P slices against the picture whose rebuilt tiles are at REF_Y_BASE and
REF_U_BASE (written by the previous picture to its RY_BASE and RU_BASE; the two buffers alternate, section 15.3); PIC_CFG[0] must be 0,
FRAME_NUM follows clause 7.4.3 (previous reference picture's frame_num plus one, modulo 2^log2_max_frame_num) and IDR_PIC_ID is not
used. The reference bases are read only in P pictures and must be tile aligned then.

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

**Strip buffer** (two halves of `RD_STRIP_MB` banks, bank pitch 32 words of 16 bytes): in a bank words 0..15 the luma rows (pixel i in
byte i); words 16..23 chroma rows, Cb(0..7) in bytes 0..7 and Cr(0..7) in bytes 8..15. Macroblock `x` of strip half `h` is bank
`h x RD_STRIP_MB + (x mod RD_STRIP_MB)`. The read DMA fetches a strip as 16 row bursts: burst `r` is pixel row `r` of the
strip's macroblocks, two 16-byte beats (one 32-byte pixel row) per macroblock.

**Rebuilt macroblock buffer** (32-bit words of 4 samples, per bank of 128): luma word `4 y + bx`, Cb word `64 + 2 y + bx`, Cr word
`80 + 2 y + bx`.

**Coefficient buffer** (48-bit words, 4 signed 12-bit levels each, per bank of 128 words): words 0..3 luma DC level matrix
rows; word `4 + 4 tag + row` for the 24 blocks (tag = `4 by + bx` luma, `16 + 2 by + bx` Cb, `20 + 2 by + bx` Cr), the
coefficient row `row` of the block in raster order (position (0,0) of AC blocks holds 0); word 100 Cb DC, word 101 Cr DC. For an
I_PCM macroblock words 0..95 hold the sample words (low 32 bits, first sample in the top byte) in stream order.

**Rebuilt picture**, macroblock-tiled (8-bit samples): macroblock `m` (raster index in the picture, `m = row x MB_W + x`) owns a luma tile of
256 bytes at `RY_BASE + 256 m` (16 rows of 16 samples, row 0 first: 16 beats of 128 bits) and a chroma tile of 128 bytes at
`RU_BASE + 128 m` (the Cb 8 x 8 block row by row, then the Cr 8 x 8 block: 8 beats, beat k of the Cb half holds Cb rows 2k and 2k + 1,
beat 4 + k the Cr rows 2k and 2k + 1). Both tile sizes are powers of two and the bases are multiples of the tile size, so a tile burst never
crosses 4 KiB. The picture needs `MB_W x MB_H x 384` bytes (3,133,440 bytes at 1080p: 2,088,960 luma and 1,044,480 chroma). The rebuilt
picture is the decoder's output for the stream (what JM, OpenH264 and FFmpeg decode, byte for byte), in tile order; the bench de-tiles it
for the comparison. Only this encoder reads it (the motion-search phase will read the tiles); the rebuilt macroblock RAM holds the 96 words of
a macroblock in exactly this order, so the writer streams it without reordering.

**Compressed ring**: byte stream of NAL units in order, wrapping at the end of the engine's share. Bytes are written as full
or partial 16-byte words (byte strobes), so the stream is contiguous. The writer stalls, and never overwrites unread
bytes, when the ring holds fewer than 4 bytes of free space (fill at most `size - 3`); firmware advances the read
pointer in steps below the ring size. A read pointer at or beyond the ring size, or a step beyond the data written, is
ignored and sets ERR code 3.

**Index entry**, four little-endian 32-bit words at the start of a 128-byte record (`IDX_BASE`-share `+ 128 x index`; bytes 16..127 of the
record are reserved and written as zero, so an index write is one 8-beat burst):

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
  `slice_type` ue(v) = 7 (I picture) or 5 (P picture, phase 2c-1; all slices of the picture have the type), `pic_parameter_set_id` ue(v) = 0,
  `frame_num` u(log2_max_frame_num), `idr_pic_id` ue(v) (IDR only), no POC fields (`pic_order_cnt_type` 2), for a P slice
  `num_ref_idx_active_override_flag` 0 (the PPS default is one reference) and `ref_pic_list_modification_flag_l0` 0,
  `dec_ref_pic_marking` (IDR: `no_output_of_prior_pics_flag` 0 and `long_term_reference_flag` 0; non-IDR: `adaptive_ref_pic_marking_mode_flag` 0:
  the sliding window with `max_num_ref_frames` 1), `slice_qp_delta` se(v) = QP - 26, `disable_deblocking_filter_idc` ue(v) = 1. The P slice
  header therefore has three zero bits after `frame_num`.
* Macroblock layer (clause 7.3.5), Intra16x16 macroblock: `mb_type` ue(v) = 1 + prediction mode + 4 x cbp_chroma + 12 x (cbp_luma
  != 0) (Table 7-11), `intra_chroma_pred_mode` ue(v), `mb_qp_delta` se(v) = 0, `Intra16x16DCLevel` (always, nC of luma block 0),
  the 16 `Intra16x16ACLevel` blocks when the luma cbp is 15 (zigzag positions 1..15, luma4x4BlkIdx order), the two
  `ChromaDCLevel` blocks (nC = -1) when cbp_chroma is not 0, the eight `ChromaACLevel` blocks when cbp_chroma is 2. Every block is
  `residual_block_cavlc` (clause 9.2): `coeff_token` (Tables 9-5 with the nC class of clause 9.2.1), the trailing-one signs,
  the level codes (`level_prefix` and `level_suffix`, suffixLength adaptation, escape at prefix 15), `total_zeros` (Tables
  9-7 to 9-9), `run_before` (Table 9-10). Slice QP only: `mb_qp_delta` is 0.
* P slices (phase 2c-1, clauses 7.3.4 and 7.3.5): before every macroblock that is not skipped, `mb_skip_run` ue(v) (the skipped macroblocks since the
  last coded one of the slice, 0 when none); at the end of the slice, `mb_skip_run` when the last macroblocks are skipped (not written for 0). The
  run restarts at every slice. A skipped macroblock (P_Skip) writes nothing. `P_L0_16x16`: `mb_type` ue(v) = 0, no `ref_idx_l0` (one active
  reference), `mvd_l0` x and y se(v) (the motion vector minus its prediction, clause 8.4.1.3; both are 0 in phase 2c-1), `coded_block_pattern` me(v)
  (Table 9-4 inter column: luma 8x8 mask in bits 3..0, `cbp_chroma` in bits 5..4), then only when the pattern is not 0 `mb_qp_delta` se(v) = 0
  and the residual: the luma 4x4 blocks of the coded 8x8 groups as `LumaLevel4x4` (16 coefficients, zigzag positions 0..15, `luma4x4BlkIdx` order;
  there is no luma DC block), then the chroma DC and AC blocks as for intra. Intra macroblocks in a P slice use the I `mb_type` plus 5 (Intra16x16
  `5 + 1 + mode + 4 x cbp_chroma + 12 x (cbp_luma != 0)`, I_PCM 30); the PPS has `constrained_intra_pred_flag` 0, so an intra macroblock predicts
  from inter neighbours. nC (clause 9.2.1): a P_Skip or P_L0_16x16 neighbour is available inside the slice with its `TotalCoeff` (skip: 0; blocks of
  an uncoded 8x8 group: 0).
* Macroblock layer of a fallback macroblock: `mb_type` ue(v) = 25 (I_PCM; 30 in a P slice), `pcm_alignment_zero_bit`s to the byte boundary, 256
  luma samples, 64 Cb samples, 64 Cr samples, 8 bits each, raster order. A PCM sample value of 0 is allowed: clause 7.4.5 states
  `pcm_sample_luma` and `pcm_sample_chroma` as sample values without a restriction in this edition, and emulation prevention
  protects any zero run.
* Slice end: `rbsp_slice_trailing_bits` (clause 7.3.2.8): one stop bit and zeros to alignment.
* A second IDR picture uses `frame_num` 0 (clause 7.4.3) and a new `idr_pic_id`, as the 2-picture runs do.
* SPS and PPS are written by firmware: `rtlnet_h264_enc_write_sps_pps()`. SPS: profile_idc 66, constraint_set1_flag 1,
  level_idc from the frame size and rate (Table A-1: 31 for 720p30, 40 for 1080p30), `pic_order_cnt_type` 2,
  `max_num_ref_frames` 1, `frame_mbs_only_flag` 1, frame cropping 1088 to 1080 (`frame_crop_bottom_offset` 4). PPS: CAVLC
  (`entropy_coding_mode_flag` 0), `deblocking_filter_control_present_flag` 1, `pic_init_qp` 26 (`pic_init_qp_minus26` 0).

Quantization: forward AC `level = (|W| x MF + f) >> qbits`, `qbits = 15 + QP/6`, `f = 2^qbits / 3` (intra; `2^qbits / 6` for inter macroblocks), luma DC on the
Hadamard of the 16 block DCs with `qbits + 1` and `2 f`, chroma DC on the 2x2 transform of the four DCs with QPc = table of
clause 8.5.8 for `chroma_qp_index_offset` 0 (the chroma DC of an inter macroblock uses `2f` with the inter `f`); dequantization and the inverse transforms are the clause 8.5 integer arithmetic.

## 9. Driver

`driver/rtlnet_h264_enc.{h,c}` (C, `rtlnet_mmio.h` for register access): `probe`, `get_mode` / `set_mode` (0 = 720p30,
default; 1 = 1080p30: writes MB_W, MB_H, fills the SPS parameters), `band_rows` (the ceil split), `configure`, `ring_reset`,
`start_picture`, `wait_done`, `status`, `clear_status`, `set_read_pointers`, `index_wptr`, `decode_index_entry`,
`read_stats` and `write_sps_pps`. Phase 2c-1 adds `start_picture_ex` (picture type IDR or P), `next_frame_num`, `set_reference` and the two-buffer helper
`buffers_init`, `buffers_begin` and `buffers_end` (section 15.3); `start_picture` is unchanged and starts an I picture. `configure` writes `max(cfg->qp, RTLNET_H264_QP_MIN_REALTIME)` into the QP register
(`RTLNET_H264_QP_MIN_REALTIME` = 12, section 3.3); `cfg->mb_pcm` writes MB_MODE. The host test
`testbench/test_rtlnet_h264_enc_driver.c` checks the register writes against a register model (including the QP clamp at 5, 12
and 51) and checks the SPS and PPS bytes with an independent bit reader (fields, emulation prevention, level, cropping,
rejections), including the 720p30 and 1080p30 modes and the bands (23/22 and 34/34).

Since 11-12-2026 the driver folder also holds the control layer `rtlnet_h264_enc_ctl.{h,c}` (the code firmware calls: session, notification mode, picture start and
turnaround, High profile controls, console view; section 18.4) and the H.264 rate controller `rtlnet_ratectl.{h,c}` (`rtlnet_ratectl.md`), with their host tests
`testbench/test_rtlnet_h264_enc_ctl.c` and `testbench/test_rtlnet_ratectl.c`. Firmware outside the driver folder includes no register definition and makes no register access to this core.

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
  (forward and inverse transform, quantizers and the DC units, with the inter modes of phase 2c-1) and `tb_rtlnet_h264_ipred` (prediction
  candidates, SAD and mode decision, inter SAD), `tb_rtlnet_h264_mbcavlc` also checks the P slice syntax of phase 2c-1 (section 15.5) and
  `tb_rtlnet_h264_mvpred` (phase 2c-1) the motion vector predictor and its context.
* Encoder bench `tb_rtlnet_h264_top`: loads the input image of each picture (`+INPFX`, `+GOP`: a string of I and P letters; two rebuilt buffers) into a memory model (`tb_h264_axi_mem`, behind the real
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
* `testbench/h264_mutation.ps1`: 19 mutations (13 of phase 2b-2, 6 of the P path), each restored byte for byte (SHA-256 checked) (section 11.4, 15.5).
* `testbench/h264_harness_par.ps1` runs the harness configurations in parallel (one process each); the P-picture configurations `p_*` of phase 2c-1
  (GOPs of generated sequences, section 15.5) run only when named with `-Config`.
* Phase 2c-2: `tb_rtlnet_h264_search` (search stage against a software model), `tb_rtlnet_h264_cinterp` (chroma interpolation, all 64 fractions) and
  `tb_rtlnet_h264_sad16` (SAD unit), the harness configurations `m_*` and the bits ratio check (section 16.8).
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

Phase 2c-1 adds six mutations of the P path (section 15.5).

### 11.5 Out-of-context synthesis

`xc7a200tsbg484-1`, `enc_clk` 100 MHz, `h264_synth.tcl` (defaults, NUM_ENGINES 2): PASS, 0 critical warnings, post-synthesis WNS +0.344 ns
(estimated net delays, no placement; worst path `invq` decoded tag into the `ipred` plane multiplier).

| NUM_ENGINES | RAM_STYLE | LUT | of which LUTRAM | FF | RAMB36 | RAMB18 | DSP | WNS |
|---|---|---|---|---|---|---|---|---|
| 2 (default) | "block" | 38 815 | 264 | 25 173 | 18 | 2 | 74 | +0.344 ns |

The transform units are the bulk (about 6300 LUT and 28 DSP per engine for `fwdq`, `invq` and the DC units; stage 3c, 11-12-2026: new figures of the pipelined engine in 17.8); sharing one dequantizer
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

On the board (QP 28, color bars): 720p30 codes every picture at 859 to 880 clocks per macroblock per engine (fits its budget of 1,666) and streams without drops. 1080p30 needs at most 735 clocks per macroblock per engine; the board shows 928 to 929, so 25 % of the pictures are dropped. The busy-cycle counters show the rebuilt-picture write path (`rtlnet_h264_recon_wr`, 32 single-beat writes per macroblock) taking 3.4 to 3.6 million of the 3.8 million clocks of a picture; the simulation (fast memory model) measures about 373 per macroblock. Resolved in phase 2b-4 (section 14).

## 14. Burst-only DDR3 access (phase 2b-4, 11-10-2026)

Rule (11-10-2026): every DDR3 access is a burst. No RTLNet master issues an `AWLEN` or `ARLEN` 0 transaction in streaming, bursts are at
least 8 beats of 128 bits (128 bytes) where the data allows, never cross 4 KiB, and only true tails (ring end, 4 KiB end, end of a slice or frame)
are shorter. Cause: with 32 single-beat writes per macroblock the encoder measured 928 clocks per macroblock on the board at 1080p30 (budget
735, 25 % of the pictures dropped) against 373 in simulation.

### 14.1 Burst shapes per master

| Master | Before | After |
|---|---|---|
| Encoder input read (AR) | 16 bursts of 2 beats per macroblock (one pixel row of 32 bytes) | 16 row bursts per strip of `RD_STRIP_MB` macroblocks: 8 beats (128 bytes) at the default 4; the last strip of a row with a width that is not a multiple of 4 has `2 x n` beats (2, 4 or 6), never 1 |
| Rebuilt picture (AW) | 32 single-beat writes per macroblock (16 luma rows, 8 + 8 chroma rows with 8-byte strobes) | 1 burst of 16 beats (luma tile, 256 B) and 1 burst of 8 beats (chroma tile, 128 B) per macroblock |
| Reference read (AR, ID 1; P pictures, phase 2c-1) | not present | 1 burst of 16 beats (luma tile, 256 B) and 1 burst of 8 beats (chroma tile, 128 B) per macroblock, from tile-aligned addresses; the strip DMA and this DMA never overlap |
| Index record (AW) | 1 beat of 16 bytes | 1 burst of 8 beats (128-byte record) |
| Compressed ring (AW) | up to 16 beats; every NAL unit end closed a burst (the 6-byte access unit delimiter was a 1-beat burst) | up to 16 beats; only a slice NAL unit end, the ring end and 4 KiB close a burst early (the delimiter joins the burst of the slice that follows); the last burst of a slice can still be short, down to 1 beat |
| Video write DMA (`rtlnet_vdma_s2mm`) | 16-beat bursts | unchanged: line starts are 256-byte aligned at both strides (2560 and 3840 bytes), so every burst is 16 beats, 720p30 and 1080p30 |
| CPU caches (arbiter master 0) | write-through: every store one narrow 32-bit beat; line fill one 128-bit beat (4 x 32-bit packed by the SmartConnect) | see `microblaze/documentation/rtlnet_cpu_microblaze.md` section 11: write-back, 64-byte lines; stores leave as 4-beat bursts (measured), reads still reach the memory controller as single beats (open) |

Other DDR3 masters: none. The AXI DMA of the CPU network path uses the AXI BRAM, the frame-buffer reader port is unused, `rtlnet_csi2_rx`
and `rtlnet_framebuf` have no memory port.

### 14.2 Design

* `rtlnet_h264_recon_wr` reads the 96 words of the rebuilt macroblock RAM in order, builds 24 beats in a 32 x 128-bit staging RAM
  (`rtlnet_ram_core`, `RAM_STYLE`) and streams the luma tile (16 beats) and the chroma tile (8 beats) as two bursts at one beat per clock.
  `rtlnet_h264_wr_master` takes a descriptor (`rc_valid`, `rc_addr`, `rc_len`, `rc_pop`) and pulls the beats (`rc_w_valid`, `rc_w_data`,
  `rc_w_pop`), as the ring does. Outstanding writes are counted per burst. The engine advances its tile pointers by 256 and 128 bytes per
  macroblock.
* `rtlnet_h264_rd_dma` fetches a strip of `RD_STRIP_MB` macroblocks with 16 row bursts and writes each macroblock's 24 words into its bank of
  the strip buffer (two halves of `RD_STRIP_MB` banks, `MB_BUF_KB` 4, one `rtlnet_ram_core`); `rtlnet_h264_c422to420` holds the even-row chroma
  per macroblock (`NMB` entries), so rows of the strip's macroblocks interleave. Stage A reads its bank as before; a half is released after the
  last macroblock of the strip. Macroblock order is raster order per band, unchanged. `IN_BASE` and `IN_STRIDE` must be multiples of
  `32 x RD_STRIP_MB` (128) so that no strip burst crosses 4 KiB (the driver and the core's `cfg_ok` check it).
* The index record is 128 bytes (8 beats, entry in the first 16 bytes, the rest zero). Chosen over coalescing records because entries are
  produced a few per picture and must be visible at once; a 128-byte record satisfies the 8-beat rule with one counter in the write master.
* Registers: `RY_BASE` is the luma tile base, `RU_BASE` the chroma tile base; 0x04C, 0x054, 0x058 are reserved (read 0). `VERSION` 0x11102026.

### 14.3 Verification and results

* Bench monitor `tb_h264_burst_mon` on every engine port: fails the bench on a 1-beat AR, a 1-beat index or rebuilt AW, an index record that is not 8
  beats, a tile burst that is not 16 or 8 beats, an AR with an odd beat count, and prints the histogram per master. Negative control:
  `h264_harness.ps1 -InjectBurst` shows the monitor one single-beat rebuilt AW; the bench must fail (`h264_harness_burstneg`: PASS).
* Histogram (1080p, 2 engines, QP 28, memory model of `rtlnet_ddr_sim`: 20 clocks read latency, no gaps), per engine:
  AR 16,320 bursts of 8 beats; ring AW 529 bursts, 528 of 16 beats and one tail (14 beats on engine 0, 2 on engine 1); index AW 2 of 8 beats; rebuilt AW
  8,160 bursts, 4,080 of 8 and 4,080 of 16 beats. No 1-beat transaction. QCIF (11 macroblocks wide): AR 288 of 8 and 144 of 6 beats.
* Clocks per macroblock (`PIC_CYC / MB_COUNT`), 1080p, both engines sharing the port, memory model latency 20 and gap 0 or 20 %: 379 (limit 735);
  one engine 379. Before: 373 in the same model but 928 on the board.
* All decoder-checked configurations decode byte-identical in JM, OpenH264 and FFmpeg against the de-tiled rebuilt picture with the PSNR floors
  met: see `.sim/logs/p2b4_*.log` (every configuration run before this document was closed passed; `strip_w13_s1`, `strip_w5_e2_s2` and `strip_w18_s3`
  have widths of 13, 5 and 18 macroblocks).
* Out-of-context synthesis of `rtlnet_h264_top` (2 engines, 11.111 ns): WNS +1.455 ns, 38,995 LUT (was 39,489), 25,759 FF (was 25,377), 22 RAMB36 + 2 RAMB18
  (was 18 + 2), 74 DSP, 0 critical warnings (`.sim/synth/h264_top_2b4.log`). The four added RAMB36 are the two tile staging RAMs.
* Board (11-10-2026, section 14.4 of this document and `rtlnet_nexys_video.md` 6.12): `show encoder` at 1080p30 reports 435 clocks per macroblock per engine
  (was 928), 720p30 423 to 425 (was 859 to 880).

### 14.4 Board results

`stream_test` at QP 28, 60 s per mode: 720p30 PASS (1805 pictures, 0 dropped, 0 continuity errors, 0 PTS gaps, PSNR minimum 51.14 dB, 1037 kb/s, TS-mux load 3.3 %,
423 and 425 clocks per macroblock); 1080p30 PASS (1802 pictures, 0 dropped, 0 continuity errors, 0 PTS gaps, PSNR minimum 51.09 dB, 2210 kb/s, TS-mux load 7.0 %,
435 clocks per macroblock on both engines, last interval 379, busy cycles read 455 k, coder 1,550 k, write 699 k of 1,778 k per picture). The write path that was 3.4 million
clocks per picture is 0.7 million. `show ddr`: errors 0 on all masters.

## 15. P pictures, phase 2c-1 (11-10-2026)

Phase 2c adds P pictures in two stages. Stage 2c-1 (this section) codes P slices in which every inter macroblock uses the motion vector (0,0)
and nothing is searched; stage 2c-2 adds the sliding search window, integer-pel search, motion vector differences, chroma eighth-sample
interpolation and the picture-edge rule. The syntax writer, the motion vector context and the residual path are general: stage 2c-2 replaces the
reference fetch and drives a search result (vector and cost) into the mode decision (section 15.4).

### 15.1 Design

* **Picture type.** `PIC_CFG[1]` selects a P picture: `slice_type` 5, `nal_unit_type` 1, `nal_ref_idc` 3 (section 8). A P picture is never an IDR
  picture: START with `PIC_CFG[1:0]` = 3 is rejected (`ERR_CODE` 1). The slice header carries `num_ref_idx_active_override_flag` 0,
  `ref_pic_list_modification_flag_l0` 0 and `adaptive_ref_pic_marking_mode_flag` 0. With `max_num_ref_frames` 1 and
  `gaps_in_frame_num_value_allowed_flag` 0, clause 7.4.3 requires `frame_num` of each picture to be the previous reference picture's value plus one
  modulo `MaxFrameNum` (every picture is a reference picture, an IDR picture restarts at 0); the firmware or driver writes it
  (`rtlnet_h264_enc_next_frame_num`).
* **Reference picture.** `REF_Y_BASE` and `REF_U_BASE` hold the tile bases of the previous picture's rebuilt picture, in the layout of section 7. The driver
  alternates two rebuilt buffers: picture n is written to buffer n mod 2 (`RY_BASE`, `RU_BASE`) and reads buffer (n - 1) mod 2 as the
  reference. `rtlnet_h264_ref_dma` fetches the co-located macroblock of every macroblock of the band, in raster order, ahead of stage A: one 16-beat burst
  for the luma tile and one 8-beat burst for the chroma tile into a bank of the reference macroblock buffer (two banks, `REF_BUF_KB`). A second
  fetch sequencer in the engine runs beside the input-strip sequencer; the two DMAs share the AR and R channels one at a time: the reference DMA starts
  only while the strip DMA is idle and no strip start is pending, and the strip sequencer starts only while the reference DMA is idle. The reference reads
  use AXI ID 1, the strip reads ID 0. Stage A starts a macroblock of a P picture when its reference bank is full, so the fetch does not add to the
  per-macroblock time as long as it stays ahead (it takes about 50 clocks against 380).
* **Mode decision (stage A).** The candidates are P_Skip, P_L0_16x16 at (0,0), Intra16x16 and the I_PCM fallback. The SAD phase accumulates the SAD of the source against the
  reference macroblock (luma and chroma, `sad_iy` and `sad_ic` of `rtlnet_h264_ipred`) beside the intra candidates, so no phase is added. Two clocks
  after the intra decision (MD1, MD2) the encoder compares the inter cost `SAD_inter + lambda x bits(mvd)` with the intra cost `SAD + mode cost + 16 x
  lambda` (the SAD and mode cost of the best intra modes of `ipred`); ties go to inter. `lambda = round(0.92 x 2^((QP - 12) / 6))`, at least 1
  (the form of the JM motion lambda: 1 at QP 12, 7 at QP 30, 83 at QP 51), `bits(mvd)` the lengths of the two se(v) codes of `mvd = mv - mvp`. The 16 bits of intra
  charge stand for the larger `mb_type` and mode fields of an intra macroblock in a P slice and give a static scene a bias towards the reference. Chosen
  inter: P_L0_16x16; if the quantized residual is empty (cbp 0) and the skip vector is (0,0), P_Skip.
* **Motion vector context.** `rtlnet_h264_mvctx` keeps the vectors and the inter flag of the left macroblock (registers) and of the row above (a
  line RAM, one 32-bit word per column, `MV_LINE_KB`), and `rtlnet_h264_mvpred` derives from them, with the availability of the left, above, above-right and
  above-left macroblocks inside the slice and the picture, the median predictor `mvp` of clause 8.4.1.3 (neighbour C replaced by D when it is not
  available; B and C replaced by A when both are unavailable and A is available; the single matching reference index; the median) and the P_Skip vector of
  clause 8.4.1.1. The context is started with each macroblock, ready 5 clocks later (inside the 20-clock neighbour phase), and updated at its end
  (intra and I_PCM macroblocks: inter 0, vector 0; P_Skip: the skip vector). `mvd = mv - mvp` is coded as se(v) for every P_L0_16x16 macroblock, so the syntax is the
  one stage 2c-2 needs; with every vector equal to (0,0) the predictor is (0,0) and `mvd` is (0,0) in this stage.
* **Inter residual and rebuild.** The luma blocks have 16 coefficients, with no luma DC transform: `rtlnet_h264_fwdq` runs with `in_full` (the DC position is quantized like the
  others, with the class 0 multiplier) and `rtlnet_h264_invq` with `in_full` (the DC position is dequantized like the others); the luma DC unit still runs
  (its schedule is unchanged) and its result is ignored. The chroma blocks are as for intra (DC 2 x 2 plus AC), with the inter rounding offset. Quantizer rounding:
  `f = 2^qbits / 6` for inter (`/ 3` for intra), an encoder choice (also in the chroma DC unit: `2 f` with the inter `f`). The coded block pattern is the luma 8x8 mask (a bit is
  set when a level of one of its four 4x4 blocks is non-zero) and `cbp_chroma` as for intra (2 when an AC level is non-zero, else 1 when a DC level is). The rebuild is
  the reference sample plus the inverse-transformed residual, clipped; a skipped macroblock is rebuilt to the prediction. The rebuilt tile write is unchanged. The size estimate
  and the fallback to I_PCM apply to inter macroblocks as to intra ones (the luma DC unit does not count).
* **Isolated coefficient elimination (encoder choice).** An inter macroblock whose quantized residual consists of at most 6 non-zero levels, every one of magnitude 1, is coded
  without a residual (its levels are dropped, cbp 0, the rebuild adds nothing). These levels are the requantization of the previous picture's quantization error;
  at low QP their dequantized size is below one sample, the inverse transform rounds it away, and without the rule they repeat in every picture of a static scene. With the rule a static scene
  codes as P_Skip from the first P picture on at every QP tested (12, 28, 38, 51).
* **Syntax (stage B, `rtlnet_h264_mb_cavlc`).** `mb_skip_run` ue(v) before each coded macroblock of a P slice and, from the engine (state `E_SKR`), at the slice end when it is not 0; the run restarts at every
  slice. P mb_type 0, no `ref_idx` (one active reference), `mvd_l0` x and y se(v), the inter coded_block_pattern me(v) (Table 9-4, generated from the JM table by
  `testbench/h264_gen_cbp_table.py`), `mb_qp_delta` only for cbp != 0, `LumaLevel4x4` blocks of the coded 8x8 groups, then chroma. Intra macroblock types are offset by 5. nC counts skipped and inter
  neighbours as available with their `TotalCoeff` (0 for a skip and for uncoded groups). An inter macroblock above the size cap falls back to I_PCM (mb_type 30). Section 8 lists the syntax.

### 15.2 Restrictions of stage 2c-1

* Every inter macroblock has the vector (0,0): no search, no sub-sample vectors, no picture-edge rule (the co-located macroblock is always inside the picture).
* P_Skip needs the skip vector (clause 8.4.1.1) to be (0,0), because its prediction would otherwise need that vector. The skip vector is computed in full (it is `mvp` unless A or B is
  unavailable or has the vector (0,0) with reference index 0). With every vector (0,0) it is always (0,0); stage 2c-2 lifts the restriction by predicting P_Skip from the skip vector.
* One reference picture (the previous one), one slice type per picture (all slices P), no B slices, no weighted prediction, no deblocking (`disable_deblocking_filter_idc` 1), CAVLC only.
* Intra macroblocks in P slices are Intra16x16 or I_PCM as in I slices; `constrained_intra_pred_flag` is 0.
* The first picture of a stream, and the first picture after any decoder reset, is an IDR picture; the firmware (not the core) decides the GOP.

### 15.3 Registers and driver

PIC_CFG[1] (P picture), REF_Y_BASE (0x054), REF_U_BASE (0x058) and the VERSION 0x11102C01: section 6. Driver (`driver/rtlnet_h264_enc.{h,c}`):
`rtlnet_h264_enc_start_picture_ex(base, frame_num, idr_pic_id, RTLNET_H264_PIC_IDR | RTLNET_H264_PIC_P)`, `rtlnet_h264_enc_next_frame_num`,
`rtlnet_h264_enc_set_reference`, and the two-buffer helper (`rtlnet_h264_enc_buffers_t`): `buffers_init(y0, u0, y1, u1)`, `buffers_begin(base, bufs, type)` (writes the current buffer's
`RY_BASE`/`RU_BASE` and, for a P picture, the other buffer's reference bases; rejects a P picture before any picture has been completed), `buffers_end` after DONE (the written buffer becomes the reference).
`rtlnet_h264_enc_start_picture` is unchanged and starts an I picture. The firmware does not use the new API in this stage. A
GOP loop is: IDR (`frame_num` 0, new `idr_pic_id`), then P pictures with `frame_num = next_frame_num(previous)`; `buffers_begin` before and `buffers_end` after each picture.

### 15.4 What stage 2c-2 replaces

* The reference fetch: the sliding search window per engine replaces the co-located macroblock read (`rtlnet_h264_ref_dma`, the reference buffer and the AR arbitration stay as the pattern).
* In `rtlnet_h264_mb_enc` the trio `inter_mv_x`, `inter_mv_y` (constant 0 here) and `inter_sad` (the SAD at that vector) is the plug: the search drives them, `mvd` and the rate term follow, the prediction
  read (`ref_word`, `ref_seg`) addresses the interpolated or shifted reference, and the skip decision drops its `inter_mv == 0` test.
* `rtlnet_h264_mvctx` already stores arbitrary 14-bit vectors, and the syntax writer codes arbitrary `mvd`; `tb_rtlnet_h264_mvpred` covers them.

### 15.5 Verification (Verilator, section 10)

All runs 11-10-2026 with the final RTL; logs in `.sim/logs/` (gitignored work directory; the log names are listed here).

| Check | Result | Log |
|---|---|---|
| Unit benches with their negative controls (`scripts/rtlnet_regression.ps1 -Match "^tb_rtlnet_h264_"`) | 14 passed, 0 failed: bitpack 4 checks, c422 4, cavlc 37 912, mbcavlc 4 936 (P slices: 164 inter, 762 skipped, 126 intra-in-P macroblocks and a 600-macroblock skip run), xform 483 044, ipred 56 161, mvpred 608 461 | `p2c1_units.log` |
| Motion vector predictor (`tb_rtlnet_h264_mvpred`) | 200 020 neighbour sets (directed edge cases: no neighbour, only A, B, C or D, B and C unavailable with an intra A, single matching reference index, median with ties, skip with a zero A or B, +-8191) and 2 100 context macroblocks over pictures with random slice starts: 608 461 checks | `p2c1_units.log` |
| Decoder harness, earlier configurations | `h264_harness_par.ps1` over all 74 configurations (I pictures only): 74 of 74 passed | `p2c1_oldv_par.log` |
| Decoder harness, P configurations `p_*` | 40 of 40 passed: JM, OpenH264 and FFmpeg byte-identical to the de-tiled rebuilt picture of EVERY picture of every GOP, PSNR floors of (sequence, QP) met for every picture | `p2c1_v_par.log`, `p2c1_cutv_par.log` (the six cut configurations after the GOP change) |
| Negative controls | `-InjectBurst` (1-beat rebuilt AW): monitor fires (2 of 2); `-InjectBurstRef` (4-beat reference read): monitor fires (2 of 2); `-Inject` (corrupted stream byte): all three decoder comparisons fail (`p_qcif_pan_q28`, `qcif_s1`) | `p2c1_negs.log` |
| Lint, driver test | `LINT PASS` (0 warnings in `rtlnet_h264_*`); `DRIVER TEST PASS: rtlnet_h264_enc checks=450` | `p2c1_negs.log` |
| Burst monitor, 1080p 2 engines QP 28 pan (9 pictures, engine 0) | input AR 146 880 bursts of 8 beats; reference AR 32 640 x 16 beats and 32 640 x 8 beats; rebuilt AW 36 720 x 8 and 36 720 x 16; index AW 18 x 8; no 1-beat transaction | `p2c1_v_p_1080p_e2_s2_pan_q28.log` |

The P configurations (QCIF 176x144 unless noted; every GOP is `IPPPPPPPP` (9 pictures) or `IPPPPIPPPP` (a second IDR picture inside the run), the `cut` GOP is `IPPPPPPPPP`
with the scene cut at picture 5 inside the P run, and `p_qcif_pan_gop20_q28` has 20 pictures so that `frame_num` wraps at 16):
sequences static (all-skip required), pan (whole-pixel pan of a photo: 4 samples right and 1 down per picture), bars_move (moving colour bars), noise_p (independent noise) and
cut (scene change); QP 12, 20, 28, 38, 51; 1 and 2 engines; 1, 2, 3, 4 and 9 slices (static and cut configurations with several slices cover the skip run reset at slice starts);
widths 208, 80 and 288 (the strip tails); a 16 KiB ring with a slow consumer; 720p and 1080p with 1 and 2 engines and 1, 2 and 4 slices over QP 12, 28, 38 and 51. The static
configurations (`p_qcif_static_*`, `p_720p_e2_s2_q38`, `p_1080p_e2_s2_static_q28`) require every P picture to be at most 6 + 24 x slices stream bytes and its rebuilt
picture to equal the previous one: they pass (16 bytes per P picture at QCIF with one slice). `ffmpeg -debug mb_type` of the static QP 28 stream before
the isolated coefficient elimination was added showed 12 of 99 macroblocks of the first P picture as P_L0_16x16 with one +-1 level each; with the rule every P macroblock is skipped.
The PSNR floors of the sequences are in `h264_psnr_floors.txt` (the minimum over the pictures and configurations minus 1 dB).

**Clocks per macroblock** (`PIC_CYC / MB_COUNT` of an engine, memory model latency 20, gap 20 %, `-Lat 20 -Gap 20`; the gate for P pictures at 1080p, 2 engines, is 480):

| Content | Engines | I pictures | P pictures |
|---|---|---|---|
| 1080p, pan QP 28 (moving content) | 2 | 379 | 381 (gate 480) |
| 1080p, static QP 28 (all skip) | 2 | 379 | 381 |
| 1080p, QP 38 and 51 (rotating sequences) | 2 | 379 | 381 |
| 1080p, QP 12 (`p_1080p_e1_s1_q12`, pan) | 1 | 433 | 435 |
| 720p, QP 12 to 51 | 1 and 2 | 379 | 381 to 382 |
| QCIF, smooth and static content | 1 | 383 to 385 | 385 to 387 |
| QCIF, noise QP 12 / 28 (dense, I_PCM fallback) | 1 | 440 / 526 | 442 / 525 |
| QCIF, strip width 5 (80 x 144, 2 engines) | 2 | 399 to 406 | 405 to 418 |

A P picture costs 2 clocks per macroblock more than an I picture (the inter decision, MD1 and MD2); the reference fetch overlaps stage A. The macroblock time is stage A (about 381 clocks): stage B
codes a skipped macroblock in a few clocks and a dense inter macroblock inside the stage A time. The 735-clock board budget leaves margin for the 15 % the board adds over the model.

**Mutations of the P path** (`h264_mutation.ps1 -Only 14,15,16,17,18,19`; logs `p2c1_mutation.log`, `p2c1_mutation2.log`, `p2c1_mutation3.log`; each file restored with an identical SHA-256): (14) a wrong inter coded_block_pattern code
(cbp 31): caught by the mbcavlc bench and by `p_qcif_pan_q12` (all three decoders); (15) `mb_skip_run` off by one: caught by the mbcavlc bench and by `p_qcif_cut_q28` (all three decoders); (16) the reference
chroma tile pointer stepping by 256: caught by `p_qcif_pan_q28`; (17) P_Skip chosen although luma levels are coded: caught by `p_qcif_pan_q28`; (18) the intra rounding offset used for inter blocks: caught by the xform bench only
(a legal encoder choice that a decoder cannot see); (19) the single-matching-reference rule ignoring neighbour C: caught by the mvpred bench only (every vector is 0 in this stage). The first versions of three mutations survived
and were replaced or their configuration changed: a cbp code (cbp 1) that the sequences never produce, a B and C substitution that is equivalent to the median rule when A is the only inter neighbour, and the skip run mutation
under `p_qcif_cut_q28`, whose scene cut fell on the second IDR picture so that no coded macroblock followed a skipped one (the cut GOP has no IDR picture at the cut now).

**Verilator compile memory.** The model of `tb_rtlnet_h264_top` at 720p and 1080p generated one 71 MB C++ file (the constant-bound loops of the bench unrolled); one `cc1plus` needed 4 to 18 GB and minutes to compile. The harness
now passes `--unroll-count 8 --unroll-stmts 500 --output-split 5000` to `rtlnet_run_verilator.ps1 -Extra`: the largest generated file is 0.4 MB, the 720p bench builds and runs in about 50 s, and the
results are unchanged. `h264_harness_par.ps1` defaults to 4 jobs. The harness still builds one model per configuration (the picture size, slice count, engine count and QP are defines of the bench); building one model per define set
would need those values as run-time plusargs, a larger change that is not made.

### 15.6 RAM added

Phase 2c-1 adds two memories per engine, both `rtlnet_ram_core` instances with `*_KB` size parameters and `RAM_STYLE`:

| Memory | Parameter | Size per engine | Block RAM (`RAM_STYLE` "block") |
|---|---|---|---|
| Reference macroblock buffer (2 banks of 32 words, 24 used, 128 bit) | `REF_BUF_KB` 1 | 64 x 128 bit = 8 Kibit | 4 RAMB18 (128 bit wide as four 36-bit slices, depth 64 of 512): 2 RAMB36 equivalents; 4 RAMB36 equivalents for 2 engines |
| Motion vector line RAM (one 32-bit word per column) | `MV_LINE_KB` 1 | 256 x 32 bit = 8 Kibit | 1 RAMB18: 0.5 RAMB36 equivalents; 1 for 2 engines |

Total for `NUM_ENGINES` 2: 10 RAMB18, about 5 RAMB36 equivalents, on top of the 22 RAMB36 + 2 RAMB18 of section 14.3 (by capacity only 32 Kibit, under one RAMB36; the width of the reference words
sets the count). `RAM_STYLE` "distributed" puts the reference buffer in about 130 LUTs per engine. Memory outside the core: the second rebuilt buffer, 3,133,440 bytes at 1080p. The
added logic is small (the inter decision, the motion vector context, the reference DMA, two comparators).

### 15.7 Synthesis of the committed 2c-1 RTL (step 0 of phase 2c-2, 11-10-2026)

`h264_synth.tcl`, 2 engines, 11.111 ns, `xc7a200tsbg484-1` (`.sim/synth/h264_top_2c1.log`): **WNS -2.871 ns** (30 failing endpoints), 41,387 LUT, 27,338 FF, 26 RAMB36 + 4 RAMB18, 74 DSP,
0 critical warnings. Two path groups failed, both in 2c-1 logic: `u_mvctx/mvp_x` to `cost_in` in `rtlnet_h264_mb_enc` (the MD1 clock computed mvd, the two se(v) lengths, the lambda
multiply and the add in one clock: 21 logic levels, 14.0 ns) and the compare of the skip vector in `rtlnet_h264_mvctx` (`skip_zero`, -1.3 ns, 15 levels). Fixes (no change of behaviour or clocks):
the mvd, its code lengths and the rate `lambda x bits` are free-running register stages (the vector, the predictor and the QP are stable far before MD1); `skip_zero` is the compare of the
registered skip vector. After the fix (`.sim/synth/h264_top_2c1fix.log`): WNS +0.895 ns, 41,546 LUT, 27,374 FF, 26 RAMB36 + 4 RAMB18, 76 DSP (the rate multiplier). The LUT and RAMB36 gates of
2c-2 are measured against the committed numbers (41,387 LUT, 26 RAMB36).

## 16. Motion search, phase 2c-2 (11-10-2026)

Phase 2c-2 replaces the co-located reference read of 2c-1 by an integer-pel motion search of the 16 x 16 partition with one reference picture
(`rtlnet_h264_search`, one per engine). The syntax writer, the motion vector context of stage A and the residual path are those of 2c-1.

### 16.1 Pipeline

The search is its own stage, one macroblock ahead of stage A. Per macroblock of the band, in raster order, it (1) waits until the window holds the
columns it needs, (2) copies the even luma rows (0, 2, ..., 14) of the macroblock from the strip buffer into a small buffer, (3) searches, (4) writes the prediction at
the best vector into a bank of the prediction buffer (the 2c-1 reference macroblock buffer, same layout: luma word y, Cb words 16 + k, Cr words 20 + k)
and reports the vector. The engine starts the next search when the other bank is free and the macroblock's strip is in the strip buffer. Stage A starts
a macroblock when its prediction bank is full, reads the prediction exactly as in 2c-1 (SAD phase, PASS1, PASS3) and takes the vector (`mv_in_x`,
`mv_in_y`, quarter samples, a multiple of 4). The search reads the strip buffer only in clocks stage A does not use its read port (and never while an
I_PCM copy runs, `src_lock`). The search stage takes 150 to 250 clocks per macroblock on typical content, so stage A (about 381 clocks) stays the limit.

**Approximation.** Stage A decides each macroblock one macroblock behind the search, so the left neighbour's final vector (it can be P_Skip at the
skip vector, or intra) is not known when the search runs. The search keeps its own vector context (`rtlnet_h264_mvctx` instance, its own line RAM)
filled with its own results: the predictor used for the rate term, and the left, above and above-right candidates, are search vectors, not final ones.
Stage A computes the exact `mvp` for `mvd` and for the skip decision and makes the final choice: P_Skip, P_L0_16x16 at the search vector, Intra16x16
or I_PCM. The cost of the approximation is only efficiency (a rate term against a slightly different predictor).

### 16.2 Search window

Two window RAMs (`rtlnet_ram_core`, 128 bit, `WIN_KB` 4 KiB, 256 words each, `RAM_STYLE`; 2 RAMB36 each, 4 RAMB36 per engine at `MAX_MB_W` 120) hold
four columns of reference tiles, slot = global column load index mod 4: the columns c - 1, c, c + 1 of the macroblock being searched and the column
c + 2 being prefetched. Adjacent columns have adjacent slots, so one RAM holds the even slots and the other the odd ones, and a 16 sample luma row at any
horizontal offset (the rows of two adjacent tiles, shifted by `vx mod 16` bytes) is read in one clock, one word from each RAM. Per slot pair and RAM:
3 macroblock rows (r - 1, r, r + 1) x 16 luma words (word `{slot[1], wr, y}`) and 8 chroma words (128 + `{slot[1], wr, beat}`, the tile beats as stored).
The loader loads one column per macroblock (the tiles of the rows that exist: three 16-beat luma and three 8-beat chroma bursts, AXI ID 1, tile
aligned, never 4 KiB crossing), so every reference tile is read three times per picture. A column g may load while g < (first column the current
search needs) + 4, and a search starts when its last column is loaded; at the end of a macroblock row the loader continues with the next row's columns
while the last macroblocks of the row search. Tiles outside the picture are not fetched. The window needs 4.5 RAMB36 per engine including the search
vector line RAM; the 8-word source buffer (`SRCBUF_STYLE`, distributed) takes about 16 LUTRAM.

### 16.3 SAD unit

`rtlnet_h264_sad16`: 16 absolute differences per clock (one macroblock row), four register stages (differences, sums of four, row sum, accumulation).
The metric covers the 8 even rows of the macroblock (a 2:1 vertical subsample of the search metric only; stage A computes the exact SAD of the chosen
vector), so a candidate takes 8 clocks; candidates follow each other with no gap, a result appears 4 clocks after the last row.
Sizing: the search budget is the stage A time (381 clocks) minus about 100 clocks for source copy, prediction and overhead; at 8 clocks per candidate
that is about 35 candidates, and the measured mean is 8 to 12 per macroblock on the test sequences (the evaluation cap `MAX_EVAL` 48 bounds the worst
case at about 600 clocks; the worst measured P picture is 560 clocks per macroblock on average). 32 samples per clock (two rows) would need four window words per clock, double
the window RAM width. A full 16-row metric (16 clocks per candidate, built and measured) raised the true-vector share only by a few macroblocks per
picture and took the 1080p pan to 625 clocks per macroblock, over the 600 gate, so the subsampled metric stays.

### 16.4 Picture-edge rule

Every candidate vector keeps the 16 x 16 luma block inside the picture: `0 <= 16 c + vx` and `16 c + vx + 16 <= 16 MB_W`, the same vertically, and
`|vx|, |vy| <= SR`. The bounds are 0 in the first and last column / row and +-`SR` elsewhere, so the block never leaves the window. For an integer luma
vector the chroma vector (clause 8.4.1.4, the luma vector in units of 1/8 chroma sample) is `4 vx` with `xIntC = (4 vx) >> 3 = floor(vx / 2)` and
`xFracC = (4 vx) & 7 = 4 (vx & 1)` (clause 8.4.2.2.2); the taps `xIntC` and `xIntC + 1` (and rows likewise) stay inside the chroma picture because the
luma block does: the last tap is at most `8 c + floor(vx / 2) + 8 <= 8 MB_W - 1` for odd `vx` (for even `vx` the weight of the extra tap is 0). So no
sample coordinate clipping (equations 8-229, 8-230) is needed in this phase. Vectors that point outside the picture (edge padding) are left to Phase 2e.
P_Skip is allowed only when the exact skip vector (clause 8.4.1.1) equals the search vector (so it is inside the picture and the window) and the
residual at that vector quantizes to zero (with the isolated-coefficient rule of 15.1); this replaces the 2c-1 restriction "skip only at (0,0)".

### 16.5 Search pattern

Cost = 2 x SAD(8 even rows) + lambda(QP) x (se(v) length of `mvdx` + of `mvdy`) with `mvd = 4 v - mvp` against the approximate predictor (clause 9.1 lengths), plus, for every vector but (0,0),
`ZERO_BIAS` (128) and 8 more bits of lambda (a static scene keeps the zero vector and codes as P_Skip at every QP: with a smaller bias the rebuilt-picture noise made a few macroblocks of the static
sequences move). Strictly lower cost wins; earlier candidates win ties.
Candidates, in this order, deduplicated and filtered by the edge rule: (0,0), the predictor (median of the neighbours, clause 8.4.1.3, all inter),
the left, above and above-right (above-left when the latter does not exist) vectors, and the vector of the macroblock searched just before (raster
order, across rows and pictures: a global motion continues; without it a pan with large vectors never found its vector from row 0 on). Then step stages
around the best candidate: d = 16 (8 points: the four diamond points and the four diagonal ones), 8 (8 points), 4 (8), 2 (4) and 1 (4 points), at most
3, 3, 2, 2 and 3 repeats while the best point moves; the stages d >= 2 are skipped when the best cost is at most `GOOD_COST` (768) at the start of the
stage; no new step starts after `MAX_EVAL` (48) evaluations. A typical pan macroblock evaluates the 1 to 3 distinct candidates and one diamond of
4 points. The software model in `tb_rtlnet_h264_search` implements exactly this order and the unit bench checks every evaluated vector and SAD.

### 16.6 Prediction

Luma: the 16 rows at the integer vector, one row per clock from the window. Chroma: `rtlnet_h264_cinterp`, clause 8.4.2.2.2 equation 8-228
`((8 - xFrac)(8 - yFrac) A + xFrac (8 - yFrac) B + (8 - xFrac) yFrac C + xFrac yFrac D + 32) >> 6`, implemented for every `xFracC`, `yFracC` of 0 to 7
as two exact separable steps (horizontal weights per source row, vertical weights per row pair), 8 samples per clock; 9 source rows per plane, 18 clocks;
only fractions 0 and 4 occur now. The rebuild of stage A uses the same prediction buffer.

### 16.7 Registers and parameters

No register changes (VERSION 0x11102C02). `SR` (0 to 16, default 16) and `WIN_KB` are parameters of `rtlnet_h264_top`; `SR` 0 searches only (0,0) (the
2c-1 behaviour, used as the baseline of the bits gate).

### 16.8 Verification (Verilator, section 10)

All runs 11-10-2026 with the final RTL; logs in `.sim/logs/` (gitignored work directory).

| Check | Result | Log |
|---|---|---|
| Search unit bench `tb_rtlnet_h264_search` (model of the algorithm; candidate order, deduplication, edge legality, SAD of every candidate, best cost, final vector, the 24-word prediction, the window RAM contents of the columns c - 1 .. c + 1 after every macroblock, burst shapes and counts) | 7 configurations pass: 6 x 5 full picture with a true vector (30 macroblocks, 786 candidates, 4,992 window words), band 2..4 of 7 x 6, 2 x 4 (width 2), random picture at QP 51, vectors beyond the range with `SR` 8; the `_neg` control fails as required | `.sim/verilator/tb_rtlnet_h264_search*/run.log` |
| Chroma interpolation `tb_rtlnet_h264_cinterp` | all 64 fractions x 5 blocks (random, extreme, gaps and back to back): 8,000 checks against equation 8-228 | `.sim/verilator/` |
| SAD unit `tb_rtlnet_h264_sad16` | 380 checks (126 candidates of 1 to 40 rows, with and without gaps) | `.sim/verilator/` |
| All 24 H.264 unit bench entries (`rtlnet_regression.ps1 -Match "^tb_rtlnet_h264_"`) | 24 passed, 0 failed | `.sim/verilator/` |
| Decoder harness, earlier configurations | `h264_harness_par.ps1` over the 74 I-picture configurations: 74 of 74 passed | `g0_par.log` |
| Decoder harness, 2c-1 P configurations `p_*` | 46 of 46 passed (static scenes all-skip at QP 12, 28, 38, 51) | `g1_par.log` |
| Decoder harness, 2c-2 configurations `m_*` | 53 of 53 passed: JM, OpenH264 and FFmpeg byte-identical to the de-tiled rebuilt picture of EVERY picture of every GOP, PSNR floors met (QCIF, 720p, 1080p; 1 and 2 engines; 1, 2, 3, 4, 9 slices; QP 12 to 51; pans of 1 to 16 samples per picture horizontally, vertically and diagonally, 24 beyond the range, a bouncing window, moving objects over a static background, moving bars, noise, a cut, widths 208, 80 and 288) | `g1_par.log` |
| Burst monitor, 1080p 2 engines QP 28 pan of 12 samples (engine 0) | input AR 146,880 x 8 beats; window AR 96,960 x 16 beats and 96,960 x 8 beats (three reads of every reference tile per picture); rebuilt AW and index AW unchanged; no 1-beat transaction | `g1_m_1080p_e2_s2_panh12_q28.log` |
| Negative controls | `-InjectBurstRef` (4-beat window read): monitor fires on `m_qcif_panh8_q28` and `p_qcif_pan_e2_s2_q28`; `-InjectBurst` and `-Inject` (corrupted stream byte): all fail as required | `n_refneg.log`, `n_burstneg.log`, `n_inject.log` |
| Lint, driver test | `LINT PASS` (0 warnings); `DRIVER TEST PASS: rtlnet_h264_enc checks=450` | |
| Mutations (`h264_mutation.ps1 -Only 14 .. 24`) | 11 of 11 caught, each file restored with an identical SHA-256: (16) window chroma tile pointer step wrong, (20) a window column loaded into the wrong slot, (21) the mvd cost of the search without the predictor (only the search bench sees it: it compares the best cost), (22) chroma interpolation weight off by one, (23) the lower edge bound of the search removed, (24) P_Skip without the skip vector equal to the search vector; (14), (15), (17), (18), (19) of 2c-1 unchanged | `n_mut.log` |

**Search quality.** Pans by a known integer vector over the value-noise canvas (`vtex`), QP 12 to 28, the share of the macroblocks whose block at the pan vector lies
inside the picture that carry exactly that vector (`MVSTAT`, minimum over the 8 P pictures; gate 90 %): panh1 97.8 %, panh2 100 %, panh3 100 %, panh5 98.9 %, panh8 93.3 % (QP 12
and 28, 3 slices), panh12 98.9 %, panh16 100 %, panv1 96.6 %, panv4 98.9 %, panv9 94.3 %, panv16 100 %, pand2 98.8 %, pand6 90.0 % (QP 28) and 91.2 % (QP 20), pand11 97.5 %,
pand16 100 %, 720p panh8 100 %, 1080p panh12 99.9 % and pand16 (QP 20) 100 %, strip widths 13 and 18: 96.3 % and 100 %, `SR` 8: 100 %. Configurations that are not gated: the two
2-engine QCIF pans (`m_qcif_pand6_e2_s2_q28`, `m_strip_w5_e2_pand3_q28`: 32 to 80 macroblocks per picture, the worst picture 87.5 %), QP 38 and 51 (the quantizer leaves too little of the
texture), and the 2c-1 smooth photo pan (4 samples right, 1 down: 42 to 69 %; even an exhaustive full SAD search finds the vector in only 35 of 80 macroblocks of its first P picture
because the QP 28 rebuilt photo makes vectors one sample apart practically tied). **Bits:** the P pictures of `m_qcif_panh8_q28` carry 36,096 bits with the search against 306,544 with `SR` 0
(the 2c-1 behaviour): ratio 0.118; `m_qcif_pand6_q28` 0.226; 1080p panh12 (2 engines) 0.010; the 2c-1 photo pan 0.19 (limit 0.50;
`h264_check.py bitsratio`).

**Clocks per macroblock** (`PIC_CYC / MB_COUNT` of an engine, `-Lat 20 -Gap 20`; gate for P pictures at 1080p, 2 engines: 600):

| Content | I pictures | P pictures (min / mean / max) |
|---|---|---|
| 1080p, pan of 12 samples QP 28, 2 engines (`m_1080p_e2_s2_panh12_q28`) | 379 | 397 / 398 / 399 |
| 1080p, pan of 16 diagonal QP 20, 1 engine | 379 | 383 / 383 / 384 |
| 1080p, 2c-1 pan QP 28 and static QP 28 (`p_1080p_e2_s2_*`) | 379 | 381 / 381 / 382 |
| 1080p, objects QP 51, 4 slices; noise QP 28 (dense, I_PCM fallback) | 379; 525 | 405 / 406 / 409; 520 / 525 / 531 |
| 720p, pans, objects, bounce (QP 12 to 38) | 379 to 437 | 382 to 419 |
| QCIF, pans QP 28 | 384 | 396 to 433 |
| QCIF, pan beyond the range (24), QP 12 / 28 | 443 / 385 | 517 to 547 / 506 to 531 |
| QCIF, 2 engines, 4 samples wide strips (`m_strip_w5_e2_pand3_q28`, worst case) | 405 to 413 | 491 / 523 / 560 |
| QCIF, noise QP 28 | 526 | 531 / 533 / 535 |

The search stage (about 150 to 250 clocks per macroblock on typical content: 8 to 12 candidates of 8 clocks, the prediction 40 clocks, the window and source waits) runs in the shadow of stage A
(381 clocks); the worst measured P macroblock average is 560 (`MAX_EVAL` 48 bounds the worst case at about 600 clocks of search plus waits), inside the 600-clock gate and the 735-clock board budget.

**RAM per engine** (2c-2, `RAM_STYLE` "block", `MAX_MB_W` 120): window 2 RAMs x 4 RAMB18 = 4 RAMB36; the search vector line RAM 1 RAMB18; the 8-word source buffer in LUTRAM; the prediction buffer is the
2c-1 reference buffer (2 RAMB36, unchanged). 2 engines: +8 RAMB36 and +2 RAMB18 over 2c-1.

### 16.9 Synthesis

`h264_synth.tcl`, 2 engines, `enc_clk` 11.111 ns, `xc7a200tsbg484-1` (`.sim/synth/h264_top_2c2c.log`): PASS, 0 critical warnings, post-synthesis **WNS +0.881 ns** (worst path `u_regs/cfg_mb_h` into
`me_left`), **47,083 LUT** (+5,696 over the committed 2c-1 RTL's 41,387; +5,537 over the timing-fixed 41,546; gate +12,000), 31,071 FF, **34 RAMB36** (+8 over 26; gate +10) + 6 RAMB18, 76 DSP.
Per engine the search stage costs about 2,800 LUT (SAD unit, chroma interpolator, shifters, the search sequencer, the window loader and the search's motion vector context).

## 17. High profile seam (11-11-2026)

The High profile tools (CABAC entropy coding, 8x8 transform) are a separate licensed product delivered as a netlist of one module,
`rtlnet_h264_hp`, one instance per engine. This repository holds only the seam; the module's source, its specification and its netlist build are
in the High profile repository (`H264HighProfile`).

### 17.1 Seam

- `HIGH_PROFILE` (top, engine, register block, board top; default 0). With 0 no reference to `rtlnet_h264_hp` exists and the generated logic is that
  of the Constrained Baseline encoder: out-of-context synthesis of two engines gives 47,083 LUT, 31,071 FF, 37 RAMB tiles and 76 DSP before and
  after the change, with the same post-synthesis WNS (+0.881 ns) and the same worst path into the packer command register (6 logic levels).
- With 1 each engine instances `rtlnet_h264_hp` as a black box. The module takes the macroblock descriptor of stage B (`rtlnet_h264_mb_cavlc`
  inputs), a read port of the coefficient bank, picture and slice events, and drives packer commands (`rtlnet_h264_bitpack` command interface),
  status (`hp_present`, `hp_licensed`, `hp_seconds_left`, `hp_caps`, `hp_active`) and, since stage 3, the 8x8 transform streams (section 17.6). The engine
  multiplexes the entropy path by `hp_active`, which holds for a whole picture. The multiplexer keeps the entropy path at 6 logic levels in
  the synthesis estimate.
- Slice events and the slice header. `slice_start` is high while the sequencer writes the first command of a slice header and `slice_end` while it
  waits in its slice-end state (both levels; the module uses their rising edges). With `hp_active` the sequencer writes the slice header of a P slice
  with one more bit (`cabac_init_idc` 0, `ue(0)`, behind the reference marking bits) and, in its slice-end state, holds the rbsp trailing bits
  (`PK_END`) until the module's `mb_busy` has risen and fallen again: the module writes the end of the slice data meanwhile. With `hp_active` 0 and
  with `HIGH_PROFILE` 0 the sequencer is unchanged.
- Packer. A new command `PK_ALIGN1` (op 6) pads with one bits to a byte boundary (the `cabac_alignment_one_bit` of the slice data); it exists only when
  the packer's parameter `ALIGN_ONES` is 1, which the engine sets from `HIGH_PROFILE`. With `ALIGN_ONES` 0 the packer is unchanged.
- Cost of the seam. Out-of-context synthesis (2 engines, 90 MHz, `xc7a200tsbg484-1`): `HIGH_PROFILE` 0 is identical to the commit before the change
  (47,083 LUT, 31,071 FF); `HIGH_PROFILE` 1 with the full netlist of the module is 52,150 LUT and 33,643 FF in total (post-synthesis WNS +0.881 ns).
- `hdl/hp/rtlnet_h264_hp_bb.sv` is the black-box declaration for a synthesis that reads the netlist. `hdl/hp/rtlnet_h264_hp_stub.sv` is the
  simulation and default-build stand-in (`hp_present` 0, `hp_licensed` 0, `hp_caps` 0, idle); `rtlnet_h264_enc.f` lists it,
  `rtlnet_h264_enc_core.f` is the same list without it. RTLNet simulates and builds without the netlist.

### 17.2 Forced IDR picture

The engine applies a change of `hp_licensed` or `hp_enable` only at a picture start. A start that sees a change codes an IDR picture (frame_num 0,
a new `idr_pic_id`, intra macroblocks only) whatever the registers requested, sets `HP_STATUS.PROFILE_CHG` and counts one change pulse. The
firmware (`rtlnet_venc`) reads and clears the flag after each picture, restarts its GOP at that picture and writes the parameter sets in front of
it, in the form of the profile now in force: High (`profile_idc` 100, CABAC) while the module codes the pictures, Constrained Baseline when the
license has ended or `hp_enable` is 0. The stream therefore changes profile at an IDR picture with new parameter sets and keeps running.

### 17.3 Registers, driver, CLI

HP_CTRL and HP_STATUS are in section 6. Driver: `rtlnet_h264_enc_hp_status`, `rtlnet_h264_enc_set_profile` (refusals with named codes
`RTLNET_H264_HP_ERR_*`), `rtlnet_h264_enc_hp_clear_change`, `rtlnet_h264_enc_write_sps_pps_profile` (the SPS and PPS in the Constrained Baseline form or, with
`high`, the High form: `profile_idc` 100, `chroma_format_idc` 1, 8 bit samples, no scaling matrices, `entropy_coding_mode_flag` 1; `rtlnet_h264_enc_write_sps_pps`
is its Constrained Baseline form). `encoder profile high` is accepted when the netlist offers a tool and the license is on. CLI: `encoder profile <baseline|high>` and the `High profile` line of `show encoder`
(not present / present, licensed or license ended, time left, tools, profile in use, forced IDR pictures).

### 17.4 Board build variants

`boards/nexys_video/scripts/build.ps1 -HighProfile none|full|demo`:

| Value | Build |
|---|---|
| `none` (default) | `HIGH_PROFILE` 0, the stand-in is not used, the flow is the Constrained Baseline image's, unchanged |
| `full` | `HIGH_PROFILE` 1 with the netlist of the unlimited-license variant, taken from `H264HighProfile\netlist\full` (or `$env:H264_HIGHPROFILE_ROOT`) |
| `demo` | `HIGH_PROFILE` 1 with the netlist of the variant whose license ends 30 minutes after FPGA configuration |

The build stops when the netlist is missing. `build_info.txt` names the variant and the netlist's `netlist_info.txt`.

### 17.6 The 8x8 transform of inter luma (stage 3, 11-12-2026)

With `hp_caps` bit 1 (the stage 3 netlist), `hp_t8_enable` (HP_CTRL bit 1) and the High profile in force, the luma residual of an inter macroblock (P_L0_16x16)
is coded by the module with the 8x8 transform: `transform_size_8x8_flag` 1 and ctxBlockCat 5 blocks, the PPS with `transform_8x8_mode_flag` 1 (the SPS stays High, 100). Chroma, Intra16x16 and I_PCM keep the 4x4
transform and their syntax. Without `hp_t8_auto` the decision is not per macroblock: every inter macroblock with luma residual uses it while it is on (17.7 describes the adaptive choice). The encoder's deblocking filter is off, so no filter edge depends on the flag.

- Ports of `rtlnet_h264_hp` (the stub and the black box carry them): inputs `hp_t8_enable` (the register bit) and `t8_sub` (the stage B descriptor: this macroblock submitted its luma residual); the reserved streams are used:
  `tf_req` (out) is high from `pic_start` to `pic_done` while the picture's inter macroblocks use the transform; `tf_res` (engine to module) carries the luma residual of the macroblock, four 8x8 blocks in raster order of the 8x8 groups, 8 beats per block,
  one row of eight signed 9-bit samples per beat; `tf_lvl` (module to engine, one beat per macroblock, valid for one clock) is the summary of the quantised levels: `[3:0]` coded 8x8 blocks, `[19:4]` the level cost sum of the size
  estimate, `[20]` a level of magnitude above one, `[21]` a level clamped at +-2047, `[25:22]` non-empty blocks; `tf_rec` (module to engine) is the rebuilt residual (quantiser, dequantiser and inverse transform of clause 8.5.13), same layout as `tf_res`,
  streamed once `tf_rec_ready` has been seen high after the summary. The levels stay in the module.
- Engine. `rtlnet_h264_mb_enc` has the parameter `T8` (= `HIGH_PROFILE`; with 0 none of it exists). Where the inter candidate wins in a picture with `tf_req`, state S_T8S sends the residual (a source row and a prediction row are read per beat), PASS1 runs the
  chroma blocks only, the summary replaces the luma terms of the coded block pattern, the size estimate, the I_PCM fallback and the isolated coefficient elimination, S_T8R takes the rebuilt residual and writes the luma words (prediction plus residual, clipped, zero residual for a
  dropped macroblock) into the rebuilt RAM, then PASS3 rebuilds the chroma blocks; S_DRN discards the stream when the macroblock falls back to I_PCM. A macroblock that submitted its residual sets `t8_sub` in its stage B descriptor.
  The clocks per macroblock of stage A grow by about 120 on smooth content with every macroblock inter and coded (381 to 502 clocks, the residual transfer of 32 beats, the wait for the summary and the luma rebuild; the luma rows leave PASS1 and PASS3 in return); the budget of 1080p30 on two engines is 735 clocks per macroblock and the P pictures of the test patterns and sequences take 502 to 575 (maximum 622 of a picture), so it holds.
- Forced IDR picture. The engine compares the applied state of the 8x8 transform (enable bit, `hp_enable`, license, `hp_caps` bit 1) with the registers at a picture start; a change forces an IDR picture like a change of the profile (17.2), and the firmware writes the parameter sets of the tools
  in force (`rtlnet_h264_enc_write_sps_pps_tools`).
- `HIGH_PROFILE` 0 is unchanged: out-of-context synthesis of two engines (90 MHz, `xc7a200tsbg484-1`) gives 47,083 LUT, 31,071 FF, 34 RAMB36, 6 RAMB18 and 76 DSP with a utilization report identical to the commit before stage 3 (8943cab), the same post-synthesis WNS (+0.881 ns) and the same entropy path; everything of the 8x8 transform in `rtlnet_h264_mb_enc` (parameter `T8`) and the stage B flag are generated only with `HIGH_PROFILE` 1. With 1 and the stage 3 netlists: 65,684 LUT, 46,677 FF, 188 DSP (full), WNS +0.881 ns (the stage A path of stage 1, unchanged), entropy path +5.085 ns at 6 logic levels.
- Driver: `rtlnet_h264_enc_set_transform8x8(base, on)` (HP_CTRL bit 1 with bit 0 kept; `on` is refused, with nothing written, by `RTLNET_H264_HP_ERR_NO_SEAM`, `_NO_MODULE` or the new `_NO_T8` (hp_caps bit 1 is 0)),
  `rtlnet_h264_enc_write_sps_pps_tools(buf, cap, cfg, high, t8, &len)` (the PPS gains `transform_8x8_mode_flag` 1, `pic_scaling_matrix_present_flag` 0 and `second_chroma_qp_index_offset` se(0) when `high` and `t8`),
  `rtlnet_h264_enc_hp_t.t8_enabled`; `rtlnet_h264_enc_set_profile` keeps bit 1. Firmware (`rtlnet_venc`): `rtlnet_venc_set_transform8x8`, the request is on by default and applied in `configure_mode`; the parameter sets are written in the form in force.
  CLI: `encoder transform8x8 <on|off>` (named refusals as for `encoder profile`) and the `Transform 8x8` line of `show encoder` (not offered / on or off, in force or not).
- Bench support: `tb_rtlnet_h264_top` has the define `TB_HP_T8` (HP_CTRL 3), the plusarg `+HPCTL=<digits>` (HP_CTRL before each picture), `TB_DUMP_MB` lines `R` (the residual beats of a macroblock that submits it) and the submission flag of the `M` line, `TB_DUMP_TOK` (the binarisation's tokens);
  `h264_gen.py --bpat P --bspeed S` writes the board's moving test patterns (`boards/nexys_video/scripts/pattern_model.py`); `h264_spspps_tool` takes `high t8`.

### 17.7 Adaptive choice of the 4x4 or the 8x8 transform per macroblock (stage 3a, 11-12-2026)

With `hp_caps` bit 2 (the stage 3a netlist), `hp_t8_auto` (HP_CTRL bit 2, written together with bit 1) and the High profile in force, the module chooses for every inter macroblock whose luma residual is coded between the 4x4 transform of this encoder and the 8x8 transform of the module, from the residual. The PPS is that of 17.6 (`transform_8x8_mode_flag` 1): a change between "on" and "auto" at a picture start forces no IDR picture and needs no new parameter sets. A macroblock that chose the 4x4 transform carries `transform_size_8x8_flag` 0 and is coded by the 4x4 path of this encoder. The rule is in the netlist (private repository, section 9.9); the engine only asks and obeys.

- Seam. No port is added to `rtlnet_h264_hp`. In an auto picture the engine starts a macroblock's submission with a request beat on `tf_res`: `tf_res_valid` with `tf_res_last` high and no residual (the data are ignored), then the 32 residual beats as before. `tf_lvl` carries the choice in bit 26 of the summary beat (1: use the 4x4 transform); the module holds the summary back until it knows the choice. A macroblock submitted without a request beat always uses the 8x8 transform (stage 3 behaviour for "on"). `t8_sub` keeps its meaning (the macroblock submitted its luma residual) and stays 1 for a macroblock that chose the 4x4 transform so that the module's banks keep in step; the module releases that macroblock's levels without reading them and produces no rebuilt residual.
- Engine (`rtlnet_h264_mb_enc`, new input `t8_auto`, new output `o_t8use`). An inter candidate that wins in an auto picture sends the request beat and the residual (S_T8S) and runs PASS1 for the chroma blocks as for "on". When the summary is in, a macroblock the module gave to the 8x8 transform continues as in 17.6 (`o_t8use` 1: S_T8R rebuilds the luma, PASS3 the chroma). A macroblock that chose the 4x4 transform runs the luma blocks of PASS1 (state S_T8L) and continues as a 4x4 macroblock (size estimate, I_PCM fallback, elimination, PASS3 over all items, `o_t8use` 0); the coded block pattern, the descriptor and the neighbour state are those of the transform used. The engine latches `hp_t8_auto` (with `hp_caps` bit 2) at the picture start and counts the macroblocks with a coded luma block per transform (inter, not skipped, not I_PCM); HP_T8_COUNT holds the numbers of the last picture, the engines added.
- Control. `rtlnet_h264_enc_set_transform8x8(base, mode)` with `RTLNET_H264_T8_OFF` (0), `_ON` (1) or `_AUTO` (2): HP_CTRL bit 1 and bit 2, bit 0 kept; refused with nothing written by `_NO_SEAM`, `_NO_MODULE`, `_NO_T8` and, for auto, `RTLNET_H264_HP_ERR_NO_AUTO` (-7, `hp_caps` bit 2 is 0: the stage 3 netlist); off is always accepted. `rtlnet_h264_enc_set_profile` keeps both bits; `rtlnet_h264_enc_t8_counts(base, &n8, &n4)` reads HP_T8_COUNT; `rtlnet_h264_enc_hp_t.t8_auto`; `RTLNET_H264_HP_CAP_ADAPTIVE`. Firmware (`rtlnet_venc`): `rtlnet_venc_set_transform8x8(mode)` (the request defaults to auto and degrades to on without `hp_caps` bit 2), `rtlnet_venc_transform8x8_counts`. CLI: `encoder transform8x8 <on|off|auto>` (named refusals as for `encoder profile`, plus the refusal text for `hp_caps` bit 2 is 0) and in `show encoder` the `Transform 8x8` line (auto, in force) and `Transform MBs : last picture 8x8 <n>, 4x4 <m>`.
- Measured effect (Verilator runs of the real engine with the netlist RTL, 720p x28 and 1080p x16 configurations of the board's test generator, QP 20 to 44, bits of the two P pictures; tables in the private repository, section 11.2). Summed over the 1080p configurations the adaptive choice is 0.09 % above the better fixed transform of each configuration (4,840 of 5.58 Mbit), 0.05 % above always-4x4 and 0.03 % above always-8x8; over the 720p configurations 0.10 % above the better fixed one, 0.30 % below always-4x4, 0.07 % above always-8x8. It does not always win: against the better fixed transform it loses on 9 of the 16 1080p configurations (by more than 1 % on four, all on pictures of 2,500 to 5,800 bits: bd2s16 q28 +32.9 % or 1,760 bits, q44 +8.2 %, objs q44 +2.4 %, objs q20 +1.4 %; the others 0.5 % or less) and on 15 of the 28 720p configurations (more than 1 % on five, the largest objs q20 +9.9 % and pan q20 and q28 +6.6 %). The gain over always-8x8 is -10.4 % (720p bd2s24 q44) at best. These are the stage 3a clock figures (the choice cost at most 43 clocks per macroblock more than always-8x8: 491 to 516 on smooth content, 381 to 400 for the 4x4 transform); stage 3c lowered them, the current figures are in 17.8 (the choice costs 5 clocks per macroblock more than always-8x8).
- `HIGH_PROFILE` 0 is unchanged: out-of-context synthesis of two engines (90 MHz, `xc7a200tsbg484-1`) of this worktree against the commit before stage 3 gives identical utilization reports (47,083 LUT, 31,071 FF, 34 RAMB36, 6 RAMB18, 76 DSP). With `HIGH_PROFILE` 1 and the stage 3a netlist, two engines: full netlist 71,465 slice LUT, 50,172 FF, 34 RAMB36, 6 RAMB18, 236 DSP, worst path +0.881 ns (the stage A path of stage 1, unchanged); demo netlist 71,509 LUT, 50,274 FF. The netlist itself is 11,865 LUT cells and 9,148 FF (`full`), 11,893 and 9,199 (`demo`), post-synthesis WNS +2.817 ns.
- Bench support: `tb_rtlnet_h264_top` has the define `TB_HP_T8AUTO` (HP_CTRL 7), the `+HPCTL` digit 7 (HP_CTRL 7 written before the picture). Tests: driver host test 652 checks, CLI demo 478 checks, the RTLNet regression 162 of 162 with the stage 3a RTL.


### 17.8 Clocks of the 8x8 path and pipeline stages for timing (stage 3c, 11-12-2026)

Stage 3c lowers the clocks that the 8x8 transform path adds in stage A and adds pipeline stages where the post-route timing of the board builds failed. Nothing changes in the streams: every stream of the stage 3a RTL (CAVLC, CABAC 4x4, 8x8, auto) is byte-identical, which the stream runs and the regression check against the reference model.

**Clocks of the 8x8 path** (`rtlnet_h264_mb_enc`, behind `T8`; the seam's port list is unchanged):

- Residual feeder, one beat per clock. A beat's source row and prediction row are read in the same clock (the prediction buffer is read by stage A only; the source buffer is shared with the motion search, so `src_lock` is raised while a row waits for the output register and the search stage does not read then). A read is issued when the data register is free or being taken, so one read is outstanding at most. The module accepts one block per 16 clocks (its forward transform has one array per pass), so the feeder is no longer the limit: S_T8S takes 70 clocks (118 before).
- Rebuild FIFO. The beats of the rebuilt residual (`tf_rec`) go into an 8 entry FIFO of 72 bits; one beat at a time leaves it: the prediction row is read in that clock, prediction plus residual is clipped into two words, written in two clocks. The write port of the rebuilt RAM is one 4-sample word wide, so 2 clocks per beat (64 clocks for the luma, as the 4x4 path's 64 luma words) is the limit of this unit. S_T8R takes 76 clocks (132 before).
- Module (private repository): the rebuild path starts at the summary and not at the engine's `tf_rec_ready`, and the inverse transform has two buffers for its row-pass result and for its column-pass result (a block per 16 clocks at the engine's pace, about 23 before).
- Not done, with the reason: the chroma PASS1 cannot run inside the module's work because both use the single source and prediction read ports and the summary comes about 50 clocks after the last beat in any case (the 32 clocks of the chroma PASS1 already fill that wait; 18 clocks remain); a speculative rebuild before the summary (the macroblock may be dropped or fall back to I_PCM) and double buffers in the forward transform would save about 12 and 45 clocks and cost about 1,900 flip-flops per module; the goal (+40 or less) was met without them.

**Clocks per macroblock** (stage A plus entropy, mean of the P pictures of the stream, engine 1, one slice; Verilator runs of the real engine, QP 28, GOP IPP, the same runs before and after; "3a" is the RTL of stage 3a, "measures" the RTL with the measures above and without the timing stages, "final" this revision; bits of every stream equal in all runs):

| size | content (QP 28, IPP) | CAVLC 4x4: 3a / 3c | CABAC 4x4 (off): 3a / measures / final | CABAC 8x8 (on): 3a / measures / final | auto: 3a / measures / final | on - off: measures / final | auto - off: measures / final | bits equal |
|---|---|---|---|---|---|---|---|---|
| 720p | pan (smooth) | 381 / 388 | 381 / 381 / 388 | 497 / 398 / 408 | 499 / 403 / 413 | +17 / +20 | +22 / +25 | yes |
| 720p | objs (smooth) | 382 / 389 | 382 / 382 / 389 | 503 / 400 / 409 | 505 / 405 / 415 | +18 / +20 | +23 / +26 | yes |
| 720p | noise band bd3 (dense) | 393 / 400 | 582 / 582 / 589 | 693 / 599 / 608 | 695 / 603 / 612 | +17 / +19 | +21 / +23 | yes |
| 720p | all bd4 (dense) | 394 / 400 | 583 / 583 / 589 | 690 / 598 / 607 | 691 / 603 / 612 | +15 / +18 | +20 / +23 | yes |
| 1080p | pan (smooth) | 381 / 388 | 381 / 381 / 388 | 500 / 399 / 409 | 502 / 404 / 414 | +18 / +21 | +23 / +26 | yes |
| 1080p | objs (smooth) | 381 / 388 | 381 / 381 / 388 | 503 / 399 / 409 | 505 / 404 / 414 | +18 / +21 | +23 / +26 | yes |
| 1080p | noise band bd3 (dense) | 389 / 396 | 514 / 514 / 521 | 629 / 531 / 540 | 631 / 536 / 546 | +17 / +19 | +22 / +25 | yes |
| 1080p | all bd4 (dense) | 389 / 396 | 514 / 514 / 521 | 624 / 531 / 540 | 626 / 535 / 544 | +17 / +19 | +21 / +23 | yes |

Reading: with the 8x8 transform in every inter macroblock the stage A overhead over the 4x4 transform fell from +107 to +122 clocks to +18 to +21 (the measures alone: +15 to +18); the adaptive mode costs 5 clocks more than always-8x8. The timing stages below cost 7 clocks per macroblock in the 4x4 path (CAVLC and CABAC alike: 381 to 388, 389 to 396 and so on) and 9 to 10 in the 8x8 path, spread over the units (`invq` 2, `dcq_chroma` 2, `ipred` input register 1, the registered prediction and write address 1, the delay stage of PASS1 1); no overlap that hides them was needed (the limit given was 10 clocks for the `invq` stage alone). The dense figures (noise band, all pattern) are bounded by the CABAC coder, not by stage A: their excess over the smooth figures is equal with the 4x4 and the 8x8 transform (section 9.10 of the private repository's `rtlnet_h264_hp.md`). A macroblock that chooses the 4x4 transform in the adaptive mode costs 507 clocks against 388 for a plain 4x4 macroblock (the module's choice arrives with the summary).

State profile (`MB_PROF`, a bench define of `rtlnet_h264_mb_enc`: clocks per state, averaged per macroblock and class, printed at the end of the simulation): QCIF pan QP 28, 8x8 macroblocks: S_T8S 118 / 70 / 72 clocks (stage 3a / measures / final), S_T8R 132 / 76 / 77, PASS1 32, S_P1W 18 / 18 / 21, PASS3 33, total 501 / 397 / 407.

**Pipeline stages for timing.** The post-route reports of the two High profile demo builds (`hp_demo_run1_altspreadlogic_high`, `hp_demo_run2_spreadlogic_high`, 90 MHz) failed on these paths; each is split so that no path of the unit exceeds about 6 to 7 logic levels:

| Unit | Path before | Change | Latency effect |
|---|---|---|---|
| `rtlnet_h264_invq` | `tt_reg` to `hs_reg`: 13 to 15 levels, 9 to 11 CARRY4 (column transform, rounding and saturation in one clock) | the column transform in three clocks: first butterfly with the rounding offset into registers, second butterfly into registers, shift and saturation into `hs` | `out_row` 0 10 clocks after `in_first` (8) |
| `rtlnet_h264_dcq_chroma` (`u_dcq_cr`, `u_dcq_cb`) | `lv_reg` to `pq_reg/A` (sum of the levels into the DSP block), `pq_reg` to `dcr_reg`, `q6_reg` to `lv_reg` | shift, clamp and sign, the 2x2 inverse transform into a register, the DSP product with registered input and output, the shift into a register, the saturation | `done` 9 clocks after `start` (7) |
| `rtlnet_h264_ipred` | `sel_p3_reg` to `q1_t_reg`: the query select, the plane multiplier (DSP block without registers) and a three input add in one clock, 9 levels | the query signals are registered at the input of the unit; `mb_enc` adds one delay stage (d3, e3) and a stage that registers the chosen prediction and the write address (e4) | prediction 3 clocks after the query (2); the writes of PASS3 one clock later |
| `rtlnet_h264_mvpred` / `_mvctx` | `avl_q_reg` to `mvp_x_reg`: 12 levels, 4 carry chains | three stage modules (`_s1` neighbour rules, `_s2` ordering and single neighbour, `_s3` median and skip), the context puts a register between them; `rtlnet_h264_mvpred` chains them, the bench is unchanged | `ready` 7 clocks after `start` (5) |
| `rtlnet_h264_top` / `_engine` | `cfg_mb_h_reg` to `me_left_reg`: the band division and the multiplier in one clock, 12 levels | the bands (`band_first`, `band_rows`) are registered in the top (the registers are written long before the start command) | none |
| private `rtlnet_h264_hp_tf8_inv`, `_tf8_fwd` | `cp_j_reg` to `u_col/e_reg`: the column select drives 160 multiplexers, 6 to 7 levels, 83 % routing | the selected column (and the selected row of the second pass) is registered before the transform unit | one clock per pass |

**Timing, out-of-context synthesis** (`h264_synth.tcl`, `xc7a200tsbg484-1`, 90 MHz, two engines; the new `*_paths.rpt` lists the worst path of every endpoint below 3 ns): `HIGH_PROFILE` 0: 46,915 LUT, 34,883 FF, 76 DSP, 34 RAMB36 + 6 RAMB18, post-synthesis WNS **+1.992 ns**, worst path `u_mb_enc/u_ipred` `pc_reg` to `q1_t_reg` (9 levels: DSP48E1 1, CARRY4 5); the paths that were worst before are gone (`cfg_mb_h` to `me_left` +0.881 ns, 12 levels; `u_mvctx` `avl_q_reg` to `mvp_x_reg` +1.315 ns, 12 levels; `u_search` `w_q_reg` to the state enable, 12 levels, after the registers of the bands and of `lim_g`). The next paths are `u_cavlc` `rem_reg` (+2.39 ns, 8 levels) and `u_search` `pc_reg` (+2.42 ns, 10 levels). **This is the new `HIGH_PROFILE` 0 baseline**: the identity with the commit before stage 3 (47,083 LUT, 31,071 FF, +0.881 ns) no longer holds because the engine itself changed (+3,812 FF for the pipeline registers, -168 LUT). `HIGH_PROFILE` 1 with the full netlist: 71,341 LUT, 58,418 FF, 236 DSP, 34 RAMB36 + 6 RAMB18, WNS **+1.881 ns** (`u_pack` `cnt_reg` to the write enable of the CABAC context RAM in the module, 11 levels; the demo netlist 71,387 LUT, 58,518 FF, the same path); the entropy path `pk_cmd_*` +5.092 ns (6 levels), the module's transform paths +4.275 ns (8 levels). The post-synthesis figures use estimated net delays; the failing paths of the board builds were dominated by routing (80 to 90 %), so the next board build confirms the stages. Paths of the board reports left to others: `u_rd_dma` `arvalid_reg` to `u_arb` `rd_pend_reg` / `rd_err_left_reg` CE (14 levels, -0.19 ns; the arbiter is `rtlnet_axi_arbiter`, not part of the encoder) and the MicroBlaze internal paths.

**Verification of the stage.** The benches of the changed units (`tb_rtlnet_h264_xform` with the latencies 10 and 9, `tb_rtlnet_h264_ipred` with the prediction three clocks after the query, `tb_rtlnet_h264_mvpred` and `tb_rtlnet_h264_search`) pass with their negative controls; the mutation of the single-neighbour rule moved to `rtlnet_h264_mvpred_s2.sv`. Streams: byte-identical to the stage 3a streams in CAVLC, CABAC 4x4, 8x8 and auto mode (40 of 40 comparisons: 9 QCIF configurations and one 720p configuration) and equal to the model (private regression 169 of 169); this repository's regression 162 of 162 on the same RTL; mutation 19 (single-neighbour rule) is caught in `rtlnet_h264_mvpred_s2.sv`.

### 17.5 Verification in this repository

The default build is covered by the existing regression, `h264_lint.ps1` and `h264_synth.tcl` (the latter with argument 4 = 1 synthesizes the
seam with the black box). The driver host test covers the new functions and both SPS / PPS forms (635 checks with the stage 3 functions) and the CLI demo of
`microblaze/firmware/build.ps1 -Demo` the CLI lines in every state of the seam (470 checks). The bench `tb_rtlnet_h264_top` has the defines `TB_HIGH_PROFILE`
and `TB_HP_ENABLE` (the module in place, `hp_enable` written) and `TB_DUMP_MB` (a text dump of stage B's input and of the clocks per macroblock, for
reference models of entropy coders); `h264_spspps_tool` takes a last argument `high`. The benches of the module and of the engine with the module in place (license expiry in the
middle of a stream, forced IDR picture, decoders) are in the High profile repository.

## 18. Interrupt (11-12-2026)

The core raises one interrupt output, `irq` (level, active high, synchronous to `enc_clk`), so that firmware starts the next picture without waiting for its
main loop to poll. The polled method works unchanged: STATUS, its flags and every other register behave as before, and the core is silent after reset.

### 18.1 Registers and sources

`irq = CTRL.IRQ_EN and (IRQ_STATUS and IRQ_ENABLE is not 0)`. `CTRL.IRQ_EN` (bit 8 of CTRL, reset 0) is the global enable; IRQ_ENABLE (reset 0) has one
enable bit per source. IRQ_STATUS holds one sticky bit per source and reads the same whether the source is enabled or not, so polled software can use it too.

| Offset | Name | Access | Meaning |
|---|---|---|---|
| 0x0D0 | IRQ_STATUS | RW | sticky event bits, write 1 to clear (a written 0 changes nothing); bits [7:6] reserved, read 0 |
| 0x0D4 | IRQ_ENABLE | RW | one enable bit per source (reset 0); bits of sources the build lacks read 0 |
| 0x0D8 | IRQ_FORCE | WO | a written 1 sets the status bit (software self-test of the interrupt path, bench); reads 0; bits of sources the build lacks are ignored |

| Bit | Source | Event (one clock) |
|---|---|---|
| 0 | PIC_DONE | the picture is complete (every engine done): the `done` pulse that also sets STATUS.DONE and increments PIC_COUNT |
| 1 | ERR | an error pulse (`err_cfg`, `err_axi`, `err_rptr`, `err_busy`): the event that sets STATUS.ERR |
| 2 | RING_STALL | rising edge of the ring-full stall of any engine (one event per stall, not one per clock) |
| 3 | PROFILE_CHG | a picture start applied a changed license or enable and forced an IDR picture (`hp_chg`, the event that sets HP_STATUS.PROFILE_CHG); HIGH_PROFILE builds, else 0 |
| 4 | LICENSE_LOST | `hp_licensed` fell (the demo time ended); HIGH_PROFILE builds, else 0 |
| 5 | PIC_START | a start accepted while idle (`start` and not `busy`); a start while busy is the ERR source (ERR_CODE 4) instead |

CAPS bit 21 reads 1 when these registers exist and CAPS [31:24] is the mask of the implemented sources (0x3F with `HIGH_PROFILE = 1`, 0x27 with 0).
VERSION is 0x11122C03; software detects the capability from CAPS bit 21 together with that VERSION (the driver does, `caps.irq`) and keeps the polled method
on a core that reads 0x11102C02.

Clear rules. An event sets its bit; a write of 1 clears it. An event in the same clock as a clear of its bit keeps the bit set (the event wins, so no event is
lost between the read and the acknowledge). IRQ_FORCE and a clear of the same bit cannot meet (one register write per clock). The legacy flags of STATUS
(DONE, ERR, with ERR_CODE) are separate from IRQ_STATUS: clearing one does not clear the other, and STATUS.DONE and STATUS.ERR keep their own rule (an event in
the clock of the clear keeps the flag).

### 18.2 Timing

An event that is high in clock n sets its IRQ_STATUS bit, which reads 1 from clock n + 1; `irq` is the combinational AND-OR of the registered bits `CTRL.IRQ_EN`, IRQ_STATUS and
IRQ_ENABLE, so it rises in clock n + 1 when the source and the global enable are on, one clock after the event. A register write strobe in clock m (a clear of IRQ_STATUS, a
write of IRQ_ENABLE or of CTRL) takes effect from clock m + 1, and `irq` falls in that clock when no enabled bit is left. `irq` is a level: it stays high while any enabled bit
is pending, whatever the number of events behind it. It is a registered-state function of 8 + 8 + 1 flip-flops, in the same clock domain as the register file, so there is no clock-domain
crossing and no extra pipeline stage.

### 18.3 Software sequences

Interrupt mode (the driver does this):
1. Probe: CAPS bit 21 and VERSION 0x11122C03. Acknowledge IRQ_STATUS (write 0xFF), write IRQ_ENABLE (PIC_DONE, ERR, RING_STALL, PROFILE_CHG, LICENSE_LOST; PIC_START
   stays off), set `CTRL.IRQ_EN`, unmask the interrupt controller input.
2. In the handler: read IRQ_STATUS; write the bits read back (acknowledge; an event that arrived in between stays set and interrupts again); then act on
   them: on PIC_DONE read the index entries and the QP, clear STATUS.DONE, collect the picture, start the next picture; on ERR read ERR_CODE and clear STATUS.ERR.
   ERR wins when both are set.
3. A picture start writes the configuration, PIC_CFG, FRAME_NUM, IDR_PIC_ID and then CTRL with START and `IRQ_EN` kept (read-modify-write of CTRL in the start
   functions of the driver).

Polled mode: leave `CTRL.IRQ_EN` and IRQ_ENABLE at 0 (the reset state). Poll STATUS for DONE or ERR as before (`rtlnet_h264_enc_wait_done`,
`rtlnet_h264_ctl_poll`); IRQ_STATUS still collects the events and can be read, with nothing enabled the output stays low. Switching modes is done while no picture
is in flight: acknowledge IRQ_STATUS, then write IRQ_ENABLE and `CTRL.IRQ_EN`.

### 18.4 Driver

Low level, `driver/rtlnet_h264_enc.{h,c}`: `probe` (`caps.irq`, `caps.irq_sources`, `caps.version`; VERSION 0x11102C02 still probes), `irq_capable`, `irq_set_enable`,
`irq_get_enable`, `irq_global`, `irq_status`, `irq_ack`, `irq_force`; the three start functions and `ring_reset` keep `CTRL.IRQ_EN`.

Control layer, `driver/rtlnet_h264_enc_ctl.{h,c}`, the only interface firmware uses (it includes no register definition): `init` stores the base address, the memory
layout and the callbacks, `open` probes and applies the notification mode, `set_notify` selects `RTLNET_H264_NOTIFY_INTERRUPT` (the default) or
`RTLNET_H264_NOTIFY_POLLED` and returns the mode in force (the interrupt mode degrades to polled on a core without the registers, without an error),
`set_mode` / `start_picture` (the start sequence in one call: configuration with the picture's QP and input, buffer bases, START), `release` (read pointers),
the High profile controls and the console view (`debug`). A completed picture reaches the application through two callbacks, whichever mode is in force:
`picture_done` receives `rtlnet_h264_ctl_picture_t` (validity, per engine the ring offset, length, the read-pointer targets, the sum of the sizes, the QP written, the
requested type, whether the encoder coded a forced IDR picture instead, the delimiter bytes) and `picture_error` the ERR_CODE. `read_mem` is the application's way to
read DDR3 (index records, the delimiter) with the cache lines invalidated; the driver has no dependency on the cache, lwIP, the multiplexer or the console.

* `rtlnet_h264_ctl_irq_service()` is the handler body: it reads and acknowledges IRQ_STATUS, counts the events per source, and dispatches (error first, then
  picture done; profile change sets the forced-IDR note, ring stall and license lost are counted for the main loop, `take_events` reports them). It does nothing
  when the interrupt mode is not in force. Its cost on a picture done is the IRQ_STATUS read and acknowledge, the STATUS clear, one index-pointer read per engine and the index records between two pictures: all bounded, no
  waiting. Counted on the host model of the core, a handler run that does only this (and the firmware's slot release, queue and rate control) makes 9 register accesses; a run that also starts the next picture
  (configuration, QP read, buffer bases, START) makes 47 on average and 50 at most.
* `rtlnet_h264_ctl_poll()` is the polled counterpart: it reads STATUS and on DONE or ERR runs the same turnaround and callbacks. It returns -1 while the interrupt
  mode is in force.
* Calling contexts: `irq_service` from the interrupt handler only; `poll` from the main loop in polled mode; `start_picture` and `set_mode` from the one context that
  owns the idle encoder (the handler at picture done, or the main loop while no picture is in flight); `release`, `irq_stats` and `take_events` from the main loop at
  any time (single-writer counters, no read-modify-write of shared state). The driver masks no interrupts itself.

### 18.5 Verification and results

**Register file bench** `testbench/tb_rtlnet_h264_regs.sv` (Active-HDL; the register file with the events driven directly; `HIGH_PROFILE` 0 and 1 by the define `TB_HP`; regression entries
`base`, `hp`, and `neg`, `hp_neg` with `+INJECT_FAILURE`). It checks: the reset state (silent, VERSION, CAPS bit 21 and the source mask); each source sets exactly its own bit; a masked source sets
the status bit and not `irq`; the global enable; write-1-to-clear; an event in the clock of its clear keeps the bit (picture done, error, ring stall edge); IRQ_FORCE sets implemented bits
only; `irq` is a level that falls only when no enabled bit is pending; the ring stall is an edge source (one event per stall); `hp_licensed` falling (a rising edge is no event);
a start while busy is no PIC_START event; the polled STATUS behaviour (DONE, ERR, ERR_CODE, BUSY, RING_STALL, the CTRL readback, an event in the clock of a STATUS clear) and its independence from
IRQ_STATUS. Result: PASS with 84 checks (`HIGH_PROFILE` 0) and 86 checks (1); the `+INJECT_FAILURE` runs fail as required. Ten mutated copies of the register file are negative controls and
every one fails the bench: the clear wins over a same-clock event (`m1`), `irq` ignores IRQ_ENABLE (`m2`), `irq` ignores the global enable (`m3`), a write of 1 does not clear (`m4`), IRQ_FORCE sets reserved
bits (`m5`), the ring stall counts every clock (`m6`), a start while busy is an event (`m7`), a clear of IRQ_STATUS also clears STATUS.DONE (`m8`), `hp_licensed` rising is an event (`m9`, `HIGH_PROFILE` 1),
IRQ_ENABLE keeps reserved bits (`m10`).

**Encoder bench** `tb_rtlnet_h264_top` (Verilator, decoder harness): the bench checks CAPS bit 21, the source mask, VERSION and the reset state of the interrupt registers; in the polled flow `irq` stays low through
every picture, IRQ_STATUS.PIC_DONE is set and readable at DONE and cleared by a write of 1, and STATUS.DONE stays independent; with `h264_harness.ps1 -Irq` the bench enables PIC_DONE and ERR and
`CTRL.IRQ_EN`, waits for the `irq` output, reads IRQ_STATUS, acknowledges it and checks that the level falls. Stream check at QCIF (`qcif_s1`, `qcif_e2_s4`, `p_qcif_pan_q28`, `p_qcif_pan_e2_s2_q28`): the stream
(`o_stream.hex`) and the rebuilt picture are byte-identical between the RTL before this change (commit d2b521f), the new RTL in the polled flow and the new RTL in the interrupt flow; JM, OpenH264 and FFmpeg decode
all twelve runs identical to the rebuilt picture. The interrupt flow is `h264_harness_irq` in `testbench/regression.txt`.

**Driver tests** (`testbench/h264_driver_test.ps1`, host gcc): the register driver `test_rtlnet_h264_enc_driver.c` 674 checks (the interrupt functions, VERSION 0x11102C02 probing with `caps.irq` 0, the refusals on a core without the
registers, the start functions keeping `CTRL.IRQ_EN`); the control layer `test_rtlnet_h264_enc_ctl.c` 85 checks against a functional core model (both modes give the same result for the same picture, the acknowledge, per-source counts, error
over done, an invalid entry, forced IDR with the rewritten parameter sets, buffer alternation, `release`, the switch between modes, the older core) with its negative control (`-DINJECT_FAILURE` must report `CTL TEST FAIL`); the rate
controller `test_rtlnet_ratectl.c` 15 gates.

**Firmware host tests** (`microblaze/firmware/test/venc_irq_host_test.ps1`, the session `rtlnet_venc.c` against the harness models, both modes): 181 checks; the demo `build.ps1 -Demo` 486 checks. The two modes send byte-identical datagrams
for a constant QP, rate control, a profile change with a forced IDR picture, an encoder error and a switch of the mode in mid-stream; a core without the interrupt registers degrades to polled and no interrupt register is touched; in the
pipelined runs the model completes a picture between any two register accesses of the firmware, every frame is a sent or a dropped picture, and the transport stream is demultiplexed and every access unit is compared with the picture the model wrote (bytes
and PTS).

**Out-of-context synthesis** (`h264_synth.tcl`, `xc7a200tsbg484-1`, `enc_clk` 90 MHz, 2 engines, `HIGH_PROFILE` 0): see section 18.6.

### 18.6 Out-of-context synthesis (11-12-2026)

`h264_synth.tcl`, `xc7a200tsbg484-1`, `enc_clk` 11.111 ns (90 MHz), `NUM_ENGINES` 2, post-synthesis estimate (no placement), Vivado 2026.1; 0 critical warnings, PASS.

| Build | LUT | FF | RAMB36 | RAMB18 | DSP | WNS |
|---|---|---|---|---|---|---|
| before the interrupt registers, `HIGH_PROFILE` 0 | 47 083 | 31 071 | 34 | 6 | 76 | +0.881 ns |
| with the interrupt registers, `HIGH_PROFILE` 0 | 47 084 | 31 080 | 34 | 6 | 76 | +0.881 ns |
| with the interrupt registers, `HIGH_PROFILE` 1 (black-boxed module) | 49 268 | 31 891 | 34 | 6 | 76 | +0.881 ns |

The interrupt controller costs 1 LUT and 9 flip-flops (`IRQ_STATUS` and `IRQ_ENABLE` of the 4 sources of the baseline build, the ring stall edge register, the read-mux terms and CAPS bits, with the
unused status bits trimmed); no RAM or DSP. The worst path is unchanged (`u_regs/cfg_mb_h_reg[5]` to the `me_left` register of engine 1, +0.881 ns). The `HIGH_PROFILE` 1 run has no earlier figure in this document for the
same tool version; it is listed for the record.
