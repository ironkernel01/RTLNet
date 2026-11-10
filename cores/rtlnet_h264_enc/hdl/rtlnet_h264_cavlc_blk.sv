// -----------------------------------------------------------------------------
// File: rtlnet_h264_cavlc_blk.sv
// Purpose: CAVLC residual block coder of the H.264 encoder (ITU-T Rec. H.264 clause 9.2, encoder side): turns one block
//   of up to 16 coefficient levels into the bit fields of residual_block_cavlc, as a stream of packer FIELD commands.
// Overview:
//   * start loads one block: mode selects maxNumCoeff (0: 16, Intra16x16DCLevel; 1: 15, Intra16x16ACLevel and
//     ChromaACLevel; 2: 4, ChromaDCLevel with nC = -1), nc is the nC of clause 9.2.1 (ignored for mode 2), coef holds
//     16 signed 12-bit levels in coding (scan) order, coef[k] at [12*k +: 12]; entries at and above maxNumCoeff are
//     ignored. Levels satisfy |level| <= 2047 (the quantizer clamps; baseline level_prefix <= 15).
//   * Command stream (cmd_valid / cmd_ready / cmd_val / cmd_len, all PK_FIELD, MSB first): one command with coeff_token
//     and the trailing-one sign bits; one command per remaining level (level_prefix and level_suffix, suffixLength adapted
//     per 9.2.2.1); total_zeros when TotalCoeff < maxNumCoeff; one run_before command per coefficient while zerosLeft > 0
//     (the last coefficient's run is implied). An all-zero block is the coeff_token command only.
//   * Pipeline: PRE (non-zero mask, TotalCoeff, total_zeros) -> T1 (trailing ones, one coefficient per clock, at most 3)
//     -> coeff_token -> LEV (four-stage pipeline: select, level code, format, merge; two levels per clock, their fields merged into
//     one command when the two fit 32 bits, otherwise two commands in two clocks) -> total_zeros -> RUN (two-stage pipeline:
//     two run_before codes per clock in one command, at most 22 bits) -> FIN. The command register is a single slot: every
//     stage advances only when the slot is free or taken (cmd_ready), so cmd_ready low stalls the block.
//   * Latency: an all-zero block takes 3 clocks from start to its command; a block with n non-zero coefficients, t trailing
//     ones: about 5 + t + (n - t) / 2 + 3 + 1 + (n - 1) / 2 + 2 clocks to done. done pulses one clock after the last command is
//     accepted. total_coeff is valid from the clock after PRE and stays until the next start.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version; two levels and two run_before codes per command (throughput).
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_cavlc_blk (
  // Clock and synchronous active-low reset.
  input  logic         clk,
  input  logic         resetn,

  // Block command, clk domain: start pulses one clock when idle.
  input  logic         start,
  input  logic [1:0]   mode,
  input  logic [4:0]   nc,
  input  logic [191:0] coef,
  output logic         busy,
  output logic         done,
  output logic [4:0]   total_coeff,

  // Packer FIELD command stream, clk domain.
  output logic         cmd_valid,
  input  logic         cmd_ready,
  output logic [31:0]  cmd_val,
  output logic [5:0]   cmd_len
);

  import rtlnet_h264_cavlc_tab::*;

  localparam logic [3:0] S_IDLE = 4'd0;
  localparam logic [3:0] S_PRE  = 4'd1;
  localparam logic [3:0] S_T1   = 4'd2;
  localparam logic [3:0] S_TOK  = 4'd3;
  localparam logic [3:0] S_LEV  = 4'd4;
  localparam logic [3:0] S_TZ   = 4'd5;
  localparam logic [3:0] S_RUN0 = 4'd6;
  localparam logic [3:0] S_RUN  = 4'd7;
  localparam logic [3:0] S_FIN  = 4'd8;

  // Index of the highest set bit.
  function automatic logic [3:0] hi(input logic [15:0] x);
    logic [3:0] r;
    r = 4'd0;
    for (int i = 0; i < 16; i++) if (x[i]) r = 4'(i);
    return r;
  endfunction

  logic [3:0]         st;
  logic signed [11:0] c [16];
  logic [4:0]         maxc;
  logic [2:0]         cls;
  logic [15:0]        nzm;
  logic [15:0]        rem;
  logic [4:0]         tc;
  logic [1:0]         t1;
  logic [2:0]         sg;
  logic [4:0]         tz;

  // Level pipeline: two levels per clock (A then B in coding order).
  logic [2:0]         sl;
  logic [4:0]         lcnt;
  logic               lfirst;
  logic               v1a, v1b;
  logic signed [11:0] lv1a, lv1b;
  logic               f1;
  logic               v2a, v2b;
  logic [12:0]        lc2a, lc2b;
  logic [2:0]         sl2a, sl2b;
  logic               v3a, v3b;
  logic [5:0]         len3a, len3b;
  logic [31:0]        val3a, val3b;
  logic               phase2;

  // Run pipeline: two run_before codes per clock.
  logic [3:0]         cur;
  logic [3:0]         zl;
  logic               alive;
  logic [4:0]         rcnt;
  logic               r1va, r1vb;
  logic [3:0]         run1a, run1b;

  // Output command slot.
  logic               o_valid;
  logic [31:0]        o_val;
  logic [5:0]         o_len;
  logic               adv_o;
  logic               adv;
  logic               split;

  logic               emit;
  logic [31:0]        e_val;
  logic [5:0]         e_len;

  assign adv_o       = !o_valid || cmd_ready;
  assign busy        = (st != S_IDLE);
  assign total_coeff = tc;
  assign cmd_valid   = o_valid;
  assign cmd_val     = o_val;
  assign cmd_len     = o_len;

  // ---------------------------------------------------------------------------
  // Combinational analysis of the loaded block
  // ---------------------------------------------------------------------------
  logic [15:0] nz_c;
  logic [4:0]  pc;
  logic [3:0]  top_c;
  always_comb begin
    pc = 5'd0;
    for (int i = 0; i < 16; i++) begin
      nz_c[i] = (c[i] != 12'sd0);
      pc = pc + 5'(nz_c[i]);
    end
    top_c = hi(nz_c);
  end

  // Highest remaining coefficient (A) and the next one below it (B).
  logic [3:0]         t1_idx;
  logic signed [11:0] t1_lv;
  logic               t1_take;
  logic [15:0]        rem_b;
  logic [3:0]         ib_idx;
  logic signed [11:0] ib_lv;
  assign t1_idx  = hi(rem);
  assign t1_lv   = c[t1_idx];
  assign t1_take = (rem != 16'd0) && (t1 != 2'd3) && ((t1_lv == 12'sd1) || (t1_lv == -12'sd1));
  always_comb begin
    rem_b = rem;
    rem_b[t1_idx] = 1'b0;
    ib_idx = hi(rem_b);
    ib_lv  = c[ib_idx];
  end

  // Level stage 2: level codes and suffixLength updates of A and B.
  logic [11:0] mag_a, mag_b;
  logic [12:0] lcode_a, lcode_b;
  logic [2:0]  sl_a1, sl_an, sl_b1, sl_bn;
  logic [6:0]  thr_a, thr_b;
  always_comb begin
    mag_a   = lv1a[11] ? 12'(-lv1a) : 12'(lv1a);
    lcode_a = lv1a[11] ? ({mag_a, 1'b0} - 13'd1) : ({mag_a, 1'b0} - 13'd2);
    if (f1 && (t1 != 2'd3)) lcode_a = lcode_a - 13'd2;
    sl_a1   = (sl == 3'd0) ? 3'd1 : sl;
    thr_a   = 7'd3 << (sl_a1 - 3'd1);
    sl_an   = ((mag_a > 12'(thr_a)) && (sl_a1 < 3'd6)) ? (sl_a1 + 3'd1) : sl_a1;
    mag_b   = lv1b[11] ? 12'(-lv1b) : 12'(lv1b);
    lcode_b = lv1b[11] ? ({mag_b, 1'b0} - 13'd1) : ({mag_b, 1'b0} - 13'd2);
    sl_b1   = (sl_an == 3'd0) ? 3'd1 : sl_an;
    thr_b   = 7'd3 << (sl_b1 - 3'd1);
    sl_bn   = ((mag_b > 12'(thr_b)) && (sl_b1 < 3'd6)) ? (sl_b1 + 3'd1) : sl_b1;
  end

  // Level stage 3: prefix and suffix of a level code, as {length, value} of one field.
  function automatic logic [37:0] fmt_level(input logic [12:0] lc, input logic [2:0] slx);
    logic [4:0]  pre;
    logic [3:0]  sufl;
    logic [11:0] suf;
    logic [15:0] lim;
    lim  = 16'd15 << slx;
    pre  = 5'd0;
    sufl = 4'd0;
    suf  = 12'd0;
    if (slx == 3'd0) begin
      if (lc < 13'd14) begin
        pre = 5'(lc);
      end else if (lc < 13'd30) begin
        pre  = 5'd14;
        sufl = 4'd4;
        suf  = 12'(lc - 13'd14);
      end else begin
        pre  = 5'd15;
        sufl = 4'd12;
        suf  = 12'(lc - 13'd30);
      end
    end else if ({3'd0, lc} < lim) begin
      pre  = 5'(lc >> slx);
      sufl = 4'(slx);
      suf  = 12'(lc & ((13'd1 << slx) - 13'd1));
    end else begin
      pre  = 5'd15;
      sufl = 4'd12;
      suf  = 12'(lc - lim[12:0]);
    end
    return {6'(pre) + 6'd1 + 6'(sufl), (32'd1 << sufl) | 32'(suf)};
  endfunction

  logic [37:0] fa, fb;
  logic [5:0]  len_a, len_b;
  logic [31:0] val_a, val_b;
  assign fa    = fmt_level(lc2a, sl2a);
  assign fb    = fmt_level(lc2b, sl2b);
  assign len_a = fa[37:32];
  assign val_a = fa[31:0];
  assign len_b = fb[37:32];
  assign val_b = fb[31:0];
  // A pair whose two fields do not fit in one 32-bit command goes out in two clocks (phase2 = second clock).
  assign split = v3a && v3b && ({1'b0, len3a} + {1'b0, len3b} > 7'd32);
  assign adv   = adv_o && !(split && !phase2);

  // Table lookups.
  logic [10:0] tok;
  logic [12:0] tzr;
  logic [4:0]  tzcr;
  logic [14:0] rba, rbb;
  logic [2:0]  zlca, zlcb;
  logic [3:0]  zl_b;
  assign tok  = ct(cls, tc, t1);
  assign tzr  = tz4(tc[3:0], tz[3:0]);
  assign tzcr = tzc(tc[1:0], tz[1:0]);
  assign zl_b = zl - run1a;
  assign zlca = (zl > 4'd7) ? 3'd7 : zl[2:0];
  assign zlcb = (zl_b > 4'd7) ? 3'd7 : zl_b[2:0];
  assign rba  = rb(zlca, run1a);
  assign rbb  = rb(zlcb, run1b);

  // Command of this clock.
  always_comb begin
    emit  = 1'b0;
    e_val = 32'd0;
    e_len = 6'd0;
    if (v3a) begin
      emit = 1'b1;
      if (v3b && !split) begin
        e_val = (val3a << len3b) | val3b;
        e_len = len3a + len3b;
      end else if (split && phase2) begin
        e_val = val3b;
        e_len = len3b;
      end else begin
        e_val = val3a;
        e_len = len3a;
      end
    end else begin
      case (st)
        S_TOK: begin
          emit  = 1'b1;
          e_val = (32'(tok[5:0]) << t1) | 32'(sg);
          e_len = 6'(tok[10:6]) + 6'(t1);
        end
        S_TZ: begin
          if (tc < maxc) begin
            emit = 1'b1;
            if (maxc == 5'd4) begin
              e_val = 32'(tzcr[2:0]);
              e_len = 6'(tzcr[4:3]);
            end else begin
              e_val = 32'(tzr[8:0]);
              e_len = 6'(tzr[12:9]);
            end
          end
        end
        S_RUN: begin
          if (r1va && alive) begin
            emit  = 1'b1;
            e_val = 32'(rba[10:0]);
            e_len = 6'(rba[14:11]);
            // Second run_before of the pair: coded while zerosLeft remains after the first.
            if (r1vb && (zl != run1a)) begin
              e_val = (32'(rba[10:0]) << rbb[14:11]) | 32'(rbb[10:0]);
              e_len = 6'(rba[14:11]) + 6'(rbb[14:11]);
            end
          end
        end
        default: begin
        end
      endcase
    end
  end

  // Load values.
  logic [4:0] maxc_n;
  logic [2:0] cls_n;
  always_comb begin
    case (mode)
      2'd1:    maxc_n = 5'd15;
      2'd2:    maxc_n = 5'd4;
      default: maxc_n = 5'd16;
    endcase
    if (mode == 2'd2)       cls_n = 3'd4;
    else if (nc < 5'd2)     cls_n = 3'd0;
    else if (nc < 5'd4)     cls_n = 3'd1;
    else if (nc < 5'd8)     cls_n = 3'd2;
    else                    cls_n = 3'd3;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      st      <= S_IDLE;
      maxc    <= '0;
      cls     <= '0;
      nzm     <= '0;
      rem     <= '0;
      tc      <= '0;
      t1      <= '0;
      sg      <= '0;
      tz      <= '0;
      sl      <= '0;
      lcnt    <= '0;
      lfirst  <= 1'b0;
      v1a     <= 1'b0;
      v1b     <= 1'b0;
      lv1a    <= '0;
      lv1b    <= '0;
      f1      <= 1'b0;
      v2a     <= 1'b0;
      v2b     <= 1'b0;
      lc2a    <= '0;
      lc2b    <= '0;
      sl2a    <= '0;
      sl2b    <= '0;
      v3a     <= 1'b0;
      v3b     <= 1'b0;
      len3a   <= '0;
      len3b   <= '0;
      val3a   <= '0;
      val3b   <= '0;
      phase2  <= 1'b0;
      cur     <= '0;
      zl      <= '0;
      alive   <= 1'b0;
      rcnt    <= '0;
      r1va    <= 1'b0;
      r1vb    <= 1'b0;
      run1a   <= '0;
      run1b   <= '0;
      o_valid <= 1'b0;
      o_val   <= '0;
      o_len   <= '0;
      done    <= 1'b0;
      for (int i = 0; i < 16; i++) c[i] <= '0;
    end else begin
      done <= 1'b0;
      if (adv_o) begin
        o_valid <= emit;
        if (emit) begin
          o_val <= e_val;
          o_len <= e_len;
        end
        if (split) phase2 <= !phase2;
      end

      if (adv) begin
        // Level pipeline stage 2 and 3 registers (free running while the state is not LEV, they hold zeros).
        v2a  <= v1a;
        v2b  <= v1b;
        lc2a <= lcode_a;
        lc2b <= lcode_b;
        sl2a <= sl;
        sl2b <= sl_an;
        v3a  <= v2a;
        v3b  <= v2b;
        len3a <= len_a;
        len3b <= len_b;
        val3a <= val_a;
        val3b <= val_b;
        if (v1a) sl <= v1b ? sl_bn : sl_an;

        case (st)
          S_IDLE: begin
            if (start) begin
              maxc <= maxc_n;
              cls  <= cls_n;
              for (int i = 0; i < 16; i++) c[i] <= (5'(i) < maxc_n) ? coef[12*i +: 12] : 12'sd0;
              st   <= S_PRE;
            end
          end
          S_PRE: begin
            nzm <= nz_c;
            rem <= nz_c;
            tc  <= pc;
            tz  <= (pc == 5'd0) ? 5'd0 : (5'(top_c) + 5'd1 - pc);
            t1  <= 2'd0;
            sg  <= 3'd0;
            st  <= (pc == 5'd0) ? S_TOK : S_T1;
          end
          S_T1: begin
            if (t1_take) begin
              t1 <= t1 + 2'd1;
              sg <= {sg[1:0], t1_lv[11]};
              rem[t1_idx] <= 1'b0;
              if (t1 == 2'd2) st <= S_TOK;
            end else begin
              st <= S_TOK;
            end
          end
          S_TOK: begin
            if (tc == 5'd0) begin
              st <= S_FIN;
            end else begin
              sl     <= ((tc > 5'd10) && (t1 != 2'd3)) ? 3'd1 : 3'd0;
              lcnt   <= tc - 5'(t1);
              lfirst <= 1'b1;
              st     <= (tc == 5'(t1)) ? S_TZ : S_LEV;
            end
          end
          S_LEV: begin
            if (lcnt != 5'd0) begin
              lv1a   <= c[t1_idx];
              v1a    <= 1'b1;
              f1     <= lfirst;
              lfirst <= 1'b0;
              rem[t1_idx] <= 1'b0;
              if (lcnt >= 5'd2) begin
                lv1b <= ib_lv;
                v1b  <= 1'b1;
                rem[ib_idx] <= 1'b0;
                lcnt <= lcnt - 5'd2;
              end else begin
                v1b  <= 1'b0;
                lcnt <= 5'd0;
              end
            end else begin
              v1a <= 1'b0;
              v1b <= 1'b0;
              if (!v1a && !v2a) st <= S_TZ;
            end
          end
          S_TZ: begin
            st <= ((tc >= 5'd2) && (tz != 5'd0) && (tc < maxc)) ? S_RUN0 : S_FIN;
          end
          S_RUN0: begin
            cur   <= hi(nzm);
            rem   <= nzm;
            rem[hi(nzm)] <= 1'b0;
            zl    <= tz[3:0];
            alive <= 1'b1;
            rcnt  <= tc - 5'd1;
            r1va  <= 1'b0;
            r1vb  <= 1'b0;
            st    <= S_RUN;
          end
          S_RUN: begin
            if ((rcnt != 5'd0) && alive) begin
              run1a <= cur - t1_idx - 4'd1;
              r1va  <= 1'b1;
              rem[t1_idx] <= 1'b0;
              if (rcnt >= 5'd2) begin
                run1b <= t1_idx - ib_idx - 4'd1;
                cur   <= ib_idx;
                r1vb  <= 1'b1;
                rem[ib_idx] <= 1'b0;
                rcnt  <= rcnt - 5'd2;
              end else begin
                cur   <= t1_idx;
                r1vb  <= 1'b0;
                rcnt  <= rcnt - 5'd1;
              end
            end else begin
              r1va <= 1'b0;
              r1vb <= 1'b0;
              if (!r1va) st <= S_FIN;
            end
            if (r1va && alive) begin
              if (r1vb && (zl != run1a)) begin
                zl <= zl_b - run1b;
                if (zl_b == run1b) alive <= 1'b0;
              end else begin
                zl <= zl_b;
                if (zl == run1a) alive <= 1'b0;
              end
            end
          end
          S_FIN: begin
            done <= 1'b1;
            st   <= S_IDLE;
          end
          default: st <= S_IDLE;
        endcase
      end
    end
  end

endmodule
