/*
 * rtlnet_classifier.h -- RTLNet frame classifier driver interface
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the rtlnet_classifier register map (4 KiB
 * window; on the CPU path the protocol sub-map window 0x8000) and the driver
 * API that owns it. The RTL package
 * cores/rtlnet_classifier/hdl/rtlnet_classifier_pkg.sv mirrors every offset
 * and bit below in localparams; the two change together in one commit. If
 * they drift, a write lands in the wrong register (or in none: undefined
 * offsets ignore writes and read 0) and the filter runs a configuration
 * nobody wrote, silently.
 *
 * Contract:
 *   - Power-up and after rtlnet_classifier_clear_all(): MODE = DROP_ALL,
 *     every entry invalid, every table, rule and policer disabled: the
 *     filter passes nothing until configured.
 *   - Field values are in number order (first wire byte most significant):
 *     MAC 00:11:22:33:44:55 is 0x001122334455, IPv4 192.169.1.220 is
 *     0xC0A901DC, a port or EtherType is its 16-bit value.
 *   - Entry update protocol (done by the set functions): disable the table
 *     or rule, write the words, re-enable. While disabled, the table or rule
 *     takes no part in the decision.
 *   - Range and data/mask compares use entry pairs (2k, 2k+1): low/high or
 *     value/mask; the control word of entry 2k governs the pair.
 *   - Every function is bounded (named limits) and returns RTLNET_CLS_OK or
 *     a negative RTLNET_CLS_ERR_* code. All functions take the context set
 *     up by rtlnet_classifier_init(); one context per classifier instance.
 *
 * This header holds offsets, bit fields, types and contract prose; the
 * per-function commentary is in rtlnet_classifier.c.
 */
#ifndef RTLNET_CLASSIFIER_H
#define RTLNET_CLASSIFIER_H

#include <stdint.h>   /* uint8_t, uint16_t, uint32_t, uint64_t, uintptr_t */

/* -------------------------------------------------------------------------
 * Register offsets (byte offsets in the 4 KiB window)
 * ------------------------------------------------------------------------- */
#define RTLNET_CLS_REG_ID              0x000u   /* RO "CLSF" */
#define RTLNET_CLS_REG_VERSION         0x004u   /* RO 0xMMDDYYYY */
#define RTLNET_CLS_REG_CAPS            0x008u   /* RO build parameters */
#define RTLNET_CLS_REG_CTRL            0x00Cu   /* RW MODE, pulses CLEAR_TABLES / CNT_CLEAR */
#define RTLNET_CLS_REG_STATUS          0x010u   /* RO CLEARING, MODE, STALL_SEEN */
#define RTLNET_CLS_REG_LATENCY         0x014u   /* RO DELAY_BEATS, VERDICT_LATENCY */
#define RTLNET_CLS_REG_TABLE_MODE(t)   (0x020u + 4u * (uint32_t)(t))     /* RW, t = 0..5 */
#define RTLNET_CLS_REG_RULE_MODE(r)    (0x040u + 4u * (uint32_t)(r))     /* RW, r = 0..3 */
#define RTLNET_CLS_REG_COUNTER(i)      (0x080u + 4u * (uint32_t)(i))     /* RO, i = RTLNET_CLS_CNT_* */
#define RTLNET_CLS_REG_POLICER(p)      (0x100u + 0x20u * (uint32_t)(p))  /* p = 0..3 */
#define RTLNET_CLS_REG_ENTRY(t, e)     (0x400u + 0x100u * (uint32_t)(t) + 0x10u * (uint32_t)(e))
#define RTLNET_CLS_REG_TUPLE(e)        (0x900u + 0x20u * (uint32_t)(e))
#define RTLNET_CLS_REG_RULE_BASE       0xC00u   /* + rule_stride * r + 4 b */
#define RTLNET_CLS_WINDOW_BYTES        0x1000u

/* Counter indices (RTLNET_CLS_REG_COUNTER). */
#define RTLNET_CLS_CNT_FRAMES          0u
#define RTLNET_CLS_CNT_PASSED          1u
#define RTLNET_CLS_CNT_DROPPED         2u
#define RTLNET_CLS_CNT_MODE_DROPPED    3u
#define RTLNET_CLS_CNT_POLICE_DROPPED  4u
#define RTLNET_CLS_CNT_TABLE_HIT       5u    /* + table, 0..5 */
#define RTLNET_CLS_CNT_RULE_HIT        11u   /* + rule, 0..3 */
#define RTLNET_CLS_CNT_OVERRUN_DROPPED 15u
#define RTLNET_CLS_NUM_COUNTERS        16u

