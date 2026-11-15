/* Purpose: cooperative bare-metal ARM application for camera H264 over UDP.
 * Overview: UART MenuBuilder and lwIP run in the foreground; encoder ISR only
 *   services picture ownership. Startup errors park with the failed API named.
 * Revision: 11-14-2026. Initial main loop.
 */
#include "rtlnet_platform.h"
#include "rtlnet_sensor.h"
#include "rtlnet_network.h"
#include "rtlnet_venc.h"
#include "menu.h"
#include <stdio.h>
static void console(const char *s, size_t n)
{
    for (size_t i=0; i<n; i++) {
        if(s[i]=='\n') plat_console_write("\r",1);
        plat_console_write(s+i,1);
    }
}
int main(void)
{
    const MenuIo io = {console};
    plat_init();
    printf("RTLNet Zybo Z7-20: initializing Pcam5C and PS GEM0\r\n");
    venc_init();
    if (rtlnet_sensor_init()) rtlnet_fatal("OV5640 bringup",-1);
    if (rtlnet_network_init()) rtlnet_fatal("GEM0/PHY/lwIP/DHCP",-1);
    if (Menu_Init(&io)) rtlnet_fatal("Menu_Init",-1);
    printf("OV5640 ID 5640; camera 720p30 admitted; DHCP started\r\n");
    Menu_PrintPrompt();
    for (;;) {
        int ch = plat_console_getc();
        if (ch >= 0) Menu_InputChar(ch);
        rtlnet_network_poll(); venc_poll();
    }
}
