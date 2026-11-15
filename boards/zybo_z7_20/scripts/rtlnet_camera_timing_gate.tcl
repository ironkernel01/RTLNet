# Purpose: gate every path while recording the authorized D-PHY deviation (DPHY_HS_INPUT).
# Overview: no constraints change; only two exact DDLY endpoints qualify for deviation.
# Revision: 11-14-2026.
namespace eval rtlnet_camera_timing {
  variable endpoints {
    {rtlnet_camera_i/MIPI_D_PHY_RX_0/U0/DataLaneGen[0].DPHY_LaneSFEN_X/HSDeserializerX/Deserializer/DDLY}
    {rtlnet_camera_i/MIPI_D_PHY_RX_0/U0/DataLaneGen[1].DPHY_LaneSFEN_X/HSDeserializerX/Deserializer/DDLY}
  }
  variable limit 1000000
}

# Pure classifier also exercised by non-Vivado negative controls.
proc rtlnet_camera_timing::classify {setup hold wpws pulse_failures} {
  variable endpoints
  set excluded {}; set other_setup {}; set other_hold {}; set full_setup {}; set full_hold {}
  set failed_setup {}; set failed_hold {}
  foreach {kind rows} [list setup $setup hold $hold] {
    foreach {pin slack} $rows {
      if {![string is double -strict $slack]} {error "missing slack for $pin"}
      lappend full_$kind $slack
      if {$slack < 0} {lappend failed_$kind $pin}
      if {$pin in $endpoints} {
        if {$slack < 0} {lappend excluded $pin}
      } else {
        lappend other_$kind $slack
        if {$slack < 0} {error "unapproved $kind endpoint $pin slack $slack"}
      }
    }
  }
  foreach list_name {full_setup full_hold other_setup other_hold} {
    if {![llength [set $list_name]]} {error "no timing evidence for $list_name"}
  }
  if {![string is double -strict $wpws] || $wpws < 0 || $pulse_failures != 0} {error "pulse-width timing fails"}
  set excluded [lsort -unique $excluded]
  if {[llength $excluded] && $excluded ne [lsort $endpoints]} {error "DPHY_HS_INPUT requires exactly the two reviewed failing endpoints"}
  return [dict create deviation [expr {[llength $excluded] == 2}] \
    failed_setup [llength [lsort -unique $failed_setup]] failed_hold [llength [lsort -unique $failed_hold]] \
    full_wns [lindex [lsort -real $full_setup] 0] full_whs [lindex [lsort -real $full_hold] 0] \
    wns [lindex [lsort -real $other_setup] 0] whs [lindex [lsort -real $other_hold] 0]]
}

proc rtlnet_camera_timing::evaluate {wpws pulse_failures reports} {
  variable endpoints; variable limit
  # Compare exact NAME properties; [] in VHDL generate labels must not act as globs.
  foreach endpoint $endpoints {
    set found [get_pins -quiet -hierarchical -filter [format {NAME == "%s"} $endpoint]]
    if {[llength $found] != 1} {error "expected exactly one reviewed pin $endpoint"}
    if {[get_property REF_NAME [get_cells -of_objects $found]] ne "ISERDESE2"} {error "reviewed endpoint primitive changes"}
  }
  set evidence [open [file join $reports post_route_timing_gate_paths.rpt] w]
  foreach kind {setup hold} {
    # Enumerate one worst path per endpoint, across groups. Never filter a single
    # worst-path result after retrieval: that can conceal the next failing path.
    set paths [get_timing_paths -$kind -nworst 1 -max_paths $limit]
    if {![llength $paths] || [llength $paths] >= $limit} {error "incomplete $kind timing enumeration"}
    set rows {}; set minimum {}; set seen {}
    foreach path $paths {
      set pin [get_property ENDPOINT_PIN $path]
      set slack [get_property SLACK $path]
      lappend seen $pin
      lappend rows $pin $slack
      if {$minimum eq "" || $slack < $minimum} {set minimum $slack}
      puts $evidence "$kind $slack $pin"
    }
    foreach endpoint $endpoints {
      if {$endpoint ni $seen} {error "missing constrained $kind path to $endpoint"}
    }
    set global_slack [get_property SLACK [get_timing_paths -$kind -max_paths 1]]
    if {abs($minimum - $global_slack) > 0.001} {error "enumeration misses global $kind minimum"}
    set $kind $rows
  }
  close $evidence
  return [classify $setup $hold $wpws $pulse_failures]
}

# Own receiver (rtlnet_csi2_rx): the reviewed endpoints are the two ISERDESE2 DDLY pins of its data lanes. The IDELAYE2 tap is loaded at
# run time (RX_TAPS), so static timing sees the tap of the primitive attribute (0); a failing endpoint is the same named deviation
# DPHY_HS_INPUT, and the run-time measurement (tap sweep) is the evidence that static timing cannot give.
proc rtlnet_camera_timing::use_own_endpoints {} {
  variable endpoints
  set cells [get_cells -quiet -hierarchical -filter {REF_NAME == ISERDESE2}]
  set found {}
  foreach pin [get_pins -quiet -of_objects $cells -filter {REF_PIN_NAME == DDLY}] {lappend found [get_property NAME $pin]}
  if {[llength $found] != 2} {error "own receiver: expected two ISERDESE2 DDLY pins, found [llength $found]"}
  set endpoints [lsort $found]
  puts "rtlnet_build: own receiver timing endpoints: $endpoints"
}
