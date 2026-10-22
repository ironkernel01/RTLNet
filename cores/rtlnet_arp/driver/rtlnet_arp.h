/*
 * rtlnet_arp.h -- RTLNet ARP responder leaf driver interface
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the rtlnet_arp register map (window 0x1000
 * of the protocol sub-map; the platform passes protocol base + 0x1000) and
 * the driver API that owns it. cores/rtlnet_arp/hdl/rtlnet_arp.sv mirrors
 * every offset and bit below in localparams; the two change together in one
 * commit. If they drift, counter reads return another register (or 0 for an
 * undefined offset) without any error.
 *
 * The leaf is enabled and disabled by the wrapper's CTRL.LEAF_ENABLE bit 2
 * (rtlnet_eth_protocol.h); STATUS.ENABLED shows that bit.
 *
 * This header holds offsets, bit fields, types and contract prose; the
 * per-function commentary is in rtlnet_arp.c.
 */
#ifndef RTLNET_ARP_H
#define RTLNET_ARP_H

#include <stdint.h>   /* uint32_t, uintptr_t */

/* Register offsets. */
#define RTLNET_ARP_REG_ID               0x000u   /* RO "ARP1" */
#define RTLNET_ARP_REG_VERSION          0x004u   /* RO 0xMMDDYYYY */
#define RTLNET_ARP_REG_CAPS             0x008u   /* RO REPLY_DELAY_CYCLES (proto_clk cycles) */
#define RTLNET_ARP_REG_CTRL             0x00Cu   /* W  CNT_CLEAR pulse, reads 0 */
#define RTLNET_ARP_REG_STATUS           0x010u   /* RO */
#define RTLNET_ARP_REG_REQUESTS_FOR_US  0x020u   /* RO valid requests for the local IP that were taken */
#define RTLNET_ARP_REG_REPLIES_SENT     0x024u   /* RO replies handed to the arbiter */
#define RTLNET_ARP_REG_IGNORED          0x028u   /* RO ARP frames not answered */

#define RTLNET_ARP_ID_VALUE             0x41525031u   /* "ARP1" */
#define RTLNET_ARP_VERSION_VALUE        0x10222026u

#define RTLNET_ARP_CTRL_CNT_CLEAR       0x00000001u
#define RTLNET_ARP_STATUS_ENABLED       0x00000001u
#define RTLNET_ARP_STATUS_BUSY          0x00000002u

#define RTLNET_ARP_OK                   0
#define RTLNET_ARP_ERROR                (-1)

/* Counters. Once idle: requests_for_us = replies_sent (a request accepted
 * before a disable is still answered). */
typedef struct {
    uint32_t requests_for_us;
    uint32_t replies_sent;
    uint32_t ignored;
} rtlnet_arp_counters_t;

int rtlnet_arp_probe(uintptr_t base);
uint32_t rtlnet_arp_get_reply_delay_cycles(uintptr_t base);
uint32_t rtlnet_arp_get_status(uintptr_t base);
void rtlnet_arp_read_counters(uintptr_t base, rtlnet_arp_counters_t *counters);
void rtlnet_arp_clear_counters(uintptr_t base);

#endif /* RTLNET_ARP_H */
