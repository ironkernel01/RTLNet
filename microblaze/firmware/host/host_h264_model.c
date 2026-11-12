/*
 * host_h264_model.c -- H.264 encoder core model of the desktop harness
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: see host_h264_model.h. Registers: ID, VERSION (with or without the interrupt registers), CAPS, CTRL, STATUS, ERR_CODE, the configuration
 * registers read back as written, the per-engine pointers (window 0x100 * e), PIC_COUNT, SLICE_COUNT, HP_CTRL, HP_STATUS, HP_T8COUNT,
 * IRQ_STATUS, IRQ_ENABLE, IRQ_FORCE. A picture takes pic_ticks model ticks (host_model_h264_advance, or one tick per access_period register
 * accesses); on completion the model writes into the DDR3 model, for each engine, a slice entry and a picture entry in its index ring and the
 * bytes of the picture (engine 0 starts with the access unit delimiter) in its ring share, then sets DONE and the IRQ_STATUS bit. The sizes and
 * bytes are deterministic functions of the picture number, the QP and the type, so two runs of the same sequence produce the same stream.
 */
#include "host_h264_model.h"

#include <string.h>   /* memset */

#include "host_platform.h"
#include "rtlnet_h264_enc.h"
#include "rtlnet_mmio.h"
#include "rtlnet_platform.h"

#define NENG            2u
#define REGS            (0x400u / 4u)
#define PIC_TICKS_DEF   6u
#define HOST_H264_REC   2048u

static struct {
    int      on;
    int      seam;
    int      irq_capable;
    uint32_t reg[REGS];            /* configuration registers as written (window 0) */
    uint32_t rptr[NENG][2];        /* ring and index read pointers written by the firmware */
    uint32_t done_flag;
    uint32_t err_flag;
    uint32_t err_code;
    uint32_t stall;
    uint32_t busy;
    uint32_t ticks_left;
    uint32_t pic_ticks;
    uint32_t access_period;
    uint32_t access_cnt;
    uint32_t irq_status;
    uint32_t irq_enable;
    uint32_t irq_en;
    uint32_t pic_count;
    uint32_t slice_count;
    uint32_t starts;
    uint32_t ring_w[NENG];
    uint32_t idx_w[NENG];
    uint32_t cur_type;
    uint32_t cur_qp;
    uint32_t cur_forced;
    uint32_t in_advance;
    uint32_t illegal_irq_access;   /* interrupt registers touched on a core that has none */
    /* High profile */
    uint32_t hp_present, hp_licensed, hp_caps, hp_seconds, hp_enable, hp_t8, hp_auto, t8_n8, t8_n4, hp_chg;
    uint32_t hp_last_cfg;
    int      hp_last_valid;
    uint32_t forced_count;
    host_h264_pic_t rec[HOST_H264_REC];
} m = { .irq_capable = 1, .pic_ticks = PIC_TICKS_DEF };

static uint32_t impl_mask(void)
{
    return m.seam ? 0x3Fu : 0x27u;
}

static void update_line(void)
{
    uint32_t level = (m.irq_capable && m.irq_en && ((m.irq_status & m.irq_enable) != 0u)) ? 1u : 0u;
    host_irq_set_line(RTLNET_CPU_IRQ_H264, level);
}

static void raise_irq(uint32_t bits)
{
    if (m.irq_capable) {
        m.irq_status |= bits & impl_mask();
    }
}

int host_h264_active(void)
{
    return m.on;
}

void host_model_h264_set(int on, int seam)
{
    int capable = m.irq_capable;
    memset(&m, 0, sizeof(m));
    m.irq_capable = capable;
    m.pic_ticks = PIC_TICKS_DEF;
    m.on = on;
    m.seam = seam;
    m.hp_present = 1u;
    m.hp_licensed = 1u;
    m.hp_seconds = RTLNET_H264_HP_SECONDS_UNLIMITED;
    update_line();
}

