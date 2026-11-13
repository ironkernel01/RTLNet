/*
 * rtlnet_phy_rtl8211e.c -- Realtek RTL8211E PHY management over rtlnet_mdio
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: PHY layer on the Clause 22 master (see rtlnet_phy_rtl8211e.h). It
 * reads and writes PHY registers only through rtlnet_mdio_read/write and
 * uses the bus context's delay_us hook for its bounded waits.
 *
 * Bring-up order used by the firmware:
 *   1. rtlnet_mdio_wait_por (or rtlnet_mdio_phy_reset): PHY out of reset and
 *      settled (30 ms after PHYRSTB rises).
 *   2. rtlnet_phy_rtl8211e_init: ID check, then the RGMII RX delay on
 *      extension page 0xA4 register 28. The Nexys Video straps the PHY with
 *      no RGMII delay; the MAC's receive capture relies on the PHY's 2 ns RX
 *      delay, and its transmit side forwards a 90-degree TXC, so the TX delay
 *      stays off. A PHY hardware reset clears the setting: run init again.
 *   3. Status polling: link, speed and duplex come from PHYSR (resolved and
 *      real-time), not from BMSR (latch-low link) or RGMII in-band status.
 *   4. Optional: rtlnet_phy_rtl8211e_leds_default (LED0 activity, LED1 link)
 *      and rtlnet_phy_rtl8211e_set_eee_advert. Like the RX delay, the LED
 *      registers return to their defaults after a PHY hardware reset.
 */
#include "rtlnet_phy_rtl8211e.h"

#include <stddef.h>   /* NULL */

#define PHY_RGMII_DELAY_MASK  (RTLNET_PHY_RGMII_CTRL_DELAY | RTLNET_PHY_RGMII_TX_DELAY | RTLNET_PHY_RGMII_RX_DELAY)
#define PHY_RGMII_DELAY_WANT  (RTLNET_PHY_RGMII_CTRL_DELAY | RTLNET_PHY_RGMII_RX_DELAY)
#define PHY_ID_SHIFT          16u

/*
 * modify -- read-modify-write one page-0 register
 * Steps:
 *   1. Read reg; clear the clear mask; set the set mask; write it back.
 * Returns: RTLNET_MDIO_OK or the bus error of the read.
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
 * ext_select -- select an extension page
 * Steps:
 *   1. PAGSEL (reg 31) = 7, EPAGSR (reg 30) = page.
 * The caller returns to page 0 on every path.
 * Returns: RTLNET_MDIO_OK or the first bus error.
 */
static int ext_select(const rtlnet_mdio_t *mdio, uint16_t page)
{
    int rc = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_PAGSEL, RTLNET_PHY_PAGSEL_EXT);

    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_EPAGSR, page);
    }
    return rc;
}

/*
 * rtlnet_phy_rtl8211e_probe -- check the PHY identity
 * Steps:
 *   1. Read PHYID1 and PHYID2.
 *   2. Compare with 0x001C / 0xC915 (exact match: the revision is fixed).
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_ID on a mismatch; RTLNET_MDIO_ERR_NO_PHY
 *   when nothing answers; RTLNET_PHY_ERR_ARG for a NULL context. *id_out
 *   (optional) receives PHYID1:PHYID2 whenever both reads completed.
 */
int rtlnet_phy_rtl8211e_probe(const rtlnet_mdio_t *mdio, uint32_t *id_out)
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
    if (id1 != RTLNET_PHY_RTL8211E_ID1 || id2 != RTLNET_PHY_RTL8211E_ID2) {
        return RTLNET_PHY_ERR_ID;
    }
    return RTLNET_PHY_OK;
}

/*
 * rtlnet_phy_rtl8211e_enable_rx_delay -- turn on the RGMII RX clock delay
 * Steps:
 *   1. PAGSEL (reg 31) = 7, EPAGSR (reg 30) = 0xA4: extension page 0xA4.
 *   2. Read register 28; set bits 13 (delay under register control) and 11
 *      (RX delay), clear bit 12 (TX delay), keep bits 10:0; write it.
 *   3. Read register 28 back.
 *   4. PAGSEL = 0, also when a step above failed, so later accesses see
 *      page 0.
 *   5. Pass when the readback has bits 13 and 11 set and bit 12 clear.
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_VERIFY when the bits did not stick;
 *   a bus error (RTLNET_MDIO_ERR_*) from any access; RTLNET_PHY_ERR_ARG for a
 *   NULL context. *before / *after (optional) receive the first read and
 *   the readback.
 */
