// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_cinterp.sv
// Purpose: self-checking bench of rtlnet_h264_cinterp, the chroma sample interpolation of ITU-T Rec. H.264 clause 8.4.2.2.2
//   (equation 8-228), against the clause's one-step formula for every fraction.
// Overview:
//   * For each of the 64 fractions (xFracC, yFracC = 0 .. 7) several 8 x 8 blocks are streamed as 9 source rows of 9 samples, with
//     random samples, extreme samples (0 and 255 in checkerboards, all 255) and random gaps between rows; some blocks follow each
//     other with no gap. The 8 output samples of every output row are compared with
//       ((8 - xFrac)(8 - yFrac) A + xFrac (8 - yFrac) B + (8 - xFrac) yFrac C + xFrac yFrac D + 32) >> 6
//     computed per sample from the four taps of the source block (A the sample, B right, C below, D below right).
//   * The tag of each output row is checked (it is the source row that completes it).
//   * +INJECT_FAILURE is the negative control (forces one failed check).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-2).
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_cinterp;

  import rtlnet_tb_pkg::*;

  logic          clk = 1'b0;
  logic          resetn = 1'b0;
  logic          in_valid = 1'b0;
  logic          in_first = 1'b0;
  logic [71:0]   in_row = '0;
  logic [3:0]    in_tag = '0;
  logic [2:0]    xf = '0;
  logic [2:0]    yf = '0;
  logic          out_valid;
  logic [63:0]   out_row;
  logic [3:0]    out_tag;

  always #5 clk = ~clk;

  rtlnet_h264_cinterp dut (
    .clk(clk), .resetn(resetn), .in_valid(in_valid), .in_first(in_first), .in_row(in_row), .in_tag(in_tag), .xf(xf), .yf(yf),
    .out_valid(out_valid), .out_row(out_row), .out_tag(out_tag)
  );

  // The block under test and the expected output.
  byte unsigned blk [9][9];
  logic [63:0]  exp_rows [8];
  int           got_n;
  int           exp_n;
  int           block_id;
  int           cur_xf, cur_yf;

  // Clause 8.4.2.2.2, equation 8-228, per sample: A = blk[r][c], B = blk[r][c + 1], C = blk[r + 1][c], D = blk[r + 1][c + 1].
  function automatic int ref_sample(input int r, input int c, input int fx, input int fy);
    int a, b, cc, d;
    a = blk[r][c];
    b = blk[r][c + 1];
    cc = blk[r + 1][c];
    d = blk[r + 1][c + 1];
    return (((8 - fx) * (8 - fy) * a) + (fx * (8 - fy) * b) + ((8 - fx) * fy * cc) + (fx * fy * d) + 32) >> 6;
  endfunction

  // Collector: output rows in order, with their tags.
  always @(posedge clk) begin
    if (resetn && out_valid) begin
      tb_check(got_n < 8, $sformatf("block %0d: more than 8 output rows", block_id));
      if (got_n < 8) begin
        tb_check(out_row == exp_rows[got_n], $sformatf("block %0d xf %0d yf %0d row %0d: got %016x expected %016x", block_id, cur_xf, cur_yf,
                                                       got_n, out_row, exp_rows[got_n]));
        tb_check(out_tag == 4'(got_n + 1), $sformatf("block %0d row %0d tag %0d", block_id, got_n, out_tag));
      end
      got_n++;
    end
  end

  task automatic run_block(input int fx, input int fy, input int mode, input int gap_pct);
    int rr, cc;
    logic [71:0] row;
    block_id++;
    cur_xf = fx;
    cur_yf = fy;
    for (int r = 0; r < 9; r++) begin
      for (int c = 0; c < 9; c++) begin
        case (mode)
          0: blk[r][c] = 8'($urandom_range(255, 0));
          1: blk[r][c] = (((r + c) % 2) == 0) ? 8'd255 : 8'd0;
          2: blk[r][c] = 8'd255;
          default: blk[r][c] = 8'($urandom_range(3, 0)) * 8'd85;
        endcase
      end
    end
    for (int r = 0; r < 8; r++) begin
      for (int c = 0; c < 8; c++) exp_rows[r][8*c +: 8] = 8'(ref_sample(r, c, fx, fy));
    end
    got_n = 0;
    @(negedge clk);
    xf = 3'(fx);
    yf = 3'(fy);
    for (int r = 0; r < 9; r++) begin
      // random gap before the row
      while (($urandom_range(99, 0)) < gap_pct) begin
        in_valid = 1'b0;
        @(negedge clk);
      end
      for (int c = 0; c < 9; c++) row[8*c +: 8] = blk[r][c];
      in_valid = 1'b1;
      in_first = (r == 0);
      in_row   = row;
      in_tag   = 4'(r);
      @(negedge clk);
    end
    in_valid = 1'b0;
    in_first = 1'b0;
    // The block's output is complete 3 clocks after the last row; the next block (fractions held) may follow only when the
    // interpolator has finished with xf / yf.
    repeat (4) @(negedge clk);
    tb_check(got_n == 8, $sformatf("block %0d xf %0d yf %0d: %0d output rows, expected 8", block_id, fx, fy, got_n));
  endtask

  initial begin
    block_id = 0;
    got_n = 0;
    exp_n = 0;
    repeat (4) @(negedge clk);
    resetn = 1'b1;
    repeat (2) @(negedge clk);
    // All 64 fractions: random blocks with gaps, an extreme block, then a random block with no gaps.
    for (int fy = 0; fy < 8; fy++) begin
      for (int fx = 0; fx < 8; fx++) begin
        run_block(fx, fy, 0, 30);
        run_block(fx, fy, 1, 0);
        run_block(fx, fy, 2, 0);
        run_block(fx, fy, 3, 0);
        run_block(fx, fy, 0, 0);
      end
    end
    tb_verdict("tb_rtlnet_h264_cinterp");
  end

endmodule
