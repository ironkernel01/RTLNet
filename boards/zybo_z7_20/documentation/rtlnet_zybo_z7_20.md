# Zybo Z7-20 camera integration

Revision: 11-15-2026.

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
| 140 / 210 MHz | sensor forwarded clock, 720p / 1080p30 | DDR HS input sampling |
| 35 / 52.5 MHz | D-PHY HS clock / 4 | recovered byte stream |

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
5. Open observation: the first decoded picture is rotated by 180 degrees (see the picture note below).

Picture quality: a decoded 720p frame of a lit desk with two monitors (`boards/zybo_z7_20/build/bringup/f20.png`) is a real camera picture,
sharp text on the monitors, plausible colours (warm light, white screens white), no tearing or shift, but dark and rotated by 180 degrees.
Later runs (dark room) give nearly black pictures; the host test reports its picture check as FAIL and is not changed.

## What is verified

Simulation (Active-HDL, `scripts/rtlnet_regression.ps1 -Match 'zybo|zynq7'`, 13 of 13 pass): the RGB adapter against a
reference model, the HP bridge against a byte-level oracle, the integrated camera-to-encoder board bench (1080p mode admits
alternate frames, 720p mode admits every frame, PTS steps 6000 and 3000) with a decoded picture, and the ARM host suites, each
with a negative control. Build: both stages pass every gate with the deviation above. Hardware: see "Hardware bring-up".
Not verified: the D-PHY sampling margin over temperature and cables, the lane rates (derived, not observable), 1080p30 as a stream
(the stream is 1080p15), a bright scene with the test's picture check, the supply on a wall adapter, other boards.
