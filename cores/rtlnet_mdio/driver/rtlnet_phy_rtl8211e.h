/*
 * rtlnet_phy_rtl8211e.h -- Realtek RTL8211E PHY management over rtlnet_mdio
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the PHY layer. Every access goes through the Clause 22 master of
 * rtlnet_mdio.h; this layer owns the PHY's register numbers and bit meanings
 * (RTL8211E-VB/VL datasheet Rev. 1.6, section 8) and never touches the GPIO
 * core's registers. Callers: the firmware CLI (PHY STATUS/DUMP/READ/WRITE/
 * RESET/AUTONEG/SPEED/ADVERTISE/LED/EEE) and the link monitor that copies the
 * PHYSR speed into the MAC.
 *
 * Speed codes (RTLNET_PHY_SPEED_*) are the PHYSR 17.15:14 encoding, which is
 * also the rtlnet_eth_mac speed encoding (00 10M, 01 100M, 10 1000M,
 * architecture section 15.1), so the link monitor copies the code unchanged.
 *
 * Split: this header holds constants, types, signatures and contracts;
 * rtlnet_phy_rtl8211e.c holds the per-function commentary.
 */
#ifndef RTLNET_PHY_RTL8211E_H
#define RTLNET_PHY_RTL8211E_H

#include "rtlnet_mdio.h"   /* rtlnet_mdio_t, rtlnet_mdio_read/write */

#include <stdint.h>        /* uint8_t, uint16_t, uint32_t */

/* Nexys Video strap: PHYAD 00001 (Reference Manual section 4). */
#define RTLNET_PHY_RTL8211E_ADDR_DEFAULT  1u

/* Page 0 registers (datasheet Table 20). */
#define RTLNET_PHY_REG_BMCR     0u
#define RTLNET_PHY_REG_BMSR     1u
#define RTLNET_PHY_REG_PHYID1   2u
#define RTLNET_PHY_REG_PHYID2   3u
#define RTLNET_PHY_REG_ANAR     4u
#define RTLNET_PHY_REG_ANLPAR   5u
#define RTLNET_PHY_REG_ANER     6u
#define RTLNET_PHY_REG_GBCR     9u
#define RTLNET_PHY_REG_GBSR     10u
#define RTLNET_PHY_REG_PHYSR    17u
#define RTLNET_PHY_REG_INER     18u
#define RTLNET_PHY_REG_INSR     19u
#define RTLNET_PHY_REG_EPAGSR   30u
#define RTLNET_PHY_REG_PAGSEL   31u
#define RTLNET_PHY_NUM_REGS     32u

/* Identity (Tables 25, 26): OUI, model 010001, revision 0101. */
#define RTLNET_PHY_RTL8211E_ID1  0x001Cu
#define RTLNET_PHY_RTL8211E_ID2  0xC915u

/* BMCR (Table 23). */
#define RTLNET_PHY_BMCR_RESET       0x8000u   /* self-clearing */
#define RTLNET_PHY_BMCR_LOOPBACK    0x4000u   /* PCS loopback */
#define RTLNET_PHY_BMCR_SPEED0      0x2000u   /* forced speed LSB */
#define RTLNET_PHY_BMCR_ANE         0x1000u   /* auto-negotiation enable */
#define RTLNET_PHY_BMCR_PWD         0x0800u
#define RTLNET_PHY_BMCR_ISOLATE     0x0400u
#define RTLNET_PHY_BMCR_RESTART_AN  0x0200u   /* self-clearing */
#define RTLNET_PHY_BMCR_DUPLEX      0x0100u   /* forced full duplex */
#define RTLNET_PHY_BMCR_SPEED1      0x0040u   /* forced speed MSB */

/* BMSR (Table 24). Link status 1.2 is latch-low; the driver takes the link
 * from PHYSR 17.10 (real time). */
#define RTLNET_PHY_BMSR_AN_COMPLETE 0x0020u
#define RTLNET_PHY_BMSR_LINK        0x0004u

/* ANAR / ANLPAR technology bits (Tables 27, 28). */
#define RTLNET_PHY_ANAR_100F        0x0100u
#define RTLNET_PHY_ANAR_100H        0x0080u
#define RTLNET_PHY_ANAR_10F         0x0040u
#define RTLNET_PHY_ANAR_10H         0x0020u
#define RTLNET_PHY_ANAR_TECH_MASK   0x01E0u

/* GBCR (Table 32): 9.9 1000BASE-T full. 9.8 is 1000BASE-T half in IEEE
 * 802.3 clause 40; the RTL8211E datasheet lists 9.8 as reserved, so the PHY
 * may not advertise 1000H (verify on hardware). */
#define RTLNET_PHY_GBCR_1000F       0x0200u
#define RTLNET_PHY_GBCR_1000H       0x0100u
#define RTLNET_PHY_GBCR_TECH_MASK   0x0300u

