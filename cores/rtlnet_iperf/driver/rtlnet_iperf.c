/*
 * rtlnet_iperf.c -- RTLNet iperf 2 UDP server leaf driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches the rtlnet_iperf registers: the server
 * port, the reverse-mode permission, the counter clear and the statistics
 * snapshot. The leaf runs the protocol by itself; nothing here waits on
 * hardware.
 *
 * CTRL rule: every CTRL write also writes REVERSE_ALLOWED (bit 0), so a
 * counter clear carries the current permission read back from CTRL.
 */
#include "rtlnet_iperf.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

/*
 * rtlnet_iperf_probe -- check that an iperf leaf answers at base
 * Returns: RTLNET_IPERF_OK when ID and VERSION match, RTLNET_IPERF_ERR_ID otherwise.
 */
int rtlnet_iperf_probe(uintptr_t base)
{
    if (rtlnet_reg_read32(base, RTLNET_IPERF_REG_ID) != RTLNET_IPERF_ID_VALUE) {
        return RTLNET_IPERF_ERR_ID;
    }
    if (rtlnet_reg_read32(base, RTLNET_IPERF_REG_VERSION) != RTLNET_IPERF_VERSION_VALUE) {
        return RTLNET_IPERF_ERR_ID;
    }
    return RTLNET_IPERF_OK;
}

/*
 * rtlnet_iperf_set_port -- set the UDP port the server listens on
 * Steps:
 *   1. Reject port 0 and values above 65535 (no write).
 *   2. Write UDP_PORT; reports and reverse datagrams use it as source port.
 * Returns: RTLNET_IPERF_OK, or RTLNET_IPERF_ERR_ARG for a rejected port.
 */
int rtlnet_iperf_set_port(uintptr_t base, uint32_t port)
{
    if ((port == 0u) || (port > RTLNET_IPERF_PORT_MASK)) {
        return RTLNET_IPERF_ERR_ARG;
    }
    rtlnet_reg_write32(base, RTLNET_IPERF_REG_UDP_PORT, port);
    return RTLNET_IPERF_OK;
}

/*
 * rtlnet_iperf_get_port -- read the UDP port in use
 * Returns: the port, 1..65535.
 */
uint32_t rtlnet_iperf_get_port(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_IPERF_REG_UDP_PORT) & RTLNET_IPERF_PORT_MASK;
}

/*
 * rtlnet_iperf_set_reverse_allowed -- allow or refuse -R reverse streams
 * Returns: nothing. A refused -R request starts no stream and opens no flow.
 */
void rtlnet_iperf_set_reverse_allowed(uintptr_t base, int on)
{
    rtlnet_reg_write32(base, RTLNET_IPERF_REG_CTRL, on ? RTLNET_IPERF_CTRL_REVERSE_ALLOWED : 0u);
}

/*
 * rtlnet_iperf_get_reverse_allowed -- read the reverse-mode permission
 * Returns: 1 when -R requests are honoured, 0 otherwise.
 */
int rtlnet_iperf_get_reverse_allowed(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_IPERF_REG_CTRL) & RTLNET_IPERF_CTRL_REVERSE_ALLOWED) ? 1 : 0;
}

/*
 * rtlnet_iperf_clear_counters -- zero the statistics registers
 * Steps:
 *   1. Read CTRL for the current REVERSE_ALLOWED level.
 *   2. Write it back together with the CNT_CLEAR pulse.
 * Returns: nothing. A flow in progress keeps its own report accounting.
 */
void rtlnet_iperf_clear_counters(uintptr_t base)
{
    uint32_t keep = rtlnet_reg_read32(base, RTLNET_IPERF_REG_CTRL) & RTLNET_IPERF_CTRL_REVERSE_ALLOWED;

    rtlnet_reg_write32(base, RTLNET_IPERF_REG_CTRL, keep | RTLNET_IPERF_CTRL_CNT_CLEAR);
}

/*
 * rtlnet_iperf_read_stats -- snapshot of the status and statistics
 * Steps:
 *   1. Read STATUS, CTRL, UDP_PORT and CAPS.
 *   2. Read RX_BYTES_LO first (it latches the high word), then RX_BYTES_HI,
 *      and the other counters.
 * Returns: RTLNET_IPERF_OK, or RTLNET_IPERF_ERR_ARG for a null pointer.
 */
int rtlnet_iperf_read_stats(uintptr_t base, rtlnet_iperf_stats_t *st)
{
    uint32_t status;
    uint32_t caps;
    uint32_t lo;
    uint32_t hi;

    if (st == NULL) {
        return RTLNET_IPERF_ERR_ARG;
    }
    status = rtlnet_reg_read32(base, RTLNET_IPERF_REG_STATUS);
    caps = rtlnet_reg_read32(base, RTLNET_IPERF_REG_CAPS);
    st->rx_active = (status & RTLNET_IPERF_STATUS_RX_ACTIVE) ? 1 : 0;
    st->tx_active = (status & RTLNET_IPERF_STATUS_TX_ACTIVE) ? 1 : 0;
    st->reverse_allowed = rtlnet_iperf_get_reverse_allowed(base);
    st->udp_port = rtlnet_iperf_get_port(base);
    st->max_dgram_bytes = caps & RTLNET_IPERF_CAPS_DGRAM_MASK;
    st->clk_khz = caps >> RTLNET_IPERF_CAPS_KHZ_SHIFT;
    st->rx_datagrams = rtlnet_reg_read32(base, RTLNET_IPERF_REG_RX_DATAGRAMS);
    lo = rtlnet_reg_read32(base, RTLNET_IPERF_REG_RX_BYTES_LO);
    hi = rtlnet_reg_read32(base, RTLNET_IPERF_REG_RX_BYTES_HI);
    st->rx_bytes = ((uint64_t)hi << 32) | (uint64_t)lo;
    st->rx_lost = rtlnet_reg_read32(base, RTLNET_IPERF_REG_RX_LOST);
    st->rx_outoforder = rtlnet_reg_read32(base, RTLNET_IPERF_REG_RX_OUTOFORDER);
    st->tx_datagrams = rtlnet_reg_read32(base, RTLNET_IPERF_REG_TX_DATAGRAMS);
    st->jitter_us16 = rtlnet_reg_read32(base, RTLNET_IPERF_REG_JITTER_US16);
    st->req_rate_bps = rtlnet_reg_read32(base, RTLNET_IPERF_REG_REQ_RATE_BPS);
    st->last_duration_us = rtlnet_reg_read32(base, RTLNET_IPERF_REG_LAST_DURATION_US);
    st->reports_sent = rtlnet_reg_read32(base, RTLNET_IPERF_REG_REPORTS_SENT);
    return RTLNET_IPERF_OK;
}
