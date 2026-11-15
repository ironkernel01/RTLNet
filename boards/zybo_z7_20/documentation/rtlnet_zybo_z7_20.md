# Zybo Z7-20 camera integration

Revision: 11-15-2026.

The target is the Digilent Zybo Z7-20 (`xc7z020clg400-1`). The camera (Digilent Pcam 5C, OV5640, two MIPI lanes) is received by the
IronKernel receiver `rtlnet_csi2_rx` (`cores/rtlnet_csi2_rx`, parameter `CAMERA_RX` = 1): D-PHY front end on the camera pins, CSI-2 packet
layer, Bayer conversion with white balance and YUV422 output. The picture is encoded with one RTLNet H.264 Baseline engine (deblocking filter on)
and the ARM application streams the result over the PS Gigabit Ethernet. The design is one flow: the capture DMA with its frame buffer, one
deblocking encoder, the arbiter and two 128-to-64-bit AXI3 bridges for the HP ports surround the receiver in the module `rtlnet_zybo_video`.

## Video wrapper

`hdl/rtlnet_zybo_video.sv` is the one hand-maintained wrapper (its plain-Verilog IP Integrator boundary `rtlnet_zybo_video_bd.v` is generated from it by
`scripts/rtlnet_generate_video_wrapper.py`; `--check` is part of `scripts/check_gates.ps1`). It contains:

- `rtlnet_csi2_rx` (`u_rx`) with the parameters `CAMERA_RX` 1, `DPHY_TARGET` "AMD", `NONCONT_CLOCK` 0, `IDELAYCTRL_INST` 1, `HS_DIFF_TERM` 0 and the frame
  geometry of the wrapper. The camera pins (`dphy_hs_clock_clk_p/n`, `dphy_data_hs_p/n`, `dphy_clk_lp_p/n`, `dphy_data_lp_p/n`) and the 200 MHz delay reference `ref_clk` go
  straight to it. The HS inputs run without the internal 100 ohm termination (`HS_DIFF_TERM` 0): bank 35 is at 3.3 V because of the camera GPIO and I2C pins, an
  LVDS_25 input with internal termination needs 2.5 V (DRC BIVC-1), and the Pcam adapter terminates the lanes.
- the camera admission and capture metadata registers (0x44A0_5000): 720p admits every frame (PTS step 3000, 30 fps), 1080p admits every second frame (PTS step 6000, 15 fps).
  The admission takes the YUV422 words of the receiver directly: `m_axis_tready` is high while a frame is not admitted, otherwise the capture slice is ready, so a skipped frame never
  stalls the receiver. The receiver cannot be stalled: its byte-clock FIFO drops entries when the capture path is not ready and counts them in `OVF`.
- `u_pair_slice`, a register slice that ends the capture FIFO ready path at a flop (one extra clock), the capture DMA (`rtlnet_vdma_s2mm`), the three-slot frame buffer
  (`rtlnet_framebuf`), the arbiter, the encoder, the HP bridges and the GP0 decoder with six 4 KiB windows (0x44A0_4000 to 0x44A0_9000, the receiver at 0x44A0_9000).
- `DPHY_TARGET` is a string parameter of the wrapper for the bench: any value other than "AMD" selects the behavioural D-PHY front end. The boundary does not expose it.

### Camera wrapper registers (0x44A0_5000)

| Offset | Register | Content |
|---|---|---|
| 0x000 | ID | 0x5A43414D |
| 0x004 | VERSION | 0x11152026 |
| 0x008 | CAPS | 0x00000002 |
| 0x00C | CTRL | bit 0 camera enable |
| 0x010 | MODE | 0 720p30, 1 1080p15 (admission) |
| 0x018 | PTS_STEP | 3000 (mode 0) or 6000 (mode 1) |
| 0x020 | SEEN | frames received from the receiver |
| 0x024 | ADMITTED | frames admitted to the capture path |

## Build flow

`scripts/build.ps1 -Tag <tag>` builds the design in one flow (parameters: `-Tag`, `-HighProfile none|full|demo` with `-HpNetlist <folder>` and `-HpTools cabac|t8|all`,
`-Implementation original|explore|holdfix` (default `holdfix`), `-StopAfter bd`). Steps:

