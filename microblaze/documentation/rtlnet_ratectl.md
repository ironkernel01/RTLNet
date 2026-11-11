# rtlnet_ratectl: H.264 rate control (Phase 2d)

Copyright (C) 2026 IronKernel. All rights reserved.

Revision: 11-10-2026

## 1. Purpose

`microblaze/firmware/src/video/rtlnet_ratectl.{h,c}` picks one QP per picture for the two-engine H.264 encoder. It is pure C: no
hardware access, no floating point (fixed point), no dynamic allocation, so `microblaze/firmware/host/test_ratectl.c` drives it on
the host with a synthetic encoder model. `rtlnet_venc.c` owns one instance and calls it twice per picture:

| Moment | Call | Data |
|---|---|---|
| start of a picture, after its type is decided | `ratectl_pick(rc, is_idr, gop)` | the QP written to the core |
| end of a picture, in `mux_picture` | `ratectl_picture_done(rc, is_idr, qp, bits, dt90)` | the coded size in bits (the picture entry lengths of every engine plus the SPS and PPS of an IDR picture), the QP read back from the core, the stream time since the previous picture in 90 kHz ticks (more than one period after a dropped picture) |

The target is the elementary stream rate (coded picture bits). The MPEG-TS stream carries about 3 % more (188-byte packets, PES headers,
PCR, PAT and PMT; `show stream` prints both).

## 2. Design

### 2.1 Modes

* **Constant QP** (target 0, the reset state): `ratectl_pick` returns the QP of `encoder qp` for every picture. Nothing else changes with
  respect to Phase 2c; the statistics and the seconds ring still run.
* **Constant bit rate** (`encoder bitrate <kbps>`): the target in kb/s with a virtual buffer, a leaky bucket of `target x buffer_ms / 1000`
  bits (default 500 ms, 100 to 2000). The buffer receives the bits of each picture and drains at the target rate over the stream time
  of the picture. The controller steers the fill to a set point of 30 % of the buffer.

### 2.2 Size model

The size of a picture of type t at QP q is `2^(K_t - q/6)` bits: one QP step is 12 % in size, six steps halve it. K_t is kept in the log domain
(Q8, `log2(bits) + q/6`) for the I and the P type separately.

* P picture done: `K_p += (K_obs - K_p) / 2`; the I model follows by a quarter of that step (`K_i += dK_p / 4`), so a scene change moves the
  estimate of the next IDR picture although IDR pictures are rare.
* IDR picture done: `K_i += 3/4 (K_obs - K_i)`.
* The first picture of a stream and every change of mode or frame period start from the target bits per pixel: initial QP
  `14 - 6 log2(bits per pixel)` (0.036 bit/pixel at 720p30 and 1000 kb/s gives QP 43), K_p such that a GOP of one I picture (6 x P) and
  GOP - 1 P pictures averages the budget, K_i = K_p + log2 6.

`log2` and `2^x` are computed in Q8 by bit-wise squaring (eight constants), the sums in 64 bit.

### 2.3 QP of the next picture

1. **Horizon** H pictures: one second or one GOP, whichever is longer, at most two seconds (30 pictures at 30 fps with GOP 30 or GOP 1, 60 with
   GOP 255).
2. The next H pictures are typed from the GOP position (the next picture's type is given, the controller counts the pictures since the last IDR
   picture): `n_I` of them are IDR pictures, `n_P = H - n_I` P pictures. With the model they cost `S x 2^(-q/6)` bits at one QP q, with
   `S = n_I 2^K_i + n_P 2^K_p`.
3. Budget of the horizon: `B = H x bits_per_picture + set point - fill`, at least a quarter of `H x bits_per_picture`.
4. Solve `S x 2^(-q/6) = B` for q (Q8). One QP for the I and the P pictures keeps the I picture at its natural size ratio, so a 30-picture GOP
   does not oscillate; the buffer absorbs the I picture and the P pictures drain it again before the next one.
5. Clamp to the QP range (12 to 51; `encoder qprange` narrows it), limit to +-2 from the previous picture's QP, and round to an integer with
   error feedback (the rounding error of each picture goes into the next), so the average QP over many pictures is the fractional solution.

The first term of the budget is the rate target, the second a proportional correction of the fill with the time constant of H pictures.

### 2.4 Overflow and underflow

The controller never drops a picture. When the fill after a picture exceeds the buffer, `overflow` counts, `overflow_below_max` counts when
the picture's QP was below the range maximum, and the fill saturates at 100 %. At QP 51 an overflow is the content being too complex for the
link, and the counter is the report. When the drain exceeds the fill (static content at the minimum QP), `underflow` counts and the fill stays at 0;
the stream is then below the target, which is allowed.

