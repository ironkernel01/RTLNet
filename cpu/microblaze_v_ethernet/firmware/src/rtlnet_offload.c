/*
 * rtlnet_offload.c -- CPU-path feature discovery and the checksum offload
 *                     control
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_offload.h for the contract. Context: main loop only.
 */
#include "rtlnet_offload.h"

#include <string.h>   /* memset */

#include "rtlnet_classifier.h"
#include "rtlnet_eth_protocol.h"
#include "rtlnet_fmt.h"
#include "rtlnet_mmio.h"
#include "rtlnet_platform.h"

static rtlnet_features_t       g_feat;
static rtlnet_tcp_offload_t    g_txo;
static int                     g_txo_ok;
static rtlnet_offload_state_t  g_st;
static uint32_t                g_req = RTLNET_OFFLOAD_ALL;   /* requested offloads (default: everything present) */
static rtlnet_offload_feat_t   g_fc;                         /* receive features: ACK coalescing, batching */

/*
 * feat_discovered -- the receive features of a confirmed core: what is present, the reset values of the
 * configuration registers (all off).
 * Returns: nothing.
 */
static void feat_discovered(void)
{
    memset(&g_fc, 0, sizeof(g_fc));
    if (g_txo.ack_present != 0u) {
        g_fc.present |= RTLNET_OFFLOAD_FEAT_ACK;
        g_fc.ack_flows = g_txo.ack_flows;
        g_fc.ack_timer_us = RTLNET_TXO_ACK_TIMER_DEFAULT;
        g_fc.ack_limit = RTLNET_TXO_ACK_LIMIT_DEFAULT;
    }
    if (g_txo.batch_present != 0u) {
        g_fc.present |= RTLNET_OFFLOAD_FEAT_BATCH;
        g_fc.bat_reserve = g_txo.batch_reserve;
        g_fc.bat_timer_us = RTLNET_TXO_BAT_TIMER_DEFAULT;
        g_fc.bat_frames = RTLNET_TXO_BAT_FRAMES_DEFAULT;
        g_fc.bat_bytes = RTLNET_TXO_BAT_BYTES_DEFAULT;
    }
}

/*
 * feat_quiesce -- switch both receive features off (rx is about to go off) and wait, bounded, until what they hold
 * has been forwarded.
 * Returns: nothing.
 */
static void feat_quiesce(void)
{
    if (g_fc.on == 0u) {
        return;
    }
    (void)rtlnet_tcp_offload_set_features(&g_txo, 0u);
    (void)rtlnet_tcp_offload_wait_features_idle(&g_txo, RTLNET_OFFLOAD_IDLE_POLLS);
    g_fc.on = 0u;
}

/*
 * fail_block -- log a discovery mismatch and count it.
 * Returns: nothing.
 */
static void fail_block(const char *what, uint32_t got, uint32_t want)
{
    g_feat.errors++;
    fmt_printf("Features: %s mismatch (read 0x%08X, expected 0x%08X): block treated as absent\n", what,
               (unsigned)got, (unsigned)want);
}

/*
 * confirm_classifier -- the classifier advertised by CPU_CAPS answers its header.
 * Returns: 1 confirmed, 0 mismatch (logged).
 */
static int confirm_classifier(void)
{
    uint32_t id = rtlnet_reg_read32(RTLNET_PLAT_CLS_BASE, RTLNET_REG_ID);
    uint32_t ver = rtlnet_reg_read32(RTLNET_PLAT_CLS_BASE, RTLNET_REG_VERSION);

    if (id != RTLNET_CLS_ID_VALUE) {
        fail_block("classifier ID", id, RTLNET_CLS_ID_VALUE);
        return 0;
    }
    if (ver != RTLNET_CLS_VERSION_VALUE) {
        fail_block("classifier VERSION", ver, RTLNET_CLS_VERSION_VALUE);
        return 0;
    }
    return 1;
}

/*
 * confirm_offload -- the offload advertised by CPU_CAPS answers its header and
 * its CAPS agree with bits 17 / 18.
 * Returns: 1 confirmed, 0 mismatch (logged).
 */
