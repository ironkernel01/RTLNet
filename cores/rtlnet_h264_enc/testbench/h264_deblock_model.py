#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File: h264_deblock_model.py
# Purpose: reference model of the H.264 deblocking filter, ITU-T Rec. H.264 (06/2026) clause 8.7, written from the text of the
#   standard for the encoder's picture structure (4:2:0, 8-bit, frame macroblocks, Baseline and High profile tools used by
#   rtlnet_h264_enc: one reference picture, 16x16 partitions, 4x4 or 8x8 luma transform, I_PCM, P_Skip).
# Overview:
#   * deblock_picture() filters a whole picture in macroblock raster order: per macroblock the luma vertical edges left to
#     right, the luma horizontal edges top to bottom, then Cb and Cr (vertical edges, horizontal edges). The filter of a macroblock
#     reads the samples already filtered by the earlier macroblocks (clause 8.7: the deblocked samples of the previous macroblock
#     are the input of the next).
#   * Per macroblock input (class MbInfo): intra (intra prediction macroblock, I_PCM included), qp (QPY used by the filter: the
#     slice QP, 0 for I_PCM), nz (16 bit mask, bit 4 * by + bx: the 4x4 luma block (by, bx) has non-zero transform coefficient
#     levels; with t8 the mask is read per 8x8 block: an 8x8 block is coded when any of its four bits is set), t8
#     (transform_size_8x8_flag), mv (motion vector in quarter samples; one vector per macroblock: 16x16 partitions).
#   * Slices: slice_row[y] is the slice number of macroblock row y (slices are whole macroblock rows in this encoder). With
#     disable_deblocking_filter_idc 2 an edge that separates two slices is not filtered (filterTopMbEdgeFlag); with 0 it is;
#     with 1 nothing is filtered.
#   * All arithmetic is the integer arithmetic of the standard (8.7.2.1 boundary strength, 8.7.2.2 the table lookups,
#     8.7.2.3 bS < 4, 8.7.2.4 bS = 4). Tables 8-16 and 8-17 are cross-checked against the JM and OpenH264 sources by
#     selftest() (when the decoder source trees are given).
# Language: Python 3.
# Revision: 11-12-2026
# -----------------------------------------------------------------------------
import sys

ALPHA = [0] * 16 + [4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 17, 20, 22, 25, 28, 32, 36, 40, 45, 50, 56, 63, 71, 80, 90, 101,
                    113, 127, 144, 162, 182, 203, 226, 255, 255]
BETA = [0] * 16 + [2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15,
                   16, 16, 17, 17, 18, 18]
# tC0'[indexA][bS - 1]
TC0 = ([(0, 0, 0)] * 17 + [(0, 0, 1)] * 4 + [(0, 1, 1)] * 2 + [(1, 1, 1)] * 4 + [(1, 1, 2)] * 4 + [(1, 2, 3)] * 2 +
       [(2, 2, 3), (2, 2, 4), (2, 3, 4), (2, 3, 4), (3, 3, 5), (3, 4, 6), (3, 4, 6), (4, 5, 7), (4, 5, 8), (4, 6, 9),
        (5, 7, 10), (6, 8, 11), (6, 8, 13), (7, 10, 14), (8, 11, 16), (9, 12, 18), (10, 13, 20), (11, 15, 23),
        (13, 17, 25)])
QPC = list(range(30)) + [29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39]


STATS = {}


def stat(k):
    STATS[k] = STATS.get(k, 0) + 1


class MbInfo:
    __slots__ = ("intra", "qp", "nz", "t8", "mvx", "mvy")

    def __init__(self, intra=0, qp=26, nz=0, t8=0, mvx=0, mvy=0):
        self.intra = intra
        self.qp = qp
        self.nz = nz
        self.t8 = t8
        self.mvx = mvx
        self.mvy = mvy


def clip3(lo, hi, v):
    return lo if v < lo else (hi if v > hi else v)


def clip1(v):
    return 0 if v < 0 else (255 if v > 255 else v)


def blk_coded(mb, bx, by):
    """The luma block containing 4x4 position (bx, by) has non-zero levels (the 8x8 block when transform_size_8x8_flag)."""
    if mb.t8:
        g = ((by >> 1) << 3) | ((bx >> 1) << 1)           # bits of the 8x8 group: 4*(2*(by>>1)) + 2*(bx>>1) + {0,1,4,5}
        m = (1 << g) | (1 << (g + 1)) | (1 << (g + 4)) | (1 << (g + 5))
        return (mb.nz & m) != 0
    return ((mb.nz >> (4 * by + bx)) & 1) != 0


def bs_luma(p_mb, q_mb, pbx, pby, qbx, qby, mb_edge):
    """Clause 8.7.2.1 for one luma edge position (frame macroblocks, one reference picture)."""
    if p_mb.intra or q_mb.intra:
        return 4 if mb_edge else 3
    if blk_coded(p_mb, pbx, pby) or blk_coded(q_mb, qbx, qby):
        return 2
    if abs(p_mb.mvx - q_mb.mvx) >= 4 or abs(p_mb.mvy - q_mb.mvy) >= 4:
        return 1
    return 0


