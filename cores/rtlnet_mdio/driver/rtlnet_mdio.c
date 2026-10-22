/*
 * rtlnet_mdio.c -- Clause 22 and Clause 45 MDIO master over the rtlnet_mdio GPIO core
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: owns the rtlnet_mdio core's registers (see rtlnet_mdio.h). Builds
 * IEEE 802.3 Clause 22 and Clause 45 management frames bit by bit through the
 * BITBANG register, drives the PHY hardware reset through CTRL.PHY_RESET and gates
 * the PHY interrupt through CTRL.IRQ_EN.
 *
 * Bit timing (one slot = one MDC period, MDC low for the first half):
 *   - Master-driven bit: one BITBANG store at the start of the slot sets MDC
 *     low and the new MDIO level, a half-period wait, one store raises MDC
 *     with the level unchanged, a half-period wait. The level is stable for
 *     a half period before and after the rising edge (datasheet Table 61
 *     t4/t5 need 10 ns).
 *   - PHY-driven bit: MDC low with the line released, a half-period wait, a
 *     BITBANG read just before the rising edge, then MDC high. The PHY
 *     launched the bit after the previous rising edge (t6 <= 300 ns), so the
 *     sample is a half period plus the store/read time after its launch.
 *   - After every frame, one idle slot: MDC low, line released, no edge, so a
 *     PHY still driving the last read bit never meets the next preamble.
 * The half period is a spin of half_loops iterations (or the platform's
 * half_delay hook); rtlnet_mdio_calibrate sizes it with the platform timer.
 */
#include "rtlnet_mdio.h"

#include <stddef.h>   /* NULL */

/* Header bit positions inside the 32-bit word that follows the preamble:
 * ST[31:30] OP[29:28] PHYAD[27:23] REGAD[22:18] TA[17:16] DATA[15:0]. Clause 45
 * uses the same positions with PRTAD in PHYAD and DEVAD in REGAD. */
#define MDIO_FRAME_ST_SHIFT     30u
#define MDIO_FRAME_OP_SHIFT     28u
#define MDIO_FRAME_PHYAD_SHIFT  23u
#define MDIO_FRAME_REGAD_SHIFT  18u
#define MDIO_FRAME_TA_SHIFT     16u
#define MDIO_FRAME_HDR_BITS     14u     /* ST + OP + PHYAD + REGAD */
#define MDIO_FRAME_WRITE_BITS   32u     /* header + TA + DATA */
#define MDIO_DATA_BITS          16u
#define MDIO_NS_PER_US          1000u

/* BITBANG pin words. */
#define MDIO_PINS_IDLE   0u                                                   /* MDC low, released */
#define MDIO_PINS_DRIVE  (RTLNET_MDIO_CTRL_MDIO_OE)
#define MDIO_PINS_HIGH   (RTLNET_MDIO_CTRL_MDC)

#ifdef RTLNET_HOST_TEST
/* Host unit test: the register model accounts the time of a spin. */
void rtlnet_host_spin(uint32_t loops);
#endif

/*
 * spin -- busy-wait a number of loop iterations
 * Steps:
 *   1. Count a volatile index up to loops (the store keeps the loop).
 * Returns: nothing.
 */
static void spin(uint32_t loops)
{
#ifdef RTLNET_HOST_TEST
    rtlnet_host_spin(loops);
#else
    for (volatile uint32_t i = 0u; i < loops; i++) {
    }
#endif
}

/*
 * half_wait -- wait one MDC half period
 * Steps:
 *   1. Call the platform half_delay hook when present.
 *   2. Otherwise spin half_loops iterations.
 * Returns: nothing.
 */
static void half_wait(const rtlnet_mdio_t *ctx)
{
    if (ctx->half_delay != NULL) {
        ctx->half_delay(ctx->user);
    } else {
        spin(ctx->half_loops);
    }
}

/*
 * pins -- set MDC, MDIO_OE and MDIO_OUT in one BITBANG store
 * Steps:
 *   1. Write the pin word; PHY_RESET and IRQ_EN are not affected.
 * Returns: nothing.
 */
