// -----------------------------------------------------------------------------
// File: rtlnet_h264_dcq_luma.sv
// Purpose: Intra16x16 luma DC path of the H.264 encoder: forward 4x4 Hadamard of the 16 block DC coefficients,
//   quantizer, and the decoder side of clause 8.5.10 (inverse Hadamard and scaling) that yields the DC values the
//   rebuild loop feeds into the 4x4 inverse transforms.
// Overview:
//   * One start with the 16 values W00 (block raster, element i = block row i/4, column i%4). A serial datapath with
//     one 4-point butterfly (o0 = a+b+c+d, o1 = a+b-c-d, o2 = a-b-c+d, o3 = a-b+c-d) runs rows then columns in place:
//     Yf = H W H (H = [1 1 1 1; 1 1 -1 -1; 1 -1 -1 1; 1 -1 1 -1], no scaling).
//   * Quantizer, 4 lanes, rows 0..3 in three pipeline stages: level = sign * min(2047, (|Yf| * MF(qp%6, class a) + 4f)
//     >> (17 + qp/6)), f = (1 << (15 + qp/6)) / 3.
//   * Decoder side: f = H c H on the level matrix (same butterfly), dcY = (f * 16V) << (qp/6 - 6) for qp >= 36, else
//     (f * 16V + (1 << (5 - qp/6))) >> (6 - qp/6), V = normAdjust4x4(qp%6, 0,0); dcY is saturated to 20 bits signed.
//   * Widths: W 16 bits signed in, Yf 20 bits signed (|Yf| <= 65280), |Yf| 16 bits, product plus 4f 32 bits, level 12 bits
//     signed, f 20 bits signed, product with 16V 30 bits signed, dcY 20 bits signed.
//   * qp is sampled at start and must be at most 51. nz is high when any level is non-zero. Outputs are valid and held from
//     done until the next start. Latency: done 30 clocks after start (start at clock t, done high at t + 30).
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_dcq_luma (
  // Clock and synchronous active-low reset.
  input  logic         clk,
  input  logic         resetn,

  // Command, clk domain: start pulses one clock while idle; qp and w_in are sampled at start.
  input  logic         start,
  input  logic [5:0]   qp,
  input  logic [255:0] w_in,

  // Status and results, clk domain.
  output logic         busy,
  output logic         done,
  output logic [191:0] lvl_out,
  output logic         nz,
  output logic [319:0] dc_out
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

  localparam logic [3:0] P_IDLE = 4'd0;
  localparam logic [3:0] P_ROW1 = 4'd1;
  localparam logic [3:0] P_COL1 = 4'd2;
  localparam logic [3:0] P_Q    = 4'd3;
  localparam logic [3:0] P_CPY  = 4'd4;
  localparam logic [3:0] P_ROW2 = 4'd5;
  localparam logic [3:0] P_COL2 = 4'd6;
  localparam logic [3:0] P_S    = 4'd7;

  logic [3:0]  ph;
  logic [2:0]  cnt;
  logic signed [19:0] m   [16];
  logic signed [11:0] lvl [16];
  logic signed [19:0] dcr [16];

  // qp%6 and qp/6 are registered at start (the division stays off the datapath timing paths).
  logic [2:0] qm;
  logic [3:0] q6;

  // Butterfly operand selection: row (ph ROW) or column (ph COL) number cnt.
  logic signed [19:0] ba, bb, bc, bd;
  logic signed [19:0] o0, o1, o2, o3;
  logic        col_mode;
  logic [3:0]  i0, i1, i2, i3;

  assign col_mode = (ph == P_COL1) || (ph == P_COL2);
  assign i0 = col_mode ? {2'd0, cnt[1:0]}        : {cnt[1:0], 2'd0};
  assign i1 = col_mode ? {2'd1, cnt[1:0]}        : {cnt[1:0], 2'd1};
  assign i2 = col_mode ? {2'd2, cnt[1:0]}        : {cnt[1:0], 2'd2};
  assign i3 = col_mode ? {2'd3, cnt[1:0]}        : {cnt[1:0], 2'd3};

  always_comb begin
    ba = m[i0];
    bb = m[i1];
    bc = m[i2];
    bd = m[i3];
    o0 = ba + bb + bc + bd;
    o1 = ba + bb - bc - bd;
    o2 = ba - bb - bc + bd;
    o3 = ba - bb + bc - bd;
  end

  // Quantizer pipeline.
  logic        q1_v, q2_v;
  logic [1:0]  q1_row, q2_row;
  logic [15:0] q1_abs [4];
  logic        q1_sgn [4];
  logic [31:0] q2_sum [4];
  logic        q2_sgn [4];
  logic [31:0] qsh [4];

  // Scaling pipeline.
  logic        s1_v;
  logic [1:0]  s1_row;
  logic signed [29:0] s1_p [4];

  logic signed [19:0] mrow [4];
  logic [15:0] mabs [4];
  logic signed [31:0] sx [4];
  logic signed [31:0] sy [4];
  logic        s2_v;
  logic [1:0]  s2_row;
  logic signed [31:0] s2_y [4];

  always_comb begin
    for (int c = 0; c < 4; c++) begin
      mrow[c] = m[{cnt[1:0], 2'(c)}];
      mabs[c] = mrow[c][19] ? 16'(-mrow[c]) : 16'(mrow[c]);
      qsh[c]  = q2_sum[c] >> (5'd17 + {1'b0, q6});
      if (qsh[c] > 32'd2047) qsh[c] = 32'd2047;
      sx[c] = 32'(s1_p[c]);
      if (q6 >= 4'd6) sy[c] = sx[c] <<< (q6 - 4'd6);
      else            sy[c] = (sx[c] + (32'sd1 <<< (4'd5 - q6))) >>> (4'd6 - q6);
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      ph   <= P_IDLE;
      cnt  <= 3'd0;
      busy <= 1'b0;
      done <= 1'b0;
      nz   <= 1'b0;
      q1_v <= 1'b0;
      q2_v <= 1'b0;
      s1_v <= 1'b0;
      s2_v <= 1'b0;
    end else begin
      done <= 1'b0;
      q1_v <= (ph == P_Q) && (cnt < 3'd4);
      q2_v <= q1_v;
      s1_v <= (ph == P_S) && (cnt < 3'd4);
      s2_v <= s1_v;
      case (ph)
        P_IDLE: begin
          if (start) begin
            qm   <= 3'(qp % 6'd6);
            q6   <= 4'(qp / 6'd6);
            busy <= 1'b1;
            ph   <= P_ROW1;
            cnt  <= 3'd0;
          end
        end
        P_ROW1, P_COL1, P_ROW2, P_COL2: begin
          if (cnt == 3'd3) begin
            cnt <= 3'd0;
            case (ph)
              P_ROW1:  ph <= P_COL1;
              P_COL1:  ph <= P_Q;
              P_ROW2:  ph <= P_COL2;
              default: ph <= P_S;
            endcase
          end else begin
            cnt <= cnt + 3'd1;
          end
        end
        P_Q: begin
          cnt <= cnt + 3'd1;
          if (cnt == 3'd5) begin
            ph  <= P_CPY;
            cnt <= 3'd0;
          end
        end
        P_CPY: begin
          nz  <= (lvl[0] != 0) || (lvl[1] != 0) || (lvl[2] != 0) || (lvl[3] != 0) || (lvl[4] != 0) || (lvl[5] != 0) ||
                 (lvl[6] != 0) || (lvl[7] != 0) || (lvl[8] != 0) || (lvl[9] != 0) || (lvl[10] != 0) || (lvl[11] != 0) ||
                 (lvl[12] != 0) || (lvl[13] != 0) || (lvl[14] != 0) || (lvl[15] != 0);
          ph  <= P_ROW2;
          cnt <= 3'd0;
        end
        P_S: begin
          cnt <= cnt + 3'd1;
          if (cnt == 3'd5) begin
            ph   <= P_IDLE;
            cnt  <= 3'd0;
            busy <= 1'b0;
            done <= 1'b1;
          end
        end
        default: ph <= P_IDLE;
      endcase
    end
  end

  // Datapath registers (no reset: written before use in every transaction).
  always_ff @(posedge clk) begin
    if ((ph == P_IDLE) && start) begin
      for (int i = 0; i < 16; i++) m[i] <= 20'(signed'(w_in[16*i +: 16]));
    end
    if ((ph == P_ROW1) || (ph == P_COL1) || (ph == P_ROW2) || (ph == P_COL2)) begin
      m[i0] <= o0;
      m[i1] <= o1;
      m[i2] <= o2;
      m[i3] <= o3;
    end
    if (ph == P_CPY) begin
      for (int i = 0; i < 16; i++) m[i] <= 20'(lvl[i]);
    end

    q1_row <= cnt[1:0];
    q2_row <= q1_row;
    for (int c = 0; c < 4; c++) begin
      q1_abs[c] <= mabs[c];
      q1_sgn[c] <= mrow[c][19];
      q2_sum[c] <= 32'(q1_abs[c]) * 32'(mf00(qm)) + {8'd0, f_of(q6), 2'b00};
      q2_sgn[c] <= q1_sgn[c];
      if (q2_v) lvl[{q2_row, 2'(c)}] <= q2_sgn[c] ? -12'(qsh[c][10:0]) : 12'(qsh[c][10:0]);
    end

    s1_row <= cnt[1:0];
    s2_row <= s1_row;
    for (int c = 0; c < 4; c++) begin
      s1_p[c] <= 30'(mrow[c]) * signed'({1'b0, ls00(qm)});
      s2_y[c] <= sy[c];
      if (s2_v) begin
        if (s2_y[c] > 32'sd524287)       dcr[{s2_row, 2'(c)}] <= 20'sd524287;
        else if (s2_y[c] < -32'sd524288) dcr[{s2_row, 2'(c)}] <= -20'sd524288;
        else                             dcr[{s2_row, 2'(c)}] <= 20'(s2_y[c]);
      end
    end
  end

  always_comb begin
    for (int i = 0; i < 16; i++) begin
      lvl_out[12*i +: 12] = lvl[i];
      dc_out[20*i +: 20]  = dcr[i];
    end
  end

endmodule