/* Policer register offsets inside RTLNET_CLS_REG_POLICER(p). */
#define RTLNET_CLS_POL_CTRL            0x00u   /* RW bit 0 ENABLE */
#define RTLNET_CLS_POL_LIMIT           0x04u   /* RW LIMIT_PKTS per window */
#define RTLNET_CLS_POL_WINDOW          0x08u   /* RW WINDOW_MS (0 acts as 1) */
#define RTLNET_CLS_POL_SEEN            0x0Cu   /* RO frames policed */
#define RTLNET_CLS_POL_PASSED          0x10u   /* RO policed frames passed */
#define RTLNET_CLS_POL_DROPPED         0x14u   /* RO policed frames dropped */
#define RTLNET_CLS_POL_BUDGET          0x18u   /* RO frames left in the current window */
#define RTLNET_CLS_POL_CTRL_ENABLE     0x00000001u

/* Field-table entry word offsets inside RTLNET_CLS_REG_ENTRY(t, e). */
#define RTLNET_CLS_ENT_SRC_LO          0x0u    /* SRC_VALUE[31:0] */
#define RTLNET_CLS_ENT_CTRL            0x4u    /* control word, SRC_VALUE[47:32] */
#define RTLNET_CLS_ENT_DST_LO          0x8u    /* DST_VALUE[31:0] */
#define RTLNET_CLS_ENT_DST_HI          0xCu    /* DST_VALUE[47:32] in [15:0] */

/* Field-table entry control word bits. */
#define RTLNET_CLS_ENT_SRC_HI_MASK     0x0000FFFFu
#define RTLNET_CLS_ENT_PROTO_SHIFT     16u
#define RTLNET_CLS_ENT_PROTO_MASK      0x00FF0000u
#define RTLNET_CLS_ENT_POLICER_SHIFT   24u
#define RTLNET_CLS_ENT_POLICER_MASK    0x03000000u
#define RTLNET_CLS_ENT_POLICE_EN       0x04000000u
#define RTLNET_CLS_ENT_PROTO_EN        0x08000000u   /* PORT table only */
#define RTLNET_CLS_ENT_BOTH            0x10000000u   /* both sides: 1 AND, 0 OR */
#define RTLNET_CLS_ENT_DST_EN          0x20000000u
#define RTLNET_CLS_ENT_SRC_EN          0x40000000u
#define RTLNET_CLS_ENT_VALID           0x80000000u

/* Tuple entry word offsets inside RTLNET_CLS_REG_TUPLE(e). */
#define RTLNET_CLS_TUP_CTRL            0x00u
#define RTLNET_CLS_TUP_SRC_IP          0x04u
#define RTLNET_CLS_TUP_SRC_MASK        0x08u
#define RTLNET_CLS_TUP_DST_IP          0x0Cu
#define RTLNET_CLS_TUP_DST_MASK        0x10u
#define RTLNET_CLS_TUP_SPORT           0x14u   /* [15:0] LO, [31:16] HI */
#define RTLNET_CLS_TUP_DPORT           0x18u
#define RTLNET_CLS_TUP_WORDS           7u

/* Tuple control word bits. */
#define RTLNET_CLS_TUP_PROTO_MASK      0x000000FFu
#define RTLNET_CLS_TUP_POLICER_SHIFT   8u
#define RTLNET_CLS_TUP_POLICER_MASK    0x00000300u
#define RTLNET_CLS_TUP_POLICE_EN       0x20000000u
#define RTLNET_CLS_TUP_PROTO_EN        0x40000000u
#define RTLNET_CLS_TUP_VALID           0x80000000u

/* Rule compare-buffer word: (byte & MASK) OP (COMPARE & MASK). */
#define RTLNET_CLS_RB_COMPARE_MASK     0x000000FFu
#define RTLNET_CLS_RB_OP_SHIFT         8u
#define RTLNET_CLS_RB_OP_MASK          0x00000F00u
#define RTLNET_CLS_RB_MASK_SHIFT       24u
#define RTLNET_CLS_RB_MASK_MASK        0xFF000000u

