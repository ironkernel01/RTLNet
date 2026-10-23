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

/* lwIP types appear only as pointers, so the desktop harness (no lwIP)
 * compiles against this header; int8_t is lwIP's err_t (s8_t). */
struct netif;

#define RTLNET_NETIF_RX_BUFS      4u        /* receive ring entries */
#define RTLNET_NETIF_TX_BUFS      2u        /* transmit buffers (copy overlaps the DMA) */
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
    uint32_t rx_budget_hits;  /* polls that used the whole frame budget (more frames were waiting) */
    /* Profile, in cpu_clk ticks (RTLNET_PLAT_TICKS_PER_US per microsecond), since the last clear. */
    uint32_t prof_clear;      /* plat_ticks() at the clear: wall time = now - prof_clear */
    uint32_t prof_busy;       /* polls that delivered frames: all work done from them, lwIP and applications included */
    uint32_t prof_rx_copy;    /* pbuf_alloc + pbuf_take of received frames (AXI BRAM read) */
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

#endif /* RTLNET_LWIP_NETIF_H */
