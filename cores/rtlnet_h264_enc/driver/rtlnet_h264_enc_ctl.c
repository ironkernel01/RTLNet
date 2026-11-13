/*
 * rtlnet_h264_enc_ctl.c -- RTLNet H.264 encoder control: session, notification mode, picture turnaround
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_h264_enc_ctl.h, on the register driver rtlnet_h264_enc.c. One encoder core per design: the
 * session state is one static object. Shared between the interrupt handler and the main loop: the counters (single writer each), chg_seen
 * (written by the handler and by the start function, read by the completion code) and notify_active (written only while no picture is in flight).
 */
#include "rtlnet_h264_enc_ctl.h"

#include <string.h>   /* memset */

#include "rtlnet_h264_enc.h"
#include "rtlnet_mmio.h"

/* The control layer repeats a few constants so that its header needs no register definitions: they must equal the register driver's. */
_Static_assert(RTLNET_H264_CTL_MODE_720P30 == RTLNET_H264_MODE_720P30, "mode 720p30");
_Static_assert(RTLNET_H264_CTL_MODE_1080P30 == RTLNET_H264_MODE_1080P30, "mode 1080p30");
_Static_assert(RTLNET_H264_CTL_PIC_IDR == RTLNET_H264_PIC_IDR, "pic idr");
_Static_assert(RTLNET_H264_CTL_PIC_P == RTLNET_H264_PIC_P, "pic p");
_Static_assert(RTLNET_H264_CTL_T8_OFF == RTLNET_H264_T8_OFF, "t8 off");
_Static_assert(RTLNET_H264_CTL_T8_ON == RTLNET_H264_T8_ON, "t8 on");
_Static_assert(RTLNET_H264_CTL_T8_AUTO == RTLNET_H264_T8_AUTO, "t8 auto");
_Static_assert(RTLNET_H264_CTL_QP_MIN_REALTIME == RTLNET_H264_QP_MIN_REALTIME, "qp floor");
_Static_assert(RTLNET_H264_CTL_PS_BYTES == RTLNET_H264_SPS_PPS_MAX_BYTES, "parameter set bytes");
_Static_assert(RTLNET_H264_CTL_HP_ERR_NO_SEAM == RTLNET_H264_HP_ERR_NO_SEAM, "hp err seam");
_Static_assert(RTLNET_H264_CTL_HP_ERR_NO_CAPS == RTLNET_H264_HP_ERR_NO_CAPS, "hp err caps");
_Static_assert(RTLNET_H264_CTL_HP_ERR_NOT_LICENSED == RTLNET_H264_HP_ERR_NOT_LICENSED, "hp err license");
_Static_assert(RTLNET_H264_CTL_HP_ERR_NO_MODULE == RTLNET_H264_HP_ERR_NO_MODULE, "hp err module");
_Static_assert(RTLNET_H264_CTL_HP_ERR_NO_T8 == RTLNET_H264_HP_ERR_NO_T8, "hp err t8");
_Static_assert(RTLNET_H264_CTL_HP_ERR_NO_AUTO == RTLNET_H264_HP_ERR_NO_AUTO, "hp err auto");
_Static_assert(RTLNET_H264_CTL_HP_CAP_CABAC == RTLNET_H264_HP_CAP_CABAC, "cap cabac");
_Static_assert(RTLNET_H264_CTL_HP_CAP_TRANSFORM8X8 == RTLNET_H264_HP_CAP_TRANSFORM8X8, "cap t8");
_Static_assert(RTLNET_H264_CTL_HP_CAP_ADAPTIVE == RTLNET_H264_HP_CAP_ADAPTIVE, "cap adaptive");
_Static_assert(RTLNET_H264_CTL_HP_SECONDS_UNLIMITED == RTLNET_H264_HP_SECONDS_UNLIMITED, "seconds unlimited");
_Static_assert((1u << RTLNET_H264_CTL_SRC_PIC_DONE) == RTLNET_H264_IRQ_PIC_DONE, "src pic done");
_Static_assert((1u << RTLNET_H264_CTL_SRC_ERR) == RTLNET_H264_IRQ_ERR, "src err");
_Static_assert((1u << RTLNET_H264_CTL_SRC_RING_STALL) == RTLNET_H264_IRQ_RING_STALL, "src stall");
_Static_assert((1u << RTLNET_H264_CTL_SRC_PROFILE_CHG) == RTLNET_H264_IRQ_PROFILE_CHG, "src chg");
_Static_assert((1u << RTLNET_H264_CTL_SRC_LICENSE_LOST) == RTLNET_H264_IRQ_LICENSE_LOST, "src license");
_Static_assert((1u << RTLNET_H264_CTL_SRC_PIC_START) == RTLNET_H264_IRQ_PIC_START, "src start");

