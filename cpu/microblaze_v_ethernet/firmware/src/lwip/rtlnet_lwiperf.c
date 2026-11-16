/*
 * Copyright (c) 2014 Simon Goldschmidt
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT
 * SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
 * OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
 * OF SUCH DAMAGE.
 *
 * This file is part of the lwIP TCP/IP stack.
 *
 * Author: Simon Goldschmidt
 */

/*
 * Modified for RTLNet (10-22-2026): copy of lwIP 2.2.0 src/apps/lwiperf/lwiperf.c, extended so
 * the stock iperf 2.2.x Windows client can measure board -> PC traffic. Every change below is
 * tagged RTLNET-MOD where it sits (grep RTLNET-MOD is the complete deviation map).
 *  1. Public symbols renamed lwiperf_* -> rtlnet_lwiperf_*, LWIPERF_* -> RTLNET_LWIPERF_*; the
 *     options LWIPERF_TCP_MAX_IDLE_SEC / LWIPERF_SERVER_IP_TYPE / LWIPERF_ALLOC / LWIPERF_FREE
 *     keep their meaning under the new names. Include: "rtlnet_lwiperf.h".
 *  2. Server receive: the client test header is read across segments with the length the header
 *     announces (24 bytes legacy, 64 bytes extended, as measured with iperf 2.2.2); the
 *     "header again every 128 KiB" logic is removed (it aborted a running test when a segment
 *     boundary fell on the 128 KiB mark); payload bytes are counted without the header.
 *  3. Reverse mode (-R, iperf 2.1+): header flags VERSION2 and upperflags REVERSE make the server
 *     send on the client's own connection for the requested time or byte count, then close.
 *  4. Tradeoff (-r) and dual (-d): the server connects back to the client's address and the port
 *     of the header (mPort) and sends for the requested amount, after the client finished (-r)
 *     or at once (-d). The connect-back writes one 24-byte header (flags 0) and then data.
 *  5. Transmit: data comes from the static pattern buffer (no copy, no allocation), a segment is
 *     queued only when tcp_sndbuf() holds it, loops are bounded, the byte-limit test is
 *     corrected (the original closed a byte-limited test at once), the byte count is the
 *     acknowledged payload, and the test ends after the last byte is acknowledged.
 *  6. One test at a time per mode (receive, reverse, connect-back); a second one is refused and
 *     reported as RTLNET_LWIPERF_TCP_REJECTED_BUSY. Reports carry the direction.
 *  7. Fixes: the report reads stored addresses (the error callback had cleared conn_pcb, so the
 *     original dereferenced NULL); rtlnet_lwiperf_abort() closes the pcbs instead of only
 *     freeing the state (the original left pcbs with dangling callback arguments); the server
 *     start frees its state and pcb on every failure path and binds with SOF_REUSEADDR (a restart
 *     within two minutes of a test failed on the TIME_WAIT pcb of the old port); callbacks
 *     return ERR_ABRT when the pcb was aborted; the LWIPERF_CHECK_RX_DATA option is removed.
 */

/**
 * @file
 * lwIP iPerf server implementation
 */

/**
 * @defgroup iperf Iperf server
 * @ingroup apps
 *
 * This is a simple performance measuring client/server to check your bandwidth using
 * iPerf2 on a PC as server/client.
 * It is currently a minimal implementation providing a TCP client/server only.
 *
 * @todo:
 * - implement UDP mode
 * - protect combined sessions handling (via 'related_master_state') against reallocation
 *   (this is a pointer address, currently, so if the same memory is allocated again,
 *    session pairs (tx/rx) can be confused on reallocation)
 */

#include "rtlnet_lwiperf.h"

#include "lwip/tcp.h"
#include "lwip/sys.h"
#include "lwip/inet.h"

#include <string.h>

/* RTLNET-MOD: the firewall of the CPU path (src/rtlnet_firewall.h) is told which port the server listens on and
 * which client connections are open, so that it lets their traffic through. The desktop loopback test of this file
 * builds with RTLNET_LWIPERF_NO_FIREWALL: no firewall, the hooks are empty. */
#ifdef RTLNET_LWIPERF_NO_FIREWALL
#define FW_SVC_IPERF_TCP 1u
#define FW_SVC_IPERF_BACK 2u
#define RTLNET_LWIPERF_FW_SERVER(id, port, on)      ((void)0)
#define RTLNET_LWIPERF_FW_FLOW_ADD(rip, rport, lport)  ((void)0)
#define RTLNET_LWIPERF_FW_FLOW_REMOVE(rip, rport, lport) ((void)0)
#else
#include "rtlnet_firewall.h"
#define RTLNET_LWIPERF_FW_SERVER(id, port, on)      ((void)fw_service_set((id), FW_PROTO_TCP, (port), (on)))
#define RTLNET_LWIPERF_FW_FLOW_ADD(rip, rport, lport)  ((void)fw_flow_add(FW_PROTO_TCP, (rip), (rport), (lport)))
#define RTLNET_LWIPERF_FW_FLOW_REMOVE(rip, rport, lport) ((void)fw_flow_remove(FW_PROTO_TCP, (rip), (rport), (lport)))
#endif

/* Currently, only TCP is implemented */
#if LWIP_TCP && LWIP_CALLBACK_API

/** Specify the idle timeout (in seconds) after that the test fails */
#ifndef RTLNET_LWIPERF_TCP_MAX_IDLE_SEC
#define RTLNET_LWIPERF_TCP_MAX_IDLE_SEC    10U
#endif
#if RTLNET_LWIPERF_TCP_MAX_IDLE_SEC > 255
#error RTLNET_LWIPERF_TCP_MAX_IDLE_SEC must fit into an u8_t
#endif

/** Change this if you don't want to lwiperf to listen to any IP version */
#ifndef RTLNET_LWIPERF_SERVER_IP_TYPE
#define RTLNET_LWIPERF_SERVER_IP_TYPE      IPADDR_TYPE_ANY
#endif

/* File internal memory allocation (struct rtlnet_lwiperf_*): this defaults to
   the heap */
#ifndef RTLNET_LWIPERF_ALLOC
#define RTLNET_LWIPERF_ALLOC(type)         mem_malloc(sizeof(type))
#define RTLNET_LWIPERF_FREE(type, item)    mem_free(item)
#endif

/*
 * RTLNET-MOD: client test header (iperf 2.2.2 capture, all fields big-endian, byte offsets):
 *   0 flags, 4 numThreads, 8 mPort, 12 mBufLen, 16 mWinBand, 20 mAmount (negative: time in
 *   10 ms units; positive: bytes), 24..31 reserved, 32 upperflags (16 bit), then version words.
 * Drift consequence: a flag or offset that differs from the client's makes the server read the
 * wrong mode (a -R test would be taken as a plain receive test and no data would flow back).
 */
