/*
 * test_rtlnet_axi_arbiter_driver.c -- host unit test of the AXI4 arbiter driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs driver/rtlnet_axi_arbiter.c on the PC against a register model of
 * rtlnet_axi_arbiter (read-only header and counters, self-clearing CNT_CLEAR,
 * write-1-to-clear STATUS.ERR, undefined offsets reading 0) through the
 * RTLNET_HOST_TEST hooks of rtlnet_mmio.h. Prints one line
 * "DRIVER TEST PASS: rtlnet_axi_arbiter checks=<n>" or "DRIVER TEST FAIL: ..." and
 * returns 0 / 1.
 *
 * Build and run (repository root; gcc from Resolve-RtlnetHostCc in scripts/rtlnet_tools.ps1):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_axi_arbiter/driver cores/rtlnet_axi_arbiter/driver/rtlnet_axi_arbiter.c
 *       cores/rtlnet_axi_arbiter/testbench/test_rtlnet_axi_arbiter_driver.c -o test_arb && ./test_arb
 */
#include "rtlnet_axi_arbiter.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */

#define TEST_BASE      0x44A04000u
#define TEST_WINDOW    0x1000u
#define MODEL_MASTERS  3u
#define MODEL_CAPS     0x01084103u   /* 3 masters, 16 bytes/beat, ID_W 4, 8 outstanding, mask 0x01 */
#define MODEL_NARROW   0x02u         /* NARROW_MASK: master 1 may issue narrow transfers */
#define COUNTERS       6u

static uint32_t g_id = RTLNET_ARB_ID_VALUE;
static uint32_t g_version = RTLNET_ARB_VERSION_VALUE;
static uint32_t g_caps = MODEL_CAPS;
static uint32_t g_status_err;
static uint32_t g_status_busy;
static uint32_t g_counter[MODEL_MASTERS][COUNTERS];
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

/* Model read: header, STATUS, per-master counters; anything else reads 0. */
uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    uint32_t master;
    uint32_t idx;

    if (addr < TEST_BASE || off >= TEST_WINDOW || (off & 3u) != 0u) {
        g_bad_access = 1;
        return 0u;
    }
    if (off == RTLNET_REG_ID) {
        return g_id;
    }
    if (off == RTLNET_REG_VERSION) {
        return g_version;
    }
    if (off == RTLNET_REG_CAPS) {
        return g_caps;
    }
    if (off == RTLNET_ARB_REG_STATUS) {
        return g_status_err | g_status_busy;
    }
    if (off == RTLNET_ARB_REG_NARROW) {
        return MODEL_NARROW;
    }
    if (off >= RTLNET_ARB_MASTER_BASE && off < RTLNET_ARB_MASTER_BASE + (RTLNET_ARB_MAX_MASTERS * RTLNET_ARB_MASTER_STRIDE)) {
        master = (off - RTLNET_ARB_MASTER_BASE) / RTLNET_ARB_MASTER_STRIDE;
        idx = ((off - RTLNET_ARB_MASTER_BASE) % RTLNET_ARB_MASTER_STRIDE) / 4u;
        if (master < MODEL_MASTERS && idx < COUNTERS) {
            return g_counter[master][idx];
        }
    }
    return 0u;
}

/* Model write: CTRL.CNT_CLEAR clears every counter; a 1 written to STATUS.ERR clears it; nothing else is writable. */
void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);

    if (addr < TEST_BASE || off >= TEST_WINDOW || (off & 3u) != 0u) {
        g_bad_access = 1;
        return;
    }
    if (off == RTLNET_ARB_REG_CTRL && (value & RTLNET_ARB_CTRL_CNT_CLEAR) != 0u) {
        for (uint32_t m = 0u; m < MODEL_MASTERS; m++) {
            for (uint32_t i = 0u; i < COUNTERS; i++) {
                g_counter[m][i] = 0u;
            }
        }
    }
    if (off == RTLNET_ARB_REG_STATUS && (value & RTLNET_ARB_STATUS_ERR) != 0u) {
        g_status_err = 0u;
    }
}

