#!/usr/bin/env python3
"""pattern_model.py -- host model of the rtlnet_csi2_rx test patterns (numpy).

Copyright (C) 2026 IronKernel. All rights reserved.

Role: produces the frames of the generator in cores/rtlnet_csi2_rx for any (mode, pattern, speed, k) as numpy arrays, byte for
byte the frames of the C model (cores/rtlnet_csi2_rx/testbench/csi2_bars_model.c, the reference) and of the RTL. Used by
stream_check.py (PSNR of the decoded pictures against the pattern) and by the model cross check.

Pattern definitions (documentation/rtlnet_csi2_rx.md section 3), W x H pixels, bw = W / 8:
  pattern 0 static bars, 1 bars scrolling right, 2 box over the bars, 3 bars with a noise band, 4 scroll + noise band + box
  bars   pixel x shows the bar of s = (x - off) mod W, off = (speed * k) mod W for patterns 1 and 4, else 0
  noise  rows [B0, B0 + 64), B0 = ((H / 2 - 32) // 16) * 16 (patterns 3, 4): the words of the band in raster order,
         n0 = seed, n(j+1) = 32 steps of the LFSR x^32 + x^22 + x^2 + x + 1, word = {Cr, Y1, Cb, Y0},
         seed = (0xACE10000 ^ (k * 0x9E3779B9 mod 2^32)) | 1
  box    64 x 64 (patterns 2, 4) at bx = tri(192 + speed * k, W - 64), by = tri(96 + (speed >> 1) * k, H - 64), tri(t, R) the
         bounce wave of period 2 R; luma ((cx >> 3) ^ (cy >> 3)) & 1 ? 192 : 64 plus (cx + 5 cy) >> 4; chroma 90 / 190
  layers box over noise over bars; the chroma of a pixel pair is that of its first pixel's layer, each pixel has its own luma.

Command line (host model check, used by cores/rtlnet_csi2_rx/testbench/csi2_bars_model.ps1 -Verify):
  pattern_model.py --verify-c <csi2_bars_model.exe>   compare every pattern, both modes, k = 0, 1, 2, 37, 1000 and speeds
                                                      4, -7, 24, 32, -32 byte for byte with the C model (frame bytes)
  pattern_model.py --dump <file> <mode> <pattern> <speed> <k>   write the YUYV frame bytes
  pattern_model.py --crc <mode> <pattern> <speed> <k>           print the CRC-32 of the frame
Exit code 0 on success.

Revision: 11-10-2026
"""
import os
import subprocess
import sys
import tempfile
import zlib

import numpy as np

MODES = {"720p30": (1280, 720), "1080p30": (1920, 1080)}
# (Y, Cb, Cr) of the eight bars, rtlnet_csi2_rx_pattern.sv bar_ycc
BARS = [(180, 128, 128), (168, 44, 136), (145, 147, 44), (133, 63, 52), (63, 193, 204), (51, 109, 212), (28, 212, 120), (16, 128, 128)]
BOX_SIZE = 64
BAND_ROWS = 64
BOX_X0 = 192
BOX_Y0 = 96
BOX_CB = 90
BOX_CR = 190
SEED_BASE = 0xACE10000
SEED_STEP = 0x9E3779B9
SPEED_MAX = 32
PATTERNS = 5


def _lfsr_tables():
    """Byte-wise tables of the 32-step LFSR map (it is linear over GF(2))."""
    def step32(s):
        for _ in range(32):
            fb = ((s >> 31) ^ (s >> 21) ^ (s >> 1) ^ s) & 1
            s = ((s << 1) | fb) & 0xFFFFFFFF
        return s
    return [[step32(v << (8 * i)) for v in range(256)] for i in range(4)], step32


_TBL, lfsr_step32 = _lfsr_tables()


def noise_words(seed, n):
    """n successive words n0 = seed, n(j+1) = step32(n(j))."""
    out = np.empty(n, dtype=np.uint32)
    s = seed
    t0, t1, t2, t3 = _TBL
    for j in range(n):
        out[j] = s
        s = t0[s & 255] ^ t1[(s >> 8) & 255] ^ t2[(s >> 16) & 255] ^ t3[s >> 24]
    return out


