// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_cdc.sv
// Purpose: asynchronous FIFO from the byte clock to the core clock for the pixel entries of the CSI-2 receiver. The writer cannot be
//   stalled (the camera sends at its own rate): an entry that finds the FIFO full is dropped and counted.
// Overview:
//   * Storage is one rtlnet_ram_core (RAM_STYLE "block" default or "distributed"), FIFO_KB kilobytes counted as 8-byte words
//     (depth = FIFO_KB * 128 entries, a power of two); an entry is ENT_W = 46 bits wide.
//   * The write and read pointers are binary counters of ADDR_W + 1 bits; each crosses through rtlnet_gray_sync (Gray code, step of one
//     per clock). Full is computed in the write clock from the synchronized read pointer and empty in the read clock from the
//     synchronized write pointer, so both flags err on the safe side.
//   * Read side: first-word style output with registered data: m_valid with m_data until m_ready takes it; the RAM read of the next entry
//     is issued in the clock the present entry is taken.
//   * ev_overflow is a one-clock pulse in the write clock, one per dropped entry.
//   * Both sides reset together: derive w_resetn and r_resetn from one assertion (rtlnet_csi2_rx does, from the system reset and
//     the soft reset). Neither side may be reset alone.
//   * Instance names: scripts/rtlnet_constrain_cdc.tcl bounds the Gray crossings of rtlnet_gray_sync instances.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// Clocks: w_clk (write, byte clock), r_clk (read, core clock); any frequencies. Crossings: wptr w_clk->r_clk and rptr r_clk->w_clk
//   (rtlnet_gray_sync).
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_cdc
  import rtlnet_csi2_rx_pkg::*;
#(
  parameter string RAM_STYLE = "block",     // "block" | "distributed"
  parameter int    FIFO_KB   = 4            // storage in kilobytes of 8-byte words
)(
  // Write side.
  input  logic             w_clk,
  input  logic             w_resetn,
  input  logic             w_valid,
  input  logic [ENT_W-1:0] w_data,
  output logic             ev_overflow,

  // Read side.
  input  logic             r_clk,
  input  logic             r_resetn,
  output logic             m_valid,
  output logic [ENT_W-1:0] m_data,
  input  logic             m_ready
);

  localparam int DEPTH  = FIFO_KB * 128;
  localparam int ADDR_W = $clog2(DEPTH);
  localparam int PTR_W  = ADDR_W + 1;

  generate
    if ((DEPTH & (DEPTH - 1)) != 0 || DEPTH < 4) begin : g_bad_size
      $fatal(1, "rtlnet_csi2_rx_cdc: FIFO_KB=%0d gives depth %0d, which must be a power of two of at least 4", FIFO_KB, DEPTH);
    end
  endgenerate

  logic [PTR_W-1:0]  wptr, wptr_r;
  logic [PTR_W-1:0]  rptr, rptr_w;
  logic              full;
  logic              wr;
  logic              avail;
  logic              issue;
  logic [ENT_W-1:0]  ram_q;

  // ---------------------------------------------------------------------------
  // Write side
  // ---------------------------------------------------------------------------
  assign full = ((wptr - rptr_w) >= PTR_W'(DEPTH));
  assign wr   = w_valid && !full;

  always_ff @(posedge w_clk) begin
    if (!w_resetn) begin
      wptr        <= '0;
      ev_overflow <= 1'b0;
    end else begin
      ev_overflow <= w_valid && full;
      if (wr) wptr <= wptr + PTR_W'(1);
    end
  end

  rtlnet_gray_sync #(.WIDTH(PTR_W), .STAGES(2)) u_wptr_gray (
    .src_clk(w_clk), .src_resetn(w_resetn), .src_count(wptr),
    .dst_clk(r_clk), .dst_resetn(r_resetn), .dst_count(wptr_r)
  );

  // ---------------------------------------------------------------------------
  // Read side
  // ---------------------------------------------------------------------------
  assign avail = (wptr_r != rptr);
  assign issue = avail && (!m_valid || m_ready);

  always_ff @(posedge r_clk) begin
    if (!r_resetn) begin
      rptr    <= '0;
      m_valid <= 1'b0;
    end else begin
      if (issue) begin
        rptr    <= rptr + PTR_W'(1);
        m_valid <= 1'b1;
      end else if (m_valid && m_ready) begin
        m_valid <= 1'b0;
      end
    end
  end

  rtlnet_gray_sync #(.WIDTH(PTR_W), .STAGES(2)) u_rptr_gray (
    .src_clk(r_clk), .src_resetn(r_resetn), .src_count(rptr),
    .dst_clk(w_clk), .dst_resetn(w_resetn), .dst_count(rptr_w)
  );

  rtlnet_ram_core #(
    .RAM_STYLE(RAM_STYLE), .CLOCKING("INDEPENDENT"), .DATA_W(ENT_W), .ADDR_W(ADDR_W), .READ_LATENCY(1)
  ) u_ram (
    .wr_clk(w_clk), .wr_en(wr), .wr_addr(wptr[ADDR_W-1:0]), .wr_data(w_data),
    .rd_clk(r_clk), .rd_resetn(r_resetn), .rd_en(issue), .rd_addr(rptr[ADDR_W-1:0]), .rd_data(ram_q)
  );

  assign m_data = ram_q;

endmodule
