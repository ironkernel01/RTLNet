/*
 * rtlnet_tcp_iperf.h -- TCP iperf 2 server on lwIP (rtlnet_lwiperf, port 5001)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: a firmware application on lwIP next to the TCP echo server. It runs
 * the project's iperf application (rtlnet_lwiperf.c, a modified copy of lwIP's
 * lwiperf) as a TCP server on port 5001. The stock iperf 2 client measures
 *   pc -> board       iperf -c <board>      the board receives
 *   board -> pc, -R   iperf -c <board> -R   the board sends on the same connection
 *   board -> pc, -r   iperf -c <board> -r   tradeoff: after the client finished,
 *                                           the board connects back and sends
 *   both ways, -d     iperf -c <board> -d   dual: the board connects back at once
 * through the CPU network path. The UDP iperf server on port 5001 is the RTL
 * iperf leaf; TCP is never claimed by a leaf, so TCP 5001 reaches lwIP.
 *
 * The report callback keeps the last two reports (a -r or -d test reports
 * both directions): result, direction, peer, bytes, duration and throughput;
 * `show iperf` prints them under "TCP (firmware, lwIP)". Configuration:
 * rtlnet_tcp_iperf_config(enable, port) stores the setting and applies it when
 * lwIP runs (server started, moved or stopped); InitLWIP() calls
 * rtlnet_tcp_iperf_lwip_ready() once lwIP is up. Context: main loop only.
 *
 * The desktop harness links host/host_lwip_stub.c instead.
 * This header holds types, constants and signatures; the .c file holds the
 * per-function commentary.
 */
#ifndef RTLNET_TCP_IPERF_H
#define RTLNET_TCP_IPERF_H

#include <stdint.h>   /* uint16_t, uint32_t */

#define RTLNET_TCP_IPERF_PORT_DEFAULT  5001u

/* Result of a test (rtlnet_lwiperf report type), or "none yet". */
#define RTLNET_TCP_IPERF_NONE          (-1)

/* Direction of a test, seen from the board. The numbers equal enum
 * rtlnet_lwiperf_direction (rtlnet_lwiperf.h); rtlnet_tcp_iperf.c asserts it. */
#define RTLNET_TCP_IPERF_DIR_RX        0   /* pc -> board (also the receive half of -r and -d) */
#define RTLNET_TCP_IPERF_DIR_REVERSE   1   /* board -> pc on the client's connection (-R) */
#define RTLNET_TCP_IPERF_DIR_TRADEOFF  2   /* board -> pc, connect-back after the client finished (-r) */
#define RTLNET_TCP_IPERF_DIR_DUAL      3   /* board -> pc, connect-back at once (-d) */
#define RTLNET_TCP_IPERF_DIR_CLIENT    4   /* the board is the client */
#define RTLNET_TCP_IPERF_DIR_COUNT     5

/* One finished test. */
typedef struct {
    int      result;           /* rtlnet_lwiperf report type, or RTLNET_TCP_IPERF_NONE */
    int      dir;              /* RTLNET_TCP_IPERF_DIR_* */
    uint32_t remote_ip;        /* host order */
    uint16_t remote_port;
    uint32_t bytes;            /* payload, the test header excluded */
    uint32_t ms;
    uint32_t kbps;             /* average, kbit/s */
    uint32_t end_ms;           /* uptime when the report arrived */
} rtlnet_tcp_iperf_test_t;

typedef struct {
    int      enabled;          /* configured */
    uint16_t port;             /* configured */
    int      lwip_running;
    int      listening;        /* lwiperf server session open */
    uint32_t tests;            /* reports received (refusals not counted) */
    uint32_t rejected;         /* connections refused: a test of the same mode was running */
    uint32_t tests_dir[RTLNET_TCP_IPERF_DIR_COUNT]; /* reports per direction */
    rtlnet_tcp_iperf_test_t last;   /* newest report, result NONE if there is none */
    rtlnet_tcp_iperf_test_t prev;   /* the one before, result NONE if there is none */
} rtlnet_tcp_iperf_status_t;

void        rtlnet_tcp_iperf_config(int enable, uint16_t port);
void        rtlnet_tcp_iperf_lwip_ready(void);
void        rtlnet_tcp_iperf_status(rtlnet_tcp_iperf_status_t *out);
const char *rtlnet_tcp_iperf_result_name(int result);
const char *rtlnet_tcp_iperf_dir_name(int dir);

#endif /* RTLNET_TCP_IPERF_H */