#define ENGINE_WINDOW_BYTES 0x100u      /* per-engine register windows (documentation section 4) */
#define IRQ_USED (RTLNET_H264_IRQ_PIC_DONE | RTLNET_H264_IRQ_ERR | RTLNET_H264_IRQ_RING_STALL | RTLNET_H264_IRQ_PROFILE_CHG | \
                  RTLNET_H264_IRQ_LICENSE_LOST)   /* the sources the interrupt mode enables; PIC_START stays masked */
#define IRQ_ALL  0xFFu

static struct {
    uintptr_t                   base;
    rtlnet_h264_ctl_layout_t    layout;
    rtlnet_h264_ctl_ops_t       ops;
    int                         is_open;
    uint32_t                    engines;
    uint32_t                    irq_capable;
    uint32_t                    irq_sources;
    uint32_t                    hp_seam;
    uint32_t                    notify_wanted;
    volatile uint32_t           notify_active;     /* 1: interrupt mode in force */
    uint32_t                    mode;              /* video mode the core is configured for */
    rtlnet_h264_ctl_mode_t      minfo;
    rtlnet_h264_enc_sps_cfg_t   sps_cfg;
    uint8_t                     sps_pps[RTLNET_H264_SPS_PPS_MAX_BYTES];
    size_t                      sps_len;
    rtlnet_h264_enc_buffers_t   bufs;
    uint32_t                    scan_idx[RTLNET_H264_CTL_MAX_ENGINES];   /* index ring position where the next picture's entries are looked for */
    volatile uint32_t           chg_seen;          /* a profile change was reported since the picture start */
    uint32_t                    qp_used;
    uint32_t                    pic_type;
    uint32_t                    t8_pref;
    /* counters: the handler (or the poll function) writes them, the main loop reads */
    volatile uint32_t           irqs;
    volatile uint32_t           spurious;
    volatile uint32_t           source[RTLNET_H264_CTL_SRC_COUNT];
    volatile uint32_t           pictures;
    volatile uint32_t           errors;
    uint32_t                    seen[RTLNET_H264_CTL_SRC_COUNT];   /* take_events snapshot, main context only */
} g;

/*
 * rtlnet_h264_ctl_init -- see the header
 */
void rtlnet_h264_ctl_init(uintptr_t base, const rtlnet_h264_ctl_layout_t *layout, const rtlnet_h264_ctl_ops_t *ops)
{
    memset(&g, 0, sizeof(g));
    g.base = base;
    if (layout != NULL) {
        g.layout = *layout;
    }
    if (ops != NULL) {
        g.ops = *ops;
    }
    g.notify_wanted = RTLNET_H264_NOTIFY_INTERRUPT;
    g.mode = RTLNET_H264_CTL_MODE_NONE;
    g.t8_pref = (uint32_t)RTLNET_H264_T8_OFF;   /* the default is the 4x4 transform; on and auto are requests */
    (void)rtlnet_h264_enc_buffers_init(&g.bufs, g.layout.ry_base[0], g.layout.ru_base[0], g.layout.ry_base[1], g.layout.ru_base[1]);
}

/*
 * apply_notify -- program the core's interrupt registers for the mode wanted.
 * Steps: global enable off, sources off, stale events acknowledged; in interrupt mode on a capable core, the sources enabled and the global
 * enable set. notify_active follows. The interrupt mode never runs on a core without the registers.
 */
