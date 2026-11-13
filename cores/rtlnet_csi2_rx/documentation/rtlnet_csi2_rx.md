# rtlnet_csi2_rx — CSI-2 capture core, Phase 1: color bars and source switch

| Item | Value |
|---|---|
| Core | `rtlnet_csi2_rx` |
| Document revision | 11-10-2026 |
| Language | SystemVerilog-2012 (RTL, benches), C11 (driver, C model) |
| Position | video source of the camera design |
| Register map revision | `VERSION` = `0x11102026`, `ID` = `0x43534932` ("CSI2") |
| Phase | Phase 1 and the Phase 2d moving patterns: register block, test-pattern generator (static bars, scrolling bars, moving box, noise band), source switch. The camera front end (D-PHY capture, CSI-2 decode, SCCB, lane calibration) is Phase 3 and joins through the camera stream port |
| Verification | Active-HDL 11.1: `tb_rtlnet_csi2_rx` (3 configurations + the full-size pattern run + negative control), `tb_rtlnet_csi2_rx_pattern` (816 frames on reduced geometry, with and without backpressure + negative control), `tb_rtlnet_video_path` (with the C model CRC), host driver test, C model self test, C model against the numpy model (`pattern_model.py`) byte for byte, pattern PSNR path of `stream_check.py`; results in section 8 |
| Synthesis | Phase 1 (static bars only), Vivado 2026.1 out of context, xc7a200tsbg484-1: PASS, 0 critical warnings; 406 LUT, 700 FF, 0 BRAM. The moving patterns are not yet synthesized; section 7 gives the estimate |

The core sends one YUV422 video stream to `rtlnet_vdma_s2mm`. Today the stream is the test-pattern generator: eight static
75 % bars at 720p30 (register reset default) or 1080p30, or, with the `PATTERN` register, bars scrolling sideways, a textured
box bouncing over the bars and a band of noise, so the frame buffer, the encoder and the streaming path run with no
camera and with content that gives rate control something to control. The camera front end (Phase 3) adds a second source behind the same switch; the camera stream port exists and the board
ties it off (valid 0).

Contents: 1 interface, 2 frame timing, 3 pattern, 4 source switch, 5 registers, 6 clocks and crossings, 7 resources,
8 verification, 9 integration, 10 limitations.

---

## 1. Interface

### 1.1 Ports

| Group | Ports | Domain | Rule |
|---|---|---|---|
| clock, reset | `clk`, `resetn`, `s_axi_aclk`, `s_axi_aresetn` | `clk` (`ui_clk`, 90 MHz), `s_axi_aclk` (`cpu_clk`) | synchronous, active low; both resets release from one assertion |
| camera stream in | `s_cam_tdata[31:0]`, `s_cam_tvalid`, `s_cam_tlast`, `s_cam_tuser`; out `s_cam_tready`; `cam_clk_running` | `clk` | Phase 3: after the byte-clock FIFO. Same word format as the output. `cam_clk_running` is already synchronized. Tied off in the board |
| video stream out | `m_axis_tdata[31:0]`, `m_axis_tvalid`, `m_axis_tlast`, `m_axis_tuser`; in `m_axis_tready` | `clk` | AXI4-Stream; one word per transfer; `tuser` = first word of a frame, `tlast` = last word of a line |
| frame sideband | `m_frame_num[31:0]`, `m_timestamp[31:0]`, `m_width[15:0]`, `m_height[15:0]`, `m_src_pattern` | `clk` | registered with the stream; stable from the clock the first word of a frame enters the output register until the next first word |
| registers | `s_axi_aw*`, `s_axi_w*`, `s_axi_b*`, `s_axi_ar*`, `s_axi_r*` (AXI4-Lite, 12-bit address, 32-bit data) | `s_axi_aclk` | 4 KiB window, crossing in section 6 |

Stream word: two YUV422 pixels, memory byte order `{Cr, Y1, Cb, Y0}` (Y0 in `tdata[7:0]`). Written little-endian into DDR3
the bytes read Y0 Cb Y1 Cr (YUYV). A frame is H lines of W/2 words: 640 words and 720 lines at 720p30, 960 words and 1080
lines at 1080p30.