int main(void)
{
    rtlnet_axi_arbiter_caps_t     caps;
    rtlnet_axi_arbiter_counters_t c;
    rtlnet_axi_arbiter_status_t   st;
    const uintptr_t               b = TEST_BASE;

    check(rtlnet_axi_arbiter_probe(b, &caps) == 0, "probe succeeds");
    check(caps.num_masters == 3u && caps.bytes_per_beat == 16u && caps.id_w == 4u && caps.max_outstanding == 8u &&
          caps.high_prio_mask == 1u && caps.narrow_mask == MODEL_NARROW, "CAPS and NARROW decoded");
    check(rtlnet_axi_arbiter_probe(b, NULL) == 0, "probe accepts a NULL caps");
    g_id = 0x12345678u;
    check(rtlnet_axi_arbiter_probe(b, &caps) == -1, "probe fails on a wrong ID");
    g_id = RTLNET_ARB_ID_VALUE;
    g_version = 0x01012026u;
    check(rtlnet_axi_arbiter_probe(b, &caps) == -1, "probe fails on a wrong VERSION");
    g_version = RTLNET_ARB_VERSION_VALUE;

    for (uint32_t m = 0u; m < MODEL_MASTERS; m++) {
        for (uint32_t i = 0u; i < COUNTERS; i++) {
            g_counter[m][i] = (m + 1u) * 1000u + i;
        }
    }
    check(rtlnet_axi_arbiter_read_counters(b, 0u, &c) == 0 && c.aw_bursts == 1000u && c.ar_bursts == 1001u &&
          c.w_beats == 1002u && c.r_beats == 1003u && c.errors == 1004u && c.wait_cycles == 1005u, "master 0 counters mapped");
    check(rtlnet_axi_arbiter_read_counters(b, 2u, &c) == 0 && c.aw_bursts == 3000u && c.wait_cycles == 3005u,
          "master 2 counters mapped");
    check(rtlnet_axi_arbiter_read_counters(b, 3u, &c) == -1, "master 3 rejected (NUM_MASTERS is 3)");
    check(rtlnet_axi_arbiter_read_counters(b, 0u, NULL) == -1, "counters reject NULL");

    rtlnet_axi_arbiter_clear(b);
    check(rtlnet_axi_arbiter_read_counters(b, 1u, &c) == 0 && c.aw_bursts == 0u && c.ar_bursts == 0u && c.w_beats == 0u &&
          c.r_beats == 0u && c.errors == 0u && c.wait_cycles == 0u, "counters cleared");

    check(rtlnet_axi_arbiter_err_status(b, &st) == 0 && st.err == 0 && st.wr_busy == 0 && st.rd_busy == 0, "status idle");
    g_status_err  = RTLNET_ARB_STATUS_ERR;
    g_status_busy = RTLNET_ARB_STATUS_WR_BUSY | RTLNET_ARB_STATUS_RD_BUSY;
    check(rtlnet_axi_arbiter_err_status(b, &st) == 0 && st.err == 1 && st.wr_busy == 1 && st.rd_busy == 1, "status flags decoded");
    check(rtlnet_axi_arbiter_err_status(b, NULL) == -1, "status rejects NULL");
    rtlnet_axi_arbiter_err_clear(b);
    check(rtlnet_axi_arbiter_err_status(b, &st) == 0 && st.err == 0 && st.wr_busy == 1 && st.rd_busy == 1,
          "err_clear clears only ERR");

    check(!g_bad_access, "no access outside the window or misaligned");
    if (g_fails == 0) {
        printf("DRIVER TEST PASS: rtlnet_axi_arbiter checks=%d\n", g_checks);
        return 0;
    }
    printf("DRIVER TEST FAIL: rtlnet_axi_arbiter fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
