# -----------------------------------------------------------------------------
# File: rtlnet_tcp_offload_timing.tcl
# Purpose: timing gate of rtlnet_tcp_offload: out-of-context synthesis and
#   implementation with a stream-clock constraint, zero failing setup/hold
#   endpoints, and a LUT-level census of every clk endpoint's worst path.
# Overview:
#   * Reads the filelist, synthesizes rtlnet_tcp_offload out of context with the
#     given generics, constrains clk to <period_ns> and s_axi_aclk to 10 ns,
#     bounds the crossings with scripts/rtlnet_constrain_cdc.tcl (classes sync,
#     axil_cdc, fifo), then opt / place / phys_opt / route.
#   * Gates: WNS >= 0 and WHS >= 0 with zero failing endpoints; every clk
#     intra-clock endpoint's worst path has at most MAX_LUT_LEVELS LUT levels
#     (LUT1..LUT6 and MUXF7/MUXF8/MUXF9 counted as LUT levels, CARRY4/CARRY8
#     counted separately; paths entirely inside the shared rtlnet_common AXI4-Lite
#     crossing and slave, or ending inside the shared rtlnet_common packet FIFO, are
#     reported separately and not gated).
#   * Writes <tag>_timing.rpt, <tag>_util.rpt, <tag>_levels.rpt,
#     <tag>_lutlevels.rpt in the working directory and prints
#     `rtlnet_timing: PASS|FAIL <tag> ...`.
# Usage: vivado -mode batch -source rtlnet_tcp_offload_timing.tcl -tclargs
#          <filelist> <part> <period_ns> <tag> [generic=value ...]
#   A <tag> starting with "synth_" stops after synthesis (quick census only).
# Exit codes: 0 pass, 10 synthesis, 20 timing, 21 logic levels, 25 implementation,
#   99 bad arguments.
# Revision: 10-22-2026
#   * 10-22-2026: initial version (from the rtlnet_classifier gate).
# -----------------------------------------------------------------------------
if {[llength $argv] < 4} { puts "usage: <filelist> <part> <period_ns> <tag> \[generic=value ...\]"; exit 99 }
set repo     [file normalize [file join [file dirname [info script]] ".." ".." ".."]]
set fl       [lindex $argv 0]
set part     [lindex $argv 1]
set period   [lindex $argv 2]
set tag      [lindex $argv 3]
set generics [lrange $argv 4 end]
set MAX_LUT_LEVELS 2

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
set gargs {}
for {set i 0} {$i < [llength $generics]} {incr i} {
  set g [lindex $generics $i]
  if {[string first "=" $g] < 0} { incr i; set g "$g=[lindex $generics $i]" }
  lappend gargs -generic $g
}
if {[catch {synth_design -top rtlnet_tcp_offload -part $part -mode out_of_context -include_dirs $::incdirs {*}$gargs} err]} {
  puts "rtlnet_timing: FAIL $tag synth_design: $err"; exit 10
}
set crit [get_msg_config -count -severity {CRITICAL WARNING}]
if {$crit > 0} { puts "rtlnet_timing: FAIL $tag $crit critical warnings in synthesis"; exit 10 }

# Clocks: clk (CPU stream clock) at the gate frequency, s_axi_aclk 100 MHz, unrelated.
create_clock -name clk        -period $period [get_ports clk]
create_clock -name s_axi_aclk -period 10.000  [get_ports s_axi_aclk]
set ::rtlnet_cdc_required {sync axil_cdc fifo}
set ::rtlnet_cdc_expect   {axil_cdc 1 fifo 1}
source [file join $repo scripts rtlnet_constrain_cdc.tcl]
report_utilization -file "${tag}_util_synth.rpt"

# A tag starting with "synth_" stops after synthesis (quick LUT-level census
# on the synthesized netlist; timing then is an estimate, not a gate).
if {![string match "synth_*" $tag]} {
  if {[catch {
    opt_design
    place_design
    phys_opt_design
    route_design
    phys_opt_design
  } err]} { puts "rtlnet_timing: FAIL $tag implementation: $err"; exit 25 }
}

write_checkpoint -force "${tag}_routed.dcp"
report_timing_summary -max_paths 20 -file "${tag}_timing.rpt"
report_utilization -file "${tag}_util.rpt"
report_design_analysis -logic_level_distribution -of_timing_paths \
  [get_timing_paths -group clk -max_paths 20000 -nworst 1] -file "${tag}_levels.rpt"

