/*
 * venc_irq_host_test.c -- host test of the encoder session in both notification modes
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_venc.c, the encoder control layer, the picture queue, the multiplexer and the rate controller on the PC against the harness'
 * models (host/host_platform.c: frame buffer, DDR3, interrupt controller; host/host_h264_model.c: the encoder core with its interrupt registers).
 * Every scenario runs in the polled mode and in the interrupt mode; what must hold:
 *   * lockstep (one frame, then run until it is sent): the two modes send byte-identical datagrams (constant QP, rate control, a profile change
 *     with a forced IDR picture, an encoder error, a mode switch in mid-stream, a core without interrupt registers that degrades to polled);
 *   * every access unit of the stream is the picture the model wrote: the transport stream is demultiplexed here and each access unit's PTS and
 *     elementary stream bytes are compared with the model's record of the picture (the SPS and PPS in front of an IDR picture are skipped);
 *   * pipelined (frames arriving faster than pictures are coded, the encoder model finishing a picture between any two register accesses of the
 *     firmware, so the handler interrupts the main loop at every point): no error, every frame accounted for as sent or dropped, the picture
 *     queue drained, the handler started pictures, no interrupt register touched on the older core;
 *   * interrupt-specific: the self-test reaches the handler, events are counted per source, the mode in force is reported;
 *   * deblocking filter (CAPS bit 22 of the core model): on at the first picture, off and on again between pictures without an IDR picture or an error, the
 *     offsets reach the core and are applied at the next picture, the request survives a stream restart (configure_mode writes it again), and a core
 *     without the filter refuses "on" by name and keeps coding.
 * Prints "VENC_IRQ_TEST: PASS (...)" or "VENC_IRQ_TEST: FAIL" and returns 0 / 1. --neg: forces one failed check (the negative control).
 * Build: microblaze/firmware/test/venc_irq_host_test.ps1.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "host_platform.h"
#include "rtlnet_csi2_rx.h"
#include "rtlnet_h264_enc.h"       /* the deblocking filter register fields the model reports */
#include "rtlnet_h264_enc_ctl.h"
#include "rtlnet_mmio.h"
#include "rtlnet_platform.h"
#include "rtlnet_picq.h"
#include "rtlnet_tsmux.h"
#include "rtlnet_venc.h"

static int g_checks;
static int g_fails;
static int g_neg;

static void check(int ok, const char *what)
{
    g_checks++;
    if (!ok) {
        g_fails++;
        printf("  CHECK FAILED: %s\n", what);
    }
}

/* Calls the harness expects of the firmware main (board.c reads the DDR3 calibration through the arbiter model). */
typedef struct {
    uint64_t hash;
    uint32_t bytes, dgrams, aus;
    venc_status_t st;
    uint32_t model_pics, model_starts, illegal, delivered;
    int demux_ok;
} result_t;

#define CAP_BYTES (6u * 1024u * 1024u)
#define BASE_FRAME 10u

static void setup(int irq_capable, int seam)
{
    host_model_ddr_set(1, 1);
    host_model_video_set(1);
    host_model_video_frames(BASE_FRAME);
    host_model_h264_irq_caps(irq_capable);
    host_model_h264_set(1, seam);
    host_model_h264_hp(1u, 1u, seam ? RTLNET_H264_CTL_HP_CAP_CABAC : 0u, 0xFFFFu);
    host_model_h264_timing(6u, 0u);
    plat_init();
    venc_init();
    host_video_udp_reset();
    host_video_udp_capture(CAP_BYTES);
}

static uint32_t pictures_sent(void)
{
    venc_status_t s;
    venc_get_status(&s);
    return s.pictures;
}

/* Run the firmware loop one step: the main loop service, then a model tick. */
static void step(void)
{
    venc_poll();
    host_model_h264_advance(1u);
}

/* Publish frame number n (the frame buffer model's frame count) and run until `want` pictures are sent, bounded. */
static int run_until_sent(uint32_t want, uint32_t max_steps)
{
    for (uint32_t i = 0u; i < max_steps; i++) {
        step();
        if (pictures_sent() >= want) {
            for (int k = 0; k < 4; k++) {
                step();   /* settle: the encoder must be idle and the queue empty */
            }
            return 1;
        }
    }
    return 0;
}

/* Demultiplex the captured transport stream: per access unit the PTS, the random access flag and the elementary stream bytes. */
typedef struct {
    uint64_t pts;
    int      rai;
    uint32_t es_len;
    uint32_t es_off;
} au_t;

#define MAX_AU 1024u
static au_t     g_au[MAX_AU];
static uint32_t g_au_n;
static uint8_t *g_es;
static uint32_t g_es_len;

