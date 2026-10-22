// -----------------------------------------------------------------------------
// File: rtlnet_pulse_sync.sv
// Purpose: carry single-cycle events from one clock to another: a toggle in
//   the source domain, a 3-stage rtlnet_sync in the destination, and an edge
//   detect that gives one destination-cycle pulse per source event.
// Overview:
//   * Open loop. Two source events closer together than STAGES + 1
//     destination clock periods can flip the toggle back before it is sampled
//     and are then both lost. Callers guarantee that spacing (register
//     strobes, frame events at Ethernet frame rates) or use a FIFO.
//   * src_pulse must be a one-cycle pulse; a held level toggles every cycle.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: src_clk (source events), dst_clk (destination pulses).
// -----------------------------------------------------------------------------
module rtlnet_pulse_sync #(
  parameter int STAGES = 3                 // synchronizer depth, >= 2
)(
  // Source domain: one-cycle event pulses.
  input  logic src_clk,
  input  logic src_resetn,                 // synchronous to src_clk, active low
  input  logic src_pulse,

  // Destination domain: one dst_clk pulse per source event.
  input  logic dst_clk,
  input  logic dst_resetn,                 // synchronous to dst_clk, active low
  output logic dst_pulse
);

  logic src_toggle;
  logic dst_level;
  logic dst_level_d;

  // Each source event flips the toggle level.
  always_ff @(posedge src_clk) begin
    if (!src_resetn)    src_toggle <= 1'b0;
    else if (src_pulse) src_toggle <= ~src_toggle;
  end

  // Toggle level crosses through the shared level synchronizer.
  rtlnet_sync #(
    .WIDTH  (1),
    .STAGES (STAGES)
  ) u_pulse_sync (
    .clk    (dst_clk),
    .resetn (dst_resetn),
    .d      (src_toggle),
    .q      (dst_level)
  );

  // History register and registered edge detect in the destination.
  always_ff @(posedge dst_clk) begin
    if (!dst_resetn) begin
      dst_level_d <= 1'b0;
      dst_pulse   <= 1'b0;
    end else begin
      dst_level_d <= dst_level;
      dst_pulse   <= dst_level ^ dst_level_d;
    end
  end

endmodule
