/*
 * rtlnet_tcp_iperf.h -- TCP iperf 2 server on lwIP (lwiperf, port 5001)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: a firmware application on lwIP next to the TCP echo server. It runs
 * lwIP's own lwiperf application (src/apps/lwiperf/lwiperf.c of the install,
 * compiled in place) as a TCP server; `iperf -c <board>` from a PC measures
 * PC -> board TCP throughput through the CPU network path. The UDP iperf
 * server on port 5001 is the RTL iperf leaf; TCP is never claimed by a leaf,
 * so TCP 5001 reaches lwIP.
 *
 * The lwiperf report callback keeps the last test: result, peer, bytes,
 * duration and throughput; `show iperf` prints it under "TCP (firmware,
 * lwIP)". Configuration: rtlnet_tcp_iperf_config(enable, port) stores the
 * setting and applies it when lwIP runs (server started, moved or stopped);
 * InitLWIP() calls rtlnet_tcp_iperf_lwip_ready() once lwIP is up. Context:
 * main loop only.
 *
 * The desktop harness links host/host_lwip_stub.c instead.
 * This header holds types, constants and signatures; the .c file holds the
 * per-function commentary.
 */
#ifndef RTLNET_TCP_IPERF_H
#define RTLNET_TCP_IPERF_H

#include <stdint.h>   /* uint16_t, uint32_t */

#define RTLNET_TCP_IPERF_PORT_DEFAULT  5001u

/* Result of the last test (lwiperf report type, plus "none yet"). */
#define RTLNET_TCP_IPERF_NONE          (-1)

typedef struct {
    int      enabled;          /* configured */
    uint16_t port;             /* configured */
    int      lwip_running;
    int      listening;        /* lwiperf server session open */
    uint32_t tests;            /* reports received */
    int      last_result;      /* lwiperf_report_type, or RTLNET_TCP_IPERF_NONE */
    uint32_t last_remote_ip;   /* host order */
    uint16_t last_remote_port;
    uint32_t last_bytes;
    uint32_t last_ms;
    uint32_t last_kbps;        /* lwiperf's average, kbit/s */
    uint32_t last_end_ms;      /* uptime when the report arrived */
} rtlnet_tcp_iperf_status_t;

void        rtlnet_tcp_iperf_config(int enable, uint16_t port);
void        rtlnet_tcp_iperf_lwip_ready(void);
void        rtlnet_tcp_iperf_status(rtlnet_tcp_iperf_status_t *out);
const char *rtlnet_tcp_iperf_result_name(int result);

#endif /* RTLNET_TCP_IPERF_H */
