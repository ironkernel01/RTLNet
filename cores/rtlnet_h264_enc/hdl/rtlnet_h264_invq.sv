// -----------------------------------------------------------------------------
// File: rtlnet_h264_invq.sv
// Purpose: AC dequantizer and inverse 4x4 transform of the H.264 intra rebuild loop, written to the decoder process
//   of ITU-T Rec. H.264 clauses 8.5.12.1 (scaling) and 8.5.12.2 (transform), so the residual is bit-exact with a
//   conforming decoder. One block goes in as four coefficient rows (levels), one row per clock; the residual comes
//   out as four rows.
// Overview:
//   * Stage 1: d = level * V(qp%6, class) (V = normAdjust4x4; LevelScale = 16 * V and the clause's shift of (qp/6 - 4)
//     reduce to level * V * 2^(qp/6)); position (0,0) of row 0 takes in_dc instead (the already scaled luma or chroma DC).
//     Stage 2: left shift by qp/6 (not applied to the DC). Stage 3: row transform e0 = d0 + d2, e1 = d0 - d2,
//     e2 = (d1 >> 1) - d3, e3 = d1 + (d3 >> 1); f0 = e0 + e3, f1 = e1 + e2, f2 = e1 - e2, f3 = e0 - e3 (arithmetic shifts).
//     Stage 4: the same on the columns, then (h + 32) >> 6, saturated to 16 bits signed. Stage 5: row output register.
//   * qp, in_dc and in_tag are sampled with the block's first row; the qp of a block applies to the whole block, so
//     blocks of different qp may follow each other back to back.
//   * Widths: level 12 bits signed, d 26 bits signed (|d| <= 2047 * 29 * 256), row and column stages 28 and 30 bits signed,
//     DC 20 bits signed, residual 16 bits signed (saturated).
//   * Cadence: four consecutive rows per block, the next block may follow on the next clock. No stall. Latency: out_row 0
//     appears 8 clocks after in_first (in_first at clock t, out_valid first high at t + 8), then rows 1..3.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_invq (
  // Clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Input rows, clk domain. qp, in_dc and in_tag are sampled with in_first.
  input  logic [5:0]  qp,
  input  logic        in_valid,
  input  logic        in_first,
  input  logic [47:0] in_lvl,
  input  logic [19:0] in_dc,
  input  logic [7:0]  in_tag,

  // Output rows, clk domain: four consecutive rows per block, fixed latency, no stall.
  output logic        out_valid,
  output logic [1:0]  out_row,
  output logic [63:0] out_res,
  output logic [7:0]  out_tag,
  // The tag of the row decoded for the macroblock coder (registered with the row): plane 0 luma, 1 Cb, 2 Cr; sample segment
  // (luma 0..3, chroma 0..1) and row inside the plane's macroblock part.
  output logic [1:0]  out_pl,
  output logic [1:0]  out_sg,
  output logic [3:0]  out_yy
);

  // V (normAdjust4x4) by qp%6 and class (0 = both even, 1 = both odd, 2 = other).
  function automatic logic [4:0] v_of(input logic [2:0] qm, input logic [1:0] cls);
    logic [4:0] r;
    case (qm)
      3'd0:    r = (cls == 2'd0) ? 5'd10 : ((cls == 2'd1) ? 5'd16 : 5'd13);
      3'd1:    r = (cls == 2'd0) ? 5'd11 : ((cls == 2'd1) ? 5'd18 : 5'd14);
      3'd2:    r = (cls == 2'd0) ? 5'd13 : ((cls == 2'd1) ? 5'd20 : 5'd16);
      3'd3:    r = (cls == 2'd0) ? 5'd14 : ((cls == 2'd1) ? 5'd23 : 5'd18);
      3'd4:    r = (cls == 2'd0) ? 5'd16 : ((cls == 2'd1) ? 5'd25 : 5'd20);
      default: r = (cls == 2'd0) ? 5'd18 : ((cls == 2'd1) ? 5'd29 : 5'd23);
    endcase
    return r;
  endfunction

  // ---------------------------------------------------------------------------
  // Stage 1: level * V
  // ---------------------------------------------------------------------------
  logic [1:0]  rcnt;
  logic [1:0]  row_idx;
  logic [7:0]  tag_a;
  logic [5:0]  qp_a;
  logic [19:0] dc_a;
  logic [7:0]  cur_tag;
  logic [5:0]  cur_qp;
  logic [19:0] cur_dc;
  logic [2:0]  qm;
  logic [3:0]  q6;
  logic [1:0]  cls [4];
  logic signed [11:0] lv [4];

  logic        s1_valid;
  logic [1:0]  s1_row;
  logic [7:0]  s1_tag;
  logic [3:0]  s1_q6;
  logic signed [19:0] s1_p [4];
  logic        s1_dcpos;

  assign row_idx = in_first ? 2'd0 : rcnt;
  assign cur_tag = in_first ? in_tag : tag_a;
  assign cur_qp  = in_first ? qp : qp_a;
  assign cur_dc  = in_first ? in_dc : dc_a;
  assign qm      = 3'(cur_qp % 6'd6);
  assign q6      = 4'(cur_qp / 6'd6);

  always_comb begin
    for (int c = 0; c < 4; c++) begin
      lv[c] = in_lvl[12*c +: 12];
      if ((row_idx[0] == 1'b0) && (c % 2 == 0))      cls[c] = 2'd0;
      else if ((row_idx[0] == 1'b1) && (c % 2 == 1)) cls[c] = 2'd1;
      else                                           cls[c] = 2'd2;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      rcnt     <= 2'd0;
      s1_valid <= 1'b0;
    end else begin
      s1_valid <= in_valid;
      if (in_valid) rcnt <= row_idx + 2'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (in_valid) begin
      tag_a <= cur_tag;
      qp_a  <= cur_qp;
      dc_a  <= cur_dc;
    end
    s1_row   <= row_idx;
    s1_tag   <= cur_tag;
    s1_q6    <= q6;
    s1_dcpos <= (row_idx == 2'd0);
    for (int c = 0; c < 4; c++) begin
      if ((row_idx == 2'd0) && (c == 0)) s1_p[c] <= signed'(cur_dc);
      else                               s1_p[c] <= 20'(lv[c] * signed'({1'b0, v_of(qm, cls[c])}));
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 2: shift left by qp/6 (not for the DC), stage 3: row transform into T
  // ---------------------------------------------------------------------------
  logic        s2_valid;
  logic [1:0]  s2_row;
  logic [7:0]  s2_tag;
  logic signed [25:0] s2_d [4];

  always_ff @(posedge clk) begin
    if (!resetn) s2_valid <= 1'b0;
    else         s2_valid <= s1_valid;
  end

  always_ff @(posedge clk) begin
    s2_row <= s1_row;
    s2_tag <= s1_tag;
    for (int c = 0; c < 4; c++) begin
      if (s1_dcpos && (c == 0)) s2_d[c] <= 26'(s1_p[c]);
      else                      s2_d[c] <= 26'(s1_p[c]) <<< s1_q6;
    end
  end

  logic signed [27:0] e0, e1, e2, e3;
  logic signed [27:0] fr [4];
  logic signed [27:0] tt [4][4];
  logic        t_load3;
  logic [7:0]  t_tag;

  always_comb begin
    e0 = 28'(s2_d[0]) + 28'(s2_d[2]);
    e1 = 28'(s2_d[0]) - 28'(s2_d[2]);
    e2 = (28'(s2_d[1]) >>> 1) - 28'(s2_d[3]);
    e3 = 28'(s2_d[1]) + (28'(s2_d[3]) >>> 1);
    fr[0] = e0 + e3;
    fr[1] = e1 + e2;
    fr[2] = e1 - e2;
    fr[3] = e0 - e3;
  end

  always_ff @(posedge clk) begin
    if (!resetn) t_load3 <= 1'b0;
    else         t_load3 <= s2_valid && (s2_row == 2'd3);
  end

  always_ff @(posedge clk) begin
    if (s2_valid) begin
      for (int c = 0; c < 4; c++) tt[s2_row][c] <= fr[c];
    end
    if (s2_valid && (s2_row == 2'd3)) t_tag <= s2_tag;
  end

  // ---------------------------------------------------------------------------
  // Stage 4: column transform, rounding and saturation into H
  // ---------------------------------------------------------------------------
  logic signed [29:0] ce0 [4];
  logic signed [29:0] ce1 [4];
  logic signed [29:0] ce2 [4];
  logic signed [29:0] ce3 [4];
  logic signed [29:0] hh  [4][4];
  logic signed [29:0] rr  [4][4];
  logic signed [15:0] hs  [4][4];
  logic signed [15:0] hn  [4][4];
  logic [7:0]  h_tag;
  logic        orun;
  logic [1:0]  orow;

  always_comb begin
    for (int c = 0; c < 4; c++) begin
      ce0[c] = 30'(tt[0][c]) + 30'(tt[2][c]);
      ce1[c] = 30'(tt[0][c]) - 30'(tt[2][c]);
      ce2[c] = (30'(tt[1][c]) >>> 1) - 30'(tt[3][c]);
      ce3[c] = 30'(tt[1][c]) + (30'(tt[3][c]) >>> 1);
      hh[0][c] = ce0[c] + ce3[c];
      hh[1][c] = ce1[c] + ce2[c];
      hh[2][c] = ce1[c] - ce2[c];
      hh[3][c] = ce0[c] - ce3[c];
    end
    for (int r = 0; r < 4; r++) begin
      for (int c = 0; c < 4; c++) begin
        rr[r][c] = (hh[r][c] + 30'sd32) >>> 6;
        if (rr[r][c] > 30'sd32767)       hn[r][c] = 16'sd32767;
        else if (rr[r][c] < -30'sd32767) hn[r][c] = -16'sd32767;
        else                             hn[r][c] = 16'(rr[r][c]);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (t_load3) begin
      for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) hs[r][c] <= hn[r][c];
      h_tag <= t_tag;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      orun <= 1'b0;
      orow <= 2'd0;
    end else if (t_load3) begin
      orun <= 1'b1;
      orow <= 2'd0;
    end else if (orun) begin
      orow <= orow + 2'd1;
      if (orow == 2'd3) orun <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 5: output row register
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) out_valid <= 1'b0;
    else         out_valid <= orun;
  end

  always_ff @(posedge clk) begin
    out_row <= orow;
    out_tag <= h_tag;
    if (h_tag[4:0] < 5'd16) begin
      out_pl <= 2'd0;
      out_sg <= h_tag[1:0];
      out_yy <= {h_tag[3:2], orow};
    end else begin
      out_pl <= (h_tag[4:0] < 5'd20) ? 2'd1 : 2'd2;
      out_sg <= {1'b0, h_tag[0]};
      out_yy <= {1'b0, h_tag[1], orow};
    end
    for (int c = 0; c < 4; c++) out_res[16*c +: 16] <= hs[orow][c];
  end

endmodule
