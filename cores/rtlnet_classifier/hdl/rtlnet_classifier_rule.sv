// -----------------------------------------------------------------------------
// File: rtlnet_classifier_rule.sv
// Purpose: one positional rule engine of rtlnet_classifier: judges frame
//   bytes 0..MATCH_BYTES-1 by position, each byte with its own mask,
//   operator and compare value, as the beats enter the delay line.
// Overview:
//   * Compare buffer: entry b = {MASK[7:0], OP[3:0], COMPARE[7:0]} for frame
//     byte b; eight lanes (b mod 8), each an rtlnet_ram_core of
//     MATCH_BEATS words (READ_LATENCY 2, COMMON clock), word = beat index.
//     Register window 0xC00 + RULE_STRIDE r + 4 b (the register word holds
//     COMPARE in [7:0], OP in [11:8], MASK in [31:24]).
//   * Byte ALU: (byte & MASK) OP (COMPARE & MASK) with OP 1000 ==, 1001 !=,
//     1010 <, 1011 >, 1100 <=, 1101 >=, any other code don't-care (passes).
//     An absent byte (beyond the frame's last byte) passes only don't-care.
//   * Frame: the rule matches when every byte 0..MATCH_BYTES-1 passes. Bytes
//     of beats the frame never sends are covered by a per-byte don't-care
//     bit vector kept beside the buffer (written with each entry): the
//     suffix AND over whole beats is registered (it settles MATCH_BEATS
//     clocks after a write, while the rule is disabled by the driver's
//     update protocol), and the value for "frame ends after beat k" travels
//     with the frame in a shift register loaded at its first beat.
//   * Timing: buffer read issued from the tap (2), mask (1), compare (1,
//     8-bit carry), operator (1), 8-byte AND (1), frame accumulate (1):
//     RULE_STAGES registers from the tap to r_match/r_done.
//   * r_match holds the last judged frame's result; r_done pulses with it.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (axis_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_classifier_rule #(
  parameter int    RULE_IDX     = 0,       // rule index r
  parameter int    MATCH_BEATS  = 8,       // MATCH_DEPTH_BYTES / 8, 5..32
  parameter int    IDX_W        = 6,       // tap_idx width
  parameter int    STRIDE_WORDS = 64,      // RULE_STRIDE / 4, power of two >= 8 MATCH_BEATS
  parameter string RAM_STYLE    = "block"
)(
  // Stream clock and synchronous active-low reset.
  input  logic             clk,
  input  logic             resetn,

  // Configuration write bus from the register file (registered).
  input  logic             cw_en,
  input  logic [9:0]       cw_addr,
  input  logic [31:0]      cw_data,
  input  logic             clr_active,
  input  logic [9:0]       clr_addr,

  // Engine tap from the delay line.
  input  logic             tap_valid,
  input  logic [63:0]      tap_data,
  input  logic [7:0]       tap_keep,
  input  logic [IDX_W-1:0] tap_idx,
  input  logic             tap_first,
  input  logic             tap_judge,

  // Result of the last judged frame (raw match, before EXCLUDE).
  output logic             r_match,
  output logic             r_done
);

  import rtlnet_classifier_pkg::*;

  localparam int M     = MATCH_BEATS;
  localparam int NB    = 8 * M;                                    // compared bytes
  localparam int AW    = rtlnet_pkg::clog2i(M);
  localparam int SB    = rtlnet_pkg::clog2i(STRIDE_WORDS);
  localparam int BW    = rtlnet_pkg::clog2i(NB);                   // byte index bits
  localparam logic [IDX_W-1:0] IDX_M = M;

  generate
    if (M < 2 || M > 32) begin : g_bad_m
      $fatal(1, "rtlnet_classifier_rule: MATCH_BEATS=%0d, must be 2..32", M);
    end
    if (STRIDE_WORDS < NB || (STRIDE_WORDS & (STRIDE_WORDS - 1)) != 0 || STRIDE_WORDS > 256) begin : g_bad_stride
      $fatal(1, "rtlnet_classifier_rule: STRIDE_WORDS=%0d invalid for %0d bytes", STRIDE_WORDS, NB);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Configuration writes and the don't-care vector.
  // ---------------------------------------------------------------------------
  logic             cw_en_q;
  logic [9:0]       cw_addr_q;
  logic [31:0]      cw_data_q;
  logic             clr_q;
  logic [9:0]       clr_addr_q;
  logic [7:0]       cw_word;          // word offset in the 0xC00 window
  logic [BW-1:0]    cw_byte;
  logic             cw_hit;

  logic [7:0]       we;               // per lane
  logic [AW-1:0]    wa;
  logic [RB_STORE_W-1:0] wd;
  logic             dc_we;
  logic             dc_set_all;
  logic [BW-1:0]    dc_byte;
  logic             dc_val;
  logic [NB-1:0]    dc;               // byte b is don't-care
  logic [M-1:0]     beat_dc;          // all bytes of beat k are don't-care
  logic [M:0]       tail_dc;          // all bytes of beats k..M-1 are don't-care

  // Local register copy of the write bus.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cw_en_q    <= 1'b0;
      cw_addr_q  <= '0;
      cw_data_q  <= '0;
      clr_q      <= 1'b0;
      clr_addr_q <= '0;
    end else begin
      cw_en_q    <= cw_en;
      cw_addr_q  <= cw_addr;
      cw_data_q  <= cw_data;
      clr_q      <= clr_active;
      clr_addr_q <= clr_addr;
    end
  end

  // Byte offset 0xC00 + 4 (STRIDE_WORDS r + b).
  assign cw_word = cw_addr_q[7:0];
  assign cw_byte = cw_word[BW-1:0];
  assign cw_hit  = cw_en_q && (cw_addr_q[9:8] == 2'b11) && ((cw_word >> SB) == RULE_IDX) &&
                   ((cw_word & (STRIDE_WORDS - 1)) < NB);

  // Lane RAM write port and don't-care update (the clear sequence writes zero:
  // operator 0000, don't-care).
  always_ff @(posedge clk) begin
    if (!resetn) begin
      we         <= '0;
      wa         <= '0;
      wd         <= '0;
      dc_we      <= 1'b0;
      dc_set_all <= 1'b0;
      dc_byte    <= '0;
      dc_val     <= 1'b1;
    end else begin
      for (int l = 0; l < 8; l++) we[l] <= clr_q || (cw_hit && (cw_byte[2:0] == l));
      if (clr_q) begin
        wa <= clr_addr_q[AW-1:0];
        wd <= '0;
      end else begin
        wa <= cw_byte[3 +: AW];
        wd <= {cw_data_q[RB_MASK_LSB +: 8], cw_data_q[RB_OP_LSB +: 4], cw_data_q[RB_COMPARE_LSB +: 8]};
      end
      dc_we      <= cw_hit;
      dc_set_all <= clr_q;
      dc_byte    <= cw_byte;
      dc_val     <= !op_is_compare(cw_data_q[RB_OP_LSB +: 4]);
    end
  end

  // Don't-care bits, beat reduction and the suffix AND over beats.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      dc      <= '1;
      beat_dc <= '1;
      tail_dc <= '1;
    end else begin
      for (int i = 0; i < NB; i++) begin
        if (dc_set_all)                                 dc[i] <= 1'b1;
        else if (dc_we && (dc_byte == i))               dc[i] <= dc_val;
      end
      for (int k = 0; k < M; k++) begin
        beat_dc[k] <= &dc[8*k +: 8];
        tail_dc[k] <= beat_dc[k] && tail_dc[k+1];
      end
      tail_dc[M] <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Compare buffer, read from the tap.
  // ---------------------------------------------------------------------------
  logic [7:0][RB_STORE_W-1:0] ent;

  genvar gl;
  generate
    for (gl = 0; gl < 8; gl++) begin : g_lane
      logic [RB_STORE_W-1:0] q;
      // Lane gl of the compare buffer: entries for bytes 8 k + gl.
      rtlnet_ram_core #(
        .RAM_STYLE (RAM_STYLE), .CLOCKING ("COMMON"), .DATA_W (RB_STORE_W), .ADDR_W (AW), .READ_LATENCY (2)
      ) u_ram (
        .wr_clk (clk), .wr_en (we[gl]), .wr_addr (wa), .wr_data (wd),
        .rd_clk (clk), .rd_resetn (resetn), .rd_en (1'b1), .rd_addr (tap_idx[AW-1:0]), .rd_data (q)
      );
      assign ent[gl] = q;
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Beat delay to the buffer output (two clocks) with the tail value.
  // ---------------------------------------------------------------------------
  logic [M-1:0] srt;
  logic [63:0]  d1_data;
  logic [7:0]   d1_keep;
  logic         d1_v;
  logic         d1_first;
  logic         d1_judge;
  logic         d1_rt;
  logic [63:0]  d2_data;
  logic [7:0]   d2_keep;
  logic         d2_v;
  logic         d2_first;
  logic         d2_judge;
  logic         d2_rt;

  // Tail shift register: at beat k of a frame d1_rt = tail_dc[k+1].
  always_ff @(posedge clk) begin
    if (!resetn) begin
      srt      <= '1;
      d1_data  <= '0;
      d1_keep  <= '0;
      d1_v     <= 1'b0;
      d1_first <= 1'b0;
      d1_judge <= 1'b0;
      d1_rt    <= 1'b1;
      d2_data  <= '0;
      d2_keep  <= '0;
      d2_v     <= 1'b0;
      d2_first <= 1'b0;
      d2_judge <= 1'b0;
      d2_rt    <= 1'b1;
    end else begin
      if (tap_valid) begin
        if (tap_first) begin
          d1_rt <= tail_dc[1];
          srt   <= {1'b1, tail_dc[M:2]};
        end else begin
          d1_rt <= srt[0];
          srt   <= {1'b1, srt[M-1:1]};
        end
      end
      d1_data  <= tap_data;
      d1_keep  <= tap_keep;
      d1_v     <= tap_valid && (tap_idx < IDX_M);
      d1_first <= tap_first;
      d1_judge <= tap_valid && tap_judge;
      d2_data  <= d1_data;
      d2_keep  <= d1_keep;
      d2_v     <= d1_v;
      d2_first <= d1_first;
      d2_judge <= d1_judge;
      d2_rt    <= d1_rt;
    end
  end

  // ---------------------------------------------------------------------------
  // Byte ALUs: S1 mask, S2 compare, S3 operator; S4 beat AND; S5 frame.
  // ---------------------------------------------------------------------------
  logic [7:0][7:0] s1_md;
  logic [7:0][7:0] s1_mc;
  logic [7:0][3:0] s1_op;
  logic [7:0]      s1_pres;
  logic            s1_v;
  logic            s1_first;
  logic            s1_judge;
  logic            s1_rt;

  logic [7:0]      s2_eq;
  logic [7:0]      s2_lt;
  logic [7:0][3:0] s2_op;
  logic [7:0]      s2_pres;
  logic            s2_v;
  logic            s2_first;
  logic            s2_judge;
  logic            s2_rt;

  logic [7:0]      s3_bp;
  logic            s3_v;
  logic            s3_first;
  logic            s3_judge;
  logic            s3_rt;

  logic            s4_bp;
  logic            s4_v;
  logic            s4_first;
  logic            s4_judge;
  logic            s4_rt;

  logic            acc;

  // Operator result for one byte.
  function automatic logic op_pass(input logic [3:0] op, input logic pres, input logic eq,
                                   input logic lt);
    logic r;
    if (!pres) begin
      r = !op_is_compare(op);
    end else begin
      case (op)
        OP_EQ:   r = eq;
        OP_NE:   r = !eq;
        OP_LT:   r = lt;
        OP_GT:   r = !lt && !eq;
        OP_LE:   r = lt || eq;
        OP_GE:   r = !lt;
        default: r = 1'b1;
      endcase
    end
    return r;
  endfunction

  always_ff @(posedge clk) begin
    if (!resetn) begin
      s1_md    <= '0;
      s1_mc    <= '0;
      s1_op    <= '0;
      s1_pres  <= '0;
      s1_v     <= 1'b0;
      s1_first <= 1'b0;
      s1_judge <= 1'b0;
      s1_rt    <= 1'b1;
      s2_eq    <= '0;
      s2_lt    <= '0;
      s2_op    <= '0;
      s2_pres  <= '0;
      s2_v     <= 1'b0;
      s2_first <= 1'b0;
      s2_judge <= 1'b0;
      s2_rt    <= 1'b1;
      s3_bp    <= '0;
      s3_v     <= 1'b0;
      s3_first <= 1'b0;
      s3_judge <= 1'b0;
      s3_rt    <= 1'b1;
      s4_bp    <= 1'b0;
      s4_v     <= 1'b0;
      s4_first <= 1'b0;
      s4_judge <= 1'b0;
      s4_rt    <= 1'b1;
    end else begin
      // S1: mask both operands.
      for (int j = 0; j < 8; j++) begin
        s1_md[j]   <= d2_data[8*j +: 8] & ent[j][RB_STORE_W-1 -: 8];
        s1_mc[j]   <= ent[j][7:0] & ent[j][RB_STORE_W-1 -: 8];
        s1_op[j]   <= ent[j][11:8];
        s1_pres[j] <= d2_keep[j];
      end
      s1_v     <= d2_v;
      s1_first <= d2_first;
      s1_judge <= d2_judge;
      s1_rt    <= d2_rt;
      // S2: equality and less-than per byte.
      for (int j = 0; j < 8; j++) begin
        s2_eq[j] <= (s1_md[j] == s1_mc[j]);
        s2_lt[j] <= (s1_md[j] <  s1_mc[j]);
      end
      s2_op    <= s1_op;
      s2_pres  <= s1_pres;
      s2_v     <= s1_v;
      s2_first <= s1_first;
      s2_judge <= s1_judge;
      s2_rt    <= s1_rt;
      // S3: operator select.
      for (int j = 0; j < 8; j++) s3_bp[j] <= op_pass(s2_op[j], s2_pres[j], s2_eq[j], s2_lt[j]);
      s3_v     <= s2_v;
      s3_first <= s2_first;
      s3_judge <= s2_judge;
      s3_rt    <= s2_rt;
      // S4: all eight bytes of the beat pass.
      s4_bp    <= &s3_bp;
      s4_v     <= s3_v;
      s4_first <= s3_first;
      s4_judge <= s3_judge;
      s4_rt    <= s3_rt;
    end
  end

  // S5: running per-frame AND; the judge beat closes the frame.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      acc     <= 1'b0;
      r_match <= 1'b0;
      r_done  <= 1'b0;
    end else begin
      r_done <= s4_judge;
      if (s4_v) acc <= s4_first ? s4_bp : (acc && s4_bp);
      if (s4_judge) r_match <= (s4_first ? s4_bp : (acc && s4_bp)) && s4_rt;
    end
  end

endmodule