void host_model_h264_hp(uint32_t present, uint32_t licensed, uint32_t caps, uint32_t seconds)
{
    uint32_t was = m.hp_licensed;
    m.hp_present = present;
    m.hp_licensed = licensed;
    m.hp_caps = caps;
    m.hp_seconds = seconds;
    if (m.seam && (was != 0u) && (licensed == 0u)) {
        raise_irq(RTLNET_H264_IRQ_LICENSE_LOST);   /* hp_licensed fell */
        update_line();
    }
}

uint32_t host_model_h264_hp_ctrl(void)
{
    return m.hp_enable;
}

uint32_t host_model_h264_hp_ctrl_t8(void)
{
    return m.hp_t8;
}

uint32_t host_model_h264_hp_ctrl_auto(void)
{
    return m.hp_auto;
}

void host_model_h264_t8_counts(uint32_t n8, uint32_t n4)
{
    m.t8_n8 = n8;
    m.t8_n4 = n4;
}

void host_model_h264_irq_caps(int capable)
{
    m.irq_capable = capable;
    update_line();
}

void host_model_h264_timing(uint32_t pic_ticks, uint32_t access_period)
{
    m.pic_ticks = (pic_ticks != 0u) ? pic_ticks : 1u;
    m.access_period = access_period;
    m.access_cnt = 0u;
}

uint32_t host_model_h264_count(int which)
{
    switch (which) {
    case HOST_H264_COUNT_PICTURES:    return m.pic_count;
    case HOST_H264_COUNT_STARTS:      return m.starts;
    case HOST_H264_COUNT_ILLEGAL_IRQ: return m.illegal_irq_access;
    case HOST_H264_COUNT_BUSY:        return m.busy;
    case HOST_H264_COUNT_FORCED:      return m.forced_count;
    case HOST_H264_COUNT_IRQ_STATUS:  return m.irq_status;
    case HOST_H264_COUNT_IRQ_ENABLE:  return m.irq_enable;
    case HOST_H264_COUNT_IRQ_GLOBAL:  return m.irq_en;
    default:                          return 0u;
    }
}

void host_model_h264_error(uint32_t code)
{
    m.err_flag = 1u;
    if (m.err_code == 0u) {
        m.err_code = code;
    }
    m.busy = 0u;           /* the engines stop at an error: the picture in flight is abandoned */
    raise_irq(RTLNET_H264_IRQ_ERR);
    update_line();
}

void host_model_h264_event(uint32_t irq_bits)
{
    if ((irq_bits & RTLNET_H264_IRQ_RING_STALL) != 0u) {
        m.stall = 1u;
    }
    raise_irq(irq_bits);
    update_line();
}

/* Bytes of the picture of engine e: deterministic in the picture number, the QP and the type. */
static uint32_t pic_len(uint32_t e)
{
    uint32_t base = (m.cur_type == RTLNET_H264_PIC_IDR || m.cur_forced) ? 3000u : 500u;
    return base + ((m.pic_count * 131u + e * 17u + m.cur_qp * 7u) % 257u);
}

/* The bytes of picture idx of engine e (len bytes): deterministic, so the test regenerates what the model wrote. */
static void fill_bytes(uint32_t idx, uint32_t e, uint32_t len, uint8_t *buf)
{
    for (uint32_t i = 0u; i < len; i++) {
        buf[i] = (uint8_t)(((idx + 1u) * 2654435761u + e * 40503u + i * 2246822519u) >> 13);
    }
    if (e == 0u && len >= 6u) {
        static const uint8_t aud[6] = {0u, 0u, 0u, 1u, 0x09u, 0xF0u};
        memcpy(buf, aud, 6u);
    }
}

int host_model_h264_picture(uint32_t idx, host_h264_pic_t *out)
{
    if (idx >= m.pic_count || m.pic_count - idx > HOST_H264_REC) {
        return -1;
    }
    *out = m.rec[idx % HOST_H264_REC];
    return 0;
}

void host_model_h264_bytes(uint32_t idx, uint32_t e, uint8_t *out)
{
    host_h264_pic_t r;
    if (host_model_h264_picture(idx, &r) == 0 && e < NENG) {
        fill_bytes(idx, e, r.len[e], out);
    }
}

