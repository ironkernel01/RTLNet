/*
 * tsmux_host_test.c -- host test of the MPEG-TS multiplexer (src/video/rtlnet_tsmux.c)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: builds access units of many sizes through tsmux_t, collects the datagrams, and parses them with an independent
 * checker: 188-byte packets, seven per datagram (the last datagram of an access unit shorter), sync bytes, PIDs, continuity
 * counters per PID, PAT and PMT contents and their CRC-32 (own bitwise implementation, and the check value 0x0376E6E7 of
 * "123456789"), PES header, PTS and DTS, PCR, random-access flag, stuffing, and the reassembled elementary stream equal to the
 * input. Run with --neg: one continuity counter is damaged after the mux, and the test passes only when the checker
 * reports it (negative control). Prints one line "TSMUX_TEST: PASS" or "TSMUX_TEST: FAIL ..." and exits 0 on pass.
 *
 * Revision: 11-09-2026
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rtlnet_tsmux.h"

#define MAX_DGRAMS 4096u
#define MAX_ES     (256u * 1024u)

static uint8_t  g_dg[MAX_DGRAMS][TSMUX_DGRAM_BYTES];
static uint32_t g_dg_len[MAX_DGRAMS];
static uint32_t g_ndg;
static int      g_fail;

static void fail(const char *what, uint32_t a, uint32_t b)
{
    if (g_fail < 12) {
        printf("  check failed: %s (%u, %u)\n", what, (unsigned)a, (unsigned)b);
    }
    g_fail++;
}

static int sink(void *ctx, const uint8_t *d, uint32_t len)
{
    (void)ctx;
    if (g_ndg >= MAX_DGRAMS) {
        return -1;
    }
    memcpy(g_dg[g_ndg], d, len);
    g_dg_len[g_ndg++] = len;
    return 0;
}

/* Independent bitwise CRC-32/MPEG-2. */
static uint32_t ref_crc(const uint8_t *p, size_t n)
{
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        for (int b = 7; b >= 0; b--) {
            uint32_t bit = ((c >> 31) ^ (uint32_t)((p[i] >> b) & 1u)) & 1u;
            c <<= 1;
            if (bit) {
                c ^= 0x04C11DB7u;
            }
        }
    }
    return c;
}

static uint64_t get_ts(const uint8_t *p)
{
    return ((uint64_t)((p[0] >> 1) & 7u) << 30) | ((uint64_t)p[1] << 22) | ((uint64_t)(p[2] >> 1) << 15) |
           ((uint64_t)p[3] << 7) | (uint64_t)(p[4] >> 1);
}

typedef struct {
    uint32_t aus;
    uint32_t es_len;
    uint8_t  es[MAX_ES];
    int      cc[8192];
    int      cc_seen[8192];
} chk_t;

