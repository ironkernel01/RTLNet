# Purpose: apply the repository's bounded CDC constraints before implementation.
# Overview: five complete AXI-Lite transaction crossings plus two IRQ synchronizers.
# Revision: 11-14-2026. Initial board implementation hook.
set rtlnet_hook_repo [file normalize [file join [file dirname [info script]] .. .. ..]]
set ::rtlnet_cdc_required {sync axil_cdc}
set ::rtlnet_cdc_expect {axil_cdc 5 sync 12}
# The run directory property is relative in this project layout; the hook runs inside the run directory.
set ::rtlnet_cdc_report [file join [pwd] rtlnet_cdc.rpt]
source [file join $rtlnet_hook_repo scripts rtlnet_constrain_cdc.tcl]
# opt_design's Block RAM power optimization inserts its own asynchronously cleared enable flops (cooolgate cells)
# in front of Block RAM enables inside u_video. The user-reset inventory gate forbids asynchronous resets there, and
# the optimization only saves power, so Block RAM cells are excluded from it (applies to the vendor RAMs too).
set_power_opt -exclude_cells [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]