/* The picture is complete: entries and bytes into the DDR3 model, DONE, the interrupt event. */
static void finish_picture(void)
{
    uint32_t ring_base = m.reg[RTLNET_H264_REG_RING_BASE / 4u];
    uint32_t ring_size = m.reg[RTLNET_H264_REG_RING_SIZE / 4u];
    uint32_t idx_base = m.reg[RTLNET_H264_REG_IDX_BASE / 4u];
    uint32_t idx_entries = m.reg[RTLNET_H264_REG_IDX_ENTRIES / 4u];
    uint32_t share = (ring_size / NENG);
    uint32_t ishare = (idx_entries / NENG);
    host_h264_pic_t *rec = &m.rec[m.pic_count % HOST_H264_REC];

    rec->qp = m.cur_qp;
    rec->idr = (m.cur_type == RTLNET_H264_PIC_IDR) ? 1u : 0u;
    rec->forced = m.cur_forced;
    rec->len[0] = pic_len(0) + 6u;
    rec->len[1] = pic_len(1);

    for (uint32_t e = 0u; e < NENG; e++) {
        uint32_t len = pic_len(e) + (e == 0u ? 6u : 0u);
        uint32_t off = m.ring_w[e];
        uint8_t  buf[4096];
        uint32_t w[4];
        if (share == 0u || ishare == 0u || len > sizeof(buf)) {
            continue;
        }
        fill_bytes(m.pic_count, e, len, buf);
        /* bytes, wrapping inside the engine's share */
        for (uint32_t i = 0u; i < len; i++) {
            host_ddr_poke(ring_base + e * share + ((off + i) % share), &buf[i], 1u);
        }
        for (uint32_t k = 0u; k < 2u; k++) {
            uint8_t rec[16];
            w[0] = off;
            w[1] = len;
            w[2] = ((m.pic_count + 1u) & 0xFFFFu) | (k << 16);
            w[3] = (k == 1u ? RTLNET_H264_IDX_KIND_PICTURE : 0u) | 7u;
            memcpy(rec, w, 16u);
            host_ddr_poke(idx_base + 128u * (e * ishare + m.idx_w[e]), rec, 16u);
            m.idx_w[e] = (m.idx_w[e] + 1u) % ishare;
        }
        m.ring_w[e] = (((off + len + 15u) / 16u) * 16u) % share;
    }
    m.pic_count++;
    m.slice_count += 2u;
    m.busy = 0u;
    m.done_flag = 1u;
    raise_irq(RTLNET_H264_IRQ_PIC_DONE);
}

void host_model_h264_advance(uint32_t ticks)
{
    while (ticks-- != 0u) {
        if (m.busy != 0u) {
            if (m.ticks_left > 0u) {
                m.ticks_left--;
            }
            if (m.ticks_left == 0u) {
                finish_picture();
            }
        }
    }
    update_line();
    host_irq_deliver();
}

void host_h264_on_access(void)
{
    if (!m.on || m.access_period == 0u || m.busy == 0u || m.in_advance) {
        return;
    }
    if (++m.access_cnt >= m.access_period) {
        m.access_cnt = 0u;
        m.in_advance = 1u;
        host_model_h264_advance(1u);
        m.in_advance = 0u;
    }
}

static void start_picture(void)
{
    uint32_t pic_cfg = m.reg[RTLNET_H264_REG_PIC_CFG / 4u];
    if (m.busy != 0u) {
        host_model_h264_error(RTLNET_H264_ERR_BUSY);
        return;
    }
    m.busy = 1u;
    m.ticks_left = m.pic_ticks;
    m.starts++;
    m.cur_type = ((pic_cfg & RTLNET_H264_PIC_CFG_IDR) != 0u) ? RTLNET_H264_PIC_IDR : RTLNET_H264_PIC_P;
    m.cur_qp = m.reg[RTLNET_H264_REG_QP / 4u];
    m.cur_forced = 0u;
    raise_irq(RTLNET_H264_IRQ_PIC_START);
    if (m.seam) {
        uint32_t cfg_now = m.hp_enable | (m.hp_licensed << 1);
        if (m.hp_last_valid && cfg_now != m.hp_last_cfg) {
            m.hp_chg = 1u;
            m.cur_forced = 1u;
            m.forced_count++;
            raise_irq(RTLNET_H264_IRQ_PROFILE_CHG);
        }
        m.hp_last_cfg = cfg_now;
        m.hp_last_valid = 1;
    }
}

