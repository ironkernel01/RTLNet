/*
 * rtlnet_cpupath.c -- CPU network path control: CPU-path classifier and the
 *                     wrapper's CPU-path registers
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_cpupath.h for the contract. Context: main loop only.
 *
 * Every setter updates the configuration first and then re-applies the whole
 * classifier configuration (hw_sync): clear the tables, write every valid
 * entry, the policers and last the MODE, all through the classifier driver.
 * Writing MODE last means a half-written configuration never passes frames
 * it should not; the driver's own entry update protocol (disable table,
 * write, enable) covers the single-entry case.
 */
#include "rtlnet_cpupath.h"

#include <stddef.h>   /* NULL */

#include "rtlnet_board.h"
#include "rtlnet_eth_protocol.h"
#include "rtlnet_platform.h"

#if defined(__has_include)
#if __has_include("rtlnet_classifier.h")
#define RTLNET_HAVE_CLS_DRIVER 1
#include "rtlnet_classifier.h"
#endif
#endif
#ifndef RTLNET_HAVE_CLS_DRIVER
#define RTLNET_HAVE_CLS_DRIVER 0
#endif

static cpupath_cls_config_t g_cfg;
static int                  g_present;

#if RTLNET_HAVE_CLS_DRIVER
static rtlnet_classifier_t  g_cls;
#endif

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
        c->etype[i].valid = 0;
        c->acl[i].valid = 0;
    }
    for (unsigned i = 0; i < CPUPATH_CLS_POLICERS; i++) {
        c->pol[i].enabled = 0;
        c->pol[i].limit_pkts = 0u;
        c->pol[i].window_ms = 0u;
    }
    c->mode = CPUPATH_MODE_PASS_ALL;
    c->mac[CPUPATH_STORM_MAC_ENTRY].valid = 1;
    c->mac[CPUPATH_STORM_MAC_ENTRY].dst = 1;
    c->mac[CPUPATH_STORM_MAC_ENTRY].has_mask = 0;
    for (unsigned j = 0; j < 6u; j++) {
        c->mac[CPUPATH_STORM_MAC_ENTRY].mac[j] = 0xFFu;
        c->mac[CPUPATH_STORM_MAC_ENTRY].mask[j] = 0xFFu;
    }
    c->mac[CPUPATH_STORM_MAC_ENTRY].action = CPUPATH_ACT_POLICE;
    c->mac[CPUPATH_STORM_MAC_ENTRY].policer = CPUPATH_STORM_POLICER;
    c->pol[CPUPATH_STORM_POLICER].enabled = 1;
    c->pol[CPUPATH_STORM_POLICER].limit_pkts = CPUPATH_STORM_LIMIT_DEF;
    c->pol[CPUPATH_STORM_POLICER].window_ms = CPUPATH_STORM_WINDOW_DEF;
}

/*
 * hw_sync -- write the whole configuration into the classifier.
 * Returns: CPUPATH_OK, CPUPATH_ABSENT, CPUPATH_NO_DRIVER or CPUPATH_HW_ERROR.
 */
