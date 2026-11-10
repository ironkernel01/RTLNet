/*
 * rtlnet_framebuf.h -- RTLNet tear-free frame buffer manager driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one file pair (rtlnet_framebuf.h / .c) that touches the registers of the rtlnet_framebuf core. Every register
 * offset and bit of the core is defined here, once; hdl/rtlnet_framebuf_regs.sv mirrors them as localparams with a pointer
 * to this header. Change both in the same commit: a mismatch reads the wrong slot or clears the wrong flag.
 *
 * The base address (the core's 4 KiB window) is passed in by the platform layer. Register access goes only through
 * rtlnet_mmio.h.
 *
 * Behaviour. N slots of SLOT_BYTES each sit in DDR3 from byte offset FB_BASE (a DDR3 offset: the CPU address is
 * RTLNET_PLAT_DDR_BASE + offset). The write DMA owns one slot while it writes a frame and publishes it as "latest" when
 * the frame is good; a reader takes "latest" with a reference count and releases it when done, and the writer never lands
 * on a slot a reader holds. The firmware is a reader too: FW_TAKE takes the latest published slot (STATUS.FW_HOLDS, the
 * FW_* registers describe it), FW_RELEASE returns it. A take with nothing published, a take while holding and a release
 * while not holding set the sticky STATUS.FW_ERR. The LATEST_* registers are a live view: they can change between two
 * reads, so a consumer takes the frame first and reads the FW_* registers.
 *
 * Revision: 11-09-2026
 */
#ifndef RTLNET_FRAMEBUF_H
#define RTLNET_FRAMEBUF_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#define RTLNET_FB_ID_VALUE              0x46425546u   /* "FBUF" */
#define RTLNET_FB_VERSION_VALUE         0x11092026u

/* Registers (ID, VERSION, CAPS at RTLNET_REG_* of rtlnet_mmio.h). */
#define RTLNET_FB_REG_CTRL              0x00Cu   /* WO command bits, reads 0 */
#define RTLNET_FB_REG_STATUS            0x010u   /* RO flags, FW_ERR write-1-to-clear */
#define RTLNET_FB_REG_FB_BASE           0x014u   /* RO, DDR3 byte offset of slot 0 */
#define RTLNET_FB_REG_SLOT_BYTES        0x018u   /* RO, bytes per slot */
#define RTLNET_FB_REG_LATEST_BASE       0x020u   /* RO, DDR3 byte offset of the latest published slot */
#define RTLNET_FB_REG_LATEST_FRAME      0x024u   /* RO, frame number of the latest published frame */
#define RTLNET_FB_REG_LATEST_TS         0x028u   /* RO, timestamp (ui_clk cycles) of the latest published frame */
#define RTLNET_FB_REG_LATEST_WH         0x02Cu   /* RO, [31:16] height, [15:0] width in pixels */
#define RTLNET_FB_REG_LATEST_SRC        0x030u   /* RO, [0] source flag: 1 pattern, 0 camera */
#define RTLNET_FB_REG_FW_BASE           0x040u   /* RO, as LATEST_*, for the frame the firmware holds */
#define RTLNET_FB_REG_FW_FRAME          0x044u
#define RTLNET_FB_REG_FW_TS             0x048u
#define RTLNET_FB_REG_FW_WH             0x04Cu
#define RTLNET_FB_REG_FW_SRC            0x050u
#define RTLNET_FB_REG_PUBLISHED         0x060u   /* RO, frames published */
#define RTLNET_FB_REG_DROPPED           0x064u   /* RO, frames dropped for want of a free slot */
#define RTLNET_FB_REG_BAD               0x068u   /* RO, frames reported not good (never published) */
#define RTLNET_FB_REG_FW_TAKES          0x06Cu   /* RO, successful firmware takes */
#define RTLNET_FB_REG_REFCNT            0x080u   /* RO, reference count of slot i at + 4 * i */
#define RTLNET_FB_MAX_SLOTS             8u

