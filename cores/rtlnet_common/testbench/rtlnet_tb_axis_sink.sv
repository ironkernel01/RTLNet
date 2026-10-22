// -----------------------------------------------------------------------------
// File: rtlnet_tb_axis_sink.sv
// Purpose: bench AXI4-Stream sink for the RTLNet stream: collects frames into
//   a queue of byte queues and checks the stream rules on every beat.
// Overview:
//   * READY_PCT: percent of cycles with tready high (100 = never stall);
//     ready_pct can be changed at run time.
//   * Rule checks (counted through rtlnet_tb_pkg): non-final beats have tkeep
//     8'hFF, the final beat's tkeep is contiguous from bit 0, data/keep/last
//     hold while tvalid && !tready, no X on tvalid after reset.
//   * get(frame, timeout) waits for the next complete frame.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (the stream clock).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_tb_axis_sink #(
  parameter int    READY_PCT = 100,
  parameter int    SEED      = 7,
  parameter string NAME      = "sink"
)(
  input  logic        clk,
  input  logic        resetn,
  input  logic [63:0] tdata,
  input  logic [7:0]  tkeep,
  input  logic        tlast,
  input  logic        tvalid,
  output logic        tready
);

  import rtlnet_tb_pkg::*;

  int     ready_pct = READY_PCT;
  int     rng       = SEED;
  bytes_t frames[$];
  bytes_t cur;
  int     frame_count = 0;
  int     beat_count  = 0;

  logic [63:0] hold_data;
  logic [7:0]  hold_keep;
  logic        hold_last;
  logic        hold_pending = 1'b0;

  initial tready = 1'b0;

  // Ready pattern.
  always @(posedge clk) begin
    rng++;
    tready <= (ready_pct >= 100) ? 1'b1 : (($urandom(rng) % 100) < ready_pct);
  end

  // Collect beats, check the stream rules.
  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      if (tvalid === 1'bx) tb_error({NAME, ": tvalid X after reset"});
      if (hold_pending && tvalid === 1'b1) begin
        if (tdata !== hold_data || tkeep !== hold_keep || tlast !== hold_last)
          tb_error({NAME, ": beat changed while stalled"});
      end
      hold_pending <= (tvalid === 1'b1) && !tready;
      hold_data    <= tdata;
      hold_keep    <= tkeep;
      hold_last    <= tlast;
      if (tvalid === 1'b1 && tready) begin
        beat_count++;
        if (!tlast && tkeep !== 8'hFF) tb_error($sformatf("%s: non-final beat tkeep %02x", NAME, tkeep));
        if (tlast && rtlnet_pkg::keep_bytes(tkeep) == 0) tb_error($sformatf("%s: final beat tkeep %02x not contiguous", NAME, tkeep));
        for (int l = 0; l < 8; l++) if (tkeep[l]) cur.push_back(tdata[8*l +: 8]);
        if (tlast) begin
          frames.push_back(cur);
          cur = {};
          frame_count++;
        end
      end
    end else begin
      hold_pending <= 1'b0;
      cur = {};
    end
  end

  // Wait up to timeout_cycles clocks for the next frame.
  task automatic get(output bytes_t frame, input int timeout_cycles, output bit ok);
    int t;
    t = 0;
    while (frames.size() == 0 && t < timeout_cycles) begin
      @(posedge clk);
      t++;
    end
    ok = (frames.size() != 0);
    if (ok) frame = frames.pop_front();
    else    frame = {};
  endtask

  // True when no frame arrives within the window (and none is queued).
  task automatic expect_none(input int cycles, output bit none);
    repeat (cycles) @(posedge clk);
    none = (frames.size() == 0);
  endtask

endmodule
