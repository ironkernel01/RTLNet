/*
 * rtlnet_muxjob.h -- resumable send of one queued picture through the transport stream multiplexer
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: sends the access unit a descriptor (rtlnet_picq.h) describes, a bounded number of elementary stream bytes per call, so the main
 * loop (and the encoder start) runs between calls. A call takes everything from the descriptor and the ring: nothing from the live
 * encoder state. Steps of one picture: begin (PAT, PMT and PES header, the access unit delimiter, the SPS and PPS of an IDR picture),
 * the rest of engine 0's bytes, every other engine's bytes, end (pad, last datagram). The bytes come from the ring through a map
 * callback that returns a pointer to n bytes at an offset inside the engine's share (the firmware invalidates the cache lines there;
 * the host test returns a pointer into an array), never across the end of the share. The datagrams are the same whatever the budget
 * is (the host test compares a one-call run with many-call runs byte for byte).
 *
 * Revision: 11-11-2026
 */
#ifndef RTLNET_MUXJOB_H
#define RTLNET_MUXJOB_H

#include <stdint.h>

#include "rtlnet_picq.h"
#include "rtlnet_tsmux.h"

#define MUXJOB_PIECE   1024u   /* most bytes handed to the multiplexer at once */
#define MUXJOB_BUDGET  5152u   /* default bytes per call: 28 packets of 184 payload bytes, four datagrams */
#define MUXJOB_PCR_LEAD 9000u  /* PTS minus PCR: 100 ms */

/* Pointer to n bytes of engine e's ring share at offset off (off + n within the share). */
typedef const uint8_t *(*muxjob_map_fn)(void *ctx, uint32_t engine, uint32_t off, uint32_t n);

typedef struct {
    const picq_desc_t *d;
    muxjob_map_fn      map;
    void              *ctx;
    uint32_t           share;    /* bytes of one engine's ring share */
    uint32_t           phase;
    uint32_t           eng;      /* engine being fed */
    uint32_t           off;      /* next ring offset of that engine */
    uint32_t           rem;      /* bytes of that engine still to send */
} muxjob_t;

/* Prepare the job for descriptor d (it must stay valid until the job is done). */
void muxjob_start(muxjob_t *j, const picq_desc_t *d, muxjob_map_fn map, void *ctx, uint32_t share);

/* Send up to budget elementary stream bytes of the picture (the begin step counts its AUD and SPS and PPS bytes). Returns 1 when the
 * whole access unit is sent (au_end done), 0 when more calls are needed. A budget of 0 is raised to 1. */
int muxjob_step(muxjob_t *j, tsmux_t *m, uint32_t budget);

#endif /* RTLNET_MUXJOB_H */
