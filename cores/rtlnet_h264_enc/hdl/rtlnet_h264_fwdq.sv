// -----------------------------------------------------------------------------
// File: rtlnet_h264_fwdq.sv
// Purpose: streaming forward 4x4 integer core transform and AC quantizer of the H.264 intra encoder
//   (ITU-T Rec. H.264 clause 8.5 defines the decoder side; the forward transform and the quantizer are the encoder
//   choice and follow the usual JM form). One 4x4 residual block goes in as four rows, one row per clock; the
//   quantized levels and the unquantized DC coefficient W00 come out as four rows.
// Overview:
//   * Row stage: per input row the horizontal core transform (adds and shifts, Cf = [1 1 1 1; 2 1 -1 -2; 1 -1 -1 1;
//     1 -2 2 -1]). Column stage: 16 accumulators add Cf[u][r] * T_r[c] as the rows arrive, so W = Cf X Cf^T is complete
//     one clock after the fourth row. W is held for the four clocks of the quantizer, which walks the rows.
//   * Quantizer, 4 lanes, pipelined in three stages (abs and MF select; |W| * MF + f; shift, clamp, sign):
//     level = sign * min(2047, (|W| * MF(qp%6, class) + f) >> (15 + qp/6)), f = (1 << (15 + qp/6)) / 3 (constant table; intra)
//     or / 6 (inter: in_inter, half the intra value: the usual rounding offsets 1/3 intra and 1/6 inter, an encoder choice).
//     Position (0,0) is the DC: its level output is 0 and W00 leaves unquantized on out_dc, unless in_full is set (the luma
//     blocks of an inter macroblock have no separate DC transform: the DC position is quantized like the others, with the
//     class 0 multiplier; W00 still leaves on out_dc).
//   * The block's qp, tag, in_inter and in_full are sampled with the block's first row and travel with it, so blocks of
//     different qp may follow each other back to back.
//   * Widths: residual 9 bits signed, row transform 12 bits signed, W 16 bits signed (|W| <= 9180), |W| 14 bits, MF 14 bits,
//     product plus f 32 bits, level 12 bits signed.
//   * Cadence: a block's four rows arrive on four consecutive clocks; the next block's first row may follow on the next
//     clock (no gap required, gaps allowed). No stall. Latency: out_row 0 appears 8 clocks after the clock of in_first
//     (in_first at clock t, out_valid first high at t + 8), then rows 1..3 on the next three clocks.
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-10-2026: phase 2c-1: in_inter (rounding offset 1/6) and in_full (DC position quantized) for inter macroblocks.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_fwdq (
  // Clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Input rows, clk domain. qp and in_tag are sampled with in_first (row 0 of a block).
  input  logic [5:0]  qp,
  input  logic        in_valid,
  input  logic        in_first,
  input  logic [35:0] in_res,
  input  logic [7:0]  in_tag,
  input  logic        in_inter,
  input  logic        in_full,

  // Output rows, clk domain: four consecutive rows per block, fixed latency, no stall.
  output logic        out_valid,
  output logic [1:0]  out_row,
  output logic [47:0] out_lvl,
  output logic        out_dc_valid,
  output logic [15:0] out_dc,
  output logic [7:0]  out_tag
);

  // MF by qp%6 and position class (0 = both even, 1 = both odd, 2 = other).
  function automatic logic [13:0] mf_of(input logic [2:0] qm, input logic [1:0] cls);
    logic [13:0] r;
    case (qm)
      3'd0:    r = (cls == 2'd0) ? 14'd13107 : ((cls == 2'd1) ? 14'd5243 : 14'd8066);
      3'd1:    r = (cls == 2'd0) ? 14'd11916 : ((cls == 2'd1) ? 14'd4660 : 14'd7490);
      3'd2:    r = (cls == 2'd0) ? 14'd10082 : ((cls == 2'd1) ? 14'd4194 : 14'd6554);
      3'd3:    r = (cls == 2'd0) ? 14'd9362  : ((cls == 2'd1) ? 14'd3647 : 14'd5825);
      3'd4:    r = (cls == 2'd0) ? 14'd8192  : ((cls == 2'd1) ? 14'd3355 : 14'd5243);
      default: r = (cls == 2'd0) ? 14'd7282  : ((cls == 2'd1) ? 14'd2893 : 14'd4559);
    endcase
    return r;
  endfunction

  // f = (1 << (15 + q6)) / 3 for q6 = qp / 6 = 0..8.
  function automatic logic [21:0] f_of(input logic [3:0] q6);
    logic [21:0] r;
    case (q6)
      4'd0:    r = 22'd10922;
      4'd1:    r = 22'd21845;
      4'd2:    r = 22'd43690;
      4'd3:    r = 22'd87381;
      4'd4:    r = 22'd174762;
      4'd5:    r = 22'd349525;
      4'd6:    r = 22'd699050;
      4'd7:    r = 22'd1398101;
      default: r = 22'd2796202;
    endcase
    return r;
  endfunction

  // Cf[u][r] times T_r (factors +-1, +-2).
  function automatic logic signed [15:0] kmul(input logic [1:0] u, input logic [1:0] r, input logic signed [11:0] t);
    logic signed [15:0] x;
    logic signed [15:0] y;
    x = 16'(t);
    case (u)
      2'd0:    y = x;
      2'd1:    y = (r == 2'd0) ? (x <<< 1) : ((r == 2'd1) ? x : ((r == 2'd2) ? -x : -(x <<< 1)));
      2'd2:    y = ((r == 2'd0) || (r == 2'd3)) ? x : -x;
      default: y = (r == 2'd0) ? x : ((r == 2'd1) ? -(x <<< 1) : ((r == 2'd2) ? (x <<< 1) : -x));
    endcase
    return y;
  endfunction

  // ---------------------------------------------------------------------------
  // Row stage
  // ---------------------------------------------------------------------------
  logic [1:0]  rcnt;
  logic [7:0]  tag_a;
  logic [5:0]  qp_a;
  logic        inter_a, full_a;
  logic [1:0]  row_idx;
  logic [7:0]  cur_tag;
  logic [5:0]  cur_qp;
  logic        cur_inter, cur_full;
  logic signed [8:0]  x [4];
  logic signed [11:0] s03, d03, s12, d12;
  logic signed [11:0] tn [4];

  logic        t_valid;
  logic [1:0]  t_row;
  logic [7:0]  t_tag;
  logic [5:0]  t_qp;
  logic        t_inter, t_full;
  logic signed [11:0] t [4];

  assign row_idx = in_first ? 2'd0 : rcnt;
  assign cur_tag = in_first ? in_tag : tag_a;
  assign cur_qp  = in_first ? qp : qp_a;
  assign cur_inter = in_first ? in_inter : inter_a;
  assign cur_full  = in_first ? in_full : full_a;

  always_comb begin
    for (int c = 0; c < 4; c++) x[c] = in_res[9*c +: 9];
    s03 = 12'(x[0]) + 12'(x[3]);
    d03 = 12'(x[0]) - 12'(x[3]);
    s12 = 12'(x[1]) + 12'(x[2]);
    d12 = 12'(x[1]) - 12'(x[2]);
    tn[0] = s03 + s12;
    tn[1] = (d03 <<< 1) + d12;
    tn[2] = s03 - s12;
    tn[3] = d03 - (d12 <<< 1);
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      rcnt    <= 2'd0;
      t_valid <= 1'b0;
    end else begin
      t_valid <= in_valid;
      if (in_valid) rcnt <= row_idx + 2'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (in_valid) begin
      tag_a   <= cur_tag;
      qp_a    <= cur_qp;
      inter_a <= cur_inter;
      full_a  <= cur_full;
    end
    t_row   <= row_idx;
    t_tag   <= cur_tag;
    t_qp    <= cur_qp;
    t_inter <= cur_inter;
    t_full  <= cur_full;
    for (int c = 0; c < 4; c++) t[c] <= tn[c];
  end

  // ---------------------------------------------------------------------------
  // Column accumulators and the held coefficient matrix wh[row][col]
  // ---------------------------------------------------------------------------
  logic signed [15:0] acc  [4][4];
  logic signed [15:0] accn [4][4];
  logic signed [15:0] wh   [4][4];
  logic [7:0]  w_tag;
  logic [5:0]  w_qp;
  logic        w_inter, w_full;
  logic        wload;
  logic        qrun;
  logic [1:0]  qrow;

  assign wload = t_valid && (t_row == 2'd3);

  always_comb begin
    for (int u = 0; u < 4; u++) begin
      for (int c = 0; c < 4; c++) begin
        accn[u][c] = ((t_row == 2'd0) ? 16'sd0 : acc[u][c]) + kmul(2'(u), t_row, t[c]);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (t_valid) begin
      for (int u = 0; u < 4; u++) for (int c = 0; c < 4; c++) acc[u][c] <= accn[u][c];
    end
    if (wload) begin
      for (int u = 0; u < 4; u++) for (int c = 0; c < 4; c++) wh[u][c] <= accn[u][c];
      w_tag   <= t_tag;
      w_qp    <= t_qp;
      w_inter <= t_inter;
      w_full  <= t_full;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      qrun <= 1'b0;
      qrow <= 2'd0;
    end else if (wload) begin
      qrun <= 1'b1;
      qrow <= 2'd0;
    end else if (qrun) begin
      qrow <= qrow + 2'd1;
      if (qrow == 2'd3) qrun <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Quantizer stage 1: absolute value and MF
  // ---------------------------------------------------------------------------
  logic        q1_valid;
  logic [1:0]  q1_row;
  logic [7:0]  q1_tag;
  logic        q1_inter, q1_full;
  logic [3:0]  q1_q6;
  logic [13:0] q1_abs [4];
  logic [13:0] q1_mf  [4];
  logic        q1_sgn [4];
  logic [15:0] q1_dc;
  logic [2:0]  qm;
  logic [3:0]  q6;
  logic signed [15:0] wsel [4];
  logic [15:0] wabs [4];
  logic [1:0]  cls [4];

  assign qm = 3'(w_qp % 6'd6);
  assign q6 = 4'(w_qp / 6'd6);

  always_comb begin
    for (int c = 0; c < 4; c++) begin
      wsel[c] = wh[qrow][c];
      wabs[c] = wsel[c][15] ? 16'(-wsel[c]) : 16'(wsel[c]);
      if ((qrow[0] == 1'b0) && (c % 2 == 0))      cls[c] = 2'd0;
      else if ((qrow[0] == 1'b1) && (c % 2 == 1)) cls[c] = 2'd1;
      else                                        cls[c] = 2'd2;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) q1_valid <= 1'b0;
    else         q1_valid <= qrun;
  end

  always_ff @(posedge clk) begin
    q1_row <= qrow;
    q1_tag <= w_tag;
    q1_inter <= w_inter;
    q1_full  <= w_full;
    q1_q6  <= q6;
    q1_dc  <= 16'(wh[0][0]);
    for (int c = 0; c < 4; c++) begin
      q1_abs[c] <= wabs[c][13:0];
      q1_sgn[c] <= wsel[c][15];
      q1_mf[c]  <= mf_of(qm, cls[c]);
    end
  end

  // ---------------------------------------------------------------------------
  // Quantizer stage 2: |W| * MF + f
  // ---------------------------------------------------------------------------
  logic        q2_valid;
  logic [1:0]  q2_row;
  logic [7:0]  q2_tag;
  logic        q2_full;
  logic [3:0]  q2_q6;
  logic [31:0] q2_sum [4];
  logic        q2_sgn [4];
  logic [15:0] q2_dc;

  always_ff @(posedge clk) begin
    if (!resetn) q2_valid <= 1'b0;
    else         q2_valid <= q1_valid;
  end

  always_ff @(posedge clk) begin
    q2_row <= q1_row;
    q2_tag <= q1_tag;
    q2_full  <= q1_full;
    q2_q6  <= q1_q6;
    q2_dc  <= q1_dc;
    for (int c = 0; c < 4; c++) begin
      q2_sum[c] <= 32'(q1_abs[c]) * 32'(q1_mf[c]) + (q1_inter ? (32'(f_of(q1_q6)) >> 1) : 32'(f_of(q1_q6)));
      q2_sgn[c] <= q1_sgn[c];
    end
  end

  // ---------------------------------------------------------------------------
  // Quantizer stage 3: shift, clamp, sign
  // ---------------------------------------------------------------------------
  logic [31:0] sh [4];
  logic signed [11:0] lv [4];

  always_comb begin
    for (int c = 0; c < 4; c++) begin
      sh[c] = q2_sum[c] >> (5'd15 + {1'b0, q2_q6});
      if (sh[c] > 32'd2047) sh[c] = 32'd2047;
      lv[c] = q2_sgn[c] ? -12'(sh[c][10:0]) : 12'(sh[c][10:0]);
      if ((q2_row == 2'd0) && (c == 0) && !q2_full) lv[c] = 12'sd0;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      out_valid    <= 1'b0;
      out_dc_valid <= 1'b0;
    end else begin
      out_valid    <= q2_valid;
      out_dc_valid <= q2_valid && (q2_row == 2'd0);
    end
  end

  always_ff @(posedge clk) begin
    out_row <= q2_row;
    out_tag <= q2_tag;
    out_dc  <= q2_dc;
    for (int c = 0; c < 4; c++) out_lvl[12*c +: 12] <= lv[c];
  end

endmodule
