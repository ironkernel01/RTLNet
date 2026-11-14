/*
 * cc.h -- lwIP compiler/platform glue of the desktop netif test
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: the minimum arch/cc.h lwIP asks of a port, for the host gcc; an
 * assertion failure prints its text and stops the test.
 */
#ifndef LWIP_NETIF_HOST_ARCH_CC_H
#define LWIP_NETIF_HOST_ARCH_CC_H

#include <stdio.h>    /* printf */
#include <stdlib.h>   /* abort */

#define LWIP_PLATFORM_DIAG(x)    do { printf x; } while (0)
#define LWIP_PLATFORM_ASSERT(x)  do { printf("lwIP assertion: %s (%s:%d)\n", x, __FILE__, __LINE__); abort(); } while (0)

#endif /* LWIP_NETIF_HOST_ARCH_CC_H */
