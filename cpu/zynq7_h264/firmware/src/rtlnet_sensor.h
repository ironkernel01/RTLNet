/* Purpose: bounded OV5640 owner, independent of display software.
 * Overview: mode changes require the stream stopped; 0=720p60/alternate, 1=1080p15.
 * Revision: 11-14-2026. Initial sensor interface.
 */
#ifndef RTLNET_SENSOR_H
#define RTLNET_SENSOR_H
int rtlnet_sensor_init(void);
int rtlnet_sensor_mode(unsigned mode);
unsigned rtlnet_sensor_get_mode(void);
#endif
