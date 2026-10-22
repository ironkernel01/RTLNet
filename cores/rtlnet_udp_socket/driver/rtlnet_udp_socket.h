/*
 * rtlnet_udp_socket.h -- RTLNet UDP socket layer driver
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the one file pair (rtlnet_udp_socket.h / .c) that touches the
 * registers of the rtlnet_udp_socket leaf. Every register offset and bit
 * position of the core is defined here, once; hdl/rtlnet_udp_socket.sv
 * mirrors them as localparams with a pointer to this header. Change both in
 * the same commit: a mismatch makes the firmware open the wrong socket or
 * read the wrong counter, with no error from the hardware (undefined offsets
 * read 0 and ignore writes).
 *
 * The base address is the leaf's window inside the protocol sub-map (board
 * window 0x1_0000 + 0x5000 on the Nexys Video), passed in by the platform
 * layer; nothing here hard-codes it. Register access goes only through
 * rtlnet_mmio.h.
 *
 * This header holds the register map, the types and the function contracts;
 * rtlnet_udp_socket.c holds the per-function commentary.
 *
 * Socket model. NUM_SOCKETS sockets (CAPS[7:0]), each bound to one local UDP
 * port. A received datagram goes to the lowest-index enabled socket whose
 * LOCAL_PORT matches the destination port. With CONNECT_ON_RX the socket's
 * REMOTE_IP / REMOTE_PORT / REMOTE_MAC follow the sender of the last
 * datagram delivered; an application sending with the metadata flag
 * USE_SOCKET_REMOTE then answers the last sender. The layer resolves no
 * addresses (no ARP): REMOTE_MAC is the next-hop MAC.
 */
#ifndef RTLNET_UDP_SOCKET_H
#define RTLNET_UDP_SOCKET_H

#include <stdint.h>   /* uint8_t, uint16_t, uint32_t, uintptr_t */

/* ------------------------------------------------------------------------- */
/* Identification                                                            */
/* ------------------------------------------------------------------------- */
#define RTLNET_UDPS_ID_VALUE           0x55445053u   /* "UDPS" */
#define RTLNET_UDPS_VERSION_VALUE      0x10222026u   /* register map 10-22-2026 */

/* ------------------------------------------------------------------------- */
/* Global registers (ID, VERSION, CAPS at RTLNET_REG_* of rtlnet_mmio.h)     */
/* ------------------------------------------------------------------------- */
#define RTLNET_UDPS_REG_CTRL           0x00Cu   /* RW: RX_CSUM_CHECK; W: CNT_CLEAR pulse */
#define RTLNET_UDPS_REG_STATUS         0x010u   /* RO */
#define RTLNET_UDPS_REG_RX_NO_SOCKET   0x014u   /* RO counter: valid datagram, no enabled socket */
#define RTLNET_UDPS_REG_RX_BAD         0x018u   /* RO counter: fragment, IHL != 5, length, checksum */
#define RTLNET_UDPS_REG_RX_FIFO_DROPS  0x01Cu   /* RO counter: socket matched, RX FIFO full */
#define RTLNET_UDPS_REG_TX_FRAMES      0x020u   /* RO counter: frames sent */
#define RTLNET_UDPS_REG_TX_DROPS       0x024u   /* RO counter: every dropped application datagram */
#define RTLNET_UDPS_REG_RX_DATAGRAMS   0x028u   /* RO counter: datagrams delivered */

/* CAPS fields. */
#define RTLNET_UDPS_CAPS_SOCKETS_MASK  0x000000FFu
#define RTLNET_UDPS_CAPS_RX_KB_SHIFT   8u
#define RTLNET_UDPS_CAPS_TX_KB_SHIFT   16u
#define RTLNET_UDPS_CAPS_KB_MASK       0xFFu
#define RTLNET_UDPS_CAPS_CSUM_CHECK    (1u << 24)

/* CTRL bits. */
#define RTLNET_UDPS_CTRL_RX_CSUM_CHECK (1u << 0)    /* verify non-zero UDP checksums on receive */
#define RTLNET_UDPS_CTRL_CNT_CLEAR     (1u << 16)   /* self-clearing, reads 0 */

/* STATUS bits. */
#define RTLNET_UDPS_STATUS_ENABLE       (1u << 0)   /* leaf enabled by the wrapper */
#define RTLNET_UDPS_STATUS_RX_BUSY      (1u << 1)   /* a received frame is being processed */
#define RTLNET_UDPS_STATUS_TX_ACTIVE    (1u << 2)   /* a datagram is being sent or dropped */
#define RTLNET_UDPS_STATUS_RX_FIFO_FULL (1u << 3)   /* no free RX slot (the application is not reading) */
#define RTLNET_UDPS_STATUS_TX_PENDING   (1u << 4)   /* a transmit descriptor waits */

/* ------------------------------------------------------------------------- */
/* Per-socket registers: socket n at BASE + n * STRIDE                       */
/* ------------------------------------------------------------------------- */
#define RTLNET_UDPS_SOCK_BASE          0x100u
#define RTLNET_UDPS_SOCK_STRIDE        0x040u
#define RTLNET_UDPS_MAX_SOCKETS        60u      /* 0x100 + 0x40 * n stays inside 4 KiB */

