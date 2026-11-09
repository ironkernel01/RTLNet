// -----------------------------------------------------------------------------
// File: rtlnet_h264_rd_dma.sv
// Purpose: read DMA of the H.264 encoder: fetch the 16 pixel rows of one macroblock from the input
//   frame (packed YUYV 4:2:2) with an AXI4 master, convert them to 4:2:0 and write the 24 words of
//   the macroblock buffer.
// Overview:
//   * One start fetches one macroblock: 16 read bursts (INCR, 2 beats of 16 bytes = one 32-byte pixel
//     row), the first at mb_addr and each next one stride bytes higher. mb_addr and stride are multiples
//     of 32, so no burst crosses a 4 KiB boundary. All 16 reads are issued back to back; R beats are
//     accepted at one per clock.
//   * Two beats make one row, fed to rtlnet_h264_c422to420. Macroblock buffer words (16 bytes each),
//     relative to dst_base: words 0..15 the luma rows (pixel i in byte i); words 16..23 the chroma rows
//     of the row pairs, U(0..7) in bytes 0..7 and V(0..7) in bytes 8..15.
//   * done pulses in the clock after the last chroma word is written; busy covers start to done.
//   * An R response other than OKAY pulses err_resp (the data is still consumed so the bus drains).
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_rd_dma #(
  parameter int ADDR_W = 32,
  parameter int RAM_AW = 6
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // Fetch command, clk domain: start pulses one clock when idle. mb_addr is the byte address of the
  // macroblock's top-left pixel, stride the line pitch in bytes (both multiples of 32), dst_base the
  // macroblock-buffer word address of the destination.
  input  logic              start,
  input  logic [ADDR_W-1:0] mb_addr,
  input  logic [ADDR_W-1:0] stride,
  input  logic [RAM_AW-1:0] dst_base,
  output logic              busy,
  output logic              done,

  // AXI4 read address channel, clk domain: INCR, 2 beats, 16 bytes per beat.
  output logic [ADDR_W-1:0] araddr,
  output logic [7:0]        arlen,
  output logic [2:0]        arsize,
  output logic [1:0]        arburst,
  output logic              arvalid,
  input  logic              arready,

  // AXI4 read data channel, clk domain.
  input  logic [127:0]      rdata,
  input  logic [1:0]        rresp,
  // rlast is not used: the two beats of a row are counted by r_beat.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic              rlast,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              rvalid,
  output logic              rready,

  // Macroblock buffer write port, clk domain: one 16-byte word per wr_en clock.
  output logic              ram_wr_en,
  output logic [RAM_AW-1:0] ram_wr_addr,
  output logic [127:0]      ram_wr_data,

  // Pulse when an R beat returns a response other than OKAY.
  output logic              err_resp
);

  localparam int ROWS         = 16;
  localparam int CHROMA_ROWS  = 8;
  localparam int CHROMA_BASE  = 16;

  logic [ADDR_W-1:0] stride_q;
  logic [RAM_AW-1:0] base_q;
  logic [4:0]        ar_cnt;
  logic              r_beat;
  logic [127:0]      beat0;
  logic [3:0]        r_row;
  logic              cv_valid;
  logic              cv_odd;
  logic [255:0]      cv_data;
  logic [3:0]        y_cnt;
  logic [3:0]        c_cnt;
  logic              y_valid;
  logic [127:0]      y_data;
  logic              c_valid;
  logic [127:0]      c_data;
  logic              fin;

  assign arlen   = 8'd1;
  assign arsize  = 3'd4;
  assign arburst = 2'b01;
  assign rready  = busy;

  rtlnet_h264_c422to420 u_conv (
    .clk(clk), .resetn(resetn),
    .in_valid(cv_valid), .in_odd(cv_odd), .in_data(cv_data),
    .y_valid(y_valid), .y_data(y_data), .c_valid(c_valid), .c_data(c_data)
  );

  assign ram_wr_en   = y_valid || c_valid;
  assign ram_wr_addr = c_valid ? (base_q + RAM_AW'(CHROMA_BASE) + RAM_AW'(c_cnt)) : (base_q + RAM_AW'(y_cnt));
  assign ram_wr_data = c_valid ? c_data : y_data;
  assign err_resp    = busy && rvalid && (rresp != 2'b00);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      busy     <= 1'b0;
      done     <= 1'b0;
      fin      <= 1'b0;
      araddr   <= '0;
      arvalid  <= 1'b0;
      stride_q <= '0;
      base_q   <= '0;
      ar_cnt   <= '0;
      r_beat   <= 1'b0;
      beat0    <= '0;
      r_row    <= '0;
      cv_valid <= 1'b0;
      cv_odd   <= 1'b0;
      cv_data  <= '0;
      y_cnt    <= '0;
      c_cnt    <= '0;
    end else begin
      done     <= 1'b0;
      cv_valid <= 1'b0;
      if (start && !busy) begin
        busy     <= 1'b1;
        fin      <= 1'b0;
        araddr   <= mb_addr;
        arvalid  <= 1'b1;
        stride_q <= stride;
        base_q   <= dst_base;
        ar_cnt   <= '0;
        r_beat   <= 1'b0;
        r_row    <= '0;
        y_cnt    <= '0;
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
        if (!r_beat) begin
          beat0  <= rdata;
          r_beat <= 1'b1;
        end else begin
          r_beat   <= 1'b0;
          cv_valid <= 1'b1;
          cv_odd   <= r_row[0];
          cv_data  <= {rdata, beat0};
          r_row    <= r_row + 4'd1;
        end
      end
      if (y_valid) y_cnt <= y_cnt + 4'd1;
      if (c_valid) begin
        c_cnt <= c_cnt + 4'd1;
        if (c_cnt == 4'(CHROMA_ROWS - 1)) fin <= 1'b1;
      end
      if (fin) begin
        fin  <= 1'b0;
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

endmodule
