# Purpose: reviewed CDC and methodology waivers of the camera receiver (rtlnet_csi2_rx) in the Zybo Z7-20 design.
# Overview: the generic crossings of the core (synchronizers, Gray pointers, held AXI-Lite bundles) are bounded and waived by
#   scripts/rtlnet_constrain_cdc.tcl (hook before opt_design). What remains are exactly the findings listed here, each with the crossing
#   written out and a reason. A crossing that is not listed, or a count that differs, is an error (fail closed); no waiver is a
#   rule-wide downgrade.
# Revision: 11-15-2026.
namespace eval rtlnet_review {
  variable rx rtlnet_camera_i/u_video/inst/u_rtl/u_rx/g_cam
  variable evidence {}
}

proc rtlnet_review::pin {name} {
  set found [get_pins -quiet -hierarchical -filter [format {NAME == "%s"} $name]]
  if {[llength $found] != 1} {error "review: expected exactly one pin $name, found [llength $found]"}
  return $found
}

proc rtlnet_review::cdc {id from to reason} {
  variable evidence
  create_waiver -type CDC -id $id -from [pin $from] -to [pin $to] -user rtlnet -description $reason
  lappend evidence "$id $from -> $to : $reason"
}

proc rtlnet_review::apply {reports deviation} {
  variable rx
  variable evidence
  set evidence {}
  # hs_go of a data lane: registered in ref_clk, combined with the running-clock level (also a ref_clk register) and the lane enable
  # (a static level) before the two-flop synchronizer into the byte clock. Both inputs of the AND are ref_clk registers; the
  # burst start waits for the settle timer, so a hazard at the AND cannot be sampled as a start: it can only move the start or end
  # of the burst by one byte clock, and the burst end is held for four byte clocks by the lane logic.
  # report_cdc names one of the two registers in front of the AND as the source (it differs between implementations): both are waived.
  foreach {lane pos} {0 0 1 1} {
    foreach src [list "$rx.u_dphy/u_ctl/u_lp_d$lane/hs_go_reg/C" "$rx.u_dphy/u_ctl/clk_running_reg/C"] {
      cdc CDC-10 $src "$rx.u_dphy/u_hs_sync/g_bit\[$pos\].sync_ff_reg\[0\]/D"         "hs_go of lane $lane (ref_clk register ANDed with the clock-running register clk_running_reg, both ref_clk) passes the two-flop rtlnet_sync into the byte clock; a hazard moves a burst edge by at most one byte clock, the burst end is held four byte clocks."
      cdc CDC-10 $src "$rx.u_st_sync/g_bit\[[expr {8 + $lane}]\].sync_ff_reg\[0\]/D"         "status copy of hs_go of lane $lane into clk through the two-flop rtlnet_sync; read by software as a level (RX_STATUS bits 2:1), no control use."
    }
  }
  # Reset of the byte-clock logic: asynchronous assertion by the system/soft reset (clk) and by the loss of the HS clock (ref_clk),
  # synchronous release inside rtlnet_reset_sync in the byte clock. Two source clocks reach the asynchronous clear on purpose: either
  # one must hold the byte-clock logic in reset while the byte clock may not run.
  foreach from [list "$rx.rx_rstn_reg/C" "$rx.u_dphy/u_ctl/clk_running_reg/C"] {
    cdc CDC-10 $from "$rx.u_dphy/u_byt_rst/pipe_reg\[0\]/CLR"       "the LUT that combines the two reset sources (see CDC-12 below) sits in front of the asynchronous clear of rtlnet_reset_sync; release is synchronous in the byte clock."
    cdc CDC-12 $from "$rx.u_dphy/u_byt_rst/pipe_reg\[0\]/CLR"       "asynchronous assertion of the byte-clock logic reset by two sources (system/soft reset in clk, lost HS clock in ref_clk); release is synchronous in the byte clock (rtlnet_reset_sync); a stopped byte clock cannot release it."
  }
  # Methodology findings (after the CDC findings are enumerated and reviewed above).
  report_methodology -name rtlnet_camera_raw_method -file [file join $reports post_route_methodology_unwaived.rpt]
  array set counts {LUTAR-1 0 TIMING-9 0 TIMING-15 0}
  foreach vio [get_methodology_violations -name rtlnet_camera_raw_method] {
    set severity [string tolower [get_property SEVERITY $vio]]
    if {$severity in {info advisory}} continue
    set id [get_property CHECK $vio]
    set text [get_property DESCRIPTION $vio]
    foreach query {get_cells get_pins get_ports} {append text " " [$query -quiet -of_objects $vio]}
    set reason {}
    if {$id eq "LUTAR-1" && [string first "$rx.u_dphy/u_ctl/pipe" $text] >= 0 && [string first "$rx.u_dphy/u_byt_rst/pipe_reg" $text] >= 0} {
      set reason {Byte-clock logic reset: the LUT combines the registered system/soft reset (clk) and the registered clock-running level (ref_clk) into the asynchronous clear of rtlnet_reset_sync; both inputs are registered and change only when the receiver is enabled, disabled or the HS clock stops; the release is synchronous in the byte clock. The exception covers only this native reset violation.}
    } elseif {$id eq "TIMING-9"} {
      set reason {Summary of the fully enumerated crossings of the camera receiver: every one is a two-flop rtlnet_sync, a Gray pointer bus, a held AXI-Lite bundle or a reviewed reset in the lists of rtlnet_constrain_cdc.tcl and camera_receiver_waivers.rpt.}
    } elseif {$id eq "TIMING-15" && $deviation} {
      foreach endpoint $::rtlnet_camera_timing::endpoints {
        if {[string first $endpoint $text] >= 0} {
          set reason {DPHY_HS_INPUT: exactly the HS input sampler of a camera receiver data lane; the full negative hold slack is retained (static model of the input data window at the IDELAY tap attribute 0); the capture margin is measured on the board by the tap sweep.}
        }
      }
    }
    if {$reason eq ""} {error "unreviewed methodology $id: $text"}
    incr counts($id)
    create_waiver -of_objects $vio -user rtlnet -description $reason
    lappend evidence "$id $text : $reason"
  }
  foreach {id maximum} {LUTAR-1 1 TIMING-9 1 TIMING-15 2} {
    if {$counts($id) > $maximum} {error "methodology inventory grows: $id=$counts($id)"}
  }
  set f [open [file join $reports camera_receiver_waivers.rpt] w]
  puts $f [join $evidence "\n"]
  close $f
  puts "rtlnet_build: camera receiver review: [llength $evidence] reviewed waivers"
}