/* Parse everything in g_dg and compare each access unit's elementary stream with exp[i] (length explen[i]). */
static void check_stream(const uint8_t *const *exp, const uint32_t *explen, const uint64_t *pts, const uint64_t *pcr,
                         const int *ra, uint32_t naus)
{
    static chk_t c;
    int in_au = 0;
    uint32_t au = 0;
    uint32_t pkts_in_dg;
    memset(&c, 0, sizeof(c));
    for (uint32_t d = 0; d < g_ndg; d++) {
        if (g_dg_len[d] % TSMUX_PKT_BYTES != 0u || g_dg_len[d] == 0u || g_dg_len[d] > TSMUX_DGRAM_BYTES) {
            fail("datagram length", d, g_dg_len[d]);
            continue;
        }
        pkts_in_dg = g_dg_len[d] / TSMUX_PKT_BYTES;
        for (uint32_t k = 0; k < pkts_in_dg; k++) {
            const uint8_t *p = &g_dg[d][k * TSMUX_PKT_BYTES];
            unsigned pid = (unsigned)(((p[1] & 0x1Fu) << 8) | p[2]);
            unsigned afc = (p[3] >> 4) & 3u;
            unsigned cc = p[3] & 15u;
            uint32_t off = 4;
            if (p[0] != 0x47u) {
                fail("sync byte", d, k);
                continue;
            }
            if ((p[1] & 0x80u) != 0u) {
                fail("transport_error_indicator", d, k);
            }
            if (c.cc_seen[pid] && (unsigned)((c.cc[pid] + 1) & 15) != cc) {
                fail("continuity counter", pid, cc);
            }
            c.cc_seen[pid] = 1;
            c.cc[pid] = (int)cc;
            if (pid == TSMUX_PID_PAT || pid == TSMUX_PID_PMT) {
                const uint8_t *s = &p[5];
                uint32_t len = (uint32_t)(((s[1] & 0x0Fu) << 8) | s[2]) + 3u;
                uint32_t crc;
                if (!(p[1] & 0x40u) || afc != 1u || p[4] != 0u) {
                    fail("PSI header", pid, 0);
                }
                crc = ((uint32_t)s[len - 4] << 24) | ((uint32_t)s[len - 3] << 16) | ((uint32_t)s[len - 2] << 8) | s[len - 1];
                if (ref_crc(s, len - 4u) != crc) {
                    fail("PSI CRC-32", pid, crc);
                }
                if (ref_crc(s, len) != 0u) {
                    fail("PSI CRC residue", pid, 0);
                }
                if (pid == TSMUX_PID_PAT) {
                    if (s[0] != 0u || len != 16u || (((s[10] & 0x1Fu) << 8) | s[11]) != TSMUX_PID_PMT || ((s[8] << 8) | s[9]) != 1) {
                        fail("PAT content", s[0], len);
                    }
                    if (in_au) {
                        fail("PAT inside an access unit", d, k);
                    }
                    in_au = 0;
                } else {
                    if (s[0] != 2u || len != 21u || (((s[8] & 0x1Fu) << 8) | s[9]) != TSMUX_PID_VIDEO || s[12] != 0x1Bu ||
                        (((s[13] & 0x1Fu) << 8) | s[14]) != TSMUX_PID_VIDEO) {
                        fail("PMT content", s[0], len);
                    }
                }
                continue;
            }
            if (pid != TSMUX_PID_VIDEO) {
                fail("unexpected PID", pid, 0);
                continue;
            }
            if ((p[1] & 0x40u) != 0u) {   /* PUSI: a new access unit, the previous one must be complete */
                if (in_au) {
                    fail("PUSI inside an access unit", d, k);
                }
                if (au >= naus) {
                    fail("more access units than expected", au, naus);
                    return;
                }
                in_au = 1;
                c.es_len = 0;
                if (afc != 3u || p[4] < 7u || (p[5] & 0x10u) == 0u) {
                    fail("first packet has no PCR", afc, p[4]);
                } else {
                    uint64_t base = ((uint64_t)p[6] << 25) | ((uint64_t)p[7] << 17) | ((uint64_t)p[8] << 9) |
                                    ((uint64_t)p[9] << 1) | (uint64_t)(p[10] >> 7);
                    if (base != pcr[au] || p[11] != 0u || (p[10] & 0x7Eu) != 0x7Eu) {
                        fail("PCR value", (uint32_t)base, (uint32_t)pcr[au]);
                    }
                    if (((p[5] & 0x40u) != 0u) != (ra[au] != 0)) {
                        fail("random_access_indicator", p[5], (uint32_t)ra[au]);
                    }
                }
                off = 4u + 1u + p[4];
                if (p[off] != 0u || p[off + 1] != 0u || p[off + 2] != 1u || p[off + 3] != 0xE0u || p[off + 4] != 0u ||
                    p[off + 5] != 0u || p[off + 6] != 0x84u || p[off + 7] != 0xC0u || p[off + 8] != 10u) {
                    fail("PES header", off, 0);
                }
                if ((p[off + 9] >> 4) != 3u || (p[off + 14] >> 4) != 1u || get_ts(&p[off + 9]) != pts[au] ||
                    get_ts(&p[off + 14]) != pts[au]) {
                    fail("PTS/DTS", (uint32_t)get_ts(&p[off + 9]), (uint32_t)pts[au]);
                }
                if ((p[off + 9] & 1u) == 0u || (p[off + 11] & 1u) == 0u || (p[off + 13] & 1u) == 0u) {
                    fail("PTS marker bits", 0, 0);
                }
                off += TSMUX_PES_HDR_BYTES;
            } else {
                if (!in_au) {
                    fail("video packet outside an access unit", d, k);
                    continue;
                }
                if (afc == 3u) {
                    off = 4u + 1u + p[4];
                    if (p[4] >= 1u && p[5] != 0u) {
                        fail("stuffing flags", p[5], 0);
                    }
                } else if (afc != 1u) {
                    fail("adaptation field control", afc, 0);
                    continue;
                }
            }
            if (afc == 3u && (p[1] & 0x40u) == 0u) {
                for (uint32_t i = 5u + (p[4] ? 1u : 0u); i < off && p[4] > 1u; i++) {
                    if (p[i] != 0xFFu) {
                        fail("stuffing byte", i, p[i]);
                        break;
                    }
                }
            }
            if (off > TSMUX_PKT_BYTES) {
                fail("payload offset", off, 0);
                continue;
            }
            if (c.es_len + (TSMUX_PKT_BYTES - off) > MAX_ES) {
                fail("access unit too large for the checker", 0, 0);
                return;
            }
            memcpy(&c.es[c.es_len], &p[off], TSMUX_PKT_BYTES - off);
            c.es_len += TSMUX_PKT_BYTES - off;
            /* The access unit ends with the datagram that holds its last packet (shorter than 7 packets or the last). */
            if (k == pkts_in_dg - 1u && (g_dg_len[d] < TSMUX_DGRAM_BYTES || d + 1u == g_ndg ||
                                         ((g_dg[d + 1][1] & 0x1Fu) == 0u && g_dg[d + 1][2] == 0u))) {
                if (c.es_len != explen[au] || memcmp(c.es, exp[au], explen[au]) != 0) {
                    fail("elementary stream mismatch", c.es_len, explen[au]);
                }
                in_au = 0;
                au++;
            }
        }
    }
    if (au != naus) {
        fail("access unit count", au, naus);
    }
}