/* Register values. */
#define RTLNET_CLS_ID_VALUE            0x434C5346u   /* "CLSF" */
#define RTLNET_CLS_VERSION_VALUE       0x10222026u

/* CTRL bits. */
#define RTLNET_CLS_CTRL_MODE_MASK      0x00000003u
#define RTLNET_CLS_CTRL_CLEAR_TABLES   0x00000100u   /* self-clearing pulse, reads 0 */
#define RTLNET_CLS_CTRL_CNT_CLEAR      0x00010000u   /* self-clearing pulse, reads 0 */

/* STATUS bits. */
#define RTLNET_CLS_STATUS_CLEARING     0x00000001u
#define RTLNET_CLS_STATUS_MODE_SHIFT   8u
#define RTLNET_CLS_STATUS_MODE_MASK    0x00000300u
#define RTLNET_CLS_STATUS_STALL_SEEN   0x00010000u   /* sticky, cleared by CNT_CLEAR */

/* CAPS fields. */
#define RTLNET_CLS_CAPS_TABLE_ENTRIES(c)  (((c) >> 0) & 0x1Fu)
#define RTLNET_CLS_CAPS_TUPLE_ENTRIES(c)  (((c) >> 5) & 0x1Fu)
#define RTLNET_CLS_CAPS_NUM_RULES(c)      (((c) >> 10) & 0x7u)
#define RTLNET_CLS_CAPS_NUM_POLICERS(c)   (((c) >> 13) & 0x7u)
#define RTLNET_CLS_CAPS_TABLE_LANES(c)    (((c) >> 16) & 0x1Fu)
#define RTLNET_CLS_CAPS_MATCH_BEATS(c)    (((c) >> 21) & 0x3Fu)   /* MATCH_DEPTH_BYTES / 8 */
#define RTLNET_CLS_CAPS_RAM_DIST(c)       (((c) >> 27) & 0x1u)    /* 1 = RAM_STYLE "distributed" */

/* LATENCY fields. */
#define RTLNET_CLS_LAT_DELAY_BEATS(v)     (((v) >> 0) & 0xFFu)
#define RTLNET_CLS_LAT_VERDICT(v)         (((v) >> 8) & 0xFFu)

/* TABLE_MODE bits. */
#define RTLNET_CLS_TM_ENABLE           0x01u
#define RTLNET_CLS_TM_EXCLUDE          0x02u
#define RTLNET_CLS_TM_COMPARE_SHIFT    2u
#define RTLNET_CLS_TM_COMPARE_MASK     0x0Cu
#define RTLNET_CLS_TM_CLASSIFY         0x10u
#define RTLNET_CLS_TM_VLAN_AWARE       0x80u

/* RULE_MODE bits. */
#define RTLNET_CLS_RM_ENABLE           0x01u
#define RTLNET_CLS_RM_EXCLUDE          0x02u
#define RTLNET_CLS_RM_CLASSIFY         0x04u
#define RTLNET_CLS_RM_POLICE_EN        0x08u
#define RTLNET_CLS_RM_POLICER_SHIFT    4u
#define RTLNET_CLS_RM_POLICER_MASK     0x30u

/* Limits of the register map (the build may be smaller, see CAPS). */
#define RTLNET_CLS_MAX_ENTRIES         16u
#define RTLNET_CLS_MAX_TUPLES          16u
#define RTLNET_CLS_MAX_RULES           4u
#define RTLNET_CLS_MAX_POLICERS        4u
#define RTLNET_CLS_MIN_RULE_STRIDE     0x100u
#define RTLNET_CLS_RULE_WINDOW_BYTES   0x400u
#define RTLNET_CLS_MAC_BYTES           6u
#define RTLNET_CLS_VALUE_MASK48        0x0000FFFFFFFFFFFFull

/* Driver bounds. CLEARING lasts 1024 axis_clk clocks (about 10 us at
 * 100 MHz); each STATUS read takes well over 10 clocks, so the poll limit is
 * a generous bound. SETTLE_READS: register reads between the last rule-byte
 * write and re-enabling the rule (the rule's don't-care suffix settles in
 * MATCH_DEPTH_BYTES / 8 + 8 axis_clk clocks; one read crosses the register
 * clock domain twice). */
#define RTLNET_CLS_CLEAR_POLL_MAX      100000u
#define RTLNET_CLS_SETTLE_READS        8u

