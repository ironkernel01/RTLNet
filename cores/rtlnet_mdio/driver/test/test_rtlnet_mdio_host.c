/*
 * test_rtlnet_mdio_host.c -- host unit test of the rtlnet_mdio and RTL8211E drivers
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_mdio.c and rtlnet_phy_rtl8211e.c unmodified (built with
 * RTLNET_HOST_TEST) against two models, in virtual time:
 *   - the rtlnet_mdio register block (ID, VERSION, CAPS, CTRL, STATUS,
 *     BITBANG, POR timer), mirroring cores/rtlnet_mdio/hdl/rtlnet_mdio.sv;
 *   - an RTL8211E management slave clocked by the MDC edges the driver
 *     produces: Clause 22 frame decode, TA and data driven t6 after the
 *     rising edge (Clause 22 and, with c45_native, Clause 45 frames), page 0
 *     registers, PAGSEL/EPAGSR, extension page 0xA4 register 28 and page 0x2C
 *     registers 26/28 (LEDs), the Clause 22 MMD access registers 13/14 over a
 *     small register file per MMD (EEEAR is MMD 7 register 60), BMCR
 *     self-clearing reset and restart, a link partner with auto-negotiation and
 *     forced modes, INSR/INER and INTB, hardware reset with the datasheet low
 *     and settle times.
 * The models check every bus rule the driver must keep: MDC period, high and
 * low times (Table 61), MDIO setup/hold against the rising edge, read
 * samples not earlier than t6 after the PHY's launching edge, no line
 * contention, 32-bit preamble, an idle slot after each frame, the 10 ms
 * reset low time and no access in the 30 ms settle window.
 *
 * Time: register access ACCESS_NS, spin loop LOOP_NS per iteration plus
 * SPIN_NS per call, delay_us exact; the timer for calibration runs at
 * 100 MHz (10 ns ticks).
 *
 * Output: exactly one line, "TEST PASS: rtlnet_mdio_host checks=N" or
 * "TEST FAIL: rtlnet_mdio_host fails=F checks=N first=<msg>". Argument
 * --inject-failure forces a failure (negative control). Exit code 0 on PASS.
 */
#include "rtlnet_mdio.h"
#include "rtlnet_phy_rtl8211e.h"

#include <stdio.h>    /* printf, snprintf */
#include <string.h>   /* memset, strcmp */

/* -------------------------------------------------------------------------
 * Check bookkeeping
 * ------------------------------------------------------------------------- */
static int g_checks;
static int g_fails;
static char g_first[200];

static void check(int cond, const char *msg)
{
    g_checks++;
    if (!cond) {
        g_fails++;
        if (g_first[0] == '\0') {
            snprintf(g_first, sizeof g_first, "%s", msg);
        }
        printf("CHECK FAILED: %s\n", msg);
    }
}

static void checkf(int cond, const char *fmt, unsigned a, unsigned b)
{
    char buf[200];

    snprintf(buf, sizeof buf, fmt, a, b);
    check(cond, buf);
}

/* -------------------------------------------------------------------------
 * Model configuration
 * ------------------------------------------------------------------------- */
#define TB_BASE          ((uintptr_t)0x44A02000u)
#define TB_CLK_KHZ       100000u
#define TB_POR_MS        20u
#define ACCESS_NS        60u
#define LOOP_NS          8u
#define SPIN_NS          4u
#define T6_NS            300u          /* worst-case PHY output delay */
#define T_HIGH_MIN_NS    160u
#define T_LOW_MIN_NS     160u
#define T_PERIOD_MIN_NS  400u
#define T_HOLD_NS        10u
#define RESET_LOW_MIN_NS 10000000ull   /* 10 ms */
#define SETTLE_NS        30000000ull   /* 30 ms */
#define AN_TIME_NS       2000000ull    /* auto-negotiation / forced link time in the model */
#define SOFT_RESET_NS    200000ull     /* BMCR bit 15 busy time */
#define TIMER_NS_PER_TICK 10u

/* Slave states */
enum { SL_PRE, SL_ST1, SL_HDR, SL_TA1, SL_TA2, SL_DATA, SL_SKIP };

typedef struct {
    /* faults and environment */
    int phy_absent;
    int wrong_id;
    int r28_stuck;
    int led_stuck;
    int eee_stuck;
    int c45_native;     /* the model answers native Clause 45 frames (the RTL8211E does not) */
    int reset_stuck;
    int por_stuck;
    int core_id_bad;
    int timer_stuck;
    int cable;
    uint32_t partner_adv;
    uint8_t phy_addr;

    /* virtual time, ns */
    unsigned long long now;

    /* GPIO core */
    uint32_t mdc;
    uint32_t oe;
    uint32_t out;
    uint32_t phy_reset_bit;
    uint32_t irq_en;

    /* bus timing state */
    int have_rise;
    unsigned long long t_rise;
    unsigned long long t_fall;
    int need_idle;
    int idle_valid;
    unsigned long long t_idle;

    /* PHY output and its pending change (t6 after a rising edge) */
    int phy_oe;
    int phy_val;
    int pend;
    int pend_oe;
    int pend_val;
    unsigned long long pend_t;

    /* violation counters */
    unsigned v_period;
    unsigned v_high;
    unsigned v_low;
    unsigned v_setup;
    unsigned v_hold;
    unsigned v_early;
    unsigned v_contention;
    unsigned v_short_pre;
    unsigned v_bad_frame;
    unsigned v_idle;
    unsigned v_in_reset;
    unsigned v_settle;
    unsigned v_reset_short;

    /* frame counters */
    unsigned frames_read;
    unsigned frames_write;
    unsigned frames_ignored;
    unsigned last_pre;
    unsigned bmcr_reads;

    /* reset tracking */
    int in_reset;
    unsigned long long reset_start;
    unsigned long long reset_bit_clear_t;
    unsigned long long release_t;
    unsigned long long min_reset_low;

    /* slave decoder */
    int st;
    unsigned ones;
    unsigned nbits;
    uint32_t hdr;
    uint16_t shreg;
    uint16_t wdata;
    int is_read;
    uint8_t reg;        /* Clause 22 REGAD or Clause 45 DEVAD */
    uint32_t op;
    int is_c45;
    int respond;        /* the model drives TA/data and applies writes for this frame */
    uint32_t ta;

    /* PHY registers and link */
    uint16_t bmcr;
    uint16_t anar;
    uint16_t gbcr;
    uint16_t iner;
    uint16_t insr;
    uint16_t pagsel;
    uint16_t epagsr;
    uint16_t r28;
    uint16_t led_lcr;           /* extension page 0x2C register 28 */
    uint16_t led_lacr;          /* extension page 0x2C register 26 */
    uint16_t macr;              /* register 13 */
    uint32_t mmd_present;       /* bit n set: MMD n exists */
    uint16_t mmd_reg[32][64];   /* register file per MMD, registers 0..63 */
    uint16_t mmd_addr[32];      /* address register per MMD (Clause 45 and MAADR share it) */
    uint32_t trace[16];         /* page 0 writes to registers 13/14: reg << 16 | value */
    unsigned ntrace;
    int bmsr_latch;
    int soft_reset_pend;
    unsigned long long soft_reset_until;
    unsigned long long link_at;     /* AN or forced link completes at this time */
    int link;
    int an_complete;
    uint8_t speed;
    int duplex;
} model_t;

static model_t g_m;

/* -------------------------------------------------------------------------
 * PHY register model
 * ------------------------------------------------------------------------- */
static int por_done(void)
{
    return !g_m.por_stuck && g_m.now >= (unsigned long long)TB_POR_MS * 1000000ull;
}

static void phy_defaults(void)
{
    g_m.bmcr = 0x1140u;
    g_m.anar = 0x05E1u;
    g_m.gbcr = 0x0200u;
    g_m.iner = 0x0000u;
    g_m.insr = 0x0000u;
    g_m.pagsel = 0u;
    g_m.epagsr = 0u;
    g_m.r28 = 0x8575u;
    g_m.led_lcr = 0x0000u;
    g_m.led_lacr = 0x0000u;
    g_m.macr = 0u;
    memset(g_m.mmd_reg, 0, sizeof g_m.mmd_reg);
    memset(g_m.mmd_addr, 0, sizeof g_m.mmd_addr);
    g_m.mmd_reg[RTLNET_PHY_MMD_AN][RTLNET_PHY_MMD_EEE_ADV] = RTLNET_PHY_EEE_ADV_MASK;   /* EEE advertised */
    g_m.bmsr_latch = 0;
    g_m.soft_reset_pend = 0;
    g_m.link = 0;
    g_m.an_complete = 0;
    g_m.speed = RTLNET_PHY_SPEED_100;
    g_m.duplex = 0;
    g_m.st = SL_PRE;
    g_m.ones = 0u;
    g_m.phy_oe = 0;
    g_m.pend = 0;
}

static uint32_t local_adv(void)
{
    uint32_t a = 0u;

    a |= (g_m.anar & RTLNET_PHY_ANAR_10H) ? RTLNET_PHY_ADV_10H : 0u;
    a |= (g_m.anar & RTLNET_PHY_ANAR_10F) ? RTLNET_PHY_ADV_10F : 0u;
    a |= (g_m.anar & RTLNET_PHY_ANAR_100H) ? RTLNET_PHY_ADV_100H : 0u;
    a |= (g_m.anar & RTLNET_PHY_ANAR_100F) ? RTLNET_PHY_ADV_100F : 0u;
    a |= (g_m.gbcr & RTLNET_PHY_GBCR_1000H) ? RTLNET_PHY_ADV_1000H : 0u;
    a |= (g_m.gbcr & RTLNET_PHY_GBCR_1000F) ? RTLNET_PHY_ADV_1000F : 0u;
    return a;
}

/* Re-evaluate link, AN and INSR at the current time. */
static void link_eval(void)
{
    int link = 0;
    int anc = 0;
    uint8_t speed = g_m.speed;
    int duplex = g_m.duplex;

    if (g_m.cable && !g_m.in_reset && g_m.now >= g_m.link_at) {
        if (g_m.bmcr & RTLNET_PHY_BMCR_ANE) {
            uint32_t c = local_adv() & g_m.partner_adv;
            anc = 1;
            if (c & RTLNET_PHY_ADV_1000F)      { link = 1; speed = RTLNET_PHY_SPEED_1000; duplex = 1; }
            else if (c & RTLNET_PHY_ADV_1000H) { link = 1; speed = RTLNET_PHY_SPEED_1000; duplex = 0; }
            else if (c & RTLNET_PHY_ADV_100F)  { link = 1; speed = RTLNET_PHY_SPEED_100;  duplex = 1; }
            else if (c & RTLNET_PHY_ADV_100H)  { link = 1; speed = RTLNET_PHY_SPEED_100;  duplex = 0; }
            else if (c & RTLNET_PHY_ADV_10F)   { link = 1; speed = RTLNET_PHY_SPEED_10;   duplex = 1; }
            else if (c & RTLNET_PHY_ADV_10H)   { link = 1; speed = RTLNET_PHY_SPEED_10;   duplex = 0; }
        } else {
            link = 1;
            speed = (g_m.bmcr & RTLNET_PHY_BMCR_SPEED0) ? RTLNET_PHY_SPEED_100 : RTLNET_PHY_SPEED_10;
            duplex = (g_m.bmcr & RTLNET_PHY_BMCR_DUPLEX) ? 1 : 0;
        }
    }
    if (link != g_m.link) {
        g_m.insr |= RTLNET_PHY_INT_LINK_CHANGE;
    }
    if (anc && !g_m.an_complete) {
        g_m.insr |= RTLNET_PHY_INT_AN_COMPLETE;
    }
    if (!link) {
        g_m.bmsr_latch = 0;
    }
    g_m.link = link;
    g_m.an_complete = anc;
    if (link) {
        g_m.speed = speed;
        g_m.duplex = duplex;
    }
}

