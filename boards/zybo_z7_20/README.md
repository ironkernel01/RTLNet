# RTLNet on Digilent Zybo Z7-20

Revision: 11-15-2026.

This is the real-camera H.264 design for the Digilent Zybo Z7-20 (XC7Z020-1CLG400): a Digilent Pcam 5C (OV5640,
MIPI CSI-2) is encoded by one RTLNet Baseline H.264 engine and streamed as MPEG-TS over UDP by a bare-metal ARM
application (`cpu/zynq7_h264`) through the PS Gigabit Ethernet and lwIP. The PHY sits on PS MIO pins, so the RTLNet
RTL network stack is not used on this board. HDMI is absent.

Clock plan: the whole video path (CSI-2 receiver video side, Bayer, gamma, adapter, capture DMA, frame buffer,
encoder and both HP ports) runs on one 90 MHz clock; 50 MHz serves GP0 and AXI-Lite and 200 MHz the D-PHY delay
reference. Sensor modes: 720p and 1080p, both at 30 fps at the sensor; the stream is 720p30 (all frames) and 1080p15 (every second frame).

## Status

Revision 11-15-2026: the design runs on a Zybo Z7-20 with a Pcam 5C. Build `enc14` (gates PASS with the named deviation
`DPHY_HS_INPUT`; qualified WNS +0.287 ns and WHS +0.050 ns excluding its two endpoints; 33,427 LUT, 26,371 registers, 28
block RAM tiles, 48 DSP) with firmware `fw10`. Measured on the board:

- Console, PS Ethernet (RTL8211F, PHY ID 001cc916, DHCP), OV5640 (ID 0x5640 over I2C) and the Digilent CSI-2 chain run.
  The sensor delivers 30 fps in both modes (frame counter: 29.9 to 30.1 fps over runs of 17 s to 292 s).
- 720p: every frame is admitted, the stream is 1280x720 at 30 fps; 1080p: every second frame is admitted, the stream is
  1920x1080 at 15 fps. ffprobe reads h264 Constrained Baseline, ffmpeg decodes with no error message: 720p for 292 s (9,006
  pictures, no continuity error, no dropped picture, adapter error counter 0) and 1080p for 142 s (2,251 pictures).
- `DPHY_HS_INPUT` stays open as a margin question: the AXI registers expose no D-PHY lane status or error counter. In
  the runs above no corrupted frame, no adapter error and no decode error was seen; that does not measure the sampling margin.
- The first picture decoded from the board (720p, a lit desk with two monitors) is a real camera picture with plausible
  colours and no tearing. The sensor flip and mirror (OV5640 0x3820 = 0x40, 0x3821 bit 1, window offset 0x3811 plus one column) put the
  picture upright in both modes with the Bayer phase kept. With the scene dark (later runs) the picture is nearly black and the host test reports it as a FAIL of
  its "picture" check.
- Faults found: the firmware never started the Cortex-A9 global timer; the BSP macro behind `plat_ticks` is not parenthesised, which
  made the time wrong and let the 500 ms picture time-out fire by chance and corrupt the encoder configuration (the
  encoder core then stopped with BUSY set after some seconds at 30 fps); a stream stop with a picture in flight is now
  drained. Details are in `documentation/rtlnet_zybo_z7_20.md` and `cpu/zynq7_h264/documentation/rtlnet_zynq7_h264.md`.
- Power: through a weak USB port the board lost power as soon as the PL was configured and the ARM ran (REBOOT_STATUS
  power-on reset, PL configuration wiped). A direct PC USB port fixed it; use a good port or a 5 V supply.

Details, the clock tree, the throughput arithmetic and the gate descriptions are in
`documentation/rtlnet_zybo_z7_20.md`.

## Load and run

