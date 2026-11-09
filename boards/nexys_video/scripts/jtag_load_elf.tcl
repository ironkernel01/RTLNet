# -----------------------------------------------------------------------------
# File: jtag_load_elf.tcl
# Purpose: load an ELF into the MicroBlaze V local memory over JTAG and run it
#   (xsdb script, Nexys Video).
# Overview:
#   * hw_server lists the MicroBlaze V debug module as `RISC-V at USER2` with
#     the child `Hart #0`, not as `MicroBlaze #0`; the hart appears one to two
#     seconds after `connect` (the BSCAN-to-JTAG bridge of the mdm_riscv is
#     probed after the device), so a plain `targets` right after `connect`
#     shows only `BSCAN JTAG at USER2`. `targets -set -filter ... -timeout`
#     polls until the hart exists.
#   * Sequence: connect, select Hart #0, stop, print the PC and register a0,
#     rst -system -stop, dow <elf> (the 512 KiB LMB at 0x0), set the PC to the
#     ELF entry, con, print the state.
#   * Every output line starts with "rtlnet_jtag:". Exit 0 with the last line
#     "rtlnet_jtag: PASS", 1 with "rtlnet_jtag: FAIL <reason>".
# Usage: xsdb jtag_load_elf.tcl <elf>   (normally through jtag_load_elf.ps1)
# Revision: 11-09-2026
#   * 11-09-2026: initial version.
# -----------------------------------------------------------------------------
proc fail {msg} { puts "rtlnet_jtag: FAIL $msg"; exit 1 }

if {[llength $argv] < 1} { fail "usage: xsdb jtag_load_elf.tcl <elf>" }
set elf [file normalize [join $argv " "]]
if {![file exists $elf]} { fail "ELF not found: $elf" }
puts "rtlnet_jtag: elf $elf ([file size $elf] bytes)"

if {[catch {connect} err]} { fail "connect: $err" }
if {[catch {targets -set -nocase -filter {name =~ "Hart*"} -timeout 15} err]} {
  fail "no RISC-V hart on the JTAG chain: $err"
}
puts "rtlnet_jtag: target [lindex [split [string trim [targets -filter {is_current == 1}]] \n] 0]"

# A hart that is already stopped answers `stop` with "Already stopped".
if {[catch {stop} err] && ![string match "*Already stopped*" $err]} { fail "stop: $err" }
puts "rtlnet_jtag: stopped [state]"
puts "rtlnet_jtag: [rrd pc]"
puts "rtlnet_jtag: [rrd a0]"

# System reset with the hart held at the reset vector: the processor, the
# interrupt controller and the peripherals return to their reset state, so the
# firmware starts as after configuration (without it a running image traps in
# its interrupt handler on the stale peripheral state).
if {[catch {rst -system -stop} err]} { fail "rst -system -stop: $err" }
puts "rtlnet_jtag: reset, [state]"

if {[catch {dow $elf} err]} { fail "dow: $err" }
# ELF32 little endian: e_entry is the 32-bit word at file offset 24.
set fh [open $elf rb]
set hdr [read $fh 28]
close $fh
if {[string range $hdr 0 3] ne "\x7fELF" || [string index $hdr 4] ne "\x01"} { fail "not an ELF32 file: $elf" }
binary scan [string range $hdr 24 27] iu entry
puts "rtlnet_jtag: entry [format 0x%x $entry]"
if {[catch {rwr pc $entry} err]} { fail "rwr pc: $err" }
puts "rtlnet_jtag: [rrd pc]"

if {[catch {con} err]} { fail "con: $err" }
after 500
puts "rtlnet_jtag: state [state]"
puts "rtlnet_jtag: PASS"
exit 0
