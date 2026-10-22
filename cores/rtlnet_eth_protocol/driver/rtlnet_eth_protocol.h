/*
 * rtlnet_eth_protocol.h -- RTLNet protocol wrapper driver interface
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the rtlnet_eth_protocol wrapper register map
 * (window 0x0000 of the 64 KiB protocol sub-map, architecture section 6.1)
 * and the driver API that owns it. The RTL register file
 * cores/rtlnet_eth_protocol/hdl/rtlnet_eth_protocol_regs.sv mirrors every
 * offset and bit below in localparams; the two change together in one commit.
 * If they drift, a write lands in the wrong register (or in none: undefined
 * offsets ignore writes and read 0) and the driver reports wrong addresses
 * and counters without any error.
 *
 * The leaf register windows inside the sub-map (RTLNET_PROTO_WIN_*) are owned
 * by the leaf drivers (rtlnet_arp.h, rtlnet_icmp.h, ...); the platform passes
 * them base + window.
 *
 * Address conventions: an IPv4 address is a uint32_t in number order (first
 * octet in bits 31..24, 192.169.1.220 = 0xC0A901DC); a MAC address is six
 * bytes in wire order (mac[0] is the first octet on the wire).
 *
 * This header holds offsets, bit fields, types and contract prose; the
 * per-function commentary is in rtlnet_eth_protocol.c.
 */
#ifndef RTLNET_ETH_PROTOCOL_H
#define RTLNET_ETH_PROTOCOL_H

#include <stdint.h>   /* uint8_t, uint32_t, uintptr_t */

/* Register windows of the protocol sub-map (address bits 15..12). */
#define RTLNET_PROTO_WIN_WRAPPER       0x0000u
#define RTLNET_PROTO_WIN_ARP           0x1000u
#define RTLNET_PROTO_WIN_ICMP          0x2000u
#define RTLNET_PROTO_WIN_DHCP          0x3000u
#define RTLNET_PROTO_WIN_IPERF         0x4000u
#define RTLNET_PROTO_WIN_UDP           0x5000u

/* Leaf indices: bit positions in CAPS.LEAF_PRESENT, CTRL.LEAF_ENABLE and
 * STATUS.LEAF_BUSY, and the arbiter priority (0 highest). Fixed whatever is
 * built. */
#define RTLNET_PROTO_LEAF_UDP          0u
#define RTLNET_PROTO_LEAF_ICMP         1u
#define RTLNET_PROTO_LEAF_ARP          2u
#define RTLNET_PROTO_LEAF_DHCP         3u
#define RTLNET_PROTO_LEAF_IPERF        4u
#define RTLNET_PROTO_LEAF_COUNT        5u
#define RTLNET_PROTO_LEAF_MASK_ALL     0x1Fu

/* Register offsets (window 0). */
#define RTLNET_PROTO_REG_ID            0x000u   /* RO "PROT" */
#define RTLNET_PROTO_REG_VERSION       0x004u   /* RO 0xMMDDYYYY */
#define RTLNET_PROTO_REG_CAPS          0x008u   /* RO build parameters */
#define RTLNET_PROTO_REG_CTRL          0x00Cu   /* RW */
#define RTLNET_PROTO_REG_STATUS        0x010u   /* RO */
#define RTLNET_PROTO_REG_LOCAL_MAC_HI  0x014u   /* RW [15:0] octets 0-1; staged until LOCAL_MAC_LO */
#define RTLNET_PROTO_REG_LOCAL_MAC_LO  0x018u   /* RW octets 2-5; the write commits all 48 bits */
#define RTLNET_PROTO_REG_STATIC_IP     0x01Cu   /* RW, reset 192.169.1.220 */
#define RTLNET_PROTO_REG_NETMASK       0x020u   /* RW, reset 255.255.255.0 */
#define RTLNET_PROTO_REG_GATEWAY       0x024u   /* RW, reset 192.169.1.1 */
#define RTLNET_PROTO_REG_EFFECTIVE_IP  0x028u   /* RO lease IP while DHCP is in use, else STATIC_IP */
#define RTLNET_PROTO_REG_EFFECTIVE_MASK 0x02Cu  /* RO lease mask or NETMASK */
#define RTLNET_PROTO_REG_EFFECTIVE_GW  0x030u   /* RO lease router or GATEWAY */
#define RTLNET_PROTO_REG_INGRESS_FRAMES   0x040u   /* RO frames stored in the ingress queue */
#define RTLNET_PROTO_REG_INGRESS_FILTERED 0x044u   /* RO frames discarded by the destination filter */
#define RTLNET_PROTO_REG_INGRESS_DROPPED  0x048u   /* RO frames dropped: queue full or over one slot */
#define RTLNET_PROTO_REG_EGRESS_FRAMES    0x04Cu   /* RO frames handed to the MAC */

/* Register values. */
#define RTLNET_PROTO_ID_VALUE          0x50524F54u   /* "PROT" */
#define RTLNET_PROTO_VERSION_VALUE     0x10222026u

