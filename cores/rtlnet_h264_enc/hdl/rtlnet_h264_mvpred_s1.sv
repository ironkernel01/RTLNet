// -----------------------------------------------------------------------------
// File: rtlnet_h264_mvpred_s1.sv
// Purpose: stage 1 of the motion vector prediction (rtlnet_h264_mvpred.sv describes the stages; stage 3c split).
// Language: SystemVerilog-2012.
// Revision: 11-12-2026
// Clocks: none (combinational).
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// Stage 1: the neighbour rules (clause 8.4.1.3.2): C replaced by D, intra / unavailable neighbours give mv 0, B and C replaced by A when
// both are unavailable and A is available; the single-neighbour flags; the P_Skip zero condition.
// -----------------------------------------------------------------------------
module rtlnet_h264_mvpred_s1 #(
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
  output logic signed [MVW-1:0]    ax,
  output logic signed [MVW-1:0]    ay,
  output logic signed [MVW-1:0]    bx,
  output logic signed [MVW-1:0]    by,
  output logic signed [MVW-1:0]    cx,
  output logic signed [MVW-1:0]    cy,
  output logic                     one,          // exactly one of the neighbours has refIdx 0
  output logic                     ra,           // it is A
  output logic                     rb,           // it is B (when neither, it is C)
  output logic                     skip_zero_f   // P_Skip: the skip vector is (0, 0)
);
  logic                  av_c2, inter_c2, rc;
  logic signed [MVW-1:0] mvx_c2, mvy_c2;
  logic                  sub;
  logic                  ra_w, rb_w;
  always_comb begin
    av_c2    = av_c ? av_c    : av_d;
    inter_c2 = av_c ? inter_c : inter_d;
    mvx_c2   = av_c ? mvx_c   : mvx_d;
    mvy_c2   = av_c ? mvy_c   : mvy_d;

    ra_w = av_a && inter_a;
    rb_w = av_b && inter_b;
    rc   = av_c2 && inter_c2;
    ax = ra_w ? mvx_a : '0;
    ay = ra_w ? mvy_a : '0;
    bx = rb_w ? mvx_b : '0;
    by = rb_w ? mvy_b : '0;
    cx = rc ? mvx_c2 : '0;
    cy = rc ? mvy_c2 : '0;

    sub = !av_b && !av_c2 && av_a;
    if (sub) begin
      bx = ax; by = ay; cx = ax; cy = ay;
      rb_w = ra_w; rc = ra_w;
    end
    ra  = ra_w;
    rb  = rb_w;
    one = (ra_w && !rb_w && !rc) || (!ra_w && rb_w && !rc) || (!ra_w && !rb_w && rc);

    skip_zero_f = !av_a || !av_b ||
                  (av_a && inter_a && (mvx_a == '0) && (mvy_a == '0)) ||
                  (av_b && inter_b && (mvx_b == '0) && (mvy_b == '0));
  end
endmodule
