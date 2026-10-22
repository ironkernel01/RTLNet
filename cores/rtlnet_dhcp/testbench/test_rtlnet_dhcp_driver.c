/*
 * test_rtlnet_dhcp_driver.c -- host unit test of rtlnet_dhcp.c
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs the DHCP driver on the PC against a register model of the leaf
 * (RTLNET_HOST_TEST hooks of rtlnet_mmio.h). The model mirrors the register
 * file of cores/rtlnet_dhcp/hdl/rtlnet_dhcp.sv: CTRL pulse bits read 0 and
 * act once per write, AUTO is a level written by every CTRL write, the other
 * registers read back what the test preset. Every write is logged so the test
 * checks the exact values the driver sends.
 *
 * Build and run (host gcc):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_dhcp/driver cores/rtlnet_dhcp/driver/rtlnet_dhcp.c
 *       cores/rtlnet_dhcp/testbench/test_rtlnet_dhcp_driver.c -o test_rtlnet_dhcp_driver
 * Prints "TEST PASS: test_rtlnet_dhcp_driver checks=<n>" and exits 0, or
 * "TEST FAIL: ..." and exits 1.
 */
#include "rtlnet_dhcp.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */
#include <string.h>   /* memset, strcmp */

#define TEST_BASE        0x44A13000u   /* protocol window + 0x3000 */
#define TEST_REGS        0x400u        /* model words: the 4 KiB window */
#define TEST_LOG_MAX     64u

static uint32_t g_regs[TEST_REGS];
static uint32_t g_log_off[TEST_LOG_MAX];
static uint32_t g_log_val[TEST_LOG_MAX];
static unsigned g_log_n;
static uint32_t g_pulses_start;
static uint32_t g_pulses_stop;
static uint32_t g_pulses_renew;
static uint32_t g_pulses_clear;
static int g_checks;
static int g_fails;

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

    check(off < 4u * TEST_REGS && (off & 3u) == 0u, "read inside the window, word aligned");
    if (off == RTLNET_DHCP_REG_CTRL) {
        return g_regs[off / 4u] & RTLNET_DHCP_CTRL_AUTO;   /* pulse bits read 0 */
    }
    return g_regs[off / 4u];
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);

    check(off < 4u * TEST_REGS && (off & 3u) == 0u, "write inside the window, word aligned");
    if (g_log_n < TEST_LOG_MAX) {
        g_log_off[g_log_n] = off;
        g_log_val[g_log_n] = value;
        g_log_n++;
    }
    if (off == RTLNET_DHCP_REG_CTRL) {
        g_regs[off / 4u] = value & RTLNET_DHCP_CTRL_AUTO;
        g_pulses_start += (value & RTLNET_DHCP_CTRL_START) ? 1u : 0u;
        g_pulses_stop += (value & RTLNET_DHCP_CTRL_STOP) ? 1u : 0u;
        g_pulses_renew += (value & RTLNET_DHCP_CTRL_RENEW_NOW) ? 1u : 0u;
        g_pulses_clear += (value & RTLNET_DHCP_CTRL_CNT_CLEAR) ? 1u : 0u;
    }
}

static void model_reset(void)
{
    memset(g_regs, 0, sizeof(g_regs));
    g_log_n = 0u;
    g_pulses_start = 0u;
    g_pulses_stop = 0u;
    g_pulses_renew = 0u;
    g_pulses_clear = 0u;
    g_regs[RTLNET_DHCP_REG_ID / 4u] = RTLNET_DHCP_ID_VALUE;
    g_regs[RTLNET_DHCP_REG_VERSION / 4u] = RTLNET_DHCP_VERSION_VALUE;
}

