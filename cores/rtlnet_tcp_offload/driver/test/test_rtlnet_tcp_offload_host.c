/*
 * test_rtlnet_tcp_offload_host.c -- host unit test of the rtlnet_tcp_offload driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_tcp_offload.c unmodified (built with RTLNET_HOST_TEST)
 * against a register model of the core, mirroring the RTL register file
 * (cores/rtlnet_tcp_offload/hdl/rtlnet_tcp_offload_regs.sv):
 *   - ID, VERSION, CAPS, LATENCY constants for a chosen build;
 *   - CTRL: bits 2:0 stored and read back exactly, the rest ignored;
 *   - STATUS idle bits (TX idle rises after a chosen number of reads);
 *   - CNT_CLEAR: a write of bit 0 clears every counter, reads 0;
 *   - counters read-only; undefined offsets read 0 and ignore writes;
 *   - the feature build (ACK coalescer, batcher): CTRL bits 4:3, STATUS idle bits 3:2 (rising after a chosen number
 *     of reads), CAPS2, the five configuration registers, the two counter blocks.
 * It also checks the trailer decoder and the receive verdict on hand-built
 * buffers, and the error paths (absent core, unsupported CTRL bits, read-back
 * mismatch, idle timeout), the feature configuration, and the batch walker on
 * hand-built batches, malformed input (truncated, bad length, misaligned, bad
 * marker, too many frames) and random batches and random buffers.
 *
 * Output: exactly one line, "TEST PASS: rtlnet_tcp_offload_host checks=N" or
 * "TEST FAIL: rtlnet_tcp_offload_host fails=F checks=N first=<msg>".
 * Argument --inject-failure forces a failure (negative control). Exit code 0
 * on PASS.
 */
#include "rtlnet_tcp_offload.h"

#include <stdio.h>    /* printf, snprintf */
#include <string.h>   /* memset, strcmp */

static int g_checks;
static int g_fails;
static char g_first[200];

static void check(int cond, const char *msg)
{
    g_checks++;
    if (!cond) {
        g_fails++;
        if (g_first[0] == '\0') {
            snprintf(g_first, sizeof g_first, "%s", msg);
        }
        printf("CHECK FAILED: %s\n", msg);
    }
}

/* -------------------------------------------------------------------------
 * Register model
 * ------------------------------------------------------------------------- */
#define TB_BASE   ((uintptr_t)0x44A19000u)

static uint32_t g_id;
static uint32_t g_version;
static uint32_t g_caps;
static uint32_t g_ctrl;
static uint32_t g_ctrl_stuck_mask;        /* bits that ignore writes (read-back mismatch) */
static uint32_t g_status_reads;
static uint32_t g_idle_after;             /* STATUS reads before TX idle rises; 0xFFFFFFFF = never */
static uint32_t g_cnt_tx[RTLNET_TXO_NUM_TX_COUNTERS];
static uint32_t g_cnt_rx[RTLNET_TXO_NUM_RX_COUNTERS];
static uint32_t g_clear_count;
static uint32_t g_writes_undefined;
static uint32_t g_feat_mask;              /* CTRL bits 4:3 the model has (0: checksum-only build) */
static uint32_t g_caps2;
static uint32_t g_ack_timer;
static uint32_t g_ack_limit;
static uint32_t g_bat_timer;
static uint32_t g_bat_frames;
static uint32_t g_bat_bytes;
static uint32_t g_cnt_ack[RTLNET_TXO_NUM_ACK_COUNTERS];
static uint32_t g_cnt_bat[RTLNET_TXO_NUM_BAT_COUNTERS];
static uint32_t g_feat_idle_after;        /* STATUS reads before the feature idle bits rise */

static uint32_t model_caps(uint32_t tx, uint32_t rx, uint32_t kb)
{
    uint32_t c = 0u;

    c |= (tx != 0u) ? RTLNET_TXO_CAPS_TX_PRESENT : 0u;
    c |= (rx != 0u) ? RTLNET_TXO_CAPS_RX_PRESENT : 0u;
    c |= RTLNET_TXO_CAPS_INS_IP | RTLNET_TXO_CAPS_INS_TCP | RTLNET_TXO_CAPS_INS_UDP | RTLNET_TXO_CAPS_VLAN;
    c |= (kb << 8) | (1518u << 16);
    return c;
}

