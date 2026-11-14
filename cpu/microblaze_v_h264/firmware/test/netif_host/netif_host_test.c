/*
 * netif_host_test.c -- desktop test of the DMA netif (src/lwip/rtlnet_lwip_netif.c) on the real lwIP core
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_lwip_netif.c, rtlnet_offload.c and the core drivers unmodified
 * against a mock of the Xilinx AXI DMA driver (xaxidma.h in this folder) and a register
 * model of the protocol wrapper and the checksum offload core, with lwIP 2.2.0 from the
 * install as the stack. Checks:
 *   arp          an ARP request received through the DMA is answered by lwIP through
 *                the netif (the reply is a single pbuf in lwIP's heap)
 *   tx           a single-pbuf frame in the heap is sent in place with zero-copy transmit
 *                (copied without it), a chained pbuf and a pool pbuf are copied; the pbuf
 *                of an in-place transfer stays referenced until the transfer is done
 *   rx hold      zero-copy receive: all buffers on loan to lwIP stop the S2MM channel
 *                (counted), freeing one re-arms it; without zero-copy receive every frame
 *                is copied into a pool pbuf and the pool runs dry cleanly
 *   trailer      with rx_csum on: frames are delivered with the length of the trailer,
 *                bad L4 / bad IPv4 / missing trailer are dropped and their buffers come
 *                back, the lwIP CHECK flags follow the first trailer
 * One build line decides the zero-copy options (-DRTLNET_NETIF_ZERO_COPY_RX/_TX).
 * Ends with exactly one line: NETIF_HOST: PASS checks=<n> or FAIL.
 */
#include <stdio.h>    /* printf */
#include <stdlib.h>   /* exit */
#include <string.h>   /* memset, memcpy, memcmp */

#include "lwip/etharp.h"
#include "lwip/init.h"
#include "lwip/ip4_addr.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/stats.h"
#include "netif/ethernet.h"

#include "rtlnet_eth_protocol.h"
#include "rtlnet_lwip_netif.h"
#include "rtlnet_mmio.h"
#include "rtlnet_offload.h"
#include "rtlnet_platform.h"
#include "rtlnet_tcp_offload.h"
#include "xaxidma.h"

#define HELD_MAX   64u

static unsigned g_checks;
static unsigned g_fails;

/* ---------------------------------------------------------------------------
 * Check bookkeeping
 * ------------------------------------------------------------------------- */
static void check(int ok, const char *msg)
{
    g_checks++;
    if (!ok) {
        g_fails++;
        printf("CHECK FAILED: %s\n", msg);
    }
}

/* ---------------------------------------------------------------------------
 * Time
 * ------------------------------------------------------------------------- */
u32_t sys_now(void)
{
    static u32_t t;
    return t++;
}

void plat_console_write(const char *s, size_t n)
{
    (void)fwrite(s, 1u, n, stdout);
}

uint32_t plat_ticks(void)
{
    static uint32_t t;
    t += 100u;
    return t;
}

/* ---------------------------------------------------------------------------
 * DMA mock
 * ------------------------------------------------------------------------- */
static int       g_rx_armed;
static uint8_t  *g_rx_buf;
static uint32_t  g_rx_cap;
static int       g_rx_done;
static uint32_t  g_rx_len;
static uint32_t  g_tx_busy_reads;
static unsigned  g_tx_count;
static uint8_t   g_tx_cap[4096];
static uint32_t  g_tx_cap_len;
static uintptr_t g_tx_cap_addr;
static unsigned  g_resets;
static XAxiDma_Config g_cfg;

XAxiDma_Config *XAxiDma_LookupConfig(uintptr_t base) { (void)base; return &g_cfg; }
int  XAxiDma_CfgInitialize(XAxiDma *dma, XAxiDma_Config *cfg) { (void)cfg; dma->RegBase = 0x1000u; return XST_SUCCESS; }
int  XAxiDma_HasSg(XAxiDma *dma) { (void)dma; return 0; }
void XAxiDma_Reset(XAxiDma *dma) { (void)dma; g_resets++; g_rx_armed = 0; g_rx_done = 0; }
int  XAxiDma_ResetIsDone(XAxiDma *dma) { (void)dma; return 1; }
void XAxiDma_IntrDisable(XAxiDma *dma, uint32_t mask, int dir) { (void)dma; (void)mask; (void)dir; }

