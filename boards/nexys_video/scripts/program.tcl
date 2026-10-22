# -----------------------------------------------------------------------------
# File: program.tcl
# Purpose: program the Nexys Video XC7A200T over its on-board USB-JTAG with
#   the Vivado Hardware Manager (local hw_server), and report the result.
# Overview:
#   * connect_hw_server (starts a local hw_server if none runs), open the first
#     JTAG target, pick the device matching xc7a200t*, set PROGRAM.FILE,
#     program_hw_devices, refresh, then read the DONE status.
#   * Exit codes: 0 programmed and DONE high; 1 no hw_server / no target /
#     no device; 2 bad arguments or missing file; 3 programming failed or DONE
#     low.
#   * Every output line starts with "rtlnet_program:".
# Usage: vivado -mode batch -source program.tcl -tclargs <bitfile>
#   Normally through boards/nexys_video/scripts/program.ps1.
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------
if {[llength $argv] < 1} { puts "rtlnet_program: usage: -tclargs <bitfile>"; exit 2 }
set bit [file normalize [join $argv " "]]
if {![file exists $bit]} { puts "rtlnet_program: ERROR bitstream not found: $bit"; exit 2 }
puts "rtlnet_program: bitstream $bit ([file size $bit] bytes)"

open_hw_manager
if {[catch {connect_hw_server} err]} {
  puts "rtlnet_program: ERROR cannot reach the hw_server: $err"
  exit 1
}
puts "rtlnet_program: hw_server [current_hw_server]"
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
  puts "rtlnet_program: ERROR the hw_server has no JTAG target (cable unplugged or board off)"
  exit 1
}
puts "rtlnet_program: target [lindex $targets 0]"
current_hw_target [lindex $targets 0]
if {[catch {open_hw_target} err]} {
  puts "rtlnet_program: ERROR open_hw_target: $err"
  exit 1
}
set dev [lindex [get_hw_devices -quiet xc7a200t*] 0]
if {$dev eq ""} {
  puts "rtlnet_program: ERROR no xc7a200t device in the chain: [get_hw_devices -quiet]"
  exit 1
}
current_hw_device $dev
set dev_name [get_property NAME $dev]
puts "rtlnet_program: device $dev_name part [get_property PART $dev]"
set_property PROGRAM.FILE $bit $dev
catch {set_property PROBES.FILE {} $dev}
catch {set_property FULL_PROBES.FILE {} $dev}
set t0 [clock milliseconds]
if {[catch {program_hw_devices $dev} err]} {
  puts "rtlnet_program: ERROR program_hw_devices: $err"
  exit 3
}
refresh_hw_device -quiet $dev
set done [get_property -quiet REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]
puts "rtlnet_program: programmed in [expr {([clock milliseconds] - $t0) / 1000.0}] s, DONE pin '$done'"
if {$done ne "1"} {
  puts "rtlnet_program: ERROR DONE pin not high after programming"
  exit 3
}
close_hw_target
disconnect_hw_server
puts "rtlnet_program: PASS $dev_name"
exit 0
