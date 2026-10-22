/*
 * test_rtlnet_udp_socket_driver.c -- host unit test of the UDP socket layer driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs driver/rtlnet_udp_socket.c on the PC against a register model of
 * rtlnet_udp_socket (the access rules of hdl/rtlnet_udp_socket.sv: field
 * widths, read-only counters, self-clearing CNT_CLEAR, undefined offsets read
 * 0) through the RTLNET_HOST_TEST hooks of rtlnet_mmio.h. Prints one line
 * "DRIVER TEST PASS: <n> checks" or "DRIVER TEST FAIL: ..." and returns 0 / 1.
 *
 * Build and run (repository root):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_udp_socket/driver cores/rtlnet_udp_socket/driver/rtlnet_udp_socket.c
 *       cores/rtlnet_udp_socket/testbench/test_rtlnet_udp_socket_driver.c -o test_udps && ./test_udps
 */
#include "rtlnet_udp_socket.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */
#include <string.h>   /* memset, memcmp */

#define TEST_BASE        0x44A15000u
#define TEST_SOCKETS     4u
#define TEST_WORDS       1024u          /* 4 KiB window */
#define TEST_LOG_MAX     64u

/* Register model state. */
static uint32_t g_regs[TEST_WORDS];
static uint32_t g_caps = TEST_SOCKETS | (16u << RTLNET_UDPS_CAPS_RX_KB_SHIFT) |
                         (8u << RTLNET_UDPS_CAPS_TX_KB_SHIFT) | RTLNET_UDPS_CAPS_CSUM_CHECK;
static uint32_t g_id = RTLNET_UDPS_ID_VALUE;
static uint32_t g_log_off[TEST_LOG_MAX];
static uint32_t g_log_val[TEST_LOG_MAX];
static uint32_t g_log_n;
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

static int is_counter(uint32_t off)
{
    uint32_t f;
    if (off >= RTLNET_UDPS_REG_RX_NO_SOCKET && off <= RTLNET_UDPS_REG_RX_DATAGRAMS) {
        return 1;
    }
    if (off < RTLNET_UDPS_SOCK_BASE) {
        return 0;
    }
    f = (off - RTLNET_UDPS_SOCK_BASE) % RTLNET_UDPS_SOCK_STRIDE;
    return f >= RTLNET_UDPS_SOCK_RX_DATAGRAMS && f <= RTLNET_UDPS_SOCK_TX_DROPS;
}

/* Model write: the RTL's field masks; counters and header read-only. */
static void model_write(uint32_t off, uint32_t v)
{
    uint32_t sock;
    uint32_t f;

    if (off < RTLNET_UDPS_SOCK_BASE) {
        if (off == RTLNET_UDPS_REG_CTRL) {
            g_regs[off / 4u] = v & RTLNET_UDPS_CTRL_RX_CSUM_CHECK;
            if ((v & RTLNET_UDPS_CTRL_CNT_CLEAR) != 0u) {
                for (uint32_t o = 0u; o < TEST_WORDS * 4u; o += 4u) {
                    if (is_counter(o)) {
                        g_regs[o / 4u] = 0u;
                    }
                }
            }
        }
        return;
    }
    sock = (off - RTLNET_UDPS_SOCK_BASE) / RTLNET_UDPS_SOCK_STRIDE;
    f = (off - RTLNET_UDPS_SOCK_BASE) % RTLNET_UDPS_SOCK_STRIDE;
    if (sock >= TEST_SOCKETS) {
        return;
    }
    switch (f) {
    case RTLNET_UDPS_SOCK_CTRL:          g_regs[off / 4u] = v & 0x3u; break;
    case RTLNET_UDPS_SOCK_LOCAL_PORT:    g_regs[off / 4u] = v & 0xFFFFu; break;
    case RTLNET_UDPS_SOCK_REMOTE_IP:     g_regs[off / 4u] = v; break;
    case RTLNET_UDPS_SOCK_REMOTE_PORT:   g_regs[off / 4u] = v & 0xFFFFu; break;
    case RTLNET_UDPS_SOCK_REMOTE_MAC_HI: g_regs[off / 4u] = v & 0xFFFFu; break;
    case RTLNET_UDPS_SOCK_REMOTE_MAC_LO: g_regs[off / 4u] = v; break;
    default: break;
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
        return RTLNET_UDPS_VERSION_VALUE;
    }
    if (off == RTLNET_REG_CAPS) {
        return g_caps;
    }
    return g_regs[off / 4u];
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TEST_BASE);
    if (addr < TEST_BASE || off >= TEST_WORDS * 4u || (off & 3u) != 0u) {
        g_bad_access = 1;
        return;
    }
    if (g_log_n < TEST_LOG_MAX) {
        g_log_off[g_log_n] = off;
        g_log_val[g_log_n] = value;
        g_log_n++;
    }
    model_write(off, value);
}