#define RTLNET_LWIPERF_FLAGS_ANSWER_TEST  0x80000000U /* header version 1: -r and -d */
#define RTLNET_LWIPERF_FLAGS_EXTEND       0x40000000U /* extended header follows the legacy 24 bytes */
#define RTLNET_LWIPERF_FLAGS_VERSION2     0x04000000U /* upperflags are valid */
#define RTLNET_LWIPERF_FLAGS_LEN_BIT      0x00010000U /* the low byte holds twice the header length */
#define RTLNET_LWIPERF_FLAGS_LEN_MASK     0x000000FEU
#define RTLNET_LWIPERF_FLAGS_ANSWER_NOW   0x00000001U /* with ANSWER_TEST: -d (at once) */
#define RTLNET_LWIPERF_UPPER_REVERSE      0x0400U     /* upperflags: -R */
#define RTLNET_LWIPERF_HDR_LEGACY_LEN     24U         /* legacy header, also the connect-back header */
#define RTLNET_LWIPERF_HDR_UPPER_OFS      32U         /* upperflags */
#define RTLNET_LWIPERF_HDR_KEEP           36U         /* header bytes kept for parsing */

/** RTLNET-MOD: bounds */
#define RTLNET_LWIPERF_TX_LOOP_MAX        16U         /* tcp_write calls per callback */
#define RTLNET_LWIPERF_ABORT_MAX          64U         /* sessions closed by one abort call */
#define RTLNET_LWIPERF_DEFAULT_AMOUNT     ((u32_t)-1000) /* iperf default: -t 10 (10 ms units) */

/** RTLNET-MOD: test slots, one test at a time per slot */
#define RTLNET_LWIPERF_SLOT_RX            0U
#define RTLNET_LWIPERF_SLOT_REVERSE       1U
#define RTLNET_LWIPERF_SLOT_CONNECT_BACK  2U
#define RTLNET_LWIPERF_SLOT_COUNT         3U
#define RTLNET_LWIPERF_SLOT_NONE          RTLNET_LWIPERF_SLOT_COUNT

/** RTLNET-MOD: what a function did to the session it was given */
typedef enum {
  RTLNET_LWIPERF_ALIVE = 0, /* session still open */
  RTLNET_LWIPERF_GONE,      /* session closed and freed; pcb closed */
  RTLNET_LWIPERF_ABRT       /* session closed and freed; pcb aborted (callbacks return ERR_ABRT) */
} rtlnet_lwiperf_life_t;

/** Basic connection handle */
struct _rtlnet_lwiperf_state_base;
typedef struct _rtlnet_lwiperf_state_base rtlnet_lwiperf_state_base_t;
struct _rtlnet_lwiperf_state_base {
  /* linked list */
  rtlnet_lwiperf_state_base_t *next;
  /* 1=tcp, 0=udp */
  u8_t tcp;
  /* 1=server, 0=client */
  u8_t server;
  /* master state used to abort sessions (e.g. listener, main client) */
  rtlnet_lwiperf_state_base_t *related_master_state;
};

/** Connection handle for a TCP iperf session */
typedef struct _rtlnet_lwiperf_state_tcp {
  rtlnet_lwiperf_state_base_t base;
  struct tcp_pcb *server_pcb;
  struct tcp_pcb *conn_pcb;
  u32_t time_started;
  rtlnet_lwiperf_report_fn report_fn;
  void *report_arg;
  u8_t poll_count;
  /* 1=start server when client is closed */
  u8_t client_tradeoff_mode;
  u8_t specific_remote;
  u32_t bytes_transferred;
  /* RTLNET-MOD: the fields below */
  u8_t dir;            /* enum rtlnet_lwiperf_direction */
  u8_t slot;           /* test slot owned, RTLNET_LWIPERF_SLOT_NONE if none */
  u8_t have_header;    /* receive: the whole client header was read */
  u8_t hdr_len;        /* receive: header length, 0 until the flags word is in */
  u8_t hdr_got;        /* receive: header bytes read */
  u8_t tx;             /* 1 = this connection sends the test data */
  u8_t tx_stop;        /* all requested data was queued */
  u8_t tx_hdr_len;     /* header bytes written before the data (0 or 24) */
  u32_t tx_queued;     /* header and data bytes handed to tcp_write */
  u32_t tx_acked;      /* header and data bytes acknowledged by the peer */
  u32_t flags;         /* receive: header flags; transmit: flags written in the header */
  u32_t amount;        /* header mAmount, host order: negative = time in 10 ms, positive = bytes */
  u16_t rport;         /* header mPort: the port the connect-back goes to */
  u16_t local_port;    /* addresses kept for the report: the pcb may be gone by then */
  u16_t remote_port;
  ip_addr_t local_addr;
  ip_addr_t remote_addr;
  u8_t hdr[RTLNET_LWIPERF_HDR_KEEP];
  u8_t fw_flow;        /* the firewall holds the client flow of this connection (fw_lport, remote_addr, remote_port) */
  u8_t fw_server;      /* firewall service id + 1 when this listener is registered (main server or connect-back), else 0 */
  u16_t fw_lport;      /* local port of the client connection / port of the listener */
} rtlnet_lwiperf_state_tcp_t;

/** List of active iperf sessions */
static rtlnet_lwiperf_state_base_t *rtlnet_lwiperf_all_connections;
/** RTLNET-MOD: the session that owns each test slot, NULL when free */
static rtlnet_lwiperf_state_tcp_t *rtlnet_lwiperf_slot_owner[RTLNET_LWIPERF_SLOT_COUNT];

/* RTLNET-MOD: the pattern, "0123456789" repeated, as a macro so the table stays short. */
#define RTLNET_LWIPERF_P10  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'
#define RTLNET_LWIPERF_P100 RTLNET_LWIPERF_P10, RTLNET_LWIPERF_P10, RTLNET_LWIPERF_P10, RTLNET_LWIPERF_P10, \
                            RTLNET_LWIPERF_P10, RTLNET_LWIPERF_P10, RTLNET_LWIPERF_P10, RTLNET_LWIPERF_P10, \
                            RTLNET_LWIPERF_P10, RTLNET_LWIPERF_P10

/* RTLNET-MOD: data segments by reference (ROM pbuf, no copy) build a chain of a header pbuf and a payload reference, which
 * the DMA netif cannot send in place (simple-mode DMA, one contiguous buffer): every frame is copied into a transmit buffer.
 * With the frame buffer RAM heap (RTLNET_NETIF_ZERO_COPY_TX) the data is copied once, by tcp_write, into one contiguous
 * pbuf in that RAM, and the frame is sent from there; this is also what an application that owns its data does.
 * The small-memory profile keeps the reference (its heap is too small to hold a full send queue of copies). */
#ifndef RTLNET_LWIPERF_TX_COPY
#if defined(RTLNET_NETIF_ZERO_COPY_TX) && RTLNET_NETIF_ZERO_COPY_TX && !defined(RTLNET_SMALL_MEM)
#define RTLNET_LWIPERF_TX_COPY             1
#else
#define RTLNET_LWIPERF_TX_COPY             0
#endif
#endif

