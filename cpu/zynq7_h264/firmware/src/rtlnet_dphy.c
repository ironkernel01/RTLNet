/* Purpose: read D-PHY control/version without disturbing camera reception.
 * Overview: no writes or inferred training/alignment/lock measurements.
 * Revision: 11-14-2026.
 */
#include "rtlnet_dphy.h"
#include "rtlnet_mmio.h"
void rtlnet_dphy_read(uintptr_t base, rtlnet_dphy_state_t *state)
{
    state->control = rtlnet_reg_read32(base, 0u);
    state->version = rtlnet_reg_read32(base, 12u);
}
