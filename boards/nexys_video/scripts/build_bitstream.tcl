# -----------------------------------------------------------------------------
# File: build_bitstream.tcl
# Purpose: scripted, reproducible Vivado 2026.1 non-project build of the RTLNet
#   Nexys Video board top: block design from Tcl, synthesis, CDC constraints,
#   implementation, gated reports, bitstream and the MicroBlaze memory map
#   (MMI) for updatemem.
# Overview:
#   * Paths derive from this script's location (boards/nexys_video/scripts), so
#     the build survives tree moves and does not depend on the working
#     directory. Outputs go to boards/nexys_video/build/.
#   * Steps: create the block design rtlnet_cpu (microblaze/
#     hdl/rtlnet_cpu_bd.tcl) under build/bd, generate output products with
#     global synthesis, read the RTL through filelists, read the XDC,
#     synth_design (top rtlnet_nexys_video_top, xc7a200tsbg484-1, generics
#     BUILD_ID and BUILD_DIRTY, define RTLNET_WITH_NETWORK only for the
#     network build), scripts/rtlnet_constrain_cdc.tcl, opt/place/phys_opt/
#     route, reports, gates, write_bitstream, write_mem_info, the fixed
#     hardware platform (XSA, write_hw_platform -fixed, the input of the
#     firmware BSP flow microblaze/firmware/build.ps1), build_info.txt.
#   * Gates (each its own exit code; nothing is written past a failed gate):
#       99 bad arguments            11 missing source, filelist or XDC
#       12 block design failure     10 synthesis error or critical warning
#       13 CDC constraint failure   25 opt_design   26 place_design
#       30 route_design             20 timing: setup WNS, hold WHS or pulse
#                                      width below 0, or any failing endpoint
#       21 utilization above 80 %   22 check_timing: unclocked or
#                                      unconstrained endpoints, loops
#       23 user asynchronous reset endpoints or latches outside the named
#          exceptions (rtlnet_reset_sync, vendor block design)
#       24 critical warnings during implementation
#       27 report_cdc Critical/Warning finding, or a methodology finding
#          (Warning or worse) without a waiver in this script
#       40 write_bitstream          41 write_mem_info
#       42 write_hw_platform
#   * Reports saved in build/reports: utilization post-synth and post-route,
#     timing summary, CDC (report_cdc -details), methodology, DRC,
#     check_timing, clock networks, clock interaction, failing paths.
# Usage: vivado -mode batch -source build_bitstream.tcl -tclargs [network 0|1]
#          [build_id <8 hex>] [dirty 0|1]   (pairs as "name value" or name=value)
#   Normally run through boards/nexys_video/scripts/build.ps1.
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
#   * 10-22-2026: XSA export (write_hw_platform -fixed).
# -----------------------------------------------------------------------------

# Script-relative roots (survive tree moves; no dependence on the caller's cwd).
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set BOARD_DIR  [file normalize [file join $SCRIPT_DIR ".."]]
set REPO       [file normalize [file join $BOARD_DIR ".." ".."]]
set BUILD_DIR  [file join $BOARD_DIR build]
set RPT_DIR    [file join $BUILD_DIR reports]
set PART       xc7a200tsbg484-1
set TOP        rtlnet_nexys_video_top
set UTIL_LIMIT 80.0

proc nv_exit {code msg} {
  puts "rtlnet_build: FAIL ($code) $msg"
  set crit [get_msg_config -count -severity {CRITICAL WARNING}]
  puts "rtlnet_build: critical warnings so far: $crit"
  exit $code
}

# ---------------------------------------------------------------------------
# Arguments: "name value" pairs, name=value, or comma-separated lists of them
# (vivado.bat splits '=' and ',' into separate arguments).
# ---------------------------------------------------------------------------
set opt(network)  0
set opt(build_id) ""
set opt(dirty)    ""
set toks {}
foreach a $argv { foreach t [split $a ",="] { if {$t ne ""} { lappend toks $t } } }
if {[llength $toks] % 2 != 0} { puts "usage: \[network 0|1\] \[build_id XXXXXXXX\] \[dirty 0|1\]"; exit 99 }
foreach {k v} $toks {
  set k [string tolower $k]
  if {![info exists opt($k)]} { puts "rtlnet_build: unknown argument '$k'"; exit 99 }
  set opt($k) $v
}
if {$opt(network) ni {0 1}} { puts "rtlnet_build: network must be 0 or 1"; exit 99 }

