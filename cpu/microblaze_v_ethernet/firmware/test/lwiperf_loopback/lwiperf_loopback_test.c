/*
 * lwiperf_loopback_test.c -- desktop test of src/lwip/rtlnet_lwiperf.c on lwIP's loopback interface
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs the iperf server (rtlnet_lwiperf.c) and a scripted iperf 2 client
 * in ONE lwIP instance on the host, over 127.0.0.1 (lwIP's loopback netif).
 * The client sends the test headers captured from iperf 2.2.2 (see
 * test/iperf_header_capture.py) and checks what the server does:
 *   plain       pc -> board, 24 byte and 64 byte header, byte count exact
 *   -R          reverse reply on the client's connection, timed and byte-limited,
 *               header split into pieces across segments
 *   -r, -d      connect-back to the header's mPort: header, data pattern, counts
 *   busy        a second test of the same mode is refused and reported
 *   abort       server abort and restart, abort of a running test
 *   heap        every session state is freed (lwIP heap back at its start value)
 * Ends with exactly one line: LWIPERF_LOOPBACK: PASS checks=<n> or
 * LWIPERF_LOOPBACK: FAIL <n> check(s) failed. Exit code 0 on PASS.
 * Build and run: powershell -File cpu/microblaze_v_ethernet/firmware/build.ps1 -LwipTest
 */
#include <stdio.h>    /* printf */
#include <stdlib.h>   /* exit */
#include <string.h>   /* memset, memcpy */
#include <time.h>     /* clock, CLOCKS_PER_SEC */

#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/tcp.h"
#include "lwip/stats.h"
#include "lwip/timeouts.h"

#include "rtlnet_lwiperf.h"

/* Header words measured with iperf 2.2.2 (test/iperf_header_capture.py). */
#define FLAGS_PLAIN     0x40010080u
#define FLAGS_REVERSE   0x44010080u
#define FLAGS_TRADEOFF  0xC0010080u
#define FLAGS_DUAL      0xC0010081u
#define UPPER_REVERSE   0x0400u
#define SERVER_PORT     5001u
#define BACK_PORT       5201u
#define REPORT_MAX      32u
#define CLIENT_MAX      4u
#define WAIT_MS         8000u

typedef struct {
    int      type;
    int      dir;
    uint32_t bytes;
    uint32_t ms;
} report_t;

typedef struct {
    struct tcp_pcb *pcb;
    uint8_t  hdr[64];
    uint16_t hdr_len;
    uint16_t hdr_sent;
    uint16_t pieces[8];       /* header piece sizes, 0 ends; empty = whole header at once */
    uint8_t  piece_idx;
    uint32_t data_total;
    uint32_t data_sent;
    int      close_when_done; /* FIN after the data */
    int      connected;
    int      fin_seen;
    int      err_seen;
    int      closed_local;
    uint32_t rx_total;
    uint32_t rx_skip;         /* leading bytes that are a header, not pattern */
    int      pattern_err;
    uint8_t  rx_first[24];
} client_t;

static report_t  g_rep[REPORT_MAX];
static unsigned  g_nrep;
static client_t  g_cl[CLIENT_MAX];
static client_t  g_back;      /* the connect-back connection accepted from the server */
static struct tcp_pcb *g_back_listen;
static void     *g_srv;
static void    (*g_first_rx_hook)(void);   /* runs once, when client 0 receives its first byte */
static unsigned  g_checks;
static unsigned  g_failed;
static const uint8_t g_pat[1500] = {
#define P10 '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'
#define P100 P10, P10, P10, P10, P10, P10, P10, P10, P10, P10
    P100, P100, P100, P100, P100, P100, P100, P100, P100, P100, P100, P100, P100, P100, P100
};

#define CHECK(cond, what) \
    do { \
        g_checks++; \
        if (!(cond)) { \
            g_failed++; \
            printf("  FAIL: %s (line %d)\n", what, __LINE__); \
        } \
    } while (0)

/* sys_now -- lwIP time base: milliseconds of the host clock. */
u32_t sys_now(void)
{
    return (u32_t)(((uint64_t)clock() * 1000u) / (uint64_t)CLOCKS_PER_SEC);
}

