/*
 * rtlnet_offload.h -- CPU-path feature discovery and the checksum offload
 *                     control (hardware CTRL and the lwIP checksum flags)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: two things, both without any compile-time assumption about the
 * bitstream.
 *
 * 1. Discovery (rtlnet_features_discover, once at boot; printed by
 *    "show offload" and "show version"). Order:
 *      1. the protocol wrapper answers its ID and VERSION;
 *      2. CAPS.CPU_PATH_PRESENT;
 *      3. CPU_CAPS feature bits: 16 classifier, 17 checksum offload TX
 *         (insert), 18 checksum offload RX (check and trailer);
 *      4. for a block the wrapper advertises, the block's own header is
 *         checked: classifier ID "CLSF" and VERSION; offload ID "TCPO",
 *         VERSION and CAPS.TX_PRESENT / CAPS.RX_PRESENT equal to the wrapper's
 *         bits 17 / 18. Any difference logs an error and the block is
 *         treated as absent.
 *    The classifier boot configuration (rtlnet_cpupath.c) and
 *    rtlnet_offload_apply() use the result.
 *
 * 2. rtlnet_offload_apply(want): the one function that changes the offload
 *    CTRL register and the lwIP netif checksum flags (InitLWIP and the CLI
 *    both call it). It masks the request by what is present, then:
 *      TX bit ON : write CTRL, read it back, then clear the matching
 *                  NETIF_CHECKSUM_GEN_* flags (the hardware overwrites the
 *                  checksum field, so lwIP's value is harmless meanwhile);
 *      TX bit OFF: set the GEN_* flags first, poll STATUS.TX_IDLE (bounded:
 *                  frames already queued were sent without a software
 *                  checksum), then clear the CTRL bit;
 *      RX ON     : write CTRL, read it back; the netif starts parsing
 *                  trailers; the CHECK_* flags are cleared when the first
 *                  frame with a valid trailer arrives (frames queued before
 *                  the change have none and are checked in software);
 *      RX OFF    : set the CHECK_* flags first, then clear CTRL; the netif
 *                  keeps keying off the marker of each frame until the first
 *                  frame without a trailer (frames already past the offload
 *                  still carry one).
 *    The lwIP flags are always derived from the CTRL value read back, never
 *    from the request. ICMP checksums stay in software (not offloaded).
 *
 * Receive policy (rtlnet_offload_rx_frame, called by the netif for each DMA
 * transfer): IPv4 frame with a bad header, or a verified segment with a bad
 * checksum -> drop and count; verified and good -> pass; unverified -> pass.
 * A frame without a valid trailer while rx_csum is on is dropped and counted.
 *
 * 3. Receive features of the core (CAPS bits ACK_COALESCE and RX_BATCH, discovered with the block; absent in the
 *    checksum-only bitstreams, where every function below reports RTLNET_OFFLOAD_ERR_ABSENT and nothing else in this
 *    file changes): rtlnet_offload_ack_set() and rtlnet_offload_batch_set() configure and switch them. Both work on
 *    the trailer, so rx must be on (RTLNET_OFFLOAD_ERR_NEED_RX otherwise); rtlnet_offload_apply() switches them off
 *    before it turns rx off. rx batching changes the DMA transfers into batches: the netif owns the matching buffer
 *    geometry (rtlnet_netif_set_rx_batch), the CLI calls both in the order that keeps the transfers within the buffer.
 *
 * Host harness: the lwIP hooks (rtlnet_lwip_set_checksum_ctrl / _get_) are
 * provided by host/host_lwip_stub.c or the offload test, the register
 * access by the rtlnet_mmio host model.
 *
 * This header holds types, constants and signatures; rtlnet_offload.c holds
 * the per-function commentary.
 */
#ifndef RTLNET_OFFLOAD_H
#define RTLNET_OFFLOAD_H

#include <stdint.h>   /* uint8_t, uint32_t */

#include "rtlnet_tcp_offload.h"   /* rtlnet_txo_counters_t */

