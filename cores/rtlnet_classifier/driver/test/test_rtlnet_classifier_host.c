/*
 * test_rtlnet_classifier_host.c -- host unit test of the rtlnet_classifier driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: runs rtlnet_classifier.c unmodified (built with RTLNET_HOST_TEST)
 * against a register model of the core, mirroring the RTL register file
 * (cores/rtlnet_classifier/hdl/rtlnet_classifier_regs.sv):
 *   - ID, VERSION, CAPS, LATENCY constants for a chosen build;
 *   - CTRL: MODE, CLEAR_TABLES (zeroes every mode, policer, entry and rule
 *     byte; STATUS.CLEARING for a few reads), CNT_CLEAR (zeroes counters);
 *   - TABLE_MODE / RULE_MODE with their implemented-bit masks;
 *   - policer CTRL / LIMIT / WINDOW (a write reloads BUDGET), counters RO;
 *   - entry, tuple and rule words stored only at defined offsets (undefined
 *     offsets read 0 and ignore writes).
 * The model also checks the update protocol on every access: no field-table
 * or tuple word is written while its table is enabled, and no rule byte is
 * written while its rule is enabled.
 *
 * Output: exactly one line, "TEST PASS: rtlnet_classifier_host checks=N" or
 * "TEST FAIL: rtlnet_classifier_host fails=F checks=N first=<msg>".
 * Argument --inject-failure forces a failure (negative control). Exit code 0
 * on PASS.
 */
#include "rtlnet_classifier.h"

#include <stdio.h>    /* printf, snprintf */
#include <string.h>   /* memset, strcmp */

/* -------------------------------------------------------------------------
 * Check bookkeeping
 * ------------------------------------------------------------------------- */
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

static void checkf(int cond, const char *fmt, unsigned a, unsigned b)
{
    char buf[200];

    snprintf(buf, sizeof buf, fmt, a, b);
    check(cond, buf);
}

/* -------------------------------------------------------------------------
 * Register model
 * ------------------------------------------------------------------------- */
#define TB_BASE          ((uintptr_t)0x44A08000u)
#define TB_WORDS         1024u
#define TB_CLEAR_READS   3u

static uint32_t g_reg[TB_WORDS];         /* stored words (entry memory, modes, policers) */
static uint32_t g_cnt[RTLNET_CLS_NUM_COUNTERS];
static uint32_t g_pol_cnt[RTLNET_CLS_MAX_POLICERS][3];
static uint32_t g_budget[RTLNET_CLS_MAX_POLICERS];
static uint32_t g_mode;
static uint32_t g_clear_reads;           /* STATUS reads left with CLEARING set */
static int      g_clear_stuck;           /* model a CLEARING that never ends */
static uint32_t g_clear_count;           /* CLEAR_TABLES pulses seen */
static uint32_t g_cnt_clear_count;
static uint32_t g_id = RTLNET_CLS_ID_VALUE;
static uint32_t g_status_reads;
static int      g_protocol_violations;
static int      g_live_tuple_ok;         /* a live tuple add may write while the tuple table is enabled */

/* Write log: every register write while enabled, in order. */
#define TB_LOG_MAX       256u
static int      g_log_on;
static uint32_t g_log_n;
static uint32_t g_log_off[TB_LOG_MAX];
static uint32_t g_log_val[TB_LOG_MAX];

static void log_start(void)
{
    g_log_n = 0u;
    g_log_on = 1;
}

static void log_stop(void)
{
    g_log_on = 0;
}

/* Build parameters of the modelled core. */
static uint32_t g_te = 16u;
static uint32_t g_tu = 16u;
static uint32_t g_nr = 2u;
static uint32_t g_np = 4u;
static uint32_t g_lanes = 2u;
static uint32_t g_mdb = 64u;
static uint32_t g_dist;                  /* 1 = RAM_STYLE "distributed" */

static uint32_t model_stride(void)
{
    uint32_t s = 0x100u;

    while (s < 4u * g_mdb) {
        s <<= 1;
    }
    return s;
}

static uint32_t model_caps(void)
{
    return g_te | (g_tu << 5) | (g_nr << 10) | (g_np << 13) | (g_lanes << 16) | ((g_mdb / 8u) << 21) | (g_dist << 27);
}

static void model_clear(void)
{
    uint32_t i;

    for (i = 0x020u / 4u; i < TB_WORDS; i++) {
        g_reg[i] = 0u;
    }
    for (i = 0u; i < RTLNET_CLS_MAX_POLICERS; i++) {
        g_budget[i] = 0u;
    }
    g_mode = 0u;
}

static void model_reset(void)
{
    memset(g_reg, 0, sizeof g_reg);
    memset(g_cnt, 0, sizeof g_cnt);
    memset(g_pol_cnt, 0, sizeof g_pol_cnt);
    memset(g_budget, 0, sizeof g_budget);
    g_mode = 0u;
    g_clear_reads = TB_CLEAR_READS;
    g_clear_stuck = 0;
    g_clear_count = 0u;
    g_cnt_clear_count = 0u;
    g_id = RTLNET_CLS_ID_VALUE;
    g_status_reads = 0u;
    g_protocol_violations = 0;
    g_live_tuple_ok = 0;
    g_log_on = 0;
    g_log_n = 0u;
}

/* Offset class of the entry memory: 1 field table t, 2 tuple, 3 rule; 0 none. */
static int entry_class(uint32_t off, uint32_t *t_or_r)
{
    uint32_t hi = off >> 8;

    if (hi >= 4u && hi <= 8u) {
        *t_or_r = hi - 4u;
        return (((off >> 4) & 0xFu) < g_te) ? 1 : 0;
    }
    if (hi == 9u || hi == 0xAu) {
        uint32_t e = (off - 0x900u) / 0x20u;
        uint32_t w = ((off - 0x900u) % 0x20u) / 4u;
        *t_or_r = 5u;
        return (e < g_tu && w < RTLNET_CLS_TUP_WORDS) ? 2 : 0;
    }
    if (hi >= 0xCu) {
        uint32_t r = (off - 0xC00u) / model_stride();
        uint32_t b = ((off - 0xC00u) % model_stride()) / 4u;
        *t_or_r = r;
        return (r < g_nr && b < g_mdb) ? 3 : 0;
    }
    return 0;
}

uint32_t rtlnet_host_reg_read32(uintptr_t addr)
{
    uint32_t off = (uint32_t)(addr - TB_BASE);
    uint32_t i;

    if (off == RTLNET_CLS_REG_ID) {
        return g_id;
    }
    if (off == RTLNET_CLS_REG_VERSION) {
        return RTLNET_CLS_VERSION_VALUE;
    }
    if (off == RTLNET_CLS_REG_CAPS) {
        return model_caps();
    }
    if (off == RTLNET_CLS_REG_LATENCY) {
        uint32_t v = (g_te > g_tu ? g_te : g_tu) / g_lanes + 15u;
        return (g_mdb / 8u + v) | (v << 8);
    }
    if (off == RTLNET_CLS_REG_CTRL) {
        return g_mode;
    }
    if (off == RTLNET_CLS_REG_STATUS) {
        uint32_t clearing = 0u;
        g_status_reads++;
        if (g_clear_stuck) {
            clearing = 1u;
        } else if (g_clear_reads > 0u) {
            g_clear_reads--;
            clearing = 1u;
        }
        return clearing | (g_mode << RTLNET_CLS_STATUS_MODE_SHIFT);
    }
    if (off >= 0x080u && off < 0x0C0u) {
        return g_cnt[(off - 0x080u) / 4u];
    }
    for (i = 0u; i < g_np; i++) {
        uint32_t b = RTLNET_CLS_REG_POLICER(i);
        if (off == b + RTLNET_CLS_POL_SEEN) {
            return g_pol_cnt[i][0];
        }
        if (off == b + RTLNET_CLS_POL_PASSED) {
            return g_pol_cnt[i][1];
        }
        if (off == b + RTLNET_CLS_POL_DROPPED) {
            return g_pol_cnt[i][2];
        }
        if (off == b + RTLNET_CLS_POL_BUDGET) {
            return g_budget[i];
        }
    }
    if (off < RTLNET_CLS_WINDOW_BYTES) {
        return g_reg[off / 4u];
    }
    return 0u;
}

