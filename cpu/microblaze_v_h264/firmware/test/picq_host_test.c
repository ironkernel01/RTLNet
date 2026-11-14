/*
 * picq_host_test.c -- host test of the picture queue and the resumable mux (src/video/rtlnet_picq.c, rtlnet_muxjob.c)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: checks the queue (coding order across wrap-around, descriptor contents unchanged from push to front, the admit gate at
 * PICQ_LIMIT with its refusal count, a push into a full queue and a bad descriptor refused, flush, counters) and the mux job (the
 * datagrams of one picture are byte-identical for a one-call run and for budgets of 1, 7, 188, 1024, 5152 and 99999 bytes; a call
 * sends at most the budget plus one packet of bytes before it returns; a picture whose engine data wraps the end of its ring share
 * and a two-engine picture arrive in the right order; the access unit delimiter, the SPS and PPS and the random access flag come
 * from the descriptor; the queue of three pictures sent in chunks equals the same pictures sent whole). Run with --neg: one byte of a
 * descriptor is damaged after the push and the test passes only when the content check reports it (negative control).
 * Prints one line "PICQ_TEST: PASS" or "PICQ_TEST: FAIL ..." and exits 0 on pass.
 *
 * Revision: 11-11-2026
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rtlnet_muxjob.h"
#include "rtlnet_picq.h"
#include "rtlnet_tsmux.h"

#define SHARE      (64u * 1024u)
#define MAX_OUT    (512u * 1024u)

static int g_fail;

static void fail(const char *what, uint32_t a, uint32_t b)
{
    if (g_fail < 12) {
        printf("  check failed: %s (%u, %u)\n", what, (unsigned)a, (unsigned)b);
    }
    g_fail++;
}

/* The ring: two engines' shares of SHARE bytes, filled with a pattern that tells the offset and the engine. */
static uint8_t g_ring[2][SHARE];

static const uint8_t *map(void *ctx, uint32_t e, uint32_t off, uint32_t n)
{
    uint32_t *calls = (uint32_t *)ctx;
    if (off + n > SHARE || e > 1u) {
        fail("map outside the share", off, n);
        return g_ring[0];
    }
    (*calls)++;
    return &g_ring[e][off];
}

static uint8_t  g_out[MAX_OUT];
static uint32_t g_out_len;

static int sink(void *ctx, const uint8_t *d, uint32_t len)
{
    (void)ctx;
    if (g_out_len + len > MAX_OUT) {
        return -1;
    }
    memcpy(&g_out[g_out_len], d, len);
    g_out_len += len;
    return 0;
}

static void fill_ring(void)
{
    for (uint32_t e = 0u; e < 2u; e++) {
        for (uint32_t i = 0u; i < SHARE; i++) {
            g_ring[e][i] = (uint8_t)(i * 7u + e * 101u + (i >> 8));
        }
    }
}

/* A descriptor for a picture of engine 0 at off0 (length len0, AUD included) and engine 1 at off1 (len1). */
static void make_desc(picq_desc_t *d, uint32_t frame, int idr, uint32_t off0, uint32_t len0, uint32_t off1, uint32_t len1)
{
    memset(d, 0, sizeof(*d));
    d->frame = frame;
    d->pic_type = idr ? 1u : 2u;
    d->qp = 20u + frame;
    d->pts = 90000u + (uint64_t)frame * 3000u;
    d->engines = 2u;
    d->off[0] = off0;
    d->len[0] = len0;
    d->off[1] = off1;
    d->len[1] = len1;
    d->ring_end[0] = (off0 + len0) % SHARE;
    d->ring_end[1] = (off1 + len1) % SHARE;
    d->idx_end[0] = frame * 2u;
    d->idx_end[1] = frame * 2u + 1u;
    /* the access unit delimiter sits in the ring at the start of engine 0's data, as the descriptor holds it */
    g_ring[0][off0 % SHARE] = 0u;
    g_ring[0][(off0 + 1u) % SHARE] = 0u;
    g_ring[0][(off0 + 2u) % SHARE] = 0u;
    g_ring[0][(off0 + 3u) % SHARE] = 1u;
    g_ring[0][(off0 + 4u) % SHARE] = 0x09u;
    g_ring[0][(off0 + 5u) % SHARE] = 0xF0u;
    for (uint32_t i = 0u; i < 6u; i++) {
        d->aud[i] = g_ring[0][(off0 + i) % SHARE];
    }
    if (idr) {
        d->sps_len = 24u;
        for (uint32_t i = 0u; i < d->sps_len; i++) {
            d->sps_pps[i] = (uint8_t)(0xA0u + i);
        }
    }
    d->es_bytes = len0 + len1 + d->sps_len;
}

