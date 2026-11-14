/*
 * rtlnet_phy.c -- PHY driver selection by MDIO ID, RTL8211E and generic Clause 22 drivers
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_phy.h for the contract. Context: main loop only.
 */
#include "rtlnet_phy.h"

#include <stddef.h>   /* NULL */

#include "rtlnet_fmt.h"

/* Clause 22 registers and bits used by the generic driver (IEEE 802.3 clause 22, 28 and 40). */
#define GEN_BMSR_EXT_STATUS     0x0100u   /* BMSR 1.8: extended status register 15 present */
#define GEN_REG_EXT_STATUS      15u
#define GEN_EXT_1000T_FULL      0x2000u   /* register 15 bit 13: 1000BASE-T full duplex */
#define GEN_ANAR_FULL_MASK      (RTLNET_PHY_ANAR_100F | RTLNET_PHY_ANAR_10F)
#define GEN_ANAR_HALF_MASK      (RTLNET_PHY_ANAR_100H | RTLNET_PHY_ANAR_10H)
#define PHY_ID1_NONE_0          0x0000u   /* no PHY drives the line: all ones, or all zeros */
#define PHY_ID1_NONE_1          0xFFFFu
#define PHY_ID_SHIFT            16u
#define PHY_ID_REV_MASK         0xFFFFFFF0u   /* PHYID2 bits 3:0 are the revision */
#define PHY_ADDR_COUNT          32u

static rtlnet_phy_driver_t g_generic;     /* filled by generic_driver(); the fallback of rtlnet_phy_select */

/*
 * rmw -- read-modify-write of a Clause 22 register: (value & ~clear) | set.
 * Returns: RTLNET_PHY_OK or a bus error.
 */
static int rmw(const rtlnet_mdio_t *mdio, uint8_t reg, uint16_t clear, uint16_t set)
{
    uint16_t v;
    int rc = rtlnet_mdio_read(mdio, reg, &v);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    v = (uint16_t)((v & (uint16_t)~clear) | set);
    return rtlnet_mdio_write(mdio, reg, v);
}

/* ------------------------------------------------------------------------- */
/* RTL8211E driver (cores/rtlnet_mdio/driver/rtlnet_phy_rtl8211e.c)           */
/* ------------------------------------------------------------------------- */

/*
 * rtl8211e_init -- RTL8211E bring-up.
 * Steps:
 *   1. RGMII RX clock delay on (page 0xA4 register 28), read back.
 *   2. LEDs: LINK steady, ACT blinking on TX/RX, USER off.
 *   3. EEE advertisement off (EEE makes the RJ45 LEDs blink, a 400 ms / 2 s pattern).
 * Returns: 0; -1, -2, -3 for the first failing step (summary holds the message).
 */
static int rtl8211e_init(const rtlnet_mdio_t *mdio, char summary[RTLNET_PHY_SUMMARY_LEN])
{
    uint16_t before = 0u;
    uint16_t after = 0u;
    if (rtlnet_phy_rtl8211e_enable_rx_delay(mdio, &before, &after) != RTLNET_PHY_OK) {
        (void)fmt_snprintf(summary, RTLNET_PHY_SUMMARY_LEN, "RX delay write not read back (0x%04X -> 0x%04X)",
                           (unsigned)before, (unsigned)after);
        return -1;
    }
    if (rtlnet_phy_rtl8211e_leds_default(mdio) != RTLNET_PHY_OK) {
        (void)fmt_snprintf(summary, RTLNET_PHY_SUMMARY_LEN, "LED configuration not read back");
        return -2;
    }
    if (rtlnet_phy_rtl8211e_set_eee_advert(mdio, 0) != RTLNET_PHY_OK) {
        (void)fmt_snprintf(summary, RTLNET_PHY_SUMMARY_LEN, "EEE advertisement not cleared");
        return -3;
    }
    (void)fmt_snprintf(summary, RTLNET_PHY_SUMMARY_LEN,
                       "RX delay 0x%04X -> 0x%04X, LEDs LINK steady, ACT blink, USER off; EEE off",
                       (unsigned)before, (unsigned)after);
    return 0;
}

