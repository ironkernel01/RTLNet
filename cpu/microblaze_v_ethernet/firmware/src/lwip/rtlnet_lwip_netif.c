/*
 * rtlnet_lwip_netif.c -- lwIP network interface on the AXI DMA and the
 *                        cpu_axis_ethernet_stream
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_lwip_netif.h for the contract. Context: main loop only (the DMA
 * interrupts are wired to the INTC but stay disabled; the channels are
 * polled).
 */
#include "rtlnet_lwip_netif.h"

#include <string.h>   /* memcpy */

#include "rtlnet_offload.h"
#include "rtlnet_platform.h"

#include "lwip/etharp.h"
#include "lwip/pbuf.h"
#include "lwip/stats.h"
#include "netif/ethernet.h"

#include "xaxidma.h"   /* XAxiDma */
#include "xstatus.h"   /* XST_SUCCESS */

/* DMA buffers and, with zero-copy transmit, lwIP's heap: the only firmware data in the AXI BRAM (section
 * .axi_bram, NOLOAD, placed at RTLNET_CPU_AXI_BRAM_BASE by the linker script). */
#define NETIF_AXI_BRAM __attribute__((section(".axi_bram"), aligned(RTLNET_NETIF_BUF_ALIGN)))

static uint8_t g_rx_buf[RTLNET_NETIF_RX_POOL_UNITS][RTLNET_NETIF_BUF_BYTES] NETIF_AXI_BRAM;
static uint8_t g_tx_buf[RTLNET_NETIF_TX_BUFS][RTLNET_NETIF_BUF_BYTES] NETIF_AXI_BRAM;

#if RTLNET_NETIF_ZERO_COPY_TX
unsigned char rtlnet_lwip_heap[RTLNET_LWIP_HEAP_BYTES] NETIF_AXI_BRAM;
#endif

#if RTLNET_NETIF_ZERO_COPY_RX
/* A received buffer on loan to lwIP: the custom pbuf and the buffer it returns on free. */
typedef struct {
    struct pbuf_custom pc;    /* first: lwIP's free callback receives &pc.pbuf */
    uint8_t            idx;
} rx_loan_t;

static rx_loan_t g_rx_loan[RTLNET_NETIF_RX_BUFS];
#endif

#if RTLNET_NETIF_ZERO_COPY_RX
/* Batch geometry, zero-copy receive: one custom pbuf per frame on loan, and the references per buffer. */
typedef struct {
    struct pbuf_custom pc;    /* first: lwIP's free callback receives &pc.pbuf */
    uint8_t            idx;   /* the receive buffer the frame lives in */
    uint8_t            next;  /* next free loan (index + 1, 0 = none) while on the free list */
} bat_loan_t;

static bat_loan_t g_bat_loan[RTLNET_NETIF_BATCH_LOANS];
static unsigned   g_bat_loan_free;                       /* free list head (index + 1, 0 = empty) */
static uint16_t   g_buf_ref[RTLNET_NETIF_RX_BUFS];       /* frames of a batch buffer still held by lwIP, plus the delivery loop */
#endif

static rtlnet_txo_batch_frame_t g_bat_fr[RTLNET_NETIF_BATCH_MAX_FRAMES];   /* the walker output of one transfer */
static unsigned             g_buf_n = RTLNET_NETIF_RX_BUFS;       /* receive buffers in the current geometry */
static uint32_t             g_buf_bytes = RTLNET_NETIF_BUF_BYTES; /* and their size */
static int                  g_batch_geom;                         /* 1: batch geometry */
static XAxiDma              g_dma;
static int                  g_present;        /* DMA configured */
static int                  g_rx_armed;       /* an S2MM transfer is outstanding into g_rx_buf[g_rx_armed_idx] */
static unsigned             g_rx_armed_idx;
static uint8_t              g_free[RTLNET_NETIF_RX_BUFS];   /* stack of free receive buffer indices */
static unsigned             g_free_n;
static unsigned             g_tx_idx;
static struct pbuf         *g_tx_pending;     /* zero-copy transmit: the pbuf the MM2S transfer reads */
static uint8_t              g_hwaddr[6];
static rtlnet_netif_stats_t g_st;

/*
 * free_push -- a receive buffer is free again.
 * Returns: nothing.
 */
static void free_push(unsigned idx)
{
    if (g_free_n < g_buf_n) {
        g_free[g_free_n++] = (uint8_t)idx;
    }
}

/*
 * free_reset -- every receive buffer free (start-up).
 * Returns: nothing.
 */
static void free_reset(void)
{
    g_free_n = 0u;
    for (unsigned i = g_buf_n; i > 0u; i--) {
        g_free[g_free_n++] = (uint8_t)(i - 1u);
    }
}

