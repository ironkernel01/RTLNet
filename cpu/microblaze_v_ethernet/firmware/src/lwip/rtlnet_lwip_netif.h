/*
 * rtlnet_lwip_netif.h -- lwIP network interface on the AXI DMA and the
 *                        cpu_axis_ethernet_stream
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches the AXI DMA of the CPU core. Frames the
 * protocol wrapper does not claim arrive on the S2MM channel (complete
 * Ethernet frames without FCS, architecture 7.4); frames lwIP sends leave on
 * the MM2S channel into the wrapper's CPU transmit FIFO.
 *
 * Receive: polled from the main loop. RTLNET_NETIF_RX_BUFS buffers of
 * RTLNET_NETIF_BUF_BYTES in the AXI BRAM form a ring; one S2MM simple transfer
 * is armed at a time. When it completes, the next buffer is armed at once and
 * the finished one is copied into a pool pbuf (its length from the S2MM
 * length register) and handed to netif->input. A frame that finds no pbuf is
 * dropped and counted; the wrapper's 16 KiB CPU receive FIFO absorbs the
 * frames that arrive while no transfer is armed.
 *
 * Transmit: linkoutput copies the pbuf chain into one of two TX buffers in
 * the AXI BRAM, waits (bounded, RTLNET_NETIF_TX_WAIT_US) until the previous
 * MM2S transfer is done and starts the next one.
 *
 * Checksum offload (rtlnet_offload.c, hardware cores/rtlnet_tcp_offload): with
 * rx_csum on, every received DMA transfer is roundup8(frame) + 8 bytes and ends
 * in a trailer beat (frame length, flags); rtlnet_offload_rx_frame() decodes it
 * and applies the policy (bad IPv4 header or verified bad TCP/UDP checksum: drop
 * and count). The buffers hold roundup8(1522) + 8 bytes.
 *
 * Zero-copy options (lwipopts.h, RX default on, TX default off, -D to change):
 *   RTLNET_NETIF_ZERO_COPY_RX: a received buffer is handed to lwIP as a custom
 *     pbuf (PBUF_REF); lwIP's free callback returns the buffer to the free
 *     list from which the next S2MM transfer is armed. 16 buffers bound the
 *     frames lwIP can hold; with none free the S2MM channel stays idle (the
 *     wrapper's CPU receive FIFO absorbs, then counts drops) and rx_no_buf
 *     counts the polls that found none.
 *   RTLNET_NETIF_ZERO_COPY_TX: lwIP's heap lives in the AXI BRAM, so a frame
 *     built in one pbuf is sent from where it is (the DMA has a realignment
 *     engine on MM2S: any byte address); the pbuf stays referenced until the
 *     transfer is done. Chained pbufs and pbufs outside the AXI BRAM are
 *     copied into one of the two transmit buffers.
 *
 * Receive batching (hardware RX_BATCH, rtlnet_offload.c / the CLI "offload rx-batch"): the AXI DMA transfer of
 * a batch holds several frames, each padded to 8 bytes and followed by its trailer. The receive buffers then
 * have the batch geometry: RTLNET_NETIF_BATCH_BUFS buffers of RTLNET_NETIF_BATCH_BUF_BYTES (the hardware closes a
 * batch before its byte limit, which is set to the buffer size, so a transfer never overruns). One poll step per
 * transfer: rtlnet_tcp_offload_batch_walk splits it (bounds-checked), every frame goes through the same trailer
 * policy as a single frame and is handed to lwIP on its own: zero-copy receive hands each frame as a custom
 * PBUF_REF pbuf and counts the references per buffer, the buffer returns to the free list when the last one is
 * freed; a batch that finds no free buffer left to arm is copied into pool pbufs instead, so the channel never
 * starves for buffers lwIP holds. Switching the geometry (rtlnet_netif_set_rx_batch) needs every buffer free;
 * with batching off the buffers are the 2 KiB single-frame buffers above and none of this code runs. A build
 * without the batch hardware never leaves that mode.
 *
 * Memory rule: the MicroBlaze has no caches, so the DMA buffers need no flush
 * or invalidate; the CPU reads and writes them uncached over M_AXI_DP. The
 * buffers are 64-byte aligned (DMA without realignment engine needs 8).
 *
 * This header holds types, constants and signatures; the .c file holds the
 * per-function commentary.
 */
