// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_lane.sv
// Purpose: byte alignment of one D-PHY data lane: finds the HS sync byte in the bit stream of the lane deserializer and outputs the
//   byte-aligned data of the burst.
// Overview:
//   * Input raw is one 8-bit word per byte clock from the deserializer, bit 0 the earliest bit on the wire (bit_rev = 1 reverses the
//     bit order of the word for a deserializer that delivers the earliest bit in bit 7). The aligner keeps the last three words (24
//     bits in time order) and, while a burst is being searched (hs_go high, settle time over), looks for the sync byte 0xB8 (wire
//     bits 0,0,0,1,1,1,0,1) at any of the eight bit offsets, preceded by at least four zero bits (the end of the HS-zero leader).
//     A candidate is taken only where it starts inside the middle word, so each position is seen exactly once as the window slides.
//   * On a match the offset is locked for the burst: every later byte is the 8 bits at that offset of the same window. The first
//     byte after the sync has o_first set. Output o_valid stays high until HOLD_CLKS clocks after hs_go fell: the LP detection (reference
//     clock, synchronizers) is slower than the data path, so ending the output at hs_go would cut the last real bytes; the HS trail and
//     junk bytes that follow the last packet byte are part of the output and the packet layer ignores them. HOLD_CLKS must stay shorter than
//     the gap between two bursts in byte clocks (T_HS-EXIT, LP-01, LP-00 and the settle time: at least about four clocks at 100 Mb/s).
//   * Without a sync byte within SYNC_WINDOW byte clocks after hs_go rose (or when hs_go falls first) the burst is abandoned and
//     ev_sync_err pulses once; the lane stays quiet until hs_go falls.
//   * active is high from the start of a search until hs_go has fallen again; o_locked is high from the match until then.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// Clocks: byte_clk (all logic); hs_go and bit_rev are already synchronized to byte_clk by the caller.
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_lane #(
  parameter int SYNC_WINDOW = 24,           // byte clocks after hs_go in which the sync byte must appear
  parameter int HOLD_CLKS   = 4             // byte clocks the output stays valid after hs_go fell
)(
  // Byte clock and its synchronous active-low reset.
  input  logic       byte_clk,
  input  logic       byte_resetn,

  // Deserializer word, hs_go (HS burst running and settled) and the bit order selection.
  input  logic [7:0] raw,
  input  logic       hs_go,
  input  logic       bit_rev,

  // Aligned bytes.
  output logic [7:0] o_data,
  output logic       o_valid,
  output logic       o_first,
  output logic       o_locked,
  output logic       active,
  output logic       ev_sync_err
);

  typedef enum logic [2:0] {L_IDLE, L_SEARCH, L_LOCK, L_SKIP, L_HOLD} lstate_t;

  lstate_t       state;
  logic [7:0]    w0, w1, w2;
  logic [7:0]    raw_u;
  logic [23:0]   win;
  logic          found;
  logic [2:0]    found_k;
  logic [2:0]    kk;
  logic [7:0]    cnt;
  logic          first_pend;
  logic [15:0]   sel16;

  always_comb begin
    for (int i = 0; i < 8; i++) raw_u[i] = bit_rev ? raw[7-i] : raw[i];
  end

  // Time order: w2 oldest, w0 newest; win bit 0 is the oldest bit.
  assign win = {w0, w1, w2};

  always_comb begin
    found   = 1'b0;
    found_k = 3'd0;
    for (int k = 7; k >= 0; k--) begin
      if ((win[8+k +: 8] == 8'hB8) && (win[4+k +: 4] == 4'h0)) begin
        found   = 1'b1;
        found_k = 3'(k);
      end
    end
  end

  assign sel16 = win[23:8] >> kk;

  always_ff @(posedge byte_clk) begin
    if (!byte_resetn) begin
      w0          <= '0;
      w1          <= '0;
      w2          <= '0;
      state       <= L_IDLE;
      kk          <= '0;
      cnt         <= '0;
      first_pend  <= 1'b0;
      o_data      <= '0;
      o_valid     <= 1'b0;
      o_first     <= 1'b0;
      o_locked    <= 1'b0;
      active      <= 1'b0;
      ev_sync_err <= 1'b0;
    end else begin
      w0 <= raw_u;
      w1 <= w0;
      w2 <= w1;
      ev_sync_err <= 1'b0;
      o_valid     <= 1'b0;
      o_first     <= 1'b0;
      case (state)
        L_IDLE: begin
          o_locked <= 1'b0;
          if (hs_go) begin
            state  <= L_SEARCH;
            cnt    <= '0;
            active <= 1'b1;
          end else begin
            active <= 1'b0;
          end
        end
        L_SEARCH: begin
          if (!hs_go) begin
            ev_sync_err <= 1'b1;
            state       <= L_IDLE;
            active      <= 1'b0;
          end else if (found) begin
            kk         <= found_k;
            first_pend <= 1'b1;
            state      <= L_LOCK;
            o_locked   <= 1'b1;
          end else begin
            cnt <= cnt + 8'd1;
            if (cnt == 8'(SYNC_WINDOW - 1)) begin
              ev_sync_err <= 1'b1;
              state       <= L_SKIP;
            end
          end
        end
        L_LOCK: begin
          o_data     <= sel16[7:0];
          o_valid    <= 1'b1;
          o_first    <= first_pend;
          first_pend <= 1'b0;
          if (!hs_go) begin
            state <= L_HOLD;
            cnt   <= 8'(HOLD_CLKS);
          end
        end
        L_HOLD: begin
          // The LP detection is slower than the data path of the lane: the last real bytes are still in the window when hs_go falls, so
          // the output stays valid for HOLD_CLKS more clocks (HS trail and junk bytes, ignored by the packet layer).
          if (hs_go) begin
            state  <= L_SEARCH;           // a new burst began (the gap between bursts is longer than the hold)
            cnt    <= '0;
            o_locked <= 1'b0;
          end else begin
            o_data  <= sel16[7:0];
            o_valid <= 1'b1;
            cnt     <= cnt - 8'd1;
            if (cnt == 8'd1) begin
              state      <= L_IDLE;
              o_locked   <= 1'b0;
              active     <= 1'b0;
              first_pend <= 1'b0;
            end
          end
        end
        default: begin   // L_SKIP: wait for the end of the burst
          if (!hs_go) begin
            state  <= L_IDLE;
            active <= 1'b0;
          end
        end
      endcase
    end
  end

endmodule
