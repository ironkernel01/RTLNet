// -----------------------------------------------------------------------------
// File: rtlnet_h264_rd_dma.sv
// Purpose: read DMA of the H.264 encoder: fetch a strip of up to NMB horizontally adjacent macroblocks of the input
//   frame (packed YUYV 4:2:2) with row bursts of an AXI4 master, convert them to 4:2:0 and write the 24 words of
//   each macroblock into its bank of the strip buffer.
// Overview:
//   * One start fetches one strip: 16 read bursts (INCR, 2 * n_mb beats of 16 bytes = n_mb pixel rows of 32 bytes,
//     128 bytes and 8 beats for the default 4 macroblocks), the first at mb_addr and each next one stride bytes higher.
//     mb_addr and stride are multiples of 32 * NMB and n_mb is at most NMB, so no burst crosses a 4 KiB boundary. All
//     16 reads are issued back to back; R beats are accepted at one per clock. A strip at the end of a macroblock row
//     may hold fewer than NMB macroblocks (n_mb); its bursts are shorter, but never a single beat.
//   * The beats of one burst are the same pixel row of macroblocks 0..n_mb-1, two beats per macroblock. Two beats make
//     one 32-byte row, fed to rtlnet_h264_c422to420 with the macroblock index; the converter holds the even row's chroma
//     per macroblock. Bank j of the strip starts at word dst_base + 32 * j and holds, as before: words 0..15 the luma
//     rows (pixel i in byte i); words 16..23 the chroma rows of the row pairs, U(0..7) in bytes 0..7 and V(0..7) in
//     bytes 8..15. The row number of each converted row travels with it through the converter latency.
//   * AXI_DATA_W (default 128): the width of the read data channel. With 64 a pixel row of 32 bytes takes four beats instead of two
//     (a burst is 4 * n_mb beats, at most 16, so NMB must be 2 or 4), the first three beats of a row are held and the fourth completes
//     the 256-bit row that goes to the converter; every other part and the bytes read from memory are unchanged. With 128 the
//     code is the original two-beat joiner (the registers of the 64-bit joiner are separate and do not exist then).
//   * done pulses in the clock after the last chroma word of the last macroblock is written; busy covers start to done.
//   * An R response other than OKAY pulses err_resp (the data is still consumed so the bus drains).
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: AXI_DATA_W parameter (128 default, 64).
//   * 11-09-2026: initial version (one macroblock per start, 2-beat bursts).
//   * 11-10-2026: strips of NMB macroblocks per row burst (burst-only DDR3 access).
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_rd_dma #(
  parameter int ADDR_W = 32,
  parameter int RAM_AW = 8,
  parameter int NMB    = 4,   // macroblocks per strip, 2, 4 or 8 (burst of 2 * NMB beats; 4 * NMB beats with AXI_DATA_W 64, so 2 or 4)
  parameter int AXI_DATA_W = 128 // width of the read data channel in bits: 128 or 64
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // Fetch command, clk domain: start pulses one clock when idle. mb_addr is the byte address of the first macroblock's
  // top-left pixel, stride the line pitch in bytes (both multiples of 32 * NMB), n_mb the macroblocks in the strip
  // (1..NMB), dst_base the strip-buffer word address of bank 0 of the strip.
  input  logic              start,
  input  logic [ADDR_W-1:0] mb_addr,
  input  logic [ADDR_W-1:0] stride,
  input  logic [3:0]        n_mb,
  input  logic [RAM_AW-1:0] dst_base,
  output logic              busy,
  output logic              done,

  // AXI4 read address channel, clk domain: INCR, 2 * n_mb beats of 16 bytes (4 * n_mb beats of 8 bytes with AXI_DATA_W 64).
  output logic [ADDR_W-1:0] araddr,
  output logic [7:0]        arlen,
  output logic [2:0]        arsize,
  output logic [1:0]        arburst,
  output logic              arvalid,
  input  logic              arready,

  // AXI4 read data channel, clk domain.
  input  logic [AXI_DATA_W-1:0] rdata,
  input  logic [1:0]        rresp,
  // rlast is not used: the beats of a row are counted by bb.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic              rlast,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              rvalid,
  output logic              rready,

  // Strip buffer write port, clk domain: one 16-byte word per wr_en clock.
  output logic              ram_wr_en,
  output logic [RAM_AW-1:0] ram_wr_addr,
  output logic [127:0]      ram_wr_data,

  // Pulse when an R beat returns a response other than OKAY.
  output logic              err_resp
);

  localparam int ROWS         = 16;
  localparam int CHROMA_BASE  = 16;
  localparam int BANK_WORDS   = 32;
  localparam int MI           = $clog2(NMB);
  localparam bit NARROW       = (AXI_DATA_W == 64);

  generate
    if (NMB != 2 && NMB != 4 && NMB != 8) begin : g_bad_nmb
      $fatal(1, "rtlnet_h264_rd_dma: NMB=%0d, must be 2, 4 or 8", NMB);
    end
    if (AXI_DATA_W != 128 && AXI_DATA_W != 64) begin : g_bad_width
      $fatal(1, "rtlnet_h264_rd_dma: AXI_DATA_W=%0d, must be 128 or 64", AXI_DATA_W);
    end
    if (AXI_DATA_W == 64 && NMB == 8) begin : g_bad_nmb64
      $fatal(1, "rtlnet_h264_rd_dma: NMB=8 gives 32-beat bursts with AXI_DATA_W 64 (AXI3 limit 16); use NMB 2 or 4");
    end
  endgenerate

  logic [ADDR_W-1:0] stride_q;
  logic [RAM_AW-1:0] base_q;
  logic [3:0]        n_q;
  logic [7:0]        len_q;
  logic [4:0]        ar_cnt;
  logic [4:0]        bb;
  logic [3:0]        r_row;
  logic [127:0]      beat0;
  logic              cv_valid;
  logic              cv_odd;
  logic [MI-1:0]     cv_mb;
  logic [255:0]      cv_data;
  logic [3:0]        cv_row;
  logic [3:0]        row_d1;
  logic [2:0]        row_d2;   // pair index of the row (row / 2)
  logic              y_valid;
  logic [MI-1:0]     y_mb;
  logic [127:0]      y_data;
  logic              c_valid;
  logic [MI-1:0]     c_mb;
  logic [127:0]      c_data;
  logic [6:0]        c_cnt;
  logic [6:0]        c_total;
  logic              fin;
  logic [RAM_AW-1:0] y_waddr;
  logic [RAM_AW-1:0] c_waddr;
  // 64-bit bus: the row registers of the joiner of four beats (constant 0 with 128 bits, where cv_* above are the joiner of two beats).
  logic              cv64_valid;
  logic              cv64_odd;
  logic [MI-1:0]     cv64_mb;
  logic [255:0]      cv64_data;
  logic [3:0]        cv64_row;
  logic              cv_valid_c;
  logic              cv_odd_c;
  logic [MI-1:0]     cv_mb_c;
  logic [255:0]      cv_data_c;
  logic [3:0]        cv_row_c;
  assign cv_valid_c = NARROW ? cv64_valid : cv_valid;
  assign cv_odd_c   = NARROW ? cv64_odd   : cv_odd;
  assign cv_mb_c    = NARROW ? cv64_mb    : cv_mb;
  assign cv_data_c  = NARROW ? cv64_data  : cv_data;
  assign cv_row_c   = NARROW ? cv64_row   : cv_row;

  assign arlen   = len_q;
  assign arsize  = 3'(NARROW ? 3 : 4);
  assign arburst = 2'b01;
  assign rready  = busy;

  rtlnet_h264_c422to420 #(.NMB(NMB)) u_conv (
    .clk(clk), .resetn(resetn),
    .in_valid(cv_valid_c), .in_odd(cv_odd_c), .in_mb(cv_mb_c), .in_data(cv_data_c),
    .y_valid(y_valid), .y_mb(y_mb), .y_data(y_data), .c_valid(c_valid), .c_mb(c_mb), .c_data(c_data)
  );

  assign y_waddr     = base_q + RAM_AW'(BANK_WORDS * int'(y_mb)) + RAM_AW'(row_d1);
  assign c_waddr     = base_q + RAM_AW'(BANK_WORDS * int'(c_mb)) + RAM_AW'(CHROMA_BASE) + RAM_AW'(row_d2);
  assign ram_wr_en   = y_valid || c_valid;
  assign ram_wr_addr = c_valid ? c_waddr : y_waddr;
  assign ram_wr_data = c_valid ? c_data : y_data;
  assign err_resp    = busy && rvalid && (rresp != 2'b00);
  assign c_total     = {n_q[3:0], 3'b000};

  // 64-bit bus: four beats make one 32-byte pixel row for the converter (the first three are held in acc). With 128 bits no logic exists here and
  // the joiner of two beats is in the main block below, as before.
  generate
    if (NARROW) begin : g_join64
      logic [191:0] acc;
      always_ff @(posedge clk) begin
        if (!resetn) begin
          acc        <= '0;
          cv64_valid <= 1'b0;
          cv64_odd   <= 1'b0;
          cv64_mb    <= '0;
          cv64_row   <= '0;
          cv64_data  <= '0;
        end else begin
          cv64_valid <= 1'b0;
          if (busy && rvalid) begin
            acc <= {rdata, acc[191:64]};
            if (bb[1:0] == 2'd3) begin
              cv64_valid <= 1'b1;
              cv64_odd   <= r_row[0];
              cv64_mb    <= MI'(bb[4:2]);
              cv64_row   <= r_row;
              cv64_data  <= {rdata, acc};
            end
          end
        end
      end
    end else begin : g_no_join64
      assign cv64_valid = 1'b0;
      assign cv64_odd   = 1'b0;
      assign cv64_mb    = '0;
      assign cv64_row   = '0;
      assign cv64_data  = '0;
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!resetn) begin
      busy     <= 1'b0;
      done     <= 1'b0;
      fin      <= 1'b0;
      araddr   <= '0;
      arvalid  <= 1'b0;
      stride_q <= '0;
      base_q   <= '0;
      n_q      <= '0;
      len_q    <= '0;
      ar_cnt   <= '0;
      bb       <= '0;
      beat0    <= '0;
      r_row    <= '0;
      cv_valid <= 1'b0;
      cv_odd   <= 1'b0;
      cv_mb    <= '0;
      cv_row   <= '0;
      cv_data  <= '0;
      row_d1   <= '0;
      row_d2   <= '0;
      c_cnt    <= '0;
    end else begin
      done     <= 1'b0;
      cv_valid <= 1'b0;
      row_d1   <= cv_row_c;
      row_d2   <= row_d1[3:1];
      if (start && !busy) begin
        busy     <= 1'b1;
        fin      <= 1'b0;
        araddr   <= mb_addr;
        arvalid  <= 1'b1;
        stride_q <= stride;
        base_q   <= dst_base;
        n_q      <= n_mb;
        len_q    <= NARROW ? ({2'd0, n_mb, 2'b00} - 8'd1) : ({3'd0, n_mb, 1'b0} - 8'd1);
        ar_cnt   <= '0;
        bb       <= '0;
        r_row    <= '0;
        c_cnt    <= '0;
      end
      if (arvalid && arready) begin
        ar_cnt <= ar_cnt + 5'd1;
        if (ar_cnt == 5'(ROWS - 1)) begin
          arvalid <= 1'b0;
        end else begin
          araddr <= araddr + stride_q;
        end
      end
      if (busy && rvalid) begin
        if (!NARROW) begin
          if (!bb[0]) begin
            beat0 <= 128'(rdata);
          end else begin
            cv_valid <= 1'b1;
            cv_odd   <= r_row[0];
            cv_mb    <= MI'(bb[4:1]);
            cv_row   <= r_row;
            cv_data  <= {128'(rdata), beat0};
          end
        end
        if (bb == (NARROW ? 5'({n_q, 2'b00} - 6'd1) : 5'({n_q, 1'b0} - 5'd1))) begin
          bb    <= '0;
          r_row <= r_row + 4'd1;
        end else begin
          bb <= bb + 5'd1;
        end
      end
      if (c_valid) begin
        c_cnt <= c_cnt + 7'd1;
        if (c_cnt == (c_total - 7'd1)) fin <= 1'b1;
      end
      if (fin) begin
        fin  <= 1'b0;
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

endmodule