def tri(t, r):
    m = 2 * r
    u = t % m
    return u if u <= r else m - u


def geometry(mode):
    if isinstance(mode, str):
        if mode in MODES:
            return MODES[mode]
        w, h = mode.lower().split("x")
        return int(w), int(h)
    return mode


def frame_planes(mode, pattern, speed, k, box0=(BOX_X0, BOX_Y0)):
    """(Y (H, W), Cb (H, W/2), Cr (H, W/2)) uint8 arrays of the 4:2:2 frame; one chroma sample per pixel pair."""
    w, h = geometry(mode)
    if not (0 <= pattern < PATTERNS and -SPEED_MAX <= speed <= SPEED_MAX and k >= 0):
        raise ValueError("pattern 0..4, speed -32..32, k >= 0")
    bw = w // 8
    scroll = pattern in (1, 4)
    box = pattern in (2, 4)
    band = pattern in (3, 4)
    off = (speed * k) % w if scroll else 0
    x = np.arange(w)
    s = (x - off) % w
    bar = s // bw
    ytab = np.array([b[0] for b in BARS], dtype=np.uint8)
    cbtab = np.array([b[1] for b in BARS], dtype=np.uint8)
    crtab = np.array([b[2] for b in BARS], dtype=np.uint8)
    y_row = ytab[bar]
    cb_row = cbtab[bar[0::2]]
    cr_row = crtab[bar[0::2]]
    Y = np.tile(y_row, (h, 1))
    CB = np.tile(cb_row, (h, 1))
    CR = np.tile(cr_row, (h, 1))
    if band:
        b0 = ((h // 2 - 32) // 16) * 16
        seed = ((SEED_BASE ^ ((k * SEED_STEP) & 0xFFFFFFFF)) | 1) & 0xFFFFFFFF
        nw = noise_words(seed, BAND_ROWS * (w // 2)).reshape(BAND_ROWS, w // 2)
        Y[b0:b0 + BAND_ROWS, 0::2] = (nw & 255).astype(np.uint8)
        CB[b0:b0 + BAND_ROWS, :] = ((nw >> 8) & 255).astype(np.uint8)
        Y[b0:b0 + BAND_ROWS, 1::2] = ((nw >> 16) & 255).astype(np.uint8)
        CR[b0:b0 + BAND_ROWS, :] = (nw >> 24).astype(np.uint8)
    if box:
        bx = tri(box0[0] + speed * k, w - BOX_SIZE)
        by = tri(box0[1] + (speed >> 1) * k, h - BOX_SIZE)
        cy = np.arange(BOX_SIZE)[:, None]
        cx = np.arange(BOX_SIZE)[None, :]
        tex = (np.where(((cx >> 3) ^ (cy >> 3)) & 1, 192, 64) + ((cx + 5 * cy) >> 4)).astype(np.uint8)
        Y[by:by + BOX_SIZE, bx:bx + BOX_SIZE] = tex
        # Chroma of the pairs whose first pixel (2p) is in the box.
        p0 = (bx + 1) // 2
        p1 = (bx + BOX_SIZE - 1) // 2          # last pair index with 2p < bx + 64
        CB[by:by + BOX_SIZE, p0:p1 + 1] = BOX_CB
        CR[by:by + BOX_SIZE, p0:p1 + 1] = BOX_CR
    return Y, CB, CR


def frame_yuyv(mode, pattern, speed, k, box0=(BOX_X0, BOX_Y0)):
    """The frame in memory order Y0 Cb Y1 Cr as a uint8 array (H, 2 W)."""
    Y, CB, CR = frame_planes(mode, pattern, speed, k, box0)
    h, w = Y.shape
    out = np.empty((h, w * 2), dtype=np.uint8)
    out[:, 0::4] = Y[:, 0::2]
    out[:, 1::4] = CB
    out[:, 2::4] = Y[:, 1::2]
    out[:, 3::4] = CR
    return out


def frame_yuv420(mode, pattern, speed, k, box0=(BOX_X0, BOX_Y0)):
    """(Y (H, W), Cb (H/2, W/2), Cr (H/2, W/2)) of the 4:2:0 frame the encoder codes: the 4:2:2 chroma of a line pair averaged
    as (a + b + 1) >> 1."""
    Y, CB, CR = frame_planes(mode, pattern, speed, k, box0)

    def vavg(c):
        a = c[0::2].astype(np.uint16)
        b = c[1::2].astype(np.uint16)
        return ((a + b + 1) >> 1).astype(np.uint8)
    return Y, vavg(CB), vavg(CR)


def frame_crc(mode, pattern, speed, k, box0=(BOX_X0, BOX_Y0)):
    return zlib.crc32(frame_yuyv(mode, pattern, speed, k, box0).tobytes()) & 0xFFFFFFFF


def verify_c(exe):
    """Compare the model with the C model byte for byte. Returns the number of mismatches."""
    ks = (0, 1, 2, 37, 1000)
    bad = 0
    n = 0
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "frame.bin")
        for mode in MODES:
            for pattern in range(PATTERNS):
                speeds = (4,) if pattern in (0, 3) else (4, -7, 24, 32, -32)
                for speed in speeds:
                    for k in ks:
                        subprocess.run([exe, "--dump-frame", path, mode, str(pattern), str(speed), str(k)], check=True)
                        with open(path, "rb") as fh:
                            ref = fh.read()
                        got = frame_yuyv(mode, pattern, speed, k).tobytes()
                        n += 1
                        if ref != got:
                            bad += 1
                            diff = next(i for i in range(len(ref)) if ref[i] != got[i])
                            print("MISMATCH %s pattern %d speed %d k %d: first difference at byte %d (C %d, Python %d)" %
                                  (mode, pattern, speed, k, diff, ref[diff], got[diff]))
                        if k == 1000:
                            # the CRC the C model prints for the frame (the --frame line)
                            out = subprocess.run([exe, "--frame", mode, str(pattern), str(speed), str(k)], check=True, capture_output=True, text=True).stdout
                            if "crc32=0x%08X" % (zlib.crc32(got) & 0xFFFFFFFF) not in out:
                                bad += 1
                                print("MISMATCH CRC %s pattern %d speed %d k %d: %s" % (mode, pattern, speed, k, out.strip()))
        # reduced geometries and edge box phases used by the pattern-module bench
        for mode, box0 in (("320x96", (48, 8)), ("448x128", (48, 8))):
            for pattern, speed in ((4, 32), (4, -32), (2, -7), (1, 24), (3, 4)):
                for k in (0, 1, 5, 23, 60):
                    subprocess.run([exe, "--box0", str(box0[0]), str(box0[1]), "--dump-frame", path, mode, str(pattern), str(speed), str(k)], check=True)
                    with open(path, "rb") as fh:
                        ref = fh.read()
                    n += 1
                    if ref != frame_yuyv(mode, pattern, speed, k, box0).tobytes():
                        bad += 1
                        print("MISMATCH %s pattern %d speed %d k %d box0 %s" % (mode, pattern, speed, k, box0))
    print("PATTERN_MODEL_XCHECK %s: %d frames compared with the C model, %d mismatches" % ("PASS" if bad == 0 else "FAIL", n, bad))
    return bad


def main(argv):
    if len(argv) == 2 and argv[0] == "--verify-c":
        return 1 if verify_c(argv[1]) else 0
    if len(argv) == 6 and argv[0] == "--dump":
        with open(argv[1], "wb") as fh:
            fh.write(frame_yuyv(argv[2], int(argv[3]), int(argv[4]), int(argv[5])).tobytes())
        return 0
    if len(argv) == 5 and argv[0] == "--crc":
        print("0x%08X" % frame_crc(argv[1], int(argv[2]), int(argv[3]), int(argv[4])))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
