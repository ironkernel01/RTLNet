/*
 * rtlnet_cpupath.c -- CPU network path control: CPU-path classifier and the
 *                     wrapper's CPU-path registers
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_cpupath.h for the contract. Context: main loop only.
 *
 * Every setter updates the configuration first and then re-applies the whole
 * classifier configuration (hw_sync): clear the tables, write the base (the
 * protection profile or the storm limiter), every valid entry, the policers
 * and last the MODE (or the firewall, which ends with MODE), all through the
 * classifier driver (cores/rtlnet_classifier/driver). Writing MODE last means
 * a half-written configuration never passes frames it should not. clear_all
 * leaves the filter in drop-all for the duration of the rewrite (about 100 us).
 * This is the only driver context of the classifier in the firmware.
 */
#include "rtlnet_cpupath.h"

#include <stddef.h>   /* NULL */

#include "rtlnet_board.h"
#include "rtlnet_classifier.h"
#include "rtlnet_eth_protocol.h"
#include "rtlnet_firewall.h"
#include "rtlnet_offload.h"
#include "rtlnet_platform.h"

static cpupath_cls_config_t g_cfg;
static int                  g_present;
static rtlnet_classifier_t  g_cls;
static const rtlnet_cls_protect_t *g_profile;   /* base profile (rtlnet_protect.c), NULL = storm limiter */
static rtlnet_cls_tuple_t   g_allow[CPUPATH_CLS_ENTRIES];   /* scratch: the composed allow list */

/*
 * cpupath_config_defaults -- the broadcast storm configuration as the
 * firmware default: pass-all, MAC entry 0 destination broadcast policed by
 * policer 0, policer 0 = 10 frames per 100 ms.
 * Returns: nothing (configuration only, no hardware access).
 */
void cpupath_config_defaults(void)
{
    cpupath_cls_config_t *c = &g_cfg;
    for (unsigned i = 0; i < CPUPATH_CLS_ENTRIES; i++) {
        c->mac[i].valid = 0;
        c->acl[i].valid = 0;
    }
    for (unsigned i = 0; i < CPUPATH_CLS_PAIRS; i++) {
        c->etype[i].valid = 0;
    }
    for (unsigned i = 0; i < CPUPATH_CLS_POLICERS; i++) {
        c->pol[i].enabled = 0;
        c->pol[i].limit_pkts = 0u;
        c->pol[i].window_ms = 0u;
    }
    c->mode = CPUPATH_MODE_PASS_ALL;
    c->mac[CPUPATH_STORM_MAC_ENTRY].valid = 1;
    c->mac[CPUPATH_STORM_MAC_ENTRY].dst = 1;
    for (unsigned j = 0; j < 6u; j++) {
        c->mac[CPUPATH_STORM_MAC_ENTRY].mac[j] = 0xFFu;
    }
    c->mac[CPUPATH_STORM_MAC_ENTRY].action = CPUPATH_ACT_POLICE;
    c->mac[CPUPATH_STORM_MAC_ENTRY].policer = CPUPATH_STORM_POLICER;
    c->pol[CPUPATH_STORM_POLICER].enabled = 1;
    c->pol[CPUPATH_STORM_POLICER].limit_pkts = CPUPATH_STORM_LIMIT_DEF;
    c->pol[CPUPATH_STORM_POLICER].window_ms = CPUPATH_STORM_WINDOW_DEF;
}

/*
 * helper_action -- driver helper action word of a CLI entry action.
 * Returns: RTLNET_CLS_ACT_GATE, RTLNET_CLS_ACT_CLASSIFY or
 *          RTLNET_CLS_ACT_CLASSIFY | RTLNET_CLS_ACT_POLICE(policer).
 */
static uint32_t helper_action(unsigned action, unsigned policer)
{
    if (action == CPUPATH_ACT_GATE) {
        return RTLNET_CLS_ACT_GATE;
    }
    if (action == CPUPATH_ACT_CLASSIFY) {
        return RTLNET_CLS_ACT_CLASSIFY;
    }
    return RTLNET_CLS_ACT_CLASSIFY | RTLNET_CLS_ACT_POLICE(policer);
}

/*
 * table_classify_only -- a table is classify-only when none of its valid
 * entries has the action gate.
 * Returns: 1 classify-only, 0 gating.
 */