# Build identity from git unless given.
if {$opt(build_id) eq ""} {
  if {[catch {exec git -C $REPO rev-parse --short=8 HEAD} h]} { set h 00000000 }
  set opt(build_id) [string trim $h]
}
if {$opt(dirty) eq ""} {
  if {[catch {exec git -C $REPO status --porcelain} st]} { set st "?" }
  set opt(dirty) [expr {[string trim $st] eq "" ? 0 : 1}]
}
if {![regexp {^[0-9a-fA-F]{1,8}$} $opt(build_id)]} { puts "rtlnet_build: bad build_id '$opt(build_id)'"; exit 99 }
if {$opt(dirty) ni {0 1}} { puts "rtlnet_build: dirty must be 0 or 1"; exit 99 }
set BUILD_ID_HEX [format %08x [scan $opt(build_id) %x]]
set NETWORK $opt(network)
puts "rtlnet_build: repo $REPO"
puts "rtlnet_build: build_id $BUILD_ID_HEX dirty $opt(dirty) network $NETWORK part $PART"

file mkdir $BUILD_DIR
file delete -force $RPT_DIR [file join $BUILD_DIR bd]
file mkdir $RPT_DIR

# ---------------------------------------------------------------------------
# Filelist reader: nested -f, +incdir+, comments; each source read once.
# ---------------------------------------------------------------------------
set ::incdirs {}
set ::read_files {}
proc read_filelist {repo path} {
  set full [file join $repo $path]
  if {![file exists $full]} { nv_exit 11 "filelist not found: $path" }
  set f [open $full r]
  set lines [split [read $f] "\n"]
  close $f
  foreach raw $lines {
    set line [string trim [regsub {(#|//).*$} $raw ""]]
    if {$line eq ""} continue
    if {[regexp {^-f\s+(.+)$} $line -> sub]} { read_filelist $repo [string trim $sub]; continue }
    if {[regexp {^\+incdir\+(.+)$} $line -> d]} {
      set dd [file join $repo $d]
      if {[lsearch -exact $::incdirs $dd] < 0} { lappend ::incdirs $dd }
      continue
    }
    if {[regexp {^\+define\+} $line]} continue
    set src [file normalize [file join $repo $line]]
    if {[lsearch -exact $::read_files $src] >= 0} continue
    if {![file exists $src]} { nv_exit 11 "source not found: $line (from $path)" }
    lappend ::read_files $src
    read_verilog -sv $src
  }
}

# ---------------------------------------------------------------------------
# Block design.
# ---------------------------------------------------------------------------
create_project -in_memory -part $PART
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]
if {[catch {
  source [file join $REPO microblaze hdl rtlnet_cpu_bd.tcl]
  set bd_file [rtlnet_cpu_bd_create [file join $BUILD_DIR bd]]
  set_property synth_checkpoint_mode None [get_files $bd_file]
  generate_target all [get_files $bd_file]
  set bd_wrapper [make_wrapper -files [get_files $bd_file] -top]
  read_verilog $bd_wrapper
} err]} { nv_exit 12 "block design: $err" }

# ---------------------------------------------------------------------------
# RTL and constraints.
# ---------------------------------------------------------------------------
read_filelist $REPO cores/rtlnet_common/hdl/rtlnet_common.f
if {$NETWORK} { read_filelist $REPO boards/nexys_video/hdl/rtlnet_nexys_video_network.f }
read_filelist $REPO boards/nexys_video/hdl/rtlnet_nexys_video.f
set xdc_list [list [file join $BOARD_DIR constraints rtlnet_nexys_video.xdc]]
if {!$NETWORK} { lappend xdc_list [file join $BOARD_DIR constraints rtlnet_nexys_video_cpu_only.xdc] }
foreach x $xdc_list {
  if {![file exists $x]} { nv_exit 11 "XDC not found: $x" }
  read_xdc $x
}

# ---------------------------------------------------------------------------
# Synthesis.
# ---------------------------------------------------------------------------
set synth_args [list -top $TOP -part $PART -include_dirs $::incdirs \
  -generic BUILD_ID=32'h$BUILD_ID_HEX -generic BUILD_DIRTY=1'b$opt(dirty)]
if {$NETWORK} { lappend synth_args -verilog_define RTLNET_WITH_NETWORK }
if {[catch {synth_design {*}$synth_args} err]} { nv_exit 10 "synth_design: $err" }
set crit_synth [get_msg_config -count -severity {CRITICAL WARNING}]
if {$crit_synth > 0} { nv_exit 10 "$crit_synth critical warning(s) up to synthesis (see the log)" }
report_utilization -file [file join $RPT_DIR post_synth_utilization.rpt]
write_checkpoint -force [file join $BUILD_DIR post_synth.dcp]

# Crossing constraints by cell name. The CPU-only build has reset and level
# synchronizers only; the network build adds Gray counters, packet FIFOs and
# AXI4-Lite crossings.
# Network build: the RGMII interface timing applies to the synthesized netlist
# (it names pin-layer cells), then the expected crossing instances: packet
# FIFOs u_mac/u_rx_fifo, u_mac/u_tx_fifo, u_protocol/u_ingress_fifo,
# u_protocol/u_egress_fifo and the socket layer's u_rx_fifo, u_tx_fifo and
# u_tx_desc_fifo, and the CPU network path queues u_protocol/u_cpu_rx_fifo and
# u_protocol/u_cpu_tx_fifo, plus the checksum offload's u_protocol/g_cpu.g_offload.u_cpu_offload/u_tx/u_tx_fifo (fifo 10); register crossings of the MAC, the protocol wrapper
# and the UDP echo, plus the CPU-path classifier's and the checksum offload's u_axil_cdc (axil_cdc 5); Gray counters u_mac/u_tx_count_sync and the
# wrapper's four ingress/egress counter crossings and its CPU transmit reject
# counter u_cnt_cpu_reject_sync (gray 6). A change of these
# counts fails the build until the expectation is reviewed and updated here.
if {$NETWORK} {
  set rgmii_xdc [file join $BOARD_DIR constraints rtlnet_nexys_video_rgmii.xdc]
  if {![file exists $rgmii_xdc]} { nv_exit 11 "XDC not found: $rgmii_xdc" }
  if {[catch {read_xdc $rgmii_xdc} err]} { nv_exit 13 "RGMII constraints: $err" }
  set ::rtlnet_cdc_required {sync reset gray fifo axil_cdc}
  set ::rtlnet_cdc_expect   {fifo 10 axil_cdc 5 gray 6}
} else {
  set ::rtlnet_cdc_required {sync reset}
  set ::rtlnet_cdc_expect   {fifo 0 axil_cdc 0 gray 0}
}
set ::rtlnet_cdc_report [file join $RPT_DIR cdc_instances.txt]
if {[catch {source [file join $REPO scripts rtlnet_constrain_cdc.tcl]} err]} { nv_exit 13 "CDC constraints: $err" }

# ---------------------------------------------------------------------------
# Implementation.
# ---------------------------------------------------------------------------
if {[catch {opt_design} err]}   { nv_exit 25 "opt_design: $err" }
if {[catch {place_design} err]} { nv_exit 26 "place_design: $err" }
if {[catch {phys_opt_design} err]} { nv_exit 26 "phys_opt_design: $err" }
if {[catch {route_design} err]} { nv_exit 30 "route_design: $err" }
write_checkpoint -force [file join $BUILD_DIR post_route.dcp]

# ---------------------------------------------------------------------------
# Reports.
# ---------------------------------------------------------------------------
report_utilization        -file [file join $RPT_DIR post_route_utilization.rpt]
report_utilization -hierarchical -file [file join $RPT_DIR post_route_utilization_hier.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -file [file join $RPT_DIR post_route_timing_summary.rpt]
report_cdc -details       -file [file join $RPT_DIR post_route_cdc.rpt]
report_methodology        -file [file join $RPT_DIR post_route_methodology.rpt]
report_drc                -file [file join $RPT_DIR post_route_drc.rpt]
report_clock_networks     -file [file join $RPT_DIR post_route_clock_networks.rpt]
report_clock_interaction  -file [file join $RPT_DIR post_route_clock_interaction.rpt]
report_io                 -file [file join $RPT_DIR post_route_io.rpt]
set ct [check_timing -verbose -return_string]
set fh [open [file join $RPT_DIR post_route_check_timing.rpt] w]; puts $fh $ct; close $fh

# ---------------------------------------------------------------------------
# Gate: timing (queried from the design, not parsed from a report).
# ---------------------------------------------------------------------------
set wns [get_property SLACK [lindex [get_timing_paths -setup -max_paths 1 -nworst 1] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -hold  -max_paths 1 -nworst 1] 0]]
if {$wns eq ""} { nv_exit 20 "no setup timing path found (unconstrained design?)" }
if {$whs eq ""} { nv_exit 20 "no hold timing path found" }
set fail_setup [llength [get_timing_paths -setup -max_paths 100000 -nworst 1 -slack_lesser_than 0]]
set fail_hold  [llength [get_timing_paths -hold  -max_paths 100000 -nworst 1 -slack_lesser_than 0]]
set wpws ""
set fail_pw 0
set ts [report_timing_summary -no_detailed_paths -no_check_timing -return_string]
set ts_lines [split $ts "\n"]
for {set i 0} {$i < [llength $ts_lines]} {incr i} {
  if {[string match "*WNS(ns)*WPWS(ns)*" [lindex $ts_lines $i]]} {
    set nums [regexp -all -inline {\S+} [lindex $ts_lines [expr {$i + 2}]]]
    if {[llength $nums] >= 12} { set wpws [lindex $nums 8]; set fail_pw [lindex $nums 10] }
    break
  }
}
puts "rtlnet_build: timing WNS $wns ns ($fail_setup failing setup endpoints), WHS $whs ns ($fail_hold failing hold endpoints), WPWS $wpws ns ($fail_pw failing pulse-width endpoints)"
if {$wpws eq ""} { nv_exit 20 "pulse-width summary not found in report_timing_summary" }
if {$wns < 0 || $whs < 0 || $fail_setup > 0 || $fail_hold > 0 || $wpws < 0 || $fail_pw > 0} {
  report_timing -setup -max_paths 50 -nworst 1 -slack_lesser_than 0 -file [file join $RPT_DIR failing_setup.rpt]
  report_timing -hold  -max_paths 50 -nworst 1 -slack_lesser_than 0 -file [file join $RPT_DIR failing_hold.rpt]
  nv_exit 20 "timing not met"
}

# ---------------------------------------------------------------------------
# Gate: check_timing (every endpoint clocked and constrained, no loops).
# ---------------------------------------------------------------------------
set ct_fail {}
foreach {all name n} [regexp -all -inline {checking (\S+) \((\d+)\)} $ct] {
  if {$name in {no_clock unconstrained_internal_endpoints loops latch_loops multiple_clock generated_clocks} && $n > 0} {
    lappend ct_fail "$name=$n"
  }
}
if {[llength $ct_fail] > 0} { nv_exit 22 "check_timing: [join $ct_fail {, }]" }

# ---------------------------------------------------------------------------
# Gate: utilization ceiling (LUT, FF, block RAM, DSP).
# ---------------------------------------------------------------------------
set ur [report_utilization -return_string]
set util_summary {}
foreach {label key} {"Slice LUTs" lut "Slice Registers" ff "Block RAM Tile" bram "DSPs" dsp} {
  set found 0
  foreach line [split $ur "\n"] {
    set f [split $line "|"]
    if {[llength $f] < 7} continue
    if {[string trim [string trimright [string trim [lindex $f 1]] "*"]] ne $label} continue
    set used [string trim [lindex $f 2]]
    set pct  [string trim [lindex $f end-1]]
    if {![string is double -strict $pct]} continue
    lappend util_summary "$key=$used ($pct%)"
    if {$pct > $UTIL_LIMIT} { nv_exit 21 "$label at $pct % (limit $UTIL_LIMIT %)" }
    set found 1
    break
  }
  if {!$found} { nv_exit 21 "utilization row '$label' not found" }
}
puts "rtlnet_build: utilization [join $util_summary {, }]"

# ---------------------------------------------------------------------------
# Gate: asynchronous clear/preset endpoints and latches. Named exceptions:
# rtlnet_reset_sync instances (u_rst_*) and the vendor block design inside
# the CPU core (u_cpu/u_bd).
# ---------------------------------------------------------------------------
set latches [get_cells -quiet -hierarchical -filter {PRIMITIVE_SUBGROUP == latch || REF_NAME =~ LD*}]
set n_async_rs 0
set n_async_bd 0
set bad_async {}
foreach c [get_cells -quiet -hierarchical -filter {REF_NAME == FDCE || REF_NAME == FDPE}] {
  set p [get_pins -quiet $c/CLR]
  if {$p eq ""} { set p [get_pins -quiet $c/PRE] }
  set net [get_nets -quiet -of_objects $p]
  if {$net ne "" && [get_property TYPE $net] in {GROUND POWER}} continue
  set parent [get_cells -quiet [get_property PARENT $c]]
  set pref ""
  if {$parent ne ""} { set pref "[get_property REF_NAME $parent] [get_property ORIG_REF_NAME $parent]" }
  if {[regexp {/pipe_reg\[[0-9]+\]$} $c] && [regexp {(^| )rtlnet_reset_sync} $pref]} { incr n_async_rs; continue }
  if {[string match "u_cpu/u_bd/*" $c]} { incr n_async_bd; continue }
  lappend bad_async $c
}
puts "rtlnet_build: asynchronous reset endpoints: rtlnet_reset_sync $n_async_rs, vendor block design $n_async_bd, other [llength $bad_async]; latches [llength $latches]"
if {[llength $latches] > 0} { nv_exit 23 "latches: [lrange $latches 0 9]" }
if {[llength $bad_async] > 0} { nv_exit 23 "user asynchronous reset endpoints: [lrange $bad_async 0 9]" }

# ---------------------------------------------------------------------------
# Gate: report_cdc and report_methodology findings. CDC: no Critical or
# Warning finding at all. Methodology: every Warning or worse must match a
# waiver below (rule, object pattern, rationale); matched waivers are printed.
# ---------------------------------------------------------------------------
# The ID summary of report_cdc -details lists the unwaived findings with their
# severity, then the waived ones (created by rtlnet_constrain_cdc.tcl) in a
# separate "Waived Endpoints" table. The gate also requires the ID table to be
# found at all, so a format change cannot pass silently.
set cdc_bad {}
set cdc_ids 0
set cdc_waived {}
foreach line [split [report_cdc -details -return_string] "\n"] {
  if {[regexp {^(CDC-[0-9]+)\s+(Critical|Warning|Info)\s+([0-9]+)\s} $line -> id sev cnt]} {
    incr cdc_ids
    if {$sev ne "Info"} { lappend cdc_bad "$id $sev x$cnt" }
  } elseif {[regexp {^(CDC-[0-9]+)\s+([0-9]+)\s*$} $line -> id cnt]} {
    lappend cdc_waived "$id x$cnt"
  }
}
puts "rtlnet_build: report_cdc: $cdc_ids finding classes, waived by rtlnet_constrain_cdc.tcl: [expr {[llength $cdc_waived] ? [join $cdc_waived {, }] : {none}}]"
if {$cdc_ids == 0} { nv_exit 27 "report_cdc ID summary not found (format changed?)" }
if {[llength $cdc_bad] > 0} { nv_exit 27 "report_cdc findings: [join $cdc_bad {, }]" }

# Waiver test for LUTAR-1 on the reset AND: the LUT is the rst_arstn gate and
# every asynchronous pin it drives is a CLR pin of an rtlnet_reset_sync chain.
proc nv_waive_reset_and {desc} {
  if {![regexp {^LUT cell u_rst_[a-z0-9_]+/pipe\[[0-9]+\]_i_1(__[0-9]+)?,} $desc]} { return 0 }
  set pins [regexp -all -inline {\S+/(?:CLR|PRE)\M} $desc]
  if {[llength $pins] == 0} { return 0 }
  foreach p $pins {
    if {![regexp {^u_rst_[a-z0-9_]+/pipe_reg\[[0-9]+\]/CLR$} [string trimright $p ",."]]} { return 0 }
  }
  return 1
}
# Waivers: {rule test rationale}; test is a regexp on the description, or
# "proc:<name>" for a Tcl test procedure.
set meth_waivers {
  {LUTAR-1 {^LUT cell u_cpu/u_bd/\S+, with 2 or more inputs, drives asynchronous preset/clear pin\(s\) u_cpu/u_bd/}
           {vendor MDM JTAG control logic inside the MicroBlaze block design}}
  {LUTAR-1 proc:nv_waive_reset_and
           {rst_arstn = cpu_resetn AND mmcm_locked into the rtlnet_reset_sync chains only; glitch argument in the board top header}}
  {TIMING-9 {.}
           {report_cdc (gated above: no Critical/Warning) shows every crossing synchronized; the asynchronous groups are the MDM BSCAN clocks of the vendor IP}}
  {TIMING-47 {^A False Path timing constraint is set between synchronous clocks rgmii_rxc_v and rgmii_rxc }
           {RGMII same-edge capture: the opposite-edge setup and same-edge hold pairs of the DDR input describe no capture (rtlnet_nexys_video_rgmii.xdc, MAC documentation section 6)}}
}
set meth_bad {}
foreach v [get_methodology_violations -quiet] {
  set rule [get_property CHECK $v]
  set sev  [get_property SEVERITY $v]
  set desc [string trim [get_property DESCRIPTION $v]]
  if {$sev eq "Advisory"} continue
  set hit ""
  foreach w $meth_waivers {
    lassign $w wr wtest wwhy
    if {$wr ne $rule} continue
    if {[string match "proc:*" $wtest]} {
      set ok [[string range $wtest 5 end] $desc]
    } else {
      set ok [regexp -- $wtest $desc]
    }
    if {$ok} { set hit $wwhy; break }
  }
  if {$hit ne ""} {
    puts "rtlnet_build: waived $rule ($sev): $hit"
  } else {
    lappend meth_bad "$rule ($sev)"
    puts "rtlnet_build: UNWAIVED $rule ($sev): [string range $desc 0 300]"
  }
}
if {[llength $meth_bad] > 0} { nv_exit 27 "methodology findings without waiver: [join $meth_bad {, }]" }

# ---------------------------------------------------------------------------
# Gate: no critical warning during implementation.
# ---------------------------------------------------------------------------
set crit_all [get_msg_config -count -severity {CRITICAL WARNING}]
if {$crit_all > $crit_synth} { nv_exit 24 "[expr {$crit_all - $crit_synth}] critical warning(s) during implementation" }

# ---------------------------------------------------------------------------
# Bitstream (BRAM holds no firmware yet; merge_elf.ps1 adds it) and MMI.
# ---------------------------------------------------------------------------
set bit_hw [file join $BUILD_DIR rtlnet_nexys_video_hw.bit]
set mmi    [file join $BUILD_DIR rtlnet_nexys_video.mmi]
if {[catch {write_bitstream -force $bit_hw} err]} { nv_exit 40 "write_bitstream: $err" }
if {[catch {write_mem_info -force $mmi} err]} { nv_exit 41 "write_mem_info: $err" }

# Fixed hardware platform for the firmware BSP (Vitis platform component).
set xsa [file join $BUILD_DIR rtlnet_nexys_video.xsa]
if {[catch {write_hw_platform -fixed -force -include_bit -file $xsa} err]} { nv_exit 42 "write_hw_platform: $err" }

# ---------------------------------------------------------------------------
# Build record.
# ---------------------------------------------------------------------------
set fh [open [file join $BUILD_DIR build_info.txt] w]
puts $fh "design        $TOP"
puts $fh "part          $PART"
puts $fh "git_hash      $BUILD_ID_HEX"
puts $fh "git_dirty     $opt(dirty)"
puts $fh "network       $NETWORK"
puts $fh "tool          [version -short]"
puts $fh "built         [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %z}]"
puts $fh "wns_ns        $wns"
puts $fh "whs_ns        $whs"
puts $fh "wpws_ns       $wpws"
puts $fh "utilization   [join $util_summary {, }]"
puts $fh "cdc_classes   $::rtlnet_cdc_result"
puts $fh "bitstream_hw  [file tail $bit_hw]"
puts $fh "mmi           [file tail $mmi]"
puts $fh "xsa           [file tail $xsa]"
close $fh
puts "rtlnet_build: PASS $bit_hw"
exit 0
