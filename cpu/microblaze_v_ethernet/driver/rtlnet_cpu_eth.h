/*
 * rtlnet_cpu_eth.h -- software view of the RTLNet Ethernet MicroBlaze CPU core
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the processor-side address map, vector
 * table and interrupt numbering of the block design `rtlnet_cpu_eth`, created by
 * cpu/microblaze_v_ethernet/hdl/rtlnet_cpu_eth_bd.tcl. The Tcl (assign_bd_address,
 * irq_concat) is the hardware side of this contract; change both together.
 * A drift shows as the firmware polling a peripheral that is not there: the
 * UART prints nothing and the timer reads 0.
 *
 * The core is board independent: this header names no board, part or PHY, and
 * the processor clock is read from the exported hardware (XSA, BSP xparameters.h),
 * never typed here. The size of the LMB block RAM is an argument of the block
 * design procedure; the firmware link (build.ps1 -LmbKb) takes it from the build.
 *
 * Firmware includes this through cpu/microblaze_v_ethernet/firmware/src/rtlnet_platform.h,
 * which adds the RTLNet register window map. The BSP's xparameters.h (generated
 * from the XSA) carries the same base addresses; the firmware passes these
 * constants to the BSP drivers, so a drift between the Tcl and this file shows as
 * a driver initialization failure at boot.
 *
 * Interrupt numbering: the INTC input of each source is defined here, not
 * taken from the XPAR_FABRIC_* values of the generated xparameters.h, which
 * number the irq_concat ports (0..4) instead of the INTC input bits (an
 * 8-bit first port shifts every later source by 7).
 *
 * This header holds constants and contract prose only.
 *
 * Revision: 11-14-2026
 *   * 11-14-2026: initial version (from the H.264 CPU header, without the DDR3 window and the caches).
 */
#ifndef RTLNET_CPU_ETH_H
#define RTLNET_CPU_ETH_H

/* Local memory: one LMB block RAM, instruction and data, at 0 (size: block design argument lmb_kb). No caches. */
#define RTLNET_CPU_LMB_BASE         0x00000000u

/* AXI block RAM on the data side, shared with the AXI DMA: DMA buffers and
 * the lwIP heap and pools (linker section .axi_bram, NOLOAD). Size: block design
 * argument axi_bram_kb, 64 KiB by default. */
#define RTLNET_CPU_AXI_BRAM_BASE    0xC0000000u
#define RTLNET_CPU_AXI_BRAM_SIZE    0x00010000u

/* MicroBlaze V reset vector (C_BASE_VECTORS = 0). Exceptions and interrupts
 * enter through mtvec, which the BSP start-up code sets; the firmware
 * registers its handlers with Xil_ExceptionRegisterHandler(). */
#define RTLNET_CPU_VEC_RESET        0x00000000u

/* AXI4-Lite peripherals of the block design (M_AXI_DP). */
#define RTLNET_CPU_DMA_BASE         0x40400000u   /* AXI DMA, simple mode, MM2S + S2MM */
#define RTLNET_CPU_UART_BASE        0x40600000u   /* AXI UART Lite, 115200 8N1 */
#define RTLNET_CPU_INTC_BASE        0x41200000u   /* AXI INTC */
#define RTLNET_CPU_TIMER_BASE       0x41C00000u   /* AXI Timer (timer 0 = tick) */

/* Exported register master M_AXI_RTLNET: the board's RTLNet window. */
#define RTLNET_CPU_RTLNET_BASE      0x44A00000u
#define RTLNET_CPU_RTLNET_SIZE      0x00100000u

/* Processor clock (cpu_clk from the board): read from the exported hardware (XSA, BSP xparameters.h), never typed here.
 * The desktop harness (RTLNET_HOST_TEST) models 100 MHz. */
#ifdef RTLNET_HOST_TEST
#define RTLNET_CPU_CLK_HZ           100000000u
#else
#include "xparameters.h"
#define RTLNET_CPU_CLK_HZ           ((uint32_t)XPAR_CPU_CORE_CLOCK_FREQ_HZ)
#endif

/* INTC input numbering: core port irq[7:0] on inputs 0..7. */
#define RTLNET_CPU_IRQ_EXT0         0u            /* irq[0] .. irq[7] = inputs 0..7 */
#define RTLNET_CPU_IRQ_EXT_COUNT    8u
#define RTLNET_CPU_IRQ_MDIO         0u            /* irq[0]: rtlnet_mdio */
#define RTLNET_CPU_IRQ_TIMER        8u
#define RTLNET_CPU_IRQ_UART         9u
#define RTLNET_CPU_IRQ_DMA_MM2S     10u           /* AXI DMA mm2s_introut */
#define RTLNET_CPU_IRQ_DMA_S2MM     11u           /* AXI DMA s2mm_introut */
#define RTLNET_CPU_IRQ_COUNT        12u

/* AXI DMA: buffer length register width (c_sg_length_width 14), the largest
 * simple transfer in bytes. */
#define RTLNET_CPU_DMA_MAX_LEN      16383u

#endif /* RTLNET_CPU_ETH_H */
