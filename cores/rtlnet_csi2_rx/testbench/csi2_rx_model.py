#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File: csi2_rx_model.py
# Purpose: reference model of the camera receiver video path (rtlnet_csi2_rx_bayer and rtlnet_csi2_rx_yuv) and the generator of the
#   bench stimulus and expected-result files.
# Overview:
#   * Written from the behaviour in the file headers of the RTL, not from the RTL code: frame conditioning (pad or cut to the mode
#     geometry), black level, white balance gain of the Bayer site, bilinear demosaic with mirrored borders, 10 to 8 bits, the optional
#     piecewise-linear gamma, the highlight clamp (green >= level becomes max(green, red, blue), applied to the gained demosaiced 10-bit
#     values before the 8-bit scaling), then the BT.709 limited-range RGB to YUV 4:2:2 conversion (the arithmetic of the Q16 matrix with the
#     rounding offsets, chroma from the unrounded sums of the two pixels).
#   * The input pictures are built from a known RGB image: a smooth gradient with colour blocks and saturated corners, sampled
#     through the Bayer mosaic of the case phase into 10-bit raw values (eight bits of the colour, two bits of a deterministic dither).
#   * Output files per geometry set (the benches read them with $readmemh):
#       csi2_rx_<set>_cfg.mem   case table: word 0 = number of cases, then 16 words per case
#                               [iw, ih, W, H, mode, phase, black, gain_r, gain_g, gain_b, proc, raw_offset, exp_offset, kind, kline, hl_level]
#                               (proc = the PROC register: bit 0 gamma, bit 1 green equalisation, bit 2 highlight clamp)
#       csi2_rx_<set>_max.mem   expected RAW_MAX register word of every case (one 32-bit word per line): [9:0] red, [19:10] green,
#                               [29:20] blue maximum of the black-level-subtracted raw values of the conditioned frame
#       csi2_rx_<set>_raw.mem   raw pixels of all cases, one 10-bit value per line (three hex digits), case after case, row by row
#       csi2_rx_<set>_exp.mem   expected video words of all cases, one 32-bit word {Cr, Y1, Cb, Y0} per line
#   * Usage: csi2_rx_model.py --write <dir> | --verify <dir> | --selftest
#     --verify regenerates the files and fails when the committed files differ; --selftest runs the known-value checks of the
#     model (CRC-16 check value, ECC parity masks, constant picture, black and white).
# Language: Python 3 (no packages).
# Revision: 11-15-2026
#   * 11-15-2026: initial version; green equalisation (gamma word bit 1); highlight clamp (proc bit 2, level in cfg word 15), raw maxima,
#     the clipped-highlight scene.
# -----------------------------------------------------------------------------
import os
import sys

GAMMA_Y = [0, 72, 99, 119, 136, 151, 164, 175, 186, 197, 206, 215, 224, 232, 240, 248, 255]

