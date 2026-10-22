/*
 * timer.h -- AXI Timer free-running tick, uptime and delays
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches the AXI Timer registers. Timer 0 counts
 * up at cpu_clk (100 MHz) and wraps every 42.9 s; timer_ticks64() extends it
 * to 64 bits in software, so it (or any function below) must run at least
 * once per wrap -- the main loop calls it continuously.
 *
 * Register map (AXI Timer product guide): TCSR0 0x00, TLR0 0x04, TCR0 0x08.
 *
 * This header holds signatures and constants; timer.c holds the commentary.
 */
#ifndef TIMER_H
#define TIMER_H

#include <stdint.h>   /* uint32_t, uint64_t, uintptr_t */

#define TIMER_TCSR0          0x00u
#define TIMER_TLR0           0x04u
#define TIMER_TCR0           0x08u

#define TIMER_TCSR_ARHT      0x00000010u   /* auto reload */
#define TIMER_TCSR_LOAD      0x00000020u   /* load TLR into the counter */
#define TIMER_TCSR_ENT       0x00000080u   /* enable */

void     timer_init(uintptr_t base, uint32_t clk_hz);
uint32_t timer_ticks(void);
uint64_t timer_ticks64(void);
uint32_t timer_uptime_ms(void);
void     timer_delay_us(uint32_t us);
void     timer_delay_ms(uint32_t ms);

#endif /* TIMER_H */