/*
 * rtl8211e_show_details -- extra lines of "show phy": RX delay, LED registers, EEE advertisement.
 * Returns: nothing.
 */
static void rtl8211e_show_details(const rtlnet_mdio_t *mdio)
{
    uint16_t lcr = 0u;
    uint16_t lacr = 0u;
    uint16_t eee = 0u;
    int lrc = rtlnet_phy_rtl8211e_get_leds(mdio, &lcr, &lacr);
    int erc = rtlnet_phy_rtl8211e_get_eee_advert(mdio, &eee);
    if (lrc == RTLNET_PHY_OK) {
        fmt_printf("  LEDs            : LCR 0x%04X LACR 0x%04X (ext page 0x2C; default 0x0070 / 0x0010: LINK steady, "
                   "ACT blink, USER off)\n", (unsigned)lcr, (unsigned)lacr);
    } else {
        fmt_printf("  LEDs            : read failed (%d)\n", lrc);
    }
    if (erc == RTLNET_PHY_OK) {
        fmt_printf("  EEE advertised  : MMD 7.60 = 0x%04X (%s)\n", (unsigned)eee, (eee == 0u) ? "off" : "on");
    } else {
        fmt_printf("  EEE advertised  : read failed (%d)\n", erc);
    }
}

/* ------------------------------------------------------------------------- */
/* DP83848 driver (cores/rtlnet_mdio/driver/rtlnet_phy_dp83848.c), 10/100 only */
/* ------------------------------------------------------------------------- */

/*
 * dp83848_init -- DP83848 bring-up (LED configuration).
 * Returns: 0, or -1 with the message in summary.
 */
static int dp83848_init(const rtlnet_mdio_t *mdio, char summary[RTLNET_PHY_SUMMARY_LEN])
{
    if (rtlnet_phy_dp83848_init(mdio) != RTLNET_PHY_OK) {
        (void)fmt_snprintf(summary, RTLNET_PHY_SUMMARY_LEN, "DP83848 initialization failed");
        return -1;
    }
    (void)fmt_snprintf(summary, RTLNET_PHY_SUMMARY_LEN, "10/100 full duplex, LEDs default");
    return 0;
}

/* ------------------------------------------------------------------------- */
/* Generic Clause 22 driver                                                  */
/* ------------------------------------------------------------------------- */

/*
 * gen_init -- generic bring-up: nothing to configure beyond the advertisement.
 * Returns: 0.
 */
static int gen_init(const rtlnet_mdio_t *mdio, char summary[RTLNET_PHY_SUMMARY_LEN])
{
    (void)mdio;
    (void)fmt_snprintf(summary, RTLNET_PHY_SUMMARY_LEN, "generic Clause 22 driver (no driver for this PHY ID yet)");
    return 0;
}

/*
 * gen_gigabit -- whether the PHY offers 1000BASE-T full duplex (BMSR extended status, register 15 bit 13).
 * Returns: 1 gigabit-capable, 0 not, a bus error as a negative value.
 */
static int gen_gigabit(const rtlnet_mdio_t *mdio)
{
    uint16_t bmsr;
    uint16_t ext;
    int rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_BMSR, &bmsr);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    if ((bmsr & GEN_BMSR_EXT_STATUS) == 0u) {
        return 0;
    }
    rc = rtlnet_mdio_read(mdio, GEN_REG_EXT_STATUS, &ext);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    return ((ext & GEN_EXT_1000T_FULL) != 0u) ? 1 : 0;
}

/*
 * gen_advertise_set -- ANAR (and GBCR on a gigabit PHY) from the full-duplex modes of the mask; half duplex never.
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_ARG for a mask without a full-duplex mode; a bus error.
 */
