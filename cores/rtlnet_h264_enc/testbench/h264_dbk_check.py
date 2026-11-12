#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File: h264_dbk_check.py
# Purpose: step 1 of the deblocking filter: check h264_deblock_model.py against the decoders. The encoder of the harness work
#   directory (an I picture stream whose slice headers say disable_deblocking_filter_idc 2, rebuilt picture still unfiltered)
#   is decoded by JM, OpenH264 and FFmpeg (the harness writes dec_jm_<n>.yuv, dec_oh_<n>.yuv, dec_ff_<n>.yuv); the model filters
#   rebuilt<n>.yuv (all macroblocks intra, slice QP) and must equal each decoder's picture byte for byte.
# Usage: h264_dbk_check.py --dir <work dir> --w 176 --h 144 --qp 28 [--slices 1] [--engines 1] [--pic 0]
# Language: Python 3. Revision: 11-12-2026
# -----------------------------------------------------------------------------
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import h264_deblock_model as m


def read_planes(path, w, h):
    d = open(path, "rb").read()
    if len(d) < w * h * 3 // 2:
        return None
    Y = [list(d[y * w:(y + 1) * w]) for y in range(h)]
    o = w * h
    U = [list(d[o + y * (w // 2):o + (y + 1) * (w // 2)]) for y in range(h // 2)]
    o += (w // 2) * (h // 2)
    V = [list(d[o + y * (w // 2):o + (y + 1) * (w // 2)]) for y in range(h // 2)]
    return [Y, U, V]


def slice_rows(mbh, engines, slices):
    """Slice number of every macroblock row: bands of ceil(mbh / engines) rows, slices / engines slices per band, the rows of a band
    divided as the engine's sequencer does (d_q rows, the first d_rem slices one more)."""
    per = (mbh + engines - 1) // engines
    spe = slices // engines
    out = []
    n = 0
    for e in range(engines):
        rows = min(per, mbh - e * per)
        if rows <= 0:
            continue
        q, rem = divmod(rows, spe)
        for s in range(spe):
            r = q + (1 if s < rem else 0)
            out += [n] * r
            n += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--w", type=int, required=True)
    ap.add_argument("--h", type=int, required=True)
    ap.add_argument("--qp", type=int, required=True)
    ap.add_argument("--slices", type=int, default=1)
    ap.add_argument("--engines", type=int, default=1)
    ap.add_argument("--pic", type=int, default=0)
    ap.add_argument("--idc", type=int, default=2)
    ap.add_argument("--aoff", type=int, default=0)
    ap.add_argument("--boff", type=int, default=0)
    a = ap.parse_args()
    mbw, mbh = a.w // 16, a.h // 16
    planes = read_planes(os.path.join(a.dir, "rebuilt%d.yuv" % a.pic), a.w, a.h)
    info = [[m.MbInfo(intra=1, qp=a.qp) for _ in range(mbw)] for _ in range(mbh)]
    m.deblock_picture(planes, mbw, mbh, info, slice_rows(mbh, a.engines, a.slices), idc=a.idc, a_off=a.aoff, b_off=a.boff)
    flat = bytearray()
    for pl in planes:
        for r in pl:
            flat += bytes(r)
    ok = True
    for d in ("jm", "oh", "ff"):
        p = os.path.join(a.dir, "dec_%s_%d.yuv" % (d, a.pic))
        if not os.path.exists(p) or os.path.getsize(p) != len(flat):
            print("%s: no decoded picture" % d)
            ok = False
            continue
        dec = open(p, "rb").read()
        if dec == bytes(flat):
            print("%s: model identical" % d)
        else:
            n = sum(1 for x, y in zip(dec, flat) if x != y)
            first = next(i for i, (x, y) in enumerate(zip(dec, flat)) if x != y)
            print("%s: MISMATCH %d bytes, first at offset %d (plane %s)" % (d, n, first, "Y" if first < a.w * a.h else "C"))
            ok = False
    print("TEST PASS: dbk_model_%s" % os.path.basename(a.dir) if ok else "TEST FAIL: dbk_model_%s" % os.path.basename(a.dir))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
