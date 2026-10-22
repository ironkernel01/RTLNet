# -----------------------------------------------------------------------------
# File: rtlnet_synth_check.tcl
# Purpose: out-of-context Vivado synthesis of one RTLNet module from a filelist,
#   to prove the sources are accepted by synthesis (XPM parameters, attributes,
#   elaboration $fatal checks) and to report utilization. No implementation.
# Usage: vivado -mode batch -nojournal -log <log> -source scripts/rtlnet_synth_check.tcl
#          -tclargs <top> <filelist> [part] [generic=value ...]
# Exit codes: 0 pass, 10 synthesis error or critical warning, 99 bad arguments.
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------
if {[llength $argv] < 2} { puts "usage: <top> <filelist> \[part\] \[generic=value ...\]"; exit 99 }
set repo [file normalize [file join [file dirname [info script]] ".."]]
set top  [lindex $argv 0]
set fl   [lindex $argv 1]
set part [expr {[llength $argv] > 2 ? [lindex $argv 2] : "xc7a200tsbg484-1"}]
set generics [lrange $argv 3 end]

proc read_filelist {repo path} {
  set f [open [file join $repo $path] r]
  foreach raw [split [read $f] "\n"] {
    set line [string trim [regsub {(#|//).*$} $raw ""]]
    if {$line eq ""} continue
    if {[regexp {^-f\s+(.+)$} $line -> sub]} { read_filelist $repo [string trim $sub]; continue }
    if {[regexp {^\+incdir\+(.+)$} $line -> d]} { lappend ::incdirs [file join $repo $d]; continue }
    if {[regexp {^\+define\+} $line]} continue
    set src [file normalize [file join $repo $line]]
    if {[lsearch -exact $::read_files $src] >= 0} continue
    lappend ::read_files $src
    read_verilog -sv $src
  }
  close $f
}
set ::incdirs {}
set ::read_files {}
read_filelist $repo $fl
# Generics as name=value, or as "name value" pairs (cmd.exe splits batch
# arguments at '=' when Vivado is launched through vivado.bat).
set gargs {}
for {set i 0} {$i < [llength $generics]} {incr i} {
  set g [lindex $generics $i]
  if {[string first "=" $g] < 0} { incr i; set g "$g=[lindex $generics $i]" }
  lappend gargs -generic $g
}
if {[catch {synth_design -top $top -part $part -mode out_of_context -include_dirs $::incdirs {*}$gargs} err]} {
  puts "rtlnet_synth_check: FAIL synth_design: $err"; exit 10
}
set crit [get_msg_config -count -severity {CRITICAL WARNING}]
report_utilization -file [file join [pwd] "${top}_utilization.rpt"]
puts "rtlnet_synth_check: critical warnings $crit"
if {$crit > 0} { puts "rtlnet_synth_check: FAIL critical warnings"; exit 10 }
puts "rtlnet_synth_check: PASS $top"
exit 0
