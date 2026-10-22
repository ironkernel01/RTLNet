/*
 * rtlnet_eth_protocol.c -- RTLNet protocol wrapper driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches the rtlnet_eth_protocol wrapper registers
 * (window 0x0000 of the protocol sub-map). Every access goes through
 * rtlnet_mmio.h with the base address the platform passes in. Offsets and
 * bits come from rtlnet_eth_protocol.h. No function waits on hardware.
 */
#include "rtlnet_eth_protocol.h"
#include "rtlnet_mmio.h"

/*
 * rtlnet_eth_protocol_probe -- check that the wrapper answers at base
 * Steps:
 *   1. Read ID and VERSION.
 *   2. Compare them with the values this driver is written for.
 * Returns: RTLNET_PROTO_OK when both match, RTLNET_PROTO_ERROR otherwise.
 */
int rtlnet_eth_protocol_probe(uintptr_t base)
{
    if (rtlnet_reg_read32(base, RTLNET_PROTO_REG_ID) != RTLNET_PROTO_ID_VALUE) {
        return RTLNET_PROTO_ERROR;
    }
    if (rtlnet_reg_read32(base, RTLNET_PROTO_REG_VERSION) != RTLNET_PROTO_VERSION_VALUE) {
        return RTLNET_PROTO_ERROR;
    }
    return RTLNET_PROTO_OK;
}

/*
 * rtlnet_eth_protocol_get_caps -- read the CAPS word
 * Steps:
 *   1. Read CAPS.
 * Returns: CAPS (leaf-present bits, queue sizes in KB, socket count).
 */
uint32_t rtlnet_eth_protocol_get_caps(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_PROTO_REG_CAPS);
}

/*
 * rtlnet_eth_protocol_get_leaves_present -- leaves built into this wrapper
 * Steps:
 *   1. Read CAPS and keep the leaf-present field.
 * Returns: bit i set when leaf index i (RTLNET_PROTO_LEAF_*) is built.
 */
uint32_t rtlnet_eth_protocol_get_leaves_present(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_PROTO_REG_CAPS) & RTLNET_PROTO_CAPS_LEAF_PRESENT_MASK;
}

/*
 * rtlnet_eth_protocol_get_status -- read the STATUS word
 * Steps:
 *   1. Read STATUS.
 * Returns: STATUS (decode with RTLNET_PROTO_STATUS_*).
 */
uint32_t rtlnet_eth_protocol_get_status(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_PROTO_REG_STATUS);
}

/*
 * rtlnet_eth_protocol_set_mac -- program the node MAC address
 * Steps:
 *   1. Write octets 0-1 to LOCAL_MAC_HI (staged in the wrapper).
 *   2. Write octets 2-5 to LOCAL_MAC_LO; this write changes all 48 bits at
 *      once, so the filter and the leaves never use a half-written MAC.
 * Returns: nothing.
 */
void rtlnet_eth_protocol_set_mac(uintptr_t base, const uint8_t mac[RTLNET_PROTO_MAC_BYTES])
{
    uint32_t hi = ((uint32_t)mac[0] << 8) | (uint32_t)mac[1];
    uint32_t lo = ((uint32_t)mac[2] << 24) | ((uint32_t)mac[3] << 16) | ((uint32_t)mac[4] << 8) |
                  (uint32_t)mac[5];

    rtlnet_reg_write32(base, RTLNET_PROTO_REG_LOCAL_MAC_HI, hi);
    rtlnet_reg_write32(base, RTLNET_PROTO_REG_LOCAL_MAC_LO, lo);
}

/*
 * rtlnet_eth_protocol_get_mac -- read the node MAC address in use
 * Steps:
 *   1. Read LOCAL_MAC_HI and LOCAL_MAC_LO.
 *   2. Unpack them into wire order.
 * Returns: nothing; mac[0..5] holds the address.
 */
void rtlnet_eth_protocol_get_mac(uintptr_t base, uint8_t mac[RTLNET_PROTO_MAC_BYTES])
{
    uint32_t hi = rtlnet_reg_read32(base, RTLNET_PROTO_REG_LOCAL_MAC_HI) & RTLNET_PROTO_MAC_HI_MASK;
    uint32_t lo = rtlnet_reg_read32(base, RTLNET_PROTO_REG_LOCAL_MAC_LO);

    mac[0] = (uint8_t)(hi >> 8);
    mac[1] = (uint8_t)hi;
    mac[2] = (uint8_t)(lo >> 24);
    mac[3] = (uint8_t)(lo >> 16);
    mac[4] = (uint8_t)(lo >> 8);
    mac[5] = (uint8_t)lo;
}

