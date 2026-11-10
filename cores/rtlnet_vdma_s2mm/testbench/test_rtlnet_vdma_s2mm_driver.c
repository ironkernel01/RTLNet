/*
 * test_rtlnet_vdma_s2mm_driver.c -- host unit test of the rtlnet_vdma_s2mm driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs driver/rtlnet_vdma_s2mm.c on the PC against a register model (header, CTRL with the self-clearing
 * CNT_CLEAR, STATUS with write-1-to-clear error flags, STRIDE, read-only counters) through the RTLNET_HOST_TEST hooks
 * of rtlnet_mmio.h. Prints one line "DRIVER TEST PASS: rtlnet_vdma_s2mm checks=<n>" or "DRIVER TEST FAIL: ..." and
 * returns 0 / 1.
 *
 * Build and run: cores/rtlnet_vdma_s2mm/testbench/rtlnet_vdma_s2mm_driver_test.ps1
 */
#include "rtlnet_vdma_s2mm.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */

#define TEST_BASE    0x44A06000u
#define TEST_WINDOW  0x1000u

static uint32_t g_id = RTLNET_S2MM_ID_VALUE;
static uint32_t g_ctrl = RTLNET_S2MM_CTRL_ENABLE;
static uint32_t g_err = RTLNET_S2MM_STATUS_AXI_ERR | RTLNET_S2MM_STATUS_LINE_ERR;
static uint32_t g_stride;
static uint32_t g_cnt[6] = { 10u, 2u, 3u, 400u, 5000u, 0x10000000u };   /* ok, bad, dropped, bursts, beats, last base */
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

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    if (addr < TEST_BASE || off >= TEST_WINDOW || (off & 3u) != 0u) {
        g_bad_access = 1;
        return 0u;
    }
    switch (off) {
    case RTLNET_REG_ID:                     return g_id;
    case RTLNET_REG_VERSION:                return RTLNET_S2MM_VERSION_VALUE;
    case RTLNET_REG_CAPS:                   return 16u | (16u << 8) | (29u << 16);
    case RTLNET_S2MM_REG_CTRL:              return g_ctrl & RTLNET_S2MM_CTRL_ENABLE;
    case RTLNET_S2MM_REG_STATUS:            return g_err | RTLNET_S2MM_STATUS_BUSY;
    case RTLNET_S2MM_REG_STRIDE:            return g_stride;
    case RTLNET_S2MM_REG_FRAMES_OK:         return g_cnt[0];
    case RTLNET_S2MM_REG_FRAMES_BAD:        return g_cnt[1];
    case RTLNET_S2MM_REG_FRAMES_DROPPED:    return g_cnt[2];
    case RTLNET_S2MM_REG_BURSTS:            return g_cnt[3];
    case RTLNET_S2MM_REG_BEATS:             return g_cnt[4];
    case RTLNET_S2MM_REG_LAST_BASE:         return g_cnt[5];
    default:                                return 0u;
    }
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    if (addr < TEST_BASE || off >= TEST_WINDOW || (off & 3u) != 0u) {
        g_bad_access = 1;
        return;
    }
    if (off == RTLNET_S2MM_REG_CTRL) {
        g_ctrl = value & RTLNET_S2MM_CTRL_ENABLE;
        if ((value & RTLNET_S2MM_CTRL_CNT_CLEAR) != 0u) {
            for (unsigned i = 0; i < 5u; i++) {
                g_cnt[i] = 0u;
            }
        }
    } else if (off == RTLNET_S2MM_REG_STATUS) {
        g_err &= ~(value & RTLNET_S2MM_STATUS_ERR_MASK);
    } else if (off == RTLNET_S2MM_REG_STRIDE) {
        g_stride = value;
    }
}

int main(void)
{
    rtlnet_vdma_s2mm_caps_t caps;
    rtlnet_vdma_s2mm_state_t st;

    check(rtlnet_vdma_s2mm_probe(TEST_BASE, &caps) == RTLNET_S2MM_OK && caps.max_burst_beats == 16u && caps.bytes_per_beat == 16u &&
          caps.addr_bits == 29u, "probe decodes CAPS");
    g_id = 0u;
    check(rtlnet_vdma_s2mm_probe(TEST_BASE, &caps) == RTLNET_S2MM_ERR_ARG, "wrong ID is ERR_ARG");
    g_id = RTLNET_S2MM_ID_VALUE;

    check(rtlnet_vdma_s2mm_read_state(TEST_BASE, &st) == RTLNET_S2MM_OK && st.ctrl == 1u && st.frames_ok == 10u && st.frames_bad == 2u &&
          st.frames_dropped == 3u && st.bursts == 400u && st.beats == 5000u && st.last_base == 0x10000000u &&
          (st.status & RTLNET_S2MM_STATUS_BUSY) != 0u && (st.status & RTLNET_S2MM_STATUS_ERR_MASK) == 0x0Cu, "read_state");
    check(rtlnet_vdma_s2mm_read_state(TEST_BASE, NULL) == RTLNET_S2MM_ERR_ARG, "read_state NULL");

    check(rtlnet_vdma_s2mm_set_stride(TEST_BASE, 5120u) == RTLNET_S2MM_OK && g_stride == 5120u, "stride 5120");
    check(rtlnet_vdma_s2mm_set_stride(TEST_BASE, 5121u) == RTLNET_S2MM_ERR_ARG && g_stride == 5120u, "stride not a multiple of 16 refused");
    check(rtlnet_vdma_s2mm_set_stride(TEST_BASE, 0u) == RTLNET_S2MM_OK && g_stride == 0u, "stride 0 is packed");

    check(rtlnet_vdma_s2mm_enable(TEST_BASE, 0) == RTLNET_S2MM_OK && g_ctrl == 0u, "disable");
    check(rtlnet_vdma_s2mm_enable(TEST_BASE, 1) == RTLNET_S2MM_OK && g_ctrl == 1u, "enable");
    rtlnet_vdma_s2mm_clear(TEST_BASE);
    check(g_cnt[0] == 0u && g_cnt[4] == 0u && g_ctrl == 1u, "clear zeroes the counters and keeps ENABLE");
    rtlnet_vdma_s2mm_err_clear(TEST_BASE);
    check(g_err == 0u, "err_clear clears the sticky flags");
    check(g_bad_access == 0, "no unaligned or out-of-window access");

    if (g_fails == 0) {
        printf("DRIVER TEST PASS: rtlnet_vdma_s2mm checks=%d\n", g_checks);
        return 0;
    }
    printf("DRIVER TEST FAIL: rtlnet_vdma_s2mm fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