1. `scripts/check_sources.py` derives the source closure from the recursive filelists (`hdl/rtlnet_zybo_video.f`), audits includes, packages and module references,
   checks that the generated boundary equals `rtlnet_generate_video_wrapper.py` output and writes `build/<tag>/project_sources.tcl`.
2. `scripts/rtlnet_vivado.ps1` runs `scripts/build_bitstream.tcl`: the project (part `xc7z020clg400-1`, the Digilent board files in `board_files`), the sources
   (`scripts/rtlnet_add_sources.tcl`), the block design `bd/rtlnet_zybo.tcl`, the constraints `constraints/rtlnet_camera_pins.xdc` and `rtlnet_camera_timing.xdc`, synthesis, implementation
   (strategy `holdfix`: Explore placement, aggressive hold-fix physical optimization and route), the gates and the export.
3. Gates (each failure prints a coded `rtlnet_build: FAIL (<code>)`): synthesis critical warnings (10), unresolved black boxes (10), implementation (30), timing with the named deviation `DPHY_HS_INPUT` (20), utilization (21),
   `check_timing` (22), latches and asynchronous resets in `u_video` (23), critical warnings of the runs (24), CDC and methodology with the reviewed waivers only (27).
4. Publication: the gated checkpoint `post_route.dcp`, the bitstream of the implementation run, the XSA with the bitstream (`write_hw_platform -include_bit`), `scripts/rtlnet_verify_export.py`
   (ZIP CRC, one embedded bitstream, hardware handoff, embedded bit equals the run bit), `export_manifest.txt` and `gate_pass 1` in `build_info.txt`.

The exact LUT cap is 45,220 even if a larger count rounds to 85.00 percent, so that a High profile leaf still fits; the 85 percent checks also cover registers, block RAM and DSP.
Publication failure codes are 40 (checkpoint/run/bit), 41 (XSA), 42 (archive verification), 43 (manifest/gate marker), 24 (final critical-warning audits) and 44 (PowerShell completed-artifact checks).
The checkpoint pre-hook compares `TOP`, since the design `NAME` after `open_checkpoint` need not equal its top module. The opt_design pre-hook (`scripts/rtlnet_cdc_hook.tcl`) applies the bounded CDC
constraints and excludes block RAM cells from the block RAM power optimization (`set_power_opt -exclude_cells`): that step inserts asynchronously cleared enable flops into `u_video`, which the reset inventory gate
rejects.

`scripts/check_gates.ps1` (a regression entry) runs the gate policy checks without Vivado: the source closure and module boundary, the deviation and reviewed-waiver policy with object-command mocks, the
publication flow with mock launchers, the `build.ps1` preflight and the implementation gates.

| Step | Required inputs | Produced artifacts |
|---|---|---|
| Source closure | recursive RTL filelists, board scripts | `project_sources.tcl` |
| Synthesis, route | sources, block design Tcl, constraints, CDC hook | own project, routed reports, gated `post_route.dcp` |
| Publication | gated checkpoint and implementation run | run-owned bit, copied root bit, bit-inclusive XSA, export manifest, completed `build_info.txt` |
| Firmware build | XSA, firmware sources, resolved Vitis tools | XSA-hash-matched BSP and ARM ELF |
| Hardware load | matching bit, PS initialization and ELF | PS application executes in DDR; no PL ELF merge |

### Source set and module-reference boundary

The recursive filelist follows the Nexys Video flow and keeps the technology and RAM wrappers. The flow registers included headers before IP Integrator parses module references. The preflight derives the RTL files,
headers, packages and module definitions from the actual core filelists, validates all includes and package references in compile order and checks module instantiations against those definitions. Only the exact
external definitions of XPM and UNISIM (`xpm_memory_sdpram`, `SRLC32E`, `IBUFDS`, `BUFIO`, `BUFR`, `IDELAYE2`, `IDELAYCTRL`, `ISERDESE2`) come from the libraries. Omission and package-order negative controls reject.
Tcl registers headers first (`Verilog Header`, plus global include for `rtlnet_technology.svh`), sets include directories, explicit AMD selection and the XPM libraries, adds the RTL in derived order in one `add_files`
call and updates the compile order before creating the block design.

