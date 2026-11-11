/*
 * csi2_bars_model.c -- host C model of the rtlnet_csi2_rx test-pattern generator
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the reference for the frame the generator sends and rtlnet_vdma_s2mm writes into a frame-buffer slot. It
 * implements documentation/rtlnet_csi2_rx.md section 3 directly and shares no code with the RTL, the bench or the firmware.
 *
 * Static bars (pattern 0, the reset default): eight vertical 75 percent color bars, full height. Bar b covers pixels
 * [b * W / 8, (b + 1) * W / 8): 160 pixels at 720p, 240 at 1080p. Colors are the ITU-R BT.709 8-bit limited-range
 * values of the gige.md section 5.4 table. YUV422, two pixels per four bytes in memory order Y0 Cb Y1 Cr. Lines are
 * packed (stride = W * 2 bytes).
 *
 * Moving patterns: a frame is a pure function of (mode, pattern, speed, k), k the pattern frame counter (0 for the first
 * frame after a PATTERN write or a VIDEO_MODE change). Per pixel, three layers, the upper covers the lower:
 *   bars  s = (x - off) mod W, off = (speed * k) mod W when the pattern scrolls (1, 4) else 0; Y from bar s / (W / 8);
 *         Cb, Cr of a pixel pair from the bar of its first pixel
 *   noise rows [B0, B0 + 64), B0 = ((H / 2 - 32) / 16) * 16, patterns 3 and 4: the words of the band in raster order are
 *         n0 = seed, n(j + 1) = 32 steps of the LFSR x^32 + x^22 + x^2 + x + 1 (Fibonacci, shift left, feedback
 *         s31 ^ s21 ^ s1 ^ s0 into bit 0); word n = {Cr, Y1, Cb, Y0}; seed = (0xACE10000 ^ (k * 0x9E3779B9)) | 1
 *   box   64 x 64 at (bx, by), patterns 2 and 4: bx = tri(192 + speed * k, W - 64), by = tri(96 + floor(speed / 2) * k,
 *         H - 64), tri(t, R) = u <= R ? u : 2R - u with u = t mod 2R; luma of local (cx, cy) =
 *         ((cx >> 3) ^ (cy >> 3)) & 1 ? 192 : 64, plus (cx + 5 * cy) >> 4; chroma Cb 90, Cr 190; the pair takes the chroma of
 *         the layer of its first pixel, each pixel its own luma
 * Speed is -32..+32 pixels per frame.
 *
 * Output: "MODEL <mode> width=<W> height=<H> bytes=<n> crc32=0x<hex>" per mode (static bars), where crc32 is the standard
 * CRC-32 (IEEE 802.3 reflected, initial value and final XOR 0xFFFFFFFF, zlib crc32) of the whole frame.
 *   csi2_bars_model                     print both MODEL lines
 *   csi2_bars_model --dump <file> <720p30|1080p30>   write the static-bars frame bytes to a file
 *   csi2_bars_model --frame <mode> <pattern> <speed> <k>            print "FRAME ..." with the CRC-32 of that frame
 *   csi2_bars_model --dump-frame <file> <mode> <pattern> <speed> <k> write that frame's bytes
 *   csi2_bars_model --crc-mem <file>    write the bench table (testbench/pattern_crc.mem, see CRC_COMBOS)
 *   csi2_bars_model --selftest          check the CRC engine: crc32("123456789") = 0xCBF43926
 * Exit code 0 on success, 1 on a bad argument, a failed self test or a file error.
 *
 * Build (host gcc from Resolve-RtlnetHostCc in scripts/rtlnet_tools.ps1):
 *   gcc -std=c11 -Wall -Wextra -Werror -pedantic -O2 csi2_bars_model.c -o csi2_bars_model
 *
 * Revision: 11-10-2026
 *   11-10-2026: moving patterns (--frame, --dump-frame, --crc-mem).
 *   11-09-2026: initial version.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BARS            8u
#define BYTES_PER_PIXEL 2u
#define CRC_POLY        0xEDB88320u
#define CRC_INIT        0xFFFFFFFFu
#define CRC_CHECK_VALUE 0xCBF43926u   /* crc32("123456789") */

#define PAT_COUNT       5u            /* patterns 0..4 */
#define SPEED_MAX       32
#define BOX_SIZE        64u
#define BAND_ROWS       64u
#define BOX_X0_DEFAULT  192u          /* box phase at k = 0 */
#define BOX_Y0_DEFAULT  96u
#define BOX_CB          90u
#define BOX_CR          190u
#define SEED_BASE       0xACE10000u
#define SEED_STEP       0x9E3779B9u