static void model_reset(uint32_t caps)
{
    uint32_t i;

    g_id = RTLNET_TXO_ID_VALUE;
    g_version = RTLNET_TXO_VERSION_VALUE;
    g_caps = caps;
    g_ctrl = 0u;
    g_ctrl_stuck_mask = 0u;
    g_status_reads = 0u;
    g_idle_after = 2u;
    g_clear_count = 0u;
    g_writes_undefined = 0u;
    g_feat_mask = 0u;
    g_caps2 = 0u;
    g_ack_timer = 0u;
    g_ack_limit = 0u;
    g_bat_timer = 0u;
    g_bat_frames = 0u;
    g_bat_bytes = 0u;
    g_feat_idle_after = 0u;
    for (i = 0u; i < RTLNET_TXO_NUM_ACK_COUNTERS; i++) {
        g_cnt_ack[i] = 300u + i;
    }
    for (i = 0u; i < RTLNET_TXO_NUM_BAT_COUNTERS; i++) {
        g_cnt_bat[i] = 400u + i;
    }
    for (i = 0u; i < RTLNET_TXO_NUM_TX_COUNTERS; i++) {
        g_cnt_tx[i] = 100u + i;
    }
    for (i = 0u; i < RTLNET_TXO_NUM_RX_COUNTERS; i++) {
        g_cnt_rx[i] = 200u + i;
    }
}

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TB_BASE);
    uint32_t i;

    switch (off) {
    case RTLNET_TXO_REG_ID:
        return g_id;
    case RTLNET_TXO_REG_VERSION:
        return g_version;
    case RTLNET_TXO_REG_CAPS:
        return g_caps;
    case RTLNET_TXO_REG_CTRL:
        return g_ctrl;
    case RTLNET_TXO_REG_STATUS: {
        uint32_t st;

        g_status_reads++;
        st = (g_idle_after != 0xFFFFFFFFu && g_status_reads > g_idle_after)
             ? (RTLNET_TXO_STATUS_TX_IDLE | RTLNET_TXO_STATUS_RX_IDLE) : RTLNET_TXO_STATUS_RX_IDLE;
        if (g_feat_idle_after != 0xFFFFFFFFu && g_status_reads > g_feat_idle_after) {
            st |= RTLNET_TXO_STATUS_ACK_IDLE | RTLNET_TXO_STATUS_BAT_IDLE;
        }
        return st;
    }
    case RTLNET_TXO_REG_CAPS2:
        return g_caps2;
    case RTLNET_TXO_REG_ACK_TIMER:
        return g_ack_timer;
    case RTLNET_TXO_REG_ACK_LIMIT:
        return g_ack_limit;
    case RTLNET_TXO_REG_BAT_TIMER:
        return g_bat_timer;
    case RTLNET_TXO_REG_BAT_FRAMES:
        return g_bat_frames;
    case RTLNET_TXO_REG_BAT_BYTES:
        return g_bat_bytes;
    case RTLNET_TXO_REG_LATENCY:
        return 18u | (17u << 8);
    default:
        break;
    }
    for (i = 0u; i < RTLNET_TXO_NUM_TX_COUNTERS; i++) {
        if (off == RTLNET_TXO_REG_CNT_TX(i)) {
            return g_cnt_tx[i];
        }
    }
    for (i = 0u; i < RTLNET_TXO_NUM_RX_COUNTERS; i++) {
        if (off == RTLNET_TXO_REG_CNT_RX(i)) {
            return g_cnt_rx[i];
        }
    }
    for (i = 0u; i < RTLNET_TXO_NUM_ACK_COUNTERS; i++) {
        if (off == RTLNET_TXO_REG_CNT_ACK(i)) {
            return g_cnt_ack[i];
        }
    }
    for (i = 0u; i < RTLNET_TXO_NUM_BAT_COUNTERS; i++) {
        if (off == RTLNET_TXO_REG_CNT_BAT(i)) {
            return g_cnt_bat[i];
        }
    }
    return 0u;
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TB_BASE);
    uint32_t i;

    if (off == RTLNET_TXO_REG_CTRL) {
        g_ctrl = (g_ctrl & g_ctrl_stuck_mask) |
                 (value & (RTLNET_TXO_CTRL_MASK | g_feat_mask) & ~g_ctrl_stuck_mask);
    } else if (off == RTLNET_TXO_REG_ACK_TIMER) {
        g_ack_timer = value & 0xFFFFu;
    } else if (off == RTLNET_TXO_REG_ACK_LIMIT) {
        g_ack_limit = value & 0xFFu;
    } else if (off == RTLNET_TXO_REG_BAT_TIMER) {
        g_bat_timer = value & 0xFFFFu;
    } else if (off == RTLNET_TXO_REG_BAT_FRAMES) {
        g_bat_frames = value & 0xFFu;
    } else if (off == RTLNET_TXO_REG_BAT_BYTES) {
        g_bat_bytes = value & 0xFFFFu;
    } else if (off == RTLNET_TXO_REG_CNT_CLEAR) {
        if ((value & 1u) != 0u) {
            g_clear_count++;
            for (i = 0u; i < RTLNET_TXO_NUM_TX_COUNTERS; i++) {
                g_cnt_tx[i] = 0u;
            }
            for (i = 0u; i < RTLNET_TXO_NUM_RX_COUNTERS; i++) {
                g_cnt_rx[i] = 0u;
            }
            for (i = 0u; i < RTLNET_TXO_NUM_ACK_COUNTERS; i++) {
                g_cnt_ack[i] = 0u;
            }
            for (i = 0u; i < RTLNET_TXO_NUM_BAT_COUNTERS; i++) {
                g_cnt_bat[i] = 0u;
            }
        }
    } else {
        g_writes_undefined++;
    }
}

/* -------------------------------------------------------------------------
 * Trailer helper: build a buffer of a frame of len bytes with a trailer
 * ------------------------------------------------------------------------- */
static uint32_t build_buf(uint8_t *buf, uint32_t len, uint16_t sum, uint16_t flags, uint8_t l4off)
{
    uint32_t n = RTLNET_TXO_ROUNDUP8(len);
    uint32_t i;

    memset(buf, 0, 2048);
    for (i = 0u; i < len; i++) {
        buf[i] = (uint8_t)(i * 7u + 3u);
    }
    buf[n + 0u] = (uint8_t)(len & 0xFFu);
    buf[n + 1u] = (uint8_t)(len >> 8);
    buf[n + 2u] = (uint8_t)(sum & 0xFFu);
    buf[n + 3u] = (uint8_t)(sum >> 8);
    buf[n + 4u] = (uint8_t)(flags & 0xFFu);
    buf[n + 5u] = (uint8_t)(flags >> 8);
    buf[n + 6u] = l4off;
    buf[n + 7u] = RTLNET_TXO_TRAILER_MARKER;
    return n + RTLNET_TXO_TRAILER_BYTES;
}

