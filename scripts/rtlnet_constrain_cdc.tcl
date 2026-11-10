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
#   fifo      rtlnet_packet_fifo (instances u_*_fifo): the RAM data path (RAM cells -> read data registers,
#             set_max_delay -datapath_only of the destination period), s_gray -> s_gray_m1 and
#             m_gray -> m_gray_s1 as for gray; the event toggles
#             events_s -> events_m1 set_max_delay -datapath_only of one source
#             period.
#   axil_cdc  rtlnet_axil_cdc: req_*_hold (to m_clk) and rsp_*_hold (to s_clk)
#             bundles, set_max_delay -datapath_only of the destination period.
#   report_cdc cannot recognize a Gray-coded bus (CDC-6) or a held bundle
#   (CDC-1, CDC-15); for exactly those registers of each instance the script
#   creates native report_cdc waivers (create_waiver -type CDC) with the
#   protocol as the reason, so report_cdc lists them as waived and any other
#   finding still shows.
# Usage (after synth_design or open_checkpoint of a synthesized design):
#   set ::rtlnet_cdc_required {sync reset}      ;# classes this build must contain
#   set ::rtlnet_cdc_expect   {fifo 7 axil_cdc 3} ;# optional: exact instance counts
#   set ::rtlnet_cdc_report   <file>             ;# optional: one line per instance
#   source scripts/rtlnet_constrain_cdc.tcl
#   The script prints one line per class, `rtlnet_cdc: <class> instances=<n>
#   crossings=<m>`, and `rtlnet_cdc: PASS` or `rtlnet_cdc: FAIL ...`; it
#   raises a Tcl error (the build turns it into an exit code) when a required
#   class has zero matches, or when an instance of a module lacks the cells the
#   constraint names (a renamed register would otherwise lose its constraint
#   silently), or when a class listed in ::rtlnet_cdc_expect has another
#   instance count than expected (a crossing lost or added by a design change
#   must be reviewed). ::rtlnet_cdc_result holds the per-class counts.
#   Default required classes: all five.
# Revision: 11-09-2026
#   * 11-09-2026: rtlnet_axil_cdc cells live in generate block g_cdc (SYNC parameter): the name patterns accept the prefix.
#   * 11-09-2026: packet FIFO RAM data path bounded (datapath_only, destination period); needed once cpu_clk and enc_clk (90 MHz)
#     differ from ui_clk (100 MHz).
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------

namespace eval rtlnet_cdc {
  variable classes {sync reset gray fifo axil_cdc}
  variable errors  {}
  variable counts
  array set counts {}
  variable detail {}
  variable waivers 0
}

proc rtlnet_cdc::note {class inst n} {
  variable detail
  lappend detail [format "%-8s %4d  %s" $class $n $inst]
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
  waive {CDC-6} $inst $src $dst \
    "rtlnet Gray crossing: one bit changes per source clock; bounded by max delay and bus skew of one source period (rtlnet_common.md section 4)"
  return 1
}

