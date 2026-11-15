# Zybo Z7-20 camera integration

Revision: 11-15-2026.

The target is the Digilent Zybo Z7-20 (`xc7z020clg400-1`). The camera (Digilent Pcam 5C, OV5640, two MIPI lanes) is received by
one of two selectable receivers (build parameter `-Receiver reference|own`, default `reference`): the vendored Digilent chain
(D-PHY receiver, CSI-2 receiver, Bayer conversion and gamma IP, followed by the RTLNet RGB-to-YUYV adapter) or the IronKernel
receiver `rtlnet_csi2_rx` (`cores/rtlnet_csi2_rx`, section "Receiver variants"). The camera picture is encoded with one RTLNet H.264
Baseline engine (deblocking filter on). The ARM application streams the result over the PS Gigabit Ethernet.

There are two build stages. Stage 0 (the camera stage) rebuilds the Digilent capture chain to an AMD AXI VDMA
S2MM connected to PS HP2. The Baseline stage replaces that sink with the RTLNet RGB-to-YUYV adapter, the capture
DMA with its frame buffer, one deblocking encoder, the arbiter and two 128-to-64-bit AXI3 bridges for the HP
ports. The Baseline stage rebuilds the whole design and uses its camera stage only as an admission check
(`build_info.txt` of the camera tag: stage camera, part `xc7z020clg400-1`, `gate_pass 1`).

## Receiver variants

| | `reference` (default) | `own` |
|---|---|---|
| Receiver | vendored Digilent D-PHY, CSI-2, Bayer-to-RGB and gamma IP, `rtlnet_rgb_to_yuyv` | `rtlnet_csi2_rx` with `CAMERA_RX` = 1 (D-PHY front end, packet layer, Bayer, YUV422) |
| Video wrapper | `hdl/rtlnet_zybo_video.sv` (+ generated `rtlnet_zybo_video_bd.v`) | `hdl/rtlnet_zybo_video_own.sv` (+ `rtlnet_zybo_video_own_bd.v`), both generated |
| BD recipe | `bd/rtlnet_baseline.tcl` | `bd/rtlnet_baseline_own.tcl` |
| Camera pins, HS clock | the Digilent D-PHY block | the receiver core itself (`dphy_hs_clock_clk_p/n`, `dphy_data_hs_*`, `dphy_clk_lp_*`, `dphy_data_lp_*`) |
| 200 MHz reference | Digilent D-PHY `RefClk` | `ref_clk` of the receiver (its IDELAYCTRL, IODELAY group `rtlnet_csi2_dly`) |
| Register windows | 0x43C0_0000 D-PHY, 0x43C1_0000 CSI-2, 0x43C2_0000 gamma | 0x44A0_9000 receiver |
| Camera wrapper `VERSION` / `CAPS` | 0x11142026 / 0x00000002 | 0x11152026 / 0x00000012 (bit 4: own receiver; the firmware reads it) |
| Build command | `build.ps1 -Stage baseline -CameraTag <tag> -Tag <tag>` | the same with `-Receiver own` |

The own wrapper is derived from the reference wrapper by `scripts/rtlnet_generate_own_video.py` (exact text patches, every anchor must occur
once; `--check` is part of `scripts/check_gates.ps1`), so capture DMA, frame buffer, encoder, arbiter, HP bridges and the camera admission
registers are the same text in both variants; `rtlnet_zybo_video.sv` is not edited by the variant. Differences in the
wrapper: the D-PHY pins and `ref_clk` replace the RGB stream ports, `rtlnet_csi2_rx` (parameters `CAMERA_RX` 1, `DPHY_TARGET` "AMD", `NONCONT_CLOCK` 0,
`IDELAYCTRL_INST` 1, `HS_DIFF_TERM` 0, the frame geometry of the wrapper) replaces the RGB adapter, a sixth register window at 0x44A0_9000 (index 5 of the
GP0 decoder) carries the receiver, and the admission logic takes the YUV422 words of the receiver directly (`m_axis_tready` is high while a frame is not admitted, otherwise the capture slice
ready, so a skipped frame never stalls the receiver; the receiver cannot be stalled: its byte-clock FIFO counts dropped entries in `OVF`). The HS inputs run without the internal
100 ohm termination (`HS_DIFF_TERM` 0): bank 35 is at 3.3 V because of the camera GPIO and I2C pins, an LVDS_25 input with internal termination needs 2.5 V (DRC BIVC-1), and the Pcam adapter
terminates the lanes (the Digilent IP also sets `DIFF_TERM` false).

The reference variant is unchanged in result: the sources `rtlnet_zybo_video.sv`, `rtlnet_zybo_video_bd.v`, `bd/rtlnet_baseline.tcl`, `bd/rtlnet_camera.tcl` and the three existing constraint files are not edited, and the reference image rebuilt with the variant-aware scripts (tag `ref2`) gives the
gate result of `enc14`: WNS -0.223 ns, WHS -1.431 ns, qualified +0.287 ns and +0.050 ns, 33,427 LUT, 26,371 registers (the two bitstream files are not byte-identical and were not compared further).