/* Append one frame of len bytes and its trailer at buf[pos]; returns the new end. Frame bytes follow a pattern of seed. */
static uint32_t append_frame(uint8_t *buf, uint32_t pos, uint32_t len, uint8_t seed, uint16_t flags)
{
    uint32_t n = RTLNET_TXO_ROUNDUP8(len);
    uint32_t i;

    for (i = 0u; i < n; i++) {
        buf[pos + i] = (i < len) ? (uint8_t)(i * 5u + seed) : 0u;
    }
    buf[pos + n + 0u] = (uint8_t)(len & 0xFFu);
    buf[pos + n + 1u] = (uint8_t)(len >> 8);
    buf[pos + n + 2u] = (uint8_t)(seed);
    buf[pos + n + 3u] = (uint8_t)(seed >> 1);
    buf[pos + n + 4u] = (uint8_t)(flags & 0xFFu);
    buf[pos + n + 5u] = (uint8_t)(flags >> 8);
    buf[pos + n + 6u] = (uint8_t)(34u);
    buf[pos + n + 7u] = RTLNET_TXO_TRAILER_MARKER;
    return pos + n + RTLNET_TXO_TRAILER_BYTES;
}

static uint32_t g_rng = 0x2545F491u;

static uint32_t rnd(void)
{
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 17;
    g_rng ^= g_rng << 5;
    return g_rng;
}

/* Feature build model: both features, 4 flows, 2056-byte reserve. */
static void feature_model(void)
{
    model_reset(model_caps(1u, 1u, 8u) | RTLNET_TXO_CAPS_ACK_COALESCE | RTLNET_TXO_CAPS_RX_BATCH);
    g_feat_mask = RTLNET_TXO_CTRL_FEATURE_MASK;
    g_caps2 = 4u | (2056u << 8);
    g_ack_timer = RTLNET_TXO_ACK_TIMER_DEFAULT;
    g_ack_limit = RTLNET_TXO_ACK_LIMIT_DEFAULT;
    g_bat_timer = RTLNET_TXO_BAT_TIMER_DEFAULT;
    g_bat_frames = RTLNET_TXO_BAT_FRAMES_DEFAULT;
    g_bat_bytes = RTLNET_TXO_BAT_BYTES_DEFAULT;
}