typedef struct {
    const char *name;
    uint32_t    width;
    uint32_t    height;
} mode_t_;

static const mode_t_ g_modes[] = { { "720p30", 1280u, 720u }, { "1080p30", 1920u, 1080u } };
#define MODE_COUNT (sizeof(g_modes) / sizeof(g_modes[0]))

/* Reduced geometries of the pattern-module bench (tb_rtlnet_csi2_rx_pattern): bar width 40 and 56 pixels. */
static const mode_t_ g_small[] = { { "320x96", 320u, 96u }, { "448x128", 448u, 128u } };
#define SMALL_BOX_X0 48u
#define SMALL_BOX_Y0 8u

/* Frame combinations of the benches: (pattern, speed). Speed matters for patterns 1, 2 and 4 only. */
typedef struct {
    uint32_t pattern;
    int32_t  speed;
} combo_t;
static const combo_t g_full_combos[] = {
    { 0u, 4 }, { 1u, 4 }, { 1u, -7 }, { 1u, 24 }, { 2u, 4 }, { 2u, -7 }, { 2u, 24 }, { 3u, 4 }, { 4u, 4 }, { 4u, -7 }, { 4u, 24 }
};
static const combo_t g_small_combos[] = {
    { 0u, 4 },
    { 1u, 4 }, { 1u, -7 }, { 1u, 24 }, { 1u, 32 }, { 1u, -32 },
    { 2u, 4 }, { 2u, -7 }, { 2u, 24 }, { 2u, 32 }, { 2u, -32 },
    { 3u, 4 },
    { 4u, 4 }, { 4u, -7 }, { 4u, 24 }, { 4u, 32 }, { 4u, -32 }
};
#define FULL_COMBOS  (sizeof(g_full_combos) / sizeof(g_full_combos[0]))
#define SMALL_COMBOS (sizeof(g_small_combos) / sizeof(g_small_combos[0]))
#define FULL_FRAMES  4u     /* consecutive frames k = 0..3 per combination in the integration bench */
#define SMALL_FRAMES 24u    /* k = 0..23 per combination in the pattern-module bench */

static mode_t_  g_custom;
static uint32_t g_box_x0 = BOX_X0_DEFAULT;
static uint32_t g_box_y0 = BOX_Y0_DEFAULT;
static uint32_t g_crc_tbl[256];

/* Y, Cb, Cr of white 75 %, yellow, cyan, green, magenta, red, blue, black (gige.md section 5.4). */
static const uint8_t g_bar[BARS][3] = {
    { 180u, 128u, 128u }, { 168u, 44u, 136u }, { 145u, 147u, 44u }, { 133u, 63u, 52u },
    { 63u, 193u, 204u }, { 51u, 109u, 212u }, { 28u, 212u, 120u }, { 16u, 128u, 128u }
};

/* crc32_init -- table of the reflected CRC-32. */
static void crc32_init(void)
{
    for (uint32_t n = 0; n < 256u; n++) {
        uint32_t c = n;
        for (unsigned b = 0; b < 8u; b++) {
            c = ((c & 1u) != 0u) ? ((c >> 1) ^ CRC_POLY) : (c >> 1);
        }
        g_crc_tbl[n] = c;
    }
}

/* crc32_update -- reflected CRC-32 register update over a byte buffer. */
static uint32_t crc32_update(uint32_t crc, const uint8_t *buf, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        crc = g_crc_tbl[(crc ^ buf[i]) & 0xFFu] ^ (crc >> 8);
    }
    return crc;
}

/* lfsr_step32 -- 32 shifts of the LFSR x^32 + x^22 + x^2 + x + 1 (Fibonacci, shift left, feedback into bit 0). */
static uint32_t lfsr_step32(uint32_t s)
{
    for (unsigned i = 0; i < 32u; i++) {
        uint32_t fb = ((s >> 31) ^ (s >> 21) ^ (s >> 1) ^ s) & 1u;
        s = (s << 1) | fb;
    }
    return s;
}

/* tri -- triangle wave of t between 0 and r (bounce at both ends), period 2 r. */
static int64_t tri(int64_t t, int64_t r)
{
    int64_t m = 2 * r;
    int64_t u = ((t % m) + m) % m;
    return (u <= r) ? u : (m - u);
}

/* half_floor -- floor(v / 2) for a signed v. */
static int32_t half_floor(int32_t v)
{
    return (v - (v & 1)) / 2;
}

