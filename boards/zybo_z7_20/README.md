# RTLNet on Digilent Zybo Z7-20

Revision: 11-14-2026.

This is the real-camera H.264 design for the Digilent Zybo Z7-20 (XC7Z020-1CLG400): a Digilent Pcam 5C (OV5640,
MIPI CSI-2) is encoded by one RTLNet Baseline H.264 engine and streamed as MPEG-TS over UDP by a bare-metal ARM
application (`cpu/zynq7_h264`) through the PS Gigabit Ethernet and lwIP. The PHY sits on PS MIO pins, so the RTLNet
RTL network stack is not used on this board. HDMI is absent.

Clock plan: the whole video path (CSI-2 receiver video side, Bayer, gamma, adapter, capture DMA, frame buffer,
encoder and both HP ports) runs on one 90 MHz clock; 50 MHz serves GP0 and AXI-Lite and 200 MHz the D-PHY delay
reference. Supported sensor modes: 720p (720p30 by frame admission) and 1080p15; 1080p30 is not offered.

## Status

Stage 0 (the Digilent camera chain) and the Baseline stage (camera chain, adapter, capture, one encoder) build and
print `PASS with deviation DPHY_HS_INPUT`: the two high-speed D-PHY sampler endpoints of the Digilent receiver
fail static timing (setup -0.223 ns, hold -1.431 ns, the same as the published reference design); everything
else closes (Baseline qualified WNS +0.287 ns, WHS +0.050 ns). The Baseline stage uses 33,427 LUT (62.83 %),
26,371 registers, 28 block RAM tiles and 48 DSP. The ARM application builds against its XSA. Nothing has run on a
board: the D-PHY deviation, the vendor receiver at a 90 MHz video clock and the streaming application are not
verified on hardware. Details, the clock tree, the throughput arithmetic and the gate descriptions are in
`documentation/rtlnet_zybo_z7_20.md`.

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
powershell -NoProfile -ExecutionPolicy Bypass -File boards/zybo_z7_20/scripts/build.ps1 -Stage baseline -CameraTag camera11 -Tag enc12 -HighProfile none
```

Each tag owns `boards/zybo_z7_20/build/<tag>`: project, reports, `rtlnet_zybo_z7_20.bit`,
`rtlnet_zybo_z7_20.xsa`, `export_manifest.txt` and `build_info.txt`. `-StopAfter bd` stops after block design
creation and validation (debug only, no verdict). `-HighProfile full|demo -HpNetlist <folder>` is the seam for the
High profile netlist; with `none` the Baseline encoder is built. Vivado runs only through `scripts/rtlnet_vivado.ps1`.
The ARM application builds from the exported XSA:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File cpu/zynq7_h264/firmware/build.ps1 -Xsa boards/zybo_z7_20/build/enc12/rtlnet_zybo_z7_20.xsa -Tag enc12
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
