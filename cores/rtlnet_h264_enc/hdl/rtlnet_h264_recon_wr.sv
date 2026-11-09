// -----------------------------------------------------------------------------
// File: rtlnet_h264_recon_wr.sv
// Purpose: write one macroblock of the rebuilt 4:2:0 picture (luma plane, Cb plane, Cr plane) through
//   the write DMA path. For I_PCM the rebuilt macroblock is the macroblock buffer content; phase 2b-2
//   feeds the rebuild loop's result through the same request interface.
// Overview:
//   * 32 single-beat writes per macroblock, each a request on the write master: 16 luma rows (16 bytes,
//     full strobe), 8 Cb rows and 8 Cr rows (8 bytes each, placed in the low or high half of the 16-byte
//     word by address bit 3 with an 8-bit strobe). The word address is the row address with bits [3:0] clear.
//   * Row addresses start at y_addr, u_addr, v_addr (byte address of the macroblock's top-left sample in
//     each plane) and advance by y_stride / c_stride per row. y_stride, c_stride and the base addresses
//     are multiples of 16, so the half of a chroma row is the same for all 8 rows.
//   * Per row: read the macroblock buffer word, then hold a request (req_valid with address, data and
//     strobe stable) until the master pulses req_ack.
//   * start pulses one clock when idle; done pulses after the last request is acknowledged.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_recon_wr #(
  parameter int ADDR_W = 32,
  parameter int RAM_AW = 6
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // Macroblock command, clk domain: base is the macroblock-buffer word address of the bank.
  input  logic              start,
  input  logic [RAM_AW-1:0] base,
  input  logic [ADDR_W-1:0] y_addr,
  input  logic [ADDR_W-1:0] u_addr,
  input  logic [ADDR_W-1:0] v_addr,
  input  logic [ADDR_W-1:0] y_stride,
  input  logic [ADDR_W-1:0] c_stride,
  output logic              busy,
  output logic              done,

  // Macroblock buffer read port, clk domain: ram_rd_data is valid the clock after ram_rd_en.
  output logic              ram_rd_en,
  output logic [RAM_AW-1:0] ram_rd_addr,
  input  logic [127:0]      ram_rd_data,

  // Single-beat write request to the write master, clk domain: fields are stable while req_valid is high;
  // req_ack pulses in the clock the master takes the request.
  output logic              req_valid,
  output logic [ADDR_W-1:0] req_addr,
  output logic [127:0]      req_data,
  output logic [15:0]       req_strb,
  input  logic              req_ack
);

  localparam logic [1:0] S_IDLE = 2'd0;
  localparam logic [1:0] S_RD   = 2'd1;
  localparam logic [1:0] S_RD2  = 2'd2;
  localparam logic [1:0] S_REQ  = 2'd3;

  localparam int ROWS_Y   = 16;
  localparam int ROWS_CB  = 24;
  localparam int ROWS_ALL = 32;

  logic [1:0]        st;
  logic [RAM_AW-1:0] base_q;
  logic [4:0]        r;
  logic [ADDR_W-1:0] ay;
  logic [ADDR_W-1:0] au;
  logic [ADDR_W-1:0] av;
  logic [ADDR_W-1:0] ys_q;
  logic [ADDR_W-1:0] cs_q;
  // Bits [2:0] of the row address are not used: rows are 8-byte aligned and only bit 3 selects the half.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [ADDR_W-1:0] row_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [63:0]       half_data;
  logic              half_hi;
  logic              is_luma;
  logic              is_cr;

  assign is_luma  = (r < 5'(ROWS_Y));
  assign is_cr    = (r >= 5'(ROWS_CB));
  assign row_addr = is_luma ? ay : (is_cr ? av : au);
  assign half_hi  = row_addr[3];
  assign half_data = is_cr ? ram_rd_data[127:64] : ram_rd_data[63:0];

  assign busy        = (st != S_IDLE);
  assign ram_rd_en   = (st == S_RD);
  assign ram_rd_addr = base_q + RAM_AW'(is_cr ? (r - 5'd8) : r);

  assign req_valid = (st == S_REQ);
  assign req_addr  = {row_addr[ADDR_W-1:4], 4'b0000};
  assign req_data  = is_luma ? ram_rd_data : (half_hi ? {half_data, 64'd0} : {64'd0, half_data});
  assign req_strb  = is_luma ? 16'hFFFF : (half_hi ? 16'hFF00 : 16'h00FF);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      st     <= S_IDLE;
      base_q <= '0;
      r      <= '0;
      ay     <= '0;
      au     <= '0;
      av     <= '0;
      ys_q   <= '0;
      cs_q   <= '0;
      done   <= 1'b0;
    end else begin
      done <= 1'b0;
      case (st)
        S_IDLE: begin
          if (start) begin
            base_q <= base;
            r      <= '0;
            ay     <= y_addr;
            au     <= u_addr;
            av     <= v_addr;
            ys_q   <= y_stride;
            cs_q   <= c_stride;
            st     <= S_RD;
          end
        end
        S_RD: begin
          st <= S_RD2;
        end
        S_RD2: begin
          st <= S_REQ;
        end
        S_REQ: begin
          if (req_ack) begin
            if (is_luma) ay <= ay + ys_q;
            else if (is_cr) av <= av + cs_q;
            else au <= au + cs_q;
            if (r == 5'(ROWS_ALL - 1)) begin
              st   <= S_IDLE;
              done <= 1'b1;
            end else begin
              r  <= r + 5'd1;
              st <= S_RD;
            end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