void rtlnet_host_reg_write32(uintptr_t addr, uint32_t value)
{
    uint32_t off = (uint32_t)(addr - TB_BASE);
    uint32_t idx;
    uint32_t i;
    int cls;

    if (g_log_on && g_log_n < TB_LOG_MAX) {
        g_log_off[g_log_n] = off;
        g_log_val[g_log_n] = value;
        g_log_n++;
    }
    if (off == RTLNET_CLS_REG_CTRL) {
        if ((value & RTLNET_CLS_CTRL_CLEAR_TABLES) != 0u) {
            model_clear();
            g_clear_reads = TB_CLEAR_READS;
            g_clear_count++;
        } else {
            g_mode = value & RTLNET_CLS_CTRL_MODE_MASK;
        }
        if ((value & RTLNET_CLS_CTRL_CNT_CLEAR) != 0u) {
            memset(g_cnt, 0, sizeof g_cnt);
            memset(g_pol_cnt, 0, sizeof g_pol_cnt);
            g_cnt_clear_count++;
        }
        return;
    }
    for (i = 0u; i < (uint32_t)RTLNET_CLS_NUM_TABLES; i++) {
        if (off == RTLNET_CLS_REG_TABLE_MODE(i)) {
            g_reg[off / 4u] = value & 0x9Fu;
            return;
        }
    }
    for (i = 0u; i < g_nr; i++) {
        if (off == RTLNET_CLS_REG_RULE_MODE(i)) {
            g_reg[off / 4u] = value & 0x3Fu;
            return;
        }
    }
    for (i = 0u; i < g_np; i++) {
        uint32_t b = RTLNET_CLS_REG_POLICER(i);
        if (off == b + RTLNET_CLS_POL_CTRL) {
            g_reg[off / 4u] = value & 1u;
            g_budget[i] = g_reg[(b + RTLNET_CLS_POL_LIMIT) / 4u];
            return;
        }
        if (off == b + RTLNET_CLS_POL_LIMIT || off == b + RTLNET_CLS_POL_WINDOW) {
            g_reg[off / 4u] = value;
            g_budget[i] = g_reg[(b + RTLNET_CLS_POL_LIMIT) / 4u];
            return;
        }
    }
    cls = entry_class(off, &idx);
    if (cls == 1 || cls == 2) {
        if ((g_reg[RTLNET_CLS_REG_TABLE_MODE(idx) / 4u] & RTLNET_CLS_TM_ENABLE) != 0u &&
            !(cls == 2 && g_live_tuple_ok)) {
            g_protocol_violations++;
        }
        g_reg[off / 4u] = value;
    } else if (cls == 3) {
        if ((g_reg[RTLNET_CLS_REG_RULE_MODE(idx) / 4u] & RTLNET_CLS_RM_ENABLE) != 0u) {
            g_protocol_violations++;
        }
        g_reg[off / 4u] = value;
    }
}

static uint32_t mreg(uint32_t off)
{
    return g_reg[off / 4u];
}

/* -------------------------------------------------------------------------
 * Tests
 * ------------------------------------------------------------------------- */
static rtlnet_classifier_t g_ctx;

static void init_ok(void)
{
    model_reset();
    check(rtlnet_classifier_init(&g_ctx, TB_BASE) == RTLNET_CLS_OK, "init");
}

static void test_init(void)
{
    rtlnet_classifier_t c;
    uint32_t nr0;

    model_reset();
    check(rtlnet_classifier_init(NULL, TB_BASE) == RTLNET_CLS_ERR_ARG, "init NULL");
    g_id = 0x12345678u;
    check(rtlnet_classifier_init(&c, TB_BASE) == RTLNET_CLS_ERR_ID, "init wrong ID");
    check(rtlnet_classifier_set_mode(&c, RTLNET_CLS_MODE_PASS_ALL) == RTLNET_CLS_ERR_NOT_INIT,
          "failed init leaves the context unusable");
    model_reset();
    g_clear_stuck = 1;
    check(rtlnet_classifier_init(&c, TB_BASE) == RTLNET_CLS_ERR_TIMEOUT, "init CLEARING stuck");
    check(g_status_reads == RTLNET_CLS_CLEAR_POLL_MAX, "CLEARING poll bounded by RTLNET_CLS_CLEAR_POLL_MAX");
    init_ok();
    check(g_ctx.table_entries == g_te && g_ctx.tuple_entries == g_tu && g_ctx.num_rules == g_nr &&
          g_ctx.num_policers == g_np && g_ctx.table_lanes == g_lanes && g_ctx.match_depth_bytes == g_mdb,
          "CAPS decoded");
    check(g_ctx.rule_stride == 0x100u, "rule stride 0x100 at 64 bytes");
    check(g_ctx.ram_distributed == g_dist, "RAM style decoded from CAPS");
    check(g_ctx.verdict_latency == ((g_te > g_tu) ? g_te : g_tu) / g_lanes + 15u &&
          g_ctx.delay_beats == 8u + g_ctx.verdict_latency, "LATENCY decoded");
    nr0 = g_nr;
    g_mdb = 128u;
    g_nr = 2u;
    init_ok();
    check(g_ctx.rule_stride == 0x200u, "rule stride 0x200 at 128 bytes");
    g_mdb = 128u;
    g_nr = 4u;
    model_reset();
    check(rtlnet_classifier_init(&c, TB_BASE) == RTLNET_CLS_ERR_ID, "impossible CAPS rejected");
    g_mdb = 64u;
    g_nr = nr0;
    init_ok();
}

static void test_mode(void)
{
    rtlnet_cls_mode_t m;
    uint32_t st;
    int i;

    init_ok();
    for (i = 0; i < 4; i++) {
        check(rtlnet_classifier_set_mode(&g_ctx, (rtlnet_cls_mode_t)i) == RTLNET_CLS_OK, "set_mode");
        check(g_mode == (uint32_t)i, "MODE written");
        check(rtlnet_classifier_get_mode(&g_ctx, &m) == RTLNET_CLS_OK && (int)m == i, "get_mode");
    }
    check(rtlnet_classifier_set_mode(&g_ctx, (rtlnet_cls_mode_t)4) == RTLNET_CLS_ERR_ARG, "set_mode bad");
    check(rtlnet_classifier_get_mode(&g_ctx, NULL) == RTLNET_CLS_ERR_ARG, "get_mode NULL");
    check(rtlnet_classifier_get_status(&g_ctx, &st) == RTLNET_CLS_OK &&
          ((st & RTLNET_CLS_STATUS_MODE_MASK) >> RTLNET_CLS_STATUS_MODE_SHIFT) == 3u, "get_status MODE");
    check(rtlnet_classifier_set_mode(NULL, RTLNET_CLS_MODE_PASS_ALL) == RTLNET_CLS_ERR_ARG, "set_mode NULL ctx");
}

static void test_table_mode(void)
{
    rtlnet_cls_table_mode_t tm;
    int t;

    init_ok();
    for (t = 0; t < RTLNET_CLS_NUM_TABLES; t++) {
        check(rtlnet_classifier_table_mode(&g_ctx, (rtlnet_cls_table_t)t, 1, 1, RTLNET_CLS_CMP_MASK, 1, 1) ==
              RTLNET_CLS_OK, "table_mode");
        checkf(mreg(RTLNET_CLS_REG_TABLE_MODE(t)) == 0x9Bu, "TABLE_MODE[%u] = 0x9B (got 0x%x)", (unsigned)t,
               mreg(RTLNET_CLS_REG_TABLE_MODE(t)));
        check(rtlnet_classifier_get_table_mode(&g_ctx, (rtlnet_cls_table_t)t, &tm) == RTLNET_CLS_OK &&
              tm.enable && tm.exclude && tm.compare == RTLNET_CLS_CMP_MASK && tm.classify && tm.vlan_aware,
              "get_table_mode all bits");
        check(rtlnet_classifier_table_mode(&g_ctx, (rtlnet_cls_table_t)t, 1, 0, RTLNET_CLS_CMP_RANGE, 0, 0) ==
              RTLNET_CLS_OK && mreg(RTLNET_CLS_REG_TABLE_MODE(t)) == 0x05u, "table_mode range enable");
    }
    check(rtlnet_classifier_table_mode(&g_ctx, (rtlnet_cls_table_t)6, 1, 0, RTLNET_CLS_CMP_SINGLE, 0, 0) ==
          RTLNET_CLS_ERR_ARG, "table_mode bad table");
    check(rtlnet_classifier_table_mode(&g_ctx, RTLNET_CLS_TABLE_MAC, 1, 0, (rtlnet_cls_compare_t)3, 0, 0) ==
          RTLNET_CLS_ERR_ARG, "table_mode bad compare");
}