static int confirm_offload(void)
{
    uint32_t id = rtlnet_reg_read32(RTLNET_PLAT_TXO_BASE, RTLNET_REG_ID);
    uint32_t ver = rtlnet_reg_read32(RTLNET_PLAT_TXO_BASE, RTLNET_REG_VERSION);
    uint32_t caps;

    if (id != RTLNET_TXO_ID_VALUE) {
        fail_block("checksum offload ID", id, RTLNET_TXO_ID_VALUE);
        return 0;
    }
    if (ver != RTLNET_TXO_VERSION_VALUE) {
        fail_block("checksum offload VERSION", ver, RTLNET_TXO_VERSION_VALUE);
        return 0;
    }
    if (rtlnet_tcp_offload_init(&g_txo, RTLNET_PLAT_TXO_BASE) != RTLNET_TXO_OK) {
        fail_block("checksum offload init", 0u, 1u);
        return 0;
    }
    caps = g_txo.caps;
    g_feat.block_caps = caps;
    if (((caps & RTLNET_TXO_CAPS_TX_PRESENT) != 0u) != (g_feat.tx_advertised != 0)) {
        fail_block("checksum offload CAPS.TX_PRESENT against CPU_CAPS bit 17", caps & RTLNET_TXO_CAPS_TX_PRESENT,
                   g_feat.tx_advertised ? RTLNET_TXO_CAPS_TX_PRESENT : 0u);
        return 0;
    }
    if (((caps & RTLNET_TXO_CAPS_RX_PRESENT) != 0u) != (g_feat.rx_advertised != 0)) {
        fail_block("checksum offload CAPS.RX_PRESENT against CPU_CAPS bit 18", caps & RTLNET_TXO_CAPS_RX_PRESENT,
                   g_feat.rx_advertised ? RTLNET_TXO_CAPS_RX_PRESENT : 0u);
        return 0;
    }
    return 1;
}

/*
 * rtlnet_features_discover -- find out which CPU-path blocks the bitstream has.
 *
 * Steps (once at boot; a second call is ignored):
 *   1. Wrapper ID and VERSION.
 *   2. CAPS.CPU_PATH_PRESENT.
 *   3. CPU_CAPS feature bits.
 *   4. For each advertised block, its own header; a mismatch logs an error
 *      and the block counts as absent.
 * Returns: nothing; the result is rtlnet_features().
 */
void rtlnet_features_discover(void)
{
    uint32_t feat;

    if (g_feat.discovered) {
        return;
    }
    memset(&g_feat, 0, sizeof(g_feat));
    memset(&g_fc, 0, sizeof(g_fc));
    g_txo_ok = 0;
    g_feat.discovered = 1;
    g_feat.wrapper_ok = (rtlnet_eth_protocol_probe(RTLNET_PLAT_PROT_BASE) == RTLNET_PROTO_OK) ? 1 : 0;
    if (!g_feat.wrapper_ok) {
        return;
    }
    g_feat.cpu_path = rtlnet_eth_protocol_cpu_path_present(RTLNET_PLAT_PROT_BASE) ? 1 : 0;
    if (!g_feat.cpu_path) {
        return;
    }
    g_feat.cpu_caps = rtlnet_reg_read32(RTLNET_PLAT_PROT_BASE, RTLNET_PROTO_REG_CPU_CAPS);
    feat = rtlnet_eth_protocol_get_cpu_features(RTLNET_PLAT_PROT_BASE);
    g_feat.cls_advertised = ((feat & RTLNET_PROTO_CPU_CAPS_CLASSIFIER) != 0u) ? 1 : 0;
    g_feat.tx_advertised = ((feat & RTLNET_PROTO_CPU_CAPS_OFFLOAD_TX) != 0u) ? 1 : 0;
    g_feat.rx_advertised = ((feat & RTLNET_PROTO_CPU_CAPS_OFFLOAD_RX) != 0u) ? 1 : 0;
    if (g_feat.cls_advertised) {
        g_feat.cls_present = confirm_classifier();
    }
    if (g_feat.tx_advertised || g_feat.rx_advertised) {
        if (confirm_offload()) {
            g_feat.tx_present = g_feat.tx_advertised;
            g_feat.rx_present = g_feat.rx_advertised;
            g_txo_ok = 1;
            feat_discovered();
        }
    }
}

