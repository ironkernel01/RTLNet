/*
 * rtlnet_eth_mac.h -- RTLNet 10/100/1000 RGMII MAC driver interface
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the rtlnet_eth_mac register map (offsets,
 * bit positions, field values) and the driver API. rtlnet_eth_mac.c is the
 * only code that touches these registers. The register file
 * cores/rtlnet_eth_mac/hdl/rtlnet_eth_mac_regs.sv mirrors every offset and
 * bit below as a localparam; both files change together in one commit.
 * Drift between them reads the wrong register or writes the wrong bit:
 * firmware would then select a speed the MAC does not run, or report
 * counters from the wrong offset.
 *
 * Register access goes through rtlnet_mmio.h with the base address the
 * platform layer passes in (0x44A0_1000 on the Nexys Video, architecture
 * section 6.1); no driver function hard-codes it. Registers live in axis_clk
 * behind an AXI4-Lite clock crossing, so every access takes a few hundred
 * nanoseconds; counters are exact 32-bit wrapping values.
 *
 * Bring-up order (firmware): read PHYSR over MDIO, set_speed() to the PHY's
 * speed, enable(rx, tx), set_link(1); wait_rx_ready() then reports when the
 * receive path has qualified RXC (the MAC needs the PHY's RX clock delay,
 * enabled by the MDIO driver, to receive correctly).
 *
 * This header holds signatures, register constants and contract prose; the
 * per-function commentary is in rtlnet_eth_mac.c.
 */
#ifndef RTLNET_ETH_MAC_H
#define RTLNET_ETH_MAC_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#include "rtlnet_mmio.h"

/* ---- Identity --------------------------------------------------------- */
#define RTLNET_ETH_MAC_ID_VALUE        0x4D414331u   /* "MAC1" */
#define RTLNET_ETH_MAC_VERSION_VALUE   0x10222026u   /* register map 10-22-2026 */

/* ---- Register offsets (byte offsets in the 4 KiB window) -------------- */
#define RTLNET_ETH_MAC_REG_ID            RTLNET_REG_ID       /* 0x000 RO */
#define RTLNET_ETH_MAC_REG_VERSION       RTLNET_REG_VERSION  /* 0x004 RO */
#define RTLNET_ETH_MAC_REG_CAPS          RTLNET_REG_CAPS     /* 0x008 RO */
#define RTLNET_ETH_MAC_REG_CTRL          0x00Cu              /* RW */
#define RTLNET_ETH_MAC_REG_STATUS        0x010u              /* RO */
#define RTLNET_ETH_MAC_REG_RX_CLK_RATE   0x014u              /* RO */
#define RTLNET_ETH_MAC_REG_RX_IDELAY_TAP 0x018u              /* RO */
#define RTLNET_ETH_MAC_REG_RX_GOOD       0x020u              /* RO counter */
#define RTLNET_ETH_MAC_REG_RX_BAD        0x024u              /* RO counter */
#define RTLNET_ETH_MAC_REG_RX_OVERFLOW   0x028u              /* RO counter */
#define RTLNET_ETH_MAC_REG_TX_FRAMES     0x02Cu              /* RO counter */

/* ---- CAPS fields ------------------------------------------------------- */
#define RTLNET_ETH_MAC_CAPS_RX_FIFO_KB_SHIFT   0u
#define RTLNET_ETH_MAC_CAPS_RX_FIFO_KB_MASK    0x000000FFu
#define RTLNET_ETH_MAC_CAPS_TX_FIFO_KB_SHIFT   8u
#define RTLNET_ETH_MAC_CAPS_TX_FIFO_KB_MASK    0x0000FF00u
#define RTLNET_ETH_MAC_CAPS_MAX_FRAME_SHIFT    16u
#define RTLNET_ETH_MAC_CAPS_MAX_FRAME_MASK     0xFFFF0000u

/* ---- CTRL bits (reset value 0: receive and transmit disabled, 10 Mb/s) --- */
#define RTLNET_ETH_MAC_CTRL_RX_EN        (1u << 0)    /* receive path may leave reset */
#define RTLNET_ETH_MAC_CTRL_TX_EN        (1u << 1)    /* 0: queued frames are discarded */
#define RTLNET_ETH_MAC_CTRL_SPEED_SHIFT  4u
#define RTLNET_ETH_MAC_CTRL_SPEED_MASK   (3u << 4)
#define RTLNET_ETH_MAC_CTRL_LINK_UP      (1u << 8)    /* firmware link flag, drives stat_link_up */
#define RTLNET_ETH_MAC_CTRL_CNT_CLEAR    (1u << 16)   /* write 1: clear the counters; reads 0 */

