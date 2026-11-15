/*
 * rtlnet_venc.c -- H.264 encoder session and MPEG-TS stream over UDP
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_venc.h. The encoder core is controlled only through the driver layer
 * (cores/rtlnet_h264_enc/driver/rtlnet_h264_enc_ctl.h): this file holds the application glue, that is the frame buffer handshake, the stream
 * state (GOP, frame_num, PTS), the rate controller calls, the picture queue and the transport stream multiplexer hand-off.
 *
 * Execution contexts. Polled mode: everything runs from venc_poll in the main loop. Interrupt mode: the encoder's interrupt handler (venc_isr,
 * INTC input RTLNET_CPU_IRQ_H264) runs the driver's service, which calls on_picture_done / on_picture_error; on picture done the handler does the
 * picture turnaround (release the slot, queue the picture for the multiplexer, rate control) and starts the next picture when a frame is
 * ready (try_begin with from_irq 1). The handler never prints, never sends and never muxes. A start that needs more than a few register
 * accesses (a mode change, the padding lines of a slot) is parked: the slot stays taken (ST_PARKED) and the main loop finishes it.
 * Ownership rule: while a picture is in flight (ST_ENCODING) the encoder-side state (stream state, rate controller, frame buffer handshake,
 * the producer side of the picture queue) belongs to the handler; while the encoder is idle it belongs to the main loop. The main loop enters
 * and leaves ST_ENCODING inside a critical section (plat_irq_save), and every main-loop access to encoder-side state while a picture may be in
 * flight (the console commands, the timeout, venc_stop, the statistics) is a short critical section. See rtlnet_ts_mux.md section 5.3 for the
 * list of shared items and how each is protected.
 *
 * Revision: 11-12-2026 (macroblock-tiled rebuilt picture, 128-byte index records; phase 2c: GOP, P pictures, two rebuilt buffers;
 *   phase 2d: rate control per picture, no IDR picture on a QP change; phase 2f: picture queue and resumable mux apart from the encoder;
 *   interrupt mode: the encoder interrupt does the picture turnaround and starts the next picture; control code moved to the driver)
 */
#include "rtlnet_venc.h"

#include <string.h>   /* memset, memcpy */

#include "rtlnet_board.h"
#include "rtlnet_camera.h"
#include "rtlnet_framebuf.h"
#include "rtlnet_h264_enc_ctl.h"
#include "rtlnet_mmio.h"
#include "rtlnet_muxjob.h"
#include "rtlnet_picq.h"
#include "rtlnet_platform.h"
#include "rtlnet_ratectl.h"
#include "rtlnet_tsmux.h"
#include "rtlnet_vdma_s2mm.h"
#include "rtlnet_video_udp.h"

#ifdef RTLNET_HOST_TEST
uint32_t rtlnet_host_mem_read32(uintptr_t addr);
#endif

/* DDR3 map (byte offsets in DDR3). The rebuilt (reference) picture is macroblock-tiled: macroblock m has 256 bytes of luma at
 * the luma base + 256 * m and 128 bytes of chroma (Cb then Cr) at the chroma base + 128 * m. 1080p (120 x 68 = 8160 macroblocks)
 * needs 2,088,960 bytes of luma and 1,044,480 bytes of chroma (3,133,440 bytes per picture); each area gets 2 MiB. Two
 * pictures (A, B) ping-pong: a picture is written to one and a P picture reads the other, the previous picture, as its reference. */
#define VENC_REC_AREA_BYTES   0x00200000u
#define VENC_RY_BASE      0x11000000u               /* picture A luma tiles */
#define VENC_RU_BASE      0x11200000u               /* picture A chroma tiles */
#define VENC_RY_BASE_B    (VENC_RY_BASE + 2u * VENC_REC_AREA_BYTES)   /* picture B luma tiles */
#define VENC_RU_BASE_B    (VENC_RU_BASE + 2u * VENC_REC_AREA_BYTES)   /* picture B chroma tiles */
#define VENC_RING_BASE    0x12000000u
#define VENC_RING_SIZE    0x00800000u
#define VENC_IDX_BASE     0x13000000u
#define VENC_IDX_ENTRIES  256u             /* 128-byte records: 32 KiB */

#define VENC_PTS_BASE     90000u     /* first PTS: one second */
#define VENC_ENC_TIMEOUT_US  500000u
#define VENC_LOG2_FN      4u
#define VENC_MUX_BUDGET   MUXJOB_BUDGET   /* elementary stream bytes the mux sends per venc_poll call (four datagrams) */
#define VENC_PAD_SLOTS    8u         /* frame-buffer slots whose padding lines are tracked */
#define VENC_NO_PENDING   0xFFFFFFFFu
#define VENC_IRQ_TEST_US  20000u     /* most time venc_irq_selftest waits for the handler */

/* States: ST_PARKED is the encoder idle with a frame taken whose start the handler left for the main loop. */
typedef enum { ST_IDLE = 0, ST_ENCODING, ST_PARKED } venc_state_t;

