#!/usr/bin/env python3
"""
File: h264_gen.py
Purpose: generate the input frames of the rtlnet_h264_top harness: a packed YUYV 4:2:2 memory image
  ($readmemh format) and the reference 4:2:0 planar YUV of the same picture.
Overview:
  * Run as: python -I h264_gen.py --pattern <name> --w 176 --h 144 [--frame N]
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
  * Textured patterns (deterministic from --seed, standard library only): gradnoise (diagonal gradient plus noise of
    about +-12 in luma and +-8 in chroma), zoneplate (luma 128 + 120 cos(k r^2) around the picture centre with the local
    frequency reaching 0.9 pi at the corners, chroma slow ramps), edges (horizontal steps, diagonal stripes, a rotated
    rectangle, 1 and 2 pixel lines, high contrast), checker (0/255 and mid-gray checkerboards with cell sizes 1, 2, 4,
    8 and 16 in separate regions), photo (smooth synthetic photo: low-frequency sinusoids and soft blobs with a
    vignette, one soft horizon, film grain sigma about 2, smooth chroma with a hue drift).
Revision: 11-09-2026
  * 11-09-2026: initial version; textured patterns for the intra 16x16 phase.
"""
import argparse
import math
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


def clamp8(v):
    return 0 if v < 0 else (255 if v > 255 else int(v))


def noise_rows(rng, n, amp):
    """n values in -amp..amp from the LCG."""
    return [((next(rng) * (2 * amp + 1)) >> 8) - amp for _ in range(n)]


