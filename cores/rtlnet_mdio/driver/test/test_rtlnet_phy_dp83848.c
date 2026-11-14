/*
 * test_rtlnet_phy_dp83848.c -- IronKernel RTLNet host PHY register model test
 * Language: C11, source-available. Clocks: virtual 1 ms reset polling steps.
 * Revision: 11-14-2026
 *   11-14-2026: verify identity, full-duplex policy, status, reset and controls.
 * The Clause 22 API is mocked; the existing MDIO host test covers wire timing.
 */
#include "rtlnet_phy_dp83848.h"
#include <stdio.h>
#include <string.h>

static uint16_t g_regs[32];
static unsigned g_checks;
static unsigned g_fails;
static unsigned g_ops;
static unsigned g_fail_at;
static unsigned g_polls;
static unsigned g_delay;
static int g_absent;
static int g_stuck;
static int g_led_stuck;
static unsigned g_gigabit_access;

/* check -- count a host assertion; Steps: record failure. Returns: none. */
static void check(int condition, const char *message)
{
    g_checks++;
    if (!condition) {
        g_fails++;
        printf("CHECK FAIL: %s\n", message);
    }
}

/* read -- model bounded BMCR reset; Returns: bus status. */
int rtlnet_mdio_read(const rtlnet_mdio_t *ctx, uint8_t reg, uint16_t *val)
{
    (void)ctx;
    g_ops++;
    if (reg == 9u || reg == 10u) { g_gigabit_access++; }
    if (g_ops == g_fail_at || g_absent) { return RTLNET_MDIO_ERR_NO_PHY; }
    if (reg == 0u && (g_regs[0] & 0x8000u)) {
        g_polls++;
        if (!g_stuck && g_polls == 3u) { g_regs[0] &= 0x7FFFu; }
    }
    *val = g_regs[reg];
    return RTLNET_MDIO_OK;
}

/* write -- model PHY registers; Steps: stuck LED register option. Returns: bus status. */
int rtlnet_mdio_write(const rtlnet_mdio_t *ctx, uint8_t reg, uint16_t val)
{
    (void)ctx;
    g_ops++;
    if (reg == 9u || reg == 10u) { g_gigabit_access++; }
    if (g_ops == g_fail_at || g_absent) { return RTLNET_MDIO_ERR_NO_PHY; }
    if (reg == 0x18u && g_led_stuck) { return RTLNET_MDIO_OK; }
    g_regs[reg] = val;
    return RTLNET_MDIO_OK;
}

/* delay -- count virtual time; Steps: accumulate microseconds. Returns: none. */
static void delay(void *user, uint32_t us)
{
    (void)user;
    g_delay += us;
}

/* main -- exercise the unmodified PHY driver against independent register values.
 * Steps: normal cases, exhaustive status combinations, bus faults, negative control.
 * Returns: zero only on PASS.
 */
