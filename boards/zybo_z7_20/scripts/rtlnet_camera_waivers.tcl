# Purpose: scope vendor protocol waivers to current native violation objects.
# Overview: no timing exceptions; unknown CDC/methodology findings fail closed.
# Revision: 11-14-2026.
namespace eval rtlnet_camera_review {
  variable phy rtlnet_camera_i/MIPI_D_PHY_RX_0/U0
  variable csi rtlnet_camera_i/MIPI_CSI_2_RX_0/U0
}
proc rtlnet_camera_review::property {name object} {
  if {[catch {get_property $name $object} value]} {return {}}
  return $value
}
# The vendor receiver registers aClkEnableInt and aDEnableInt(0..1) with the identical expression
# (vEnable and video_aresetn, MIPI_CSI2_Rx.vhd PPI_Clock_Enable). Synthesis merges the equal flops and keeps
# one name that depends on the surrounding netlist; exactly these three names are the same register.
proc rtlnet_camera_review::enable_source {from} {
  variable csi
  foreach name [list aClkEnableInt_reg/C "aDEnableInt_reg\[0\]/C" "aDEnableInt_reg\[1\]/C"] {
    if {$from eq "$csi/MIPI_CSI2_Rx_inst/$name"} {return 1}
  }
  return 0
}
proc rtlnet_camera_review::cdc_reason {id from to} {
  variable phy; variable csi
  if {$id eq "CDC-15" && [string first $csi/MIPI_CSI2_Rx_inst/LLP_inst/DataFIFO/U0/ $from] == 0 &&
      [string first $csi/MIPI_CSI2_Rx_inst/LLP_inst/DataFIFO/U0/ $to] == 0} {
    return {FIFO Generator AXIS asynchronous FIFO: payload is held in storage until synchronized pointer/empty control admits a read; packaged FIFO max-delay constraints remain active.}
  }
  foreach lane {0 1} {
    set base [format {%s/DataLaneGen[%d].DPHY_LaneSFEN_X} $phy $lane]
    if {$id eq "CDC-7" && $from eq "$base/cHSSettled_reg/C" &&
        $to eq "$base/HSDeserializerX/SyncAsyncSettled/oSyncStages_reg\[0\]/CLR"} {
      return {Vendor HS_SETTLE latency bridge: constant-one first stage releases into registered dLogicRst; payload validity waits for reset and the byte-alignment pipeline. No raw settled flag drives payload validity.}
    }
    if {$id eq "CDC-11" && $from eq "$phy/ClockLane/HSClockingX/SyncAsyncLocked/oSyncStages_reg\[1\]/C" &&
        $to eq "$base/RxClkActiveHSResetBridge/SyncAsyncx/oSyncStages_reg\[0\]/PRE"} {
      return {Clock-active source fans out to independent two-stage reset bridges; each destination synchronizes release on its own control clock. This is reset distribution, not reconvergent data.}
    }
    if {$id eq "CDC-10" && [enable_source $from] &&
        $to eq "$base/SyncAsyncEnable/oSyncStages_reg\[0\]/D"} {
      return {One-bit lane-enable level is combined with software-enable and IDELAYCTRL-ready, then passes a two-stage synchronizer and stop/settle FSM before HS reception. Software reset/enable changes precede sensor streaming.}
    }
  }
  if {$id eq "CDC-10" && [enable_source $from] &&
      $to eq "$phy/ClockLane/SyncAsyncEnable/oSyncStages_reg\[0\]/D"} {
    return {One-bit clock-enable level combines stable software-enable/IDELAY-ready; two-stage synchronization and the clock-lane stop/settle state machine precede reception.}
  }
  return {}
}