/*
 * rtlnet_features_rediscover -- run the discovery again (the harness changes
 * the bitstream under it; the firmware itself discovers once).
 * Returns: nothing.
 */
void rtlnet_features_rediscover(void)
{
    g_feat.discovered = 0;
    rtlnet_features_discover();
}

/*
 * rtlnet_features -- the discovery result.
 * Returns: pointer to it (all zero before rtlnet_features_discover).
 */
const rtlnet_features_t *rtlnet_features(void)
{
    return &g_feat;
}

/*
 * rtlnet_offload_supported -- CTRL bits the build has, from the confirmed
 * discovery and the core's CAPS: tx_ip needs the IPv4 insert, tx_l4 needs the
 * TCP and UDP insert, rx needs the receive path.
 * Returns: mask of RTLNET_OFFLOAD_* bits.
 */
uint32_t rtlnet_offload_supported(void)
{
    uint32_t m = 0u;

    if (!g_txo_ok) {
        return 0u;
    }
    if (g_feat.tx_present && g_txo.ins_ip != 0u) {
        m |= RTLNET_OFFLOAD_TX_IP;
    }
    if (g_feat.tx_present && g_txo.ins_tcp != 0u && g_txo.ins_udp != 0u) {
        m |= RTLNET_OFFLOAD_TX_L4;
    }
    if (g_feat.rx_present) {
        m |= RTLNET_OFFLOAD_RX;
    }
    return m;
}

/*
 * rtlnet_offload_flags_for -- the lwIP checksum flags for a CTRL value.
 * tx_ip clears GEN_IP, tx_l4 clears GEN_TCP and GEN_UDP, and rx_csum clears
 * CHECK_IP / CHECK_TCP / CHECK_UDP only when rx_checks_off says the receive
 * trailers are established. The ICMP flags stay set: ICMP is not offloaded.
 * Returns: the flag word for NETIF_SET_CHECKSUM_CTRL.
 */
uint32_t rtlnet_offload_flags_for(uint32_t ctrl, int rx_checks_off)
{
    uint32_t f = RTLNET_CS_ENABLE_ALL;

    if ((ctrl & RTLNET_OFFLOAD_TX_IP) != 0u) {
        f &= ~RTLNET_CS_GEN_IP;
    }
    if ((ctrl & RTLNET_OFFLOAD_TX_L4) != 0u) {
        f &= ~(RTLNET_CS_GEN_TCP | RTLNET_CS_GEN_UDP);
    }
    if ((ctrl & RTLNET_OFFLOAD_RX) != 0u && rx_checks_off) {
        f &= ~(RTLNET_CS_CHECK_IP | RTLNET_CS_CHECK_TCP | RTLNET_CS_CHECK_UDP);
    }
    return f;
}

/*
 * push_flags -- set the lwIP flags for a CTRL value.
 * Returns: nothing.
 */
static void push_flags(uint32_t ctrl)
{
    g_st.flags = rtlnet_offload_flags_for(ctrl, g_st.rx_state == RTLNET_RX_TRAILER_ON);
    rtlnet_lwip_set_checksum_ctrl(g_st.flags);
}

/*
 * write_ctrl -- write CTRL and read the value back.
 * Returns: RTLNET_OFFLOAD_OK, or RTLNET_OFFLOAD_ERR_IO when the read-back
 * differs from the request (*readback holds what the hardware reports).
 */
static int write_ctrl(uint32_t value, uint32_t *readback)
{
    int rc = rtlnet_tcp_offload_set_ctrl(&g_txo, value);

    *readback = 0u;
    (void)rtlnet_tcp_offload_get_ctrl(&g_txo, readback);
    g_st.ctrl = *readback;
    if (rc != RTLNET_TXO_OK) {
        g_st.io_errors++;
        return RTLNET_OFFLOAD_ERR_IO;
    }
    return RTLNET_OFFLOAD_OK;
}

