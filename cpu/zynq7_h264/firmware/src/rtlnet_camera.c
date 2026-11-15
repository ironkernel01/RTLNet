/* Purpose: own every access to the board camera-admission register file.
 * Overview: AXI-Lite CDC completes each transaction; statistics are live samples.
 * Revision: 11-14-2026. Initial ZCAM driver; physical base supplied by callers.
 */
#include "rtlnet_camera.h"
#include "rtlnet_mmio.h"
int rtlnet_camera_probe(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_ZCAM_REG_ID) == RTLNET_ZCAM_ID_VALUE ? 0 : -1;
}
void rtlnet_camera_enable(uintptr_t base, int enabled)
{
    rtlnet_reg_write32(base, RTLNET_ZCAM_REG_CTRL, enabled ? RTLNET_ZCAM_CTRL_ENABLE : 0u);
}
int rtlnet_camera_mode(uintptr_t base, unsigned mode)
{
    if (mode > RTLNET_ZCAM_MODE_1080P15) return -1;
    rtlnet_reg_write32(base, RTLNET_ZCAM_REG_MODE, mode);
    return 0;
}
uint32_t rtlnet_camera_pts_step(uintptr_t base)
{
    return rtlnet_reg_read32(base, RTLNET_ZCAM_REG_PTS_STEP);
}
void rtlnet_camera_read_state(uintptr_t base, rtlnet_camera_state_t *s)
{
    s->enabled = rtlnet_reg_read32(base, RTLNET_ZCAM_REG_CTRL);
    s->mode = rtlnet_reg_read32(base, RTLNET_ZCAM_REG_MODE);
    s->status = rtlnet_reg_read32(base, RTLNET_ZCAM_REG_STATUS);
    s->seen = rtlnet_reg_read32(base, RTLNET_ZCAM_REG_SEEN);
    s->admitted = rtlnet_reg_read32(base, RTLNET_ZCAM_REG_ADMITTED);
}
