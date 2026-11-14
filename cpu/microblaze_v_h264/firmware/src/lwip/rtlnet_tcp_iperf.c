/*
 * rtlnet_tcp_iperf.c -- TCP iperf 2 server on lwIP (rtlnet_lwiperf, port 5001)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_tcp_iperf.h for the contract. Context: main loop only (the
 * rtlnet_lwiperf callbacks run from rtlnet_lwip_poll).
 */
#include "rtlnet_tcp_iperf.h"

#include <stddef.h>   /* NULL */

#include "rtlnet_platform.h"

#include "rtlnet_lwiperf.h"
#include "lwip/ip_addr.h"

_Static_assert((int)RTLNET_LWIPERF_DIR_RX == RTLNET_TCP_IPERF_DIR_RX &&
               (int)RTLNET_LWIPERF_DIR_REVERSE == RTLNET_TCP_IPERF_DIR_REVERSE &&
               (int)RTLNET_LWIPERF_DIR_TRADEOFF == RTLNET_TCP_IPERF_DIR_TRADEOFF &&
               (int)RTLNET_LWIPERF_DIR_DUAL == RTLNET_TCP_IPERF_DIR_DUAL &&
               (int)RTLNET_LWIPERF_DIR_CLIENT == RTLNET_TCP_IPERF_DIR_CLIENT,
               "RTLNET_TCP_IPERF_DIR_* must equal enum rtlnet_lwiperf_direction");

static void                     *g_session;      /* lwiperf server session, NULL when stopped */
static int                       g_lwip_running;
static int                       g_cfg_enable;
static uint16_t                  g_cfg_port;
static uint16_t                  g_port_running;
static rtlnet_tcp_iperf_status_t g_st;

/*
 * on_report -- report callback: keep the last two tests, count a refusal.
 * Returns: nothing.
 */
static void on_report(void *arg, enum rtlnet_lwiperf_report_type report_type, enum rtlnet_lwiperf_direction dir,
                      const ip_addr_t *local_addr, u16_t local_port, const ip_addr_t *remote_addr, u16_t remote_port,
                      u32_t bytes_transferred, u32_t ms_duration, u32_t bandwidth_kbitpsec)
{
    (void)arg;
    (void)local_addr;
    (void)local_port;
    if (report_type == RTLNET_LWIPERF_TCP_REJECTED_BUSY) {
        g_st.rejected++;
        return;
    }
    g_st.tests++;
    if ((unsigned)dir < (unsigned)RTLNET_TCP_IPERF_DIR_COUNT) {
        g_st.tests_dir[dir]++;
    }
    g_st.prev = g_st.last;
    g_st.last.result = (int)report_type;
    g_st.last.dir = (int)dir;
    g_st.last.remote_ip = (remote_addr != NULL) ? lwip_ntohl(ip4_addr_get_u32(ip_2_ip4(remote_addr))) : 0u;
    g_st.last.remote_port = remote_port;
    g_st.last.bytes = bytes_transferred;
    g_st.last.ms = ms_duration;
    g_st.last.kbps = bandwidth_kbitpsec;
    g_st.last.end_ms = plat_uptime_ms();
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
        rtlnet_lwiperf_abort(g_session);
        g_session = NULL;
    }
    if (g_cfg_enable && g_session == NULL) {
        g_session = rtlnet_lwiperf_start_tcp_server(IP4_ADDR_ANY, g_cfg_port, on_report, NULL);
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
 * rtlnet_tcp_iperf_status -- configuration, server state and the last two tests.
 * Returns: nothing; *out filled.
 */
void rtlnet_tcp_iperf_status(rtlnet_tcp_iperf_status_t *out)
{
    *out = g_st;
    out->enabled = g_cfg_enable;
    out->port = g_cfg_port;
    out->lwip_running = g_lwip_running;
    out->listening = (g_session != NULL) ? 1 : 0;
    if (g_st.tests < 1u) {
        out->last.result = RTLNET_TCP_IPERF_NONE;
    }
    if (g_st.tests < 2u) {
        out->prev.result = RTLNET_TCP_IPERF_NONE;
    }
}

/*
 * rtlnet_tcp_iperf_result_name -- text of a result value.
 * Returns: the name.
 */
const char *rtlnet_tcp_iperf_result_name(int result)
{
    switch (result) {
    case RTLNET_LWIPERF_TCP_DONE_SERVER:             return "done (received)";
    case RTLNET_LWIPERF_TCP_DONE_CLIENT:             return "done (sent)";
    case RTLNET_LWIPERF_TCP_ABORTED_LOCAL:           return "aborted (local)";
    case RTLNET_LWIPERF_TCP_ABORTED_LOCAL_DATAERROR: return "aborted (data error)";
    case RTLNET_LWIPERF_TCP_ABORTED_LOCAL_TXERROR:   return "aborted (transmit error)";
    case RTLNET_LWIPERF_TCP_ABORTED_REMOTE:          return "aborted (by the client)";
    default:                                         return "none yet";
    }
}

/*
 * rtlnet_tcp_iperf_dir_name -- text of a direction value.
 * Returns: the name.
 */
const char *rtlnet_tcp_iperf_dir_name(int dir)
{
    switch (dir) {
    case RTLNET_TCP_IPERF_DIR_RX:       return "pc->board";
    case RTLNET_TCP_IPERF_DIR_REVERSE:  return "board->pc reverse (-R)";
    case RTLNET_TCP_IPERF_DIR_TRADEOFF: return "board->pc tradeoff (-r)";
    case RTLNET_TCP_IPERF_DIR_DUAL:     return "board->pc dual (-d)";
    case RTLNET_TCP_IPERF_DIR_CLIENT:   return "board->pc client";
    default:                            return "unknown";
    }
}
