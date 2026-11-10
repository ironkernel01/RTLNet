// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_c422.sv
// Purpose: self-checking bench of rtlnet_h264_c422to420: YUYV 4:2:2 rows to 4:2:0 macroblock rows, with
//   the vertical chroma pair averaged as (a + b + 1) >> 1.
// Overview:
//   * Macroblocks of 16 random rows (plus corner values 0 and 255) go in with random gaps; the luma row
//     and the chroma row of each pair are checked against a reference written here on whole bytes.
//   * +INJECT_FAILURE is the negative control (forces one failed check).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_c422;

  import rtlnet_tb_pkg::*;

  localparam int NUM_MB = 300;

  logic         clk = 1'b0;
  logic         resetn = 1'b0;
  logic         in_valid = 1'b0;
  logic         in_odd = 1'b0;
  logic [255:0] in_data = '0;
  logic         y_valid;
  logic [127:0] y_data;
  logic         c_valid;
  logic [127:0] c_data;

  always #5 clk = ~clk;

  // One macroblock index (in_mb 0): the strip interleave of rtlnet_h264_rd_dma is covered by the encoder benches.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0] y_mb, c_mb;
  /* verilator lint_on UNUSEDSIGNAL */

  rtlnet_h264_c422to420 dut (
    .clk(clk), .resetn(resetn), .in_valid(in_valid), .in_odd(in_odd), .in_mb(2'd0), .in_data(in_data),
    .y_valid(y_valid), .y_mb(y_mb), .y_data(y_data), .c_valid(c_valid), .c_mb(c_mb), .c_data(c_data)
  );

  logic [127:0] exp_y[$];
  logic [127:0] exp_c[$];
  logic [127:0] got_y[$];
  logic [127:0] got_c[$];
  logic [255:0] rows[16];

  function automatic logic [127:0] ref_luma(input logic [255:0] row);
    logic [127:0] r;
    for (int p = 0; p < 16; p++) r[8*p +: 8] = row[8*(2*p) +: 8];
    return r;
  endfunction

  // Chroma of row a and row b: U(k) at byte 4k+1, V(k) at byte 4k+3; out U(0..7), V(0..7).
  function automatic logic [127:0] ref_chroma(input logic [255:0] a, input logic [255:0] b);
    logic [127:0] r;
    int           s;
    for (int k = 0; k < 8; k++) begin
      s = int'(a[8*(4*k+1) +: 8]) + int'(b[8*(4*k+1) +: 8]) + 1;
      r[8*k +: 8] = 8'(s / 2);
      s = int'(a[8*(4*k+3) +: 8]) + int'(b[8*(4*k+3) +: 8]) + 1;
      r[64 + 8*k +: 8] = 8'(s / 2);
    end
    return r;
  endfunction

  // Race-free: inputs change and outputs are sampled at the falling edge.
  always @(negedge clk) begin
    if (resetn && y_valid) got_y.push_back(y_data);
    if (resetn && c_valid) got_c.push_back(c_data);
  end

  int mism;
  initial begin
    resetn = 1'b0;
    repeat (4) @(negedge clk);
    resetn = 1'b1;
    repeat (2) @(negedge clk);
    for (int mb = 0; mb < NUM_MB; mb++) begin
      for (int r = 0; r < 16; r++) begin
        for (int b = 0; b < 32; b++) begin
          case (mb % 5)
            0:       rows[r][8*b +: 8] = 8'($urandom);
            1:       rows[r][8*b +: 8] = (r % 2) ? 8'd255 : 8'd0;
            2:       rows[r][8*b +: 8] = (r % 2) ? 8'd0 : 8'd255;
            3:       rows[r][8*b +: 8] = (r % 2) ? 8'd1 : 8'd0;
            default: rows[r][8*b +: 8] = 8'($urandom) & 8'h0F;
          endcase
        end
      end
      for (int r = 0; r < 16; r++) begin
        exp_y.push_back(ref_luma(rows[r]));
        if (r % 2) exp_c.push_back(ref_chroma(rows[r - 1], rows[r]));
        if (($urandom % 3) == 0) repeat ($urandom % 3) @(negedge clk);
        in_valid = 1'b1;
        in_odd   = (r % 2);
        in_data  = rows[r];
        @(negedge clk);
        in_valid = 1'b0;
      end
    end
    repeat (6) @(negedge clk);
    tb_check(got_y.size() == exp_y.size(), $sformatf("luma rows %0d, expected %0d", got_y.size(), exp_y.size()));
    tb_check(got_c.size() == exp_c.size(), $sformatf("chroma rows %0d, expected %0d", got_c.size(), exp_c.size()));
    mism = 0;
    for (int i = 0; (i < got_y.size()) && (i < exp_y.size()); i++) begin
      if (got_y[i] !== exp_y[i]) mism++;
    end
    tb_check(mism == 0, $sformatf("%0d luma row mismatches", mism));
    mism = 0;
    for (int i = 0; (i < got_c.size()) && (i < exp_c.size()); i++) begin
      if (got_c[i] !== exp_c[i]) begin
        if (mism == 0) tb_error($sformatf("chroma row %0d: got %032x expected %032x", i, got_c[i], exp_c[i]));
        mism++;
      end
    end
    tb_check(mism == 0, $sformatf("%0d chroma row mismatches", mism));
    $display("NOTE: tb_rtlnet_h264_c422: %0d macroblocks compared", NUM_MB);
    tb_verdict("tb_rtlnet_h264_c422");
  end

  initial begin
    #200ms;
    tb_error("timeout");
    tb_verdict("tb_rtlnet_h264_c422");
  end

endmodule