`build_bitstream.tcl` (argument `receiver`) differs for `own` as follows. The camera Tcl of the reference stage is reused: a copy in the build folder
(`rtlnet_camera_own.tcl`) replaces its tail (the vendor address assignments) by `bd/rtlnet_baseline_own.tcl`, which deletes the vendor chain, the stage 0
VDMA and its interconnect, reduces the GP0 interconnect to one master and connects the pins and `clk_wiz_0/clk_out3` (200 MHz) to the wrapper; the vendor IP checks, the vendor
debug and gamma constraint handling and the vendor waivers are skipped; `constraints/rtlnet_own_rx.xdc` adds the false path of the LP inputs (Vivado derives the byte clock at the BUFR
output itself; an explicit generated clock is rejected as an override, Constraints 18-1056); the CDC hook `scripts/rtlnet_cdc_hook_own.tcl` requires and counts the classes `sync` 33, `reset` 3, `gray` 2, `axil_cdc` 6;
`scripts/rtlnet_own_waivers.tcl` waives exactly the reviewed findings that remain (CDC findings on the combination of `hs_go` and the clock-running level in front of two
synchronizers and on the two-source asynchronous clear of the byte-clock reset, with both registers that `report_cdc` may name as the source; and three methodology findings: the LUT in front of the
asynchronous clear, the TIMING-9 summary and the two hold findings of the deviation), each with its reason in `reports/own_receiver_waivers.rpt`; any other finding fails the build (code 27). The
asynchronous-reset inventory allows only the `pipe_reg` cells of the receiver's `rtlnet_reset_sync` (asynchronous assertion, synchronous release) inside `u_video`. The timing gate uses the two
`ISERDESE2` `DDLY` pins of the receiver as the reviewed endpoints of the deviation `DPHY_HS_INPUT` (below).

## Clock plan

| Clock | Source | Consumers |
|---|---|---|
| 100 MHz | PS FCLK0 | both clocking wizards |
| 50 MHz | clk_wiz_0, 600 MHz VCO / 12 | GP0, receiver and D-PHY AXI-Lite control, RTLNet register window |
| 90 MHz | rtlnet_video_clock | CSI-2 receiver video side, Bayer, gamma, adapter, capture DMA, frame buffer, encoder, HP0 and HP2, stage 0 VDMA |
| 200 MHz | clk_wiz_0, 600 MHz VCO / 3 | D-PHY delay reference (`own`: `ref_clk` of the receiver, also its LP trackers and clock detector) |
| 140 / 210 MHz | sensor forwarded clock, 720p / 1080p30 | DDR HS input sampling |
| 35 / 52.5 MHz | D-PHY HS clock / 4 | recovered byte stream (`own`: BUFR output, the clock Vivado names `g_cam.byte_clk`) |

The 150 MHz output of the Digilent reference clocking wizard is not used: it stays unconnected and unbuffered
in clk_wiz_0 so that the wizard's port numbering (clk_out3 = 200 MHz) is unchanged. The constraint model of the
D-PHY HS input keeps a 210 MHz DDR clock (4.762 ns period) as the conservative bound for the fastest selectable
mode.

### Clock tree

Everything that moves video runs on the one 90 MHz clock of `rtlnet_video_clock` (an MMCM fed by FCLK0). The
50 MHz clock serves PS GP0 and the AXI-Lite slaves; the 200 MHz clock serves only the D-PHY IDELAY reference.
Resets: the video-clock reset controller (`rtlnet_rst_video`) releases the camera stream blocks, the gamma
control, the stage 0 capture interconnect and the capture side; `rtlnet_rst_encoder` releases the encoder (same
clock, separate controller); the 50 MHz controller releases the AXI-Lite slaves. A 50 MHz-domain reset must not
drive 90 MHz logic: the two clocks come from different MMCMs and have no common phase.

Crossings that remain: byte clock to 90 MHz inside the vendor receiver (asynchronous FIFO), 90 MHz to byte clock
(lane enable), HS clock inside the D-PHY, 50 MHz to 90 MHz AXI-Lite (RTLNet `rtlnet_axil_cdc` cells and the
vendor interconnect converter for the gamma control), and the reset and enable synchronizers between the 50 MHz
and 90 MHz clocks and the 200 MHz reference inside the D-PHY. The RTLNet sync, pulse-sync and `rtlnet_axil_cdc`
cells between `capture_clk` and `enc_clk` inside `rtlnet_zybo_video` remain instantiated; both ports are the same
clock, so their constraints from `scripts/rtlnet_constrain_cdc.tcl` are redundant. The encoder interrupt level
is registered in the encoder clock before its synchronizer.

## Video stream throughput at 90 MHz

The selectable sensor modes (`cpu/zynq7_h264/firmware/src/ov5640/rtlnet_ov5640_tables.h`) are 720p (RAW10, 1280 x 720,
HTS 1896, VTS 984, PCLK 56 MHz, MIPISCLK 280 MHz) and 1080p (RAW10, 1920 x 1080 from the Digilent 1080p30 table, HTS 2500,
VTS 1120, PCLK 84 MHz, MIPISCLK 420 MHz). The sensor runs 30 fps in both modes (measured, see "Hardware bring-up"); the
stream is 720p30 (every frame admitted) and 1080p15 (every second frame admitted).

- Stream-side capacity: the Bayer block receives four pixels per beat and emits one pixel per clock, so a 90 MHz
  clock carries 90 Mpixel/s. The receiver's RAW10 formatter handles 3.2 pixels per clock.
