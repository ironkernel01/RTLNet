/*
 * rtlnet_udp_echo.c -- RTLNet UDP echo server driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that reads or writes rtlnet_udp_echo registers.
 * Register map and contracts: rtlnet_udp_echo.h. No driver state: every
 * change is a read-modify-write of CTRL, so the hardware holds the one copy
 * of the configuration.
 */
#include "rtlnet_udp_echo.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

/*
 * ctrl_update -- replace some CTRL configuration bits
 * Steps:
 *   1. Read CTRL, keep the configuration bits outside mask.
 *   2. Write back with the bits of value inside mask (CNT_CLEAR never set).
 * Returns: nothing.
 */
static void ctrl_update(uintptr_t base, uint32_t mask, uint32_t value)
{
    uint32_t v;

    v = rtlnet_reg_read32(base, RTLNET_ECHO_REG_CTRL) & RTLNET_ECHO_CTRL_CONFIG_MASK;
    v = (v & ~mask) | (value & mask);
    rtlnet_reg_write32(base, RTLNET_ECHO_REG_CTRL, v);
}

/*
 * rtlnet_udp_echo_probe -- identify the core
 * Steps:
 *   1. Check ID and VERSION.
 * Returns: 0 when present and matching, -1 otherwise.
 */
int rtlnet_udp_echo_probe(uintptr_t base)
{
    if (rtlnet_reg_read32(base, RTLNET_REG_ID) != RTLNET_ECHO_ID_VALUE) {
        return -1;
    }
    if (rtlnet_reg_read32(base, RTLNET_REG_VERSION) != RTLNET_ECHO_VERSION_VALUE) {
        return -1;
    }
    return 0;
}

/*
 * rtlnet_udp_echo_enable -- start or stop echoing
 * Steps:
 *   1. Set or clear CTRL.ENABLE, keeping the socket selection. While stopped,
 *      datagrams are consumed and counted in DISCARDED.
 * Returns: nothing.
 */
void rtlnet_udp_echo_enable(uintptr_t base, int on)
{
    ctrl_update(base, RTLNET_ECHO_CTRL_ENABLE, on ? RTLNET_ECHO_CTRL_ENABLE : 0u);
}

/*
 * rtlnet_udp_echo_select_socket -- echo only one socket
 * Steps:
 *   1. Check the index fits the CTRL field.
 *   2. Write CTRL.SOCKET and clear SOCKET_ANY, keeping ENABLE.
 * Returns: 0 on success, -1 when sock > 255.
 */
int rtlnet_udp_echo_select_socket(uintptr_t base, uint32_t sock)
{
    if (sock > RTLNET_ECHO_MAX_SOCKET) {
        return -1;
    }
    ctrl_update(base, RTLNET_ECHO_CTRL_SOCKET_ANY | RTLNET_ECHO_CTRL_SOCKET_MASK,
                sock << RTLNET_ECHO_CTRL_SOCKET_SHIFT);
    return 0;
}

/*
 * rtlnet_udp_echo_select_any -- echo every socket
 * Steps:
 *   1. Set CTRL.SOCKET_ANY, keeping ENABLE and the SOCKET field.
 * Returns: nothing.
 */
void rtlnet_udp_echo_select_any(uintptr_t base)
{
    ctrl_update(base, RTLNET_ECHO_CTRL_SOCKET_ANY, RTLNET_ECHO_CTRL_SOCKET_ANY);
}

/*
 * rtlnet_udp_echo_get_config -- read the configuration
 * Steps:
 *   1. Validate the pointer; decode CTRL.
 * Returns: 0 on success, -1 on NULL cfg.
 */
int rtlnet_udp_echo_get_config(uintptr_t base, rtlnet_udp_echo_config_t *cfg)
{
    uint32_t v;

    if (cfg == NULL) {
        return -1;
    }
    v = rtlnet_reg_read32(base, RTLNET_ECHO_REG_CTRL);
    cfg->enabled    = (v & RTLNET_ECHO_CTRL_ENABLE) != 0u;
    cfg->socket_any = (v & RTLNET_ECHO_CTRL_SOCKET_ANY) != 0u;
    cfg->socket     = (v & RTLNET_ECHO_CTRL_SOCKET_MASK) >> RTLNET_ECHO_CTRL_SOCKET_SHIFT;
    return 0;
}

/*
 * rtlnet_udp_echo_read_counters -- read the three counters
 * Steps:
 *   1. Validate the pointer; read each counter.
 * Returns: 0 on success, -1 on NULL c.
 */
int rtlnet_udp_echo_read_counters(uintptr_t base, rtlnet_udp_echo_counters_t *c)
{
    if (c == NULL) {
        return -1;
    }
    c->echoed_datagrams = rtlnet_reg_read32(base, RTLNET_ECHO_REG_ECHOED_DATAGRAMS);
    c->echoed_bytes     = rtlnet_reg_read32(base, RTLNET_ECHO_REG_ECHOED_BYTES);
    c->discarded        = rtlnet_reg_read32(base, RTLNET_ECHO_REG_DISCARDED);
    return 0;
}

/*
 * rtlnet_udp_echo_clear_counters -- zero the counters
 * Steps:
 *   1. Write CTRL with its current configuration plus the CNT_CLEAR pulse
 *      (a CTRL write reloads ENABLE, SOCKET_ANY and SOCKET, so they are kept).
 * Returns: nothing.
 */
void rtlnet_udp_echo_clear_counters(uintptr_t base)
{
    uint32_t v;

    v = rtlnet_reg_read32(base, RTLNET_ECHO_REG_CTRL) & RTLNET_ECHO_CTRL_CONFIG_MASK;
    rtlnet_reg_write32(base, RTLNET_ECHO_REG_CTRL, v | RTLNET_ECHO_CTRL_CNT_CLEAR);
}