static void test_features(void)
{
    rtlnet_tcp_offload_t ctx;
    rtlnet_txo_feat_counters_t fc;
    uint32_t v;

    /* Discovery. */
    feature_model();
    check(rtlnet_tcp_offload_init(&ctx, TB_BASE) == RTLNET_TXO_OK, "feature build: init");
    check(ctx.ack_present == 1u && ctx.batch_present == 1u, "feature build: caps bits");
    check(ctx.ack_flows == 4u && ctx.batch_reserve == 2056u, "feature build: CAPS2 fields");
    model_reset(model_caps(1u, 1u, 8u));
    check(rtlnet_tcp_offload_init(&ctx, TB_BASE) == RTLNET_TXO_OK && ctx.ack_present == 0u && ctx.batch_present == 0u &&
          ctx.ack_flows == 0u && ctx.batch_reserve == 0u, "checksum-only build: no features");
    check(rtlnet_tcp_offload_set_features(&ctx, RTLNET_TXO_CTRL_ACK_COALESCE) == RTLNET_TXO_ERR_UNSUPPORTED,
          "ack_coalesce refused without the feature");
    check(rtlnet_tcp_offload_set_features(&ctx, RTLNET_TXO_CTRL_RX_BATCH) == RTLNET_TXO_ERR_UNSUPPORTED,
          "rx_batch refused without the feature");
    check(rtlnet_tcp_offload_set_features(&ctx, 0u) == RTLNET_TXO_OK, "features 0 accepted everywhere");
    check(rtlnet_tcp_offload_ack_config(&ctx, 100u, 4u) == RTLNET_TXO_ERR_UNSUPPORTED, "ack_config refused without the feature");
    check(rtlnet_tcp_offload_batch_config(&ctx, 100u, 4u, 8192u) == RTLNET_TXO_ERR_UNSUPPORTED,
          "batch_config refused without the feature");
    check(rtlnet_tcp_offload_feature_counters(&ctx, &fc) == RTLNET_TXO_OK && fc.ack[0] == 0u && fc.bat[5] == 0u,
          "counters of a missing feature read 0");
    check(rtlnet_tcp_offload_wait_features_idle(&ctx, 3u) == RTLNET_TXO_OK, "no feature, nothing to wait for");

    /* CTRL bits. */
    feature_model();
    (void)rtlnet_tcp_offload_init(&ctx, TB_BASE);
    check(rtlnet_tcp_offload_set_ctrl(&ctx, RTLNET_TXO_CTRL_RX_CSUM) == RTLNET_TXO_OK, "rx_csum on");
    check(rtlnet_tcp_offload_set_features(&ctx, RTLNET_TXO_CTRL_ACK_COALESCE | RTLNET_TXO_CTRL_RX_BATCH) == RTLNET_TXO_OK,
          "both features on");
    check(g_ctrl == (RTLNET_TXO_CTRL_RX_CSUM | RTLNET_TXO_CTRL_FEATURE_MASK), "CTRL holds rx_csum and both features");
    check(rtlnet_tcp_offload_set_ctrl(&ctx, RTLNET_TXO_CTRL_RX_CSUM | RTLNET_TXO_CTRL_TX_IP_CSUM) == RTLNET_TXO_OK,
          "set_ctrl keeps the feature bits");
    check(g_ctrl == (RTLNET_TXO_CTRL_RX_CSUM | RTLNET_TXO_CTRL_TX_IP_CSUM | RTLNET_TXO_CTRL_FEATURE_MASK),
          "CTRL after set_ctrl: features stay");
    check(rtlnet_tcp_offload_set_ctrl(&ctx, 0x8u) == RTLNET_TXO_ERR_ARG, "set_ctrl still takes the checksum bits only");
    check(rtlnet_tcp_offload_set_features(&ctx, RTLNET_TXO_CTRL_RX_CSUM) == RTLNET_TXO_ERR_ARG, "set_features takes the feature bits only");
    check(rtlnet_tcp_offload_set_features(NULL, 0u) == RTLNET_TXO_ERR_ARG, "set_features NULL ctx");
    check(rtlnet_tcp_offload_set_features(&ctx, RTLNET_TXO_CTRL_ACK_COALESCE) == RTLNET_TXO_OK, "one feature");
    check(g_ctrl == (RTLNET_TXO_CTRL_RX_CSUM | RTLNET_TXO_CTRL_TX_IP_CSUM | RTLNET_TXO_CTRL_ACK_COALESCE),
          "rx_batch cleared, the checksum bits kept");
    check(rtlnet_tcp_offload_set_features(&ctx, 0u) == RTLNET_TXO_OK && (g_ctrl & RTLNET_TXO_CTRL_FEATURE_MASK) == 0u,
          "features off");
    check(rtlnet_tcp_offload_set_ctrl(&ctx, 0u) == RTLNET_TXO_OK && g_ctrl == 0u, "set_ctrl 0 after features off");
    g_ctrl_stuck_mask = RTLNET_TXO_CTRL_RX_BATCH;
    check(rtlnet_tcp_offload_set_features(&ctx, RTLNET_TXO_CTRL_RX_BATCH) == RTLNET_TXO_ERR_READBACK,
          "feature read-back mismatch detected");
    g_ctrl_stuck_mask = 0u;
    check(ctx.feat_ctrl == 0u, "a failed set_features leaves the remembered bits alone");

    /* Configuration registers. */
    check(rtlnet_tcp_offload_ack_config(&ctx, 250u, 12u) == RTLNET_TXO_OK && g_ack_timer == 250u && g_ack_limit == 12u,
          "ack_config written");
    check(rtlnet_tcp_offload_ack_config(&ctx, 65535u, 255u) == RTLNET_TXO_OK && g_ack_timer == 65535u && g_ack_limit == 255u,
          "ack_config maximum");
    check(rtlnet_tcp_offload_ack_config(&ctx, 0u, 0u) == RTLNET_TXO_OK && g_ack_timer == 0u, "ack_config zero");
    check(rtlnet_tcp_offload_ack_config(&ctx, 65536u, 1u) == RTLNET_TXO_ERR_ARG, "ack timer above 16 bits refused");
    check(rtlnet_tcp_offload_ack_config(&ctx, 1u, 256u) == RTLNET_TXO_ERR_ARG, "ack limit above 8 bits refused");
    check(rtlnet_tcp_offload_batch_config(&ctx, 40u, 16u, 8192u) == RTLNET_TXO_OK && g_bat_timer == 40u &&
          g_bat_frames == 16u && g_bat_bytes == 8192u, "batch_config written");
    check(rtlnet_tcp_offload_batch_config(&ctx, 65535u, RTLNET_TXO_BATCH_MAX_FRAMES, 65535u) == RTLNET_TXO_OK,
          "batch_config maximum");
    check(rtlnet_tcp_offload_batch_config(&ctx, 0u, 0u, RTLNET_TXO_RX_BUFFER_BYTES(1522u)) == RTLNET_TXO_OK,
          "batch_config minimum buffer (one frame)");
    check(rtlnet_tcp_offload_batch_config(&ctx, 65536u, 16u, 8192u) == RTLNET_TXO_ERR_ARG, "batch timer above 16 bits refused");
    check(rtlnet_tcp_offload_batch_config(&ctx, 1u, RTLNET_TXO_BATCH_MAX_FRAMES + 1u, 8192u) == RTLNET_TXO_ERR_ARG,
          "batch frame count above the walker bound refused");
    check(rtlnet_tcp_offload_batch_config(&ctx, 1u, 16u, RTLNET_TXO_RX_BUFFER_BYTES(1522u) - 1u) == RTLNET_TXO_ERR_ARG,
          "batch bytes below one frame refused");
    check(rtlnet_tcp_offload_batch_config(&ctx, 1u, 16u, 65536u) == RTLNET_TXO_ERR_ARG, "batch bytes above 16 bits refused");
    check(g_writes_undefined == 0u, "feature registers: only defined registers written");

    /* Counters. */
    check(rtlnet_tcp_offload_feature_counters(&ctx, &fc) == RTLNET_TXO_OK, "feature counters read");
    check(fc.ack[RTLNET_TXO_CNT_ACK_CAND] == 300u && fc.ack[RTLNET_TXO_CNT_ACK_DROPPED] == 301u &&
          fc.ack[RTLNET_TXO_CNT_ACK_FWD] == 302u && fc.ack[RTLNET_TXO_CNT_ACK_FL_TIMER] == 303u &&
          fc.ack[RTLNET_TXO_CNT_ACK_FL_LIMIT] == 304u && fc.ack[RTLNET_TXO_CNT_ACK_FL_ORDER] == 305u, "ACK counters map");
    check(fc.bat[RTLNET_TXO_CNT_BAT_BATCHES] == 400u && fc.bat[RTLNET_TXO_CNT_BAT_FRAMES] == 401u &&
          fc.bat[RTLNET_TXO_CNT_BAT_CL_BYTES] == 402u && fc.bat[RTLNET_TXO_CNT_BAT_CL_COUNT] == 403u &&
          fc.bat[RTLNET_TXO_CNT_BAT_CL_TIMER] == 404u && fc.bat[RTLNET_TXO_CNT_BAT_CL_OTHER] == 405u, "batch counters map");
    check(rtlnet_tcp_offload_clear_counters(&ctx) == RTLNET_TXO_OK, "clear");
    check(rtlnet_tcp_offload_feature_counters(&ctx, &fc) == RTLNET_TXO_OK && fc.ack[0] == 0u && fc.bat[5] == 0u,
          "feature counters cleared");
    check(rtlnet_tcp_offload_feature_counters(&ctx, NULL) == RTLNET_TXO_ERR_ARG, "NULL feature counters refused");

    /* Idle wait. */
    g_status_reads = 0u;
    g_feat_idle_after = 4u;
    check(rtlnet_tcp_offload_wait_features_idle(&ctx, 20u) == RTLNET_TXO_OK && g_status_reads == 5u, "features idle seen");
    g_status_reads = 0u;
    g_feat_idle_after = 0xFFFFFFFFu;
    check(rtlnet_tcp_offload_wait_features_idle(&ctx, 6u) == RTLNET_TXO_ERR_TIMEOUT && g_status_reads == 6u,
          "features idle wait is bounded");
    v = 0u;
    check(rtlnet_tcp_offload_get_ctrl(&ctx, &v) == RTLNET_TXO_OK, "get_ctrl after the feature tests");
}

