#!/usr/bin/env python3
"""
File: h264_check.py
Purpose: stream assembly and picture comparison of the rtlnet_h264_top decoder harness.
Overview:
  * assemble: turns the bench's dumps into the files the decoders and the comparison use.
      python -I h264_check.py assemble --dir D --prefix D/o --spspps D/sps.bin --pics N --disp-h H [--refs a.yuv b.yuv]
          [--pcm] [--pattern P[,P2] --qp Q --floors FILE] [--measure]
    Reads <prefix>_info.txt, <prefix>_stream.hex, <prefix>_rec<n>.hex. Writes D/stream.264 (SPS + PPS + the
    encoder's Annex B stream), D/rebuilt<n>.yuv (the engine's rebuilt picture n, 4:2:0 planar, cropped to
    the display height) and, when --refs is given, compares each rebuilt picture with the generator's
    reference 4:2:0 picture (cropped the same way).
      - With --pcm (I_PCM macroblock mode) the rebuilt picture must equal the reference exactly: exit code 1 and the
        first differing macroblock on a mismatch.
      - Without --pcm the picture is lossy and is judged by PSNR. It prints
        `PSNR pic<n> Y <dB> Cb <dB> Cr <dB> all <dB>` (display area, rebuilt against the reference) and enforces the
        floor of the pattern/QP pair from the floors file (lines `<pattern> <qp> <floor_dB>`, `#` comments): the
        overall PSNR must be >= the floor, else exit code 1. A pair that is absent from the file is an error, unless
        --measure is given: then a candidate line `FLOOR <pattern> <qp> <value>` is printed (the measured overall PSNR
        minus 1.0 dB, rounded down to 0.1 dB) and the picture passes.
    Always prints `BITS pic<n> <bits>` (the stream bits of the picture: the access unit delimiters split the
    pictures; SPS and PPS are not counted) and `BITS_PER_MB pic<n> <bits per macroblock>`.
  * compare: python -I h264_check.py compare --a X.yuv --b Y.yuv --w W --h H --label NAME
    Byte comparison of two 4:2:0 YUV files (all frames); prints PSNR, and on a mismatch the first differing
    frame, plane and macroblock (x, y); exit code 1 on any difference or size mismatch.
  * Sequences (phase 2c-1): --gop <I/P letters> names the picture types (printed as PTYPE lines, used by --allskip). A single
    --pattern name with several pictures (a sequence: static, pan, ...) applies the floor of (name, qp) to every picture, and
    --measure prints one candidate line with the minimum PSNR over the pictures. --allskip (static scene) requires every P
    picture to be coded as skipped macroblocks only: at most 6 + 24 x --slices stream bytes (the access unit delimiter, and per
    slice the header, mb_skip_run and the trailing bits), and its rebuilt picture byte-identical to the previous picture's.
Revision: 11-10-2026
  * 11-09-2026: initial version; PSNR report and floors, bits per picture, --pcm switch (intra 16x16 phase).
  * 11-10-2026: sequences, --gop, --allskip.
"""
import argparse
import math
import sys


def read_info(path):
    info = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                info[k] = int(v)
    return info


def hex_to_bytes(path):
    out = bytearray()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out += bytes.fromhex(line)[::-1]
    return bytes(out)