static void test_entries(void)
{
    rtlnet_cls_entry_t e;
    rtlnet_cls_entry_t g;
    uint32_t t;
    uint32_t i;

    init_ok();
    for (t = 0u; t < 5u; t++) {
        /* Enabled table: the update must disable it while writing. */
        (void)rtlnet_classifier_table_mode(&g_ctx, (rtlnet_cls_table_t)t, 1, 0, RTLNET_CLS_CMP_SINGLE, 0, 0);
        for (i = 0u; i < g_te; i++) {
            memset(&e, 0, sizeof e);
            e.valid = 1u;
            e.src_en = (uint8_t)(i & 1u);
            e.dst_en = (uint8_t)((i >> 1) & 1u);
            e.both = (uint8_t)((i >> 2) & 1u);
            e.proto_en = (uint8_t)((i >> 3) & 1u);
            e.proto = (uint8_t)(17u + i);
            e.police_en = 1u;
            e.policer = (uint8_t)(i & 3u);
            e.src_value = 0x0000A1B2C3D4E5F0ull + i + 0x1000000ull * t;
            e.dst_value = 0x0000102030405060ull + i;
            check(rtlnet_classifier_table_entry_set(&g_ctx, (rtlnet_cls_table_t)t, i, &e) == RTLNET_CLS_OK,
                  "entry_set");
            memset(&g, 0, sizeof g);
            check(rtlnet_classifier_table_entry_get(&g_ctx, (rtlnet_cls_table_t)t, i, &g) == RTLNET_CLS_OK,
                  "entry_get");
            check(memcmp(&e, &g, sizeof e) == 0, "entry round trip");
        }
        check(mreg(RTLNET_CLS_REG_TABLE_MODE(t)) == 0x01u, "table mode restored after update");
        check(mreg(RTLNET_CLS_REG_ENTRY(t, 3u) + RTLNET_CLS_ENT_CTRL) ==
              (RTLNET_CLS_ENT_VALID | RTLNET_CLS_ENT_SRC_EN | RTLNET_CLS_ENT_DST_EN | RTLNET_CLS_ENT_POLICE_EN |
               (3u << RTLNET_CLS_ENT_POLICER_SHIFT) | (20u << RTLNET_CLS_ENT_PROTO_SHIFT) | 0xA1B2u),
              "entry control word packing");
    }
    check(rtlnet_classifier_table_entry_set(&g_ctx, RTLNET_CLS_TABLE_MAC, g_te, &e) == RTLNET_CLS_ERR_RANGE,
          "entry index range");
    check(rtlnet_classifier_table_entry_set(&g_ctx, RTLNET_CLS_TABLE_TUPLE, 0u, &e) == RTLNET_CLS_ERR_ARG,
          "entry_set on the tuple table");
    check(rtlnet_classifier_table_entry_get(&g_ctx, RTLNET_CLS_TABLE_MAC, 0u, NULL) == RTLNET_CLS_ERR_ARG,
          "entry_get NULL");
}

static void test_tuples(void)
{
    rtlnet_cls_tuple_t x;
    rtlnet_cls_tuple_t y;
    uint32_t i;

    init_ok();
    (void)rtlnet_classifier_table_mode(&g_ctx, RTLNET_CLS_TABLE_TUPLE, 1, 0, RTLNET_CLS_CMP_SINGLE, 0, 0);
    for (i = 0u; i < g_tu; i++) {
        memset(&x, 0, sizeof x);
        x.valid = 1u;
        x.proto_en = (uint8_t)(i & 1u);
        x.proto = 6u;
        x.police_en = (uint8_t)((i >> 1) & 1u);
        x.policer = (uint8_t)(i & 3u);
        x.src_ip = 0xC0A90100u + i;
        x.src_mask = 0xFFFFFF00u;
        x.dst_ip = 0xC0A901DCu;
        x.dst_mask = 0xFFFFFFFFu;
        x.sport_lo = (uint16_t)i;
        x.sport_hi = (uint16_t)(i + 100u);
        x.dport_lo = 22u;
        x.dport_hi = 22u;
        check(rtlnet_classifier_tuple_set(&g_ctx, i, &x) == RTLNET_CLS_OK, "tuple_set");
        memset(&y, 0, sizeof y);
        check(rtlnet_classifier_tuple_get(&g_ctx, i, &y) == RTLNET_CLS_OK && memcmp(&x, &y, sizeof x) == 0,
              "tuple round trip");
    }
    check(mreg(RTLNET_CLS_REG_TUPLE(1u) + RTLNET_CLS_TUP_SPORT) == ((101u << 16) | 1u), "tuple SPORT packing");
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(RTLNET_CLS_TABLE_TUPLE)) == 0x01u, "tuple mode restored");
    check(rtlnet_classifier_tuple_set(&g_ctx, g_tu, &x) == RTLNET_CLS_ERR_RANGE, "tuple index range");
}

static void test_rules(void)
{
    rtlnet_cls_rule_mode_t rm;
    uint8_t data[4] = {0x08u, 0x00u, 0x45u, 0x00u};
    uint8_t mask[4] = {0xFFu, 0xFFu, 0xF0u, 0x00u};
    uint32_t r;
    uint32_t b;
    uint32_t reads;

    init_ok();
    for (r = 0u; r < g_nr; r++) {
        check(rtlnet_classifier_rule_mode(&g_ctx, r, 1, 1, 1, 1, 2u) == RTLNET_CLS_OK, "rule_mode");
        check(mreg(RTLNET_CLS_REG_RULE_MODE(r)) == 0x2Fu, "RULE_MODE packing");
        check(rtlnet_classifier_get_rule_mode(&g_ctx, r, &rm) == RTLNET_CLS_OK && rm.enable && rm.exclude &&
              rm.classify && rm.police_en && rm.policer == 2u, "get_rule_mode");
        reads = g_status_reads;
        check(rtlnet_classifier_rule_byte(&g_ctx, r, 63u, 0xF0u, RTLNET_CLS_OP_GE, 0x5Au) == RTLNET_CLS_OK,
              "rule_byte");
        check(mreg(RTLNET_CLS_REG_RULE_BASE + 0x100u * r + 4u * 63u) == 0xF0000D5Au, "rule byte word");
        check(g_status_reads - reads >= RTLNET_CLS_SETTLE_READS, "rule settle reads before re-enable");
        check(mreg(RTLNET_CLS_REG_RULE_MODE(r)) == 0x2Fu, "rule mode restored");
        check(rtlnet_classifier_rule_pattern(&g_ctx, r, 12u, 4u, data, mask) == RTLNET_CLS_OK, "rule_pattern");
        for (b = 0u; b < g_mdb; b++) {
            uint32_t exp = 0u;
            if (b >= 12u && b < 16u) {
                exp = ((uint32_t)mask[b - 12u] << 24) | (0x8u << 8) | data[b - 12u];
            }
            checkf(mreg(RTLNET_CLS_REG_RULE_BASE + 0x100u * r + 4u * b) == exp, "rule pattern byte %u rule %u",
                   b, r);
        }
    }
    check(rtlnet_classifier_rule_mode(&g_ctx, g_nr, 1, 0, 0, 0, 0u) == RTLNET_CLS_ERR_RANGE, "rule range");
    check(rtlnet_classifier_rule_byte(&g_ctx, 0u, g_mdb, 0u, RTLNET_CLS_OP_EQ, 0u) == RTLNET_CLS_ERR_RANGE,
          "rule byte range");
    check(rtlnet_classifier_rule_pattern(&g_ctx, 0u, 60u, 8u, data, NULL) == RTLNET_CLS_ERR_RANGE,
          "rule pattern range");
    check(rtlnet_classifier_rule_pattern(&g_ctx, 0u, 0u, 4u, NULL, NULL) == RTLNET_CLS_ERR_ARG, "rule pattern NULL");
}