/* Status codes. */
#define RTLNET_CLS_OK                  0
#define RTLNET_CLS_ERR_ARG             (-1)    /* null pointer or bad enum */
#define RTLNET_CLS_ERR_ID              (-2)    /* ID / VERSION / CAPS mismatch at init */
#define RTLNET_CLS_ERR_TIMEOUT         (-3)    /* CLEARING did not end */
#define RTLNET_CLS_ERR_RANGE           (-4)    /* index beyond what the build has */
#define RTLNET_CLS_ERR_NOT_INIT        (-5)    /* context not initialised */
#define RTLNET_CLS_ERR_IN_USE          (-6)    /* live add on a valid slot, or while CLEARING */

/* -------------------------------------------------------------------------
 * Types
 * ------------------------------------------------------------------------- */
typedef enum {
    RTLNET_CLS_MODE_DROP_ALL      = 0,   /* power-up */
    RTLNET_CLS_MODE_PASS_ALL      = 1,
    RTLNET_CLS_MODE_PASS_ON_MATCH = 2,
    RTLNET_CLS_MODE_DROP_ON_MATCH = 3
} rtlnet_cls_mode_t;

typedef enum {
    RTLNET_CLS_TABLE_MAC       = 0,
    RTLNET_CLS_TABLE_ETHERTYPE = 1,
    RTLNET_CLS_TABLE_VLAN      = 2,
    RTLNET_CLS_TABLE_IP        = 3,
    RTLNET_CLS_TABLE_PORT      = 4,
    RTLNET_CLS_TABLE_TUPLE     = 5,
    RTLNET_CLS_NUM_TABLES      = 6
} rtlnet_cls_table_t;

typedef enum {
    RTLNET_CLS_CMP_SINGLE = 0,           /* one value per entry */
    RTLNET_CLS_CMP_RANGE  = 1,           /* pair low/high, inclusive */
    RTLNET_CLS_CMP_MASK   = 2            /* pair value/mask */
} rtlnet_cls_compare_t;

/* Which side of a field a helper compares. */
typedef enum {
    RTLNET_CLS_SIDE_SRC    = 0,
    RTLNET_CLS_SIDE_DST    = 1,
    RTLNET_CLS_SIDE_EITHER = 2,
    RTLNET_CLS_SIDE_BOTH   = 3
} rtlnet_cls_side_t;

/* Rule byte operators (rtlnet_classifier_rule_byte). */
typedef enum {
    RTLNET_CLS_OP_DONT_CARE = 0x0,
    RTLNET_CLS_OP_EQ        = 0x8,
    RTLNET_CLS_OP_NE        = 0x9,
    RTLNET_CLS_OP_LT        = 0xA,
    RTLNET_CLS_OP_GT        = 0xB,
    RTLNET_CLS_OP_LE        = 0xC,
    RTLNET_CLS_OP_GE        = 0xD
} rtlnet_cls_op_t;

/* Helper actions: RTLNET_CLS_ACT_GATE (the table takes part in match) or
 * RTLNET_CLS_ACT_CLASSIFY (classify-only: hits are counted and police),
 * optionally ORed with RTLNET_CLS_ACT_POLICE(p) (a hit selects policer p). */
#define RTLNET_CLS_ACT_GATE            0x00u
#define RTLNET_CLS_ACT_CLASSIFY        0x01u
#define RTLNET_CLS_ACT_POLICE_FLAG     0x10u
#define RTLNET_CLS_ACT_POLICER_SHIFT   2u
#define RTLNET_CLS_ACT_POLICE(p)       (RTLNET_CLS_ACT_POLICE_FLAG | (((uint32_t)(p) & 0x3u) << RTLNET_CLS_ACT_POLICER_SHIFT))
#define RTLNET_CLS_ACT_POLICER(a)      (((uint32_t)(a) >> RTLNET_CLS_ACT_POLICER_SHIFT) & 0x3u)

/* One field-table entry (rtlnet_classifier_table_entry_set/get). */
typedef struct {
    uint8_t  valid;        /* entry in use */
    uint8_t  src_en;       /* compare the source field */
    uint8_t  dst_en;       /* compare the destination field */
    uint8_t  both;         /* both enabled: 1 AND, 0 OR */
    uint8_t  proto_en;     /* PORT table: also require IP protocol == proto */
    uint8_t  proto;
    uint8_t  police_en;    /* a hit selects policer */
    uint8_t  policer;      /* 0..3 */
    uint64_t src_value;    /* 48 bits used */
    uint64_t dst_value;
} rtlnet_cls_entry_t;