int main(void)
{
    rtlnet_dhcp_lease_t lease;
    rtlnet_dhcp_counters_t cnt;

    model_reset();
    check(rtlnet_dhcp_probe(TEST_BASE) == RTLNET_DHCP_OK, "probe matches ID and VERSION");
    g_regs[RTLNET_DHCP_REG_VERSION / 4u] = 0x01012026u;
    check(rtlnet_dhcp_probe(TEST_BASE) == RTLNET_DHCP_ERR_ID, "probe rejects another VERSION");
    g_regs[RTLNET_DHCP_REG_VERSION / 4u] = RTLNET_DHCP_VERSION_VALUE;
    g_regs[RTLNET_DHCP_REG_ID / 4u] = 0x49505246u;
    check(rtlnet_dhcp_probe(TEST_BASE) == RTLNET_DHCP_ERR_ID, "probe rejects another ID");

    /* Commands without AUTO: exactly the pulse bit. */
    model_reset();
    rtlnet_dhcp_start(TEST_BASE);
    check(g_log_n == 1u && g_log_off[0] == RTLNET_DHCP_REG_CTRL && g_log_val[0] == RTLNET_DHCP_CTRL_START,
          "start writes CTRL = START");
    rtlnet_dhcp_stop(TEST_BASE);
    check(g_log_val[1] == RTLNET_DHCP_CTRL_STOP, "stop writes CTRL = STOP");
    rtlnet_dhcp_renew_now(TEST_BASE);
    check(g_log_val[2] == RTLNET_DHCP_CTRL_RENEW_NOW, "renew writes CTRL = RENEW_NOW");
    rtlnet_dhcp_clear_counters(TEST_BASE);
    check(g_log_val[3] == RTLNET_DHCP_CTRL_CNT_CLEAR, "clear writes CTRL = CNT_CLEAR");
    check(g_pulses_start == 1u && g_pulses_stop == 1u && g_pulses_renew == 1u && g_pulses_clear == 1u,
          "one pulse of each command");

    /* AUTO survives every command. */
    model_reset();
    rtlnet_dhcp_set_auto(TEST_BASE, 1);
    check(rtlnet_dhcp_get_auto(TEST_BASE) == 1, "AUTO set");
    rtlnet_dhcp_start(TEST_BASE);
    check(g_log_val[1] == (RTLNET_DHCP_CTRL_AUTO | RTLNET_DHCP_CTRL_START), "start keeps AUTO");
    rtlnet_dhcp_stop(TEST_BASE);
    check(g_log_val[2] == (RTLNET_DHCP_CTRL_AUTO | RTLNET_DHCP_CTRL_STOP), "stop keeps AUTO");
    rtlnet_dhcp_clear_counters(TEST_BASE);
    check(rtlnet_dhcp_get_auto(TEST_BASE) == 1, "AUTO still set after the commands");
    rtlnet_dhcp_set_auto(TEST_BASE, 0);
    check(rtlnet_dhcp_get_auto(TEST_BASE) == 0 && g_pulses_start == 1u, "AUTO cleared, no extra pulse");

    /* Lease snapshot. */
    model_reset();
    g_regs[RTLNET_DHCP_REG_STATUS / 4u] = RTLNET_DHCP_STATE_RENEWING | RTLNET_DHCP_STATUS_BOUND |
                                          RTLNET_DHCP_STATUS_ENABLE;
    g_regs[RTLNET_DHCP_REG_LEASE_IP / 4u] = 0x0A140039u;
    g_regs[RTLNET_DHCP_REG_LEASE_MASK / 4u] = 0xFFFFFF00u;
    g_regs[RTLNET_DHCP_REG_LEASE_ROUTER / 4u] = 0x0A1400FEu;
    g_regs[RTLNET_DHCP_REG_LEASE_SERVER / 4u] = 0x0A140001u;
    g_regs[RTLNET_DHCP_REG_LEASE_TIME_S / 4u] = 86400u;
    g_regs[RTLNET_DHCP_REG_LEASE_ELAPSED_S / 4u] = 43201u;
    g_regs[RTLNET_DHCP_REG_XID / 4u] = 0x12345678u;
    check(rtlnet_dhcp_read_lease(TEST_BASE, &lease) == RTLNET_DHCP_OK, "read_lease OK");
    check(lease.state == RTLNET_DHCP_STATE_RENEWING && lease.bound == 1 && lease.fail == 0 && lease.enabled == 1 &&
          lease.auto_start == 0, "lease state fields");
    check(lease.lease_ip == 0x0A140039u && lease.lease_mask == 0xFFFFFF00u && lease.lease_router == 0x0A1400FEu &&
          lease.lease_server == 0x0A140001u && lease.lease_time_s == 86400u && lease.lease_elapsed_s == 43201u &&
          lease.xid == 0x12345678u, "lease values");
    check(rtlnet_dhcp_state(TEST_BASE) == RTLNET_DHCP_STATE_RENEWING, "state()");
    check(g_log_n == 0u, "reads write nothing");
    g_regs[RTLNET_DHCP_REG_STATUS / 4u] = RTLNET_DHCP_STATE_FAIL | RTLNET_DHCP_STATUS_FAIL;
    check(rtlnet_dhcp_read_lease(TEST_BASE, &lease) == RTLNET_DHCP_OK && lease.fail == 1 && lease.bound == 0 &&
          lease.enabled == 0, "fail flag");

    /* Counters. */
    g_regs[RTLNET_DHCP_REG_DISCOVERS_SENT / 4u] = 11u;
    g_regs[RTLNET_DHCP_REG_OFFERS_RX / 4u] = 12u;
    g_regs[RTLNET_DHCP_REG_REQUESTS_SENT / 4u] = 13u;
    g_regs[RTLNET_DHCP_REG_ACKS_RX / 4u] = 14u;
    g_regs[RTLNET_DHCP_REG_NAKS_RX / 4u] = 15u;
    g_regs[RTLNET_DHCP_REG_LEASES_LOST / 4u] = 16u;
    g_regs[RTLNET_DHCP_REG_RELEASES_SENT / 4u] = 17u;
    check(rtlnet_dhcp_read_counters(TEST_BASE, &cnt) == RTLNET_DHCP_OK, "read_counters OK");
    check(cnt.discovers_sent == 11u && cnt.offers_rx == 12u && cnt.requests_sent == 13u && cnt.acks_rx == 14u &&
          cnt.naks_rx == 15u && cnt.leases_lost == 16u && cnt.releases_sent == 17u, "counter values");

    /* Arguments and names. */
    check(rtlnet_dhcp_read_lease(TEST_BASE, NULL) == RTLNET_DHCP_ERR_ARG, "null lease pointer");
    check(rtlnet_dhcp_read_counters(TEST_BASE, NULL) == RTLNET_DHCP_ERR_ARG, "null counter pointer");
    check(strcmp(rtlnet_dhcp_state_name(RTLNET_DHCP_STATE_INIT), "INIT") == 0 &&
          strcmp(rtlnet_dhcp_state_name(RTLNET_DHCP_STATE_BOUND), "BOUND") == 0 &&
          strcmp(rtlnet_dhcp_state_name(RTLNET_DHCP_STATE_FAIL), "FAIL") == 0 &&
          strcmp(rtlnet_dhcp_state_name(6u), "?") == 0, "state names");

    if (g_fails == 0) {
        printf("TEST PASS: test_rtlnet_dhcp_driver checks=%d\n", g_checks);
        return 0;
    }
    printf("TEST FAIL: test_rtlnet_dhcp_driver fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
