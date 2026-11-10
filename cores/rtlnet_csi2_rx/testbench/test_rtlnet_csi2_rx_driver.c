/*
 * test_rtlnet_csi2_rx_driver.c -- host unit test of the rtlnet_csi2_rx driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs driver/rtlnet_csi2_rx.c on the PC against a register model of the Phase 1 window (header, VIDEO_MODE,
 * SOURCE, FRAME_PERIOD, CAM_TIMEOUT, STATUS with write-1-to-clear error flags, FRAME_COUNT, ACTIVE) through the
 * RTLNET_HOST_TEST hooks of rtlnet_mmio.h. The model rejects as the RTL does: a mode above 1 (MODE_ERR), a mode or a
 * period below the minimum of the selected mode (PERIOD_ERR), a source of 3 (SOURCE_ERR). Prints one line
 * "DRIVER TEST PASS: rtlnet_csi2_rx checks=<n>" or "DRIVER TEST FAIL: ..." and returns 0 / 1.
 *
 * Build and run: cores/rtlnet_csi2_rx/testbench/rtlnet_csi2_rx_driver_test.ps1
 */
#include "rtlnet_csi2_rx.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */

#define TEST_BASE    0x44A05000u
#define TEST_WINDOW  0x1000u

static uint32_t g_id = RTLNET_CSI2_ID_VALUE;
static uint32_t g_mode;
static uint32_t g_source;
static uint32_t g_period = RTLNET_CSI2_PERIOD_RESET;
static uint32_t g_timeout = RTLNET_CSI2_CAM_TIMEOUT_RESET;
static uint32_t g_err;
static uint32_t g_frames = 42u;
static int      g_bad_access;
static int      g_checks;
static int      g_fails;

static void check(int cond, const char *what)
{
    g_checks++;
    if (!cond) {
        g_fails++;
        printf("CHECK FAILED: %s\n", what);
    }
}

static uint32_t min_period(uint32_t mode)
{
    return (mode == RTLNET_CSI2_MODE_1080P30) ? RTLNET_CSI2_PERIOD_MIN_1080P30 : RTLNET_CSI2_PERIOD_MIN_720P30;
}

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    if (addr < TEST_BASE || off >= TEST_WINDOW || (off & 3u) != 0u) {
        g_bad_access = 1;
        return 0u;
    }
    switch (off) {
    case RTLNET_REG_ID:                return g_id;
    case RTLNET_REG_VERSION:           return RTLNET_CSI2_VERSION_VALUE;
    case RTLNET_REG_CAPS:              return RTLNET_CSI2_MODE_COUNT | RTLNET_CSI2_CAPS_PATTERN;
    case RTLNET_CSI2_REG_VIDEO_MODE:   return g_mode;
    case RTLNET_CSI2_REG_SOURCE:       return g_source;
    case RTLNET_CSI2_REG_FRAME_PERIOD: return g_period;
    case RTLNET_CSI2_REG_CAM_TIMEOUT:  return g_timeout;
    case RTLNET_CSI2_REG_STATUS:       return RTLNET_CSI2_STATUS_PATTERN | g_err;
    case RTLNET_CSI2_REG_FRAME_COUNT:  return g_frames;
    case RTLNET_CSI2_REG_ACTIVE:       return g_mode;
    default:                           return 0u;
    }
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    if (addr < TEST_BASE || off >= TEST_WINDOW || (off & 3u) != 0u) {
        g_bad_access = 1;
        return;
    }
    switch (off) {
    case RTLNET_CSI2_REG_VIDEO_MODE:
        if (value >= RTLNET_CSI2_MODE_COUNT) {
            g_err |= RTLNET_CSI2_STATUS_MODE_ERR;
        } else if (g_period < min_period(value)) {
            g_err |= RTLNET_CSI2_STATUS_PERIOD_ERR;
        } else {
            g_mode = value;
        }
        break;
    case RTLNET_CSI2_REG_SOURCE:
        if (value > RTLNET_CSI2_SRC_PATTERN) {
            g_err |= RTLNET_CSI2_STATUS_SOURCE_ERR;
        } else {
            g_source = value;
        }
        break;
    case RTLNET_CSI2_REG_FRAME_PERIOD:
        if (value < min_period(g_mode)) {
            g_err |= RTLNET_CSI2_STATUS_PERIOD_ERR;
        } else {
            g_period = value;
        }
        break;
    case RTLNET_CSI2_REG_CAM_TIMEOUT:
        g_timeout = value;
        break;
    case RTLNET_CSI2_REG_STATUS:
        g_err &= ~(value & RTLNET_CSI2_STATUS_ERR_MASK);
        break;
    default:
        break;
    }
}