static void test_policers(void)
{
    rtlnet_cls_policer_t ps;
    uint32_t p;

    init_ok();
    for (p = 0u; p < g_np; p++) {
        check(rtlnet_classifier_policer_set(&g_ctx, p, 1, 10u + p, 100u + p) == RTLNET_CLS_OK, "policer_set");
        g_pol_cnt[p][0] = 7u + p;
        g_pol_cnt[p][1] = 5u;
        g_pol_cnt[p][2] = 2u + p;
        check(rtlnet_classifier_policer_get(&g_ctx, p, &ps) == RTLNET_CLS_OK, "policer_get");
        check(ps.enable == 1u && ps.limit_pkts == 10u + p && ps.window_ms == 100u + p && ps.seen == 7u + p &&
              ps.passed == 5u && ps.dropped == 2u + p && ps.budget == 10u + p, "policer fields");
    }
    check(rtlnet_classifier_policer_set(&g_ctx, g_np, 1, 1u, 1u) == RTLNET_CLS_ERR_RANGE, "policer range");
    check(rtlnet_classifier_policer_get(&g_ctx, 0u, NULL) == RTLNET_CLS_ERR_ARG, "policer_get NULL");
}

static void test_counters(void)
{
    rtlnet_cls_counters_t c;
    uint32_t i;

    init_ok();
    for (i = 0u; i < RTLNET_CLS_NUM_COUNTERS; i++) {
        g_cnt[i] = 1000u + i;
    }
    check(rtlnet_classifier_counters(&g_ctx, &c) == RTLNET_CLS_OK, "counters");
    check(c.frames == 1000u && c.passed == 1001u && c.dropped == 1002u && c.mode_dropped == 1003u &&
          c.police_dropped == 1004u && c.overrun_dropped == 1015u, "counter fields");
    for (i = 0u; i < 6u; i++) {
        check(c.table_hit[i] == 1005u + i, "table hit counters");
    }
    check(c.rule_hit[0] == 1011u && c.rule_hit[1] == ((g_nr > 1u) ? 1012u : 0u) && c.rule_hit[2] == 0u && c.rule_hit[3] == 0u,
          "rule hit counters of built rules only");
    (void)rtlnet_classifier_set_mode(&g_ctx, RTLNET_CLS_MODE_PASS_ON_MATCH);
    check(rtlnet_classifier_clear_counters(&g_ctx) == RTLNET_CLS_OK && g_cnt_clear_count == 1u && g_cnt[0] == 0u,
          "clear_counters");
    check(g_mode == (uint32_t)RTLNET_CLS_MODE_PASS_ON_MATCH, "clear_counters keeps MODE");
    check(rtlnet_classifier_counters(&g_ctx, NULL) == RTLNET_CLS_ERR_ARG, "counters NULL");
}

static void test_clear_all(void)
{
    init_ok();
    (void)rtlnet_classifier_set_mode(&g_ctx, RTLNET_CLS_MODE_PASS_ALL);
    (void)rtlnet_classifier_table_mode(&g_ctx, RTLNET_CLS_TABLE_IP, 1, 0, RTLNET_CLS_CMP_SINGLE, 0, 0);
    (void)rtlnet_classifier_policer_set(&g_ctx, 1u, 1, 5u, 5u);
    g_reg[(RTLNET_CLS_REG_ENTRY(3u, 0u) + RTLNET_CLS_ENT_CTRL) / 4u] = RTLNET_CLS_ENT_VALID;
    check(rtlnet_classifier_clear_all(&g_ctx) == RTLNET_CLS_OK && g_clear_count == 1u, "clear_all");
    check(g_mode == 0u && mreg(RTLNET_CLS_REG_TABLE_MODE(3u)) == 0u &&
          mreg(RTLNET_CLS_REG_POLICER(1u) + RTLNET_CLS_POL_CTRL) == 0u &&
          mreg(RTLNET_CLS_REG_ENTRY(3u, 0u) + RTLNET_CLS_ENT_CTRL) == 0u, "power-up state after clear_all");
    g_clear_stuck = 1;
    check(rtlnet_classifier_clear_all(&g_ctx) == RTLNET_CLS_ERR_TIMEOUT, "clear_all timeout");
    g_clear_stuck = 0;
}

static void test_helpers(void)
{
    static const uint8_t mac[6] = {0x02u, 0x49u, 0x4Bu, 0x52u, 0x4Eu, 0x01u};
    rtlnet_cls_entry_t e;
    rtlnet_cls_tuple_t x;

    init_ok();
    (void)rtlnet_classifier_table_mode(&g_ctx, RTLNET_CLS_TABLE_MAC, 0, 1, RTLNET_CLS_CMP_RANGE, 0, 1);
    check(rtlnet_classifier_mac_filter(&g_ctx, 2u, mac, RTLNET_CLS_SIDE_BOTH, RTLNET_CLS_ACT_GATE) == RTLNET_CLS_OK,
          "mac_filter");
    (void)rtlnet_classifier_table_entry_get(&g_ctx, RTLNET_CLS_TABLE_MAC, 2u, &e);
    check(e.valid && e.src_en && e.dst_en && e.both && !e.police_en && e.src_value == 0x02494B524E01ull &&
          e.dst_value == 0x02494B524E01ull, "mac_filter entry");
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(0u)) == (RTLNET_CLS_TM_ENABLE | RTLNET_CLS_TM_EXCLUDE | RTLNET_CLS_TM_VLAN_AWARE),
          "mac_filter table mode keeps EXCLUDE / VLAN_AWARE, sets single");
    check(rtlnet_classifier_mac_filter(&g_ctx, 0u, mac, (rtlnet_cls_side_t)7, 0u) == RTLNET_CLS_ERR_ARG, "mac side bad");

    check(rtlnet_classifier_ethertype_filter(&g_ctx, 1u, 0x0800u, 0x0806u, RTLNET_CLS_ACT_POLICE(3u)) == RTLNET_CLS_OK,
          "ethertype_filter");
    (void)rtlnet_classifier_table_entry_get(&g_ctx, RTLNET_CLS_TABLE_ETHERTYPE, 2u, &e);
    check(e.valid && e.src_en && e.src_value == 0x0800u && e.police_en && e.policer == 3u, "ethertype low entry");
    (void)rtlnet_classifier_table_entry_get(&g_ctx, RTLNET_CLS_TABLE_ETHERTYPE, 3u, &e);
    check(!e.valid && e.src_value == 0x0806u, "ethertype high entry");
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(1u)) == 0x05u, "ethertype table range");
    check(rtlnet_classifier_ethertype_filter(&g_ctx, g_te / 2u, 1u, 2u, 0u) == RTLNET_CLS_ERR_RANGE, "ethertype pair range");
    check(rtlnet_classifier_ethertype_filter(&g_ctx, 0u, 3u, 2u, 0u) == RTLNET_CLS_ERR_ARG, "ethertype lo > hi");

    check(rtlnet_classifier_ipv4_filter(&g_ctx, 0u, RTLNET_CLS_SIDE_DST, 0xC0A90100u, 0xFFFFFF00u,
                                        RTLNET_CLS_ACT_CLASSIFY) == RTLNET_CLS_OK, "ipv4_filter");
    (void)rtlnet_classifier_table_entry_get(&g_ctx, RTLNET_CLS_TABLE_IP, 0u, &e);
    check(e.valid && !e.src_en && e.dst_en && e.dst_value == 0xC0A90100u, "ipv4 value entry");
    (void)rtlnet_classifier_table_entry_get(&g_ctx, RTLNET_CLS_TABLE_IP, 1u, &e);
    check(e.dst_value == 0xFFFFFF00u, "ipv4 mask entry");
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(3u)) == (0x09u | RTLNET_CLS_TM_CLASSIFY), "ipv4 table mask, classify");

    check(rtlnet_classifier_port_filter(&g_ctx, 2u, 6u, RTLNET_CLS_SIDE_EITHER, 20u, 25u, RTLNET_CLS_ACT_GATE) ==
          RTLNET_CLS_OK, "port_filter");
    (void)rtlnet_classifier_table_entry_get(&g_ctx, RTLNET_CLS_TABLE_PORT, 4u, &e);
    check(e.valid && e.src_en && e.dst_en && !e.both && e.proto_en && e.proto == 6u && e.src_value == 20u,
          "port low entry");
    (void)rtlnet_classifier_table_entry_get(&g_ctx, RTLNET_CLS_TABLE_PORT, 5u, &e);
    check(e.dst_value == 25u, "port high entry");
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(4u)) == 0x05u, "port table range");

    check(rtlnet_classifier_acl_add(&g_ctx, 4u, 6u, 0xC0A90100u, 0xFFFFFF00u, 0xC0A901DCu, 0xFFFFFFFFu, 0u, 65535u,
                                    22u, 22u, RTLNET_CLS_ACT_POLICE(1u)) == RTLNET_CLS_OK, "acl_add");
    (void)rtlnet_classifier_tuple_get(&g_ctx, 4u, &x);
    check(x.valid && x.proto_en && x.proto == 6u && x.police_en && x.policer == 1u && x.src_ip == 0xC0A90100u &&
          x.dport_lo == 22u && x.dport_hi == 22u && x.sport_hi == 65535u, "acl entry");
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(5u)) == 0x01u, "tuple table enabled, gating");
    check(rtlnet_classifier_acl_add(&g_ctx, 0u, 0u, 0u, 0u, 0u, 0u, 5u, 4u, 0u, 0u, 0u) == RTLNET_CLS_ERR_ARG,
          "acl sport lo > hi");
}