/* box_luma -- luma of the box texture at local (cx, cy): 8x8 checkerboard of 64 / 192 plus a ramp along the diagonal (cx + 5 cy) >> 4. */
static uint8_t box_luma(uint32_t cx, uint32_t cy)
{
    uint32_t chk = ((cx >> 3) ^ (cy >> 3)) & 1u;
    return (uint8_t)((chk != 0u ? 192u : 64u) + ((cx + 5u * cy) >> 4));
}

/* render_frame -- the frame (mode m, pattern, speed, k) in memory order Y0 Cb Y1 Cr, packed lines. */
static void render_frame(const mode_t_ *m, uint32_t pattern, int32_t speed, uint32_t k, uint8_t *buf)
{
    int      scroll = (pattern == 1u || pattern == 4u);
    int      box    = (pattern == 2u || pattern == 4u);
    int      band   = (pattern == 3u || pattern == 4u);
    uint32_t w = m->width;
    uint32_t h = m->height;
    uint32_t bw = w / BARS;
    uint32_t off = 0;
    uint32_t band0 = ((h / 2u - 32u) / 16u) * 16u;
    uint32_t bx = 0;
    uint32_t by = 0;
    uint32_t noise = (SEED_BASE ^ (k * SEED_STEP)) | 1u;

    if (scroll) {
        int64_t o = ((int64_t)speed * (int64_t)k) % (int64_t)w;
        off = (uint32_t)((o + (int64_t)w) % (int64_t)w);
    }
    if (box) {
        bx = (uint32_t)tri((int64_t)g_box_x0 + (int64_t)speed * (int64_t)k, (int64_t)w - (int64_t)BOX_SIZE);
        by = (uint32_t)tri((int64_t)g_box_y0 + (int64_t)half_floor(speed) * (int64_t)k, (int64_t)h - (int64_t)BOX_SIZE);
    }
    for (uint32_t y = 0; y < h; y++) {
        uint8_t *row = buf + (size_t)y * w * BYTES_PER_PIXEL;
        int in_band = band && (y >= band0) && (y < band0 + BAND_ROWS);
        int in_rows = box && (y >= by) && (y < by + BOX_SIZE);
        for (uint32_t x = 0; x < w; x += 2u) {
            uint32_t s0 = (x + w - off) % w;
            uint32_t s1 = (x + 1u + w - off) % w;
            uint8_t  y0 = g_bar[s0 / bw][0];
            uint8_t  y1 = g_bar[s1 / bw][0];
            uint8_t  cb = g_bar[s0 / bw][1];
            uint8_t  cr = g_bar[s0 / bw][2];
            if (in_band) {
                y0 = (uint8_t)(noise & 0xFFu);
                cb = (uint8_t)((noise >> 8) & 0xFFu);
                y1 = (uint8_t)((noise >> 16) & 0xFFu);
                cr = (uint8_t)(noise >> 24);
                noise = lfsr_step32(noise);
            }
            if (in_rows) {
                int in0 = (x >= bx) && (x < bx + BOX_SIZE);
                int in1 = (x + 1u >= bx) && (x + 1u < bx + BOX_SIZE);
                if (in0) {
                    y0 = box_luma(x - bx, y - by);
                    cb = (uint8_t)BOX_CB;
                    cr = (uint8_t)BOX_CR;
                }
                if (in1) {
                    y1 = box_luma(x + 1u - bx, y - by);
                }
            }
            row[x * BYTES_PER_PIXEL + 0u] = y0;
            row[x * BYTES_PER_PIXEL + 1u] = cb;
            row[x * BYTES_PER_PIXEL + 2u] = y1;
            row[x * BYTES_PER_PIXEL + 3u] = cr;
        }
    }
}

/* frame_crc -- CRC-32 of a whole frame. Returns 0 on success. */
static int frame_crc(const mode_t_ *m, uint32_t pattern, int32_t speed, uint32_t k, uint32_t *crc_out)
{
    uint8_t *buf = (uint8_t *)malloc((size_t)m->width * m->height * BYTES_PER_PIXEL);
    if (buf == NULL) {
        return 1;
    }
    render_frame(m, pattern, speed, k, buf);
    *crc_out = ~crc32_update(CRC_INIT, buf, (size_t)m->width * m->height * BYTES_PER_PIXEL);
    free(buf);
    return 0;
}

