// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_dphy_io.sv
// Purpose: the vendor-specific part of the D-PHY receiver: differential input buffers, the HS clock buffers, the programmable input
//   delay of the data lanes and the 1:8 deserializers. The only file of the camera receiver that instantiates device primitives.
// Overview:
//   * TARGET = "AMD" (7-series): IBUFDS on the HS clock and on each data lane, BUFIO (bit clock of the deserializers) and BUFR divide by
//     four (byte clock) from the HS clock, IDELAYE2 (variable load, 200 MHz reference, tap 0 to 31) in front of each ISERDESE2
//     (DDR, 1:8, NETWORKING). IDELAYCTRL is inside (IDELAYCTRL_INST = 1) and ready is reported; with IDELAYCTRL_INST = 0 the design
//     instantiates it elsewhere (one per IODELAY_GROUP "rtlnet_csi2_dly" region). Every other TARGET: a behavioural model for simulation
//     and for other vendors: it samples the HS pair on both edges of the HS clock, builds a byte every four HS clock periods and
//     divides the HS clock by four for the byte clock. The delay taps are accepted and have no effect in the model.
//   * Word format: raw0 and raw1 are one byte per byte-clock period with bit 0 the earliest bit on the wire (ISERDESE2 Q8 is
//     the first bit received and maps to bit 0; rtlnet_csi2_rx_lane keeps a bit_rev control for a source with the opposite order). The byte clock phase relative to the wire bytes is arbitrary; rtlnet_csi2_rx_lane finds the byte boundary.
//   * byte_tog toggles on every byte clock (clock activity for the detector in the reference clock domain); it is not reset.
//   * Delay taps load through LD in ref_clk when a tap changes; tap values are asynchronous levels synchronized by the caller into
//     ref_clk. bufr_clr holds the BUFR divider in reset (non-continuous HS clock: the divider restarts with the clock).
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: initial version; HS_DIFF_TERM (the Zybo Z7-20 bank 35 runs at 3.3 V and the Pcam adapter terminates the lanes: no internal termination).
// Clocks: hs_clk (the HS clock pair; the byte clock is derived), ref_clk (IDELAY reference and tap load clock).
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_dphy_io #(
  parameter string TARGET          = "GENERIC",   // "AMD" or any other string for the behavioural model
  parameter bit    IDELAYCTRL_INST = 1'b1,
  parameter bit    HS_DIFF_TERM    = 1'b1         // 1: internal 100 ohm termination of the HS inputs (needs VCCO 2.5 V); 0: board termination
)(
  // Reference clock (200 MHz) and its synchronous active-low reset.
  input  logic       ref_clk,
  input  logic       ref_resetn,

  // HS clock pair and data pairs.
  input  logic       hs_clk_p,
  input  logic       hs_clk_n,
  input  logic [1:0] hs_dat_p,
  input  logic [1:0] hs_dat_n,

  // Delay taps (ref_clk domain) and BUFR clear.
  input  logic [4:0] tap0,
  input  logic [4:0] tap1,
  input  logic       bufr_clr,

  // Byte clock domain reset (active low, released synchronously to byte_clk) for the deserializers.
  input  logic       byte_resetn,

  output logic       byte_clk,
  output logic       byte_tog,
  output logic [7:0] raw0,
  output logic [7:0] raw1,
  output logic       dlyctl_rdy
);

  logic byte_tog_r = 1'b0;
  always_ff @(posedge byte_clk) byte_tog_r <= ~byte_tog_r;
  assign byte_tog = byte_tog_r;

  generate
    if (TARGET == "AMD") begin : g_amd
      logic       clk_ibuf;
      logic       io_clk;
      logic [1:0] dat_ibuf;
      logic [1:0] dat_dly;
      logic [4:0] tap [0:1];
      logic [4:0] tap_applied [0:1];
      logic [1:0] ld;
      logic [4:0] cnt_in [0:1];
      logic [7:0] q0, q1;

      IBUFDS #(.DIFF_TERM(HS_DIFF_TERM ? "TRUE" : "FALSE"), .IOSTANDARD("LVDS_25")) u_ibuf_clk (.I(hs_clk_p), .IB(hs_clk_n), .O(clk_ibuf));
      BUFIO u_bufio (.I(clk_ibuf), .O(io_clk));
      BUFR #(.BUFR_DIVIDE("4"), .SIM_DEVICE("7SERIES")) u_bufr (.I(clk_ibuf), .CE(1'b1), .CLR(bufr_clr), .O(byte_clk));

      if (IDELAYCTRL_INST) begin : g_dlyctl
        (* IODELAY_GROUP = "rtlnet_csi2_dly" *)
        IDELAYCTRL u_dlyctl (.REFCLK(ref_clk), .RST(!ref_resetn), .RDY(dlyctl_rdy));
      end else begin : g_nodlyctl
        assign dlyctl_rdy = 1'b1;
      end

      assign tap[0] = tap0;
      assign tap[1] = tap1;

      for (genvar i = 0; i < 2; i++) begin : g_lane
        // Tap load: a changed tap value is presented on CNTVALUEIN and loaded by a one-clock LD pulse.
        always_ff @(posedge ref_clk) begin
          if (!ref_resetn) begin
            tap_applied[i] <= 5'd0;
            cnt_in[i]      <= 5'd0;
            ld[i]          <= 1'b0;
          end else begin
            ld[i] <= 1'b0;
            if (!ld[i] && (tap[i] != tap_applied[i])) begin
              cnt_in[i]      <= tap[i];
              ld[i]          <= 1'b1;
              tap_applied[i] <= tap[i];
            end
          end
        end

        IBUFDS #(.DIFF_TERM(HS_DIFF_TERM ? "TRUE" : "FALSE"), .IOSTANDARD("LVDS_25")) u_ibuf (.I(hs_dat_p[i]), .IB(hs_dat_n[i]), .O(dat_ibuf[i]));

        (* IODELAY_GROUP = "rtlnet_csi2_dly" *)
        IDELAYE2 #(
          .CINVCTRL_SEL("FALSE"), .DELAY_SRC("IDATAIN"), .HIGH_PERFORMANCE_MODE("TRUE"), .IDELAY_TYPE("VAR_LOAD"),
          .IDELAY_VALUE(0), .PIPE_SEL("FALSE"), .REFCLK_FREQUENCY(200.0), .SIGNAL_PATTERN("DATA")
        ) u_idelay (
          .C(ref_clk), .CE(1'b0), .CINVCTRL(1'b0), .CNTVALUEIN(cnt_in[i]), .CNTVALUEOUT(), .DATAIN(1'b0),
          .DATAOUT(dat_dly[i]), .IDATAIN(dat_ibuf[i]), .INC(1'b0), .LD(ld[i]), .LDPIPEEN(1'b0), .REGRST(1'b0)
        );

        logic [7:0] q;
        ISERDESE2 #(
          .DATA_RATE("DDR"), .DATA_WIDTH(8), .DYN_CLKDIV_INV_EN("FALSE"), .DYN_CLK_INV_EN("FALSE"), .INTERFACE_TYPE("NETWORKING"),
          .IOBDELAY("IFD"), .NUM_CE(1), .OFB_USED("FALSE"), .SERDES_MODE("MASTER"), .IS_CLKB_INVERTED(1'b1)
        ) u_iserdes (
          .BITSLIP(1'b0), .CE1(1'b1), .CE2(1'b0), .CLK(io_clk), .CLKB(io_clk), .CLKDIV(byte_clk), .CLKDIVP(1'b0), .D(1'b0),
          .DDLY(dat_dly[i]), .DYNCLKDIVSEL(1'b0), .DYNCLKSEL(1'b0), .OCLK(1'b0), .OCLKB(1'b0), .OFB(1'b0), .RST(!byte_resetn),
          .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .O(), .Q1(q[7]), .Q2(q[6]), .Q3(q[5]), .Q4(q[4]), .Q5(q[3]), .Q6(q[2]), .Q7(q[1]),
          .Q8(q[0]), .SHIFTOUT1(), .SHIFTOUT2()
        );
        if (i == 0) begin : g_q0
          assign q0 = q;
        end else begin : g_q1
          assign q1 = q;
        end
      end

      assign raw0 = q0;
      assign raw1 = q1;
    end else begin : g_model
      // Behavioural model: dual-edge sampling of the HS pair, a byte every four HS clock periods.
      logic       hs_clk_i;
      logic [1:0] dat_i;
      logic [7:0] sh0, sh1;
      logic [1:0] cnt;
      logic       byte_clk_r;

      assign hs_clk_i = hs_clk_p & ~hs_clk_n;
      assign dat_i    = hs_dat_p & ~hs_dat_n;
      assign dlyctl_rdy = 1'b1;

      initial begin
        cnt        = 2'd0;
        byte_clk_r = 1'b0;
        sh0        = 8'd0;
        sh1        = 8'd0;
        raw0       = 8'd0;
        raw1       = 8'd0;
      end

      always @(hs_clk_i) begin
        sh0 <= {dat_i[0], sh0[7:1]};
        sh1 <= {dat_i[1], sh1[7:1]};
      end

      always @(posedge hs_clk_i) begin
        cnt        <= cnt + 2'd1;
        byte_clk_r <= (cnt + 2'd1) >= 2'd2;
        if (cnt == 2'd3) begin
          raw0 <= sh0;
          raw1 <= sh1;
        end
      end

      assign byte_clk = byte_clk_r;
    end
  endgenerate

endmodule
