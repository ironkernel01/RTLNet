/*
 * rtlnet_lwip.c -- lwIP on RTLNet: InitLWIP(), main-loop service, status
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_lwip.h for the contract. Context: main loop only.
 */
#include "rtlnet_lwip.h"

#include <string.h>   /* memcmp, memcpy, memset */

#include "rtlnet_eth_protocol.h"
#include "rtlnet_lwip_netif.h"
#include "rtlnet_offload.h"
#include "rtlnet_platform.h"
#include "rtlnet_tcp_echo.h"
#include "rtlnet_tcp_iperf.h"

#include "lwip/etharp.h"
#include "lwip/init.h"
#include "lwip/ip4_addr.h"
#include "lwip/memp.h"
#include "lwip/netif.h"
#include "lwip/stats.h"
#include "lwip/timeouts.h"
#include "netif/ethernet.h"

/* The offload module mirrors the lwIP checksum flag values to stay free of lwIP headers. */
_Static_assert(RTLNET_CS_GEN_IP == NETIF_CHECKSUM_GEN_IP, "GEN_IP value");
_Static_assert(RTLNET_CS_GEN_UDP == NETIF_CHECKSUM_GEN_UDP, "GEN_UDP value");
_Static_assert(RTLNET_CS_GEN_TCP == NETIF_CHECKSUM_GEN_TCP, "GEN_TCP value");
_Static_assert(RTLNET_CS_GEN_ICMP == NETIF_CHECKSUM_GEN_ICMP, "GEN_ICMP value");
_Static_assert(RTLNET_CS_CHECK_IP == NETIF_CHECKSUM_CHECK_IP, "CHECK_IP value");
_Static_assert(RTLNET_CS_CHECK_UDP == NETIF_CHECKSUM_CHECK_UDP, "CHECK_UDP value");
_Static_assert(RTLNET_CS_CHECK_TCP == NETIF_CHECKSUM_CHECK_TCP, "CHECK_TCP value");
_Static_assert(RTLNET_CS_CHECK_ICMP == NETIF_CHECKSUM_CHECK_ICMP, "CHECK_ICMP value");

static struct netif g_netif;
static uint32_t     g_cs_flags = RTLNET_CS_ENABLE_ALL;   /* checksum flags requested before the netif exists */
static int          g_netif_added;                      /* netif_add succeeded (flags can be set on it) */
static int          g_running;
static int          g_link_down;      /* 0 = up (.bss, so a soft restart starts with link up) */
static rtlnet_lwip_status_t g_stat;

/*
 * sys_now -- lwIP time base (NO_SYS): the platform millisecond tick.
 * Returns: milliseconds since start-up.
 */
u32_t sys_now(void)
{
    return plat_uptime_ms();
}

/*
 * rtlnet_lwip_set_checksum_ctrl -- set the netif's checksum flags
 * (NETIF_CHECKSUM_GEN_* / _CHECK_*). Called by rtlnet_offload_apply only.
 * Returns: nothing; remembered for the netif added later when lwIP is not running.
 */
void rtlnet_lwip_set_checksum_ctrl(uint32_t flags)
{
    g_cs_flags = flags;
    if (g_netif_added) {
        NETIF_SET_CHECKSUM_CTRL(&g_netif, flags);
    }
}

/*
 * rtlnet_lwip_get_checksum_ctrl -- the netif's checksum flags as lwIP holds them.
 * Returns: the flags (the requested ones while lwIP is not running).
 */
uint32_t rtlnet_lwip_get_checksum_ctrl(void)
{
    return g_netif_added ? (uint32_t)g_netif.chksum_flags : g_cs_flags;
}

/*
 * ip4_from_host -- lwIP address from a host-order value (first octet in [31:24]).
 * Returns: nothing.
 */
static void ip4_from_host(ip4_addr_t *a, uint32_t v)
{
    IP4_ADDR(a, (u8_t)(v >> 24), (u8_t)(v >> 16), (u8_t)(v >> 8), (u8_t)v);
}