int XAxiDma_SimpleTransfer(XAxiDma *dma, UINTPTR buf, uint32_t len, int dir)
{
    (void)dma;
    if (dir == XAXIDMA_DEVICE_TO_DMA) {
        g_rx_armed = 1;
        g_rx_done = 0;
        g_rx_buf = (uint8_t *)buf;
        g_rx_cap = len;
    } else {
        g_tx_count++;
        g_tx_cap_addr = buf;
        g_tx_cap_len = len;
        memcpy(g_tx_cap, (const void *)buf, (len < sizeof(g_tx_cap)) ? len : sizeof(g_tx_cap));
        g_tx_busy_reads = 3u;
    }
    return XST_SUCCESS;
}

uint32_t XAxiDma_ReadReg_mock(uintptr_t base, uint32_t offset)
{
    (void)base;
    if (offset == XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET) {
        return (g_rx_armed && !g_rx_done) ? 0u : XAXIDMA_IDLE_MASK;
    }
    if (offset == XAXIDMA_TX_OFFSET + XAXIDMA_SR_OFFSET) {
        if (g_tx_busy_reads > 0u) {
            g_tx_busy_reads--;
            return 0u;
        }
        return XAXIDMA_IDLE_MASK;
    }
    if (offset == XAXIDMA_RX_OFFSET + XAXIDMA_BUFFLEN_OFFSET) {
        return g_rx_len;
    }
    return 0u;
}

/* A frame arrives on S2MM: fills the armed buffer. Returns 1 when a transfer was armed. */
static int mock_rx_inject(const uint8_t *data, uint32_t n)
{
    if (!g_rx_armed || g_rx_done || n > g_rx_cap) {
        return 0;
    }
    memcpy(g_rx_buf, data, n);
    g_rx_len = n;
    g_rx_done = 1;
    return 1;
}

/* ---------------------------------------------------------------------------
 * Register model: protocol wrapper (CAPS, CPU_CAPS) and the checksum offload window
 * ------------------------------------------------------------------------- */
static uint32_t g_txo_ctrl;

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    if (addr >= RTLNET_PLAT_TXO_BASE && addr < RTLNET_PLAT_TXO_BASE + 0x1000u) {
        switch ((uint32_t)(addr - RTLNET_PLAT_TXO_BASE)) {
        case RTLNET_TXO_REG_ID:      return RTLNET_TXO_ID_VALUE;
        case RTLNET_TXO_REG_VERSION: return RTLNET_TXO_VERSION_VALUE;
        case RTLNET_TXO_REG_CAPS:    return 0x05EE083Fu;
        case RTLNET_TXO_REG_CTRL:    return g_txo_ctrl;
        case RTLNET_TXO_REG_STATUS:  return 3u;
        case RTLNET_TXO_REG_LATENCY: return 18u | (17u << 8);
        default:                     return 0u;
        }
    }
    if (addr == RTLNET_PLAT_PROT_BASE + RTLNET_PROTO_REG_ID)      return RTLNET_PROTO_ID_VALUE;
    if (addr == RTLNET_PLAT_PROT_BASE + RTLNET_PROTO_REG_VERSION) return RTLNET_PROTO_VERSION_VALUE;
    if (addr == RTLNET_PLAT_PROT_BASE + RTLNET_PROTO_REG_CAPS)    return RTLNET_PROTO_CAPS_CPU_PATH_PRESENT;
    if (addr == RTLNET_PLAT_PROT_BASE + RTLNET_PROTO_REG_CPU_CAPS) return 0x00060810u;
    return 0u;
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    if (addr == RTLNET_PLAT_TXO_BASE + RTLNET_TXO_REG_CTRL) {
        g_txo_ctrl = value & RTLNET_TXO_CTRL_MASK;
    }
}

/* ---------------------------------------------------------------------------
 * lwIP checksum flag hooks onto the test netif
 * ------------------------------------------------------------------------- */
static struct netif g_nif;

void rtlnet_lwip_set_checksum_ctrl(uint32_t flags)
{
    NETIF_SET_CHECKSUM_CTRL(&g_nif, flags);
}

uint32_t rtlnet_lwip_get_checksum_ctrl(void)
{
    return g_nif.chksum_flags;
}

/* ---------------------------------------------------------------------------
 * A receive hook that keeps the pbufs (to hold buffers on loan)
 * ------------------------------------------------------------------------- */
static struct pbuf *g_held[HELD_MAX];
static unsigned     g_held_n;

static err_t hold_input(struct pbuf *p, struct netif *nif)
{
    (void)nif;
    if (g_held_n < HELD_MAX) {
        g_held[g_held_n++] = p;
        return ERR_OK;
    }
    return ERR_MEM;
}

