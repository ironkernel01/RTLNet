/* Purpose: bounded PHY identification, DHCP and copied UDP sends on PS GEM0.
 * Overview: standard emacps adapter owns GEM DMA/cache handling. Only the main
 *   loop calls lwIP; link service occurs once per second. Identify E/F by ID.
 * Revision: 11-14-2026. Initial Zynq raw API implementation.
 */
#include "rtlnet_network.h"
#include "rtlnet_video_udp.h"
#include "rtlnet_platform.h"
#include "rtlnet_phy.h"
#include "xemacps.h"
#include "netif/xadapter.h"
#include "netif/xemacpsif.h"
#include "lwip/init.h"
#include "lwip/dhcp.h"
#include "lwip/timeouts.h"
#include "lwip/udp.h"
#include "lwip/etharp.h"
#include <stdio.h>
#include <string.h>
static struct netif nif;
static struct udp_pcb *pcb;
static ip_addr_t destination;
static uint16_t port;
static uint32_t phy_id, last_link, last_rx_check, sent, dropped, retries;
static uint64_t copy_time, send_time;
static int initialized;
u32_t sys_now(void) { return plat_uptime_ms(); }
int rtlnet_network_init(void)
{
    XEmacPs probe;
    XEmacPs_Config *cfg = XEmacPs_LookupConfig(0);
    unsigned char mac[6] = {0x02,0x49,0x52,0x4f,0x4e,0x01};
    ip_addr_t zero;
    if (!cfg || XEmacPs_CfgInitialize(&probe, cfg, cfg->BaseAddress) != XST_SUCCESS) return -1;
    XEmacPs_SetMdioDivisor(&probe, MDC_DIV_224);
    plat_delay_ms(100u);
    for (unsigned addr = 0; addr < 32u; addr++) {
        uint16_t a = 0, b = 0;
        if (XEmacPs_PhyRead(&probe, addr, 2, &a) != XST_SUCCESS ||
            XEmacPs_PhyRead(&probe, addr, 3, &b) != XST_SUCCESS) continue;
        uint32_t id = ((uint32_t)a << 16) | b;
        if (id == RTLNET_PHY_ID_E || id == RTLNET_PHY_ID_F) { phy_id = id; break; }
    }
    if (!phy_id) return -1;
    lwip_init(); ip_addr_set_zero(&zero);
    if (!xemac_add(&nif, &zero, &zero, &zero, mac, RTLNET_PS_GEM_BASE)) return -1;
    netif_set_default(&nif); netif_set_up(&nif);
    if (dhcp_start(&nif) != ERR_OK) return -1;
    initialized = 1;
    return 0;
}
void rtlnet_network_poll(void)
{
    if (!initialized) return;
    xemacif_input(&nif);
    sys_check_timeouts();
    if ((uint32_t)(plat_uptime_ms() - last_link) >= 1000u) {
        last_link = plat_uptime_ms(); eth_link_detect(&nif);
    }
    if ((uint32_t)(plat_uptime_ms() - last_rx_check) >= 5000u) {
        last_rx_check = plat_uptime_ms();
        xemacpsif_resetrx_on_no_rxdata(&nif); /* Zynq GEM RX erratum, SDK workaround. */
    }
}
void rtlnet_network_show(void)
{
    printf("PHY %08lx link=%d DHCP=%d IP %s\r\n", (unsigned long)phy_id,
        netif_is_link_up(&nif), dhcp_supplied_address(&nif), ip4addr_ntoa(netif_ip4_addr(&nif)));
}
int video_udp_open(uint32_t ip, uint16_t dst_port)
{
    const ip4_addr_t *hop;
    struct eth_addr *mac;
    const ip4_addr_t *cached;
    uint32_t start, request_time;
    if (!initialized || !dhcp_supplied_address(&nif) || !dst_port) return -1;
    video_udp_close();
    IP_ADDR4(&destination, ip >> 24, ip >> 16, ip >> 8, ip);
    hop = ip4_addr_netcmp(ip_2_ip4(&destination), netif_ip4_addr(&nif), netif_ip4_netmask(&nif)) ?
        ip_2_ip4(&destination) : netif_ip4_gw(&nif);
    if (ip4_addr_isany_val(*hop)) return -1;
    start = plat_ticks(); request_time = start - 250000u;
    while (etharp_find_addr(&nif, hop, &mac, &cached) < 0) {
        uint32_t now = plat_ticks();
        if ((uint32_t)(now - start) >= 1000000u) return -1;
        if ((uint32_t)(now - request_time) >= 250000u) {
            (void)etharp_request(&nif, hop); request_time = now;
        }
        rtlnet_network_poll();
    }
    pcb = udp_new();
    if (!pcb) return -1;
    port = dst_port; return 0;
}
void video_udp_close(void) { if (pcb) { udp_remove(pcb); pcb = NULL; } }
int video_udp_send(const uint8_t *data, uint32_t len)
{
    uint32_t start = plat_ticks();
    if (!pcb || len > 1472u) { dropped++; return -1; }
    do {
        struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)len, PBUF_RAM);
        if (p) {
            uint32_t t = plat_ticks();
            err_t rc = pbuf_take(p, data, (u16_t)len);
            copy_time += (uint32_t)(plat_ticks() - t);
            t = plat_ticks();
            if (rc == ERR_OK) rc = udp_sendto(pcb, p, &destination, port);
            pbuf_free(p); send_time += (uint32_t)(plat_ticks() - t);
            if (rc == ERR_OK) { sent++; return 0; }
        }
        retries++; rtlnet_network_poll();
    } while ((uint32_t)(plat_ticks() - start) < 2000u);
    dropped++; return -1;
}
void video_udp_counters(uint32_t *s, uint32_t *d, uint32_t *r)
{ if(s)*s=sent; if(d)*d=dropped; if(r)*r=retries; }
void video_udp_profile(uint64_t *c, uint64_t *s)
{ if(c)*c=copy_time; if(s)*s=send_time; }