Sideband: `m_frame_num` is `FRAME_COUNT` after the frame started (the first frame is 1), `m_timestamp` the free-running
`clk` count at the first word, `m_width` and `m_height` in pixels of the mode in effect for the frame, `m_src_pattern`
1 for the pattern and 0 for the camera.

### 1.2 Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `PERIOD_RESET` | 3,000,000 | `FRAME_PERIOD` reset value (30.000 fps at 90 MHz) |
| `PERIOD_MIN_720` | 3,000,000 | minimum `FRAME_PERIOD` at 720p30 (750 lines x 4,000) |
| `PERIOD_MIN_1080` | 2,999,250 | minimum `FRAME_PERIOD` at 1080p30 (1,125 lines x 2,666) |
| `LINE_PERIOD_720`, `LINE_PERIOD_1080` | 4,000, 2,666 | `clk` cycles from line start to line start |
| `CAM_TIMEOUT_RESET` | 2 | `CAM_TIMEOUT` reset value |

The defaults are the values of `driver/rtlnet_csi2_rx.h`. The benches shorten the line periods for speed and run one
configuration with the real values.

---

## 2. Frame timing

A free-running frame timer ticks every `FRAME_PERIOD` clocks; the value in force is the one latched at the previous tick,
so a change takes effect at the next frame. On a tick with the pattern selected and no frame in progress the generator
starts one frame in the mode `VIDEO_MODE` holds at that tick. Lines are spaced like a sensor's: line n starts n x line
period after the frame start (active lines only; the blank lines of the 750 / 1,125 line frame are idle time at the end), so
the DDR3 load and burst pattern match the camera in the same mode.

| Mode | Active / total lines | Line period (clocks) | Words per line | Minimum `FRAME_PERIOD` |
|---|---|---|---|---|
| 720p30 | 720 / 750 | 4,000 | 640 | 3,000,000 |
| 1080p30 | 1,080 / 1,125 | 2,666 | 960 | 2,999,250 |

A line runs at one word per clock while `m_axis_tready` is high; a line that overruns its slot starts the next line at
once. A tick that finds the previous frame still running starts nothing and sets the sticky `STATUS.OVERRUN`. A longer
`FRAME_PERIOD` lowers the rate (6,666,666 gives 15 fps).

---

## 3. Pattern

The generator sends one frame per frame tick in the mode of `VIDEO_MODE` (W x H = 1280 x 720 or 1920 x 1080) with the pattern
of `PATTERN`. Every frame is a pure function of (mode, pattern, speed, k): `pattern` and `speed` are the `PATTERN` fields latched
at the frame start, and `k` is the pattern frame counter. `k` is 0 for the first frame after a `PATTERN` write (accepted) or a
`VIDEO_MODE` write that changes the mode, and one more for each frame after that; `PATTERN_FRAME` reads the number of frames
started since, that is the `k` of the next frame. Pixel x runs 0 to W - 1 from the left, line y 0 to H - 1 from the top.

| `pattern` | Content |
|---:|---|
| 0 | static bars (reset default) |
| 1 | the bars scroll right |
| 2 | a moving box over the static bars |
| 3 | static bars with a noise band |
| 4 | scrolling bars, the noise band, and the box on top |

Three layers, the upper one covers the lower: box over noise over bars. A pattern that does not use a layer leaves it out
(pattern 0 only the bars, pattern 2 bars and box, pattern 3 bars and noise).

**Pixel pairs.** The stream carries two pixels per word, `{Cr, Y1, Cb, Y0}`; Cb and Cr belong to the pair. Every layer
gives each pixel its own luma; the chroma of a pair is the chroma of the layer at the pair's first (even) pixel.

### 3.1 Bars

Eight vertical 75 % bars, bw = W / 8 pixels wide (160 at 720p, 240 at 1080p, 10 and 15 macroblocks, so each edge of the
static bars is on a macroblock boundary). ITU-R BT.709 8-bit limited-range values:

| Bar | Y | Cb | Cr |
|---|---|---|---|
| 0 white 75 % | 180 | 128 | 128 |
| 1 yellow | 168 | 44 | 136 |
| 2 cyan | 145 | 147 | 44 |
| 3 green | 133 | 63 | 52 |
| 4 magenta | 63 | 193 | 204 |
| 5 red | 51 | 109 | 212 |
| 6 blue | 28 | 212 | 120 |
| 7 black | 16 | 128 | 128 |

Pixel x shows the bar of s(x) = (x - off) mod W, bar index s(x) div bw, where off = 0 for the patterns 0, 2, 3 and
off = (speed x k) mod W (a non-negative remainder) for the patterns 1 and 4. The picture moves right by `speed` pixels per
frame (left for a negative speed), wrapping at the frame edge; every line is identical. With an odd offset a pair can
straddle a bar edge: Y0 is the luma of the bar at s(2p), Y1 the luma of the bar at s(2p + 1), Cb and Cr those of the bar at s(2p).

### 3.2 Box

A 64 x 64 box with top-left corner (bx, by) and a texture computed from its local coordinates cx = x - bx, cy = y - by
(0 to 63), so it needs no memory:

    Y(cx, cy) = (((cx >> 3) xor (cy >> 3)) and 1 ? 192 : 64) + ((cx + 5 cy) >> 4)       (an 8 x 8 checkerboard of the levels 64 and 192, and a ramp of 0 to 23)
    Cb = 90, Cr = 190                                                                   (fixed color)

The ramp runs along a diagonal that is not a multiple of the checkerboard period, so a block inside the box has exactly one
shift (the true one) with zero sum of absolute differences within the encoder's +-16 pixel search range (checked for the
speeds +-1, 4, 12, 16, 24, 32 on 16 x 16 blocks). The box moves by (speed, speed div 2) pixels per frame, `div` rounding
toward minus infinity (speed -7 moves the box 4 lines up), and bounces at the frame edges as a triangle wave in closed form:

    tri(t, R) = u if u <= R else 2R - u,  u = t mod 2R (non-negative)
    bx = tri(192 + speed x k, W - 64),   by = tri(96 + (speed div 2) x k, H - 64)

so the box starts at (192, 96) at k = 0 and the position is a function of k alone. A pixel is in the box when bx <= x < bx + 64
and by <= y < by + 64; the pair takes the box chroma when its first pixel is in the box, and each pixel in the box takes the
texture luma, so a box at an odd x has pairs that mix box and background luma.

### 3.3 Noise band

64 rows, macroblock aligned, from row B0 = ((H / 2 - 32) div 16) x 16 (320 to 383 at 720p, 496 to 559 at 1080p), full width.
The words of the band in raster order (line by line, W / 2 words per line, over the frame) are the successive states of a
32-bit maximal LFSR, one state per output word:

    n(0) = seed,  n(j + 1) = step(n(j)),  step = 32 shifts of  s <- {s[30:0], s[31] xor s[21] xor s[1] xor s[0]}   (x^32 + x^22 + x^2 + x + 1)
    seed = (0xACE10000 xor (k x 0x9E3779B9 mod 2^32)) or 1                                          (never 0)
    word = n(j) = {Cr, Y1, Cb, Y0}: Y0 = n[7:0], Cb = n[15:8], Y1 = n[23:16], Cr = n[31:24]

Both pixels of a word are noise. The seed changes every frame, so the noise is new every frame; outside the band the layers below show. Noise does not compress: the band makes the coded bit rate of the picture rise to a steady
level (about 64 / 720 of the frame at full entropy).

### 3.4 Hardware

The generator runs in the one system clock (`ui_clk`). It has no RAM and no multiplier. Three running registers (the scroll
start position as bar and pixel in the bar, and the two phases of the box triangle waves), a 32-bit register holding k x 0x9E3779B9
and the box position of the next frame are updated by a five-phase sequencer in the clocks after each frame start, by one add
per frame and one conditional wrap (the speed is at most 32 pixels, the wrap at most one period), so `speed x k` never appears.
A `PATTERN` write or a `VIDEO_MODE` change resets them to the values of k = 0 (a frame started in the same clock is k = 0).
The word datapath is a three-stage pipeline behind the position counters (flags and the box column and row, bar colors and
texture ramp, layer mux) on one enable (the output register is free or `m_axis_tready`), at most two LUT levels per stage
except the noise register (an XOR of up to 22 state bits, two levels, and the load or hold). The line timing (4,000 and
2,666 clocks per line) is that of Phase 1; the pipeline only delays the first word by a constant number of clocks.