The only module-reference top is `rtlnet_zybo_video_bd.v`. It uses plain Verilog scalar and vector wire ports and simple parameters, preserves all interface, clock, reset and interrupt attributes (the interrupt
carries `SENSITIVITY LEVEL_HIGH`), and instantiates the SystemVerilog implementation as `u_rtl`. The register segment of the module reference is discovered by the block design Tcl (`u_video/S_AXI/reg0`) and assigned
at 0x44a00000.

## Clock plan

| Clock | Source | Consumers |
|---|---|---|
| 100 MHz | PS FCLK0 | both clocking wizards |
| 50 MHz | clk_wiz_0 (`clk_out1`), 600 MHz VCO / 12 | GP0, AXI-Lite control of the receiver and the RTLNet register windows |
| 90 MHz | rtlnet_video_clock | receiver video side (Bayer, YUV), capture DMA, frame buffer, encoder, HP0 and HP2 |
| 200 MHz | clk_wiz_0 (`clk_out2`), 600 MHz VCO / 3 | `ref_clk` of the receiver: IDELAYCTRL, LP trackers and clock detector |
| 140 / 210 MHz | sensor forwarded clock, 720p / 1080p30 | DDR HS input sampling |
| 35 / 52.5 MHz | D-PHY HS clock / 4 | recovered byte stream (BUFR output, the clock Vivado names `g_cam.byte_clk`) |

The constraint model of the HS input keeps a 210 MHz DDR clock (4.762 ns period) as the bound for the fastest mode (`constraints/rtlnet_camera_timing.xdc`).

### Clock tree

Everything that moves video runs on the one 90 MHz clock of `rtlnet_video_clock` (an MMCM fed by FCLK0). The 50 MHz clock serves PS GP0 and the AXI-Lite slaves; the 200 MHz clock serves only the D-PHY IDELAY
reference and the LP/clock detectors. Resets: the video-clock reset controller (`rtlnet_rst_video`) releases the receiver video side and the capture side; `rtlnet_rst_encoder` releases the encoder (same clock,
separate controller); the 50 MHz controller releases the AXI-Lite slaves. A 50 MHz-domain reset must not drive 90 MHz logic: the two clocks come from different MMCMs and have no common phase.

Crossings: HS clock to byte clock inside the receiver's D-PHY front end, byte clock to 90 MHz (Gray-pointer FIFO), 90 MHz to byte clock and to the 200 MHz reference (lane enable and reset), 50 MHz to 90 MHz AXI-Lite
(RTLNet `rtlnet_axil_cdc` cells; the receiver window has its own inside the core), and the reset and enable synchronizers. The RTLNet sync, pulse-sync and `rtlnet_axil_cdc` cells between `capture_clk` and
`enc_clk` inside `rtlnet_zybo_video` remain instantiated; both ports are the same clock, so their constraints from `scripts/rtlnet_constrain_cdc.tcl` are redundant. The encoder interrupt level is registered in the encoder
clock before its synchronizer. The CDC hook requires and counts the classes `sync` 33, `reset` 3, `gray` 2 and `axil_cdc` 6.

## Video stream throughput at 90 MHz

The selectable sensor modes (`cpu/zynq7_h264/firmware/src/ov5640/rtlnet_ov5640_tables.h`) are 720p (RAW10, 1280 x 720, HTS 1896, VTS 984, PCLK 56 MHz, MIPISCLK 280 MHz) and 1080p (RAW10, 1920 x 1080
from the 1080p30 table, HTS 2500, VTS 1120, PCLK 84 MHz, MIPISCLK 420 MHz). The sensor runs 30 fps in both modes (measured); the stream is 720p30 (every frame admitted) and 1080p15 (every second frame admitted).

- Stream-side capacity: the receiver's Bayer stage emits one pixel per clock, so a 90 MHz clock carries 90 Mpixel/s.
- Pixel burst rate during an active line, bounded by the CSI-2 lanes (two lanes, RAW10, 10 bit per pixel): 720p, 2 x 280 Mb/s / 10 = 56 Mpixel/s (byte clock 35 MHz); 1080p30, 2 x 420 Mb/s / 10 = 84 Mpixel/s
  (byte clock 52.5 MHz, HS clock 210 MHz DDR). Margins against 90 Mpixel/s: 1.61 (720p) and 1.07 (1080p30). The lane rate follows from the PLL registers of the sensor tables (five times the sensor PCLK); the receiver
  has no rate counter.
