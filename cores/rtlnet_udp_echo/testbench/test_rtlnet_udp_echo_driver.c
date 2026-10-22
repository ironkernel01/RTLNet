/*
 * test_rtlnet_udp_echo_driver.c -- host unit test of the UDP echo driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs driver/rtlnet_udp_echo.c on the PC against a register model of
 * rtlnet_udp_echo (CTRL field masks, self-clearing CNT_CLEAR, read-only
 * counters) through the RTLNET_HOST_TEST hooks of rtlnet_mmio.h. Prints one
 * line "DRIVER TEST PASS: <n> checks" or "DRIVER TEST FAIL: ..." and returns
 * 0 / 1.
 *
 * Build and run (repository root):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_udp_echo/driver cores/rtlnet_udp_echo/driver/rtlnet_udp_echo.c
 *       cores/rtlnet_udp_echo/testbench/test_rtlnet_udp_echo_driver.c -o test_echo && ./test_echo
 */
#include "rtlnet_udp_echo.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */

#define TEST_BASE   0x44A03000u
#define TEST_WORDS  1024u

static uint32_t g_regs[TEST_WORDS];
static uint32_t g_id = RTLNET_ECHO_ID_VALUE;
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
    if (addr < TEST_BASE || off >= TEST_WORDS * 4u || (off & 3u) != 0u) {
        g_bad_access = 1;
        return 0u;
    }
    if (off == RTLNET_REG_ID) {
        return g_id;
    }
    if (off == RTLNET_REG_VERSION) {
        return RTLNET_ECHO_VERSION_VALUE;
    }
    if (off == RTLNET_REG_CAPS) {
        return 1472u;
    }
    return g_regs[off / 4u];
}

/* Model write: only CTRL is writable; CNT_CLEAR clears the counters. */
void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    if (addr < TEST_BASE || off >= TEST_WORDS * 4u || (off & 3u) != 0u) {
        g_bad_access = 1;
        return;
    }
    if (off == RTLNET_ECHO_REG_CTRL) {
        g_regs[off / 4u] = value & RTLNET_ECHO_CTRL_CONFIG_MASK;
        if ((value & RTLNET_ECHO_CTRL_CNT_CLEAR) != 0u) {
            g_regs[RTLNET_ECHO_REG_ECHOED_DATAGRAMS / 4u] = 0u;
            g_regs[RTLNET_ECHO_REG_ECHOED_BYTES / 4u]     = 0u;
            g_regs[RTLNET_ECHO_REG_DISCARDED / 4u]        = 0u;
        }
    }
}

static uint32_t ctrl(void)
{
    return g_regs[RTLNET_ECHO_REG_CTRL / 4u];
}

int main(void)
{
    rtlnet_udp_echo_config_t   cfg;
    rtlnet_udp_echo_counters_t c;
    const uintptr_t            b = TEST_BASE;

    check(rtlnet_udp_echo_probe(b) == 0, "probe succeeds");
    g_id = 0x12345678u;
    check(rtlnet_udp_echo_probe(b) == -1, "probe fails on a wrong ID");
    g_id = RTLNET_ECHO_ID_VALUE;

    check(rtlnet_udp_echo_select_socket(b, 2u) == 0, "select socket 2");
    check(ctrl() == (2u << 8), "SOCKET field written, disabled");
    rtlnet_udp_echo_enable(b, 1);
    check(ctrl() == ((2u << 8) | RTLNET_ECHO_CTRL_ENABLE), "enable keeps the socket");
    rtlnet_udp_echo_select_any(b);
    check(ctrl() == ((2u << 8) | RTLNET_ECHO_CTRL_ENABLE | RTLNET_ECHO_CTRL_SOCKET_ANY), "SOCKET_ANY set");
    check(rtlnet_udp_echo_get_config(b, &cfg) == 0 && cfg.enabled && cfg.socket_any && cfg.socket == 2u,
          "get_config");
    check(rtlnet_udp_echo_select_socket(b, 255u) == 0, "select socket 255");
    check(ctrl() == ((255u << 8) | RTLNET_ECHO_CTRL_ENABLE), "select clears SOCKET_ANY, keeps ENABLE");
    check(rtlnet_udp_echo_select_socket(b, 256u) == -1, "socket 256 rejected");
    check(ctrl() == ((255u << 8) | RTLNET_ECHO_CTRL_ENABLE), "rejected select writes nothing");
    check(rtlnet_udp_echo_get_config(b, NULL) == -1, "get_config rejects NULL");

    g_regs[RTLNET_ECHO_REG_ECHOED_DATAGRAMS / 4u] = 5u;
    g_regs[RTLNET_ECHO_REG_ECHOED_BYTES / 4u]     = 500u;
    g_regs[RTLNET_ECHO_REG_DISCARDED / 4u]        = 7u;
    check(rtlnet_udp_echo_read_counters(b, &c) == 0 && c.echoed_datagrams == 5u && c.echoed_bytes == 500u &&
          c.discarded == 7u, "counters mapped");
    check(rtlnet_udp_echo_read_counters(b, NULL) == -1, "counters reject NULL");
    rtlnet_udp_echo_clear_counters(b);
    check(ctrl() == ((255u << 8) | RTLNET_ECHO_CTRL_ENABLE), "clear keeps the configuration");
    check(rtlnet_udp_echo_read_counters(b, &c) == 0 && c.echoed_datagrams == 0u && c.echoed_bytes == 0u &&
          c.discarded == 0u, "counters cleared");
    rtlnet_udp_echo_enable(b, 0);
    check(ctrl() == (255u << 8), "disable keeps the socket");

    check(!g_bad_access, "no access outside the window or misaligned");
    if (g_fails == 0) {
        printf("DRIVER TEST PASS: rtlnet_udp_echo checks=%d\n", g_checks);
        return 0;
    }
    printf("DRIVER TEST FAIL: rtlnet_udp_echo fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
