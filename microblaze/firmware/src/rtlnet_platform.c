/*
 * rtlnet_platform.c -- MicroBlaze implementation of the platform services on
 *                      the generated standalone BSP
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: console on XUartLite, time on XTmrCtr (timer 0 free running at
 * cpu_clk for ticks and delays, timer 1 auto-reload with a 1 ms interrupt),
 * interrupt setup on XIntc, the LED shadow with the heartbeat on led[1], and
 * soft restart. See rtlnet_platform.h for the contract. The BSP drivers are
 * the only code that touches the UART, timer and INTC registers; their base
 * addresses come from rtlnet_cpu_microblaze.h (the same values as the BSP's
 * xparameters.h).
 *
 * Context rules: the 1 ms timer interrupt only increments g_ms (volatile,
 * written by the interrupt, read by the main loop with a single 32-bit
 * load). Everything else, lwIP included, runs in the main loop.
 *
 * Failure policy: a BSP driver that does not initialize (status other than
 * XST_SUCCESS) is reported on the console with the API name and code once the
 * UART is up; the firmware then continues without that service (polled time
 * from timer 0 still works without the interrupt).
 */
#include "rtlnet_platform.h"

#include "rtlnet_board.h"

#include "xil_cache.h"      /* Xil_DCacheFlushRange, Xil_DCacheInvalidateRange */
#include "xil_exception.h"  /* Xil_ExceptionInit, Xil_ExceptionRegisterHandler, Xil_ExceptionEnable, Xil_ExceptionDisable */
#include "xintc.h"          /* XIntc */
#include "xstatus.h"        /* XST_SUCCESS */
#include "xtmrctr.h"        /* XTmrCtr */
#include "xuartlite.h"      /* XUartLite */
#include "xuartlite_l.h"    /* XUartLite_IsTransmitFull, XUartLite_IsReceiveEmpty, register offsets */

#define PLAT_UART_DRAIN_MS   20u        /* 16-character FIFO at 115200 baud drains in 1.4 ms */
#define PLAT_TMR_FREE        0u         /* XTmrCtr counter 0: free running */
#define PLAT_TMR_TICK        1u         /* XTmrCtr counter 1: 1 ms interrupt */
#define PLAT_TICKS_PER_MS    (RTLNET_PLAT_CPU_CLK_HZ / 1000u)
/* Bound on the wait for TX FIFO space: 16 characters at 115200 baud take
 * 1.4 ms; about 10 status reads per microsecond, so 200000 reads is about
 * 20 ms, far above the drain time. A timeout drops the character. */
#define PLAT_UART_TX_WAIT    200000u
#define PLAT_RX_RING         256u       /* software receive ring, power of two */

static XUartLite g_uart;
static XTmrCtr   g_tmr;
static XIntc     g_intc;
static uint32_t  g_led_bits;            /* LEDS register shadow, bits [7:1] */
static uint32_t  g_heartbeat_next_ms;
static volatile uint32_t g_ms;          /* 1 ms tick: written by the timer interrupt only */
static int       g_tick_irq;            /* 1 when the 1 ms interrupt runs */
static uint8_t   g_rx_ring[PLAT_RX_RING];
static unsigned  g_rx_head;
static unsigned  g_rx_tail;
static uint32_t  g_last_ticks;          /* polled fallback when the interrupt is not running */
static uint32_t  g_tick_rem;

/*
 * plat_tick_isr -- XTmrCtr callback of counter 1 (1 ms period).
 * Steps:
 *   1. Count the millisecond (XTmrCtr_InterruptHandler acknowledges).
 * Returns: nothing.
 */
static void plat_tick_isr(void *ref, u8 counter)
{
    (void)ref;
    if (counter == PLAT_TMR_TICK) {
        g_ms++;
    }
}

/*
 * plat_rx_pull -- move characters from the UART receive FIFO into the ring.
 * Returns: nothing; characters arriving with the ring full stay in the FIFO.
 */
