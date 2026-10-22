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
 *   2. Copy the pbuf chain into the free TX buffer.
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
    (void)pbuf_copy_partial(p, buf, len, 0u);
    t0 = plat_ticks();
    while (chan_busy(0)) {
        if ((plat_ticks() - t0) >= RTLNET_NETIF_TX_WAIT_US * RTLNET_PLAT_TICKS_PER_US) {
            g_st.tx_timeouts++;
            LINK_STATS_INC(link.drop);
            return ERR_IF;
        }
    }
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
    if (len < RTLNET_NETIF_MIN_FRAME || len > RTLNET_NETIF_BUF_BYTES) {
        g_st.rx_runts++;
        return;
    }
    if (nif == NULL) {
        g_st.rx_unbound++;
        return;
    }
    p = pbuf_alloc(PBUF_RAW, (u16_t)len, PBUF_POOL);
    if (p == NULL) {
        g_st.rx_no_pbuf++;
        LINK_STATS_INC(link.memerr);
        return;
    }
    (void)pbuf_take(p, buf, (u16_t)len);
    g_st.rx_frames++;
    g_st.rx_bytes += len;
    LINK_STATS_INC(link.recv);
    if (nif->input(p, nif) != ERR_OK) {
        pbuf_free(p);
    }
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
    for (unsigned n = 0; n < RTLNET_NETIF_RX_BUDGET; n++) {
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
            return;
        }
        len = XAxiDma_ReadReg(g_dma.RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_BUFFLEN_OFFSET);
        done = g_rx_idx;
        g_rx_idx = (g_rx_idx + 1u) % RTLNET_NETIF_RX_BUFS;
        rx_arm();
        rx_deliver(nif, g_rx_buf[done], len);
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
