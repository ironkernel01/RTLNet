/*
 * rtlnet_txring.h -- byte ring of the console transmit path
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the logic of the software transmit ring behind plat_putc: the main loop puts characters in, the UART transmit-empty interrupt
 * (and the main loop, with interrupts masked) takes them out into the 16-character UART FIFO. The ring is a power-of-two byte array with
 * free-running head and tail counters; it holds no hardware access and no locking: rtlnet_platform.c keeps the two sides apart by masking
 * interrupts around every put and every take that the main loop makes, as the receive ring does. The host test
 * cpu/microblaze_v_h264/firmware/test/txring_host_test.c runs wrap, full and drain.
 *
 * Revision: 11-11-2026
 */
#ifndef RTLNET_TXRING_H
#define RTLNET_TXRING_H

#include <stdint.h>   /* uint8_t, uint32_t */

#define TXRING_OK         0
#define TXRING_ERR_FULL   (-1)   /* put into a full ring */
#define TXRING_ERR_ARG    (-2)   /* size not a power of two, or a null buffer */

typedef struct {
    uint8_t           *buf;
    uint32_t           mask;      /* size - 1 */
    volatile uint32_t  head;      /* characters put since init (free running) */
    volatile uint32_t  tail;      /* characters taken since init (free running) */
    uint32_t           high;      /* most characters held at once */
} txring_t;

/* Use buf of size bytes (a power of two, at least 2). TXRING_OK or TXRING_ERR_ARG. */
int txring_init(txring_t *r, uint8_t *buf, uint32_t size);

/* Characters held. */
uint32_t txring_count(const txring_t *r);

/* Append one character. TXRING_OK, or TXRING_ERR_FULL when size characters are held. */
int txring_put(txring_t *r, uint8_t c);

/* Remove the oldest character: 0..255, or -1 when empty. */
int txring_get(txring_t *r);

#endif /* RTLNET_TXRING_H */
