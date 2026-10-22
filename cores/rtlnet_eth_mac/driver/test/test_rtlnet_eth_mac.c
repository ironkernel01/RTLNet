/*
 * test_rtlnet_eth_mac.c -- host unit test of the rtlnet_eth_mac driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_eth_mac.c on the PC (host gcc, RTLNET_HOST_TEST) against
 * a register model of the core that mirrors cores/rtlnet_eth_mac/hdl/
 * rtlnet_eth_mac_regs.sv: read-only header and status registers, CTRL with
 * the self-clearing CNT_CLEAR pulse that zeroes the counters, writes to
 * read-only offsets ignored. The model logs every access so the test can
 * check what the driver wrote and how many times it polled.
 *
 * Output: one anchored line, "TEST PASS: test_rtlnet_eth_mac checks=<n>" or
 * "TEST FAIL: test_rtlnet_eth_mac fails=<n> checks=<n>"; exit code 0 / 1.
 */
#include "rtlnet_eth_mac.h"

#include <stdio.h>    /* printf */
#include <stdint.h>   /* uint32_t, uintptr_t */

#define TEST_BASE            0x44A01000u   /* any base: the driver adds offsets */
#define TEST_CAPS_VALUE      ((1518u << 16) | (8u << 8) | 8u)
#define TEST_TAP_VALUE       12u
#define TEST_POLLS_NEVER     0xFFFFFFFFu

/* ---- Register model ----------------------------------------------------- */
static uint32_t g_id = RTLNET_ETH_MAC_ID_VALUE;
static uint32_t g_ctrl;
static uint32_t g_status_fixed;          /* STATUS bits other than RX_CLK_OK/RX_IN_RESET */
static uint32_t g_ready_after;           /* STATUS reports ready from this read on */
static uint32_t g_status_reads;
static uint32_t g_rate;
static uint32_t g_rx_good;
static uint32_t g_rx_bad;
static uint32_t g_rx_overflow;
static uint32_t g_tx_frames;
static uint32_t g_writes;
static uint32_t g_ro_writes;
static uint32_t g_last_ctrl_write;
static uint32_t g_clear_pulses;

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

static void model_reset(void)
{
    g_id = RTLNET_ETH_MAC_ID_VALUE;
    g_ctrl = 0u;
    g_status_fixed = RTLNET_ETH_MAC_STATUS_IDELAY_RDY;
    g_ready_after = TEST_POLLS_NEVER;
    g_status_reads = 0u;
    g_rate = 0u;
    g_rx_good = 5u;
    g_rx_bad = 6u;
    g_rx_overflow = 7u;
    g_tx_frames = 8u;
    g_writes = 0u;
    g_ro_writes = 0u;
    g_last_ctrl_write = 0u;
    g_clear_pulses = 0u;
}

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    uint32_t st;

    switch (off) {
    case RTLNET_ETH_MAC_REG_ID:
        return g_id;
    case RTLNET_ETH_MAC_REG_VERSION:
        return RTLNET_ETH_MAC_VERSION_VALUE;
    case RTLNET_ETH_MAC_REG_CAPS:
        return TEST_CAPS_VALUE;
    case RTLNET_ETH_MAC_REG_CTRL:
        return g_ctrl;
    case RTLNET_ETH_MAC_REG_STATUS:
        st = g_status_fixed;
        if (g_ready_after != TEST_POLLS_NEVER && g_status_reads >= g_ready_after) {
            st |= RTLNET_ETH_MAC_STATUS_RX_CLK_OK;
        } else {
            st |= RTLNET_ETH_MAC_STATUS_RX_IN_RESET;
        }
        g_status_reads++;
        return st;
    case RTLNET_ETH_MAC_REG_RX_CLK_RATE:
        return g_rate;
    case RTLNET_ETH_MAC_REG_RX_IDELAY_TAP:
        return TEST_TAP_VALUE;
    case RTLNET_ETH_MAC_REG_RX_GOOD:
        return g_rx_good;
    case RTLNET_ETH_MAC_REG_RX_BAD:
        return g_rx_bad;
    case RTLNET_ETH_MAC_REG_RX_OVERFLOW:
        return g_rx_overflow;
    case RTLNET_ETH_MAC_REG_TX_FRAMES:
        return g_tx_frames;
    default:
        return 0u;
    }
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);

    g_writes++;
    if (off != RTLNET_ETH_MAC_REG_CTRL) {
        g_ro_writes++;
        return;
    }
    g_last_ctrl_write = value;
    g_ctrl = value & (RTLNET_ETH_MAC_CTRL_RX_EN | RTLNET_ETH_MAC_CTRL_TX_EN | RTLNET_ETH_MAC_CTRL_SPEED_MASK |
                      RTLNET_ETH_MAC_CTRL_LINK_UP);
    if ((value & RTLNET_ETH_MAC_CTRL_CNT_CLEAR) != 0u) {
        g_clear_pulses++;
        g_rx_good = 0u;
        g_rx_bad = 0u;
        g_rx_overflow = 0u;
        g_tx_frames = 0u;
    }
}