static void on_report(void *arg, enum rtlnet_lwiperf_report_type type, enum rtlnet_lwiperf_direction dir,
                      const ip_addr_t *local_addr, u16_t local_port, const ip_addr_t *remote_addr, u16_t remote_port,
                      u32_t bytes, u32_t ms, u32_t kbps)
{
    (void)arg; (void)local_addr; (void)local_port; (void)remote_addr; (void)remote_port; (void)kbps;
    if (g_nrep < REPORT_MAX) {
        g_rep[g_nrep].type = (int)type;
        g_rep[g_nrep].dir = (int)dir;
        g_rep[g_nrep].bytes = bytes;
        g_rep[g_nrep].ms = ms;
        g_nrep++;
    }
    printf("    report: type %d dir %d bytes %u ms %u kbit/s %u\n", (int)type, (int)dir, (unsigned)bytes,
           (unsigned)ms, (unsigned)kbps);
}

static const report_t *find_report(int dir, int type)
{
    for (unsigned i = 0; i < g_nrep; i++) {
        if (g_rep[i].dir == dir && g_rep[i].type == type) {
            return &g_rep[i];
        }
    }
    return NULL;
}

static void poll_once(void)
{
    netif_poll_all();
    sys_check_timeouts();
}

/* run_until -- poll lwIP until pred() is true or the time is up. Returns 1 when pred() held. */
static int run_until(int (*pred)(void), unsigned timeout_ms)
{
    u32_t t0 = sys_now();
    while (!pred()) {
        poll_once();
        if ((u32_t)(sys_now() - t0) > timeout_ms) {
            return 0;
        }
    }
    return 1;
}

static void run_for(unsigned ms)
{
    u32_t t0 = sys_now();
    while ((u32_t)(sys_now() - t0) < ms) {
        poll_once();
    }
}

/* ---- scripted client ---- */

static void client_pump(client_t *c);

static err_t client_sent(void *arg, struct tcp_pcb *pcb, u16_t len)
{
    (void)pcb; (void)len;
    client_pump((client_t *)arg);
    return ERR_OK;
}

static err_t client_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    client_t *c = (client_t *)arg;
    int first = (c->rx_total == 0u);
    (void)err;
    if (p == NULL) {
        c->fin_seen = 1;
        if (!c->closed_local) {
            tcp_arg(pcb, NULL); tcp_recv(pcb, NULL); tcp_sent(pcb, NULL); tcp_err(pcb, NULL);
            (void)tcp_close(pcb);
            c->closed_local = 1;
        }
        return ERR_OK;
    }
    for (struct pbuf *q = p; q != NULL; q = q->next) {
        const uint8_t *d = (const uint8_t *)q->payload;
        for (u16_t i = 0; i < q->len; i++) {
            if (c->rx_total < sizeof(c->rx_first)) {
                c->rx_first[c->rx_total] = d[i];
            }
            if (c->rx_total >= c->rx_skip) {
                if (d[i] != (uint8_t)('0' + ((c->rx_total - c->rx_skip) % 10u))) {
                    c->pattern_err = 1;
                }
            }
            c->rx_total++;
        }
    }
    tcp_recved(pcb, p->tot_len);
    pbuf_free(p);
    if (first && c == &g_cl[0] && g_first_rx_hook != NULL) {
        void (*hook)(void) = g_first_rx_hook;
        g_first_rx_hook = NULL;
        hook(); /* lwIP's loopback netif runs a whole timed test inside one poll: act from the callback */
    }
    return ERR_OK;
}

static void client_err(void *arg, err_t err)
{
    client_t *c = (client_t *)arg;
    (void)err;
    c->err_seen = 1;
    c->pcb = NULL;
}

static err_t client_connected(void *arg, struct tcp_pcb *pcb, err_t err)
{
    client_t *c = (client_t *)arg;
    (void)pcb; (void)err;
    c->connected = 1;
    client_pump(c);
    return ERR_OK;
}