int rtlnet_phy_rtl8211e_enable_rx_delay(const rtlnet_mdio_t *mdio, uint16_t *before, uint16_t *after)
{
    uint16_t r28 = RTLNET_MDIO_NO_PHY_DATA;
    uint16_t rb = RTLNET_MDIO_NO_PHY_DATA;
    int rc;
    int rc_page0;

    if (mdio == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_PAGSEL, RTLNET_PHY_PAGSEL_EXT);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_EPAGSR, RTLNET_PHY_EXTPAGE_RGMII);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_RGMII_DELAY, &r28);
    }
    if (rc == RTLNET_MDIO_OK) {
        uint16_t w = (uint16_t)((r28 & (uint16_t)~PHY_RGMII_DELAY_MASK) | PHY_RGMII_DELAY_WANT);
        rc = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_RGMII_DELAY, w);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_RGMII_DELAY, &rb);
    }
    rc_page0 = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_PAGSEL, RTLNET_PHY_PAGSEL_PAGE0);

    if (before != NULL) {
        *before = r28;
    }
    if (after != NULL) {
        *after = rb;
    }
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    if (rc_page0 != RTLNET_MDIO_OK) {
        return rc_page0;
    }
    if ((rb & PHY_RGMII_DELAY_MASK) != PHY_RGMII_DELAY_WANT) {
        return RTLNET_PHY_ERR_VERIFY;
    }
    return RTLNET_PHY_OK;
}

/*
 * rtlnet_phy_rtl8211e_init -- identity check and RX delay, the bring-up pair
 * Steps:
 *   1. Probe; stop on any error.
 *   2. Enable the RGMII RX delay with readback.
 * Returns: as rtlnet_phy_rtl8211e_probe, then as enable_rx_delay.
 */
int rtlnet_phy_rtl8211e_init(const rtlnet_mdio_t *mdio)
{
    int rc = rtlnet_phy_rtl8211e_probe(mdio, NULL);

    if (rc != RTLNET_PHY_OK) {
        return rc;
    }
    return rtlnet_phy_rtl8211e_enable_rx_delay(mdio, NULL, NULL);
}

/*
 * rtlnet_phy_rtl8211e_soft_reset -- BMCR software reset with bounded wait
 * Steps:
 *   1. Set BMCR bit 15 (read-modify-write).
 *   2. Poll BMCR every RTLNET_PHY_RESET_POLL_US until bit 15 reads 0, at most
 *      RTLNET_PHY_RESET_POLL_MAX polls.
 * BMCR and BMSR return to their defaults and auto-negotiation restarts
 * (datasheet Table 23 notes); advertisement and forced settings written
 * before take effect.
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_TIMEOUT when bit 15 stays set; a
 *   bus error; RTLNET_PHY_ERR_ARG for a NULL context.
 */
