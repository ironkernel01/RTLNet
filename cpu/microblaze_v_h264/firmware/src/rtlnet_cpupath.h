/*
 * rtlnet_cpupath.h -- CPU network path control: the CPU-path classifier
 *                     (broadcast storm limiter and filter tables) and the
 *                     protocol wrapper's CPU-path registers
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: owns the firmware's configuration of the CPU-path classifier
 * (rtlnet_classifier instance u_cpu_classifier inside rtlnet_eth_protocol,
 * registers at protocol sub-map 0x8000, cores/rtlnet_classifier/documentation)
 * and applies it through the classifier driver; the CLI edits the
 * configuration here and prints it back in the running configuration. The
 * classifier powers up DROP-ALL: until cpupath_init() has configured it the
 * CPU (lwIP) receives nothing.
 *
 * Default (cpupath_cls_defaults, the driver's config_bcast_storm(10, 100)):
 * MODE pass-all, MAC table classify-only with entry 0 destination
 * FF:FF:FF:FF:FF:FF policed by policer 0, policer 0 = 10 frames per 100 ms.
 * "storm-control broadcast" is policer 0 plus that MAC entry.
 *
 * Driver binding: the wrapper's CPU-path registers through the
 * rtlnet_eth_protocol driver (rtlnet_eth_protocol_cpu_path_present,
 * _set/_get_cpu_path_enable, _read_cpu_counters); the classifier through
 * cores/rtlnet_classifier/driver (rtlnet_classifier_t context held here,
 * RTLNET_PLAT_CLS_BASE). A classifier that does not answer its ID ("CLSF")
 * is reported absent and the configuration is only kept.
 *
 * Mapping of the CLI entries onto the driver's helpers: MAC entries 0..15
 * are single-value entries of the MAC table (rtlnet_classifier_mac_filter);
 * EtherType entries 0..7 are range pairs of the EtherType table (entries
 * 2i, 2i+1, rtlnet_classifier_ethertype_filter); ACL entries 0..15 are the
 * tuple table (rtlnet_classifier_acl_add). The CLASSIFY flag of a table is
 * per table: a table gates (takes part in the match) as soon as one of its
 * entries has the action gate, otherwise it is classify-only and its police
 * entries only count and police.
 *
 * This header holds types, constants and signatures; rtlnet_cpupath.c holds
 * the per-function commentary.
 */
#ifndef RTLNET_CPUPATH_H
#define RTLNET_CPUPATH_H

#include <stdint.h>   /* uint8_t, uint16_t, uint32_t */

#define CPUPATH_CLS_ENTRIES        16u     /* MAC and ACL entries (classifier TABLE_ENTRIES / TUPLE_ENTRIES) */
#define CPUPATH_CLS_PAIRS          8u      /* EtherType range pairs (TABLE_ENTRIES / 2) */
#define CPUPATH_CLS_POLICERS       4u      /* classifier NUM_POLICERS */
#define CPUPATH_STORM_POLICER      0u
#define CPUPATH_STORM_MAC_ENTRY    0u
#define CPUPATH_STORM_LIMIT_DEF    10u
#define CPUPATH_STORM_WINDOW_DEF   100u

/* Global MODE (classifier CTRL.MODE). */
#define CPUPATH_MODE_DROP_ALL      0u
#define CPUPATH_MODE_PASS_ALL      1u
#define CPUPATH_MODE_PASS_ON_MATCH 2u
#define CPUPATH_MODE_DROP_ON_MATCH 3u

/* Entry action. */
#define CPUPATH_ACT_GATE           0u      /* takes part in the match */
#define CPUPATH_ACT_CLASSIFY       1u      /* counted only */
#define CPUPATH_ACT_POLICE         2u      /* classify-only, policed by .policer */

/* Results. */
#define CPUPATH_OK                 0
#define CPUPATH_ABSENT             (-1)    /* classifier not in this bitstream */
#define CPUPATH_NO_DRIVER          (-2)    /* driver not in this firmware build */
#define CPUPATH_BAD_ARG            (-3)
#define CPUPATH_HW_ERROR           (-4)

typedef struct {
    int      valid;
    int      dst;                  /* 1 destination MAC, 0 source */
    uint8_t  mac[6];
    unsigned action;
    unsigned policer;
} cpupath_mac_entry_t;

typedef struct {
    int      valid;
    uint16_t lo;
    uint16_t hi;                   /* == lo for a single value */
    unsigned action;
    unsigned policer;
} cpupath_etype_entry_t;