static void pins(const rtlnet_mdio_t *ctx, uint32_t word)
{
    rtlnet_reg_write32(ctx->base, RTLNET_MDIO_REG_BITBANG, word);
}

/*
 * out_bit -- drive one bit slot
 * Steps:
 *   1. MDC low, drive the level; wait a half period.
 *   2. MDC high, level unchanged; wait a half period.
 * Returns: nothing.
 */
static void out_bit(const rtlnet_mdio_t *ctx, uint32_t bit)
{
    uint32_t word = MDIO_PINS_DRIVE | ((bit != 0u) ? RTLNET_MDIO_CTRL_MDIO_OUT : 0u);

    pins(ctx, word);
    half_wait(ctx);
    pins(ctx, word | MDIO_PINS_HIGH);
    half_wait(ctx);
}

/*
 * in_bit -- sample one PHY-driven bit slot
 * Steps:
 *   1. MDC low, line released; wait a half period.
 *   2. Read MDIO_IN just before the rising edge.
 *   3. MDC high; wait a half period.
 * Returns: the sampled bit, 0 or 1.
 */
static uint32_t in_bit(const rtlnet_mdio_t *ctx)
{
    uint32_t bit;

    pins(ctx, MDIO_PINS_IDLE);
    half_wait(ctx);
    bit = rtlnet_reg_read32(ctx->base, RTLNET_MDIO_REG_BITBANG) & RTLNET_MDIO_BITBANG_MDIO_IN;
    pins(ctx, MDIO_PINS_IDLE | MDIO_PINS_HIGH);
    half_wait(ctx);
    return bit;
}

/*
 * idle_slot -- end a frame
 * Steps:
 *   1. MDC low, line released, for one full period with no edge.
 * Returns: nothing.
 */
static void idle_slot(const rtlnet_mdio_t *ctx)
{
    pins(ctx, MDIO_PINS_IDLE);
    half_wait(ctx);
    half_wait(ctx);
}

/*
 * out_bits -- drive the top count bits of word, most significant first
 * Steps:
 *   1. For each bit from 31 down to 32 - count, drive one slot.
 * Returns: nothing.
 */
static void out_bits(const rtlnet_mdio_t *ctx, uint32_t word, uint32_t count)
{
    for (uint32_t i = 0u; i < count; i++) {
        out_bit(ctx, (word >> (31u - i)) & 1u);
    }
}

/*
 * frame_word -- build the 32-bit post-preamble word of a frame
 * Steps:
 *   1. Pack ST, OP, PHYAD (PRTAD), REGAD (DEVAD), TA and DATA at their
 *      positions.
 * Returns: the word, ST in bits 31:30.
 */
static uint32_t frame_word(uint32_t st, uint32_t op, uint8_t phy_addr, uint8_t reg, uint32_t ta, uint16_t data)
{
    return (st << MDIO_FRAME_ST_SHIFT) | (op << MDIO_FRAME_OP_SHIFT) |
           ((uint32_t)phy_addr << MDIO_FRAME_PHYAD_SHIFT) | ((uint32_t)reg << MDIO_FRAME_REGAD_SHIFT) |
           (ta << MDIO_FRAME_TA_SHIFT) | (uint32_t)data;
}

/*
 * read_frame -- one read-type frame, Clause 22 or Clause 45
 * Steps:
 *   1. 32 preamble ones, then the 14 header bits of word (master drives).
 *   2. TA: release the line; slot 1 is ignored, slot 2 must read 0 (the PHY
 *      drives it); a 1 means nobody answered.
 *   3. 16 data bits, most significant first; then the idle slot.
 * Returns: RTLNET_MDIO_OK with *val set; RTLNET_MDIO_ERR_NO_PHY with *val =
 *   0xFFFF (the frame still completes).
 */
