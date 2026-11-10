/*
 * rtlnet_framebuf.c -- RTLNet tear-free frame buffer manager driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that reads or writes rtlnet_framebuf registers. Register map and function rules:
 * rtlnet_framebuf.h. No driver state: the hardware holds every value.
 */
#include "rtlnet_framebuf.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

#define FB_TAKE_POLLS   1000u   /* bound on the wait for the take to complete in the ui_clk domain */
#define FB_WH_MASK      0xFFFFu
#define FB_WH_SHIFT     16u

/*
 * rtlnet_framebuf_probe -- identify the core and read its build parameters
 * Returns: RTLNET_FB_OK when ID and VERSION match, RTLNET_FB_ERR_ARG otherwise.
 */
int rtlnet_framebuf_probe(uintptr_t base, rtlnet_framebuf_caps_t *caps)
{
    uint32_t c;
    uint32_t log2;

    if (rtlnet_reg_read32(base, RTLNET_REG_ID) != RTLNET_FB_ID_VALUE) {
        return RTLNET_FB_ERR_ARG;
    }
    if (rtlnet_reg_read32(base, RTLNET_REG_VERSION) != RTLNET_FB_VERSION_VALUE) {
        return RTLNET_FB_ERR_ARG;
    }
    if (caps != NULL) {
        c = rtlnet_reg_read32(base, RTLNET_REG_CAPS);
        log2 = (c >> RTLNET_FB_CAPS_SLOTLOG2_SHIFT) & RTLNET_FB_CAPS_SLOTLOG2_MASK;
        caps->slots      = c & RTLNET_FB_CAPS_SLOTS_MASK;
        caps->readers    = (c >> RTLNET_FB_CAPS_READERS_SHIFT) & RTLNET_FB_CAPS_READERS_MASK;
        caps->slot_bytes = (log2 < 32u) ? (1u << log2) : 0u;
        caps->addr_bits  = (c >> RTLNET_FB_CAPS_ADDR_SHIFT) & RTLNET_FB_CAPS_ADDR_MASK;
    }
    return RTLNET_FB_OK;
}

/* read_frame -- read the five registers of a frame description starting at offset. */
static void read_frame(uintptr_t base, uint32_t offset, rtlnet_framebuf_frame_t *f)
{
    uint32_t wh;

    f->base      = rtlnet_reg_read32(base, offset + 0x00u);
    f->frame     = rtlnet_reg_read32(base, offset + 0x04u);
    f->timestamp = rtlnet_reg_read32(base, offset + 0x08u);
    wh           = rtlnet_reg_read32(base, offset + 0x0Cu);
    f->width     = wh & FB_WH_MASK;
    f->height    = (wh >> FB_WH_SHIFT) & FB_WH_MASK;
    f->pattern   = rtlnet_reg_read32(base, offset + 0x10u) & 1u;
}

/*
 * rtlnet_framebuf_read_state -- read the status, the counters, the slot reference counts and the latest frame
 * Steps:
 *   1. Validate the pointer.
 *   2. Read STATUS, the base and size registers and the counters.
 *   3. Read the reference counts of the slots the core reports in CAPS (at most RTLNET_FB_MAX_SLOTS).
 *   4. Read the latest-frame registers (a live view).
 * Returns: RTLNET_FB_OK, or RTLNET_FB_ERR_ARG on NULL st.
 */
