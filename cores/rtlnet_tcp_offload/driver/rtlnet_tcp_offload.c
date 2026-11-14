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
 *   2. Read CAPS and LATENCY into the context, CAPS2 when a feature is built.
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
    ctx->ack_present = ((caps & RTLNET_TXO_CAPS_ACK_COALESCE) != 0u) ? 1u : 0u;
    ctx->batch_present = ((caps & RTLNET_TXO_CAPS_RX_BATCH) != 0u) ? 1u : 0u;
    ctx->ack_flows = 0u;
    ctx->batch_reserve = 0u;
    if (ctx->ack_present != 0u || ctx->batch_present != 0u) {
        uint32_t caps2 = rd(ctx, RTLNET_TXO_REG_CAPS2);
        ctx->ack_flows = (ctx->ack_present != 0u) ? RTLNET_TXO_CAPS2_ACK_FLOWS(caps2) : 0u;
        ctx->batch_reserve = (ctx->batch_present != 0u) ? RTLNET_TXO_CAPS2_BAT_RESERVE(caps2) : 0u;
    }
    ctx->feat_ctrl = 0u;
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
 *   2. Write CTRL (the feature bits stay as rtlnet_tcp_offload_set_features set
 *      them), read it back.
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
    wr(ctx, RTLNET_TXO_REG_CTRL, ctrl | ctx->feat_ctrl);
    return (rd(ctx, RTLNET_TXO_REG_CTRL) == (ctrl | ctx->feat_ctrl)) ? RTLNET_TXO_OK : RTLNET_TXO_ERR_READBACK;
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
 * rtlnet_tcp_offload_set_features -- switch ACK coalescing and receive batching.
 *
 * features is a combination of RTLNET_TXO_CTRL_ACK_COALESCE and RTLNET_TXO_CTRL_RX_BATCH (0 switches both off);
 * the checksum bits of CTRL are kept as they are. Both features work on the receive trailer, so
 * RTLNET_TXO_CTRL_RX_CSUM must be on while they are (the caller's order: rx_csum on first, features off first).
 * Switching a feature off makes the hardware forward what it holds; wait_features_idle tells when that is done.
 *
 * Steps:
 *   1. Reject other bits, and features the build does not have.
 *   2. Read CTRL, replace the feature bits, write, read back.
 *   3. Remember the bits so rtlnet_tcp_offload_set_ctrl keeps them.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, RTLNET_TXO_ERR_UNSUPPORTED, RTLNET_TXO_ERR_READBACK,
 * RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_set_features(rtlnet_tcp_offload_t *ctx, uint32_t features)
{
    uint32_t ctrl;
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    if ((features & ~RTLNET_TXO_CTRL_FEATURE_MASK) != 0u) {
        return RTLNET_TXO_ERR_ARG;
    }
    if (((features & RTLNET_TXO_CTRL_ACK_COALESCE) != 0u && ctx->ack_present == 0u) ||
        ((features & RTLNET_TXO_CTRL_RX_BATCH) != 0u && ctx->batch_present == 0u)) {
        return RTLNET_TXO_ERR_UNSUPPORTED;
    }
    ctrl = (rd(ctx, RTLNET_TXO_REG_CTRL) & ~RTLNET_TXO_CTRL_FEATURE_MASK) | features;
    wr(ctx, RTLNET_TXO_REG_CTRL, ctrl);
    if (rd(ctx, RTLNET_TXO_REG_CTRL) != ctrl) {
        return RTLNET_TXO_ERR_READBACK;
    }
    ctx->feat_ctrl = features;
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_wait_features_idle -- wait until the ACK coalescer and the batcher (those that are built)
 * hold nothing: no held ACK, no open batch. Used after switching a feature off.
 * max_polls bounds the STATUS reads (0 selects RTLNET_TXO_IDLE_POLL_DEFAULT). A held ACK or open batch is released
 * by its timer at the latest, so the bound has to cover the timer registers.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_TIMEOUT, RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_wait_features_idle(const rtlnet_tcp_offload_t *ctx, uint32_t max_polls)
{
    uint32_t want;
    uint32_t i;
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    want = ((ctx->ack_present != 0u) ? RTLNET_TXO_STATUS_ACK_IDLE : 0u) |
           ((ctx->batch_present != 0u) ? RTLNET_TXO_STATUS_BAT_IDLE : 0u);
    if (max_polls == 0u) {
        max_polls = RTLNET_TXO_IDLE_POLL_DEFAULT;
    }
    for (i = 0u; i < max_polls; i++) {
        if ((rd(ctx, RTLNET_TXO_REG_STATUS) & want) == want) {
            return RTLNET_TXO_OK;
        }
    }
    return RTLNET_TXO_ERR_TIMEOUT;
}

/*
 * rtlnet_tcp_offload_ack_config -- ACK coalescer timer and limit.
 *
 * timer_us: microseconds a held ACK waits at most (0..65535; 0 forwards at the next opportunity). limit: ACKs
 * dropped per forwarded ACK at most (0..255; 0 and 1 act as 1). Written and read back.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, RTLNET_TXO_ERR_UNSUPPORTED (no coalescer), RTLNET_TXO_ERR_READBACK,
 * RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_ack_config(const rtlnet_tcp_offload_t *ctx, uint32_t timer_us, uint32_t limit)
{
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    if (timer_us > 0xFFFFu || limit > 0xFFu) {
        return RTLNET_TXO_ERR_ARG;
    }
    if (ctx->ack_present == 0u) {
        return RTLNET_TXO_ERR_UNSUPPORTED;
    }
    wr(ctx, RTLNET_TXO_REG_ACK_TIMER, timer_us);
    wr(ctx, RTLNET_TXO_REG_ACK_LIMIT, limit);
    if (rd(ctx, RTLNET_TXO_REG_ACK_TIMER) != timer_us || rd(ctx, RTLNET_TXO_REG_ACK_LIMIT) != limit) {
        return RTLNET_TXO_ERR_READBACK;
    }
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_batch_config -- receive batcher timer and limits.
 *
 * timer_us: microseconds a batch waits after its first frame was complete (0..65535). max_frames: frames per batch
 * (0..255, at most RTLNET_TXO_BATCH_MAX_FRAMES for a firmware that uses the walker as is; 0 and 1: every frame
 * alone). max_bytes: bytes per batch, at least one full frame (RTLNET_TXO_RX_BUFFER_BYTES(1522)) and at most 65535;
 * the hardware closes a batch as soon as a next frame of up to 2048 bytes might not fit, so the buffer of a batch
 * is max_bytes long. Written and read back.
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, RTLNET_TXO_ERR_UNSUPPORTED (no batcher), RTLNET_TXO_ERR_READBACK,
 * RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_batch_config(const rtlnet_tcp_offload_t *ctx, uint32_t timer_us, uint32_t max_frames,
                                    uint32_t max_bytes)
{
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    if (timer_us > 0xFFFFu || max_frames > RTLNET_TXO_BATCH_MAX_FRAMES || max_bytes > 0xFFFFu ||
        max_bytes < RTLNET_TXO_RX_BUFFER_BYTES(1522u)) {
        return RTLNET_TXO_ERR_ARG;
    }
    if (ctx->batch_present == 0u) {
        return RTLNET_TXO_ERR_UNSUPPORTED;
    }
    wr(ctx, RTLNET_TXO_REG_BAT_TIMER, timer_us);
    wr(ctx, RTLNET_TXO_REG_BAT_FRAMES, max_frames);
    wr(ctx, RTLNET_TXO_REG_BAT_BYTES, max_bytes);
    if (rd(ctx, RTLNET_TXO_REG_BAT_TIMER) != timer_us || rd(ctx, RTLNET_TXO_REG_BAT_FRAMES) != max_frames ||
        rd(ctx, RTLNET_TXO_REG_BAT_BYTES) != max_bytes) {
        return RTLNET_TXO_ERR_READBACK;
    }
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_feature_counters -- read the ACK coalescer and batcher counters (0 for a feature not built).
 * Returns: RTLNET_TXO_OK, RTLNET_TXO_ERR_ARG, RTLNET_TXO_ERR_NOT_INIT.
 */
int rtlnet_tcp_offload_feature_counters(const rtlnet_tcp_offload_t *ctx, rtlnet_txo_feat_counters_t *counters)
{
    uint32_t i;
    int rc = ready(ctx);

    if (rc != RTLNET_TXO_OK) {
        return rc;
    }
    if (counters == NULL) {
        return RTLNET_TXO_ERR_ARG;
    }
    for (i = 0u; i < RTLNET_TXO_NUM_ACK_COUNTERS; i++) {
        counters->ack[i] = (ctx->ack_present != 0u) ? rd(ctx, RTLNET_TXO_REG_CNT_ACK(i)) : 0u;
    }
    for (i = 0u; i < RTLNET_TXO_NUM_BAT_COUNTERS; i++) {
        counters->bat[i] = (ctx->batch_present != 0u) ? rd(ctx, RTLNET_TXO_REG_CNT_BAT(i)) : 0u;
    }
    return RTLNET_TXO_OK;
}

/*
 * rtlnet_tcp_offload_batch_walk -- split one received DMA transfer into its frames.
 *
 * buf holds xfer_len bytes the DMA wrote. With receive batching (or rx_csum alone: a batch of one) the transfer is
 * [frame padded to 8 bytes][trailer] repeated; the trailer, not the frame, carries the length, so the walk starts
 * at the end: the last 8 bytes are a trailer, its length field says where its frame starts, the 8 bytes before that
 * are the previous trailer, and so on until offset 0. Frames are returned in arrival order.
 *
 * Every step is bounds-checked against what remains of the buffer: a transfer that is not a multiple of 8 bytes or
 * shorter than 16, a missing marker, a zero or oversized length, a length that points before the start of the
 * buffer, or a remainder too short for another frame all return RTLNET_TXO_ERR_BATCH and *count 0. More than
 * max_frames frames return RTLNET_TXO_ERR_FULL, *count 0. The padding bytes are not inspected.
 *
 * Steps:
 *   1. Validate arguments and the transfer length.
 *   2. Walk backwards, filling frames[0..n-1] from the end.
 *   3. Reverse the array in place.
 * Returns: RTLNET_TXO_OK with *count frames (at least 1), RTLNET_TXO_ERR_ARG, RTLNET_TXO_ERR_BATCH,
 * RTLNET_TXO_ERR_FULL.
 */
int rtlnet_tcp_offload_batch_walk(const uint8_t *buf, uint32_t xfer_len, rtlnet_txo_batch_frame_t *frames,
                                  uint32_t max_frames, uint32_t *count)
{
    uint32_t pos;
    uint32_t n = 0u;
    uint32_t i;

    if (buf == NULL || frames == NULL || count == NULL || max_frames == 0u) {
        return RTLNET_TXO_ERR_ARG;
    }
    *count = 0u;
    if (xfer_len < (2u * RTLNET_TXO_TRAILER_BYTES) || (xfer_len % RTLNET_TXO_TRAILER_BYTES) != 0u) {
        return RTLNET_TXO_ERR_BATCH;
    }
    pos = xfer_len;
    while (pos != 0u) {
        const uint8_t *t;
        uint32_t len;
        uint32_t span;

        if (pos < (2u * RTLNET_TXO_TRAILER_BYTES)) {
            return RTLNET_TXO_ERR_BATCH;
        }
        t = &buf[pos - RTLNET_TXO_TRAILER_BYTES];
        if (t[7] != RTLNET_TXO_TRAILER_MARKER) {
            return RTLNET_TXO_ERR_BATCH;
        }
        len = (uint32_t)t[0] | ((uint32_t)t[1] << 8);
        if (len == 0u || len > RTLNET_TXO_BATCH_MAX_FRAME) {
            return RTLNET_TXO_ERR_BATCH;
        }
        span = RTLNET_TXO_ROUNDUP8(len) + RTLNET_TXO_TRAILER_BYTES;
        if (span > pos) {
            return RTLNET_TXO_ERR_BATCH;
        }
        if (n >= max_frames) {
            return RTLNET_TXO_ERR_FULL;
        }
        pos -= span;
        frames[n].offset = pos;
        frames[n].trailer.frame_len = (uint16_t)len;
        frames[n].trailer.l4_sum = (uint16_t)((uint32_t)t[2] | ((uint32_t)t[3] << 8));
        frames[n].trailer.flags = (uint16_t)((uint32_t)t[4] | ((uint32_t)t[5] << 8));
        frames[n].trailer.l4_offset = t[6];
        n++;
    }
    for (i = 0u; i < n / 2u; i++) {
        rtlnet_txo_batch_frame_t tmp = frames[i];
        frames[i] = frames[n - 1u - i];
        frames[n - 1u - i] = tmp;
    }
    *count = n;
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
