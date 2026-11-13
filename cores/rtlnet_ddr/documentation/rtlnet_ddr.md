# rtlnet_ddr — DDR3 memory controller core

| Item | Value |
|---|---|
| Core | `rtlnet_ddr` (wrapper), `rtlnet_ddr_amd` (AMD 7-series implementation), `rtlnet_ddr_sim` (simulation model) |
| Document revision | 11-09-2026 |
| Language | SystemVerilog-2012 (RTL, bench support), Vivado Tcl (IP generation) |
| Position | behind `rtlnet_axi_arbiter`; the one DDR3 port of the design |
| First target | Digilent Nexys Video: Micron MT41K256M16 x16 DDR3L (512 MiB, one rank), AMD MIG 7 series 4.2, 2778 ps memory clock (360 MHz, 720 Mb/s per pin), 4:1 ratio |
| Interface | one AXI4 slave, 128-bit data, 29-bit byte address, 4-bit ID, on `ui_clk` (90.000 MHz, the system clock of the Nexys Video build) |
| Verification | board bench in Active-HDL with `rtlnet_ddr_sim`; hardware: `ddr test` on the board (`boards/nexys_video/documentation/rtlnet_nexys_video.md` section 9) |

The core turns the vendor memory controller into a vendor-neutral AXI4 slave. Everything above it (the arbiter, the DMA
masters, the CPU caches) sees only the AXI4 port, a user clock, a reset and a calibration flag. A port to another FPGA
vendor replaces `rtlnet_ddr_amd.sv` and the IP script; no other file changes.

Contents: 1 files, 2 interface, 3 clocks and resets, 4 the MIG project, 5 simulation model, 6 integration, 7 limitations.

---

## 1. Files

| File | Content |
|---|---|
| `hdl/rtlnet_ddr.sv` | wrapper: `TARGET` selects the implementation; connects it by name |
| `hdl/rtlnet_ddr_amd.sv` | one instance of the generated `rtlnet_ddr_mig`; the only AMD-specific RTL |
| `hdl/rtlnet_ddr.f`, `hdl/rtlnet_ddr_sim.f` | filelists: synthesis (wrapper + AMD file) and benches that define `RTLNET_DDR_SIM` (wrapper + model) |
| `ip/rtlnet_ddr_mig.prj` | MIG project file, committed |
| `ip/rtlnet_ddr_mig.tcl` | `rtlnet_ddr_mig_create <dir>`: generates the MIG IP from the project into a build tree |
| `testbench/rtlnet_ddr_sim.sv` | simulation model: AXI4 memory (`rtlnet_tb_axi4_mem`) with a calibration delay |

The generated IP (RTL, constraints, XCI) is never committed; every build recreates it under `boards/<board>/build/ip`.

---

## 2. Interface

| Group | Ports | Rule |
|---|---|---|
| clocks, reset | in `sys_clk`, `ref_clk`, `sys_rstn` | `sys_clk` 102.857 MHz (9723 ps, controller PLL input, already buffered; the board feeds it from a second MMCM through a BUFG), `ref_clk` 200 MHz (IDELAYCTRL), `sys_rstn` asynchronous, active low |
| user side | out `ui_clk`, out `ui_resetn`, in `s_axi_aresetn`, out `init_calib_complete` | `ui_clk` 90 MHz; `ui_resetn` is the controller's own reset (active low, synchronous to `ui_clk`); `s_axi_aresetn` is the reset the AXI side runs with, driven by the board top; `init_calib_complete` is a `ui_clk` level |
| AXI4 slave | `s_axi_aw*`, `s_axi_w*`, `s_axi_b*`, `s_axi_ar*`, `s_axi_r*` | `ui_clk`; `ADDR_W` 29, `DATA_W` 128, `ID_W` 4 |
| DDR3 pins | `ddr3_dq[15:0]`, `ddr3_dqs_p/n[1:0]`, `ddr3_addr[14:0]`, `ddr3_ba[2:0]`, `ddr3_ras_n`, `ddr3_cas_n`, `ddr3_we_n`, `ddr3_reset_n`, `ddr3_ck_p/n`, `ddr3_cke`, `ddr3_dm[1:0]`, `ddr3_odt` | names of the MIG project |

