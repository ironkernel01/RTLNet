/*
 * rtlnet_udp_socket.c -- RTLNet UDP socket layer driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that reads or writes rtlnet_udp_socket registers.
 * Register map and contracts: rtlnet_udp_socket.h. The driver keeps no state
 * of its own; the socket count is read from CAPS on every call that takes a
 * socket index, so one driver serves any number of instances.
 */
#include "rtlnet_udp_socket.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

/* -------------------------------------------------------------------------- */
/* Internal helpers                                                           */
/* -------------------------------------------------------------------------- */

/*
 * sock_count -- number of sockets the core was built with
 * Steps:
 *   1. Read CAPS and return its socket field.
 * Returns: NUM_SOCKETS (0 when the core is absent and CAPS reads 0).
 */
static uint32_t sock_count(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_REG_CAPS) & RTLNET_UDPS_CAPS_SOCKETS_MASK;
}

/*
 * sock_valid -- check a socket index against the core
 * Steps:
 *   1. Compare with the built socket count and the register-map limit.
 * Returns: 1 when the index addresses an existing socket, else 0.
 */
static int sock_valid(uintptr_t base, uint32_t sock)
{
    return (sock < RTLNET_UDPS_MAX_SOCKETS) && (sock < sock_count(base));
}

/* -------------------------------------------------------------------------- */
/* Public functions                                                           */
/* -------------------------------------------------------------------------- */

/*
 * rtlnet_udp_socket_probe -- identify the core and read its build parameters
 * Steps:
 *   1. Check ID and VERSION against the values this driver was written for.
 *   2. Decode CAPS into *caps (when caps is not NULL).
 * Returns: 0 when the core is present and matches, -1 otherwise.
 */
int rtlnet_udp_socket_probe(uintptr_t base, rtlnet_udp_socket_caps_t *caps)
{
    uint32_t v;

    if (rtlnet_reg_read32(base, RTLNET_REG_ID) != RTLNET_UDPS_ID_VALUE) {
        return -1;
    }
    if (rtlnet_reg_read32(base, RTLNET_REG_VERSION) != RTLNET_UDPS_VERSION_VALUE) {
        return -1;
    }
    v = rtlnet_reg_read32(base, RTLNET_REG_CAPS);
    if (caps != NULL) {
        caps->num_sockets = v & RTLNET_UDPS_CAPS_SOCKETS_MASK;
        caps->rx_buf_kb   = (v >> RTLNET_UDPS_CAPS_RX_KB_SHIFT) & RTLNET_UDPS_CAPS_KB_MASK;
        caps->tx_buf_kb   = (v >> RTLNET_UDPS_CAPS_TX_KB_SHIFT) & RTLNET_UDPS_CAPS_KB_MASK;
        caps->csum_check  = (v & RTLNET_UDPS_CAPS_CSUM_CHECK) != 0u;
    }
    return 0;
}

/*
 * rtlnet_udp_socket_open -- bind a socket to a local port and enable it
 * Steps:
 *   1. Validate the index and the options (only CONNECT_ON_RX is defined).
 *   2. Disable the socket, so no datagram is matched against a half-written
 *      binding.
 *   3. Write LOCAL_PORT, then CTRL = ENABLE | options.
 * Returns: 0 on success, -1 on a bad index or unknown option bits.
 */
int rtlnet_udp_socket_open(uintptr_t base, uint32_t sock, uint16_t local_port, uint32_t options)
{
    if (!sock_valid(base, sock) || ((options & ~RTLNET_UDPS_OPEN_CONNECT_ON_RX) != 0u)) {
        return -1;
    }
    rtlnet_reg_write32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_CTRL), 0u);
    rtlnet_reg_write32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_LOCAL_PORT), (uint32_t)local_port);
    rtlnet_reg_write32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_CTRL),
                       RTLNET_UDPS_SCTRL_ENABLE | options);
    return 0;
}

/*
 * rtlnet_udp_socket_close -- disable a socket
 * Steps:
 *   1. Validate the index.
 *   2. Write CTRL = 0 (no receive match, transmit datagrams dropped and
 *      counted). The port and remote registers are kept.
 * Returns: 0 on success, -1 on a bad index.
 */
int rtlnet_udp_socket_close(uintptr_t base, uint32_t sock)
{
    if (!sock_valid(base, sock)) {
        return -1;
    }
    rtlnet_reg_write32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_CTRL), 0u);
    return 0;
}

/*
 * rtlnet_udp_socket_set_connect_on_rx -- make the remote registers follow the last sender
 * Steps:
 *   1. Validate the index.
 *   2. Read-modify-write CTRL bit CONNECT_ON_RX, keeping ENABLE.
 * Returns: 0 on success, -1 on a bad index.
 */
