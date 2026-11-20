# RTLNet demonstration images

The [RTLNet Specification](../documentation/rtnet_specification.md) describes the cores, board configurations, measurements and limits. Each release includes its bitstream, firmware, build record and board-specific operating instructions.

| Released image | Run guide | Data path |
|---|---|---|
| Nexys Video Ethernet | [Nexys Video](ethernet/nexys_video/README.md) | Gigabit RGMII, hardware IPv4 services and MicroBlaze V TCP |
| Arty A7-100T Ethernet | [Arty A7-100T](ethernet/arty_a7_100/README.md) | 10/100 MII with the shared Ethernet firmware in on-chip RAM |
| Nexys H.264 Baseline | [Baseline demo](h264_baseline/nexys_video/README.md) | Internal pattern, DDR, IronH264 and MPEG-TS over UDP |
| Nexys H.264 High Profile | [Timed evaluation](h264_high_profile_demo/nexys_video/README.md) | CABAC for 30 minutes, then continuous Baseline streaming |

See the [demo guide](demos.md) for equipment, JTAG loading and release packaging. The [RTLNet license](../LICENSE.md) and the [High Profile evaluation license](LICENSE_DEMO.md) cover their respective distributions.