static struct {
    venc_status_t              st;
    volatile uint32_t          state;             /* venc_state_t; written by the context that owns the encoder */
    tsmux_t                    mux;
    uint32_t                   engines;
    uint32_t                   cfg_mode;          /* mode the core and the SPS describe; 0xFFFFFFFF none */
    rtlnet_framebuf_frame_t    frame;
    int                        holding;
    int                        have_last;
    uint32_t                   first_frame;
    uint32_t                   acct_frame;        /* highest frame number accounted for: encoded, or counted as dropped */
    uint32_t                   pts_step;
    picq_t                     q;                 /* pictures coded and not yet sent, in coding order (producer: encoder side; consumer: main loop) */
    muxjob_t                   job;               /* the oldest queued picture, when job_active */
    int                        job_active;
    uint32_t                   mux_pic_ticks;     /* mux time of the picture being sent */
    uint32_t                   skip_frame;        /* frame number of the last frame skipped for the backlog */
    int                        skip_valid;
    uint32_t                   gop_pos;           /* pictures coded since the last IDR picture (the IDR counts 1) */
    uint32_t                   need_idr;          /* the next picture must be an IDR picture */
    uint32_t                   prev_fn;           /* frame_num of the last started picture */
    uint32_t                   idr_id;            /* idr_pic_id of the next IDR picture (alternates 0, 1) */
    uint32_t                   pic_type;          /* RTLNET_H264_CTL_PIC_IDR or _P of the picture in flight */
    uint32_t                   padded[VENC_PAD_SLOTS];   /* slot bases whose padding lines (below the display height) are filled */
    uint32_t                   padded_n;
    uint32_t                   t_start;           /* plat_ticks at picture start */
    /* notification mode */
    uint32_t                   notify_want;       /* requested mode (VENC_NOTIFY_*) */
    volatile uint32_t          notify_pending;    /* mode to apply at the next idle point, or VENC_NO_PENDING */
    int                        irq_attached;      /* the handler is connected on the INTC */
    volatile int               in_irq;            /* 1 while the handler runs */
    /* handler measurements: written by the handler only, read by the main loop */
    volatile uint32_t          isr_n;
    volatile uint32_t          isr_last_ticks;
    volatile uint32_t          isr_max_ticks;
    volatile uint32_t          irq_started;       /* pictures the handler started */
    volatile uint32_t          irq_parked;        /* starts the handler left for the main loop */
    uint32_t                   main_started;      /* pictures the main loop started */
    uint32_t                   ring_stall_events; /* events the main loop took from the driver */
    uint32_t                   license_lost_events;
    volatile uint32_t          last_err_code;     /* ERR_CODE of the last encoder error */
    /* load accounting: ticks of busy time in the current one-second window */
    uint32_t                   win_start_ms;
    uint32_t                   win_ts_bytes;
    uint32_t                   win_mux_ticks;     /* main loop */
    volatile uint32_t          win_enc_ticks;     /* encoder side (handler or main), cleared by window_update in a critical section */
    /* sequencing measurements (venc_status_t, phase 2f) */
    uint32_t                   cyc_last_begin;    /* plat_ticks at the previous begin_picture */
    int                        cyc_have;
    uint32_t                   cyc_n;             /* pictures started */
    uint32_t                   cyc_cnt;           /* cycle times counted */
    uint32_t                   cyc_min, cyc_max;  /* ticks */
    uint64_t                   cyc_sum;
    int                        lag_have;          /* lag_off holds the smallest (now - time stamp) seen */
    int32_t                    lag_off;
    uint64_t                   lag_sum;
    uint32_t                   lag_max;
    uint32_t                   lag_cnt;
    uint64_t                   mux_chunk_ticks;   /* time in mux (all) */
    uint64_t                   mux_sink_ticks;    /* part of it inside video_udp_send */
    uint64_t                   udp_copy0, udp_send0;   /* video_udp_profile values at the last clear */
    uint32_t                   mux_n;
    uint32_t                   skipped_backlog;
} g;

/* The rate controller and its seconds ring (28,800 bytes of .bss in the LMB, see rtlnet_ratectl.h). Encoder-side state: the handler calls
 * ratectl_picture_done and ratectl_pick; the console commands change it in a critical section. */
static ratectl_t g_rc;

/* mem_copy -- n bytes of DDR3 (byte offset off) into dst, through the data cache with the lines invalidated first. */
static void mem_copy(uint8_t *dst, uint32_t off, uint32_t n)
{
#ifdef RTLNET_HOST_TEST
    for (uint32_t i = 0u; i < n; i++) {
        uint32_t w = rtlnet_host_mem_read32((uintptr_t)(RTLNET_PLAT_DDR_BASE + ((off + i) & ~3u)));
        dst[i] = (uint8_t)(w >> (8u * ((off + i) & 3u)));
    }
#else
    plat_dcache_invalidate_range((uintptr_t)(RTLNET_PLAT_DDR_BASE + off), n);
    memcpy(dst, (const void *)(uintptr_t)(RTLNET_PLAT_DDR_BASE + off), n);
#endif
}

/* ops_read_mem -- driver callback: DDR3 bytes for the index records and the access unit delimiter. */
static int ops_read_mem(void *ctx, uint32_t ddr_off, uint8_t *dst, uint32_t n)
{
    (void)ctx;
    mem_copy(dst, ddr_off, n);
    return 0;
}

static int sink(void *ctx, const uint8_t *d, uint32_t len)
{
    uint32_t t0 = plat_ticks();
    int rc;
    (void)ctx;
    rc = video_udp_send(d, len);
    g.mux_sink_ticks += plat_ticks() - t0;
    return rc;
}

/* mux_map -- muxjob callback: n ring bytes of engine e at offset off of its share, the cache lines invalidated first. */
static const uint8_t *mux_map(void *ctx, uint32_t e, uint32_t off, uint32_t n)
{
    uint32_t share = VENC_RING_SIZE / g.engines;
    uint32_t base = VENC_RING_BASE + e * share + off;
    (void)ctx;
#ifdef RTLNET_HOST_TEST
    {
        static uint8_t chunk[MUXJOB_PIECE];
        mem_copy(chunk, base, n);
        return chunk;
    }
#else
    plat_dcache_invalidate_range((uintptr_t)(RTLNET_PLAT_DDR_BASE + base), n);
    return (const uint8_t *)(uintptr_t)(RTLNET_PLAT_DDR_BASE + base);
#endif
}

static void on_picture_done(void *ctx, const rtlnet_h264_ctl_picture_t *pic);
static void on_picture_error(void *ctx, uint32_t err_code);
static void venc_isr(void *ref);

void venc_init(void)
{
    rtlnet_h264_ctl_layout_t layout;
    rtlnet_h264_ctl_ops_t ops;
    memset(&g, 0, sizeof(g));
    g.st.qp = VENC_QP_DEFAULT;
    g.st.gop = VENC_GOP_DEFAULT;
    g.cfg_mode = 0xFFFFFFFFu;
    g.need_idr = 1u;
    g.notify_want = VENC_NOTIFY_INTERRUPT;
    g.notify_pending = VENC_NO_PENDING;
    picq_init(&g.q);
    memset(&layout, 0, sizeof(layout));
    layout.ring_base = VENC_RING_BASE;
    layout.ring_size = VENC_RING_SIZE;
    layout.idx_base = VENC_IDX_BASE;
    layout.idx_entries = VENC_IDX_ENTRIES;
    layout.ry_base[0] = VENC_RY_BASE;
    layout.ru_base[0] = VENC_RU_BASE;
    layout.ry_base[1] = VENC_RY_BASE_B;
    layout.ru_base[1] = VENC_RU_BASE_B;
    layout.log2_max_frame_num = VENC_LOG2_FN;
    ops.picture_done = on_picture_done;
    ops.picture_error = on_picture_error;
    ops.read_mem = ops_read_mem;
    ops.ctx = NULL;
    rtlnet_h264_ctl_init(RTLNET_PLAT_H264_BASE, &layout, &ops);
    /* The handler is connected here and the INTC input stays masked until a stream starts in interrupt mode. */
    g.irq_attached = (plat_irq_attach(RTLNET_CPU_IRQ_H264, venc_isr, NULL) == 0) ? 1 : 0;
    ratectl_init(&g_rc);
    ratectl_set_cqp(&g_rc, VENC_QP_DEFAULT);
}

