/*
 * rtlnet_ratectl.c -- H.264 rate control: one QP per picture from the size of the last pictures
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_ratectl.h. Fixed point only: log2 and 2^x in Q8 by bit-wise squaring (no tables
 * beyond eight constants), 64-bit integer arithmetic for the sums.
 *
 * Revision: 11-10-2026 (initial, Phase 2d)
 */
#include "rtlnet_ratectl.h"

#include <string.h>   /* memset */

#define RC_QP_DEFAULT      28u
#define RC_RATIO_I0        6u          /* first guess of the I picture size over the P picture size at equal QP */
#define RC_LOG2_RATIO_I0   662         /* log2(6) x 256 */
#define RC_MIN_BITS        64u         /* floor of a picture size for the model (log2 of 0 is undefined) */
#define RC_K_MAX           (40 * 256)
#define RC_FLOOR_DIV       4u          /* the budget of the horizon never falls below 1/4 of its nominal value */

/* 2^(1/2^k) for k = 1..8, Q30. */
static const uint32_t g_exp2_const[8] = {
    0x5A82799Au, 0x4C1BF829u, 0x45CAE0F2u, 0x42D561B4u, 0x4166C34Cu, 0x40B268FAu, 0x4058F6A8u, 0x402C6BE9u
};

/**
 * @brief log2(x) in Q8 (x > 0), eight fraction bits by repeated squaring of the mantissa.
 * @param x Value, 1..2^63.
 * @return log2(x) x 256, truncated; 0 for x = 0.
 */
static int32_t log2_q8(uint64_t x)
{
    int n = 63;
    uint64_t m;
    int32_t r;
    if (x == 0u) {
        return 0;
    }
    while ((x >> n) == 0u) {
        n--;
    }
    m = (n >= 30) ? (x >> (n - 30)) : (x << (30 - n));   /* [2^30, 2^31) */
    r = (int32_t)n * 256;
    for (int i = 7; i >= 0; i--) {
        m = (m * m) >> 30;
        if (m >= (1ull << 31)) {
            m >>= 1;
            r |= (int32_t)(1u << i);
        }
    }
    return r;
}

/**
 * @brief 2^(y/256) as an integer.
 * @param y Exponent x 256, 0..RC_K_MAX + 2048.
 * @return The value (below 2^46).
 */
static uint64_t exp2_u(int32_t y)
{
    uint64_t m = 1ull << 30;
    int32_t ip;
    uint32_t f;
    if (y < 0) {
        y = 0;
    }
    ip = y >> 8;
    f = (uint32_t)y & 255u;
    for (uint32_t k = 1u; k <= 8u; k++) {
        if ((f & (1u << (8u - k))) != 0u) {
            m = (m * g_exp2_const[k - 1u]) >> 30;
        }
    }
    return (ip >= 30) ? (m << (ip - 30)) : (m >> (30 - ip));
}

/**
 * @brief qp / 6 in Q8.
 * @param qp QP.
 * @return qp x 256 / 6, rounded.
 */
static int32_t qp_div6_q8(uint32_t qp)
{
    return (int32_t)((qp * 256u + 3u) / 6u);
}

/**
 * @brief Clamp a model constant to its valid range.
 * @param k K value, Q8.
 * @return K within 0..RC_K_MAX.
 */
static int32_t k_clamp(int32_t k)
{
    return (k < 0) ? 0 : ((k > RC_K_MAX) ? RC_K_MAX : k);
}

/**
 * @brief Bits of one nominal picture period at the target rate.
 * @param rc Controller.
 * @return target_kbps x period / 90.
 */
static uint64_t bits_per_pic(const ratectl_t *rc)
{
    return ((uint64_t)rc->target_kbps * rc->period90) / 90u;
}

/**
 * @brief Virtual buffer size in bits.
 * @param rc Controller.
 * @return target_kbps x buffer_ms.
 */
static int64_t buffer_bits(const ratectl_t *rc)
{
    return (int64_t)rc->target_kbps * (int64_t)rc->buffer_ms;
}

void ratectl_init(ratectl_t *rc)
{
    memset(rc, 0, sizeof(*rc));
    rc->cqp = RC_QP_DEFAULT;
    rc->buffer_ms = RATECTL_BUFFER_MS_DEFAULT;
    rc->qp_min = RATECTL_QP_MIN_RT;
    rc->qp_max = RATECTL_QP_MAX;
    rc->pixels = 1280u * 720u;
    rc->period90 = 3000u;
    ratectl_clear_stats(rc);
}

