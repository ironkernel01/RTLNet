/*
 * rtlnet_netmgr.c -- network manager: bring-up, link monitor, configuration
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * See rtlnet_netmgr.h for the contract. Context: main loop only (no
 * interrupt touches this state).
 */
#include "rtlnet_netmgr.h"

#include <stddef.h>   /* NULL */

#include "menu.h"
#include "rtlnet_arp.h"
#include "rtlnet_board.h"
#include "rtlnet_cpupath.h"
#include "rtlnet_dhcp.h"
#include "rtlnet_eth_mac.h"
#include "rtlnet_eth_protocol.h"
#include "rtlnet_fmt.h"
#include "rtlnet_icmp.h"
#include "rtlnet_iperf.h"
#include "rtlnet_lwip.h"
#include "rtlnet_lwip_netif.h"
#include "rtlnet_offload.h"
#include "rtlnet_phy.h"
#include "rtlnet_platform.h"
#include "rtlnet_tcp_echo.h"
#include "rtlnet_tcp_iperf.h"
#include "rtlnet_udp_echo.h"
#include "rtlnet_udp_socket.h"

#define NETMGR_PHY_SETTLE_MS   30u    /* PHY: 30 ms from reset release to MDIO access (the slowest PHY of the table, RTL8211E) */
#define NETMGR_PHY_ADDR_FIRST  1u     /* MDIO address the bus context starts with; InitPHY scans for the real one */

static netmgr_config_t  g_cfg;
static netmgr_present_t g_present;
static netmgr_link_t    g_link;
static rtlnet_mdio_t    g_mdio;
static uint32_t         g_next_poll_ms;

/*
 * mdio_delay_us -- MDIO driver delay hook (AXI timer busy-wait).
 * Returns: nothing.
 */
static void mdio_delay_us(void *user, uint32_t us)
{
    (void)user;
    plat_delay_us(us);
}

/*
 * mdio_now_ticks -- MDIO driver calibration clock (free-running timer).
 * Returns: current tick count.
 */
static uint32_t mdio_now_ticks(void *user)
{
    (void)user;
    return plat_ticks();
}

/*
 * event_end -- finish an asynchronous event message: redisplay the prompt
 * and the line being typed.
 * Returns: nothing.
 */
static void event_end(void)
{
    Menu_Redisplay();
}

/*
 * netmgr_config_defaults -- power-on configuration.
 * Returns: nothing.
 */
void netmgr_config_defaults(void)
{
    static const uint8_t mac_default[6] = { 0x02u, 0x49u, 0x4Bu, 0x52u, 0x4Eu, 0x01u };   /* rtlnet_pkg default */
    g_cfg.adv_mask    = netmgr_adv_supported();
    g_cfg.shutdown    = 0;
    g_cfg.static_ip   = NETMGR_DEFAULT_IP;
    g_cfg.netmask     = NETMGR_DEFAULT_MASK;
    g_cfg.gateway     = NETMGR_DEFAULT_GW;
    for (unsigned i = 0; i < 6u; i++) {
        g_cfg.mac[i] = mac_default[i];
    }
    g_cfg.dhcp_auto   = 1;
    g_cfg.iperf_port  = NETMGR_IPERF_PORT;
    g_cfg.echo_enable = 1;
    g_cfg.echo_socket = (int)NETMGR_ECHO_SOCKET;
    g_cfg.tcp_echo_enable = 1;
    g_cfg.tcp_echo_port = RTLNET_TCP_ECHO_PORT_DEFAULT;
    g_cfg.tcp_iperf_enable = 1;
    g_cfg.tcp_iperf_port = RTLNET_TCP_IPERF_PORT_DEFAULT;
    cpupath_config_defaults();
    for (unsigned i = 0; i < NETMGR_NUM_SOCKETS; i++) {
        netmgr_socket_cfg_t *k = &g_cfg.sock[i];
        k->open          = 0;
        k->local_port    = 0u;
        k->remote_ip     = 0u;
        k->remote_port   = 0u;
        k->connect_on_rx = 0;
        for (unsigned j = 0; j < 6u; j++) {
            k->remote_mac[j] = 0u;
        }
    }
    g_cfg.sock[NETMGR_ECHO_SOCKET].open          = 1;
    g_cfg.sock[NETMGR_ECHO_SOCKET].local_port    = NETMGR_ECHO_PORT;
    g_cfg.sock[NETMGR_ECHO_SOCKET].connect_on_rx = 1;
}