static void link_restart(void)
{
    g_m.link_at = g_m.now + AN_TIME_NS;
    g_m.an_complete = 0;
    if (g_m.link) {
        g_m.insr |= RTLNET_PHY_INT_LINK_CHANGE;
    }
    g_m.link = 0;
    g_m.bmsr_latch = 0;
}

static uint16_t mmd_read(uint32_t dev, uint16_t reg)
{
    if (((g_m.mmd_present >> dev) & 1u) == 0u || reg >= 64u) {
        return 0u;
    }
    return g_m.mmd_reg[dev][reg];
}

static void mmd_write(uint32_t dev, uint16_t reg, uint16_t v)
{
    if (((g_m.mmd_present >> dev) & 1u) == 0u || reg >= 64u) {
        return;
    }
    if (dev == RTLNET_PHY_MMD_AN && reg == RTLNET_PHY_MMD_EEE_ADV && g_m.eee_stuck) {
        return;
    }
    g_m.mmd_reg[dev][reg] = v;
}

static uint16_t reg_read(uint8_t reg)
{
    uint16_t v = 0u;

    link_eval();
    if (reg == RTLNET_PHY_REG_PAGSEL) {
        return g_m.pagsel;
    }
    if (reg == RTLNET_PHY_REG_EPAGSR) {
        return g_m.epagsr;
    }
    if ((g_m.pagsel & 0x7u) != 0u) {
        if ((g_m.pagsel & 0x7u) == RTLNET_PHY_PAGSEL_EXT && g_m.epagsr == RTLNET_PHY_EXTPAGE_RGMII &&
            reg == RTLNET_PHY_REG_RGMII_DELAY) {
            return g_m.r28;
        }
        if ((g_m.pagsel & 0x7u) == RTLNET_PHY_PAGSEL_EXT && g_m.epagsr == RTLNET_PHY_EXTPAGE_LED) {
            if (reg == RTLNET_PHY_REG_LED_LCR) {
                return g_m.led_lcr;
            }
            if (reg == RTLNET_PHY_REG_LED_LACR) {
                return g_m.led_lacr;
            }
        }
        return 0u;
    }
    switch (reg) {
    case RTLNET_PHY_REG_BMCR:
        g_m.bmcr_reads++;
        if (g_m.soft_reset_pend && !g_m.reset_stuck && g_m.now >= g_m.soft_reset_until) {
            g_m.soft_reset_pend = 0;
            g_m.bmcr = 0x1140u;
            link_restart();
        }
        v = g_m.bmcr;
        break;
    case RTLNET_PHY_REG_BMSR:
        v = (uint16_t)(0x7949u | (g_m.an_complete ? RTLNET_PHY_BMSR_AN_COMPLETE : 0u) |
                       (g_m.bmsr_latch ? RTLNET_PHY_BMSR_LINK : 0u));
        g_m.bmsr_latch = g_m.link;
        break;
    case RTLNET_PHY_REG_PHYID1:
        v = RTLNET_PHY_RTL8211E_ID1;
        break;
    case RTLNET_PHY_REG_PHYID2:
        v = g_m.wrong_id ? (uint16_t)(RTLNET_PHY_RTL8211E_ID2 + 1u) : RTLNET_PHY_RTL8211E_ID2;
        break;
    case RTLNET_PHY_REG_ANAR:
        v = g_m.anar;
        break;
    case RTLNET_PHY_REG_ANLPAR:
        if (g_m.an_complete) {
            v = 0x4001u;
            v |= (g_m.partner_adv & RTLNET_PHY_ADV_10H) ? RTLNET_PHY_ANAR_10H : 0u;
            v |= (g_m.partner_adv & RTLNET_PHY_ADV_10F) ? RTLNET_PHY_ANAR_10F : 0u;
            v |= (g_m.partner_adv & RTLNET_PHY_ADV_100H) ? RTLNET_PHY_ANAR_100H : 0u;
            v |= (g_m.partner_adv & RTLNET_PHY_ADV_100F) ? RTLNET_PHY_ANAR_100F : 0u;
        }
        break;
    case RTLNET_PHY_REG_GBCR:
        v = g_m.gbcr;
        break;
    case RTLNET_MDIO_REG_MACR:
        v = g_m.macr;
        break;
    case RTLNET_MDIO_REG_MAADR: {
        uint32_t dev = g_m.macr & RTLNET_MDIO_MACR_DEVAD_MASK;
        uint32_t func = g_m.macr & 0xC000u;

        if (func == RTLNET_MDIO_MACR_FUNC_ADDR) {
            v = g_m.mmd_addr[dev];
        } else {
            v = mmd_read(dev, g_m.mmd_addr[dev]);
            if (func == RTLNET_MDIO_MACR_FUNC_INC_RW) {
                g_m.mmd_addr[dev]++;
            }
        }
        break;
    }
    case RTLNET_PHY_REG_GBSR:
        if (g_m.an_complete) {
            v |= (g_m.partner_adv & RTLNET_PHY_ADV_1000F) ? RTLNET_PHY_GBSR_LP_1000F : 0u;
            v |= (g_m.partner_adv & RTLNET_PHY_ADV_1000H) ? RTLNET_PHY_GBSR_LP_1000H : 0u;
        }
        break;
    case RTLNET_PHY_REG_PHYSR:
        if (g_m.link) {
            v = (uint16_t)(((uint32_t)g_m.speed << RTLNET_PHY_PHYSR_SPEED_SHIFT) |
                           (g_m.duplex ? RTLNET_PHY_PHYSR_DUPLEX : 0u) | RTLNET_PHY_PHYSR_RESOLVED |
                           RTLNET_PHY_PHYSR_LINK);
        } else {
            v = 0x4000u;   /* datasheet default speed code 01, nothing resolved */
        }
        break;
    case RTLNET_PHY_REG_INER:
        v = g_m.iner;
        break;
    case RTLNET_PHY_REG_INSR:
        v = g_m.insr;
        g_m.insr = 0u;
        break;
    default:
        v = 0u;
        break;
    }
    return v;
}

static void reg_write(uint8_t reg, uint16_t v)
{
    link_eval();
    if (reg == RTLNET_PHY_REG_PAGSEL) {
        g_m.pagsel = v;
        return;
    }
    if (reg == RTLNET_PHY_REG_EPAGSR) {
        g_m.epagsr = v;
        return;
    }
    if ((g_m.pagsel & 0x7u) != 0u) {
        if ((g_m.pagsel & 0x7u) == RTLNET_PHY_PAGSEL_EXT && g_m.epagsr == RTLNET_PHY_EXTPAGE_RGMII &&
            reg == RTLNET_PHY_REG_RGMII_DELAY && !g_m.r28_stuck) {
            g_m.r28 = v;
        }
        if ((g_m.pagsel & 0x7u) == RTLNET_PHY_PAGSEL_EXT && g_m.epagsr == RTLNET_PHY_EXTPAGE_LED && !g_m.led_stuck) {
            if (reg == RTLNET_PHY_REG_LED_LCR) {
                g_m.led_lcr = v;
            } else if (reg == RTLNET_PHY_REG_LED_LACR) {
                g_m.led_lacr = v;
            }
        }
        return;
    }
    switch (reg) {
    case RTLNET_PHY_REG_BMCR:
        if (v & RTLNET_PHY_BMCR_RESET) {
            g_m.bmcr = v;
            g_m.soft_reset_pend = 1;
            g_m.soft_reset_until = g_m.now + SOFT_RESET_NS;
            link_restart();
        } else {
            uint16_t old = g_m.bmcr;
            g_m.bmcr = (uint16_t)(v & (uint16_t)~RTLNET_PHY_BMCR_RESTART_AN);
            if ((v & RTLNET_PHY_BMCR_RESTART_AN) ||
                ((old ^ v) & (RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_SPEED0 | RTLNET_PHY_BMCR_SPEED1 |
                              RTLNET_PHY_BMCR_DUPLEX))) {
                link_restart();
            }
        }
        break;
    case RTLNET_PHY_REG_ANAR:
        g_m.anar = (uint16_t)((v & 0xFDE0u) | 0x0001u);
        break;
    case RTLNET_MDIO_REG_MACR:
        g_m.macr = v;
        if (g_m.ntrace < sizeof g_m.trace / sizeof g_m.trace[0]) {
            g_m.trace[g_m.ntrace++] = ((uint32_t)reg << 16) | v;
        }
        break;
    case RTLNET_MDIO_REG_MAADR: {
        uint32_t dev = g_m.macr & RTLNET_MDIO_MACR_DEVAD_MASK;
        uint32_t func = g_m.macr & 0xC000u;

        if (g_m.ntrace < sizeof g_m.trace / sizeof g_m.trace[0]) {
            g_m.trace[g_m.ntrace++] = ((uint32_t)reg << 16) | v;
        }
        if (func == RTLNET_MDIO_MACR_FUNC_ADDR) {
            g_m.mmd_addr[dev] = v;
        } else {
            mmd_write(dev, g_m.mmd_addr[dev], v);
            if (func >= RTLNET_MDIO_MACR_FUNC_INC_RW) {
                g_m.mmd_addr[dev]++;
            }
        }
        break;
    }
    case RTLNET_PHY_REG_GBCR:
        g_m.gbcr = v;
        break;
    case RTLNET_PHY_REG_INER:
        g_m.iner = v;
        break;
    default:
        break;
    }
}

/* -------------------------------------------------------------------------
 * Reset, line and slave decoder
 * ------------------------------------------------------------------------- */
static int phy_responsive(void)
{
    return !g_m.in_reset && g_m.now >= g_m.release_t + SETTLE_NS;
}

