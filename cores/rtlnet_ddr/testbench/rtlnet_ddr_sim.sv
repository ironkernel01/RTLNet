// -----------------------------------------------------------------------------
// File: rtlnet_ddr_sim.sv
// Purpose: simulation stand-in for the DDR3 controller (rtlnet_ddr_amd): the
//   same port list, the AXI4 memory model rtlnet_tb_axi4_mem behind it, no
//   DDR3 pins. Selected by rtlnet_ddr when RTLNET_DDR_SIM is defined (board
//   benches); never synthesized.
// Overview:
//   * ui_clk is the model's own 90 MHz clock; ui_resetn releases RELEASE_CLOCKS
//     ui clocks after sys_rstn is released and is asserted with sys_rstn (sampled on ui_clk).
//   * init_calib_complete rises CALIB_CLOCKS ui clocks after ui_resetn is
//     released (the real controller needs about 100 us) and falls with sys_rstn.
//   * The memory model runs while init_calib_complete is high and
//     s_axi_aresetn is released; before that its ready outputs are low, as the
//     controller's AXI slave holds them until calibration completes.
//   * Storage: sparse, 128-bit words, 29-bit addresses; READ_LATENCY 20 clocks,
//     no ready gaps.
//   * DDR3 outputs are driven to idle levels; the inouts are not driven.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: ui_clk (generated here, 90 MHz); sys_clk and ref_clk unused.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_ddr_sim #(
  parameter int ADDR_W         = 29,
  parameter int DATA_W         = 128,
  parameter int ID_W           = 2,
  parameter int RELEASE_CLOCKS = 8,
  parameter int CALIB_CLOCKS   = 2000,
  parameter real UI_HALF_NS    = 5.5555    // half period of ui_clk: 90 MHz
)(
  // Controller clocks and reset (the model uses sys_clk only).
  input  logic                sys_clk,
  input  logic                ref_clk,
  input  logic                sys_rstn,

  // User clock, controller reset, AXI-side reset, calibration status.
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

  // DDR3 pins: idle outputs, undriven inouts.
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

  logic [$clog2(RELEASE_CLOCKS+1)-1:0] rel_cnt;
  logic [$clog2(CALIB_CLOCKS+1)-1:0]   cal_cnt;
  logic                                mem_resetn;

  // The model's own 90 MHz user clock (the controller at a 2778 ps memory clock, 4:1): sys_clk is not the user clock here.
  logic ui_clk_r = 1'b0;
  always #(UI_HALF_NS) ui_clk_r = ~ui_clk_r;
  assign ui_clk = ui_clk_r;

  // Reset release and calibration delay; sys_rstn is the one reset of the model.
  always_ff @(posedge ui_clk) begin
    if (!sys_rstn) begin
      rel_cnt             <= '0;
      cal_cnt             <= '0;
      ui_resetn           <= 1'b0;
      init_calib_complete <= 1'b0;
    end else begin
      if (rel_cnt == RELEASE_CLOCKS) begin
        ui_resetn <= 1'b1;
      end else begin
        rel_cnt <= rel_cnt + 1'b1;
      end
      if (ui_resetn) begin
        if (cal_cnt == CALIB_CLOCKS) begin
          init_calib_complete <= 1'b1;
        end else begin
          cal_cnt <= cal_cnt + 1'b1;
        end
      end
    end
  end

  assign mem_resetn = s_axi_aresetn & init_calib_complete;

  rtlnet_tb_axi4_mem #(
    .ADDR_W       (ADDR_W),
    .DATA_W       (DATA_W),
    .ID_W         (ID_W),
    .READ_LATENCY (20)
  ) u_mem (
    .clk     (ui_clk),
    .resetn  (mem_resetn),
    .awid    (s_axi_awid),
    .awaddr  (s_axi_awaddr),
    .awlen   (s_axi_awlen),
    .awsize  (s_axi_awsize),
    .awburst (s_axi_awburst),
    .awvalid (s_axi_awvalid),
    .awready (s_axi_awready),
    .wdata   (s_axi_wdata),
    .wstrb   (s_axi_wstrb),
    .wlast   (s_axi_wlast),
    .wvalid  (s_axi_wvalid),
    .wready  (s_axi_wready),
    .bid     (s_axi_bid),
    .bresp   (s_axi_bresp),
    .bvalid  (s_axi_bvalid),
    .bready  (s_axi_bready),
    .arid    (s_axi_arid),
    .araddr  (s_axi_araddr),
    .arlen   (s_axi_arlen),
    .arsize  (s_axi_arsize),
    .arburst (s_axi_arburst),
    .arvalid (s_axi_arvalid),
    .arready (s_axi_arready),
    .rid     (s_axi_rid),
    .rdata   (s_axi_rdata),
    .rresp   (s_axi_rresp),
    .rlast   (s_axi_rlast),
    .rvalid  (s_axi_rvalid),
    .rready  (s_axi_rready)
  );

  assign ddr3_addr    = '0;
  assign ddr3_ba      = '0;
  assign ddr3_ras_n   = 1'b1;
  assign ddr3_cas_n   = 1'b1;
  assign ddr3_we_n    = 1'b1;
  assign ddr3_reset_n = sys_rstn;
  assign ddr3_ck_p    = '0;
  assign ddr3_ck_n    = '1;
  assign ddr3_cke     = '0;
  assign ddr3_dm      = '0;
  assign ddr3_odt     = '0;

endmodule
