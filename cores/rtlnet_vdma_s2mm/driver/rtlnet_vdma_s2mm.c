/*
 * rtlnet_vdma_s2mm.c -- RTLNet video write DMA driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only code that reads or writes rtlnet_vdma_s2mm registers. Register map and function rules:
 * rtlnet_vdma_s2mm.h. No driver state: the hardware holds every value.
 */
#include "rtlnet_vdma_s2mm.h"
#include "rtlnet_mmio.h"

#include <stddef.h>   /* NULL */

/*
 * rtlnet_vdma_s2mm_probe -- identify the core and read its build parameters
 * Returns: RTLNET_S2MM_OK when ID and VERSION match, RTLNET_S2MM_ERR_ARG otherwise.
 */
int rtlnet_vdma_s2mm_probe(uintptr_t base, rtlnet_vdma_s2mm_caps_t *caps)
{
    uint32_t c;

    if (rtlnet_reg_read32(base, RTLNET_REG_ID) != RTLNET_S2MM_ID_VALUE) {
        return RTLNET_S2MM_ERR_ARG;
    }
    if (rtlnet_reg_read32(base, RTLNET_REG_VERSION) != RTLNET_S2MM_VERSION_VALUE) {
        return RTLNET_S2MM_ERR_ARG;
    }
    if (caps != NULL) {
        c = rtlnet_reg_read32(base, RTLNET_REG_CAPS);
        caps->max_burst_beats = c & RTLNET_S2MM_CAPS_BURST_MASK;
        caps->bytes_per_beat  = (c >> RTLNET_S2MM_CAPS_BYTES_SHIFT) & RTLNET_S2MM_CAPS_BYTES_MASK;
        caps->addr_bits       = (c >> RTLNET_S2MM_CAPS_ADDR_SHIFT) & RTLNET_S2MM_CAPS_ADDR_MASK;
    }
    return RTLNET_S2MM_OK;
}

/*
 * rtlnet_vdma_s2mm_read_state -- read the control, status and counter registers
 * Returns: RTLNET_S2MM_OK, or RTLNET_S2MM_ERR_ARG on NULL st.
 */
int rtlnet_vdma_s2mm_read_state(uintptr_t base, rtlnet_vdma_s2mm_state_t *st)
{
    if (st == NULL) {
        return RTLNET_S2MM_ERR_ARG;
    }
    st->ctrl           = rtlnet_reg_read32(base, RTLNET_S2MM_REG_CTRL);
    st->status         = rtlnet_reg_read32(base, RTLNET_S2MM_REG_STATUS);
    st->stride         = rtlnet_reg_read32(base, RTLNET_S2MM_REG_STRIDE);
    st->frames_ok      = rtlnet_reg_read32(base, RTLNET_S2MM_REG_FRAMES_OK);
    st->frames_bad     = rtlnet_reg_read32(base, RTLNET_S2MM_REG_FRAMES_BAD);
    st->frames_dropped = rtlnet_reg_read32(base, RTLNET_S2MM_REG_FRAMES_DROPPED);
    st->bursts         = rtlnet_reg_read32(base, RTLNET_S2MM_REG_BURSTS);
    st->beats          = rtlnet_reg_read32(base, RTLNET_S2MM_REG_BEATS);
    st->last_base      = rtlnet_reg_read32(base, RTLNET_S2MM_REG_LAST_BASE);
    return RTLNET_S2MM_OK;
}

/* rtlnet_vdma_s2mm_enable -- set or clear CTRL.ENABLE; a disabled core discards the stream. */
int rtlnet_vdma_s2mm_enable(uintptr_t base, int on)
{
    rtlnet_reg_write32(base, RTLNET_S2MM_REG_CTRL, (on != 0) ? RTLNET_S2MM_CTRL_ENABLE : 0u);
    return RTLNET_S2MM_OK;
}

/*
 * rtlnet_vdma_s2mm_set_stride -- set the line stride in bytes
 * Steps:
 *   1. Reject a value that is not a multiple of the beat size (the core would drop every frame).
 *   2. Write STRIDE; 0 selects packed lines.
 * Returns: RTLNET_S2MM_OK or RTLNET_S2MM_ERR_ARG.
 */
int rtlnet_vdma_s2mm_set_stride(uintptr_t base, uint32_t stride)
{
    if ((stride % RTLNET_S2MM_BEAT_BYTES) != 0u) {
        return RTLNET_S2MM_ERR_ARG;
    }
    rtlnet_reg_write32(base, RTLNET_S2MM_REG_STRIDE, stride);
    return RTLNET_S2MM_OK;
}

/* rtlnet_vdma_s2mm_clear -- clear every counter (self-clearing CTRL bit; ENABLE keeps its value). */
void rtlnet_vdma_s2mm_clear(uintptr_t base)
{
    uint32_t ctrl = rtlnet_reg_read32(base, RTLNET_S2MM_REG_CTRL) & RTLNET_S2MM_CTRL_ENABLE;
    rtlnet_reg_write32(base, RTLNET_S2MM_REG_CTRL, ctrl | RTLNET_S2MM_CTRL_CNT_CLEAR);
}

/* rtlnet_vdma_s2mm_err_clear -- clear the sticky error flags (write 1). */
void rtlnet_vdma_s2mm_err_clear(uintptr_t base)
{
    rtlnet_reg_write32(base, RTLNET_S2MM_REG_STATUS, RTLNET_S2MM_STATUS_ERR_MASK);
}
