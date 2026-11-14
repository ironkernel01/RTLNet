/*
 * rtlnet_protect.c -- CPU-path protection profile (four policed traffic classes)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_protect.h for the contract. Context: main loop only. The profile
 * lives in the classifier hardware (rule 0, tuples 0 and 1, MAC entry 0, the
 * four policers); this file keeps the limits and windows the CLI changes and
 * applies them through the classifier driver, using its own driver context
 * for the same registers as rtlnet_cpupath.c.
 */
#include "rtlnet_protect.h"

#include <stddef.h>   /* NULL */

#include "rtlnet_classifier.h"
#include "rtlnet_cpupath.h"
#include "rtlnet_platform.h"

static rtlnet_classifier_t g_cls;
static rtlnet_cls_protect_t g_profile;
static int                  g_profile_ready;
static int                  g_installed;

/*
 * lower -- ASCII lower case of one character.
 * Returns: the character, lower case when it is a capital letter.
 */
static char lower(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

/*
 * ensure_profile -- fill the configuration with the driver defaults once.
 */
static void ensure_profile(void)
{
    if (!g_profile_ready) {
        protect_config_defaults();
    }
}

/*
 * protect_config_defaults -- the default limits (driver RTLNET_CLS_PROT_*_DEFAULT: broadcast 10, udp 10,
 * arp 20, icmp 10 frames per 100 ms); no hardware access.
 */
void protect_config_defaults(void)
{
    rtlnet_classifier_protect_defaults(&g_profile);
    g_profile_ready = 1;
}

/*
 * map_rc -- classifier driver result to a PROTECT_* result.
 * Returns: PROTECT_OK, PROTECT_TOO_SMALL (index or size past the build), PROTECT_BAD_ARG, PROTECT_HW_ERROR.
 */
static int map_rc(int rc)
{
    switch (rc) {
    case RTLNET_CLS_OK:        return PROTECT_OK;
    case RTLNET_CLS_ERR_RANGE: return PROTECT_TOO_SMALL;
    case RTLNET_CLS_ERR_ARG:   return PROTECT_BAD_ARG;
    default:                   return PROTECT_HW_ERROR;
    }
}

/*
 * protect_install -- probe the classifier and install the profile.
 * Steps:
 *   1. The classifier must have been found by cpupath_init (feature discovery).
 *   2. rtlnet_classifier_init, then rtlnet_classifier_config_protect with the
 *      configured limits: clear, rule, tuples, MAC entry, policers, MODE
 *      pass-all last.
 * A classifier too small for the profile is left as it is (the broadcast
 * storm limiter of cpupath_init).
 * Returns: PROTECT_OK, PROTECT_ABSENT, PROTECT_TOO_SMALL or PROTECT_HW_ERROR.
 */
int protect_install(void)
{
    int rc;

    ensure_profile();
    g_installed = 0;
    if (!cpupath_cls_present()) {
        return PROTECT_ABSENT;
    }
    if (rtlnet_classifier_init(&g_cls, RTLNET_PLAT_CLS_BASE) != RTLNET_CLS_OK) {
        return PROTECT_HW_ERROR;
    }
    rc = map_rc(rtlnet_classifier_config_protect(&g_cls, &g_profile));
    g_installed = (rc == PROTECT_OK) ? 1 : 0;
    return rc;
}

/*
 * protect_set -- limit and window of one class (also kept when the profile is
 * not installed, so a later install uses it).
 * Returns: PROTECT_OK, PROTECT_BAD_ARG (class, limit above PROTECT_LIMIT_MAX,
 * window 0 or above PROTECT_WINDOW_MAX_MS), PROTECT_ABSENT (kept only),
 * PROTECT_TOO_SMALL (kept only) or PROTECT_HW_ERROR.
 */
int protect_set(unsigned cls, uint32_t limit_pkts, uint32_t window_ms)
{
    ensure_profile();
    if (cls >= PROTECT_CLASSES || limit_pkts > PROTECT_LIMIT_MAX || window_ms == 0u ||
        window_ms > PROTECT_WINDOW_MAX_MS) {
        return PROTECT_BAD_ARG;
    }
    g_profile.limit_pkts[cls] = limit_pkts;
    g_profile.window_ms[cls] = window_ms;
    if (!cpupath_cls_present()) {
        return PROTECT_ABSENT;
    }
    if (!g_installed) {
        return PROTECT_TOO_SMALL;
    }
    return map_rc(rtlnet_classifier_protect_limit(&g_cls, (rtlnet_cls_prot_class_t)cls, limit_pkts, window_ms));
}

/*
 * protect_class_get -- configuration and counters of one class. Without an
 * installed profile the counters are 0 and the limits are the configured ones.
 * Returns: PROTECT_OK, PROTECT_BAD_ARG, PROTECT_HW_ERROR.
 */
int protect_class_get(unsigned cls, protect_class_t *out)
{
    rtlnet_cls_policer_t ps;

    if (cls >= PROTECT_CLASSES || out == NULL) {
        return PROTECT_BAD_ARG;
    }
    ensure_profile();
    *out = (protect_class_t){ 0 };
    out->limit_pkts = g_profile.limit_pkts[cls];
    out->window_ms = g_profile.window_ms[cls];
    if (!g_installed) {
        return PROTECT_OK;
    }
    if (rtlnet_classifier_protect_get(&g_cls, (rtlnet_cls_prot_class_t)cls, &ps) != RTLNET_CLS_OK) {
        return PROTECT_HW_ERROR;
    }
    out->limit_pkts = ps.limit_pkts;
    out->window_ms = ps.window_ms;
    out->enabled = (int)ps.enable;
    out->seen = ps.seen;
    out->passed = ps.passed;
    out->dropped = ps.dropped;
    return PROTECT_OK;
}

/*
 * protect_info -- the built classifier (sizes, RAM style, latency) and the
 * state of the profile.
 * Returns: PROTECT_OK (*out valid), PROTECT_ABSENT (*out valid 0) or PROTECT_HW_ERROR.
 */
int protect_info(protect_info_t *out)
{
    rtlnet_cls_build_t b;
    rtlnet_cls_mode_t  m;

    if (out == NULL) {
        return PROTECT_BAD_ARG;
    }
    *out = (protect_info_t){ 0 };
    if (!cpupath_cls_present()) {
        return PROTECT_ABSENT;
    }
    if (rtlnet_classifier_init(&g_cls, RTLNET_PLAT_CLS_BASE) != RTLNET_CLS_OK ||
        rtlnet_classifier_get_build(&g_cls, &b) != RTLNET_CLS_OK ||
        rtlnet_classifier_get_mode(&g_cls, &m) != RTLNET_CLS_OK) {
        return PROTECT_HW_ERROR;
    }
    out->valid = 1;
    out->installed = g_installed;
    out->mode = (unsigned)m;
    out->table_entries = b.table_entries;
    out->tuple_entries = b.tuple_entries;
    out->num_rules = b.num_rules;
    out->num_policers = b.num_policers;
    out->table_lanes = b.table_lanes;
    out->match_depth_bytes = b.match_depth_bytes;
    out->ram_distributed = (int)b.ram_distributed;
    out->delay_beats = b.delay_beats;
    out->verdict_latency = b.verdict_latency;
    return PROTECT_OK;
}

/*
 * protect_class_find -- class number of a CLI word (case-insensitive, whole word).
 * Returns: 0..PROTECT_CLASSES-1, or -1 for an unknown word.
 */
int protect_class_find(const char *name)
{
    for (unsigned c = 0u; c < PROTECT_CLASSES; c++) {
        const char *want = protect_class_name(c);
        const char *s = name;

        while (s != NULL && *s != '\0' && *want != '\0' && lower(*s) == *want) {
            s++;
            want++;
        }
        if (s != NULL && *s == '\0' && *want == '\0') {
            return (int)c;
        }
    }
    return -1;
}

/*
 * protect_class_name -- CLI spelling of a class.
 * Returns: the name, "?" for a number past the classes.
 */
const char *protect_class_name(unsigned cls)
{
    static const char *const names[PROTECT_CLASSES] = { "broadcast", "udp", "arp", "icmp" };

    return (cls < PROTECT_CLASSES) ? names[cls] : "?";
}

/*
 * protect_class_text -- what a class polices, for the console.
 * Returns: the text.
 */
const char *protect_class_text(unsigned cls)
{
    static const char *const texts[PROTECT_CLASSES] = {
        "broadcast frames (other than ARP, ICMP, UDP)",
        "UDP datagrams no hardware socket claimed",
        "ARP requests (other hosts) and replies",
        "ICMP the hardware responder did not answer"
    };

    return (cls < PROTECT_CLASSES) ? texts[cls] : "?";
}

/*
 * protect_result_text -- explanation of a PROTECT_* result for the console.
 * Returns: the text.
 */
const char *protect_result_text(int rc)
{
    switch (rc) {
    case PROTECT_OK:        return "applied";
    case PROTECT_ABSENT:    return "classifier not present in this build; setting kept";
    case PROTECT_BAD_ARG:   return "invalid argument";
    case PROTECT_TOO_SMALL: return "this classifier build cannot hold the protection profile (not installed); setting kept";
    default:                return "classifier driver error";
    }
}
