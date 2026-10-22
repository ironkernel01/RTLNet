// -----------------------------------------------------------------------------
// File: rtlnet_tb_axis_src.sv
// Purpose: bench AXI4-Stream source for the RTLNet stream: sends byte-queue
//   frames as 64-bit beats (byte 0 in tdata[7:0], contiguous tkeep on the last
//   beat), with optional random idle cycles between and inside frames.
// Overview:
//   * send(frame) blocks until the last beat is accepted.
//   * GAP_PCT: percent chance of an idle (tvalid low) cycle before each beat.
//   * Data is held stable while tvalid && !tready (AXI4-Stream rule).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (the stream clock).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_tb_axis_src #(
  parameter int GAP_PCT = 0,               // percent idle cycles inside frames
  parameter int SEED    = 1
)(
  input  logic        clk,
  output logic [63:0] tdata,
  output logic [7:0]  tkeep,
  output logic        tlast,
  output logic        tvalid,
  input  logic        tready
);

  import rtlnet_tb_pkg::*;

  int gap_pct = GAP_PCT;
  int rng     = SEED;
  int sent    = 0;

  initial begin
    tdata  = '0;
    tkeep  = '0;
    tlast  = 1'b0;
    tvalid = 1'b0;
  end

  // Send one frame; returns after its last beat is accepted.
  task automatic send(input bytes_t frame);
    int n;
    int beats;
    n = frame.size();
    beats = (n + 7) / 8;
    for (int b = 0; b < beats; b++) begin
      while (gap_pct > 0 && ($urandom(rng) % 100) < gap_pct) begin
        rng++;
        tvalid <= 1'b0;
        @(posedge clk);
      end
      rng++;
      for (int l = 0; l < 8; l++) begin
        tdata[8*l +: 8] <= (8*b + l < n) ? frame[8*b + l] : 8'h00;
        tkeep[l]        <= (8*b + l < n);
      end
      tlast  <= (b == beats - 1);
      tvalid <= 1'b1;
      @(posedge clk);
      while (!tready) @(posedge clk);
    end
    tvalid <= 1'b0;
    tlast  <= 1'b0;
    sent++;
  endtask

  // Idle for n clocks.
  task automatic idle(input int n);
    tvalid <= 1'b0;
    repeat (n) @(posedge clk);
  endtask

endmodule