### 3.5 Models

The frame bytes are those of `testbench/csi2_bars_model.c` (host gcc, the reference; `--frame <mode> <pattern> <speed> <k>` prints the
CRC-32 and `--dump-frame` writes the bytes), which prints the CRC-32 (IEEE 802.3, zlib `crc32`) of the packed frame as it lands in
DDR3: static bars 720p30 1,843,200 bytes `0x6D3DF810`, 1080p30 4,147,200 bytes `0x8ED9EC2B`. `boards/nexys_video/scripts/pattern_model.py`
(numpy) produces the same frames as YUYV arrays and as 4:2:0 planes (the encoder's rule: the 4:2:2 chroma of a line pair averaged as
(a + b + 1) >> 1); `stream_check.py psnr --pattern N --speed S` compares decoded pictures with it, finding k per picture in
k_prev + 1 .. k_prev + 4 so that a dropped picture resyncs.

---

## 4. Source switch

`SOURCE` selects auto (reset), camera only or pattern only. In auto the camera is used when `cam_clk_running` is high and a
camera frame start arrived within `CAM_TIMEOUT` frame ticks; otherwise the pattern. The selection changes only between
frames, with one exception: a camera frame in progress when the camera is no longer selected (stopped mid-frame, or the
source set to pattern) is abandoned at once; its output closes without the missing lines, the next frame (pattern) starts
with its own first word, and `rtlnet_vdma_s2mm` pads the short frame and never publishes it. While the pattern is selected the
camera stream is accepted and discarded; a camera word that is not part of a frame that began with a first word is discarded.
With `SOURCE` 1 and no camera no frame is sent and `FRAME_COUNT` stands still. `STATUS.PATTERN` reports the selected source,
the frame sideband carries the source of each frame, and no frame mixes sources.

---

## 5. Registers

12-bit address; offsets are defined in `driver/rtlnet_csi2_rx.h` and mirrored in `hdl/rtlnet_csi2_rx_regs.sv`. Writes are
full-word only. A write the core rejects leaves the register unchanged and sets a sticky flag; nothing is clamped.
Undefined offsets read 0 and ignore writes.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | 0x43534932 | "CSI2" |
| 0x004 | `VERSION` | RO | 0x11102026 | register map date code (0x11092026 was Phase 1 without `PATTERN`) |
| 0x008 | `CAPS` | RO | 0x52 | `[3:0]` number of video modes (2), `[4]` test-pattern generator, `[5]` camera front end (0), `[6]` moving patterns |
| 0x010 | `VIDEO_MODE` | RW | 0 | `[1:0]` 0 = 720p30, 1 = 1080p30; a value above 1 sets `STATUS.MODE_ERR`; a mode whose minimum period exceeds the present `FRAME_PERIOD` sets `STATUS.PERIOD_ERR`; both leave the register unchanged; effective at the next frame start |
| 0x014 | `SOURCE` | RW | 0 | `[1:0]` 0 = auto, 1 = camera only, 2 = pattern only; 3 and above set `STATUS.SOURCE_ERR` and change nothing |
| 0x018 | `FRAME_PERIOD` | RW | 3,000,000 | `clk` cycles per frame; below the minimum of the selected mode sets `STATUS.PERIOD_ERR` and changes nothing |
| 0x01C | `CAM_TIMEOUT` | RW | 2 | frame periods without a camera frame before auto uses the pattern (0 = auto never uses the camera) |
| 0x020 | `STATUS` | RO, flags W1C | 1 | `[0]` selected source (0 camera, 1 pattern), `[1]` camera byte clock running, `[2]` `MODE_ERR`, `[3]` `PERIOD_ERR`, `[4]` `SOURCE_ERR`, `[5]` `OVERRUN`, `[6]` `PATTERN_ERR` (flags sticky, write 1 to clear; a new error in the clock of a clear keeps it set) |
| 0x024 | `FRAME_COUNT` | RO | 0 | frames sent, both sources, counted at the first word of a frame |
| 0x028 | `ACTIVE` | RO | 0 | `[1:0]` mode of the frame in progress or the last frame |
| 0x030 | `PATTERN` | RW | 0x0000_0400 | `[2:0]` pattern: 0 static bars, 1 scrolling bars, 2 moving box over the bars, 3 bars with a noise band, 4 all three; `[15:8]` signed speed in pixels per frame of the scroll and the box, reset 4, allowed -32 to +32 (0x00..0x20, 0xE0..0xFF); a pattern of 5 to 7, a speed beyond +-32 or any other bit set sets `STATUS.PATTERN_ERR` and leaves the register unchanged; effective at the next frame start, which is `k` = 0 |
| 0x034 | `PATTERN_FRAME` | RO | 0 | pattern frames started since the last accepted `PATTERN` write or `VIDEO_MODE` change (reads 0 right after it; the `k` of the next frame) |

