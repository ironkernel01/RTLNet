/*
 * rtlnet_picq.c -- queue of coded pictures waiting for the transport stream multiplexer
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_picq.h.
 *
 * Revision: 11-11-2026
 */
#include "rtlnet_picq.h"

#include <stddef.h>   /* NULL */
#include <string.h>   /* memset */

void picq_init(picq_t *q)
{
    memset(q, 0, sizeof(*q));
}

void picq_flush(picq_t *q)
{
    q->head = 0u;
    q->count = 0u;
}

uint32_t picq_count(const picq_t *q)
{
    return q->count;
}

int picq_admit(picq_t *q, uint32_t limit)
{
    if (q->count >= limit) {
        q->refused++;
        return 0;
    }
    return 1;
}

int picq_push(picq_t *q, const picq_desc_t *d)
{
    uint32_t slot;
    if (d->engines < 1u || d->engines > PICQ_ENGINES || d->sps_len > PICQ_PS_BYTES) {
        return PICQ_ERR_ARG;
    }
    if (q->count >= PICQ_SLOTS) {
        return PICQ_ERR_FULL;
    }
    slot = (q->head + q->count) % PICQ_SLOTS;
    q->d[slot] = *d;
    q->count++;
    q->pushed++;
    if (q->count > q->max_count) {
        q->max_count = q->count;
    }
    return PICQ_OK;
}

const picq_desc_t *picq_front(const picq_t *q)
{
    return (q->count == 0u) ? NULL : &q->d[q->head];
}

int picq_pop(picq_t *q)
{
    if (q->count == 0u) {
        return -1;
    }
    q->head = (q->head + 1u) % PICQ_SLOTS;
    q->count--;
    q->popped++;
    return 0;
}

void picq_clear_counters(picq_t *q)
{
    q->max_count = q->count;
    q->pushed = 0u;
    q->popped = 0u;
    q->refused = 0u;
}
