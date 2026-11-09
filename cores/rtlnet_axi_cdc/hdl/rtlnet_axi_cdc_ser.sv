// -----------------------------------------------------------------------------
// File: rtlnet_axi_cdc_ser.sv
// Purpose: serialize one AXI beat (a BITS-wide vector) into WORDS words of the
//   packet-FIFO stream format {keep[7:0], data[63:0]} (72 payload bits per word,
//   low word first), one clock domain.
// Overview:
//   * One beat is held in a register; its words leave in order, one per clock
//     while out_ready is high. out_last is high on the final word of a beat
//     whose in_last was set (a burst's last beat, or any beat of a one-beat
//     channel).
//   * in_ready is high while the holding register is empty or its last word is
//     accepted in the same clock; a stream of beats runs at WORDS clocks per beat.
//   * Unused high bits of the last word are zero.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_axi_cdc_ser #(
  parameter int BITS  = 64,                // beat width in bits
  parameter int WORDS = 1                  // ceil(BITS / 72)
)(
  input  logic            clk,
  input  logic            resetn,          // synchronous to clk, active low

  // Beat in.
  input  logic            in_valid,
  output logic            in_ready,
  input  logic [BITS-1:0] in_data,
  input  logic            in_last,

  // Word stream out.
  output logic            out_valid,
  input  logic            out_ready,
  output logic [63:0]     out_data,
  output logic [7:0]      out_keep,
  output logic            out_last
);

  localparam int IDX_W = (WORDS > 1) ? rtlnet_pkg::clog2i(WORDS) : 1;

  logic [WORDS*72-1:0] hold_vec;
  logic                hold_valid;
  logic                hold_last;
  logic [IDX_W-1:0]    idx;
  logic                final_word;

  assign final_word = (idx == IDX_W'(WORDS - 1));
  assign out_valid  = hold_valid;
  assign in_ready   = !hold_valid || (out_ready && final_word);
  assign out_last   = hold_last && final_word;
  assign {out_keep, out_data} = hold_vec[idx*72 +: 72];

  always_ff @(posedge clk) begin
    if (!resetn) begin
      hold_valid <= 1'b0;
      hold_vec   <= '0;
      hold_last  <= 1'b0;
      idx        <= '0;
    end else begin
      if (hold_valid && out_ready) begin
        if (final_word) begin
          hold_valid <= 1'b0;
          idx        <= '0;
        end else begin
          idx <= idx + 1'b1;
        end
      end
      if (in_valid && in_ready) begin
        hold_valid <= 1'b1;
        hold_vec   <= (WORDS*72)'(in_data);
        hold_last  <= in_last;
        idx        <= '0;
      end
    end
  end

endmodule
