// -----------------------------------------------------------------------------
// File: rtlnet_h264_cinterp.sv
// Purpose: chroma sample interpolation of inter prediction (ITU-T Rec. H.264 clause 8.4.2.2.2): the bilinear filter at eighth-sample
//   positions, one row of 8 samples per clock, for any horizontal and vertical fraction (xFracC, yFracC = 0..7).
// Overview:
//   * The caller streams the source rows of one 8 x 8 chroma block, top row first: 9 rows of 9 samples (row r holds the samples at
//     xIntC .. xIntC + 8 of the reference row yIntC + r; the extra column and row are the B, C and D taps). in_first marks the first
//     row of a block (it produces no output; the following rows do: output row r - 1 comes from source rows r - 1 and r).
//   * Clause 8.4.2.2.2, equation 8-228, for every output sample with A, B, C, D the four taps:
//       pred = ((8 - xFrac) * (8 - yFrac) * A + xFrac * (8 - yFrac) * B + (8 - xFrac) * yFrac * C + xFrac * yFrac * D + 32) >> 6.
//     The arithmetic is exact in two separable steps: h = (8 - xFrac) * P[i] + xFrac * P[i + 1] on every source row (11 bits), then
//     pred = ((8 - yFrac) * h[row] + yFrac * h[row + 1] + 32) >> 6; the products regroup without rounding, so the result equals
//     the one-step formula for every fraction (the bench checks all 64 fractions against the formula).
//   * The reference sample coordinates of equations 8-229 and 8-230 clip to the picture; the caller never reads outside the picture
//     in this phase (an integer luma vector that keeps the 16 x 16 block inside the picture keeps the taps inside, see the
//     documentation), so no clip is done here; phase 2e (picture-edge padding) adds it on the read side.
//   * Two clock latency: stage 1 registers the horizontal sums, stage 2 combines two consecutive rows. in_tag follows the row.
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-2).
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_cinterp (
  input  logic          clk,
  input  logic          resetn,

  input  logic          in_valid,
  input  logic          in_first,
  input  logic [71:0]   in_row,      // 9 samples, sample i in [8*i +: 8]
  input  logic [3:0]    in_tag,
  input  logic [2:0]    xf,          // xFracC, held while a block streams
  input  logic [2:0]    yf,          // yFracC, held while a block streams

  output logic          out_valid,
  output logic [63:0]   out_row,     // 8 samples, sample i in [8*i +: 8]
  output logic [3:0]    out_tag      // tag of the source row that completed the output row
);

  logic [10:0] h_w [8];
  logic [10:0] h1 [8];
  logic [10:0] hp [8];
  logic        s1_v;
  logic        s1_first;
  logic [3:0]  s1_tag;

  logic [3:0]  wx0, wx1, wy0, wy1;
  assign wx1 = {1'b0, xf};
  assign wx0 = 4'd8 - wx1;
  assign wy1 = {1'b0, yf};
  assign wy0 = 4'd8 - wy1;

  always_comb begin
    for (int i = 0; i < 8; i++) begin
      h_w[i] = 11'(wx0 * in_row[8*i +: 8]) + 11'(wx1 * in_row[8*(i+1) +: 8]);
    end
  end

  logic [63:0] out_w;
  always_comb begin
    for (int i = 0; i < 8; i++) begin
      out_w[8*i +: 8] = 8'((15'(wy0 * hp[i]) + 15'(wy1 * h1[i]) + 15'd32) >> 6);
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      s1_v      <= 1'b0;
      s1_first  <= 1'b0;
      s1_tag    <= '0;
      out_valid <= 1'b0;
      out_row   <= '0;
      out_tag   <= '0;
      for (int i = 0; i < 8; i++) begin
        h1[i] <= '0;
        hp[i] <= '0;
      end
    end else begin
      s1_v     <= in_valid;
      s1_first <= in_first;
      s1_tag   <= in_tag;
      if (in_valid) begin
        for (int i = 0; i < 8; i++) h1[i] <= h_w[i];
      end
      if (s1_v) begin
        for (int i = 0; i < 8; i++) hp[i] <= h1[i];
      end
      out_valid <= s1_v && !s1_first;
      out_tag   <= s1_tag;
      if (s1_v && !s1_first) out_row <= out_w;
    end
  end

endmodule
