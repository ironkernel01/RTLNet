/*
 * Purpose: define the Zybo camera-wrapper control register contract.
 * Overview: offsets mirror rtlnet_zybo_video.sv's capture-domain register file.
 *   Change both together: drift selects the wrong mode or labels captured frames incorrectly.
 *   Sensor configuration remains a separate I2C operation; mode writes do not program the sensor.
 * Revision: 11-15-2026. CAPS bit 4 marks the own-receiver image.
 */
#ifndef RTLNET_ZYNQ_CAMERA_H
#define RTLNET_ZYNQ_CAMERA_H
#include <stdint.h>

#define RTLNET_ZCAM_ID_VALUE         0x5a43414du
#define RTLNET_ZCAM_REG_ID           0x000u
#define RTLNET_ZCAM_REG_VERSION      0x004u
#define RTLNET_ZCAM_REG_CAPS         0x008u
#define RTLNET_ZCAM_REG_CTRL         0x00cu
#define RTLNET_ZCAM_REG_MODE         0x010u
#define RTLNET_ZCAM_REG_STATUS       0x014u
#define RTLNET_ZCAM_REG_PTS_STEP     0x018u
#define RTLNET_ZCAM_REG_SEEN         0x020u
#define RTLNET_ZCAM_REG_ADMITTED     0x024u
#define RTLNET_ZCAM_CAPS_OWN_RX      0x10u   /* CAPS bit 4: the image has the own receiver (rtlnet_csi2_rx at RTLNET_PLAT_RX_BASE); VERSION 0x11152026 */
#define RTLNET_ZCAM_CTRL_ENABLE      1u
#define RTLNET_ZCAM_MODE_720P30      0u
#define RTLNET_ZCAM_MODE_1080P15     1u
#define RTLNET_ZCAM_STATUS_ODD_LINE  1u

typedef struct {
    uint32_t enabled, mode, status, seen, admitted;
} rtlnet_camera_state_t;
/* Single register owner; each call receives the platform's physical base. */
int rtlnet_camera_probe(uintptr_t base);
void rtlnet_camera_enable(uintptr_t base, int enabled);
int rtlnet_camera_mode(uintptr_t base, unsigned mode);
uint32_t rtlnet_camera_pts_step(uintptr_t base);
void rtlnet_camera_read_state(uintptr_t base, rtlnet_camera_state_t *state);

#endif
