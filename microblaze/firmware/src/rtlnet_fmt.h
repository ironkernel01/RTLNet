/*
 * rtlnet_fmt.h -- small printf-style formatter (no C library)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: formatted text for the console and for buffers, without newlib.
 * Conversions: %d %i %u %x %X %c %s %p %%, flags '-' and '0', a field width
 * (digits or '*'), and the length modifier 'l' (accepted, values are 32-bit).
 * fmt_printf() sends its output to plat_console_write().
 *
 * This header holds signatures; rtlnet_fmt.c holds the commentary.
 */
#ifndef RTLNET_FMT_H
#define RTLNET_FMT_H

#include <stdarg.h>   /* va_list */
#include <stddef.h>   /* size_t */

int fmt_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int fmt_snprintf(char *buf, size_t cap, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
int fmt_vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap);
void fmt_puts(const char *s);

#endif /* RTLNET_FMT_H */
