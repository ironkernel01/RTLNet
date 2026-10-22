/*
 * host_test_rtlnet_icmp.c -- host unit test of the ICMP leaf driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_icmp.c on the PC against a mocked 4 KiB register window
 * (rtlnet_mmio.h host hooks, RTLNET_HOST_TEST) with an ordered write log.
 * Prints one line "HOST TEST PASS|FAIL: host_test_rtlnet_icmp checks=<n>" and
 * exits 0 on pass.
 *
 * Build and run (repository root):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_icmp/driver cores/rtlnet_icmp/driver/rtlnet_icmp.c
 *       cores/rtlnet_icmp/testbench/host_test_rtlnet_icmp.c -o .sim/host_test_icmp.exe
 */
#include "rtlnet_icmp.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */
#include <string.h>   /* memset */

#define TEST_BASE        ((uintptr_t)0x44A12000u)
#define TEST_WORDS       0x400u           /* 4 KiB window, 32-bit words */
#define TEST_LOG_MAX     16u

static uint32_t g_regs[TEST_WORDS];
static uint32_t g_log_off[TEST_LOG_MAX];
static uint32_t g_log_val[TEST_LOG_MAX];
static unsigned g_log_n;
static unsigned g_checks;
static unsigned g_fails;
static int      g_bad_access;

static uint32_t offset_of(uintptr_t addr)
{
    uintptr_t off = addr - TEST_BASE;

    if (addr < TEST_BASE || off >= (uintptr_t)(TEST_WORDS * 4u) || (off & 3u) != 0u) {
        g_bad_access = 1;
        return 0u;
    }
    return (uint32_t)off;
}

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    return g_regs[offset_of(addr) / 4u];
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = offset_of(addr);

    if (g_log_n < TEST_LOG_MAX) {
        g_log_off[g_log_n] = off;
        g_log_val[g_log_n] = value;
        g_log_n++;
    }
    g_regs[off / 4u] = value;
}

static void check(int cond, const char *what)
{
    g_checks++;
    if (!cond) {
        g_fails++;
        printf("CHECK FAILED: %s\n", what);
    }
}

int main(void)
{
    rtlnet_icmp_counters_t c;

    memset(g_regs, 0, sizeof(g_regs));
    check(rtlnet_icmp_probe(TEST_BASE) == RTLNET_ICMP_ERROR, "probe fails on an absent leaf (reads 0)");
    g_regs[RTLNET_ICMP_REG_ID / 4u] = RTLNET_ICMP_ID_VALUE;
    g_regs[RTLNET_ICMP_REG_VERSION / 4u] = RTLNET_ICMP_VERSION_VALUE;
    check(rtlnet_icmp_probe(TEST_BASE) == RTLNET_ICMP_OK, "probe passes on ID and VERSION");

    g_regs[RTLNET_ICMP_REG_CAPS / 4u] = 0x000205C0u;   /* 2 KB, 1472 bytes */
    check(rtlnet_icmp_get_max_payload(TEST_BASE) == 1472u, "max payload from CAPS");
    check(rtlnet_icmp_get_buf_kb(TEST_BASE) == 2u, "buffer KB from CAPS");
    g_regs[RTLNET_ICMP_REG_STATUS / 4u] = RTLNET_ICMP_STATUS_ENABLED;
    check(rtlnet_icmp_get_status(TEST_BASE) == 1u, "get_status");

    g_regs[RTLNET_ICMP_REG_ECHO_REQUESTS / 4u] = 10u;
    g_regs[RTLNET_ICMP_REG_ECHO_REPLIES / 4u] = 7u;
    g_regs[RTLNET_ICMP_REG_DROPPED_CHECKSUM / 4u] = 2u;
    g_regs[RTLNET_ICMP_REG_DROPPED_SIZE / 4u] = 1u;
    rtlnet_icmp_read_counters(TEST_BASE, &c);
    check(c.echo_requests == 10u && c.echo_replies == 7u && c.dropped_checksum == 2u && c.dropped_size == 1u,
          "read_counters reads the four offsets");

    g_log_n = 0u;
    rtlnet_icmp_clear_counters(TEST_BASE);
    check(g_log_n == 1u && g_log_off[0] == RTLNET_ICMP_REG_CTRL && g_log_val[0] == RTLNET_ICMP_CTRL_CNT_CLEAR,
          "clear_counters writes CTRL.CNT_CLEAR");
    check(!g_bad_access, "every access inside the window, 32-bit aligned");

    if (g_fails == 0u) {
        printf("HOST TEST PASS: host_test_rtlnet_icmp checks=%u\n", g_checks);
        return 0;
    }
    printf("HOST TEST FAIL: host_test_rtlnet_icmp fails=%u checks=%u\n", g_fails, g_checks);
    return 1;
}