/*
 * ip4_to_host -- host-order value of an lwIP address.
 * Returns: the address, first octet in [31:24].
 */
static uint32_t ip4_to_host(const ip4_addr_t *a)
{
    return ((uint32_t)ip4_addr1(a) << 24) | ((uint32_t)ip4_addr2(a) << 16) | ((uint32_t)ip4_addr3(a) << 8) |
           (uint32_t)ip4_addr4(a);
}

/*
 * InitLWIP -- configure lwIP from the RTL node identity (MAC, effective IP,
 * netmask, gateway of the protocol wrapper).
 * Steps:
 *   1. Protocol core absent: return RTLNET_LWIP_NO_PROTOCOL (lwIP stays off,
 *      the CPU-only bitstream); DMA absent: RTLNET_LWIP_NO_DMA.
 *   2. Read the MAC and the effective IP / mask / gateway through the
 *      rtlnet_eth_protocol driver.
 *   3. First call: lwip_init(), netif_add with those values and
 *      ethernet_input, discovery of the CPU-path blocks and
 *      rtlnet_offload_apply (checksum offloads on as far as present), default,
 *      up, link as last reported; start the TCP
 *      applications (echo on port 7, iperf on port 5001). Returns RTLNET_LWIP_STARTED.
 *   4. Later calls: a different MAC replaces netif->hwaddr and flushes the
 *      ARP table; a different IP, mask or gateway goes in with
 *      netif_set_addr (lwIP moves or aborts the affected PCBs and announces
 *      the address). Returns RTLNET_LWIP_RECONFIGURED, or
 *      RTLNET_LWIP_UNCHANGED when everything already matched.
 * Returns: one of the RTLNET_LWIP_* codes.
 */
int InitLWIP(void)
{
    uint8_t mac[6];
    ip4_addr_t ip;
    ip4_addr_t mask;
    ip4_addr_t gw;
    int rc = RTLNET_LWIP_UNCHANGED;

    g_stat.init_calls++;
    if (rtlnet_eth_protocol_probe(RTLNET_PLAT_PROT_BASE) != RTLNET_PROTO_OK) {
        g_stat.last_result = RTLNET_LWIP_NO_PROTOCOL;
        return RTLNET_LWIP_NO_PROTOCOL;
    }
    if (!rtlnet_netif_hw_present()) {
        g_stat.last_result = RTLNET_LWIP_NO_DMA;
        return RTLNET_LWIP_NO_DMA;
    }
    rtlnet_eth_protocol_get_mac(RTLNET_PLAT_PROT_BASE, mac);
    ip4_from_host(&ip, rtlnet_eth_protocol_get_effective_ip(RTLNET_PLAT_PROT_BASE));
    ip4_from_host(&mask, rtlnet_eth_protocol_get_effective_mask(RTLNET_PLAT_PROT_BASE));
    ip4_from_host(&gw, rtlnet_eth_protocol_get_effective_gateway(RTLNET_PLAT_PROT_BASE));

    if (!g_running) {
        lwip_init();
        rtlnet_netif_set_hwaddr(mac);
        if (netif_add(&g_netif, &ip, &mask, &gw, NULL, rtlnet_netif_init, ethernet_input) == NULL) {
            g_stat.last_result = RTLNET_LWIP_NETIF_FAIL;
            return RTLNET_LWIP_NETIF_FAIL;
        }
        /* Checksum offload: discover what the bitstream has and bring CTRL and the netif flags to "everything
         * present" before the first frame (rtlnet_offload_apply; the flags follow the CTRL read-back). */
        g_netif_added = 1;
        rtlnet_features_discover();
        (void)rtlnet_offload_apply(rtlnet_offload_request());
        netif_set_default(&g_netif);
        netif_set_up(&g_netif);
        if (!g_link_down) {
            netif_set_link_up(&g_netif);
        }
        g_running = 1;
        rtlnet_tcp_echo_lwip_ready();
        rtlnet_tcp_iperf_lwip_ready();
        rc = RTLNET_LWIP_STARTED;
    } else {
        if (memcmp(g_netif.hwaddr, mac, ETH_HWADDR_LEN) != 0) {
            etharp_cleanup_netif(&g_netif);
            memcpy(g_netif.hwaddr, mac, ETH_HWADDR_LEN);
            rtlnet_netif_set_hwaddr(mac);
            g_stat.mac_changes++;
            rc = RTLNET_LWIP_RECONFIGURED;
        }
        if (!ip4_addr_eq(netif_ip4_addr(&g_netif), &ip) || !ip4_addr_eq(netif_ip4_netmask(&g_netif), &mask) ||
            !ip4_addr_eq(netif_ip4_gw(&g_netif), &gw)) {
            netif_set_addr(&g_netif, &ip, &mask, &gw);
            etharp_cleanup_netif(&g_netif);
            g_stat.addr_changes++;
            rc = RTLNET_LWIP_RECONFIGURED;
        }
    }
    if (rc != RTLNET_LWIP_UNCHANGED) {
        g_stat.reconfigs++;
    }
    g_stat.last_result = rc;
    return rc;
}

