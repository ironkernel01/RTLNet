/*
 * rtlnet_axi_arbiter.h -- RTLNet AXI4 arbiter driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one file pair (rtlnet_axi_arbiter.h / .c) that touches the
 * registers of the rtlnet_axi_arbiter core. Every register offset and bit of
 * the core is defined here, once; hdl/rtlnet_axi_arbiter_regs.sv mirrors them
 * as localparams with a pointer to this header. Change both in the same
 * commit: a mismatch reads the wrong master's counter or clears the wrong
 * flag.
 *
 * The base address (the core's 4 KiB window) is passed in by the platform
 * layer. Register access goes only through rtlnet_mmio.h.
 *
 * Behaviour. The arbiter shares one AXI4 memory-controller port between up to
 * eight masters. Each master has traffic counters (bursts and beats forwarded
 * to the memory controller, illegal bursts answered with SLVERR, and clocks
 * spent waiting for a grant). An illegal burst (not INCR, not full-width, or
 * crossing a 4 KiB boundary; a master in NARROW_MASK may use any size up to the
 * full width, the boundary check then uses the burst's own size; a master in
 * WRAP_MASK may also issue a WRAP burst of 2, 4, 8 or 16 beats at an address
 * aligned to the size, and any other WRAP is illegal) sets the sticky STATUS.ERR flag, which stays set
 * until software clears it by writing 1 to it; the core's err_irq output is the
 * level of that flag. The first illegal burst after a clear is also held in the
 * read-only capture registers (direction, master, address, len, size, burst type and
 * the failed rule), until STATUS.ERR or the counters are cleared.
 *
 * This header holds the register map, the types and the function rules;
 * rtlnet_axi_arbiter.c holds the per-function commentary.
 */
#ifndef RTLNET_AXI_ARBITER_H
#define RTLNET_AXI_ARBITER_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#define RTLNET_ARB_ID_VALUE               0x41524254u   /* "ARBT" */
#define RTLNET_ARB_VERSION_VALUE          0x11092026u
/* Revision 11-09-2026: NARROW register and narrow_mask in the caps struct; WRAP register, wrap_mask, illegal-burst capture. */

/* Registers (ID, VERSION, CAPS at RTLNET_REG_* of rtlnet_mmio.h). */
#define RTLNET_ARB_REG_CTRL               0x00Cu   /* WO command bits, reads 0 */
#define RTLNET_ARB_REG_STATUS             0x010u   /* RO flags, ERR write-1-to-clear */
#define RTLNET_ARB_REG_NARROW             0x014u   /* RO, [7:0] NARROW_MASK: masters allowed narrow transfers */
#define RTLNET_ARB_REG_WRAP               0x018u   /* RO, [7:0] WRAP_MASK: masters allowed legal WRAP bursts */
#define RTLNET_ARB_REG_CAP_INFO           0x040u   /* RO, first illegal burst, fields below; 0 when none captured */
#define RTLNET_ARB_REG_CAP_ADDR           0x044u   /* RO, captured address [31:0] */
#define RTLNET_ARB_REG_CAP_ADDR_HI        0x048u   /* RO, captured address [63:32] (0 for a 32-bit address bus) */

/* CAP_INFO fields. Cleared by STATUS.ERR (write 1) or CTRL.CNT_CLEAR; set by the first illegal burst after that. */
#define RTLNET_ARB_CAP_VALID              (1u << 0)     /* a burst is captured */
#define RTLNET_ARB_CAP_IS_READ            (1u << 1)     /* 0: AW (write), 1: AR (read) */
#define RTLNET_ARB_CAP_MASTER_SHIFT       2u            /* [4:2] master index */
#define RTLNET_ARB_CAP_MASTER_MASK        0x7u
#define RTLNET_ARB_CAP_SIZE_SHIFT         5u            /* [7:5] AxSIZE */
#define RTLNET_ARB_CAP_SIZE_MASK          0x7u
#define RTLNET_ARB_CAP_LEN_SHIFT          8u            /* [15:8] AxLEN */
#define RTLNET_ARB_CAP_LEN_MASK           0xFFu
#define RTLNET_ARB_CAP_BURST_SHIFT        16u           /* [17:16] AxBURST (0 FIXED, 1 INCR, 2 WRAP) */
#define RTLNET_ARB_CAP_BURST_MASK         0x3u
#define RTLNET_ARB_CAP_FAIL_SHIFT         18u           /* [20:18] failed rules, see RTLNET_ARB_FAIL_* */
#define RTLNET_ARB_CAP_FAIL_MASK          0x7u
#define RTLNET_ARB_FAIL_BURST             0x1u          /* burst type (not INCR, or a WRAP that is not allowed) */
#define RTLNET_ARB_FAIL_SIZE              0x2u          /* size not allowed for the master */
#define RTLNET_ARB_FAIL_4K                0x4u          /* crosses a 4 KiB boundary */