static uint32_t g_rng = 0x12345678u;
static uint32_t rnd(void)
{
    g_rng = g_rng * 1664525u + 1013904223u;
    return g_rng >> 8;
}

int main(int argc, char **argv)
{
    static const uint32_t sizes[] = { 0, 1, 2, 100, 164, 165, 166, 175, 176, 177, 183, 184, 185, 358, 359, 360, 361, 1316, 5000, 77777, 200000 };
    enum { NAUS = sizeof(sizes) / sizeof(sizes[0]) };
    static uint8_t es[NAUS][200001];
    const uint8_t *exp[NAUS];
    uint32_t explen[NAUS];
    uint64_t pts[NAUS];
    uint64_t pcr[NAUS];
    int ra[NAUS];
    tsmux_t m;
    int neg = (argc > 1 && strcmp(argv[1], "--neg") == 0);
    int fails_before_neg;
    static const uint8_t crc_in[9] = { '1', '2', '3', '4', '5', '6', '7', '8', '9' };

    if (tsmux_crc32_mpeg(crc_in, 9) != 0x0376E6E7u || ref_crc(crc_in, 9) != 0x0376E6E7u) {
        fail("CRC-32/MPEG-2 check value", tsmux_crc32_mpeg(crc_in, 9), 0x0376E6E7u);
    }
    tsmux_init(&m, sink, NULL);
    for (uint32_t i = 0; i < NAUS; i++) {
        for (uint32_t j = 0; j < sizes[i]; j++) {
            es[i][j] = (uint8_t)rnd();
        }
        exp[i] = es[i];
        explen[i] = sizes[i];
        pts[i] = 90000ull + (uint64_t)i * 3000ull + ((i == NAUS - 1u) ? 0x1F0000000ull : 0ull);
        pcr[i] = pts[i] - 9000ull;
        ra[i] = (int)(i & 1u);
        tsmux_au_begin(&m, pts[i], pcr[i], ra[i]);
        /* feed in uneven pieces, as the ring segments arrive */
        for (uint32_t pos = 0; pos < sizes[i];) {
            uint32_t n = 1u + rnd() % 400u;
            if (n > sizes[i] - pos) {
                n = sizes[i] - pos;
            }
            tsmux_au_data(&m, &es[i][pos], n);
            pos += n;
        }
        tsmux_au_end(&m);
    }
    if (m.sink_errors != 0u || m.access_units != NAUS || m.datagrams != g_ndg) {
        fail("mux counters", m.sink_errors, m.datagrams);
    }
    if (neg) {
        /* Damage the continuity counter of a video packet in the middle of the stream. */
        uint32_t d = g_ndg / 2u;
        g_dg[d][TSMUX_PKT_BYTES + 3] = (uint8_t)(g_dg[d][TSMUX_PKT_BYTES + 3] ^ 0x05u);
        fails_before_neg = g_fail;
        check_stream(exp, explen, pts, pcr, ra, NAUS);
        if (g_fail > fails_before_neg) {
            printf("TSMUX_TEST: PASS (negative control: the damaged continuity counter was reported, %d checks failed as required)\n",
                   g_fail - fails_before_neg);
            return 0;
        }
        printf("TSMUX_TEST: FAIL negative control: the damage was not detected\n");
        return 1;
    }
    check_stream(exp, explen, pts, pcr, ra, NAUS);
    if (g_fail != 0) {
        printf("TSMUX_TEST: FAIL %d checks\n", g_fail);
        return 1;
    }
    printf("TSMUX_TEST: PASS (%u access units, %u datagrams, %u packets)\n", (unsigned)NAUS, (unsigned)g_ndg, (unsigned)m.packets);
    return 0;
}
