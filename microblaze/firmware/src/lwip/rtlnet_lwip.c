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

static struct netif g_netif;
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
 *      ethernet_input, default, up, link as last reported; start the TCP
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