static int table_classify_only(const unsigned *actions, const int *valid, unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        if (valid[i] && actions[i] == CPUPATH_ACT_GATE) {
            return 0;
        }
    }
    return 1;
}

/*
 * settle_table -- give a table that holds entries its final TABLE_MODE: the
 * helpers set CLASSIFY from the last entry written, the configuration decides
 * it from all entries of the table (gating when any entry gates).
 * Returns: RTLNET_CLS_OK or the driver's error code.
 */
static int settle_table(rtlnet_cls_table_t table, int any_valid, int classify_only)
{
    rtlnet_cls_table_mode_t m;
    int rc;
    if (!any_valid) {
        return RTLNET_CLS_OK;
    }
    rc = rtlnet_classifier_get_table_mode(&g_cls, table, &m);
    if (rc != RTLNET_CLS_OK) {
        return rc;
    }
    return rtlnet_classifier_table_mode(&g_cls, table, 1, m.exclude, (rtlnet_cls_compare_t)m.compare, classify_only,
                                        m.vlan_aware);
}

/*
 * base_slots -- tuple slots the base uses (the protection profile: ICMP and UDP).
 * Returns: 2 with the profile, 0 with the storm limiter.
 */
static unsigned base_slots(void)
{
    return (g_profile != NULL) ? (unsigned)RTLNET_CLS_PROT_MIN_TUPLES : 0u;
}

/*
 * hw_sync -- write the whole configuration into the classifier.
 * Steps:
 *   1. clear_all (tables, rules, policers disabled, MODE drop-all).
 *   2. Base: the protection profile (rtlnet_classifier_protect_load with the current limits: everything
 *      config_protect writes except MODE) when it is installed, else nothing (the storm limiter is MAC entry 0
 *      and policer 0 below). MODE stays drop-all from clear_all and is written only at the very end, so no
 *      pass-all write happens before the last write.
 *   3. The MAC entries (entry 0 stays the storm / broadcast entry); the MAC table gets its final mode.
 *   4. The policers from the configuration, except while the profile is installed: its limits (written in
 *      step 2) own policers 0..3.
 *   5. Firewall on: rtlnet_classifier_firewall_apply with the composed allow list (ARP pair 0; the EtherType
 *      entries of the configuration are not applied); it ends with MODE drop-on-match.
 *      Firewall off: the EtherType entries, the ACL entries (user entry i in tuple slot base_slots + i),
 *      the final modes of both tables, and last the MODE of the configuration.
 * cpupath_cls_set_acl refuses an entry with no slot behind the base's slots in both firewall states, so an
 * entry past the table is only possible when the build shrank after it was accepted; the loop then skips it
 * (the defensive bound), and hw_sync never fails for acl space.
 * Returns: CPUPATH_OK, CPUPATH_ABSENT, CPUPATH_TOO_SMALL or CPUPATH_HW_ERROR.
 */
