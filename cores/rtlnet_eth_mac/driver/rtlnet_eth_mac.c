/*
 * rtlnet_eth_mac.c -- RTLNet 10/100/1000 RGMII MAC driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches the rtlnet_eth_mac registers (map in
 * rtlnet_eth_mac.h). Every access goes through rtlnet_mmio.h with the base
 * address passed in by the caller. The driver keeps no state of its own: the
 * CTRL register is the configuration, read back before each change, so
 * several callers in one firmware context see one consistent view.
 *
 * Context: RTLNet firmware runs every driver from one context (no
 * interrupts touch the MAC), so the CTRL read-modify-write sequences are not
 * guarded.
 */
#include "rtlnet_eth_mac.h"

#include <stddef.h>   /* NULL: optional caps argument of probe/init */

/* CTRL bits that hold configuration (CNT_CLEAR is a pulse and never kept). */
#define RTLNET_ETH_MAC_CTRL_CONFIG_MASK  (RTLNET_ETH_MAC_CTRL_RX_EN | RTLNET_ETH_MAC_CTRL_TX_EN | \
                                          RTLNET_ETH_MAC_CTRL_SPEED_MASK | RTLNET_ETH_MAC_CTRL_LINK_UP)

/*
 * ctrl_update -- replace the CTRL bits in mask with value
 * Steps:
 *   1. Read CTRL and keep only its configuration bits.
 *   2. Replace the bits of mask with those of value and write CTRL.
 * Returns: nothing.
 */
static void ctrl_update(uintptr_t base, uint32_t mask, uint32_t value)
{
    uint32_t ctrl = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_CTRL) & RTLNET_ETH_MAC_CTRL_CONFIG_MASK;

    ctrl = (ctrl & ~mask) | (value & mask);
    rtlnet_reg_write32(base, RTLNET_ETH_MAC_REG_CTRL, ctrl);
}

/*
 * rtlnet_eth_mac_speed_code -- speed in Mb/s to the CTRL/STATUS speed code
 * Steps:
 *   1. Map 10, 100 and 1000 to codes 0, 1 and 2.
 * Returns: the code, or 3 (reserved) for any other value.
 */
uint32_t rtlnet_eth_mac_speed_code(uint32_t mbps)
{
    switch (mbps) {
    case 10u:
        return RTLNET_ETH_MAC_SPEED_10;
    case 100u:
        return RTLNET_ETH_MAC_SPEED_100;
    case 1000u:
        return RTLNET_ETH_MAC_SPEED_1000;
    default:
        return 3u;
    }
}

/*
 * rtlnet_eth_mac_speed_mbps -- speed code to Mb/s
 * Steps:
 *   1. Map codes 0, 1, 2 to 10, 100, 1000; the reserved code 3 runs as 1000.
 * Returns: the speed in Mb/s.
 */
uint32_t rtlnet_eth_mac_speed_mbps(uint32_t code)
{
    switch (code & 3u) {
    case RTLNET_ETH_MAC_SPEED_10:
        return 10u;
    case RTLNET_ETH_MAC_SPEED_100:
        return 100u;
    default:
        return 1000u;
    }
}

/*
 * rtlnet_eth_mac_probe -- check the core identity and read its build parameters
 * Steps:
 *   1. Read ID and VERSION; reject anything but "MAC1" / 0x10222026.
 *   2. If caps is not NULL, decode CAPS and RX_IDELAY_TAP into it.
 * Returns: RTLNET_ETH_MAC_OK, or RTLNET_ETH_MAC_ERR_ID when the identity
 *   does not match (wrong base address or another register-map revision).
 */
int rtlnet_eth_mac_probe(uintptr_t base, rtlnet_eth_mac_caps_t *caps)
{
    uint32_t caps_word;

    if (rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_ID) != RTLNET_ETH_MAC_ID_VALUE) {
        return RTLNET_ETH_MAC_ERR_ID;
    }
    if (rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_VERSION) != RTLNET_ETH_MAC_VERSION_VALUE) {
        return RTLNET_ETH_MAC_ERR_ID;
    }
    if (caps != NULL) {
        caps_word = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_CAPS);
        caps->rx_fifo_kb = (caps_word & RTLNET_ETH_MAC_CAPS_RX_FIFO_KB_MASK) >> RTLNET_ETH_MAC_CAPS_RX_FIFO_KB_SHIFT;
        caps->tx_fifo_kb = (caps_word & RTLNET_ETH_MAC_CAPS_TX_FIFO_KB_MASK) >> RTLNET_ETH_MAC_CAPS_TX_FIFO_KB_SHIFT;
        caps->max_frame_bytes = (caps_word & RTLNET_ETH_MAC_CAPS_MAX_FRAME_MASK) >> RTLNET_ETH_MAC_CAPS_MAX_FRAME_SHIFT;
        caps->rx_idelay_tap = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_RX_IDELAY_TAP);
    }
    return RTLNET_ETH_MAC_OK;
}

