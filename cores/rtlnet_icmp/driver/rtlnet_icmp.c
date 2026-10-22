/*
 * rtlnet_icmp.c -- RTLNet ICMP echo responder leaf driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches the rtlnet_icmp registers. Every access
 * goes through rtlnet_mmio.h with the base address the platform passes in
 * (protocol sub-map base + RTLNET_PROTO_WIN_ICMP). No function waits on
 * hardware.
 */
#include "rtlnet_icmp.h"
#include "rtlnet_mmio.h"

/*
 * rtlnet_icmp_probe -- check that the ICMP leaf answers at base
 * Steps:
 *   1. Read ID and VERSION and compare them with this driver's values.
 * Returns: RTLNET_ICMP_OK when both match; RTLNET_ICMP_ERROR otherwise (an
 *          absent leaf reads 0).
 */
int rtlnet_icmp_probe(uintptr_t base)
{
    if (rtlnet_reg_read32(base, RTLNET_ICMP_REG_ID) != RTLNET_ICMP_ID_VALUE) {
        return RTLNET_ICMP_ERROR;
    }
    if (rtlnet_reg_read32(base, RTLNET_ICMP_REG_VERSION) != RTLNET_ICMP_VERSION_VALUE) {
        return RTLNET_ICMP_ERROR;
    }
    return RTLNET_ICMP_OK;
}

/*
 * rtlnet_icmp_get_max_payload -- the largest echo payload answered
 * Steps:
 *   1. Read CAPS and keep the payload field.
 * Returns: bytes of echo data (1472 for the default 2 KB buffer).
 */
uint32_t rtlnet_icmp_get_max_payload(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_ICMP_REG_CAPS) & RTLNET_ICMP_CAPS_MAX_PAYLOAD_MASK;
}

/*
 * rtlnet_icmp_get_buf_kb -- the payload buffer size
 * Steps:
 *   1. Read CAPS and extract the buffer field.
 * Returns: ICMP_BUF_KB, kilobytes.
 */
uint32_t rtlnet_icmp_get_buf_kb(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_ICMP_REG_CAPS) >> RTLNET_ICMP_CAPS_BUF_KB_SHIFT) &
           RTLNET_ICMP_CAPS_BUF_KB_MASK;
}

/*
 * rtlnet_icmp_get_status -- read STATUS
 * Steps:
 *   1. Read STATUS.
 * Returns: STATUS (RTLNET_ICMP_STATUS_ENABLED, RTLNET_ICMP_STATUS_BUSY).
 */
uint32_t rtlnet_icmp_get_status(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_ICMP_REG_STATUS);
}

/*
 * rtlnet_icmp_read_counters -- read the four counters
 * Steps:
 *   1. Read ECHO_REQUESTS, ECHO_REPLIES, DROPPED_CHECKSUM and DROPPED_SIZE
 *      into *counters.
 * Returns: nothing.
 */
void rtlnet_icmp_read_counters(uintptr_t base, rtlnet_icmp_counters_t *counters)
{
    counters->echo_requests    = rtlnet_reg_read32(base, RTLNET_ICMP_REG_ECHO_REQUESTS);
    counters->echo_replies     = rtlnet_reg_read32(base, RTLNET_ICMP_REG_ECHO_REPLIES);
    counters->dropped_checksum = rtlnet_reg_read32(base, RTLNET_ICMP_REG_DROPPED_CHECKSUM);
    counters->dropped_size     = rtlnet_reg_read32(base, RTLNET_ICMP_REG_DROPPED_SIZE);
}

/*
 * rtlnet_icmp_clear_counters -- restart the four counters from 0
 * Steps:
 *   1. Write CTRL with CNT_CLEAR (a self-clearing pulse).
 * Returns: nothing.
 */
void rtlnet_icmp_clear_counters(uintptr_t base)
{
    rtlnet_reg_write32(base, RTLNET_ICMP_REG_CTRL, RTLNET_ICMP_CTRL_CNT_CLEAR);
}
