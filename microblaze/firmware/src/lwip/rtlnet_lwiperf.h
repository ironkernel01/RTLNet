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
 *
 */

/*
 * Modified for RTLNet (10-22-2026): copy of lwIP 2.2.0 src/include/lwip/apps/lwiperf.h.
 * Every change is tagged RTLNET-MOD where it sits; the list is in rtlnet_lwiperf.c.
 *   - Symbols renamed lwiperf_* -> rtlnet_lwiperf_*, LWIPERF_* -> RTLNET_LWIPERF_*,
 *     include guard RTLNET_LWIPERF_H, so nothing collides with the install's header.
 *   - Report type RTLNET_LWIPERF_TCP_REJECTED_BUSY and the enum rtlnet_lwiperf_direction
 *     added; the report function takes the direction.
 */

/**
 * @file
 * lwIP iPerf server implementation
 */

#ifndef RTLNET_LWIPERF_H
#define RTLNET_LWIPERF_H

#include "lwip/opt.h"
#include "lwip/ip_addr.h"

#ifdef __cplusplus
extern "C" {
#endif

#define RTLNET_LWIPERF_TCP_PORT_DEFAULT  5001

/** lwIPerf test results */
enum rtlnet_lwiperf_report_type
{
  /** The server side test is done */
  RTLNET_LWIPERF_TCP_DONE_SERVER,
  /** The client side test is done */
  RTLNET_LWIPERF_TCP_DONE_CLIENT,
  /** Local error lead to test abort */
  RTLNET_LWIPERF_TCP_ABORTED_LOCAL,
  /** Data check error lead to test abort */
  RTLNET_LWIPERF_TCP_ABORTED_LOCAL_DATAERROR,
  /** Transmit error lead to test abort */
  RTLNET_LWIPERF_TCP_ABORTED_LOCAL_TXERROR,
  /** Remote side aborted the test */
  RTLNET_LWIPERF_TCP_ABORTED_REMOTE,
  /** RTLNET-MOD: a test of the same mode was running; the new connection was refused */
  RTLNET_LWIPERF_TCP_REJECTED_BUSY
};

/** RTLNET-MOD: direction of a reported test, seen from the board */
enum rtlnet_lwiperf_direction
{
  /** The client sends to the board (plain test, or the receive half of -r / -d) */
  RTLNET_LWIPERF_DIR_RX,
  /** The board sends on the client's own connection (-R) */
  RTLNET_LWIPERF_DIR_REVERSE,
  /** The board connects back and sends after the client finished (-r) */
  RTLNET_LWIPERF_DIR_TRADEOFF,
  /** The board connects back and sends while the client sends (-d) */
  RTLNET_LWIPERF_DIR_DUAL,
  /** The board is the client (rtlnet_lwiperf_start_tcp_client) */
  RTLNET_LWIPERF_DIR_CLIENT
};

/** Control */
enum rtlnet_lwiperf_client_type
{
  /** Unidirectional tx only test */
  RTLNET_LWIPERF_CLIENT,
  /** Do a bidirectional test simultaneously */
  RTLNET_LWIPERF_DUAL,
  /** Do a bidirectional test individually */
  RTLNET_LWIPERF_TRADEOFF
};

/** Prototype of a report function that is called when a session is finished.
    This report function can show the test results.
    @param arg Report_arg from when the test was started.
    @param report_type contains the test result
    @param dir direction of the test (RTLNET-MOD)
    @param local_addr The local address from the session
    @param local_port The local port
    @param remote_addr The remote address from the session
    @param remote_port The remote port
    @param bytes_transferred Total transferred bytes (payload; the test header is not counted)
    @param ms_duration Total session duration, in milliseconds
    @param bandwidth_kbitpsec Average bandwidth during the session, in kbps
*/
typedef void (*rtlnet_lwiperf_report_fn)(void *arg, enum rtlnet_lwiperf_report_type report_type,
  enum rtlnet_lwiperf_direction dir,
  const ip_addr_t* local_addr, u16_t local_port, const ip_addr_t* remote_addr, u16_t remote_port,
  u32_t bytes_transferred, u32_t ms_duration, u32_t bandwidth_kbitpsec);

void* rtlnet_lwiperf_start_tcp_server(const ip_addr_t* local_addr, u16_t local_port,
                               rtlnet_lwiperf_report_fn report_fn, void* report_arg);
void* rtlnet_lwiperf_start_tcp_server_default(rtlnet_lwiperf_report_fn report_fn, void* report_arg);
void* rtlnet_lwiperf_start_tcp_client(const ip_addr_t* remote_addr, u16_t remote_port,
                               enum rtlnet_lwiperf_client_type type,
                               rtlnet_lwiperf_report_fn report_fn, void* report_arg);
void* rtlnet_lwiperf_start_tcp_client_default(const ip_addr_t* remote_addr,
                               rtlnet_lwiperf_report_fn report_fn, void* report_arg);

void  rtlnet_lwiperf_abort(void* lwiperf_session);


#ifdef __cplusplus
}
#endif

#endif /* RTLNET_LWIPERF_H */