- Frame rate: PCLK / (HTS x VTS) is 30.0 fps for both tables. Measured on the board with the receiver `FRAMES` counter and the frame counter of `show camera`: see "Hardware bring-up". The capture and encoder paths need far less than
  the stream capacity: 720p30 encoder input is 27.6 Mpixel/s.
- Receiver buffering: a 1024-word asynchronous FIFO (32 bit, byte clock to video clock) and a line buffer of 2048 beats x 4 pixels = 8192 pixels, more than one 1920-pixel line. Arrival never exceeds drain at the sensor link
  rates, so the backlog does not grow inside a line; a downstream stall would have to outlast the line buffer (8192 pixels / 56 Mpixel/s = 146 us) to overflow it (`OVF` counts the dropped entries).

The receiver pipeline has about 20 clocks of latency (Bayer window, YUV conversion) and `u_pair_slice` adds one clock between the receiver and the capture DMA input.

## Results (`xc7z020clg400-1`, image `own7`, 11-15-2026)

| Resource | Used | Device | Percent |
|---|---|---|---|
| Slice LUTs | 33,897 | 53,200 | 63.72 |
| Slice registers | 27,770 | 106,400 | 26.10 |
| Block RAM tiles | 27 | 140 | 19.29 |
| DSPs | 50 | 220 | 22.73 |

The gates print `rtlnet_build: PASS with deviation DPHY_HS_INPUT (2 endpoints; run-time tap sweep is the evidence)`. Full timing: WNS +0.252 ns, WHS -1.429 ns (the two deviation endpoints), worst pulse-width slack +0.264 ns;
timing without the two endpoints: WNS +0.252 ns, WHS +0.050 ns. Critical warnings: 0 in synthesis; 2 in implementation and 4 in the parent log, all the two timing statements of the deviation (waived under its predicate).
16 reviewed CDC and methodology waivers; 12 asynchronous-reset cells (the receiver's `rtlnet_reset_sync`). The previous image (`own6`, before the highlight clamp) used 33,820 LUT and 27,678 registers with WNS +0.404 ns.


## Timing deviation `DPHY_HS_INPUT`

The two high-speed lane sampler inputs of the receiver (the `DDLY` inputs of the `ISERDESE2` of each data lane) cannot close static timing: the IDELAYE2 is `VAR_LOAD` and is loaded from `RX_TAPS` at run time, static timing
uses its attribute `IDELAY_VALUE` 0 and cannot see the loaded tap, so no tap makes the static model close (setup and hold slack move in opposite directions by 78 ps per tap). The timing gate accepts exactly these two pins
(found as the `DDLY` pins of the `ISERDESE2` cells of the netlist, `rtlnet_camera_timing::discover`):

```text
rtlnet_camera_i/u_video/inst/u_rtl/u_rx/g_cam.u_dphy/u_io/g_amd.g_lane[0].u_iserdes/DDLY
rtlnet_camera_i/u_video/inst/u_rtl/u_rx/g_cam.u_dphy/u_io/g_amd.g_lane[1].u_iserdes/DDLY
```

The data path is IBUFDS, IDELAYE2, ISERDESE2 with zero fabric routing delay; the input delay model (data valid 0.357 to 2.024 ns after each clock edge of the 210 MHz DDR clock) is in `constraints/rtlnet_camera_timing.xdc`.
No input delay is relaxed and no sampler false path or clock group is added.

The timing gate enumerates one worst setup and hold path per endpoint, cross-checks the full minima, verifies both pins, and rejects incomplete queries, unexpected failures and pulse-width failures. Only exactly those two
failing endpoints permit the deviation. Full WNS/WHS and WNS/WHS excluding them are printed and recorded separately. `Timing 38-282` with its exact message and `Route 35-39` with the prefix `The design did not meet
timing requirements.` qualify only under this predicate, only in implementation and parent logs; changed IDs or messages, synthesis occurrences and other critical warnings fail. The bitstream, the XSA and `gate_pass 1`
appear only after all remaining gates pass.

The evidence for the margin is the measurement on the board, not the static model: the tap sweep (`scripts/rx_test.ps1 -Action sweep`, section 12.1 of `cores/rtlnet_csi2_rx/documentation/rtlnet_csi2_rx.md`) shows the receiver
error-free over a wide range of taps. It does not replace the static model (one board, one cable, room temperature) and the deviation stays named and open in `build_info.txt` (`dphy_hardware_verification open`).

### Reviewed CDC and methodology findings

The generic crossings of the receiver (synchronizers, Gray pointers, held AXI-Lite bundles) are bounded and waived by `scripts/rtlnet_constrain_cdc.tcl` in the opt_design pre-hook. `scripts/rtlnet_review_waivers.tcl` waives
exactly the findings that remain, each with its reason in `reports/camera_receiver_waivers.rpt`: CDC findings on the combination of `hs_go` and the clock-running level in front of two synchronizers and on the two-source
asynchronous clear of the byte-clock reset (both registers that `report_cdc` may name as the source), and three methodology findings (the LUT in front of the asynchronous clear, the TIMING-9 summary and the two hold findings of the
deviation). Any other finding fails the build (code 27); there is no rule-wide severity downgrade. The asynchronous-reset inventory allows only the `pipe_reg` cells of the receiver's `rtlnet_reset_sync` (asynchronous
assertion, synchronous release) inside `u_video`.