/** A const buffer to send from: we want to measure sending, not copying! */
static const u8_t rtlnet_lwiperf_txbuf_const[1600] = {
  RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100,
  RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100,
  RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100,
  RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100, RTLNET_LWIPERF_P100
};
#if (TCP_MSS + 9) > 1600
#error RTLNET-MOD: rtlnet_lwiperf_txbuf_const holds less than one segment plus the pattern phase
#endif

static err_t rtlnet_lwiperf_tcp_poll(void *arg, struct tcp_pcb *tpcb);
static void rtlnet_lwiperf_tcp_err(void *arg, err_t err);
static err_t rtlnet_lwiperf_start_tcp_server_impl(const ip_addr_t *local_addr, u16_t local_port,
                                           rtlnet_lwiperf_report_fn report_fn, void *report_arg,
                                           rtlnet_lwiperf_state_base_t *related_master_state, rtlnet_lwiperf_state_tcp_t **state);


/** RTLNET-MOD: life status of a session as the callback return value */
static err_t
rtlnet_lwiperf_life_err(rtlnet_lwiperf_life_t life)
{
  return (life == RTLNET_LWIPERF_ABRT) ? ERR_ABRT : ERR_OK;
}

/** RTLNET-MOD: read a big-endian 32 bit value (the one unpack helper) */
static u32_t
rtlnet_lwiperf_get_be32(const u8_t *src)
{
  return ((u32_t)src[0] << 24) | ((u32_t)src[1] << 16) | ((u32_t)src[2] << 8) | (u32_t)src[3];
}

/** RTLNET-MOD: write a big-endian 32 bit value (the one pack helper) */
static void
rtlnet_lwiperf_put_be32(u8_t *dst, u32_t value)
{
  dst[0] = (u8_t)(value >> 24);
  dst[1] = (u8_t)(value >> 16);
  dst[2] = (u8_t)(value >> 8);
  dst[3] = (u8_t)value;
}

/** Add an iperf session to the 'active' list */
static void
rtlnet_lwiperf_list_add(rtlnet_lwiperf_state_base_t *item)
{
  item->next = rtlnet_lwiperf_all_connections;
  rtlnet_lwiperf_all_connections = item;
}

/** Remove an iperf session from the 'active' list */
static void
rtlnet_lwiperf_list_remove(rtlnet_lwiperf_state_base_t *item)
{
  rtlnet_lwiperf_state_base_t *prev = NULL;
  rtlnet_lwiperf_state_base_t *iter;
  for (iter = rtlnet_lwiperf_all_connections; iter != NULL; prev = iter, iter = iter->next) {
    if (iter == item) {
      if (prev == NULL) {
        rtlnet_lwiperf_all_connections = iter->next;
      } else {
        prev->next = iter->next;
      }
      /* @debug: ensure this item is listed only once */
      for (iter = iter->next; iter != NULL; iter = iter->next) {
        LWIP_ASSERT("duplicate entry", iter != item);
      }
      break;
    }
  }
}

static rtlnet_lwiperf_state_base_t *
rtlnet_lwiperf_list_find(rtlnet_lwiperf_state_base_t *item)
{
  rtlnet_lwiperf_state_base_t *iter;
  for (iter = rtlnet_lwiperf_all_connections; iter != NULL; iter = iter->next) {
    if (iter == item) {
      return item;
    }
  }
  return NULL;
}

/** RTLNET-MOD: claim a test slot for a session; 0 when another session owns it */
static int
rtlnet_lwiperf_slot_claim(rtlnet_lwiperf_state_tcp_t *conn, u8_t slot)
{
  if (slot >= RTLNET_LWIPERF_SLOT_COUNT) {
    return 1;
  }
  if (rtlnet_lwiperf_slot_owner[slot] != NULL) {
    return 0;
  }
  rtlnet_lwiperf_slot_owner[slot] = conn;
  conn->slot = slot;
  return 1;
}

/** RTLNET-MOD: give the slot of a session back */
static void
rtlnet_lwiperf_slot_release(rtlnet_lwiperf_state_tcp_t *conn)
{
  if (conn->slot < RTLNET_LWIPERF_SLOT_COUNT && rtlnet_lwiperf_slot_owner[conn->slot] == conn) {
    rtlnet_lwiperf_slot_owner[conn->slot] = NULL;
  }
  conn->slot = RTLNET_LWIPERF_SLOT_NONE;
}

/** RTLNET-MOD: average bandwidth in kbit/s without 64 bit arithmetic */
static u32_t
rtlnet_lwiperf_kbps(u32_t bytes, u32_t duration_ms)
{
  if (duration_ms == 0) {
    return 0;
  }
  /* bytes/ms*8 = kbit/s; the remainder term keeps the fraction (bytes % ms < ms, times 8 fits) */
  return ((bytes / duration_ms) * 8U) + (((bytes % duration_ms) * 8U) / duration_ms);
}

/** Call the report function of an iperf tcp session */
static void
rtlnet_lwip_tcp_conn_report(rtlnet_lwiperf_state_tcp_t *conn, enum rtlnet_lwiperf_report_type report_type)
{
  if ((conn != NULL) && (conn->report_fn != NULL)) {
    u32_t now, duration_ms;
    now = sys_now();
    duration_ms = now - conn->time_started;
    /* RTLNET-MOD: reports from the stored addresses, the pcb may be gone */
    conn->report_fn(conn->report_arg, report_type, (enum rtlnet_lwiperf_direction)conn->dir,
                    &conn->local_addr, conn->local_port,
                    &conn->remote_addr, conn->remote_port,
                    conn->bytes_transferred, duration_ms, rtlnet_lwiperf_kbps(conn->bytes_transferred, duration_ms));
  }
}

/** Close an iperf tcp session; the session is freed */
static rtlnet_lwiperf_life_t
rtlnet_lwiperf_tcp_close(rtlnet_lwiperf_state_tcp_t *conn, enum rtlnet_lwiperf_report_type report_type)
{
  err_t err;
  rtlnet_lwiperf_life_t life = RTLNET_LWIPERF_GONE;

  rtlnet_lwiperf_list_remove(&conn->base);
  rtlnet_lwiperf_slot_release(conn);
  rtlnet_lwip_tcp_conn_report(conn, report_type);
  if (conn->fw_flow) {
    RTLNET_LWIPERF_FW_FLOW_REMOVE(lwip_ntohl(ip4_addr_get_u32(ip_2_ip4(&conn->remote_addr))), conn->remote_port,
                                  conn->fw_lport);
    conn->fw_flow = 0;
  }
  if (conn->fw_server) {
    RTLNET_LWIPERF_FW_SERVER((unsigned)conn->fw_server - 1u, conn->fw_lport, 0);
    conn->fw_server = 0;
  }
  if (conn->conn_pcb != NULL) {
    tcp_arg(conn->conn_pcb, NULL);
    tcp_poll(conn->conn_pcb, NULL, 0);
    tcp_sent(conn->conn_pcb, NULL);
    tcp_recv(conn->conn_pcb, NULL);
    tcp_err(conn->conn_pcb, NULL);
    err = tcp_close(conn->conn_pcb);
    if (err != ERR_OK) {
      /* don't want to wait for free memory here... */
      tcp_abort(conn->conn_pcb);
      life = RTLNET_LWIPERF_ABRT; /* RTLNET-MOD */
    }
  } else if (conn->server_pcb != NULL) {
    /* no conn pcb, this is the listener pcb */
    err = tcp_close(conn->server_pcb);
    LWIP_ASSERT("error", err == ERR_OK);
  }
  RTLNET_LWIPERF_FREE(rtlnet_lwiperf_state_tcp_t, conn);
  return life;
}

