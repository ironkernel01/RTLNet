/*
 * rtlnet_venc.c -- H.264 encoder session and MPEG-TS stream over UDP
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_venc.h.
 *
 * Revision: 11-09-2026
 */
#include "rtlnet_venc.h"

#include <string.h>   /* memset, memcpy */

#include "rtlnet_board.h"
#include "rtlnet_csi2_rx.h"
#include "rtlnet_framebuf.h"
#include "rtlnet_h264_enc.h"
#include "rtlnet_mmio.h"
#include "rtlnet_platform.h"
#include "rtlnet_tsmux.h"
#include "rtlnet_vdma_s2mm.h"
#include "rtlnet_video_udp.h"

#ifdef RTLNET_HOST_TEST
uint32_t rtlnet_host_mem_read32(uintptr_t addr);
#endif

/* DDR3 map (byte offsets in DDR3). */
#define VENC_RY_BASE      0x11000000u
#define VENC_RY_STRIDE    2048u
#define VENC_RU_BASE      0x11300000u
#define VENC_RV_BASE      0x11380000u
#define VENC_RC_STRIDE    1024u
#define VENC_RING_BASE    0x12000000u
#define VENC_RING_SIZE    0x00800000u
#define VENC_IDX_BASE     0x13000000u
#define VENC_IDX_ENTRIES  256u

#define VENC_PTS_BASE     90000u     /* first PTS: one second */
#define VENC_PCR_LEAD     9000u      /* PTS minus PCR: 100 ms */
#define VENC_ENC_TIMEOUT_US  500000u
#define VENC_LOG2_FN      4u
#define VENC_CHUNK        1024u      /* bytes per cache invalidate and read */

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
    uint32_t                   pts_step;
    uint32_t                   ring_rptr[VENC_MAX_ENGINES];
    uint32_t                   idx_rptr[VENC_MAX_ENGINES];
    uint32_t                   pic_seq;
    uint32_t                   t_start;           /* plat_ticks at picture start */
    /* load accounting: ticks of busy time in the current one-second window */
    uint32_t                   win_start_ms;
    uint32_t                   win_ts_bytes;
    uint32_t                   win_mux_ticks;
    uint32_t                   win_busy_ticks;
} g;

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
    (void)ctx;
    return video_udp_send(d, len);
}

/* ring_feed -- append n ring bytes (engine e, ring offset off, wrapping at the share) to the access unit in chunks. */
static void ring_feed(uint32_t e, uint32_t off, uint32_t n)
{
    static uint8_t chunk[VENC_CHUNK];
    uint32_t share = VENC_RING_SIZE / g.engines;
    uint32_t base = VENC_RING_BASE + e * share;
    while (n != 0u) {
        uint32_t c = n;
        if (c > VENC_CHUNK) {
            c = VENC_CHUNK;
        }
        if (off + c > share) {
            c = share - off;
        }
#ifdef RTLNET_HOST_TEST
        mem_copy(chunk, base + off, c);
        tsmux_au_data(&g.mux, chunk, c);
#else
        plat_dcache_invalidate_range((uintptr_t)(RTLNET_PLAT_DDR_BASE + base + off), c);
        tsmux_au_data(&g.mux, (const uint8_t *)(uintptr_t)(RTLNET_PLAT_DDR_BASE + base + off), c);
        (void)chunk;
#endif
        off = (off + c) % share;
        n -= c;
    }
}

void venc_init(void)
{
    memset(&g, 0, sizeof(g));
    g.st.qp = VENC_QP_DEFAULT;
    g.cfg_mode = 0xFFFFFFFFu;
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
    g.state = ST_IDLE;
    g.pic_seq = 0u;
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
    g.st.running = 0;
    video_udp_close();
}

int venc_set_qp(uint32_t qp)
{
    if (qp > VENC_QP_MAX) {
        return VENC_ERR_ARG;
    }
    g.st.qp = qp;
    return VENC_OK;
}

/*
 * configure_mode -- program the core for a video mode: frame size and SPS/PPS bytes from the driver, ring and index ring
 * pointers cleared, firmware read pointers restarted. Called when the mode changes (and for the first picture).
 */