static int read_frame(const rtlnet_mdio_t *ctx, uint32_t word, uint16_t *val)
{
    uint32_t ta2;
    uint32_t data = 0u;

    out_bits(ctx, UINT32_MAX, RTLNET_MDIO_PREAMBLE_BITS);
    out_bits(ctx, word, MDIO_FRAME_HDR_BITS);
    (void)in_bit(ctx);
    ta2 = in_bit(ctx);
    for (uint32_t i = 0u; i < MDIO_DATA_BITS; i++) {
        data = (data << 1) | in_bit(ctx);
    }
    idle_slot(ctx);

    if (ta2 != 0u) {
        *val = RTLNET_MDIO_NO_PHY_DATA;
        return RTLNET_MDIO_ERR_NO_PHY;
    }
    *val = (uint16_t)data;
    return RTLNET_MDIO_OK;
}

/*
 * write_frame -- one write-type frame, Clause 22 or Clause 45
 * Steps:
 *   1. 32 preamble ones, then all 32 bits of word (header, TA 10, data), all
 *      driven by the master; then the idle slot.
 * Returns: nothing.
 */
static void write_frame(const rtlnet_mdio_t *ctx, uint32_t word)
{
    out_bits(ctx, UINT32_MAX, RTLNET_MDIO_PREAMBLE_BITS);
    out_bits(ctx, word, MDIO_FRAME_WRITE_BITS);
    idle_slot(ctx);
}

/*
 * ctrl_update -- read-modify-write CTRL bits
 * Steps:
 *   1. Read CTRL (pins read back as last written), clear then set the masks.
 * Returns: nothing.
 */
static void ctrl_update(const rtlnet_mdio_t *ctx, uint32_t clear, uint32_t set)
{
    uint32_t v = rtlnet_reg_read32(ctx->base, RTLNET_MDIO_REG_CTRL);

    rtlnet_reg_write32(ctx->base, RTLNET_MDIO_REG_CTRL, (v & ~clear) | set);
}

/*
 * rtlnet_mdio_init -- bind a context to a core and idle the bus
 * Steps:
 *   1. Check the arguments; store base, PHY address and hooks.
 *   2. Check the ID and VERSION registers.
 *   3. Set a conservative half_loops from CAPS (one loop iteration costs at
 *      least one clk cycle, so this is at least RTLNET_MDIO_HALF_TARGET_NS).
 *   4. Put the bus in the idle state (MDC low, line released).
 * Returns: RTLNET_MDIO_OK; RTLNET_MDIO_ERR_ARG for a NULL context or a PHY
 *   address above 31; RTLNET_MDIO_ERR_NO_DELAY without delay_us;
 *   RTLNET_MDIO_ERR_CORE_ID when ID or VERSION do not match.
 */
int rtlnet_mdio_init(rtlnet_mdio_t *ctx, uintptr_t base, uint8_t phy_addr,
                     rtlnet_mdio_delay_us_fn delay_us, void *user)
{
    uint32_t khz;

    if (ctx == NULL || phy_addr > RTLNET_MDIO_ADDR_MAX) {
        return RTLNET_MDIO_ERR_ARG;
    }
    if (delay_us == NULL) {
        return RTLNET_MDIO_ERR_NO_DELAY;
    }
    ctx->base = base;
    ctx->phy_addr = phy_addr;
    ctx->half_delay = NULL;
    ctx->delay_us = delay_us;
    ctx->user = user;
    ctx->half_loops = 0u;

    if (rtlnet_reg_read32(base, RTLNET_MDIO_REG_ID) != RTLNET_MDIO_ID_VALUE ||
        rtlnet_reg_read32(base, RTLNET_MDIO_REG_VERSION) != RTLNET_MDIO_VERSION_VALUE) {
        return RTLNET_MDIO_ERR_CORE_ID;
    }

    khz = rtlnet_mdio_caps_clk_khz(ctx);
    ctx->half_loops = (khz * RTLNET_MDIO_HALF_TARGET_NS) / (MDIO_NS_PER_US * MDIO_NS_PER_US) + 1u;

    pins(ctx, MDIO_PINS_IDLE);
    return RTLNET_MDIO_OK;
}

