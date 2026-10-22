/*
 * rtlnet_fmt.c -- small printf-style formatter (no C library)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * The formatter writes through a sink (buffer or console chunk); see
 * rtlnet_fmt.h for the supported conversions.
 */
#include "rtlnet_fmt.h"

#include <stdint.h>   /* uint32_t, uintptr_t */

#include "rtlnet_platform.h"

#define FMT_CHUNK 128u     /* console output is flushed in pieces of this size */

typedef struct {
    char  *buf;            /* buffer sink: destination, or NULL for the console */
    size_t cap;            /* buffer sink: capacity including the NUL */
    size_t len;            /* characters produced (also those not stored) */
    char   chunk[FMT_CHUNK];
    size_t chunk_len;
} fmt_sink_t;

/*
 * sink_put -- emit one character to the sink.
 * Steps:
 *   1. Buffer sink: store while room for the NUL remains.
 *   2. Console sink: collect in the chunk, flush it when full.
 * Returns: nothing; len counts every character.
 */
static void sink_put(fmt_sink_t *k, char c)
{
    if (k->buf != NULL) {
        if (k->len + 1u < k->cap) {
            k->buf[k->len] = c;
        }
    } else {
        k->chunk[k->chunk_len++] = c;
        if (k->chunk_len == FMT_CHUNK) {
            plat_console_write(k->chunk, k->chunk_len);
            k->chunk_len = 0;
        }
    }
    k->len++;
}

/*
 * sink_pad -- emit n copies of a character.
 * Returns: nothing.
 */
static void sink_pad(fmt_sink_t *k, char c, int n)
{
    while (n-- > 0) {
        sink_put(k, c);
    }
}

/*
 * put_field -- emit a converted field with width and alignment.
 * Steps:
 *   1. Left-aligned: text then spaces. Right-aligned with '0': the sign
 *      first, then zeros, then digits. Otherwise spaces then text.
 * Returns: nothing.
 */
static void put_field(fmt_sink_t *k, const char *text, int len, int width, int left, int zero, int neg)
{
    int total = len + (neg ? 1 : 0);
    int padn  = (width > total) ? (width - total) : 0;
    if (left) {
        if (neg) {
            sink_put(k, '-');
        }
        for (int i = 0; i < len; i++) {
            sink_put(k, text[i]);
        }
        sink_pad(k, ' ', padn);
        return;
    }
    if (zero) {
        if (neg) {
            sink_put(k, '-');
        }
        sink_pad(k, '0', padn);
    } else {
        sink_pad(k, ' ', padn);
        if (neg) {
            sink_put(k, '-');
        }
    }
    for (int i = 0; i < len; i++) {
        sink_put(k, text[i]);
    }
}

/*
 * utoa_rev -- digits of v in base (10 or 16), most significant first.
 * Returns: number of digits written to out (at least 1).
 */
static int utoa_digits(uint32_t v, unsigned base, int upper, char *out)
{
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char tmp[12];
    int  n = 0;
    do {
        tmp[n++] = dig[v % base];
        v /= base;
    } while (v != 0u);
    for (int i = 0; i < n; i++) {
        out[i] = tmp[n - 1 - i];
    }
    return n;
}

/*
 * fmt_core -- the formatter shared by every entry point.
 * Steps:
 *   1. Copy plain characters; on '%' parse flags, width, length.
 *   2. Convert the argument and emit it with put_field.
 * Returns: number of characters produced.
 */
static int fmt_core(fmt_sink_t *k, const char *fmt, va_list ap)
{
    char num[16];
    while (*fmt != '\0') {
        int left = 0;
        int zero = 0;
        int width = 0;
        char c = *fmt++;
        if (c != '%') {
            sink_put(k, c);
            continue;
        }
        for (;;) {
            if (*fmt == '-') {
                left = 1;
                fmt++;
            } else if (*fmt == '0') {
                zero = 1;
                fmt++;
            } else {
                break;
            }
        }
        if (*fmt == '*') {
            width = va_arg(ap, int);
            if (width < 0) {
                left  = 1;
                width = -width;
            }
            fmt++;
        } else {
            while (*fmt >= '0' && *fmt <= '9') {
                width = width * 10 + (*fmt - '0');
                fmt++;
            }
        }
        while (*fmt == 'l') {
            fmt++;
        }
        c = *fmt++;
        switch (c) {
        case 'd':
        case 'i': {
            int v = va_arg(ap, int);
            uint32_t m = (v < 0) ? (uint32_t)(-(int64_t)v) : (uint32_t)v;
            int n = utoa_digits(m, 10u, 0, num);
            put_field(k, num, n, width, left, zero, v < 0);
            break;
        }
        case 'u': {
            int n = utoa_digits(va_arg(ap, unsigned int), 10u, 0, num);
            put_field(k, num, n, width, left, zero, 0);
            break;
        }
        case 'x':
        case 'X': {
            int n = utoa_digits(va_arg(ap, unsigned int), 16u, c == 'X', num);
            put_field(k, num, n, width, left, zero, 0);
            break;
        }
        case 'p': {
            int n = utoa_digits((uint32_t)(uintptr_t)va_arg(ap, void *), 16u, 0, num);
            sink_put(k, '0');
            sink_put(k, 'x');
            put_field(k, num, n, width, left, zero, 0);
            break;
        }
        case 'c':
            num[0] = (char)va_arg(ap, int);
            put_field(k, num, 1, width, left, 0, 0);
            break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            int n = 0;
            if (s == NULL) {
                s = "(null)";
            }
            while (s[n] != '\0') {
                n++;
            }
            put_field(k, s, n, width, left, 0, 0);
            break;
        }
        case '%':
            sink_put(k, '%');
            break;
        case '\0':
            return (int)k->len;
        default:
            sink_put(k, '%');
            sink_put(k, c);
            break;
        }
    }
    return (int)k->len;
}

/*
 * fmt_vsnprintf -- format into a buffer, always NUL-terminated (cap > 0).
 * Returns: length the full output would have.
 */
int fmt_vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap)
{
    fmt_sink_t k;
    int n;
    k.buf = buf;
    k.cap = cap;
    k.len = 0;
    k.chunk_len = 0;
    n = fmt_core(&k, fmt, ap);
    if (cap > 0u) {
        buf[(k.len < cap) ? k.len : (cap - 1u)] = '\0';
    }
    return n;
}

/*
 * fmt_snprintf -- format into a buffer.
 * Returns: length the full output would have.
 */
int fmt_snprintf(char *buf, size_t cap, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = fmt_vsnprintf(buf, cap, fmt, ap);
    va_end(ap);
    return n;
}

/*
 * fmt_printf -- format to the console.
 * Steps:
 *   1. Format through a console sink; flush the last partial chunk.
 * Returns: number of characters written.
 */
int fmt_printf(const char *fmt, ...)
{
    fmt_sink_t k;
    va_list ap;
    int n;
    k.buf = NULL;
    k.cap = 0;
    k.len = 0;
    k.chunk_len = 0;
    va_start(ap, fmt);
    n = fmt_core(&k, fmt, ap);
    va_end(ap);
    if (k.chunk_len > 0u) {
        plat_console_write(k.chunk, k.chunk_len);
    }
    return n;
}

/*
 * fmt_puts -- write a string to the console unchanged (no newline added).
 * Returns: nothing.
 */
void fmt_puts(const char *s)
{
    size_t n = 0;
    while (s[n] != '\0') {
        n++;
    }
    plat_console_write(s, n);
}
