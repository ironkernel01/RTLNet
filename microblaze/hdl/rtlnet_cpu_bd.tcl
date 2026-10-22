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
#     compare, debug enabled), 256 KiB LMB block RAM at 0x0000_0000 for
#     instructions and data, MDM (JTAG debug, JTAG UART), AXI UART Lite
#     115200 8N1, AXI Timer, AXI INTC, the exported AXI4-Lite master
#     M_AXI_RTLNET (0x44A0_0000, 1 MiB), and the CPU network path: an AXI DMA
#     in simple (direct register) mode between the exported streams
#     S_AXIS_ETH (frames from the network, S2MM) / M_AXIS_ETH (frames to the
#     network, MM2S), 64-bit tdata with tkeep, and a 128 KiB AXI block RAM
#     (DMA buffers, lwIP pools and heap) shared by the MicroBlaze data side and
#     both DMA channels.
#   * Interconnect: axi_periph (MicroBlaze M_AXI_DP, 7 masters: UART, timer,
#     INTC, MDM, RTLNet window, DMA registers, memory path) and axi_mem
#     (3 slaves: the memory path from axi_periph, DMA MM2S, DMA S2MM; one
#     master: the AXI BRAM controller, 64-bit).
#   * Clock and reset come from outside: port `clk` (cpu_clk, 100 MHz from the
#     board MMCM) and port `resetn` (active low, already synchronous to clk).
#     No clocking wizard inside; proc_sys_reset sequences the processor, LMB
#     and peripheral resets.
#   * Interrupts: INTC inputs 0..7 = port irq[7:0] (level, active high),
#     8 = AXI Timer, 9 = UART Lite, 10 = DMA MM2S, 11 = DMA S2MM.
#   * Address map (documented in documentation/rtlnet_cpu_microblaze.md and
#     driver/rtlnet_cpu_microblaze.h; keep all three in step):
#       0x0000_0000  256 KiB  LMB BRAM (ILMB + DLMB)
#       0x4040_0000   64 KiB  AXI DMA registers
#       0x4060_0000   64 KiB  AXI UART Lite
#       0x4120_0000   64 KiB  AXI INTC
#       0x4140_0000    4 KiB  MDM (JTAG UART registers)
#       0x41C0_0000   64 KiB  AXI Timer
#       0x44A0_0000    1 MiB  M_AXI_RTLNET (RTLNet register window)
#       0xC000_0000  128 KiB  AXI BRAM (MicroBlaze data side and DMA)
#   * Cell names are part of the build interface: the MMI written by
#     write_mem_info names microblaze_0 and the lmb_bram cell; updatemem uses
#     the processor path <hier>/rtlnet_cpu_i/microblaze_0; the BSP flow
#     (microblaze/firmware/build.ps1) names microblaze_0 and finds the DMA,
#     UART, timer and INTC by their XSA instance names.
# Language: Vivado Tcl (2025.2).
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
#   * 10-22-2026: LMB 256 KiB; AXI DMA (simple mode, 64-bit streams) with the
#     exported S_AXIS_ETH / M_AXIS_ETH, 128 KiB AXI BRAM, axi_mem interconnect,
#     DMA interrupts on INTC inputs 10 and 11.
# Clocks: clk (cpu_clk 100 MHz) for every cell.
# -----------------------------------------------------------------------------