/*
 * rtlnet_mdio_set_half_delay -- install or remove the half-period hook
 * Steps:
 *   1. Store the hook; NULL returns to the half_loops spin.
 * Returns: nothing.
 */
void rtlnet_mdio_set_half_delay(rtlnet_mdio_t *ctx, rtlnet_mdio_half_delay_fn half_delay)
{
    if (ctx != NULL) {
        ctx->half_delay = half_delay;
    }
}

/*
 * rtlnet_mdio_set_half_loops -- set the spin count per MDC half period
 * Steps:
 *   1. Store the count (caller guarantees >= RTLNET_MDIO_HALF_MIN_NS).
 * Returns: nothing.
 */
void rtlnet_mdio_set_half_loops(rtlnet_mdio_t *ctx, uint32_t half_loops)
{
    if (ctx != NULL) {
        ctx->half_loops = half_loops;
    }
}

/*
 * cal_measure -- time RTLNET_MDIO_CAL_ITERS idle stores each followed by a spin
 * Steps:
 *   1. Read the timer, run the iterations (MDC stays low: no PHY clocking),
 *      read the timer again.
 * Returns: elapsed ticks (unsigned difference, wrap safe).
 */
static uint32_t cal_measure(const rtlnet_mdio_t *ctx, rtlnet_mdio_now_ticks_fn now_ticks, uint32_t loops)
{
    uint32_t t0 = now_ticks(ctx->user);

    for (uint32_t i = 0u; i < RTLNET_MDIO_CAL_ITERS; i++) {
        pins(ctx, MDIO_PINS_IDLE);
        spin(loops);
    }
    return now_ticks(ctx->user) - t0;
}

/*
 * rtlnet_mdio_calibrate -- size half_loops for a RTLNET_MDIO_HALF_TARGET_NS half period
 * Steps:
 *   1. Time the store-plus-spin step with 0 and with RTLNET_MDIO_CAL_LOOPS
 *      loops (two-point fit: store overhead and cost per loop).
 *   2. loops = ceil((target - overhead) / cost per loop), at least 0, at
 *      most RTLNET_MDIO_CAL_LOOPS_MAX.
 *   3. Store half_loops and report the estimated half period.
 * Returns: RTLNET_MDIO_OK; RTLNET_MDIO_ERR_ARG for NULL arguments or
 *   ticks_per_us 0; RTLNET_MDIO_ERR_CALIBRATE when the timer does not
 *   advance, the loop cost is not measurable or a measurement overflows
 *   (half_loops is left unchanged).
 */
int rtlnet_mdio_calibrate(rtlnet_mdio_t *ctx, rtlnet_mdio_now_ticks_fn now_ticks,
                          uint32_t ticks_per_us, uint32_t *half_ns_out)
{
    uint32_t t_base;
    uint32_t t_loop;
    uint32_t base_ns;
    uint32_t span_ns;
    uint32_t loops;

    if (ctx == NULL || now_ticks == NULL || ticks_per_us == 0u) {
        return RTLNET_MDIO_ERR_ARG;
    }
    t_base = cal_measure(ctx, now_ticks, 0u);
    t_loop = cal_measure(ctx, now_ticks, RTLNET_MDIO_CAL_LOOPS);
    if (t_loop <= t_base || t_loop > (UINT32_MAX / MDIO_NS_PER_US)) {
        return RTLNET_MDIO_ERR_CALIBRATE;
    }
    /* Per-iteration times in ns: store overhead, and the cost of CAL_LOOPS loops. */
    base_ns = (t_base * MDIO_NS_PER_US / ticks_per_us) / RTLNET_MDIO_CAL_ITERS;
    span_ns = ((t_loop - t_base) * MDIO_NS_PER_US / ticks_per_us) / RTLNET_MDIO_CAL_ITERS;
    if (span_ns == 0u) {
        return RTLNET_MDIO_ERR_CALIBRATE;
    }
    if (base_ns >= RTLNET_MDIO_HALF_TARGET_NS) {
        loops = 0u;
    } else {
        loops = ((RTLNET_MDIO_HALF_TARGET_NS - base_ns) * RTLNET_MDIO_CAL_LOOPS + span_ns - 1u) / span_ns;
    }
    if (loops > RTLNET_MDIO_CAL_LOOPS_MAX) {
        loops = RTLNET_MDIO_CAL_LOOPS_MAX;
    }
    ctx->half_loops = loops;
    if (half_ns_out != NULL) {
        *half_ns_out = base_ns + (loops * span_ns) / RTLNET_MDIO_CAL_LOOPS;
    }
    return RTLNET_MDIO_OK;
}

