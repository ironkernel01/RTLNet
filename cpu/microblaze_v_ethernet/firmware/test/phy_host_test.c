/*
 * phy_host_test.c -- host test of the PHY driver selection (src/rtlnet_phy.c)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_phy_find, rtlnet_phy_select and the generic Clause 22 driver against a mock MDIO bus (this file
 * provides rtlnet_mdio_read/write/read_addr/mmd_* on register arrays, one array per PHY address). Checks:
 *   * the bus scan finds a PHY at any address 1..31 and at 0, and reports no PHY on an empty bus;
 *   * the table selects the RTL8211E driver for its ID (any revision) and the generic driver for any other ID;
 *   * the generic driver on a 10/100 PHY: advertise_set writes only the full-duplex ANAR bits and never touches the
 *     gigabit registers; advertise_get reads them back; status resolves speed and duplex from the advertised and partner
 *     abilities, treats a latched link-down correctly (BMSR is read twice) and refuses a half-duplex-only partner;
 *   * the generic driver on a gigabit PHY (BMSR extended status, register 15): GBCR bit 9 follows 1000F and 1000H is
 *     never written; a gigabit partner resolves to 1000 Mb/s, a 10/100 partner to 100 Mb/s.
 * --neg flips one expectation (the negative control): the run must report FAIL.
 * Build and run: powershell -File cpu/microblaze_v_ethernet/firmware/test/phy_host_test.ps1
 * Last line: PHY_HOST_TEST: PASS checks=<n> or PHY_HOST_TEST: FAIL ...
 */
#include <stdio.h>    /* printf */
#include <string.h>   /* memset, strcmp */

#include "rtlnet_phy.h"

#define MOCK_ADDRS 32u
#define MOCK_REGS  32u

static uint16_t g_regs[MOCK_ADDRS][MOCK_REGS];
static int      g_present[MOCK_ADDRS];
static unsigned g_gbcr_writes;
static int      g_checks;
static int      g_fails;
static int      g_neg;

#define CHECK(cond, what) \
    do { \
        g_checks++; \
        if (!(cond)) { \
            g_fails++; \
            printf("  FAIL: %s (line %d)\n", what, __LINE__); \
        } \
    } while (0)

int rtlnet_mdio_read_addr(const rtlnet_mdio_t *ctx, uint8_t phy_addr, uint8_t reg, uint16_t *val)
{
    (void)ctx;
    if (phy_addr >= MOCK_ADDRS || reg >= MOCK_REGS || !g_present[phy_addr]) {
        *val = 0xFFFFu;
        return RTLNET_MDIO_ERR_NO_PHY;
    }
    *val = g_regs[phy_addr][reg];
    return RTLNET_MDIO_OK;
}

int rtlnet_mdio_read(const rtlnet_mdio_t *ctx, uint8_t reg, uint16_t *val)
{
    return rtlnet_mdio_read_addr(ctx, ctx->phy_addr, reg, val);
}

int rtlnet_mdio_write(const rtlnet_mdio_t *ctx, uint8_t reg, uint16_t val)
{
    if (!g_present[ctx->phy_addr] || reg >= MOCK_REGS) {
        return RTLNET_MDIO_ERR_NO_PHY;
    }
    if (reg == RTLNET_PHY_REG_GBCR) {
        g_gbcr_writes++;
    }
    g_regs[ctx->phy_addr][reg] = val;
    return RTLNET_MDIO_OK;
}

int rtlnet_mdio_mmd_read(const rtlnet_mdio_t *ctx, uint8_t devad, uint16_t reg, uint16_t *val)
{
    (void)ctx; (void)devad; (void)reg;
    *val = 0u;
    return RTLNET_MDIO_OK;
}

int rtlnet_mdio_mmd_write(const rtlnet_mdio_t *ctx, uint8_t devad, uint16_t reg, uint16_t val)
{
    (void)ctx; (void)devad; (void)reg; (void)val;
    return RTLNET_MDIO_OK;
}