/**
 * RTLNET-MOD: true when the requested time has passed or the requested bytes are queued.
 * mAmount negative: time in 10 ms units; positive: payload bytes.
 */
static int
rtlnet_lwiperf_tx_finished(const rtlnet_lwiperf_state_tcp_t *conn)
{
  if ((conn->amount & 0x80000000U) != 0U) {
    u32_t time_ms = (u32_t)(0U - conn->amount) * 10U;
    return (sys_now() - conn->time_started) >= time_ms;
  }
  return (conn->tx_queued - conn->tx_hdr_len) >= conn->amount;
}

/**
 * RTLNET-MOD: send more on a transmitting session (reverse reply or connect-back or client).
 * Flow control: nothing is written unless tcp_sndbuf() holds the whole chunk; a full buffer is
 * resumed from the sent callback (on every acknowledgement) and from the poll callback.
 * When the requested amount is queued and acknowledged the session is closed and reported.
 */
static rtlnet_lwiperf_life_t
rtlnet_lwiperf_tcp_tx_more(rtlnet_lwiperf_state_tcp_t *conn)
{
  struct tcp_pcb *pcb = conn->conn_pcb;
  u8_t hdr[RTLNET_LWIPERF_HDR_LEGACY_LEN];
  const void *txptr;
  u16_t len;
  u8_t loops;
  u8_t apiflags;
  err_t err;

  for (loops = 0; (conn->tx_stop == 0) && (loops < RTLNET_LWIPERF_TX_LOOP_MAX); loops++) {
    if (rtlnet_lwiperf_tx_finished(conn)) {
      conn->tx_stop = 1;
      break;
    }
    if (conn->tx_queued < conn->tx_hdr_len) {
      /* the test header first: flags, numThreads, mPort, mBufLen, mWinBand, mAmount */
      memset(hdr, 0, sizeof(hdr));
      rtlnet_lwiperf_put_be32(&hdr[0], conn->flags);
      rtlnet_lwiperf_put_be32(&hdr[4], 1U);
      rtlnet_lwiperf_put_be32(&hdr[8], (u32_t)conn->rport);
      rtlnet_lwiperf_put_be32(&hdr[20], conn->amount);
      len = (u16_t)(conn->tx_hdr_len - conn->tx_queued);
      txptr = &hdr[conn->tx_queued];
      apiflags = TCP_WRITE_FLAG_COPY | TCP_WRITE_FLAG_MORE;
    } else {
      u32_t sent = conn->tx_queued - conn->tx_hdr_len;
      len = TCP_MSS;
      if (((conn->amount & 0x80000000U) == 0U) && ((conn->amount - sent) < (u32_t)len)) {
        len = (u16_t)(conn->amount - sent); /* last chunk of a byte-limited test */
      }
      txptr = &rtlnet_lwiperf_txbuf_const[sent % 10U];
      apiflags = RTLNET_LWIPERF_TX_COPY ? TCP_WRITE_FLAG_COPY : 0; /* RTLNET-MOD: see RTLNET_LWIPERF_TX_COPY */
    }
    if (tcp_sndbuf(pcb) < len) {
      break; /* wait for acknowledgements */
    }
    err = tcp_write(pcb, txptr, len, apiflags);
    if (err == ERR_MEM) {
      break; /* try again from the next sent or poll callback */
    }
    if (err != ERR_OK) {
      return rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_ABORTED_LOCAL_TXERROR);
    }
    conn->tx_queued += len;
  }
  (void)tcp_output(pcb); /* a transient failure is retried from the sent and poll callbacks */
  if ((conn->tx_stop != 0) && (tcp_sndqueuelen(pcb) == 0)) {
    /* everything is acknowledged: the test is over */
    return rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_DONE_CLIENT);
  }
  return RTLNET_LWIPERF_ALIVE;
}

/** TCP sent callback, try to send more data */
static err_t
rtlnet_lwiperf_tcp_client_sent(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
  rtlnet_lwiperf_state_tcp_t *conn = (rtlnet_lwiperf_state_tcp_t *)arg;
  LWIP_ASSERT("invalid conn", conn->conn_pcb == tpcb);
  LWIP_UNUSED_ARG(tpcb);

  conn->poll_count = 0;
  /* RTLNET-MOD: the transferred bytes are the acknowledged payload, the test header excluded */
  conn->tx_acked += len;
  conn->bytes_transferred = (conn->tx_acked > conn->tx_hdr_len) ? (conn->tx_acked - conn->tx_hdr_len) : 0U;

  return rtlnet_lwiperf_life_err(rtlnet_lwiperf_tcp_tx_more(conn));
}

/** TCP connected callback (active connection), send data now */
static err_t
rtlnet_lwiperf_tcp_client_connected(void *arg, struct tcp_pcb *tpcb, err_t err)
{
  rtlnet_lwiperf_state_tcp_t *conn = (rtlnet_lwiperf_state_tcp_t *)arg;
  LWIP_ASSERT("invalid conn", conn->conn_pcb == tpcb);
  LWIP_UNUSED_ARG(tpcb);
  if (err != ERR_OK) {
    return rtlnet_lwiperf_life_err(rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_ABORTED_REMOTE));
  }
  conn->poll_count = 0;
  conn->time_started = sys_now();
  ip_addr_copy(conn->local_addr, tpcb->local_ip); /* RTLNET-MOD */
  conn->local_port = tpcb->local_port;
  return rtlnet_lwiperf_life_err(rtlnet_lwiperf_tcp_tx_more(conn));
}

/**
 * RTLNET-MOD: refusal report of a test that never got a session (no memory, slot busy).
 */
static void
rtlnet_lwiperf_report_failed(rtlnet_lwiperf_report_fn report_fn, void *report_arg,
                             enum rtlnet_lwiperf_report_type report_type, enum rtlnet_lwiperf_direction dir,
                             const ip_addr_t *remote_ip, u16_t remote_port)
{
  if (report_fn != NULL) {
    ip_addr_t none;
    ip_addr_set_zero(&none);
    report_fn(report_arg, report_type, dir, &none, 0, remote_ip, remote_port, 0, 0, 0);
  }
}

