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
//   * Outputs for stage B with done: i16 prediction mode, chroma prediction mode, cbp_chroma (0..2), cbp_luma (0 or 1); for a
//     P macroblock also o_inter, o_skip, o_cbp4 (the luma 8x8 coded block pattern) and o_mvd_x / o_mvd_y.
//   * P pictures (phase 2c-1, p_pic): the candidates are P_Skip, P_L0_16x16 at the motion vector (0, 0) (the co-located macroblock
//     of the reference picture, read from the reference macroblock buffer through the ref_rd port), Intra16x16 and I_PCM.
//       Phase 2c-2: the vector is an integer vector chosen by the motion search (rtlnet_h264_search), the prediction buffer holds its
//              prediction; P_Skip needs the skip vector (exact, rtlnet_h264_mvctx) to equal that vector.
//       MD1/MD2 (3 clocks after the intra decision) compare the inter cost, SAD(source, reference) over luma and chroma (the
//              accumulators of rtlnet_h264_ipred, filled in the SAD phase next to the intra candidates) plus lambda(QP) times
//              the bits of mvd = mv - mvp, with the intra cost, the SAD plus mode cost of the best intra modes plus lambda times
//              INTRA_BIAS_BITS; ties go to inter. The plug for stage 2c-2 is the trio inter_mv (the vector), inter_sad (SAD at
//              that vector) and the mvd bits: the search result replaces inter_mv and inter_sad.
//       PASS1  an inter macroblock subtracts the reference instead of the intra prediction; rtlnet_h264_fwdq runs with in_inter
//              (rounding offset 1/6) and in_full for the 16 luma blocks (the DC position is quantized like the others; there is
//              no luma DC transform, its result is ignored). The chroma blocks and their DC units are as for intra.
//       PASS3  the rebuild adds the reference to the residual (rtlnet_h264_invq with in_full for luma).
//       cbp    luma bit g (8x8 block g in raster order) is set when a quantized level of one of its four 4x4 blocks is non-zero;
//              cbp_chroma as for intra. P_Skip is chosen when the inter candidate won, cbp is 0 and the skip motion vector
//              (clause 8.4.1.1, rtlnet_h264_mvctx) is (0, 0): with the reference prediction at mv (0, 0) the rebuilt macroblock
//              is the same macroblock. A skip motion vector other than (0, 0) forbids P_Skip in 2c-1 (the prediction would need
//              that vector); stage 2c-2 lifts the restriction.
//       Isolated coefficient elimination (inter macroblocks, an encoder choice): an inter macroblock whose residual consists of at
//              most DROP_LEVELS non-zero levels, all of magnitude 1, is coded with no residual: its levels are dropped (cbp 0, the
//              rebuild adds nothing to the prediction). Such levels are the requantization of the previous picture's quantization
//              error; at low QP their dequantized size is below one sample (the inverse transform rounds it away) and they would
//              repeat in every picture. A static scene codes as P_Skip with this rule, also in the first picture after an I picture.
//       The estimate of the fallback (CHK) excludes the luma DC unit for an inter macroblock; a macroblock above the limit is
//       coded as I_PCM like an intra one. rtlnet_h264_mvctx keeps the vectors of the neighbours (mvp for P_L0_16x16, the skip
//       vector) and is updated at the end of every macroblock of a P picture (intra and I_PCM macroblocks count as intra).
//   * 8x8 transform (T8 = 1, High profile seam, stage 3): when the picture's inter macroblocks use the 8x8 transform (t8_en) and the inter
//       candidate wins, the luma residual (source minus the prediction at the vector) goes to rtlnet_h264_hp on the tf_res stream instead of
//       through rtlnet_h264_fwdq: state S_T8S sends the 4 blocks of 8 rows (a source row and a prediction row are read per beat), PASS1 then runs
//       the chroma blocks only. The module answers on tf_sum (once, after the 4th block: non-zero mask, size estimate terms) with the coded
//       luma 8x8 pattern; the estimate, the I_PCM fallback and the isolated coefficient elimination use it with the chroma values. S_T8R takes
//       the rebuilt residual back (tf_rec) and writes the luma words (prediction plus residual, clipped, zero residual when the macroblock was
//       dropped) into the rebuilt RAM, then PASS3 rebuilds the chroma blocks; S_DRN takes and discards it when the macroblock falls back to I_PCM.
//       o_t8sub tells stage B (and the module) that the luma residual was submitted. With T8 = 0 nothing of this exists.
//   * Adaptive choice (stage 3a, T8 = 1 and the input t8_auto): the inter candidate that wins first sends a request beat on tf_res (tf_res_last
//       high, no residual) and the macroblock's residual (S_T8S as above); PASS1 then runs the chroma blocks (items 64..95) as above, and the
//       summary beat of the module carries its choice (tf_sum_data[26], 1 = the 4x4 transform). Chosen 8x8 (the module's rule, private to the module):
//       the macroblock continues as the 8x8 transform macroblock above (t8_use_q set when the summary is in). Chosen 4x4: state S_T8L runs PASS1 for
//       the luma blocks (items 0..63) as the 4x4 encoder does, the estimate, decisions, rebuild and descriptor are those of the 4x4 macroblock
//       (the module released its levels and sends no rebuilt residual; o_t8sub stays 1 so that the module's banks keep in step, o_t8use is 0).
//       Without t8_auto the 8x8 transform is used on every inter macroblock as in stage 3. o_t8use: the macroblock is coded with the 8x8 transform.
// Language: SystemVerilog-2012.
// Revision: 11-12-2026
//   * 11-09-2026: initial version; per-macroblock I_PCM fallback.
//   * 11-10-2026: phase 2c-1: P pictures (inter candidate, skip, inter residual and rebuild, motion vector context).
//   * 11-10-2026: phase 2c-2: the inter vector comes from the motion search (mv_in_x / mv_in_y); P_Skip at the exact skip vector.
//   * 11-12-2026: stage 3: 8x8 transform of inter luma on the High profile seam (parameter T8).
//   * 11-12-2026: stage 3a: adaptive choice of the transform per macroblock (t8_auto, request beat, S_T8L, o_t8use).
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_mb_enc #(
  parameter int    MAX_MB_W   = 120,
  parameter int    LINE_KB    = 4,        // line RAM: 2 words of 16 bytes per macroblock column
  parameter string RAM_STYLE  = "block",
  parameter int    SRC_AW     = 6,
  parameter int    REC_AW     = 8,
  parameter int    CRAM_AW    = 8,
  parameter int    REF_AW     = 6,
  parameter int    MV_LINE_KB = 1,
  parameter bit    T8         = 1'b0     // 1: the 8x8 transform of inter macroblocks on the tf_* streams (HIGH_PROFILE builds)
)(
  // Clock and synchronous active-low reset.
  input  logic                clk,
  input  logic                resetn,

  // Macroblock command, clk domain: start pulses one clock when idle. The values are sampled with start.
  input  logic                start,
  input  logic                pcm_mode,
  input  logic                p_pic,
  input  logic [7:0]          mb_x,
  input  logic                av_top,
  input  logic                av_left,
  input  logic                av_tr,
  input  logic [5:0]          qp,
  input  logic [SRC_AW-1:0]   src_base,
  input  logic [REC_AW-1:0]   reb_base,
  input  logic [CRAM_AW-1:0]  coef_base,
  input  logic [REF_AW-1:0]   ref_base,
  // The motion vector of the inter candidate (phase 2c-2): quarter samples, a multiple of 4 (integer vector); the prediction buffer
  // bank at ref_base holds the prediction at that vector. Valid from start until done.
  input  logic signed [13:0]  mv_in_x,
  input  logic signed [13:0]  mv_in_y,
  // High while the I_PCM copy needs the source read port's data to stay (the search stage must not read then).
  output logic                src_lock,
  output logic                busy,
  output logic                done,

  // Coding decisions for stage B, valid with done.
  output logic [1:0]          o_i16_mode,
  output logic [1:0]          o_chroma_mode,
  output logic [1:0]          o_cbp_chroma,
  output logic                o_cbp_luma,
  output logic                o_pcm,
  output logic                o_inter,
  output logic                o_skip,
  output logic [3:0]          o_cbp4,
  output logic signed [15:0]  o_mvd_x,
  output logic signed [15:0]  o_mvd_y,

  // 8x8 transform seam (T8 = 1; tie t8_en, tf_res_ready, tf_rec_valid, tf_rec_data, tf_sum_valid and tf_sum_data to 0 with T8 = 0).
  // t8_en: the picture's inter macroblocks use the 8x8 transform. o_t8sub: this macroblock submitted its luma residual (valid with done).
  // tf_res: 4 blocks x 8 beats, one row of 8 signed 9-bit residual samples per beat; tf_rec: the rebuilt residual in the same form;
  // tf_sum: one beat per submitted macroblock: [3:0] non-zero 8x8 blocks, [19:4] level cost sum, [20] a level above 1, [21] a clamped level,
  // [25:22] number of non-empty blocks, [26] the module's choice of the 4x4 transform (only after a request beat: tf_res_last high, no residual).
  // t8_auto: the picture lets the module choose the transform per macroblock. o_t8use: this macroblock is coded with the 8x8 transform.
  input  logic                t8_en,
  input  logic                t8_auto,
  output logic                o_t8sub,
  output logic                o_t8use,
  output logic                tf_res_valid,
  output logic                tf_res_last,
  input  logic                tf_res_ready,
  output logic [71:0]         tf_res_data,
  input  logic                tf_rec_valid,
  output logic                tf_rec_ready,
  input  logic [71:0]         tf_rec_data,
  input  logic                tf_sum_valid,
  input  logic [26:0]         tf_sum_data,

  // Prediction buffer read port (the motion search's prediction of this macroblock): ref_rd_data is valid the clock after ref_rd_en.
  output logic                ref_rd_en,
  output logic [REF_AW-1:0]   ref_rd_addr,
  input  logic [127:0]        ref_rd_data,

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

  // Inter decision: the intra candidate is charged INTRA_BIAS_BITS bits of rate (the larger mb_type and the intra mode fields of
  // a P slice, and a bias towards the reference so that a static scene codes as skip).
  localparam int INTRA_BIAS_BITS = 16;

  // Isolated coefficient elimination: an inter macroblock with at most DROP_LEVELS non-zero levels, all +-1, is coded without residual.
  localparam int DROP_LEVELS = 6;

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
  localparam logic [4:0] S_MD1   = 5'd18;
  localparam logic [4:0] S_MD2   = 5'd19;
  localparam logic [4:0] S_T8S   = 5'd20;   // 8x8 transform: send the luma residual
  localparam logic [4:0] S_T8R   = 5'd21;   // 8x8 transform: rebuild the luma
  localparam logic [4:0] S_DRN   = 5'd22;   // 8x8 transform: discard the rebuilt residual (I_PCM fallback)
  localparam logic [4:0] S_T8L   = 5'd23;   // adaptive choice: the module chose the 4x4 transform, PASS1 of the luma blocks

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
  logic [17:0]        ip_sad_iy;
  logic [17:0]        ip_sad_ic;
  logic [19:0]        ip_cost_y;
  logic [19:0]        ip_cost_c;

  // Inter decision (P pictures).
  logic               inter_q;
  logic [19:0]        cost_in;
  logic [19:0]        cost_ia;
  logic [3:0]         nz8;
  logic               drop_q;
  logic               big_q;
  logic [15:0]        lv_sum;
  logic [3:0]         nz8_e;
  logic               mv_ready;
  logic               mv_ready_seen;
  logic signed [13:0] mvp_x, mvp_y, skip_x, skip_y;
  // skip_zero of rtlnet_h264_mvctx is not used since 2c-2: the skip vector is compared with the search vector.
  /* verilator lint_off UNUSEDSIGNAL */
  logic               skip_zero;
  logic [3:0]         nb_unused;
  logic signed [13:0] nb_unused_v [8];
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [13:0] inter_mv_x, inter_mv_y;
  logic [17:0]        inter_sad;
  logic signed [15:0] mvd_x_w, mvd_y_w;     // registered mv - mvp (free running; both inputs are stable long before MD1)
  logic [6:0]         mvd_len_q;            // bits of the two se(v) codes of mvd
  logic [14:0]        rate_q;               // lambda x mvd bits
  logic [7:0]         lam;                  // registered lambda of the slice QP
  logic [31:0]        ref_s1;
  logic [31:0]        d1_ref, d2_ref, e2_ref;
  logic               fq_in_inter, fq_in_full;
  // 8x8 transform (T8): signals of the sub-units below.
  logic               t8_use_q;          // this macroblock sends its luma residual to the 8x8 transform (a register of g_t8, constant 0 with T8 = 0)
  /* verilator lint_off UNUSEDSIGNAL */   // used by g_t8 only
  logic               t8_use_clr;        // the macroblock starts: clear it
  logic               t8_use_set;        // the inter candidate won in a picture with the 8x8 transform: set it
  logic               t8_sub_set;        // ... and o_t8sub
  logic               t8_auto_mb;        // the macroblock asked the module for its choice (a g_t8 register)
  logic               t8_rej_q;          // the module chose the 4x4 transform for it (a g_t8 register)
  logic               t8_lum_q;          // the luma pass of the 4x4 transform has been started (a g_t8 register)
  logic               t8_acc_set;        // the module chose the 8x8 transform: the summary is in
  logic               p1w_ok;            // PASS1 of the macroblock's blocks is complete
  assign t8_use_clr = (st == S_IDLE) && start;
  assign t8_sub_set = (st == S_MD2) && t8_en && (cost_in <= cost_ia);
  assign t8_use_set = t8_sub_set && !t8_auto;
  /* verilator lint_on UNUSEDSIGNAL */
  logic               t8s_done;
  logic               t8r_done;
  logic               drn_done;
  logic               t8_sum_seen;
  logic [3:0]         t8_nz4;
  logic [15:0]        t8_cost;
  logic               t8_big;
  logic               t8_sat;
  logic [3:0]         t8_nblk;
  logic               t8_src_en;
  logic [SRC_AW-1:0]  t8_src_addr;
  logic               t8_ref_en;
  logic [REF_AW-1:0]  t8_ref_addr;
  logic               t8_wr_v;
  logic [REC_AW-1:0]  t8_wr_addr;
  logic [31:0]        t8_wr_data;
  logic [3:0]         t8_wr_y;
  logic [1:0]         t8_wr_bx;
  // The summary's terms for the macroblock's decisions (0 when the macroblock does not use the 8x8 transform).
  logic [15:0]        t8_cost_g;
  logic [15:0]        t8_nb4_g;
  logic               t8_sat_g;
  logic               t8_big_g;
  assign p1w_ok = (fq_rows == 7'd96) && dqy_done_q && dqcb_done_q && dqcr_done_q && (!o_t8sub || t8_sum_seen);
  assign t8_acc_set = T8 && (st == S_P1W) && p1w_ok && t8_auto_mb && !t8_lum_q && !t8_rej_q;
  assign t8_cost_g = (T8 && t8_use_q) ? t8_cost : 16'd0;
  assign t8_nb4_g  = (T8 && t8_use_q) ? {10'd0, t8_nblk, 2'b00} : 16'd0;
  assign t8_sat_g  = T8 && t8_use_q && t8_sat;
  assign t8_big_g  = T8 && t8_use_q && t8_big;
  logic               iq_in_full;
  logic               mv_upd;
  logic signed [13:0] mv_upd_x, mv_upd_y;

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

  // Reference macroblock buffer (the co-located rebuilt tiles, documentation section 7): luma row y at word y, the Cb tile at words
  // 16..19 (word 16 + k holds rows 2k and 2k + 1, the even row in the low 8 bytes), the Cr tile at words 20..23.
  function automatic logic [REF_AW-1:0] ref_word(input logic [1:0] pl, input logic [3:0] y);
    case (pl)
      2'd0:    return REF_AW'(y);
      2'd1:    return REF_AW'(5'd16) + REF_AW'(y[2:1]);
      default: return REF_AW'(5'd20) + REF_AW'(y[2:1]);
    endcase
  endfunction

  // The four reference samples of an item (plane, 4-sample segment, row) from the 128-bit buffer word.
  function automatic logic [31:0] ref_seg(input logic [127:0] w, input logic [1:0] pl, input logic [1:0] sg, input logic y0);
    if (pl == 2'd0) return w[32*sg +: 32];
    else            return w[64*y0 + 32*sg[0] +: 32];
  endfunction

  // Reference read: the item of the issue phases (SAD, PASS1) at the same time as the source read, or the item leaving the
  // inverse transform (PASS3) of an inter macroblock.
  assign ref_rd_en   = (iss_run && p_pic) || (sel_p3 && iq_out_v && inter_q) || (T8 && t8_ref_en);
  assign ref_rd_addr = (T8 && t8_ref_en) ? t8_ref_addr : (ref_base + (iss_run ? ref_word(it_plane, it_y) : ref_word(iq_out_pl, iq_out_yy)));
  assign ref_s1      = ref_seg(ref_rd_data, s1_pl, s1_sg, s1_yy[0]);

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
  assign src_rd_en   = iss_run || pcm_rd_en || (T8 && t8_src_en);
  assign src_rd_addr = iss_run ? it_addr : ((T8 && t8_src_en) ? t8_src_addr : pcm_rd_addr);

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
  assign p_d2_sel = inter_q ? d2_ref : ((blk_plane(d2_b) == 2'd0) ? p_luma_sel : p_chroma_sel);
  always_comb begin
    for (int i = 0; i < 4; i++) begin
      res_d2[9*i +: 9] = 9'(signed'({1'b0, d2_src[8*i +: 8]}) - signed'({1'b0, p_d2_sel[8*i +: 8]}));
    end
  end

  // Reconstructed word of the delayed rebuild item (PASS3): clip(pred + residual).
  logic [31:0] rec_word;
  logic [31:0] p_e2_sel;
  assign p_e2_sel = inter_q ? e2_ref : ((blk_plane(e2_b) == 2'd0) ? p_luma_sel : p_chroma_sel);
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
  assign reb_we    = e2_v || pcm_wr || (T8 && t8_wr_v);
  assign reb_waddr = (st == S_PCM) ? pcm_waddr : ((T8 && t8_wr_v) ? t8_wr_addr : e2_waddr);
  assign reb_wdata = (st == S_PCM) ? pcm_data[32*pcm_q4 +: 32] : ((T8 && t8_wr_v) ? t8_wr_data : rec_word);

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
  // Motion vector context and the inter candidate (P pictures)
  // ---------------------------------------------------------------------------
  // Stage 2c-2: the vector comes from the motion search (the prediction buffer holds the prediction at it); the cost is the SAD of that
  // prediction (luma and chroma, exact) plus lambda x the bits of mvd = mv - mvp with the exact predictor mvp of rtlnet_h264_mvctx.
  assign inter_mv_x = mv_in_x;
  assign inter_mv_y = mv_in_y;
  assign inter_sad  = ip_sad_iy + ip_sad_ic;
  // Rate pipeline (free running): mvd, its code lengths, lambda x bits. Phase 2c-1 computed it in MD1 in one clock (post-synthesis
  // WNS -2.9 ns); the inputs (mvp 5 clocks after start, the vector, QP) are stable far ahead of MD1, so the stages cost no clocks.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      mvd_x_w   <= 16'sd0;
      mvd_y_w   <= 16'sd0;
      mvd_len_q <= 7'd0;
      rate_q    <= 15'd0;
      lam       <= 8'd1;
    end else begin
      mvd_x_w   <= 16'(inter_mv_x) - 16'(mvp_x);
      mvd_y_w   <= 16'(inter_mv_y) - 16'(mvp_y);
      mvd_len_q <= 7'(h264_se_len(mvd_x_w)) + 7'(h264_se_len(mvd_y_w));
      lam       <= h264_lambda(qp_q);
      rate_q    <= 15'(lam) * 15'(mvd_len_q);
    end
  end
  assign mv_upd_x   = o_skip ? skip_x : inter_mv_x;
  assign mv_upd_y   = o_skip ? skip_y : inter_mv_y;
  assign mv_upd     = (st == S_DONE) && p_pic;

  rtlnet_h264_mvctx #(.MAX_MB_W(MAX_MB_W), .MV_LINE_KB(MV_LINE_KB), .RAM_STYLE(RAM_STYLE)) u_mvctx (
    .clk(clk), .resetn(resetn),
    .start(start && (st == S_IDLE) && p_pic), .mb_x(mb_x[6:0]), .av_top(av_top), .av_left(av_left), .av_tr(av_tr),
    .ready(mv_ready), .mvp_x(mvp_x), .mvp_y(mvp_y), .skip_x(skip_x), .skip_y(skip_y), .skip_zero(skip_zero),
    .nb_a_inter(nb_unused[0]), .nb_a_mvx(nb_unused_v[0]), .nb_a_mvy(nb_unused_v[1]), .nb_b_inter(nb_unused[1]), .nb_b_mvx(nb_unused_v[2]),
    .nb_b_mvy(nb_unused_v[3]), .nb_c_inter(nb_unused[2]), .nb_c_mvx(nb_unused_v[4]), .nb_c_mvy(nb_unused_v[5]), .nb_d_inter(nb_unused[3]),
    .nb_d_mvx(nb_unused_v[6]), .nb_d_mvy(nb_unused_v[7]),
    .upd(mv_upd), .upd_inter(o_inter), .upd_mvx(mv_upd_x), .upd_mvy(mv_upd_y)
  );

  // ---------------------------------------------------------------------------
  // Datapath units
  // ---------------------------------------------------------------------------
  rtlnet_h264_ipred u_ipred (
    .clk(clk), .resetn(resetn),
    .nb_load(ip_nb_load), .nb_top_y(top_y), .nb_left_y(left_y), .nb_tl_y(tl_y), .nb_top_c(top_c), .nb_left_c(left_c),
    .nb_tl_cb(tl_cb), .nb_tl_cr(tl_cr), .nb_av_top(avt_q), .nb_av_left(avl_q),
    .prep_done(ip_prep_done),
    .q_valid(ip_q_valid), .q_plane(ip_q_plane), .q_seg(ip_q_seg), .q_y(ip_q_y), .q_src(ip_q_src), .q_acc(ip_q_acc),
    .q_ref(ref_s1),
    .p_valid(ip_p_valid), .p_px(ip_p_px),
    .dec_start(ip_dec_start), .dec_done(ip_dec_done), .dec_luma_mode(ip_dec_lm), .dec_chroma_mode(ip_dec_cm),
    .sad_y(ip_sad_y), .sad_c(ip_sad_c), .sad_iy(ip_sad_iy), .sad_ic(ip_sad_ic),
    .dec_cost_y(ip_cost_y), .dec_cost_c(ip_cost_c)
  );

  rtlnet_h264_fwdq u_fwdq (
    .clk(clk), .resetn(resetn),
    .qp(fq_in_qp), .in_valid(fq_in_v), .in_first(fq_in_first), .in_res(fq_in_res), .in_tag(fq_in_tag),
    .in_inter(fq_in_inter), .in_full(fq_in_full),
    .out_valid(fq_out_v), .out_row(fq_out_row), .out_lvl(fq_out_lvl), .out_dc_valid(fq_out_dcv), .out_dc(fq_out_dc),
    .out_tag(fq_out_tag)
  );

  rtlnet_h264_invq u_invq (
    .clk(clk), .resetn(resetn),
    .qp(iq_in_qp), .in_valid(iq_in_v), .in_first(iq_in_first), .in_lvl(iq_in_lvl), .in_dc(iq_in_dc), .in_tag(iq_in_tag),
    .in_full(iq_in_full),
    .out_valid(iq_out_v), .out_row(iq_out_row), .out_res(iq_out_res), .out_tag(iq_out_tag),
    .out_pl(iq_out_pl), .out_sg(iq_out_sg), .out_yy(iq_out_yy)
  );

  rtlnet_h264_dcq_luma u_dcq_y (
    .clk(clk), .resetn(resetn), .start(dqy_start), .qp(qp_q), .w_in(dcw_y),
    .busy(dqy_busy), .done(dqy_done), .lvl_out(dqy_lvl), .nz(dqy_nz), .dc_out(dqy_dc)
  );
  rtlnet_h264_dcq_chroma u_dcq_cb (
    .clk(clk), .resetn(resetn), .start(dqc_start), .qpc(qpc_q), .inter(inter_q), .w_in(dcw_cb),
    .busy(dqcb_busy), .done(dqcb_done), .lvl_out(dqcb_lvl), .nz(dqcb_nz), .dc_out(dqcb_dc)
  );
  rtlnet_h264_dcq_chroma u_dcq_cr (
    .clk(clk), .resetn(resetn), .start(dqc_start), .qpc(qpc_q), .inter(inter_q), .w_in(dcw_cr),
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
    if (drop_q)               iq_in_dc = 20'sd0;
  end

  assign iq_in_v     = p3_s1_v;
  assign iq_in_first = (p3_s1_r == 2'd0);
  assign nz8_e       = drop_q ? 4'd0 : ((T8 && t8_use_q) ? t8_nz4 : nz8);
  assign iq_in_lvl   = drop_q ? 48'd0 : cof_rdata;
  assign iq_in_tag   = {3'd0, p3_s1_b};
  assign iq_in_full  = inter_q && (p3_s1_b < 5'd16);
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
  // 8x8 transform sub-units (T8 = 1): residual feeder (S_T8S), summary capture, rebuild of the luma (S_T8R), discard (S_DRN)
  // ---------------------------------------------------------------------------
  generate
    if (T8) begin : g_t8
      // The decision of the macroblock (set in S_MD2 without t8_auto, else when the module's choice is in; cleared at the start of the next
      // macroblock), the flag for stage B (the macroblock submitted its residual) and the request / choice bookkeeping of the adaptive mode.
      logic mk_pend;                  // the request beat has still to be sent
      logic res_last_q;
      assign o_t8use     = t8_use_q;
      assign tf_res_last = res_last_q;
      always_ff @(posedge clk) begin
        if (!resetn) begin
          t8_use_q   <= 1'b0;
          o_t8sub    <= 1'b0;
          t8_auto_mb <= 1'b0;
          t8_rej_q   <= 1'b0;
          t8_lum_q   <= 1'b0;
          mk_pend    <= 1'b0;
        end else begin
          if (t8_use_clr) begin
            t8_use_q   <= 1'b0;
            o_t8sub    <= 1'b0;
            t8_auto_mb <= 1'b0;
            t8_rej_q   <= 1'b0;
            t8_lum_q   <= 1'b0;
            mk_pend    <= 1'b0;
          end
          if (t8_sub_set) o_t8sub <= 1'b1;
          if (t8_use_set || t8_acc_set) t8_use_q <= 1'b1;
          if (t8_sub_set && t8_auto) begin
            t8_auto_mb <= 1'b1;
            mk_pend    <= 1'b1;
          end
          if (mk_pend && res_v && tf_res_ready && res_last_q) mk_pend <= 1'b0;
          if (tf_sum_valid && t8_auto_mb) t8_rej_q <= tf_sum_data[26];
          if (st == S_T8L) t8_lum_q <= 1'b1;
        end
      end

      // Summary of the module (one beat per submitted macroblock; cleared at the macroblock's start).
      always_ff @(posedge clk) begin
        if (!resetn) begin
          t8_sum_seen <= 1'b0;
          t8_nz4      <= '0;
          t8_cost     <= '0;
          t8_big      <= 1'b0;
          t8_sat      <= 1'b0;
          t8_nblk     <= '0;
        end else begin
          if ((st == S_IDLE) && start) t8_sum_seen <= 1'b0;
          if (tf_sum_valid) begin
            t8_sum_seen <= 1'b1;
            t8_nz4      <= tf_sum_data[3:0];
            t8_cost     <= tf_sum_data[19:4];
            t8_big      <= tf_sum_data[20];
            t8_sat      <= tf_sum_data[21];
            t8_nblk     <= tf_sum_data[25:22];
          end
        end
      end

      // Feeder: per beat one source row and one prediction row are read (one clock of latency), the 8 residual samples of the 8x8
      // block's half are registered and offered on tf_res until taken. Beat n: block n / 8 (raster order of the 8x8 blocks), row n % 8.
      logic [5:0] fd_cnt;
      logic [1:0] fd_ph;
      logic       res_v;
      logic [71:0] res_d;
      logic [3:0] fd_y;
      logic       fd_gx;
      logic       fd_rd;
      assign fd_y   = {fd_cnt[4], fd_cnt[2:0]};
      assign fd_gx  = fd_cnt[3];
      assign fd_rd  = (st == S_T8S) && !mk_pend && (fd_ph == 2'd0) && (fd_cnt != 6'd32);
      assign tf_res_valid = res_v;
      assign tf_res_data  = res_d;
      assign t8s_done     = (st == S_T8S) && (fd_cnt == 6'd32) && !res_v;

      always_ff @(posedge clk) begin
        if (!resetn || (st != S_T8S)) begin
          fd_cnt     <= 6'd0;
          fd_ph      <= 2'd0;
          res_v      <= 1'b0;
          res_last_q <= 1'b0;
        end else if (mk_pend) begin
          // The request beat (no residual) of the adaptive mode.
          if (!res_v) begin
            res_v      <= 1'b1;
            res_last_q <= 1'b1;
          end else if (tf_res_ready) begin
            res_v      <= 1'b0;
            res_last_q <= 1'b0;
          end
        end else begin
          case (fd_ph)
            2'd0: if (fd_cnt != 6'd32) fd_ph <= 2'd1;
            2'd1: begin
              res_v <= 1'b1;
              fd_ph <= 2'd2;
            end
            default: begin
              if (res_v && tf_res_ready) begin
                res_v  <= 1'b0;
                fd_cnt <= fd_cnt + 6'd1;
                fd_ph  <= 2'd0;
              end
            end
          endcase
        end
      end
      always_ff @(posedge clk) begin
        if (fd_ph == 2'd1) begin
          for (int j = 0; j < 8; j++) begin
            res_d[9*j +: 9] <= 9'(signed'({1'b0, src_rd_data[8*(8*int'(fd_gx) + j) +: 8]}) - signed'({1'b0, ref_rd_data[8*(8*int'(fd_gx) + j) +: 8]}));
          end
        end
      end

      // Rebuild: beats of the rebuilt residual are taken one at a time; the prediction row is read in the clock the beat is taken (data
      // valid the next clock, held until the next read), prediction plus residual is clipped into two words that are written in two clocks.
      logic [5:0]  rc_cnt;
      logic [5:0]  dn_cnt;
      logic        x1_v;
      logic [71:0] x1_d;
      logic [3:0]  x1_y;
      logic        x1_gx;
      logic        w_v;
      logic        w_ph;
      logic [3:0]  w_y;
      logic        w_gx;
      logic [63:0] w_data;
      logic        r_act, d_act, r_take, w_free;
      logic [3:0]  rc_y;
      assign r_act        = (st == S_T8R);
      assign d_act        = (st == S_DRN);
      assign rc_y         = {rc_cnt[4], rc_cnt[2:0]};
      assign tf_rec_ready = (r_act && !x1_v && (rc_cnt != 6'd32)) || (d_act && (dn_cnt != 6'd32));
      assign r_take       = r_act && tf_rec_valid && tf_rec_ready;
      assign w_free       = !w_v || w_ph;
      assign t8_src_en    = fd_rd;
      assign t8_src_addr  = sbase_q + SRC_AW'(fd_y);
      assign t8_ref_en    = fd_rd || r_take;
      assign t8_ref_addr  = ref_base + REF_AW'((st == S_T8S) ? fd_y : rc_y);
      assign t8r_done     = r_act && (rc_cnt == 6'd32) && !x1_v && !w_v;
      assign drn_done     = d_act && (dn_cnt == 6'd32);
      assign t8_wr_v      = w_v;
      assign t8_wr_y      = w_y;
      assign t8_wr_bx     = {w_gx, w_ph};
      assign t8_wr_addr   = rbase_q + REC_AW'({w_y, 2'b00}) + REC_AW'({w_gx, w_ph});
      assign t8_wr_data   = w_data[32*w_ph +: 32];

      always_ff @(posedge clk) begin
        if (!resetn || !(r_act || d_act)) begin
          rc_cnt <= 6'd0;
          dn_cnt <= 6'd0;
          x1_v   <= 1'b0;
          w_v    <= 1'b0;
          w_ph   <= 1'b0;
        end else begin
          if (d_act && tf_rec_valid && tf_rec_ready) dn_cnt <= dn_cnt + 6'd1;
          if (r_take) begin
            x1_v   <= 1'b1;
            rc_cnt <= rc_cnt + 6'd1;
          end
          if (x1_v && w_free) begin
            x1_v <= 1'b0;
            w_v  <= 1'b1;
            w_ph <= 1'b0;
          end else if (w_v) begin
            if (w_ph) w_v <= 1'b0;
            else      w_ph <= 1'b1;
          end
        end
      end
      always_ff @(posedge clk) begin
        if (r_take) begin
          x1_d  <= tf_rec_data;
          x1_y  <= rc_y;
          x1_gx <= rc_cnt[3];
        end
        if (x1_v && w_free) begin
          w_y  <= x1_y;
          w_gx <= x1_gx;
          for (int j = 0; j < 8; j++) begin
            logic signed [17:0] v;
            v = 18'(signed'({1'b0, ref_rd_data[8*(8*int'(x1_gx) + j) +: 8]})) + (drop_q ? 18'sd0 : 18'($signed(x1_d[9*j +: 9])));
            if (v < 18'sd0)        w_data[8*j +: 8] <= 8'd0;
            else if (v > 18'sd255) w_data[8*j +: 8] <= 8'd255;
            else                   w_data[8*j +: 8] <= v[7:0];
          end
        end
      end
    end else begin : g_no_t8
      assign t8_use_q     = 1'b0;
      assign o_t8sub      = 1'b0;
      assign o_t8use      = 1'b0;
      assign tf_res_last  = 1'b0;
      assign t8_auto_mb   = 1'b0;
      assign t8_rej_q     = 1'b0;
      assign t8_lum_q     = 1'b0;
      assign t8s_done     = 1'b0;
      assign t8r_done     = 1'b0;
      assign drn_done     = 1'b0;
      assign t8_sum_seen  = 1'b0;
      assign t8_nz4       = '0;
      assign t8_cost      = '0;
      assign t8_big       = 1'b0;
      assign t8_sat       = 1'b0;
      assign t8_nblk      = '0;
      assign t8_src_en    = 1'b0;
      assign t8_src_addr  = '0;
      assign t8_ref_en    = 1'b0;
      assign t8_ref_addr  = '0;
      assign t8_wr_v      = 1'b0;
      assign t8_wr_addr   = '0;
      assign t8_wr_data   = '0;
      assign t8_wr_y      = '0;
      assign t8_wr_bx     = '0;
      assign tf_res_valid = 1'b0;
      assign tf_res_data  = '0;
      assign tf_rec_ready = 1'b0;
      /* verilator lint_off UNUSEDSIGNAL */
      logic unused_t8;
      assign unused_t8 = &{1'b0, tf_res_ready, tf_rec_valid, tf_rec_data, tf_sum_valid, tf_sum_data, t8_en, t8_auto};
      /* verilator lint_on UNUSEDSIGNAL */
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Sequencing
  // ---------------------------------------------------------------------------
  assign busy = (st != S_IDLE);
  assign src_lock = (st == S_PCM);

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
      o_inter     <= 1'b0;
      o_skip      <= 1'b0;
      o_cbp4      <= '0;
      o_mvd_x     <= '0;
      o_mvd_y     <= '0;
      inter_q     <= 1'b0;
      cost_in     <= '0;
      cost_ia     <= '0;
      nz8         <= '0;
      drop_q      <= 1'b0;
      big_q       <= 1'b0;
      lv_sum      <= '0;
      mv_ready_seen <= 1'b0;
      d1_ref      <= '0;
      d2_ref      <= '0;
      e2_ref      <= '0;
      fq_in_inter <= 1'b0;
      fq_in_full  <= 1'b0;
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
      d1_ref <= ref_s1;
      d2_ref <= d1_ref;

      // Forward transform input register (PASS1).
      fq_in_v     <= d2_v;
      fq_in_first <= (d2_r == 2'd0);
      fq_in_res   <= res_d2;
      fq_in_tag   <= {3'd0, d2_b};
      fq_in_qp    <= (d2_b < 5'd16) ? qp_q : qpc_q;
      fq_in_inter <= inter_q;
      fq_in_full  <= inter_q && (d2_b < 5'd16);

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
          if (|fq_out_lvl) begin
            ac_nz_y <= 1'b1;
            nz8[{fq_out_tag[3], fq_out_tag[1]}] <= 1'b1;
          end
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
        if ((r1_cost[0] > 7'd1) || (r1_cost[1] > 7'd1) || (r1_cost[2] > 7'd1) || (r1_cost[3] > 7'd1)) big_q <= 1'b1;
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
      e2_ref <= ref_seg(ref_rd_data, blk_plane(e1_b), blk_seg(e1_b), blk_y(e1_b, e1_r)[0]);
      if (mv_ready) mv_ready_seen <= 1'b1;
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

      // 8x8 transform: left column and bottom row capture of the luma words written by S_T8R.
      if (T8 && t8_wr_v) begin
        if (t8_wr_bx == 2'd3) left_y[8*t8_wr_y +: 8] <= t8_wr_data[31:24];
        if (t8_wr_y == 4'd15) bot_y[32*t8_wr_bx +: 32] <= t8_wr_data;
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
            o_inter <= 1'b0;
            o_skip  <= 1'b0;
            inter_q <= 1'b0;
            nz8     <= '0;
            drop_q  <= 1'b0;
            big_q   <= 1'b0;
            mv_ready_seen <= 1'b0;
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
            cnt           <= '0;
            if (p_pic) begin
              st <= S_MD1;
            end else begin
              iss_run <= 1'b1;
              st      <= S_P1;
            end
          end
        end

        // Inter decision: cost of the reference at the vector against the best intra modes (3 clocks).
        S_MD1: begin
          cost_in <= 20'(inter_sad) + 20'(rate_q);
          cost_ia <= ip_cost_y + ip_cost_c + (20'(lam) << $clog2(INTRA_BIAS_BITS));
          st      <= S_MD2;
        end

        S_MD2: begin
          inter_q <= (cost_in <= cost_ia);
          o_inter <= (cost_in <= cost_ia);
          o_mvd_x <= mvd_x_w;
          o_mvd_y <= mvd_y_w;
          iss_n   <= '0;
          iss_run <= 1'b1;
          cnt     <= '0;
          st      <= S_P1;
          if (T8 && t8_en && (cost_in <= cost_ia)) begin
            // 8x8 transform: the luma residual goes to the module (S_T8S), PASS1 then runs the chroma blocks (items 64..95); there is no
            // luma DC unit result and the luma rows of the forward transform do not come.
            iss_run     <= 1'b0;
            st          <= S_T8S;
            fq_rows     <= 7'd64;
            dc_cnt      <= 5'd16;
            dqy_done_q  <= 1'b1;
          end
        end

        S_P1: begin
          if (iss_run) begin
            if (iss_n == ((T8 && t8_lum_q) ? 7'd63 : 7'd95)) begin
              iss_run <= 1'b0;
              st      <= S_P1W;
            end
            iss_n <= iss_n + 7'd1;
          end
        end

        // Wait for all coefficient rows written and the three DC units finished.
        S_P1W: begin
          if (p1w_ok) begin
            st    <= S_CHK;
            dcw_n <= '0;
          end
        end

        // Fallback decision, in five clocks: level costs of the DC levels, word sums, sum of the DC part, total, branch.
        S_CHK: begin
          // The luma DC unit's result does not exist for an inter macroblock (no luma DC transform): it counts as zero.
          for (int i = 0; i < 16; i++) w_cost[i] <= inter_q ? 7'd0 : lcost(dqy_lvl[12*i +: 12]);
          for (int i = 0; i < 4; i++) begin
            w_cost[16 + i] <= lcost(dqcb_lvl[12*i +: 12]);
            w_cost[20 + i] <= lcost(dqcr_lvl[12*i +: 12]);
          end
          for (int i = 0; i < 4; i++) begin
            w_sat[i] <= !inter_q && sat4(dqy_lvl[48*i +: 48]);
            w_nz[i]  <= !inter_q && (|dqy_lvl[48*i +: 48]);
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
          for (int i = 16; i < 24; i++) if (w_cost[i] > 7'd1) big_q <= 1'b1;
          st    <= S_CHK3;
        end

        S_CHK3: begin
          est_dc <= w_est[0] + w_est[1] + w_est[2] + w_est[3] + w_est[4] + w_est[5];
          st     <= S_CHK4;
        end

        S_CHK4: begin
          est_tot <= est_q + est_dc + t8_cost_g + 16'(EST_BASE) + 16'(EST_BLK) * (16'(nb_q) + 16'(nb_dc) + t8_nb4_g);
          lv_sum  <= est_q + est_dc + t8_cost_g;
          st      <= S_CHK5;
        end

        S_CHK5: begin
          if (ovf_q || t8_sat_g || (est_tot > 16'(EST_LIMIT))) begin
            o_pcm  <= 1'b1;
            o_inter <= 1'b0;
            o_skip <= 1'b0;
            inter_q <= 1'b0;
            pcm_w  <= '0;
            pcm_ph <= '0;
            st     <= (T8 && t8_use_q) ? S_DRN : S_PCM;
          end else begin
            drop_q <= inter_q && !big_q && !t8_big_g && (lv_sum <= 16'(DROP_LEVELS));
            st     <= S_DCW;
          end
        end

        S_DCW: begin
          dcw_n <= dcw_n + 3'd1;
          if (dcw_n == 3'd5) begin
            o_cbp_luma   <= ac_nz_y;
            o_cbp4       <= nz8_e;
            o_cbp_chroma <= drop_q ? 2'd0 : (ac_nz_c ? 2'd2 : ((dqcb_nz || dqcr_nz) ? 2'd1 : 2'd0));
            // P_Skip (clause 8.4.1.1): the inter candidate with nothing to code, and the skip vector equal to the vector of the prediction
            // (a decoder predicts a skipped macroblock at the skip vector; the search vector is inside the picture and the window, so the
            // skip vector is too when they are equal).
            o_skip       <= inter_q && (nz8_e == 4'd0) && (drop_q || (!ac_nz_c && !dqcb_nz && !dqcr_nz)) &&
                            (skip_x == inter_mv_x) && (skip_y == inter_mv_y);
            p3_n         <= (T8 && t8_use_q) ? 7'd64 : 7'd0;
            p3_run       <= !(T8 && t8_use_q);
            sel_p3       <= !(T8 && t8_use_q);
            wr_cnt       <= '0;
            st           <= (T8 && t8_use_q) ? S_T8R : S_P3;
          end
        end

        S_P3: begin
          if (!p3_run) st <= S_P3W;
        end

        S_P3W: begin
          if (wr_cnt == ((T8 && t8_use_q) ? 7'd32 : 7'd96)) begin
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

      // 8x8 transform states (T8 = 1 only). They are handled after the case statement, not as its items, so that with T8 = 0 the state machine
      // is the one of the Constrained Baseline encoder (the case's default sends them, unreachable, to S_IDLE); with T8 = 1 these assignments
      // come last and win over the default.
      if (T8) begin
        // The residual is sent; PASS1 of the chroma blocks follows.
        if ((st == S_T8S) && t8s_done) begin
          iss_n   <= 7'd64;
          iss_run <= 1'b1;
          cnt     <= '0;
          st      <= S_P1;
        end
        // The luma words of the rebuilt macroblock, then PASS3 of the chroma blocks.
        if ((st == S_T8R) && t8r_done) begin
          p3_run  <= 1'b1;
          sel_p3  <= 1'b1;
          st      <= S_P3;
        end
        // Adaptive choice: the module chose the 4x4 transform, so PASS1 of the luma blocks (items 0..63) still has to run, after the chroma blocks that
        // are done: the row and DC bookkeeping start like a 4x4 macroblock's (the chroma rows and DCs are in).
        if ((st == S_P1W) && p1w_ok && t8_auto_mb && !t8_lum_q && t8_rej_q) st <= S_T8L;
        if (st == S_T8L) begin
          iss_n      <= 7'd0;
          iss_run    <= 1'b1;
          cnt        <= '0;
          fq_rows    <= 7'd32;
          dc_cnt     <= 5'd0;
          dqy_done_q <= 1'b0;
          st         <= S_P1;
        end
        // I_PCM fallback: the rebuilt residual is taken and discarded, then the I_PCM copy.
        if ((st == S_DRN) && drn_done) st <= S_PCM;
        // The three states hold until their sub-unit is done (the case's default would send them to S_IDLE).
        if ((st == S_T8S) && !t8s_done) st <= S_T8S;
        if ((st == S_T8R) && !t8r_done) st <= S_T8R;
        if ((st == S_DRN) && !drn_done) st <= S_DRN;
      end
    end
  end

  // synthesis translate_off
  // The motion vector context (5 clocks) is ready long before the inter decision.
  always_ff @(posedge clk) begin
    if (resetn && (st == S_MD1) && !mv_ready_seen) $error("rtlnet_h264_mb_enc: motion vector context not ready at the inter decision");
  end
  // synthesis translate_on

endmodule
