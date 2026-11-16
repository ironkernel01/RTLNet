# RTLNet on Digilent Zybo Z7-20

Revision: 11-15-2026.

This is the real-camera H.264 design for the Digilent Zybo Z7-20 (XC7Z020-1CLG400): a Digilent Pcam 5C (OV5640,
MIPI CSI-2) is received by the IronKernel receiver `rtlnet_csi2_rx` (`cores/rtlnet_csi2_rx`), encoded by one RTLNet
Baseline H.264 engine and streamed as MPEG-TS over UDP by a bare-metal ARM application (`cpu/zynq7_h264`) through the PS
Gigabit Ethernet and lwIP. The PHY sits on PS MIO pins, so the RTLNet RTL network stack is not used on this board. HDMI is absent.

Clock plan: the whole video path (receiver video side, capture DMA, frame buffer, encoder and both HP ports) runs on one
90 MHz clock; 50 MHz serves GP0 and AXI-Lite and 200 MHz the D-PHY delay reference. Sensor modes: 720p and 1080p, both at
30 fps at the sensor; the stream is 720p30 (all frames) and 1080p15 (every second frame).

## Status

The design runs on a Zybo Z7-20 with a Pcam 5C: image `own9` with firmware `fw19` (gates PASS with the named deviation `DPHY_HS_INPUT` on the two `ISERDESE2` `DDLY` pins of the receiver; qualified
WNS +0.222 ns and WHS +0.051 ns excluding them; 33,151 LUT, 26,393 registers, 26 block RAM tiles, 50 DSP). The capture DMA and the encoder are 64-bit masters on the HP ports: no width bridge, no arbiter. Measured on the board with this image:

- Receiver counters over 60 s: 720p 30.00 fps, 1080p 30.01 fps, `ECC_UNC`, `CRC`, `SOT`, `SIZE` and every other error counter 0 (`ECC_CORR` 0).
- `stream_test.ps1 -Mode both -Port COM6` PASS 16/16 in three consecutive runs; 120 s soak at 720p PASS 8/8 (3,573 pictures, no continuity or decode error); 120 s soak at 1080p PASS 8/8 (1,771 pictures, no continuity, PTS or decode error, no dropped picture).
- Pictures upright in both modes (checked again on `own9` in a dark room; the white balance, green and highlight measurements below are those of `own7`); white balance gains per mode make a neutral wall R:G:B within about 5 percent; the two greens of the sensor are equalised by the receiver (`PROC` bit 1); the highlight clamp (`PROC` bit 2)
  keeps clipped bright areas neutral where the white balance gains had made them pink at 1080p (bright pixels 251 : 222 : 235 without, 253 : 251 : 239 with the clamp).
- IDELAY sweep (both lanes, 3 s per tap, 78 ps per tap, measured on the previous image with the same receiver): error-free taps 0 to 29 at 720p (280 Mb/s) and 0 to 21 at 1080p (420 Mb/s); the default taps are 11 and 10.
  One unit, room temperature; the static timing of the two HS samplers fails hold (the named deviation).
- Not measured: temperature, supply, other cables, boards and sensors, the non-continuous clock mode, a stopped HS clock on a real sensor, a sunlit clipped window with the final image (the room was dark).
- Power: through a weak USB port the board lost power as soon as the PL was configured and the ARM ran; use a direct PC USB port or a 5 V supply.

Details, the clock tree, the throughput arithmetic and the gate descriptions are in `documentation/rtlnet_zybo_z7_20.md`.

## Load and run

