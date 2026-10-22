/*
 * rtlnet_board.c -- Nexys Video board system registers and RTLNet window access
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Owns the board system registers and core-header probing; see
 * rtlnet_board.h for the contract.
 */
#include "rtlnet_board.h"

#include "rtlnet_mmio.h"

/*
 * board_sys_read -- read one board system register.
 * Returns: the register value (offsets from rtlnet_nexys_video_sysregs.h).
 */
uint32_t board_sys_read(uint32_t offset)
{
    return rtlnet_reg_read32(RTLNET_PLAT_SYS_BASE, offset);
}

/*
 * board_sys_write -- write one board system register.
 * Returns: nothing (read-only offsets ignore the write in hardware).
 */
void board_sys_write(uint32_t offset, uint32_t value)
{
    rtlnet_reg_write32(RTLNET_PLAT_SYS_BASE, offset, value);
}

/*
 * board_clk_khz -- measured frequency of a monitored clock.
 * Steps:
 *   1. Read CLK_MEAS[index] (beacon edges per 1 ms window).
 *   2. Scale by NXV_CLK_MEAS_KHZ_PER_LSB.
 * Returns: frequency in kHz (resolution 16 kHz), 0 for a stopped clock or an
 *          index out of range.
 */
uint32_t board_clk_khz(unsigned index)
{
    if (index >= NXV_CLK_MEAS_COUNT) {
        return 0u;
    }
    return board_sys_read(NXV_SYS_CLK_MEAS0 + index * NXV_SYS_CLK_MEAS_STRIDE) * NXV_CLK_MEAS_KHZ_PER_LSB;
}

/*
 * board_probe -- read a core's standard header and compare its ID.
 * Steps:
 *   1. Read ID; a window without its core reads 0 (stub or DECERR).
 *   2. When ID matches, also read VERSION and CAPS.
 * Returns: 1 present, 0 absent; *out filled in both cases.
 */
int board_probe(uintptr_t base, uint32_t expected_id, board_probe_t *out)
{
    out->id      = rtlnet_reg_read32(base, RTLNET_REG_ID);
    out->present = (out->id == expected_id) ? 1 : 0;
    out->version = out->present ? rtlnet_reg_read32(base, RTLNET_REG_VERSION) : 0u;
    out->caps    = out->present ? rtlnet_reg_read32(base, RTLNET_REG_CAPS) : 0u;
    return out->present;
}

/*
 * board_debug_read32 -- raw 32-bit read of any word-aligned address.
 * Returns: the word read (the caller checks alignment).
 */
uint32_t board_debug_read32(uintptr_t addr)
{
    return rtlnet_reg_read32(addr, 0u);
}

/*
 * board_debug_write32 -- raw 32-bit write of any word-aligned address.
 * Returns: nothing.
 */
void board_debug_write32(uintptr_t addr, uint32_t value)
{
    rtlnet_reg_write32(addr, 0u, value);
}

/*
 * board_id_text -- the four ASCII characters of an ID code.
 * Steps:
 *   1. Bits [31:24] are the first character; non-printable bytes become '.'.
 * Returns: nothing; out holds a NUL-terminated 4-character string.
 */
void board_id_text(uint32_t id, char out[5])
{
    for (unsigned i = 0; i < 4u; i++) {
        char c = (char)((id >> (24u - 8u * i)) & 0xFFu);
        out[i] = (c >= 0x20 && c <= 0x7E) ? c : '.';
    }
    out[4] = '\0';
}