/*
 * netmgr_adv_supported -- every full-duplex mode of the board.
 * Steps:
 *   1. LINK_CAPS of the system registers (ETHS_LINK_*), mapped to RTLNET_PHY_ADV_*.
 * Returns: RTLNET_PHY_ADV_* mask of the supported full-duplex modes, never 0 ("speed auto").
 */
uint32_t netmgr_adv_supported(void)
{
    uint32_t caps = board_link_caps();
    uint32_t adv = 0u;
    adv |= (caps & ETHS_LINK_10F) ? RTLNET_PHY_ADV_10F : 0u;
    adv |= (caps & ETHS_LINK_100F) ? RTLNET_PHY_ADV_100F : 0u;
    adv |= (caps & ETHS_LINK_1000F) ? RTLNET_PHY_ADV_1000F : 0u;
    return adv;
}

/*
 * netmgr_adv_effective -- advertisement the PHY is given with auto-negotiation.
 * The configured full-duplex set, written by the speed command (the last
 * command wins), limited to the modes of the board; half-duplex bits are never part of it.
 * Returns: RTLNET_PHY_ADV_* mask, never 0.
 */
uint32_t netmgr_adv_effective(void)
{
    uint32_t adv = g_cfg.adv_mask & netmgr_adv_supported();
    return (adv != 0u) ? adv : netmgr_adv_supported();
}

/*
 * netmgr_apply_phy -- program the speed setting into the PHY.
 * Steps:
 *   1. Write the effective advertisement (full-duplex modes only).
 *   2. Enable and restart auto-negotiation; the link always auto-negotiates.
 * Returns: RTLNET_PHY_OK, a driver error, or -1 when the PHY is absent.
 */
int netmgr_apply_phy(void)
{
    int rc;
    if (!g_present.phy) {
        return -1;
    }
    rc = g_present.phy_driver->advertise_set(&g_mdio, netmgr_adv_effective());
    if (rc == RTLNET_PHY_OK) {
        rc = g_present.phy_driver->autoneg_restart(&g_mdio);
    }
    return rc;
}

/*
 * netmgr_apply_shutdown -- MAC receive/transmit enable from "shutdown".
 * Returns: nothing (no effect while the link is down; link up applies it).
 */
void netmgr_apply_shutdown(void)
{
    if (g_present.mac && g_link.up) {
        rtlnet_eth_mac_enable(RTLNET_PLAT_MAC_BASE, !g_cfg.shutdown, !g_cfg.shutdown);
    }
}

/*
 * netmgr_apply_addresses -- node MAC, static IP, netmask and gateway into the
 * protocol wrapper (the effective address follows a DHCP lease by itself),
 * then into lwIP (InitLWIP compares and reconfigures in place).
 * Returns: nothing.
 */
void netmgr_apply_addresses(void)
{
    if (!g_present.prot) {
        return;
    }
    rtlnet_eth_protocol_set_mac(RTLNET_PLAT_PROT_BASE, g_cfg.mac);
    rtlnet_eth_protocol_set_static_ip(RTLNET_PLAT_PROT_BASE, g_cfg.static_ip);
    rtlnet_eth_protocol_set_netmask(RTLNET_PLAT_PROT_BASE, g_cfg.netmask);
    rtlnet_eth_protocol_set_gateway(RTLNET_PLAT_PROT_BASE, g_cfg.gateway);
    (void)InitLWIP();
}

