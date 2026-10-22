# -----------------------------------------------------------------------------
# File: rtlnet_cpu_bd.tcl
# Purpose: create the MicroBlaze block design `rtlnet_cpu` by script, the one
#   AMD-only block of RTLNet, hidden inside the CPU core rtlnet_cpu_microblaze.
# Overview:
#   * Defines `rtlnet_cpu_bd_create <bd_dir>`; the caller has an open (or
#     in-memory) project with the part set. The procedure creates the design
#     under <bd_dir>, validates and saves it, and returns the .bd file path.
#   * Contents: classic MicroBlaze 11.0 (32-bit, little endian, no MMU, no
#     caches, no FPU, barrel shifter, hardware multiplier and divider, pattern
#     compare, debug enabled), 128 KiB LMB block RAM at 0x0000_0000 for
#     instructions and data, MDM (JTAG debug, JTAG UART), AXI UART Lite
#     115200 8N1, AXI Timer, AXI INTC, one AXI interconnect and the exported
#     AXI4-Lite master M_AXI_RTLNET (0x44A0_0000, 1 MiB).
#   * Clock and reset come from outside: port `clk` (cpu_clk, 100 MHz from the
#     board MMCM) and port `resetn` (active low, already synchronous to clk).
#     No clocking wizard inside; proc_sys_reset sequences the processor, LMB
#     and peripheral resets.
#   * Interrupts: INTC inputs 0..7 = port irq[7:0] (level, active high),
#     8 = AXI Timer, 9 = UART Lite.
#   * Address map (documented in documentation/rtlnet_cpu_microblaze.md and
#     microblaze/firmware/src/rtlnet_platform.h; keep all three in step):
#       0x0000_0000  128 KiB  LMB BRAM (ILMB + DLMB)
#       0x4060_0000   64 KiB  AXI UART Lite
#       0x4120_0000   64 KiB  AXI INTC
#       0x4140_0000    4 KiB  MDM (JTAG UART registers)
#       0x41C0_0000   64 KiB  AXI Timer
#       0x44A0_0000    1 MiB  M_AXI_RTLNET (RTLNet register window)
#   * Cell names are part of the build interface: the MMI written by
#     write_mem_info names microblaze_0 and the lmb_bram cell; updatemem uses
#     the processor path <hier>/rtlnet_cpu_i/microblaze_0.
# Language: Vivado Tcl (2025.2).
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# Clocks: clk (cpu_clk 100 MHz) for every cell.
# -----------------------------------------------------------------------------

namespace eval rtlnet_cpu_bd {
  variable CPU_CLK_HZ     100000000
  variable LMB_SIZE       128K
  variable UART_BAUD      115200
  variable RTLNET_BASE    0x44A00000
  variable RTLNET_RANGE   1M
  variable UART_BASE      0x40600000
  variable INTC_BASE      0x41200000
  variable MDM_BASE       0x41400000
  variable TIMER_BASE     0x41C00000
}

