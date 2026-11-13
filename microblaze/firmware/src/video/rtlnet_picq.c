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

/* Compiler barrier: on the single MicroBlaze the handler and the main loop interleave on one instruction stream, so program order is enough
 * once the compiler does not move the descriptor store past the index store. */
#define PICQ_BARRIER() __asm__ __volatile__("" : : : "memory")

void picq_flush(picq_t *q)
{
    q->rd = q->wr;
}

uint32_t picq_count(const picq_t *q)
{
    return q->wr - q->rd;
}

int picq_admit(picq_t *q, uint32_t limit)
{
    if (picq_count(q) >= limit) {
        q->refused++;
        return 0;
    }
    return 1;
}

int picq_push(picq_t *q, const picq_desc_t *d)
{
    uint32_t slot;
    uint32_t count;
    if (d->engines < 1u || d->engines > PICQ_ENGINES || d->sps_len > PICQ_PS_BYTES) {
        return PICQ_ERR_ARG;
    }
    count = q->wr - q->rd;
    if (count >= PICQ_SLOTS) {
        return PICQ_ERR_FULL;
    }
    slot = q->wr % PICQ_SLOTS;
    q->d[slot] = *d;
    PICQ_BARRIER();      /* the descriptor is complete before the consumer can see the index move */
    q->wr++;
    q->pushed++;
    if ((count + 1u) > q->max_count) {
        q->max_count = count + 1u;
    }
    return PICQ_OK;
}

const picq_desc_t *picq_front(const picq_t *q)
{
    return (q->wr == q->rd) ? NULL : &q->d[q->rd % PICQ_SLOTS];
}

int picq_pop(picq_t *q)
{
    if (q->wr == q->rd) {
        return -1;
    }
    PICQ_BARRIER();      /* the consumer is done with the descriptor before the producer may reuse the slot */
    q->rd++;
    q->popped++;
    return 0;
}

void picq_clear_counters(picq_t *q)
{
    q->max_count = picq_count(q);
    q->pushed = 0u;
    q->popped = 0u;
    q->refused = 0u;
}