/*
 * netmgr_apply_tcp_echo -- TCP echo server enable and port into the lwIP
 * application (applied at once when lwIP runs, else when it starts).
 * Returns: nothing.
 */
void netmgr_apply_tcp_echo(void)
{
    rtlnet_tcp_echo_config(g_cfg.tcp_echo_enable, (uint16_t)g_cfg.tcp_echo_port);
}

/*
 * netmgr_apply_tcp_iperf -- TCP iperf server enable and port into the lwIP
 * application (applied at once when lwIP runs, else when it starts).
 * Returns: nothing.
 */
void netmgr_apply_tcp_iperf(void)
{
    rtlnet_tcp_iperf_config(g_cfg.tcp_iperf_enable, (uint16_t)g_cfg.tcp_iperf_port);
}

/*
 * netmgr_apply_iperf -- iperf server port.
 * Returns: driver result, -1 when absent.
 */
int netmgr_apply_iperf(void)
{
    if (!g_present.iperf) {
        return -1;
    }
    return rtlnet_iperf_set_port(RTLNET_PLAT_IPERF_BASE, g_cfg.iperf_port);
}

/*
 * netmgr_apply_socket -- open/close one socket and set its remote endpoint.
 * Returns: 0, or -1 when the socket layer is absent or rejects the setting.
 */
int netmgr_apply_socket(unsigned index)
{
    const netmgr_socket_cfg_t *k;
    rtlnet_udp_socket_remote_t r;
    int rc;
    if (!g_present.udp || index >= NETMGR_NUM_SOCKETS) {
        return -1;
    }
    k = &g_cfg.sock[index];
    if (!k->open) {
        return rtlnet_udp_socket_close(RTLNET_PLAT_UDP_BASE, index);
    }
    r.ip   = k->remote_ip;
    r.port = (uint16_t)k->remote_port;
    for (unsigned j = 0; j < 6u; j++) {
        r.mac[j] = k->remote_mac[j];
    }
    rc = rtlnet_udp_socket_set_remote(RTLNET_PLAT_UDP_BASE, index, &r);
    if (rc == 0) {
        rc = rtlnet_udp_socket_open(RTLNET_PLAT_UDP_BASE, index, (uint16_t)k->local_port,
                                    k->connect_on_rx ? RTLNET_UDPS_OPEN_CONNECT_ON_RX : 0u);
    }
    return rc;
}

/*
 * netmgr_apply_echo -- UDP echo enable and socket selection.
 * Returns: 0, or -1 when absent or the socket index is rejected.
 */
int netmgr_apply_echo(void)
{
    int rc = 0;
    if (!g_present.echo) {
        return -1;
    }
    if (g_cfg.echo_socket < 0) {
        rtlnet_udp_echo_select_any(RTLNET_PLAT_ECHO_BASE);
    } else {
        rc = rtlnet_udp_echo_select_socket(RTLNET_PLAT_ECHO_BASE, (uint32_t)g_cfg.echo_socket);
    }
    rtlnet_udp_echo_enable(RTLNET_PLAT_ECHO_BASE, g_cfg.echo_enable);
    return rc;
}

/*
 * netmgr_apply_dhcp_auto -- DHCP AUTO flag (the firmware's start-on-link-up intent).
 * Returns: nothing.
 */
void netmgr_apply_dhcp_auto(void)
{
    if (g_present.dhcp) {
        rtlnet_dhcp_set_auto(RTLNET_PLAT_DHCP_BASE, g_cfg.dhcp_auto);
    }
}

