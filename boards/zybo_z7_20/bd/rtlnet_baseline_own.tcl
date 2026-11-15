# Purpose: replace the Digilent camera chain and the stage 0 capture sink with the own-receiver wrapper (rtlnet_zybo_video_own).
# Overview: the vendor D-PHY, CSI-2, Bayer, gamma, VDMA and its interconnect are deleted; the wrapper contains the IronKernel
#   CSI-2 receiver (rtlnet_csi2_rx) and takes the camera pins and the 200 MHz delay reference directly. Capture HP2 and encoder HP0
#   on the one 90 MHz video clock, GP0 AXI-Lite at 50 MHz, IRQs 0/1. Sourced by the own-receiver copy of rtlnet_camera.tcl
#   that build_bitstream.tcl writes into the build folder (the vendor address assignments of the reference tail are not used).
# Revision: 11-15-2026. Initial own-receiver recipe.
delete_bd_objs [get_bd_cells MIPI_CSI_2_RX_0] [get_bd_cells MIPI_D_PHY_RX_0] [get_bd_cells AXI_BayerToRGB_1] \
  [get_bd_cells AXI_GammaCorrection_0] [get_bd_cells axi_vdma_0] [get_bd_cells axi_mem_intercon_1] [get_bd_cells rtlnet_zero]
delete_bd_objs [get_bd_intf_ports dphy_hs_clock]
# One GP0 master (the video wrapper); the former vendor register masters disappear with their cells.
set_property CONFIG.NUM_MI 1 [get_bd_cells ps7_0_axi_periph]
set_property CONFIG.PCW_USE_S_AXI_HP0 1 [get_bd_cells processing_system7_0]
create_bd_cell -type module -reference rtlnet_zybo_video_own_bd u_video
set_property -dict [list CONFIG.HIGH_PROFILE $::rtlnet_hp CONFIG.HP_T8 $::rtlnet_hp_t8 \
  CONFIG.HP_T8_AUTO $::rtlnet_hp_auto] [get_bd_cells u_video]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rtlnet_rst_encoder
connect_bd_net [get_bd_pins rtlnet_video_clock/clk_out1] [get_bd_pins rtlnet_rst_encoder/slowest_sync_clk] \
  [get_bd_pins u_video/enc_clk] [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK]
connect_bd_net [get_bd_pins rtlnet_video_clock/locked] [get_bd_pins rtlnet_rst_encoder/dcm_locked]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rtlnet_rst_encoder/ext_reset_in]
connect_bd_net [get_bd_pins rtlnet_rst_encoder/peripheral_aresetn] [get_bd_pins u_video/enc_resetn]
connect_bd_net [get_bd_pins rtlnet_video_clock/clk_out1] [get_bd_pins u_video/capture_clk]
connect_bd_net [get_bd_pins rtlnet_rst_video/peripheral_aresetn] [get_bd_pins u_video/capture_resetn]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins u_video/s_axi_aclk]
connect_bd_net [get_bd_pins rst_clk_wiz_0_50M/peripheral_aresetn] [get_bd_pins u_video/s_axi_aresetn]
# The 200 MHz output of clk_wiz_0 is the D-PHY delay reference.
connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] [get_bd_pins u_video/ref_clk]
connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI] [get_bd_intf_pins u_video/S_AXI]
connect_bd_intf_net [get_bd_intf_pins u_video/M_AXI_CAP] [get_bd_intf_pins processing_system7_0/S_AXI_HP2]
connect_bd_intf_net [get_bd_intf_pins u_video/M_AXI_ENC] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
# Camera pins: the HS clock port keeps the names of the board constraints (dphy_hs_clock_clk_p / _n).
create_bd_port -dir I dphy_hs_clock_clk_p
create_bd_port -dir I dphy_hs_clock_clk_n
foreach port {dphy_hs_clock_clk_p dphy_hs_clock_clk_n dphy_clk_lp_p dphy_clk_lp_n dphy_data_hs_p dphy_data_hs_n dphy_data_lp_p dphy_data_lp_n} {
  connect_bd_net [get_bd_ports $port] [get_bd_pins u_video/$port]
}
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 rtlnet_irqs
set_property CONFIG.NUM_PORTS 16 [get_bd_cells rtlnet_irqs]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 rtlnet_irq_zero
set_property -dict [list CONFIG.CONST_VAL 0 CONFIG.CONST_WIDTH 1] [get_bd_cells rtlnet_irq_zero]
foreach lane {0 1} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 rtlnet_irq_slice_$lane
  set_property -dict [list CONFIG.DIN_WIDTH 2 CONFIG.DIN_FROM $lane CONFIG.DIN_TO $lane CONFIG.DOUT_WIDTH 1] [get_bd_cells rtlnet_irq_slice_$lane]
  connect_bd_net [get_bd_pins u_video/irq] [get_bd_pins rtlnet_irq_slice_$lane/Din]
  connect_bd_net [get_bd_pins rtlnet_irq_slice_$lane/Dout] [get_bd_pins rtlnet_irqs/In$lane]
}
for {set lane 2} {$lane < 16} {incr lane} {
  connect_bd_net [get_bd_pins rtlnet_irq_zero/dout] [get_bd_pins rtlnet_irqs/In$lane]
}
connect_bd_net [get_bd_pins rtlnet_irqs/dout] [get_bd_pins processing_system7_0/IRQ_F2P]
set rtlnet_segs [get_bd_addr_segs -quiet -of_objects [get_bd_intf_pins u_video/S_AXI]]
puts "rtlnet_build: u_video S_AXI address segments: $rtlnet_segs"
if {[llength $rtlnet_segs] != 1} {error "expected one u_video/S_AXI address segment, found [llength $rtlnet_segs]"}
assign_bd_address -offset 0x44a00000 -range 0x00010000 $rtlnet_segs