Because the mode write checks the period and the period write checks the mode, `FRAME_PERIOD` is never below the minimum of
`VIDEO_MODE`. A `PATTERN` write in mid-frame leaves that frame as it is; the next frame starts with the new pattern at `k` = 0.
Both a `PATTERN` write and a `VIDEO_MODE` write that changes the mode restart `k`, because one set of running registers serves both
modes (a `VIDEO_MODE` write of the present value does not). Driver: `rtlnet_csi2_rx_probe`, `_read_state` (also the pattern, the
signed speed and `PATTERN_FRAME`), `_set_mode`, `_set_source`, `_set_frame_period`, `_set_rate_fps` (period = 100,000,000 / fps,
fps 1..30), `_set_pattern(base, pattern, speed)` with `RTLNET_CSI2_PATTERN_BARS` 0, `_SCROLL` 1, `_BOX` 2, `_NOISE` 3, `_ALL` 4,
`_mode_width`, `_mode_height`; a rejected write clears its flag and returns `RTLNET_CSI2_ERR_REJECTED` (`_set_pattern` writes
every value that fits the fields, so pattern 5 to 255 and speed beyond +-32 return `ERR_REJECTED` from the core's rejection; a pattern
above 255 or a speed outside -128..127 cannot be encoded and return `ERR_ARG` without a write).

---

## 6. Clocks and crossings

All logic is in `clk` (`ui_clk`): generator, switch, output register and register file. The register window is on
`s_axi_aclk` (`cpu_clk`) behind `rtlnet_axil_cdc` (whole-transaction toggle crossing, constrained by
`scripts/rtlnet_constrain_cdc.tcl`) and `rtlnet_axil_slave`, the pattern of `rtlnet_axi_arbiter`. The core adds one
`rtlnet_axil_cdc` instance to a build (CDC gate: `axil_cdc` +1 per video core). The camera stream and `cam_clk_running` are
inputs already in `clk`; the byte-clock crossing belongs to the Phase 3 front end.

---

## 7. Resources

Phase 1 (static bars), Vivado 2026.1, out-of-context synthesis, xc7a200tsbg484-1 (`scripts/rtlnet_synth_check.tcl`,
`.sim/synth/rtlnet_csi2_rx.log`), defaults:

| Resource | Used |
|---|---|
| Slice LUT | 406 (0.30 %) |
| Slice register | 700 (0.26 %) |
| Block RAM | 0 |

The register crossing is part of these numbers. The moving patterns are not synthesized yet (no Vivado run in this change); the
estimate from the register and operator count of `rtlnet_csi2_rx_pattern.sv` and `_regs.sv`:

| Part | Flip-flops | LUTs |
|---|---:|---:|
| position counters, line timer, frame sequencer (state, line, word, bar, box column, row and band flags) | 107 incl. noise register | 280 |
| frame stepping (running scroll, box phases, seed multiple, `k`, sums and flags, five phases) | 173 | 260 |
| frame configuration latched at the start | 34 | 40 |
| word pipeline (flags, bar colors, texture ramps) | 87 | 80 |
| layer mux and output register | 35 | 35 |
| 32-step LFSR (XOR trees, 4 to 22 inputs per bit, two levels) | in the noise register | 108 |
| `PATTERN`, `PATTERN_ERR`, read mux | 12 | 15 |
| Phase 1 generator (about 50 FF, 100 LUT) replaced | -50 | -100 |
| Total change | about +385 | about +720 |

