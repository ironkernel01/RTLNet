// -----------------------------------------------------------------------------
// File: rtlnet_h264_ipred.sv
// Purpose: intra prediction of one macroblock for the H.264 encoder engine: neighbour state, Intra16x16 luma
//   prediction (clause 8.3.3) and intra chroma prediction (clause 8.3.4), a four-mode prediction query port,
//   SAD accumulation and the mode decision.
// Overview:
//   * nb_load captures the neighbours (row above, column to the left, above-left sample of luma, Cb and Cr) and the
//     availability of the above and left macroblocks (the above-left sample is available when both are), clears the
//     SAD accumulators and starts the preparation: the plane parameters H, V, b, c and the constant k0 of each of the
//     three planes (serial multiply-accumulate, one step per clock) and the DC values (luma, and the four 4x4 blocks
//     of each chroma plane). prep_done pulses at most 24 clocks after nb_load; queries follow after it.
//   * A query (q_valid) names a plane (0 luma, 1 Cb, 2 Cr), a 4-sample row segment (q_seg, q_y) and carries the four
//     source samples. Two clocks later p_valid and p_px return the prediction of all four modes for that segment, mode m
//     at [32*m +: 32] with the spec mode number of the plane type (luma 0 V, 1 H, 2 DC, 3 Plane; chroma 0 DC, 1 H, 2 V,
//     3 Plane). The samples of an illegal mode (V without the above MB, H without the left MB, Plane without both) read 0.
//     Queries may come every clock.
//   * With q_acc the segment's SAD against q_src is added to the accumulators of the legal modes: luma into sad_y,
//     Cb and Cr together into sad_c (4 x 18 bits, mode m at [18*m +: 18]; an illegal mode stays 0). The accumulators
//     are final 4 clocks after the last q_valid; dec_start may be given 3 clocks after the last q_valid (two idle clocks
//     between) or later. dec_done pulses 5 clocks after dec_start.
//   * Decision: total(m) = SAD(m) + cost(m) over the legal modes, ties go to the first of the order DC, V, H, Plane.
//     Luma cost DC 0, V 16, H 16, Plane 32; chroma cost DC 0, H 16, V 16, Plane 32. dec_luma_mode / dec_chroma_mode
//     carry the spec mode numbers (DC when nothing else is legal).
//   * Plane prediction: Clip1((a + b*(x-C) + c*(y-C) + 16) >> 5) with C 7 (luma) or 3 (chroma), evaluated as
//     (k0 + c*y + b*x) >> 5 with k0 = a + 16 - C*(b + c). H and V sums use the above-left sample at the end of the sum.
//   * A new nb_load, or a query before prep_done, is not allowed.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_ipred (
  // Clock and synchronous active-low reset.
  input  logic         clk,
  input  logic         resetn,

  // Neighbour load, clk domain: nb_load pulses one clock when idle.
  input  logic         nb_load,
  input  logic [127:0] nb_top_y,
  input  logic [127:0] nb_left_y,
  input  logic [7:0]   nb_tl_y,
  input  logic [127:0] nb_top_c,
  input  logic [127:0] nb_left_c,
  input  logic [7:0]   nb_tl_cb,
  input  logic [7:0]   nb_tl_cr,
  input  logic         nb_av_top,
  input  logic         nb_av_left,
  output logic         prep_done,

  // Prediction query, clk domain: p_valid and p_px follow q_valid by two clocks.
  input  logic         q_valid,
  input  logic [1:0]   q_plane,
  input  logic [1:0]   q_seg,
  input  logic [3:0]   q_y,
  input  logic [31:0]  q_src,
  input  logic         q_acc,
  output logic         p_valid,
  output logic [127:0] p_px,

  // Mode decision, clk domain.
  input  logic         dec_start,
  output logic         dec_done,
  output logic [1:0]   dec_luma_mode,
  output logic [1:0]   dec_chroma_mode,
  output logic [71:0]  sad_y,
  output logic [71:0]  sad_c
);

  // ---------------------------------------------------------------------------
  // Neighbour registers and availability
  // ---------------------------------------------------------------------------
  logic [127:0] top_y, left_y, top_c, left_c;
  logic [7:0]   tl_y, tl_cb, tl_cr;
  logic         av_top, av_left;
  logic [3:0]   leg_y;   // legal modes by spec number
  logic [3:0]   leg_c;

  // ---------------------------------------------------------------------------
  // Preparation: step generator (plane pl, index i), difference stage, accumulate stage
  // ---------------------------------------------------------------------------
  logic        g_run;
  logic [1:0]  g_pl;
  logic [2:0]  g_i;
  logic        g_last_i;

  logic        s1_v;
  logic [1:0]  s1_pl;
  logic [2:0]  s1_i;
  logic        s1_last;
  logic signed [8:0] s1_dh, s1_dv;

  logic signed [16:0] acc_h, acc_v;
  logic signed [16:0] hsum [3];
  logic signed [16:0] vsum [3];
  logic        sum_done;

  logic [1:0]  fin;     // 0 idle, 1 sums, 2 params and DC
  logic signed [12:0] pb [3];
  logic signed [12:0] pc [3];
  logic signed [19:0] pk0 [3];
  logic [7:0]  dc_y;
  logic [7:0]  dc_c [2][4];

  logic [11:0] sum_top_y, sum_left_y;
  logic [9:0]  t0 [2];
  logic [9:0]  t1 [2];
  logic [9:0]  l0 [2];
  logic [9:0]  l1 [2];

  // 8-bit sample pick of a plane's above row or left column; the index 7 step of the last position is the corner.
  function automatic logic [7:0] pick_top(input logic [1:0] pl, input logic [3:0] idx);
    logic [7:0] r;
    case (pl)
      2'd0:    r = top_y[8*idx +: 8];
      2'd1:    r = top_c[8*idx[2:0] +: 8];
      default: r = top_c[64 + 8*idx[2:0] +: 8];
    endcase
    return r;
  endfunction

  function automatic logic [7:0] pick_left(input logic [1:0] pl, input logic [3:0] idx);
    logic [7:0] r;
    case (pl)
      2'd0:    r = left_y[8*idx +: 8];
      2'd1:    r = left_c[8*idx[2:0] +: 8];
      default: r = left_c[64 + 8*idx[2:0] +: 8];
    endcase
    return r;
  endfunction

  logic [3:0]  hi_idx, lo_idx;
  logic [7:0]  tl_sel;
  logic        lo_is_tl;
  logic [7:0]  top_hi, top_lo, left_hi, left_lo;

  // Luma: hi = 8 + i, lo = 6 - i (i = 7: corner). Chroma: hi = 4 + i, lo = 2 - i (i = 3: corner).
  assign hi_idx   = (g_pl == 2'd0) ? (4'd8 + {1'b0, g_i}) : (4'd4 + {1'b0, g_i});
  assign lo_is_tl = (g_pl == 2'd0) ? (g_i == 3'd7) : (g_i == 3'd3);
  assign lo_idx   = (g_pl == 2'd0) ? (4'd6 - {1'b0, g_i}) : (4'd2 - {1'b0, g_i});
  assign tl_sel   = (g_pl == 2'd0) ? tl_y : ((g_pl == 2'd1) ? tl_cb : tl_cr);
  assign top_hi   = pick_top(g_pl, hi_idx);
  assign top_lo   = lo_is_tl ? tl_sel : pick_top(g_pl, lo_idx);
  assign left_hi  = pick_left(g_pl, hi_idx);
  assign left_lo  = lo_is_tl ? tl_sel : pick_left(g_pl, lo_idx);
  assign g_last_i = (g_pl == 2'd0) ? (g_i == 3'd7) : (g_i == 3'd3);

  logic signed [16:0] newh, newv;
  logic signed [4:0]  w_s2;
  logic signed [13:0] prod_h, prod_v;
  assign w_s2   = $signed({2'b00, s1_i}) + 5'sd1;
  assign prod_h = s1_dh * w_s2;
  assign prod_v = s1_dv * w_s2;
  assign newh = ((s1_i == 3'd0) ? 17'sd0 : acc_h) + 17'(prod_h);
  assign newv = ((s1_i == 3'd0) ? 17'sd0 : acc_v) + 17'(prod_v);

  // Plane parameter helpers.
  function automatic logic signed [12:0] b_of(input logic signed [16:0] h, input logic chroma);
    logic signed [23:0] m;
    if (chroma) m = (24'(h) <<< 5) + (24'(h) <<< 1) + 24'sd32;
    else        m = (24'(h) <<< 2) + 24'(h) + 24'sd32;
    return 13'(m >>> 6);
  endfunction

  logic [1:0] fin_pl;
  logic [1:0] k_pl;
  logic signed [12:0] k_b, k_c;
  logic signed [14:0] k_a;
  logic signed [14:0] k_bc;
  logic signed [19:0] k_cbc;
  logic [7:0] k_lt, k_tt;
  always_comb begin
    k_pl = fin_pl;
    k_b  = pb[k_pl];
    k_c  = pc[k_pl];
    k_lt = pick_left(k_pl, (k_pl == 2'd0) ? 4'd15 : 4'd7);
    k_tt = pick_top(k_pl, (k_pl == 2'd0) ? 4'd15 : 4'd7);
    k_a  = 15'({1'b0, k_lt} + {1'b0, k_tt}) <<< 4;
    k_bc = 15'(k_b) + 15'(k_c);
    k_cbc = (k_pl == 2'd0) ? ((20'(k_bc) <<< 3) - 20'(k_bc)) : ((20'(k_bc) <<< 1) + 20'(k_bc));
  end

  // DC value rules (8.3.3 luma 16x16, 8.3.4.1 to 8.3.4.3 chroma 4x4 blocks).
  function automatic logic [7:0] cdc(input int blk, input logic [9:0] ta, input logic [9:0] tb,
                                     input logic [9:0] la, input logic [9:0] lb, input logic avt, input logic avl);
    // ta, tb: sums of the above samples of block columns 0 and 1; la, lb: sums of the left samples of block rows 0 and 1.
    logic [9:0] s_t, s_l;
    // The DC value is at most 255: the upper bits of the 11-bit intermediate are not read.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [10:0] v;
    /* verilator lint_on UNUSEDSIGNAL */
    s_t = (blk[0]) ? tb : ta;
    s_l = (blk[1]) ? lb : la;
    v  = 11'd128;
    if (blk == 1) begin
      if (avt)      v = (11'(s_t) + 11'd2) >> 2;
      else if (avl) v = (11'(s_l) + 11'd2) >> 2;
    end else if (blk == 2) begin
      if (avl)      v = (11'(s_l) + 11'd2) >> 2;
      else if (avt) v = (11'(s_t) + 11'd2) >> 2;
    end else begin
      if (avt && avl) v = (11'(s_t) + 11'(s_l) + 11'd4) >> 3;
      else if (avl)   v = (11'(s_l) + 11'd2) >> 2;
      else if (avt)   v = (11'(s_t) + 11'd2) >> 2;
    end
    return v[7:0];
  endfunction

  always_ff @(posedge clk) begin
    if (!resetn) begin
      top_y <= '0; left_y <= '0; top_c <= '0; left_c <= '0;
      tl_y <= '0; tl_cb <= '0; tl_cr <= '0;
      av_top <= 1'b0; av_left <= 1'b0; leg_y <= 4'b0100; leg_c <= 4'b0001;
      g_run <= 1'b0; g_pl <= '0; g_i <= '0;
      s1_v <= 1'b0; s1_pl <= '0; s1_i <= '0; s1_last <= 1'b0; s1_dh <= '0; s1_dv <= '0;
      acc_h <= '0; acc_v <= '0; sum_done <= 1'b0;
      fin <= 2'd0; fin_pl <= '0; prep_done <= 1'b0;
      dc_y <= 8'd128;
      sum_top_y <= '0; sum_left_y <= '0;
      for (int p = 0; p < 3; p++) begin
        hsum[p] <= '0; vsum[p] <= '0; pb[p] <= '0; pc[p] <= '0; pk0[p] <= '0;
      end
      for (int p = 0; p < 2; p++) begin
        t0[p] <= '0; t1[p] <= '0; l0[p] <= '0; l1[p] <= '0;
        for (int b = 0; b < 4; b++) dc_c[p][b] <= 8'd128;
      end
    end else begin
      prep_done <= 1'b0;
      sum_done  <= 1'b0;
      if (nb_load) begin
        top_y <= nb_top_y; left_y <= nb_left_y; top_c <= nb_top_c; left_c <= nb_left_c;
        tl_y <= nb_tl_y; tl_cb <= nb_tl_cb; tl_cr <= nb_tl_cr;
        av_top <= nb_av_top; av_left <= nb_av_left;
        leg_y <= {nb_av_top && nb_av_left, 1'b1, nb_av_left, nb_av_top};
        leg_c <= {nb_av_top && nb_av_left, nb_av_top, nb_av_left, 1'b1};
        g_run <= 1'b1; g_pl <= 2'd0; g_i <= 3'd0;
      end

      // Step generator.
      if (g_run) begin
        if (g_last_i) begin
          g_i  <= 3'd0;
          g_pl <= g_pl + 2'd1;
          if (g_pl == 2'd2) g_run <= 1'b0;
        end else begin
          g_i <= g_i + 3'd1;
        end
      end

      // Stage 1: differences.
      s1_v    <= g_run;
      s1_pl   <= g_pl;
      s1_i    <= g_i;
      s1_last <= g_last_i;
      s1_dh   <= $signed({1'b0, top_hi}) - $signed({1'b0, top_lo});
      s1_dv   <= $signed({1'b0, left_hi}) - $signed({1'b0, left_lo});

      // Stage 2: weighted accumulate.
      if (s1_v) begin
        acc_h <= newh;
        acc_v <= newv;
        if (s1_last) begin
          hsum[s1_pl] <= newh;
          vsum[s1_pl] <= newv;
          if (s1_pl == 2'd2) sum_done <= 1'b1;
        end
      end

      // Finish: sums for DC and the plane parameters, then k0 per plane and the DC values.
      if (sum_done) begin
        fin <= 2'd1;
      end
      case (fin)
        2'd1: begin
          for (int p = 0; p < 3; p++) begin
            pb[p] <= b_of(hsum[p], p != 0);
            pc[p] <= b_of(vsum[p], p != 0);
          end
          sum_top_y <= 12'(top_y[7:0]) + 12'(top_y[15:8]) + 12'(top_y[23:16]) + 12'(top_y[31:24]) +
                       12'(top_y[39:32]) + 12'(top_y[47:40]) + 12'(top_y[55:48]) + 12'(top_y[63:56]) +
                       12'(top_y[71:64]) + 12'(top_y[79:72]) + 12'(top_y[87:80]) + 12'(top_y[95:88]) +
                       12'(top_y[103:96]) + 12'(top_y[111:104]) + 12'(top_y[119:112]) + 12'(top_y[127:120]);
          sum_left_y <= 12'(left_y[7:0]) + 12'(left_y[15:8]) + 12'(left_y[23:16]) + 12'(left_y[31:24]) +
                        12'(left_y[39:32]) + 12'(left_y[47:40]) + 12'(left_y[55:48]) + 12'(left_y[63:56]) +
                        12'(left_y[71:64]) + 12'(left_y[79:72]) + 12'(left_y[87:80]) + 12'(left_y[95:88]) +
                        12'(left_y[103:96]) + 12'(left_y[111:104]) + 12'(left_y[119:112]) + 12'(left_y[127:120]);
          t0[0] <= 10'(top_c[7:0]) + 10'(top_c[15:8]) + 10'(top_c[23:16]) + 10'(top_c[31:24]);
          t1[0] <= 10'(top_c[39:32]) + 10'(top_c[47:40]) + 10'(top_c[55:48]) + 10'(top_c[63:56]);
          t0[1] <= 10'(top_c[71:64]) + 10'(top_c[79:72]) + 10'(top_c[87:80]) + 10'(top_c[95:88]);
          t1[1] <= 10'(top_c[103:96]) + 10'(top_c[111:104]) + 10'(top_c[119:112]) + 10'(top_c[127:120]);
          l0[0] <= 10'(left_c[7:0]) + 10'(left_c[15:8]) + 10'(left_c[23:16]) + 10'(left_c[31:24]);
          l1[0] <= 10'(left_c[39:32]) + 10'(left_c[47:40]) + 10'(left_c[55:48]) + 10'(left_c[63:56]);
          l0[1] <= 10'(left_c[71:64]) + 10'(left_c[79:72]) + 10'(left_c[87:80]) + 10'(left_c[95:88]);
          l1[1] <= 10'(left_c[103:96]) + 10'(left_c[111:104]) + 10'(left_c[119:112]) + 10'(left_c[127:120]);
          fin    <= 2'd2;
          fin_pl <= 2'd0;
        end
        2'd2: begin
          // k0 of plane fin_pl, one plane per clock.
          pk0[fin_pl] <= 20'(k_a) + 20'sd16 - k_cbc;
          if (fin_pl == 2'd2) begin
            fin       <= 2'd3;
          end else begin
            fin_pl <= fin_pl + 2'd1;
          end
        end
        2'd3: begin
          if (av_top && av_left)
            dc_y <= 8'((13'(sum_top_y) + 13'(sum_left_y) + 13'd16) >> 5);
          else if (av_left)
            dc_y <= 8'((sum_left_y + 12'd8) >> 4);
          else if (av_top)
            dc_y <= 8'((sum_top_y + 12'd8) >> 4);
          else
            dc_y <= 8'd128;
          for (int p = 0; p < 2; p++) begin
            for (int b = 0; b < 4; b++) dc_c[p][b] <= cdc(b, t0[p], t1[p], l0[p], l1[p], av_top, av_left);
          end
          fin       <= 2'd0;
          prep_done <= 1'b1;
        end
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Query pipeline: stage 1 (plane base value, simple-mode samples), stage 2 (all four modes)
  // ---------------------------------------------------------------------------
  logic        q1_v, q1_acc;
  logic [1:0]  q1_pl;
  logic signed [19:0] q1_t;
  logic signed [12:0] q1_b;
  logic [31:0] q1_top, q1_src;
  logic [7:0]  q1_left, q1_dc;

  logic signed [12:0] sel_b, sel_c;
  logic signed [19:0] sel_k;
  logic signed [17:0] pcy, pbx;
  logic [7:0]  l_byte, dc_byte;
  logic [31:0] t_seg;
  logic [4:0]  xo;

  always_comb begin
    case (q_plane)
      2'd0:    begin sel_b = pb[0]; sel_c = pc[0]; sel_k = pk0[0]; end
      2'd1:    begin sel_b = pb[1]; sel_c = pc[1]; sel_k = pk0[1]; end
      default: begin sel_b = pb[2]; sel_c = pc[2]; sel_k = pk0[2]; end
    endcase
    xo  = {1'b0, q_seg, 2'b00};
    pcy = sel_c * $signed({1'b0, q_y});
    pbx = sel_b * $signed(xo);
    case (q_plane)
      2'd0:    begin t_seg = top_y[32*q_seg +: 32]; l_byte = left_y[8*q_y +: 8]; dc_byte = dc_y; end
      2'd1:    begin t_seg = top_c[32*q_seg[0] +: 32]; l_byte = left_c[8*q_y[2:0] +: 8]; dc_byte = dc_c[0][{q_y[2], q_seg[0]}]; end
      default: begin t_seg = top_c[64 + 32*q_seg[0] +: 32]; l_byte = left_c[64 + 8*q_y[2:0] +: 8]; dc_byte = dc_c[1][{q_y[2], q_seg[0]}]; end
    endcase
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      q1_v <= 1'b0; q1_acc <= 1'b0; q1_pl <= '0; q1_t <= '0; q1_b <= '0;
      q1_top <= '0; q1_src <= '0; q1_left <= '0; q1_dc <= '0;
    end else begin
      q1_v   <= q_valid;
      q1_acc <= q_acc;
      q1_pl  <= q_plane;
      q1_t   <= sel_k + 20'(pcy) + 20'(pbx);
      q1_b   <= sel_b;
      q1_top <= t_seg;
      q1_src <= q_src;
      q1_left <= l_byte;
      q1_dc  <= dc_byte;
    end
  end

  // Stage 2: plane samples.
  logic signed [19:0] pl_v [4];
  logic [7:0]  pl_px [4];
  always_comb begin
    pl_v[0] = q1_t;
    pl_v[1] = q1_t + 20'(q1_b);
    pl_v[2] = q1_t + (20'(q1_b) <<< 1);
    pl_v[3] = q1_t + (20'(q1_b) <<< 1) + 20'(q1_b);
    for (int i = 0; i < 4; i++) begin
      logic signed [19:0] s;
      s = pl_v[i] >>> 5;
      if (s < 0)        pl_px[i] = 8'd0;
      else if (s > 255) pl_px[i] = 8'd255;
      else              pl_px[i] = s[7:0];
    end
  end

  logic [31:0] m_v, m_h, m_dc, m_pl;
  logic [127:0] px_n;
  always_comb begin
    m_v  = q1_top;
    m_h  = {4{q1_left}};
    m_dc = {4{q1_dc}};
    m_pl = {pl_px[3], pl_px[2], pl_px[1], pl_px[0]};
    if (q1_pl == 2'd0) begin
      px_n = {leg_y[3] ? m_pl : 32'd0, m_dc, leg_y[1] ? m_h : 32'd0, leg_y[0] ? m_v : 32'd0};
    end else begin
      px_n = {leg_c[3] ? m_pl : 32'd0, leg_c[2] ? m_v : 32'd0, leg_c[1] ? m_h : 32'd0, m_dc};
    end
  end

  logic        q2_acc;
  logic        q2_luma;
  logic [31:0] q2_src;
  always_ff @(posedge clk) begin
    if (!resetn) begin
      p_valid <= 1'b0; p_px <= '0; q2_acc <= 1'b0; q2_luma <= 1'b0; q2_src <= '0;
    end else begin
      p_valid <= q1_v;
      if (q1_v) p_px <= px_n;
      q2_acc  <= q1_v && q1_acc;
      q2_luma <= (q1_pl == 2'd0);
      q2_src  <= q1_src;
    end
  end

  // ---------------------------------------------------------------------------
  // SAD: stage 3 (sum of 4 absolute differences per mode), stage 4 (accumulate)
  // ---------------------------------------------------------------------------
  logic        s3_v;
  logic        s3_luma;
  logic [10:0] s3_sad [4];
  logic [17:0] acc_y [4];
  logic [17:0] acc_c [4];

  function automatic logic [10:0] sad4(input logic [31:0] a, input logic [31:0] b);
    logic [10:0] s;
    s = 11'd0;
    for (int k = 0; k < 4; k++) begin
      if (a[8*k +: 8] >= b[8*k +: 8]) s = s + 11'(a[8*k +: 8] - b[8*k +: 8]);
      else                            s = s + 11'(b[8*k +: 8] - a[8*k +: 8]);
    end
    return s;
  endfunction

  always_ff @(posedge clk) begin
    if (!resetn) begin
      s3_v <= 1'b0; s3_luma <= 1'b0;
      for (int m = 0; m < 4; m++) begin
        s3_sad[m] <= '0; acc_y[m] <= '0; acc_c[m] <= '0;
      end
    end else begin
      s3_v    <= q2_acc;
      s3_luma <= q2_luma;
      for (int m = 0; m < 4; m++) begin
        s3_sad[m] <= sad4(p_px[32*m +: 32], q2_src);
      end
      if (nb_load) begin
        for (int m = 0; m < 4; m++) begin
          acc_y[m] <= '0; acc_c[m] <= '0;
        end
      end else if (s3_v) begin
        for (int m = 0; m < 4; m++) begin
          if (s3_luma) begin
            if (leg_y[m]) acc_y[m] <= acc_y[m] + 18'(s3_sad[m]);
          end else begin
            if (leg_c[m]) acc_c[m] <= acc_c[m] + 18'(s3_sad[m]);
          end
        end
      end
    end
  end

  always_comb begin
    for (int m = 0; m < 4; m++) begin
      sad_y[18*m +: 18] = acc_y[m];
      sad_c[18*m +: 18] = acc_c[m];
    end
  end

  // ---------------------------------------------------------------------------
  // Decision: totals, then the first-best search in the order DC, V, H, Plane
  // ---------------------------------------------------------------------------
  logic [2:0]  d_st;
  logic [19:0] tot_y [4];
  logic [19:0] tot_c [4];

  // Phase 2b-3 timing fix: the first-best search is two clocks. Clock 1 registers the six pairwise "t_a <= t_b" results of
  // the candidate positions a < b; clock 2 picks the winner: the earliest legal candidate with the minimum total (ties go to
  // the earlier position, the order DC, V, H, Plane), which is exactly the result of the serial "replace when strictly
  // smaller" search. Position 0 (DC) is always legal.
  function automatic logic [5:0] pair_le(input logic [19:0] t0_, input logic [19:0] t1_, input logic [19:0] t2_,
                                         input logic [19:0] t3_);
    // bit order: 01, 02, 03, 12, 13, 23
    return {t2_ <= t3_, t1_ <= t3_, t1_ <= t2_, t0_ <= t3_, t0_ <= t2_, t0_ <= t1_};
  endfunction

  function automatic logic [1:0] pick_best(input logic [5:0] le, input logic [3:0] leg, input logic [1:0] n0,
                                           input logic [1:0] n1, input logic [1:0] n2, input logic [1:0] n3);
    logic [3:0] lp;      // legal flags by candidate position
    logic [2:0] win;      // candidate 3 wins when no earlier one does
    lp = {leg[n3], leg[n2], leg[n1], 1'b1};
    // candidate k wins when legal, strictly below every earlier legal one and not above any later legal one
    win[0] = lp[0] && (!lp[1] || le[0]) && (!lp[2] || le[1]) && (!lp[3] || le[2]);
    win[1] = lp[1] && (!lp[0] || !le[0]) && (!lp[2] || le[3]) && (!lp[3] || le[4]);
    win[2] = lp[2] && (!lp[0] || !le[1]) && (!lp[1] || !le[3]) && (!lp[3] || le[5]);
    if (win[0]) return n0;
    if (win[1]) return n1;
    if (win[2]) return n2;
    return n3;
  endfunction

  logic [5:0] le_y;
  logic [5:0] le_c;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      d_st <= 3'd0; dec_done <= 1'b0; dec_luma_mode <= 2'd2; dec_chroma_mode <= 2'd0;
      for (int m = 0; m < 4; m++) begin
        tot_y[m] <= '0; tot_c[m] <= '0;
      end
    end else begin
      dec_done <= 1'b0;
      case (d_st)
        3'd0: if (dec_start) d_st <= 3'd1;
        3'd1: begin
          // Luma by spec number: V 0 (cost 16), H 1 (16), DC 2 (0), Plane 3 (32).
          tot_y[0] <= 20'(acc_y[0]) + 20'd16;
          tot_y[1] <= 20'(acc_y[1]) + 20'd16;
          tot_y[2] <= 20'(acc_y[2]);
          tot_y[3] <= 20'(acc_y[3]) + 20'd32;
          // Chroma by spec number: DC 0 (0), H 1 (16), V 2 (16), Plane 3 (32).
          tot_c[0] <= 20'(acc_c[0]);
          tot_c[1] <= 20'(acc_c[1]) + 20'd16;
          tot_c[2] <= 20'(acc_c[2]) + 20'd16;
          tot_c[3] <= 20'(acc_c[3]) + 20'd32;
          d_st <= 3'd2;
        end
        3'd2: begin
          le_y <= pair_le(tot_y[2], tot_y[0], tot_y[1], tot_y[3]);
          le_c <= pair_le(tot_c[0], tot_c[2], tot_c[1], tot_c[3]);
          d_st <= 3'd3;
        end
        3'd3: begin
          dec_luma_mode   <= pick_best(le_y, leg_y, 2'd2, 2'd0, 2'd1, 2'd3);
          dec_chroma_mode <= pick_best(le_c, leg_c, 2'd0, 2'd2, 2'd1, 2'd3);
          d_st <= 3'd4;
        end
        default: begin
          dec_done <= 1'b1;
          d_st     <= 3'd0;
        end
      endcase
    end
  end

endmodule