def pat_gradnoise(w, h, seed):
    ys, us, vs = [], [], []
    rng = lcg(seed)
    cw = w // 2
    for y in range(h):
        nz = noise_rows(rng, w, 12)
        base = y * 255 // (h - 1)
        ys.append(bytes(clamp8(((x * 255 // (w - 1)) + base) // 2 + nz[x]) for x in range(w)))
        nu = noise_rows(rng, cw, 8)
        nv = noise_rows(rng, cw, 8)
        us.append(bytes(clamp8(32 + (x * 191) // (cw - 1) + nu[x]) for x in range(cw)))
        vs.append(bytes(clamp8(255 - base + nv[x]) for x in range(cw)))
    return ys, us, vs


def pat_zoneplate(w, h):
    ys, us, vs = [], [], []
    cw = w // 2
    rmax = math.hypot(w, h) / 2.0
    k = 0.9 * math.pi / (2.0 * rmax)
    cx, cy = w / 2.0, h / 2.0
    cxs = [math.cos(k * (x - cx) ** 2) for x in range(w)]
    sxs = [math.sin(k * (x - cx) ** 2) for x in range(w)]
    for y in range(h):
        cyv = math.cos(k * (y - cy) ** 2)
        syv = math.sin(k * (y - cy) ** 2)
        ys.append(bytes(clamp8(128 + 120 * (cxs[x] * cyv - sxs[x] * syv)) for x in range(w)))
        us.append(bytes(clamp8(64 + (x * 128) // (cw - 1) + y // 8) for x in range(cw)))
        vs.append(bytes(clamp8(192 - (x * 96) // (cw - 1) - y // 8) for x in range(cw)))
    return ys, us, vs


def pat_edges(w, h):
    ys, us, vs = [], [], []
    cw = w // 2
    sx = w / 176.0
    sy = h / 144.0
    ang = math.radians(30)
    ca, sa = math.cos(ang), math.sin(ang)
    rcx, rcy = 0.7 * w, 0.35 * h
    hw, hh = 0.14 * w, 0.09 * h
    stripe = max(2, int(3 * sx))
    crow = max(4, int(8 * sy))
    cb_tab = (60, 200, 128, 90, 180, 128, 40, 220)
    cr_tab = (200, 60, 128, 170, 70, 128, 220, 40)
    for y in range(h):
        row = bytearray(w)
        for x in range(w):
            if x < w // 4:
                v = 40 if (y * 5 // h) % 2 == 0 else 220
            elif x < w // 2:
                v = 235 if ((x + y) // stripe) % 2 == 0 else 20
            else:
                v = 90
            if y > 2 * h // 3:
                if (x % 29) == 0:
                    v = 255
                elif (x % 37) in (0, 1):
                    v = 0
                elif (y % 17) == 0:
                    v = 250
            dx, dy = x - rcx, y - rcy
            u = dx * ca + dy * sa
            t = -dx * sa + dy * ca
            if abs(u) < hw and abs(t) < hh:
                v = 250 if v < 128 else 10
            row[x] = v
        ys.append(bytes(row))
        odd = (y // crow) % 2 == 0
        us.append(bytes(cb_tab[x * 2 * 8 // w] for x in range(cw)))
        vs.append(bytes(cr_tab[x * 2 * 8 // w] if odd else 128 for x in range(cw)))
    return ys, us, vs


def pat_checker(w, h):
    ys, us, vs = [], [], []
    cw = w // 2
    for y in range(h):
        row = bytearray(w)
        gray = ((y // max(1, h // 4)) % 2) == 1
        for x in range(w):
            reg = x * 5 // w
            size = (1, 2, 4, 8, 16)[reg] if y < h // 2 else (16, 8, 4, 2, 1)[reg]
            on = ((x // size) + (y // size)) & 1
            row[x] = (200 if on else 56) if gray else (255 if on else 0)
        ys.append(bytes(row))
        us.append(bytes((((x // 4) + (y // 4)) & 1) * 120 + 68 for x in range(cw)))
        vs.append(bytes((((x // 2) + (y // 2)) & 1) * 100 + 78 for x in range(cw)))
    return ys, us, vs


def pat_photo(w, h, seed):
    ys, us, vs = [], [], []
    rng = lcg(seed)
    cw = w // 2
    ph = [(seed * 0.37 + i * 1.3) for i in range(4)]
    fx = [2.0, 3.7, 6.1, 9.3]
    fy = [1.6, 2.9, 5.3, 8.1]
    amp = [14.0, 8.0, 4.5, 2.5]
    sinx = [[math.sin(2 * math.pi * fx[i] * x / w + ph[i]) for x in range(w)] for i in range(4)]
    cosy = [[math.cos(2 * math.pi * fy[i] * y / h + ph[3 - i]) for y in range(h)] for i in range(4)]
    blobs = [(0.25, 0.35, 0.12, 0.10, 45.0), (0.7, 0.55, 0.16, 0.2, -38.0), (0.5, 0.8, 0.2, 0.08, 30.0),
             (0.85, 0.25, 0.06, 0.05, 40.0)]
    nb = len(blobs)
    bx = [[math.exp(-((x / w - b[0]) ** 2) / (2 * b[2] ** 2)) * b[4] for x in range(w)] for b in blobs]
    by = [[math.exp(-((y / h - b[1]) ** 2) / (2 * b[3] ** 2)) for y in range(h)] for b in blobs]
    vgx = [1.0 - 0.35 * ((x / w - 0.5) * 2) ** 2 for x in range(w)]
    hor = int(0.45 * h)
    for y in range(h):
        vy = 1.0 - 0.25 * ((y / h - 0.5) * 2) ** 2
        sky = 175.0 - 55.0 * y / h
        ground = 95.0 + 40.0 * (y - hor) / h
        hb = 1.0 / (1.0 + math.exp(-(y - hor) / (0.012 * h + 1)))
        base_row = sky * (1 - hb) + ground * hb
        cyt = [amp[i] * cosy[i][y] for i in range(4)]
        byt = [by[j][y] for j in range(nb)]
        g = noise_rows(rng, w, 3)
        g2 = noise_rows(rng, w, 3)
        row = bytearray(w)
        for x in range(w):
            v = (base_row + sinx[0][x] * cyt[0] + sinx[1][x] * cyt[1] + sinx[2][x] * cyt[2] + sinx[3][x] * cyt[3]
                 + bx[0][x] * byt[0] + bx[1][x] * byt[1] + bx[2][x] * byt[2] + bx[3][x] * byt[3])
            row[x] = clamp8(v * vgx[x] * vy + (g[x] + g2[x]) * 0.55)
        ys.append(bytes(row))
        us.append(bytes(clamp8(118 + 22 * math.sin(2 * math.pi * (x / cw * 0.6 + y / h * 0.4)) + 14 * (x / cw - 0.5))
                        for x in range(cw)))
        vs.append(bytes(clamp8(140 - 24 * math.cos(2 * math.pi * (x / cw * 0.5 - y / h * 0.3)) + 18 * (y / h - 0.5))
                        for x in range(cw)))
    return ys, us, vs


def make_planes(pattern, w, h, frame, seed):
    """Return (Y rows, U rows, V rows) with 4:2:2 chroma (w // 2 samples per row)."""
    ys, us, vs = [], [], []
    if pattern == "gradnoise":
        return pat_gradnoise(w, h, seed)
    if pattern == "zoneplate":
        return pat_zoneplate(w, h)
    if pattern == "edges":
        return pat_edges(w, h)
    if pattern == "checker":
        return pat_checker(w, h)
    if pattern == "photo":
        return pat_photo(w, h, seed)
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
