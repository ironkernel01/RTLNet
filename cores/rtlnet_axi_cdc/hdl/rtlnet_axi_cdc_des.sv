// -----------------------------------------------------------------------------
// File: rtlnet_axi_cdc_des.sv
// Purpose: gather WORDS words of the packet-FIFO stream format {keep[7:0],
//   data[63:0]} (low word first) into one AXI beat, a BITS-wide vector, one
//   clock domain. The inverse of rtlnet_axi_cdc_ser.
// Overview:
//   * Words collect into the beat register; the beat is valid after its last
//     word. out_last is the FIFO frame-end flag of that last word.
//   * in_ready is high while the beat register is empty or its beat is accepted
//     in the same clock, so a beat is never overwritten; a stream of beats runs
//     at WORDS clocks per beat.
//   * out_data and out_valid are registered.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_axi_cdc_des #(
  parameter int BITS  = 64,                // beat width in bits
  parameter int WORDS = 1                  // ceil(BITS / 72)
)(
  input  logic            clk,
  input  logic            resetn,          // synchronous to clk, active low

  // Word stream in.
  input  logic            in_valid,
  output logic            in_ready,
  input  logic [63:0]     in_data,
  input  logic [7:0]      in_keep,
  input  logic            in_last,

  // Beat out.
  output logic            out_valid,
  input  logic            out_ready,
  output logic [BITS-1:0] out_data,
  output logic            out_last
);

  localparam int IDX_W = (WORDS > 1) ? rtlnet_pkg::clog2i(WORDS) : 1;

  logic [WORDS*72-1:0] beat_vec;
  logic [IDX_W-1:0]    idx;
  logic                final_word;

  assign final_word = (idx == IDX_W'(WORDS - 1));
  assign in_ready   = !out_valid || out_ready;
  assign out_data   = beat_vec[BITS-1:0];

  always_ff @(posedge clk) begin
    if (!resetn) begin
      out_valid <= 1'b0;
      out_last  <= 1'b0;
      beat_vec  <= '0;
      idx       <= '0;
    end else begin
      if (out_valid && out_ready) out_valid <= 1'b0;
      if (in_valid && in_ready) begin
        beat_vec[idx*72 +: 72] <= {in_keep, in_data};
        if (final_word) begin
          out_valid <= 1'b1;
          out_last  <= in_last;
          idx       <= '0;
        end else begin
          idx <= idx + 1'b1;
        end
      end
    end
  end

endmodule