/* client_pump -- write the header (whole or one piece per call), then the pattern data, then the FIN. */
static void client_pump(client_t *c)
{
    struct tcp_pcb *pcb = c->pcb;
    if (pcb == NULL || c->closed_local) {
        return;
    }
    while (c->hdr_sent < c->hdr_len) {
        uint16_t n = (uint16_t)(c->hdr_len - c->hdr_sent);
        if (c->pieces[c->piece_idx] != 0u) {
            n = c->pieces[c->piece_idx++];
        }
        if (tcp_write(pcb, &c->hdr[c->hdr_sent], n, TCP_WRITE_FLAG_COPY) != ERR_OK) {
            return;
        }
        c->hdr_sent = (uint16_t)(c->hdr_sent + n);
        (void)tcp_output(pcb);
        if (c->pieces[0] != 0u) {
            return; /* next piece after this one is acknowledged: separate segments */
        }
    }
    while (c->data_sent < c->data_total) {
        uint32_t n = c->data_total - c->data_sent;
        if (n > 1460u) {
            n = 1460u;
        }
        if (tcp_sndbuf(pcb) < n) {
            break;
        }
        if (tcp_write(pcb, &g_pat[c->data_sent % 10u], (u16_t)n, 0) != ERR_OK) {
            break;
        }
        c->data_sent += n;
    }
    (void)tcp_output(pcb);
    if (c->close_when_done && c->data_sent >= c->data_total && tcp_sndqueuelen(pcb) == 0u) {
        tcp_arg(pcb, NULL); tcp_recv(pcb, NULL); tcp_sent(pcb, NULL); tcp_err(pcb, NULL);
        (void)tcp_close(pcb);
        c->closed_local = 1;
        c->fin_seen = 1; /* nothing is read back on a closed pcb */
    }
}

static void client_close(client_t *c)
{
    if (c->pcb != NULL && !c->closed_local) {
        tcp_arg(c->pcb, NULL); tcp_recv(c->pcb, NULL); tcp_sent(c->pcb, NULL); tcp_err(c->pcb, NULL);
        (void)tcp_close(c->pcb);
        c->closed_local = 1;
    }
}

static void put_be32(uint8_t *d, uint32_t v)
{
    d[0] = (uint8_t)(v >> 24); d[1] = (uint8_t)(v >> 16); d[2] = (uint8_t)(v >> 8); d[3] = (uint8_t)v;
}

/* client_start -- connect a scripted client; extended = the 64 byte header of iperf 2.2.2. */
static client_t *client_start(unsigned idx, uint32_t flags, uint16_t mport, int32_t amount, uint16_t upper,
                              int extended, uint32_t data_total, int close_when_done)
{
    client_t *c = &g_cl[idx];
    ip_addr_t lo;
    memset(c, 0, sizeof(*c));
    put_be32(&c->hdr[0], flags);
    put_be32(&c->hdr[4], 1u);
    put_be32(&c->hdr[8], mport);
    put_be32(&c->hdr[20], (uint32_t)amount);
    c->hdr_len = 24;
    if (extended) {
        static const uint8_t ver[8] = { 0x00, 0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x03 };
        c->hdr[32] = (uint8_t)(upper >> 8);
        c->hdr[33] = (uint8_t)upper;
        memcpy(&c->hdr[36], ver, sizeof(ver));
        c->hdr_len = 64;
    }
    c->data_total = data_total;
    c->close_when_done = close_when_done;
    c->pcb = tcp_new();
    tcp_nagle_disable(c->pcb);
    tcp_arg(c->pcb, c);
    tcp_recv(c->pcb, client_recv);
    tcp_sent(c->pcb, client_sent);
    tcp_err(c->pcb, client_err);
    IP4_ADDR(ip_2_ip4(&lo), 127, 0, 0, 1);
    IP_SET_TYPE_VAL(lo, IPADDR_TYPE_V4);
    CHECK(tcp_connect(c->pcb, &lo, SERVER_PORT, client_connected) == ERR_OK, "client connect");
    return c;
}

/* ---- the listener of the connect-back ---- */

static err_t back_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    return client_recv(arg, pcb, p, err);
}

static err_t back_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    (void)arg; (void)err;
    memset(&g_back, 0, sizeof(g_back));
    g_back.pcb = newpcb;
    g_back.rx_skip = 24u; /* the 24 byte test header the server writes first */
    tcp_arg(newpcb, &g_back);
    tcp_recv(newpcb, back_recv);
    tcp_err(newpcb, client_err);
    return ERR_OK;
}