int rtlnet_phy_rtl8211e_soft_reset(const rtlnet_mdio_t *mdio)
{
    uint16_t bmcr;
    int rc;

    if (mdio == NULL) {
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
 * rtlnet_phy_rtl8211e_autoneg_restart -- enable and restart auto-negotiation
 * Steps:
 *   1. BMCR: set ANE and Restart_AN (self-clearing), other bits kept; the
 *      ANAR and GBCR settings take effect now (Table 27 note 1, Table 32
 *      note 1).
 * Returns: RTLNET_PHY_OK, a bus error, or RTLNET_PHY_ERR_ARG.
 */
int rtlnet_phy_rtl8211e_autoneg_restart(const rtlnet_mdio_t *mdio)
{
    if (mdio == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    return modify(mdio, RTLNET_PHY_REG_BMCR, 0u, RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_RESTART_AN);
}

/*
 * rtlnet_phy_rtl8211e_advertise_set -- choose the advertised abilities
 * Steps:
 *   1. Reject unknown bits and a mask without a full-duplex mode.
 *   2. ANAR bits 8:5 from 10F/100F; the half-duplex bits 10H/100H are always
 *      written 0, whatever the mask holds (pause and other bits kept).
 *   3. GBCR bits 9:8 from 1000F; 1000H is always written 0 (master/slave and
 *      test bits kept).
 * The MAC is full duplex only, so no half-duplex ability is ever advertised.
 * The new set takes effect at the next rtlnet_phy_rtl8211e_autoneg_restart.
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_ARG; a bus error.
 */
int rtlnet_phy_rtl8211e_advertise_set(const rtlnet_mdio_t *mdio, uint32_t adv_mask)
{
    uint16_t anar = 0u;
    uint16_t gbcr = 0u;
    int rc;

    if (mdio == NULL || (adv_mask & RTLNET_PHY_ADV_FULL) == 0u || (adv_mask & ~RTLNET_PHY_ADV_ALL) != 0u) {
        return RTLNET_PHY_ERR_ARG;
    }
    anar |= (adv_mask & RTLNET_PHY_ADV_10F) ? RTLNET_PHY_ANAR_10F : 0u;
    anar |= (adv_mask & RTLNET_PHY_ADV_100F) ? RTLNET_PHY_ANAR_100F : 0u;
    gbcr |= (adv_mask & RTLNET_PHY_ADV_1000F) ? RTLNET_PHY_GBCR_1000F : 0u;

    rc = modify(mdio, RTLNET_PHY_REG_ANAR, RTLNET_PHY_ANAR_TECH_MASK, anar);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    return modify(mdio, RTLNET_PHY_REG_GBCR, RTLNET_PHY_GBCR_TECH_MASK, gbcr);
}

/*
 * rtlnet_phy_rtl8211e_advertise_get -- read back the advertised abilities
 * Steps:
 *   1. Read ANAR and GBCR; map their technology bits to RTLNET_PHY_ADV_*.
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_ARG; a bus error.
 */
int rtlnet_phy_rtl8211e_advertise_get(const rtlnet_mdio_t *mdio, uint32_t *adv_mask)
{
    uint16_t anar;
    uint16_t gbcr;
    uint32_t m = 0u;
    int rc;

    if (mdio == NULL || adv_mask == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_ANAR, &anar);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_GBCR, &gbcr);
    }
    if (rc != RTLNET_MDIO_OK) {
        return rc;
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
 * rtlnet_phy_rtl8211e_force -- forced speed and duplex, auto-negotiation off
 * Steps:
 *   1. Accept 10 or 100 Mb/s only: BMCR speed 1000 (bits 6/13 = 1/0) is
 *      reserved in forced mode on this PHY (Table 23, note 4).
 *   2. BMCR: clear ANE, Restart_AN and both speed bits; set SPEED0 for 100,
 *      DUPLEX for full; other bits kept.
 * Table 23 note 2 states that a speed/duplex/ANE write takes effect with a
 * software reset, Restart_AN or a power-down exit; the write is applied as
 * is (the IEEE behaviour), to be confirmed on hardware.
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_ARG; a bus error.
 */
int rtlnet_phy_rtl8211e_force(const rtlnet_mdio_t *mdio, uint8_t speed, int full_duplex)
{
    uint16_t set = 0u;

    if (mdio == NULL || (speed != RTLNET_PHY_SPEED_10 && speed != RTLNET_PHY_SPEED_100)) {
        return RTLNET_PHY_ERR_ARG;
    }
    if (speed == RTLNET_PHY_SPEED_100) {
        set |= RTLNET_PHY_BMCR_SPEED0;
    }
    if (full_duplex != 0) {
        set |= RTLNET_PHY_BMCR_DUPLEX;
    }
    return modify(mdio, RTLNET_PHY_REG_BMCR,
                  RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_RESTART_AN | RTLNET_PHY_BMCR_SPEED0 |
                  RTLNET_PHY_BMCR_SPEED1 | RTLNET_PHY_BMCR_DUPLEX, set);
}

/*
 * rtlnet_phy_rtl8211e_status -- read and decode link status
 * Steps:
 *   1. Read BMCR, BMSR, PHYSR, ANLPAR and GBSR (page 0).
 *   2. Link, resolved, speed, duplex, crossover from PHYSR; speed_valid only
 *      with link and resolved set and a non-reserved code.
 *   3. AN enabled from BMCR, AN complete from BMSR; partner abilities from
 *      ANLPAR and GBSR only when AN is complete (otherwise not valid,
 *      Tables 28 and 33).
 * A missing PHY returns RTLNET_MDIO_ERR_NO_PHY, so an all-ones bus never
 * reads as a link.
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_ARG; a bus error (*st not updated).
 */
int rtlnet_phy_rtl8211e_status(const rtlnet_mdio_t *mdio, rtlnet_phy_status_t *st)
{
    rtlnet_phy_status_t s;
    int rc;

    if (mdio == NULL || st == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_BMCR, &s.bmcr);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_BMSR, &s.bmsr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_PHYSR, &s.physr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_ANLPAR, &s.anlpar);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_GBSR, &s.gbsr);
    }
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }

    s.link_up = (s.physr & RTLNET_PHY_PHYSR_LINK) ? 1u : 0u;
    s.resolved = (s.physr & RTLNET_PHY_PHYSR_RESOLVED) ? 1u : 0u;
    s.speed = (uint8_t)((s.physr >> RTLNET_PHY_PHYSR_SPEED_SHIFT) & RTLNET_PHY_PHYSR_SPEED_MASK);
    s.full_duplex = (s.physr & RTLNET_PHY_PHYSR_DUPLEX) ? 1u : 0u;
    s.mdi_crossover = (s.physr & RTLNET_PHY_PHYSR_MDI_X) ? 1u : 0u;
    s.speed_valid = (s.link_up && s.resolved && s.speed != RTLNET_PHY_SPEED_UNKNOWN) ? 1u : 0u;
    s.an_enabled = (s.bmcr & RTLNET_PHY_BMCR_ANE) ? 1u : 0u;
    s.an_complete = (s.bmsr & RTLNET_PHY_BMSR_AN_COMPLETE) ? 1u : 0u;
    s.partner_adv = 0u;
    if (s.an_complete) {
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_10H) ? RTLNET_PHY_ADV_10H : 0u;
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_10F) ? RTLNET_PHY_ADV_10F : 0u;
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_100H) ? RTLNET_PHY_ADV_100H : 0u;
        s.partner_adv |= (s.anlpar & RTLNET_PHY_ANAR_100F) ? RTLNET_PHY_ADV_100F : 0u;
        s.partner_adv |= (s.gbsr & RTLNET_PHY_GBSR_LP_1000H) ? RTLNET_PHY_ADV_1000H : 0u;
        s.partner_adv |= (s.gbsr & RTLNET_PHY_GBSR_LP_1000F) ? RTLNET_PHY_ADV_1000F : 0u;
    }
    *st = s;
    return RTLNET_PHY_OK;
}

