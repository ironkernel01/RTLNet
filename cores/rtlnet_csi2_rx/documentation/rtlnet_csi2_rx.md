# rtlnet_csi2_rx — MIPI CSI-2 camera receiver core

| Item | Value |
|---|---|
| Core | `rtlnet_csi2_rx` |
| Document revision | 11-15-2026 |
| Language | SystemVerilog-2012 (RTL, benches), C11 (driver, C model) |
| Position | video source of the camera design |
| Register map revision | `VERSION` = `0x11152026` with the camera receiver (`CAMERA_RX` = 1), `0x11102026` without it; `ID` = `0x43534932` ("CSI2") |
| Contents of the core | register block, test-pattern generator (static bars, scrolling bars, moving box, noise band), source switch; with `CAMERA_RX` = 1 the camera receiver: D-PHY front end (two data lanes and a clock lane), CSI-2 packet layer, byte-clock FIFO, Bayer to RGB, RGB to YUV422 |
| Hardware status | the camera receiver runs on the Digilent Zybo Z7-20 with a Pcam 5C (OV5640, two lanes, RAW10, 720p and 1080p at 30 fps): section 12 lists what is measured there and what is not; every other board and sensor is untested |
| Verification | Active-HDL 11.1: the pattern benches (`tb_rtlnet_csi2_rx`, `tb_rtlnet_csi2_rx_pattern`, `tb_rtlnet_video_path`) and the camera receiver benches (`tb_rtlnet_csi2_rx_dphy`, `_packet`, `_cdc`, `_bayer`, `_camera`) with a bench D-PHY transmitter model and the Python model `csi2_rx_model.py`; host driver test; results in section 9; board measurements in section 12 |
| Synthesis | section 8 |

The core sends one YUV422 video stream to `rtlnet_vdma_s2mm`. The stream comes from the test-pattern generator (eight static
75 % bars at 720p30, the register reset default, or 1080p30, or with the `PATTERN` register bars scrolling sideways, a textured
box bouncing over the bars and a band of noise) or, with `CAMERA_RX` = 1, from the camera receiver inside the core: D-PHY pins in,
CSI-2 packets decoded, RAW10 Bayer converted to YUV422. A source switch in front of the stream chooses between them. With
`CAMERA_RX` = 0 the camera comes in through the `s_cam_*` stream port (a board without a camera ties it off).

Contents: 1 interface, 2 frame timing, 3 pattern, 4 source switch, 5 camera receiver, 6 registers, 7 clocks and crossings,
8 resources, 9 verification, 10 integration, 11 limitations, 12 board measurements.

---

## 1. Interface

### 1.1 Ports