# set name -> (mode 0 geometry, mode 1 geometry, cases)
# case: (name, iw, ih, mode, phase, black, gr, gg, gb, gamma word: bit 0 gamma, bit 1 green equalisation, bit 2 highlight clamp
#        [, kind, kline [, scene, hl_level]])   scene 'clip' = bright area with a clipped green (see clip_scene); hl_level is an integer
#        or ('edge', d): the green of the first edge pixel the clamp changes, plus d
SETS = {
    'small': {
        'geom': {0: (32, 8), 1: (24, 10)},
        'cases': [
            ('exact_p0',   32, 8,  0, 0, 0,  0x100, 0x100, 0x100, 0),
            ('exact_p1',   32, 8,  0, 1, 16, 0x180, 0x100, 0x1C0, 1),
            ('exact_p2',   32, 8,  0, 2, 0,  0x100, 0x100, 0x100, 1),
            ('exact_p3',   32, 8,  0, 3, 40, 0x230, 0x0E0, 0x2A0, 0),
            ('mode1_p0',   24, 10, 1, 0, 0,  0x100, 0x100, 0x100, 0),
            ('short_pad',  12, 6,  0, 0, 0,  0x100, 0x100, 0x100, 0),
            ('long_cut',   40, 10, 0, 2, 8,  0x140, 0x100, 0x140, 0),
            ('cut3',       32, 8,  0, 0, 0,  0x100, 0x100, 0x100, 0, 3, 3),
            # gamma word 2 = green equalisation, 3 = green equalisation and gamma (PROC bits 1 and 0)
            ('geq_p3',     32, 8,  0, 3, 0,  0x163, 0x100, 0x163, 2),
            ('geq_p1_g',   32, 8,  0, 1, 16, 0x180, 0x100, 0x1C0, 3),
            # Clipped highlight (green raw clipped at 720, red 560, blue 600 above the black level 16; gains of the OV5640 at 1080p):
            # clamp off (pink), on at level 700, level equal to an edge green (that pixel qualifies), one above it (that pixel does not),
            # level 0 (every pixel), level 1023 (none), another Bayer phase with green equalisation and gamma.
            ('clip_off',     32, 8, 0, 0, 16, 0x195, 0x100, 0x17C, 0, 0, 0, 'clip', 0),
            ('clip_hl',      32, 8, 0, 0, 16, 0x195, 0x100, 0x17C, 4, 0, 0, 'clip', 700),
            ('clip_edge_eq', 32, 8, 0, 0, 16, 0x195, 0x100, 0x17C, 4, 0, 0, 'clip', ('edge', 0)),
            ('clip_edge_p1', 32, 8, 0, 0, 16, 0x195, 0x100, 0x17C, 4, 0, 0, 'clip', ('edge', 1)),
            ('clip_lvl0',    32, 8, 0, 0, 16, 0x195, 0x100, 0x17C, 4, 0, 0, 'clip', 0),
            ('clip_lvl1023', 32, 8, 0, 0, 16, 0x195, 0x100, 0x17C, 4, 0, 0, 'clip', 1023),
            ('clip_p3_all',  32, 8, 0, 3, 16, 0x195, 0x100, 0x17C, 7, 0, 0, 'clip', 700),
        ],
    },
    # Fault cases of the full-path bench (small geometry): kind 1 = line k never arrives, kind 2 = line k arrives with 4 pixels only,
    # kind 3 = only the first k lines arrive.
    'fault': {
        'geom': {0: (32, 8), 1: (24, 10)},
        'cases': [
            ('lost_line3',  32, 8, 0, 0, 0, 0x100, 0x100, 0x100, 0, 1, 3),
            ('trunc_line5', 32, 8, 0, 0, 0, 0x100, 0x100, 0x100, 0, 2, 5),
            ('lost_line0',  32, 8, 0, 1, 0, 0x100, 0x100, 0x100, 0, 1, 0),
            ('exact_f',     32, 8, 0, 0, 0, 0x100, 0x100, 0x100, 0, 0, 0),
            ('cut3_f',      32, 8, 0, 0, 0, 0x100, 0x100, 0x100, 0, 3, 3),
        ],
    },
    'wide': {
        'geom': {0: (1280, 4), 1: (1920, 4)},
        'cases': [
            ('w1280_p0', 1280, 4, 0, 0, 0, 0x100, 0x100, 0x100, 0),
            ('w1920_p2', 1920, 4, 1, 2, 16, 0x1A0, 0x100, 0x180, 1),
        ],
    },
}