/* release_slot -- release the frame-buffer slot when the firmware holds it. */
static void release_slot(void)
{
    if (g.holding) {
        (void)rtlnet_framebuf_fw_release(RTLNET_PLAT_FB_BASE);
        g.holding = 0;
    }
}

/* notify_apply -- put the notification mode in force: the driver programs the core, the INTC input follows. The encoder must be idle. */
static void notify_apply(uint32_t want)
{
    uint32_t eff = (g.irq_attached && (want == VENC_NOTIFY_INTERRUPT)) ? VENC_NOTIFY_INTERRUPT : VENC_NOTIFY_POLLED;
    uint32_t s = plat_irq_save();
    (void)rtlnet_h264_ctl_set_notify(eff);
    plat_irq_enable(RTLNET_CPU_IRQ_H264, (rtlnet_h264_ctl_notify() == RTLNET_H264_NOTIFY_INTERRUPT) ? 1 : 0);
    plat_irq_restore(s);
}

int venc_start(uint32_t ip, uint16_t port)
{
    rtlnet_h264_ctl_info_t info;
    if (g.st.running) {
        return VENC_ERR_BUSY;
    }
    if (!board_ddr_calibrated()) {
        return VENC_ERR_CORE;   /* the CPU runs before the DDR3 calibration completes: no DDR3 traffic until it is done */
    }
    (void)rtlnet_h264_ctl_set_notify((g.irq_attached && (g.notify_want == VENC_NOTIFY_INTERRUPT)) ? RTLNET_H264_NOTIFY_INTERRUPT : RTLNET_H264_NOTIFY_POLLED);
    if (rtlnet_h264_ctl_open(&info) != 0) {
        return VENC_ERR_CORE;
    }
    if (rtlnet_framebuf_probe(RTLNET_PLAT_FB_BASE, NULL) != RTLNET_FB_OK || info.engines == 0u || info.engines > VENC_MAX_ENGINES) {
        rtlnet_h264_ctl_close();   /* the core's interrupts were enabled by open */
        return VENC_ERR_CORE;
    }
    if (video_udp_open(ip, port) != 0) {
        rtlnet_h264_ctl_close();
        return VENC_ERR_UDP;
    }
    g.engines = info.engines;
    tsmux_init(&g.mux, sink, NULL);
    g.cfg_mode = 0xFFFFFFFFu;
    g.have_last = 0;
    g.acct_frame = 0u;
    g.state = ST_IDLE;
    g.need_idr = 1u;
    g.padded_n = 0u;
    g.gop_pos = 0u;
    g.prev_fn = 0u;
    g.idr_id = 0u;
    g.notify_pending = VENC_NO_PENDING;
    picq_flush(&g.q);
    g.job_active = 0;
    g.skip_valid = 0;
    g.cyc_have = 0;
    ratectl_restart(&g_rc);   /* a new stream: the model and the buffer start again (the statistics keep running) */
    g.st.dst_ip = ip;
    g.st.dst_port = port;
    g.win_start_ms = plat_uptime_ms();
    g.win_ts_bytes = 0u;
    g.win_mux_ticks = 0u;
    g.win_enc_ticks = 0u;
    plat_irq_enable(RTLNET_CPU_IRQ_H264, (rtlnet_h264_ctl_notify() == RTLNET_H264_NOTIFY_INTERRUPT) ? 1 : 0);
    g.st.running = 1;
    return VENC_OK;
}

void venc_stop(void)
{
    uint32_t s;
    if (!g.st.running) {
        return;
    }
    /* The core's interrupts first: after this the handler cannot run, and the encoder-side state is the main loop's. */
    s = plat_irq_save();
    plat_irq_enable(RTLNET_CPU_IRQ_H264, 0);
    rtlnet_h264_ctl_close();
    release_slot();
    g.state = ST_IDLE;
    picq_flush(&g.q);   /* the pictures queued are abandoned with the stream; the next start resets the rings */
    g.job_active = 0;
    g.st.running = 0;
    plat_irq_restore(s);
    video_udp_close();
}

int venc_set_qp(uint32_t qp)
{
    uint32_t s;
    if (qp > VENC_QP_MAX) {
        return VENC_ERR_ARG;
    }
    /* H.264 slice QP is per slice: a P picture may use any QP, so a QP change does not force an IDR picture. */
    s = plat_irq_save();
    g.st.qp = qp;
    ratectl_set_cqp(&g_rc, qp);
    plat_irq_restore(s);
    return VENC_OK;
}

int venc_set_bitrate(uint32_t kbps)
{
    uint32_t s = plat_irq_save();
    int rc = ratectl_set_target(&g_rc, kbps);
    plat_irq_restore(s);
    return (rc == 0) ? VENC_OK : VENC_ERR_ARG;
}

int venc_set_buffer_ms(uint32_t ms)
{
    uint32_t s = plat_irq_save();
    int rc = ratectl_set_buffer_ms(&g_rc, ms);
    plat_irq_restore(s);
    return (rc == 0) ? VENC_OK : VENC_ERR_ARG;
}

int venc_set_qp_range(uint32_t qp_min, uint32_t qp_max)
{
    uint32_t s = plat_irq_save();
    int rc = ratectl_set_qp_range(&g_rc, qp_min, qp_max);
    plat_irq_restore(s);
    return (rc == 0) ? VENC_OK : VENC_ERR_ARG;
}

void venc_get_ratectl(ratectl_stats_t *out)
{
    uint32_t s = plat_irq_save();
    ratectl_get_stats(&g_rc, out);
    plat_irq_restore(s);
}

int venc_history(uint32_t age, ratectl_sec_t *out)
{
    uint32_t s = plat_irq_save();
    int rc = ratectl_history(&g_rc, age, out);
    plat_irq_restore(s);
    return rc;
}