## Address map, memory map, interrupts

| GP0 address | Owner |
|---|---|
| 0x44a04000 | RTLNet one-master arbiter |
| 0x44a05000 | Camera admission and capture metadata |
| 0x44a06000 | RTLNet capture DMA |
| 0x44a07000 | Three-slot frame buffer |
| 0x44a08000 | One-engine H.264 encoder |
| 0x44a09000 | Camera receiver `rtlnet_csi2_rx` |

| Physical DDR region | Use |
|---|---|
| 0x00100000..0x0fffffff | ARM application, heap, stacks |
| 0x10000000..0x10bfffff | Three 4 MiB capture slots |
| 0x11000000 / 0x11200000 | Reference/reconstructed A luma/chroma, 2 MiB each |
| 0x11400000 / 0x11600000 | Reference/reconstructed B luma/chroma, 2 MiB each |
| 0x12000000..0x127fffff | Compressed ring |
| 0x13000000..0x13007fff | 256 index records of 128 bytes |

The video memory envelope is 0x10000000..0x13007fff; the ARM linker excludes it, and HP ownership transitions require Cortex-A9 cache maintenance. IRQ_F2P bits 0 and 1 map to GIC IDs 61 and 62. Capture uses an edge pulse;
the encoder uses a synchronized level until serviced. The ARM platform owns the fabric handlers, while emacps owns the PS GEM interrupt. AXI-Lite transactions cross atomically into the capture and encoder logic; frame data
crosses DDR with explicit slot ownership, completion responses and CPU cache maintenance. The capture timestamp divider counts 90 clocks per microsecond. The frame sequence increments only on admission; 1080p admits alternate
frames and 720p admits every frame. Firmware PTS steps are 3000 or 6000 at 90 kHz.

## Bench

`tb_rtlnet_zybo_video` instantiates the wrapper (behavioural D-PHY front end, `DPHY_TARGET` "GENERIC") with the complete encoder-stage hierarchy against the GP and HP models. The D-PHY transmitter model of the receiver
benches (`cores/rtlnet_csi2_rx/testbench/rtlnet_csi2_tb_phy.sv`) sends CSI-2 RAW10 frames of 32 x 16 pixels (diagonal ramps that the demosaic reproduces exactly in the interior) on two lanes at 420 and 280 Mb/s per lane.
It checks: the camera block and receiver core identities and versions; in the 1080p mode 3 of 5 frames admitted and the stored frame of the second admission (geometry 32 x 16, the luma of every interior pixel within
one step of the expected value, neutral chroma) with a held slot never overwritten; in the 720p mode every frame admitted; the receiver `FRAMES` counter 7 and every error counter 0 read over AXI-Lite; the publication
and encoder IRQs; one real lossy/deblocked IDR encode whose Annex B stream and reconstruction `scripts/check_board_encode.ps1` decodes with the repository's three reference decoders (a mutated reconstruction and a damaged
stream are negative controls). Negative controls of the bench: `INJECT_FAILURE` (the verdict fails) and `MUTATE` (one raw pixel of the checked frame is changed on the wire, the luma check fails).

