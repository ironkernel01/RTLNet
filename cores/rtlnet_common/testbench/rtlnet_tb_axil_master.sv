// -----------------------------------------------------------------------------
// File: rtlnet_tb_axil_master.sv
// Purpose: bench AXI4-Lite master: write32 / read32 tasks with a response
//   timeout, used by every register-file bench and by the board bench in
//   place of a CPU.
// Overview:
//   * write32 drives AW and W together, waits for both readies, then B.
//   * read32 drives AR, waits for R and returns data and response.
//   * A transaction that does not complete within TIMEOUT clocks is a failed
//     check (rtlnet_tb_pkg) and returns resp 2'b10.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: aclk.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_tb_axil_master #(
  parameter int ADDR_W  = 32,
  parameter int TIMEOUT = 20000
)(
  input  logic              aclk,
  output logic [ADDR_W-1:0] awaddr,
  output logic              awvalid,
  input  logic              awready,
  output logic [31:0]       wdata,
  output logic [3:0]        wstrb,
  output logic              wvalid,
  input  logic              wready,
  input  logic [1:0]        bresp,
  input  logic              bvalid,
  output logic              bready,
  output logic [ADDR_W-1:0] araddr,
  output logic              arvalid,
  input  logic              arready,
  input  logic [31:0]       rdata,
  input  logic [1:0]        rresp,
  input  logic              rvalid,
  output logic              rready
);

  import rtlnet_tb_pkg::*;

  initial begin
    awaddr = '0; awvalid = 0; wdata = '0; wstrb = '0; wvalid = 0; bready = 0;
    araddr = '0; arvalid = 0; rready = 0;
  end

  task automatic write32(input logic [ADDR_W-1:0] addr, input logic [31:0] data,
                         input logic [3:0] strb = 4'hF, output logic [1:0] resp);
    int  t;
    bit  aw_ok;
    bit  w_ok;
    @(posedge aclk);
    awaddr <= addr; awvalid <= 1'b1;
    wdata  <= data; wstrb   <= strb; wvalid <= 1'b1;
    aw_ok = 0; w_ok = 0; t = 0;
    while (!(aw_ok && w_ok) && t < TIMEOUT) begin
      @(posedge aclk);
      if (awvalid && awready) begin aw_ok = 1; awvalid <= 1'b0; end
      if (wvalid && wready)   begin w_ok  = 1; wvalid  <= 1'b0; end
      t++;
    end
    bready <= 1'b1;
    t = 0;
    @(posedge aclk);
    while (!bvalid && t < TIMEOUT) begin @(posedge aclk); t++; end
    resp = bvalid ? bresp : 2'b10;
    if (!bvalid) tb_error($sformatf("AXI write 0x%08x timed out", addr));
    bready <= 1'b0;
    awvalid <= 1'b0; wvalid <= 1'b0;
  endtask

  task automatic read32(input logic [ADDR_W-1:0] addr, output logic [31:0] data, output logic [1:0] resp);
    int t;
    @(posedge aclk);
    araddr <= addr; arvalid <= 1'b1;
    t = 0;
    @(posedge aclk);
    while (!arready && t < TIMEOUT) begin @(posedge aclk); t++; end
    arvalid <= 1'b0;
    rready  <= 1'b1;
    t = 0;
    @(posedge aclk);
    while (!rvalid && t < TIMEOUT) begin @(posedge aclk); t++; end
    data = rdata;
    resp = rvalid ? rresp : 2'b10;
    if (!rvalid) tb_error($sformatf("AXI read 0x%08x timed out", addr));
    rready <= 1'b0;
  endtask

  // Convenience forms that check an OKAY response.
  task automatic wr(input logic [ADDR_W-1:0] addr, input logic [31:0] data);
    logic [1:0] r;
    write32(addr, data, 4'hF, r);
    tb_check(r == 2'b00, $sformatf("AXI write 0x%08x response %0d", addr, r));
  endtask

  task automatic rd(input logic [ADDR_W-1:0] addr, output logic [31:0] data);
    logic [1:0] r;
    read32(addr, data, r);
    tb_check(r == 2'b00, $sformatf("AXI read 0x%08x response %0d", addr, r));
  endtask

endmodule
