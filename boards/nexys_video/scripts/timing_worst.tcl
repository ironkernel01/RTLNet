# -----------------------------------------------------------------------------
# File: timing_worst.tcl
# Purpose: the ten worst routed setup paths of a checkpoint with their logic levels and module, and the 400 worst endpoints grouped by module.
# Usage: scripts/rtlnet_vivado.ps1 -Tcl boards/nexys_video/scripts/timing_worst.tcl -Log <log> -TclArgs <post_route.dcp> <output file>
# Output: the output file holds "ten worst" (one line per endpoint: slack, levels, start, end) and "groups" (module of the endpoint, number of
#   endpoints of the 400 worst, worst slack, maximum levels). The module is the first two hierarchy levels of the endpoint cell
#   (u_arb, u_h264/g_engine[0].u_engine, u_cpu/u_bd and so on).
# Revision: 11-12-2026
#   * 11-12-2026: initial version.
# -----------------------------------------------------------------------------
set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set paths [get_timing_paths -max_paths 400 -nworst 1 -setup]
set fh [open $out w]
puts $fh "# checkpoint $dcp"
puts $fh "# ten worst endpoints: slack_ns levels startpoint -> endpoint"
set n 0
array set grp_n {}
array set grp_s {}
array set grp_l {}
foreach p $paths {
  set sl [get_property SLACK $p]
  set lv [get_property LOGIC_LEVELS $p]
  set sp [get_property STARTPOINT_PIN $p]
  set ep [get_property ENDPOINT_PIN $p]
  if {$n < 10} { puts $fh [format "%7.3f %2d %s -> %s" $sl $lv $sp $ep] }
  incr n
  set parts [split $ep "/"]
  set m [lindex $parts 0]
  if {[llength $parts] > 2} { set m "[lindex $parts 0]/[lindex $parts 1]" }
  regsub -all {\[[0-9]+\]} $m {[*]} m
  if {![info exists grp_n($m)]} { set grp_n($m) 0; set grp_s($m) $sl; set grp_l($m) 0 }
  incr grp_n($m)
  if {$sl < $grp_s($m)} { set grp_s($m) $sl }
  if {$lv > $grp_l($m)} { set grp_l($m) $lv }
}
puts $fh "# groups of the $n worst endpoints by module: endpoints worst_slack_ns max_levels module"
set lst {}
foreach m [array names grp_n] { lappend lst [list $grp_s($m) $m] }
foreach e [lsort -real -index 0 $lst] {
  set m [lindex $e 1]
  puts $fh [format "%4d %7.3f %2d %s" $grp_n($m) $grp_s($m) $grp_l($m) $m]
}
close $fh
puts "timing_worst: wrote $out ($n endpoints)"
exit 0