static void free_held(void)
{
    for (unsigned i = 0; i < g_held_n; i++) {
        pbuf_free(g_held[i]);
        g_held[i] = NULL;
    }
    g_held_n = 0u;
}

/* Poll until the netif has nothing left to do for the test. */
static void poll_n(unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        rtlnet_netif_poll(&g_nif);
    }
}

/* Inject one frame and let the netif take it. Returns 1 when the DMA was armed. */
static int inject(const uint8_t *data, uint32_t n)
{
    int ok;
    poll_n(1);
    ok = mock_rx_inject(data, n);
    poll_n(1);
    return ok;
}

/* A frame of n bytes whose first byte is tag and the rest a pattern. */
static void make_frame(uint8_t *f, uint32_t n, uint8_t tag)
{
    for (uint32_t i = 0; i < n; i++) {
        f[i] = (uint8_t)(i * 3u + 1u);
    }
    f[0] = tag;
}

/* A DMA transfer of a frame: padded to 8 bytes with the receive trailer. */
static uint32_t make_trailer_transfer(uint8_t *buf, uint32_t len, uint16_t flags, uint16_t sum, uint8_t tag)
{
    uint32_t n = (len + 7u) & ~7u;
    memset(buf, 0, 2048u);
    make_frame(buf, len, tag);
    buf[n + 0u] = (uint8_t)len;
    buf[n + 1u] = (uint8_t)(len >> 8);
    buf[n + 2u] = (uint8_t)sum;
    buf[n + 3u] = (uint8_t)(sum >> 8);
    buf[n + 4u] = (uint8_t)flags;
    buf[n + 5u] = (uint8_t)(flags >> 8);
    buf[n + 6u] = 34u;
    buf[n + 7u] = 0xA5u;
    return n + 8u;
}

/* ---------------------------------------------------------------------------
 * Tests
 * ------------------------------------------------------------------------- */
static u32_t g_mem_base;

static void test_arp(void)
{
    uint8_t f[60];
    const rtlnet_netif_stats_t *st = rtlnet_netif_stats();
    unsigned tx0 = g_tx_count;
    uint32_t zc0 = st->tx_zero_copy;
    uint32_t cp0 = st->tx_copied;

    memset(f, 0, sizeof(f));
    memset(&f[0], 0xFF, 6);
    f[6] = 0x02; f[7] = 0x00; f[8] = 0x00; f[9] = 0x00; f[10] = 0x00; f[11] = 0x32;
    f[12] = 0x08; f[13] = 0x06;
    f[14] = 0x00; f[15] = 0x01; f[16] = 0x08; f[17] = 0x00; f[18] = 6; f[19] = 4; f[20] = 0x00; f[21] = 0x01;
    memcpy(&f[22], &f[6], 6);
    f[28] = 192; f[29] = 169; f[30] = 1; f[31] = 50;
    f[38] = 192; f[39] = 169; f[40] = 1; f[41] = 220;
    check(inject(f, sizeof(f)) == 1, "arp: request injected");
    poll_n(4);
    check(g_tx_count == tx0 + 1u, "arp: lwIP answered through the netif");
    check(g_tx_cap_len == 42u && g_tx_cap[12] == 0x08 && g_tx_cap[13] == 0x06 && g_tx_cap[21] == 0x02, "arp: reply frame");
    check(memcmp(&g_tx_cap[0], &f[6], 6) == 0 && memcmp(&g_tx_cap[38], &f[28], 4) == 0, "arp: reply addressed to the requester");
    check(g_tx_cap[28] == 192 && g_tx_cap[31] == 220, "arp: reply carries the netif address");
#if RTLNET_NETIF_ZERO_COPY_TX
    check(st->tx_zero_copy == zc0 + 1u && st->tx_copied == cp0, "arp: single heap pbuf sent in place");
    check(g_tx_cap_addr >= (uintptr_t)rtlnet_lwip_heap && g_tx_cap_addr < (uintptr_t)rtlnet_lwip_heap + RTLNET_LWIP_HEAP_BYTES,
          "arp: the DMA read the heap");
#else
    check(st->tx_zero_copy == zc0 && st->tx_copied == cp0 + 1u, "arp: copied without zero-copy transmit");
#endif
    check(lwip_stats.mem.used == g_mem_base, "arp: the reply pbuf is freed after the transfer");
}

