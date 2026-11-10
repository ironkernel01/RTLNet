/*
 * rtlnet_vdma_s2mm.h -- RTLNet video write DMA driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one file pair (rtlnet_vdma_s2mm.h / .c) that touches the registers of the rtlnet_vdma_s2mm core. Every
 * register offset and bit of the core is defined here, once; hdl/rtlnet_vdma_s2mm_regs.sv mirrors them as localparams
 * with a pointer to this header. Change both in the same commit: a mismatch reads the wrong counter or writes the wrong
 * control bit.
 *
 * The base address (the core's 4 KiB window) is passed in by the platform layer. Register access goes only through
 * rtlnet_mmio.h.
 *
 * Behaviour. The core writes a video stream (32-bit words of two YUV422 pixels, start-of-frame and end-of-line flags)
 * as a 2D image into a frame-buffer slot of DDR3: at each frame start it asks rtlnet_framebuf for a slot, writes the
 * lines at base + line * stride in INCR bursts of at most 16 beats of 16 bytes that never cross a 4 KiB boundary, and
 * reports the frame done when every write response has arrived. STRIDE 0 packs the lines (stride = line bytes).
 * Frame width and height come with the stream. A frame with a bad line, a short frame or a write error is reported
 * to the frame buffer as not good and is never published.
 *
 * Revision: 11-09-2026
 */
#ifndef RTLNET_VDMA_S2MM_H
#define RTLNET_VDMA_S2MM_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#define RTLNET_S2MM_ID_VALUE            0x53324D4Du   /* "S2MM" */
#define RTLNET_S2MM_VERSION_VALUE       0x11092026u

/* Registers (ID, VERSION, CAPS at RTLNET_REG_* of rtlnet_mmio.h). */
#define RTLNET_S2MM_REG_CTRL            0x00Cu   /* RW, [0] ENABLE (reset 1), [16] CNT_CLEAR self-clearing (reads 0) */
#define RTLNET_S2MM_REG_STATUS          0x010u   /* RO flags, error flags write-1-to-clear */
#define RTLNET_S2MM_REG_STRIDE          0x014u   /* RW, bytes between line starts, 0 = packed; else a multiple of 16 */
#define RTLNET_S2MM_REG_FRAMES_OK       0x018u   /* RO, frames written and reported good */
#define RTLNET_S2MM_REG_FRAMES_BAD      0x01Cu   /* RO, frames reported not good (never published) */
#define RTLNET_S2MM_REG_FRAMES_DROPPED  0x020u   /* RO, frames not written: no slot, disabled or bad configuration */
#define RTLNET_S2MM_REG_BURSTS          0x024u   /* RO, write bursts issued */
#define RTLNET_S2MM_REG_BEATS           0x028u   /* RO, write data beats sent */
#define RTLNET_S2MM_REG_LAST_BASE       0x02Cu   /* RO, DDR3 byte offset of the slot written last */

/* CAPS fields. */
#define RTLNET_S2MM_CAPS_BURST_MASK     0x000000FFu   /* [7:0] maximum burst length in beats */
#define RTLNET_S2MM_CAPS_BYTES_SHIFT    8u            /* [15:8] bytes per beat */
#define RTLNET_S2MM_CAPS_BYTES_MASK     0xFFu
#define RTLNET_S2MM_CAPS_ADDR_SHIFT     16u           /* [23:16] DDR3 address width in bits */
#define RTLNET_S2MM_CAPS_ADDR_MASK      0xFFu

/* CTRL bits. */
#define RTLNET_S2MM_CTRL_ENABLE         (1u << 0)
#define RTLNET_S2MM_CTRL_CNT_CLEAR      (1u << 16)

/* STATUS bits. */
#define RTLNET_S2MM_STATUS_BUSY         (1u << 0)     /* a frame is being written */
#define RTLNET_S2MM_STATUS_CFG_ERR      (1u << 1)     /* sticky: a frame had a bad width, height or stride and was dropped */
#define RTLNET_S2MM_STATUS_AXI_ERR      (1u << 2)     /* sticky: a write response was not OKAY */
#define RTLNET_S2MM_STATUS_LINE_ERR     (1u << 3)     /* sticky: a misplaced line end or a short frame */
#define RTLNET_S2MM_STATUS_ERR_MASK     0x0000000Eu

#define RTLNET_S2MM_MAX_BURST_BEATS     16u
#define RTLNET_S2MM_BEAT_BYTES          16u

#define RTLNET_S2MM_OK                  0
#define RTLNET_S2MM_ERR_ARG             (-1)          /* bad argument, or the core is not present */

typedef struct {
    uint32_t max_burst_beats;
    uint32_t bytes_per_beat;
    uint32_t addr_bits;
} rtlnet_vdma_s2mm_caps_t;

typedef struct {
    uint32_t ctrl;
    uint32_t status;
    uint32_t stride;
    uint32_t frames_ok;
    uint32_t frames_bad;
    uint32_t frames_dropped;
    uint32_t bursts;
    uint32_t beats;
    uint32_t last_base;
} rtlnet_vdma_s2mm_state_t;

/* Return RTLNET_S2MM_OK, or RTLNET_S2MM_ERR_ARG. */
int rtlnet_vdma_s2mm_probe(uintptr_t base, rtlnet_vdma_s2mm_caps_t *caps);
int rtlnet_vdma_s2mm_read_state(uintptr_t base, rtlnet_vdma_s2mm_state_t *st);
int rtlnet_vdma_s2mm_enable(uintptr_t base, int on);
/* Stride in bytes, 0 = packed; a value that is not a multiple of 16 is rejected with ERR_ARG (nothing written). */
int rtlnet_vdma_s2mm_set_stride(uintptr_t base, uint32_t stride);
void rtlnet_vdma_s2mm_clear(uintptr_t base);          /* CTRL.CNT_CLEAR */
void rtlnet_vdma_s2mm_err_clear(uintptr_t base);      /* STATUS error flags */

#endif /* RTLNET_VDMA_S2MM_H */
