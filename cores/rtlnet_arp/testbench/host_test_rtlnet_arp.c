/*
 * host_test_rtlnet_arp.c -- host unit test of the ARP leaf driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_arp.c on the PC against a mocked 4 KiB register window
 * (rtlnet_mmio.h host hooks, RTLNET_HOST_TEST) with an ordered write log.
 * Prints one line "HOST TEST PASS|FAIL: host_test_rtlnet_arp checks=<n>" and
 * exits 0 on pass.
 *
 * Build and run (repository root):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_arp/driver cores/rtlnet_arp/driver/rtlnet_arp.c
 *       cores/rtlnet_arp/testbench/host_test_rtlnet_arp.c -o .sim/host_test_arp.exe
 */
#include "rtlnet_arp.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */
#include <string.h>   /* memset */

#define TEST_BASE        ((uintptr_t)0x44A11000u)
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
    rtlnet_arp_counters_t c;

    memset(g_regs, 0, sizeof(g_regs));
    check(rtlnet_arp_probe(TEST_BASE) == RTLNET_ARP_ERROR, "probe fails on an absent leaf (reads 0)");
    g_regs[RTLNET_ARP_REG_ID / 4u] = RTLNET_ARP_ID_VALUE;
    g_regs[RTLNET_ARP_REG_VERSION / 4u] = RTLNET_ARP_VERSION_VALUE;
    check(rtlnet_arp_probe(TEST_BASE) == RTLNET_ARP_OK, "probe passes on ID and VERSION");

    g_regs[RTLNET_ARP_REG_CAPS / 4u] = 1250u;
    check(rtlnet_arp_get_reply_delay_cycles(TEST_BASE) == 1250u, "reply delay from CAPS");
    g_regs[RTLNET_ARP_REG_STATUS / 4u] = RTLNET_ARP_STATUS_ENABLED | RTLNET_ARP_STATUS_BUSY;
    check(rtlnet_arp_get_status(TEST_BASE) == 3u, "get_status");

    g_regs[RTLNET_ARP_REG_REQUESTS_FOR_US / 4u] = 7u;
    g_regs[RTLNET_ARP_REG_REPLIES_SENT / 4u] = 6u;
    g_regs[RTLNET_ARP_REG_IGNORED / 4u] = 5u;
    rtlnet_arp_read_counters(TEST_BASE, &c);
    check(c.requests_for_us == 7u && c.replies_sent == 6u && c.ignored == 5u, "read_counters reads the three offsets");

    g_log_n = 0u;
    rtlnet_arp_clear_counters(TEST_BASE);
    check(g_log_n == 1u && g_log_off[0] == RTLNET_ARP_REG_CTRL && g_log_val[0] == RTLNET_ARP_CTRL_CNT_CLEAR,
          "clear_counters writes CTRL.CNT_CLEAR");
    check(!g_bad_access, "every access inside the window, 32-bit aligned");

    if (g_fails == 0u) {
        printf("HOST TEST PASS: host_test_rtlnet_arp checks=%u\n", g_checks);
        return 0;
    }
    printf("HOST TEST FAIL: host_test_rtlnet_arp fails=%u checks=%u\n", g_fails, g_checks);
    return 1;
}