int rtlnet_framebuf_read_state(uintptr_t base, rtlnet_framebuf_state_t *st)
{
    uint32_t n;

    if (st == NULL) {
        return RTLNET_FB_ERR_ARG;
    }
    n = rtlnet_reg_read32(base, RTLNET_REG_CAPS) & RTLNET_FB_CAPS_SLOTS_MASK;
    st->status     = rtlnet_reg_read32(base, RTLNET_FB_REG_STATUS);
    st->fb_base    = rtlnet_reg_read32(base, RTLNET_FB_REG_FB_BASE);
    st->slot_bytes = rtlnet_reg_read32(base, RTLNET_FB_REG_SLOT_BYTES);
    st->published  = rtlnet_reg_read32(base, RTLNET_FB_REG_PUBLISHED);
    st->dropped    = rtlnet_reg_read32(base, RTLNET_FB_REG_DROPPED);
    st->bad        = rtlnet_reg_read32(base, RTLNET_FB_REG_BAD);
    st->fw_takes   = rtlnet_reg_read32(base, RTLNET_FB_REG_FW_TAKES);
    for (uint32_t i = 0u; i < RTLNET_FB_MAX_SLOTS; i++) {
        st->refcnt[i] = (i < n) ? rtlnet_reg_read32(base, RTLNET_FB_REG_REFCNT + (4u * i)) : 0u;
    }
    read_frame(base, RTLNET_FB_REG_LATEST_BASE, &st->latest);
    return RTLNET_FB_OK;
}

/*
 * rtlnet_framebuf_fw_take -- take the latest published slot for the firmware
 * Steps:
 *   1. Validate the pointer; clear a stale FW_ERR.
 *   2. Write CTRL.FW_TAKE.
 *   3. Poll STATUS (bounded) until FW_HOLDS rises, or FW_ERR sets (nothing published, or a slot already held).
 *   4. Read the held frame's registers.
 * Returns: RTLNET_FB_OK, RTLNET_FB_ERR_NO_FRAME, RTLNET_FB_ERR_TIMEOUT or RTLNET_FB_ERR_ARG.
 */
int rtlnet_framebuf_fw_take(uintptr_t base, rtlnet_framebuf_frame_t *frame)
{
    uint32_t st = 0u;

    if (frame == NULL) {
        return RTLNET_FB_ERR_ARG;
    }
    rtlnet_reg_write32(base, RTLNET_FB_REG_STATUS, RTLNET_FB_STATUS_FW_ERR);
    rtlnet_reg_write32(base, RTLNET_FB_REG_CTRL, RTLNET_FB_CTRL_FW_TAKE);
    for (uint32_t i = 0u; i < FB_TAKE_POLLS; i++) {
        st = rtlnet_reg_read32(base, RTLNET_FB_REG_STATUS);
        if ((st & RTLNET_FB_STATUS_FW_ERR) != 0u) {
            rtlnet_reg_write32(base, RTLNET_FB_REG_STATUS, RTLNET_FB_STATUS_FW_ERR);
            return RTLNET_FB_ERR_NO_FRAME;
        }
        if ((st & RTLNET_FB_STATUS_FW_HOLDS) != 0u) {
            read_frame(base, RTLNET_FB_REG_FW_BASE, frame);
            return RTLNET_FB_OK;
        }
    }
    return RTLNET_FB_ERR_TIMEOUT;
}

/*
 * rtlnet_framebuf_fw_release -- release the slot the firmware holds
 * Steps:
 *   1. Check STATUS.FW_HOLDS; return ERR_NO_FRAME when the firmware holds none.
 *   2. Write CTRL.FW_RELEASE.
 * Returns: RTLNET_FB_OK or RTLNET_FB_ERR_NO_FRAME.
 */
int rtlnet_framebuf_fw_release(uintptr_t base)
{
    if ((rtlnet_reg_read32(base, RTLNET_FB_REG_STATUS) & RTLNET_FB_STATUS_FW_HOLDS) == 0u) {
        return RTLNET_FB_ERR_NO_FRAME;
    }
    rtlnet_reg_write32(base, RTLNET_FB_REG_CTRL, RTLNET_FB_CTRL_FW_RELEASE);
    return RTLNET_FB_OK;
}

/* rtlnet_framebuf_clear -- clear the counters (self-clearing CTRL bit). */
void rtlnet_framebuf_clear(uintptr_t base)
{
    rtlnet_reg_write32(base, RTLNET_FB_REG_CTRL, RTLNET_FB_CTRL_CNT_CLEAR);
}