static void test_bcast_storm(void)
{
    uint32_t i;
    uint32_t c;

    init_ok();
    /* Leftover configuration that config_bcast_storm must remove. */
    (void)rtlnet_classifier_table_mode(&g_ctx, RTLNET_CLS_TABLE_IP, 1, 0, RTLNET_CLS_CMP_SINGLE, 0, 0);
    (void)rtlnet_classifier_rule_mode(&g_ctx, 0u, 1, 0, 0, 0, 0u);
    (void)rtlnet_classifier_policer_set(&g_ctx, 2u, 1, 1u, 1u);
    check(rtlnet_classifier_config_bcast_storm(&g_ctx, 10u, 100u) == RTLNET_CLS_OK, "config_bcast_storm(10, 100)");
    check(g_clear_count == 1u, "bcast storm starts from CLEAR_TABLES");
    check(g_mode == (uint32_t)RTLNET_CLS_MODE_PASS_ALL, "bcast storm MODE = PASS_ALL");
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(0u)) == (RTLNET_CLS_TM_ENABLE | RTLNET_CLS_TM_CLASSIFY),
          "MAC table enabled, classify-only, single compare");
    for (i = 1u; i < 6u; i++) {
        check(mreg(RTLNET_CLS_REG_TABLE_MODE(i)) == 0u, "other tables disabled");
    }
    check(mreg(RTLNET_CLS_REG_RULE_MODE(0u)) == 0u, "rules disabled");
    c = mreg(RTLNET_CLS_REG_ENTRY(0u, 0u) + RTLNET_CLS_ENT_CTRL);
    check(c == (RTLNET_CLS_ENT_VALID | RTLNET_CLS_ENT_DST_EN | RTLNET_CLS_ENT_POLICE_EN | 0xFFFFu),
          "entry 0: valid, destination, police with policer 0");
    check(mreg(RTLNET_CLS_REG_ENTRY(0u, 0u) + RTLNET_CLS_ENT_DST_LO) == 0xFFFFFFFFu &&
          mreg(RTLNET_CLS_REG_ENTRY(0u, 0u) + RTLNET_CLS_ENT_DST_HI) == 0xFFFFu, "entry 0 destination FF:FF:FF:FF:FF:FF");
    check(mreg(RTLNET_CLS_REG_POLICER(0u) + RTLNET_CLS_POL_CTRL) == 1u &&
          mreg(RTLNET_CLS_REG_POLICER(0u) + RTLNET_CLS_POL_LIMIT) == 10u &&
          mreg(RTLNET_CLS_REG_POLICER(0u) + RTLNET_CLS_POL_WINDOW) == 100u, "policer 0 = 10 frames / 100 ms");
    check(mreg(RTLNET_CLS_REG_POLICER(2u) + RTLNET_CLS_POL_CTRL) == 0u, "other policers disabled");
    check(rtlnet_classifier_bcast_storm_enable(&g_ctx, 0) == RTLNET_CLS_OK &&
          mreg(RTLNET_CLS_REG_POLICER(0u) + RTLNET_CLS_POL_CTRL) == 0u, "bcast_storm_enable(0)");
    check(mreg(RTLNET_CLS_REG_POLICER(0u) + RTLNET_CLS_POL_LIMIT) == 10u, "disable keeps the limit");
    check(rtlnet_classifier_bcast_storm_enable(&g_ctx, 1) == RTLNET_CLS_OK &&
          mreg(RTLNET_CLS_REG_POLICER(0u) + RTLNET_CLS_POL_CTRL) == 1u, "bcast_storm_enable(1)");
    check(rtlnet_classifier_config_bcast_storm(NULL, 10u, 100u) == RTLNET_CLS_ERR_ARG, "bcast storm NULL");
}

static void test_build_and_bounds(void)
{
    rtlnet_cls_build_t b;
    rtlnet_cls_entry_t e = {0};
    rtlnet_cls_tuple_t x = {0};
    static const uint8_t mac[6] = {0x02u, 0x00u, 0x00u, 0x00u, 0x00u, 0x01u};

    init_ok();
    check(rtlnet_classifier_get_build(&g_ctx, &b) == RTLNET_CLS_OK, "get_build");
    check(b.table_entries == g_te && b.tuple_entries == g_tu && b.num_rules == g_nr && b.num_policers == g_np &&
          b.table_lanes == g_lanes && b.match_depth_bytes == g_mdb && b.ram_distributed == g_dist &&
          b.delay_beats == g_mdb / 8u + (((g_te > g_tu) ? g_te : g_tu) / g_lanes + 15u) &&
          b.verdict_latency == ((g_te > g_tu) ? g_te : g_tu) / g_lanes + 15u, "build sizes and RAM style");
    check(rtlnet_classifier_get_build(&g_ctx, NULL) == RTLNET_CLS_ERR_ARG, "get_build NULL");
    check(rtlnet_classifier_get_build(NULL, &b) == RTLNET_CLS_ERR_ARG, "get_build no context");

    /* One past the built sizes is an error in every add function, and nothing is written. */
    e.valid = 1u;
    check(rtlnet_classifier_table_entry_set(&g_ctx, RTLNET_CLS_TABLE_IP, g_te, &e) == RTLNET_CLS_ERR_RANGE,
          "entry index past the table");
    check(rtlnet_classifier_table_entry_get(&g_ctx, RTLNET_CLS_TABLE_IP, g_te, &e) == RTLNET_CLS_ERR_RANGE,
          "entry get past the table");
    check(rtlnet_classifier_table_entry_set(&g_ctx, RTLNET_CLS_TABLE_IP, 0u, &e) == RTLNET_CLS_OK,
          "last-index-safe entry set");
    check(rtlnet_classifier_table_entry_set(&g_ctx, RTLNET_CLS_TABLE_IP, g_te - 1u, &e) == RTLNET_CLS_OK,
          "last entry of the table");
    check(rtlnet_classifier_tuple_set(&g_ctx, g_tu, &x) == RTLNET_CLS_ERR_RANGE, "tuple index past the table");
    check(rtlnet_classifier_tuple_set(&g_ctx, g_tu - 1u, &x) == RTLNET_CLS_OK, "last tuple");
    check(rtlnet_classifier_rule_mode(&g_ctx, g_nr, 1, 0, 0, 0, 0u) == RTLNET_CLS_ERR_RANGE, "rule past the build");
    check(rtlnet_classifier_rule_byte(&g_ctx, g_nr, 0u, 0u, RTLNET_CLS_OP_EQ, 0u) == RTLNET_CLS_ERR_RANGE,
          "rule byte on a rule past the build");
    check(rtlnet_classifier_policer_set(&g_ctx, g_np, 1, 1u, 1u) == RTLNET_CLS_ERR_RANGE, "policer past the build");
    check(rtlnet_classifier_mac_filter(&g_ctx, g_te, mac, RTLNET_CLS_SIDE_DST, RTLNET_CLS_ACT_GATE) ==
          RTLNET_CLS_ERR_RANGE, "mac_filter past the table");
    check(rtlnet_classifier_acl_add(&g_ctx, g_tu, 6u, 0u, 0u, 0u, 0u, 0u, 65535u, 0u, 65535u, RTLNET_CLS_ACT_GATE) ==
          RTLNET_CLS_ERR_RANGE, "acl_add past the table");

    /* A policer the build does not have is an error, not a silently disabled policer. */
    if (g_np < RTLNET_CLS_MAX_POLICERS) {
        e.police_en = 1u;
        e.policer = (uint8_t)g_np;
        check(rtlnet_classifier_table_entry_set(&g_ctx, RTLNET_CLS_TABLE_IP, 0u, &e) == RTLNET_CLS_ERR_RANGE,
              "entry with a missing policer");
        check(rtlnet_classifier_mac_filter(&g_ctx, 0u, mac, RTLNET_CLS_SIDE_DST, RTLNET_CLS_ACT_POLICE(g_np)) ==
              RTLNET_CLS_ERR_RANGE, "helper with a missing policer");
        check(rtlnet_classifier_rule_mode(&g_ctx, 0u, 1, 0, 1, 1, g_np) == RTLNET_CLS_ERR_RANGE,
              "rule with a missing policer");
    }
}