int venc_set_gop(uint32_t gop)
{
    if (gop < 1u || gop > VENC_GOP_MAX) {
        return VENC_ERR_ARG;
    }
    g.st.gop = gop;   /* one 32-bit store; the encoder side reads it once per picture */
    return VENC_OK;
}

/*
 * venc_set_notify -- see the header
 * Steps: remember the request; when a stream runs, apply it now if the encoder is idle, otherwise at the next idle point of venc_poll.
 */
int venc_set_notify(uint32_t mode)
{
    uint32_t s;
    if ((mode != VENC_NOTIFY_INTERRUPT) && (mode != VENC_NOTIFY_POLLED)) {
        return VENC_ERR_ARG;
    }
    g.notify_want = mode;
    if (g.st.running) {
        s = plat_irq_save();
        if (g.state == ST_IDLE) {
            notify_apply(mode);
            g.notify_pending = VENC_NO_PENDING;
        } else {
            g.notify_pending = mode;
        }
        plat_irq_restore(s);
    }
    return VENC_OK;
}

/*
 * pad_slot -- fill the lines of a slot below the picture (the coded height is a multiple of 16: 1088 for 1080 lines).
 * The video write DMA writes only the picture's lines, so the lines 1080..1087 hold whatever the DDR3 held before (power-up
 * contents or an earlier frame), and the encoder reads them as the bottom of the last macroblock row. Stale data there changes the
 * picture size (one slot in three coded about 11 kB more in the 215334f run) and makes every P picture across such a slot
 * non-skip in that row. The firmware writes the last picture line into each padding line once per slot and mode (the DMA never
 * touches those lines, and the slot is held by the firmware while this runs).
 */
static void pad_slot(uint32_t base, uint32_t stride, uint32_t lines, uint32_t coded_lines)
{
    uint32_t i;
    for (i = 0u; i < g.padded_n; i++) {
        if (g.padded[i] == base) {
            return;
        }
    }
#ifndef RTLNET_HOST_TEST
    {
        uintptr_t src = (uintptr_t)(RTLNET_PLAT_DDR_BASE + base + (lines - 1u) * stride);
        uintptr_t dst = (uintptr_t)(RTLNET_PLAT_DDR_BASE + base + lines * stride);
        plat_dcache_invalidate_range(src, stride);
        for (uint32_t r = 0u; r < coded_lines - lines; r++) {
            memcpy((void *)(dst + (uintptr_t)r * stride), (const void *)src, stride);
        }
        plat_dcache_flush_range(dst, (coded_lines - lines) * stride);
    }
#else
    (void)stride; (void)lines; (void)coded_lines;   /* the host build keeps the bookkeeping, the model has no padding lines */
#endif
    if (g.padded_n < VENC_PAD_SLOTS) {
        g.padded[g.padded_n++] = base;
    }
}

/* slot_padded -- 1 when the padding lines of the slot at base are filled. */
static int slot_padded(uint32_t base)
{
    for (uint32_t i = 0u; i < g.padded_n; i++) {
        if (g.padded[i] == base) {
            return 1;
        }
    }
    return 0;
}

/*
 * rtlnet_venc_set_deblock -- see the header
 */
int rtlnet_venc_set_deblock(int on)
{
    return rtlnet_h264_ctl_set_deblock(on);
}

/*
 * rtlnet_venc_set_deblock_offsets -- see the header
 */
int rtlnet_venc_set_deblock_offsets(int alpha_div2, int beta_div2)
{
    return rtlnet_h264_ctl_set_deblock_offsets(alpha_div2, beta_div2);
}

/*
 * rtlnet_venc_deblock_wanted -- see the header
 */
int rtlnet_venc_deblock_wanted(void)
{
    return rtlnet_h264_ctl_deblock_wanted();
}

/*
 * rtlnet_venc_deblock_info -- see the header
 */
int rtlnet_venc_deblock_info(rtlnet_h264_ctl_dbk_t *out)
{
    return rtlnet_h264_ctl_deblock_info(out);
}

/*
 * rtlnet_venc_set_transform8x8 -- see the header
 */
int rtlnet_venc_set_transform8x8(int mode)
{
    return rtlnet_h264_ctl_set_transform8x8(mode);
}

/*
 * rtlnet_venc_transform8x8_counts -- see the header
 */
int rtlnet_venc_transform8x8_counts(uint32_t *n8, uint32_t *n4)
{
    return rtlnet_h264_ctl_transform8x8_counts(n8, n4);
}

/*
 * rtlnet_venc_transform8x8_wanted -- see the header
 */
int rtlnet_venc_transform8x8_wanted(void)
{
    return rtlnet_h264_ctl_transform8x8_wanted();
}

/*
 * rtlnet_venc_transform8x8_in_force -- see the header
 */
int rtlnet_venc_transform8x8_in_force(void)
{
    return rtlnet_h264_ctl_transform8x8_in_force();
}

/*
 * configure_mode -- program the core for a video mode through the driver: frame size, the stream parameters, the memory layout, the rings
 * reset. Called when the mode changes (and for the first picture), from the main loop only (the encoder is idle).
 */
static int configure_mode(uint32_t mode)
{
    rtlnet_h264_ctl_mode_t m;
    if (rtlnet_h264_ctl_set_mode(mode, g.st.qp) != 0 || rtlnet_h264_ctl_mode_info(mode, &m) != 0) {
        return -1;
    }
    g.cfg_mode = mode;
    g.padded_n = 0u;   /* the padding lines of the slots are filled again for the new geometry */
    g.need_idr = 1u;   /* a new mode starts a new coded video sequence: the reference of the old mode is unusable */
    g.st.mode = mode;
    g.st.width = m.display_width;
    g.st.height = m.display_height;
    return 0;
}

/* begin_fail -- a start failed after the slot was taken: release it and leave the encoder idle. */
static void begin_fail(void)
{
    release_slot();
    g.state = ST_IDLE;
}

/*
 * begin_picture -- take the latest frame (or resume a parked one) and start the encoder on it.
 * Steps: take the slot; map the frame width to the mode; from the handler, park the frame when the start needs the mode configured or the slot's
 * padding lines filled (the main loop finishes it); otherwise (re)configure on a mode change and pad; pick the picture type and the QP; start the
 * picture through the driver inside a critical section that also moves the state to ST_ENCODING and updates the stream state, so the handler
 * never sees a picture in flight with the old state.
 * Returns: 0 when a picture runs; 1 when the frame was parked; -1 on failure (the slot is released).
 */
