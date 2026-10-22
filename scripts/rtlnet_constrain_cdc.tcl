# -----------------------------------------------------------------------------
# File: rtlnet_constrain_cdc.tcl
# Purpose: bound every RTLNet clock-domain crossing by cell name, on a
#   synthesized design (architecture section 9, rtlnet_common.md section 4).
#   No blanket asynchronous clock groups; each crossing gets the constraint
#   its protocol needs.
# Overview (classes, found by cell name inside instances of the named module):
#   sync      rtlnet_sync: false path to the D pin of every first stage
#             g_bit[*].sync_ff_reg[0] (rtlnet_pulse_sync and rtlnet_axil_cdc
#             toggles cross through rtlnet_sync and are covered here).
#   reset     rtlnet_reset_sync: false path to the CLR/PRE pins of pipe_reg[*].
#   gray      rtlnet_gray_sync: gray_src_reg -> gray_dst_ff_reg[0][*],
#             set_max_delay -datapath_only and set_bus_skew of one source period.
#   fifo      rtlnet_packet_fifo (instances u_*_fifo): s_gray -> s_gray_m1 and
#             m_gray -> m_gray_s1 as for gray; the event toggles
#             events_s -> events_m1 set_max_delay -datapath_only of one source
#             period.
#   axil_cdc  rtlnet_axil_cdc: req_*_hold (to m_clk) and rsp_*_hold (to s_clk)
#             bundles, set_max_delay -datapath_only of the destination period.
# Usage (after synth_design or open_checkpoint of a synthesized design):
#   set ::rtlnet_cdc_required {sync reset}      ;# classes this build must contain
#   source scripts/rtlnet_constrain_cdc.tcl
#   The script prints one line per class, `rtlnet_cdc: <class> instances=<n>
#   crossings=<m>`, and `rtlnet_cdc: PASS` or `rtlnet_cdc: FAIL ...`; it
#   raises a Tcl error (the build turns it into an exit code) when a required
#   class has zero matches, or when an instance of a module lacks the cells the
#   constraint names (a renamed register would otherwise lose its constraint
#   silently). ::rtlnet_cdc_result holds the per-class counts afterwards.
#   Default required classes: all five.
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------

namespace eval rtlnet_cdc {
  variable classes {sync reset gray fifo axil_cdc}
  variable errors  {}
  variable counts
  array set counts {}
}

# Hierarchical instances of a module, uniquified or not.
proc rtlnet_cdc::instances {module} {
  return [get_cells -quiet -hierarchical -filter \
    "IS_PRIMITIVE == 0 && (REF_NAME == $module || ORIG_REF_NAME == $module || REF_NAME =~ ${module}__parameterized*)"]
}

# Flip-flop cells under one instance whose local name matches a regular expression.
proc rtlnet_cdc::cells_in {inst regexp} {
  set pat "^[string map {[ \\[ ] \\] . \\.} $inst]/$regexp\$"
  return [get_cells -quiet -hierarchical -regexp -filter {IS_SEQUENTIAL == 1} $pat]
}

# The clock period that drives a flip-flop cell (first clock on its clock pin).
proc rtlnet_cdc::period_of {cell} {
  set clk [lindex [get_clocks -quiet -of_objects [get_pins -quiet $cell/C]] 0]
  if {$clk eq ""} { return "" }
  return [get_property PERIOD $clk]
}

proc rtlnet_cdc::fail {msg} {
  variable errors
  lappend errors $msg
  puts "rtlnet_cdc: ERROR $msg"
}

# Max delay (datapath only) plus bus skew of one source period, src -> dst.
proc rtlnet_cdc::bound_gray {inst src dst} {
  set per [period_of [lindex $src 0]]
  if {$per eq ""} { fail "$inst: no clock on [lindex $src 0]"; return 0 }
  set_max_delay -datapath_only -from $src -to $dst $per
  set_bus_skew -from $src -to $dst $per
  return 1
}

# ---------------------------------------------------------------------------
# sync: rtlnet_sync first stages.
# ---------------------------------------------------------------------------
proc rtlnet_cdc::do_sync {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances rtlnet_sync] {
    incr n_inst
    set first [cells_in $inst {g_bit\[[0-9]+\]\.sync_ff_reg\[0\]}]
    if {[llength $first] == 0} { fail "$inst: no g_bit\[*\].sync_ff_reg\[0\] cells"; continue }
    set_false_path -to [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]
    incr n_x [llength $first]
  }
  set counts(sync) [list $n_inst $n_x]
}

# ---------------------------------------------------------------------------
# reset: rtlnet_reset_sync asynchronous clear/preset pins.
# ---------------------------------------------------------------------------
proc rtlnet_cdc::do_reset {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances rtlnet_reset_sync] {
    incr n_inst
    set pipe [cells_in $inst {pipe_reg\[[0-9]+\]}]
    set pins [get_pins -quiet -of_objects $pipe -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
    if {[llength $pins] == 0} { fail "$inst: no pipe_reg\[*\] CLR/PRE pins"; continue }
    set_false_path -to $pins
    incr n_x [llength $pins]
  }
  set counts(reset) [list $n_inst $n_x]
}

