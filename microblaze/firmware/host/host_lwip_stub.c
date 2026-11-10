/*
 * host_lwip_stub.c -- desktop-harness stand-in for lwIP, the DMA netif and
 *                     the TCP echo server
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the harness (host gcc) compiles the CLI, the network manager and the
 * board layer against a register model, but no lwIP and no AXI DMA. This file
 * provides the signatures of src/lwip/rtlnet_lwip.h, src/lwip/rtlnet_lwip_netif.h and
 * src/lwip/rtlnet_tcp_echo.h and src/lwip/rtlnet_tcp_iperf.h: InitLWIP reports that lwIP does not run here, the
 * DMA is absent, and the TCP echo and iperf configuration is stored so the running
 * configuration and the CLI commands behave as on the target.
 */
#include <string.h>   /* memset */

#include "host_platform.h"
#include "rtlnet_video_udp.h"
#include "rtlnet_lwip.h"
#include "rtlnet_offload.h"
#include "rtlnet_lwip_netif.h"
#include "rtlnet_tcp_echo.h"
#include "rtlnet_tcp_iperf.h"

static rtlnet_netif_stats_t g_st;
static uint32_t             g_cs_flags = 0xFFFFu;
static int                  g_echo_enable;
static uint16_t             g_echo_port;
static uint32_t             g_init_calls;
static int                  g_iperf_enable;
static uint16_t             g_iperf_port;

/*
 * InitLWIP -- harness: lwIP is not part of the desktop build.
 * Returns: RTLNET_LWIP_NO_DMA.
 */
int InitLWIP(void)
{
    g_init_calls++;
    return RTLNET_LWIP_NO_DMA;
}

/*
 * rtlnet_lwip_set_checksum_ctrl -- harness: remember the flags and log the change.
 * Returns: nothing.
 */
void rtlnet_lwip_set_checksum_ctrl(uint32_t flags)
{
    g_cs_flags = flags;
    host_event_flags(flags);
}

/*
 * rtlnet_lwip_get_checksum_ctrl -- harness: the flags last set.
 * Returns: the flags.
 */
uint32_t rtlnet_lwip_get_checksum_ctrl(void)
{
    return g_cs_flags;
}

/*
 * rtlnet_lwip_poll -- harness: nothing to service.
 * Returns: nothing.
 */
void rtlnet_lwip_poll(void)
{
}

/*
 * rtlnet_lwip_set_link -- harness: ignored.
 * Returns: nothing.
 */
void rtlnet_lwip_set_link(int up)
{
    (void)up;
}

/*
 * rtlnet_lwip_status -- harness: not running.
 * Returns: nothing; *out zero except the call count and the last result.
 */
void rtlnet_lwip_status(rtlnet_lwip_status_t *out)
{
    memset(out, 0, sizeof(*out));
    out->init_calls = g_init_calls;
    out->last_result = RTLNET_LWIP_NO_DMA;
}

/*
 * rtlnet_lwip_counters -- harness: zero.
 * Returns: nothing.
 */
void rtlnet_lwip_counters(rtlnet_lwip_counters_t *out)
{
    memset(out, 0, sizeof(*out));
}

/*
 * rtlnet_lwip_clear_counters -- harness: nothing to clear.
 * Returns: nothing.
 */
void rtlnet_lwip_clear_counters(void)
{
}

/*
 * rtlnet_netif_hw_init -- harness: no DMA.
 * Returns: -1.
 */
int rtlnet_netif_hw_init(void)
{
    return -1;
}

/*
 * rtlnet_netif_hw_present -- harness: no DMA.
 * Returns: 0.
 */
int rtlnet_netif_hw_present(void)
{
    return 0;
}

/*
 * rtlnet_netif_stats -- harness: zero counters.
 * Returns: pointer to them.
 */
const rtlnet_netif_stats_t *rtlnet_netif_stats(void)
{
    return &g_st;
}

/*
 * rtlnet_netif_clear_stats -- harness: nothing to clear.
 * Returns: nothing.
 */
void rtlnet_netif_clear_stats(void)
{
}

/*
 * rtlnet_netif_dma_sr -- harness: no DMA.
 * Returns: 0.
 */
uint32_t rtlnet_netif_dma_sr(int rx)
{
    (void)rx;
    return 0u;
}

/*
 * rtlnet_tcp_echo_config -- harness: store the setting.
 * Returns: nothing.
 */
void rtlnet_tcp_echo_config(int enable, uint16_t port)
{
    g_echo_enable = enable ? 1 : 0;
    g_echo_port = port;
}

/*
 * rtlnet_tcp_echo_lwip_ready -- harness: never called.
 * Returns: nothing.
 */
void rtlnet_tcp_echo_lwip_ready(void)
{
}

/*
 * rtlnet_tcp_echo_status -- harness: configuration, not listening.
 * Returns: nothing.
 */
void rtlnet_tcp_echo_status(rtlnet_tcp_echo_status_t *out)
{
    memset(out, 0, sizeof(*out));
    out->enabled = g_echo_enable;
    out->port = g_echo_port;
}

/*
 * rtlnet_tcp_echo_conn -- harness: no connections.
 * Returns: 0.
 */
int rtlnet_tcp_echo_conn(unsigned index, rtlnet_tcp_echo_conn_t *out)
{
    (void)index;
    (void)out;
    return 0;
}

/*
 * rtlnet_tcp_echo_clear_counters -- harness: nothing to clear.
 * Returns: nothing.
 */
void rtlnet_tcp_echo_clear_counters(void)
{
}

/*
 * rtlnet_tcp_iperf_config -- harness: store the setting.
 * Returns: nothing.
 */
void rtlnet_tcp_iperf_config(int enable, uint16_t port)
{
    g_iperf_enable = enable ? 1 : 0;
    g_iperf_port = port;
}

/*
 * rtlnet_tcp_iperf_lwip_ready -- harness: never called.
 * Returns: nothing.
 */
void rtlnet_tcp_iperf_lwip_ready(void)
{
}

/*
 * rtlnet_tcp_iperf_status -- harness: configuration, no session, no test.
 * Returns: nothing.
 */
void rtlnet_tcp_iperf_status(rtlnet_tcp_iperf_status_t *out)
{
    memset(out, 0, sizeof(*out));
    out->enabled = g_iperf_enable;
    out->port = g_iperf_port;
    out->last.result = RTLNET_TCP_IPERF_NONE;
    out->prev.result = RTLNET_TCP_IPERF_NONE;
}

/*
 * rtlnet_tcp_iperf_result_name -- harness: no lwiperf, only "none yet".
 * Returns: the name.
 */
const char *rtlnet_tcp_iperf_result_name(int result)
{
    (void)result;
    return "none yet";
}

/*
 * rtlnet_tcp_iperf_dir_name -- harness: no lwiperf, only "unknown".
 * Returns: the name.
 */
const char *rtlnet_tcp_iperf_dir_name(int dir)
{
    (void)dir;
    return "unknown";
}

/* Video UDP output, harness: the datagrams are counted and discarded. */
static uint32_t g_vudp_sent;
static int      g_vudp_open;

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
    (void)data;
    (void)len;
    if (!g_vudp_open) {
        return -1;
    }
    g_vudp_sent++;
    return 0;
}

void video_udp_counters(uint32_t *sent, uint32_t *dropped, uint32_t *retries)
{
    *sent = g_vudp_sent;
    *dropped = 0u;
    *retries = 0u;
}
