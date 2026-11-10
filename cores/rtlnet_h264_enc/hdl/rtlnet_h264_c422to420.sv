// -----------------------------------------------------------------------------
// File: rtlnet_h264_c422to420.sv
// Purpose: convert packed YUYV 4:2:2 pixel rows to the 4:2:0 macroblock rows of the encoder:
//   a luma row passes through, and every vertical pair of chroma rows is averaged with
//   rounding, (a + b + 1) >> 1.
// Overview:
//   * Input row, 32 bytes = 16 pixels in YUYV order: byte 4k = Y(2k), 4k+1 = U(k), 4k+2 = Y(2k+1),
//     4k+3 = V(k), k = 0..7; byte 0 in in_data[7:0]. Rows arrive top to bottom of a macroblock;
//     in_odd is 0 for rows 0, 2, 4.. and 1 for rows 1, 3, 5..
//   * y_data (one clock after the row): the 16 luma bytes of the row, pixel i in y_data[8*i +: 8].
//   * c_data (two clocks after an odd row): the chroma row of the row pair, U(0..7) in bytes 0..7
//     and V(0..7) in bytes 8..15, each the rounded average of the even and odd row.
//   * The converter holds the even row's chroma until the odd row arrives, one held row per macroblock index
//     (in_mb, 0..NMB-1): rows of different macroblocks may interleave (a strip of macroblocks is read row by row), a
//     macroblock's rows arrive top to bottom and start on an even row. y_mb and c_mb carry the index of the output row.
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-10-2026: macroblock index (in_mb, y_mb, c_mb) so rows of several macroblocks can interleave.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_c422to420 #(
  parameter int NMB = 4   // macroblock indices 0..NMB-1 (a power of two, at least 2)
)(
  // Clock and synchronous active-low reset.
  input  logic         clk,
  input  logic         resetn,

  // Pixel row in, clk domain: a row is taken in a clock with in_valid high.
  input  logic         in_valid,
  input  logic         in_odd,
  input  logic [$clog2(NMB)-1:0] in_mb,
  input  logic [255:0] in_data,

  // Luma row out, one clock after in_valid.
  output logic         y_valid,
  output logic [$clog2(NMB)-1:0] y_mb,
  output logic [127:0] y_data,

  // Chroma row out, two clocks after the odd row of a pair.
  output logic         c_valid,
  output logic [$clog2(NMB)-1:0] c_mb,
  output logic [127:0] c_data
);

  logic [127:0] chroma_cur;
  logic [127:0] chroma_prev;
  logic [127:0] held [NMB];
  logic [$clog2(NMB)-1:0] mb_q;
  logic [127:0] chroma_avg;
  logic [127:0] luma_cur;
  logic         odd_valid;
  logic [127:0] avg_q;

  always_comb begin
    for (int k = 0; k < 8; k++) begin
      chroma_cur[8*k +: 8]      = in_data[32*k + 8 +: 8];
      chroma_cur[64 + 8*k +: 8] = in_data[32*k + 24 +: 8];
    end
    for (int i = 0; i < 16; i++) begin
      luma_cur[8*i +: 8] = in_data[16*i +: 8];
    end
    chroma_prev = held[in_mb];
    for (int b = 0; b < 16; b++) begin
      chroma_avg[8*b +: 8] = 8'(({1'b0, chroma_prev[8*b +: 8]} + {1'b0, chroma_cur[8*b +: 8]} + 9'd1) >> 1);
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      y_valid     <= 1'b0;
      y_data      <= '0;
      c_valid     <= 1'b0;
      c_data      <= '0;
      for (int i = 0; i < NMB; i++) held[i] <= '0;
      y_mb        <= '0;
      c_mb        <= '0;
      mb_q        <= '0;
      odd_valid   <= 1'b0;
      avg_q       <= '0;
    end else begin
      y_valid   <= in_valid;
      odd_valid <= in_valid && in_odd;
      c_valid   <= odd_valid;
      if (in_valid) begin
        y_data <= luma_cur;
        y_mb   <= in_mb;
        if (!in_odd) held[in_mb] <= chroma_cur;
        if (in_odd) begin
          avg_q <= chroma_avg;
          mb_q  <= in_mb;
        end
      end
      if (odd_valid) begin
        c_data <= avg_q;
        c_mb   <= mb_q;
      end
    end
  end

endmodule
