/* Purpose: camera receiver (rtlnet_csi2_rx) bring-up and diagnostics; see rtlnet_rx.h.
 * Overview: all register access goes through the core driver (rtlnet_csi2_rx.h) and rtlnet_mmio.h. The receiver core is identified by
 *   its ID and VERSION registers before it is configured.
 * Revision: 11-15-2026.
 */
#include "rtlnet_rx.h"
#include "rtlnet_platform.h"
#include "rtlnet_camera.h"
#include "rtlnet_csi2_rx.h"
#include "rtlnet_mmio.h"
#include <stdio.h>

/* rtlnet_rx_probe -- check that the receiver core with the camera front end is at its address; a clear message names what was read. */
int rtlnet_rx_probe(void)
{
    uint32_t id = rtlnet_reg_read32(RTLNET_PLAT_RX_BASE, RTLNET_REG_ID);
    uint32_t version = rtlnet_reg_read32(RTLNET_PLAT_RX_BASE, RTLNET_REG_VERSION);
    if (id == RTLNET_CSI2_ID_VALUE && version == RTLNET_CSI2_VERSION_CAMERA) return 0;
    printf("camera receiver core not found at 0x%08lx: ID 0x%08lx (expected 0x%08lx) VERSION 0x%08lx (expected 0x%08lx)\r\n",
        (unsigned long)RTLNET_PLAT_RX_BASE, (unsigned long)id, (unsigned long)RTLNET_CSI2_ID_VALUE, (unsigned long)version,
        (unsigned long)RTLNET_CSI2_VERSION_CAMERA);
    return -1;
}

/* rtlnet_rx_init -- configure the receiver and let it track the sensor (the sensor is still in reset or standby). */
int rtlnet_rx_init(void)
{
    rtlnet_csi2_rx_caps_t caps;
    uintptr_t b = RTLNET_PLAT_RX_BASE;
    if (rtlnet_rx_probe() != 0) return -1;
    if (rtlnet_csi2_rx_probe(b, &caps) != RTLNET_CSI2_OK || !caps.camera) return -1;
    if (rtlnet_csi2_rx_rx_control(b, 1, 1, 3u, RTLNET_RX_DEFAULT_BITREV) != RTLNET_CSI2_OK) return -1; /* hold in soft reset while configuring */
    if (rtlnet_csi2_rx_set_settle(b, RTLNET_RX_DEFAULT_SETTLE) != RTLNET_CSI2_OK) return -1;
    if (rtlnet_csi2_rx_set_filter(b, 0u, 0x2Bu) != RTLNET_CSI2_OK) return -1;                        /* virtual channel 0, RAW10 */
    if (rtlnet_csi2_rx_set_taps(b, RTLNET_RX_DEFAULT_TAP0, RTLNET_RX_DEFAULT_TAP1) != RTLNET_CSI2_OK) return -1;
    if (rtlnet_csi2_rx_set_black(b, RTLNET_RX_DEFAULT_BLACK) != RTLNET_CSI2_OK) return -1;
    if (rtlnet_csi2_rx_set_wb(b, RTLNET_RX_GAIN_R_720, RTLNET_RX_GAIN_G_720, RTLNET_RX_GAIN_B_720) != RTLNET_CSI2_OK) return -1;
    if (rtlnet_csi2_rx_set_phase(b, RTLNET_RX_DEFAULT_PHASE) != RTLNET_CSI2_OK) return -1;
    if (rtlnet_csi2_rx_set_gamma(b, RTLNET_RX_DEFAULT_GAMMA) != RTLNET_CSI2_OK) return -1;
    if (rtlnet_csi2_rx_set_green_eq(b, RTLNET_RX_DEFAULT_GEQ) != RTLNET_CSI2_OK) return -1;
    if (rtlnet_csi2_rx_set_highlight(b, RTLNET_RX_HL_ON, RTLNET_RX_HL_LEVEL_720) != RTLNET_CSI2_OK) return -1;
    if (rtlnet_csi2_rx_set_source(b, RTLNET_CSI2_SRC_CAMERA) != RTLNET_CSI2_OK) return -1;          /* camera only: no pattern frames */
    if (rtlnet_csi2_rx_rx_control(b, 1, 0, 3u, RTLNET_RX_DEFAULT_BITREV) != RTLNET_CSI2_OK) return -1;
    return 0;
}