static int configure_mode(uint32_t mode)
{
    rtlnet_h264_enc_cfg_t cfg;
    rtlnet_h264_enc_mode_t m;
    if (rtlnet_h264_enc_get_mode(mode, &m) != 0 || rtlnet_h264_enc_set_mode(RTLNET_PLAT_H264_BASE, mode, &g.sps_cfg) != 0 ||
        rtlnet_h264_enc_write_sps_pps(g.sps_pps, sizeof(g.sps_pps), &g.sps_cfg, &g.sps_len) != 0) {
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
    cfg.ry_stride = VENC_RY_STRIDE;
    cfg.ru_base = VENC_RU_BASE;
    cfg.rv_base = VENC_RV_BASE;
    cfg.rc_stride = VENC_RC_STRIDE;
    cfg.ring_base = VENC_RING_BASE;
    cfg.ring_size = VENC_RING_SIZE;
    cfg.idx_base = VENC_IDX_BASE;
    cfg.idx_entries = VENC_IDX_ENTRIES;
    if (rtlnet_h264_enc_configure(RTLNET_PLAT_H264_BASE, &cfg) != 0) {
        return -1;
    }
    rtlnet_h264_enc_ring_reset(RTLNET_PLAT_H264_BASE);
    for (uint32_t e = 0u; e < g.engines; e++) {
        g.ring_rptr[e] = 0u;
        g.idx_rptr[e] = 0u;
    }
    g.cfg_mode = mode;
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
    memset(&cfg, 0, sizeof(cfg));
    cfg.mb_w = m.mb_w;
    cfg.mb_h = m.mb_h;
    cfg.slices = g.engines;
    cfg.qp = g.st.qp;
    cfg.log2_max_frame_num = VENC_LOG2_FN;
    cfg.in_base = f.base;
    cfg.in_stride = stride;
    cfg.ry_base = VENC_RY_BASE;
    cfg.ry_stride = VENC_RY_STRIDE;
    cfg.ru_base = VENC_RU_BASE;
    cfg.rv_base = VENC_RV_BASE;
    cfg.rc_stride = VENC_RC_STRIDE;
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
    period = rtlnet_reg_read32(RTLNET_PLAT_CSI2_BASE, RTLNET_CSI2_REG_FRAME_PERIOD);
    g.pts_step = (uint32_t)(((uint64_t)period * 90000u + (RTLNET_PLAT_CPU_CLK_HZ / 2u)) / RTLNET_PLAT_CPU_CLK_HZ);
    if (g.pts_step == 0u) {
        g.pts_step = 3000u;
    }
    if (!g.have_last) {
        g.first_frame = f.frame;
    } else if (f.frame > g.st.last_frame + 1u) {
        g.st.dropped_pictures += f.frame - g.st.last_frame - 1u;
    }
    g.pic_seq++;
    if (rtlnet_h264_enc_start_picture(RTLNET_PLAT_H264_BASE, 0u, g.pic_seq & 0xFFu, 1) != 0) {
        g.st.errors++;
        release_slot();
        return -1;
    }
    g.t_start = plat_ticks();
    return 0;
}

/*
 * mux_picture -- read both engines' picture entries and send the access unit.
 * Steps: for each engine find the next picture entry in its index ring; check the access unit delimiter at the start of
 * engine 0's data; au_begin; AUD, SPS and PPS, the rest of engine 0, all of the other engines; au_end; advance the
 * ring and index read pointers.
 * Returns 0, or -1 when an index entry is missing or malformed (the rings are then reset).
 */
static int mux_picture(void)
{
    uint32_t off[VENC_MAX_ENGINES];
    uint32_t len[VENC_MAX_ENGINES];
    uint32_t idx_share = VENC_IDX_ENTRIES / g.engines;
    uint32_t share = VENC_RING_SIZE / g.engines;
    uint32_t new_idx[VENC_MAX_ENGINES];
    uint8_t  aud[6];
    uint32_t total = 0u;
    uint64_t pts;
    uint32_t t0;
    uint32_t dt;
    for (uint32_t e = 0u; e < g.engines; e++) {
        uintptr_t win = RTLNET_PLAT_H264_BASE + 0x100u * e;
        uint32_t wptr = rtlnet_h264_enc_index_wptr(win);
        uint32_t r = g.idx_rptr[e];
        int found = 0;
        while (r != wptr && !found) {
            uint8_t raw[RTLNET_H264_IDX_ENTRY_BYTES];
            uint32_t w[4];
            rtlnet_h264_enc_index_entry_t ent;
            mem_copy(raw, VENC_IDX_BASE + 16u * (e * idx_share + r), sizeof(raw));
            for (uint32_t i = 0u; i < 4u; i++) {
                w[i] = (uint32_t)raw[4u * i] | ((uint32_t)raw[4u * i + 1u] << 8) | ((uint32_t)raw[4u * i + 2u] << 16) |
                       ((uint32_t)raw[4u * i + 3u] << 24);
            }
            rtlnet_h264_enc_decode_index_entry(w, &ent);
            r = (r + 1u) % idx_share;
            if (ent.is_picture) {
                off[e] = ent.offset;
                len[e] = ent.length;
                found = 1;
            }
        }
        if (!found || off[e] >= share || len[e] > share) {
            return -1;
        }
        new_idx[e] = r;
    }
    if (len[0] < 6u) {
        return -1;
    }
    mem_copy(aud, VENC_RING_BASE + off[0], sizeof(aud));
    if (aud[0] != 0u || aud[1] != 0u || aud[2] != 0u || aud[3] != 1u || aud[4] != 0x09u) {
        return -1;
    }
    pts = (uint64_t)VENC_PTS_BASE + (uint64_t)(g.frame.frame - g.first_frame) * g.pts_step;
    t0 = plat_ticks();
    tsmux_au_begin(&g.mux, pts, pts - VENC_PCR_LEAD, 1);
    tsmux_au_data(&g.mux, aud, sizeof(aud));
    tsmux_au_data(&g.mux, g.sps_pps, (uint32_t)g.sps_len);
    ring_feed(0u, (off[0] + 6u) % share, len[0] - 6u);
    for (uint32_t e = 1u; e < g.engines; e++) {
        ring_feed(e, off[e], len[e]);
    }
    tsmux_au_end(&g.mux);
    dt = plat_ticks() - t0;
    g.win_mux_ticks += dt;
    g.st.last_mux_us = dt / RTLNET_PLAT_TICKS_PER_US;
    if (g.st.last_mux_us > g.st.max_mux_us) {
        g.st.max_mux_us = g.st.last_mux_us;
    }
    for (uint32_t e = 0u; e < g.engines; e++) {
        total += len[e];
        g.ring_rptr[e] = (off[e] + len[e]) % share;
        g.idx_rptr[e] = new_idx[e];
        rtlnet_h264_enc_set_read_pointers(RTLNET_PLAT_H264_BASE + 0x100u * e, g.ring_rptr[e], g.idx_rptr[e]);
    }
    g.st.pictures++;
    g.st.es_bytes += total + (uint32_t)g.sps_len;
    g.st.last_picture_bytes = total + (uint32_t)g.sps_len;
    g.st.last_frame = g.frame.frame;
    g.have_last = 1;
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

void venc_poll(void)
{
    uint32_t t0;
    if (!g.st.running) {
        return;
    }
    window_update();
    if (g.state == ST_IDLE) {
        uint32_t status = rtlnet_reg_read32(RTLNET_PLAT_FB_BASE, RTLNET_FB_REG_STATUS);
        if ((status & RTLNET_FB_STATUS_LATEST_VALID) == 0u) {
            return;
        }
        if (g.have_last && rtlnet_reg_read32(RTLNET_PLAT_FB_BASE, RTLNET_FB_REG_LATEST_FRAME) == g.st.last_frame) {
            return;
        }
        t0 = plat_ticks();
        if (begin_picture() == 0) {
            g.state = ST_ENCODING;
        }
        g.win_busy_ticks += plat_ticks() - t0;
    } else {
        uint32_t status = rtlnet_h264_enc_status(RTLNET_PLAT_H264_BASE);
        if ((status & (RTLNET_H264_STATUS_DONE | RTLNET_H264_STATUS_ERR)) != 0u) {
            t0 = plat_ticks();
            release_slot();
            if ((status & RTLNET_H264_STATUS_ERR) != 0u) {
                g.st.errors++;
                rtlnet_h264_enc_clear_status(RTLNET_PLAT_H264_BASE);
                g.cfg_mode = 0xFFFFFFFFu;   /* reconfigure and reset the rings at the next picture */
            } else {
                rtlnet_h264_enc_clear_status(RTLNET_PLAT_H264_BASE);
                if (mux_picture() != 0) {
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
            g.state = ST_IDLE;
        }
    }
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
}

void venc_clear_counters(void)
{
    g.st.pictures = 0u;
    g.st.es_bytes = 0u;
    g.st.dropped_pictures = 0u;
    g.st.errors = 0u;
    g.st.max_mux_us = 0u;
    tsmux_clear_counters(&g.mux);
    g.win_ts_bytes = 0u;
}