static void reset_eval(void)
{
    int r = (g_m.phy_reset_bit != 0u) || !por_done();

    if (r && !g_m.in_reset) {
        g_m.in_reset = 1;
        g_m.reset_start = g_m.now;
        phy_defaults();
    } else if (!r && g_m.in_reset) {
        unsigned long long por_t = (unsigned long long)TB_POR_MS * 1000000ull;
        unsigned long long rel = (g_m.reset_bit_clear_t > por_t) ? g_m.reset_bit_clear_t : por_t;
        unsigned long long low = rel - g_m.reset_start;
        g_m.in_reset = 0;
        g_m.release_t = rel;
        if (low < g_m.min_reset_low) {
            g_m.min_reset_low = low;
        }
        if (low < RESET_LOW_MIN_NS) {
            g_m.v_reset_short++;
        }
        phy_defaults();
        g_m.link_at = rel + SETTLE_NS + AN_TIME_NS;
    }
}

static void apply_pending(void)
{
    if (g_m.pend && g_m.now >= g_m.pend_t) {
        g_m.phy_oe = g_m.pend_oe;
        g_m.phy_val = g_m.pend_val;
        g_m.pend = 0;
    }
}

static void schedule(int oe, int val)
{
    apply_pending();
    g_m.pend = 1;
    g_m.pend_oe = oe;
    g_m.pend_val = val;
    g_m.pend_t = g_m.now + T6_NS;
}

static int line_level(void)
{
    if (g_m.oe && g_m.phy_oe) {
        g_m.v_contention++;
        return 0;
    }
    if (g_m.oe) {
        return (int)g_m.out;
    }
    if (g_m.phy_oe) {
        return g_m.phy_val;
    }
    return 1;   /* pull-up */
}

static void slave_rise(int line)
{
    uint32_t op;
    uint32_t pa;

    if (g_m.in_reset) {
        g_m.v_in_reset++;
        return;
    }
    if (!phy_responsive()) {
        g_m.v_settle++;
    }
    if (g_m.phy_absent) {
        return;
    }
    switch (g_m.st) {
    case SL_PRE:
        if (line) {
            g_m.ones++;
        } else {
            if (g_m.ones >= RTLNET_MDIO_PREAMBLE_BITS) {
                g_m.last_pre = g_m.ones;
                g_m.st = SL_ST1;
            } else {
                g_m.v_short_pre++;
                g_m.st = SL_SKIP;
            }
            g_m.ones = 0u;
        }
        break;
    case SL_ST1:
        /* The preamble's terminating 0 was ST bit 1; this is ST bit 0: 01 is
         * Clause 22, 00 is Clause 45. */
        g_m.is_c45 = !line;
        g_m.st = SL_HDR;
        g_m.nbits = 0u;
        g_m.hdr = 0u;
        break;
    case SL_HDR:
        g_m.hdr = (g_m.hdr << 1) | (uint32_t)line;
        if (++g_m.nbits == 12u) {
            op = (g_m.hdr >> 10) & 3u;
            pa = (g_m.hdr >> 5) & 31u;
            g_m.reg = (uint8_t)(g_m.hdr & 31u);
            g_m.op = op;
            if (g_m.is_c45) {
                /* Every Clause 45 frame is decoded to its end, so the
                 * decoder stays in step; only a device that exists answers. */
                g_m.is_read = (op == RTLNET_MDIO_C45_OP_READ || op == RTLNET_MDIO_C45_OP_READ_INC);
                g_m.respond = g_m.c45_native && pa == g_m.phy_addr && phy_responsive() &&
                              ((g_m.mmd_present >> g_m.reg) & 1u) != 0u;
                if (!g_m.respond) {
                    g_m.frames_ignored++;
                }
                g_m.st = SL_TA1;
            } else {
                g_m.is_read = (op == RTLNET_MDIO_OP_READ);
                g_m.respond = 1;
                if (op != RTLNET_MDIO_OP_READ && op != RTLNET_MDIO_OP_WRITE) {
                    g_m.v_bad_frame++;
                    g_m.st = SL_SKIP;
                } else if (pa != g_m.phy_addr || !phy_responsive()) {
                    g_m.frames_ignored++;
                    g_m.st = SL_SKIP;
                } else {
                    g_m.st = SL_TA1;
                }
            }
        }
        break;
    case SL_TA1:
        g_m.ta = (uint32_t)line << 1;
        if (g_m.is_read && g_m.respond) {
            g_m.shreg = g_m.is_c45 ? mmd_read(g_m.reg, g_m.mmd_addr[g_m.reg]) : reg_read(g_m.reg);
            schedule(1, 0);
        }
        g_m.st = SL_TA2;
        break;
    case SL_TA2:
        g_m.ta |= (uint32_t)line;
        g_m.nbits = 0u;
        if (g_m.is_read) {
            if (g_m.respond) {
                schedule(1, (g_m.shreg >> 15) & 1u);
                g_m.shreg = (uint16_t)(g_m.shreg << 1);
            }
            g_m.st = SL_DATA;
        } else if (g_m.ta != RTLNET_MDIO_TA_WRITE) {
            g_m.v_bad_frame++;
            g_m.st = SL_SKIP;
        } else {
            g_m.wdata = 0u;
            g_m.st = SL_DATA;
        }
        break;
    case SL_DATA:
        g_m.nbits++;
        if (g_m.is_read) {
            if (g_m.nbits == 16u) {
                if (g_m.respond) {
                    schedule(0, 1);
                    g_m.frames_read++;
                    if (g_m.is_c45 && g_m.op == RTLNET_MDIO_C45_OP_READ_INC) {
                        g_m.mmd_addr[g_m.reg]++;
                    }
                }
                g_m.st = SL_PRE;
                g_m.ones = 0u;
                g_m.need_idle = 1;
            } else if (g_m.respond) {
                schedule(1, (g_m.shreg >> 15) & 1u);
                g_m.shreg = (uint16_t)(g_m.shreg << 1);
            }
        } else {
            g_m.wdata = (uint16_t)((g_m.wdata << 1) | (uint32_t)line);
            if (g_m.nbits == 16u) {
                if (g_m.respond) {
                    if (!g_m.is_c45) {
                        reg_write(g_m.reg, g_m.wdata);
                    } else if (g_m.op == RTLNET_MDIO_C45_OP_ADDR) {
                        g_m.mmd_addr[g_m.reg] = g_m.wdata;
                    } else {
                        mmd_write(g_m.reg, g_m.mmd_addr[g_m.reg], g_m.wdata);
                    }
                    g_m.frames_write++;
                }
                g_m.st = SL_PRE;
                g_m.ones = 0u;
                g_m.need_idle = 1;
            }
        }
        break;
    default:
        if (line) {
            if (++g_m.ones >= 16u) {
                g_m.st = SL_PRE;
            }
        } else {
            g_m.ones = 0u;
        }
        break;
    }
}

static void contention_check(void)
{
    if (g_m.oe && g_m.phy_oe) {
        g_m.v_contention++;
    }
}

/* Pins written by CTRL or BITBANG. */
static void pins_write(uint32_t mdc, uint32_t oe, uint32_t out)
{
    int drive_changed = (oe != g_m.oe) || (oe && out != g_m.out);
    int rising = (mdc && !g_m.mdc);
    int falling = (!mdc && g_m.mdc);

    if (g_m.need_idle && (oe || rising)) {
        if (!g_m.idle_valid || g_m.now - g_m.t_idle < T_PERIOD_MIN_NS) {
            g_m.v_idle++;
        }
        g_m.need_idle = 0;
    }
    if (drive_changed) {
        if (g_m.mdc && mdc) {
            g_m.v_setup++;            /* change while MDC high */
        } else if (rising) {
            g_m.v_setup++;            /* change on the rising edge */
        } else if (g_m.have_rise && g_m.now - g_m.t_rise < T_HOLD_NS) {
            g_m.v_hold++;
        }
    }
    g_m.mdc = mdc;
    g_m.oe = oe;
    g_m.out = out;
    if (!mdc && !oe) {
        if (!g_m.idle_valid) {
            g_m.idle_valid = 1;
            g_m.t_idle = g_m.now;
        }
    } else {
        g_m.idle_valid = 0;
    }
    if (rising) {
        if (g_m.have_rise && g_m.now - g_m.t_rise < T_PERIOD_MIN_NS) {
            g_m.v_period++;
        }
        if (g_m.now - g_m.t_fall < T_LOW_MIN_NS) {
            g_m.v_low++;
        }
        g_m.have_rise = 1;
        g_m.t_rise = g_m.now;
        slave_rise(line_level());
    }
    if (falling) {
        if (g_m.now - g_m.t_rise < T_HIGH_MIN_NS) {
            g_m.v_high++;
        }
        g_m.t_fall = g_m.now;
    }
    contention_check();
}

/* Common per-event update: time, reset, PHY output, link. */
static void event(void)
{
    g_m.now += ACCESS_NS;
    reset_eval();
    apply_pending();
    if (!g_m.in_reset) {
        link_eval();
    }
    contention_check();
}

static uint32_t sample_line(void)
{
    int lvl = line_level();

    if (g_m.pend && g_m.now < g_m.pend_t) {
        int nxt = g_m.oe ? lvl : (g_m.pend_oe ? g_m.pend_val : 1);
        if (nxt != lvl) {
            g_m.v_early++;
        }
    }
    return (uint32_t)lvl;
}

/* -------------------------------------------------------------------------
 * Hooks required by rtlnet_mmio.h (RTLNET_HOST_TEST) and rtlnet_mdio.c
 * ------------------------------------------------------------------------- */
uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TB_BASE);
    uint32_t v = 0u;

    event();
    switch (off) {
    case RTLNET_MDIO_REG_ID:
        v = g_m.core_id_bad ? 0x12345678u : RTLNET_MDIO_ID_VALUE;
        break;
    case RTLNET_MDIO_REG_VERSION:
        v = RTLNET_MDIO_VERSION_VALUE;
        break;
    case RTLNET_MDIO_REG_CAPS:
        v = (TB_POR_MS << RTLNET_MDIO_CAPS_POR_MS_SHIFT) | TB_CLK_KHZ;
        break;
    case RTLNET_MDIO_REG_CTRL:
        v = (g_m.mdc ? RTLNET_MDIO_CTRL_MDC : 0u) | (g_m.oe ? RTLNET_MDIO_CTRL_MDIO_OE : 0u) |
            (g_m.out ? RTLNET_MDIO_CTRL_MDIO_OUT : 0u) | (g_m.phy_reset_bit ? RTLNET_MDIO_CTRL_PHY_RESET : 0u) |
            (g_m.irq_en ? RTLNET_MDIO_CTRL_IRQ_EN : 0u);
        break;
    case RTLNET_MDIO_REG_STATUS:
        v = sample_line();
        v |= ((g_m.insr & g_m.iner) != 0u && !g_m.in_reset) ? RTLNET_MDIO_STATUS_PHY_INT : 0u;
        v |= por_done() ? RTLNET_MDIO_STATUS_POR_DONE : 0u;
        v |= g_m.in_reset ? RTLNET_MDIO_STATUS_PHY_RESET_ACTIVE : 0u;
        break;
    case RTLNET_MDIO_REG_BITBANG:
        v = sample_line();
        break;
    default:
        v = 0u;
        break;
    }
    return v;
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TB_BASE);

    event();
    if (off == RTLNET_MDIO_REG_CTRL || off == RTLNET_MDIO_REG_BITBANG) {
        pins_write(value & RTLNET_MDIO_CTRL_MDC, (value & RTLNET_MDIO_CTRL_MDIO_OE) ? 1u : 0u,
                   (value & RTLNET_MDIO_CTRL_MDIO_OUT) ? 1u : 0u);
    }
    if (off == RTLNET_MDIO_REG_CTRL) {
        uint32_t rb = (value & RTLNET_MDIO_CTRL_PHY_RESET) ? 1u : 0u;
        if (g_m.phy_reset_bit && !rb) {
            g_m.reset_bit_clear_t = g_m.now;
        }
        g_m.phy_reset_bit = rb;
        g_m.irq_en = (value & RTLNET_MDIO_CTRL_IRQ_EN) ? 1u : 0u;
        reset_eval();
    }
}