/* parse_mode -- a mode name (720p30, 1080p30) or a size "<W>x<H>" (W a multiple of 16); NULL when unknown. */
static const mode_t_ *parse_mode(const char *name)
{
    unsigned w;
    unsigned h;
    char     tail;
    for (size_t i = 0; i < MODE_COUNT; i++) {
        if (strcmp(name, g_modes[i].name) == 0) {
            return &g_modes[i];
        }
    }
    if (sscanf(name, "%ux%u%c", &w, &h, &tail) == 2 && w >= 128u && w <= 4096u && (w % 16u) == 0u && h >= 64u && h <= 4096u && (h % 2u) == 0u) {
        g_custom.name = name;
        g_custom.width = w;
        g_custom.height = h;
        return &g_custom;
    }
    return NULL;
}

/* parse_int -- decimal integer argument; returns 0 on success. */
static int parse_int(const char *s, long lo, long hi, long *out)
{
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s || *end != '\0' || v < lo || v > hi) {
        return 1;
    }
    *out = v;
    return 0;
}

/* parse_frame_args -- <mode> <pattern> <speed> <k>. Returns 0 on success. */
static int parse_frame_args(char **a, const mode_t_ **m, uint32_t *pattern, int32_t *speed, uint32_t *k)
{
    long p;
    long sp;
    long kk;
    *m = parse_mode(a[0]);
    if (*m == NULL || parse_int(a[1], 0, (long)PAT_COUNT - 1, &p) != 0 || parse_int(a[2], -SPEED_MAX, SPEED_MAX, &sp) != 0 ||
        parse_int(a[3], 0, 0x7FFFFFFF, &kk) != 0) {
        fprintf(stderr, "bad arguments: <720p30|1080p30|WxH> <pattern 0..4> <speed -32..32> <k>\n");
        return 1;
    }
    *pattern = (uint32_t)p;
    *speed = (int32_t)sp;
    *k = (uint32_t)kk;
    return 0;
}

/* write_mem -- the CRC table of one bench: for each mode, each combination, each k, one hex word and a comment. */
static int write_mem(const char *path, const mode_t_ *modes, size_t nmodes, const combo_t *combos, size_t ncombos, uint32_t frames,
                     uint32_t x0, uint32_t y0)
{
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        fprintf(stderr, "cannot write \"%s\"\n", path);
        return 1;
    }
    g_box_x0 = x0;
    g_box_y0 = y0;
    (void)fprintf(f, "// generated by csi2_bars_model.c: one CRC-32 per line, order mode, combination, k (box phase %u, %u)\n", (unsigned)x0,
                  (unsigned)y0);
    for (size_t mi = 0; mi < nmodes; mi++) {
        for (size_t ci = 0; ci < ncombos; ci++) {
            for (uint32_t k = 0; k < frames; k++) {
                uint32_t crc;
                if (frame_crc(&modes[mi], combos[ci].pattern, combos[ci].speed, k, &crc) != 0) {
                    (void)fclose(f);
                    return 1;
                }
                (void)fprintf(f, "%08X // %s pattern %u speed %d k %u\n", (unsigned)crc, modes[mi].name, (unsigned)combos[ci].pattern,
                              (int)combos[ci].speed, (unsigned)k);
            }
        }
    }
    g_box_x0 = BOX_X0_DEFAULT;
    g_box_y0 = BOX_Y0_DEFAULT;
    return (fclose(f) == 0) ? 0 : 1;
}

/* dump_frame -- write one frame's bytes to a file. */
static int dump_frame(const char *path, const mode_t_ *m, uint32_t pattern, int32_t speed, uint32_t k)
{
    size_t n = (size_t)m->width * m->height * BYTES_PER_PIXEL;
    uint8_t *buf = (uint8_t *)malloc(n);
    FILE *f = fopen(path, "wb");
    int rc = 0;
    if (buf == NULL || f == NULL) {
        fprintf(stderr, "cannot write \"%s\"\n", path);
        rc = 1;
    } else {
        render_frame(m, pattern, speed, k, buf);
        if (fwrite(buf, 1u, n, f) != n) {
            rc = 1;
        }
    }
    if (f != NULL && fclose(f) != 0) {
        rc = 1;
    }
    free(buf);
    return rc;
}

