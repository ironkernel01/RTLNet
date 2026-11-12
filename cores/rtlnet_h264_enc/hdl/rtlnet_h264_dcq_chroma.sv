// -----------------------------------------------------------------------------
// File: rtlnet_h264_dcq_chroma.sv
// Purpose: chroma DC path (4:2:0, one plane) of the H.264 encoder: forward 2x2 Hadamard of the four block DC
//   coefficients, quantizer, and the decoder side of clause 8.5.11.2 (inverse 2x2 transform and scaling) that yields the
//   DC values of the four chroma 4x4 blocks for the rebuild loop.
// Overview:
//   * One start with W00 of the plane's four blocks (raster order, 2x2). Yc = [1 1; 1 -1] W [1 1; 1 -1] with no scaling:
//     Yc00 = w0+w1+w2+w3, Yc01 = w0-w1+w2-w3, Yc10 = w0+w1-w2-w3, Yc11 = w0-w1-w2+w3, level order c0..c3.
//   * Quantizer, 4 lanes, three pipeline stages: level = sign * min(2047, (|Yc| * MF(qpc%6, class a) + 2f) >> (16 + qpc/6)),
//     f = (1 << (15 + qpc/6)) / 3 (intra) or / 6 (inter: the input inter selects the rounding offset 1/6 of an inter macroblock,
//     half the intra f, like the AC quantizer). qpc is the already mapped chroma QP (rtlnet_h264_pkg h264_qpc).
//   * Decoder side: f = [1 1; 1 -1] c [1 1; 1 -1], dcC = ((f * 16V(qpc%6, 0,0)) << (qpc/6)) >> 5, element i = chroma block i,
//     saturated to 20 bits signed.
//   * Widths: W 16 bits signed in, Yc 18 bits signed (|Yc| <= 16320), product plus 2f 31 bits, level 12 bits signed, f 14 bits
//     signed, product with 16V 24 bits signed, shifted value 32 bits signed, dcC 20 bits signed.
//   * qpc is sampled at start. nz is high when any level is non-zero. Outputs are valid and held from done until the
//     next start. Latency: done 9 clocks after start (start at clock t, done high at t + 9).
// Language: SystemVerilog-2012.
// Revision: 11-12-2026
//   * 11-09-2026: initial version.
//   * 11-12-2026: stage 3c: the inverse transform of the levels, the product with 16V, the shift and the saturation in separate clocks (timing: the DSP block's input and output got logic and long routes); latency 7 -> 9.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_dcq_chroma (
  // Clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Command, clk domain: start pulses one clock while idle; qpc and w_in are sampled at start.
  input  logic        start,
  input  logic [5:0]  qpc,
  input  logic        inter,
  input  logic [63:0] w_in,

  // Status and results, clk domain.
  output logic        busy,
  output logic        done,
  output logic [47:0] lvl_out,
  output logic        nz,
  output logic [79:0] dc_out
);

  function automatic logic [13:0] mf00(input logic [2:0] qm);
    logic [13:0] r;
    case (qm)
      3'd0:    r = 14'd13107;
      3'd1:    r = 14'd11916;
      3'd2:    r = 14'd10082;
      3'd3:    r = 14'd9362;
      3'd4:    r = 14'd8192;
      default: r = 14'd7282;
    endcase
    return r;
  endfunction

  // 16 * V(qm, class a).
  function automatic logic [8:0] ls00(input logic [2:0] qm);
    logic [8:0] r;
    case (qm)
      3'd0:    r = 9'd160;
      3'd1:    r = 9'd176;
      3'd2:    r = 9'd208;
      3'd3:    r = 9'd224;
      3'd4:    r = 9'd256;
      default: r = 9'd288;
    endcase
    return r;
  endfunction

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

  // Sequence: S0 idle, S1 Yc and abs, S2 product, S3 shift by 16 + qpc/6, S4 clamp and sign (the levels), S5 inverse 2x2 transform of the
  // levels, S6 product with 16V (DSP block with registered input and output), S7 shift, S8 saturation, then done.
  localparam logic [3:0] S_IDLE = 4'd0;
  localparam logic [3:0] S_1    = 4'd1;
  localparam logic [3:0] S_2    = 4'd2;
  localparam logic [3:0] S_3    = 4'd3;
  localparam logic [3:0] S_4    = 4'd4;
  localparam logic [3:0] S_5    = 4'd5;
  localparam logic [3:0] S_6    = 4'd6;
  localparam logic [3:0] S_7    = 4'd7;
  localparam logic [3:0] S_8    = 4'd8;

  logic [3:0]  st;
  logic [2:0]  qm;
  logic [3:0]  q6;
  logic        inter_q;
  logic signed [15:0] w [4];
  logic signed [17:0] y [4];
  logic [15:0] a1_abs [4];
  logic        a1_sgn [4];
  logic [31:0] a2_sum [4];
  logic        a2_sgn [4];
  logic signed [11:0] lv [4];
  logic signed [11:0] lv_n [4];
  logic [31:0] sh [4];
  logic [31:0] sh_r [4];
  logic [31:0] sh_c [4];
  logic signed [13:0] fq [4];
  logic signed [13:0] fq_r [4];
  logic signed [23:0] pq [4];
  logic signed [23:0] pq_n [4];
  logic signed [31:0] sx [4];
  logic signed [31:0] sy [4];
  logic signed [31:0] sy_r [4];
  logic signed [19:0] dcr [4];

  always_comb begin
    y[0] = 18'(w[0]) + 18'(w[1]) + 18'(w[2]) + 18'(w[3]);
    y[1] = 18'(w[0]) - 18'(w[1]) + 18'(w[2]) - 18'(w[3]);
    y[2] = 18'(w[0]) + 18'(w[1]) - 18'(w[2]) - 18'(w[3]);
    y[3] = 18'(w[0]) - 18'(w[1]) - 18'(w[2]) + 18'(w[3]);
    for (int c = 0; c < 4; c++) begin
      sh[c] = a2_sum[c] >> (5'd16 + {1'b0, q6});
      sh_c[c] = sh_r[c];
      if (sh_c[c] > 32'd2047) sh_c[c] = 32'd2047;
      lv_n[c] = a2_sgn[c] ? -12'(sh_c[c][10:0]) : 12'(sh_c[c][10:0]);
    end
    fq[0] = 14'(lv[0]) + 14'(lv[1]) + 14'(lv[2]) + 14'(lv[3]);
    fq[1] = 14'(lv[0]) - 14'(lv[1]) + 14'(lv[2]) - 14'(lv[3]);
    fq[2] = 14'(lv[0]) + 14'(lv[1]) - 14'(lv[2]) - 14'(lv[3]);
    fq[3] = 14'(lv[0]) - 14'(lv[1]) - 14'(lv[2]) + 14'(lv[3]);
    for (int c = 0; c < 4; c++) begin
      pq_n[c] = 24'(fq_r[c]) * signed'({1'b0, ls00(qm)});
      sx[c]   = 32'(pq[c]) <<< q6;
      sy[c]   = sx[c] >>> 5;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      st   <= S_IDLE;
      busy <= 1'b0;
      done <= 1'b0;
    end else begin
      done <= 1'b0;
      case (st)
        S_IDLE: if (start) begin st <= S_1; busy <= 1'b1; end
        S_1:    st <= S_2;
        S_2:    st <= S_3;
        S_3:    st <= S_4;
        S_4:    st <= S_5;
        S_5:    st <= S_6;
        S_6:    st <= S_7;
        S_7:    st <= S_8;
        default: begin
          st   <= S_IDLE;
          busy <= 1'b0;
          done <= 1'b1;
        end
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if ((st == S_IDLE) && start) begin
      qm   <= 3'(qpc % 6'd6);
      q6   <= 4'(qpc / 6'd6);
      inter_q <= inter;
      for (int i = 0; i < 4; i++) w[i] <= signed'(w_in[16*i +: 16]);
    end
    if (st == S_1) begin
      for (int c = 0; c < 4; c++) begin
        a1_abs[c] <= y[c][17] ? 16'(-y[c]) : 16'(y[c]);
        a1_sgn[c] <= y[c][17];
      end
    end
    if (st == S_2) begin
      for (int c = 0; c < 4; c++) begin
        a2_sum[c] <= 32'(a1_abs[c]) * 32'(mf00(qm)) + (inter_q ? {10'd0, f_of(q6)[21:1], 1'b0} : {9'd0, f_of(q6), 1'b0});
        a2_sgn[c] <= a1_sgn[c];
      end
    end
    if (st == S_3) begin
      for (int c = 0; c < 4; c++) sh_r[c] <= sh[c];
    end
    if (st == S_4) begin
      for (int c = 0; c < 4; c++) lv[c] <= lv_n[c];
      nz <= (lv_n[0] != 0) || (lv_n[1] != 0) || (lv_n[2] != 0) || (lv_n[3] != 0);
    end
    if (st == S_5) begin
      for (int c = 0; c < 4; c++) fq_r[c] <= fq[c];
    end
    if (st == S_6) begin
      for (int c = 0; c < 4; c++) pq[c] <= pq_n[c];
    end
    if (st == S_7) begin
      for (int c = 0; c < 4; c++) sy_r[c] <= sy[c];
    end
    if (st == S_8) begin
      for (int c = 0; c < 4; c++) begin
        if (sy_r[c] > 32'sd524287)       dcr[c] <= 20'sd524287;
        else if (sy_r[c] < -32'sd524288) dcr[c] <= -20'sd524288;
        else                             dcr[c] <= 20'(sy_r[c]);
      end
    end
  end

  always_comb begin
    for (int c = 0; c < 4; c++) begin
      lvl_out[12*c +: 12] = lv[c];
      dc_out[20*c +: 20]  = dcr[c];
    end
  end

endmodule