void rtlnet_host_spin(uint32_t loops)
{
    g_m.now += SPIN_NS + (unsigned long long)loops * LOOP_NS;
}

static void tb_delay_us(void *user, uint32_t us)
{
    (void)user;
    g_m.now += (unsigned long long)us * 1000ull;
}

static uint32_t tb_now_ticks(void *user)
{
    (void)user;
    if (g_m.timer_stuck) {
        return 1234u;
    }
    return (uint32_t)(g_m.now / TIMER_NS_PER_TICK);
}

static unsigned g_hook_calls;
static void tb_half_hook(void *user)
{
    (void)user;
    g_hook_calls++;
    g_m.now += 300u;
}

/* -------------------------------------------------------------------------
 * Test helpers
 * ------------------------------------------------------------------------- */
static rtlnet_mdio_t g_ctx;

static void model_reset(void)
{
    memset(&g_m, 0, sizeof g_m);
    g_m.cable = 1;
    g_m.partner_adv = RTLNET_PHY_ADV_ALL;
    g_m.phy_addr = RTLNET_PHY_RTL8211E_ADDR_DEFAULT;
    g_m.mmd_present = (1u << 1) | (1u << 3) | (1u << RTLNET_PHY_MMD_AN);
    g_m.in_reset = 1;                       /* power-on: PHYRSTB low from time 0 */
    g_m.min_reset_low = ~0ull;
    g_m.idle_valid = 1;
    phy_defaults();
}

static unsigned violations(void)
{
    return g_m.v_period + g_m.v_high + g_m.v_low + g_m.v_setup + g_m.v_hold + g_m.v_early +
           g_m.v_contention + g_m.v_short_pre + g_m.v_bad_frame + g_m.v_idle + g_m.v_in_reset +
           g_m.v_settle + g_m.v_reset_short;
}

static void check_clean(const char *where)
{
    char buf[200];

    snprintf(buf, sizeof buf,
             "%s: bus rule violations period %u high %u low %u setup %u hold %u early %u contention %u "
             "preamble %u frame %u idle %u in-reset %u settle %u reset-low %u",
             where, g_m.v_period, g_m.v_high, g_m.v_low, g_m.v_setup, g_m.v_hold, g_m.v_early,
             g_m.v_contention, g_m.v_short_pre, g_m.v_bad_frame, g_m.v_idle, g_m.v_in_reset, g_m.v_settle,
             g_m.v_reset_short);
    check(violations() == 0u, buf);
}

/* Fresh model, driver bound, calibrated, PHY out of POR and settled. */
static void fresh(void)
{
    uint32_t half_ns = 0u;
    int rc;

    model_reset();
    rc = rtlnet_mdio_init(&g_ctx, TB_BASE, RTLNET_PHY_RTL8211E_ADDR_DEFAULT, tb_delay_us, NULL);
    check(rc == RTLNET_MDIO_OK, "fresh: init");
    rc = rtlnet_mdio_calibrate(&g_ctx, tb_now_ticks, 100u, &half_ns);
    check(rc == RTLNET_MDIO_OK, "fresh: calibrate");
    rc = rtlnet_mdio_wait_por(&g_ctx);
    check(rc == RTLNET_MDIO_OK, "fresh: wait_por");
}

/* Advance time until the model link has had time to come up, polling status. */
static int wait_link(rtlnet_phy_status_t *st, unsigned max_polls)
{
    for (unsigned i = 0u; i < max_polls; i++) {
        int rc = rtlnet_phy_rtl8211e_status(&g_ctx, st);
        if (rc != RTLNET_PHY_OK) {
            return rc;
        }
        if (st->speed_valid) {
            return RTLNET_PHY_OK;
        }
        tb_delay_us(NULL, 500u);
    }
    return RTLNET_PHY_ERR_TIMEOUT;
}

/* -------------------------------------------------------------------------
 * Tests
 * ------------------------------------------------------------------------- */
static void test_core(void)
{
    rtlnet_mdio_t c;
    int rc;

    model_reset();
    check(rtlnet_mdio_init(NULL, TB_BASE, 1u, tb_delay_us, NULL) == RTLNET_MDIO_ERR_ARG, "init NULL ctx");
    check(rtlnet_mdio_init(&c, TB_BASE, 32u, tb_delay_us, NULL) == RTLNET_MDIO_ERR_ARG, "init PHYAD 32");
    check(rtlnet_mdio_init(&c, TB_BASE, 1u, NULL, NULL) == RTLNET_MDIO_ERR_NO_DELAY, "init without delay_us");
    g_m.core_id_bad = 1;
    check(rtlnet_mdio_init(&c, TB_BASE, 1u, tb_delay_us, NULL) == RTLNET_MDIO_ERR_CORE_ID, "init wrong core ID");
    g_m.core_id_bad = 0;
    rc = rtlnet_mdio_init(&c, TB_BASE, 1u, tb_delay_us, NULL);
    check(rc == RTLNET_MDIO_OK, "init OK");
    checkf(c.half_loops == 26u, "default half_loops %u, expected %u", c.half_loops, 26u);
    check(g_m.mdc == 0u && g_m.oe == 0u, "init leaves the bus idle");
    check(rtlnet_mdio_caps_clk_khz(&c) == TB_CLK_KHZ, "CAPS clock kHz");
    check(rtlnet_mdio_caps_por_ms(&c) == TB_POR_MS, "CAPS POR ms");

    /* POR wait: returns after POR_DONE plus the settle time. */
    rc = rtlnet_mdio_wait_por(&c);
    check(rc == RTLNET_MDIO_OK, "wait_por OK");
    check(g_m.now >= (TB_POR_MS * 1000000ull) + SETTLE_NS, "wait_por waits POR and 30 ms settle");
    check(g_m.now <= (TB_POR_MS * 1000000ull) + 2ull * 1000000ull + RTLNET_MDIO_RESET_SETTLE_US * 1000ull,
          "wait_por does not overshoot");

    model_reset();
    g_m.por_stuck = 1;
    rc = rtlnet_mdio_init(&c, TB_BASE, 1u, tb_delay_us, NULL);
    check(rtlnet_mdio_wait_por(&c) == RTLNET_MDIO_ERR_TIMEOUT, "wait_por times out when POR_DONE never sets");
    check(g_m.now <= (RTLNET_MDIO_POR_POLL_MAX + 2u) * 1000000ull, "wait_por bounded");
    (void)rc;
}

static void test_calibrate(void)
{
    uint32_t half_ns = 0u;
    rtlnet_mdio_t c;

    model_reset();
    check(rtlnet_mdio_init(&c, TB_BASE, 1u, tb_delay_us, NULL) == RTLNET_MDIO_OK, "cal: init");
    check(rtlnet_mdio_calibrate(&c, tb_now_ticks, 100u, &half_ns) == RTLNET_MDIO_OK, "calibrate OK");
    /* base = ACCESS + SPIN = 64 ns, 64 loops = 512 ns -> ceil(186 * 64 / 512) = 24 loops. */
    checkf(c.half_loops == 24u, "calibrated half_loops %u, expected %u", c.half_loops, 24u);
    checkf(half_ns >= RTLNET_MDIO_HALF_MIN_NS && half_ns <= 300u, "calibrated half %u ns (min %u)", half_ns,
           RTLNET_MDIO_HALF_MIN_NS);
    check(g_m.mdc == 0u && g_m.oe == 0u && !g_m.have_rise, "calibration produces no MDC edge");
    check(rtlnet_mdio_calibrate(&c, NULL, 100u, &half_ns) == RTLNET_MDIO_ERR_ARG, "calibrate NULL timer");
    check(rtlnet_mdio_calibrate(&c, tb_now_ticks, 0u, &half_ns) == RTLNET_MDIO_ERR_ARG, "calibrate 0 ticks/us");
    g_m.timer_stuck = 1;
    check(rtlnet_mdio_calibrate(&c, tb_now_ticks, 100u, &half_ns) == RTLNET_MDIO_ERR_CALIBRATE,
          "calibrate with a stopped timer");
    checkf(c.half_loops == 24u, "failed calibration keeps half_loops (%u, %u)", c.half_loops, 24u);
}

