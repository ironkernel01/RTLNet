/*
 * rtlnet_classifier.c -- RTLNet frame classifier driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches rtlnet_classifier registers. Register
 * access goes through rtlnet_mmio.h; offsets and bits come from
 * rtlnet_classifier.h. Every loop that waits on the hardware is bounded by a
 * named constant. The context carries the build parameters read from CAPS,
 * so every index is checked against what the hardware has.
 */
#include "rtlnet_classifier.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

/* -------------------------------------------------------------------------
 * Internal helpers
 * ------------------------------------------------------------------------- */

/*
 * rd -- read one classifier register.
 * Returns: the register value.
 */
static uint32_t rd(const rtlnet_classifier_t *ctx, uint32_t off)
{
    return rtlnet_reg_read32(ctx->base, off);
}

/*
 * wr -- write one classifier register.
 */
static void wr(const rtlnet_classifier_t *ctx, uint32_t off, uint32_t value)
{
    rtlnet_reg_write32(ctx->base, off, value);
}

/*
 * ready -- check a context before use.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG for NULL, RTLNET_CLS_ERR_NOT_INIT.
 */
static int ready(const rtlnet_classifier_t *ctx)
{
    if (ctx == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    return (ctx->initialised != 0u) ? RTLNET_CLS_OK : RTLNET_CLS_ERR_NOT_INIT;
}

/*
 * wait_clear_done -- wait until STATUS.CLEARING is 0.
 * Returns: RTLNET_CLS_OK, or RTLNET_CLS_ERR_TIMEOUT after
 * RTLNET_CLS_CLEAR_POLL_MAX reads.
 */
static int wait_clear_done(const rtlnet_classifier_t *ctx)
{
    uint32_t i;

    for (i = 0u; i < RTLNET_CLS_CLEAR_POLL_MAX; i++) {
        if ((rd(ctx, RTLNET_CLS_REG_STATUS) & RTLNET_CLS_STATUS_CLEARING) == 0u) {
            return RTLNET_CLS_OK;
        }
    }
    return RTLNET_CLS_ERR_TIMEOUT;
}

/*
 * entry_ctrl_word -- pack the control word of a field-table entry.
 * Returns: the +4 word (control bits and SRC_VALUE[47:32]).
 */
static uint32_t entry_ctrl_word(const rtlnet_cls_entry_t *e)
{
    uint32_t w = (uint32_t)((e->src_value >> 32) & RTLNET_CLS_ENT_SRC_HI_MASK);

    w |= ((uint32_t)e->proto << RTLNET_CLS_ENT_PROTO_SHIFT) & RTLNET_CLS_ENT_PROTO_MASK;
    w |= ((uint32_t)e->policer << RTLNET_CLS_ENT_POLICER_SHIFT) & RTLNET_CLS_ENT_POLICER_MASK;
    w |= (e->police_en != 0u) ? RTLNET_CLS_ENT_POLICE_EN : 0u;
    w |= (e->proto_en != 0u) ? RTLNET_CLS_ENT_PROTO_EN : 0u;
    w |= (e->both != 0u) ? RTLNET_CLS_ENT_BOTH : 0u;
    w |= (e->dst_en != 0u) ? RTLNET_CLS_ENT_DST_EN : 0u;
    w |= (e->src_en != 0u) ? RTLNET_CLS_ENT_SRC_EN : 0u;
    w |= (e->valid != 0u) ? RTLNET_CLS_ENT_VALID : 0u;
    return w;
}

/*
 * write_entry_words -- write the four words of field-table entry (t, index),
 * values first and the control word (with VALID) last.
 */
static void write_entry_words(const rtlnet_classifier_t *ctx, uint32_t t, uint32_t index,
                              const rtlnet_cls_entry_t *e)
{
    uint32_t base = RTLNET_CLS_REG_ENTRY(t, index);

    wr(ctx, base + RTLNET_CLS_ENT_SRC_LO, (uint32_t)(e->src_value & 0xFFFFFFFFull));
    wr(ctx, base + RTLNET_CLS_ENT_DST_LO, (uint32_t)(e->dst_value & 0xFFFFFFFFull));
    wr(ctx, base + RTLNET_CLS_ENT_DST_HI, (uint32_t)((e->dst_value >> 32) & 0xFFFFull));
    wr(ctx, base + RTLNET_CLS_ENT_CTRL, entry_ctrl_word(e));
}

/*
 * table_disable -- clear ENABLE of a table for an update.
 * Returns: the TABLE_MODE value to restore afterwards.
 */
static uint32_t table_disable(const rtlnet_classifier_t *ctx, uint32_t t)
{
    uint32_t mode = rd(ctx, RTLNET_CLS_REG_TABLE_MODE(t));

    if ((mode & RTLNET_CLS_TM_ENABLE) != 0u) {
        wr(ctx, RTLNET_CLS_REG_TABLE_MODE(t), mode & ~RTLNET_CLS_TM_ENABLE);
    }
    return mode;
}

/*
 * rule_disable -- clear ENABLE of a rule for an update.
 * Returns: the RULE_MODE value to restore afterwards.
 */
static uint32_t rule_disable(const rtlnet_classifier_t *ctx, uint32_t r)
{
    uint32_t mode = rd(ctx, RTLNET_CLS_REG_RULE_MODE(r));

    if ((mode & RTLNET_CLS_RM_ENABLE) != 0u) {
        wr(ctx, RTLNET_CLS_REG_RULE_MODE(r), mode & ~RTLNET_CLS_RM_ENABLE);
    }
    return mode;
}

/*
 * rule_restore -- let the rule's don't-care suffix settle, then restore
 * RULE_MODE.
 */
static void rule_restore(const rtlnet_classifier_t *ctx, uint32_t r, uint32_t mode)
{
    uint32_t i;

    for (i = 0u; i < RTLNET_CLS_SETTLE_READS; i++) {
        (void)rd(ctx, RTLNET_CLS_REG_STATUS);
    }
    wr(ctx, RTLNET_CLS_REG_RULE_MODE(r), mode);
}

/*
 * rule_byte_off -- register offset of rule r, byte b.
 */
static uint32_t rule_byte_off(const rtlnet_classifier_t *ctx, uint32_t r, uint32_t b)
{
    return RTLNET_CLS_REG_RULE_BASE + ctx->rule_stride * r + 4u * b;
}

/*
 * rule_word -- pack one rule compare-buffer word.
 */
static uint32_t rule_word(uint8_t mask, rtlnet_cls_op_t op, uint8_t value)
{
    return ((uint32_t)mask << RTLNET_CLS_RB_MASK_SHIFT) |
           (((uint32_t)op << RTLNET_CLS_RB_OP_SHIFT) & RTLNET_CLS_RB_OP_MASK) |
           ((uint32_t)value & RTLNET_CLS_RB_COMPARE_MASK);
}

/*
 * side_flags -- set src_en / dst_en / both of an entry from a side selector.
 * Returns: RTLNET_CLS_OK or RTLNET_CLS_ERR_ARG.
 */
static int side_flags(rtlnet_cls_side_t which, rtlnet_cls_entry_t *e)
{
    switch (which) {
    case RTLNET_CLS_SIDE_SRC:    e->src_en = 1u; e->dst_en = 0u; e->both = 0u; break;
    case RTLNET_CLS_SIDE_DST:    e->src_en = 0u; e->dst_en = 1u; e->both = 0u; break;
    case RTLNET_CLS_SIDE_EITHER: e->src_en = 1u; e->dst_en = 1u; e->both = 0u; break;
    case RTLNET_CLS_SIDE_BOTH:   e->src_en = 1u; e->dst_en = 1u; e->both = 1u; break;
    default:                     return RTLNET_CLS_ERR_ARG;
    }
    return RTLNET_CLS_OK;
}

/*
 * apply_action -- set the policing fields of an entry from a helper action.
 */
static void apply_action(uint32_t action, rtlnet_cls_entry_t *e)
{
    e->police_en = ((action & RTLNET_CLS_ACT_POLICE_FLAG) != 0u) ? 1u : 0u;
    e->policer = (uint8_t)RTLNET_CLS_ACT_POLICER(action);
}

/*
 * action_ok -- check that the policer a helper action selects exists in the build (an index at or above
 * NUM_POLICERS would act as a disabled policer in hardware, silently).
 * Returns: 1 when the action is usable, 0 otherwise.
 */
static int action_ok(const rtlnet_classifier_t *ctx, uint32_t action)
{
    return ((action & RTLNET_CLS_ACT_POLICE_FLAG) == 0u) || (RTLNET_CLS_ACT_POLICER(action) < ctx->num_policers);
}

/*
 * helper_table_mode -- enable a table for a helper: keep EXCLUDE and
 * VLAN_AWARE, set COMPARE, set CLASSIFY from the action.
 * Returns: the new TABLE_MODE value.
 */
static uint32_t helper_table_mode(uint32_t old, rtlnet_cls_compare_t compare, uint32_t action)
{
    uint32_t m = old & (RTLNET_CLS_TM_EXCLUDE | RTLNET_CLS_TM_VLAN_AWARE);

    m |= RTLNET_CLS_TM_ENABLE;
    m |= ((uint32_t)compare << RTLNET_CLS_TM_COMPARE_SHIFT) & RTLNET_CLS_TM_COMPARE_MASK;
    m |= ((action & RTLNET_CLS_ACT_CLASSIFY) != 0u) ? RTLNET_CLS_TM_CLASSIFY : 0u;
    return m;
}

/*
 * pair_write -- write entry pair (2 index, 2 index + 1) of table t with the
 * table disabled, then set the table mode.
 * Steps:
 *   1. Disable the table.
 *   2. Write the odd entry (values only), then the even entry (control word last).
 *   3. Write the new TABLE_MODE (enables the table).
 */
static void pair_write(const rtlnet_classifier_t *ctx, uint32_t t, uint32_t index,
                       const rtlnet_cls_entry_t *even, const rtlnet_cls_entry_t *odd, uint32_t new_mode)
{
    (void)table_disable(ctx, t);
    write_entry_words(ctx, t, 2u * index + 1u, odd);
    write_entry_words(ctx, t, 2u * index, even);
    wr(ctx, RTLNET_CLS_REG_TABLE_MODE(t), new_mode);
}

/* -------------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------------- */

/*
 * rtlnet_classifier_init -- probe the core and fill the context.
 * Steps:
 *   1. Check ID and VERSION.
 *   2. Decode CAPS and LATENCY; check every field against the register map.
 *   3. Wait for the power-up clear sequence to end.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_ID (not a
 * classifier or impossible CAPS), RTLNET_CLS_ERR_TIMEOUT.
 */
int rtlnet_classifier_init(rtlnet_classifier_t *ctx, uintptr_t base)
{
    uint32_t caps;
    uint32_t lat;
    uint32_t stride;

    if (ctx == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    ctx->initialised = 0u;
    ctx->base = base;
    if (rd(ctx, RTLNET_CLS_REG_ID) != RTLNET_CLS_ID_VALUE ||
        rd(ctx, RTLNET_CLS_REG_VERSION) != RTLNET_CLS_VERSION_VALUE) {
        return RTLNET_CLS_ERR_ID;
    }
    caps = rd(ctx, RTLNET_CLS_REG_CAPS);
    lat = rd(ctx, RTLNET_CLS_REG_LATENCY);
    ctx->table_entries = RTLNET_CLS_CAPS_TABLE_ENTRIES(caps);
    ctx->tuple_entries = RTLNET_CLS_CAPS_TUPLE_ENTRIES(caps);
    ctx->num_rules = RTLNET_CLS_CAPS_NUM_RULES(caps);
    ctx->num_policers = RTLNET_CLS_CAPS_NUM_POLICERS(caps);
    ctx->table_lanes = RTLNET_CLS_CAPS_TABLE_LANES(caps);
    ctx->match_depth_bytes = 8u * RTLNET_CLS_CAPS_MATCH_BEATS(caps);
    ctx->ram_distributed = RTLNET_CLS_CAPS_RAM_DIST(caps);
    ctx->delay_beats = RTLNET_CLS_LAT_DELAY_BEATS(lat);
    ctx->verdict_latency = RTLNET_CLS_LAT_VERDICT(lat);
    stride = RTLNET_CLS_MIN_RULE_STRIDE;
    while (stride < 4u * ctx->match_depth_bytes && stride < RTLNET_CLS_RULE_WINDOW_BYTES) {
        stride <<= 1;
    }
    ctx->rule_stride = stride;
    if (ctx->table_entries == 0u || ctx->table_entries > RTLNET_CLS_MAX_ENTRIES ||
        ctx->tuple_entries == 0u || ctx->tuple_entries > RTLNET_CLS_MAX_TUPLES ||
        ctx->num_rules == 0u || ctx->num_rules > RTLNET_CLS_MAX_RULES ||
        ctx->num_policers == 0u || ctx->num_policers > RTLNET_CLS_MAX_POLICERS ||
        ctx->match_depth_bytes == 0u || ctx->num_rules * ctx->rule_stride > RTLNET_CLS_RULE_WINDOW_BYTES) {
        return RTLNET_CLS_ERR_ID;
    }
    if (wait_clear_done(ctx) != RTLNET_CLS_OK) {
        return RTLNET_CLS_ERR_TIMEOUT;
    }
    ctx->initialised = 1u;
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_set_mode -- write CTRL.MODE.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_set_mode(const rtlnet_classifier_t *ctx, rtlnet_cls_mode_t mode)
{
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if ((uint32_t)mode > (uint32_t)RTLNET_CLS_MODE_DROP_ON_MATCH) {
        return RTLNET_CLS_ERR_ARG;
    }
    wr(ctx, RTLNET_CLS_REG_CTRL, (uint32_t)mode & RTLNET_CLS_CTRL_MODE_MASK);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_get_mode -- read CTRL.MODE.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_get_mode(const rtlnet_classifier_t *ctx, rtlnet_cls_mode_t *mode)
{
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (mode == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    *mode = (rtlnet_cls_mode_t)(rd(ctx, RTLNET_CLS_REG_CTRL) & RTLNET_CLS_CTRL_MODE_MASK);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_get_status -- read STATUS.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_get_status(const rtlnet_classifier_t *ctx, uint32_t *status)
{
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (status == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    *status = rd(ctx, RTLNET_CLS_REG_STATUS);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_clear_all -- return to the power-up state.
 * Steps:
 *   1. Pulse CTRL.CLEAR_TABLES (MODE = DROP_ALL, every table, rule and
 *      policer disabled, every entry and rule byte zeroed).
 *   2. Wait for STATUS.CLEARING to end.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT,
 * RTLNET_CLS_ERR_TIMEOUT.
 */
int rtlnet_classifier_clear_all(const rtlnet_classifier_t *ctx)
{
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    wr(ctx, RTLNET_CLS_REG_CTRL, RTLNET_CLS_CTRL_CLEAR_TABLES);
    return wait_clear_done(ctx);
}

/*
 * rtlnet_classifier_table_mode -- write TABLE_MODE of table 0..5.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_table_mode(const rtlnet_classifier_t *ctx, rtlnet_cls_table_t table, int enable,
                                 int exclude, rtlnet_cls_compare_t compare, int classify, int vlan_aware)
{
    uint32_t m;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if ((uint32_t)table >= (uint32_t)RTLNET_CLS_NUM_TABLES || (uint32_t)compare > (uint32_t)RTLNET_CLS_CMP_MASK) {
        return RTLNET_CLS_ERR_ARG;
    }
    m = (enable != 0) ? RTLNET_CLS_TM_ENABLE : 0u;
    m |= (exclude != 0) ? RTLNET_CLS_TM_EXCLUDE : 0u;
    m |= ((uint32_t)compare << RTLNET_CLS_TM_COMPARE_SHIFT) & RTLNET_CLS_TM_COMPARE_MASK;
    m |= (classify != 0) ? RTLNET_CLS_TM_CLASSIFY : 0u;
    m |= (vlan_aware != 0) ? RTLNET_CLS_TM_VLAN_AWARE : 0u;
    wr(ctx, RTLNET_CLS_REG_TABLE_MODE(table), m);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_get_table_mode -- read and decode TABLE_MODE.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_get_table_mode(const rtlnet_classifier_t *ctx, rtlnet_cls_table_t table,
                                     rtlnet_cls_table_mode_t *mode)
{
    uint32_t m;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if ((uint32_t)table >= (uint32_t)RTLNET_CLS_NUM_TABLES || mode == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    m = rd(ctx, RTLNET_CLS_REG_TABLE_MODE(table));
    mode->enable = (uint8_t)((m & RTLNET_CLS_TM_ENABLE) != 0u);
    mode->exclude = (uint8_t)((m & RTLNET_CLS_TM_EXCLUDE) != 0u);
    mode->compare = (uint8_t)((m & RTLNET_CLS_TM_COMPARE_MASK) >> RTLNET_CLS_TM_COMPARE_SHIFT);
    mode->classify = (uint8_t)((m & RTLNET_CLS_TM_CLASSIFY) != 0u);
    mode->vlan_aware = (uint8_t)((m & RTLNET_CLS_TM_VLAN_AWARE) != 0u);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_table_entry_set -- write one field-table entry with the
 * update protocol.
 * Steps:
 *   1. Check the table (0..4) and the index against CAPS.
 *   2. Disable the table, write the value words and the control word.
 *   3. Restore TABLE_MODE.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_table_entry_set(const rtlnet_classifier_t *ctx, rtlnet_cls_table_t table,
                                      uint32_t index, const rtlnet_cls_entry_t *entry)
{
    uint32_t mode;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if ((uint32_t)table >= (uint32_t)RTLNET_CLS_TABLE_TUPLE || entry == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (index >= ctx->table_entries ||
        (entry->police_en != 0u && (uint32_t)entry->policer >= ctx->num_policers)) {
        return RTLNET_CLS_ERR_RANGE;
    }
    mode = table_disable(ctx, (uint32_t)table);
    write_entry_words(ctx, (uint32_t)table, index, entry);
    if ((mode & RTLNET_CLS_TM_ENABLE) != 0u) {
        wr(ctx, RTLNET_CLS_REG_TABLE_MODE(table), mode);
    }
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_table_entry_get -- read one field-table entry back.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_table_entry_get(const rtlnet_classifier_t *ctx, rtlnet_cls_table_t table,
                                      uint32_t index, rtlnet_cls_entry_t *entry)
{
    uint32_t base;
    uint32_t c;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if ((uint32_t)table >= (uint32_t)RTLNET_CLS_TABLE_TUPLE || entry == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (index >= ctx->table_entries) {
        return RTLNET_CLS_ERR_RANGE;
    }
    base = RTLNET_CLS_REG_ENTRY(table, index);
    c = rd(ctx, base + RTLNET_CLS_ENT_CTRL);
    entry->src_value = ((uint64_t)(c & RTLNET_CLS_ENT_SRC_HI_MASK) << 32) |
                       (uint64_t)rd(ctx, base + RTLNET_CLS_ENT_SRC_LO);
    entry->dst_value = ((uint64_t)(rd(ctx, base + RTLNET_CLS_ENT_DST_HI) & 0xFFFFu) << 32) |
                       (uint64_t)rd(ctx, base + RTLNET_CLS_ENT_DST_LO);
    entry->proto = (uint8_t)((c & RTLNET_CLS_ENT_PROTO_MASK) >> RTLNET_CLS_ENT_PROTO_SHIFT);
    entry->policer = (uint8_t)((c & RTLNET_CLS_ENT_POLICER_MASK) >> RTLNET_CLS_ENT_POLICER_SHIFT);
    entry->police_en = (uint8_t)((c & RTLNET_CLS_ENT_POLICE_EN) != 0u);
    entry->proto_en = (uint8_t)((c & RTLNET_CLS_ENT_PROTO_EN) != 0u);
    entry->both = (uint8_t)((c & RTLNET_CLS_ENT_BOTH) != 0u);
    entry->dst_en = (uint8_t)((c & RTLNET_CLS_ENT_DST_EN) != 0u);
    entry->src_en = (uint8_t)((c & RTLNET_CLS_ENT_SRC_EN) != 0u);
    entry->valid = (uint8_t)((c & RTLNET_CLS_ENT_VALID) != 0u);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_tuple_set -- write one tuple (ACL) entry with the update
 * protocol (tuple table disabled while its words change).
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_tuple_set(const rtlnet_classifier_t *ctx, uint32_t index,
                                const rtlnet_cls_tuple_t *tuple)
{
    uint32_t base;
    uint32_t c;
    uint32_t mode;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (tuple == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (index >= ctx->tuple_entries) {
        return RTLNET_CLS_ERR_RANGE;
    }
    if (tuple->police_en != 0u && (uint32_t)tuple->policer >= ctx->num_policers) {
        return RTLNET_CLS_ERR_RANGE;
    }
    base = RTLNET_CLS_REG_TUPLE(index);
    c = (uint32_t)tuple->proto & RTLNET_CLS_TUP_PROTO_MASK;
    c |= ((uint32_t)tuple->policer << RTLNET_CLS_TUP_POLICER_SHIFT) & RTLNET_CLS_TUP_POLICER_MASK;
    c |= (tuple->police_en != 0u) ? RTLNET_CLS_TUP_POLICE_EN : 0u;
    c |= (tuple->proto_en != 0u) ? RTLNET_CLS_TUP_PROTO_EN : 0u;
    c |= (tuple->valid != 0u) ? RTLNET_CLS_TUP_VALID : 0u;
    mode = table_disable(ctx, (uint32_t)RTLNET_CLS_TABLE_TUPLE);
    wr(ctx, base + RTLNET_CLS_TUP_SRC_IP, tuple->src_ip);
    wr(ctx, base + RTLNET_CLS_TUP_SRC_MASK, tuple->src_mask);
    wr(ctx, base + RTLNET_CLS_TUP_DST_IP, tuple->dst_ip);
    wr(ctx, base + RTLNET_CLS_TUP_DST_MASK, tuple->dst_mask);
    wr(ctx, base + RTLNET_CLS_TUP_SPORT, ((uint32_t)tuple->sport_hi << 16) | (uint32_t)tuple->sport_lo);
    wr(ctx, base + RTLNET_CLS_TUP_DPORT, ((uint32_t)tuple->dport_hi << 16) | (uint32_t)tuple->dport_lo);
    wr(ctx, base + RTLNET_CLS_TUP_CTRL, c);
    if ((mode & RTLNET_CLS_TM_ENABLE) != 0u) {
        wr(ctx, RTLNET_CLS_REG_TABLE_MODE(RTLNET_CLS_TABLE_TUPLE), mode);
    }
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_tuple_get -- read one tuple entry back.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_tuple_get(const rtlnet_classifier_t *ctx, uint32_t index, rtlnet_cls_tuple_t *tuple)
{
    uint32_t base;
    uint32_t c;
    uint32_t sp;
    uint32_t dp;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (tuple == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (index >= ctx->tuple_entries) {
        return RTLNET_CLS_ERR_RANGE;
    }
    base = RTLNET_CLS_REG_TUPLE(index);
    c = rd(ctx, base + RTLNET_CLS_TUP_CTRL);
    sp = rd(ctx, base + RTLNET_CLS_TUP_SPORT);
    dp = rd(ctx, base + RTLNET_CLS_TUP_DPORT);
    tuple->proto = (uint8_t)(c & RTLNET_CLS_TUP_PROTO_MASK);
    tuple->policer = (uint8_t)((c & RTLNET_CLS_TUP_POLICER_MASK) >> RTLNET_CLS_TUP_POLICER_SHIFT);
    tuple->police_en = (uint8_t)((c & RTLNET_CLS_TUP_POLICE_EN) != 0u);
    tuple->proto_en = (uint8_t)((c & RTLNET_CLS_TUP_PROTO_EN) != 0u);
    tuple->valid = (uint8_t)((c & RTLNET_CLS_TUP_VALID) != 0u);
    tuple->src_ip = rd(ctx, base + RTLNET_CLS_TUP_SRC_IP);
    tuple->src_mask = rd(ctx, base + RTLNET_CLS_TUP_SRC_MASK);
    tuple->dst_ip = rd(ctx, base + RTLNET_CLS_TUP_DST_IP);
    tuple->dst_mask = rd(ctx, base + RTLNET_CLS_TUP_DST_MASK);
    tuple->sport_lo = (uint16_t)(sp & 0xFFFFu);
    tuple->sport_hi = (uint16_t)(sp >> 16);
    tuple->dport_lo = (uint16_t)(dp & 0xFFFFu);
    tuple->dport_hi = (uint16_t)(dp >> 16);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_rule_mode -- write RULE_MODE of one rule.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_RANGE, RTLNET_CLS_ERR_ARG,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_rule_mode(const rtlnet_classifier_t *ctx, uint32_t rule, int enable, int exclude,
                                int classify, int police_en, uint32_t policer)
{
    uint32_t m;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (rule >= ctx->num_rules) {
        return RTLNET_CLS_ERR_RANGE;
    }
    if (policer >= RTLNET_CLS_MAX_POLICERS) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (police_en != 0 && policer >= ctx->num_policers) {
        return RTLNET_CLS_ERR_RANGE;
    }
    m = (enable != 0) ? RTLNET_CLS_RM_ENABLE : 0u;
    m |= (exclude != 0) ? RTLNET_CLS_RM_EXCLUDE : 0u;
    m |= (classify != 0) ? RTLNET_CLS_RM_CLASSIFY : 0u;
    m |= (police_en != 0) ? RTLNET_CLS_RM_POLICE_EN : 0u;
    m |= (policer << RTLNET_CLS_RM_POLICER_SHIFT) & RTLNET_CLS_RM_POLICER_MASK;
    wr(ctx, RTLNET_CLS_REG_RULE_MODE(rule), m);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_get_rule_mode -- read and decode RULE_MODE.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_RANGE, RTLNET_CLS_ERR_ARG,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_get_rule_mode(const rtlnet_classifier_t *ctx, uint32_t rule,
                                    rtlnet_cls_rule_mode_t *mode)
{
    uint32_t m;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (mode == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (rule >= ctx->num_rules) {
        return RTLNET_CLS_ERR_RANGE;
    }
    m = rd(ctx, RTLNET_CLS_REG_RULE_MODE(rule));
    mode->enable = (uint8_t)((m & RTLNET_CLS_RM_ENABLE) != 0u);
    mode->exclude = (uint8_t)((m & RTLNET_CLS_RM_EXCLUDE) != 0u);
    mode->classify = (uint8_t)((m & RTLNET_CLS_RM_CLASSIFY) != 0u);
    mode->police_en = (uint8_t)((m & RTLNET_CLS_RM_POLICE_EN) != 0u);
    mode->policer = (uint8_t)((m & RTLNET_CLS_RM_POLICER_MASK) >> RTLNET_CLS_RM_POLICER_SHIFT);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_rule_byte -- program one byte of a rule with the update
 * protocol: (frame[byte] & mask) op (value & mask).
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_RANGE, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_rule_byte(const rtlnet_classifier_t *ctx, uint32_t rule, uint32_t byte, uint8_t mask,
                                rtlnet_cls_op_t op, uint8_t value)
{
    uint32_t mode;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (rule >= ctx->num_rules || byte >= ctx->match_depth_bytes) {
        return RTLNET_CLS_ERR_RANGE;
    }
    mode = rule_disable(ctx, rule);
    wr(ctx, rule_byte_off(ctx, rule, byte), rule_word(mask, op, value));
    rule_restore(ctx, rule, mode);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_rule_pattern -- program a whole rule as one data/mask
 * pattern: bytes offset..offset+len-1 compare equal under mask (data[i],
 * mask[i]; mask NULL = 0xFF), every other byte don't-care.
 * Steps:
 *   1. Check the range against MATCH_DEPTH_BYTES; disable the rule.
 *   2. Write every byte of the compare buffer.
 *   3. Let the rule settle and restore RULE_MODE.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_rule_pattern(const rtlnet_classifier_t *ctx, uint32_t rule, uint32_t offset,
                                   uint32_t len, const uint8_t *data, const uint8_t *mask)
{
    uint32_t mode;
    uint32_t b;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (data == NULL && len != 0u) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (rule >= ctx->num_rules || offset > ctx->match_depth_bytes || len > ctx->match_depth_bytes - offset) {
        return RTLNET_CLS_ERR_RANGE;
    }
    mode = rule_disable(ctx, rule);
    for (b = 0u; b < ctx->match_depth_bytes; b++) {
        uint32_t w = rule_word(0u, RTLNET_CLS_OP_DONT_CARE, 0u);
        if (b >= offset && b < offset + len) {
            uint8_t m = (mask != NULL) ? mask[b - offset] : 0xFFu;
            w = rule_word(m, RTLNET_CLS_OP_EQ, data[b - offset]);
        }
        wr(ctx, rule_byte_off(ctx, rule, b), w);
    }
    rule_restore(ctx, rule, mode);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_policer_set -- configure one policer (the write restarts
 * its window and reloads its budget).
 * Steps:
 *   1. Write LIMIT_PKTS and WINDOW_MS.
 *   2. Write CTRL.ENABLE.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_RANGE, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_policer_set(const rtlnet_classifier_t *ctx, uint32_t policer, int enable,
                                  uint32_t limit_pkts, uint32_t window_ms)
{
    uint32_t base;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (policer >= ctx->num_policers) {
        return RTLNET_CLS_ERR_RANGE;
    }
    base = RTLNET_CLS_REG_POLICER(policer);
    wr(ctx, base + RTLNET_CLS_POL_LIMIT, limit_pkts);
    wr(ctx, base + RTLNET_CLS_POL_WINDOW, window_ms);
    wr(ctx, base + RTLNET_CLS_POL_CTRL, (enable != 0) ? RTLNET_CLS_POL_CTRL_ENABLE : 0u);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_policer_get -- read one policer's configuration,
 * counters and current budget.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_policer_get(const rtlnet_classifier_t *ctx, uint32_t policer,
                                  rtlnet_cls_policer_t *state)
{
    uint32_t base;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (state == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (policer >= ctx->num_policers) {
        return RTLNET_CLS_ERR_RANGE;
    }
    base = RTLNET_CLS_REG_POLICER(policer);
    state->enable = (uint8_t)((rd(ctx, base + RTLNET_CLS_POL_CTRL) & RTLNET_CLS_POL_CTRL_ENABLE) != 0u);
    state->limit_pkts = rd(ctx, base + RTLNET_CLS_POL_LIMIT);
    state->window_ms = rd(ctx, base + RTLNET_CLS_POL_WINDOW);
    state->seen = rd(ctx, base + RTLNET_CLS_POL_SEEN);
    state->passed = rd(ctx, base + RTLNET_CLS_POL_PASSED);
    state->dropped = rd(ctx, base + RTLNET_CLS_POL_DROPPED);
    state->budget = rd(ctx, base + RTLNET_CLS_POL_BUDGET);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_counters -- read every global counter.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_counters(const rtlnet_classifier_t *ctx, rtlnet_cls_counters_t *counters)
{
    uint32_t i;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (counters == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    counters->frames = rd(ctx, RTLNET_CLS_REG_COUNTER(RTLNET_CLS_CNT_FRAMES));
    counters->passed = rd(ctx, RTLNET_CLS_REG_COUNTER(RTLNET_CLS_CNT_PASSED));
    counters->dropped = rd(ctx, RTLNET_CLS_REG_COUNTER(RTLNET_CLS_CNT_DROPPED));
    counters->mode_dropped = rd(ctx, RTLNET_CLS_REG_COUNTER(RTLNET_CLS_CNT_MODE_DROPPED));
    counters->police_dropped = rd(ctx, RTLNET_CLS_REG_COUNTER(RTLNET_CLS_CNT_POLICE_DROPPED));
    counters->overrun_dropped = rd(ctx, RTLNET_CLS_REG_COUNTER(RTLNET_CLS_CNT_OVERRUN_DROPPED));
    for (i = 0u; i < (uint32_t)RTLNET_CLS_NUM_TABLES; i++) {
        counters->table_hit[i] = rd(ctx, RTLNET_CLS_REG_COUNTER(RTLNET_CLS_CNT_TABLE_HIT + i));
    }
    for (i = 0u; i < RTLNET_CLS_MAX_RULES; i++) {
        counters->rule_hit[i] = (i < ctx->num_rules) ? rd(ctx, RTLNET_CLS_REG_COUNTER(RTLNET_CLS_CNT_RULE_HIT + i))
                                                      : 0u;
    }
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_clear_counters -- pulse CTRL.CNT_CLEAR (global and
 * policer counters, STATUS.STALL_SEEN), keeping MODE.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_clear_counters(const rtlnet_classifier_t *ctx)
{
    uint32_t mode;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    mode = rd(ctx, RTLNET_CLS_REG_CTRL) & RTLNET_CLS_CTRL_MODE_MASK;
    wr(ctx, RTLNET_CLS_REG_CTRL, mode | RTLNET_CLS_CTRL_CNT_CLEAR);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_mac_filter -- MAC table entry `index` (single-value
 * compare) for one MAC address on the chosen side(s); enables the MAC table
 * with CLASSIFY from the action.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_mac_filter(const rtlnet_classifier_t *ctx, uint32_t index,
                                 const uint8_t mac[RTLNET_CLS_MAC_BYTES], rtlnet_cls_side_t which,
                                 uint32_t action)
{
    rtlnet_cls_entry_t e = {0};
    uint64_t v = 0u;
    uint32_t i;
    uint32_t old;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (mac == NULL || side_flags(which, &e) != RTLNET_CLS_OK) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (index >= ctx->table_entries) {
        return RTLNET_CLS_ERR_RANGE;
    }
    if (!action_ok(ctx, action)) {
        return RTLNET_CLS_ERR_RANGE;
    }
    for (i = 0u; i < RTLNET_CLS_MAC_BYTES; i++) {
        v = (v << 8) | (uint64_t)mac[i];
    }
    e.valid = 1u;
    e.src_value = v;
    e.dst_value = v;
    apply_action(action, &e);
    old = table_disable(ctx, (uint32_t)RTLNET_CLS_TABLE_MAC);
    write_entry_words(ctx, (uint32_t)RTLNET_CLS_TABLE_MAC, index, &e);
    wr(ctx, RTLNET_CLS_REG_TABLE_MODE(RTLNET_CLS_TABLE_MAC), helper_table_mode(old, RTLNET_CLS_CMP_SINGLE, action));
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_ethertype_filter -- EtherType range lo..hi in entry pair
 * `index` (entries 2 index, 2 index + 1); sets the ETHERTYPE table to range
 * compare.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_ethertype_filter(const rtlnet_classifier_t *ctx, uint32_t index, uint16_t lo,
                                       uint16_t hi, uint32_t action)
{
    rtlnet_cls_entry_t even = {0};
    rtlnet_cls_entry_t odd = {0};
    uint32_t old;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (lo > hi) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (2u * index + 1u >= ctx->table_entries) {
        return RTLNET_CLS_ERR_RANGE;
    }
    if (!action_ok(ctx, action)) {
        return RTLNET_CLS_ERR_RANGE;
    }
    even.valid = 1u;
    even.src_en = 1u;
    even.src_value = lo;
    apply_action(action, &even);
    odd.src_value = hi;
    old = rd(ctx, RTLNET_CLS_REG_TABLE_MODE(RTLNET_CLS_TABLE_ETHERTYPE));
    pair_write(ctx, (uint32_t)RTLNET_CLS_TABLE_ETHERTYPE, index, &even, &odd,
               helper_table_mode(old, RTLNET_CLS_CMP_RANGE, action));
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_ipv4_filter -- IPv4 address/mask on the chosen side(s) in
 * IP-table entry pair `index`; sets the IP table to data/mask compare.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_ipv4_filter(const rtlnet_classifier_t *ctx, uint32_t index, rtlnet_cls_side_t which,
                                  uint32_t addr, uint32_t mask, uint32_t action)
{
    rtlnet_cls_entry_t even = {0};
    rtlnet_cls_entry_t odd = {0};
    uint32_t old;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (side_flags(which, &even) != RTLNET_CLS_OK) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (2u * index + 1u >= ctx->table_entries) {
        return RTLNET_CLS_ERR_RANGE;
    }
    if (!action_ok(ctx, action)) {
        return RTLNET_CLS_ERR_RANGE;
    }
    even.valid = 1u;
    even.src_value = addr;
    even.dst_value = addr;
    apply_action(action, &even);
    odd.src_value = mask;
    odd.dst_value = mask;
    old = rd(ctx, RTLNET_CLS_REG_TABLE_MODE(RTLNET_CLS_TABLE_IP));
    pair_write(ctx, (uint32_t)RTLNET_CLS_TABLE_IP, index, &even, &odd,
               helper_table_mode(old, RTLNET_CLS_CMP_MASK, action));
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_port_filter -- L4 port range lo..hi on the chosen
 * side(s) in PORT-table entry pair `index`; proto 0 = any protocol (6 or 17
 * otherwise). Sets the PORT table to range compare.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_port_filter(const rtlnet_classifier_t *ctx, uint32_t index, uint8_t proto,
                                  rtlnet_cls_side_t which, uint16_t lo, uint16_t hi, uint32_t action)
{
    rtlnet_cls_entry_t even = {0};
    rtlnet_cls_entry_t odd = {0};
    uint32_t old;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (lo > hi || side_flags(which, &even) != RTLNET_CLS_OK) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (2u * index + 1u >= ctx->table_entries) {
        return RTLNET_CLS_ERR_RANGE;
    }
    if (!action_ok(ctx, action)) {
        return RTLNET_CLS_ERR_RANGE;
    }
    even.valid = 1u;
    even.src_value = lo;
    even.dst_value = lo;
    even.proto_en = (proto != 0u) ? 1u : 0u;
    even.proto = proto;
    apply_action(action, &even);
    odd.src_value = hi;
    odd.dst_value = hi;
    old = rd(ctx, RTLNET_CLS_REG_TABLE_MODE(RTLNET_CLS_TABLE_PORT));
    pair_write(ctx, (uint32_t)RTLNET_CLS_TABLE_PORT, index, &even, &odd,
               helper_table_mode(old, RTLNET_CLS_CMP_RANGE, action));
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_acl_add -- one tuple entry (proto 0 = any protocol) and
 * enable the tuple table with CLASSIFY from the action.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_acl_add(const rtlnet_classifier_t *ctx, uint32_t index, uint8_t proto,
                              uint32_t src, uint32_t src_mask, uint32_t dst, uint32_t dst_mask,
                              uint16_t sport_lo, uint16_t sport_hi, uint16_t dport_lo, uint16_t dport_hi,
                              uint32_t action)
{
    rtlnet_cls_tuple_t t = {0};
    uint32_t old;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (sport_lo > sport_hi || dport_lo > dport_hi) {
        return RTLNET_CLS_ERR_ARG;
    }
    if (index >= ctx->tuple_entries) {
        return RTLNET_CLS_ERR_RANGE;
    }
    t.valid = 1u;
    t.proto_en = (proto != 0u) ? 1u : 0u;
    t.proto = proto;
    t.police_en = ((action & RTLNET_CLS_ACT_POLICE_FLAG) != 0u) ? 1u : 0u;
    t.policer = (uint8_t)RTLNET_CLS_ACT_POLICER(action);
    t.src_ip = src;
    t.src_mask = src_mask;
    t.dst_ip = dst;
    t.dst_mask = dst_mask;
    t.sport_lo = sport_lo;
    t.sport_hi = sport_hi;
    t.dport_lo = dport_lo;
    t.dport_hi = dport_hi;
    old = rd(ctx, RTLNET_CLS_REG_TABLE_MODE(RTLNET_CLS_TABLE_TUPLE));
    rc = rtlnet_classifier_tuple_set(ctx, index, &t);
    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    wr(ctx, RTLNET_CLS_REG_TABLE_MODE(RTLNET_CLS_TABLE_TUPLE),
       helper_table_mode(old, RTLNET_CLS_CMP_SINGLE, action));
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_config_bcast_storm -- the first default configuration:
 * broadcast storm limiter.
 * Steps:
 *   1. Clear everything (power-up state).
 *   2. MAC table entry 0: destination FF:FF:FF:FF:FF:FF, police with
 *      policer 0; MAC table enabled, classify-only, single compare.
 *   3. Policer 0: enabled, limit_pkts frames per window_ms.
 *   4. MODE = PASS_ALL (every other frame passes).
 * Returns: RTLNET_CLS_OK or the first failing step's code.
 */
int rtlnet_classifier_config_bcast_storm(const rtlnet_classifier_t *ctx, uint32_t limit_pkts,
                                         uint32_t window_ms)
{
    static const uint8_t bcast[RTLNET_CLS_MAC_BYTES] = {0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu};
    int rc = rtlnet_classifier_clear_all(ctx);

    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_mac_filter(ctx, 0u, bcast, RTLNET_CLS_SIDE_DST,
                                          RTLNET_CLS_ACT_CLASSIFY | RTLNET_CLS_ACT_POLICE(0u));
    }
    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_policer_set(ctx, 0u, 1, limit_pkts, window_ms);
    }
    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_set_mode(ctx, RTLNET_CLS_MODE_PASS_ALL);
    }
    return rc;
}

/*
 * rtlnet_classifier_bcast_storm_enable -- enable or disable policer 0 (the
 * broadcast storm limiter), keeping its limit and window.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_bcast_storm_enable(const rtlnet_classifier_t *ctx, int on)
{
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    wr(ctx, RTLNET_CLS_REG_POLICER(0u) + RTLNET_CLS_POL_CTRL, (on != 0) ? RTLNET_CLS_POL_CTRL_ENABLE : 0u);
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_get_build -- copy the built sizes read at init.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_get_build(const rtlnet_classifier_t *ctx, rtlnet_cls_build_t *build)
{
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (build == NULL) {
        return RTLNET_CLS_ERR_ARG;
    }
    build->table_entries = ctx->table_entries;
    build->tuple_entries = ctx->tuple_entries;
    build->num_rules = ctx->num_rules;
    build->num_policers = ctx->num_policers;
    build->table_lanes = ctx->table_lanes;
    build->match_depth_bytes = ctx->match_depth_bytes;
    build->ram_distributed = ctx->ram_distributed;
    build->delay_beats = ctx->delay_beats;
    build->verdict_latency = ctx->verdict_latency;
    return RTLNET_CLS_OK;
}

/*
 * rtlnet_classifier_protect_defaults -- fill a profile with the default limits
 * (RTLNET_CLS_PROT_*_DEFAULT frames per RTLNET_CLS_PROT_WINDOW_MS_DEFAULT).
 */
void rtlnet_classifier_protect_defaults(rtlnet_cls_protect_t *profile)
{
    uint32_t c;

    if (profile == NULL) {
        return;
    }
    profile->limit_pkts[RTLNET_CLS_PROT_BROADCAST] = RTLNET_CLS_PROT_BROADCAST_DEFAULT;
    profile->limit_pkts[RTLNET_CLS_PROT_UDP] = RTLNET_CLS_PROT_UDP_DEFAULT;
    profile->limit_pkts[RTLNET_CLS_PROT_ARP] = RTLNET_CLS_PROT_ARP_DEFAULT;
    profile->limit_pkts[RTLNET_CLS_PROT_ICMP] = RTLNET_CLS_PROT_ICMP_DEFAULT;
    for (c = 0u; c < (uint32_t)RTLNET_CLS_PROT_CLASSES; c++) {
        profile->window_ms[c] = RTLNET_CLS_PROT_WINDOW_MS_DEFAULT;
    }
}

/*
 * rtlnet_classifier_config_protect -- install the protection profile: every
 * frame passes (MODE = PASS_ALL) except what the four class policers limit.
 * Steps:
 *   1. Check the build holds the profile (1 MAC-table entry, 2 tuples, 1
 *      rule of 14 bytes, 4 policers) and every window is 1 ms or more;
 *      nothing is written when it does not.
 *   2. Clear everything (power-up state, MODE DROP_ALL).
 *   3. Rule 0: EtherType 0x0806 at bytes 12..13, classify-only, policer ARP.
 *   4. Tuple 0: IPv4 protocol 1, any addresses and ports, classify-only,
 *      policer ICMP.
 *   5. Tuple 1: IPv4 protocol 17, any addresses and ports, classify-only,
 *      policer UDP.
 *   6. MAC table entry 0: destination FF:FF:FF:FF:FF:FF, classify-only,
 *      policer BROADCAST.
 *   7. Policers 0..3 = the class limits and windows.
 *   8. MODE = PASS_ALL.
 * The hardware picks the policer in the order rule, tuple, MAC table, so a
 * frame in several classes is counted once: ARP first, then ICMP, UDP,
 * broadcast.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE (the
 * build is too small), RTLNET_CLS_ERR_NOT_INIT, or a failing step's code.
 */
int rtlnet_classifier_config_protect(const rtlnet_classifier_t *ctx, const rtlnet_cls_protect_t *profile)
{
    static const uint8_t bcast[RTLNET_CLS_MAC_BYTES] = {0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu};
    static const uint8_t arp_type[2] = {0x08u, 0x06u};
    static const uint8_t arp_mask[2] = {0xFFu, 0xFFu};
    rtlnet_cls_protect_t dflt;
    uint32_t c;
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if (profile == NULL) {
        rtlnet_classifier_protect_defaults(&dflt);
        profile = &dflt;
    }
    for (c = 0u; c < (uint32_t)RTLNET_CLS_PROT_CLASSES; c++) {
        if (profile->window_ms[c] == 0u) {
            return RTLNET_CLS_ERR_ARG;
        }
    }
    if (ctx->table_entries < RTLNET_CLS_PROT_MIN_TABLE_ENTRIES || ctx->tuple_entries < RTLNET_CLS_PROT_MIN_TUPLES ||
        ctx->num_rules < RTLNET_CLS_PROT_MIN_RULES || ctx->num_policers < RTLNET_CLS_PROT_MIN_POLICERS ||
        ctx->match_depth_bytes < RTLNET_CLS_PROT_MIN_MATCH_BYTES) {
        return RTLNET_CLS_ERR_RANGE;
    }
    rc = rtlnet_classifier_clear_all(ctx);
    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_rule_pattern(ctx, 0u, RTLNET_CLS_PROT_ARP_ETYPE_OFFSET, 2u, arp_type, arp_mask);
    }
    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_rule_mode(ctx, 0u, 1, 0, 1, 1, (uint32_t)RTLNET_CLS_PROT_ARP);
    }
    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_acl_add(ctx, 0u, (uint8_t)RTLNET_CLS_PROT_ICMP_PROTO, 0u, 0u, 0u, 0u, 0u, 0xFFFFu, 0u,
                                       0xFFFFu, RTLNET_CLS_ACT_CLASSIFY | RTLNET_CLS_ACT_POLICE(RTLNET_CLS_PROT_ICMP));
    }
    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_acl_add(ctx, 1u, (uint8_t)RTLNET_CLS_PROT_UDP_PROTO, 0u, 0u, 0u, 0u, 0u, 0xFFFFu, 0u,
                                       0xFFFFu, RTLNET_CLS_ACT_CLASSIFY | RTLNET_CLS_ACT_POLICE(RTLNET_CLS_PROT_UDP));
    }
    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_mac_filter(ctx, 0u, bcast, RTLNET_CLS_SIDE_DST,
                                          RTLNET_CLS_ACT_CLASSIFY | RTLNET_CLS_ACT_POLICE(RTLNET_CLS_PROT_BROADCAST));
    }
    for (c = 0u; rc == RTLNET_CLS_OK && c < (uint32_t)RTLNET_CLS_PROT_CLASSES; c++) {
        rc = rtlnet_classifier_policer_set(ctx, c, 1, profile->limit_pkts[c], profile->window_ms[c]);
    }
    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_set_mode(ctx, RTLNET_CLS_MODE_PASS_ALL);
    }
    return rc;
}