/*
 * InitPHY -- the whole PHY bring-up in one place, in order.
 * Steps:
 *   1. MDIO driver on the MDIO core (core ID); absent core: NETMGR_PHY_NO_MDIO.
 *   2. Wait for the core's power-on PHY reset to finish, then the PHY settle time.
 *   3. MDC calibration against the AXI timer (half period in ns).
 *   4. Find the PHY on the bus and read its ID (rtlnet_phy_find); the ID selects the driver (rtlnet_phy_select); an
 *      ID outside the table gets the generic Clause 22 driver and is printed.
 *   5. The driver's bring-up (RTL8211E: RX clock delay, LEDs, EEE off; generic: none).
 *   6. The configured advertisement, then the auto-negotiation restart (netmgr_apply_phy).
 *   7. One summary line on the console.
 * Called at boot (netmgr_init, before InitLWIP) and after every PHY reset
 * (CLI "phy reset"), so the driver's settings are always re-applied.
 * Returns: NETMGR_PHY_OK or the first failing step (NETMGR_PHY_*); the
 *          details stay in netmgr_present().
 */
int InitPHY(void)
{
    uint32_t id = 0u;
    uint8_t addr = (uint8_t)NETMGR_PHY_ADDR_FIRST;
    int rc;

    g_present.phy = 0;
    g_present.phy_id = 0u;
    g_present.phy_driver = NULL;
    g_present.phy_summary[0] = '\0';
    rc = rtlnet_mdio_init(&g_mdio, RTLNET_PLAT_MDIO_BASE, (uint8_t)NETMGR_PHY_ADDR_FIRST, mdio_delay_us, NULL);
    g_present.mdio = (rc == RTLNET_MDIO_OK) ? 1 : 0;
    if (!g_present.mdio) {
        g_present.phy_rc = NETMGR_PHY_NO_MDIO;
        return NETMGR_PHY_NO_MDIO;
    }
    if (rtlnet_mdio_wait_por(&g_mdio) != RTLNET_MDIO_OK) {
        g_present.phy_rc = NETMGR_PHY_POR_TIMEOUT;
        fmt_printf("PHY: MDIO core power-on reset did not finish\n");
        return NETMGR_PHY_POR_TIMEOUT;
    }
    plat_delay_ms(NETMGR_PHY_SETTLE_MS);
    (void)rtlnet_mdio_calibrate(&g_mdio, mdio_now_ticks, RTLNET_PLAT_TICKS_PER_US, &g_present.mdc_half_ns);
    if (rtlnet_phy_find(&g_mdio, &addr, &id) != RTLNET_MDIO_OK) {
        g_present.phy_rc = NETMGR_PHY_NOT_FOUND;
        fmt_printf("PHY: no PHY answers on the MDIO bus\n");
        return NETMGR_PHY_NOT_FOUND;
    }
    g_mdio.phy_addr = addr;
    g_present.phy_addr = addr;
    g_present.phy_id = id;
    g_present.phy_driver = rtlnet_phy_select(id);
    g_present.phy = 1;
    if (rtlnet_phy_is_generic(g_present.phy_driver)) {
        fmt_printf("PHY: ID 0x%08X at address %u has no driver in the table, using the generic Clause 22 driver\n",
                   (unsigned)id, (unsigned)addr);
    }
    if (g_present.phy_driver->init(&g_mdio, g_present.phy_summary) != 0) {
        g_present.phy_rc = NETMGR_PHY_INIT_FAIL;
        fmt_printf("PHY: %s bring-up failed: %s\n", g_present.phy_driver->name, g_present.phy_summary);
        return NETMGR_PHY_INIT_FAIL;
    }
    if (netmgr_apply_phy() != RTLNET_PHY_OK) {
        g_present.phy_rc = NETMGR_PHY_AN_FAIL;
        fmt_printf("PHY: advertisement / auto-negotiation restart failed\n");
        return NETMGR_PHY_AN_FAIL;
    }
    g_present.phy_rc = NETMGR_PHY_OK;
    fmt_printf("PHY: %s ID 0x%08X at address %u, MDC half period %u ns, %s, auto-negotiation restarted\n",
               g_present.phy_driver->name, (unsigned)id, (unsigned)addr, (unsigned)g_present.mdc_half_ns,
               g_present.phy_summary);
    return NETMGR_PHY_OK;
}