/*
 * rtlnet_mdio_caps_clk_khz -- core clock frequency from CAPS
 * Returns: CLK_HZ / 1000 of the core build.
 */
uint32_t rtlnet_mdio_caps_clk_khz(const rtlnet_mdio_t *ctx)
{
    return rtlnet_reg_read32(ctx->base, RTLNET_MDIO_REG_CAPS) & RTLNET_MDIO_CAPS_CLK_KHZ_MASK;
}

/*
 * rtlnet_mdio_caps_por_ms -- power-on PHY reset length from CAPS
 * Returns: POR_RESET_MS of the core build.
 */
uint32_t rtlnet_mdio_caps_por_ms(const rtlnet_mdio_t *ctx)
{
    return (rtlnet_reg_read32(ctx->base, RTLNET_MDIO_REG_CAPS) >> RTLNET_MDIO_CAPS_POR_MS_SHIFT) &
           RTLNET_MDIO_CAPS_POR_MS_MASK;
}

/*
 * rtlnet_mdio_read_addr -- Clause 22 read from any PHY address
 * Steps:
 *   1. 32 preamble ones, ST 01, OP 10, PHYAD, REGAD (master drives).
 *   2. TA: release the line; slot 1 is ignored, slot 2 must read 0 (the PHY
 *      drives it); a 1 means no PHY answered.
 *   3. 16 data bits, most significant first; then the idle slot.
 * Returns: RTLNET_MDIO_OK with *val set; RTLNET_MDIO_ERR_NO_PHY with *val =
 *   0xFFFF (the frame still completes); RTLNET_MDIO_ERR_ARG for a NULL
 *   pointer or an address above 31.
 */
int rtlnet_mdio_read_addr(const rtlnet_mdio_t *ctx, uint8_t phy_addr, uint8_t reg, uint16_t *val)
{
    if (ctx == NULL || val == NULL || phy_addr > RTLNET_MDIO_ADDR_MAX || reg > RTLNET_MDIO_ADDR_MAX) {
        return RTLNET_MDIO_ERR_ARG;
    }
    return read_frame(ctx, frame_word(RTLNET_MDIO_ST, RTLNET_MDIO_OP_READ, phy_addr, reg, 0u, 0u), val);
}

/*
 * rtlnet_mdio_write_addr -- Clause 22 write to any PHY address
 * Steps:
 *   1. 32 preamble ones, then ST 01, OP 01, PHYAD, REGAD, TA 10 and 16 data
 *      bits, all driven by the master; then the idle slot.
 * Returns: RTLNET_MDIO_OK; RTLNET_MDIO_ERR_ARG for a NULL context or an
 *   address above 31. A write cannot detect a missing PHY.
 */
int rtlnet_mdio_write_addr(const rtlnet_mdio_t *ctx, uint8_t phy_addr, uint8_t reg, uint16_t val)
{
    if (ctx == NULL || phy_addr > RTLNET_MDIO_ADDR_MAX || reg > RTLNET_MDIO_ADDR_MAX) {
        return RTLNET_MDIO_ERR_ARG;
    }
    write_frame(ctx, frame_word(RTLNET_MDIO_ST, RTLNET_MDIO_OP_WRITE, phy_addr, reg, RTLNET_MDIO_TA_WRITE, val));
    return RTLNET_MDIO_OK;
}

