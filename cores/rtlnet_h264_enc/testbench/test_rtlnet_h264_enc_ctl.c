/*
 * test_rtlnet_h264_enc_ctl.c -- host unit test of the H.264 encoder control layer (rtlnet_h264_enc_ctl.c)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs driver/rtlnet_h264_enc_ctl.c and rtlnet_h264_enc.c on the PC against a functional model of the core: configuration registers, START
 * with a busy time counted in model ticks, the picture entries and delimiter written into a DDR3 array, STATUS and its write-1-to-clear flags,
 * IRQ_STATUS / IRQ_ENABLE / IRQ_FORCE, CTRL.IRQ_EN and the irq line, a High profile status with PROFILE_CHG, and an older core without the
 * interrupt registers. An interrupt controller model calls rtlnet_h264_ctl_irq_service() while the line is high.
 * Checks: both notification modes produce the same picture result (sizes, pointers, QP, delimiter); the interrupt mode acknowledges IRQ_STATUS,
 * counts per source and leaves the legacy STATUS flags cleared; the polled mode leaves the core's interrupts disabled and reads STATUS; the
 * interrupt request degrades to polled on an older core; errors win over done; an invalid entry reports valid 0; ring stall, profile change and
 * license lost are counted and reported by take_events; a forced IDR picture rewrites the stream parameters; the buffers alternate; release
 * writes the read pointers; the mode switch programs the interrupt registers; force gives a spurious-free self-test.
 * Prints "CTL TEST PASS: rtlnet_h264_enc_ctl checks=<n>" or "CTL TEST FAIL: ..." and returns 0 / 1. -DINJECT_FAILURE: forces one failed check.
 */
#include "rtlnet_h264_enc.h"
#include "rtlnet_h264_enc_ctl.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */
#include <string.h>   /* memset, memcmp */

#define TEST_BASE     0x44A08000u
#define TEST_WINDOW   0x1000u
#define NENG          2u
#define DDR_BYTES     0x40000u

#define RING_BASE     0x1000u
#define RING_SIZE     0x4000u
#define IDX_BASE      0x20000u
#define IDX_ENTRIES   16u

static uint32_t g_reg[4u * TEST_WINDOW / 4u];     /* the window, and room for the engine windows' own registers */
static uint8_t  g_ddr[DDR_BYTES];
static int      g_checks;
static int      g_fails;

/* Model of the core. */
static uint32_t g_irq_impl;        /* implemented interrupt sources; 0 with no interrupt registers (an older core) */
static int      g_new_core;        /* 1: VERSION with the interrupt registers */
static int      g_seam;            /* 1: High profile registers */
static int      g_dbk_build = 1;   /* 1: the deblocking filter is built (CAPS bit 22) on a core with the current VERSION */
static uint32_t g_wr_dbk;          /* writes to DBK_CTRL seen */
static uint32_t g_busy_ticks;      /* ticks left of the picture in progress */
static uint32_t g_pic_ticks = 3u;  /* ticks a picture takes */
static uint32_t g_ring_w[NENG];
static uint32_t g_idx_w[NENG];
static uint32_t g_pic_no;
static uint32_t g_payload = 100u;  /* bytes per engine of the next picture */
static int      g_bad_aud;         /* the next picture's delimiter is wrong */
static uint32_t g_hp_chg_next;     /* the next start reports a profile change */
static uint32_t g_wr_log_irq_en;   /* writes to IRQ_ENABLE seen */

static void check(int cond, const char *what)
{
    g_checks++;
    if (!cond) {
        g_fails++;
        printf("CHECK FAILED: %s\n", what);
    }
}

static uint32_t reg(uint32_t off)
{
    return g_reg[off / 4u];
}

static uint32_t w32(uint32_t off, uint32_t v)
{
    g_reg[off / 4u] = v;
    return v;
}

static uint32_t st_get(void)
{
    return (g_busy_ticks != 0u ? RTLNET_H264_STATUS_BUSY : 0u) | (reg(RTLNET_H264_REG_STATUS) & (RTLNET_H264_STATUS_DONE | RTLNET_H264_STATUS_ERR));
}

static void ev_irq(uint32_t bits)
{
    w32(RTLNET_H264_REG_IRQ_STATUS, reg(RTLNET_H264_REG_IRQ_STATUS) | (bits & g_irq_impl));
}

static void ev_error(uint32_t code)
{
    w32(RTLNET_H264_REG_STATUS, reg(RTLNET_H264_REG_STATUS) | RTLNET_H264_STATUS_ERR);
    if (reg(RTLNET_H264_REG_ERR_CODE) == 0u) {
        w32(RTLNET_H264_REG_ERR_CODE, code);
    }
    ev_irq(RTLNET_H264_IRQ_ERR);
}

