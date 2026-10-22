/*
 * rtlnet_dhcp.c -- RTLNet DHCP client leaf driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that touches the rtlnet_dhcp registers. It issues the
 * leaf's commands (start, stop, renew now, the AUTO intent flag, counter
 * clear) and reads the lease, the client state and the counters into the
 * structures of rtlnet_dhcp.h. The leaf runs the protocol by itself; nothing
 * here waits on hardware, so no loop needs a timeout bound.
 *
 * CTRL rule: every CTRL write also writes the AUTO level (bit 2), so each
 * command write carries the current AUTO value read back from CTRL.
 */
#include "rtlnet_dhcp.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

/*
 * ctrl_command -- write one CTRL pulse while keeping the AUTO level
 * Steps:
 *   1. Read CTRL (pulse bits read 0, AUTO reads its level).
 *   2. Write the AUTO level together with the pulse bits.
 * Returns: nothing.
 */
static void ctrl_command(uintptr_t base, uint32_t pulse_bits)
{
    uint32_t keep = rtlnet_reg_read32(base, RTLNET_DHCP_REG_CTRL) & RTLNET_DHCP_CTRL_AUTO;

    rtlnet_reg_write32(base, RTLNET_DHCP_REG_CTRL, keep | pulse_bits);
}

/*
 * rtlnet_dhcp_probe -- check that a DHCP leaf answers at base
 * Steps:
 *   1. Read ID and VERSION.
 *   2. Compare both with the values of this header.
 * Returns: RTLNET_DHCP_OK on a match, RTLNET_DHCP_ERR_ID otherwise.
 */
int rtlnet_dhcp_probe(uintptr_t base)
{
    if (rtlnet_reg_read32(base, RTLNET_DHCP_REG_ID) != RTLNET_DHCP_ID_VALUE) {
        return RTLNET_DHCP_ERR_ID;
    }
    if (rtlnet_reg_read32(base, RTLNET_DHCP_REG_VERSION) != RTLNET_DHCP_VERSION_VALUE) {
        return RTLNET_DHCP_ERR_ID;
    }
    return RTLNET_DHCP_OK;
}

/*
 * rtlnet_dhcp_start -- start or restart an acquisition (new xid, DISCOVER)
 * Steps:
 *   1. Pulse CTRL.START, keeping AUTO.
 * Returns: nothing. A held lease stays valid until the new ACK or its expiry.
 */
void rtlnet_dhcp_start(uintptr_t base)
{
    ctrl_command(base, RTLNET_DHCP_CTRL_START);
}

/*
 * rtlnet_dhcp_stop -- drop the lease and return the client to INIT
 * Steps:
 *   1. Pulse CTRL.STOP, keeping AUTO. The leaf sends a DHCPRELEASE when a
 *      lease was held.
 * Returns: nothing.
 */
void rtlnet_dhcp_stop(uintptr_t base)
{
    ctrl_command(base, RTLNET_DHCP_CTRL_STOP);
}

/*
 * rtlnet_dhcp_renew_now -- renew a bound lease at once instead of at T1
 * Steps:
 *   1. Pulse CTRL.RENEW_NOW, keeping AUTO (ignored unless BOUND).
 * Returns: nothing.
 */
void rtlnet_dhcp_renew_now(uintptr_t base)
{
    ctrl_command(base, RTLNET_DHCP_CTRL_RENEW_NOW);
}

/*
 * rtlnet_dhcp_set_auto -- record the firmware's auto-start intent
 * Steps:
 *   1. Write CTRL with only the AUTO level (no pulse).
 * Returns: nothing. The flag has no hardware effect; the link monitor reads
 * it to decide whether to call rtlnet_dhcp_start after link-up.
 */
void rtlnet_dhcp_set_auto(uintptr_t base, int on)
{
    rtlnet_reg_write32(base, RTLNET_DHCP_REG_CTRL, on ? RTLNET_DHCP_CTRL_AUTO : 0u);
}

/*
 * rtlnet_dhcp_get_auto -- read the auto-start intent flag
 * Returns: 1 when AUTO is set, 0 otherwise.
 */
int rtlnet_dhcp_get_auto(uintptr_t base)
{
    return (rtlnet_reg_read32(base, RTLNET_DHCP_REG_CTRL) & RTLNET_DHCP_CTRL_AUTO) ? 1 : 0;
}

/*
 * rtlnet_dhcp_clear_counters -- zero the seven counters
 * Steps:
 *   1. Pulse CTRL.CNT_CLEAR, keeping AUTO.
 * Returns: nothing.
 */
