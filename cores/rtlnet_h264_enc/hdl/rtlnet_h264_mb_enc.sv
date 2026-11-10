// -----------------------------------------------------------------------------
// File: rtlnet_h264_mb_enc.sv
// Purpose: stage A of the macroblock coder (phase 2b-2): Intra16x16 mode decision, forward transform and quantizer,
//   rebuild loop (dequantizer, inverse transform, prediction add, clip) and the neighbour state of the next macroblocks.
//   It writes the quantized levels into the coefficient RAM (read by stage B, rtlnet_h264_mb_cavlc) and the rebuilt
//   macroblock into the rebuilt RAM (read by rtlnet_h264_recon_wr). A macroblock with a level at the baseline limit (+-2047)
//   or with an estimated CAVLC size above the I_PCM size falls back to I_PCM: the source macroblock is copied into the rebuilt
//   RAM and into the coefficient RAM (the I_PCM sample words for stage B). The pcm_mode input forces that for every macroblock.
// Overview:
//   * One macroblock takes these phases:
//       TOP    read the rebuilt bottom rows of the macroblock above from the line RAM (luma word, chroma word),
//              load the neighbours into rtlnet_h264_ipred (top row, left column, corner, availability).
//       PREP   rtlnet_h264_ipred computes the plane parameters and DC values.
//       SAD    96 row segments (16 luma blocks, 4 Cb, 4 Cr blocks of 4 rows each, raster block order) are read from the
//              source buffer and offered to rtlnet_h264_ipred, which accumulates the SAD of every legal mode and decides.
//       PASS1  the same 96 row segments: source minus prediction of the chosen mode, rtlnet_h264_fwdq (forward 4x4
//              transform and AC quantizer), levels into the coefficient RAM, the 24 DC coefficients into the DC units
//              (rtlnet_h264_dcq_luma during the chroma blocks, rtlnet_h264_dcq_chroma twice at the end).
//       CHK    fallback decision (five clocks): saturated level flag, size estimate (EST_BASE + EST_BLK per non-empty block +
//              the level costs by bit length), I_PCM when the flag is set or the estimate exceeds EST_LIMIT.
//       DCW    the DC levels into the coefficient RAM; the coded block pattern follows from the nonzero flags.
//       PASS3  rebuild: coefficient rows back out of the RAM, rtlnet_h264_invq (dequantizer, inverse transform, the DC from
//              the DC units), prediction of the chosen mode added and clipped, one 4-sample word per clock into the
//              rebuilt RAM. The left column and bottom row of the rebuilt macroblock are captured on the way.
//       LINE   the bottom row (luma word, chroma word) into the line RAM.
//   * Neighbours come from the same slice only: the caller drives av_top (not the first macroblock row of its slice)
//     and av_left (mb_x not 0). The line RAM holds one rebuilt bottom row for the picture width (two 16-byte words per
//     macroblock column: luma, then Cb and Cr). The corner sample of the next macroblock is saved while the top word
//     is read, before the line RAM word of this column is overwritten at the end of the macroblock.
//   * Coefficient RAM layout (48-bit words, 4 signed 12-bit levels each): words 0..3 luma DC level matrix rows, word
//     4 + 4 * tag + row for the 24 blocks (tag = by * 4 + bx for luma, 16 + 2 * by + bx for Cb, 20 + 2 * by + bx for Cr),
//     word 100 / 101 the Cb / Cr DC levels. Rebuilt RAM layout (32-bit words, 4 samples): luma word (4 * y + bx), Cb
//     word 64 + 2 * y + bx, Cr word 80 + 2 * y + bx.
//   * I_PCM copy (pcm_mode, or the fallback after CHK): the source macroblock (24 words of 16 bytes) is copied into the rebuilt
//     RAM and into the coefficient RAM (words 0..95, the same word index and the sample order of the stream, first sample in the
//     top byte), 4 words per source word; the left column and bottom row are captured from the copy and the line RAM written.
//   * Outputs for stage B with done: i16 prediction mode, chroma prediction mode, cbp_chroma (0..2), cbp_luma (0 or 1).
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version; per-macroblock I_PCM fallback.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_mb_enc #(
  parameter int    MAX_MB_W   = 120,
  parameter int    LINE_KB    = 4,        // line RAM: 2 words of 16 bytes per macroblock column
  parameter string RAM_STYLE  = "block",
  parameter int    SRC_AW     = 6,
  parameter int    REC_AW     = 8,
  parameter int    CRAM_AW    = 8
)(
  // Clock and synchronous active-low reset.
  input  logic                clk,
  input  logic                resetn,

  // Macroblock command, clk domain: start pulses one clock when idle. The values are sampled with start.
  input  logic                start,
  input  logic                pcm_mode,
  input  logic [7:0]          mb_x,
  input  logic                av_top,
  input  logic                av_left,
  input  logic [5:0]          qp,
  input  logic [SRC_AW-1:0]   src_base,
  input  logic [REC_AW-1:0]   reb_base,
  input  logic [CRAM_AW-1:0]  coef_base,
  output logic                busy,
  output logic                done,

  // Coding decisions for stage B, valid with done.
  output logic [1:0]          o_i16_mode,
  output logic [1:0]          o_chroma_mode,
  output logic [1:0]          o_cbp_chroma,
  output logic                o_cbp_luma,
  output logic                o_pcm,

  // Source macroblock buffer read port: src_rd_data is valid the clock after src_rd_en.
  output logic                src_rd_en,
  output logic [SRC_AW-1:0]   src_rd_addr,
  input  logic [127:0]        src_rd_data,

  // Rebuilt macroblock RAM write port.
  output logic                reb_we,
  output logic [REC_AW-1:0]   reb_waddr,
  output logic [31:0]         reb_wdata,

  // Coefficient RAM write port and read-back port (stage A's copy): rdata valid the clock after cof_rd_en.
  output logic                cof_we,
  output logic [CRAM_AW-1:0]  cof_waddr,
  output logic [47:0]         cof_wdata,
  output logic                cof_rd_en,
  output logic [CRAM_AW-1:0]  cof_raddr,
  input  logic [47:0]         cof_rdata
);

  import rtlnet_h264_pkg::*;

  localparam int LINE_AW = $clog2(LINE_KB * 1024 / 16);

  // Fallback thresholds (documentation: size estimate). The estimate of the CAVLC size of the macroblock in bits is EST_BASE,
  // plus EST_BLK per non-empty block, plus the sum of the level costs (a table by the bit length of |level|, least-squares fit
  // to the coded sizes of 3721 macroblocks); the macroblock falls back to I_PCM when it exceeds EST_LIMIT (the I_PCM macroblock
  // layer is 9 + 3072 bits plus alignment).
  localparam int EST_BASE  = 21;
  localparam int EST_BLK   = 16;
  localparam int EST_LIMIT = 3072;

  // Phase states.
  localparam logic [4:0] S_IDLE  = 5'd0;
  localparam logic [4:0] S_TOP   = 5'd1;
  localparam logic [4:0] S_PREP  = 5'd2;
  localparam logic [4:0] S_SAD   = 5'd3;
  localparam logic [4:0] S_DEC   = 5'd4;
  localparam logic [4:0] S_P1    = 5'd5;
  localparam logic [4:0] S_P1W   = 5'd6;
  localparam logic [4:0] S_DCW   = 5'd7;
  localparam logic [4:0] S_P3    = 5'd8;
  localparam logic [4:0] S_P3W   = 5'd9;
  localparam logic [4:0] S_LINE  = 5'd10;
  localparam logic [4:0] S_DONE  = 5'd11;
  localparam logic [4:0] S_PCM   = 5'd12;
  localparam logic [4:0] S_CHK   = 5'd13;
  localparam logic [4:0] S_CHK2  = 5'd14;
  localparam logic [4:0] S_CHK3  = 5'd15;
  localparam logic [4:0] S_CHK4  = 5'd16;
  localparam logic [4:0] S_CHK5  = 5'd17;

  generate
    if ((2 * MAX_MB_W) > (1 << LINE_AW)) begin : g_line_small
      $fatal(1, "rtlnet_h264_mb_enc: LINE_KB=%0d too small for MAX_MB_W=%0d", LINE_KB, MAX_MB_W);
    end
  endgenerate

  logic [4:0]         st;
  logic [7:0]         cnt;
  logic [6:0]         iss_n;
  logic               iss_run;
  logic               p3_run;
  logic               sel_p3;       // PASS3 (rebuild) owns the ipred query port: set with S_P3, cleared with S_P3W's end
  logic [6:0]         x_q;
  logic               avt_q;
  logic               avl_q;
  logic [5:0]         qp_q;
  logic [5:0]         qpc_q;
  logic [SRC_AW-1:0]  sbase_q;
  logic [REC_AW-1:0]  rbase_q;
  logic [CRAM_AW-1:0] cbase_q;

  // Neighbour registers.
  logic [127:0]       top_y;
  logic [127:0]       top_c;
  logic [127:0]       left_y;
  logic [127:0]       left_c;
  logic [7:0]         tl_y, tl_cb, tl_cr;
  logic [7:0]         tln_y, tln_cb, tln_cr;
  logic [127:0]       bot_y;
  logic [127:0]       bot_c;
  logic [127:0]       lr_rdata;
  logic               lr_rd_en;
  logic [LINE_AW-1:0] lr_raddr;
  logic               lr_we;
  logic [LINE_AW-1:0] lr_waddr;
  logic [127:0]       lr_wdata;

  // ipred signals.
  logic               ip_nb_load;
  logic               ip_prep_done;
  logic               ip_q_valid;
  logic [1:0]         ip_q_plane;
  logic [1:0]         ip_q_seg;
  logic [3:0]         ip_q_y;
  logic [31:0]        ip_q_src;
  logic               ip_q_acc;
  logic               ip_p_valid;
  logic [127:0]       ip_p_px;
  logic               ip_dec_start;
  logic               ip_dec_done;
  logic [1:0]         ip_dec_lm;
  logic [1:0]         ip_dec_cm;
  // The SAD accumulators are bench visibility outputs of rtlnet_h264_ipred.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [71:0]        ip_sad_y;
  logic [71:0]        ip_sad_c;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0]         lm_q;
  logic [1:0]         cm_q;

  // Issue pipeline (source read, stage 1, two delay stages).
  logic               s1_v;
  logic [4:0]         s1_b;
  logic [1:0]         s1_r;
  logic               s1_acc;
  logic               d1_v, d2_v;
  logic [4:0]         d1_b, d2_b;
  logic [1:0]         d1_r, d2_r;
  logic [31:0]        d1_src, d2_src;
  logic [31:0]        s1_src;

  // Decoded issue item.
  logic [4:0]         it_b;
  logic [1:0]         it_r;
  logic [1:0]         it_plane;
  logic [3:0]         it_y;
  logic [SRC_AW-1:0]  it_addr;

  // Forward path.
  logic               fq_in_v;
  logic               fq_in_first;
  logic [35:0]        fq_in_res;
  logic [7:0]         fq_in_tag;
  logic [5:0]         fq_in_qp;
  logic               fq_out_v;
  logic [1:0]         fq_out_row;
  logic [47:0]        fq_out_lvl;
  logic               fq_out_dcv;
  logic [15:0]        fq_out_dc;
  logic [7:0]         fq_out_tag;
  logic [255:0]       dcw_y;
  logic [63:0]        dcw_cb;
  logic [63:0]        dcw_cr;
  logic [4:0]         dc_cnt;
  logic [6:0]         fq_rows;
  logic               ac_nz_y;
  logic               ac_nz_c;
  logic               dqy_start;
  logic               dqc_start;
  logic               dqy_done_q, dqcb_done_q, dqcr_done_q;
  logic               dqy_done, dqcb_done, dqcr_done;
  logic               dqy_busy, dqcb_busy, dqcr_busy;
  logic [191:0]       dqy_lvl;
  logic [319:0]       dqy_dc;
  logic               dqy_nz;
  logic [47:0]        dqcb_lvl, dqcr_lvl;
  logic [79:0]        dqcb_dc, dqcr_dc;
  logic               dqcb_nz, dqcr_nz;
  logic [2:0]         dcw_n;

  // Fallback decision (I_PCM macroblock): any level at the profile limit, or the CAVLC size estimate above the I_PCM size.
  logic [15:0]        est_q;
  logic               ovf_q;
  logic [15:0]        w_est [6];
  logic [6:0]         w_cost [24];
  logic [15:0]        est_dc;
  logic [2:0]         nb_dc;
  logic               r1_v;
  logic [6:0]         r1_cost [4];
  logic               r1_nz;
  logic               r1_sat;
  logic               r1_row3;
  logic [5:0]         w_sat;
  logic [5:0]         w_nz;
  logic [5:0]         nb_q;
  logic               blk_nz;
  logic [15:0]        est_tot;

  // Rebuild path.
  logic               iq_in_v;
  logic               iq_in_first;
  logic [47:0]        iq_in_lvl;
  logic [19:0]        iq_in_dc;
  logic [7:0]         iq_in_tag;
  logic [5:0]         iq_in_qp;
  logic               iq_out_v;
  logic [1:0]         iq_out_row;
  logic [63:0]        iq_out_res;
  logic [7:0]         iq_out_tag;
  logic [1:0]         iq_out_pl;
  logic [1:0]         iq_out_sg;
  logic [3:0]         iq_out_yy;
  logic [1:0]         s1_pl;
  logic [1:0]         s1_sg;
  logic [3:0]         s1_yy;
  logic               p3_s1_v;
  logic [4:0]         p3_s1_b;
  logic [1:0]         p3_s1_r;
  logic [6:0]         p3_n;
  logic               e1_v, e2_v;
  logic [4:0]         e1_b, e2_b;
  logic [1:0]         e1_r, e2_r;
  logic [63:0]        e1_res, e2_res;
  logic [6:0]         wr_cnt;

  // Chosen-prediction samples of the current delayed item.
  logic [31:0]        p_luma_sel;
  logic [31:0]        p_chroma_sel;

  // ---------------------------------------------------------------------------
  // Item decode: item n = 4 * block + row; blocks 0..15 luma raster, 16..19 Cb, 20..23 Cr
  // ---------------------------------------------------------------------------
  function automatic logic [1:0] blk_plane(input logic [4:0] b);
    if (b < 5'd16)      return 2'd0;
    else if (b < 5'd20) return 2'd1;
    else                return 2'd2;
  endfunction

  function automatic logic [1:0] blk_seg(input logic [4:0] b);
    if (b < 5'd16) return b[1:0];
    else           return {1'b0, b[0]};
  endfunction

  function automatic logic [3:0] blk_y(input logic [4:0] b, input logic [1:0] r);
    if (b < 5'd16) return {b[3:2], r};
    else           return {1'b0, b[1], r};
  endfunction

  assign it_b     = iss_n[6:2];
  assign it_r     = iss_n[1:0];
  assign it_plane = blk_plane(it_b);
  assign it_y     = blk_y(it_b, it_r);
  assign it_addr  = sbase_q + ((it_plane == 2'd0) ? SRC_AW'(it_y) : (SRC_AW'(16) + SRC_AW'(it_y[2:0])));

  // Level cost estimate in bits: 0 for a zero level, else a table by the bit length of |level| (1 .. 12).
  function automatic logic [6:0] lcost(input logic signed [11:0] l);
    logic [11:0] m;
    logic [3:0]  bl;
    m  = l[11] ? 12'(-l) : 12'(l);
    bl = 4'd0;
    for (int i = 0; i < 12; i++) if (m[i]) bl = 4'(i + 1);
    case (bl)
      4'd0:    return 7'd0;
      4'd1:    return 7'd1;
      4'd2:    return 7'd5;
      4'd3:    return 7'd5;
      4'd4:    return 7'd6;
      4'd5:    return 7'd13;
      4'd6:    return 7'd16;
      4'd7:    return 7'd16;
      4'd8:    return 7'd18;
      4'd9:    return 7'd34;
      default: return 7'd71;
    endcase
  endfunction

  // A level at the baseline limit (the quantizer clamps to +-2047): the macroblock cannot be coded faithfully.
  function automatic logic lsat(input logic signed [11:0] l);
    return (l == 12'sh7FF) || (l == 12'sh801) || (l == 12'sh800);
  endfunction

  function automatic logic sat4(input logic [47:0] w);
    logic r;
    r = 1'b0;
    for (int i = 0; i < 4; i++) r = r | lsat(w[12*i +: 12]);
    return r;
  endfunction

  // Source segment (4 bytes) of an item from the source word.
  function automatic logic [31:0] seg_bytes(input logic [127:0] w, input logic [4:0] b);
    logic [1:0] pl;
    logic [1:0] sg;
    pl = blk_plane(b);
    sg = blk_seg(b);
    case (pl)
      2'd0:    return w[32*sg +: 32];
      2'd1:    return w[32*sg[0] +: 32];
      default: return w[64 + 32*sg[0] +: 32];
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Issue control and stage 1
  // ---------------------------------------------------------------------------
  // Source read: issue phases (SAD, PASS1) and the PCM copy.
  logic              pcm_rd_en;
  logic [SRC_AW-1:0] pcm_rd_addr;
  assign src_rd_en   = iss_run || pcm_rd_en;
  assign src_rd_addr = iss_run ? it_addr : pcm_rd_addr;

  assign s1_src = seg_bytes(src_rd_data, s1_b);

  // ipred query: from stage 1 (SAD, PASS1) or from the inverse-transform output (PASS3).
  always_comb begin
    if (sel_p3) begin
      ip_q_valid = iq_out_v;
      ip_q_plane = iq_out_pl;
      ip_q_seg   = iq_out_sg;
      ip_q_y     = iq_out_yy;
      ip_q_src   = 32'd0;
      ip_q_acc   = 1'b0;
    end else begin
      ip_q_valid = s1_v;
      ip_q_plane = s1_pl;
      ip_q_seg   = s1_sg;
      ip_q_y     = s1_yy;
      ip_q_src   = s1_src;
      ip_q_acc   = s1_acc;
    end
  end

  // Chosen predictions of the delayed item.
  assign p_luma_sel   = ip_p_px[32*lm_q +: 32];
  assign p_chroma_sel = ip_p_px[32*cm_q +: 32];

  // Residual of the delayed item (PASS1): 4 x signed 9 bit.
  logic [35:0] res_d2;
  logic [31:0] p_d2_sel;
  assign p_d2_sel = (blk_plane(d2_b) == 2'd0) ? p_luma_sel : p_chroma_sel;
  always_comb begin
    for (int i = 0; i < 4; i++) begin
      res_d2[9*i +: 9] = 9'(signed'({1'b0, d2_src[8*i +: 8]}) - signed'({1'b0, p_d2_sel[8*i +: 8]}));
    end
  end

  // Reconstructed word of the delayed rebuild item (PASS3): clip(pred + residual).
  logic [31:0] rec_word;
  logic [31:0] p_e2_sel;
  assign p_e2_sel = (blk_plane(e2_b) == 2'd0) ? p_luma_sel : p_chroma_sel;
  always_comb begin
    for (int i = 0; i < 4; i++) begin
      logic signed [17:0] v;
      v = 18'(signed'({1'b0, p_e2_sel[8*i +: 8]})) + 18'(signed'(e2_res[16*i +: 16]));
      if (v < 18'sd0)        rec_word[8*i +: 8] = 8'd0;
      else if (v > 18'sd255) rec_word[8*i +: 8] = 8'd255;
      else                   rec_word[8*i +: 8] = v[7:0];
    end
  end

  // ---------------------------------------------------------------------------
  // Rebuilt RAM write address and neighbour capture
  // ---------------------------------------------------------------------------
  logic [REC_AW-1:0] e2_waddr;
  logic [1:0]        e2_plane;
  logic [1:0]        e2_seg;
  logic [3:0]        e2_y;
  assign e2_plane = blk_plane(e2_b);
  assign e2_seg   = blk_seg(e2_b);
  assign e2_y     = blk_y(e2_b, e2_r);
  always_comb begin
    case (e2_plane)
      2'd0:    e2_waddr = rbase_q + REC_AW'({e2_y, 2'b00} + {2'b00, e2_seg});
      2'd1:    e2_waddr = rbase_q + REC_AW'(7'd64 + {3'b000, e2_y[2:0], 1'b0} + {6'd0, e2_seg[0]});
      default: e2_waddr = rbase_q + REC_AW'(7'd80 + {3'b000, e2_y[2:0], 1'b0} + {6'd0, e2_seg[0]});
    endcase
  end

  logic [REC_AW-1:0] pcm_waddr;
  logic [127:0]      pcm_data;
  logic [4:0]        pcm_w;
  logic [2:0]        pcm_ph;
  logic [1:0]        pcm_q4;
  logic              pcm_wr;

  // PCM copy write: phases 3..6 write quarter pcm_ph - 3 of the captured source word pcm_w.
  assign pcm_wr    = (st == S_PCM) && (pcm_ph >= 3'd3);
  assign pcm_q4    = 2'(pcm_ph - 3'd3);
  assign reb_we    = e2_v || pcm_wr;
  assign reb_waddr = (st == S_PCM) ? pcm_waddr : e2_waddr;
  assign reb_wdata = (st == S_PCM) ? pcm_data[32*pcm_q4 +: 32] : rec_word;

  // Word index of the quarter in the rebuilt layout (and in the coefficient RAM copy read by stage B): luma 4 * y + bx,
  // Cb 64 + 2 * y + bx, Cr 80 + 2 * y + bx; the index order is the I_PCM sample order of the stream.
  logic [6:0] pcm_idx;
  always_comb begin
    if (pcm_w < 5'd16)   pcm_idx = {1'b0, pcm_w[3:0], pcm_q4};
    else if (!pcm_q4[1]) pcm_idx = 7'd64 + {3'b000, pcm_w[2:0], 1'b0} + {6'd0, pcm_q4[0]};
    else                 pcm_idx = 7'd80 + {3'b000, pcm_w[2:0], 1'b0} + {6'd0, pcm_q4[0]};
    pcm_waddr = rbase_q + REC_AW'(pcm_idx);
  end

  // ---------------------------------------------------------------------------
  // Line RAM (rebuilt bottom rows of the previous macroblock row)
  // ---------------------------------------------------------------------------
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(LINE_AW), .READ_LATENCY(1)) u_line (
    .wr_clk(clk), .wr_en(lr_we), .wr_addr(lr_waddr), .wr_data(lr_wdata),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(lr_rd_en), .rd_addr(lr_raddr), .rd_data(lr_rdata)
  );

  assign lr_rd_en  = (st == S_TOP) && (cnt[2:0] <= 3'd1);
  assign lr_raddr  = {x_q[LINE_AW-2:0], cnt[0]};
  assign lr_we     = (st == S_LINE) && (cnt[1:0] <= 2'd1);
  assign lr_waddr  = {x_q[LINE_AW-2:0], cnt[0]};
  assign lr_wdata  = cnt[0] ? bot_c : bot_y;

  // ---------------------------------------------------------------------------
  // Datapath units
  // ---------------------------------------------------------------------------
  rtlnet_h264_ipred u_ipred (
    .clk(clk), .resetn(resetn),
    .nb_load(ip_nb_load), .nb_top_y(top_y), .nb_left_y(left_y), .nb_tl_y(tl_y), .nb_top_c(top_c), .nb_left_c(left_c),
    .nb_tl_cb(tl_cb), .nb_tl_cr(tl_cr), .nb_av_top(avt_q), .nb_av_left(avl_q),
    .prep_done(ip_prep_done),
    .q_valid(ip_q_valid), .q_plane(ip_q_plane), .q_seg(ip_q_seg), .q_y(ip_q_y), .q_src(ip_q_src), .q_acc(ip_q_acc),
    .p_valid(ip_p_valid), .p_px(ip_p_px),
    .dec_start(ip_dec_start), .dec_done(ip_dec_done), .dec_luma_mode(ip_dec_lm), .dec_chroma_mode(ip_dec_cm),
    .sad_y(ip_sad_y), .sad_c(ip_sad_c)
  );

  rtlnet_h264_fwdq u_fwdq (
    .clk(clk), .resetn(resetn),
    .qp(fq_in_qp), .in_valid(fq_in_v), .in_first(fq_in_first), .in_res(fq_in_res), .in_tag(fq_in_tag),
    .out_valid(fq_out_v), .out_row(fq_out_row), .out_lvl(fq_out_lvl), .out_dc_valid(fq_out_dcv), .out_dc(fq_out_dc),
    .out_tag(fq_out_tag)
  );

  rtlnet_h264_invq u_invq (
    .clk(clk), .resetn(resetn),
    .qp(iq_in_qp), .in_valid(iq_in_v), .in_first(iq_in_first), .in_lvl(iq_in_lvl), .in_dc(iq_in_dc), .in_tag(iq_in_tag),
    .out_valid(iq_out_v), .out_row(iq_out_row), .out_res(iq_out_res), .out_tag(iq_out_tag),
    .out_pl(iq_out_pl), .out_sg(iq_out_sg), .out_yy(iq_out_yy)
  );

  rtlnet_h264_dcq_luma u_dcq_y (
    .clk(clk), .resetn(resetn), .start(dqy_start), .qp(qp_q), .w_in(dcw_y),
    .busy(dqy_busy), .done(dqy_done), .lvl_out(dqy_lvl), .nz(dqy_nz), .dc_out(dqy_dc)
  );
  rtlnet_h264_dcq_chroma u_dcq_cb (
    .clk(clk), .resetn(resetn), .start(dqc_start), .qpc(qpc_q), .w_in(dcw_cb),
    .busy(dqcb_busy), .done(dqcb_done), .lvl_out(dqcb_lvl), .nz(dqcb_nz), .dc_out(dqcb_dc)
  );
  rtlnet_h264_dcq_chroma u_dcq_cr (
    .clk(clk), .resetn(resetn), .start(dqc_start), .qpc(qpc_q), .w_in(dcw_cr),
    .busy(dqcr_busy), .done(dqcr_done), .lvl_out(dqcr_lvl), .nz(dqcr_nz), .dc_out(dqcr_dc)
  );

  // Busy outputs of the units are not needed: the done pulses are latched.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = dqy_busy | dqcb_busy | dqcr_busy | ip_p_valid | dqy_nz | (|fq_out_tag[7:5]) | (|iq_out_tag[7:5]) | mb_x[7];
  /* verilator lint_on UNUSEDSIGNAL */

  // DC for an invq input block.
  always_comb begin
    iq_in_dc = 20'sd0;
    if (p3_s1_b < 5'd16)      iq_in_dc = dqy_dc[20*p3_s1_b[3:0] +: 20];
    else if (p3_s1_b < 5'd20) iq_in_dc = dqcb_dc[20*p3_s1_b[1:0] +: 20];
    else                      iq_in_dc = dqcr_dc[20*p3_s1_b[1:0] +: 20];
  end

  assign iq_in_v     = p3_s1_v;
  assign iq_in_first = (p3_s1_r == 2'd0);
  assign iq_in_lvl   = cof_rdata;
  assign iq_in_tag   = {3'd0, p3_s1_b};
  assign iq_in_qp    = (p3_s1_b < 5'd16) ? qp_q : qpc_q;

  assign cof_rd_en   = p3_run;
  assign cof_raddr   = cbase_q + CRAM_AW'(p3_n) + CRAM_AW'(4);

  // Forward path write into the coefficient RAM and DC bookkeeping.
  logic [CRAM_AW-1:0] cof_waddr_p1;
  assign cof_waddr_p1 = cbase_q + CRAM_AW'(8'd4 + {fq_out_tag[4:0], 2'b00} + {6'd0, fq_out_row});
  always_comb begin
    cof_we    = fq_out_v;
    cof_waddr = cof_waddr_p1;
    cof_wdata = fq_out_lvl;
    if (st == S_PCM) begin
      // I_PCM: the sample words (first sample in the top byte) for stage B, in stream order.
      cof_we    = pcm_wr;
      cof_waddr = cbase_q + CRAM_AW'(pcm_idx);
      cof_wdata = {16'd0, pcm_data[32*pcm_q4 +: 8], pcm_data[32*pcm_q4 + 8 +: 8], pcm_data[32*pcm_q4 + 16 +: 8], pcm_data[32*pcm_q4 + 24 +: 8]};
    end
    if (st == S_DCW) begin
      cof_we = 1'b1;
      case (dcw_n)
        3'd0:    begin cof_waddr = cbase_q + CRAM_AW'(0); cof_wdata = dqy_lvl[0 +: 48]; end
        3'd1:    begin cof_waddr = cbase_q + CRAM_AW'(1); cof_wdata = dqy_lvl[48 +: 48]; end
        3'd2:    begin cof_waddr = cbase_q + CRAM_AW'(2); cof_wdata = dqy_lvl[96 +: 48]; end
        3'd3:    begin cof_waddr = cbase_q + CRAM_AW'(3); cof_wdata = dqy_lvl[144 +: 48]; end
        3'd4:    begin cof_waddr = cbase_q + CRAM_AW'(100); cof_wdata = dqcb_lvl; end
        default: begin cof_waddr = cbase_q + CRAM_AW'(101); cof_wdata = dqcr_lvl; end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Sequencing
  // ---------------------------------------------------------------------------
  assign busy = (st != S_IDLE);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      st          <= S_IDLE;
      cnt         <= '0;
      iss_n       <= '0;
      iss_run     <= 1'b0;
      p3_run      <= 1'b0;
      sel_p3      <= 1'b0;
      x_q         <= '0;
      avt_q       <= 1'b0;
      avl_q       <= 1'b0;
      qp_q        <= '0;
      qpc_q       <= '0;
      sbase_q     <= '0;
      rbase_q     <= '0;
      cbase_q     <= '0;
      done        <= 1'b0;
      o_i16_mode  <= '0;
      o_chroma_mode <= '0;
      o_cbp_chroma <= '0;
      o_cbp_luma  <= 1'b0;
      o_pcm       <= 1'b0;
      est_q       <= '0;
      ovf_q       <= 1'b0;
      w_sat       <= '0;
      w_nz        <= '0;
      nb_q        <= '0;
      blk_nz      <= 1'b0;
      est_tot     <= '0;
      top_y       <= '0;
      top_c       <= '0;
      left_y      <= '0;
      left_c      <= '0;
      tl_y        <= '0;
      tl_cb       <= '0;
      tl_cr       <= '0;
      tln_y       <= '0;
      tln_cb      <= '0;
      tln_cr      <= '0;
      bot_y       <= '0;
      bot_c       <= '0;
      ip_nb_load  <= 1'b0;
      ip_dec_start <= 1'b0;
      lm_q        <= '0;
      cm_q        <= '0;
      s1_v        <= 1'b0;
      s1_b        <= '0;
      s1_r        <= '0;
      s1_acc      <= 1'b0;
      s1_pl       <= '0;
      s1_sg       <= '0;
      s1_yy       <= '0;
      d1_v        <= 1'b0;
      d2_v        <= 1'b0;
      d1_b        <= '0;
      d2_b        <= '0;
      d1_r        <= '0;
      d2_r        <= '0;
      d1_src      <= '0;
      d2_src      <= '0;
      fq_in_v     <= 1'b0;
      fq_in_first <= 1'b0;
      fq_in_res   <= '0;
      fq_in_tag   <= '0;
      fq_in_qp    <= '0;
      dcw_y       <= '0;
      dcw_cb      <= '0;
      dcw_cr      <= '0;
      dc_cnt      <= '0;
      fq_rows     <= '0;
      ac_nz_y     <= 1'b0;
      ac_nz_c     <= 1'b0;
      dqy_start   <= 1'b0;
      dqc_start   <= 1'b0;
      dqy_done_q  <= 1'b0;
      dqcb_done_q <= 1'b0;
      dqcr_done_q <= 1'b0;
      dcw_n       <= '0;
      for (int i = 0; i < 6; i++) w_est[i] <= '0;
      for (int i = 0; i < 24; i++) w_cost[i] <= '0;
      est_dc      <= '0;
      nb_dc       <= '0;
      r1_v        <= 1'b0;
      for (int i = 0; i < 4; i++) r1_cost[i] <= '0;
      r1_nz       <= 1'b0;
      r1_sat      <= 1'b0;
      r1_row3     <= 1'b0;
      p3_s1_v     <= 1'b0;
      p3_s1_b     <= '0;
      p3_s1_r     <= '0;
      p3_n        <= '0;
      e1_v        <= 1'b0;
      e2_v        <= 1'b0;
      e1_b        <= '0;
      e2_b        <= '0;
      e1_r        <= '0;
      e2_r        <= '0;
      e1_res      <= '0;
      e2_res      <= '0;
      wr_cnt      <= '0;
      pcm_rd_en   <= 1'b0;
      pcm_rd_addr <= '0;
      pcm_data    <= '0;
      pcm_w       <= '0;
      pcm_ph      <= '0;
    end else begin
      done         <= 1'b0;
      ip_nb_load   <= 1'b0;
      ip_dec_start <= 1'b0;
      dqy_start    <= 1'b0;
      dqc_start    <= 1'b0;
      pcm_rd_en    <= 1'b0;

      // Stage 1 of the issue pipeline and the two delay stages (PASS1 residual alignment).
      s1_v   <= iss_run;
      s1_b   <= it_b;
      s1_r   <= it_r;
      s1_acc <= (st == S_SAD);
      s1_pl  <= it_plane;
      s1_sg  <= blk_seg(it_b);
      s1_yy  <= it_y;
      d1_v   <= s1_v && !s1_acc;
      d1_b   <= s1_b;
      d1_r   <= s1_r;
      d1_src <= s1_src;
      d2_v   <= d1_v;
      d2_b   <= d1_b;
      d2_r   <= d1_r;
      d2_src <= d1_src;

      // Forward transform input register (PASS1).
      fq_in_v     <= d2_v;
      fq_in_first <= (d2_r == 2'd0);
      fq_in_res   <= res_d2;
      fq_in_tag   <= {3'd0, d2_b};
      fq_in_qp    <= (d2_b < 5'd16) ? qp_q : qpc_q;

      // Forward transform outputs: DC capture, nonzero flags, DC unit starts.
      if (fq_out_dcv) begin
        dc_cnt <= dc_cnt + 5'd1;
        if (fq_out_tag[4:0] < 5'd16)      dcw_y[16*fq_out_tag[3:0] +: 16] <= fq_out_dc;
        else if (fq_out_tag[4:0] < 5'd20) dcw_cb[16*fq_out_tag[1:0] +: 16] <= fq_out_dc;
        else                              dcw_cr[16*fq_out_tag[1:0] +: 16] <= fq_out_dc;
        if (dc_cnt == 5'd15) dqy_start <= 1'b1;
        if (dc_cnt == 5'd23) dqc_start <= 1'b1;
      end
      if (fq_out_v) begin
        fq_rows <= fq_rows + 7'd1;
        if (fq_out_tag[4:0] < 5'd16) begin
          if (|fq_out_lvl) ac_nz_y <= 1'b1;
        end else begin
          if (|fq_out_lvl) ac_nz_c <= 1'b1;
        end
      end
      // Size estimate and saturation flag of the rows, one stage behind the quantizer: the level costs are registered, then
      // summed into the macroblock estimate. Rows of one block come one after the other, row 3 closes the block.
      r1_v    <= fq_out_v;
      r1_nz   <= |fq_out_lvl;
      r1_sat  <= sat4(fq_out_lvl);
      r1_row3 <= (fq_out_row == 2'd3);
      for (int i = 0; i < 4; i++) r1_cost[i] <= lcost(fq_out_lvl[12*i +: 12]);
      if (r1_v) begin
        est_q <= est_q + 16'(r1_cost[0]) + 16'(r1_cost[1]) + 16'(r1_cost[2]) + 16'(r1_cost[3]);
        if (r1_sat) ovf_q <= 1'b1;
        if (r1_row3) begin
          blk_nz <= 1'b0;
          if (blk_nz || r1_nz) nb_q <= nb_q + 6'd1;
        end else if (r1_nz) begin
          blk_nz <= 1'b1;
        end
      end
      if (dqy_done)  dqy_done_q  <= 1'b1;
      if (dqcb_done) dqcb_done_q <= 1'b1;
      if (dqcr_done) dqcr_done_q <= 1'b1;

      // Rebuild pipeline (PASS3): coefficient row read, inverse transform input, delay of the residual.
      p3_s1_v <= p3_run;
      p3_s1_b <= p3_n[6:2];
      p3_s1_r <= p3_n[1:0];
      if (p3_run) begin
        if (p3_n == 7'd95) p3_run <= 1'b0;
        p3_n <= p3_n + 7'd1;
      end
      e1_v   <= iq_out_v;
      e1_b   <= iq_out_tag[4:0];
      e1_r   <= iq_out_row;
      e1_res <= iq_out_res;
      e2_v   <= e1_v;
      e2_b   <= e1_b;
      e2_r   <= e1_r;
      e2_res <= e1_res;
      if (e2_v) begin
        wr_cnt <= wr_cnt + 7'd1;
        // Left column (right column of the macroblock) and bottom row capture.
        if (e2_plane == 2'd0) begin
          if (e2_seg == 2'd3) left_y[8*e2_y +: 8] <= rec_word[31:24];
          if (e2_y[3:2] == 2'd3 && e2_r == 2'd3) bot_y[32*e2_seg +: 32] <= rec_word;
        end else begin
          if (e2_seg[0]) begin
            if (e2_plane == 2'd1) left_c[8*e2_y[2:0] +: 8]      <= rec_word[31:24];
            else                  left_c[64 + 8*e2_y[2:0] +: 8] <= rec_word[31:24];
          end
          if (e2_y[2] && e2_r == 2'd3) begin
            if (e2_plane == 2'd1) bot_c[32*e2_seg[0] +: 32]      <= rec_word;
            else                  bot_c[64 + 32*e2_seg[0] +: 32] <= rec_word;
          end
        end
      end

      // I_PCM copy: left column and bottom row capture of the rebuilt macroblock.
      if (pcm_wr) begin
        if (!pcm_idx[6]) begin
          if (pcm_idx[1:0] == 2'd3) left_y[8*pcm_idx[5:2] +: 8] <= pcm_data[32*pcm_q4 + 24 +: 8];
          if (pcm_idx[5:2] == 4'd15) bot_y[32*pcm_idx[1:0] +: 32] <= pcm_data[32*pcm_q4 +: 32];
        end else begin
          if (pcm_idx[0]) begin
            if (!pcm_idx[4]) left_c[8*pcm_idx[3:1] +: 8]      <= pcm_data[32*pcm_q4 + 24 +: 8];
            else             left_c[64 + 8*pcm_idx[3:1] +: 8] <= pcm_data[32*pcm_q4 + 24 +: 8];
          end
          if (pcm_idx[3:1] == 3'd7) begin
            if (!pcm_idx[4]) bot_c[32*pcm_idx[0] +: 32]      <= pcm_data[32*pcm_q4 +: 32];
            else             bot_c[64 + 32*pcm_idx[0] +: 32] <= pcm_data[32*pcm_q4 +: 32];
          end
        end
      end

      case (st)
        S_IDLE: begin
          if (start) begin
            x_q     <= mb_x[6:0];
            avt_q   <= av_top;
            avl_q   <= av_left;
            qp_q    <= qp;
            qpc_q   <= h264_qpc(qp);
            sbase_q <= src_base;
            rbase_q <= reb_base;
            cbase_q <= coef_base;
            cnt     <= '0;
            wr_cnt  <= '0;
            iss_n   <= '0;
            dc_cnt  <= '0;
            fq_rows <= '0;
            ac_nz_y <= 1'b0;
            ac_nz_c <= 1'b0;
            est_q   <= '0;
            nb_q    <= '0;
            blk_nz  <= 1'b0;
            ovf_q   <= 1'b0;
            o_pcm   <= pcm_mode;
            dqy_done_q  <= 1'b0;
            dqcb_done_q <= 1'b0;
            dqcr_done_q <= 1'b0;
            dcw_n   <= '0;
            p3_n    <= '0;
            pcm_w   <= '0;
            pcm_ph  <= '0;
            st      <= pcm_mode ? S_PCM : S_TOP;
          end
        end

        // Neighbour fetch: line RAM luma word (clk 0), chroma word (clk 1); data a clock later.
        S_TOP: begin
          cnt <= cnt + 8'd1;
          if (cnt == 8'd1) begin
            top_y <= lr_rdata;
            tl_y  <= tln_y;
            tl_cb <= tln_cb;
            tl_cr <= tln_cr;
            tln_y <= lr_rdata[127:120];
          end
          if (cnt == 8'd2) begin
            top_c  <= lr_rdata;
            tln_cb <= lr_rdata[63:56];
            tln_cr <= lr_rdata[127:120];
          end
          if (cnt == 8'd3) begin
            ip_nb_load <= 1'b1;
            st         <= S_PREP;
          end
        end

        S_PREP: begin
          if (ip_prep_done) begin
            iss_n   <= '0;
            cnt     <= '0;
            iss_run <= 1'b1;
            st      <= S_SAD;
          end
        end

        // SAD pass: 96 items, then wait for the pipeline to drain and decide.
        S_SAD: begin
          if (iss_run) begin
            if (iss_n == 7'd95) iss_run <= 1'b0;
            iss_n <= iss_n + 7'd1;
          end else begin
            cnt <= cnt + 8'd1;
            if (cnt == 8'd9) begin
              ip_dec_start <= 1'b1;
              st           <= S_DEC;
            end
          end
        end

        S_DEC: begin
          if (ip_dec_done) begin
            lm_q          <= ip_dec_lm;
            cm_q          <= ip_dec_cm;
            o_i16_mode    <= ip_dec_lm;
            o_chroma_mode <= ip_dec_cm;
            iss_n         <= '0;
            iss_run       <= 1'b1;
            cnt           <= '0;
            st            <= S_P1;
          end
        end

        S_P1: begin
          if (iss_run) begin
            if (iss_n == 7'd95) begin
              iss_run <= 1'b0;
              st      <= S_P1W;
            end
            iss_n <= iss_n + 7'd1;
          end
        end

        // Wait for all coefficient rows written and the three DC units finished.
        S_P1W: begin
          if ((fq_rows == 7'd96) && dqy_done_q && dqcb_done_q && dqcr_done_q) begin
            st    <= S_CHK;
            dcw_n <= '0;
          end
        end

        // Fallback decision, in five clocks: level costs of the DC levels, word sums, sum of the DC part, total, branch.
        S_CHK: begin
          for (int i = 0; i < 16; i++) w_cost[i] <= lcost(dqy_lvl[12*i +: 12]);
          for (int i = 0; i < 4; i++) begin
            w_cost[16 + i] <= lcost(dqcb_lvl[12*i +: 12]);
            w_cost[20 + i] <= lcost(dqcr_lvl[12*i +: 12]);
          end
          for (int i = 0; i < 4; i++) begin
            w_sat[i] <= sat4(dqy_lvl[48*i +: 48]);
            w_nz[i]  <= |dqy_lvl[48*i +: 48];
          end
          w_sat[4] <= sat4(dqcb_lvl);
          w_nz[4]  <= |dqcb_lvl;
          w_sat[5] <= sat4(dqcr_lvl);
          w_nz[5]  <= |dqcr_lvl;
          st       <= S_CHK2;
        end

        S_CHK2: begin
          for (int i = 0; i < 6; i++) begin
            w_est[i] <= 16'(w_cost[4*i]) + 16'(w_cost[4*i + 1]) + 16'(w_cost[4*i + 2]) + 16'(w_cost[4*i + 3]);
          end
          nb_dc <= 3'(|w_nz[3:0]) + 3'(w_nz[4]) + 3'(w_nz[5]);
          if (|w_sat) ovf_q <= 1'b1;
          st    <= S_CHK3;
        end

        S_CHK3: begin
          est_dc <= w_est[0] + w_est[1] + w_est[2] + w_est[3] + w_est[4] + w_est[5];
          st     <= S_CHK4;
        end

        S_CHK4: begin
          est_tot <= est_q + est_dc + 16'(EST_BASE) + 16'(EST_BLK) * (16'(nb_q) + 16'(nb_dc));
          st      <= S_CHK5;
        end

        S_CHK5: begin
          if (ovf_q || (est_tot > 16'(EST_LIMIT))) begin
            o_pcm  <= 1'b1;
            pcm_w  <= '0;
            pcm_ph <= '0;
            st     <= S_PCM;
          end else begin
            st <= S_DCW;
          end
        end

        S_DCW: begin
          dcw_n <= dcw_n + 3'd1;
          if (dcw_n == 3'd5) begin
            o_cbp_luma   <= ac_nz_y;
            o_cbp_chroma <= ac_nz_c ? 2'd2 : ((dqcb_nz || dqcr_nz) ? 2'd1 : 2'd0);
            p3_n         <= '0;
            p3_run       <= 1'b1;
            sel_p3       <= 1'b1;
            wr_cnt       <= '0;
            st           <= S_P3;
          end
        end

        S_P3: begin
          if (!p3_run) st <= S_P3W;
        end

        S_P3W: begin
          if (wr_cnt == 7'd96) begin
            sel_p3 <= 1'b0;
            cnt <= '0;
            st  <= S_LINE;
          end
        end

        S_LINE: begin
          cnt <= cnt + 8'd1;
          if (cnt == 8'd1) st <= S_DONE;
        end

        S_DONE: begin
          done <= 1'b1;
          st   <= S_IDLE;
        end

        // I_PCM debug mode: copy the 24 source words into the rebuilt RAM, 4 words per source word.
        // Phase 0 sets the read, 1 reads, 2 captures the word, 3..6 write the four quarters.
        S_PCM: begin
          case (pcm_ph)
            3'd0: begin
              pcm_rd_en   <= 1'b1;
              pcm_rd_addr <= sbase_q + SRC_AW'(pcm_w);
              pcm_ph      <= 3'd1;
            end
            3'd1: pcm_ph <= 3'd2;
            3'd2: begin
              pcm_data <= src_rd_data;
              pcm_ph   <= 3'd3;
            end
            3'd6: begin
              pcm_ph <= 3'd0;
              pcm_w  <= pcm_w + 5'd1;
              if (pcm_w == 5'd23) begin
                cnt <= '0;
                st  <= S_LINE;
              end
            end
            default: pcm_ph <= pcm_ph + 3'd1;
          endcase
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
