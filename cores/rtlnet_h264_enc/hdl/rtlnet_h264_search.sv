// -----------------------------------------------------------------------------
// File: rtlnet_h264_search.sv
// Purpose: integer-pel motion search of the 16 x 16 partition with one reference picture (phase 2c-2): the sliding search window of
//   reference tiles, the window loader (one new column of tiles per macroblock), the candidate and refinement search over a
//   SAD unit, and the prediction generator (luma at the integer vector, chroma by the clause 8.4.2.2.2 bilinear filter) that fills
//   the prediction buffer stage A reads. Documentation section 16.
// Overview:
//   * Window. Two window RAMs (rtlnet_ram_core, 128 bit, WIN_KB KiB each) hold four columns of reference tiles, slot = column index
//     mod 4: the columns c - 1, c, c + 1 of the macroblock being searched and the column c + 2 being prefetched. Adjacent columns
//     have adjacent slots, so one RAM holds the even slots and the other the odd ones, and a 16 sample row at any horizontal offset
//     (two adjacent tile rows, shifted) is read in one clock, one word from each RAM. Per RAM and slot pair: 3 macroblock rows (r - 1,
//     r, r + 1) x (16 luma words + 8 chroma words): luma word {slot[1], wr, y}, chroma word 128 + {slot[1], wr, beat}.
//     A column load is up to three 16-beat luma and three 8-beat chroma tile bursts (rows that exist), so every reference tile is
//     read three times per picture. The loader runs ahead of the search by at most the free slot: column g may load while
//     g < first column the current search still needs + 4. The search of a macroblock starts when its last column is loaded.
//     At the start of a macroblock row the loader continues with the next row's columns while the last macroblocks of the row search.
//   * Search range. Integer vectors, |vx|, |vy| <= SR (SR 16 at most: the window covers one macroblock in each direction), and
//     every candidate keeps the 16 x 16 block inside the picture (documentation 16.4): the lower bound of a component is 0 in the
//     first column / row and -SR elsewhere, the upper bound 0 in the last column / row and SR elsewhere.
//   * Search (documentation 16.5). The metric is the SAD over the 8 even rows of the macroblock (16 samples per clock, 8 clocks per
//     candidate), cost = 2 x SAD + lambda x bits(mvd) against the approximate predictor. Candidates: (0,0), the predictor,
//     the left, above and above-right (else above-left) vectors and the vector of the macroblock searched just before in raster order
//     (the last one of the previous row at a row start, of the previous picture at a picture start: a global motion carries on across rows and
//     pictures), deduplicated and legality filtered; then step stages around the best
//     candidate: d = 16 (4 points), 8 (8 points), 4 (8 points), 2 (4), 1 (4) with at most 2, 3, 2, 2, 3 repeats while the best point
//     moves; the stages d >= 2 are skipped when the best cost is at most GOOD_COST; the total of evaluated candidates is capped by MAX_EVAL.
//     The predictor and the neighbours are the search's own previous vectors (the left macroblock's final vector is not known yet when
//     this stage runs one macroblock ahead of stage A): an approximation, stage A computes the exact predictor.
//   * Prediction. After the search the luma block at the best vector (16 rows) and the chroma blocks (9 source rows per plane through
//     rtlnet_h264_cinterp, xFracC = 4 x (vx & 1), yFracC = 4 x (vy & 1)) are written to the prediction buffer in the 2c-1 layout
//     (luma word y, Cb words 16 + k, Cr words 20 + k with rows 2k and 2k + 1).
//   * Source. The luma rows 0, 2, ..., 14 of the macroblock are copied from the strip buffer (through the engine's arbitrated read
//     port: a read only in a clock the coder does not use the port) into a small buffer (SRCBUF_STYLE).
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-2).
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_search #(
  parameter int    ADDR_W       = 32,
  parameter int    MAX_MB_W     = 120,
  parameter int    SR           = 16,       // search range in whole samples, 0 .. 16 (0: only the vector (0, 0))
  parameter int    WIN_KB       = 4,        // each of the two window RAMs, KiB (needs 144 words of 16 bytes at least: 4 KiB)
  parameter int    MV_LINE_KB   = 1,        // search vector line RAM
  parameter int    SRC_AW       = 7,
  parameter int    REF_AW       = 6,
  parameter int    MAX_EVAL     = 48,       // candidates evaluated per macroblock at most (checked before each step)
  parameter int    GOOD_COST    = 768,      // best cost at or below which the large steps are skipped
  parameter int    ZERO_BIAS    = 128,      // cost added to every vector but (0,0): a static scene must keep the zero vector (P_Skip)
  parameter string RAM_STYLE    = "block",
  parameter string SRCBUF_STYLE = "distributed"
)(
  input  logic                 clk,
  input  logic                 resetn,

  // Picture start (P pictures): geometry, reference picture tile bases, the engine's band. cfg_* hold while the picture runs.
  input  logic                 pic_start,
  input  logic [7:0]           cfg_mb_w,
  input  logic [7:0]           cfg_mb_h,
  input  logic [7:0]           band_first_row,
  input  logic [7:0]           band_rows,
  input  logic [ADDR_W-1:0]    ref_y_base,
  input  logic [ADDR_W-1:0]    ref_u_base,
  input  logic [5:0]           qp,

  // Window loader's AR / R channel. win_req asks for the channel; the owner of the channel grants with win_go (one clock, only while
  // no other read owns it); win_busy covers the loader's use from the clock after win_go until its last beat.
  output logic                 win_req,
  input  logic                 win_go,
  output logic                 win_busy,
  output logic [ADDR_W-1:0]    win_araddr,
  output logic [7:0]           win_arlen,
  output logic                 win_arvalid,
  input  logic                 win_arready,
  input  logic [127:0]         win_rdata,
  input  logic [1:0]           win_rresp,
  input  logic                 win_rvalid,
  output logic                 win_rready,
  output logic                 err_resp,

  // Macroblock command: start pulses one clock when mb_idle; the next macroblock of the band in raster order is searched.
  input  logic                 mb_start,
  input  logic [SRC_AW-1:0]    mb_src_base,
  input  logic [REF_AW-1:0]    mb_pred_base,
  output logic                 mb_idle,
  output logic                 mb_done,
  output logic signed [5:0]    mb_vx,
  output logic signed [5:0]    mb_vy,

  // Source rows: the read is performed in the clock where src_rd_req and src_rd_gnt are both high; the data is valid the clock after.
  output logic                 src_rd_req,
  output logic [SRC_AW-1:0]    src_rd_addr,
  input  logic                 src_rd_gnt,
  input  logic [127:0]         src_rd_data,

  // Prediction buffer write port.
  output logic                 pred_we,
  output logic [REF_AW-1:0]    pred_addr,
  output logic [127:0]         pred_data,

  // No macroblock running and no load pending (the picture is finished).
  output logic                 idle,

  // Bench visibility: every candidate result as it leaves the SAD unit.
  output logic                 dbg_ev_v,
  output logic signed [5:0]    dbg_ev_vx,
  output logic signed [5:0]    dbg_ev_vy,
  output logic [18:0]          dbg_ev_sad,
  output logic [16:0]          dbg_best_cost   // cost of the best candidate (valid at mb_done)
);

  import rtlnet_h264_pkg::*;

  localparam int WIN_AW = $clog2(WIN_KB * 1024 / 16);

  generate
    if (WIN_AW < 8) begin : g_win_small
      $fatal(1, "rtlnet_h264_search: WIN_KB=%0d too small (the window needs 144 words of 16 bytes per RAM: 4 KiB)", WIN_KB);
    end
    if ((SR < 0) || (SR > 16)) begin : g_sr
      $fatal(1, "rtlnet_h264_search: SR=%0d, must be 0 .. 16 (the window holds one macroblock in each direction)", SR);
    end
  endgenerate

  // Job kinds of the read issue stage.
  localparam logic [1:0] K_SAD  = 2'd0;
  localparam logic [1:0] K_LUMA = 2'd1;
  localparam logic [1:0] K_CH   = 2'd2;

  // Macroblock sequencer states.
  localparam logic [3:0] M_IDLE = 4'd0;
  localparam logic [3:0] M_WAIT = 4'd1;
  localparam logic [3:0] M_PREP = 4'd2;
  localparam logic [3:0] M_COPY = 4'd3;
  localparam logic [3:0] M_CAND = 4'd4;
  localparam logic [3:0] M_EVST = 4'd5;
  localparam logic [3:0] M_EV   = 4'd6;
  localparam logic [3:0] M_D    = 4'd7;
  localparam logic [3:0] M_PROP = 4'd8;
  localparam logic [3:0] M_D2   = 4'd9;
  localparam logic [3:0] M_PY   = 4'd10;
  localparam logic [3:0] M_PYW  = 4'd11;
  localparam logic [3:0] M_PC   = 4'd12;
  localparam logic [3:0] M_PCW  = 4'd13;
  localparam logic [3:0] M_FIN  = 4'd14;

  // ---------------------------------------------------------------------------
  // Picture and position state
  // ---------------------------------------------------------------------------
  logic              active;
  logic [7:0]        w_q, h_q, brow_q;
  logic [15:0]       tot_cols;
  logic [6:0]        pc;                // column of the next macroblock to search
  logic [7:0]        prabs;             // its absolute row
  logic [7:0]        pri;               // its row inside the band
  logic [15:0]       prowbase;          // global load index of column 0 of its row
  logic [15:0]       keep_g;            // first column the search still needs
  logic [15:0]       lim_g;             // last column it needs

  logic [3:0]        st;
  logic [SRC_AW-1:0] src_base_q;
  logic [REF_AW-1:0] pred_base_q;
  logic [1:0]        s0;                // slot of window column c - 1
  logic signed [7:0] vlo_x, vhi_x, vlo_y, vhi_y;
  logic              av_top_q, av_left_q, av_tr_q;
  logic [6:0]        pc_q;              // column of the macroblock being searched
  logic [7:0]        lam_q;

  assign keep_g = prowbase + ((pc == 7'd0) ? 16'd0 : (16'(pc) - 16'd1));
  assign lim_g  = prowbase + (((8'(pc) + 8'd1) < w_q) ? (16'(pc) + 16'd1) : (16'(w_q) - 16'd1));

  // ---------------------------------------------------------------------------
  // Window RAMs and the loader
  // ---------------------------------------------------------------------------
  logic              wr_en0, wr_en1;
  logic [7:0]        wr_addr;
  logic              rd_en_w;
  logic [7:0]        rd_addr0, rd_addr1;
  logic [127:0]      rd_data0, rd_data1;

  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(WIN_AW), .READ_LATENCY(1)) u_win0 (
    .wr_clk(clk), .wr_en(wr_en0), .wr_addr(wr_addr[WIN_AW-1:0]), .wr_data(win_rdata),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(rd_en_w), .rd_addr(rd_addr0[WIN_AW-1:0]), .rd_data(rd_data0)
  );
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(WIN_AW), .READ_LATENCY(1)) u_win1 (
    .wr_clk(clk), .wr_en(wr_en1), .wr_addr(wr_addr[WIN_AW-1:0]), .wr_data(win_rdata),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(rd_en_w), .rd_addr(rd_addr1[WIN_AW-1:0]), .rd_data(rd_data1)
  );

  logic [15:0]       ld_g;
  logic [6:0]        ld_k;
  logic [7:0]        ld_row;
  logic [ADDR_W-1:0] y_cur, c_cur;
  logic              init_run;
  logic [7:0]        init_cnt;
  logic [ADDR_W-1:0] sy_w, sc_w;

  assign sy_w = ADDR_W'({w_q, 8'd0});
  assign sc_w = ADDR_W'({w_q, 7'd0});

  // Loader DMA state: a list of up to six bursts (row 0 luma, chroma, row 1 ..., row 2 ...), the entries of absent rows skipped.
  logic [ADDR_W-1:0] lst_addr [6];
  logic [1:0]        lst_wr [6];
  logic              lst_ch [6];
  logic [2:0]        ar_i, r_i, lst_end;
  logic [4:0]        r_b;
  logic [1:0]        slot_q;
  logic              ar_run;

  assign win_req = active && !init_run && !win_busy && (ld_g < tot_cols) && (ld_g < (keep_g + 16'd4));

  assign win_araddr  = lst_addr[ar_i];
  assign win_arlen   = lst_ch[ar_i] ? 8'd7 : 8'd15;
  assign win_arvalid = ar_run;
  assign win_rready  = win_busy;
  assign err_resp    = win_busy && win_rvalid && (win_rresp != 2'b00);

  logic [4:0] r_len_m1;
  assign r_len_m1 = lst_ch[r_i] ? 5'd7 : 5'd15;
  assign wr_addr  = lst_ch[r_i] ? {1'b1, slot_q[1], 1'b0, lst_wr[r_i], r_b[2:0]} : {1'b0, slot_q[1], lst_wr[r_i], r_b[3:0]};
  assign wr_en0   = win_busy && win_rvalid && !slot_q[0];
  assign wr_en1   = win_busy && win_rvalid && slot_q[0];

  always_ff @(posedge clk) begin
    if (!resetn) begin
      active    <= 1'b0;
      w_q       <= '0;
      h_q       <= '0;
      brow_q    <= '0;
      tot_cols  <= '0;
      ld_g      <= '0;
      ld_k      <= '0;
      ld_row    <= '0;
      y_cur     <= '0;
      c_cur     <= '0;
      init_run  <= 1'b0;
      init_cnt  <= '0;
      win_busy  <= 1'b0;
      ar_run    <= 1'b0;
      ar_i      <= '0;
      r_i       <= '0;
      lst_end   <= '0;
      r_b       <= '0;
      slot_q    <= '0;
      for (int i = 0; i < 6; i++) begin
        lst_addr[i] <= '0;
        lst_wr[i]   <= '0;
        lst_ch[i]   <= 1'b0;
      end
    end else begin
      // Picture start: the loader positions its tile pointers on the first row of the band (one row per clock), then loads.
      if (pic_start) begin
        active   <= 1'b1;
        w_q      <= cfg_mb_w;
        h_q      <= cfg_mb_h;
        brow_q   <= band_rows;
        ld_g     <= '0;
        ld_k     <= '0;
        ld_row   <= band_first_row;
        y_cur    <= ref_y_base;
        c_cur    <= ref_u_base;
        init_run <= 1'b1;
        init_cnt <= band_first_row;
      end else if (init_run) begin
        tot_cols <= 16'(brow_q) * 16'(w_q);
        if (init_cnt != 8'd0) begin
          y_cur    <= y_cur + sy_w;
          c_cur    <= c_cur + sc_w;
          init_cnt <= init_cnt - 8'd1;
        end else begin
          init_run <= 1'b0;
        end
      end

      // Column load.
      if (win_go && !win_busy) begin
        win_busy <= 1'b1;
        slot_q   <= ld_g[1:0];
        lst_addr[0] <= y_cur - sy_w;  lst_wr[0] <= 2'd0;  lst_ch[0] <= 1'b0;
        lst_addr[1] <= c_cur - sc_w;  lst_wr[1] <= 2'd0;  lst_ch[1] <= 1'b1;
        lst_addr[2] <= y_cur;         lst_wr[2] <= 2'd1;  lst_ch[2] <= 1'b0;
        lst_addr[3] <= c_cur;         lst_wr[3] <= 2'd1;  lst_ch[3] <= 1'b1;
        lst_addr[4] <= y_cur + sy_w;  lst_wr[4] <= 2'd2;  lst_ch[4] <= 1'b0;
        lst_addr[5] <= c_cur + sc_w;  lst_wr[5] <= 2'd2;  lst_ch[5] <= 1'b1;
        ar_i    <= (ld_row != 8'd0) ? 3'd0 : 3'd2;
        r_i     <= (ld_row != 8'd0) ? 3'd0 : 3'd2;
        lst_end <= ((ld_row + 8'd1) < h_q) ? 3'd6 : 3'd4;
        r_b     <= '0;
        ar_run  <= 1'b1;
      end
      if (ar_run && win_arready) begin
        ar_i <= ar_i + 3'd1;
        if ((ar_i + 3'd1) == lst_end) ar_run <= 1'b0;
      end
      if (win_busy && win_rvalid) begin
        if (r_b == r_len_m1) begin
          r_b <= '0;
          r_i <= r_i + 3'd1;
          if ((r_i + 3'd1) == lst_end) begin
            win_busy <= 1'b0;
            ld_g     <= ld_g + 16'd1;
            y_cur    <= y_cur + 32'd256;
            c_cur    <= c_cur + 32'd128;
            if (ld_k == (7'(w_q) - 7'd1)) begin
              ld_k   <= '0;
              ld_row <= ld_row + 8'd1;
            end else begin
              ld_k <= ld_k + 7'd1;
            end
          end
        end else begin
          r_b <= r_b + 5'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Candidate list, best result and step state
  // ---------------------------------------------------------------------------
  logic signed [5:0] lx [8];
  logic signed [5:0] ly [8];
  logic [3:0]        ln;                // entries in the list (0 .. 8)
  logic [16:0]       rate_r [8];
  logic [16:0]       best_cost;
  logic signed [5:0] bx, by;            // best vector
  logic signed [7:0] cx, cy;            // centre of the step stages
  logic signed [5:0] gm_x, gm_y;        // vector of the macroblock searched last (raster order, across rows and pictures)
  logic [2:0]        stage;             // 0..4: d = 16, 8, 4, 2, 1; 5: done
  logic [1:0]        iter;
  logic [6:0]        ev_cnt;
  logic              ph_cand;
  logic [2:0]        pi;                // candidate proposal index 0..4 / point index 0..7
  logic              ctx_start;
  logic              ctx_ready_seen;
  logic [3:0]        drain;

  logic [6:0]        res_rem;           // candidate results still to arrive and be compared

  // Search vector context (the search's own previous vectors).
  logic                 ctx_ready;
  logic signed [13:0]   mvp_x, mvp_y, sk_x, sk_y;
  logic                 sk_zero;
  logic                 nb_a_i, nb_b_i, nb_c_i, nb_d_i;
  logic signed [13:0]   nb_ax, nb_ay, nb_bx, nb_by, nb_cx, nb_cy, nb_dx, nb_dy;
  logic                 ctx_upd;
  logic signed [13:0]   ctx_upd_x, ctx_upd_y;

  rtlnet_h264_mvctx #(.MAX_MB_W(MAX_MB_W), .MV_LINE_KB(MV_LINE_KB), .RAM_STYLE(RAM_STYLE)) u_ctx (
    .clk(clk), .resetn(resetn),
    .start(ctx_start), .mb_x(pc_q), .av_top(av_top_q), .av_left(av_left_q), .av_tr(av_tr_q),
    .ready(ctx_ready), .mvp_x(mvp_x), .mvp_y(mvp_y), .skip_x(sk_x), .skip_y(sk_y), .skip_zero(sk_zero),
    .nb_a_inter(nb_a_i), .nb_a_mvx(nb_ax), .nb_a_mvy(nb_ay),
    .nb_b_inter(nb_b_i), .nb_b_mvx(nb_bx), .nb_b_mvy(nb_by),
    .nb_c_inter(nb_c_i), .nb_c_mvx(nb_cx), .nb_c_mvy(nb_cy),
    .nb_d_inter(nb_d_i), .nb_d_mvx(nb_dx), .nb_d_mvy(nb_dy),
    .upd(ctx_upd), .upd_inter(1'b1), .upd_mvx(ctx_upd_x), .upd_mvy(ctx_upd_y)
  );

  // The skip vector and its flag are not used by the search (the skip vector is the predictor or (0,0), both candidates).
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ctx;
  assign unused_ctx = sk_zero ^ (^sk_x) ^ (^sk_y) ^ (^nb_ax[1:0]) ^ (^nb_ay[1:0]) ^ (^nb_bx[1:0]) ^ (^nb_by[1:0]) ^ (^nb_cx[1:0]) ^
                      (^nb_cy[1:0]) ^ (^nb_dx[1:0]) ^ (^nb_dy[1:0]) ^ (^mvp_x[1:0]) ^ (^mvp_y[1:0]);
  /* verilator lint_on UNUSEDSIGNAL */

  // Step stage parameters.
  logic signed [7:0] dval;
  logic              sq_pat;
  logic [1:0]        maxit;
  always_comb begin
    case (stage)
      3'd0:    begin dval = 8'sd16; sq_pat = 1'b1; maxit = 2'd3; end
      3'd1:    begin dval = 8'sd8;  sq_pat = 1'b1; maxit = 2'd3; end
      3'd2:    begin dval = 8'sd4;  sq_pat = 1'b1; maxit = 2'd2; end
      3'd3:    begin dval = 8'sd2;  sq_pat = 1'b0; maxit = 2'd2; end
      default: begin dval = 8'sd1;  sq_pat = 1'b0; maxit = 2'd3; end
    endcase
  end

  // Proposal (one candidate vector per clock in M_CAND and M_PROP).
  logic signed [7:0] prop_x, prop_y;
  logic              prop_v;
  logic              prop_legal, prop_dup, prop_ok;
  always_comb begin
    prop_x = 8'sd0;
    prop_y = 8'sd0;
    prop_v = 1'b0;
    if (st == M_CAND) begin
      case (pi)
        3'd0: begin prop_x = 8'sd0; prop_y = 8'sd0; prop_v = 1'b1; end
        3'd1: begin prop_x = 8'(mvp_x >>> 2); prop_y = 8'(mvp_y >>> 2); prop_v = 1'b1; end
        3'd2: begin prop_x = 8'(nb_ax >>> 2); prop_y = 8'(nb_ay >>> 2); prop_v = av_left_q && nb_a_i; end
        3'd3: begin prop_x = 8'(nb_bx >>> 2); prop_y = 8'(nb_by >>> 2); prop_v = av_top_q && nb_b_i; end
        3'd4: begin
          if (av_tr_q) begin
            prop_x = 8'(nb_cx >>> 2); prop_y = 8'(nb_cy >>> 2); prop_v = nb_c_i;
          end else begin
            prop_x = 8'(nb_dx >>> 2); prop_y = 8'(nb_dy >>> 2); prop_v = av_top_q && av_left_q && nb_d_i;
          end
        end
        default: begin prop_x = 8'(gm_x); prop_y = 8'(gm_y); prop_v = 1'b1; end
      endcase
    end else begin
      case (pi)
        3'd0: begin prop_x = cx + dval; prop_y = cy;        end
        3'd1: begin prop_x = cx - dval; prop_y = cy;        end
        3'd2: begin prop_x = cx;        prop_y = cy + dval; end
        3'd3: begin prop_x = cx;        prop_y = cy - dval; end
        3'd4: begin prop_x = cx + dval; prop_y = cy + dval; end
        3'd5: begin prop_x = cx - dval; prop_y = cy + dval; end
        3'd6: begin prop_x = cx + dval; prop_y = cy - dval; end
        default: begin prop_x = cx - dval; prop_y = cy - dval; end
      endcase
      prop_v = (pi < 3'd4) || sq_pat;
    end
    prop_legal = (prop_x >= vlo_x) && (prop_x <= vhi_x) && (prop_y >= vlo_y) && (prop_y <= vhi_y);
    prop_dup   = 1'b0;
    for (int i = 0; i < 8; i++) begin
      if ((4'(i) < ln) && (8'(lx[i]) == prop_x) && (8'(ly[i]) == prop_y)) prop_dup = 1'b1;
    end
    prop_ok = prop_v && prop_legal && !prop_dup;
  end

  // ---------------------------------------------------------------------------
  // Read issue: a sequencer drives the issue registers (stage I0), one row per clock
  // ---------------------------------------------------------------------------
  logic              iq_run;
  logic [1:0]        iq_kind;
  logic [2:0]        iq_idx;
  logic [3:0]        iq_row;
  logic              iq_pl;

  logic              i0_v;
  logic [1:0]        i0_kind;
  logic signed [5:0] i0_vx, i0_vy;
  logic [3:0]        i0_row;
  logic [2:0]        i0_idx;
  logic              i0_pl;
  logic              i0_first, i0_last;

  // Address generation (clock of I0): two window words per row, the left tile's word from the RAM of its slot parity.
  logic [5:0]        xx_l;
  logic [5:0]        yy_l;
  logic [4:0]        xs_c;
  logic [4:0]        sy_c;
  logic [1:0]        slot_l;
  logic              slot_r_hi;   // bit 1 of the right tile's slot (slot_l + 1; its bit 0 is the opposite of slot_l[0])
  logic [7:0]        addr_l, addr_r;
  logic [3:0]        sh_l;
  logic [2:0]        off_c;
  logic [3:0]        j_l;
  logic [2:0]        ry_c;
  always_comb begin
    j_l  = (i0_kind == K_SAD) ? {i0_row[2:0], 1'b0} : i0_row;
    xx_l = 6'(8'sd16 + 8'(i0_vx));
    yy_l = 6'(8'sd16 + 8'(i0_vy)) + 6'(j_l);
    xs_c = 5'(8'sd8 + 8'(i0_vx >>> 1));
    sy_c = 5'(8'sd8 + 8'(i0_vy >>> 1)) + 5'(i0_row);
    ry_c = sy_c[2:0];
    if (i0_kind == K_CH) begin
      slot_l = s0 + xs_c[4:3];
      slot_r_hi = slot_l[1] ^ slot_l[0];
      addr_l = {1'b1, slot_l[1], 1'b0, sy_c[4:3], i0_pl, ry_c[2:1]};
      addr_r = {1'b1, slot_r_hi, 1'b0, sy_c[4:3], i0_pl, ry_c[2:1]};
      sh_l   = 4'd0;
      off_c  = xs_c[2:0];
    end else begin
      slot_l = s0 + xx_l[5:4];
      slot_r_hi = slot_l[1] ^ slot_l[0];
      addr_l = {1'b0, slot_l[1], yy_l[5:4], yy_l[3:0]};
      addr_r = {1'b0, slot_r_hi, yy_l[5:4], yy_l[3:0]};
      sh_l   = xx_l[3:0];
      off_c  = 3'd0;
    end
    // The RAM of even slots is 0, of odd slots 1: the left tile word is read from RAM slot_l[0], the right one from the other.
    rd_addr0 = slot_l[0] ? addr_r : addr_l;
    rd_addr1 = slot_l[0] ? addr_l : addr_r;
  end
  assign rd_en_w = i0_v;

  // Source copy buffer (rows 0, 2, ..., 14 of the macroblock).
  logic              cp_run;
  logic [4:0]        cp_n;              // reads granted so far
  logic              cp_v1;
  logic [2:0]        cp_a1;
  logic              cp_done;
  logic [127:0]      sb_data;
  logic              sb_rd_en;
  logic [2:0]        sb_rd_addr;

  assign src_rd_req  = cp_run && (cp_n < 5'd8);
  assign src_rd_addr = src_base_q + SRC_AW'({cp_n[2:0], 1'b0});

  rtlnet_ram_core #(.RAM_STYLE(SRCBUF_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(3), .READ_LATENCY(1)) u_srcbuf (
    .wr_clk(clk), .wr_en(cp_v1), .wr_addr(cp_a1), .wr_data(src_rd_data),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(sb_rd_en), .rd_addr(sb_rd_addr), .rd_data(sb_data)
  );
  assign sb_rd_en   = i0_v && (i0_kind == K_SAD);
  assign sb_rd_addr = i0_row[2:0];

  // Stage I1: the clock of the RAM data.
  logic              p1_v;
  logic [1:0]        p1_kind;
  logic              p1_swap;
  logic [3:0]        p1_sh;
  logic              p1_half;
  logic [2:0]        p1_off;
  logic [2:0]        p1_idx;
  logic              p1_first, p1_last;
  logic              p1_pl;
  logic [3:0]        p1_row;
  logic [127:0]      w_l, w_r;
  logic [127:0]      lum_row;
  logic [71:0]       ch_row;
  logic [63:0]       ch_l, ch_r;
  always_comb begin
    w_l = p1_swap ? rd_data1 : rd_data0;
    w_r = p1_swap ? rd_data0 : rd_data1;
    lum_row = 128'(({w_r, w_l} >> (8 * p1_sh)));
    ch_l = p1_half ? w_l[127:64] : w_l[63:0];
    ch_r = p1_half ? w_r[127:64] : w_r[63:0];
    ch_row = 72'(({ch_r, ch_l} >> (8 * p1_off)));
  end

  // Stage I2: aligned row data.
  logic              p2_v;
  logic [1:0]        p2_kind;
  logic [2:0]        p2_idx;
  logic              p2_first, p2_last;
  logic              p2_pl;
  logic [3:0]        p2_row;
  logic [127:0]      p2_lum;
  logic [127:0]      p2_src;
  logic [71:0]       p2_ch;

  // SAD unit.
  logic              sad_v;
  logic [2:0]        sad_idx;
  logic [18:0]       sad_val;
  rtlnet_h264_sad16 #(.TAG_W(3)) u_sad (
    .clk(clk), .resetn(resetn),
    .in_valid(p2_v && (p2_kind == K_SAD)), .in_first(p2_first), .in_last(p2_last), .in_tag(p2_idx), .in_a(p2_lum), .in_b(p2_src),
    .out_valid(sad_v), .out_tag(sad_idx), .out_sad(sad_val)
  );

  // Chroma interpolation.
  logic              ci_v;
  logic [63:0]       ci_row;
  logic [3:0]        ci_tag;
  logic [2:0]        xf_q, yf_q;
  rtlnet_h264_cinterp u_ci (
    .clk(clk), .resetn(resetn),
    .in_valid(p2_v && (p2_kind == K_CH)), .in_first(p2_first), .in_row(p2_ch), .in_tag({p2_pl, 3'(p2_row - 4'd1)}),
    .xf(xf_q), .yf(yf_q),
    .out_valid(ci_v), .out_row(ci_row), .out_tag(ci_tag)
  );

  // Prediction buffer writes: luma rows straight from I2, chroma word pairs from the interpolator.
  logic [63:0]       ci_even;
  logic              pl_we;
  assign pl_we     = p2_v && (p2_kind == K_LUMA);
  assign pred_we   = pl_we || (ci_v && ci_tag[0]);
  assign pred_addr = pl_we ? (pred_base_q + REF_AW'(p2_row)) : (pred_base_q + REF_AW'(5'd16) + REF_AW'({ci_tag[3], 2'b00}) + REF_AW'(ci_tag[2:1]));
  assign pred_data = pl_we ? p2_lum : {ci_row, ci_even};

  // ---------------------------------------------------------------------------
  // Rate pipeline and result compare
  // ---------------------------------------------------------------------------
  logic              r1_v;
  logic [2:0]        r1_idx;
  logic signed [15:0] r1_dx, r1_dy;
  logic              r1_nz;
  logic              r2_v;
  logic [2:0]        r2_idx;
  logic [6:0]        r2_len;
  logic              r2_nz;
  logic              c1_v;
  logic [2:0]        c1_idx;
  logic [16:0]       c1_cost;
  logic              dc_cmp;            // best / centre differ (moved)

  assign dbg_ev_v   = sad_v;
  assign dbg_ev_vx  = lx[sad_idx];
  assign dbg_ev_vy  = ly[sad_idx];
  assign dbg_ev_sad = sad_val;
  assign dbg_best_cost = best_cost;

  // ---------------------------------------------------------------------------
  // Sequencing
  // ---------------------------------------------------------------------------
  assign mb_idle = (st == M_IDLE) && !mb_done;   // not in the clock where mb_done shows: the engine switches the prediction bank then
  assign idle    = (st == M_IDLE) && !win_busy && !(active && (ld_g < tot_cols)) && !mb_start;
  assign dc_cmp  = (8'(bx) != cx) || (8'(by) != cy);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      st             <= M_IDLE;
      pc             <= '0;
      prabs          <= '0;
      pri            <= '0;
      prowbase       <= '0;
      src_base_q     <= '0;
      pred_base_q    <= '0;
      s0             <= '0;
      vlo_x          <= '0;
      vhi_x          <= '0;
      vlo_y          <= '0;
      vhi_y          <= '0;
      av_top_q       <= 1'b0;
      av_left_q      <= 1'b0;
      av_tr_q        <= 1'b0;
      pc_q           <= '0;
      lam_q          <= 8'd1;
      ln             <= '0;
      best_cost      <= '1;
      bx             <= '0;
      by             <= '0;
      cx             <= '0;
      cy             <= '0;
      gm_x           <= '0;
      gm_y           <= '0;
      stage          <= '0;
      iter           <= '0;
      ev_cnt         <= '0;
      ph_cand        <= 1'b0;
      pi             <= '0;
      ctx_start      <= 1'b0;
      ctx_ready_seen <= 1'b0;
      drain          <= '0;
      res_rem        <= '0;
      mb_done        <= 1'b0;
      mb_vx          <= '0;
      mb_vy          <= '0;
      ctx_upd        <= 1'b0;
      ctx_upd_x      <= '0;
      ctx_upd_y      <= '0;
      xf_q           <= '0;
      yf_q           <= '0;
      iq_run         <= 1'b0;
      iq_kind        <= K_SAD;
      iq_idx         <= '0;
      iq_row         <= '0;
      iq_pl          <= 1'b0;
      i0_v           <= 1'b0;
      i0_kind        <= K_SAD;
      i0_vx          <= '0;
      i0_vy          <= '0;
      i0_row         <= '0;
      i0_idx         <= '0;
      i0_pl          <= 1'b0;
      i0_first       <= 1'b0;
      i0_last        <= 1'b0;
      cp_run         <= 1'b0;
      cp_n           <= '0;
      cp_v1          <= 1'b0;
      cp_a1          <= '0;
      cp_done        <= 1'b0;
      p1_v           <= 1'b0;
      p1_kind        <= K_SAD;
      p1_swap        <= 1'b0;
      p1_sh          <= '0;
      p1_half        <= 1'b0;
      p1_off         <= '0;
      p1_idx         <= '0;
      p1_first       <= 1'b0;
      p1_last        <= 1'b0;
      p1_pl          <= 1'b0;
      p1_row         <= '0;
      p2_v           <= 1'b0;
      p2_kind        <= K_SAD;
      p2_idx         <= '0;
      p2_first       <= 1'b0;
      p2_last        <= 1'b0;
      p2_pl          <= 1'b0;
      p2_row         <= '0;
      p2_lum         <= '0;
      p2_src         <= '0;
      p2_ch          <= '0;
      ci_even        <= '0;
      r1_v           <= 1'b0;
      r1_idx         <= '0;
      r1_dx          <= '0;
      r1_dy          <= '0;
      r2_v           <= 1'b0;
      r2_idx         <= '0;
      r2_len         <= '0;
      r2_nz          <= 1'b0;
      r1_nz          <= 1'b0;
      c1_v           <= 1'b0;
      c1_idx         <= '0;
      c1_cost        <= '0;
      for (int i = 0; i < 8; i++) begin
        lx[i]     <= '0;
        ly[i]     <= '0;
        rate_r[i] <= '0;
      end
    end else begin
      mb_done   <= 1'b0;
      ctx_start <= 1'b0;
      ctx_upd   <= 1'b0;

      if (pic_start) begin
        pc       <= '0;
        pri      <= '0;
        prabs    <= band_first_row;
        prowbase <= '0;
      end

      if (ctx_ready) ctx_ready_seen <= 1'b1;

      // ----- source copy: a read in each clock the port is granted, written to the buffer the clock after -----
      cp_v1 <= 1'b0;
      if (cp_run && src_rd_req && src_rd_gnt) begin
        cp_v1 <= 1'b1;
        cp_a1 <= cp_n[2:0];
        cp_n  <= cp_n + 5'd1;
        if (cp_n == 5'd7) cp_run <= 1'b0;
      end
      if (cp_v1 && (cp_a1 == 3'd7)) cp_done <= 1'b1;

      // ----- issue sequencer -> stage I0 -----
      i0_v <= iq_run;
      if (iq_run) begin
        i0_kind  <= iq_kind;
        i0_row   <= iq_row;
        i0_idx   <= iq_idx;
        i0_pl    <= iq_pl;
        i0_first <= (iq_row == 4'd0);
        if (iq_kind == K_SAD) begin
          i0_vx   <= lx[iq_idx];
          i0_vy   <= ly[iq_idx];
          i0_last <= (iq_row == 4'd7);
        end else begin
          i0_vx   <= bx;
          i0_vy   <= by;
          i0_last <= (iq_kind == K_LUMA) ? (iq_row == 4'd15) : (iq_row == 4'd8);
        end
        case (iq_kind)
          K_SAD: begin
            if (iq_row == 4'd7) begin
              iq_row <= '0;
              if ((4'(iq_idx) + 4'd1) < ln) iq_idx <= iq_idx + 3'd1;
              else                      iq_run <= 1'b0;
            end else begin
              iq_row <= iq_row + 4'd1;
            end
          end
          K_LUMA: begin
            if (iq_row == 4'd15) iq_run <= 1'b0;
            iq_row <= iq_row + 4'd1;
          end
          default: begin
            if (iq_row == 4'd8) begin
              iq_row <= '0;
              iq_pl  <= 1'b1;
              if (iq_pl) iq_run <= 1'b0;
            end else begin
              iq_row <= iq_row + 4'd1;
            end
          end
        endcase
      end

      // ----- stage I1 (aligned with the RAM data) -----
      p1_v     <= i0_v;
      p1_kind  <= i0_kind;
      p1_swap  <= slot_l[0];
      p1_sh    <= sh_l;
      p1_half  <= ry_c[0];
      p1_off   <= off_c;
      p1_idx   <= i0_idx;
      p1_first <= i0_first;
      p1_last  <= i0_last;
      p1_pl    <= i0_pl;
      p1_row   <= i0_row;
      // ----- stage I2 -----
      p2_v     <= p1_v;
      p2_kind  <= p1_kind;
      p2_idx   <= p1_idx;
      p2_first <= p1_first;
      p2_last  <= p1_last;
      p2_pl    <= p1_pl;
      p2_row   <= p1_row;
      p2_lum   <= lum_row;
      p2_src   <= sb_data;
      p2_ch    <= ch_row;
      if (ci_v && !ci_tag[0]) ci_even <= ci_row;

      // ----- rate pipeline: mvd, code lengths, lambda x bits, three clocks behind the first row of a candidate -----
      r1_v   <= i0_v && (i0_kind == K_SAD) && i0_first;
      r1_idx <= i0_idx;
      r1_dx  <= 16'sd4 * 16'(i0_vx) - 16'(mvp_x);
      r1_dy  <= 16'sd4 * 16'(i0_vy) - 16'(mvp_y);
      r1_nz  <= (i0_vx != 6'sd0) || (i0_vy != 6'sd0);
      r2_v   <= r1_v;
      r2_idx <= r1_idx;
      r2_len <= 7'(h264_se_len(r1_dx)) + 7'(h264_se_len(r1_dy)) + (r1_nz ? 7'd8 : 7'd0);
      r2_nz  <= r1_nz;
      if (r2_v) rate_r[r2_idx] <= 17'(lam_q) * 17'(r2_len) + (r2_nz ? 17'(ZERO_BIAS) : 17'd0);

      // ----- result compare: cost = 2 x SAD + rate, strictly lower wins (earlier candidates win ties) -----
      c1_v    <= sad_v;
      c1_idx  <= sad_idx;
      c1_cost <= 17'({sad_val[14:0], 1'b0}) + rate_r[sad_idx];
      if (c1_v) begin
        res_rem <= res_rem - 7'd1;
        if (c1_cost < best_cost) begin
          best_cost <= c1_cost;
          bx        <= lx[c1_idx];
          by        <= ly[c1_idx];
        end
      end

      // ----- macroblock sequencer -----
      case (st)
        M_IDLE: begin
          if (mb_start) begin
            src_base_q  <= mb_src_base;
            pred_base_q <= mb_pred_base;
            st          <= M_WAIT;
          end
        end

        // The columns of the macroblock's window must be loaded.
        M_WAIT: begin
          if (ld_g > lim_g) st <= M_PREP;
        end

        M_PREP: begin
          pc_q           <= pc;
          av_top_q       <= (pri != 8'd0);
          av_left_q      <= (pc != 7'd0);
          av_tr_q        <= (pri != 8'd0) && ((8'(pc) + 8'd1) < w_q);
          s0             <= prowbase[1:0] + pc[1:0] - 2'd1;
          vlo_x          <= (pc == 7'd0) ? 8'sd0 : -8'sd1 * 8'(SR);
          vhi_x          <= ((8'(pc) + 8'd1) == w_q) ? 8'sd0 : 8'(SR);
          vlo_y          <= (prabs == 8'd0) ? 8'sd0 : -8'sd1 * 8'(SR);
          vhi_y          <= ((prabs + 8'd1) == h_q) ? 8'sd0 : 8'(SR);
          lam_q          <= h264_lambda(qp);
          ctx_start      <= 1'b1;
          ctx_ready_seen <= 1'b0;
          cp_run         <= 1'b1;
          cp_n           <= '0;
          cp_done        <= 1'b0;
          ln             <= '0;
          best_cost      <= '1;
          ev_cnt         <= '0;
          pi             <= '0;
          ph_cand        <= 1'b1;
          stage          <= '0;
          iter           <= '0;
          st             <= M_COPY;
        end

        M_COPY: begin
          if (cp_done && ctx_ready_seen) begin
            pi <= '0;
            st <= M_CAND;
          end
        end

        M_CAND: begin
          if (prop_ok) begin
            lx[ln[2:0]] <= prop_x[5:0];
            ly[ln[2:0]] <= prop_y[5:0];
            ln          <= ln + 4'd1;
          end
          if (pi == 3'd5) st <= M_EVST;
          pi <= pi + 3'd1;
        end

        M_EVST: begin
          if (ln == 4'd0) begin
            st <= ph_cand ? M_D : M_D2;
            if (ph_cand) begin
              cx      <= 8'(bx);
              cy      <= 8'(by);
              ph_cand <= 1'b0;
            end
          end else begin
            iq_run  <= 1'b1;
            iq_kind <= K_SAD;
            iq_idx  <= '0;
            iq_row  <= '0;
            res_rem <= 7'(ln);
            ev_cnt  <= ev_cnt + 7'(ln);
            st      <= M_EV;
          end
        end

        M_EV: begin
          if (!iq_run && !i0_v && (res_rem == 7'd0) && !c1_v && !sad_v && !p2_v && !p1_v) begin
            if (ph_cand) begin
              cx      <= 8'(bx);
              cy      <= 8'(by);
              ph_cand <= 1'b0;
              st      <= M_D;
            end else begin
              st <= M_D2;
            end
          end
        end

        // Step stage decision.
        M_D: begin
          if (stage == 3'd5) begin
            st <= M_PY;
          end else if ((iter == 2'd0) && (stage < 3'd4) && (best_cost <= 17'(GOOD_COST))) begin
            stage <= 3'd4;
            iter  <= '0;
          end else if (ev_cnt >= 7'(MAX_EVAL)) begin
            st <= M_PY;
          end else begin
            ln <= '0;
            pi <= '0;
            st <= M_PROP;
          end
        end

        M_PROP: begin
          if (prop_ok) begin
            lx[ln[2:0]] <= prop_x[5:0];
            ly[ln[2:0]] <= prop_y[5:0];
            ln          <= ln + 4'd1;
          end
          if (pi == (sq_pat ? 3'd7 : 3'd3)) st <= M_EVST;
          pi <= pi + 3'd1;
        end

        M_D2: begin
          if (dc_cmp) begin
            cx <= 8'(bx);
            cy <= 8'(by);
            if ((iter + 2'd1) < maxit) begin
              iter <= iter + 2'd1;
            end else begin
              stage <= stage + 3'd1;
              iter  <= '0;
            end
          end else begin
            stage <= stage + 3'd1;
            iter  <= '0;
          end
          st <= M_D;
        end

        // Prediction: luma rows, then the two chroma planes.
        M_PY: begin
          iq_run  <= 1'b1;
          iq_kind <= K_LUMA;
          iq_row  <= '0;
          xf_q    <= {bx[0], 2'b00};
          yf_q    <= {by[0], 2'b00};
          st      <= M_PYW;
        end
        M_PYW: begin
          if (!iq_run) begin
            iq_run  <= 1'b1;
            iq_kind <= K_CH;
            iq_row  <= '0;
            iq_pl   <= 1'b0;
            st      <= M_PC;
          end
        end
        M_PC: begin
          st    <= M_PCW;
          drain <= '0;
        end
        M_PCW: begin
          if (!iq_run) begin
            drain <= drain + 4'd1;
            if (drain == 4'd11) st <= M_FIN;
          end
        end

        M_FIN: begin
          mb_vx     <= bx;
          mb_vy     <= by;
          gm_x      <= bx;
          gm_y      <= by;
          ctx_upd   <= 1'b1;
          ctx_upd_x <= 14'(bx) * 14'sd4;
          ctx_upd_y <= 14'(by) * 14'sd4;
          mb_done   <= 1'b1;
          if ((8'(pc) + 8'd1) == w_q) begin
            pc       <= '0;
            pri      <= pri + 8'd1;
            prabs    <= prabs + 8'd1;
            prowbase <= prowbase + 16'(w_q);
          end else begin
            pc <= pc + 7'd1;
          end
          st <= M_IDLE;
        end

        default: st <= M_IDLE;
      endcase
    end
  end

endmodule
