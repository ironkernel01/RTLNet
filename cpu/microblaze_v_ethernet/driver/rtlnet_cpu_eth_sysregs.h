/*
 * rtlnet_cpu_eth_sysregs.h -- system-register map of the Ethernet CPU core
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the board-independent system-register block
 * (cpu/microblaze_v_ethernet/hdl/rtlnet_cpu_eth_sysregs.sv), window SYS at
 * offset 0x0_0000 of the RTLNet window (RTLNET_PLAT_SYS_BASE). The register
 * file mirrors these offsets and bit positions as localparams with a pointer
 * comment to this file; change both in the same commit. A drift shows as the
 * firmware reading the wrong register (an ID mismatch in "show version" is the
 * first symptom).
 *
 * The block carries the facts the firmware needs about the board: BOARD_ID
 * (four ASCII characters), CPU_CLK_HZ, LINK_CAPS (the link modes the board
 * supports, full duplex only), the number of LEDs, switches and buttons. The
 * firmware has no board-specific source file: it reads these registers and
 * identifies the PHY from its MDIO ID registers (rtlnet_phy.h).
 *
 * All registers are 32-bit, AXI4-Lite, cpu_clk. Undefined offsets read 0 and
 * ignore writes; partial-strobe writes are ignored (architecture section 5).
 *
 * This header holds offsets, bit positions and contract prose only.
 *
 * Revision: 11-14-2026
 *   * 11-14-2026: initial version.
 */
#ifndef RTLNET_CPU_ETH_SYSREGS_H
#define RTLNET_CPU_ETH_SYSREGS_H

/* Standard header (architecture section 5). */
#define ETHS_SYS_ID              0x000u   /* RO "ETHS" */
#define ETHS_SYS_VERSION         0x004u   /* RO register-map date code */
#define ETHS_SYS_CAPS            0x008u   /* RO number of user I/O (below) */

/* Registers. */
#define ETHS_SYS_BUILD_ID        0x00Cu   /* RO 32-bit git hash (first 8 hex digits) */
#define ETHS_SYS_BUILD_DIRTY     0x010u   /* RO bit 0: tree had uncommitted changes */
#define ETHS_SYS_BOARD_ID        0x014u   /* RO four ASCII characters naming the board, first character in [31:24] */
#define ETHS_SYS_CPU_CLK_HZ      0x018u   /* RO frequency of cpu_clk in Hz */
#define ETHS_SYS_LINK_CAPS       0x01Cu   /* RO link modes of the board (bit map below) */
#define ETHS_SYS_UPTIME_MS       0x020u   /* RO milliseconds since cpu_clk reset release */
#define ETHS_SYS_LEDS            0x024u   /* RW bits [NUM_LED-1:1] drive led[NUM_LED-1:1]; bit 0 reads 0 */
#define ETHS_SYS_SWITCHES        0x028u   /* RO switch levels, synchronized */
#define ETHS_SYS_BUTTONS         0x02Cu   /* RO button levels, synchronized (1 = pressed) */
#define ETHS_SYS_SCRATCH         0x030u   /* RW scratch */
#define ETHS_SYS_CLK_STATUS      0x034u   /* RO bit 0: clocks locked */
#define ETHS_SYS_PHY_STATUS      0x038u   /* RO PHY side-band pins (bit map below) */
#define ETHS_SYS_NET_STATUS      0x03Cu   /* RO network core status (bit map below) */

/* Register values. */
#define ETHS_SYS_ID_VALUE        0x45544853u   /* "ETHS" */
#define ETHS_SYS_VERSION_VALUE   0x11142026u   /* 11-14-2026 */

/* CAPS: counts of user I/O the board has. */
#define ETHS_CAPS_NUM_LEDS_SHIFT 8u            /* [15:8] number of user LEDs */
#define ETHS_CAPS_NUM_SW_SHIFT   16u           /* [23:16] number of slide switches */
#define ETHS_CAPS_NUM_BTN_SHIFT  24u           /* [31:24] number of push buttons */

/* LINK_CAPS: link modes the board supports, full duplex (half duplex is never offered). */
#define ETHS_LINK_10F            0x00000001u
#define ETHS_LINK_100F           0x00000002u
#define ETHS_LINK_1000F          0x00000004u
#define ETHS_LINK_MASK           0x00000007u

/* LEDS: led[0] is hardware-owned (clocks locked); led[1] is the firmware
 * heartbeat by convention; led[2] link, led[3] DHCP lease; the rest are free. */
#define ETHS_LED_HEARTBEAT       0x00000002u

/* CLK_STATUS bits. */
#define ETHS_CLK_LOCKED          0x00000001u

/* PHY_STATUS bits (pin levels, synchronized; the interrupt pin is active low). */
#define ETHS_PHY_INT_N           0x00000001u   /* PHY interrupt pin */
#define ETHS_PHY_RST_N           0x00000002u   /* PHY reset as driven */
#define ETHS_PHY_MDIO_IN         0x00000004u   /* MDIO pad input */

/* NET_STATUS bits. */
#define ETHS_NET_LINK_UP         0x00000001u
#define ETHS_NET_SPEED_SHIFT     1u            /* [2:1] 00 10M, 01 100M, 10 1000M */
#define ETHS_NET_SPEED_MASK      0x00000006u
#define ETHS_NET_RX_CLK_OK       0x00000008u
#define ETHS_NET_IP_VALID        0x00000010u
#define ETHS_NET_DHCP_BOUND      0x00000020u

#endif /* RTLNET_CPU_ETH_SYSREGS_H */