static void test_tx(void)
{
    const rtlnet_netif_stats_t *st = rtlnet_netif_stats();
    struct pbuf *a;
    struct pbuf *b;
    struct pbuf *p;
    uint32_t zc0;
    uint32_t cp0;
    uint8_t exp[128];

    /* Single pbuf in the heap. */
    zc0 = st->tx_zero_copy;
    cp0 = st->tx_copied;
    p = pbuf_alloc(PBUF_RAW, 100, PBUF_RAM);
    check(p != NULL, "tx: heap pbuf");
    for (unsigned i = 0; i < 100u; i++) {
        ((uint8_t *)p->payload)[i] = (uint8_t)(i + 7u);
    }
    check(g_nif.linkoutput(&g_nif, p) == ERR_OK, "tx: single heap pbuf accepted");
    check(g_tx_cap_len == 100u && g_tx_cap[0] == 7u && g_tx_cap[99] == 106u, "tx: single pbuf bytes");
#if RTLNET_NETIF_ZERO_COPY_TX
    check(st->tx_zero_copy == zc0 + 1u && g_tx_cap_addr == (uintptr_t)p->payload, "tx: sent in place");
    pbuf_free(p);
    check(lwip_stats.mem.used > g_mem_base, "tx: the pbuf stays referenced while the transfer runs");
    poll_n(6);
    check(lwip_stats.mem.used == g_mem_base, "tx: released when the transfer is done");
#else
    check(st->tx_copied == cp0 + 1u && g_tx_cap_addr != (uintptr_t)p->payload, "tx: copied");
    pbuf_free(p);
    check(lwip_stats.mem.used == g_mem_base, "tx: pbuf free at once");
#endif

    /* Chained pbuf: copied. */
    zc0 = st->tx_zero_copy;
    cp0 = st->tx_copied;
    a = pbuf_alloc(PBUF_RAW, 40, PBUF_RAM);
    b = pbuf_alloc(PBUF_RAW, 30, PBUF_RAM);
    for (unsigned i = 0; i < 40u; i++) {
        ((uint8_t *)a->payload)[i] = (uint8_t)i;
        exp[i] = (uint8_t)i;
    }
    for (unsigned i = 0; i < 30u; i++) {
        ((uint8_t *)b->payload)[i] = (uint8_t)(0x80u + i);
        exp[40u + i] = (uint8_t)(0x80u + i);
    }
    pbuf_cat(a, b);
    check(g_nif.linkoutput(&g_nif, a) == ERR_OK && g_tx_cap_len == 70u && memcmp(g_tx_cap, exp, 70u) == 0, "tx: chained pbuf copied whole");
    check(st->tx_copied == cp0 + 1u && st->tx_zero_copy == zc0, "tx: chained pbuf counted as a copy");
    pbuf_free(a);

    /* Pool pbuf (not in the heap): copied. */
    zc0 = st->tx_zero_copy;
    cp0 = st->tx_copied;
    p = pbuf_alloc(PBUF_RAW, 60, PBUF_POOL);
    check(p != NULL, "tx: pool pbuf");
    memset(p->payload, 0x5A, 60);
    check(g_nif.linkoutput(&g_nif, p) == ERR_OK && g_tx_cap_len == 60u && g_tx_cap[0] == 0x5A, "tx: pool pbuf sent");
    check(st->tx_copied == cp0 + 1u && st->tx_zero_copy == zc0, "tx: pool pbuf copied");
    pbuf_free(p);
    poll_n(6);
    check(lwip_stats.mem.used == g_mem_base, "tx: heap back at its start value");
}