static uint64_t decode_pts(const uint8_t *b)
{
    return ((uint64_t)((b[0] >> 1) & 7u) << 30) | ((uint64_t)b[1] << 22) | ((uint64_t)(b[2] >> 1) << 15) | ((uint64_t)b[3] << 7) | (uint64_t)(b[4] >> 1);
}

static int demux(void)
{
    uint32_t len = 0u;
    const uint8_t *d = host_video_udp_data(&len);
    int ok = 1;
    g_au_n = 0u;
    g_es_len = 0u;
    if (g_es == NULL) {
        g_es = (uint8_t *)malloc(CAP_BYTES);
    }
    for (uint32_t p = 0u; p + 188u <= len; p += 188u) {
        const uint8_t *pk = &d[p];
        uint32_t pid = ((uint32_t)(pk[1] & 0x1Fu) << 8) | pk[2];
        uint32_t off = 4u;
        int pusi = (pk[1] & 0x40u) != 0;
        if (pk[0] != 0x47u) {
            return 0;
        }
        if (pid != TSMUX_PID_VIDEO) {
            continue;
        }
        if ((pk[3] & 0x20u) != 0u) {
            if (pusi && g_au_n < MAX_AU) {
                g_au[g_au_n].rai = (pk[5] & 0x40u) != 0u;
            }
            off += 1u + pk[4];
        } else if (pusi && g_au_n < MAX_AU) {
            g_au[g_au_n].rai = 0;
        }
        if ((pk[3] & 0x10u) == 0u || off >= 188u) {
            continue;
        }
        if (pusi) {
            if (g_au_n >= MAX_AU || off + TSMUX_PES_HDR_BYTES > 188u || pk[off] != 0u || pk[off + 1u] != 0u || pk[off + 2u] != 1u || pk[off + 3u] != 0xE0u) {
                return 0;
            }
            g_au[g_au_n].pts = decode_pts(&pk[off + 9u]);
            g_au[g_au_n].es_off = g_es_len;
            g_au[g_au_n].es_len = 0u;
            off += TSMUX_PES_HDR_BYTES;
            g_au_n++;
        }
        if (g_au_n == 0u) {
            ok = 0;
            continue;
        }
        memcpy(&g_es[g_es_len], &pk[off], 188u - off);
        g_es_len += 188u - off;
        g_au[g_au_n - 1u].es_len += 188u - off;
    }
    return ok;
}

/* Check every access unit against the model's pictures (picture index first_idx + k) and the PTS rule. Returns 1 when all hold. */
static int verify_stream(uint32_t first_idx, uint32_t first_frame, uint32_t expect_aus, const char *tag)
{
    int ok = demux();
    char msg[160];
    uint32_t bad = 0u;
    (void)snprintf(msg, sizeof(msg), "%s: the transport stream parses", tag);
    check(ok, msg);
    (void)snprintf(msg, sizeof(msg), "%s: %u access units, expected %u", tag, (unsigned)g_au_n, (unsigned)expect_aus);
    check(g_au_n == expect_aus, msg);
    for (uint32_t k = 0u; k < g_au_n && k < expect_aus; k++) {
        host_h264_pic_t r;
        uint8_t e0[4096];
        uint8_t e1[4096];
        const uint8_t *es = &g_es[g_au[k].es_off];
        uint32_t n = g_au[k].es_len;
        uint32_t tail = 0u;
        if (host_model_h264_picture(first_idx + k, &r) != 0) {
            bad++;
            continue;
        }
        host_model_h264_bytes(first_idx + k, 0u, e0);
        host_model_h264_bytes(first_idx + k, 1u, e1);
        /* the stream end of an access unit is padded by adaptation-field stuffing, so n is exact */
        tail = (r.len[0] - 6u) + r.len[1];
        if (n < 6u + tail || memcmp(es, e0, 6u) != 0) {
            bad++;
            continue;
        }
        if (n > 6u + tail) {
            /* parameter sets between the delimiter and the slices (an IDR picture) */
            if (!g_au[k].rai || es[6] != 0u || es[7] != 0u || es[8] != 0u || es[9] != 1u || es[10] != 0x67u) {
                bad++;
                continue;
            }
        } else if (g_au[k].rai && r.idr == 0u && r.forced == 0u) {
            bad++;
            continue;
        }
        if (memcmp(&es[n - tail], &e0[6], r.len[0] - 6u) != 0 || memcmp(&es[n - r.len[1]], e1, r.len[1]) != 0) {
            bad++;
            continue;
        }
        if (g_au[k].pts < 90000u || (g_au[k].pts - 90000u) % 3000u != 0u || (k > 0u && g_au[k].pts <= g_au[k - 1u].pts)) {
            bad++;
            continue;
        }
        (void)first_frame;
    }
    (void)snprintf(msg, sizeof(msg), "%s: every access unit is the model's picture, PTS rising on the 3000 grid (%u bad)", tag, (unsigned)bad);
    check(bad == 0u, msg);
    return ok && bad == 0u;
}