static int gen_advertise_set(const rtlnet_mdio_t *mdio, uint32_t adv_mask)
{
    uint16_t anar = 0u;
    int giga;
    int rc;
    if ((adv_mask & RTLNET_PHY_ADV_FULL) == 0u || (adv_mask & ~RTLNET_PHY_ADV_ALL) != 0u) {
        return RTLNET_PHY_ERR_ARG;
    }
    anar |= (adv_mask & RTLNET_PHY_ADV_10F) ? RTLNET_PHY_ANAR_10F : 0u;
    anar |= (adv_mask & RTLNET_PHY_ADV_100F) ? RTLNET_PHY_ANAR_100F : 0u;
    rc = rmw(mdio, RTLNET_PHY_REG_ANAR, RTLNET_PHY_ANAR_TECH_MASK, anar);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    giga = gen_gigabit(mdio);
    if (giga < 0) {
        return giga;
    }
    if (giga != 0) {
        return rmw(mdio, RTLNET_PHY_REG_GBCR, RTLNET_PHY_GBCR_TECH_MASK,
                   (adv_mask & RTLNET_PHY_ADV_1000F) ? RTLNET_PHY_GBCR_1000F : 0u);
    }
    return RTLNET_PHY_OK;
}

/*
 * gen_advertise_get -- advertised abilities from ANAR and, on a gigabit PHY, GBCR.
 * Returns: RTLNET_PHY_OK or a bus error.
 */
static int gen_advertise_get(const rtlnet_mdio_t *mdio, uint32_t *adv_mask)
{
    uint16_t anar;
    uint16_t gbcr = 0u;
    uint32_t m = 0u;
    int giga;
    int rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_ANAR, &anar);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    giga = gen_gigabit(mdio);
    if (giga < 0) {
        return giga;
    }
    if (giga != 0) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_GBCR, &gbcr);
        if (rc != RTLNET_MDIO_OK) {
            return rc;
        }
    }
    m |= (anar & RTLNET_PHY_ANAR_10H) ? RTLNET_PHY_ADV_10H : 0u;
    m |= (anar & RTLNET_PHY_ANAR_10F) ? RTLNET_PHY_ADV_10F : 0u;
    m |= (anar & RTLNET_PHY_ANAR_100H) ? RTLNET_PHY_ADV_100H : 0u;
    m |= (anar & RTLNET_PHY_ANAR_100F) ? RTLNET_PHY_ADV_100F : 0u;
    m |= (gbcr & RTLNET_PHY_GBCR_1000H) ? RTLNET_PHY_ADV_1000H : 0u;
    m |= (gbcr & RTLNET_PHY_GBCR_1000F) ? RTLNET_PHY_ADV_1000F : 0u;
    *adv_mask = m;
    return RTLNET_PHY_OK;
}

/*
 * gen_autoneg_restart -- BMCR: auto-negotiation enabled and restarted.
 * Returns: RTLNET_PHY_OK or a bus error.
 */
static int gen_autoneg_restart(const rtlnet_mdio_t *mdio)
{
    return rmw(mdio, RTLNET_PHY_REG_BMCR, 0u, (uint16_t)(RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_RESTART_AN));
}

/*
 * gen_status -- link, speed and duplex of a standard Clause 22 PHY.
 * Steps:
 *   1. BMCR, BMSR twice (link status is latch-low: the second read is the real-time level), ANLPAR; ANAR, GBCR and
 *      GBSR on a gigabit PHY.
 *   2. The partner abilities count only when auto-negotiation is complete.
 *   3. The resolved mode is the highest full-duplex mode both sides advertise (1000F, 100F, 10F); no common
 *      full-duplex mode leaves speed_valid 0, because the MAC is full duplex only.
 * Returns: RTLNET_PHY_OK or a bus error (*st not updated).
 */
