/*
 * rtlnet_csi2_rx.c -- RTLNet CSI-2 capture core driver (Phase 1)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that reads or writes rtlnet_csi2_rx registers. Register map and function rules:
 * rtlnet_csi2_rx.h. No driver state: the hardware holds every value.
 */
#include "rtlnet_csi2_rx.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

/*
 * rtlnet_csi2_rx_probe -- identify the core and read its capabilities
 * Steps:
 *   1. Check ID and VERSION.
 *   2. Decode CAPS into caps when caps is not NULL.
 * Returns: RTLNET_CSI2_OK when present and matching, RTLNET_CSI2_ERR_ARG otherwise.
 */
int rtlnet_csi2_rx_probe(uintptr_t base, rtlnet_csi2_rx_caps_t *caps)
{
    uint32_t c;

    if (rtlnet_reg_read32(base, RTLNET_REG_ID) != RTLNET_CSI2_ID_VALUE) {
        return RTLNET_CSI2_ERR_ARG;
    }
    if (rtlnet_reg_read32(base, RTLNET_REG_VERSION) != RTLNET_CSI2_VERSION_VALUE) {
        return RTLNET_CSI2_ERR_ARG;
    }
    if (caps != NULL) {
        c = rtlnet_reg_read32(base, RTLNET_REG_CAPS);
        caps->modes   = c & RTLNET_CSI2_CAPS_MODES_MASK;
        caps->pattern = ((c & RTLNET_CSI2_CAPS_PATTERN) != 0u) ? 1 : 0;
        caps->camera  = ((c & RTLNET_CSI2_CAPS_CAMERA) != 0u) ? 1 : 0;
    }
    return RTLNET_CSI2_OK;
}

/*
 * rtlnet_csi2_rx_read_state -- read every register of the first part of the window
 * Steps:
 *   1. Validate the pointer.
 *   2. Read the registers in offset order.
 * Returns: RTLNET_CSI2_OK, or RTLNET_CSI2_ERR_ARG on NULL st.
 */
int rtlnet_csi2_rx_read_state(uintptr_t base, rtlnet_csi2_rx_state_t *st)
{
    if (st == NULL) {
        return RTLNET_CSI2_ERR_ARG;
    }
    st->video_mode   = rtlnet_reg_read32(base, RTLNET_CSI2_REG_VIDEO_MODE);
    st->source       = rtlnet_reg_read32(base, RTLNET_CSI2_REG_SOURCE);
    st->frame_period = rtlnet_reg_read32(base, RTLNET_CSI2_REG_FRAME_PERIOD);
    st->cam_timeout  = rtlnet_reg_read32(base, RTLNET_CSI2_REG_CAM_TIMEOUT);
    st->status       = rtlnet_reg_read32(base, RTLNET_CSI2_REG_STATUS);
    st->frame_count  = rtlnet_reg_read32(base, RTLNET_CSI2_REG_FRAME_COUNT);
    st->active_mode  = rtlnet_reg_read32(base, RTLNET_CSI2_REG_ACTIVE) & 0x3u;
    return RTLNET_CSI2_OK;
}

/*
 * write_checked -- write one register and report whether the core rejected it
 * Steps:
 *   1. Clear the error flags that this write could set (they are sticky).
 *   2. Write the value.
 *   3. Read STATUS; a flag of err_mask set means the core rejected the value: clear it, return ERR_REJECTED.
 * Returns: RTLNET_CSI2_OK or RTLNET_CSI2_ERR_REJECTED.
 */
static int write_checked(uintptr_t base, uint32_t offset, uint32_t value, uint32_t err_mask)
{
    rtlnet_reg_write32(base, RTLNET_CSI2_REG_STATUS, err_mask);
    rtlnet_reg_write32(base, offset, value);
    if ((rtlnet_reg_read32(base, RTLNET_CSI2_REG_STATUS) & err_mask) != 0u) {
        rtlnet_reg_write32(base, RTLNET_CSI2_REG_STATUS, err_mask);
        return RTLNET_CSI2_ERR_REJECTED;
    }
    return RTLNET_CSI2_OK;
}

