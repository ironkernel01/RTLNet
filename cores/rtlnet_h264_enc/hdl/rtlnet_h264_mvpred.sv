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
// Revision: 11-12-2026
//   * 11-10-2026: initial version (phase 2c-1).
//   * 11-12-2026: stage 3c: split into the three stage modules (rtlnet_h264_mvpred chains them, same function).
// Clocks: none (combinational). The prediction is built from three stages, rtlnet_h264_mvpred_s1 (neighbour rules), _s2 (ordering of the
//   candidates, selection of the single neighbour) and _s3 (median and skip); rtlnet_h264_mvpred chains them, the motion vector context
//   (rtlnet_h264_mvctx) puts a register between them (stage 3c, timing: 12 logic levels with 4 carry chains in one clock).
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
  logic signed [MVW-1:0] ax, ay, bx, by, cx, cy;
  logic                  one, ra, rb, szf;
  logic signed [MVW-1:0] xmn, xmx, xc, xone, ymn, ymx, yc, yone;
  logic                  xlt, ylt;

  rtlnet_h264_mvpred_s1 #(.MVW(MVW)) u_s1 (
    .av_a(av_a), .inter_a(inter_a), .mvx_a(mvx_a), .mvy_a(mvy_a),
    .av_b(av_b), .inter_b(inter_b), .mvx_b(mvx_b), .mvy_b(mvy_b),
    .av_c(av_c), .inter_c(inter_c), .mvx_c(mvx_c), .mvy_c(mvy_c),
    .av_d(av_d), .inter_d(inter_d), .mvx_d(mvx_d), .mvy_d(mvy_d),
    .ax(ax), .ay(ay), .bx(bx), .by(by), .cx(cx), .cy(cy), .one(one), .ra(ra), .rb(rb), .skip_zero_f(szf)
  );
  rtlnet_h264_mvpred_s2 #(.MVW(MVW)) u_s2x (.a(ax), .b(bx), .c(cx), .ra(ra), .rb(rb), .mn(xmn), .mx(xmx), .c_o(xc), .lt(xlt), .one_v(xone));
  rtlnet_h264_mvpred_s2 #(.MVW(MVW)) u_s2y (.a(ay), .b(by), .c(cy), .ra(ra), .rb(rb), .mn(ymn), .mx(ymx), .c_o(yc), .lt(ylt), .one_v(yone));
  rtlnet_h264_mvpred_s3 #(.MVW(MVW)) u_s3x (.mn(xmn), .mx(xmx), .c(xc), .lt(xlt), .one_v(xone), .one(one), .skip_zero_f(szf), .mvp(mvp_x), .skip(skip_x));
  rtlnet_h264_mvpred_s3 #(.MVW(MVW)) u_s3y (.mn(ymn), .mx(ymx), .c(yc), .lt(ylt), .one_v(yone), .one(one), .skip_zero_f(szf), .mvp(mvp_y), .skip(skip_y));
  assign skip_zero = (skip_x == '0) && (skip_y == '0);
endmodule
