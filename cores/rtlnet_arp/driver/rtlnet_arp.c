/*
 * rtlnet_arp.c -- RTLNet ARP responder leaf driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches the rtlnet_arp registers. Every access
 * goes through rtlnet_mmio.h with the base address the platform passes in
 * (protocol sub-map base + RTLNET_PROTO_WIN_ARP). No function waits on
 * hardware.
 */
#include "rtlnet_arp.h"
#include "rtlnet_mmio.h"

/*
 * rtlnet_arp_probe -- check that the ARP leaf answers at base
 * Steps:
 *   1. Read ID and VERSION and compare them with this driver's values.
 * Returns: RTLNET_ARP_OK when both match; RTLNET_ARP_ERROR otherwise (an
 *          absent leaf reads 0).
 */
int rtlnet_arp_probe(uintptr_t base)
{
    if (rtlnet_reg_read32(base, RTLNET_ARP_REG_ID) != RTLNET_ARP_ID_VALUE) {
        return RTLNET_ARP_ERROR;
    }
    if (rtlnet_reg_read32(base, RTLNET_ARP_REG_VERSION) != RTLNET_ARP_VERSION_VALUE) {
        return RTLNET_ARP_ERROR;
    }
    return RTLNET_ARP_OK;
}

/*
 * rtlnet_arp_get_reply_delay_cycles -- the built-in reply delay
 * Steps:
 *   1. Read CAPS.
 * Returns: proto_clk cycles between a request's decision and its reply.
 */
uint32_t rtlnet_arp_get_reply_delay_cycles(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_ARP_REG_CAPS);
}

/*
 * rtlnet_arp_get_status -- read STATUS
 * Steps:
 *   1. Read STATUS.
 * Returns: STATUS (RTLNET_ARP_STATUS_ENABLED, RTLNET_ARP_STATUS_BUSY).
 */
uint32_t rtlnet_arp_get_status(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_ARP_REG_STATUS);
}

/*
 * rtlnet_arp_read_counters -- read the three counters
 * Steps:
 *   1. Read REQUESTS_FOR_US, REPLIES_SENT and IGNORED into *counters.
 * Returns: nothing.
 */
void rtlnet_arp_read_counters(uintptr_t base, rtlnet_arp_counters_t *counters)
{
    counters->requests_for_us = rtlnet_reg_read32(base, RTLNET_ARP_REG_REQUESTS_FOR_US);
    counters->replies_sent    = rtlnet_reg_read32(base, RTLNET_ARP_REG_REPLIES_SENT);
    counters->ignored         = rtlnet_reg_read32(base, RTLNET_ARP_REG_IGNORED);
}

/*
 * rtlnet_arp_clear_counters -- restart the three counters from 0
 * Steps:
 *   1. Write CTRL with CNT_CLEAR (a self-clearing pulse).
 * Returns: nothing.
 */
void rtlnet_arp_clear_counters(uintptr_t base)
{
    rtlnet_reg_write32(base, RTLNET_ARP_REG_CTRL, RTLNET_ARP_CTRL_CNT_CLEAR);
}