/* Reads the policer limit/window/enable registers of policer p. */
static int policer_is(uint32_t p, uint32_t limit, uint32_t window)
{
    return mreg(RTLNET_CLS_REG_POLICER(p) + RTLNET_CLS_POL_CTRL) == 1u &&
           mreg(RTLNET_CLS_REG_POLICER(p) + RTLNET_CLS_POL_LIMIT) == limit &&
           mreg(RTLNET_CLS_REG_POLICER(p) + RTLNET_CLS_POL_WINDOW) == window;
}

static void test_protect(void)
{
    rtlnet_cls_protect_t pr;
    rtlnet_cls_policer_t ps;
    uint32_t base;
    uint32_t ctrl;

    init_ok();
    rtlnet_classifier_protect_defaults(&pr);
    check(pr.limit_pkts[0] == 10u && pr.limit_pkts[1] == 10u && pr.limit_pkts[2] == 20u && pr.limit_pkts[3] == 10u &&
          pr.window_ms[0] == 100u && pr.window_ms[3] == 100u, "protect defaults");
    /* Leftover configuration that the profile must remove. */
    (void)rtlnet_classifier_table_mode(&g_ctx, RTLNET_CLS_TABLE_IP, 1, 0, RTLNET_CLS_CMP_SINGLE, 0, 0);
    check(rtlnet_classifier_config_protect(&g_ctx, NULL) == RTLNET_CLS_OK, "config_protect(defaults)");
    check(g_clear_count == 1u && g_mode == (uint32_t)RTLNET_CLS_MODE_PASS_ALL, "profile starts from CLEAR, ends PASS_ALL");
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(3u)) == 0u && mreg(RTLNET_CLS_REG_TABLE_MODE(1u)) == 0u, "other tables off");
    /* Rule 0: EtherType 08 06 at bytes 12..13, classify-only, policer 2. */
    check(mreg(RTLNET_CLS_REG_RULE_MODE(0u)) == (RTLNET_CLS_RM_ENABLE | RTLNET_CLS_RM_CLASSIFY | RTLNET_CLS_RM_POLICE_EN |
                                                  (2u << RTLNET_CLS_RM_POLICER_SHIFT)), "ARP rule mode");
    check(mreg(RTLNET_CLS_REG_RULE_BASE + 4u * 12u) == 0xFF000808u && mreg(RTLNET_CLS_REG_RULE_BASE + 4u * 13u) == 0xFF000806u &&
          mreg(RTLNET_CLS_REG_RULE_BASE + 4u * 11u) == 0u && mreg(RTLNET_CLS_REG_RULE_BASE + 4u * 14u) == 0u,
          "ARP rule bytes 12..13, the rest don't-care");
    /* Tuple 0: protocol 1, any ports, policer 3, classify-only. */
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(5u)) == (RTLNET_CLS_TM_ENABLE | RTLNET_CLS_TM_CLASSIFY), "tuple table classify");
    base = RTLNET_CLS_REG_TUPLE(0u);
    ctrl = mreg(base);
    check(ctrl == (RTLNET_CLS_TUP_VALID | RTLNET_CLS_TUP_PROTO_EN | RTLNET_CLS_TUP_POLICE_EN | (3u << 8) | 1u), "ICMP tuple control");
    check(mreg(base + RTLNET_CLS_TUP_SPORT) == 0xFFFF0000u && mreg(base + RTLNET_CLS_TUP_DPORT) == 0xFFFF0000u &&
          mreg(base + RTLNET_CLS_TUP_SRC_MASK) == 0u && mreg(base + RTLNET_CLS_TUP_DST_MASK) == 0u, "ICMP tuple any address, any port");
    /* Tuple 1: protocol 17, any ports, policer 1. */
    check(mreg(RTLNET_CLS_REG_TUPLE(1u)) == (RTLNET_CLS_TUP_VALID | RTLNET_CLS_TUP_PROTO_EN | RTLNET_CLS_TUP_POLICE_EN |
                                              (1u << 8) | 17u), "UDP tuple control");
    /* MAC table, single compare: entry 0 destination broadcast (policer 0), classify-only. */
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(0u)) == (RTLNET_CLS_TM_ENABLE | RTLNET_CLS_TM_CLASSIFY), "MAC table classify");
    check(mreg(RTLNET_CLS_REG_ENTRY(0u, 0u) + RTLNET_CLS_ENT_CTRL) ==
          (RTLNET_CLS_ENT_VALID | RTLNET_CLS_ENT_DST_EN | RTLNET_CLS_ENT_POLICE_EN | 0xFFFFu), "broadcast entry control");
    check(mreg(RTLNET_CLS_REG_ENTRY(0u, 0u) + RTLNET_CLS_ENT_DST_LO) == 0xFFFFFFFFu &&
          mreg(RTLNET_CLS_REG_ENTRY(0u, 0u) + RTLNET_CLS_ENT_DST_HI) == 0xFFFFu, "broadcast destination");
    check(mreg(RTLNET_CLS_REG_ENTRY(0u, 1u) + RTLNET_CLS_ENT_CTRL) == 0u, "no other MAC entry in use");
    check(policer_is(0u, 10u, 100u) && policer_is(1u, 10u, 100u) && policer_is(2u, 20u, 100u) && policer_is(3u, 10u, 100u),
          "four policers at the default limits");

    /* Change one class; the others stay. */
    check(rtlnet_classifier_protect_limit(&g_ctx, RTLNET_CLS_PROT_ARP, 50u, 250u) == RTLNET_CLS_OK, "protect_limit");
    check(policer_is(2u, 50u, 250u) && policer_is(0u, 10u, 100u), "protect_limit changes one policer");
    g_pol_cnt[2][0] = 9u;
    g_pol_cnt[2][1] = 6u;
    g_pol_cnt[2][2] = 3u;
    check(rtlnet_classifier_protect_get(&g_ctx, RTLNET_CLS_PROT_ARP, &ps) == RTLNET_CLS_OK && ps.limit_pkts == 50u &&
          ps.window_ms == 250u && ps.seen == 9u && ps.passed == 6u && ps.dropped == 3u, "protect_get");
    check(rtlnet_classifier_protect_limit(&g_ctx, (rtlnet_cls_prot_class_t)4, 1u, 1u) == RTLNET_CLS_ERR_ARG, "class past the profile");
    check(rtlnet_classifier_protect_limit(&g_ctx, RTLNET_CLS_PROT_ICMP, 1u, 0u) == RTLNET_CLS_ERR_ARG, "window 0");
    check(rtlnet_classifier_protect_get(&g_ctx, (rtlnet_cls_prot_class_t)4, &ps) == RTLNET_CLS_ERR_ARG, "protect_get class");

    /* A custom profile and the argument checks (nothing written on error). */
    pr.limit_pkts[0] = 0u;
    pr.window_ms[1] = 0u;
    g_clear_count = 0u;
    check(rtlnet_classifier_config_protect(&g_ctx, &pr) == RTLNET_CLS_ERR_ARG && g_clear_count == 0u, "window 0 rejected, nothing written");
    pr.window_ms[1] = 7u;
    check(rtlnet_classifier_config_protect(&g_ctx, &pr) == RTLNET_CLS_OK && policer_is(0u, 0u, 100u) && policer_is(1u, 10u, 7u),
          "custom profile");
    check(rtlnet_classifier_config_protect(NULL, &pr) == RTLNET_CLS_ERR_ARG, "config_protect no context");

    /* protect_load: the config_protect image except MODE, and no write of pass-all. */
    {
        static uint32_t img[RTLNET_CLS_WINDOW_BYTES / 4u];
        uint32_t w;
        uint32_t bad = 0u;
        int pass_write = 0;

        check(rtlnet_classifier_config_protect(&g_ctx, NULL) == RTLNET_CLS_OK, "protect_load: reference image");
        for (w = 0x20u / 4u; w < RTLNET_CLS_WINDOW_BYTES / 4u; w++) {
            img[w] = mreg(4u * w);
        }
        log_start();
        check(rtlnet_classifier_protect_load(&g_ctx, NULL) == RTLNET_CLS_OK, "protect_load");
        log_stop();
        for (w = 0x20u / 4u; w < RTLNET_CLS_WINDOW_BYTES / 4u; w++) {
            bad += (mreg(4u * w) != img[w]) ? 1u : 0u;
        }
        check(bad == 0u, "protect_load: registers equal the config_protect image (MODE aside)");
        check(g_mode == (uint32_t)RTLNET_CLS_MODE_DROP_ALL, "protect_load: MODE stays drop-all");
        for (w = 0u; w < g_log_n; w++) {
            if (g_log_off[w] == RTLNET_CLS_REG_CTRL && (g_log_val[w] & RTLNET_CLS_CTRL_MODE_MASK) == (uint32_t)RTLNET_CLS_MODE_PASS_ALL) {
                pass_write = 1;
            }
        }
        check(!pass_write && g_log_n > 10u, "protect_load: no CTRL write of pass-all");
        check(rtlnet_classifier_protect_load(NULL, NULL) == RTLNET_CLS_ERR_ARG, "protect_load: no context");
    }

    /* A build too small for the profile is refused before anything is written. */
    {
        uint32_t tu = g_tu;
        uint32_t nr = g_nr;
        uint32_t np = g_np;

        g_tu = 1u;
        init_ok();
        g_clear_count = 0u;
        check(rtlnet_classifier_config_protect(&g_ctx, NULL) == RTLNET_CLS_ERR_RANGE && g_clear_count == 0u, "1 tuple: too small");
        g_tu = tu;
        g_np = 3u;
        init_ok();
        check(rtlnet_classifier_config_protect(&g_ctx, NULL) == RTLNET_CLS_ERR_RANGE, "3 policers: too small");
        g_np = np;
        g_tu = tu;
        g_nr = nr;
        init_ok();
    }
}

