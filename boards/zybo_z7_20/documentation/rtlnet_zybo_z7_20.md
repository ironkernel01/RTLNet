# Zybo Z7-20 camera integration

Revision: 11-14-2026.

The target is the Digilent Zybo Z7-20 (`xc7z020clg400-1`). The design keeps the Digilent Pcam 5C physical
receiver, CSI-2 receiver, Bayer conversion and gamma IP and encodes the camera picture with one RTLNet H.264
Baseline engine (deblocking filter on). The ARM application streams the result over the PS Gigabit Ethernet.

There are two build stages. Stage 0 (the camera stage) rebuilds the Digilent capture chain to an AMD AXI VDMA
S2MM connected to PS HP2. The Baseline stage replaces that sink with the RTLNet RGB-to-YUYV adapter, the capture
DMA with its frame buffer, one deblocking encoder, the arbiter and two 128-to-64-bit AXI3 bridges for the HP
ports. The Baseline stage rebuilds the whole design and uses its camera stage only as an admission check
(`build_info.txt` of the camera tag: stage camera, part `xc7z020clg400-1`, `gate_pass 1`).

## Clock plan

| Clock | Source | Consumers |
|---|---|---|
| 100 MHz | PS FCLK0 | both clocking wizards |
| 50 MHz | clk_wiz_0, 600 MHz VCO / 12 | GP0, receiver and D-PHY AXI-Lite control, RTLNet register window |
| 90 MHz | rtlnet_video_clock | CSI-2 receiver video side, Bayer, gamma, adapter, capture DMA, frame buffer, encoder, HP0 and HP2, stage 0 VDMA |
| 200 MHz | clk_wiz_0, 600 MHz VCO / 3 | D-PHY delay reference |
| 140 / 105 MHz | sensor forwarded clock, 720p / 1080p15 | DDR HS input sampling |
| 35 / 26.25 MHz | D-PHY HS clock / 4 | recovered byte stream |

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

The selectable sensor modes (`cpu/zynq7_h264/firmware/src/ov5640/rtlnet_ov5640_tables.h`) are 720p (RAW10,
1280 x 720, HTS 1896, VTS 984, PCLK 56 MHz, MIPISCLK 280 MHz) and 1080p15 (RAW10, 1920 x 1080, HTS 2500,
VTS 1120, PCLK 42 MHz, MIPISCLK 210 MHz). 1080p30 (148.5 Mpixel/s) is not offered by the firmware.

- Stream-side capacity: the Bayer block receives four pixels per beat and emits one pixel per clock, so a 90 MHz
  clock carries 90 Mpixel/s. The receiver's RAW10 formatter handles 3.2 pixels per clock.
- Pixel burst rate during an active line, bounded by the CSI-2 lanes (two lanes, RAW10, 10 bit per pixel):
  720p, 2 x 280 Mb/s / 10 = 56 Mpixel/s (byte clock 35 MHz); 1080p15 from the sensor PLL arithmetic,
  2 x 210 Mb/s / 10 = 42 Mpixel/s (byte clock 26.25 MHz). If the 1080p15 lanes ran at 420 Mb/s instead, the burst
  would be 84 Mpixel/s. Margins against 90 Mpixel/s: 1.61 (56), 2.14 (42), 1.07 (84). The vendor receiver was
  tested at an 84 MHz byte clock with a 150 MHz video clock; the vendor documents no minimum video clock.
- Frame rate: the sensor timing registers give PCLK / (HTS x VTS) = 15.0 fps for the 1080p15 table and 30.0 fps
  for the 720p table, which is named 60 fps. Frame admission halves the 720p rate for 720p30 on the assumption of a
  60 fps sensor; the frame counters measure the real rate at bring-up. The capture and encoder paths need far
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

Supported modes at 90 MHz: 720p (720p30 by frame admission) and 1080p15. Not supported: 1080p30.

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

The only Baseline module-reference top is `rtlnet_zybo_video_bd.v`. It uses plain Verilog scalar and vector wire
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
divider counts 90 clocks per microsecond. The frame sequence increments only on admission; 720p admits alternate
frames and 1080p15 admits every frame. Firmware PTS steps are 3000 or 6000 at 90 kHz.

## What is verified

Simulation (Active-HDL, `scripts/rtlnet_regression.ps1 -Match 'zybo|zynq7'`): the RGB adapter against a
reference model, the HP bridge against a byte-level oracle, the integrated camera-to-encoder board bench with a
decoded picture, and the ARM host suites, each with a negative control. Build: both stages pass every gate with
the deviation above. Not verified: anything on hardware (D-PHY sampling margin, the vendor receiver at a 90 MHz
video clock, sensor frame and lane rates, the streaming application).
