# -----------------------------------------------------------------------------
# File: rtlnet_ddr_mig.tcl
# Purpose: generate the AMD 7-series memory controller IP (MIG, mig_7series 4.2)
#   of the RTLNet DDR3 core from rtlnet_ddr_mig.prj, into a build tree.
# Overview:
#   * Defines `rtlnet_ddr_mig_create <ip_dir> <prj_file>`; the caller has an open (or
#     in-memory) project with the part set. The procedure creates the IP
#     rtlnet_ddr_mig from the given MIG project file (the pinout, part and
#     timing of a board; the board owns it, there is no default), generates its output
#     products (global synthesis: no IP checkpoint, the controller is
#     synthesized with the top) and returns the .xci path. Nothing generated
#     is committed: the build tree <ip_dir> is recreated by every build.
#   * Example of a project file: the ip folder of the Nexys Video board (boards/nexys_video/ip/rtlnet_ddr_mig.prj),
#     the Digilent Nexys Video MIG project (board files
#     A.0 1.2: MT41K256M16, retimed to 2778 ps / 360 MHz, 4:1, 16-bit, input 100 MHz in the .prj (the wizard turns it into the 102.857 MHz the board feeds from u_mmcm2),
#     AXI, 512 MiB, pins unchanged) with five edits, documented in
#     documentation/rtlnet_ddr.md section 4: module name rtlnet_ddr_mig,
#     system clock "No Buffer", AXI data width 128 bits, AXI ID width 4 (the
#     arbiter memory-side ID, ID_W 2 + IDX_W 2, four masters), UI extra clocks disabled (UIExtraClocks 0, ui_addn_clk_* unused).
#   * The IP ports are the interface of hdl/rtlnet_ddr_amd.sv.
# Language: Vivado Tcl (2026.1).
# Revision: 11-13-2026
#   * 11-13-2026: the MIG project file is an argument of rtlnet_ddr_mig_create (the board provides it).
#   * 11-09-2026: initial version.
# Clocks: none (generation only).
# -----------------------------------------------------------------------------

proc rtlnet_ddr_mig_create {ip_dir prj} {
  if {![file exists $prj]} { error "MIG project not found: $prj" }
  file delete -force $ip_dir
  file mkdir $ip_dir
  create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 -module_name rtlnet_ddr_mig -dir $ip_dir
  set ip [get_ips rtlnet_ddr_mig]
  set_property -dict [list \
    CONFIG.XML_INPUT_FILE        [file normalize $prj] \
    CONFIG.RESET_BOARD_INTERFACE Custom \
    CONFIG.MIG_DONT_TOUCH_PARAM  Custom \
    CONFIG.BOARD_MIG_PARAM       Custom] $ip
  set xci [get_files -of_objects [get_filesets sources_1] rtlnet_ddr_mig.xci]
  set_property generate_synth_checkpoint false $xci
  generate_target all $xci
  return $xci
}
