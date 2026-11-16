/*
 * rtlnet_firewall.c -- default-deny firewall of the CPU path: allow list composition and live update
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_firewall.h for the contract. Context: main loop only. This file keeps the services, the client
 * flows and a shadow of the hardware allow slots; the classifier is written only through the functions of
 * rtlnet_cpupath.c (cpupath_sync for the whole state, cpupath_fw_live_set / _live_clear for one slot).
 */
#include "rtlnet_firewall.h"

#include <stddef.h>   /* NULL */

#include "rtlnet_cpupath.h"

#define FW_MAX_WANT   (FW_NUM_SERVICES + FW_MAX_FLOWS + CPUPATH_CLS_ENTRIES)

/* One entry of the composed list. */
typedef struct {
    uint8_t            kind;
    uint8_t            index;
    rtlnet_cls_tuple_t tuple;
} fw_want_t;

static int          g_enabled;
static fw_service_t g_svc[FW_NUM_SERVICES];
static fw_flow_t    g_flow[FW_MAX_FLOWS];
static fw_slot_t    g_slot[FW_MAX_SLOTS];     /* what the hardware holds while the firewall is on */
static fw_want_t    g_want[FW_MAX_WANT];      /* scratch: the composed list */
static unsigned     g_unfit;
static unsigned     g_needed;
static unsigned     g_avail;
static unsigned     g_flows_full;

/*
 * fw_config_defaults -- firewall off, no service, no flow (no hardware access).
 * Returns: nothing.
 */
void fw_config_defaults(void)
{
    g_enabled = 0;
    for (unsigned i = 0; i < FW_NUM_SERVICES; i++) {
        g_svc[i] = (fw_service_t){ 0 };
    }
    for (unsigned i = 0; i < FW_MAX_FLOWS; i++) {
        g_flow[i] = (fw_flow_t){ 0 };
    }
    fw_shadow_clear();
    g_needed = 0u;
    g_avail = 0u;
    g_flows_full = 0u;
}

/*
 * fw_shadow_clear -- every allow slot free (the hardware holds no allow list).
 * Returns: nothing.
 */
void fw_shadow_clear(void)
{
    for (unsigned i = 0; i < FW_MAX_SLOTS; i++) {
        g_slot[i] = (fw_slot_t){ 0 };
    }
    g_unfit = 0u;
}

/*
 * fw_enabled -- the firewall is on.
 * Returns: 1 on, 0 off.
 */
int fw_enabled(void)
{
    return g_enabled;
}

/*
 * tuple_equal -- two tuples hold the same match and action.
 * Returns: 1 equal, 0 different.
 */
static int tuple_equal(const rtlnet_cls_tuple_t *a, const rtlnet_cls_tuple_t *b)
{
    return a->valid == b->valid && a->proto_en == b->proto_en && a->proto == b->proto &&
           a->police_en == b->police_en && a->policer == b->policer && a->src_ip == b->src_ip &&
           a->src_mask == b->src_mask && a->dst_ip == b->dst_ip && a->dst_mask == b->dst_mask &&
           a->sport_lo == b->sport_lo && a->sport_hi == b->sport_hi && a->dport_lo == b->dport_lo &&
           a->dport_hi == b->dport_hi;
}

/*
 * acl_covers -- a valid user ACL entry that matches the protocol and the destination port of a service.
 * Returns: 1 covered, 0 not.
 */
static int acl_covers(const fw_service_t *s)
{
    const cpupath_cls_config_t *c = cpupath_cls_config();

    for (unsigned i = 0; i < CPUPATH_CLS_ENTRIES; i++) {
        const cpupath_acl_entry_t *a = &c->acl[i];
        if (a->valid && (a->proto == 0u || a->proto == s->proto) && s->port >= a->dport_lo && s->port <= a->dport_hi) {
            return 1;
        }
    }
    return 0;
}

/*
 * tuple_base -- an allowed tuple with no source or destination restriction and every port.
 * Returns: nothing; *t filled.
 */
static void tuple_base(rtlnet_cls_tuple_t *t, uint8_t proto)
{
    *t = (rtlnet_cls_tuple_t){ 0 };
    t->valid = 1u;
    t->proto_en = (proto != 0u) ? 1u : 0u;
    t->proto = proto;
    t->sport_hi = 0xFFFFu;
    t->dport_hi = 0xFFFFu;
}