## Hardware bring-up (image `own7`, firmware `fw18`, 11-15-2026)

Board: Digilent Zybo Z7-20 with a Pcam 5C, USB powered (JTAG and UART through one micro-USB cable on a direct PC port), PS Ethernet to a switch, console COM6. Load with
`scripts/program.ps1 -Tag own7 -FwTag fw18` (volatile JTAG: PL, PS initialization from the XSA, ARM ELF on core 0; core 1 untouched). Host tests with the explicit port: `scripts/stream_test.ps1 -Port COM6`
and `scripts/rx_test.ps1 -Port COM6`.

| Stage | Result | Evidence |
|---|---|---|
| a Console, b PS Ethernet, c Clocks, d Camera control | pass | prompt on the UART, RTL8211F with DHCP lease, OV5640 ID 0x5640 over I2C, receiver ID and VERSION found; `show rx` after boot: `status=0x07f` (clock running, both lanes in a burst and locked, IDELAYCTRL ready, in frame) |
| e Receiver counters, 60 s | pass | `ZYBO_RX_COUNTERS: PASS 22/22`: 720p `FRAMES` 3 to 1,812 in 60.2 s (30.04 fps), 1080p 2 to 1,809 (30.00 fps); `ECC_CORR`, `ECC_UNC`, `CRC`, `SOT`, `DT`, `TRUNC`, `OVF`, `SIZE`, `ORPHAN`, `LEN`, `CLKLOSS` all 0 at both; admitted 30.00 fps at 720p and 14.99 fps at 1080p |
| f `stream_test.ps1 -Mode both -Port COM6` | pass | `ZYBO_STREAM_TEST: PASS 16/16` in three consecutive runs (sensor 30 fps, no encoder error, no dropped picture, continuity counters and decode clean from the second IDR picture, picture check) |
| g Soak | pass | `stream_test.ps1 -Mode 720p -Seconds 120`: `ZYBO_STREAM_TEST: PASS 8/8`, `access_units=3573 cc_errors=0 pts_gaps=0`, rate 30.000, 0 decode errors |

Measured rates: sensor 30 fps in both modes; stream 720p 1280x720 30 fps and 1080p 1920x1080 15 fps (h264 Constrained Baseline, every GOP of 30 pictures starts with an IDR). At constant QP 28 the 720p stream runs at 0.74 Mb/s in a dim scene.

Picture (decoded frames saved from the runs; the room was dark when the final frames were taken, lit only by two monitors): upright in both modes, monitor text readable, the white monitor bezels and screen strips are white
(mean R:G:B of the 1080p bezel strip 214 : 212 : 203 with values up to 255 in all channels; 720p bezel strips 217 : 210 : 204). The dark scene gives no statement about the colour of lit walls: those were measured with the earlier
daylight frames (section "Colour").

### Colour

White balance gains per mode (4.8 fixed point): 720p R 0x163, G 0x100, B 0x163; 1080p R 0x195, G 0x100, B 0x17C, measured on a neutral wall, a ceiling lamp and a monitor bezel so that R:G:B is within about 5 percent in the decoded
picture (with gains 1.0 R and B are 14 to 18 percent below G). A two-pixel luma pattern (+-6 percent) in flat areas of the binned 720p mode (the OV5640 delivers two greens that differ by about 8 percent) is removed by the green
equalisation of the core (`PROC` bit 1): the green level of the four pixel parities is 188.2 / 187.9 / 188.5 / 188.3 afterwards (190 / 201 / 178 / 190 before).

#### Highlights