static int begin_picture(int from_irq)
{
    rtlnet_framebuf_frame_t f;
    rtlnet_h264_ctl_mode_t m;
    rtlnet_h264_ctl_start_t s;
    uint32_t mode;
    uint32_t stride;
    uint32_t period;
    uint32_t pic_type;
    uint32_t qp;
    uint32_t qp_used = 0u;
    uint32_t irq_s;
    int rc;
    if (g.state == ST_PARKED) {
        f = g.frame;   /* the slot is held since the handler parked the frame */
    } else {
        if (rtlnet_framebuf_fw_take(RTLNET_PLAT_FB_BASE, &f) != RTLNET_FB_OK) {
            g.st.errors++;
            return -1;
        }
        g.holding = 1;
        g.frame = f;
    }
    mode = rtlnet_h264_ctl_mode_of(f.width, f.height);
    if (mode == RTLNET_H264_CTL_MODE_NONE) {
        g.st.errors++;
        begin_fail();
        return -1;
    }
    (void)rtlnet_h264_ctl_mode_info(mode, &m);
    if (from_irq && (mode != g.cfg_mode || (m.height > f.height && f.height > 0u && !slot_padded(f.base)))) {
        g.state = ST_PARKED;   /* a mode change or the padding lines: more than the handler does */
        g.irq_parked++;
        return 1;
    }
    if (mode != g.cfg_mode && configure_mode(mode) != 0) {
        g.st.errors++;
        begin_fail();
        return -1;
    }
    stride = rtlnet_reg_read32(RTLNET_PLAT_S2MM_BASE, RTLNET_S2MM_REG_STRIDE);
    if (stride == 0u) {
        stride = m.width * 2u;
    }
    if (m.height > f.height && f.height > 0u) {
        pad_slot(f.base, stride, f.height, m.height);
    }
    period = rtlnet_camera_pts_step(RTLNET_PLAT_CSI2_BASE);
    g.pts_step = period; /* ZCAM reports 90 kHz ticks per admitted frame. */
    if (g.pts_step == 0u) {
        g.pts_step = 3000u;
    }
    if (!g.have_last) {
        g.first_frame = f.frame;
    } else {
        /* A gap is counted once: acct_frame remembers what was counted, so a configure or start failure below does not count it again. */
        uint32_t base = (g.acct_frame > g.st.last_frame) ? g.acct_frame : g.st.last_frame;
        if (f.frame > base + 1u) {
            g.st.dropped_pictures += f.frame - base - 1u;
            g.acct_frame = f.frame - 1u;
            g.need_idr = 1u;   /* a dropped picture: restart the GOP with an IDR picture */
        }
    }
    /* IDR when forced, when the GOP is complete (gop 1: every picture), or when no reference picture exists; P otherwise. */
    if (g.need_idr || g.gop_pos >= g.st.gop || rtlnet_h264_ctl_has_reference() == 0) {
        pic_type = RTLNET_H264_CTL_PIC_IDR;
    } else {
        pic_type = RTLNET_H264_CTL_PIC_P;
    }
    ratectl_set_stream(&g_rc, m.width * m.height, g.pts_step);
    qp = ratectl_pick(&g_rc, pic_type == RTLNET_H264_CTL_PIC_IDR, g.st.gop);   /* constant QP mode returns the configured QP */
    s.in_base = f.base;
    s.in_stride = stride;
    s.qp = qp;
    s.pic_type = pic_type;
    s.frame_num = (pic_type == RTLNET_H264_CTL_PIC_IDR) ? 0u : rtlnet_h264_ctl_next_frame_num(g.prev_fn);
    s.idr_pic_id = g.idr_id;
    irq_s = plat_irq_save();
    g.state = ST_ENCODING;
    g.t_start = plat_ticks();
    rc = rtlnet_h264_ctl_start_picture(&s, &qp_used);
    if (rc == 0) {
        g.pic_type = pic_type;
        if (pic_type == RTLNET_H264_CTL_PIC_IDR) {
            g.prev_fn = 0u;
            g.idr_id ^= 1u;       /* consecutive IDR pictures differ (clause 7.4.3) */
            g.need_idr = 0u;
            g.gop_pos = 1u;
        } else {
            g.prev_fn = s.frame_num;
            g.gop_pos++;
        }
    } else {
        g.state = ST_IDLE;
    }
    plat_irq_restore(irq_s);
    if (rc != -1) {
        g.st.qp_used = qp_used;
    }
    if (rc != 0) {
        g.st.errors++;
        if (rc == -2) {
            g.need_idr = 1u;
        }
        release_slot();
        return -1;
    }
    if (from_irq) {
        g.irq_started++;
    } else {
        g.main_started++;
    }
    g.cyc_n++;
    if (g.cyc_have) {
        uint32_t d = g.t_start - g.cyc_last_begin;
        g.cyc_sum += d;
        g.cyc_cnt++;
        if (g.cyc_cnt == 1u || d < g.cyc_min) {
            g.cyc_min = d;
        }
        if (d > g.cyc_max) {
            g.cyc_max = d;
        }
    }
    g.cyc_last_begin = g.t_start;
    g.cyc_have = 1;
    {
        /* ZCAM stamps microseconds; plat_ticks uses microseconds from the PS timer. The minimum observed difference is the origin offset. */
        int32_t d = (int32_t)(g.t_start - g.frame.timestamp);
        uint32_t lag;
        if (!g.lag_have || d < g.lag_off) {
            g.lag_off = d;
            g.lag_have = 1;
        }
        lag = (uint32_t)(d - g.lag_off);
        g.lag_sum += lag;
        g.lag_cnt++;
        if (lag > g.lag_max) {
            g.lag_max = lag;
        }
    }
    return 0;
}

/*
 * queue_picture -- on DONE: queue the picture for the multiplexer.
 * Steps: fill the descriptor from the driver's result (frame, type, QP, PTS, ring offsets and lengths, the ring and index positions that are free
 * once the picture is sent, the delimiter, the SPS and PPS of an IDR picture); push the descriptor; rate control sees the size now (the sizes are
 * known at DONE, so the controller runs in coding order whatever the multiplexer is doing).
 * Returns 0, or -1 when the result is not valid or the queue refuses (the rings are then reset at the next picture, after the queue is drained).
 */
