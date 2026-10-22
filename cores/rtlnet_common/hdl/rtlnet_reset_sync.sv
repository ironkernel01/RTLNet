// -----------------------------------------------------------------------------
// File: rtlnet_reset_sync.sv
// Purpose: the RTLNet RESET synchronizer: asynchronous assertion, synchronous
//   release, active low in and out. Every clock domain's reset comes from one
//   instance of this module.
// Overview:
//   * Assertion is asynchronous, so resetn falls even while clk is stopped
//     (a PHY receive clock that has not started, an MMCM that has not locked).
//     Release is synchronous: STAGES clock edges after arstn rises.
//   * THIS IS THE ONE NAMED EXCEPTION to the RTLNet synchronous-reset rule.
//     No other RTLNet file has an asynchronous edge in a sensitivity list.
//   * The chain register is named `pipe`; scripts/rtlnet_constrain_cdc.tcl
//     finds its asynchronous clear pins by that name (renaming it drops a
//     false path, and the script errors on zero matches).
//   * Carries `RTLNET_SYNC_ATTR from rtlnet_technology.svh, as rtlnet_sync.sv.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk is the destination clock; arstn is asynchronous to it; resetn is
//   synchronous to it.
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_reset_sync #(
  parameter int STAGES = 4                 // flip-flops before release, >= 2
)(
  // Destination domain clock.
  input  logic clk,
  // Asynchronous assertion, active low (any source: button, lock, request).
  input  logic arstn,
  // Reset released synchronously to clk, active low.
  output logic resetn
);

  generate
    if (STAGES < 2) begin : g_bad_stages
      $fatal(1, "rtlnet_reset_sync: STAGES=%0d, must be at least 2", STAGES);
    end
  endgenerate

  `RTLNET_SYNC_ATTR
  logic [STAGES-1:0] pipe = {STAGES{1'b0}};

  // Named exception: asynchronous clear so assertion works with no clock.
  always_ff @(posedge clk or negedge arstn) begin
    if (!arstn) pipe <= {STAGES{1'b0}};
    else        pipe <= {pipe[STAGES-2:0], 1'b1};
  end

  assign resetn = pipe[STAGES-1];

endmodule