/*
 * rx_buf_ptr -- start of receive buffer idx in the current geometry (the same memory, 2 KiB or batch buffers).
 * Returns: the address.
 */
static uint8_t *rx_buf_ptr(unsigned idx)
{
    return &g_rx_buf[0][0] + (size_t)idx * g_buf_bytes;
}

/*
 * dma_reset -- reset both channels and wait (bounded) for completion.
 * A receive transfer in flight is cancelled and its buffer is free again.
 * Returns: 0 done, -1 the reset did not complete.
 */
static int dma_reset(void)
{
    XAxiDma_Reset(&g_dma);
    for (uint32_t i = 0; i < RTLNET_NETIF_RESET_POLLS; i++) {
        if (XAxiDma_ResetIsDone(&g_dma)) {
            XAxiDma_IntrDisable(&g_dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
            XAxiDma_IntrDisable(&g_dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
            g_st.dma_resets++;
            if (g_rx_armed) {
                free_push(g_rx_armed_idx);
            }
            g_rx_armed = 0;
            if (g_tx_pending != NULL) {
                pbuf_free(g_tx_pending);
                g_tx_pending = NULL;
            }
            return 0;
        }
    }
    return -1;
}

/*
 * chan_busy -- a transfer is in progress on a channel.
 * XAxiDma_Busy reports a halted channel (never started, or after a reset) as
 * busy, because IDLE is 0 while HALTED is 1; a halted channel takes a new
 * simple transfer at once, so it counts as free here.
 * Returns: 1 running and not idle, 0 idle or halted.
 */
static int chan_busy(int rx)
{
    uint32_t sr = XAxiDma_ReadReg(g_dma.RegBase, (rx ? XAXIDMA_RX_OFFSET : XAXIDMA_TX_OFFSET) + XAXIDMA_SR_OFFSET);
    return ((sr & (XAXIDMA_HALTED_MASK | XAXIDMA_IDLE_MASK)) == 0u) ? 1 : 0;
}

/* Profile (RTLNET_NETIF_PROFILE in the header): timer reads around the copy and lwIP calls cost
 * about 3% of the receive throughput, so a build without them is the one to measure speed with. */
#if RTLNET_NETIF_PROFILE
#define PROF_NOW()          plat_ticks()
#define PROF_ADD(field, t0) do { g_st.field += plat_ticks() - (t0); } while (0)
#else
#define PROF_NOW()          0u
#define PROF_ADD(field, t0) ((void)(t0))
#endif

/* 32-bit access to byte buffers (the frame buffers are byte arrays). */
typedef uint32_t __attribute__((may_alias)) word_t;

/*
 * axi_put_chain -- copy a pbuf chain into a TX buffer in the AXI BRAM with word writes only.
 * The CPU reaches the AXI BRAM over M_AXI_DP, about 16 cycles per access whatever its width, and the
 * pieces of a chain start at odd offsets (54 byte header, then the payload at any alignment). A byte
 * copy, which is what memcpy does for mismatched alignments, cost about 20 cycles per byte (307 us per
 * frame). Here the bytes are packed into words in registers (little endian): bytes of a piece are
 * consumed until its source is word aligned, then every source word is shifted into place against the
 * pending bytes and written as one aligned word.
 * Returns: nothing; the last partial word is written whole (the DMA length cuts it).
 */
static void axi_put_chain(volatile word_t *dst, const struct pbuf *p)
{
    uint32_t acc = 0u;   /* pending bytes, lowest byte first */
    uint32_t nb = 0u;    /* number of pending bytes, 0..3 */
    for (; p != NULL; p = p->next) {
        const uint8_t *s = (const uint8_t *)p->payload;
        uint32_t n = p->len;
#if defined(__BYTE_ORDER__) && (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
        while (n != 0u && ((uintptr_t)s & 3u) != 0u) {
            acc |= (uint32_t)*s++ << (8u * nb);
            n--;
            if (++nb == 4u) {
                *dst++ = acc;
                acc = 0u;
                nb = 0u;
            }
        }
        if (n >= 4u) {
            const word_t *w = (const word_t *)(const void *)s;
            if (nb == 0u) {
                while (n >= 16u) {
                    uint32_t v0 = w[0];
                    uint32_t v1 = w[1];
                    uint32_t v2 = w[2];
                    uint32_t v3 = w[3];
                    dst[0] = v0;
                    dst[1] = v1;
                    dst[2] = v2;
                    dst[3] = v3;
                    dst += 4;
                    w += 4;
                    n -= 16u;
                }
                while (n >= 4u) {
                    *dst++ = *w++;
                    n -= 4u;
                }
            } else {
                uint32_t up = 8u * nb;
                uint32_t down = 32u - up;
                while (n >= 16u) {
                    uint32_t v0 = w[0];
                    uint32_t v1 = w[1];
                    uint32_t v2 = w[2];
                    uint32_t v3 = w[3];
                    dst[0] = acc | (v0 << up);
                    dst[1] = (v0 >> down) | (v1 << up);
                    dst[2] = (v1 >> down) | (v2 << up);
                    dst[3] = (v2 >> down) | (v3 << up);
                    acc = v3 >> down;
                    dst += 4;
                    w += 4;
                    n -= 16u;
                }
                while (n >= 4u) {
                    uint32_t v = *w++;
                    *dst++ = acc | (v << up);
                    acc = v >> down;
                    n -= 4u;
                }
            }
            s = (const uint8_t *)(const void *)w;
        }
#endif
        while (n != 0u) {
            acc |= (uint32_t)*s++ << (8u * nb);
            n--;
            if (++nb == 4u) {
                *dst++ = acc;
                acc = 0u;
                nb = 0u;
            }
        }
    }
    if (nb != 0u) {
        *dst = acc;
    }
}

#if !RTLNET_NETIF_ZERO_COPY_RX   /* with zero-copy receive lwIP reads the frame where it is */
/*
 * axi_get_words -- copy a received frame from an RX buffer in the AXI BRAM into a pbuf payload.
 * Whole 32-bit reads (about 16 cycles each over M_AXI_DP, no way to overlap two of them), eight
 * per loop pass; the payload of a pool pbuf is word aligned. Words past len are copied too (the
 * pool payload is larger than a frame, so the write stays inside it).
 * Returns: nothing.
 */
static void axi_get_words(word_t *dst, const volatile word_t *src, uint32_t n_bytes)
{
    uint32_t n = (n_bytes + 3u) >> 2;
    while (n >= 8u) {
        uint32_t a = src[0];
        uint32_t b = src[1];
        uint32_t c = src[2];
        uint32_t d = src[3];
        uint32_t e = src[4];
        uint32_t f = src[5];
        uint32_t g = src[6];
        uint32_t h = src[7];
        dst[0] = a;
        dst[1] = b;
        dst[2] = c;
        dst[3] = d;
        dst[4] = e;
        dst[5] = f;
        dst[6] = g;
        dst[7] = h;
        dst += 8;
        src += 8;
        n -= 8u;
    }
    while (n != 0u) {
        *dst++ = *src++;
        n--;
    }
}
#endif

/*
 * rx_arm -- start an S2MM simple transfer into a free receive buffer.
 * Returns: nothing; g_rx_armed tells whether the transfer started (no free
 * buffer, or a refused transfer: it did not).
 */
static void rx_arm(void)
{
    unsigned idx;
    if (g_free_n == 0u) {
        g_rx_armed = 0;
        return;
    }
    idx = g_free[g_free_n - 1u];
    if (XAxiDma_SimpleTransfer(&g_dma, (UINTPTR)rx_buf_ptr(idx), g_buf_bytes, XAXIDMA_DEVICE_TO_DMA) ==
        XST_SUCCESS) {
        g_free_n--;
        g_rx_armed_idx = idx;
        g_rx_armed = 1;
    } else {
        g_rx_armed = 0;
    }
}

/*
 * rtlnet_netif_hw_init -- find and configure the AXI DMA, arm the first receive buffer.
 * Steps:
 *   1. XAxiDma_LookupConfig at RTLNET_PLAT_DMA_BASE; refuse a scatter-gather
 *      build (the block design is simple mode).
 *   2. XAxiDma_CfgInitialize, channel reset, interrupts off.
 *   3. Every receive buffer free, arm one.
 * Returns: 0 configured, -1 no DMA or a failed initialization.
 */
int rtlnet_netif_hw_init(void)
{
    XAxiDma_Config *cfg;
    g_present = 0;
    g_tx_idx = 0u;
    g_tx_pending = NULL;
    g_rx_armed = 0;
    free_reset();
    cfg = XAxiDma_LookupConfig(RTLNET_PLAT_DMA_BASE);
    if (cfg == NULL || XAxiDma_CfgInitialize(&g_dma, cfg) != XST_SUCCESS || XAxiDma_HasSg(&g_dma)) {
        return -1;
    }
    if (dma_reset() != 0) {
        return -1;
    }
    g_st.dma_resets = 0u;
    g_present = 1;
    rx_arm();
    return 0;
}

/*
 * rtlnet_netif_hw_present -- the DMA answered at start-up.
 * Returns: 1 present, 0 absent.
 */
int rtlnet_netif_hw_present(void)
{
    return g_present;
}

/*
 * rtlnet_netif_set_hwaddr -- MAC address the next rtlnet_netif_init copies.
 * Returns: nothing.
 */
void rtlnet_netif_set_hwaddr(const uint8_t mac[6])
{
    memcpy(g_hwaddr, mac, sizeof(g_hwaddr));
}

/*
 * tx_reap -- release the pbuf of a finished zero-copy transmit.
 * Returns: nothing.
 */
static void tx_reap(void)
{
    if (g_tx_pending != NULL && !chan_busy(0)) {
        pbuf_free(g_tx_pending);
        g_tx_pending = NULL;
    }
}

#if RTLNET_NETIF_ZERO_COPY_TX
/*
 * in_axi_bram -- a buffer lies wholly in the AXI BRAM, where the DMA can read it.
 * The desktop test builds its pbufs in lwIP's heap, which stands in for the AXI BRAM there.
 * Returns: 1 yes, 0 no.
 */
static int in_axi_bram(const void *p, uint32_t len)
{
    uintptr_t a = (uintptr_t)p;
#ifdef RTLNET_HOST_TEST
    return (a >= (uintptr_t)rtlnet_lwip_heap && a + len <= (uintptr_t)rtlnet_lwip_heap + RTLNET_LWIP_HEAP_BYTES) ? 1 : 0;
#else
    return (a >= RTLNET_CPU_AXI_BRAM_BASE && a + len <= (uintptr_t)RTLNET_CPU_AXI_BRAM_BASE + RTLNET_CPU_AXI_BRAM_SIZE) ? 1 : 0;
#endif
}
#endif

/*
 * netif_linkoutput -- send one frame.
 * Steps:
 *   1. Reject frames longer than a buffer.
 *   2. Zero-copy transmit: a single pbuf inside the AXI BRAM is sent in
 *      place and stays referenced until its transfer is done. Otherwise the
 *      pbuf chain is copied into the free TX buffer (axi_put_chain: word
 *      writes only).
 *   3. Wait (bounded) for the previous transfer; on an MM2S error reset the
 *      DMA and re-arm the receive side.
 *   4. Start the simple transfer, switch buffers, count.
 * Returns: ERR_OK sent, ERR_IF dropped (too long, timeout, DMA error).
 */
static err_t netif_linkoutput(struct netif *nif, struct pbuf *p)
{
    uint8_t *buf;
    uint16_t len = p->tot_len;
    uint32_t t0;
    uint32_t t1;
    uint32_t t2;
    uint32_t sr;
    int in_place = 0;
    (void)nif;
    if (!g_present) {
        return ERR_IF;
    }
    if (len > RTLNET_NETIF_BUF_BYTES) {
        g_st.tx_too_long++;
        return ERR_IF;
    }
#if RTLNET_NETIF_ZERO_COPY_TX
    in_place = (p->next == NULL && in_axi_bram(p->payload, len)) ? 1 : 0;
#endif
    buf = g_tx_buf[g_tx_idx];
    t0 = PROF_NOW();
    if (in_place) {
        buf = (uint8_t *)p->payload;
    } else {
        axi_put_chain((volatile word_t *)(void *)buf, p);
    }
    t1 = plat_ticks();
    PROF_ADD(prof_tx_copy, t0);
    while (chan_busy(0)) {
        if ((plat_ticks() - t1) >= RTLNET_NETIF_TX_WAIT_US * RTLNET_PLAT_TICKS_PER_US) {
            g_st.tx_timeouts++;
            LINK_STATS_INC(link.drop);
            return ERR_IF;
        }
    }
    t2 = PROF_NOW();
    PROF_ADD(prof_tx_wait, t1);
    tx_reap();
    sr = XAxiDma_ReadReg(g_dma.RegBase, XAXIDMA_TX_OFFSET + XAXIDMA_SR_OFFSET);
    if (sr & XAXIDMA_ERR_ALL_MASK) {
        g_st.tx_errors++;
        (void)dma_reset();
        rx_arm();
    }
    if (XAxiDma_SimpleTransfer(&g_dma, (UINTPTR)buf, len, XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS) {
        g_st.tx_errors++;
        LINK_STATS_INC(link.err);
        return ERR_IF;
    }
    PROF_ADD(prof_tx_start, t2);
    if (in_place) {
        pbuf_ref(p);
        g_tx_pending = p;
        g_st.tx_zero_copy++;
    } else {
        g_tx_idx = (g_tx_idx + 1u) % RTLNET_NETIF_TX_BUFS;
        g_st.tx_copied++;
    }
    g_st.tx_frames++;
    g_st.tx_bytes += len;
    LINK_STATS_INC(link.xmit);
    return ERR_OK;
}

/*
 * rtlnet_netif_init -- lwIP netif init callback (netif_add).
 * Steps:
 *   1. Name, MTU, MAC (from rtlnet_netif_set_hwaddr), Ethernet/ARP flags.
 *   2. output = etharp_output, linkoutput = the DMA transmit above.
 * Returns: ERR_OK, ERR_IF when the DMA is absent.
 */
int8_t rtlnet_netif_init(struct netif *nif)
{
    if (!g_present) {
        return ERR_IF;
    }
    nif->name[0] = 'e';
    nif->name[1] = '0';
    nif->mtu = RTLNET_NETIF_MTU;
    nif->hwaddr_len = ETH_HWADDR_LEN;
    memcpy(nif->hwaddr, g_hwaddr, ETH_HWADDR_LEN);
    nif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_ETHERNET;
    nif->output = etharp_output;
    nif->linkoutput = netif_linkoutput;
    return ERR_OK;
}

#if RTLNET_NETIF_ZERO_COPY_RX
/*
 * rx_loan_free -- lwIP is done with a receive buffer: it is free again.
 * Returns: nothing.
 */
static void rx_loan_free(struct pbuf *p)
{
    rx_loan_t *l = (rx_loan_t *)(void *)p;
    free_push(l->idx);
}
#endif

/*
 * rx_deliver -- give one received frame to lwIP.
 * Steps:
 *   1. rtlnet_offload_rx_frame decodes the trailer (when rx_csum is on) and
 *      applies the drop policy; a dropped frame frees its buffer.
 *   2. A frame shorter than an Ethernet header is a runt.
 *   3. Zero-copy receive: the buffer becomes a custom PBUF_REF pbuf that
 *      frees itself back to the free list; otherwise the frame is copied into
 *      a pool pbuf and the buffer is free at once.
 * Returns: nothing; drops are counted.
 */
static void rx_deliver(struct netif *nif, unsigned idx, uint32_t xfer_len)
{
    const uint8_t *buf = g_rx_buf[idx];
    uint32_t len = xfer_len;
    struct pbuf *p;
    uint32_t t0 = PROF_NOW();
    uint32_t t1;
    switch (rtlnet_offload_rx_frame(buf, xfer_len, &len)) {
    case RTLNET_RXA_DROP_BAD_IP:
        g_st.rx_drop_ip++;
        LINK_STATS_INC(link.drop);
        free_push(idx);
        return;
    case RTLNET_RXA_DROP_BAD_L4:
        g_st.rx_drop_l4++;
        LINK_STATS_INC(link.drop);
        free_push(idx);
        return;
    case RTLNET_RXA_DROP_NO_TRAILER:
        g_st.rx_no_trailer++;
        LINK_STATS_INC(link.drop);
        free_push(idx);
        return;
    default:
        break;
    }
    if (len < RTLNET_NETIF_MIN_FRAME || len > RTLNET_NETIF_BUF_BYTES) {
        g_st.rx_runts++;
        free_push(idx);
        return;
    }
    if (nif == NULL) {
        g_st.rx_unbound++;
        free_push(idx);
        return;
    }
#if RTLNET_NETIF_ZERO_COPY_RX
    g_rx_loan[idx].idx = (uint8_t)idx;
    g_rx_loan[idx].pc.custom_free_function = rx_loan_free;
    p = pbuf_alloced_custom(PBUF_RAW, (u16_t)len, PBUF_REF, &g_rx_loan[idx].pc, g_rx_buf[idx], RTLNET_NETIF_BUF_BYTES);
    if (p == NULL) {
        g_st.rx_no_pbuf++;
        LINK_STATS_INC(link.memerr);
        free_push(idx);
        return;
    }
#else
    p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
    if (p == NULL) {
        g_st.rx_no_pbuf++;
        LINK_STATS_INC(link.memerr);
        free_push(idx);
        return;
    }
    if (p->next == NULL && ((uintptr_t)p->payload & 3u) == 0u && (len + 3u) <= PBUF_POOL_BUFSIZE) {
        axi_get_words((word_t *)p->payload, (const volatile word_t *)(const void *)buf, len);
    } else {
        (void)pbuf_take(p, buf, (u16_t)len);
    }
    free_push(idx);
#endif
    t1 = PROF_NOW();
    PROF_ADD(prof_rx_copy, t0);
    g_st.rx_frames++;
    g_st.rx_bytes += len;
    LINK_STATS_INC(link.recv);
    if (nif->input(p, nif) != ERR_OK) {
        pbuf_free(p);
    }
    PROF_ADD(prof_rx_input, t1);
}

#if RTLNET_NETIF_ZERO_COPY_RX
/*
 * bat_loans_reset -- every loan free, every reference count 0 (geometry change, all buffers free).
 * Returns: nothing.
 */
static void bat_loans_reset(void)
{
    g_bat_loan_free = 0u;
    for (unsigned i = RTLNET_NETIF_BATCH_LOANS; i > 0u; i--) {
        g_bat_loan[i - 1u].next = (uint8_t)g_bat_loan_free;
        g_bat_loan_free = i;
    }
    memset(g_buf_ref, 0, sizeof(g_buf_ref));
}

/*
 * bat_unref -- one reference of a batch buffer is gone; the last one frees the buffer.
 * Returns: nothing.
 */
static void bat_unref(unsigned idx)
{
    if (g_buf_ref[idx] != 0u && --g_buf_ref[idx] == 0u) {
        free_push(idx);
    }
}

/*
 * bat_loan_free -- lwIP is done with one frame of a batch buffer: the loan and the reference go back.
 * Returns: nothing.
 */
static void bat_loan_free(struct pbuf *p)
{
    bat_loan_t *l = (bat_loan_t *)(void *)p;
    unsigned i = (unsigned)(l - g_bat_loan);
    unsigned idx = l->idx;
    l->next = (uint8_t)g_bat_loan_free;
    g_bat_loan_free = i + 1u;
    bat_unref(idx);
}
#endif

/*
 * bat_frame_out -- give one frame of a batch buffer to lwIP.
 * Zero-copy receive (and not copying this batch): a custom PBUF_REF pbuf on a loan, one buffer reference; a full
 * loan table or the copy mode: a pool pbuf with a copy of the frame.
 * Returns: nothing; drops are counted.
 */
static void bat_frame_out(struct netif *nif, unsigned idx, uint32_t off, uint32_t len, int copy)
{
    uint8_t *base = rx_buf_ptr(idx);
    struct pbuf *p = NULL;
#if !RTLNET_NETIF_ZERO_COPY_RX
    (void)copy;   /* every frame is copied */
#endif
    if (len < RTLNET_NETIF_MIN_FRAME || len > RTLNET_NETIF_BATCH_BUF_BYTES) {
        g_st.rx_runts++;
        return;
    }
    if (nif == NULL) {
        g_st.rx_unbound++;
        return;
    }
#if RTLNET_NETIF_ZERO_COPY_RX
    if (!copy && g_bat_loan_free != 0u) {
        unsigned li = g_bat_loan_free - 1u;
        bat_loan_t *l = &g_bat_loan[li];
        g_bat_loan_free = l->next;
        l->idx = (uint8_t)idx;
        l->pc.custom_free_function = bat_loan_free;
        p = pbuf_alloced_custom(PBUF_RAW, (u16_t)len, PBUF_REF, &l->pc, base + off, (u16_t)RTLNET_TXO_ROUNDUP8(len));
        if (p != NULL) {
            g_buf_ref[idx]++;
        } else {
            l->next = (uint8_t)g_bat_loan_free;
            g_bat_loan_free = li + 1u;
        }
    } else if (!copy) {
        g_st.rx_batch_noloan++;
    }
#endif
    if (p == NULL) {
        p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
        if (p == NULL) {
            g_st.rx_no_pbuf++;
            LINK_STATS_INC(link.memerr);
            return;
        }
        (void)pbuf_take(p, base + off, (u16_t)len);
    }
    g_st.rx_frames++;
    g_st.rx_bytes += len;
    LINK_STATS_INC(link.recv);
    if (nif->input(p, nif) != ERR_OK) {
        pbuf_free(p);
    }
}

/*
 * batch_deliver -- one completed S2MM transfer in the batch geometry: split into frames, apply the trailer policy
 * to each, hand each to lwIP.
 * Steps:
 *   1. The delivery loop holds one reference of the buffer (zero-copy); a transfer that leaves no buffer free to arm
 *      is copied frame by frame (the buffer is free at the end).
 *   2. Trailers expected (rx offload on): rtlnet_tcp_offload_batch_walk splits the transfer. A transfer that does not
 *      walk (a raw frame while rx offload turns off, a malformed batch) falls back to the single-frame decision of
 *      rtlnet_offload_rx_frame on the whole transfer, which counts and drops what has no trailer.
 *   3. Each walked frame: rtlnet_offload_rx_frame on its own span (padded frame and trailer) gives the policy; delivered
 *      frames are the trailer's length.
 *   4. The delivery loop's reference goes.
 * Returns: nothing.
 */
static void batch_deliver(struct netif *nif, unsigned idx, uint32_t xfer_len)
{
    uint8_t *base = rx_buf_ptr(idx);
    rtlnet_txo_batch_frame_t *fr = g_bat_fr;   /* static: the 8 KiB stack stays free for the lwIP input chain */
    uint32_t n = 0u;
    int walked = 0;
    int copy = g_rx_armed ? 0 : 1;   /* no buffer was left to arm: free this one at once */
    uint32_t t0 = PROF_NOW();
#if RTLNET_NETIF_ZERO_COPY_RX
    g_buf_ref[idx] = 1u;
#else
    copy = 1;
#endif
    if (rtlnet_offload_state()->rx_state != RTLNET_RX_TRAILER_OFF) {
        int rc = rtlnet_tcp_offload_batch_walk(base, xfer_len, fr, RTLNET_NETIF_BATCH_MAX_FRAMES, &n);
        walked = (rc == RTLNET_TXO_OK) ? 1 : 0;
        if (!walked) {
            n = 0u;
            if (rtlnet_offload_state()->rx_state == RTLNET_RX_TRAILER_ON) {
                g_st.rx_batch_bad++;   /* trailers are established: neither a batch nor a frame with a trailer */
            }
        }
    }
    if (copy) {
        g_st.rx_batch_copied++;
    }
    if (walked) {
        g_st.rx_batches++;
        g_st.rx_batch_frames += n;
        if (n > g_st.rx_batch_max) {
            g_st.rx_batch_max = n;
        }
        for (uint32_t i = 0u; i < n; i++) {
            uint32_t flen = 0u;
            uint32_t span = RTLNET_TXO_ROUNDUP8((uint32_t)fr[i].trailer.frame_len) + RTLNET_TXO_TRAILER_BYTES;
            switch (rtlnet_offload_rx_frame(base + fr[i].offset, span, &flen)) {
            case RTLNET_RXA_DROP_BAD_IP:
                g_st.rx_drop_ip++;
                LINK_STATS_INC(link.drop);
                break;
            case RTLNET_RXA_DROP_BAD_L4:
                g_st.rx_drop_l4++;
                LINK_STATS_INC(link.drop);
                break;
            case RTLNET_RXA_DROP_NO_TRAILER:
                g_st.rx_no_trailer++;
                LINK_STATS_INC(link.drop);
                break;
            default:
                bat_frame_out(nif, idx, fr[i].offset, flen, copy);
                break;
            }
        }
    } else {
        /* Not a batch: the transfer is one frame, with a trailer (single-frame decision) or raw. */
        uint32_t flen = xfer_len;
        switch (rtlnet_offload_rx_frame(base, xfer_len, &flen)) {
        case RTLNET_RXA_DROP_BAD_IP:
            g_st.rx_drop_ip++;
            LINK_STATS_INC(link.drop);
            break;
        case RTLNET_RXA_DROP_BAD_L4:
            g_st.rx_drop_l4++;
            LINK_STATS_INC(link.drop);
            break;
        case RTLNET_RXA_DROP_NO_TRAILER:
            g_st.rx_no_trailer++;
            LINK_STATS_INC(link.drop);
            break;
        default:
            bat_frame_out(nif, idx, 0u, flen, copy);
            break;
        }
    }
    PROF_ADD(prof_rx_input, t0);
#if RTLNET_NETIF_ZERO_COPY_RX
    bat_unref(idx);
#else
    free_push(idx);
#endif
}

/*
 * rtlnet_netif_set_rx_batch -- switch the receive buffers between the single-frame geometry (16 x 2 KiB) and the
 * batch geometry (RTLNET_NETIF_BATCH_BUFS x RTLNET_NETIF_BATCH_BUF_BYTES).
 * Steps:
 *   1. No DMA or no batch hardware (rtlnet_offload_feat): ABSENT when asked for the batch geometry.
 *   2. Cancel the armed receive transfer (a DMA reset, so no transmit may be running) and require every buffer
 *      free: otherwise re-arm in the old geometry and report BUSY.
 *   3. Carve the memory, free every buffer, arm one.
 * Returns: RTLNET_NETIF_BATCH_OK, _BUSY, _ABSENT.
 */
int rtlnet_netif_set_rx_batch(int on)
{
    if (!g_present) {
        return RTLNET_NETIF_BATCH_ABSENT;
    }
    if ((on != 0) == (g_batch_geom != 0)) {
        return RTLNET_NETIF_BATCH_OK;
    }
    if (on && (rtlnet_offload_feat()->present & RTLNET_OFFLOAD_FEAT_BATCH) == 0u) {
        return RTLNET_NETIF_BATCH_ABSENT;
    }
    tx_reap();
    if (chan_busy(0) || g_tx_pending != NULL) {
        return RTLNET_NETIF_BATCH_BUSY;
    }
    if (g_rx_armed) {
        free_push(g_rx_armed_idx);
        g_rx_armed = 0;
        (void)dma_reset();
    }
    if (g_free_n != g_buf_n) {
        rx_arm();
        return RTLNET_NETIF_BATCH_BUSY;
    }
    g_batch_geom = on ? 1 : 0;
    g_buf_n = on ? RTLNET_NETIF_BATCH_BUFS : RTLNET_NETIF_RX_BUFS;
    g_buf_bytes = on ? RTLNET_NETIF_BATCH_BUF_BYTES : RTLNET_NETIF_BUF_BYTES;
    free_reset();
#if RTLNET_NETIF_ZERO_COPY_RX
    bat_loans_reset();
#endif
    rx_arm();
    return RTLNET_NETIF_BATCH_OK;
}

/*
 * rtlnet_netif_rx_batch_active -- the receive buffers have the batch geometry.
 * Returns: 1 or 0.
 */
int rtlnet_netif_rx_batch_active(void)
{
    return g_batch_geom;
}

/*
 * rtlnet_netif_rx_buf_bytes -- size of a receive buffer (the DMA transfer length armed) in the current geometry.
 * Returns: bytes.
 */
uint32_t rtlnet_netif_rx_buf_bytes(void)
{
    return g_buf_bytes;
}

/*
 * rtlnet_netif_poll -- receive service, called from the main loop.
 * Steps (up to RTLNET_NETIF_RX_BUDGET frames per call):
 *   0. Release the pbuf of a finished zero-copy transmit.
 *   1. No transfer armed: arm one (a free buffer is needed; none free is
 *      counted in rx_no_buf); S2MM error: count, reset the DMA, re-arm, stop.
 *   2. Transfer still running: stop.
 *   3. Completed: read the received length, arm the next buffer at once,
 *      deliver the finished one.
 * Returns: nothing. nif NULL (lwIP not running) drains and drops frames.
 */
void rtlnet_netif_poll(struct netif *nif)
{
    if (!g_present) {
        return;
    }
    tx_reap();
    uint32_t t_poll = PROF_NOW();
    unsigned n;
    for (n = 0; n < RTLNET_NETIF_RX_BUDGET; n++) {
        uint32_t sr;
        uint32_t len;
        unsigned done;
        if (!g_rx_armed) {
            rx_arm();
            if (!g_rx_armed) {
                if (g_free_n == 0u) {
                    g_st.rx_no_buf++;
                }
                return;
            }
        }
        sr = XAxiDma_ReadReg(g_dma.RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET);
        if (sr & XAXIDMA_ERR_ALL_MASK) {
            g_st.rx_errors++;
            (void)dma_reset();
            rx_arm();
            return;
        }
        if (chan_busy(1)) {
            break;
        }
        len = XAxiDma_ReadReg(g_dma.RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_BUFFLEN_OFFSET);
        done = g_rx_armed_idx;
        g_rx_armed = 0;
        rx_arm();
        if (g_batch_geom) {
            batch_deliver(nif, done, len);
        } else {
            rx_deliver(nif, done, len);
        }
    }
    if (n != 0u) {
        PROF_ADD(prof_busy, t_poll);
        if (n >= RTLNET_NETIF_RX_BUDGET) {
            g_st.rx_budget_hits++;
        }
    }
}

/*
 * rtlnet_netif_stats -- frame counters of the netif.
 * Returns: pointer to the counters.
 */
const rtlnet_netif_stats_t *rtlnet_netif_stats(void)
{
    return &g_st;
}

/*
 * rtlnet_netif_clear_stats -- zero the counters.
 * Returns: nothing.
 */
void rtlnet_netif_clear_stats(void)
{
    memset(&g_st, 0, sizeof(g_st));
    g_st.prof_clear = PROF_NOW();
}

/*
 * rtlnet_netif_dma_sr -- raw DMA channel status register.
 * Returns: S2MM (rx != 0) or MM2S status, 0 when the DMA is absent.
 */
uint32_t rtlnet_netif_dma_sr(int rx)
{
    if (!g_present) {
        return 0u;
    }
    return XAxiDma_ReadReg(g_dma.RegBase, (rx ? XAXIDMA_RX_OFFSET : XAXIDMA_TX_OFFSET) + XAXIDMA_SR_OFFSET);
}
