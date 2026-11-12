# -----------------------------------------------------------------------------
# File: h264_synth.tcl
# Purpose: out-of-context Vivado synthesis of rtlnet_h264_top for xc7a200tsbg484-1 with the default parameters
#   (MAX_MB_W 120, MAX_MB_H 68, NUM_ENGINES 2), enc_clk constrained to 90 MHz (11.111 ns, the board's enc_clk, a MMCM output; the engine masters cross to the 100 MHz
#   ui_clk through rtlnet_axi_cdc), to report critical warnings, utilization and the post-synthesis timing estimate (no placement: net delays
#   are estimates).
# Usage: scripts/rtlnet_vivado.ps1 -Tcl cores/rtlnet_h264_enc/testbench/h264_synth.tcl -Log .sim/synth/h264_top.log
#          -TclArgs [part] [enc_period_ns] [NUM_ENGINES] [HIGH_PROFILE]       (defaults: xc7a200tsbg484-1, 11.111, 2, 0)
#   HIGH_PROFILE 1 synthesizes the High profile seam with rtlnet_h264_hp as a black box (hp/rtlnet_h264_hp_bb.sv): the cost of the seam
#   in the entropy path, without the private netlist's own logic.
# Outputs (in the log's directory): rtlnet_h264_top_e<N>[_hp]_utilization.rpt, rtlnet_h264_top_e<N>[_hp]_timing.rpt.
# Exit codes: 0 pass (0 critical warnings and post-synthesis WNS >= 0), 10 synthesis error, critical warning or WNS < 0.
# Revision: 11-09-2026
#   * 11-09-2026: initial version; 100 MHz default, NUM_ENGINES argument, WNS < 0 fails.
#   * 11-09-2026: default period 11.111 ns (enc_clk 90 MHz of the Phase 2b-3 board).
#   * 11-11-2026: HIGH_PROFILE argument (black-boxed rtlnet_h264_hp).
#   * 11-12-2026: stage 3c: *_paths.rpt (the worst path of each endpoint with a slack below 3 ns, at most 400).
# -----------------------------------------------------------------------------
set repo [file normalize [file join [file dirname [info script]] ".." ".." ".."]]
set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7a200tsbg484-1"}]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 11.111}]
set engines [expr {[llength $argv] > 2 ? [lindex $argv 2] : 2}]
set hp [expr {[llength $argv] > 3 ? [lindex $argv 3] : 0}]
set tag [expr {$hp ? "e${engines}_hp" : "e${engines}"}]
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
if {$hp} {
  read_filelist $repo cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc_core.f
  read_verilog -sv [file join $repo cores/rtlnet_h264_enc/hdl/hp/rtlnet_h264_hp_bb.sv]
  # The black box stays unresolved here by design (the netlist is not part of this run): its critical warning is a warning.
  set_msg_config -id {Project 1-560} -new_severity WARNING
} else {
  read_filelist $repo cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc.f
}
if {[catch {synth_design -top rtlnet_h264_top -part $part -mode out_of_context -include_dirs $::incdirs -generic NUM_ENGINES=$engines -generic HIGH_PROFILE=$hp} err]} {
  puts "h264_synth: FAIL synth_design: $err"; exit 10
}
create_clock -name enc_clk -period $period [get_ports enc_clk]
create_clock -name s_axi_aclk -period 11.111 [get_ports s_axi_aclk]
set_clock_groups -asynchronous -group [get_clocks enc_clk] -group [get_clocks s_axi_aclk]
set crit [get_msg_config -count -severity {CRITICAL WARNING}]
report_utilization -file [file join [pwd] "rtlnet_h264_top_${tag}_utilization.rpt"]
report_utilization
report_timing_summary -delay_type max -max_paths 40 -file [file join [pwd] "rtlnet_h264_top_${tag}_timing.rpt"]
report_timing -delay_type max -nworst 1 -max_paths 400 -slack_lesser_than 3.0 -file [file join [pwd] "rtlnet_h264_top_${tag}_paths.rpt"]
set p [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]
set wns [get_property SLACK $p]
puts "h264_synth: NUM_ENGINES $engines, HIGH_PROFILE $hp, enc_clk period $period ns, post-synthesis WNS $wns ns (worst path [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p])"
puts "h264_synth: critical warnings $crit"
if {$crit > 0} { puts "h264_synth: FAIL critical warnings"; exit 10 }
if {$wns < 0} { puts "h264_synth: FAIL post-synthesis WNS $wns ns below 0"; exit 10 }
puts "h264_synth: PASS rtlnet_h264_top"
exit 0
