/*
 * test_rtlnet_framebuf_driver.c -- host unit test of the rtlnet_framebuf driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs driver/rtlnet_framebuf.c on the PC against a register model (header, STATUS with the sticky FW_ERR,
 * CTRL.FW_TAKE and FW_RELEASE, the latest and firmware-held frame registers, counters, reference counts) through the
 * RTLNET_HOST_TEST hooks of rtlnet_mmio.h. A take with nothing published or while holding sets FW_ERR; a take can be
 * made to never complete (g_stall) to test the bounded poll. Prints one line "DRIVER TEST PASS: rtlnet_framebuf
 * checks=<n>" or "DRIVER TEST FAIL: ..." and returns 0 / 1.
 *
 * Build and run: cores/rtlnet_framebuf/testbench/rtlnet_framebuf_driver_test.ps1
 */
#include "rtlnet_framebuf.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */

#define TEST_BASE    0x44A07000u
#define TEST_WINDOW  0x1000u
#define FB_OFFSET    0x10000000u
#define SLOT_BYTES   0x400000u

static uint32_t g_id = RTLNET_FB_ID_VALUE;
static uint32_t g_published = 7u;         /* frames published; frame k is in slot (k - 1) % 3 */
static int      g_holds;
static uint32_t g_fw_slot;
static uint32_t g_fw_frame;
static uint32_t g_err;
static uint32_t g_takes;
static int      g_stall;
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

static uint32_t latest_slot(void)
{
    return (g_published == 0u) ? 0u : ((g_published - 1u) % 3u);
}

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    if (addr < TEST_BASE || off >= TEST_WINDOW || (off & 3u) != 0u) {
        g_bad_access = 1;
        return 0u;
    }
    switch (off) {
    case RTLNET_REG_ID:               return g_id;
    case RTLNET_REG_VERSION:          return RTLNET_FB_VERSION_VALUE;
    case RTLNET_REG_CAPS:             return 3u | (1u << 4) | (22u << 8) | (29u << 16);
    case RTLNET_FB_REG_STATUS:        return ((g_published != 0u) ? RTLNET_FB_STATUS_LATEST_VALID : 0u) |
                                             (g_holds ? RTLNET_FB_STATUS_FW_HOLDS : 0u) | g_err | (latest_slot() << 8) | (g_fw_slot << 16);
    case RTLNET_FB_REG_FB_BASE:       return FB_OFFSET;
    case RTLNET_FB_REG_SLOT_BYTES:    return SLOT_BYTES;
    case RTLNET_FB_REG_LATEST_BASE:   return FB_OFFSET + (latest_slot() * SLOT_BYTES);
    case RTLNET_FB_REG_LATEST_FRAME:  return g_published;
    case RTLNET_FB_REG_LATEST_TS:     return g_published * 3000000u;
    case RTLNET_FB_REG_LATEST_WH:     return (720u << 16) | 1280u;
    case RTLNET_FB_REG_LATEST_SRC:    return 1u;
    case RTLNET_FB_REG_FW_BASE:       return FB_OFFSET + (g_fw_slot * SLOT_BYTES);
    case RTLNET_FB_REG_FW_FRAME:      return g_fw_frame;
    case RTLNET_FB_REG_FW_TS:         return g_fw_frame * 3000000u;
    case RTLNET_FB_REG_FW_WH:         return (720u << 16) | 1280u;
    case RTLNET_FB_REG_FW_SRC:        return 1u;
    case RTLNET_FB_REG_PUBLISHED:     return g_published;
    case RTLNET_FB_REG_DROPPED:       return 1u;
    case RTLNET_FB_REG_BAD:           return 2u;
    case RTLNET_FB_REG_FW_TAKES:      return g_takes;
    case RTLNET_FB_REG_REFCNT + 0u:   return (g_holds && g_fw_slot == 0u) ? 1u : 0u;
    case RTLNET_FB_REG_REFCNT + 4u:   return (g_holds && g_fw_slot == 1u) ? 1u : 0u;
    case RTLNET_FB_REG_REFCNT + 8u:   return (g_holds && g_fw_slot == 2u) ? 1u : 0u;
    default:                          return 0u;
    }
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    if (addr < TEST_BASE || off >= TEST_WINDOW || (off & 3u) != 0u) {
        g_bad_access = 1;
        return;
    }
    if (off == RTLNET_FB_REG_STATUS) {
        g_err &= ~(value & RTLNET_FB_STATUS_FW_ERR);
    } else if (off == RTLNET_FB_REG_CTRL) {
        if ((value & RTLNET_FB_CTRL_FW_TAKE) != 0u && !g_stall) {
            if (g_published == 0u || g_holds) {
                g_err |= RTLNET_FB_STATUS_FW_ERR;
            } else {
                g_holds = 1;
                g_fw_slot = latest_slot();
                g_fw_frame = g_published;
                g_takes++;
            }
        }
        if ((value & RTLNET_FB_CTRL_FW_RELEASE) != 0u) {
            if (g_holds) {
                g_holds = 0;
            } else {
                g_err |= RTLNET_FB_STATUS_FW_ERR;
            }
        }
        if ((value & RTLNET_FB_CTRL_CNT_CLEAR) != 0u) {
            g_takes = 0u;
        }
    }
}

