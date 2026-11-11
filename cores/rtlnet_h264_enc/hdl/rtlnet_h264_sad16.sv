// -----------------------------------------------------------------------------
// File: rtlnet_h264_sad16.sv
// Purpose: the sum of absolute differences of the motion search: 16 sample pairs per clock (one macroblock row), accumulated over the
//   rows of one candidate (documentation section 16.3).
// Overview:
//   * One row per clock: in_a and in_b hold 16 samples each (sample i in [8*i +: 8]); in_first marks the first row of a candidate and
//     in_last the last. After a pipeline of four registers the accumulated sum of the rows of the candidate appears with out_valid
//     (the clock after the last row's sum is added) together with the candidate tag of the last row.
//   * Pipeline: absolute differences (16 x 8 bit), sums of four (4 x 10 bit), the row sum (12 bit), accumulation (15 bit: the search
//     adds 8 rows, at most 8 x 16 x 255 = 32 640; the module accepts up to 128 rows without overflow of its 19-bit accumulator).
//   * Rows of different candidates may follow each other with no gap; every row carries its own first / last flag and tag.
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-2).
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_sad16 #(
  parameter int TAG_W = 3
)(
  input  logic              clk,
  input  logic              resetn,

  input  logic              in_valid,
  input  logic              in_first,
  input  logic              in_last,
  input  logic [TAG_W-1:0]  in_tag,
  input  logic [127:0]      in_a,
  input  logic [127:0]      in_b,

  output logic              out_valid,
  output logic [TAG_W-1:0]  out_tag,
  output logic [18:0]       out_sad
);

  logic [7:0]  ad [16];
  logic [9:0]  gs [4];
  logic [11:0] rs;
  logic        v1, f1, l1;
  logic        v2, f2, l2;
  logic        v3, f3, l3;
  logic [TAG_W-1:0] t1, t2, t3;
  logic [18:0] acc;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      v1 <= 1'b0; f1 <= 1'b0; l1 <= 1'b0; t1 <= '0;
      v2 <= 1'b0; f2 <= 1'b0; l2 <= 1'b0; t2 <= '0;
      v3 <= 1'b0; f3 <= 1'b0; l3 <= 1'b0; t3 <= '0;
      for (int i = 0; i < 16; i++) ad[i] <= '0;
      for (int i = 0; i < 4; i++) gs[i] <= '0;
      rs        <= '0;
      acc       <= '0;
      out_valid <= 1'b0;
      out_tag   <= '0;
      out_sad   <= '0;
    end else begin
      // Stage 1: absolute differences.
      v1 <= in_valid;
      f1 <= in_first;
      l1 <= in_last;
      t1 <= in_tag;
      for (int i = 0; i < 16; i++) begin
        ad[i] <= (in_a[8*i +: 8] >= in_b[8*i +: 8]) ? (in_a[8*i +: 8] - in_b[8*i +: 8]) : (in_b[8*i +: 8] - in_a[8*i +: 8]);
      end
      // Stage 2: sums of four.
      v2 <= v1;
      f2 <= f1;
      l2 <= l1;
      t2 <= t1;
      for (int i = 0; i < 4; i++) gs[i] <= 10'(ad[4*i]) + 10'(ad[4*i + 1]) + 10'(ad[4*i + 2]) + 10'(ad[4*i + 3]);
      // Stage 3: the row sum.
      v3 <= v2;
      f3 <= f2;
      l3 <= l2;
      t3 <= t2;
      rs <= 12'(gs[0]) + 12'(gs[1]) + 12'(gs[2]) + 12'(gs[3]);
      // Stage 4: accumulate; the result is registered with out_valid in the clock after the last row.
      out_valid <= 1'b0;
      if (v3) begin
        if (f3) acc <= 19'(rs);
        else    acc <= acc + 19'(rs);
        if (l3) begin
          out_valid <= 1'b1;
          out_tag   <= t3;
          out_sad   <= f3 ? 19'(rs) : (acc + 19'(rs));
        end
      end
    end
  end

endmodule