/* Write the picture's entries and bytes at the end of the picture: one slice entry and one picture entry per engine. */
static void finish_picture(void)
{
    uint32_t share = RING_SIZE / NENG;
    uint32_t ishare = IDX_ENTRIES / NENG;

    for (uint32_t e = 0u; e < NENG; e++) {
        uint32_t off = g_ring_w[e];
        uint32_t len = g_payload + (e == 0u ? RTLNET_H264_CTL_AUD_BYTES : 0u);
        uint32_t rec;
        static const uint8_t aud[6] = {0u, 0u, 0u, 1u, 0x09u, 0xF0u};

        for (uint32_t i = 0u; i < len; i++) {
            g_ddr[RING_BASE + e * share + ((off + i) % share)] = (uint8_t)(g_pic_no * 7u + e * 3u + i);
        }
        if (e == 0u) {
            for (uint32_t i = 0u; i < 6u; i++) {
                g_ddr[RING_BASE + ((off + i) % share)] = g_bad_aud ? 0xAAu : aud[i];
            }
        }
        for (uint32_t k = 0u; k < 2u; k++) {
            uint32_t *w;

            rec = IDX_BASE + 128u * (e * ishare + g_idx_w[e]);
            w = (uint32_t *)&g_ddr[rec];
            w[0] = off;
            w[1] = len;
            w[2] = (g_pic_no & 0xFFFFu) | (k << 16);
            w[3] = (k == 1u ? RTLNET_H264_IDX_KIND_PICTURE : 0u) | 7u;
            g_idx_w[e] = (g_idx_w[e] + 1u) % ishare;
        }
        g_ring_w[e] = (off + len + 15u) / 16u * 16u % share;
        w32(0x100u * e + RTLNET_H264_REG_IDX_WPTR, g_idx_w[e]);
        w32(0x100u * e + RTLNET_H264_REG_RING_WPTR, g_ring_w[e]);
    }
    g_bad_aud = 0;
    g_pic_no++;
    w32(RTLNET_H264_REG_STATUS, reg(RTLNET_H264_REG_STATUS) | RTLNET_H264_STATUS_DONE);
    ev_irq(RTLNET_H264_IRQ_PIC_DONE);
}

static void model_reset(int new_core, uint32_t impl, int seam)
{
    memset(g_reg, 0, sizeof(g_reg));
    memset(g_ddr, 0, sizeof(g_ddr));
    g_new_core = new_core;
    g_irq_impl = new_core ? impl : 0u;
    g_seam = seam;
    g_busy_ticks = 0u;
    for (uint32_t e = 0u; e < NENG; e++) {
        g_ring_w[e] = 0u;
        g_idx_w[e] = 0u;
    }
    g_pic_no = 0u;
    g_payload = 100u;
    g_bad_aud = 0;
    g_hp_chg_next = 0u;
    g_wr_log_irq_en = 0u;
    g_wr_dbk = 0u;
    w32(RTLNET_REG_ID, RTLNET_H264_ID_VALUE);
    w32(RTLNET_REG_VERSION, new_core ? RTLNET_H264_VERSION_VALUE : RTLNET_H264_VERSION_PRE_IRQ);
    w32(RTLNET_REG_CAPS, 120u | (68u << 8) | (NENG << 16) | (seam ? RTLNET_H264_CAPS_HP_SEAM : 0u) |
                         (new_core ? (RTLNET_H264_CAPS_IRQ | (impl << RTLNET_H264_CAPS_IRQ_SRC_SHIFT)) : 0u) |
                         ((new_core && g_dbk_build) ? RTLNET_H264_CAPS_DBK : 0u));
    if (new_core && g_dbk_build) {   /* reset: enable 1, offsets 0; DBK_STATUS reports the filter present */
        w32(RTLNET_H264_REG_DBK_CTRL, RTLNET_H264_DBK_CTRL_ENABLE);
        w32(RTLNET_H264_REG_DBK_STATUS, RTLNET_H264_DBK_STATUS_PRESENT);
    }
    if (seam) {
        w32(RTLNET_H264_REG_HP_STATUS, RTLNET_H264_HP_STATUS_PRESENT | RTLNET_H264_HP_STATUS_LICENSED | (RTLNET_H264_HP_CAP_CABAC << RTLNET_H264_HP_STATUS_CAPS_SHIFT) |
                                       (600u << RTLNET_H264_HP_STATUS_SEC_SHIFT));
    }
}