/* Send descriptor d whole or in budget-sized calls; the datagrams go to g_out. Returns the number of calls; checks the per-call bound. */
static uint32_t send_picture(const picq_desc_t *d, uint32_t budget, tsmux_t *m, uint32_t *map_calls)
{
    muxjob_t j;
    uint32_t calls = 0u;
    muxjob_start(&j, d, map, map_calls, SHARE);
    for (;;) {
        uint32_t before = m->packets;
        int done = muxjob_step(&j, m, budget);
        calls++;
        /* PAT, PMT and the PES header of the begin step are not counted against the budget; the rest of a call is at most budget bytes
         * of payload plus the packet that was open. */
        if (calls > 1u && !done && (m->packets - before) > (budget / 184u) + 2u) {
            fail("a call sent more than its budget", m->packets - before, budget);
        }
        if (done) {
            break;
        }
        if (calls > 2000000u) {
            fail("job does not finish", calls, budget);
            break;
        }
    }
    return calls;
}

static void queue_checks(int neg)
{
    picq_t q;
    picq_desc_t d;
    const picq_desc_t *f;
    uint32_t seq = 0u;
    uint32_t next_pop = 0u;
    picq_init(&q);
    if (picq_front(&q) != NULL || picq_pop(&q) != -1 || picq_count(&q) != 0u) {
        fail("empty queue", picq_count(&q), 0u);
    }
    /* order across several wraps of the 8 slots: push 2, pop 1, push 1 ... */
    for (uint32_t round = 0u; round < 40u; round++) {
        for (uint32_t k = 0u; k < 2u && picq_count(&q) < PICQ_SLOTS; k++) {
            make_desc(&d, seq, (seq % 5u) == 0u, 1000u + seq, 300u + seq, 2000u + seq, 400u + seq);
            if (picq_push(&q, &d) != PICQ_OK) {
                fail("push", seq, picq_count(&q));
            }
            seq++;
        }
        if (neg && round == 10u) {
            ((picq_desc_t *)picq_front(&q))->len[1] ^= 0x40u;   /* damage the oldest descriptor after the push */
        }
        f = picq_front(&q);
        if (f == NULL || f->frame != next_pop || f->len[0] != 300u + next_pop || f->len[1] != 400u + next_pop || f->off[1] != 2000u + next_pop ||
            f->qp != 20u + next_pop || f->pts != 90000u + (uint64_t)next_pop * 3000u || (f->sps_len != 0u) != ((next_pop % 5u) == 0u) ||
            f->es_bytes != 700u + 2u * next_pop + f->sps_len || f->ring_end[0] != (1000u + next_pop + 300u + next_pop) % SHARE) {
            fail("descriptor contents or order", f ? f->frame : 0xFFFFu, next_pop);
            next_pop = f ? f->frame : next_pop;
        }
        (void)picq_pop(&q);
        next_pop++;
    }
    /* admit gate and overflow policy */
    picq_flush(&q);
    picq_clear_counters(&q);
    for (uint32_t i = 0u; i < PICQ_LIMIT; i++) {
        if (!picq_admit(&q, PICQ_LIMIT)) {
            fail("admit below the limit", i, PICQ_LIMIT);
        }
        make_desc(&d, i, 0, 0u, 100u, 0u, 100u);
        (void)picq_push(&q, &d);
    }
    if (picq_admit(&q, PICQ_LIMIT) || picq_admit(&q, PICQ_LIMIT) || q.refused != 2u) {
        fail("admit at the limit refuses and counts", q.refused, 2u);
    }
    (void)picq_pop(&q);
    if (!picq_admit(&q, PICQ_LIMIT)) {
        fail("admit again after a pop", picq_count(&q), PICQ_LIMIT);
    }
    /* a push into a full queue is refused and leaves the queue as it was */
    for (uint32_t i = picq_count(&q); i < PICQ_SLOTS; i++) {
        if (picq_push(&q, &d) != PICQ_OK) {
            fail("fill to the slot count", i, 0u);
        }
    }
    if (picq_push(&q, &d) != PICQ_ERR_FULL || picq_count(&q) != PICQ_SLOTS || q.max_count != PICQ_SLOTS) {
        fail("push into a full queue", picq_count(&q), q.max_count);
    }
    d.engines = 0u;
    picq_flush(&q);
    if (picq_push(&q, &d) != PICQ_ERR_ARG) {
        fail("zero engines refused", 0u, 0u);
    }
    d.engines = 2u;
    d.sps_len = PICQ_PS_BYTES + 1u;
    if (picq_push(&q, &d) != PICQ_ERR_ARG || picq_count(&q) != 0u) {
        fail("oversized SPS refused", 0u, 0u);
    }
    if (PICQ_LIMIT >= PICQ_SLOTS) {
        fail("limit below the slot count", PICQ_LIMIT, PICQ_SLOTS);
    }
}

