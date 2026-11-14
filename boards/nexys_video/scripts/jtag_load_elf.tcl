# -----------------------------------------------------------------------------
# File: jtag_load_elf.tcl
# Purpose: load an ELF into the MicroBlaze V memory over JTAG and run it
#   (xsdb script, Nexys Video). The ELF is the release image linked into the
#   512 KiB LMB (0x0) or the development image linked into DDR3 (0x8000_0000,
#   cpu/microblaze_v_h264/firmware/build.ps1 -Ddr); both go through the same sequence.
# Overview:
#   * hw_server lists the MicroBlaze V debug module as `RISC-V at USER2` with
#     the child `Hart #0`, not as `MicroBlaze #0`; the hart appears one to two
#     seconds after `connect` (the BSCAN-to-JTAG bridge of the mdm_riscv is
#     probed after the device), so a plain `targets` right after `connect`
#     shows only `BSCAN JTAG at USER2`. `targets -set -filter ... -timeout`
#     polls until the hart exists.
#   * Sequence: connect, select Hart #0, stop, print the PC and register a0,
#     write a sentinel word into free DDR3, rst -system -stop, wait for DDR3
#     calibration (CLK_STATUS bit 1 at 0x44A0_0020, bounded), dow <elf>, verify
#     the download (words at the start, middle and end of every loaded segment
#     read back with mrd and compared with the ELF file), set the PC to the ELF
#     entry, con, print the state.
#   * `rst -system` and the DDR3 controller: the system reset of the debug
#     module resets the processor and the AXI peripherals (proc_sys_reset), but
#     the controller's own reset input (sys_rstn) is the board reset, not the
#     debug reset, so the MIG is not reset and stays calibrated. The script
#     proves it on every run: the sentinel word written before the reset must
#     read back unchanged after it ("ddr3 survived reset" line; a mismatch is
#     reported as "ddr3 reset by rst -system" and is not an error), and the
#     calibration bit is polled anyway, so a variant whose reset reaches the
#     MIG still waits for the recalibration before `dow`.
#     The DDR3 arbiter (0x44A0_4000) is not reset either: the script clears its sticky error flag and counters
#     before `dow`, so `show ddr` of the new image starts clean.
#   * DDR3 images: the BSP start-up of the DDR3 image clears its .bss in DDR3,
#     which needs a calibrated controller; the release image booted from the
#     LMB has calibrated it before this script runs (the wait guarantees it).
#     The reset vector at 0x0 stays the release image; the DDR3 image starts
#     only through the `rwr pc` of this script.
#   * Every output line starts with "rtlnet_jtag:". Exit 0 with the last line
#     "rtlnet_jtag: PASS", 1 with "rtlnet_jtag: FAIL <reason>". Reasons:
#     connect, no hart, stop, reset, ddr3 calibration timeout, dow, verify
#     mismatch, not an ELF32, rwr pc, con.
# Usage: xsdb jtag_load_elf.tcl <elf> [calib_timeout_ms]
#   (normally through jtag_load_elf.ps1)
# Revision: 11-14-2026
#   * 11-14-2026: moved to cpu/microblaze_v_h264/ (was microblaze/).
#   * 11-09-2026: initial version.
#   * 11-09-2026: bounded wait for DDR3 calibration after the reset, download verification, reset/MIG finding.
# -----------------------------------------------------------------------------
proc fail {msg} { puts "rtlnet_jtag: FAIL $msg"; exit 1 }

set CLK_STATUS_ADDR 0x44A00020
set CALIB_BIT       0x2
set SENTINEL_ADDR   0x87F00000
set SENTINEL_VALUE  0xA5C3965A

if {[llength $argv] < 1} { fail "usage: xsdb jtag_load_elf.tcl <elf> \[calib_timeout_ms\]" }
set elf [file normalize [lindex $argv 0]]
set calib_timeout_ms 10000
if {[llength $argv] > 1} { set calib_timeout_ms [lindex $argv 1] }
if {![file exists $elf]} { fail "ELF not found: $elf" }
puts "rtlnet_jtag: elf $elf ([file size $elf] bytes)"

# Read one 32-bit word as an integer (mrd -value prints the value in decimal).
proc rd32 {addr} {
  return [expr {[string trim [mrd -value $addr]] + 0}]
}

