// -----------------------------------------------------------------------------
// File: rtlnet_sync.sv
// Purpose: the RTLNet LEVEL synchronizer: STAGES flip-flops per bit in the
//   DESTINATION clock, carrying asynchronous levels across a clock boundary.
// Overview:
//   * Levels only. Each bit must hold its new value for at least two
//     destination clock edges. Pulses use rtlnet_pulse_sync, counters
//     rtlnet_gray_sync, buses a held bundle (rtlnet_axil_cdc) or a FIFO.
//   * The source clock is not an input: a synchronizer is defined by the
//     domain it samples in.
//   * Each chain carries `RTLNET_SYNC_ATTR from rtlnet_technology.svh: the
//     no-merge / no-SRL / keep-together attribute set of the selected
//     technology (AMD ASYNC_REG + SHREG_EXTRACT + DONT_TOUCH, Quartus
//     synchronizer identification, Synplify syn_preserve + syn_srlstyle).
//   * The chain resets to RESET_VALUE (default 0) and has a matching
//     declaration initializer, so power-up and reset look the same.
//   * The register is named `sync_ff`; scripts/rtlnet_constrain_cdc.tcl finds
//     every chain's first stage (g_bit[*].sync_ff_reg[0]) by that name.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk is the destination clock; resetn is synchronous to it, active low.
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_sync #(
  parameter int         WIDTH       = 1,   // levels carried, one chain each
  parameter int         STAGES      = 3,   // flip-flops per chain, >= 2
  parameter logic       RESET_VALUE = 1'b0 // value every chain holds in reset
)(
  // Destination domain clock and its synchronous active-low reset.
  input  logic             clk,
  input  logic             resetn,

  // Asynchronous levels in; synchronized levels out in the clk domain.
  input  logic [WIDTH-1:0] d,
  output logic [WIDTH-1:0] q
);

  generate
    if (STAGES < 2) begin : g_bad_stages
      $fatal(1, "rtlnet_sync: STAGES=%0d, must be at least 2", STAGES);
    end
  endgenerate

  genvar gi;
  generate
    for (gi = 0; gi < WIDTH; gi++) begin : g_bit
      `RTLNET_SYNC_ATTR
      logic [STAGES-1:0] sync_ff = {STAGES{RESET_VALUE}};

      // Shift the asynchronous level through the chain; only the last stage
      // is ever read.
      always_ff @(posedge clk) begin
        if (!resetn) sync_ff <= {STAGES{RESET_VALUE}};
        else         sync_ff <= {sync_ff[STAGES-2:0], d[gi]};
      end

      assign q[gi] = sync_ff[STAGES-1];
    end
  endgenerate

endmodule