int ratectl_set_target(ratectl_t *rc, uint32_t kbps)
{
    int64_t old_size = buffer_bits(rc);
    if (kbps > RATECTL_KBPS_MAX) {
        return -1;
    }
    rc->target_kbps = kbps;
    if (kbps == 0u) {
        rc->have_model = 0;
        rc->fill = 0;
    } else if (rc->have_model && old_size > 0) {
        rc->fill = (rc->fill * buffer_bits(rc)) / old_size;   /* keep the fill fraction */
    } else {
        rc->have_model = 0;
    }
    return 0;
}

int ratectl_set_buffer_ms(ratectl_t *rc, uint32_t ms)
{
    int64_t old_size = buffer_bits(rc);
    if (ms < RATECTL_BUFFER_MS_MIN || ms > RATECTL_BUFFER_MS_MAX) {
        return -1;
    }
    rc->buffer_ms = ms;
    if (rc->have_model && old_size > 0) {
        rc->fill = (rc->fill * buffer_bits(rc)) / old_size;
    }
    return 0;
}

int ratectl_set_qp_range(ratectl_t *rc, uint32_t qp_min, uint32_t qp_max)
{
    if (qp_min < RATECTL_QP_MIN_RT || qp_max > RATECTL_QP_MAX || qp_min > qp_max) {
        return -1;
    }
    rc->qp_min = qp_min;
    rc->qp_max = qp_max;
    return 0;
}

void ratectl_set_cqp(ratectl_t *rc, uint32_t qp)
{
    rc->cqp = qp;
}

void ratectl_restart(ratectl_t *rc)
{
    rc->have_model = 0;
    rc->have_prev = 0;
    rc->qerr = 0;
    rc->since_idr = 0u;
    rc->fill = 0;
}

void ratectl_set_stream(ratectl_t *rc, uint32_t pixels, uint32_t period90)
{
    if (pixels == 0u || period90 == 0u) {
        return;
    }
    if (pixels != rc->pixels || period90 != rc->period90) {
        rc->pixels = pixels;
        rc->period90 = period90;
        ratectl_restart(rc);
    }
}

/**
 * @brief Set the model from the target bits per pixel (first picture of a stream) and the buffer to its set point.
 * @param rc Controller.
 * @param gop IDR period.
 * @return None.
 */
static void model_init(ratectl_t *rc, uint32_t gop)
{
    uint64_t bpp = bits_per_pic(rc);
    int32_t lb;
    int32_t q_q8;
    uint32_t q;
    int32_t kp;
    if (bpp == 0u) {
        bpp = 1u;
    }
    /* initial QP = 14 - 6 log2(bits per pixel): 0.036 bit/pixel (720p30, 1000 kb/s) gives QP 43 */
    lb = log2_q8(bpp << 8) - log2_q8((uint64_t)rc->pixels << 8);
    q_q8 = 14 * 256 - 6 * lb;
    q = (q_q8 < 0) ? 0u : (uint32_t)((q_q8 + 128) >> 8);
    if (q < rc->qp_min) {
        q = rc->qp_min;
    }
    if (q > rc->qp_max) {
        q = rc->qp_max;
    }
    /* P size at QP q such that a GOP of one I (6 x P) and gop - 1 P pictures averages the budget */
    kp = log2_q8(bpp << 8) - 2048 + log2_q8((uint64_t)gop << 8) - 2048 - (log2_q8((uint64_t)(gop + RC_RATIO_I0 - 1u) << 8) - 2048) +
         qp_div6_q8(q);
    rc->k_p = k_clamp(kp);
    rc->k_i = k_clamp(kp + RC_LOG2_RATIO_I0);
    rc->fill = (buffer_bits(rc) * RATECTL_FILL_SETPOINT_PCT) / 100;
    if (rc->pictures == 0u) {   /* the statistics start with the first picture of the stream */
        rc->fill_lo = rc->fill;
        rc->fill_hi = rc->fill;
    }
    rc->have_model = 1;
}

