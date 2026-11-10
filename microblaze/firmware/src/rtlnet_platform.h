/*
 * rtlnet_platform.h -- Nexys Video firmware platform: address map and services
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: every base address the firmware uses, and the small platform API
 * (console, time, LEDs, restart) that the CLI and the application call. The
 * platform implementation is src/rtlnet_platform.c on the MicroBlaze and
 * host/host_platform.c in the desktop harness.
 *
 * Address map (processor view):
 *
 *   0x0000_0000  512 KiB  LMB block RAM (code, data, stack, lwIP)  CPU core
 *   0x4040_0000   64 KiB  AXI DMA (CPU network path, simple mode)  CPU core
 *   0x4060_0000   64 KiB  AXI UART Lite (console, 115200 8N1)      CPU core
 *   0x4120_0000   64 KiB  AXI INTC                                 CPU core
 *   0x41C0_0000   64 KiB  AXI Timer                                CPU core
 *   0x44A0_0000    1 MiB  RTLNet window (M_AXI_RTLNET), below:     board top
 *     0x44A0_0000   4 KiB  SYS board system registers "NXVD"
 *     0x44A0_1000   4 KiB  MAC  rtlnet_eth_mac        "MAC1"
 *     0x44A0_2000   4 KiB  MDIO rtlnet_mdio           "MDIO"
 *     0x44A0_3000   4 KiB  ECHO rtlnet_udp_echo       "ECHO"
 *     0x44A0_4000   4 KiB  ARB  rtlnet_axi_arbiter     "ARBT" (DDR3 arbiter)
 *     0x44A0_5000   4 KiB  CSI2 rtlnet_csi2_rx        "CSI2" (color bars, source switch)
 *     0x44A0_6000   4 KiB  S2MM rtlnet_vdma_s2mm      "S2MM" (video write DMA)
 *     0x44A0_7000   4 KiB  FBUF rtlnet_framebuf       "FBUF" (frame buffer manager)
 *     0x44A1_0000  64 KiB  PROTOCOL rtlnet_eth_protocol, sub-map:
 *       0x44A1_0000        wrapper                    "PROT"
 *       0x44A1_1000        ARP leaf                   "ARP1"
 *       0x44A1_2000        ICMP leaf                  "ICMP"
 *       0x44A1_3000        DHCP leaf                  "DHCP"
 *       0x44A1_4000        iperf leaf                 "IPRF"
 *       0x44A1_5000        UDP socket leaf            "UDPS"
 *       0x44A1_8000        CPU-path classifier        "CLSF"
 *       0x44A1_9000        CPU-path checksum offload  "TCPO"
 *     0x44A2_0000   4 KiB  CLASSIFIER (reserved, reads 0)
 *   0x8000_0000  512 MiB  DDR3 SDRAM (cached, M_AXI_DDR)           CPU core
 *   0xC000_0000   64 KiB  AXI BRAM (DMA frame buffers only)        CPU core
 *
 * The CPU-core part comes from microblaze/driver/
 * rtlnet_cpu_microblaze.h (single definition, matches rtlnet_cpu_bd.tcl);
 * the RTLNet window offsets match architecture section 6.1 and the decoder
 * parameters of boards/nexys_video/hdl/rtlnet_nexys_video_top.sv. Windows of
 * cores that are not in the build answer 0 for every register, so a core is
 * present exactly when its ID register reads the expected code.
 *
 * This header holds constants, signatures and contract prose; the .c files
 * hold the per-function commentary.
 *
 * Revision: 11-09-2026
 *   * 11-09-2026: video windows CSI2, S2MM and FBUF (Phase 1).
 *   * 11-09-2026: RTLNET_FW_IMAGE ("LMB" release image, "DDR3" development image of build.ps1 -Ddr).
 */
#ifndef RTLNET_PLATFORM_H
#define RTLNET_PLATFORM_H

#include <stddef.h>   /* size_t */
#include <stdint.h>   /* uint32_t, uintptr_t */

#include "rtlnet_cpu_microblaze.h"

/* CPU-core peripherals. */
#define RTLNET_PLAT_DMA_BASE        RTLNET_CPU_DMA_BASE
#define RTLNET_PLAT_UART_BASE       RTLNET_CPU_UART_BASE
#define RTLNET_PLAT_INTC_BASE       RTLNET_CPU_INTC_BASE
#define RTLNET_PLAT_TIMER_BASE      RTLNET_CPU_TIMER_BASE
#define RTLNET_PLAT_CPU_CLK_HZ      RTLNET_CPU_CLK_HZ

/* DDR3 window and its caches (single definition in rtlnet_cpu_microblaze.h). */
#define RTLNET_PLAT_DDR_BASE        RTLNET_CPU_DDR_BASE
#define RTLNET_PLAT_DDR_SIZE        RTLNET_CPU_DDR_SIZE
#define RTLNET_PLAT_CACHE_LINE      RTLNET_CPU_CACHE_LINE_BYTES