/*
 * rtlnet_offload_apply -- bring the hardware CTRL and the lwIP flags to the
 * requested offloads, in the order that never leaves a frame without its
 * checksum.
 *
 * Steps:
 *   1. Mask the request by rtlnet_offload_supported(); read CTRL.
 *   2. Bits to turn off: TX bits first set the GEN flags (flags from the
 *      current CTRL without them), then wait for TX_IDLE (bounded); the RX bit
 *      first sets the CHECK flags. Then CTRL is written and read back.
 *   3. Bits to turn on: CTRL is written and read back.
 *   4. The receive trailer state follows the read-back RX bit; the lwIP
 *      flags are set from the read-back value (CHECK flags only once the
 *      first trailer has been seen).
 * Returns: RTLNET_OFFLOAD_OK, RTLNET_OFFLOAD_ERR_IO (read-back mismatch;
 * the flags follow the hardware), RTLNET_OFFLOAD_ERR_TIMEOUT (TX_IDLE did not
 * come: CTRL unchanged, GEN flags back on).
 */
int rtlnet_offload_apply(uint32_t want_mask)
{
    uint32_t sup = rtlnet_offload_supported();
    uint32_t want = want_mask & sup;
    uint32_t cur = 0u;
    uint32_t off;
    uint32_t on;
    uint32_t rb = 0u;
    int rc = RTLNET_OFFLOAD_OK;

    g_st.applies++;
    g_req = want_mask & RTLNET_OFFLOAD_ALL;
    g_st.want = want;
    if ((sup & RTLNET_OFFLOAD_RX) == 0u) {
        g_st.rx_state = RTLNET_RX_TRAILER_OFF;
    }
    if (sup == 0u) {
        g_st.ctrl = 0u;
        g_st.rx_state = RTLNET_RX_TRAILER_OFF;
        push_flags(0u);
        return RTLNET_OFFLOAD_OK;
    }
    (void)rtlnet_tcp_offload_get_ctrl(&g_txo, &cur);
    g_st.ctrl = cur;
    cur &= RTLNET_OFFLOAD_ALL;   /* the receive feature bits are not part of the checksum request */
    off = cur & ~want;
    on = want & ~cur;

    if (off != 0u) {
        uint32_t next = cur & ~off;
        rtlnet_rx_trailer_state_t s = g_st.rx_state;

        /* Flags first: software takes over before the hardware lets go. */
        if ((off & RTLNET_OFFLOAD_RX) != 0u) {
            feat_quiesce();   /* ACK coalescing and batching work on the trailer: off before it goes */
            g_st.rx_state = RTLNET_RX_TRAILER_DRAINING;
        }
        g_st.flags = rtlnet_offload_flags_for(next, g_st.rx_state == RTLNET_RX_TRAILER_ON);
        rtlnet_lwip_set_checksum_ctrl(g_st.flags);
        if ((off & (RTLNET_OFFLOAD_TX_IP | RTLNET_OFFLOAD_TX_L4)) != 0u) {
            if (rtlnet_tcp_offload_wait_tx_idle(&g_txo, RTLNET_OFFLOAD_IDLE_POLLS) != RTLNET_TXO_OK) {
                g_st.idle_timeouts++;
                g_st.rx_state = s;
                push_flags(cur);
                return RTLNET_OFFLOAD_ERR_TIMEOUT;
            }
        }
        rc = write_ctrl(next, &rb);
        cur = rb & RTLNET_OFFLOAD_ALL;
    }
    if (on != 0u && rc == RTLNET_OFFLOAD_OK) {
        rc = write_ctrl(cur | on, &rb);
        cur = rb & RTLNET_OFFLOAD_ALL;
    }
    if ((cur & RTLNET_OFFLOAD_RX) != 0u) {
        if (g_st.rx_state == RTLNET_RX_TRAILER_OFF || g_st.rx_state == RTLNET_RX_TRAILER_DRAINING) {
            g_st.rx_state = RTLNET_RX_TRAILER_ARMING;
        }
    } else if (g_st.rx_state == RTLNET_RX_TRAILER_ON || g_st.rx_state == RTLNET_RX_TRAILER_ARMING) {
        g_st.rx_state = RTLNET_RX_TRAILER_DRAINING;
    }
    push_flags(cur);
    return rc;
}