static void plat_rx_pull(void)
{
    while (!XUartLite_IsReceiveEmpty(RTLNET_PLAT_UART_BASE)) {
        unsigned next = (g_rx_head + 1u) & (PLAT_RX_RING - 1u);
        if (next == g_rx_tail) {
            return;
        }
        g_rx_ring[g_rx_head] = (uint8_t)XUartLite_ReadReg(RTLNET_PLAT_UART_BASE, XUL_RX_FIFO_OFFSET);
        g_rx_head = next;
    }
}

/*
 * plat_putc -- send one character, keeping the receive side drained.
 * Returns: nothing; the character is dropped after PLAT_UART_TX_WAIT reads.
 */
static void plat_putc(char c)
{
    uint32_t n = 0u;
    while (XUartLite_IsTransmitFull(RTLNET_PLAT_UART_BASE)) {
        plat_rx_pull();
        if (++n >= PLAT_UART_TX_WAIT) {
            return;
        }
    }
    XUartLite_WriteReg(RTLNET_PLAT_UART_BASE, XUL_TX_FIFO_OFFSET, (u32)(uint8_t)c);
}

/*
 * plat_init -- bring up console, time base and interrupts, clear the LEDs.
 * Steps:
 *   1. XUartLite_Initialize at the console UART (FIFOs reset).
 *   2. XTmrCtr_Initialize; counter 0 free running (auto reload from 0),
 *      counter 1 down-counting auto reload of one millisecond with interrupt.
 *   3. XIntc_Initialize, connect the timer handler on INTC input
 *      RTLNET_CPU_IRQ_TIMER, start in real mode, enable the input; register
 *      the INTC handler as the MicroBlaze interrupt and enable interrupts.
 *   4. LEDS register cleared (led[0] stays hardware-owned).
 * Returns: nothing; failures are printed with the API name and status.
 */
void plat_init(void)
{
    int st_uart;
    int st_tmr;
    int st_intc = XST_FAILURE;

    Xil_ExceptionDisable();
    g_rx_head = 0u;
    g_rx_tail = 0u;
    g_ms = 0u;
    g_tick_irq = 0;
    g_tick_rem = 0u;
    st_uart = XUartLite_Initialize(&g_uart, RTLNET_PLAT_UART_BASE);
    if (st_uart == XST_SUCCESS) {
        XUartLite_ResetFifos(&g_uart);
    }

    st_tmr = XTmrCtr_Initialize(&g_tmr, RTLNET_PLAT_TIMER_BASE);
    if (st_tmr == XST_SUCCESS || st_tmr == XST_DEVICE_IS_STARTED) {
        XTmrCtr_Stop(&g_tmr, PLAT_TMR_FREE);
        XTmrCtr_Stop(&g_tmr, PLAT_TMR_TICK);
        XTmrCtr_SetOptions(&g_tmr, PLAT_TMR_FREE, XTC_AUTO_RELOAD_OPTION);
        XTmrCtr_SetResetValue(&g_tmr, PLAT_TMR_FREE, 0u);
        XTmrCtr_Reset(&g_tmr, PLAT_TMR_FREE);
        XTmrCtr_Start(&g_tmr, PLAT_TMR_FREE);
        g_last_ticks = XTmrCtr_GetValue(&g_tmr, PLAT_TMR_FREE);
        st_tmr = XST_SUCCESS;

        st_intc = XIntc_Initialize(&g_intc, RTLNET_PLAT_INTC_BASE);
        if (st_intc == XST_SUCCESS) {
            st_intc = XIntc_Connect(&g_intc, RTLNET_CPU_IRQ_TIMER, (XInterruptHandler)XTmrCtr_InterruptHandler, &g_tmr);
        }
        if (st_intc == XST_SUCCESS) {
            st_intc = XIntc_Start(&g_intc, XIN_REAL_MODE);
        }
        if (st_intc == XST_SUCCESS) {
            XTmrCtr_SetHandler(&g_tmr, plat_tick_isr, NULL);
            XTmrCtr_SetOptions(&g_tmr, PLAT_TMR_TICK,
                               XTC_INT_MODE_OPTION | XTC_AUTO_RELOAD_OPTION | XTC_DOWN_COUNT_OPTION);
            XTmrCtr_SetResetValue(&g_tmr, PLAT_TMR_TICK, PLAT_TICKS_PER_MS - 1u);
            XTmrCtr_Reset(&g_tmr, PLAT_TMR_TICK);
            XIntc_Enable(&g_intc, RTLNET_CPU_IRQ_TIMER);
            Xil_ExceptionInit();
            Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT, (Xil_ExceptionHandler)XIntc_InterruptHandler, &g_intc);
            XTmrCtr_Start(&g_tmr, PLAT_TMR_TICK);
            Xil_ExceptionEnable();
            g_tick_irq = 1;
        }
    }

    g_led_bits = 0u;
    board_sys_write(NXV_SYS_LEDS, g_led_bits);
    g_heartbeat_next_ms = RTLNET_PLAT_HEARTBEAT_MS;
    if (st_uart != XST_SUCCESS || st_tmr != XST_SUCCESS || st_intc != XST_SUCCESS) {
        static const char msg[] = "\r\n% platform: XUartLite/XTmrCtr/XIntc initialization failed\r\n";
        plat_console_write(msg, sizeof(msg) - 1u);
    }
}

