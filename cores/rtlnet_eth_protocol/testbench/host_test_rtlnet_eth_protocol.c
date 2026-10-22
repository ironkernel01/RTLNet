/*
 * host_test_rtlnet_eth_protocol.c -- host unit test of the protocol wrapper driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_eth_protocol.c on the PC against a mocked register map
 * (rtlnet_mmio.h host hooks, RTLNET_HOST_TEST). The mock stores every write,
 * keeps an ordered write log, and models the two register behaviours the
 * driver relies on: CTRL.CNT_CLEAR reads 0, LOCAL_MAC_HI is staged until the
 * LOCAL_MAC_LO write. Prints one line "HOST TEST PASS|FAIL:
 * host_test_rtlnet_eth_protocol checks=<n>" and exits 0 on pass.
 *
 * Build and run (repository root):
 *   gcc -std=c11 -Wall -Wextra -Werror -DRTLNET_HOST_TEST -Icores/rtlnet_common/driver
 *       -Icores/rtlnet_eth_protocol/driver cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.c
 *       cores/rtlnet_eth_protocol/testbench/host_test_rtlnet_eth_protocol.c -o .sim/host_test_eth_protocol.exe
 */
#include "rtlnet_eth_protocol.h"
#include "rtlnet_mmio.h"

#include <stdio.h>    /* printf */
#include <string.h>   /* memset */

#define TEST_BASE        ((uintptr_t)0x44A10000u)
#define TEST_WORDS       0x4000u          /* 64 KiB window, 32-bit words */
#define TEST_LOG_MAX     64u

static uint32_t g_regs[TEST_WORDS];
static uint32_t g_mac_hi_staged;
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
    if (off == RTLNET_PROTO_REG_CTRL) {
        g_regs[off / 4u] = value & ~RTLNET_PROTO_CTRL_CNT_CLEAR;
    } else if (off == RTLNET_PROTO_REG_LOCAL_MAC_HI) {
        g_mac_hi_staged = value & RTLNET_PROTO_MAC_HI_MASK;
    } else if (off == RTLNET_PROTO_REG_LOCAL_MAC_LO) {
        g_regs[RTLNET_PROTO_REG_LOCAL_MAC_HI / 4u] = g_mac_hi_staged;
        g_regs[off / 4u] = value;
    } else {
        g_regs[off / 4u] = value;
    }
}

static void check(int cond, const char *what)
{
    g_checks++;
    if (!cond) {
        g_fails++;
        printf("CHECK FAILED: %s\n", what);
    }
}

static void reset_mock(void)
{
    memset(g_regs, 0, sizeof(g_regs));
    g_mac_hi_staged = 0u;
    g_log_n = 0u;
}

