/*
 * rtlnet_txring.c -- byte ring of the console transmit path
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_txring.h.
 *
 * Revision: 11-11-2026
 */
#include "rtlnet_txring.h"

#include <stddef.h>   /* NULL */

int txring_init(txring_t *r, uint8_t *buf, uint32_t size)
{
    if (buf == NULL || size < 2u || (size & (size - 1u)) != 0u) {
        return TXRING_ERR_ARG;
    }
    r->buf = buf;
    r->mask = size - 1u;
    r->head = 0u;
    r->tail = 0u;
    r->high = 0u;
    return TXRING_OK;
}

uint32_t txring_count(const txring_t *r)
{
    return r->head - r->tail;
}

int txring_put(txring_t *r, uint8_t c)
{
    uint32_t n = r->head - r->tail;
    if (n > r->mask) {
        return TXRING_ERR_FULL;
    }
    r->buf[r->head & r->mask] = c;
    r->head++;
    n++;
    if (n > r->high) {
        r->high = n;
    }
    return TXRING_OK;
}

int txring_get(txring_t *r)
{
    int c;
    if (r->head == r->tail) {
        return -1;
    }
    c = (int)r->buf[r->tail & r->mask];
    r->tail++;
    return c;
}
