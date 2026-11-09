// -----------------------------------------------------------------------------
// File: rtlnet_h264_mb_pcm.sv
// Purpose: macroblock coder of phase 2b-1: writes one I_PCM macroblock layer (clause 7.3.5) from a
//   macroblock buffer bank into the bit packer. The intra prediction, transform and CAVLC coder of
//   phase 2b-2 replace this module behind the same start/done and packer-command interface.
// Overview:
//   * Syntax emitted per macroblock in an I slice with entropy_coding_mode_flag 0:
//       mb_type            ue(v) = 25 (I_PCM, Table 7-11)
//       pcm_alignment_zero_bit  zeros up to the byte boundary
//       pcm_sample_luma[256]    8 bits each, raster order
//       pcm_sample_chroma[128]  8 bits each, 64 Cb samples then 64 Cr samples, raster order
//     No other syntax element follows (I_PCM carries no mb_qp_delta or coded_block_pattern). A
//     pcm sample value of 0 is allowed (clause 7.4.5); emulation prevention in the packer protects it.
//   * The 384 sample bytes leave at one packer command per clock. The macroblock buffer words (see
//     rtlnet_h264_rd_dma) are read 32 groups: 16 luma words of 16 bytes, 8 words' low halves (Cb rows)
//     and 8 words' high halves (Cr rows). The next group's word is prefetched during the current group.
//   * start pulses one clock when idle; done pulses when the last sample command is accepted.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_mb_pcm #(
  parameter int RAM_AW = 6
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // Macroblock command, clk domain: base is the macroblock-buffer word address of the bank to code.
  input  logic              start,
  input  logic [RAM_AW-1:0] base,
  output logic              busy,
  output logic              done,

  // Macroblock buffer read port, clk domain: ram_rd_data is valid the clock after ram_rd_en.
  output logic              ram_rd_en,
  output logic [RAM_AW-1:0] ram_rd_addr,
  input  logic [127:0]      ram_rd_data,

  // Bit-packer command output, clk domain.
  output logic              cmd_valid,
  input  logic              cmd_ready,
  output logic [2:0]        cmd_op,
  output logic [31:0]       cmd_val,
  output logic [5:0]        cmd_len
);

  import rtlnet_h264_pkg::*;

  localparam logic [2:0] S_IDLE  = 3'd0;
  localparam logic [2:0] S_UE    = 3'd1;
  localparam logic [2:0] S_ALIGN = 3'd2;
  localparam logic [2:0] S_PRE   = 3'd3;
  localparam logic [2:0] S_PRE2  = 3'd4;
  localparam logic [2:0] S_RUN   = 3'd5;

  localparam int GROUPS      = 32;
  localparam int LUMA_GROUPS = 16;
  localparam int CB_GROUPS   = 24;

  logic [2:0]        st;
  logic [RAM_AW-1:0] base_q;
  logic [4:0]        g;
  logic [3:0]        j;
  logic [127:0]      cur;
  logic [127:0]      nxt;
  logic              pf;
  logic              rd_q;
  logic [4:0]        g_next;
  logic [4:0]        g_next_word;
  logic [3:0]        g_off;
  logic [4:0]        g_nb;
  logic [3:0]        byte_idx;

  // Group g reads word g (luma), word g (Cb rows, low half) or word g - 8 (Cr rows, high half).
  assign g_next      = g + 5'd1;
  assign g_next_word = (g_next >= 5'(CB_GROUPS)) ? (g_next - 5'd8) : g_next;
  assign g_off       = (g >= 5'(CB_GROUPS)) ? 4'd8 : 4'd0;
  assign g_nb        = (g < 5'(LUMA_GROUPS)) ? 5'd16 : 5'd8;
  assign byte_idx    = g_off + j;

  assign busy        = (st != S_IDLE);
  assign ram_rd_en   = (st == S_PRE) || ((st == S_RUN) && !pf && (g != 5'(GROUPS - 1)));
  assign ram_rd_addr = (st == S_PRE) ? base_q : (base_q + RAM_AW'(g_next_word));

  always_comb begin
    cmd_valid = 1'b0;
    cmd_op    = PK_FIELD;
    cmd_val   = '0;
    cmd_len   = 6'd8;
    case (st)
      S_UE: begin
        cmd_valid = 1'b1;
        cmd_op    = PK_UE;
        cmd_val   = MB_TYPE_I_PCM;
        cmd_len   = 6'd0;
      end
      S_ALIGN: begin
        cmd_valid = 1'b1;
        cmd_op    = PK_ALIGN;
        cmd_len   = 6'd0;
      end
      S_RUN: begin
        cmd_valid = 1'b1;
        cmd_op    = PK_FIELD;
        cmd_val   = {24'd0, cur[8*byte_idx +: 8]};
        cmd_len   = 6'd8;
      end
      default: begin
        cmd_valid = 1'b0;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      st     <= S_IDLE;
      base_q <= '0;
      g      <= '0;
      j      <= '0;
      cur    <= '0;
      nxt    <= '0;
      pf     <= 1'b0;
      rd_q   <= 1'b0;
      done   <= 1'b0;
    end else begin
      done <= 1'b0;
      rd_q <= ram_rd_en;
      if (rd_q) nxt <= ram_rd_data;
      case (st)
        S_IDLE: begin
          if (start) begin
            base_q <= base;
            st     <= S_UE;
          end
        end
        S_UE: begin
          if (cmd_ready) st <= S_ALIGN;
        end
        S_ALIGN: begin
          if (cmd_ready) st <= S_PRE;
        end
        S_PRE: begin
          st <= S_PRE2;
        end
        S_PRE2: begin
          cur <= ram_rd_data;
          g   <= '0;
          j   <= '0;
          pf  <= 1'b0;
          st  <= S_RUN;
        end
        S_RUN: begin
          if (ram_rd_en) pf <= 1'b1;
          if (cmd_ready) begin
            if ({1'b0, j} == (g_nb - 5'd1)) begin
              j  <= '0;
              pf <= 1'b0;
              if (g == 5'(GROUPS - 1)) begin
                st   <= S_IDLE;
                done <= 1'b1;
              end else begin
                g   <= g_next;
                cur <= nxt;
              end
            end else begin
              j <= j + 4'd1;
            end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