static void apply_notify(void)
{
    g.notify_active = 0u;
    if (g.irq_capable == 0u) {
        return;
    }
    (void)rtlnet_h264_enc_irq_global(g.base, 0);
    (void)rtlnet_h264_enc_irq_set_enable(g.base, 0u);
    rtlnet_h264_enc_irq_ack(g.base, IRQ_ALL);
    if (g.notify_wanted == RTLNET_H264_NOTIFY_INTERRUPT) {
        (void)rtlnet_h264_enc_irq_set_enable(g.base, IRQ_USED & g.irq_sources);
        (void)rtlnet_h264_enc_irq_global(g.base, 1);
        g.notify_active = 1u;
    }
}

/*
 * rtlnet_h264_ctl_open -- see the header
 */
int rtlnet_h264_ctl_open(rtlnet_h264_ctl_info_t *info)
{
    rtlnet_h264_enc_caps_t caps;

    g.is_open = 0;
    g.notify_active = 0u;
    if ((rtlnet_h264_enc_probe(g.base, &caps) != 0) || (caps.num_engines == 0u) || (caps.num_engines > RTLNET_H264_CTL_MAX_ENGINES)) {
        return -1;
    }
    g.engines     = caps.num_engines;
    g.irq_capable = caps.irq;
    g.irq_sources = caps.irq_sources;
    g.hp_seam     = caps.hp_seam;
    g.mode        = RTLNET_H264_CTL_MODE_NONE;
    g.chg_seen    = 0u;
    memset(g.scan_idx, 0, sizeof(g.scan_idx));
    rtlnet_h264_ctl_reset_session();
    apply_notify();
    g.is_open = 1;
    if (info != NULL) {
        info->engines     = caps.num_engines;
        info->max_mb_w    = caps.max_mb_w;
        info->max_mb_h    = caps.max_mb_h;
        info->hp_seam     = caps.hp_seam;
        info->version     = caps.version;
        info->irq_capable = caps.irq;
        info->irq_sources = caps.irq_sources;
    }
    return 0;
}

/*
 * rtlnet_h264_ctl_close -- see the header
 */
void rtlnet_h264_ctl_close(void)
{
    if (g.is_open && (g.irq_capable != 0u)) {
        g.notify_active = 0u;
        (void)rtlnet_h264_enc_irq_global(g.base, 0);
        (void)rtlnet_h264_enc_irq_set_enable(g.base, 0u);
    }
    g.notify_active = 0u;
    g.is_open = 0;
}

/*
 * rtlnet_h264_ctl_set_notify -- see the header
 */
uint32_t rtlnet_h264_ctl_set_notify(uint32_t mode)
{
    g.notify_wanted = (mode == RTLNET_H264_NOTIFY_INTERRUPT) ? RTLNET_H264_NOTIFY_INTERRUPT : RTLNET_H264_NOTIFY_POLLED;
    if (g.is_open) {
        apply_notify();
    }
    return rtlnet_h264_ctl_notify();
}

/* The mode in force: the interrupt mode only on a core that has the registers and while open. */
uint32_t rtlnet_h264_ctl_notify(void)
{
    if (g.is_open) {
        return (g.notify_active != 0u) ? RTLNET_H264_NOTIFY_INTERRUPT : RTLNET_H264_NOTIFY_POLLED;
    }
    return g.notify_wanted;
}

uint32_t rtlnet_h264_ctl_notify_wanted(void)
{
    return g.notify_wanted;
}

int rtlnet_h264_ctl_irq_capable(void)
{
    return (g.irq_capable != 0u) ? 1 : 0;
}

/*
 * read_entries -- find the picture entry of every engine and the access unit delimiter.
 * Steps: for each engine read the index records from scan_idx up to the index write pointer through read_mem until a picture entry (kind bit)
 * is found: its offset and length are the engine's bytes of the picture; check the share bounds; read the delimiter at the start of engine 0's
 * data and check it is 00 00 00 01 09; fill the read-pointer targets; advance scan_idx.
 * Returns: 1 when valid, 0 otherwise (scan_idx unchanged).
 */