/*
 * rtlnet_phy_rtl8211e_loopback -- PCS loopback on or off
 * Steps:
 *   1. Set or clear BMCR bit 14 (read-modify-write).
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_ARG; a bus error.
 */
int rtlnet_phy_rtl8211e_loopback(const rtlnet_mdio_t *mdio, int enable)
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
 * rtlnet_phy_rtl8211e_dump -- read registers 0..31 of the current page
 * Steps:
 *   1. Read each register into regs[n]; a failed read stores 0xFFFF and the
 *      dump continues.
 * Side effects: read-clear registers are cleared by the dump (BMSR 1.1/1.4
 * and its link latch, ANER, GBSR 10.15/10.7:0, INSR (releases INTB), RXERC).
 * Returns: RTLNET_PHY_OK; the first bus error; RTLNET_PHY_ERR_ARG.
 */
int rtlnet_phy_rtl8211e_dump(const rtlnet_mdio_t *mdio, uint16_t regs[RTLNET_PHY_NUM_REGS])
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

/*
 * rtlnet_phy_rtl8211e_irq_config -- select the events that drive INTB
 * Steps:
 *   1. Write INER (RTLNET_PHY_INT_* bits; 0 masks every event).
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_ARG; a bus error.
 */
int rtlnet_phy_rtl8211e_irq_config(const rtlnet_mdio_t *mdio, uint16_t iner_mask)
{
    if (mdio == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    return rtlnet_mdio_write(mdio, RTLNET_PHY_REG_INER, iner_mask);
}

/*
 * rtlnet_phy_rtl8211e_irq_ack -- read and clear the interrupt status
 * Steps:
 *   1. Read INSR (read-clear); the PHY releases INTB.
 * Returns: RTLNET_PHY_OK with *insr set; RTLNET_PHY_ERR_ARG; a bus error.
 */
int rtlnet_phy_rtl8211e_irq_ack(const rtlnet_mdio_t *mdio, uint16_t *insr)
{
    if (mdio == NULL || insr == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    return rtlnet_mdio_read(mdio, RTLNET_PHY_REG_INSR, insr);
}

/*
 * rtlnet_phy_rtl8211e_set_leds -- program the LED control registers
 * Steps:
 *   1. PAGSEL = 7, EPAGSR = 0x2C: extension page 0x2C.
 *   2. Write register 28 (LCR) with lcr, then register 26 (LACR) with lacr.
 *   3. Read both back.
 *   4. PAGSEL = 0, also when a step above failed, so later accesses see
 *      page 0.
 *   5. Pass when both readbacks equal the values written (reserved bits in
 *      lcr and lacr must be 0 for that to hold).
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_VERIFY when a readback differs; a
 *   bus error (RTLNET_MDIO_ERR_*) from any access; RTLNET_PHY_ERR_ARG for a
 *   NULL context.
 */
int rtlnet_phy_rtl8211e_set_leds(const rtlnet_mdio_t *mdio, uint16_t lcr, uint16_t lacr)
{
    uint16_t rb_lcr = RTLNET_MDIO_NO_PHY_DATA;
    uint16_t rb_lacr = RTLNET_MDIO_NO_PHY_DATA;
    int rc;
    int rc_page0;

    if (mdio == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = ext_select(mdio, RTLNET_PHY_EXTPAGE_LED);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_LED_LCR, lcr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_LED_LACR, lacr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_LED_LCR, &rb_lcr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_LED_LACR, &rb_lacr);
    }
    rc_page0 = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_PAGSEL, RTLNET_PHY_PAGSEL_PAGE0);

    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    if (rc_page0 != RTLNET_MDIO_OK) {
        return rc_page0;
    }
    if (rb_lcr != lcr || rb_lacr != lacr) {
        return RTLNET_PHY_ERR_VERIFY;
    }
    return RTLNET_PHY_OK;
}

