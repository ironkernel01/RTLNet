#!/usr/bin/env python3
"""stream_check.py -- host checks of a captured RTLNet H.264 MPEG-TS stream (called by stream_test.ps1).

Copyright (C) 2026 IronKernel. All rights reserved.

Role: two independent checks that need no decoder library.
  ts   <file.ts> [--steps 3000] [--fps 30] [--gop 30]
       Parses the transport stream itself: 188-byte packets with sync bytes, per-PID continuity counters, PAT and PMT
       CRC-32/MPEG-2, PCR monotonic, PES start codes, PTS and DTS of every access unit, PTS steps. Prints one line per
       check: "CHECK <name> PASS|FAIL <detail>", then "TS_SUMMARY ...". With --gop N (Phase 2c) the random access indicator must be
       set on the IDR access units only, the IDR access units are N pictures apart (the first access unit is one), every access unit's
       NAL units agree with its indicator (an IDR slice, NAL type 5, with SPS and PPS, exactly when the indicator is set), and
       "AU_SIZE" lines give the number, minimum, average and maximum elementary-stream bytes of the IDR and of the P access units.
  psnr <file.yuv> <width> <height> [--floor 30] [--max-frames 24]
       Reads decoded yuv420p frames one at a time (ffmpeg -pix_fmt yuv420p -f rawvideo; --max-frames 0 checks every frame), builds the expected 4:2:0 bar frame from the same
       eight 75 percent bars as rtlnet_csi2_rx (BT.709 limited range values of gige.md section 5.4; vertical bars of width/8
       pixels, chroma 4:2:0 of flat bars equals the bar chroma), and prints the PSNR of Y, Cb and Cr per sampled frame and the
       minimum. "CHECK psnr PASS|FAIL ...".
Exit code 0 when every check passes.

Revision: 11-10-2026 (phase 2c: GOP checks, access-unit sizes, every-frame PSNR without reading the whole file)
"""
import math
import sys

# (Y, Cb, Cr) of the eight bars, rtlnet_csi2_rx_pattern.sv bar_ycc
BARS = [(180, 128, 128), (168, 44, 136), (145, 147, 44), (133, 63, 52), (63, 193, 204), (51, 109, 212), (28, 212, 120), (16, 128, 128)]