int main(int argc, char **argv)
{
    rtlnet_mdio_t mdio = {0};
    rtlnet_phy_status_t st;
    uint32_t id;
    uint32_t mask;
    uint16_t word;
    uint16_t dump[32];
    mdio.delay_us = delay;
    g_regs[2] = 0x2000u;
    for (unsigned rev = 0u; rev < 16u; rev++) {
        g_regs[3] = (uint16_t)(0x5C90u | rev);
        check(rtlnet_phy_dp83848_probe(&mdio, &id) == 0 && id == (0x20005C90u | rev), "revision masked");
    }
    g_regs[3] = 0x5CA0u;
    check(rtlnet_phy_dp83848_init(&mdio) == RTLNET_PHY_ERR_ID, "wrong model rejected");
    g_regs[3] = 0x5C90u;
    g_regs[4] = 0x0FE1u;
    check(rtlnet_phy_dp83848_init(&mdio) == 0, "init");
    check(g_regs[4] == 0x0D41u, "ANAR strips half/T4, keeps pause and selector");
    check((g_regs[0] & 0x1200u) == 0x1200u, "AN restarted");
    for (unsigned bits = 0u; bits < 64u; bits++) {
        unsigned before = g_ops;
        int valid = bits != 0u && (bits & ~0x0Au) == 0u;
        int rc = rtlnet_phy_dp83848_advertise_set(&mdio, bits);
        check(valid ? rc == 0 : rc == RTLNET_PHY_ERR_ARG, "advertisement mask policy");
        if (!valid) { check(g_ops == before, "invalid advertisement writes nothing"); }
        else {
            check((g_regs[4] & 0x02A0u) == 0u, "no half duplex or T4");
            check(rtlnet_phy_dp83848_advertise_get(&mdio, &mask) == 0 && mask == bits, "advertisement readback");
        }
    }
    check(rtlnet_phy_dp83848_force(&mdio, 2u, 1) == RTLNET_PHY_ERR_ARG, "gigabit force rejected");
    check(rtlnet_phy_dp83848_force(&mdio, 1u, 0) == RTLNET_PHY_ERR_ARG, "half force rejected");
    check(rtlnet_phy_dp83848_force(&mdio, 1u, 1) == 0 && (g_regs[0] & 0x3340u) == 0x2100u, "force 100 full");
    check(rtlnet_phy_dp83848_force(&mdio, 0u, 1) == 0 && (g_regs[0] & 0x3340u) == 0x0100u, "force 10 full");
    for (unsigned an = 0u; an < 2u; an++) {
        for (unsigned flags = 0u; flags < 32u; flags++) {
            unsigned link = flags & 1u;
            unsigned full = (flags >> 2) & 1u;
            unsigned complete = (flags >> 4) & 1u;
            g_regs[0] = an ? 0x1000u : 0u;
            g_regs[1] = 0u; /* latch-low BMSR contradicts PHYSTS deliberately */
            g_regs[0x10] = (uint16_t)(flags | 0x4000u);
            g_regs[5] = 0x01E1u;
            check(rtlnet_phy_dp83848_status(&mdio, &st) == 0, "status read");
            check(st.link_up == link && st.full_duplex == full, "PHYSTS current link and duplex");
            check(st.speed == ((flags & 2u) ? 0u : 1u), "PHYSTS speed inversion");
            check(st.speed_valid == (link && full && (!an || complete)), "speed validity policy");
            check(st.an_complete == complete && st.mdi_crossover && st.gbsr == 0u, "PHYSTS AN/MDIX, no gigabit");
            check(st.partner_adv == ((an && complete) ? 15u : 0u), "partner only valid after AN");
        }
    }
    check(g_gigabit_access == 0u, "normal operations never access gigabit registers");
    g_regs[0] = 0u;
    check(rtlnet_phy_dp83848_soft_reset(&mdio) == 0 && g_polls == 3u && g_delay == 3000u, "bounded reset clears");
    g_stuck = 1;
    g_polls = 0u;
    g_delay = 0u;
    check(rtlnet_phy_dp83848_soft_reset(&mdio) == RTLNET_PHY_ERR_TIMEOUT, "reset timeout");
    check(g_polls == 500u && g_delay == 500000u, "reset exact bound");
    g_stuck = 0;
    check(rtlnet_phy_dp83848_loopback(&mdio, 1) == 0 && (g_regs[0] & 0x4000u), "loopback on");
    check(rtlnet_phy_dp83848_loopback(&mdio, 0) == 0 && !(g_regs[0] & 0x4000u), "loopback off");
    check(rtlnet_phy_dp83848_set_leds(&mdio, 0x0036u) == 0, "LED direct control");
    check(rtlnet_phy_dp83848_get_leds(&mdio, &word) == 0 && word == 0x0036u, "LED readback");
    check(rtlnet_phy_dp83848_leds_default(&mdio) == 0 && g_regs[0x18] == 0u, "LED normal functions");
    g_led_stuck = 1;
    check(rtlnet_phy_dp83848_set_leds(&mdio, 0x0036u) == RTLNET_PHY_ERR_VERIFY, "LED not sticking");
    g_led_stuck = 0;
    check(rtlnet_phy_dp83848_set_leds(&mdio, 0x0040u) == RTLNET_PHY_ERR_ARG, "LED reserved bit");
    check(rtlnet_phy_dp83848_set_leds(&mdio, 0x0001u) == RTLNET_PHY_ERR_ARG && rtlnet_phy_dp83848_set_leds(&mdio, 0x0008u) == RTLNET_PHY_ERR_ARG, "LED must-be-zero bits");
    check(rtlnet_phy_dp83848_dump(&mdio, dump) == 0 && dump[2] == 0x2000u, "dump");
    /* Fail every step of status: caller output must remain unchanged. */
    for (unsigned step = 1u; step <= 4u; step++) {
        memset(&st, 0xA5, sizeof(st));
        g_fail_at = g_ops + step;
        check(rtlnet_phy_dp83848_status(&mdio, &st) == RTLNET_MDIO_ERR_NO_PHY, "status bus fault");
        check(st.link_up == 0xA5u && st.physr == 0xA5A5u, "failed status leaves output");
        g_fail_at = 0u;
    }
    for (unsigned step = 1u; step <= 6u; step++) {
        g_fail_at = g_ops + step;
        check(rtlnet_phy_dp83848_init(&mdio) == RTLNET_MDIO_ERR_NO_PHY, "init propagates every bus failure");
        g_fail_at = 0u;
    }
    g_absent = 1;
    check(rtlnet_phy_dp83848_probe(&mdio, NULL) == RTLNET_MDIO_ERR_NO_PHY, "absent probe");
    check(rtlnet_phy_dp83848_soft_reset(&mdio) == RTLNET_MDIO_ERR_NO_PHY, "absent reset");
    check(rtlnet_phy_dp83848_dump(&mdio, dump) == RTLNET_MDIO_ERR_NO_PHY, "absent dump");
    g_absent = 0;
    check(rtlnet_phy_dp83848_probe(NULL, NULL) == RTLNET_PHY_ERR_ARG, "probe NULL");
    check(rtlnet_phy_dp83848_status(&mdio, NULL) == RTLNET_PHY_ERR_ARG, "status NULL");
    check(rtlnet_phy_dp83848_advertise_get(&mdio, NULL) == RTLNET_PHY_ERR_ARG, "advertisement NULL");
    mdio.delay_us = NULL;
    check(rtlnet_phy_dp83848_soft_reset(&mdio) == RTLNET_PHY_ERR_ARG, "reset missing delay");
    if (argc > 1 && strcmp(argv[1], "--inject-failure") == 0) { check(0, "negative control"); }
    if (g_fails) { printf("TEST FAIL: rtlnet_phy_dp83848 fails=%u checks=%u\n", g_fails, g_checks); return 1; }
    printf("TEST PASS: rtlnet_phy_dp83848 checks=%u\n", g_checks);
    return 0;
}