| Group | Ports | Domain | Rule |
|---|---|---|---|
| clock, reset | `clk`, `resetn`, `s_axi_aclk`, `s_axi_aresetn` | `clk` (`ui_clk`, 90 MHz), `s_axi_aclk` (`cpu_clk`) | synchronous, active low; both resets release from one assertion |
| camera stream in (`CAMERA_RX` = 0) | `s_cam_tdata[31:0]`, `s_cam_tvalid`, `s_cam_tlast`, `s_cam_tuser`; out `s_cam_tready`; `cam_clk_running` | `clk` | same word format as the output; `cam_clk_running` is already synchronized. Tied off by a board without a camera; not used with `CAMERA_RX` = 1 (`s_cam_tready` still reports the switch) |
| camera pins (`CAMERA_RX` = 1) | `dphy_clk_p`, `dphy_clk_n` (HS clock pair), `dphy_clk_lp_p`, `dphy_clk_lp_n`, `dphy_dat_p[1:0]`, `dphy_dat_n[1:0]` (HS data pairs), `dphy_dat_lp_p[1:0]`, `dphy_dat_lp_n[1:0]` (LP pins of the data lanes), `ref_clk` | pins, `ref_clk` 200 MHz | all inputs; unconnected when `CAMERA_RX` = 0 |
| video stream out | `m_axis_tdata[31:0]`, `m_axis_tvalid`, `m_axis_tlast`, `m_axis_tuser`; in `m_axis_tready` | `clk` | AXI4-Stream; one word per transfer; `tuser` = first word of a frame, `tlast` = last word of a line |
| frame sideband | `m_frame_num[31:0]`, `m_timestamp[31:0]`, `m_width[15:0]`, `m_height[15:0]`, `m_src_pattern` | `clk` | registered with the stream; stable from the clock the first word of a frame enters the output register until the next first word |
| registers | `s_axi_aw*`, `s_axi_w*`, `s_axi_b*`, `s_axi_ar*`, `s_axi_r*` (AXI4-Lite, 12-bit address, 32-bit data) | `s_axi_aclk` | 4 KiB window, crossing in section 7 |

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
| `CAMERA_RX` | 0 | 1 builds the camera receiver; 0 is the register block, generator and switch with the external `s_cam_*` port |
| `DPHY_TARGET` | `` `RTLNET_TARGET `` ("AMD") | "AMD" selects the 7-series primitives (IBUFDS, BUFIO, BUFR, IDELAYE2, ISERDESE2, IDELAYCTRL) in `rtlnet_csi2_rx_dphy_io`; any other string a behavioural model for simulation and other vendors |
| `NONCONT_CLOCK` | 0 | 1 for a sensor that stops the HS clock between bursts (section 5.2) |
| `IDELAYCTRL_INST` | 1 | 1 puts the IDELAYCTRL inside the front end (IODELAY group `rtlnet_csi2_dly`) |
| `HS_DIFF_TERM` | 1 | 1 enables the internal 100 ohm termination of the HS clock and data inputs (needs the bank at VCCO 2.5 V); 0 for a board that terminates the lanes itself and runs the bank at another voltage (the Zybo Z7-20 bank 35 runs at 3.3 V: 0) |
| `FIFO_KB` | 4 | byte-clock FIFO size in kilobytes of 8-byte words (depth = 128 x `FIFO_KB` entries, a power of two; one entry holds four pixels) |
| `LINE_KB` | 8 | Bayer line buffer size in kilobytes of 4-byte words (pixels per line = 256 x `LINE_KB`, 2048) |
| `RAM_STYLE` | "block" | "block" or "distributed" for both RAMs (through `rtlnet_ram_core`) |
| `WIDTH_720`, `HEIGHT_720`, `WIDTH_1080`, `HEIGHT_1080` | 1280, 720, 1920, 1080 | frame geometry of the two modes (the benches use small values) |

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
2,666 clocks per line) is that of the first generator; the pipeline only delays the first word by a constant number of clocks.

### 3.5 Models

The frame bytes are those of `testbench/csi2_bars_model.c` (host gcc, the reference; `--frame <mode> <pattern> <speed> <k>` prints the
CRC-32 and `--dump-frame` writes the bytes), which prints the CRC-32 (IEEE 802.3, zlib `crc32`) of the packed frame as it lands in
DDR3: static bars 720p30 1,843,200 bytes `0x6D3DF810`, 1080p30 4,147,200 bytes `0x8ED9EC2B`. `testbench/pattern_model.py`
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

## 5. Camera receiver

`CAMERA_RX` = 1 builds the receiver in front of the source switch. Data path, in the order of the signal:

| Block | File | Clock | Job |
|---|---|---|---|
| D-PHY pins | `rtlnet_csi2_rx_dphy_io` | HS clock, `ref_clk` | the only file with device primitives (`DPHY_TARGET`): IBUFDS on the clock and data pairs, BUFIO and BUFR (divide by 4, the byte clock), IDELAYE2 per data lane, ISERDESE2 1:8 DDR; one raw byte per lane per byte clock |
| LP and clock monitor | `rtlnet_csi2_rx_dphy_ctl`, `_dphy_lp` | `ref_clk` | LP state sequences of the three lanes, HS settle timer, HS clock detector |
| lane alignment | `rtlnet_csi2_rx_lane` (two) | byte clock | sync byte search, byte alignment |
| lane merge | `rtlnet_csi2_rx_deskew` | byte clock | lane skew removal, byte pairs |
| packet layer | `rtlnet_csi2_rx_packet` | byte clock | ECC, CRC-16, filter, RAW10 unpacking |
| FIFO | `rtlnet_csi2_rx_cdc` | byte clock to `clk` | Gray-pointer asynchronous FIFO over `rtlnet_ram_core`, entries dropped and counted when full |
| Bayer | `rtlnet_csi2_rx_bayer` | `clk` | frame and line conditioning, black level, white balance, demosaic, gamma |
| RGB to YUV | `rtlnet_csi2_rx_yuv` | `clk` | BT.709 limited-range 4:2:2 words `{Cr, Y1, Cb, Y0}` |

`rtlnet_csi2_rx_dphy` joins the first five blocks; `rtlnet_csi2_rx_pkg` holds the ECC, CRC-16 and FIFO entry definitions.
Rates: up to 420 Mb/s per lane (210 MHz DDR HS clock, 52.5 MHz byte clock, 84 Mpixel/s of RAW10 on two lanes); the pixel path takes one pixel
per `clk` clock (90 MHz).

### 5.1 D-PHY front end

*LP states.* Each data lane has a tracker in `ref_clk`: the LP pins `{Dp, Dn}` pass a two-flop synchronizer and a glitch filter (two equal
samples). The sequence stop (11), request (01), bridge (00) starts the settle timer; after `RX_SETTLE` clocks (28 = 140 ns at the reset value) `hs_go`
rises. A filtered stop state ends the burst. A state that does not fit the sequence sends the lane back to waiting for a stop state.

*HS clock.* The byte clock toggles a flop on every cycle; the toggle crosses into `ref_clk`. The clock counts as running after two edges and as
stopped after 64 `ref_clk` clocks without an edge (`RX_STATUS.CLK_RUN`). `hs_go` needs a running clock.

*Byte alignment.* Each lane keeps the last three raw bytes (24 bits in time order) and looks, from `hs_go` on, for the sync byte 0xB8 (wire bits
0,0,0,1,1,1,0,1, least significant bit first) at all eight bit offsets, preceded by four zero bits. A match locks the offset for the burst; the bytes
after it are the lane output, the first one marked. No match within 24 byte clocks, or `hs_go` falling first, abandons the burst and counts one
`SOT` error. The output stays valid for 4 byte clocks after `hs_go` fell, because the LP detection is slower than the data path: ending at `hs_go`
would cut the last bytes of a packet. The hold is shorter than the gap between bursts (the settle time alone is about 4 byte clocks at 100 Mb/s). The
junk bytes of the hold and the HS trail follow the packet and the packet layer ignores them. `RX_CTRL.BIT_REV` reverses the bit order of the raw byte for a
deserializer that delivers the earliest bit last (the ISERDESE2 Q8 is the first bit received and maps to bit 0, so the AMD front end runs with `BIT_REV` 0).

*Lane merge.* The first byte after the sync byte of each lane is marked; the lane that starts first is delayed by 0 to 3 byte clocks until the other lane starts. A
second lane that starts later than 3 byte clocks, or never, gives one `SOT` error for the burst. Pairs `{lane 1, lane 0}` leave while both
lanes are valid; `p_end` follows one clock after the last pair. With `RX_CTRL.LANE_EN` = 1 only lane 0 is used and two consecutive bytes form a pair.

*Delay taps.* `RX_TAPS` loads a 5-bit IDELAYE2 value per data lane (200 MHz reference, 78 ps per tap) through a load pulse when the value changes.
The behavioural model ignores the taps.

### 5.2 Clock modes and resets

With a continuous HS clock (`NONCONT_CLOCK` = 0, the OV5640 setting in `rtlnet_ov5640_tables.h`, register 0x4800 = 0x14) the byte-clock logic is held in
reset while the clock is not running, so that a clock that stops in the middle of a frame leaves no half-finished packet: the `CLKLOSS` counter counts it,
the rest of the burst gives an `SOT` error, the lines after it are counted as orphans until the next frame start and the frame is closed by the Bayer stage
(section 5.4). With `NONCONT_CLOCK` = 1 the logic is not reset by a stopped clock, the BUFR divider is held in reset while the clock lane is in the stop state, and the end of a burst completes
with the first clocks of the next one (the clock stops only about ten byte clocks after the lane left the burst); `CLKLOSS` then counts every burst.
Three resets: `ref_resetn` (reference clock), `byte_resetn_g` (global: FIFO pointers and event crossings, released only by the system reset and `RX_CTRL.SOFT_RESET`) and
`byte_resetn` (logic). All come from `rtlnet_reset_sync` (asynchronous assertion, so they work with the clock stopped).

### 5.3 Packet layer

One packet per HS burst: the first four bytes after the sync byte are the header; whatever follows the packet in the burst (HS trail, a chained second packet) is ignored. The OV5640
sends one packet per burst.

| Item | Rule |
|---|---|
| header | data identifier, word count (2 bytes), ECC byte. One flipped bit in the 32 bits (also in the ECC byte) is corrected and the packet used (`ECC_CORR`); two flipped bits are detected (`ECC_UNC`) and the packet and the burst dropped |
| filter | `RX_FILTER`: another virtual channel is dropped without a count; a long packet of another data type than `RX_FILTER.DT` (reset 0x2B, RAW10) and a short packet of a reserved type (4 to 15) count `DT`; line start and line end are ignored |
| frame | frame start (type 0) opens the frame (`FRAMES`, `RX_STATUS.IN_FRAME`) and arms the start flag of the next line; frame end (type 1) pushes a frame-end marker and closes it. A line outside a frame counts `ORPHAN` and is dropped |
| RAW10 | five bytes carry four pixels (four high bytes, then the four low bit pairs); every complete group of five bytes becomes one FIFO entry of four pixels, with the end-of-line flag on the last complete group. A word count of 0 or not a multiple of 5 counts `LEN` (complete groups are still used) |
| CRC | CRC-16 (polynomial x^16 + x^12 + x^5 + 1, initial value 0xFFFF, reflected) over the payload against the two bytes that follow. A mismatch counts `CRC`; the pixels were already pushed and are used |
| truncation | a burst that ends before the word count and CRC are complete counts `TRUNC`; an end-of-line marker entry closes the line. The junk bytes of the burst end fill up to about 8 byte pairs, so a packet that is short by fewer than about 16 bytes is seen as a CRC error instead; both are errors counted |

### 5.4 Bayer, conditioning and output

*Conditioning.* Every frame that starts is output at exactly `WIDTH` x `HEIGHT` of the mode in `VIDEO_MODE` at the frame start: longer lines are cut, short lines padded with zero pixels, missing lines
padded with zero lines at the frame end, extra lines dropped, so the source switch (which ends a camera frame by its line count) and the DMA always get a complete frame. A frame start inside a frame closes the open frame the same way.
`SIZE` counts frames whose line count or any line width differs from the mode; `RX_LINES` and `RX_PIXELS` hold the size of the last frame and last line as received. Change `VIDEO_MODE` only while the camera does not stream.

*Processing* (one pixel per clock, every stage advances together while the output is ready; a frame takes (W + 1) x (H + 1) steps because the last column and row are completed by one virtual step):
black level subtraction (`BLACK`, floored at 0); white balance gain of the Bayer site (unsigned 4.8 fixed point, 1.0 = 0x100; `clip10((t x gain + 128) >> 8)`); two line buffers in one `rtlnet_ram_core` word;
bilinear demosaic over a 3 x 3 window with mirrored borders (the missing row or column is replaced by the opposite one, which keeps the colour of every site); `PHASE` is the site of the
first pixel (0 R of RGGB, 1 G on a red row, 2 G on a blue row, 3 B; bit 0 mirrors columns, bit 1 rows); with `PROC.GREEN_EQ` (reset 0) the green of a G site is the mean of that G and the
mean of its four diagonal neighbours, `(G + (D sum + 2) / 4 + 1) / 2`: the diagonals of a G site are the other kind of G, so Gr and Gb come out equal and a sensor whose two greens differ shows no two-pixel luma pattern
(the Pcam 5C OV5640 in its binned 720p mode: Gr and Gb differ by about 8 percent, a fixed pattern of +-6 percent luma in flat areas); the price is a slightly softer green at the G sites; with `PROC.HIGHLIGHT` (reset 0) the highlight clamp (below) acts on the gained demosaiced 10-bit values; 10 to 8 bits `(v + 2) >> 2`; with `PROC.GAMMA` a 16-segment piecewise-linear curve (about 1/2.2,
breakpoints 0, 72, 99, 119, 136, 151, 164, 175, 186, 197, 206, 215, 224, 232, 240, 248, 255 at multiples of 16); then `rtlnet_csi2_rx_yuv`. The reset gains are 1.0 each; no gain is tuned for a sensor. Configuration is taken at each frame start.
*Highlight clamp.* The white balance gains (above 1.0 on red and blue) bring red and blue to full scale at a raw value below that of green (gain 1.0): in a bright area red and blue are clipped after the gain while green is still lower, and the highlight comes out pink. The `RAW_MAX` registers give the raw maxima per channel to see this.
With `PROC.HIGHLIGHT` = 1 a pixel of the gained, demosaiced 10-bit triple (R, G, B) whose green is at or above `HL_LEVEL` gets G = max(G, R, B); R and B stay. The comparison is `G >= HL_LEVEL`: a green equal to the level qualifies, one below does not. `HL_LEVEL` 0 with the clamp on qualifies every pixel (G becomes the largest of the three everywhere);
`HL_LEVEL` 1023 qualifies only pixels at full scale. The clamp acts after green equalisation and before the 8-bit scaling and the gamma; with `PROC.HIGHLIGHT` = 0 the output is the unclamped picture. A level a few percent below the green of such a bright area, after the gains, lifts exactly those areas.
The clamp enable and the level are taken at the frame start with the other processing configuration.

*Raw maxima.* `RAW_MAX` holds, per colour, the largest black-level-subtracted raw value (before the gain) at the red, the green (both kinds of G) and the blue sites of the last completed frame: the running maxima restart at a frame start and are published when the frame ends, together with `RX_LINES`.
Before the first frame they read 0. They show per colour how close the sensor is to clipping, which is the value to choose `HL_LEVEL` from (the clipped green maximum multiplied by the green gain, minus a margin).

Demosaic formulas: R or B site G = (N + S + W + E + 2) / 4 and the other colour (sum of the four diagonals + 2) / 4; G site on a red row R = (W + E + 1) / 2, B = (N + S + 1) / 2; G site on a blue row B = (W + E + 1) / 2, R = (N + S + 1) / 2.

*YUV.* `rtlnet_csi2_rx_yuv` converts RGB to BT.709 YUV422 with a Q16 matrix (rounding offsets folded in, chroma of the unrounded sum of the two pixels, Y clipped to 16..235, chroma to 16..240).

### 5.5 Counters and status

Twelve saturating 32-bit counters in `clk` (event pulses of the byte clock cross through `rtlnet_pulse_sync`, one per counter): `ECC_CORR`, `ECC_UNC`, `CRC`, `SOT`, `FRAMES`, `DT`, `TRUNC`, `OVF` (FIFO entries dropped because
the `clk` side did not keep up), `SIZE`, `ORPHAN`, `LEN`, `CLKLOSS`. `RX_STATUS` carries clock running, lane in burst, lane locked, IDELAYCTRL ready, in frame, YUV format error and the LP states of the data lanes.

---

## 6. Registers

12-bit address; offsets are defined in `driver/rtlnet_csi2_rx.h` and mirrored in `hdl/rtlnet_csi2_rx_regs.sv`. Writes are
full-word only. A write the core rejects leaves the register unchanged and sets a sticky flag; nothing is clamped.
Undefined offsets read 0 and ignore writes.

| Offset | Name | Access | Reset | Content |
|---:|---|---|---|---|
| 0x000 | `ID` | RO | 0x43534932 | "CSI2" |
| 0x004 | `VERSION` | RO | 0x11152026 | register map date code; 0x11102026 when the core is built without the camera receiver |
| 0x008 | `CAPS` | RO | 0x72 | `[3:0]` number of video modes (2), `[4]` test-pattern generator, `[5]` camera receiver (0 without `CAMERA_RX`, value 0x52), `[6]` moving patterns |
| 0x010 | `VIDEO_MODE` | RW | 0 | `[1:0]` 0 = 720p30, 1 = 1080p30; a value above 1 sets `STATUS.MODE_ERR`; a mode whose minimum period exceeds the present `FRAME_PERIOD` sets `STATUS.PERIOD_ERR`; both leave the register unchanged; effective at the next frame start |
| 0x014 | `SOURCE` | RW | 0 | `[1:0]` 0 = auto, 1 = camera only, 2 = pattern only; 3 and above set `STATUS.SOURCE_ERR` and change nothing |
| 0x018 | `FRAME_PERIOD` | RW | 3,000,000 | `clk` cycles per frame; below the minimum of the selected mode sets `STATUS.PERIOD_ERR` and changes nothing |
| 0x01C | `CAM_TIMEOUT` | RW | 2 | frame periods without a camera frame before auto uses the pattern (0 = auto never uses the camera) |
| 0x020 | `STATUS` | RO, flags W1C | 1 | `[0]` selected source (0 camera, 1 pattern), `[1]` camera byte clock running, `[2]` `MODE_ERR`, `[3]` `PERIOD_ERR`, `[4]` `SOURCE_ERR`, `[5]` `OVERRUN`, `[6]` `PATTERN_ERR` (flags sticky, write 1 to clear; a new error in the clock of a clear keeps it set) |
| 0x024 | `FRAME_COUNT` | RO | 0 | frames sent, both sources, counted at the first word of a frame |
| 0x028 | `ACTIVE` | RO | 0 | `[1:0]` mode of the frame in progress or the last frame |
| 0x030 | `PATTERN` | RW | 0x0000_0400 | `[2:0]` pattern: 0 static bars, 1 scrolling bars, 2 moving box over the bars, 3 bars with a noise band, 4 all three; `[15:8]` signed speed in pixels per frame of the scroll and the box, reset 4, allowed -32 to +32 (0x00..0x20, 0xE0..0xFF); a pattern of 5 to 7, a speed beyond +-32 or any other bit set sets `STATUS.PATTERN_ERR` and leaves the register unchanged; effective at the next frame start, which is `k` = 0 |
| 0x034 | `PATTERN_FRAME` | RO | 0 | pattern frames started since the last accepted `PATTERN` write or `VIDEO_MODE` change (reads 0 right after it; the `k` of the next frame) |
| 0x040 | `RX_CTRL` | RW | 0x0D | camera receiver: `[0]` enable, `[1]` soft reset (holds the receiver in reset), `[3:2]` lane enable (3 two lanes, 1 lane 0 only), `[4]` bit order reversal |
| 0x044 | `RX_STATUS` | RO | | `[0]` HS clock running, `[2:1]` lane in a burst, `[4:3]` lane locked on its sync byte, `[5]` IDELAYCTRL ready, `[6]` in frame, `[7]` YUV format error, `[9:8]` LP state of lane 0, `[11:10]` of lane 1 (3 = stop) |
| 0x048 | `RX_TAPS` | RW | 0 | `[4:0]` IDELAY tap of lane 0, `[12:8]` of lane 1 |
| 0x04C | `RX_SETTLE` | RW | 28 | `[7:0]` HS settle time in 200 MHz clocks |
| 0x050 | `RX_FILTER` | RW | 0x2B00 | `[1:0]` virtual channel, `[13:8]` data type (0x2B RAW10) |
| 0x054 | `RX_CLEAR` | WO | | bit n clears counter n, bit 31 clears all; reads 0 |
| 0x058 | `RX_LINES` | RO | 0 | lines of the last frame as received |
| 0x05C | `RX_PIXELS` | RO | 0 | pixels of the last line as received |
| 0x060 to 0x08C | counters | RO | 0 | 12 counters, 4 bytes apart, order: `ECC_CORR`, `ECC_UNC`, `CRC`, `SOT`, `FRAMES`, `DT`, `TRUNC`, `OVF`, `SIZE`, `ORPHAN`, `LEN`, `CLKLOSS` |
| 0x090 | `BLACK` | RW | 0 | `[9:0]` black level in 10-bit raw units |
| 0x094, 0x098, 0x09C | `WB_R`, `WB_G`, `WB_B` | RW | 0x100 | `[11:0]` gain, unsigned 4.8 fixed point, 0x100 = 1.0 |
| 0x0A0 | `PHASE` | RW | 0 | `[1:0]` Bayer site of the first pixel of the first line |
| 0x0A4 | `PROC` | RW | 0 | `[0]` gamma enable, `[1]` green equalisation, `[2]` highlight clamp enable (`PROC.HIGHLIGHT`) |
| 0x0A8 | `RAW_MAX` | RO | 0 | maxima of the last completed frame, black level subtracted, before the gain: `[9:0]` red, `[19:10]` green, `[29:20]` blue; writes are ignored |
| 0x0AC | `HL_LEVEL` | RW | 0 | `[9:0]` highlight clamp level in 10-bit units of the gained values |

The camera registers (0x040 and up) exist with `CAMERA_RX` = 1; without it they read 0 and ignore writes. Fields are masked to their width, reserved bits read 0, no reject flags. `RX_CTRL`, `RX_TAPS`, `RX_SETTLE`, `RX_FILTER` are written while the receiver is idle. Driver functions: `rtlnet_csi2_rx_rx_control`, `_set_taps`,
`_set_settle`, `_set_filter`, `_set_black`, `_set_wb`, `_set_phase`, `_set_gamma`, `_set_green_eq` (each of the two read-modify-writes `PROC` and keeps the other bits), `_set_highlight` (enable and level 0..1023, else `ERR_ARG`, same `PROC` rule), `_read_raw_max`, `_read_rxstate`, `_clear_counters`; `_probe` accepts both VERSION values.

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

## 7. Clocks and crossings

Pattern generator, switch, output register, Bayer, YUV and register file run in `clk` (`ui_clk`, 90 MHz). The register window is on `s_axi_aclk` (`cpu_clk`) behind `rtlnet_axil_cdc`
(whole-transaction toggle crossing, constrained by `scripts/rtlnet_constrain_cdc.tcl`) and `rtlnet_axil_slave`. With `CAMERA_RX` = 1 two more clocks exist: `ref_clk` (200 MHz, LP trackers, clock detector, IDELAY load and reference)
and the byte clock (BUFR output, a quarter of the HS clock; at 420 Mb/s per lane 52.5 MHz). Crossings:

| Crossing | Mechanism |
|---|---|
| registers `s_axi_aclk` to `clk` | `rtlnet_axil_cdc` |
| configuration (taps, settle, lane enable, enable, bit order, filter) `clk` to `ref_clk` and byte clock | levels, two-flop `rtlnet_sync`, written while idle |
| byte clock toggle to `ref_clk` | three-flop `rtlnet_sync`, edge detect |
| `hs_go` `ref_clk` to byte clock | two-flop `rtlnet_sync` |
| pixel entries byte clock to `clk` | `rtlnet_csi2_rx_cdc`, Gray-coded pointers (`rtlnet_gray_sync`) |
| event pulses byte clock to `clk` | `rtlnet_pulse_sync`, one per counter (events are at least one packet apart) |
| status levels `ref_clk` and byte clock to `clk` | two-flop `rtlnet_sync` |
| soft reset `clk` to `ref_clk` and byte clock | asynchronous assertion through `rtlnet_reset_sync` |

Timing constraints of the HS inputs, the IDELAY group and the CDC bounds belong to the board design (a camera board's constraint files). The Zybo Z7-20 design
(`boards/zybo_z7_20`) constrains the HS clock at 4.762 ns, the HS data input delays against it, the false path of the LP pins and the CDC bounds of `scripts/rtlnet_constrain_cdc.tcl`
(33 `rtlnet_sync`, 3 `rtlnet_reset_sync`, 2 Gray pointers, one `rtlnet_axil_cdc`); Vivado derives the byte clock at the BUFR output itself.

---

## 8. Resources

Vivado 2026.1, out-of-context synthesis of `rtlnet_csi2_rx` with `CAMERA_RX` = 1, AMD primitives, `xc7z020clg400-1`, default parameters (1280 x 720 and 1920 x 1080 modes,
4 KB FIFO, 8 KB line buffers). The result is a post-synthesis estimate: no placement, no routing, no board constraints.

| Resource | Used |
|---|---|
| Slice LUT | 2,745 (5.2 %) |
| Slice register | 2,976 (2.8 %) |
| Block RAM | 2.5 tiles (two RAMB36 for the FIFO and one RAMB18 for the line buffers, 20 bits x 2,048) |
| DSP48 | 11 (white balance multiplier, YUV matrix) |

Estimated timing with clocks `clk` 11.111 ns (90 MHz), the HS clock 4.762 ns (210 MHz DDR, 420 Mb/s per lane) and the byte clock as the divide-by-4 generated clock of the BUFR, `ref_clk` 5 ns:

| Clock | Worst setup slack |
|---|---|
| `clk` (90 MHz) | +1.772 ns |
| byte clock (19.048 ns, 420 Mb/s per lane) | +6.438 ns |
| `ref_clk` (200 MHz) | +1.159 ns |
| `s_axi_aclk` (50 MHz) | +17.118 ns |

The crossings between these clocks show negative slack in this run because no CDC bound is applied; the board constraints bound them (`scripts/rtlnet_constrain_cdc.tcl`
bounds the Gray pointers and the pulse and level synchronizers of the core; the configuration levels that cross into `ref_clk` and the byte clock are static while the receiver runs).
The pattern-only core (`CAMERA_RX` = 0) has the resources of the pattern generator and switch only (about 1,100 LUT, 1,100 FF, no RAM).

Placed and routed in the Zybo Z7-20 design (Vivado 2026.1, image `own6` before the highlight clamp, hierarchical report; the whole design with the clamp, image `own7`: 33,897 LUT, 27,770 registers, WNS +0.252 ns and WHS +0.050 ns without the two deviation endpoints): `u_rx` 2,665 LUT, 2,923 registers, 2 RAMB36 and 1 RAMB18, 11 DSP48. The 90 MHz domain of that design closes
with +0.404 ns setup and +0.051 ns hold; the byte clock (`g_cam.byte_clk`) with +4.816 ns and +0.063 ns; the 200 MHz reference with +0.942 ns and +0.119 ns. The two HS data samplers
(`ISERDESE2` `DDLY` pins, clock `rtlnet_dphy_hs`) meet setup with +0.584 and +0.623 ns and fail hold with -1.385 and -1.429 ns at the IDELAY tap attribute 0 (static timing does not know the tap loaded at run time):
see section 12.

---

## 9. Verification

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

`tb_rtlnet_video_path` runs the pattern core, `rtlnet_vdma_s2mm` and `rtlnet_framebuf` in the board arrangement against the AXI4 memory model: the first
published frame (defaults only) is 1280x720 from the pattern and its slot bytes have the CRC-32 the C model prints for 720p30
(`TB_CRC720` 1832777744 = 0x6D3DF810);
after `VIDEO_MODE` 1 the latest published frame is 1920x1080 with the 1080p30 model CRC (`TB_CRC1080` 2396646443 = 0x8ED9EC2B); a held slot does not change while two
more frames are published; `FRAMES_OK`, published and dropped counts agree. The static bars are unchanged.

Host: `testbench/test_rtlnet_csi2_rx_driver.c` runs the driver against a register model with the rejection rules, now also `PATTERN`,
`PATTERN_FRAME` and `PATTERN_ERR` (`rtlnet_csi2_rx_driver_test.ps1`); `testbench/csi2_bars_model.c` (`csi2_bars_model.ps1`) has the self test (its CRC
engine returns 0xCBF43926 for "123456789", and every line of the static bars is identical), `-Verify` (regression entry
`pattern_model_xcheck`: the committed CRC tables equal what the C model prints, and `testbench/pattern_model.py --verify-c`
compares the numpy model with the C model byte for byte on 220 frames: every pattern, both modes, k = 0, 1, 2, 37, 1000, speeds +4, -7, +24,
+32, -32, plus reduced geometries and box phases; then `stream_check.py selftest` builds streams from the Python model with ffmpeg libx264,
leaves pictures out, decodes and checks that the PSNR path finds k per picture and counts the resyncs: pattern 1 two resyncs and three
dropped pictures, patterns 2, 3, 4 one resync and one dropped picture, pattern 0 none, every PSNR above 50 dB) and `-WriteMem`.

### 9.1 Camera receiver benches

All benches use the bench D-PHY transmitter model `rtlnet_csi2_tb_phy.sv` (two lanes and a clock lane, LP-11 / LP-01 / LP-00 sequences, HS garbage, zero leader, sync byte,
data least significant bit first, HS trail, per-lane skew in bit times, settable bit rate, continuous or non-continuous clock, clock freeze) and the packet builders of
`rtlnet_csi2_tb_pkg.sv`, whose ECC (explicit parity equations) and CRC-16 (MSB-first register over bit-reversed bytes) are written independently of the RTL. No bench uses `foreach`.

| Bench (tags in `regression.txt`) | Proves |
|---|---|
| `tb_rtlnet_csi2_rx_dphy` (`cont`, `noncont`) | clock detection; packets at 420, 280, 140 and 100 Mb/s; lengths 4 to 1602 bytes; the shortest and a long HS trail (no real pair lost); lane skew of 0 to 23 bit times either side (pair stream exact) and 40 bit times (no pair, one `SOT` event); missing sync on lane 0, lane 1, both; single lane; the non-continuous clock (`noncont`); a clock freeze in the middle of a burst (`cont`: clock-running flag falls, one `SOT` event, next packet exact); disabled receiver; six back-to-back bursts |
| `tb_rtlnet_csi2_rx_packet` | frame and line packets to FIFO entries; line lengths 4 to 1920 pixels; all 32 single-bit header errors on a line packet and on a frame start (corrected, packet used); all 496 double-bit errors on a frame start and 120 on a line (detected, dropped); each of the 16 CRC bits and a payload bit flipped (counted, pixels pushed); other virtual channel, wrong and reserved data types, line start / end, line outside a frame; word counts 0 to 14; truncation after 1, 2, 3, 5, 10 and N - 1 pairs, burst restart; trail pairs and a chained second packet ignored; gapped pair stream; frame start inside a frame |
| `tb_rtlnet_csi2_rx_cdc` | 4,000 entries in order with a fast and a slow reader and the reverse clock ratio; overflow with a stalled reader (71 pulses, the first 129 entries read in order); sustained overflow (every accepted entry out once, in order, none of the dropped ones) |
| `tb_rtlnet_csi2_rx_bayer` (`small`, `fault`, `wide`) | Bayer to YUV words equal `csi2_rx_model.py` bit for bit: four phases with black level, gains and gamma, two cases with green equalisation (phase 3 with gains, phase 1 with black level, gains and gamma), a clipped highlight scene (green clipped below red and blue, gains of 1.58 and 1.48 on red and blue): clamp off (pink), on at level 700, level equal to the green of an edge pixel and one above, level 0, level 1023, phase 3 with green equalisation and gamma; `RAW_MAX` source values against the model after every case; both mode geometries, short lines and fewer lines than the mode (padded), long lines and more lines (cut), a lost line, a line closed by a marker after four pixels, a frame cut after three lines, a frame start inside a frame, lines of 1280 and 1920 pixels; with random entry gaps and random output ready and at full speed; `ev_size_err` pulses; `RX_LINES` / `RX_PIXELS` source values |
| `tb_rtlnet_csi2_rx_camera` (`small`, `wide`) | the whole core with `CAMERA_RX` = 1 over the pins (also with `HS_DIFF_TERM` 0, which the behavioural front end ignores): register reset values and masks (`PROC` bits 2:0, `HL_LEVEL`, `RAW_MAX` read only); every case of the set exact against the model with the sideband, the counters, `RX_LINES` / `RX_PIXELS` and `RAW_MAX` (the clipped-highlight cases write `HL_LEVEL` and `PROC` bit 2); faults, each counted and each followed by an exact recovery frame: one-bit header error, two-bit header error, CRC error, missing sync, packet cut after four pixels, other data type, five-byte lane skew, HS clock frozen in the middle of a line (clock loss, orphan lines, the cut frame closed by the next frame start), lost frame start; `RX_CLEAR` for one and all counters; soft reset |
| `csi2_rx_model_xcheck` | self test of the Python model (CRC-16 check value 0x6F91, ECC columns, constant picture, black, white, the clamp rule and its level boundary on the clipped scene, the raw maxima) and the committed `.mem` files equal the model |

Each bench has a negative control (`neg`: `+INJECT_FAILURE` fails the verdict) and a mutation entry (`mut`: `+MUTATE` perturbs one expected or driven value and the compare must fail).
Not simulated: the AMD primitive branch of `rtlnet_csi2_rx_dphy_io` (the ISERDESE2 model is encrypted and is not compiled by the simulation scripts): it is covered by the Vivado synthesis and implementation of the board design and by the board measurements of section 12.
Two mutation entries cover the clamp and the maxima: `mut_hl` (the level at the core is one above the model level, the boundary cases fail with word mismatches) and `mut_max` (one bit of the expected `RAW_MAX` word is wrong, the maxima check fails), in `tb_rtlnet_csi2_rx_bayer`; `mut_max` also in `tb_rtlnet_csi2_rx_camera`.
A mutation of the green equalisation rounding (`+ 1` to `+ 0` in `g_eq`) fails `tb_rtlnet_csi2_rx_bayer` `small` with 70 word mismatches (RTL restored byte for byte afterwards).

Results (Active-HDL 11.1, 11-15-2026, `.sim/<bench>_<tag>/simulation.log`):

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
| `tb_rtlnet_video_path` `crc_model` | `TEST PASS: tb_rtlnet_video_path checks=3059275` (the static-bars CRCs) |
| `tb_rtlnet_video_path` `neg` | expected `TEST FAIL ... first=INJECT_FAILURE negative control` |
| driver host test | `DRIVER TEST PASS: rtlnet_csi2_rx checks=55` |
| `pattern_model_xcheck` | `PATTERN_MODEL_XCHECK PASS: 220 frames compared with the C model, 0 mismatches`, `CSI2_BARS_MODEL: PASS` |
| camera receiver benches | `dphy` cont 328 checks and noncont 343, `packet` 1688, `cdc` 18, `bayer` small 8468, fault 4646, wide 38417, `camera` small 11304 and wide 19342, `csi2_rx_model_xcheck` PASS, each negative control and mutation fails as required; driver host test `DRIVER TEST PASS: rtlnet_csi2_rx checks=56` |

Mutations (RTL restored to the identical SHA-256 `1d493f2b...80ab9` afterwards): the box chroma Cb 90 changed to 91 fails `tb_rtlnet_csi2_rx`
`patfull` with 48 failed checks, the first "mode 0 pattern 2 speed 4 k 0 (frame 18): CRC 0x4501913b, C model 0x5e00af14"; the LFSR tap s[21]
changed to s[20] fails `tb_rtlnet_csi2_rx_pattern` `gap0` with 292 failed checks, the first "mode 0 pattern 3 speed 4 k 0: CRC 0xd5348556, C model 0x882036b5".
Mutation of the static bars: yellow bar Cb 44 changed to 45 in the generator fails
`tb_rtlnet_csi2_rx` (`fast`) at the first yellow word, "pattern word 80 of line 0 (mode 0): 0x88a82da8, expected 0x88a82ca8".

Run: `powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_csi2_rx -Filelist cores/rtlnet_csi2_rx/testbench/tb_rtlnet_csi2_rx.f -Tag <tag> -Defines <defines>`, or
`powershell -File scripts/rtlnet_regression.ps1 -Match csi2` for every gate above (the pattern core without the camera keeps VERSION 0x11102026 and CAPS 0x52, so the board benches that read them do not change).

---

## 10. Integration guide

1. Instantiate with `clk` = `ui_clk` and the `ui_clk` reset; the register clock and reset are the CPU's.
2. Connect `m_axis_*` and the sideband to `rtlnet_vdma_s2mm`. The output is registered; a stalled `m_axis_tready` stalls the pattern. The camera cannot be stalled: the byte-clock FIFO (`FIFO_KB`) absorbs a short stall
   and drops entries when full (`OVF`).
3. Without a camera (`CAMERA_RX` = 0): tie `s_cam_tvalid`, `s_cam_tlast`, `s_cam_tuser`, `cam_clk_running` to 0, leave `s_cam_tready` and the pin ports open.
4. With the camera (`CAMERA_RX` = 1): connect the eleven pin ports to the camera connector, a 200 MHz `ref_clk`, and constrain the HS clock (a clock-capable pin pair, the clock created on it at the sensor's
   rate, the HS data input delays against it), the `rtlnet_csi2_dly` IODELAY group with one IDELAYCTRL (or `IDELAYCTRL_INST` = 0 and one outside), the LP pins in an LVCMOS or HSUL_12 bank that reads the connector levels (the LP receivers are false paths), and the CDC bounds of `scripts/rtlnet_constrain_cdc.tcl`.
   Set `HS_DIFF_TERM` to 0 when the HS inputs are terminated on the board or the bank does not run at 2.5 V (an LVDS_25 input with the internal termination in a 3.3 V bank fails the placer DRC BIVC-1).
   Program the sensor first (two lanes, RAW10, the HS clock continuous or `NONCONT_CLOCK`), then set `RX_FILTER`, `PHASE`, gains, green equalisation and `RX_TAPS` and let the sensor stream. `PHASE` is the Bayer arrangement of the sensor mode after any flip, mirror and window offset:
   a wrong phase swaps red and blue (phase 0 against 3) or gives a pink or violet picture (phases 1 and 2); check it on a picture with a known colour.
5. Map the 4 KiB window and call `rtlnet_csi2_rx_probe`. `camera mode`, `camera source` and `camera rate` of the firmware CLI go through the driver.

---

## 11. Limitations

- Hardware evidence exists for one board, one sensor module and one lane configuration (section 12). Not measured: other boards, sensors and cables, temperature and supply variation, the non-continuous clock mode
  on a real sensor (`NONCONT_CLOCK` = 1), the behaviour after the HS clock stops on a real sensor (the sensor is never stopped while streaming in the measurements), a single-lane sensor (lane enable 1), the LP receiver thresholds on another resistor network,
  and the burst-end hold of 4 byte clocks against other primitive latencies (it needed no change on the Zybo).
- The two greens of the Pcam 5C differ by about 8 percent in the binned 720p mode; the core equalises them with `PROC.GREEN_EQ` at the cost of a slightly softer green at the G sites; no other sensor was looked at.
- Two data lanes (or lane 0 alone); one packet per HS burst; RAW10 only (the data type register selects which type is read as RAW10).
- Lane skew up to three byte clocks is removed; a bigger skew drops the burst (`SOT`).
- A packet that is short by fewer than about 16 bytes is counted as a CRC error instead of a truncation.
- A CRC error does not drop the line: its pixels are used.
- Two modes (720p30, 1080p30); other modes are later `VIDEO_MODE` values. Change `VIDEO_MODE` while the camera does not stream.
- White balance gains reset to 1.0; the core carries no value for a sensor or a light source (the Zybo firmware loads gains per sensor mode, section 12).
- `k` restarts on a `VIDEO_MODE` change as well as on a `PATTERN` write (one set of running registers); the box phase must lie inside the frame (192, 96 are inside both modes).
- The pattern models are exact for k below 2^32 (4.5 years at 30 fps); the counter then wraps and the sequence restarts from the running values.
- A camera frame that is cut off by the switch is closed short; `FRAME_COUNT` and the timestamp wrap at 32 bits.

---

## 12. Board measurements (Digilent Zybo Z7-20, Pcam 5C, 11-15-2026)

Design `own6` of `boards/zybo_z7_20` with firmware `fw16` (the counters and the stream were repeated on `own7` with `fw18`, which adds the highlight clamp: 720p 30.04 fps, 1080p 30.00 fps over 60 s, every error counter 0), one board on a direct PC USB port, one Pcam 5C (OV5640, two lanes, RAW10, continuous HS clock, 420 Mb/s per lane at 1080p and
280 Mb/s at 720p), a lit room scene, room temperature. Everything below is measured unless marked.

| Item | Result |
|---|---|
| Lane order and bit order | `RX_CTRL.BIT_REV` 0 is right (the receiver locked at the first start); the sync byte is found on both lanes in every burst |
| Counters over 60 s, 720p | `FRAMES` 1,808 (30.03 fps), `ECC_UNC` 0, `CRC` 0, `SOT` 0, `SIZE` 0, `DT` 0, `TRUNC` 0, `OVF` 0, `ORPHAN` 0, `LEN` 0, `CLKLOSS` 0, `ECC_CORR` 0; `RX_LINES` 720, `RX_PIXELS` 1,280 |
| Counters over 60 s, 1080p | `FRAMES` 1,806 (29.99 fps), all error counters and `ECC_CORR` 0; `RX_LINES` 1,080, `RX_PIXELS` 1,920 |
| Bayer arrangement | the OV5640 tables with the board's flip, mirror and window offset deliver the arrangement `PHASE` 3 (BGGR); `PHASE` 0 swaps red and blue, 1 and 2 give a pink and a violet picture |
| Green imbalance | green level of the four pixel parities (x, y) = (0,0), (1,0), (0,1), (1,1) of a flat wall in the decoded picture: 190 / 201 / 178 / 190 (a two-pixel pattern of +-6 percent) without `GREEN_EQ`, 188.2 / 187.9 / 188.5 / 188.3 with it |
| White balance | gains per mode (4.8 fixed point): 720p R 0x163, G 0x100, B 0x163; 1080p R 0x195, G 0x100, B 0x17C; neutral wall, ceiling lamp and bezel R:G:B within about 5 percent (R/G 0.97 to 1.02 at 720p, 1.00 to 1.01 at 1080p; B/G 0.93 to 1.09) after; before (gains 1.0) R and B 14 to 18 percent below G |
| Black level | `BLACK` 0; raising it only darkens the picture (32 and 64 measured), the dark areas stay red-brown (sensor and scene) |
| IDELAY window | section 12.1 |

### 12.1 D-PHY capture margin

`boards/zybo_z7_20/scripts/rx_test.ps1 -Action sweep`: the stream runs, at each IDELAY tap (78 ps at the 200 MHz reference) `RX_TAPS` is written, the counters are cleared and read 3 s later. A tap is clean when `ECC_UNC`, `CRC`, `SOT`,
`SIZE`, `ORPHAN`, `LEN`, `TRUNC`, `OVF` and `DT` stay 0, `CLKLOSS` is 0 and the frame rate is within 1 fps of the sensor. Both lanes at the same tap:

| Mode | Clean taps | Window | First tap with errors | Taps with errors | Next clean taps |
|---|---|---|---|---|---|
| 720p30 (280 Mb/s, UI 3.57 ns) | 0 to 29 | 30 taps, 2,340 ps (lower edge below tap 0) | 30 (`CRC` 27,997 and `SOT` 229 in 3 s) | 30, 31 | none to tap 31 |
| 1080p30 (420 Mb/s, UI 2.38 ns) | 0 to 21 | 22 taps, 1,716 ps (lower edge below tap 0) | 22 (`CRC` 35, `ECC_CORR` 11) | 22 to 26 | 27 to 31 (the next bit period) |

The errors at taps 23 to 25 at 1080p are a burst of lost headers and sync bytes (`SOT` 166,558 to 310,485, `ECC_UNC` up to 103,537, `FRAMES` between 0 and 55 per second); at taps 22 and 26 single bits fail. One bit period at
420 Mb/s is 30.5 taps, so the clean taps 27 to 31 are the next eye and the error band repeats every 30.5 taps: the band at 22 to 26 has its previous occurrence at about -9 to -4, which puts the clean region at taps -4 to 21 and its
centre at about tap 9; only the part from 0 is measured. Independent lanes (the other lane at tap 10):

| Mode | Lane 0 clean taps | Lane 0 error taps | Lane 1 clean taps | Lane 1 error taps |
|---|---|---|---|---|
| 720p30 | 0 to 30 (31 taps, 2,418 ps) | 31 | 0 to 29 (30 taps, 2,340 ps) | 30, 31 |
| 1080p30 | 0 to 22 (23 taps, 1,794 ps) | 23 to 26 | 0 to 21 (22 taps, 1,716 ps) | 22 to 25 |

The lanes differ by about one tap (78 ps) in skew: lane 1 sees its eye edge one tap earlier.

Default taps: lane 0 at 11 and lane 1 at 10, the centres of the measured 1080p windows of the lanes (0 to 22 and 0 to 21). At 1080p the distance to the upper edge is 11 and 12 taps (about 0.9 ns) and the measured distance to tap 0 is the same,
so the default sits between the measured edge and the extrapolated lower edge within about two taps.

What this does and does not prove. The static timing of the two HS samplers (setup +0.58 and +0.62 ns met, hold -1.39 and -1.43 ns failed at the tap attribute 0) cannot be closed by any tap (the tap loaded at run time is unknown to static timing) and is the named deviation `DPHY_HS_INPUT` of the
build. The measurement shows that this board samples both lanes correctly over at least 22 taps (1.7 ns) of a 2.38 ns bit period at 420 Mb/s and over at least 30 taps at 280 Mb/s, with 0 errors in 3 s per tap (about 10^9 bits per lane per tap) and in the 60 s counter runs and the 112 s soak at the default taps.
It is not a closure of the static model, not a statistical error rate (no bit error rate below 10^-9 is claimed), and not a margin over temperature, supply, board and cable variation: one unit, one cable, one room temperature, one sensor module.