- Pixel burst rate during an active line, bounded by the CSI-2 lanes (two lanes, RAW10, 10 bit per pixel): 720p,
  2 x 280 Mb/s / 10 = 56 Mpixel/s (byte clock 35 MHz); 1080p30, 2 x 420 Mb/s / 10 = 84 Mpixel/s (byte clock 52.5 MHz, HS
  clock 210 MHz DDR). Margins against 90 Mpixel/s: 1.61 (720p) and 1.07 (1080p30). The lane rate (derived from the PLL registers, not observable on the board: the D-PHY IP has no rate counter; a wrong rate would not
  have produced the error-free decoded streams below) is five times the
  sensor PCLK in both tables (the sensor sends the pixel clock continuously over two lanes); the 15 fps table of the
  earlier plan (PCLK 42 MHz, 210 Mb/s per lane) is no longer used, and the 420 Mb/s of the D-PHY constraint model is the
  1080p30 lane rate. The vendor receiver was tested at an 84 MHz byte clock with a 150 MHz video clock; the vendor
  documents no minimum video clock.
- Frame rate: PCLK / (HTS x VTS) is 30.0 fps for the 720p table (named 60 fps in the vendor table) and 30.0 fps for the
  1080p30 table. Measured on the board with the frame counter of `show camera`: 720p 29.94 to 30.1 fps, 1080p 29.99 to
  30.05 fps. Frame admission is in the PL (`rtlnet_zybo_video`): mode 0 (720p) admits every frame and reports a PTS step of
  3000 (30 fps), mode 1 (1080p) admits every second frame and reports 6000 (15 fps). The capture and encoder paths need far
  less than the stream capacity: 720p30 encoder input is 27.6 Mpixel/s.
- Receiver buffering: a 1024-word asynchronous FIFO (32 bit, byte clock to video clock) and a line buffer of
  2048 beats x 4 pixels = 8192 pixels, more than one 1920-pixel line. Arrival never exceeds drain at the
  sensor link rates (56, 42 or 84 against 90 Mpixel/s), so the backlog does not grow inside a line; a downstream
  stall would have to outlast the line buffer (8192 pixels / 56 Mpixel/s = 146 us) to overflow it.
- Bench evidence (`tb_rtlnet_zybo_video`): one 90 MHz clock for camera, capture and encoder; the camera model
  offers pixels at 56/90, 84/90 and 42/90 pixels per clock into a receiver backlog model; backlog peak, source
  stall cycles and the bit-exact luma and chroma of the captured frames are checked. The bench does not contain the
  vendor CSI-2 receiver or the D-PHY, and its frames (32 x 16) are short. The vendor receiver at a 90 MHz video
  clock is not simulated and not verified on hardware.

Supported modes at 90 MHz: 720p (sensor 30 fps, stream 30 fps) and 1080p (sensor 30 fps, stream 15 fps). The Bayer, gamma and adapter chain carried 1080p30 from the sensor on the board without an adapter error.

The adapter has four register stages (input, product, matrix sum, pair sum) before its output register, and
`u_pair_slice` adds one clock: about eight clocks (90 ns) from a gamma pixel to the capture DMA input. The
slice also ends the capture FIFO's ready path at a flop, so it never reaches the vendor Bayer and gamma clock
enables combinationally.

## Results (Baseline stage, `xc7z020clg400-1`, 11-14-2026)

| Resource | Used | Device | Percent |
|---|---|---|---|
| Slice LUTs | 33,427 | 53,200 | 62.83 |
| Slice registers | 26,371 | 106,400 | 24.78 |
| Block RAM tiles | 28 | 140 | 20.00 |
| DSPs | 48 | 220 | 21.82 |

| Clock pair | Setup slack | Hold slack |
|---|---|---|
| 90 MHz video clock, intra-clock (73,079 endpoints) | +0.287 ns | +0.050 ns |
| 50 MHz control clock, intra-clock | +9.585 ns | +0.057 ns |
| 200 MHz reference, intra-clock | +0.679 ns | +0.122 ns |
| rtlnet_dphy_hs (the deviation, 2 endpoints) | -0.223 ns | -1.431 ns |

Worst pulse-width slack is +0.264 ns. The camera stage uses 4,139 LUT, 4,493 registers and 6.5 block RAM tiles.
Both stages print `rtlnet_build: PASS with deviation DPHY_HS_INPUT`; the deviation endpoints are the same two.
Timing without the deviation endpoints: WNS +0.287 ns, WHS +0.050 ns (Baseline), WNS +0.942 ns, WHS +0.052 ns
(camera stage).

### Own-receiver image (`own6`, `-Receiver own`, 11-15-2026)

| Resource | Used | Device | Percent |
|---|---|---|---|
| Slice LUTs | 33,820 | 53,200 | 63.57 |
| Slice registers | 27,678 | 106,400 | 26.01 |
| Block RAM tiles | 27 | 140 | 19.29 |
| DSPs | 50 | 220 | 22.73 |