/* ---- Tests ----------------------------------------------------------------- */
static void test_probe_init(void)
{
    rtlnet_eth_mac_caps_t caps = {0u, 0u, 0u, 0u};
    int rc;

    model_reset();
    g_id = 0x12345678u;
    rc = rtlnet_eth_mac_init(TEST_BASE, &caps);
    check(rc == RTLNET_ETH_MAC_ERR_ID, "init rejects a wrong ID");
    check(g_writes == 0u, "init writes nothing after a wrong ID");

    model_reset();
    g_ctrl = RTLNET_ETH_MAC_CTRL_RX_EN | RTLNET_ETH_MAC_CTRL_TX_EN;
    rc = rtlnet_eth_mac_init(TEST_BASE, &caps);
    check(rc == RTLNET_ETH_MAC_OK, "init accepts MAC1 / 0x10222026");
    check(caps.rx_fifo_kb == 8u && caps.tx_fifo_kb == 8u, "CAPS FIFO sizes decoded");
    check(caps.max_frame_bytes == 1518u, "CAPS MAX_FRAME_BYTES decoded");
    check(caps.rx_idelay_tap == TEST_TAP_VALUE, "RX_IDELAY_TAP read");
    check(g_ctrl == 0u, "init leaves CTRL = 0 (disabled)");
    check(g_clear_pulses == 1u && g_rx_good == 0u && g_tx_frames == 0u, "init clears the counters");
    check(g_ro_writes == 0u, "init writes only CTRL");
    check(rtlnet_eth_mac_probe(TEST_BASE, NULL) == RTLNET_ETH_MAC_OK, "probe without caps");
}

static void test_speed_enable_link(void)
{
    model_reset();
    check(rtlnet_eth_mac_set_speed(TEST_BASE, 1000u) == RTLNET_ETH_MAC_OK, "set_speed 1000");
    check(((g_ctrl & RTLNET_ETH_MAC_CTRL_SPEED_MASK) >> RTLNET_ETH_MAC_CTRL_SPEED_SHIFT) == RTLNET_ETH_MAC_SPEED_1000,
          "CTRL.SPEED = 2 for 1000 Mb/s");
    check(rtlnet_eth_mac_get_speed(TEST_BASE) == 1000u, "get_speed 1000");
    rtlnet_eth_mac_enable(TEST_BASE, 1, 1);
    rtlnet_eth_mac_set_link(TEST_BASE, 1);
    check(g_ctrl == (RTLNET_ETH_MAC_CTRL_RX_EN | RTLNET_ETH_MAC_CTRL_TX_EN | (2u << 4) | RTLNET_ETH_MAC_CTRL_LINK_UP),
          "enable + link keep the speed");
    check(rtlnet_eth_mac_set_speed(TEST_BASE, 100u) == RTLNET_ETH_MAC_OK, "set_speed 100");
    check(g_ctrl == (RTLNET_ETH_MAC_CTRL_RX_EN | RTLNET_ETH_MAC_CTRL_TX_EN | (1u << 4) | RTLNET_ETH_MAC_CTRL_LINK_UP),
          "set_speed 100 keeps enables and link");
    check(rtlnet_eth_mac_get_speed(TEST_BASE) == 100u, "get_speed 100");
    check(rtlnet_eth_mac_set_speed(TEST_BASE, 10u) == RTLNET_ETH_MAC_OK, "set_speed 10");
    check(rtlnet_eth_mac_get_speed(TEST_BASE) == 10u, "get_speed 10");
    g_writes = 0u;
    check(rtlnet_eth_mac_set_speed(TEST_BASE, 25u) == RTLNET_ETH_MAC_ERR_ARG, "set_speed rejects 25 Mb/s");
    check(g_writes == 0u, "rejected speed writes nothing");
    rtlnet_eth_mac_enable(TEST_BASE, 0, 1);
    check((g_ctrl & 3u) == RTLNET_ETH_MAC_CTRL_TX_EN, "enable(0, 1)");
    rtlnet_eth_mac_enable(TEST_BASE, 1, 0);
    check((g_ctrl & 3u) == RTLNET_ETH_MAC_CTRL_RX_EN, "enable(1, 0)");
    rtlnet_eth_mac_set_link(TEST_BASE, 0);
    check((g_ctrl & RTLNET_ETH_MAC_CTRL_LINK_UP) == 0u, "set_link(0)");
    check((g_last_ctrl_write & RTLNET_ETH_MAC_CTRL_CNT_CLEAR) == 0u, "configuration writes never pulse CNT_CLEAR");
    check(g_ro_writes == 0u, "configuration writes touch only CTRL");
}

