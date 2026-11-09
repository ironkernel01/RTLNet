# -----------------------------------------------------------------------------
# File: h264_synth.tcl
# Purpose: out-of-context Vivado synthesis of rtlnet_h264_top for xc7a200tsbg484-1 with the default parameters
#   (MAX_MB_W 120, MAX_MB_H 68, NUM_ENGINES 2), enc_clk constrained to 100 MHz (the MIG ui_clk the board runs the engines
#   on), to report critical warnings, utilization and the post-synthesis timing estimate (no placement: net delays
#   are estimates).
# Usage: scripts/rtlnet_vivado.ps1 -Tcl cores/rtlnet_h264_enc/testbench/h264_synth.tcl -Log .sim/synth/h264_top.log
#          -TclArgs [part] [enc_period_ns] [NUM_ENGINES]       (defaults: xc7a200tsbg484-1, 10.000, 2)
# Outputs (in the log's directory): rtlnet_h264_top_e<N>_utilization.rpt, rtlnet_h264_top_e<N>_timing.rpt.
# Exit codes: 0 pass (0 critical warnings and post-synthesis WNS >= 0), 10 synthesis error, critical warning or WNS < 0.
# Revision: 11-09-2026
#   * 11-09-2026: initial version; 100 MHz default, NUM_ENGINES argument, WNS < 0 fails.
# -----------------------------------------------------------------------------
set repo [file normalize [file join [file dirname [info script]] ".." ".." ".."]]
set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7a200tsbg484-1"}]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 10.000}]
set engines [expr {[llength $argv] > 2 ? [lindex $argv 2] : 2}]
set ::incdirs {}
set ::read_files {}

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
read_filelist $repo cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc.f
if {[catch {synth_design -top rtlnet_h264_top -part $part -mode out_of_context -include_dirs $::incdirs -generic NUM_ENGINES=$engines} err]} {
  puts "h264_synth: FAIL synth_design: $err"; exit 10
}
create_clock -name enc_clk -period $period [get_ports enc_clk]
create_clock -name s_axi_aclk -period 10.0 [get_ports s_axi_aclk]
set_clock_groups -asynchronous -group [get_clocks enc_clk] -group [get_clocks s_axi_aclk]
set crit [get_msg_config -count -severity {CRITICAL WARNING}]
report_utilization -file [file join [pwd] "rtlnet_h264_top_e${engines}_utilization.rpt"]
report_utilization
report_timing_summary -delay_type max -max_paths 40 -file [file join [pwd] "rtlnet_h264_top_e${engines}_timing.rpt"]
set p [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]
set wns [get_property SLACK $p]
puts "h264_synth: NUM_ENGINES $engines, enc_clk period $period ns, post-synthesis WNS $wns ns (worst path [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p])"
puts "h264_synth: critical warnings $crit"
if {$crit > 0} { puts "h264_synth: FAIL critical warnings"; exit 10 }
if {$wns < 0} { puts "h264_synth: FAIL post-synthesis WNS $wns ns below 0"; exit 10 }
puts "h264_synth: PASS rtlnet_h264_top"
exit 0