static uint32_t read_entries(rtlnet_h264_ctl_picture_t *p)
{
    uint32_t idx_share = g.layout.idx_entries / g.engines;
    uint32_t share = g.layout.ring_size / g.engines;
    uint32_t new_idx[RTLNET_H264_CTL_MAX_ENGINES];

    if ((g.ops.read_mem == NULL) || (g.mode == RTLNET_H264_CTL_MODE_NONE)) {
        return 0u;
    }
    for (uint32_t e = 0u; e < g.engines; e++) {
        uint32_t wptr = rtlnet_h264_enc_index_wptr(g.base + ENGINE_WINDOW_BYTES * e);
        uint32_t r = g.scan_idx[e];
        int found = 0;

        while ((r != wptr) && !found) {
            uint8_t raw[RTLNET_H264_IDX_WORDS * 4u];   /* the entry words at the start of the 128-byte record */
            uint32_t w[4];
            rtlnet_h264_enc_index_entry_t ent;

            if (g.ops.read_mem(g.ops.ctx, g.layout.idx_base + RTLNET_H264_IDX_ENTRY_BYTES * (e * idx_share + r), raw, sizeof(raw)) != 0) {
                return 0u;
            }
            for (uint32_t i = 0u; i < 4u; i++) {
                w[i] = (uint32_t)raw[4u * i] | ((uint32_t)raw[4u * i + 1u] << 8) | ((uint32_t)raw[4u * i + 2u] << 16) |
                       ((uint32_t)raw[4u * i + 3u] << 24);
            }
            rtlnet_h264_enc_decode_index_entry(w, &ent);
            r = (r + 1u) % idx_share;
            if (ent.is_picture) {
                p->off[e] = ent.offset;
                p->len[e] = ent.length;
                found = 1;
            }
        }
        if (!found || (p->off[e] >= share) || (p->len[e] > share)) {
            return 0u;
        }
        new_idx[e] = r;
    }
    if (p->len[0] < RTLNET_H264_CTL_AUD_BYTES) {
        return 0u;
    }
    if (g.ops.read_mem(g.ops.ctx, g.layout.ring_base + p->off[0], p->aud, RTLNET_H264_CTL_AUD_BYTES) != 0) {
        return 0u;
    }
    if ((p->aud[0] != 0u) || (p->aud[1] != 0u) || (p->aud[2] != 0u) || (p->aud[3] != 1u) || (p->aud[4] != 0x09u)) {
        return 0u;
    }
    p->engines = g.engines;
    for (uint32_t e = 0u; e < g.engines; e++) {
        p->size_bytes += p->len[e];
        p->ring_end[e] = (p->off[e] + p->len[e]) % share;
        p->idx_end[e] = new_idx[e];
        g.scan_idx[e] = new_idx[e];
    }
    return 1u;
}

/*
 * refresh_params -- write the SPS and PPS for the profile in force.
 */
static void refresh_params(void)
{
    (void)rtlnet_h264_enc_write_sps_pps_tools(g.sps_pps, sizeof(g.sps_pps), &g.sps_cfg, rtlnet_h264_ctl_profile_in_force(),
                                              rtlnet_h264_ctl_transform8x8_in_force(), &g.sps_len);
}

/*
 * turnaround -- a picture completed or failed (the service in interrupt mode, the poll function in polled mode).
 * Steps (as the polled firmware did): on ERR read ERR_CODE, clear the flags, report; otherwise clear DONE, swap the rebuilt buffers (the picture
 * just rebuilt is the reference of the next one), take the profile change note (a change reported by the interrupt, or HP_STATUS.CHG read and cleared
 * here: the encoder coded a forced IDR picture, the stream parameters are rewritten for the profile now in force), collect the entries and report.
 */