/*
 * build_list -- compose the allow list into g_want: active services (not covered by a user ACL entry),
 * active flows, user ACL entries.
 * Returns: the number of entries.
 */
static unsigned build_list(void)
{
    const cpupath_cls_config_t *c = cpupath_cls_config();
    unsigned n = 0u;

    for (unsigned i = 0; i < FW_NUM_SERVICES; i++) {
        const fw_service_t *s = &g_svc[i];
        if (s->active && !acl_covers(s)) {
            g_want[n].kind = (uint8_t)FW_SLOT_SERVICE;
            g_want[n].index = (uint8_t)i;
            tuple_base(&g_want[n].tuple, s->proto);
            g_want[n].tuple.dport_lo = s->port;
            g_want[n].tuple.dport_hi = s->port;
            n++;
        }
    }
    for (unsigned i = 0; i < FW_MAX_FLOWS; i++) {
        const fw_flow_t *f = &g_flow[i];
        if (f->active) {
            g_want[n].kind = (uint8_t)FW_SLOT_FLOW;
            g_want[n].index = (uint8_t)i;
            tuple_base(&g_want[n].tuple, f->proto);
            g_want[n].tuple.src_ip = f->remote_ip;
            g_want[n].tuple.src_mask = 0xFFFFFFFFu;
            g_want[n].tuple.sport_lo = f->remote_port;
            g_want[n].tuple.sport_hi = f->remote_port;
            g_want[n].tuple.dport_lo = f->local_port;
            g_want[n].tuple.dport_hi = f->local_port;
            n++;
        }
    }
    for (unsigned i = 0; i < CPUPATH_CLS_ENTRIES; i++) {
        const cpupath_acl_entry_t *a = &c->acl[i];
        if (a->valid) {
            rtlnet_cls_tuple_t *t = &g_want[n].tuple;
            g_want[n].kind = (uint8_t)FW_SLOT_ACL;
            g_want[n].index = (uint8_t)i;
            tuple_base(t, a->proto);
            t->police_en = (a->action == CPUPATH_ACT_POLICE) ? 1u : 0u;
            t->policer = (uint8_t)((a->action == CPUPATH_ACT_POLICE) ? a->policer : 0u);
            t->src_ip = a->src;
            t->src_mask = a->src_mask;
            t->dst_ip = a->dst;
            t->dst_mask = a->dst_mask;
            t->sport_lo = a->sport_lo;
            t->sport_hi = a->sport_hi;
            t->dport_lo = a->dport_lo;
            t->dport_hi = a->dport_hi;
            n++;
        }
    }
    return n;
}

/*
 * fw_compose -- the allow list for a whole-state write (called by cpupath's hw_sync with the firewall on).
 * Steps:
 *   1. Compose the list; its length is *needed.
 *   2. The first `max` entries go to out[0..]; the shadow of the hardware slots is set to exactly that,
 *      the remaining slots are free; entries past max are counted as not fitting.
 * Returns: the number of entries placed in out.
 */
unsigned fw_compose(rtlnet_cls_tuple_t *out, unsigned max, unsigned *needed)
{
    unsigned n = build_list();
    unsigned placed = (n < max) ? n : max;

    if (placed > FW_MAX_SLOTS) {
        placed = FW_MAX_SLOTS;
    }
    fw_shadow_clear();
    for (unsigned i = 0; i < placed; i++) {
        out[i] = g_want[i].tuple;
        g_slot[i].kind = g_want[i].kind;
        g_slot[i].index = g_want[i].index;
        g_slot[i].tuple = g_want[i].tuple;
    }
    g_unfit = n - placed;
    if (needed != NULL) {
        *needed = n;
    }
    return placed;
}

/*
 * slot_wanted -- position of the composed entry that a slot holds (same owner and same tuple).
 * Returns: the index in g_want, or -1 when the slot is stale.
 */