static void back_listen_start(void)
{
    struct tcp_pcb *pcb = tcp_new();
    memset(&g_back, 0, sizeof(g_back));
    CHECK(tcp_bind(pcb, IP_ANY_TYPE, BACK_PORT) == ERR_OK, "bind connect-back listener");
    g_back_listen = tcp_listen(pcb);
    tcp_accept(g_back_listen, back_accept);
}

static void back_listen_stop(void)
{
    if (g_back_listen != NULL) {
        (void)tcp_close(g_back_listen);
        g_back_listen = NULL;
    }
}

/* ---- predicates ---- */

static unsigned g_want_reports;
static int p_reports(void)   { return g_nrep >= g_want_reports; }
static int p_cl0_fin(void)   { return g_cl[0].fin_seen || g_cl[0].err_seen; }
static int p_cl1_fin(void)   { return g_cl[1].fin_seen || g_cl[1].err_seen; }
static int p_back_fin(void)  { return g_back.fin_seen; }

static void hook_second_reverse(void)
{
    (void)client_start(1, FLAGS_REVERSE, SERVER_PORT, -100, UPPER_REVERSE, 1, 0u, 0);
}

static void hook_abort(void)
{
    rtlnet_lwiperf_abort(g_srv);
    g_srv = NULL;
}

static void reset_reports(void)
{
    memset(g_cl, 0, sizeof(g_cl));
    g_nrep = 0;
    memset(g_rep, 0, sizeof(g_rep));
}

static void wait_reports(unsigned n)
{
    g_want_reports = n;
    CHECK(run_until(p_reports, WAIT_MS), "reports arrive in time");
}

static void server_start(void)
{
    g_srv = rtlnet_lwiperf_start_tcp_server(IP_ANY_TYPE, SERVER_PORT, on_report, NULL);
    CHECK(g_srv != NULL, "server starts");
}

/* ---- scenarios ---- */

static void test_plain(void)
{
    const report_t *r;
    printf("plain, 64 byte header, 200000 bytes\n");
    reset_reports();
    (void)client_start(0, FLAGS_PLAIN, SERVER_PORT, -200, 0, 1, 200000u, 1);
    wait_reports(1);
    r = find_report(RTLNET_LWIPERF_DIR_RX, RTLNET_LWIPERF_TCP_DONE_SERVER);
    CHECK(r != NULL, "plain: DONE_SERVER report");
    CHECK(r != NULL && r->bytes == 200000u, "plain: payload count excludes the header");

    printf("plain, 24 byte header, 5000 bytes\n");
    reset_reports();
    (void)client_start(0, 0u, SERVER_PORT, -10, 0, 0, 5000u, 1);
    wait_reports(1);
    r = find_report(RTLNET_LWIPERF_DIR_RX, RTLNET_LWIPERF_TCP_DONE_SERVER);
    CHECK(r != NULL && r->bytes == 5000u, "legacy header: payload count");
}

