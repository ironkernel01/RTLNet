# -----------------------------------------------------------------------------
# File: arb_synth.tcl
# Purpose: out-of-context Vivado synthesis of rtlnet_axi_arbiter for xc7a200tsbg484-1 with the parameters of the Nexys Video board top
#   (4 masters, 29-bit address, 128-bit data, ID_W 2, HIGH_PRIO_MASK 0010, NARROW_MASK 0001, WRAP_MASK 0001, MAX_OUTSTANDING 8, AXIL_SYNC 1),
#   clk constrained to 90 MHz (11.111 ns, the board's common clock), every input with a 0 ns input delay and every output with a 0 ns output delay
#   against clk, so the paths from the masters into the grant logic and from the grant logic to the memory controller are timed. Reports the
#   utilization, the worst paths with their logic levels and the logic level distribution (post-synthesis estimate, no placement).
# Usage: scripts/rtlnet_vivado.ps1 -Tcl cores/rtlnet_axi_arbiter/testbench/arb_synth.tcl -Log .sim/synth/arb_<tag>.log
#          -TclArgs <tag> [ADDR_REG] [arbiter source override] [period_ns]        (defaults: new, 1, the repository file, 11.111)
#   The arbiter source override lets a run use another copy of rtlnet_axi_arbiter.sv (the version before a change); ADDR_REG is ignored (not passed)
#   when it is "-" (a source without the parameter).
# Outputs (in the log's directory): arb_<tag>_utilization.rpt, arb_<tag>_paths.rpt (200 worst endpoints), arb_<tag>_levels.rpt.
# Exit codes: 0 done, 10 synthesis error.
# Revision: 11-12-2026
#   * 11-12-2026: initial version.
# -----------------------------------------------------------------------------
set repo [file normalize [file join [file dirname [info script]] ".." ".." ".."]]
set tag    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "new"}]
set addrreg [expr {[llength $argv] > 1 ? [lindex $argv 1] : 1}]
set src    [expr {[llength $argv] > 2 && [lindex $argv 2] ne "" ? [lindex $argv 2] : [file join $repo cores/rtlnet_axi_arbiter/hdl/rtlnet_axi_arbiter.sv]}]
set period [expr {[llength $argv] > 3 ? [lindex $argv 3] : 11.111}]
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
    set s [file normalize [file join $repo $line]]
    if {[lsearch -exact $::read_files $s] >= 0} continue
    lappend ::read_files $s
    if {[string match *rtlnet_axi_arbiter.sv $s]} { read_verilog -sv $::arb_src } else { read_verilog -sv $s }
  }
  close $f
}
set ::arb_src $src
read_filelist $repo cores/rtlnet_axi_arbiter/hdl/rtlnet_axi_arbiter.f
set gen [list -generic AXIL_SYNC=1'b1 -generic NUM_MASTERS=4 -generic ADDR_W=29 -generic DATA_W=128 -generic ID_W=2 \
  -generic HIGH_PRIO_MASK=4'b0010 -generic NARROW_MASK=4'b0001 -generic WRAP_MASK=4'b0001 -generic MAX_OUTSTANDING=8]
if {$addrreg ne "-"} { lappend gen -generic ADDR_REG=1'b$addrreg }
if {[catch {synth_design -top rtlnet_axi_arbiter -part xc7a200tsbg484-1 -mode out_of_context -include_dirs $::incdirs {*}$gen} err]} {
  puts "arb_synth: FAIL synth_design: $err"; exit 10
}
create_clock -name clk -period $period [get_ports clk]
create_clock -name s_axi_aclk -period $period [get_ports s_axi_aclk]
set_clock_groups -asynchronous -group [get_clocks clk] -group [get_clocks s_axi_aclk]
set_input_delay -clock clk 0 [get_ports -filter {NAME != clk && NAME != s_axi_aclk && NAME !~ s_axi_a*} [all_inputs]]
set_output_delay -clock clk 0 [get_ports -filter {NAME !~ s_axi_*} [all_outputs]]
report_utilization -file [file join [pwd] "arb_${tag}_utilization.rpt"]
report_utilization
report_timing -delay_type max -nworst 1 -max_paths 200 -file [file join [pwd] "arb_${tag}_paths.rpt"]
report_design_analysis -logic_level_distribution -logic_level_dist_paths 500 -file [file join [pwd] "arb_${tag}_levels.rpt"]
set paths [get_timing_paths -max_paths 40 -nworst 1 -setup]
set maxlev 0
foreach p $paths { set l [get_property LOGIC_LEVELS $p]; if {$l > $maxlev} { set maxlev $l } }
set p [lindex $paths 0]
puts "arb_synth: tag $tag ADDR_REG $addrreg period $period ns, WNS [get_property SLACK $p] ns, worst path levels [get_property LOGIC_LEVELS $p], max levels over the 40 worst endpoints $maxlev"
puts "arb_synth: worst path [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
foreach p [lrange $paths 0 14] { puts [format "arb_synth: slack %7.3f levels %2d %s -> %s" [get_property SLACK $p] [get_property LOGIC_LEVELS $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]] }
exit 0
