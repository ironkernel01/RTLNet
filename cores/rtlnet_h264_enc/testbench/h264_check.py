#!/usr/bin/env python3
"""
File: h264_check.py
Purpose: stream assembly and picture comparison of the rtlnet_h264_top decoder harness.
Overview:
  * assemble: turns the bench's dumps into the files the decoders and the comparison use.
      python -I h264_check.py assemble --dir D --prefix D/o --spspps D/sps.bin --pics N --disp-h H [--refs a.yuv b.yuv]
    Reads <prefix>_info.txt, <prefix>_stream.hex, <prefix>_rec<n>.hex. Writes D/stream.264 (SPS + PPS + the
    encoder's Annex B stream), D/rebuilt<n>.yuv (the engine's rebuilt picture n, 4:2:0 planar, cropped to
    the display height) and, when --refs is given, checks each rebuilt picture against the generator's
    reference 4:2:0 picture (cropped the same way): exit code 1 and the first differing macroblock on a mismatch.
  * compare: python -I h264_check.py compare --a X.yuv --b Y.yuv --w W --h H --label NAME
    Byte comparison of two 4:2:0 YUV files (all frames); prints PSNR, and on a mismatch the first differing
    frame, plane and macroblock (x, y); exit code 1 on any difference or size mismatch.
Revision: 11-09-2026
  * 11-09-2026: initial version.
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
    for n in range(args.pics):
        rec = hex_to_bytes("%s_rec%d.hex" % (args.prefix, n))
        yuv, w, h = rebuilt_to_yuv(rec, info, args.disp_h)
        with open("%s/rebuilt%d.yuv" % (args.dir, n), "wb") as f:
            f.write(yuv)
        if args.refs:
            ref = open(args.refs[n], "rb").read()
            # Crop the reference (coded size) to the display height.
            ys = ref[:w * h][:w * args.disp_h]
            cw = w // 2
            us = ref[w * h:w * h + cw * (h // 2)][:cw * (args.disp_h // 2)]
            vs = ref[w * h + cw * (h // 2):][:cw * (args.disp_h // 2)]
            refc = ys + us + vs
            with open("%s/ref%d.yuv" % (args.dir, n), "wb") as f:
                f.write(refc)
            d = first_diff(refc, yuv, w, args.disp_h)
            if d or len(refc) != len(yuv):
                print("MISMATCH rebuilt%d vs generator reference: %s" % (n, d))
                rc = 1
            else:
                print("MATCH rebuilt%d equals the generator's 4:2:0 reference (%d bytes), PSNR inf" % (n, len(yuv)))
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
    a = ap.parse_args()
    return cmd_compare(a) if a.cmd == "compare" else cmd_assemble(a)


if __name__ == "__main__":
    sys.exit(main())
