/*
 * rtlnet_nexys_video_sysregs.h -- Nexys Video board system-register map
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the board system-register block
 * (boards/nexys_video/hdl/rtlnet_nexys_video_sysregs.sv), window SYS at
 * offset 0x0_0000 of the RTLNet window (RTLNET_PLAT_SYS_BASE). The register
 * file mirrors these offsets and bit positions as localparams with a pointer
 * comment to this file; change both in the same commit. A drift shows as the
 * firmware reading the wrong register (ID mismatch in "show version" is the
 * first symptom).
 *
 * All registers are 32-bit, AXI4-Lite, cpu_clk. Undefined offsets read 0 and
 * ignore writes; partial-strobe writes are ignored (architecture section 5).
 *
 * This header holds offsets, bit positions and contract prose only.
 */
#ifndef RTLNET_NEXYS_VIDEO_SYSREGS_H
#define RTLNET_NEXYS_VIDEO_SYSREGS_H

/* Standard header (architecture section 5). */
#define NXV_SYS_ID              0x000u   /* RO "NXVD" */
#define NXV_SYS_VERSION         0x004u   /* RO register-map date code */
#define NXV_SYS_CAPS            0x008u   /* RO build capabilities */

/* Board registers. */
#define NXV_SYS_BUILD_ID        0x00Cu   /* RO 32-bit git hash (first 8 hex digits) */
#define NXV_SYS_BUILD_DIRTY     0x010u   /* RO bit 0: tree had uncommitted changes */
#define NXV_SYS_LEDS            0x014u   /* RW bits [7:1] drive led[7:1]; bit 0 reads 0 */
#define NXV_SYS_SWITCHES        0x018u   /* RO sw[7:0], synchronized */
#define NXV_SYS_BUTTONS         0x01Cu   /* RO buttons, synchronized (bit map below) */
#define NXV_SYS_CLK_STATUS      0x020u   /* RO MMCM lock and per-clock activity */
#define NXV_SYS_SCRATCH         0x024u   /* RW scratch */
#define NXV_SYS_UPTIME_MS       0x028u   /* RO milliseconds since cpu_clk reset release */
#define NXV_SYS_CPU_CLK_HZ      0x02Cu   /* RO cpu_clk frequency the build assumes */
#define NXV_SYS_PHY_STATUS      0x030u   /* RO PHY side-band pins */
#define NXV_SYS_NET_STATUS      0x034u   /* RO network core status (network build only) */
#define NXV_SYS_CLK_MEAS0       0x040u   /* RO clock measurement, index 0..4, stride 4 */
#define NXV_SYS_CLK_MEAS_STRIDE 0x004u

/* Register values. */
#define NXV_SYS_ID_VALUE        0x4E585644u   /* "NXVD" */
#define NXV_SYS_VERSION_VALUE   0x10222026u   /* 10-22-2026 */

/* CAPS bits. */
#define NXV_CAPS_NETWORK        0x00000001u   /* built with RTLNET_WITH_NETWORK */
#define NXV_CAPS_NUM_LEDS_SHIFT 8u            /* [15:8] number of user LEDs */
#define NXV_CAPS_NUM_SW_SHIFT   16u           /* [23:16] number of slide switches */
#define NXV_CAPS_NUM_BTN_SHIFT  24u           /* [31:24] number of push buttons */

/* LEDS: led[0] is hardware-owned (MMCM locked); led[1] is the firmware
 * heartbeat by convention; led[7:2] are free for firmware. */
#define NXV_LED_HEARTBEAT       0x00000002u
#define NXV_LED_WRITABLE_MASK   0x000000FEu

/* BUTTONS bits (1 = pressed). */
#define NXV_BTN_C               0x00000001u
#define NXV_BTN_D               0x00000002u
#define NXV_BTN_L               0x00000004u
#define NXV_BTN_R               0x00000008u
#define NXV_BTN_U               0x00000010u

/* CLK_STATUS bits. */
#define NXV_CLK_MMCM_LOCKED     0x00000001u
#define NXV_CLK_ALIVE_SHIFT     8u            /* [12:8] clock i measured nonzero */

/* Clock measurement: CLK_MEAS[i] counts both edges of a divide-by-32 beacon of
 * clock i over one 1 ms window of cpu_clk, so f(kHz) = CLK_MEAS[i] * 16. */
#define NXV_CLK_MEAS_COUNT      5u
#define NXV_CLK_MEAS_KHZ_PER_LSB 16u
#define NXV_CLK_IDX_CLK125      0u
#define NXV_CLK_IDX_CLK125_90   1u
#define NXV_CLK_IDX_CLK200      2u
#define NXV_CLK_IDX_AXIS        3u
#define NXV_CLK_IDX_PROTO       4u

/* PHY_STATUS bits (pin levels, synchronized; the PHY pins are active low). */
#define NXV_PHY_INT_N           0x00000001u   /* eth_int_b */
#define NXV_PHY_PME_N           0x00000002u   /* eth_pme_b */
#define NXV_PHY_RST_N           0x00000004u   /* eth_rst_b as driven */
#define NXV_PHY_MDIO_IN         0x00000008u   /* eth_mdio pad input */
/* RGMII receive pin levels, sampled in cpu_clk (CPU-only build; 0 in the
 * network build, where the MAC owns those pins). A toggling RXCK bit across
 * reads shows the PHY clock is running. */
#define NXV_PHY_RXCTL           0x00000010u   /* eth_rxctl */
#define NXV_PHY_RXD_SHIFT       5u            /* [8:5] eth_rxd[3:0] */
#define NXV_PHY_RXD_MASK        0x000001E0u
#define NXV_PHY_RXCK            0x00000200u   /* eth_rxck */

/* NET_STATUS bits (network build; reads 0 in the CPU-only build). */
#define NXV_NET_LINK_UP         0x00000001u
#define NXV_NET_SPEED_SHIFT     1u            /* [2:1] 00 10M, 01 100M, 10 1000M */
#define NXV_NET_SPEED_MASK      0x00000006u
#define NXV_NET_RX_CLK_OK       0x00000008u
#define NXV_NET_IP_VALID        0x00000010u
#define NXV_NET_DHCP_BOUND      0x00000020u

#endif /* RTLNET_NEXYS_VIDEO_SYSREGS_H */