| Clock pair | Setup slack | Hold slack |
|---|---|---|
| 90 MHz video clock, intra-clock (77,154 endpoints) | +0.404 ns | +0.051 ns |
| 50 MHz control clock, intra-clock | +7.167 ns | +0.052 ns |
| 200 MHz reference, intra-clock | +0.942 ns | +0.119 ns |
| byte clock `g_cam.byte_clk`, intra-clock (1,261 endpoints) | +4.816 ns | +0.063 ns |
| byte clock to 90 MHz / 90 MHz to byte clock | +17.656 ns / +9.501 ns | |
| `rtlnet_dphy_hs` (the deviation, 2 endpoints) | +0.584 ns | -1.429 ns |

Worst pulse-width slack is +0.264 ns. The gates print `rtlnet_build: PASS with deviation DPHY_HS_INPUT (2 endpoints, own receiver; run-time tap sweep is the evidence)`; timing without the two
endpoints: WNS +0.404 ns, WHS +0.051 ns. The receiver core takes 2,665 LUT, 2,923 registers, 2 RAMB36, 1 RAMB18 and 11 DSP48 of it. The vendor chain and the stage 0 sink are absent from this image, the
receiver core brings its pattern generator (about 1,100 LUT), so the total is 393 LUT above the reference image. Two builds of identical sources (`own5` and `own6`) gave identical numbers.

## Timing deviation `DPHY_HS_INPUT`

The two high-speed lane sampler inputs of the Digilent D-PHY receiver cannot close static timing; the published
reference design fails on the same two endpoints. The timing gate accepts exactly these two:

```text
rtlnet_camera_i/MIPI_D_PHY_RX_0/U0/DataLaneGen[0].DPHY_LaneSFEN_X/HSDeserializerX/Deserializer/DDLY
rtlnet_camera_i/MIPI_D_PHY_RX_0/U0/DataLaneGen[1].DPHY_LaneSFEN_X/HSDeserializerX/Deserializer/DDLY
```

| Lane | Setup slack | Hold slack | Sum | Setup / hold clock insertion |
|---|---:|---:|---:|---:|
| 0 | -0.184 ns | -1.431 ns | -1.615 ns | 1.372 / 4.123 ns |
| 1 | -0.223 ns | -1.388 ns | -1.611 ns | 1.364 / 4.110 ns |

Both paths are input IBUFDS, IDELAYE2, ISERDESE2 with zero fabric data routing delay. The requirements are
2.381 ns for setup and 0.000 ns for hold. The static data transition model is 0.357..2.024 ns on each DDR edge.
The published reference fails the same two endpoints (WNS -2.450 ns, WHS -1.038 ns) because its fixed 200 Mb/s
example delays mismatch its 210 MHz clock. No input delay is relaxed and no sampler false path or clock group
is added.

| Item | Instantiated behavior / access |
|---|---|
| IDELAYE2 data primitive | VARIABLE, 5-bit tap capability 0..31 |
| Configured tap | 12 + compensation; both compensations are 0; configured taps 12/12 |
| Tap load / enable / increment | `cIDLY_LD`, `cIDLY_CE`, `cIDLY_INC` tied to zero in DPHY_LaneSFEN |
| Current tap output | `cIDLY_CNT => open`; no AXI readback |
| Automatic tap search | Absent; no generic enables it |
| Byte alignment | Per-burst SoT search over offsets 0..7; hard/soft match and error flags |
| Burst reset | LP stop / HS reset re-arms the alignment pipeline |
| AXI readback | Control at +0; version at +12; other reads return zero |
| PPI outputs | Sync/valid/SoT-error pulses and clock-active/IDELAY-ready ports exist, but AXI does not expose them |

VARIABLE does not mean active tap training. The deviation means "matches the published reference, static
timing not closable, hardware verification required"; the verdict describes a reference configuration and never
claims run-time tap training. The firmware `show camera` command reads control and version and reports
`tap_training=disabled`, `aligned/lock/tap readback=unavailable` and the configured taps as not measured.

The timing gate enumerates one worst setup and hold path per endpoint, cross-checks the full minima, verifies
both exact pins and primitive types, and rejects incomplete queries, unexpected failures and pulse-width failures.
Only exactly those two failing endpoints permit the deviation. Full WNS/WHS and WNS/WHS excluding them are printed
and recorded separately. `Timing 38-282` with its exact message and `Route 35-39` with the prefix `The design
did not meet timing requirements.` qualify only under this predicate, only in implementation and parent logs;
changed IDs or messages, synthesis occurrences and other critical warnings fail. The bitstream, the XSA and
`gate_pass 1` appear only after all remaining gates pass.

Closing the hardware verification needs PPI instrumentation to observe IDELAYCTRL ready, each lane's HS
sync/valid activity and the absence of SoT/sync errors over bursts and restarts, plus sustained 720p30 and
1080p15 image capture and decoded streaming across power, temperature and cable conditions, and a review of the
electrical margin. The AXI registers cannot provide the per-lane observations; a separate instrumented image is
required. A successful CLI register read alone does not close the item.