static int hw_sync(void)
{
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
#if RTLNET_HAVE_CLS_DRIVER
    {
        const cpupath_cls_config_t *c = &g_cfg;
        int rc = rtlnet_classifier_clear_all(&g_cls);
        for (unsigned i = 0; rc == 0 && i < CPUPATH_CLS_ENTRIES; i++) {
            if (c->mac[i].valid) {
                rc = rtlnet_classifier_mac_filter(&g_cls, i, c->mac[i].mac, c->mac[i].has_mask ? c->mac[i].mask : NULL,
                                                  c->mac[i].dst ? RTLNET_CLS_WHICH_DST : RTLNET_CLS_WHICH_SRC,
                                                  (c->mac[i].action == CPUPATH_ACT_GATE) ? RTLNET_CLS_ACTION_GATE :
                                                  (c->mac[i].action == CPUPATH_ACT_CLASSIFY) ? RTLNET_CLS_ACTION_CLASSIFY :
                                                  RTLNET_CLS_ACTION_POLICE(c->mac[i].policer));
            }
            if (rc == 0 && c->etype[i].valid) {
                rc = rtlnet_classifier_ethertype_filter(&g_cls, i, c->etype[i].lo, c->etype[i].hi,
                                                        (c->etype[i].action == CPUPATH_ACT_GATE) ? RTLNET_CLS_ACTION_GATE :
                                                        (c->etype[i].action == CPUPATH_ACT_CLASSIFY) ?
                                                        RTLNET_CLS_ACTION_CLASSIFY :
                                                        RTLNET_CLS_ACTION_POLICE(c->etype[i].policer));
            }
            if (rc == 0 && c->acl[i].valid) {
                const cpupath_acl_entry_t *a = &c->acl[i];
                rc = rtlnet_classifier_acl_add(&g_cls, i, a->proto, a->src, a->src_mask, a->dst, a->dst_mask,
                                               a->sport_lo, a->sport_hi, a->dport_lo, a->dport_hi,
                                               (a->action == CPUPATH_ACT_GATE) ? RTLNET_CLS_ACTION_GATE :
                                               (a->action == CPUPATH_ACT_CLASSIFY) ? RTLNET_CLS_ACTION_CLASSIFY :
                                               RTLNET_CLS_ACTION_POLICE(a->policer));
            }
        }
        for (unsigned p = 0; rc == 0 && p < CPUPATH_CLS_POLICERS; p++) {
            rc = rtlnet_classifier_policer_set(&g_cls, p, c->pol[p].enabled, c->pol[p].limit_pkts, c->pol[p].window_ms);
        }
        if (rc == 0) {
            rc = rtlnet_classifier_set_mode(&g_cls, c->mode);
        }
        return (rc == 0) ? CPUPATH_OK : CPUPATH_HW_ERROR;
    }
#else
    return CPUPATH_NO_DRIVER;
#endif
}

/*
 * cpupath_init -- probe the classifier and the wrapper CPU path, configure.
 * Steps:
 *   1. Classifier present when its ID reads "CLSF" at the protocol sub-map
 *      0x8000 (a CPU-only or older bitstream reads 0).
 *   2. With the driver: initialize it and write the configuration (the
 *      broadcast storm default unless the CLI changed it) - the classifier
 *      leaves DROP-ALL here.
 *   3. Enable the wrapper's CPU path when its driver offers the control.
 * Returns: CPUPATH_OK, CPUPATH_ABSENT, CPUPATH_NO_DRIVER or CPUPATH_HW_ERROR.
 */
