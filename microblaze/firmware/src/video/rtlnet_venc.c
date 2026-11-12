/*
 * rtlnet_venc.c -- H.264 encoder session and MPEG-TS stream over UDP
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_venc.h.
 *
 * Revision: 11-11-2026 (macroblock-tiled rebuilt picture, 128-byte index records; phase 2c: GOP, P pictures, two rebuilt buffers;
 *   phase 2d: rate control per picture, no IDR picture on a QP change; phase 2f: picture queue and resumable mux apart from the encoder)
 */
#include "rtlnet_venc.h"

#include <string.h>   /* memset, memcpy */

#include "rtlnet_board.h"
#include "rtlnet_csi2_rx.h"
#include "rtlnet_framebuf.h"
#include "rtlnet_h264_enc.h"
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

typedef enum { ST_IDLE = 0, ST_ENCODING } venc_state_t;

static struct {
    venc_status_t              st;
    venc_state_t               state;
    tsmux_t                    mux;
    uint32_t                   engines;
    uint32_t                   cfg_mode;          /* mode the core and the SPS describe; 0xFFFFFFFF none */
    rtlnet_h264_enc_sps_cfg_t  sps_cfg;
    uint8_t                    sps_pps[RTLNET_H264_SPS_PPS_MAX_BYTES];
    size_t                     sps_len;
    rtlnet_framebuf_frame_t    frame;
    int                        holding;
    int                        have_last;
    uint32_t                   first_frame;
    uint32_t                   acct_frame;        /* highest frame number accounted for: encoded, or counted as dropped */
    uint32_t                   pts_step;
    uint32_t                   scan_idx[VENC_MAX_ENGINES];   /* index ring position where the next picture's entries are looked for */
    picq_t                     q;                 /* pictures coded and not yet sent, in coding order */
    muxjob_t                   job;               /* the oldest queued picture, when job_active */
    int                        job_active;
    uint32_t                   mux_pic_ticks;     /* mux time of the picture being sent */
    uint32_t                   skip_frame;        /* frame number of the last frame skipped for the backlog */
    int                        skip_valid;
    uint32_t                   pic_seq;
    rtlnet_h264_enc_buffers_t  bufs;              /* the two rebuilt buffers: cur is written, the other is the reference */
    uint32_t                   gop_pos;           /* pictures coded since the last IDR picture (the IDR counts 1) */
    uint32_t                   need_idr;          /* the next picture must be an IDR picture */
    uint32_t                   prev_fn;           /* frame_num of the last started picture */
    uint32_t                   idr_id;            /* idr_pic_id of the next IDR picture (alternates 0, 1) */
    uint32_t                   pic_type;          /* RTLNET_H264_PIC_IDR or _P of the picture in flight */
    uint32_t                   padded[VENC_PAD_SLOTS];   /* slot bases whose padding lines (below the display height) are filled */
    uint32_t                   padded_n;
    uint32_t                   t_start;           /* plat_ticks at picture start */
    /* load accounting: ticks of busy time in the current one-second window */
    uint32_t                   win_start_ms;
    uint32_t                   win_ts_bytes;
    uint32_t                   win_mux_ticks;
    uint32_t                   win_busy_ticks;
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

/* The rate controller and its seconds ring (28,800 bytes of .bss in the LMB, see rtlnet_ratectl.h). */
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

void venc_init(void)
{
    memset(&g, 0, sizeof(g));
    g.st.qp = VENC_QP_DEFAULT;
    g.st.gop = VENC_GOP_DEFAULT;
    g.cfg_mode = 0xFFFFFFFFu;
    g.need_idr = 1u;
    picq_init(&g.q);
    (void)rtlnet_h264_enc_buffers_init(&g.bufs, VENC_RY_BASE, VENC_RU_BASE, VENC_RY_BASE_B, VENC_RU_BASE_B);
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

int venc_start(uint32_t ip, uint16_t port)
{
    rtlnet_h264_enc_caps_t caps;
    if (g.st.running) {
        return VENC_ERR_BUSY;
    }
    if (!board_ddr_calibrated()) {
        return VENC_ERR_CORE;   /* the CPU runs before the DDR3 calibration completes: no DDR3 traffic until it is done */
    }
    if (rtlnet_h264_enc_probe(RTLNET_PLAT_H264_BASE, &caps) != 0 || rtlnet_framebuf_probe(RTLNET_PLAT_FB_BASE, NULL) != RTLNET_FB_OK ||
        caps.num_engines == 0u || caps.num_engines > VENC_MAX_ENGINES) {
        return VENC_ERR_CORE;
    }
    if (video_udp_open(ip, port) != 0) {
        return VENC_ERR_UDP;
    }
    g.engines = caps.num_engines;
    tsmux_init(&g.mux, sink, NULL);
    g.cfg_mode = 0xFFFFFFFFu;
    g.have_last = 0;
    g.acct_frame = 0u;
    g.state = ST_IDLE;
    g.pic_seq = 0u;
    g.need_idr = 1u;
    g.padded_n = 0u;
    g.gop_pos = 0u;
    g.prev_fn = 0u;
    g.idr_id = 0u;
    picq_flush(&g.q);
    g.job_active = 0;
    g.skip_valid = 0;
    g.cyc_have = 0;
    (void)rtlnet_h264_enc_buffers_init(&g.bufs, VENC_RY_BASE, VENC_RU_BASE, VENC_RY_BASE_B, VENC_RU_BASE_B);
    ratectl_restart(&g_rc);   /* a new stream: the model and the buffer start again (the statistics keep running) */
    g.st.dst_ip = ip;
    g.st.dst_port = port;
    g.win_start_ms = plat_uptime_ms();
    g.win_ts_bytes = 0u;
    g.win_mux_ticks = 0u;
    g.win_busy_ticks = 0u;
    g.st.running = 1;
    return VENC_OK;
}

void venc_stop(void)
{
    if (!g.st.running) {
        return;
    }
    release_slot();
    g.state = ST_IDLE;
    picq_flush(&g.q);   /* the pictures queued are abandoned with the stream; the next start resets the rings */
    g.job_active = 0;
    g.st.running = 0;
    video_udp_close();
}

int venc_set_qp(uint32_t qp)
{
    if (qp > VENC_QP_MAX) {
        return VENC_ERR_ARG;
    }
    /* H.264 slice QP is per slice: a P picture may use any QP, so a QP change does not force an IDR picture. */
    g.st.qp = qp;
    ratectl_set_cqp(&g_rc, qp);
    return VENC_OK;
}

int venc_set_bitrate(uint32_t kbps)
{
    return (ratectl_set_target(&g_rc, kbps) == 0) ? VENC_OK : VENC_ERR_ARG;
}

int venc_set_buffer_ms(uint32_t ms)
{
    return (ratectl_set_buffer_ms(&g_rc, ms) == 0) ? VENC_OK : VENC_ERR_ARG;
}

int venc_set_qp_range(uint32_t qp_min, uint32_t qp_max)
{
    return (ratectl_set_qp_range(&g_rc, qp_min, qp_max) == 0) ? VENC_OK : VENC_ERR_ARG;
}

void venc_get_ratectl(ratectl_stats_t *out)
{
    ratectl_get_stats(&g_rc, out);
}

int venc_history(uint32_t age, ratectl_sec_t *out)
{
    return ratectl_history(&g_rc, age, out);
}

int venc_set_gop(uint32_t gop)
{
    if (gop < 1u || gop > VENC_GOP_MAX) {
        return VENC_ERR_ARG;
    }
    g.st.gop = gop;
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
#ifndef RTLNET_HOST_TEST
    uintptr_t src = (uintptr_t)(RTLNET_PLAT_DDR_BASE + base + (lines - 1u) * stride);
    uintptr_t dst = (uintptr_t)(RTLNET_PLAT_DDR_BASE + base + lines * stride);
    uint32_t i;
    for (i = 0u; i < g.padded_n; i++) {
        if (g.padded[i] == base) {
            return;
        }
    }
    plat_dcache_invalidate_range(src, stride);
    for (uint32_t r = 0u; r < coded_lines - lines; r++) {
        memcpy((void *)(dst + (uintptr_t)r * stride), (const void *)src, stride);
    }
    plat_dcache_flush_range(dst, (coded_lines - lines) * stride);
    if (g.padded_n < VENC_PAD_SLOTS) {
        g.padded[g.padded_n++] = base;
    }
#else
    (void)base; (void)stride; (void)lines; (void)coded_lines;
#endif
}

/*
 * profile_in_force -- 1 when pictures are coded in the High profile (CABAC): the module is present and licensed, enabled in HP_CTRL and offers
 * CABAC. The parameter sets are written in the form of this profile. Builds without the seam, with the stub or with hp_caps 0 return 0.
 */
static int profile_in_force(void)
{
    rtlnet_h264_enc_hp_t hp;
    if (rtlnet_h264_enc_hp_status(RTLNET_PLAT_H264_BASE, &hp) != 0) {
        return 0;
    }
    return ((hp.present != 0u) && (hp.licensed != 0u) && (hp.enabled != 0u) && ((hp.caps & RTLNET_H264_HP_CAP_CABAC) != 0u)) ? 1 : 0;
}

/* The transform of inter macroblocks: requested by the user (RTLNET_H264_T8_OFF / _ON / _AUTO, default auto), and in force while the High profile is. */
static uint32_t g_t8_pref = (uint32_t)RTLNET_H264_T8_AUTO;

/*
 * t8_in_force -- 1 when the pictures use the 8x8 transform: the High profile is in force, the request bit is set and the module offers the
 * transform. The PPS then has transform_8x8_mode_flag 1.
 */
static int t8_in_force(void)
{
    rtlnet_h264_enc_hp_t hp;
    if ((profile_in_force() == 0) || (rtlnet_h264_enc_hp_status(RTLNET_PLAT_H264_BASE, &hp) != 0)) {
        return 0;
    }
    return ((hp.t8_enabled != 0u) && ((hp.caps & RTLNET_H264_HP_CAP_TRANSFORM8X8) != 0u)) ? 1 : 0;
}

/*
 * rtlnet_venc_set_transform8x8 -- see the header
 */
int rtlnet_venc_set_transform8x8(int mode)
{
    int rc = rtlnet_h264_enc_set_transform8x8(RTLNET_PLAT_H264_BASE, (mode == RTLNET_H264_T8_AUTO) ? RTLNET_H264_T8_AUTO : ((mode != 0) ? 1 : 0));
    if (rc == 0) {
        g_t8_pref = (mode == RTLNET_H264_T8_AUTO) ? (uint32_t)RTLNET_H264_T8_AUTO : ((mode != 0) ? 1u : 0u);
    }
    return rc;
}

/*
 * rtlnet_venc_transform8x8_counts -- see the header
 */
int rtlnet_venc_transform8x8_counts(uint32_t *n8, uint32_t *n4)
{
    return rtlnet_h264_enc_t8_counts(RTLNET_PLAT_H264_BASE, n8, n4);
}

/*
 * rtlnet_venc_transform8x8_wanted -- see the header
 */
int rtlnet_venc_transform8x8_wanted(void)
{
    return (int)g_t8_pref;
}

/*
 * rtlnet_venc_transform8x8_in_force -- see the header
 */
int rtlnet_venc_transform8x8_in_force(void)
{
    return t8_in_force();
}

/*
 * configure_mode -- program the core for a video mode: frame size and SPS/PPS bytes from the driver, ring and index ring
 * pointers cleared, firmware read pointers restarted. Called when the mode changes (and for the first picture).
 */
static int configure_mode(uint32_t mode)
{
    rtlnet_h264_enc_cfg_t cfg;
    rtlnet_h264_enc_mode_t m;
    /* The transform request is applied before the parameter sets are written (default auto; the module ignores it without hp_caps bit 1). */
    if (rtlnet_h264_enc_set_transform8x8(RTLNET_PLAT_H264_BASE, (int)g_t8_pref) == RTLNET_H264_HP_ERR_NO_AUTO) {
        /* The netlist has no adaptive choice (hp_caps bit 2): the default degrades to the 8x8 transform on every inter macroblock. */
        (void)rtlnet_h264_enc_set_transform8x8(RTLNET_PLAT_H264_BASE, RTLNET_H264_T8_ON);
    }
    if (rtlnet_h264_enc_get_mode(mode, &m) != 0 || rtlnet_h264_enc_set_mode(RTLNET_PLAT_H264_BASE, mode, &g.sps_cfg) != 0 ||
        rtlnet_h264_enc_write_sps_pps_tools(g.sps_pps, sizeof(g.sps_pps), &g.sps_cfg, profile_in_force(), t8_in_force(), &g.sps_len) != 0) {
        return -1;
    }
    memset(&cfg, 0, sizeof(cfg));
    cfg.mb_w = m.mb_w;
    cfg.mb_h = m.mb_h;
    cfg.slices = g.engines;
    cfg.qp = g.st.qp;
    cfg.log2_max_frame_num = VENC_LOG2_FN;
    cfg.in_base = 0u;
    cfg.in_stride = m.width * 2u;
    cfg.ry_base = VENC_RY_BASE;
    cfg.ru_base = VENC_RU_BASE;
    cfg.ring_base = VENC_RING_BASE;
    cfg.ring_size = VENC_RING_SIZE;
    cfg.idx_base = VENC_IDX_BASE;
    cfg.idx_entries = VENC_IDX_ENTRIES;
    if (rtlnet_h264_enc_configure(RTLNET_PLAT_H264_BASE, &cfg) != 0) {
        return -1;
    }
    rtlnet_h264_enc_ring_reset(RTLNET_PLAT_H264_BASE);
    for (uint32_t e = 0u; e < g.engines; e++) {
        g.scan_idx[e] = 0u;
    }
    g.cfg_mode = mode;
    g.padded_n = 0u;   /* the padding lines of the slots are filled again for the new geometry */
    g.need_idr = 1u;   /* a new mode starts a new coded video sequence: the reference of the old mode is unusable */
    g.st.mode = mode;
    g.st.width = m.display_width;
    g.st.height = m.display_height;
    return 0;
}

/*
 * begin_picture -- take the latest frame and start the encoder on it.
 * Steps: take the slot; map the frame width to the mode; (re)configure on a mode change; write the per-picture registers
 * (QP, input base and stride) through a full configure; start. Returns 0 when a picture runs; the slot is released on failure.
 */
static int begin_picture(void)
{
    rtlnet_framebuf_frame_t f;
    rtlnet_h264_enc_cfg_t cfg;
    rtlnet_h264_enc_mode_t m;
    uint32_t mode;
    uint32_t stride;
    uint32_t period;
    uint32_t pic_type;
    uint32_t qp;
    if (rtlnet_framebuf_fw_take(RTLNET_PLAT_FB_BASE, &f) != RTLNET_FB_OK) {
        g.st.errors++;
        return -1;
    }
    g.holding = 1;
    g.frame = f;
    if (f.width == 1280u && f.height == 720u) {
        mode = RTLNET_H264_MODE_720P30;
    } else if (f.width == 1920u && f.height == 1080u) {
        mode = RTLNET_H264_MODE_1080P30;
    } else {
        g.st.errors++;
        release_slot();
        return -1;
    }
    if (mode != g.cfg_mode && configure_mode(mode) != 0) {
        g.st.errors++;
        release_slot();
        return -1;
    }
    (void)rtlnet_h264_enc_get_mode(mode, &m);
    stride = rtlnet_reg_read32(RTLNET_PLAT_S2MM_BASE, RTLNET_S2MM_REG_STRIDE);
    if (stride == 0u) {
        stride = m.width * 2u;
    }
    if (m.height > f.height && f.height > 0u) {
        pad_slot(f.base, stride, f.height, m.height);
    }
    period = rtlnet_reg_read32(RTLNET_PLAT_CSI2_BASE, RTLNET_CSI2_REG_FRAME_PERIOD);
    g.pts_step = (uint32_t)(((uint64_t)period * 90000u + (RTLNET_PLAT_CPU_CLK_HZ / 2u)) / RTLNET_PLAT_CPU_CLK_HZ);
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
    if (g.need_idr || g.gop_pos >= g.st.gop || !g.bufs.has_ref) {
        pic_type = RTLNET_H264_PIC_IDR;
    } else {
        pic_type = RTLNET_H264_PIC_P;
    }
    ratectl_set_stream(&g_rc, m.width * m.height, g.pts_step);
    qp = ratectl_pick(&g_rc, pic_type == RTLNET_H264_PIC_IDR, g.st.gop);   /* constant QP mode returns the configured QP */
    memset(&cfg, 0, sizeof(cfg));
    cfg.mb_w = m.mb_w;
    cfg.mb_h = m.mb_h;
    cfg.slices = g.engines;
    cfg.qp = qp;
    cfg.log2_max_frame_num = VENC_LOG2_FN;
    cfg.in_base = f.base;
    cfg.in_stride = stride;
    cfg.ry_base = VENC_RY_BASE;
    cfg.ru_base = VENC_RU_BASE;
    cfg.ring_base = VENC_RING_BASE;
    cfg.ring_size = VENC_RING_SIZE;
    cfg.idx_base = VENC_IDX_BASE;
    cfg.idx_entries = VENC_IDX_ENTRIES;
    if (rtlnet_h264_enc_configure(RTLNET_PLAT_H264_BASE, &cfg) != 0) {
        g.st.errors++;
        release_slot();
        return -1;
    }
    g.st.qp_used = rtlnet_reg_read32(RTLNET_PLAT_H264_BASE, RTLNET_H264_REG_QP);
    g.pic_seq++;
    if (rtlnet_h264_enc_buffers_begin(RTLNET_PLAT_H264_BASE, &g.bufs, pic_type) != 0 ||
        rtlnet_h264_enc_start_picture_ex(RTLNET_PLAT_H264_BASE,
                                         pic_type == RTLNET_H264_PIC_IDR ? 0u : rtlnet_h264_enc_next_frame_num(g.prev_fn, VENC_LOG2_FN),
                                         g.idr_id, pic_type) != 0) {
        g.st.errors++;
        g.need_idr = 1u;
        release_slot();
        return -1;
    }
    g.pic_type = pic_type;
    if (pic_type == RTLNET_H264_PIC_IDR) {
        g.prev_fn = 0u;
        g.idr_id ^= 1u;       /* consecutive IDR pictures differ (clause 7.4.3) */
        g.need_idr = 0u;
        g.gop_pos = 1u;
    } else {
        g.prev_fn = rtlnet_h264_enc_next_frame_num(g.prev_fn, VENC_LOG2_FN);
        g.gop_pos++;
    }
    g.t_start = plat_ticks();
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
        /* Lag: the frame's time stamp counts ui_clk cycles, plat_ticks counts the same 90 MHz clock from another origin; the smallest
         * difference seen is taken as zero lag (the firmware was idle and saw the frame at once). */
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
 * hp_after_picture -- High profile seam: the picture just completed.
 * The encoder codes a picture as a forced IDR picture (frame_num 0, new idr_pic_id, intra only) when the license or the profile
 * changed at its start, and sets PROFILE_CHG. Steps: read and clear the flag; when it was set, the picture in flight was an IDR
 * picture whatever was requested: restart the GOP at it (frame_num counting from 0, the next IDR picture's id differs), and
 * rewrite the parameter sets, which the mux sends in front of every IDR picture. Builds without the seam do nothing.
 */
static void hp_after_picture(void)
{
    if (rtlnet_h264_enc_hp_clear_change(RTLNET_PLAT_H264_BASE) != 1) {
        return;
    }
    g.st.hp_forced_idr++;
    if (g.pic_type != RTLNET_H264_PIC_IDR) {
        g.pic_type = RTLNET_H264_PIC_IDR;
        g.prev_fn = 0u;
        g.gop_pos = 1u;
        g.need_idr = 0u;
        g.idr_id ^= 1u;       /* the next IDR picture differs from the forced one (clause 7.4.3) */
    }
    /* The parameter sets are rewritten for the profile now in force: High (profile_idc 100, entropy_coding_mode_flag 1) while the module
     * codes CABAC pictures, Constrained Baseline after the license ended or the enable was cleared. The mux sends them in front of this
     * forced IDR picture. */
    (void)rtlnet_h264_enc_write_sps_pps_tools(g.sps_pps, sizeof(g.sps_pps), &g.sps_cfg, profile_in_force(), t8_in_force(), &g.sps_len);
}

/*
 * queue_picture -- on DONE: read the picture entries of every engine and queue the picture for the multiplexer.
 * Steps: for each engine find the next picture entry in its index ring (from scan_idx); check the access unit delimiter at the start of
 * engine 0's data; fill the descriptor (frame, type, QP, PTS, ring offsets and lengths, the ring and index positions that are free
 * once the picture is sent, the delimiter, the SPS and PPS of an IDR picture); rate control sees the size now (the sizes are known at
 * DONE, so the controller runs in coding order whatever the multiplexer is doing); push the descriptor.
 * Returns 0, or -1 when an index entry is missing or malformed or the queue refuses (the rings are then reset at the next picture,
 * after the queue is drained).
 */
static int queue_picture(void)
{
    picq_desc_t d;
    uint32_t idx_share = VENC_IDX_ENTRIES / g.engines;
    uint32_t share = VENC_RING_SIZE / g.engines;
    uint32_t new_idx[VENC_MAX_ENGINES];
    uint32_t total = 0u;
    memset(&d, 0, sizeof(d));
    for (uint32_t e = 0u; e < g.engines; e++) {
        uintptr_t win = RTLNET_PLAT_H264_BASE + 0x100u * e;
        uint32_t wptr = rtlnet_h264_enc_index_wptr(win);
        uint32_t r = g.scan_idx[e];
        int found = 0;
        while (r != wptr && !found) {
            uint8_t raw[RTLNET_H264_IDX_WORDS * 4u];   /* the entry words at the start of the 128-byte record */
            uint32_t w[4];
            rtlnet_h264_enc_index_entry_t ent;
            mem_copy(raw, VENC_IDX_BASE + RTLNET_H264_IDX_ENTRY_BYTES * (e * idx_share + r), sizeof(raw));
            for (uint32_t i = 0u; i < 4u; i++) {
                w[i] = (uint32_t)raw[4u * i] | ((uint32_t)raw[4u * i + 1u] << 8) | ((uint32_t)raw[4u * i + 2u] << 16) |
                       ((uint32_t)raw[4u * i + 3u] << 24);
            }
            rtlnet_h264_enc_decode_index_entry(w, &ent);
            r = (r + 1u) % idx_share;
            if (ent.is_picture) {
                d.off[e] = ent.offset;
                d.len[e] = ent.length;
                found = 1;
            }
        }
        if (!found || d.off[e] >= share || d.len[e] > share) {
            return -1;
        }
        new_idx[e] = r;
    }
    if (d.len[0] < PICQ_AUD_BYTES) {
        return -1;
    }
    mem_copy(d.aud, VENC_RING_BASE + d.off[0], PICQ_AUD_BYTES);
    if (d.aud[0] != 0u || d.aud[1] != 0u || d.aud[2] != 0u || d.aud[3] != 1u || d.aud[4] != 0x09u) {
        return -1;
    }
    d.engines = g.engines;
    d.frame = g.frame.frame;
    d.pic_type = g.pic_type;
    d.qp = g.st.qp_used;
    d.pts = (uint64_t)VENC_PTS_BASE + (uint64_t)(g.frame.frame - g.first_frame) * g.pts_step;
    for (uint32_t e = 0u; e < g.engines; e++) {
        total += d.len[e];
        d.ring_end[e] = (d.off[e] + d.len[e]) % share;
        d.idx_end[e] = new_idx[e];
    }
    if (g.pic_type == RTLNET_H264_PIC_IDR) {
        d.sps_len = (uint32_t)g.sps_len;
        memcpy(d.sps_pps, g.sps_pps, g.sps_len);
        total += d.sps_len;
    }
    d.es_bytes = total;
    d.t_done = plat_ticks();
    if (picq_push(&g.q, &d) != PICQ_OK) {
        return -1;
    }
    for (uint32_t e = 0u; e < g.engines; e++) {
        g.scan_idx[e] = new_idx[e];
    }
    /* Rate control: the coded size (the entry lengths of every engine, plus the SPS and PPS of an IDR picture), the QP written and
     * the stream time since the previous picture (more than one period after a dropped picture). */
    ratectl_picture_done(&g_rc, g.pic_type == RTLNET_H264_PIC_IDR, g.st.qp_used, total * 8u,
                         g.have_last ? (g.frame.frame - g.st.last_frame) * g.pts_step : g.pts_step);
    g.st.last_frame = g.frame.frame;
    g.have_last = 1;
    if (picq_count(&g.q) > g.st.backlog_max) {
        g.st.backlog_max = picq_count(&g.q);
    }
    return 0;
}

/* window_update -- once per second: bit rate and load figures from the accumulated byte count and busy ticks. */
static void window_update(void)
{
    uint32_t now = plat_uptime_ms();
    uint32_t span = now - g.win_start_ms;
    if (span >= 1000u) {
        uint64_t ticks = (uint64_t)span * (RTLNET_PLAT_TICKS_PER_US * 1000u);
        uint32_t ts_now = g.mux.bytes;
        g.st.bit_rate_bps = (uint32_t)(((uint64_t)(ts_now - g.win_ts_bytes) * 8u * 1000u) / span);
        g.st.mux_load_permille = (uint32_t)(((uint64_t)g.win_mux_ticks * 1000u) / ticks);
        g.st.venc_load_permille = (uint32_t)(((uint64_t)g.win_busy_ticks * 1000u) / ticks);
        g.win_ts_bytes = ts_now;
        g.win_mux_ticks = 0u;
        g.win_busy_ticks = 0u;
        g.win_start_ms = now;
    }
}

/* mode_of -- the encoder mode of a frame size, 0xFFFFFFFF for an unsupported size. */
static uint32_t mode_of(uint32_t w, uint32_t h)
{
    if (w == 1280u && h == 720u) {
        return RTLNET_H264_MODE_720P30;
    }
    if (w == 1920u && h == 1080u) {
        return RTLNET_H264_MODE_1080P30;
    }
    return 0xFFFFFFFFu;
}

/*
 * try_begin -- encoder idle: start the next picture when a new frame is ready.
 * A frame already coded or already skipped is not taken again. When the rings are to be reset (a mode change, or an error left
 * cfg_mode invalid) the queue is drained first: the pictures in it point into the rings. When the queue holds PICQ_LIMIT pictures the
 * frame is skipped: counted as a dropped picture and as a backlog skip, the next picture is an IDR picture, the slot is not taken (so
 * the encoder cannot stall on a full ring).
 */
static void try_begin(void)
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
    mode = mode_of(wh & 0xFFFFu, wh >> 16);
    if (picq_count(&g.q) != 0u && (g.cfg_mode == 0xFFFFFFFFu || (mode != 0xFFFFFFFFu && mode != g.cfg_mode))) {
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
    if (begin_picture() == 0) {
        g.state = ST_ENCODING;
    }
    g.win_busy_ticks += plat_ticks() - t0;
}

/* mux_finish -- the picture the job sent is complete: free its ring and index space, account for it, remove it from the queue. */
static void mux_finish(void)
{
    const picq_desc_t *d = picq_front(&g.q);
    if (d == NULL) {
        return;
    }
    for (uint32_t e = 0u; e < d->engines; e++) {
        rtlnet_h264_enc_set_read_pointers(RTLNET_PLAT_H264_BASE + 0x100u * e, d->ring_end[e], d->idx_end[e]);
    }
    g.st.last_mux_us = g.mux_pic_ticks / RTLNET_PLAT_TICKS_PER_US;
    if (g.st.last_mux_us > g.st.max_mux_us) {
        g.st.max_mux_us = g.st.last_mux_us;
    }
    if (d->pic_type == RTLNET_H264_PIC_IDR) {
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
    g.win_busy_ticks += dt;
    if (done) {
        mux_finish();
    }
}

void venc_poll(void)
{
    if (!g.st.running) {
        return;
    }
    window_update();
    if (g.state == ST_ENCODING) {
        uint32_t status = rtlnet_h264_enc_status(RTLNET_PLAT_H264_BASE);
        if ((status & (RTLNET_H264_STATUS_DONE | RTLNET_H264_STATUS_ERR)) != 0u) {
            uint32_t t0 = plat_ticks();
            release_slot();
            if ((status & RTLNET_H264_STATUS_ERR) != 0u) {
                g.st.errors++;
                rtlnet_h264_enc_clear_status(RTLNET_PLAT_H264_BASE);
                g.cfg_mode = 0xFFFFFFFFu;   /* reconfigure and reset the rings at the next picture (configure_mode forces an IDR) */
                g.need_idr = 1u;
            } else {
                rtlnet_h264_enc_clear_status(RTLNET_PLAT_H264_BASE);
                rtlnet_h264_enc_buffers_end(&g.bufs);   /* the picture just rebuilt is the reference of the next one */
                hp_after_picture();
                if (queue_picture() != 0) {
                    g.st.errors++;
                    g.cfg_mode = 0xFFFFFFFFu;
                }
            }
            g.state = ST_IDLE;
            g.win_busy_ticks += plat_ticks() - t0;
        } else if ((plat_ticks() - g.t_start) > VENC_ENC_TIMEOUT_US * RTLNET_PLAT_TICKS_PER_US) {
            release_slot();
            g.st.errors++;
            g.cfg_mode = 0xFFFFFFFFu;
            g.need_idr = 1u;
            g.state = ST_IDLE;
        }
    }
    if (g.state == ST_IDLE) {
        try_begin();
    }
    mux_service();
}

void venc_get_status(venc_status_t *out)
{
    rtlnet_framebuf_state_t fs;
    *out = g.st;
    out->ts_bytes = g.mux.bytes;
    out->ts_packets = g.mux.packets;
    out->datagrams = g.mux.datagrams;
    out->sink_errors = g.mux.sink_errors;
    if (rtlnet_framebuf_read_state(RTLNET_PLAT_FB_BASE, &fs) == RTLNET_FB_OK) {
        out->fb_dropped = fs.dropped;
        out->fb_published = fs.published;
    }
    {
        uint64_t copy_t;
        uint64_t send_t;
        uint32_t tpu = RTLNET_PLAT_TICKS_PER_US;
        video_udp_profile(&copy_t, &send_t);
        copy_t -= g.udp_copy0;
        send_t -= g.udp_send0;
        out->cyc_n = g.cyc_n;
        out->cyc_min_us = g.cyc_min / tpu;
        out->cyc_avg_us = (g.cyc_cnt != 0u) ? (uint32_t)(g.cyc_sum / g.cyc_cnt / tpu) : 0u;
        out->cyc_max_us = g.cyc_max / tpu;
        out->lag_avg_us = (g.lag_cnt != 0u) ? (uint32_t)(g.lag_sum / g.lag_cnt / tpu) : 0u;
        out->lag_max_us = g.lag_max / tpu;
        out->mux_n = g.mux_n;
        out->mux_ring_ts_us = (g.mux_n != 0u) ? (uint32_t)(g.mux_chunk_ticks / g.mux_n / tpu) : 0u;
        out->mux_copy_us = (g.mux_n != 0u) ? (uint32_t)(copy_t / g.mux_n / tpu) : 0u;
        out->mux_send_us = (g.mux_n != 0u) ? (uint32_t)(send_t / g.mux_n / tpu) : 0u;
        out->backlog = picq_count(&g.q);
        out->backlog_max = g.st.backlog_max;
        out->skipped_backlog = g.skipped_backlog;
        out->backlog_limit = PICQ_LIMIT;
    }
}

void venc_clear_counters(void)
{
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
    video_udp_profile(&g.udp_copy0, &g.udp_send0);
}
