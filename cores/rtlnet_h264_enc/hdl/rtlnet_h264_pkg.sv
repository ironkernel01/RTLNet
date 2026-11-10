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
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
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
