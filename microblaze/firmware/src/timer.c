/*
 * timer.c -- AXI Timer free-running tick, uptime and delays
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Owns the AXI Timer registers; see timer.h for the contract.
 * State g_ticks_hi / g_ticks_last is touched from the main loop only (no
 * interrupt context reads or writes it).
 */
#include "timer.h"

#include "rtlnet_mmio.h"

static uintptr_t g_timer_base;
static uint32_t  g_ticks_per_us;
static uint32_t  g_ticks_per_ms;
static uint32_t  g_ticks_hi;
static uint32_t  g_ticks_last;

/*
 * timer_init -- start timer 0 as a free-running up-counter.
 * Steps:
 *   1. Stop the timer, load 0 from TLR0.
 *   2. Enable it counting up with auto reload (wraps at 2^32).
 *   3. Derive ticks per microsecond and per millisecond from clk_hz.
 * Returns: nothing.
 */
void timer_init(uintptr_t base, uint32_t clk_hz)
{
    g_timer_base   = base;
    g_ticks_per_us = clk_hz / 1000000u;
    g_ticks_per_ms = clk_hz / 1000u;
    g_ticks_hi     = 0u;
    g_ticks_last   = 0u;
    rtlnet_reg_write32(g_timer_base, TIMER_TCSR0, 0u);
    rtlnet_reg_write32(g_timer_base, TIMER_TLR0, 0u);
    rtlnet_reg_write32(g_timer_base, TIMER_TCSR0, TIMER_TCSR_LOAD);
    rtlnet_reg_write32(g_timer_base, TIMER_TCSR0, TIMER_TCSR_ENT | TIMER_TCSR_ARHT);
}

/*
 * timer_ticks -- raw 32-bit counter value.
 * Returns: TCR0 (cpu_clk ticks, wraps every 2^32).
 */
uint32_t timer_ticks(void)
{
    return rtlnet_reg_read32(g_timer_base, TIMER_TCR0);
}

/*
 * timer_ticks64 -- 64-bit tick count since timer_init.
 * Steps:
 *   1. Read TCR0; a value below the previous read means one wrap.
 *   2. Combine with the software high word.
 * Returns: ticks since timer_init (valid while called at least once per wrap).
 */
uint64_t timer_ticks64(void)
{
    uint32_t now = timer_ticks();
    if (now < g_ticks_last) {
        g_ticks_hi++;
    }
    g_ticks_last = now;
    return ((uint64_t)g_ticks_hi << 32) | now;
}

/*
 * timer_uptime_ms -- milliseconds since timer_init.
 * Returns: elapsed milliseconds, truncated to 32 bits (wraps after 49 days).
 */
uint32_t timer_uptime_ms(void)
{
    return (uint32_t)(timer_ticks64() / g_ticks_per_ms);
}

/*
 * timer_delay_us -- busy-wait at least us microseconds.
 * Steps:
 *   1. Wait until the 32-bit tick difference reaches us * ticks_per_us.
 *      Delays above 42 s are split into 1 s pieces so the difference never
 *      wraps.
 * Returns: nothing.
 */
void timer_delay_us(uint32_t us)
{
    const uint32_t chunk_us = 1000000u;
    while (us > 0u) {
        uint32_t part  = (us > chunk_us) ? chunk_us : us;
        uint32_t want  = part * g_ticks_per_us;
        uint32_t start = timer_ticks();
        while ((uint32_t)(timer_ticks() - start) < want) {
            (void)timer_ticks64();
        }
        us -= part;
    }
}

/*
 * timer_delay_ms -- busy-wait at least ms milliseconds.
 * Returns: nothing.
 */
void timer_delay_ms(uint32_t ms)
{
    while (ms > 0u) {
        timer_delay_us(1000u);
        ms--;
    }
}