/** Start TCP connection back to the client (either parallel or after the
 * receive test has finished.
 * RTLNET-MOD: takes the fields it needs instead of the received settings, so it can run after the
 * receiving session is freed. hdr_flags go in the 24-byte header written first; slot is the test
 * slot to own (RTLNET_LWIPERF_SLOT_NONE for none).
 */
static err_t
rtlnet_lwiperf_tx_start_impl(const ip_addr_t *remote_ip, u16_t remote_port, u32_t amount, u32_t hdr_flags,
                      enum rtlnet_lwiperf_direction dir, u8_t slot, rtlnet_lwiperf_report_fn report_fn,
                      void *report_arg, rtlnet_lwiperf_state_base_t *related_master_state, rtlnet_lwiperf_state_tcp_t **new_conn)
{
  err_t err;
  rtlnet_lwiperf_state_tcp_t *client_conn;
  struct tcp_pcb *newpcb;
  ip_addr_t remote_addr;

  LWIP_ASSERT("remote_ip != NULL", remote_ip != NULL);
  LWIP_ASSERT("new_conn != NULL", new_conn != NULL);
  *new_conn = NULL;

  if (remote_port == 0) {
    remote_port = RTLNET_LWIPERF_TCP_PORT_DEFAULT; /* RTLNET-MOD */
  }
  if ((slot < RTLNET_LWIPERF_SLOT_COUNT) && (rtlnet_lwiperf_slot_owner[slot] != NULL)) {
    rtlnet_lwiperf_report_failed(report_fn, report_arg, RTLNET_LWIPERF_TCP_REJECTED_BUSY, dir, remote_ip, remote_port);
    return ERR_INPROGRESS;
  }
  client_conn = (rtlnet_lwiperf_state_tcp_t *)RTLNET_LWIPERF_ALLOC(rtlnet_lwiperf_state_tcp_t);
  if (client_conn == NULL) {
    rtlnet_lwiperf_report_failed(report_fn, report_arg, RTLNET_LWIPERF_TCP_ABORTED_LOCAL_TXERROR, dir, remote_ip, remote_port);
    return ERR_MEM;
  }
  newpcb = tcp_new_ip_type(IP_GET_TYPE(remote_ip));
  if (newpcb == NULL) {
    RTLNET_LWIPERF_FREE(rtlnet_lwiperf_state_tcp_t, client_conn);
    rtlnet_lwiperf_report_failed(report_fn, report_arg, RTLNET_LWIPERF_TCP_ABORTED_LOCAL_TXERROR, dir, remote_ip, remote_port);
    return ERR_MEM;
  }
  memset(client_conn, 0, sizeof(rtlnet_lwiperf_state_tcp_t));
  client_conn->base.tcp = 1;
  client_conn->base.related_master_state = related_master_state;
  client_conn->conn_pcb = newpcb;
  client_conn->time_started = sys_now(); /* set again on 'connected' */
  client_conn->report_fn = report_fn;
  client_conn->report_arg = report_arg;
  client_conn->bytes_transferred = 0;
  /* RTLNET-MOD */
  client_conn->dir = (u8_t)dir;
  client_conn->slot = RTLNET_LWIPERF_SLOT_NONE;
  client_conn->tx = 1;
  client_conn->tx_hdr_len = (u8_t)RTLNET_LWIPERF_HDR_LEGACY_LEN;
  client_conn->flags = hdr_flags;
  client_conn->amount = (amount != 0U) ? amount : RTLNET_LWIPERF_DEFAULT_AMOUNT;
  client_conn->rport = remote_port;
  client_conn->remote_port = remote_port;
  ip_addr_copy(client_conn->remote_addr, *remote_ip);
  (void)rtlnet_lwiperf_slot_claim(client_conn, slot);

  tcp_arg(newpcb, client_conn);
  tcp_sent(newpcb, rtlnet_lwiperf_tcp_client_sent);
  tcp_poll(newpcb, rtlnet_lwiperf_tcp_poll, 2U);
  tcp_err(newpcb, rtlnet_lwiperf_tcp_err);

  ip_addr_copy(remote_addr, *remote_ip);

  err = tcp_connect(newpcb, &remote_addr, remote_port, rtlnet_lwiperf_tcp_client_connected);
  if (err != ERR_OK) {
    (void)rtlnet_lwiperf_tcp_close(client_conn, RTLNET_LWIPERF_TCP_ABORTED_LOCAL);
    return err;
  }
  /* RTLNET-MOD: the local port is known now and the SYN-ACK is processed from the main loop later: let the
     firewall pass the reply traffic (removed again in rtlnet_lwiperf_tcp_close, on a close or an error) */
  client_conn->fw_lport = newpcb->local_port;
  client_conn->fw_flow = 1;
  RTLNET_LWIPERF_FW_FLOW_ADD(lwip_ntohl(ip4_addr_get_u32(ip_2_ip4(&remote_addr))), remote_port, newpcb->local_port);
  rtlnet_lwiperf_list_add(&client_conn->base);
  *new_conn = client_conn;
  return ERR_OK;
}

/**
 * RTLNET-MOD: take the client test header bytes out of a received pbuf. The length of the header
 * is known after its flags word (4 bytes); the first RTLNET_LWIPERF_HDR_KEEP bytes are kept.
 * Returns: the number of bytes of p that belong to the header.
 */
static u16_t
rtlnet_lwiperf_rx_take_header(rtlnet_lwiperf_state_tcp_t *conn, const struct pbuf *p)
{
  u16_t used = 0;
  u16_t n;

  if (conn->hdr_len == 0) {
    n = (u16_t)(4U - conn->hdr_got);
    if (n > p->tot_len) {
      n = p->tot_len;
    }
    if (pbuf_copy_partial(p, &conn->hdr[conn->hdr_got], n, 0) != n) {
      return used;
    }
    conn->hdr_got = (u8_t)(conn->hdr_got + n);
    used = n;
    if (conn->hdr_got == 4U) {
      u32_t flags = rtlnet_lwiperf_get_be32(conn->hdr);
      u32_t len = RTLNET_LWIPERF_HDR_LEGACY_LEN;
      if (((flags & RTLNET_LWIPERF_FLAGS_EXTEND) != 0U) && ((flags & RTLNET_LWIPERF_FLAGS_LEN_BIT) != 0U)) {
        u32_t announced = (flags & RTLNET_LWIPERF_FLAGS_LEN_MASK) >> 1;
        if (announced >= RTLNET_LWIPERF_HDR_LEGACY_LEN) {
          len = announced;
        }
      }
      conn->hdr_len = (u8_t)len;
    }
  }
  if ((conn->hdr_len != 0) && (conn->hdr_got < conn->hdr_len)) {
    u16_t left = (u16_t)(p->tot_len - used);
    n = (u16_t)(conn->hdr_len - conn->hdr_got);
    if (n > left) {
      n = left;
    }
    if (conn->hdr_got < RTLNET_LWIPERF_HDR_KEEP) {
      u16_t keep = (u16_t)(RTLNET_LWIPERF_HDR_KEEP - conn->hdr_got);
      if (keep > n) {
        keep = n;
      }
      if (pbuf_copy_partial(p, &conn->hdr[conn->hdr_got], keep, used) != keep) {
        return used;
      }
    }
    conn->hdr_got = (u8_t)(conn->hdr_got + n);
    used = (u16_t)(used + n);
  }
  if ((conn->hdr_len != 0) && (conn->hdr_got >= conn->hdr_len)) {
    conn->have_header = 1;
  }
  return used;
}

