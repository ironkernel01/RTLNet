// -----------------------------------------------------------------------------
// File: rtlnet_mii_rxc_rate.sv
// Purpose: IronKernel RTLNet MII RX clock qualification using the client clock.
// Overview: RXC/16 transitions cross through rtlnet_sync and are counted over
//   approximately 32.768 us. Nominal counts 102 (100 Mb/s), 10 (10 Mb/s) retain
//   the existing MAC RX_CLK_RATE units. Two in-band windows qualify; one bad
//   window or a speed change clears the verdict. Gigabit codes never qualify.
// Language: SystemVerilog-2012, source-available.
// Revision: 11-14-2026
//   * 11-14-2026: parameterize reference frequency independently of PHY clocks.
// Clocks: ref_clk (REF_CLK_HZ, 10..250 MHz), rx_clk (25 or 2.5 MHz probe).
// -----------------------------------------------------------------------------
module rtlnet_mii_rxc_rate #(parameter int REF_CLK_HZ = 62_500_000) (
  // Client reference clock (REF_CLK_HZ) and its synchronous active-low reset.
  input  logic       ref_clk,
  input  logic       ref_resetn,

  // The PHY receive clock under measurement (may stop at any time).
  input  logic       rx_clk,

  // Selected speed, ref_clk domain (00 10M, 01 100M, 10/11 rejected).
  input  logic [1:0] speed,

  // Verdict and the last window count, ref_clk registers.
  output logic       rate_ok,
  output logic [9:0] rate_count
);

  localparam longint WINDOW_NS = 32768;
  localparam longint NS_PER_SECOND = 1_000_000_000;
  localparam int WINDOW_CYCLES = int'((REF_CLK_HZ * WINDOW_NS + NS_PER_SECOND / 2) / NS_PER_SECOND);
  localparam int WINDOW_LAST = WINDOW_CYCLES - 1;    // client-clock cycles per window
  localparam logic [9:0]  COUNT_MAX   = 10'd1023;
  localparam logic [9:0]  MIN_100     = 10'd88;      // 102.4 - 14 %
  localparam logic [9:0]  MAX_100     = 10'd116;     // 102.4 + 13 %
  localparam logic [9:0]  MIN_10      = 10'd8;       // 10.24 - 22 %
  localparam logic [9:0]  MAX_10      = 10'd13;      // 10.24 + 27 %
  localparam logic [1:0]  SPEED_10    = 2'b00;
  localparam logic [1:0]  SPEED_100   = 2'b01;

  logic [3:0]  probe_count = 4'd0;   // rx_clk, free-running
  logic        probe_sync;
  logic        probe_prev;
  logic [$clog2(WINDOW_CYCLES)-1:0] window;
  logic [9:0]  edge_count;
  logic        judge;                // rate_count was latched last clock
  logic        ok_prev;              // the previous window was in band
  logic [1:0]  speed_q;
  logic        probe_edge;
  logic        speed_change;
  logic [9:0]  band_min;
  logic [9:0]  band_max;
  logic        in_band;

  // Reject reference clocks that cannot sample the divided 25 MHz probe reliably.
  generate
    if (REF_CLK_HZ < 10_000_000 || REF_CLK_HZ > 250_000_000) begin : g_bad_ref
      $fatal(1, "rtlnet_mii_rxc_rate: REF_CLK_HZ must be 10..250 MHz");
    end
  endgenerate

  // Probe divider in the receive clock.
  always_ff @(posedge rx_clk) begin
    probe_count <= probe_count + 4'd1;
  end

  // rx_clk / 16 into ref_clk.
  rtlnet_sync #(
    .WIDTH  (1),
    .STAGES (3)
  ) u_probe_sync (
    .clk    (ref_clk),
    .resetn (ref_resetn),
    .d      (probe_count[3]),
    .q      (probe_sync)
  );

  assign probe_edge   = (probe_sync != probe_prev);
  assign speed_change = (speed != speed_q);
  assign band_min     = (speed == SPEED_10) ? MIN_10 : MIN_100;
  assign band_max     = (speed == SPEED_10) ? MAX_10 : MAX_100;
  assign in_band      = ((speed == SPEED_10) || (speed == SPEED_100)) && (rate_count >= band_min) && (rate_count <= band_max);

  // Window counter, transition counter and the two-window verdict.
  always_ff @(posedge ref_clk) begin
    if (!ref_resetn) begin
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
