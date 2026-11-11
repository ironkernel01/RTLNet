/*
 * test_ratectl.c -- host unit test of the H.264 rate controller (src/video/rtlnet_ratectl.c)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: drives the controller with a synthetic encoder model and checks the gates of microblaze/documentation/rtlnet_ratectl.md
 * (section 7). Model: the bits of a picture are complexity x 2^((34 - QP) / 6) x (1 + noise), an IDR picture is RATIO times a P
 * picture at equal QP, noise is uniform within +-10 %. The test uses double for the model only; the controller is fixed point.
 * Sequences: static, constant motion, a 3 s noise burst, a scene cut, ramps. Cases: 720p30 1000 kb/s, 1080p30 2000 kb/s,
 * 720p30 300 kb/s, each with GOP 30 and GOP 1. Prints one INFO line per run and one PASS or FAIL line per gate; the last line is
 * "RATECTL_TEST: PASS" or "RATECTL_TEST: FAIL" and the exit code follows it.
 *
 * Revision: 11-10-2026 (initial, Phase 2d)
 */
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rtlnet_ratectl.h"

#define FPS         30u
#define PERIOD90    3000u
#define N_PICS      2700u      /* 90 s */
#define SKIP_PICS   60u        /* the first 2 s are not gated */
#define QP_REF      34.0       /* QP at which the complexity is the size of a P picture */

typedef enum { SEQ_STATIC, SEQ_MOTION, SEQ_BURST, SEQ_CUT, SEQ_RAMP, SEQ_SATURATE, SEQ_BURST_IDR, SEQ_CUT_IDR } seq_t;
static const char *const g_seq_name[] = { "static", "motion", "burst", "cut", "ramp", "saturate", "burst@IDR", "cut@IDR" };

typedef struct {
    const char *name;
    uint32_t    width, height, kbps;
} case_t;

typedef struct {
    uint32_t bits[N_PICS];
    uint32_t qp[N_PICS];
    uint8_t  idr[N_PICS];
} run_t;

static ratectl_t g_rc;   /* about 29 KiB: static, as on the target */
static run_t     g_run;
static int       g_fail;
static int       g_checks;

static uint32_t g_rng = 12345u;

/**
 * @brief Uniform noise in [-0.10, +0.10] from a fixed-seed LCG.
 * @return Noise.
 */
static double noise(void)
{
    g_rng = g_rng * 1664525u + 1013904223u;
    return (((double)(g_rng >> 8) / 16777216.0) - 0.5) * 0.20;
}

/**
 * @brief Content complexity multiplier at a picture.
 * @param seq Sequence.
 * @param i Picture index.
 * @return Multiplier of the equilibrium complexity (1.0 = the complexity that lands at QP 34).
 */
static double mult(seq_t seq, uint32_t i)
{
    double t = (double)i / (double)FPS;
    switch (seq) {
    case SEQ_STATIC:   return 0.02;
    case SEQ_MOTION:   return 1.0;
    case SEQ_BURST:    return (t >= 20.5 && t < 23.5) ? 4.0 : 1.0;
    case SEQ_CUT:      return (t >= 30.5) ? 3.0 : 1.0;
    case SEQ_RAMP:     return (t < 30.0) ? 0.5 + 2.5 * t / 30.0 : 3.0 - 2.5 * (t - 30.0) / 30.0 + ((t >= 60.0) ? 0.0 : 0.0);
    case SEQ_SATURATE: return 40.0;
    case SEQ_BURST_IDR: return (t >= 20.0 && t < 23.0) ? 4.0 : 1.0;   /* starts on an IDR picture of GOP 30 */
    case SEQ_CUT_IDR:  return (t >= 30.0) ? 3.0 : 1.0;
    }
    return 1.0;
}

/**
 * @brief Run the controller against the model for N_PICS pictures, as venc does (IDR first and every gop pictures).
 * @param c Case.
 * @param gop GOP length.
 * @param seq Sequence.
 * @param ratio IDR over P size at equal QP.
 * @param target_kbps Target, 0 = constant QP.
 * @return None (g_run holds the pictures; g_rc the controller).
 */