/*
 * rtlnet_mdio_read -- Clause 22 read from the context's PHY
 * Returns: as rtlnet_mdio_read_addr.
 */
int rtlnet_mdio_read(const rtlnet_mdio_t *ctx, uint8_t reg, uint16_t *val)
{
    if (ctx == NULL) {
        return RTLNET_MDIO_ERR_ARG;
    }
    return rtlnet_mdio_read_addr(ctx, ctx->phy_addr, reg, val);
}

/*
 * rtlnet_mdio_write -- Clause 22 write to the context's PHY
 * Returns: as rtlnet_mdio_write_addr.
 */
int rtlnet_mdio_write(const rtlnet_mdio_t *ctx, uint8_t reg, uint16_t val)
{
    if (ctx == NULL) {
        return RTLNET_MDIO_ERR_ARG;
    }
    return rtlnet_mdio_write_addr(ctx, ctx->phy_addr, reg, val);
}

/*
 * rtlnet_mdio_c45_addr -- Clause 45 address frame
 * Steps:
 *   1. 32 preamble ones, ST 00, OP 00, PRTAD (the context's PHY address),
 *      DEVAD, TA 10 and the 16-bit register address; then the idle slot.
 * Returns: RTLNET_MDIO_OK; RTLNET_MDIO_ERR_ARG for a NULL context or a devad
 *   above 31. A missing device cannot be detected by an address frame.
 */
int rtlnet_mdio_c45_addr(const rtlnet_mdio_t *ctx, uint8_t devad, uint16_t reg)
{
    if (ctx == NULL || devad > RTLNET_MDIO_ADDR_MAX) {
        return RTLNET_MDIO_ERR_ARG;
    }
    write_frame(ctx, frame_word(RTLNET_MDIO_C45_ST, RTLNET_MDIO_C45_OP_ADDR, ctx->phy_addr, devad,
                                RTLNET_MDIO_TA_WRITE, reg));
    return RTLNET_MDIO_OK;
}

/*
 * rtlnet_mdio_c45_write -- Clause 45 write
 * Steps:
 *   1. Address frame with reg.
 *   2. Write frame (OP 01, TA 10) with val.
 * Returns: as rtlnet_mdio_c45_addr.
 */
int rtlnet_mdio_c45_write(const rtlnet_mdio_t *ctx, uint8_t devad, uint16_t reg, uint16_t val)
{
    int rc = rtlnet_mdio_c45_addr(ctx, devad, reg);

    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    write_frame(ctx, frame_word(RTLNET_MDIO_C45_ST, RTLNET_MDIO_C45_OP_WRITE, ctx->phy_addr, devad,
                                RTLNET_MDIO_TA_WRITE, val));
    return RTLNET_MDIO_OK;
}

/*
 * rtlnet_mdio_c45_read -- Clause 45 read
 * Steps:
 *   1. Address frame with reg.
 *   2. Read frame (OP 11): TA released, the device drives TA bit 2 to 0, then
 *      16 data bits.
 * Returns: RTLNET_MDIO_OK with *val set; RTLNET_MDIO_ERR_NO_PHY with *val =
 *   0xFFFF when the device does not answer (both frames still complete);
 *   RTLNET_MDIO_ERR_ARG for a NULL pointer or a devad above 31.
 */
int rtlnet_mdio_c45_read(const rtlnet_mdio_t *ctx, uint8_t devad, uint16_t reg, uint16_t *val)
{
    int rc;

    if (val == NULL) {
        return RTLNET_MDIO_ERR_ARG;
    }
    rc = rtlnet_mdio_c45_addr(ctx, devad, reg);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    return read_frame(ctx, frame_word(RTLNET_MDIO_C45_ST, RTLNET_MDIO_C45_OP_READ, ctx->phy_addr, devad, 0u, 0u),
                      val);
}

/*
 * rtlnet_mdio_c45_read_inc -- Clause 45 post-read-increment-address read
 * Steps:
 *   1. One read frame with OP 10: the device returns the register at its
 *      current address for this DEVAD, then increments that address. The
 *      address comes from the preceding rtlnet_mdio_c45_addr (or c45_read).
 * Returns: as rtlnet_mdio_c45_read, without the address frame.
 */
