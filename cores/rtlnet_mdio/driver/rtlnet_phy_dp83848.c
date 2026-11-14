/*
 * rtlnet_phy_dp83848.c -- IronKernel RTLNet DP83848 Clause 22 PHY layer
 * Copyright (C) 2026 IronKernel. All rights reserved. Source-available.
 * Language: C11. Clocks: none; synchronous calls through rtlnet_mdio.
 * Revision: 11-14-2026
 *   11-14-2026: add 10/100 full-duplex PHY management.
 * Shared rtlnet_phy_status_t, speed, advertisement and error encodings come
 * from the existing PHY API header. No gigabit register is accessed.
 */
#include "rtlnet_phy_dp83848.h"
#include <stddef.h>
#define PHY_ID_SHIFT 16u

/*
 * modify -- read-modify-write one Clause 22 register
 * Steps: read the register, clear then set the given bits, write it back.
 * Returns: RTLNET_MDIO_OK or the first bus fault.
 */
static int modify(const rtlnet_mdio_t *mdio, uint8_t reg, uint16_t clear, uint16_t set)
{
    uint16_t v;
    int rc = rtlnet_mdio_read(mdio, reg, &v);

    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    v = (uint16_t)((v & (uint16_t)~clear) | set);
    return rtlnet_mdio_write(mdio, reg, v);
}


/*
 * rtlnet_phy_dp83848_advertise_set -- advertise only supported full-duplex modes
 * Steps: reject empty/unsupported masks; replace ANAR technology bits, keep pause/selector.
 * Returns: RTLNET_PHY_OK, RTLNET_PHY_ERR_ARG or the bus fault.
 */
int rtlnet_phy_dp83848_advertise_set(const rtlnet_mdio_t *mdio, uint32_t adv_mask)
{
    uint16_t anar = 0u;
    if (mdio == NULL || adv_mask == 0u || (adv_mask & ~RTLNET_PHY_DP83848_ADV_FULL) != 0u) {
        return RTLNET_PHY_ERR_ARG;
    }
    anar |= (adv_mask & RTLNET_PHY_ADV_10F) ? RTLNET_PHY_ANAR_10F : 0u;
    anar |= (adv_mask & RTLNET_PHY_ADV_100F) ? RTLNET_PHY_ANAR_100F : 0u;
    return modify(mdio, RTLNET_PHY_REG_ANAR, RTLNET_PHY_DP83848_ANAR_TECH_MASK, anar);
}

/*
 * rtlnet_phy_dp83848_advertise_get -- read the actual ANAR abilities
 * Steps: map all four 10/100 abilities, exposing any strap half-duplex advertisement.
 * Returns: RTLNET_PHY_OK, RTLNET_PHY_ERR_ARG or the bus fault; output changes on success.
 */
int rtlnet_phy_dp83848_advertise_get(const rtlnet_mdio_t *mdio, uint32_t *adv_mask)
{
    uint16_t anar;
    uint32_t mask = 0u;
    int rc;
    if (mdio == NULL || adv_mask == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_ANAR, &anar);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    mask |= (anar & RTLNET_PHY_ANAR_10H) ? RTLNET_PHY_ADV_10H : 0u;
    mask |= (anar & RTLNET_PHY_ANAR_10F) ? RTLNET_PHY_ADV_10F : 0u;
    mask |= (anar & RTLNET_PHY_ANAR_100H) ? RTLNET_PHY_ADV_100H : 0u;
    mask |= (anar & RTLNET_PHY_ANAR_100F) ? RTLNET_PHY_ADV_100F : 0u;
    *adv_mask = mask;
    return RTLNET_PHY_OK;
}

/*
 * rtlnet_phy_dp83848_init -- identify, restrict advertisement and restart AN
 * Steps: stop at the first error; never access a gigabit or RGMII delay register.
 * Returns: RTLNET_PHY_OK or the first identity/bus error.
 */
int rtlnet_phy_dp83848_init(const rtlnet_mdio_t *mdio)
{
    int rc = rtlnet_phy_dp83848_probe(mdio, NULL);
    if (rc == RTLNET_PHY_OK) {
        rc = rtlnet_phy_dp83848_advertise_set(mdio, RTLNET_PHY_DP83848_ADV_FULL);
    }
    if (rc == RTLNET_PHY_OK) {
        rc = rtlnet_phy_dp83848_autoneg_restart(mdio);
    }
    return rc;
}

/*
 * rtlnet_phy_dp83848_status -- decode current link/speed/duplex from PHYSTS
 * Steps: read BMCR, BMSR, PHYSTS and ANLPAR. Qualify speed with link, completed
 *   AN (or forced mode) and full duplex. PHYSTS SPEED10=1 maps to MAC speed 0.
 * Returns: RTLNET_PHY_OK or argument/bus error; output changes only on success.
 */