/*
 * rtlnet_eth_mac_init -- probe the core and put it in its disabled state
 * Steps:
 *   1. Probe ID/VERSION (and CAPS into caps if given).
 *   2. Write CTRL = 0: receive and transmit disabled, link flag clear,
 *      10 Mb/s; then clear the counters.
 * Returns: RTLNET_ETH_MAC_OK, or RTLNET_ETH_MAC_ERR_ID (nothing written).
 */
int rtlnet_eth_mac_init(uintptr_t base, rtlnet_eth_mac_caps_t *caps)
{
    int rc = rtlnet_eth_mac_probe(base, caps);

    if (rc != RTLNET_ETH_MAC_OK) {
        return rc;
    }
    rtlnet_reg_write32(base, RTLNET_ETH_MAC_REG_CTRL, 0u);
    rtlnet_eth_mac_clear_counters(base);
    return RTLNET_ETH_MAC_OK;
}

/*
 * rtlnet_eth_mac_set_speed -- select 10, 100 or 1000 Mb/s
 * Steps:
 *   1. Reject any speed other than 10, 100, 1000 (CTRL untouched).
 *   2. Write CTRL.SPEED, keeping the other configuration bits. A change
 *      resets the receive path until RXC is measured at the new rate.
 * Returns: RTLNET_ETH_MAC_OK, or RTLNET_ETH_MAC_ERR_ARG.
 */
int rtlnet_eth_mac_set_speed(uintptr_t base, uint32_t mbps)
{
    uint32_t code = rtlnet_eth_mac_speed_code(mbps);

    if (code > RTLNET_ETH_MAC_SPEED_1000) {
        return RTLNET_ETH_MAC_ERR_ARG;
    }
    ctrl_update(base, RTLNET_ETH_MAC_CTRL_SPEED_MASK, code << RTLNET_ETH_MAC_CTRL_SPEED_SHIFT);
    return RTLNET_ETH_MAC_OK;
}

/*
 * rtlnet_eth_mac_get_speed -- configured speed (CTRL.SPEED)
 * Steps:
 *   1. Read CTRL and decode SPEED.
 * Returns: 10, 100 or 1000.
 */
uint32_t rtlnet_eth_mac_get_speed(uintptr_t base)
{
    uint32_t ctrl = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_CTRL);

    return rtlnet_eth_mac_speed_mbps((ctrl & RTLNET_ETH_MAC_CTRL_SPEED_MASK) >> RTLNET_ETH_MAC_CTRL_SPEED_SHIFT);
}

/*
 * rtlnet_eth_mac_enable -- set the receive and transmit enables
 * Steps:
 *   1. Write CTRL.RX_EN and CTRL.TX_EN (nonzero = enable), keeping speed and
 *      link flag. With TX_EN = 0 queued frames are discarded, not sent.
 * Returns: nothing.
 */
void rtlnet_eth_mac_enable(uintptr_t base, int rx_enable, int tx_enable)
{
    uint32_t value = 0u;

    if (rx_enable != 0) {
        value |= RTLNET_ETH_MAC_CTRL_RX_EN;
    }
    if (tx_enable != 0) {
        value |= RTLNET_ETH_MAC_CTRL_TX_EN;
    }
    ctrl_update(base, RTLNET_ETH_MAC_CTRL_RX_EN | RTLNET_ETH_MAC_CTRL_TX_EN, value);
}

/*
 * rtlnet_eth_mac_set_link -- set the firmware link flag (stat_link_up)
 * Steps:
 *   1. Write CTRL.LINK_UP (nonzero = up), keeping the other bits.
 * Returns: nothing.
 */
void rtlnet_eth_mac_set_link(uintptr_t base, int link_up)
{
    ctrl_update(base, RTLNET_ETH_MAC_CTRL_LINK_UP, (link_up != 0) ? RTLNET_ETH_MAC_CTRL_LINK_UP : 0u);
}