uint32_t ratectl_pick(ratectl_t *rc, int is_idr, uint32_t gop)
{
    uint64_t bpp;
    uint32_t fps;
    uint32_t h;
    uint32_t pos0;
    uint32_t n_i;
    uint64_t s_q8;
    int64_t size;
    int64_t budget;
    int64_t floor_budget;
    int32_t q_q8;
    int32_t acc;
    int32_t qi;
    uint32_t lo;
    uint32_t hi;
    if (rc->target_kbps == 0u) {
        return rc->cqp;
    }
    if (gop < 1u) {
        gop = 1u;
    }
    if (!rc->have_model) {
        model_init(rc, gop);
    }
    bpp = bits_per_pic(rc);
    size = buffer_bits(rc);
    /* horizon: one second or one GOP, whichever is longer, at most two seconds */
    fps = (RATECTL_TICKS_PER_S + rc->period90 / 2u) / rc->period90;
    if (fps < 1u) {
        fps = 1u;
    }
    h = (gop < 2u * fps) ? gop : 2u * fps;
    if (h < fps) {
        h = fps;
    }
    pos0 = is_idr ? 0u : ((rc->since_idr == 0u) ? 1u : rc->since_idr);
    /* IDR pictures among the next h: multiples of gop in [pos0, pos0 + h - 1] */
    n_i = (pos0 + h - 1u) / gop + ((pos0 > 0u) ? 0u : 1u) - ((pos0 > 0u) ? (pos0 - 1u) / gop : 0u);
    if (n_i > h) {
        n_i = h;
    }
    s_q8 = (uint64_t)n_i * exp2_u(rc->k_i + 2048) + (uint64_t)(h - n_i) * exp2_u(rc->k_p + 2048);
    budget = (int64_t)h * (int64_t)bpp + (size * RATECTL_FILL_SETPOINT_PCT) / 100 - rc->fill;
    floor_budget = ((int64_t)h * (int64_t)bpp) / RC_FLOOR_DIV;
    if (budget < floor_budget) {
        budget = floor_budget;
    }
    if (budget < 1) {
        budget = 1;
    }
    q_q8 = 6 * (log2_q8(s_q8) - log2_q8((uint64_t)budget << 8));
    if (q_q8 < (int32_t)(rc->qp_min * 256u)) {
        q_q8 = (int32_t)(rc->qp_min * 256u);
    }
    if (q_q8 > (int32_t)(rc->qp_max * 256u)) {
        q_q8 = (int32_t)(rc->qp_max * 256u);
    }
    acc = q_q8 + rc->qerr;
    qi = (acc + 128) >> 8;
    lo = rc->qp_min;
    hi = rc->qp_max;
    if (rc->have_prev) {
        if (rc->qp_prev > RATECTL_QP_STEP_MAX && lo < rc->qp_prev - RATECTL_QP_STEP_MAX) {
            lo = rc->qp_prev - RATECTL_QP_STEP_MAX;
        }
        if (hi > rc->qp_prev + RATECTL_QP_STEP_MAX) {
            hi = rc->qp_prev + RATECTL_QP_STEP_MAX;
        }
        if (lo > hi) {   /* the previous QP lay outside a range narrowed since */
            lo = hi = (rc->qp_prev < rc->qp_min) ? rc->qp_min : rc->qp_max;
        }
    }
    if (qi < (int32_t)lo) {
        qi = (int32_t)lo;
    }
    if (qi > (int32_t)hi) {
        qi = (int32_t)hi;
    }
    rc->qerr = acc - qi * 256;
    if (rc->qerr > 256) {
        rc->qerr = 256;
    }
    if (rc->qerr < -256) {
        rc->qerr = -256;
    }
    return (uint32_t)qi;
}

/**
 * @brief Close the open second: append its record to the ring.
 * @param rc Controller.
 * @return None.
 */
static void seal_second(ratectl_t *rc)
{
    ratectl_sec_t *s = &rc->sec[rc->sec_head];
    uint32_t pics = rc->sec_pics;
    uint32_t q4 = (pics != 0u) ? rc->sec_qp16 / pics : 0u;
    int64_t size = buffer_bits(rc);
    s->bits = rc->sec_bits;
    s->qp_q4 = (uint16_t)q4;
    s->fill_pct = (uint8_t)((rc->target_kbps != 0u && size > 0) ? (rc->fill * 100) / size : 0);
    s->pics = (uint8_t)((pics > 255u) ? 255u : pics);
    rc->sec_head = (rc->sec_head + 1u) % RATECTL_HISTORY_SECONDS;
    if (rc->sec_count < RATECTL_HISTORY_SECONDS) {
        rc->sec_count++;
    }
    rc->sec_total++;
    rc->sec_bits = 0u;
    rc->sec_qp16 = 0u;
    rc->sec_pics = 0u;
}