static uint32_t reg(uint32_t off)
{
    return g_regs[off / 4u];
}

int main(void)
{
    rtlnet_udp_socket_caps_t          caps;
    rtlnet_udp_socket_config_t        cfg;
    rtlnet_udp_socket_remote_t        rem;
    rtlnet_udp_socket_remote_t        back;
    rtlnet_udp_socket_sock_counters_t sc;
    rtlnet_udp_socket_counters_t      gc;
    const uintptr_t                   b = TEST_BASE;

    memset(g_regs, 0, sizeof(g_regs));

    /* Probe. */
    check(rtlnet_udp_socket_probe(b, &caps) == 0, "probe succeeds");
    check(caps.num_sockets == 4u && caps.rx_buf_kb == 16u && caps.tx_buf_kb == 8u && caps.csum_check,
          "CAPS decoded");
    check(rtlnet_udp_socket_probe(b, NULL) == 0, "probe with NULL caps");
    g_id = 0u;
    check(rtlnet_udp_socket_probe(b, &caps) == -1, "probe fails on a wrong ID");
    g_id = RTLNET_UDPS_ID_VALUE;

    /* Open: disable, port, then enable with options. */
    g_log_n = 0u;
    check(rtlnet_udp_socket_open(b, 1u, 7u, RTLNET_UDPS_OPEN_CONNECT_ON_RX) == 0, "open socket 1");
    check(g_log_n == 3u, "open writes three registers");
    check(g_log_off[0] == RTLNET_UDPS_SOCK_REG(1u, RTLNET_UDPS_SOCK_CTRL) && g_log_val[0] == 0u,
          "open disables first");
    check(g_log_off[1] == RTLNET_UDPS_SOCK_REG(1u, RTLNET_UDPS_SOCK_LOCAL_PORT) && g_log_val[1] == 7u,
          "open writes LOCAL_PORT second");
    check(g_log_off[2] == RTLNET_UDPS_SOCK_REG(1u, RTLNET_UDPS_SOCK_CTRL) && g_log_val[2] == 3u,
          "open enables with CONNECT_ON_RX last");
    check(rtlnet_udp_socket_open(b, 0u, 5000u, 0u) == 0, "open socket 0");
    check(reg(RTLNET_UDPS_SOCK_REG(0u, RTLNET_UDPS_SOCK_CTRL)) == RTLNET_UDPS_SCTRL_ENABLE, "socket 0 enabled");
    check(rtlnet_udp_socket_open(b, 4u, 1u, 0u) == -1, "open rejects index 4");
    check(rtlnet_udp_socket_open(b, 2u, 1u, 0x80u) == -1, "open rejects unknown option bits");
    check(rtlnet_udp_socket_open(b, 0xFFFFFFFFu, 1u, 0u) == -1, "open rejects a huge index");

    /* Config, find, connect-on-rx. */
    check(rtlnet_udp_socket_get_config(b, 1u, &cfg) == 0 && cfg.local_port == 7u && cfg.enabled && cfg.connect_on_rx,
          "get_config socket 1");
    check(rtlnet_udp_socket_get_config(b, 1u, NULL) == -1, "get_config rejects NULL");
    check(rtlnet_udp_socket_find_port(b, 7u) == 1, "find port 7");
    check(rtlnet_udp_socket_find_port(b, 5000u) == 0, "find port 5000");
    check(rtlnet_udp_socket_find_port(b, 9u) == -1, "port 9 not bound");
    check(rtlnet_udp_socket_open(b, 3u, 7u, 0u) == 0, "socket 3 also on port 7");
    check(rtlnet_udp_socket_find_port(b, 7u) == 1, "lowest index wins");
    check(rtlnet_udp_socket_set_connect_on_rx(b, 1u, 0) == 0, "connect off");
    check(reg(RTLNET_UDPS_SOCK_REG(1u, RTLNET_UDPS_SOCK_CTRL)) == RTLNET_UDPS_SCTRL_ENABLE, "connect off keeps ENABLE");
    check(rtlnet_udp_socket_set_connect_on_rx(b, 1u, 1) == 0, "connect on");
    check(reg(RTLNET_UDPS_SOCK_REG(1u, RTLNET_UDPS_SOCK_CTRL)) == 3u, "connect on keeps ENABLE");
    check(rtlnet_udp_socket_close(b, 1u) == 0, "close socket 1");
    check(reg(RTLNET_UDPS_SOCK_REG(1u, RTLNET_UDPS_SOCK_CTRL)) == 0u, "closed");
    check(rtlnet_udp_socket_find_port(b, 7u) == 3, "port 7 now on socket 3");
    check(rtlnet_udp_socket_close(b, 9u) == -1, "close rejects index 9");

    /* Remote address round trip and bit layout. */
    rem.ip = 0xC0A8010Au;
    rem.port = 40000u;
    rem.mac[0] = 0x00u; rem.mac[1] = 0x11u; rem.mac[2] = 0x22u;
    rem.mac[3] = 0x33u; rem.mac[4] = 0x44u; rem.mac[5] = 0x55u;
    check(rtlnet_udp_socket_set_remote(b, 2u, &rem) == 0, "set_remote");
    check(reg(RTLNET_UDPS_SOCK_REG(2u, RTLNET_UDPS_SOCK_REMOTE_IP)) == 0xC0A8010Au, "REMOTE_IP layout");
    check(reg(RTLNET_UDPS_SOCK_REG(2u, RTLNET_UDPS_SOCK_REMOTE_PORT)) == 40000u, "REMOTE_PORT layout");
    check(reg(RTLNET_UDPS_SOCK_REG(2u, RTLNET_UDPS_SOCK_REMOTE_MAC_HI)) == 0x0011u, "MAC_HI = octets 0, 1");
    check(reg(RTLNET_UDPS_SOCK_REG(2u, RTLNET_UDPS_SOCK_REMOTE_MAC_LO)) == 0x22334455u, "MAC_LO = octets 2..5");
    memset(&back, 0, sizeof(back));
    check(rtlnet_udp_socket_get_remote(b, 2u, &back) == 0, "get_remote");
    check(back.ip == rem.ip && back.port == rem.port && memcmp(back.mac, rem.mac, 6u) == 0, "remote round trip");
    check(rtlnet_udp_socket_set_remote(b, 2u, NULL) == -1, "set_remote rejects NULL");
    check(rtlnet_udp_socket_get_remote(b, 4u, &back) == -1, "get_remote rejects index 4");

    /* Counters. */
    g_regs[RTLNET_UDPS_SOCK_REG(2u, RTLNET_UDPS_SOCK_RX_DATAGRAMS) / 4u] = 11u;
    g_regs[RTLNET_UDPS_SOCK_REG(2u, RTLNET_UDPS_SOCK_RX_DROPS) / 4u]     = 12u;
    g_regs[RTLNET_UDPS_SOCK_REG(2u, RTLNET_UDPS_SOCK_TX_DATAGRAMS) / 4u] = 13u;
    g_regs[RTLNET_UDPS_SOCK_REG(2u, RTLNET_UDPS_SOCK_TX_DROPS) / 4u]     = 14u;
    g_regs[RTLNET_UDPS_REG_RX_DATAGRAMS / 4u]  = 21u;
    g_regs[RTLNET_UDPS_REG_RX_NO_SOCKET / 4u]  = 22u;
    g_regs[RTLNET_UDPS_REG_RX_BAD / 4u]        = 23u;
    g_regs[RTLNET_UDPS_REG_RX_FIFO_DROPS / 4u] = 24u;
    g_regs[RTLNET_UDPS_REG_TX_FRAMES / 4u]     = 25u;
    g_regs[RTLNET_UDPS_REG_TX_DROPS / 4u]      = 26u;
    check(rtlnet_udp_socket_read_sock_counters(b, 2u, &sc) == 0, "read socket counters");
    check(sc.rx_datagrams == 11u && sc.rx_drops == 12u && sc.tx_datagrams == 13u && sc.tx_drops == 14u,
          "socket counters mapped");
    check(rtlnet_udp_socket_read_sock_counters(b, 4u, &sc) == -1, "socket counters reject index 4");
    check(rtlnet_udp_socket_read_counters(b, &gc) == 0, "read global counters");
    check(gc.rx_datagrams == 21u && gc.rx_no_socket == 22u && gc.rx_bad == 23u && gc.rx_fifo_drops == 24u &&
          gc.tx_frames == 25u && gc.tx_drops == 26u, "global counters mapped");
    check(rtlnet_udp_socket_read_counters(b, NULL) == -1, "global counters reject NULL");

    /* Checksum check and counter clear keep each other. */
    rtlnet_udp_socket_set_rx_csum_check(b, 1);
    check(reg(RTLNET_UDPS_REG_CTRL) == RTLNET_UDPS_CTRL_RX_CSUM_CHECK, "RX_CSUM_CHECK set");
    rtlnet_udp_socket_clear_counters(b);
    check(reg(RTLNET_UDPS_REG_CTRL) == RTLNET_UDPS_CTRL_RX_CSUM_CHECK, "clear keeps RX_CSUM_CHECK");
    check(rtlnet_udp_socket_read_counters(b, &gc) == 0 && gc.rx_datagrams == 0u && gc.tx_drops == 0u,
          "global counters cleared");
    check(rtlnet_udp_socket_read_sock_counters(b, 2u, &sc) == 0 && sc.rx_datagrams == 0u && sc.tx_drops == 0u,
          "socket counters cleared");
    rtlnet_udp_socket_set_rx_csum_check(b, 0);
    check(reg(RTLNET_UDPS_REG_CTRL) == 0u, "RX_CSUM_CHECK clear");
    g_regs[RTLNET_UDPS_REG_STATUS / 4u] = RTLNET_UDPS_STATUS_ENABLE | RTLNET_UDPS_STATUS_RX_FIFO_FULL;
    check(rtlnet_udp_socket_status(b) == 0x9u, "status read");

    /* A core with one socket. */
    g_caps = 1u;
    check(rtlnet_udp_socket_open(b, 1u, 1u, 0u) == -1, "one-socket core rejects index 1");
    check(rtlnet_udp_socket_find_port(b, 7u) == -1, "one-socket core scans socket 0 only");

    check(!g_bad_access, "no access outside the 4 KiB window or misaligned");
    if (g_fails == 0) {
        printf("DRIVER TEST PASS: rtlnet_udp_socket checks=%d\n", g_checks);
        return 0;
    }
    printf("DRIVER TEST FAIL: rtlnet_udp_socket fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