### 2.5 What the controller cannot do

A picture that is far larger than the model predicts and arrives with a nearly full buffer overflows whatever the controller does: the QP moves by
at most 2 per picture, and a P picture of a scene cut costs several buffer periods' worth only on the first picture. An IDR picture at the
exact picture of a 4x noise burst (6 x 4 = 24 P-picture equivalents at once) is such a case (section 7, informational lines). The counters show it.

## 3. Parameters

| Parameter | Default | Range | CLI |
|---|---|---|---|
| target | 0 (constant QP) | 0..100000 kb/s | `encoder bitrate` |
| buffer | 500 ms | 100..2000 ms | `encoder buffer` |
| QP range | 12..51 | 12 <= min <= max <= 51 | `encoder qprange` |
| constant QP | 28 | 0..51 (driver writes at least 12) | `encoder qp` |
| GOP | 30 | 1..255 | `encoder gop` |
| fill set point | 30 % | constant `RATECTL_FILL_SETPOINT_PCT` | none |
| QP step | 2 | constant `RATECTL_QP_STEP_MAX` | none |

A change is effective at the next picture and forces no IDR picture (the slice QP of a P picture is free; the rule "no P picture across a QP change"
of Phase 2c is removed from `rtlnet_venc.c`). The IDR rules that remain: a stream start, a dropped picture, a mode change, an encoder error,
a timeout and a mux failure.

## 4. Measurement

The ring holds one 8-byte record per second of stream time (stream time is the PTS time base, so it follows the capture clock):

| Field | Size | Content |
|---|---|---|
| `bits` | 4 bytes | coded bits of the pictures finished in that second (= the bit rate) |
| `qp_q4` | 2 bytes | mean QP x 16 |
| `fill_pct` | 1 byte | buffer fill at the end of the second, 0..100 (0 in constant QP mode) |
| `pics` | 1 byte | pictures finished in that second |

`RATECTL_HISTORY_SECONDS` is 3600 records: **28,800 bytes**. It lives in the LMB (`.bss` of `rtlnet_venc.o`, symbol `g_rc`, 28,944 bytes with the controller
state), not in DDR3: the LMB is uncached, so the firmware writes it without cache maintenance and the host build shares the code, and 29 KiB fits.
Budget of the build of record (`build.ps1`, 11-10-2026): `_end` is at 0x67020 = 412.0 KiB of the 512 KiB LMB (text 146,276 B, data 1,128 B, bss 311,360 B of which the
36,864 B of the AXI BRAM section are not in the LMB), 100 KiB free; before Phase 2d the image ended at 374 KiB (the controller and the CLI add 10 KiB
of code and the 28.9 KiB of `g_rc`).

`show stream` and `show encoder` read: the mode and target; the rate over the last second (the newest record) and over the last ten seconds (mean of the
newest ten); the buffer fill with the minimum and the maximum since `clear counters`; the QP of the last picture and its minimum, average and
maximum since clear; the overflow count (with the count below the QP maximum) and the underflow count; the test pattern and its speed.
`clear counters` clears the statistics and the ring.

## 5. CLI

Defined in `microblaze/firmware/cli/cli_commands.txt` (MenuBuilder hierarchy; `gen_menu.py` regenerates the tables, `check_menu.py` checks them).

| Command | Mode | Action |
|---|---|---|
| `encoder bitrate <kbps>` | priv | target 0..100000 kb/s, 0 = constant QP |
| `encoder buffer <ms>` | priv | virtual buffer 100..2000 ms |
| `encoder qprange <min> <max>` | priv | QP range |
| `camera pattern <bars|scroll|box|noise|all> [speed]` | priv | test pattern content, speed -32..32 (default 4, 0 = still); calls `rtlnet_csi2_rx_set_pattern(base, pattern, speed)` with `RTLNET_CSI2_PATTERN_BARS 0`, `_SCROLL 1`, `_BOX 2`, `_NOISE 3`, `_ALL 4` |
| `show encoder history [n]` | exec | the last n seconds of the ring (default 20, at most 3600), oldest first: age, bits per second, mean QP, fill, pictures |
| `show stream`, `show encoder` | exec | the rate-control lines of section 4 |