void ratectl_picture_done(ratectl_t *rc, int is_idr, uint32_t qp, uint32_t bits, uint32_t dt90)
{
    int32_t kobs;
    if (dt90 < rc->period90) {
        dt90 = rc->period90;
    }
    rc->pictures++;
    rc->qp_last = qp;
    if (qp < rc->qp_lo) {
        rc->qp_lo = qp;
    }
    if (qp > rc->qp_hi) {
        rc->qp_hi = qp;
    }
    rc->qp_sum += qp;
    if (is_idr) {
        rc->since_idr = 1u;
    } else if (rc->since_idr < 65535u) {
        rc->since_idr++;
    }
    rc->qp_prev = qp;
    rc->have_prev = 1;
    if (rc->target_kbps != 0u && rc->have_model) {
        int64_t size = buffer_bits(rc);
        int64_t drain = ((int64_t)rc->target_kbps * (int64_t)dt90) / 90;
        kobs = log2_q8((bits < RC_MIN_BITS) ? RC_MIN_BITS : bits) + qp_div6_q8(qp);
        if (is_idr) {
            rc->k_i = k_clamp(rc->k_i + ((kobs - rc->k_i) * 3) / 4);
        } else {
            int32_t d = (kobs - rc->k_p) / 2;
            rc->k_p = k_clamp(rc->k_p + d);
            rc->k_i = k_clamp(rc->k_i + d / 4);   /* the I model follows the content between the rare I pictures */
        }
        rc->fill += bits;
        if (rc->fill > size) {
            rc->overflow++;
            if (qp < rc->qp_max) {
                rc->overflow_below_max++;
            }
            rc->fill = size;
        }
        if (rc->fill > rc->fill_hi) {
            rc->fill_hi = rc->fill;
        }
        rc->fill -= drain;
        if (rc->fill < 0) {
            rc->underflow++;
            rc->fill = 0;
        }
        if (rc->fill < rc->fill_lo) {
            rc->fill_lo = rc->fill;
        }
    }
    rc->sec_bits += bits;
    rc->sec_qp16 += qp * 16u;
    rc->sec_pics++;
    rc->acc90 += dt90;
    if (rc->acc90 >= RATECTL_TICKS_PER_S) {
        uint32_t guard = RATECTL_HISTORY_SECONDS;
        seal_second(rc);
        rc->acc90 -= RATECTL_TICKS_PER_S;
        while (rc->acc90 >= RATECTL_TICKS_PER_S && guard != 0u) {   /* a stall longer than a second: empty records */
            seal_second(rc);
            rc->acc90 -= RATECTL_TICKS_PER_S;
            guard--;
        }
        if (rc->acc90 >= RATECTL_TICKS_PER_S) {
            rc->acc90 = 0u;
        }
    }
}

void ratectl_clear_stats(ratectl_t *rc)
{
    rc->pictures = 0u;
    rc->qp_last = 0u;
    rc->qp_lo = 0xFFFFu;
    rc->qp_hi = 0u;
    rc->qp_sum = 0u;
    rc->fill_lo = rc->fill;
    rc->fill_hi = rc->fill;
    rc->overflow = 0u;
    rc->overflow_below_max = 0u;
    rc->underflow = 0u;
    rc->acc90 = 0u;
    rc->sec_bits = 0u;
    rc->sec_qp16 = 0u;
    rc->sec_pics = 0u;
    rc->sec_head = 0u;
    rc->sec_count = 0u;
    rc->sec_total = 0u;
}

int ratectl_history(const ratectl_t *rc, uint32_t age, ratectl_sec_t *out)
{
    if (age >= rc->sec_count) {
        return -1;
    }
    *out = rc->sec[(rc->sec_head + RATECTL_HISTORY_SECONDS - 1u - age) % RATECTL_HISTORY_SECONDS];
    return 0;
}

void ratectl_get_stats(const ratectl_t *rc, ratectl_stats_t *out)
{
    int64_t size = buffer_bits(rc);
    uint64_t sum = 0u;
    uint32_t n = (rc->sec_count < 10u) ? rc->sec_count : 10u;
    memset(out, 0, sizeof(*out));
    out->target_kbps = rc->target_kbps;
    out->buffer_ms = rc->buffer_ms;
    out->qp_min = rc->qp_min;
    out->qp_max = rc->qp_max;
    out->cqp = rc->cqp;
    out->pictures = rc->pictures;
    for (uint32_t i = 0u; i < n; i++) {
        ratectl_sec_t s = { 0u, 0u, 0u, 0u };
        (void)ratectl_history(rc, i, &s);
        sum += s.bits;
        if (i == 0u) {
            out->bits_1s = s.bits;
        }
    }
    out->bits_10s = (n != 0u) ? (uint32_t)(sum / n) : 0u;
    if (rc->target_kbps != 0u && size > 0) {
        out->fill_permille = (uint32_t)((rc->fill * 1000) / size);
        out->fill_lo_permille = (uint32_t)((rc->fill_lo * 1000) / size);
        out->fill_hi_permille = (uint32_t)((rc->fill_hi * 1000) / size);
    }
    out->qp_last = rc->qp_last;
    out->qp_lo = (rc->pictures != 0u) ? rc->qp_lo : 0u;
    out->qp_hi = rc->qp_hi;
    out->qp_avg_x100 = (rc->pictures != 0u) ? (uint32_t)((rc->qp_sum * 100u) / rc->pictures) : 0u;
    out->overflow = rc->overflow;
    out->overflow_below_max = rc->overflow_below_max;
    out->underflow = rc->underflow;
    out->seconds = rc->sec_count;
}
