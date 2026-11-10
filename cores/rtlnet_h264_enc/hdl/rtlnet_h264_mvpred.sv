// -----------------------------------------------------------------------------
// File: rtlnet_h264_mvpred.sv
// Purpose: motion vector prediction of a 16x16 macroblock partition of a P slice with one reference picture (ITU-T Rec.
//   H.264 clauses 8.4.1.3 and 8.4.1.1): the median predictor mvp for P_L0_16x16 and the motion vector of a P_Skip macroblock.
// Overview:
//   * Combinational. The caller supplies the neighbours of the macroblock: A (left), B (above), C (above right) and D (above
//     left), each as: av (the macroblock exists and is in the same slice: 6.4.8, 6.4.9), inter (it is coded in inter
//     prediction with reference index 0; an intra macroblock has inter 0) and its motion vector in quarter samples.
//   * Neighbouring partitions (clause 8.4.1.3.2): a neighbour that is not available or is intra gives mv 0 and refIdx -1; any
//     other neighbour gives its mv and refIdx 0. When C is not available, D takes its place (clause 8.4.1.3.2, "mbAddrC not
//     available"), including its availability.
//   * Median luma prediction (clause 8.4.1.3.1): when B and C are both not available and A is available, B and C take A's
//     values (availability, not intra status, decides this); then, with refIdx 0 for the current macroblock: if exactly one of
//     refIdxA, refIdxB, refIdxC is 0, mvp is that neighbour's mv; otherwise mvp is the component-wise median of the three.
//   * P_Skip (clause 8.4.1.1): mv is (0, 0) when A or B is not available, or A is inter with mv (0, 0), or B is inter with
//     mv (0, 0); otherwise it is mvp. skip_zero is high when that mv is (0, 0).
//   * 16x16 only (no 16x8 / 8x16 directional rules, no sub-partitions); one reference picture, so refIdx is 0 for every inter
//     macroblock.
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-1).
// Clocks: none (combinational).
// -----------------------------------------------------------------------------
module rtlnet_h264_mvpred #(
  parameter int MVW = 14
)(
  input  logic                     av_a,
  input  logic                     inter_a,
  input  logic signed [MVW-1:0]    mvx_a,
  input  logic signed [MVW-1:0]    mvy_a,
  input  logic                     av_b,
  input  logic                     inter_b,
  input  logic signed [MVW-1:0]    mvx_b,
  input  logic signed [MVW-1:0]    mvy_b,
  input  logic                     av_c,
  input  logic                     inter_c,
  input  logic signed [MVW-1:0]    mvx_c,
  input  logic signed [MVW-1:0]    mvy_c,
  input  logic                     av_d,
  input  logic                     inter_d,
  input  logic signed [MVW-1:0]    mvx_d,
  input  logic signed [MVW-1:0]    mvy_d,
  output logic signed [MVW-1:0]    mvp_x,
  output logic signed [MVW-1:0]    mvp_y,
  output logic signed [MVW-1:0]    skip_x,
  output logic signed [MVW-1:0]    skip_y,
  output logic                     skip_zero
);

  function automatic logic signed [MVW-1:0] med3(input logic signed [MVW-1:0] a, input logic signed [MVW-1:0] b,
                                                 input logic signed [MVW-1:0] c);
    logic signed [MVW-1:0] mn, mx;
    mn = (a < b) ? a : b;
    mx = (a < b) ? b : a;
    // median = max(min(a, b), min(max(a, b), c))
    return (mn > ((mx < c) ? mx : c)) ? mn : ((mx < c) ? mx : c);
  endfunction

  // Neighbour C, or D in its place.
  logic                  av_c2, inter_c2;
  logic signed [MVW-1:0] mvx_c2, mvy_c2;
  // refIdx 0 flags and mv after the intra / unavailable rule.
  logic                  ra, rb, rc;
  logic signed [MVW-1:0] ax, ay, bx, by, cx, cy;
  logic                  sub;     // B and C replaced by A

  always_comb begin
    av_c2    = av_c ? av_c    : av_d;
    inter_c2 = av_c ? inter_c : inter_d;
    mvx_c2   = av_c ? mvx_c   : mvx_d;
    mvy_c2   = av_c ? mvy_c   : mvy_d;

    ra = av_a && inter_a;
    rb = av_b && inter_b;
    rc = av_c2 && inter_c2;
    ax = ra ? mvx_a : '0;
    ay = ra ? mvy_a : '0;
    bx = rb ? mvx_b : '0;
    by = rb ? mvy_b : '0;
    cx = rc ? mvx_c2 : '0;
    cy = rc ? mvy_c2 : '0;

    sub = !av_b && !av_c2 && av_a;
    if (sub) begin
      bx = ax; by = ay; cx = ax; cy = ay;
      rb = ra; rc = ra;
    end

    if ((ra && !rb && !rc) || (!ra && rb && !rc) || (!ra && !rb && rc)) begin
      mvp_x = ra ? ax : (rb ? bx : cx);
      mvp_y = ra ? ay : (rb ? by : cy);
    end else begin
      mvp_x = med3(ax, bx, cx);
      mvp_y = med3(ay, by, cy);
    end

    // P_Skip (clause 8.4.1.1): the neighbours A and B as derived by clause 8.4.1.3.2 (no substitution).
    if (!av_a || !av_b ||
        (av_a && inter_a && (mvx_a == '0) && (mvy_a == '0)) ||
        (av_b && inter_b && (mvx_b == '0) && (mvy_b == '0))) begin
      skip_x = '0;
      skip_y = '0;
    end else begin
      skip_x = mvp_x;
      skip_y = mvp_y;
    end
    skip_zero = (skip_x == '0) && (skip_y == '0);
  end

endmodule
