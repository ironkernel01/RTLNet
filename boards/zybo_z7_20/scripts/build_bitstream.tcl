# Purpose: reconstruct, synthesize and route the camera-only Zybo Z7-20 baseline.
# Overview: reports precede fail-closed timing gates; only passing designs export bit/XSA.
# Revision: 11-14-2026. Initial camera build.
# Every uncaught command error receives a coded verdict, including publication.
proc fail {code msg} {
  global build
  if {[info exists build]} {
    foreach artifact {rtlnet_zybo_z7_20.bit rtlnet_zybo_z7_20.xsa export_manifest.txt} {
      catch {file delete -force [file join $build $artifact]}
    }
    # Preserve measurement evidence but never leave a stale successful marker.
    catch {
      set path [file join $build build_info.txt]
      if {[file exists $path]} {
        set f [open $path r]; set contents [read $f]; close $f
        regsub -all -line {^gate_pass\s+1\s*$} $contents {} contents
        set f [open $path w]; puts -nonewline $f $contents; close $f
      }
    }
  }
  puts "rtlnet_build: FAIL ($code) [string map {\n { } \r { }} $msg]"
  exit $code
}
set ::rtlnet_failure_code 99
if {[catch {
set board [file normalize [file join [file dirname [info script]] ..]]
set repo [file normalize [file join $board .. ..]]
array set opt {tag camera stage camera highprofile none hp_netlist {} hp_t8 1 hp_auto 1 implementation holdfix python {} stop none}
set toks [split [join $argv ,] ,]
if {[llength $toks] % 2} {error "expected name,value pairs"}
foreach {name value} $toks {
  if {![info exists opt($name)]} {error "unknown argument $name"}
  set opt($name) $value
}
set tag $opt(tag)
if {![regexp {^[A-Za-z0-9_]{1,24}$} $tag]} {error "invalid tag"}
if {$opt(python) eq "" || ![file isfile $opt(python)]} {fail 11 "missing Python path from the central resolver"}
set build [file join $board build $tag]
set reports [file join $build reports]
file mkdir $reports
set ::rtlnet_dphy_deviation 0
source [file join $board scripts rtlnet_camera_timing_gate.tcl]
source [file join $board scripts rtlnet_camera_waivers.tcl]
source [file join $board scripts rtlnet_camera_export.tcl]
set_param board.repoPaths [list [file join $board board_files]]
create_project -force rtlnet_camera [file join $build project] -part xc7z020clg400-1
set_property board_part digilentinc.com:zybo-z7-20:part0:1.2 [current_project]
source [file join $board scripts rtlnet_camera_implementation.tcl]
rtlnet_camera_impl::configure [get_runs impl_1] $opt(implementation)
# These exact packaged-board annotations are stale, not physical board bindings.
# cdc_fifo: FIFO Generator uses explicit widths/clocks and no board pins or presets.
# ila_rxclk: kDebug=false excludes this analyzer from the camera netlist.
# ila_rxclk_lane: kDebug=false excludes this analyzer from the camera netlist.
# ila_vidclk: kDebug=false excludes this analyzer from the camera netlist.
# line_buffer: FIFO Generator uses explicit storage geometry and no board pins or presets.
foreach inner {cdc_fifo ila_rxclk ila_rxclk_lane ila_vidclk line_buffer} {
  set message "IP $inner was packaged with board value 'em.avnet.com:zed:part0:1.4'."
  set_msg_config -id {IP_Flow 19-4965} -string $message -new_severity WARNING
  puts "rtlnet_build: waiver \[IP_Flow 19-4965\] $message"
}
# Child Vivado processes have their own message counters. Audit their actual
# logs too; only the same five exact ID/object combinations qualify for waiver.
proc audit_run_critical_warnings {run} {
  global build reports
  set log [file join $build project rtlnet_camera.runs $run runme.log]
  if {$run eq "parent"} {set log [file join $build build_bitstream.log]}
  if {![file exists $log]} {fail 10 "missing critical-warning evidence $log"}
  set input [open $log r]; set lines [split [read $input] \n]; close $input
  set evidence [open [file join $reports ${run}_critical_warnings.rpt] w]
  set raw 0; set waived 0; set unwaived 0
  foreach line $lines {
    if {![regexp {^CRITICAL WARNING: \[([^]]+)\] (.*)} $line -> id message]} continue
    incr raw
    set allowed 0
    if {$id eq {IP_Flow 19-4965}} {
      foreach inner {cdc_fifo ila_rxclk ila_rxclk_lane ila_vidclk line_buffer} {
        set exact "IP $inner was packaged with board value 'em.avnet.com:zed:part0:1.4'."
        if {[string first $exact $message] == 0} {set allowed 1}
      }
    }
    if {$run in {impl_1 parent} && $::rtlnet_dphy_deviation && $id eq {Timing 38-282} &&
        [string trim $message] eq {The design failed to meet the timing requirements. Please see the timing summary report for details on the timing violations.}} {
      set allowed 1
      puts $evidence "deviation DPHY_HS_INPUT: full timing retained; only the two reviewed DDLY endpoints fail"
    }
    # The router's own statement of the same condition (Route 35-39) qualifies under the same deviation predicate.
    if {$run in {impl_1 parent} && $::rtlnet_dphy_deviation && $id eq {Route 35-39} &&
        [string first {The design did not meet timing requirements.} [string trim $message]] == 0} {
      set allowed 1
      puts $evidence "deviation DPHY_HS_INPUT: router timing statement; only the two reviewed DDLY endpoints fail"
    }
    if {$allowed} {incr waived} else {incr unwaived}
    puts $evidence "waived=$allowed $line"
  }
  close $evidence
  puts "rtlnet_build: $run critical warnings raw $raw, waived $waived, unwaived $unwaived"
  return $unwaived
}
foreach artifact {rtlnet_zybo_z7_20.bit rtlnet_zybo_z7_20.xsa build_info.txt export_manifest.txt} {
  file delete -force [file join $build $artifact]
}
set ::rtlnet_baseline [expr {$opt(stage) eq "baseline"}]
set ::rtlnet_hp [expr {$opt(highprofile) ne "none"}]
set ::rtlnet_hp_t8 $opt(hp_t8)
set ::rtlnet_hp_auto $opt(hp_auto)
if {$::rtlnet_baseline} {
  source [file join $board scripts rtlnet_add_baseline_sources.tcl]
  if {[catch {rtlnet_add_baseline_sources $repo $build} detail]} {fail 11 $detail}
  if {$::rtlnet_hp} {
    if {![file exists [file join $opt(hp_netlist) rtlnet_h264_hp.edf]]} {fail 11 "missing High profile netlist"}
    add_files -norecurse [file join $repo cores rtlnet_h264_enc hdl hp rtlnet_h264_hp_bb.sv]
    read_edif [file join $opt(hp_netlist) rtlnet_h264_hp.edf]
  }
  set_property STEPS.OPT_DESIGN.TCL.PRE [file join $board scripts rtlnet_cdc_hook.tcl] [get_runs impl_1]
}
set_property ip_repo_paths [list [file join $build ip_repo]] [current_project]
update_ip_catalog
if {[catch {source [file join $board bd rtlnet_camera.tcl]} detail]} {fail 12 $detail}
set bd [get_files *.bd]
if {$opt(stop) eq "bd"} {
  # Debug stop: block design created and validated, no synthesis, no artifacts.
  puts "rtlnet_build: STOP bd (block design created and validated; debug stop, not a build verdict)"
  exit 0
}
set_property synth_checkpoint_mode None $bd
# Check actual IP parameters before generation; Python also checks source Tcl.
foreach cell {MIPI_CSI_2_RX_0 MIPI_D_PHY_RX_0} {
  if {[get_property CONFIG.kDebug [get_bd_cells $cell]] ni {false 0}} {
    fail 13 "staged ILA exception removal requires kDebug=false on $cell"
  }
}
generate_target all $bd
# Firmware labels these as configured defaults, never as measured taps.
foreach parameter {kAddDelayClk_ps kAddDelayData0_ps kAddDelayData1_ps} {
  if {[get_property CONFIG.$parameter [get_bd_cells MIPI_D_PHY_RX_0]] != 0} {
    fail 13 "D-PHY diagnostics require audited zero delay compensation: $parameter"
  }
}
# Disable only XDC belonging to the six absent debug analyzers. The CDC FIFO
# is functional logic: its XDC remains enabled and any missing-module warning fails.
foreach {cell modules} {
  MIPI_CSI_2_RX_0 {ila_rxclk ila_rxclk_lane ila_vidclk}
  MIPI_D_PHY_RX_0 {ila_scnn_refclk ila_sfen_refclk ila_sfen_rxclk}
} {
  if {[get_property CONFIG.kDebug [get_bd_cells $cell]] ni {false 0}} {
    fail 13 "debug constraints require kDebug=false on $cell"
  }
  foreach module $modules {
    set pattern "*/rtlnet_camera_${cell}_0/hdl/$module/ila_v6_2/constraints/ila.xdc"
    set files [get_files -all -quiet $pattern]
    if {[llength $files] != 1} {fail 13 "expected one debug XDC $pattern"}
    set_property USED_IN_SYNTHESIS false $files
    set_property USED_IN_IMPLEMENTATION false $files
    puts "rtlnet_build: unused debug XDC $files"
  }
}
# Gamma control and stream use one clock. Its vendor false path has no CDC to justify it.
set gamma_xdc [get_files -all -quiet */AXI_GammaCorrection.xdc]
if {[llength $gamma_xdc] != 1} {fail 13 "expected one gamma constraint file, found [llength $gamma_xdc]"}
set_property USED_IN_SYNTHESIS false $gamma_xdc
set_property USED_IN_IMPLEMENTATION false $gamma_xdc
set wrapper [make_wrapper -files $bd -top]
add_files -norecurse $wrapper
set_property top rtlnet_camera_wrapper [current_fileset]
add_files -fileset constrs_1 [file join $board constraints rtlnet_camera_pins.xdc]
add_files -fileset constrs_1 [file join $board constraints rtlnet_camera_clocks.xdc]
set_property PROCESSING_ORDER EARLY [get_files rtlnet_camera_clocks.xdc]
add_files -fileset constrs_1 [file join $board constraints rtlnet_camera_timing.xdc]
set_property PROCESSING_ORDER LATE [get_files rtlnet_camera_timing.xdc]
set ::rtlnet_failure_code 10
launch_runs synth_1 -jobs 2
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {fail 10 "synthesis failed"}
open_run synth_1
report_utilization -hierarchical -file [file join $reports post_synth_utilization_hier.rpt]
# Collect the next-gate evidence even if the synthesis warning audit fails.
# Routed gates still decide qualification; synthesis estimates do not pass them.
report_timing_summary -report_unconstrained -max_paths 30 -file [file join $reports post_synth_timing_summary.rpt]
report_cdc -details -file [file join $reports post_synth_cdc.rpt]
report_methodology -file [file join $reports post_synth_methodology.rpt]
report_drc -file [file join $reports post_synth_drc.rpt]
report_exceptions -file [file join $reports post_synth_exceptions.rpt]
set synth_ct [check_timing -verbose -return_string]
set synth_ct_file [open [file join $reports post_synth_check_timing.rpt] w]
puts $synth_ct_file $synth_ct
close $synth_ct_file
set crit_synth [get_msg_config -count -severity {CRITICAL WARNING}]
puts "rtlnet_build: synthesis critical warnings: $crit_synth"
if {$crit_synth > 0} {fail 10 "synthesis critical warnings: $crit_synth"}
if {[audit_run_critical_warnings synth_1] > 0} {fail 10 "unwaived synthesis run critical warnings"}
set blackboxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $blackboxes]} {fail 10 "unresolved black boxes: $blackboxes"}
close_design
set ::rtlnet_failure_code 30
launch_runs impl_1 -to_step route_design -jobs 2
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {fail 30 "implementation failed"}
open_run impl_1
if {$opt(implementation) ne "original"} {
  write_checkpoint -force [file join $build before_post_route_physopt.dcp]
  report_timing_summary -max_paths 4 -file [file join $reports before_post_route_physopt_timing.rpt]
  if {[catch {rtlnet_camera_impl::post_route $opt(implementation)} detail]} {
    fail 30 "post-route physical optimization: $detail"
  }
}
write_checkpoint -force [file join $build post_route.dcp]
report_utilization -file [file join $reports post_route_utilization.rpt]
report_utilization -hierarchical -file [file join $reports post_route_utilization_hier.rpt]
report_timing_summary -report_unconstrained -max_paths 30 -file [file join $reports post_route_timing_summary.rpt]
report_timing -delay_type min_max -slack_lesser_than 0 -max_paths 64 -input_pins -file [file join $reports post_route_failing_paths.rpt]
report_exceptions -file [file join $reports post_route_exceptions.rpt]
report_cdc -details -file [file join $reports post_route_cdc.rpt]
report_methodology -file [file join $reports post_route_methodology.rpt]
report_clock_interaction -file [file join $reports post_route_clock_interaction.rpt]
report_clock_networks -file [file join $reports post_route_clock_networks.rpt]
report_drc -file [file join $reports post_route_drc.rpt]
set ct [check_timing -verbose -return_string]
set f [open [file join $reports post_route_check_timing.rpt] w]; puts $f $ct; close $f
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]
set ts [report_timing_summary -no_detailed_paths -no_check_timing -return_string]
set wpws ""
set ts_lines [split $ts \n]
for {set i 0} {$i < [llength $ts_lines]} {incr i} {
  if {[string match "*WNS(ns)*WPWS(ns)*" [lindex $ts_lines $i]]} {
    set nums [regexp -all -inline {\S+} [lindex $ts_lines [expr {$i + 2}]]]
    set wpws [lindex $nums 8]
    break
  }
}
puts "rtlnet_build: timing WNS $wns ns, WHS $whs ns, WPWS $wpws ns"
if {[catch {rtlnet_camera_timing::evaluate $wpws [lindex $nums 10] $reports} timing_result]} {
  fail 20 "timing gate: $timing_result"
}
if {[dict get $timing_result failed_setup] != [lindex $nums 2] ||
    [dict get $timing_result failed_hold] != [lindex $nums 6] ||
    abs($wns - [lindex $nums 0]) > 0.001 || abs($whs - [lindex $nums 4]) > 0.001} {
  fail 20 "timing enumeration disagrees with full summary"
}
set ::rtlnet_dphy_deviation [dict get $timing_result deviation]
set qualified_wns [dict get $timing_result wns]
set qualified_whs [dict get $timing_result whs]
puts "rtlnet_build: timing excluding DPHY_HS_INPUT WNS $qualified_wns ns, WHS $qualified_whs ns"
if {[catch {rtlnet_camera_review::apply $reports $::rtlnet_dphy_deviation} detail]} {
  fail 27 "vendor review: $detail"
}
report_cdc -details -file [file join $reports post_route_cdc.rpt]
report_cdc -details -waived -file [file join $reports post_route_cdc_waived.rpt]
report_methodology -name rtlnet_camera_final_method -file [file join $reports post_route_methodology.rpt]
report_methodology -waived -file [file join $reports post_route_methodology_waived.rpt]
# Save the exact waiver-bearing final netlist for reproducibility.
write_checkpoint -force [file join $build post_route.dcp]
# Timing 38-282 qualifies only under the just-computed deviation predicate.
set crit_impl_parent [get_msg_config -count -severity {CRITICAL WARNING}]
set crit_impl_run [audit_run_critical_warnings impl_1]
puts "rtlnet_build: implementation parent critical warnings: $crit_impl_parent"
set info [open [file join $build build_info.txt] w]
puts $info "design rtlnet_camera_wrapper\npart xc7z020clg400-1\ntool [version -short]"
puts $info "stage $opt(stage)\nhigh_profile $opt(highprofile)\nhp_t8 $opt(hp_t8)\nhp_t8_auto $opt(hp_auto)"
puts $info "implementation $opt(implementation)"
puts $info "git_hash [exec git -C $repo rev-parse --short=8 HEAD]"
puts $info "git_dirty [expr {[string trim [exec git -C $repo status --porcelain]] ne {}}]"
puts $info "wns_ns $wns\nwhs_ns $whs\nwpws_ns $wpws"
puts $info "qualified_wns_ns $qualified_wns\nqualified_whs_ns $qualified_whs"
puts $info "deviation_DPHY_HS_INPUT $::rtlnet_dphy_deviation\ndphy_tap_training 0\ndphy_hardware_verification open"
puts $info "deviation_reason matches_published_reference_static_timing_not_closable_no_tap_training"
if {$::rtlnet_hp} {
  set delivery [open [file join $build hp_delivery.txt] r]
  puts $info [read $delivery]
  close $delivery
}
puts $info [report_utilization -return_string]
close $info
# classify already rejects every other failing endpoint and every pulse-width failure.
set util [report_utilization -return_string]
foreach label {{Slice LUTs} {Slice Registers} {Block RAM Tile} DSPs} {
  set found 0
  foreach line [split $util \n] {
    set fields [split $line |]
    if {[llength $fields] < 7} continue
    if {[string trimright [string trim [lindex $fields 1]] *] ne $label} continue
    set pct [string trim [lindex $fields end-1]]
    if {![string is double -strict $pct]} continue
    puts "rtlnet_build: utilization $label [string trim [lindex $fields 2]] ($pct %)"
    if {$pct > 85.0} {fail 21 "$label exceeds 85 percent"}
    if {$label eq "Slice LUTs"} {
      set used [string map {, {}} [string trim [lindex $fields 2]]]
      if {![string is integer -strict $used] || $used > 45220} {fail 21 "Slice LUTs exceed 45,220 or count is invalid"}
    }
    set found 1
    break
  }
  if {!$found} {fail 21 "missing utilization row $label"}
}
set latches [get_cells -quiet -hierarchical -filter {PRIMITIVE_SUBGROUP == latch || REF_NAME =~ LD*}]
if {[llength $latches] > 0} {fail 23 "latches: $latches"}
set async_cells [get_cells -quiet -hierarchical -filter {REF_NAME == FDCE || REF_NAME == FDPE}]
foreach cell $async_cells {
  if {[string match */u_video/* $cell]} {fail 23 "user video asynchronous reset $cell"}
}
set f [open [file join $reports post_route_async_resets.rpt] w]
puts $f [join $async_cells \n]
close $f
puts "rtlnet_build: vendor camera BD asynchronous reset inventory [llength $async_cells] cells"
foreach {all name n} [regexp -all -inline {checking (\S+) \((\d+)\)} $ct] {
  if {$name in {no_clock unconstrained_internal_endpoints loops latch_loops multiple_clock generated_clocks} && $n > 0} {
    fail 22 "check_timing $name=$n"
  }
}
foreach line [split [report_cdc -details -return_string] \n] {
  if {[regexp {^(CDC-[0-9]+)\s+(Critical|Warning)\s+([0-9]+)\s} $line -> id sev cnt] && $cnt > 0} {
    fail 27 "CDC $id $sev x$cnt"
  }
}
foreach violation [get_methodology_violations -quiet -name rtlnet_camera_final_method] {
  if {[string tolower [get_property SEVERITY $violation]] ni {info advisory}} {
    fail 27 "methodology [get_property CHECK $violation]: [get_property DESCRIPTION $violation]"
  }
}
if {$crit_impl_run > 0} {fail 24 "unwaived implementation run critical warnings"}
if {[audit_run_critical_warnings parent] > 0} {fail 24 "unwaived parent critical warnings"}
# Publication uses the same gated checkpoint for both stage values.
rtlnet_camera_export::write $board $build $opt(python)
set ::rtlnet_failure_code 24
if {[audit_run_critical_warnings impl_1] > 0} {fail 24 "unwaived bitstream-run critical warnings"}
if {[audit_run_critical_warnings parent] > 0} {
  foreach artifact {rtlnet_zybo_z7_20.bit rtlnet_zybo_z7_20.xsa} {file delete -force [file join $build $artifact]}
  fail 24 "unwaived export critical warnings"
}
set ::rtlnet_failure_code 43
set export_info [open [file join $build export_manifest.txt] r]
set manifest [read $export_info]; close $export_info
set info [open [file join $build build_info.txt] a]
puts $info $manifest
puts $info "gate_pass 1"
close $info
if {$::rtlnet_dphy_deviation} {
  puts "rtlnet_build: PASS with deviation DPHY_HS_INPUT (2 endpoints, reference configuration; hardware verification open)"
} else {
  puts "rtlnet_build: PASS $opt(stage)"
}
exit 0
} detail]} {
  fail $::rtlnet_failure_code $detail
}
