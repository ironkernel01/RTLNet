/*
 * rtlnet_lwip.h -- lwIP on RTLNet: node identity from the protocol wrapper,
 *                  main-loop service, status for the CLI
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the protocol wrapper owns the node identity (MAC address, effective
 * IPv4 address, netmask, gateway: rtlnet_eth_protocol registers). lwIP must
 * use the same values, because the hardware leaves answer ARP and ping for
 * that address and only unclaimed frames (TCP, ARP replies, other traffic)
 * reach lwIP. InitLWIP() is the one function that copies the identity into
 * lwIP:
 *   - first call: lwip_init(), DMA netif added with the RTL values, set
 *     default and up; the TCP applications start;
 *   - every later call: the RTL values are compared with the netif; a changed
 *     IP, mask or gateway goes in with netif_set_addr, a changed MAC replaces
 *     netif->hwaddr and flushes the ARP table (etharp_cleanup_netif); nothing
 *     happens when everything matches.
 * rtlnet_netmgr calls it after the protocol core is probed, on DHCP bound /
 * lost / new address, on a static IP / mask / gateway / MAC change from the
 * CLI, on link up, and as a consistency check every link-monitor period.
 *
 * rtlnet_lwip_arp_resolve() makes the ARP entry of a destination's next hop exist (ARP request every
 * RTLNET_LWIP_ARP_RETRY_MS, lwIP serviced meanwhile), so the first datagram to that destination is sent at
 * once and not held in lwIP's ARP queue; the video stream calls it before its first datagram.
 *
 * Main-loop contract: rtlnet_lwip_poll() from the main loop (netif receive
 * service, sys_check_timeouts). sys_now() is the platform millisecond tick.
 *
 * The desktop harness links host/host_lwip_stub.c instead (no lwIP there).
 * This header holds types, constants and signatures; rtlnet_lwip.c holds the
 * per-function commentary.
 */
#ifndef RTLNET_LWIP_H
#define RTLNET_LWIP_H

#include <stdint.h>   /* uint8_t, uint32_t */

#define RTLNET_LWIP_ARP_RETRY_MS   100u   /* spacing of the ARP requests of rtlnet_lwip_arp_resolve */

/* InitLWIP() results. */
#define RTLNET_LWIP_UNCHANGED      0    /* netif already matches the RTL registers */
#define RTLNET_LWIP_STARTED        1    /* first call: lwIP initialized, netif up */
#define RTLNET_LWIP_RECONFIGURED   2    /* address and/or MAC updated in place */
#define RTLNET_LWIP_NO_PROTOCOL    (-1) /* protocol core absent: lwIP not started */
#define RTLNET_LWIP_NO_DMA         (-2) /* AXI DMA absent or not configured */
#define RTLNET_LWIP_NETIF_FAIL     (-3) /* netif_add refused */

typedef struct {
    int      running;          /* lwIP initialized and the netif added */
    int      link_up;
    uint8_t  mac[6];           /* as in netif->hwaddr */
    uint32_t ip;               /* host order, first octet in [31:24] */
    uint32_t mask;
    uint32_t gw;
    uint32_t init_calls;       /* InitLWIP() calls */
    uint32_t reconfigs;        /* calls that changed something */
    uint32_t mac_changes;
    uint32_t addr_changes;
    int      last_result;      /* last InitLWIP() result */
} rtlnet_lwip_status_t;

/* lwIP statistics the CLI prints (copied out of lwip_stats). */
typedef struct {
    uint32_t link_recv, link_xmit, link_drop;
    uint32_t etharp_recv, etharp_xmit;
    uint32_t ip_recv, ip_xmit, ip_drop;
    uint32_t tcp_recv, tcp_xmit, tcp_drop, tcp_err;
    uint32_t mem_used, mem_max, mem_avail, mem_err;
    uint32_t pbuf_pool_used, pbuf_pool_max, pbuf_pool_avail, pbuf_pool_err;
    uint32_t tcp_pcb_used, tcp_pcb_avail, tcp_seg_used, tcp_seg_max;
} rtlnet_lwip_counters_t;

int  InitLWIP(void);
void rtlnet_lwip_poll(void);
void rtlnet_lwip_set_link(int up);
int  rtlnet_lwip_arp_resolve(uint32_t ip, uint32_t timeout_ms);
void rtlnet_lwip_status(rtlnet_lwip_status_t *out);
void rtlnet_lwip_counters(rtlnet_lwip_counters_t *out);
void rtlnet_lwip_clear_counters(void);

#endif /* RTLNET_LWIP_H */