namespace eval rtlnet_cpu_bd {
  variable CPU_CLK_HZ     100000000
  variable LMB_SIZE       256K
  variable UART_BAUD      115200
  variable RTLNET_BASE    0x44A00000
  variable RTLNET_RANGE   1M
  variable DMA_BASE       0x40400000
  variable UART_BASE      0x40600000
  variable INTC_BASE      0x41200000
  variable MDM_BASE       0x41400000
  variable TIMER_BASE     0x41C00000
  variable AXI_BRAM_BASE  0xC0000000
  variable AXI_BRAM_SIZE  128K
  # DMA length register width: 2^14 - 1 = 16383 bytes per simple transfer,
  # above the 1518-byte frame and the 2 KiB buffer.
  variable DMA_LEN_W      14
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
  # Ethernet frame streams (cpu_axis_ethernet_stream, architecture 7.4):
  # 64-bit tdata, tkeep, tlast, no tuser/tid/tdest.
  set p_rx [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_ETH]
  set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES 8 \
    CONFIG.HAS_TKEEP       1 \
    CONFIG.HAS_TLAST       1 \
    CONFIG.HAS_TREADY      1 \
    CONFIG.HAS_TSTRB       0 \
    CONFIG.TUSER_WIDTH     0 \
    CONFIG.TID_WIDTH       0 \
    CONFIG.TDEST_WIDTH     0 \
    CONFIG.FREQ_HZ         $CPU_CLK_HZ] $p_rx
  set p_tx [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_ETH]
  set_property CONFIG.FREQ_HZ $CPU_CLK_HZ $p_tx
  set_property CONFIG.ASSOCIATED_BUSIF M_AXI_RTLNET:S_AXIS_ETH:M_AXIS_ETH $p_clk
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
    CONFIG.C_USE_INTERRUPT         1 \
    CONFIG.C_USE_MSR_INSTR         1 \
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

  # Tick timer (two 32-bit counters; firmware uses timer 0 free running).
  set timer [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_timer:2.0 axi_timer_0]

  # Interrupt controller, interrupt delivered on the MicroBlaze INTERRUPT bus.
  # Default (non-fast) mode: MicroBlaze jumps to the 0x10 vector, the BSP
  # handler reads the INTC IVR.
  set intc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_intc:4.1 axi_intc_0]

  # Interrupt vector: irq[7:0] at inputs 0..7, timer 8, UART 9, DMA MM2S 10,
  # DMA S2MM 11.
  set cat [create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 irq_concat]
  set_property -dict [list \
    CONFIG.NUM_PORTS 5 \
    CONFIG.IN0_WIDTH 8 \
    CONFIG.IN1_WIDTH 1 \
    CONFIG.IN2_WIDTH 1 \
    CONFIG.IN3_WIDTH 1 \
    CONFIG.IN4_WIDTH 1] $cat

  # CPU network path DMA: simple (direct register) mode, no scatter-gather,
  # 64-bit memory side and 64-bit streams, no data realignment engine
  # (buffers are 8-byte aligned), 14-bit buffer length register.
  set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
  set_property -dict [list \
    CONFIG.c_include_sg              0 \
    CONFIG.c_sg_length_width         $::rtlnet_cpu_bd::DMA_LEN_W \
    CONFIG.c_addr_width              32 \
    CONFIG.c_include_mm2s            1 \
    CONFIG.c_include_s2mm            1 \
    CONFIG.c_m_axi_mm2s_data_width   64 \
    CONFIG.c_m_axis_mm2s_tdata_width 64 \
    CONFIG.c_m_axi_s2mm_data_width   64 \
    CONFIG.c_s_axis_s2mm_tdata_width 64 \
    CONFIG.c_include_mm2s_dre        0 \
    CONFIG.c_include_s2mm_dre        0 \
    CONFIG.c_mm2s_burst_size         16 \
    CONFIG.c_s2mm_burst_size         16] $dma

  # DMA buffer memory: AXI BRAM controller (AXI4, 64-bit, single port) and its
  # block RAM; the size follows the address range (128 KiB = 32 RAMB36).
  set bctl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_0]
  set_property -dict [list \
    CONFIG.PROTOCOL         AXI4 \
    CONFIG.DATA_WIDTH       64 \
    CONFIG.SINGLE_PORT_BRAM 1 \
    CONFIG.ECC_TYPE         0] $bctl
  set dbram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 axi_bram]
  set_property -dict [list \
    CONFIG.Memory_Type    Single_Port_RAM \
    CONFIG.use_bram_block BRAM_Controller] $dbram

  # Peripheral interconnect: MicroBlaze M_AXI_DP to seven slaves.
  set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_periph]
  set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 7] $ic

  # Memory interconnect: CPU memory path and both DMA channels to the AXI
  # BRAM controller (width conversion 32 -> 64 for the CPU path inside).
  set icm [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_mem]
  set_property -dict [list CONFIG.NUM_SI 3 CONFIG.NUM_MI 1] $icm

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
  connect_bd_intf_net [get_bd_intf_pins axi_periph/M05_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
  connect_bd_intf_net [get_bd_intf_pins axi_periph/M06_AXI] [get_bd_intf_pins axi_mem/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins axi_mem/S01_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins axi_mem/S02_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_mem/M00_AXI] [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA] [get_bd_intf_pins axi_bram/BRAM_PORTA]
  connect_bd_intf_net [get_bd_intf_ports S_AXIS_ETH] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]
  connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_ports M_AXIS_ETH]

  # ---------------------------------------------------------------------------
  # Clock: every clock pin from port clk.
  # ---------------------------------------------------------------------------
  set clk_pins [list \
    microblaze_0/Clk ilmb_v10/LMB_Clk dlmb_v10/LMB_Clk \
    ilmb_bram_if_cntlr/LMB_Clk dlmb_bram_if_cntlr/LMB_Clk \
    mdm_0/S_AXI_ACLK axi_uartlite_0/s_axi_aclk axi_timer_0/s_axi_aclk axi_intc_0/s_axi_aclk \
    axi_dma_0/s_axi_lite_aclk axi_dma_0/m_axi_mm2s_aclk axi_dma_0/m_axi_s2mm_aclk \
    axi_bram_ctrl_0/s_axi_aclk \
    axi_periph/ACLK axi_periph/S00_ACLK axi_periph/M00_ACLK axi_periph/M01_ACLK \
    axi_periph/M02_ACLK axi_periph/M03_ACLK axi_periph/M04_ACLK axi_periph/M05_ACLK \
    axi_periph/M06_ACLK \
    axi_mem/ACLK axi_mem/S00_ACLK axi_mem/S01_ACLK axi_mem/S02_ACLK axi_mem/M00_ACLK \
    rst_cpu/slowest_sync_clk]
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
  connect_bd_net [get_bd_pins rst_cpu/interconnect_aresetn] [get_bd_pins axi_mem/ARESETN]
  set prst_pins [list \
    mdm_0/S_AXI_ARESETN axi_uartlite_0/s_axi_aresetn axi_timer_0/s_axi_aresetn axi_intc_0/s_axi_aresetn \
    axi_dma_0/axi_resetn axi_bram_ctrl_0/s_axi_aresetn \
    axi_periph/S00_ARESETN axi_periph/M00_ARESETN axi_periph/M01_ARESETN axi_periph/M02_ARESETN \
    axi_periph/M03_ARESETN axi_periph/M04_ARESETN axi_periph/M05_ARESETN axi_periph/M06_ARESETN \
    axi_mem/S00_ARESETN axi_mem/S01_ARESETN axi_mem/S02_ARESETN axi_mem/M00_ARESETN]
  foreach p $prst_pins { connect_bd_net [get_bd_pins rst_cpu/peripheral_aresetn] [get_bd_pins $p] }

  # ---------------------------------------------------------------------------
  # Console pins and interrupts.
  # ---------------------------------------------------------------------------
  connect_bd_intf_net [get_bd_intf_pins axi_uartlite_0/UART] [get_bd_intf_ports uart]
  connect_bd_net [get_bd_ports irq] [get_bd_pins irq_concat/In0]
  connect_bd_net [get_bd_pins axi_timer_0/interrupt] [get_bd_pins irq_concat/In1]
  connect_bd_net [get_bd_pins axi_uartlite_0/interrupt] [get_bd_pins irq_concat/In2]
  connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut] [get_bd_pins irq_concat/In3]
  connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins irq_concat/In4]
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
  assign_bd_address -offset $::rtlnet_cpu_bd::DMA_BASE -range 64K -target_address_space $dspace \
    [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg] -force
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
  foreach sp [list $dspace [get_bd_addr_spaces axi_dma_0/Data_MM2S] [get_bd_addr_spaces axi_dma_0/Data_S2MM]] {
    assign_bd_address -offset $::rtlnet_cpu_bd::AXI_BRAM_BASE -range $::rtlnet_cpu_bd::AXI_BRAM_SIZE \
      -target_address_space $sp [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0] -force
  }

  validate_bd_design
  save_bd_design
  return [get_files rtlnet_cpu.bd]
}
