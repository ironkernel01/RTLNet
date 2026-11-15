/* Purpose: PS7 address map, time, interrupt and cache services for the ARM application.
 * Overview: IRQ inputs 0/1 map to GIC IDs 61/62; ticks and capture stamps are microseconds.
 * Revision: 11-14-2026. Initial Zynq platform. Headers hold contracts; C owns hardware access.
 */
#ifndef RTLNET_PLATFORM_H
#define RTLNET_PLATFORM_H
#include <stddef.h>
#include <stdint.h>
#define RTLNET_PLAT_DDR_BASE       0u
#define RTLNET_PLAT_DDR_SIZE       0x40000000u
#define RTLNET_PLAT_CACHE_LINE     32u
#define RTLNET_PLAT_TICKS_PER_US   1u
#define RTLNET_PLAT_CPU_CLK_HZ     666666667u
#define RTLNET_PLAT_ARB_BASE       0x44a04000u
#define RTLNET_PLAT_CSI2_BASE      0x44a05000u
#define RTLNET_PLAT_S2MM_BASE      0x44a06000u
#define RTLNET_PLAT_FB_BASE        0x44a07000u
#define RTLNET_PLAT_H264_BASE      0x44a08000u
#define RTLNET_CPU_IRQ_CAPTURE     0u
#define RTLNET_CPU_IRQ_H264        1u
#define RTLNET_PS_GEM_BASE         0xe000b000u
#define RTLNET_PS_UART_BASE        0xe0001000u
#define RTLNET_PS_I2C_BASE         0xe0004000u
#define RTLNET_PS_GPIO_BASE        0xe000a000u
void plat_init(void);
void plat_console_write(const char *s, size_t n);
int plat_console_getc(void);
uint32_t plat_ticks(void);
uint32_t plat_uptime_ms(void);
void plat_delay_us(uint32_t us);
void plat_delay_ms(uint32_t ms);
void plat_poll(void);
uint32_t plat_irq_save(void);
void plat_irq_restore(uint32_t state);
int plat_irq_attach(unsigned input, void (*handler)(void *), void *ref);
void plat_irq_enable(unsigned input, int on);
void plat_dcache_flush_range(uintptr_t addr, size_t len);
void plat_dcache_invalidate_range(uintptr_t addr, size_t len);
void plat_mem_barrier(void);
void rtlnet_fatal(const char *api, int status);
#endif