static int core_irq(void)
{
    return ((reg(RTLNET_H264_REG_CTRL) & RTLNET_H264_CTRL_IRQ_EN) != 0u) && ((reg(RTLNET_H264_REG_IRQ_STATUS) & reg(RTLNET_H264_REG_IRQ_ENABLE)) != 0u);
}

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);

    if ((addr < TEST_BASE) || (off >= TEST_WINDOW) || ((off & 3u) != 0u)) {
        g_fails++;
        printf("CHECK FAILED: register read outside the window 0x%lx\n", (unsigned long)addr);
        return 0u;
    }
    if (off == RTLNET_H264_REG_STATUS) {
        return st_get();
    }
    if ((off >= RTLNET_H264_REG_IRQ_STATUS) && (off <= RTLNET_H264_REG_IRQ_FORCE) && !g_new_core) {
        return 0u;
    }
    if (off == RTLNET_H264_REG_IRQ_FORCE) {
        return 0u;
    }
    return reg(off);
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);

    if ((addr < TEST_BASE) || (off >= TEST_WINDOW) || ((off & 3u) != 0u)) {
        g_fails++;
        printf("CHECK FAILED: register write outside the window 0x%lx\n", (unsigned long)addr);
        return;
    }
    if ((off >= RTLNET_H264_REG_IRQ_STATUS) && (off <= RTLNET_H264_REG_IRQ_FORCE) && !g_new_core) {
        g_fails++;
        printf("CHECK FAILED: interrupt register written on a core that has none (0x%x)\n", (unsigned)off);
        return;
    }
    switch (off) {
    case RTLNET_H264_REG_STATUS:
        w32(off, reg(off) & ~(value & (RTLNET_H264_STATUS_DONE | RTLNET_H264_STATUS_ERR)));
        if ((value & RTLNET_H264_STATUS_ERR) != 0u) {
            w32(RTLNET_H264_REG_ERR_CODE, 0u);
        }
        return;
    case RTLNET_H264_REG_IRQ_STATUS:
        w32(off, reg(off) & ~value);
        return;
    case RTLNET_H264_REG_IRQ_FORCE:
        ev_irq(value);
        return;
    case RTLNET_H264_REG_IRQ_ENABLE:
        g_wr_log_irq_en++;
        w32(off, value & g_irq_impl);
        return;
    case RTLNET_H264_REG_DBK_STATUS:
        return;   /* read only */
    case RTLNET_H264_REG_DBK_CTRL:
        g_wr_dbk++;
        if ((reg(RTLNET_REG_CAPS) & RTLNET_H264_CAPS_DBK) != 0u) {   /* the core's rules: enable, two offset fields of -6..+6, the rest reads 0 */
            uint32_t nv = value & RTLNET_H264_DBK_CTRL_ENABLE;

            for (uint32_t sh = RTLNET_H264_DBK_CTRL_ALPHA_SHIFT; sh <= RTLNET_H264_DBK_CTRL_BETA_SHIFT; sh += 4u) {
                uint32_t fld = (value >> sh) & 0xFu;
                int      sv = (fld >= 8u) ? ((int)fld - 16) : (int)fld;

                nv |= ((sv >= -6) && (sv <= 6)) ? (fld << sh) : (reg(off) & (0xFu << sh));
            }
            w32(off, nv);
        }
        return;
    case RTLNET_H264_REG_HP_CTRL:
        w32(off, value);
        w32(RTLNET_H264_REG_HP_STATUS, (reg(RTLNET_H264_REG_HP_STATUS) & ~RTLNET_H264_HP_STATUS_ENABLED) | (((value & 1u) != 0u) ? RTLNET_H264_HP_STATUS_ENABLED : 0u));
        return;
    case RTLNET_H264_REG_HP_STATUS:
        if ((value & RTLNET_H264_HP_STATUS_CHG) != 0u) {
            w32(off, reg(off) & ~RTLNET_H264_HP_STATUS_CHG);
        }
        return;
    case RTLNET_H264_REG_CTRL:
        w32(off, value & RTLNET_H264_CTRL_IRQ_EN);
        if ((value & RTLNET_H264_CTRL_RING_RESET) != 0u) {
            for (uint32_t e = 0u; e < NENG; e++) {
                g_ring_w[e] = 0u;
                g_idx_w[e] = 0u;
                w32(0x100u * e + RTLNET_H264_REG_IDX_WPTR, 0u);
                w32(0x100u * e + RTLNET_H264_REG_RING_WPTR, 0u);
            }
        }
        if ((value & RTLNET_H264_CTRL_START) != 0u) {
            if (g_busy_ticks != 0u) {
                ev_error(RTLNET_H264_ERR_BUSY);
            } else {
                g_busy_ticks = g_pic_ticks;
                if ((reg(RTLNET_REG_CAPS) & RTLNET_H264_CAPS_DBK) != 0u) {   /* DBK_CTRL is latched at START */
                    uint32_t cur = reg(RTLNET_H264_REG_DBK_CTRL);

                    w32(RTLNET_H264_REG_DBK_STATUS, RTLNET_H264_DBK_STATUS_PRESENT | (((cur & RTLNET_H264_DBK_CTRL_ENABLE) != 0u) ? RTLNET_H264_DBK_STATUS_APPLIED : 0u) |
                                                    (((cur >> RTLNET_H264_DBK_CTRL_ALPHA_SHIFT) & 0xFu) << RTLNET_H264_DBK_STATUS_ALPHA_SHIFT) |
                                                    (((cur >> RTLNET_H264_DBK_CTRL_BETA_SHIFT) & 0xFu) << RTLNET_H264_DBK_STATUS_BETA_SHIFT));
                }
                ev_irq(RTLNET_H264_IRQ_PIC_START);
                if (g_hp_chg_next != 0u) {
                    w32(RTLNET_H264_REG_HP_STATUS, reg(RTLNET_H264_REG_HP_STATUS) | RTLNET_H264_HP_STATUS_CHG);
                    ev_irq(RTLNET_H264_IRQ_PROFILE_CHG);
                    g_hp_chg_next = 0u;
                }
            }
        }
        return;
    default:
        w32(off, value);
        return;
    }
}

/* One model tick: the picture in progress advances; the interrupt controller calls the service while the line is high. */
static void tick(int intc)
{
    if (g_busy_ticks != 0u) {
        g_busy_ticks--;
        if (g_busy_ticks == 0u) {
            finish_picture();
        }
    }
    if (intc) {
        for (int n = 0; (n < 4) && core_irq(); n++) {
            rtlnet_h264_ctl_irq_service();
        }
    }
}

/* Callback records. */
static int                       g_cb_done;
static int                       g_cb_err;
static uint32_t                  g_cb_code;
static rtlnet_h264_ctl_picture_t g_cb_pic;

static void cb_done(void *ctx, const rtlnet_h264_ctl_picture_t *p)
{
    (void)ctx;
    g_cb_done++;
    g_cb_pic = *p;
}

static void cb_err(void *ctx, uint32_t code)
{
    (void)ctx;
    g_cb_err++;
    g_cb_code = code;
}

static int cb_read(void *ctx, uint32_t off, uint8_t *dst, uint32_t n)
{
    (void)ctx;
    if (off + n > DDR_BYTES) {
        return -1;
    }
    memcpy(dst, &g_ddr[off], n);
    return 0;
}

static const rtlnet_h264_ctl_layout_t k_layout = {
    RING_BASE, RING_SIZE, IDX_BASE, IDX_ENTRIES, {0x100000u, 0x300000u}, {0x200000u, 0x400000u}, 4u
};

static void setup(int new_core, uint32_t impl, int seam)
{
    rtlnet_h264_ctl_ops_t ops;

    model_reset(new_core, impl, seam);
    ops.picture_done = cb_done;
    ops.picture_error = cb_err;
    ops.read_mem = cb_read;
    ops.ctx = NULL;
    rtlnet_h264_ctl_init(TEST_BASE, &k_layout, &ops);
    g_cb_done = 0;
    g_cb_err = 0;
    g_cb_code = 0u;
    memset(&g_cb_pic, 0, sizeof(g_cb_pic));

}