static void test_reverse(void)
{
    const report_t *r;
    printf("reverse -R, 1.0 s\n");
    reset_reports();
    (void)client_start(0, FLAGS_REVERSE, SERVER_PORT, -100, UPPER_REVERSE, 1, 0u, 0);
    CHECK(run_until(p_cl0_fin, WAIT_MS), "reverse: server closes after the time");
    wait_reports(1);
    r = find_report(RTLNET_LWIPERF_DIR_REVERSE, RTLNET_LWIPERF_TCP_DONE_CLIENT);
    CHECK(r != NULL, "reverse: DONE_CLIENT report");
    CHECK(g_cl[0].rx_total > 100000u, "reverse: data flowed to the client");
    CHECK(!g_cl[0].pattern_err, "reverse: data pattern");
    CHECK(r != NULL && r->bytes == g_cl[0].rx_total, "reverse: reported bytes equal received bytes");
    CHECK(r != NULL && r->ms >= 1000u && r->ms < 1600u, "reverse: duration follows -t");

    printf("reverse -R, 300000 bytes (-n)\n");
    reset_reports();
    (void)client_start(0, FLAGS_REVERSE, SERVER_PORT, 300000, UPPER_REVERSE, 1, 0u, 0);
    CHECK(run_until(p_cl0_fin, WAIT_MS), "reverse -n: server closes");
    wait_reports(1);
    r = find_report(RTLNET_LWIPERF_DIR_REVERSE, RTLNET_LWIPERF_TCP_DONE_CLIENT);
    CHECK(r != NULL && r->bytes == 300000u, "reverse -n: exact byte count");
    CHECK(g_cl[0].rx_total == 300000u && !g_cl[0].pattern_err, "reverse -n: client got the bytes");

    printf("reverse -R, header in pieces\n");
    reset_reports();
    {
        client_t *c = client_start(0, FLAGS_REVERSE, SERVER_PORT, 20000, UPPER_REVERSE, 1, 0u, 0);
        c->pieces[0] = 3; c->pieces[1] = 1; c->pieces[2] = 20; c->pieces[3] = 1; c->pieces[4] = 39;
    }
    CHECK(run_until(p_cl0_fin, WAIT_MS), "pieces: server closes");
    wait_reports(1);
    r = find_report(RTLNET_LWIPERF_DIR_REVERSE, RTLNET_LWIPERF_TCP_DONE_CLIENT);
    CHECK(r != NULL && r->bytes == 20000u && g_cl[0].rx_total == 20000u, "pieces: reverse test ran");
}

static void test_tradeoff(void)
{
    const report_t *r;
    printf("tradeoff -r, 50000 bytes then connect-back 1.0 s\n");
    reset_reports();
    back_listen_start();
    (void)client_start(0, FLAGS_TRADEOFF, BACK_PORT, -100, 0, 1, 50000u, 1);
    g_want_reports = 2;
    CHECK(run_until(p_reports, WAIT_MS), "tradeoff: two reports");
    CHECK(run_until(p_back_fin, WAIT_MS), "tradeoff: connect-back ends");
    r = find_report(RTLNET_LWIPERF_DIR_RX, RTLNET_LWIPERF_TCP_DONE_SERVER);
    CHECK(r != NULL && r->bytes == 50000u, "tradeoff: receive half");
    r = find_report(RTLNET_LWIPERF_DIR_TRADEOFF, RTLNET_LWIPERF_TCP_DONE_CLIENT);
    CHECK(r != NULL, "tradeoff: connect-back report");
    CHECK(r != NULL && g_back.rx_total >= 24u && r->bytes == g_back.rx_total - 24u,
          "tradeoff: reported bytes equal received payload");
    CHECK(g_back.rx_total > 100000u, "tradeoff: data flowed");
    CHECK(!g_back.pattern_err, "tradeoff: data pattern");
    CHECK(r != NULL && r->ms >= 1000u && r->ms < 1600u, "tradeoff: duration follows the header");
    CHECK(g_back.rx_first[0] == 0u && g_back.rx_first[3] == 0u && g_back.rx_first[7] == 1u &&
          g_back.rx_first[10] == 0x14u && g_back.rx_first[11] == 0x51u, "tradeoff: connect-back header carries numThreads 1, mPort");
    back_listen_stop();
}

static void test_dual(void)
{
    const report_t *r;
    printf("dual -d, connect-back 1.0 s while the client sends\n");
    reset_reports();
    back_listen_start();
    (void)client_start(0, FLAGS_DUAL, BACK_PORT, -100, 0, 1, 20000u, 0);
    CHECK(run_until(p_back_fin, WAIT_MS), "dual: connect-back ends");
    wait_reports(1);
    r = find_report(RTLNET_LWIPERF_DIR_DUAL, RTLNET_LWIPERF_TCP_DONE_CLIENT);
    CHECK(r != NULL && g_back.rx_total >= 24u && r->bytes == g_back.rx_total - 24u, "dual: connect-back bytes");
    CHECK(!g_back.pattern_err && g_back.rx_total > 100000u, "dual: data pattern and volume");
    client_close(&g_cl[0]);
    wait_reports(2);
    r = find_report(RTLNET_LWIPERF_DIR_RX, RTLNET_LWIPERF_TCP_DONE_SERVER);
    CHECK(r != NULL && r->bytes == 20000u, "dual: receive half");
    back_listen_stop();
}

