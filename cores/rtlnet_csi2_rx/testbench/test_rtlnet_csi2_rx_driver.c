/*
 * test_rtlnet_csi2_rx_driver.c -- host unit test of the rtlnet_csi2_rx driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs driver/rtlnet_csi2_rx.c on the PC against a register model of the window (header, VIDEO_MODE,
 * SOURCE, FRAME_PERIOD, CAM_TIMEOUT, STATUS with write-1-to-clear error flags, FRAME_COUNT, ACTIVE, PATTERN, PATTERN_FRAME) through
 * the RTLNET_HOST_TEST hooks of rtlnet_mmio.h. The model rejects as the RTL does: a mode above 1 (MODE_ERR), a mode or a
 * period below the minimum of the selected mode (PERIOD_ERR), a source of 3 (SOURCE_ERR), a PATTERN value with a pattern above 4,
 * a bit set outside [2:0] and [15:8], or a speed beyond +-32 (PATTERN_ERR). The model runs twice: as the core without the camera receiver
 * (VERSION 0x11102026, the camera registers read 0) and as the core with it (VERSION 0x11152026, CAPS camera bit, the camera registers with the
 * field masks of the RTL, counters that clear by RX_CLEAR). Prints one line
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
static uint32_t g_pattern = 0x00000400u;
static uint32_t g_pat_frames = 5u;
static int      g_bad_access;
static int      g_camera;                 /* 1: the model is the core with the camera receiver */
static uint32_t g_rx_ctrl = 0x0Du;
static uint32_t g_rx_taps;
static uint32_t g_rx_settle = 28u;
static uint32_t g_rx_filter = 0x2B00u;
static uint32_t g_black;
static uint32_t g_wb[3] = { 0x100u, 0x100u, 0x100u };
static uint32_t g_phase;
static uint32_t g_proc;
static uint32_t g_hl_level;
static uint32_t g_raw_max = (3u << 20) | (2u << 10) | 1u;   /* blue 3, green 2, red 1 */
static uint32_t g_cnt[RTLNET_CSI2_CNT_COUNT];
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
    case RTLNET_REG_VERSION:           return g_camera ? RTLNET_CSI2_VERSION_CAMERA : RTLNET_CSI2_VERSION_VALUE;
    case RTLNET_REG_CAPS:              return RTLNET_CSI2_MODE_COUNT | RTLNET_CSI2_CAPS_PATTERN | RTLNET_CSI2_CAPS_MOVING |
                                              (g_camera ? RTLNET_CSI2_CAPS_CAMERA : 0u);
    case RTLNET_CSI2_REG_VIDEO_MODE:   return g_mode;
    case RTLNET_CSI2_REG_SOURCE:       return g_source;
    case RTLNET_CSI2_REG_FRAME_PERIOD: return g_period;
    case RTLNET_CSI2_REG_CAM_TIMEOUT:  return g_timeout;
    case RTLNET_CSI2_REG_STATUS:       return RTLNET_CSI2_STATUS_PATTERN | g_err;
    case RTLNET_CSI2_REG_FRAME_COUNT:  return g_frames;
    case RTLNET_CSI2_REG_ACTIVE:       return g_mode;
    case RTLNET_CSI2_REG_PATTERN:      return g_pattern;
    case RTLNET_CSI2_REG_PATTERN_FRAME: return g_pat_frames;
    default:
        break;
    }
    if (!g_camera) {
        return 0u;
    }
    switch (off) {
    case RTLNET_CSI2_REG_RX_CTRL:      return g_rx_ctrl;
    case RTLNET_CSI2_REG_RX_STATUS:    return RTLNET_CSI2_RXST_CLK_RUN | (3u << RTLNET_CSI2_RXST_LP_D0_SHIFT) | (3u << RTLNET_CSI2_RXST_LP_D1_SHIFT);
    case RTLNET_CSI2_REG_RX_TAPS:      return g_rx_taps;
    case RTLNET_CSI2_REG_RX_SETTLE:    return g_rx_settle;
    case RTLNET_CSI2_REG_RX_FILTER:    return g_rx_filter;
    case RTLNET_CSI2_REG_RX_LINES:     return 720u;
    case RTLNET_CSI2_REG_RX_PIXELS:    return 1280u;
    case RTLNET_CSI2_REG_BLACK:        return g_black;
    case RTLNET_CSI2_REG_WB_R:         return g_wb[0];
    case RTLNET_CSI2_REG_WB_G:         return g_wb[1];
    case RTLNET_CSI2_REG_WB_B:         return g_wb[2];
    case RTLNET_CSI2_REG_PHASE:        return g_phase;
    case RTLNET_CSI2_REG_PROC:         return g_proc;
    case RTLNET_CSI2_REG_RAW_MAX:      return g_raw_max;
    case RTLNET_CSI2_REG_HL_LEVEL:     return g_hl_level;
    default:
        if (off >= RTLNET_CSI2_REG_CNT_BASE && off < RTLNET_CSI2_REG_CNT_BASE + 4u * RTLNET_CSI2_CNT_COUNT) {
            return g_cnt[(off - RTLNET_CSI2_REG_CNT_BASE) / 4u];
        }
        return 0u;
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
    case RTLNET_CSI2_REG_PATTERN: {
        uint32_t spd = (value >> 8) & 0xFFu;
        int ok = ((value & 0xFFFF0000u) == 0u) && ((value & 0xF8u) == 0u) && ((value & 7u) < RTLNET_CSI2_PATTERN_COUNT) &&
                 (spd <= 32u || spd >= 0xE0u);
        if (ok) {
            g_pattern = value;
            g_pat_frames = 0u;
        } else {
            g_err |= RTLNET_CSI2_STATUS_PATTERN_ERR;
        }
        break;
    }
    case RTLNET_CSI2_REG_STATUS:
        g_err &= ~(value & RTLNET_CSI2_STATUS_ERR_MASK);
        break;
    default:
        if (!g_camera) {
            break;
        }
        switch (off) {
        case RTLNET_CSI2_REG_RX_CTRL:   g_rx_ctrl = value & 0x1Fu; break;
        case RTLNET_CSI2_REG_RX_TAPS:   g_rx_taps = value & 0x1F1Fu; break;
        case RTLNET_CSI2_REG_RX_SETTLE: g_rx_settle = value & 0xFFu; break;
        case RTLNET_CSI2_REG_RX_FILTER: g_rx_filter = value & 0x3F03u; break;
        case RTLNET_CSI2_REG_BLACK:     g_black = value & 0x3FFu; break;
        case RTLNET_CSI2_REG_WB_R:      g_wb[0] = value & 0xFFFu; break;
        case RTLNET_CSI2_REG_WB_G:      g_wb[1] = value & 0xFFFu; break;
        case RTLNET_CSI2_REG_WB_B:      g_wb[2] = value & 0xFFFu; break;
        case RTLNET_CSI2_REG_PHASE:     g_phase = value & 3u; break;
        case RTLNET_CSI2_REG_PROC:      g_proc = value & 7u; break;
        case RTLNET_CSI2_REG_HL_LEVEL:  g_hl_level = value & 0x3FFu; break;
        case RTLNET_CSI2_REG_RAW_MAX:   break;   /* read only */
        case RTLNET_CSI2_REG_RX_CLEAR: {
            uint32_t i;
            for (i = 0u; i < RTLNET_CSI2_CNT_COUNT; i++) {
                if ((value & RTLNET_CSI2_CLEAR_ALL) != 0u || (value & (1u << i)) != 0u) {
                    g_cnt[i] = 0u;
                }
            }
            break;
        }
        default:
            break;
        }
        break;
    }
}

