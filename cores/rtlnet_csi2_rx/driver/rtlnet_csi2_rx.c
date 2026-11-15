/*
 * rtlnet_csi2_rx.c -- RTLNet CSI-2 capture core driver (test patterns, source switch, camera receiver)
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
 *   1. Check ID and VERSION (the core with or without the camera receiver).
 *   2. Decode CAPS into caps when caps is not NULL.
 * Returns: RTLNET_CSI2_OK when present and matching, RTLNET_CSI2_ERR_ARG otherwise.
 */
int rtlnet_csi2_rx_probe(uintptr_t base, rtlnet_csi2_rx_caps_t *caps)
{
    uint32_t c;

    if (rtlnet_reg_read32(base, RTLNET_REG_ID) != RTLNET_CSI2_ID_VALUE) {
        return RTLNET_CSI2_ERR_ARG;
    }
    c = rtlnet_reg_read32(base, RTLNET_REG_VERSION);
    if (c != RTLNET_CSI2_VERSION_VALUE && c != RTLNET_CSI2_VERSION_CAMERA) {
        return RTLNET_CSI2_ERR_ARG;
    }
    if (caps != NULL) {
        c = rtlnet_reg_read32(base, RTLNET_REG_CAPS);
        caps->modes   = c & RTLNET_CSI2_CAPS_MODES_MASK;
        caps->pattern = ((c & RTLNET_CSI2_CAPS_PATTERN) != 0u) ? 1 : 0;
        caps->camera  = ((c & RTLNET_CSI2_CAPS_CAMERA) != 0u) ? 1 : 0;
        caps->moving  = ((c & RTLNET_CSI2_CAPS_MOVING) != 0u) ? 1 : 0;
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
    uint32_t pat;

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
    pat = rtlnet_reg_read32(base, RTLNET_CSI2_REG_PATTERN);
    st->pattern       = pat & 0x7u;
    st->pattern_speed = (int32_t)(int8_t)((pat >> RTLNET_CSI2_PATTERN_SPEED_SHIFT) & 0xFFu);
    st->pattern_frame = rtlnet_reg_read32(base, RTLNET_CSI2_REG_PATTERN_FRAME);
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
 * rtlnet_csi2_rx_set_pattern -- select the test pattern and its speed (effective at the next frame start)
 * Steps:
 *   1. Refuse values that do not fit the register fields (pattern above 255, speed outside -128..127): nothing is written.
 *   2. Write pattern | speed << 8; the core accepts patterns 0..4 and speeds -32..+32 and rejects the rest (PATTERN_ERR).
 * Returns: RTLNET_CSI2_OK, ERR_ARG (not encodable), or ERR_REJECTED (the core rejected the value; the register is unchanged).
 */
int rtlnet_csi2_rx_set_pattern(uintptr_t base, uint32_t pattern, int32_t speed)
{
    if (pattern > 0xFFu || speed < -128 || speed > 127) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return write_checked(base, RTLNET_CSI2_REG_PATTERN,
                         pattern | (((uint32_t)speed & 0xFFu) << RTLNET_CSI2_PATTERN_SPEED_SHIFT), RTLNET_CSI2_STATUS_PATTERN_ERR);
}

/*
 * rtlnet_csi2_rx_set_rate_fps -- set the frame rate in whole frames per second
 * Steps:
 *   1. Reject 0 and anything above RTLNET_CSI2_FPS_MAX (the period would fall below the mode minimum).
 *   2. Write RTLNET_CSI2_UI_CLK_HZ / fps as the period; 30 gives 3,000,000, the reset value.
 * Returns: RTLNET_CSI2_OK, ERR_ARG, or ERR_REJECTED.
 */
int rtlnet_csi2_rx_set_rate_fps(uintptr_t base, uint32_t fps)
{
    if (fps == 0u || fps > RTLNET_CSI2_FPS_MAX) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return rtlnet_csi2_rx_set_frame_period(base, RTLNET_CSI2_UI_CLK_HZ / fps);
}

/*
 * camera_present -- the core has the camera receiver (CAPS camera bit)
 * Returns: 1 when present, 0 otherwise.
 */
static int camera_present(uintptr_t base)
{
    return ((rtlnet_reg_read32(base, RTLNET_REG_CAPS) & RTLNET_CSI2_CAPS_CAMERA) != 0u) ? 1 : 0;
}

/*
 * cam_write -- write one camera receiver register after the presence check
 * Returns: RTLNET_CSI2_OK, or ERR_ARG without the camera receiver.
 */
static int cam_write(uintptr_t base, uint32_t offset, uint32_t value)
{
    if (camera_present(base) == 0) {
        return RTLNET_CSI2_ERR_ARG;
    }
    rtlnet_reg_write32(base, offset, value);
    return RTLNET_CSI2_OK;
}

/*
 * rtlnet_csi2_rx_rx_control -- enable, soft reset, lane enable and bit order of the receiver
 * Returns: OK, or ERR_ARG (lane_en above 3, no camera receiver).
 */
int rtlnet_csi2_rx_rx_control(uintptr_t base, int enable, int soft_reset, uint32_t lane_en, int bit_rev)
{
    uint32_t v;

    if (lane_en > 3u) {
        return RTLNET_CSI2_ERR_ARG;
    }
    v = ((enable != 0) ? RTLNET_CSI2_CTRL_ENABLE : 0u) | ((soft_reset != 0) ? RTLNET_CSI2_CTRL_SOFT_RESET : 0u) |
        (lane_en << RTLNET_CSI2_CTRL_LANE_SHIFT) | ((bit_rev != 0) ? RTLNET_CSI2_CTRL_BIT_REV : 0u);
    return cam_write(base, RTLNET_CSI2_REG_RX_CTRL, v);
}

/* rtlnet_csi2_rx_set_taps -- input delay taps (0..31) of the two data lanes. */
int rtlnet_csi2_rx_set_taps(uintptr_t base, uint32_t tap0, uint32_t tap1)
{
    if (tap0 > 31u || tap1 > 31u) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return cam_write(base, RTLNET_CSI2_REG_RX_TAPS, tap0 | (tap1 << 8));
}

/* rtlnet_csi2_rx_set_settle -- HS settle time in clocks of the 200 MHz reference (0..255). */
int rtlnet_csi2_rx_set_settle(uintptr_t base, uint32_t clocks)
{
    if (clocks > 255u) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return cam_write(base, RTLNET_CSI2_REG_RX_SETTLE, clocks);
}

/* rtlnet_csi2_rx_set_filter -- virtual channel (0..3) and data type (0..63) the receiver accepts. */
int rtlnet_csi2_rx_set_filter(uintptr_t base, uint32_t vc, uint32_t dt)
{
    if (vc > 3u || dt > 63u) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return cam_write(base, RTLNET_CSI2_REG_RX_FILTER, vc | (dt << 8));
}

/* rtlnet_csi2_rx_set_black -- black level in 10-bit raw units (0..1023). */
int rtlnet_csi2_rx_set_black(uintptr_t base, uint32_t black)
{
    if (black > 1023u) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return cam_write(base, RTLNET_CSI2_REG_BLACK, black);
}

/*
 * rtlnet_csi2_rx_set_wb -- white balance gains, unsigned 4.8 fixed point (0x100 = 1.0)
 * Returns: OK, or ERR_ARG (a gain above 0xFFF, no camera receiver); nothing is written on ERR_ARG.
 */
int rtlnet_csi2_rx_set_wb(uintptr_t base, uint32_t gain_r, uint32_t gain_g, uint32_t gain_b)
{
    if (gain_r > 0xFFFu || gain_g > 0xFFFu || gain_b > 0xFFFu) {
        return RTLNET_CSI2_ERR_ARG;
    }
    if (camera_present(base) == 0) {
        return RTLNET_CSI2_ERR_ARG;
    }
    rtlnet_reg_write32(base, RTLNET_CSI2_REG_WB_R, gain_r);
    rtlnet_reg_write32(base, RTLNET_CSI2_REG_WB_G, gain_g);
    rtlnet_reg_write32(base, RTLNET_CSI2_REG_WB_B, gain_b);
    return RTLNET_CSI2_OK;
}

/* rtlnet_csi2_rx_set_phase -- Bayer phase of the first pixel of the first line (0 R, 1 Gr, 2 Gb, 3 B). */
int rtlnet_csi2_rx_set_phase(uintptr_t base, uint32_t phase)
{
    if (phase > 3u) {
        return RTLNET_CSI2_ERR_ARG;
    }
    return cam_write(base, RTLNET_CSI2_REG_PHASE, phase);
}

/* proc_update -- change the bits of mask in PROC and keep the others (read, modify, write after the presence check). */
static int proc_update(uintptr_t base, uint32_t mask, int on)
{
    uint32_t v;

    if (camera_present(base) == 0) {
        return RTLNET_CSI2_ERR_ARG;
    }
    v = rtlnet_reg_read32(base, RTLNET_CSI2_REG_PROC);
    v = (on != 0) ? (v | mask) : (v & ~mask);
    rtlnet_reg_write32(base, RTLNET_CSI2_REG_PROC, v);
    return RTLNET_CSI2_OK;
}

/* rtlnet_csi2_rx_set_gamma -- gamma curve on (1) or off (0); the other PROC bits keep their value. */
int rtlnet_csi2_rx_set_gamma(uintptr_t base, int enable)
{
    return proc_update(base, RTLNET_CSI2_PROC_GAMMA, enable);
}

/* rtlnet_csi2_rx_set_green_eq -- green equalisation on (1) or off (0); the other PROC bits keep their value. */
int rtlnet_csi2_rx_set_green_eq(uintptr_t base, int enable)
{
    return proc_update(base, RTLNET_CSI2_PROC_GREEN_EQ, enable);
}

/*
 * rtlnet_csi2_rx_read_rxstate -- read the camera receiver registers and the twelve counters
 * Returns: OK, or ERR_ARG (NULL, no camera receiver).
 */
int rtlnet_csi2_rx_read_rxstate(uintptr_t base, rtlnet_csi2_rx_rxstate_t *st)
{
    uint32_t i;

    if (st == NULL || camera_present(base) == 0) {
        return RTLNET_CSI2_ERR_ARG;
    }
    st->ctrl   = rtlnet_reg_read32(base, RTLNET_CSI2_REG_RX_CTRL);
    st->status = rtlnet_reg_read32(base, RTLNET_CSI2_REG_RX_STATUS);
    st->taps   = rtlnet_reg_read32(base, RTLNET_CSI2_REG_RX_TAPS);
    st->settle = rtlnet_reg_read32(base, RTLNET_CSI2_REG_RX_SETTLE);
    st->filter = rtlnet_reg_read32(base, RTLNET_CSI2_REG_RX_FILTER);
    st->lines  = rtlnet_reg_read32(base, RTLNET_CSI2_REG_RX_LINES);
    st->pixels = rtlnet_reg_read32(base, RTLNET_CSI2_REG_RX_PIXELS);
    for (i = 0u; i < RTLNET_CSI2_CNT_COUNT; i++) {
        st->counters[i] = rtlnet_reg_read32(base, RTLNET_CSI2_REG_CNT_BASE + 4u * i);
    }
    return RTLNET_CSI2_OK;
}

/* rtlnet_csi2_rx_clear_counters -- clear the counters whose bit is set in mask (bit n = counter n), or all with RTLNET_CSI2_CLEAR_ALL. */
int rtlnet_csi2_rx_clear_counters(uintptr_t base, uint32_t mask)
{
    return cam_write(base, RTLNET_CSI2_REG_RX_CLEAR, mask);
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