/*
 * rtlnet_offload_request -- what the last rtlnet_offload_apply (or the default,
 * everything) asked for, before masking by what is present.
 * Returns: mask of RTLNET_OFFLOAD_* bits.
 */
uint32_t rtlnet_offload_request(void)
{
    return g_req;
}

/*
 * rtlnet_offload_state -- the control state and the receive statistics.
 * Returns: pointer to it.
 */
const rtlnet_offload_state_t *rtlnet_offload_state(void)
{
    return &g_st;
}

/*
 * rtlnet_offload_rx_frame -- decide what to do with one received DMA transfer.
 *
 * Steps:
 *   1. State OFF: the transfer is the frame.
 *   2. Otherwise look for a valid trailer (marker, length consistent with the
 *      transfer): found, the first one in state ARMING makes the state ON and
 *      clears the CHECK flags; the policy of rtlnet_tcp_offload_rx_verdict
 *      gives the action and *frame_len is the trailer's frame length.
 *   3. Not found: ARMING and DRAINING deliver the transfer as a raw frame
 *      (DRAINING then ends: the hardware sends no more trailers); ON drops it.
 * Returns: the action; *frame_len is the number of frame bytes to deliver.
 */
rtlnet_rx_action_t rtlnet_offload_rx_frame(const uint8_t *buf, uint32_t xfer_len, uint32_t *frame_len)
{
    rtlnet_txo_trailer_t tr;

    *frame_len = xfer_len;
    if (g_st.rx_state == RTLNET_RX_TRAILER_OFF) {
        g_st.rx_raw++;
        return RTLNET_RXA_DELIVER_RAW;
    }
    if (rtlnet_tcp_offload_trailer_parse(buf, xfer_len, &tr) != RTLNET_TXO_OK) {
        if (g_st.rx_state == RTLNET_RX_TRAILER_ON) {
            g_st.rx_no_trailer++;
            return RTLNET_RXA_DROP_NO_TRAILER;
        }
        if (g_st.rx_state == RTLNET_RX_TRAILER_DRAINING) {
            g_st.rx_state = RTLNET_RX_TRAILER_OFF;
        }
        g_st.rx_raw++;
        return RTLNET_RXA_DELIVER_RAW;
    }
    g_st.rx_trailer_frames++;
    if (g_st.rx_state == RTLNET_RX_TRAILER_ARMING) {
        g_st.rx_state = RTLNET_RX_TRAILER_ON;
        push_flags(g_st.ctrl);
    }
    *frame_len = tr.frame_len;
    switch (rtlnet_tcp_offload_rx_verdict(&tr)) {
    case RTLNET_TXO_RX_DROP_BAD_IP:
        g_st.rx_drop_ip++;
        return RTLNET_RXA_DROP_BAD_IP;
    case RTLNET_TXO_RX_DROP_BAD_L4:
        g_st.rx_drop_l4++;
        return RTLNET_RXA_DROP_BAD_L4;
    case RTLNET_TXO_RX_PASS_VERIFIED:
        g_st.rx_verified++;
        return RTLNET_RXA_DELIVER_VERIFIED;
    default:
        g_st.rx_unverified++;
        return RTLNET_RXA_DELIVER_UNVERIFIED;
    }
}

/*
 * rtlnet_offload_counters -- the core's hardware counters.
 * Returns: RTLNET_TXO_OK, or an RTLNET_TXO_ERR_* code (core absent).
 */
int rtlnet_offload_counters(rtlnet_txo_counters_t *out)
{
    if (!g_txo_ok) {
        memset(out, 0, sizeof(*out));
        return RTLNET_TXO_ERR_NOT_INIT;
    }
    return rtlnet_tcp_offload_counters(&g_txo, out);
}

/*
 * rtlnet_offload_ctrl_now -- the core's CTRL register as it reads now.
 * Returns: RTLNET_TXO_OK, or RTLNET_TXO_ERR_NOT_INIT when the core is absent.
 */