#define RTLNET_UDPS_SOCK_CTRL          0x00u    /* RW: ENABLE, CONNECT_ON_RX */
#define RTLNET_UDPS_SOCK_LOCAL_PORT    0x04u    /* RW [15:0] */
#define RTLNET_UDPS_SOCK_REMOTE_IP     0x08u    /* RW, first octet in [31:24]; written by CONNECT_ON_RX */
#define RTLNET_UDPS_SOCK_REMOTE_PORT   0x0Cu    /* RW [15:0]; written by CONNECT_ON_RX */
#define RTLNET_UDPS_SOCK_REMOTE_MAC_HI 0x10u    /* RW [15:0] = octets 0, 1 */
#define RTLNET_UDPS_SOCK_REMOTE_MAC_LO 0x14u    /* RW [31:0] = octets 2..5 */
#define RTLNET_UDPS_SOCK_RX_DATAGRAMS  0x18u    /* RO counter */
#define RTLNET_UDPS_SOCK_RX_DROPS      0x1Cu    /* RO counter: RX FIFO full */
#define RTLNET_UDPS_SOCK_TX_DATAGRAMS  0x20u    /* RO counter */
#define RTLNET_UDPS_SOCK_TX_DROPS      0x24u    /* RO counter: disabled socket, length mismatch */

#define RTLNET_UDPS_SOCK_REG(n, field) \
    (RTLNET_UDPS_SOCK_BASE + ((uint32_t)(n) * RTLNET_UDPS_SOCK_STRIDE) + (field))

#define RTLNET_UDPS_SCTRL_ENABLE        (1u << 0)
#define RTLNET_UDPS_SCTRL_CONNECT_ON_RX (1u << 1)

/* Options for rtlnet_udp_socket_open(). */
#define RTLNET_UDPS_OPEN_CONNECT_ON_RX  RTLNET_UDPS_SCTRL_CONNECT_ON_RX

/* Largest datagram payload either direction (1500 - 20 - 8). */
#define RTLNET_UDPS_MAX_PAYLOAD        1472u

/* ------------------------------------------------------------------------- */
/* Types                                                                     */
/* ------------------------------------------------------------------------- */
typedef struct {
    uint32_t num_sockets;
    uint32_t rx_buf_kb;
    uint32_t tx_buf_kb;
    int      csum_check;        /* receive checksum verification available */
} rtlnet_udp_socket_caps_t;

typedef struct {
    uint32_t ip;                /* first octet in bits 31:24 */
    uint16_t port;
    uint8_t  mac[6];            /* mac[0] first on the wire */
} rtlnet_udp_socket_remote_t;

typedef struct {
    uint16_t local_port;
    int      enabled;
    int      connect_on_rx;
} rtlnet_udp_socket_config_t;

typedef struct {
    uint32_t rx_datagrams;
    uint32_t rx_drops;
    uint32_t tx_datagrams;
    uint32_t tx_drops;
} rtlnet_udp_socket_sock_counters_t;

typedef struct {
    uint32_t rx_datagrams;
    uint32_t rx_no_socket;
    uint32_t rx_bad;
    uint32_t rx_fifo_drops;
    uint32_t tx_frames;
    uint32_t tx_drops;
} rtlnet_udp_socket_counters_t;

/* ------------------------------------------------------------------------- */
/* Functions. Return 0 on success, -1 on a bad argument or a missing core.   */
/* `sock` is checked against CAPS on every call.                             */
/* ------------------------------------------------------------------------- */
int rtlnet_udp_socket_probe(uintptr_t base, rtlnet_udp_socket_caps_t *caps);
int rtlnet_udp_socket_open(uintptr_t base, uint32_t sock, uint16_t local_port, uint32_t options);
int rtlnet_udp_socket_close(uintptr_t base, uint32_t sock);
int rtlnet_udp_socket_set_connect_on_rx(uintptr_t base, uint32_t sock, int on);
int rtlnet_udp_socket_get_config(uintptr_t base, uint32_t sock, rtlnet_udp_socket_config_t *cfg);
int rtlnet_udp_socket_find_port(uintptr_t base, uint16_t local_port);
int rtlnet_udp_socket_set_remote(uintptr_t base, uint32_t sock, const rtlnet_udp_socket_remote_t *remote);
int rtlnet_udp_socket_get_remote(uintptr_t base, uint32_t sock, rtlnet_udp_socket_remote_t *remote);
int rtlnet_udp_socket_read_sock_counters(uintptr_t base, uint32_t sock, rtlnet_udp_socket_sock_counters_t *c);
int rtlnet_udp_socket_read_counters(uintptr_t base, rtlnet_udp_socket_counters_t *c);
void rtlnet_udp_socket_clear_counters(uintptr_t base);
void rtlnet_udp_socket_set_rx_csum_check(uintptr_t base, int on);
uint32_t rtlnet_udp_socket_status(uintptr_t base);

#endif /* RTLNET_UDP_SOCKET_H */
