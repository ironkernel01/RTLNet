/* Purpose: own camera receiver (rtlnet_csi2_rx) bring-up and diagnostics for the Zybo Z7-20 own-receiver image.
 * Overview: the image variant is read from the camera-wrapper CAPS register (bit 4 set: own receiver; clear: the vendored Digilent chain,
 *   whose D-PHY, CSI-2 and gamma registers are at 0x43C0_0000..). Every access to the receiver window is guarded by that bit, because the
 *   window does not exist in the reference image (a read there is a bus error). Defaults below are the values the sensor and this camera
 *   need; the CLI (rx ...) changes them at run time for measurements.
 * Revision: 11-15-2026. Initial own-receiver module.
 */
#ifndef RTLNET_RX_H
#define RTLNET_RX_H
#include <stdint.h>

/* Defaults (board measurements, see documentation/rtlnet_zynq7_h264.md). Gains are unsigned 4.8 fixed point, 0x100 = 1.0. */
#define RTLNET_RX_DEFAULT_TAP0    11u   /* centre of the measured error-free window of lane 0 at 1080p (taps 0..22) */
#define RTLNET_RX_DEFAULT_TAP1    10u   /* lane 1 (taps 0..21, centre 10.5) */
#define RTLNET_RX_DEFAULT_SETTLE  28u
#define RTLNET_RX_DEFAULT_BLACK   0u
/* White balance gains per sensor mode (the raw output of the Pcam 5C has no white balance; the two sensor tables differ in colour response):
 * measured on a neutral wall, ceiling lamp and monitor bezel so that R:G:B is within 3 to 5 percent. A mode change loads the pair of the new mode. */
#define RTLNET_RX_GAIN_R_720      0x163u   /* 1.387 */
#define RTLNET_RX_GAIN_G_720      0x100u
#define RTLNET_RX_GAIN_B_720      0x163u   /* 1.387 */
#define RTLNET_RX_GAIN_R_1080     0x195u   /* 1.582 */
#define RTLNET_RX_GAIN_G_1080     0x100u
#define RTLNET_RX_GAIN_B_1080     0x17Cu   /* 1.484 */
#define RTLNET_RX_DEFAULT_PHASE   3u       /* BGGR: the OV5640 tables with flip/mirror and the window offset deliver blue first (phase 0 swaps red and blue) */
#define RTLNET_RX_DEFAULT_GAMMA   1
#define RTLNET_RX_DEFAULT_GEQ     1        /* green equalisation: the sensor's two greens differ by about 8 percent in the binned modes */
#define RTLNET_RX_DEFAULT_BITREV  0

/* 1 when the image has the own receiver (CAPS bit 4 of the camera wrapper), decided once at start-up. */
int rtlnet_rx_detect(void);
int rtlnet_rx_present(void);
/* Receiver set-up before the sensor streams: enable, lanes, data type, settle, taps, Bayer processing, camera-only source. */
int rtlnet_rx_init(void);
/* Core video mode (0 = 720p30 geometry, 1 = 1080p) and the white balance gains of that mode, while the sensor is stopped. */
int rtlnet_rx_set_mode(unsigned mode);
/* Run-time setters (0 on success, negative on a bad value or an absent receiver). */
int rtlnet_rx_set_taps(uint32_t tap0, uint32_t tap1);
int rtlnet_rx_set_wb(uint32_t r, uint32_t g, uint32_t b);
int rtlnet_rx_set_black(uint32_t black);
int rtlnet_rx_set_phase(uint32_t phase);
int rtlnet_rx_set_gamma(int on);
int rtlnet_rx_set_geq(int on);
int rtlnet_rx_set_bitrev(int on);
int rtlnet_rx_set_settle(uint32_t clocks);
int rtlnet_rx_clear(void);
/* Print state and all counters (machine readable "key=value" lines); returns 0, or -1 when absent. */
int rtlnet_rx_show(void);
#endif