static void test_frames(void)
{
    uint16_t v = 0u;
    unsigned long long t0;
    unsigned long long dt;

    fresh();
    check_clean("after bring-up");
    t0 = g_m.now;
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID1, &v) == RTLNET_MDIO_OK, "read PHYID1 OK");
    checkf(v == 0x001Cu, "PHYID1 = 0x%04x, expected 0x%04x", v, 0x001Cu);
    dt = g_m.now - t0;
    checkf(dt >= 65u * 400u && dt <= 65u * 1000u, "read frame %u ns (65 slots, %u ns minimum)", (unsigned)dt,
           65u * 400u);
    checkf(g_m.last_pre == 32u, "preamble %u ones, expected %u", g_m.last_pre, 32u);
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID2, &v) == RTLNET_MDIO_OK, "read PHYID2 OK");
    checkf(v == 0xC915u, "PHYID2 = 0x%04x, expected 0x%04x", v, 0xC915u);
    check(rtlnet_mdio_write(&g_ctx, RTLNET_PHY_REG_INER, 0xA55Au) == RTLNET_MDIO_OK, "write INER");
    checkf(g_m.iner == 0xA55Au, "model INER 0x%04x, expected 0x%04x", g_m.iner, 0xA55Au);
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_INER, &v) == RTLNET_MDIO_OK && v == 0xA55Au, "read back INER");
    check(rtlnet_mdio_write(&g_ctx, RTLNET_PHY_REG_INER, 0x0000u) == RTLNET_MDIO_OK, "clear INER");
    checkf(g_m.frames_read == 3u && g_m.frames_write == 2u, "frames read %u write %u", g_m.frames_read,
           g_m.frames_write);
    check(g_m.mdc == 0u && g_m.oe == 0u, "bus idle after frames");
    check_clean("frames");

    /* Argument checks. */
    check(rtlnet_mdio_read(&g_ctx, 32u, &v) == RTLNET_MDIO_ERR_ARG, "read reg 32 rejected");
    check(rtlnet_mdio_read(&g_ctx, 1u, NULL) == RTLNET_MDIO_ERR_ARG, "read NULL value rejected");
    check(rtlnet_mdio_write(&g_ctx, 40u, 0u) == RTLNET_MDIO_ERR_ARG, "write reg 40 rejected");
    check(rtlnet_mdio_read_addr(&g_ctx, 33u, 1u, &v) == RTLNET_MDIO_ERR_ARG, "read PHYAD 33 rejected");
    check(rtlnet_mdio_read(NULL, 1u, &v) == RTLNET_MDIO_ERR_ARG, "read NULL ctx rejected");

    /* Another address: nobody answers. */
    v = 0u;
    check(rtlnet_mdio_read_addr(&g_ctx, 2u, RTLNET_PHY_REG_PHYID1, &v) == RTLNET_MDIO_ERR_NO_PHY,
          "read PHYAD 2 reports no PHY");
    checkf(v == 0xFFFFu, "no-PHY read value 0x%04x, expected 0x%04x", v, 0xFFFFu);
    checkf(g_m.frames_ignored == 1u, "slave ignored %u frames, expected %u", g_m.frames_ignored, 1u);
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID1, &v) == RTLNET_MDIO_OK && v == 0x001Cu,
          "read after a no-PHY frame");

    /* Half-period hook replaces the spin. */
    g_hook_calls = 0u;
    rtlnet_mdio_set_half_delay(&g_ctx, tb_half_hook);
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID2, &v) == RTLNET_MDIO_OK && v == 0xC915u,
          "read with half_delay hook");
    checkf(g_hook_calls == 2u * 65u, "half_delay calls %u, expected %u", g_hook_calls, 2u * 65u);
    rtlnet_mdio_set_half_delay(&g_ctx, NULL);
    check_clean("no-PHY address and hook");
}

static void test_timing_negative(void)
{
    uint16_t v;

    /* A half period below the minimum must be caught by the model. */
    fresh();
    rtlnet_mdio_set_half_loops(&g_ctx, 0u);
    (void)rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID1, &v);
    check(g_m.v_period > 0u && g_m.v_high > 0u && g_m.v_low > 0u, "model flags MDC timing below Table 61");
    check(g_m.v_early > 0u, "model flags samples earlier than t6");
}

static void test_no_phy(void)
{
    uint16_t v = 0u;
    uint32_t id = 0u;
    rtlnet_phy_status_t st;

    fresh();
    g_m.phy_absent = 1;
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_BMSR, &v) == RTLNET_MDIO_ERR_NO_PHY, "no PHY: read error");
    checkf(v == 0xFFFFu, "no PHY: value 0x%04x, expected 0x%04x", v, 0xFFFFu);
    check(rtlnet_phy_rtl8211e_probe(&g_ctx, &id) == RTLNET_MDIO_ERR_NO_PHY, "no PHY: probe");
    check(rtlnet_phy_rtl8211e_status(&g_ctx, &st) == RTLNET_MDIO_ERR_NO_PHY, "no PHY: status error, no phantom link");
    check(rtlnet_phy_rtl8211e_init(&g_ctx) == RTLNET_MDIO_ERR_NO_PHY, "no PHY: init");
    check_clean("no PHY");
}

static void test_probe_and_delay(void)
{
    uint32_t id = 0u;
    uint16_t before = 0u;
    uint16_t after = 0u;

    fresh();
    check(rtlnet_phy_rtl8211e_probe(&g_ctx, &id) == RTLNET_PHY_OK, "probe OK");
    checkf(id == 0x001CC915u, "PHY ID 0x%08x, expected 0x%08x", id, 0x001CC915u);
    check(rtlnet_phy_rtl8211e_probe(NULL, &id) == RTLNET_PHY_ERR_ARG, "probe NULL");

    check(rtlnet_phy_rtl8211e_enable_rx_delay(&g_ctx, &before, &after) == RTLNET_PHY_OK, "RX delay OK");
    checkf(before == 0x8575u, "reg 28 before 0x%04x, expected 0x%04x", before, 0x8575u);
    checkf(after == 0xAD75u, "reg 28 after 0x%04x, expected 0x%04x", after, 0xAD75u);
    checkf(g_m.r28 == 0xAD75u, "model reg 28 0x%04x, expected 0x%04x", g_m.r28, 0xAD75u);
    checkf(g_m.pagsel == 0u, "PAGSEL back to 0 (0x%04x, %u)", g_m.pagsel, 0u);
    check_clean("probe and RX delay");

    /* TX delay set before: the read-modify-write clears it, keeps bits 10:0. */
    g_m.pagsel = 0u;
    g_m.r28 = 0x1234u;
    check(rtlnet_phy_rtl8211e_enable_rx_delay(&g_ctx, &before, &after) == RTLNET_PHY_OK, "RX delay from 0x1234");
    checkf(g_m.r28 == 0x2A34u, "reg 28 0x%04x, expected 0x%04x (bit 12 cleared, 10:0 kept)", g_m.r28, 0x2A34u);

    /* Wrong identity. */
    fresh();
    g_m.wrong_id = 1;
    check(rtlnet_phy_rtl8211e_probe(&g_ctx, &id) == RTLNET_PHY_ERR_ID, "wrong ID rejected");
    checkf(id == 0x001CC916u, "wrong ID reported 0x%08x (%u)", id, 0u);
    check(rtlnet_phy_rtl8211e_init(&g_ctx) == RTLNET_PHY_ERR_ID, "init stops on wrong ID");
    checkf(g_m.r28 == 0x8575u, "init with wrong ID leaves reg 28 (0x%04x, 0x%04x)", g_m.r28, 0x8575u);

    /* Register 28 does not stick. */
    fresh();
    g_m.r28_stuck = 1;
    check(rtlnet_phy_rtl8211e_enable_rx_delay(&g_ctx, &before, &after) == RTLNET_PHY_ERR_VERIFY,
          "reg 28 not sticking reported");
    checkf(after == 0x8575u, "readback 0x%04x, expected 0x%04x", after, 0x8575u);
    checkf(g_m.pagsel == 0u, "PAGSEL back to 0 after a failed verify (0x%04x, %u)", g_m.pagsel, 0u);
    check(rtlnet_phy_rtl8211e_init(&g_ctx) == RTLNET_PHY_ERR_VERIFY, "init reports the verify failure");
    check_clean("ID and reg 28 faults");
}

static void test_hw_reset(void)
{
    uint16_t v = 0u;
    unsigned long long t0;

    fresh();
    check(rtlnet_phy_rtl8211e_init(&g_ctx) == RTLNET_PHY_OK, "init before hardware reset");
    checkf(g_m.r28 == 0xAD75u, "reg 28 set (0x%04x, 0x%04x)", g_m.r28, 0xAD75u);
    t0 = g_m.now;
    g_m.min_reset_low = ~0ull;
    check(rtlnet_mdio_phy_reset(&g_ctx) == RTLNET_MDIO_OK, "phy_reset OK");
    check(g_m.min_reset_low >= RESET_LOW_MIN_NS && g_m.min_reset_low < 25000000ull,
          "PHY reset low between 10 ms and 25 ms");
    check(g_m.now - t0 >= RESET_LOW_MIN_NS + SETTLE_NS, "phy_reset covers low and settle time");
    check(g_m.phy_reset_bit == 0u && !g_m.in_reset, "PHY released after phy_reset");
    checkf(g_m.r28 == 0x8575u, "hardware reset clears reg 28 (0x%04x, 0x%04x)", g_m.r28, 0x8575u);
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID1, &v) == RTLNET_MDIO_OK && v == 0x001Cu,
          "PHY answers after reset and settle");
    check(rtlnet_phy_rtl8211e_init(&g_ctx) == RTLNET_PHY_OK, "init again after hardware reset");
    check_clean("hardware reset");

    /* Negative control of the model: a 5 ms reset pulse and an access right
     * after release, inside the settle window. */
    rtlnet_host_reg_write32(TB_BASE + RTLNET_MDIO_REG_CTRL, RTLNET_MDIO_CTRL_PHY_RESET);
    tb_delay_us(NULL, 5000u);
    rtlnet_host_reg_write32(TB_BASE + RTLNET_MDIO_REG_CTRL, 0u);
    check(g_m.v_reset_short == 1u, "model flags a reset pulse shorter than 10 ms");
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID1, &v) == RTLNET_MDIO_ERR_NO_PHY,
          "PHY silent during the settle window");
    check(g_m.v_settle > 0u, "model flags access inside the 30 ms settle window");
}

static void test_soft_reset(void)
{
    unsigned reads;

    fresh();
    check(rtlnet_phy_rtl8211e_soft_reset(&g_ctx) == RTLNET_PHY_OK, "soft reset OK");
    check((g_m.bmcr & RTLNET_PHY_BMCR_RESET) == 0u, "BMCR reset bit cleared");
    checkf(g_m.bmcr == 0x1140u, "BMCR after soft reset 0x%04x, expected 0x%04x", g_m.bmcr, 0x1140u);
    check_clean("soft reset");

    fresh();
    g_m.reset_stuck = 1;
    reads = g_m.bmcr_reads;
    check(rtlnet_phy_rtl8211e_soft_reset(&g_ctx) == RTLNET_PHY_ERR_TIMEOUT, "stuck reset bit times out");
    checkf(g_m.bmcr_reads - reads == RTLNET_PHY_RESET_POLL_MAX + 1u, "BMCR reads %u, bound %u",
           g_m.bmcr_reads - reads, RTLNET_PHY_RESET_POLL_MAX + 1u);
}

