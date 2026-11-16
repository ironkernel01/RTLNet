/*
 * rtlnet_tcp_echo.c -- lwIP raw-API TCP echo server (RFC 862, port 7)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_tcp_echo.h for the contract. Context: main loop only (lwIP
 * callbacks run from rtlnet_lwip_poll and from tcp_* calls made here).
 */
#include "rtlnet_tcp_echo.h"

#include <stddef.h>   /* NULL */
#include <string.h>   /* memset */

#include "rtlnet_firewall.h"
#include "rtlnet_platform.h"

#include "lwip/pbuf.h"
#include "lwip/tcp.h"

typedef struct {
    struct tcp_pcb *pcb;
    struct pbuf    *queue;     /* received, not yet written */
    int             used;
    int             closing;   /* FIN seen: close once the queue is empty */
    uint32_t        bytes_rx;
    uint32_t        bytes_tx;
    uint32_t        start_ms;
} echo_conn_t;

static echo_conn_t              g_conn[RTLNET_TCP_ECHO_MAX_CONN];
static struct tcp_pcb          *g_listen;
static int                      g_lwip_running;
static int                      g_cfg_enable;
static uint16_t                 g_cfg_port;
static uint16_t                 g_listen_port;
static rtlnet_tcp_echo_status_t g_st;

static err_t on_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err);
static err_t on_sent(void *arg, struct tcp_pcb *pcb, u16_t len);
static err_t on_poll(void *arg, struct tcp_pcb *pcb);
static void  on_err(void *arg, err_t err);

/*
 * conn_release -- detach the callbacks and free the slot.
 * Returns: nothing.
 */
static void conn_release(echo_conn_t *c)
{
    if (c->pcb != NULL) {
        tcp_arg(c->pcb, NULL);
        tcp_recv(c->pcb, NULL);
        tcp_sent(c->pcb, NULL);
        tcp_err(c->pcb, NULL);
        tcp_poll(c->pcb, NULL, 0u);
    }
    if (c->queue != NULL) {
        pbuf_free(c->queue);
    }
    memset(c, 0, sizeof(*c));
    if (g_st.active > 0u) {
        g_st.active--;
    }
}

/*
 * conn_close -- orderly close; retried from the poll callback when lwIP has
 * no memory for the FIN.
 * Returns: nothing.
 */
static void conn_close(echo_conn_t *c)
{
    struct tcp_pcb *pcb = c->pcb;
    tcp_arg(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_sent(pcb, NULL);
    tcp_err(pcb, NULL);
    tcp_poll(pcb, NULL, 0u);
    if (tcp_close(pcb) != ERR_OK) {
        /* No memory for the FIN: keep the connection; the poll callback
         * retries the close. */
        tcp_arg(pcb, c);
        tcp_recv(pcb, on_recv);
        tcp_sent(pcb, on_sent);
        tcp_err(pcb, on_err);
        tcp_poll(pcb, on_poll, RTLNET_TCP_ECHO_POLL_HALF_S);
        return;
    }
    c->pcb = NULL;
    g_st.closed++;
    conn_release(c);
}

/*
 * conn_send -- move queued data into the send buffer.
 * Steps:
 *   1. While the head pbuf fits tcp_sndbuf: tcp_write it (copy), unlink it,
 *      then tcp_recved its length (the window opens only for data that is
 *      on its way back).
 *   2. ERR_MEM: stop and retry from tcp_sent / poll; other errors counted.
 *   3. tcp_output; close when the client finished and the queue is empty.
 * Returns: nothing.
 */
static void conn_send(echo_conn_t *c)
{
    while (c->queue != NULL && c->queue->len <= tcp_sndbuf(c->pcb)) {
        struct pbuf *head = c->queue;
        u16_t len = head->len;
        err_t wr = tcp_write(c->pcb, head->payload, len, TCP_WRITE_FLAG_COPY);
        if (wr == ERR_MEM) {
            break;
        }
        if (wr != ERR_OK) {
            g_st.write_errors++;
            break;
        }
        /* Unlink the head: the rest of the chain keeps its own reference. */
        c->queue = head->next;
        head->next = NULL;
        head->tot_len = len;
        pbuf_free(head);
        tcp_recved(c->pcb, len);
        c->bytes_tx += len;
        g_st.bytes_tx += len;
    }
    (void)tcp_output(c->pcb);
    if (c->closing && c->queue == NULL) {
        conn_close(c);
    }
}

/*
 * on_recv -- data or FIN from the client.
 * Returns: ERR_OK (the pbuf is owned here), or the error passed in.
 */
static err_t on_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    echo_conn_t *c = (echo_conn_t *)arg;
    if (c == NULL) {
        if (p != NULL) {
            tcp_recved(pcb, p->tot_len);
            pbuf_free(p);
        }
        return ERR_OK;
    }
    if (p == NULL) {
        c->closing = 1;
        if (c->queue == NULL) {
            conn_close(c);
        } else {
            conn_send(c);
        }
        return ERR_OK;
    }
    if (err != ERR_OK) {
        pbuf_free(p);
        return err;
    }
    c->bytes_rx += p->tot_len;
    g_st.bytes_rx += p->tot_len;
    if (c->queue == NULL) {
        c->queue = p;
    } else {
        pbuf_cat(c->queue, p);
    }
    conn_send(c);
    return ERR_OK;
}

/*
 * on_sent -- the peer acknowledged data: continue sending or close.
 * Returns: ERR_OK.
 */
static err_t on_sent(void *arg, struct tcp_pcb *pcb, u16_t len)
{
    echo_conn_t *c = (echo_conn_t *)arg;
    (void)pcb;
    (void)len;
    if (c != NULL) {
        conn_send(c);
    }
    return ERR_OK;
}