#ifndef RTLNET_LWIP_NETIF_H
#define RTLNET_LWIP_NETIF_H

#include <stdint.h>   /* int8_t, uint32_t */

#include "lwipopts.h"           /* RTLNET_NETIF_ZERO_COPY_RX / _TX */
#include "rtlnet_tcp_offload.h" /* RTLNET_TXO_RX_BUFFER_BYTES */

/* lwIP types appear only as pointers, so the desktop harness (no lwIP)
 * compiles against this header; int8_t is lwIP's err_t (s8_t). */
struct netif;

#if RTLNET_NETIF_ZERO_COPY_RX
#define RTLNET_NETIF_RX_BUFS      16u       /* receive buffers: lwIP holds some, one is armed */
#else
#define RTLNET_NETIF_RX_BUFS      4u        /* receive buffers: one armed, the rest free */
#endif
#define RTLNET_NETIF_TX_BUFS      2u        /* transmit buffers (copy overlaps the DMA) */

/* Batch geometry: the same memory as the single-frame buffers, carved into larger buffers. */
#define RTLNET_NETIF_BATCH_BUF_BYTES  8192u
#if RTLNET_NETIF_ZERO_COPY_RX
#define RTLNET_NETIF_BATCH_BUFS   4u        /* one armed, up to three held by lwIP */
#else
#define RTLNET_NETIF_BATCH_BUFS   2u        /* copy receive: one armed, one being delivered */
#endif
#define RTLNET_NETIF_BATCH_MAX_FRAMES RTLNET_TXO_BATCH_MAX_FRAMES   /* walker array; the hardware count limit stays below */
#define RTLNET_NETIF_BATCH_LOANS  128u      /* custom pbufs on loan across all batch buffers (zero-copy receive) */
/* Receive memory in 2 KiB units: the single-frame buffers, or the batch buffers when those need more. */
#if (RTLNET_NETIF_BATCH_BUFS * RTLNET_NETIF_BATCH_BUF_BYTES / 2048u) > RTLNET_NETIF_RX_BUFS
#define RTLNET_NETIF_RX_POOL_UNITS (RTLNET_NETIF_BATCH_BUFS * RTLNET_NETIF_BATCH_BUF_BYTES / 2048u)
#else
#define RTLNET_NETIF_RX_POOL_UNITS RTLNET_NETIF_RX_BUFS
#endif
#define RTLNET_NETIF_BUF_BYTES    2048u     /* per buffer; holds the 1518-byte frame */
#define RTLNET_NETIF_BUF_ALIGN    64u
#define RTLNET_NETIF_RX_BUDGET    8u        /* frames handled per poll call */
#define RTLNET_NETIF_TX_WAIT_US   2000u     /* bound on the wait for the previous MM2S transfer */
#define RTLNET_NETIF_RESET_POLLS  10000u    /* bound on the DMA reset completion */
#define RTLNET_NETIF_MIN_FRAME    14u       /* Ethernet header */
#define RTLNET_NETIF_MTU          1500u

/* 1: timers around the copies and the lwIP input in rtlnet_netif_stats_t (show cpu-path prints them). */
#ifndef RTLNET_NETIF_PROFILE
#define RTLNET_NETIF_PROFILE      0
#endif

#if RTLNET_NETIF_BUF_BYTES < 1518u
#error "RTLNET_NETIF_BUF_BYTES is smaller than a maximum Ethernet frame"
#endif
#if RTLNET_NETIF_BUF_BYTES < RTLNET_TXO_RX_BUFFER_BYTES(1522u)
#error "RTLNET_NETIF_BUF_BYTES cannot hold roundup8(1522) + 8 bytes (frame, padding and receive trailer)"
#endif