int rtlnet_rx_set_mode(unsigned mode)
{
    if (rtlnet_csi2_rx_set_wb(RTLNET_PLAT_RX_BASE, mode ? RTLNET_RX_GAIN_R_1080 : RTLNET_RX_GAIN_R_720, mode ? RTLNET_RX_GAIN_G_1080 : RTLNET_RX_GAIN_G_720,
                              mode ? RTLNET_RX_GAIN_B_1080 : RTLNET_RX_GAIN_B_720) != RTLNET_CSI2_OK) return -1;
    if (rtlnet_csi2_rx_set_highlight(RTLNET_PLAT_RX_BASE, RTLNET_RX_HL_ON, mode ? RTLNET_RX_HL_LEVEL_1080 : RTLNET_RX_HL_LEVEL_720) != RTLNET_CSI2_OK) return -1;
    return rtlnet_csi2_rx_set_mode(RTLNET_PLAT_RX_BASE, mode ? RTLNET_CSI2_MODE_1080P30 : RTLNET_CSI2_MODE_720P30) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_set_taps(uint32_t t0, uint32_t t1)
{
    return rtlnet_csi2_rx_set_taps(RTLNET_PLAT_RX_BASE, t0, t1) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_set_wb(uint32_t r, uint32_t g, uint32_t b)
{
    return rtlnet_csi2_rx_set_wb(RTLNET_PLAT_RX_BASE, r, g, b) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_set_black(uint32_t v)
{
    return rtlnet_csi2_rx_set_black(RTLNET_PLAT_RX_BASE, v) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_set_phase(uint32_t v)
{
    return rtlnet_csi2_rx_set_phase(RTLNET_PLAT_RX_BASE, v) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_set_gamma(int on)
{
    return rtlnet_csi2_rx_set_gamma(RTLNET_PLAT_RX_BASE, on) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_set_geq(int on)
{
    return rtlnet_csi2_rx_set_green_eq(RTLNET_PLAT_RX_BASE, on) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_set_highlight(int on, uint32_t level)
{
    return rtlnet_csi2_rx_set_highlight(RTLNET_PLAT_RX_BASE, on, level) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_set_bitrev(int on)
{
    uint32_t ctrl;
    ctrl = rtlnet_reg_read32(RTLNET_PLAT_RX_BASE, RTLNET_CSI2_REG_RX_CTRL);
    return rtlnet_csi2_rx_rx_control(RTLNET_PLAT_RX_BASE, (int)(ctrl & RTLNET_CSI2_CTRL_ENABLE), 0, (ctrl >> RTLNET_CSI2_CTRL_LANE_SHIFT) & 3u, on) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_set_settle(uint32_t v)
{
    return rtlnet_csi2_rx_set_settle(RTLNET_PLAT_RX_BASE, v) == RTLNET_CSI2_OK ? 0 : -1;
}
int rtlnet_rx_clear(void)
{
    return rtlnet_csi2_rx_clear_counters(RTLNET_PLAT_RX_BASE, RTLNET_CSI2_CLEAR_ALL) == RTLNET_CSI2_OK ? 0 : -1;
}

/* rtlnet_rx_show -- one "key=value" group per line so that a host script can parse it. */
int rtlnet_rx_show(void)
{
    rtlnet_csi2_rx_rxstate_t s;
    uintptr_t b = RTLNET_PLAT_RX_BASE;
    static const char *const names[RTLNET_CSI2_CNT_COUNT] = {"ECC_CORR", "ECC_UNC", "CRC", "SOT", "FRAMES", "DT", "TRUNC", "OVF", "SIZE", "ORPHAN", "LEN", "CLKLOSS"};
    if (rtlnet_csi2_rx_read_rxstate(b, &s) != RTLNET_CSI2_OK) return -1;
    printf("RX ctrl=0x%02lx status=0x%03lx taps=%lu,%lu settle=%lu filter=0x%04lx lines=%lu pixels=%lu\r\n",
        (unsigned long)s.ctrl, (unsigned long)s.status, (unsigned long)(s.taps & 31u), (unsigned long)((s.taps >> 8) & 31u),
        (unsigned long)s.settle, (unsigned long)s.filter, (unsigned long)s.lines, (unsigned long)s.pixels);
    printf("RX counters");
    for (unsigned i = 0; i < RTLNET_CSI2_CNT_COUNT; i++) printf(" %s=%lu", names[i], (unsigned long)s.counters[i]);
    printf("\r\n");
    printf("RX proc black=%lu wb=0x%03lx,0x%03lx,0x%03lx phase=%lu gamma=%lu geq=%lu bitrev=%lu clkrun=%lu dlyrdy=%lu lp=%lu,%lu frames_out=%lu\r\n",
        (unsigned long)rtlnet_reg_read32(b, RTLNET_CSI2_REG_BLACK),
        (unsigned long)rtlnet_reg_read32(b, RTLNET_CSI2_REG_WB_R), (unsigned long)rtlnet_reg_read32(b, RTLNET_CSI2_REG_WB_G),
        (unsigned long)rtlnet_reg_read32(b, RTLNET_CSI2_REG_WB_B), (unsigned long)rtlnet_reg_read32(b, RTLNET_CSI2_REG_PHASE),
        (unsigned long)(rtlnet_reg_read32(b, RTLNET_CSI2_REG_PROC) & 1u), (unsigned long)((rtlnet_reg_read32(b, RTLNET_CSI2_REG_PROC) >> 1) & 1u), (unsigned long)((s.ctrl >> 4) & 1u),
        (unsigned long)(s.status & RTLNET_CSI2_RXST_CLK_RUN), (unsigned long)((s.status >> 5) & 1u),
        (unsigned long)((s.status >> RTLNET_CSI2_RXST_LP_D0_SHIFT) & 3u), (unsigned long)((s.status >> RTLNET_CSI2_RXST_LP_D1_SHIFT) & 3u),
        (unsigned long)rtlnet_reg_read32(b, RTLNET_CSI2_REG_FRAME_COUNT));
    {
        uint32_t proc = rtlnet_reg_read32(b, RTLNET_CSI2_REG_PROC), mr = 0, mg = 0, mb = 0;
        (void)rtlnet_csi2_rx_read_raw_max(b, &mr, &mg, &mb);
        printf("RX highlight=%lu level=%lu rawmax r=%lu g=%lu b=%lu\r\n", (unsigned long)((proc & RTLNET_CSI2_PROC_HIGHLIGHT) ? 1u : 0u),
            (unsigned long)rtlnet_reg_read32(b, RTLNET_CSI2_REG_HL_LEVEL), (unsigned long)mr, (unsigned long)mg, (unsigned long)mb);
    }
    return 0;
}
