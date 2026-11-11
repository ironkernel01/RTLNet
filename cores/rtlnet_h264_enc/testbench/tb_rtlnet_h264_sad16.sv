// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_sad16.sv
// Purpose: self-checking bench of rtlnet_h264_sad16, the 16 samples per clock SAD unit of the motion search, against a software model.
// Overview:
//   * Candidates of 1 to 8 rows (rows of random samples, of extreme values 0 and 255, of equal samples) go in back to back and with
//     random gaps; each candidate carries a tag. The result of every candidate (the sum over its rows of the sum of the 16 absolute
//     differences) is compared with a model computed here on whole bytes, and the order and the tags of the results are checked.
//   * +INJECT_FAILURE is the negative control (forces one failed check).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-2).
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_sad16;

  import rtlnet_tb_pkg::*;

  logic          clk = 1'b0;
  logic          resetn = 1'b0;
  logic          in_valid = 1'b0;
  logic          in_first = 1'b0;
  logic          in_last = 1'b0;
  logic [2:0]    in_tag = '0;
  logic [127:0]  in_a = '0;
  logic [127:0]  in_b = '0;
  logic          out_valid;
  logic [2:0]    out_tag;
  logic [18:0]   out_sad;

  always #5 clk = ~clk;

  rtlnet_h264_sad16 #(.TAG_W(3)) dut (
    .clk(clk), .resetn(resetn), .in_valid(in_valid), .in_first(in_first), .in_last(in_last), .in_tag(in_tag), .in_a(in_a), .in_b(in_b),
    .out_valid(out_valid), .out_tag(out_tag), .out_sad(out_sad)
  );

  int exp_sad [$];
  int exp_tag [$];
  int n_results;

  always @(posedge clk) begin
    if (resetn && out_valid) begin
      tb_check(exp_sad.size() > 0, "a result with no candidate pending");
      if (exp_sad.size() > 0) begin
        tb_check(int'(out_sad) == exp_sad[0], $sformatf("candidate %0d: SAD %0d expected %0d", n_results, out_sad, exp_sad[0]));
        tb_check(int'(out_tag) == exp_tag[0], $sformatf("candidate %0d: tag %0d expected %0d", n_results, out_tag, exp_tag[0]));
        void'(exp_sad.pop_front());
        void'(exp_tag.pop_front());
      end
      n_results++;
    end
  end

  task automatic send_candidate(input int rows, input int mode, input int tag, input int gap_pct);
    int sum;
    int d;
    logic [127:0] a, b;
    sum = 0;
    for (int r = 0; r < rows; r++) begin
      while ($urandom_range(99, 0) < gap_pct) begin
        in_valid = 1'b0;
        @(negedge clk);
      end
      for (int i = 0; i < 16; i++) begin
        case (mode)
          0: begin a[8*i +: 8] = 8'($urandom_range(255, 0)); b[8*i +: 8] = 8'($urandom_range(255, 0)); end
          1: begin a[8*i +: 8] = 8'd255; b[8*i +: 8] = 8'd0; end
          2: begin a[8*i +: 8] = 8'd0; b[8*i +: 8] = 8'd255; end
          3: begin a[8*i +: 8] = 8'($urandom_range(255, 0)); b[8*i +: 8] = a[8*i +: 8]; end
          default: begin a[8*i +: 8] = 8'($urandom_range(255, 250)); b[8*i +: 8] = 8'($urandom_range(5, 0)); end
        endcase
        d = int'(a[8*i +: 8]) - int'(b[8*i +: 8]);
        sum += (d < 0) ? -d : d;
      end
      in_valid = 1'b1;
      in_first = (r == 0);
      in_last  = (r == rows - 1);
      in_tag   = 3'(tag);
      in_a     = a;
      in_b     = b;
      @(negedge clk);
    end
    exp_sad.push_back(sum);
    exp_tag.push_back(tag);
  endtask

  initial begin
    n_results = 0;
    repeat (4) @(negedge clk);
    resetn = 1'b1;
    repeat (2) @(negedge clk);
    // Back to back, no gaps: the 8-row candidates of the search, with every tag.
    for (int k = 0; k < 40; k++) send_candidate(8, k % 5, k % 8, 0);
    // Random row counts, with gaps.
    for (int k = 0; k < 80; k++) send_candidate(1 + ($urandom_range(7, 0)), k % 5, k % 8, 25);
    // Long candidates (the accumulator is wider than the search needs).
    for (int k = 0; k < 6; k++) send_candidate(40, 1, k, 0);
    in_valid = 1'b0;
    repeat (20) @(negedge clk);
    tb_check(exp_sad.size() == 0, $sformatf("%0d candidates without a result", exp_sad.size()));
    tb_check(n_results == 126, $sformatf("%0d results, expected 126", n_results));
    tb_verdict("tb_rtlnet_h264_sad16");
  end

endmodule
