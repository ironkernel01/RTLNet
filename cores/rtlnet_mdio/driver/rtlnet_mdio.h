/*
 * rtlnet_mdio.h -- RTLNet MDIO GPIO core register map and Clause 22 master
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single owner of the rtlnet_mdio core's registers. The RTL is a
 * GPIO register block (MDC, MDIO output/enable, synchronized MDIO input, PHY
 * reset, PHY interrupt); this driver is the IEEE 802.3 Clause 22 management
 * master that bit-bangs frames through it. Higher layers (the RTL8211E PHY
 * layer rtlnet_phy_rtl8211e.h, the CLI, the link monitor) call the functions
 * below and never touch the core's registers.
 *
 * Register offsets and bit positions are defined here once. The register file
 * cores/rtlnet_mdio/hdl/rtlnet_mdio.sv mirrors them as localparams; change
 * both in the same commit. A drift moves a pin: the driver would toggle the
 * wrong output (for example pulse PHY reset instead of MDC) or sample a bit
 * that is not MDIO.
 *
 * Split: this header holds constants, types, signatures and contracts;
 * rtlnet_mdio.c holds the per-function commentary.
 */
#ifndef RTLNET_MDIO_H
#define RTLNET_MDIO_H

#include "rtlnet_mmio.h"   /* rtlnet_reg_read32/write32, RTLNET_REG_ID/VERSION/CAPS */

#include <stdint.h>        /* uint8_t, uint16_t, uint32_t, uintptr_t */

/* -------------------------------------------------------------------------
 * Register map (byte offsets in the core's 4 KiB window). Mirrored by the
 * localparams of cores/rtlnet_mdio/hdl/rtlnet_mdio.sv.
 * ------------------------------------------------------------------------- */
#define RTLNET_MDIO_REG_ID        RTLNET_REG_ID       /* 0x000 RO "MDIO" */
#define RTLNET_MDIO_REG_VERSION   RTLNET_REG_VERSION  /* 0x004 RO 0xMMDDYYYY */
#define RTLNET_MDIO_REG_CAPS      RTLNET_REG_CAPS     /* 0x008 RO build parameters */
#define RTLNET_MDIO_REG_CTRL      0x00Cu              /* RW pins, PHY reset, IRQ enable */
#define RTLNET_MDIO_REG_STATUS    0x010u              /* RO synchronized inputs */
#define RTLNET_MDIO_REG_BITBANG   0x014u              /* W: pins only; R: MDIO_IN */

#define RTLNET_MDIO_ID_VALUE      0x4D44494Fu         /* "MDIO" */
#define RTLNET_MDIO_VERSION_VALUE 0x10222026u         /* register map 10-22-2026 */

/* CAPS: [23:0] CLK_HZ / 1000 (clk frequency in kHz), [31:24] POR_RESET_MS. */
#define RTLNET_MDIO_CAPS_CLK_KHZ_MASK  0x00FFFFFFu
#define RTLNET_MDIO_CAPS_POR_MS_SHIFT  24u
#define RTLNET_MDIO_CAPS_POR_MS_MASK   0xFFu

/* CTRL bits. One write updates MDC, MDIO_OE and MDIO_OUT together. */
#define RTLNET_MDIO_CTRL_MDC        (1u << 0)   /* MDC pin level */
#define RTLNET_MDIO_CTRL_MDIO_OE    (1u << 1)   /* 1 = drive MDIO (mdio_t = 0) */
#define RTLNET_MDIO_CTRL_MDIO_OUT   (1u << 2)   /* level driven when MDIO_OE = 1 */
#define RTLNET_MDIO_CTRL_PINS_MASK  (0x7u)      /* the three pin bits, also BITBANG[2:0] */
#define RTLNET_MDIO_CTRL_PHY_RESET  (1u << 8)   /* 1 = hold phy_rst_n low */
#define RTLNET_MDIO_CTRL_IRQ_EN     (1u << 9)   /* irq = PHY_INT && IRQ_EN */

/* STATUS bits. */
#define RTLNET_MDIO_STATUS_MDIO_IN          (1u << 0)   /* MDIO pin, 3-stage synchronized */
#define RTLNET_MDIO_STATUS_PHY_INT          (1u << 1)   /* phy_int_n is low (synchronized) */
#define RTLNET_MDIO_STATUS_POR_DONE         (1u << 2)   /* power-on PHY reset finished */
#define RTLNET_MDIO_STATUS_PHY_RESET_ACTIVE (1u << 3)   /* phy_rst_n is low now */

/* BITBANG: write bits [2:0] as CTRL[2:0] (PHY_RESET and IRQ_EN unchanged);
 * read returns MDIO_IN in bit 0, other bits 0. */
#define RTLNET_MDIO_BITBANG_MDIO_IN (1u << 0)

/* -------------------------------------------------------------------------
 * Clause 22 constants (IEEE 802.3 clause 22.2.4.5; RTL8211E datasheet
 * section 7.10.4 Tables 14 and 15).
 * ------------------------------------------------------------------------- */
#define RTLNET_MDIO_PREAMBLE_BITS   32u
#define RTLNET_MDIO_ST              0x1u    /* 01 */
#define RTLNET_MDIO_OP_READ         0x2u    /* 10 */
#define RTLNET_MDIO_OP_WRITE        0x1u    /* 01 */
#define RTLNET_MDIO_TA_WRITE        0x2u    /* 10 */
#define RTLNET_MDIO_ADDR_MAX        31u     /* 5-bit PHYAD and REGAD */
#define RTLNET_MDIO_NO_PHY_DATA     0xFFFFu /* value returned when no PHY answers */