static result_t finish(void)
{
    result_t r;
    memset(&r, 0, sizeof(r));
    r.hash = host_video_udp_hash();
    r.bytes = host_video_udp_bytes();
    r.dgrams = host_video_udp_datagrams();
    venc_get_status(&r.st);
    r.model_pics = host_model_h264_count(HOST_H264_COUNT_PICTURES);
    r.model_starts = host_model_h264_count(HOST_H264_COUNT_STARTS);
    r.illegal = host_model_h264_count(HOST_H264_COUNT_ILLEGAL_IRQ);
    r.delivered = host_irq_delivered();
    return r;
}

/* Scenario kinds of the lockstep runs. */
enum { SC_CQP, SC_CBR, SC_PROFILE, SC_ERROR, SC_SWITCH };

/* One lockstep run: nframes frames, one at a time. */
static result_t lockstep(uint32_t notify, int irq_capable, int scenario, uint32_t nframes, const char *tag)
{
    result_t r;
    char msg[160];
    int seam = (scenario == SC_PROFILE) ? 1 : 0;
    uint32_t frame = BASE_FRAME;
    uint32_t sent_want = 0u;
    int ok = 1;

    setup(irq_capable, seam);
    check(venc_set_notify(notify) == VENC_OK, "venc_set_notify");
    if (scenario == SC_CBR) {
        check(venc_set_bitrate(1500u) == VENC_OK, "set bitrate");
    }
    if (scenario == SC_PROFILE) {
        check(rtlnet_h264_ctl_set_profile(1) == 0, "profile high accepted before the stream");
    }
    check(venc_start(0xC0A80A0Au, 5004u) == VENC_OK, "venc_start");
    for (uint32_t k = 0u; k < nframes; k++) {
        frame++;
        host_model_video_frames(frame);
        if (scenario == SC_PROFILE && k == 12u) {
            check(rtlnet_h264_ctl_set_profile(0) == 0, "profile baseline mid-stream");   /* PROFILE_CHG at the next start, a forced IDR picture */
        }
        if (scenario == SC_PROFILE && k == 20u) {
            check(rtlnet_h264_ctl_set_profile(1) == 0, "profile high again");
        }
        if (scenario == SC_SWITCH && k == 10u) {
            check(venc_set_notify(VENC_NOTIFY_INTERRUPT) == VENC_OK, "switch to interrupt mid-stream");
        }
        if (scenario == SC_SWITCH && k == 20u) {
            check(venc_set_notify(VENC_NOTIFY_POLLED) == VENC_OK, "switch to polled mid-stream");
        }
        if (scenario == SC_SWITCH && k == 28u) {
            check(venc_set_notify(VENC_NOTIFY_INTERRUPT) == VENC_OK, "switch to interrupt again");
        }
        if (scenario == SC_ERROR && k == 15u) {
            /* an error pulse while the picture is coded: the picture is abandoned, the next one reconfigures and is an IDR picture */
            for (int i = 0; i < 3; i++) {
                step();
            }
            host_model_h264_error(2u);
            for (int i = 0; i < 40; i++) {
                step();   /* the model finishes the aborted picture; the firmware reconfigures */
            }
            sent_want = pictures_sent();
            continue;
        }
        sent_want++;
        if (!run_until_sent(sent_want, 4000u)) {
            (void)snprintf(msg, sizeof(msg), "%s: frame %u was sent", tag, (unsigned)k);
            check(0, msg);
            ok = 0;
            break;
        }
    }
    r = finish();
    (void)ok;
    return r;
}

static void same(const result_t *a, const result_t *b, const char *what)
{
    char msg[200];
    (void)snprintf(msg, sizeof(msg), "%s: datagrams byte-identical in both modes (hash %016llx bytes %u / %016llx bytes %u)", what,
                   (unsigned long long)a->hash, (unsigned)a->bytes, (unsigned long long)b->hash, (unsigned)b->bytes);
    check(a->hash == b->hash && a->bytes == b->bytes && a->dgrams == b->dgrams, msg);
    (void)snprintf(msg, sizeof(msg), "%s: the same pictures, bytes, IDR and P counts in both modes", what);
    check(a->st.pictures == b->st.pictures && a->st.es_bytes == b->st.es_bytes && a->st.idr_pictures == b->st.idr_pictures &&
          a->st.p_pictures == b->st.p_pictures && a->st.errors == b->st.errors && a->st.hp_forced_idr == b->st.hp_forced_idr, msg);
}

