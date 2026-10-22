/*
 * rtlnet_netmgr.h -- Nexys Video network manager: bring-up, link monitor,
 *                    configuration
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: owns the network configuration of the board (the "running
 * configuration") and applies it to the cores through their drivers
 * (cores/<core>/driver): PHY bring-up through rtlnet_mdio /
 * rtlnet_phy_rtl8211e, MAC speed/enable/link through rtlnet_eth_mac, node
 * addresses through rtlnet_eth_protocol, DHCP, iperf, UDP sockets and the UDP
 * echo server; the CPU network path (classifier configuration through
 * rtlnet_cpupath, the AXI DMA netif) and lwIP: InitLWIP() copies the node
 * identity of the protocol wrapper into lwIP at boot (after the protocol
 * core is probed and the classifier configured), on link up, on every DHCP
 * lease change, on a CLI change of the static address, mask, gateway or MAC,
 * and as a consistency check every NETMGR_POLL_MS. The CLI changes the configuration through this module and
 * reads status from the drivers; nothing here prints except link and DHCP
 * events.
 *
 * Main-loop contract: netmgr_init() once after plat_init(); netmgr_poll()
 * from the main loop (it acts every NETMGR_POLL_MS). A core whose ID does not
 * read back is marked absent and skipped, so the same firmware runs on the
 * CPU-only bitstream.
 *
 * Defaults: DHCP auto on (start on link up), static fallback 192.169.1.220/24
 * gateway 192.169.1.1 (the protocol wrapper's reset values,
 * rtlnet_eth_protocol.h), UDP echo on socket 0 port 7 with connect-on-
 * receive, iperf on 5001, auto-negotiation advertising full duplex
 * 10/100/1000 (the MAC is full duplex only), TCP echo (lwIP) on port 7,
 * classifier broadcast storm limit 10 frames per 100 ms.
 *
 * This header holds types, constants and signatures; rtlnet_netmgr.c holds
 * the per-function commentary.
 */
#ifndef RTLNET_NETMGR_H
#define RTLNET_NETMGR_H

#include <stdint.h>   /* uint8_t, uint16_t, uint32_t */

#include "rtlnet_mdio.h"

#define NETMGR_POLL_MS          250u     /* link monitor period */
#define NETMGR_NUM_SOCKETS      4u       /* sockets of the build (UDP socket leaf CAPS) */
#define NETMGR_ECHO_SOCKET      0u
#define NETMGR_ECHO_PORT        7u
#define NETMGR_IPERF_PORT       5001u
#define NETMGR_DEFAULT_IP       0xC0A901DCu   /* 192.169.1.220 */
#define NETMGR_DEFAULT_MASK     0xFFFFFF00u   /* 255.255.255.0 */
#define NETMGR_DEFAULT_GW       0xC0A90101u   /* 192.169.1.1 */
#define NETMGR_LED_LINK         2u       /* led[2]: link up */
#define NETMGR_LED_LEASE        3u       /* led[3]: DHCP lease held */
#define NETMGR_RX_READY_POLLS   20000u   /* MAC receive qualification, about 10 ms of reads */

/* InitPHY() results (first failing step). */
#define NETMGR_PHY_OK           0
#define NETMGR_PHY_NO_MDIO      (-1)    /* MDIO core absent (CPU-only bitstream) */
#define NETMGR_PHY_POR_TIMEOUT  (-2)    /* the MDIO core's power-on PHY reset did not finish */
#define NETMGR_PHY_NOT_FOUND    (-3)    /* no RTL8211E ID on the bus */
#define NETMGR_PHY_RXDLY_FAIL   (-4)    /* RX delay not read back */
#define NETMGR_PHY_LED_FAIL     (-5)    /* LED registers not read back */
#define NETMGR_PHY_EEE_FAIL     (-6)    /* EEE advertisement not cleared */
#define NETMGR_PHY_AN_FAIL      (-7)    /* advertisement / AN restart failed */

/* Duplex setting. */
#define NETMGR_DUPLEX_AUTO      0u
#define NETMGR_DUPLEX_HALF      1u
#define NETMGR_DUPLEX_FULL      2u

typedef struct {
    int      open;
    uint32_t local_port;
    uint32_t remote_ip;
    uint32_t remote_port;
    uint8_t  remote_mac[6];
    int      connect_on_rx;
} netmgr_socket_cfg_t;

typedef struct {
    uint32_t speed_mbps;        /* 0 auto, 10, 100, 1000 */
    uint32_t duplex;            /* NETMGR_DUPLEX_* */
    int      autoneg;           /* 1: auto-negotiation (speed/duplex limit the advertisement) */
    uint32_t adv_mask;          /* RTLNET_PHY_ADV_* explicit advertisement, 0 = derived */
    int      shutdown;          /* 1: MAC receive/transmit disabled */
    uint32_t static_ip;
    uint32_t netmask;
    uint32_t gateway;
    uint8_t  mac[6];
    int      dhcp_auto;
    uint32_t iperf_port;
    int      echo_enable;
    int      echo_socket;       /* -1 = any socket */
    int      tcp_echo_enable;   /* lwIP TCP echo server */
    uint32_t tcp_echo_port;
    netmgr_socket_cfg_t sock[NETMGR_NUM_SOCKETS];
} netmgr_config_t;

typedef struct {
    int      mac;
    int      mdio;
    int      phy;               /* RTL8211E answered with its ID */
    int      prot;
    int      arp;
    int      icmp;
    int      dhcp;
    int      iperf;
    int      udp;
    int      echo;
    int      cls;               /* CPU-path classifier answered "CLSF" */
    int      dma;               /* AXI DMA of the CPU core configured */
    int      cpupath_rc;        /* cpupath_init() result (CPUPATH_*) */
    int      lwip_rc;           /* first InitLWIP() result (RTLNET_LWIP_*) */
    uint32_t phy_id;            /* PHYID1 << 16 | PHYID2 as read */
    int      phy_rc;            /* result of InitPHY (NETMGR_PHY_*) */
    uint16_t rgmii_before;      /* page 0xA4 register 28 before / after the RX delay write */
    uint16_t rgmii_after;
    uint32_t mdc_half_ns;       /* calibrated MDC half period */
} netmgr_present_t;

typedef struct {
    int      up;
    uint32_t speed_mbps;
    int      full_duplex;
    int      rx_ready;          /* MAC qualified RXC after the last link up */
    uint32_t ups;
    uint32_t downs;
    uint32_t last_change_ms;
    int      lease;             /* DHCP lease held (last poll) */
    uint32_t lease_ip;
} netmgr_link_t;

int                     InitPHY(void);
int                     netmgr_phy_reset(void);
void                    netmgr_init(void);
void                    netmgr_poll(void);
netmgr_config_t        *netmgr_config(void);
const netmgr_present_t *netmgr_present(void);
const netmgr_link_t    *netmgr_link(void);
const rtlnet_mdio_t    *netmgr_mdio(void);
uint32_t                netmgr_adv_effective(void);
int                     netmgr_apply_phy(void);
void                    netmgr_apply_shutdown(void);
void                    netmgr_apply_addresses(void);
int                     netmgr_apply_iperf(void);
int                     netmgr_apply_socket(unsigned index);
int                     netmgr_apply_echo(void);
void                    netmgr_apply_dhcp_auto(void);
void                    netmgr_apply_tcp_echo(void);
void                    netmgr_config_defaults(void);

#endif /* RTLNET_NETMGR_H */