def crc32_mpeg(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def get_ts(p):
    return (((p[0] >> 1) & 7) << 30) | (p[1] << 22) | ((p[2] >> 1) << 15) | (p[3] << 7) | (p[4] >> 1)


class Checker:
    def __init__(self):
        self.fail = 0

    def report(self, name, ok, detail=""):
        print("CHECK %s %s %s" % (name, "PASS" if ok else "FAIL", detail))
        if not ok:
            self.fail += 1


def nal_types(buf):
    """NAL unit types found by start codes in an access unit's elementary stream bytes."""
    out = []
    i = buf.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(buf):
        out.append(buf[i + 3] & 0x1F)
        i = buf.find(b"\x00\x00\x01", i + 3)
    return out


def check_ts(path, step, fps, gop=0):
    c = Checker()
    data = open(path, "rb").read()
    # Align on the first sync byte that repeats every 188 bytes three times.
    start = -1
    for i in range(min(len(data), 4000)):
        if all(i + k * 188 < len(data) and data[i + k * 188] == 0x47 for k in range(3)):
            start = i
            break
    if start < 0:
        c.report("sync", False, "no 188-byte packet sync in %d bytes" % len(data))
        return c.fail
    npk = (len(data) - start) // 188
    bad_sync = cc_err = psi_err = tei = 0
    cc_last = {}
    pids = {}
    pcr_list = []
    pcr_bad = 0
    au = None            # (pts, dts, pcr) of the access unit in progress
    pts_list = []
    dts_list = []
    pes_err = 0
    ra_count = 0
    ra_flags = []        # random access indicator of each access unit
    au_bytes = []        # elementary stream bytes of each access unit
    au_nals = []         # NAL unit types of each access unit
    cur = None           # bytearray of the access unit in progress
    pat_ok = pmt_ok = 0
    video_pid = None
    for n in range(npk):
        p = data[start + n * 188: start + (n + 1) * 188]
        if p[0] != 0x47:
            bad_sync += 1
            continue
        if p[1] & 0x80:
            tei += 1
        pid = ((p[1] & 0x1F) << 8) | p[2]
        afc = (p[3] >> 4) & 3
        cc = p[3] & 15
        pids[pid] = pids.get(pid, 0) + 1
        if pid in cc_last and ((cc_last[pid] + 1) & 15) != cc and afc & 1:
            cc_err += 1
        cc_last[pid] = cc
        off = 4
        if afc & 2:
            alen = p[4]
            if alen >= 7 and (p[5] & 0x10):
                base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
                if pcr_list and base < pcr_list[-1]:
                    pcr_bad += 1
                pcr_list.append(base)
            if alen >= 1 and (p[5] & 0x40):
                ra_count += 1
            off = 5 + alen
        if pid in (0, 0x1000) or (pid == 0x1000):
            if (p[1] & 0x40) and (afc & 1):
                s = p[5:]
                ln = (((s[1] & 0x0F) << 8) | s[2]) + 3
                crc = int.from_bytes(s[ln - 4: ln], "big")
                if crc32_mpeg(s[: ln - 4]) == crc and crc32_mpeg(s[:ln]) == 0:
                    if pid == 0:
                        pat_ok += 1
                    else:
                        pmt_ok += 1
                        video_pid = ((s[13] & 0x1F) << 8) | s[14]
                else:
                    psi_err += 1
            continue
        if (p[1] & 0x40) and (afc & 1) and pid == 0x0100:   # PES start: close the previous access unit
            if cur is not None:
                au_bytes.append(len(cur))
                au_nals.append(nal_types(bytes(cur)))
            cur = bytearray()
            ra_flags.append(bool((afc & 2) and p[4] >= 1 and (p[5] & 0x40)))
        if (p[1] & 0x40) and (afc & 1):   # PES start
            if p[off:off + 3] != b"\x00\x00\x01" or p[off + 3] != 0xE0 or (p[off + 7] & 0xC0) != 0xC0:
                pes_err += 1
                continue
            pts = get_ts(p[off + 9: off + 14])
            dts = get_ts(p[off + 14: off + 19])
            pts_list.append(pts)
            dts_list.append(dts)
            cur += p[off + 19:]
            continue
        if pid == 0x0100 and (afc & 1) and cur is not None:
            cur += p[off:]
    c.report("packets", npk > 0 and bad_sync == 0 and tei == 0 and (len(data) - start) % 188 == 0,
             "%d packets, %d bad sync, %d transport errors, %d trailing bytes" % (npk, bad_sync, tei, (len(data) - start) % 188))
    c.report("continuity", cc_err == 0, "%d continuity counter errors, PIDs %s" % (cc_err, {hex(k): v for k, v in sorted(pids.items())}))
    c.report("psi", psi_err == 0 and pat_ok > 0 and pmt_ok > 0, "PAT %d, PMT %d valid, %d CRC errors, video PID %s" % (pat_ok, pmt_ok, psi_err, hex(video_pid) if video_pid else None))
    c.report("pes", pes_err == 0 and len(pts_list) > 0, "%d access units, %d PES header errors" % (len(pts_list), pes_err))
    c.report("pcr", len(pcr_list) > 0 and pcr_bad == 0, "%d PCR values, %d going backwards" % (len(pcr_list), pcr_bad))
    steps = [b - a for a, b in zip(pts_list, pts_list[1:])]
    bad = [s for s in steps if s != step]
    c.report("pts_steps", len(steps) > 0 and not bad, "%d steps of %d expected, %d different %s" % (len(steps) - len(bad), step, len(bad), sorted(set(bad))[:6]))
    c.report("dts_equals_pts", pts_list == dts_list, "DTS equals PTS in %d of %d access units" % (sum(1 for a, b in zip(pts_list, dts_list) if a == b), len(pts_list)))
    dur = (pts_list[-1] - pts_list[0]) / 90000.0 if len(pts_list) > 1 else 0
    rate = (len(pts_list) - 1) / dur if dur > 0 else 0
    c.report("frame_rate", abs(rate - fps) < 0.6, "%.2f pictures per second over %.2f s of PTS" % (rate, dur))
    if cur is not None:
        au_bytes.append(len(cur))
        au_nals.append(nal_types(bytes(cur)))
    if gop <= 0:
        c.report("random_access", ra_count == len(pts_list), "%d of %d access units flag random access" % (ra_count, len(pts_list)))
    else:
        idx = [i for i, f in enumerate(ra_flags) if f]
        gaps = [b - a for a, b in zip(idx, idx[1:])]
        bad_gaps = [g for g in gaps if g != gop]
        c.report("random_access", len(ra_flags) > 0 and ra_flags[0] and not bad_gaps,
                 "%d of %d access units flag random access (IDR), first access unit %s, %d gaps of %d, %d different %s" %
                 (len(idx), len(ra_flags), "yes" if ra_flags and ra_flags[0] else "no", len(gaps) - len(bad_gaps), gop, len(bad_gaps), sorted(set(bad_gaps))[:6]))
        mism = 0
        for f, n in zip(ra_flags, au_nals):
            idr = 5 in n
            if idr != f or (idr and not (7 in n and 8 in n)) or (not idr and (7 in n or 8 in n or 1 not in n)):
                mism += 1
        c.report("nal_types", len(au_nals) > 0 and mism == 0, "%d access units: IDR (NAL 5 with SPS 7 and PPS 8) exactly where the indicator is set, P (NAL 1) elsewhere; %d mismatches" % (len(au_nals), mism))
        for label, want in (("idr", True), ("p", False)):
            sz = [b for b, f in zip(au_bytes, ra_flags) if f == want]
            if sz:
                print("AU_SIZE %s n=%d min=%d avg=%d max=%d bytes" % (label, len(sz), min(sz), sum(sz) // len(sz), max(sz)))
            else:
                print("AU_SIZE %s n=0" % label)
        tot = sum(au_bytes)
        if len(pts_list) > 1:
            print("AU_SIZE total_es_bytes=%d es_rate_kbps=%.0f ts_rate_kbps=%.0f" % (tot, tot * 8 / ((pts_list[-1] - pts_list[0]) / 90000.0 + 1.0 / fps) / 1000.0, (len(data) - start) * 8 / ((pts_list[-1] - pts_list[0]) / 90000.0 + 1.0 / fps) / 1000.0))
    print("TS_SUMMARY packets=%d access_units=%d cc_errors=%d pts_gaps=%d rate=%.3f bytes=%d" % (npk, len(pts_list), cc_err, len(bad), rate, len(data)))
    return c.fail


def expected_frame(w, h):
    bw = w // 8
    yrow = b"".join(bytes([BARS[i][0]]) * bw for i in range(8))
    crow = b"".join(bytes([BARS[i][1]]) * (bw // 2) for i in range(8))
    vrow = b"".join(bytes([BARS[i][2]]) * (bw // 2) for i in range(8))
    return yrow, crow, vrow


def plane_sse(buf, off, rows, width, exp_row):
    sse = 0
    for r in range(rows):
        row = buf[off + r * width: off + (r + 1) * width]
        if row != exp_row:
            sse += sum((a - b) * (a - b) for a, b in zip(row, exp_row))
    return sse


def psnr_of(sse, n):
    if sse == 0:
        return 99.0
    return 10.0 * math.log10(255.0 * 255.0 * n / sse)


def check_psnr(path, w, h, floor, max_frames):
    c = Checker()
    import os
    fsize = w * h * 3 // 2
    nframes = os.path.getsize(path) // fsize
    if nframes == 0:
        c.report("psnr", False, "no decoded frame of %dx%d in %d bytes" % (w, h, os.path.getsize(path)))
        return c.fail
    yrow, crow, vrow = expected_frame(w, h)
    want = nframes if max_frames <= 0 else min(max_frames, nframes)
    pick = sorted(set(int(i * (nframes - 1) / max(1, want - 1)) for i in range(want)))
    worst = 99.0
    worst_f = -1
    with open(path, "rb") as fh:
        for f in pick:
            fh.seek(f * fsize)
            data = fh.read(fsize)
            py = psnr_of(plane_sse(data, 0, h, w, yrow), w * h)
            pu = psnr_of(plane_sse(data, w * h, h // 2, w // 2, crow), w * h // 4)
            pv = psnr_of(plane_sse(data, w * h + w * h // 4, h // 2, w // 2, vrow), w * h // 4)
            m = min(py, pu, pv)
            if m < worst:
                worst = m
                worst_f = f
            if max_frames > 0 or m < floor or f < 3:
                print("PSNR frame %d Y %.2f Cb %.2f Cr %.2f dB" % (f, py, pu, pv))
    print("PSNR worst frame %d at %.2f dB" % (worst_f, worst))
    c.report("psnr", worst >= floor, "%d of %d decoded frames checked, minimum %.2f dB (floor %.1f)" % (len(pick), nframes, worst, floor))
    c.report("decoded_frames", nframes >= 1, "%d frames decoded" % nframes)
    return c.fail


def main(argv):
    if len(argv) >= 2 and argv[0] == "ts":
        step = 3000
        fps = 30.0
        if "--steps" in argv:
            step = int(argv[argv.index("--steps") + 1])
        if "--fps" in argv:
            fps = float(argv[argv.index("--fps") + 1])
        gop = int(argv[argv.index("--gop") + 1]) if "--gop" in argv else 0
        return 1 if check_ts(argv[1], step, fps, gop) else 0
    if len(argv) >= 4 and argv[0] == "psnr":
        floor = float(argv[argv.index("--floor") + 1]) if "--floor" in argv else 30.0
        mx = int(argv[argv.index("--max-frames") + 1]) if "--max-frames" in argv else 24
        return 1 if check_psnr(argv[1], int(argv[2]), int(argv[3]), floor, mx) else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