int main(void)
{
    rtlnet_framebuf_caps_t caps;
    rtlnet_framebuf_state_t st;
    rtlnet_framebuf_frame_t f;

    check(rtlnet_framebuf_probe(TEST_BASE, &caps) == RTLNET_FB_OK && caps.slots == 3u && caps.readers == 1u &&
          caps.slot_bytes == SLOT_BYTES && caps.addr_bits == 29u, "probe decodes CAPS");
    g_id = 0u;
    check(rtlnet_framebuf_probe(TEST_BASE, &caps) == RTLNET_FB_ERR_ARG, "wrong ID is ERR_ARG");
    g_id = RTLNET_FB_ID_VALUE;

    check(rtlnet_framebuf_read_state(TEST_BASE, &st) == RTLNET_FB_OK && st.fb_base == FB_OFFSET && st.slot_bytes == SLOT_BYTES &&
          st.published == 7u && st.dropped == 1u && st.bad == 2u && st.latest.frame == 7u && st.latest.width == 1280u &&
          st.latest.height == 720u && st.latest.pattern == 1u && st.latest.base == FB_OFFSET && st.refcnt[0] == 0u && st.refcnt[3] == 0u &&
          (st.status & RTLNET_FB_STATUS_LATEST_VALID) != 0u && ((st.status >> RTLNET_FB_STATUS_LATEST_SHIFT) & 0xFFu) == 0u,
          "read_state: frame 7 is in slot 0");
    check(rtlnet_framebuf_read_state(TEST_BASE, NULL) == RTLNET_FB_ERR_ARG, "read_state NULL");

    check(rtlnet_framebuf_fw_take(TEST_BASE, &f) == RTLNET_FB_OK && f.frame == 7u && f.base == FB_OFFSET && f.width == 1280u && f.height == 720u &&
          f.pattern == 1u && g_holds == 1, "take the latest frame");
    check(rtlnet_framebuf_read_state(TEST_BASE, &st) == RTLNET_FB_OK && st.refcnt[0] == 1u && st.fw_takes == 1u, "reference count of the held slot");
    check(rtlnet_framebuf_fw_take(TEST_BASE, &f) == RTLNET_FB_ERR_NO_FRAME && g_err == 0u && g_holds == 1, "second take refused, FW_ERR cleared");
    check(rtlnet_framebuf_fw_release(TEST_BASE) == RTLNET_FB_OK && g_holds == 0, "release");
    check(rtlnet_framebuf_fw_release(TEST_BASE) == RTLNET_FB_ERR_NO_FRAME && g_err == 0u, "release while not holding refused, nothing written");

    g_published = 0u;
    check(rtlnet_framebuf_fw_take(TEST_BASE, &f) == RTLNET_FB_ERR_NO_FRAME && g_err == 0u && g_holds == 0, "take with nothing published");
    g_published = 8u;
    g_stall = 1;
    check(rtlnet_framebuf_fw_take(TEST_BASE, &f) == RTLNET_FB_ERR_TIMEOUT, "a take that never completes times out (bounded poll)");
    g_stall = 0;
    check(rtlnet_framebuf_fw_take(TEST_BASE, NULL) == RTLNET_FB_ERR_ARG, "take NULL");
    check(rtlnet_framebuf_fw_take(TEST_BASE, &f) == RTLNET_FB_OK && f.frame == 8u && g_fw_slot == 1u, "frame 8 is in slot 1");
    check(rtlnet_framebuf_fw_release(TEST_BASE) == RTLNET_FB_OK, "release again");
    rtlnet_framebuf_clear(TEST_BASE);
    check(g_takes == 0u, "clear zeroes the take counter");
    check(g_bad_access == 0, "no unaligned or out-of-window access");

    if (g_fails == 0) {
        printf("DRIVER TEST PASS: rtlnet_framebuf checks=%d\n", g_checks);
        return 0;
    }
    printf("DRIVER TEST FAIL: rtlnet_framebuf fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