static int slot_wanted(const fw_slot_t *s, unsigned n)
{
    for (unsigned i = 0; i < n; i++) {
        if (g_want[i].kind == s->kind && g_want[i].index == s->index && tuple_equal(&g_want[i].tuple, &s->tuple)) {
            return (int)i;
        }
    }
    return -1;
}

/*
 * fw_live_refresh -- apply the difference between the composed list and the shadow, live.
 * Steps:
 *   1. Compose the list. A slot whose entry is no longer in it (removed, or changed) is cleared
 *      (rtlnet_classifier_tuple_live_clear) and marked free.
 *   2. Every composed entry that is in no slot goes into the first free slot (tuple_live_set); with no free
 *      slot the entry stays out and counts as not fitting.
 * Nothing is written when the firewall is off or the list is unchanged.
 * Returns: FW_OK, FW_HW_ERROR.
 */
int fw_live_refresh(void)
{
    unsigned slots = cpupath_fw_slots();
    unsigned n;
    unsigned unfit = 0u;

    if (!g_enabled) {
        return FW_OK;
    }
    if (slots > FW_MAX_SLOTS) {
        slots = FW_MAX_SLOTS;
    }
    n = build_list();
    for (unsigned s = 0; s < slots; s++) {
        if (g_slot[s].kind != (uint8_t)FW_SLOT_FREE && slot_wanted(&g_slot[s], n) < 0) {
            if (cpupath_fw_live_clear(s) != CPUPATH_OK) {
                return FW_HW_ERROR;
            }
            g_slot[s] = (fw_slot_t){ 0 };
        }
    }
    for (unsigned w = 0; w < n; w++) {
        unsigned s;
        int held = 0;
        for (s = 0; s < slots; s++) {
            if (g_slot[s].kind == g_want[w].kind && g_slot[s].index == g_want[w].index &&
                tuple_equal(&g_slot[s].tuple, &g_want[w].tuple)) {
                held = 1;
                break;
            }
        }
        if (held) {
            continue;
        }
        for (s = 0; s < slots && g_slot[s].kind != (uint8_t)FW_SLOT_FREE; s++) {
        }
        if (s >= slots) {
            unfit++;
            continue;
        }
        if (cpupath_fw_live_set(s, &g_want[w].tuple) != CPUPATH_OK) {
            return FW_HW_ERROR;
        }
        g_slot[s].kind = g_want[w].kind;
        g_slot[s].index = g_want[w].index;
        g_slot[s].tuple = g_want[w].tuple;
    }
    g_unfit = unfit;
    return FW_OK;
}

/*
 * fw_service_set -- a service that lwIP listens on (or stopped listening on).
 * Returns: FW_OK, FW_BAD_ARG (id past FW_NUM_SERVICES), FW_HW_ERROR (live update failed; the table is updated).
 */
int fw_service_set(unsigned id, uint8_t proto, uint16_t port, int active)
{
    if (id >= FW_NUM_SERVICES) {
        return FW_BAD_ARG;
    }
    g_svc[id].proto = proto;
    g_svc[id].port = port;
    g_svc[id].active = active ? 1 : 0;
    return fw_live_refresh();
}

/*
 * flow_find -- the active flow with these values.
 * Returns: its index, or -1.
 */
static int flow_find(uint8_t proto, uint32_t rip, uint16_t rport, uint16_t lport)
{
    for (unsigned i = 0; i < FW_MAX_FLOWS; i++) {
        const fw_flow_t *f = &g_flow[i];
        if (f->active && f->proto == proto && f->remote_ip == rip && f->remote_port == rport && f->local_port == lport) {
            return (int)i;
        }
    }
    return -1;
}

/*
 * fw_flow_add -- a connection lwIP opened: allow the reply traffic (remote address and port to the local
 * port). Adding a flow that is tracked already changes nothing.
 * Returns: FW_OK, FW_FULL (flow table full: counted, the flow stays blocked), FW_HW_ERROR.
 */
int fw_flow_add(uint8_t proto, uint32_t remote_ip, uint16_t remote_port, uint16_t local_port)
{
    if (flow_find(proto, remote_ip, remote_port, local_port) >= 0) {
        return FW_OK;
    }
    for (unsigned i = 0; i < FW_MAX_FLOWS; i++) {
        if (!g_flow[i].active) {
            g_flow[i].proto = proto;
            g_flow[i].remote_ip = remote_ip;
            g_flow[i].remote_port = remote_port;
            g_flow[i].local_port = local_port;
            g_flow[i].active = 1;
            return fw_live_refresh();
        }
    }
    g_flows_full++;
    return FW_FULL;
}

