/*
 * uart_lite.c -- polled AXI UART Lite console driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Owns the AXI UART Lite registers; see uart_lite.h for the contract.
 */
#include "uart_lite.h"

#include "rtlnet_mmio.h"

static uintptr_t g_uart_base;
static uint8_t   g_rx_ring[UART_LITE_RX_RING];
static uint32_t  g_rx_head;   /* next write index (free-running) */
static uint32_t  g_rx_tail;   /* next read index (free-running) */

/*
 * uart_lite_rx_drain -- move received characters into the software ring.
 * Steps:
 *   1. While the RX FIFO holds data and the ring has room, copy one byte.
 *      Bounded by the 16-entry hardware FIFO depth plus arrivals during the
 *      loop (each read takes far less than one 87 us character time).
 * Returns: nothing.
 */
static void uart_lite_rx_drain(void)
{
    while ((g_rx_head - g_rx_tail) < UART_LITE_RX_RING &&
           (rtlnet_reg_read32(g_uart_base, UART_LITE_STATUS) & UART_LITE_SR_RX_VALID) != 0u) {
        g_rx_ring[g_rx_head % UART_LITE_RX_RING] =
            (uint8_t)(rtlnet_reg_read32(g_uart_base, UART_LITE_RX_FIFO) & 0xFFu);
        g_rx_head++;
    }
}

/*
 * uart_lite_init -- select the UART and flush both FIFOs.
 * Steps:
 *   1. Remember the base address.
 *   2. Reset the TX and RX FIFOs (interrupts stay disabled).
 * Returns: nothing.
 */
void uart_lite_init(uintptr_t base)
{
    g_uart_base = base;
    g_rx_head   = 0u;
    g_rx_tail   = 0u;
    rtlnet_reg_write32(g_uart_base, UART_LITE_CONTROL, UART_LITE_CR_RST_TX | UART_LITE_CR_RST_RX);
}

/*
 * uart_lite_putc -- send one character, waiting for FIFO space.
 * Steps:
 *   1. Poll STATUS until TX FIFO not full, at most UART_LITE_TX_WAIT_MAX reads,
 *      draining received characters into the ring meanwhile.
 *   2. Write the character to the TX FIFO.
 * Returns: 0 sent, -1 timeout (character dropped).
 */
int uart_lite_putc(char c)
{
    uint32_t n;
    for (n = 0; n < UART_LITE_TX_WAIT_MAX; n++) {
        uart_lite_rx_drain();
        if ((rtlnet_reg_read32(g_uart_base, UART_LITE_STATUS) & UART_LITE_SR_TX_FULL) == 0u) {
            rtlnet_reg_write32(g_uart_base, UART_LITE_TX_FIFO, (uint32_t)(unsigned char)c);
            return 0;
        }
    }
    return -1;
}

/*
 * uart_lite_write -- send n characters, "\n" as "\r\n".
 * Steps:
 *   1. For each character: a "\n" is preceded by "\r"; send it.
 * Returns: nothing (characters that time out are dropped).
 */
void uart_lite_write(const char *s, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++) {
        if (s[i] == '\n') {
            (void)uart_lite_putc('\r');
        }
        (void)uart_lite_putc(s[i]);
    }
}

/*
 * uart_lite_getc_nb -- non-blocking read of one received character.
 * Steps:
 *   1. Drain the RX FIFO into the ring.
 *   2. Return the oldest ring entry, if any.
 * Returns: the character (0..255), or -1 when nothing was received.
 */
int uart_lite_getc_nb(void)
{
    uart_lite_rx_drain();
    if (g_rx_head == g_rx_tail) {
        return -1;
    }
    return (int)g_rx_ring[g_rx_tail++ % UART_LITE_RX_RING];
}