static void run(const case_t *c, uint32_t gop, seq_t seq, double ratio, uint32_t target_kbps)
{
    double bpp = (double)c->kbps * 1000.0 / (double)FPS;
    double cxp = (gop > 1u) ? bpp * (double)gop / ((double)gop - 1.0 + ratio) : bpp / ratio;
    uint32_t pos = 0u;
    ratectl_init(&g_rc);
    (void)ratectl_set_target(&g_rc, target_kbps);
    ratectl_set_cqp(&g_rc, 30u);
    ratectl_set_stream(&g_rc, c->width * c->height, PERIOD90);
    ratectl_restart(&g_rc);
    ratectl_clear_stats(&g_rc);
    for (uint32_t i = 0u; i < N_PICS; i++) {
        int is_idr = (i == 0u) || (pos >= gop);
        uint32_t qp = ratectl_pick(&g_rc, is_idr, gop);
        double b = cxp * mult(seq, i) * pow(2.0, (QP_REF - (double)qp) / 6.0) * (is_idr ? ratio : 1.0) * (1.0 + noise());
        uint32_t bits = (uint32_t)(b < 64.0 ? 64.0 : b);
        pos = is_idr ? 1u : pos + 1u;
        g_run.bits[i] = bits;
        g_run.qp[i] = qp;
        g_run.idr[i] = (uint8_t)is_idr;
        ratectl_picture_done(&g_rc, is_idr, qp, bits, PERIOD90);
    }
}

/**
 * @brief Largest relative error of the sliding windows of w pictures against the target, windows starting at or after `from`.
 * @param c Case.
 * @param w Window in pictures.
 * @param from First window start.
 * @param to One past the last window start (0 = the end).
 * @return Worst |window bits / target - 1| in percent.
 */
static double worst_window(const case_t *c, uint32_t w, uint32_t from, uint32_t to)
{
    double target = (double)c->kbps * 1000.0 * (double)w / (double)FPS;
    double worst = 0.0;
    uint64_t sum = 0u;
    uint32_t last = (to != 0u && to < N_PICS - w + 1u) ? to : N_PICS - w + 1u;
    for (uint32_t i = 0u; i < w; i++) {
        sum += g_run.bits[i];
    }
    for (uint32_t s = 0u; s + w <= N_PICS && s < last; s++) {
        if (s > 0u) {
            sum += g_run.bits[s + w - 1u];
            sum -= g_run.bits[s - 1u];
        }
        if (s >= from) {
            double e = fabs((double)sum / target - 1.0) * 100.0;
            if (e > worst) {
                worst = e;
            }
        }
    }
    return worst;
}

/**
 * @brief First window start (picture) from which every 1 s window stays within 10 % of the target; N_PICS when none.
 * @param c Case.
 * @param from Do not look before this picture.
 * @return Picture index.
 */
static uint32_t settle_pic(const case_t *c, uint32_t from)
{
    double target = (double)c->kbps * 1000.0;
    uint32_t ok_from = N_PICS;
    uint64_t sum = 0u;
    for (uint32_t s = N_PICS - FPS; ; s--) {
        sum = 0u;
        for (uint32_t i = s; i < s + FPS; i++) {
            sum += g_run.bits[i];
        }
        if (fabs((double)sum / target - 1.0) > 0.10) {
            break;
        }
        ok_from = s;
        if (s == from || s == 0u) {
            break;
        }
    }
    return ok_from;
}

/**
 * @brief Print one gate line and count it.
 * @param ok Result.
 * @param fmt Message format.
 * @return None.
 */
