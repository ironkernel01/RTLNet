/* Purpose: host platform mocks for portable ARM CLI/session checks.
 * Overview: no devices are present; no simulated encode or network claim.
 * Revision: 11-14-2026. Initial host harness.
 */
#include "rtlnet_platform.h"
#include "rtlnet_dphy.h"
#include <stdio.h>
#include <stdlib.h>
uint32_t rtlnet_host_reg_read32(uintptr_t a)
{
    if (a == RTLNET_DPHY_BASE) return 2u;
    if (a == RTLNET_DPHY_BASE + 12u) return 0x00010003u;
    return 0;
}
void rtlnet_host_reg_write32(uintptr_t a,uint32_t v) { (void)a;(void)v; }
uint32_t rtlnet_host_mem_read32(uintptr_t a) { (void)a; return 0; }
uint32_t plat_ticks(void) { static uint32_t t; return ++t; }
uint32_t plat_uptime_ms(void) { return plat_ticks()/1000; }
uint32_t plat_irq_save(void) { return 0; }
void plat_irq_restore(uint32_t s) { (void)s; }
int plat_irq_attach(unsigned i,void (*h)(void *),void *r) { (void)i;(void)h;(void)r; return -1; }
void plat_irq_enable(unsigned i,int v) { (void)i;(void)v; }
void plat_dcache_flush_range(uintptr_t a,size_t n) { (void)a;(void)n; }
void plat_dcache_invalidate_range(uintptr_t a,size_t n) { (void)a;(void)n; }
void plat_mem_barrier(void) { }
int board_ddr_calibrated(void) { return 1; }
int video_udp_open(uint32_t a,uint16_t p) { (void)a;(void)p; return -1; }
void video_udp_close(void) { }
int video_udp_send(const uint8_t *p,uint32_t n) { (void)p;(void)n; return -1; }
void video_udp_counters(uint32_t *s,uint32_t *d,uint32_t *r) { if(s)*s=0;if(d)*d=0;if(r)*r=0; }
void video_udp_profile(uint64_t *c,uint64_t *s) { if(c)*c=0;if(s)*s=0; }
static unsigned mode;
int rtlnet_sensor_mode(unsigned m) { mode=m;return 0; }
unsigned rtlnet_sensor_get_mode(void) { return mode; }
void rtlnet_network_show(void) { puts("host: no PHY/DHCP"); }