void rtlnet_dhcp_clear_counters(uintptr_t base)
{
    ctrl_command(base, RTLNET_DHCP_CTRL_CNT_CLEAR);
}

/*
 * rtlnet_dhcp_state -- current client state code
 * Returns: one of RTLNET_DHCP_STATE_*.
 */
uint32_t rtlnet_dhcp_state(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_DHCP_REG_STATUS) & RTLNET_DHCP_STATUS_STATE_MASK;
}

/*
 * rtlnet_dhcp_read_lease -- snapshot of the state and the lease registers
 * Steps:
 *   1. Read STATUS and CTRL for state, bound, fail, enable and AUTO.
 *   2. Read the five lease registers, the elapsed time and the xid.
 * Returns: RTLNET_DHCP_OK, or RTLNET_DHCP_ERR_ARG for a null pointer. The
 * reads are not atomic against an ACK; the caller re-reads when STATUS.BOUND
 * changed between two calls.
 */
int rtlnet_dhcp_read_lease(uintptr_t base, rtlnet_dhcp_lease_t *lease)
{
    uint32_t status;

    if (lease == NULL) {
        return RTLNET_DHCP_ERR_ARG;
    }
    status = rtlnet_reg_read32(base, RTLNET_DHCP_REG_STATUS);
    lease->state = status & RTLNET_DHCP_STATUS_STATE_MASK;
    lease->bound = (status & RTLNET_DHCP_STATUS_BOUND) ? 1 : 0;
    lease->fail = (status & RTLNET_DHCP_STATUS_FAIL) ? 1 : 0;
    lease->enabled = (status & RTLNET_DHCP_STATUS_ENABLE) ? 1 : 0;
    lease->auto_start = rtlnet_dhcp_get_auto(base);
    lease->lease_ip = rtlnet_reg_read32(base, RTLNET_DHCP_REG_LEASE_IP);
    lease->lease_mask = rtlnet_reg_read32(base, RTLNET_DHCP_REG_LEASE_MASK);
    lease->lease_router = rtlnet_reg_read32(base, RTLNET_DHCP_REG_LEASE_ROUTER);
    lease->lease_server = rtlnet_reg_read32(base, RTLNET_DHCP_REG_LEASE_SERVER);
    lease->lease_time_s = rtlnet_reg_read32(base, RTLNET_DHCP_REG_LEASE_TIME_S);
    lease->lease_elapsed_s = rtlnet_reg_read32(base, RTLNET_DHCP_REG_LEASE_ELAPSED_S);
    lease->xid = rtlnet_reg_read32(base, RTLNET_DHCP_REG_XID);
    return RTLNET_DHCP_OK;
}

/*
 * rtlnet_dhcp_read_counters -- read the seven counters
 * Returns: RTLNET_DHCP_OK, or RTLNET_DHCP_ERR_ARG for a null pointer.
 */
int rtlnet_dhcp_read_counters(uintptr_t base, rtlnet_dhcp_counters_t *cnt)
{
    if (cnt == NULL) {
        return RTLNET_DHCP_ERR_ARG;
    }
    cnt->discovers_sent = rtlnet_reg_read32(base, RTLNET_DHCP_REG_DISCOVERS_SENT);
    cnt->offers_rx = rtlnet_reg_read32(base, RTLNET_DHCP_REG_OFFERS_RX);
    cnt->requests_sent = rtlnet_reg_read32(base, RTLNET_DHCP_REG_REQUESTS_SENT);
    cnt->acks_rx = rtlnet_reg_read32(base, RTLNET_DHCP_REG_ACKS_RX);
    cnt->naks_rx = rtlnet_reg_read32(base, RTLNET_DHCP_REG_NAKS_RX);
    cnt->leases_lost = rtlnet_reg_read32(base, RTLNET_DHCP_REG_LEASES_LOST);
    cnt->releases_sent = rtlnet_reg_read32(base, RTLNET_DHCP_REG_RELEASES_SENT);
    return RTLNET_DHCP_OK;
}

/*
 * rtlnet_dhcp_state_name -- printable name of a state code, for the CLI
 * Returns: a constant string; "?" for an unknown code.
 */
const char *rtlnet_dhcp_state_name(uint32_t state)
{
    static const char *const names[] = {
        "INIT", "SELECTING", "REQUESTING", "BOUND", "RENEWING", "FAIL"
    };

    if (state >= (uint32_t)(sizeof(names) / sizeof(names[0]))) {
        return "?";
    }
    return names[state];
}
