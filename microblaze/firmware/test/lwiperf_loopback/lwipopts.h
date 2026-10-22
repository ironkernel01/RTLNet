/*
 * lwipopts.h -- lwIP options of the desktop loopback test of rtlnet_lwiperf
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the firmware options (src/lwip/lwipopts.h) with the changes the host
 * test needs: the loopback interface 127.0.0.1 (the test client and the iperf
 * server share one lwIP instance), 8-byte memory alignment for the 64-bit
 * host, a larger heap. Everything that shapes TCP (MSS, window, send buffer,
 * pbuf pool, PCB counts) stays as in the firmware.
 */
#ifndef LWIPOPTS_LOOPBACK_H
#define LWIPOPTS_LOOPBACK_H

#include "../../src/lwip/lwipopts.h"

#undef LWIP_SINGLE_NETIF
#define LWIP_SINGLE_NETIF               0
#undef LWIP_NETIF_LOOPBACK
#define LWIP_NETIF_LOOPBACK             1
#undef MEM_ALIGNMENT
#define MEM_ALIGNMENT                   8
#undef MEM_SIZE
#define MEM_SIZE                        (256 * 1024)

#endif /* LWIPOPTS_LOOPBACK_H */
