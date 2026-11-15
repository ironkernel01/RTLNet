/* Purpose: initialize the OV5640 sensor (register tables) and the camera receiver.
 * Overview: PS I2C0 owns address 0x3c; PS GPIO EMIO0 (pin 54) owns camera reset.
 *   Polling operations return errors; bus-idle waits have a 100 ms deadline.
 * Revision: 11-15-2026.
 */
#include "rtlnet_sensor.h"
#include "rtlnet_platform.h"
#include "rtlnet_camera.h"
#include "rtlnet_rx.h"
#include "ov5640/rtlnet_ov5640_tables.h"
#include "xiicps.h"
#include "xgpiops.h"
#include "xparameters.h"
static XIicPs iic;
static XGpioPs gpio;
static unsigned current_mode;
static int idle(void)
{
    uint32_t start = plat_ticks();
    while (XIicPs_BusIsBusy(&iic))
        if ((uint32_t)(plat_ticks() - start) >= 100000u) return -1;
    return 0;
}
static int write_reg(uint16_t addr, uint8_t value)
{
    uint8_t data[3] = {(uint8_t)(addr >> 8), (uint8_t)addr, value};
    if (idle() != 0) return -1;
    if (XIicPs_MasterSendPolled(&iic, data, 3, 0x3c) != XST_SUCCESS) return -1;
    return idle();
}
static int read_reg(uint16_t addr, uint8_t *value)
{
    uint8_t data[2] = {(uint8_t)(addr >> 8), (uint8_t)addr};
    if (idle() != 0) return -1;
    if (XIicPs_MasterSendPolled(&iic, data, 2, 0x3c) != XST_SUCCESS || idle() != 0) return -1;
    if (XIicPs_MasterRecvPolled(&iic, value, 1, 0x3c) != XST_SUCCESS) return -1;
    return idle();
}
static int table(const rtlnet_sensor_reg_t *p, unsigned count)
{
    for (unsigned n = 0; n < count; n++)
        if (write_reg(p[n].addr, p[n].data) != 0) return -1;
    return 0;
}
#define TABLE(t) table(t, sizeof(t)/sizeof((t)[0]))
/* Sensor rates: mode 0 uses the "720p 60 fps" table of the Pcam 5C software release, whose PCLK 56 MHz / (HTS 1896 x VTS 984) gives 30 fps (measured 30.0 on the board);
 * mode 1 uses the 1080p30 table (PCLK 84 MHz / (2500 x 1120) = 30 fps). The stream rate is set by frame admission in the PL: 720p all frames
 * (30 fps), 1080p every second frame (15 fps). */
int rtlnet_sensor_mode(unsigned mode)
{
    if (mode > 1u) return -1;
    rtlnet_camera_enable(RTLNET_PLAT_CSI2_BASE, 0);
    if (write_reg(0x3008, 0x42) != 0) return -1;
    if (rtlnet_rx_set_mode(mode) != 0) return -1;
    if ((mode == 0u ? TABLE(cfg_720p_60fps_) : TABLE(cfg_1080p_30fps_)) != 0) return -1;
    if (TABLE(cfg_advanced_awb_) != 0 || write_reg(0x3008, 0x02) != 0) return -1;
    plat_delay_ms(100u);
    if (rtlnet_camera_mode(RTLNET_PLAT_CSI2_BASE, mode)) return -1;
    rtlnet_camera_enable(RTLNET_PLAT_CSI2_BASE, 1);
    current_mode = mode;
    return 0;
}
unsigned rtlnet_sensor_get_mode(void) { return current_mode; }
int rtlnet_sensor_init(void)
{
    XIicPs_Config *ic = XIicPs_LookupConfig(0);
    XGpioPs_Config *gc = XGpioPs_LookupConfig(0);
    uint8_t hi = 0, lo = 0;
    if (rtlnet_camera_probe(RTLNET_PLAT_CSI2_BASE)) return -1;
    if (!ic || !gc) return -1;
    if (XIicPs_CfgInitialize(&iic, ic, ic->BaseAddress) != XST_SUCCESS ||
        XIicPs_SetSClk(&iic, 100000u) != XST_SUCCESS ||
        XGpioPs_CfgInitialize(&gpio, gc, gc->BaseAddr) != XST_SUCCESS) return -1;
    XGpioPs_SetDirectionPin(&gpio, 54u, 1u);
    XGpioPs_SetOutputEnablePin(&gpio, 54u, 1u);
    XGpioPs_WritePin(&gpio, 54u, 0u); plat_delay_ms(1000u);
    XGpioPs_WritePin(&gpio, 54u, 1u); plat_delay_ms(1000u);
    if (read_reg(0x300a, &hi) || read_reg(0x300b, &lo) || hi != 0x56 || lo != 0x40) return -1;
    if (write_reg(0x3103, 0x11) || write_reg(0x3008, 0x82)) return -1;
    plat_delay_ms(1000u);
    if (TABLE(cfg_init_)) return -1;
    if (rtlnet_rx_init() != 0) return -1;
    return rtlnet_sensor_mode(0u);
}
