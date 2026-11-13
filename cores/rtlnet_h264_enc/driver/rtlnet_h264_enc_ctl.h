/*
 * rtlnet_h264_enc_ctl.h -- RTLNet H.264 encoder control: session, notification mode, picture turnaround
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the layer of the driver that firmware calls. It sits on rtlnet_h264_enc.c (the register driver) and owns everything that touches the
 * core's registers on behalf of an application: probing, the video mode and the stream parameters, the High profile controls, the picture start
 * sequence, the ring and index read pointers, and the completion of a picture. A picture completes through one of two notification modes that
 * produce the same result:
 *   RTLNET_H264_NOTIFY_INTERRUPT  the core's irq output (IRQ_STATUS / IRQ_ENABLE, CTRL.IRQ_EN) calls rtlnet_h264_ctl_irq_service() from the
 *                                 interrupt handler the platform connected. The service reads and acknowledges IRQ_STATUS, counts the events
 *                                 per source and, on picture done, collects the result and calls the registered callback.
 *   RTLNET_H264_NOTIFY_POLLED     the core's interrupts stay disabled; the application calls rtlnet_h264_ctl_poll(), which reads STATUS and,
 *                                 on DONE or ERR, collects the same result and calls the same callback.
 * The code above the driver is therefore the same in both modes. A core without the interrupt registers (an older VERSION) runs the polled mode
 * only: asking for the interrupt mode keeps the polled one, without an error (rtlnet_h264_ctl_set_notify returns the mode in force).
 *
 * The driver reaches memory (index records and the access unit delimiter in DDR3) only through the read_mem callback of the application, which
 * invalidates the cache lines; it has no dependency on lwIP, the multiplexer or the console, and no code here prints.
 *
 * Calling contexts (interrupt mode; "main" is the main loop, "irq" the handler):
 *   rtlnet_h264_ctl_irq_service   irq only. Bounded: one IRQ_STATUS read and one acknowledge, and on picture done the
 *                                 STATUS clear, one index write pointer read per engine, the index records between two pictures
 *                                 read through read_mem, and the callbacks (the firmware's: slot release, queue, rate control and
 *                                 the start of the next picture, about 47 register accesses in all on the host model, 9 without it).
 *   rtlnet_h264_ctl_poll          main only, polled mode only.
 *   rtlnet_h264_ctl_start_picture, rtlnet_h264_ctl_set_mode
 *                                 the one context that owns the idle encoder: the handler on picture done, or main while no picture is in flight.
 *   everything else               main. rtlnet_h264_ctl_release, rtlnet_h264_ctl_irq_stats and rtlnet_h264_ctl_take_events are safe against a
 *                                 running handler (single-writer counters, no read-modify-write of shared state).
 * The driver masks no interrupts itself; the callbacks run in the context that called the service or poll function.
 *
 * Revision: 11-12-2026
 *   * 11-12-2026: initial version (interrupt mode; the control code moved here from firmware rtlnet_venc.c).
 *   * 11-12-2026: deblocking filter controls (rtlnet_h264_ctl_set_deblock, _set_deblock_offsets, _deblock_wanted, _deblock_in_force, _deblock_info).
 */
#ifndef RTLNET_H264_ENC_CTL_H
#define RTLNET_H264_ENC_CTL_H

#include <stddef.h>   /* size_t */
#include <stdint.h>   /* uint8_t, uint32_t, uintptr_t */

#define RTLNET_H264_CTL_MAX_ENGINES   4u
#define RTLNET_H264_CTL_PS_BYTES      64u   /* a buffer this size holds the SPS and PPS (RTLNET_H264_SPS_PPS_MAX_BYTES) */
#define RTLNET_H264_CTL_AUD_BYTES     6u    /* start code, NAL header and payload of the access unit delimiter */

/* Notification modes. */
#define RTLNET_H264_NOTIFY_POLLED     0u
#define RTLNET_H264_NOTIFY_INTERRUPT  1u

