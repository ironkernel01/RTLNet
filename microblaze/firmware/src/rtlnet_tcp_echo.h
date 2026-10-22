/*
 * rtlnet_tcp_echo.h -- lwIP raw-API TCP echo server (RFC 862, port 7)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: a firmware application on lwIP. Every byte a client sends on a
 * connection to the echo port comes back on that connection.
 *
 * Behaviour:
 *   - up to RTLNET_TCP_ECHO_MAX_CONN concurrent connections (one state slot
 *     each, no heap); a connection beyond that is refused with an abort;
 *   - flow control: received pbufs are queued; each one is copied into the
 *     send buffer with tcp_write when tcp_sndbuf has room, and only then
 *     acknowledged to the peer with tcp_recved, so a client that sends faster
 *     than the echo drains sees the receive window close; tcp_sent and the
 *     poll callback resume sending;
 *   - FIN from the client: the queued data is still echoed, then the
 *     connection is closed;
 *   - tcp_err: the slot is released (the PCB is already gone) and counted.
 *
 * Configuration: rtlnet_tcp_echo_config(enable, port) stores the setting and
 * applies it when lwIP runs (listen PCB opened, moved or closed; existing
 * connections are kept). InitLWIP() calls rtlnet_tcp_echo_lwip_ready() once
 * lwIP is up. Context: main loop only.
 *
 * The desktop harness links host/host_lwip_stub.c instead.
 * This header holds types, constants and signatures; the .c file holds the
 * per-function commentary.
 */
#ifndef RTLNET_TCP_ECHO_H
#define RTLNET_TCP_ECHO_H

#include <stdint.h>   /* uint16_t, uint32_t */

#define RTLNET_TCP_ECHO_PORT_DEFAULT  7u
#define RTLNET_TCP_ECHO_MAX_CONN      8u
#define RTLNET_TCP_ECHO_POLL_HALF_S   2u    /* tcp_poll interval, units of 0.5 s */

typedef struct {
    int      enabled;          /* configured */
    uint16_t port;             /* configured */
    int      lwip_running;
    int      listening;        /* listen PCB open on port */
    uint32_t active;           /* connections now */
    uint32_t accepted;
    uint32_t refused;          /* no free slot */
    uint32_t closed;           /* orderly close */
    uint32_t aborted;          /* tcp_err (reset by the peer, timeout) */
    uint32_t write_errors;     /* tcp_write failures other than ERR_MEM */
    uint32_t bytes_rx;
    uint32_t bytes_tx;
} rtlnet_tcp_echo_status_t;

typedef struct {
    uint32_t remote_ip;        /* host order */
    uint16_t remote_port;
    uint16_t local_port;
    uint32_t bytes_rx;
    uint32_t bytes_tx;
    uint32_t queued;           /* bytes received, not yet written */
    uint32_t age_ms;
    int      closing;          /* FIN received */
} rtlnet_tcp_echo_conn_t;

void rtlnet_tcp_echo_config(int enable, uint16_t port);
void rtlnet_tcp_echo_lwip_ready(void);
void rtlnet_tcp_echo_status(rtlnet_tcp_echo_status_t *out);
int  rtlnet_tcp_echo_conn(unsigned index, rtlnet_tcp_echo_conn_t *out);
void rtlnet_tcp_echo_clear_counters(void);

#endif /* RTLNET_TCP_ECHO_H */