/*
 * rtlnet_eth_protocol_set_static_ip -- program the static IPv4 address
 * Steps:
 *   1. Write STATIC_IP. It becomes the effective address unless a DHCP lease
 *      is in use.
 * Returns: nothing.
 */
void rtlnet_eth_protocol_set_static_ip(uintptr_t base, uint32_t ip)
{
    rtlnet_reg_write32(base, RTLNET_PROTO_REG_STATIC_IP, ip);
}

/*
 * rtlnet_eth_protocol_get_static_ip -- read the static IPv4 address
 * Steps:
 *   1. Read STATIC_IP.
 * Returns: the static address, number order.
 */
uint32_t rtlnet_eth_protocol_get_static_ip(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_PROTO_REG_STATIC_IP);
}

/*
 * rtlnet_eth_protocol_set_netmask -- program the static netmask
 * Steps:
 *   1. Write NETMASK.
 * Returns: nothing.
 */
void rtlnet_eth_protocol_set_netmask(uintptr_t base, uint32_t mask)
{
    rtlnet_reg_write32(base, RTLNET_PROTO_REG_NETMASK, mask);
}

/*
 * rtlnet_eth_protocol_get_netmask -- read the static netmask
 * Steps:
 *   1. Read NETMASK.
 * Returns: the static netmask.
 */
uint32_t rtlnet_eth_protocol_get_netmask(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_PROTO_REG_NETMASK);
}

/*
 * rtlnet_eth_protocol_set_gateway -- program the static gateway
 * Steps:
 *   1. Write GATEWAY.
 * Returns: nothing.
 */
void rtlnet_eth_protocol_set_gateway(uintptr_t base, uint32_t gateway)
{
    rtlnet_reg_write32(base, RTLNET_PROTO_REG_GATEWAY, gateway);
}

/*
 * rtlnet_eth_protocol_get_gateway -- read the static gateway
 * Steps:
 *   1. Read GATEWAY.
 * Returns: the static gateway.
 */
uint32_t rtlnet_eth_protocol_get_gateway(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_PROTO_REG_GATEWAY);
}

/*
 * rtlnet_eth_protocol_get_effective_ip -- the IPv4 address the leaves use
 * Steps:
 *   1. Read EFFECTIVE_IP.
 * Returns: the DHCP lease address while one is in use, else STATIC_IP.
 */
uint32_t rtlnet_eth_protocol_get_effective_ip(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_PROTO_REG_EFFECTIVE_IP);
}

/*
 * rtlnet_eth_protocol_get_effective_mask -- the netmask the leaves use
 * Steps:
 *   1. Read EFFECTIVE_MASK.
 * Returns: the lease mask while DHCP is in use, else NETMASK.
 */
uint32_t rtlnet_eth_protocol_get_effective_mask(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_PROTO_REG_EFFECTIVE_MASK);
}

/*
 * rtlnet_eth_protocol_get_effective_gateway -- the gateway the leaves use
 * Steps:
 *   1. Read EFFECTIVE_GATEWAY.
 * Returns: the lease router while DHCP is in use, else GATEWAY.
 */
uint32_t rtlnet_eth_protocol_get_effective_gateway(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_PROTO_REG_EFFECTIVE_GW);
}

/*
 * rtlnet_eth_protocol_ip_from_dhcp -- is the effective address a lease
 * Steps:
 *   1. Read STATUS and test IP_FROM_DHCP.
 * Returns: 1 when the effective address comes from a DHCP lease, 0 otherwise.
 */
int rtlnet_eth_protocol_ip_from_dhcp(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_PROTO_REG_STATUS) & RTLNET_PROTO_STATUS_IP_FROM_DHCP) != 0u;
}

/*
 * rtlnet_eth_protocol_set_filter_enable -- destination filter or promiscuous
 * Steps:
 *   1. Read CTRL (CNT_CLEAR reads 0, so it is never re-triggered).
 *   2. Set or clear FILTER_ENABLE and write CTRL back.
 * Returns: nothing.
 */
void rtlnet_eth_protocol_set_filter_enable(uintptr_t base, int enable)
{
    uint32_t ctrl = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CTRL) & ~RTLNET_PROTO_CTRL_CNT_CLEAR;

    if (enable) {
        ctrl |= RTLNET_PROTO_CTRL_FILTER_ENABLE;
    } else {
        ctrl &= ~RTLNET_PROTO_CTRL_FILTER_ENABLE;
    }
    rtlnet_reg_write32(base, RTLNET_PROTO_REG_CTRL, ctrl);
}

