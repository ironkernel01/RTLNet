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

#include "rtlnet_platform.h"

#include "lwip/etharp.h"
#include "lwip/pbuf.h"
#include "lwip/stats.h"
#include "netif/ethernet.h"

#include "xaxidma.h"   /* XAxiDma */
#include "xstatus.h"   /* XST_SUCCESS */

/* DMA buffers: the only firmware data in the AXI BRAM (section .axi_bram,
 * NOLOAD, placed at RTLNET_CPU_AXI_BRAM_BASE by the linker script). */
#define NETIF_AXI_BRAM __attribute__((section(".axi_bram"), aligned(RTLNET_NETIF_BUF_ALIGN)))

static uint8_t g_rx_buf[RTLNET_NETIF_RX_BUFS][RTLNET_NETIF_BUF_BYTES] NETIF_AXI_BRAM;
static uint8_t g_tx_buf[RTLNET_NETIF_TX_BUFS][RTLNET_NETIF_BUF_BYTES] NETIF_AXI_BRAM;

static XAxiDma              g_dma;
static int                  g_present;        /* DMA configured */
static int                  g_rx_armed;       /* an S2MM transfer is outstanding into g_rx_buf[g_rx_idx] */
static unsigned             g_rx_idx;
static unsigned             g_tx_idx;
static uint8_t              g_hwaddr[6];
static rtlnet_netif_stats_t g_st;

/*
 * dma_reset -- reset both channels and wait (bounded) for completion.
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
            g_rx_armed = 0;
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

/*
 * rx_arm -- start an S2MM simple transfer into the current ring entry.
 * Returns: nothing; g_rx_armed tells whether the transfer started.
 */
static void rx_arm(void)
{
    g_rx_armed = (XAxiDma_SimpleTransfer(&g_dma, (UINTPTR)g_rx_buf[g_rx_idx], RTLNET_NETIF_BUF_BYTES,
                                         XAXIDMA_DEVICE_TO_DMA) == XST_SUCCESS) ? 1 : 0;
}

/*
 * rtlnet_netif_hw_init -- find and configure the AXI DMA, arm the receive ring.
 * Steps:
 *   1. XAxiDma_LookupConfig at RTLNET_PLAT_DMA_BASE; refuse a scatter-gather
 *      build (the block design is simple mode).
 *   2. XAxiDma_CfgInitialize, channel reset, interrupts off.
 *   3. Arm the first receive buffer.
 * Returns: 0 configured, -1 no DMA or a failed initialization.
 */
int rtlnet_netif_hw_init(void)
{
    XAxiDma_Config *cfg;
    g_present = 0;
    g_rx_idx = 0u;
    g_tx_idx = 0u;
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
 * netif_linkoutput -- send one frame: copy the chain, start MM2S.
 * Steps:
 *   1. Reject frames longer than a buffer.
 *   2. Copy the pbuf chain into the free TX buffer (axi_put_chain: word writes only).
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
    (void)nif;
    if (!g_present) {
        return ERR_IF;
    }
    if (len > RTLNET_NETIF_BUF_BYTES) {
        g_st.tx_too_long++;
        return ERR_IF;
    }
    buf = g_tx_buf[g_tx_idx];
    t0 = PROF_NOW();
    axi_put_chain((volatile word_t *)(void *)buf, p);
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
    g_tx_idx = (g_tx_idx + 1u) % RTLNET_NETIF_TX_BUFS;
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

/*
 * rx_deliver -- copy one received frame into a pbuf and give it to lwIP.
 * Returns: nothing; drops are counted.
 */
static void rx_deliver(struct netif *nif, const uint8_t *buf, uint32_t len)
{
    struct pbuf *p;
    uint32_t t0;
    uint32_t t1;
    if (len < RTLNET_NETIF_MIN_FRAME || len > RTLNET_NETIF_BUF_BYTES) {
        g_st.rx_runts++;
        return;
    }
    if (nif == NULL) {
        g_st.rx_unbound++;
        return;
    }
    t0 = PROF_NOW();
    p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
    if (p == NULL) {
        g_st.rx_no_pbuf++;
        LINK_STATS_INC(link.memerr);
        return;
    }
    if (p->next == NULL && ((uintptr_t)p->payload & 3u) == 0u && (len + 3u) <= PBUF_POOL_BUFSIZE) {
        axi_get_words((word_t *)p->payload, (const volatile word_t *)(const void *)buf, len);
    } else {
        (void)pbuf_take(p, buf, (u16_t)len);
    }
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

/*
 * rtlnet_netif_poll -- receive service, called from the main loop.
 * Steps (up to RTLNET_NETIF_RX_BUDGET frames per call):
 *   1. S2MM error: count, reset the DMA, re-arm, stop.
 *   2. Transfer still running: stop.
 *   3. Completed: read the received length, arm the next ring entry at
 *      once, deliver the finished buffer.
 * Returns: nothing. nif NULL (lwIP not running) drains and drops frames.
 */
void rtlnet_netif_poll(struct netif *nif)
{
    if (!g_present) {
        return;
    }
    uint32_t t_poll = PROF_NOW();
    unsigned n;
    for (n = 0; n < RTLNET_NETIF_RX_BUDGET; n++) {
        uint32_t sr;
        uint32_t len;
        unsigned done;
        if (!g_rx_armed) {
            rx_arm();
            if (!g_rx_armed) {
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
        done = g_rx_idx;
        g_rx_idx = (g_rx_idx + 1u) % RTLNET_NETIF_RX_BUFS;
        rx_arm();
        rx_deliver(nif, g_rx_buf[done], len);
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
