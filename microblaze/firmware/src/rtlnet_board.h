/*
 * rtlnet_board.h -- Nexys Video board system registers and RTLNet window access
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the only firmware code that reads or writes the board system
 * registers (window SYS, map in rtlnet_nexys_video_sysregs.h) and the one
 * place that probes another core's standard header (ID/VERSION/CAPS) before
 * that core's driver is integrated. The CLI calls these functions and never
 * dereferences a register address itself. Raw debug access is also routed
 * here so every hardware access stays in one file.
 *
 * Builds for the target (volatile accesses) and for the host harness
 * (RTLNET_HOST_TEST: rtlnet_mmio.h forwards to the register model).
 */
#ifndef RTLNET_BOARD_H
#define RTLNET_BOARD_H

#include <stdint.h>   /* uint32_t, uintptr_t */

#include "rtlnet_nexys_video_sysregs.h"
#include "rtlnet_platform.h"

/* Result of probing a core window. */
typedef struct {
    uint32_t id;          /* ID register as read */
    uint32_t version;     /* VERSION register (valid when present) */
    uint32_t caps;        /* CAPS register (valid when present) */
    int      present;     /* 1 when id equals the expected code */
} board_probe_t;

uint32_t board_sys_read(uint32_t offset);
void     board_sys_write(uint32_t offset, uint32_t value);
uint32_t board_clk_khz(unsigned index);
int      board_ddr_calibrated(void);
int      board_probe(uintptr_t base, uint32_t expected_id, board_probe_t *out);
uint32_t board_debug_read32(uintptr_t addr);
void     board_debug_write32(uintptr_t addr, uint32_t value);
void     board_id_text(uint32_t id, char out[5]);

#endif /* RTLNET_BOARD_H */