/*
 * plat_console_write -- send console text ("\n" becomes "\r\n").
 * Returns: nothing.
 */
void plat_console_write(const char *s, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '\n') {
            plat_putc('\r');
        }
        plat_putc(s[i]);
    }
}

/*
 * plat_console_getc -- non-blocking console read (ring first, then FIFO).
 * Returns: character 0..255, or -1 when none is waiting.
 */
int plat_console_getc(void)
{
    int c;
    plat_rx_pull();
    if (g_rx_tail == g_rx_head) {
        return -1;
    }
    c = (int)g_rx_ring[g_rx_tail];
    g_rx_tail = (g_rx_tail + 1u) & (PLAT_RX_RING - 1u);
    return c;
}

/*
 * plat_uptime_ms -- milliseconds since plat_init.
 * Steps:
 *   1. With the 1 ms interrupt running: the interrupt counter.
 *   2. Otherwise: advance a software count from timer 0 (must be called
 *      at least once per 42.9 s wrap, which the main loop does).
 * Returns: elapsed milliseconds (wraps after 49.7 days).
 */
uint32_t plat_uptime_ms(void)
{
    uint32_t now;
    if (g_tick_irq) {
        return g_ms;
    }
    now = XTmrCtr_GetValue(&g_tmr, PLAT_TMR_FREE);
    g_tick_rem += now - g_last_ticks;
    g_last_ticks = now;
    while (g_tick_rem >= PLAT_TICKS_PER_MS) {
        g_tick_rem -= PLAT_TICKS_PER_MS;
        g_ms++;
    }
    return g_ms;
}

/*
 * plat_ticks -- free-running 32-bit cpu_clk tick counter.
 * Returns: XTmrCtr counter 0.
 */
uint32_t plat_ticks(void)
{
    return XTmrCtr_GetValue(&g_tmr, PLAT_TMR_FREE);
}

/*
 * plat_delay_us -- busy-wait on the free-running counter.
 * Returns: nothing.
 */
void plat_delay_us(uint32_t us)
{
    uint32_t t0 = plat_ticks();
    uint32_t span = us * RTLNET_PLAT_TICKS_PER_US;
    while ((plat_ticks() - t0) < span) {
    }
}

/*
 * plat_delay_ms -- busy-wait in 1 ms steps (no 32-bit tick overflow).
 * Returns: nothing.
 */
void plat_delay_ms(uint32_t ms)
{
    while (ms-- > 0u) {
        plat_delay_us(1000u);
    }
}

/*
 * plat_poll -- periodic main-loop work: heartbeat LED.
 * Steps:
 *   1. Every RTLNET_PLAT_HEARTBEAT_MS toggle led[1] in the LEDS register.
 * Returns: nothing.
 */
void plat_poll(void)
{
    uint32_t now = plat_uptime_ms();
    if ((int32_t)(now - g_heartbeat_next_ms) >= 0) {
        g_heartbeat_next_ms = now + RTLNET_PLAT_HEARTBEAT_MS;
        g_led_bits ^= NXV_LED_HEARTBEAT;
        board_sys_write(NXV_SYS_LEDS, g_led_bits);
    }
}

