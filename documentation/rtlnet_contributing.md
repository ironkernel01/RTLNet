# RTLNet — Rules for building a core

| Item | Value |
|---|---|
| Document revision | 10-22-2026 |
| Applies to | every file under `cores/`, `boards/`, `firmware/`, `scripts/` |

Read `documentation/rtlnet_architecture.md` first (bus, register conventions, address map, leaf contract,
section 15 port lists). This page lists the rules a core must follow to be accepted.

## 1. Non-negotiable rules

1. **No other company is named anywhere** — sources, comments, documents, file and module names, commit
   messages. Prior designs used as references are not cited by path or name. Silicon and tool vendors are named
   only for the part or tool meant (AMD/Xilinx, Intel/Altera, Lattice, Realtek RTL8211E, Digilent Nexys Video).
   Before every commit `scripts/rtlnet_name_check.ps1` must report `RTLNET_NAMES: PASS` (its pattern list is kept
   outside the repository, in `%LOCALAPPDATA%/RTLNet/forbidden_names.txt`, so the names never enter RTLNet files).
2. **SystemVerilog-2012 only** (`.sv`, `.svh`), synthesizable subset for RTL: `logic`, `always_ff`, `always_comb`,
   `assign`, packages, `localparam`, functions. No interfaces or classes in synthesizable ports.
3. **Folder structure**: `cores/<core>/{hdl,driver,testbench,documentation}` — nothing else at core level.
4. **Technology**: never put a vendor primitive, vendor macro or vendor-only attribute in a generic core. Use
   `rtlnet_ram_core` for every memory, `rtlnet_sync`/`rtlnet_pulse_sync`/`rtlnet_gray_sync`/`rtlnet_axil_cdc`/
   `rtlnet_packet_fifo` for every crossing, `rtlnet_reset_sync` for every reset release. Technology comes from
   `rtlnet_technology.svh` only; no `TARGET` parameter exists.
5. **Memories**: every buffer has a `*_KB` total-size parameter and a `RAM_STYLE` parameter (`"block"` default,
   `"distributed"`); derive depths from them and `$fatal` (in a generate branch, so synthesis fails too) on a size
   that cannot be built.
6. **Buses**: data is the RTLNet stream (64-bit AXI4-Stream, architecture section 4); control is AXI4-Lite through
   `rtlnet_axil_slave` (architecture section 5, standard ID/VERSION/CAPS header).
7. **Commit regularly**: one commit per coherent step (RTL, bench passing, driver, doc). Commit messages end with
   the `Co-Authored-By` line the session supplies.

## 2. RTL style (from the FPGA coding guide in force)

- Header block on every file: purpose, overview of behaviours, language, revision as a `MM-DD-YYYY` date code with
  a change list, clocks. Comments state current function in present tense.
- Ports in commented groups (clock domain, protocol, polarity, width contract), clocks and resets first.
- Synchronous, active-low resets (`resetn`, `aresetn`); the only asynchronous-assert process is inside
  `rtlnet_reset_sync`.
- Clocked blocks `always_ff` with `<=` only; combinational logic in `assign` or `always_comb` with defaults first.
- One registered state variable per FSM, `S_*` localparams, single clocked process, `default` recovers.
- No latches, no combinational loops, no internal tri-states, no logic-generated clocks.
- 2-space indent, no tabs, lines up to 130 columns, one declaration per line, no commented-out code, no magic
  numbers (named localparams or `rtlnet_pkg` constants).
- Precede every process and instance with a comment saying what it does in context.
- FIFO and RAM overflow made impossible structurally and made visible by a simulation-only check
  (`// synthesis translate_off` ... `translate_on`).
- Instance names that constraints depend on (`u_*_fifo`, `u_rgmii_io`, synchronizer instances) are stable.

## 3. Registers

- Offsets and bit positions are defined once, in the core's driver header `<core>.h`; the register file carries
  `localparam`s with a comment naming the header. Keep both in step in the same commit.
- Standard header at 0x000 `ID` (four ASCII characters via `rtlnet_pkg::id4`), 0x004 `VERSION` (`0xMMDDYYYY`),
  0x008 `CAPS`. Read mux registered. Counters 32-bit with a `CNT_CLEAR` pulse.

## 4. Drivers (C11, embedded C guide in force)

- `cores/<core>/driver/<core>.h` and `<core>.c`: the only code that touches the core's registers. Public functions
  `<core>_*` lower_snake_case, `static` file state with `g_` prefix, constants `ALL_CAPS` with a domain prefix and
  `u` suffixes, fixed-width types, `const` pointer parameters, 4-space indent, function comments
  `name -- summary`, `Steps:`, `Returns:`.
- Register access only through `rtlnet_mmio.h` (`rtlnet_reg_read32(base, off)`, `rtlnet_reg_write32(base, off, v)`)
  from `cores/rtlnet_common/driver/`; the base address is passed in, never hard-coded in a driver.
- Loops that wait on hardware are bounded by named constants and return an error on timeout.
- Drivers must compile warning-free with `mb-gcc -std=c11 -Wall -Wextra -Werror` and with host `gcc` for unit tests.

## 5. Testbenches (Aldec Active-HDL 11.1)

- One self-checking bench per core at least, `cores/<core>/testbench/tb_<core>.sv`, with a filelist `tb_<core>.f`
  (paths relative to the repository root; nested `-f cores/rtlnet_common/hdl/rtlnet_common.f` and
  `-f cores/rtlnet_common/testbench/rtlnet_tb_common.f`).
- Use `rtlnet_tb_pkg` (`tb_check`, `tb_error`, `tb_verdict`), the AXI-Stream source/sink, the AXI4-Lite master and,
  for protocol leaves, `rtlnet_tb_leaf_busy_monitor`. Oracles must be independent of the RTL (bench-built frames,
  `crc32_serial_fcs`, `inet_sum`).
- End with exactly one `tb_verdict("<bench>")`; add a watchdog that calls it on timeout.
- **Never use `foreach` in bench code** (Active-HDL 11.1 bug, see `cores/rtlnet_common/documentation`); use
  `for (int i = 0; i < $size(q); i++)`.
- Register every run in `cores/<core>/testbench/regression.txt`, including one `plusargs=INJECT_FAILURE expectfail`
  negative-control line.
- Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_run_sim.ps1 -Bench <tb> -Filelist <f>`.
  The runner serializes the single Active-HDL seat machine-wide; just call it. Do not start the Active-HDL GUI.
- Prove each new check can fail (perturb the bench once, see TEST FAIL, restore).

## 6. Synthesis check

`vivado -mode batch -nojournal -log <log> -source scripts/rtlnet_synth_check.tcl -tclargs <top> <filelist> xc7a200tsbg484-1 [NAME value ...]`
must report `rtlnet_synth_check: PASS` with 0 critical warnings for every new synthesizable top. Record the
utilization in the core documentation.

## 7. Documentation

`cores/<core>/documentation/<core>.md`: purpose, interface (port groups), parameters, register map (offsets, bits,
reset values, access), design (state machines, data path, latency), clocks/resets/crossings, verification
(benches, what each proves, recorded results with date and check count), synthesis results, limitations,
revision history.