int rtlnet_offload_ctrl_now(uint32_t *ctrl)
{
    if (!g_txo_ok) {
        *ctrl = 0u;
        return RTLNET_TXO_ERR_NOT_INIT;
    }
    return rtlnet_tcp_offload_get_ctrl(&g_txo, ctrl);
}

/*
 * rtlnet_offload_buffer_kb -- the TX frame buffer of the core in kilobytes (CAPS).
 * Returns: the size, 0 when the core is absent.
 */
uint32_t rtlnet_offload_buffer_kb(void)
{
    return g_txo_ok ? g_txo.tx_buf_kb : 0u;
}

/*
 * rtlnet_offload_status -- the core's STATUS register.
 * Returns: RTLNET_TXO_OK, or RTLNET_TXO_ERR_NOT_INIT when the core is absent.
 */
int rtlnet_offload_status(uint32_t *status)
{
    if (!g_txo_ok) {
        *status = 0u;
        return RTLNET_TXO_ERR_NOT_INIT;
    }
    return rtlnet_tcp_offload_get_status(&g_txo, status);
}

/*
 * rtlnet_offload_reset_stats -- zero the software receive statistics and the
 * hardware counters (the control state is kept).
 * Returns: nothing.
 */
void rtlnet_offload_reset_stats(void)
{
    g_st.rx_trailer_frames = 0u;
    g_st.rx_verified = 0u;
    g_st.rx_unverified = 0u;
    g_st.rx_drop_ip = 0u;
    g_st.rx_drop_l4 = 0u;
    g_st.rx_no_trailer = 0u;
    g_st.rx_raw = 0u;
    g_st.io_errors = 0u;
    g_st.idle_timeouts = 0u;
    if (g_txo_ok) {
        (void)rtlnet_tcp_offload_clear_counters(&g_txo);
    }
}

/*
 * rtlnet_offload_feat -- the receive features as configured.
 * Returns: pointer to the state (all zero without the features).
 */
const rtlnet_offload_feat_t *rtlnet_offload_feat(void)
{
    return &g_fc;
}

/*
 * feat_switch -- turn one receive feature on or off in CTRL (hardware order: configuration first, then the bit;
 * off: the bit, then wait for what the block holds).
 * Returns: RTLNET_OFFLOAD_OK, RTLNET_OFFLOAD_ERR_IO.
 */
static int feat_switch(uint32_t feat, uint32_t ctrl_bit, int on)
{
    uint32_t next = on ? (g_fc.on | feat) : (g_fc.on & ~feat);
    uint32_t bits = 0u;

    if ((next & RTLNET_OFFLOAD_FEAT_ACK) != 0u) {
        bits |= RTLNET_TXO_CTRL_ACK_COALESCE;
    }
    if ((next & RTLNET_OFFLOAD_FEAT_BATCH) != 0u) {
        bits |= RTLNET_TXO_CTRL_RX_BATCH;
    }
    (void)ctrl_bit;
    if (rtlnet_tcp_offload_set_features(&g_txo, bits) != RTLNET_TXO_OK) {
        g_st.io_errors++;
        return RTLNET_OFFLOAD_ERR_IO;
    }
    if (!on) {
        (void)rtlnet_tcp_offload_wait_features_idle(&g_txo, RTLNET_OFFLOAD_IDLE_POLLS);
    }
    g_fc.on = next;
    return RTLNET_OFFLOAD_OK;
}

/*
 * rtlnet_offload_ack_set -- ACK coalescing on or off, with the timer and the count limit.
 *
 * Steps:
 *   1. The build must have it (ERR_ABSENT); on needs rx offload on (ERR_NEED_RX): the feature works on the trailer.
 *   2. Timer (microseconds, 0..65535) and limit (0..255) written (RTLNET_OFFLOAD_KEEP keeps the current value).
 *   3. The CTRL bit follows; off waits until held ACKs have been forwarded.
 * Returns: RTLNET_OFFLOAD_OK, ERR_ABSENT, ERR_NEED_RX, ERR_ARG, ERR_IO.
 */