# Setup / hold gates.
set wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1] 0]]
set nsetup [llength [get_timing_paths -delay_type max -max_paths 100000 -nworst 1 -slack_lesser_than 0]]
set nhold  [llength [get_timing_paths -delay_type min -max_paths 100000 -nworst 1 -slack_lesser_than 0]]

# LUT-level census over the worst path of every clk endpoint.
set paths [get_timing_paths -from [get_clocks clk] -to [get_clocks clk] -max_paths 200000 -nworst 1]
array set hist {}
array set deep {}
set maxlut 0
set maxcommon 0
set worst {}
foreach p $paths {
  set luts 0
  set carry 0
  foreach c [get_cells -quiet -of_objects $p] {
    set ref [get_property REF_NAME $c]
    if {[regexp {^(LUT[1-6]|MUXF[789])$} $ref]} { incr luts }
    if {[regexp {^CARRY} $ref]} { incr carry }
  }
  # Paths that start and end inside the shared rtlnet_common AXI4-Lite
  # crossing / slave (u_regs/u_axil_*) or ending inside the shared packet FIFO (u_tx/u_tx_fifo) are counted apart: that code is not
  # part of this core.
  set spc [get_property PARENT_CELL [get_property STARTPOINT_PIN $p]]
  set epc [get_property PARENT_CELL [get_property ENDPOINT_PIN $p]]
  set common [expr {([string match "u_regs/u_axil_*" $spc] && [string match "u_regs/u_axil_*" $epc]) || [string match "u_tx/u_tx_fifo/*" $epc]}]
  if {$common} {
    if {$luts > $maxcommon} { set maxcommon $luts }
  } else {
    set key "$luts"
    if {![info exists hist($key)]} { set hist($key) 0 }
    incr hist($key)
    if {$luts > $maxlut} { set maxlut $luts; set worst $p }
  }
  if {$luts > $MAX_LUT_LEVELS} {
    # Group by start and end register names with bit indices removed.
    set sp [regsub -all {\[[0-9]+\]} $spc {}]
    set ep [regsub -all {\[[0-9]+\]} $epc {}]
    set g "$luts $sp -> $ep[expr {$common ? { (rtlnet_common)} : {}}]"
    if {![info exists deep($g)]} { set deep($g) 0 }
    incr deep($g)
  }
}
set f [open "${tag}_lutlevels.rpt" w]
puts $f "rtlnet_tcp_offload $tag: part $part, clk period $period ns"
puts $f "clk endpoints analysed: [llength $paths]"
puts $f "LUT levels (LUT1-6 + MUXF7/8/9; carry cells not counted) : endpoints"
foreach k [lsort -integer [array names hist]] { puts $f [format "  %2d : %d" $k $hist($k)] }
puts $f "max LUT levels (rtlnet_tcp_offload logic): $maxlut"
puts $f "max LUT levels inside rtlnet_common u_axil_cdc / u_axil_slave (not gated): $maxcommon"
if {$worst ne ""} {
  puts $f "deepest path: [get_property STARTPOINT_PIN $worst] -> [get_property ENDPOINT_PIN $worst]"
  foreach c [get_cells -quiet -of_objects $worst] { puts $f "    [get_property REF_NAME $c]  $c" }
}
puts $f "endpoints above $MAX_LUT_LEVELS LUT levels, grouped (levels start -> end : count):"
foreach g [lsort [array names deep]] { puts $f "  $g : $deep($g)" }
puts $f "WNS $wns ns, WHS $whs ns, failing setup endpoints $nsetup, failing hold endpoints $nhold"
close $f

puts "rtlnet_timing: $tag WNS=$wns WHS=$whs setup_fail=$nsetup hold_fail=$nhold max_lut_levels=$maxlut common_axil_levels=$maxcommon endpoints=[llength $paths]"
if {$nsetup > 0 || $nhold > 0 || $wns < 0 || $whs < 0} { puts "rtlnet_timing: FAIL $tag timing"; exit 20 }
if {$maxlut > $MAX_LUT_LEVELS} { puts "rtlnet_timing: FAIL $tag logic levels ($maxlut LUT levels)"; exit 21 }
puts "rtlnet_timing: PASS $tag"
exit 0
