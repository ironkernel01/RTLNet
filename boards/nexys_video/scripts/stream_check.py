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
       With --target-kbps K (Phase 2d) the elementary-stream rate is checked over sliding windows of one second (fps pictures; after the first
       --skip-s seconds, default 2) against K: "CHECK rate_1s" within +-10 %; the 10 s windows are printed ("RATE 10s") and gated within +-3 % with --gate10.
       --waive a,b,c lists stream seconds (from the first PTS) whose windows are excluded (the encoder at the top of the QP range). "QP min= avg= max="
       --cc-tol-pct P lets the continuity check pass with up to P percent of the packets in error (a Wi-Fi link; default 0). "QP min= avg= max="
       is the slice QP of every picture parsed from the slice headers; --max-qp-step N gates the largest step between pictures ("CHECK qp_steps").
       --forced-idr N (High profile demo netlist): exactly N IDR pictures lie off the GOP cadence (the forced IDR picture at a license end); each is printed as "FORCED_IDR" with its position.
  psnr <file.yuv> <width> <height> [--floor 30] [--max-frames 24] [--pattern <0..4> --speed <n> [--k-first-max 64] [--step 1]]
       Reads decoded yuv420p frames one at a time (ffmpeg -pix_fmt yuv420p -f rawvideo; --max-frames 0 checks every frame), builds the expected 4:2:0 bar frame from the same
       eight 75 percent bars as rtlnet_csi2_rx (BT.709 limited range values; vertical bars of width/8
       pixels, chroma 4:2:0 of flat bars equals the bar chroma), and prints the PSNR of Y, Cb and Cr per sampled frame and the
       minimum. "CHECK psnr PASS|FAIL ...".
       With --pattern N --speed S (Phase 2d) every decoded picture, in order, is compared with the pattern of
       cores/rtlnet_csi2_rx/testbench/pattern_model.py (the rtlnet_csi2_rx pattern N at speed S in 4:2:0, the encoder's chroma rule): the
       pattern frame counter k of a picture is searched among k_prev + 1 .. k_prev + 4 (the first picture among 0 .. --k-first-max) and the
       best match (lowest luma error) is kept, so a picture the board dropped resyncs the sequence. Prints "PSNR frame f k K ..." lines,
       "PSNR_K resyncs=<n> dropped=<d> ..." and "CHECK psnr PASS|FAIL ..." (PSNR floor on the best match; a picture whose best match
       is not k_prev + 1 counts as a resync). "PSNR_STAT min= mean=" gives the minimum and the mean over the checked pictures. With --step N the file holds every N-th picture
       (ffmpeg select=not(mod(n\\,N)), a long capture): k then advances by N per file frame. Pattern 0 needs no k. Without --pattern the check is the static-bars one above.
  reorder <file.ts> <file.ts.lens>
       Puts datagrams that arrived out of order (a swap seen over Wi-Fi at the start of a stream and at IDR bursts; the datagram count equals the
       board's) back in order by their continuity counters, rewrites the capture and prints "REORDER datagrams=<n> out_of_order_repaired=<m>".
       stream_test.ps1 calls it before trim and the ts checks.
  headtrim <file.ts>
       With -CcTolPct only: cuts the capture before the PAT of its first IDR picture (the first datagrams of a stream can be missing over Wi-Fi) and
       prints "HEADTRIM cut_packets=<n> cut_access_units=<m>"; stream_test.ps1 reports the cut.
  skipidr <file.ts> [--n 2]
       Cuts the capture before the PAT of its n-th IDR picture (random access indicator, default the second) and rewrites the file; the start-up part
       is judged by nobody. Prints "SKIPIDR cut_packets=<p> cut_access_units=<a> cc_errors=<e>": the video-PID continuity errors that lay in the
       cut part (reported, not judged). Without a n-th IDR picture the file is left unchanged and "SKIPIDR none" is printed (exit 1).
       stream_test.ps1 of the Zybo Z7-20 calls it after trim; the Nexys Video test does not use it.
  trim <file.ts>
       Cuts the capture before its last video access unit (the one the capture stopped in is incomplete; FFmpeg and JM report it as a corrupted
       macroblock or an out-of-range mb_qp_delta). stream_test.ps1 calls it before every check.
  selftest <ffmpeg.exe> [--keep <dir>]
       Host test of the pattern PSNR path: builds streams from pattern_model.py with ffmpeg libx264 (pictures omitted to force resyncs), decodes
       them again and runs the pattern check; prints "CHECK selftest_<pattern> PASS|FAIL ...".
Exit code 0 when every check passes.

Revision: 11-15-2026 (skipidr); 11-10-2026 (phase 2c: GOP checks, access-unit sizes, every-frame PSNR without reading the whole file; phase 2d: --pattern, selftest, --target-kbps rate windows, slice QP)
"""
import math
import os
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


class BitReader:
    def __init__(self, data):
        self.d = data
        self.pos = 0

    def u(self, n):
        v = 0
        for _ in range(n):
            byte = self.d[self.pos >> 3]
            v = (v << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v

    def ue(self):
        z = 0
        while self.u(1) == 0:
            z += 1
            if z > 31:
                raise ValueError("ue")
        return (1 << z) - 1 + (self.u(z) if z else 0)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)


def unescape(b):
    out = bytearray()
    z = 0
    for x in b:
        if z >= 2 and x == 3:
            z = 0
            continue
        out.append(x)
        z = z + 1 if x == 0 else 0
    return bytes(out)


_CABAC = False   # entropy_coding_mode_flag of the last PPS seen (a stream that switches profile carries a PPS in front of every IDR picture)


def sps_profile(buf):
    """(profile_idc, constraint flags byte, entropy_coding_mode_flag, transform_8x8_mode_flag) from the SPS (NAL 7) and PPS (NAL 8) of an access unit, or None without an SPS.
    transform_8x8_mode_flag is 0 when the PPS has no extension fields (the PPS of Constrained Baseline and of High profile with the 4x4 transform)."""
    prof = None
    cabac = None
    t8 = None
    i = buf.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(buf):
        t = buf[i + 3] & 0x1F
        try:
            if t == 7:
                d = unescape(bytes(buf[i + 4: i + 8]))
                prof = (d[0], d[1])
            elif t == 8:
                j = buf.find(b"\x00\x00\x01", i + 3)
                pps = unescape(bytes(buf[i + 4: (j if j >= 0 else len(buf))])).rstrip(b"\x00")
                r = BitReader(pps)
                r.ue()
                r.ue()
                cabac = r.u(1)
                r.u(1)                       # bottom_field_pic_order_in_frame_present_flag
                if r.ue() != 0:              # num_slice_groups_minus1
                    raise ValueError("slice groups")
                r.ue()
                r.ue()                       # num_ref_idx_l0 / l1_default_active_minus1
                r.u(1)
                r.u(2)                       # weighted_pred_flag, weighted_bipred_idc
                r.se()
                r.se()
                r.se()                       # pic_init_qp, pic_init_qs, chroma_qp_index_offset
                r.u(1)
                r.u(1)
                r.u(1)                       # deblocking_filter_control_present, constrained_intra_pred, redundant_pic_cnt_present
                stop = len(pps) * 8 - 1
                while not (pps[stop >> 3] >> (7 - (stop & 7))) & 1:
                    stop -= 1                # the rbsp_stop_one_bit
                t8 = r.u(1) if r.pos < stop else 0
        except (ValueError, IndexError):
            pass
        i = buf.find(b"\x00\x00\x01", i + 3)
    if prof is None:
        return None
    return (prof[0], prof[1], cabac, t8)


def slice_qp(buf, log2_fn=4):
    """Slice QP (26 + slice_qp_delta) of the first slice NAL (type 1 or 5) of an access unit, or None.
    Header layout of rtlnet_h264_engine.sv: first_mb ue, slice_type ue, pps_id ue, frame_num u(log2_fn), idr_pic_id ue (IDR),
    P: num_ref_idx_active_override_flag u(1), ref_pic_list_modification_flag_l0 u(1); dec_ref_pic_marking (IDR 2 flags, P 1 flag),
    cabac_init_idc ue (P slice when the PPS has entropy_coding_mode_flag 1), slice_qp_delta se."""
    global _CABAC
    i = buf.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(buf):
        t = buf[i + 3] & 0x1F
        if t == 8:
            try:
                r = BitReader(unescape(bytes(buf[i + 4: i + 12])))
                r.ue()
                r.ue()
                _CABAC = bool(r.u(1))
            except (ValueError, IndexError):
                pass
        if t in (1, 5):
            try:
                r = BitReader(unescape(bytes(buf[i + 4: i + 40])))
                r.ue()
                r.ue()
                r.ue()
                r.u(log2_fn)
                if t == 5:
                    r.ue()
                    r.u(2)
                else:
                    if r.u(1):
                        return None
                    r.u(1)
                    r.u(1)
                    if _CABAC:
                        r.ue()
                return 26 + r.se()
            except (ValueError, IndexError):
                return None
        i = buf.find(b"\x00\x00\x01", i + 3)
    return None


def check_ts(path, step, fps, gop=0, target_kbps=0.0, skip_s=2.0, gate10=False, waive=None, max_qp_step=0, cc_tol_pct=0.0, forced_idr=-1):
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
    au_qps = []          # slice QP of each access unit
    au_prof = []         # (profile_idc, constraint flags, entropy_coding_mode_flag, transform_8x8_mode_flag) of the SPS and PPS of each access unit, or None
    cur = None           # bytearray of the access unit in progress
    pat_ok = pmt_ok = 0
    video_pid = None
    dmg = set()          # access unit indexes next to a video continuity error (a lost datagram); only used with --cc-tol-pct
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
            if cc_err <= 12:
                print("CC_ERR packet=%d pid=%s expected=%d got=%d access_unit=%d datagram_offset=%d" % (n, hex(pid), (cc_last[pid] + 1) & 15, cc, len(ra_flags) - 1, (start + n * 188) // 188 % 7))
            if pid == 0x0100:
                dmg.add(len(ra_flags) - 1)
                dmg.add(len(ra_flags))
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
                au_qps.append(slice_qp(cur))
                au_prof.append(sps_profile(bytes(cur)))
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
    c.report("continuity", cc_err * 100.0 <= cc_tol_pct * max(1, npk), "%d continuity counter errors in %d packets (%.4f %%, limit %.4f %%), PIDs %s" %
             (cc_err, npk, cc_err * 100.0 / max(1, npk), cc_tol_pct, {hex(k): v for k, v in sorted(pids.items())}))
    c.report("psi", psi_err == 0 and pat_ok > 0 and pmt_ok > 0, "PAT %d, PMT %d valid, %d CRC errors, video PID %s" % (pat_ok, pmt_ok, psi_err, hex(video_pid) if video_pid else None))
    c.report("pes", pes_err == 0 and len(pts_list) > 0, "%d access units, %d PES header errors" % (len(pts_list), pes_err))
    c.report("pcr", len(pcr_list) > 0 and pcr_bad == 0, "%d PCR values, %d going backwards" % (len(pcr_list), pcr_bad))
    steps = [b - a for a, b in zip(pts_list, pts_list[1:])]
    bad = [s for s in steps if s != step]
    # Wi-Fi tolerance: with --cc-tol-pct and continuity errors, a step that is a whole multiple of the picture period is a lost access unit
    # (at most one lost picture per continuity error); they are reported, any other step still fails.
    lost_au = 0
    if cc_tol_pct > 0 and cc_err > 0:
        lost_au = sum(s // step - 1 for s in bad if s > step and s % step == 0)
        bad_other = [s for s in bad if not (s > step and s % step == 0)]
        tol_ok = lost_au <= cc_err and not bad_other
    else:
        bad_other = bad
        tol_ok = not bad
    c.report("pts_steps", len(steps) > 0 and tol_ok, "%d steps of %d expected, %d different %s, %d lost access unit(s) tolerated (%d continuity errors)" % (len(steps) - len(bad), step, len(bad), sorted(set(bad))[:6], lost_au if tol_ok else 0, cc_err) if lost_au else
             "%d steps of %d expected, %d different %s" % (len(steps) - len(bad), step, len(bad), sorted(set(bad))[:6]))
    tol = cc_tol_pct > 0 and cc_err > 0
    if lost_au:
        print("LOST_AU %d" % lost_au)
    c.report("dts_equals_pts", pts_list == dts_list, "DTS equals PTS in %d of %d access units" % (sum(1 for a, b in zip(pts_list, dts_list) if a == b), len(pts_list)))
    dur = (pts_list[-1] - pts_list[0]) / 90000.0 if len(pts_list) > 1 else 0
    rate = (len(pts_list) - 1) / dur if dur > 0 else 0
    c.report("frame_rate", abs(rate - fps) < 0.6, "%.2f pictures per second over %.2f s of PTS" % (rate, dur))
    if cur is not None:
        au_bytes.append(len(cur))
        au_nals.append(nal_types(bytes(cur)))
        au_qps.append(slice_qp(cur))
        au_prof.append(sps_profile(bytes(cur)))
    if gop <= 0:
        c.report("random_access", ra_count == len(pts_list), "%d of %d access units flag random access" % (ra_count, len(pts_list)))
    else:
        idx = [i for i, f in enumerate(ra_flags) if f]
        if tol:
            # the distance between IDR pictures in PTS periods (a lost access unit shortens the index distance, not the PTS distance)
            gaps = [int(round((pts_list[b] - pts_list[a]) / float(step))) for a, b in zip(idx, idx[1:])]
        else:
            gaps = [b - a for a, b in zip(idx, idx[1:])]
        bad_gaps = [g for g in gaps if g != gop]
        if forced_idr >= 0:
            # License change (High profile demo netlist): the encoder forces an IDR picture off the GOP cadence. Either the cadence restarts after it
            # (one short gap) or it stays on the old grid (two gaps that add up to the GOP). Each forced IDR picture is reported with its position.
            forced_at = []
            gi = 0
            while gi < len(gaps):
                if gaps[gi] != gop:
                    if gi + 1 < len(gaps) and gaps[gi] + gaps[gi + 1] == gop:
                        forced_at.append((idx[gi + 1], "grid kept: gaps %d + %d" % (gaps[gi], gaps[gi + 1])))
                        gi += 2
                        continue
                    forced_at.append((idx[gi + 1], "cadence restarted: gap %d" % gaps[gi]))
                gi += 1
            for (ai, how) in forced_at:
                print("FORCED_IDR access_unit=%d pts_s=%.3f (%s) nal_types=%s" % (ai, (pts_list[ai] - pts_list[0]) / 90000.0, how, sorted(au_nals[ai])))
            prev = None
            for ai, pr in enumerate(au_prof):
                if pr is not None and pr != prev:
                    print("PROFILE_RUN access_unit=%d pts_s=%.3f profile_idc=%d constraint_set1=%d entropy_coding_mode=%s transform_8x8_mode=%s" %
                          (ai, (pts_list[ai] - pts_list[0]) / 90000.0, pr[0], (pr[1] >> 6) & 1, pr[2], pr[3]))
                    prev = pr
            c.report("random_access", len(ra_flags) > 0 and ra_flags[0] and len(forced_at) == forced_idr,
                     "%d of %d access units flag random access (IDR), first access unit %s, %d IDR pictures off the GOP %d cadence (expected %d)" %
                     (len(idx), len(ra_flags), "yes" if ra_flags and ra_flags[0] else "no", len(forced_at), gop, forced_idr))
        else:
          c.report("random_access", len(ra_flags) > 0 and ra_flags[0] and not bad_gaps,
                   "%d of %d access units flag random access (IDR), first access unit %s, %d gaps of %d, %d different %s" %
                   (len(idx), len(ra_flags), "yes" if ra_flags and ra_flags[0] else "no", len(gaps) - len(bad_gaps), gop, len(bad_gaps), sorted(set(bad_gaps))[:6]))
        mism = 0
        for i, (f, n) in enumerate(zip(ra_flags, au_nals)):
            if tol and i in dmg:
                continue
            idr = 5 in n
            if idr != f or (idr and not (7 in n and 8 in n)) or (not idr and (7 in n or 8 in n or 1 not in n)):
                mism += 1
        c.report("nal_types", len(au_nals) > 0 and mism == 0, "%d access units: IDR (NAL 5 with SPS 7 and PPS 8) exactly where the indicator is set, P (NAL 1) elsewhere; %d mismatches" % (len(au_nals), mism))
        nfirst = int(round(fps))
        print("FIRST_SECOND_MAX_AU %d bytes (largest of the first %d access units, the first IDR picture included)" % (max(au_bytes[:nfirst]) if au_bytes else 0, nfirst))
        for label, want in (("idr", True), ("p", False)):
            sz = [b for b, f in zip(au_bytes, ra_flags) if f == want]
            if sz:
                print("AU_SIZE %s n=%d min=%d avg=%d max=%d bytes" % (label, len(sz), min(sz), sum(sz) // len(sz), max(sz)))
            else:
                print("AU_SIZE %s n=0" % label)
        tot = sum(au_bytes)
        if len(pts_list) > 1:
            print("AU_SIZE total_es_bytes=%d es_rate_kbps=%.0f ts_rate_kbps=%.0f" % (tot, tot * 8 / ((pts_list[-1] - pts_list[0]) / 90000.0 + 1.0 / fps) / 1000.0, (len(data) - start) * 8 / ((pts_list[-1] - pts_list[0]) / 90000.0 + 1.0 / fps) / 1000.0))
    if target_kbps > 0 and len(au_bytes) > 1:
        n = len(au_bytes)
        win = int(round(fps))
        skip = int(round(skip_s * fps))
        waive = waive or set()

        def windows(wn, tol_pct, name, gated):
            worst_dev = 0.0
            cnt = 0
            skipped = 0
            sums = []
            want = target_kbps * 1000.0 / 8.0 * wn / fps
            for a in range(skip, n - wn + 1):
                # a window is waived when a stream second it touches is a waived one (seconds from the first PTS)
                if tol and any(k in dmg for k in range(a, a + wn)):
                    skipped += 1
                    continue
                secs = set(range(int((pts_list[a] - pts_list[0]) / 90000.0), int((pts_list[a + wn - 1] - pts_list[0]) / 90000.0) + 1))
                if secs & waive:
                    skipped += 1
                    continue
                v = sum(au_bytes[a:a + wn])
                sums.append(v)
                worst_dev = max(worst_dev, abs(v - want) / want * 100.0)
                cnt += 1
            mean = (sum(sums) / len(sums) * 8.0 * fps / wn / 1000.0) if sums else 0.0
            print("RATE %s windows=%d waived=%d worst_dev=%.2f%% mean_kbps=%.1f" % (name, cnt, skipped, worst_dev, mean))
            if gated:
                c.report("rate_" + name, cnt > 0 and worst_dev <= tol_pct,
                         "target %.0f kb/s: worst %s window deviates %.2f%% (limit %.0f%%), %d windows checked, %d waived (QP limit, or next to a lost datagram)" %
                         (target_kbps, name, worst_dev, tol_pct, cnt, skipped))
        windows(win, 10.0, "1s", True)
        windows(10 * win, 3.0, "10s", gate10)
    qv = [q for q in au_qps if q is not None]
    if qv:
        # a step across a lost access unit (a PTS gap, lossy capture only) spans two pictures: it is left out
        steps_q = [abs(b - a) for i, (a, b) in enumerate(zip(au_qps, au_qps[1:]))
                   if a is not None and b is not None and not (tol and i + 1 < len(pts_list) and pts_list[i + 1] - pts_list[i] != step)]
        mx = max(steps_q) if steps_q else 0
        print("QP min=%d avg=%.2f max=%d pictures=%d unparsed=%d max_step=%d" % (min(qv), sum(qv) / len(qv), max(qv), len(qv), len(au_qps) - len(qv), mx))
        if max_qp_step > 0:
            c.report("qp_steps", len(qv) == len(au_qps) and mx <= max_qp_step,
                     "slice QP of %d of %d pictures parsed, largest step between pictures %d (limit %d)" % (len(qv), len(au_qps), mx, max_qp_step))
    print("TS_SUMMARY packets=%d access_units=%d cc_errors=%d pts_gaps=%d rate=%.3f bytes=%d" % (npk, len(pts_list), cc_err, len(bad), rate, len(data)))
    return c.fail


def reorder_ts(path, lens_path, look=8):
    """Put datagrams that arrived out of order back in order (stream_test.ps1 writes one 16-bit length per received datagram next to the capture).
    A datagram is in order when the first payload-carrying packet of each PID in it continues that PID's continuity counter; when the next
    datagram does not continue, the next --look datagrams are searched for one that does and it is emitted first. Prints "REORDER ..." and
    rewrites the capture; the continuity check that follows counts the real losses only."""
    data = open(path, "rb").read()
    lens = open(lens_path, "rb").read()
    n = len(lens) // 2
    sizes = [lens[2 * i] | (lens[2 * i + 1] << 8) for i in range(n)]
    if sum(sizes) != len(data):
        print("REORDER skipped: length file covers %d bytes, capture has %d" % (sum(sizes), len(data)))
        return 0
    dgs = []
    off = 0
    for sz in sizes:
        dgs.append(data[off:off + sz])
        off += sz

    def first_cc(d):
        out = {}
        for i in range(0, len(d) - 187, 188):
            if d[i] != 0x47:
                return None
            afc = (d[i + 3] >> 4) & 3
            if not (afc & 1):
                continue
            pid = ((d[i + 1] & 0x1F) << 8) | d[i + 2]
            if pid not in out:
                out[pid] = d[i + 3] & 15
        return out

    def last_cc(d):
        out = {}
        for i in range(0, len(d) - 187, 188):
            afc = (d[i + 3] >> 4) & 3
            if d[i] == 0x47 and (afc & 1):
                out[((d[i + 1] & 0x1F) << 8) | d[i + 2]] = d[i + 3] & 15
        return out

    def continues(fc, last):
        return fc is not None and all(pid not in last or ((last[pid] + 1) & 15) == c for pid, c in fc.items())

    out = []
    last = {}
    pending = list(range(n))
    moved = 0
    swaps = 0
    while pending:
        pick = 0
        if last and not continues(first_cc(dgs[pending[0]]), last):
            for k in range(1, min(look, len(pending) - 1) + 1):
                if continues(first_cc(dgs[pending[k]]), last):
                    pick = k
                    break
        if pick:
            moved += 1
            swaps += 1
        i = pending.pop(pick)
        out.append(dgs[i])
        last.update(last_cc(dgs[i]))
    if moved:
        with open(path, "wb") as fh:
            fh.write(b"".join(out))
    print("REORDER datagrams=%d out_of_order_repaired=%d" % (n, moved))
    return 0


def headtrim_ts(path):
    """Cut the capture before the PAT of the first IDR picture. The first datagrams of a Wi-Fi stream can be missing (the capture then starts inside the
    first picture or one picture later); a capture that starts at a P picture cannot be decoded and its first access unit is not a random access point.
    Prints "HEADTRIM cut_packets=<n> cut_access_units=<m>" (0 and 0 when the capture starts at an IDR picture) and rewrites the file when it cuts."""
    import shutil
    with open(path, "rb") as fh:
        data = fh.read(32 * 1024 * 1024)
    start = -1
    for i in range(min(len(data), 4000)):
        if all(i + k * 188 < len(data) and data[i + k * 188] == 0x47 for k in range(3)):
            start = i
            break
    if start < 0:
        print("HEADTRIM no sync")
        return 1
    npk = (len(data) - start) // 188
    last_pat = -1
    au = 0
    cut = -1
    for n in range(npk):
        p = data[start + n * 188: start + (n + 1) * 188]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid == 0 and (p[1] & 0x40):
            last_pat = n
        if pid == 0x0100 and (p[1] & 0x40) and ((p[3] >> 4) & 3) & 2 and p[4] >= 1 and (p[5] & 0x40):
            cut = last_pat if (last_pat >= 0 and n - last_pat < 8) else n
            break
        if pid == 0x0100 and (p[1] & 0x40):
            au += 1
    if cut < 0:
        print("HEADTRIM no IDR picture in the first %d packets" % npk)
        return 1
    if cut == 0 and start == 0:
        print("HEADTRIM cut_packets=0 cut_access_units=0")
        return 0
    off = start + cut * 188
    tmp = path + ".head"
    with open(path, "rb") as src, open(tmp, "wb") as dst:
        src.seek(off)
        shutil.copyfileobj(src, dst, 16 * 1024 * 1024)
    os.replace(tmp, path)
    print("HEADTRIM cut_packets=%d cut_access_units=%d" % (cut, au))
    return 0


def skipidr_ts(path, n_idr=2):
    """Cut the capture before the PAT of the n-th IDR picture; count the video continuity errors of the cut part (see the module text)."""
    with open(path, "rb") as fh:
        data = fh.read()
    start = -1
    for i in range(min(len(data), 4000)):
        if all(i + k * 188 < len(data) and data[i + k * 188] == 0x47 for k in range(3)):
            start = i
            break
    if start < 0:
        print("SKIPIDR no sync")
        return 1
    npk = (len(data) - start) // 188
    last_pat = -1
    au = 0
    idr = 0
    cut = -1
    cc_last = None
    cc_err = 0
    errs_at = []
    for n in range(npk):
        p = data[start + n * 188: start + (n + 1) * 188]
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid == 0 and (p[1] & 0x40):
            last_pat = n
        if pid == 0x0100 and (p[3] >> 4) & 1:
            if cc_last is not None and ((cc_last + 1) & 15) != (p[3] & 15):
                errs_at.append(n)
            cc_last = p[3] & 15
        if pid == 0x0100 and (p[1] & 0x40):
            if ((p[3] >> 4) & 3) & 2 and p[4] >= 1 and (p[5] & 0x40):
                idr += 1
                if idr == n_idr:
                    cut = last_pat if (last_pat >= 0 and n - last_pat < 8) else n
                    break
            au += 1
    if cut < 0:
        print("SKIPIDR none")
        return 1
    cc_err = sum(1 for e in errs_at if e < cut)
    tmp = path + ".skip"
    with open(tmp, "wb") as dst:
        dst.write(data[start + cut * 188:])
    os.replace(tmp, path)
    print("SKIPIDR cut_packets=%d cut_access_units=%d cc_errors=%d" % (cut, au, cc_err))
    return 0


def trim_ts(path):
    """Cut the file before the last video PES start (PID 0x100): the access unit the capture stopped in is incomplete, and a trailing partial
    datagram goes with it. Prints "TRIM kept=<bytes> cut=<bytes>" and returns 0."""
    data = open(path, "rb").read()
    start = -1
    for i in range(min(len(data), 4000)):
        if all(i + k * 188 < len(data) and data[i + k * 188] == 0x47 for k in range(3)):
            start = i
            break
    if start < 0:
        print("TRIM no sync")
        return 1
    npk = (len(data) - start) // 188
    last = -1
    for n in range(npk - 1, -1, -1):
        p = data[start + n * 188: start + n * 188 + 4]
        if p[0] == 0x47 and (((p[1] & 0x1F) << 8) | p[2]) == 0x0100 and (p[1] & 0x40):
            last = n
            break
    if last <= 0:
        print("TRIM no video PES start")
        return 1
    cut = start + last * 188
    with open(path, "r+b") as fh:
        fh.truncate(cut)
    print("TRIM kept=%d cut=%d" % (cut, len(data) - cut))
    return 0


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


def _best_k(dec_y, pm, geom, pattern, speed, cands, cache):
    """k among cands whose expected luma is closest (lowest SSE) to the decoded luma; returns (k, planes of that k)."""
    import numpy as np
    best = None
    for k in cands:
        if k not in cache:
            cache[k] = pm.frame_yuv420(geom, pattern, speed, k)
        d = dec_y.astype(np.int32) - cache[k][0].astype(np.int32)
        sse = int((d * d).sum())
        if best is None or sse < best[0]:
            best = (sse, k)
    planes = cache[best[1]]
    while len(cache) > 12:
        cache.pop(min(k for k in cache if k != best[1]))
    return best[1], planes


def _plane_psnr(dec, exp):
    import numpy as np
    d = dec.astype(np.int32) - exp.astype(np.int32)
    sse = int((d * d).sum())
    return psnr_of(sse, dec.size)


def check_psnr_pattern(path, w, h, floor, max_frames, pattern, speed, k_first_max, step=1):
    """PSNR of every decoded picture against the pattern, k tracked per picture (see the module text)."""
    import numpy as np
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'cores', 'rtlnet_csi2_rx', 'testbench'))
    import pattern_model as pm
    c = Checker()
    fsize = w * h * 3 // 2
    nframes = os.path.getsize(path) // fsize
    if nframes == 0:
        c.report("psnr", False, "no decoded frame of %dx%d in %d bytes" % (w, h, os.path.getsize(path)))
        return c.fail
    want = nframes if max_frames <= 0 else min(max_frames, nframes)
    geom = (w, h)
    cache = {}
    k_prev = -1
    resyncs = 0
    dropped = 0
    unmatched = 0
    worst = 99.0
    worst_f = -1
    ks = []
    allm = []
    with open(path, "rb") as fh:
        for f in range(want):
            data = np.frombuffer(fh.read(fsize), dtype=np.uint8)
            y = data[: w * h].reshape(h, w)
            cb = data[w * h: w * h + w * h // 4].reshape(h // 2, w // 2)
            cr = data[w * h + w * h // 4:].reshape(h // 2, w // 2)
            if pattern == 0:
                k = 0
                planes = pm.frame_yuv420(geom, 0, speed, 0) if 0 not in cache else cache[0]
                cache[0] = planes
            else:
                cands = range(0, k_first_max + 1) if k_prev < 0 else range(k_prev + step, k_prev + step + 4 + (step // 8))
                k, planes = _best_k(y, pm, geom, pattern, speed, cands, cache)
                if k_prev >= 0 and k != k_prev + step:
                    resyncs += 1
                    dropped += k - k_prev - step
                k_prev = k
            py = _plane_psnr(y, planes[0])
            pu = _plane_psnr(cb, planes[1])
            pv = _plane_psnr(cr, planes[2])
            m = min(py, pu, pv)
            if m < floor:
                unmatched += 1
            if m < worst:
                worst = m
                worst_f = f
            ks.append(k)
            allm.append(m)
            if f < 3 or m < floor:
                print("PSNR frame %d k %d Y %.2f Cb %.2f Cr %.2f dB" % (f, k, py, pu, pv))
    print("PSNR worst frame %d at %.2f dB" % (worst_f, worst))
    print("PSNR_STAT min=%.2f mean=%.2f frames=%d step=%d" % (worst, sum(allm) / len(allm), len(allm), step))
    print("PSNR_K resyncs=%d dropped=%d first_k=%d last_k=%d pictures=%d" % (resyncs, dropped, ks[0], ks[-1], len(ks)))
    c.report("psnr", worst >= floor, "%d of %d decoded frames checked against pattern %d speed %d, minimum %.2f dB (floor %.1f), %d resyncs (%d pictures dropped), %d below the floor" %
             (want, nframes, pattern, speed, worst, floor, resyncs, dropped, unmatched))
    c.report("decoded_frames", nframes >= 1, "%d frames decoded" % nframes)
    return c.fail


def selftest(ffmpeg, keep):
    """Streams from the Python model through libx264 (pictures left out to force resyncs), decoded and checked."""
    import subprocess
    import tempfile
    import numpy as np
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'cores', 'rtlnet_csi2_rx', 'testbench'))
    import pattern_model as pm
    c = Checker()
    w, h = 640, 352
    cases = [(1, 4, [0, 1, 2, 3, 5, 6, 7, 10, 11, 12, 13, 14]),
             (2, -7, [0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12]),
             (3, 4, [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
             (4, 24, [0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12]),
             (0, 4, [0, 1, 2, 3, 4, 5])]
    with tempfile.TemporaryDirectory() as td:
        wd = keep or td
        os.makedirs(wd, exist_ok=True)
        for pattern, speed, klist in cases:
            raw = os.path.join(wd, "p%d_in.yuv" % pattern)
            out = os.path.join(wd, "p%d_out.yuv" % pattern)
            mp4 = os.path.join(wd, "p%d.mp4" % pattern)
            with open(raw, "wb") as fh:
                for k in klist:
                    yy, cb, cr = pm.frame_yuv420((w, h), pattern, speed, k)
                    fh.write(yy.tobytes() + cb.tobytes() + cr.tobytes())
            r1 = subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "%dx%d" % (w, h), "-r", "30", "-i", raw,
                                 "-c:v", "libx264", "-profile:v", "baseline", "-preset", "ultrafast", "-crf", "10", "-g", "8", "-bf", "0", mp4],
                                capture_output=True, text=True)
            r2 = subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", mp4, "-pix_fmt", "yuv420p", "-f", "rawvideo", out], capture_output=True, text=True)
            if r1.returncode != 0 or r2.returncode != 0:
                c.report("selftest_p%d" % pattern, False, "ffmpeg failed: %s %s" % (r1.stderr.strip(), r2.stderr.strip()))
                continue
            expect_resyncs = sum(1 for a, b in zip(klist, klist[1:]) if b != a + 1) if pattern != 0 else 0
            expect_dropped = sum(b - a - 1 for a, b in zip(klist, klist[1:])) if pattern != 0 else 0
            print("selftest pattern %d speed %d: %d pictures, expected %d resyncs, %d dropped" % (pattern, speed, len(klist), expect_resyncs, expect_dropped))
            import io
            buf = io.StringIO()
            old = sys.stdout
            sys.stdout = buf
            try:
                fails = check_psnr_pattern(out, w, h, 30.0, 0, pattern, speed, 8)
            finally:
                sys.stdout = old
            text = buf.getvalue()
            print(text.strip())
            line = [ln for ln in text.splitlines() if ln.startswith("PSNR_K")][0]
            got = dict(tok.split("=") for tok in line.split()[1:])
            ok = fails == 0 and int(got["resyncs"]) == expect_resyncs and int(got["dropped"]) == expect_dropped and (pattern == 0 or (int(got["first_k"]) == klist[0] and int(got["last_k"]) == klist[-1]))
            c.report("selftest_p%d" % pattern, ok, "resyncs %s (expected %d), dropped %s (expected %d), k %s..%s" %
                     (got["resyncs"], expect_resyncs, got["dropped"], expect_dropped, got["first_k"], got["last_k"]))
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
        tgt = float(argv[argv.index("--target-kbps") + 1]) if "--target-kbps" in argv else 0.0
        skip_s = float(argv[argv.index("--skip-s") + 1]) if "--skip-s" in argv else 2.0
        waive = set(int(x) for x in argv[argv.index("--waive") + 1].split(",") if x) if "--waive" in argv else set()
        mqs = int(argv[argv.index("--max-qp-step") + 1]) if "--max-qp-step" in argv else 0
        cct = float(argv[argv.index("--cc-tol-pct") + 1]) if "--cc-tol-pct" in argv else 0.0
        fidr = int(argv[argv.index("--forced-idr") + 1]) if "--forced-idr" in argv else -1
        return 1 if check_ts(argv[1], step, fps, gop, tgt, skip_s, "--gate10" in argv, waive, mqs, cct, fidr) else 0
    if len(argv) >= 4 and argv[0] == "psnr":
        floor = float(argv[argv.index("--floor") + 1]) if "--floor" in argv else 30.0
        if "--pattern" in argv:
            pattern = int(argv[argv.index("--pattern") + 1])
            speed = int(argv[argv.index("--speed") + 1]) if "--speed" in argv else 4
            kmax = int(argv[argv.index("--k-first-max") + 1]) if "--k-first-max" in argv else 64
            mx = int(argv[argv.index("--max-frames") + 1]) if "--max-frames" in argv else 0
            stp = int(argv[argv.index("--step") + 1]) if "--step" in argv else 1
            return 1 if check_psnr_pattern(argv[1], int(argv[2]), int(argv[3]), floor, mx, pattern, speed, kmax, stp) else 0
        mx = int(argv[argv.index("--max-frames") + 1]) if "--max-frames" in argv else 24
        return 1 if check_psnr(argv[1], int(argv[2]), int(argv[3]), floor, mx) else 0
    if len(argv) >= 3 and argv[0] == "reorder":
        return reorder_ts(argv[1], argv[2])
    if len(argv) >= 2 and argv[0] == "headtrim":
        return headtrim_ts(argv[1])
    if len(argv) >= 2 and argv[0] == "skipidr":
        return skipidr_ts(argv[1], int(argv[argv.index("--n") + 1]) if "--n" in argv else 2)
    if len(argv) >= 2 and argv[0] == "trim":
        return trim_ts(argv[1])
    if len(argv) >= 2 and argv[0] == "selftest":
        keep = argv[argv.index("--keep") + 1] if "--keep" in argv else None
        return 1 if selftest(argv[1], keep) else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
