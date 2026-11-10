# rtlnet_csi2_rx — CSI-2 capture core, Phase 1: color bars and source switch

| Item | Value |
|---|---|
| Core | `rtlnet_csi2_rx` |
| Document revision | 11-09-2026 |
| Language | SystemVerilog-2012 (RTL, benches), C11 (driver, C model) |
| Position | video source of the camera design (`documentation/gige.md` sections 5.1, 5.4) |
| Register map revision | `VERSION` = `0x11092026`, `ID` = `0x43534932` ("CSI2") |
| Phase | Phase 1: register block, 75 % color-bar generator, source switch. The camera front end (D-PHY capture, CSI-2 decode, SCCB, lane calibration) is Phase 3 and joins through the camera stream port |
| Verification | Active-HDL 11.1: `tb_rtlnet_csi2_rx` (3 configurations + negative control), `tb_rtlnet_video_path` (with the C model CRC), host driver test, C model self test |
| Synthesis | Vivado 2026.1 out of context, xc7a200tsbg484-1: PASS, 0 critical warnings; 406 LUT, 700 FF, 0 BRAM |

The core sends one YUV422 video stream to `rtlnet_vdma_s2mm`. Today the stream is the color-bar generator: eight static 75 %
bars at 720p30 (register reset default) or 1080p30, so the frame buffer, the encoder and the streaming path run with no
camera. The camera front end (Phase 3) adds a second source behind the same switch; the camera stream port exists and the board
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

Eight vertical bars, full frame height, every line identical, W/8 pixels wide (160 at 720p, 240 at 1080p, 10 and 15
macroblocks, so each edge is on a macroblock boundary). ITU-R BT.709 8-bit limited-range values:

| Bar | Y | Cb | Cr |
|---|---|---|---|
| white 75 % | 180 | 128 | 128 |
| yellow | 168 | 44 | 136 |
| cyan | 145 | 147 | 44 |
| green | 133 | 63 | 52 |
| magenta | 63 | 193 | 204 |
| red | 51 | 109 | 212 |
| blue | 28 | 212 | 120 |
| black | 16 | 128 | 128 |

Both pixels of a word take the bar's Y. The frame bytes are those of `testbench/csi2_bars_model.c` (host gcc), which prints the
CRC-32 (IEEE 802.3, zlib `crc32`) of the packed frame as it lands in DDR3: 720p30 1,843,200 bytes `0x6D3DF810`, 1080p30
4,147,200 bytes `0x8ED9EC2B`.

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
| 0x004 | `VERSION` | RO | 0x11092026 | register map date code |
| 0x008 | `CAPS` | RO | 0x12 | `[3:0]` number of video modes (2), `[4]` test-pattern generator, `[5]` camera front end (0) |
| 0x010 | `VIDEO_MODE` | RW | 0 | `[1:0]` 0 = 720p30, 1 = 1080p30; a value above 1 sets `STATUS.MODE_ERR`; a mode whose minimum period exceeds the present `FRAME_PERIOD` sets `STATUS.PERIOD_ERR`; both leave the register unchanged; effective at the next frame start |
| 0x014 | `SOURCE` | RW | 0 | `[1:0]` 0 = auto, 1 = camera only, 2 = pattern only; 3 and above set `STATUS.SOURCE_ERR` and change nothing |
| 0x018 | `FRAME_PERIOD` | RW | 3,000,000 | `clk` cycles per frame; below the minimum of the selected mode sets `STATUS.PERIOD_ERR` and changes nothing |
| 0x01C | `CAM_TIMEOUT` | RW | 2 | frame periods without a camera frame before auto uses the pattern (0 = auto never uses the camera) |
| 0x020 | `STATUS` | RO, flags W1C | 1 | `[0]` selected source (0 camera, 1 pattern), `[1]` camera byte clock running, `[2]` `MODE_ERR`, `[3]` `PERIOD_ERR`, `[4]` `SOURCE_ERR`, `[5]` `OVERRUN` (flags sticky, write 1 to clear; a new error in the clock of a clear keeps it set) |
| 0x024 | `FRAME_COUNT` | RO | 0 | frames sent, both sources, counted at the first word of a frame |
| 0x028 | `ACTIVE` | RO | 0 | `[1:0]` mode of the frame in progress or the last frame |

