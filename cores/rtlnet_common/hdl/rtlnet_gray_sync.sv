// -----------------------------------------------------------------------------
// File: rtlnet_gray_sync.sv
// Purpose: carry a free-running binary counter (event counts, frame counts)
//   into another clock as a coherent value: Gray-code it in the source,
//   synchronize every Gray bit in the destination, convert back to binary.
// Overview:
//   * The source value may change by at most +1 per source clock; then only
//     one Gray bit changes per source edge and every sampled destination value
//     is either the old or the new count (never a torn mix).
//   * The Gray register (`gray_src`) and the first destination stage
//     (`gray_dst_ff[0]`) are bounded by scripts/rtlnet_constrain_cdc.tcl with
//     set_max_delay -datapath_only and set_bus_skew of one source period.
//   * Latency: one source clock to register the Gray value plus STAGES
//     destination clocks plus one binary output register.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: src_clk (counter domain), dst_clk (reader domain).
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_gray_sync #(
  parameter int WIDTH  = 32,               // counter width
  parameter int STAGES = 2                 // synchronizer depth, >= 2
)(
  // Source domain: binary counter that steps by 0 or +1 per clock.
  input  logic             src_clk,
  input  logic             src_resetn,     // synchronous to src_clk, active low
  input  logic [WIDTH-1:0] src_count,

  // Destination domain: the same count, coherent, STAGES+2 clocks late.
  input  logic             dst_clk,
  input  logic             dst_resetn,     // synchronous to dst_clk, active low
  output logic [WIDTH-1:0] dst_count
);

  generate
    if (STAGES < 2) begin : g_bad_stages
      $fatal(1, "rtlnet_gray_sync: STAGES=%0d, must be at least 2", STAGES);
    end
  endgenerate

  logic [WIDTH-1:0] gray_src;
  logic [WIDTH-1:0] gray_dst;
  logic [WIDTH-1:0] bin_dst;

  `RTLNET_SYNC_ATTR
  logic [WIDTH-1:0] gray_dst_ff [0:STAGES-1];

  // Registered Gray code of the source count (no logic between this flop and
  // the destination chain).
  always_ff @(posedge src_clk) begin
    if (!src_resetn) gray_src <= '0;
    else             gray_src <= src_count ^ (src_count >> 1);
  end

  // Destination synchronizer chain over the whole Gray word.
  always_ff @(posedge dst_clk) begin
    if (!dst_resetn) begin
      for (int s = 0; s < STAGES; s++) gray_dst_ff[s] <= '0;
    end else begin
      gray_dst_ff[0] <= gray_src;
      for (int s = 1; s < STAGES; s++) gray_dst_ff[s] <= gray_dst_ff[s-1];
    end
  end

  assign gray_dst = gray_dst_ff[STAGES-1];

  // Gray to binary: bit i is the XOR of Gray bits i..WIDTH-1.
  always_comb begin
    bin_dst[WIDTH-1] = gray_dst[WIDTH-1];
    for (int i = WIDTH - 2; i >= 0; i--) bin_dst[i] = bin_dst[i+1] ^ gray_dst[i];
  end

  // Registered binary output.
  always_ff @(posedge dst_clk) begin
    if (!dst_resetn) dst_count <= '0;
    else             dst_count <= bin_dst;
  end

endmodule
