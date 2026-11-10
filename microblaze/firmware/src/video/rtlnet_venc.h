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
 * DDR3 map (byte offsets in DDR3, CPU address = DDR3 window + offset; the frame buffer holds 0x1000_0000 to 0x10C0_0000):
 *   0x1100_0000  rebuilt luma plane (stride 2048), 0x1130_0000 Cb (stride 1024), 0x1138_0000 Cr
 *   0x1200_0000  compressed rings, 8 MiB, split by the core into one share per engine
 *   0x1300_0000  index rings, 256 entries of 16 bytes, split per engine
 *
 * This header holds the contract; rtlnet_venc.c holds the per-function commentary.
 *
 * Revision: 11-09-2026
 */
#ifndef RTLNET_VENC_H
#define RTLNET_VENC_H

#include <stdint.h>   /* uint32_t, uint16_t */

#define VENC_QP_DEFAULT     28u
#define VENC_QP_MAX         51u
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
} venc_status_t;

/* Reset the session state (not running, QP 28). Called once at start-up. */
void venc_init(void);

/* Start a stream to ip:port (host order). VENC_OK, VENC_ERR_CORE, VENC_ERR_UDP, VENC_ERR_BUSY. */
int venc_start(uint32_t ip, uint16_t port);

/* Stop the stream and close the socket; a picture in flight is abandoned and its slot released. */
void venc_stop(void);

/* Set the QP (0..51; the driver raises values below 12 to 12). VENC_ERR_ARG above 51. Effective at the next picture. */
int venc_set_qp(uint32_t qp);

/* Main-loop service: start the next picture, finish a running one, mux and send. Does nothing when stopped. */
void venc_poll(void);

/* Copy out the session status and counters. */
void venc_get_status(venc_status_t *out);

/* Clear the counters (the stream keeps running). */
void venc_clear_counters(void);

#endif /* RTLNET_VENC_H */
