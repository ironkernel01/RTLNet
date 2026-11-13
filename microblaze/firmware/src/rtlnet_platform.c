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
 * Console transmit: plat_putc writes into a 4 KiB ring (rtlnet_txring.c) and returns; the UART interrupt (INTC input RTLNET_CPU_IRQ_UART,
 * edge, raised when the transmit FIFO empties and when a character arrives) refills the 16-character FIFO from the ring and moves received
 * characters into the receive ring. The main loop touches the transmit ring and the receive ring only with interrupts masked (plat_irq_save
 * and plat_irq_restore, nesting safe), so the interrupt and the main loop never see a ring half updated. A full ring makes the caller
 * wait (bounded by PLAT_UART_TX_WAIT polls of the FIFO, which the main loop refills itself); only a wait that times out loses a character,
 * and it is counted (plat_console_tx_stats, drops). Until the interrupt is running (plat_init, a failed INTC setup) the console is polled.
 *
 * Peripheral interrupts of the application: plat_irq_attach connects a handler on an INTC input (RTLNET_CPU_IRQ_*) and plat_irq_enable
 * unmasks or masks that input; the encoder's handler (INTC input RTLNET_CPU_IRQ_H264) uses them. A handler runs with the CPU interrupts
 * masked (no nesting), so it must be short; plat_irq_save and plat_irq_restore give the main loop a critical section against it.
 *
 * Failure policy: a BSP driver that does not initialize (status other than
 * XST_SUCCESS) is reported on the console with the API name and code once the
 * UART is up; the firmware then continues without that service (polled time
 * from timer 0 still works without the interrupt).
 */
#include "rtlnet_platform.h"

#include "rtlnet_board.h"
#include "rtlnet_txring.h"

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
#define PLAT_TX_RING         4096u      /* software transmit ring, power of two */
#define PLAT_RELOAD_TX_MS    500u       /* most time plat_reload waits for the transmit ring to drain */
#define PLAT_MSTATUS_MIE     8u         /* RISC-V mstatus machine interrupt enable bit */

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
static uint8_t   g_tx_buf[PLAT_TX_RING];
static txring_t  g_tx;                  /* transmit ring: put by the main loop, taken by the interrupt and the main loop (interrupts masked) */
static volatile int g_tx_busy;          /* 1 while characters are in the UART FIFO and a transmit-empty interrupt is due */
static int       g_uart_irq;            /* 1 when the UART interrupt runs: transmit through the ring */
static volatile uint32_t g_tx_irqs;     /* UART interrupts */
static volatile uint32_t g_tx_refills;  /* FIFO refills made by the main loop (a full ring waiting, or the poll below) */
static volatile uint32_t g_tx_drops;    /* characters lost: a full ring whose wait timed out (PLAT_ERR_TX_TIMEOUT) */
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
 * plat_irq_save -- mask interrupts and return the previous state (nesting safe).
 * Returns: the mstatus value before the change, for plat_irq_restore.
 */
uint32_t plat_irq_save(void)
{
    uint32_t s;
    __asm__ volatile ("csrrci %0, mstatus, 8" : "=r"(s) : : "memory");
    return s;
}

/* plat_irq_restore -- unmask interrupts when plat_irq_save found them unmasked. */
void plat_irq_restore(uint32_t s)
{
    if ((s & PLAT_MSTATUS_MIE) != 0u) {
        __asm__ volatile ("csrsi mstatus, 8" : : : "memory");
    }
}

/*
 * plat_irq_attach -- connect a handler on an INTC input; the input stays masked until plat_irq_enable.
 * Returns: 0 on success, -1 when the interrupt controller is not running or the connect failed.
 */
int plat_irq_attach(unsigned input, void (*handler)(void *), void *ref)
{
    if (!g_tick_irq || (input >= RTLNET_CPU_IRQ_COUNT) || (handler == NULL)) {
        return -1;
    }
    return (XIntc_Connect(&g_intc, (u8)input, (XInterruptHandler)handler, ref) == XST_SUCCESS) ? 0 : -1;
}