/*
 * rtlnet_phy_rtl8211e_get_leds -- read the LED control registers
 * Steps:
 *   1. PAGSEL = 7, EPAGSR = 0x2C.
 *   2. Read register 28 (LCR) and register 26 (LACR).
 *   3. PAGSEL = 0, also when a step above failed.
 * Returns: RTLNET_PHY_OK with *lcr and *lacr set; a bus error (the outputs
 *   are not updated); RTLNET_PHY_ERR_ARG for a NULL pointer.
 */
int rtlnet_phy_rtl8211e_get_leds(const rtlnet_mdio_t *mdio, uint16_t *lcr, uint16_t *lacr)
{
    uint16_t r_lcr;
    uint16_t r_lacr;
    int rc;
    int rc_page0;

    if (mdio == NULL || lcr == NULL || lacr == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = ext_select(mdio, RTLNET_PHY_EXTPAGE_LED);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_LED_LCR, &r_lcr);
    }
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_read(mdio, RTLNET_PHY_REG_LED_LACR, &r_lacr);
    }
    rc_page0 = rtlnet_mdio_write(mdio, RTLNET_PHY_REG_PAGSEL, RTLNET_PHY_PAGSEL_PAGE0);

    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    if (rc_page0 != RTLNET_MDIO_OK) {
        return rc_page0;
    }
    *lcr = r_lcr;
    *lacr = r_lacr;
    return RTLNET_PHY_OK;
}

/*
 * rtlnet_phy_rtl8211e_leds_default -- apply the RTLNet board LED setting
 * Steps:
 *   1. set_leds with LCR 0x0070 and LACR 0x0010: LED0 (LD10) blinks on TX/RX
 *      activity, LED1 (LD9) is steady while the link is up at 10, 100 or
 *      1000 Mb/s, LED2 (LD8, unused) is off.
 * Run after every PHY hardware reset (the registers return to their defaults).
 * Returns: as rtlnet_phy_rtl8211e_set_leds.
 */
