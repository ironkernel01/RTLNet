/*
 * rtlnet_platform.h -- Ethernet CPU firmware platform: address map and services
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: every base address the firmware uses, and the small platform API
 * (console, time, LEDs, restart) that the CLI and the application call. The
 * platform implementation is src/rtlnet_platform.c on the MicroBlaze and
 * host/host_platform.c in the desktop harness. Nothing here names a board:
 * the board facts come from the system registers (rtlnet_board.h).
 *
 * Address map (processor view):
 *
 *   0x0000_0000  lmb_kb    LMB block RAM (code, data, stack, lwIP)  CPU core
 *   0x4040_0000   64 KiB  AXI DMA (CPU network path, simple mode)  CPU core
 *   0x4060_0000   64 KiB  AXI UART Lite (console, 115200 8N1)      CPU core
 *   0x4120_0000   64 KiB  AXI INTC                                 CPU core
 *   0x41C0_0000   64 KiB  AXI Timer                                CPU core
 *   0x44A0_0000    1 MiB  RTLNet window (M_AXI_RTLNET), below:     board top
 *     0x44A0_0000   4 KiB  SYS system registers "ETHS"
 *     0x44A0_1000   4 KiB  MAC  rtlnet_eth_mac           "MAC1"
 *     0x44A0_2000   4 KiB  MDIO rtlnet_mdio              "MDIO"
 *     0x44A0_3000   4 KiB  ECHO rtlnet_udp_echo          "ECHO"
 *     0x44A1_0000  64 KiB  PROTOCOL rtlnet_eth_protocol, sub-map:
 *       0x44A1_0000        wrapper                    "PROT"
 *       0x44A1_1000        ARP leaf                   "ARP1"
 *       0x44A1_2000        ICMP leaf                  "ICMP"
 *       0x44A1_3000        DHCP leaf                  "DHCP"
 *       0x44A1_4000        iperf leaf                 "IPRF"
 *       0x44A1_5000        UDP socket leaf            "UDPS"
 *       0x44A1_8000        CPU-path classifier        "CLSF"
 *       0x44A1_9000        CPU-path checksum offload  "TCPO"
 *   0xC000_0000   64 KiB  AXI BRAM (DMA frame buffers only)        CPU core
 *
 * The CPU-core part comes from cpu/microblaze_v_ethernet/driver/
 * rtlnet_cpu_eth.h (single definition, matches rtlnet_cpu_eth_bd.tcl);
 * the RTLNet window offsets match architecture section 6.1 and the decoder
 * parameters of the board top. Windows of cores that are not in the build
 * answer 0 for every register, so a core is present exactly when its ID
 * register reads the expected code.
 *
 * This header holds constants, signatures and contract prose; the .c files
 * hold the per-function commentary.
 */
#ifndef RTLNET_PLATFORM_H
#define RTLNET_PLATFORM_H

#include <stddef.h>   /* size_t */
#include <stdint.h>   /* uint32_t, uintptr_t */

#include "rtlnet_cpu_eth.h"

/* CPU-core peripherals. */
#define RTLNET_PLAT_DMA_BASE        RTLNET_CPU_DMA_BASE
#define RTLNET_PLAT_UART_BASE       RTLNET_CPU_UART_BASE
#define RTLNET_PLAT_INTC_BASE       RTLNET_CPU_INTC_BASE
#define RTLNET_PLAT_TIMER_BASE      RTLNET_CPU_TIMER_BASE
#define RTLNET_PLAT_CPU_CLK_HZ      RTLNET_CPU_CLK_HZ