int rtlnet_mdio_c45_read_inc(const rtlnet_mdio_t *ctx, uint8_t devad, uint16_t *val)
{
    if (ctx == NULL || val == NULL || devad > RTLNET_MDIO_ADDR_MAX) {
        return RTLNET_MDIO_ERR_ARG;
    }
    return read_frame(ctx, frame_word(RTLNET_MDIO_C45_ST, RTLNET_MDIO_C45_OP_READ_INC, ctx->phy_addr, devad, 0u, 0u),
                      val);
}

/*
 * mmd_select -- point the MMD access registers at a register
 * Steps:
 *   1. MACR (reg 13) = address function | devad.
 *   2. MAADR (reg 14) = register address.
 *   3. MACR = data function (no post increment) | devad.
 * Returns: RTLNET_MDIO_OK; RTLNET_MDIO_ERR_ARG for a NULL context or a devad
 *   above 31. The next MAADR access reaches the register.
 */
static int mmd_select(const rtlnet_mdio_t *ctx, uint8_t devad, uint16_t reg)
{
    if (ctx == NULL || devad > RTLNET_MDIO_ADDR_MAX) {
        return RTLNET_MDIO_ERR_ARG;
    }
    (void)rtlnet_mdio_write(ctx, RTLNET_MDIO_REG_MACR, (uint16_t)(RTLNET_MDIO_MACR_FUNC_ADDR | devad));
    (void)rtlnet_mdio_write(ctx, RTLNET_MDIO_REG_MAADR, reg);
    return rtlnet_mdio_write(ctx, RTLNET_MDIO_REG_MACR, (uint16_t)(RTLNET_MDIO_MACR_FUNC_DATA | devad));
}

/*
 * rtlnet_mdio_mmd_write -- Clause 45 register write through Clause 22 registers 13/14
 * Steps:
 *   1. mmd_select; then write MAADR with val.
 * MACR is left in the data function for devad. Annex 22D access; the RTL8211E
 * supports this form only.
 * Returns: RTLNET_MDIO_OK; RTLNET_MDIO_ERR_ARG. A write cannot detect a
 *   missing PHY.
 */
int rtlnet_mdio_mmd_write(const rtlnet_mdio_t *ctx, uint8_t devad, uint16_t reg, uint16_t val)
{
    int rc = mmd_select(ctx, devad, reg);

    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    return rtlnet_mdio_write(ctx, RTLNET_MDIO_REG_MAADR, val);
}

/*
 * rtlnet_mdio_mmd_read -- Clause 45 register read through Clause 22 registers 13/14
 * Steps:
 *   1. mmd_select; then read MAADR.
 * Returns: RTLNET_MDIO_OK with *val set; RTLNET_MDIO_ERR_NO_PHY with *val =
 *   0xFFFF when no PHY answers the read; RTLNET_MDIO_ERR_ARG for a NULL
 *   pointer or a devad above 31.
 */
int rtlnet_mdio_mmd_read(const rtlnet_mdio_t *ctx, uint8_t devad, uint16_t reg, uint16_t *val)
{
    int rc;

    if (val == NULL) {
        return RTLNET_MDIO_ERR_ARG;
    }
    rc = mmd_select(ctx, devad, reg);
    if (rc != RTLNET_MDIO_OK) {
        return rc;
    }
    return rtlnet_mdio_read(ctx, RTLNET_MDIO_REG_MAADR, val);
}

/*
 * rtlnet_mdio_wait_por -- wait for the core's power-on PHY reset and the PHY settle time
 * Steps:
 *   1. Poll STATUS.POR_DONE every RTLNET_MDIO_POR_POLL_US, at most
 *      RTLNET_MDIO_POR_POLL_MAX times.
 *   2. Wait RTLNET_MDIO_RESET_SETTLE_US (the PHY needs 30 ms after PHYRSTB
 *      rises before the first register access).
 * Returns: RTLNET_MDIO_OK; RTLNET_MDIO_ERR_ARG for a NULL context;
 *   RTLNET_MDIO_ERR_TIMEOUT when POR_DONE does not set.
 */