int main(void)
{
    static const uint8_t new_mac[RTLNET_PROTO_MAC_BYTES] = {0x0Eu, 0x00u, 0x11u, 0x22u, 0x33u, 0x44u};
    uint8_t mac[RTLNET_PROTO_MAC_BYTES];
    rtlnet_eth_protocol_counters_t c;

    /* Probe: absent, wrong version, present. */
    reset_mock();
    check(rtlnet_eth_protocol_probe(TEST_BASE) == RTLNET_PROTO_ERROR, "probe fails on an empty map");
    g_regs[RTLNET_PROTO_REG_ID / 4u] = RTLNET_PROTO_ID_VALUE;
    g_regs[RTLNET_PROTO_REG_VERSION / 4u] = 0x01012026u;
    check(rtlnet_eth_protocol_probe(TEST_BASE) == RTLNET_PROTO_ERROR, "probe fails on a wrong VERSION");
    g_regs[RTLNET_PROTO_REG_VERSION / 4u] = RTLNET_PROTO_VERSION_VALUE;
    check(rtlnet_eth_protocol_probe(TEST_BASE) == RTLNET_PROTO_OK, "probe passes on ID and VERSION");

    /* MAC: HI before LO, packed in wire order; read back. */
    g_log_n = 0u;
    rtlnet_eth_protocol_set_mac(TEST_BASE, new_mac);
    check(g_log_n == 2u, "set_mac writes twice");
    check(g_log_off[0] == RTLNET_PROTO_REG_LOCAL_MAC_HI && g_log_val[0] == 0x00000E00u, "set_mac writes HI first");
    check(g_log_off[1] == RTLNET_PROTO_REG_LOCAL_MAC_LO && g_log_val[1] == 0x11223344u, "set_mac writes LO second");
    memset(mac, 0, sizeof(mac));
    rtlnet_eth_protocol_get_mac(TEST_BASE, mac);
    check(memcmp(mac, new_mac, sizeof(mac)) == 0, "get_mac returns the programmed MAC");
    g_regs[RTLNET_PROTO_REG_LOCAL_MAC_HI / 4u] = 0xABCD0249u;   /* upper bits are not part of the MAC */
    g_regs[RTLNET_PROTO_REG_LOCAL_MAC_LO / 4u] = 0x4B524E01u;
    rtlnet_eth_protocol_get_mac(TEST_BASE, mac);
    check(mac[0] == 0x02u && mac[1] == 0x49u && mac[2] == 0x4Bu && mac[5] == 0x01u, "get_mac unpacks the default MAC");

    /* Static address set: offsets and values. */
    rtlnet_eth_protocol_set_static_ip(TEST_BASE, 0x0A010203u);
    rtlnet_eth_protocol_set_netmask(TEST_BASE, 0xFFFF0000u);
    rtlnet_eth_protocol_set_gateway(TEST_BASE, 0x0A010001u);
    check(g_regs[RTLNET_PROTO_REG_STATIC_IP / 4u] == 0x0A010203u, "set_static_ip writes STATIC_IP");
    check(g_regs[RTLNET_PROTO_REG_NETMASK / 4u] == 0xFFFF0000u, "set_netmask writes NETMASK");
    check(g_regs[RTLNET_PROTO_REG_GATEWAY / 4u] == 0x0A010001u, "set_gateway writes GATEWAY");
    check(rtlnet_eth_protocol_get_static_ip(TEST_BASE) == 0x0A010203u, "get_static_ip");
    check(rtlnet_eth_protocol_get_netmask(TEST_BASE) == 0xFFFF0000u, "get_netmask");
    check(rtlnet_eth_protocol_get_gateway(TEST_BASE) == 0x0A010001u, "get_gateway");

    /* Effective address and DHCP flag. */
    g_regs[RTLNET_PROTO_REG_EFFECTIVE_IP / 4u] = 0xC0A80064u;
    g_regs[RTLNET_PROTO_REG_EFFECTIVE_MASK / 4u] = 0xFFFFFF00u;
    g_regs[RTLNET_PROTO_REG_EFFECTIVE_GW / 4u] = 0xC0A80001u;
    g_regs[RTLNET_PROTO_REG_STATUS / 4u] = RTLNET_PROTO_STATUS_IP_FROM_DHCP | RTLNET_PROTO_STATUS_IP_VALID;
    check(rtlnet_eth_protocol_get_effective_ip(TEST_BASE) == 0xC0A80064u, "get_effective_ip");
    check(rtlnet_eth_protocol_get_effective_mask(TEST_BASE) == 0xFFFFFF00u, "get_effective_mask");
    check(rtlnet_eth_protocol_get_effective_gateway(TEST_BASE) == 0xC0A80001u, "get_effective_gateway");
    check(rtlnet_eth_protocol_ip_from_dhcp(TEST_BASE) == 1, "ip_from_dhcp set");
    g_regs[RTLNET_PROTO_REG_STATUS / 4u] = RTLNET_PROTO_STATUS_IP_VALID;
    check(rtlnet_eth_protocol_ip_from_dhcp(TEST_BASE) == 0, "ip_from_dhcp clear");

    /* Filter mode: read-modify-write of CTRL, leaf enables kept. */
    g_regs[RTLNET_PROTO_REG_CTRL / 4u] = 0x00000601u;
    rtlnet_eth_protocol_set_filter_enable(TEST_BASE, 0);
    check(g_regs[RTLNET_PROTO_REG_CTRL / 4u] == 0x00000600u, "filter off keeps LEAF_ENABLE");
    check(rtlnet_eth_protocol_get_filter_enable(TEST_BASE) == 0, "get_filter_enable 0");
    rtlnet_eth_protocol_set_filter_enable(TEST_BASE, 1);
    check(g_regs[RTLNET_PROTO_REG_CTRL / 4u] == 0x00000601u, "filter on");
    check(rtlnet_eth_protocol_get_filter_enable(TEST_BASE) == 1, "get_filter_enable 1");

    /* Leaf enables: present leaves only; a mask naming an absent leaf is rejected. */
    g_regs[RTLNET_PROTO_REG_CAPS / 4u] = 0x00081006u;   /* ICMP and ARP present */
    check(rtlnet_eth_protocol_get_leaves_present(TEST_BASE) == 0x06u, "get_leaves_present");
    check(rtlnet_eth_protocol_get_caps(TEST_BASE) == 0x00081006u, "get_caps");
    check(rtlnet_eth_protocol_set_leaf_enables(TEST_BASE, 1u << RTLNET_PROTO_LEAF_ICMP) == RTLNET_PROTO_OK,
          "set_leaf_enables ICMP only accepted");
    check(g_regs[RTLNET_PROTO_REG_CTRL / 4u] == 0x00000201u, "CTRL with ICMP only, filter kept");
    check(rtlnet_eth_protocol_get_leaf_enables(TEST_BASE) == 0x02u, "get_leaf_enables");
    g_log_n = 0u;
    check(rtlnet_eth_protocol_set_leaf_enables(TEST_BASE, 1u << RTLNET_PROTO_LEAF_DHCP) == RTLNET_PROTO_ERROR,
          "set_leaf_enables with an absent leaf rejected");
    check(g_log_n == 0u, "a rejected mask writes nothing");

    /* Counters and CNT_CLEAR. */
    g_regs[RTLNET_PROTO_REG_INGRESS_FRAMES / 4u] = 11u;
    g_regs[RTLNET_PROTO_REG_INGRESS_FILTERED / 4u] = 22u;
    g_regs[RTLNET_PROTO_REG_INGRESS_DROPPED / 4u] = 33u;
    g_regs[RTLNET_PROTO_REG_EGRESS_FRAMES / 4u] = 44u;
    rtlnet_eth_protocol_read_counters(TEST_BASE, &c);
    check(c.ingress_frames == 11u && c.ingress_filtered == 22u && c.ingress_dropped == 33u && c.egress_frames == 44u,
          "read_counters reads the four offsets");
    g_log_n = 0u;
    rtlnet_eth_protocol_clear_counters(TEST_BASE);
    check(g_log_n == 1u && g_log_off[0] == RTLNET_PROTO_REG_CTRL && g_log_val[0] == 0x00010201u,
          "clear_counters pulses CNT_CLEAR and keeps CTRL");
    check(rtlnet_eth_protocol_get_status(TEST_BASE) == RTLNET_PROTO_STATUS_IP_VALID, "get_status");

    check(!g_bad_access, "every access inside the window, 32-bit aligned");

    if (g_fails == 0u) {
        printf("HOST TEST PASS: host_test_rtlnet_eth_protocol checks=%u\n", g_checks);
        return 0;
    }
    printf("HOST TEST FAIL: host_test_rtlnet_eth_protocol fails=%u checks=%u\n", g_fails, g_checks);
    return 1;
}