/* Video modes (rtlnet_h264_enc.h RTLNET_H264_MODE_*). */
#define RTLNET_H264_CTL_MODE_720P30   0u
#define RTLNET_H264_CTL_MODE_1080P30  1u
#define RTLNET_H264_CTL_MODE_NONE     0xFFFFFFFFu

/* Picture types (RTLNET_H264_PIC_*). */
#define RTLNET_H264_CTL_PIC_IDR       0u
#define RTLNET_H264_CTL_PIC_P         1u

/* Transform of inter macroblocks (RTLNET_H264_T8_*). */
#define RTLNET_H264_CTL_T8_OFF        0
#define RTLNET_H264_CTL_T8_ON         1
#define RTLNET_H264_CTL_T8_AUTO       2

/* Lowest QP the driver writes (RTLNET_H264_QP_MIN_REALTIME). */
#define RTLNET_H264_CTL_QP_MIN_REALTIME 12u

/* Interrupt event sources, as counted by rtlnet_h264_ctl_irq_stats (index) and reported by rtlnet_h264_ctl_take_events (mask 1 << index). */
#define RTLNET_H264_CTL_SRC_PIC_DONE      0u
#define RTLNET_H264_CTL_SRC_ERR           1u
#define RTLNET_H264_CTL_SRC_RING_STALL    2u
#define RTLNET_H264_CTL_SRC_PROFILE_CHG   3u
#define RTLNET_H264_CTL_SRC_LICENSE_LOST  4u
#define RTLNET_H264_CTL_SRC_PIC_START     5u
#define RTLNET_H264_CTL_SRC_COUNT         6u

/* High profile (HIGH_PROFILE builds) results of the profile functions; the same values as the register driver's RTLNET_H264_HP_ERR_*. */
#define RTLNET_H264_CTL_HP_ERR_NO_SEAM    (-2)
#define RTLNET_H264_CTL_HP_ERR_NO_CAPS    (-3)
#define RTLNET_H264_CTL_HP_ERR_NOT_LICENSED (-4)
#define RTLNET_H264_CTL_HP_ERR_NO_MODULE  (-5)
#define RTLNET_H264_CTL_HP_ERR_NO_T8      (-6)
#define RTLNET_H264_CTL_HP_ERR_NO_AUTO    (-7)

/* Deblocking filter results (RTLNET_H264_DBK_ERR_*) and the offset range. */
#define RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT (-8)   /* the build has no deblocking filter (CAPS bit 22 is 0) */
#define RTLNET_H264_CTL_DBK_ERR_RANGE     (-9)     /* an offset outside -6..+6 */
#define RTLNET_H264_CTL_DBK_OFFSET_MIN    (-6)
#define RTLNET_H264_CTL_DBK_OFFSET_MAX    6

/* hp_caps bits of the High profile module. */
#define RTLNET_H264_CTL_HP_CAP_CABAC          (1u << 0)
#define RTLNET_H264_CTL_HP_CAP_TRANSFORM8X8   (1u << 1)
#define RTLNET_H264_CTL_HP_CAP_ADAPTIVE       (1u << 2)
#define RTLNET_H264_CTL_HP_SECONDS_UNLIMITED  0xFFFFu

/* Memory layout of the stream, chosen by the application: byte offsets in DDR3. */
typedef struct {
    uint32_t ring_base;          /* compressed ring, split by the core into one equal share per engine */
    uint32_t ring_size;
    uint32_t idx_base;           /* index rings, 128-byte records, split per engine */
    uint32_t idx_entries;
    uint32_t ry_base[2];         /* rebuilt picture A and B: luma tile bases */
    uint32_t ru_base[2];         /* rebuilt picture A and B: chroma tile bases */
    uint32_t log2_max_frame_num;
} rtlnet_h264_ctl_layout_t;

/* Result of opening the core. */
typedef struct {
    uint32_t engines;
    uint32_t max_mb_w;
    uint32_t max_mb_h;
    uint32_t hp_seam;
    uint32_t version;
    uint32_t irq_capable;        /* 1 when the core has the interrupt registers */
    uint32_t irq_sources;        /* implemented source mask (bit n = source n) */
} rtlnet_h264_ctl_info_t;