While `cores/rtlnet_csi2_rx/driver/rtlnet_csi2_rx.h` has no `RTLNET_CSI2_PATTERN_ALL`, `cli_commands.c` compiles a stub of the same signature that refuses
("The CSI-2 driver has no moving test patterns in this build"); once the driver header defines the constants and the function, the stub is not compiled and the
command calls the driver.

## 6. Host test

`microblaze/firmware/host/test_ratectl.c`, built and run by `build.ps1 -RatectlTest` and as part of `build.ps1 -Demo`; log `microblaze/firmware/build/ratectl_test.log`
(the whole `-Demo` run is in `microblaze/firmware/build/phase2d_build_demo.txt`). The synthetic encoder: `bits = complexity x 2^((34 - QP)/6) x (1 + noise)`, noise uniform within +-10 %
(fixed-seed generator), an IDR picture 6 x a P picture at equal QP (4 x and 8 x also run for constant motion), 2700 pictures (90 s) per run at 30 fps. Sequences: static (0.02 of
the moderate complexity), constant moderate motion (equilibrium QP 34), a 3 s noise burst of 4 x complexity from t = 20.5 s, a scene cut to 3 x complexity at t = 30.5 s, ramps
(0.5 to 3 x and back over 60 s). Cases: 720p30 at 1000 kb/s, 1080p30 at 2000 kb/s, 720p30 at 300 kb/s, each with GOP 30 and GOP 1: 30 runs, 18 more for the IDR ratios,
plus a saturation run (40 x complexity at 300 kb/s), a constant QP run and a ring-wrap run (3700 s).

The burst and the cut start half a second after an IDR picture: an event that coincides with the IDR picture is a single picture of 18 to 24 times the average and overflows the 500 ms buffer
at any QP the +-2 limit allows; it is run as an informational line, not gated.

## 7. Host results

| Gate | Result | Log line |
|---|---|---|
| 1 s windows within +-10 % after the first 2 s, constant motion (sliding 30-picture windows, all cases, IDR 4 x, 6 x, 8 x) | worst 6.27 % (720p30 300 kb/s, GOP 30, IDR 8 x P) | `PASS: 1 s windows within +-10 % ...` |
| 10 s windows within +-3 % after the first 2 s, constant motion (sliding 300-picture windows) | worst 0.72 % (720p30 1000 kb/s, GOP 30, IDR 8 x P) | `PASS: 10 s windows within +-3 % ...` |
| Buffer never overflows below QP_MAX and never leaves 0..100 % (30 runs) | 0 overflows below the maximum | `PASS: buffer never overflows ...` |
| QP changes by at most 2 per picture, stays within 12..51 (every picture of 30 runs) | 0 step violations, 0 range violations | `PASS: QP changes by at most 2 ...` |
| Static content settles at QP_MIN with underflow reported | 0 pictures off QP 12 in the last 5 s, underflow reported in all 6 runs | `PASS: static content settles ...` |
| Recovery after the noise burst and the scene cut: every later 1 s window within +-10 % | within 1.43 s of the event, worst case (720p30 1000 kb/s, GOP 1, cut) | `PASS: recovery after the noise burst ...` |
| Constant QP mode unchanged | 2700 of 2700 pictures at the configured QP, no buffer figures, the QP passes through (the driver clamps to 12) | `PASS: constant QP unchanged ...`, `PASS: constant QP: the value is passed through ...` |
| Saturation: QP pins at 51, overflow counted, the controller keeps running | QP stays at 51 once reached, 2700 overflows, 0 below the maximum | `PASS: saturation ...` |
| History ring: 3600 records of 8 bytes wrap correctly; per-second records equal the pictures they cover | 28,800 bytes; 0 mismatches in 30 runs | `PASS: history ring ...`, `PASS: per-second record matches ...` |

Mean rates of the 30 runs are within 0.3 % of the target for every constant-motion run (for example 999.4 kb/s at 1000 kb/s, 299.7 kb/s at 300 kb/s). The fill range in constant motion with
GOP 30 is 8 to 62 % (the I picture is the rise, the P pictures the fall); the burst reaches 98 % at 300 kb/s and 92 % at 1000 kb/s without overflow.
Informational lines: a burst or a cut that starts on the IDR picture overflows 6 and 5 pictures (720p30 1000 kb/s, GOP 30): the counters report it.

## 8. Not covered by the host test

The real encoder deviates from `2^(-q/6)` (size falls more slowly at high QP, tiny P pictures have a floor of a few dozen bytes); the feedback on the buffer corrects the
remainder, and the one-hour soak on the board measures it. The test pattern command depends on the other agent's driver function. Per-row `mb_qp_delta`
inside a picture is not part of this phase.
