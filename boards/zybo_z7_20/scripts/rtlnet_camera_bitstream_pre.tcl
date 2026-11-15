# Purpose: generate the run-owned bitstream from the exact gated checkpoint.
# Overview: the parent qualifies this checkpoint after physical optimization and waivers.
# Revision: 11-14-2026.
if {![info exists ::rtlnet_gated_checkpoint] || ![info exists ::rtlnet_gated_top]} {
  error "missing gated bitstream inputs"
}
if {![file isfile $::rtlnet_gated_checkpoint] || [file size $::rtlnet_gated_checkpoint] == 0} {
  error "missing gated checkpoint $::rtlnet_gated_checkpoint"
}
if {[current_design -quiet] ne ""} {close_design}
open_checkpoint $::rtlnet_gated_checkpoint
# A design opened from a checkpoint is named after the checkpoint; its TOP property carries the top module.
set rtlnet_dcp_top [get_property TOP [current_design]]
if {$rtlnet_dcp_top ne $::rtlnet_gated_top} {
  error "gated checkpoint top '$rtlnet_dcp_top' (design '[get_property NAME [current_design]]') does not match the implementation run top '$::rtlnet_gated_top'"
}
puts "rtlnet_build: bitstream input checkpoint $::rtlnet_gated_checkpoint"