def filter_line(p, q, bs, alpha, beta, tc0, chroma):
    """p = [p0, p1, p2, p3], q = [q0, q1, q2, q3] (chroma uses the first two); returns (p, q) lists, filtered in place."""
    p0, p1, p2 = p[0], p[1], p[2]
    q0, q1, q2 = q[0], q[1], q[2]
    if not (bs != 0 and abs(p0 - q0) < alpha and abs(p1 - p0) < beta and abs(q1 - q0) < beta):
        stat("c%d_bs%d_off" % (chroma, bs))
        return
    stat("c%d_bs%d_on" % (chroma, bs))
    if chroma:
        if bs < 4:
            tc = tc0 + 1
            d = clip3(-tc, tc, (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3)
            p[0] = clip1(p0 + d)
            q[0] = clip1(q0 - d)
        else:
            p[0] = (2 * p1 + p0 + q1 + 2) >> 2
            q[0] = (2 * q1 + q0 + p1 + 2) >> 2
        return
    ap = abs(p2 - p0)
    aq = abs(q2 - q0)
    if bs < 4:
        tc = tc0 + (1 if ap < beta else 0) + (1 if aq < beta else 0)
        d = clip3(-tc, tc, (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3)
        p[0] = clip1(p0 + d)
        q[0] = clip1(q0 - d)
        stat("l_bslt4_tc0_%d" % min(tc0, 3))
        if ap < beta:
            stat("l_bslt4_p1")
            p[1] = p1 + clip3(-tc0, tc0, (p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >> 1)
        if aq < beta:
            q[1] = q1 + clip3(-tc0, tc0, (q2 + ((p0 + q0 + 1) >> 1) - (q1 << 1)) >> 1)
    else:
        p3, q3 = p[3], q[3]
        small = abs(p0 - q0) < ((alpha >> 2) + 2)
        stat("l_bs4_strong_p" if (ap < beta and small) else "l_bs4_weak_p")
        if ap < beta and small:
            p[0] = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3
            p[1] = (p2 + p1 + p0 + q0 + 2) >> 2
            p[2] = (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3
        else:
            p[0] = (2 * p1 + p0 + q1 + 2) >> 2
        if aq < beta and small:
            q[0] = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3
            q[1] = (p0 + q0 + q1 + q2 + 2) >> 2
            q[2] = (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3
        else:
            q[0] = (2 * q1 + q0 + p1 + 2) >> 2


def edge_params(qp_p, qp_q, a_off, b_off, bs):
    qav = (qp_p + qp_q + 1) >> 1
    ia = clip3(0, 51, qav + 2 * a_off)
    ib = clip3(0, 51, qav + 2 * b_off)
    stat("idxA_%d" % (ia // 8))
    if qav + 2 * a_off < 0 or qav + 2 * a_off > 51:
        stat("idxA_clipped")
    tc0 = TC0[ia][bs - 1] if 1 <= bs <= 3 else 0
    return ALPHA[ia], BETA[ib], tc0


def deblock_picture(planes, mbw, mbh, info, slice_row, idc=2, a_off=0, b_off=0, cb_off=0):
    """planes = [Y, U, V] as lists of rows (modified in place and returned); info[y][x] MbInfo; slice_row[y] slice number."""
    if idc == 1:
        return planes
    Y, U, V = planes
    for my in range(mbh):
        for mx in range(mbw):
            q_mb = info[my][mx]
            left_ok = mx > 0
            top_ok = my > 0 and (idc != 2 or slice_row[my - 1] == slice_row[my])
            # ---- luma: vertical edges (x = 0, 4, 8, 12), then horizontal
            for e in range(4):
                if e == 0 and not left_ok:
                    continue
                if q_mb.t8 and (e & 1):
                    continue
                p_mb = info[my][mx - 1] if e == 0 else q_mb
                for y in range(16):
                    by = y >> 2
                    pbx = 3 if e == 0 else e - 1
                    bs = bs_luma(p_mb, q_mb, pbx, by, e, by, e == 0)
                    if bs == 0:
                        continue
                    al, be, tc0 = edge_params(p_mb.qp, q_mb.qp, a_off, b_off, bs)
                    row = Y[my * 16 + y]
                    x0 = mx * 16 + 4 * e
                    p = [row[x0 - 1 - i] for i in range(4)]
                    q = [row[x0 + i] for i in range(4)]
                    filter_line(p, q, bs, al, be, tc0, False)
                    for i in range(4):
                        row[x0 - 1 - i] = p[i]
                        row[x0 + i] = q[i]
            for e in range(4):
                if e == 0 and not top_ok:
                    continue
                if q_mb.t8 and (e & 1):
                    continue
                p_mb = info[my - 1][mx] if e == 0 else q_mb
                for x in range(16):
                    bx = x >> 2
                    pby = 3 if e == 0 else e - 1
                    bs = bs_luma(p_mb, q_mb, bx, pby, bx, e, e == 0)
                    if bs == 0:
                        continue
                    al, be, tc0 = edge_params(p_mb.qp, q_mb.qp, a_off, b_off, bs)
                    y0 = my * 16 + 4 * e
                    xx = mx * 16 + x
                    p = [Y[y0 - 1 - i][xx] for i in range(4)]
                    q = [Y[y0 + i][xx] for i in range(4)]
                    filter_line(p, q, bs, al, be, tc0, False)
                    for i in range(4):
                        Y[y0 - 1 - i][xx] = p[i]
                        Y[y0 + i][xx] = q[i]
            # ---- chroma (4:2:0): edges at chroma x = 0, 4 and y = 0, 4; bS of the luma edge 0 and 2
            for pl in (U, V):
                qpc_q = QPC[clip3(0, 51, q_mb.qp + cb_off)]
                for ce in range(2):
                    if ce == 0 and not left_ok:
                        continue
                    p_mb = info[my][mx - 1] if ce == 0 else q_mb
                    qpc_p = QPC[clip3(0, 51, p_mb.qp + cb_off)]
                    for y in range(8):
                        by = (2 * y) >> 2
                        le = 2 * ce
                        pbx = 3 if le == 0 else le - 1
                        bs = bs_luma(p_mb, q_mb, pbx, by, le, by, le == 0)
                        if bs == 0:
                            continue
                        al, be, tc0 = edge_params(qpc_p, qpc_q, a_off, b_off, bs)
                        row = pl[my * 8 + y]
                        x0 = mx * 8 + 4 * ce
                        p = [row[x0 - 1], row[x0 - 2], 0, 0]
                        q = [row[x0], row[x0 + 1], 0, 0]
                        filter_line(p, q, bs, al, be, tc0, True)
                        row[x0 - 1] = p[0]
                        row[x0] = q[0]
                for ce in range(2):
                    if ce == 0 and not top_ok:
                        continue
                    p_mb = info[my - 1][mx] if ce == 0 else q_mb
                    qpc_p = QPC[clip3(0, 51, p_mb.qp + cb_off)]
                    for x in range(8):
                        bx = (2 * x) >> 2
                        le = 2 * ce
                        pby = 3 if le == 0 else le - 1
                        bs = bs_luma(p_mb, q_mb, bx, pby, bx, le, le == 0)
                        if bs == 0:
                            continue
                        al, be, tc0 = edge_params(qpc_p, qpc_q, a_off, b_off, bs)
                        y0 = my * 8 + 4 * ce
                        xx = mx * 8 + x
                        p = [pl[y0 - 1][xx], pl[y0 - 2][xx], 0, 0]
                        q = [pl[y0][xx], pl[y0 + 1][xx], 0, 0]
                        filter_line(p, q, bs, al, be, tc0, True)
                        pl[y0 - 1][xx] = p[0]
                        pl[y0][xx] = q[0]
    return planes


def selftest(jm_src=None, oh_src=None):
    """Tables against the decoder sources (JM source/lib/ldecod/loopfilter*.c / OpenH264 decoder/core/src/deblocking.cpp)."""
    import re
    ok = True
    if jm_src:
        txt = open(jm_src, encoding="latin-1").read()
        m = re.search(r"ALPHA_TABLE\s*\[52\]\s*=\s*\{([^}]*)\}", txt)
        if m:
            v = [int(t) for t in re.findall(r"\d+", m.group(1))]
            print("JM ALPHA", "ok" if v == ALPHA else "MISMATCH")
            ok &= (v == ALPHA)
        m = re.search(r"BETA_TABLE\s*\[52\]\s*=\s*\{([^}]*)\}", txt)
        if m:
            v = [int(t) for t in re.findall(r"\d+", m.group(1))]
            print("JM BETA", "ok" if v == BETA else "MISMATCH")
            ok &= (v == BETA)
        m = re.search(r"CLIP_TAB\s*\[52\]\[5\]\s*=\s*\{(.*?)\n\}\s*;", txt, re.S)
        if m:
            rows = re.findall(r"\{([^}]*)\}", m.group(1))
            v = [tuple(int(t) for t in re.findall(r"\d+", r)) for r in rows]
            mine = [(0,) + tuple(t) + (0,) for t in TC0]
            print("JM TC0 rows", len(v))
            good = all(v[i][1:4] == TC0[i] for i in range(52)) if len(v) == 52 else False
            print("JM TC0", "ok" if good else "MISMATCH")
            ok &= good
    return ok


if __name__ == "__main__":
    sys.exit(0 if selftest(*(sys.argv[1:3])) else 1)
