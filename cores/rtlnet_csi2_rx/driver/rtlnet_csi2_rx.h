/*
 * rtlnet_csi2_rx.h -- RTLNet CSI-2 capture core driver (Phase 1: test pattern and source switch)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one file pair (rtlnet_csi2_rx.h / .c) that touches the registers of the rtlnet_csi2_rx core. Every
 * register offset and bit of the core is defined here, once; hdl/rtlnet_csi2_rx_regs.sv mirrors them as localparams
 * with a pointer to this header. Change both in the same commit: a mismatch writes the wrong register or reads the
 * wrong flag.
 *
 * The base address (the core's 4 KiB window) is passed in by the platform layer. Register access goes only through
 * rtlnet_mmio.h.
 *
 * Behaviour. The core sends one YUV422 video stream (32-bit words of two pixels, Y0 Cb Y1 Cr, start-of-frame and
 * end-of-line flags) to rtlnet_vdma_s2mm. In this phase the stream comes from the 75 percent color-bar generator; the
 * camera front end (Phase 3) joins through the same source switch. VIDEO_MODE selects 720p30 or 1080p30; FRAME_PERIOD
 * is the ui_clk cycle count per frame (3,000,000 at the 90 MHz ui_clk is 30.000 fps). A rejected write leaves the
 * register unchanged and sets the matching sticky STATUS flag; the driver clears the flag and returns
 * RTLNET_CSI2_ERR_REJECTED.
 *
 * Test patterns. PATTERN selects the picture (static bars, scrolling bars, a moving box, a noise band, all three) and the speed
 * in pixels per frame of the scroll and the box (-32 to +32); a write takes effect at the next frame start and restarts the
 * pattern frame counter (PATTERN_FRAME) at 0, as does a VIDEO_MODE change. The pattern reset default is static bars, speed 4.
 *
 * Revision: 11-10-2026
 */
#ifndef RTLNET_CSI2_RX_H
#define RTLNET_CSI2_RX_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#define RTLNET_CSI2_ID_VALUE            0x43534932u   /* "CSI2" */
#define RTLNET_CSI2_VERSION_VALUE       0x11102026u

/* Registers (ID, VERSION, CAPS at RTLNET_REG_* of rtlnet_mmio.h). */
#define RTLNET_CSI2_REG_VIDEO_MODE      0x010u   /* RW, [1:0] mode, other values rejected (STATUS.MODE_ERR) */
#define RTLNET_CSI2_REG_SOURCE          0x014u   /* RW, [1:0] source, 3 rejected (STATUS.SOURCE_ERR) */
#define RTLNET_CSI2_REG_FRAME_PERIOD    0x018u   /* RW, ui_clk cycles per frame, below the mode minimum rejected */
#define RTLNET_CSI2_REG_CAM_TIMEOUT     0x01Cu   /* RW, frame periods without a camera frame before auto uses the pattern */
#define RTLNET_CSI2_REG_STATUS          0x020u   /* RO flags, error flags write-1-to-clear */
#define RTLNET_CSI2_REG_FRAME_COUNT     0x024u   /* RO, frames sent (both sources) */
#define RTLNET_CSI2_REG_ACTIVE          0x028u   /* RO, [1:0] mode of the frame in progress or the last frame */
#define RTLNET_CSI2_REG_PATTERN         0x030u   /* RW, [2:0] pattern 0..4, [15:8] signed speed -32..+32, else rejected (STATUS.PATTERN_ERR) */
#define RTLNET_CSI2_REG_PATTERN_FRAME   0x034u   /* RO, pattern frames started since the last PATTERN write or VIDEO_MODE change */

/* CAPS fields. */
#define RTLNET_CSI2_CAPS_MODES_MASK     0x0000000Fu   /* [3:0] number of video modes */
#define RTLNET_CSI2_CAPS_PATTERN        (1u << 4)     /* test-pattern generator present */
#define RTLNET_CSI2_CAPS_CAMERA         (1u << 5)     /* camera front end present (0 in Phase 1) */
#define RTLNET_CSI2_CAPS_MOVING         (1u << 6)     /* moving patterns (PATTERN register) present */

/* VIDEO_MODE values. */
#define RTLNET_CSI2_MODE_720P30         0u
#define RTLNET_CSI2_MODE_1080P30        1u
#define RTLNET_CSI2_MODE_COUNT          2u

/* SOURCE values. */
#define RTLNET_CSI2_SRC_AUTO            0u
#define RTLNET_CSI2_SRC_CAMERA          1u
#define RTLNET_CSI2_SRC_PATTERN         2u

/* PATTERN values (REG_PATTERN [2:0]). */
#define RTLNET_CSI2_PATTERN_BARS        0u            /* static bars (reset default) */
#define RTLNET_CSI2_PATTERN_SCROLL      1u            /* bars scrolling right */
#define RTLNET_CSI2_PATTERN_BOX         2u            /* 64 x 64 textured box moving over the static bars */
#define RTLNET_CSI2_PATTERN_NOISE       3u            /* static bars with a 64-row noise band */
#define RTLNET_CSI2_PATTERN_ALL         4u            /* scrolling bars, noise band and box */
#define RTLNET_CSI2_PATTERN_COUNT       5u
#define RTLNET_CSI2_SPEED_MAX           32            /* speed in pixels per frame, -32 .. +32 */
#define RTLNET_CSI2_SPEED_RESET         4
#define RTLNET_CSI2_PATTERN_SPEED_SHIFT 8u            /* REG_PATTERN [15:8] */

