/*
 * rtlnet_udp_echo.h -- RTLNet UDP echo server driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one file pair (rtlnet_udp_echo.h / .c) that touches the
 * registers of the rtlnet_udp_echo core. Every register offset and bit of the
 * core is defined here, once; hdl/rtlnet_udp_echo.sv mirrors them as
 * localparams with a pointer to this header. Change both in the same commit:
 * a mismatch silently selects the wrong socket or reads the wrong counter.
 *
 * The base address (board window 0x0_3000 on the Nexys Video) is passed in by
 * the platform layer. Register access goes only through rtlnet_mmio.h.
 *
 * Behaviour. When enabled, every datagram the socket layer delivers on the
 * selected socket (or on any socket with SOCKET_ANY) is sent back to its
 * sender with the payload unchanged; every other datagram is consumed and
 * counted in DISCARDED. Selection changes apply from the next datagram.
 * The socket itself (its local port) is opened with the socket-layer driver
 * (rtlnet_udp_socket_open).
 *
 * This header holds the register map, the types and the function contracts;
 * rtlnet_udp_echo.c holds the per-function commentary.
 */
#ifndef RTLNET_UDP_ECHO_H
#define RTLNET_UDP_ECHO_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#define RTLNET_ECHO_ID_VALUE              0x4543484Fu   /* "ECHO" */
#define RTLNET_ECHO_VERSION_VALUE         0x10222026u

/* Registers (ID, VERSION, CAPS at RTLNET_REG_* of rtlnet_mmio.h). */
#define RTLNET_ECHO_REG_CTRL              0x00Cu   /* RW; CNT_CLEAR write-only pulse */
#define RTLNET_ECHO_REG_STATUS            0x010u   /* RO */
#define RTLNET_ECHO_REG_ECHOED_DATAGRAMS  0x014u   /* RO counter */
#define RTLNET_ECHO_REG_ECHOED_BYTES      0x018u   /* RO counter: payload bytes echoed */
#define RTLNET_ECHO_REG_DISCARDED         0x01Cu   /* RO counter: datagrams consumed, not echoed */

/* CAPS: [15:0] largest datagram payload. */
#define RTLNET_ECHO_CAPS_MAX_PAYLOAD_MASK 0x0000FFFFu

/* CTRL bits. */
#define RTLNET_ECHO_CTRL_ENABLE           (1u << 0)
#define RTLNET_ECHO_CTRL_SOCKET_ANY       (1u << 1)
#define RTLNET_ECHO_CTRL_SOCKET_SHIFT     8u
#define RTLNET_ECHO_CTRL_SOCKET_MASK      (0xFFu << RTLNET_ECHO_CTRL_SOCKET_SHIFT)
#define RTLNET_ECHO_CTRL_CNT_CLEAR        (1u << 16)   /* self-clearing, reads 0 */
#define RTLNET_ECHO_CTRL_CONFIG_MASK      (RTLNET_ECHO_CTRL_ENABLE | RTLNET_ECHO_CTRL_SOCKET_ANY | \
                                           RTLNET_ECHO_CTRL_SOCKET_MASK)

/* STATUS bits. */
#define RTLNET_ECHO_STATUS_ENABLE         (1u << 0)
#define RTLNET_ECHO_STATUS_BUSY           (1u << 1)    /* inside a datagram */

/* Largest socket index the CTRL field can name. */
#define RTLNET_ECHO_MAX_SOCKET            255u

typedef struct {
    int      enabled;
    int      socket_any;
    uint32_t socket;
} rtlnet_udp_echo_config_t;

typedef struct {
    uint32_t echoed_datagrams;
    uint32_t echoed_bytes;
    uint32_t discarded;
} rtlnet_udp_echo_counters_t;

/* Return 0 on success, -1 on a bad argument or a missing core. */
int rtlnet_udp_echo_probe(uintptr_t base);
void rtlnet_udp_echo_enable(uintptr_t base, int on);
int rtlnet_udp_echo_select_socket(uintptr_t base, uint32_t sock);
void rtlnet_udp_echo_select_any(uintptr_t base);
int rtlnet_udp_echo_get_config(uintptr_t base, rtlnet_udp_echo_config_t *cfg);
int rtlnet_udp_echo_read_counters(uintptr_t base, rtlnet_udp_echo_counters_t *c);
void rtlnet_udp_echo_clear_counters(uintptr_t base);

#endif /* RTLNET_UDP_ECHO_H */