/* GBSR (Table 33): link partner 1000BASE-T abilities. */
#define RTLNET_PHY_GBSR_LP_1000F    0x0800u
#define RTLNET_PHY_GBSR_LP_1000H    0x0400u

/* PHYSR (Table 38). */
#define RTLNET_PHY_PHYSR_SPEED_SHIFT 14u
#define RTLNET_PHY_PHYSR_SPEED_MASK  0x3u
#define RTLNET_PHY_PHYSR_DUPLEX      0x2000u
#define RTLNET_PHY_PHYSR_RESOLVED    0x0800u
#define RTLNET_PHY_PHYSR_LINK        0x0400u   /* real time */
#define RTLNET_PHY_PHYSR_MDI_X       0x0040u

/* INER / INSR (Tables 39, 40). INSR is read-clear; reading it releases INTB. */
#define RTLNET_PHY_INT_AN_ERROR     0x8000u
#define RTLNET_PHY_INT_PAGE_RX      0x1000u
#define RTLNET_PHY_INT_AN_COMPLETE  0x0800u
#define RTLNET_PHY_INT_LINK_CHANGE  0x0400u

/* Extension page access (section 7.10.5, Tables 43, 44): PAGSEL = 7 selects
 * the extension page space, EPAGSR selects the page, PAGSEL = 0 returns. */
#define RTLNET_PHY_PAGSEL_PAGE0     0x0000u
#define RTLNET_PHY_PAGSEL_EXT       0x0007u
#define RTLNET_PHY_EXTPAGE_RGMII    0x00A4u
#define RTLNET_PHY_REG_RGMII_DELAY  28u
/* Extension page 0xA4 register 28 (not in the public datasheet; the Linux
 * rtl8211e_config_init definitions): bit 13 delays under register control,
 * bit 12 TX delay, bit 11 RX delay; bits 10:0 are vendor settings and are
 * preserved by a read-modify-write. */
#define RTLNET_PHY_RGMII_CTRL_DELAY 0x2000u
#define RTLNET_PHY_RGMII_TX_DELAY   0x1000u
#define RTLNET_PHY_RGMII_RX_DELAY   0x0800u

/* LED extension page 0x2C (section 7.13, Tables 17-19; same page mechanism as
 * above). Register 28 is the LED control register (LCR), register 26 the LED
 * activity control register (LACR). The Nexys Video wires LED0 to the activity
 * LED (LD10), LED1 to the link LED (LD9) and LED2 to the user LED (LD8, unused).
 * LCR 6:4 select the link speeds that light LED1 (10, 100, 1000); the LED0 and
 * LED2 link selects, bits 2:0 and 10:8, stay 0, so LED0 has no link function and
 * LED2 is off. LACR bit 4 makes LED0 blink on TX/RX activity; bits 5 and 6 stay
 * 0, so LED1 is steady and LED2 is off. */
#define RTLNET_PHY_EXTPAGE_LED      0x002Cu
#define RTLNET_PHY_REG_LED_LCR      28u
#define RTLNET_PHY_REG_LED_LACR     26u
#define RTLNET_PHY_LCR_LED1_LINK_ALL 0x0070u   /* LED1 on at link 10, 100 and 1000 */
#define RTLNET_PHY_LACR_LED0_ACT    0x0010u    /* LED0 blinks on TX/RX activity */
#define RTLNET_PHY_LCR_BOARD        RTLNET_PHY_LCR_LED1_LINK_ALL   /* 0x0070 */
#define RTLNET_PHY_LACR_BOARD       RTLNET_PHY_LACR_LED0_ACT       /* 0x0010 */

/* Energy-Efficient Ethernet advertisement: MMD 7 (auto-negotiation), register
 * 60 EEEAR (IEEE 802.3 clause 45 register 7.60; datasheet Table 21), reached through Clause 22 registers 13/14 by
 * rtlnet_mdio_mmd_read/write. Bit 1 is 100BASE-TX EEE, bit 2 is 1000BASE-T EEE. */
#define RTLNET_PHY_MMD_AN           7u
#define RTLNET_PHY_MMD_EEE_ADV      60u
#define RTLNET_PHY_EEE_ADV_100TX    0x0002u
#define RTLNET_PHY_EEE_ADV_1000T    0x0004u
#define RTLNET_PHY_EEE_ADV_MASK     (RTLNET_PHY_EEE_ADV_100TX | RTLNET_PHY_EEE_ADV_1000T)   /* 0x0006 */

/* Advertisement / ability mask used by the API (not a register layout). */
#define RTLNET_PHY_ADV_10H          (1u << 0)
#define RTLNET_PHY_ADV_10F          (1u << 1)
#define RTLNET_PHY_ADV_100H         (1u << 2)
#define RTLNET_PHY_ADV_100F         (1u << 3)
#define RTLNET_PHY_ADV_1000H        (1u << 4)
#define RTLNET_PHY_ADV_1000F        (1u << 5)
#define RTLNET_PHY_ADV_ALL          (0x3Fu)
#define RTLNET_PHY_ADV_FULL         (RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100F | RTLNET_PHY_ADV_1000F)   /* the only modes advertise_set writes as 1 */