/* Pipelined run: frames every `cadence` steps, the encoder model completes pictures between register accesses (access_period). */
static result_t pipelined(uint32_t notify, uint32_t nframes, uint32_t cadence, uint32_t access_period, int mode_change, const char *tag)
{
    result_t r;
    char msg[200];
    uint32_t frame = BASE_FRAME;
    uint32_t published = 0u;
    uint32_t steps = 0u;
    uint32_t ac0 = 0u, at0 = 0u, am0 = 0u;

    setup(1, 0);
    host_irq_access_stats(&ac0, &at0, &am0);
    host_model_h264_timing(9u, access_period);
    check(venc_set_notify(notify) == VENC_OK, "venc_set_notify");
    check(venc_start(0xC0A80A0Au, 5004u) == VENC_OK, "venc_start");
    while (steps < 400000u) {
        venc_status_t s;
        if (published < nframes && (steps % cadence) == 0u) {
            frame++;
            published++;
            host_model_video_frames(frame);
            if (mode_change && published == nframes / 2u) {
                rtlnet_reg_write32(RTLNET_PLAT_CSI2_BASE, RTLNET_CSI2_REG_VIDEO_MODE, RTLNET_CSI2_MODE_1080P30);
            }
        }
        venc_poll();
        if (access_period == 0u || (steps & 3u) == 0u) {
            host_model_h264_advance(1u);   /* with access_period the model also runs between the firmware's register accesses */
        }
        steps++;
        if (published >= nframes) {
            venc_get_status(&s);
            if (s.backlog == 0u && host_model_h264_count(HOST_H264_COUNT_BUSY) == 0u && steps > (uint32_t)(nframes * cadence + 200u)) {
                break;
            }
        }
    }
    for (int k = 0; k < 20; k++) {
        venc_poll();
        host_model_h264_advance(1u);
    }
    r = finish();
    if (notify == VENC_NOTIFY_INTERRUPT) {
        uint32_t ac1 = 0u, at1 = 0u, am1 = 0u;
        host_irq_access_stats(&ac1, &at1, &am1);
        printf("  %s: handler register accesses: %u per run on average, %u in the longest run so far (runs that started the next picture included)\n", tag,
               (unsigned)((ac1 > ac0) ? (at1 - at0) / (ac1 - ac0) : 0u), (unsigned)am1);
    }
    printf("  %s: %u frames offered, %u sent, %u dropped (%u for the backlog), backlog max %u, errors %u; handler %u runs (last %u us, max %u us), started by handler %u, main %u, parked %u\n",
           tag, (unsigned)nframes, (unsigned)r.st.pictures, (unsigned)r.st.dropped_pictures, (unsigned)r.st.skipped_backlog, (unsigned)r.st.backlog_max, (unsigned)r.st.errors,
           (unsigned)r.st.isr_n, (unsigned)r.st.isr_last_us, (unsigned)r.st.isr_max_us, (unsigned)r.st.irq_started, (unsigned)r.st.main_started, (unsigned)r.st.irq_parked);
    (void)snprintf(msg, sizeof(msg), "%s: no error (errors %u)", tag, (unsigned)r.st.errors);
    check(r.st.errors == 0u, msg);
    (void)snprintf(msg, sizeof(msg), "%s: every frame is a sent picture or a dropped one (sent %u + dropped %u = %u)", tag, (unsigned)r.st.pictures,
                   (unsigned)r.st.dropped_pictures, (unsigned)(r.st.last_frame - (BASE_FRAME + 1u) + 1u));
    check(r.st.pictures + r.st.dropped_pictures == r.st.last_frame - (BASE_FRAME + 1u) + 1u, msg);
    (void)snprintf(msg, sizeof(msg), "%s: the queue drained (backlog %u), the encoder idle", tag, (unsigned)r.st.backlog);
    check(r.st.backlog == 0u && host_model_h264_count(HOST_H264_COUNT_BUSY) == 0u, msg);
    (void)snprintf(msg, sizeof(msg), "%s: the model coded the pictures that were sent (%u sent, %u coded)", tag, (unsigned)r.st.pictures, (unsigned)r.model_pics);
    check(r.model_pics == r.st.pictures, msg);
    check(r.st.pictures > nframes / 4u, "a useful share of the frames was coded");
    if (notify == VENC_NOTIFY_INTERRUPT) {
        (void)snprintf(msg, sizeof(msg), "%s: handler runs %u, started %u pictures, the main loop %u, parked %u", tag, (unsigned)r.st.isr_n,
                       (unsigned)r.st.irq_started, (unsigned)r.st.main_started, (unsigned)r.st.irq_parked);
        check(r.st.isr_n > 0u && r.st.irq_started > 0u, msg);
        (void)snprintf(msg, sizeof(msg), "%s: every start is accounted (handler %u + main %u = model %u)", tag, (unsigned)r.st.irq_started,
                       (unsigned)r.st.main_started, (unsigned)r.model_starts);
        check(r.st.irq_started + r.st.main_started == r.model_starts, msg);
        (void)snprintf(msg, sizeof(msg), "%s: one picture-done event per picture (%u events, %u coded)", tag, (unsigned)r.st.irq_src[RTLNET_H264_CTL_SRC_PIC_DONE],
                       (unsigned)r.model_pics);
        check(r.st.irq_src[RTLNET_H264_CTL_SRC_PIC_DONE] == r.model_pics, msg);
        check(r.st.notify_mode == VENC_NOTIFY_INTERRUPT, "the interrupt mode is in force");
        check(r.delivered >= r.st.isr_n, "the interrupt controller model delivered the handler calls");
    } else {
        check(r.st.isr_n == 0u && r.st.irqs == 0u && r.st.irq_started == 0u, "polled: no interrupt was taken");
        check(r.st.notify_mode == VENC_NOTIFY_POLLED, "the polled mode is in force");
    }
    check(!mode_change || r.st.mode == RTLNET_H264_CTL_MODE_1080P30, "the mode change reached 1080p30");
    return r;
}