/* Index of the first / last logged write to `off` (-1 when none). */
static int log_find(uint32_t off, int last)
{
    int found = -1;
    uint32_t i;

    for (i = 0u; i < g_log_n; i++) {
        if (g_log_off[i] == off) {
            found = (int)i;
            if (!last) {
                break;
            }
        }
    }
    return found;
}

static rtlnet_cls_tuple_t fw_allow(uint32_t i)
{
    rtlnet_cls_tuple_t t;

    memset(&t, 0, sizeof t);
    t.valid = 1u;
    t.proto_en = 1u;
    t.proto = (i & 1u) ? 17u : 6u;
    t.src_ip = 0xC0A90100u + i;
    t.src_mask = 0xFFFFFF00u;
    t.dst_ip = 0xC0A901DCu;
    t.dst_mask = 0xFFFFFFFFu;
    t.sport_lo = 0u;
    t.sport_hi = 0xFFFFu;
    t.dport_lo = (uint16_t)(1000u + i);
    t.dport_hi = (uint16_t)(1000u + i);
    return t;
}

static void test_firewall(void)
{
    rtlnet_cls_tuple_t allow[RTLNET_CLS_MAX_TUPLES];
    rtlnet_cls_tuple_t got;
    rtlnet_cls_firewall_t fw;
    rtlnet_classifier_t un;
    uint32_t mac0[4];
    uint32_t rm0;
    uint32_t counts[3];
    uint32_t k;
    uint32_t i;
    uint32_t n;
    uint32_t w;
    uint32_t e0 = RTLNET_CLS_REG_ENTRY((uint32_t)RTLNET_CLS_TABLE_ETHERTYPE, 2u);
    int first_ctrl;
    int last_ctrl;

    counts[0] = 0u;
    counts[1] = 3u;
    counts[2] = g_tu;
    for (i = 0u; i < RTLNET_CLS_MAX_TUPLES; i++) {
        allow[i] = fw_allow(i);
    }
    for (k = 0u; k < 3u; k++) {
        n = counts[k];
        init_ok();
        check(rtlnet_classifier_config_protect(&g_ctx, NULL) == RTLNET_CLS_OK, "fw: profile first");
        for (w = 0u; w < 4u; w++) {
            mac0[w] = mreg(RTLNET_CLS_REG_ENTRY((uint32_t)RTLNET_CLS_TABLE_MAC, 0u) + 4u * w);
        }
        rm0 = mreg(RTLNET_CLS_REG_RULE_MODE(0u));
        fw.allow = allow;
        fw.count = n;
        fw.etype_pair = 1u;
        log_start();
        check(rtlnet_classifier_firewall_apply(&g_ctx, &fw) == RTLNET_CLS_OK, "fw: apply");
        log_stop();
        checkf(g_mode == (uint32_t)RTLNET_CLS_MODE_DROP_ON_MATCH, "fw: MODE drop-on-match (count %u, tuples %u)", n, g_tu);
        checkf(mreg(RTLNET_CLS_REG_TABLE_MODE(1u)) ==
                   (RTLNET_CLS_TM_ENABLE | RTLNET_CLS_TM_EXCLUDE | (1u << RTLNET_CLS_TM_COMPARE_SHIFT)),
               "fw: EtherType table enable|exclude|range classify 0 (count %u, tuples %u)", n, g_tu);
        checkf(mreg(RTLNET_CLS_REG_TABLE_MODE(5u)) == (RTLNET_CLS_TM_ENABLE | RTLNET_CLS_TM_EXCLUDE),
               "fw: tuple table enable|exclude classify 0 (count %u, tuples %u)", n, g_tu);
        checkf(mreg(e0 + RTLNET_CLS_ENT_SRC_LO) == 0x0806u &&
                   mreg(e0 + RTLNET_CLS_ENT_CTRL) == (RTLNET_CLS_ENT_VALID | RTLNET_CLS_ENT_SRC_EN),
               "fw: ARP pair low word and control (%u, %u)", n, g_tu);
        checkf(mreg(e0 + 0x10u + RTLNET_CLS_ENT_SRC_LO) == 0x0806u && mreg(e0 + 0x10u + RTLNET_CLS_ENT_CTRL) == 0u,
               "fw: ARP pair high word (%u, %u)", n, g_tu);
        for (i = 0u; i < g_tu; i++) {
            memset(&got, 0, sizeof got);
            check(rtlnet_classifier_tuple_get(&g_ctx, i, &got) == RTLNET_CLS_OK, "fw: tuple_get");
            if (i < n) {
                checkf(memcmp(&got, &allow[i], sizeof got) == 0, "fw: allow slot %u encoded (count %u)", i, n);
            } else {
                checkf(got.valid == 0u && mreg(RTLNET_CLS_REG_TUPLE(i) + RTLNET_CLS_TUP_CTRL) == 0u,
                       "fw: slot %u invalid (count %u)", i, n);
            }
        }
        for (w = 0u; w < 4u; w++) {
            checkf(mreg(RTLNET_CLS_REG_ENTRY((uint32_t)RTLNET_CLS_TABLE_MAC, 0u) + 4u * w) == mac0[w],
                   "fw: MAC table word %u unchanged (count %u)", w, n);
        }
        checkf(mreg(RTLNET_CLS_REG_RULE_MODE(0u)) == rm0, "fw: rule 0 mode unchanged (%u, %u)", n, g_tu);
        /* Write order. */
        first_ctrl = log_find(RTLNET_CLS_REG_CTRL, 0);
        last_ctrl = log_find(RTLNET_CLS_REG_CTRL, 1);
        check(g_log_n > 2u && first_ctrl == 0 && g_log_val[0] == (uint32_t)RTLNET_CLS_MODE_DROP_ALL,
              "fw: MODE = DROP_ALL is the first write");
        check(last_ctrl >= 0 && (uint32_t)last_ctrl == g_log_n - 1u &&
                  g_log_val[last_ctrl] == (uint32_t)RTLNET_CLS_MODE_DROP_ON_MATCH,
              "fw: MODE = DROP_ON_MATCH is the last write");
        check(first_ctrl != last_ctrl, "fw: two distinct CTRL writes");
    }
    check(g_protocol_violations == 0, "fw: no protocol violation");

    /* Rejections: right error and zero register writes. */
    init_ok();
    fw.allow = allow;
    fw.count = 2u;
    fw.etype_pair = 0u;
    log_start();
    fw.count = g_tu + 1u;
    check(rtlnet_classifier_firewall_apply(&g_ctx, &fw) == RTLNET_CLS_ERR_RANGE && g_log_n == 0u, "fw: count > tuples");
    fw.count = 2u;
    fw.etype_pair = g_te / 2u;
    check(rtlnet_classifier_firewall_apply(&g_ctx, &fw) == RTLNET_CLS_ERR_RANGE && g_log_n == 0u, "fw: etype_pair range");
    fw.etype_pair = 0u;
    allow[1].valid = 0u;
    check(rtlnet_classifier_firewall_apply(&g_ctx, &fw) == RTLNET_CLS_ERR_ARG && g_log_n == 0u, "fw: allow entry valid 0");
    allow[1].valid = 1u;
    allow[1].police_en = 1u;
    allow[1].policer = 7u;
    check(rtlnet_classifier_firewall_apply(&g_ctx, &fw) == RTLNET_CLS_ERR_RANGE && g_log_n == 0u, "fw: allow policer range");
    allow[1].police_en = 0u;
    allow[1].policer = 0u;
    fw.allow = NULL;
    check(rtlnet_classifier_firewall_apply(&g_ctx, &fw) == RTLNET_CLS_ERR_ARG && g_log_n == 0u, "fw: allow NULL with count");
    check(rtlnet_classifier_firewall_apply(&g_ctx, NULL) == RTLNET_CLS_ERR_ARG && g_log_n == 0u, "fw: NULL firewall");
    check(rtlnet_classifier_firewall_apply(NULL, &fw) == RTLNET_CLS_ERR_ARG && g_log_n == 0u, "fw: NULL context");
    memset(&un, 0, sizeof un);
    check(rtlnet_classifier_firewall_apply(&un, &fw) == RTLNET_CLS_ERR_NOT_INIT && g_log_n == 0u, "fw: uninitialised context");
    fw.count = 0u;
    check(rtlnet_classifier_firewall_apply(&g_ctx, &fw) == RTLNET_CLS_OK && g_log_n > 0u, "fw: allow NULL with count 0 is fine");
    log_stop();
}