/* Host stand-in of the firmware's printf (the drivers print through it only in show_details). */
int fmt_printf(const char *fmt, ...)
{
    (void)fmt;
    return 0;
}

int fmt_snprintf(char *buf, size_t cap, const char *fmt, ...)
{
    (void)fmt;
    if (cap > 0u) {
        buf[0] = '\0';
    }
    return 0;
}

static void reset_bus(void)
{
    memset(g_regs, 0, sizeof(g_regs));
    memset(g_present, 0, sizeof(g_present));
    g_gbcr_writes = 0u;
}

/* A PHY at address a: ID, BMSR with link and auto-negotiation complete as given, ANAR and the gigabit registers. */
static void add_phy(unsigned a, uint16_t id1, uint16_t id2, int gigabit)
{
    g_present[a] = 1;
    g_regs[a][RTLNET_PHY_REG_PHYID1] = id1;
    g_regs[a][RTLNET_PHY_REG_PHYID2] = id2;
    g_regs[a][RTLNET_PHY_REG_BMSR] = (uint16_t)(0x7809u | (gigabit ? 0x0100u : 0u));   /* abilities, extended status */
    g_regs[a][RTLNET_PHY_REG_ANAR] = 0x01E1u;                                          /* every 10/100 mode, selector 1 */
    g_regs[a][15] = gigabit ? 0x2000u : 0u;
}

static void link_up(unsigned a, uint16_t anlpar, uint16_t gbsr)
{
    g_regs[a][RTLNET_PHY_REG_BMSR] |= (uint16_t)(RTLNET_PHY_BMSR_LINK | RTLNET_PHY_BMSR_AN_COMPLETE);
    g_regs[a][RTLNET_PHY_REG_BMCR] = RTLNET_PHY_BMCR_ANE;
    g_regs[a][RTLNET_PHY_REG_ANLPAR] = anlpar;
    g_regs[a][RTLNET_PHY_REG_GBSR] = gbsr;
}