/* Speed codes: PHYSR 17.15:14 and the MAC speed register encoding. */
#define RTLNET_PHY_SPEED_10         0u
#define RTLNET_PHY_SPEED_100        1u
#define RTLNET_PHY_SPEED_1000       2u
#define RTLNET_PHY_SPEED_UNKNOWN    3u   /* reserved code */

/* Bounded waits: soft reset self-clear poll (BMCR bit 15). */
#define RTLNET_PHY_RESET_POLL_US    1000u
#define RTLNET_PHY_RESET_POLL_MAX   500u

/* Return codes: RTLNET_MDIO_* from the bus layer pass through unchanged
 * (0 OK, -1 .. -6); this layer adds -16 and below. */
#define RTLNET_PHY_OK               0
#define RTLNET_PHY_ERR_ID           (-16)   /* PHYID1/PHYID2 not 0x001C/0xC915 */
#define RTLNET_PHY_ERR_VERIFY       (-17)   /* readback differs from the value written (RX delay, LED, EEE) */
#define RTLNET_PHY_ERR_TIMEOUT      (-18)   /* BMCR reset bit did not self-clear */
#define RTLNET_PHY_ERR_ARG          (-19)   /* NULL pointer, bad mask or speed */

/* Decoded status. Raw words are kept for the CLI. */
typedef struct {
    uint8_t  link_up;       /* PHYSR 17.10, real time */
    uint8_t  resolved;      /* PHYSR 17.11 speed and duplex resolved */
    uint8_t  speed;         /* RTLNET_PHY_SPEED_*, PHYSR 17.15:14 */
    uint8_t  full_duplex;   /* PHYSR 17.13 */
    uint8_t  speed_valid;   /* link_up && resolved && speed != UNKNOWN: safe to copy to the MAC */
    uint8_t  an_enabled;    /* BMCR 0.12 */
    uint8_t  an_complete;   /* BMSR 1.5 */
    uint8_t  mdi_crossover; /* PHYSR 17.6 */
    uint32_t partner_adv;   /* RTLNET_PHY_ADV_* from ANLPAR and GBSR; 0 unless an_complete */
    uint16_t bmcr;
    uint16_t bmsr;
    uint16_t physr;
    uint16_t anlpar;
    uint16_t gbsr;
} rtlnet_phy_status_t;

int rtlnet_phy_rtl8211e_probe(const rtlnet_mdio_t *mdio, uint32_t *id_out);
int rtlnet_phy_rtl8211e_enable_rx_delay(const rtlnet_mdio_t *mdio, uint16_t *before, uint16_t *after);
int rtlnet_phy_rtl8211e_init(const rtlnet_mdio_t *mdio);
int rtlnet_phy_rtl8211e_soft_reset(const rtlnet_mdio_t *mdio);
int rtlnet_phy_rtl8211e_autoneg_restart(const rtlnet_mdio_t *mdio);
int rtlnet_phy_rtl8211e_advertise_set(const rtlnet_mdio_t *mdio, uint32_t adv_mask);
int rtlnet_phy_rtl8211e_advertise_get(const rtlnet_mdio_t *mdio, uint32_t *adv_mask);
int rtlnet_phy_rtl8211e_force(const rtlnet_mdio_t *mdio, uint8_t speed, int full_duplex);
int rtlnet_phy_rtl8211e_status(const rtlnet_mdio_t *mdio, rtlnet_phy_status_t *st);
int rtlnet_phy_rtl8211e_loopback(const rtlnet_mdio_t *mdio, int enable);
int rtlnet_phy_rtl8211e_dump(const rtlnet_mdio_t *mdio, uint16_t regs[RTLNET_PHY_NUM_REGS]);
int rtlnet_phy_rtl8211e_irq_config(const rtlnet_mdio_t *mdio, uint16_t iner_mask);
int rtlnet_phy_rtl8211e_irq_ack(const rtlnet_mdio_t *mdio, uint16_t *insr);
int rtlnet_phy_rtl8211e_set_leds(const rtlnet_mdio_t *mdio, uint16_t lcr, uint16_t lacr);
int rtlnet_phy_rtl8211e_get_leds(const rtlnet_mdio_t *mdio, uint16_t *lcr, uint16_t *lacr);
int rtlnet_phy_rtl8211e_leds_default(const rtlnet_mdio_t *mdio);
int rtlnet_phy_rtl8211e_set_eee_advert(const rtlnet_mdio_t *mdio, int enable);
int rtlnet_phy_rtl8211e_get_eee_advert(const rtlnet_mdio_t *mdio, uint16_t *value);
uint32_t rtlnet_phy_speed_mbps(uint8_t speed);

#endif /* RTLNET_PHY_RTL8211E_H */