static int hw_sync(void)
{
    const cpupath_cls_config_t *c = &g_cfg;
    unsigned act[CPUPATH_CLS_ENTRIES];
    int      val[CPUPATH_CLS_ENTRIES];
    int      any_mac = 0;
    int      any_etype = 0;
    int      any_acl = 0;
    int      fw_on = fw_enabled();
    int      rc;

    if (!g_present) {
        return CPUPATH_ABSENT;
    }
    rc = rtlnet_classifier_clear_all(&g_cls);
    if (rc == RTLNET_CLS_OK && g_profile != NULL) {
        rc = rtlnet_classifier_protect_load(&g_cls, g_profile);
        if (rc == RTLNET_CLS_ERR_RANGE) {
            return CPUPATH_TOO_SMALL;
        }
    }
    for (unsigned i = 0; rc == RTLNET_CLS_OK && i < CPUPATH_CLS_ENTRIES; i++) {
        if (c->mac[i].valid) {
            any_mac = 1;
            rc = rtlnet_classifier_mac_filter(&g_cls, i, c->mac[i].mac,
                                              c->mac[i].dst ? RTLNET_CLS_SIDE_DST : RTLNET_CLS_SIDE_SRC,
                                              helper_action(c->mac[i].action, c->mac[i].policer));
        }
    }
    for (unsigned i = 0; i < CPUPATH_CLS_ENTRIES; i++) {
        act[i] = c->mac[i].action;
        val[i] = c->mac[i].valid;
    }
    if (rc == RTLNET_CLS_OK) {
        rc = settle_table(RTLNET_CLS_TABLE_MAC, any_mac, table_classify_only(act, val, CPUPATH_CLS_ENTRIES));
    }
    for (unsigned p = 0; g_profile == NULL && rc == RTLNET_CLS_OK && p < CPUPATH_CLS_POLICERS; p++) {
        rc = rtlnet_classifier_policer_set(&g_cls, p, c->pol[p].enabled, c->pol[p].limit_pkts, c->pol[p].window_ms);
    }
    if (rc == RTLNET_CLS_OK && fw_on) {
        rtlnet_cls_firewall_t fw;
        unsigned needed;
        fw.count = fw_compose(g_allow, g_cls.tuple_entries, &needed);
        fw.allow = g_allow;
        fw.etype_pair = 0u;
        rc = rtlnet_classifier_firewall_apply(&g_cls, &fw);
        return (rc == RTLNET_CLS_OK) ? CPUPATH_OK : CPUPATH_HW_ERROR;
    }
    fw_shadow_clear();
    for (unsigned i = 0; rc == RTLNET_CLS_OK && i < CPUPATH_CLS_PAIRS; i++) {
        if (c->etype[i].valid) {
            any_etype = 1;
            rc = rtlnet_classifier_ethertype_filter(&g_cls, i, c->etype[i].lo, c->etype[i].hi,
                                                    helper_action(c->etype[i].action, c->etype[i].policer));
        }
    }
    for (unsigned i = 0; rc == RTLNET_CLS_OK && i < CPUPATH_CLS_ENTRIES; i++) {
        const cpupath_acl_entry_t *a = &c->acl[i];
        if (a->valid && base_slots() + i < g_cls.tuple_entries) {
            any_acl = 1;
            rc = rtlnet_classifier_acl_add(&g_cls, base_slots() + i, a->proto, a->src, a->src_mask, a->dst,
                                           a->dst_mask, a->sport_lo, a->sport_hi, a->dport_lo, a->dport_hi,
                                           helper_action(a->action, a->policer));
        }
    }
    for (unsigned i = 0; i < CPUPATH_CLS_PAIRS; i++) {
        act[i] = c->etype[i].action;
        val[i] = c->etype[i].valid;
    }
    if (rc == RTLNET_CLS_OK) {
        rc = settle_table(RTLNET_CLS_TABLE_ETHERTYPE, any_etype, table_classify_only(act, val, CPUPATH_CLS_PAIRS));
    }
    for (unsigned i = 0; i < CPUPATH_CLS_ENTRIES; i++) {
        act[i] = c->acl[i].action;
        val[i] = c->acl[i].valid;
    }
    if (rc == RTLNET_CLS_OK) {
        rc = settle_table(RTLNET_CLS_TABLE_TUPLE, any_acl, table_classify_only(act, val, CPUPATH_CLS_ENTRIES));
    }
    if (rc == RTLNET_CLS_OK) {
        rc = rtlnet_classifier_set_mode(&g_cls, (rtlnet_cls_mode_t)c->mode);
    }
    return (rc == RTLNET_CLS_OK) ? CPUPATH_OK : CPUPATH_HW_ERROR;
}

/*
 * cpupath_init -- probe the classifier and the wrapper CPU path, configure.
 * Steps:
 *   1. Classifier present when the feature discovery (rtlnet_features_discover:
 *      wrapper CPU_CAPS bit 16 and the block's own ID "CLSF" and VERSION at the
 *      protocol sub-map 0x8000) found it; a CPU-only or older bitstream does
 *      not advertise it. Then rtlnet_classifier_init.
 *   2. The broadcast storm default through
 *      rtlnet_classifier_config_bcast_storm (the classifier leaves
 *      DROP-ALL); when the running configuration differs from the default
 *      (a CLI change before this call) the whole configuration is written
 *      instead.
 *   3. Enable the wrapper's CPU path when it is built (CAPS).
 * Returns: CPUPATH_OK, CPUPATH_ABSENT or CPUPATH_HW_ERROR.
 */
