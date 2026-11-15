# -----------------------------------------------------------------------------
# File: program.tcl
# Purpose: load the Zybo Z7-20 camera and H.264 design over JTAG with xsdb: programmable logic bitstream, PS initialization
#   from the XSA (ps7_init, ps7_post_config), ARM application in DDR, run. Volatile only: no QSPI, no SD card.
# Overview:
#   * connect (starts a local hw_server if none runs); the JTAG chain must hold an xc7z020 device and the Zynq ARM core
#     targets, otherwise the script refuses and touches nothing (another board on the PC is never programmed).
#   * Order: system reset, ps7_init (clocks, DDR, MIO), fpga -file <bit>, ps7_post_config (PS-PL level shifters, FCLK),
#     dow <elf> on Cortex-A9 #0, con.
#   * Uses Cortex-A9 core #0 only (selected by name); core #1 is never started, woken or loaded.
#   * Exit codes: 0 running; 1 no hw_server / no Zynq xc7z020; 2 bad arguments or missing file; 3 load failed.
#   * Every output line starts with "rtlnet_zybo_load:".
# Usage: xsdb program.tcl <bitfile> <ps7_init.tcl> <elf>   (normally through program.ps1)
# Revision: 11-15-2026
#   * 11-14-2026: initial version.
# -----------------------------------------------------------------------------
proc say {s} { puts "rtlnet_zybo_load: $s" }
if {[llength $argv] < 3} { say "usage: <bitfile> <ps7_init.tcl> <elf>"; exit 2 }
lassign $argv bit init elf
foreach f [list $bit $init $elf] {
  if {![file exists $f]} { say "ERROR missing file $f"; exit 2 }
}
say "bit $bit ([file size $bit] bytes)"
say "elf $elf ([file size $elf] bytes)"
if {[catch {connect} err]} { say "ERROR cannot reach the hw_server: $err"; exit 1 }
set tl [targets]
say "targets:\n$tl"
if {[catch {targets -set -nocase -filter {name =~ "xc7z020*"}} err]} {
  say "ERROR no xc7z020 device on the JTAG chain (refusing to program): $err"
  exit 1
}
if {[catch {targets -set -nocase -filter {name =~ "ARM*#0"}} err]} {
  say "ERROR no Cortex-A9 #0 target: $err"
  exit 1
}
if {[catch {
  rst -system
  after 500
  targets -set -nocase -filter {name =~ "ARM*#0"}
  source $init
  ps7_init
  say "ps7_init done"
  targets -set -nocase -filter {name =~ "xc7z020*"}
  fpga -file $bit
  say "fpga programmed"
  targets -set -nocase -filter {name =~ "ARM*#0"}
  ps7_post_config
  say "ps7_post_config done"
  dow $elf
  say "elf downloaded"
  con
} err]} { say "ERROR load failed: $err"; exit 3 }
# Core #0 is selected by name for download and run; core #1 is never selected for a write, started or woken, and is
# only read (state) for the log.
after 1500
# A power-on reset of the board (USB supply sag) wipes the PL configuration: the core still reports Running (BootROM).
if {[catch {targets -set -nocase -filter {name =~ "xc7z020*"}; set pl [fpga -state]}] || ![string match "*is configured*" $pl]} {
  say "ERROR the PL is not configured after the start (board power-on reset): $pl"
  exit 3
}
if {[catch {targets -set -nocase -filter {name =~ "ARM*#0"}} err] || [catch {state} st] || [string match "*error*" $st]} {
  say "ERROR core #0 state query failed (the PS was reset or lost): $err $st"
  exit 3
}
say "core #0 state: $st"
if {![string match "Running*" $st]} { say "ERROR core #0 is not running"; exit 3 }
catch {
  targets -set -nocase -filter {name =~ "ARM*#1"}
  say "core #1 state (untouched): [state]"
  targets -set -nocase -filter {name =~ "ARM*#0"}
}
say "PASS"
exit 0
