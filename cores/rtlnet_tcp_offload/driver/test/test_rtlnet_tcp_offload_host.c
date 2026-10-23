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
 *   - counters read-only; undefined offsets read 0 and ignore writes.
 * It also checks the trailer decoder and the receive verdict on hand-built
 * buffers, and the error paths (absent core, unsupported CTRL bits, read-back
 * mismatch, idle timeout).
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
    case RTLNET_TXO_REG_STATUS:
        g_status_reads++;
        return (g_idle_after != 0xFFFFFFFFu && g_status_reads > g_idle_after)
               ? (RTLNET_TXO_STATUS_TX_IDLE | RTLNET_TXO_STATUS_RX_IDLE) : RTLNET_TXO_STATUS_RX_IDLE;
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
    return 0u;
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TB_BASE);
    uint32_t i;

    if (off == RTLNET_TXO_REG_CTRL) {
        g_ctrl = (g_ctrl & g_ctrl_stuck_mask) | (value & RTLNET_TXO_CTRL_MASK & ~g_ctrl_stuck_mask);
    } else if (off == RTLNET_TXO_REG_CNT_CLEAR) {
        if ((value & 1u) != 0u) {
            g_clear_count++;
            for (i = 0u; i < RTLNET_TXO_NUM_TX_COUNTERS; i++) {
                g_cnt_tx[i] = 0u;
            }
            for (i = 0u; i < RTLNET_TXO_NUM_RX_COUNTERS; i++) {
                g_cnt_rx[i] = 0u;
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