typedef struct {
    uint32_t rx_frames;       /* frames delivered to lwIP */
    uint32_t rx_bytes;
    uint32_t rx_no_pbuf;      /* dropped: pbuf pool empty */
    uint32_t rx_runts;        /* dropped: shorter than an Ethernet header */
    uint32_t rx_unbound;      /* dropped: lwIP not running */
    uint32_t rx_errors;       /* S2MM error status (channel reset) */
    uint32_t tx_frames;
    uint32_t tx_bytes;
    uint32_t tx_timeouts;     /* previous MM2S transfer did not finish in time */
    uint32_t tx_too_long;
    uint32_t tx_errors;       /* MM2S error status or refused transfer */
    uint32_t dma_resets;
    uint32_t rx_drop_ip;      /* dropped by the trailer policy: bad IPv4 header */
    uint32_t rx_drop_l4;      /* dropped by the trailer policy: bad TCP/UDP checksum */
    uint32_t rx_no_trailer;   /* dropped: rx_csum on but no trailer */
    uint32_t rx_no_buf;       /* polls that found no free receive buffer to arm (zero-copy receive) */
    uint32_t tx_zero_copy;    /* frames sent from the pbuf in place */
    uint32_t tx_copied;       /* frames copied into a transmit buffer */
    uint32_t rx_budget_hits;  /* polls that used the whole frame budget (more frames were waiting) */
    uint32_t rx_batches;      /* receive batching: transfers walked (a single frame is a batch of one) */
    uint32_t rx_batch_frames; /* frames taken out of them */
    uint32_t rx_batch_max;    /* most frames in one transfer */
    uint32_t rx_batch_bad;    /* transfers that did not walk (malformed or too many frames), dropped */
    uint32_t rx_batch_copied; /* transfers copied into pool pbufs: no buffer left to arm (zero-copy receive) */
    uint32_t rx_batch_noloan; /* frames copied because the loan table was full */
    /* Profile, in cpu_clk ticks (RTLNET_PLAT_TICKS_PER_US per microsecond), since the last clear. */
    uint32_t prof_clear;      /* plat_ticks() at the clear: wall time = now - prof_clear */
    uint32_t prof_busy;       /* polls that delivered frames: all work done from them, lwIP and applications included */
    uint32_t prof_rx_copy;    /* pbuf_alloc + copy of received frames (AXI BRAM read), trailer decode */
    uint32_t prof_rx_input;   /* netif->input: lwIP receive path, TCP, applications, and the frames they send */
    uint32_t prof_tx_copy;    /* pbuf chain written to the TX buffer (AXI BRAM word writes) */
    uint32_t prof_tx_wait;    /* wait for the previous MM2S transfer */
    uint32_t prof_tx_start;   /* XAxiDma_SimpleTransfer */
} rtlnet_netif_stats_t;

int                         rtlnet_netif_hw_init(void);
int                         rtlnet_netif_hw_present(void);
void                        rtlnet_netif_set_hwaddr(const uint8_t mac[6]);
int8_t                      rtlnet_netif_init(struct netif *nif);
void                        rtlnet_netif_poll(struct netif *nif);
const rtlnet_netif_stats_t *rtlnet_netif_stats(void);
void                        rtlnet_netif_clear_stats(void);
uint32_t                    rtlnet_netif_dma_sr(int rx);
int                         rtlnet_netif_set_rx_batch(int on);
int                         rtlnet_netif_rx_batch_active(void);
uint32_t                    rtlnet_netif_rx_buf_bytes(void);

/* rtlnet_netif_set_rx_batch results. */
#define RTLNET_NETIF_BATCH_OK       0
#define RTLNET_NETIF_BATCH_BUSY     (-1)   /* buffers are on loan to lwIP or a transmit is running: try again */
#define RTLNET_NETIF_BATCH_ABSENT   (-2)   /* no DMA, or no batch hardware in this bitstream */

#endif /* RTLNET_LWIP_NETIF_H */
