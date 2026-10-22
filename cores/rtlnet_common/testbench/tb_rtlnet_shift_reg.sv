// -----------------------------------------------------------------------------
// File: tb_rtlnet_shift_reg.sv
// Purpose: self-checking bench for rtlnet_shift_reg_core: for depths 2, 5, 16,
//   32, 33, 64 and 70 (single SRL, exact SRL length, one and two cascades),
//   random data and a random shift enable, the output equals the input delayed
//   by exactly DEPTH enabled clocks, every clock, after the line has filled.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_shift_reg;

  import rtlnet_tb_pkg::*;

  localparam int W = 11;
  localparam int N = 7;
  localparam int DEPTHS [N] = '{2, 5, 16, 32, 33, 64, 70};

  logic         clk = 0;
  logic         ce  = 0;
  logic [W-1:0] d   = '0;
  logic [W-1:0] q [N];

  always #5 clk = ~clk;

  genvar gi;
  generate
    for (gi = 0; gi < N; gi++) begin : g_dut
      rtlnet_shift_reg_core #(.DATA_W(W), .DEPTH(DEPTHS[gi])) u_dut (
        .clk(clk), .ce(ce), .d(d), .q(q[gi]));
    end
  endgenerate

  // Model: history of the values shifted in (one entry per enabled clock).
  logic [W-1:0] hist [$];

  initial begin : main
    int unsigned rng;
    int          shifts;
    rng = 17;
    shifts = 0;
    repeat (3) @(posedge clk);
    for (int t = 0; t < 4000; t++) begin
      rng = rng * 1664525 + 1013904223;
      @(negedge clk);
      ce = ((rng >> 20) % 4) != 0;          // shift 75 % of clocks
      d  = W'(rng >> 8);
      @(posedge clk);
      if (ce) begin
        hist.push_front(d);
        shifts++;
      end
      #1;
      for (int k = 0; k < N; k++) begin
        if (shifts >= DEPTHS[k]) begin
          tb_check(q[k] === hist[DEPTHS[k] - 1],
                   $sformatf("depth %0d: q=%h expected %h after %0d shifts", DEPTHS[k], q[k], hist[DEPTHS[k] - 1], shifts));
        end
      end
      if (hist.size() > 80) void'(hist.pop_back());
    end
    tb_verdict("tb_rtlnet_shift_reg");
  end

endmodule
