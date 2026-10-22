/*
 * rtlnet_tcp_offload.h -- RTLNet TCP/UDP/IPv4 checksum offload driver interface
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the rtlnet_tcp_offload register map (4 KiB
 * window; planned protocol sub-map slot 0x9000, 0x44A1_9000), the receive
 * trailer layout and the driver API that owns them. The RTL package
 * cores/rtlnet_tcp_offload/hdl/rtlnet_tcp_offload_pkg.sv mirrors every offset
 * and bit below in localparams; the two change together in one commit. If
 * they drift, a write lands in the wrong register (undefined offsets ignore
 * writes and read 0) or a trailer field is read from the wrong bits, silently.
 *
 * Contract:
 *   - Power-up: CTRL = 0. The TX path then passes frames bit-exact and the RX
 *     path passes frames bit-exact with no trailer. Existing software that does
 *     not know the core is unaffected.
 *   - CTRL bits are sampled by the datapath at the first beat of each frame:
 *       tx_ip_csum  insert the IPv4 header checksum of frames the CPU sends
 *       tx_l4_csum  insert the TCP/UDP checksum of frames the CPU sends
 *       rx_csum     check IPv4 header and TCP/UDP checksum of frames the CPU
 *                   receives and append one 8-byte trailer beat to every frame
 *     CTRL reads back exactly as written (undefined bits read 0).
 *   - TX insert overwrites the checksum fields; software may leave any value
 *     in them. A frame is left alone (and counted) when it is a fragment, not
 *     TCP/UDP, or its lengths are inconsistent. UDP result 0x0000 is sent as
 *     0xFFFF.
 *   - RX: with rx_csum set every frame carries a trailer. The DMA buffer must
 *     hold roundup8(max frame) + 8 bytes. The trailer is at byte offset
 *     roundup8(frame_len) and ends the DMA transfer, so the transfer length is
 *     roundup8(frame_len) + 8. Padding bytes between frame_len and the trailer
 *     are zero. rtlnet_tcp_offload_trailer_parse() validates and decodes it.
 *   - Counters are 32-bit, wrap, and clear through CNT_CLEAR.
 *   - Every function is bounded and returns RTLNET_TXO_OK or a negative
 *     RTLNET_TXO_ERR_* code. All functions take the context set up by
 *     rtlnet_tcp_offload_init(); one context per core instance.
 *
 * This header holds offsets, bit fields, types and contract prose; the
 * per-function commentary is in rtlnet_tcp_offload.c.
 */
#ifndef RTLNET_TCP_OFFLOAD_H
#define RTLNET_TCP_OFFLOAD_H

#include <stdint.h>   /* uint8_t, uint16_t, uint32_t, uintptr_t */

/* -------------------------------------------------------------------------
 * Register offsets (byte offsets in the 4 KiB window)
 * ------------------------------------------------------------------------- */
#define RTLNET_TXO_REG_ID              0x000u   /* RO "TCPO" */
#define RTLNET_TXO_REG_VERSION         0x004u   /* RO 0xMMDDYYYY */
#define RTLNET_TXO_REG_CAPS            0x008u   /* RO build parameters */
#define RTLNET_TXO_REG_CTRL            0x00Cu   /* RW tx_ip_csum, tx_l4_csum, rx_csum */
#define RTLNET_TXO_REG_STATUS          0x010u   /* RO idle bits */
#define RTLNET_TXO_REG_LATENCY         0x014u   /* RO pipeline latencies, clocks */
#define RTLNET_TXO_REG_CNT_CLEAR       0x018u   /* WO bit 0 clears every counter, reads 0 */
#define RTLNET_TXO_REG_CNT_TX(i)       (0x040u + 4u * (uint32_t)(i))   /* RO, i = RTLNET_TXO_CNT_TX_* */
#define RTLNET_TXO_REG_CNT_RX(i)       (0x060u + 4u * (uint32_t)(i))   /* RO, i = RTLNET_TXO_CNT_RX_* */
#define RTLNET_TXO_WINDOW_BYTES        0x1000u