/**
 * RTLNET-MOD: the client header is complete: decide the mode (receive, reverse), claim its slot
 * and start what the header asks for (the reverse reply, or the connect-back of -d).
 */
static rtlnet_lwiperf_life_t
rtlnet_lwiperf_rx_header_done(rtlnet_lwiperf_state_tcp_t *conn)
{
  u32_t flags = rtlnet_lwiperf_get_be32(&conn->hdr[0]);
  int reverse = 0;

  conn->flags = flags;
  conn->rport = (u16_t)(rtlnet_lwiperf_get_be32(&conn->hdr[8]) & 0xFFFFU);
  conn->amount = rtlnet_lwiperf_get_be32(&conn->hdr[20]);
  if (conn->amount == 0U) {
    conn->amount = RTLNET_LWIPERF_DEFAULT_AMOUNT;
  }
  if ((conn->hdr_len >= (RTLNET_LWIPERF_HDR_UPPER_OFS + 2U)) &&
      ((flags & RTLNET_LWIPERF_FLAGS_EXTEND) != 0U) && ((flags & RTLNET_LWIPERF_FLAGS_VERSION2) != 0U)) {
    u32_t upper = ((u32_t)conn->hdr[RTLNET_LWIPERF_HDR_UPPER_OFS] << 8) | (u32_t)conn->hdr[RTLNET_LWIPERF_HDR_UPPER_OFS + 1U];
    reverse = ((upper & RTLNET_LWIPERF_UPPER_REVERSE) != 0U);
  }
  conn->time_started = sys_now();
  conn->dir = reverse ? (u8_t)RTLNET_LWIPERF_DIR_REVERSE : (u8_t)RTLNET_LWIPERF_DIR_RX;
  if (!rtlnet_lwiperf_slot_claim(conn, reverse ? RTLNET_LWIPERF_SLOT_REVERSE : RTLNET_LWIPERF_SLOT_RX)) {
    return rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_REJECTED_BUSY);
  }
  if (reverse) {
    /* send the test data on this connection; the client sends nothing more */
    conn->tx = 1;
    conn->tx_hdr_len = 0;
    tcp_sent(conn->conn_pcb, rtlnet_lwiperf_tcp_client_sent);
    return rtlnet_lwiperf_tcp_tx_more(conn);
  }
  if (((flags & RTLNET_LWIPERF_FLAGS_ANSWER_TEST) != 0U) && ((flags & RTLNET_LWIPERF_FLAGS_ANSWER_NOW) != 0U)) {
    /* client requested parallel transmission test */
    rtlnet_lwiperf_state_tcp_t *new_conn = NULL;
    err_t err = rtlnet_lwiperf_tx_start_impl(&conn->remote_addr, conn->rport, conn->amount, 0U, RTLNET_LWIPERF_DIR_DUAL,
                                      RTLNET_LWIPERF_SLOT_CONNECT_BACK, conn->report_fn, conn->report_arg,
                                      conn->base.related_master_state, &new_conn);
    if (err != ERR_OK) {
      return rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_ABORTED_LOCAL_TXERROR);
    }
  }
  return RTLNET_LWIPERF_ALIVE;
}

/** Receive data on an iperf tcp session */
static err_t
rtlnet_lwiperf_tcp_recv(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
  u16_t tot_len;
  u16_t used = 0;
  rtlnet_lwiperf_life_t life = RTLNET_LWIPERF_ALIVE;
  rtlnet_lwiperf_state_tcp_t *conn = (rtlnet_lwiperf_state_tcp_t *)arg;

  LWIP_ASSERT("pcb mismatch", conn->conn_pcb == tpcb);
  LWIP_UNUSED_ARG(tpcb);

  if (err != ERR_OK) {
    if (p != NULL) {
      pbuf_free(p);
    }
    return rtlnet_lwiperf_life_err(rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_ABORTED_REMOTE));
  }
  if (p == NULL) {
    /* connection closed -> test done */
    if (conn->tx) {
      /* RTLNET-MOD: reverse test: the client closed its sending half, the reply continues */
      return ERR_OK;
    }
    if (!conn->have_header) {
      return rtlnet_lwiperf_life_err(rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_ABORTED_LOCAL_DATAERROR));
    }
    if (((conn->flags & RTLNET_LWIPERF_FLAGS_ANSWER_TEST) != 0U) && ((conn->flags & RTLNET_LWIPERF_FLAGS_ANSWER_NOW) == 0U)) {
      /* client requested transmission after end of test */
      rtlnet_lwiperf_state_tcp_t *new_conn = NULL;
      (void)rtlnet_lwiperf_tx_start_impl(&conn->remote_addr, conn->rport, conn->amount, 0U, RTLNET_LWIPERF_DIR_TRADEOFF,
                                  RTLNET_LWIPERF_SLOT_CONNECT_BACK, conn->report_fn, conn->report_arg,
                                  conn->base.related_master_state, &new_conn);
    }
    return rtlnet_lwiperf_life_err(rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_DONE_SERVER));
  }
  tot_len = p->tot_len;

  conn->poll_count = 0;
  tcp_recved(tpcb, tot_len); /* RTLNET-MOD: before any close, so a refused test is not reset */

  if (!conn->have_header) {
    used = rtlnet_lwiperf_rx_take_header(conn, p);
    if (conn->have_header) {
      life = rtlnet_lwiperf_rx_header_done(conn);
    }
  }
  if ((life == RTLNET_LWIPERF_ALIVE) && !conn->tx && conn->have_header) {
    conn->bytes_transferred += (u32_t)(tot_len - used);
  }
  pbuf_free(p);
  return rtlnet_lwiperf_life_err(life);
}

/** Error callback, iperf tcp session aborted */
static void
rtlnet_lwiperf_tcp_err(void *arg, err_t err)
{
  rtlnet_lwiperf_state_tcp_t *conn = (rtlnet_lwiperf_state_tcp_t *)arg;
  LWIP_UNUSED_ARG(err);

  /* pcb is already deallocated, prevent double-free */
  conn->conn_pcb = NULL;
  conn->server_pcb = NULL;

  (void)rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_ABORTED_REMOTE);
}

