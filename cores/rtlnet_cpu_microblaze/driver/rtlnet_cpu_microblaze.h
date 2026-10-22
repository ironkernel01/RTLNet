/*
 * rtlnet_cpu_microblaze.h -- software view of the RTLNet MicroBlaze CPU core
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the single definition of the processor-side address map, vector
 * table and interrupt numbering of the block design `rtlnet_cpu`, created by
 * cores/rtlnet_cpu_microblaze/hdl/rtlnet_cpu_bd.tcl. The Tcl (assign_bd_address,
 * irq_concat) is the hardware side of this contract; change both together.
 * A drift shows as the firmware polling a peripheral that is not there: the
 * UART prints nothing and the timer reads 0.
 *
 * Firmware includes this through firmware/nexys_video/src/rtlnet_platform.h,
 * which adds the RTLNet register window map of the board.
 *
 * This header holds constants and contract prose only.
 */
#ifndef RTLNET_CPU_MICROBLAZE_H
#define RTLNET_CPU_MICROBLAZE_H

/* Local memory: one 128 KiB LMB block RAM, instruction and data, at 0. */
#define RTLNET_CPU_LMB_BASE         0x00000000u
#define RTLNET_CPU_LMB_SIZE         0x00020000u

/* MicroBlaze vectors (C_BASE_VECTORS = 0), each slot 8 bytes (imm + brai). */
#define RTLNET_CPU_VEC_RESET        0x00000000u
#define RTLNET_CPU_VEC_USER_EXC     0x00000008u
#define RTLNET_CPU_VEC_INTERRUPT    0x00000010u
#define RTLNET_CPU_VEC_BREAK        0x00000018u
#define RTLNET_CPU_VEC_HW_EXC       0x00000020u

/* AXI4-Lite peripherals of the block design (M_AXI_DP). */
#define RTLNET_CPU_UART_BASE        0x40600000u   /* AXI UART Lite, 115200 8N1 */
#define RTLNET_CPU_INTC_BASE        0x41200000u   /* AXI INTC */
#define RTLNET_CPU_MDM_BASE         0x41400000u   /* MDM JTAG UART */
#define RTLNET_CPU_TIMER_BASE       0x41C00000u   /* AXI Timer (timer 0 = tick) */

/* Exported register master M_AXI_RTLNET: the board's RTLNet window. */
#define RTLNET_CPU_RTLNET_BASE      0x44A00000u
#define RTLNET_CPU_RTLNET_SIZE      0x00100000u

/* Processor clock (cpu_clk from the board MMCM). */
#define RTLNET_CPU_CLK_HZ           100000000u

/* INTC input numbering: core port irq[7:0] on inputs 0..7. */
#define RTLNET_CPU_IRQ_EXT0         0u            /* irq[0] .. irq[7] = inputs 0..7 */
#define RTLNET_CPU_IRQ_EXT_COUNT    8u
#define RTLNET_CPU_IRQ_TIMER        8u
#define RTLNET_CPU_IRQ_UART         9u

#endif /* RTLNET_CPU_MICROBLAZE_H */