static void turnaround(uint32_t err)
{
    rtlnet_h264_ctl_picture_t p;

    if (err != 0u) {
        uint32_t code = rtlnet_reg_read32(g.base, RTLNET_H264_REG_ERR_CODE);

        rtlnet_h264_enc_clear_status(g.base);
        g.errors++;
        if (g.ops.picture_error != NULL) {
            g.ops.picture_error(g.ops.ctx, code);
        }
        return;
    }
    rtlnet_h264_enc_clear_status(g.base);
    rtlnet_h264_enc_buffers_end(&g.bufs);
    memset(&p, 0, sizeof(p));
    p.forced_idr = (g.chg_seen != 0u) ? 1u : 0u;
    if ((g.hp_seam != 0u) && (rtlnet_h264_enc_hp_clear_change(g.base) == 1)) {
        p.forced_idr = 1u;
    }
    if (p.forced_idr != 0u) {
        refresh_params();
    }
    p.qp = g.qp_used;
    p.pic_type = g.pic_type;
    p.valid = read_entries(&p);
    g.pictures++;
    if (g.ops.picture_done != NULL) {
        g.ops.picture_done(g.ops.ctx, &p);
    }
}

/*
 * rtlnet_h264_ctl_irq_service -- see the header
 */
void rtlnet_h264_ctl_irq_service(void)
{
    uint32_t st;

    if (g.notify_active == 0u) {
        return;
    }
    st = rtlnet_h264_enc_irq_status(g.base) & IRQ_USED & g.irq_sources;
    if (st == 0u) {
        g.spurious++;
        return;
    }
    rtlnet_h264_enc_irq_ack(g.base, st);
    g.irqs++;
    for (uint32_t s = 0u; s < RTLNET_H264_CTL_SRC_COUNT; s++) {
        if ((st & (1u << s)) != 0u) {
            g.source[s]++;
        }
    }
    if ((st & RTLNET_H264_IRQ_PROFILE_CHG) != 0u) {
        g.chg_seen = 1u;
    }
    if ((st & RTLNET_H264_IRQ_ERR) != 0u) {
        turnaround(1u);          /* an error wins over done, as in the polled method */
    } else if ((st & RTLNET_H264_IRQ_PIC_DONE) != 0u) {
        turnaround(0u);
    }
}

/*
 * rtlnet_h264_ctl_poll -- see the header
 */
int rtlnet_h264_ctl_poll(void)
{
    uint32_t status;

    if (g.notify_active != 0u) {
        return -1;
    }
    status = rtlnet_h264_enc_status(g.base);
    if ((status & (RTLNET_H264_STATUS_DONE | RTLNET_H264_STATUS_ERR)) == 0u) {
        return 0;
    }
    if ((status & RTLNET_H264_STATUS_ERR) != 0u) {
        g.source[RTLNET_H264_CTL_SRC_ERR]++;
        turnaround(1u);
    } else {
        g.source[RTLNET_H264_CTL_SRC_PIC_DONE]++;
        turnaround(0u);
    }
    return 1;
}

/*
 * rtlnet_h264_ctl_irq_stats -- see the header
 */
void rtlnet_h264_ctl_irq_stats(rtlnet_h264_ctl_irq_stats_t *out)
{
    memset(out, 0, sizeof(*out));
    out->irqs = g.irqs;
    out->spurious = g.spurious;
    for (uint32_t s = 0u; s < RTLNET_H264_CTL_SRC_COUNT; s++) {
        out->source[s] = g.source[s];
    }
    out->pictures = g.pictures;
    out->errors = g.errors;
    out->notify = rtlnet_h264_ctl_notify();
    out->irq_capable = g.irq_capable;
}

void rtlnet_h264_ctl_irq_stats_clear(void)
{
    g.irqs = 0u;
    g.spurious = 0u;
    for (uint32_t s = 0u; s < RTLNET_H264_CTL_SRC_COUNT; s++) {
        g.source[s] = 0u;
        g.seen[s] = 0u;
    }
    g.pictures = 0u;
    g.errors = 0u;
}

/*
 * rtlnet_h264_ctl_take_events -- see the header
 */
uint32_t rtlnet_h264_ctl_take_events(void)
{
    uint32_t m = 0u;

    for (uint32_t s = 0u; s < RTLNET_H264_CTL_SRC_COUNT; s++) {
        uint32_t now = g.source[s];

        if ((now != g.seen[s]) && (s != RTLNET_H264_CTL_SRC_PIC_DONE) && (s != RTLNET_H264_CTL_SRC_ERR)) {
            m |= 1u << s;
        }
        g.seen[s] = now;
    }
    return m;
}

int rtlnet_h264_ctl_irq_force(uint32_t mask)
{
    return rtlnet_h264_enc_irq_force(g.base, mask);
}

