# RTLNet bare-metal Zynq-7000 camera firmware

Revision: 11-14-2026.

The application runs on Cortex-A9 core 0 with the standalone BSP and raw lwIP
from the board XSA. It owns PS UART1, I2C0, camera GPIO EMIO0, fabric GIC
handlers and GEM0. The vendor emacps adapter owns Ethernet DMA. No RTLNet
network core is instantiated. All network and CLI work runs in the foreground;
the encoder ISR services register events, slot ownership and picture queueing.

Build from the repository root with `firmware/build.ps1 -Xsa <board XSA>`
using PowerShell `-NoProfile -ExecutionPolicy Bypass -File`. Every tool resolves
through the central resolver. The fresh tag creates a local Vitis workspace,
builds standalone/lwIP with DHCP, then compiles and links `rtlnet_zybo.elf`.
`-ReuseBsp` requires a prior successful BSP marker with the same XSA SHA256.
A failed Vitis Python
script cannot pass merely because the Vitis launcher returns zero.

The program uses physical DDR addresses directly. The linker permits only
0x00100000..0x0fffffff; capture, reconstructed pictures, compressed and index
rings occupy fixed addresses above 0x10000000. Cache operations widen to
32-byte lines and issue barriers. PL-written ring/index data is invalidated
before CPU reads; CPU-written padding is flushed before encoder access.

The OV5640 owner checks ID 0x5640, uses the retained Digilent register tables
and drives EMIO GPIO pin 54 for reset. Tables and notices are under
`firmware/src/ov5640`. Software standby surrounds mode changes. I2C bus waits
are bounded; driver errors stop startup with the failed API named. The D-PHY,
CSI and gamma register addresses match the board Tcl. Mode changes require
the stream stopped and configure admission as well as the sensor.

GEM MDIO identifies RTL8211E (001cc915) or RTL8211F (001cc916); unknown IDs
stop startup. A CPU-local BSD-licensed emacps PHY adaptation uses the proper
status layout and bounds PHY reset waits. The SDK installation remains
unchanged. The temporary library copy and corrected metadata live under the
ignored `firmware/build/sdk`; only the reviewed PHY adaptation is maintained
as application source. DHCP has no static fallback. The default MAC (`rtlnet_network.c`) is locally
administered and needs a different value on additional boards sharing a LAN.

MenuBuilder has exec/priv modes and these commands:

```
show version
show ip
show camera
show encoder
show stream
enable
encoder bitrate 4000
encoder qp 28
encoder gop 30
stream start 192.0.2.10 5000
stream stop
camera mode 720p30
camera mode 1080p15
```

Zero bitrate selects constant QP. Commands validate ranges before changing
owners. A stream requires a DHCP lease and the expected capture/encoder IDs.
`show camera` also reads D-PHY control (+0) and version (+12). The retained
receiver has no AXI aligned/lock/tap readback; the command explicitly prints
those capabilities as unavailable. Configured taps 12/12 are labeled not
measured, and tap training is disabled: the leaf's LD/CE/INC controls are tied
low. Per-burst byte alignment is not data-tap training. Hardware review of
`DPHY_HS_INPUT` requires separately instrumented PPI/IDELAY-ready observations,
not an invented software lock result.
The 1080 geometry constant retains the shared driver's name `1080P30`, but
this port writes a 15 fps SPS VUI and 6000-tick PTS step. Capture and CPU ticks
are microseconds with independent epochs; lag is relative to the minimum
observed lag. Reconstructed pictures ping-pong; dropped frames force an IDR.

Run `firmware/test/rtlnet_host_tests.ps1`, `tsmux_host_test.ps1`, `picq_host_test.ps1`,
`rtlnet_encoder_host_tests.ps1` and `venc_irq_host_test.ps1` with PowerShell (the repository regression lists them
in `firmware/test/regression.txt`). The CLI harness links the real copied video/session/control code against
absent-device mocks; it does not emulate GIC, caches, camera or networking. The MicroBlaze UART TX-ring and INTC
test has no counterpart for the polled PS UART. The encoder-session IRQ test uses extracted DDR/framebuf/UDP
models, one engine, microsecond timestamps, the ZCAM PTS/mode map and Cortex-A9 logical mask semantics. Its
229 checks compare streams between interrupt and polled modes, including errors, profile changes, mode changes,
queueing, dropped frames and deblocking. It does not test the physical PS GIC. The board PL bench
(`boards/zybo_z7_20`) separately checks GP control, capture ownership, HP transactions and a decoded picture.
No hardware operation or runtime streaming result is claimed.

The ELF is built against the XSA of the Baseline stage (the video path runs on a 90 MHz clock; the capture
timestamp counts microseconds from it):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/zynq7_h264/firmware/build.ps1 -Xsa boards/zybo_z7_20/build/enc12/rtlnet_zybo_z7_20.xsa -Tag enc12
```