int main(void)
{
    rtlnet_csi2_rx_caps_t caps;
    rtlnet_csi2_rx_state_t st;

    check(rtlnet_csi2_rx_probe(TEST_BASE, &caps) == RTLNET_CSI2_OK && caps.modes == 2u && caps.pattern == 1 && caps.camera == 0,
          "probe decodes CAPS");
    check(rtlnet_csi2_rx_probe(TEST_BASE, NULL) == RTLNET_CSI2_OK, "probe without caps");
    g_id = 0u;
    check(rtlnet_csi2_rx_probe(TEST_BASE, &caps) == RTLNET_CSI2_ERR_ARG, "wrong ID is ERR_ARG");
    g_id = RTLNET_CSI2_ID_VALUE;

    check(rtlnet_csi2_rx_read_state(TEST_BASE, &st) == RTLNET_CSI2_OK && st.video_mode == 0u && st.source == 0u &&
          st.frame_period == 3000000u && st.cam_timeout == 2u && st.frame_count == 42u && (st.status & RTLNET_CSI2_STATUS_PATTERN) != 0u,
          "reset state: 720p30, auto, 3,000,000, timeout 2, pattern active");
    check(rtlnet_csi2_rx_read_state(TEST_BASE, NULL) == RTLNET_CSI2_ERR_ARG, "read_state NULL");

    check(rtlnet_csi2_rx_set_mode(TEST_BASE, RTLNET_CSI2_MODE_1080P30) == RTLNET_CSI2_OK && g_mode == 1u, "set_mode 1080p30");
    check(rtlnet_csi2_rx_set_mode(TEST_BASE, 2u) == RTLNET_CSI2_ERR_ARG && g_mode == 1u && g_err == 0u,
          "set_mode 2 refused by the driver, nothing written");
    g_period = 2999500u;
    check(rtlnet_csi2_rx_set_mode(TEST_BASE, RTLNET_CSI2_MODE_720P30) == RTLNET_CSI2_ERR_REJECTED && g_mode == 1u && g_err == 0u,
          "set_mode 720p30 with a short period: rejected, flag cleared");
    g_period = RTLNET_CSI2_PERIOD_RESET;
    check(rtlnet_csi2_rx_set_mode(TEST_BASE, RTLNET_CSI2_MODE_720P30) == RTLNET_CSI2_OK && g_mode == 0u, "set_mode 720p30");

    check(rtlnet_csi2_rx_set_source(TEST_BASE, RTLNET_CSI2_SRC_PATTERN) == RTLNET_CSI2_OK && g_source == 2u, "set_source pattern");
    check(rtlnet_csi2_rx_set_source(TEST_BASE, 3u) == RTLNET_CSI2_ERR_ARG && g_source == 2u, "set_source 3 refused");
    g_err = RTLNET_CSI2_STATUS_SOURCE_ERR;
    check(rtlnet_csi2_rx_set_source(TEST_BASE, RTLNET_CSI2_SRC_AUTO) == RTLNET_CSI2_OK && g_source == 0u && g_err == 0u,
          "a stale error flag does not fail a good write");

    check(rtlnet_csi2_rx_set_frame_period(TEST_BASE, 2999999u) == RTLNET_CSI2_ERR_REJECTED && g_period == RTLNET_CSI2_PERIOD_RESET &&
          g_err == 0u, "period below the minimum rejected");
    check(rtlnet_csi2_rx_set_frame_period(TEST_BASE, RTLNET_CSI2_PERIOD_MIN_720P30) == RTLNET_CSI2_OK && g_period == 3000000u,
          "period at the minimum accepted");
    check(rtlnet_csi2_rx_set_rate_fps(TEST_BASE, 30u) == RTLNET_CSI2_OK && g_period == 3000000u, "30 fps is the reset period");
    check(rtlnet_csi2_rx_set_rate_fps(TEST_BASE, 15u) == RTLNET_CSI2_OK && g_period == 6000000u, "15 fps");
    check(rtlnet_csi2_rx_set_rate_fps(TEST_BASE, 0u) == RTLNET_CSI2_ERR_ARG && rtlnet_csi2_rx_set_rate_fps(TEST_BASE, 31u) == RTLNET_CSI2_ERR_ARG &&
          g_period == 6000000u, "0 and 31 fps refused, register unchanged");

    check(rtlnet_csi2_rx_mode_width(0u) == 1280u && rtlnet_csi2_rx_mode_height(0u) == 720u && rtlnet_csi2_rx_mode_width(1u) == 1920u &&
          rtlnet_csi2_rx_mode_height(1u) == 1080u && rtlnet_csi2_rx_mode_width(2u) == 0u && rtlnet_csi2_rx_mode_height(2u) == 0u,
          "mode geometry");
    check(g_bad_access == 0, "no unaligned or out-of-window access");

    if (g_fails == 0) {
        printf("DRIVER TEST PASS: rtlnet_csi2_rx checks=%d\n", g_checks);
        return 0;
    }
    printf("DRIVER TEST FAIL: rtlnet_csi2_rx fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
