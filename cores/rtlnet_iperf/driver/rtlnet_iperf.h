/*
 * rtlnet_iperf.h -- RTLNet iperf 2 UDP server leaf: register map and driver API
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one definition of the rtlnet_iperf register map. The RTL register
 * file (cores/rtlnet_iperf/hdl/rtlnet_iperf.sv) mirrors every value below as
 * a localparam with a pointer comment to this file; both change in the same
 * commit. Drift is silent: a moved offset reads another counter, a moved CTRL
 * bit turns reverse mode off when firmware means to clear the counters.
 *
 * Header/source split: this header holds signatures, register constants,
 * types and contract prose; rtlnet_iperf.c holds the per-function commentary.
 * Register access goes through rtlnet_mmio.h only; the base address is passed
 * in by the caller (protocol window 0x1_0000 + 0x4000 on the Nexys Video).
 *
 * Statistics semantics: RX_* describe the current or last receive flow and
 * restart at zero when a flow opens; TX_DATAGRAMS describes the current or last
 * reverse stream; REPORTS_SENT counts every server report sent. CNT_CLEAR sets
 * all of them to zero without touching a flow in progress (the server report
 * is computed from separate flow state).
 */
#ifndef RTLNET_IPERF_H
#define RTLNET_IPERF_H

#include <stdint.h>   /* uint32_t, uint64_t, uintptr_t */

/* ---- Register offsets ---- */
#define RTLNET_IPERF_REG_ID               0x000u   /* RO "IPRF" */
#define RTLNET_IPERF_REG_VERSION          0x004u   /* RO 0xMMDDYYYY */
#define RTLNET_IPERF_REG_CAPS             0x008u   /* RO [13:0] MAX_DGRAM_BYTES, [31:14] CLK_HZ/1000 */
#define RTLNET_IPERF_REG_CTRL             0x00Cu   /* RW */
#define RTLNET_IPERF_REG_STATUS           0x010u   /* RO */
#define RTLNET_IPERF_REG_UDP_PORT         0x014u   /* RW [15:0] server port */
#define RTLNET_IPERF_REG_RX_DATAGRAMS     0x018u   /* RO datagrams received, FIN included */
#define RTLNET_IPERF_REG_RX_BYTES_LO      0x01Cu   /* RO UDP payload bytes [31:0]; a read latches [63:32] */
#define RTLNET_IPERF_REG_RX_BYTES_HI      0x020u   /* RO [63:32] latched by the last RX_BYTES_LO read */
#define RTLNET_IPERF_REG_RX_LOST          0x024u   /* RO max(sum of gaps - out of order, 0) */
#define RTLNET_IPERF_REG_RX_OUTOFORDER    0x028u   /* RO late and duplicate datagrams */
#define RTLNET_IPERF_REG_TX_DATAGRAMS     0x02Cu   /* RO reverse datagrams (final datagram excluded) */
#define RTLNET_IPERF_REG_JITTER_US16      0x030u   /* RO RFC 3550 estimator, microseconds x 16 */
#define RTLNET_IPERF_REG_REQ_RATE_BPS     0x034u   /* RO rate field of the last client header */
#define RTLNET_IPERF_REG_LAST_DURATION_US 0x038u   /* RO first datagram to FIN of the last flow */
#define RTLNET_IPERF_REG_REPORTS_SENT     0x03Cu   /* RO server reports sent, resends included */

/* ---- Constant register values ---- */
#define RTLNET_IPERF_ID_VALUE             0x49505246u   /* "IPRF" */
#define RTLNET_IPERF_VERSION_VALUE        0x10222026u

/* ---- CAPS fields ---- */
#define RTLNET_IPERF_CAPS_DGRAM_MASK      0x00003FFFu
#define RTLNET_IPERF_CAPS_KHZ_SHIFT       14u

/* ---- CTRL bits ---- */
#define RTLNET_IPERF_CTRL_REVERSE_ALLOWED 0x00000001u   /* level, reset 1: honour -R requests */
#define RTLNET_IPERF_CTRL_CNT_CLEAR       0x00010000u   /* pulse: clear the statistics registers */

/* ---- STATUS bits ---- */
#define RTLNET_IPERF_STATUS_RX_ACTIVE     0x00000001u   /* a receive flow is open */
#define RTLNET_IPERF_STATUS_TX_ACTIVE     0x00000002u   /* a reverse stream is running */
#define RTLNET_IPERF_STATUS_ENABLE        0x00010000u   /* the wrapper's leaf enable */

#define RTLNET_IPERF_PORT_MASK            0x0000FFFFu
#define RTLNET_IPERF_DEFAULT_PORT         5001u

/* ---- Driver results ---- */
#define RTLNET_IPERF_OK                   0
#define RTLNET_IPERF_ERR_ID               (-1)   /* ID or VERSION register mismatch */
#define RTLNET_IPERF_ERR_ARG              (-2)   /* null pointer or port 0 */

typedef struct {
    int      rx_active;
    int      tx_active;
    int      reverse_allowed;
    uint32_t udp_port;
    uint32_t rx_datagrams;
    uint64_t rx_bytes;
    uint32_t rx_lost;
    uint32_t rx_outoforder;
    uint32_t tx_datagrams;
    uint32_t jitter_us16;          /* microseconds x 16 */
    uint32_t req_rate_bps;
    uint32_t last_duration_us;
    uint32_t reports_sent;
    uint32_t max_dgram_bytes;      /* from CAPS */
    uint32_t clk_khz;              /* from CAPS */
} rtlnet_iperf_stats_t;

int  rtlnet_iperf_probe(uintptr_t base);
int  rtlnet_iperf_set_port(uintptr_t base, uint32_t port);
uint32_t rtlnet_iperf_get_port(uintptr_t base);
void rtlnet_iperf_set_reverse_allowed(uintptr_t base, int on);
int  rtlnet_iperf_get_reverse_allowed(uintptr_t base);
void rtlnet_iperf_clear_counters(uintptr_t base);
int  rtlnet_iperf_read_stats(uintptr_t base, rtlnet_iperf_stats_t *st);

#endif /* RTLNET_IPERF_H */