typedef struct {
    int      valid;
    uint8_t  proto;                /* 0 any, 6 TCP, 17 UDP */
    uint32_t src;
    uint32_t src_mask;
    uint32_t dst;
    uint32_t dst_mask;
    uint16_t sport_lo;
    uint16_t sport_hi;
    uint16_t dport_lo;
    uint16_t dport_hi;
    unsigned action;
    unsigned policer;
} cpupath_acl_entry_t;

typedef struct {
    int      enabled;
    uint32_t limit_pkts;
    uint32_t window_ms;
} cpupath_policer_t;

typedef struct {
    unsigned              mode;
    cpupath_mac_entry_t   mac[CPUPATH_CLS_ENTRIES];
    cpupath_etype_entry_t etype[CPUPATH_CLS_PAIRS];
    cpupath_acl_entry_t   acl[CPUPATH_CLS_ENTRIES];
    cpupath_policer_t     pol[CPUPATH_CLS_POLICERS];
} cpupath_cls_config_t;

typedef struct {
    int      valid;                /* counters read from the hardware */
    uint32_t frames;
    uint32_t passed;
    uint32_t dropped;
    uint32_t mode_dropped;
    uint32_t police_dropped;
    uint32_t overrun_dropped;
    uint32_t mac_hits;             /* judged frames that hit a MAC / EtherType / tuple entry */
    uint32_t etype_hits;
    uint32_t acl_hits;
    uint32_t pol_seen[CPUPATH_CLS_POLICERS];
    uint32_t pol_passed[CPUPATH_CLS_POLICERS];
    uint32_t pol_dropped[CPUPATH_CLS_POLICERS];
} cpupath_cls_counters_t;

typedef struct {
    int      valid;                /* classifier state read from the hardware */
    unsigned mode;                 /* CTRL.MODE as the hardware reads it */
    uint32_t status;               /* STATUS */
    uint32_t delay_beats;          /* LATENCY */
    uint32_t verdict_latency;
    uint32_t table_entries;        /* CAPS */
    uint32_t tuple_entries;
    uint32_t num_rules;
    uint32_t num_policers;
    uint32_t match_depth_bytes;
} cpupath_cls_info_t;

typedef struct {
    int      valid;                /* wrapper CPU-path registers read */
    int      enabled;              /* CTRL.CPU_PATH_ENABLE */
    uint32_t rx_fifo_kb;           /* CPU_CAPS */
    uint32_t tx_fifo_kb;
    uint32_t delivered;            /* frames dequeued to the leaves (and the CPU copy) */
    uint32_t rx_frames;            /* unclaimed, committed to the CPU receive FIFO */
    uint32_t rx_claimed;           /* copies dropped: a leaf claimed the frame */
    uint32_t rx_fifo_drops;        /* unclaimed, lost: CPU receive FIFO full */
    uint32_t tx_frames;            /* CPU frames sent to the MAC */
    uint32_t tx_discarded;         /* CPU frames discarded while the path is off */
    uint32_t tx_rejected;          /* CPU frames with an illegal length or tkeep */
} cpupath_wrapper_counters_t;

void                        cpupath_config_defaults(void);
int                         cpupath_init(void);
int                         cpupath_cls_present(void);
int                         cpupath_cls_driver(void);
const cpupath_cls_config_t *cpupath_cls_config(void);
int                         cpupath_cls_defaults(void);
int                         cpupath_cls_set_mode(unsigned mode);
int                         cpupath_cls_set_policer(unsigned index, int enable, uint32_t limit, uint32_t window_ms);
int                         cpupath_cls_set_mac(unsigned entry, const cpupath_mac_entry_t *e);
int                         cpupath_cls_set_etype(unsigned entry, const cpupath_etype_entry_t *e);
int                         cpupath_cls_set_acl(unsigned entry, const cpupath_acl_entry_t *e);
int                         cpupath_cls_counters(cpupath_cls_counters_t *out);
int                         cpupath_cls_clear_counters(void);
int                         cpupath_cls_info(cpupath_cls_info_t *out);
int                         cpupath_storm_set(uint32_t limit, uint32_t window_ms);
int                         cpupath_storm_enable(int on);
int                         cpupath_wrapper_counters(cpupath_wrapper_counters_t *out);
const char                 *cpupath_mode_name(unsigned mode);
const char                 *cpupath_result_text(int rc);

#endif /* RTLNET_CPUPATH_H */
