/*
 * txring_host_test.c -- host test of the console transmit ring (src/rtlnet_txring.c)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: checks the ring that sits behind plat_putc: an empty ring, put and get in order, a full ring (put refused with
 * TXRING_ERR_FULL and the contents unchanged), drain to empty, wrap of the index counters around the buffer end many times and around
 * the 32-bit counter end, the high-water mark, a bad size or a null buffer refused, and a model of the interrupt-driven path: a producer
 * that puts text lines while a consumer takes up to 16 characters per "interrupt" (the UART FIFO), with the text read back identical and
 * a producer that waits on a full ring losing nothing. Run with --neg: a character is damaged inside the ring and the test passes only
 * when the comparison reports it (negative control). Prints one line "TXRING_TEST: PASS" or "TXRING_TEST: FAIL ..." and exits 0 on pass.
 *
 * Revision: 11-11-2026
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "rtlnet_txring.h"

#define RING 64u

static int g_fail;

static void fail(const char *what, uint32_t a, uint32_t b)
{
    if (g_fail < 12) {
        printf("  check failed: %s (%u, %u)\n", what, (unsigned)a, (unsigned)b);
    }
    g_fail++;
}

static uint8_t g_buf[RING];

int main(int argc, char **argv)
{
    int neg = (argc > 1 && strcmp(argv[1], "--neg") == 0);
    txring_t r;
    uint8_t other[RING];
    uint32_t i;
    uint32_t put = 0u;
    uint32_t got = 0u;
    static char text[20000];
    static char back[20000];
    uint32_t tlen = 0u;

    if (txring_init(&r, NULL, RING) != TXRING_ERR_ARG || txring_init(&r, g_buf, 0u) != TXRING_ERR_ARG ||
        txring_init(&r, g_buf, 1u) != TXRING_ERR_ARG || txring_init(&r, g_buf, 48u) != TXRING_ERR_ARG) {
        fail("bad arguments accepted", 0u, 0u);
    }
    if (txring_init(&r, g_buf, RING) != TXRING_OK || txring_count(&r) != 0u || txring_get(&r) != -1) {
        fail("empty ring", txring_count(&r), 0u);
    }
    /* put and get in order, full, drain */
    for (i = 0u; i < RING; i++) {
        if (txring_put(&r, (uint8_t)(i + 1u)) != TXRING_OK) {
            fail("put below full", i, 0u);
        }
    }
    if (txring_count(&r) != RING || txring_put(&r, 0xEEu) != TXRING_ERR_FULL || txring_count(&r) != RING || r.high != RING) {
        fail("full ring", txring_count(&r), r.high);
    }
    for (i = 0u; i < RING; i++) {
        int c = txring_get(&r);
        if (c != (int)(i + 1u)) {
            fail("drain order", (uint32_t)c, i + 1u);
        }
    }
    if (txring_count(&r) != 0u || txring_get(&r) != -1) {
        fail("drained ring", txring_count(&r), 0u);
    }
    /* wrap of the buffer many times, partly filled, and of the 32-bit counters */
    r.head = 0xFFFFFFF0u;
    r.tail = 0xFFFFFFF0u;
    for (i = 0u; i < 1000u; i++) {
        uint32_t n = 1u + (i % 37u);
        for (uint32_t k = 0u; k < n; k++) {
            if (txring_put(&r, (uint8_t)(put++)) != TXRING_OK) {
                fail("put in the wrap run", i, k);
            }
        }
        for (uint32_t k = 0u; k < n; k++) {
            int c = txring_get(&r);
            if (c != (int)(uint8_t)(got++)) {
                fail("wrap order", (uint32_t)c, got - 1u);
            }
        }
    }
    if (r.head >= 0xFFFFFFF0u) {
        fail("32-bit counters did not wrap", r.head, 0u);
    }
    /* model of the interrupt path: the producer puts lines, the consumer takes at most 16 characters per interrupt; a full ring makes
     * the producer wait (one interrupt), nothing is lost */
    txring_init(&r, g_buf, RING);
    for (i = 0u; i < 300u; i++) {
        char line[80];
        int n = snprintf(line, sizeof(line), "line %u: the quick brown fox jumps over the lazy dog %u\r\n", (unsigned)i, (unsigned)(i * 7u));
        for (int k = 0; k < n; k++) {
            while (txring_put(&r, (uint8_t)line[k]) != TXRING_OK) {
                for (int f = 0; f < 16; f++) {
                    int c = txring_get(&r);
                    if (c < 0) {
                        break;
                    }
                    back[got % sizeof(back)] = (char)c;
                    got++;
                }
            }
            text[tlen++ % sizeof(text)] = line[k];
            if (neg && tlen == 500u) {
                g_buf[r.tail & r.mask] ^= 0x20u;   /* damage a character inside the ring */
            }
        }
        if ((i % 3u) == 0u) {
            for (int f = 0; f < 16; f++) {
                int c = txring_get(&r);
                if (c < 0) {
                    break;
                }
                back[got % sizeof(back)] = (char)c;
                got++;
            }
        }
    }
    for (;;) {
        int c = txring_get(&r);
        if (c < 0) {
            break;
        }
        back[got % sizeof(back)] = (char)c;
        got++;
    }
    memset(other, 0, sizeof(other));
    {
        /* got continued from the wrap run: compare the text part only */
        uint32_t base = got - tlen;
        uint32_t bad = 0u;
        for (i = 0u; i < tlen; i++) {
            if (back[(base + i) % sizeof(back)] != text[i % sizeof(text)]) {
                bad++;
            }
        }
        if (bad != 0u) {
            fail("text through the ring differs", bad, tlen);
        }
        if (r.high != RING) {
            fail("high water below the ring size although the ring filled", r.high, RING);
        }
    }
    if (neg) {
        if (g_fail > 0) {
            printf("TXRING_TEST: PASS (negative control: the damaged character was reported, %d checks failed as required)\n", g_fail);
            return 0;
        }
        printf("TXRING_TEST: FAIL negative control: the damage was not detected\n");
        return 1;
    }
    if (g_fail != 0) {
        printf("TXRING_TEST: FAIL %d checks\n", g_fail);
        return 1;
    }
    printf("TXRING_TEST: PASS (order, full, drain, wrap of the buffer and of the 32-bit counters, %u characters of text through a %u-byte ring)\n",
           (unsigned)tlen, (unsigned)RING);
    return 0;
}