/* One tuple (ACL) entry. A port range 0..65535 is "any". */
typedef struct {
    uint8_t  valid;
    uint8_t  proto_en;
    uint8_t  proto;        /* 6 TCP, 17 UDP, 1 ICMP */
    uint8_t  police_en;
    uint8_t  policer;
    uint32_t src_ip;
    uint32_t src_mask;     /* 0 = any */
    uint32_t dst_ip;
    uint32_t dst_mask;
    uint16_t sport_lo;
    uint16_t sport_hi;
    uint16_t dport_lo;
    uint16_t dport_hi;
} rtlnet_cls_tuple_t;

/* Decoded TABLE_MODE. */
typedef struct {
    uint8_t enable;
    uint8_t exclude;
    uint8_t compare;       /* rtlnet_cls_compare_t */
    uint8_t classify;
    uint8_t vlan_aware;
} rtlnet_cls_table_mode_t;

/* Decoded RULE_MODE. */
typedef struct {
    uint8_t enable;
    uint8_t exclude;
    uint8_t classify;
    uint8_t police_en;
    uint8_t policer;
} rtlnet_cls_rule_mode_t;

/* Policer configuration and statistics. */
typedef struct {
    uint8_t  enable;
    uint32_t limit_pkts;
    uint32_t window_ms;
    uint32_t seen;
    uint32_t passed;
    uint32_t dropped;
    uint32_t budget;
} rtlnet_cls_policer_t;

/* Statistics. Identities once traffic stops: frames = passed + dropped,
 * dropped = mode_dropped + police_dropped + overrun_dropped. */
typedef struct {
    uint32_t frames;
    uint32_t passed;
    uint32_t dropped;
    uint32_t mode_dropped;
    uint32_t police_dropped;
    uint32_t overrun_dropped;
    uint32_t table_hit[RTLNET_CLS_NUM_TABLES];
    uint32_t rule_hit[RTLNET_CLS_MAX_RULES];
} rtlnet_cls_counters_t;

/* Driver context, one per classifier instance; filled by init. */
typedef struct {
    uintptr_t base;
    uint32_t  table_entries;
    uint32_t  tuple_entries;
    uint32_t  num_rules;
    uint32_t  num_policers;
    uint32_t  table_lanes;
    uint32_t  match_depth_bytes;
    uint32_t  ram_distributed; /* 1 = built with RAM_STYLE "distributed" */
    uint32_t  rule_stride;     /* bytes between rule compare buffers */
    uint32_t  delay_beats;
    uint32_t  verdict_latency;
    uint32_t  initialised;
} rtlnet_classifier_t;

/* Built sizes of one instance (rtlnet_classifier_get_build), as read from CAPS and LATENCY at init. */
typedef struct {
    uint32_t table_entries;     /* entries per field table */
    uint32_t tuple_entries;
    uint32_t num_rules;
    uint32_t num_policers;
    uint32_t table_lanes;
    uint32_t match_depth_bytes;
    uint32_t ram_distributed;   /* 1 = RAM_STYLE "distributed", 0 = "block" */
    uint32_t delay_beats;
    uint32_t verdict_latency;
} rtlnet_cls_build_t;

/* Protection profile (rtlnet_classifier_config_protect): traffic classes, each policed by the policer of the
 * same number. Priority when a frame is in several classes: ARP (rule 0), ICMP (tuple 0), UDP (tuple 1),
 * broadcast (MAC table entry 0). Everything else passes unpoliced (MODE = PASS_ALL). */
typedef enum {
    RTLNET_CLS_PROT_BROADCAST = 0,   /* destination FF:FF:FF:FF:FF:FF (not ARP, ICMP or UDP) */
    RTLNET_CLS_PROT_UDP       = 1,   /* IPv4 protocol 17 that no hardware leaf claimed (closed ports) */
    RTLNET_CLS_PROT_ARP       = 2,   /* EtherType 0x0806, requests and replies */
    RTLNET_CLS_PROT_ICMP      = 3,   /* IPv4 protocol 1 */
    RTLNET_CLS_PROT_CLASSES   = 4
} rtlnet_cls_prot_class_t;

