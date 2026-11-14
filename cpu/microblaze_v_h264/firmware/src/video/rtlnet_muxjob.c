/*
 * rtlnet_muxjob.c -- resumable send of one queued picture through the transport stream multiplexer
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_muxjob.h.
 *
 * Revision: 11-11-2026
 */
#include "rtlnet_muxjob.h"

#define PH_BEGIN  0u
#define PH_FEED   1u
#define PH_END    2u
#define PH_DONE   3u

void muxjob_start(muxjob_t *j, const picq_desc_t *d, muxjob_map_fn map, void *ctx, uint32_t share)
{
    j->d = d;
    j->map = map;
    j->ctx = ctx;
    j->share = share;
    j->phase = PH_BEGIN;
    j->eng = 0u;
    j->off = 0u;
    j->rem = 0u;
}

/* feed_set -- point the job at engine e's bytes (engine 0 skips the access unit delimiter, which the begin step sent). */
static void feed_set(muxjob_t *j, uint32_t e)
{
    const picq_desc_t *d = j->d;
    j->eng = e;
    if (e == 0u) {
        j->off = (d->off[0] + PICQ_AUD_BYTES) % j->share;
        j->rem = d->len[0] - PICQ_AUD_BYTES;
    } else {
        j->off = d->off[e];
        j->rem = d->len[e];
    }
}

int muxjob_step(muxjob_t *j, tsmux_t *m, uint32_t budget)
{
    const picq_desc_t *d = j->d;
    if (budget == 0u) {
        budget = 1u;
    }
    if (j->phase == PH_BEGIN) {
        /* The random access indicator marks IDR pictures only (an IDR picture carries its SPS and PPS); the PCR stays on every access
         * unit (13818-1: at most 100 ms apart). */
        uint32_t used = PICQ_AUD_BYTES + d->sps_len;
        tsmux_au_begin(m, d->pts, d->pts - MUXJOB_PCR_LEAD, d->sps_len != 0u);
        tsmux_au_data(m, d->aud, PICQ_AUD_BYTES);
        if (d->sps_len != 0u) {
            tsmux_au_data(m, d->sps_pps, d->sps_len);
        }
        feed_set(j, 0u);
        j->phase = PH_FEED;
        budget = (used >= budget) ? 0u : (budget - used);
        if (budget == 0u) {
            return 0;
        }
    }
    while (j->phase == PH_FEED) {
        uint32_t c;
        while (j->rem == 0u && j->eng + 1u < d->engines) {
            feed_set(j, j->eng + 1u);
        }
        if (j->rem == 0u) {
            j->phase = PH_END;
            break;
        }
        if (budget == 0u) {
            return 0;
        }
        c = j->rem;
        if (c > MUXJOB_PIECE) {
            c = MUXJOB_PIECE;
        }
        if (c > budget) {
            c = budget;
        }
        if (j->off + c > j->share) {
            c = j->share - j->off;
        }
        tsmux_au_data(m, j->map(j->ctx, j->eng, j->off, c), c);
        j->off = (j->off + c) % j->share;
        j->rem -= c;
        budget -= c;
    }
    if (j->phase == PH_END) {
        tsmux_au_end(m);
        j->phase = PH_DONE;
    }
    return (j->phase == PH_DONE) ? 1 : 0;
}