/*
 * rtlnet_eth_protocol_get_filter_enable -- read the filter mode
 * Steps:
 *   1. Read CTRL and test FILTER_ENABLE.
 * Returns: 1 when only local-MAC and broadcast frames are accepted, 0 when
 *          promiscuous.
 */
int rtlnet_eth_protocol_get_filter_enable(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_PROTO_REG_CTRL) & RTLNET_PROTO_CTRL_FILTER_ENABLE) != 0u;
}

/*
 * rtlnet_eth_protocol_set_leaf_enables -- enable or disable leaves
 * Steps:
 *   1. Reject a mask that names a leaf index above RTLNET_PROTO_LEAF_COUNT or
 *      a leaf that is not built (CAPS.LEAF_PRESENT); nothing is written.
 *   2. Read CTRL, replace the LEAF_ENABLE field, write CTRL back.
 * Returns: RTLNET_PROTO_OK, or RTLNET_PROTO_ERROR when the mask was rejected.
 */
int rtlnet_eth_protocol_set_leaf_enables(uintptr_t base, uint32_t mask)
{
    uint32_t present = rtlnet_eth_protocol_get_leaves_present(base);
    uint32_t ctrl;

    if ((mask & ~present) != 0u) {
        return RTLNET_PROTO_ERROR;
    }
    ctrl = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CTRL) & ~RTLNET_PROTO_CTRL_CNT_CLEAR;
    ctrl &= ~RTLNET_PROTO_CTRL_LEAF_ENABLE_MASK;
    ctrl |= (mask << RTLNET_PROTO_CTRL_LEAF_ENABLE_SHIFT) & RTLNET_PROTO_CTRL_LEAF_ENABLE_MASK;
    rtlnet_reg_write32(base, RTLNET_PROTO_REG_CTRL, ctrl);
    return RTLNET_PROTO_OK;
}

/*
 * rtlnet_eth_protocol_get_leaf_enables -- read the leaf enable mask
 * Steps:
 *   1. Read CTRL and extract LEAF_ENABLE.
 * Returns: bit i set when leaf index i is enabled.
 */
uint32_t rtlnet_eth_protocol_get_leaf_enables(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_PROTO_REG_CTRL) & RTLNET_PROTO_CTRL_LEAF_ENABLE_MASK) >>
           RTLNET_PROTO_CTRL_LEAF_ENABLE_SHIFT;
}

/*
 * rtlnet_eth_protocol_read_counters -- read the four frame counters
 * Steps:
 *   1. Read INGRESS_FRAMES, INGRESS_FILTERED, INGRESS_DROPPED, EGRESS_FRAMES
 *      into *counters (four separate reads: a frame arriving between them is
 *      seen by the later reads only).
 * Returns: nothing.
 */
void rtlnet_eth_protocol_read_counters(uintptr_t base, rtlnet_eth_protocol_counters_t *counters)
{
    counters->ingress_frames   = rtlnet_reg_read32(base, RTLNET_PROTO_REG_INGRESS_FRAMES);
    counters->ingress_filtered = rtlnet_reg_read32(base, RTLNET_PROTO_REG_INGRESS_FILTERED);
    counters->ingress_dropped  = rtlnet_reg_read32(base, RTLNET_PROTO_REG_INGRESS_DROPPED);
    counters->egress_frames    = rtlnet_reg_read32(base, RTLNET_PROTO_REG_EGRESS_FRAMES);
}

/*
 * rtlnet_eth_protocol_clear_counters -- restart every wrapper counter from 0
 * Steps:
 *   1. Read CTRL and write it back with CNT_CLEAR set (a self-clearing
 *      pulse; FILTER_ENABLE, CPU_PATH_ENABLE and LEAF_ENABLE are kept). The
 *      ingress, egress, DELIVERED and CPU counters restart together.
 * Returns: nothing.
 */
void rtlnet_eth_protocol_clear_counters(uintptr_t base)
{
    uint32_t ctrl = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CTRL);

    rtlnet_reg_write32(base, RTLNET_PROTO_REG_CTRL, ctrl | RTLNET_PROTO_CTRL_CNT_CLEAR);
}

/*
 * rtlnet_eth_protocol_cpu_path_present -- is the CPU network path built
 * Steps:
 *   1. Read CAPS and test CPU_PATH_PRESENT.
 * Returns: 1 when the wrapper has the CPU network path, 0 otherwise.
 */
