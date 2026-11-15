/* Purpose: retain public UDP capture model. Overview: no network. Revision: 11-14-2026.
 * Copyright (C) 2026 IronKernel. All rights reserved. */
#include <stdlib.h>
#include <string.h>
#include "host_platform.h"
#include "rtlnet_video_udp.h"
/* Video UDP output, harness: the datagrams are counted and discarded. */
static uint32_t g_vudp_sent;
static int      g_vudp_open;
static uint64_t g_vudp_hash = 1469598103934665603ull;   /* FNV-1a 64 offset basis */
static uint32_t g_vudp_bytes;
static uint32_t g_vudp_dgrams;
static uint8_t *g_vudp_cap;
static uint32_t g_vudp_cap_max;
static uint32_t g_vudp_cap_len;

void host_video_udp_capture(uint32_t max_bytes)
{
    free(g_vudp_cap);
    g_vudp_cap = (max_bytes != 0u) ? (uint8_t *)malloc(max_bytes) : NULL;
    g_vudp_cap_max = (g_vudp_cap != NULL) ? max_bytes : 0u;
    g_vudp_cap_len = 0u;
}

const uint8_t *host_video_udp_data(uint32_t *len)
{
    *len = g_vudp_cap_len;
    return g_vudp_cap;
}

void host_video_udp_reset(void)
{
    g_vudp_hash = 1469598103934665603ull;
    g_vudp_bytes = 0u;
    g_vudp_dgrams = 0u;
    g_vudp_cap_len = 0u;
}

uint64_t host_video_udp_hash(void)
{
    return g_vudp_hash;
}

uint32_t host_video_udp_bytes(void)
{
    return g_vudp_bytes;
}

uint32_t host_video_udp_datagrams(void)
{
    return g_vudp_dgrams;
}

int video_udp_open(uint32_t ip, uint16_t port)
{
    (void)ip;
    (void)port;
    g_vudp_open = 1;
    return 0;
}

void video_udp_close(void)
{
    g_vudp_open = 0;
}

int video_udp_send(const uint8_t *data, uint32_t len)
{
    if (!g_vudp_open) {
        return -1;
    }
    for (uint32_t i = 0u; i < len; i++) {
        g_vudp_hash = (g_vudp_hash ^ data[i]) * 1099511628211ull;
    }
    if (g_vudp_cap != NULL && g_vudp_cap_len + len <= g_vudp_cap_max) {
        memcpy(&g_vudp_cap[g_vudp_cap_len], data, len);
        g_vudp_cap_len += len;
    }
    g_vudp_bytes += len;
    g_vudp_dgrams++;
    g_vudp_sent++;
    return 0;
}

void video_udp_counters(uint32_t *sent, uint32_t *dropped, uint32_t *retries)
{
    *sent = g_vudp_sent;
    *dropped = 0u;
    *retries = 0u;
}

void video_udp_profile(uint64_t *copy_ticks, uint64_t *send_ticks)
{
    *copy_ticks = 0u;
    *send_ticks = 0u;
}