Estimated core: about 1,130 LUT (0.84 %) and 1,085 FF (0.41 %), 0 block RAM, no DSP. The critical path of the Phase 1 core is in the
output stage and the camera mux, unchanged; the new logic is at most two LUT levels per stage except the register of the noise word
(about three). Synthesis of the changed core is the first check of the board build (WNS +0.070 ns before this change).

---

## 8. Verification

`tb_rtlnet_csi2_rx` (`testbench/regression.txt`, tags `fast`, `fast_gap`, `real`, `patfull`, `neg`) drives the register window through
`rtlnet_tb_axil_master` on a 9.7 ns clock against the 10 ns core clock, with a camera stream model and an output monitor
that checks every word against a reference written in the bench.

| Group | Proves |
|---|---|
| reset values | ID, VERSION, CAPS, `VIDEO_MODE` 0, `SOURCE` 0, `FRAME_PERIOD`, `CAM_TIMEOUT` 2, `STATUS` pattern bit only |
| pattern | every word of every frame at 720p30 and 1080p30 equals the reference (eight bars, 160 / 240 pixels, BT.709 values, `{Cr, Y1, Cb, Y0}`), first-word flag on the first word only, end-of-line on the last word of each of H lines, W/2 words per line, frame numbers 1, 2, 3 ... |
| sideband | width, height, frame number, timestamp and source flag stable over each frame |
| timing (`real`) | frame start to frame start equals `FRAME_PERIOD` (3,000,000 and 2,999,250); line start to line start equals 4,444 and 2,962 |
| rejection | a period below the minimum of each mode is rejected, the minimum is accepted, `PERIOD_ERR` clears by write 1; a mode write above the present period is rejected; mode 2 and 0x10000 set `MODE_ERR`; source 3 sets `SOURCE_ERR`; registers unchanged by a rejected write |
| mode change | a write in mid-frame leaves the frame in progress in its old geometry (the next frame starts in the new mode), `ACTIVE` follows |
| source switch (`fast` and `fast_gap`) | auto with the camera byte clock off sends the pattern and drains the camera stream; with the clock running and camera frames arriving auto switches to the camera between frames; the camera stopping mid-frame closes that frame short and auto returns to the pattern; `SOURCE` 2 keeps the pattern against a running camera; `SOURCE` 1 with no camera sends no frame and `FRAME_COUNT` stands still; `SOURCE` 1 with camera frames passes them; stray camera words are discarded; no frame mixes sources |
| backpressure (`fast_gap`) | random output ready: no word lost or repeated |
| `PATTERN` registers (every run) | reset 0x400, `PATTERN_FRAME` 0, CAPS 0x52, VERSION 0x11102026; eight accepted values (patterns 0 to 4, speeds -32, -1, 0, +1, +24, +32 and others) read back; fourteen rejected values (pattern 5, 6, 7, a bit in [7:3], speed 33, -33, -128, 127, a bit in [31:16], all ones) each set `PATTERN_ERR` and leave the register and the other flags alone; the flag is sticky (other clears and a valid write leave it), clears by write 1 |
| moving patterns, full size (every run, 720p30) | `PATTERN` 4, speed -7, written in mid-frame: the next two frames equal the C model CRC-32 for k = 0 and 1, `PATTERN_FRAME` reads 0 after the write and 2 in the second frame; writing the bars back in mid-frame leaves that frame as it was and the following frames pass the word check again |
| moving patterns, full size (`patfull`) | 22 combinations (patterns 0 to 4, both modes, speeds +4, -7, +24 where speed matters) of four consecutive frames k = 0..3 = 88 frames, each write in the last frame of the previous combination so no frame lies between them (`PATTERN` write and `VIDEO_MODE` write in mid-frame, `PATTERN_FRAME` 0 after each write and 4 in the fourth frame): the CRC-32 of every frame equals `testbench/pattern_crc_full.mem` from the C model |