/*
 * rtlnet_eth_mac_read_status -- decode STATUS and RX_CLK_RATE
 * Steps:
 *   1. Read STATUS and RX_CLK_RATE.
 *   2. Decode every field into status.
 * Returns: nothing.
 */
void rtlnet_eth_mac_read_status(uintptr_t base, rtlnet_eth_mac_status_t *status)
{
    uint32_t st = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_STATUS);

    status->rx_clk_ok = ((st & RTLNET_ETH_MAC_STATUS_RX_CLK_OK) != 0u) ? 1 : 0;
    status->idelay_rdy = ((st & RTLNET_ETH_MAC_STATUS_IDELAY_RDY) != 0u) ? 1 : 0;
    status->rx_in_reset = ((st & RTLNET_ETH_MAC_STATUS_RX_IN_RESET) != 0u) ? 1 : 0;
    status->speed_mbps = rtlnet_eth_mac_speed_mbps((st & RTLNET_ETH_MAC_STATUS_SPEED_MASK) >>
                                                   RTLNET_ETH_MAC_STATUS_SPEED_SHIFT);
    status->inband_link = ((st & RTLNET_ETH_MAC_STATUS_INBAND_LINK) != 0u) ? 1 : 0;
    status->inband_speed_mbps = rtlnet_eth_mac_speed_mbps((st & RTLNET_ETH_MAC_STATUS_INBAND_SPEED_MASK) >>
                                                          RTLNET_ETH_MAC_STATUS_INBAND_SPEED_SHIFT);
    status->inband_full_duplex = ((st & RTLNET_ETH_MAC_STATUS_INBAND_DUPLEX) != 0u) ? 1 : 0;
    status->rx_clk_rate = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_RX_CLK_RATE) & RTLNET_ETH_MAC_RX_CLK_RATE_MASK;
}

/*
 * rtlnet_eth_mac_wait_rx_ready -- wait until the receive path runs
 * Steps:
 *   1. Poll STATUS up to max_polls times (0 selects
 *      RTLNET_ETH_MAC_READY_POLL_MAX) for RX_CLK_OK = 1 and RX_IN_RESET = 0.
 * Returns: RTLNET_ETH_MAC_OK, or RTLNET_ETH_MAC_ERR_TIMEOUT (RXC absent, at
 *   another rate than CTRL.SPEED, RX_EN clear, or the delay controller not
 *   ready).
 */
int rtlnet_eth_mac_wait_rx_ready(uintptr_t base, uint32_t max_polls)
{
    uint32_t polls = (max_polls == 0u) ? RTLNET_ETH_MAC_READY_POLL_MAX : max_polls;
    uint32_t i;
    uint32_t st;

    for (i = 0u; i < polls; i++) {
        st = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_STATUS);
        if (((st & RTLNET_ETH_MAC_STATUS_RX_CLK_OK) != 0u) && ((st & RTLNET_ETH_MAC_STATUS_RX_IN_RESET) == 0u)) {
            return RTLNET_ETH_MAC_OK;
        }
    }
    return RTLNET_ETH_MAC_ERR_TIMEOUT;
}

/*
 * rtlnet_eth_mac_read_counters -- read the four frame counters
 * Steps:
 *   1. Read RX_GOOD, RX_BAD, RX_OVERFLOW and TX_FRAMES (32-bit, wrapping).
 * Returns: nothing.
 */
void rtlnet_eth_mac_read_counters(uintptr_t base, rtlnet_eth_mac_counters_t *counters)
{
    counters->rx_good = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_RX_GOOD);
    counters->rx_bad = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_RX_BAD);
    counters->rx_overflow = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_RX_OVERFLOW);
    counters->tx_frames = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_TX_FRAMES);
}

/*
 * rtlnet_eth_mac_clear_counters -- zero every frame counter
 * Steps:
 *   1. Write CTRL with its configuration unchanged plus CNT_CLEAR (a pulse
 *      in the core; the bit reads back 0).
 * Returns: nothing.
 */
void rtlnet_eth_mac_clear_counters(uintptr_t base)
{
    uint32_t ctrl = rtlnet_reg_read32(base, RTLNET_ETH_MAC_REG_CTRL) & RTLNET_ETH_MAC_CTRL_CONFIG_MASK;

    rtlnet_reg_write32(base, RTLNET_ETH_MAC_REG_CTRL, ctrl | RTLNET_ETH_MAC_CTRL_CNT_CLEAR);
}