uint32_t rtlnet_h264_ctl_mode_of(uint32_t width, uint32_t height)
{
    if ((width == 1280u) && (height == 720u)) {
        return RTLNET_H264_CTL_MODE_720P30;
    }
    if ((width == 1920u) && (height == 1080u)) {
        return RTLNET_H264_CTL_MODE_1080P30;
    }
    return RTLNET_H264_CTL_MODE_NONE;
}

int rtlnet_h264_ctl_mode_info(uint32_t mode, rtlnet_h264_ctl_mode_t *out)
{
    rtlnet_h264_enc_mode_t m;

    if ((out == NULL) || (rtlnet_h264_enc_get_mode(mode, &m) != 0)) {
        return -1;
    }
    out->mb_w = m.mb_w;
    out->mb_h = m.mb_h;
    out->width = m.width;
    out->height = m.height;
    out->display_width = m.display_width;
    out->display_height = m.display_height;
    return 0;
}

/*
 * rtlnet_h264_ctl_set_mode -- see the header
 * Steps: apply the transform request (default off; a module without the adaptive choice degrades auto to on); size registers and the SPS/PPS bytes from the
 * driver; the configuration registers with the memory layout; ring reset; the index scan positions restart.
 */
int rtlnet_h264_ctl_set_mode(uint32_t mode, uint32_t qp)
{
    rtlnet_h264_enc_cfg_t cfg;
    rtlnet_h264_enc_mode_t m;

    if (rtlnet_h264_enc_set_transform8x8(g.base, (int)g.t8_pref) == RTLNET_H264_HP_ERR_NO_AUTO) {
        (void)rtlnet_h264_enc_set_transform8x8(g.base, RTLNET_H264_T8_ON);
    }
    if ((rtlnet_h264_enc_get_mode(mode, &m) != 0) || (rtlnet_h264_enc_set_mode(g.base, mode, &g.sps_cfg) != 0) ||
        (rtlnet_h264_enc_write_sps_pps_tools(g.sps_pps, sizeof(g.sps_pps), &g.sps_cfg, rtlnet_h264_ctl_profile_in_force(),
                                             rtlnet_h264_ctl_transform8x8_in_force(), &g.sps_len) != 0)) {
        return -1;
    }
    memset(&cfg, 0, sizeof(cfg));
    cfg.mb_w = m.mb_w;
    cfg.mb_h = m.mb_h;
    cfg.slices = g.engines;
    cfg.qp = qp;
    cfg.log2_max_frame_num = g.layout.log2_max_frame_num;
    cfg.in_base = 0u;
    cfg.in_stride = m.width * 2u;
    cfg.ry_base = g.layout.ry_base[0];
    cfg.ru_base = g.layout.ru_base[0];
    cfg.ring_base = g.layout.ring_base;
    cfg.ring_size = g.layout.ring_size;
    cfg.idx_base = g.layout.idx_base;
    cfg.idx_entries = g.layout.idx_entries;
    if (rtlnet_h264_enc_configure(g.base, &cfg) != 0) {
        return -1;
    }
    rtlnet_h264_enc_ring_reset(g.base);
    memset(g.scan_idx, 0, sizeof(g.scan_idx));
    g.mode = mode;
    (void)rtlnet_h264_ctl_mode_info(mode, &g.minfo);
    return 0;
}

void rtlnet_h264_ctl_params(const uint8_t **bytes, uint32_t *len)
{
    *bytes = g.sps_pps;
    *len = (uint32_t)g.sps_len;
}

/*
 * rtlnet_h264_ctl_start_picture -- see the header
 * Steps: the full configuration with this picture's QP and input (the driver checks the rules), the QP read back, the rebuilt and reference bases of
 * the two buffers, the profile-change note cleared (the core reports a change at the start), then PIC_CFG, frame_num, idr_pic_id and START.
 */
