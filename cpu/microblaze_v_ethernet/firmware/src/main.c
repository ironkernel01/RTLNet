/*
 * main.c -- RTLNet Ethernet demo firmware application loop
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: bring up the platform, start the console, then poll forever: one
 * received character at a time into the CLI line editor, the periodic
 * platform work (heartbeat LED), lwIP (DMA receive service and timers), and
 * the network manager's link monitor (MAC speed follow, DHCP on link up,
 * InitLWIP on address changes). Entered from the BSP start-up (crt0,
 * crtinit) after .bss is cleared.
 */
#include "cli_commands.h"
#include "menu.h"
#include "rtlnet_lwip.h"
#include "rtlnet_netmgr.h"
#include "rtlnet_platform.h"

int main(void);

/*
 * main -- firmware entry, called by the BSP start-up.
 * Steps:
 *   1. plat_init: XUartLite console, XTmrCtr time base, XIntc 1 ms tick.
 *   2. cli_start: banner, menu engine, network bring-up (netmgr_init:
 *      cores, PHY, classifier, DMA, InitLWIP), first prompt.
 *   3. Loop: feed console characters to Menu_InputChar; plat_poll
 *      (heartbeat); rtlnet_lwip_poll (frames, lwIP timers); netmgr_poll
 *      (link monitor, DHCP events).
 * Returns: never.
 */
int main(void)
{
    plat_init();
    cli_start();
    for (;;) {
        int c = plat_console_getc();
        if (c >= 0) {
            Menu_InputChar(c);
        }
        plat_poll();
        rtlnet_lwip_poll();
        netmgr_poll();
    }
}