`scripts/program.ps1` loads the design over JTAG (volatile, never QSPI or SD): board lock, xsdb, refusal unless an xc7z020
is on the chain, `ps7_init` from the XSA, `fpga`, `ps7_post_config`, download of the ARM ELF to Cortex-A9 core 0 and run.
Core 1 is not touched: the firmware runs on core 0 only and core 1 stays in the boot loop (reported Running by the debugger
after the load) and is free for a later application.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/program.ps1 -Tag <bitstream tag> -FwTag <firmware tag>
```

The console is the board USB-UART at 115200 baud (the one serial port of the FTDI device). About 40 s after the load the
prompt appears (sensor start-up and DHCP). `scripts/stream_test.ps1` is the host test (stream receive, decode, frame
rates, one PASS/FAIL line; the first GOP of a new UDP flow is reported but not judged, because the network can reorder the first burst of a new flow): `powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/stream_test.ps1 -Mode both`.

## Third-party IP

The design uses Digilent's MIT-licensed D-PHY receiver, CSI-2 receiver, Bayer-to-RGB and gamma IP and the
Digilent Zybo Z7-20 board files. They are kept unchanged under `boards/zybo_z7_20/ip/digilent` and
`boards/zybo_z7_20/board_files` (each with a `NOTICE.txt` that lists the origin and the SHA-256 of every file)
and may be absent from a checkout. `scripts/build.ps1` stops before Vivado with the command to populate them when
they are missing. To populate them, take two inputs:

- the Digilent Pcam 5C demo hardware archive `Zybo-Z7-20-Pcam-5C-hw.xpr.zip` (Zybo-Z7 release 20, Pcam-5C,
  2025.1-1) from the Digilent Zybo-Z7 demo releases;
- the Digilent board files (`vivado-boards`, folder `new/board_files`, containing `zybo-z7-20/A.0/board.xml`).

```powershell
python boards/zybo_z7_20/scripts/rtlnet_import_camera.py `
    --hw-archive <path>/Zybo-Z7-20-Pcam-5C-hw.xpr.zip --board-files <path>/board_files
```

The archive path and the board-file folder can also be given by `RTLNET_ZYBO_HW_ARCHIVE` and
`RTLNET_ZYBO_BOARD_FILES`. The import refuses an archive whose SHA-256 differs from the expected value
(`ae235e42e1956dff5269a4a1e1d78bfb3624bc2c6ec0bbc119bdb852da50ac13`), copies the IP and board files, and regenerates
`bd/rtlnet_camera.tcl` and `constraints/rtlnet_camera_pins.xdc` from the archive's block design and constraints
(the committed files are the output of this script, byte for byte). The build then checks every IP file against the
hashes in `ip/digilent/NOTICE.txt`, stages the IP in the build folder with four debug-analyzer constraint files
omitted and one merged debug-library source, and never edits the originals.

## Build

From the repository root, stage 0 first and then the Baseline stage (the tags are free names; the Baseline
stage names its camera tag):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/build.ps1 -Tag camera11
powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/build.ps1 -Stage baseline -CameraTag camera11 -Tag enc14 -HighProfile none
```

Each tag owns `boards/zybo_z7_20/build/<tag>`: project, reports, `rtlnet_zybo_z7_20.bit`,
`rtlnet_zybo_z7_20.xsa`, `export_manifest.txt` and `build_info.txt`. `-StopAfter bd` stops after block design
creation and validation (debug only, no verdict). `-HighProfile full|demo -HpNetlist <folder>` is the seam for the
High profile netlist; with `none` the Baseline encoder is built. Vivado runs only through `scripts/rtlnet_vivado.ps1`.
The ARM application builds from the exported XSA:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/zynq7_h264/firmware/build.ps1 -Xsa boards/zybo_z7_20/build/enc14/rtlnet_zybo_z7_20.xsa -Tag fw10
```

## Tests

Run the board's regression entries (Active-HDL, no Vivado, no board) from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1 -Match 'zybo|zynq7'
```

The entries are: the RGB-to-YUYV adapter against a reference model (and a negative control), the HP bridge against
a byte-level oracle, the integrated camera-to-encoder board bench, the decoder check
(`scripts/check_board_encode.ps1` runs the bench itself and decodes its H.264 stream with three reference
decoders), the build-gate policy checks (`scripts/check_gates.ps1`) and the ARM host suites. The board bench runs
on one 90 MHz clock with a camera model at the sensor link rates; it does not contain the vendor CSI-2 receiver or the
D-PHY. The gate checks that need the third-party IP report SKIPPED when it is absent.

## Layout

| Folder | Content |
|---|---|
| `hdl/` | `rtlnet_zybo_video` (adapter, capture, frame buffer, encoder, arbiter, bridges), `rtlnet_rgb_to_yuyv`, `rtlnet_axi_hp_bridge`, module-reference wrapper |
| `bd/` | block design Tcl of the camera stage and the Baseline replacement |
| `constraints/` | camera pins, forwarded-clock model, D-PHY input timing |
| `scripts/` | build flow, gates, import script, checks |
| `testbench/` | benches, fixtures and `regression.txt` |
| `ip/`, `board_files/` | third-party Digilent material (see above) |
| `documentation/` | architecture, clock tree, gates, results |