int main(int argc, char **argv)
{
    rtlnet_mdio_t m;
    uint8_t addr = 0u;
    uint32_t id = 0u;
    uint32_t adv = 0u;
    rtlnet_phy_status_t st;
    const rtlnet_phy_driver_t *d;

    g_neg = (argc > 1 && strcmp(argv[1], "--neg") == 0);
    memset(&m, 0, sizeof(m));

    /* Bus scan. */
    reset_bus();
    CHECK(rtlnet_phy_find(&m, &addr, &id) == RTLNET_MDIO_ERR_NO_PHY, "empty bus: no PHY");
    add_phy(1u, 0x001Cu, 0xC915u, 1);
    CHECK(rtlnet_phy_find(&m, &addr, &id) == RTLNET_MDIO_OK && addr == 1u && id == 0x001CC915u, "PHY at address 1");
    reset_bus();
    add_phy(17u, 0x2000u, 0x7C90u, 0);
    CHECK(rtlnet_phy_find(&m, &addr, &id) == RTLNET_MDIO_OK && addr == 17u && id == 0x20007C90u, "PHY at address 17");
    reset_bus();
    add_phy(0u, 0x0022u, 0x1622u, 1);
    CHECK(rtlnet_phy_find(&m, &addr, &id) == RTLNET_MDIO_OK && addr == 0u, "PHY at address 0 (scanned last)");
    reset_bus();
    g_present[5] = 1;                                   /* an address that answers all ones is not a PHY */
    g_regs[5][RTLNET_PHY_REG_PHYID1] = 0xFFFFu;
    CHECK(rtlnet_phy_find(&m, &addr, &id) == RTLNET_MDIO_ERR_NO_PHY, "all-ones ID is not a PHY");

    /* Driver table. */
    d = rtlnet_phy_select(0x001CC915u);
    CHECK(d != NULL && strcmp(d->name, "RTL8211E") == 0 && !rtlnet_phy_is_generic(d), "RTL8211E ID selects its driver");
    d = rtlnet_phy_select(0x001CC91Fu);
    CHECK(strcmp(d->name, "RTL8211E") == 0, "RTL8211E, another revision");
    d = rtlnet_phy_select(0x20007C90u);
    CHECK(rtlnet_phy_is_generic(d), "unknown ID selects the generic driver");
    CHECK(d->init != NULL && d->status != NULL && d->advertise_set != NULL && d->advertise_get != NULL &&
          d->autoneg_restart != NULL, "generic driver has every function");

    /* Generic driver on a 10/100 PHY at address 3. */
    reset_bus();
    add_phy(3u, 0x2000u, 0x7C90u, 0);
    m.phy_addr = 3u;
    CHECK(d->advertise_set(&m, RTLNET_PHY_ADV_100F) == RTLNET_PHY_OK, "advertise 100f");
    CHECK((g_regs[3][RTLNET_PHY_REG_ANAR] & RTLNET_PHY_ANAR_TECH_MASK) == RTLNET_PHY_ANAR_100F, "ANAR holds only 100F");
    CHECK(g_gbcr_writes == 0u, "no gigabit register written on a 10/100 PHY");
    CHECK(d->advertise_set(&m, RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100F | RTLNET_PHY_ADV_1000F) == RTLNET_PHY_OK, "advertise auto");
    CHECK((g_regs[3][RTLNET_PHY_REG_ANAR] & RTLNET_PHY_ANAR_TECH_MASK) == (RTLNET_PHY_ANAR_10F | RTLNET_PHY_ANAR_100F),
          "ANAR holds 10F and 100F, no half duplex");
    CHECK(d->advertise_get(&m, &adv) == RTLNET_PHY_OK && adv == (RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100F), "advertise_get");
    CHECK(d->advertise_set(&m, RTLNET_PHY_ADV_10H | RTLNET_PHY_ADV_100H) == RTLNET_PHY_ERR_ARG, "half-duplex-only mask refused");
    CHECK(d->autoneg_restart(&m) == RTLNET_PHY_OK &&
          (g_regs[3][RTLNET_PHY_REG_BMCR] & (RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_RESTART_AN)) ==
          (RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_RESTART_AN), "autoneg restart sets ANE and RESTART_AN");
    g_regs[3][RTLNET_PHY_REG_BMSR] &= (uint16_t)~(RTLNET_PHY_BMSR_LINK | RTLNET_PHY_BMSR_AN_COMPLETE);
    CHECK(d->status(&m, &st) == RTLNET_PHY_OK && !st.link_up && !st.speed_valid, "link down");
    link_up(3u, 0x01E1u, 0u);
    CHECK(d->status(&m, &st) == RTLNET_PHY_OK && st.link_up && st.speed_valid && st.full_duplex &&
          st.speed == RTLNET_PHY_SPEED_100, "100 Mb/s full duplex resolved");
    d->advertise_set(&m, RTLNET_PHY_ADV_10F);
    CHECK(d->status(&m, &st) == RTLNET_PHY_OK && st.speed_valid && st.speed == RTLNET_PHY_SPEED_10, "10 only advertised: 10 Mb/s");
    link_up(3u, 0x00A1u, 0u);                           /* partner: 100 half and 10 half only */
    d->advertise_set(&m, RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100F);
    CHECK(d->status(&m, &st) == RTLNET_PHY_OK && st.link_up && !st.speed_valid, "half-duplex-only partner: no usable link");

    /* Generic driver on a gigabit PHY at address 9. */
    reset_bus();
    add_phy(9u, 0x2000u, 0x7C90u, 1);
    m.phy_addr = 9u;
    CHECK(d->advertise_set(&m, RTLNET_PHY_ADV_1000F | RTLNET_PHY_ADV_100F) == RTLNET_PHY_OK, "advertise 1000f and 100f");
    CHECK((g_regs[9][RTLNET_PHY_REG_GBCR] & RTLNET_PHY_GBCR_TECH_MASK) == RTLNET_PHY_GBCR_1000F, "GBCR holds 1000F only, never 1000H");
    link_up(9u, 0x01E1u, RTLNET_PHY_GBSR_LP_1000F);
    CHECK(d->status(&m, &st) == RTLNET_PHY_OK && st.speed_valid && st.speed == RTLNET_PHY_SPEED_1000 && st.full_duplex,
          "gigabit partner: 1000 Mb/s");
    link_up(9u, 0x01E1u, 0u);
    CHECK(d->status(&m, &st) == RTLNET_PHY_OK && st.speed_valid && st.speed == RTLNET_PHY_SPEED_100, "10/100 partner: 100 Mb/s");

    /* DP83848 (10/100 only): selected by ID 0x2000/0x5C9x, the abilities stop at 100 Mb/s. */
    d = rtlnet_phy_select(0x20005C91u);
    CHECK(strcmp(d->name, "DP83848") == 0 && !rtlnet_phy_is_generic(d), "DP83848 ID selects its driver");
    CHECK(d->abilities == (RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100F), "DP83848 abilities are 10f and 100f");
    CHECK(strcmp(rtlnet_phy_select(0x001CC915u)->name, "RTL8211E") == 0 &&
          (rtlnet_phy_select(0x001CC915u)->abilities & RTLNET_PHY_ADV_1000F) != 0u, "RTL8211E keeps 1000f");
    reset_bus();
    add_phy(1u, 0x2000u, 0x5C90u, 0);
    m.phy_addr = 1u;
    CHECK(d->advertise_set(&m, RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100F) == RTLNET_PHY_OK, "DP83848 advertise 10f+100f");
    CHECK((g_regs[1][RTLNET_PHY_REG_ANAR] & RTLNET_PHY_ANAR_TECH_MASK) == (RTLNET_PHY_ANAR_10F | RTLNET_PHY_ANAR_100F),
          "DP83848 ANAR: full duplex only");
    CHECK(d->advertise_get(&m, &adv) == RTLNET_PHY_OK && adv == (RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100F), "DP83848 advertise_get");
    g_regs[1][RTLNET_PHY_REG_BMSR] |= (uint16_t)(RTLNET_PHY_BMSR_LINK | RTLNET_PHY_BMSR_AN_COMPLETE);
    g_regs[1][RTLNET_PHY_REG_BMCR] = RTLNET_PHY_BMCR_ANE;
    g_regs[1][RTLNET_PHY_REG_ANLPAR] = 0x01E1u;
    g_regs[1][RTLNET_PHY_DP83848_REG_PHYSTS] = (uint16_t)(RTLNET_PHY_DP83848_PHYSTS_LINK | RTLNET_PHY_DP83848_PHYSTS_DUPLEX |
                                                      RTLNET_PHY_DP83848_PHYSTS_AN_COMPLETE);
    CHECK(d->status(&m, &st) == RTLNET_PHY_OK && st.speed_valid && st.speed == RTLNET_PHY_SPEED_100 && st.full_duplex,
          "DP83848 100 Mb/s full duplex");
    g_regs[1][RTLNET_PHY_DP83848_REG_PHYSTS] |= RTLNET_PHY_DP83848_PHYSTS_SPEED10;
    CHECK(d->status(&m, &st) == RTLNET_PHY_OK && st.speed_valid && st.speed == RTLNET_PHY_SPEED_10, "DP83848 10 Mb/s");

    if (g_neg) {
        CHECK(0, "negative control");
    }
    if (g_fails == 0 && g_checks > 0) {
        printf("PHY_HOST_TEST: PASS checks=%d\n", g_checks);
        return 0;
    }
    printf("PHY_HOST_TEST: FAIL fails=%d checks=%d\n", g_fails, g_checks);
    return 1;
}