int rtlnet_udp_socket_set_connect_on_rx(uintptr_t base, uint32_t sock, int on)
{
    uint32_t off;
    uint32_t v;

    if (!sock_valid(base, sock)) {
        return -1;
    }
    off = RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_CTRL);
    v = rtlnet_reg_read32(base, off);
    if (on) {
        v |= RTLNET_UDPS_SCTRL_CONNECT_ON_RX;
    } else {
        v &= ~RTLNET_UDPS_SCTRL_CONNECT_ON_RX;
    }
    rtlnet_reg_write32(base, off, v);
    return 0;
}

/*
 * rtlnet_udp_socket_get_config -- read a socket's binding
 * Steps:
 *   1. Validate the index and the output pointer.
 *   2. Read LOCAL_PORT and CTRL.
 * Returns: 0 on success, -1 on a bad index or NULL cfg.
 */
int rtlnet_udp_socket_get_config(uintptr_t base, uint32_t sock, rtlnet_udp_socket_config_t *cfg)
{
    uint32_t ctrl;

    if (!sock_valid(base, sock) || (cfg == NULL)) {
        return -1;
    }
    ctrl = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_CTRL));
    cfg->local_port    = (uint16_t)rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_LOCAL_PORT));
    cfg->enabled       = (ctrl & RTLNET_UDPS_SCTRL_ENABLE) != 0u;
    cfg->connect_on_rx = (ctrl & RTLNET_UDPS_SCTRL_CONNECT_ON_RX) != 0u;
    return 0;
}

/*
 * rtlnet_udp_socket_find_port -- find the socket that receives a port
 * Steps:
 *   1. Scan the sockets in index order (the hardware's match priority) for
 *      an enabled one bound to local_port.
 * Returns: the socket index, or -1 when no enabled socket has the port.
 */
int rtlnet_udp_socket_find_port(uintptr_t base, uint16_t local_port)
{
    uint32_t n;
    uint32_t count;

    count = sock_count(base);
    for (n = 0u; (n < count) && (n < RTLNET_UDPS_MAX_SOCKETS); n++) {
        uint32_t ctrl = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(n, RTLNET_UDPS_SOCK_CTRL));
        uint32_t port = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(n, RTLNET_UDPS_SOCK_LOCAL_PORT));
        if (((ctrl & RTLNET_UDPS_SCTRL_ENABLE) != 0u) && (port == (uint32_t)local_port)) {
            return (int)n;
        }
    }
    return -1;
}

/*
 * rtlnet_udp_socket_set_remote -- write a socket's remote address
 * Steps:
 *   1. Validate the index and the pointer.
 *   2. Write REMOTE_IP, REMOTE_PORT, REMOTE_MAC_HI (octets 0, 1) and
 *      REMOTE_MAC_LO (octets 2..5). With CONNECT_ON_RX set, the next
 *      delivered datagram overwrites these.
 * Returns: 0 on success, -1 on a bad index or NULL remote.
 */
int rtlnet_udp_socket_set_remote(uintptr_t base, uint32_t sock, const rtlnet_udp_socket_remote_t *remote)
{
    uint32_t hi;
    uint32_t lo;

    if (!sock_valid(base, sock) || (remote == NULL)) {
        return -1;
    }
    hi = ((uint32_t)remote->mac[0] << 8) | (uint32_t)remote->mac[1];
    lo = ((uint32_t)remote->mac[2] << 24) | ((uint32_t)remote->mac[3] << 16) |
         ((uint32_t)remote->mac[4] << 8) | (uint32_t)remote->mac[5];
    rtlnet_reg_write32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_REMOTE_IP), remote->ip);
    rtlnet_reg_write32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_REMOTE_PORT), (uint32_t)remote->port);
    rtlnet_reg_write32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_REMOTE_MAC_HI), hi);
    rtlnet_reg_write32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_REMOTE_MAC_LO), lo);
    return 0;
}

/*
 * rtlnet_udp_socket_get_remote -- read a socket's remote address
 * Steps:
 *   1. Validate the index and the pointer.
 *   2. Read the four remote registers and unpack the MAC.
 *   The registers are read one by one; a datagram delivered with
 *   CONNECT_ON_RX between two reads can give a mixed result (read twice and
 *   compare when that matters).
 * Returns: 0 on success, -1 on a bad index or NULL remote.
 */
