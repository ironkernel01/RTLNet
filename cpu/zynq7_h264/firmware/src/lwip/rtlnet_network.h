/* Purpose: raw lwIP PS GEM0 owner and video datagram contract.
 * Overview: main-loop-only network service; DHCP has no static fallback.
 * Revision: 11-14-2026. Initial Zynq network interface.
 */
#ifndef RTLNET_NETWORK_H
#define RTLNET_NETWORK_H
int rtlnet_network_init(void);
void rtlnet_network_poll(void);
void rtlnet_network_show(void);
#endif