/* STATUS bits. */
#define RTLNET_CSI2_STATUS_PATTERN      (1u << 0)     /* active source: 0 camera, 1 pattern */
#define RTLNET_CSI2_STATUS_CLK_RUN      (1u << 1)     /* camera byte clock running */
#define RTLNET_CSI2_STATUS_MODE_ERR     (1u << 2)     /* sticky, write 1 to clear */
#define RTLNET_CSI2_STATUS_PERIOD_ERR   (1u << 3)     /* sticky, write 1 to clear */
#define RTLNET_CSI2_STATUS_SOURCE_ERR   (1u << 4)     /* sticky, write 1 to clear */
#define RTLNET_CSI2_STATUS_OVERRUN      (1u << 5)     /* sticky, write 1 to clear: a frame tick found the previous frame still running */
#define RTLNET_CSI2_STATUS_PATTERN_ERR  (1u << 6)     /* sticky, write 1 to clear */
#define RTLNET_CSI2_STATUS_ERR_MASK     0x0000007Cu

/* Frame geometry and timing, matched by the RTL localparams. */
#define RTLNET_CSI2_UI_CLK_HZ           90000000u
#define RTLNET_CSI2_PERIOD_RESET        3000000u      /* 30.000 fps */
#define RTLNET_CSI2_PERIOD_MIN_720P30   3000000u      /* 750 lines * 4000 cycles */
#define RTLNET_CSI2_PERIOD_MIN_1080P30  2999250u      /* 1125 lines * 2666 cycles */
#define RTLNET_CSI2_WIDTH_720P30        1280u
#define RTLNET_CSI2_HEIGHT_720P30       720u
#define RTLNET_CSI2_WIDTH_1080P30       1920u
#define RTLNET_CSI2_HEIGHT_1080P30      1080u
#define RTLNET_CSI2_BYTES_PER_PIXEL     2u            /* YUV422, byte order Y0 Cb Y1 Cr in memory */
#define RTLNET_CSI2_CAM_TIMEOUT_RESET   2u
#define RTLNET_CSI2_FPS_MAX             30u

#define RTLNET_CSI2_OK                  0
#define RTLNET_CSI2_ERR_ARG             (-1)          /* bad argument, or the core is not present */
#define RTLNET_CSI2_ERR_REJECTED        (-2)          /* the core rejected the value (flag cleared) */

typedef struct {
    uint32_t modes;         /* number of video modes */
    int      pattern;       /* test-pattern generator present */
    int      camera;        /* camera front end present */
    int      moving;        /* moving patterns present */
} rtlnet_csi2_rx_caps_t;

typedef struct {
    uint32_t video_mode;
    uint32_t source;
    uint32_t frame_period;
    uint32_t cam_timeout;
    uint32_t status;
    uint32_t frame_count;
    uint32_t active_mode;
    uint32_t pattern;         /* PATTERN [2:0] */
    int32_t  pattern_speed;   /* PATTERN [15:8], signed pixels per frame */
    uint32_t pattern_frame;   /* PATTERN_FRAME: frames started since the last restart */
} rtlnet_csi2_rx_state_t;

/* Return RTLNET_CSI2_OK, or a negative RTLNET_CSI2_ERR_* code. */
int rtlnet_csi2_rx_probe(uintptr_t base, rtlnet_csi2_rx_caps_t *caps);
int rtlnet_csi2_rx_read_state(uintptr_t base, rtlnet_csi2_rx_state_t *st);
int rtlnet_csi2_rx_set_mode(uintptr_t base, uint32_t mode);
int rtlnet_csi2_rx_set_source(uintptr_t base, uint32_t source);
int rtlnet_csi2_rx_set_frame_period(uintptr_t base, uint32_t period);
/* Pattern RTLNET_CSI2_PATTERN_* and speed (pixels per frame) for the next frame; the pattern frame counter restarts at 0. Values
 * the core does not accept (pattern above 4, speed beyond +-32) are written and rejected by the core: ERR_REJECTED, register
 * unchanged. ERR_ARG only when the value cannot be encoded in the register fields (pattern above 255, speed outside -128..127). */
int rtlnet_csi2_rx_set_pattern(uintptr_t base, uint32_t pattern, int32_t speed);
/* Frame period for fps frames per second (RTLNET_CSI2_UI_CLK_HZ / fps); fps 1..RTLNET_CSI2_FPS_MAX, else ERR_ARG. */
int rtlnet_csi2_rx_set_rate_fps(uintptr_t base, uint32_t fps);
/* Frame width and height in pixels of a mode; 0 for an unknown mode. */
uint32_t rtlnet_csi2_rx_mode_width(uint32_t mode);
uint32_t rtlnet_csi2_rx_mode_height(uint32_t mode);

#endif /* RTLNET_CSI2_RX_H */
