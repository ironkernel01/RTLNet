# timing_coverage.tcl -- constraint coverage check of a routed checkpoint
#
# Role: lists every clock with the number of its timed register endpoints, every clock pair of the clock interaction table with its
#   constraint class and the number of timed endpoints, every timing exception (set_false_path, set_max_delay, set_clock_groups, ...)
#   with the number of paths it matches, and the check_timing summary, so that a clock or a constrained crossing that analyses zero paths
#   shows. Opens the checkpoint read-only in batch mode; writes the report named in the second argument.
# Usage: vivado -mode batch -source timing_coverage.tcl -tclargs <post_route.dcp> <report.txt>
# Revision: 11-11-2026

set dcp [lindex $argv 0]
set out [lindex $argv 1]
open_checkpoint $dcp
set f [open $out w]

puts $f "== clocks: register endpoints timed per clock"
foreach c [lsort [get_clocks]] {
    set name [get_property NAME $c]
    set regs [all_registers -clock $c -edge_triggered]
    set n [llength $regs]
    set p [llength [get_timing_paths -setup -to $c -max_paths 1 -quiet]]
    puts $f [format "clock %-60s period %8s  registers %7d  setup path found %d" $name [get_property PERIOD $c] $n $p]
}

puts $f ""
puts $f "== clock interaction table (report_clock_interaction): rows with the endpoint counts"
set ci [report_clock_interaction -delay_type min_max -return_string]
puts $f $ci

puts $f ""
puts $f "== timing exceptions and the paths they match (report_exceptions)"
catch {
    set ex [report_exceptions -return_string]
    puts $f $ex
}
puts $f ""
puts $f "== exceptions that are ignored"
catch {
    set ex [report_exceptions -ignored -return_string]
    puts $f $ex
}

puts $f ""
puts $f "== check_timing"
puts $f [check_timing -verbose -return_string]
puts $f ""
puts $f "== worst setup path"
puts $f [report_timing -setup -max_paths 1 -return_string]
puts $f ""
puts $f "== worst hold path"
puts $f [report_timing -hold -max_paths 1 -return_string]
puts $f ""
puts $f "== timing summary"
puts $f [report_timing_summary -max_paths 1 -return_string]
close $f
close_design