/* Geometry of a video mode. */
typedef struct {
    uint32_t mb_w, mb_h;
    uint32_t width, height;                  /* coded size */
    uint32_t display_width, display_height;  /* after SPS cropping */
} rtlnet_h264_ctl_mode_t;

/* A completed picture, as the callback receives it. */
typedef struct {
    uint32_t valid;                                     /* 1 when every engine's picture entry was found and the delimiter is right */
    uint32_t engines;
    uint32_t off[RTLNET_H264_CTL_MAX_ENGINES];          /* ring offset of the engine's slices (inside the engine's share) */
    uint32_t len[RTLNET_H264_CTL_MAX_ENGINES];          /* bytes of the engine's slices (engine 0 includes the delimiter) */
    uint32_t ring_end[RTLNET_H264_CTL_MAX_ENGINES];     /* ring read pointer once the picture is consumed */
    uint32_t idx_end[RTLNET_H264_CTL_MAX_ENGINES];      /* index read pointer once the picture is consumed */
    uint32_t size_bytes;                                /* sum of len */
    uint32_t qp;                                        /* QP register value the picture was started with */
    uint32_t pic_type;                                  /* type requested at the start; forced_idr overrides it */
    uint32_t forced_idr;                                /* the encoder coded an IDR picture instead (license or profile change) */
    uint8_t  aud[RTLNET_H264_CTL_AUD_BYTES];            /* the access unit delimiter bytes */
} rtlnet_h264_ctl_picture_t;

/* Application callbacks. picture_done and picture_error run in the context of the service or poll call (a handler in interrupt mode): short
 * and bounded, no blocking. read_mem copies n bytes of DDR3 at byte offset ddr_off into dst with the cache lines invalidated first, 0 on success. */
typedef struct {
    void (*picture_done)(void *ctx, const rtlnet_h264_ctl_picture_t *pic);
    void (*picture_error)(void *ctx, uint32_t err_code);
    int  (*read_mem)(void *ctx, uint32_t ddr_off, uint8_t *dst, uint32_t n);
    void  *ctx;
} rtlnet_h264_ctl_ops_t;

/* Parameters of one picture start. */
typedef struct {
    uint32_t in_base;            /* input frame, DDR3 byte offset */
    uint32_t in_stride;
    uint32_t qp;                 /* 0..51; values below RTLNET_H264_CTL_QP_MIN_REALTIME are raised to it */
    uint32_t pic_type;           /* RTLNET_H264_CTL_PIC_IDR or _P */
    uint32_t frame_num;          /* for a P picture; an IDR picture has 0 */
    uint32_t idr_pic_id;
} rtlnet_h264_ctl_start_t;

/* Counters of the interrupt path. Every counter has one writer (the handler), so a read in the main loop is safe; a snapshot of several fields
 * is not atomic. */
typedef struct {
    uint32_t irqs;                                      /* service calls that found an event */
    uint32_t spurious;                                  /* service calls with no enabled event pending */
    uint32_t source[RTLNET_H264_CTL_SRC_COUNT];         /* events per source */
    uint32_t pictures;                                  /* pictures completed (either mode) */
    uint32_t errors;                                    /* errors reported (either mode) */
    uint32_t notify;                                    /* mode in force */
    uint32_t irq_capable;
} rtlnet_h264_ctl_irq_stats_t;

/* High profile status. */
typedef struct {
    uint32_t present, licensed, active, enabled, t8_enabled, t8_auto, profile_chg, caps, seconds_left;
} rtlnet_h264_ctl_hp_t;

/* Deblocking filter state. Offsets are signed slice-header values (div2 units), -6..+6. */
typedef struct {
    uint32_t present;            /* the filter logic is built */
    uint32_t enable;             /* the filter is requested for the next picture (DBK_CTRL) */
    uint32_t applied;            /* the last started picture was coded with the filter */
    int32_t  alpha_applied, beta_applied;   /* offsets of the last started picture */
    int32_t  alpha_req, beta_req;           /* offsets requested for the next picture */
} rtlnet_h264_ctl_dbk_t;