Vendor CDC findings are reviewed per crossing: two HS-settle reset releases, three stable lane-enable
synchronizers, two independent clock-active reset bridges and 37 held FIFO payload/control paths. The lane-enable
register (`aClkEnableInt` and the two `aDEnableInt` bits are one expression, `vEnable and video_aresetn`) is merged
by synthesis and keeps one of those three names; the review accepts exactly those names. Native violation-object
waivers pin the actual endpoints; changes to the catalog or the counts fail closed. Methodology waivers cover only
the corresponding reviewed CDC summary, the vendor reset LUT finding, four asynchronous LP sampler ports and,
conditionally, the two deviation hold findings. Raw and waived reports remain beside the effective reports. There
is no rule-wide severity downgrade.

### `DPHY_HS_INPUT` in the own-receiver image

The deviation is the same named one with the two `ISERDESE2` `DDLY` pins of the own receiver
(`...u_rx/g_cam.u_dphy/u_io/g_amd.g_lane[0].u_iserdes/DDLY` and `[1]`) as its endpoints; the gate accepts the deviation only when exactly these two fail
(`rtlnet_camera_timing::use_own_endpoints`). Measured: setup +0.623 ns (lane 0) and +0.584 ns (lane 1) met, hold -1.429 ns and -1.385 ns failed (clock skew of 2.94 ns between the pin and the sampler, the data path
IBUFDS, IDELAYE2, ISERDESE2 without fabric routing). The IDELAYE2 of the own receiver is `VAR_LOAD` and is loaded from `RX_TAPS` at run time; static timing uses its attribute `IDELAY_VALUE` 0 and cannot see the loaded tap, so no tap makes the static model close
(setup and hold slack move in opposite directions by 78 ps per tap, and their sum is -0.80 ns for both lanes). The input delay model (data valid 0.357 to 2.024 ns after each clock edge) is the one of the reference build.

What the own receiver adds is the measurement the reference chain could not give: the tap sweep in "Hardware bring-up, own-receiver image". It shows the receiver error-free over a wide range of taps; it does not replace the static model
(one board, one cable, room temperature) and the deviation stays named and open in `build_info.txt` (`dphy_hardware_verification open`).

## Publication and stage inputs

Both stages save the gated design as `post_route.dcp`, resume `impl_1` to `write_bitstream`, and use a pre-hook
to open that exact checkpoint before bitstream generation. This preserves post-route physical optimization and
native waiver objects while registering the bitstream with the project run. The run status must be
`write_bitstream Complete`; the run bit must be nonempty and at least as new as the gated checkpoint. The root
bit is copied from that run. `write_hw_platform -include_bit` then exports the selected implementation run.
Python checks the ZIP CRC, one embedded bitstream, a hardware handoff and exact embedded-bit equality. The manifest
hashes the checkpoint, bit and XSA. Only then, after the final warning audits, does `build_info.txt` gain
`gate_pass 1` and the PASS lines print. A coded FAIL removes the published exports and the success marker and
keeps the reports and run artifacts.

| Step | Required inputs | Produced artifacts |
|---|---|---|
| Camera prerequisite for Baseline | Camera tag `build_info.txt`: stage camera, matching part, `gate_pass 1` | Admission only; no artifact copied |
| Either stage synthesis and route | Checked source lists, staged vendor IP, board Tcl and XDC; Baseline adds the video RTL and the CDC hook | Own project, routed reports, gated `post_route.dcp` |
| Either stage publication | Own gated checkpoint and implementation run | Run-owned bit, copied root bit, bit-inclusive XSA, export manifest, completed `build_info.txt` |
| Firmware build | Baseline tag XSA, firmware sources, resolved Vitis tools | XSA-hash-matched BSP and ARM ELF |
| Hardware load | Matching bit, PS initialization and ELF | PS application executes in DDR; no PL ELF merge |

The exact LUT cap is 45,220 even if a larger count rounds to 85.00 percent, so that a High profile leaf still
fits; the 85 percent checks also cover registers, block RAM and DSP. Publication failure codes are 40
(checkpoint/run/bit), 41 (XSA), 42 (archive verification), 43 (manifest/gate marker), 24 (final critical-warning
audits) and 44 (PowerShell completed-artifact checks). Other uncaught Tcl errors also print a coded FAIL. The
checkpoint pre-hook compares `TOP`, since the design `NAME` after `open_checkpoint` need not equal its top
module. The opt_design pre-hook also excludes block RAM cells from the block RAM power optimization
(`set_power_opt -exclude_cells`): that step inserts asynchronously cleared enable flops into `u_video`, which the
reset inventory gate (no asynchronous reset in user video logic) rejects.

`scripts/check_gates.ps1` (a regression entry) runs the gate policy checks without Vivado: source closure,
deviation and vendor-review policy against committed fixtures (`testbench/fixtures`), the publication flow with
mock launchers, the implementation gates and the camera IP staging.

## Baseline source and module-reference boundary

The recursive filelist and include-directory pattern follows the Nexys Video flow and keeps the technology and
RAM wrappers. This flow additionally registers included headers before IP Integrator parses module references.
The preflight derives 54 RTL files, one header, three packages and 51 module definitions from the actual core
filelists, validates all includes and package references in compile order and checks module instantiations
against those definitions. Only the exact external definitions `xpm_memory_sdpram` and `SRLC32E` come from
XPM/UNISIM. It emits the manifest consumed by Tcl; omission and package-order negative controls reject. The
lexical audit supplements the Active-HDL compiler. Tcl registers headers first (`Verilog Header`, plus global
include for `rtlnet_technology.svh`), sets include directories, explicit AMD selection and the XPM libraries,
adds the RTL in derived order in one `add_files` call and updates the compile order before creating the BD.