/* CAPS fields. */
#define RTLNET_PROTO_CAPS_LEAF_PRESENT_MASK  0x0000001Fu   /* bit i: leaf index i is built */
#define RTLNET_PROTO_CAPS_INGRESS_KB_SHIFT   8u
#define RTLNET_PROTO_CAPS_EGRESS_KB_SHIFT    16u
#define RTLNET_PROTO_CAPS_SOCKETS_SHIFT      24u
#define RTLNET_PROTO_CAPS_BYTE_MASK          0xFFu

/* CTRL fields. Reset: FILTER_ENABLE 1, LEAF_ENABLE = the present leaves. */
#define RTLNET_PROTO_CTRL_FILTER_ENABLE      0x00000001u   /* 0 = promiscuous */
#define RTLNET_PROTO_CTRL_LEAF_ENABLE_SHIFT  8u            /* bits 12..8, bit 8 + i = leaf index i */
#define RTLNET_PROTO_CTRL_LEAF_ENABLE_MASK   0x00001F00u
#define RTLNET_PROTO_CTRL_CNT_CLEAR          0x00010000u   /* self-clearing pulse, reads 0 */

/* STATUS fields. */
#define RTLNET_PROTO_STATUS_IP_FROM_DHCP     0x00000001u   /* the effective address is a DHCP lease */
#define RTLNET_PROTO_STATUS_IP_VALID         0x00000002u   /* the effective IP is not 0.0.0.0 */
#define RTLNET_PROTO_STATUS_LEASE_VALID      0x00000004u   /* the DHCP leaf holds a lease */
#define RTLNET_PROTO_STATUS_LEAF_BUSY_SHIFT  8u            /* bits 12..8, busy of leaf index i */
#define RTLNET_PROTO_STATUS_LEAF_BUSY_MASK   0x00001F00u
#define RTLNET_PROTO_STATUS_INGRESS_PENDING  0x00010000u   /* a frame waits in the ingress queue */
#define RTLNET_PROTO_STATUS_EGRESS_FULL      0x00020000u   /* the egress queue has no free slot */
#define RTLNET_PROTO_STATUS_DELIVERING       0x00040000u   /* a frame is being delivered to the leaves */
#define RTLNET_PROTO_STATUS_ARBITER_ACTIVE   0x00080000u   /* a leaf holds the transmit grant */

/* MAC register packing. */
#define RTLNET_PROTO_MAC_BYTES               6u
#define RTLNET_PROTO_MAC_HI_MASK             0x0000FFFFu

/* Status codes. */
#define RTLNET_PROTO_OK                      0
#define RTLNET_PROTO_ERROR                   (-1)

/* The four frame counters, read in one call. Identity, once traffic has
 * stopped: frames offered by the MAC = ingress_filtered + ingress_frames +
 * ingress_dropped. */
typedef struct {
    uint32_t ingress_frames;
    uint32_t ingress_filtered;
    uint32_t ingress_dropped;
    uint32_t egress_frames;
} rtlnet_eth_protocol_counters_t;

int rtlnet_eth_protocol_probe(uintptr_t base);
uint32_t rtlnet_eth_protocol_get_caps(uintptr_t base);
uint32_t rtlnet_eth_protocol_get_leaves_present(uintptr_t base);
uint32_t rtlnet_eth_protocol_get_status(uintptr_t base);

void rtlnet_eth_protocol_set_mac(uintptr_t base, const uint8_t mac[RTLNET_PROTO_MAC_BYTES]);
void rtlnet_eth_protocol_get_mac(uintptr_t base, uint8_t mac[RTLNET_PROTO_MAC_BYTES]);
void rtlnet_eth_protocol_set_static_ip(uintptr_t base, uint32_t ip);
uint32_t rtlnet_eth_protocol_get_static_ip(uintptr_t base);
void rtlnet_eth_protocol_set_netmask(uintptr_t base, uint32_t mask);
uint32_t rtlnet_eth_protocol_get_netmask(uintptr_t base);
void rtlnet_eth_protocol_set_gateway(uintptr_t base, uint32_t gateway);
uint32_t rtlnet_eth_protocol_get_gateway(uintptr_t base);
uint32_t rtlnet_eth_protocol_get_effective_ip(uintptr_t base);
uint32_t rtlnet_eth_protocol_get_effective_mask(uintptr_t base);
uint32_t rtlnet_eth_protocol_get_effective_gateway(uintptr_t base);
int rtlnet_eth_protocol_ip_from_dhcp(uintptr_t base);

void rtlnet_eth_protocol_set_filter_enable(uintptr_t base, int enable);
int rtlnet_eth_protocol_get_filter_enable(uintptr_t base);
int rtlnet_eth_protocol_set_leaf_enables(uintptr_t base, uint32_t mask);
uint32_t rtlnet_eth_protocol_get_leaf_enables(uintptr_t base);

void rtlnet_eth_protocol_read_counters(uintptr_t base, rtlnet_eth_protocol_counters_t *counters);
void rtlnet_eth_protocol_clear_counters(uintptr_t base);

#endif /* RTLNET_ETH_PROTOCOL_H */