static void test_rx_hold(void)
{
    uint8_t f[100];
    const rtlnet_netif_stats_t *st = rtlnet_netif_stats();
    unsigned i;
    uint32_t nb0 = st->rx_no_buf;
    uint32_t np0 = st->rx_no_pbuf;

    g_nif.input = hold_input;
    g_held_n = 0u;
#if RTLNET_NETIF_ZERO_COPY_RX
    (void)np0;
    for (i = 0; i < RTLNET_NETIF_RX_BUFS; i++) {
        make_frame(f, 64u, (uint8_t)(0x40u + i));
        check(inject(f, 64u) == 1, "rx hold: frame accepted");
    }
    check(g_held_n == RTLNET_NETIF_RX_BUFS, "rx hold: every buffer on loan to lwIP");
    check(g_rx_armed == 0 || g_rx_done, "rx hold: no transfer armed with no free buffer");
    make_frame(f, 64u, 0x77u);
    check(inject(f, 64u) == 0, "rx hold: S2MM idle, the next frame waits in the hardware FIFO");
    check(st->rx_no_buf > nb0, "rx hold: the stall is counted");
    check((g_held[3]->flags & PBUF_FLAG_IS_CUSTOM) != 0u && g_held[3]->tot_len == 64u && g_held[3]->type_internal == PBUF_REF,
          "rx hold: custom PBUF_REF pbuf of the frame length");
    check(((uint8_t *)g_held[3]->payload)[0] == 0x43u && ((uint8_t *)g_held[9]->payload)[0] == 0x49u,
          "rx hold: each pbuf is its own buffer");
    pbuf_free(g_held[3]);
    g_held[3] = NULL;
    poll_n(2);
    make_frame(f, 64u, 0x78u);
    check(inject(f, 64u) == 1, "rx hold: freeing a pbuf re-arms the channel");
    check(g_held_n == RTLNET_NETIF_RX_BUFS + 1u && ((uint8_t *)g_held[g_held_n - 1u]->payload)[0] == 0x78u,
          "rx hold: the new frame arrives in the freed buffer");
    for (i = 0; i < g_held_n; i++) {
        if (g_held[i] != NULL) {
            pbuf_free(g_held[i]);
        }
    }
    g_held_n = 0u;
    poll_n(2);
    for (i = 0; i < 3u * RTLNET_NETIF_RX_BUFS; i++) {
        make_frame(f, 70u, (uint8_t)i);
        if (!inject(f, 70u)) {
            break;
        }
        pbuf_free(g_held[--g_held_n]);
    }
    check(i == 3u * RTLNET_NETIF_RX_BUFS, "rx hold: buffers cycle through the free list without leaking");
#else
    for (i = 0; i < PBUF_POOL_SIZE + 6u; i++) {
        make_frame(f, 64u, (uint8_t)i);
        check(inject(f, 64u) == 1, "rx copy: the DMA never stalls");
    }
    check(g_held_n == PBUF_POOL_SIZE && st->rx_no_pbuf - np0 >= 6u, "rx copy: the pbuf pool runs dry, drops counted");
    check(((uint8_t *)g_held[5]->payload)[0] == 5u && g_held[5]->tot_len == 64u, "rx copy: frame content");
    free_held();
    check(lwip_stats.memp[MEMP_PBUF_POOL]->used == 0u, "rx copy: pool free again");
    (void)nb0;
#endif
    free_held();
    check(lwip_stats.memp[MEMP_PBUF_POOL]->used == 0u, "rx: no pool pbuf in use");
}