int rtlnet_phy_dp83848_status(const rtlnet_mdio_t *mdio, rtlnet_phy_status_t *st)
{
    rtlnet_phy_status_t s = {0};
    int rc;
    if (mdio == NULL || st == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_BMCR, &s.bmcr);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_BMSR, &s.bmsr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_DP83848_REG_PHYSTS, &s.physr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_ANLPAR, &s.anlpar);
    }
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    s.link_up = (s.physr & RTLNET_PHY_DP83848_PHYSTS_LINK) ? 1u : 0u;
    s.full_duplex = (s.physr & RTLNET_PHY_DP83848_PHYSTS_DUPLEX) ? 1u : 0u;
    s.speed = (s.physr & RTLNET_PHY_DP83848_PHYSTS_SPEED10) ? RTLNET_PHY_SPEED_10 : RTLNET_PHY_SPEED_100;
    s.an_enabled = (s.bmcr & RTLNET_PHY_BMCR_ANE) ? 1u : 0u;
    s.an_complete = (s.physr & RTLNET_PHY_DP83848_PHYSTS_AN_COMPLETE) ? 1u : 0u;
    s.resolved = (s.link_up && (!s.an_enabled || s.an_complete)) ? 1u : 0u;
    s.speed_valid = (s.resolved && s.full_duplex) ? 1u : 0u;
    s.mdi_crossover = (s.physr & RTLNET_PHY_DP83848_PHYSTS_MDIX) ? 1u : 0u;
    if (s.an_enabled && s.an_complete) {
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_10H) ? RTLNET_PHY_ADV_10H : 0u;
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_10F) ? RTLNET_PHY_ADV_10F : 0u;
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_100H) ? RTLNET_PHY_ADV_100H : 0u;
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_100F) ? RTLNET_PHY_ADV_100F : 0u;
    }
    *st = s;
    return RTLNET_PHY_OK;
}

/*
 * rtlnet_phy_dp83848_set_leds -- program LEDCR direct-drive enables and values
 * Steps: reject reserved bits (3, 0 must be zero); write LEDCR and verify its readback.
 * Returns: RTLNET_PHY_OK, argument/readback error or bus fault.
 */
int rtlnet_phy_dp83848_set_leds(const rtlnet_mdio_t *mdio, uint16_t ledcr)
{
    uint16_t rb;
    int rc;
    if (mdio == NULL || (ledcr & (uint16_t)~RTLNET_PHY_DP83848_LED_MASK) != 0u) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = rtlnet_mdio_write(mdio, RTLNET_PHY_DP83848_REG_LEDCR, ledcr);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_DP83848_REG_LEDCR, &rb);
    }
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    return rb == ledcr ? RTLNET_PHY_OK : RTLNET_PHY_ERR_VERIFY;
}

/*
 * rtlnet_phy_dp83848_get_leds -- read LEDCR control bits, not actual pin states
 * Steps: validate pointers and read LEDCR.
 * Returns: RTLNET_PHY_OK, argument error or bus fault.
 */
int rtlnet_phy_dp83848_get_leds(const rtlnet_mdio_t *mdio, uint16_t *ledcr)
{
    if (mdio == NULL || ledcr == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    return rtlnet_mdio_read(mdio, RTLNET_PHY_DP83848_REG_LEDCR, ledcr);
}

/*
 * rtlnet_phy_dp83848_leds_default -- return LEDs to their strapped normal functions
 * Steps: clear all LEDCR direct-drive enables and values, with readback.
 * Returns: as rtlnet_phy_dp83848_set_leds.
 */
int rtlnet_phy_dp83848_leds_default(const rtlnet_mdio_t *mdio)
{
    return rtlnet_phy_dp83848_set_leds(mdio, 0u);
}


/*
 * rtlnet_phy_dp83848_probe -- read ID 0x20005C90 with revision nibble masked
 * Steps: read PHYIDR1/2; PHYIDR1 must be 0x2000 and PHYIDR2[15:4] 0x5C9.
 * Returns: RTLNET_PHY_OK, RTLNET_PHY_ERR_ID, argument error or the bus fault.
 */
int rtlnet_phy_dp83848_probe(const rtlnet_mdio_t *mdio, uint32_t *id_out)
{
    uint16_t id1;
    uint16_t id2;
    int rc;

    if (mdio == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_PHYID1, &id1);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_PHYID2, &id2);
    }
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    if (id_out != NULL) {
        *id_out = ((uint32_t)id1 << PHY_ID_SHIFT) | id2;
    }
    if (id1 != RTLNET_PHY_DP83848_ID1 || (id2 & RTLNET_PHY_DP83848_ID2_MASK) != RTLNET_PHY_DP83848_ID2) {
        return RTLNET_PHY_ERR_ID;
    }
    return RTLNET_PHY_OK;
}

