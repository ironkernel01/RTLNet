# Purpose: reconstruct the camera-only BD in the installed Vivado.
# Overview: generated from the published BD data; display path is absent.
# Revision: 11-14-2026.
create_bd_design rtlnet_camera
create_bd_intf_port -mode Master -vlnv {xilinx.com:interface:ddrx_rtl:1.0} DDR
create_bd_intf_port -mode Master -vlnv {xilinx.com:display_processing_system7:fixedio_rtl:1.0} FIXED_IO
create_bd_intf_port -mode Master -vlnv {xilinx.com:interface:gpio_rtl:1.0} cam_gpio
create_bd_intf_port -mode Master -vlnv {xilinx.com:interface:iic_rtl:1.0} cam_iic
create_bd_intf_port -mode Slave -vlnv {xilinx.com:interface:diff_clock_rtl:1.0} dphy_hs_clock
set_property CONFIG.FREQ_HZ 210000000 [get_bd_intf_ports dphy_hs_clock]
create_bd_port -dir I dphy_clk_lp_n
create_bd_port -dir I dphy_clk_lp_p
create_bd_port -dir I -from 1 -to 0 dphy_data_hs_n
create_bd_port -dir I -from 1 -to 0 dphy_data_hs_p
create_bd_port -dir I -from 1 -to 0 dphy_data_lp_n
create_bd_port -dir I -from 1 -to 0 dphy_data_lp_p
create_bd_cell -type ip -vlnv {digilentinc.com:user:AXI_BayerToRGB:1.0} AXI_BayerToRGB_1
create_bd_cell -type ip -vlnv {digilentinc.com:user:AXI_GammaCorrection:1.0} AXI_GammaCorrection_0
create_bd_cell -type ip -vlnv {digilentinc.com:ip:MIPI_CSI_2_RX:1.2} MIPI_CSI_2_RX_0
set_property -dict [list \
  CONFIG.kDebug {false} \
  CONFIG.kGenerateAXIL {true} \
] [get_bd_cells MIPI_CSI_2_RX_0]
create_bd_cell -type ip -vlnv {digilentinc.com:ip:MIPI_D_PHY_RX:1.3} MIPI_D_PHY_RX_0
set_property -dict [list \
  CONFIG.kDebug {false} \
  CONFIG.kGenerateAXIL {true} \
  CONFIG.kLPFromLane0 {false} \
  CONFIG.kNoOfDataLanes {2} \
] [get_bd_cells MIPI_D_PHY_RX_0]
create_bd_cell -type ip -vlnv {xilinx.com:ip:processing_system7:5.5} processing_system7_0
set_property -dict [list \
  CONFIG.PCW_ACT_APU_PERIPHERAL_FREQMHZ {666.666687} \
  CONFIG.PCW_ACT_CAN0_PERIPHERAL_FREQMHZ {23.8095} \
  CONFIG.PCW_ACT_CAN1_PERIPHERAL_FREQMHZ {23.8095} \
  CONFIG.PCW_ACT_CAN_PERIPHERAL_FREQMHZ {10.000000} \
  CONFIG.PCW_ACT_DCI_PERIPHERAL_FREQMHZ {10.158730} \
  CONFIG.PCW_ACT_ENET0_PERIPHERAL_FREQMHZ {125.000000} \
  CONFIG.PCW_ACT_ENET1_PERIPHERAL_FREQMHZ {10.000000} \
  CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
  CONFIG.PCW_ACT_FPGA1_PERIPHERAL_FREQMHZ {10.000000} \
  CONFIG.PCW_ACT_FPGA2_PERIPHERAL_FREQMHZ {10.000000} \
  CONFIG.PCW_ACT_FPGA3_PERIPHERAL_FREQMHZ {10.000000} \
  CONFIG.PCW_ACT_I2C_PERIPHERAL_FREQMHZ {50} \
  CONFIG.PCW_ACT_PCAP_PERIPHERAL_FREQMHZ {200.000000} \
  CONFIG.PCW_ACT_QSPI_PERIPHERAL_FREQMHZ {200.000000} \
  CONFIG.PCW_ACT_SDIO_PERIPHERAL_FREQMHZ {100.000000} \
  CONFIG.PCW_ACT_SMC_PERIPHERAL_FREQMHZ {10.000000} \
  CONFIG.PCW_ACT_SPI_PERIPHERAL_FREQMHZ {10.000000} \
  CONFIG.PCW_ACT_TPIU_PERIPHERAL_FREQMHZ {200.000000} \
  CONFIG.PCW_ACT_TTC0_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
  CONFIG.PCW_ACT_TTC0_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
  CONFIG.PCW_ACT_TTC0_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
  CONFIG.PCW_ACT_TTC1_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
  CONFIG.PCW_ACT_TTC1_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
  CONFIG.PCW_ACT_TTC1_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
  CONFIG.PCW_ACT_TTC_PERIPHERAL_FREQMHZ {50} \
  CONFIG.PCW_ACT_UART_PERIPHERAL_FREQMHZ {100.000000} \
  CONFIG.PCW_ACT_USB0_PERIPHERAL_FREQMHZ {60} \
  CONFIG.PCW_ACT_USB1_PERIPHERAL_FREQMHZ {60} \
  CONFIG.PCW_ACT_WDT_PERIPHERAL_FREQMHZ {111.111115} \
  CONFIG.PCW_APU_CLK_RATIO_ENABLE {6:2:1} \
  CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {666.666666} \
  CONFIG.PCW_CAN0_PERIPHERAL_CLKSRC {External} \
  CONFIG.PCW_CAN0_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_CAN1_PERIPHERAL_CLKSRC {External} \
  CONFIG.PCW_CAN1_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_CAN_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_CAN_PERIPHERAL_VALID {0} \
  CONFIG.PCW_CLK0_FREQ {100000000} \
  CONFIG.PCW_CLK1_FREQ {10000000} \
  CONFIG.PCW_CLK2_FREQ {10000000} \
  CONFIG.PCW_CLK3_FREQ {10000000} \
  CONFIG.PCW_CORE0_FIQ_INTR {0} \
  CONFIG.PCW_CORE0_IRQ_INTR {0} \
  CONFIG.PCW_CORE1_FIQ_INTR {0} \
  CONFIG.PCW_CORE1_IRQ_INTR {0} \
  CONFIG.PCW_CPU_CPU_6X4X_MAX_RANGE {667} \
  CONFIG.PCW_CPU_PERIPHERAL_CLKSRC {ARM PLL} \
  CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
  CONFIG.PCW_DCI_PERIPHERAL_CLKSRC {DDR PLL} \
  CONFIG.PCW_DCI_PERIPHERAL_FREQMHZ {10.159} \
  CONFIG.PCW_DDR_PERIPHERAL_CLKSRC {DDR PLL} \
  CONFIG.PCW_DDR_RAM_BASEADDR {0x00100000} \
  CONFIG.PCW_DDR_RAM_HIGHADDR {0x3FFFFFFF} \
  CONFIG.PCW_DM_WIDTH {4} \
  CONFIG.PCW_DQS_WIDTH {4} \
  CONFIG.PCW_DQ_WIDTH {32} \
  CONFIG.PCW_ENET0_BASEADDR {0xE000B000} \
  CONFIG.PCW_ENET0_ENET0_IO {MIO 16 .. 27} \
  CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
  CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53} \
  CONFIG.PCW_ENET0_HIGHADDR {0xE000BFFF} \
  CONFIG.PCW_ENET0_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
  CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ {1000 Mbps} \
  CONFIG.PCW_ENET1_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_ENET1_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_ENET_RESET_ENABLE {0} \
  CONFIG.PCW_ENET_RESET_POLARITY {Active Low} \
  CONFIG.PCW_EN_4K_TIMER {0} \
  CONFIG.PCW_EN_CAN0 {0} \
  CONFIG.PCW_EN_CAN1 {0} \
  CONFIG.PCW_EN_CLK0_PORT {1} \
  CONFIG.PCW_EN_CLK1_PORT {0} \
  CONFIG.PCW_EN_CLK2_PORT {0} \
  CONFIG.PCW_EN_CLK3_PORT {0} \
  CONFIG.PCW_EN_CLKTRIG0_PORT {0} \
  CONFIG.PCW_EN_CLKTRIG1_PORT {0} \
  CONFIG.PCW_EN_CLKTRIG2_PORT {0} \
  CONFIG.PCW_EN_CLKTRIG3_PORT {0} \
  CONFIG.PCW_EN_DDR {1} \
  CONFIG.PCW_EN_EMIO_CAN0 {0} \
  CONFIG.PCW_EN_EMIO_CAN1 {0} \
  CONFIG.PCW_EN_EMIO_CD_SDIO0 {1} \
  CONFIG.PCW_EN_EMIO_CD_SDIO1 {0} \
  CONFIG.PCW_EN_EMIO_ENET0 {0} \
  CONFIG.PCW_EN_EMIO_ENET1 {0} \
  CONFIG.PCW_EN_EMIO_GPIO {1} \
  CONFIG.PCW_EN_EMIO_I2C0 {1} \
  CONFIG.PCW_EN_EMIO_I2C1 {0} \
  CONFIG.PCW_EN_EMIO_MODEM_UART0 {0} \
  CONFIG.PCW_EN_EMIO_MODEM_UART1 {0} \
  CONFIG.PCW_EN_EMIO_PJTAG {0} \
  CONFIG.PCW_EN_EMIO_SDIO0 {0} \
  CONFIG.PCW_EN_EMIO_SDIO1 {0} \
  CONFIG.PCW_EN_EMIO_SPI0 {0} \
  CONFIG.PCW_EN_EMIO_SPI1 {0} \
  CONFIG.PCW_EN_EMIO_SRAM_INT {0} \
  CONFIG.PCW_EN_EMIO_TRACE {0} \
  CONFIG.PCW_EN_EMIO_TTC0 {0} \
  CONFIG.PCW_EN_EMIO_TTC1 {0} \
  CONFIG.PCW_EN_EMIO_UART0 {0} \
  CONFIG.PCW_EN_EMIO_UART1 {0} \
  CONFIG.PCW_EN_EMIO_WDT {0} \
  CONFIG.PCW_EN_EMIO_WP_SDIO0 {0} \
  CONFIG.PCW_EN_EMIO_WP_SDIO1 {0} \
  CONFIG.PCW_EN_ENET0 {1} \
  CONFIG.PCW_EN_ENET1 {0} \
  CONFIG.PCW_EN_GPIO {1} \
  CONFIG.PCW_EN_I2C0 {1} \
  CONFIG.PCW_EN_I2C1 {0} \
  CONFIG.PCW_EN_MODEM_UART0 {0} \
  CONFIG.PCW_EN_MODEM_UART1 {0} \
  CONFIG.PCW_EN_PJTAG {0} \
  CONFIG.PCW_EN_PTP_ENET0 {0} \
  CONFIG.PCW_EN_PTP_ENET1 {0} \
  CONFIG.PCW_EN_QSPI {1} \
  CONFIG.PCW_EN_RST0_PORT {1} \
  CONFIG.PCW_EN_RST1_PORT {0} \
  CONFIG.PCW_EN_RST2_PORT {0} \
  CONFIG.PCW_EN_RST3_PORT {0} \
  CONFIG.PCW_EN_SDIO0 {1} \
  CONFIG.PCW_EN_SDIO1 {0} \
  CONFIG.PCW_EN_SMC {0} \
  CONFIG.PCW_EN_SPI0 {0} \
  CONFIG.PCW_EN_SPI1 {0} \
  CONFIG.PCW_EN_TRACE {0} \
  CONFIG.PCW_EN_TTC0 {0} \
  CONFIG.PCW_EN_TTC1 {0} \
  CONFIG.PCW_EN_UART0 {0} \
  CONFIG.PCW_EN_UART1 {1} \
  CONFIG.PCW_EN_USB0 {1} \
  CONFIG.PCW_EN_USB1 {0} \
  CONFIG.PCW_EN_WDT {0} \
  CONFIG.PCW_FCLK0_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_FCLK1_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_FCLK2_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_FCLK3_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_FCLK_CLK0_BUF {TRUE} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
  CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {200} \
  CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ {200} \
  CONFIG.PCW_FPGA3_PERIPHERAL_FREQMHZ {50} \
  CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
  CONFIG.PCW_GP0_EN_MODIFIABLE_TXN {0} \
  CONFIG.PCW_GP0_NUM_READ_THREADS {4} \
  CONFIG.PCW_GP0_NUM_WRITE_THREADS {4} \
  CONFIG.PCW_GP1_EN_MODIFIABLE_TXN {0} \
  CONFIG.PCW_GP1_NUM_READ_THREADS {4} \
  CONFIG.PCW_GP1_NUM_WRITE_THREADS {4} \
  CONFIG.PCW_GPIO_BASEADDR {0xE000A000} \
  CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {1} \
  CONFIG.PCW_GPIO_EMIO_GPIO_IO {1} \
  CONFIG.PCW_GPIO_EMIO_GPIO_WIDTH {1} \
  CONFIG.PCW_GPIO_HIGHADDR {0xE000AFFF} \
  CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
  CONFIG.PCW_GPIO_MIO_GPIO_IO {MIO} \
  CONFIG.PCW_GPIO_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_I2C0_BASEADDR {0xE0004000} \
  CONFIG.PCW_I2C0_HIGHADDR {0xE0004FFF} \
  CONFIG.PCW_I2C0_I2C0_IO {EMIO} \
  CONFIG.PCW_I2C0_PERIPHERAL_ENABLE {1} \
  CONFIG.PCW_I2C1_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_I2C_PERIPHERAL_FREQMHZ {111.111115} \
  CONFIG.PCW_I2C_RESET_ENABLE {0} \
  CONFIG.PCW_I2C_RESET_POLARITY {Active Low} \
  CONFIG.PCW_IMPORT_BOARD_PRESET {None} \
  CONFIG.PCW_INCLUDE_ACP_TRANS_CHECK {0} \
  CONFIG.PCW_IRQ_F2P_INTR {1} \
  CONFIG.PCW_IRQ_F2P_MODE {DIRECT} \
  CONFIG.PCW_MIO_0_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_0_PULLUP {enabled} \
  CONFIG.PCW_MIO_0_SLEW {slow} \
  CONFIG.PCW_MIO_10_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_10_PULLUP {enabled} \
  CONFIG.PCW_MIO_10_SLEW {slow} \
  CONFIG.PCW_MIO_11_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_11_PULLUP {enabled} \
  CONFIG.PCW_MIO_11_SLEW {slow} \
  CONFIG.PCW_MIO_12_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_12_PULLUP {enabled} \
  CONFIG.PCW_MIO_12_SLEW {slow} \
  CONFIG.PCW_MIO_13_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_13_PULLUP {enabled} \
  CONFIG.PCW_MIO_13_SLEW {slow} \
  CONFIG.PCW_MIO_14_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_14_PULLUP {enabled} \
  CONFIG.PCW_MIO_14_SLEW {slow} \
  CONFIG.PCW_MIO_15_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_15_PULLUP {enabled} \
  CONFIG.PCW_MIO_15_SLEW {slow} \
  CONFIG.PCW_MIO_16_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_16_PULLUP {enabled} \
  CONFIG.PCW_MIO_16_SLEW {slow} \
  CONFIG.PCW_MIO_17_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_17_PULLUP {enabled} \
  CONFIG.PCW_MIO_17_SLEW {slow} \
  CONFIG.PCW_MIO_18_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_18_PULLUP {enabled} \
  CONFIG.PCW_MIO_18_SLEW {slow} \
  CONFIG.PCW_MIO_19_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_19_PULLUP {enabled} \
  CONFIG.PCW_MIO_19_SLEW {slow} \
  CONFIG.PCW_MIO_1_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_1_PULLUP {enabled} \
  CONFIG.PCW_MIO_1_SLEW {slow} \
  CONFIG.PCW_MIO_20_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_20_PULLUP {enabled} \
  CONFIG.PCW_MIO_20_SLEW {slow} \
  CONFIG.PCW_MIO_21_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_21_PULLUP {enabled} \
  CONFIG.PCW_MIO_21_SLEW {slow} \
  CONFIG.PCW_MIO_22_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_22_PULLUP {enabled} \
  CONFIG.PCW_MIO_22_SLEW {slow} \
  CONFIG.PCW_MIO_23_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_23_PULLUP {enabled} \
  CONFIG.PCW_MIO_23_SLEW {slow} \
  CONFIG.PCW_MIO_24_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_24_PULLUP {enabled} \
  CONFIG.PCW_MIO_24_SLEW {slow} \
  CONFIG.PCW_MIO_25_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_25_PULLUP {enabled} \
  CONFIG.PCW_MIO_25_SLEW {slow} \
  CONFIG.PCW_MIO_26_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_26_PULLUP {enabled} \
  CONFIG.PCW_MIO_26_SLEW {slow} \
  CONFIG.PCW_MIO_27_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_27_PULLUP {enabled} \
  CONFIG.PCW_MIO_27_SLEW {slow} \
  CONFIG.PCW_MIO_28_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_28_PULLUP {enabled} \
  CONFIG.PCW_MIO_28_SLEW {slow} \
  CONFIG.PCW_MIO_29_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_29_PULLUP {enabled} \
  CONFIG.PCW_MIO_29_SLEW {slow} \
  CONFIG.PCW_MIO_2_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_2_SLEW {slow} \
  CONFIG.PCW_MIO_30_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_30_PULLUP {enabled} \
  CONFIG.PCW_MIO_30_SLEW {slow} \
  CONFIG.PCW_MIO_31_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_31_PULLUP {enabled} \
  CONFIG.PCW_MIO_31_SLEW {slow} \
  CONFIG.PCW_MIO_32_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_32_PULLUP {enabled} \
  CONFIG.PCW_MIO_32_SLEW {slow} \
  CONFIG.PCW_MIO_33_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_33_PULLUP {enabled} \
  CONFIG.PCW_MIO_33_SLEW {slow} \
  CONFIG.PCW_MIO_34_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_34_PULLUP {enabled} \
  CONFIG.PCW_MIO_34_SLEW {slow} \
  CONFIG.PCW_MIO_35_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_35_PULLUP {enabled} \
  CONFIG.PCW_MIO_35_SLEW {slow} \
  CONFIG.PCW_MIO_36_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_36_PULLUP {enabled} \
  CONFIG.PCW_MIO_36_SLEW {slow} \
  CONFIG.PCW_MIO_37_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_37_PULLUP {enabled} \
  CONFIG.PCW_MIO_37_SLEW {slow} \
  CONFIG.PCW_MIO_38_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_38_PULLUP {enabled} \
  CONFIG.PCW_MIO_38_SLEW {slow} \
  CONFIG.PCW_MIO_39_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_39_PULLUP {enabled} \
  CONFIG.PCW_MIO_39_SLEW {slow} \
  CONFIG.PCW_MIO_3_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_3_SLEW {slow} \
  CONFIG.PCW_MIO_40_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_40_PULLUP {enabled} \
  CONFIG.PCW_MIO_40_SLEW {slow} \
  CONFIG.PCW_MIO_41_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_41_PULLUP {enabled} \
  CONFIG.PCW_MIO_41_SLEW {slow} \
  CONFIG.PCW_MIO_42_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_42_PULLUP {enabled} \
  CONFIG.PCW_MIO_42_SLEW {slow} \
  CONFIG.PCW_MIO_43_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_43_PULLUP {enabled} \
  CONFIG.PCW_MIO_43_SLEW {slow} \
  CONFIG.PCW_MIO_44_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_44_PULLUP {enabled} \
  CONFIG.PCW_MIO_44_SLEW {slow} \
  CONFIG.PCW_MIO_45_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_45_PULLUP {enabled} \
  CONFIG.PCW_MIO_45_SLEW {slow} \
  CONFIG.PCW_MIO_46_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_46_PULLUP {enabled} \
  CONFIG.PCW_MIO_46_SLEW {slow} \
  CONFIG.PCW_MIO_47_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_47_PULLUP {enabled} \
  CONFIG.PCW_MIO_47_SLEW {slow} \
  CONFIG.PCW_MIO_48_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_48_PULLUP {enabled} \
  CONFIG.PCW_MIO_48_SLEW {slow} \
  CONFIG.PCW_MIO_49_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_49_PULLUP {enabled} \
  CONFIG.PCW_MIO_49_SLEW {slow} \
  CONFIG.PCW_MIO_4_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_4_SLEW {slow} \
  CONFIG.PCW_MIO_50_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_50_PULLUP {enabled} \
  CONFIG.PCW_MIO_50_SLEW {slow} \
  CONFIG.PCW_MIO_51_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_51_PULLUP {enabled} \
  CONFIG.PCW_MIO_51_SLEW {slow} \
  CONFIG.PCW_MIO_52_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_52_PULLUP {enabled} \
  CONFIG.PCW_MIO_52_SLEW {slow} \
  CONFIG.PCW_MIO_53_IOTYPE {LVCMOS 1.8V} \
  CONFIG.PCW_MIO_53_PULLUP {enabled} \
  CONFIG.PCW_MIO_53_SLEW {slow} \
  CONFIG.PCW_MIO_5_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_5_SLEW {slow} \
  CONFIG.PCW_MIO_6_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_6_SLEW {slow} \
  CONFIG.PCW_MIO_7_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_7_SLEW {slow} \
  CONFIG.PCW_MIO_8_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_8_SLEW {slow} \
  CONFIG.PCW_MIO_9_IOTYPE {LVCMOS 3.3V} \
  CONFIG.PCW_MIO_9_PULLUP {enabled} \
  CONFIG.PCW_MIO_9_SLEW {slow} \
  CONFIG.PCW_MIO_PRIMITIVE {54} \
  CONFIG.PCW_M_AXI_GP0_ENABLE_STATIC_REMAP {0} \
  CONFIG.PCW_M_AXI_GP0_ID_WIDTH {12} \
  CONFIG.PCW_M_AXI_GP0_SUPPORT_NARROW_BURST {0} \
  CONFIG.PCW_M_AXI_GP0_THREAD_ID_WIDTH {12} \
  CONFIG.PCW_NAND_CYCLES_T_AR {1} \
  CONFIG.PCW_NAND_CYCLES_T_CLR {1} \
  CONFIG.PCW_NAND_CYCLES_T_RC {11} \
  CONFIG.PCW_NAND_CYCLES_T_REA {1} \
  CONFIG.PCW_NAND_CYCLES_T_RR {1} \
  CONFIG.PCW_NAND_CYCLES_T_WC {11} \
  CONFIG.PCW_NAND_CYCLES_T_WP {1} \
  CONFIG.PCW_NOR_CS0_T_CEOE {1} \
  CONFIG.PCW_NOR_CS0_T_PC {1} \
  CONFIG.PCW_NOR_CS0_T_RC {11} \
  CONFIG.PCW_NOR_CS0_T_TR {1} \
  CONFIG.PCW_NOR_CS0_T_WC {11} \
  CONFIG.PCW_NOR_CS0_T_WP {1} \
  CONFIG.PCW_NOR_CS0_WE_TIME {0} \
  CONFIG.PCW_NOR_CS1_T_CEOE {1} \
  CONFIG.PCW_NOR_CS1_T_PC {1} \
  CONFIG.PCW_NOR_CS1_T_RC {11} \
  CONFIG.PCW_NOR_CS1_T_TR {1} \
  CONFIG.PCW_NOR_CS1_T_WC {11} \
  CONFIG.PCW_NOR_CS1_T_WP {1} \
  CONFIG.PCW_NOR_CS1_WE_TIME {0} \
  CONFIG.PCW_NOR_SRAM_CS0_T_CEOE {1} \
  CONFIG.PCW_NOR_SRAM_CS0_T_PC {1} \
  CONFIG.PCW_NOR_SRAM_CS0_T_RC {11} \
  CONFIG.PCW_NOR_SRAM_CS0_T_TR {1} \
  CONFIG.PCW_NOR_SRAM_CS0_T_WC {11} \
  CONFIG.PCW_NOR_SRAM_CS0_T_WP {1} \
  CONFIG.PCW_NOR_SRAM_CS0_WE_TIME {0} \
  CONFIG.PCW_NOR_SRAM_CS1_T_CEOE {1} \
  CONFIG.PCW_NOR_SRAM_CS1_T_PC {1} \
  CONFIG.PCW_NOR_SRAM_CS1_T_RC {11} \
  CONFIG.PCW_NOR_SRAM_CS1_T_TR {1} \
  CONFIG.PCW_NOR_SRAM_CS1_T_WC {11} \
  CONFIG.PCW_NOR_SRAM_CS1_T_WP {1} \
  CONFIG.PCW_NOR_SRAM_CS1_WE_TIME {0} \
  CONFIG.PCW_OVERRIDE_BASIC_CLOCK {0} \
  CONFIG.PCW_P2F_ENET0_INTR {0} \
  CONFIG.PCW_P2F_GPIO_INTR {0} \
  CONFIG.PCW_P2F_I2C0_INTR {0} \
  CONFIG.PCW_P2F_QSPI_INTR {0} \
  CONFIG.PCW_P2F_SDIO0_INTR {0} \
  CONFIG.PCW_P2F_UART1_INTR {0} \
  CONFIG.PCW_P2F_USB0_INTR {0} \
  CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY0 {0.089} \
  CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY1 {0.075} \
  CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY2 {0.085} \
  CONFIG.PCW_PACKAGE_DDR_BOARD_DELAY3 {0.092} \
  CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_0 {-0.025} \
  CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_1 {0.014} \
  CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_2 {-0.009} \
  CONFIG.PCW_PACKAGE_DDR_DQS_TO_CLK_DELAY_3 {-0.033} \
  CONFIG.PCW_PACKAGE_NAME {clg400} \
  CONFIG.PCW_PCAP_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_PCAP_PERIPHERAL_FREQMHZ {200} \
  CONFIG.PCW_PERIPHERAL_BOARD_PRESET {part0} \
  CONFIG.PCW_PJTAG_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_PLL_BYPASSMODE_ENABLE {0} \
  CONFIG.PCW_PRESET_BANK0_VOLTAGE {LVCMOS 3.3V} \
  CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
  CONFIG.PCW_PS7_SI_REV {PRODUCTION} \
  CONFIG.PCW_QSPI_GRP_FBCLK_ENABLE {1} \
  CONFIG.PCW_QSPI_GRP_FBCLK_IO {MIO 8} \
  CONFIG.PCW_QSPI_GRP_IO1_ENABLE {0} \
  CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE {1} \
  CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO {MIO 1 .. 6} \
  CONFIG.PCW_QSPI_GRP_SS1_ENABLE {0} \
  CONFIG.PCW_QSPI_INTERNAL_HIGHADDRESS {0xFCFFFFFF} \
  CONFIG.PCW_QSPI_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_QSPI_PERIPHERAL_ENABLE {1} \
  CONFIG.PCW_QSPI_PERIPHERAL_FREQMHZ {200} \
  CONFIG.PCW_QSPI_QSPI_IO {MIO 1 .. 6} \
  CONFIG.PCW_SD0_GRP_CD_ENABLE {1} \
  CONFIG.PCW_SD0_GRP_CD_IO {EMIO} \
  CONFIG.PCW_SD0_GRP_POW_ENABLE {0} \
  CONFIG.PCW_SD0_GRP_WP_ENABLE {0} \
  CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1} \
  CONFIG.PCW_SD0_SD0_IO {MIO 40 .. 45} \
  CONFIG.PCW_SD1_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_SDIO0_BASEADDR {0xE0100000} \
  CONFIG.PCW_SDIO0_HIGHADDR {0xE0100FFF} \
  CONFIG.PCW_SDIO_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_SDIO_PERIPHERAL_FREQMHZ {100} \
  CONFIG.PCW_SDIO_PERIPHERAL_VALID {1} \
  CONFIG.PCW_SINGLE_QSPI_DATA_MODE {x4} \
  CONFIG.PCW_SMC_CYCLE_T0 {NA} \
  CONFIG.PCW_SMC_CYCLE_T1 {NA} \
  CONFIG.PCW_SMC_CYCLE_T2 {NA} \
  CONFIG.PCW_SMC_CYCLE_T3 {NA} \
  CONFIG.PCW_SMC_CYCLE_T4 {NA} \
  CONFIG.PCW_SMC_CYCLE_T5 {NA} \
  CONFIG.PCW_SMC_CYCLE_T6 {NA} \
  CONFIG.PCW_SMC_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_SMC_PERIPHERAL_VALID {0} \
  CONFIG.PCW_SPI0_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_SPI1_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_SPI_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_SPI_PERIPHERAL_VALID {0} \
  CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
  CONFIG.PCW_S_AXI_HP0_ID_WIDTH {6} \
  CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {64} \
  CONFIG.PCW_S_AXI_HP2_ID_WIDTH {6} \
  CONFIG.PCW_TPIU_PERIPHERAL_CLKSRC {External} \
  CONFIG.PCW_TRACE_INTERNAL_WIDTH {2} \
  CONFIG.PCW_TRACE_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_TTC0_CLK0_PERIPHERAL_CLKSRC {CPU_1X} \
  CONFIG.PCW_TTC0_CLK0_PERIPHERAL_DIVISOR0 {1} \
  CONFIG.PCW_TTC0_CLK1_PERIPHERAL_CLKSRC {CPU_1X} \
  CONFIG.PCW_TTC0_CLK1_PERIPHERAL_DIVISOR0 {1} \
  CONFIG.PCW_TTC0_CLK2_PERIPHERAL_CLKSRC {CPU_1X} \
  CONFIG.PCW_TTC0_CLK2_PERIPHERAL_DIVISOR0 {1} \
  CONFIG.PCW_TTC0_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_TTC1_CLK0_PERIPHERAL_CLKSRC {CPU_1X} \
  CONFIG.PCW_TTC1_CLK0_PERIPHERAL_DIVISOR0 {1} \
  CONFIG.PCW_TTC1_CLK1_PERIPHERAL_CLKSRC {CPU_1X} \
  CONFIG.PCW_TTC1_CLK1_PERIPHERAL_DIVISOR0 {1} \
  CONFIG.PCW_TTC1_CLK2_PERIPHERAL_CLKSRC {CPU_1X} \
  CONFIG.PCW_TTC1_CLK2_PERIPHERAL_DIVISOR0 {1} \
  CONFIG.PCW_TTC1_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_UART0_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_UART1_BASEADDR {0xE0001000} \
  CONFIG.PCW_UART1_BAUD_RATE {115200} \
  CONFIG.PCW_UART1_GRP_FULL_ENABLE {0} \
  CONFIG.PCW_UART1_HIGHADDR {0xE0001FFF} \
  CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
  CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
  CONFIG.PCW_UART_PERIPHERAL_CLKSRC {IO PLL} \
  CONFIG.PCW_UART_PERIPHERAL_FREQMHZ {100} \
  CONFIG.PCW_UART_PERIPHERAL_VALID {1} \
  CONFIG.PCW_UIPARAM_ACT_DDR_FREQ_MHZ {533.333374} \
  CONFIG.PCW_UIPARAM_DDR_ADV_ENABLE {0} \
  CONFIG.PCW_UIPARAM_DDR_AL {0} \
  CONFIG.PCW_UIPARAM_DDR_BL {8} \
  CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0 {0.176} \
  CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1 {0.159} \
  CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY2 {0.162} \
  CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY3 {0.187} \
  CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {32 Bit} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_0_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_0_PACKAGE_LENGTH {80.4535} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_0_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_1_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_1_PACKAGE_LENGTH {80.4535} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_1_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_2_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_2_PACKAGE_LENGTH {80.4535} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_2_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_3_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_3_PACKAGE_LENGTH {80.4535} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_3_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_CLOCK_STOP_EN {0} \
  CONFIG.PCW_UIPARAM_DDR_DQS_0_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_DQS_0_PACKAGE_LENGTH {105.056} \
  CONFIG.PCW_UIPARAM_DDR_DQS_0_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_DQS_1_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_DQS_1_PACKAGE_LENGTH {66.904} \
  CONFIG.PCW_UIPARAM_DDR_DQS_1_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_DQS_2_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_DQS_2_PACKAGE_LENGTH {89.1715} \
  CONFIG.PCW_UIPARAM_DDR_DQS_2_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_DQS_3_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_DQS_3_PACKAGE_LENGTH {113.63} \
  CONFIG.PCW_UIPARAM_DDR_DQS_3_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_0 {0.000} \
  CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_1 {0.000} \
  CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_2 {0.000} \
  CONFIG.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_3 {0.000} \
  CONFIG.PCW_UIPARAM_DDR_DQ_0_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_DQ_0_PACKAGE_LENGTH {98.503} \
  CONFIG.PCW_UIPARAM_DDR_DQ_0_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_DQ_1_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_DQ_1_PACKAGE_LENGTH {68.5855} \
  CONFIG.PCW_UIPARAM_DDR_DQ_1_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_DQ_2_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_DQ_2_PACKAGE_LENGTH {90.295} \
  CONFIG.PCW_UIPARAM_DDR_DQ_2_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_DQ_3_LENGTH_MM {0} \
  CONFIG.PCW_UIPARAM_DDR_DQ_3_PACKAGE_LENGTH {103.977} \
  CONFIG.PCW_UIPARAM_DDR_DQ_3_PROPOGATION_DELAY {160} \
  CONFIG.PCW_UIPARAM_DDR_ENABLE {1} \
  CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ {533.333333} \
  CONFIG.PCW_UIPARAM_DDR_HIGH_TEMP {Normal (0-85)} \
  CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3 (Low Voltage)} \
  CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
  CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE {1} \
  CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE {1} \
  CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL {1} \
  CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF {0} \
  CONFIG.PCW_UIPARAM_GENERATE_SUMMARY {NA} \
  CONFIG.PCW_USB0_BASEADDR {0xE0102000} \
  CONFIG.PCW_USB0_HIGHADDR {0xE0102fff} \
  CONFIG.PCW_USB0_PERIPHERAL_ENABLE {1} \
  CONFIG.PCW_USB0_RESET_ENABLE {1} \
  CONFIG.PCW_USB0_RESET_IO {MIO 46} \
  CONFIG.PCW_USB0_USB0_IO {MIO 28 .. 39} \
  CONFIG.PCW_USB1_PERIPHERAL_ENABLE {0} \
  CONFIG.PCW_USB_RESET_ENABLE {1} \
  CONFIG.PCW_USB_RESET_POLARITY {Active Low} \
  CONFIG.PCW_USB_RESET_SELECT {Share reset pin} \
  CONFIG.PCW_USE_AXI_FABRIC_IDLE {0} \
  CONFIG.PCW_USE_AXI_NONSECURE {0} \
  CONFIG.PCW_USE_CORESIGHT {0} \
  CONFIG.PCW_USE_CROSS_TRIGGER {0} \
  CONFIG.PCW_USE_CR_FABRIC {1} \
  CONFIG.PCW_USE_DDR_BYPASS {0} \
  CONFIG.PCW_USE_DEBUG {0} \
  CONFIG.PCW_USE_DMA0 {0} \
  CONFIG.PCW_USE_DMA1 {0} \
  CONFIG.PCW_USE_DMA2 {0} \
  CONFIG.PCW_USE_DMA3 {0} \
  CONFIG.PCW_USE_EXPANDED_IOP {0} \
  CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
  CONFIG.PCW_USE_HIGH_OCM {0} \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_USE_M_AXI_GP1 {0} \
  CONFIG.PCW_USE_PROC_EVENT_BUS {0} \
  CONFIG.PCW_USE_PS_SLCR_REGISTERS {0} \
  CONFIG.PCW_USE_S_AXI_ACP {0} \
  CONFIG.PCW_USE_S_AXI_GP0 {0} \
  CONFIG.PCW_USE_S_AXI_GP1 {0} \
  CONFIG.PCW_USE_S_AXI_HP0 {0} \
  CONFIG.PCW_USE_S_AXI_HP1 {0} \
  CONFIG.PCW_USE_S_AXI_HP2 {1} \
  CONFIG.PCW_USE_S_AXI_HP3 {0} \
  CONFIG.PCW_USE_TRACE {0} \
  CONFIG.PCW_VALUE_SILVERSION {3} \
  CONFIG.PCW_WDT_PERIPHERAL_CLKSRC {CPU_1X} \
  CONFIG.PCW_WDT_PERIPHERAL_DIVISOR0 {1} \
  CONFIG.PCW_WDT_PERIPHERAL_ENABLE {0} \
] [get_bd_cells processing_system7_0]
create_bd_cell -type ip -vlnv {xilinx.com:ip:proc_sys_reset:5.0} rst_clk_wiz_0_50M
create_bd_cell -type ip -vlnv {xilinx.com:ip:axi_interconnect:2.1} axi_mem_intercon_1
set_property -dict [list \
  CONFIG.NUM_MI {1} \
  CONFIG.SYNCHRONIZATION_STAGES {2} \
] [get_bd_cells axi_mem_intercon_1]
create_bd_cell -type ip -vlnv {xilinx.com:ip:axi_vdma:6.3} axi_vdma_0
set_property -dict [list \
  CONFIG.c_include_mm2s_dre {0} \
  CONFIG.c_include_s2mm {1} \
  CONFIG.c_m_axi_s2mm_data_width {64} \
  CONFIG.c_m_axis_mm2s_tdata_width {24} \
  CONFIG.c_s2mm_genlock_mode {2} \
  CONFIG.c_s2mm_linebuffer_depth {1024} \
  CONFIG.c_include_mm2s {0} \
] [get_bd_cells axi_vdma_0]
create_bd_cell -type ip -vlnv {xilinx.com:ip:clk_wiz:6.0} clk_wiz_0
set_property -dict [list \
  CONFIG.CLKOUT1_DRIVES {BUFG} \
  CONFIG.CLKOUT1_JITTER {174.353} \
  CONFIG.CLKOUT1_PHASE_ERROR {132.063} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50} \
  CONFIG.CLKOUT2_DRIVES {BUFG} \
  CONFIG.CLKOUT2_JITTER {139.594} \
  CONFIG.CLKOUT2_PHASE_ERROR {132.063} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {150} \
  CONFIG.CLKOUT2_USED {true} \
  CONFIG.CLKOUT3_DRIVES {BUFG} \
  CONFIG.CLKOUT3_JITTER {132.221} \
  CONFIG.CLKOUT3_PHASE_ERROR {132.063} \
  CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200} \
  CONFIG.CLKOUT3_USED {true} \
  CONFIG.CLKOUT4_DRIVES {BUFG} \
  CONFIG.CLKOUT5_DRIVES {BUFG} \
  CONFIG.CLKOUT6_DRIVES {BUFG} \
  CONFIG.CLKOUT7_DRIVES {BUFG} \
  CONFIG.CLK_OUT2_PORT {clk_out2} \
  CONFIG.CLK_OUT3_PORT {clk_out3} \
  CONFIG.MMCM_CLKFBOUT_MULT_F {6.000} \
  CONFIG.MMCM_CLKIN1_PERIOD {10.0} \
  CONFIG.MMCM_CLKIN2_PERIOD {10.0} \
  CONFIG.MMCM_CLKOUT0_DIVIDE_F {12.000} \
  CONFIG.MMCM_CLKOUT1_DIVIDE {4} \
  CONFIG.MMCM_CLKOUT2_DIVIDE {3} \
  CONFIG.MMCM_DIVCLK_DIVIDE {1} \
  CONFIG.NUM_OUT_CLKS {3} \
  CONFIG.PRIM_SOURCE {Global_buffer} \
  CONFIG.RESET_PORT {reset} \
  CONFIG.RESET_TYPE {ACTIVE_HIGH} \
  CONFIG.SECONDARY_SOURCE {Single_ended_clock_capable_pin} \
  CONFIG.USE_PHASE_ALIGNMENT {false} \
  CONFIG.USE_RESET {false} \
] [get_bd_cells clk_wiz_0]
# Video clock plan (11-14-2026): the 150 MHz output of clk_wiz_0 is removed. The whole video stream path
# (CSI-2 receiver video side, Bayer, gamma, capture, HP capture port, encoder) runs on one 90 MHz clock.
# clk_wiz_0 keeps 50 MHz (control) and 200 MHz (D-PHY IDELAY reference); its former 150 MHz output stays
# unconnected and unbuffered so the wizard port numbering (clk_out3 = 200 MHz) is unchanged.
set_property CONFIG.CLKOUT2_DRIVES No_buffer [get_bd_cells clk_wiz_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 rtlnet_video_clock
set_property -dict [list CONFIG.PRIM_SOURCE Global_buffer CONFIG.PRIM_IN_FREQ 100 \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 90 CONFIG.USE_RESET false] [get_bd_cells rtlnet_video_clock]
create_bd_cell -type ip -vlnv {xilinx.com:ip:axi_interconnect:2.1} ps7_0_axi_periph
set_property -dict [list \
  CONFIG.NUM_MI {4} \
  CONFIG.NUM_SI {1} \
] [get_bd_cells ps7_0_axi_periph]
connect_bd_intf_net [get_bd_intf_pins {AXI_BayerToRGB_1/AXI_Stream_Master}] [get_bd_intf_pins {AXI_GammaCorrection_0/s_axis_video}]
connect_bd_intf_net [get_bd_intf_pins {AXI_GammaCorrection_0/m_axis_video}] [get_bd_intf_pins {axi_vdma_0/S_AXIS_S2MM}]
connect_bd_intf_net [get_bd_intf_pins {AXI_BayerToRGB_1/AXI_Slave_Interface}] [get_bd_intf_pins {MIPI_CSI_2_RX_0/m_axis_video}]
connect_bd_intf_net [get_bd_intf_pins {MIPI_CSI_2_RX_0/rx_mipi_ppi}] [get_bd_intf_pins {MIPI_D_PHY_RX_0/D_PHY_PPI}]
connect_bd_intf_net [get_bd_intf_pins {axi_mem_intercon_1/M00_AXI}] [get_bd_intf_pins {processing_system7_0/S_AXI_HP2}]
connect_bd_intf_net [get_bd_intf_pins {axi_mem_intercon_1/S00_AXI}] [get_bd_intf_pins {axi_vdma_0/M_AXI_S2MM}]
connect_bd_intf_net [get_bd_intf_ports {dphy_hs_clock}] [get_bd_intf_pins {MIPI_D_PHY_RX_0/dphy_hs_clock}]
connect_bd_intf_net [get_bd_intf_ports {DDR}] [get_bd_intf_pins {processing_system7_0/DDR}]
connect_bd_intf_net [get_bd_intf_ports {FIXED_IO}] [get_bd_intf_pins {processing_system7_0/FIXED_IO}]
connect_bd_intf_net [get_bd_intf_ports {cam_gpio}] [get_bd_intf_pins {processing_system7_0/GPIO_0}]
connect_bd_intf_net [get_bd_intf_ports {cam_iic}] [get_bd_intf_pins {processing_system7_0/IIC_0}]
connect_bd_intf_net [get_bd_intf_pins {processing_system7_0/M_AXI_GP0}] [get_bd_intf_pins {ps7_0_axi_periph/S00_AXI}]
connect_bd_intf_net [get_bd_intf_pins {axi_vdma_0/S_AXI_LITE}] [get_bd_intf_pins {ps7_0_axi_periph/M00_AXI}]
connect_bd_intf_net [get_bd_intf_pins {MIPI_D_PHY_RX_0/S_AXI_LITE}] [get_bd_intf_pins {ps7_0_axi_periph/M01_AXI}]
connect_bd_intf_net [get_bd_intf_pins {MIPI_CSI_2_RX_0/S_AXI_LITE}] [get_bd_intf_pins {ps7_0_axi_periph/M02_AXI}]
connect_bd_intf_net [get_bd_intf_pins {AXI_GammaCorrection_0/s_axil}] [get_bd_intf_pins {ps7_0_axi_periph/M03_AXI}]
connect_bd_net [get_bd_pins {MIPI_D_PHY_RX_0/RxByteClkHS}] [get_bd_pins {MIPI_CSI_2_RX_0/RxByteClkHS}]
connect_bd_net [get_bd_pins {clk_wiz_0/locked}] [get_bd_pins {rst_clk_wiz_0_50M/dcm_locked}]
connect_bd_net [get_bd_ports {dphy_clk_lp_n}] [get_bd_pins {MIPI_D_PHY_RX_0/dphy_clk_lp_n}]
connect_bd_net [get_bd_ports {dphy_clk_lp_p}] [get_bd_pins {MIPI_D_PHY_RX_0/dphy_clk_lp_p}]
connect_bd_net [get_bd_ports {dphy_data_hs_n}] [get_bd_pins {MIPI_D_PHY_RX_0/dphy_data_hs_n}]
connect_bd_net [get_bd_ports {dphy_data_hs_p}] [get_bd_pins {MIPI_D_PHY_RX_0/dphy_data_hs_p}]
connect_bd_net [get_bd_ports {dphy_data_lp_n}] [get_bd_pins {MIPI_D_PHY_RX_0/dphy_data_lp_n}]
connect_bd_net [get_bd_ports {dphy_data_lp_p}] [get_bd_pins {MIPI_D_PHY_RX_0/dphy_data_lp_p}]
connect_bd_net [get_bd_pins {rtlnet_video_clock/clk_out1}] [get_bd_pins {AXI_BayerToRGB_1/StreamClk}] [get_bd_pins {AXI_GammaCorrection_0/StreamClk}] [get_bd_pins {MIPI_CSI_2_RX_0/video_aclk}] [get_bd_pins {axi_mem_intercon_1/ACLK}] [get_bd_pins {axi_mem_intercon_1/S00_ACLK}] [get_bd_pins {axi_mem_intercon_1/M00_ACLK}] [get_bd_pins {axi_vdma_0/m_axi_s2mm_aclk}] [get_bd_pins {axi_vdma_0/s_axis_s2mm_aclk}] [get_bd_pins {processing_system7_0/S_AXI_HP2_ACLK}]
connect_bd_net [get_bd_pins {processing_system7_0/FCLK_CLK0}] [get_bd_pins {clk_wiz_0/clk_in1}]
connect_bd_net [get_bd_pins {processing_system7_0/FCLK_CLK0}] [get_bd_pins {rtlnet_video_clock/clk_in1}]
connect_bd_net [get_bd_pins {processing_system7_0/FCLK_RESET0_N}] [get_bd_pins {rst_clk_wiz_0_50M/ext_reset_in}]
connect_bd_net [get_bd_pins {clk_wiz_0/clk_out3}] [get_bd_pins {MIPI_D_PHY_RX_0/RefClk}]
connect_bd_net [get_bd_pins {rst_clk_wiz_0_50M/interconnect_aresetn}] [get_bd_pins {axi_mem_intercon_1/ARESETN}] [get_bd_pins {ps7_0_axi_periph/ARESETN}]
connect_bd_net [get_bd_pins {rst_clk_wiz_0_50M/peripheral_aresetn}] [get_bd_pins {AXI_BayerToRGB_1/sStreamReset_n}] [get_bd_pins {AXI_GammaCorrection_0/aAxiLiteReset_n}] [get_bd_pins {AXI_GammaCorrection_0/sStreamReset_n}] [get_bd_pins {MIPI_CSI_2_RX_0/s_axi_lite_aresetn}] [get_bd_pins {MIPI_D_PHY_RX_0/s_axi_lite_aresetn}] [get_bd_pins {axi_mem_intercon_1/S00_ARESETN}] [get_bd_pins {axi_mem_intercon_1/M00_ARESETN}] [get_bd_pins {axi_vdma_0/axi_resetn}] [get_bd_pins {ps7_0_axi_periph/S00_ARESETN}] [get_bd_pins {ps7_0_axi_periph/M00_ARESETN}] [get_bd_pins {ps7_0_axi_periph/M01_ARESETN}] [get_bd_pins {ps7_0_axi_periph/M02_ARESETN}] [get_bd_pins {ps7_0_axi_periph/M03_ARESETN}]
connect_bd_net [get_bd_pins {rst_clk_wiz_0_50M/peripheral_reset}] [get_bd_pins {MIPI_D_PHY_RX_0/aRst}]
connect_bd_net [get_bd_pins {clk_wiz_0/clk_out1}] [get_bd_pins {AXI_GammaCorrection_0/AxiLiteClk}] [get_bd_pins {MIPI_CSI_2_RX_0/s_axi_lite_aclk}] [get_bd_pins {MIPI_D_PHY_RX_0/s_axi_lite_aclk}] [get_bd_pins {axi_vdma_0/s_axi_lite_aclk}] [get_bd_pins {processing_system7_0/M_AXI_GP0_ACLK}] [get_bd_pins {ps7_0_axi_periph/ACLK}] [get_bd_pins {ps7_0_axi_periph/S00_ACLK}] [get_bd_pins {ps7_0_axi_periph/M00_ACLK}] [get_bd_pins {ps7_0_axi_periph/M01_ACLK}] [get_bd_pins {ps7_0_axi_periph/M02_ACLK}] [get_bd_pins {ps7_0_axi_periph/M03_ACLK}] [get_bd_pins {rst_clk_wiz_0_50M/slowest_sync_clk}]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 rtlnet_zero
set_property -dict [list CONFIG.CONST_VAL 0 CONFIG.CONST_WIDTH 1] [get_bd_cells rtlnet_zero]
connect_bd_net [get_bd_pins rtlnet_zero/dout] [get_bd_pins processing_system7_0/IRQ_F2P]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rtlnet_rst_video
# Reset polarity propagates from PS FCLK_RESET0_N; C_EXT_RESET_HIGH is derived.
connect_bd_net [get_bd_pins rtlnet_video_clock/clk_out1] [get_bd_pins rtlnet_rst_video/slowest_sync_clk]
connect_bd_net [get_bd_pins rtlnet_video_clock/locked] [get_bd_pins rtlnet_rst_video/dcm_locked]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rtlnet_rst_video/ext_reset_in]
foreach p {AXI_BayerToRGB_1/sStreamReset_n AXI_GammaCorrection_0/sStreamReset_n} {
  disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins $p]] [get_bd_pins $p]
  connect_bd_net [get_bd_pins rtlnet_rst_video/peripheral_aresetn] [get_bd_pins $p]
}
# Gamma selection and samples share the 90 MHz video clock; the interconnect converts GP0 control clocks.
foreach p {AXI_GammaCorrection_0/AxiLiteClk ps7_0_axi_periph/M03_ACLK} {
  disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins $p]] [get_bd_pins $p]
  connect_bd_net [get_bd_pins rtlnet_video_clock/clk_out1] [get_bd_pins $p]
}
foreach p {AXI_GammaCorrection_0/aAxiLiteReset_n ps7_0_axi_periph/M03_ARESETN} {
  disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins $p]] [get_bd_pins $p]
  connect_bd_net [get_bd_pins rtlnet_rst_video/peripheral_aresetn] [get_bd_pins $p]
}
# The stage 0 capture interconnect runs on the video clock: its resets come from the video-clock reset controller
# (a 50 MHz-domain reset has no common phase with the 90 MHz clock).
foreach {p source} {axi_mem_intercon_1/ARESETN interconnect_aresetn axi_mem_intercon_1/S00_ARESETN peripheral_aresetn
                    axi_mem_intercon_1/M00_ARESETN peripheral_aresetn} {
  disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins $p]] [get_bd_pins $p]
  connect_bd_net [get_bd_pins rtlnet_rst_video/$source] [get_bd_pins $p]
}
if {[info exists ::rtlnet_baseline] && $::rtlnet_baseline} {
  source [file join [file dirname [info script]] rtlnet_baseline.tcl]
}
assign_bd_address -offset 0x43c00000 -range 0x10000 [get_bd_addr_segs MIPI_D_PHY_RX_0/S_AXI_LITE/S_AXI_LITE_reg]
assign_bd_address -offset 0x43c10000 -range 0x10000 [get_bd_addr_segs MIPI_CSI_2_RX_0/S_AXI_LITE/S_AXI_LITE_reg]
assign_bd_address -offset 0x43c20000 -range 0x10000 [get_bd_addr_segs AXI_GammaCorrection_0/s_axil/reg0]
assign_bd_address
validate_bd_design
if {$::rtlnet_baseline && [get_property CONFIG.PCW_NUM_F2P_INTR_INPUTS [get_bd_cells processing_system7_0]] != 16} {
  error "Baseline IRQ_F2P must propagate to sixteen scalar concat inputs"
}
if {!$::rtlnet_baseline && [get_property CONFIG.c_s_axis_s2mm_tdata_width [get_bd_cells axi_vdma_0]] != 24} {
  error "camera gamma-to-VDMA stream width must propagate to 24"
}
if {[get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells rtlnet_rst_video]] != 0} {
  error "PS active-low reset polarity must propagate to video reset controller"
}
save_bd_design
