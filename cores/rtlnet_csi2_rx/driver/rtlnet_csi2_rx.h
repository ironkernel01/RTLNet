/*
 * rtlnet_csi2_rx.h -- RTLNet CSI-2 capture core driver (test pattern, source switch and the camera receiver)
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
 * Camera receiver (CAPS camera bit set, VERSION 0x11152026). The core receives the camera itself: two D-PHY data lanes and a clock lane
 * in, CSI-2 packets decoded (header ECC, CRC-16, virtual channel and data type filter, RAW10), Bayer to RGB and YUV422 out into the same
 * source switch. The functions below configure the receiver and read its status and counters. Configuration written to RX_CTRL, RX_TAPS,
 * RX_SETTLE, RX_FILTER should be written while the receiver is idle (before the sensor streams); the Bayer processing registers take
 * effect at the next frame start. The twelve event counters are saturating, read as 32-bit values and cleared by rtlnet_csi2_rx_clear_counters.
 * The frame geometry of the camera path is that of VIDEO_MODE (1280 x 720 or 1920 x 1080): every frame that starts is output at exactly that
 * size, a frame of another size is padded or cut and counted in RTLNET_CSI2_CNT_SIZE. Without the camera bit the functions return
 * RTLNET_CSI2_ERR_ARG. The receiver is proven in simulation only.
 *
 * Revision: 11-15-2026
 */
#ifndef RTLNET_CSI2_RX_H
#define RTLNET_CSI2_RX_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#define RTLNET_CSI2_ID_VALUE            0x43534932u   /* "CSI2" */
#define RTLNET_CSI2_VERSION_VALUE       0x11102026u   /* core without the camera receiver */
#define RTLNET_CSI2_VERSION_CAMERA      0x11152026u   /* core with the camera receiver (CAPS camera bit set) */

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

/* Camera receiver registers (read 0 and ignore writes when the camera bit of CAPS is 0). */
#define RTLNET_CSI2_REG_RX_CTRL         0x040u   /* RW, [0] enable (reset 1), [1] soft reset (reset 0), [3:2] lane enable (reset 3), [4] bit order */
#define RTLNET_CSI2_REG_RX_STATUS       0x044u   /* RO, see RTLNET_CSI2_RXST_* */
#define RTLNET_CSI2_REG_RX_TAPS         0x048u   /* RW, [4:0] input delay tap of lane 0, [12:8] of lane 1 (reset 0) */
#define RTLNET_CSI2_REG_RX_SETTLE       0x04Cu   /* RW, [7:0] HS settle time in 200 MHz clocks (reset 28 = 140 ns) */
#define RTLNET_CSI2_REG_RX_FILTER       0x050u   /* RW, [1:0] virtual channel (reset 0), [13:8] data type (reset 0x2B, RAW10) */
#define RTLNET_CSI2_REG_RX_CLEAR        0x054u   /* WO, bit n clears counter n, bit 31 all; reads 0 */
#define RTLNET_CSI2_REG_RX_LINES        0x058u   /* RO, lines of the last frame as received */
#define RTLNET_CSI2_REG_RX_PIXELS       0x05Cu   /* RO, pixels of the last line as received */
#define RTLNET_CSI2_REG_CNT_BASE        0x060u   /* RO, twelve 32-bit counters, 4 bytes apart (RTLNET_CSI2_CNT_*) */
#define RTLNET_CSI2_REG_BLACK           0x090u   /* RW, [9:0] black level in 10-bit raw units (reset 0) */
#define RTLNET_CSI2_REG_WB_R            0x094u   /* RW, [11:0] red gain, unsigned 4.8 fixed point (reset 0x100 = 1.0) */
#define RTLNET_CSI2_REG_WB_G            0x098u   /* RW, [11:0] green gain (reset 0x100) */
#define RTLNET_CSI2_REG_WB_B            0x09Cu   /* RW, [11:0] blue gain (reset 0x100) */
#define RTLNET_CSI2_REG_PHASE           0x0A0u   /* RW, [1:0] Bayer phase of the first pixel of the first line (reset 0) */
#define RTLNET_CSI2_REG_PROC            0x0A4u   /* RW, [0] gamma enable, [1] green equalisation (reset 0) */
#define RTLNET_CSI2_PROC_GAMMA          (1u << 0)
#define RTLNET_CSI2_PROC_GREEN_EQ       (1u << 1)     /* G at a G site = mean of G and the four diagonal G (equalises Gr and Gb) */

#define RTLNET_CSI2_CTRL_ENABLE         (1u << 0)
#define RTLNET_CSI2_CTRL_SOFT_RESET     (1u << 1)
#define RTLNET_CSI2_CTRL_LANE_SHIFT     2u            /* [3:2] lane enable: 3 two lanes, 1 lane 0 only */
#define RTLNET_CSI2_CTRL_BIT_REV        (1u << 4)     /* deserializer delivers the earliest bit in bit 7 */

