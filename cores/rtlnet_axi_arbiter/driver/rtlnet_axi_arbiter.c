/*
 * rtlnet_axi_arbiter.c -- RTLNet AXI4 arbiter driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that reads or writes rtlnet_axi_arbiter registers.
 * Register map and function rules: rtlnet_axi_arbiter.h. No driver state: the
 * hardware holds the counters and the error flag.
 */
#include "rtlnet_axi_arbiter.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

/*
 * decode_caps -- split the CAPS word into its fields
 * Steps:
 *   1. Shift and mask each field.
 * Returns: nothing.
 */
static void decode_caps(uint32_t caps, rtlnet_axi_arbiter_caps_t *out)
{
    out->num_masters     = caps & RTLNET_ARB_CAPS_MASTERS_MASK;
    out->bytes_per_beat  = (caps >> RTLNET_ARB_CAPS_BYTES_SHIFT) & RTLNET_ARB_CAPS_BYTES_MASK;
    out->id_w            = (caps >> RTLNET_ARB_CAPS_ID_W_SHIFT) & RTLNET_ARB_CAPS_ID_W_MASK;
    out->max_outstanding = (caps >> RTLNET_ARB_CAPS_MAXOUT_SHIFT) & RTLNET_ARB_CAPS_MAXOUT_MASK;
    out->high_prio_mask  = (caps >> RTLNET_ARB_CAPS_HPMASK_SHIFT) & RTLNET_ARB_CAPS_HPMASK_MASK;
}

/*
 * rtlnet_axi_arbiter_probe -- identify the core and read its build parameters
 * Steps:
 *   1. Check ID and VERSION.
 *   2. Decode CAPS into caps when caps is not NULL.
 * Returns: 0 when present and matching, -1 otherwise.
 */
int rtlnet_axi_arbiter_probe(uintptr_t base, rtlnet_axi_arbiter_caps_t *caps)
{
    if (rtlnet_reg_read32(base, RTLNET_REG_ID) != RTLNET_ARB_ID_VALUE) {
        return -1;
    }
    if (rtlnet_reg_read32(base, RTLNET_REG_VERSION) != RTLNET_ARB_VERSION_VALUE) {
        return -1;
    }
    if (caps != NULL) {
        decode_caps(rtlnet_reg_read32(base, RTLNET_REG_CAPS), caps);
    }
    return 0;
}

/*
 * rtlnet_axi_arbiter_read_counters -- read the six counters of one master
 * Steps:
 *   1. Validate the pointer.
 *   2. Reject a master index at or above NUM_MASTERS (from CAPS): the window
 *      would read 0, which hides the mistake.
 *   3. Read each counter at the master's window offset.
 * Returns: 0 on success, -1 on NULL c or an unavailable master.
 */
int rtlnet_axi_arbiter_read_counters(uintptr_t base, uint32_t master, rtlnet_axi_arbiter_counters_t *c)
{
    rtlnet_axi_arbiter_caps_t caps;
    uint32_t                  win;

    if (c == NULL) {
        return -1;
    }
    decode_caps(rtlnet_reg_read32(base, RTLNET_REG_CAPS), &caps);
    if (master >= caps.num_masters) {
        return -1;
    }
    win = RTLNET_ARB_MASTER_BASE + (master * RTLNET_ARB_MASTER_STRIDE);
    c->aw_bursts   = rtlnet_reg_read32(base, win + RTLNET_ARB_CNT_AW_BURSTS);
    c->ar_bursts   = rtlnet_reg_read32(base, win + RTLNET_ARB_CNT_AR_BURSTS);
    c->w_beats     = rtlnet_reg_read32(base, win + RTLNET_ARB_CNT_W_BEATS);
    c->r_beats     = rtlnet_reg_read32(base, win + RTLNET_ARB_CNT_R_BEATS);
    c->errors      = rtlnet_reg_read32(base, win + RTLNET_ARB_CNT_ERRORS);
    c->wait_cycles = rtlnet_reg_read32(base, win + RTLNET_ARB_CNT_WAIT_CYCLES);
    return 0;
}

/*
 * rtlnet_axi_arbiter_clear -- zero every counter of every master
 * Steps:
 *   1. Write the CNT_CLEAR pulse to CTRL (CTRL holds no other state).
 * Returns: nothing.
 */
void rtlnet_axi_arbiter_clear(uintptr_t base)
{
    rtlnet_reg_write32(base, RTLNET_ARB_REG_CTRL, RTLNET_ARB_CTRL_CNT_CLEAR);
}

/*
 * rtlnet_axi_arbiter_err_status -- read the error flag and the in-flight bits
 * Steps:
 *   1. Validate the pointer; decode STATUS.
 * Returns: 0 on success, -1 on NULL st.
 */
int rtlnet_axi_arbiter_err_status(uintptr_t base, rtlnet_axi_arbiter_status_t *st)
{
    uint32_t v;

    if (st == NULL) {
        return -1;
    }
    v = rtlnet_reg_read32(base, RTLNET_ARB_REG_STATUS);
    st->err     = (v & RTLNET_ARB_STATUS_ERR) != 0u;
    st->wr_busy = (v & RTLNET_ARB_STATUS_WR_BUSY) != 0u;
    st->rd_busy = (v & RTLNET_ARB_STATUS_RD_BUSY) != 0u;
    return 0;
}

/*
 * rtlnet_axi_arbiter_err_clear -- clear the sticky error flag
 * Steps:
 *   1. Write 1 to STATUS.ERR (the in-flight bits are read-only). An illegal
 *      burst in the same clock keeps the flag set.
 * Returns: nothing.
 */
void rtlnet_axi_arbiter_err_clear(uintptr_t base)
{
    rtlnet_reg_write32(base, RTLNET_ARB_REG_STATUS, RTLNET_ARB_STATUS_ERR);
}