`scripts/program.ps1` loads the design over JTAG (volatile, never QSPI or SD): board lock, xsdb, refusal unless an xc7z020
is on the chain, `ps7_init` from the XSA, `fpga`, `ps7_post_config`, download of the ARM ELF to Cortex-A9 core 0 and run.
Core 1 is not touched: the firmware runs on core 0 only and core 1 stays in the boot loop and is free for a later application.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/program.ps1 -Tag <bitstream tag> -FwTag <firmware tag>
```

On a PC with more than one serial device `stream_test.ps1` and `rx_test.ps1` take the console port explicitly (`-Port COM6`; `rx_test.ps1` refuses `COM5` and requires the argument).
`rx_test.ps1 -Action counters` reads the receiver counters over a streaming interval, `-Action sweep` sweeps the IDELAY taps and prints the error-free window.

The console is the board USB-UART at 115200 baud. About 40 s after the load the prompt appears (sensor start-up and DHCP). `scripts/stream_test.ps1` is the host test (stream receive, decode, frame
rates, one PASS/FAIL line; the first GOP of a new UDP flow is reported but not judged, because the network can reorder the first burst of a new flow):
`powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/stream_test.ps1 -Mode both -Port COM6`.

## Demo

The released image is a demo entry: `demos/h264_baseline/zybo_z7_20/` holds `rtlnet_zybo_z7_20.bit`, the firmware `rtlnet_zybo.elf` and `ps7_init.tcl` of image `own9` and firmware `fw19`, with its README (what to connect, how to load and view the stream), build info and a brief with the measured results (`h264_baseline_zybo_z7_20_brief.pdf`). `scripts/program_demo.ps1` loads those three files over JTAG (volatile) without a build folder; `demos/demorelease.bat h264_baseline zybo_z7_20` copies a new build into the demo folder and `scripts/demo_captures.ps1 -Port COM6` takes the pictures of the brief again from the running board (`demos/h264_baseline/images/README.md`).

## Build

From the repository root (the tag is a free name):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/build.ps1 -Tag own9
```

The tag owns `boards/zybo_z7_20/build/<tag>`: project, reports, `rtlnet_zybo_z7_20.bit`, `rtlnet_zybo_z7_20.xsa`, `export_manifest.txt` and `build_info.txt`. `-StopAfter bd` stops after block design creation and
validation (debug only, no verdict). `-HighProfile full|demo -HpNetlist <folder>` is the seam for the High profile netlist; with `none` the Baseline encoder is built. Vivado runs only through
`scripts/rtlnet_vivado.ps1`. The ARM application builds from the exported XSA:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/zynq7_h264/firmware/build.ps1 -Xsa boards/zybo_z7_20/build/own9/rtlnet_zybo_z7_20.xsa -Tag fw19
```

## Third-party material

The Digilent Zybo Z7-20 board files (MIT licensed) are kept unchanged under `boards/zybo_z7_20/board_files` with a `NOTICE.txt` that lists the origin and the SHA-256 of every file. The OV5640 register tables
in `cpu/zynq7_h264/firmware/src/ov5640` come from the Digilent Pcam 5C software release (notice in that folder).

## Tests

Run the board's regression entries (Active-HDL, no Vivado, no board) from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1 -Match 'csi2|video_path|zybo|zynq7'
```

The entries are: the integrated camera-to-encoder board bench (the D-PHY transmitter model of the receiver benches drives the wrapper's camera pins; admission, geometry, capture and encoder, the capture DMA and the encoder connected directly to two AXI3 HP slave models that reject illegal bursts;
negative controls `INJECT_FAILURE` and `MUTATE`, mutation controls for WID, 4 KiB, burst length, single-beat bursts and beat size), the decoder check (`scripts/check_board_encode.ps1` runs the bench itself and decodes its H.264 stream with three reference decoders), the
build-gate policy checks (`scripts/check_gates.ps1`) and the ARM host suites. The receiver core has its own benches (`-Match csi2`). The AMD primitive branch of the receiver's D-PHY front end cannot be simulated;
the bench uses the behavioural front end, and the primitive branch is covered by synthesis, the gates and the board runs.

## Layout

| Folder | Content |
|---|---|
| `hdl/` | `rtlnet_zybo_video` (receiver, admission, capture, frame buffer, encoder; the capture DMA and the encoder are 64-bit masters on the HP ports, no bridge, no arbiter), its generated module-reference boundary and filelist |
| `bd/` | block design Tcl (`rtlnet_zybo.tcl`) |
| `constraints/` | camera pins; HS clock, HS input delays and LP false paths |
| `scripts/` | build flow and gates, CDC hook and reviewed waivers, `program.ps1`, `program_demo.ps1`, `stream_test.ps1`, `rx_test.ps1`, `demo_captures.ps1` |
| `testbench/` | benches and `regression.txt` |
| `board_files/` | Digilent board files (see above) |
| `documentation/` | architecture, clock tree, gates, results |