int rtlnet_eth_protocol_cpu_path_present(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_PROTO_REG_CAPS) & RTLNET_PROTO_CAPS_CPU_PATH_PRESENT) != 0u;
}

/*
 * rtlnet_eth_protocol_set_cpu_path_enable -- turn the CPU network path on or off
 * Steps:
 *   1. Reject an enable when the path is not built (CAPS); nothing is written.
 *   2. Read CTRL (CNT_CLEAR reads 0), set or clear CPU_PATH_ENABLE, write CTRL
 *      back. Off: no frame is copied to the CPU and CPU frames are discarded
 *      (the change applies from the next frame boundary on each side).
 * Returns: RTLNET_PROTO_OK, or RTLNET_PROTO_ERROR when enabling an absent path.
 */
int rtlnet_eth_protocol_set_cpu_path_enable(uintptr_t base, int enable)
{
    uint32_t ctrl;

    if (enable && !rtlnet_eth_protocol_cpu_path_present(base)) {
        return RTLNET_PROTO_ERROR;
    }
    ctrl = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CTRL) & ~RTLNET_PROTO_CTRL_CNT_CLEAR;
    if (enable) {
        ctrl |= RTLNET_PROTO_CTRL_CPU_PATH_ENABLE;
    } else {
        ctrl &= ~RTLNET_PROTO_CTRL_CPU_PATH_ENABLE;
    }
    rtlnet_reg_write32(base, RTLNET_PROTO_REG_CTRL, ctrl);
    return RTLNET_PROTO_OK;
}

/*
 * rtlnet_eth_protocol_get_cpu_path_enable -- read the CPU network path enable
 * Steps:
 *   1. Read CTRL and test CPU_PATH_ENABLE (always 0 when the path is not built).
 * Returns: 1 when enabled, 0 otherwise.
 */
int rtlnet_eth_protocol_get_cpu_path_enable(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_PROTO_REG_CTRL) & RTLNET_PROTO_CTRL_CPU_PATH_ENABLE) != 0u;
}

/*
 * rtlnet_eth_protocol_get_cpu_rx_fifo_kb -- size of the CPU receive queue
 * Steps:
 *   1. Read CPU_CAPS and extract the receive size.
 * Returns: CPU_RX_FIFO_KB, 0 without the CPU path.
 */
uint32_t rtlnet_eth_protocol_get_cpu_rx_fifo_kb(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_PROTO_REG_CPU_CAPS) >> RTLNET_PROTO_CPU_CAPS_RX_KB_SHIFT) &
           RTLNET_PROTO_CAPS_BYTE_MASK;
}

/*
 * rtlnet_eth_protocol_get_cpu_tx_fifo_kb -- size of the CPU transmit queue
 * Steps:
 *   1. Read CPU_CAPS and extract the transmit size.
 * Returns: CPU_TX_FIFO_KB, 0 without the CPU path.
 */
uint32_t rtlnet_eth_protocol_get_cpu_tx_fifo_kb(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_PROTO_REG_CPU_CAPS) >> RTLNET_PROTO_CPU_CAPS_TX_KB_SHIFT) &
           RTLNET_PROTO_CAPS_BYTE_MASK;
}

/*
 * rtlnet_eth_protocol_read_cpu_counters -- read the CPU network path counters
 * Steps:
 *   1. Read DELIVERED_FRAMES, CPU_RX_FRAMES, CPU_RX_CLAIMED, CPU_RX_DROPPED,
 *      CPU_TX_FRAMES, CPU_TX_DISCARDED, CPU_TX_REJECTED into *counters
 *      (separate reads: a frame arriving between them is seen by the later
 *      reads only).
 * Returns: nothing.
 */
void rtlnet_eth_protocol_read_cpu_counters(uintptr_t base, rtlnet_eth_protocol_cpu_counters_t *counters)
{
    counters->delivered_frames = rtlnet_reg_read32(base, RTLNET_PROTO_REG_DELIVERED_FRAMES);
    counters->cpu_rx_frames    = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CPU_RX_FRAMES);
    counters->cpu_rx_claimed   = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CPU_RX_CLAIMED);
    counters->cpu_rx_dropped   = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CPU_RX_DROPPED);
    counters->cpu_tx_frames    = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CPU_TX_FRAMES);
    counters->cpu_tx_discarded = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CPU_TX_DISCARDED);
    counters->cpu_tx_rejected  = rtlnet_reg_read32(base, RTLNET_PROTO_REG_CPU_TX_REJECTED);
}