A clipped bright area came out pink at 1080p (a sunlit window: decoded R 251, G 218, B 248). The white balance gains of 1.4 to 1.6 on red and blue bring those channels to full scale at a raw value of 650 to 740, while green with
gain 1.0 is still lower: with the `RAW_MAX` registers of the core, bright monitor areas at 1080p reach a raw green of 790 to 803 and a raw red and blue of 660 to 714, so after the gain red and blue are clipped at 1023 and green stays
at about 800. The gamma curve then maps that to R 255, G 220, B 245: pink. At 720p the binned mode reaches 1023 in every channel (overexposed lamps measured with `RAW_MAX` 1023 / 1023 / 1023) and the highlights are white.
The highlight clamp of the core (`PROC` bit 2, `HL_LEVEL`) lifts a green at or above the level to the larger of the three channels. Defaults: 1080p level 760, 720p level 960 (`src/rtlnet_rx.h`).
Same scene (white monitor strips and bezels, 1080p, `rx highlight 0 760` against the default): mean R:G:B of the pixels with a channel at 250 or more: 251.0 : 221.6 : 234.5 without the clamp, 252.8 : 251.1 : 239.3 with it
(green lifted, the highlight neutral). Pixels below the level are unchanged (model and bench: bit-exact outside the clamp). A true clipped sunlit window was not available (dark room): the monitor strips are the clipped area used.
Not shown on the board: a saturated coloured object (a bright saturated red or orange area is desaturated towards white when its green is at the level or above).

### Receiver margin (IDELAY sweep)

Margin (`rx_test.ps1 -Action sweep`, 3 s per tap, section 12.1 of `cores/rtlnet_csi2_rx/documentation/rtlnet_csi2_rx.md`; measured on image `own6`, same receiver sources and constraints): both lanes at one tap, 720p error-free taps 0 to 29 (30 taps, 2,340 ps), 1080p
error-free taps 0 to 21 (22 taps, 1,716 ps; errors at 22 to 26, clean again from 27, the next bit period). Default taps 11 (lane 0) and 10 (lane 1). The lower edge of the window lies below tap 0 and is not measured. Not
measured: temperature, supply, other cables and boards. The sweep was not repeated on `own7`.

### Faults found on the board

1. The firmware hung in its first delay: the Cortex-A9 global timer was never started (control register 0). Fixed in `plat_init`.
2. `plat_ticks`/`plat_uptime_ms` used the BSP macro `COUNTS_PER_SECOND`, which expands to `XPAR_CPU_CORE_CLOCK_FREQ_HZ/2` without parentheses: the time was four times slow in its seconds part and stepped backwards every two seconds.
   The encoder time-out (500 ms) fired by chance, the firmware abandoned a running P picture, and the next picture start rewrote PIC_CFG under it; the core waited for the motion search in its end-of-picture state forever
   (STATUS.BUSY stuck, MB_COUNT 3,600). Fixed in `cpu/zynq7_h264/firmware/src/rtlnet_platform.c`.
3. A stream stop with a picture in flight left the core BUSY: `venc_stop` now drains the picture first.
4. Power: through a weak USB port the whole board reset (SLCR REBOOT_STATUS 0x00400002, PL configuration lost) 60 to 80 ms after the ARM started with the PL configured; a direct PC USB port removed it.
5. The HS inputs of the receiver had the internal 100 ohm termination on, which the placer rejected in bank 35 at 3.3 V (DRC BIVC-1): `HS_DIFF_TERM` 0.
6. The picture is upright: the sensor flip bits of `0x3820` are cleared, the sensor mirror (`0x3821` bit 1) is set and the horizontal timing offset `0x3811` is one column higher, which keeps the Bayer phase.
7. The first IDR picture of a new UDP flow can arrive out of order at the PC although the board sends the datagrams in order; `stream_test.ps1` judges the stream from the second IDR picture and reports the continuity errors of the first GOP.


## What is verified

Simulation (Active-HDL, `scripts/rtlnet_regression.ps1 -Match 'csi2|video_path|zybo|zynq7'`): the receiver benches including the highlight clamp and raw maxima, the HP bridge against a byte-level oracle, the integrated
camera-to-encoder board bench through the receiver (admission, geometry, receiver counters, decoded picture), the build-gate policy checks and the ARM host suites, each with a negative control. Build: every gate passes with the
deviation above. Hardware: see "Hardware bring-up".
Not verified: the D-PHY sampling margin over temperature and cables, the lane rates (derived, not observable), 1080p30 as a stream (the stream is 1080p15), the colour of lit scenes and a true clipped sunlit window with the final image
(the room was dark), the sweep on `own7`, the supply on a wall adapter, other boards, the AMD primitive branch of the D-PHY front end in simulation.

