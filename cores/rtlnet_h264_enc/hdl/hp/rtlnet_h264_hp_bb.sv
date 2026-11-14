// -----------------------------------------------------------------------------
// File: rtlnet_h264_hp_bb.sv
// Purpose: black-box declaration of rtlnet_h264_hp, the High profile extension of one rtlnet_h264_engine, for a synthesis
//   that takes the module from a separately delivered netlist (rtlnet_h264_top with HIGH_PROFILE = 1).
// Overview:
//   * Declares the ports only; the netlist supplies the logic. rtlnet_h264_enc.f does not list this file: the board build adds
//     it together with the netlist (the board build script, for example boards/nexys_video/scripts/build.ps1 with -HighProfile full|demo).
//   * The port list is the seam of the High profile extension: macroblock descriptor of rtlnet_h264_mb_cavlc, packer command
//     output, 8x8 transform streams, picture events and status. rtlnet_h264_hp_stub.sv has the same ports.
// Language: SystemVerilog-2012.
// Revision: 11-11-2026
//   * 11-11-2026: initial version.
// Clocks: clk (the encoder clock).
// -----------------------------------------------------------------------------
(* black_box = "yes", keep_hierarchy = "yes" *)
module rtlnet_h264_hp #(
  parameter int LIMIT_MINUTES = 0,   // license limit in minutes from configuration, 0 = unlimited
  parameter int CLK_HZ        = 90000000,                   // frequency of clk in Hz
  parameter int SIM_SCALE     = 1        // simulation only, 1 in every build
)(
  // Encoder clock and synchronous active-low reset. The reset never reaches the license timer.
  input  logic              clk,
  input  logic              resetn,

  // Status and control, clk domain: hp_enable is the register-block enable bit; hp_present is 1 in the delivered module and 0 in the stub; hp_licensed is 1 while High
  // profile coding is allowed; hp_seconds_left is the license time left (16'hFFFF unlimited); hp_caps bit 0 CABAC, bit 1 8x8, bit 2 adaptive choice
  // transform (bit 3 reserved 0); hp_active is high from pic_start to pic_done when this module codes the picture.
  input  logic              hp_enable,
  // hp_t8_enable: the register block's 8x8 transform enable bit (applied with hp_enable at a picture start).
  input  logic              hp_t8_enable,
  output logic              hp_present,
  output logic              hp_licensed,
  output logic [15:0]       hp_seconds_left,
  output logic [3:0]        hp_caps,
  output logic              hp_active,

  // Picture and slice events from the engine, clk domain: pic_start and pic_done are one-clock pulses (the engine accepts a start,
  // hp_enable and hp_licensed are sampled then; the picture is done). slice_start is high while the engine writes the slice header's
  // first command (the module uses its rising edge), slice_end is high while the engine waits in its slice-end state: the module writes
  // the end of its slice data and holds mb_busy until the last command has been accepted; the engine writes the rbsp trailing bits then.
  input  logic              pic_start,
  input  logic              pic_done,
  input  logic              slice_start,
  input  logic              slice_end,

  // Macroblock command, clk domain: the descriptor of rtlnet_h264_mb_cavlc (same meaning, same timing: mb_start pulses one
  // clock when the module is idle and the descriptor is sampled with it). qp is the slice QP. mb_skip_run is the running count of
  // skipped macroblocks of the slice; mb_busy and mb_done are the macroblock-coded handshake.
  input  logic              mb_start,
  input  logic [7:0]        mb_x,
  input  logic              av_top,
  input  logic              av_left,
  input  logic              pcm,
  input  logic [1:0]        i16_mode,
  input  logic [1:0]        cbp_chroma,
  input  logic              cbp_luma,
  input  logic [1:0]        chroma_mode,
  input  logic [9:0]        cbase,
  input  logic              p_slice,
  input  logic              skip,
  input  logic              inter,
  input  logic [3:0]        cbp_luma4,
  // t8_sub: the macroblock submitted its luma residual on tf_res (the levels are in the module).
  input  logic              t8_sub,
  input  logic signed [15:0] mvd_x,
  input  logic signed [15:0] mvd_y,
  input  logic [5:0]        qp,
  output logic [15:0]       mb_skip_run,
  output logic              mb_busy,
  output logic              mb_done,

  // Coefficient RAM read port, clk domain: the port of the macroblock's coefficient bank (48-bit words, four 12-bit levels each);
  // cram_rd_data is valid the clock after cram_rd_en.
  output logic              cram_rd_en,
  output logic [9:0]        cram_rd_addr,
  input  logic [47:0]       cram_rd_data,

  // Bit output to the packer, clk domain: the command interface of rtlnet_h264_bitpack (op 0 FIELD, 1 UE, 2 SE, 3 ALIGN, 4 START,
  // 5 END, 6 ALIGN1: pad with one bits to a byte boundary; val and len as there). Valid is held until ready.
  output logic              cmd_valid,
  input  logic              cmd_ready,
  output logic [2:0]        cmd_op,
  output logic [31:0]       cmd_val,
  output logic [5:0]        cmd_len,

  // 8x8 transform seam, clk domain. tf_req is high while the module wants the 8x8 transform for the current macroblock.
  // tf_res: residual of an 8x8 block from the engine, one row of 8 signed 9-bit samples per beat (sample 0 in bits [8:0]), 8 beats
  // per block. tf_res_last high with tf_res_valid is a request beat that carries no residual: it precedes a macroblock's 32 residual beats and
  // asks the module for its choice of the 4x4 or the 8x8 transform (tf_lvl_data[26], 1 = 4x4; stage 3a, adaptive mode). tf_rec: the rebuilt
  // residual (after quantization, dequantization and the inverse transform) of the block, same layout, to the engine's rebuild loop (none for
  // a macroblock that chose the 4x4 transform). tf_lvl: one summary beat per macroblock (see the module's documentation), tf_lvl_last with it.
  // Tied off in stages 1 and 2.
  output logic              tf_req,
  input  logic              tf_res_valid,
  output logic              tf_res_ready,
  input  logic [71:0]       tf_res_data,
  input  logic              tf_res_last,
  output logic              tf_rec_valid,
  input  logic              tf_rec_ready,
  output logic [71:0]       tf_rec_data,
  output logic              tf_rec_last,
  output logic              tf_lvl_valid,
  input  logic              tf_lvl_ready,
  output logic [127:0]      tf_lvl_data,
  output logic              tf_lvl_last
);

endmodule