The only Baseline module-reference top is `rtlnet_zybo_video_bd.v` (`rtlnet_zybo_video_own_bd.v` in the own-receiver variant, checked the same way by `check_baseline_sources.py --receiver own`). It uses plain Verilog scalar and vector wire
ports and simple parameters, preserves all interface, clock, reset and interrupt attributes (the interrupt
carries `SENSITIVITY LEVEL_HIGH`), and instantiates the SystemVerilog implementation as `u_rtl`.
`scripts/rtlnet_generate_video_wrapper.py` generates it and the source-closure check verifies it. The register
segment of the module reference is discovered by the BD Tcl (`u_video/S_AXI/reg0`) and assigned at 0x44a00000.
`rtlnet_zybo_video.sv`, the adapter and the benches are hand-maintained.

Both `tb_rtlnet_zybo_video` cases instantiate this wrapper and the complete encoder-stage hierarchy against
the GP and HP models and a post-gamma RGB stimulus; `scripts/check_board_encode.ps1` runs the same bench
through the repository simulator runner and decodes its Annex B output with the repository's three reference
decoders (a mutated reconstruction and a damaged stream are negative controls).

## Address map, memory map, interrupts

| GP0 address | Owner |
|---|---|
| 0x43c00000 | Digilent D-PHY |
| 0x43c10000 | Digilent CSI-2 |
| 0x43c20000 | Digilent gamma |
| 0x44a04000 | RTLNet one-master arbiter |
| 0x44a05000 | Camera admission and capture metadata |
| 0x44a06000 | RTLNet capture DMA |
| 0x44a07000 | Three-slot frame buffer |
| 0x44a08000 | One-engine H.264 encoder |
| 0x44a09000 | Own camera receiver `rtlnet_csi2_rx` (own-receiver image only; the 0x43c0_0000 addresses above exist in the reference image only) |

| Physical DDR region | Use |
|---|---|
| 0x00100000..0x0fffffff | ARM application, heap, stacks |
| 0x10000000..0x10bfffff | Three 4 MiB capture slots |
| 0x11000000 / 0x11200000 | Reference/reconstructed A luma/chroma, 2 MiB each |
| 0x11400000 / 0x11600000 | Reference/reconstructed B luma/chroma, 2 MiB each |
| 0x12000000..0x127fffff | Compressed ring |
| 0x13000000..0x13007fff | 256 index records of 128 bytes |

The video memory envelope is 0x10000000..0x13007fff; the ARM linker excludes it, and HP ownership transitions
require Cortex-A9 cache maintenance. IRQ_F2P bits 0 and 1 map to GIC IDs 61 and 62. Capture uses an edge pulse;
the encoder uses a synchronized level until serviced. The ARM platform owns the fabric handlers, while emacps
owns the PS GEM interrupt. AXI-Lite transactions cross atomically into the capture and encoder logic; frame data
crosses DDR with explicit slot ownership, completion responses and CPU cache maintenance. The capture timestamp
divider counts 90 clocks per microsecond. The frame sequence increments only on admission; 1080p admits alternate
frames and 720p admits every frame. Firmware PTS steps are 3000 or 6000 at 90 kHz.

## Hardware bring-up (11-15-2026)

Board: Digilent Zybo Z7-20 with a Pcam 5C, USB powered (JTAG and UART through one micro-USB cable on a direct PC port),
PS Ethernet to a switch. Build `enc14` (Baseline stage, gates PASS with the deviation below), firmware `fw10`. Load with
`scripts/program.ps1` (volatile JTAG: PL, PS initialization from the XSA, ARM ELF on core 0; core 1 untouched). Host test:
`scripts/stream_test.ps1`.

| Stage | Result | Evidence |
|---|---|---|
| a Console | pass | banner and prompt on the UART (about 40 s after the load before the clock fix, about 10 s after it), `show version` prints the build ID |
| b PS Ethernet | pass | RTL8211F (PHY ID 001cc916), link up, DHCP lease, ping from the PC |
| c Clocks, resets | pass (indirect) | the 90 MHz clock, the 200 MHz reference and the resets are not readable by a register; capture, encoder and the HP ports run, so they are up |
| d Camera control | pass | OV5640 ID 0x5640 over I2C, sensor tables load, the PL counts frames |
| e D-PHY, CSI-2 | pass, deviation open | 30 fps frame counter in both modes, adapter error counter 0, no decode error in 292 s of 720p and 142 s of 1080p |
| f Video path | pass | Bayer, gamma, adapter, capture, frame buffer: frames are decoded without error on the PC |
| g Encoder | pass | 9,006 pictures in 292 s without an error, constant QP 28: 0.17 Mb/s for the dark scene, about 1 Mb/s for the lit desk |
| h Network, decode | pass | MPEG-TS over UDP, no continuity error, ffprobe and ffmpeg without error |

Measured rates (frame counter of `show camera`, two reads 10 s to 290 s apart): 720p sensor 29.94 to 30.12 fps, admitted
the same; 1080p sensor 29.99 to 30.05 fps, admitted 14.96 to 15.03 fps. The sensor runs 30 fps in the 720p table that the vendor
names 60 fps. The lane rates follow from the sensor PLL registers (five times PCLK: 280 Mb/s at 720p, 420 Mb/s at 1080p30);
they are not observable on the board.

