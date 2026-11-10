// -----------------------------------------------------------------------------
// File: rtlnet_h264_pkg.sv
// Purpose: constants shared by the rtlnet_h264_top modules: bit-packer command codes, NAL kinds,
//   error codes and index-entry fields.
// Overview:
//   * Packer commands (rtlnet_h264_bitpack): FIELD appends len bits, UE/SE append an exp-Golomb
//     code (ITU-T Rec. H.264 clause 9.1), ALIGN pads zero bits to a byte boundary, START emits an
//     Annex B start code, END appends the rbsp trailing bits and marks the NAL's last byte.
//   * Error codes are the values of the ERR_CODE register (driver/rtlnet_h264_enc.h mirrors them).
// Language: SystemVerilog-2012 (synthesizable package).
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-10-2026: phase 2c-1 (P pictures): P slice constants, the inter coded_block_pattern code (Table 9-4), the motion
//     lambda and the se(v) length used by the inter decision.
// Clocks: none (package).
// -----------------------------------------------------------------------------
package rtlnet_h264_pkg;

  // Bit-packer command codes.
  localparam logic [2:0] PK_FIELD = 3'd0;
  localparam logic [2:0] PK_UE    = 3'd1;
  localparam logic [2:0] PK_SE    = 3'd2;
  localparam logic [2:0] PK_ALIGN = 3'd3;
  localparam logic [2:0] PK_START = 3'd4;
  localparam logic [2:0] PK_END   = 3'd5;

  // NAL kind carried with the byte stream: picture delimiter (no index entry) or slice.
  localparam logic       NAL_AUD   = 1'b0;
  localparam logic       NAL_SLICE = 1'b1;

  // ERR_CODE register values (0 = no error).
  localparam logic [7:0] ERR_NONE   = 8'd0;
  localparam logic [7:0] ERR_CONFIG = 8'd1;   // start with an illegal register setting
  localparam logic [7:0] ERR_AXI    = 8'd2;   // memory read or write response other than OKAY
  localparam logic [7:0] ERR_RPTR   = 8'd3;   // firmware moved a read pointer past the data written
  localparam logic [7:0] ERR_BUSY   = 8'd4;   // start while a picture is running

  // Index entry kinds (word 3 bit 24).
  localparam logic       IDX_KIND_SLICE   = 1'b0;
  localparam logic       IDX_KIND_PICTURE = 1'b1;

  // Index record: 128 bytes (8 beats of 128 bits) per entry so every index write is one 8-beat burst; the first 16 bytes
  // hold the entry words, the other 112 bytes are reserved and written as zero.
  localparam int IDX_REC_BYTES = 128;
  localparam int IDX_REC_BEATS = 8;

  // Rebuilt-picture tile layout (macroblock-tiled reference picture): 256 bytes of luma (16 beats, row-major 16 x 16)
  // and 128 bytes of chroma (8 beats: Cb 8 x 8 then Cr 8 x 8) per macroblock, at base + 256 * mb and base + 128 * mb.
  localparam int REC_LUMA_TILE_BYTES   = 256;
  localparam int REC_CHROMA_TILE_BYTES = 128;

  // Slice type code written in the slice header and the index entry (I slice, all slices of the picture).
  localparam logic [7:0] SLICE_TYPE_I_ALL = 8'd7;

  // Macroblock type of an I_PCM macroblock in an I slice (Table 7-11).
  localparam logic [31:0] MB_TYPE_I_PCM = 32'd25;

  // Slice type code of a picture of P slices only (slice_type 5, Table 7-6) in the slice header and the index entry.
  localparam logic [7:0] SLICE_TYPE_P_ALL = 8'd5;

  // Macroblock types in a P slice (Tables 7-13 and 7-11): P_L0_16x16 is 0; the I macroblock types follow at an offset of 5
  // (I_PCM is 5 + 25 = 30, Intra16x16 is 5 + 1 + prediction mode + 4 * cbp_chroma + 12 * (cbp_luma != 0)).
  localparam logic [31:0] MB_TYPE_P_L0_16X16   = 32'd0;
  localparam logic [31:0] MB_TYPE_P_INTRA_BASE = 32'd5;

  // coded_block_pattern to codeNum for an inter macroblock (Table 9-4, ChromaArrayType 1, column "Inter"; me(v)). The
  // coded_block_pattern is the luma 8x8 mask in bits 3..0 and cbp_chroma (0..2) in bits 5..4. Generated from the JM 19.1
  // decoder table by testbench/h264_gen_cbp_table.py (--check compares this text with the generated one).
  function automatic logic [5:0] h264_cbp_inter_code(input logic [5:0] cbp);
    logic [5:0] r;
    case (cbp)
      6'd0: r = 6'd0;
      6'd1: r = 6'd2;
      6'd2: r = 6'd3;
      6'd3: r = 6'd7;
      6'd4: r = 6'd4;
      6'd5: r = 6'd8;
      6'd6: r = 6'd17;
      6'd7: r = 6'd13;
      6'd8: r = 6'd5;
      6'd9: r = 6'd18;
      6'd10: r = 6'd9;
      6'd11: r = 6'd14;
      6'd12: r = 6'd10;
      6'd13: r = 6'd15;
      6'd14: r = 6'd16;
      6'd15: r = 6'd11;
      6'd16: r = 6'd1;
      6'd17: r = 6'd32;
      6'd18: r = 6'd33;
      6'd19: r = 6'd36;
      6'd20: r = 6'd34;
      6'd21: r = 6'd37;
      6'd22: r = 6'd44;
      6'd23: r = 6'd40;
      6'd24: r = 6'd35;
      6'd25: r = 6'd45;
      6'd26: r = 6'd38;
      6'd27: r = 6'd41;
      6'd28: r = 6'd39;
      6'd29: r = 6'd42;
      6'd30: r = 6'd43;
      6'd31: r = 6'd19;
      6'd32: r = 6'd6;
      6'd33: r = 6'd24;
      6'd34: r = 6'd25;
      6'd35: r = 6'd20;
      6'd36: r = 6'd26;
      6'd37: r = 6'd21;
      6'd38: r = 6'd46;
      6'd39: r = 6'd28;
      6'd40: r = 6'd27;
      6'd41: r = 6'd47;
      6'd42: r = 6'd22;
      6'd43: r = 6'd29;
      6'd44: r = 6'd23;
      6'd45: r = 6'd30;
      6'd46: r = 6'd31;
      6'd47: r = 6'd12;
      default: r = 6'd0;
    endcase
    return r;
  endfunction

  // Motion lambda of the inter decision (SAD units per bit), clause-independent encoder choice: round(0.92 * 2^((QP - 12) / 6)),
  // at least 1 (the form of the JM motion lambda, the square root of 0.85 * 2^((QP - 12) / 3)). base_q8[r] = 0.92 * 2^(r / 6) * 256.
  function automatic logic [7:0] h264_lambda(input logic [5:0] qp);
    logic [8:0]  base;
    logic [3:0]  q6;
    logic [2:0]  r;
    logic [19:0] v;
    q6 = 4'(qp / 6'd6);
    r  = 3'(qp % 6'd6);
    case (r)
      3'd0:    base = 9'd235;
      3'd1:    base = 9'd264;
      3'd2:    base = 9'd297;
      3'd3:    base = 9'd333;
      3'd4:    base = 9'd374;
      default: base = 9'd420;
    endcase
    v = ((20'(base) << q6) >> 2) + 20'd128;
    v = v >> 8;
    if (v == 20'd0) return 8'd1;
    return v[7:0];
  endfunction

  // Length in bits of se(v) for a signed value (clause 9.1.1: codeNum 2|v| - (v > 0), length 2 floor(log2(codeNum + 1)) + 1).
  function automatic logic [5:0] h264_se_len(input logic signed [15:0] v);
    logic [16:0] code;
    logic [4:0]  n;
    code = (v > 16'sd0) ? {v[15:0], 1'b0} - 17'd1 : {(-v), 1'b0};
    code = code + 17'd1;
    n = 5'd0;
    for (int i = 0; i < 17; i++) if (code[i]) n = 5'(i);
    return {n, 1'b0} + 6'd1;
  endfunction

  // Chroma QP for chroma_qp_index_offset 0 (clause 8.5.8, Table 8-15): QPc equals QPy below 30.
  function automatic logic [5:0] h264_qpc(input logic [5:0] qp);
    logic [5:0] r;
    case (qp)
      6'd30: r = 6'd29;  6'd31: r = 6'd30;  6'd32: r = 6'd31;  6'd33: r = 6'd32;  6'd34: r = 6'd32;
      6'd35: r = 6'd33;  6'd36: r = 6'd34;  6'd37: r = 6'd34;  6'd38: r = 6'd35;  6'd39: r = 6'd35;
      6'd40: r = 6'd36;  6'd41: r = 6'd36;  6'd42: r = 6'd37;  6'd43: r = 6'd37;  6'd44: r = 6'd37;
      6'd45: r = 6'd38;  6'd46: r = 6'd38;  6'd47: r = 6'd38;  6'd48: r = 6'd39;  6'd49: r = 6'd39;
      6'd50: r = 6'd39;  6'd51: r = 6'd39;
      default: r = qp;
    endcase
    return r;
  endfunction

  // pic_init_qp_minus26 is 0: the PPS written by rtlnet_h264_enc_write_sps_pps() has pic_init_qp 26.
  localparam int unsigned PIC_INIT_QP = 26;

endpackage