/** TCP poll callback, try to send more data */
static err_t
rtlnet_lwiperf_tcp_poll(void *arg, struct tcp_pcb *tpcb)
{
  rtlnet_lwiperf_state_tcp_t *conn = (rtlnet_lwiperf_state_tcp_t *)arg;
  LWIP_ASSERT("pcb mismatch", conn->conn_pcb == tpcb);
  LWIP_UNUSED_ARG(tpcb);
  if (++conn->poll_count >= RTLNET_LWIPERF_TCP_MAX_IDLE_SEC) {
    /* lwiperf_tcp_close frees conn */
    return rtlnet_lwiperf_life_err(rtlnet_lwiperf_tcp_close(conn, RTLNET_LWIPERF_TCP_ABORTED_LOCAL));
  }

  if (conn->tx && ((conn->conn_pcb->state == ESTABLISHED) || (conn->conn_pcb->state == CLOSE_WAIT))) {
    return rtlnet_lwiperf_life_err(rtlnet_lwiperf_tcp_tx_more(conn));
  }

  return ERR_OK;
}

/** This is called when a new client connects for an iperf tcp session */
static err_t
rtlnet_lwiperf_tcp_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
  rtlnet_lwiperf_state_tcp_t *s, *conn;
  if ((err != ERR_OK) || (newpcb == NULL) || (arg == NULL)) {
    return ERR_VAL;
  }

  s = (rtlnet_lwiperf_state_tcp_t *)arg;
  LWIP_ASSERT("invalid session", s->base.server);
  LWIP_ASSERT("invalid listen pcb", s->server_pcb != NULL);
  LWIP_ASSERT("invalid conn pcb", s->conn_pcb == NULL);
  if (s->specific_remote) {
    LWIP_ASSERT("s->base.related_master_state != NULL", s->base.related_master_state != NULL);
    if (!ip_addr_eq(&newpcb->remote_ip, &s->remote_addr)) {
      /* this listener belongs to a client session, and this is not the correct remote */
      return ERR_VAL;
    }
  } else {
    LWIP_ASSERT("s->base.related_master_state == NULL", s->base.related_master_state == NULL);
  }

  conn = (rtlnet_lwiperf_state_tcp_t *)RTLNET_LWIPERF_ALLOC(rtlnet_lwiperf_state_tcp_t);
  if (conn == NULL) {
    return ERR_MEM;
  }
  memset(conn, 0, sizeof(rtlnet_lwiperf_state_tcp_t));
  conn->base.tcp = 1;
  conn->base.server = 1;
  conn->base.related_master_state = &s->base;
  conn->conn_pcb = newpcb;
  conn->time_started = sys_now();
  conn->report_fn = s->report_fn;
  conn->report_arg = s->report_arg;
  /* RTLNET-MOD: addresses for the report and the connect-back, and the receive direction */
  conn->dir = (u8_t)RTLNET_LWIPERF_DIR_RX;
  conn->slot = RTLNET_LWIPERF_SLOT_NONE;
  ip_addr_copy(conn->local_addr, newpcb->local_ip);
  conn->local_port = newpcb->local_port;
  ip_addr_copy(conn->remote_addr, newpcb->remote_ip);
  conn->remote_port = newpcb->remote_port;

  /* setup the tcp rx connection */
  tcp_arg(newpcb, conn);
  tcp_recv(newpcb, rtlnet_lwiperf_tcp_recv);
  tcp_poll(newpcb, rtlnet_lwiperf_tcp_poll, 2U);
  tcp_err(conn->conn_pcb, rtlnet_lwiperf_tcp_err);

  if (s->specific_remote) {
    /* this listener belongs to a client, so make the client the master of the newly created connection */
    conn->base.related_master_state = s->base.related_master_state;
    /* if dual mode or (tradeoff mode AND client is done): close the listener */
    if (!s->client_tradeoff_mode || !rtlnet_lwiperf_list_find(s->base.related_master_state)) {
      /* prevent report when closing: this is expected */
      s->report_fn = NULL;
      (void)rtlnet_lwiperf_tcp_close(s, RTLNET_LWIPERF_TCP_ABORTED_LOCAL);
    }
  }
  rtlnet_lwiperf_list_add(&conn->base);
  return ERR_OK;
}

/**
 * @ingroup iperf
 * Start a TCP iperf server on the default TCP port (5001) and listen for
 * incoming connections from iperf clients.
 *
 * @returns a connection handle that can be used to abort the server
 *          by calling @ref rtlnet_lwiperf_abort()
 */
void *
rtlnet_lwiperf_start_tcp_server_default(rtlnet_lwiperf_report_fn report_fn, void *report_arg)
{
  return rtlnet_lwiperf_start_tcp_server(IP_ADDR_ANY, RTLNET_LWIPERF_TCP_PORT_DEFAULT,
                                  report_fn, report_arg);
}

/**
 * @ingroup iperf
 * Start a TCP iperf server on a specific IP address and port and listen for
 * incoming connections from iperf clients.
 *
 * @returns a connection handle that can be used to abort the server
 *          by calling @ref rtlnet_lwiperf_abort()
 */
void *
rtlnet_lwiperf_start_tcp_server(const ip_addr_t *local_addr, u16_t local_port,
                         rtlnet_lwiperf_report_fn report_fn, void *report_arg)
{
  err_t err;
  rtlnet_lwiperf_state_tcp_t *state = NULL;

  err = rtlnet_lwiperf_start_tcp_server_impl(local_addr, local_port, report_fn, report_arg,
    NULL, &state);
  if (err == ERR_OK) {
    return state;
  }
  return NULL;
}

