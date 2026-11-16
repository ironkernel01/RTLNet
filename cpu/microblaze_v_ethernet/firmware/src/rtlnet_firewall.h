/*
 * rtlnet_firewall.h -- default-deny firewall of the CPU path: ARP and an allow list reach lwIP, everything
 *                      else is dropped by the classifier
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the firmware owner of the Ethernet demo's firewall. The firewall is off at boot (every frame
 * reaches lwIP except what the protection profile polices). With the firewall on, only ARP and the allow
 * list reach lwIP; the classifier drops the rest in hardware (MODE drop-on-match, EtherType table EXCLUDE
 * with the ARP pair, tuple table EXCLUDE holding the allow list: cores/rtlnet_classifier/documentation,
 * sections 6 and 13).
 *
 * The allow list is composed, in this order, from
 *   1. the services lwIP listens on (TCP echo, TCP iperf server, the iperf connect-back listener): protocol, destination port, any source;
 *      a service is left out when a user ACL entry already covers its protocol and port, so a
 *      source-restricted ACL entry stays in force;
 *   2. the client flows lwIP opened (the iperf client connect-backs): TCP, source = the remote address
 *      (/32) and port, destination port = the local port of the connection;
 *   3. the user ACL entries ("classifier acl ...", all treated as allow entries while the firewall is on;
 *      a police action keeps its policer).
 * The EtherType entries of the user configuration are not applied while the firewall is on (the Ethernet
 * firmware has no command for them). The classifier build limits the list (tuple slots); with the firewall
 * on, an entry that does not fit stays out and is counted ("show classifier" reports it); turning the
 * firewall on is refused, before any register is written, when the list does not fit.
 *
 * Live update: with the firewall on, a change of a service or flow, or of a user ACL entry, is applied to
 * the hardware as the difference against a shadow of the allow slots: a removed entry's slot is cleared,
 * a new entry goes into a free slot (value words first, VALID last: rtlnet_classifier_tuple_live_set /
 * _live_clear). No clear_all and no TABLE_MODE write happens, so established connections are not disturbed.
 *
 * Callers: src/lwip/rtlnet_tcp_echo.c (listen, close, port change), src/lwip/rtlnet_lwiperf.c (server
 * listen and close, every client connect and its close), the CLI. Context: main loop only.
 *
 * This header holds types, constants and signatures; rtlnet_firewall.c holds the per-function commentary.
 */
#ifndef RTLNET_FIREWALL_H
#define RTLNET_FIREWALL_H

#include <stdint.h>   /* uint8_t, uint16_t, uint32_t */

#include "rtlnet_classifier.h"

/* Fixed service ids. */
#define FW_SVC_TCP_ECHO        0u
#define FW_SVC_IPERF_TCP       1u
#define FW_SVC_IPERF_BACK      2u      /* the listener of a dual / tradeoff iperf session while it waits for the connect-back */
#define FW_NUM_SERVICES        3u

#define FW_MAX_FLOWS           4u      /* client flows tracked at a time */
#define FW_MAX_SLOTS           16u     /* allow slots tracked (RTLNET_CLS_MAX_TUPLES) */

#define FW_PROTO_TCP           6u
#define FW_PROTO_UDP           17u

/* Results. */
#define FW_OK                  0
#define FW_ABSENT              (-1)    /* classifier not in this build: the firewall cannot be on */
#define FW_BAD_ARG             (-2)
#define FW_NO_ROOM             (-3)    /* the allow list does not fit the tuple slots (see fw_status) */
#define FW_NO_ARP              (-4)    /* the build has no EtherType pair for ARP */
#define FW_HW_ERROR            (-5)
#define FW_FULL                (-6)    /* the flow table is full; the flow is not tracked */

/* What an allow slot holds. */
#define FW_SLOT_FREE           0u
#define FW_SLOT_SERVICE        1u
#define FW_SLOT_FLOW           2u
#define FW_SLOT_ACL            3u

typedef struct {
    uint8_t  proto;
    uint16_t port;                     /* destination port */
    int      active;                   /* lwIP listens */
} fw_service_t;

typedef struct {
    uint8_t  proto;
    uint32_t remote_ip;                /* number order */
    uint16_t remote_port;
    uint16_t local_port;
    int      active;
} fw_flow_t;

/* One allow slot as the hardware holds it (shadow). */
typedef struct {
    uint8_t            kind;           /* FW_SLOT_* */
    uint8_t            index;          /* service id, flow index or ACL entry */
    rtlnet_cls_tuple_t tuple;
} fw_slot_t;

typedef struct {
    int      enabled;
    unsigned slots;                    /* tuple slots of the build */
    unsigned used;                     /* allow slots in use */
    unsigned unfit;                    /* wanted entries that are not in the hardware list */
    unsigned needed;                   /* entries of the list at the last enable request */
    unsigned avail;                    /* slots at that request */
    unsigned flows_full;               /* flows that found the flow table full */
} fw_status_t;

void           fw_config_defaults(void);
int            fw_enable(int on);
int            fw_enabled(void);
int            fw_service_set(unsigned id, uint8_t proto, uint16_t port, int active);
int            fw_flow_add(uint8_t proto, uint32_t remote_ip, uint16_t remote_port, uint16_t local_port);
int            fw_flow_remove(uint8_t proto, uint32_t remote_ip, uint16_t remote_port, uint16_t local_port);
void           fw_status(fw_status_t *out);
const fw_slot_t *fw_slot(unsigned slot);
const char    *fw_service_name(unsigned id);
const char    *fw_result_text(int rc);

/* Used by rtlnet_cpupath.c (the owner of the classifier context). */
unsigned       fw_compose(rtlnet_cls_tuple_t *out, unsigned max, unsigned *needed);
void           fw_shadow_clear(void);
int            fw_live_refresh(void);

#endif /* RTLNET_FIREWALL_H */