int cpupath_init(void)
{
    int rc = CPUPATH_ABSENT;
    g_profile = NULL;
    rtlnet_features_discover();
    g_present = rtlnet_features()->cls_present;
    if (g_present && rtlnet_classifier_init(&g_cls, RTLNET_PLAT_CLS_BASE) != RTLNET_CLS_OK) {
        g_present = 0;
    }
    if (g_present) {
        const cpupath_policer_t *sp = &g_cfg.pol[CPUPATH_STORM_POLICER];
        if (g_cfg.mode == CPUPATH_MODE_PASS_ALL && sp->enabled && !fw_enabled() &&
            rtlnet_classifier_config_bcast_storm(&g_cls, sp->limit_pkts, sp->window_ms) == RTLNET_CLS_OK) {
            rc = CPUPATH_OK;
        } else {
            rc = hw_sync();
        }
    }
    if (rtlnet_eth_protocol_probe(RTLNET_PLAT_PROT_BASE) == RTLNET_PROTO_OK &&
        rtlnet_eth_protocol_cpu_path_present(RTLNET_PLAT_PROT_BASE)) {
        (void)rtlnet_eth_protocol_set_cpu_path_enable(RTLNET_PLAT_PROT_BASE, 1);
    }
    return rc;
}

/*
 * cpupath_cls_present -- the classifier answered its ID at start-up.
 * Returns: 1 present, 0 absent.
 */
int cpupath_cls_present(void)
{
    return g_present;
}

/*
 * cpupath_cls_config -- the classifier configuration (running configuration).
 * Returns: pointer to it.
 */
const cpupath_cls_config_t *cpupath_cls_config(void)
{
    return &g_cfg;
}

/*
 * cpupath_cls_defaults -- back to the broadcast storm default and apply.
 * Returns: see hw_sync.
 */
int cpupath_cls_defaults(void)
{
    cpupath_config_defaults();
    return hw_sync();
}

/*
 * cpupath_cls_set_mode -- global MODE.
 * Returns: CPUPATH_BAD_ARG for a mode above 3, else see hw_sync.
 */
int cpupath_cls_set_mode(unsigned mode)
{
    if (mode > CPUPATH_MODE_DROP_ON_MATCH) {
        return CPUPATH_BAD_ARG;
    }
    g_cfg.mode = mode;
    return hw_sync();
}

/*
 * cpupath_cls_set_policer -- one policer: enable, frames per window. While the protection profile is
 * installed its limits own the four policers (change them with protect_set): this setter is refused then.
 * Returns: CPUPATH_BAD_ARG for an index out of range or while the profile is installed, else see hw_sync.
 */
int cpupath_cls_set_policer(unsigned index, int enable, uint32_t limit, uint32_t window_ms)
{
    if (index >= CPUPATH_CLS_POLICERS || g_profile != NULL) {
        return CPUPATH_BAD_ARG;
    }
    g_cfg.pol[index].enabled = enable ? 1 : 0;
    g_cfg.pol[index].limit_pkts = limit;
    g_cfg.pol[index].window_ms = window_ms;
    return hw_sync();
}

/*
 * cpupath_cls_set_mac -- set (valid) or clear (!valid) one MAC-table entry.
 * Returns: CPUPATH_BAD_ARG for an entry or policer out of range, else see
 *          hw_sync.
 */
int cpupath_cls_set_mac(unsigned entry, const cpupath_mac_entry_t *e)
{
    if (entry >= CPUPATH_CLS_ENTRIES || e->policer >= CPUPATH_CLS_POLICERS) {
        return CPUPATH_BAD_ARG;
    }
    g_cfg.mac[entry] = *e;
    return hw_sync();
}

/*
 * cpupath_cls_set_etype -- set or clear one EtherType-table entry.
 * Returns: CPUPATH_BAD_ARG for an entry, range or policer out of range, else
 *          see hw_sync.
 */
int cpupath_cls_set_etype(unsigned entry, const cpupath_etype_entry_t *e)
{
    if (entry >= CPUPATH_CLS_PAIRS || e->policer >= CPUPATH_CLS_POLICERS || (e->valid && e->hi < e->lo)) {
        return CPUPATH_BAD_ARG;
    }
    g_cfg.etype[entry] = *e;
    return hw_sync();
}

/*
 * cpupath_cls_set_acl -- set or clear one tuple (ACL) entry.
 * Entry i has the tuple slot base_slots + i (the protection profile holds slots 0 and 1) with the firewall off;
 * the same limit is applied with it on, so the firewall can always be turned off: an entry past the table is
 * refused in both states with nothing changed. With the firewall on, the entries are packed into the allow
 * list and the change is applied live (see rtlnet_firewall.h); an entry that does not fit stays out.
 * Returns: CPUPATH_BAD_ARG for an entry, port range or policer out of range, CPUPATH_NO_SPACE for an entry
 *          without a slot, else see hw_sync.
 */