/* Per-engine statistics of the last picture. */
typedef struct {
    uint32_t mb_count, cyc_last, cyc_max, pic_cyc, rd_cyc, pk_cyc, wr_cyc;
} rtlnet_h264_ctl_stats_t;

/* Core state for the console (show encoder). */
typedef struct {
    uint32_t version;
    uint32_t engines, max_mb_w, max_mb_h, hp_seam;
    uint32_t busy, done, err, ring_stall;
    uint32_t err_code, pic_count, slice_count;
    uint32_t irq_capable;
    uint32_t irq_status, irq_enable, irq_global;
    rtlnet_h264_ctl_stats_t eng[RTLNET_H264_CTL_MAX_ENGINES];
} rtlnet_h264_ctl_debug_t;

/*
 * Setup. rtlnet_h264_ctl_init stores the base address, the layout and the callbacks and clears the session; it touches no register (it may run
 * before the DDR3 calibration). rtlnet_h264_ctl_open probes the core: 0 and *info on success, -1 when the core is absent or unusable. It then
 * applies the notification mode: interrupt mode acknowledges stale events, enables the sources and the global enable; polled mode disables them.
 * rtlnet_h264_ctl_close disables the core's interrupts (the core stays configured).
 */
void rtlnet_h264_ctl_init(uintptr_t base, const rtlnet_h264_ctl_layout_t *layout, const rtlnet_h264_ctl_ops_t *ops);
int  rtlnet_h264_ctl_open(rtlnet_h264_ctl_info_t *info);
void rtlnet_h264_ctl_close(void);

/* Select the notification mode (RTLNET_H264_NOTIFY_*); effective at once when the core is open, otherwise at open. Returns the mode in force: the
 * interrupt mode degrades to polled on a core without the interrupt registers. Call it only while no picture is in flight. */
uint32_t rtlnet_h264_ctl_set_notify(uint32_t mode);
uint32_t rtlnet_h264_ctl_notify(void);        /* mode in force */
uint32_t rtlnet_h264_ctl_notify_wanted(void); /* mode requested */
int      rtlnet_h264_ctl_irq_capable(void);   /* 1 when the core opened has the interrupt registers */

/* Interrupt handler body (interrupt mode): read and acknowledge IRQ_STATUS, count, and dispatch: a picture error calls picture_error, a picture
 * done calls picture_done with the result; ring stall, profile change and license lost are counted for the main loop. Does nothing when the
 * interrupt mode is not in force. */
void rtlnet_h264_ctl_irq_service(void);

/* Polled mode: read STATUS and on DONE or ERR do what the service does. Returns 1 when a picture completed or failed, 0 when nothing is due, -1
 * when the interrupt mode is in force (the handler owns completion). */
int rtlnet_h264_ctl_poll(void);

/* Read the interrupt counters. */
void rtlnet_h264_ctl_irq_stats(rtlnet_h264_ctl_irq_stats_t *out);
/* Clear them (main context; the handler is the only other writer, so clear while no picture is in flight). */
void rtlnet_h264_ctl_irq_stats_clear(void);

/* Sources (mask of 1 << RTLNET_H264_CTL_SRC_*) whose count rose since the previous call, for the main loop: ring stall, profile change, license lost. */
uint32_t rtlnet_h264_ctl_take_events(void);

/* Self-test of the interrupt path: set the event bits of mask (RTLNET_H264_CTL_SRC bits, 1 << src) in IRQ_STATUS. 0, or -1 without the registers. */
int rtlnet_h264_ctl_irq_force(uint32_t mask);

/* Video mode of a frame size (RTLNET_H264_CTL_MODE_NONE when unsupported) and the geometry of a mode (0, or -1). */
uint32_t rtlnet_h264_ctl_mode_of(uint32_t width, uint32_t height);
int      rtlnet_h264_ctl_mode_info(uint32_t mode, rtlnet_h264_ctl_mode_t *out);

/* Program the core for a video mode: frame size, the transform request, the stream parameters for the profile in force, the memory layout; the
 * rings are reset. -1 on failure. Needed before the first picture and at a mode change; the encoder must be idle and the rings consumed. */
