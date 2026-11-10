// -----------------------------------------------------------------------------
// File: rtlnet_h264_ref_dma.sv
// Purpose: read DMA of the reference macroblock of a P picture: the co-located macroblock of the reference picture's rebuilt
//   tiles (documentation section 7) into a bank of the reference macroblock buffer.
// Overview:
//   * One start fetches one macroblock: one 16-beat burst for the luma tile (y_addr, 256 bytes) and one 8-beat burst for the
//     chroma tile (c_addr, 128 bytes: Cb 8 x 8 then Cr 8 x 8), INCR, 16 bytes per beat, so neither crosses 4 KiB (the tile
//     bases are multiples of the tile sizes) and neither is shorter than 8 beats. Both read addresses are issued back to back.
//   * The 24 beats are written to the buffer in order: words dst_base + 0..15 the luma rows (row y at word y, pixel i in byte
//     i), words dst_base + 16..23 the chroma tile as stored (word 16 + k: Cb rows 2k and 2k + 1; word 20 + k: Cr rows 2k and
//     2k + 1, each row 8 bytes, the even row in the low 8 bytes). The tile layout is the one rtlnet_h264_recon_wr writes.
//   * done pulses in the clock after the last beat is written; busy covers start to done. The R channel is taken only while
//     busy: the caller keeps it away from other readers meanwhile (the engine starts the input strip DMA and this DMA one at a
//     time, so the R beats are never mixed). An R response other than OKAY pulses err_resp (the data is still consumed).
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-1).
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_ref_dma #(
  parameter int ADDR_W = 32,
  parameter int RAM_AW = 6
)(
  input  logic              clk,
  input  logic              resetn,

  input  logic              start,
  input  logic [ADDR_W-1:0] y_addr,
  input  logic [ADDR_W-1:0] c_addr,
  input  logic [RAM_AW-1:0] dst_base,
  output logic              busy,
  output logic              done,

  output logic [ADDR_W-1:0] araddr,
  output logic [7:0]        arlen,
  output logic [2:0]        arsize,
  output logic [1:0]        arburst,
  output logic              arvalid,
  input  logic              arready,

  input  logic [127:0]      rdata,
  input  logic [1:0]        rresp,
  // rlast is not used: the beats are counted.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic              rlast,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              rvalid,
  output logic              rready,

  output logic              ram_wr_en,
  output logic [RAM_AW-1:0] ram_wr_addr,
  output logic [127:0]      ram_wr_data,

  output logic              err_resp
);

  localparam int LUMA_BEATS   = 16;
  localparam int CHROMA_BEATS = 8;

  logic [ADDR_W-1:0] c_q;
  logic              first_ar;     // the luma address has been accepted, the chroma address follows
  logic [RAM_AW-1:0] base_q;
  logic [4:0]        beat;
  logic              fin;

  assign arsize  = 3'd4;
  assign arburst = 2'b01;
  assign rready  = busy;
  assign err_resp = busy && rvalid && (rresp != 2'b00);
  assign ram_wr_en   = busy && rvalid;
  assign ram_wr_addr = base_q + RAM_AW'(beat);
  assign ram_wr_data = rdata;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      busy     <= 1'b0;
      done     <= 1'b0;
      fin      <= 1'b0;
      arvalid  <= 1'b0;
      araddr   <= '0;
      arlen    <= '0;
      c_q      <= '0;
      first_ar <= 1'b0;
      base_q   <= '0;
      beat     <= '0;
    end else begin
      done <= 1'b0;
      if (start && !busy) begin
        busy     <= 1'b1;
        fin      <= 1'b0;
        arvalid  <= 1'b1;
        araddr   <= y_addr;
        arlen    <= 8'(LUMA_BEATS - 1);
        c_q      <= c_addr;
        first_ar <= 1'b0;
        base_q   <= dst_base;
        beat     <= '0;
      end
      if (arvalid && arready) begin
        if (!first_ar) begin
          first_ar <= 1'b1;
          araddr   <= c_q;
          arlen    <= 8'(CHROMA_BEATS - 1);
        end else begin
          arvalid <= 1'b0;
        end
      end
      if (busy && rvalid) begin
        if (beat == 5'(LUMA_BEATS + CHROMA_BEATS - 1)) begin
          fin <= 1'b1;
        end else begin
          beat <= beat + 5'd1;
        end
      end
      if (fin) begin
        fin  <= 1'b0;
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

endmodule
