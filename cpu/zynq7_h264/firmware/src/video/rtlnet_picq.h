/*
 * rtlnet_picq.h -- queue of coded pictures waiting for the transport stream multiplexer
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the firmware codes a picture, and on DONE writes what the multiplexer needs into a descriptor and pushes it here; the encoder
 * then starts the next picture while the multiplexer sends the oldest descriptor in chunks (rtlnet_muxjob.c). A descriptor holds
 * everything the multiplexer reads: frame number, picture type, QP, PTS, the access unit delimiter, the SPS and PPS of an IDR picture
 * as they were when the picture was coded, and for every engine the ring offset and length of the picture and the ring and index
 * positions that are free once it is sent. The queue keeps coding order: pictures leave in the order they were pushed.
 * Overflow policy: picq_admit is the gate in front of the encoder. At or above the limit it refuses, counts the refusal and the caller
 * skips the input frame (counted as a dropped picture with its own cause); a push into a full queue is an error that the limit makes
 * unreachable (PICQ_LIMIT is below PICQ_SLOTS). The module has no hardware access and no static state; the host test
 * cpu/microblaze_v_h264/firmware/test/picq_host_test.c runs it.
 * Concurrency (single producer, single consumer): the queue is safe between a producer that runs in an interrupt handler (picq_push, picq_admit)
 * and a consumer in the main loop (picq_front, picq_pop, picq_count) without masking interrupts: the write index wr changes only in picq_push and the
 * read index rd only in picq_pop, both are free-running counters, and the descriptor is complete before wr advances. The consumer's pop can only lower
 * the count the producer sees, so the producer's admit decision is at worst late, never wrong in the unsafe direction. picq_flush, picq_init and
 * picq_clear_counters touch both sides: call them with the producer quiescent (interrupts masked or the stream stopped).
 * Counter ownership: pushed and max_count by the producer, popped by the consumer, refused by the caller of picq_admit.
 *
 * Revision: 11-12-2026
 *   * 11-12-2026: single producer / single consumer indices (the interrupt-driven encoder pushes from its handler).
 */
#ifndef RTLNET_PICQ_H
#define RTLNET_PICQ_H

#include <stdint.h>   /* uint8_t, uint32_t, uint64_t */

#define PICQ_SLOTS        8u    /* descriptor storage */
#define PICQ_LIMIT        3u    /* pictures coded and not yet sent at which the next input frame is skipped (3 x 33.3 ms = the 100 ms PCR lead) */
#define PICQ_ENGINES      4u    /* most engines a descriptor describes (VENC_MAX_ENGINES) */
#define PICQ_PS_BYTES     64u   /* SPS and PPS bytes a descriptor carries (RTLNET_H264_SPS_PPS_MAX_BYTES) */
#define PICQ_AUD_BYTES    6u    /* start code, NAL header and payload of the access unit delimiter */

#define PICQ_OK           0
#define PICQ_ERR_FULL     (-1)  /* push into a full queue */
#define PICQ_ERR_ARG      (-2)  /* engine count outside 1..PICQ_ENGINES, SPS longer than PICQ_PS_BYTES */

typedef struct {
    uint32_t frame;                      /* frame number stamped by the capture path */
    uint32_t pic_type;                   /* RTLNET_H264_PIC_IDR or _P */
    uint32_t qp;                         /* QP written to the core for this picture */
    uint64_t pts;                        /* 90 kHz; the PCR is derived by the multiplexer */
    uint32_t engines;                    /* engines that coded the picture, 1..PICQ_ENGINES */
    uint32_t off[PICQ_ENGINES];          /* ring offset of the engine's slices, inside the engine's share */
    uint32_t len[PICQ_ENGINES];          /* bytes of the engine's slices (engine 0 includes the access unit delimiter) */
    uint32_t ring_end[PICQ_ENGINES];     /* ring read pointer once the picture is sent: (off + len) modulo the share */
    uint32_t idx_end[PICQ_ENGINES];      /* index read pointer once the picture is sent */
    uint32_t es_bytes;                   /* elementary stream bytes of the picture: all lengths plus the SPS and PPS of an IDR picture */
    uint32_t t_done;                     /* plat_ticks when the picture was queued */
    uint8_t  aud[PICQ_AUD_BYTES];
    uint32_t sps_len;                    /* 0 for a P picture */
    uint8_t  sps_pps[PICQ_PS_BYTES];
} picq_desc_t;

typedef struct {
    picq_desc_t d[PICQ_SLOTS];
    volatile uint32_t rd;                /* free-running read index (consumer): the oldest descriptor is d[rd % PICQ_SLOTS] */
    volatile uint32_t wr;                /* free-running write index (producer); descriptors queued = wr - rd */
    uint32_t    max_count;               /* highest count seen (producer) */
    uint32_t    pushed;                  /* producer */
    uint32_t    popped;                  /* consumer */
    uint32_t    refused;                 /* picq_admit refusals */
} picq_t;

/* Empty the queue and clear its counters. */
void picq_init(picq_t *q);

/* Empty the queue; the counters keep running. */
void picq_flush(picq_t *q);

/* Descriptors queued. */
uint32_t picq_count(const picq_t *q);

/* 1 when a new picture may be started: fewer than limit descriptors queued. Otherwise 0, and the refusal is counted. */
int picq_admit(picq_t *q, uint32_t limit);

/* Append a copy of *d. PICQ_OK, PICQ_ERR_FULL or PICQ_ERR_ARG. */
int picq_push(picq_t *q, const picq_desc_t *d);

/* The oldest descriptor (valid until the next pop), or NULL when empty. */
const picq_desc_t *picq_front(const picq_t *q);

/* Remove the oldest descriptor; 0, or -1 when empty. */
int picq_pop(picq_t *q);

/* Clear the counters except the queue contents (max_count restarts from the current count). */
void picq_clear_counters(picq_t *q);

#endif /* RTLNET_PICQ_H */