# ---------------------------------------------------------------------------
# gray: rtlnet_gray_sync counters.
# ---------------------------------------------------------------------------
proc rtlnet_cdc::do_gray {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances rtlnet_gray_sync] {
    incr n_inst
    set src [cells_in $inst {gray_src_reg(\[[0-9]+\])?}]
    set dst [cells_in $inst {gray_dst_ff_reg\[0\](\[[0-9]+\])?}]
    if {[llength $src] == 0 || [llength $dst] == 0} { fail "$inst: gray_src_reg / gray_dst_ff_reg\[0\] not found"; continue }
    if {[bound_gray $inst $src $dst]} { incr n_x [llength $dst] }
  }
  set counts(gray) [list $n_inst $n_x]
}

# ---------------------------------------------------------------------------
# fifo: rtlnet_packet_fifo Gray frame counters and event toggles.
# ---------------------------------------------------------------------------
proc rtlnet_cdc::do_fifo {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances rtlnet_packet_fifo] {
    incr n_inst
    if {![string match "u_*_fifo" [file tail $inst]]} {
      puts "rtlnet_cdc: WARNING $inst: packet FIFO instance not named u_*_fifo"
    }
    set s_g  [cells_in $inst {s_gray_reg(\[[0-9]+\])?}]
    set s_m1 [cells_in $inst {s_gray_m1_reg(\[[0-9]+\])?}]
    set m_g  [cells_in $inst {m_gray_reg(\[[0-9]+\])?}]
    set m_s1 [cells_in $inst {m_gray_s1_reg(\[[0-9]+\])?}]
    set e_s  [cells_in $inst {events_s_reg(\[[0-9]+\])?}]
    set e_m1 [cells_in $inst {events_m1_reg(\[[0-9]+\])?}]
    if {[llength $s_g] == 0 || [llength $s_m1] == 0 || [llength $m_g] == 0 || [llength $m_s1] == 0} {
      fail "$inst: s_gray/s_gray_m1/m_gray/m_gray_s1 registers not found"; continue
    }
    if {[bound_gray $inst $s_g $s_m1]} { incr n_x [llength $s_m1] }
    if {[bound_gray $inst $m_g $m_s1]} { incr n_x [llength $m_s1] }
    if {[llength $e_s] > 0 && [llength $e_m1] > 0} {
      set per [period_of [lindex $e_s 0]]
      if {$per ne ""} {
        set_max_delay -datapath_only -from $e_s -to $e_m1 $per
        incr n_x [llength $e_m1]
      }
    }
  }
  set counts(fifo) [list $n_inst $n_x]
}

# ---------------------------------------------------------------------------
# axil_cdc: held request and response bundles.
# ---------------------------------------------------------------------------
proc rtlnet_cdc::do_axil_cdc {} {
  variable counts
  set n_inst 0
  set n_x 0
  foreach inst [instances rtlnet_axil_cdc] {
    incr n_inst
    set req [cells_in $inst {req_[a-z_]+_hold_reg(\[[0-9]+\])?}]
    set rsp [cells_in $inst {rsp_[a-z_]+_hold_reg(\[[0-9]+\])?}]
    set ack [cells_in $inst {u_ack_sync/g_bit\[0\]\.sync_ff_reg\[0\]}]
    set rqs [cells_in $inst {u_req_sync/g_bit\[0\]\.sync_ff_reg\[0\]}]
    if {[llength $req] == 0 || [llength $rsp] == 0 || [llength $ack] == 0 || [llength $rqs] == 0} {
      fail "$inst: req_*_hold / rsp_*_hold / toggle synchronizers not found"; continue
    }
    # Destination of the request bundle is m_clk (the request synchronizer's
    # clock); destination of the response bundle is s_clk.
    set m_clk [lindex [get_clocks -quiet -of_objects [get_pins $rqs/C]] 0]
    set s_clk [lindex [get_clocks -quiet -of_objects [get_pins $ack/C]] 0]
    if {$m_clk eq "" || $s_clk eq ""} { fail "$inst: clocks of the toggle synchronizers not found"; continue }
    set_max_delay -datapath_only -from $req -to $m_clk [get_property PERIOD $m_clk]
    set_max_delay -datapath_only -from $rsp -to $s_clk [get_property PERIOD $s_clk]
    incr n_x [expr {[llength $req] + [llength $rsp]}]
  }
  set counts(axil_cdc) [list $n_inst $n_x]
}

# ---------------------------------------------------------------------------
# Run every class, report, gate.
# ---------------------------------------------------------------------------
proc rtlnet_cdc::run {required} {
  variable classes
  variable counts
  variable errors
  set errors {}
  array unset counts
  foreach c $classes { do_$c }
  foreach c $classes {
    lassign $counts($c) n_inst n_x
    set req [expr {[lsearch -exact $required $c] >= 0 ? "required" : "optional"}]
    puts [format "rtlnet_cdc: %-8s instances=%-4d crossings=%-5d (%s)" $c $n_inst $n_x $req]
    if {$req eq "required" && $n_x == 0} { fail "class $c is required in this build and matched nothing" }
  }
  foreach r $required {
    if {[lsearch -exact $classes $r] < 0} { fail "unknown required class '$r'" }
  }
  set ::rtlnet_cdc_result [array get counts]
  if {[llength $errors] > 0} {
    puts "rtlnet_cdc: FAIL [llength $errors] error(s)"
    error "rtlnet_cdc: [join $errors {; }]"
  }
  puts "rtlnet_cdc: PASS"
}

if {![info exists ::rtlnet_cdc_required]} { set ::rtlnet_cdc_required $::rtlnet_cdc::classes }
rtlnet_cdc::run $::rtlnet_cdc_required