/* Counter indices. */
#define RTLNET_TXO_CNT_TX_FRAMES       0u    /* frames passed through the TX path */
#define RTLNET_TXO_CNT_TX_IP_PATCHED   1u    /* IPv4 header checksum inserted */
#define RTLNET_TXO_CNT_TX_L4_PATCHED   2u    /* TCP/UDP checksum inserted */
#define RTLNET_TXO_CNT_TX_SKIPPED      3u    /* L4 insert on but fragment or not TCP/UDP */
#define RTLNET_TXO_CNT_TX_MALFORMED    4u    /* IPv4 frame with inconsistent lengths, left unpatched */
#define RTLNET_TXO_CNT_TX_DROPPED      5u    /* frame longer than a buffer slot, dropped */
#define RTLNET_TXO_NUM_TX_COUNTERS     6u
#define RTLNET_TXO_CNT_RX_FRAMES       0u    /* frames given a trailer */
#define RTLNET_TXO_CNT_RX_VERIFIED     1u    /* IPv4 header and L4 checksum both good */
#define RTLNET_TXO_CNT_RX_IP_BAD       2u    /* IPv4 frame, header malformed or checksum bad */
#define RTLNET_TXO_CNT_RX_L4_BAD       3u    /* L4 checksum possible and bad */
#define RTLNET_TXO_CNT_RX_UNVERIFIED   4u    /* L4 check not possible (non-IP, fragment, other protocol, UDP 0) */
#define RTLNET_TXO_NUM_RX_COUNTERS     5u

/* Register values. */
#define RTLNET_TXO_ID_VALUE            0x5443504Fu   /* "TCPO" */
#define RTLNET_TXO_VERSION_VALUE       0x10222026u

/* CTRL bits. */
#define RTLNET_TXO_CTRL_TX_IP_CSUM     0x00000001u
#define RTLNET_TXO_CTRL_TX_L4_CSUM     0x00000002u
#define RTLNET_TXO_CTRL_RX_CSUM        0x00000004u
#define RTLNET_TXO_CTRL_MASK           0x00000007u

/* STATUS bits. */
#define RTLNET_TXO_STATUS_TX_IDLE      0x00000001u   /* TX buffer, sideband queue and pipeline empty */
#define RTLNET_TXO_STATUS_RX_IDLE      0x00000002u   /* RX delay line empty, no trailer pending */

/* CAPS bits and fields. */
#define RTLNET_TXO_CAPS_TX_PRESENT     0x00000001u
#define RTLNET_TXO_CAPS_RX_PRESENT     0x00000002u
#define RTLNET_TXO_CAPS_INS_IP         0x00000004u
#define RTLNET_TXO_CAPS_INS_TCP        0x00000008u
#define RTLNET_TXO_CAPS_INS_UDP        0x00000010u
#define RTLNET_TXO_CAPS_VLAN           0x00000020u
#define RTLNET_TXO_CAPS_TX_BUF_KB(c)   (((c) >> 8) & 0xFFu)
#define RTLNET_TXO_CAPS_MAX_FRAME(c)   (((c) >> 16) & 0x7FFu)

/* LATENCY fields. */
#define RTLNET_TXO_LAT_TX(v)           (((v) >> 0) & 0xFFu)   /* last beat accepted -> sideband written */
#define RTLNET_TXO_LAT_RX(v)           (((v) >> 8) & 0xFFu)   /* beats the RX delay line holds */

/* -------------------------------------------------------------------------
 * Receive trailer (one 8-byte beat after the frame, little endian)
 * ------------------------------------------------------------------------- */
#define RTLNET_TXO_TRAILER_BYTES       8u
#define RTLNET_TXO_TRAILER_MARKER      0xA5u   /* upper nibble 0xA: trailer; lower nibble 5: layout version */
/* byte 0..1 frame length; 2..3 folded L4 sum; 4..5 flags; 6 L4 offset; 7 marker */
#define RTLNET_TXO_TRF_IS_IPV4         0x0001u
#define RTLNET_TXO_TRF_IS_TCP          0x0002u
#define RTLNET_TXO_TRF_IS_UDP          0x0004u
#define RTLNET_TXO_TRF_VLAN            0x0008u
#define RTLNET_TXO_TRF_FRAGMENT        0x0010u
#define RTLNET_TXO_TRF_IP_OK           0x0020u   /* IPv4 header valid and its checksum good */
#define RTLNET_TXO_TRF_L4_OK           0x0040u   /* verified and the L4 checksum good */
#define RTLNET_TXO_TRF_VERIFIED        0x0080u   /* both checks were possible */

/* Largest frame the trailer's length field and a DMA buffer sizing rule cover. */
#define RTLNET_TXO_ROUNDUP8(n)         (((uint32_t)(n) + 7u) & ~7u)
#define RTLNET_TXO_RX_BUFFER_BYTES(max_frame) (RTLNET_TXO_ROUNDUP8(max_frame) + RTLNET_TXO_TRAILER_BYTES)