static void test_autoneg(void)
{
    rtlnet_phy_status_t st;
    uint32_t adv = 0u;

    fresh();
    check(rtlnet_phy_rtl8211e_init(&g_ctx) == RTLNET_PHY_OK, "AN: init");
    check(rtlnet_phy_rtl8211e_advertise_get(&g_ctx, &adv) == RTLNET_PHY_OK, "advertise_get");
    checkf(adv == (RTLNET_PHY_ADV_ALL & ~RTLNET_PHY_ADV_1000H), "default advertisement 0x%02x, expected 0x%02x",
           adv, RTLNET_PHY_ADV_ALL & ~RTLNET_PHY_ADV_1000H);

    /* Partner: a 10/100 router. */
    g_m.partner_adv = RTLNET_PHY_ADV_10H | RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100H | RTLNET_PHY_ADV_100F;
    check(rtlnet_phy_rtl8211e_autoneg_restart(&g_ctx) == RTLNET_PHY_OK, "AN restart");
    check((g_m.bmcr & RTLNET_PHY_BMCR_RESTART_AN) == 0u, "Restart_AN self-clears in the model");
    check(rtlnet_phy_rtl8211e_status(&g_ctx, &st) == RTLNET_PHY_OK, "status during AN");
    check(!st.link_up && !st.speed_valid && !st.an_complete, "no link while AN runs");
    check(wait_link(&st, 20u) == RTLNET_PHY_OK, "link after AN");
    checkf(st.speed == RTLNET_PHY_SPEED_100 && st.full_duplex, "AN result speed %u duplex %u (100 full)",
           st.speed, st.full_duplex);
    check(st.an_enabled && st.an_complete && st.resolved, "AN enabled/complete/resolved");
    checkf(st.partner_adv == g_m.partner_adv, "partner abilities 0x%02x, expected 0x%02x", st.partner_adv,
           g_m.partner_adv);
    checkf(st.physr == 0x6C00u, "PHYSR 0x%04x, expected 0x%04x", st.physr, 0x6C00u);
    check(rtlnet_phy_speed_mbps(st.speed) == 100u, "speed code to Mb/s");

    /* Advertise 10 only; the half-duplex bit in the mask is written 0. */
    check(rtlnet_phy_rtl8211e_advertise_set(&g_ctx, RTLNET_PHY_ADV_10H | RTLNET_PHY_ADV_10F) == RTLNET_PHY_OK,
          "advertise 10H/10F");
    checkf((g_m.anar & RTLNET_PHY_ANAR_TECH_MASK) == RTLNET_PHY_ANAR_10F,
           "ANAR tech bits 0x%04x, expected 0x%04x (10F only, no half duplex)", g_m.anar & RTLNET_PHY_ANAR_TECH_MASK,
           RTLNET_PHY_ANAR_10F);
    checkf((g_m.anar & 0x0C1Fu) == 0x0401u, "ANAR pause/selector kept 0x%04x (0x%04x)", g_m.anar & 0x0C1Fu,
           0x0401u);
    checkf((g_m.gbcr & RTLNET_PHY_GBCR_TECH_MASK) == 0u, "GBCR tech bits 0x%04x (%u)", g_m.gbcr, 0u);
    check(rtlnet_phy_rtl8211e_advertise_get(&g_ctx, &adv) == RTLNET_PHY_OK &&
          adv == RTLNET_PHY_ADV_10F, "advertise_get after set");
    check(rtlnet_phy_rtl8211e_autoneg_restart(&g_ctx) == RTLNET_PHY_OK, "AN restart (10)");
    check(wait_link(&st, 20u) == RTLNET_PHY_OK, "link at 10");
    checkf(st.speed == RTLNET_PHY_SPEED_10 && st.full_duplex, "speed %u duplex %u (10 full)", st.speed,
           st.full_duplex);

    /* Gigabit partner, advertise everything. */
    g_m.partner_adv = RTLNET_PHY_ADV_ALL & ~RTLNET_PHY_ADV_1000H;
    check(rtlnet_phy_rtl8211e_advertise_set(&g_ctx, RTLNET_PHY_ADV_ALL) == RTLNET_PHY_OK, "advertise all");
    checkf((g_m.gbcr & RTLNET_PHY_GBCR_TECH_MASK) == RTLNET_PHY_GBCR_1000F, "GBCR 0x%04x (1000F only, 0x%04x)",
           g_m.gbcr, RTLNET_PHY_GBCR_1000F);
    checkf((g_m.anar & RTLNET_PHY_ANAR_TECH_MASK) == (RTLNET_PHY_ANAR_10F | RTLNET_PHY_ANAR_100F),
           "ANAR after advertise all 0x%04x (10F/100F only, 0x%04x)", g_m.anar & RTLNET_PHY_ANAR_TECH_MASK,
           RTLNET_PHY_ANAR_10F | RTLNET_PHY_ANAR_100F);
    check(rtlnet_phy_rtl8211e_autoneg_restart(&g_ctx) == RTLNET_PHY_OK, "AN restart (1000)");
    check(wait_link(&st, 20u) == RTLNET_PHY_OK, "link at 1000");
    checkf(st.speed == RTLNET_PHY_SPEED_1000 && st.full_duplex, "speed %u duplex %u (1000 full)", st.speed,
           st.full_duplex);
    check((st.partner_adv & RTLNET_PHY_ADV_1000F) != 0u, "partner 1000F from GBSR");
    check(rtlnet_phy_speed_mbps(st.speed) == 1000u, "speed 1000 Mb/s");

    /* No common ability: no link. */
    g_m.partner_adv = RTLNET_PHY_ADV_100H;
    check(rtlnet_phy_rtl8211e_advertise_set(&g_ctx, RTLNET_PHY_ADV_10F) == RTLNET_PHY_OK, "advertise 10F");
    check(rtlnet_phy_rtl8211e_autoneg_restart(&g_ctx) == RTLNET_PHY_OK, "AN restart (no common)");
    check(wait_link(&st, 10u) == RTLNET_PHY_ERR_TIMEOUT, "no common mode: no link");
    check(!st.speed_valid && !st.link_up, "no common mode: speed not valid");

    /* Argument checks. */
    check(rtlnet_phy_rtl8211e_advertise_set(&g_ctx, 0u) == RTLNET_PHY_ERR_ARG, "advertise nothing rejected");
    check(rtlnet_phy_rtl8211e_advertise_set(&g_ctx, RTLNET_PHY_ADV_10H | RTLNET_PHY_ADV_100H | RTLNET_PHY_ADV_1000H) ==
          RTLNET_PHY_ERR_ARG, "advertise half duplex only rejected");
    check(rtlnet_phy_rtl8211e_advertise_set(&g_ctx, 0x40u) == RTLNET_PHY_ERR_ARG, "advertise unknown bit rejected");
    check(rtlnet_phy_rtl8211e_advertise_get(&g_ctx, NULL) == RTLNET_PHY_ERR_ARG, "advertise_get NULL");
    check(rtlnet_phy_rtl8211e_status(&g_ctx, NULL) == RTLNET_PHY_ERR_ARG, "status NULL");
    check_clean("auto-negotiation");
}

static void test_forced_and_loopback(void)
{
    rtlnet_phy_status_t st;
    uint16_t regs[RTLNET_PHY_NUM_REGS];

    fresh();
    check(rtlnet_phy_rtl8211e_force(&g_ctx, RTLNET_PHY_SPEED_100, 1) == RTLNET_PHY_OK, "force 100 full");
    checkf((g_m.bmcr & (RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_SPEED0 | RTLNET_PHY_BMCR_SPEED1 |
                        RTLNET_PHY_BMCR_DUPLEX)) == (RTLNET_PHY_BMCR_SPEED0 | RTLNET_PHY_BMCR_DUPLEX),
           "BMCR forced 100 full 0x%04x (0x%04x)", g_m.bmcr, RTLNET_PHY_BMCR_SPEED0 | RTLNET_PHY_BMCR_DUPLEX);
    check(wait_link(&st, 20u) == RTLNET_PHY_OK, "forced link");
    check(st.speed == RTLNET_PHY_SPEED_100 && st.full_duplex && !st.an_enabled, "forced status 100 full, AN off");
    check(rtlnet_phy_rtl8211e_force(&g_ctx, RTLNET_PHY_SPEED_10, 0) == RTLNET_PHY_OK, "force 10 half");
    checkf((g_m.bmcr & (RTLNET_PHY_BMCR_ANE | RTLNET_PHY_BMCR_SPEED0 | RTLNET_PHY_BMCR_SPEED1 |
                        RTLNET_PHY_BMCR_DUPLEX)) == 0u, "BMCR forced 10 half 0x%04x (%u)", g_m.bmcr, 0u);
    check(wait_link(&st, 20u) == RTLNET_PHY_OK && st.speed == RTLNET_PHY_SPEED_10 && !st.full_duplex,
          "forced status 10 half");
    check(rtlnet_phy_rtl8211e_force(&g_ctx, RTLNET_PHY_SPEED_1000, 1) == RTLNET_PHY_ERR_ARG, "force 1000 rejected");
    check(rtlnet_phy_rtl8211e_force(&g_ctx, 7u, 1) == RTLNET_PHY_ERR_ARG, "force bad code rejected");
    check(rtlnet_phy_rtl8211e_autoneg_restart(&g_ctx) == RTLNET_PHY_OK, "back to AN");
    check((g_m.bmcr & RTLNET_PHY_BMCR_ANE) != 0u, "ANE set again");

    check(rtlnet_phy_rtl8211e_loopback(&g_ctx, 1) == RTLNET_PHY_OK, "loopback on");
    check((g_m.bmcr & RTLNET_PHY_BMCR_LOOPBACK) != 0u, "BMCR loopback bit set");
    check(rtlnet_phy_rtl8211e_loopback(&g_ctx, 0) == RTLNET_PHY_OK, "loopback off");
    check((g_m.bmcr & RTLNET_PHY_BMCR_LOOPBACK) == 0u, "BMCR loopback bit clear");

    check(wait_link(&st, 20u) == RTLNET_PHY_OK, "link before dump");
    memset(regs, 0, sizeof regs);
    check(rtlnet_phy_rtl8211e_dump(&g_ctx, regs) == RTLNET_PHY_OK, "dump OK");
    checkf(regs[2] == 0x001Cu && regs[3] == 0xC915u, "dump IDs 0x%04x 0x%04x", regs[2], regs[3]);
    checkf(regs[17] == 0xAC00u, "dump PHYSR 0x%04x, expected 0x%04x", regs[17], 0xAC00u);
    checkf(regs[31] == 0u && regs[0] == g_m.bmcr, "dump PAGSEL %u BMCR 0x%04x", regs[31], regs[0]);
    check(rtlnet_phy_rtl8211e_dump(&g_ctx, NULL) == RTLNET_PHY_ERR_ARG, "dump NULL");
    g_m.phy_absent = 1;
    check(rtlnet_phy_rtl8211e_dump(&g_ctx, regs) == RTLNET_MDIO_ERR_NO_PHY && regs[5] == 0xFFFFu,
          "dump without PHY fills 0xFFFF and reports");
    g_m.phy_absent = 0;
    check_clean("forced, loopback, dump");
}