/*
 * on_poll -- periodic retry of a stalled send or close.
 * Returns: ERR_OK.
 */
static err_t on_poll(void *arg, struct tcp_pcb *pcb)
{
    echo_conn_t *c = (echo_conn_t *)arg;
    if (c == NULL) {
        (void)tcp_close(pcb);
        return ERR_OK;
    }
    if (c->queue != NULL || c->closing) {
        conn_send(c);
    }
    return ERR_OK;
}

/*
 * on_err -- the PCB is gone (reset, timeout, abort): release the slot.
 * Returns: nothing.
 */
static void on_err(void *arg, err_t err)
{
    echo_conn_t *c = (echo_conn_t *)arg;
    (void)err;
    if (c != NULL) {
        c->pcb = NULL;
        g_st.aborted++;
        conn_release(c);
    }
}

/*
 * on_accept -- a new connection on the listen PCB.
 * Steps:
 *   1. Take a free slot, else refuse (tcp_abort, ERR_ABRT).
 *   2. Install the callbacks.
 * Returns: ERR_OK, ERR_VAL on a failed accept, ERR_ABRT when refused.
 */
static err_t on_accept(void *arg, struct tcp_pcb *pcb, err_t err)
{
    (void)arg;
    if (err != ERR_OK || pcb == NULL) {
        return ERR_VAL;
    }
    for (unsigned i = 0; i < RTLNET_TCP_ECHO_MAX_CONN; i++) {
        echo_conn_t *c = &g_conn[i];
        if (!c->used) {
            memset(c, 0, sizeof(*c));
            c->used = 1;
            c->pcb = pcb;
            c->start_ms = plat_uptime_ms();
            tcp_setprio(pcb, TCP_PRIO_MIN);
            tcp_arg(pcb, c);
            tcp_recv(pcb, on_recv);
            tcp_sent(pcb, on_sent);
            tcp_err(pcb, on_err);
            tcp_poll(pcb, on_poll, RTLNET_TCP_ECHO_POLL_HALF_S);
            g_st.accepted++;
            g_st.active++;
            return ERR_OK;
        }
    }
    g_st.refused++;
    tcp_abort(pcb);
    return ERR_ABRT;
}

/*
 * apply -- open, move or close the listen PCB to match the configuration, and tell the firewall which port
 * is open (FW_SVC_TCP_ECHO: removed when the listen PCB closes, set once the new one listens).
 * Returns: nothing.
 */
static void apply(void)
{
    if (!g_lwip_running) {
        return;
    }
    if (g_listen != NULL && (!g_cfg_enable || g_listen_port != g_cfg_port)) {
        (void)tcp_close(g_listen);
        g_listen = NULL;
        (void)fw_service_set(FW_SVC_TCP_ECHO, FW_PROTO_TCP, g_listen_port, 0);
    }
    if (g_cfg_enable && g_listen == NULL) {
        struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
        if (pcb == NULL) {
            return;
        }
        if (tcp_bind(pcb, IP4_ADDR_ANY, g_cfg_port) != ERR_OK) {
            (void)tcp_close(pcb);
            return;
        }
        g_listen = tcp_listen(pcb);
        if (g_listen == NULL) {
            (void)tcp_close(pcb);
            return;
        }
        g_listen_port = g_cfg_port;
        tcp_accept(g_listen, on_accept);
        (void)fw_service_set(FW_SVC_TCP_ECHO, FW_PROTO_TCP, g_listen_port, 1);
    }
}

/*
 * rtlnet_tcp_echo_config -- store enable and port, apply when lwIP runs.
 * Returns: nothing.
 */
void rtlnet_tcp_echo_config(int enable, uint16_t port)
{
    g_cfg_enable = enable ? 1 : 0;
    g_cfg_port = port;
    apply();
}

/*
 * rtlnet_tcp_echo_lwip_ready -- lwIP is up (first InitLWIP): open the server.
 * Returns: nothing.
 */
void rtlnet_tcp_echo_lwip_ready(void)
{
    g_lwip_running = 1;
    apply();
}

/*
 * rtlnet_tcp_echo_status -- configuration, server state and counters.
 * Returns: nothing; *out filled.
 */
void rtlnet_tcp_echo_status(rtlnet_tcp_echo_status_t *out)
{
    *out = g_st;
    out->enabled = g_cfg_enable;
    out->port = g_cfg_port;
    out->lwip_running = g_lwip_running;
    out->listening = (g_listen != NULL) ? 1 : 0;
}

/*
 * rtlnet_tcp_echo_conn -- one connection slot.
 * Returns: 1 slot in use (*out filled), 0 free or out of range.
 */
int rtlnet_tcp_echo_conn(unsigned index, rtlnet_tcp_echo_conn_t *out)
{
    const echo_conn_t *c;
    if (index >= RTLNET_TCP_ECHO_MAX_CONN || !g_conn[index].used || g_conn[index].pcb == NULL) {
        return 0;
    }
    c = &g_conn[index];
    out->remote_ip = lwip_ntohl(ip4_addr_get_u32(ip_2_ip4(&c->pcb->remote_ip)));
    out->remote_port = c->pcb->remote_port;
    out->local_port = c->pcb->local_port;
    out->bytes_rx = c->bytes_rx;
    out->bytes_tx = c->bytes_tx;
    out->queued = (c->queue != NULL) ? c->queue->tot_len : 0u;
    out->age_ms = plat_uptime_ms() - c->start_ms;
    out->closing = c->closing;
    return 1;
}

/*
 * rtlnet_tcp_echo_clear_counters -- zero the counters (active stays).
 * Returns: nothing.
 */
void rtlnet_tcp_echo_clear_counters(void)
{
    uint32_t active = g_st.active;
    memset(&g_st, 0, sizeof(g_st));
    g_st.active = active;
}