/* RTLNet window (architecture section 6.1). */
#define RTLNET_PLAT_WINDOW_BASE     RTLNET_CPU_RTLNET_BASE
#define RTLNET_PLAT_SYS_BASE        (RTLNET_PLAT_WINDOW_BASE + 0x00000u)
#define RTLNET_PLAT_MAC_BASE        (RTLNET_PLAT_WINDOW_BASE + 0x01000u)
#define RTLNET_PLAT_MDIO_BASE       (RTLNET_PLAT_WINDOW_BASE + 0x02000u)
#define RTLNET_PLAT_ECHO_BASE       (RTLNET_PLAT_WINDOW_BASE + 0x03000u)
#define RTLNET_PLAT_ARB_BASE        (RTLNET_PLAT_WINDOW_BASE + 0x04000u)
#define RTLNET_PLAT_CSI2_BASE       (RTLNET_PLAT_WINDOW_BASE + 0x05000u)
#define RTLNET_PLAT_S2MM_BASE       (RTLNET_PLAT_WINDOW_BASE + 0x06000u)
#define RTLNET_PLAT_FB_BASE         (RTLNET_PLAT_WINDOW_BASE + 0x07000u)
#define RTLNET_PLAT_H264_BASE       (RTLNET_PLAT_WINDOW_BASE + 0x08000u)   /* H.264 encoder, Phase 2b-3 */
#define RTLNET_PLAT_PROT_BASE       (RTLNET_PLAT_WINDOW_BASE + 0x10000u)
#define RTLNET_PLAT_ARP_BASE        (RTLNET_PLAT_PROT_BASE + 0x1000u)
#define RTLNET_PLAT_ICMP_BASE       (RTLNET_PLAT_PROT_BASE + 0x2000u)
#define RTLNET_PLAT_DHCP_BASE       (RTLNET_PLAT_PROT_BASE + 0x3000u)
#define RTLNET_PLAT_IPERF_BASE      (RTLNET_PLAT_PROT_BASE + 0x4000u)
#define RTLNET_PLAT_UDP_BASE        (RTLNET_PLAT_PROT_BASE + 0x5000u)
#define RTLNET_PLAT_CLS_BASE        (RTLNET_PLAT_PROT_BASE + 0x8000u)   /* CPU-path classifier */
#define RTLNET_PLAT_TXO_BASE        (RTLNET_PLAT_PROT_BASE + 0x9000u)   /* CPU-path checksum offload */
#define RTLNET_PLAT_CLASSIFIER_BASE (RTLNET_PLAT_WINDOW_BASE + 0x20000u)

/* Core ID codes (four ASCII characters, first character in bits [31:24]). */
#define RTLNET_ID_SYS               0x4E585644u   /* "NXVD" */
#define RTLNET_ID_MAC               0x4D414331u   /* "MAC1" */
#define RTLNET_ID_MDIO              0x4D44494Fu   /* "MDIO" */
#define RTLNET_ID_PROT              0x50524F54u   /* "PROT" */
#define RTLNET_ID_ARP               0x41525031u   /* "ARP1" */
#define RTLNET_ID_ICMP              0x49434D50u   /* "ICMP" */
#define RTLNET_ID_DHCP              0x44484350u   /* "DHCP" */
#define RTLNET_ID_IPERF             0x49505246u   /* "IPRF" */
#define RTLNET_ID_UDP               0x55445053u   /* "UDPS" */
#define RTLNET_ID_ECHO              0x4543484Fu   /* "ECHO" */
#define RTLNET_ID_ARB               0x41524254u   /* "ARBT" */
#define RTLNET_ID_CLS               0x434C5346u   /* "CLSF" */
#define RTLNET_ID_TXO               0x5443504Fu   /* "TCPO" */
#define RTLNET_ID_CSI2              0x43534932u   /* "CSI2" */
#define RTLNET_ID_S2MM              0x53324D4Du   /* "S2MM" */
#define RTLNET_ID_FB                0x46425546u   /* "FBUF" */
#define RTLNET_ID_H264              0x48323634u   /* "H264" */

/* Firmware identity. */
#define RTLNET_FW_NAME              "rtlnet-fw"
#define RTLNET_FW_VERSION           "11-09-2026"
/* Memory the image is linked into: "LMB" (release, build.ps1) or "DDR3" (development, build.ps1 -Ddr, which defines
 * RTLNET_FW_IMAGE_DDR; the image is loaded over JTAG). */
#ifdef RTLNET_FW_IMAGE_DDR
#define RTLNET_FW_IMAGE             "DDR3"
#else
#define RTLNET_FW_IMAGE             "LMB"
#endif

/* Free-running tick (AXI Timer 0 at cpu_clk). */
#define RTLNET_PLAT_TICKS_PER_US    (RTLNET_PLAT_CPU_CLK_HZ / 1000000u)

/* Heartbeat: led[1] toggles every RTLNET_PLAT_HEARTBEAT_MS. */
#define RTLNET_PLAT_HEARTBEAT_MS    500u

/* Platform services (rtlnet_platform.c on the target, host_platform.c on the PC). */
void     plat_init(void);
void     plat_console_write(const char *s, size_t n);
int      plat_console_getc(void);
uint32_t plat_uptime_ms(void);
uint32_t plat_ticks(void);
void     plat_delay_us(uint32_t us);
void     plat_delay_ms(uint32_t ms);
void     plat_poll(void);
void     plat_led_set(unsigned index, int on);
uint32_t plat_led_state(void);
void     plat_reload(void);

/* Data cache maintenance for the DDR3 window. The range is widened to whole cache lines
 * (RTLNET_PLAT_CACHE_LINE, 64 bytes). The data cache is write-back: flush writes dirty lines back to memory and
 * invalidates them (call it on a buffer the CPU wrote before hardware reads it); invalidate drops the lines,
 * dirty data included, so the next read comes from memory (call it on a buffer hardware wrote before the CPU
 * reads it, and keep such buffers 64-byte aligned and sized in 64-byte multiples so no CPU-written data
 * shares a line). No-ops where the build has no caches. */
void     plat_dcache_flush_range(uintptr_t addr, size_t len);
void     plat_dcache_invalidate_range(uintptr_t addr, size_t len);
void     plat_dcache_flush_all(void);
void     plat_mem_barrier(void);
void     plat_dcache_invalidate_all(void);

#endif /* RTLNET_PLATFORM_H */