uint32_t host_h264_read(uint32_t off)
{
    uint32_t e = (off >> 8) & 0xFu;
    uint32_t lo = off & 0xFFu;

    if (e != 0u) {
        if (e >= NENG) {
            return 0u;
        }
        switch (lo) {
        case RTLNET_H264_REG_RING_WPTR: return m.ring_w[e];
        case RTLNET_H264_REG_IDX_WPTR:  return m.idx_w[e];
        case RTLNET_H264_REG_RING_RPTR: return m.rptr[e][0];
        case RTLNET_H264_REG_IDX_RPTR:  return m.rptr[e][1];
        default:                        return 0u;
        }
    }
    switch (off) {
    case RTLNET_REG_ID:               return RTLNET_H264_ID_VALUE;
    case RTLNET_REG_VERSION:          return m.irq_capable ? RTLNET_H264_VERSION_VALUE : RTLNET_H264_VERSION_PRE_IRQ;
    case RTLNET_REG_CAPS:             return 120u | (68u << RTLNET_H264_CAPS_MB_H_SHIFT) | (NENG << RTLNET_H264_CAPS_ENG_SHIFT) |
                                             (m.seam ? RTLNET_H264_CAPS_HP_SEAM : 0u) |
                                             (m.irq_capable ? (RTLNET_H264_CAPS_IRQ | (impl_mask() << RTLNET_H264_CAPS_IRQ_SRC_SHIFT)) : 0u);
    case RTLNET_H264_REG_CTRL:        return m.irq_en ? RTLNET_H264_CTRL_IRQ_EN : 0u;
    case RTLNET_H264_REG_STATUS:      return (m.busy ? RTLNET_H264_STATUS_BUSY : 0u) | (m.done_flag ? RTLNET_H264_STATUS_DONE : 0u) |
                                             (m.err_flag ? RTLNET_H264_STATUS_ERR : 0u) | (m.stall ? RTLNET_H264_STATUS_RING_STALL : 0u);
    case RTLNET_H264_REG_ERR_CODE:    return m.err_code;
    case RTLNET_H264_REG_PIC_COUNT:   return m.pic_count;
    case RTLNET_H264_REG_SLICE_COUNT: return m.slice_count;
    case RTLNET_H264_REG_RING_WPTR:   return m.ring_w[0];
    case RTLNET_H264_REG_IDX_WPTR:    return m.idx_w[0];
    case RTLNET_H264_REG_RING_RPTR:   return m.rptr[0][0];
    case RTLNET_H264_REG_IDX_RPTR:    return m.rptr[0][1];
    case RTLNET_H264_REG_IRQ_STATUS:
    case RTLNET_H264_REG_IRQ_ENABLE:
        if (!m.irq_capable) {
            m.illegal_irq_access++;
            return 0u;
        }
        return (off == RTLNET_H264_REG_IRQ_STATUS) ? m.irq_status : m.irq_enable;
    case RTLNET_H264_REG_IRQ_FORCE:   return 0u;
    case RTLNET_H264_REG_HP_CTRL:     return m.seam ? (m.hp_enable | (m.hp_t8 << 1) | (m.hp_auto << 2)) : 0u;
    case RTLNET_H264_REG_HP_T8COUNT:  return m.seam ? ((m.t8_n8 & 0xFFFFu) | (m.t8_n4 << 16)) : 0u;
    case RTLNET_H264_REG_HP_STATUS:
        if (!m.seam) {
            return 0u;
        }
        return (m.hp_present ? RTLNET_H264_HP_STATUS_PRESENT : 0u) | (m.hp_licensed ? RTLNET_H264_HP_STATUS_LICENSED : 0u) |
               (m.hp_enable ? RTLNET_H264_HP_STATUS_ENABLED : 0u) | (m.hp_t8 ? RTLNET_H264_HP_STATUS_T8ENABLED : 0u) |
               (m.hp_auto ? RTLNET_H264_HP_STATUS_T8AUTO : 0u) | (m.hp_chg ? RTLNET_H264_HP_STATUS_CHG : 0u) |
               (m.hp_caps << RTLNET_H264_HP_STATUS_CAPS_SHIFT) | (m.hp_seconds << RTLNET_H264_HP_STATUS_SEC_SHIFT);
    default:
        return (off < sizeof(m.reg)) ? m.reg[off / 4u] : 0u;
    }
}