# ELF32 little endian: header fields and PT_LOAD segments.
set fh [open $elf rb]
set data [read $fh]
close $fh
if {[string range $data 0 3] ne "\x7fELF" || [string index $data 4] ne "\x01"} { fail "not an ELF32 file: $elf" }
binary scan $data @24iu entry
binary scan $data @28iu phoff
binary scan $data @42su phentsize
binary scan $data @44su phnum
set segs {}
for {set i 0} {$i < $phnum} {incr i} {
  set o [expr {$phoff + $i * $phentsize}]
  binary scan $data @${o}iu ptype
  binary scan $data @[expr {$o + 4}]iu poffset
  binary scan $data @[expr {$o + 8}]iu pvaddr
  binary scan $data @[expr {$o + 16}]iu pfilesz
  if {$ptype == 1 && $pfilesz >= 4} { lappend segs [list $pvaddr $poffset $pfilesz] }
}
puts "rtlnet_jtag: entry [format 0x%x $entry], [llength $segs] loaded segment(s)"

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

# Sentinel in free DDR3 (127 MiB above the base, past any image): shows after
# the reset whether the controller was reset. Informational only.
set sentinel_set 0
if {[catch {
  mwr $SENTINEL_ADDR $SENTINEL_VALUE
  set sentinel_set [expr {[rd32 $SENTINEL_ADDR] == $SENTINEL_VALUE}]
} err]} { puts "rtlnet_jtag: sentinel not written: $err" }

# System reset with the hart held at the reset vector: the processor, the
# interrupt controller and the peripherals return to their reset state, so the
# firmware starts as after configuration (without it a running image traps in
# its interrupt handler on the stale peripheral state).
if {[catch {rst -system -stop} err]} { fail "rst -system -stop: $err" }
puts "rtlnet_jtag: reset, [state]"

# Wait for DDR3 calibration (CLK_STATUS bit 1), bounded; a failed read right
# after the reset (the AXI path still in reset) is retried until the timeout.
set t0 [clock milliseconds]
set calib 0
set first 1
while {1} {
  if {[catch {rd32 $CLK_STATUS_ADDR} st]} { set st -1 }
  if {$st >= 0 && ($st & $CALIB_BIT)} { set calib 1 }
  if {$first} {
    puts "rtlnet_jtag: CLK_STATUS right after reset [expr {$st >= 0 ? [format 0x%08x $st] : {unreadable}}]"
    set first 0
  }
  if {$calib} { break }
  if {[clock milliseconds] - $t0 > $calib_timeout_ms} { break }
  after 20
}
if {!$calib} { fail "ddr3 calibration timeout: CLK_STATUS bit 1 not set within ${calib_timeout_ms} ms" }
puts "rtlnet_jtag: ddr3 calibrated [expr {[clock milliseconds] - $t0}] ms after reset"
if {$sentinel_set} {
  if {[catch {rd32 $SENTINEL_ADDR} sv]} { set sv -1 }
  if {$sv == $SENTINEL_VALUE} {
    puts "rtlnet_jtag: ddr3 survived reset (sentinel at [format 0x%08x $SENTINEL_ADDR] intact: the MIG is not reset by rst -system)"
  } else {
    puts "rtlnet_jtag: ddr3 reset by rst -system (sentinel [expr {$sv >= 0 ? [format 0x%08x $sv] : {unreadable}}])"
  }
}

# The DDR3 arbiter (ID "ARBT" at 0x44A0_4000) is not reset by rst -system either: its sticky error flag and
# counters from the previous image would show in the next image's `show ddr`. Clear both (STATUS.ERR is
# write-1-to-clear, CTRL bit 16 clears the counters) when the core is present.
if {![catch {rd32 0x44A04000} aid] && $aid == 0x41524254} {
  catch {mwr 0x44A04010 1}
  catch {mwr 0x44A0400C 0x10000}
  puts "rtlnet_jtag: arbiter status and counters cleared"
}

if {[catch {dow $elf} err]} { fail "dow: $err" }

# Verify: first, middle and last word of every loaded segment against the file.
set nwords 0
foreach seg $segs {
  lassign $seg vaddr foff fsz
  set last [expr {($fsz & ~3) - 4}]
  foreach rel [lsort -unique -integer [list 0 [expr {(($fsz / 2) & ~3)}] $last]] {
    binary scan $data @[expr {$foff + $rel}]iu want
    set a [expr {$vaddr + $rel}]
    if {[catch {rd32 $a} got]} { fail "verify: cannot read [format 0x%08x $a]: $got" }
    if {$got != $want} {
      fail [format "verify mismatch at 0x%08x: memory 0x%08x, ELF 0x%08x" $a $got $want]
    }
    incr nwords
  }
}
puts "rtlnet_jtag: download verified ($nwords words in [llength $segs] segment(s))"

if {[catch {rwr pc $entry} err]} { fail "rwr pc: $err" }
puts "rtlnet_jtag: [rrd pc]"

if {[catch {con} err]} { fail "con: $err" }
after 500
puts "rtlnet_jtag: state [state]"
puts "rtlnet_jtag: PASS"
exit 0