/* selftest -- the CRC engine and the static-bars frame (every line of pattern 0 equals line 0, first bar edge in place). */
static int selftest(void)
{
    static const uint8_t check[] = { '1', '2', '3', '4', '5', '6', '7', '8', '9' };
    uint32_t crc = ~crc32_update(CRC_INIT, check, sizeof(check));
    int ok = (crc == CRC_CHECK_VALUE);
    printf("SELFTEST crc32(\"123456789\")=0x%08X %s\n", (unsigned)crc, ok ? "PASS" : "FAIL");
    for (size_t i = 0; i < MODE_COUNT && ok; i++) {
        size_t line = (size_t)g_modes[i].width * BYTES_PER_PIXEL;
        uint8_t *buf = (uint8_t *)malloc(line * g_modes[i].height);
        if (buf == NULL) {
            return 1;
        }
        render_frame(&g_modes[i], 0u, 4, 7u, buf);
        for (uint32_t y = 1; y < g_modes[i].height && ok; y++) {
            ok = (memcmp(buf, buf + (size_t)y * line, line) == 0);
        }
        ok = ok && (buf[0] == g_bar[0][0]) && (buf[(g_modes[i].width / BARS) * BYTES_PER_PIXEL] == g_bar[1][0]);
        printf("SELFTEST static bars %s %s\n", g_modes[i].name, ok ? "PASS" : "FAIL");
        free(buf);
    }
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    const mode_t_ *m;
    uint32_t pattern;
    int32_t speed;
    uint32_t k;

    crc32_init();
    if (argc >= 4 && strcmp(argv[1], "--box0") == 0) {
        long x0;
        long y0;
        if (parse_int(argv[2], 0, 4096, &x0) != 0 || parse_int(argv[3], 0, 4096, &y0) != 0) {
            fprintf(stderr, "bad --box0 values\n");
            return 1;
        }
        g_box_x0 = (uint32_t)x0;
        g_box_y0 = (uint32_t)y0;
        argc -= 3;
        argv += 3;
    }
    if (argc == 2 && strcmp(argv[1], "--selftest") == 0) {
        return selftest();
    }
    if (argc == 3 && strcmp(argv[1], "--crc-mem") == 0) {
        return write_mem(argv[2], g_modes, MODE_COUNT, g_full_combos, FULL_COMBOS, FULL_FRAMES, BOX_X0_DEFAULT, BOX_Y0_DEFAULT);
    }
    if (argc == 3 && strcmp(argv[1], "--crc-mem-small") == 0) {
        return write_mem(argv[2], g_small, sizeof(g_small) / sizeof(g_small[0]), g_small_combos, SMALL_COMBOS, SMALL_FRAMES, SMALL_BOX_X0,
                         SMALL_BOX_Y0);
    }
    if (argc == 6 && strcmp(argv[1], "--frame") == 0) {
        uint32_t crc;
        if (parse_frame_args(&argv[2], &m, &pattern, &speed, &k) != 0 || frame_crc(m, pattern, speed, k, &crc) != 0) {
            return 1;
        }
        printf("FRAME %s pattern=%u speed=%d k=%u width=%u height=%u bytes=%u crc32=0x%08X\n", m->name, (unsigned)pattern, (int)speed,
               (unsigned)k, (unsigned)m->width, (unsigned)m->height, (unsigned)(m->width * m->height * BYTES_PER_PIXEL), (unsigned)crc);
        return 0;
    }
    if (argc == 7 && strcmp(argv[1], "--dump-frame") == 0) {
        if (parse_frame_args(&argv[3], &m, &pattern, &speed, &k) != 0) {
            return 1;
        }
        return dump_frame(argv[2], m, pattern, speed, k);
    }
    if (argc == 4 && strcmp(argv[1], "--dump") == 0) {
        m = parse_mode(argv[3]);
        if (m == NULL) {
            fprintf(stderr, "unknown mode \"%s\" (720p30 or 1080p30)\n", argv[3]);
            return 1;
        }
        return dump_frame(argv[2], m, 0u, 0, 0u);
    }
    if (argc != 1) {
        fprintf(stderr, "usage: csi2_bars_model [--box0 <x0> <y0>] [--selftest | --dump <file> <mode> | --frame <mode> <pattern> <speed> <k> |\n"
                        "       --dump-frame <file> <mode> <pattern> <speed> <k> | --crc-mem <file> | --crc-mem-small <file>]\n");
        return 1;
    }
    for (size_t i = 0; i < MODE_COUNT; i++) {
        uint32_t crc;
        if (frame_crc(&g_modes[i], 0u, 0, 0u, &crc) != 0) {
            return 1;
        }
        printf("MODEL %s width=%u height=%u bytes=%u crc32=0x%08X\n", g_modes[i].name, (unsigned)g_modes[i].width,
               (unsigned)g_modes[i].height, (unsigned)(g_modes[i].width * g_modes[i].height * BYTES_PER_PIXEL), (unsigned)crc);
    }
    return 0;
}