int rtlnet_h264_ctl_start_picture(const rtlnet_h264_ctl_start_t *s, uint32_t *qp_used)
{
    rtlnet_h264_enc_cfg_t cfg;

    if ((s == NULL) || (g.mode == RTLNET_H264_CTL_MODE_NONE)) {
        return -1;
    }
    memset(&cfg, 0, sizeof(cfg));
    cfg.mb_w = g.minfo.mb_w;
    cfg.mb_h = g.minfo.mb_h;
    cfg.slices = g.engines;
    cfg.qp = s->qp;
    cfg.log2_max_frame_num = g.layout.log2_max_frame_num;
    cfg.in_base = s->in_base;
    cfg.in_stride = s->in_stride;
    cfg.ry_base = g.layout.ry_base[0];
    cfg.ru_base = g.layout.ru_base[0];
    cfg.ring_base = g.layout.ring_base;
    cfg.ring_size = g.layout.ring_size;
    cfg.idx_base = g.layout.idx_base;
    cfg.idx_entries = g.layout.idx_entries;
    if (rtlnet_h264_enc_configure(g.base, &cfg) != 0) {
        return -1;
    }
    g.qp_used = rtlnet_reg_read32(g.base, RTLNET_H264_REG_QP);
    if (qp_used != NULL) {
        *qp_used = g.qp_used;
    }
    g.chg_seen = 0u;
    g.pic_type = s->pic_type;
    if ((rtlnet_h264_enc_buffers_begin(g.base, &g.bufs, s->pic_type) != 0) ||
        (rtlnet_h264_enc_start_picture_ex(g.base, s->frame_num, s->idr_pic_id, s->pic_type) != 0)) {
        return -2;
    }
    return 0;
}

uint32_t rtlnet_h264_ctl_next_frame_num(uint32_t prev)
{
    return rtlnet_h264_enc_next_frame_num(prev, g.layout.log2_max_frame_num);
}

void rtlnet_h264_ctl_release(uint32_t engine, uint32_t ring_end, uint32_t idx_end)
{
    rtlnet_h264_enc_set_read_pointers(g.base + ENGINE_WINDOW_BYTES * engine, ring_end, idx_end);
}

void rtlnet_h264_ctl_reset_session(void)
{
    (void)rtlnet_h264_enc_buffers_init(&g.bufs, g.layout.ry_base[0], g.layout.ru_base[0], g.layout.ry_base[1], g.layout.ru_base[1]);
}

int rtlnet_h264_ctl_has_reference(void)
{
    return (g.bufs.has_ref != 0u) ? 1 : 0;
}

static void hp_copy(const rtlnet_h264_enc_hp_t *in, rtlnet_h264_ctl_hp_t *out)
{
    out->present = in->present;
    out->licensed = in->licensed;
    out->active = in->active;
    out->enabled = in->enabled;
    out->t8_enabled = in->t8_enabled;
    out->t8_auto = in->t8_auto;
    out->profile_chg = in->profile_chg;
    out->caps = in->caps;
    out->seconds_left = in->seconds_left;
}

int rtlnet_h264_ctl_set_profile(int high)
{
    return rtlnet_h264_enc_set_profile(g.base, high);
}

/* 0, or RTLNET_H264_CTL_HP_ERR_NO_SEAM when the build has no High profile registers. */
int rtlnet_h264_ctl_hp_info(rtlnet_h264_ctl_hp_t *out)
{
    rtlnet_h264_enc_hp_t hp;
    int rc;

    if (out == NULL) {
        return -1;
    }
    rc = rtlnet_h264_enc_hp_status(g.base, &hp);
    if (rc == 0) {
        hp_copy(&hp, out);
    }
    return rc;
}

/*
 * rtlnet_h264_ctl_profile_in_force -- 1 when pictures are coded in the High profile (CABAC): the module is present and licensed, enabled in HP_CTRL
 * and offers CABAC. Builds without the seam, with the stub or with hp_caps 0 return 0.
 */
int rtlnet_h264_ctl_profile_in_force(void)
{
    rtlnet_h264_enc_hp_t hp;

    if (rtlnet_h264_enc_hp_status(g.base, &hp) != 0) {
        return 0;
    }
    return ((hp.present != 0u) && (hp.licensed != 0u) && (hp.enabled != 0u) && ((hp.caps & RTLNET_H264_HP_CAP_CABAC) != 0u)) ? 1 : 0;
}

