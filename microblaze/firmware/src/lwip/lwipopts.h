/*
 * lwipopts.h -- lwIP 2.2.0 configuration of the RTLNet MicroBlaze firmware
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one configuration of the lwIP core that build.ps1 compiles in
 * place from the AMD install (lwip220_v1_3/src/lwip-2.2.0/src). lwIP runs
 * NO_SYS = 1 with the raw API only, from the main loop (no interrupt context
 * ever calls lwIP, so no lightweight protection is needed), IPv4 only, ARP on,
 * TCP on, no DHCP and no AutoIP in lwIP: the node address belongs to the
 * protocol wrapper and its DHCP leaf, and InitLWIP() (rtlnet_lwip.c) copies it
 * into the netif.
 *
 * Applications: the TCP echo server (rtlnet_tcp_echo.c, port 7) and, in the
 * integration phase, the TCP iperf server (lwiperf, port 5001); both run at
 * the same time and the sizes below hold both.
 *
 * Memory (all in the LMB block RAM, .bss; only the DMA buffers live in the
 * AXI BRAM, rtlnet_lwip_netif.c):
 *   MEM_SIZE                      32 KiB heap: tcp_write copies of echoed
 *                                 data, outgoing headers, lwiperf state
 *   PBUF_POOL_SIZE x BUFSIZE      32 x 1536 B = 48 KiB: every received frame
 *                                 is copied into a pool pbuf
 *   MEMP (PCBs, segments, pbufs)  about 16 KiB
 * TCP window and send buffer: 4 x MSS each (5840 B). The bound is the
 * wrapper's CPU receive FIFO, not lwIP memory: the PC sends a whole window
 * per connection at line rate while the CPU drains slower, so the sum of
 * the open windows must fit the FIFO (CPU_RX_FIFO_KB 32 in the board top:
 * five connections of 4 MSS). With the 16 KiB FIFO, four echo connections
 * of 4 MSS overflowed it (24 "CPU FIFO drops", retransmission stalls of
 * about 0.4 s); frames dropped there show as "CPU FIFO drops" in show
 * cpu-path and as TCP retransmissions.
 *
 * Drift consequence: a TCP_WND larger than the pool lets the peer send more
 * than lwIP can buffer; frames are then dropped in the netif (counted as
 * rx_no_pbuf) and TCP retransmits, which shows as low throughput, not as an
 * error.
 */
#ifndef LWIPOPTS_H
#define LWIPOPTS_H

/* Byte order of the MicroBlaze configuration (C_ENDIANNESS 1). */
#define PROCESSOR_LITTLE_ENDIAN

/* System: bare metal, raw API, timers from sys_now() in the main loop. */
#define NO_SYS                          1
#define NO_SYS_NO_TIMERS                0
#define LWIP_TIMERS                     1
#define SYS_LIGHTWEIGHT_PROT            0
#define LWIP_NETCONN                    0
#define LWIP_SOCKET                     0
#define LWIP_NETIF_API                  0
#define LWIP_TCPIP_CORE_LOCKING         0

/* Memory. */
#define MEM_LIBC_MALLOC                 0
#define MEMP_MEM_MALLOC                 0
#define MEM_ALIGNMENT                   4
#define MEM_SIZE                        (32 * 1024)
#define MEMP_NUM_PBUF                   16
#define MEMP_NUM_RAW_PCB                1
#define MEMP_NUM_UDP_PCB                2
#define MEMP_NUM_TCP_PCB                12
#define MEMP_NUM_TCP_PCB_LISTEN         4
#define MEMP_NUM_TCP_SEG                64
#define MEMP_NUM_REASSDATA              2
#define MEMP_NUM_FRAG_PBUF              4
#define MEMP_NUM_ARP_QUEUE              8
#define MEMP_NUM_SYS_TIMEOUT            (LWIP_NUM_SYS_TIMEOUT_INTERNAL + 2)
#define PBUF_POOL_SIZE                  32
#define PBUF_POOL_BUFSIZE               1536
#define PBUF_LINK_HLEN                  14
#define ETH_PAD_SIZE                    0

/* Protocols. */
#define LWIP_IPV4                       1
#define LWIP_IPV6                       0
#define LWIP_ARP                        1
#define LWIP_ETHERNET                   1
#define ARP_TABLE_SIZE                  10
#define ARP_QUEUEING                    1
#define ETHARP_SUPPORT_STATIC_ENTRIES   0
#define LWIP_DHCP                       0
#define LWIP_AUTOIP                     0
#define LWIP_ACD                        0
#define LWIP_IGMP                       0
#define LWIP_DNS                        0
#define LWIP_ICMP                       1
#define LWIP_RAW                        0
#define LWIP_UDP                        1
#define LWIP_TCP                        1
#define IP_FORWARD                      0
#define IP_OPTIONS_ALLOWED              0
#define IP_REASSEMBLY                   1
#define IP_FRAG                         1
#define IP_DEFAULT_TTL                  64

/* TCP. */
#define TCP_MSS                         1460
#define TCP_WND                         (4 * TCP_MSS)
#define TCP_SND_BUF                     (4 * TCP_MSS)
#define TCP_SND_QUEUELEN                ((4 * (TCP_SND_BUF) + (TCP_MSS - 1)) / (TCP_MSS))
#define TCP_QUEUE_OOSEQ                 1
#define TCP_OVERSIZE                    TCP_MSS
#define LWIP_TCP_KEEPALIVE              0
#define LWIP_LISTEN_BACKLOG             0
#define LWIP_TCP_SACK_OUT               0

/* Checksums in software (the CPU path carries frames without offload). */
#define CHECKSUM_GEN_IP                 1
#define CHECKSUM_GEN_UDP                1
#define CHECKSUM_GEN_TCP                1
#define CHECKSUM_GEN_ICMP               1
#define CHECKSUM_CHECK_IP               1
#define CHECKSUM_CHECK_UDP              1
#define CHECKSUM_CHECK_TCP              1
#define CHECKSUM_CHECK_ICMP             1
#define LWIP_CHECKSUM_ON_COPY           0

/* Netif. */
#define LWIP_NETIF_STATUS_CALLBACK      0
#define LWIP_NETIF_LINK_CALLBACK        0
#define LWIP_NETIF_HOSTNAME             0
#define LWIP_SINGLE_NETIF               1
#define LWIP_NETIF_TX_SINGLE_PBUF       0

/* Statistics: the counters show tcp prints. */
#define LWIP_STATS                      1
#define LWIP_STATS_DISPLAY              0
#define LWIP_STATS_LARGE                1
#define LINK_STATS                      1
#define ETHARP_STATS                    1
#define IP_STATS                        1
#define TCP_STATS                       1
#define MEM_STATS                       1
#define MEMP_STATS                      1
#define UDP_STATS                       0
#define ICMP_STATS                      0
#define IPFRAG_STATS                    0
#define SYS_STATS                       0

/* lwiperf (TCP iperf 2 server): idle timeout of a test connection. */
#define LWIPERF_TCP_MAX_IDLE_SEC        10U

/* LWIP_DEBUG stays undefined (lwIP tests it with #ifdef). */

#endif /* LWIPOPTS_H */