`tb_rtlnet_csi2_rx_pattern` (tags `gap0`, `gap1`, `neg`) drives `rtlnet_csi2_rx_pattern` alone on reduced frames (320 x 96 and 448 x 128
pixels, bar width 40 and 56, box phase 48, 8, line periods 180 and 250) so that long sequences fit: both modes, 17 combinations (pattern 0 and 3
at speed +4, patterns 1, 2 and 4 at +4, -7, +24, +32, -32), 24 consecutive frames k = 0..23 each, 816 frames; every frame's CRC-32 equals
`testbench/pattern_crc_small.mem` from the C model (`csi2_bars_model --crc-mem-small`), which takes the scroll offset through its
wrap and the box through every bounce, fold and wrap of its triangle waves in both axes, and checks `tuser`, `tlast`, the word count,
`PATTERN_FRAME` (0 after a restart, k + 1 after frame k), `busy` low between frames, and (`gap0`) the line spacing of 180 and 250 clocks. It also
covers the restart rules: a restart in the clock of the start (that frame is k = 0 of the new pattern, the next k = 1), a start one clock
before the new pattern appears (the old pattern's next frame, then k = 0), a restart in the middle of a frame (that frame unchanged,
the next k = 0). `gap1` repeats everything with random output ready (75 %) and a 500-clock stall in the middle of a line.

`tb_rtlnet_video_path` runs the three Phase 1 cores in the board arrangement against the AXI4 memory model: the first
published frame (defaults only) is 1280x720 from the pattern and its slot bytes have the CRC-32 the C model prints for 720p30
(`TB_CRC720` 1832777744 = 0x6D3DF810);
after `VIDEO_MODE` 1 the latest published frame is 1920x1080 with the 1080p30 model CRC (`TB_CRC1080` 2396646443 = 0x8ED9EC2B); a held slot does not change while two
more frames are published; `FRAMES_OK`, published and dropped counts agree. The static bars are byte for byte those of Phase 1.

Host: `testbench/test_rtlnet_csi2_rx_driver.c` runs the driver against a register model with the rejection rules, now also `PATTERN`,
`PATTERN_FRAME` and `PATTERN_ERR` (`rtlnet_csi2_rx_driver_test.ps1`); `testbench/csi2_bars_model.c` (`csi2_bars_model.ps1`) has the self test (its CRC
engine returns 0xCBF43926 for "123456789", and every line of the static bars is identical), `-Verify` (regression entry
`pattern_model_xcheck`: the committed CRC tables equal what the C model prints, and `boards/nexys_video/scripts/pattern_model.py --verify-c`
compares the numpy model with the C model byte for byte on 220 frames: every pattern, both modes, k = 0, 1, 2, 37, 1000, speeds +4, -7, +24,
+32, -32, plus reduced geometries and box phases; then `stream_check.py selftest` builds streams from the Python model with ffmpeg libx264,
leaves pictures out, decodes and checks that the PSNR path finds k per picture and counts the resyncs: pattern 1 two resyncs and three
dropped pictures, patterns 2, 3, 4 one resync and one dropped picture, pattern 0 none, every PSNR above 50 dB) and `-WriteMem`.

Results (Active-HDL 11.1, 11-10-2026, `.sim/<bench>_<tag>/simulation.log`):

