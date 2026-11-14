/*
 * rtlnet_fbcrc.c -- CRC-32 of the latest published video frame
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_fbcrc.h.
 */
#include "rtlnet_fbcrc.h"

#include <stddef.h>   /* NULL */

#include "rtlnet_csi2_rx.h"
#include "rtlnet_ddrtest.h"
#include "rtlnet_mmio.h"
#include "rtlnet_platform.h"
#include "rtlnet_vdma_s2mm.h"

#define FBCRC_POLY        0xEDB88320u   /* IEEE 802.3, reflected */
#define FBCRC_INIT        0xFFFFFFFFu
#define FBCRC_TABLE_SIZE  256u
#define FBCRC_BYTE_BITS   8u
#define FBCRC_WORD_BYTES  4u
#define FBCRC_FWSLOT_MASK RTLNET_FB_STATUS_FIELD_MASK

static uint32_t g_crc_table[FBCRC_TABLE_SIZE];
static int      g_crc_ready;

/*
 * crc_table_init -- build the 256-entry table on first use (1 KiB of bss, no constants to keep in step)
 * Returns: nothing.
 */
static void crc_table_init(void)
{
    if (g_crc_ready) {
        return;
    }
    for (uint32_t i = 0u; i < FBCRC_TABLE_SIZE; i++) {
        uint32_t c = i;
        for (uint32_t b = 0u; b < FBCRC_BYTE_BITS; b++) {
            c = ((c & 1u) != 0u) ? ((c >> 1) ^ FBCRC_POLY) : (c >> 1);
        }
        g_crc_table[i] = c;
    }
    g_crc_ready = 1;
}

/* crc_word -- advance the CRC over one little-endian word (four bytes, lowest address first). */
static inline uint32_t crc_word(uint32_t crc, uint32_t w)
{
    crc ^= w;
    crc = g_crc_table[crc & 0xFFu] ^ (crc >> 8);
    crc = g_crc_table[crc & 0xFFu] ^ (crc >> 8);
    crc = g_crc_table[crc & 0xFFu] ^ (crc >> 8);
    crc = g_crc_table[crc & 0xFFu] ^ (crc >> 8);
    return crc;
}

/*
 * fbcrc_update_words -- CRC-32 update over nwords little-endian words in a buffer
 * Returns: the updated register value (not inverted).
 */
uint32_t fbcrc_update_words(uint32_t crc, const uint32_t *buf, uint32_t nwords)
{
    crc_table_init();
    for (uint32_t i = 0u; i < nwords; i++) {
        crc = crc_word(crc, buf[i]);
    }
    return crc;
}

/* mem_read -- one word of the DDR3 window as the cache presents it. */
static inline uint32_t mem_read(uintptr_t addr)
{
#ifdef RTLNET_HOST_TEST
    return rtlnet_host_mem_read32(addr);
#else
    return *(volatile const uint32_t *)addr;
#endif
}

/*
 * hash_frame -- CRC the lines of a held frame
 * Steps:
 *   1. For each line, invalidate its data-cache lines, then read it word by word.
 *   2. Advance the CRC over each word.
 * Returns: the final (inverted) CRC-32.
 */
static uint32_t hash_frame(uintptr_t first, uint32_t line_bytes, uint32_t stride, uint32_t height)
{
    uint32_t crc = FBCRC_INIT;
    uint32_t words = line_bytes / FBCRC_WORD_BYTES;

    crc_table_init();
    for (uint32_t y = 0u; y < height; y++) {
        uintptr_t line = first + ((uintptr_t)y * stride);
        plat_dcache_invalidate_range(line, line_bytes);
        for (uint32_t x = 0u; x < words; x++) {
            crc = crc_word(crc, mem_read(line + ((uintptr_t)x * FBCRC_WORD_BYTES)));
        }
    }
    return ~crc;
}

/*
 * geometry_ok -- check a frame of height lines of line_bytes at the given stride against the slot size
 * Returns: 1 when the geometry is usable, else 0.
 */
static int geometry_ok(uint32_t line_bytes, uint32_t stride, uint32_t height, uint32_t slot_bytes)
{
    uint32_t rows_before_last;

    if (height == 0u || line_bytes == 0u || (line_bytes % FBCRC_WORD_BYTES) != 0u || stride < line_bytes ||
        (stride % FBCRC_WORD_BYTES) != 0u || line_bytes > slot_bytes) {
        return 0;
    }
    rows_before_last = height - 1u;
    if (rows_before_last != 0u && stride > (slot_bytes - line_bytes) / rows_before_last) {
        return 0;
    }
    return 1;
}

/*
 * fbcrc_latest -- CRC-32 of the latest published frame
 * Steps:
 *   1. Probe the frame buffer and the write DMA; read the stride.
 *   2. Take the latest slot for the firmware.
 *   3. Check that the geometry fits the slot.
 *   4. Hash the frame; release the slot on every path after the take.
 * Returns: FBCRC_OK or a negative FBCRC_ERR_* code.
 */
int fbcrc_latest(uintptr_t fb_win, uintptr_t s2mm_win, uintptr_t ddr_base, fbcrc_result_t *r)
{
    rtlnet_framebuf_caps_t caps;
    rtlnet_framebuf_frame_t f;
    uint32_t stride;
    uint32_t line_bytes;
    uint32_t status;
    int rc;

    if (r == NULL || rtlnet_framebuf_probe(fb_win, &caps) != RTLNET_FB_OK ||
        rtlnet_vdma_s2mm_probe(s2mm_win, NULL) != RTLNET_S2MM_OK) {
        return FBCRC_ERR_CORE;
    }
    stride = rtlnet_reg_read32(s2mm_win, RTLNET_S2MM_REG_STRIDE);
    rc = rtlnet_framebuf_fw_take(fb_win, &f);
    if (rc == RTLNET_FB_ERR_NO_FRAME) {
        return FBCRC_ERR_NO_FRAME;
    }
    if (rc != RTLNET_FB_OK) {
        return (rc == RTLNET_FB_ERR_TIMEOUT) ? FBCRC_ERR_TIMEOUT : FBCRC_ERR_CORE;
    }
    status = rtlnet_reg_read32(fb_win, RTLNET_FB_REG_STATUS);
    line_bytes = f.width * RTLNET_CSI2_BYTES_PER_PIXEL;
    if (stride == 0u) {
        stride = line_bytes;
    }
    rc = FBCRC_OK;
    if (!geometry_ok(line_bytes, stride, f.height, caps.slot_bytes)) {
        rc = FBCRC_ERR_GEOMETRY;
    } else {
        r->crc   = hash_frame(ddr_base + f.base, line_bytes, stride, f.height);
        r->slot  = (status >> RTLNET_FB_STATUS_FWSLOT_SHIFT) & FBCRC_FWSLOT_MASK;
        r->bytes = line_bytes * f.height;
        r->frame = f;
    }
    (void)rtlnet_framebuf_fw_release(fb_win);
    return rc;
}