int rtlnet_mdio_wait_por(const rtlnet_mdio_t *ctx)
{
    uint32_t polls = 0u;

    if (ctx == NULL) {
        return RTLNET_MDIO_ERR_ARG;
    }
    while ((rtlnet_reg_read32(ctx->base, RTLNET_MDIO_REG_STATUS) & RTLNET_MDIO_STATUS_POR_DONE) == 0u) {
        if (polls >= RTLNET_MDIO_POR_POLL_MAX) {
            return RTLNET_MDIO_ERR_TIMEOUT;
        }
        ctx->delay_us(ctx->user, RTLNET_MDIO_POR_POLL_US);
        polls++;
    }
    ctx->delay_us(ctx->user, RTLNET_MDIO_RESET_SETTLE_US);
    return RTLNET_MDIO_OK;
}

/*
 * rtlnet_mdio_phy_reset -- pulse the PHY hardware reset
 * Steps:
 *   1. Idle the bus; set CTRL.PHY_RESET (phy_rst_n low).
 *   2. Wait RTLNET_MDIO_RESET_LOW_US (datasheet minimum 10 ms).
 *   3. Clear CTRL.PHY_RESET; wait RTLNET_MDIO_RESET_SETTLE_US (minimum 30 ms
 *      before the first register access).
 * Every PHY register returns to its default, so the RX delay must be set
 * again afterwards (rtlnet_phy_rtl8211e_enable_rx_delay).
 * Returns: RTLNET_MDIO_OK; RTLNET_MDIO_ERR_ARG for a NULL context.
 */
int rtlnet_mdio_phy_reset(const rtlnet_mdio_t *ctx)
{
    if (ctx == NULL) {
        return RTLNET_MDIO_ERR_ARG;
    }
    pins(ctx, MDIO_PINS_IDLE);
    ctrl_update(ctx, 0u, RTLNET_MDIO_CTRL_PHY_RESET);
    ctx->delay_us(ctx->user, RTLNET_MDIO_RESET_LOW_US);
    ctrl_update(ctx, RTLNET_MDIO_CTRL_PHY_RESET, 0u);
    ctx->delay_us(ctx->user, RTLNET_MDIO_RESET_SETTLE_US);
    return RTLNET_MDIO_OK;
}

/*
 * rtlnet_mdio_irq_enable -- gate the PHY interrupt onto the core's irq output
 * Steps:
 *   1. Set or clear CTRL.IRQ_EN.
 * Returns: nothing.
 */
void rtlnet_mdio_irq_enable(const rtlnet_mdio_t *ctx, int enable)
{
    if (ctx == NULL) {
        return;
    }
    if (enable != 0) {
        ctrl_update(ctx, 0u, RTLNET_MDIO_CTRL_IRQ_EN);
    } else {
        ctrl_update(ctx, RTLNET_MDIO_CTRL_IRQ_EN, 0u);
    }
}

/*
 * rtlnet_mdio_phy_int_asserted -- PHY interrupt line state
 * Returns: 1 while the PHY holds INTB low (independent of IRQ_EN), else 0.
 */
int rtlnet_mdio_phy_int_asserted(const rtlnet_mdio_t *ctx)
{
    return (rtlnet_mdio_status(ctx) & RTLNET_MDIO_STATUS_PHY_INT) != 0u;
}

/*
 * rtlnet_mdio_status -- raw STATUS register
 * Returns: the STATUS word (RTLNET_MDIO_STATUS_* bits), 0 for a NULL context.
 */
uint32_t rtlnet_mdio_status(const rtlnet_mdio_t *ctx)
{
    if (ctx == NULL) {
        return 0u;
    }
    return rtlnet_reg_read32(ctx->base, RTLNET_MDIO_REG_STATUS);
}
