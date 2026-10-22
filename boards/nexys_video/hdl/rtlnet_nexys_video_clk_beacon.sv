// -----------------------------------------------------------------------------
// File: rtlnet_nexys_video_clk_beacon.sv
// Purpose: activity beacon of one clock domain for the board clock monitor:
//   a free-running divide-by-32 square wave, registered, that the system
//   registers sample in cpu_clk to measure the frequency of the domain.
// Overview:
//   * A 5-bit counter runs while resetn is high; `beacon` is a copy of the
//     counter MSB in its own register, so the crossing starts at a flop with
//     no logic behind it (the destination is an rtlnet_sync chain).
//   * Both beacon edges are 16 source clocks apart: at 200 MHz that is 80 ns,
//     eight cpu_clk periods, more than the two destination edges rtlnet_sync
//     needs to see a level.
//   * In reset the beacon holds 0, so a domain without clock or in reset
//     measures 0.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (the monitored domain); resetn synchronous to clk, active low.
// -----------------------------------------------------------------------------
module rtlnet_nexys_video_clk_beacon (
  // Monitored clock domain and its synchronous active-low reset.
  input  logic clk,
  input  logic resetn,

  // Beacon, clk domain, registered: square wave at f(clk) / 32.
  output logic beacon
);

  localparam int DIV_BITS = 5;

  logic [DIV_BITS-1:0] div_count;

  // Divider and registered beacon (no combinational logic on the crossing).
  always_ff @(posedge clk) begin
    if (!resetn) begin
      div_count <= '0;
      beacon    <= 1'b0;
    end else begin
      div_count <= div_count + 1'b1;
      beacon    <= div_count[DIV_BITS-1];
    end
  end

endmodule