/*
 * netmgr_phy_reset -- hardware PHY reset through the MDIO core, then InitPHY.
 * Steps:
 *   1. rtlnet_mdio_phy_reset pulses the PHY reset pin (the link monitor sees
 *      the link go down by itself through PHYSR).
 *   2. InitPHY re-applies RX delay, LEDs, EEE and the advertisement.
 * Returns: the InitPHY result, NETMGR_PHY_NO_MDIO without the MDIO core.
 */
int netmgr_phy_reset(void)
{
    if (!g_present.mdio) {
        return NETMGR_PHY_NO_MDIO;
    }
    (void)rtlnet_mdio_phy_reset(&g_mdio);
    return InitPHY();
}

/*
 * netmgr_init -- probe every core and apply the default configuration.
 * Returns: nothing. Prints one summary line per subsystem.
 */
void netmgr_init(void)
{
    netmgr_config_defaults();
    g_link.up = 0;
    g_link.speed_mbps = 0u;
    g_link.full_duplex = 0;
    g_link.rx_ready = 0;
    g_link.ups = 0u;
    g_link.downs = 0u;
    g_link.last_change_ms = 0u;
    g_link.lease = 0;
    g_link.lease_ip = 0u;

    g_present.mac   = (rtlnet_eth_mac_init(RTLNET_PLAT_MAC_BASE, NULL) == RTLNET_ETH_MAC_OK);
    g_present.prot  = (rtlnet_eth_protocol_probe(RTLNET_PLAT_PROT_BASE) == RTLNET_PROTO_OK);
    g_present.arp   = g_present.prot && (rtlnet_arp_probe(RTLNET_PLAT_ARP_BASE) == RTLNET_ARP_OK);
    g_present.icmp  = g_present.prot && (rtlnet_icmp_probe(RTLNET_PLAT_ICMP_BASE) == RTLNET_ICMP_OK);
    g_present.dhcp  = g_present.prot && (rtlnet_dhcp_probe(RTLNET_PLAT_DHCP_BASE) == RTLNET_DHCP_OK);
    g_present.iperf = g_present.prot && (rtlnet_iperf_probe(RTLNET_PLAT_IPERF_BASE) == RTLNET_IPERF_OK);
    g_present.udp   = g_present.prot && (rtlnet_udp_socket_probe(RTLNET_PLAT_UDP_BASE, NULL) == 0);
    g_present.echo  = (rtlnet_udp_echo_probe(RTLNET_PLAT_ECHO_BASE) == 0);
    g_present.phy   = 0;
    g_present.phy_rc = 0;
    (void)InitPHY();

    /* CPU network path: the classifier leaves DROP-ALL (broadcast storm
     * default) before lwIP sees any frame; then the DMA netif. */
    rtlnet_features_discover();
    g_present.cpupath_rc = cpupath_init();
    g_present.cls = cpupath_cls_present();
    g_present.dma = (rtlnet_netif_hw_init() == 0);
    netmgr_apply_tcp_echo();
    netmgr_apply_tcp_iperf();

    if (g_present.mac) {
        rtlnet_eth_mac_set_link(RTLNET_PLAT_MAC_BASE, 0);
    }
    if (g_present.prot) {
        /* Node MAC: keep the wrapper's reset value (rtlnet_pkg default). */
        rtlnet_eth_protocol_get_mac(RTLNET_PLAT_PROT_BASE, g_cfg.mac);
    }
    netmgr_apply_addresses();
    netmgr_apply_dhcp_auto();
    (void)netmgr_apply_iperf();
    for (unsigned i = 0; i < NETMGR_NUM_SOCKETS; i++) {
        if (g_cfg.sock[i].open) {
            (void)netmgr_apply_socket(i);
        }
    }
    (void)netmgr_apply_echo();
    g_present.lwip_rc = InitLWIP();
    g_next_poll_ms = plat_uptime_ms();

    if (g_present.mac || g_present.mdio || g_present.prot) {
        fmt_printf("Network: MAC %s, MDIO %s, PHY %s (%s, ID 0x%08X), protocol %s\n",
                   g_present.mac ? "ok" : "absent", g_present.mdio ? "ok" : "absent",
                   g_present.phy ? ((g_present.phy_rc == NETMGR_PHY_OK) ? "ok" : "error") : "absent",
                   g_present.phy ? g_present.phy_driver->name : "none",
                   (unsigned)g_present.phy_id, g_present.prot ? "ok" : "absent");
        fmt_printf("CPU path: DMA %s, classifier %s, lwIP %s\n", g_present.dma ? "ok" : "absent",
                   g_present.cls ? ((g_present.cpupath_rc == CPUPATH_OK) ? "broadcast storm limit 10/100 ms" :
                                    cpupath_result_text(g_present.cpupath_rc)) : "absent",
                   (g_present.lwip_rc >= 0) ? "up (TCP echo, TCP iperf)" : "not started");
    } else {
        fmt_printf("Network cores not present. CPU path: DMA %s.\n", g_present.dma ? "ok" : "absent");
    }
}

