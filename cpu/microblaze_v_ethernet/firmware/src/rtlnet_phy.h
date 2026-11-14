/*
 * rtlnet_phy.h -- PHY driver selection by MDIO ID
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the firmware has no board-specific source, so the PHY of the board is found at run time. rtlnet_phy_find()
 * scans the Clause 22 bus for a PHY (PHYAD 1..31, then 0) and reads PHYID1/PHYID2; rtlnet_phy_select() picks the
 * driver of that ID from the table g_drivers in rtlnet_phy.c. A PHY whose ID is not in the table gets the generic
 * Clause 22 driver (basic control and status registers, auto-negotiation advertisement of the full-duplex modes, the
 * speed and duplex resolved from the advertised and partner abilities); its ID is printed so a driver can be added.
 *
 * Adding a PHY: write a driver file under cores/rtlnet_mdio/driver/ (register map and bring-up of that PHY, in the
 * style of rtlnet_phy_rtl8211e.c) and add one line to g_drivers in rtlnet_phy.c: name, ID, ID mask and the five
 * functions (init, advertise_set, advertise_get, autoneg_restart, status). Nothing else in the firmware changes.
 * Today the table holds the RTL8211E and the DP83848 (10/100 only).
 *
 * Every driver reports the decoded link state in rtlnet_phy_status_t (rtlnet_phy_rtl8211e.h) with the speed code of
 * the MAC (0 10M, 1 100M, 2 1000M). The advertisement mask uses RTLNET_PHY_ADV_*; half duplex is never advertised.
 *
 * This header holds types and signatures; rtlnet_phy.c holds the per-function commentary.
 */
#ifndef RTLNET_PHY_H
#define RTLNET_PHY_H

#include <stdint.h>   /* uint8_t, uint32_t */

#include "rtlnet_mdio.h"
#include "rtlnet_phy_rtl8211e.h"
#include "rtlnet_phy_dp83848.h"

#define RTLNET_PHY_SUMMARY_LEN  120u   /* size of the bring-up summary text of a driver */

typedef struct rtlnet_phy_driver {
    const char *name;                 /* printed in the banner and "show phy" */
    uint32_t    id;                   /* PHYID1 << 16 | PHYID2 of the PHY */
    uint32_t    id_mask;              /* bits of the ID that must match (the revision bits are masked out) */
    uint32_t    abilities;            /* RTLNET_PHY_ADV_* full-duplex modes the PHY itself can do (speed auto never offers more) */
    int       (*init)(const rtlnet_mdio_t *mdio, char summary[RTLNET_PHY_SUMMARY_LEN]);
    int       (*advertise_set)(const rtlnet_mdio_t *mdio, uint32_t adv_mask);
    int       (*advertise_get)(const rtlnet_mdio_t *mdio, uint32_t *adv_mask);
    int       (*autoneg_restart)(const rtlnet_mdio_t *mdio);
    int       (*status)(const rtlnet_mdio_t *mdio, rtlnet_phy_status_t *st);
    void      (*show_details)(const rtlnet_mdio_t *mdio);   /* extra lines of "show phy", may be NULL */
} rtlnet_phy_driver_t;

int                        rtlnet_phy_find(const rtlnet_mdio_t *mdio, uint8_t *addr, uint32_t *id);
const rtlnet_phy_driver_t *rtlnet_phy_select(uint32_t id);
int                        rtlnet_phy_is_generic(const rtlnet_phy_driver_t *drv);

#endif /* RTLNET_PHY_H */
