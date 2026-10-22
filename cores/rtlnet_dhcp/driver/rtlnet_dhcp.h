/*
 * rtlnet_dhcp.h -- RTLNet DHCP client leaf: register map and driver API
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one definition of the rtlnet_dhcp register map (offsets, bit
 * positions, codes) and the driver entry points. The RTL register file
 * (cores/rtlnet_dhcp/hdl/rtlnet_dhcp.sv) mirrors every value below as a
 * localparam with a pointer comment to this file; both change in the same
 * commit. Drift is silent on the wire: a CTRL bit moved on one side only
 * starts, stops or renews the lease at the wrong write, and a moved offset
 * reads another register.
 *
 * Header/source split: this header holds signatures, register constants,
 * types and contract prose; rtlnet_dhcp.c holds the per-function commentary.
 * Register access goes through rtlnet_mmio.h only; the base address is passed
 * in by the caller (protocol window 0x1_0000 + 0x3000 on the Nexys Video).
 */
#ifndef RTLNET_DHCP_H
#define RTLNET_DHCP_H

#include <stdint.h>   /* uint32_t, uintptr_t */

/* ---- Register offsets (byte offsets inside the 4 KiB leaf window) ---- */
#define RTLNET_DHCP_REG_ID              0x000u   /* RO "DHCP" */
#define RTLNET_DHCP_REG_VERSION         0x004u   /* RO 0xMMDDYYYY */
#define RTLNET_DHCP_REG_CAPS            0x008u   /* RO build parameters */
#define RTLNET_DHCP_REG_CTRL            0x00Cu   /* RW pulses + AUTO level */
#define RTLNET_DHCP_REG_STATUS          0x010u   /* RO state, bound, fail */
#define RTLNET_DHCP_REG_LEASE_IP        0x014u   /* RO leased address */
#define RTLNET_DHCP_REG_LEASE_MASK      0x018u   /* RO option 1 */
#define RTLNET_DHCP_REG_LEASE_ROUTER    0x01Cu   /* RO option 3 (first address) */
#define RTLNET_DHCP_REG_LEASE_SERVER    0x020u   /* RO option 54 */
#define RTLNET_DHCP_REG_LEASE_TIME_S    0x024u   /* RO lease in seconds (0xFFFFFFFF infinite) */
#define RTLNET_DHCP_REG_LEASE_ELAPSED_S 0x028u   /* RO seconds since the binding ACK */
#define RTLNET_DHCP_REG_XID             0x02Cu   /* RO transaction id in use */
#define RTLNET_DHCP_REG_DISCOVERS_SENT  0x030u   /* RO counter */
#define RTLNET_DHCP_REG_OFFERS_RX       0x034u   /* RO counter */
#define RTLNET_DHCP_REG_REQUESTS_SENT   0x038u   /* RO counter */
#define RTLNET_DHCP_REG_ACKS_RX         0x03Cu   /* RO counter */
#define RTLNET_DHCP_REG_NAKS_RX         0x040u   /* RO counter */
#define RTLNET_DHCP_REG_LEASES_LOST     0x044u   /* RO counter */
#define RTLNET_DHCP_REG_RELEASES_SENT   0x048u   /* RO counter */

/* ---- Constant register values ---- */
#define RTLNET_DHCP_ID_VALUE            0x44484350u   /* "DHCP" */
#define RTLNET_DHCP_VERSION_VALUE       0x10222026u   /* register map 10-22-2026 */

/* ---- CAPS fields ---- */
#define RTLNET_DHCP_CAPS_BUF_KB_MASK    0x000000FFu   /* [7:0]  DHCP_BUF_KB */
#define RTLNET_DHCP_CAPS_TRIES_SHIFT    8u            /* [11:8] MAX_TRIES */
#define RTLNET_DHCP_CAPS_TRIES_MASK     0x00000F00u
#define RTLNET_DHCP_CAPS_RELEASE        0x00010000u   /* [16] DHCPRELEASE on STOP */