int main(void)
{
    rtlnet_csi2_rx_caps_t caps;
    rtlnet_csi2_rx_state_t st;

    check(rtlnet_csi2_rx_probe(TEST_BASE, &caps) == RTLNET_CSI2_OK && caps.modes == 2u && caps.pattern == 1 && caps.camera == 0 &&
          caps.moving == 1, "probe decodes CAPS");
    check(rtlnet_csi2_rx_probe(TEST_BASE, NULL) == RTLNET_CSI2_OK, "probe without caps");
    g_id = 0u;
    check(rtlnet_csi2_rx_probe(TEST_BASE, &caps) == RTLNET_CSI2_ERR_ARG, "wrong ID is ERR_ARG");
    g_id = RTLNET_CSI2_ID_VALUE;

    check(rtlnet_csi2_rx_read_state(TEST_BASE, &st) == RTLNET_CSI2_OK && st.video_mode == 0u && st.source == 0u &&
          st.frame_period == 3000000u && st.cam_timeout == 2u && st.frame_count == 42u && (st.status & RTLNET_CSI2_STATUS_PATTERN) != 0u &&
          st.pattern == RTLNET_CSI2_PATTERN_BARS && st.pattern_speed == RTLNET_CSI2_SPEED_RESET && st.pattern_frame == 5u,
          "reset state: 720p30, auto, 3,000,000, timeout 2, pattern active, static bars at speed 4");
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
    /* Test patterns. */
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, RTLNET_CSI2_PATTERN_ALL, -7) == RTLNET_CSI2_OK && g_pattern == 0x0000F904u && g_pat_frames == 0u,
          "set_pattern all, speed -7: written as 0xF904, counter restarted");
    check(rtlnet_csi2_rx_read_state(TEST_BASE, &st) == RTLNET_CSI2_OK && st.pattern == 4u && st.pattern_speed == -7 && st.pattern_frame == 0u,
          "read_state decodes the pattern, the signed speed and the counter");
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, RTLNET_CSI2_PATTERN_SCROLL, RTLNET_CSI2_SPEED_MAX) == RTLNET_CSI2_OK && g_pattern == 0x00002001u,
          "set_pattern scroll, speed +32");
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, RTLNET_CSI2_PATTERN_BOX, -RTLNET_CSI2_SPEED_MAX) == RTLNET_CSI2_OK && g_pattern == 0x0000E002u,
          "set_pattern box, speed -32");
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, RTLNET_CSI2_PATTERN_NOISE, 0) == RTLNET_CSI2_OK && g_pattern == 0x00000003u, "set_pattern noise, speed 0");
    g_pat_frames = 9u;
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, 5u, 4) == RTLNET_CSI2_ERR_REJECTED && g_pattern == 0x00000003u && g_err == 0u && g_pat_frames == 9u,
          "pattern 5 rejected by the core, flag cleared, register and counter unchanged");
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, 7u, 4) == RTLNET_CSI2_ERR_REJECTED && g_pattern == 0x00000003u && g_err == 0u, "pattern 7 rejected");
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, 4u, 33) == RTLNET_CSI2_ERR_REJECTED && g_pattern == 0x00000003u && g_err == 0u, "speed 33 rejected");
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, 4u, -33) == RTLNET_CSI2_ERR_REJECTED && g_pattern == 0x00000003u && g_err == 0u, "speed -33 rejected");
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, 4u, 127) == RTLNET_CSI2_ERR_REJECTED && rtlnet_csi2_rx_set_pattern(TEST_BASE, 4u, -128) == RTLNET_CSI2_ERR_REJECTED &&
          g_pattern == 0x00000003u, "speed 127 and -128 rejected");
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, 256u, 4) == RTLNET_CSI2_ERR_ARG && rtlnet_csi2_rx_set_pattern(TEST_BASE, 4u, 128) == RTLNET_CSI2_ERR_ARG &&
          rtlnet_csi2_rx_set_pattern(TEST_BASE, 4u, -129) == RTLNET_CSI2_ERR_ARG && g_pattern == 0x00000003u && g_err == 0u,
          "values that do not fit the fields: ERR_ARG, nothing written");
    g_err = RTLNET_CSI2_STATUS_PATTERN_ERR;
    check(rtlnet_csi2_rx_set_pattern(TEST_BASE, RTLNET_CSI2_PATTERN_BARS, RTLNET_CSI2_SPEED_RESET) == RTLNET_CSI2_OK && g_pattern == 0x00000400u && g_err == 0u,
          "a stale PATTERN_ERR does not fail a good write; back to the reset value");
    check(g_bad_access == 0, "no unaligned or out-of-window access");

    /* Without the camera receiver every camera function refuses and writes nothing. */
    {
        rtlnet_csi2_rx_rxstate_t rs;
        check(rtlnet_csi2_rx_set_taps(TEST_BASE, 1u, 2u) == RTLNET_CSI2_ERR_ARG && g_rx_taps == 0u, "no camera: set_taps refused");
        check(rtlnet_csi2_rx_set_wb(TEST_BASE, 1u, 2u, 3u) == RTLNET_CSI2_ERR_ARG && g_wb[0] == 0x100u, "no camera: set_wb refused");
        check(rtlnet_csi2_rx_read_rxstate(TEST_BASE, &rs) == RTLNET_CSI2_ERR_ARG, "no camera: read_rxstate refused");
        {
            uint32_t mr = 0u, mg = 0u, mb = 0u;
            check(rtlnet_csi2_rx_set_highlight(TEST_BASE, 1, 5u) == RTLNET_CSI2_ERR_ARG && g_hl_level == 0u && g_proc == 0u &&
                  rtlnet_csi2_rx_read_raw_max(TEST_BASE, &mr, &mg, &mb) == RTLNET_CSI2_ERR_ARG, "no camera: set_highlight and read_raw_max refused");
        }
        check(rtlnet_csi2_rx_clear_counters(TEST_BASE, RTLNET_CSI2_CLEAR_ALL) == RTLNET_CSI2_ERR_ARG, "no camera: clear_counters refused");
    }

    /* The core with the camera receiver. */
    g_camera = 1;
    {
        rtlnet_csi2_rx_rxstate_t rs;
        check(rtlnet_csi2_rx_probe(TEST_BASE, &caps) == RTLNET_CSI2_OK && caps.camera == 1, "camera core: probe accepts VERSION 0x11152026, camera bit set");
        check(rtlnet_csi2_rx_read_rxstate(TEST_BASE, NULL) == RTLNET_CSI2_ERR_ARG, "read_rxstate NULL");
        check(rtlnet_csi2_rx_read_rxstate(TEST_BASE, &rs) == RTLNET_CSI2_OK && rs.ctrl == 0x0Du && rs.settle == 28u && rs.filter == 0x2B00u &&
              rs.taps == 0u && (rs.status & RTLNET_CSI2_RXST_CLK_RUN) != 0u && ((rs.status >> RTLNET_CSI2_RXST_LP_D0_SHIFT) & 3u) == 3u &&
              rs.lines == 720u && rs.pixels == 1280u, "camera reset state");
        check(rtlnet_csi2_rx_rx_control(TEST_BASE, 1, 1, 3u, 0) == RTLNET_CSI2_OK && g_rx_ctrl == 0x0Fu, "rx_control: soft reset set");
        check(rtlnet_csi2_rx_rx_control(TEST_BASE, 1, 0, 1u, 1) == RTLNET_CSI2_OK && g_rx_ctrl == 0x15u, "rx_control: one lane, bit order");
        check(rtlnet_csi2_rx_rx_control(TEST_BASE, 1, 0, 4u, 0) == RTLNET_CSI2_ERR_ARG && g_rx_ctrl == 0x15u, "rx_control: lane_en 4 refused");
        check(rtlnet_csi2_rx_rx_control(TEST_BASE, 1, 0, 3u, 0) == RTLNET_CSI2_OK && g_rx_ctrl == 0x0Du, "rx_control: back to the reset value");
        check(rtlnet_csi2_rx_set_taps(TEST_BASE, 31u, 5u) == RTLNET_CSI2_OK && g_rx_taps == 0x051Fu, "set_taps 31 and 5");
        check(rtlnet_csi2_rx_set_taps(TEST_BASE, 32u, 0u) == RTLNET_CSI2_ERR_ARG && rtlnet_csi2_rx_set_taps(TEST_BASE, 0u, 32u) == RTLNET_CSI2_ERR_ARG &&
              g_rx_taps == 0x051Fu, "set_taps 32 refused, nothing written");
        check(rtlnet_csi2_rx_set_settle(TEST_BASE, 255u) == RTLNET_CSI2_OK && g_rx_settle == 255u &&
              rtlnet_csi2_rx_set_settle(TEST_BASE, 256u) == RTLNET_CSI2_ERR_ARG && g_rx_settle == 255u, "set_settle 255 accepted, 256 refused");
        check(rtlnet_csi2_rx_set_filter(TEST_BASE, 3u, 0x12u) == RTLNET_CSI2_OK && g_rx_filter == 0x1203u &&
              rtlnet_csi2_rx_set_filter(TEST_BASE, 4u, 0x12u) == RTLNET_CSI2_ERR_ARG && rtlnet_csi2_rx_set_filter(TEST_BASE, 0u, 64u) == RTLNET_CSI2_ERR_ARG &&
              g_rx_filter == 0x1203u, "set_filter");
        check(rtlnet_csi2_rx_set_black(TEST_BASE, 16u) == RTLNET_CSI2_OK && g_black == 16u && rtlnet_csi2_rx_set_black(TEST_BASE, 1024u) == RTLNET_CSI2_ERR_ARG &&
              g_black == 16u, "set_black");
        check(rtlnet_csi2_rx_set_wb(TEST_BASE, 0x180u, 0x100u, 0x1C0u) == RTLNET_CSI2_OK && g_wb[0] == 0x180u && g_wb[1] == 0x100u && g_wb[2] == 0x1C0u,
              "set_wb");
        check(rtlnet_csi2_rx_set_wb(TEST_BASE, 0x1000u, 1u, 1u) == RTLNET_CSI2_ERR_ARG && g_wb[0] == 0x180u && g_wb[1] == 0x100u, "set_wb 0x1000 refused, nothing written");
        check(rtlnet_csi2_rx_set_phase(TEST_BASE, 3u) == RTLNET_CSI2_OK && g_phase == 3u && rtlnet_csi2_rx_set_phase(TEST_BASE, 4u) == RTLNET_CSI2_ERR_ARG &&
              g_phase == 3u, "set_phase");
        check(rtlnet_csi2_rx_set_gamma(TEST_BASE, 1) == RTLNET_CSI2_OK && g_proc == 1u && rtlnet_csi2_rx_set_gamma(TEST_BASE, 0) == RTLNET_CSI2_OK && g_proc == 0u,
              "set_gamma");
        check(rtlnet_csi2_rx_set_green_eq(TEST_BASE, 1) == RTLNET_CSI2_OK && g_proc == 2u && rtlnet_csi2_rx_set_gamma(TEST_BASE, 1) == RTLNET_CSI2_OK && g_proc == 3u &&
              rtlnet_csi2_rx_set_gamma(TEST_BASE, 0) == RTLNET_CSI2_OK && g_proc == 2u && rtlnet_csi2_rx_set_green_eq(TEST_BASE, 0) == RTLNET_CSI2_OK && g_proc == 0u,
              "set_green_eq and set_gamma keep each other's bit");
        {
            uint32_t mr = 99u, mg = 99u, mb = 99u;
            check(rtlnet_csi2_rx_set_highlight(TEST_BASE, 1, 700u) == RTLNET_CSI2_OK && g_hl_level == 700u && g_proc == 4u &&
                  rtlnet_csi2_rx_set_gamma(TEST_BASE, 1) == RTLNET_CSI2_OK && g_proc == 5u &&
                  rtlnet_csi2_rx_set_highlight(TEST_BASE, 0, 1023u) == RTLNET_CSI2_OK && g_hl_level == 1023u && g_proc == 1u &&
                  rtlnet_csi2_rx_set_gamma(TEST_BASE, 0) == RTLNET_CSI2_OK && g_proc == 0u, "set_highlight keeps the other PROC bits, level 1023 accepted");
            check(rtlnet_csi2_rx_set_highlight(TEST_BASE, 1, 1024u) == RTLNET_CSI2_ERR_ARG && g_hl_level == 1023u && g_proc == 0u,
                  "set_highlight level 1024 refused, nothing written");
            check(rtlnet_csi2_rx_read_raw_max(TEST_BASE, &mr, &mg, &mb) == RTLNET_CSI2_OK && mr == 1u && mg == 2u && mb == 3u, "read_raw_max fields");
            check(rtlnet_csi2_rx_read_raw_max(TEST_BASE, NULL, &mg, &mb) == RTLNET_CSI2_ERR_ARG && rtlnet_csi2_rx_read_raw_max(TEST_BASE, &mr, &mg, NULL) == RTLNET_CSI2_ERR_ARG,
                  "read_raw_max NULL refused");
        }
        g_cnt[RTLNET_CSI2_CNT_CRC] = 7u;
        g_cnt[RTLNET_CSI2_CNT_CLKLOSS] = 9u;
        check(rtlnet_csi2_rx_read_rxstate(TEST_BASE, &rs) == RTLNET_CSI2_OK && rs.counters[RTLNET_CSI2_CNT_CRC] == 7u &&
              rs.counters[RTLNET_CSI2_CNT_CLKLOSS] == 9u && rs.counters[RTLNET_CSI2_CNT_ECC_CORR] == 0u, "read_rxstate reads the counters in index order");
        check(rtlnet_csi2_rx_clear_counters(TEST_BASE, 1u << RTLNET_CSI2_CNT_CRC) == RTLNET_CSI2_OK && g_cnt[RTLNET_CSI2_CNT_CRC] == 0u &&
              g_cnt[RTLNET_CSI2_CNT_CLKLOSS] == 9u, "clear one counter");
        check(rtlnet_csi2_rx_clear_counters(TEST_BASE, RTLNET_CSI2_CLEAR_ALL) == RTLNET_CSI2_OK && g_cnt[RTLNET_CSI2_CNT_CLKLOSS] == 0u, "clear all counters");
        check(g_bad_access == 0, "camera registers: no unaligned or out-of-window access");
    }

    if (g_fails == 0) {
        printf("DRIVER TEST PASS: rtlnet_csi2_rx checks=%d\n", g_checks);
        return 0;
    }
    printf("DRIVER TEST FAIL: rtlnet_csi2_rx fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