/* Request / CTRL bits (same positions as the core's CTRL register). */
#define RTLNET_OFFLOAD_TX_IP   0x1u    /* insert the IPv4 header checksum */
#define RTLNET_OFFLOAD_TX_L4   0x2u    /* insert the TCP and UDP checksums */
#define RTLNET_OFFLOAD_RX      0x4u    /* check IPv4/TCP/UDP checksums, trailer on every frame */
#define RTLNET_OFFLOAD_ALL     0x7u

/* The lwIP NETIF_CHECKSUM_* flag values (asserted against lwIP in rtlnet_lwip.c). */
#define RTLNET_CS_GEN_IP       0x0001u
#define RTLNET_CS_GEN_UDP      0x0002u
#define RTLNET_CS_GEN_TCP      0x0004u
#define RTLNET_CS_GEN_ICMP     0x0008u
#define RTLNET_CS_CHECK_IP     0x0100u
#define RTLNET_CS_CHECK_UDP    0x0200u
#define RTLNET_CS_CHECK_TCP    0x0400u
#define RTLNET_CS_CHECK_ICMP   0x0800u
#define RTLNET_CS_ENABLE_ALL   0xFFFFu

/* Bounds. */
#define RTLNET_OFFLOAD_IDLE_POLLS   2000u   /* STATUS reads while waiting for TX_IDLE */

/* Results of rtlnet_offload_apply. */
#define RTLNET_OFFLOAD_OK           0
#define RTLNET_OFFLOAD_ERR_IO       (-1)    /* CTRL did not read back as written */
#define RTLNET_OFFLOAD_ERR_TIMEOUT  (-2)    /* TX_IDLE did not come: the CTRL bit stays set */

/* Receive features. */
#define RTLNET_OFFLOAD_FEAT_ACK     0x1u    /* ACK coalescing */
#define RTLNET_OFFLOAD_FEAT_BATCH   0x2u    /* receive batching */
#define RTLNET_OFFLOAD_KEEP         0xFFFFFFFFu   /* "keep the current value" for a timer or limit argument */
#define RTLNET_OFFLOAD_ERR_NEED_RX  (-3)    /* the feature works on the receive trailer: rx offload is not on */
#define RTLNET_OFFLOAD_ERR_ABSENT   (-4)    /* the build does not have the feature */
#define RTLNET_OFFLOAD_ERR_ARG      (-5)    /* a value outside the register range */

/* Feature discovery result. */
typedef struct {
    int      discovered;        /* the routine ran */
    int      wrapper_ok;        /* wrapper ID and VERSION match */
    int      cpu_path;          /* CAPS.CPU_PATH_PRESENT */
    uint32_t cpu_caps;          /* CPU_CAPS as read */
    int      cls_advertised;    /* CPU_CAPS bit 16 */
    int      tx_advertised;     /* CPU_CAPS bit 17 */
    int      rx_advertised;     /* CPU_CAPS bit 18 */
    int      cls_present;       /* advertised and the block's header matches */
    int      tx_present;        /* advertised and the block's header and CAPS match */
    int      rx_present;
    uint32_t block_caps;        /* offload CAPS as read (0 when not read) */
    unsigned errors;            /* mismatches found (each also printed) */
} rtlnet_features_t;

/* Receive state of the trailer handling. */
typedef enum {
    RTLNET_RX_TRAILER_OFF = 0,  /* rx_csum off: frames are raw */
    RTLNET_RX_TRAILER_ARMING,   /* rx_csum on, no trailer seen yet: parse by marker, software checks still on */
    RTLNET_RX_TRAILER_ON,       /* rx_csum on, trailers seen: every frame must carry one */
    RTLNET_RX_TRAILER_DRAINING  /* rx_csum turned off: parse by marker until the first raw frame */
} rtlnet_rx_trailer_state_t;