Stream figures: 720p 1280x720 30.00 fps, 6.38 MB in 292 s (0.17 Mb/s, constant QP 28, dark scene); 1080p 1920x1080 15.00 fps,
1.91 MB in 142 s (0.11 Mb/s). Both are h264 Constrained Baseline, every GOP of 30 pictures starts with an IDR.

### Timing deviation `DPHY_HS_INPUT`, hardware status

Not closed, not contradicted. The D-PHY registers (control at +0, version at +12) expose no lane, alignment or error status, and the
vendor receiver has no data-tap training. The runs of 292 s (720p) and 142 s (1080p) show no corrupted frame, no adapter error
and no decode error, on one board, one cable and room temperature. The two endpoints still fail static timing by
the margins above, so this is a hardware observation of one unit and not a timing closure; the margin question needs the instrumented image
described in the deviation section (per-lane HS sync/valid, IDELAY ready) and a temperature and cable review. No tap value or clock
setting was changed.

### Own-receiver image (`own6` with firmware `fw16`, 11-15-2026)

Load: `scripts/program.ps1 -Tag own6 -FwTag fw16` (volatile JTAG, serial console COM6). Host tests with the explicit port: `scripts/stream_test.ps1 -Port COM6` and `scripts/rx_test.ps1 -Port COM6`.

| Stage | Result | Evidence |
|---|---|---|
| a to d | pass | console, DHCP, OV5640 as before; `show camera` prints `receiver=own`; `show rx` after boot: `status=0x07f` (clock running, both lanes in a burst and locked, IDELAYCTRL ready, in frame), `FRAMES` 940 at the first look, `lines=720 pixels=1280`, all error counters 0 |
| e Receiver counters, 60 s | pass | `ZYBO_RX_COUNTERS: PASS 22/22`: 720p `FRAMES` 3 to 1,811 in 60.2 s (30.03 fps), 1080p 3 to 1,809 (29.99 fps); `ECC_CORR`, `ECC_UNC`, `CRC`, `SOT`, `DT`, `TRUNC`, `OVF`, `SIZE`, `ORPHAN`, `LEN`, `CLKLOSS` all 0 at both |
| f `stream_test.ps1 -Mode both -Port COM6` | pass | `ZYBO_STREAM_TEST: PASS 16/16` in three consecutive runs (sensor 30.0 fps, admitted 30.0 fps at 720p and 15.0 fps at 1080p, no encoder error, no dropped picture, continuity counters and decode clean from the second IDR picture, picture check) |
| g Soak | pass | `stream_test.ps1 -Mode 720p -Seconds 120`: `ZYBO_STREAM_TEST: PASS 8/8`, 3,573 access units in 112 s, `cc_errors=0`, 0 decode errors, 6,581 datagrams sent and received |
| h IDELAY sweep | see below | window per mode and lane |

Picture (decoded frames `build/final_*_720p_frame.png`, `final_*_1080p_frame.png`; scene: a room with a ceiling fan, a monitor, a window and a bed; the camera looks at this scene, not at a colour chart): upright in both modes,
the same field of view as the reference image `enc14` with `fw13` on the same scene (ceiling fan, window frame, monitor corner, lamp at the same pixel positions in the 720p and the 1080p frame, no shifted or missing column or line).
Colours: the walls, ceiling and the white bezel are neutral, the fan blades are brown, the blanket blue-grey; the sunlit window is clipped and shows pink at 1080p (a clipped green channel with red and blue
raised by the white balance gains), the lower wall is slightly violet at 1080p (lens shading, not corrected), the black monitor and shadows are red-brown (as in the reference image). Sharpness (|gradient| of the luma, fan blades 720p, 90th and 99th percentile: reference 21 / 84,
own 26 / 82; window frame 15 / 69 against 13 / 59; 1080p ceiling and bed 3 / 24 and 11 / 51 against 3 / 22 and 12 / 48): the same within the differences of exposure; the own picture is smoother in flat areas (Laplacian variance of the whole 720p frame
22.6 against 66.3 for the reference).

White balance (mean R:G:B of 8-bit decoded PNG regions, neutral wall at 700,330,150x80 of the 720p frame): reference image 147:184:149 (R/G 0.80, B/G 0.81); own receiver with gains 1.0 and without green equalisation 167:195:162 (R/G 0.86, B/G 0.83);
with the firmware default gains 182:187:187 (R/G 0.97, B/G 1.00). Five neutral regions at 720p (wall, wall left, bed linen, bezel, ceiling lamp dome): R/G 0.97 to 1.02 and B/G 0.96 to 1.09 (the bezel, the brightest, is the high one). At 1080p (the wall at 1000,300,300x200, with gains 0x195 / 0x100 / 0x17C): reference 98:129:102
(R/G 0.76, B/G 0.79), own with the 720p gains 132:143:139 (R/G 0.92, B/G 0.97), own with the 1080p gains 141:141:145 (R/G 1.00, B/G 1.03); four 1080p regions R/G 1.00 to 1.01, B/G 0.93 to 1.03. The gains are applied before the gamma curve, so the linear
gain is about the square of the correction seen in the decoded picture.

