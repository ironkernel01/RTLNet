// -----------------------------------------------------------------------------
// File: rtlnet_eth_rxc_rate.sv
// Purpose: RXC rate detector of the RTLNet MAC: measures the PHY receive
//   clock against clk125 and qualifies it for the speed firmware selected, so
//   the receive path leaves reset only on a clock of the right frequency.
// Overview:
//   * rx_clk side: a free-running 4-bit counter; bit 3 (rx_clk / 16) is the
//     probe. It has no reset (the receive reset is what this block releases)
//     and a zero declaration initializer.
//   * The probe crosses into clk125 through rtlnet_sync (u_probe_sync); every
//     transition is counted, saturating at 1023, over a window of 4096 clk125
//     cycles (32.768 us). At the window end the count is latched into
//     rate_count and judged one clock later.
//   * Nominal counts per window: 1000 Mb/s (125 MHz) 512, 100 Mb/s (25 MHz)
//     102.4, 10 Mb/s (2.5 MHz) 10.24. Accept bands: 448..576, 88..116, 8..13.
//     The bands are rate classifiers (Ethernet clocks are within 100 ppm) and
//     do not overlap, so a wrong speed never qualifies. Speed code 11 is
//     judged as 1000.
//   * rate_ok rises after two consecutive in-band windows and falls at the
//     first window out of band. A change of `speed` clears rate_ok and the
//     history at once, so every speed change passes through at least two
//     windows of rate_ok = 0.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk125 (measurement, 125 MHz, outputs), rx_clk (probe counter only).
// -----------------------------------------------------------------------------
module rtlnet_eth_rxc_rate (
  // Measurement clock (125 MHz) and its synchronous active-low reset.
  input  logic       clk125,
  input  logic       clk125_resetn,

  // The PHY receive clock under measurement (may stop at any time).
  input  logic       rx_clk,

  // Selected speed, clk125 domain (00 10M, 01 100M, 10/11 1000M).
  input  logic [1:0] speed,

  // Verdict and the last window count, clk125 registers.
  output logic       rate_ok,
  output logic [9:0] rate_count
);

  localparam logic [11:0] WINDOW_LAST = 12'd4095;    // 4096 clk125 cycles per window
  localparam logic [9:0]  COUNT_MAX   = 10'd1023;
  localparam logic [9:0]  MIN_1000    = 10'd448;     // 512 - 12.5 %
  localparam logic [9:0]  MAX_1000    = 10'd576;     // 512 + 12.5 %
  localparam logic [9:0]  MIN_100     = 10'd88;      // 102.4 - 14 %
  localparam logic [9:0]  MAX_100     = 10'd116;     // 102.4 + 13 %
  localparam logic [9:0]  MIN_10      = 10'd8;       // 10.24 - 22 %
  localparam logic [9:0]  MAX_10      = 10'd13;      // 10.24 + 27 %
  localparam logic [1:0]  SPEED_10    = 2'b00;
  localparam logic [1:0]  SPEED_100   = 2'b01;

  logic [3:0]  probe_count = 4'd0;   // rx_clk, free-running
  logic        probe_sync;
  logic        probe_prev;
  logic [11:0] window;
  logic [9:0]  edge_count;
  logic        judge;                // rate_count was latched last clock
  logic        ok_prev;              // the previous window was in band
  logic [1:0]  speed_q;
  logic        probe_edge;
  logic        speed_change;
  logic [9:0]  band_min;
  logic [9:0]  band_max;
  logic        in_band;

  // Probe divider in the receive clock.
  always_ff @(posedge rx_clk) begin
    probe_count <= probe_count + 4'd1;
  end

  // rx_clk / 16 into clk125.
  rtlnet_sync #(
    .WIDTH  (1),
    .STAGES (3)
  ) u_probe_sync (
    .clk    (clk125),
    .resetn (clk125_resetn),
    .d      (probe_count[3]),
    .q      (probe_sync)
  );

  assign probe_edge   = (probe_sync != probe_prev);
  assign speed_change = (speed != speed_q);
  assign band_min     = (speed == SPEED_10) ? MIN_10 : (speed == SPEED_100) ? MIN_100 : MIN_1000;
  assign band_max     = (speed == SPEED_10) ? MAX_10 : (speed == SPEED_100) ? MAX_100 : MAX_1000;
  assign in_band      = (rate_count >= band_min) && (rate_count <= band_max);

  // Window counter, transition counter and the two-window verdict.
  always_ff @(posedge clk125) begin
    if (!clk125_resetn) begin
      probe_prev <= 1'b0;
      window     <= '0;
      edge_count <= '0;
      rate_count <= '0;
      judge      <= 1'b0;
      ok_prev    <= 1'b0;
      rate_ok    <= 1'b0;
      speed_q    <= speed;
    end else begin
      probe_prev <= probe_sync;
      speed_q    <= speed;
      judge      <= 1'b0;
      if (window == WINDOW_LAST) begin
        window     <= '0;
        rate_count <= edge_count;
        edge_count <= {9'd0, probe_edge};
        judge      <= 1'b1;
      end else begin
        window <= window + 1'b1;
        if (probe_edge && edge_count != COUNT_MAX) edge_count <= edge_count + 1'b1;
      end
      if (speed_change) begin
        rate_ok <= 1'b0;
        ok_prev <= 1'b0;
      end else if (judge) begin
        ok_prev <= in_band;
        if (!in_band)     rate_ok <= 1'b0;
        else if (ok_prev) rate_ok <= 1'b1;
      end
    end
  end

endmodule