static void test_link_and_irq(void)
{
    rtlnet_phy_status_t st;
    uint16_t insr = 0u;

    fresh();
    check(rtlnet_phy_rtl8211e_init(&g_ctx) == RTLNET_PHY_OK, "irq: init");
    check(wait_link(&st, 20u) == RTLNET_PHY_OK, "irq: link up");
    check(rtlnet_phy_rtl8211e_irq_ack(&g_ctx, &insr) == RTLNET_PHY_OK, "irq: clear INSR");
    check(rtlnet_phy_rtl8211e_irq_config(&g_ctx, RTLNET_PHY_INT_LINK_CHANGE) == RTLNET_PHY_OK, "irq: INER");
    rtlnet_mdio_irq_enable(&g_ctx, 1);
    check(g_m.irq_en == 1u, "CTRL.IRQ_EN set");
    check(g_m.phy_reset_bit == 0u, "IRQ enable keeps PHY_RESET clear");
    check(!rtlnet_mdio_phy_int_asserted(&g_ctx), "no interrupt before the link changes");

    g_m.cable = 0;    /* unplug */
    check(rtlnet_phy_rtl8211e_status(&g_ctx, &st) == RTLNET_PHY_OK, "status after unplug");
    check(!st.link_up && !st.speed_valid, "link down after unplug");
    check(rtlnet_mdio_phy_int_asserted(&g_ctx), "PHY interrupt asserted on link change");
    check(rtlnet_phy_rtl8211e_irq_ack(&g_ctx, &insr) == RTLNET_PHY_OK, "irq ack");
    check((insr & RTLNET_PHY_INT_LINK_CHANGE) != 0u, "INSR link change bit");
    check(!rtlnet_mdio_phy_int_asserted(&g_ctx), "INTB released after INSR read");
    check(rtlnet_phy_rtl8211e_irq_ack(&g_ctx, NULL) == RTLNET_PHY_ERR_ARG, "irq_ack NULL");

    g_m.cable = 1;    /* plug back in: the PHY renegotiates */
    g_m.link_at = g_m.now + AN_TIME_NS;
    check(wait_link(&st, 20u) == RTLNET_PHY_OK && st.speed == RTLNET_PHY_SPEED_1000, "link back at 1000");
    rtlnet_mdio_irq_enable(&g_ctx, 0);
    check(g_m.irq_en == 0u, "CTRL.IRQ_EN cleared");
    check(rtlnet_phy_rtl8211e_irq_config(NULL, 0u) == RTLNET_PHY_ERR_ARG, "irq_config NULL");
    check_clean("link change and interrupt");
}

static void test_leds(void)
{
    uint16_t lcr = 0xFFFFu;
    uint16_t lacr = 0xFFFFu;
    uint16_t v = 0u;

    checkf(RTLNET_PHY_LCR_BOARD == 0x0070u && RTLNET_PHY_LACR_BOARD == 0x0010u,
           "board LED constants LCR 0x%04x LACR 0x%04x", RTLNET_PHY_LCR_BOARD, RTLNET_PHY_LACR_BOARD);
    fresh();
    check(rtlnet_phy_rtl8211e_get_leds(&g_ctx, &lcr, &lacr) == RTLNET_PHY_OK, "get_leds default");
    checkf(lcr == 0u && lacr == 0u, "model LED defaults LCR 0x%04x LACR 0x%04x", lcr, lacr);
    checkf(g_m.pagsel == 0u, "get_leds returns to page 0 (0x%04x, %u)", g_m.pagsel, 0u);

    check(rtlnet_phy_rtl8211e_set_leds(&g_ctx, 0x0123u, 0x0456u) == RTLNET_PHY_OK, "set_leds arbitrary values");
    checkf(g_m.led_lcr == 0x0123u && g_m.led_lacr == 0x0456u, "model LCR 0x%04x LACR 0x%04x", g_m.led_lcr,
           g_m.led_lacr);

    check(rtlnet_phy_rtl8211e_leds_default(&g_ctx) == RTLNET_PHY_OK, "leds_default");
    checkf(g_m.led_lcr == 0x0070u, "LCR 0x%04x, expected 0x%04x", g_m.led_lcr, 0x0070u);
    checkf(g_m.led_lacr == 0x0010u, "LACR 0x%04x, expected 0x%04x", g_m.led_lacr, 0x0010u);
    checkf(g_m.pagsel == 0u, "PAGSEL back to 0 after set_leds (0x%04x, %u)", g_m.pagsel, 0u);
    checkf(g_m.r28 == 0x8575u, "LED page write leaves RGMII register 28 (0x%04x, 0x%04x)", g_m.r28, 0x8575u);
    check(rtlnet_phy_rtl8211e_get_leds(&g_ctx, &lcr, &lacr) == RTLNET_PHY_OK && lcr == 0x0070u && lacr == 0x0010u,
          "get_leds reads the board setting");
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID1, &v) == RTLNET_MDIO_OK && v == 0x001Cu,
          "page 0 access after the LED pages");

    check(rtlnet_phy_rtl8211e_set_leds(NULL, 0u, 0u) == RTLNET_PHY_ERR_ARG, "set_leds NULL");
    check(rtlnet_phy_rtl8211e_get_leds(&g_ctx, NULL, &lacr) == RTLNET_PHY_ERR_ARG, "get_leds NULL lcr");
    check(rtlnet_phy_rtl8211e_get_leds(&g_ctx, &lcr, NULL) == RTLNET_PHY_ERR_ARG, "get_leds NULL lacr");
    check(rtlnet_phy_rtl8211e_leds_default(NULL) == RTLNET_PHY_ERR_ARG, "leds_default NULL");
    check_clean("LEDs");

    /* Negative: the LED registers do not stick. */
    fresh();
    g_m.led_stuck = 1;
    check(rtlnet_phy_rtl8211e_set_leds(&g_ctx, 0x0070u, 0x0010u) == RTLNET_PHY_ERR_VERIFY,
          "LED registers not sticking reported");
    checkf(g_m.pagsel == 0u, "PAGSEL back to 0 after a failed LED verify (0x%04x, %u)", g_m.pagsel, 0u);
    check(rtlnet_phy_rtl8211e_leds_default(&g_ctx) == RTLNET_PHY_ERR_VERIFY, "leds_default reports the verify failure");
    check(rtlnet_phy_rtl8211e_get_leds(&g_ctx, &lcr, &lacr) == RTLNET_PHY_OK && lcr == 0u && lacr == 0u,
          "get_leds shows the unchanged registers");
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID1, &v) == RTLNET_MDIO_OK && v == 0x001Cu,
          "page 0 access after a failed LED verify");
    check_clean("LED verify failure");

    /* Negative: no PHY answers. */
    fresh();
    g_m.phy_absent = 1;
    check(rtlnet_phy_rtl8211e_set_leds(&g_ctx, 0x0070u, 0x0010u) == RTLNET_MDIO_ERR_NO_PHY, "set_leds without PHY");
    check(rtlnet_phy_rtl8211e_get_leds(&g_ctx, &lcr, &lacr) == RTLNET_MDIO_ERR_NO_PHY, "get_leds without PHY");
    g_m.phy_absent = 0;
    check_clean("LEDs without PHY");
}

static void test_eee(void)
{
    uint16_t v = 0xFFFFu;
    unsigned w0;
    unsigned r0;

    fresh();
    check(rtlnet_phy_rtl8211e_get_eee_advert(&g_ctx, &v) == RTLNET_PHY_OK, "get_eee_advert");
    checkf(v == 0x0006u, "EEE advertisement at power-up 0x%04x, expected 0x%04x", v, 0x0006u);

    /* Wire sequence of a disable: write 13 = 7, 14 = 60, 13 = 0x4007, 14 = data; the readback
     * repeats the first three writes and reads 14. */
    g_m.ntrace = 0u;
    w0 = g_m.frames_write;
    r0 = g_m.frames_read;
    check(rtlnet_phy_rtl8211e_set_eee_advert(&g_ctx, 0) == RTLNET_PHY_OK, "EEE disable");
    checkf(g_m.mmd_reg[7][60] == 0u, "EEEAR after disable 0x%04x (%u)", g_m.mmd_reg[7][60], 0u);
    checkf(g_m.frames_write - w0 == 7u && g_m.frames_read - r0 == 1u, "EEE disable frames: writes %u reads %u",
           g_m.frames_write - w0, g_m.frames_read - r0);
    check(g_m.ntrace == 7u && g_m.trace[0] == ((13u << 16) | 0x0007u) && g_m.trace[1] == ((14u << 16) | 0x003Cu) &&
              g_m.trace[2] == ((13u << 16) | 0x4007u) && g_m.trace[3] == ((14u << 16) | 0x0000u) &&
              g_m.trace[4] == ((13u << 16) | 0x0007u) && g_m.trace[5] == ((14u << 16) | 0x003Cu) &&
              g_m.trace[6] == ((13u << 16) | 0x4007u),
          "MMD 7.60 access sequence on registers 13/14");
    check(rtlnet_phy_rtl8211e_get_eee_advert(&g_ctx, &v) == RTLNET_PHY_OK && v == 0u, "get_eee_advert after disable");

    g_m.ntrace = 0u;
    check(rtlnet_phy_rtl8211e_set_eee_advert(&g_ctx, 1) == RTLNET_PHY_OK, "EEE enable");
    checkf(g_m.mmd_reg[7][60] == 0x0006u, "EEEAR after enable 0x%04x, expected 0x%04x", g_m.mmd_reg[7][60], 0x0006u);
    check(g_m.trace[3] == ((14u << 16) | 0x0006u), "enable writes 0x0006 as the data");
    check(rtlnet_phy_rtl8211e_get_eee_advert(&g_ctx, &v) == RTLNET_PHY_OK && v == (RTLNET_PHY_EEE_ADV_100TX | RTLNET_PHY_EEE_ADV_1000T),
          "get_eee_advert after enable");

    check(rtlnet_phy_rtl8211e_set_eee_advert(NULL, 0) == RTLNET_PHY_ERR_ARG, "set_eee_advert NULL");
    check(rtlnet_phy_rtl8211e_get_eee_advert(&g_ctx, NULL) == RTLNET_PHY_ERR_ARG, "get_eee_advert NULL value");
    check(rtlnet_phy_rtl8211e_get_eee_advert(NULL, &v) == RTLNET_PHY_ERR_ARG, "get_eee_advert NULL ctx");
    check_clean("EEE");

    /* Negative: EEEAR does not stick. */
    g_m.eee_stuck = 1;
    check(rtlnet_phy_rtl8211e_set_eee_advert(&g_ctx, 0) == RTLNET_PHY_ERR_VERIFY, "EEE disable not sticking reported");
    checkf(g_m.mmd_reg[7][60] == 0x0006u, "stuck EEEAR unchanged 0x%04x (0x%04x)", g_m.mmd_reg[7][60], 0x0006u);
    g_m.eee_stuck = 0;

    /* Negative: no PHY. */
    g_m.phy_absent = 1;
    check(rtlnet_phy_rtl8211e_set_eee_advert(&g_ctx, 0) == RTLNET_MDIO_ERR_NO_PHY, "set_eee_advert without PHY");
    check(rtlnet_phy_rtl8211e_get_eee_advert(&g_ctx, &v) == RTLNET_MDIO_ERR_NO_PHY, "get_eee_advert without PHY");
    g_m.phy_absent = 0;
    check_clean("EEE faults");
}