/* Driver bounds. */
#define RTLNET_TXO_IDLE_POLL_DEFAULT   100000u

/* Status codes. */
#define RTLNET_TXO_OK                  0
#define RTLNET_TXO_ERR_ARG             (-1)    /* null pointer or bad value */
#define RTLNET_TXO_ERR_ID              (-2)    /* ID / VERSION mismatch at init */
#define RTLNET_TXO_ERR_TIMEOUT         (-3)    /* idle did not come */
#define RTLNET_TXO_ERR_NOT_INIT        (-4)    /* context not initialised */
#define RTLNET_TXO_ERR_READBACK        (-5)    /* CTRL read back differently from what was written */
#define RTLNET_TXO_ERR_TRAILER         (-6)    /* no valid trailer in the buffer */
#define RTLNET_TXO_ERR_UNSUPPORTED     (-7)    /* CTRL bits the build does not have */

/* -------------------------------------------------------------------------
 * Types
 * ------------------------------------------------------------------------- */
/* Driver context, one per core instance; filled by init. */
typedef struct {
    uintptr_t base;
    uint32_t  caps;
    uint32_t  tx_present;
    uint32_t  rx_present;
    uint32_t  ins_ip;
    uint32_t  ins_tcp;
    uint32_t  ins_udp;
    uint32_t  vlan;
    uint32_t  tx_buf_kb;
    uint32_t  max_frame;
    uint32_t  tx_latency;
    uint32_t  rx_delay;
    uint32_t  initialised;
} rtlnet_tcp_offload_t;

typedef struct {
    uint32_t tx_frames;
    uint32_t tx_ip_patched;
    uint32_t tx_l4_patched;
    uint32_t tx_skipped;
    uint32_t tx_malformed;
    uint32_t tx_dropped;
    uint32_t rx_frames;
    uint32_t rx_verified;
    uint32_t rx_ip_bad;
    uint32_t rx_l4_bad;
    uint32_t rx_unverified;
} rtlnet_txo_counters_t;

/* Decoded receive trailer. */
typedef struct {
    uint16_t frame_len;     /* frame bytes before padding */
    uint16_t l4_sum;        /* folded ones'-complement sum, 0xFFFF for a good segment; 0 if not summed */
    uint16_t flags;         /* RTLNET_TXO_TRF_* */
    uint8_t  l4_offset;     /* L4 start from the frame start; 0 unless the IPv4 header is valid */
} rtlnet_txo_trailer_t;

/* What the CPU should do with a received frame. */
typedef enum {
    RTLNET_TXO_RX_PASS_VERIFIED   = 0,   /* both checks done and good */
    RTLNET_TXO_RX_PASS_UNVERIFIED = 1,   /* L4 check not possible and no IPv4 header fault seen */
    RTLNET_TXO_RX_DROP_BAD_IP     = 2,   /* IPv4 frame whose header is malformed or its checksum bad */
    RTLNET_TXO_RX_DROP_BAD_L4     = 3    /* TCP/UDP checksum bad */
} rtlnet_txo_rx_verdict_t;

/* -------------------------------------------------------------------------
 * API
 * ------------------------------------------------------------------------- */
int rtlnet_tcp_offload_init(rtlnet_tcp_offload_t *ctx, uintptr_t base);

int rtlnet_tcp_offload_set_ctrl(const rtlnet_tcp_offload_t *ctx, uint32_t ctrl);
int rtlnet_tcp_offload_get_ctrl(const rtlnet_tcp_offload_t *ctx, uint32_t *ctrl);
int rtlnet_tcp_offload_get_status(const rtlnet_tcp_offload_t *ctx, uint32_t *status);
int rtlnet_tcp_offload_wait_tx_idle(const rtlnet_tcp_offload_t *ctx, uint32_t max_polls);

int rtlnet_tcp_offload_counters(const rtlnet_tcp_offload_t *ctx, rtlnet_txo_counters_t *counters);
int rtlnet_tcp_offload_clear_counters(const rtlnet_tcp_offload_t *ctx);

int rtlnet_tcp_offload_trailer_parse(const uint8_t *buf, uint32_t xfer_len, rtlnet_txo_trailer_t *trailer);
rtlnet_txo_rx_verdict_t rtlnet_tcp_offload_rx_verdict(const rtlnet_txo_trailer_t *trailer);

#endif /* RTLNET_TCP_OFFLOAD_H */