static void gate(int ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void gate(int ok, const char *fmt, ...)
{
    va_list ap;
    char msg[256];
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    printf("%s: %s\n", ok ? "PASS" : "FAIL", msg);
    g_checks++;
    if (!ok) {
        g_fail++;
    }
}

int main(void)
{
    static const case_t cases[] = {
        { "720p30 1000 kb/s", 1280u, 720u, 1000u },
        { "1080p30 2000 kb/s", 1920u, 1080u, 2000u },
        { "720p30 300 kb/s", 1280u, 720u, 300u },
    };
    static const uint32_t gops[] = { 30u, 1u };
    static const seq_t seqs[] = { SEQ_STATIC, SEQ_MOTION, SEQ_BURST, SEQ_CUT, SEQ_RAMP };
    double w1_worst = 0.0, w10_worst = 0.0;
    double rec_worst = 0.0;
    uint32_t ovf_below = 0u, step_viol = 0u, range_viol = 0u, neg_viol = 0u, static_bad = 0u, static_under_missing = 0u;
    uint32_t hist_bad = 0u;
    uint32_t runs = 0u;
    uint32_t sum_viol = 0u;
    char w1_where[96] = "", w10_where[96] = "", rec_where[96] = "";

    printf("RATECTL_TEST: model bits = complexity x 2^((34 - QP) / 6) x (1 +- 10 %%), IDR 6 x P (also 4 and 8 for constant motion)\n");
    for (uint32_t ci = 0u; ci < 3u; ci++) {
        for (uint32_t gi = 0u; gi < 2u; gi++) {
            for (uint32_t si = 0u; si < 5u; si++) {
                const case_t *c = &cases[ci];
                seq_t seq = seqs[si];
                ratectl_stats_t st;
                int64_t fill = 0;
                int64_t size = (int64_t)c->kbps * 500;
                int64_t bpp = (int64_t)c->kbps * 1000 / FPS;
                uint64_t sum_all = 0u;
                run(c, gops[gi], seq, 6.0, c->kbps);
                runs++;
                ratectl_get_stats(&g_rc, &st);
                /* independent leaky bucket from the bit sequence */
                fill = (size * RATECTL_FILL_SETPOINT_PCT) / 100;
                for (uint32_t i = 0u; i < N_PICS; i++) {
                    fill += g_run.bits[i];
                    if (fill > size) {
                        if (g_run.qp[i] < RATECTL_QP_MAX) {
                            ovf_below++;
                        }
                        fill = size;
                    }
                    fill -= bpp;
                    if (fill < 0) {
                        fill = 0;
                    }
                    if (i > 0u) {
                        uint32_t d = (g_run.qp[i] > g_run.qp[i - 1u]) ? g_run.qp[i] - g_run.qp[i - 1u] : g_run.qp[i - 1u] - g_run.qp[i];
                        if (d > RATECTL_QP_STEP_MAX) {
                            step_viol++;
                        }
                    }
                    if (g_run.qp[i] < RATECTL_QP_MIN_RT || g_run.qp[i] > RATECTL_QP_MAX) {
                        range_viol++;
                    }
                    sum_all += g_run.bits[i];
                }
                if (st.fill_lo_permille > 1000u || st.fill_hi_permille > 1000u || st.fill_permille > 1000u) {
                    neg_viol++;   /* a fill figure outside 0..100 % (the signed fill is clamped at 0, so a negative one wraps) */
                }
                printf("INFO: %-18s GOP %-2u %-7s mean %7.1f kb/s  QP %2u..%2u avg %u.%02u  fill %u..%u %%  ovf %u (below max %u)  und %u\n",
                       c->name, (unsigned)gops[gi], g_seq_name[seq], (double)sum_all / ((double)N_PICS / FPS) / 1000.0,
                       (unsigned)st.qp_lo, (unsigned)st.qp_hi, (unsigned)(st.qp_avg_x100 / 100u), (unsigned)(st.qp_avg_x100 % 100u),
                       (unsigned)(st.fill_lo_permille / 10u), (unsigned)(st.fill_hi_permille / 10u), (unsigned)st.overflow,
                       (unsigned)st.overflow_below_max, (unsigned)st.underflow);
                if (seq == SEQ_MOTION) {
                    double w1 = worst_window(c, FPS, SKIP_PICS, 0u);
                    double w10 = worst_window(c, 10u * FPS, SKIP_PICS, 0u);
                    if (w1 > w1_worst) {
                        w1_worst = w1;
                        snprintf(w1_where, sizeof(w1_where), "%s GOP %u", c->name, (unsigned)gops[gi]);
                    }
                    if (w10 > w10_worst) {
                        w10_worst = w10;
                        snprintf(w10_where, sizeof(w10_where), "%s GOP %u", c->name, (unsigned)gops[gi]);
                    }
                }
                if (seq == SEQ_BURST || seq == SEQ_CUT) {
                    uint32_t event = (seq == SEQ_BURST) ? (23u * FPS + FPS / 2u) : (30u * FPS + FPS / 2u);   /* end of the burst, the cut */
                    uint32_t ok_from = settle_pic(c, 0u);
                    double rec_s = ((double)ok_from + (double)FPS - (double)event) / (double)FPS;   /* window end vs the event */
                    if (ok_from > event) {
                        if (rec_s > rec_worst) {
                            rec_worst = rec_s;
                            snprintf(rec_where, sizeof(rec_where), "%s GOP %u %s", c->name, (unsigned)gops[gi], g_seq_name[seq]);
                        }
                    }
                    if (ok_from >= N_PICS) {
                        rec_worst = 99.0;
                        snprintf(rec_where, sizeof(rec_where), "%s GOP %u %s never settles", c->name, (unsigned)gops[gi], g_seq_name[seq]);
                    }
                }
                if (seq == SEQ_STATIC) {
                    uint32_t bad = 0u;
                    for (uint32_t i = N_PICS - 5u * FPS; i < N_PICS; i++) {
                        if (g_run.qp[i] != RATECTL_QP_MIN_RT) {
                            bad++;
                        }
                    }
                    static_bad += bad;
                    if (st.underflow == 0u) {
                        static_under_missing++;
                    }
                }
                /* history: completed seconds, and the newest record against the pictures it covers */
                {
                    ratectl_sec_t r;
                    uint64_t b = 0u;
                    uint32_t secs = N_PICS / FPS;
                    if (st.seconds != secs || ratectl_history(&g_rc, 0u, &r) != 0) {
                        hist_bad++;
                    } else {
                        for (uint32_t i = N_PICS - FPS; i < N_PICS; i++) {
                            b += g_run.bits[i];
                        }
                        if (r.bits != b || r.pics != FPS) {
                            hist_bad++;
                        }
                        if (st.bits_1s != b) {
                            hist_bad++;
                        }
                    }
                }
                if (st.overflow_below_max != 0u) {
                    sum_viol += st.overflow_below_max;
                }
            }
        }
    }

    /* Constant motion at the other IDR ratios (4 and 8 times a P picture). */
    for (uint32_t ri = 0u; ri < 2u; ri++) {
        double ratio = (ri == 0u) ? 4.0 : 8.0;
        for (uint32_t ci = 0u; ci < 3u; ci++) {
            for (uint32_t gi = 0u; gi < 2u; gi++) {
                double w1;
                double w10;
                run(&cases[ci], gops[gi], SEQ_MOTION, ratio, cases[ci].kbps);
                w1 = worst_window(&cases[ci], FPS, SKIP_PICS, 0u);
                w10 = worst_window(&cases[ci], 10u * FPS, SKIP_PICS, 0u);
                printf("INFO: %-18s GOP %-2u motion, IDR %.0f x P: worst 1 s %.2f %%, worst 10 s %.2f %%\n", cases[ci].name,
                       (unsigned)gops[gi], ratio, w1, w10);
                if (w1 > w1_worst) {
                    w1_worst = w1;
                    snprintf(w1_where, sizeof(w1_where), "%s GOP %u IDR %.0f x P", cases[ci].name, (unsigned)gops[gi], ratio);
                }
                if (w10 > w10_worst) {
                    w10_worst = w10;
                    snprintf(w10_where, sizeof(w10_where), "%s GOP %u IDR %.0f x P", cases[ci].name, (unsigned)gops[gi], ratio);
                }
            }
        }
    }

    /* Events that start on the IDR picture itself: the picture is 6 x 4 (or 6 x 3) P pictures at once and cannot be foreseen; the
     * overflow is counted and reported, nothing is gated. */
    for (uint32_t k = 0u; k < 2u; k++) {
        ratectl_stats_t st;
        run(&cases[0], 30u, k == 0u ? SEQ_BURST_IDR : SEQ_CUT_IDR, 6.0, cases[0].kbps);
        ratectl_get_stats(&g_rc, &st);
        printf("INFO: %-18s GOP 30 %-9s (no look-ahead possible): overflow %u (below max %u), fill max %u %%, QP max %u\n", cases[0].name,
               g_seq_name[k == 0u ? SEQ_BURST_IDR : SEQ_CUT_IDR], (unsigned)st.overflow, (unsigned)st.overflow_below_max,
               (unsigned)(st.fill_hi_permille / 10u), (unsigned)st.qp_hi);
    }

    /* Saturation: content far beyond the link; the QP pins at the maximum, overflow is counted, nothing crashes. */
    {
        ratectl_stats_t st;
        uint32_t after_max_bad = 0u;
        int reached = 0;
        run(&cases[2], 30u, SEQ_SATURATE, 6.0, cases[2].kbps);
        ratectl_get_stats(&g_rc, &st);
        for (uint32_t i = 0u; i < N_PICS; i++) {
            if (g_run.qp[i] == RATECTL_QP_MAX) {
                reached = 1;
            } else if (reached && i > 0u) {
                after_max_bad++;
            }
        }
        printf("INFO: saturation: QP max %u, overflow %u, below max %u, QP left the maximum %u times\n", (unsigned)st.qp_hi,
               (unsigned)st.overflow, (unsigned)st.overflow_below_max, (unsigned)after_max_bad);
        gate(st.qp_hi == RATECTL_QP_MAX && st.overflow > 0u && after_max_bad == 0u,
             "saturation: QP pins at %u, %u overflows counted at QP_MAX, the controller keeps running", (unsigned)st.qp_hi,
             (unsigned)st.overflow);
    }

    /* Constant QP mode: the configured QP for every picture of either type, statistics still collected. */
    {
        ratectl_stats_t st;
        uint32_t bad = 0u;
        run(&cases[0], 30u, SEQ_MOTION, 6.0, 0u);
        for (uint32_t i = 0u; i < N_PICS; i++) {
            if (g_run.qp[i] != 30u) {
                bad++;
            }
        }
        ratectl_get_stats(&g_rc, &st);
        gate(bad == 0u && st.fill_permille == 0u && st.overflow == 0u && st.underflow == 0u && st.bits_1s != 0u && st.qp_lo == 30u &&
                 st.qp_hi == 30u,
             "constant QP unchanged: %u of %u pictures at QP 30, no buffer figures, bits_1s %u", (unsigned)(N_PICS - bad),
             (unsigned)N_PICS, (unsigned)st.bits_1s);
        ratectl_set_cqp(&g_rc, 8u);
        gate(ratectl_pick(&g_rc, 1, 30u) == 8u && ratectl_pick(&g_rc, 0, 30u) == 8u, "constant QP: the value is passed through (the driver clamps to 12)");
    }

    /* History ring: 3700 s of pictures wrap the ring of 3600 records. */
    {
        ratectl_sec_t r;
        ratectl_init(&g_rc);
        ratectl_clear_stats(&g_rc);
        for (uint32_t i = 0u; i < 3700u * FPS; i++) {
            ratectl_picture_done(&g_rc, 0, 20u + (i / FPS) % 5u, 1000u + i / FPS, PERIOD90);
        }
        gate(g_rc.sec_count == RATECTL_HISTORY_SECONDS && g_rc.sec_total == 3700u && ratectl_history(&g_rc, 0u, &r) == 0 &&
                 r.bits == 30u * (1000u + 3699u) && r.pics == 30u && ratectl_history(&g_rc, 3599u, &r) == 0 &&
                 r.bits == 30u * (1000u + 100u) && ratectl_history(&g_rc, 3600u, &r) != 0,
             "history ring: %u records of %u bytes (%u bytes), 3700 s wrap correctly, oldest kept is second 100",
             (unsigned)RATECTL_HISTORY_SECONDS, (unsigned)sizeof(ratectl_sec_t),
             (unsigned)(RATECTL_HISTORY_SECONDS * sizeof(ratectl_sec_t)));
    }

    gate(w1_worst <= 10.0, "1 s windows within +-10 %% of the target after the first 2 s (constant motion: 6 cases at IDR 6x, 12 more at 4x and 8x): worst %.2f %% (%s)",
         w1_worst, w1_where);
    gate(w10_worst <= 3.0, "10 s windows within +-3 %% of the target after the first 2 s (constant motion): worst %.2f %% (%s)", w10_worst,
         w10_where);
    gate(ovf_below == 0u && sum_viol == 0u && neg_viol == 0u,
         "buffer never overflows below QP_MAX and never leaves 0..100 %% (%u runs, 5 sequences x 2 GOPs x 3 cases): %u overflows below max",
         (unsigned)runs, (unsigned)(ovf_below + sum_viol));
    gate(step_viol == 0u && range_viol == 0u, "QP changes by at most %u per picture and stays within 12..51: %u step violations, %u range violations",
         (unsigned)RATECTL_QP_STEP_MAX, (unsigned)step_viol, (unsigned)range_viol);
    gate(static_bad == 0u && static_under_missing == 0u,
         "static content settles at QP_MIN 12 (last 5 s) with underflow reported: %u pictures off the minimum, %u runs without underflow report",
         (unsigned)static_bad, (unsigned)static_under_missing);
    gate(rec_worst <= 2.0, "recovery after the noise burst and the scene cut: every later 1 s window within +-10 %% within %.2f s (%s)", rec_worst,
         rec_where);
    gate(hist_bad == 0u, "per-second record matches the pictures it covers in all runs (%u mismatches)", (unsigned)hist_bad);
    printf("RATECTL_TEST: %s (%d gates, %d failed)\n", g_fail == 0 ? "PASS" : "FAIL", g_checks, g_fail);
    return g_fail == 0 ? 0 : 1;
}
