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
 * Applications: the TCP echo server (rtlnet_tcp_echo.c, port 7) and the TCP
 * iperf server (rtlnet_lwiperf.c, port 5001); both run at the same time and
 * the sizes below hold both.
 *
 * Memory (all in the LMB block RAM, .bss; only the DMA buffers live in the
 * AXI BRAM, rtlnet_lwip_netif.c):
 *   MEM_SIZE                      64 KiB heap: tcp_write copies of echoed
 *                                 data (TCP_WRITE_FLAG_COPY: up to TCP_WND
 *                                 of 8 x 1460 B per echo connection, 37 KB
 *                                 used with four connections), outgoing
 *                                 headers, lwiperf state
 *   PBUF_POOL_SIZE x BUFSIZE      64 x 1536 B = 96 KiB: every received frame
 *                                 is copied into a pool pbuf
 *   MEMP (PCBs, segments, pbufs)  about 9 KiB (MEMP_NUM_TCP_SEG 256 and
 *                                 MEMP_NUM_PBUF 96 for the 24-segment send
 *                                 queue: the iperf reverse test queues one
 *                                 ROM pbuf and one TCP segment per MSS)
 * The whole image ends at 381 KiB of the 512 KiB LMB (text 158 KiB, data 2,
 * bss 233, heap 2, stack 8).
 * TCP send buffer: 24 x MSS (35040 B), TCP_SND_QUEUELEN 4 x that / MSS = 96.
 * The reverse (-R) test needs it: the PC acknowledges anywhere from every
 * second to every eighth segment (the rate follows the pacing of the frames
 * and the window the board advertises), so the send buffer must cover several
 * acknowledgement intervals to keep the link busy (8 x MSS: 68 Mbit/s,
 * 16: 75, 24: 83, 32: 83, the CPU limit).
 * TCP window: 8 x MSS (11680 B). With an 8 x MSS send buffer, 4 x MSS gave 81
 * and 6 x MSS 88 Mbit/s PC to board but only 56 Mbit/s board to PC (about
 * 6000 ACKs per test against 29000 with 8 x MSS); 16 x MSS gained nothing and
 * overflowed the wrapper's CPU receive FIFO. The FIFO is the hard bound: the
 * PC sends a whole window per connection at line rate while the CPU drains
 * slower (a frame costs about 135 us), so the sum of the open windows should
 * fit it (CPU_RX_FIFO_KB 32 in the board top). 8 x MSS fits two connections;
 * four echo connections plus the iperf stream together open 58 KB, and the
 * frames that do not fit show as "CPU FIFO drops" (11 for the four-connection
 * echo test, 374 under the broadcast flood plus echo plus iperf) and as TCP
 * retransmissions; every test still passes.
 * LWIP_CHKSUM_ALGORITHM 3 (32-bit reads, the software checksum is the largest
 * single cost of a frame without offload) took PC to board from 77 to 85
 * Mbit/s and board to PC from 63 to 68.
 *
 * Drift rule: PBUF_POOL_SIZE must hold TCP_WND for every TCP connection that
 * can be open at once, plus margin: (TCP_WND / TCP_MSS) x connections + 16 =
 * 8 x 6 (four echo, two iperf) + 16 = 64 pbufs. A TCP_WND larger than the
 * pool lets the peer send more than lwIP can buffer; frames are then dropped
 * in the netif (counted as rx_no_pbuf) and TCP retransmits, which shows as low
 * throughput, not as an error. The pool is rarely loaded (the main loop
 * delivers every frame as it arrives: peak 3 of 64 in the echo test), the
 * echo server holds a received pbuf until it is echoed.
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
#define MEM_SIZE                        (64 * 1024)
#define MEMP_NUM_PBUF                   96
#define MEMP_NUM_RAW_PCB                1
#define MEMP_NUM_UDP_PCB                2
#define MEMP_NUM_TCP_PCB                12
#define MEMP_NUM_TCP_PCB_LISTEN         4
#define MEMP_NUM_TCP_SEG                256
#define MEMP_NUM_REASSDATA              2
#define MEMP_NUM_FRAG_PBUF              4
#define MEMP_NUM_ARP_QUEUE              8
#define MEMP_NUM_SYS_TIMEOUT            (LWIP_NUM_SYS_TIMEOUT_INTERNAL + 2)
#define PBUF_POOL_SIZE                  64
#define PBUF_POOL_BUFSIZE               1536
#define PBUF_LINK_HLEN                  14
#define ETH_PAD_SIZE                    0

/* Sockets options of the raw API: SOF_REUSEADDR lets the iperf server rebind past TIME_WAIT. */
#define SO_REUSE                        1

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
#define TCP_WND                         (8 * TCP_MSS)
#define TCP_SND_BUF                     (24 * TCP_MSS)
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
#define LWIP_CHKSUM_ALGORITHM           3

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

/* rtlnet_lwiperf (TCP iperf 2 server): idle timeout of a test connection. */
#define RTLNET_LWIPERF_TCP_MAX_IDLE_SEC 10U

/* LWIP_DEBUG stays undefined (lwIP tests it with #ifdef). */

#endif /* LWIPOPTS_H */
