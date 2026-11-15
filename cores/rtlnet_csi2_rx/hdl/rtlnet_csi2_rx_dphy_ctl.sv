// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_dphy_ctl.sv
// Purpose: reference-clock side of the D-PHY receiver: the LP state trackers of the two data lanes and of the clock lane, and the
//   HS clock detector.
// Overview:
//   * Two rtlnet_csi2_rx_dphy_lp instances (data lanes) give hs_go[1:0]; a third follows the clock lane and gives clk_stop (the clock lane
//     is in the stop state and no clock runs; the clock may stop in non-continuous mode).
//   * HS clock detector: the byte clock divides the HS clock; byte_tog toggles on every byte clock. It crosses into ref_clk through a
//     three-flop synchronizer; every edge restarts an idle counter; clk_running rises after two edges and falls when no edge came for
//     CLK_STOP_CLKS ref_clk periods (the clock stopped or was lost). A running HS clock is a condition of hs_go: a burst needs the byte
//     clock.
//   * lane_en gates hs_go per lane; enable gates both.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// Clocks: ref_clk (all logic); byte_tog, the pins and the configuration are asynchronous inputs and are synchronized here.
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_dphy_ctl #(
  parameter int CLK_STOP_CLKS = 64          // ref_clk periods without a byte clock edge before the clock counts as stopped
)(
  // Reference clock and its synchronous active-low reset.
  input  logic       ref_clk,
  input  logic       ref_resetn,

  // LP pins {Dp, Dn} of the clock lane and the two data lanes.
  input  logic [1:0] lp_clk,
  input  logic [1:0] lp_d0,
  input  logic [1:0] lp_d1,

  // Byte clock toggle (async), configuration (async levels).
  input  logic       byte_tog,
  input  logic [7:0] cfg_settle,
  input  logic [1:0] cfg_lane_en,
  input  logic       cfg_enable,

  output logic [1:0] hs_go,
  output logic       clk_running,
  output logic       clk_stop,
  output logic [1:0] lp_state_d0,
  output logic [1:0] lp_state_d1
);

  logic [1:0] hs_go_raw;
  logic       stop_c, stop_d0, stop_d1;
  logic       hs_go_c;
  logic [1:0] lp_state_c;
  logic       tog_s;
  logic       tog_d;
  logic [7:0] idle_cnt;
  logic [1:0] edge_cnt;

  rtlnet_csi2_rx_dphy_lp u_lp_c  (.ref_clk(ref_clk), .ref_resetn(ref_resetn), .lp_pins(lp_clk), .settle(8'd0), .enable(1'b1),
                                  .hs_go(hs_go_c), .stop_state(stop_c), .lp_state(lp_state_c));
  rtlnet_csi2_rx_dphy_lp u_lp_d0 (.ref_clk(ref_clk), .ref_resetn(ref_resetn), .lp_pins(lp_d0), .settle(cfg_settle),
                                  .enable(cfg_enable && cfg_lane_en[0]),
                                  .hs_go(hs_go_raw[0]), .stop_state(stop_d0), .lp_state(lp_state_d0));
  rtlnet_csi2_rx_dphy_lp u_lp_d1 (.ref_clk(ref_clk), .ref_resetn(ref_resetn), .lp_pins(lp_d1), .settle(cfg_settle),
                                  .enable(cfg_enable && cfg_lane_en[1]),
                                  .hs_go(hs_go_raw[1]), .stop_state(stop_d1), .lp_state(lp_state_d1));

  rtlnet_sync #(.WIDTH(1), .STAGES(3)) u_tog_sync (
    .clk(ref_clk), .resetn(ref_resetn), .d(byte_tog), .q(tog_s)
  );

  always_ff @(posedge ref_clk) begin
    if (!ref_resetn) begin
      tog_d       <= 1'b0;
      idle_cnt    <= '0;
      edge_cnt    <= '0;
      clk_running <= 1'b0;
    end else begin
      tog_d <= tog_s;
      if (tog_s != tog_d) begin
        idle_cnt <= '0;
        if (edge_cnt != 2'd3) edge_cnt <= edge_cnt + 2'd1;
      end else if (idle_cnt == 8'(CLK_STOP_CLKS)) begin
        edge_cnt <= '0;
      end else begin
        idle_cnt <= idle_cnt + 8'd1;
      end
      clk_running <= (edge_cnt >= 2'd2);
    end
  end

  assign clk_stop = stop_c && !clk_running;
  assign hs_go    = hs_go_raw & {2{clk_running}};

endmodule
