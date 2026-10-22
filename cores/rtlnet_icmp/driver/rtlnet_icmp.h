/*
 * rtlnet_icmp.h -- RTLNet ICMP echo responder leaf driver interface
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the rtlnet_icmp register map (window 0x2000
 * of the protocol sub-map; the platform passes protocol base + 0x2000) and
 * the driver API that owns it. cores/rtlnet_icmp/hdl/rtlnet_icmp.sv mirrors
 * every offset and bit below in localparams; the two change together in one
 * commit. If they drift, counter reads return another register (or 0 for an
 * undefined offset) without any error.
 *
 * The leaf is enabled and disabled by the wrapper's CTRL.LEAF_ENABLE bit 1
 * (rtlnet_eth_protocol.h); STATUS.ENABLED shows that bit.
 *
 * This header holds offsets, bit fields, types and contract prose; the
 * per-function commentary is in rtlnet_icmp.c.
 */
#ifndef RTLNET_ICMP_H
#define RTLNET_ICMP_H

#include <stdint.h>   /* uint32_t, uintptr_t */

/* Register offsets. */
#define RTLNET_ICMP_REG_ID                0x000u   /* RO "ICMP" */
#define RTLNET_ICMP_REG_VERSION           0x004u   /* RO 0xMMDDYYYY */
#define RTLNET_ICMP_REG_CAPS              0x008u   /* RO payload buffer */
#define RTLNET_ICMP_REG_CTRL              0x00Cu   /* W  CNT_CLEAR pulse, reads 0 */
#define RTLNET_ICMP_REG_STATUS            0x010u   /* RO */
#define RTLNET_ICMP_REG_ECHO_REQUESTS     0x020u   /* RO echo requests for the local IP that were taken */
#define RTLNET_ICMP_REG_ECHO_REPLIES      0x024u   /* RO replies handed to the arbiter */
#define RTLNET_ICMP_REG_DROPPED_CHECKSUM  0x028u   /* RO requests with a bad ICMP checksum */
#define RTLNET_ICMP_REG_DROPPED_SIZE      0x02Cu   /* RO requests too large, too small or truncated */

#define RTLNET_ICMP_ID_VALUE              0x49434D50u   /* "ICMP" */
#define RTLNET_ICMP_VERSION_VALUE         0x10222026u

/* CAPS fields: the largest echo payload answered (bytes) and the buffer size. */
#define RTLNET_ICMP_CAPS_MAX_PAYLOAD_MASK 0x0000FFFFu
#define RTLNET_ICMP_CAPS_BUF_KB_SHIFT     16u
#define RTLNET_ICMP_CAPS_BUF_KB_MASK      0xFFu

#define RTLNET_ICMP_CTRL_CNT_CLEAR        0x00000001u
#define RTLNET_ICMP_STATUS_ENABLED        0x00000001u
#define RTLNET_ICMP_STATUS_BUSY           0x00000002u

#define RTLNET_ICMP_OK                    0
#define RTLNET_ICMP_ERROR                 (-1)

/* Counters. Once idle: echo_requests = echo_replies + dropped_checksum +
 * dropped_size. */
typedef struct {
    uint32_t echo_requests;
    uint32_t echo_replies;
    uint32_t dropped_checksum;
    uint32_t dropped_size;
} rtlnet_icmp_counters_t;

int rtlnet_icmp_probe(uintptr_t base);
uint32_t rtlnet_icmp_get_max_payload(uintptr_t base);
uint32_t rtlnet_icmp_get_buf_kb(uintptr_t base);
uint32_t rtlnet_icmp_get_status(uintptr_t base);
void rtlnet_icmp_read_counters(uintptr_t base, rtlnet_icmp_counters_t *counters);
void rtlnet_icmp_clear_counters(uintptr_t base);

#endif /* RTLNET_ICMP_H */