int rtlnet_offload_ack_set(int on, uint32_t timer_us, uint32_t limit)
{
    uint32_t ctrl = 0u;
    uint32_t t = (timer_us == RTLNET_OFFLOAD_KEEP) ? g_fc.ack_timer_us : timer_us;
    uint32_t l = (limit == RTLNET_OFFLOAD_KEEP) ? g_fc.ack_limit : limit;

    if ((g_fc.present & RTLNET_OFFLOAD_FEAT_ACK) == 0u) {
        return RTLNET_OFFLOAD_ERR_ABSENT;
    }
    if (t > 0xFFFFu || l > 0xFFu) {
        return RTLNET_OFFLOAD_ERR_ARG;
    }
    if (on) {
        (void)rtlnet_tcp_offload_get_ctrl(&g_txo, &ctrl);
        if ((ctrl & RTLNET_OFFLOAD_RX) == 0u) {
            return RTLNET_OFFLOAD_ERR_NEED_RX;
        }
        if (rtlnet_tcp_offload_ack_config(&g_txo, t, l) != RTLNET_TXO_OK) {
            g_st.io_errors++;
            return RTLNET_OFFLOAD_ERR_IO;
        }
        g_fc.ack_timer_us = t;
        g_fc.ack_limit = l;
    }
    return feat_switch(RTLNET_OFFLOAD_FEAT_ACK, RTLNET_TXO_CTRL_ACK_COALESCE, on);
}

/*
 * rtlnet_offload_batch_set -- receive batching on or off, with the timer, the frame limit and the byte limit.
 *
 * The byte limit is the size of the DMA buffer the netif arms: no transfer is longer. The netif switches its
 * buffers to that size first (rtlnet_netif_set_rx_batch); the CLI does both, in that order. Same steps and
 * results as rtlnet_offload_ack_set (max_frames 0..64, max_bytes one frame to 65535).
 * Returns: RTLNET_OFFLOAD_OK, ERR_ABSENT, ERR_NEED_RX, ERR_ARG, ERR_IO.
 */
int rtlnet_offload_batch_set(int on, uint32_t timer_us, uint32_t max_frames, uint32_t max_bytes)
{
    uint32_t ctrl = 0u;
    uint32_t t = (timer_us == RTLNET_OFFLOAD_KEEP) ? g_fc.bat_timer_us : timer_us;
    uint32_t f = (max_frames == RTLNET_OFFLOAD_KEEP) ? g_fc.bat_frames : max_frames;
    uint32_t b = (max_bytes == RTLNET_OFFLOAD_KEEP) ? g_fc.bat_bytes : max_bytes;

    if ((g_fc.present & RTLNET_OFFLOAD_FEAT_BATCH) == 0u) {
        return RTLNET_OFFLOAD_ERR_ABSENT;
    }
    if (on) {
        (void)rtlnet_tcp_offload_get_ctrl(&g_txo, &ctrl);
        if ((ctrl & RTLNET_OFFLOAD_RX) == 0u) {
            return RTLNET_OFFLOAD_ERR_NEED_RX;
        }
        if (rtlnet_tcp_offload_batch_config(&g_txo, t, f, b) != RTLNET_TXO_OK) {
            g_st.io_errors++;
            return RTLNET_OFFLOAD_ERR_ARG;
        }
        g_fc.bat_timer_us = t;
        g_fc.bat_frames = f;
        g_fc.bat_bytes = b;
    }
    return feat_switch(RTLNET_OFFLOAD_FEAT_BATCH, RTLNET_TXO_CTRL_RX_BATCH, on);
}

/*
 * rtlnet_offload_feat_counters -- the ACK coalescer and batcher counters of the core.
 * Returns: RTLNET_TXO_OK, or RTLNET_TXO_ERR_NOT_INIT when the core is absent.
 */
int rtlnet_offload_feat_counters(rtlnet_txo_feat_counters_t *out)
{
    if (!g_txo_ok) {
        memset(out, 0, sizeof(*out));
        return RTLNET_TXO_ERR_NOT_INIT;
    }
    return rtlnet_tcp_offload_feature_counters(&g_txo, out);
}