/* Speed codes (CTRL.SPEED, STATUS.SPEED), the RTL8211E PHYSR 17.15:14 code. */
#define RTLNET_ETH_MAC_SPEED_10          0u
#define RTLNET_ETH_MAC_SPEED_100         1u
#define RTLNET_ETH_MAC_SPEED_1000        2u

/* ---- STATUS bits ------------------------------------------------------- */
#define RTLNET_ETH_MAC_STATUS_RX_CLK_OK     (1u << 0)   /* RXC measured in band for CTRL.SPEED */
#define RTLNET_ETH_MAC_STATUS_IDELAY_RDY    (1u << 1)   /* input delay controller ready */
#define RTLNET_ETH_MAC_STATUS_RX_IN_RESET   (1u << 2)   /* receive path held in reset */
#define RTLNET_ETH_MAC_STATUS_SPEED_SHIFT   4u          /* speed in effect in the MAC clocks */
#define RTLNET_ETH_MAC_STATUS_SPEED_MASK    (3u << 4)
#define RTLNET_ETH_MAC_STATUS_INBAND_LINK   (1u << 8)   /* RGMII in-band status, debug only */
#define RTLNET_ETH_MAC_STATUS_INBAND_SPEED_SHIFT 9u
#define RTLNET_ETH_MAC_STATUS_INBAND_SPEED_MASK  (3u << 9)
#define RTLNET_ETH_MAC_STATUS_INBAND_DUPLEX (1u << 11)

/* ---- RX_CLK_RATE --------------------------------------------------------
 * Transitions of RXC/16 counted in 4096 clk125 cycles (last full window):
 * nominal 512 at 1000 Mb/s, 102 at 100 Mb/s, 10 at 10 Mb/s. */
#define RTLNET_ETH_MAC_RX_CLK_RATE_MASK  0x000003FFu

/* ---- Driver ------------------------------------------------------------ */

/* Bounds of the driver's polling loops (register reads, each a few hundred
 * nanoseconds; the receive qualification takes about 70 us after the PHY
 * clock is stable, two 32.8 us rate windows). */
#define RTLNET_ETH_MAC_READY_POLL_MAX    100000u

/* Return codes. */
#define RTLNET_ETH_MAC_OK                0
#define RTLNET_ETH_MAC_ERR_ID           (-1)
#define RTLNET_ETH_MAC_ERR_ARG          (-2)
#define RTLNET_ETH_MAC_ERR_TIMEOUT      (-3)

typedef struct {
    uint32_t rx_fifo_kb;
    uint32_t tx_fifo_kb;
    uint32_t max_frame_bytes;
    uint32_t rx_idelay_tap;
} rtlnet_eth_mac_caps_t;

typedef struct {
    int      rx_clk_ok;       /* 1: RXC rate in band for the configured speed */
    int      idelay_rdy;      /* 1: input delay controller ready */
    int      rx_in_reset;     /* 1: receive path held in reset */
    uint32_t speed_mbps;      /* speed in effect: 10, 100 or 1000 */
    uint32_t rx_clk_rate;     /* last RX_CLK_RATE window count */
    int      inband_link;     /* RGMII in-band status (debug only) */
    uint32_t inband_speed_mbps;
    int      inband_full_duplex;
} rtlnet_eth_mac_status_t;

typedef struct {
    uint32_t rx_good;
    uint32_t rx_bad;
    uint32_t rx_overflow;
    uint32_t tx_frames;
} rtlnet_eth_mac_counters_t;

int rtlnet_eth_mac_probe(uintptr_t base, rtlnet_eth_mac_caps_t *caps);
int rtlnet_eth_mac_init(uintptr_t base, rtlnet_eth_mac_caps_t *caps);
int rtlnet_eth_mac_set_speed(uintptr_t base, uint32_t mbps);
uint32_t rtlnet_eth_mac_get_speed(uintptr_t base);
void rtlnet_eth_mac_enable(uintptr_t base, int rx_enable, int tx_enable);
void rtlnet_eth_mac_set_link(uintptr_t base, int link_up);
void rtlnet_eth_mac_read_status(uintptr_t base, rtlnet_eth_mac_status_t *status);
int rtlnet_eth_mac_wait_rx_ready(uintptr_t base, uint32_t max_polls);
void rtlnet_eth_mac_read_counters(uintptr_t base, rtlnet_eth_mac_counters_t *counters);
void rtlnet_eth_mac_clear_counters(uintptr_t base);
uint32_t rtlnet_eth_mac_speed_code(uint32_t mbps);
uint32_t rtlnet_eth_mac_speed_mbps(uint32_t code);

#endif /* RTLNET_ETH_MAC_H */
