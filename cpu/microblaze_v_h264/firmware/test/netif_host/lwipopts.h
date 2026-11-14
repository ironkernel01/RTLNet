/*
 * lwipopts.h -- lwIP options of the desktop test of the DMA netif (rtlnet_lwip_netif.c)
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the firmware options (src/lwip/lwipopts.h) with the changes the host
 * test needs: 8-byte memory alignment for the 64-bit host and a heap that
 * holds a few frames. The zero-copy options come from the build line
 * (-DRTLNET_NETIF_ZERO_COPY_RX=0/1, -DRTLNET_NETIF_ZERO_COPY_TX=0/1); the
 * checksum flags per netif and the pbuf pool are those of the firmware.
 */
#ifndef LWIPOPTS_NETIF_HOST_H
#define LWIPOPTS_NETIF_HOST_H

#include "../../src/lwip/lwipopts.h"

#undef MEM_ALIGNMENT
#define MEM_ALIGNMENT                   8
#undef MEM_SIZE
#define MEM_SIZE                        (16 * 1024)

#endif /* LWIPOPTS_NETIF_HOST_H */
