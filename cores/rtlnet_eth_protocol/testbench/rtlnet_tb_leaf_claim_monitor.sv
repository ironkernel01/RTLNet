// -----------------------------------------------------------------------------
// File: rtlnet_tb_leaf_claim_monitor.sv
// Purpose: checker for the claim rule of the RTLNet leaf contract
//   (documentation/rtlnet_architecture.md section 7.5), attached to any leaf:
//   a registered one-clock pulse for each frame the leaf consumes, issued after
//   that frame's last beat and no later than the clock its busy falls (within
//   RISE_LIMIT clocks when the leaf never raises busy for the frame).
// Overview, checks counted through rtlnet_tb_pkg:
//   * claim is never X after reset.
//   * Every claim follows an input frame end that has not been claimed yet
//     (at most one claim per frame; never before any frame).
//   * A claim is never in the clock of a frame's last beat (it comes after).
//   * Sampling: every value is read at the clock edge that ends its cycle, so
//     the claim, busy and the handshake of one cycle are compared together.
//   * Timing: if busy was high in some clock since the last beat (that clock
//     included) and then low in an earlier clock than the claim, the claim is
//     late; if busy has stayed low since the last beat, the claim comes within
//     RISE_LIMIT clocks of it.
//   * A claim while enable is low is an error (a disabled leaf never claims).
//   * claims counts the pulses; a bench compares it with the frames its model
//     says the leaf consumes (exactly one per consumed frame, none otherwise).
//   * The checker refers to the most recent frame end, so it is exact when the
//     claimed frame is the last one that ended before the claim (always true
//     behind the wrapper, which sends one frame at a time after busy falls).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (the leaf clock, proto_clk).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_tb_leaf_claim_monitor #(
  parameter string NAME       = "leaf",
  parameter int    RISE_LIMIT = 12
)(
  input logic clk,
  input logic resetn,
  input logic enable,
  input logic s_tvalid,
  input logic s_tready,
  input logic s_tlast,
  input logic busy,
  input logic claim
);

  import rtlnet_tb_pkg::*;

  int claims       = 0;            // claim pulses seen
  int frames_ended = 0;            // input frames ended
  int errors       = 0;            // timing/ordering errors (reported up to 8)
  int since_end    = 1 << 30;      // clocks from the last-beat clock to the previous clock
  bit busy_hi      = 1'b0;         // busy seen high since the last beat (that clock included)
  bit busy_fell    = 1'b0;         // busy seen high, then low, since the last beat
  bit claim_q      = 1'b0;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 8) tb_error({NAME, ": claim: ", msg});
  endtask

  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      if (claim === 1'bx || claim === 1'bz) fail("claim X after reset");
      if (claim === 1'b1) begin
        claims++;
        if (claim_q) fail("claim high for two clocks (must be a one-clock pulse per frame)");
        if (claims > frames_ended) fail($sformatf("claim %0d with only %0d frames ended", claims, frames_ended));
        if (s_tvalid && s_tready && s_tlast) fail("claim in the clock of a frame's last beat");
        if (busy_fell) fail($sformatf("claim %0d clocks after the last beat, after busy fell", since_end + 1));
        if (!busy_hi && !busy && since_end + 1 > RISE_LIMIT && since_end < (1 << 30))
          fail($sformatf("claim %0d clocks after the last beat with busy never raised (limit %0d)", since_end + 1,
                         RISE_LIMIT));
        if (enable !== 1'b1) fail("claim while the leaf is disabled");
      end
      claim_q = (claim === 1'b1);
      // Frame end bookkeeping for the next clock.
      if (s_tvalid && s_tready && s_tlast) begin
        frames_ended++;
        since_end = 0;
        busy_hi   = (busy === 1'b1);
        busy_fell = 1'b0;
      end else begin
        if (since_end < (1 << 30)) since_end++;
        if (busy === 1'b1)  busy_hi = 1'b1;
        else if (busy_hi)   busy_fell = 1'b1;
      end
    end else begin
      claim_q = 1'b0;
    end
  end

endmodule