static int gen_status(const rtlnet_mdio_t *mdio, rtlnet_phy_status_t *st)
{
    rtlnet_phy_status_t s;
    uint16_t anar = 0u;
    uint16_t gbcr = 0u;
    uint32_t own = 0u;
    uint32_t common;
    int giga;
    int rc;

    s.physr = 0u;
    s.gbsr = 0u;
    rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_BMCR, &s.bmcr);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_BMSR, &s.bmsr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_BMSR, &s.bmsr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_ANAR, &anar);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_ANLPAR, &s.anlpar);
    }
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    giga = gen_gigabit(mdio);
    if (giga < 0) {
        return giga;
    }
    if (giga != 0) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_GBCR, &gbcr);
        if (rc == RTLNET_MDIO_OK) {
            rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_GBSR, &s.gbsr);
        }
        if (rc != RTLNET_MDIO_OK) {
            return rc;
        }
    }

    s.link_up = (s.bmsr & RTLNET_PHY_BMSR_LINK) ? 1u : 0u;
    s.an_enabled = (s.bmcr & RTLNET_PHY_BMCR_ANE) ? 1u : 0u;
    s.an_complete = (s.bmsr & RTLNET_PHY_BMSR_AN_COMPLETE) ? 1u : 0u;
    s.mdi_crossover = 0u;
    s.partner_adv = 0u;
    if (s.an_complete) {
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_10H) ? RTLNET_PHY_ADV_10H : 0u;
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_10F) ? RTLNET_PHY_ADV_10F : 0u;
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_100H) ? RTLNET_PHY_ADV_100H : 0u;
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_100F) ? RTLNET_PHY_ADV_100F : 0u;
        s.partner_adv |= (s.gbsr & RTLNET_PHY_GBSR_LP_1000H) ? RTLNET_PHY_ADV_1000H : 0u;
        s.partner_adv |= (s.gbsr & RTLNET_PHY_GBSR_LP_1000F) ? RTLNET_PHY_ADV_1000F : 0u;
    }
    own |= (anar & RTLNET_PHY_ANAR_10F) ? RTLNET_PHY_ADV_10F : 0u;
    own |= (anar & RTLNET_PHY_ANAR_100F) ? RTLNET_PHY_ADV_100F : 0u;
    own |= (gbcr & RTLNET_PHY_GBCR_1000F) ? RTLNET_PHY_ADV_1000F : 0u;
    common = own & s.partner_adv & RTLNET_PHY_ADV_FULL;
    s.resolved = (s.link_up && s.an_complete && common != 0u) ? 1u : 0u;
    s.full_duplex = (common != 0u) ? 1u : 0u;
    if ((common & RTLNET_PHY_ADV_1000F) != 0u) {
        s.speed = RTLNET_PHY_SPEED_1000;
    } else if ((common & RTLNET_PHY_ADV_100F) != 0u) {
        s.speed = RTLNET_PHY_SPEED_100;
    } else if ((common & RTLNET_PHY_ADV_10F) != 0u) {
        s.speed = RTLNET_PHY_SPEED_10;
    } else {
        s.speed = RTLNET_PHY_SPEED_UNKNOWN;
    }
    s.speed_valid = s.resolved;
    *st = s;
    return RTLNET_PHY_OK;
}

/* ------------------------------------------------------------------------- */
/* Driver table                                                              */
/* ------------------------------------------------------------------------- */

/* One line per PHY: name, ID, ID mask, init, advertise_set, advertise_get, autoneg_restart, status, show_details.
 * ADD A PHY DRIVER HERE (rtlnet_phy.h describes the steps). */
