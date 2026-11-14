// -----------------------------------------------------------------------------
// File: rtlnet_mii_clkbuf.sv
// Purpose: IronKernel RTLNet clock buffer of one PHY-sourced MII clock; the one
//   place the MII MAC touches a vendor clock primitive.
// Overview:
//   * RTLNET_TECH_AMD (default): BUFG, the global clock net of the 25 / 2.5 MHz
//     PHY clock. Every other technology (ALTERA, LATTICE, GENERIC) forwards the
//     clock unchanged: those tools promote an input clock to a global net.
//   * No division, no gating, no MMCM: the PHY clock stops on link loss and
//     the downstream resets are asserted without it.
// Language: SystemVerilog-2012, source-available.
// Revision: 11-14-2026
//   * 11-14-2026: initial version.
// Clocks: clk_in is the PHY pin clock; clk_out is the buffered fabric clock.
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_mii_clkbuf (
  // PHY clock from the input pad and the buffered fabric clock.
  input  logic clk_in,
  output logic clk_out
);

`ifdef RTLNET_TECH_AMD
  BUFG u_bufg (
    .I (clk_in),
    .O (clk_out)
  );
`else
  assign clk_out = clk_in;
`endif

endmodule
