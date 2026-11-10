// -----------------------------------------------------------------------------
// File: rtlnet_h264_mb_cavlc.sv
// Purpose: stage B of the H.264 encoder: the macroblock layer syntax (clause 7.3.5) and CAVLC residual coding (clause 9.2)
//   of one Intra16x16 macroblock in an I slice, from the quantized levels in the coefficient RAM into packer commands.
// Overview:
//   * Per macroblock: mb_type ue(v) = 1 + i16_mode + 4 * cbp_chroma + 12 * cbp_luma (Table 7-11), intra_chroma_pred_mode ue(v),
//     mb_qp_delta se(v) = 0, then residual(): Intra16x16DCLevel always (maxNumCoeff 16); when cbp_luma the 16
//     Intra16x16ACLevel blocks (maxNumCoeff 15, zigzag positions 1..15) in luma4x4BlkIdx order; when cbp_chroma != 0 the Cb and
//     Cr ChromaDCLevel blocks (nC = -1); when cbp_chroma == 2 the four Cb and four Cr ChromaACLevel blocks.
//   * Coefficient RAM (48-bit words, four 12-bit levels each, per bank of 128 words at cbase): 0..3 luma DC matrix rows,
//     4 + 4 * (by * 4 + bx) + r luma AC row r of block (bx, by), 68 + 4 * blk + r Cb AC, 84 + 4 * blk + r Cr AC, 100 Cb DC,
//     101 Cr DC. A reader reads the next block (four words, or one for chroma DC) into a raster buffer while the previous
//     block is coded; the zigzag scan order is applied when the block goes to rtlnet_h264_cavlc_blk.
//   * nC (clause 9.2.1): blkA is the left, blkB the upper neighbouring 4x4 block of the same plane (inside the macroblock,
//     or the left macroblock's right column or the upper macroblock's bottom row). Their total_coeff is that of the AC block
//     (0 when the macroblock coded no AC); a neighbour in another macroblock counts only when available (av_left, av_top;
//     the caller drives av_left = 0 for the first macroblock of a row and av_top = 0 in the first row of a slice). nC is the
//     rounded mean when both exist, the one value when one exists, 0 when none. The Intra16x16DCLevel block uses the
//     neighbours of luma block 0. The left macroblock's counts stay in registers across starts; the upper counts of every
//     column (4 luma, 2 Cb, 2 Cr, 5 bits each) are a line RAM (rtlnet_ram_core, depth from MAX_MB_W) read at start and
//     written at the end of the macroblock.
//   * Command interface: ready/valid, op PK_UE / PK_SE for the header, PK_FIELD for the residual.
//   * Two block coders (rtlnet_h264_cavlc_blk) work in ping-pong in block order: the dispatcher takes the block from the
//     reader buffer, counts its non-zero levels (TotalCoeff, so the next block's nC does not wait for the coder), computes nC
//     and starts the idle coder; the command output follows the dispatch order, so the second coder's analysis overlaps the
//     first coder's commands. Each coder emits two levels or two run_before codes per command.
//   * I_PCM macroblock (input pcm): mb_type ue(v) = 25, PK_ALIGN, then the 96 sample words of the coefficient RAM as 32-bit
//     fields (word i = samples 4i .. 4i + 3, first sample in the top byte), 3 clocks per word; every block counts 16
//     coefficients for the neighbours' nC (clause 9.2.1).
//   * Cycles: an empty macroblock (cbp 0) takes about 20 clocks; a dense macroblock about 350 to 450; an I_PCM macroblock
//     about 290 (the packer takes one byte per clock, so its 386 bytes need at least that many clocks).
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_mb_cavlc #(
  parameter int    MAX_MB_W  = 120,
  parameter string RAM_STYLE = "block",
  parameter int    CRAM_AW   = 8
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // Macroblock command, clk domain: start pulses one clock when idle; the descriptor is sampled with start.
  input  logic              start,
  // Column of the macroblock; only the low $clog2(MAX_MB_W) bits address the line RAM.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [7:0]        mb_x,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              av_top,
  input  logic              av_left,
  input  logic              pcm,
  input  logic [1:0]        i16_mode,
  input  logic [1:0]        cbp_chroma,
  input  logic              cbp_luma,
  input  logic [1:0]        chroma_mode,
  input  logic [CRAM_AW-1:0] cbase,
  output logic              busy,
  output logic              done,

  // Coefficient RAM read port, clk domain: cram_rd_data is valid the clock after cram_rd_en.
  output logic              cram_rd_en,
  output logic [CRAM_AW-1:0] cram_rd_addr,
  input  logic [47:0]       cram_rd_data,

  // Bit-packer command output, clk domain.
  output logic              cmd_valid,
  input  logic              cmd_ready,
  output logic [2:0]        cmd_op,
  output logic [31:0]       cmd_val,
  output logic [5:0]        cmd_len
);

  import rtlnet_h264_pkg::*;

  localparam int LAW = $clog2(MAX_MB_W);

  // Coder states.
  localparam logic [3:0] C_IDLE = 4'd0;
  localparam logic [3:0] C_H0   = 4'd1;
  localparam logic [3:0] C_H1   = 4'd2;
  localparam logic [3:0] C_H2   = 4'd3;
  localparam logic [3:0] C_BLK  = 4'd4;
  localparam logic [3:0] C_FIN  = 4'd7;
  localparam logic [3:0] C_P0   = 4'd8;
  localparam logic [3:0] C_P1   = 4'd9;
  localparam logic [3:0] C_PR   = 4'd10;
  localparam logic [3:0] C_PW   = 4'd11;
  localparam logic [3:0] C_PE   = 4'd12;

  // Reader states.
  localparam logic [1:0] R_IDLE  = 2'd0;
  localparam logic [1:0] R_ISSUE = 2'd1;
  localparam logic [1:0] R_CAP   = 2'd2;
  localparam logic [1:0] R_HOLD  = 2'd3;

  // Item numbers: 0 luma DC, 1..16 luma AC (blkIdx = item - 1), 17 Cb DC, 18 Cr DC, 19..22 Cb AC, 23..26 Cr AC, 31 end.
  function automatic logic item_valid(input logic [4:0] s, input logic cl, input logic [1:0] cc);
    if (s == 5'd0)                     return 1'b1;
    if (s <= 5'd16)                    return cl;
    if (s <= 5'd18)                    return (cc != 2'd0);
    if (s <= 5'd26)                    return (cc == 2'd2);
    return 1'b0;
  endfunction

  function automatic logic [4:0] next_item(input logic [4:0] s, input logic cl, input logic [1:0] cc);
    logic [4:0] r;
    r = 5'd31;
    for (int i = 26; i >= 1; i--) if ((5'(i) > s) && item_valid(5'(i), cl, cc)) r = 5'(i);
    return r;
  endfunction

  // Luma blkIdx to geometric position.
  // Each function reads two of the four index bits.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [1:0] blk_bx(input logic [3:0] i);
    return {i[2], i[0]};
  endfunction
  function automatic logic [1:0] blk_by(input logic [3:0] i);
    return {i[3], i[1]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // Coefficient RAM word offset of an item.
  function automatic logic [7:0] item_off(input logic [4:0] s);
    logic [3:0] bi;
    logic [3:0] g;
    bi = 4'(s - 5'd1);
    g  = {blk_by(bi), blk_bx(bi)};
    if (s == 5'd0)       return 8'd0;
    if (s <= 5'd16)      return 8'd4 + {2'b00, g, 2'b00};
    if (s == 5'd17)      return 8'd100;
    if (s == 5'd18)      return 8'd101;
    if (s <= 5'd22)      return 8'd68 + {1'b0, 5'(s - 5'd19), 2'b00};
    return 8'd84 + {1'b0, 5'(s - 5'd23), 2'b00};
  endfunction

  // Zigzag scan (frame): coding index to raster index.
  function automatic logic [3:0] zz(input int k);
    case (k)
      0: return 4'd0;   1: return 4'd1;   2: return 4'd4;   3: return 4'd8;
      4: return 4'd5;   5: return 4'd2;   6: return 4'd3;   7: return 4'd6;
      8: return 4'd9;   9: return 4'd12; 10: return 4'd13; 11: return 4'd10;
      12: return 4'd7; 13: return 4'd11; 14: return 4'd14; default: return 4'd15;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic [3:0]         st;
  logic [1:0]         rst;
  logic [CRAM_AW-1:0] cbase_q;
  logic [LAW-1:0]     mbx_q;
  logic               avt_q;
  logic               avl_q;
  logic [1:0]         mode_q;
  logic [1:0]         cbpc_q;
  logic               cbpl_q;
  logic [1:0]         cmode_q;

  // Total-coeff bookkeeping, 5 bits each: current macroblock luma (index by * 4 + bx) and chroma (p * 4 + by * 2 + bx), the
  // left macroblock's right column (luma by; chroma p * 2 + by) and the upper macroblock's bottom row (luma bx; chroma p * 2 + bx).
  logic [4:0]         lc  [16];
  logic [4:0]         cc  [8];
  logic [4:0]         ll  [4];
  logic [4:0]         lcl [4];
  logic [4:0]         tl_l [4];
  logic [4:0]         tl_c [4];

  // Reader.
  logic [4:0]         rs;
  logic [2:0]         ri;
  logic               rd_v_q;
  logic [2:0]         rd_i_q;
  logic [191:0]       rbuf;
  logic               rvalid;
  logic [4:0]         r_item;
  logic               rtake;

  // Coders: two block coders work in ping-pong; the dispatcher starts them in block order and the output follows
  // the same order (bsel is the coder whose commands go out; nsel the coder that takes the next block).
  logic               disp;
  logic               bsel;
  logic               nsel;
  logic [1:0]         act;
  logic [1:0]         blk_start;
  logic [1:0]         blk_done;
  logic [1:0]         blk_cmd_valid;
  logic [31:0]        blk_cmd_val [2];
  logic [5:0]         blk_cmd_len [2];
  logic [1:0]         blk_ready;
  logic [191:0]       blk_coef;
  logic [1:0]         blk_mode;
  logic [4:0]         pc_blk;
  logic               last_disp;
  logic               all_disp;

  // I_PCM path: word counter and the captured word.
  logic [6:0]         pw_n;
  logic [31:0]        pw_data;

  // Line RAM of the upper counts.
  logic               ln_rd_en;
  logic               ln_rd_q;
  logic [39:0]        ln_rd_data;
  logic               ln_wr_en;
  logic [39:0]        ln_wr_data;

  assign busy = (st != C_IDLE);

  // ---------------------------------------------------------------------------
  // Reader address generation
  // ---------------------------------------------------------------------------
  logic [2:0] r_words;
  assign r_words      = ((rs == 5'd17) || (rs == 5'd18)) ? 3'd1 : 3'd4;
  assign cram_rd_en   = (rst == R_ISSUE) || (st == C_PR);
  assign cram_rd_addr = (st == C_PR) ? (cbase_q + CRAM_AW'(pw_n)) : (cbase_q + CRAM_AW'(item_off(rs)) + CRAM_AW'(ri));

  // ---------------------------------------------------------------------------
  // Block coder input: zigzag order
  // ---------------------------------------------------------------------------
  logic signed [11:0] rr [16];
  always_comb begin
    for (int i = 0; i < 16; i++) rr[i] = rbuf[12*i +: 12];
    blk_coef = '0;
    if (r_item == 5'd0) begin
      blk_mode = 2'd0;
      for (int k = 0; k < 16; k++) blk_coef[12*k +: 12] = rr[zz(k)];
    end else if ((r_item == 5'd17) || (r_item == 5'd18)) begin
      blk_mode = 2'd2;
      for (int k = 0; k < 4; k++) blk_coef[12*k +: 12] = rr[k];
    end else begin
      blk_mode = 2'd1;
      for (int k = 0; k < 15; k++) blk_coef[12*k +: 12] = rr[zz(k + 1)];
    end
  end

  // Number of non-zero levels of the block (TotalCoeff): known at dispatch, so nC of the following block does not wait
  // for the block coder.
  always_comb begin
    pc_blk = 5'd0;
    for (int k = 0; k < 16; k++) pc_blk = pc_blk + 5'(blk_coef[12*k +: 12] != 12'd0);
  end

  // ---------------------------------------------------------------------------
  // nC of the item waiting in the reader buffer (clause 9.2.1)
  // ---------------------------------------------------------------------------
  logic [1:0] nbx;
  logic [1:0] nby;
  logic       nplane;     // chroma plane: 0 Cb, 1 Cr
  logic       n_chroma;
  logic       a_av;
  logic       b_av;
  logic [4:0] a_n;
  logic [4:0] b_n;
  // n_sum bit 0 is the rounding remainder of the mean.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [5:0] n_sum;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [4:0] nc_calc;
  logic [3:0] n_bi;
  logic [1:0] n_ci;
  always_comb begin
    n_bi     = 4'(r_item - 5'd1);
    n_ci     = 2'(r_item - 5'd19);
    n_chroma = (r_item >= 5'd19);
    nplane   = (r_item >= 5'd23);
    nbx      = 2'd0;
    nby      = 2'd0;
    if (n_chroma) begin
      nbx = {1'b0, n_ci[0]};
      nby = {1'b0, n_ci[1]};
    end else if (r_item != 5'd0) begin
      nbx = blk_bx(n_bi);
      nby = blk_by(n_bi);
    end
    if (n_chroma) begin
      a_av = (nbx != 2'd0) || avl_q;
      b_av = (nby != 2'd0) || avt_q;
      a_n  = (nbx != 2'd0) ? cc[{nplane, nby[0], 1'b0} + 3'd0 + {2'b00, nbx[0]} - 3'd1] : lcl[{nplane, nby[0]}];
      b_n  = (nby != 2'd0) ? cc[{nplane, 2'b00} + {2'b00, nbx[0]}] : tl_c[{nplane, nbx[0]}];
    end else begin
      a_av = (nbx != 2'd0) || avl_q;
      b_av = (nby != 2'd0) || avt_q;
      a_n  = (nbx != 2'd0) ? lc[{nby, 2'b00} + {2'b00, nbx} - 4'd1] : ll[nby];
      b_n  = (nby != 2'd0) ? lc[{nby - 2'd1, 2'b00} + {2'b00, nbx}] : tl_l[nbx];
    end
    n_sum   = {1'b0, a_n} + {1'b0, b_n} + 6'd1;
    if (a_av && b_av)      nc_calc = n_sum[5:1];
    else if (a_av)         nc_calc = a_n;
    else if (b_av)         nc_calc = b_n;
    else                   nc_calc = 5'd0;
  end

  // ---------------------------------------------------------------------------
  // Command output
  // ---------------------------------------------------------------------------
  logic [31:0] mbtype;
  assign mbtype = 32'd1 + 32'(mode_q) + 32'd4 * 32'(cbpc_q) + (cbpl_q ? 32'd12 : 32'd0);

  always_comb begin
    cmd_valid = 1'b0;
    cmd_op    = PK_FIELD;
    cmd_val   = 32'd0;
    cmd_len   = 6'd0;
    case (st)
      C_H0: begin cmd_valid = 1'b1; cmd_op = PK_UE; cmd_val = mbtype; end
      C_H1: begin cmd_valid = 1'b1; cmd_op = PK_UE; cmd_val = 32'(cmode_q); end
      C_H2: begin cmd_valid = 1'b1; cmd_op = PK_SE; cmd_val = 32'd0; end
      C_BLK: begin
        cmd_valid = blk_cmd_valid[bsel];
        cmd_op    = PK_FIELD;
        cmd_val   = blk_cmd_val[bsel];
        cmd_len   = blk_cmd_len[bsel];
      end
      C_P0: begin cmd_valid = 1'b1; cmd_op = PK_UE; cmd_val = MB_TYPE_I_PCM; end
      C_P1: begin cmd_valid = 1'b1; cmd_op = PK_ALIGN; end
      C_PE: begin cmd_valid = 1'b1; cmd_op = PK_FIELD; cmd_val = pw_data; cmd_len = 6'd32; end
      default: begin
      end
    endcase
  end

  // Dispatch: a block waits in the reader buffer and the coder that takes it is idle (or finishes in this clock).
  assign disp      = (st == C_BLK) && rvalid && !all_disp && (!act[nsel] || blk_done[nsel]);
  assign rtake     = disp;
  assign blk_start = {disp && nsel, disp && !nsel};
  assign blk_ready = {cmd_ready && (st == C_BLK) && bsel, cmd_ready && (st == C_BLK) && !bsel};
  assign last_disp = (next_item(r_item, cbpl_q, cbpc_q) == 5'd31);

  for (genvar gi = 0; gi < 2; gi++) begin : g_blk
    logic        b_busy;
    logic [4:0]  b_tc;
    rtlnet_h264_cavlc_blk u_blk (
      .clk(clk), .resetn(resetn), .start(blk_start[gi]), .mode(blk_mode), .nc(nc_calc), .coef(blk_coef),
      .busy(b_busy), .done(blk_done[gi]), .total_coeff(b_tc),
      .cmd_valid(blk_cmd_valid[gi]), .cmd_ready(blk_ready[gi]), .cmd_val(blk_cmd_val[gi]), .cmd_len(blk_cmd_len[gi])
    );
    // Busy and total_coeff are not needed here: the dispatcher counts non-zero levels itself.
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_blk;
    assign unused_blk = b_busy | (|b_tc);
    /* verilator lint_on UNUSEDSIGNAL */
  end

  // ---------------------------------------------------------------------------
  // Upper counts line RAM
  // ---------------------------------------------------------------------------
  assign ln_rd_en = start;
  assign ln_wr_en = (st == C_FIN);
  assign ln_wr_data = {cc[7], cc[6], cc[3], cc[2], lc[15], lc[14], lc[13], lc[12]};

  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(40), .ADDR_W(LAW), .READ_LATENCY(1)) u_line (
    .wr_clk(clk), .wr_en(ln_wr_en), .wr_addr(mbx_q), .wr_data(ln_wr_data),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(ln_rd_en), .rd_addr(mb_x[LAW-1:0]), .rd_data(ln_rd_data)
  );

  // ---------------------------------------------------------------------------
  // Sequential logic
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      st      <= C_IDLE;
      rst     <= R_IDLE;
      cbase_q <= '0;
      mbx_q   <= '0;
      avt_q   <= 1'b0;
      avl_q   <= 1'b0;
      mode_q  <= '0;
      cbpc_q  <= '0;
      cbpl_q  <= 1'b0;
      cmode_q <= '0;
      rs      <= '0;
      ri      <= '0;
      rd_v_q  <= 1'b0;
      rd_i_q  <= '0;
      rbuf    <= '0;
      rvalid  <= 1'b0;
      r_item  <= '0;
      bsel    <= 1'b0;
      nsel    <= 1'b0;
      act     <= '0;
      all_disp <= 1'b0;
      pw_n    <= '0;
      pw_data <= '0;
      ln_rd_q <= 1'b0;
      done    <= 1'b0;
      for (int i = 0; i < 16; i++) lc[i] <= '0;
      for (int i = 0; i < 8; i++)  cc[i] <= '0;
      for (int i = 0; i < 4; i++) begin
        ll[i]   <= '0;
        lcl[i]  <= '0;
        tl_l[i] <= '0;
        tl_c[i] <= '0;
      end
    end else begin
      done   <= 1'b0;
      rd_v_q <= (rst == R_ISSUE);
      rd_i_q <= ri;
      ln_rd_q <= ln_rd_en;
      if (ln_rd_q) begin
        for (int i = 0; i < 4; i++) tl_l[i] <= ln_rd_data[5*i +: 5];
        tl_c[0] <= ln_rd_data[20 +: 5];
        tl_c[1] <= ln_rd_data[25 +: 5];
        tl_c[2] <= ln_rd_data[30 +: 5];
        tl_c[3] <= ln_rd_data[35 +: 5];
      end
      if (rd_v_q) rbuf[48*rd_i_q +: 48] <= cram_rd_data;

      // Reader.
      case (rst)
        R_IDLE: begin
          if (start && !pcm) begin
            cbase_q <= cbase;
            rs      <= 5'd0;
            ri      <= 3'd0;
            rvalid  <= 1'b0;
            rst     <= R_ISSUE;
          end
        end
        R_ISSUE: begin
          if (ri == (r_words - 3'd1)) rst <= R_CAP;
          else                        ri  <= ri + 3'd1;
        end
        R_CAP: begin
          rvalid <= 1'b1;
          r_item <= rs;
          rst    <= R_HOLD;
        end
        R_HOLD: begin
          if (rtake) begin
            rvalid <= 1'b0;
            if (next_item(rs, cbpl_q, cbpc_q) == 5'd31) begin
              rst <= R_IDLE;
            end else begin
              rs  <= next_item(rs, cbpl_q, cbpc_q);
              ri  <= 3'd0;
              rst <= R_ISSUE;
            end
          end
        end
        default: rst <= R_IDLE;
      endcase

      // Coder.
      if (blk_done[0]) act[0] <= 1'b0;
      if (blk_done[1]) act[1] <= 1'b0;
      if (blk_done[bsel]) bsel <= ~bsel;
      case (st)
        C_IDLE: begin
          if (start) begin
            mbx_q   <= mb_x[LAW-1:0];
            avt_q   <= av_top;
            avl_q   <= av_left;
            mode_q  <= i16_mode;
            cbpc_q  <= cbp_chroma;
            cbpl_q  <= cbp_luma;
            cmode_q <= chroma_mode;
            cbase_q <= cbase;
            // An I_PCM macroblock counts as 16 coefficients in every block for the neighbours (clause 9.2.1).
            for (int i = 0; i < 16; i++) lc[i] <= pcm ? 5'd16 : 5'd0;
            for (int i = 0; i < 8; i++)  cc[i] <= pcm ? 5'd16 : 5'd0;
            bsel     <= 1'b0;
            nsel     <= 1'b0;
            act      <= '0;
            all_disp <= 1'b0;
            pw_n     <= '0;
            st       <= pcm ? C_P0 : C_H0;
          end
        end
        C_H0: if (cmd_ready) st <= C_H1;
        C_H1: if (cmd_ready) st <= C_H2;
        C_H2: if (cmd_ready) st <= C_BLK;
        C_BLK: begin
          if (disp) begin
            nsel     <= ~nsel;
            act[nsel] <= 1'b1;
            if ((r_item >= 5'd1) && (r_item <= 5'd16)) lc[{blk_by(4'(r_item - 5'd1)), blk_bx(4'(r_item - 5'd1))}] <= pc_blk;
            if ((r_item >= 5'd19) && (r_item <= 5'd22)) cc[3'(r_item - 5'd19)] <= pc_blk;
            if ((r_item >= 5'd23) && (r_item <= 5'd26)) cc[3'(r_item - 5'd23) + 3'd4] <= pc_blk;
            if (last_disp) all_disp <= 1'b1;
          end
          // All blocks dispatched and both coders drained.
          if (all_disp && (act == 2'd0)) st <= C_FIN;
        end
        // I_PCM macroblock: mb_type, alignment, then the 96 sample words (read, wait, emit).
        C_P0: if (cmd_ready) st <= C_P1;
        C_P1: if (cmd_ready) begin
          pw_n <= '0;
          st   <= C_PR;
        end
        C_PR: st <= C_PW;
        C_PW: begin
          pw_data <= cram_rd_data[31:0];
          st      <= C_PE;
        end
        C_PE: begin
          if (cmd_ready) begin
            if (pw_n == 7'd95) begin
              st <= C_FIN;
            end else begin
              pw_n <= pw_n + 7'd1;
              st   <= C_PR;
            end
          end
        end
        C_FIN: begin
          ll[0]  <= lc[3];
          ll[1]  <= lc[7];
          ll[2]  <= lc[11];
          ll[3]  <= lc[15];
          lcl[0] <= cc[1];
          lcl[1] <= cc[3];
          lcl[2] <= cc[5];
          lcl[3] <= cc[7];
          done   <= 1'b1;
          st     <= C_IDLE;
        end
        default: st <= C_IDLE;
      endcase
    end
  end

endmodule