int rtlnet_phy_rtl8211e_leds_default(const rtlnet_mdio_t *mdio)
{
    return rtlnet_phy_rtl8211e_set_leds(mdio, RTLNET_PHY_LCR_BOARD, RTLNET_PHY_LACR_BOARD);
}

/*
 * rtlnet_phy_rtl8211e_set_eee_advert -- advertise Energy-Efficient Ethernet or not
 * Steps:
 *   1. Write MMD 7 register 60 (EEEAR) through Clause 22 registers 13/14
 *      (rtlnet_mdio_mmd_write): 0x0006 (100BASE-TX and 1000BASE-T EEE) for
 *      enable, 0x0000 for disable.
 *   2. Read it back (rtlnet_mdio_mmd_read).
 *   3. Pass when bits 2:1 equal the value written.
 * The register is the auto-negotiation advertisement: a change takes effect
 * at the next auto-negotiation, so the caller runs
 * rtlnet_phy_rtl8211e_autoneg_restart afterwards (disabling EEE needs it to
 * leave EEE mode; the link partner is told only by a new negotiation).
 * Why EEE is off for the RTLNet board: in EEE mode the PHY blinks its LEDs
 * 400 ms on and 2 s off (the activity pattern of the LED setting is lost),
 * and the RGMII receive side carries low-power-idle codes between frames,
 * which a MAC without LPI support does not expect.
 * Returns: RTLNET_PHY_OK; RTLNET_PHY_ERR_VERIFY when the readback differs; a
 *   bus error (RTLNET_MDIO_ERR_*); RTLNET_PHY_ERR_ARG for a NULL context.
 */
int rtlnet_phy_rtl8211e_set_eee_advert(const rtlnet_mdio_t *mdio, int enable)
{
    uint16_t want = (enable != 0) ? RTLNET_PHY_EEE_ADV_MASK : 0u;
    uint16_t rb = RTLNET_MDIO_NO_PHY_DATA;
    int rc;

    if (mdio == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    rc = rtlnet_mdio_mmd_write(mdio, RTLNET_PHY_MMD_AN, RTLNET_PHY_MMD_EEE_ADV, want);
    if (rc == RTLNET_MDIO_OK) {
        rc = rtlnet_mdio_mmd_read(mdio, RTLNET_PHY_MMD_AN, RTLNET_PHY_MMD_EEE_ADV, &rb);
    }
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    if ((rb & RTLNET_PHY_EEE_ADV_MASK) != want) {
        return RTLNET_PHY_ERR_VERIFY;
    }
    return RTLNET_PHY_OK;
}

/*
 * rtlnet_phy_rtl8211e_get_eee_advert -- read the EEE advertisement
 * Steps:
 *   1. Read MMD 7 register 60 (EEEAR) through Clause 22 registers 13/14.
 * Returns: RTLNET_PHY_OK with *value = the register (RTLNET_PHY_EEE_ADV_*
 *   bits); a bus error; RTLNET_PHY_ERR_ARG for a NULL pointer.
 */
int rtlnet_phy_rtl8211e_get_eee_advert(const rtlnet_mdio_t *mdio, uint16_t *value)
{
    if (mdio == NULL || value == NULL) {
        return RTLNET_PHY_ERR_ARG;
    }
    return rtlnet_mdio_mmd_read(mdio, RTLNET_PHY_MMD_AN, RTLNET_PHY_MMD_EEE_ADV, value);
}

/*
 * rtlnet_phy_speed_mbps -- speed code to Mb/s
 * Returns: 10, 100 or 1000; 0 for RTLNET_PHY_SPEED_UNKNOWN or any other code.
 */
uint32_t rtlnet_phy_speed_mbps(uint8_t speed)
{
    switch (speed) {
    case RTLNET_PHY_SPEED_10:
        return 10u;
    case RTLNET_PHY_SPEED_100:
        return 100u;
    case RTLNET_PHY_SPEED_1000:
        return 1000u;
    default:
        return 0u;
    }
}
