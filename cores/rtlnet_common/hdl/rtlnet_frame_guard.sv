// -----------------------------------------------------------------------------
// File: rtlnet_frame_guard.sv
// Purpose: judge each frame on an RTLNet stream for legal tkeep qualifiers and
//   length, producing the bad flag for an rtlnet_packet_fifo's s_bad input.
// Overview:
//   * Watches the same beats the FIFO accepts (valid && ready); never stalls.
//   * malformed: a non-final beat without tkeep 8'hFF, or a final beat whose
//     tkeep is empty or not contiguous from bit 0.
//   * Length: MIN_BYTES..MAX_BYTES client bytes; the minimum is judged on the
//     final beat, the maximum on every beat.
//   * bad_in is ORed in (an upstream verdict, e.g. the GMII receiver's FCS
//     check on the final beat). A bad beat makes the rest of the frame bad.
//   * The word counter saturates so an endless malformed stream cannot wrap.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk is the stream clock; resetn is synchronous to it.
// -----------------------------------------------------------------------------
module rtlnet_frame_guard #(
  parameter int MIN_BYTES = rtlnet_pkg::ETH_MIN_FRAME_BYTES,
  parameter int MAX_BYTES = rtlnet_pkg::ETH_MAX_FRAME_BYTES
)(
  // Stream clock and synchronous active-low reset.
  input  logic       clk,
  input  logic       resetn,

  // The observed stream's qualifiers and handshake (the FIFO write side).
  input  logic [7:0] keep,
  input  logic       valid,
  input  logic       ready,
  input  logic       last,

  // Upstream verdict in; this beat's verdict out (to the FIFO's s_bad).
  input  logic       bad_in,
  output logic       bad_out
);

  import rtlnet_pkg::*;

  localparam int MAX_WORDS  = MAX_BYTES / 8;
  localparam int MIN_WORDS  = MIN_BYTES / 8;
  localparam int COUNT_BITS = clog2i(MAX_WORDS + 2);

  logic [COUNT_BITS-1:0] word_count;
  logic                  bad;
  logic [3:0]            byte_count;
  logic                  malformed;
  logic                  too_long;
  logic                  too_short;

  // A legal non-final beat always holds eight bytes: count those beats and
  // compare the final byte count only at the constant boundaries.
  assign byte_count = keep_bytes(keep);
  assign malformed  = (byte_count == 4'd0) || (!last && keep != 8'hFF);
  assign too_long   = (word_count > COUNT_BITS'(MAX_WORDS)) ||
                      (word_count == COUNT_BITS'(MAX_WORDS) && byte_count > 4'(MAX_BYTES % 8));
  assign too_short  = (word_count < COUNT_BITS'(MIN_WORDS)) ||
                      (word_count == COUNT_BITS'(MIN_WORDS) && byte_count < 4'(MIN_BYTES % 8));
  assign bad_out    = bad_in || bad || malformed || too_long || (last && too_short);

  // Per-frame word count (saturating) and sticky bad flag, cleared on the
  // final beat.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      word_count <= '0;
      bad        <= 1'b0;
    end else if (valid && ready) begin
      if (last) begin
        word_count <= '0;
        bad        <= 1'b0;
      end else begin
        if (word_count <= COUNT_BITS'(MAX_WORDS)) word_count <= word_count + 1'b1;
        bad <= bad_out;
      end
    end
  end

endmodule
