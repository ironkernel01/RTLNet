/* Purpose: report exactly the diagnostics exposed by the retained D-PHY IP.
 * Overview: AXI control/version are readable; tap/alignment status is not exposed.
 * Revision: 11-14-2026.
 */
#ifndef RTLNET_DPHY_H
#define RTLNET_DPHY_H
#include <stdint.h>
typedef struct {
    uint32_t control;
    uint32_t version;
} rtlnet_dphy_state_t;
#define RTLNET_DPHY_BASE 0x43c00000u
#define RTLNET_DPHY_CONFIGURED_TAPS 12u
void rtlnet_dphy_read(uintptr_t base, rtlnet_dphy_state_t *state);
#endif