static int queue_picture(const rtlnet_h264_ctl_picture_t *pic)
{
    picq_desc_t d;
    const uint8_t *ps = NULL;
    uint32_t ps_len = 0u;
    uint32_t total = 0u;
    if (!pic->valid) {
        return -1;
    }
    memset(&d, 0, sizeof(d));
    d.engines = pic->engines;
    d.frame = g.frame.frame;
    d.pic_type = g.pic_type;
    d.qp = pic->qp;
    d.pts = (uint64_t)VENC_PTS_BASE + (uint64_t)(g.frame.frame - g.first_frame) * g.pts_step;
    memcpy(d.aud, pic->aud, PICQ_AUD_BYTES);
    for (uint32_t e = 0u; e < pic->engines; e++) {
        d.off[e] = pic->off[e];
        d.len[e] = pic->len[e];
        d.ring_end[e] = pic->ring_end[e];
        d.idx_end[e] = pic->idx_end[e];
        total += d.len[e];
    }
    if (g.pic_type == RTLNET_H264_CTL_PIC_IDR) {
        rtlnet_h264_ctl_params(&ps, &ps_len);
        if (ps_len > PICQ_PS_BYTES) {
            return -1;
        }
        d.sps_len = ps_len;
        memcpy(d.sps_pps, ps, ps_len);
        total += ps_len;
    }
    d.es_bytes = total;
    d.t_done = plat_ticks();
    if (picq_push(&g.q, &d) != PICQ_OK) {
        return -1;
    }
    /* Rate control: the coded size (the entry lengths of every engine, plus the SPS and PPS of an IDR picture), the QP written and
     * the stream time since the previous picture (more than one period after a dropped picture). */
    ratectl_picture_done(&g_rc, g.pic_type == RTLNET_H264_CTL_PIC_IDR, g.st.qp_used, total * 8u,
                         g.have_last ? (g.frame.frame - g.st.last_frame) * g.pts_step : g.pts_step);
    g.st.last_frame = g.frame.frame;
    g.have_last = 1;
    if (picq_count(&g.q) > g.st.backlog_max) {
        g.st.backlog_max = picq_count(&g.q);
    }
    return 0;
}

/*
 * try_begin -- encoder idle: start the next picture when a new frame is ready.
 * A frame already coded or already skipped is not taken again. When the rings are to be reset (a mode change, or an error left
 * cfg_mode invalid) the queue is drained first: the pictures in it point into the rings. When the queue holds PICQ_LIMIT pictures the
 * frame is skipped: counted as a dropped picture and as a backlog skip, the next picture is an IDR picture, the slot is not taken (so
 * the encoder cannot stall on a full ring). from_irq 1: called by the handler, which parks what it cannot finish quickly (begin_picture).
 */
static void try_begin(int from_irq)
{
    uint32_t t0;
    uint32_t latest;
    uint32_t mode;
    uint32_t wh;
    if ((rtlnet_reg_read32(RTLNET_PLAT_FB_BASE, RTLNET_FB_REG_STATUS) & RTLNET_FB_STATUS_LATEST_VALID) == 0u) {
        return;
    }
    latest = rtlnet_reg_read32(RTLNET_PLAT_FB_BASE, RTLNET_FB_REG_LATEST_FRAME);
    if ((g.have_last && latest == g.st.last_frame) || (g.skip_valid && latest == g.skip_frame)) {
        return;
    }
    wh = rtlnet_reg_read32(RTLNET_PLAT_FB_BASE, RTLNET_FB_REG_LATEST_WH);
    mode = rtlnet_h264_ctl_mode_of(wh & 0xFFFFu, wh >> 16);
    if (picq_count(&g.q) != 0u && (g.cfg_mode == 0xFFFFFFFFu || (mode != RTLNET_H264_CTL_MODE_NONE && mode != g.cfg_mode))) {
        return;   /* the mux drains the queue, then the rings are reset */
    }
    if (!picq_admit(&g.q, PICQ_LIMIT)) {
        uint32_t base = (g.acct_frame > g.st.last_frame) ? g.acct_frame : g.st.last_frame;
        if (g.have_last && latest > base + 1u) {
            g.st.dropped_pictures += latest - base - 1u;   /* frames lost before this one (the gap is counted once) */
        }
        g.st.dropped_pictures++;
        g.skipped_backlog++;
        g.acct_frame = latest;
        g.skip_frame = latest;
        g.skip_valid = 1;
        g.need_idr = 1u;
        return;
    }
    t0 = plat_ticks();
    (void)begin_picture(from_irq);   /* state: ST_ENCODING on a start, ST_PARKED when parked, ST_IDLE otherwise */
    g.win_enc_ticks += plat_ticks() - t0;
}

/*
 * on_picture_done -- driver callback: a picture completed (the handler in interrupt mode, venc_poll in polled mode).
 * Steps: release the frame-buffer slot; account for a forced IDR picture (license or profile change: restart the GOP at it; the driver has
 * rewritten the stream parameters); queue the picture; leave the encoder idle; in the handler, start the next picture at once.
 * Short and bounded: no console, no UDP, no mux.
 */
static void on_picture_done(void *ctx, const rtlnet_h264_ctl_picture_t *pic)
{
    uint32_t t0 = plat_ticks();
    (void)ctx;
    if (g.state != ST_ENCODING) {
        return;   /* a completion nobody waits for (a picture abandoned by venc_stop) */
    }
    release_slot();
    if (pic->forced_idr != 0u) {
        g.st.hp_forced_idr++;
        if (g.pic_type != RTLNET_H264_CTL_PIC_IDR) {
            g.pic_type = RTLNET_H264_CTL_PIC_IDR;
            g.prev_fn = 0u;
            g.gop_pos = 1u;
            g.need_idr = 0u;
            g.idr_id ^= 1u;       /* the next IDR picture differs from the forced one (clause 7.4.3) */
        }
    }
    if (queue_picture(pic) != 0) {
        g.st.errors++;
        g.cfg_mode = 0xFFFFFFFFu;
    }
    g.state = ST_IDLE;
    g.win_enc_ticks += plat_ticks() - t0;
    if (g.in_irq) {
        try_begin(1);
    }
}

/*
 * on_picture_error -- driver callback: the core reported an error (ERR_CODE read, the flags cleared).
 * Steps: release the slot; count; the next picture reconfigures the core and resets the rings (configure_mode forces an IDR picture). The main
 * loop starts that picture (the handler does not: the mode is invalid).
 */
