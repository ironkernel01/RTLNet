#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File: h264_dbk_vec.py
# Purpose: vector generator of the deblocking filter bench (tb_rtlnet_h264_dbk): random and directed pictures of unfiltered rebuilt macroblocks
#   with their per-macroblock information, and the expected filtered tiles from the clause 8.7 model (h264_deblock_model.py).
# Overview:
#   * vec.hex: header words {mbw, mbh, en, alpha_div2, beta_div2, qp}, then per macroblock in raster order 4 information words
#     {x | avt << 8 | intra << 9 | pcm << 10 | t8 << 11, nz16, mvx, mvy} and the 96 words of the rebuilt macroblock bank (luma word 4 y + bx,
#     Cb word 64 + 2 y + bx, Cr word 80 + 2 y + bx; sample 0 in bits 7:0). exp.hex: the 96 words of every filtered tile (tile order).
#   * Kinds of picture: "rand" (smooth content with block offsets and noise so that all filter branches run: bS 1..4, the strong and the weak
#     luma filter, small and large steps, clipping near 0 and 255), "mv" (inter macroblocks, vectors that differ by 0..8 quarter samples: bS 0 below
#     4, bS 1 at 4 and above), "intra" (all intra / I_PCM), "t8" (8x8 transform macroblocks), "slices" (several slices: idc 2 does not filter across).
#   * The slice QP of a picture is qp; an I_PCM macroblock has qP 0.
# Usage: h264_dbk_vec.py --out <prefix> --kind rand --mbw 8 --mbh 6 --seed 1 [--qp N] [--en 1] [--aoff N] [--boff N]
# Language: Python 3. Revision: 11-12-2026
# -----------------------------------------------------------------------------
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import h264_deblock_model as m


def expand_t8(nz8):
    """nz8 = 4 bits (index 2 * by8 + bx8) -> 16 bit mask per 4x4 block."""
    v = 0
    for by in range(4):
        for bx in range(4):
            if (nz8 >> (2 * (by >> 1) + (bx >> 1))) & 1:
                v |= 1 << (4 * by + bx)
    return v


