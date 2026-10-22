/*
 * rtlnet_tcp_iperf.c -- TCP iperf 2 server on lwIP (lwiperf, port 5001)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_tcp_iperf.h for the contract. Context: main loop only (the
 * lwiperf callbacks run from rtlnet_lwip_poll).
 */
#include "rtlnet_tcp_iperf.h"

#include <stddef.h>   /* NULL */

#include "rtlnet_platform.h"

#include "lwip/apps/lwiperf.h"
#include "lwip/ip_addr.h"

static void                     *g_session;      /* lwiperf server session, NULL when stopped */
static int                       g_lwip_running;
static int                       g_cfg_enable;
static uint16_t                  g_cfg_port;
static uint16_t                  g_port_running;
static int                       g_have_last;
static rtlnet_tcp_iperf_status_t g_st;

/*
 * on_report -- lwiperf report callback: keep the last test.
 * Returns: nothing.
 */
static void on_report(void *arg, enum lwiperf_report_type report_type, const ip_addr_t *local_addr, u16_t local_port,
                      const ip_addr_t *remote_addr, u16_t remote_port, u32_t bytes_transferred, u32_t ms_duration,
                      u32_t bandwidth_kbitpsec)
{
    (void)arg;
    (void)local_addr;
    (void)local_port;
    g_have_last = 1;
    g_st.tests++;
    g_st.last_result = (int)report_type;
    g_st.last_remote_ip = (remote_addr != NULL) ? lwip_ntohl(ip4_addr_get_u32(ip_2_ip4(remote_addr))) : 0u;
    g_st.last_remote_port = remote_port;
    g_st.last_bytes = bytes_transferred;
    g_st.last_ms = ms_duration;
    g_st.last_kbps = bandwidth_kbitpsec;
    g_st.last_end_ms = plat_uptime_ms();
}

/*
 * apply -- start, move or stop the lwiperf server to match the configuration.
 * Returns: nothing.
 */
static void apply(void)
{
    if (!g_lwip_running) {
        return;
    }
    if (g_session != NULL && (!g_cfg_enable || g_port_running != g_cfg_port)) {
        lwiperf_abort(g_session);
        g_session = NULL;
    }
    if (g_cfg_enable && g_session == NULL) {
        g_session = lwiperf_start_tcp_server(IP4_ADDR_ANY, g_cfg_port, on_report, NULL);
        g_port_running = g_cfg_port;
    }
}

/*
 * rtlnet_tcp_iperf_config -- store enable and port, apply when lwIP runs.
 * Returns: nothing.
 */
void rtlnet_tcp_iperf_config(int enable, uint16_t port)
{
    g_cfg_enable = enable ? 1 : 0;
    g_cfg_port = port;
    apply();
}

/*
 * rtlnet_tcp_iperf_lwip_ready -- lwIP is up (first InitLWIP): start the server.
 * Returns: nothing.
 */
void rtlnet_tcp_iperf_lwip_ready(void)
{
    g_lwip_running = 1;
    apply();
}

/*
 * rtlnet_tcp_iperf_status -- configuration, server state and the last test.
 * Returns: nothing; *out filled.
 */
void rtlnet_tcp_iperf_status(rtlnet_tcp_iperf_status_t *out)
{
    *out = g_st;
    out->enabled = g_cfg_enable;
    out->port = g_cfg_port;
    out->lwip_running = g_lwip_running;
    out->listening = (g_session != NULL) ? 1 : 0;
    if (!g_have_last) {
        out->last_result = RTLNET_TCP_IPERF_NONE;
    }
}

/*
 * rtlnet_tcp_iperf_result_name -- text of a last_result value.
 * Returns: the name.
 */
const char *rtlnet_tcp_iperf_result_name(int result)
{
    switch (result) {
    case LWIPERF_TCP_DONE_SERVER:             return "done (server)";
    case LWIPERF_TCP_DONE_CLIENT:             return "done (client)";
    case LWIPERF_TCP_ABORTED_LOCAL:           return "aborted (local)";
    case LWIPERF_TCP_ABORTED_LOCAL_DATAERROR: return "aborted (data error)";
    case LWIPERF_TCP_ABORTED_LOCAL_TXERROR:   return "aborted (transmit error)";
    case LWIPERF_TCP_ABORTED_REMOTE:          return "aborted (by the client)";
    default:                                  return "none yet";
    }
}