# Native report_cdc waiver for the findings report_cdc raises on a crossing
# whose protocol it cannot recognize (Gray-coded buses, held bundles). Scope:
# from the source registers' clock pins to the destination cells' input pins
# of this one instance only; every waiver carries its reason. Vivado lists the
# waived endpoints in report_cdc, so nothing is hidden.
proc rtlnet_cdc::waive {ids inst from_cells to_cells reason} {
  variable waivers
  set from [get_pins -quiet -of_objects $from_cells -filter {REF_PIN_NAME == C}]
  set to   [get_pins -quiet -of_objects $to_cells -filter {DIRECTION == IN && IS_CLOCK == 0}]
  if {[llength $from] == 0 || [llength $to] == 0} { fail "$inst: no pins for the $ids waiver"; return }
  foreach id $ids {
    if {[catch {create_waiver -type CDC -id $id -from $from -to $to -user rtlnet -description "$inst: $reason"} err]} {
      fail "$inst: create_waiver $id: $err"
    } else {
      incr waivers
    }
  }
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
    note sync $inst [llength $first]
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
    note reset $inst [llength $pins]
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
    if {[bound_gray $inst $src $dst]} { incr n_x [llength $dst]; note gray $inst [llength $dst] }
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
        waive {CDC-6} $inst $e_s $e_m1 \
          "rtlnet packet FIFO event toggles: independent single-bit toggles (overflow, bad frame), each synchronized, bounded by one source period"
        incr n_x [llength $e_m1]
      }
    }
    # RAM data crossing: the FIFO storage is written in s_clk and read in m_clk. A word is read only after its Gray pointer has
    # crossed (two or more destination clocks after the write), so the RAM-to-read-register path is bounded by one destination
    # period with set_max_delay -datapath_only, like the Gray bundles. Without it Vivado times the path between the two clocks
    # as if they were related (equal periods hid the missing constraint while cpu_clk and ui_clk were both 100 MHz).
    set ram  [get_cells -quiet -hierarchical -filter "REF_NAME =~ RAM* && NAME =~ [string map {[ \[ ] \]} $inst]/u_ram/*"]
    set rreg [get_cells -quiet -hierarchical -filter "IS_SEQUENTIAL == 1 && NAME =~ [string map {[ \[ ] \]} $inst]/u_ram/*doutb_reg*"]
    if {[llength $ram] > 0 && [llength $rreg] > 0} {
      set per [period_of [lindex $rreg 0]]
      if {$per ne ""} {
        set_max_delay -datapath_only -from $ram -to $rreg $per
        incr n_x [llength $rreg]
      }
    }
    note fifo $inst [expr {[llength $s_m1] + [llength $m_s1] + [llength $e_m1]}]
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
    # SYNC = 1 instance: a pass-through with no flop, so there is no crossing to constrain or count.
    if {[llength [cells_in $inst {.*}]] == 0} {
      puts "rtlnet_cdc: $inst is a SYNC pass-through (no clock crossing), not counted"
      continue
    }
    incr n_inst
    set req [cells_in $inst {(g_cdc\.)?req_[a-z_]+_hold_reg(\[[0-9]+\])?}]
    set rsp [cells_in $inst {(g_cdc\.)?rsp_[a-z_]+_hold_reg(\[[0-9]+\])?}]
    set ack [cells_in $inst {(g_cdc\.)?u_ack_sync/g_bit\[0\]\.sync_ff_reg\[0\]}]
    set rqs [cells_in $inst {(g_cdc\.)?u_req_sync/g_bit\[0\]\.sync_ff_reg\[0\]}]
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
    set all [cells_in $inst {.*}]
    waive {CDC-1 CDC-15} $inst [concat $req $rsp] $all \
      "rtlnet_axil_cdc held bundle: req_*_hold/rsp_*_hold stay constant while the toggle crosses through rtlnet_sync and are read only after the synchronized toggle edge; bounded by max delay of the destination period (rtlnet_common.md section 4)"
    incr n_x [expr {[llength $req] + [llength $rsp]}]
    note axil_cdc $inst [expr {[llength $req] + [llength $rsp]}]
  }
  set counts(axil_cdc) [list $n_inst $n_x]
}

# ---------------------------------------------------------------------------
# Run every class, report, gate.
# ---------------------------------------------------------------------------
proc rtlnet_cdc::run {required expect} {
  variable classes
  variable counts
  variable errors
  variable detail
  variable waivers
  set errors {}
  set detail {}
  set waivers 0
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
  foreach {c n} $expect {
    if {![info exists counts($c)]} { fail "unknown expected class '$c'"; continue }
    set got [lindex $counts($c) 0]
    if {$got != $n} { fail "class $c has $got instances, expected $n" } else { puts "rtlnet_cdc: $c instance count $got as expected" }
  }
  if {[info exists ::rtlnet_cdc_report]} {
    set fh [open $::rtlnet_cdc_report w]
    puts $fh "# class  constrained-cells  instance"
    foreach l $detail { puts $fh $l }
    close $fh
  }
  puts "rtlnet_cdc: $waivers report_cdc waiver(s) created (Gray buses, FIFO event toggles, held bundles)"
  set ::rtlnet_cdc_result [array get counts]
  if {[llength $errors] > 0} {
    puts "rtlnet_cdc: FAIL [llength $errors] error(s)"
    error "rtlnet_cdc: [join $errors {; }]"
  }
  puts "rtlnet_cdc: PASS"
}

if {![info exists ::rtlnet_cdc_required]} { set ::rtlnet_cdc_required $::rtlnet_cdc::classes }
if {![info exists ::rtlnet_cdc_expect]} { set ::rtlnet_cdc_expect {} }
rtlnet_cdc::run $::rtlnet_cdc_required $::rtlnet_cdc_expect