#define RTLNET_CSI2_RXST_CLK_RUN        (1u << 0)     /* HS clock detected */
#define RTLNET_CSI2_RXST_HS_MASK        (3u << 1)     /* [2:1] lane in an HS burst (settle over) */
#define RTLNET_CSI2_RXST_LOCKED_MASK    (3u << 3)     /* [4:3] lane found its sync byte in the burst */
#define RTLNET_CSI2_RXST_DLYCTL_RDY     (1u << 5)     /* IDELAYCTRL ready */
#define RTLNET_CSI2_RXST_IN_FRAME       (1u << 6)     /* a frame start was seen and the frame end not yet */
#define RTLNET_CSI2_RXST_FMT_ERR        (1u << 7)     /* YUV conversion saw a malformed line (sticky until reset) */
#define RTLNET_CSI2_RXST_LP_D0_SHIFT    8u            /* [9:8] LP state {Dp, Dn} of lane 0: 3 = stop */
#define RTLNET_CSI2_RXST_LP_D1_SHIFT    10u           /* [11:10] of lane 1 */

/* Counter indexes. */
#define RTLNET_CSI2_CNT_ECC_CORR        0u            /* header errors corrected (packet used) */
#define RTLNET_CSI2_CNT_ECC_UNC         1u            /* header errors not correctable (packet dropped) */
#define RTLNET_CSI2_CNT_CRC             2u            /* payload CRC errors (the pixels are still used) */
#define RTLNET_CSI2_CNT_SOT             3u            /* bursts without a sync byte, or lane skew beyond three bytes */
#define RTLNET_CSI2_CNT_FRAMES          4u            /* frame starts received */
#define RTLNET_CSI2_CNT_DT              5u            /* packets of an unexpected data type (same virtual channel) */
#define RTLNET_CSI2_CNT_TRUNC           6u            /* packets that ended before their word count */
#define RTLNET_CSI2_CNT_OVF             7u            /* FIFO entries dropped (clk side did not keep up) */
#define RTLNET_CSI2_CNT_SIZE            8u            /* frames whose lines or line width differ from the mode */
#define RTLNET_CSI2_CNT_ORPHAN          9u            /* lines outside a frame (no frame start) */
#define RTLNET_CSI2_CNT_LEN             10u           /* word count zero or not a multiple of five */
#define RTLNET_CSI2_CNT_CLKLOSS         11u           /* HS clock stops (every burst with a non-continuous clock) */
#define RTLNET_CSI2_CNT_COUNT           12u
#define RTLNET_CSI2_CLEAR_ALL           0x80000000u

/* CAPS fields. */
#define RTLNET_CSI2_CAPS_MODES_MASK     0x0000000Fu   /* [3:0] number of video modes */
#define RTLNET_CSI2_CAPS_PATTERN        (1u << 4)     /* test-pattern generator present */
#define RTLNET_CSI2_CAPS_CAMERA         (1u << 5)     /* camera receiver present (CAMERA_RX build) */
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
    uint32_t ctrl;                              /* RX_CTRL */
    uint32_t status;                            /* RX_STATUS */
    uint32_t taps;                              /* RX_TAPS */
    uint32_t settle;                            /* RX_SETTLE */
    uint32_t filter;                            /* RX_FILTER */
    uint32_t lines;                             /* RX_LINES */
    uint32_t pixels;                            /* RX_PIXELS */
    uint32_t counters[RTLNET_CSI2_CNT_COUNT];   /* RTLNET_CSI2_CNT_* */
} rtlnet_csi2_rx_rxstate_t;

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
/* Camera receiver. Each returns RTLNET_CSI2_OK, or RTLNET_CSI2_ERR_ARG for a value that does not fit its field or when the core has no camera. */
int rtlnet_csi2_rx_rx_control(uintptr_t base, int enable, int soft_reset, uint32_t lane_en, int bit_rev);
int rtlnet_csi2_rx_set_taps(uintptr_t base, uint32_t tap0, uint32_t tap1);          /* each 0..31 */
int rtlnet_csi2_rx_set_settle(uintptr_t base, uint32_t clocks);                     /* 0..255 clocks of 200 MHz */
int rtlnet_csi2_rx_set_filter(uintptr_t base, uint32_t vc, uint32_t dt);            /* vc 0..3, dt 0..63 */
int rtlnet_csi2_rx_set_black(uintptr_t base, uint32_t black);                       /* 0..1023 */
int rtlnet_csi2_rx_set_wb(uintptr_t base, uint32_t gain_r, uint32_t gain_g, uint32_t gain_b);   /* each 0..0xFFF, 0x100 = 1.0 */
int rtlnet_csi2_rx_set_phase(uintptr_t base, uint32_t phase);                       /* 0 R, 1 Gr, 2 Gb, 3 B first pixel */
int rtlnet_csi2_rx_set_gamma(uintptr_t base, int enable);
int rtlnet_csi2_rx_set_green_eq(uintptr_t base, int enable);                        /* both keep the other PROC bit */
int rtlnet_csi2_rx_read_rxstate(uintptr_t base, rtlnet_csi2_rx_rxstate_t *st);
int rtlnet_csi2_rx_clear_counters(uintptr_t base, uint32_t mask);                   /* bit n counter n, RTLNET_CSI2_CLEAR_ALL for all */

/* Frame width and height in pixels of a mode; 0 for an unknown mode. */
uint32_t rtlnet_csi2_rx_mode_width(uint32_t mode);
uint32_t rtlnet_csi2_rx_mode_height(uint32_t mode);

#endif /* RTLNET_CSI2_RX_H */