static void test_clause45(void)
{
    rtlnet_mdio_t other;
    uint16_t v = 0u;
    unsigned w0;
    unsigned r0;

    fresh();

    /* Clause 45 registers through Clause 22 registers 13/14. */
    g_m.ntrace = 0u;
    check(rtlnet_mdio_mmd_write(&g_ctx, 3u, 0x0010u, 0xCAFEu) == RTLNET_MDIO_OK, "mmd_write");
    checkf(g_m.mmd_reg[3][0x10] == 0xCAFEu, "MMD 3 register 16 0x%04x, expected 0x%04x", g_m.mmd_reg[3][0x10], 0xCAFEu);
    checkf(g_m.macr == 0x4003u, "MACR left in data function 0x%04x, expected 0x%04x", g_m.macr, 0x4003u);
    check(g_m.ntrace == 4u && g_m.trace[0] == ((13u << 16) | 0x0003u) && g_m.trace[1] == ((14u << 16) | 0x0010u) &&
              g_m.trace[2] == ((13u << 16) | 0x4003u) && g_m.trace[3] == ((14u << 16) | 0xCAFEu),
          "mmd_write register sequence");
    w0 = g_m.frames_write;
    r0 = g_m.frames_read;
    check(rtlnet_mdio_mmd_read(&g_ctx, 3u, 0x0010u, &v) == RTLNET_MDIO_OK && v == 0xCAFEu, "mmd_read");
    checkf(g_m.frames_write - w0 == 3u && g_m.frames_read - r0 == 1u, "mmd_read frames: writes %u reads %u",
           g_m.frames_write - w0, g_m.frames_read - r0);
    check(rtlnet_mdio_mmd_read(&g_ctx, 5u, 0x0000u, &v) == RTLNET_MDIO_OK && v == 0u, "mmd_read of an absent MMD (model reads 0)");
    check(rtlnet_mdio_mmd_read(&g_ctx, 32u, 0u, &v) == RTLNET_MDIO_ERR_ARG, "mmd_read devad 32 rejected");
    check(rtlnet_mdio_mmd_write(&g_ctx, 32u, 0u, 0u) == RTLNET_MDIO_ERR_ARG, "mmd_write devad 32 rejected");
    check(rtlnet_mdio_mmd_read(&g_ctx, 3u, 0u, NULL) == RTLNET_MDIO_ERR_ARG, "mmd_read NULL value rejected");
    check(rtlnet_mdio_mmd_read(NULL, 3u, 0u, &v) == RTLNET_MDIO_ERR_ARG, "mmd_read NULL ctx rejected");
    check(rtlnet_mdio_mmd_write(NULL, 3u, 0u, 0u) == RTLNET_MDIO_ERR_ARG, "mmd_write NULL ctx rejected");
    check_clean("MMD indirect access");

    /* The RTL8211E does not answer native Clause 45: no TA, 0xFFFF; the bus stays in step. */
    check(rtlnet_mdio_c45_read(&g_ctx, RTLNET_PHY_MMD_AN, RTLNET_PHY_MMD_EEE_ADV, &v) == RTLNET_MDIO_ERR_NO_PHY,
          "native Clause 45 read of the RTL8211E reports no PHY");
    checkf(v == 0xFFFFu, "no-answer value 0x%04x, expected 0x%04x", v, 0xFFFFu);
    check(rtlnet_mdio_c45_write(&g_ctx, RTLNET_PHY_MMD_AN, RTLNET_PHY_MMD_EEE_ADV, 0u) == RTLNET_MDIO_OK,
          "native Clause 45 write returns OK (cannot detect)");
    checkf(g_m.mmd_reg[7][60] == 0x0006u, "RTL8211E ignored the native write (0x%04x, 0x%04x)", g_m.mmd_reg[7][60],
           0x0006u);
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID1, &v) == RTLNET_MDIO_OK && v == 0x001Cu,
          "Clause 22 read after ignored Clause 45 frames");
    check_clean("native Clause 45 on the RTL8211E");

    /* A Clause 45 PHY. */
    g_m.c45_native = 1;
    w0 = g_m.frames_write;
    check(rtlnet_mdio_c45_write(&g_ctx, 3u, 0x0020u, 0xBEEFu) == RTLNET_MDIO_OK, "c45_write");
    checkf(g_m.mmd_reg[3][0x20] == 0xBEEFu, "MMD 3 register 32 0x%04x, expected 0x%04x", g_m.mmd_reg[3][0x20], 0xBEEFu);
    checkf(g_m.frames_write - w0 == 2u, "c45_write frames %u, expected %u", g_m.frames_write - w0, 2u);
    w0 = g_m.frames_write;
    r0 = g_m.frames_read;
    v = 0u;
    check(rtlnet_mdio_c45_read(&g_ctx, 3u, 0x0020u, &v) == RTLNET_MDIO_OK, "c45_read");
    checkf(v == 0xBEEFu, "c45_read value 0x%04x, expected 0x%04x", v, 0xBEEFu);
    checkf(g_m.frames_write - w0 == 1u && g_m.frames_read - r0 == 1u, "c45_read frames: address %u read %u",
           g_m.frames_write - w0, g_m.frames_read - r0);
    checkf(g_m.last_pre == 32u, "Clause 45 preamble %u ones, expected %u", g_m.last_pre, 32u);
    checkf(g_m.mmd_addr[3] == 0x0020u, "address register 0x%04x, expected 0x%04x", g_m.mmd_addr[3], 0x0020u);

    /* Block read with post-increment. */
    g_m.mmd_reg[3][8] = 0x1111u;
    g_m.mmd_reg[3][9] = 0x2222u;
    g_m.mmd_reg[3][10] = 0x3333u;
    check(rtlnet_mdio_c45_addr(&g_ctx, 3u, 8u) == RTLNET_MDIO_OK, "c45_addr");
    check(rtlnet_mdio_c45_read_inc(&g_ctx, 3u, &v) == RTLNET_MDIO_OK && v == 0x1111u, "read_inc word 0");
    check(rtlnet_mdio_c45_read_inc(&g_ctx, 3u, &v) == RTLNET_MDIO_OK && v == 0x2222u, "read_inc word 1");
    check(rtlnet_mdio_c45_read_inc(&g_ctx, 3u, &v) == RTLNET_MDIO_OK && v == 0x3333u, "read_inc word 2");
    checkf(g_m.mmd_addr[3] == 0x000Bu, "address after three read_inc 0x%04x, expected 0x%04x", g_m.mmd_addr[3], 0x000Bu);

    /* The MMD file is shared with the indirect path. */
    check(rtlnet_mdio_mmd_read(&g_ctx, 3u, 0x0020u, &v) == RTLNET_MDIO_OK && v == 0xBEEFu,
          "indirect read of a natively written register");
    check(rtlnet_mdio_read(&g_ctx, RTLNET_PHY_REG_PHYID2, &v) == RTLNET_MDIO_OK && v == 0xC915u,
          "Clause 22 read between Clause 45 frames");
    check_clean("native Clause 45");

    /* Negative: a device that does not exist, and another port address. */
    v = 0u;
    check(rtlnet_mdio_c45_read(&g_ctx, 5u, 0x0001u, &v) == RTLNET_MDIO_ERR_NO_PHY, "c45_read of an absent MMD: TA error");
    checkf(v == 0xFFFFu, "absent MMD value 0x%04x, expected 0x%04x", v, 0xFFFFu);
    check(rtlnet_mdio_c45_read_inc(&g_ctx, 5u, &v) == RTLNET_MDIO_ERR_NO_PHY, "c45_read_inc of an absent MMD: TA error");
    check(rtlnet_mdio_c45_write(&g_ctx, 5u, 0x0001u, 0x1234u) == RTLNET_MDIO_OK, "c45_write to an absent MMD returns OK");
    checkf(g_m.mmd_reg[5][1] == 0u && g_m.mmd_addr[5] == 0u, "absent MMD untouched (0x%04x, 0x%04x)", g_m.mmd_reg[5][1],
           g_m.mmd_addr[5]);
    other = g_ctx;
    other.phy_addr = 2u;
    check(rtlnet_mdio_c45_read(&other, 3u, 0x0020u, &v) == RTLNET_MDIO_ERR_NO_PHY, "c45_read at another port address: TA error");
    check(rtlnet_mdio_c45_read(&g_ctx, 3u, 0x0020u, &v) == RTLNET_MDIO_OK && v == 0xBEEFu,
          "c45_read still works after the failed frames");
    check_clean("Clause 45 faults");

    /* Argument checks. */
    check(rtlnet_mdio_c45_addr(&g_ctx, 32u, 0u) == RTLNET_MDIO_ERR_ARG, "c45_addr devad 32 rejected");
    check(rtlnet_mdio_c45_write(&g_ctx, 32u, 0u, 0u) == RTLNET_MDIO_ERR_ARG, "c45_write devad 32 rejected");
    check(rtlnet_mdio_c45_read(&g_ctx, 32u, 0u, &v) == RTLNET_MDIO_ERR_ARG, "c45_read devad 32 rejected");
    check(rtlnet_mdio_c45_read_inc(&g_ctx, 32u, &v) == RTLNET_MDIO_ERR_ARG, "c45_read_inc devad 32 rejected");
    check(rtlnet_mdio_c45_read(&g_ctx, 3u, 0u, NULL) == RTLNET_MDIO_ERR_ARG, "c45_read NULL value rejected");
    check(rtlnet_mdio_c45_read_inc(&g_ctx, 3u, NULL) == RTLNET_MDIO_ERR_ARG, "c45_read_inc NULL value rejected");
    check(rtlnet_mdio_c45_write(NULL, 3u, 0u, 0u) == RTLNET_MDIO_ERR_ARG, "c45_write NULL ctx rejected");
    check(rtlnet_mdio_c45_read(NULL, 3u, 0u, &v) == RTLNET_MDIO_ERR_ARG, "c45_read NULL ctx rejected");
    check_clean("Clause 45 arguments");
}

int main(int argc, char **argv)
{
    int inject = (argc > 1 && strcmp(argv[1], "--inject-failure") == 0);

    test_core();
    test_calibrate();
    test_frames();
    test_timing_negative();
    test_no_phy();
    test_probe_and_delay();
    test_hw_reset();
    test_soft_reset();
    test_autoneg();
    test_forced_and_loopback();
    test_link_and_irq();
    test_leds();
    test_eee();
    test_clause45();
    if (inject) {
        check(0, "INJECT_FAILURE negative control");
    }

    if (g_fails == 0 && g_checks > 0) {
        printf("TEST PASS: rtlnet_mdio_host checks=%d\n", g_checks);
        return 0;
    }
    printf("TEST FAIL: rtlnet_mdio_host fails=%d checks=%d first=%s\n", g_fails, g_checks,
           (g_checks == 0) ? "no checks ran" : g_first);
    return 1;
}