static void test_tuple_live(void)
{
    rtlnet_cls_tuple_t t = fw_allow(2u);
    rtlnet_cls_tuple_t got;
    rtlnet_cls_firewall_t fw;
    uint32_t base = RTLNET_CLS_REG_TUPLE(5u);
    uint32_t i;
    int tm_written = 0;

    init_ok();
    fw.allow = NULL;
    fw.count = 0u;
    fw.etype_pair = 0u;
    check(rtlnet_classifier_firewall_apply(&g_ctx, &fw) == RTLNET_CLS_OK, "live: firewall first");
    g_live_tuple_ok = 1;
    log_start();
    check(rtlnet_classifier_tuple_live_set(&g_ctx, 5u, &t) == RTLNET_CLS_OK, "live: set on a free slot");
    log_stop();
    check(g_log_n == 7u, "live: exactly 7 writes");
    check(g_log_n == 7u && g_log_off[6] == base + RTLNET_CLS_TUP_CTRL && (g_log_val[6] & RTLNET_CLS_TUP_VALID) != 0u,
          "live: control word with VALID is last");
    for (i = 0u; i < g_log_n; i++) {
        if (g_log_off[i] == RTLNET_CLS_REG_TABLE_MODE(RTLNET_CLS_TABLE_TUPLE)) {
            tm_written = 1;
        }
    }
    check(!tm_written, "live: TABLE_MODE[TUPLE] never written");
    check(mreg(RTLNET_CLS_REG_TABLE_MODE(5u)) == (RTLNET_CLS_TM_ENABLE | RTLNET_CLS_TM_EXCLUDE),
          "live: tuple table still enabled");
    memset(&got, 0, sizeof got);
    check(rtlnet_classifier_tuple_get(&g_ctx, 5u, &got) == RTLNET_CLS_OK && memcmp(&got, &t, sizeof got) == 0,
          "live: entry encoded");

    log_start();
    check(rtlnet_classifier_tuple_live_set(&g_ctx, 5u, &t) == RTLNET_CLS_ERR_IN_USE && g_log_n == 0u,
          "live: valid slot is IN_USE, no write");
    check(rtlnet_classifier_tuple_live_set(&g_ctx, g_tu, &t) == RTLNET_CLS_ERR_RANGE && g_log_n == 0u,
          "live: index range");
    t.valid = 0u;
    check(rtlnet_classifier_tuple_live_set(&g_ctx, 6u, &t) == RTLNET_CLS_ERR_ARG && g_log_n == 0u,
          "live: valid 0 rejected");
    t.valid = 1u;
    check(rtlnet_classifier_tuple_live_set(&g_ctx, 6u, NULL) == RTLNET_CLS_ERR_ARG && g_log_n == 0u,
          "live: NULL tuple");
    g_clear_reads = 2u;
    check(rtlnet_classifier_tuple_live_set(&g_ctx, 6u, &t) == RTLNET_CLS_ERR_IN_USE && g_log_n == 0u,
          "live: CLEARING is IN_USE, no write");
    g_clear_reads = 0u;
    check(rtlnet_classifier_tuple_live_set(&g_ctx, 6u, &t) == RTLNET_CLS_OK && g_log_n == 7u,
          "live: free slot after CLEARING ends");

    log_start();
    check(rtlnet_classifier_tuple_live_clear(&g_ctx, 5u) == RTLNET_CLS_OK, "live: clear");
    check(g_log_n == 1u && g_log_off[0] == base + RTLNET_CLS_TUP_CTRL && g_log_val[0] == 0u,
          "live: clear is one write of 0 to +0");
    check(mreg(RTLNET_CLS_REG_TUPLE(5u) + RTLNET_CLS_TUP_CTRL) == 0u, "live: slot free again");
    check(rtlnet_classifier_tuple_live_clear(&g_ctx, g_tu) == RTLNET_CLS_ERR_RANGE && g_log_n == 1u,
          "live: clear index range, no write");
    log_stop();
    g_live_tuple_ok = 0;
    check(rtlnet_classifier_tuple_live_set(NULL, 0u, &t) == RTLNET_CLS_ERR_ARG, "live: NULL context");
}

static void run_suite(void)
{
    test_init();
    test_mode();
    test_table_mode();
    test_entries();
    test_tuples();
    test_rules();
    test_policers();
    test_counters();
    test_clear_all();
    test_helpers();
    test_bcast_storm();
    test_build_and_bounds();
    test_protect();
    test_firewall();
    test_tuple_live();
}

/* Builds the suite runs against: the defaults, the defaults with distributed RAM, the small-FPGA profile. */
static void set_build(uint32_t te, uint32_t tu, uint32_t nr, uint32_t np, uint32_t dist)
{
    g_te = te;
    g_tu = tu;
    g_nr = nr;
    g_np = np;
    g_dist = dist;
}

int main(int argc, char **argv)
{
    int inject = (argc > 1 && strcmp(argv[1], "--inject-failure") == 0);

    set_build(16u, 16u, 2u, 4u, 0u);
    run_suite();
    set_build(16u, 16u, 2u, 4u, 1u);
    run_suite();
    set_build(8u, 8u, 1u, 4u, 1u);
    run_suite();
    check(g_protocol_violations == 0, "update protocol: no entry or rule word written while enabled");
    if (inject) {
        check(0, "INJECT_FAILURE negative control");
    }
    if (g_fails == 0 && g_checks > 0) {
        printf("TEST PASS: rtlnet_classifier_host checks=%d\n", g_checks);
        return 0;
    }
    printf("TEST FAIL: rtlnet_classifier_host fails=%d checks=%d first=%s\n", g_fails, g_checks, g_first);
    return 1;
}