int rtlnet_udp_socket_get_remote(uintptr_t base, uint32_t sock, rtlnet_udp_socket_remote_t *remote)
{
    uint32_t hi;
    uint32_t lo;

    if (!sock_valid(base, sock) || (remote == NULL)) {
        return -1;
    }
    remote->ip   = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_REMOTE_IP));
    remote->port = (uint16_t)rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_REMOTE_PORT));
    hi = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_REMOTE_MAC_HI));
    lo = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_REMOTE_MAC_LO));
    remote->mac[0] = (uint8_t)(hi >> 8);
    remote->mac[1] = (uint8_t)hi;
    remote->mac[2] = (uint8_t)(lo >> 24);
    remote->mac[3] = (uint8_t)(lo >> 16);
    remote->mac[4] = (uint8_t)(lo >> 8);
    remote->mac[5] = (uint8_t)lo;
    return 0;
}

/*
 * rtlnet_udp_socket_read_sock_counters -- read one socket's four counters
 * Steps:
 *   1. Validate the index and the pointer.
 *   2. Read RX_DATAGRAMS, RX_DROPS, TX_DATAGRAMS, TX_DROPS.
 * Returns: 0 on success, -1 on a bad index or NULL c.
 */
int rtlnet_udp_socket_read_sock_counters(uintptr_t base, uint32_t sock, rtlnet_udp_socket_sock_counters_t *c)
{
    if (!sock_valid(base, sock) || (c == NULL)) {
        return -1;
    }
    c->rx_datagrams = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_RX_DATAGRAMS));
    c->rx_drops     = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_RX_DROPS));
    c->tx_datagrams = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_TX_DATAGRAMS));
    c->tx_drops     = rtlnet_reg_read32(base, RTLNET_UDPS_SOCK_REG(sock, RTLNET_UDPS_SOCK_TX_DROPS));
    return 0;
}

/*
 * rtlnet_udp_socket_read_counters -- read the six global counters
 * Steps:
 *   1. Validate the pointer.
 *   2. Read each counter register.
 * Returns: 0 on success, -1 on NULL c.
 */
int rtlnet_udp_socket_read_counters(uintptr_t base, rtlnet_udp_socket_counters_t *c)
{
    if (c == NULL) {
        return -1;
    }
    c->rx_datagrams  = rtlnet_reg_read32(base, RTLNET_UDPS_REG_RX_DATAGRAMS);
    c->rx_no_socket  = rtlnet_reg_read32(base, RTLNET_UDPS_REG_RX_NO_SOCKET);
    c->rx_bad        = rtlnet_reg_read32(base, RTLNET_UDPS_REG_RX_BAD);
    c->rx_fifo_drops = rtlnet_reg_read32(base, RTLNET_UDPS_REG_RX_FIFO_DROPS);
    c->tx_frames     = rtlnet_reg_read32(base, RTLNET_UDPS_REG_TX_FRAMES);
    c->tx_drops      = rtlnet_reg_read32(base, RTLNET_UDPS_REG_TX_DROPS);
    return 0;
}

/*
 * rtlnet_udp_socket_clear_counters -- zero every global and per-socket counter
 * Steps:
 *   1. Read CTRL and write it back with CNT_CLEAR set, so RX_CSUM_CHECK is
 *      kept (CNT_CLEAR is a self-clearing pulse).
 * Returns: nothing.
 */
void rtlnet_udp_socket_clear_counters(uintptr_t base)
{
    uint32_t v;

    v = rtlnet_reg_read32(base, RTLNET_UDPS_REG_CTRL) & RTLNET_UDPS_CTRL_RX_CSUM_CHECK;
    rtlnet_reg_write32(base, RTLNET_UDPS_REG_CTRL, v | RTLNET_UDPS_CTRL_CNT_CLEAR);
}

/*
 * rtlnet_udp_socket_set_rx_csum_check -- enable or disable receive UDP checksum verification
 * Steps:
 *   1. Write CTRL with only RX_CSUM_CHECK set or clear (no CNT_CLEAR).
 *   With it set, a datagram with a non-zero UDP checksum that does not verify
 *   is dropped and counted in RX_BAD; a zero checksum (none) is accepted.
 * Returns: nothing.
 */
void rtlnet_udp_socket_set_rx_csum_check(uintptr_t base, int on)
{
    rtlnet_reg_write32(base, RTLNET_UDPS_REG_CTRL, on ? RTLNET_UDPS_CTRL_RX_CSUM_CHECK : 0u);
}

/*
 * rtlnet_udp_socket_status -- read STATUS
 * Steps:
 *   1. Read the register.
 * Returns: the STATUS word (RTLNET_UDPS_STATUS_* bits).
 */
uint32_t rtlnet_udp_socket_status(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_UDPS_REG_STATUS);
}