static err_t rtlnet_lwiperf_start_tcp_server_impl(const ip_addr_t *local_addr, u16_t local_port,
                                           rtlnet_lwiperf_report_fn report_fn, void *report_arg,
                                           rtlnet_lwiperf_state_base_t *related_master_state, rtlnet_lwiperf_state_tcp_t **state)
{
  err_t err;
  struct tcp_pcb *pcb;
  rtlnet_lwiperf_state_tcp_t *s;

  LWIP_ASSERT_CORE_LOCKED();

  LWIP_ASSERT("state != NULL", state != NULL);

  if (local_addr == NULL) {
    return ERR_ARG;
  }

  s = (rtlnet_lwiperf_state_tcp_t *)RTLNET_LWIPERF_ALLOC(rtlnet_lwiperf_state_tcp_t);
  if (s == NULL) {
    return ERR_MEM;
  }
  memset(s, 0, sizeof(rtlnet_lwiperf_state_tcp_t));
  s->base.tcp = 1;
  s->base.server = 1;
  s->base.related_master_state = related_master_state;
  s->report_fn = report_fn;
  s->report_arg = report_arg;
  s->slot = RTLNET_LWIPERF_SLOT_NONE; /* RTLNET-MOD */

  pcb = tcp_new_ip_type(RTLNET_LWIPERF_SERVER_IP_TYPE);
  if (pcb == NULL) {
    RTLNET_LWIPERF_FREE(rtlnet_lwiperf_state_tcp_t, s); /* RTLNET-MOD: no leak */
    return ERR_MEM;
  }
  /* RTLNET-MOD: bind past the TIME_WAIT pcbs of earlier tests on this port (needs SO_REUSE 1);
     without it a restart of the server within about two minutes of a test failed with ERR_USE */
  ip_set_option(pcb, SOF_REUSEADDR);
  err = tcp_bind(pcb, local_addr, local_port);
  if (err != ERR_OK) {
    (void)tcp_close(pcb); /* RTLNET-MOD: no leak */
    RTLNET_LWIPERF_FREE(rtlnet_lwiperf_state_tcp_t, s);
    return err;
  }
  s->server_pcb = tcp_listen_with_backlog(pcb, 1);
  if (s->server_pcb == NULL) {
    if (pcb != NULL) {
      tcp_close(pcb);
    }
    RTLNET_LWIPERF_FREE(rtlnet_lwiperf_state_tcp_t, s);
    return ERR_MEM;
  }
  pcb = NULL;

  tcp_arg(s->server_pcb, s);
  tcp_accept(s->server_pcb, rtlnet_lwiperf_tcp_accept);
  /* RTLNET-MOD: the main server is the firewall's iperf service; the listener a dual or tradeoff client starts for
     the connect-back is a temporary service of its own while it listens (removed when the listener closes) */
  s->fw_server = (u8_t)(((related_master_state == NULL) ? FW_SVC_IPERF_TCP : FW_SVC_IPERF_BACK) + 1u);
  s->fw_lport = local_port;
  RTLNET_LWIPERF_FW_SERVER((unsigned)s->fw_server - 1u, local_port, 1);

  rtlnet_lwiperf_list_add(&s->base);
  *state = s;
  return ERR_OK;
}

/**
 * @ingroup iperf
 * Start a TCP iperf client to the default TCP port (5001).
 *
 * @returns a connection handle that can be used to abort the client
 *          by calling @ref rtlnet_lwiperf_abort()
 */
void* rtlnet_lwiperf_start_tcp_client_default(const ip_addr_t* remote_addr,
                               rtlnet_lwiperf_report_fn report_fn, void* report_arg)
{
  return rtlnet_lwiperf_start_tcp_client(remote_addr, RTLNET_LWIPERF_TCP_PORT_DEFAULT, RTLNET_LWIPERF_CLIENT,
                                  report_fn, report_arg);
}

/**
 * @ingroup iperf
 * Start a TCP iperf client to a specific IP address and port.
 *
 * @returns a connection handle that can be used to abort the client
 *          by calling @ref rtlnet_lwiperf_abort()
 */
void* rtlnet_lwiperf_start_tcp_client(const ip_addr_t* remote_addr, u16_t remote_port,
  enum rtlnet_lwiperf_client_type type, rtlnet_lwiperf_report_fn report_fn, void* report_arg)
{
  err_t ret;
  u32_t flags;
  enum rtlnet_lwiperf_direction dir;
  rtlnet_lwiperf_state_tcp_t *state = NULL;

  switch (type) {
  case RTLNET_LWIPERF_CLIENT:
    /* Unidirectional tx only test */
    flags = 0;
    dir = RTLNET_LWIPERF_DIR_CLIENT;
    break;
  case RTLNET_LWIPERF_DUAL:
    /* Do a bidirectional test simultaneously */
    flags = RTLNET_LWIPERF_FLAGS_ANSWER_TEST | RTLNET_LWIPERF_FLAGS_ANSWER_NOW;
    dir = RTLNET_LWIPERF_DIR_DUAL;
    break;
  case RTLNET_LWIPERF_TRADEOFF:
    /* Do a bidirectional test individually */
    flags = RTLNET_LWIPERF_FLAGS_ANSWER_TEST;
    dir = RTLNET_LWIPERF_DIR_TRADEOFF;
    break;
  default:
    /* invalid argument */
    return NULL;
  }
  /* TODO: implement passing duration/amount of bytes to transfer (default: 10 s) */
  ret = rtlnet_lwiperf_tx_start_impl(remote_addr, remote_port, RTLNET_LWIPERF_DEFAULT_AMOUNT, flags, dir,
                              RTLNET_LWIPERF_SLOT_NONE, report_fn, report_arg, NULL, &state);
  if (ret == ERR_OK) {
    LWIP_ASSERT("state != NULL", state != NULL);
    if (type != RTLNET_LWIPERF_CLIENT) {
      /* start corresponding server now */
      rtlnet_lwiperf_state_tcp_t *server = NULL;
      ret = rtlnet_lwiperf_start_tcp_server_impl(&state->conn_pcb->local_ip, RTLNET_LWIPERF_TCP_PORT_DEFAULT,
        report_fn, report_arg, (rtlnet_lwiperf_state_base_t *)state, &server);
      if (ret != ERR_OK) {
        /* starting server failed, abort client */
        rtlnet_lwiperf_abort(state);
        return NULL;
      }
      /* make this server accept one connection only */
      server->specific_remote = 1;
      server->remote_addr = state->conn_pcb->remote_ip;
      if (type == RTLNET_LWIPERF_TRADEOFF) {
        /* tradeoff means that the remote host connects only after the client is done,
           so keep the listen pcb open until the client is done */
        server->client_tradeoff_mode = 1;
      }
    }
    return state;
  }
  return NULL;
}

/**
 * @ingroup iperf
 * Abort an iperf session (handle returned by rtlnet_lwiperf_start_tcp_server*())
 * RTLNET-MOD: every session of the handle (the session itself and the ones whose master it is)
 * is closed without a report, its pcb closed and its state freed. At most
 * RTLNET_LWIPERF_ABORT_MAX sessions are closed per call.
 */
void
rtlnet_lwiperf_abort(void *lwiperf_session)
{
  rtlnet_lwiperf_state_base_t *i;
  u8_t closed;

  LWIP_ASSERT_CORE_LOCKED();

  for (closed = 0; closed < RTLNET_LWIPERF_ABORT_MAX; closed++) {
    for (i = rtlnet_lwiperf_all_connections; i != NULL; i = i->next) {
      if ((i == lwiperf_session) || (i->related_master_state == lwiperf_session)) {
        break;
      }
    }
    if (i == NULL) {
      return;
    }
    ((rtlnet_lwiperf_state_tcp_t *)i)->report_fn = NULL;
    (void)rtlnet_lwiperf_tcp_close((rtlnet_lwiperf_state_tcp_t *)i, RTLNET_LWIPERF_TCP_ABORTED_LOCAL);
  }
}

#endif /* LWIP_TCP && LWIP_CALLBACK_API */
