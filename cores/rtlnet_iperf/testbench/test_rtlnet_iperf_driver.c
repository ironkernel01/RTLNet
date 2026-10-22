/*
 * test_rtlnet_iperf_driver.c -- host unit test of rtlnet_iperf.c
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs the iperf driver on the PC against a register model of the leaf
 * (RTLNET_HOST_TEST hooks of rtlnet_mmio.h). The model mirrors the register
 * file of cores/rtlnet_iperf/hdl/rtlnet_iperf.sv: CTRL holds REVERSE_ALLOWED
 * (reset 1) and CNT_CLEAR is a pulse that reads 0, UDP_PORT keeps 16 bits,
 * a read of RX_BYTES_LO latches the high word for RX_BYTES_HI.
 *
 * Build and run (host gcc):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_iperf/driver cores/rtlnet_iperf/driver/rtlnet_iperf.c
 *       cores/rtlnet_iperf/testbench/test_rtlnet_iperf_driver.c -o test_rtlnet_iperf_driver
 * Prints "TEST PASS: test_rtlnet_iperf_driver checks=<n>" and exits 0, or
 * "TEST FAIL: ..." and exits 1.
 */
#include "rtlnet_iperf.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */
#include <string.h>   /* memset */

#define TEST_BASE        0x44A14000u   /* protocol window + 0x4000 */
#define TEST_REGS        0x400u
#define TEST_LOG_MAX     64u

static uint32_t g_regs[TEST_REGS];
static uint64_t g_bytes;               /* the leaf's 64-bit byte counter */
static uint32_t g_bytes_hi_latch;
static uint32_t g_log_off[TEST_LOG_MAX];
static uint32_t g_log_val[TEST_LOG_MAX];
static unsigned g_log_n;
static uint32_t g_clears;
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
    if (off == RTLNET_IPERF_REG_RX_BYTES_LO) {
        g_bytes_hi_latch = (uint32_t)(g_bytes >> 32);
        return (uint32_t)g_bytes;
    }
    if (off == RTLNET_IPERF_REG_RX_BYTES_HI) {
        return g_bytes_hi_latch;
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
    if (off == RTLNET_IPERF_REG_CTRL) {
        g_regs[off / 4u] = value & RTLNET_IPERF_CTRL_REVERSE_ALLOWED;
        g_clears += (value & RTLNET_IPERF_CTRL_CNT_CLEAR) ? 1u : 0u;
    } else if (off == RTLNET_IPERF_REG_UDP_PORT) {
        g_regs[off / 4u] = value & RTLNET_IPERF_PORT_MASK;
    }
}

static void model_reset(void)
{
    memset(g_regs, 0, sizeof(g_regs));
    g_bytes = 0u;
    g_bytes_hi_latch = 0u;
    g_log_n = 0u;
    g_clears = 0u;
    g_regs[RTLNET_IPERF_REG_ID / 4u] = RTLNET_IPERF_ID_VALUE;
    g_regs[RTLNET_IPERF_REG_VERSION / 4u] = RTLNET_IPERF_VERSION_VALUE;
    g_regs[RTLNET_IPERF_REG_CAPS / 4u] = (50000u << RTLNET_IPERF_CAPS_KHZ_SHIFT) | 1472u;
    g_regs[RTLNET_IPERF_REG_CTRL / 4u] = RTLNET_IPERF_CTRL_REVERSE_ALLOWED;
    g_regs[RTLNET_IPERF_REG_UDP_PORT / 4u] = RTLNET_IPERF_DEFAULT_PORT;
}

