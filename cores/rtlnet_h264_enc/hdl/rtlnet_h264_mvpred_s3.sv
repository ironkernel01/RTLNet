// -----------------------------------------------------------------------------
// File: rtlnet_h264_mvpred_s3.sv
// Purpose: stage 3 of the motion vector prediction (rtlnet_h264_mvpred.sv describes the stages; stage 3c split).
// Language: SystemVerilog-2012.
// Revision: 11-12-2026
// Clocks: none (combinational).
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// Stage 3 (one vector component): median = max(min(a, b), min(max(a, b), c)), or the single neighbour's component; P_Skip zero.
// -----------------------------------------------------------------------------
module rtlnet_h264_mvpred_s3 #(
  parameter int MVW = 14
)(
  input  logic signed [MVW-1:0]    mn,
  input  logic signed [MVW-1:0]    mx,
  input  logic signed [MVW-1:0]    c,
  input  logic                     lt,
  input  logic signed [MVW-1:0]    one_v,
  input  logic                     one,
  input  logic                     skip_zero_f,
  output logic signed [MVW-1:0]    mvp,
  output logic signed [MVW-1:0]    skip
);
  logic signed [MVW-1:0] m2;
  always_comb begin
    m2   = lt ? mx : c;
    mvp  = one ? one_v : ((mn > m2) ? mn : m2);
    skip = skip_zero_f ? '0 : mvp;
  end
endmodule