/*
 * rtlnet_lwip_poll -- main-loop service.
 * Steps:
 *   1. Receive service of the DMA netif (frames are drained even while lwIP
 *      is not running).
 *   2. lwIP timers (sys_check_timeouts) while running.
 * Returns: nothing.
 */
void rtlnet_lwip_poll(void)
{
    rtlnet_netif_poll(g_running ? &g_netif : NULL);
    if (g_running) {
        sys_check_timeouts();
    }
}

/*
 * rtlnet_lwip_set_link -- PHY link state into the netif.
 * Returns: nothing; remembered for the first InitLWIP() when not running.
 */
void rtlnet_lwip_set_link(int up)
{
    g_link_down = up ? 0 : 1;
    if (!g_running) {
        return;
    }
    if (!g_link_down) {
        netif_set_link_up(&g_netif);
    } else {
        netif_set_link_down(&g_netif);
    }
}

/*
 * rtlnet_lwip_arp_resolve -- make the ARP entry of the next hop to a destination exist.
 * Steps:
 *   1. lwIP not running: return 0. A broadcast, multicast or unspecified destination needs no entry: return 1.
 *   2. Next hop: the destination when it is on the netif's subnet, else the gateway (none: return 0).
 *   3. Until an entry for the next hop is stable or timeout_ms has passed: send an ARP request now and every
 *      RTLNET_LWIP_ARP_RETRY_MS, and service lwIP (the reply is received and stored by the netif service).
 * The datagrams of a stream then leave without waiting in lwIP's ARP queue; the first datagram of a new
 * destination is the one an unresolved entry costs.
 * Returns: 1 when the entry exists (or none is needed), 0 on timeout or when lwIP is off.
 */
int rtlnet_lwip_arp_resolve(uint32_t ip, uint32_t timeout_ms)
{
    ip4_addr_t dst;
    ip4_addr_t hop;
    struct eth_addr *eth = NULL;
    const ip4_addr_t *ipr = NULL;
    uint32_t t0;
    uint32_t last;

    if (!g_running) {
        return 0;
    }
    ip4_from_host(&dst, ip);
    if (ip4_addr_isany_val(dst) || ip4_addr_isbroadcast(&dst, &g_netif) || ip4_addr_ismulticast(&dst)) {
        return 1;
    }
    hop = ip4_addr_netcmp(&dst, netif_ip4_addr(&g_netif), netif_ip4_netmask(&g_netif)) ? dst : *netif_ip4_gw(&g_netif);
    if (ip4_addr_isany_val(hop)) {
        return 0;
    }
    t0 = plat_uptime_ms();
    last = t0 - RTLNET_LWIP_ARP_RETRY_MS;   /* the first request goes out at once */
    for (;;) {
        uint32_t now;
        if (etharp_find_addr(&g_netif, &hop, &eth, &ipr) >= 0) {
            return 1;
        }
        now = plat_uptime_ms();
        if ((now - t0) >= timeout_ms) {
            return 0;
        }
        if ((now - last) >= RTLNET_LWIP_ARP_RETRY_MS) {
            (void)etharp_request(&g_netif, &hop);
            last = now;
        }
        rtlnet_lwip_poll();
    }
}