A two-pixel luma pattern (+-6 percent) showed in flat areas in the first pictures with the own receiver (green level of the four pixel parities (0,0), (1,0), (0,1), (1,1) of a wall: 190 / 201 / 178 / 190): the OV5640 in its binned 720p mode delivers two greens that differ by about 8 percent, which the 2 x 2 averaging of the Digilent Bayer block hides
and the 3 x 3 bilinear demosaic of the own receiver shows. The green equalisation of the core (`PROC` bit 1) removes it: the green level of the four parities (0,0), (1,0), (0,1), (1,1) is 188.2 / 187.9 / 188.5 / 188.3 afterwards (190 / 201 / 178 / 190 before).

Margin (`rx_test.ps1 -Action sweep`, 3 s per tap, section 12.1 of `cores/rtlnet_csi2_rx/documentation/rtlnet_csi2_rx.md`): both lanes at one tap, 720p error-free taps 0 to 29 (30 taps, 2,340 ps; errors at 30 and 31), 1080p error-free taps 0 to 21 (22 taps, 1,716 ps; errors at 22 to 26, clean again from 27, the next bit
period). Independent lanes (the other lane at tap 10): 720p lane 0 taps 0 to 30, lane 1 taps 0 to 29; 1080p lane 0 taps 0 to 22 (errors 23 to 26), lane 1 taps 0 to 21 (errors 22 to 25); the lanes differ by about one tap. Default taps 11 (lane 0) and 10 (lane 1). The lower edge of the window lies below tap 0 and is not measured (extrapolated at about tap -4 at 1080p from the 30.5-tap bit period). Not measured: temperature, supply, other cables and boards.

Faults found with the own receiver and corrected in the core: the HS inputs of the receiver had the internal 100 ohm termination on (`DIFF_TERM` TRUE), which the placer rejected in bank 35 at 3.3 V (DRC BIVC-1); the receiver has the parameter `HS_DIFF_TERM` and the board sets it to 0.
The two-pixel pattern above led to the green equalisation. No sync, ECC, CRC or clock fault was found on the board; the burst-end hold and the bit order needed no change.

### Faults found on the board

1. The firmware hung in its first delay: the Cortex-A9 global timer was never started (control register 0). Fixed in `plat_init`.
2. `plat_ticks`/`plat_uptime_ms` used the BSP macro `COUNTS_PER_SECOND`, which expands to `XPAR_CPU_CORE_CLOCK_FREQ_HZ/2` without parentheses: the time was
   four times slow in its seconds part and stepped backwards every two seconds. The encoder time-out (500 ms) fired by chance, the firmware
   abandoned a running P picture, and the next picture start rewrote PIC_CFG under it. The picture then coded without waiting for motion
   search and the core waited for the search in its end-of-picture state forever: STATUS.BUSY stuck, MB_COUNT 3,600, PIC_CFG 0x401 (the
   value written by the driver's configure step) while the picture was a P picture. Read-out with a throwaway build (debug word: state E_FLUSH,
   motion search active and not idle, every other unit idle; the debug build is not kept). Fixed in `cpu/zynq7_h264/firmware/src/rtlnet_platform.c`.
3. A stream stop with a picture in flight left the core BUSY (before fix 2): `venc_stop` now drains the picture first.
4. Power: through a weak USB port the whole board reset (SLCR REBOOT_STATUS 0x00400002, power-on reset bit only, PL configuration lost,
   `fpga -state` "not configured") 60 to 80 ms after the ARM started with the PL configured and clocked; no firmware cause was found
   (reset-cause registers, a `b .` loop and an unconfigured PL survive). A direct PC USB port removed it.
5. The picture is upright: the sensor flip bits of `0x3820` are cleared, the sensor mirror (`0x3821` bit 1) is set and the horizontal timing offset `0x3811` is one column higher, which keeps the Bayer phase.
6. The first IDR picture of a new UDP flow can arrive out of order at the PC although the board sends the datagrams in order (trace of every `udp_sendto`); `stream_test.ps1` judges the stream from the second IDR picture and reports the continuity errors of the first GOP.

Picture quality: a decoded 720p frame of a lit desk with two monitors (`boards/zybo_z7_20/build/bringup/f20.png`) is a real camera picture,
sharp text on the monitors, plausible colours (warm light, white screens white), no tearing or shift, but dark; the picture is upright.
Later runs (dark room) give nearly black pictures; the host test reports its picture check as FAIL and is not changed.

## What is verified

Simulation (Active-HDL, `scripts/rtlnet_regression.ps1 -Match 'zybo|zynq7'`, 13 of 13 pass): the RGB adapter against a
reference model, the HP bridge against a byte-level oracle, the integrated camera-to-encoder board bench (1080p mode admits
alternate frames, 720p mode admits every frame, PTS steps 6000 and 3000) with a decoded picture, and the ARM host suites, each
with a negative control. Build: both stages pass every gate with the deviation above. Hardware: see "Hardware bring-up".
Not verified: the D-PHY sampling margin over temperature and cables, the lane rates (derived, not observable), 1080p30 as a stream
(the stream is 1080p15), a bright scene with the test's picture check, the supply on a wall adapter, other boards.
