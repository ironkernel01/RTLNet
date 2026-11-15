// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_deskew.sv
// Purpose: lane merge of the two-lane CSI-2 receiver: removes the byte skew between the lanes and outputs one 16-bit byte pair per
//   clock ({lane 1 byte, lane 0 byte}) for the packet layer.
// Overview:
//   * Each aligned lane (rtlnet_csi2_rx_lane) marks the first byte after its sync byte. The lane that starts first is delayed until the
//     other lane's first byte arrives; the delay can be 0 to MAX_SKEW byte clocks and is held for the burst. The first pair has
//     p_first set. A second lane that starts later than MAX_SKEW clocks after the first one is a skew error.
//   * Pairs are output while both delayed lanes are valid. When one lane's valid falls the burst ends: p_end pulses one clock after the
//     last pair (never in the same clock as a valid pair).
//   * One error pulse per burst (ev_sot): a sync byte missing on a lane (ev_sync_err of the lane), or the skew beyond MAX_SKEW. The pulse
//     comes when both lanes have left the burst.
//   * lane_en = 2'b01 selects one lane: the pairs are two consecutive bytes of lane 0 (a pair every second valid clock); lane_en = 2'b11
//     two lanes; 2'b10 and 2'b00 output nothing.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// Clocks: byte_clk (all logic); lane_en is synchronized to byte_clk by the caller.
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_deskew #(
  parameter int MAX_SKEW = 3                // byte clocks of lane skew that are removed
)(
  // Byte clock and its synchronous active-low reset.
  input  logic        byte_clk,
  input  logic        byte_resetn,

  input  logic [1:0]  lane_en,

  // Lane outputs.
  input  logic [7:0]  l0_data,
  input  logic        l0_valid,
  input  logic        l0_first,
  input  logic        l0_active,
  input  logic        l0_err,
  input  logic [7:0]  l1_data,
  input  logic        l1_valid,
  input  logic        l1_first,
  input  logic        l1_active,
  input  logic        l1_err,

  // Pair stream.
  output logic        p_valid,
  output logic [15:0] p_data,
  output logic        p_first,
  output logic        p_end,
  output logic        ev_sot
);

  typedef enum logic [2:0] {M_IDLE, M_WAIT0, M_WAIT1, M_RUN, M_SKIP, M_ONE} mstate_t;

  mstate_t      state;
  logic [9:0]   sr0 [0:MAX_SKEW];     // {first, valid, data}: index k = k + 1 clocks ago
  logic [9:0]   sr1 [0:MAX_SKEW];
  logic [2:0]   cnt;
  logic [2:0]   dly0, dly1;
  logic         err_flag;
  logic         burst_seen;
  logic         one_lane;
  logic         two_lane;
  logic         f0, f1;
  logic         start;
  logic [2:0]   d0sel, d1sel;
  logic [9:0]   tap0, tap1;
  logic         pair_v;
  logic         half;
  logic [7:0]   lo_byte;
  logic         one_first;
  logic         one_started;

  assign one_lane = (lane_en == 2'b01);
  assign two_lane = (lane_en == 2'b11);
  assign f0       = sr0[0][9] && sr0[0][8];
  assign f1       = sr1[0][9] && sr1[0][8];

  always_comb begin
    start = 1'b0;
    d0sel = dly0;
    d1sel = dly1;
    if (state == M_IDLE && f0 && f1) begin
      start = 1'b1; d0sel = 3'd0; d1sel = 3'd0;
    end else if (state == M_WAIT1 && f1 && (cnt <= 3'(MAX_SKEW))) begin
      start = 1'b1; d0sel = cnt; d1sel = 3'd0;
    end else if (state == M_WAIT0 && f0 && (cnt <= 3'(MAX_SKEW))) begin
      start = 1'b1; d0sel = 3'd0; d1sel = cnt;
    end
    tap0 = sr0[d0sel];
    tap1 = sr1[d1sel];
    pair_v = (start || (state == M_RUN)) && tap0[8] && tap1[8];
  end

  always_ff @(posedge byte_clk) begin
    if (!byte_resetn) begin
      for (int i = 0; i <= MAX_SKEW; i++) begin
        sr0[i] <= '0;
        sr1[i] <= '0;
      end
      state       <= M_IDLE;
      cnt         <= '0;
      dly0        <= '0;
      dly1        <= '0;
      err_flag    <= 1'b0;
      burst_seen  <= 1'b0;
      p_valid     <= 1'b0;
      p_data      <= '0;
      p_first     <= 1'b0;
      p_end       <= 1'b0;
      ev_sot      <= 1'b0;
      half        <= 1'b0;
      lo_byte     <= '0;
      one_first   <= 1'b0;
      one_started <= 1'b0;
    end else begin
      sr0[0] <= {l0_first, l0_valid, l0_data};
      sr1[0] <= {l1_first, l1_valid, l1_data};
      for (int i = 1; i <= MAX_SKEW; i++) begin
        sr0[i] <= sr0[i-1];
        sr1[i] <= sr1[i-1];
      end
      p_valid <= 1'b0;
      p_first <= 1'b0;
      p_end   <= 1'b0;
      ev_sot  <= 1'b0;

      if (l0_err || (two_lane && l1_err)) err_flag <= 1'b1;

      if (two_lane) begin
        if (l0_active || l1_active) burst_seen <= 1'b1;
        case (state)
          M_IDLE: begin
            cnt <= 3'd1;
            if (f0 && f1) begin
              state <= M_RUN; dly0 <= 3'd0; dly1 <= 3'd0;
            end else if (f0) begin
              state <= M_WAIT1;
            end else if (f1) begin
              state <= M_WAIT0;
            end
          end
          M_WAIT1, M_WAIT0: begin
            cnt <= cnt + 3'd1;
            if (start) begin
              state <= M_RUN;
              dly0  <= d0sel;
              dly1  <= d1sel;
            end else if (cnt > 3'(MAX_SKEW) || (state == M_WAIT1 && f0) || (state == M_WAIT0 && f1)) begin
              err_flag <= 1'b1;
              state    <= M_SKIP;
            end
          end
          M_RUN: begin
            if (!pair_v) begin
              p_end <= 1'b1;
              state <= M_SKIP;
            end
          end
          default: begin   // M_SKIP: wait for both lanes to leave the burst
          end
        endcase
        if (pair_v) begin
          p_valid <= 1'b1;
          p_data  <= {tap1[7:0], tap0[7:0]};
          p_first <= start;
        end
        if ((burst_seen || (state != M_IDLE)) && !l0_active && !l1_active && (state != M_RUN)) begin
          state <= M_IDLE;
          if (err_flag || l0_err || l1_err) ev_sot <= 1'b1;
          err_flag   <= 1'b0;
          burst_seen <= 1'b0;
        end
      end else if (one_lane) begin
        // One lane: pairs of two consecutive lane 0 bytes.
        if (l0_valid) begin
          if (!half) begin
            lo_byte   <= l0_data;
            half      <= 1'b1;
            one_first <= l0_first;
          end else begin
            half        <= 1'b0;
            p_valid     <= 1'b1;
            p_data      <= {l0_data, lo_byte};
            p_first     <= one_first;
            one_started <= 1'b1;
          end
        end else if (one_started) begin
          p_end       <= 1'b1;
          one_started <= 1'b0;
          half        <= 1'b0;
        end
        if (!l0_active && !l0_valid) begin
          half <= 1'b0;
          if (err_flag || l0_err) ev_sot <= 1'b1;
          err_flag <= 1'b0;
        end
      end
    end
  end

endmodule