def make_picture(rng, w, h, level, blk, noise, big_every):
    Y = [[0] * w for _ in range(h)]
    # smooth field: a gradient plus a per-4x4 offset
    gx = rng.uniform(-0.6, 0.6)
    gy = rng.uniform(-0.6, 0.6)
    offs = {}
    for y in range(h):
        for x in range(w):
            k = (y // 4, x // 4)
            if k not in offs:
                o = rng.randint(-blk, blk)
                if big_every and rng.randrange(big_every) == 0:
                    o += rng.choice([-60, -30, 30, 60])
                offs[k] = o
            v = level + gx * x + gy * y + offs[k] + rng.randint(-noise, noise)
            Y[y][x] = max(0, min(255, int(round(v))))
    return Y


def gen(args):
    rng = random.Random(args.seed)
    mbw, mbh = args.mbw, args.mbh
    w, h = mbw * 16, mbh * 16
    kind = args.kind
    level = rng.choice([4, 20, 128, 128, 200, 252])
    blk = rng.choice([1, 2, 3, 6, 12, 20])
    noise = rng.choice([0, 1, 2, 4])
    big_every = rng.choice([0, 0, 8, 3])
    planes = [make_picture(rng, w, h, level, blk, noise, big_every),
              make_picture(rng, w // 2, h // 2, level, max(1, blk // 2), noise, big_every),
              make_picture(rng, w // 2, h // 2, level, max(1, blk // 2), noise, big_every)]
    if kind == "step":
        # flat 4x4 blocks of extreme values: steps up to 255 across the edges, flat sides (strong filter, the largest alpha)
        vals = [0, 1, 2, 253, 254, 255, 128, 127]
        for pl in planes:
            hh, ww = len(pl), len(pl[0])
            for by in range(0, hh, 4):
                for bx in range(0, ww, 4):
                    v = rng.choice(vals)
                    for y in range(by, min(by + 4, hh)):
                        for x in range(bx, min(bx + 4, ww)):
                            pl[y][x] = v
    qp = args.qp if args.qp >= 0 else (51 if kind == 'step' else rng.choice([0, 10, 16, 20, 24, 28, 30, 33, 36, 40, 44, 48, 51, rng.randint(0, 51)]))
    en = args.en
    a_off = args.aoff if args.aoff is not None else (6 if kind == 'step' else rng.randint(-6, 6))
    b_off = args.boff if args.boff is not None else (6 if kind == 'step' else rng.randint(-6, 6))
    # slices: whole macroblock rows
    nsl = 1 if kind != "slices" else rng.randint(2, max(2, mbh))
    cuts = sorted(rng.sample(range(1, mbh), min(nsl - 1, mbh - 1))) if mbh > 1 and nsl > 1 else []
    slice_row = []
    s = 0
    for y in range(mbh):
        if y in cuts:
            s += 1
        slice_row.append(s)
    p_intra = {"rand": 0.25, "mv": 0.05, "intra": 1.0, "t8": 0.1, "slices": 0.3, "step": 1.0}[kind]
    p_pcm = 0.1 if kind in ("rand", "intra") else 0.0
    p_t8 = {"rand": 0.2, "mv": 0.0, "intra": 0.0, "t8": 0.7, "slices": 0.2, "step": 0.0}[kind]
    base_mv = (rng.randint(-8, 8), rng.randint(-8, 8))
    info = []
    pcms = []
    for y in range(mbh):
        row = []
        prow = []
        for x in range(mbw):
            intra = 1 if rng.random() < p_intra else 0
            pcm = 1 if (intra and rng.random() < p_pcm) else 0
            t8 = 1 if (not intra and rng.random() < p_t8) else 0
            if kind == "mv":
                nz = 0 if rng.random() < 0.7 else rng.getrandbits(16) & rng.getrandbits(16) & rng.getrandbits(16)
                mvx = base_mv[0] + rng.choice([0, 0, 1, 2, 3, 4, 5, 8, -1, -3, -4, -7])
                mvy = base_mv[1] + rng.choice([0, 0, 1, 2, 3, 4, 5, 8, -2, -3, -4, -9])
            else:
                nz = 0 if rng.random() < 0.4 else rng.getrandbits(16) & rng.getrandbits(16)
                mvx = rng.choice([0, 0, 4, 8, -4, 2, 3]) + base_mv[0]
                mvy = rng.choice([0, 0, 4, -4, 1, 3]) + base_mv[1]
            if intra:
                mvx = mvy = 0
            if t8:
                nz = expand_t8(rng.getrandbits(4) if rng.random() < 0.7 else 0)
            row.append(m.MbInfo(intra=intra | pcm, qp=0 if pcm else qp, nz=nz, t8=t8, mvx=mvx, mvy=mvy))
            prow.append(pcm)
        info.append(row)
        pcms.append(prow)
    # unfiltered words
    words = [mbw, mbh, en, a_off & 15, b_off & 15, qp]
    mbwords = []
    for y in range(mbh):
        for x in range(mbw):
            i = info[y][x]
            avt = 1 if (y > 0 and slice_row[y] == slice_row[y - 1]) else 0
            words += [x | (avt << 8) | (i.intra << 9) | (pcms[y][x] << 10) | (i.t8 << 11), i.nz, i.mvx & 0x3FFF, i.mvy & 0x3FFF]
            mw = []
            for yy in range(16):
                for bx in range(4):
                    px = planes[0][y * 16 + yy][x * 16 + bx * 4:x * 16 + bx * 4 + 4]
                    mw.append(px[0] | (px[1] << 8) | (px[2] << 16) | (px[3] << 24))
            for pl in (1, 2):
                for yy in range(8):
                    for bx in range(2):
                        px = planes[pl][y * 8 + yy][x * 8 + bx * 4:x * 8 + bx * 4 + 4]
                        mw.append(px[0] | (px[1] << 8) | (px[2] << 16) | (px[3] << 24))
            words += mw
    # expected
    import copy
    fp = copy.deepcopy(planes)
    if en:
        m.deblock_picture(fp, mbw, mbh, info, slice_row, idc=2, a_off=a_off, b_off=b_off)
    exp = []
    for y in range(mbh):
        for x in range(mbw):
            for yy in range(16):
                for bx in range(4):
                    px = fp[0][y * 16 + yy][x * 16 + bx * 4:x * 16 + bx * 4 + 4]
                    exp.append(px[0] | (px[1] << 8) | (px[2] << 16) | (px[3] << 24))
            for pl in (1, 2):
                for yy in range(8):
                    for bx in range(2):
                        px = fp[pl][y * 8 + yy][x * 8 + bx * 4:x * 8 + bx * 4 + 4]
                        exp.append(px[0] | (px[1] << 8) | (px[2] << 16) | (px[3] << 24))
    with open(args.out + "_vec.hex", "w") as f:
        f.write("\n".join("%08x" % (v & 0xFFFFFFFF) for v in words) + "\n")
    with open(args.out + "_exp.hex", "w") as f:
        f.write("\n".join("%08x" % v for v in exp) + "\n")
    changed = sum(1 for a, b in zip([v for pl in planes for r in pl for v in r], [v for pl in fp for r in pl for v in r]) if a != b)
    if os.environ.get('DBK_COV'):
        import json
        open(os.environ['DBK_COV'], 'a').write(json.dumps(m.STATS) + chr(10))
    print("kind=%s seed=%d %dx%d qp=%d en=%d a=%d b=%d slices=%d changed_samples=%d" % (kind, args.seed, mbw, mbh, qp, en, a_off, b_off,
                                                                                         max(slice_row) + 1, changed))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--kind", default="rand", choices=["rand", "mv", "intra", "t8", "slices", "step"])
    ap.add_argument("--mbw", type=int, default=6)
    ap.add_argument("--mbh", type=int, default=4)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--qp", type=int, default=-1)
    ap.add_argument("--en", type=int, default=1)
    ap.add_argument("--aoff", type=int, default=None)
    ap.add_argument("--boff", type=int, default=None)
    gen(ap.parse_args())


if __name__ == "__main__":
    main()