/* CAPS fields. */
#define RTLNET_ARB_CAPS_MASTERS_MASK      0x0000000Fu   /* [3:0] NUM_MASTERS */
#define RTLNET_ARB_CAPS_BYTES_SHIFT       4u            /* [11:4] DATA_W / 8, bytes per beat */
#define RTLNET_ARB_CAPS_BYTES_MASK        0xFFu
#define RTLNET_ARB_CAPS_ID_W_SHIFT        12u           /* [15:12] ID_W */
#define RTLNET_ARB_CAPS_ID_W_MASK         0xFu
#define RTLNET_ARB_CAPS_MAXOUT_SHIFT      16u           /* [23:16] MAX_OUTSTANDING */
#define RTLNET_ARB_CAPS_MAXOUT_MASK       0xFFu
#define RTLNET_ARB_CAPS_HPMASK_SHIFT      24u           /* [31:24] HIGH_PRIO_MASK */
#define RTLNET_ARB_CAPS_HPMASK_MASK       0xFFu

/* CTRL bits. */
#define RTLNET_ARB_CTRL_CNT_CLEAR         (1u << 16)    /* self-clearing, clears every counter */

/* STATUS bits. */
#define RTLNET_ARB_STATUS_ERR             (1u << 0)     /* sticky; write 1 to clear */
#define RTLNET_ARB_STATUS_WR_BUSY         (1u << 1)     /* a write is accepted and not yet answered */
#define RTLNET_ARB_STATUS_RD_BUSY         (1u << 2)     /* a read is accepted and not yet answered */

/* Per-master window: base + master * stride + counter offset. */
#define RTLNET_ARB_MASTER_BASE            0x100u
#define RTLNET_ARB_MASTER_STRIDE          0x20u
#define RTLNET_ARB_MAX_MASTERS            8u
#define RTLNET_ARB_CNT_AW_BURSTS          0x00u   /* RO, write bursts forwarded to the memory controller */
#define RTLNET_ARB_CNT_AR_BURSTS          0x04u   /* RO, read bursts forwarded */
#define RTLNET_ARB_CNT_W_BEATS            0x08u   /* RO, write data beats forwarded */
#define RTLNET_ARB_CNT_R_BEATS            0x0Cu   /* RO, read data beats returned by the memory controller */
#define RTLNET_ARB_CNT_ERRORS             0x10u   /* RO, illegal bursts answered with SLVERR */
#define RTLNET_ARB_CNT_WAIT_CYCLES        0x14u   /* RO, clocks with awvalid or arvalid high and not granted */

typedef struct {
    uint32_t num_masters;
    uint32_t bytes_per_beat;
    uint32_t id_w;
    uint32_t max_outstanding;
    uint32_t high_prio_mask;
    uint32_t narrow_mask;   /* masters whose bursts may use sizes below the full width */
    uint32_t wrap_mask;     /* masters whose WRAP bursts (2, 4, 8, 16 beats, aligned) are legal */
} rtlnet_axi_arbiter_caps_t;

typedef struct {
    uint32_t aw_bursts;
    uint32_t ar_bursts;
    uint32_t w_beats;
    uint32_t r_beats;
    uint32_t errors;
    uint32_t wait_cycles;
} rtlnet_axi_arbiter_counters_t;

typedef struct {
    int err;       /* sticky illegal-burst flag */
    int wr_busy;
    int rd_busy;
} rtlnet_axi_arbiter_status_t;

typedef struct {
    int      valid;     /* an illegal burst is captured */
    int      is_read;   /* 0: write (AW), 1: read (AR) */
    uint32_t master;
    uint32_t size;      /* AxSIZE, bytes per beat = 1 << size */
    uint32_t len;       /* AxLEN, beats = len + 1 */
    uint32_t burst;     /* AxBURST */
    uint32_t fail;      /* RTLNET_ARB_FAIL_* bits */
    uint32_t addr_lo;
    uint32_t addr_hi;
} rtlnet_axi_arbiter_capture_t;

/* Return 0 on success, -1 on a bad argument, a missing core or a master index
 * at or above the core's NUM_MASTERS. */
int rtlnet_axi_arbiter_probe(uintptr_t base, rtlnet_axi_arbiter_caps_t *caps);
int rtlnet_axi_arbiter_read_counters(uintptr_t base, uint32_t master, rtlnet_axi_arbiter_counters_t *c);
void rtlnet_axi_arbiter_clear(uintptr_t base);
int rtlnet_axi_arbiter_err_status(uintptr_t base, rtlnet_axi_arbiter_status_t *st);
void rtlnet_axi_arbiter_err_clear(uintptr_t base);
/* Read the first-illegal-burst capture; valid is 0 and every other field 0 when nothing is captured.
 * Return 0 on success, -1 on NULL cap. The capture clears with err_clear or clear. */
int rtlnet_axi_arbiter_read_capture(uintptr_t base, rtlnet_axi_arbiter_capture_t *cap);

#endif /* RTLNET_AXI_ARBITER_H */