static void on_picture_error(void *ctx, uint32_t err_code)
{
    (void)ctx;
    g.last_err_code = err_code;
    if (g.state != ST_ENCODING) {
        return;
    }
    release_slot();
    g.st.errors++;
    g.cfg_mode = 0xFFFFFFFFu;   /* reconfigure and reset the rings at the next picture (configure_mode forces an IDR) */
    g.need_idr = 1u;
    g.state = ST_IDLE;
}

/*
 * venc_isr -- INTC handler of the encoder interrupt.
 * Steps: run the driver's service (acknowledge, count, picture turnaround through the callbacks above); measure its duration.
 */
static void venc_isr(void *ref)
{
    uint32_t t0 = plat_ticks();
    uint32_t dt;
    (void)ref;
    g.in_irq = 1;
    rtlnet_h264_ctl_irq_service();
    g.in_irq = 0;
    dt = plat_ticks() - t0;
    g.isr_n++;
    g.isr_last_ticks = dt;
    if (dt > g.isr_max_ticks) {
        g.isr_max_ticks = dt;
    }
}

/* window_update -- once per second: bit rate and load figures from the accumulated byte count and busy ticks. */
static void window_update(void)
{
    uint32_t now = plat_uptime_ms();
    uint32_t span = now - g.win_start_ms;
    if (span >= 1000u) {
        uint64_t ticks = (uint64_t)span * (RTLNET_PLAT_TICKS_PER_US * 1000u);
        uint32_t ts_now = g.mux.bytes;
        uint32_t enc_ticks;
        uint32_t s = plat_irq_save();
        enc_ticks = g.win_enc_ticks;
        g.win_enc_ticks = 0u;
        plat_irq_restore(s);
        g.st.bit_rate_bps = (uint32_t)(((uint64_t)(ts_now - g.win_ts_bytes) * 8u * 1000u) / span);
        g.st.mux_load_permille = (uint32_t)(((uint64_t)g.win_mux_ticks * 1000u) / ticks);
        g.st.venc_load_permille = (uint32_t)(((uint64_t)(enc_ticks + g.win_mux_ticks) * 1000u) / ticks);
        g.win_ts_bytes = ts_now;
        g.win_mux_ticks = 0u;
        g.win_start_ms = now;
    }
}

/* mux_finish -- the picture the job sent is complete: free its ring and index space, account for it, remove it from the queue. */
static void mux_finish(void)
{
    const picq_desc_t *d = picq_front(&g.q);
    if (d == NULL) {
        return;
    }
    for (uint32_t e = 0u; e < d->engines; e++) {
        rtlnet_h264_ctl_release(e, d->ring_end[e], d->idx_end[e]);
    }
    g.st.last_mux_us = g.mux_pic_ticks / RTLNET_PLAT_TICKS_PER_US;
    if (g.st.last_mux_us > g.st.max_mux_us) {
        g.st.max_mux_us = g.st.last_mux_us;
    }
    if (d->pic_type == RTLNET_H264_CTL_PIC_IDR) {
        g.st.idr_pictures++;
        g.st.idr_bytes += d->es_bytes;
        g.st.last_idr = 1u;
    } else {
        g.st.p_pictures++;
        g.st.p_bytes += d->es_bytes;
        g.st.last_idr = 0u;
    }
    g.st.pictures++;
    g.st.es_bytes += d->es_bytes;
    g.st.last_picture_bytes = d->es_bytes;
    g.mux_n++;
    (void)picq_pop(&g.q);
    g.job_active = 0;
}

/*
 * mux_service -- send one chunk (VENC_MUX_BUDGET elementary stream bytes, about four datagrams) of the oldest queued picture.
 * venc_poll checks the frame and DONE state before every chunk, so the encoder never waits for the multiplexer.
 */
static void mux_service(void)
{
    uint32_t t0;
    uint32_t dt;
    int done;
    if (!g.job_active) {
        const picq_desc_t *d = picq_front(&g.q);
        if (d == NULL) {
            return;
        }
        muxjob_start(&g.job, d, mux_map, NULL, VENC_RING_SIZE / g.engines);
        g.job_active = 1;
        g.mux_pic_ticks = 0u;
    }
    g.mux_sink_ticks = 0u;
    t0 = plat_ticks();
    done = muxjob_step(&g.job, &g.mux, VENC_MUX_BUDGET);
    dt = plat_ticks() - t0;
    g.mux_chunk_ticks += (dt - (uint32_t)g.mux_sink_ticks);   /* ring read and TS build: the time outside the sink */
    g.mux_pic_ticks += dt;
    g.win_mux_ticks += dt;
    if (done) {
        mux_finish();
    }
}

/* encoder_timeout -- a picture has not completed within VENC_ENC_TIMEOUT_US: abandon it. A critical section: the handler may complete it just now. */
static void encoder_timeout(void)
{
    uint32_t s = plat_irq_save();
    if ((g.state == ST_ENCODING) && ((plat_ticks() - g.t_start) > VENC_ENC_TIMEOUT_US * RTLNET_PLAT_TICKS_PER_US)) {
        release_slot();
        g.st.errors++;
        g.cfg_mode = 0xFFFFFFFFu;
        g.need_idr = 1u;
        g.state = ST_IDLE;
    }
    plat_irq_restore(s);
}

void venc_poll(void)
{
    if (!g.st.running) {
        return;
    }
    window_update();
    {
        uint32_t ev = rtlnet_h264_ctl_take_events();   /* events the handler captured for the main loop */
        if ((ev & (1u << RTLNET_H264_CTL_SRC_RING_STALL)) != 0u) {
            g.ring_stall_events++;
        }
        if ((ev & (1u << RTLNET_H264_CTL_SRC_LICENSE_LOST)) != 0u) {
            g.license_lost_events++;
        }
    }
    if (g.notify_pending != VENC_NO_PENDING && g.state == ST_IDLE) {
        uint32_t s = plat_irq_save();
        if (g.state == ST_IDLE) {
            notify_apply(g.notify_pending);
            g.notify_pending = VENC_NO_PENDING;
        }
        plat_irq_restore(s);
    }
    if (g.state == ST_ENCODING) {
        if (rtlnet_h264_ctl_notify() == RTLNET_H264_NOTIFY_POLLED) {
            if (rtlnet_h264_ctl_poll() != 1) {
                encoder_timeout();   /* nothing completed; a picture past its time is abandoned */
            }
        } else {
            encoder_timeout();       /* the handler completes pictures; only a lost interrupt reaches the timeout */
        }
    }
    if (g.state == ST_PARKED) {
        uint32_t t0 = plat_ticks();
        (void)begin_picture(0);
        g.win_enc_ticks += plat_ticks() - t0;
    } else if (g.state == ST_IDLE) {
        try_begin(0);
    }
    mux_service();
}

