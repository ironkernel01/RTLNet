// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_dphy_lp.sv
// Purpose: low-power state tracker of one D-PHY lane: follows the single-ended LP signals, recognizes the HS request sequence
//   (stop, LP-01, LP-00) and the end of the burst (stop), and times the HS settle interval.
// Overview:
//   * The two LP pins {Dp, Dn} come from the pin buffers asynchronously; they pass a two-flop synchronizer (rtlnet_sync) and a glitch
//     filter that accepts a new state when it was seen on two consecutive clocks.
//   * States: L_INIT (waits for the first stop state 11), L_STOP, L_RQST (01 after stop), L_SETTLE (00 after the request; counts
//     settle clocks of ref_clk so that the HS termination and prepare time of the transmitter is over), L_HS (hs_go high). The
//     lane returns to stop on LP-11 from any state. A state that does not fit the sequence (LP-10 escape entry, 00 straight from stop)
//     sends the lane back to L_INIT and no burst is started until the next stop state.
//   * hs_go is the level that tells the byte aligner that the burst data after the settle time is valid; it falls on the first
//     filtered LP-11 after the burst. enable = 0 holds the lane in L_INIT.
//   * stop_state is high while the filtered LP state is 11.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// Clocks: ref_clk (all logic, the always-running 200 MHz reference); the LP pins and settle/enable are asynchronous inputs.
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_dphy_lp (
  // Reference clock and its synchronous active-low reset.
  input  logic       ref_clk,
  input  logic       ref_resetn,

  // LP pins {Dp, Dn}, asynchronous; settle count in ref_clk periods; enable.
  input  logic [1:0] lp_pins,
  input  logic [7:0] settle,
  input  logic       enable,

  output logic       hs_go,
  output logic       stop_state,
  output logic [1:0] lp_state
);

  typedef enum logic [2:0] {L_INIT, L_STOP, L_RQST, L_SETTLE, L_HS} lstate_t;

  lstate_t     state;
  logic [1:0]  lp_s;
  logic [1:0]  lp_q;
  logic [1:0]  lp_f;
  logic [7:0]  cnt;

  rtlnet_sync #(.WIDTH(2), .STAGES(2)) u_lp_sync (
    .clk(ref_clk), .resetn(ref_resetn), .d(lp_pins), .q(lp_s)
  );

  always_ff @(posedge ref_clk) begin
    if (!ref_resetn) begin
      lp_q  <= 2'b00;
      lp_f  <= 2'b00;
      state <= L_INIT;
      cnt   <= '0;
      hs_go <= 1'b0;
    end else begin
      lp_q <= lp_s;
      if (lp_s == lp_q) lp_f <= lp_s;
      if (!enable) begin
        state <= L_INIT;
        hs_go <= 1'b0;
      end else begin
        case (state)
          L_INIT: begin
            hs_go <= 1'b0;
            if (lp_f == 2'b11) state <= L_STOP;
          end
          L_STOP: begin
            if (lp_f == 2'b01)      state <= L_RQST;
            else if (lp_f != 2'b11) state <= L_INIT;
          end
          L_RQST: begin
            cnt <= '0;
            if (lp_f == 2'b00)      state <= L_SETTLE;
            else if (lp_f == 2'b11) state <= L_STOP;
            else if (lp_f == 2'b10) state <= L_INIT;
          end
          L_SETTLE: begin
            cnt <= cnt + 8'd1;
            if (lp_f == 2'b11) begin
              state <= L_STOP;
            end else if (cnt >= settle) begin
              state <= L_HS;
              hs_go <= 1'b1;
            end
          end
          default: begin   // L_HS
            if (lp_f == 2'b11) begin
              state <= L_STOP;
              hs_go <= 1'b0;
            end
          end
        endcase
      end
    end
  end

  assign stop_state = (lp_f == 2'b11);
  assign lp_state   = lp_f;

endmodule
