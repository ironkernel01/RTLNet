/* Purpose: identify the board's E/F PHY and decode its negotiated link status.
 * Overview: pure functions used by the emacps PHY adaptation and host tests.
 *   ID and status fields follow Digilent's RTL8211F PCN and its realtek-21.1 patch.
 * Revision: 11-14-2026. Initial ID-specific PHY contract.
 */
#ifndef RTLNET_PHY_H
#define RTLNET_PHY_H
#include <stdint.h>
#define RTLNET_PHY_ID_E 0x001cc915u
#define RTLNET_PHY_ID_F 0x001cc916u
static inline unsigned rtlnet_phy_speed(uint32_t id, uint16_t status)
{
    unsigned code;
    if (id == RTLNET_PHY_ID_E) {
        if ((status & 0x0400u) == 0u) return 0u;
        code = (status >> 14) & 3u;
    } else if (id == RTLNET_PHY_ID_F) {
        if ((status & 0x0004u) == 0u) return 0u;
        code = (status >> 4) & 3u;
    } else return 0u;
    return code == 2u ? 1000u : (code == 1u ? 100u : (code == 0u ? 10u : 0u));
}
#endif