/*
 * link_up -- PHY reports link: program the MAC and start DHCP when enabled.
 * Steps:
 *   1. MAC speed from PHYSR, receive/transmit enable (unless shutdown),
 *      LINK_UP; wait (bounded) for the receive path to qualify RXC.
 *   2. LED, event line, DHCP start (auto) when no lease is held.
 * Returns: nothing.
 */
static void link_up(const rtlnet_phy_status_t *st)
{
    g_link.up          = 1;
    g_link.speed_mbps  = rtlnet_phy_speed_mbps(st->speed);
    g_link.full_duplex = st->full_duplex;
    g_link.ups++;
    g_link.last_change_ms = plat_uptime_ms();
    g_link.rx_ready = 0;
    if (g_present.mac) {
        (void)rtlnet_eth_mac_set_speed(RTLNET_PLAT_MAC_BASE, g_link.speed_mbps);
        rtlnet_eth_mac_enable(RTLNET_PLAT_MAC_BASE, !g_cfg.shutdown, !g_cfg.shutdown);
        rtlnet_eth_mac_set_link(RTLNET_PLAT_MAC_BASE, 1);
        g_link.rx_ready = (rtlnet_eth_mac_wait_rx_ready(RTLNET_PLAT_MAC_BASE, NETMGR_RX_READY_POLLS) ==
                           RTLNET_ETH_MAC_OK);
    }
    plat_led_set(NETMGR_LED_LINK, 1);
    rtlnet_lwip_set_link(1);
    (void)InitLWIP();
    fmt_printf("\n%%LINK: eth0 up, %u Mb/s %s duplex, MAC receive %s\n", (unsigned)g_link.speed_mbps,
               g_link.full_duplex ? "full" : "half", g_link.rx_ready ? "ready" : "NOT ready");
    if (g_present.dhcp && g_cfg.dhcp_auto && !g_link.lease) {
        rtlnet_dhcp_start(RTLNET_PLAT_DHCP_BASE);
        fmt_printf("%%DHCP: discovery started\n");
    }
    event_end();
}

/*
 * link_down -- PHY lost the link: clear the MAC link flag.
 * Returns: nothing.
 */
static void link_down(void)
{
    g_link.up = 0;
    g_link.downs++;
    g_link.last_change_ms = plat_uptime_ms();
    if (g_present.mac) {
        rtlnet_eth_mac_set_link(RTLNET_PLAT_MAC_BASE, 0);
    }
    plat_led_set(NETMGR_LED_LINK, 0);
    rtlnet_lwip_set_link(0);
    fmt_printf("\n%%LINK: eth0 down\n");
    event_end();
}

/*
 * lease_watch -- report DHCP lease changes.
 * Returns: nothing.
 */