static int start(uint32_t type, uint32_t fnum)
{
    rtlnet_h264_ctl_start_t s;
    uint32_t qp = 0u;
    int rc;

    s.in_base = 0x80000u;
    s.in_stride = 2560u;
    s.qp = 20u;
    s.pic_type = type;
    s.frame_num = fnum;
    s.idr_pic_id = 1u;
    rc = rtlnet_h264_ctl_start_picture(&s, &qp);
    return rc;
}

/* Run one picture to completion in the mode in force. Returns the picture callbacks seen. */
static int run_picture(uint32_t type, uint32_t fnum)
{
    int before = g_cb_done + g_cb_err;
    int mode_int = (rtlnet_h264_ctl_notify() == RTLNET_H264_NOTIFY_INTERRUPT);

    if (start(type, fnum) != 0) {
        return -100;
    }
    for (int n = 0; n < 20; n++) {
        tick(mode_int);
        if (!mode_int) {
            (void)rtlnet_h264_ctl_poll();
        }
        if ((g_cb_done + g_cb_err) != before) {
            break;
        }
    }
    return (g_cb_done + g_cb_err) - before;
}

int main(void)
{
    rtlnet_h264_ctl_info_t info;
    rtlnet_h264_ctl_irq_stats_t is;
    rtlnet_h264_ctl_picture_t ref_int;
    rtlnet_h264_ctl_picture_t ref_pol;

    /* Core absent: open refuses. */
    setup(1, 0x3Fu, 0);
    memset(g_reg, 0, sizeof(g_reg));
    check(rtlnet_h264_ctl_open(&info) == -1, "open: no core");

    /* Interrupt mode on a core with the registers. */
    setup(1, 0x3Fu, 1);
    check(rtlnet_h264_ctl_open(&info) == 0, "open");
    check((info.engines == NENG) && (info.irq_capable == 1u) && (info.irq_sources == 0x3Fu) && (info.hp_seam == 1u), "open: info");
    check(rtlnet_h264_ctl_notify() == RTLNET_H264_NOTIFY_INTERRUPT, "interrupt mode is the default");
    check(rtlnet_h264_ctl_transform8x8_wanted() == RTLNET_H264_CTL_T8_OFF, "the transform request is off (4x4) by default");
    check((reg(RTLNET_H264_REG_CTRL) & RTLNET_H264_CTRL_IRQ_EN) != 0u, "open: global enable set");
    check(reg(RTLNET_H264_REG_IRQ_ENABLE) == (RTLNET_H264_IRQ_PIC_DONE | RTLNET_H264_IRQ_ERR | RTLNET_H264_IRQ_RING_STALL |
                                              RTLNET_H264_IRQ_PROFILE_CHG | RTLNET_H264_IRQ_LICENSE_LOST),
          "open: sources enabled (PIC_START stays masked)");
    check(rtlnet_h264_ctl_mode_of(1280u, 720u) == RTLNET_H264_CTL_MODE_720P30 && rtlnet_h264_ctl_mode_of(640u, 480u) == RTLNET_H264_CTL_MODE_NONE, "mode_of");
    check(rtlnet_h264_ctl_set_mode(RTLNET_H264_CTL_MODE_720P30, 28u) == 0, "set_mode 720p");
    {
        const uint8_t *ps;
        uint32_t pl;
        rtlnet_h264_ctl_params(&ps, &pl);
        check((pl > 10u) && (ps[0] == 0u) && (ps[3] == 1u) && (ps[4] == 0x67u), "params: SPS first");
    }
    check(run_picture(RTLNET_H264_CTL_PIC_IDR, 0u) == 1, "interrupt: IDR picture done");
    check(g_cb_done == 1 && g_cb_err == 0, "interrupt: one done callback");
    check(g_cb_pic.valid == 1u && g_cb_pic.engines == NENG, "interrupt: result valid");
    check(g_cb_pic.len[0] == 100u + 6u && g_cb_pic.len[1] == 100u && g_cb_pic.size_bytes == 206u, "interrupt: sizes");
    check(g_cb_pic.off[0] == 0u && g_cb_pic.off[1] == 0u, "interrupt: offsets");
    check(g_cb_pic.idx_end[0] == 2u && g_cb_pic.idx_end[1] == 2u, "interrupt: index positions past the two entries");
    check(g_cb_pic.ring_end[0] == 106u && g_cb_pic.ring_end[1] == 100u, "interrupt: ring positions");
    check(g_cb_pic.qp == 20u && g_cb_pic.pic_type == RTLNET_H264_CTL_PIC_IDR && g_cb_pic.forced_idr == 0u, "interrupt: qp, type, not forced");
    check(g_cb_pic.aud[4] == 0x09u && g_cb_pic.aud[3] == 1u, "interrupt: delimiter");
    check((reg(RTLNET_H264_REG_IRQ_STATUS) & RTLNET_H264_IRQ_PIC_DONE) == 0u, "interrupt: IRQ_STATUS acknowledged");
    check((reg(RTLNET_H264_REG_STATUS) & RTLNET_H264_STATUS_DONE) == 0u, "interrupt: legacy DONE flag cleared too");
    check(core_irq() == 0, "interrupt: the line fell");
    rtlnet_h264_ctl_irq_stats(&is);
    check(is.irqs >= 1u && is.source[RTLNET_H264_CTL_SRC_PIC_DONE] == 1u && is.pictures == 1u && is.notify == RTLNET_H264_NOTIFY_INTERRUPT, "interrupt: counters");
    check(rtlnet_h264_ctl_has_reference() == 1, "interrupt: a reference exists after the first picture");
    ref_int = g_cb_pic;
    /* Release frees the ring and index. */
    rtlnet_h264_ctl_release(0u, g_cb_pic.ring_end[0], g_cb_pic.idx_end[0]);
    rtlnet_h264_ctl_release(1u, g_cb_pic.ring_end[1], g_cb_pic.idx_end[1]);
    check(reg(0x00u + RTLNET_H264_REG_RING_RPTR) == 106u && reg(0x100u + RTLNET_H264_REG_RING_RPTR) == 100u, "release: ring read pointers");
    check(reg(RTLNET_H264_REG_IDX_RPTR) == 2u && reg(0x100u + RTLNET_H264_REG_IDX_RPTR) == 2u, "release: index read pointers");
    /* A P picture reads the other buffer; the second picture's entries follow the first. */
    g_payload = 40u;
    check(run_picture(RTLNET_H264_CTL_PIC_P, 1u) == 1, "interrupt: P picture done");
    check(g_cb_pic.valid == 1u && g_cb_pic.len[0] == 46u && g_cb_pic.off[0] == 112u && g_cb_pic.idx_end[0] == 4u, "interrupt: second picture found after the first");
    check((reg(RTLNET_H264_REG_PIC_CFG) & RTLNET_H264_PIC_CFG_P) != 0u && reg(RTLNET_H264_REG_FRAME_NUM) == 1u, "P picture registers");
    check(reg(RTLNET_H264_REG_RY_BASE) == 0x300000u && reg(RTLNET_H264_REG_REFY_BASE) == 0x100000u, "buffers alternate: rebuilt B, reference A");

    /* Spurious: a service call with nothing pending. */
    rtlnet_h264_ctl_irq_stats(&is);
    {
        uint32_t sp = is.spurious;

        rtlnet_h264_ctl_irq_service();
        rtlnet_h264_ctl_irq_stats(&is);
        check(is.spurious == sp + 1u, "service with nothing pending counts spurious");
    }
    /* poll is refused in interrupt mode. */
    check(rtlnet_h264_ctl_poll() == -1, "poll in interrupt mode: -1");

    /* Error: the callback gets the code; the flags are cleared. */
    ev_error(RTLNET_H264_ERR_BUSY);
    tick(1);
    check(g_cb_err == 1 && g_cb_code == RTLNET_H264_ERR_BUSY, "error: callback with the error code");
    check((reg(RTLNET_H264_REG_STATUS) & RTLNET_H264_STATUS_ERR) == 0u && (reg(RTLNET_H264_REG_IRQ_STATUS) & RTLNET_H264_IRQ_ERR) == 0u, "error: flags cleared");
    check(g_cb_done == 2, "error: no done callback");
    rtlnet_h264_ctl_irq_stats(&is);
    check(is.errors == 1u && is.source[RTLNET_H264_CTL_SRC_ERR] == 1u, "error counters");
    /* An error wins over a done in the same service call (the polled method does the same). */
    w32(RTLNET_H264_REG_STATUS, reg(RTLNET_H264_REG_STATUS) | RTLNET_H264_STATUS_DONE);
    ev_irq(RTLNET_H264_IRQ_PIC_DONE);
    ev_error(RTLNET_H264_ERR_AXI);
    rtlnet_h264_ctl_irq_service();
    check(g_cb_err == 2 && g_cb_code == RTLNET_H264_ERR_AXI && g_cb_done == 2, "error wins over the done of the same service call");
    check((reg(RTLNET_H264_REG_STATUS) & (RTLNET_H264_STATUS_ERR | RTLNET_H264_STATUS_DONE)) == 0u && (reg(RTLNET_H264_REG_IRQ_STATUS) & (RTLNET_H264_IRQ_ERR | RTLNET_H264_IRQ_PIC_DONE)) == 0u,
          "error and done flags both cleared");
    g_cb_err = 1;   /* the polled test below counts from here */
    g_busy_ticks = 0u;

    /* Invalid entry: a wrong delimiter reports valid 0. */
    g_bad_aud = 1;
    check(run_picture(RTLNET_H264_CTL_PIC_IDR, 0u) == 1 && g_cb_pic.valid == 0u, "bad delimiter: valid 0");

    /* Ring stall, profile change and license lost: counted, reported once by take_events. */
    (void)rtlnet_h264_ctl_take_events();
    ev_irq(RTLNET_H264_IRQ_RING_STALL);
    ev_irq(RTLNET_H264_IRQ_LICENSE_LOST);
    tick(1);
    check(rtlnet_h264_ctl_take_events() == ((1u << RTLNET_H264_CTL_SRC_RING_STALL) | (1u << RTLNET_H264_CTL_SRC_LICENSE_LOST)), "take_events: stall and license lost");
    check(rtlnet_h264_ctl_take_events() == 0u, "take_events: once");
    rtlnet_h264_ctl_irq_stats(&is);
    check(is.source[RTLNET_H264_CTL_SRC_RING_STALL] == 1u && is.source[RTLNET_H264_CTL_SRC_LICENSE_LOST] == 1u, "stall and license counters");
    check((reg(RTLNET_H264_REG_IRQ_STATUS) & ~RTLNET_H264_IRQ_PIC_START) == 0u, "all enabled events acknowledged");
    /* PIC_START is not enabled: the status bit sets and stays, no interrupt. */
    check(start(RTLNET_H264_CTL_PIC_IDR, 0u) == 0, "start (PIC_START event)");
    check((reg(RTLNET_H264_REG_IRQ_STATUS) & RTLNET_H264_IRQ_PIC_START) != 0u && core_irq() == 0, "PIC_START sets the status bit and does not interrupt");
    tick(1);
    tick(1);
    tick(1);
    w32(RTLNET_H264_REG_IRQ_STATUS, 0u);
    g_cb_done = 0;

    /* Profile change at the picture start: forced IDR, parameter sets rewritten (High form when the module is enabled and offers CABAC). */
    {
        const uint8_t *ps;
        uint32_t pl;
        int rc;

        rc = rtlnet_h264_ctl_set_profile(1);
        check(rc == 0, "set_profile high accepted");
        g_hp_chg_next = 1u;
        check(run_picture(RTLNET_H264_CTL_PIC_P, 3u) == 1, "profile change: picture done");
        check(g_cb_pic.forced_idr == 1u && g_cb_pic.pic_type == RTLNET_H264_CTL_PIC_P, "profile change: forced IDR reported, requested type kept");
        rtlnet_h264_ctl_params(&ps, &pl);
        check((pl > 10u) && (ps[5] == 100u), "profile change: parameter sets rewritten, profile_idc 100");
        check((reg(RTLNET_H264_REG_HP_STATUS) & RTLNET_H264_HP_STATUS_CHG) == 0u, "profile change: HP_STATUS.CHG cleared");
        rtlnet_h264_ctl_irq_stats(&is);
        check(is.source[RTLNET_H264_CTL_SRC_PROFILE_CHG] == 1u, "profile change counted");
        check(run_picture(RTLNET_H264_CTL_PIC_P, 4u) == 1 && g_cb_pic.forced_idr == 0u, "the next picture is not forced");
    }

    /* Polled mode on the same core: interrupts disabled, STATUS read, the same result. */
    check(rtlnet_h264_ctl_set_notify(RTLNET_H264_NOTIFY_POLLED) == RTLNET_H264_NOTIFY_POLLED, "set_notify polled");
    check((reg(RTLNET_H264_REG_CTRL) & RTLNET_H264_CTRL_IRQ_EN) == 0u && reg(RTLNET_H264_REG_IRQ_ENABLE) == 0u, "polled: global enable and sources off");
    check(rtlnet_h264_ctl_poll() == 0, "polled: nothing due");
    check(rtlnet_h264_ctl_set_mode(RTLNET_H264_CTL_MODE_720P30, 28u) == 0, "set_mode again (rings reset)");
    g_payload = 100u;
    g_cb_done = 0;
    check(run_picture(RTLNET_H264_CTL_PIC_IDR, 0u) == 1, "polled: picture done");
    check(core_irq() == 0, "polled: the line stays low");
    check((reg(RTLNET_H264_REG_IRQ_STATUS) & RTLNET_H264_IRQ_PIC_DONE) != 0u, "polled: the sticky IRQ_STATUS bit is set (readable, not enabled)");
    ref_pol = g_cb_pic;
    check(ref_pol.valid == ref_int.valid && ref_pol.len[0] == ref_int.len[0] && ref_pol.len[1] == ref_int.len[1] && ref_pol.size_bytes == ref_int.size_bytes &&
          ref_pol.off[0] == ref_int.off[0] && ref_pol.ring_end[0] == ref_int.ring_end[0] && ref_pol.idx_end[0] == ref_int.idx_end[0] &&
          ref_pol.qp == ref_int.qp && ref_pol.forced_idr == ref_int.forced_idr && memcmp(ref_pol.aud, ref_int.aud, sizeof(ref_pol.aud)) == 0,
          "polled and interrupt modes give the same result for the same picture");
    check((reg(RTLNET_H264_REG_STATUS) & RTLNET_H264_STATUS_DONE) == 0u, "polled: DONE cleared");
    rtlnet_h264_ctl_irq_service();
    check(g_cb_done == 1, "polled: the service does nothing");
    /* Polled error. */
    check(start(RTLNET_H264_CTL_PIC_P, 1u) == 0, "polled: start");
    ev_error(RTLNET_H264_ERR_AXI);
    check(rtlnet_h264_ctl_poll() == 1 && g_cb_err >= 1 && g_cb_code == RTLNET_H264_ERR_AXI, "polled: error reported with its code");
    g_busy_ticks = 0u;

    /* Back to interrupt mode while idle: stale status acknowledged. */
    w32(RTLNET_H264_REG_IRQ_STATUS, RTLNET_H264_IRQ_PIC_DONE);
    check(rtlnet_h264_ctl_set_notify(RTLNET_H264_NOTIFY_INTERRUPT) == RTLNET_H264_NOTIFY_INTERRUPT, "set_notify interrupt");
    check(reg(RTLNET_H264_REG_IRQ_STATUS) == 0u && (reg(RTLNET_H264_REG_CTRL) & RTLNET_H264_CTRL_IRQ_EN) != 0u, "switching acknowledges stale events and enables");
    /* Self-test by force. */
    (void)rtlnet_h264_ctl_take_events();
    check(rtlnet_h264_ctl_irq_force(RTLNET_H264_IRQ_RING_STALL) == 0, "irq_force");
    check(core_irq() == 1, "force raises the line");
    rtlnet_h264_ctl_irq_service();
    check(core_irq() == 0 && rtlnet_h264_ctl_take_events() == (1u << RTLNET_H264_CTL_SRC_RING_STALL), "force: serviced and reported");
    rtlnet_h264_ctl_close();
    check((reg(RTLNET_H264_REG_CTRL) & RTLNET_H264_CTRL_IRQ_EN) == 0u && reg(RTLNET_H264_REG_IRQ_ENABLE) == 0u, "close disables the core's interrupts");
    check(rtlnet_h264_ctl_notify() == RTLNET_H264_NOTIFY_INTERRUPT, "closed: the wanted mode is reported");
    rtlnet_h264_ctl_irq_stats_clear();
    rtlnet_h264_ctl_irq_stats(&is);
    check(is.irqs == 0u && is.pictures == 0u && is.source[RTLNET_H264_CTL_SRC_PIC_DONE] == 0u, "stats_clear");

    /* An older core: the interrupt request degrades to polled, no interrupt register is written, polled completion works. */
    setup(0, 0u, 0);
    check(rtlnet_h264_ctl_open(&info) == 0 && info.irq_capable == 0u && info.irq_sources == 0u && info.version == RTLNET_H264_VERSION_PRE_IRQ, "older core opens");
    check(rtlnet_h264_ctl_notify_wanted() == RTLNET_H264_NOTIFY_INTERRUPT && rtlnet_h264_ctl_notify() == RTLNET_H264_NOTIFY_POLLED, "older core: interrupt degrades to polled");
    check(rtlnet_h264_ctl_set_notify(RTLNET_H264_NOTIFY_INTERRUPT) == RTLNET_H264_NOTIFY_POLLED, "older core: set_notify interrupt keeps polled");
    check(rtlnet_h264_ctl_irq_capable() == 0, "older core: irq_capable 0");
    check(rtlnet_h264_ctl_irq_force(1u) == -1, "older core: irq_force refused");
    check(rtlnet_h264_ctl_set_mode(RTLNET_H264_CTL_MODE_720P30, 28u) == 0, "older core: set_mode");
    check(run_picture(RTLNET_H264_CTL_PIC_IDR, 0u) == 1 && g_cb_pic.valid == 1u && g_cb_pic.size_bytes == 206u, "older core: polled picture");
    rtlnet_h264_ctl_irq_service();
    check(g_cb_done == 1, "older core: the service does nothing");
    check(g_wr_log_irq_en == 0u, "older core: IRQ_ENABLE never written");
    {
        rtlnet_h264_ctl_dbk_t k;

        check(rtlnet_h264_ctl_deblock_info(&k) == RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT && k.present == 0u, "older core: no deblocking filter");
        check(rtlnet_h264_ctl_set_deblock(1) == RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT && g_wr_dbk == 0u, "older core: deblock on refused, nothing written");
    }

    /* A core with the registers but no High profile sources (mask 0x27): enable drops the absent ones. */
    setup(1, 0x27u, 0);
    check(rtlnet_h264_ctl_open(&info) == 0 && info.irq_sources == 0x27u, "mask 0x27 build opens");
    check(reg(RTLNET_H264_REG_IRQ_ENABLE) == (RTLNET_H264_IRQ_PIC_DONE | RTLNET_H264_IRQ_ERR | RTLNET_H264_IRQ_RING_STALL), "only the implemented sources enabled");
    check(rtlnet_h264_ctl_set_mode(RTLNET_H264_CTL_MODE_720P30, 28u) == 0 && run_picture(RTLNET_H264_CTL_PIC_IDR, 0u) == 1, "mask 0x27 build: picture");

    /* Deblocking filter, a build with it: on by default, the request re-applied at set_mode, latched at START. */
    {
        rtlnet_h264_ctl_dbk_t k;
        uint32_t              w0;

        g_dbk_build = 1;
        setup(1, 0x3Fu, 1);
        check(rtlnet_h264_ctl_open(&info) == 0, "deblock: open");
        check(rtlnet_h264_ctl_deblock_wanted() == 1, "deblock: the request defaults to on");
        check((rtlnet_h264_ctl_deblock_info(&k) == 0) && (k.present == 1u) && (k.enable == 1u) && (k.applied == 0u) && (k.alpha_req == 0) && (k.beta_req == 0) &&
              (k.alpha_applied == 0) && (k.beta_applied == 0), "deblock: reset state, on, offsets 0, nothing applied yet");
        check(rtlnet_h264_ctl_deblock_in_force() == 1, "deblock: in force at reset");
        check(rtlnet_h264_ctl_deblock_info(NULL) == -1, "deblock: info NULL");
        check(rtlnet_h264_ctl_set_mode(RTLNET_H264_CTL_MODE_720P30, 28u) == 0, "deblock: set_mode");
        check((reg(RTLNET_H264_REG_DBK_CTRL) == 1u) && (rtlnet_h264_ctl_deblock_in_force() == 1), "deblock: set_mode keeps the default request (on, offsets 0)");
        check(run_picture(RTLNET_H264_CTL_PIC_IDR, 0u) == 1, "deblock: IDR picture");
        check((rtlnet_h264_ctl_deblock_info(&k) == 0) && (k.applied == 1u) && (k.alpha_applied == 0) && (k.beta_applied == 0), "deblock: the first picture was filtered");
        /* Offsets: range, nothing written on a refusal, kept while on/off changes. */
        w0 = g_wr_dbk;
        check(rtlnet_h264_ctl_set_deblock_offsets(7, 0) == RTLNET_H264_CTL_DBK_ERR_RANGE && rtlnet_h264_ctl_set_deblock_offsets(0, -7) == RTLNET_H264_CTL_DBK_ERR_RANGE &&
              g_wr_dbk == w0 && reg(RTLNET_H264_REG_DBK_CTRL) == 1u, "deblock: offsets outside -6..+6 refused, nothing written");
        check(rtlnet_h264_ctl_set_deblock_offsets(-3, 4) == 0 && reg(RTLNET_H264_REG_DBK_CTRL) == (1u | (0xDu << 4) | (4u << 8)), "deblock: offsets -3 and +4 written, enable kept");
        check((rtlnet_h264_ctl_deblock_info(&k) == 0) && (k.alpha_req == -3) && (k.beta_req == 4) && (k.alpha_applied == 0), "deblock: requested offsets differ from the applied ones until a picture starts");
        check(run_picture(RTLNET_H264_CTL_PIC_P, 1u) == 1 && g_cb_pic.forced_idr == 0u, "deblock: P picture, not a forced IDR picture");
        check((rtlnet_h264_ctl_deblock_info(&k) == 0) && (k.applied == 1u) && (k.alpha_applied == -3) && (k.beta_applied == 4), "deblock: the next picture applied the offsets");
        /* Off, then a change while a picture runs: effective at the next picture. */
        check(rtlnet_h264_ctl_set_deblock(0) == 0 && rtlnet_h264_ctl_deblock_wanted() == 0 && rtlnet_h264_ctl_deblock_in_force() == 0, "deblock: off accepted");
        check(reg(RTLNET_H264_REG_DBK_CTRL) == ((0xDu << 4) | (4u << 8)), "deblock: off keeps the offsets");
        check(run_picture(RTLNET_H264_CTL_PIC_P, 2u) == 1 && g_cb_pic.forced_idr == 0u, "deblock: picture with the filter off, no IDR needed");
        check((rtlnet_h264_ctl_deblock_info(&k) == 0) && (k.applied == 0u) && (k.enable == 0u), "deblock: the picture after off was not filtered");
        check(start(RTLNET_H264_CTL_PIC_P, 3u) == 0, "deblock: start with the filter off");
        check(rtlnet_h264_ctl_set_deblock(1) == 0, "deblock: on while the picture runs");
        check((rtlnet_h264_ctl_deblock_info(&k) == 0) && (k.applied == 0u) && (k.enable == 1u), "deblock: a change while busy does not touch the picture in progress");
        for (int n = 0; (n < 20) && (g_cb_done < 4); n++) {
            tick(1);
        }
        check(g_cb_done == 4, "deblock: the picture in progress completes");
        rtlnet_h264_ctl_release(0u, g_cb_pic.ring_end[0], g_cb_pic.idx_end[0]);
        rtlnet_h264_ctl_release(1u, g_cb_pic.ring_end[1], g_cb_pic.idx_end[1]);
        check(run_picture(RTLNET_H264_CTL_PIC_P, 4u) == 1, "deblock: the next picture");
        check((rtlnet_h264_ctl_deblock_info(&k) == 0) && (k.applied == 1u) && (k.alpha_applied == -3) && (k.beta_applied == 4), "deblock: the change took effect at the next picture");
        /* The request survives a mode set: the register is rewritten from it. */
        check(rtlnet_h264_ctl_set_deblock(0) == 0 && rtlnet_h264_ctl_set_deblock_offsets(2, -2) == 0, "deblock: off and offsets 2 and -2");
        w32(RTLNET_H264_REG_DBK_CTRL, 1u);   /* clobber the register: the core was reset */
        check(rtlnet_h264_ctl_set_mode(RTLNET_H264_CTL_MODE_720P30, 28u) == 0, "deblock: set_mode again");
        check(reg(RTLNET_H264_REG_DBK_CTRL) == ((2u << 4) | (0xEu << 8)), "deblock: set_mode re-applies the request (off, offsets 2 and -2)");
        check(rtlnet_h264_ctl_deblock_wanted() == 0, "deblock: the request is still off");
        rtlnet_h264_ctl_close();
    }

    /* Deblocking filter, a build without it (DEBLOCK = 0): named refusal, off accepted, set_mode never writes DBK_CTRL. */
    {
        rtlnet_h264_ctl_dbk_t k;

        g_dbk_build = 0;
        setup(1, 0x3Fu, 1);
        check(rtlnet_h264_ctl_open(&info) == 0, "deblock absent: open");
        check((rtlnet_h264_ctl_deblock_info(&k) == RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT) && (k.present == 0u) && (k.enable == 0u), "deblock absent: info reports not present");
        check(rtlnet_h264_ctl_deblock_in_force() == 0, "deblock absent: not in force");
        check(rtlnet_h264_ctl_set_deblock(1) == RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT && rtlnet_h264_ctl_deblock_wanted() == 1, "deblock absent: on refused, the request unchanged");
        check(rtlnet_h264_ctl_set_deblock_offsets(1, 1) == RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT && rtlnet_h264_ctl_set_deblock_offsets(9, 9) == RTLNET_H264_CTL_DBK_ERR_RANGE,
              "deblock absent: offsets refused (range first)");
        check(rtlnet_h264_ctl_set_deblock(0) == 0 && rtlnet_h264_ctl_deblock_wanted() == 0, "deblock absent: off accepted");
        check(rtlnet_h264_ctl_set_mode(RTLNET_H264_CTL_MODE_720P30, 28u) == 0 && run_picture(RTLNET_H264_CTL_PIC_IDR, 0u) == 1, "deblock absent: set_mode and a picture work");
        check(g_wr_dbk == 0u && reg(RTLNET_H264_REG_DBK_CTRL) == 0u, "deblock absent: DBK_CTRL never written");
        g_dbk_build = 1;
    }

    /* The console view. */
    {
        rtlnet_h264_ctl_debug_t d;

        check(rtlnet_h264_ctl_debug(&d) == 0 && d.engines == NENG && d.irq_capable == 1u && d.irq_global == 1u && d.version == RTLNET_H264_VERSION_VALUE, "debug view");
        check(d.irq_enable == reg(RTLNET_H264_REG_IRQ_ENABLE), "debug view: IRQ_ENABLE");
    }

#ifdef INJECT_FAILURE
    check(0, "INJECT_FAILURE negative control");
#endif
    if (g_fails == 0) {
        printf("CTL TEST PASS: rtlnet_h264_enc_ctl checks=%d\n", g_checks);
        return 0;
    }
    printf("CTL TEST FAIL: rtlnet_h264_enc_ctl fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
