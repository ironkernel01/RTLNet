/*
 * rtlnet_protect.h -- CPU-path protection profile: four traffic classes, each
 *                     policed by its own classifier policer
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the firmware owner of the Ethernet demo's default protection of the
 * soft CPU. The classifier on the CPU receive stream (u_cpu_classifier inside
 * rtlnet_eth_protocol, cores/rtlnet_classifier) stays in MODE pass-all, so
 * every frame reaches lwIP except what the four class policers limit. The
 * profile is installed once at boot by protect_install() through the
 * classifier driver (rtlnet_classifier_config_protect) and is tuned from the
 * CLI ("classifier policer <class> <frames> <window-ms>").
 *
 * Classes (class number = policer number), in the priority the hardware
 * applies when a frame belongs to several:
 *   arp        EtherType 0x0806, requests for other hosts and replies
 *   icmp       IPv4 protocol 1 that the hardware ICMP responder did not answer
 *   udp        IPv4 protocol 17 that no hardware socket claimed (closed ports)
 *   broadcast  destination FF:FF:FF:FF:FF:FF, the rest of the broadcast traffic
 * Everything else (TCP, unicast, ...) is not policed.
 *
 * Ownership: the classifier driver context lives in rtlnet_cpupath.c (the one owner of every register
 * write of the whole state). This module keeps the limits (protect_profile) and the installed state
 * (protect_installed); a limit change is one policer write through cpupath's context, and every
 * whole-state rewrite of cpupath (a CLI ACL edit, the firewall) rebuilds the profile from these limits
 * instead of wiping it.
 *
 * The profile needs a classifier of at least 1 table entry, 2 tuples, 1 rule
 * and 4 policers (the small-FPGA build has exactly that). A smaller build
 * leaves the classifier in the boot default of rtlnet_cpupath (broadcast storm
 * limiter) and protect_install() returns PROTECT_TOO_SMALL.
 *
 * This header holds types, constants and signatures; rtlnet_protect.c holds
 * the per-function commentary.
 */
#ifndef RTLNET_PROTECT_H
#define RTLNET_PROTECT_H

#include <stdint.h>   /* uint32_t */

#include "rtlnet_classifier.h"

#define PROTECT_CLASSES        4u        /* arp, icmp, udp, broadcast (policer numbers 2, 3, 1, 0) */
#define PROTECT_LIMIT_MAX      100000u   /* frames per window accepted from the CLI */
#define PROTECT_WINDOW_MAX_MS  60000u    /* window accepted from the CLI */

/* Results. */
#define PROTECT_OK             0
#define PROTECT_ABSENT         (-1)      /* classifier not in this bitstream (setting kept) */
#define PROTECT_BAD_ARG        (-2)
#define PROTECT_TOO_SMALL      (-3)      /* the built classifier cannot hold the profile */
#define PROTECT_HW_ERROR       (-4)

/* Class numbers: equal to the classifier policer that polices the class. */
#define PROTECT_BROADCAST      0u
#define PROTECT_UDP            1u
#define PROTECT_ARP            2u
#define PROTECT_ICMP           3u

/* One class: configuration and the policer's counters. */
typedef struct {
    uint32_t limit_pkts;       /* frames passed per window */
    uint32_t window_ms;
    int      enabled;          /* policer enable as the hardware reads it */
    uint32_t seen;             /* frames of the class */
    uint32_t passed;
    uint32_t dropped;
} protect_class_t;

/* The built classifier and the state of the profile. */
typedef struct {
    int      valid;            /* classifier answered, fields below read from it */
    int      installed;        /* the profile is active in the hardware */
    unsigned mode;             /* CTRL.MODE as the hardware reads it */
    uint32_t table_entries;    /* CAPS */
    uint32_t tuple_entries;
    uint32_t num_rules;
    uint32_t num_policers;
    uint32_t table_lanes;
    uint32_t match_depth_bytes;
    int      ram_distributed;  /* 1 = RAM_STYLE "distributed" */
    uint32_t delay_beats;      /* LATENCY */
    uint32_t verdict_latency;
} protect_info_t;

void        protect_config_defaults(void);
int         protect_install(void);
const rtlnet_cls_protect_t *protect_profile(void);
int         protect_installed(void);
int         protect_set(unsigned cls, uint32_t limit_pkts, uint32_t window_ms);
int         protect_class_get(unsigned cls, protect_class_t *out);
int         protect_info(protect_info_t *out);
int         protect_class_find(const char *name);
const char *protect_class_name(unsigned cls);
const char *protect_class_text(unsigned cls);
const char *protect_result_text(int rc);

#endif /* RTLNET_PROTECT_H */
