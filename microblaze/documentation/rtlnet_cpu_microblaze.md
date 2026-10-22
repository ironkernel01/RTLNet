# rtlnet_cpu_microblaze — RTLNet CPU core (MicroBlaze)

| Item | Value |
|---|---|
| Core | `rtlnet_cpu_microblaze` |
| Document revision | 10-22-2026 |
| Language | SystemVerilog-2012 wrapper; Vivado Tcl block design |
| Technology | AMD 7-series (the one AMD-only block of RTLNet, architecture section 3) |
| Port contract | architecture section 15.6 |
| Verification | board bench `tb_rtlnet_nexys_video_top` (BFM in place of the core); hardware bring-up on the Nexys Video |

The CPU is a core like any other: a vendor-neutral port list around the processor subsystem. The
MicroBlaze block design is created by script on every build; nothing generated is committed.

## 1. Files

| File | Content |
|---|---|
| `hdl/rtlnet_cpu_bd.tcl` | `rtlnet_cpu_bd_create <bd_dir>`: creates, validates and saves the block design `rtlnet_cpu`, returns the `.bd` path |
| `hdl/rtlnet_cpu_microblaze.sv` | the core: section 15.6 ports, instance `u_bd` of the generated `rtlnet_cpu_wrapper` |
| `hdl/rtlnet_cpu_microblaze.f` | filelist (the wrapper `.sv`; the build adds the generated wrapper) |
| `driver/rtlnet_cpu_microblaze.h` | software contract: address map, vectors, interrupt numbering (single definition) |
| `testbench/rtlnet_cpu_bfm.sv` | bus-functional model with the same ports |

## 2. Interface

| Group | Ports | Contract |
|---|---|---|
| clock, reset | `clk`, `resetn` | cpu_clk 100 MHz from the board MMCM; `resetn` synchronous to `clk`, active low (board `rtlnet_reset_sync`) |
| console | in `uart_rxd`, out `uart_txd` | USB-UART bridge, 115200 8N1; `uart_rxd` is asynchronous, idle high |
| register master | `m_axi_aw*`, `m_axi_w*`, `m_axi_b*`, `m_axi_ar*`, `m_axi_r*` | AXI4-Lite master, 32-bit address and data, full processor addresses (0x44A0_0000..0x44AF_FFFF), into `rtlnet_axil_decoder`; one transaction at a time |
| interrupts | in `irq[7:0]` | level, active high, synchronous to `clk`; INTC inputs 0..7 |

`uart_rxd` needs no synchronizer in the wrapper: the UART Lite synchronizes it with its own two-stage
`ASYNC_REG` chain (`UARTLITE_RX_I/INPUT_DOUBLE_REGS3`). A replacement processor must synchronize its
receive pin the same way. AWPROT/ARPROT of the block design stay inside the wrapper (RTLNet slaves do
not use them). Architecture section 10 also lists a status output `cpu_reset_out_n`; the binding port
list of section 15.6 has none, and this core follows 15.6 (see section 9).

## 3. Block design `rtlnet_cpu`