/*
 * fw_flow_remove -- the connection closed or failed.
 * Returns: FW_OK (also for a flow that is not tracked), FW_HW_ERROR.
 */
int fw_flow_remove(uint8_t proto, uint32_t remote_ip, uint16_t remote_port, uint16_t local_port)
{
    int i = flow_find(proto, remote_ip, remote_port, local_port);

    if (i < 0) {
        return FW_OK;
    }
    g_flow[i].active = 0;
    return fw_live_refresh();
}

/*
 * fw_enable -- firewall on or off.
 * On: refused, with nothing written, when the classifier is absent, has no ARP pair, or the allow list needs
 * more tuple slots than the build has (fw_status gives needed and avail); else the whole state is rebuilt
 * (cpupath_sync: protection profile, firewall).
 * Off: the whole state is rebuilt without the firewall (exactly the state before it was turned on); never
 * refused for acl space (cpupath_cls_set_acl applies the same slot limit in both states).
 * Returns: FW_OK, FW_ABSENT, FW_NO_ARP, FW_NO_ROOM, FW_HW_ERROR.
 */
int fw_enable(int on)
{
    int rc;

    if (on) {
        if (!cpupath_cls_present()) {
            return FW_ABSENT;
        }
        if (!cpupath_fw_arp_ok()) {
            return FW_NO_ARP;
        }
        g_needed = build_list();
        g_avail = cpupath_fw_slots();
        if (g_needed > g_avail) {
            return FW_NO_ROOM;
        }
        g_enabled = 1;
        rc = cpupath_sync();
        if (rc != CPUPATH_OK) {
            g_enabled = 0;
            (void)cpupath_sync();
            return FW_HW_ERROR;
        }
        return FW_OK;
    }
    if (!g_enabled) {
        return FW_OK;
    }
    g_enabled = 0;
    rc = cpupath_sync();
    return (rc == CPUPATH_OK || rc == CPUPATH_ABSENT) ? FW_OK : FW_HW_ERROR;
}

/*
 * fw_status -- state for the console.
 * Returns: nothing; *out filled.
 */
void fw_status(fw_status_t *out)
{
    *out = (fw_status_t){ 0 };
    out->enabled = g_enabled;
    out->slots = cpupath_fw_slots();
    for (unsigned i = 0; i < FW_MAX_SLOTS; i++) {
        if (g_slot[i].kind != (uint8_t)FW_SLOT_FREE) {
            out->used++;
        }
    }
    out->unfit = g_unfit;
    out->needed = g_needed;
    out->avail = g_avail;
    out->flows_full = g_flows_full;
}

/*
 * fw_slot -- one allow slot of the shadow.
 * Returns: pointer to it, NULL past FW_MAX_SLOTS.
 */
const fw_slot_t *fw_slot(unsigned slot)
{
    return (slot < FW_MAX_SLOTS) ? &g_slot[slot] : NULL;
}

/*
 * fw_service_name -- CLI spelling of a service.
 * Returns: the name, "?" for an id past the services.
 */
const char *fw_service_name(unsigned id)
{
    static const char *const names[FW_NUM_SERVICES] = { "tcp-echo", "iperf-tcp", "iperf-back" };

    return (id < FW_NUM_SERVICES) ? names[id] : "?";
}

/*
 * fw_result_text -- explanation of an FW_* result for the console.
 * Returns: the text.
 */
const char *fw_result_text(int rc)
{
    switch (rc) {
    case FW_OK:          return "applied";
    case FW_ABSENT:      return "classifier not present in this build; the firewall cannot be turned on";
    case FW_BAD_ARG:     return "invalid argument";
    case FW_NO_ROOM:     return "the allow list does not fit the classifier's tuple slots";
    case FW_NO_ARP:      return "this classifier build has no EtherType entry pair for ARP";
    case FW_FULL:        return "flow table full";
    default:             return "classifier driver error";
    }
}
