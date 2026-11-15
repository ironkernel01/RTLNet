# Purpose: register the audited transitive RTL/header set before module references.
# Overview: use generated compile order; retain production AMD RAM and shift wrappers.
# Revision: 11-15-2026.
proc rtlnet_add_sources {repo build} {
  set manifest [file join $build project_sources.tcl]
  if {![file isfile $manifest]} {error "missing preflight source manifest $manifest"}
  source $manifest
  set fileset [get_filesets sources_1]
  set_property target_language Verilog [current_project]
  set_property XPM_LIBRARIES {XPM_MEMORY XPM_CDC} [current_project]
  set dirs {}
  foreach relative $::rtlnet_project_incdirs {lappend dirs [file join $repo $relative]}
  set_property include_dirs $dirs $fileset
  set_property verilog_define $::rtlnet_project_defines $fileset
  # Register headers before any RTL is parsed by IP Integrator (one add_files call each: Vivado 12-3645).
  set headers {}
  foreach relative $::rtlnet_project_headers {
    set path [file join $repo $relative]
    if {![file isfile $path]} {error "missing project header $relative"}
    lappend headers $path
  }
  if {[llength $headers]} {
    add_files -norecurse $headers
    foreach path $headers {
      set_property FILE_TYPE {Verilog Header} [get_files $path]
      if {[file tail $path] eq "rtlnet_technology.svh"} {
        set_property IS_GLOBAL_INCLUDE true [get_files $path]
      }
    }
  }
  set rtl {}
  foreach relative $::rtlnet_project_sources {
    if {$::rtlnet_hp && [string match */hp/rtlnet_h264_hp_stub.sv $relative]} continue
    set path [file join $repo $relative]
    if {![file isfile $path]} {error "missing project RTL $relative"}
    lappend rtl $path
  }
  add_files -norecurse $rtl
  foreach path $rtl {
    set_property FILE_TYPE [expr {[file extension $path] eq ".v" ? "Verilog" : "SystemVerilog"}] [get_files $path]
  }
  update_compile_order -fileset sources_1
}