/*
 * plat_led_set -- set or clear one firmware LED (index 1..7).
 * Returns: nothing; index 0 (hardware lock LED) and out-of-range are ignored.
 */
void plat_led_set(unsigned index, int on)
{
    uint32_t mask;
    if (index < 1u || index > 7u) {
        return;
    }
    mask = 1u << index;
    g_led_bits = on ? (g_led_bits | mask) : (g_led_bits & ~mask);
    board_sys_write(NXV_SYS_LEDS, g_led_bits);
}

/*
 * plat_led_state -- LED register as last written by the firmware.
 * Returns: bits [7:1] of the LEDS shadow.
 */
uint32_t plat_led_state(void)
{
    return g_led_bits;
}

/*
 * plat_cache_span -- widen a byte range to whole cache lines.
 * Steps:
 *   1. Round the start down and the end up to RTLNET_PLAT_CACHE_LINE.
 *      (The BSP range routines skip a partial last line, so the span handed to
 *      them is always line aligned at both ends.)
 * Returns: nothing; *start and *bytes hold the aligned span.
 */
static void plat_cache_span(uintptr_t addr, size_t len, uintptr_t *start, size_t *bytes)
{
    uintptr_t first = addr & ~(uintptr_t)(RTLNET_PLAT_CACHE_LINE - 1u);
    uintptr_t last  = (addr + len + (RTLNET_PLAT_CACHE_LINE - 1u)) & ~(uintptr_t)(RTLNET_PLAT_CACHE_LINE - 1u);
    *start = first;
    *bytes = (size_t)(last - first);
}

/*
 * plat_dcache_flush_range -- write back and invalidate the data cache lines of a range.
 * Steps:
 *   1. Widen the range to whole lines; an empty range does nothing.
 *   2. Xil_DCacheFlushRange (BSP, cbo.flush per line).
 * Returns: nothing.
 */
void plat_dcache_flush_range(uintptr_t addr, size_t len)
{
    uintptr_t start;
    size_t bytes;
    if (len == 0u) {
        return;
    }
    plat_cache_span(addr, len, &start, &bytes);
    Xil_DCacheFlushRange(start, (unsigned)bytes);
}

/*
 * plat_dcache_invalidate_range -- drop the data cache lines of a range.
 * Steps:
 *   1. Widen the range to whole lines; an empty range does nothing.
 *   2. Xil_DCacheInvalidateRange (BSP, cbo.inval per line).
 * Returns: nothing.
 */
void plat_dcache_invalidate_range(uintptr_t addr, size_t len)
{
    uintptr_t start;
    size_t bytes;
    if (len == 0u) {
        return;
    }
    plat_cache_span(addr, len, &start, &bytes);
    Xil_DCacheInvalidateRange(start, (unsigned)bytes);
}

/*
 * plat_mem_barrier -- order earlier memory accesses before later ones (RISC-V fence).
 * Returns: nothing.
 */
void plat_mem_barrier(void)
{
    __asm__ volatile ("fence" ::: "memory");
}

/*
 * plat_dcache_flush_all -- write back and invalidate the whole data cache.
 * Returns: nothing.
 */
void plat_dcache_flush_all(void)
{
    Xil_DCacheFlush();
}

/*
 * plat_dcache_invalidate_all -- drop every line of the data cache.
 * Returns: nothing.
 */
void plat_dcache_invalidate_all(void)
{
    Xil_DCacheInvalidate();
}

/*
 * plat_reload -- soft restart: let the console drain, stop interrupts and
 * timers, then jump to the reset vector (the BSP start-up clears .bss and
 * runs main again; .data is not reloaded, so no firmware state relies on a
 * .data initial value).
 * Returns: never.
 */
void plat_reload(void)
{
    plat_delay_ms(PLAT_UART_DRAIN_MS);
    Xil_ExceptionDisable();
    if (g_tick_irq) {
        XTmrCtr_Stop(&g_tmr, PLAT_TMR_TICK);
        XIntc_Stop(&g_intc);
    }
    __asm__ volatile ("jr zero" ::: "memory");
    for (;;) {
    }
}
