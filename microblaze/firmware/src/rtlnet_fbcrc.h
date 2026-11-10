/*
 * rtlnet_fbcrc.h -- CRC-32 of the latest published video frame
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the check behind the CLI command "framebuffer crc". It takes the latest published slot of rtlnet_framebuf for
 * the firmware, invalidates the data-cache lines of the frame (the write DMA wrote the frame behind the cache), reads
 * the frame through the cache and computes the standard CRC-32 (IEEE 802.3, reflected, initial value and final XOR
 * 0xFFFFFFFF, the value of zlib crc32) over the height lines of width * 2 bytes. A line starts at
 * base + line * stride, where stride is the S2MM STRIDE register, or the line bytes when that register is 0 (packed).
 * The bytes are in memory order: Y0 Cb Y1 Cr per pixel pair, the order the C bar model hashes.
 *
 * The slot is released on every path, so a failed check never leaves the write DMA short of a slot.
 *
 * Builds for the target (volatile reads of the DDR3 window) and for the host harness (RTLNET_HOST_TEST: reads go to
 * rtlnet_host_mem_read32 of the memory model).
 *
 * This header holds the types and the function contract; the .c file holds the per-function commentary.
 *
 * Revision: 11-09-2026
 */
#ifndef RTLNET_FBCRC_H
#define RTLNET_FBCRC_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#include "rtlnet_framebuf.h"

#define FBCRC_OK            0
#define FBCRC_ERR_CORE      (-1)   /* the frame buffer or the write DMA is not present */
#define FBCRC_ERR_NO_FRAME  (-2)   /* nothing published yet, or the firmware already holds a slot */
#define FBCRC_ERR_TIMEOUT   (-3)   /* the take did not complete */
#define FBCRC_ERR_GEOMETRY  (-4)   /* the frame geometry or the stride does not fit the slot */

typedef struct {
    uint32_t                crc;     /* CRC-32 of the frame bytes */
    uint32_t                slot;    /* slot index the frame was in */
    uint32_t                bytes;   /* bytes hashed (width * 2 * height) */
    rtlnet_framebuf_frame_t frame;   /* metadata of the frame as taken */
} fbcrc_result_t;

/* Compute the CRC-32 of the latest published frame. fb_win and s2mm_win are the register windows of rtlnet_framebuf and
 * rtlnet_vdma_s2mm, ddr_base the CPU address of DDR3 offset 0. Returns FBCRC_OK or a negative FBCRC_ERR_* code; r is
 * valid only on FBCRC_OK. */
int fbcrc_latest(uintptr_t fb_win, uintptr_t s2mm_win, uintptr_t ddr_base, fbcrc_result_t *r);

/* CRC-32 register update over nwords little-endian words (table-driven); the register starts at 0xFFFFFFFF and the
 * caller inverts it at the end. Exposed for the host test of the engine. */
uint32_t fbcrc_update_words(uint32_t crc, const uint32_t *buf, uint32_t nwords);

#endif /* RTLNET_FBCRC_H */