proc rtlnet_cpu_bd_create {bd_dir} {
  set CPU_CLK_HZ   $::rtlnet_cpu_bd::CPU_CLK_HZ

  create_bd_design -dir $bd_dir rtlnet_cpu
  current_bd_design rtlnet_cpu

  # ---------------------------------------------------------------------------
  # External ports: the vendor-neutral boundary of architecture section 15.6.
  # ---------------------------------------------------------------------------
  set p_clk [create_bd_port -dir I -type clk -freq_hz $CPU_CLK_HZ clk]
  set p_rst [create_bd_port -dir I -type rst resetn]
  set_property CONFIG.POLARITY ACTIVE_LOW $p_rst
  # UART interface port `uart`: the generated wrapper names its pins uart_rxd
  # (input, from the USB-UART bridge) and uart_txd (output, to it).
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:uart_rtl:1.0 uart
  set p_irq [create_bd_port -dir I -from 7 -to 0 -type intr irq]
  set_property CONFIG.SENSITIVITY LEVEL_HIGH $p_irq
  set p_m [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_RTLNET]
  set_property -dict [list \
    CONFIG.PROTOCOL   AXI4LITE \
    CONFIG.ADDR_WIDTH 32 \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.HAS_PROT   0 \
    CONFIG.FREQ_HZ    $CPU_CLK_HZ] $p_m
  set_property CONFIG.ASSOCIATED_BUSIF M_AXI_RTLNET $p_clk
  set_property CONFIG.ASSOCIATED_RESET resetn $p_clk

  # ---------------------------------------------------------------------------
  # Processor: classic MicroBlaze, microcontroller-class configuration.
  # C_AREA_OPTIMIZED 0 = 5-stage pipeline. Bus exceptions stay disabled, so a
  # DECERR from an unmapped RTLNet address reads as data and never traps.
  # ---------------------------------------------------------------------------
  set mb [create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze:11.0 microblaze_0]
  set_property -dict [list \
    CONFIG.C_AREA_OPTIMIZED        0 \
    CONFIG.C_USE_BARREL            1 \
    CONFIG.C_USE_HW_MUL            1 \
    CONFIG.C_USE_DIV               1 \
    CONFIG.C_USE_PCMP_INSTR        1 \
    CONFIG.C_USE_FPU               0 \
    CONFIG.C_USE_MMU               0 \
    CONFIG.C_USE_ICACHE            0 \
    CONFIG.C_USE_DCACHE            0 \
    CONFIG.C_USE_BRANCH_TARGET_CACHE 0 \
    CONFIG.C_DEBUG_ENABLED         1 \
    CONFIG.C_D_AXI                 1 \
    CONFIG.C_D_LMB                 1 \
    CONFIG.C_I_LMB                 1 \
    CONFIG.C_I_AXI                 0 \
    CONFIG.C_USE_INTERRUPT         1     CONFIG.C_USE_MSR_INSTR         1 \
    CONFIG.C_M_AXI_D_BUS_EXCEPTION 0 \
    CONFIG.C_BASE_VECTORS          0x00000000] $mb

  # Local memory: two LMB buses, two BRAM interface controllers, one true
  # dual-port block RAM (port A instruction side, port B data side).
  set ilmb [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 ilmb_v10]
  set dlmb [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 dlmb_v10]
  set ictl [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 ilmb_bram_if_cntlr]
  set dctl [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 dlmb_bram_if_cntlr]
  set_property CONFIG.C_ECC 0 $ictl
  set_property CONFIG.C_ECC 0 $dctl
  set bram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 lmb_bram]
  set_property -dict [list \
    CONFIG.Memory_Type     True_Dual_Port_RAM \
    CONFIG.use_bram_block  BRAM_Controller \
    CONFIG.Enable_B        Use_ENB_Pin \
    CONFIG.Use_RSTB_Pin    true] $bram

  # Debug module: one MicroBlaze debug port, JTAG UART enabled (AXI slave).
  set mdm [create_bd_cell -type ip -vlnv xilinx.com:ip:mdm:3.2 mdm_0]
  set_property -dict [list CONFIG.C_MB_DBG_PORTS 1 CONFIG.C_USE_UART 1] $mdm

  # Console UART: 115200 baud, 8 data bits, no parity, 1 stop bit.
  set uart [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 axi_uartlite_0]
  set_property -dict [list \
    CONFIG.C_BAUDRATE   $::rtlnet_cpu_bd::UART_BAUD \
    CONFIG.C_DATA_BITS  8 \
    CONFIG.C_USE_PARITY 0] $uart

  # Free-running tick timer (two 32-bit counters, firmware uses timer 0).
  set timer [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer:2.0 axi_timer_0]

  # Interrupt controller, interrupt delivered on the MicroBlaze INTERRUPT bus.
  # Default (non-fast) mode: MicroBlaze jumps to the 0x10 vector, firmware
  # reads the INTC IVR.
  set intc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc_0]

  # Interrupt vector: irq[7:0] at inputs 0..7, timer at 8, UART at 9.
  set cat [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 irq_concat]
  set_property -dict [list \
    CONFIG.NUM_PORTS 3 \
    CONFIG.IN0_WIDTH 8 \
    CONFIG.IN1_WIDTH 1 \
    CONFIG.IN2_WIDTH 1] $cat

  # Peripheral interconnect: MicroBlaze M_AXI_DP to five AXI4-Lite slaves.
  set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_periph]
  set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 5] $ic

  # Reset sequencer: external resetn (active low) plus the MDM debug reset.
  # The ext_reset_in polarity follows the resetn port (POLARITY ACTIVE_LOW).
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_cpu
  set one [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_one]
  set_property -dict [list CONFIG.CONST_WIDTH 1 CONFIG.CONST_VAL 1] $one

  # ---------------------------------------------------------------------------
  # Interface connections.
  # ---------------------------------------------------------------------------
  connect_bd_intf_net [get_bd_intf_pins microblaze_0/ILMB] [get_bd_intf_pins ilmb_v10/LMB_M]
  connect_bd_intf_net [get_bd_intf_pins microblaze_0/DLMB] [get_bd_intf_pins dlmb_v10/LMB_M]
  connect_bd_intf_net [get_bd_intf_pins ilmb_v10/LMB_Sl_0] [get_bd_intf_pins ilmb_bram_if_cntlr/SLMB]
  connect_bd_intf_net [get_bd_intf_pins dlmb_v10/LMB_Sl_0] [get_bd_intf_pins dlmb_bram_if_cntlr/SLMB]
  connect_bd_intf_net [get_bd_intf_pins ilmb_bram_if_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTA]
  connect_bd_intf_net [get_bd_intf_pins dlmb_bram_if_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTB]
  connect_bd_intf_net [get_bd_intf_pins mdm_0/MBDEBUG_0] [get_bd_intf_pins microblaze_0/DEBUG]
  connect_bd_intf_net [get_bd_intf_pins axi_intc_0/interrupt] [get_bd_intf_pins microblaze_0/INTERRUPT]
  connect_bd_intf_net [get_bd_intf_pins microblaze_0/M_AXI_DP] [get_bd_intf_pins axi_periph/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph/M00_AXI] [get_bd_intf_pins axi_uartlite_0/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph/M01_AXI] [get_bd_intf_pins axi_timer_0/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph/M02_AXI] [get_bd_intf_pins axi_intc_0/s_axi]
  connect_bd_intf_net [get_bd_intf_pins axi_periph/M03_AXI] [get_bd_intf_pins mdm_0/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_periph/M04_AXI] [get_bd_intf_ports M_AXI_RTLNET]

  # ---------------------------------------------------------------------------
  # Clock: every clock pin from port clk.
  # ---------------------------------------------------------------------------
  set clk_pins [list \
    microblaze_0/Clk ilmb_v10/LMB_Clk dlmb_v10/LMB_Clk \
    ilmb_bram_if_cntlr/LMB_Clk dlmb_bram_if_cntlr/LMB_Clk \
    mdm_0/S_AXI_ACLK axi_uartlite_0/s_axi_aclk axi_timer_0/s_axi_aclk axi_intc_0/s_axi_aclk \
    axi_periph/ACLK axi_periph/S00_ACLK axi_periph/M00_ACLK axi_periph/M01_ACLK \
    axi_periph/M02_ACLK axi_periph/M03_ACLK axi_periph/M04_ACLK rst_cpu/slowest_sync_clk]
  foreach p $clk_pins { connect_bd_net [get_bd_ports clk] [get_bd_pins $p] }
  set intc_pclk [get_bd_pins -quiet axi_intc_0/processor_clk]
  if {$intc_pclk ne ""} { connect_bd_net [get_bd_ports clk] $intc_pclk }

  # ---------------------------------------------------------------------------
  # Resets from proc_sys_reset.
  # ---------------------------------------------------------------------------
  connect_bd_net [get_bd_ports resetn] [get_bd_pins rst_cpu/ext_reset_in]
  connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins rst_cpu/dcm_locked]
  connect_bd_net [get_bd_pins mdm_0/Debug_SYS_Rst] [get_bd_pins rst_cpu/mb_debug_sys_rst]
  connect_bd_net [get_bd_pins rst_cpu/mb_reset] [get_bd_pins microblaze_0/Reset]
  set intc_prst [get_bd_pins -quiet axi_intc_0/processor_rst]
  if {$intc_prst ne ""} { connect_bd_net [get_bd_pins rst_cpu/mb_reset] $intc_prst }
  foreach p {ilmb_v10/SYS_Rst dlmb_v10/SYS_Rst ilmb_bram_if_cntlr/LMB_Rst dlmb_bram_if_cntlr/LMB_Rst} {
    connect_bd_net [get_bd_pins rst_cpu/bus_struct_reset] [get_bd_pins $p]
  }
  connect_bd_net [get_bd_pins rst_cpu/interconnect_aresetn] [get_bd_pins axi_periph/ARESETN]
  set prst_pins [list \
    mdm_0/S_AXI_ARESETN axi_uartlite_0/s_axi_aresetn axi_timer_0/s_axi_aresetn axi_intc_0/s_axi_aresetn \
    axi_periph/S00_ARESETN axi_periph/M00_ARESETN axi_periph/M01_ARESETN axi_periph/M02_ARESETN \
    axi_periph/M03_ARESETN axi_periph/M04_ARESETN]
  foreach p $prst_pins { connect_bd_net [get_bd_pins rst_cpu/peripheral_aresetn] [get_bd_pins $p] }

  # ---------------------------------------------------------------------------
  # Console pins and interrupts.
  # ---------------------------------------------------------------------------
  connect_bd_intf_net [get_bd_intf_pins axi_uartlite_0/UART] [get_bd_intf_ports uart]
  connect_bd_net [get_bd_ports irq] [get_bd_pins irq_concat/In0]
  connect_bd_net [get_bd_pins axi_timer_0/interrupt] [get_bd_pins irq_concat/In1]
  connect_bd_net [get_bd_pins axi_uartlite_0/interrupt] [get_bd_pins irq_concat/In2]
  connect_bd_net [get_bd_pins irq_concat/dout] [get_bd_pins axi_intc_0/intr]

  # ---------------------------------------------------------------------------
  # Address map.
  # ---------------------------------------------------------------------------
  set dspace [get_bd_addr_spaces microblaze_0/Data]
  set ispace [get_bd_addr_spaces microblaze_0/Instruction]
  assign_bd_address -offset 0x00000000 -range $::rtlnet_cpu_bd::LMB_SIZE -target_address_space $dspace \
    [get_bd_addr_segs dlmb_bram_if_cntlr/SLMB/Mem] -force
  assign_bd_address -offset 0x00000000 -range $::rtlnet_cpu_bd::LMB_SIZE -target_address_space $ispace \
    [get_bd_addr_segs ilmb_bram_if_cntlr/SLMB/Mem] -force
  assign_bd_address -offset $::rtlnet_cpu_bd::UART_BASE -range 64K -target_address_space $dspace \
    [get_bd_addr_segs axi_uartlite_0/S_AXI/Reg] -force
  assign_bd_address -offset $::rtlnet_cpu_bd::INTC_BASE -range 64K -target_address_space $dspace \
    [get_bd_addr_segs axi_intc_0/S_AXI/Reg] -force
  assign_bd_address -offset $::rtlnet_cpu_bd::MDM_BASE -range 4K -target_address_space $dspace \
    [get_bd_addr_segs mdm_0/S_AXI/Reg] -force
  assign_bd_address -offset $::rtlnet_cpu_bd::TIMER_BASE -range 64K -target_address_space $dspace \
    [get_bd_addr_segs axi_timer_0/S_AXI/Reg] -force
  assign_bd_address -offset $::rtlnet_cpu_bd::RTLNET_BASE -range $::rtlnet_cpu_bd::RTLNET_RANGE \
    -target_address_space $dspace [get_bd_addr_segs M_AXI_RTLNET/Reg] -force

  validate_bd_design
  save_bd_design
  return [get_files rtlnet_cpu.bd]
}