/* What the netif does with a received DMA transfer. */
typedef enum {
    RTLNET_RXA_DELIVER_RAW = 0,     /* no trailer expected or present: whole transfer is the frame */
    RTLNET_RXA_DELIVER_VERIFIED,    /* trailer: both checks good */
    RTLNET_RXA_DELIVER_UNVERIFIED,  /* trailer: not checkable, passes */
    RTLNET_RXA_DROP_BAD_IP,         /* trailer: IPv4 header malformed or checksum bad */
    RTLNET_RXA_DROP_BAD_L4,         /* trailer: TCP/UDP checksum bad */
    RTLNET_RXA_DROP_NO_TRAILER      /* rx_csum on but no valid trailer */
} rtlnet_rx_action_t;

typedef struct {
    uint32_t want;              /* requested, masked by what is present */
    uint32_t ctrl;              /* CTRL as last read back */
    uint32_t flags;             /* lwIP checksum flags last set */
    rtlnet_rx_trailer_state_t rx_state;
    uint32_t rx_trailer_frames; /* frames with a valid trailer */
    uint32_t rx_verified;       /* passed, verified */
    uint32_t rx_unverified;     /* passed, unverified */
    uint32_t rx_drop_ip;        /* dropped: bad IPv4 header */
    uint32_t rx_drop_l4;        /* dropped: bad TCP/UDP checksum */
    uint32_t rx_no_trailer;     /* dropped: rx_csum on, no trailer */
    uint32_t rx_raw;            /* frames handled without a trailer */
    uint32_t applies;           /* rtlnet_offload_apply calls */
    uint32_t io_errors;
    uint32_t idle_timeouts;
} rtlnet_offload_state_t;

/* The receive features as configured (what the CLI shows and the running configuration prints). */
typedef struct {
    uint32_t present;           /* RTLNET_OFFLOAD_FEAT_* the build has */
    uint32_t on;                /* RTLNET_OFFLOAD_FEAT_* switched on */
    uint32_t ack_flows;         /* flow table entries (CAPS2) */
    uint32_t bat_reserve;       /* bytes the batch byte limit keeps free for a next frame (CAPS2) */
    uint32_t ack_timer_us;      /* configuration, as last written (reset value until then) */
    uint32_t ack_limit;
    uint32_t bat_timer_us;
    uint32_t bat_frames;
    uint32_t bat_bytes;
} rtlnet_offload_feat_t;

/* lwIP hooks (rtlnet_lwip.c on the target, host stubs on the PC). */
void     rtlnet_lwip_set_checksum_ctrl(uint32_t flags);
uint32_t rtlnet_lwip_get_checksum_ctrl(void);

void                        rtlnet_features_discover(void);
void                        rtlnet_features_rediscover(void);
const rtlnet_features_t    *rtlnet_features(void);

int                         rtlnet_offload_apply(uint32_t want_mask);
uint32_t                    rtlnet_offload_request(void);
uint32_t                    rtlnet_offload_supported(void);
uint32_t                    rtlnet_offload_flags_for(uint32_t ctrl, int rx_checks_off);
const rtlnet_offload_state_t *rtlnet_offload_state(void);
rtlnet_rx_action_t          rtlnet_offload_rx_frame(const uint8_t *buf, uint32_t xfer_len, uint32_t *frame_len);
int                         rtlnet_offload_counters(rtlnet_txo_counters_t *out);
int                         rtlnet_offload_status(uint32_t *status);
int                         rtlnet_offload_ctrl_now(uint32_t *ctrl);
uint32_t                    rtlnet_offload_buffer_kb(void);
void                        rtlnet_offload_reset_stats(void);

const rtlnet_offload_feat_t *rtlnet_offload_feat(void);
int                         rtlnet_offload_ack_set(int on, uint32_t timer_us, uint32_t limit);
int                         rtlnet_offload_batch_set(int on, uint32_t timer_us, uint32_t max_frames, uint32_t max_bytes);
int                         rtlnet_offload_feat_counters(rtlnet_txo_feat_counters_t *out);

#endif /* RTLNET_OFFLOAD_H */