/*
 * rtlnet_csi2_rx_set_mode -- select 720p30 or 1080p30 (effective at the next frame start)
 * Returns: RTLNET_CSI2_OK, ERR_ARG for a mode at or above RTLNET_CSI2_MODE_COUNT (the register is not written),
 *          ERR_REJECTED when the core rejects it (the present FRAME_PERIOD is below the new mode's minimum).
 */
int rtlnet_csi2_rx_set_mode(uintptr_t base, uint32_t mode)
{
    if (mode >= RTLNET_CSI2_MODE_COUNT) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return write_checked(base, RTLNET_CSI2_REG_VIDEO_MODE, mode,
                         RTLNET_CSI2_STATUS_MODE_ERR | RTLNET_CSI2_STATUS_PERIOD_ERR);
}

/*
 * rtlnet_csi2_rx_set_source -- select auto, camera or pattern
 * Returns: RTLNET_CSI2_OK, ERR_ARG for a value above RTLNET_CSI2_SRC_PATTERN, ERR_REJECTED when the core rejects it.
 */
int rtlnet_csi2_rx_set_source(uintptr_t base, uint32_t source)
{
    if (source > RTLNET_CSI2_SRC_PATTERN) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return write_checked(base, RTLNET_CSI2_REG_SOURCE, source, RTLNET_CSI2_STATUS_SOURCE_ERR);
}

/*
 * rtlnet_csi2_rx_set_frame_period -- set the ui_clk cycles per frame
 * Returns: RTLNET_CSI2_OK, or ERR_REJECTED when the period is below the minimum of the selected mode.
 */
int rtlnet_csi2_rx_set_frame_period(uintptr_t base, uint32_t period)
{
    return write_checked(base, RTLNET_CSI2_REG_FRAME_PERIOD, period, RTLNET_CSI2_STATUS_PERIOD_ERR);
}

/*
 * rtlnet_csi2_rx_set_rate_fps -- set the frame rate in whole frames per second
 * Steps:
 *   1. Reject 0 and anything above RTLNET_CSI2_FPS_MAX (the period would fall below the mode minimum).
 *   2. Write RTLNET_CSI2_UI_CLK_HZ / fps as the period; 30 gives 3,333,333, the reset value.
 * Returns: RTLNET_CSI2_OK, ERR_ARG, or ERR_REJECTED.
 */
int rtlnet_csi2_rx_set_rate_fps(uintptr_t base, uint32_t fps)
{
    if (fps == 0u || fps > RTLNET_CSI2_FPS_MAX) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return rtlnet_csi2_rx_set_frame_period(base, RTLNET_CSI2_UI_CLK_HZ / fps);
}

/* rtlnet_csi2_rx_mode_width -- pixels per line of a mode, 0 for an unknown mode. */
uint32_t rtlnet_csi2_rx_mode_width(uint32_t mode)
{
    if (mode == RTLNET_CSI2_MODE_720P30) {
        return RTLNET_CSI2_WIDTH_720P30;
    }
    if (mode == RTLNET_CSI2_MODE_1080P30) {
        return RTLNET_CSI2_WIDTH_1080P30;
    }
    return 0u;
}

/* rtlnet_csi2_rx_mode_height -- lines per frame of a mode, 0 for an unknown mode. */
uint32_t rtlnet_csi2_rx_mode_height(uint32_t mode)
{
    if (mode == RTLNET_CSI2_MODE_720P30) {
        return RTLNET_CSI2_HEIGHT_720P30;
    }
    if (mode == RTLNET_CSI2_MODE_1080P30) {
        return RTLNET_CSI2_HEIGHT_1080P30;
    }
    return 0u;
}