/* CAPS fields. */
#define RTLNET_FB_CAPS_SLOTS_MASK       0x0000000Fu   /* [3:0] N, slots */
#define RTLNET_FB_CAPS_READERS_SHIFT    4u            /* [7:4] reader ports */
#define RTLNET_FB_CAPS_READERS_MASK     0xFu
#define RTLNET_FB_CAPS_SLOTLOG2_SHIFT   8u            /* [15:8] log2 of SLOT_BYTES */
#define RTLNET_FB_CAPS_SLOTLOG2_MASK    0xFFu
#define RTLNET_FB_CAPS_ADDR_SHIFT       16u           /* [23:16] DDR3 address width in bits */
#define RTLNET_FB_CAPS_ADDR_MASK        0xFFu

/* CTRL bits. */
#define RTLNET_FB_CTRL_FW_TAKE          (1u << 0)     /* take the latest published slot for the firmware */
#define RTLNET_FB_CTRL_FW_RELEASE       (1u << 1)     /* release the slot the firmware holds */
#define RTLNET_FB_CTRL_CNT_CLEAR        (1u << 16)    /* clears the counters (not the slot state) */

/* STATUS bits and fields. */
#define RTLNET_FB_STATUS_LATEST_VALID   (1u << 0)     /* a frame is published */
#define RTLNET_FB_STATUS_FW_HOLDS       (1u << 1)     /* the firmware holds a slot */
#define RTLNET_FB_STATUS_WRITING        (1u << 2)     /* the write DMA owns a slot */
#define RTLNET_FB_STATUS_FW_ERR         (1u << 3)     /* sticky, write 1 to clear */
#define RTLNET_FB_STATUS_LATEST_SHIFT   8u            /* [15:8] latest slot index */
#define RTLNET_FB_STATUS_FWSLOT_SHIFT   16u           /* [23:16] slot the firmware holds */
#define RTLNET_FB_STATUS_WRSLOT_SHIFT   24u           /* [31:24] slot the write DMA owns (last owned when idle) */
#define RTLNET_FB_STATUS_FIELD_MASK     0xFFu

#define RTLNET_FB_OK                    0
#define RTLNET_FB_ERR_ARG               (-1)          /* bad argument, or the core is not present */
#define RTLNET_FB_ERR_NO_FRAME          (-2)          /* nothing published, or the firmware already holds a slot */
#define RTLNET_FB_ERR_TIMEOUT           (-3)          /* the take did not complete within the poll bound */

typedef struct {
    uint32_t slots;
    uint32_t readers;
    uint32_t slot_bytes;
    uint32_t addr_bits;
} rtlnet_framebuf_caps_t;

typedef struct {
    uint32_t base;       /* DDR3 byte offset of the slot */
    uint32_t frame;      /* frame number */
    uint32_t timestamp;  /* ui_clk cycles */
    uint32_t width;      /* pixels */
    uint32_t height;     /* lines */
    uint32_t pattern;    /* 1 pattern, 0 camera */
} rtlnet_framebuf_frame_t;

typedef struct {
    uint32_t status;
    uint32_t fb_base;
    uint32_t slot_bytes;
    uint32_t published;
    uint32_t dropped;
    uint32_t bad;
    uint32_t fw_takes;
    uint32_t refcnt[RTLNET_FB_MAX_SLOTS];
    rtlnet_framebuf_frame_t latest;
} rtlnet_framebuf_state_t;

/* Return RTLNET_FB_OK, or a negative RTLNET_FB_ERR_* code. */
int rtlnet_framebuf_probe(uintptr_t base, rtlnet_framebuf_caps_t *caps);
int rtlnet_framebuf_read_state(uintptr_t base, rtlnet_framebuf_state_t *st);
/* Take the latest published slot for the firmware and describe it. ERR_NO_FRAME when nothing is published or the firmware
 * already holds a slot (the flag is cleared); ERR_TIMEOUT when STATUS.FW_HOLDS does not rise within a bounded poll. */
int rtlnet_framebuf_fw_take(uintptr_t base, rtlnet_framebuf_frame_t *frame);
/* Release the slot the firmware holds; ERR_NO_FRAME when it holds none. */
int rtlnet_framebuf_fw_release(uintptr_t base);
void rtlnet_framebuf_clear(uintptr_t base);           /* CTRL.CNT_CLEAR */

#endif /* RTLNET_FRAMEBUF_H */