/* MDC timing. Datasheet Table 61: period t3 >= 400 ns, high t1 and low t2
 * >= 160 ns. The driver aims at a 500 ns period (2 MHz, 250 ns per half);
 * RTLNET_MDIO_HALF_MIN_NS is the floor calibration never goes below. */
#define RTLNET_MDIO_HALF_TARGET_NS  250u
#define RTLNET_MDIO_HALF_MIN_NS     200u

/* PHY hardware reset (datasheet section 7.16, Figure 10: >= 10 ms low, then
 * 30 ms before the first register access), used with margin. */
#define RTLNET_MDIO_RESET_LOW_US    20000u
#define RTLNET_MDIO_RESET_SETTLE_US 50000u

/* Bound on the wait for the core's power-on reset (POR_RESET_MS <= 255). */
#define RTLNET_MDIO_POR_POLL_US     1000u
#define RTLNET_MDIO_POR_POLL_MAX    300u

/* Calibration: iterations timed per measurement and the loop count used for
 * the second point of the two-point fit. */
#define RTLNET_MDIO_CAL_ITERS       64u
#define RTLNET_MDIO_CAL_LOOPS       64u
#define RTLNET_MDIO_CAL_LOOPS_MAX   100000u

/* -------------------------------------------------------------------------
 * Return codes (0 = success, negative = named fault).
 * ------------------------------------------------------------------------- */
#define RTLNET_MDIO_OK              0
#define RTLNET_MDIO_ERR_ARG         (-1)   /* NULL pointer, address > 31 */
#define RTLNET_MDIO_ERR_CORE_ID     (-2)   /* ID or VERSION register mismatch */
#define RTLNET_MDIO_ERR_NO_PHY      (-3)   /* read TA bit 2 not driven low */
#define RTLNET_MDIO_ERR_TIMEOUT     (-4)   /* POR_DONE never set */
#define RTLNET_MDIO_ERR_CALIBRATE   (-5)   /* timer did not advance */
#define RTLNET_MDIO_ERR_NO_DELAY    (-6)   /* delay_us callback missing */

/* Platform hooks. user is the context's opaque pointer.
 *   delay_us     -- busy-wait at least us microseconds (AXI timer); used for
 *                   the PHY reset and the POR wait. Required.
 *   half_delay   -- optional: wait one MDC half period. When NULL the driver
 *                   spins half_loops iterations of a volatile counter.
 *   now_ticks    -- free-running timer, used only by calibrate. */
typedef void (*rtlnet_mdio_delay_us_fn)(void *user, uint32_t us);
typedef void (*rtlnet_mdio_half_delay_fn)(void *user);
typedef uint32_t (*rtlnet_mdio_now_ticks_fn)(void *user);

/* Driver context, one per MDIO bus. Initialized by rtlnet_mdio_init; the
 * caller owns the storage. Fields are read-only for callers except
 * half_loops, which rtlnet_mdio_set_half_loops / rtlnet_mdio_calibrate set. */
typedef struct {
    uintptr_t                 base;        /* core base address (platform layer) */
    uint8_t                   phy_addr;    /* Clause 22 PHYAD, 0..31 */
    uint32_t                  half_loops;  /* spin count per MDC half period */
    rtlnet_mdio_half_delay_fn half_delay;  /* optional, overrides half_loops */
    rtlnet_mdio_delay_us_fn   delay_us;    /* required */
    void                     *user;        /* passed to every hook */
} rtlnet_mdio_t;

/* Core bring-up and timing. */
int rtlnet_mdio_init(rtlnet_mdio_t *ctx, uintptr_t base, uint8_t phy_addr,
                     rtlnet_mdio_delay_us_fn delay_us, void *user);
void rtlnet_mdio_set_half_delay(rtlnet_mdio_t *ctx, rtlnet_mdio_half_delay_fn half_delay);
void rtlnet_mdio_set_half_loops(rtlnet_mdio_t *ctx, uint32_t half_loops);
int rtlnet_mdio_calibrate(rtlnet_mdio_t *ctx, rtlnet_mdio_now_ticks_fn now_ticks,
                          uint32_t ticks_per_us, uint32_t *half_ns_out);
uint32_t rtlnet_mdio_caps_clk_khz(const rtlnet_mdio_t *ctx);
uint32_t rtlnet_mdio_caps_por_ms(const rtlnet_mdio_t *ctx);

/* Clause 22 frames. reg 0..31; on RTLNET_MDIO_ERR_NO_PHY *val is 0xFFFF. */
int rtlnet_mdio_read(const rtlnet_mdio_t *ctx, uint8_t reg, uint16_t *val);
int rtlnet_mdio_write(const rtlnet_mdio_t *ctx, uint8_t reg, uint16_t val);
int rtlnet_mdio_read_addr(const rtlnet_mdio_t *ctx, uint8_t phy_addr, uint8_t reg, uint16_t *val);
int rtlnet_mdio_write_addr(const rtlnet_mdio_t *ctx, uint8_t phy_addr, uint8_t reg, uint16_t val);

/* PHY reset and interrupt line. */
int rtlnet_mdio_wait_por(const rtlnet_mdio_t *ctx);
int rtlnet_mdio_phy_reset(const rtlnet_mdio_t *ctx);
void rtlnet_mdio_irq_enable(const rtlnet_mdio_t *ctx, int enable);
int rtlnet_mdio_phy_int_asserted(const rtlnet_mdio_t *ctx);
uint32_t rtlnet_mdio_status(const rtlnet_mdio_t *ctx);

#endif /* RTLNET_MDIO_H */
