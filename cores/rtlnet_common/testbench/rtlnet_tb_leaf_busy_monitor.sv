// -----------------------------------------------------------------------------
// File: rtlnet_tb_leaf_busy_monitor.sv
// Purpose: checker for the RTLNet leaf contract (documentation/
//   rtlnet_architecture.md section 7.5) attached to any leaf instance.
// Overview, checks counted through rtlnet_tb_pkg:
//   * s_axis_tready is high in every clock after reset.
//   * A reply frame (m_axis first beat) is never started without busy having
//     been high since the end of the last input frame.
//   * busy never stays high for STUCK_LIMIT clocks with no input and no output
//     activity (a stuck leaf).
//   * busy and tvalid are never X after reset.
//   * The 12-clock rise bound itself is not timed here (a leaf may also be
//     busy for frames it does not answer); a leaf bench that needs the exact
//     bound checks it directly.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version; header no longer claims a CHECK_RISE option.
// Clocks: clk (the leaf clock, proto_clk).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_tb_leaf_busy_monitor #(
  parameter string NAME        = "leaf",
  parameter int    RISE_LIMIT  = 12,
  parameter int    STUCK_LIMIT = 200000
)(
  input logic clk,
  input logic resetn,
  input logic s_tvalid,
  input logic s_tready,
  input logic s_tlast,
  input logic m_tvalid,
  input logic m_tready,
  input logic m_tlast,
  input logic busy
);

  import rtlnet_tb_pkg::*;

  int  since_last_in  = 1 << 30;
  int  busy_run       = 0;
  bit  busy_seen      = 0;          // busy rose since the last input frame ended
  bit  in_reply       = 0;
  int  ready_errors   = 0;

  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      if (busy === 1'bx || m_tvalid === 1'bx) tb_error({NAME, ": busy/tvalid X after reset"});
      if (s_tready !== 1'b1 && ready_errors < 4) begin
        ready_errors++;
        tb_error({NAME, ": s_axis_tready low (a leaf must never stall the fan-out)"});
      end
      if (s_tvalid && s_tready && s_tlast) begin
        since_last_in = 0;
        busy_seen     = 0;
      end else if (since_last_in < (1 << 30)) begin
        since_last_in++;
      end
      if (busy) busy_seen = 1;
      // First beat of a reply.
      if (m_tvalid && !in_reply) begin
        in_reply = 1;
        if (since_last_in < RISE_LIMIT * 4 && !busy_seen && !busy)
          tb_error({NAME, ": reply started with busy never raised after the input frame"});
      end
      if (m_tvalid && m_tready && m_tlast) in_reply = 0;
      // Stuck busy.
      if (busy && !s_tvalid && !m_tvalid) busy_run++;
      else                                busy_run = 0;
      if (busy_run == STUCK_LIMIT) tb_error({NAME, ": busy stuck high"});
    end else begin
      in_reply = 0;
      busy_run = 0;
    end
  end

endmodule