def clip(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def crc16(data):
    c = 0xFFFF
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0x8408 if c & 1 else c >> 1
    return c


ECC_MASKS = [0xF12CB7, 0xF2555B, 0x749A6D, 0xB8E38E, 0xDF03F0, 0xEFFC00]


def hdr_ecc(d24):
    e = 0
    for i, m in enumerate(ECC_MASKS):
        e |= (bin(d24 & m).count('1') & 1) << i
    return e


def rgb_image(w, h):
    """Known RGB picture: gradients, colour blocks, saturated corners. Returns rows of (r, g, b) 8-bit."""
    img = []
    for y in range(h):
        row = []
        for x in range(w):
            r = (x * 255) // max(w - 1, 1)
            g = (y * 255) // max(h - 1, 1)
            b = 255 - ((x + y) * 255) // max(w + h - 2, 1)
            if (x // 4 + y // 2) % 5 == 0:
                r, g, b = 255 - r, 255 - g, 255 - b
            if x < 2 and y < 2:
                r, g, b = 255, 255, 255
            if x >= w - 2 and y >= h - 2:
                r, g, b = 0, 0, 0
            row.append((r, g, b))
        img.append(row)
    return img


def site(x, y, phase):
    """0 R, 1 G, 2 B, with (u, v) the RGGB-frame coordinates."""
    u = (x & 1) ^ (phase & 1)
    v = (y & 1) ^ ((phase >> 1) & 1)
    if u == 0 and v == 0:
        return 'R', u, v
    if u == 1 and v == 1:
        return 'B', u, v
    return 'G', u, v


def mosaic(img, w, h, phase):
    raw = []
    for y in range(h):
        row = []
        for x in range(w):
            r, g, b = img[y][x]
            s = site(x, y, phase)[0]
            c = r if s == 'R' else (g if s == 'G' else b)
            row.append(min(1023, (c << 2) | ((x * 3 + y * 5) & 3)))
        raw.append(row)
    return raw


def condition(rows, W, H):
    """rows: the input lines as received (any lengths); every line is cut or padded to W, the frame to H lines."""
    out = []
    for y in range(H):
        src = rows[y] if y < len(rows) else []
        out.append([src[x] if x < len(src) else 0 for x in range(W)])
    return out


def preprocess(raw, W, H, phase, black, gr, gg, gb):
    out = []
    for y in range(H):
        row = []
        for x in range(W):
            s = site(x, y, phase)[0]
            g = gr if s == 'R' else (gb if s == 'B' else gg)
            t = max(raw[y][x] - black, 0)
            row.append(min(1023, (t * g + 128) >> 8))
        out.append(row)
    return out


def mirror(i, n):
    if i < 0:
        return -i
    if i >= n:
        return 2 * (n - 1) - i
    return i


def demosaic(p, W, H, phase, geq=0):
    out = []
    for y in range(H):
        row = []
        for x in range(W):
            def px(dx, dy):
                return p[mirror(y + dy, H)][mirror(x + dx, W)]
            c = px(0, 0)
            n, s, w_, e = px(0, -1), px(0, 1), px(-1, 0), px(1, 0)
            nw, ne, sw, se = px(-1, -1), px(1, -1), px(-1, 1), px(1, 1)
            kind, u, v = site(x, y, phase)
            cross = (n + s + w_ + e + 2) >> 2
            diag = (nw + ne + sw + se + 2) >> 2
            horz = (w_ + e + 1) >> 1
            vert = (n + s + 1) >> 1
            if kind == 'R':
                rgb = (c, cross, diag)
            elif kind == 'B':
                rgb = (diag, cross, c)
            elif u == 1 and v == 0:          # G on a red row
                rgb = (horz, (c + diag + 1) >> 1 if geq else c, vert)
            else:                            # G on a blue row
                rgb = (vert, (c + diag + 1) >> 1 if geq else c, horz)
            row.append(rgb)
        out.append(row)
    return out


def to8(v):
    return min(255, (v + 2) >> 2)


def gamma8(v, en):
    if not en:
        return v
    seg, frac = v >> 4, v & 15
    y0, y1 = GAMMA_Y[seg], GAMMA_Y[seg + 1]
    return y0 + (((y1 - y0) * frac) >> 4)


def yuv_terms(r, g, b):
    y = 11966 * r + 40254 * g + 4064 * b + 1081344
    cb = -6596 * r - 22189 * g + 28784 * b + 8421376
    cr = 28784 * r - 26145 * g - 2639 * b + 8421376
    return y, cb, cr


def yuv_words(rgb8, W, H):
    words = []
    for y in range(H):
        for x in range(0, W, 2):
            y0, cb0, cr0 = yuv_terms(*rgb8[y][x])
            y1, cb1, cr1 = yuv_terms(*rgb8[y][x + 1])
            ya = clip(y0 >> 16, 16, 235)
            yb = clip(y1 >> 16, 16, 235)
            cb = clip((cb0 + cb1) >> 17, 16, 240)
            cr = clip((cr0 + cr1) >> 17, 16, 240)
            words.append((cr << 24) | (yb << 16) | (cb << 8) | ya)
    return words


def highlight(d, hl, level):
    """Highlight clamp on the gained demosaiced 10-bit triples: green >= level becomes max(green, red, blue)."""
    if not hl:
        return d
    return [[((r, max(g, r, b), b) if g >= level else (r, g, b)) for (r, g, b) in row] for row in d]


def raw_max(rows, W, H, phase, black):
    """RAW_MAX of a frame: maxima of the black-level-subtracted raw values of the conditioned frame at red, green and blue sites."""
    c = condition(rows, W, H)
    m = {'R': 0, 'G': 0, 'B': 0}
    for y in range(H):
        for x in range(W):
            k = site(x, y, phase)[0]
            m[k] = max(m[k], max(c[y][x] - black, 0))
    return (m['B'] << 20) | (m['G'] << 10) | m['R']


def demosaiced(rows, W, H, phase, black, gr, gg, gb, gamma, hll=0):
    c = condition(rows, W, H)
    p = preprocess(c, W, H, phase, black, gr, gg, gb)
    # The gamma word of a case: bit 0 gamma curve, bit 1 green equalisation, bit 2 highlight clamp (PROC register bits).
    d = demosaic(p, W, H, phase, (gamma >> 1) & 1)
    return highlight(d, (gamma >> 2) & 1, hll)


def expected_rgb8(rows, W, H, phase, black, gr, gg, gb, gamma, hll=0):
    d = demosaiced(rows, W, H, phase, black, gr, gg, gb, gamma, hll)
    return [[tuple(gamma8(to8(v), gamma & 1) for v in px) for px in row] for row in d]


def expected(rows, W, H, phase, black, gr, gg, gb, gamma, hll=0):
    return yuv_words(expected_rgb8(rows, W, H, phase, black, gr, gg, gb, gamma, hll), W, H)


# Clipped-highlight scene: a bright area (x 10..21, y 1..6) on a dark gradient. The sensor clips green at 720 (the dither lowers it by
# 0..3), red and blue are not clipped (560 and 600); all above the black level.
CLIP_X0, CLIP_X1, CLIP_Y0, CLIP_Y1 = 10, 22, 1, 7


def clip_scene(w, h, phase, black):
    raw = []
    for y in range(h):
        row = []
        for x in range(w):
            k = site(x, y, phase)[0]
            dth = (x * 3 + y * 5) & 3
            if CLIP_X0 <= x < CLIP_X1 and CLIP_Y0 <= y < CLIP_Y1:
                v = (560 + dth) if k == 'R' else ((600 + dth) if k == 'B' else (720 - dth))
            else:
                v = 50 + ((x * 7 + y * 13) % 200) + dth
            row.append(min(1023, v + black))
        raw.append(row)
    return raw


def edge_level(rows, W, H, phase, black, gr, gg, gb, gamma):
    """Green (gained, demosaiced) of the first pixel whose green the clamp changes by a visible step, and its position."""
    d = demosaiced(rows, W, H, phase, black, gr, gg, gb, gamma & 3, 0)
    for y in range(H):
        for x in range(W):
            r_, g_, b_ = d[y][x]
            if g_ > 300 and max(r_, b_) - g_ >= 16 and g_ < 700:
                return g_, (x, y)
    raise ValueError('no edge pixel')


def build_set(name):
    s = SETS[name]
    cfg = [len(s['cases'])]
    raws, exps, maxes = [], [], []
    for case in s['cases']:
        (cname, iw, ih, mode, phase, black, gr, gg, gb, gamma) = case[:10]
        kind, kline = (case[10], case[11]) if len(case) > 10 else (0, 0)
        scene, hll = (case[12], case[13]) if len(case) > 12 else ('rgb', 0)
        W, H = s['geom'][mode]
        if scene == 'clip':
            raw = clip_scene(iw, ih, phase, black)
        else:
            raw = mosaic(rgb_image(iw, ih), iw, ih, phase)
        if isinstance(hll, tuple):
            hll = edge_level([list(r) for r in raw], W, H, phase, black, gr, gg, gb, gamma)[0] + hll[1]
        rows = [list(r) for r in raw]
        if kind == 1:
            del rows[kline]
        elif kind == 2:
            rows[kline] = rows[kline][:4]
        elif kind == 3:
            rows = rows[:kline]
        words = expected(rows, W, H, phase, black, gr, gg, gb, gamma, hll)
        maxes.append(raw_max(rows, W, H, phase, black))
        cfg += [iw, ih, W, H, mode, phase, black, gr, gg, gb, gamma, len(raws), len(exps), kind, kline, hll]
        for row in raw:
            raws += row
        exps += words
    return cfg, raws, exps, maxes


def files_for(name):
    cfg, raws, exps, maxes = build_set(name)
    return {
        'csi2_rx_%s_cfg.mem' % name: ''.join('%08x\n' % v for v in cfg),
        'csi2_rx_%s_raw.mem' % name: ''.join('%03x\n' % v for v in raws),
        'csi2_rx_%s_exp.mem' % name: ''.join('%08x\n' % v for v in exps),
        'csi2_rx_%s_max.mem' % name: ''.join('%08x\n' % v for v in maxes),
    }


def selftest():
    ok = True
    if crc16(b'123456789') != 0x6F91:
        print('SELFTEST FAIL crc16'); ok = False
    # one flipped header bit changes the parity; every data column is distinct and of weight 3 or 5
    cols = set()
    for i in range(24):
        col = tuple((m >> i) & 1 for m in ECC_MASKS)
        cols.add(col)
        if sum(col) not in (3, 5):
            ok = False
    if len(cols) != 24:
        print('SELFTEST FAIL ecc columns'); ok = False
    # constant colour: mosaic, demosaic and conversion give that colour back
    for (r, g, b) in ((200, 100, 50), (255, 255, 255), (0, 0, 0), (17, 240, 130)):
        img = [[(r, g, b)] * 8 for _ in range(6)]
        for ph in range(4):
            raw = [[min(1023, (img[y][x][0 if site(x, y, ph)[0] == 'R' else (1 if site(x, y, ph)[0] == 'G' else 2)] << 2))
                    for x in range(8)] for y in range(6)]
            words = expected(raw, 8, 6, ph, 0, 0x100, 0x100, 0x100, 0)
            y_, cb, cr = yuv_terms(r, g, b)
            ye, cbe, cre = clip(y_ >> 16, 16, 235), clip((2 * cb) >> 17, 16, 240), clip((2 * cr) >> 17, 16, 240)
            exp = (cre << 24) | (ye << 16) | (cbe << 8) | ye
            if any(w != exp for w in words):
                print('SELFTEST FAIL constant picture', (r, g, b), ph, hex(words[0]), hex(exp)); ok = False
    w = expected([[1023] * 4] * 4, 4, 4, 0, 0, 0x100, 0x100, 0x100, 0)
    if w[0] != 0x80EB80EB:
        print('SELFTEST FAIL white', hex(w[0])); ok = False
    w = expected([[0] * 4] * 4, 4, 4, 0, 0, 0x100, 0x100, 0x100, 0)
    if w[0] != 0x80108010:
        print('SELFTEST FAIL black', hex(w[0])); ok = False
    for k in range(16):
        if not (GAMMA_Y[k] < GAMMA_Y[k + 1]):
            print('SELFTEST FAIL gamma table'); ok = False
    # Highlight clamp: rule, boundary and the pink highlight of the clipped scene.
    w_, h_ = 32, 8
    gains = (0x195, 0x100, 0x17C)
    for ph in (0, 3):
        raw = clip_scene(w_, h_, ph, 16)
        off = demosaiced(raw, w_, h_, ph, 16, *gains, 0)
        for y in (3, 4):
            for x in range(12, 20):
                r_, g_, b_ = off[y][x]
                if not (g_ < r_ and g_ < b_):
                    print('SELFTEST FAIL clipped scene not pink', ph, x, y, off[y][x]); ok = False
        on = demosaiced(raw, w_, h_, ph, 16, *gains, 4, 700)
        for y in range(h_):
            for x in range(w_):
                r_, g_, b_ = off[y][x]
                want = (r_, max(g_, r_, b_), b_) if g_ >= 700 else (r_, g_, b_)
                if on[y][x] != want:
                    print('SELFTEST FAIL highlight rule', ph, x, y, on[y][x], want); ok = False
        for y in (3, 4):
            for x in range(12, 20):
                if on[y][x][1] != max(on[y][x][0], on[y][x][2]):
                    print('SELFTEST FAIL highlight interior not neutral', ph, x, y, on[y][x]); ok = False
        rgb_off = expected_rgb8(raw, w_, h_, ph, 16, *gains, 0)
        rgb_on = expected_rgb8(raw, w_, h_, ph, 16, *gains, 4, 700)
        if not (rgb_off[3][15][0] > rgb_off[3][15][1] + 20 and abs(rgb_on[3][15][0] - rgb_on[3][15][1]) < 8):
            print('SELFTEST FAIL clipped highlight 8-bit', ph, rgb_off[3][15], rgb_on[3][15]); ok = False
        lvl, (ex, ey) = edge_level(raw, w_, h_, ph, 16, *gains, 0)
        a = demosaiced(raw, w_, h_, ph, 16, *gains, 4, lvl)[ey][ex]
        b = demosaiced(raw, w_, h_, ph, 16, *gains, 4, lvl + 1)[ey][ex]
        if not (a[1] > lvl and b[1] == lvl):
            print('SELFTEST FAIL level boundary', ph, lvl, a, b); ok = False
        if demosaiced(raw, w_, h_, ph, 16, *gains, 0, 700) != off:
            print('SELFTEST FAIL clamp off changes the picture'); ok = False
    # Raw maxima of a raw frame with one constant value per site kind.
    raw = [[(100 if site(x, y, 0)[0] == 'R' else (200 if site(x, y, 0)[0] == 'G' else 300)) for x in range(4)] for y in range(4)]
    if raw_max(raw, 4, 4, 0, 10) != ((290 << 20) | (190 << 10) | 90):
        print('SELFTEST FAIL raw max', hex(raw_max(raw, 4, 4, 0, 10))); ok = False
    print('CSI2_RX_MODEL: %s' % ('PASS' if ok else 'FAIL'))
    return ok


def main(argv):
    if len(argv) >= 2 and argv[1] == '--selftest':
        return 0 if selftest() else 1
    if len(argv) >= 3 and argv[1] in ('--write', '--verify'):
        d = argv[2]
        os.makedirs(d, exist_ok=True)
        bad = 0
        for name in SETS:
            for fn, text in files_for(name).items():
                path = os.path.join(d, fn)
                if argv[1] == '--write':
                    with open(path, 'w', newline='\n') as f:
                        f.write(text)
                else:
                    got = open(path, newline='').read().replace('\r\n', '\n') if os.path.exists(path) else ''
                    if got != text:
                        print('CSI2_RX_MODEL: %s differs from the model (run --write)' % fn)
                        bad += 1
        if argv[1] == '--verify':
            if bad:
                return 1
            print('CSI2_RX_MODEL: PASS files equal the model')
        return 0
    print(__doc__ if __doc__ else 'usage: csi2_rx_model.py --write <dir> | --verify <dir> | --selftest')
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