int cpupath_cls_set_acl(unsigned entry, const cpupath_acl_entry_t *e)
{
    if (entry >= CPUPATH_CLS_ENTRIES || e->policer >= CPUPATH_CLS_POLICERS ||
        (e->valid && (e->sport_hi < e->sport_lo || e->dport_hi < e->dport_lo))) {
        return CPUPATH_BAD_ARG;
    }
    if (e->valid && g_present && base_slots() + entry >= g_cls.tuple_entries) {
        return CPUPATH_NO_SPACE;
    }
    g_cfg.acl[entry] = *e;
    if (g_present && fw_enabled()) {
        return (fw_live_refresh() == FW_OK) ? CPUPATH_OK : CPUPATH_HW_ERROR;
    }
    return hw_sync();
}

/*
 * cpupath_cls_counters -- classifier and policer counters.
 * Returns: CPUPATH_OK (*out valid), CPUPATH_ABSENT (*out zero, valid 0) or
 *          CPUPATH_HW_ERROR.
 */
int cpupath_cls_counters(cpupath_cls_counters_t *out)
{
    rtlnet_cls_counters_t k;
    *out = (cpupath_cls_counters_t){ 0 };
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
    if (rtlnet_classifier_counters(&g_cls, &k) != RTLNET_CLS_OK) {
        return CPUPATH_HW_ERROR;
    }
    out->frames = k.frames;
    out->passed = k.passed;
    out->dropped = k.dropped;
    out->mode_dropped = k.mode_dropped;
    out->police_dropped = k.police_dropped;
    out->overrun_dropped = k.overrun_dropped;
    out->mac_hits = k.table_hit[RTLNET_CLS_TABLE_MAC];
    out->etype_hits = k.table_hit[RTLNET_CLS_TABLE_ETHERTYPE];
    out->acl_hits = k.table_hit[RTLNET_CLS_TABLE_TUPLE];
    for (unsigned p = 0; p < CPUPATH_CLS_POLICERS; p++) {
        rtlnet_cls_policer_t ps;
        if (rtlnet_classifier_policer_get(&g_cls, p, &ps) != RTLNET_CLS_OK) {
            return CPUPATH_HW_ERROR;
        }
        out->pol_seen[p] = ps.seen;
        out->pol_passed[p] = ps.passed;
        out->pol_dropped[p] = ps.dropped;
    }
    out->valid = 1;
    return CPUPATH_OK;
}

/*
 * cpupath_cls_clear_counters -- CNT_CLEAR of the classifier.
 * Returns: CPUPATH_OK, CPUPATH_ABSENT or CPUPATH_HW_ERROR.
 */
int cpupath_cls_clear_counters(void)
{
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
    return (rtlnet_classifier_clear_counters(&g_cls) == RTLNET_CLS_OK) ? CPUPATH_OK : CPUPATH_HW_ERROR;
}

/*
 * cpupath_cls_info -- hardware state read back: MODE, STATUS, build
 * parameters (CAPS) and latency.
 * Returns: CPUPATH_OK (*out valid), CPUPATH_ABSENT or CPUPATH_HW_ERROR.
 */
int cpupath_cls_info(cpupath_cls_info_t *out)
{
    rtlnet_cls_mode_t m;
    *out = (cpupath_cls_info_t){ 0 };
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
    if (rtlnet_classifier_get_mode(&g_cls, &m) != RTLNET_CLS_OK ||
        rtlnet_classifier_get_status(&g_cls, &out->status) != RTLNET_CLS_OK) {
        return CPUPATH_HW_ERROR;
    }
    out->mode = (unsigned)m;
    out->delay_beats = g_cls.delay_beats;
    out->verdict_latency = g_cls.verdict_latency;
    out->table_entries = g_cls.table_entries;
    out->tuple_entries = g_cls.tuple_entries;
    out->num_rules = g_cls.num_rules;
    out->num_policers = g_cls.num_policers;
    out->match_depth_bytes = g_cls.match_depth_bytes;
    out->valid = 1;
    return CPUPATH_OK;
}

/*
 * cpupath_storm_set -- storm-control broadcast <packets> <milliseconds>:
 * policer 0 limit and window, enabled, MAC entry 0 the broadcast policing
 * entry again.
 * Returns: see hw_sync; CPUPATH_BAD_ARG for a zero window.
 */