int main(void)
{
    rtlnet_iperf_stats_t st;

    model_reset();
    check(rtlnet_iperf_probe(TEST_BASE) == RTLNET_IPERF_OK, "probe matches");
    g_regs[RTLNET_IPERF_REG_ID / 4u] = 0x44484350u;
    check(rtlnet_iperf_probe(TEST_BASE) == RTLNET_IPERF_ERR_ID, "probe rejects another ID");

    /* Port. */
    model_reset();
    check(rtlnet_iperf_get_port(TEST_BASE) == 5001u, "default port");
    check(rtlnet_iperf_set_port(TEST_BASE, 6001u) == RTLNET_IPERF_OK && rtlnet_iperf_get_port(TEST_BASE) == 6001u,
          "port 6001");
    check(rtlnet_iperf_set_port(TEST_BASE, 0u) == RTLNET_IPERF_ERR_ARG, "port 0 rejected");
    check(rtlnet_iperf_set_port(TEST_BASE, 70000u) == RTLNET_IPERF_ERR_ARG, "port above 65535 rejected");
    check(g_log_n == 1u && rtlnet_iperf_get_port(TEST_BASE) == 6001u, "rejected ports write nothing");

    /* Reverse permission and counter clear. */
    check(rtlnet_iperf_get_reverse_allowed(TEST_BASE) == 1, "reverse allowed after reset");
    rtlnet_iperf_clear_counters(TEST_BASE);
    check(g_log_val[g_log_n - 1u] == (RTLNET_IPERF_CTRL_REVERSE_ALLOWED | RTLNET_IPERF_CTRL_CNT_CLEAR),
          "clear keeps REVERSE_ALLOWED");
    rtlnet_iperf_set_reverse_allowed(TEST_BASE, 0);
    check(rtlnet_iperf_get_reverse_allowed(TEST_BASE) == 0, "reverse refused");
    rtlnet_iperf_clear_counters(TEST_BASE);
    check(g_log_val[g_log_n - 1u] == RTLNET_IPERF_CTRL_CNT_CLEAR && rtlnet_iperf_get_reverse_allowed(TEST_BASE) == 0,
          "clear keeps the refusal");
    check(g_clears == 2u, "two clear pulses");

    /* Statistics snapshot, 64-bit bytes through the latch. */
    model_reset();
    g_regs[RTLNET_IPERF_REG_STATUS / 4u] = RTLNET_IPERF_STATUS_RX_ACTIVE | RTLNET_IPERF_STATUS_ENABLE;
    g_regs[RTLNET_IPERF_REG_RX_DATAGRAMS / 4u] = 81266u;
    g_bytes = 0x0000000123456789ull;
    g_regs[RTLNET_IPERF_REG_RX_LOST / 4u] = 7u;
    g_regs[RTLNET_IPERF_REG_RX_OUTOFORDER / 4u] = 3u;
    g_regs[RTLNET_IPERF_REG_TX_DATAGRAMS / 4u] = 99u;
    g_regs[RTLNET_IPERF_REG_JITTER_US16 / 4u] = 160u;
    g_regs[RTLNET_IPERF_REG_REQ_RATE_BPS / 4u] = 10485760u;
    g_regs[RTLNET_IPERF_REG_LAST_DURATION_US / 4u] = 10000123u;
    g_regs[RTLNET_IPERF_REG_REPORTS_SENT / 4u] = 2u;
    check(rtlnet_iperf_read_stats(TEST_BASE, &st) == RTLNET_IPERF_OK, "read_stats OK");
    check(st.rx_active == 1 && st.tx_active == 0 && st.reverse_allowed == 1 && st.udp_port == 5001u, "status fields");
    check(st.max_dgram_bytes == 1472u && st.clk_khz == 50000u, "CAPS fields");
    check(st.rx_bytes == 0x0000000123456789ull, "64-bit byte count through the latch");
    check(st.rx_datagrams == 81266u && st.rx_lost == 7u && st.rx_outoforder == 3u && st.tx_datagrams == 99u &&
          st.jitter_us16 == 160u && st.req_rate_bps == 10485760u && st.last_duration_us == 10000123u &&
          st.reports_sent == 2u, "counter values");
    check(g_log_n == 0u, "reads write nothing");
    check(rtlnet_iperf_read_stats(TEST_BASE, NULL) == RTLNET_IPERF_ERR_ARG, "null pointer");

    if (g_fails == 0) {
        printf("TEST PASS: test_rtlnet_iperf_driver checks=%d\n", g_checks);
        return 0;
    }
    printf("TEST FAIL: test_rtlnet_iperf_driver fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