int main(int argc, char **argv)
{
    result_t a;
    result_t b;
    result_t c;
    char msg[200];

    g_neg = (argc > 1 && strcmp(argv[1], "--neg") == 0);

    /* 1. Constant QP, lockstep: both modes, identical datagrams, every access unit the model's picture. */
    a = lockstep(VENC_NOTIFY_POLLED, 1, SC_CQP, 40u, "cqp polled");
    check(a.st.pictures == 40u && a.st.errors == 0u && a.st.irq_src[RTLNET_H264_CTL_SRC_PIC_DONE] == 40u, "cqp polled: 40 pictures, no error");
    check(a.st.notify_mode == VENC_NOTIFY_POLLED && a.st.isr_n == 0u && a.st.irq_started == 0u && a.st.irqs == 0u, "cqp polled: no interrupt");
    check(a.st.idr_pictures == 2u, "cqp polled: IDR at 0 and at 30");
    (void)verify_stream(0u, BASE_FRAME + 1u, 40u, "cqp polled");
    b = lockstep(VENC_NOTIFY_INTERRUPT, 1, SC_CQP, 40u, "cqp interrupt");
    check(b.st.pictures == 40u && b.st.errors == 0u, "cqp interrupt: 40 pictures, no error");
    check(b.st.notify_mode == VENC_NOTIFY_INTERRUPT && b.st.isr_n >= 40u && b.st.irq_src[RTLNET_H264_CTL_SRC_PIC_DONE] == 40u, "cqp interrupt: 40 picture-done interrupts");
    check(b.st.isr_max_us < 50000u, "cqp interrupt: handler time measured and bounded");
    {
        uint32_t calls = 0u, total = 0u, mx = 0u;
        host_irq_access_stats(&calls, &total, &mx);
        printf("  cqp interrupt: handler register accesses over %u runs: average %u, most in one run %u (a picture done that starts the next picture)\n", (unsigned)calls,
               (unsigned)(calls ? total / calls : 0u), (unsigned)mx);
    }
    (void)verify_stream(0u, BASE_FRAME + 1u, 40u, "cqp interrupt");
    same(&a, &b, "constant QP");

    /* 2. Rate control: the controller sees the same sizes in the same order. */
    a = lockstep(VENC_NOTIFY_POLLED, 1, SC_CBR, 40u, "cbr polled");
    b = lockstep(VENC_NOTIFY_INTERRUPT, 1, SC_CBR, 40u, "cbr interrupt");
    same(&a, &b, "rate control");
    check(a.st.qp_used != 0u && a.st.qp_used == b.st.qp_used, "rate control: the same QP written");

    /* 3. A profile change in mid-stream: PROFILE_CHG at the next start, a forced IDR picture, new parameter sets. */
    a = lockstep(VENC_NOTIFY_POLLED, 1, SC_PROFILE, 36u, "profile polled");
    b = lockstep(VENC_NOTIFY_INTERRUPT, 1, SC_PROFILE, 36u, "profile interrupt");
    same(&a, &b, "profile change");
    check(a.st.hp_forced_idr >= 2u && b.st.hp_forced_idr == a.st.hp_forced_idr, "profile change: forced IDR pictures counted, equal in both modes");
    check(b.st.irq_src[RTLNET_H264_CTL_SRC_PROFILE_CHG] == b.st.hp_forced_idr, "profile change: one profile-change interrupt per forced IDR picture");
    (void)verify_stream(0u, BASE_FRAME + 1u, 36u, "profile interrupt");

    /* 4. An encoder error mid-picture: both modes report it, abandon the picture and resume with an IDR picture. */
    a = lockstep(VENC_NOTIFY_POLLED, 1, SC_ERROR, 30u, "error polled");
    b = lockstep(VENC_NOTIFY_INTERRUPT, 1, SC_ERROR, 30u, "error interrupt");
    check(a.st.errors == 1u && b.st.errors == 1u, "error: counted once in both modes");
    check(a.st.last_err_code == 2u && b.st.last_err_code == 2u, "error: the code is reported");
    check(b.st.irq_src[RTLNET_H264_CTL_SRC_ERR] == 1u, "error: one error interrupt");
    same(&a, &b, "error recovery");
    (void)snprintf(msg, sizeof(msg), "error recovery: the stream continues after the error (%u pictures)", (unsigned)b.st.pictures);
    check(b.st.pictures >= 25u, msg);

    /* 5. The mode switches in mid-stream: the stream is the polled one. */
    a = lockstep(VENC_NOTIFY_POLLED, 1, SC_CQP, 40u, "reference");
    c = lockstep(VENC_NOTIFY_POLLED, 1, SC_SWITCH, 40u, "switching");
    same(&a, &c, "runtime mode switch");
    check(c.st.isr_n > 0u && c.st.isr_n < 40u, "runtime mode switch: the handler ran for the interrupt part only");

    /* 6. A core without interrupt registers: the interrupt request degrades to polled without an error, no interrupt register is touched. */
    b = lockstep(VENC_NOTIFY_INTERRUPT, 0, SC_CQP, 40u, "old core");
    check(b.st.notify_wanted == VENC_NOTIFY_INTERRUPT && b.st.notify_mode == VENC_NOTIFY_POLLED && b.st.irq_capable == 0u, "old core: interrupt requested, polled in force");
    check(b.illegal == 0u, "old core: no interrupt register accessed");
    check(b.st.errors == 0u, "old core: no error");
    a = lockstep(VENC_NOTIFY_POLLED, 1, SC_CQP, 40u, "reference");
    same(&a, &b, "older core");

    /* 7. The self-test: the forced event reaches the handler in the interrupt mode, and is refused elsewhere. */
    setup(1, 0);
    check(venc_irq_selftest() == VENC_ERR_ARG, "self-test without a stream is refused");
    check(venc_set_notify(VENC_NOTIFY_INTERRUPT) == VENC_OK && venc_start(0xC0A80A0Au, 5004u) == VENC_OK, "start in interrupt mode");
    check(venc_irq_selftest() == VENC_OK, "self-test: the forced event reached the handler");
    {
        venc_status_t s;
        venc_get_status(&s);
        check(s.irq_src[RTLNET_H264_CTL_SRC_RING_STALL] == 1u && s.isr_n >= 1u, "self-test: counted as one ring stall and one handler run");
        for (int i = 0; i < 3; i++) {
            venc_poll();
        }
        venc_get_status(&s);
        check(s.ring_stall_events == 1u, "ring stall event taken by the main loop once");
    }
    host_model_h264_event(1u << RTLNET_H264_CTL_SRC_RING_STALL);
    host_model_h264_advance(1u);
    {
        venc_status_t s;
        venc_get_status(&s);
        check(s.irq_src[RTLNET_H264_CTL_SRC_RING_STALL] == 2u, "a ring stall from the core is counted");
    }
    venc_stop();
    check(venc_set_notify(VENC_NOTIFY_POLLED) == VENC_OK && venc_start(0xC0A80A0Au, 5004u) == VENC_OK, "start in polled mode");
    check(venc_irq_selftest() == VENC_ERR_ARG, "self-test in polled mode is refused");
    check(host_model_h264_count(HOST_H264_COUNT_IRQ_GLOBAL) == 0u && host_model_h264_count(HOST_H264_COUNT_IRQ_ENABLE) == 0u, "polled: the core's interrupts are disabled");
    venc_stop();
    check(venc_set_notify(7u) == VENC_ERR_ARG, "an unknown mode is refused");
    check(venc_set_notify(VENC_NOTIFY_INTERRUPT) == VENC_OK && venc_start(0xC0A80A0Au, 5004u) == VENC_OK, "interrupt again");
    check(host_model_h264_count(HOST_H264_COUNT_IRQ_GLOBAL) == 1u && host_model_h264_count(HOST_H264_COUNT_IRQ_ENABLE) != 0u, "interrupt: global enable and sources set in the core");
    venc_stop();
    check(host_model_h264_count(HOST_H264_COUNT_IRQ_GLOBAL) == 0u && host_model_h264_count(HOST_H264_COUNT_IRQ_ENABLE) == 0u, "stop: the core's interrupts are disabled");

    /* 8. License loss: counted by the handler, reported to the main loop once; the next picture is a forced IDR picture. */
    setup(1, 1);
    host_model_h264_hp(1u, 1u, RTLNET_H264_CTL_HP_CAP_CABAC, 600u);
    check(rtlnet_h264_ctl_set_profile(1) == 0, "profile high before the stream");
    check(venc_start(0xC0A80A0Au, 5004u) == VENC_OK, "start (license test)");
    for (int k = 0; k < 6; k++) {
        host_model_video_frames(BASE_FRAME + 1u + (uint32_t)k);
        check(run_until_sent((uint32_t)k + 1u, 4000u), "picture before the license ends");
    }
    host_model_h264_hp(1u, 0u, RTLNET_H264_CTL_HP_CAP_CABAC, 0u);   /* the demo time ended */
    host_model_h264_advance(1u);
    for (int i = 0; i < 4; i++) {
        venc_poll();
    }
    {
        venc_status_t s;
        venc_get_status(&s);
        check(s.irq_src[RTLNET_H264_CTL_SRC_LICENSE_LOST] == 1u && s.license_lost_events == 1u, "license lost: one interrupt, taken by the main loop once");
    }
    host_model_video_frames(BASE_FRAME + 7u);
    check(run_until_sent(7u, 4000u), "picture after the license ended");
    {
        venc_status_t s;
        venc_get_status(&s);
        check(s.hp_forced_idr == 1u && s.errors == 0u, "license lost: the next picture is a forced IDR picture");
    }
    venc_stop();

    /* 8b. Deblocking filter: the request defaults to on, changes between pictures are legal without an IDR picture, the offsets are applied at the next
     *     picture, the request is written again by configure_mode at a stream restart, a core without the filter refuses on by name. */
    for (uint32_t notify = 0u; notify < 2u; notify++) {
        venc_status_t s;
        const uint32_t dbk_on = RTLNET_H264_DBK_STATUS_PRESENT | RTLNET_H264_DBK_STATUS_APPLIED;

        setup(1, 0);
        check(venc_set_notify(notify) == VENC_OK, "deblock: venc_set_notify");
        check(rtlnet_venc_deblock_wanted() == 1, "deblock: the request defaults to on");
        check(venc_start(0xC0A80A0Au, 5004u) == VENC_OK, "deblock: start");
        host_model_video_frames(BASE_FRAME + 1u);
        check(run_until_sent(1u, 4000u), "deblock: first picture");
        check(host_model_h264_dbk_status() == dbk_on, "deblock: the first picture was filtered, offsets 0");
        check(rtlnet_venc_set_deblock(0) == 0 && rtlnet_venc_deblock_wanted() == 0, "deblock: off");
        host_model_video_frames(BASE_FRAME + 2u);
        check(run_until_sent(2u, 4000u), "deblock: picture with the filter off");
        check(host_model_h264_dbk_status() == RTLNET_H264_DBK_STATUS_PRESENT, "deblock: the picture after off was not filtered");
        venc_get_status(&s);
        check(s.idr_pictures == 1u && s.hp_forced_idr == 0u && s.errors == 0u, "deblock: off needs no IDR picture and raises no error");
        check(rtlnet_venc_set_deblock_offsets(-2, 3) == 0 && rtlnet_venc_set_deblock(1) == 0, "deblock: offsets -2 and +3, on");
        check(rtlnet_venc_set_deblock_offsets(9, 0) == RTLNET_H264_CTL_DBK_ERR_RANGE, "deblock: offset 9 refused");
        host_model_video_frames(BASE_FRAME + 3u);
        check(run_until_sent(3u, 4000u), "deblock: picture with the filter on again");
        check(host_model_h264_dbk_status() == (dbk_on | (0xEu << RTLNET_H264_DBK_STATUS_ALPHA_SHIFT) | (3u << RTLNET_H264_DBK_STATUS_BETA_SHIFT)),
              "deblock: the picture applied alpha -2 and beta +3");
        venc_get_status(&s);
        check(s.idr_pictures == 1u && s.hp_forced_idr == 0u && s.errors == 0u, "deblock: on again needs no IDR picture and raises no error");
        {
            rtlnet_h264_ctl_dbk_t k;

            check(rtlnet_venc_deblock_info(&k) == 0 && k.present == 1u && k.enable == 1u && k.applied == 1u && k.alpha_applied == -2 && k.beta_applied == 3 &&
                  k.alpha_req == -2 && k.beta_req == 3, "deblock: venc_deblock_info");
        }
        venc_stop();
        host_model_h264_dbk(1);   /* the core is reset: enable 1, offsets 0 */
        check(rtlnet_venc_set_deblock(0) == 0, "deblock: off before the restart");
        check(venc_start(0xC0A80A0Au, 5004u) == VENC_OK, "deblock: restart");
        host_model_video_frames(BASE_FRAME + 1u);
        check(run_until_sent(1u, 4000u), "deblock: first picture after the restart");
        check(host_model_h264_dbk_ctrl() == ((0xEu << RTLNET_H264_DBK_CTRL_ALPHA_SHIFT) | (3u << RTLNET_H264_DBK_CTRL_BETA_SHIFT)) &&
              host_model_h264_dbk_status() == (RTLNET_H264_DBK_STATUS_PRESENT | (0xEu << RTLNET_H264_DBK_STATUS_ALPHA_SHIFT) | (3u << RTLNET_H264_DBK_STATUS_BETA_SHIFT)),
              "deblock: configure_mode wrote the request again (off, offsets -2 and +3) and the first picture used it");
        venc_stop();
        /* A build without the filter. */
        setup(1, 0);
        host_model_h264_dbk(0);
        check(venc_set_notify(notify) == VENC_OK && venc_start(0xC0A80A0Au, 5004u) == VENC_OK, "deblock absent: start");
        check(rtlnet_venc_set_deblock(1) == RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT, "deblock absent: on refused by name");
        check(rtlnet_venc_set_deblock_offsets(1, 1) == RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT, "deblock absent: offsets refused by name");
        host_model_video_frames(BASE_FRAME + 1u);
        check(run_until_sent(1u, 4000u), "deblock absent: pictures are coded");
        venc_get_status(&s);
        check(s.errors == 0u && host_model_h264_dbk_status() == 0u && host_model_h264_dbk_ctrl() == 0u, "deblock absent: no error, the registers read 0");
        venc_stop();
    }

    /* 9. Pipelined, interrupt between any two register accesses; the stream is verified against the model. */
    for (uint32_t notify = 0u; notify < 2u; notify++) {
        const char *nm = (notify == VENC_NOTIFY_INTERRUPT) ? "pipelined interrupt" : "pipelined polled";
        a = pipelined(notify, 150u, 11u, 3u, 0, nm);
        (void)verify_stream(0u, BASE_FRAME + 1u, a.st.pictures, nm);
        a = pipelined(notify, 150u, 5u, 0u, 0, (notify == VENC_NOTIFY_INTERRUPT) ? "overload interrupt" : "overload polled");
        (void)snprintf(msg, sizeof(msg), "overload: frames dropped (%u)", (unsigned)a.st.dropped_pictures);
        check(a.st.dropped_pictures > 0u, msg);
        a = pipelined(notify, 120u, 11u, 3u, 1, (notify == VENC_NOTIFY_INTERRUPT) ? "mode change interrupt" : "mode change polled");
        (void)verify_stream(0u, BASE_FRAME + 1u, a.st.pictures, (notify == VENC_NOTIFY_INTERRUPT) ? "mode change interrupt" : "mode change polled");
        if (notify == VENC_NOTIFY_INTERRUPT) {
            (void)snprintf(msg, sizeof(msg), "mode change in interrupt mode: the handler parked %u starts (1080p slots whose padding lines are not filled yet) for the main loop", (unsigned)a.st.irq_parked);
            check(a.st.irq_parked > 0u, msg);
        }
    }

    if (g_neg) {
        check(0, "negative control (--neg): a forced failure");
    }
    if (g_fails == 0) {
        printf("VENC_IRQ_TEST: PASS (%d checks: both notification modes send identical streams; handler, queue and error paths exercised)\n", g_checks);
        return 0;
    }
    printf("VENC_IRQ_TEST: FAIL (%d of %d checks failed)\n", g_fails, g_checks);
    return 1;
}
