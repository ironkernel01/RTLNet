/*
 * rtlnet_venc.h -- H.264 encoder session and MPEG-TS stream over UDP
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the firmware half of the Phase 2b-3 video path. It runs from the main loop (venc_poll) while a stream is
 * started with "stream h264 <ip> <port>":
 *   1. a new frame is published in rtlnet_framebuf: take the slot (firmware reader), configure the two-engine encoder from the
 *      frame size (mode 720p30 or 1080p30, one I picture, one slice per engine, fixed QP) and start the picture;
 *   2. on DONE release the slot, read each engine's picture entry from its index ring, and build the access unit: the access
 *      unit delimiter of engine 0, the SPS and PPS, engine 0's slices, engine 1's slices;
 *   3. hand the access unit to the TS multiplexer (rtlnet_tsmux.c), which sends 1316-byte datagrams through lwIP UDP
 *      (rtlnet_video_udp.c); then advance the ring and index read pointers.
 * The 90 kHz time base: the PTS (and DTS) of picture n is pts_base + (frame_n - frame_first) x step, where frame_n is the
 * frame number stamped by the capture path and step = round(FRAME_PERIOD x 90000 / cpu_clk_hz) the 90 kHz ticks of one frame period
 * of rtlnet_csi2_rx (3000 at 30 fps). The count comes from ui_clk through the frame numbers, so a dropped frame shows as a
 * PTS gap of two steps. The PCR is the PTS minus 9000 ticks (100 ms of receiver buffering).
 *
 * Phase 2c: IDR every GOP pictures (default 30), P pictures between. The rebuilt picture ping-pongs between two buffers; a P
 * picture's reference is the previous picture's buffer. The next picture is an IDR picture after a dropped picture, a mode change,
 * an encoder error, a timeout or a mux failure, so a P picture never references a picture that was not coded. A QP change does not
 * force an IDR picture: the slice QP of an H.264 P picture is free, so rate control (Phase 2d) changes it at every picture.
 *
 * Phase 2d: rate control (rtlnet_ratectl.c). Target 0 is constant QP (the QP of venc_set_qp for every picture); a target in kb/s
 * picks the QP of each picture from the coded sizes of the pictures before it (the entry lengths of every engine's index record).
 *
 * Phase 2f: the multiplexer runs apart from the encoder. On DONE the picture is queued (rtlnet_picq.c: a descriptor with everything the multiplexer
 * needs), the slot is released and the next picture starts at once; every venc_poll call sends one chunk of the oldest queued picture
 * (rtlnet_muxjob.c). Pictures leave in coding order. At PICQ_LIMIT pictures queued a new frame is skipped on purpose (a dropped picture with its
 * own counter, the next picture an IDR picture), so the encoder cannot stall on a full ring. See rtlnet_ts_mux.md section 5.2.
 *
 * DDR3 map (byte offsets in DDR3, CPU address = DDR3 window + offset; the frame buffer holds 0x1000_0000 to 0x10C0_0000):
 *   0x1100_0000 / 0x1120_0000  rebuilt picture A, luma tiles / chroma tiles (2 MiB each)
 *   0x1140_0000 / 0x1160_0000  rebuilt picture B, luma tiles / chroma tiles (2 MiB each)
 *   0x1200_0000  compressed rings, 8 MiB, split by the core into one share per engine
 *   0x1300_0000  index rings, 256 records of 128 bytes, split per engine
 *
 * This header holds the contract; rtlnet_venc.c holds the per-function commentary.
 *
 * Revision: 11-10-2026 (GOP, P pictures; rate control)
 */
#ifndef RTLNET_VENC_H
#define RTLNET_VENC_H

#include <stdint.h>   /* uint32_t, uint16_t */

#include "rtlnet_ratectl.h"

#define VENC_QP_DEFAULT     28u
#define VENC_QP_MAX         51u
#define VENC_GOP_DEFAULT    30u    /* IDR every 30 pictures, P pictures in between */
#define VENC_GOP_MAX        255u   /* 1 = every picture is an IDR picture */
#define VENC_MAX_ENGINES    4u

#define VENC_OK             0
#define VENC_ERR_CORE       (-1)   /* encoder, frame buffer or write DMA not present */
#define VENC_ERR_UDP        (-2)   /* the UDP socket could not be opened */
#define VENC_ERR_BUSY       (-3)   /* a stream is already running */
#define VENC_ERR_ARG        (-4)

