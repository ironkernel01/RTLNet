/*
 * rtlnet_netmgr.c -- Nexys Video network manager: bring-up, link monitor,
 *                    configuration
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
#include "rtlnet_dhcp.h"
#include "rtlnet_eth_mac.h"
#include "rtlnet_eth_protocol.h"
#include "rtlnet_fmt.h"
#include "rtlnet_icmp.h"
#include "rtlnet_iperf.h"
#include "rtlnet_phy_rtl8211e.h"
#include "rtlnet_platform.h"
#include "rtlnet_udp_echo.h"
#include "rtlnet_udp_socket.h"

#define NETMGR_PHY_SETTLE_MS   30u    /* RTL8211E: 30 ms from reset release to MDIO access */
#define NETMGR_ADV_FULL        (RTLNET_PHY_ADV_10F | RTLNET_PHY_ADV_100F | RTLNET_PHY_ADV_1000F)
#define NETMGR_ADV_HALF        (RTLNET_PHY_ADV_10H | RTLNET_PHY_ADV_100H | RTLNET_PHY_ADV_1000H)
#define NETMGR_ADV_10          (RTLNET_PHY_ADV_10H | RTLNET_PHY_ADV_10F)
#define NETMGR_ADV_100         (RTLNET_PHY_ADV_100H | RTLNET_PHY_ADV_100F)
#define NETMGR_ADV_1000        (RTLNET_PHY_ADV_1000H | RTLNET_PHY_ADV_1000F)

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
    g_cfg.speed_mbps  = 0u;
    g_cfg.duplex      = NETMGR_DUPLEX_AUTO;
    g_cfg.autoneg     = 1;
    g_cfg.adv_mask    = 0u;
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
 * netmgr_adv_effective -- advertisement the PHY is given with auto-negotiation.
 * Steps:
 *   1. An explicit mask (advertise command) wins.
 *   2. Else full-duplex modes (half with "duplex half"), limited to the
 *      configured speed when one is set.
 * Returns: RTLNET_PHY_ADV_* mask (never 0 for a valid configuration).
 */
uint32_t netmgr_adv_effective(void)
{
    uint32_t adv;
    if (g_cfg.adv_mask != 0u) {
        return g_cfg.adv_mask;
    }
    adv = (g_cfg.duplex == NETMGR_DUPLEX_HALF) ? NETMGR_ADV_HALF : NETMGR_ADV_FULL;
    if (g_cfg.speed_mbps == 10u) {
        adv &= NETMGR_ADV_10;
    } else if (g_cfg.speed_mbps == 100u) {
        adv &= NETMGR_ADV_100;
    } else if (g_cfg.speed_mbps == 1000u) {
        adv &= NETMGR_ADV_1000;
    }
    return adv;
}

/*
 * netmgr_apply_phy -- program speed/duplex/auto-negotiation into the PHY.
 * Steps:
 *   1. Auto-negotiation: write the effective advertisement, enable and
 *      restart AN.
 *   2. Forced: 10 or 100 Mb/s with the configured duplex (full by default).
 * Returns: RTLNET_PHY_OK, a driver error, or -1 when the PHY is absent.
 */
int netmgr_apply_phy(void)
{
    int rc;
    if (!g_present.phy) {
        return -1;
    }
    if (g_cfg.autoneg) {
        rc = rtlnet_phy_rtl8211e_advertise_set(&g_mdio, netmgr_adv_effective());
        if (rc == RTLNET_PHY_OK) {
            rc = rtlnet_phy_rtl8211e_autoneg_restart(&g_mdio);
        }
        return rc;
    }
    return rtlnet_phy_rtl8211e_force(&g_mdio,
                                     (g_cfg.speed_mbps == 10u) ? RTLNET_PHY_SPEED_10 : RTLNET_PHY_SPEED_100,
                                     g_cfg.duplex != NETMGR_DUPLEX_HALF);
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
 * protocol wrapper (the effective address follows a DHCP lease by itself).
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
 * phy_bringup -- MDIO bus, PHY identity, RX clock delay, advertisement.
 * Steps:
 *   1. MDIO driver init (core ID), MDC calibration against the AXI timer.
 *   2. Wait for the core's power-on PHY reset, then the PHY settle time.
 *   3. Probe PHYID; enable the RGMII RX delay (read-back verified).
 *   4. Apply the speed/duplex/advertisement configuration (restarts AN).
 * Returns: nothing; results in g_present.
 */
static void phy_bringup(void)
{
    uint32_t id = 0u;
    int rc = rtlnet_mdio_init(&g_mdio, RTLNET_PLAT_MDIO_BASE, RTLNET_PHY_RTL8211E_ADDR_DEFAULT, mdio_delay_us, NULL);
    g_present.mdio = (rc == RTLNET_MDIO_OK) ? 1 : 0;
    if (!g_present.mdio) {
        return;
    }
    (void)rtlnet_mdio_calibrate(&g_mdio, mdio_now_ticks, RTLNET_PLAT_TICKS_PER_US, &g_present.mdc_half_ns);
    rc = rtlnet_mdio_wait_por(&g_mdio);
    if (rc == RTLNET_MDIO_OK) {
        plat_delay_ms(NETMGR_PHY_SETTLE_MS);
        rc = rtlnet_phy_rtl8211e_probe(&g_mdio, &id);
    }
    g_present.phy_id = id;
    if (rc == RTLNET_PHY_OK) {
        rc = rtlnet_phy_rtl8211e_enable_rx_delay(&g_mdio, &g_present.rgmii_before, &g_present.rgmii_after);
        g_present.phy = 1;
        if (rc == RTLNET_PHY_OK) {
            rc = netmgr_apply_phy();
        }
    }
    g_present.phy_rc = rc;
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
    phy_bringup();

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
    g_next_poll_ms = plat_uptime_ms();

    if (g_present.mac || g_present.mdio || g_present.prot) {
        fmt_printf("Network: MAC %s, MDIO %s, PHY %s (ID 0x%08X, RX delay reg 0x%04X -> 0x%04X), protocol %s\n",
                   g_present.mac ? "ok" : "absent", g_present.mdio ? "ok" : "absent",
                   g_present.phy ? ((g_present.phy_rc == 0) ? "ok" : "error") : "absent",
                   (unsigned)g_present.phy_id, (unsigned)g_present.rgmii_before, (unsigned)g_present.rgmii_after,
                   g_present.prot ? "ok" : "absent");
    } else {
        fmt_printf("Network cores not in this build.\n");
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
        fmt_printf("\n%%DHCP: lease lost, static address in use\n");
        event_end();
    }
}

/*
 * netmgr_poll -- link monitor, every NETMGR_POLL_MS.
 * Steps:
 *   1. Read PHY status (BMCR, BMSR, PHYSR, ANLPAR, GBSR).
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
    if (g_present.phy && rtlnet_phy_rtl8211e_status(&g_mdio, &st) == RTLNET_PHY_OK) {
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