/*
 * rtlnet_h264_ctl_transform8x8_in_force -- 1 when the pictures use the 8x8 transform: the High profile is in force, the request bit is set and the
 * module offers the transform. The PPS then has transform_8x8_mode_flag 1.
 */
int rtlnet_h264_ctl_transform8x8_in_force(void)
{
    rtlnet_h264_enc_hp_t hp;

    if ((rtlnet_h264_ctl_profile_in_force() == 0) || (rtlnet_h264_enc_hp_status(g.base, &hp) != 0)) {
        return 0;
    }
    return ((hp.t8_enabled != 0u) && ((hp.caps & RTLNET_H264_HP_CAP_TRANSFORM8X8) != 0u)) ? 1 : 0;
}

int rtlnet_h264_ctl_set_transform8x8(int mode)
{
    int m = (mode == RTLNET_H264_T8_AUTO) ? RTLNET_H264_T8_AUTO : ((mode != 0) ? 1 : 0);
    int rc = rtlnet_h264_enc_set_transform8x8(g.base, m);

    if (rc == 0) {
        g.t8_pref = (uint32_t)m;
    }
    return rc;
}

int rtlnet_h264_ctl_transform8x8_wanted(void)
{
    return (int)g.t8_pref;
}

int rtlnet_h264_ctl_transform8x8_counts(uint32_t *n8, uint32_t *n4)
{
    return rtlnet_h264_enc_t8_counts(g.base, n8, n4);
}

/*
 * rtlnet_h264_ctl_debug -- see the header
 */
int rtlnet_h264_ctl_debug(rtlnet_h264_ctl_debug_t *out)
{
    rtlnet_h264_enc_caps_t caps;
    uint32_t status;

    if ((out == NULL) || (rtlnet_h264_enc_probe(g.base, &caps) != 0)) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    out->version = caps.version;
    out->engines = caps.num_engines;
    out->max_mb_w = caps.max_mb_w;
    out->max_mb_h = caps.max_mb_h;
    out->hp_seam = caps.hp_seam;
    status = rtlnet_h264_enc_status(g.base);
    out->busy = ((status & RTLNET_H264_STATUS_BUSY) != 0u) ? 1u : 0u;
    out->done = ((status & RTLNET_H264_STATUS_DONE) != 0u) ? 1u : 0u;
    out->err = ((status & RTLNET_H264_STATUS_ERR) != 0u) ? 1u : 0u;
    out->ring_stall = ((status & RTLNET_H264_STATUS_RING_STALL) != 0u) ? 1u : 0u;
    out->err_code = rtlnet_reg_read32(g.base, RTLNET_H264_REG_ERR_CODE);
    out->pic_count = rtlnet_reg_read32(g.base, RTLNET_H264_REG_PIC_COUNT);
    out->slice_count = rtlnet_reg_read32(g.base, RTLNET_H264_REG_SLICE_COUNT);
    out->irq_capable = caps.irq;
    if (caps.irq != 0u) {
        out->irq_status = rtlnet_h264_enc_irq_status(g.base);
        out->irq_enable = rtlnet_h264_enc_irq_get_enable(g.base);
        out->irq_global = ((rtlnet_reg_read32(g.base, RTLNET_H264_REG_CTRL) & RTLNET_H264_CTRL_IRQ_EN) != 0u) ? 1u : 0u;
    }
    for (uint32_t e = 0u; (e < caps.num_engines) && (e < RTLNET_H264_CTL_MAX_ENGINES); e++) {
        rtlnet_h264_enc_stats_t t;

        rtlnet_h264_enc_read_stats(g.base + ENGINE_WINDOW_BYTES * e, &t);
        out->eng[e].mb_count = t.mb_count;
        out->eng[e].cyc_last = t.cyc_last;
        out->eng[e].cyc_max = t.cyc_max;
        out->eng[e].pic_cyc = t.pic_cyc;
        out->eng[e].rd_cyc = t.rd_cyc;
        out->eng[e].pk_cyc = t.pk_cyc;
        out->eng[e].wr_cyc = t.wr_cyc;
    }
    return 0;
}