static void test_walk(void)
{
    static uint8_t buf[20000];
    rtlnet_txo_batch_frame_t fr[RTLNET_TXO_BATCH_MAX_FRAMES];
    rtlnet_txo_trailer_t tr;
    uint32_t n = 99u;
    uint32_t pos;
    uint32_t i;
    uint32_t t;

    /* Three frames: 60, 1514 and 1 bytes. */
    pos = 0u;
    pos = append_frame(buf, pos, 60u, 11u, RTLNET_TXO_TRF_IS_IPV4 | RTLNET_TXO_TRF_IP_OK);
    pos = append_frame(buf, pos, 1514u, 22u, RTLNET_TXO_TRF_IS_TCP | RTLNET_TXO_TRF_VERIFIED);
    pos = append_frame(buf, pos, 1u, 33u, 0u);
    check(pos == 72u + 1528u + 16u, "batch of three: length");
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, RTLNET_TXO_BATCH_MAX_FRAMES, &n) == RTLNET_TXO_OK && n == 3u,
          "walk: three frames");
    check(fr[0].offset == 0u && fr[0].trailer.frame_len == 60u && fr[0].trailer.l4_sum == 0x050Bu &&
          fr[0].trailer.flags == (RTLNET_TXO_TRF_IS_IPV4 | RTLNET_TXO_TRF_IP_OK) && fr[0].trailer.l4_offset == 34u,
          "walk: first frame and its trailer");
    check(fr[1].offset == 72u && fr[1].trailer.frame_len == 1514u && fr[1].trailer.flags == (RTLNET_TXO_TRF_IS_TCP | RTLNET_TXO_TRF_VERIFIED),
          "walk: second frame");
    check(fr[2].offset == 72u + 1528u && fr[2].trailer.frame_len == 1u, "walk: third frame");
    check(buf[fr[1].offset + 5u] == (uint8_t)(5u * 5u + 22u), "walk: offset points at the frame bytes");

    /* One frame (the plain rx_csum transfer) and the largest frame. */
    pos = append_frame(buf, 0u, 100u, 5u, 0u);
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 1u, &n) == RTLNET_TXO_OK && n == 1u && fr[0].offset == 0u &&
          fr[0].trailer.frame_len == 100u, "walk: single frame");
    check(rtlnet_tcp_offload_trailer_parse(buf, pos, &tr) == RTLNET_TXO_OK && tr.frame_len == fr[0].trailer.frame_len,
          "walk agrees with trailer_parse for one frame");
    pos = append_frame(buf, 0u, RTLNET_TXO_BATCH_MAX_FRAME, 6u, 0u);
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 2u, &n) == RTLNET_TXO_OK && n == 1u &&
          fr[0].trailer.frame_len == RTLNET_TXO_BATCH_MAX_FRAME, "walk: largest frame");
    pos = append_frame(buf, 0u, RTLNET_TXO_BATCH_MAX_FRAME, 6u, 0u);
    buf[pos - 8u] = (uint8_t)((RTLNET_TXO_BATCH_MAX_FRAME + 1u) & 0xFFu);
    buf[pos - 7u] = (uint8_t)((RTLNET_TXO_BATCH_MAX_FRAME + 1u) >> 8);
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 2u, &n) == RTLNET_TXO_ERR_BATCH && n == 0u, "walk: frame above 3072 refused");

    /* Exactly max_frames frames fit; one more is FULL. */
    pos = 0u;
    for (i = 0u; i < RTLNET_TXO_BATCH_MAX_FRAMES; i++) {
        pos = append_frame(buf, pos, 14u + i, (uint8_t)i, 0u);
    }
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, RTLNET_TXO_BATCH_MAX_FRAMES, &n) == RTLNET_TXO_OK &&
          n == RTLNET_TXO_BATCH_MAX_FRAMES && fr[63].trailer.frame_len == 14u + 63u && fr[0].trailer.frame_len == 14u,
          "walk: 64 frames in a 64-entry array");
    n = 7u;
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, RTLNET_TXO_BATCH_MAX_FRAMES - 1u, &n) == RTLNET_TXO_ERR_FULL && n == 0u,
          "walk: one frame too many is FULL, count 0");
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 1u, &n) == RTLNET_TXO_ERR_FULL, "walk: FULL with room for one");

    /* Malformed input. */
    pos = 0u;
    pos = append_frame(buf, pos, 60u, 1u, 0u);
    pos = append_frame(buf, pos, 200u, 2u, 0u);
    check(rtlnet_tcp_offload_batch_walk(NULL, pos, fr, 4u, &n) == RTLNET_TXO_ERR_ARG, "walk: NULL buffer");
    check(rtlnet_tcp_offload_batch_walk(buf, pos, NULL, 4u, &n) == RTLNET_TXO_ERR_ARG, "walk: NULL frames");
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 4u, NULL) == RTLNET_TXO_ERR_ARG, "walk: NULL count");
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 0u, &n) == RTLNET_TXO_ERR_ARG, "walk: zero-size array");
    n = 5u;
    check(rtlnet_tcp_offload_batch_walk(buf, 0u, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH && n == 0u, "walk: empty transfer");
    check(rtlnet_tcp_offload_batch_walk(buf, 8u, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: 8 bytes");
    check(rtlnet_tcp_offload_batch_walk(buf, pos + 1u, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: misaligned length (+1)");
    check(rtlnet_tcp_offload_batch_walk(buf, pos + 4u, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: misaligned length (+4)");
    check(rtlnet_tcp_offload_batch_walk(buf, pos - 8u, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: truncated by one trailer");
    check(rtlnet_tcp_offload_batch_walk(buf, pos - 16u, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: truncated by two beats");
    check(rtlnet_tcp_offload_batch_walk(buf, 72u + 80u, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: cut inside the second frame");
    /* Stray bytes in front of the first frame. */
    for (i = pos; i > 0u; i--) {
        buf[i + 7u] = buf[i - 1u];
    }
    for (i = 0u; i < 8u; i++) {
        buf[i] = 0x55u;
    }
    check(rtlnet_tcp_offload_batch_walk(buf, pos + 8u, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: 8 stray bytes in front");
    for (i = 0u; i < pos; i++) {
        buf[i] = buf[i + 8u];
    }
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 4u, &n) == RTLNET_TXO_OK && n == 2u, "walk: restored batch walks again");
    /* Bad length in the last trailer: longer than the buffer, zero, and one trailer in the middle too long. */
    t = pos - 8u;
    buf[t + 0u] = 0xFFu;
    buf[t + 1u] = 0x0Bu;   /* 3071 */
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH && n == 0u, "walk: length beyond the buffer");
    buf[t + 0u] = 0u;
    buf[t + 1u] = 0u;
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: length 0");
    buf[t + 0u] = 200u;
    buf[t + 1u] = 0u;
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 4u, &n) == RTLNET_TXO_OK && n == 2u, "walk: valid again before the mid-batch cases");
    buf[64u + 0u] = 65u;                    /* first frame (trailer at 64) claims 65 bytes: span 80 > the 72 before it */
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: middle length too long");
    buf[64u + 0u] = 60u;
    buf[64u + 7u] = 0xA4u;
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: bad marker in the middle");
    buf[64u + 7u] = RTLNET_TXO_TRAILER_MARKER;
    buf[pos - 1u] = 0u;
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 4u, &n) == RTLNET_TXO_ERR_BATCH, "walk: bad marker at the end");
    buf[pos - 1u] = RTLNET_TXO_TRAILER_MARKER;
    check(rtlnet_tcp_offload_batch_walk(buf, pos, fr, 4u, &n) == RTLNET_TXO_OK && n == 2u, "walk: restored again");

    /* Random batches: the walk finds exactly what was built. */
    for (t = 0u; t < 300u; t++) {
        uint32_t cnt = 1u + (rnd() % 20u);
        uint32_t lens[20];
        uint32_t offs[20];
        uint32_t ok = 1u;

        pos = 0u;
        for (i = 0u; i < cnt; i++) {
            lens[i] = 1u + (rnd() % ((rnd() % 4u == 0u) ? 3072u : 200u));
            offs[i] = pos;
            if (pos + RTLNET_TXO_ROUNDUP8(lens[i]) + 8u > sizeof buf) {
                cnt = i;
                break;
            }
            pos = append_frame(buf, pos, lens[i], (uint8_t)i, (uint16_t)(rnd() & 0xFFu));
        }
        if (cnt == 0u) {
            continue;
        }
        if (rtlnet_tcp_offload_batch_walk(buf, pos, fr, RTLNET_TXO_BATCH_MAX_FRAMES, &n) != RTLNET_TXO_OK || n != cnt) {
            ok = 0u;
        }
        for (i = 0u; ok != 0u && i < cnt; i++) {
            if (fr[i].offset != offs[i] || fr[i].trailer.frame_len != lens[i]) {
                ok = 0u;
            }
        }
        check(ok != 0u, "walk: random batch recovered exactly");
    }

    /* Random buffers: the walker never reports a frame outside the buffer and never returns frames out of order. */
    for (t = 0u; t < 4000u; t++) {
        uint32_t len = 8u * (rnd() % 40u) + ((rnd() % 5u == 0u) ? (rnd() % 8u) : 0u);
        uint32_t ok = 1u;
        int rc;

        for (i = 0u; i < len; i++) {
            buf[i] = (uint8_t)rnd();
        }
        for (i = 8u; i <= len; i += 8u) {
            if ((rnd() % 3u) != 0u) {
                buf[i - 1u] = RTLNET_TXO_TRAILER_MARKER;
                buf[i - 8u] = (uint8_t)(rnd() % 40u);
                buf[i - 7u] = 0u;
            }
        }
        n = 77u;
        rc = rtlnet_tcp_offload_batch_walk(buf, len, fr, 8u, &n);
        if (rc != RTLNET_TXO_OK) {
            ok = (n == 0u) ? 1u : 0u;
        } else {
            uint32_t end = 0u;

            ok = (n >= 1u && n <= 8u) ? 1u : 0u;
            for (i = 0u; ok != 0u && i < n; i++) {
                if (fr[i].offset != end || fr[i].trailer.frame_len == 0u) {
                    ok = 0u;
                }
                end = fr[i].offset + RTLNET_TXO_ROUNDUP8(fr[i].trailer.frame_len) + 8u;
            }
            if (end != len) {
                ok = 0u;
            }
        }
        check(ok != 0u, "walk: random buffer, consistent result or error");
    }
}

int main(int argc, char **argv)
{
    rtlnet_tcp_offload_t ctx;
    rtlnet_txo_counters_t cnt;
    rtlnet_txo_trailer_t tr;
    uint8_t buf[2048];
    uint32_t v;
    uint32_t xfer;
    int inject = 0;
    int rc;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--inject-failure") == 0) {
            inject = 1;
        }
    }

    /* Present core, both paths. */
    model_reset(model_caps(1u, 1u, 4u));
    rc = rtlnet_tcp_offload_init(&ctx, TB_BASE);
    check(rc == RTLNET_TXO_OK, "init ok");
    check(ctx.tx_present == 1u && ctx.rx_present == 1u, "caps tx/rx present");
    check(ctx.ins_ip == 1u && ctx.ins_tcp == 1u && ctx.ins_udp == 1u && ctx.vlan == 1u, "caps insert types");
    check(ctx.tx_buf_kb == 4u && ctx.max_frame == 1518u, "caps sizes");
    check(ctx.tx_latency == 18u && ctx.rx_delay == 17u, "latency fields");

    /* Power-up is pass-through. */
    check(rtlnet_tcp_offload_get_ctrl(&ctx, &v) == RTLNET_TXO_OK && v == 0u, "CTRL powers up 0");

    /* CTRL: each legal value reads back as written. */
    for (v = 0u; v <= RTLNET_TXO_CTRL_MASK; v++) {
        check(rtlnet_tcp_offload_set_ctrl(&ctx, v) == RTLNET_TXO_OK, "set_ctrl legal value");
        uint32_t got = 0xFFu;
        check(rtlnet_tcp_offload_get_ctrl(&ctx, &got) == RTLNET_TXO_OK && got == v, "CTRL read back as written");
    }
    check(rtlnet_tcp_offload_set_ctrl(&ctx, 0x8u) == RTLNET_TXO_ERR_ARG, "undefined CTRL bit rejected");
    check(rtlnet_tcp_offload_set_ctrl(NULL, 0u) == RTLNET_TXO_ERR_ARG, "NULL ctx rejected");
    {
        rtlnet_tcp_offload_t blank;

        memset(&blank, 0, sizeof blank);
        check(rtlnet_tcp_offload_set_ctrl(&blank, 0u) == RTLNET_TXO_ERR_NOT_INIT, "uninitialised ctx rejected");
    }

    /* Read-back mismatch is an error. */
    g_ctrl_stuck_mask = RTLNET_TXO_CTRL_RX_CSUM;
    g_ctrl = 0u;
    check(rtlnet_tcp_offload_set_ctrl(&ctx, RTLNET_TXO_CTRL_RX_CSUM) == RTLNET_TXO_ERR_READBACK,
          "read-back mismatch detected");
    g_ctrl_stuck_mask = 0u;
    check(rtlnet_tcp_offload_set_ctrl(&ctx, 0u) == RTLNET_TXO_OK, "set_ctrl 0 ok");

    /* Counters and clear. */
    check(rtlnet_tcp_offload_counters(&ctx, &cnt) == RTLNET_TXO_OK, "counters read");
    check(cnt.tx_frames == 100u && cnt.tx_ip_patched == 101u && cnt.tx_l4_patched == 102u &&
          cnt.tx_skipped == 103u && cnt.tx_malformed == 104u && cnt.tx_dropped == 105u, "TX counters map");
    check(cnt.rx_frames == 200u && cnt.rx_verified == 201u && cnt.rx_ip_bad == 202u && cnt.rx_l4_bad == 203u &&
          cnt.rx_unverified == 204u, "RX counters map");
    check(rtlnet_tcp_offload_clear_counters(&ctx) == RTLNET_TXO_OK && g_clear_count == 1u, "clear pulse written");
    check(rtlnet_tcp_offload_counters(&ctx, &cnt) == RTLNET_TXO_OK && cnt.tx_frames == 0u && cnt.rx_unverified == 0u,
          "counters cleared");
    check(rtlnet_tcp_offload_counters(&ctx, NULL) == RTLNET_TXO_ERR_ARG, "NULL counters rejected");
    check(g_writes_undefined == 0u, "driver wrote only defined registers");

    /* Idle wait: bounded, succeeds after a few reads, times out when stuck. */
    g_status_reads = 0u;
    g_idle_after = 3u;
    check(rtlnet_tcp_offload_wait_tx_idle(&ctx, 10u) == RTLNET_TXO_OK, "wait_tx_idle ok");
    check(g_status_reads == 4u, "idle seen on the first read after the model's busy period");
    g_idle_after = 0xFFFFFFFFu;
    g_status_reads = 0u;
    check(rtlnet_tcp_offload_wait_tx_idle(&ctx, 7u) == RTLNET_TXO_ERR_TIMEOUT, "wait_tx_idle times out");
    check(g_status_reads == 7u, "idle poll count is bounded by max_polls");
    check(rtlnet_tcp_offload_get_status(&ctx, &v) == RTLNET_TXO_OK && (v & RTLNET_TXO_STATUS_TX_IDLE) == 0u,
          "status read");

    /* Core without the RX path: rx_csum rejected, TX bits accepted. */
    model_reset(model_caps(1u, 0u, 8u));
    check(rtlnet_tcp_offload_init(&ctx, TB_BASE) == RTLNET_TXO_OK, "init TX-only build");
    check(ctx.tx_present == 1u && ctx.rx_present == 0u && ctx.tx_buf_kb == 8u, "TX-only caps");
    check(rtlnet_tcp_offload_set_ctrl(&ctx, RTLNET_TXO_CTRL_RX_CSUM) == RTLNET_TXO_ERR_UNSUPPORTED,
          "rx_csum rejected without RX path");
    check(rtlnet_tcp_offload_set_ctrl(&ctx, RTLNET_TXO_CTRL_TX_IP_CSUM | RTLNET_TXO_CTRL_TX_L4_CSUM) == RTLNET_TXO_OK,
          "TX bits accepted");
    model_reset(model_caps(0u, 1u, 4u));
    check(rtlnet_tcp_offload_init(&ctx, TB_BASE) == RTLNET_TXO_OK, "init RX-only build");
    check(rtlnet_tcp_offload_set_ctrl(&ctx, RTLNET_TXO_CTRL_TX_L4_CSUM) == RTLNET_TXO_ERR_UNSUPPORTED,
          "tx bit rejected without TX path");
    check(rtlnet_tcp_offload_set_ctrl(&ctx, RTLNET_TXO_CTRL_RX_CSUM) == RTLNET_TXO_OK, "rx_csum accepted");

    /* Absent core reads 0 everywhere; a wrong version is refused too. */
    model_reset(model_caps(1u, 1u, 4u));
    g_id = 0u;
    check(rtlnet_tcp_offload_init(&ctx, TB_BASE) == RTLNET_TXO_ERR_ID && ctx.initialised == 0u, "absent core refused");
    g_id = RTLNET_TXO_ID_VALUE;
    g_version = 0x01012025u;
    check(rtlnet_tcp_offload_init(&ctx, TB_BASE) == RTLNET_TXO_ERR_ID, "wrong version refused");
    check(rtlnet_tcp_offload_init(NULL, TB_BASE) == RTLNET_TXO_ERR_ARG, "init NULL ctx");

    /* Trailer decode. */
    xfer = build_buf(buf, 1514u, 0xFFFFu, RTLNET_TXO_TRF_IS_IPV4 | RTLNET_TXO_TRF_IS_TCP | RTLNET_TXO_TRF_IP_OK |
                     RTLNET_TXO_TRF_L4_OK | RTLNET_TXO_TRF_VERIFIED, 34u);
    check(xfer == 1520u + 8u, "transfer length is roundup8 + 8");
    check(rtlnet_tcp_offload_trailer_parse(buf, xfer, &tr) == RTLNET_TXO_OK, "trailer parses");
    check(tr.frame_len == 1514u && tr.l4_sum == 0xFFFFu && tr.l4_offset == 34u, "trailer fields");
    check(rtlnet_tcp_offload_rx_verdict(&tr) == RTLNET_TXO_RX_PASS_VERIFIED, "verified and good passes");

    xfer = build_buf(buf, 60u, 0x1234u, RTLNET_TXO_TRF_IS_IPV4 | RTLNET_TXO_TRF_IS_UDP | RTLNET_TXO_TRF_IP_OK |
                     RTLNET_TXO_TRF_VERIFIED, 34u);
    check(rtlnet_tcp_offload_trailer_parse(buf, xfer, &tr) == RTLNET_TXO_OK && tr.frame_len == 60u, "60-byte trailer");
    check(rtlnet_tcp_offload_rx_verdict(&tr) == RTLNET_TXO_RX_DROP_BAD_L4, "verified and bad L4 drops");

    xfer = build_buf(buf, 42u, 0u, RTLNET_TXO_TRF_IS_IPV4 | RTLNET_TXO_TRF_IS_UDP | RTLNET_TXO_TRF_IP_OK, 34u);
    check(rtlnet_tcp_offload_trailer_parse(buf, xfer, &tr) == RTLNET_TXO_OK && tr.frame_len == 42u, "42-byte trailer");
    check(rtlnet_tcp_offload_rx_verdict(&tr) == RTLNET_TXO_RX_PASS_UNVERIFIED, "UDP checksum 0 passes unverified");

    xfer = build_buf(buf, 64u, 0u, RTLNET_TXO_TRF_IS_IPV4, 0u);
    check(rtlnet_tcp_offload_trailer_parse(buf, xfer, &tr) == RTLNET_TXO_OK, "64-byte trailer");
    check(rtlnet_tcp_offload_rx_verdict(&tr) == RTLNET_TXO_RX_DROP_BAD_IP, "IPv4 with bad header drops");

    xfer = build_buf(buf, 60u, 0u, 0u, 0u);
    check(rtlnet_tcp_offload_trailer_parse(buf, xfer, &tr) == RTLNET_TXO_OK, "non-IP trailer");
    check(rtlnet_tcp_offload_rx_verdict(&tr) == RTLNET_TXO_RX_PASS_UNVERIFIED, "non-IP passes unverified");

    xfer = build_buf(buf, 1u, 0u, 0u, 0u);
    check(xfer == 16u && rtlnet_tcp_offload_trailer_parse(buf, xfer, &tr) == RTLNET_TXO_OK && tr.frame_len == 1u,
          "1-byte frame trailer");

    /* Malformed buffers. */
    xfer = build_buf(buf, 100u, 0u, 0u, 0u);
    check(rtlnet_tcp_offload_trailer_parse(buf, xfer - 8u, &tr) == RTLNET_TXO_ERR_TRAILER, "no trailer (pass-through frame)");
    check(rtlnet_tcp_offload_trailer_parse(buf, xfer + 1u, &tr) == RTLNET_TXO_ERR_TRAILER, "length not a multiple of 8");
    check(rtlnet_tcp_offload_trailer_parse(buf, 8u, &tr) == RTLNET_TXO_ERR_TRAILER, "too short");
    buf[xfer - 1u] = 0xA4u;
    check(rtlnet_tcp_offload_trailer_parse(buf, xfer, &tr) == RTLNET_TXO_ERR_TRAILER, "wrong marker");
    buf[xfer - 1u] = RTLNET_TXO_TRAILER_MARKER;
    buf[xfer - 8u] = 50u;
    check(rtlnet_tcp_offload_trailer_parse(buf, xfer, &tr) == RTLNET_TXO_ERR_TRAILER, "length field inconsistent");
    check(rtlnet_tcp_offload_trailer_parse(NULL, xfer, &tr) == RTLNET_TXO_ERR_ARG, "NULL buffer");
    check(RTLNET_TXO_RX_BUFFER_BYTES(1522u) == 1528u + 8u, "buffer sizing rule roundup8(1522) + 8");

    test_features();
    test_walk();

    if (inject != 0) {
        check(0, "inject-failure negative control");
    }
    if (g_fails == 0 && g_checks > 0) {
        printf("TEST PASS: rtlnet_tcp_offload_host checks=%d\n", g_checks);
        return 0;
    }
    printf("TEST FAIL: rtlnet_tcp_offload_host fails=%d checks=%d first=%s\n", g_fails, g_checks, g_first);
    return 1;
}