static void lease_watch(void)
{
    rtlnet_dhcp_lease_t l;
    if (!g_present.dhcp || rtlnet_dhcp_read_lease(RTLNET_PLAT_DHCP_BASE, &l) != RTLNET_DHCP_OK) {
        return;
    }
    if (l.bound && (!g_link.lease || l.lease_ip != g_link.lease_ip)) {
        g_link.lease = 1;
        g_link.lease_ip = l.lease_ip;
        plat_led_set(NETMGR_LED_LEASE, 1);
        (void)InitLWIP();
        fmt_printf("\n%%DHCP: bound %u.%u.%u.%u mask %u.%u.%u.%u router %u.%u.%u.%u lease %u s\n",
                   (unsigned)(l.lease_ip >> 24), (unsigned)((l.lease_ip >> 16) & 0xFFu),
                   (unsigned)((l.lease_ip >> 8) & 0xFFu), (unsigned)(l.lease_ip & 0xFFu),
                   (unsigned)(l.lease_mask >> 24), (unsigned)((l.lease_mask >> 16) & 0xFFu),
                   (unsigned)((l.lease_mask >> 8) & 0xFFu), (unsigned)(l.lease_mask & 0xFFu),
                   (unsigned)(l.lease_router >> 24), (unsigned)((l.lease_router >> 16) & 0xFFu),
                   (unsigned)((l.lease_router >> 8) & 0xFFu), (unsigned)(l.lease_router & 0xFFu),
                   (unsigned)l.lease_time_s);
        event_end();
    } else if (!l.bound && g_link.lease) {
        g_link.lease = 0;
        plat_led_set(NETMGR_LED_LEASE, 0);
        (void)InitLWIP();
        fmt_printf("\n%%DHCP: lease lost, static address in use\n");
        event_end();
    }
}

/*
 * netmgr_poll -- link monitor, every NETMGR_POLL_MS.
 * Steps:
 *   1. Read PHY status through the selected driver (link, speed, duplex, partner abilities).
 *   2. Link up/down edges call link_up/link_down; a speed change while up
 *      re-programs the MAC (its receive path resets by itself).
 *   3. Watch the DHCP lease.
 * Returns: nothing.
 */
void netmgr_poll(void)
{
    rtlnet_phy_status_t st;
    uint32_t now = plat_uptime_ms();
    if ((int32_t)(now - g_next_poll_ms) < 0) {
        return;
    }
    g_next_poll_ms = now + NETMGR_POLL_MS;
    if (g_present.phy && g_present.phy_driver->status(&g_mdio, &st) == RTLNET_PHY_OK) {
        int up = st.speed_valid ? 1 : 0;
        if (up && !g_link.up) {
            link_up(&st);
        } else if (!up && g_link.up) {
            link_down();
        } else if (up && rtlnet_phy_speed_mbps(st.speed) != g_link.speed_mbps) {
            link_down();
            link_up(&st);
        }
    }
    lease_watch();
    if (g_present.prot) {
        /* Consistency check: the RTL identity and lwIP agree (no-op when they do). */
        (void)InitLWIP();
    }
}

/*
 * netmgr_config -- the running configuration (CLI edits it, then applies).
 * Returns: pointer to the configuration.
 */
netmgr_config_t *netmgr_config(void)
{
    return &g_cfg;
}

/*
 * netmgr_present -- which cores answered at start-up, PHY bring-up results.
 * Returns: pointer to the presence record.
 */
const netmgr_present_t *netmgr_present(void)
{
    return &g_present;
}

/*
 * netmgr_link -- link monitor state.
 * Returns: pointer to the link record.
 */
const netmgr_link_t *netmgr_link(void)
{
    return &g_link;
}

/*
 * netmgr_mdio -- the MDIO bus context for PHY register commands.
 * Returns: the context, or NULL when the MDIO core is absent.
 */
const rtlnet_mdio_t *netmgr_mdio(void)
{
    return g_present.mdio ? &g_mdio : NULL;
}