/*
 * venc_irq_selftest -- see the header
 */
int venc_irq_selftest(void)
{
    rtlnet_h264_ctl_irq_stats_t a;
    rtlnet_h264_ctl_irq_stats_t b;
    uint32_t t0;
    if (!g.st.running || rtlnet_h264_ctl_notify() != RTLNET_H264_NOTIFY_INTERRUPT) {
        return VENC_ERR_ARG;
    }
    rtlnet_h264_ctl_irq_stats(&a);
    if (rtlnet_h264_ctl_irq_force(1u << RTLNET_H264_CTL_SRC_RING_STALL) != 0) {
        return VENC_ERR_CORE;
    }
    t0 = plat_ticks();
    do {
        rtlnet_h264_ctl_irq_stats(&b);
        if (b.source[RTLNET_H264_CTL_SRC_RING_STALL] != a.source[RTLNET_H264_CTL_SRC_RING_STALL]) {
            return VENC_OK;
        }
    } while ((plat_ticks() - t0) < VENC_IRQ_TEST_US * RTLNET_PLAT_TICKS_PER_US);
    return VENC_ERR_CORE;   /* forced, no interrupt arrived */
}

void venc_get_status(venc_status_t *out)
{
    rtlnet_framebuf_state_t fs;
    rtlnet_h264_ctl_irq_stats_t is;
    uint32_t s = plat_irq_save();
    *out = g.st;
    if (rtlnet_framebuf_read_state(RTLNET_PLAT_FB_BASE, &fs) == RTLNET_FB_OK) {
        out->fb_dropped = fs.dropped;
        out->fb_published = fs.published;
    }
    {
        uint32_t tpu = RTLNET_PLAT_TICKS_PER_US;
        out->cyc_n = g.cyc_n;
        out->cyc_min_us = g.cyc_min / tpu;
        out->cyc_avg_us = (g.cyc_cnt != 0u) ? (uint32_t)(g.cyc_sum / g.cyc_cnt / tpu) : 0u;
        out->cyc_max_us = g.cyc_max / tpu;
        out->lag_avg_us = (g.lag_cnt != 0u) ? (uint32_t)(g.lag_sum / g.lag_cnt / tpu) : 0u;
        out->lag_max_us = g.lag_max / tpu;
        out->backlog = picq_count(&g.q);
        out->backlog_max = g.st.backlog_max;
        out->skipped_backlog = g.skipped_backlog;
        out->backlog_limit = PICQ_LIMIT;
        out->isr_n = g.isr_n;
        out->isr_last_us = g.isr_last_ticks / tpu;
        out->isr_max_us = g.isr_max_ticks / tpu;
        out->irq_started = g.irq_started;
        out->irq_parked = g.irq_parked;
        out->main_started = g.main_started;
    }
    plat_irq_restore(s);
    out->ts_bytes = g.mux.bytes;
    out->ts_packets = g.mux.packets;
    out->datagrams = g.mux.datagrams;
    out->sink_errors = g.mux.sink_errors;
    {
        uint64_t copy_t;
        uint64_t send_t;
        uint32_t tpu = RTLNET_PLAT_TICKS_PER_US;
        video_udp_profile(&copy_t, &send_t);
        copy_t -= g.udp_copy0;
        send_t -= g.udp_send0;
        out->mux_n = g.mux_n;
        out->mux_ring_ts_us = (g.mux_n != 0u) ? (uint32_t)(g.mux_chunk_ticks / g.mux_n / tpu) : 0u;
        out->mux_copy_us = (g.mux_n != 0u) ? (uint32_t)(copy_t / g.mux_n / tpu) : 0u;
        out->mux_send_us = (g.mux_n != 0u) ? (uint32_t)(send_t / g.mux_n / tpu) : 0u;
    }
    rtlnet_h264_ctl_irq_stats(&is);
    out->notify_wanted = g.notify_want;
    out->notify_mode = g.st.running ? is.notify : g.notify_want;
    out->irq_capable = (uint32_t)rtlnet_h264_ctl_irq_capable();
    out->irq_attached = (uint32_t)g.irq_attached;
    out->irqs = is.irqs;
    out->irq_spurious = is.spurious;
    for (uint32_t i = 0u; i < RTLNET_H264_CTL_SRC_COUNT; i++) {
        out->irq_src[i] = is.source[i];
    }
    out->ring_stall_events = g.ring_stall_events;
    out->license_lost_events = g.license_lost_events;
    out->last_err_code = g.last_err_code;
}

void venc_clear_counters(void)
{
    uint32_t s = plat_irq_save();
    g.st.pictures = 0u;
    g.st.es_bytes = 0u;
    g.st.dropped_pictures = 0u;
    g.st.idr_pictures = 0u;
    g.st.hp_forced_idr = 0u;
    g.st.p_pictures = 0u;
    g.st.idr_bytes = 0u;
    g.st.p_bytes = 0u;
    g.st.errors = 0u;
    g.st.max_mux_us = 0u;
    tsmux_clear_counters(&g.mux);
    g.win_ts_bytes = 0u;
    ratectl_clear_stats(&g_rc);
    g.cyc_have = 0;
    g.cyc_n = 0u;
    g.cyc_cnt = 0u;
    g.cyc_min = 0u;
    g.cyc_max = 0u;
    g.cyc_sum = 0u;
    g.lag_sum = 0u;
    g.lag_cnt = 0u;
    g.lag_max = 0u;
    g.mux_chunk_ticks = 0u;
    g.mux_n = 0u;
    g.st.backlog_max = picq_count(&g.q);
    g.skipped_backlog = 0u;
    g.isr_n = 0u;
    g.isr_last_ticks = 0u;
    g.isr_max_ticks = 0u;
    g.irq_started = 0u;
    g.irq_parked = 0u;
    g.main_started = 0u;
    g.ring_stall_events = 0u;
    g.license_lost_events = 0u;
    rtlnet_h264_ctl_irq_stats_clear();
    video_udp_profile(&g.udp_copy0, &g.udp_send0);
    plat_irq_restore(s);
}
