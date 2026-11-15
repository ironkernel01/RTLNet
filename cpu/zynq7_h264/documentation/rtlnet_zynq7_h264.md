# RTLNet bare-metal Zynq-7000 camera firmware

Revision: 11-15-2026.

The application runs on Cortex-A9 core 0 only, with the standalone BSP and raw lwIP
from the board XSA. Core 1 is not used: the BSP domain targets `ps7_cortexa9_0`, no source writes the core 1 start
address or contains SMP/AMP code, and `boards/zybo_z7_20/scripts/program.ps1` downloads and runs core 0 by name; core 1
stays in the boot loop (the debugger reports it Running) and is free for a later application. It owns PS UART1, I2C0, camera GPIO EMIO0, fabric GIC
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

The OV5640 owner checks ID 0x5640, uses the register tables of the Pcam 5C software release
and drives EMIO GPIO pin 54 for reset. Tables and notices are under
`firmware/src/ov5640`. Software standby surrounds mode changes. I2C bus waits
are bounded; driver errors stop startup with the failed API named. Mode changes require
the stream stopped and configure admission as well as the sensor.

The camera receiver `rtlnet_csi2_rx` sits at 0x44A0_9000. `rtlnet_rx_probe` (`src/rtlnet_rx.c`) reads its ID and VERSION first (0x43534932 and 0x11152026, the core with the camera front end); any other value
stops startup with a message that names what was read. `rtlnet_rx_init` (through the core driver `cores/rtlnet_csi2_rx/driver`) brings the receiver up after the sensor init table and before the sensor streams: soft
reset held while the configuration is written, two lanes, bit order 0, settle 28 clocks, virtual channel 0 and data type RAW10, delay taps, black level, white balance gains, Bayer phase, gamma, green equalisation,
highlight clamp and camera-only source, then the soft reset is released. A mode change sets the core `VIDEO_MODE`, the gains and the highlight level of the mode while the sensor is in standby. The defaults are the macros
`RTLNET_RX_DEFAULT_*`, `RTLNET_RX_GAIN_*` and `RTLNET_RX_HL_*` in `src/rtlnet_rx.h` (values and their measurement below).

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
show rx
rx clear
rx taps 12 12
rx wb 355 256 355
rx black 0
rx phase 3
rx gamma 1
rx geq 1
rx bitrev 0
rx settle 28
```

`show rx` (an error line when the receiver does not answer) prints four lines of `key=value` for a host script: `RX ctrl status taps settle
filter lines pixels`, `RX counters ECC_CORR ECC_UNC CRC SOT FRAMES DT TRUNC OVF SIZE ORPHAN LEN CLKLOSS` (all twelve counters of the core) and
`RX proc black wb phase gamma geq bitrev clkrun dlyrdy lp frames_out` and `RX highlight level rawmax r g b` (the raw maxima of the last frame, black level subtracted, before the gain). `rx clear` clears the counters. `rx taps <lane 0> <lane 1>`
takes 0 to 31 (78 ps each), `rx wb <R> <G> <B>` 4.8 fixed point (256 = 1.0), `rx black` 0 to 1023 raw units, `rx phase` 0 to 3,
`rx gamma`, `rx geq` and `rx bitrev` 0 or 1, `rx highlight <0|1> <level 0..1023>` (the highlight clamp of the core), `rx settle` 0 to 255 clocks of 200 MHz. The rx commands change the receiver at once (the Bayer
processing registers take effect at the next frame); `boards/zybo_z7_20/scripts/rx_test.ps1` drives them for the counter and tap sweep measurements.

Zero bitrate selects constant QP. Commands validate ranges before changing
owners. A stream requires a DHCP lease and the expected capture/encoder IDs.
`show camera` prints the sensor mode, the frame counters of the admission block and a pointer to `show rx`.
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

## Hardware bring-up (11-15-2026)

Measured on a Zybo Z7-20 with a Pcam 5C (JTAG load with `boards/zybo_z7_20/scripts/program.ps1`):

- The console (115200 baud) reaches the prompt about 40 s after the load; `show version`, `show ip` (RTL8211F, PHY ID
  001cc916, DHCP lease), `show camera`, `show encoder`, `show stream` work. `show stream` also prints the frame buffer
  recovery counters and the drain time of the last stream stop.
- The firmware started the Cortex-A9 global timer nowhere: `plat_delay_*` and `plat_ticks` waited forever in the first
  sensor delay. `plat_init` now clears and enables the SCU global timer (0xF8F00200).
- The BSP macro `COUNTS_PER_SECOND` is `XPAR_CPU_CORE_CLOCK_FREQ_HZ/2` without parentheses, so `plat_ticks` and
  `plat_uptime_ms` divided by the CPU clock and then by 2 (the seconds part ran four times slow, the fraction part was wrong
  and the time stepped backwards every two seconds; start-up took 40 s instead of about 5 s). The 500 ms encoder time-out then
  fired by chance, abandoned a picture in flight, and the next start rewrote the core configuration (PIC_CFG) under the
  running picture; the core deadlocked in its end-of-picture wait (debug read-out: state E_FLUSH, motion search still active)
  and stayed BUSY for good: after 30 to 750 pictures at 30 fps. `rtlnet_platform.c` now uses a parenthesised
  `RTLNET_GTIMER_HZ`; 1,822 pictures in 60 s and 9,006 pictures in 292 s ran without an error.
- A stream stop with a picture in flight is drained (`venc_stop` waits at most 400 ms for the core to finish before it
  gives the input slot back); before the clock fix such a stop left the core BUSY in 3 of 6 stop and start cycles, 6 of 6 cycles
  were clean with the drain alone; `show stream` prints the wait of the last stop.
- OV5640 tables: mode 0 (720p, PCLK 56 MHz, HTS 1896, VTS 984) runs 30.0 fps at the sensor (measured), the
  1080p30 table (PCLK 84 MHz, HTS 2500, VTS 1120) is mode 1 and runs 30.0 fps (measured). The PL admits every frame in
  mode 0 (PTS step 3000) and every second frame in mode 1 (PTS step 6000, 15 fps).

### Receiver bring-up measurements (11-15-2026, image `own7`, firmware `fw18`)

The receiver measurements themselves are in `cores/rtlnet_csi2_rx/documentation/rtlnet_csi2_rx.md` section 12.

- Start-up: `rtlnet_rx_probe` finds the core (ID, VERSION 0x11152026); `rtlnet_rx_init` brings the receiver up after the sensor init table; the receiver locks on the first burst (`show rx`: clock running, both lanes locked, IDELAYCTRL ready,
  all error counters 0).
- Defaults in `src/rtlnet_rx.h`: taps 11 (lane 0) and 10 (lane 1), the centres of the measured 1080p windows of the lanes; settle 28 clocks; black level 0; Bayer phase 3 (BGGR; phase 0 swaps red and blue with the OV5640 tables of this firmware);
  gamma on; green equalisation on; bit order 0; white balance gains loaded with each mode (720p R 0x163, G 0x100, B 0x163; 1080p R 0x195, G 0x100, B 0x17C), measured on a neutral wall, a ceiling lamp and a monitor bezel so that R:G:B is
  within about 5 percent in the decoded picture; highlight clamp on with level 760 at 1080p and 960 at 720p (see "Highlights" in `boards/zybo_z7_20/documentation/rtlnet_zybo_z7_20.md`). An `rx wb` or `rx highlight` command stays in force until the next
  `camera mode`.
- The sensor tables are unchanged: the sensor flip, mirror and the window offset stay; the Bayer phase register only names the arrangement that results.
- `ZYBO_RX_COUNTERS: PASS 22/22` (60 s per mode), `ZYBO_STREAM_TEST: PASS 16/16` in three consecutive `-Mode both` runs and `PASS 8/8` for the 120 s soak at 720p, all with `-Port COM6`.
- The host suites of `firmware/test` run with the commands (the receiver is absent on the host: `show rx` and `rx ...` return an error line and touch no register).


The ELF is built against the XSA of the design (the video path runs on a 90 MHz clock; the capture
timestamp counts microseconds from it):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/zynq7_h264/firmware/build.ps1 -Xsa boards/zybo_z7_20/build/own7/rtlnet_zybo_z7_20.xsa -Tag fw17
```

The build includes the receiver core driver (`cores/rtlnet_csi2_rx/driver`).
