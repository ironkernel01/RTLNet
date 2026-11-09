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

  // Slice type code written in the slice header and the index entry (I slice, all slices of the picture).
  localparam logic [7:0] SLICE_TYPE_I_ALL = 8'd7;

  // Macroblock type of an I_PCM macroblock in an I slice (Table 7-11).
  localparam logic [31:0] MB_TYPE_I_PCM = 32'd25;

  // pic_init_qp_minus26 is 0: the PPS written by rtlnet_h264_enc_write_sps_pps() has pic_init_qp 26.
  localparam int unsigned PIC_INIT_QP = 26;

endpackage