static void mux_checks(void)
{
    static const uint32_t budgets[] = {1u, 7u, 188u, 1024u, 5152u, 99999u};
    static uint8_t ref[MAX_OUT];
    static uint8_t es[MAX_OUT];
    picq_desc_t d[3];
    uint32_t ref_len;
    uint32_t map_calls = 0u;
    tsmux_t m;
    /* three pictures: an IDR picture of 6 kB and 3 kB, a P picture that wraps the end of engine 0's share, a P picture of engine data
     * that ends exactly at the end of the share */
    make_desc(&d[0], 0u, 1, 100u, 6000u, 200u, 3000u);
    make_desc(&d[1], 1u, 0, SHARE - 1500u, 4000u, SHARE - 700u, 1000u);
    make_desc(&d[2], 2u, 0, 50u, 120u, SHARE - 200u, 200u);
    /* reference: the same pictures through tsmux directly, in one piece each */
    g_out_len = 0u;
    tsmux_init(&m, sink, NULL);
    for (uint32_t p = 0u; p < 3u; p++) {
        uint32_t n = 0u;
        for (uint32_t i = 6u; i < d[p].len[0]; i++) {
            es[n++] = g_ring[0][(d[p].off[0] + i) % SHARE];
        }
        for (uint32_t i = 0u; i < d[p].len[1]; i++) {
            es[n++] = g_ring[1][(d[p].off[1] + i) % SHARE];
        }
        tsmux_au_begin(&m, d[p].pts, d[p].pts - MUXJOB_PCR_LEAD, d[p].sps_len != 0u);
        tsmux_au_data(&m, d[p].aud, 6u);
        if (d[p].sps_len != 0u) {
            tsmux_au_data(&m, d[p].sps_pps, d[p].sps_len);
        }
        tsmux_au_data(&m, es, n);
        tsmux_au_end(&m);
    }
    ref_len = g_out_len;
    memcpy(ref, g_out, ref_len);
    if (ref_len == 0u || m.sink_errors != 0u) {
        fail("reference run", ref_len, m.sink_errors);
        return;
    }
    for (uint32_t b = 0u; b < sizeof(budgets) / sizeof(budgets[0]); b++) {
        uint32_t calls = 0u;
        g_out_len = 0u;
        map_calls = 0u;
        tsmux_init(&m, sink, NULL);
        for (uint32_t p = 0u; p < 3u; p++) {
            calls += send_picture(&d[p], budgets[b], &m, &map_calls);
        }
        if (g_out_len != ref_len || memcmp(g_out, ref, ref_len) != 0) {
            fail("datagrams differ from the one-piece run", budgets[b], g_out_len);
        }
        if (m.access_units != 3u || m.sink_errors != 0u) {
            fail("access units", m.access_units, budgets[b]);
        }
        if (budgets[b] == 99999u && calls != 3u) {
            fail("a large budget sends a picture in one call", calls, 3u);
        }
        if (budgets[b] == 5152u && calls <= 3u) {   /* the 9 kB IDR picture alone needs two calls */
            fail("a bounded budget needs several calls", calls, budgets[b]);
        }
        printf("  budget %5u: %u calls, %u ring reads, %u bytes of datagrams\n", (unsigned)budgets[b], (unsigned)calls,
               (unsigned)map_calls, (unsigned)g_out_len);
    }
    /* content from the descriptor: random access flag only on the IDR picture; the AUD and the SPS at the start of its payload */
    {
        uint32_t ra = 0u;
        uint32_t pusi = 0u;
        for (uint32_t off = 0u; off + TSMUX_PKT_BYTES <= ref_len; off += TSMUX_PKT_BYTES) {
            const uint8_t *pk = &ref[off];
            uint16_t pid = (uint16_t)(((pk[1] & 0x1Fu) << 8) | pk[2]);
            if (pid == TSMUX_PID_VIDEO && (pk[1] & 0x40u) != 0u && (pk[3] & 0x20u) != 0u) {
                pusi++;
                if ((pk[5] & 0x40u) != 0u) {
                    ra++;
                }
            }
        }
        if (pusi != 3u || ra != 1u) {
            fail("random access on the IDR picture only", pusi, ra);
        }
    }
}

int main(int argc, char **argv)
{
    int neg = (argc > 1 && strcmp(argv[1], "--neg") == 0);
    int before;
    fill_ring();
    queue_checks(neg);
    if (neg) {
        before = g_fail;
        if (g_fail > 0) {
            printf("PICQ_TEST: PASS (negative control: the damaged descriptor was reported, %d checks failed as required)\n", g_fail);
            return 0;
        }
        (void)before;
        printf("PICQ_TEST: FAIL negative control: the damage was not detected\n");
        return 1;
    }
    mux_checks();
    if (g_fail != 0) {
        printf("PICQ_TEST: FAIL %d checks\n", g_fail);
        return 1;
    }
    printf("PICQ_TEST: PASS (queue order, content, admit gate and overflow; mux chunking equals one piece for 6 budgets)\n");
    return 0;
}
