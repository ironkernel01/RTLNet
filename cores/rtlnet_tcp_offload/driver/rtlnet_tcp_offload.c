/*
 * rtlnet_tcp_offload.c -- RTLNet TCP/UDP/IPv4 checksum offload driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches rtlnet_tcp_offload registers, and the one
 * place that decodes its receive trailer. Register access goes through
 * rtlnet_mmio.h; offsets and bits come from rtlnet_tcp_offload.h. Every loop
 * that waits on the hardware is bounded. The context carries the build
 * parameters read from CAPS and LATENCY.
 */
#include "rtlnet_tcp_offload.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

/*
 * rd -- read one offload register.
 * Returns: the register value.
 */
static uint32_t rd(const rtlnet_tcp_offload_t *ctx, uint32_t off)
{
    return rtlnet_reg_read32(ctx->base, off);
}

/*
 * wr -- write one offload register.
 */
static void wr(const rtlnet_tcp_offload_t *ctx, uint32_t off, uint32_t value)
{
    rtlnet_reg_write32(ctx->base, off, value);
}

/*
 * ready -- check a context before use.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG for NULL, RTLNET_TXO_ERR_NOT_INIT.
 */
static int ready(const rtlnet_tcp_offload_t *ctx)
{
    if (ctx == NULL) {
        return RTLNET_TXO_ERR_ARG;
    }
    return (ctx->initialised != 0u) ? RTLNET_TXO_OK : RTLNET_TXO_ERR_NOT_INIT;
}

/*
 * rtlnet_tcp_offload_init -- identify the core and read its build parameters.
 *
 * Steps:
 *   1. Check ID and VERSION.
 *   2. Read CAPS and LATENCY into the context.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, or RTLNET_TXO_ERR_ID when the
 * window does not hold this core (an absent core reads 0).
 */