/*
 * rtlnet_classifier_protect_limit -- change the limit and window of one class
 * of an installed profile (enables its policer, restarts its window).
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG (class or window 0),
 * RTLNET_CLS_ERR_RANGE, RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_protect_limit(const rtlnet_classifier_t *ctx, rtlnet_cls_prot_class_t cls,
                                    uint32_t limit_pkts, uint32_t window_ms)
{
    int rc = ready(ctx);

    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    if ((uint32_t)cls >= (uint32_t)RTLNET_CLS_PROT_CLASSES || window_ms == 0u) {
        return RTLNET_CLS_ERR_ARG;
    }
    return rtlnet_classifier_policer_set(ctx, (uint32_t)cls, 1, limit_pkts, window_ms);
}

/*
 * rtlnet_classifier_protect_get -- limit, window and counters of one class.
 * Returns: RTLNET_CLS_OK, RTLNET_CLS_ERR_ARG, RTLNET_CLS_ERR_RANGE,
 * RTLNET_CLS_ERR_NOT_INIT.
 */
int rtlnet_classifier_protect_get(const rtlnet_classifier_t *ctx, rtlnet_cls_prot_class_t cls,
                                  rtlnet_cls_policer_t *state)
{
    if ((uint32_t)cls >= (uint32_t)RTLNET_CLS_PROT_CLASSES) {
        return RTLNET_CLS_ERR_ARG;
    }
    return rtlnet_classifier_policer_get(ctx, (uint32_t)cls, state);
}