def rebuilt_to_yuv(rec, info, disp_h):
    """rec: Y region (ry_size), U region, V region (rc_size each), strides ry_stride / rc_stride."""
    w = info["mbw"] * 16
    h = info["mbh"] * 16
    ry, rcs = info["ry_stride"], info["rc_stride"]
    ysz, csz = info["ry_size"], info["rc_size"]
    y = rec[:ysz]
    u = rec[ysz:ysz + csz]
    v = rec[ysz + csz:ysz + 2 * csz]
    out = bytearray()
    for r in range(disp_h):
        out += y[r * ry:r * ry + w]
    for plane in (u, v):
        for r in range(disp_h // 2):
            out += plane[r * rcs:r * rcs + w // 2]
    return bytes(out), w, h


def first_diff(a, b, w, h):
    if a == b:
        return None
    fsz = w * h * 3 // 2
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            f, off = divmod(i, fsz)
            if off < w * h:
                return "frame %d plane Y mb (%d,%d) pixel (%d,%d) got %d expected %d" % (
                    f, (off % w) // 16, (off // w) // 16, off % w, off // w, b[i], a[i])
            off -= w * h
            cw, ch = w // 2, h // 2
            plane = "U"
            if off >= cw * ch:
                off -= cw * ch
                plane = "V"
            return "frame %d plane %s mb (%d,%d) sample (%d,%d) got %d expected %d" % (
                f, plane, (off % cw) // 8, (off // cw) // 8, off % cw, off // cw, b[i], a[i])
    return None


def psnr(a, b):
    n = min(len(a), len(b))
    if n == 0:
        return 0.0
    se = sum((x - y) * (x - y) for x, y in zip(a[:n], b[:n]))
    if se == 0:
        return math.inf
    return 10.0 * math.log10(255.0 * 255.0 * n / se)


def psnr_planes(a, b, w, h):
    """PSNR of b against a (both 4:2:0 planar, w x h): [Y, Cb, Cr, all]."""
    ysz = w * h
    csz = (w // 2) * (h // 2)
    vals = []
    tot_se = 0
    for off, n in ((0, ysz), (ysz, csz), (ysz + csz, csz)):
        se = sum((x - y) * (x - y) for x, y in zip(a[off:off + n], b[off:off + n]))
        tot_se += se
        vals.append(math.inf if se == 0 else 10.0 * math.log10(255.0 * 255.0 * n / se))
    n_all = ysz + 2 * csz
    vals.append(math.inf if tot_se == 0 else 10.0 * math.log10(255.0 * 255.0 * n_all / tot_se))
    return vals


def read_floors(path):
    floors = {}
    if path:
        try:
            with open(path) as f:
                for line in f:
                    line = line.split("#", 1)[0].strip()
                    if line:
                        pat, qp, db = line.split()
                        floors[(pat, int(qp))] = float(db)
        except FileNotFoundError:
            pass
    return floors


def split_pictures(stream):
    """Byte offsets of the access unit delimiters (00 00 00 01 09) in the stream."""
    marker = bytes([0, 0, 0, 1, 9])
    marks = []
    i = stream.find(marker)
    while i >= 0:
        marks.append(i)
        i = stream.find(marker, i + 5)
    return marks


def cmd_compare(args):
    a = open(args.a, "rb").read()
    b = open(args.b, "rb").read()
    if len(a) != len(b):
        print("MISMATCH %s: size %d bytes, expected %d" % (args.label, len(b), len(a)))
        return 1
    d = first_diff(a, b, args.w, args.h)
    if d:
        print("MISMATCH %s: first difference at %s; PSNR %.2f dB" % (args.label, d, psnr(a, b)))
        return 1
    print("MATCH %s: %d bytes identical, PSNR inf" % (args.label, len(a)))
    return 0


def cmd_assemble(args):
    info = read_info(args.prefix + "_info.txt")
    stream = hex_to_bytes(args.prefix + "_stream.hex")[:info["stream_bytes"]]
    sps = open(args.spspps, "rb").read()
    with open(args.dir + "/stream.264", "wb") as f:
        f.write(sps + stream)
    rc = 0
    floors = read_floors(args.floors)
    marks = split_pictures(stream)
    min_psnr = {}
    prev_yuv = None
    for n in range(args.pics):
        rec = hex_to_bytes("%s_rec%d.hex" % (args.prefix, n))
        yuv, w, h = rebuilt_to_yuv(rec, info, args.disp_h)
        with open("%s/rebuilt%d.yuv" % (args.dir, n), "wb") as f:
            f.write(yuv)
        ptype = args.gop[n] if n < len(args.gop) else "I"
        print("PTYPE pic%d %s" % (n, ptype))
        if n < len(marks):
            end = marks[n + 1] if n + 1 < len(marks) else len(stream)
            bits = (end - marks[n]) * 8
            print("BITS pic%d %d" % (n, bits))
            print("BITS_PER_MB pic%d %.1f" % (n, bits / float(info["mbw"] * info["mbh"])))
            if args.allskip and ptype == "P":
                limit = 6 + 24 * args.slices
                if (end - marks[n]) > limit or (prev_yuv is not None and yuv != prev_yuv):
                    print("MISMATCH pic%d is not all-skip: %d bytes (limit %d), rebuilt equals the previous picture: %s" % (
                        n, end - marks[n], limit, yuv == prev_yuv))
                    rc = 1
                else:
                    print("ALLSKIP OK pic%d: %d bytes (limit %d), rebuilt identical to the previous picture" % (n, end - marks[n], limit))
        prev_yuv = yuv
        if not args.refs:
            continue
        ref = open(args.refs[n], "rb").read()
        # Crop the reference (coded size) to the display height.
        ys = ref[:w * h][:w * args.disp_h]
        cw = w // 2
        us = ref[w * h:w * h + cw * (h // 2)][:cw * (args.disp_h // 2)]
        vs = ref[w * h + cw * (h // 2):][:cw * (args.disp_h // 2)]
        refc = ys + us + vs
        with open("%s/ref%d.yuv" % (args.dir, n), "wb") as f:
            f.write(refc)
        if len(refc) != len(yuv):
            print("MISMATCH rebuilt%d vs generator reference: size %d, expected %d" % (n, len(yuv), len(refc)))
            rc = 1
            continue
        py, pu, pv, pa = psnr_planes(refc, yuv, w, args.disp_h)
        print("PSNR pic%d Y %.2f Cb %.2f Cr %.2f all %.2f" % (n, py, pu, pv, pa))
        if args.pcm:
            d = first_diff(refc, yuv, w, args.disp_h)
            if d:
                print("MISMATCH rebuilt%d vs generator reference: %s" % (n, d))
                rc = 1
            else:
                print("MATCH rebuilt%d equals the generator's 4:2:0 reference (%d bytes), PSNR inf" % (n, len(yuv)))
            continue
        pats = args.pattern.split(",")
        key = (pats[min(n, len(pats) - 1)], args.qp)
        if len(pats) == 1 and args.pics > 1:
            # A sequence: one floor for every picture, measured as the minimum over the pictures.
            min_psnr[key] = min(min_psnr.get(key, math.inf), pa)
            if key in floors:
                if pa < floors[key]:
                    print("FLOOR FAIL pic%d %s qp %d: PSNR %.2f dB below the floor %.2f dB" % (n, key[0], args.qp, pa, floors[key]))
                    rc = 1
                else:
                    print("FLOOR OK pic%d %s qp %d: PSNR %.2f dB >= %.2f dB" % (n, key[0], args.qp, pa, floors[key]))
            elif not args.measure:
                print("FLOOR MISSING pic%d %s qp %d: add a line to the floors file (run the harness with -Measure)" % (n, key[0], args.qp))
                rc = 1
            continue
        if key in floors:
            if pa < floors[key]:
                print("FLOOR FAIL pic%d %s qp %d: PSNR %.2f dB below the floor %.2f dB" % (n, key[0], args.qp, pa, floors[key]))
                rc = 1
            else:
                print("FLOOR OK pic%d %s qp %d: PSNR %.2f dB >= %.2f dB" % (n, key[0], args.qp, pa, floors[key]))
        elif args.measure:
            val = 99.0 if pa == math.inf else max(0.0, math.floor((pa - 1.0) * 10.0) / 10.0)
            print("FLOOR %s %d %.1f" % (key[0], args.qp, val))
        else:
            print("FLOOR MISSING pic%d %s qp %d: add a line to the floors file (run the harness with -Measure)" % (n, key[0], args.qp))
            rc = 1
    if args.measure:
        for key, pa in min_psnr.items():
            val = 99.0 if pa == math.inf else max(0.0, math.floor((pa - 1.0) * 10.0) / 10.0)
            print("FLOOR %s %d %.1f" % (key[0], key[1], val))
    print("stream %d bytes (+%d SPS/PPS)" % (len(stream), len(sps)))
    return rc


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare")
    c.add_argument("--a", required=True)
    c.add_argument("--b", required=True)
    c.add_argument("--w", type=int, required=True)
    c.add_argument("--h", type=int, required=True)
    c.add_argument("--label", default="compare")
    s = sub.add_parser("assemble")
    s.add_argument("--dir", required=True)
    s.add_argument("--prefix", required=True)
    s.add_argument("--spspps", required=True)
    s.add_argument("--pics", type=int, default=1)
    s.add_argument("--disp-h", type=int, required=True)
    s.add_argument("--refs", nargs="*")
    s.add_argument("--pcm", action="store_true")
    s.add_argument("--pattern", default="")
    s.add_argument("--qp", type=int, default=-1)
    s.add_argument("--floors", default="")
    s.add_argument("--measure", action="store_true")
    s.add_argument("--gop", default="")
    s.add_argument("--allskip", action="store_true")
    s.add_argument("--slices", type=int, default=1)
    a = ap.parse_args()
    return cmd_compare(a) if a.cmd == "compare" else cmd_assemble(a)


if __name__ == "__main__":
    sys.exit(main())