/*
 * rtlnet_phy_dp83848_soft_reset -- set BMCR reset and poll at most 500 times with 1 ms delays
 * Steps: set BMCR.RESET, then poll it until it self-clears.
 * Returns: RTLNET_PHY_OK, RTLNET_PHY_ERR_TIMEOUT, argument error or the bus fault.
 */
int rtlnet_phy_dp83848_soft_reset(const rtlnet_mdio_t *mdio)
{
    uint16_t bmcr;
    int rc;

    if (mdio == NULL || mdio->delay_us == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = modify(mdio, RTLNET_PHY_REG_BMCR, 0u, RTLNET_PHY_BMCR_RESET);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    for (uint32_t i = 0u; i < RTLNET_PHY_RESET_POLL_MAX; i++) {
        mdio->delay_us(mdio->user, RTLNET_PHY_RESET_POLL_US);
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_BMCR, &bmcr);
        if (rc != RTLNET_MDIO_OK) {
            return rc;
        }
        if ((bmcr & RTLNET_PHY_BMCR_RESET) == 0u) {
            return RTLNET_PHY_OK;
        }
    }
    return RTLNET_PHY_ERR_TIMEOUT;
}

/*
 * rtlnet_phy_dp83848_autoneg_restart -- set BMCR AN enable and restart, preserving other fields
 * Steps: read-modify-write BMCR.
 * Returns: RTLNET_PHY_OK, argument error or the bus fault.
 */
int rtlnet_phy_dp83848_autoneg_restart(const rtlnet_mdio_t *mdio)
{
    if (mdio == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    return modify(mdio, RTLNET_PHY_REG_BMCR, 0u, RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_RESTART_AN);
}

/*
 * rtlnet_phy_dp83848_force -- force 10 or 100 full duplex, rejecting half duplex and gigabit
 * Steps: clear AN enable/restart and speed bits, set the speed bit for 100 and full duplex.
 *   Auto-MDIX is not changed (strap-controlled; disabled on the Arty A7).
 * Returns: RTLNET_PHY_OK, RTLNET_PHY_ERR_ARG or the bus fault.
 */
int rtlnet_phy_dp83848_force(const rtlnet_mdio_t *mdio, uint8_t speed, int full_duplex)
{
    uint16_t set = 0u;

    if (mdio == NULL || !full_duplex || (speed != RTLNET_PHY_SPEED_10 && speed != RTLNET_PHY_SPEED_100)) {
        return RTLNET_PHY_ERR_ARG;
    }
    if (speed == RTLNET_PHY_SPEED_100) {
        set |= RTLNET_PHY_BMCR_SPEED0;
    }
    set |= RTLNET_PHY_BMCR_DUPLEX;
    return modify(mdio, RTLNET_PHY_REG_BMCR,
                  RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_RESTART_AN | RTLNET_PHY_BMCR_SPEED0 |
                  RTLNET_PHY_BMCR_SPEED1 | RTLNET_PHY_BMCR_DUPLEX, set);
}

/*
 * rtlnet_phy_dp83848_loopback -- set or clear the BMCR loopback bit
 * Steps: read-modify-write BMCR.
 * Returns: RTLNET_PHY_OK, argument error or the bus fault.
 */
int rtlnet_phy_dp83848_loopback(const rtlnet_mdio_t *mdio, int enable)
{
    if (mdio == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    if (enable != 0) {
        return modify(mdio, RTLNET_PHY_REG_BMCR, 0u, RTLNET_PHY_BMCR_LOOPBACK);
    }
    return modify(mdio, RTLNET_PHY_REG_BMCR, RTLNET_PHY_BMCR_LOOPBACK, 0u);
}

/*
 * rtlnet_phy_dp83848_dump -- read all 32 registers, returning the first bus fault
 * Steps: read registers 0..31 in order, continuing after a fault.
 * Returns: RTLNET_PHY_OK, argument error or the first bus fault.
 */
int rtlnet_phy_dp83848_dump(const rtlnet_mdio_t *mdio, uint16_t regs[RTLNET_PHY_NUM_REGS])
{
    int first = RTLNET_PHY_OK;

    if (mdio == NULL || regs == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    for (uint8_t r = 0u; r < RTLNET_PHY_NUM_REGS; r++) {
        int rc = rtlnet_mdio_read(mdio, r, &regs[r]);
        if (rc != RTLNET_MDIO_OK && first == RTLNET_PHY_OK) {
            first = rc;
        }
    }
    return first;
}