int cpupath_storm_set(uint32_t limit, uint32_t window_ms)
{
    cpupath_mac_entry_t *m = &g_cfg.mac[CPUPATH_STORM_MAC_ENTRY];
    if (window_ms == 0u) {
        return CPUPATH_BAD_ARG;
    }
    m->valid = 1;
    m->dst = 1;
    for (unsigned j = 0; j < 6u; j++) {
        m->mac[j] = 0xFFu;
    }
    m->action = CPUPATH_ACT_POLICE;
    m->policer = CPUPATH_STORM_POLICER;
    g_cfg.pol[CPUPATH_STORM_POLICER].enabled = 1;
    g_cfg.pol[CPUPATH_STORM_POLICER].limit_pkts = limit;
    g_cfg.pol[CPUPATH_STORM_POLICER].window_ms = window_ms;
    return hw_sync();
}

/*
 * cpupath_storm_enable -- enable or disable policer 0 (a disabled policer
 * passes every broadcast); limit and window stay.
 * Returns: CPUPATH_OK, CPUPATH_ABSENT or CPUPATH_HW_ERROR.
 */
int cpupath_storm_enable(int on)
{
    g_cfg.pol[CPUPATH_STORM_POLICER].enabled = on ? 1 : 0;
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
    return (rtlnet_classifier_bcast_storm_enable(&g_cls, on) == RTLNET_CLS_OK) ? CPUPATH_OK : CPUPATH_HW_ERROR;
}

/*
 * cpupath_wrapper_counters -- the protocol wrapper's CPU-path counters.
 * Returns: CPUPATH_OK (*out valid), CPUPATH_ABSENT (no protocol core) or
 *          CPUPATH_NO_DRIVER (a wrapper built without the CPU path).
 */
int cpupath_wrapper_counters(cpupath_wrapper_counters_t *out)
{
    rtlnet_eth_protocol_cpu_counters_t k;
    *out = (cpupath_wrapper_counters_t){ 0 };
    if (rtlnet_eth_protocol_probe(RTLNET_PLAT_PROT_BASE) != RTLNET_PROTO_OK) {
        return CPUPATH_ABSENT;
    }
    if (!rtlnet_eth_protocol_cpu_path_present(RTLNET_PLAT_PROT_BASE)) {
        return CPUPATH_NO_DRIVER;
    }
    rtlnet_eth_protocol_read_cpu_counters(RTLNET_PLAT_PROT_BASE, &k);
    out->valid = 1;
    out->enabled = rtlnet_eth_protocol_get_cpu_path_enable(RTLNET_PLAT_PROT_BASE);
    out->rx_fifo_kb = rtlnet_eth_protocol_get_cpu_rx_fifo_kb(RTLNET_PLAT_PROT_BASE);
    out->tx_fifo_kb = rtlnet_eth_protocol_get_cpu_tx_fifo_kb(RTLNET_PLAT_PROT_BASE);
    out->delivered = k.delivered_frames;
    out->rx_frames = k.cpu_rx_frames;
    out->rx_claimed = k.cpu_rx_claimed;
    out->rx_fifo_drops = k.cpu_rx_dropped;
    out->tx_frames = k.cpu_tx_frames;
    out->tx_discarded = k.cpu_tx_discarded;
    out->tx_rejected = k.cpu_tx_rejected;
    return CPUPATH_OK;
}

/*
 * cpupath_base_profile -- install (or, with NULL, remove) the protection profile as the base of the whole
 * state: re-read the build, then rewrite everything (hw_sync). The profile is held by pointer, so a limit
 * changed in its owner (rtlnet_protect.c) is what the next rewrite writes.
 * Returns: CPUPATH_OK, CPUPATH_ABSENT, CPUPATH_TOO_SMALL (the build cannot hold it: the storm limiter stays
 *          the base), CPUPATH_NO_SPACE or CPUPATH_HW_ERROR.
 */
