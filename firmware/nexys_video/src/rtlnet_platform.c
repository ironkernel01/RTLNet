/*
 * rtlnet_platform.c -- MicroBlaze implementation of the platform services
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: console (UART Lite), time (AXI Timer), the LED shadow with the
 * heartbeat on led[1], soft restart, and the interrupt entry the vector
 * table points at. See rtlnet_platform.h for the contract.
 *
 * Context rules: everything here runs in the main loop. Interrupts stay
 * disabled (MSR[IE] = 0 from reset); rtlnet_isr exists so the 0x10 vector
 * has a defined target and counts any interrupt that a later firmware
 * enables before it installs a real handler.
 */
#include "rtlnet_platform.h"

#include "rtlnet_board.h"
#include "timer.h"
#include "uart_lite.h"

#define PLAT_UART_DRAIN_MS  20u   /* 16-character FIFO at 115200 baud drains in 1.4 ms */

static uint32_t g_led_bits;          /* LEDS register shadow, bits [7:1] */
static uint32_t g_heartbeat_next_ms;
static volatile uint32_t g_isr_count; /* written by rtlnet_isr, read by nobody yet */

void rtlnet_isr(void) __attribute__((interrupt_handler));

/*
 * rtlnet_isr -- interrupt vector target (0x10).
 * Steps:
 *   1. Count the event; interrupts are not enabled by this firmware.
 * Returns: via rtid (interrupt_handler attribute).
 */
void rtlnet_isr(void)
{
    g_isr_count++;
}

/*
 * plat_init -- bring up console and time base, clear the LEDs.
 * Steps:
 *   1. UART Lite FIFOs reset; timer 0 free running at cpu_clk.
 *   2. LEDS register cleared (led[0] stays hardware-owned).
 * Returns: nothing.
 */
void plat_init(void)
{
    uart_lite_init(RTLNET_PLAT_UART_BASE);
    timer_init(RTLNET_PLAT_TIMER_BASE, RTLNET_PLAT_CPU_CLK_HZ);
    g_led_bits = 0u;
    board_sys_write(NXV_SYS_LEDS, g_led_bits);
    g_heartbeat_next_ms = RTLNET_PLAT_HEARTBEAT_MS;
    g_isr_count = 0u;
}

/*
 * plat_console_write -- send console text ("\n" becomes "\r\n").
 * Returns: nothing.
 */
void plat_console_write(const char *s, size_t n)
{
    uart_lite_write(s, n);
}

/*
 * plat_console_getc -- non-blocking console read.
 * Returns: character 0..255, or -1 when none is waiting.
 */
int plat_console_getc(void)
{
    return uart_lite_getc_nb();
}

/*
 * plat_uptime_ms -- milliseconds since plat_init.
 * Returns: elapsed time from the AXI Timer.
 */
uint32_t plat_uptime_ms(void)
{
    return timer_uptime_ms();
}

/*
 * plat_ticks -- free-running 32-bit cpu_clk tick counter.
 * Returns: AXI Timer 0 count.
 */
uint32_t plat_ticks(void)
{
    return timer_ticks();
}

/*
 * plat_delay_us -- busy-wait.
 * Returns: nothing.
 */
void plat_delay_us(uint32_t us)
{
    timer_delay_us(us);
}

/*
 * plat_delay_ms -- busy-wait.
 * Returns: nothing.
 */
void plat_delay_ms(uint32_t ms)
{
    timer_delay_ms(ms);
}

/*
 * plat_poll -- periodic main-loop work: heartbeat LED.
 * Steps:
 *   1. Every RTLNET_PLAT_HEARTBEAT_MS toggle led[1] in the LEDS register.
 * Returns: nothing.
 */
void plat_poll(void)
{
    uint32_t now = timer_uptime_ms();
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
 * plat_reload -- soft restart: let the console drain, then jump to the
 * reset vector (crt0 re-copies .data and clears .bss).
 * Returns: never.
 */
void plat_reload(void)
{
    timer_delay_ms(PLAT_UART_DRAIN_MS);
    __asm__ volatile ("brai 0x0" ::: "memory");
    for (;;) {
    }
}