/* RTLNet window (architecture section 6.1). */
#define RTLNET_PLAT_WINDOW_BASE     RTLNET_CPU_RTLNET_BASE
#define RTLNET_PLAT_SYS_BASE        (RTLNET_PLAT_WINDOW_BASE + 0x00000u)
#define RTLNET_PLAT_MAC_BASE        (RTLNET_PLAT_WINDOW_BASE + 0x01000u)
#define RTLNET_PLAT_MDIO_BASE       (RTLNET_PLAT_WINDOW_BASE + 0x02000u)
#define RTLNET_PLAT_ECHO_BASE       (RTLNET_PLAT_WINDOW_BASE + 0x03000u)
#define RTLNET_PLAT_PROT_BASE       (RTLNET_PLAT_WINDOW_BASE + 0x10000u)
#define RTLNET_PLAT_ARP_BASE        (RTLNET_PLAT_PROT_BASE + 0x1000u)
#define RTLNET_PLAT_ICMP_BASE       (RTLNET_PLAT_PROT_BASE + 0x2000u)
#define RTLNET_PLAT_DHCP_BASE       (RTLNET_PLAT_PROT_BASE + 0x3000u)
#define RTLNET_PLAT_IPERF_BASE      (RTLNET_PLAT_PROT_BASE + 0x4000u)
#define RTLNET_PLAT_UDP_BASE        (RTLNET_PLAT_PROT_BASE + 0x5000u)
#define RTLNET_PLAT_CLS_BASE        (RTLNET_PLAT_PROT_BASE + 0x8000u)   /* CPU-path classifier */
#define RTLNET_PLAT_TXO_BASE        (RTLNET_PLAT_PROT_BASE + 0x9000u)   /* CPU-path checksum offload */

/* Core ID codes (four ASCII characters, first character in bits [31:24]). */
#define RTLNET_ID_SYS               0x45544853u   /* "ETHS" */
#define RTLNET_ID_MAC               0x4D414331u   /* "MAC1" */
#define RTLNET_ID_MDIO              0x4D44494Fu   /* "MDIO" */
#define RTLNET_ID_PROT              0x50524F54u   /* "PROT" */
#define RTLNET_ID_ARP               0x41525031u   /* "ARP1" */
#define RTLNET_ID_ICMP              0x49434D50u   /* "ICMP" */
#define RTLNET_ID_DHCP              0x44484350u   /* "DHCP" */
#define RTLNET_ID_IPERF             0x49505246u   /* "IPRF" */
#define RTLNET_ID_UDP               0x55445053u   /* "UDPS" */
#define RTLNET_ID_ECHO              0x4543484Fu   /* "ECHO" */
#define RTLNET_ID_CLS               0x434C5346u   /* "CLSF" */
#define RTLNET_ID_TXO               0x5443504Fu   /* "TCPO" */

/* Firmware identity. */
#define RTLNET_FW_NAME              "rtlnet-eth-fw"
#define RTLNET_FW_VERSION           "11-14-2026"

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

/* Interrupts. plat_irq_save masks the CPU interrupts and returns the previous state, plat_irq_restore returns to it (nesting safe): a critical
 * section against interrupt handlers, to be kept to a few register accesses. plat_irq_attach connects a handler (it receives ref) on an INTC input
 * (RTLNET_CPU_IRQ_*; the input stays masked), plat_irq_enable unmasks (on != 0) or masks it; attach returns 0, or -1 when the interrupt controller is
 * not running. A handler runs with the CPU interrupts masked and must be short. The harness models the controller: a handler is called when its input
 * is unmasked, the line is high and the interrupts are not masked. */
uint32_t plat_irq_save(void);
void     plat_irq_restore(uint32_t state);
int      plat_irq_attach(unsigned input, void (*handler)(void *ref), void *ref);
void     plat_irq_enable(unsigned input, int on);

/* Console transmit counters: the target sends through a 4 KiB ring and the UART interrupt (rtlnet_cpu_microblaze.md); the harness reports
 * a zero ring. irq_mode is 1 while the interrupt runs; drops counts characters lost to a full ring whose wait timed out. */
typedef struct {
    uint32_t ring_bytes;
    uint32_t high_water;
    uint32_t irqs;
    uint32_t refills;
    uint32_t drops;
    uint32_t irq_mode;
} plat_console_tx_t;
void     plat_console_tx_stats(plat_console_tx_t *out);

#endif /* RTLNET_PLATFORM_H */
