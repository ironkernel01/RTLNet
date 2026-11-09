// -----------------------------------------------------------------------------
// File: rtlnet_ddr.sv
// Purpose: the RTLNet DDR3 core: a vendor-neutral AXI4 slave port in front of
//   the DDR3 SDRAM controller of the target technology (documentation/gige.md
//   section 5.1, cores/rtlnet_ddr/documentation/rtlnet_ddr.md).
// Overview:
//   * TARGET selects the implementation; the default is the technology macro of
//     rtlnet_technology.svh (AMD unless the build defines another). "AMD":
//     rtlnet_ddr_amd (MIG controller IP). Any other value stops elaboration;
//     another vendor adds its branch here and its own wrapper file.
//   * RTLNET_DDR_SIM (defined by the board benches): the AMD branch is replaced
//     by rtlnet_ddr_sim (cores/rtlnet_ddr/testbench), the AXI4 memory model with
//     a calibration delay and no DDR3 pins, so the board top simulates in
//     Active-HDL without the controller IP.
//   * Ports: sys_clk / ref_clk / sys_rstn in; ui_clk (100 MHz), ui_resetn (the
//     controller's own reset, active low, synchronous to ui_clk) and
//     init_calib_complete out; one AXI4 slave on ui_clk (INCR, full 128-bit
//     beats, 29-bit byte address = 512 MiB, 2-bit ID); s_axi_aresetn is the
//     reset the AXI side runs with, driven by the board top (it combines
//     ui_resetn with the board reset tree); the DDR3 pins.
//   * No logic of its own: both branches are connected by name.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: sys_clk, ref_clk (controller inputs); ui_clk (everything else).
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_ddr #(
  parameter string TARGET = `RTLNET_TARGET,   // "AMD" (default)
  parameter int    ADDR_W = 29,               // 512 MiB
  parameter int    DATA_W = 128,
  parameter int    ID_W   = 2
)(
  // Controller clocks and reset: sys_clk 100 MHz (controller PLL input, already
  // buffered), ref_clk 200 MHz, sys_rstn asynchronous, active low.
  input  logic                sys_clk,
  input  logic                ref_clk,
  input  logic                sys_rstn,

  // User clock, its controller reset (active low, synchronous to ui_clk), the
  // reset of the AXI side (driven by the board top) and calibration status.
  output logic                ui_clk,
  output logic                ui_resetn,
  input  logic                s_axi_aresetn,
  output logic                init_calib_complete,

  // AXI4 slave, ui_clk domain.
  input  logic [ID_W-1:0]     s_axi_awid,
  input  logic [ADDR_W-1:0]   s_axi_awaddr,
  input  logic [7:0]          s_axi_awlen,
  input  logic [2:0]          s_axi_awsize,
  input  logic [1:0]          s_axi_awburst,
  input  logic                s_axi_awlock,
  input  logic [3:0]          s_axi_awcache,
  input  logic [2:0]          s_axi_awprot,
  input  logic [3:0]          s_axi_awqos,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,
  input  logic [DATA_W-1:0]   s_axi_wdata,
  input  logic [DATA_W/8-1:0] s_axi_wstrb,
  input  logic                s_axi_wlast,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,
  output logic [ID_W-1:0]     s_axi_bid,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready,
  input  logic [ID_W-1:0]     s_axi_arid,
  input  logic [ADDR_W-1:0]   s_axi_araddr,
  input  logic [7:0]          s_axi_arlen,
  input  logic [2:0]          s_axi_arsize,
  input  logic [1:0]          s_axi_arburst,
  input  logic                s_axi_arlock,
  input  logic [3:0]          s_axi_arcache,
  input  logic [2:0]          s_axi_arprot,
  input  logic [3:0]          s_axi_arqos,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,
  output logic [ID_W-1:0]     s_axi_rid,
  output logic [DATA_W-1:0]   s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rlast,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready,

  // DDR3 SDRAM pins (MT41K256M16, 16 bit, one rank).
  inout  wire  [15:0]         ddr3_dq,
  inout  wire  [1:0]          ddr3_dqs_n,
  inout  wire  [1:0]          ddr3_dqs_p,
  output logic [14:0]         ddr3_addr,
  output logic [2:0]          ddr3_ba,
  output logic                ddr3_ras_n,
  output logic                ddr3_cas_n,
  output logic                ddr3_we_n,
  output logic                ddr3_reset_n,
  output logic [0:0]          ddr3_ck_p,
  output logic [0:0]          ddr3_ck_n,
  output logic [0:0]          ddr3_cke,
  output logic [1:0]          ddr3_dm,
  output logic [0:0]          ddr3_odt
);

  generate
    if (TARGET != "AMD") begin : g_bad_target
      $fatal(1, "rtlnet_ddr: TARGET=%s, only AMD is implemented", TARGET);
    end else begin : g_amd
`ifdef RTLNET_DDR_SIM
      rtlnet_ddr_sim #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_ddr (.*);
`else
      rtlnet_ddr_amd #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W)) u_ddr (.*);
`endif
    end
  endgenerate

endmodule