void host_h264_write(uint32_t off, uint32_t value)
{
    uint32_t e = (off >> 8) & 0xFu;
    uint32_t lo = off & 0xFFu;

    if (e != 0u) {
        if (e < NENG && lo == RTLNET_H264_REG_RING_RPTR) {
            m.rptr[e][0] = value;
        } else if (e < NENG && lo == RTLNET_H264_REG_IDX_RPTR) {
            m.rptr[e][1] = value;
        }
        return;
    }
    switch (off) {
    case RTLNET_H264_REG_CTRL:
        m.irq_en = ((value & RTLNET_H264_CTRL_IRQ_EN) != 0u) ? 1u : 0u;
        if ((value & RTLNET_H264_CTRL_RING_RESET) != 0u) {
            memset(m.ring_w, 0, sizeof(m.ring_w));
            memset(m.idx_w, 0, sizeof(m.idx_w));
            memset(m.rptr, 0, sizeof(m.rptr));
        }
        if ((value & RTLNET_H264_CTRL_START) != 0u) {
            start_picture();
        }
        break;
    case RTLNET_H264_REG_STATUS:
        if ((value & RTLNET_H264_STATUS_DONE) != 0u) {
            m.done_flag = 0u;
        }
        if ((value & RTLNET_H264_STATUS_ERR) != 0u) {
            m.err_flag = 0u;
            m.err_code = 0u;
        }
        break;
    case RTLNET_H264_REG_IRQ_STATUS:
    case RTLNET_H264_REG_IRQ_ENABLE:
    case RTLNET_H264_REG_IRQ_FORCE:
        if (!m.irq_capable) {
            m.illegal_irq_access++;
            return;
        }
        if (off == RTLNET_H264_REG_IRQ_STATUS) {
            m.irq_status &= ~value;
        } else if (off == RTLNET_H264_REG_IRQ_ENABLE) {
            m.irq_enable = value & impl_mask();
        } else {
            m.irq_status |= value & impl_mask();
        }
        break;
    case RTLNET_H264_REG_HP_CTRL:
        if (m.seam) {
            m.hp_enable = ((value & 1u) != 0u && m.hp_caps != 0u) ? 1u : 0u;
            m.hp_t8     = ((value & 2u) != 0u && (m.hp_caps & RTLNET_H264_HP_CAP_TRANSFORM8X8) != 0u) ? 1u : 0u;
            m.hp_auto   = ((value & 6u) == 6u && (m.hp_caps & RTLNET_H264_HP_CAP_TRANSFORM8X8) != 0u &&
                           (m.hp_caps & RTLNET_H264_HP_CAP_ADAPTIVE) != 0u) ? 1u : 0u;
        }
        break;
    case RTLNET_H264_REG_HP_STATUS:
        if (m.seam && (value & RTLNET_H264_HP_STATUS_CHG) != 0u) {
            m.hp_chg = 0u;
        }
        break;
    default:
        if (off < sizeof(m.reg)) {
            m.reg[off / 4u] = value;
        }
        break;
    }
    update_line();
    host_irq_deliver();
}
