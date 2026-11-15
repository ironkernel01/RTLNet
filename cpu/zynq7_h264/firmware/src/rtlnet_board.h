/* Purpose: describe DDR readiness to the reused encoder session.
 * Overview: the ARM application executes in DDR after FSBL/ps7_init; it cannot run before DDR initialization.
 * Revision: 11-14-2026. Initial PS board service.
 */
#ifndef RTLNET_BOARD_H
#define RTLNET_BOARD_H
int board_ddr_calibrated(void);
#endif
