/*
 * uart_lite.h -- polled AXI UART Lite console driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches the AXI UART Lite registers (console at
 * RTLNET_PLAT_UART_BASE, 115200 8N1 fixed in the block design). Polled, no
 * interrupts. Line ends: uart_lite_write() sends "\r\n" for every "\n".
 *
 * Register map (AXI UART Lite product guide): RX FIFO 0x0, TX FIFO 0x4,
 * STATUS 0x8, CONTROL 0xC; 16-entry FIFOs.
 *
 * Receive buffering: while the driver waits for TX FIFO space it moves
 * received characters from the 16-entry RX FIFO into a UART_LITE_RX_RING
 * byte ring, so input typed (or pasted) during a long response is kept;
 * uart_lite_getc_nb() reads the ring first. Characters arriving with the
 * ring full stay in the hardware FIFO (and are lost once it overflows).
 *
 * This header holds signatures and constants; uart_lite.c holds the
 * per-function commentary.
 */
#ifndef UART_LITE_H
#define UART_LITE_H

#include <stddef.h>   /* size_t */
#include <stdint.h>   /* uintptr_t */

#define UART_LITE_RX_FIFO        0x00u
#define UART_LITE_TX_FIFO        0x04u
#define UART_LITE_STATUS         0x08u
#define UART_LITE_CONTROL        0x0Cu

#define UART_LITE_SR_RX_VALID    0x01u
#define UART_LITE_SR_TX_FULL     0x08u
#define UART_LITE_CR_RST_TX      0x01u
#define UART_LITE_CR_RST_RX      0x02u

/* Bound on the wait for TX FIFO space: 16 characters at 115200 baud take
 * 1.4 ms; at roughly 10 status reads per microsecond 200000 reads is about
 * 20 ms, far above the drain time. A timeout drops the character. */
#define UART_LITE_TX_WAIT_MAX    200000u

/* Software receive ring, power of two. */
#define UART_LITE_RX_RING        256u

void uart_lite_init(uintptr_t base);
int  uart_lite_putc(char c);
void uart_lite_write(const char *s, size_t n);
int  uart_lite_getc_nb(void);

#endif /* UART_LITE_H */