/* ---- CTRL bits. Pulse bits act on a write of 1 and read 0. ---- */
#define RTLNET_DHCP_CTRL_START          0x00000001u   /* pulse: (re)start acquisition, new xid */
#define RTLNET_DHCP_CTRL_STOP           0x00000002u   /* pulse: drop the lease (DHCPRELEASE if held) */
#define RTLNET_DHCP_CTRL_AUTO           0x00000004u   /* level: firmware auto-start intent, no hardware effect */
#define RTLNET_DHCP_CTRL_RENEW_NOW      0x00000008u   /* pulse: when BOUND, renew now */
#define RTLNET_DHCP_CTRL_CNT_CLEAR      0x00010000u   /* pulse: clear the counters */

/* ---- STATUS fields ---- */
#define RTLNET_DHCP_STATUS_STATE_MASK   0x00000007u   /* [2:0] client state, codes below */
#define RTLNET_DHCP_STATUS_BOUND        0x00000100u   /* [8]  lease_valid */
#define RTLNET_DHCP_STATUS_FAIL         0x00000200u   /* [9]  the last acquisition gave up */
#define RTLNET_DHCP_STATUS_ENABLE       0x00010000u   /* [16] the wrapper's leaf enable */

/* ---- Client state codes (STATUS[2:0]) ---- */
#define RTLNET_DHCP_STATE_INIT          0u
#define RTLNET_DHCP_STATE_SELECTING     1u
#define RTLNET_DHCP_STATE_REQUESTING    2u
#define RTLNET_DHCP_STATE_BOUND         3u
#define RTLNET_DHCP_STATE_RENEWING      4u
#define RTLNET_DHCP_STATE_FAIL          5u

/* ---- Driver results ---- */
#define RTLNET_DHCP_OK                  0
#define RTLNET_DHCP_ERR_ID              (-1)   /* ID or VERSION register mismatch */
#define RTLNET_DHCP_ERR_ARG             (-2)   /* null pointer argument */

/* Snapshot of the leaf's lease and counters. Addresses carry the first
 * octet in bits [31:24]. */
typedef struct {
    uint32_t state;           /* RTLNET_DHCP_STATE_* */
    int      bound;           /* 1 while a lease is held (lease_valid) */
    int      fail;            /* 1 after an acquisition gave up */
    int      auto_start;      /* the AUTO flag as written by firmware */
    int      enabled;         /* the wrapper's leaf enable */
    uint32_t lease_ip;
    uint32_t lease_mask;
    uint32_t lease_router;
    uint32_t lease_server;
    uint32_t lease_time_s;
    uint32_t lease_elapsed_s;
    uint32_t xid;
} rtlnet_dhcp_lease_t;

typedef struct {
    uint32_t discovers_sent;
    uint32_t offers_rx;
    uint32_t requests_sent;
    uint32_t acks_rx;
    uint32_t naks_rx;
    uint32_t leases_lost;
    uint32_t releases_sent;
} rtlnet_dhcp_counters_t;

int  rtlnet_dhcp_probe(uintptr_t base);
void rtlnet_dhcp_start(uintptr_t base);
void rtlnet_dhcp_stop(uintptr_t base);
void rtlnet_dhcp_renew_now(uintptr_t base);
void rtlnet_dhcp_set_auto(uintptr_t base, int on);
int  rtlnet_dhcp_get_auto(uintptr_t base);
void rtlnet_dhcp_clear_counters(uintptr_t base);
uint32_t rtlnet_dhcp_state(uintptr_t base);
int  rtlnet_dhcp_read_lease(uintptr_t base, rtlnet_dhcp_lease_t *lease);
int  rtlnet_dhcp_read_counters(uintptr_t base, rtlnet_dhcp_counters_t *cnt);
const char *rtlnet_dhcp_state_name(uint32_t state);

#endif /* RTLNET_DHCP_H */
