// -----------------------------------------------------------------------------
// File: rtlnet_iperf_div.sv
// Purpose: small sequential unsigned divider for rtlnet_iperf: 64-bit dividend
//   by 32-bit divisor, one quotient bit per clock (restoring division), used for
//   the occasional arithmetic of the iperf leaf (mean jitter at the end of a
//   test, the seconds/microseconds split of the jitter, the pacing rate of a
//   reverse stream).
// Overview:
//   * start (one clock, while idle) loads dividend and divisor; DIV_BITS clocks
//     later done pulses for one clock with quotient and remainder, which hold
//     until the next start. start while busy is ignored.
//   * Each step shifts the partial remainder left by one dividend bit and
//     subtracts the divisor when it fits (shift-subtract, MSB first).
//   * A zero divisor gives an all-ones quotient; the caller avoids it.
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (proto_clk); resetn synchronous, active low.
// -----------------------------------------------------------------------------
module rtlnet_iperf_div #(
  parameter int DIV_BITS = 64              // dividend and quotient width
)(
  // Clock and synchronous active-low reset (proto_clk).
  input  logic                clk,
  input  logic                resetn,

  // Request: one-clock start with the operands, accepted while idle.
  input  logic                start,
  input  logic [DIV_BITS-1:0] dividend,
  input  logic [31:0]         divisor,

  // Result: done pulses one clock; quotient and remainder hold until the next
  // start. busy is high from the clock after start to done.
  output logic                busy,
  output logic                done,
  output logic [DIV_BITS-1:0] quotient,
  output logic [31:0]         remainder
);

  localparam int CNT_W = $clog2(DIV_BITS + 1);

  logic [CNT_W-1:0] steps_left;
  logic [32:0]      shifted;
  logic             fits;
  logic [31:0]      divisor_q;

  assign shifted = {remainder, quotient[DIV_BITS-1]};
  assign fits    = (shifted >= {1'b0, divisor_q});

  // One shift-subtract step per clock while busy.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      busy       <= 1'b0;
      done       <= 1'b0;
      steps_left <= '0;
      quotient   <= '0;
      remainder  <= 32'd0;
      divisor_q  <= 32'd0;
    end else begin
      done <= 1'b0;
      if (!busy) begin
        if (start) begin
          busy       <= 1'b1;
          steps_left <= CNT_W'(DIV_BITS);
          quotient   <= dividend;
          remainder  <= 32'd0;
          divisor_q  <= divisor;
        end
      end else begin
        quotient   <= {quotient[DIV_BITS-2:0], fits};
        remainder  <= fits ? 32'(shifted - {1'b0, divisor_q}) : shifted[31:0];
        steps_left <= steps_left - 1'b1;
        if (steps_left == CNT_W'(1)) begin
          busy <= 1'b0;
          done <= 1'b1;
        end
      end
    end
  end

endmodule