/*
 * rtlnet_lwip_status -- netif identity and InitLWIP() history.
 * Returns: nothing; *out filled.
 */
void rtlnet_lwip_status(rtlnet_lwip_status_t *out)
{
    *out = g_stat;
    out->running = g_running;
    out->link_up = g_running ? (netif_is_link_up(&g_netif) ? 1 : 0) : !g_link_down;
    if (g_running) {
        memcpy(out->mac, g_netif.hwaddr, sizeof(out->mac));
        out->ip = ip4_to_host(netif_ip4_addr(&g_netif));
        out->mask = ip4_to_host(netif_ip4_netmask(&g_netif));
        out->gw = ip4_to_host(netif_ip4_gw(&g_netif));
    } else {
        memset(out->mac, 0, sizeof(out->mac));
        out->ip = 0u;
        out->mask = 0u;
        out->gw = 0u;
    }
}

/*
 * rtlnet_lwip_counters -- the lwIP statistics the CLI prints.
 * Returns: nothing; *out zero while lwIP is not running.
 */
void rtlnet_lwip_counters(rtlnet_lwip_counters_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!g_running) {
        return;
    }
    out->link_recv = lwip_stats.link.recv;
    out->link_xmit = lwip_stats.link.xmit;
    out->link_drop = lwip_stats.link.drop;
    out->etharp_recv = lwip_stats.etharp.recv;
    out->etharp_xmit = lwip_stats.etharp.xmit;
    out->ip_recv = lwip_stats.ip.recv;
    out->ip_xmit = lwip_stats.ip.xmit;
    out->ip_drop = lwip_stats.ip.drop;
    out->tcp_recv = lwip_stats.tcp.recv;
    out->tcp_xmit = lwip_stats.tcp.xmit;
    out->tcp_drop = lwip_stats.tcp.drop;
    out->tcp_err = lwip_stats.tcp.err;
    out->mem_used = lwip_stats.mem.used;
    out->mem_max = lwip_stats.mem.max;
    out->mem_avail = lwip_stats.mem.avail;
    out->mem_err = lwip_stats.mem.err;
    out->pbuf_pool_used = lwip_stats.memp[MEMP_PBUF_POOL]->used;
    out->pbuf_pool_max = lwip_stats.memp[MEMP_PBUF_POOL]->max;
    out->pbuf_pool_avail = lwip_stats.memp[MEMP_PBUF_POOL]->avail;
    out->pbuf_pool_err = lwip_stats.memp[MEMP_PBUF_POOL]->err;
    out->tcp_pcb_used = lwip_stats.memp[MEMP_TCP_PCB]->used;
    out->tcp_pcb_avail = lwip_stats.memp[MEMP_TCP_PCB]->avail;
    out->tcp_seg_used = lwip_stats.memp[MEMP_TCP_SEG]->used;
    out->tcp_seg_max = lwip_stats.memp[MEMP_TCP_SEG]->max;
}

/*
 * rtlnet_lwip_clear_counters -- zero the protocol counters (not the memory
 * usage, which describes the current state) and the netif counters.
 * Returns: nothing.
 */
void rtlnet_lwip_clear_counters(void)
{
    rtlnet_netif_clear_stats();
    if (!g_running) {
        return;
    }
    memset(&lwip_stats.link, 0, sizeof(lwip_stats.link));
    memset(&lwip_stats.etharp, 0, sizeof(lwip_stats.etharp));
    memset(&lwip_stats.ip, 0, sizeof(lwip_stats.ip));
    memset(&lwip_stats.tcp, 0, sizeof(lwip_stats.tcp));
}