| Parameter | Default | Meaning |
|---|---|---|
| `TARGET` | `` `RTLNET_TARGET `` ("AMD") | implementation; anything else stops elaboration |
| `ADDR_W`, `DATA_W`, `ID_W` | 29, 128, 4 | AXI4 widths; the AMD file accepts exactly these (they are the widths of the MIG project) |

The AXI4 slave follows the burst rules of the MIG: INCR bursts, full-width beats (`AxSIZE` = 4), no 4 KiB boundary
crossing, AxLEN 0..255. `rtlnet_axi_arbiter` in front checks and enforces them; a master that connects here directly
must obey them. Writes and reads are independent channels; AXI4 does not order a read behind an earlier write, so a
master that needs read-after-write waits for the write response first (the CPU firmware does, see
`microblaze/firmware/src/rtlnet_ddrtest.h`). Responses for one ID return in order.

---

## 3. Clocks and resets

* `sys_clk` is a 102.857 MHz net the board derives from the second MMCM (CLKOUT0) through a BUFG (`ddr_sys_clk`); the oscillator pad cannot feed the board MMCM and the controller PLL together (Place 30-172, rule gclkio_pll_1load). The MIG is generated
  with "No Buffer" system clock, so it connects the net to its own PLL without an input buffer.
* `ref_clk` is the board's 200 MHz MMCM output (`clk200`), also the IDELAYCTRL reference of the RGMII pin layer.
* `ui_clk` is the controller's user clock (a BUFG output inside the IP): 90.000 MHz, phase related to `sys_clk` through
  the controller PLL, asynchronous to every other board clock from the design's point of view; every crossing into or
  out of it is in `rtlnet_axi_arbiter` (register port), the board top's `rtlnet_axi_cdc` bridge `u_ddr_cdc` (the CPU's
  128-bit AXI4 master on `cpu_clk` into the arbiter) and the board top (calibration status through `rtlnet_sync`,
  reset through `rtlnet_reset_sync`).
* Reset: `sys_rstn` resets the controller (a button press or an MMCM unlock recalibrates the memory, about 100 us).
  `ui_resetn` falls while the controller clock tree is unlocked. The board top forms the reset of the AXI side with an
  `rtlnet_reset_sync` on `ui_clk` whose asynchronous input is the board reset assertion, ANDs `ui_resetn` into its
  released output, and passes the result back as `s_axi_aresetn`.

---

## 4. The MIG project

`ip/rtlnet_ddr_mig.prj` is the Digilent Nexys Video MIG project (board files A.0 1.2, `mig.prj`) with these edits only:

| Edit | Reason |
|---|---|
| `ModuleName` `rtlnet_ddr_mig` | core-owned name |
| `SystemClock` "No Buffer" (pin entry "No connect") | the clock buffer is the board's; MIG takes the net as is |
| `C0_S_AXI_DATA_WIDTH` 128 | the native width of the controller (16 DQ x 8 beats); no width conversion inside the IP |
| `C0_S_AXI_ID_WIDTH` 4 (was 2; Phase 2b-3) | the memory-side ID of `rtlnet_axi_arbiter` with `ID_W` 2 and four masters (`IDX_W` 2) |
| `UIExtraClocks` 0 (was 1; Phase 2b-3) | UI extra clocks disabled, the `ui_addn_clk_*` ports do not exist (their connections are removed from `rtlnet_ddr_amd.sv`); with the extras on, the infrastructure MMCM CLKOUT0 got `DIVIDE_F` 3.595 at the 102.857 MHz input, which fails DRC AVAL-139 (not a multiple of 0.125); `ui_clk` (CLKFBOUT) is unaffected |

Changed from the Digilent project: `TimePeriod` 2778 ps (360 MHz memory clock, DDR3-720, inside the DDR3-800 range of the part and of the speed grade). MIG then requires its input clock at 9723 ps (102.848 MHz; the wizard answers a 100 MHz input with "Invalid Input Clock Period 100, nearest 102.848"): its PLL multiplies by 14 (VCO 1440 MHz), CLKOUT1 /4 is the 360 MHz memory clock, CLKOUT3 /16 the user clock. The board feeds exactly 100 MHz x 36 / 5 / 7 = 102.857143 MHz (second MMCM, VCO 720 MHz), so `ui_clk` is 1440 / 16 = 90.000 MHz. Otherwise unchanged: part MT41K256M16XX-125, 4:1, 16-bit, AXI, 29-bit address (512 MiB), burst length 8,
CL 6, CWL 5, `RD_PRI_REG`, every pin and timing parameter. `ReferenceClock` is "No Buffer" in the original project too.

`rtlnet_ddr_mig_create` is `create_ip -name mig_7series` with `XML_INPUT_FILE` set to the project, `generate_target
all`, and `generate_synth_checkpoint false` (the controller synthesizes with the top). The IP's own constraints carry the
pin locations, I/O standards, `INTERNAL_VREF` of bank 35, the PHY site constraints and the controller's timing exceptions;
the board XDC repeats the pin properties (balls, standard, slew, input termination) so the pinout is visible in one
place. Both carry the same values.

---

## 5. Simulation model

With `RTLNET_DDR_SIM` defined, `rtlnet_ddr` instantiates `rtlnet_ddr_sim` in place of `rtlnet_ddr_amd`: same ports, no IP.

* `ui_clk` is the model's own free-running 90 MHz clock (not `sys_clk`); `ui_resetn` releases 8 clocks after `sys_rstn`; `init_calib_complete` rises 2000 `ui_clk`
  clocks after `ui_resetn` and falls with `sys_rstn`.
* The AXI4 memory model `rtlnet_tb_axi4_mem` (`cores/rtlnet_common/testbench`) answers: sparse 128-bit words, read latency
  20 clocks, INCR, full width, 4 KiB boundary checks on everything it receives. It is held in reset until calibration
  completes and `s_axi_aresetn` is released, so its ready outputs are low before.
* DDR3 outputs are idle, the data pins are not driven.

The board benches (`tb_rtlnet_nexys_video_top`, `tb_rtlnet_nexys_video_net`) define `RTLNET_DDR_SIM`. They check the
calibration bit, the reset behaviour and the arbiter window through the CPU stub; the stub does not issue DDR3 traffic
(the traffic benches are `tb_rtlnet_axi_arbiter` and the firmware memory test on the board).

---

## 6. Integration

1. Add `-f cores/rtlnet_axi_arbiter/hdl/rtlnet_axi_arbiter.f` and `-f cores/rtlnet_ddr/hdl/rtlnet_ddr.f` to the board
   filelist; the build calls `rtlnet_ddr_mig_create` (see `boards/nexys_video/scripts/build_bitstream.tcl`) before reading
   the RTL.
2. Feed `sys_clk` from a 100 MHz clock of the design on a BUFG (not from the oscillator pad that also feeds an MMCM) and `ref_clk` from a 200 MHz clock of the design.
3. Instance `rtlnet_axi_arbiter` with `ADDR_W` 29, `DATA_W` 128 and `ID_W` such that `ID_W + IDX_W` is 4; connect its `m_axi_*`
   to `s_axi_*` here and its `clk` to `ui_clk`.
4. Create the AXI-side reset as in section 3.
5. Constrain the DDR3 pins (the IP does; add them to the board XDC as well, section 4).
6. Replace the controller in simulation with `RTLNET_DDR_SIM`.

---

## 7. Limitations

* One rank, 16-bit DDR3L at 360 MHz (720 Mb/s per pin): the memory peaks at 1.44 GB/s; the 90 MHz 128-bit AXI side peaks at 1.44 GB/s and limits a
  single stream to 1.6 GB/s as well.
* No ECC, no self refresh or user refresh requests (tied inactive), no calibration tap loader.
* The AXI slave answers narrow, FIXED and WRAP bursts with unpredictable data; the arbiter keeps them out.
* The AMD file is a fixed 29/128/2 configuration; another memory or width means another `.prj` and matching parameters.
