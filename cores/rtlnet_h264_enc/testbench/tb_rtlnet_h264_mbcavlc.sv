// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_mbcavlc.sv
// Purpose: self-checking bench of rtlnet_h264_mb_cavlc (stage B): the macroblock layer of an Intra16x16, I_PCM, P_L0_16x16 or
//   P_Skip macroblock and its CAVLC residual, against a reference written in the bench from ITU-T Rec. H.264 clauses 7.3.4,
//   7.3.5, 9.1 and 9.2 (tb_h264_cavlc_ref.svh).
// Overview:
//   * A coefficient RAM model (48-bit words, read latency 1, the layout of the rtlnet_h264_mb_cavlc header) holds random
//     macroblocks in two banks; unused words (AC of an uncoded cbp, position (0,0) of AC blocks, words above 101) hold random
//     garbage so that reading them fails the check.
//   * Pictures of 4 rows by 6 macroblocks with random slice starts (a row without upper neighbours has av_top = 0, the first
//     macroblock of each row av_left = 0), random cbp_luma / cbp_chroma / modes, random content density and magnitude, random
//     cmd_ready back-pressure. The reference keeps the total_coeff of every block of every macroblock of the picture and takes
//     nA / nB from the neighbouring macroblocks' arrays (0 for macroblocks without coded AC), 9.2.1 order, then builds the whole
//     macroblock bit string (mb_type, intra_chroma_pred_mode, mb_qp_delta, DC, AC in luma4x4BlkIdx order, chroma DC, chroma AC).
//     The DUT's PK_UE / PK_SE / PK_FIELD commands expand to bits and must equal it bit for bit.
//   * I_PCM macroblocks (the fallback of stage A): the coefficient RAM holds the 96 sample words (first sample in the top byte of
//     the low 32 bits, stream order); the reference is mb_type 25, the alignment zero bits for a random bit offset of the macroblock
//     in the slice, and the 96 words. Such a macroblock counts 16 coefficients in every block for its neighbours' nC.
//   * P slices (phase 2c-1, odd pictures): the reference adds mb_skip_run ue(v) before every macroblock that is not skipped
//     (clause 7.3.4: the count of skipped macroblocks since the last coded one in the slice), codes P_Skip macroblocks as nothing
//     (total_coeff of the whole macroblock 0 for the neighbours' nC, available neighbour: clause 9.2.1), offsets the intra
//     mb_type by 5 (Table 7-13) and codes P_L0_16x16: mb_type 0, mvd_l0 x and y se(v), coded_block_pattern me(v) from the inter
//     column of Table 9-4 (tb_h264_cbp_tab.svh, generated from the JM table), mb_qp_delta only for cbp != 0, LumaLevel4x4
//     blocks (16 coefficients) of the coded 8x8 groups only (the other groups' blocks hold garbage in the RAM and count 0 for
//     nC), chroma as for intra. The running skip run (skip_run output) is compared after every macroblock and at every slice
//     end, and slice_start must clear it.
//   * Reports the clocks per macroblock (no back-pressure) for empty, sparse and dense macroblocks.
//   * +INJECT_FAILURE is the negative control (forces one failed check).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-10-2026: phase 2c-1: P slices (mb_skip_run, P_Skip, P_L0_16x16, inter coded_block_pattern, offset intra types).
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_mbcavlc;

  import rtlnet_tb_pkg::*;
  import rtlnet_h264_pkg::*;

  `include "tb_h264_cavlc_ref_tab.svh"
  `include "tb_h264_cavlc_ref.svh"
  `include "tb_h264_cbp_tab.svh"

  localparam int MBW   = 6;
  localparam int MBH   = 4;
  localparam int NPICS = 40;

  logic         clk = 1'b0;
  logic         resetn = 1'b0;
  logic         start = 1'b0;
  logic [7:0]   mb_x = '0;
  logic         av_top = 1'b0;
  logic         av_left = 1'b0;
  logic [1:0]   i16_mode = '0;
  logic [1:0]   cbp_chroma = '0;
  logic         cbp_luma = 1'b0;
  logic         pcm = 1'b0;
  logic [1:0]   chroma_mode = '0;
  logic [7:0]   cbase = '0;
  logic         p_slice = 1'b0;
  logic         skip = 1'b0;
  logic         inter = 1'b0;
  logic [3:0]   cbp_luma4 = '0;
  logic signed [15:0] mvd_x = '0;
  logic signed [15:0] mvd_y = '0;
  logic         slice_start = 1'b0;
  logic [15:0]  skip_run;
  logic         busy, done;
  logic         cram_rd_en;
  logic [7:0]   cram_rd_addr;
  logic [47:0]  cram_rd_data = '0;
  logic         cmd_valid;
  logic         cmd_ready = 1'b0;
  logic [2:0]   cmd_op;
  logic [31:0]  cmd_val;
  logic [5:0]   cmd_len;

  always #5 clk = ~clk;

  rtlnet_h264_mb_cavlc #(.MAX_MB_W(8), .RAM_STYLE("distributed"), .CRAM_AW(8)) dut (
    .clk(clk), .resetn(resetn), .start(start), .mb_x(mb_x), .av_top(av_top), .av_left(av_left), .pcm(pcm), .i16_mode(i16_mode),
    .cbp_chroma(cbp_chroma), .cbp_luma(cbp_luma), .chroma_mode(chroma_mode), .cbase(cbase),
    .p_slice(p_slice), .skip(skip), .inter(inter), .cbp_luma4(cbp_luma4), .mvd_x(mvd_x), .mvd_y(mvd_y),
    .slice_start(slice_start), .skip_run(skip_run), .busy(busy), .done(done),
    .cram_rd_en(cram_rd_en), .cram_rd_addr(cram_rd_addr), .cram_rd_data(cram_rd_data),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_op(cmd_op), .cmd_val(cmd_val), .cmd_len(cmd_len)
  );

  // Coefficient RAM model, read latency 1.
  logic [47:0] cmem [256];
  always_ff @(posedge clk) if (cram_rd_en) cram_rd_data <= cmem[cram_rd_addr];

  // Zigzag scan of the bench (frame, coding index to raster index).
  localparam int ZZ [16] = '{0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};

  // Content of the macroblock being coded: raster levels (row * 4 + col).
  int dcl [16];
  int acl [16][16];        // luma AC by geometric block (by * 4 + bx)
  int cdc [2][4];
  int cac [2][4][16];

  // total_coeff of the whole picture, per macroblock (row, x): luma by geometric block, chroma plane * 4 + blk.
  int pic_lc [MBH][MBW][16];
  int pic_cc [MBH][MBW][8];

  function automatic int rand_mag(input int mc);
    int bits;
    case (mc)
      0: return $urandom_range(1, 3);
      1: return $urandom_range(1, 30);
      default: begin
        bits = $urandom_range(1, 11);
        return 1 + ($urandom_range(0, (1 << bits) - 1) % 2047);
      end
    endcase
  endfunction

  function automatic int rand_signed(input int mag);
    return ($urandom_range(0, 1) == 1) ? -mag : mag;
  endfunction

  function automatic int blk_bx_of(input int i);
    return (i & 1) + 2 * ((i >> 2) & 1);
  endfunction

  function automatic int blk_by_of(input int i);
    return ((i >> 1) & 1) + 2 * (i >> 3);
  endfunction

  function automatic logic [47:0] pack_row(input int a, input int b, input int c, input int d);
    return {12'(d), 12'(c), 12'(b), 12'(a)};
  endfunction

  function automatic logic [47:0] garbage_word();
    return {$urandom, $urandom};
  endfunction

  task automatic fill_levels(output int lv[16], input int dens, input int mc);
    for (int i = 0; i < 16; i++) lv[i] = (($urandom_range(0, 15) < dens) ? rand_signed(rand_mag(mc)) : 0);
  endtask

  task automatic store_block(input int base, input int lv[16], input bit garbage_dc);
    for (int r = 0; r < 4; r++) begin
      cmem[base + r] = pack_row(lv[4*r], lv[4*r+1], lv[4*r+2], lv[4*r+3]);
    end
    if (garbage_dc) cmem[base][11:0] = 12'($urandom);
  endtask

  // P slice state of the reference: the picture is a P picture, and the skip run since the last coded macroblock of the slice.
  bit pslice_ref = 1'b0;
  int run_ref = 0;

  // mb_skip_run before a coded macroblock of a P slice (clause 7.3.4).
  function automatic void ref_skip_run(ref bitq_t q);
    if (pslice_ref) begin
      put_ue(q, run_ref);
      run_ref = 0;
    end
  endfunction

  function automatic int cbp_code_of(input int cbp);
    for (int i = 0; i < 48; i++) if (CBP_INTER_BY_CODE[i] == cbp) return i;
    return -1;
  endfunction

  // Chroma part of a macroblock (DC blocks, then the AC blocks of cbp_chroma 2), shared by intra and inter macroblocks.
  function automatic void ref_chroma(ref bitq_t q, input int row, input int x, input bit avt, input bit avl, input int cbpc);
    int coef [16];
    int na, nb, nc, tc, p, ci, cbx, cby;
    bit a_av, b_av;
    if (cbpc != 0) begin
      for (p = 0; p < 2; p++) begin
        for (int k = 0; k < 16; k++) coef[k] = (k < 4) ? cdc[p][k] : 0;
        void'(ref_block(q, 4, 4, coef));
      end
    end
    if (cbpc == 2) begin
      for (p = 0; p < 2; p++) begin
        for (ci = 0; ci < 4; ci++) begin
          cbx = ci % 2;
          cby = ci / 2;
          if (cbx > 0) begin a_av = 1; na = pic_cc[row][x][p*4 + cby*2 + cbx - 1]; end
          else begin a_av = avl; na = avl ? pic_cc[row][x-1][p*4 + cby*2 + 1] : 0; end
          if (cby > 0) begin b_av = 1; nb = pic_cc[row][x][p*4 + cbx]; end
          else begin b_av = avt; nb = avt ? pic_cc[row-1][x][p*4 + 2 + cbx] : 0; end
          nc = (a_av && b_av) ? ((na + nb + 1) >> 1) : (a_av ? na : (b_av ? nb : 0));
          for (int k = 0; k < 15; k++) coef[k] = cac[p][ci][ZZ[k + 1]];
          coef[15] = 0;
          tc = ref_block(q, 15, ref_cls(15, nc), coef);
          pic_cc[row][x][p*4 + ci] = tc;
        end
      end
    end
  endfunction

  // P_L0_16x16: mb_skip_run, mb_type 0, mvd x and y, coded_block_pattern me(v), mb_qp_delta and the residual only for cbp != 0.
  function automatic void ref_mb_inter(ref bitq_t q, input int row, input int x, input bit avt, input bit avl, input int cbpl4,
                                       input int cbpc, input int mx, input int my);
    int coef [16];
    int bi, bx, by, g, na, nb, nc, tc;
    bit a_av, b_av;
    ref_skip_run(q);
    put_ue(q, 0);
    put_se(q, mx);
    put_se(q, my);
    put_ue(q, cbp_code_of(cbpl4 + 16 * cbpc));
    for (int i = 0; i < 16; i++) pic_lc[row][x][i] = 0;
    for (int i = 0; i < 8; i++)  pic_cc[row][x][i] = 0;
    if ((cbpl4 != 0) || (cbpc != 0)) begin
      put_se(q, 0);
      for (bi = 0; bi < 16; bi++) begin
        if (((cbpl4 >> (bi / 4)) & 1) != 0) begin
          bx = blk_bx_of(bi);
          by = blk_by_of(bi);
          g  = by * 4 + bx;
          if (bx > 0) begin a_av = 1; na = pic_lc[row][x][by*4 + bx - 1]; end
          else begin a_av = avl; na = avl ? pic_lc[row][x-1][by*4 + 3] : 0; end
          if (by > 0) begin b_av = 1; nb = pic_lc[row][x][(by-1)*4 + bx]; end
          else begin b_av = avt; nb = avt ? pic_lc[row-1][x][12 + bx] : 0; end
          nc = (a_av && b_av) ? ((na + nb + 1) >> 1) : (a_av ? na : (b_av ? nb : 0));
          for (int k = 0; k < 16; k++) coef[k] = acl[g][ZZ[k]];
          tc = ref_block(q, 16, ref_cls(16, nc), coef);
          pic_lc[row][x][g] = tc;
        end
      end
      ref_chroma(q, row, x, avt, avl, cbpc);
    end
  endfunction

  // P_Skip: no bits; the macroblock joins the run and its total_coeff are 0.
  function automatic void ref_mb_skip(input int row, input int x);
    run_ref++;
    for (int i = 0; i < 16; i++) pic_lc[row][x][i] = 0;
    for (int i = 0; i < 8; i++)  pic_cc[row][x][i] = 0;
  endfunction

  // Reference: bits of one macroblock; counts of the picture position (row, x) are written as a side effect.
  function automatic void ref_mb(ref bitq_t q, input int row, input int x, input bit avt, input bit avl, input int md,
                                 input int cbpc, input bit cbpl, input int cmd_);
    int coef [16];
    int bi, bx, by, g, na, nb, nc, tc, p, ci, cbx, cby;
    bit a_av, b_av;
    ref_skip_run(q);
    put_ue(q, 1 + md + 4 * cbpc + (cbpl ? 12 : 0) + (pslice_ref ? 5 : 0));
    put_ue(q, cmd_);
    put_se(q, 0);
    for (int i = 0; i < 16; i++) pic_lc[row][x][i] = 0;
    for (int i = 0; i < 8; i++)  pic_cc[row][x][i] = 0;
    // Intra16x16DCLevel: nC of block 0.
    a_av = avl;
    b_av = avt;
    na = avl ? pic_lc[row][x-1][3] : 0;
    nb = avt ? pic_lc[row-1][x][12] : 0;
    nc = (a_av && b_av) ? ((na + nb + 1) >> 1) : (a_av ? na : (b_av ? nb : 0));
    for (int k = 0; k < 16; k++) coef[k] = dcl[ZZ[k]];
    void'(ref_block(q, 16, ref_cls(16, nc), coef));
    if (cbpl) begin
      for (bi = 0; bi < 16; bi++) begin
        bx = blk_bx_of(bi);
        by = blk_by_of(bi);
        g  = by * 4 + bx;
        if (bx > 0) begin a_av = 1; na = pic_lc[row][x][by*4 + bx - 1]; end
        else begin a_av = avl; na = avl ? pic_lc[row][x-1][by*4 + 3] : 0; end
        if (by > 0) begin b_av = 1; nb = pic_lc[row][x][(by-1)*4 + bx]; end
        else begin b_av = avt; nb = avt ? pic_lc[row-1][x][12 + bx] : 0; end
        nc = (a_av && b_av) ? ((na + nb + 1) >> 1) : (a_av ? na : (b_av ? nb : 0));
        for (int k = 0; k < 15; k++) coef[k] = acl[g][ZZ[k + 1]];
        coef[15] = 0;
        tc = ref_block(q, 15, ref_cls(15, nc), coef);
        pic_lc[row][x][g] = tc;
      end
    end
    if (cbpc != 0) begin
      for (p = 0; p < 2; p++) begin
        for (int k = 0; k < 16; k++) coef[k] = (k < 4) ? cdc[p][k] : 0;
        void'(ref_block(q, 4, 4, coef));
      end
    end
    if (cbpc == 2) begin
      for (p = 0; p < 2; p++) begin
        for (ci = 0; ci < 4; ci++) begin
          cbx = ci % 2;
          cby = ci / 2;
          if (cbx > 0) begin a_av = 1; na = pic_cc[row][x][p*4 + cby*2 + cbx - 1]; end
          else begin a_av = avl; na = avl ? pic_cc[row][x-1][p*4 + cby*2 + 1] : 0; end
          if (cby > 0) begin b_av = 1; nb = pic_cc[row][x][p*4 + cbx]; end
          else begin b_av = avt; nb = avt ? pic_cc[row-1][x][p*4 + 2 + cbx] : 0; end
          nc = (a_av && b_av) ? ((na + nb + 1) >> 1) : (a_av ? na : (b_av ? nb : 0));
          for (int k = 0; k < 15; k++) coef[k] = cac[p][ci][ZZ[k + 1]];
          coef[15] = 0;
          tc = ref_block(q, 15, ref_cls(15, nc), coef);
          pic_cc[row][x][p*4 + ci] = tc;
        end
      end
    end
  endfunction

  int clk_empty_max = 0, clk_sparse_max = 0, clk_dense_max = 0, clk_dense_min = 100000, clk_empty_min = 100000;
  longint unsigned clk_sparse_sum = 0, clk_dense_sum = 0;
  int clk_sparse_n = 0, clk_dense_n = 0;
  int mbs_run = 0;
  int mb_cov_top = 0, mb_cov_left = 0, mb_cov_both = 0, mb_cov_none = 0;

  int cat_dens;

  // Reference of an I_PCM macroblock; off is the bit offset of the macroblock in the slice (alignment zero bits).
  function automatic void ref_pcm(ref bitq_t q, input int row, input int x, input int off, input logic [31:0] words [96]);
    ref_skip_run(q);
    put_ue(q, 25 + (pslice_ref ? 5 : 0));
    for (int i = 0; i < ((8 - ((off + q.size()) % 8)) % 8); i++) q.push_back(1'b0);
    for (int w = 0; w < 96; w++) put_bits(q, words[w], 32);
    for (int i = 0; i < 16; i++) pic_lc[row][x][i] = 16;
    for (int i = 0; i < 8; i++)  pic_cc[row][x][i] = 16;
  endfunction

  int clk_pcm_max = 0;
  int pcm_mbs = 0;

  // Code one I_PCM macroblock.
  task automatic run_pcm(input int row, input int x, input bit avt, input bit avl, input int pct);
    bitq_t expq, got;
    logic [31:0] words [96];
    int bank, t, off;
    bit fin;
    bank = ($urandom_range(0, 1) == 1) ? 128 : 0;
    off  = $urandom_range(0, 7);
    for (int w = 0; w < 128; w++) cmem[bank + w] = garbage_word();
    for (int w = 0; w < 96; w++) begin
      words[w] = $urandom;
      cmem[bank + w][31:0] = words[w];
    end
    ref_pcm(expq, row, x, off, words);
    @(negedge clk);
    start = 1'b1; mb_x = 8'(x); av_top = avt; av_left = avl; i16_mode = 2'($urandom_range(0, 3)); cbp_chroma = 2'($urandom_range(0, 2));
    cbp_luma = 1'($urandom_range(0, 1)); chroma_mode = 2'($urandom_range(0, 3)); cbase = 8'(bank); pcm = 1'b1;
    p_slice = pslice_ref; skip = 1'b0; inter = 1'b0;
    @(negedge clk);
    start = 1'b0;
    fin = 0;
    t = 1;
    while (!fin && t < 20000) begin
      cmd_ready = (pct >= 100) ? 1'b1 : (($urandom_range(0, 99) < pct) ? 1'b1 : 1'b0);
      if (cmd_valid && cmd_ready) begin
        case (cmd_op)
          PK_UE:    put_ue(got, cmd_val);
          PK_ALIGN: for (int i = 0; i < ((8 - ((off + got.size()) % 8)) % 8); i++) got.push_back(1'b0);
          PK_FIELD: put_bits(got, cmd_val, int'(cmd_len));
          default:  tb_error("unexpected command op in an I_PCM macroblock");
        endcase
      end
      if (done) fin = 1;
      else @(negedge clk);
      t++;
    end
    cmd_ready = 1'b0;
    pcm = 1'b0;
    tb_check(fin, $sformatf("I_PCM macroblock (%0d,%0d) did not finish", row, x));
    tb_check(got == expq, $sformatf("I_PCM bit string mismatch mb (%0d,%0d): got %0d bits, expected %0d", row, x, got.size(), expq.size()));
    pcm_mbs++;
    if ((pct >= 100) && (t > clk_pcm_max)) clk_pcm_max = t;
    @(negedge clk);
    @(negedge clk);
  endtask

  // Code one macroblock: set up the RAM, run the DUT, compare.
  task automatic run_mb(input int row, input int x, input bit avt, input bit avl, input int pct, input int cat);
    bitq_t expq, got;
    int md, cm, cbpc, bank, t, mc, dd, cdens;
    bit cbpl, fin;
    int lv [16];
    md   = $urandom_range(0, 3);
    cm   = $urandom_range(0, 3);
    cbpl = (cat == 0) ? 1'b0 : (($urandom_range(0, 3) != 0) ? 1'b1 : 1'b0);
    cbpc = (cat == 0) ? 0 : $urandom_range(0, 2);
    bank = ($urandom_range(0, 1) == 1) ? 128 : 0;
    mc   = (cat == 2) ? 2 : $urandom_range(0, 2);
    dd   = (cat == 0) ? $urandom_range(0, 2) : ((cat == 1) ? $urandom_range(1, 3) : $urandom_range(10, 16));
    // Garbage everywhere in the bank first, then the structured content.
    for (int w = 0; w < 128; w++) cmem[bank + w] = garbage_word();
    fill_levels(lv, dd, mc);
    for (int i = 0; i < 16; i++) dcl[i] = lv[i];
    store_block(bank + 0, dcl, 1'b0);
    for (int g = 0; g < 16; g++) begin
      fill_levels(lv, dd, mc);
      for (int i = 0; i < 16; i++) acl[g][i] = lv[i];
      store_block(bank + 4 + 4 * g, lv, 1'b1);
    end
    for (int p = 0; p < 2; p++) begin
      fill_levels(lv, dd, mc);
      for (int i = 0; i < 4; i++) cdc[p][i] = lv[i];
      cmem[bank + 100 + p] = pack_row(lv[0], lv[1], lv[2], lv[3]);
      for (int ci = 0; ci < 4; ci++) begin
        fill_levels(lv, dd, mc);
        for (int i = 0; i < 16; i++) cac[p][ci][i] = lv[i];
        store_block(bank + 68 + 16 * p + 4 * ci, lv, 1'b1);
      end
    end
    ref_mb(expq, row, x, avt, avl, md, cbpc, cbpl, cm);
    if (avt && avl) mb_cov_both++; else if (avt) mb_cov_top++; else if (avl) mb_cov_left++; else mb_cov_none++;

    @(negedge clk);
    start = 1'b1; mb_x = 8'(x); av_top = avt; av_left = avl; i16_mode = 2'(md); cbp_chroma = 2'(cbpc); cbp_luma = cbpl;
    chroma_mode = 2'(cm); cbase = 8'(bank);
    p_slice = pslice_ref; skip = 1'b0; inter = 1'b0;
    @(negedge clk);
    start = 1'b0;
    fin = 0;
    t = 1;
    while (!fin && t < 20000) begin
      cmd_ready = (pct >= 100) ? 1'b1 : (($urandom_range(0, 99) < pct) ? 1'b1 : 1'b0);
      if (cmd_valid && cmd_ready) begin
        case (cmd_op)
          PK_UE:    put_ue(got, cmd_val);
          PK_SE:    put_se(got, int'(cmd_val));
          PK_FIELD: put_bits(got, cmd_val, int'(cmd_len));
          default:  tb_error("unexpected command op");
        endcase
      end
      if (done) fin = 1;
      else @(negedge clk);
      t++;
    end
    cmd_ready = 1'b0;
    tb_check(fin, $sformatf("macroblock (%0d,%0d) did not finish", row, x));
    tb_check(got == expq, $sformatf("bit string mismatch mb (%0d,%0d) avt %0d avl %0d cbpl %0d cbpc %0d: got %0d bits, expected %0d", row, x,
                                    avt, avl, cbpl, cbpc, got.size(), expq.size()));
    mbs_run++;
    if (pct >= 100) begin
      if (cat == 0 && !cbpl && cbpc == 0) begin
        if (t < clk_empty_min) clk_empty_min = t;
        if (t > clk_empty_max) clk_empty_max = t;
      end else if (cat == 1) begin
        clk_sparse_sum += t; clk_sparse_n++;
        if (t > clk_sparse_max) clk_sparse_max = t;
      end else if (cat == 2) begin
        clk_dense_sum += t; clk_dense_n++;
        if (t > clk_dense_max) clk_dense_max = t;
        if (t < clk_dense_min) clk_dense_min = t;
      end
    end
    @(negedge clk);
    @(negedge clk);
  endtask

  int inter_mbs = 0, skip_mbs = 0, p_intra_mbs = 0, inter_cbp0 = 0, inter_cbp_part = 0;
  int clk_inter_max = 0, clk_skip_max = 0;

  // Code one P_L0_16x16 macroblock: random coded 8x8 groups (garbage in the RAM for the others), random chroma cbp, random mvd.
  task automatic run_inter(input int row, input int x, input bit avt, input bit avl, input int pct, input int cat);
    bitq_t expq, got;
    int cbpl4, cbpc, bank, t, mc, dd, mx, my;
    bit fin;
    int lv [16];
    case ($urandom_range(0, 5))
      0: cbpl4 = 0;
      1: cbpl4 = 15;
      default: cbpl4 = $urandom_range(0, 15);
    endcase
    cbpc = $urandom_range(0, 2);
    if (($urandom_range(0, 5) == 0) && (cat == 0)) begin cbpl4 = 0; cbpc = 0; end
    if (cbpl4 == 0 && cbpc == 0) inter_cbp0++; else if (cbpl4 != 15) inter_cbp_part++;
    case ($urandom_range(0, 5))
      0: begin mx = 0; my = 0; end
      1: begin mx = $urandom_range(0, 4000) - 2000; my = $urandom_range(0, 4000) - 2000; end
      default: begin mx = $urandom_range(0, 40) - 20; my = $urandom_range(0, 40) - 20; end
    endcase
    bank = ($urandom_range(0, 1) == 1) ? 128 : 0;
    mc   = (cat == 2) ? 2 : $urandom_range(0, 2);
    dd   = (cat == 0) ? $urandom_range(0, 2) : ((cat == 1) ? $urandom_range(1, 3) : $urandom_range(10, 16));
    for (int w = 0; w < 128; w++) cmem[bank + w] = garbage_word();
    for (int g = 0; g < 16; g++) begin
      fill_levels(lv, dd, mc);
      for (int i = 0; i < 16; i++) acl[g][i] = lv[i];
      store_block(bank + 4 + 4 * g, lv, 1'b0);
    end
    for (int p = 0; p < 2; p++) begin
      fill_levels(lv, dd, mc);
      for (int i = 0; i < 4; i++) cdc[p][i] = lv[i];
      cmem[bank + 100 + p] = pack_row(lv[0], lv[1], lv[2], lv[3]);
      for (int ci = 0; ci < 4; ci++) begin
        fill_levels(lv, dd, mc);
        for (int i = 0; i < 16; i++) cac[p][ci][i] = lv[i];
        store_block(bank + 68 + 16 * p + 4 * ci, lv, 1'b1);
      end
    end
    ref_mb_inter(expq, row, x, avt, avl, cbpl4, cbpc, mx, my);
    @(negedge clk);
    start = 1'b1; mb_x = 8'(x); av_top = avt; av_left = avl; cbase = 8'(bank);
    p_slice = 1'b1; skip = 1'b0; inter = 1'b1; pcm = 1'b0; cbp_luma4 = 4'(cbpl4); cbp_chroma = 2'(cbpc);
    cbp_luma = 1'($urandom_range(0, 1)); i16_mode = 2'($urandom_range(0, 3)); chroma_mode = 2'($urandom_range(0, 3));
    mvd_x = 16'(mx); mvd_y = 16'(my);
    @(negedge clk);
    start = 1'b0;
    fin = 0;
    t = 1;
    while (!fin && t < 20000) begin
      cmd_ready = (pct >= 100) ? 1'b1 : (($urandom_range(0, 99) < pct) ? 1'b1 : 1'b0);
      if (cmd_valid && cmd_ready) begin
        case (cmd_op)
          PK_UE:    put_ue(got, cmd_val);
          PK_SE:    put_se(got, int'(cmd_val));
          PK_FIELD: put_bits(got, cmd_val, int'(cmd_len));
          default:  tb_error("unexpected command op");
        endcase
      end
      if (done) fin = 1;
      else @(negedge clk);
      t++;
    end
    cmd_ready = 1'b0;
    inter = 1'b0;
    tb_check(fin, $sformatf("inter macroblock (%0d,%0d) did not finish", row, x));
    tb_check(got == expq, $sformatf("inter bit string mismatch mb (%0d,%0d) avt %0d avl %0d cbpl4 %0d cbpc %0d mvd (%0d,%0d): got %0d bits, expected %0d",
                                    row, x, avt, avl, cbpl4, cbpc, mx, my, got.size(), expq.size()));
    tb_check(skip_run == 16'(run_ref), $sformatf("skip_run %0d after a coded macroblock, expected %0d", skip_run, run_ref));
    inter_mbs++;
    if ((pct >= 100) && (t > clk_inter_max)) clk_inter_max = t;
    @(negedge clk);
    @(negedge clk);
  endtask

  // Code one P_Skip macroblock: no commands, the run grows, done pulses.
  task automatic run_skip(input int row, input int x, input bit avt, input bit avl);
    int t;
    bit fin;
    ref_mb_skip(row, x);
    @(negedge clk);
    start = 1'b1; mb_x = 8'(x); av_top = avt; av_left = avl; p_slice = 1'b1; skip = 1'b1; inter = 1'b0; pcm = 1'b0;
    @(negedge clk);
    start = 1'b0;
    fin = 0;
    t = 1;
    while (!fin && t < 200) begin
      cmd_ready = 1'b1;
      tb_check(!cmd_valid, "a skipped macroblock wrote a command");
      if (done) fin = 1;
      else @(negedge clk);
      t++;
    end
    cmd_ready = 1'b0;
    skip = 1'b0;
    tb_check(fin, $sformatf("skipped macroblock (%0d,%0d) did not finish", row, x));
    tb_check(skip_run == 16'(run_ref), $sformatf("skip_run %0d after a skipped macroblock, expected %0d", skip_run, run_ref));
    skip_mbs++;
    if (t > clk_skip_max) clk_skip_max = t;
    @(negedge clk);
    @(negedge clk);
  endtask

  // Slice end of a P picture: the engine writes mb_skip_run when it is not 0 (here: compare), slice_start clears it.
  task automatic slice_boundary();
    tb_check(skip_run == 16'(run_ref), $sformatf("skip_run %0d at the slice end, expected %0d", skip_run, run_ref));
    @(negedge clk);
    slice_start = 1'b1;
    @(negedge clk);
    slice_start = 1'b0;
    run_ref = 0;
    @(negedge clk);
    tb_check(skip_run == 16'd0, "slice_start did not clear the skip run");
  endtask

  bit ss [MBH];
  int pct_v, cat_v;

  initial begin
    resetn = 1'b0;
    for (int w = 0; w < 256; w++) cmem[w] = '0;
    repeat (6) @(negedge clk);
    resetn = 1'b1;
    repeat (3) @(negedge clk);

    for (int pic = 0; pic < NPICS; pic++) begin
      // Slice starts: a row that starts a slice has no upper neighbours.
      for (int r = 0; r < MBH; r++) ss[r] = (r == 0) || ($urandom_range(0, 2) == 0);
      cat_v = (pic / 2) % 3;
      // Odd pictures are P pictures (the I pictures are the pictures of the earlier phases).
      pslice_ref = (pic % 2) == 1;
      run_ref    = 0;
      for (int r = 0; r < MBH; r++) begin
        if (ss[r] && pslice_ref) slice_boundary();
        for (int x = 0; x < MBW; x++) begin
          pct_v = (pic % 4 == 3) ? 30 : ((pic % 4 == 2) ? 60 : 100);
          if (pslice_ref) begin
            // P slice: 30 % skipped (in runs), 35 % inter, the rest intra and I_PCM.
            case ($urandom_range(0, 19))
              0, 1, 2, 3, 4, 5:        run_skip(r, x, !ss[r], (x > 0));
              6, 7, 8, 9, 10, 11, 12:  run_inter(r, x, !ss[r], (x > 0), pct_v, ($urandom_range(0, 3) == 0) ? ((cat_v + 1) % 3) : cat_v);
              13:                      begin run_pcm(r, x, !ss[r], (x > 0), pct_v); end
              default:                 begin run_mb(r, x, !ss[r], (x > 0), pct_v, cat_v); p_intra_mbs++; end
            endcase
          end else begin
            if ($urandom_range(0, 7) == 0) run_pcm(r, x, !ss[r], (x > 0), pct_v);
            else run_mb(r, x, !ss[r], (x > 0), pct_v, ($urandom_range(0, 3) == 0) ? ((cat_v + 1) % 3) : cat_v);
          end
        end
      end
      // Picture end: a trailing run is written at the slice end by the engine; the I pictures have no run.
      if (pslice_ref) slice_boundary();
    end
    // Long run of skipped macroblocks (a run above 255 crosses the 8-bit ue range) in one slice.
    pslice_ref = 1'b1;
    run_ref = 0;
    slice_start = 1'b1; @(negedge clk); slice_start = 1'b0; @(negedge clk);
    for (int k = 0; k < 600; k++) run_skip((k / MBW) % MBH, k % MBW, ((k / MBW) % MBH) != 0, (k % MBW) != 0);
    run_inter(0, 0, 1'b0, 1'b0, 100, 0);
    slice_boundary();
    $display("STAT macroblocks=%0d, neighbour cases: both %0d top-only %0d left-only %0d none %0d", mbs_run, mb_cov_both, mb_cov_top,
             mb_cov_left, mb_cov_none);
    $display("STAT clocks per macroblock (no stall): empty min %0d max %0d, sparse max %0d avg %0d, dense min %0d max %0d avg %0d",
             clk_empty_min, clk_empty_max, clk_sparse_max, (clk_sparse_n > 0) ? int'(clk_sparse_sum / clk_sparse_n) : 0,
             clk_dense_min, clk_dense_max, (clk_dense_n > 0) ? int'(clk_dense_sum / clk_dense_n) : 0);
    $display("STAT P slices: inter %0d (cbp 0 %0d, partial luma %0d), skip %0d, intra in P %0d; clocks per macroblock max: inter %0d, skip %0d",
             inter_mbs, inter_cbp0, inter_cbp_part, skip_mbs, p_intra_mbs, clk_inter_max, clk_skip_max);
    tb_check(inter_mbs > 100 && skip_mbs > 100 && inter_cbp0 > 5 && inter_cbp_part > 20, "P slice coverage");
    $display("STAT I_PCM macroblocks=%0d, clocks per I_PCM macroblock (no stall) max %0d", pcm_mbs, clk_pcm_max);
    tb_check(pcm_mbs > 20, "I_PCM coverage");
    tb_verdict("tb_rtlnet_h264_mbcavlc");
  end

  initial begin
    #2000000000;
    tb_error("watchdog");
    tb_verdict("tb_rtlnet_h264_mbcavlc");
  end

endmodule
