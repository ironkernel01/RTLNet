// -----------------------------------------------------------------------------
// File: rtlnet_csi2_tb_phy.sv
// Purpose: bench model of a MIPI D-PHY transmitter with one or two data lanes and a clock lane, for the camera receiver benches.
// Overview:
//   * Pins as on the Pcam connector: an HS differential pair for the clock and each data lane (clk_p/clk_n, dat_p/dat_n) and two LP pins
//     {Dp, Dn} per lane (lp_clk, lp_d0, lp_d1). In LP states the HS pair is driven to 0/0 (zero differential).
//   * send_burst(lane0 bytes, lane1 bytes) runs one complete HS burst on every used lane: LP-11, LP-01 (T_LPX 60 ns), LP-00 (T_HS-PREPARE
//     70 ns), HS drive: garbage bits (an alternating 1,0 pattern for garbage_ui bit times: what a real lane shows while the transmitter
//     settles), the HS-zero leader (leader_ui zeros), the sync byte 0xB8 (unless omit_sync), the data bytes least significant bit first,
//     the HS trail (the complement of the last bit for trail_ui bit times), LP-11. The lanes run in parallel (fork); when two lanes are used
//     the bytes of a packet are distributed round-robin by send_packet.
//   * Clock: continuous (default) runs for ever; non-continuous (continuous = 0) goes through its own LP-11, LP-01, LP-00 sequence, runs
//     T_CLK-PRE before the data lanes start and for T_CLK-POST after they end, then stops with LP-11. The HS clock period is 2 UI; the
//     data changes a quarter period after each clock edge, so the clock edge is in the middle of the data eye (the D-PHY convention).
//   * Settings (module variables, set by the bench before a burst): ui_ns (bit time, 2.381 = 420 Mb/s), skew_ui[0..1] (extra delay of
//     the HS data of a lane in bit times: a skew of 8 is one byte), leader_ui, garbage_ui, trail_ui, omit_sync[0..1], lanes (1 or 2),
//     continuous.
//   * freeze_clock(ns) stops the HS clock for a while (continuous mode, in the middle of a burst when called from a parallel process): the
//     data of a lane stalls with it because every bit is timed from a clock edge.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_csi2_tb_phy (
  output logic       clk_p,
  output logic       clk_n,
  output logic [1:0] dat_p,
  output logic [1:0] dat_n,
  output logic [1:0] lp_clk,
  output logic [1:0] lp_d0,
  output logic [1:0] lp_d1
);

  import rtlnet_tb_pkg::*;

  real ui_ns       = 2.381;
  bit  continuous  = 1'b1;
  int  lanes       = 2;
  int  leader_ui   = 64;
  int  garbage_ui  = 16;
  int  trail_ui    = 40;
  bit  omit_sync [0:1];
  real skew_ui   [0:1];

  logic       hs_clk_i = 1'b0;
  logic       clk_en   = 1'b0;
  logic       clk_on   = 1'b0;
  logic [1:0] dat_on   = 2'b00;
  logic [1:0] dat_i    = 2'b00;
  logic [1:0] dat_p_i, dat_n_i;
  logic [1:0] lp_q [0:1];

  initial begin
    omit_sync[0] = 1'b0; omit_sync[1] = 1'b0;
    skew_ui[0] = 0.0; skew_ui[1] = 0.0;
    lp_clk = 2'b00; lp_d0 = 2'b11; lp_d1 = 2'b11;
    dat_p = 2'b00; dat_n = 2'b00;
    clk_on = 1'b1;
    clk_en = 1'b1;
  end

  // Switch between the continuous clock (running, the clock lane in HS) and the non-continuous clock (stopped, LP-11).
  task automatic set_continuous(input bit c);
    continuous = c;
    if (c) begin
      lp_clk = 2'b00; clk_on = 1'b1; clk_en = 1'b1;
    end else begin
      clk_en = 1'b0; #(2 * ui_ns); clk_on = 1'b0; lp_clk = 2'b11;
    end
  endtask

  // HS clock generator: toggles every bit time while enabled; the phase continues after a stop.
  initial begin
    forever begin
      if (clk_en) begin
        #(ui_ns);
        hs_clk_i = ~hs_clk_i;
      end else begin
        @(posedge clk_en);
      end
    end
  end

  assign clk_p = clk_on ? hs_clk_i : 1'b0;
  assign clk_n = clk_on ? ~hs_clk_i : 1'b0;

  // Data pins with the lane skew (transport delay).
  assign dat_p_i = dat_on & dat_i;
  assign dat_n_i = dat_on & ~dat_i;
  always @(dat_p_i[0] or dat_n_i[0]) begin
    dat_p[0] <= #(skew_ui[0] * ui_ns) dat_p_i[0];
    dat_n[0] <= #(skew_ui[0] * ui_ns) dat_n_i[0];
  end
  always @(dat_p_i[1] or dat_n_i[1]) begin
    dat_p[1] <= #(skew_ui[1] * ui_ns) dat_p_i[1];
    dat_n[1] <= #(skew_ui[1] * ui_ns) dat_n_i[1];
  end

  // One data lane burst.
  task automatic lane_burst(input int lane, input bytes_t data);
    bit bits [$];
    bit last;
    // LP sequence.
    if (lane == 0) lp_d0 = 2'b01; else lp_d1 = 2'b01;
    #60;
    if (lane == 0) lp_d0 = 2'b00; else lp_d1 = 2'b00;
    #70;
    // Bits: garbage, leader zeros, sync, data, trail.
    for (int i = 0; i < garbage_ui; i++) bits.push_back((i % 2) == 0);
    for (int i = 0; i < leader_ui; i++) bits.push_back(1'b0);
    if (!omit_sync[lane]) begin
      for (int k = 0; k < 8; k++) bits.push_back(8'hB8 >> k & 1'b1);
    end
    for (int i = 0; i < data.size(); i++) begin
      for (int k = 0; k < 8; k++) bits.push_back(data[i][k]);
    end
    last = (data.size() > 0) ? data[data.size() - 1][7] : 1'b0;
    for (int i = 0; i < trail_ui; i++) bits.push_back(!last);
    dat_on[lane] = 1'b1;
    for (int i = 0; i < bits.size(); i++) begin
      @(hs_clk_i);
      #(ui_ns / 2.0);
      dat_i[lane] = bits[i];
    end
    @(hs_clk_i);
    #(ui_ns / 2.0);
    dat_on[lane] = 1'b0;
    if (lane == 0) lp_d0 = 2'b11; else lp_d1 = 2'b11;
  endtask

  task automatic clock_start();
    lp_clk = 2'b01;
    #60;
    lp_clk = 2'b00;
    #80;
    clk_on = 1'b1;
    clk_en = 1'b1;
    #(40 * ui_ns);        // T_CLK-PRE and the clock zero time before the data lanes begin
  endtask

  task automatic clock_stop();
    #(60 + 52 * ui_ns);   // T_CLK-POST
    clk_en = 1'b0;
    #(2 * ui_ns);
    clk_on = 1'b0;
    lp_clk = 2'b11;
  endtask

  task automatic send_burst(input bytes_t l0, input bytes_t l1);
    if (!continuous) clock_start();
    fork
      lane_burst(0, l0);
      if (lanes == 2) lane_burst(1, l1);
    join
    if (!continuous) clock_stop();
    #120;                 // T_HS-EXIT: the lanes stay in LP-11 before the next request
  endtask

  // Distribute the bytes of a packet over the lanes (round robin) and send them as one burst.
  task automatic send_packet(input bytes_t pkt);
    bytes_t a, b;
    for (int i = 0; i < pkt.size(); i++) begin
      if (lanes == 1 || (i % 2) == 0) a.push_back(pkt[i]);
      else                            b.push_back(pkt[i]);
    end
    send_burst(a, b);
  endtask

  task automatic freeze_clock(input real ns);
    clk_en = 1'b0;
    #(ns);
    clk_en = 1'b1;
  endtask

endmodule
