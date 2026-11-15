/* Purpose: independently exercise PHY identity, link and speed interpretation.
 * Overview: E/F wire status words distinguish layouts; unknown IDs cannot start a link.
 * Revision: 11-14-2026. Initial host test and negative control.
 */
#include "rtlnet_phy.h"
#include <stdio.h>
int main(int argc, char **argv)
{
    int failures = 0;
    (void)argv;
    failures += rtlnet_phy_speed(0x001cc915u, 0x8400u) != 1000u;
    failures += rtlnet_phy_speed(0x001cc915u, 0x4400u) != 100u;
    failures += rtlnet_phy_speed(0x001cc915u, 0x0400u) != 10u;
    failures += rtlnet_phy_speed(0x001cc916u, 0x0024u) != 1000u;
    failures += rtlnet_phy_speed(0x001cc916u, 0x0014u) != 100u;
    failures += rtlnet_phy_speed(0x001cc916u, 0x0004u) != 10u;
    failures += rtlnet_phy_speed(0x001cc915u, 0x0024u) != 0u;
    failures += rtlnet_phy_speed(0x001cc916u, 0x8400u) != 0u;
    failures += rtlnet_phy_speed(0x12345678u, 0xffffu) != 0u;
    failures += argc > 1;
    printf("PHY_HOST_TEST: %s checks=9\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
