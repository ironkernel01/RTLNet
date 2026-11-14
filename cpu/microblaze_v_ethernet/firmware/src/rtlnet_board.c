/*
 * rtlnet_board.c -- system registers and RTLNet window access
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Owns the system registers and core-header probing; see
 * rtlnet_board.h for the contract.
 */
#include "rtlnet_board.h"

#include "rtlnet_mmio.h"

/*
 * board_sys_read -- read one system register.
 * Returns: the register value (offsets from rtlnet_cpu_eth_sysregs.h).
 */
uint32_t board_sys_read(uint32_t offset)
{
    return rtlnet_reg_read32(RTLNET_PLAT_SYS_BASE, offset);
}

/*
 * board_sys_write -- write one system register.
 * Returns: nothing (read-only offsets ignore the write in hardware).
 */
void board_sys_write(uint32_t offset, uint32_t value)
{
    rtlnet_reg_write32(RTLNET_PLAT_SYS_BASE, offset, value);
}

/*
 * board_link_caps -- the link modes the board supports.
 * Returns: ETHS_LINK_* bits (full duplex only); never 0: a register that reads
 *          0 (hardware older than this map) is treated as 10/100/1000.
 */
uint32_t board_link_caps(void)
{
    uint32_t c = board_sys_read(ETHS_SYS_LINK_CAPS) & ETHS_LINK_MASK;
    return (c != 0u) ? c : ETHS_LINK_MASK;
}

/*
 * board_num_leds -- number of user LEDs of the board.
 * Returns: CAPS[15:8], at most 8 (the LEDS register shadow of the platform layer holds 8 bits).
 */
unsigned board_num_leds(void)
{
    unsigned n = (unsigned)((board_sys_read(ETHS_SYS_CAPS) >> ETHS_CAPS_NUM_LEDS_SHIFT) & 0xFFu);
    return (n > 8u) ? 8u : n;
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
