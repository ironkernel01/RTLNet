# Purpose: apply the repository's bounded CDC constraints before implementation (own-receiver variant).
# Overview: six AXI-Lite transaction crossings (five of the reference plus the receiver's window), the receiver's byte-clock
#   crossings (Gray FIFO pointers, pulse and level synchronizers, resets) and the IRQ synchronizers.
# Revision: 11-15-2026. Initial own-receiver hook.
set rtlnet_hook_repo [file normalize [file join [file dirname [info script]] .. .. ..]]
set ::rtlnet_cdc_required {sync reset gray axil_cdc}
set ::rtlnet_cdc_expect {axil_cdc 6 sync 33 reset 3 gray 2}
# The run directory property is relative in this project layout; the hook runs inside the run directory.
set ::rtlnet_cdc_report [file join [pwd] rtlnet_cdc.rpt]
source [file join $rtlnet_hook_repo scripts rtlnet_constrain_cdc.tcl]
# opt_design's Block RAM power optimization inserts its own asynchronously cleared enable flops in front of Block RAM enables inside
# u_video; the optimization only saves power, so Block RAM cells are excluded from it (as in the reference hook).
set_power_opt -exclude_cells [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]
