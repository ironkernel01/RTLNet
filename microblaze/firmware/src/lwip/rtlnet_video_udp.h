/*
 * rtlnet_video_udp.h -- UDP datagram output of the video stream through lwIP
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: one unicast UDP socket (udp_new, udp_sendto) that carries the MPEG-TS datagrams of rtlnet_venc to a host and port.
 * video_udp_send copies the datagram into a pbuf (headroom for the UDP, IPv4 and Ethernet headers) and calls udp_sendto,
 * which resolves the host's MAC by ARP and sends the frame through netif_linkoutput (AXI DMA, checksum offload). When lwIP
 * has no pbuf or the transmit DMA is busy, it services the receive path and retries for at most 2 ms, then drops the
 * datagram and returns nonzero; the TS continuity counters make the loss visible. The desktop harness links
 * host_lwip_stub.c, whose version counts the datagrams.
 *
 * Revision: 11-11-2026 (send-time profile)
 */
#ifndef RTLNET_VIDEO_UDP_H
#define RTLNET_VIDEO_UDP_H

#include <stdint.h>   /* uint8_t, uint16_t, uint32_t */

/* Open the socket to ip (host order, first octet in [31:24]) and port. 0 on success, -1 when lwIP is not running or no PCB. */
int  video_udp_open(uint32_t ip, uint16_t port);

/* Close the socket. */
void video_udp_close(void);

/* Send one datagram. 0 when lwIP accepted it, -1 when it was dropped. */
int  video_udp_send(const uint8_t *data, uint32_t len);

/* Counters: datagrams accepted, datagrams dropped, retries. */
void video_udp_counters(uint32_t *sent, uint32_t *dropped, uint32_t *retries);

/* Time spent in video_udp_send, in plat_ticks, since start-up: the copy of the datagram into the pbuf, and everything else (pbuf
 * allocation, udp_sendto with the netif and the DMA, pbuf release, the retries). Counters that only grow; the caller takes differences. */
void video_udp_profile(uint64_t *copy_ticks, uint64_t *send_ticks);

#endif /* RTLNET_VIDEO_UDP_H */