static void test_status(void)
{
    rtlnet_eth_mac_status_t st;

    model_reset();
    g_status_fixed = RTLNET_ETH_MAC_STATUS_IDELAY_RDY | (1u << RTLNET_ETH_MAC_STATUS_SPEED_SHIFT) |
                     RTLNET_ETH_MAC_STATUS_INBAND_LINK | (1u << RTLNET_ETH_MAC_STATUS_INBAND_SPEED_SHIFT) |
                     RTLNET_ETH_MAC_STATUS_INBAND_DUPLEX;
    g_ready_after = 0u;
    g_rate = 102u;
    rtlnet_eth_mac_read_status(TEST_BASE, &st);
    check(st.rx_clk_ok == 1 && st.rx_in_reset == 0 && st.idelay_rdy == 1, "status flags decoded");
    check(st.speed_mbps == 100u && st.rx_clk_rate == 102u, "status speed and RXC rate decoded");
    check(st.inband_link == 1 && st.inband_speed_mbps == 100u && st.inband_full_duplex == 1, "in-band status decoded");

    model_reset();
    g_ready_after = 3u;
    check(rtlnet_eth_mac_wait_rx_ready(TEST_BASE, 10u) == RTLNET_ETH_MAC_OK, "wait_rx_ready succeeds");
    check(g_status_reads == 4u, "wait_rx_ready stops polling once ready");
    model_reset();
    check(rtlnet_eth_mac_wait_rx_ready(TEST_BASE, 10u) == RTLNET_ETH_MAC_ERR_TIMEOUT, "wait_rx_ready times out");
    check(g_status_reads == 10u, "wait_rx_ready polls exactly max_polls times");
    model_reset();
    check(rtlnet_eth_mac_wait_rx_ready(TEST_BASE, 0u) == RTLNET_ETH_MAC_ERR_TIMEOUT, "default poll bound");
    check(g_status_reads == RTLNET_ETH_MAC_READY_POLL_MAX, "default bound is RTLNET_ETH_MAC_READY_POLL_MAX");
}

static void test_counters(void)
{
    rtlnet_eth_mac_counters_t c;

    model_reset();
    g_ctrl = RTLNET_ETH_MAC_CTRL_RX_EN | RTLNET_ETH_MAC_CTRL_TX_EN | (2u << 4) | RTLNET_ETH_MAC_CTRL_LINK_UP;
    rtlnet_eth_mac_read_counters(TEST_BASE, &c);
    check(c.rx_good == 5u && c.rx_bad == 6u && c.rx_overflow == 7u && c.tx_frames == 8u, "counters read");
    rtlnet_eth_mac_clear_counters(TEST_BASE);
    check(g_last_ctrl_write == (g_ctrl | RTLNET_ETH_MAC_CTRL_CNT_CLEAR), "clear writes CTRL | CNT_CLEAR");
    check(g_ctrl == (RTLNET_ETH_MAC_CTRL_RX_EN | RTLNET_ETH_MAC_CTRL_TX_EN | (2u << 4) | RTLNET_ETH_MAC_CTRL_LINK_UP),
          "clear keeps the configuration");
    rtlnet_eth_mac_read_counters(TEST_BASE, &c);
    check(c.rx_good == 0u && c.rx_bad == 0u && c.rx_overflow == 0u && c.tx_frames == 0u, "counters cleared");
}

static void test_codes(void)
{
    check(rtlnet_eth_mac_speed_code(10u) == 0u && rtlnet_eth_mac_speed_code(100u) == 1u &&
          rtlnet_eth_mac_speed_code(1000u) == 2u && rtlnet_eth_mac_speed_code(1u) == 3u, "speed_code mapping");
    check(rtlnet_eth_mac_speed_mbps(0u) == 10u && rtlnet_eth_mac_speed_mbps(1u) == 100u &&
          rtlnet_eth_mac_speed_mbps(2u) == 1000u && rtlnet_eth_mac_speed_mbps(3u) == 1000u, "speed_mbps mapping");
}

int main(void)
{
    test_probe_init();
    test_speed_enable_link();
    test_status();
    test_counters();
    test_codes();
    if (g_fails == 0 && g_checks > 0) {
        printf("TEST PASS: test_rtlnet_eth_mac checks=%d\n", g_checks);
        return 0;
    }
    printf("TEST FAIL: test_rtlnet_eth_mac fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