/* Default limits: frames per 100 ms window (reasoning in the classifier document, section 12). */
#define RTLNET_CLS_PROT_WINDOW_MS_DEFAULT   100u
#define RTLNET_CLS_PROT_BROADCAST_DEFAULT   10u
#define RTLNET_CLS_PROT_UDP_DEFAULT         10u
#define RTLNET_CLS_PROT_ARP_DEFAULT         20u
#define RTLNET_CLS_PROT_ICMP_DEFAULT        10u

/* Smallest build the profile fits: 1 MAC-table entry, 1 rule, 2 tuples, 4 policers, 14 compared bytes. */
#define RTLNET_CLS_PROT_MIN_TABLE_ENTRIES   1u
#define RTLNET_CLS_PROT_MIN_TUPLES          2u
#define RTLNET_CLS_PROT_MIN_RULES           1u
#define RTLNET_CLS_PROT_MIN_POLICERS        4u
#define RTLNET_CLS_PROT_MIN_MATCH_BYTES     14u
#define RTLNET_CLS_PROT_ARP_ETYPE_OFFSET    12u   /* rule 0 compares bytes 12..13 = 08 06 */
#define RTLNET_CLS_PROT_ICMP_PROTO          1u
#define RTLNET_CLS_PROT_UDP_PROTO           17u

typedef struct {
    uint32_t limit_pkts[RTLNET_CLS_PROT_CLASSES];
    uint32_t window_ms[RTLNET_CLS_PROT_CLASSES];   /* 1 or more */
} rtlnet_cls_protect_t;

/* Firewall for the CPU path (rtlnet_classifier_firewall_apply), built from existing hardware, no RTL change:
 *   MODE = DROP_ON_MATCH, EtherType table gating + EXCLUDE with one range pair 0x0806..0x0806 (ARP),
 *   tuple table gating + EXCLUDE holding the allow list.
 * A frame drops when it is not ARP AND hits no allow entry (match = AND over the enabled gating engines; an
 * EXCLUDE table contributes "no entry hit"). ARP and allowed tuples pass, everything else drops; with zero
 * allow entries only ARP passes. The allow entries sit in tuple slots 0..count-1; the other slots are written
 * invalid. Layers on top of clear_all plus a profile: the MAC table and rule 0 stay as they are. */
typedef struct {
    const rtlnet_cls_tuple_t *allow;      /* allow entries, written to tuple slots 0..count-1 */
    uint32_t                  count;      /* 0 = only ARP passes */
    uint32_t                  etype_pair; /* EtherType range-pair index used for ARP (entries 2i, 2i+1) */
} rtlnet_cls_firewall_t;

/* -------------------------------------------------------------------------
 * API
 * ------------------------------------------------------------------------- */
int rtlnet_classifier_init(rtlnet_classifier_t *ctx, uintptr_t base);
int rtlnet_classifier_get_build(const rtlnet_classifier_t *ctx, rtlnet_cls_build_t *build);

int rtlnet_classifier_set_mode(const rtlnet_classifier_t *ctx, rtlnet_cls_mode_t mode);
int rtlnet_classifier_get_mode(const rtlnet_classifier_t *ctx, rtlnet_cls_mode_t *mode);
int rtlnet_classifier_get_status(const rtlnet_classifier_t *ctx, uint32_t *status);
int rtlnet_classifier_clear_all(const rtlnet_classifier_t *ctx);

int rtlnet_classifier_table_mode(const rtlnet_classifier_t *ctx, rtlnet_cls_table_t table, int enable,
                                 int exclude, rtlnet_cls_compare_t compare, int classify, int vlan_aware);
int rtlnet_classifier_get_table_mode(const rtlnet_classifier_t *ctx, rtlnet_cls_table_t table,
                                     rtlnet_cls_table_mode_t *mode);
int rtlnet_classifier_table_entry_set(const rtlnet_classifier_t *ctx, rtlnet_cls_table_t table,
                                      uint32_t index, const rtlnet_cls_entry_t *entry);
int rtlnet_classifier_table_entry_get(const rtlnet_classifier_t *ctx, rtlnet_cls_table_t table,
                                      uint32_t index, rtlnet_cls_entry_t *entry);
int rtlnet_classifier_tuple_set(const rtlnet_classifier_t *ctx, uint32_t index,
                                const rtlnet_cls_tuple_t *tuple);