Because the mode write checks the period and the period write checks the mode, `FRAME_PERIOD` is never below the minimum of
`VIDEO_MODE`. Driver: `rtlnet_csi2_rx_probe`, `_read_state`, `_set_mode`, `_set_source`, `_set_frame_period`,
`_set_rate_fps` (period = 100,000,000 / fps, fps 1..30), `_mode_width`, `_mode_height`; a rejected write clears its flag
and returns `RTLNET_CSI2_ERR_REJECTED`.

---

## 6. Clocks and crossings

All logic is in `clk` (`ui_clk`): generator, switch, output register and register file. The register window is on
`s_axi_aclk` (`cpu_clk`) behind `rtlnet_axil_cdc` (whole-transaction toggle crossing, constrained by
`scripts/rtlnet_constrain_cdc.tcl`) and `rtlnet_axil_slave`, the pattern of `rtlnet_axi_arbiter`. The core adds one
`rtlnet_axil_cdc` instance to a build (CDC gate: `axil_cdc` +1 per video core). The camera stream and `cam_clk_running` are
inputs already in `clk`; the byte-clock crossing belongs to the Phase 3 front end.

---

## 7. Resources

Vivado 2026.1, out-of-context synthesis, xc7a200tsbg484-1 (`scripts/rtlnet_synth_check.tcl`, `.sim/synth/rtlnet_csi2_rx.log`),
defaults:

| Resource | Used |
|---|---|
| Slice LUT | 406 (0.30 %) |
| Slice register | 700 (0.26 %) |
| Block RAM | 0 |

The register crossing is part of these numbers. The generator has no memory (a bar is eight constants and counters).

---

## 8. Verification

`tb_rtlnet_csi2_rx` (`testbench/regression.txt`, tags `fast`, `fast_gap`, `real`, `neg`) drives the register window through
`rtlnet_tb_axil_master` on a 9.7 ns clock against the 10 ns core clock, with a camera stream model and an output monitor
that checks every word against a reference written in the bench from `gige.md` section 5.4.

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

`tb_rtlnet_video_path` runs the three Phase 1 cores in the board arrangement against the AXI4 memory model: the first
published frame (defaults only) is 1280x720 from the pattern and its slot bytes have the CRC-32 the C model prints for 720p30;
after `VIDEO_MODE` 1 the latest published frame is 1920x1080 with the 1080p30 model CRC; a held slot does not change while two
more frames are published; `FRAMES_OK`, published and dropped counts agree.

Host: `testbench/test_rtlnet_csi2_rx_driver.c` runs the driver against a register model with the rejection rules
(`rtlnet_csi2_rx_driver_test.ps1`); `testbench/csi2_bars_model.c` (`csi2_bars_model.ps1`, self test: its CRC engine returns
0xCBF43926 for "123456789") prints the expected frame CRC-32 values.

Mutation (RTL restored to the identical SHA-256 afterwards): yellow bar Cb 44 changed to 45 in the generator fails
`tb_rtlnet_csi2_rx` (`fast`) at the first yellow word, "pattern word 80 of line 0 (mode 0): 0x88a82da8, expected 0x88a82ca8".

Run: `powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_csi2_rx -Filelist cores/rtlnet_csi2_rx/testbench/tb_rtlnet_csi2_rx.f -Tag <tag> -Defines <defines>`.

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
- The pattern is static; there is no pattern select register.
- A camera frame that is cut off is closed short; the line count of a camera frame is checked against the mode in the DMA,
  the core does not check CSI-2 CRC or ECC (Phase 3).
- `FRAME_COUNT` and the timestamp wrap at 32 bits.
