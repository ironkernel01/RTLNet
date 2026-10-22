/*
 * main.c -- RTLNet Nexys Video firmware application loop
 *
 * Copyright (C) 2026 IronKernel. All rights reserved.
 *
 * Role: bring up the platform, start the console, then poll forever: one
 * received character at a time into the CLI line editor, and the periodic
 * platform work (heartbeat LED), and the network manager's link monitor (MAC
 * speed follow, DHCP on link up).
 */
#include "cli_commands.h"
#include "menu.h"
#include "rtlnet_netmgr.h"
#include "rtlnet_platform.h"

int main(void);

/*
 * main -- firmware entry, called by crt0 _start.
 * Steps:
 *   1. plat_init: UART Lite, AXI Timer, LEDs.
 *   2. cli_start: banner, menu engine, network bring-up, first prompt.
 *   3. Loop: feed console characters to Menu_InputChar; plat_poll
 *      (heartbeat); netmgr_poll (link monitor, DHCP events).
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
        netmgr_poll();
    }
}