| Gate | Result |
|---|---|
| `tb_rtlnet_csi2_rx` `fast` | `TEST PASS: tb_rtlnet_csi2_rx checks=81314258` |
| `tb_rtlnet_csi2_rx` `fast_gap` | `TEST PASS: tb_rtlnet_csi2_rx checks=81305977` |
| `tb_rtlnet_csi2_rx` `real` | `TEST PASS: tb_rtlnet_csi2_rx checks=32839857` |
| `tb_rtlnet_csi2_rx` `patfull` | `TEST PASS: tb_rtlnet_csi2_rx checks=265421371`, "88 full-size pattern frames compared with the C model", 89 frames, 720p 45, 1080p 44 |
| `tb_rtlnet_csi2_rx` `neg` | expected `TEST FAIL ... first=INJECT_FAILURE negative control` |
| `tb_rtlnet_csi2_rx_pattern` `gap0` | `TEST PASS: tb_rtlnet_csi2_rx_pattern checks=72873474`, "816 frames checked against the C model, 18194432 words, 91592 line spacings" |
| `tb_rtlnet_csi2_rx_pattern` `gap1` | `TEST PASS: tb_rtlnet_csi2_rx_pattern checks=72781882` |
| `tb_rtlnet_csi2_rx_pattern` `neg` | expected `TEST FAIL ... first=INJECT_FAILURE negative control` |
| `tb_rtlnet_video_path` `crc_model` | `TEST PASS: tb_rtlnet_video_path checks=3059275` (the CRCs of Phase 1) |
| `tb_rtlnet_video_path` `neg` | expected `TEST FAIL ... first=INJECT_FAILURE negative control` |
| driver host test | `DRIVER TEST PASS: rtlnet_csi2_rx checks=31` |
| `pattern_model_xcheck` | `PATTERN_MODEL_XCHECK PASS: 220 frames compared with the C model, 0 mismatches`, `CSI2_BARS_MODEL: PASS` |
| Verilator `--lint-only -Wall` of `rtlnet_csi2_rx.f` | no warning in the three core files (the remaining warnings are in `rtlnet_common`) |

Mutations (RTL restored to the identical SHA-256 `1d493f2b...80ab9` afterwards): the box chroma Cb 90 changed to 91 fails `tb_rtlnet_csi2_rx`
`patfull` with 48 failed checks, the first "mode 0 pattern 2 speed 4 k 0 (frame 18): CRC 0x4501913b, C model 0x5e00af14"; the LFSR tap s[21]
changed to s[20] fails `tb_rtlnet_csi2_rx_pattern` `gap0` with 292 failed checks, the first "mode 0 pattern 3 speed 4 k 0: CRC 0xd5348556, C model 0x882036b5".
Phase 1 mutation: yellow bar Cb 44 changed to 45 in the generator fails
`tb_rtlnet_csi2_rx` (`fast`) at the first yellow word, "pattern word 80 of line 0 (mode 0): 0x88a82da8, expected 0x88a82ca8".

Run: `powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_csi2_rx -Filelist cores/rtlnet_csi2_rx/testbench/tb_rtlnet_csi2_rx.f -Tag <tag> -Defines <defines>`, or
`powershell -File scripts/rtlnet_regression.ps1 -Match csi2` for every gate above (the board top bench `tb_rtlnet_nexys_video_top` reads the VERSION and CAPS of this core and
needs the new values 0x11102026 and 0x52).

---

## 9. Integration guide

1. Instantiate with `clk` = `ui_clk` and the `ui_clk` reset; the register clock and reset are the CPU's.
2. Connect `m_axis_*` and the sideband to `rtlnet_vdma_s2mm`. The output is registered; a stalled `m_axis_tready` stalls the
   pattern (never a camera, which has to be buffered upstream).
3. Camera not built: tie `s_cam_tvalid`, `s_cam_tlast`, `s_cam_tuser`, `cam_clk_running` to 0 and leave `s_cam_tready` open.
4. Map the 4 KiB window and call `rtlnet_csi2_rx_probe`. `camera mode`, `camera source` and `camera rate` of the firmware CLI
   go through the driver.

---

## 10. Limitations

- Phase 1 only: no D-PHY capture, CSI-2 decode, SCCB or lane calibration; `STATUS.CLK_RUN` is the `cam_clk_running` input.
- Two modes (720p30, 1080p30); 720p60 and 2592x1944 are later `VIDEO_MODE` values with the camera.
- `k` restarts on a `VIDEO_MODE` change as well as on a `PATTERN` write (one set of running registers); the box phase must lie inside the frame (192, 96 are inside both modes).
- The models are exact for k below 2^32 (4.5 years at 30 fps); the counter then wraps and the sequence restarts from the running values.
- A camera frame that is cut off is closed short; the line count of a camera frame is checked against the mode in the DMA,
  the core does not check CSI-2 CRC or ECC (Phase 3).
- `FRAME_COUNT` and the timestamp wrap at 32 bits.
