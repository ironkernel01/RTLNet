// -----------------------------------------------------------------------------
// File: rtlnet_h264_mvpred_s2.sv
// Purpose: stage 2 of the motion vector prediction (rtlnet_h264_mvpred.sv describes the stages; stage 3c split).
// Language: SystemVerilog-2012.
// Revision: 11-12-2026
// Clocks: none (combinational).
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// Stage 2 (one vector component): the ordering of the first two candidates, the comparison of the larger with the third, and the
// component of the single neighbour with refIdx 0 (selected by ra, rb; neither: C).
// -----------------------------------------------------------------------------
module rtlnet_h264_mvpred_s2 #(
  parameter int MVW = 14
)(
  input  logic signed [MVW-1:0]    a,
  input  logic signed [MVW-1:0]    b,
  input  logic signed [MVW-1:0]    c,
  input  logic                     ra,
  input  logic                     rb,
  output logic signed [MVW-1:0]    mn,
  output logic signed [MVW-1:0]    mx,
  output logic signed [MVW-1:0]    c_o,
  output logic                     lt,           // mx < c
  output logic signed [MVW-1:0]    one_v
);
  always_comb begin
    mn    = (a < b) ? a : b;
    mx    = (a < b) ? b : a;
    c_o   = c;
    lt    = (mx < c);
    one_v = ra ? a : (rb ? b : c);
  end
endmodule