int cpupath_base_profile(const rtlnet_cls_protect_t *profile)
{
    int rc;
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
    if (rtlnet_classifier_init(&g_cls, RTLNET_PLAT_CLS_BASE) != RTLNET_CLS_OK) {
        return CPUPATH_HW_ERROR;
    }
    if (profile != NULL && (g_cls.table_entries < RTLNET_CLS_PROT_MIN_TABLE_ENTRIES ||
                            g_cls.tuple_entries < RTLNET_CLS_PROT_MIN_TUPLES ||
                            g_cls.num_rules < RTLNET_CLS_PROT_MIN_RULES ||
                            g_cls.num_policers < RTLNET_CLS_PROT_MIN_POLICERS ||
                            g_cls.match_depth_bytes < RTLNET_CLS_PROT_MIN_MATCH_BYTES)) {
        g_profile = NULL;
        (void)hw_sync();
        return CPUPATH_TOO_SMALL;
    }
    g_profile = profile;
    rc = hw_sync();
    if (rc != CPUPATH_OK && profile != NULL) {
        g_profile = NULL;
    }
    return rc;
}

/*
 * cpupath_cls_ctx -- the classifier driver context (the only one), for the read side and the one-register
 * policer write of rtlnet_protect.c.
 * Returns: the context, NULL when the classifier is absent.
 */
const rtlnet_classifier_t *cpupath_cls_ctx(void)
{
    return g_present ? &g_cls : NULL;
}

/*
 * cpupath_cls_reinit -- read the build parameters again (ID, CAPS, LATENCY).
 * Returns: CPUPATH_OK, CPUPATH_ABSENT or CPUPATH_HW_ERROR.
 */
int cpupath_cls_reinit(void)
{
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
    return (rtlnet_classifier_init(&g_cls, RTLNET_PLAT_CLS_BASE) == RTLNET_CLS_OK) ? CPUPATH_OK : CPUPATH_HW_ERROR;
}

/*
 * cpupath_sync -- rewrite the whole classifier state from the configuration (hw_sync) for the firewall.
 * Returns: see hw_sync.
 */
int cpupath_sync(void)
{
    return hw_sync();
}

/*
 * cpupath_fw_slots -- tuple slots of the built classifier.
 * Returns: the count, 0 when the classifier is absent.
 */
unsigned cpupath_fw_slots(void)
{
    return g_present ? g_cls.tuple_entries : 0u;
}

/*
 * cpupath_fw_arp_ok -- the build has an EtherType range pair for the firewall's ARP entry.
 * Returns: 1 yes, 0 no.
 */
int cpupath_fw_arp_ok(void)
{
    return (g_present && g_cls.table_entries >= 2u) ? 1 : 0;
}

/*
 * cpupath_fw_live_set -- one allow entry into a free tuple slot, the tuple table stays enabled.
 * Returns: CPUPATH_OK, CPUPATH_ABSENT, CPUPATH_HW_ERROR.
 */
int cpupath_fw_live_set(unsigned slot, const rtlnet_cls_tuple_t *tuple)
{
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
    return (rtlnet_classifier_tuple_live_set(&g_cls, slot, tuple) == RTLNET_CLS_OK) ? CPUPATH_OK : CPUPATH_HW_ERROR;
}

/*
 * cpupath_fw_live_clear -- remove one allow entry, the tuple table stays enabled.
 * Returns: CPUPATH_OK, CPUPATH_ABSENT, CPUPATH_HW_ERROR.
 */
int cpupath_fw_live_clear(unsigned slot)
{
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
    return (rtlnet_classifier_tuple_live_clear(&g_cls, slot) == RTLNET_CLS_OK) ? CPUPATH_OK : CPUPATH_HW_ERROR;
}

/*
 * cpupath_mode_name -- CLI spelling of a MODE.
 * Returns: the name.
 */
const char *cpupath_mode_name(unsigned mode)
{
    static const char *const names[4] = { "drop-all", "pass-all", "pass-on-match", "drop-on-match" };
    return (mode < 4u) ? names[mode] : "?";
}

/*
 * cpupath_result_text -- explanation of a CPUPATH_* result for the console.
 * Returns: the text.
 */
const char *cpupath_result_text(int rc)
{
    switch (rc) {
    case CPUPATH_OK:        return "applied";
    case CPUPATH_ABSENT:    return "classifier not present in this build; setting kept in the running configuration";
    case CPUPATH_NO_DRIVER: return "protocol core built without the CPU network path";
    case CPUPATH_BAD_ARG:   return "invalid argument";
    case CPUPATH_TOO_SMALL: return "this classifier build cannot hold the protection profile";
    case CPUPATH_NO_SPACE:  return "no tuple slot for this entry (the protection profile uses the first two slots)";
    default:                return "classifier driver error";
    }
}