int rtlnet_h264_ctl_set_mode(uint32_t mode, uint32_t qp);

/* The stream parameters (SPS and PPS, Annex B) of the mode set and the profile in force at the last set_mode or forced IDR picture. */
void rtlnet_h264_ctl_params(const uint8_t **bytes, uint32_t *len);

/* Start one picture: write the per-picture registers and the buffer bases (the two rebuilt buffers alternate; a P picture reads the other one),
 * clear the profile-change note, and start. 0, -1 when the registers were refused (nothing started), -2 when the start was refused. *qp_used
 * receives the QP written (it is not NULL). */
int rtlnet_h264_ctl_start_picture(const rtlnet_h264_ctl_start_t *s, uint32_t *qp_used);

/* frame_num of the picture after one with frame_num prev (modulo 2^log2_max_frame_num of the layout; clause 7.4.3 with every picture a reference). */
uint32_t rtlnet_h264_ctl_next_frame_num(uint32_t prev);

/* The firmware has consumed the picture's bytes of engine e: report the ring and index read pointers, freeing the space. */
void rtlnet_h264_ctl_release(uint32_t engine, uint32_t ring_end, uint32_t idx_end);

/* Forget the rebuilt-buffer history (the next P picture has no reference until a picture completes): after a stream restart or a failed picture. */
void rtlnet_h264_ctl_reset_session(void);
int  rtlnet_h264_ctl_has_reference(void);

/* High profile controls (all of them refuse by named error codes, see RTLNET_H264_CTL_HP_ERR_*). set_profile: high != 0 selects High, 0
 * Constrained Baseline. set_transform8x8: RTLNET_H264_CTL_T8_OFF / _ON / _AUTO; the request is remembered (wanted) and re-applied at every
 * set_mode (the default is OFF, the 4x4 transform), where auto degrades to on on a module without the adaptive choice. profile_in_force and transform8x8_in_force describe
 * what the next picture uses. */
int  rtlnet_h264_ctl_set_profile(int high);
int  rtlnet_h264_ctl_hp_info(rtlnet_h264_ctl_hp_t *out);
int  rtlnet_h264_ctl_set_transform8x8(int mode);
int  rtlnet_h264_ctl_transform8x8_wanted(void);
int  rtlnet_h264_ctl_transform8x8_in_force(void);
int  rtlnet_h264_ctl_profile_in_force(void);
int  rtlnet_h264_ctl_transform8x8_counts(uint32_t *n8, uint32_t *n4);

/* Deblocking filter (CAPS bit 22; the in-loop filter of the core, on by default, no parameter-set change). set_deblock: on != 0 enables, 0
 * disables; on is refused with RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT when the build has no filter, off is always accepted. set_deblock_offsets:
 * alpha and beta (slice_alpha_c0_offset_div2, slice_beta_offset_div2), each -6..+6, else RTLNET_H264_CTL_DBK_ERR_RANGE (checked first) or
 * _NOT_PRESENT; nothing is written on an error. Both requests are remembered (deblock_wanted: 1 for on, the default) and re-applied at every
 * set_mode; the core takes the register state at each picture start, so a change is effective at the next picture and needs no IDR picture.
 * deblock_info: 0 and the state, or RTLNET_H264_CTL_DBK_ERR_NOT_PRESENT (the structure is zeroed), -1 for a NULL pointer. deblock_in_force: 1
 * when the filter is present and enabled, i.e. the next picture is filtered. */
int  rtlnet_h264_ctl_set_deblock(int on);
int  rtlnet_h264_ctl_set_deblock_offsets(int alpha_div2, int beta_div2);
int  rtlnet_h264_ctl_deblock_wanted(void);
int  rtlnet_h264_ctl_deblock_in_force(void);
int  rtlnet_h264_ctl_deblock_info(rtlnet_h264_ctl_dbk_t *out);

/* Console view of the core (works without open): version, status, counters, statistics. -1 when the core does not answer. */
int rtlnet_h264_ctl_debug(rtlnet_h264_ctl_debug_t *out);

#endif /* RTLNET_H264_ENC_CTL_H */