static void test_trailer(void)
{
    uint8_t buf[2048];
    uint32_t xfer;
    const rtlnet_netif_stats_t *st = rtlnet_netif_stats();
    unsigned i;
    uint32_t drops;

    g_nif.input = hold_input;
    g_held_n = 0u;
    rtlnet_features_rediscover();
    check(rtlnet_features()->tx_present && rtlnet_features()->rx_present, "trailer: offload discovered");
    check(rtlnet_offload_apply(RTLNET_OFFLOAD_ALL) == RTLNET_OFFLOAD_OK, "trailer: apply(all)");
    check((g_nif.chksum_flags & (NETIF_CHECKSUM_GEN_IP | NETIF_CHECKSUM_GEN_TCP | NETIF_CHECKSUM_GEN_UDP)) == 0u &&
          (g_nif.chksum_flags & NETIF_CHECKSUM_CHECK_TCP) != 0u, "trailer: GEN flags off, CHECK flags still on while arming");

    make_frame(buf, 64u, 0x11u);
    check(inject(buf, 64u) == 1 && g_held_n == 1u && g_held[0]->tot_len == 64u, "trailer: arming, a frame without trailer is whole");
    xfer = make_trailer_transfer(buf, 61u, 0x00E3u, 0xFFFFu, 0x22u);
    check(xfer == 72u && inject(buf, xfer) == 1 && g_held_n == 2u, "trailer: verified frame delivered");
    check(g_held[1]->tot_len == 61u && ((uint8_t *)g_held[1]->payload)[0] == 0x22u && ((uint8_t *)g_held[1]->payload)[60] == (uint8_t)(60u * 3u + 1u),
          "trailer: pbuf is the frame, without padding and trailer");
    check((g_nif.chksum_flags & (NETIF_CHECKSUM_CHECK_IP | NETIF_CHECKSUM_CHECK_TCP | NETIF_CHECKSUM_CHECK_UDP)) == 0u &&
          (g_nif.chksum_flags & NETIF_CHECKSUM_CHECK_ICMP) != 0u, "trailer: the first trailer clears the CHECK flags (ICMP stays)");
    free_held();

    /* Dropped frames give their buffers back: far more drops than buffers. */
    drops = st->rx_drop_l4;
    for (i = 0; i < 4u * RTLNET_NETIF_RX_BUFS; i++) {
        xfer = make_trailer_transfer(buf, 100u + i, 0x00A3u, 0x1234u, 0x33u);
        if (!inject(buf, xfer)) {
            break;
        }
    }
    check(i == 4u * RTLNET_NETIF_RX_BUFS && st->rx_drop_l4 - drops == i && g_held_n == 0u, "trailer: bad L4 checksum dropped, buffer returned");
    drops = st->rx_drop_ip;
    xfer = make_trailer_transfer(buf, 90u, 0x0001u, 0u, 0x44u);
    check(inject(buf, xfer) == 1 && st->rx_drop_ip == drops + 1u && g_held_n == 0u, "trailer: bad IPv4 header dropped");
    drops = st->rx_no_trailer;
    make_frame(buf, 64u, 0x55u);
    check(inject(buf, 64u) == 1 && st->rx_no_trailer == drops + 1u && g_held_n == 0u, "trailer: rx_csum on, no trailer: dropped");
    xfer = make_trailer_transfer(buf, 77u, 0x0000u, 0u, 0x66u);
    check(inject(buf, xfer) == 1 && g_held_n == 1u && g_held[0]->tot_len == 77u, "trailer: unverified frame passes");
    free_held();

    /* Receive off: CHECK flags back first, trailers parsed until the first raw frame. */
    check(rtlnet_offload_apply(RTLNET_OFFLOAD_TX_IP | RTLNET_OFFLOAD_TX_L4) == RTLNET_OFFLOAD_OK, "trailer: apply(tx only)");
    check((g_nif.chksum_flags & NETIF_CHECKSUM_CHECK_IP) != 0u, "trailer: CHECK flags set again");
    xfer = make_trailer_transfer(buf, 80u, 0x0000u, 0u, 0x77u);
    check(inject(buf, xfer) == 1 && g_held_n == 1u && g_held[0]->tot_len == 80u, "trailer: draining, a late trailer frame is parsed");
    make_frame(buf, 120u, 0x88u);
    check(inject(buf, 120u) == 1 && g_held_n == 2u && g_held[1]->tot_len == 120u &&
          rtlnet_offload_state()->rx_state == RTLNET_RX_TRAILER_OFF, "trailer: the first raw frame ends the draining");
    free_held();
    check(lwip_stats.memp[MEMP_PBUF_POOL]->used == 0u, "trailer: no pbuf leaked");
}

int main(void)
{
    ip4_addr_t ip;
    ip4_addr_t mask;
    ip4_addr_t gw;
    static const uint8_t mac[6] = { 0x02, 0x49, 0x4B, 0x52, 0x4E, 0x01 };

    printf("netif host test: zero-copy RX %d, zero-copy TX %d, %u receive buffers\n", RTLNET_NETIF_ZERO_COPY_RX,
           RTLNET_NETIF_ZERO_COPY_TX, (unsigned)RTLNET_NETIF_RX_BUFS);
    lwip_init();
    IP4_ADDR(&ip, 192, 169, 1, 220);
    IP4_ADDR(&mask, 255, 255, 255, 0);
    IP4_ADDR(&gw, 192, 169, 1, 1);
    rtlnet_netif_set_hwaddr(mac);
    check(rtlnet_netif_hw_init() == 0 && rtlnet_netif_hw_present() == 1, "hw_init");
    check(netif_add(&g_nif, &ip, &mask, &gw, NULL, rtlnet_netif_init, ethernet_input) != NULL, "netif_add");
    netif_set_default(&g_nif);
    netif_set_up(&g_nif);
    netif_set_link_up(&g_nif);
    poll_n(8);                          /* the gratuitous ARP of netif_set_up is sent and released */
    g_mem_base = lwip_stats.mem.used;

    test_arp();
    test_tx();
    test_rx_hold();
    g_nif.input = ethernet_input;
    test_trailer();

    if (g_fails == 0u) {
        printf("NETIF_HOST: PASS checks=%u\n", g_checks);
        return 0;
    }
    printf("NETIF_HOST: FAIL %u check(s) failed of %u\n", g_fails, g_checks);
    return 1;
}