static void test_busy(void)
{
    printf("busy: second receive test refused\n");
    reset_reports();
    (void)client_start(0, FLAGS_PLAIN, SERVER_PORT, -200, 0, 1, 1000u, 0);
    run_for(200);
    (void)client_start(1, FLAGS_PLAIN, SERVER_PORT, -200, 0, 1, 1000u, 0);
    wait_reports(1);
    CHECK(find_report(RTLNET_LWIPERF_DIR_RX, RTLNET_LWIPERF_TCP_REJECTED_BUSY) != NULL, "busy: REJECTED_BUSY reported");
    CHECK(run_until(p_cl1_fin, WAIT_MS), "busy: refused client is closed");
    client_close(&g_cl[0]);
    wait_reports(2);
    CHECK(find_report(RTLNET_LWIPERF_DIR_RX, RTLNET_LWIPERF_TCP_DONE_SERVER) != NULL, "busy: first test completes");

    printf("busy: second reverse test refused\n");
    reset_reports();
    g_first_rx_hook = hook_second_reverse; /* the second test starts while the first one runs */
    (void)client_start(0, FLAGS_REVERSE, SERVER_PORT, -100, UPPER_REVERSE, 1, 0u, 0);
    CHECK(run_until(p_cl1_fin, WAIT_MS), "busy: second reverse test closed");
    CHECK(find_report(RTLNET_LWIPERF_DIR_REVERSE, RTLNET_LWIPERF_TCP_REJECTED_BUSY) != NULL, "busy: reverse refusal reported");
    CHECK(run_until(p_cl0_fin, WAIT_MS), "busy: first reverse test ends");
    wait_reports(2);
    CHECK(find_report(RTLNET_LWIPERF_DIR_REVERSE, RTLNET_LWIPERF_TCP_DONE_CLIENT) != NULL, "busy: first reverse test reported");
}

static void test_abort(void)
{
    printf("abort of a running reverse test, restart of the server\n");
    reset_reports();
    g_first_rx_hook = hook_abort; /* the abort comes while the test runs */
    (void)client_start(0, FLAGS_REVERSE, SERVER_PORT, -500, UPPER_REVERSE, 1, 0u, 0);
    CHECK(run_until(p_cl0_fin, WAIT_MS), "abort: client sees the close");
    CHECK(g_srv == NULL, "abort: hook ran");
    CHECK(g_nrep == 0u, "abort: no report");
    (void)client_start(1, FLAGS_PLAIN, SERVER_PORT, -200, 0, 1, 100u, 1);
    CHECK(run_until(p_cl1_fin, WAIT_MS) && g_cl[1].err_seen, "abort: port refuses connections");
    server_start();
    reset_reports();
    (void)client_start(0, FLAGS_PLAIN, SERVER_PORT, -200, 0, 1, 12345u, 1);
    wait_reports(1);
    CHECK(find_report(RTLNET_LWIPERF_DIR_RX, RTLNET_LWIPERF_TCP_DONE_SERVER) != NULL &&
          g_rep[0].bytes == 12345u, "abort: restarted server works");
}

int main(void)
{
    u32_t heap_start;
    lwip_init();
    heap_start = lwip_stats.mem.used;
    server_start();
    test_plain();
    test_reverse();
    test_tradeoff();
    test_dual();
    test_busy();
    test_abort();
    run_for(300);
    rtlnet_lwiperf_abort(g_srv);
    g_srv = NULL;
    run_for(300);
    CHECK(lwip_stats.mem.used == heap_start, "heap: every session state freed");
    if (lwip_stats.mem.used != heap_start) {
        printf("  heap used %u, at start %u\n", (unsigned)lwip_stats.mem.used, (unsigned)heap_start);
    }
    if (g_failed == 0u) {
        printf("LWIPERF_LOOPBACK: PASS checks=%u\n", g_checks);
        return 0;
    }
    printf("LWIPERF_LOOPBACK: FAIL %u check(s) failed\n", g_failed);
    return 1;
}
