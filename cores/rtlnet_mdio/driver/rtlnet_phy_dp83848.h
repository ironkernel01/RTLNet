/*
 * rtlnet_phy_dp83848.h -- IronKernel RTLNet DP83848 Clause 22 PHY layer
 * Copyright (C) 2026 IronKernel. All rights reserved. Source-available.
 * Language: C11. Clocks: none; synchronous calls through rtlnet_mdio.
 * Revision: 11-14-2026
 *   11-14-2026: add 10/100 full-duplex PHY management.
 * Shared rtlnet_phy_status_t, speed, advertisement and error encodings come
 * from the existing PHY API header. No gigabit register is accessed.
 */
#ifndef RTLNET_PHY_DP83848_H
#define RTLNET_PHY_DP83848_H
#include "rtlnet_phy_rtl8211e.h"

#define RTLNET_PHY_DP83848_ADDR_DEFAULT 1u
#define RTLNET_PHY_DP83848_ID1 0x2000u
#define RTLNET_PHY_DP83848_ID2 0x5C90u
#define RTLNET_PHY_DP83848_ID2_MASK 0xFFF0u
#define RTLNET_PHY_DP83848_REG_PHYSTS 0x10u
#define RTLNET_PHY_DP83848_REG_LEDCR 0x18u
#define RTLNET_PHY_DP83848_PHYSTS_LINK 0x0001u
#define RTLNET_PHY_DP83848_PHYSTS_SPEED10 0x0002u
#define RTLNET_PHY_DP83848_PHYSTS_DUPLEX 0x0004u
#define RTLNET_PHY_DP83848_PHYSTS_AN_COMPLETE 0x0010u
#define RTLNET_PHY_DP83848_PHYSTS_MDIX 0x4000u
#define RTLNET_PHY_DP83848_ADV_FULL (RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100F)
#define RTLNET_PHY_DP83848_ANAR_TECH_MASK 0x03E0u /* includes unsupported 100BASE-T4 */
/* LEDCR (0x18, Table 6-23): DRV_SPDLED 5, DRV_LNKLED 4, SPDLED 2, LNKLED 1; bits 3 and 0 must be zero. */
#define RTLNET_PHY_DP83848_LED_MASK 0x0036u

int rtlnet_phy_dp83848_probe(const rtlnet_mdio_t *mdio, uint32_t *id_out);
/* init probes, restricts advertisement to 10F/100F, then restarts AN. */
int rtlnet_phy_dp83848_init(const rtlnet_mdio_t *mdio);
/* Soft reset restores straps/defaults: run init again after reset. */
int rtlnet_phy_dp83848_soft_reset(const rtlnet_mdio_t *mdio);
int rtlnet_phy_dp83848_autoneg_restart(const rtlnet_mdio_t *mdio);
int rtlnet_phy_dp83848_advertise_set(const rtlnet_mdio_t *mdio, uint32_t adv_mask);
int rtlnet_phy_dp83848_advertise_get(const rtlnet_mdio_t *mdio, uint32_t *adv_mask);
/* Only 10/100 full duplex is accepted. */
int rtlnet_phy_dp83848_force(const rtlnet_mdio_t *mdio, uint8_t speed, int full_duplex);
/* physr holds raw PHYSTS, gbsr is zero; speed_valid also requires full duplex. */
int rtlnet_phy_dp83848_status(const rtlnet_mdio_t *mdio, rtlnet_phy_status_t *st);
int rtlnet_phy_dp83848_loopback(const rtlnet_mdio_t *mdio, int enable);
/* dump reads 0..31, including read-clear interrupt/counter registers. */
int rtlnet_phy_dp83848_dump(const rtlnet_mdio_t *mdio, uint16_t regs[RTLNET_PHY_NUM_REGS]);
/* LEDs use LEDCR direct control, with readback; zero selects normal operation. The Arty A7 LEDs sit on the
 * RJ-45 and the interrupt pin is not routed to the FPGA, so there is no interrupt API: registers 0x11/0x12 are
 * reserved in the datasheet (SNLS250E Table 6-7) and are never written. */
int rtlnet_phy_dp83848_set_leds(const rtlnet_mdio_t *mdio, uint16_t ledcr);
int rtlnet_phy_dp83848_get_leds(const rtlnet_mdio_t *mdio, uint16_t *ledcr);
int rtlnet_phy_dp83848_leds_default(const rtlnet_mdio_t *mdio);
#endif
