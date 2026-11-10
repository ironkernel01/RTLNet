// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_mvpred.sv
// Purpose: self-checking bench of the motion vector prediction of the P-picture encoder: rtlnet_h264_mvpred (the median
//   predictor of ITU-T Rec. H.264 clause 8.4.1.3 for a 16x16 partition and the P_Skip vector of clause 8.4.1.1) and
//   rtlnet_h264_mvctx (the line RAM and the left registers that supply its neighbours), against a reference written in the
//   bench from the clause text.
// Overview:
//   * Reference (ref_pred): neighbouring partitions A, B, C (C replaced by D when it is not available) with availability, intra
//     status and vector; unavailable and intra neighbours get mv 0 and refIdx -1 (8.4.1.3.2); when B and C are both not
//     available and A is, B and C take A (8.4.1.3.1); exactly one refIdx equal to 0 selects that vector, else the component-wise
//     median (sorted, middle element); the skip vector is 0 when A or B is not available or A or B has refIdx 0 and mv 0
//     (8.4.1.1), else the predictor.
//   * Directed cases: no neighbour, only A, only B, only C, only D (C unavailable, D substituted), B and C unavailable with an
//     intra A (A "available" but refIdx -1: B and C copy A, so mvp 0), exactly one matching refIdx in each position, all
//     three matching (median) with ties and negative components, the skip vector with a zero A or zero B, maximum and minimum
//     vectors (+-8191) of the 14-bit components.
//   * Random cases: 200 000 random neighbour sets (availability, intra flag and vectors from a small, a medium and a full range,
//     including the zero vector with high probability) against the reference.
//   * mvctx: pictures of 7 x 5 macroblocks with random slice starts (a row that starts a slice has no upper neighbours), random
//     macroblock types (intra / I_PCM, P_L0_16x16 with a random vector, drawn from 0, a neighbour's vector or a random one, and
//     P_Skip at the skip vector). For each macroblock the bench starts the context with the geometric availability (left: not the
//     first column; above: not the first row of the slice; above right: above and a column to the right), waits for ready and
//     compares mvp, the skip vector and skip_zero with the reference computed from the bench's own picture arrays (so the
//     above-left shift register and the line RAM are checked at the picture edges, the slice edges and the right edge), then
//     updates the context with the macroblock's type and vector.
//   * +INJECT_FAILURE is the negative control (forces one failed check).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-1).
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_mvpred;

  import rtlnet_tb_pkg::*;

  localparam int W = 7;
  localparam int H = 5;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #5 clk = ~clk;

  // Combinational predictor under test.
  logic                  av_a = 0, inter_a = 0, av_b = 0, inter_b = 0, av_c = 0, inter_c = 0, av_d = 0, inter_d = 0;
  logic signed [13:0]    mvx_a = 0, mvy_a = 0, mvx_b = 0, mvy_b = 0, mvx_c = 0, mvy_c = 0, mvx_d = 0, mvy_d = 0;
  logic signed [13:0]    mvp_x, mvp_y, skip_x, skip_y;
  logic                  skip_zero;

  rtlnet_h264_mvpred #(.MVW(14)) dut (
    .av_a(av_a), .inter_a(inter_a), .mvx_a(mvx_a), .mvy_a(mvy_a),
    .av_b(av_b), .inter_b(inter_b), .mvx_b(mvx_b), .mvy_b(mvy_b),
    .av_c(av_c), .inter_c(inter_c), .mvx_c(mvx_c), .mvy_c(mvy_c),
    .av_d(av_d), .inter_d(inter_d), .mvx_d(mvx_d), .mvy_d(mvy_d),
    .mvp_x(mvp_x), .mvp_y(mvp_y), .skip_x(skip_x), .skip_y(skip_y), .skip_zero(skip_zero)
  );

  // Context under test.
  logic        c_start = 0, c_av_top = 0, c_av_left = 0, c_av_tr = 0, c_ready, c_zero;
  logic [6:0]  c_x = 0;
  logic signed [13:0] c_mvp_x, c_mvp_y, c_skip_x, c_skip_y;
  logic        c_upd = 0, c_upd_inter = 0;
  logic signed [13:0] c_upd_x = 0, c_upd_y = 0;

  rtlnet_h264_mvctx #(.MAX_MB_W(W), .MV_LINE_KB(1), .RAM_STYLE("distributed")) ctx (
    .clk(clk), .resetn(resetn), .start(c_start), .mb_x(c_x), .av_top(c_av_top), .av_left(c_av_left), .av_tr(c_av_tr),
    .ready(c_ready), .mvp_x(c_mvp_x), .mvp_y(c_mvp_y), .skip_x(c_skip_x), .skip_y(c_skip_y), .skip_zero(c_zero),
    .upd(c_upd), .upd_inter(c_upd_inter), .upd_mvx(c_upd_x), .upd_mvy(c_upd_y)
  );

  // ---------------------------------------------------------------------------
  // Reference (clauses 8.4.1.1, 8.4.1.3, 8.4.1.3.1, 8.4.1.3.2)
  // ---------------------------------------------------------------------------
  function automatic int median3(input int a, input int b, input int c);
    int t [3];
    int tmp;
    t[0] = a; t[1] = b; t[2] = c;
    for (int i = 0; i < 2; i++) begin
      for (int j = 0; j < 2 - i; j++) begin
        if (t[j] > t[j + 1]) begin tmp = t[j]; t[j] = t[j + 1]; t[j + 1] = tmp; end
      end
    end
    return t[1];
  endfunction

  // n: neighbours 0 A, 1 B, 2 C, 3 D. av = partition available, it = coded in inter prediction (refIdx 0).
  function automatic void ref_pred(input bit av [4], input bit it [4], input int vx [4], input int vy [4],
                                   output int px, output int py, output int sx, output int sy);
    bit  a_av, b_av, c_av;
    int  ref_n [3];
    int  mx [3];
    int  my [3];
    int  cnt1, which;
    bit  cu;
    // C or its replacement D (clause 8.4.1.3.2).
    cu = av[2];
    c_av = av[2] ? 1'b1 : av[3];
    a_av = av[0];
    b_av = av[1];
    for (int k = 0; k < 3; k++) begin
      int src;
      bit  a_ok;
      src = (k == 2 && !cu) ? 3 : k;
      a_ok = av[src] && it[src];
      ref_n[k] = a_ok ? 0 : -1;
      mx[k] = a_ok ? vx[src] : 0;
      my[k] = a_ok ? vy[src] : 0;
    end
    // Clause 8.4.1.3.1: both B and C not available and A available.
    if (!b_av && !c_av && a_av) begin
      mx[1] = mx[0]; my[1] = my[0]; ref_n[1] = ref_n[0];
      mx[2] = mx[0]; my[2] = my[0]; ref_n[2] = ref_n[0];
    end
    cnt1 = 0;
    which = -1;
    for (int k = 0; k < 3; k++) if (ref_n[k] == 0) begin cnt1++; which = k; end
    if (cnt1 == 1) begin
      px = mx[which];
      py = my[which];
    end else begin
      px = median3(mx[0], mx[1], mx[2]);
      py = median3(my[0], my[1], my[2]);
    end
    // Clause 8.4.1.1: P_Skip.
    if (!av[0] || !av[1] || (av[0] && it[0] && vx[0] == 0 && vy[0] == 0) || (av[1] && it[1] && vx[1] == 0 && vy[1] == 0)) begin
      sx = 0; sy = 0;
    end else begin
      sx = px; sy = py;
    end
  endfunction

  function automatic int rnd_mv(input int kind);
    case (kind)
      0: return $urandom_range(0, 6) - 3;
      1: return $urandom_range(0, 200) - 100;
      2: return $urandom_range(0, 16383) - 8192;
      default: return 0;
    endcase
  endfunction

  int cases = 0;
  int cnt_single = 0, cnt_sub = 0, cnt_dsub = 0, cnt_median = 0, cnt_skipzero = 0, cnt_skipmvp = 0;

  // Apply one neighbour set to the DUT and compare.
  task automatic apply_and_check(input bit av [4], input bit it [4], input int vx [4], input int vy [4], input string what);
    int px, py, sx, sy;
    ref_pred(av, it, vx, vy, px, py, sx, sy);
    av_a = av[0]; inter_a = it[0]; mvx_a = 14'(vx[0]); mvy_a = 14'(vy[0]);
    av_b = av[1]; inter_b = it[1]; mvx_b = 14'(vx[1]); mvy_b = 14'(vy[1]);
    av_c = av[2]; inter_c = it[2]; mvx_c = 14'(vx[2]); mvy_c = 14'(vy[2]);
    av_d = av[3]; inter_d = it[3]; mvx_d = 14'(vx[3]); mvy_d = 14'(vy[3]);
    #1;
    tb_check((int'(mvp_x) == px) && (int'(mvp_y) == py),
             $sformatf("%s: mvp (%0d,%0d) expected (%0d,%0d); A %0d/%0d (%0d,%0d) B %0d/%0d (%0d,%0d) C %0d/%0d (%0d,%0d) D %0d/%0d (%0d,%0d)", what,
                       mvp_x, mvp_y, px, py, av[0], it[0], vx[0], vy[0], av[1], it[1], vx[1], vy[1], av[2], it[2], vx[2], vy[2], av[3], it[3], vx[3], vy[3]));
    tb_check((int'(skip_x) == sx) && (int'(skip_y) == sy), $sformatf("%s: skip vector (%0d,%0d) expected (%0d,%0d)", what, skip_x, skip_y, sx, sy));
    tb_check(skip_zero == ((sx == 0) && (sy == 0)), $sformatf("%s: skip_zero", what));
    cases++;
    if (sx == 0 && sy == 0) cnt_skipzero++; else cnt_skipmvp++;
  endtask

  task automatic directed();
    bit av [4];
    bit it [4];
    int vx [4];
    int vy [4];
    // No neighbour at all: mvp 0, skip 0.
    av = '{0, 0, 0, 0}; it = '{0, 0, 0, 0}; vx = '{5, 6, 7, 8}; vy = '{-5, -6, -7, -8};
    apply_and_check(av, it, vx, vy, "no neighbour");
    // Only A (inter): B and C copy A.
    av = '{1, 0, 0, 0}; it = '{1, 0, 0, 0}; vx = '{12, 0, 0, 0}; vy = '{-9, 0, 0, 0};
    apply_and_check(av, it, vx, vy, "only A inter");
    // Only A and A is intra: refIdxA -1, so all three -1: median of zeros.
    av = '{1, 0, 0, 0}; it = '{0, 0, 0, 0}; vx = '{12, 0, 0, 0}; vy = '{-9, 0, 0, 0};
    apply_and_check(av, it, vx, vy, "only A intra");
    // Only B (A, C, D unavailable): single match, B's vector.
    av = '{0, 1, 0, 0}; it = '{0, 1, 0, 0}; vx = '{0, 21, 0, 0}; vy = '{0, 4, 0, 0};
    apply_and_check(av, it, vx, vy, "only B inter");
    // Only C.
    av = '{0, 0, 1, 0}; it = '{0, 0, 1, 0}; vx = '{0, 0, -33, 0}; vy = '{0, 0, 17, 0};
    apply_and_check(av, it, vx, vy, "only C inter");
    // C unavailable, D available: D takes C's place.
    av = '{0, 0, 0, 1}; it = '{0, 0, 0, 1}; vx = '{0, 0, 0, 44}; vy = '{0, 0, 0, -45};
    apply_and_check(av, it, vx, vy, "only D inter (substituted for C)");
    // A and D available, B and C not: D replaces C, so B and C are not both unavailable.
    av = '{1, 0, 0, 1}; it = '{1, 0, 0, 1}; vx = '{10, 0, 0, -30}; vy = '{3, 0, 0, 8};
    apply_and_check(av, it, vx, vy, "A and D, B unavailable");
    // A and B available, C and D unavailable: refIdxC -1.
    av = '{1, 1, 0, 0}; it = '{1, 1, 0, 0}; vx = '{10, 20, 0, 0}; vy = '{-10, -20, 0, 0};
    apply_and_check(av, it, vx, vy, "A and B, C unavailable");
    // All three inter: median, negative components, ties.
    av = '{1, 1, 1, 1}; it = '{1, 1, 1, 1}; vx = '{-4, 9, 2, 100}; vy = '{7, 7, -3, 100};
    apply_and_check(av, it, vx, vy, "median of three");
    av = '{1, 1, 1, 1}; it = '{1, 1, 1, 1}; vx = '{3, 3, 3, 0}; vy = '{-8, -8, 5, 0};
    apply_and_check(av, it, vx, vy, "median with ties");
    // Exactly one inter among the three (the others intra): that one's vector.
    av = '{1, 1, 1, 1}; it = '{0, 1, 0, 0}; vx = '{50, -7, 50, 50}; vy = '{50, 13, 50, 50};
    apply_and_check(av, it, vx, vy, "single matching refIdx: B");
    av = '{1, 1, 1, 1}; it = '{0, 0, 1, 0}; vx = '{50, 50, -7, 50}; vy = '{50, 50, 13, 50};
    apply_and_check(av, it, vx, vy, "single matching refIdx: C");
    av = '{1, 1, 1, 1}; it = '{1, 0, 0, 0}; vx = '{-7, 50, 50, 50}; vy = '{13, 50, 50, 50};
    apply_and_check(av, it, vx, vy, "single matching refIdx: A");
    // C unavailable and D intra, A and B inter: two matches, median of A, B and 0.
    av = '{1, 1, 0, 1}; it = '{1, 1, 0, 0}; vx = '{8, -8, 0, 30}; vy = '{8, -8, 0, 30};
    apply_and_check(av, it, vx, vy, "D intra replaces C");
    // None inter though all available: median of zeros.
    av = '{1, 1, 1, 1}; it = '{0, 0, 0, 0}; vx = '{9, 9, 9, 9}; vy = '{9, 9, 9, 9};
    apply_and_check(av, it, vx, vy, "all intra");
    // Skip vector: zero A (inter, mv 0) forces 0 although the predictor is not 0.
    av = '{1, 1, 1, 1}; it = '{1, 1, 1, 1}; vx = '{0, 20, 21, 0}; vy = '{0, 20, 22, 0};
    apply_and_check(av, it, vx, vy, "skip: A zero");
    av = '{1, 1, 1, 1}; it = '{1, 1, 1, 1}; vx = '{20, 0, 21, 0}; vy = '{20, 0, 22, 0};
    apply_and_check(av, it, vx, vy, "skip: B zero");
    // Skip vector: A intra with mv 0 does not count (refIdxA is -1): the predictor is used.
    av = '{1, 1, 1, 1}; it = '{0, 1, 1, 0}; vx = '{0, 5, 7, 0}; vy = '{0, 6, 8, 0};
    apply_and_check(av, it, vx, vy, "skip: A intra, B and C inter");
    // Skip vector: B unavailable forces 0.
    av = '{1, 0, 1, 1}; it = '{1, 0, 1, 1}; vx = '{5, 0, 7, 9}; vy = '{6, 0, 8, 9};
    apply_and_check(av, it, vx, vy, "skip: B unavailable");
    // Extremes of the 14-bit components.
    av = '{1, 1, 1, 1}; it = '{1, 1, 1, 1}; vx = '{8191, -8192, 8191, 0}; vy = '{-8192, -8192, 8191, 0};
    apply_and_check(av, it, vx, vy, "extreme components");
  endtask

  task automatic random_cases(input int n);
    bit av [4];
    bit it [4];
    int vx [4];
    int vy [4];
    int kind;
    for (int i = 0; i < n; i++) begin
      kind = $urandom_range(0, 3);
      for (int k = 0; k < 4; k++) begin
        av[k] = ($urandom_range(0, 3) != 0);
        it[k] = ($urandom_range(0, 3) != 0);
        vx[k] = rnd_mv(($urandom_range(0, 3) == 0) ? 3 : kind);
        vy[k] = rnd_mv(($urandom_range(0, 3) == 0) ? 3 : kind);
      end
      // Make the vectors of neighbours equal now and then (the median and skip rules see ties).
      if ($urandom_range(0, 5) == 0) begin vx[1] = vx[0]; vy[1] = vy[0]; end
      if ($urandom_range(0, 5) == 0) begin vx[2] = vx[1]; vy[2] = vy[1]; end
      apply_and_check(av, it, vx, vy, "random");
    end
  endtask

  // ---------------------------------------------------------------------------
  // mvctx: pictures with slices
  // ---------------------------------------------------------------------------
  int pic_vx [H][W];
  int pic_vy [H][W];
  bit pic_it [H][W];
  bit ss [H];
  int ctx_mbs = 0, ctx_types [3];

  task automatic ctx_mb(input int r, input int x);
    bit av [4];
    bit it [4];
    int vx [4];
    int vy [4];
    int px, py, sx, sy, ty, mx, my, t;
    bit avt, avl, avtr, ok;
    avt  = !ss[r];
    avl  = (x > 0);
    avtr = avt && ((x + 1) < W);
    av[0] = avl;                    it[0] = avl ? pic_it[r][x-1] : 0;     vx[0] = avl ? pic_vx[r][x-1] : 0;     vy[0] = avl ? pic_vy[r][x-1] : 0;
    av[1] = avt;                    it[1] = avt ? pic_it[r-1][x] : 0;     vx[1] = avt ? pic_vx[r-1][x] : 0;     vy[1] = avt ? pic_vy[r-1][x] : 0;
    av[2] = avtr;                   it[2] = avtr ? pic_it[r-1][x+1] : 0;  vx[2] = avtr ? pic_vx[r-1][x+1] : 0;  vy[2] = avtr ? pic_vy[r-1][x+1] : 0;
    av[3] = avt && avl;             it[3] = (avt && avl) ? pic_it[r-1][x-1] : 0;
    vx[3] = (avt && avl) ? pic_vx[r-1][x-1] : 0;  vy[3] = (avt && avl) ? pic_vy[r-1][x-1] : 0;
    ref_pred(av, it, vx, vy, px, py, sx, sy);
    @(negedge clk);
    c_start = 1'b1; c_x = 7'(x); c_av_top = avt; c_av_left = avl; c_av_tr = avtr;
    @(negedge clk);
    c_start = 1'b0;
    ok = 0;
    t = 0;
    while (!ok && t < 30) begin
      if (c_ready) ok = 1;
      else @(negedge clk);
      t++;
    end
    tb_check(ok, "mvctx ready");
    tb_check(t <= 8, $sformatf("mvctx took %0d clocks to be ready", t));
    tb_check((int'(c_mvp_x) == px) && (int'(c_mvp_y) == py),
             $sformatf("mvctx mb (%0d,%0d) mvp (%0d,%0d) expected (%0d,%0d) avt %0d avl %0d avtr %0d", r, x, c_mvp_x, c_mvp_y, px, py, avt, avl, avtr));
    tb_check((int'(c_skip_x) == sx) && (int'(c_skip_y) == sy) && (c_zero == ((sx == 0) && (sy == 0))),
             $sformatf("mvctx mb (%0d,%0d) skip vector (%0d,%0d) expected (%0d,%0d)", r, x, c_skip_x, c_skip_y, sx, sy));
    // The macroblock's type: 0 intra, 1 inter with a vector, 2 skip at the skip vector.
    ty = $urandom_range(0, 2);
    case ($urandom_range(0, 3))
      0: begin mx = 0; my = 0; end
      1: begin mx = px; my = py; end
      2: begin mx = vx[1]; my = vy[1]; end
      default: begin mx = rnd_mv(1); my = rnd_mv(1); end
    endcase
    ctx_types[ty]++;
    @(negedge clk);
    c_upd = 1'b1;
    if (ty == 0)      begin c_upd_inter = 0; c_upd_x = 0;       c_upd_y = 0;       pic_it[r][x] = 0; pic_vx[r][x] = 0;  pic_vy[r][x] = 0; end
    else if (ty == 1) begin c_upd_inter = 1; c_upd_x = 14'(mx); c_upd_y = 14'(my); pic_it[r][x] = 1; pic_vx[r][x] = mx; pic_vy[r][x] = my; end
    else              begin c_upd_inter = 1; c_upd_x = 14'(sx); c_upd_y = 14'(sy); pic_it[r][x] = 1; pic_vx[r][x] = sx; pic_vy[r][x] = sy; end
    @(negedge clk);
    c_upd = 1'b0;
    ctx_mbs++;
    repeat ($urandom_range(0, 3)) @(negedge clk);
  endtask

  initial begin
    for (int i = 0; i < 3; i++) ctx_types[i] = 0;
    resetn = 1'b0;
    repeat (4) @(negedge clk);
    resetn = 1'b1;
    repeat (2) @(negedge clk);
    directed();
    random_cases(200000);
    for (int pic = 0; pic < 60; pic++) begin
      for (int r = 0; r < H; r++) ss[r] = (r == 0) || ($urandom_range(0, 2) == 0);
      for (int r = 0; r < H; r++) for (int x = 0; x < W; x++) ctx_mb(r, x);
    end
    $display("STAT mvpred cases=%0d (skip zero %0d, skip = predictor %0d); mvctx macroblocks=%0d (intra %0d, inter %0d, skip %0d)",
             cases, cnt_skipzero, cnt_skipmvp, ctx_mbs, ctx_types[0], ctx_types[1], ctx_types[2]);
    tb_check(cnt_skipmvp > 1000, "coverage of the skip = predictor case");
    tb_verdict("tb_rtlnet_h264_mvpred");
  end

  initial begin
    #3000000000;
    tb_error("watchdog");
    tb_verdict("tb_rtlnet_h264_mvpred");
  end

endmodule