int rtlnet_classifier_tuple_get(const rtlnet_classifier_t *ctx, uint32_t index, rtlnet_cls_tuple_t *tuple);

int rtlnet_classifier_rule_mode(const rtlnet_classifier_t *ctx, uint32_t rule, int enable, int exclude,
                                int classify, int police_en, uint32_t policer);
int rtlnet_classifier_get_rule_mode(const rtlnet_classifier_t *ctx, uint32_t rule,
                                    rtlnet_cls_rule_mode_t *mode);
int rtlnet_classifier_rule_byte(const rtlnet_classifier_t *ctx, uint32_t rule, uint32_t byte, uint8_t mask,
                                rtlnet_cls_op_t op, uint8_t value);
int rtlnet_classifier_rule_pattern(const rtlnet_classifier_t *ctx, uint32_t rule, uint32_t offset,
                                   uint32_t len, const uint8_t *data, const uint8_t *mask);

int rtlnet_classifier_policer_set(const rtlnet_classifier_t *ctx, uint32_t policer, int enable,
                                  uint32_t limit_pkts, uint32_t window_ms);
int rtlnet_classifier_policer_get(const rtlnet_classifier_t *ctx, uint32_t policer,
                                  rtlnet_cls_policer_t *state);

int rtlnet_classifier_counters(const rtlnet_classifier_t *ctx, rtlnet_cls_counters_t *counters);
int rtlnet_classifier_clear_counters(const rtlnet_classifier_t *ctx);

int rtlnet_classifier_mac_filter(const rtlnet_classifier_t *ctx, uint32_t index,
                                 const uint8_t mac[RTLNET_CLS_MAC_BYTES], rtlnet_cls_side_t which,
                                 uint32_t action);
int rtlnet_classifier_ethertype_filter(const rtlnet_classifier_t *ctx, uint32_t index, uint16_t lo,
                                       uint16_t hi, uint32_t action);
int rtlnet_classifier_ipv4_filter(const rtlnet_classifier_t *ctx, uint32_t index, rtlnet_cls_side_t which,
                                  uint32_t addr, uint32_t mask, uint32_t action);
int rtlnet_classifier_port_filter(const rtlnet_classifier_t *ctx, uint32_t index, uint8_t proto,
                                  rtlnet_cls_side_t which, uint16_t lo, uint16_t hi, uint32_t action);
int rtlnet_classifier_acl_add(const rtlnet_classifier_t *ctx, uint32_t index, uint8_t proto,
                              uint32_t src, uint32_t src_mask, uint32_t dst, uint32_t dst_mask,
                              uint16_t sport_lo, uint16_t sport_hi, uint16_t dport_lo, uint16_t dport_hi,
                              uint32_t action);

int rtlnet_classifier_config_bcast_storm(const rtlnet_classifier_t *ctx, uint32_t limit_pkts,
                                         uint32_t window_ms);
int rtlnet_classifier_bcast_storm_enable(const rtlnet_classifier_t *ctx, int on);

int rtlnet_classifier_firewall_apply(const rtlnet_classifier_t *ctx, const rtlnet_cls_firewall_t *fw);
/* Live update of one allow entry without disabling the tuple table (an EXCLUDE table that is disabled
 * would drop all IP during the write): value words first, control word with VALID last. */
int rtlnet_classifier_tuple_live_set(const rtlnet_classifier_t *ctx, uint32_t index,
                                     const rtlnet_cls_tuple_t *tuple);
int rtlnet_classifier_tuple_live_clear(const rtlnet_classifier_t *ctx, uint32_t index);

void rtlnet_classifier_protect_defaults(rtlnet_cls_protect_t *profile);
int rtlnet_classifier_protect_load(const rtlnet_classifier_t *ctx, const rtlnet_cls_protect_t *profile);   /* everything but the final MODE write */
int rtlnet_classifier_config_protect(const rtlnet_classifier_t *ctx, const rtlnet_cls_protect_t *profile);
int rtlnet_classifier_protect_limit(const rtlnet_classifier_t *ctx, rtlnet_cls_prot_class_t cls,
                                    uint32_t limit_pkts, uint32_t window_ms);
int rtlnet_classifier_protect_get(const rtlnet_classifier_t *ctx, rtlnet_cls_prot_class_t cls,
                                  rtlnet_cls_policer_t *state);

#endif /* RTLNET_CLASSIFIER_H */