/* plat_irq_enable -- unmask (on != 0) or mask an INTC input. */
void plat_irq_enable(unsigned input, int on)
{
    if (!g_tick_irq || (input >= RTLNET_CPU_IRQ_COUNT)) {
        return;
    }
    if (on != 0) {
        XIntc_Enable(&g_intc, (u8)input);
    } else {
        XIntc_Disable(&g_intc, (u8)input);
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
 * plat_tx_fill -- move characters from the transmit ring into the UART FIFO until the FIFO is full or the ring is empty.
 * Called with interrupts masked (from the interrupt, or between plat_irq_save and plat_irq_restore).
 * Steps: write while the FIFO has room; when something was written a transmit-empty interrupt is due (busy); when nothing was written
 * and the FIFO is empty, no interrupt is due (not busy).
 * Returns: nothing.
 */
static void plat_tx_fill(void)
{
    uint32_t wrote = 0u;
    while (!XUartLite_IsTransmitFull(RTLNET_PLAT_UART_BASE)) {
        int c = txring_get(&g_tx);
        if (c < 0) {
            break;
        }
        XUartLite_WriteReg(RTLNET_PLAT_UART_BASE, XUL_TX_FIFO_OFFSET, (u32)c);
        wrote++;
    }
    if (wrote != 0u) {
        g_tx_busy = 1;
    } else if ((XUartLite_GetStatusReg(RTLNET_PLAT_UART_BASE) & XUL_SR_TX_FIFO_EMPTY) != 0u) {
        g_tx_busy = 0;
    }
}

/*
 * plat_uart_isr -- INTC handler of the UART (edge: transmit FIFO became empty, or a character arrived).
 * Steps: count; move received characters into the receive ring; refill the transmit FIFO from the ring.
 * Returns: nothing.
 */
static void plat_uart_isr(void *ref)
{
    (void)ref;
    g_tx_irqs++;
    plat_rx_pull();
    plat_tx_fill();
}

/*
 * plat_putc -- queue one character for transmission, keeping the receive side drained.
 * Steps: with the interrupt running, put the character in the ring and, when no transmit-empty interrupt is due, prime the FIFO from
 * the ring; a full ring is waited out (the main loop refills the FIFO itself and pulls received characters) for at most
 * PLAT_UART_TX_WAIT polls. Without the interrupt: poll the FIFO.
 * Returns: nothing; the character is lost only when the wait times out (counted in g_tx_drops).
 */
static void plat_putc(char c)
{
    uint32_t n = 0u;
    if (!g_uart_irq) {
        while (XUartLite_IsTransmitFull(RTLNET_PLAT_UART_BASE)) {
            plat_rx_pull();
            if (++n >= PLAT_UART_TX_WAIT) {
                return;
            }
        }
        XUartLite_WriteReg(RTLNET_PLAT_UART_BASE, XUL_TX_FIFO_OFFSET, (u32)(uint8_t)c);
        return;
    }
    for (;;) {
        uint32_t s = plat_irq_save();
        if (txring_put(&g_tx, (uint8_t)c) == TXRING_OK) {
            if (!g_tx_busy) {
                plat_tx_fill();
            }
            plat_irq_restore(s);
            return;
        }
        if (!XUartLite_IsTransmitFull(RTLNET_PLAT_UART_BASE)) {
            plat_tx_fill();   /* the ring is full but the FIFO has room: an interrupt is late or lost, refill here */
            g_tx_refills++;
        }
        plat_rx_pull();
        plat_irq_restore(s);
        if (++n >= PLAT_UART_TX_WAIT) {
            g_tx_drops++;
            return;
        }
    }
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
    int st_uirq = XST_FAILURE;

    Xil_ExceptionDisable();
    XUartLite_DisableIntr(RTLNET_PLAT_UART_BASE);   /* a soft restart can leave the enable set */
    g_uart_irq = 0;
    g_tx_busy = 0;
    (void)txring_init(&g_tx, g_tx_buf, PLAT_TX_RING);
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
            st_uirq = XIntc_Connect(&g_intc, RTLNET_CPU_IRQ_UART, (XInterruptHandler)plat_uart_isr, NULL);
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
            if (st_uirq == XST_SUCCESS && st_uart == XST_SUCCESS) {
                XIntc_Enable(&g_intc, RTLNET_CPU_IRQ_UART);
            }
            Xil_ExceptionEnable();
            g_tick_irq = 1;
            if (st_uirq == XST_SUCCESS && st_uart == XST_SUCCESS) {
                g_uart_irq = 1;
                XUartLite_EnableIntr(RTLNET_PLAT_UART_BASE);
            }
        }
    }

    g_led_bits = 0u;
    board_sys_write(NXV_SYS_LEDS, g_led_bits);
    g_heartbeat_next_ms = RTLNET_PLAT_HEARTBEAT_MS;
    if (st_uart != XST_SUCCESS || st_tmr != XST_SUCCESS || st_intc != XST_SUCCESS || st_uirq != XST_SUCCESS) {
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
    uint32_t s = plat_irq_save();
    plat_rx_pull();
    plat_irq_restore(s);
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
 * plat_poll -- periodic main-loop work: transmit safety refill, heartbeat LED.
 * Steps:
 *   0. Characters waiting with the UART FIFO empty (a lost interrupt): refill the FIFO.
 *   1. Every RTLNET_PLAT_HEARTBEAT_MS toggle led[1] in the LEDS register.
 * Returns: nothing.
 */
void plat_poll(void)
{
    uint32_t now = plat_uptime_ms();
    if (g_uart_irq && txring_count(&g_tx) != 0u && (XUartLite_GetStatusReg(RTLNET_PLAT_UART_BASE) & XUL_SR_TX_FIFO_EMPTY) != 0u) {
        /* characters wait and the FIFO is empty: the interrupt is late or was lost; refill from the main loop */
        uint32_t s = plat_irq_save();
        plat_tx_fill();
        plat_irq_restore(s);
        g_tx_refills++;
    }
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
    if (g_uart_irq) {
        /* let the transmit ring and the FIFO empty (bounded), then stop the UART interrupt */
        uint32_t t0 = plat_uptime_ms();
        while ((txring_count(&g_tx) != 0u || (XUartLite_GetStatusReg(RTLNET_PLAT_UART_BASE) & XUL_SR_TX_FIFO_EMPTY) == 0u) &&
               (plat_uptime_ms() - t0) < PLAT_RELOAD_TX_MS) {
            uint32_t s = plat_irq_save();
            if (!XUartLite_IsTransmitFull(RTLNET_PLAT_UART_BASE)) {
                plat_tx_fill();
            }
            plat_irq_restore(s);
        }
        XUartLite_DisableIntr(RTLNET_PLAT_UART_BASE);
    }
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

/*
 * plat_console_tx_stats -- counters of the interrupt-driven console transmit path.
 * Returns: nothing; *out holds the ring size, its high-water mark, the UART interrupts, the refills made by the main loop and the
 * characters lost to a wait that timed out.
 */
void plat_console_tx_stats(plat_console_tx_t *out)
{
    out->ring_bytes = PLAT_TX_RING;
    out->high_water = g_tx.high;
    out->irqs = g_tx_irqs;
    out->refills = g_tx_refills;
    out->drops = g_tx_drops;
    out->irq_mode = (uint32_t)g_uart_irq;
}