static const rtlnet_phy_driver_t g_drivers[] = {
    { "RTL8211E", ((uint32_t)RTLNET_PHY_RTL8211E_ID1 << PHY_ID_SHIFT) | RTLNET_PHY_RTL8211E_ID2, PHY_ID_REV_MASK, RTLNET_PHY_ADV_FULL,
      rtl8211e_init, rtlnet_phy_rtl8211e_advertise_set, rtlnet_phy_rtl8211e_advertise_get,
      rtlnet_phy_rtl8211e_autoneg_restart, rtlnet_phy_rtl8211e_status, rtl8211e_show_details },
    { "DP83848", ((uint32_t)RTLNET_PHY_DP83848_ID1 << PHY_ID_SHIFT) | RTLNET_PHY_DP83848_ID2,
      ((uint32_t)0xFFFFu << PHY_ID_SHIFT) | RTLNET_PHY_DP83848_ID2_MASK, RTLNET_PHY_DP83848_ADV_FULL,
      dp83848_init, rtlnet_phy_dp83848_advertise_set, rtlnet_phy_dp83848_advertise_get,
      rtlnet_phy_dp83848_autoneg_restart, rtlnet_phy_dp83848_status, NULL },
};

/*
 * generic_driver -- the fallback driver record (filled once).
 * Returns: pointer to the generic Clause 22 driver.
 */
static const rtlnet_phy_driver_t *generic_driver(void)
{
    g_generic.name = "generic Clause 22";
    g_generic.id = 0u;
    g_generic.id_mask = 0u;
    g_generic.abilities = RTLNET_PHY_ADV_FULL;
    g_generic.init = gen_init;
    g_generic.advertise_set = gen_advertise_set;
    g_generic.advertise_get = gen_advertise_get;
    g_generic.autoneg_restart = gen_autoneg_restart;
    g_generic.status = gen_status;
    g_generic.show_details = NULL;
    return &g_generic;
}

/*
 * rtlnet_phy_find -- look for a PHY on the Clause 22 bus.
 * Steps:
 *   1. Read PHYID1 at PHYAD 1..31, then 0; the first address that answers with an ID other than all zeros or all
 *      ones is the PHY.
 *   2. Read PHYID2 there and return the 32-bit ID.
 * Returns: RTLNET_MDIO_OK with *addr and *id set; RTLNET_MDIO_ERR_NO_PHY when no address answers.
 */
int rtlnet_phy_find(const rtlnet_mdio_t *mdio, uint8_t *addr, uint32_t *id)
{
    for (uint32_t n = 1u; n <= PHY_ADDR_COUNT; n++) {
        uint8_t a = (uint8_t)(n % PHY_ADDR_COUNT);
        uint16_t id1 = 0u;
        uint16_t id2 = 0u;
        if (rtlnet_mdio_read_addr(mdio, a, RTLNET_PHY_REG_PHYID1, &id1) != RTLNET_MDIO_OK) {
            continue;
        }
        if (id1 == PHY_ID1_NONE_0 || id1 == PHY_ID1_NONE_1) {
            continue;
        }
        if (rtlnet_mdio_read_addr(mdio, a, RTLNET_PHY_REG_PHYID2, &id2) != RTLNET_MDIO_OK) {
            continue;
        }
        *addr = a;
        *id = ((uint32_t)id1 << PHY_ID_SHIFT) | id2;
        return RTLNET_MDIO_OK;
    }
    return RTLNET_MDIO_ERR_NO_PHY;
}

/*
 * rtlnet_phy_select -- the driver of a PHY ID.
 * Returns: the table entry whose masked ID matches, else the generic Clause 22 driver (never NULL).
 */
const rtlnet_phy_driver_t *rtlnet_phy_select(uint32_t id)
{
    for (unsigned i = 0u; i < sizeof(g_drivers) / sizeof(g_drivers[0]); i++) {
        if ((id & g_drivers[i].id_mask) == (g_drivers[i].id & g_drivers[i].id_mask)) {
            return &g_drivers[i];
        }
    }
    return generic_driver();
}

/*
 * rtlnet_phy_is_generic -- whether a driver is the generic fallback.
 * Returns: 1 for the generic driver, 0 for a table entry.
 */
int rtlnet_phy_is_generic(const rtlnet_phy_driver_t *drv)
{
    return (drv == &g_generic) ? 1 : 0;
}