proc rtlnet_camera_review::context {violation} {
  set text [property DESCRIPTION $violation]
  foreach query {get_cells get_pins get_ports} {
    append text " " [$query -quiet -of_objects $violation]
  }
  return $text
}
proc rtlnet_camera_review::method_reason {id text deviation} {
  variable phy
  if {$id eq "TIMING-15" && $deviation} {
    foreach endpoint $::rtlnet_camera_timing::endpoints {
      if {[string first $endpoint $text] >= 0} {return {DPHY_HS_INPUT: exactly the reviewed HS input sampler; full negative slack is retained and hardware verification remains open. Reference configuration has no tap training.}}
    }
  }
  if {$id eq "TIMING-18"} {
    foreach lane {0 1} {
      foreach pol {n p} {
        set port [format {dphy_data_lp_%s[%d]} $pol $lane]
        if {[string first $port $text] >= 0} {
          return {This exact LP input is asynchronous to the forwarded HS clock. Vendor LP ISERDES oversamples transitions; two-stage control synchronizers and minimum-duration filters accept LP states. A synchronous input-delay value would invent a relationship.}
        }
      }
    }
  }
  if {$id eq "LUTAR-1"} {
    set driver $phy/ClockLane/SyncAsyncEnable/GenNoMMCM.cBUFR_Rst_i_1
    if {[string first $driver $text] >= 0} {
      return {Vendor clock-reset bridge: registered cBUFR_Rst and synchronized enable assert the clock-inactive reset; SyncAsyncLocked has two release stages. The exception covers only this native clock-lane reset violation.}
    }
    foreach queue {USE_BURSTS.cmd_queue USE_B_CHANNEL.cmd_b_queue} {
      set prefix rtlnet_camera_i/axi_mem_intercon_1/s00_couplers/auto_pc/inst/gen_axi4_axi3.axi3_conv_inst/USE_WRITE.write_addr_inst/$queue/inst/fifo_gen_inst/inst_fifo_gen/gconvfifo.rf/grf.rf/
      if {[string first ${prefix}rstblk/gpregsm1.curr_fwft_state\[1\]_i_2 $text] >= 0} {
        return {FIFO Generator's registered FWFT-empty/state feedback drives its own asynchronous flag initialization. This native violation is internal to the single vendor command queue; reset/read/write protocol and packaged IP remain unchanged.}
      }
    }
  }
  return {}
}

proc rtlnet_camera_review::apply {reports deviation} {
  set evidence [open [file join $reports vendor_waivers.rpt] w]
  report_cdc -details -name rtlnet_camera_raw_cdc -file [file join $reports post_route_cdc_unwaived.rpt]
  array set counts {CDC-7 0 CDC-10 0 CDC-11 0 CDC-15 0}
  foreach vio [get_cdc_violations -name rtlnet_camera_raw_cdc] {
    set severity [string tolower [property SEVERITY $vio]]
    if {$severity in {info advisory}} continue
    if {$severity ni {critical warning {critical warning}}} {error "CDC severity is unreviewed: $severity"}
    set id [property CHECK $vio]
    set from [property STARTPOINT_PIN $vio]; set to [property ENDPOINT_PIN $vio]
    set reason [cdc_reason $id $from $to]
    if {$reason eq ""} {error "unreviewed CDC $id: $from -> $to"}
    incr counts($id)
    create_waiver -of_objects $vio -user rtlnet -description $reason
    puts $evidence "$id $from -> $to : $reason"
  }
  foreach {id expected} {CDC-7 2 CDC-10 3 CDC-11 2 CDC-15 37} {
    if {$counts($id) != $expected} {error "vendor CDC inventory changes: $id=$counts($id), expected $expected"}
  }
  # The summary TIMING-9 is considered only AFTER every individual CDC finding
  # has matched its reviewed crossing and exact inventory. It has no independent
  # scope broadening; any added/changed crossing above already rejects the build.
  report_methodology -name rtlnet_camera_raw_method -file [file join $reports post_route_methodology_unwaived.rpt]
  array set method_counts {TIMING-9 0 TIMING-15 0 TIMING-18 0 LUTAR-1 0}
  foreach vio [get_methodology_violations -name rtlnet_camera_raw_method] {
    set severity [string tolower [property SEVERITY $vio]]
    if {$severity in {info advisory}} continue
    if {$severity ni {warning critical {critical warning}}} {error "methodology severity is unreviewed: $severity"}
    set id [property CHECK $vio]; set text [context $vio]
    set reason [method_reason $id $text $deviation]
    if {$id eq "TIMING-9"} {
      set reason {Summary of the fully enumerated, individually reviewed vendor CDC crossings in vendor_waivers.rpt; no unreviewed crossing is permitted.}
    }
    if {$reason eq ""} {error "unreviewed methodology $id: $text"}
    incr method_counts($id)
    create_waiver -of_objects $vio -user rtlnet -description $reason
    puts $evidence "$id $text : $reason"
  }
  foreach {id maximum} {TIMING-9 1 TIMING-15 2 TIMING-18 4 LUTAR-1 3} {
    if {$method_counts($id) > $maximum} {error "vendor methodology inventory grows: $id=$method_counts($id)"}
  }
  close $evidence
  write_waivers -force [file join $reports vendor_waivers.xdc]
}