int cpupath_init(void)
{
    board_probe_t p;
    g_present = board_probe(RTLNET_PLAT_CLS_BASE, RTLNET_ID_CLS, &p);
#if RTLNET_HAVE_CLS_DRIVER
    if (g_present && rtlnet_classifier_init(&g_cls, RTLNET_PLAT_CLS_BASE) != 0) {
        g_present = 0;
    }
#endif
#ifdef RTLNET_PROTO_CTRL_CPU_PATH_ENABLE
    if (rtlnet_eth_protocol_probe(RTLNET_PLAT_PROT_BASE) == RTLNET_PROTO_OK) {
        rtlnet_eth_protocol_set_cpu_path(RTLNET_PLAT_PROT_BASE, 1);
    }
#endif
    return hw_sync();
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
 * cpupath_cls_driver -- the classifier driver is part of this firmware.
 * Returns: 1 yes, 0 no.
 */
int cpupath_cls_driver(void)
{
    return RTLNET_HAVE_CLS_DRIVER;
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
 * cpupath_cls_set_policer -- one policer: enable, frames per window.
 * Returns: CPUPATH_BAD_ARG for an index out of range, else see hw_sync.
 */
int cpupath_cls_set_policer(unsigned index, int enable, uint32_t limit, uint32_t window_ms)
{
    if (index >= CPUPATH_CLS_POLICERS) {
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
    if (entry >= CPUPATH_CLS_ENTRIES || e->policer >= CPUPATH_CLS_POLICERS || (e->valid && e->hi < e->lo)) {
        return CPUPATH_BAD_ARG;
    }
    g_cfg.etype[entry] = *e;
    return hw_sync();
}

/*
 * cpupath_cls_set_acl -- set or clear one tuple (ACL) entry.
 * Returns: CPUPATH_BAD_ARG for an entry, port range or policer out of range,
 *          else see hw_sync.
 */
int cpupath_cls_set_acl(unsigned entry, const cpupath_acl_entry_t *e)
{
    if (entry >= CPUPATH_CLS_ENTRIES || e->policer >= CPUPATH_CLS_POLICERS ||
        (e->valid && (e->sport_hi < e->sport_lo || e->dport_hi < e->dport_lo))) {
        return CPUPATH_BAD_ARG;
    }
    g_cfg.acl[entry] = *e;
    return hw_sync();
}

/*
 * cpupath_cls_counters -- classifier and policer counters.
 * Returns: CPUPATH_OK (*out valid), CPUPATH_ABSENT or CPUPATH_NO_DRIVER
 *          (*out zero, valid 0).
 */
int cpupath_cls_counters(cpupath_cls_counters_t *out)
{
    *out = (cpupath_cls_counters_t){ 0 };
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
#if RTLNET_HAVE_CLS_DRIVER
    {
        rtlnet_cls_counters_t k;
        if (rtlnet_classifier_counters(&g_cls, &k) != 0) {
            return CPUPATH_HW_ERROR;
        }
        out->valid = 1;
        out->frames = k.frames;
        out->passed = k.passed;
        out->dropped = k.dropped;
        out->mode_dropped = k.mode_dropped;
        out->police_dropped = k.police_dropped;
        for (unsigned p = 0; p < CPUPATH_CLS_POLICERS; p++) {
            out->pol_seen[p] = k.policer_seen[p];
            out->pol_passed[p] = k.policer_passed[p];
            out->pol_dropped[p] = k.policer_dropped[p];
        }
        return CPUPATH_OK;
    }
#else
    return CPUPATH_NO_DRIVER;
#endif
}

/*
 * cpupath_cls_clear_counters -- CNT_CLEAR of the classifier.
 * Returns: CPUPATH_OK, CPUPATH_ABSENT or CPUPATH_NO_DRIVER.
 */
int cpupath_cls_clear_counters(void)
{
    if (!g_present) {
        return CPUPATH_ABSENT;
    }
#if RTLNET_HAVE_CLS_DRIVER
    return (rtlnet_classifier_clear_counters(&g_cls) == 0) ? CPUPATH_OK : CPUPATH_HW_ERROR;
#else
    return CPUPATH_NO_DRIVER;
#endif
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
    m->has_mask = 0;
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
 * passes every broadcast).
 * Returns: see hw_sync.
 */
int cpupath_storm_enable(int on)
{
    g_cfg.pol[CPUPATH_STORM_POLICER].enabled = on ? 1 : 0;
    return hw_sync();
}

/*
 * cpupath_wrapper_counters -- the protocol wrapper's CPU-path counters.
 * Returns: CPUPATH_OK (*out valid), CPUPATH_ABSENT (no protocol core) or
 *          CPUPATH_NO_DRIVER (the wrapper driver has no CPU-path registers).
 */
int cpupath_wrapper_counters(cpupath_wrapper_counters_t *out)
{
    *out = (cpupath_wrapper_counters_t){ 0 };
    if (rtlnet_eth_protocol_probe(RTLNET_PLAT_PROT_BASE) != RTLNET_PROTO_OK) {
        return CPUPATH_ABSENT;
    }
#ifdef RTLNET_PROTO_CTRL_CPU_PATH_ENABLE
    {
        rtlnet_eth_protocol_cpu_counters_t k;
        rtlnet_eth_protocol_read_cpu_counters(RTLNET_PLAT_PROT_BASE, &k);
        out->valid = 1;
        out->enabled = rtlnet_eth_protocol_get_cpu_path(RTLNET_PLAT_PROT_BASE);
        out->rx_frames = k.rx_frames;
        out->rx_fifo_drops = k.rx_dropped;
        out->tx_frames = k.tx_frames;
        return CPUPATH_OK;
    }
#else
    return CPUPATH_NO_DRIVER;
#endif
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
    case CPUPATH_NO_DRIVER: return "classifier driver not in this firmware build; setting kept in the running configuration";
    case CPUPATH_BAD_ARG:   return "invalid argument";
    default:                return "classifier driver error";
    }
}