int rtlnet_tcp_offload_init(rtlnet_tcp_offload_t *ctx, uintptr_t base)
{
    uint32_t caps;
    uint32_t lat;

    if (ctx == NULL) {
        return RTLNET_TXO_ERR_ARG;
    }
    ctx->initialised = 0u;
    ctx->base = base;
    if (rd(ctx, RTLNET_TXO_REG_ID) != RTLNET_TXO_ID_VALUE ||
        rd(ctx, RTLNET_TXO_REG_VERSION) != RTLNET_TXO_VERSION_VALUE) {
        return RTLNET_TXO_ERR_ID;
    }
    caps = rd(ctx, RTLNET_TXO_REG_CAPS);
    lat = rd(ctx, RTLNET_TXO_REG_LATENCY);
    ctx->caps = caps;
    ctx->tx_present = ((caps & RTLNET_TXO_CAPS_TX_PRESENT) != 0u) ? 1u : 0u;
    ctx->rx_present = ((caps & RTLNET_TXO_CAPS_RX_PRESENT) != 0u) ? 1u : 0u;
    ctx->ins_ip = ((caps & RTLNET_TXO_CAPS_INS_IP) != 0u) ? 1u : 0u;
    ctx->ins_tcp = ((caps & RTLNET_TXO_CAPS_INS_TCP) != 0u) ? 1u : 0u;
    ctx->ins_udp = ((caps & RTLNET_TXO_CAPS_INS_UDP) != 0u) ? 1u : 0u;
    ctx->vlan = ((caps & RTLNET_TXO_CAPS_VLAN) != 0u) ? 1u : 0u;
    ctx->tx_buf_kb = RTLNET_TXO_CAPS_TX_BUF_KB(caps);
    ctx->max_frame = RTLNET_TXO_CAPS_MAX_FRAME(caps);
    ctx->tx_latency = RTLNET_TXO_LAT_TX(lat);
    ctx->rx_delay = RTLNET_TXO_LAT_RX(lat);
    ctx->initialised = 1u;
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_set_ctrl -- write CTRL and read it back.
 *
 * Steps:
 *   1. Reject bits outside RTLNET_TXO_CTRL_MASK, and bits the build lacks
 *      (tx_ip needs INS_IP, tx_l4 needs INS_TCP and INS_UDP, rx_csum needs
 *      RX_PRESENT).
 *   2. Write CTRL, read it back.
 * The hardware samples CTRL at each frame's first beat, so the new value
 * applies to frames that start after the write has taken effect (a few
 * clocks); the read-back confirms it.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, RTLNET_TXO_ERR_UNSUPPORTED,
 * RTLNET_TXO_ERR_READBACK.
 */
int rtlnet_tcp_offload_set_ctrl(const rtlnet_tcp_offload_t *ctx, uint32_t ctrl)
{
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    if ((ctrl & ~RTLNET_TXO_CTRL_MASK) != 0u) {
        return RTLNET_TXO_ERR_ARG;
    }
    if (((ctrl & RTLNET_TXO_CTRL_TX_IP_CSUM) != 0u && (ctx->tx_present == 0u || ctx->ins_ip == 0u)) ||
        ((ctrl & RTLNET_TXO_CTRL_TX_L4_CSUM) != 0u &&
         (ctx->tx_present == 0u || ctx->ins_tcp == 0u || ctx->ins_udp == 0u)) ||
        ((ctrl & RTLNET_TXO_CTRL_RX_CSUM) != 0u && ctx->rx_present == 0u)) {
        return RTLNET_TXO_ERR_UNSUPPORTED;
    }
    wr(ctx, RTLNET_TXO_REG_CTRL, ctrl);
    return (rd(ctx, RTLNET_TXO_REG_CTRL) == ctrl) ? RTLNET_TXO_OK : RTLNET_TXO_ERR_READBACK;
}

/*
 * rtlnet_tcp_offload_get_ctrl -- read CTRL.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_get_ctrl(const rtlnet_tcp_offload_t *ctx, uint32_t *ctrl)
{
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    if (ctrl == NULL) {
        return RTLNET_TXO_ERR_ARG;
    }
    *ctrl = rd(ctx, RTLNET_TXO_REG_CTRL);
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_get_status -- read STATUS (RTLNET_TXO_STATUS_* bits).
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_get_status(const rtlnet_tcp_offload_t *ctx, uint32_t *status)
{
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    if (status == NULL) {
        return RTLNET_TXO_ERR_ARG;
    }
    *status = rd(ctx, RTLNET_TXO_REG_STATUS);
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_wait_tx_idle -- wait until the TX path holds no frame.
 *
 * Used when turning a TX insert bit off: frames already accepted keep the CTRL
 * value they started with, and idle says none is left in the buffer.
 * max_polls bounds the STATUS reads (0 selects RTLNET_TXO_IDLE_POLL_DEFAULT).
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_TIMEOUT, RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_wait_tx_idle(const rtlnet_tcp_offload_t *ctx, uint32_t max_polls)
{
    uint32_t i;
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    if (max_polls == 0u) {
        max_polls = RTLNET_TXO_IDLE_POLL_DEFAULT;
    }
    for (i = 0u; i < max_polls; i++) {
        if ((rd(ctx, RTLNET_TXO_REG_STATUS) & RTLNET_TXO_STATUS_TX_IDLE) != 0u) {
            return RTLNET_TXO_OK;
        }
    }
    return RTLNET_TXO_ERR_TIMEOUT;
}

/*
 * rtlnet_tcp_offload_counters -- read every counter.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_counters(const rtlnet_tcp_offload_t *ctx, rtlnet_txo_counters_t *counters)
{
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    if (counters == NULL) {
        return RTLNET_TXO_ERR_ARG;
    }
    counters->tx_frames = rd(ctx, RTLNET_TXO_REG_CNT_TX(RTLNET_TXO_CNT_TX_FRAMES));
    counters->tx_ip_patched = rd(ctx, RTLNET_TXO_REG_CNT_TX(RTLNET_TXO_CNT_TX_IP_PATCHED));
    counters->tx_l4_patched = rd(ctx, RTLNET_TXO_REG_CNT_TX(RTLNET_TXO_CNT_TX_L4_PATCHED));
    counters->tx_skipped = rd(ctx, RTLNET_TXO_REG_CNT_TX(RTLNET_TXO_CNT_TX_SKIPPED));
    counters->tx_malformed = rd(ctx, RTLNET_TXO_REG_CNT_TX(RTLNET_TXO_CNT_TX_MALFORMED));
    counters->tx_dropped = rd(ctx, RTLNET_TXO_REG_CNT_TX(RTLNET_TXO_CNT_TX_DROPPED));
    counters->rx_frames = rd(ctx, RTLNET_TXO_REG_CNT_RX(RTLNET_TXO_CNT_RX_FRAMES));
    counters->rx_verified = rd(ctx, RTLNET_TXO_REG_CNT_RX(RTLNET_TXO_CNT_RX_VERIFIED));
    counters->rx_ip_bad = rd(ctx, RTLNET_TXO_REG_CNT_RX(RTLNET_TXO_CNT_RX_IP_BAD));
    counters->rx_l4_bad = rd(ctx, RTLNET_TXO_REG_CNT_RX(RTLNET_TXO_CNT_RX_L4_BAD));
    counters->rx_unverified = rd(ctx, RTLNET_TXO_REG_CNT_RX(RTLNET_TXO_CNT_RX_UNVERIFIED));
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_clear_counters -- clear every counter.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_clear_counters(const rtlnet_tcp_offload_t *ctx)
{
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    wr(ctx, RTLNET_TXO_REG_CNT_CLEAR, 1u);
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_trailer_parse -- locate and decode the receive trailer.
 *
 * buf is the DMA buffer of one received frame and xfer_len the number of bytes
 * the DMA wrote. With rx_csum set xfer_len is roundup8(frame_len) + 8 and the
 * trailer is its last 8 bytes.
 *
 * Steps:
 *   1. Require xfer_len a multiple of 8 and at least 16.
 *   2. Require the marker 0xA5 in the last byte.
 *   3. Decode the fields; require roundup8(frame_len) + 8 == xfer_len.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, or RTLNET_TXO_ERR_TRAILER when
 * the buffer does not end in a consistent trailer (rx_csum was off when the
 * frame arrived, or a transfer error).
 */
int rtlnet_tcp_offload_trailer_parse(const uint8_t *buf, uint32_t xfer_len, rtlnet_txo_trailer_t *trailer)
{
    const uint8_t *t;
    uint32_t len;

    if (buf == NULL || trailer == NULL) {
        return RTLNET_TXO_ERR_ARG;
    }
    if (xfer_len < (2u * RTLNET_TXO_TRAILER_BYTES) || (xfer_len % RTLNET_TXO_TRAILER_BYTES) != 0u) {
        return RTLNET_TXO_ERR_TRAILER;
    }
    t = &buf[xfer_len - RTLNET_TXO_TRAILER_BYTES];
    if (t[7] != RTLNET_TXO_TRAILER_MARKER) {
        return RTLNET_TXO_ERR_TRAILER;
    }
    len = (uint32_t)t[0] | ((uint32_t)t[1] << 8);
    if (len == 0u || RTLNET_TXO_ROUNDUP8(len) + RTLNET_TXO_TRAILER_BYTES != xfer_len) {
        return RTLNET_TXO_ERR_TRAILER;
    }
    trailer->frame_len = (uint16_t)len;
    trailer->l4_sum = (uint16_t)((uint32_t)t[2] | ((uint32_t)t[3] << 8));
    trailer->flags = (uint16_t)((uint32_t)t[4] | ((uint32_t)t[5] << 8));
    trailer->l4_offset = t[6];
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_rx_verdict -- decide what to do with a received frame.
 *
 * Policy: an IPv4 frame whose header is malformed or whose header checksum is
 * bad is dropped (the CPU stack's IP checksum check is off while rx_csum is on);
 * a TCP/UDP segment whose checksum is bad is dropped; a verified, good frame
 * passes; a frame the engine could not check (not IP, fragment, other protocol,
 * UDP checksum 0) passes unverified.
 * Returns: the verdict (RTLNET_TXO_RX_PASS_UNVERIFIED for a NULL trailer).
 */
rtlnet_txo_rx_verdict_t rtlnet_tcp_offload_rx_verdict(const rtlnet_txo_trailer_t *trailer)
{
    uint16_t f;

    if (trailer == NULL) {
        return RTLNET_TXO_RX_PASS_UNVERIFIED;
    }
    f = trailer->flags;
    if ((f & RTLNET_TXO_TRF_IS_IPV4) != 0u && (f & RTLNET_TXO_TRF_IP_OK) == 0u) {
        return RTLNET_TXO_RX_DROP_BAD_IP;
    }
    if ((f & RTLNET_TXO_TRF_VERIFIED) != 0u) {
        return ((f & RTLNET_TXO_TRF_L4_OK) != 0u) ? RTLNET_TXO_RX_PASS_VERIFIED : RTLNET_TXO_RX_DROP_BAD_L4;
    }
    return RTLNET_TXO_RX_PASS_UNVERIFIED;
}
