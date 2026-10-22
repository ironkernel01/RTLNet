# RTLNet

FPGA design repository: Verilog/SystemVerilog RTL, testbenches, constraints, IP, and Vivado projects.

## Layout

```
rtl/          Synthesizable RTL (.v, .sv, .vh)
tb/           Testbenches and simulation models
constraints/  Pin and timing constraints (.xdc)
ip/           Vivado IP configurations (.xci only; outputs are regenerated)
bd/           Block designs (.bd) and their export Tcl
vivado/       Vivado projects (.xpr) and project-recreate Tcl scripts
scripts/      Build, sim, and programming scripts (.tcl, .bat, .sh, .py)
sim/          Simulator setup files (wave configs, do/tcl scripts)
docs/         Specifications, block diagrams, notes
releases/     Tagged bitstreams (.bit/.bin) kept under version control
```

Larger designs can mirror this layout in a subfolder per design (e.g. `designs/<name>/rtl`, `designs/<name>/tb`).

## What gets committed

- Committed: HDL sources, testbenches, `.xdc`, `.xci`, `.bd`, `.xpr`, Tcl scripts.
- Ignored: Vivado generated directories (`*.cache`, `*.runs`, `*.sim`, `*.gen`, `*.hw`, `*.ip_user_files`, `.Xil`), logs and journals, and build outputs (`*.bit`, `*.dcp`, reports) outside `releases/`.

To make a project reproducible without the `.xpr`, export a recreate script from the Vivado Tcl console:

```tcl
write_project_tcl -force -no_copy_sources vivado/<project>_recreate.tcl
```
