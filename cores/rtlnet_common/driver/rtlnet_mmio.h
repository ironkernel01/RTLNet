/*
 * rtlnet_mmio.h -- RTLNet register access primitives
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of how every RTLNet driver touches hardware
 * registers. Drivers never dereference a register address themselves; they
 * call rtlnet_reg_read32() / rtlnet_reg_write32() with the core's base
 * address (passed in by the platform layer, never hard-coded in a driver)
 * and a byte offset from the core's driver header.
 *
 * Two builds:
 *   - Target (default): volatile 32-bit loads and stores. AXI4-Lite cores
 *     answer full 32-bit words only; partial writes are ignored by the RTL.
 *   - Host unit test (RTLNET_HOST_TEST defined): every access calls a hook
 *     the test provides, so a driver can run against a register model on the
 *     PC with the host gcc.
 *
 * This header holds signatures and contract prose; there is no .c file.
 */
#ifndef RTLNET_MMIO_H
#define RTLNET_MMIO_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#ifdef RTLNET_HOST_TEST

/* Provided by the host unit test. */
uint32_t rtlnet_host_reg_read32(uintptr_t addr);
void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value);

static inline uint32_t rtlnet_reg_read32(uintptr_t base, uint32_t offset)
{
    return rtlnet_host_reg_read32(base + offset);
}

static inline void rtlnet_reg_write32(uintptr_t base, uint32_t offset, uint32_t value)
{
    rtlnet_host_reg_write32(base + offset, value);
}

#else

static inline uint32_t rtlnet_reg_read32(uintptr_t base, uint32_t offset)
{
    return *(volatile const uint32_t *)(base + offset);
}

static inline void rtlnet_reg_write32(uintptr_t base, uint32_t offset, uint32_t value)
{
    *(volatile uint32_t *)(base + offset) = value;
}

#endif

/* Read-modify-write helpers: set or clear the bits of mask. Not atomic with
 * respect to interrupts; RTLNet firmware touches each core from one context. */
static inline void rtlnet_reg_set_bits(uintptr_t base, uint32_t offset, uint32_t mask)
{
    rtlnet_reg_write32(base, offset, rtlnet_reg_read32(base, offset) | mask);
}

static inline void rtlnet_reg_clear_bits(uintptr_t base, uint32_t offset, uint32_t mask)
{
    rtlnet_reg_write32(base, offset, rtlnet_reg_read32(base, offset) & ~mask);
}

/* Standard header present in every RTLNet core (architecture section 5). */
#define RTLNET_REG_ID       0x000u   /* four ASCII characters */
#define RTLNET_REG_VERSION  0x004u   /* register-map date code 0xMMDDYYYY */
#define RTLNET_REG_CAPS     0x008u   /* build parameters */

#endif /* RTLNET_MMIO_H */
