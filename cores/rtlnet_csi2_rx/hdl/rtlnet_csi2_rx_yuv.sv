// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_yuv.sv
// Purpose: convert RGB pixels to BT.709 limited-range YUV 4:2:2 words of two pixels, the video word format of rtlnet_csi2_rx.
// Overview: RGB input packs R[23:16], B[15:8], G[7:0].
//   Output bytes in increasing memory address are Y0 Cb Y1 Cr, two pixels/beat (word {Cr, Y1, Cb, Y0}).
//   Q16 matrix rows (R,G,B): Y=(11966,40254,4064), Cb=(-6596,-22189,28784),
//   Cr=(28784,-26145,-2639). Y offset is 16; chroma offset is 128. Round to
//   nearest with ties toward positive infinity, then clip Y to 16..235 and
//   chroma to 16..240. Chroma is the average of the two UNROUNDED pixel values,
//   sited horizontally between Y0 and Y1. No vertical subsampling occurs here.
//   State matrix: FIRST accepts a first pixel; SECOND accepts a second pixel
//   and publishes a pair. FIRST may fill while an earlier pair is stalled.
//   SECOND waits for output space. A new SOF discards an orphan first pixel;
//   EOL on an unpaired pixel discards it and sets format_error until reset.
//   Even line widths are required. SOF follows Y0; EOL follows Y1. Output data
//   and flags stay stable until accepted, including through malformed inputs.
//   Elastic input, product and matrix-sum stages precede pairing; a pair register stage
//   (sum before clip) follows it. Each register stage
//   contains either constant products or the sum tree; stalls preserve pixels.
//   Rounding offsets are folded into the product stage (Y: 16.5 in Q16; each
//   chroma term: half of 128.5 in Q17 units) so the pair stage is one add, a
//   shift and a clip; the results equal the rounded formulas above exactly.
// Language: SystemVerilog-2012.
// Clocks: clk (90 MHz video clock, one pixel per clock at most); resetn synchronous active low.
// Revision: 11-15-2026.
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_yuv (
  // Core clock and synchronous active-low reset.
  input  logic clk,
  input  logic resetn,

  // RGB pixel stream (one pixel per accepted beat, R[23:16] B[15:8] G[7:0]), SOF/EOL flags.
  input  logic [23:0] s_axis_tdata,
  input  logic s_axis_tvalid,
  output logic s_axis_tready,
  input  logic s_axis_tuser,
  input  logic s_axis_tlast,

  // Video stream out: two pixels per word, byte order Y0 Cb Y1 Cr (word {Cr, Y1, Cb, Y0}), same clock domain.
  output logic [31:0] m_axis_tdata,
  output logic m_axis_tvalid,
  input  logic m_axis_tready,
  output logic m_axis_tuser,
  output logic m_axis_tlast,

  // Sticky malformed-line indication; clears on reset.
  output logic format_error
);
  localparam logic S_FIRST = 1'b0;
  localparam logic S_SECOND = 1'b1;
  logic state;
  logic [7:0] first_y;
  logic signed [27:0] first_cb;
  logic signed [27:0] first_cr;
  logic first_sof;
  logic signed [31:0] red;
  logic signed [31:0] green;
  logic signed [31:0] blue;
  logic signed [27:0] y_q16;
  logic signed [27:0] cb_q16;
  logic signed [27:0] cr_q16;
  logic signed [28:0] pair_cb;
  logic signed [28:0] pair_cr;
  logic signed [25:0] yr, yg, yb, cbr, cbg, cbb, crr, crg, crb;
  logic in_valid, in_sof, in_eol, in_ready;
  logic [23:0] in_data;
  logic pre_valid, pre_sof, pre_eol, pre_take;
  logic [7:0] pre_first_y, pre_y;
  logic signed [28:0] pre_cb, pre_cr;
  logic product_valid, product_sof, product_eol;
  logic matrix_valid, matrix_sof, matrix_eol;
  logic product_ready, matrix_ready, pair_ready;

  // Integer coefficients approximate BT.709 within one output code value.
  // Constant products may map into DSP blocks; signed 32 bits cover every sum.
  assign red = $signed({24'd0, in_data[23:16]});
  assign green = $signed({24'd0, in_data[7:0]});
  assign blue = $signed({24'd0, in_data[15:8]});
  // Offsets: Y +16*65536+32768 on yr; chroma +(64*131072+32768) on each pixel's red term.
  assign pair_cb = (29'(first_cb) + 29'(cb_q16)) >>> 17;
  assign pair_cr = (29'(first_cr) + 29'(cr_q16)) >>> 17;
  assign pre_take = pre_valid && (!m_axis_tvalid || m_axis_tready);
  assign pair_ready = (state == S_FIRST) || !pre_valid || pre_take;
  assign matrix_ready = !matrix_valid || pair_ready;
  assign product_ready = !product_valid || matrix_ready;
  assign in_ready = !in_valid || product_ready;
  assign s_axis_tready = resetn && in_ready;

  // Two elastic pixel stages keep multipliers separate from the matrix sums.
  // Signed 26-bit products cover the largest value, 255 * 40254 = 10264770.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      in_valid <= 1'b0; in_sof <= 1'b0; in_eol <= 1'b0; in_data <= '0;
      product_valid <= 1'b0;
      matrix_valid <= 1'b0;
      product_sof <= 1'b0;
      product_eol <= 1'b0;
      matrix_sof <= 1'b0;
      matrix_eol <= 1'b0;
      yr <= '0; yg <= '0; yb <= '0;
      cbr <= '0; cbg <= '0; cbb <= '0;
      crr <= '0; crg <= '0; crb <= '0;
      y_q16 <= '0; cb_q16 <= '0; cr_q16 <= '0;
    end else begin
      if (in_ready) begin
        in_valid <= s_axis_tvalid;
        if (s_axis_tvalid) begin
          in_data <= s_axis_tdata;
          in_sof <= s_axis_tuser;
          in_eol <= s_axis_tlast;
        end
      end
      if (product_ready) begin
        product_valid <= in_valid;
        if (in_valid) begin
          yr <= 11966 * red + 1081344; yg <= 40254 * green; yb <= 4064 * blue;
          cbr <= -6596 * red + 8421376; cbg <= -22189 * green; cbb <= 28784 * blue;
          crr <= 28784 * red + 8421376; crg <= -26145 * green; crb <= -2639 * blue;
          product_sof <= in_sof;
          product_eol <= in_eol;
        end
      end
      if (matrix_ready) begin
        matrix_valid <= product_valid;
        if (product_valid) begin
          y_q16 <= {{2{yr[25]}}, yr} + {{2{yg[25]}}, yg} + {{2{yb[25]}}, yb};
          cb_q16 <= {{2{cbr[25]}}, cbr} + {{2{cbg[25]}}, cbg} + {{2{cbb[25]}}, cbb};
          cr_q16 <= {{2{crr[25]}}, crr} + {{2{crg[25]}}, crg} + {{2{crb[25]}}, crb};
          matrix_sof <= product_sof;
          matrix_eol <= product_eol;
        end
      end
    end
  end

  // Saturation guards the limited-range output contract.
  function automatic logic [7:0] clip(input logic signed [28:0] value, input integer upper);
    if (value < 16) clip = 8'd16;
    else if (value > upper) clip = upper[7:0];
    else clip = value[7:0];
  endfunction

  // Pair ownership is independent of the pending output beat's ownership.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      state <= S_FIRST;
      first_y <= '0;
      first_cb <= '0;
      first_cr <= '0;
      first_sof <= 1'b0;
      m_axis_tdata <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tuser <= 1'b0;
      m_axis_tlast <= 1'b0;
      pre_valid <= 1'b0; pre_sof <= 1'b0; pre_eol <= 1'b0;
      pre_first_y <= '0; pre_y <= '0; pre_cb <= '0; pre_cr <= '0;
      format_error <= 1'b0;
    end else begin
      if (m_axis_tvalid && m_axis_tready) m_axis_tvalid <= 1'b0;
      if (pre_take) begin
        m_axis_tdata <= {clip(pre_cr, 240), pre_y, clip(pre_cb, 240), pre_first_y};
        m_axis_tvalid <= 1'b1;
        m_axis_tuser <= pre_sof;
        m_axis_tlast <= pre_eol;
        pre_valid <= 1'b0;
      end
      if (matrix_valid && pair_ready) begin
        if ((state == S_FIRST) || matrix_sof) begin
          if ((state == S_SECOND) || matrix_eol) format_error <= 1'b1;
          first_y <= clip(29'(y_q16) >>> 16, 235);
          first_cb <= cb_q16;
          first_cr <= cr_q16;
          first_sof <= matrix_sof;
          state <= matrix_eol ? S_FIRST : S_SECOND;
        end else begin
          pre_cb <= pair_cb;
          pre_cr <= pair_cr;
          pre_y <= clip(29'(y_q16) >>> 16, 235);
          pre_first_y <= first_y;
          pre_valid <= 1'b1;
          pre_sof <= first_sof;
          pre_eol <= matrix_eol;
          state <= S_FIRST;
        end
      end
    end
  end
endmodule
