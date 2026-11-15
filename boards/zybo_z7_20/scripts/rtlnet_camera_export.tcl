# Purpose: finish the project run and publish a bit-inclusive, verified XSA.
# Overview: use the gated DCP in the run's bitstream pre-hook; never export an unrouted image.
# Revision: 11-14-2026.
namespace eval rtlnet_camera_export {}
proc rtlnet_camera_export::write {board build python} {
  set ::rtlnet_failure_code 40
  set checkpoint [file join $build post_route.dcp]
  if {![file isfile $checkpoint] || [file size $checkpoint] == 0} {error "missing gated checkpoint $checkpoint"}
  set run [get_runs impl_1]
  set top [get_property TOP [get_filesets sources_1]]
  if {$top ne "rtlnet_camera_wrapper"} {error "unexpected bitstream top $top"}
  set hook [file join $build write_bitstream_pre.tcl]
  set channel [open $hook w]
  puts $channel [list set ::rtlnet_gated_checkpoint $checkpoint]
  puts $channel [list set ::rtlnet_gated_top $top]
  puts $channel [list source [file join $board scripts rtlnet_camera_bitstream_pre.tcl]]
  close $channel
  set_property STEPS.WRITE_BITSTREAM.TCL.PRE $hook $run
  set route_log [file join [get_property DIRECTORY $run] runme.log]
  if {[file exists $route_log]} {file copy -force $route_log [file join $build reports impl_1_before_bitstream.log]}
  # Resuming a completed route registers the BIT with the project run. The
  # pre-hook replaces its in-memory netlist with the checkpoint actually gated.
  launch_runs impl_1 -to_step write_bitstream -jobs 2
  wait_on_run impl_1
  if {[get_property PROGRESS $run] ne "100%" ||
      ![string match {write_bitstream Complete*} [get_property STATUS $run]]} {
    error "bitstream run does not complete: [get_property STATUS $run]"
  }
  set run_bit [file join [get_property DIRECTORY $run] ${top}.bit]
  if {![file isfile $run_bit] || [file size $run_bit] == 0 || [file mtime $run_bit] < [file mtime $checkpoint]} {
    error "missing, empty or stale implementation-run bitstream $run_bit"
  }
  set bit [file join $build rtlnet_zybo_z7_20.bit]
  file copy -force $run_bit $bit
  set ::rtlnet_failure_code 41
  current_run -implementation impl_1
  set xsa [file join $build rtlnet_zybo_z7_20.xsa]
  write_hw_platform -fixed -force -include_bit -file $xsa
  set ::rtlnet_failure_code 42
  puts [exec $python -I [file join $board scripts rtlnet_verify_export.py] \
    $bit $xsa $checkpoint [file join $build export_manifest.txt]]
}
