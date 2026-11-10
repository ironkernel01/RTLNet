/*
 * rtlnet_video_udp.c -- UDP datagram output of the video stream through lwIP
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: implementation of the contract in rtlnet_video_udp.h.
 *
 * Revision: 11-09-2026
 */
#include "rtlnet_video_udp.h"

#include <stddef.h>   /* NULL */
#include <string.h>   /* memcpy */

#include "lwip/err.h"
#include "lwip/pbuf.h"
#include "lwip/udp.h"
#include "rtlnet_lwip.h"
#include "rtlnet_platform.h"

#define VIDEO_UDP_RETRY_US  2000u

static struct udp_pcb *g_pcb;
static ip_addr_t       g_dst;
static uint16_t        g_port;
static uint32_t        g_sent;
static uint32_t        g_dropped;
static uint32_t        g_retries;

int video_udp_open(uint32_t ip, uint16_t port)
{
    rtlnet_lwip_status_t st;
    rtlnet_lwip_status(&st);
    if (!st.running) {
        return -1;
    }
    if (g_pcb != NULL) {
        udp_remove(g_pcb);
    }
    g_pcb = udp_new();
    if (g_pcb == NULL) {
        return -1;
    }
    IP4_ADDR(&g_dst, (ip >> 24) & 0xFFu, (ip >> 16) & 0xFFu, (ip >> 8) & 0xFFu, ip & 0xFFu);
    g_port = port;
    return 0;
}

void video_udp_close(void)
{
    if (g_pcb != NULL) {
        udp_remove(g_pcb);
        g_pcb = NULL;
    }
}

/*
 * video_udp_send -- one datagram. Allocation or transmit failures (ERR_MEM, ERR_BUF, ERR_IF) are retried while servicing
 * lwIP, bounded by VIDEO_UDP_RETRY_US; an ARP miss queues the packet inside lwIP and returns ERR_OK.
 */
int video_udp_send(const uint8_t *data, uint32_t len)
{
    uint32_t t0 = plat_ticks();
    if (g_pcb == NULL) {
        return -1;
    }
    for (;;) {
        struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)len, PBUF_RAM);
        if (p != NULL) {
            err_t e;
            memcpy(p->payload, data, len);
            e = udp_sendto(g_pcb, p, &g_dst, g_port);
            pbuf_free(p);
            if (e == ERR_OK) {
                g_sent++;
                return 0;
            }
        }
        if ((plat_ticks() - t0) >= VIDEO_UDP_RETRY_US * RTLNET_PLAT_TICKS_PER_US) {
            g_dropped++;
            return -1;
        }
        g_retries++;
        rtlnet_lwip_poll();
    }
}

void video_udp_counters(uint32_t *sent, uint32_t *dropped, uint32_t *retries)
{
    *sent = g_sent;
    *dropped = g_dropped;
    *retries = g_retries;
}
