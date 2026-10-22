/*
 * rtlnet_string.c -- memory and string primitives for the freestanding target
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the firmware links no C library (-nostdlib), but GCC emits calls to
 * memcpy, memset, memmove and memcmp for structure copies and array
 * initialization even in freestanding mode (GCC manual, "Standards": a
 * freestanding environment must provide these four). This file provides
 * them, plus strlen. Target build only; the host harness uses its C library.
 */
#include <stddef.h>   /* size_t */

void  *memcpy(void *dst, const void *src, size_t n);
void  *memmove(void *dst, const void *src, size_t n);
void  *memset(void *dst, int c, size_t n);
int    memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);

/*
 * memcpy -- copy n bytes, regions must not overlap.
 * Returns: dst.
 */
void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n-- > 0u) {
        *d++ = *s++;
    }
    return dst;
}

/*
 * memmove -- copy n bytes, regions may overlap.
 * Returns: dst.
 */
void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        while (n-- > 0u) {
            *d++ = *s++;
        }
    } else {
        while (n-- > 0u) {
            d[n] = s[n];
        }
    }
    return dst;
}

/*
 * memset -- fill n bytes with (unsigned char)c.
 * Returns: dst.
 */
void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    while (n-- > 0u) {
        *d++ = (unsigned char)c;
    }
    return dst;
}

/*
 * memcmp -- compare n bytes.
 * Returns: <0, 0, >0 as the first differing byte of a is below, equal to,
 *          above that of b.
 */
int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *p = (const unsigned char *)a;
    const unsigned char *q = (const unsigned char *)b;
    for (size_t i = 0; i < n; i++) {
        if (p[i] != q[i]) {
            return (int)p[i] - (int)q[i];
        }
    }
    return 0;
}

/*
 * strlen -- length of a NUL-terminated string.
 * Returns: characters before the NUL.
 */
size_t strlen(const char *s)
{
    size_t n = 0;
    while (s[n] != '\0') {
        n++;
    }
    return n;
}
