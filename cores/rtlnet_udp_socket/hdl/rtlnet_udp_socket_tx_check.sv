// -----------------------------------------------------------------------------
// File: rtlnet_udp_socket_tx_check.sv
// Purpose: application-side (app_clk) front end of the UDP socket layer's
//   transmit path. Splits each datagram the application writes into a payload
//   frame for the TX payload FIFO and a two-word descriptor for the TX
//   descriptor FIFO, and judges the datagram's length while it streams, so
//   the frame builder in proto_clk knows the verdict before it starts a frame.
// Overview:
//   * Input: meta 0, meta 1, payload (documentation/rtlnet_architecture.md
//     section 7.7). A datagram is accepted only when both FIFOs have a free
//     slot (s_axis_tready low between datagrams otherwise); once meta 0 is
//     taken the rest of the datagram is never stalled.
//   * Verdict "bad" (the frame builder drops the datagram and counts it):
//       - meta 0 carries tlast (no meta 1);
//       - meta 0 length > 1472;
//       - zero length but payload beats follow, or a non-zero length and
//         meta 1 carries tlast;
//       - a non-final payload beat with tkeep != 8'hFF, a final beat with an
//         empty or non-contiguous tkeep;
//       - the payload byte count differs from the meta 0 length.
//   * Payload FIFO: the payload beats unchanged; s_bad on the final beat when
//     the verdict is bad, so a bad datagram never reaches the read side (the
//     FIFO also drops anything longer than one slot by itself).
//   * Descriptor FIFO: after the final input beat, word 0 = meta 0 and word 1
//     = meta 1 with flags bit 7 replaced by the verdict (FLAG_TX_BAD). A
//     datagram with no meta 1 gets socket index 0xFF (always out of range).
//     A datagram has a payload frame in the payload FIFO exactly when its
//     length is non-zero and its verdict is good.
//   * The descriptor is written in the two clocks after the final input beat
//     (s_axis_tready is low then); the descriptor FIFO's slot was reserved by
//     the ready check at meta 0, so both writes are always accepted.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (app_clk); resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_udp_socket_tx_check (
  // Clock and synchronous active-low reset, app_clk domain.
  input  logic        clk,
  input  logic        resetn,

  // Application transmit stream (app_clk): meta 0, meta 1, payload.
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // TX payload FIFO write side (app_clk).
  output logic [63:0] pay_data,
  output logic [7:0]  pay_keep,
  output logic        pay_valid,
  output logic        pay_last,
  output logic        pay_bad,
  input  logic        pay_ready,

  // TX descriptor FIFO write side (app_clk): two words per datagram.
  output logic [63:0] desc_data,
  output logic        desc_valid,
  output logic        desc_last,
  input  logic        desc_ready
);

  import rtlnet_pkg::*;
  import rtlnet_udp_socket_pkg::*;

  localparam logic [2:0] C_META0 = 3'd0;    // waiting for meta 0 (both FIFOs free)
  localparam logic [2:0] C_META1 = 3'd1;
  localparam logic [2:0] C_PAY   = 3'd2;    // payload beats to the payload FIFO
  localparam logic [2:0] C_DESC0 = 3'd3;    // descriptor word 0
  localparam logic [2:0] C_DESC1 = 3'd4;    // descriptor word 1 (last)

  localparam logic [11:0] MAX_PAYLOAD = 12'(MAX_PAYLOAD_BYTES);
  localparam logic [11:0] BYTES_SAT   = 12'hFFF;

  logic [2:0]  state;
  logic [63:0] meta0;
  logic [63:0] meta1;
  logic        bad;                 // verdict so far
  logic [11:0] byte_count;          // payload bytes of the non-final beats (saturating)
  logic        beat;
  logic [11:0] final_bytes;
  logic        final_bad;
  logic        len_too_big;
  logic [63:0] desc_word1;

  assign beat        = s_axis_tvalid && s_axis_tready;
  assign len_too_big = (s_axis_tdata[15:0] > {4'd0, MAX_PAYLOAD});

  always_comb begin
    case (state)
      C_META0: s_axis_tready = pay_ready && desc_ready;
      C_META1: s_axis_tready = 1'b1;
      C_PAY:   s_axis_tready = pay_ready;
      default: s_axis_tready = 1'b0;
    endcase
  end

  // Verdict on the final payload beat (combinational, drives pay_bad).
  assign final_bytes = (byte_count > BYTES_SAT - 12'd8) ? BYTES_SAT : byte_count + {8'd0, keep_bytes(s_axis_tkeep)};
  assign final_bad   = bad || (keep_bytes(s_axis_tkeep) == 4'd0) || ({4'd0, final_bytes} != meta0[15:0]);

  // Payload FIFO: the payload beats pass through unchanged.
  assign pay_data  = s_axis_tdata;
  assign pay_keep  = s_axis_tkeep;
  assign pay_last  = s_axis_tlast;
  assign pay_valid = (state == C_PAY) && s_axis_tvalid;
  assign pay_bad   = s_axis_tlast && final_bad;

  // Descriptor FIFO: meta 0, then meta 1 with the verdict in flags bit 7.
  always_comb begin
    desc_word1                                = meta1;
    desc_word1[META1_FLAG_LSB + FLAG_TX_BAD]  = bad;
  end
  assign desc_valid = (state == C_DESC0) || (state == C_DESC1);
  assign desc_last  = (state == C_DESC1);
  assign desc_data  = (state == C_DESC1) ? desc_word1 : meta0;

  // Datagram sequencer and length check.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      state      <= C_META0;
      meta0      <= '0;
      meta1      <= '0;
      bad        <= 1'b0;
      byte_count <= '0;
    end else begin
      case (state)
        C_META0: begin
          if (beat) begin
            meta0      <= s_axis_tdata;
            meta1      <= meta1_pack(SOCK_IDX_NONE, 8'h00, 48'd0);
            bad        <= s_axis_tlast || len_too_big;
            byte_count <= '0;
            state      <= s_axis_tlast ? C_DESC0 : C_META1;
          end
        end
        C_META1: begin
          if (beat) begin
            meta1 <= s_axis_tdata;
            if (s_axis_tlast) begin
              bad   <= bad || (meta0[15:0] != 16'd0);
              state <= C_DESC0;
            end else begin
              state <= C_PAY;
            end
          end
        end
        C_PAY: begin
          if (beat) begin
            if (s_axis_tlast) begin
              bad   <= final_bad;
              state <= C_DESC0;
            end else begin
              if (s_axis_tkeep != 8'hFF) bad <= 1'b1;
              byte_count <= (byte_count > BYTES_SAT - 12'd8) ? BYTES_SAT : byte_count + 12'd8;
            end
          end
        end
        C_DESC0: begin
          if (desc_ready) state <= C_DESC1;
        end
        C_DESC1: begin
          if (desc_ready) state <= C_META0;
        end
        default: state <= C_META0;
      endcase
    end
  end

  // Simulation-only check: the slot reserved at meta 0 always takes the
  // descriptor and the payload beats.
  // synthesis translate_off
  always @(posedge clk) begin
    if (resetn && ((desc_valid && !desc_ready) || (pay_valid && !pay_ready)))
      $error("%m: TX FIFO write refused after the slot check");
  end
  // synthesis translate_on

endmodule