| Cell | IP | Configuration |
|---|---|---|
| `microblaze_0` | MicroBlaze 11.0 (classic) | 32-bit, little endian (`C_ENDIANNESS` 1), 5-stage pipeline (`C_AREA_OPTIMIZED` 0), no MMU, no caches, no FPU, no branch target cache, barrel shifter, 32-bit hardware multiplier (`C_USE_HW_MUL` 1), hardware divider, pattern compare, MSR instructions, reorder instructions (default), interrupt input (normal mode), debug enabled, D-AXI on, I-AXI off, `C_BASE_VECTORS` 0, bus exceptions off (a DECERR reads as data) |
| `ilmb_v10`, `dlmb_v10` | LMB 3.0 | instruction and data local memory buses |
| `ilmb_bram_if_cntlr`, `dlmb_bram_if_cntlr` | LMB BRAM controller 4.0 | no ECC |
| `lmb_bram` | Block Memory Generator 8.4 | true dual port, BRAM controller mode; 128 KiB = 32 RAMB36 |
| `mdm_0` | MDM 3.2 | one debug port, JTAG UART on (AXI slave) |
| `axi_uartlite_0` | AXI UART Lite 2.0 | 115200 baud, 8 data bits, no parity (1 stop bit), `C_S_AXI_ACLK_FREQ_HZ` 100 MHz from the clock port |
| `axi_timer_0` | AXI Timer 2.0 | two 32-bit counters (firmware uses timer 0 free running) |
| `axi_intc_0` | AXI INTC 4.1 | 10 inputs from `irq_concat`; kinds detected from the sources (irq/timer level, UART edge) |
| `irq_concat` | inline concat 1.0 | `{uart, timer, irq[7:0]}` |
| `axi_periph` | AXI Interconnect 2.1 | 1 slave (M_AXI_DP), 5 masters |
| `rst_cpu` | Processor System Reset 5.0 | `ext_reset_in` = port `resetn` (active low), `mb_debug_sys_rst` from the MDM; `dcm_locked` tied 1 (lock is part of the board's reset assertion) |
| `const_one` | inline constant 1.0 | `dcm_locked` tie |

No clocking wizard: every clock pin is the `clk` port (`FREQ_HZ` 100 MHz).

## 4. Address map

| Base | Size | Block |
|---|---:|---|
| 0x0000_0000 | 128 KiB | LMB BRAM (ILMB and DLMB) |
| 0x4060_0000 | 64 KiB | AXI UART Lite (console) |
| 0x4120_0000 | 64 KiB | AXI INTC |
| 0x4140_0000 | 4 KiB | MDM (JTAG UART) |
| 0x41C0_0000 | 64 KiB | AXI Timer |
| 0x44A0_0000 | 1 MiB | `M_AXI_RTLNET` (RTLNet register window, decoded by the board top) |

Interrupt inputs: 0..7 = `irq[7:0]`, 8 = timer, 9 = UART. Vectors: reset 0x00, user exception 0x08,
interrupt 0x10, break 0x18, hardware exception 0x20. The single definition for software is
`driver/rtlnet_cpu_microblaze.h`; `microblaze/firmware/src/rtlnet_platform.h` includes it and adds the
RTLNet window map. The INTC base is not listed in architecture section 6.1 (see section 9).

Names other flows depend on: the MMI written by `write_mem_info` names the processor
`u_cpu/u_bd/rtlnet_cpu_i/microblaze_0` (board instance `u_cpu`), the path `updatemem -proc` takes.

## 5. Firmware toolchain contract

`mb-gcc` (GCC 13.3, `C:\Xilinx\2025.2\gnu\microblaze\nt\bin`) with flags that match the configuration:
`-mcpu=v11.0 -mlittle-endian -mxl-barrel-shift -mxl-pattern-compare -mno-xl-soft-mul -mno-xl-soft-div`
(no `-mhard-float`: no FPU). Multilib `le/bs/p/m` (libgcc for 64-bit division helpers). Freestanding,
own start-up and linker script: see `microblaze/firmware`.

## 6. Replacing the processor (Nios V, another RISC-V)

The board top instances `u_cpu` with exactly the section 15.6 ports. A replacement is a new core
`cores/rtlnet_cpu_<name>/` whose `hdl/rtlnet_cpu_<name>.sv` has the same module ports and wraps the
vendor system:

1. Platform Designer (or the vendor's equivalent) system with the processor, on-chip RAM, a UART (or
   JTAG UART), a timer, an interrupt controller and an AXI4-Lite (or Avalon-MM bridged to AXI4-Lite)
   master covering 0x44A0_0000 + 1 MiB at the same processor address.
2. Clock and reset from the ports (no PLL inside); the receive pin synchronized inside.
3. The board top selects the module by name (the `ifdef` that today selects the BFM shows the pattern);
   the decoder, the system registers and every core below the decoder are unchanged.
4. Software: a `driver/rtlnet_cpu_<name>.h` with the same macro names (`RTLNET_CPU_UART_BASE` ...),
   a UART and timer driver for that vendor's peripherals behind the same platform API
   (`plat_console_write`, `plat_uptime_ms`, ...), the processor's start-up and linker script. The CLI,
   the board layer and every RTLNet core driver compile unchanged, because they reach hardware only
   through `rtlnet_platform.h` and `rtlnet_mmio.h`.

## 7. Bus-functional model

`testbench/rtlnet_cpu_bfm.sv` (module `rtlnet_cpu_bfm`, same ports) replaces the core when a bench
defines `RTLNET_CPU_BFM`; the board top then instances it as `u_cpu`. Tasks (called hierarchically,
`dut.u_cpu.<task>`): `wait_reset_release`, `axil_write(addr, data, strb, resp)`,
`axil_read(addr, data, resp)` (timeouts return resp 2'b10 and count `axil_timeouts`),
`uart_send(byte)` on `uart_txd`, a receiver on `uart_rxd` into `uart_rx_q` (`uart_get`,
`uart_rx_errors`), `wait_irq(mask, timeout, ok)`.

## 8. Verification and results

| Check | Result (10-22-2026) |
|---|---|
| Block design creation, validation, output products, wrapper (Vivado 2025.2) | no errors, 0 critical warnings |
| Board bench `tb_rtlnet_nexys_video_top` (BFM AXI4-Lite and UART tasks against the real top) | TEST PASS, 74 checks; `+INJECT_FAILURE` gives TEST FAIL; a perturbed clock expectation gives TEST FAIL |
| CPU-only board build, post-route | WNS +1.698 ns, WHS +0.081 ns, no failing endpoints (commit f34a8bac) |
| Hardware: firmware merged with updatemem, JTAG programmed, CLI over the USB-UART | `cli_test.ps1` 15/15 (board report: `boards/nexys_video/documentation/rtlnet_nexys_video.md`) |

Utilization (post-route, `u_cpu`, xc7a200t): 2450 LUTs (64 LUTRAM, 92 SRL), 2097 FFs, 32 RAMB36,
3 DSP48. MicroBlaze alone 1538 LUTs, 1237 FFs, 3 DSP48.

## 9. Limitations and open points

- Interrupts are wired (INTC, vector at 0x10) but the firmware runs polled; no interrupt handler beyond
  the counting stub is installed.
- `cpu_reset_out_n` of architecture section 10 is not a port (section 15.6 is binding); the architecture
  document should drop it from section 10 or add it to 15.6.
- The INTC (0x4120_0000) is missing from the architecture's processor-side address list (section 6.1).
- The MDM's BSCAN clocks are constrained by the vendor IP itself (asynchronous clock groups inside the IP
  XDC); the build waives the related methodology check TIMING-9 only while `report_cdc` shows no
  Critical/Warning finding.

## 10. Revision history

| Revision | Change |
|---|---|
| 10-22-2026 | Initial version: block design script, wrapper, driver header, BFM |