typedef struct {
    int      running;
    uint32_t dst_ip;            /* host order */
    uint16_t dst_port;
    uint32_t qp;                /* configured QP; the driver raises it to 12 */
    uint32_t qp_used;           /* QP written to the core */
    uint32_t gop;               /* IDR every gop pictures (1 = all IDR) */
    uint32_t idr_pictures;      /* IDR pictures sent */
    uint32_t p_pictures;        /* P pictures sent */
    uint32_t idr_bytes;         /* elementary stream bytes of the IDR pictures (SPS, PPS and slices) */
    uint32_t p_bytes;           /* elementary stream bytes of the P pictures */
    uint32_t last_idr;          /* 1 when the last picture was an IDR picture, 0 for a P picture */
    uint32_t mode;              /* RTLNET_H264_MODE_* of the last picture */
    uint32_t width, height;     /* display size of the last picture */
    uint32_t pictures;          /* pictures sent */
    uint32_t es_bytes;          /* elementary stream bytes of those pictures (SPS, PPS and slices) */
    uint32_t ts_bytes;          /* bytes handed to UDP */
    uint32_t ts_packets;
    uint32_t datagrams;
    uint32_t sink_errors;       /* datagrams refused by UDP */
    uint32_t dropped_pictures;  /* published frames the encoder skipped (frame number jumps) */
    uint32_t errors;            /* encoder errors, bad index entries, take failures */
    uint32_t last_picture_bytes;
    uint32_t bit_rate_bps;      /* ES + TS overhead over the last full second: TS bytes x 8 */
    uint32_t mux_load_permille; /* TS mux busy time over the last full second */
    uint32_t venc_load_permille;/* take, start, release and mux busy time over the last full second */
    uint32_t last_mux_us;       /* mux time of the last picture */
    uint32_t max_mux_us;
    uint32_t last_frame;        /* frame number of the last picture */
    uint32_t fb_dropped;        /* frame-buffer DROPPED counter (frames the writer could not place) */
    uint32_t fb_published;
    uint32_t hp_forced_idr;     /* pictures the encoder turned into IDR pictures (license or profile change, High profile seam) */
    /* Sequencing measurements (phase 2f), cleared with the stream statistics. Times in microseconds. */
    uint32_t cyc_n;             /* pictures started since the clear (cycle times counted from the second one) */
    uint32_t cyc_min_us;        /* picture cycle time, begin to begin */
    uint32_t cyc_avg_us;
    uint32_t cyc_max_us;
    uint32_t lag_avg_us;        /* lag at begin_picture: now minus the frame's time stamp, relative to the smallest lag seen */
    uint32_t lag_max_us;
    uint32_t mux_n;             /* pictures sent since the clear */
    uint32_t mux_ring_ts_us;    /* per picture: ring read (cache invalidate) and TS build */
    uint32_t mux_copy_us;       /* per picture: copy of the datagrams into the pbufs */
    uint32_t mux_send_us;       /* per picture: pbuf allocation, udp_sendto (lwIP and the network interface), pbuf release */
    uint32_t backlog;           /* pictures queued for the mux now (coded, not yet sent) */
    uint32_t backlog_max;
    uint32_t skipped_backlog;   /* frames skipped on purpose because the mux backlog was at its limit (a subset of dropped_pictures) */
    uint32_t backlog_limit;     /* the limit */
} venc_status_t;

/* Reset the session state (not running, QP 28). Called once at start-up. */
void venc_init(void);

/* Start a stream to ip:port (host order). VENC_OK, VENC_ERR_CORE, VENC_ERR_UDP, VENC_ERR_BUSY. */
int venc_start(uint32_t ip, uint16_t port);

/* Stop the stream and close the socket; a picture in flight is abandoned and its slot released. */
void venc_stop(void);

/* Set the QP of constant QP mode (0..51; the driver raises values below 12 to 12). VENC_ERR_ARG above 51. Effective at the next
 * picture; it does not force an IDR picture. */
int venc_set_qp(uint32_t qp);

/* Set the GOP length: an IDR picture every gop pictures, P pictures in between (1..255; 1 = all IDR). VENC_ERR_ARG outside 1..255.
 * Effective at the next picture. */
int venc_set_gop(uint32_t gop);

/* Rate control. Bit rate target in kb/s (0 = constant QP, up to 100000), virtual buffer in ms (100..2000), QP range (12 <= min <=
 * max <= 51). VENC_ERR_ARG on a value out of range. Effective at the next picture. */
int venc_set_bitrate(uint32_t kbps);
int venc_set_buffer_ms(uint32_t ms);
int venc_set_qp_range(uint32_t qp_min, uint32_t qp_max);

/* Rate control statistics, and the record of the completed second `age` seconds ago (0 = the newest; -1 beyond the ring). */
void venc_get_ratectl(ratectl_stats_t *out);
int venc_history(uint32_t age, ratectl_sec_t *out);

/* Main-loop service: start the next picture, finish a running one, mux and send. Does nothing when stopped. */
void venc_poll(void);

/* Copy out the session status and counters. */
void venc_get_status(venc_status_t *out);

/* Clear the counters (the stream keeps running). */
void venc_clear_counters(void);

/*
 * 8x8 transform of inter macroblocks (High profile module with hp_caps bit 1). rtlnet_venc_set_transform8x8: request it (on != 0, the default) or the
 * 4x4 transform; returns the driver's result (0, or RTLNET_H264_HP_ERR_NO_SEAM / _NO_MODULE / _NO_T8 for on). The change takes effect at the next
 * picture start while the profile is High: that picture is a forced IDR picture and the parameter sets are rewritten (PPS transform_8x8_mode_flag).
 * rtlnet_venc_transform8x8_wanted: the request. rtlnet_venc_transform8x8_in_force: 1 when the pictures use the transform now (High profile in
 * force, requested, offered).
 */
int rtlnet_venc_set_transform8x8(int on);
int rtlnet_venc_transform8x8_wanted(void);
int rtlnet_venc_transform8x8_in_force(void);

#endif /* RTLNET_VENC_H */
