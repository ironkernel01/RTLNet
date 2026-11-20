/*
 * rtlnet_ratectl.h -- H.264 rate control: one QP per picture from the size of the last pictures
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: pure C with no hardware access and no floating point (fixed point, no dynamic allocation), so the host unit test
 * (testbench/test_rtlnet_ratectl.c) drives it with a synthetic encoder model. rtlnet_venc.c owns one instance:
 *   begin of a picture   qp = ratectl_pick(rc, is_idr, gop)               the QP written to the core
 *   end of a picture     ratectl_picture_done(rc, is_idr, qp, bits, dt90) the coded size, the QP actually used, the time step
 *
 * Concurrency: no locking and no static state. rtlnet_venc.c calls ratectl_pick and ratectl_picture_done from the encoder side (the encoder
 * interrupt handler in interrupt mode) and the console commands (set_*, get_stats, history, clear_stats) inside a critical section.
 *
 * Modes: target 0 is constant QP (ratectl_pick returns the configured QP, today's behaviour); a target in kb/s is constant bit
 * rate with a virtual buffer (leaky bucket) of target x buffer_ms / 1000 bits. The controller never drops a picture: a buffer that
 * would overflow is counted (overflow, and overflow_below_max when the picture's QP was below the range maximum) and the fill
 * saturates at 100 %; a buffer that runs empty (static content at the minimum QP) is counted as underflow.
 *
 * Model (section 2 of ip/rtlnet_h264_enc/documentation/rtlnet_ratectl.md): the size of a picture of type t at QP q is 2^(K_t - q/6) bits;
 * K_t is tracked in the log domain (Q8) for the I and the P type separately. The QP of the next picture solves "the pictures of the
 * next H coded at one QP use the bit budget of H picture periods plus the distance of the buffer from its set point"; the result is
 * clamped to the QP range, limited to +-2 from the previous picture and rounded with error feedback so the average QP is exact.
 *
 * Measurement: a ring of one record per second of stream time (RATECTL_HISTORY_SECONDS records of 8 bytes: 28,800 bytes) and the
 * running statistics of ratectl_stats_t.
 *
 * Revision: 11-10-2026 (initial, Phase 2d)
 */
#ifndef RTLNET_RATECTL_H
#define RTLNET_RATECTL_H

#include <stdint.h>

#define RATECTL_QP_MIN_RT         12u     /* the real-time clamp of the encoder driver */
#define RATECTL_QP_MAX            51u
#define RATECTL_BUFFER_MS_DEFAULT 500u
#define RATECTL_BUFFER_MS_MIN     100u
#define RATECTL_BUFFER_MS_MAX     2000u
#define RATECTL_KBPS_MAX          100000u
#define RATECTL_QP_STEP_MAX       2u      /* largest QP change from one picture to the next */
#define RATECTL_START_QP_BACKOFF  3u      /* the first picture of a stream is coded at qp_max - 3 (within the range) */
#define RATECTL_FILL_SETPOINT_PCT 30u     /* buffer fill the controller steers to */
#define RATECTL_HISTORY_SECONDS   3600u
#define RATECTL_TICKS_PER_S       90000u  /* the 90 kHz stream time base of the PTS */

/* One second of stream time (8 bytes). */
typedef struct {
    uint32_t bits;        /* coded bits of the pictures finished in that second */
    uint16_t qp_q4;       /* mean QP x 16 */
    uint8_t  fill_pct;    /* buffer fill at the end of the second, 0..100 (0 in constant QP mode) */
    uint8_t  pics;        /* pictures finished in that second */
} ratectl_sec_t;

typedef struct {
    /* configuration */
    uint32_t target_kbps;       /* 0 = constant QP */
    uint32_t buffer_ms;
    uint32_t qp_min, qp_max;
    uint32_t cqp;               /* constant QP */
    uint32_t pixels;            /* coded pixels per picture */
    uint32_t period90;          /* nominal picture period in 90 kHz ticks */
    /* controller state */
    int      have_model;
    int32_t  k_i, k_p;          /* log2(bits) + qp/6, Q8, of the I and P type */
    int64_t  fill;              /* virtual buffer fill in bits */
    int      have_prev;
    uint32_t qp_prev;
    int32_t  qerr;              /* rounding error carried to the next picture, Q8 */
    uint32_t since_idr;         /* pictures coded since and including the last IDR picture */
    /* statistics since clear */
    uint32_t pictures;
    uint32_t qp_last, qp_lo, qp_hi;
    uint64_t qp_sum;
    int64_t  fill_lo, fill_hi;
    uint32_t overflow, overflow_below_max, underflow;
    /* seconds ring */
    uint32_t acc90;             /* stream time of the open second */
    uint32_t sec_bits, sec_qp16, sec_pics;
    uint32_t sec_head;          /* next record to write */
    uint32_t sec_count;         /* valid records, at most RATECTL_HISTORY_SECONDS */
    uint32_t sec_total;         /* seconds completed since clear */
    ratectl_sec_t sec[RATECTL_HISTORY_SECONDS];
} ratectl_t;

typedef struct {
    uint32_t target_kbps, buffer_ms, qp_min, qp_max, cqp;
    uint32_t pictures;
    uint32_t bits_1s;           /* last completed second, bits */
    uint32_t bits_10s;          /* mean of the last (up to) 10 completed seconds, bits per second */
    uint32_t fill_permille, fill_lo_permille, fill_hi_permille;   /* 0 in constant QP mode */
    uint32_t qp_last, qp_lo, qp_hi, qp_avg_x100;
    uint32_t overflow, overflow_below_max, underflow;
    uint32_t seconds;           /* completed seconds in the ring */
} ratectl_stats_t;

/* Defaults: constant QP 28, buffer 500 ms, range 12..51. Clears everything. */
void ratectl_init(ratectl_t *rc);

/* 0 on success, -1 on a value out of range. Effective at the next picture. */
int ratectl_set_target(ratectl_t *rc, uint32_t kbps);                 /* 0..RATECTL_KBPS_MAX, 0 = constant QP */
int ratectl_set_buffer_ms(ratectl_t *rc, uint32_t ms);                /* 100..2000 */
int ratectl_set_qp_range(ratectl_t *rc, uint32_t qp_min, uint32_t qp_max);   /* 12 <= min <= max <= 51 */
void ratectl_set_cqp(ratectl_t *rc, uint32_t qp);                     /* the QP of constant QP mode */

/* The coded picture size in pixels and the nominal picture period (90 kHz ticks); a change restarts the model. */
void ratectl_set_stream(ratectl_t *rc, uint32_t pixels, uint32_t period90);

/* Forget the model, the buffer and the previous QP (a new stream); configuration and statistics stay. */
void ratectl_restart(ratectl_t *rc);

/* The QP of the next picture (is_idr: its type; gop: IDR period in pictures). */
uint32_t ratectl_pick(ratectl_t *rc, int is_idr, uint32_t gop);

/* The picture is coded: its type, the QP used, its size in bits, the stream time since the previous picture (90 kHz ticks, at least
 * one period; more after a dropped picture). */
void ratectl_picture_done(ratectl_t *rc, int is_idr, uint32_t qp, uint32_t bits, uint32_t dt90);

void ratectl_clear_stats(ratectl_t *rc);                              /* statistics and the seconds ring */
void ratectl_get_stats(const ratectl_t *rc, ratectl_stats_t *out);

/* Record of the completed second `age` seconds ago (0 = the newest). 0 on success, -1 when age is beyond the ring. */
int ratectl_history(const ratectl_t *rc, uint32_t age, ratectl_sec_t *out);

#endif /* RTLNET_RATECTL_H */
