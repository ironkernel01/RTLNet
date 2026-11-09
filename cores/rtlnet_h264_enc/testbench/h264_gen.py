#!/usr/bin/env python3
"""
File: h264_gen.py
Purpose: generate the input frames of the rtlnet_h264_top harness: a packed YUYV 4:2:2 memory image
  ($readmemh format) and the reference 4:2:0 planar YUV of the same picture.
Overview:
  * Run as: python -I h264_gen.py --pattern bars|gradient|noise|zeros|square --w 176 --h 144 [--frame N]
      [--seed S] --out <prefix>
    Writes <prefix>.hex and <prefix>_ref.yuv.
  * Memory image: one 128-bit word per line (32 hex digits, byte 15 first, so byte 0 is the last pair of
    digits), as read by $readmemh into a 128-bit array. Byte order inside a line of pixels: Y0 U0 Y1 V0
    (packed YUYV), 2 bytes per pixel, line stride w * 2 bytes.
  * Reference 4:2:0: the source chroma is 4:2:2 (one U and one V per horizontal pixel pair); each 4:2:0 chroma
    sample is (a + b + 1) >> 1 of the two vertically adjacent 4:2:2 samples (rows 2r and 2r+1), the rounding
    the encoder's read DMA applies. Output order: Y plane, U plane, V plane, 8 bits.
  * Patterns: bars (75 % colour bars, BT.601), gradient (diagonal luma ramp, chroma ramps in x and y, so
    the vertical chroma average matters), noise (seeded pseudo-random, all values 0..255 including 0 and
    the emulation-prevention range), zeros (seeded, about 80 % zero bytes and many values 1..3, so the stream holds
    long zero runs and emulation prevention fires often), square (a 64x64 square that moves 8 pixels per frame, frame N).
Revision: 11-09-2026
  * 11-09-2026: initial version.
"""
import argparse
import sys

BARS = [  # 75 % bars, BT.601 limited range (Y, Cb, Cr)
    (180, 128, 128), (162, 44, 142), (131, 156, 44), (112, 72, 58),
    (84, 184, 198), (65, 100, 212), (35, 212, 114), (16, 128, 128),
]


def lcg(seed):
    state = seed & 0xFFFFFFFF
    while True:
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        yield (state >> 16) & 0xFF


def make_planes(pattern, w, h, frame, seed):
    """Return (Y rows, U rows, V rows) with 4:2:2 chroma (w // 2 samples per row)."""
    ys, us, vs = [], [], []
    if pattern == "noise":
        rng = lcg(seed)
        for _ in range(h):
            ys.append(bytes(next(rng) for _ in range(w)))
            us.append(bytes(next(rng) for _ in range(w // 2)))
            vs.append(bytes(next(rng) for _ in range(w // 2)))
        return ys, us, vs
    if pattern == "zeros":
        rng = lcg(seed)

        def zb():
            v = next(rng)
            return 0 if v < 200 else ((v & 3) if v < 225 else v)

        for _ in range(h):
            ys.append(bytes(zb() for _ in range(w)))
            us.append(bytes(zb() for _ in range(w // 2)))
            vs.append(bytes(zb() for _ in range(w // 2)))
        return ys, us, vs
    if pattern == "bars":
        row_y = bytearray(w)
        row_u = bytearray(w // 2)
        row_v = bytearray(w // 2)
        for i, (y, cb, cr) in enumerate(BARS):
            x0 = ((w * i) // 8) & ~1
            x1 = ((w * (i + 1)) // 8) & ~1 if i < 7 else w
            row_y[x0:x1] = bytes([y]) * (x1 - x0)
            row_u[x0 // 2:x1 // 2] = bytes([cb]) * ((x1 - x0) // 2)
            row_v[x0 // 2:x1 // 2] = bytes([cr]) * ((x1 - x0) // 2)
        for _ in range(h):
            ys.append(bytes(row_y))
            us.append(bytes(row_u))
            vs.append(bytes(row_v))
        return ys, us, vs
    if pattern == "gradient":
        for y in range(h):
            ys.append(bytes(((x * 255 // (w - 1)) + (y * 255 // (h - 1))) // 2 for x in range(w)))
            us.append(bytes(32 + (x * 191) // (w // 2 - 1) for x in range(w // 2)))
            vs.append(bytes((255 - (y * 255) // (h - 1)) for _ in range(w // 2)))
        return ys, us, vs
    if pattern == "square":
        sx = 8 * frame
        sy = (h - 64) // 2
        for y in range(h):
            row_y = bytearray(((x // 8) + (y // 8)) % 2 * 16 + 40 for x in range(w))
            row_u = bytearray([110] * (w // 2))
            row_v = bytearray([140] * (w // 2))
            if sy <= y < sy + 64:
                for x in range(sx, min(w, sx + 64)):
                    row_y[x] = 235
                for x in range(sx // 2, min(w // 2, (sx + 64) // 2)):
                    row_u[x] = 90
                    row_v[x] = 240
            ys.append(bytes(row_y))
            us.append(bytes(row_u))
            vs.append(bytes(row_v))
        return ys, us, vs
    raise SystemExit("unknown pattern " + pattern)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pattern", required=True)
    ap.add_argument("--w", type=int, required=True)
    ap.add_argument("--h", type=int, required=True)
    ap.add_argument("--frame", type=int, default=0)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    w, h = a.w, a.h
    if w % 16 or h % 16 or (w * 2) % 32:
        raise SystemExit("w and h must be multiples of 16 (macroblock), line stride a multiple of 32")
    ys, us, vs = make_planes(a.pattern, w, h, a.frame, a.seed)
    with open(a.out + ".hex", "w", newline="\n") as f:
        for y in range(h):
            row = bytearray(w * 2)
            row[0::4] = ys[y][0::2]
            row[1::4] = us[y]
            row[2::4] = ys[y][1::2]
            row[3::4] = vs[y]
            for i in range(0, len(row), 16):
                f.write(bytes(row[i:i + 16][::-1]).hex() + "\n")
    with open(a.out + "_ref.yuv", "wb") as f:
        for y in range(h):
            f.write(ys[y])
        for plane in (us, vs):
            for r in range(h // 2):
                f.write(bytes((p + q + 1) >> 1 for p, q in zip(plane[2 * r], plane[2 * r + 1])))
    print("wrote", a.out + ".hex", a.out + "_ref.yuv")


if __name__ == "__main__":
    sys.exit(main())
