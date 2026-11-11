// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_search.sv
// Purpose: self-checking bench of rtlnet_h264_search, the motion search stage of phase 2c-2: window loader, candidate order, SAD values,
//   edge clamping of the vectors, the sliding window contents, the search result and the prediction (luma at the integer vector,
//   chroma by the clause 8.4.2.2.2 filter), against a software model written here from the algorithm of documentation section 16.
// Overview:
//   * A reference picture (smooth content with grain) is placed as macroblock tiles (luma 256 B, chroma 128 B per macroblock, the
//     rebuilt-picture layout of documentation section 7) in a memory model behind a read-burst port with latency and random gaps. The
//     current picture is the reference moved by (TB_TX, TB_TY) plus noise, so the search has a true vector; for a random picture
//     (TB_TX = 99) there is none. The source rows of the macroblock are served through the arbitrated read port with random grants.
//   * The band TB_FIRST .. TB_FIRST + TB_ROWS - 1 of a TB_W x TB_H picture is searched macroblock by macroblock in raster order. For
//     every macroblock the bench checks:
//       - the stream of candidate results (vector, SAD) in order against the model (candidate order, deduplication, edge legality,
//         SAD of the 8 even rows), and that every evaluated vector keeps the block inside the picture and inside +-SR;
//       - the final vector against the model;
//       - the prediction buffer (24 words: luma rows, Cb and Cr words of row pairs) against the model prediction at that vector;
//       - the window RAM contents of the columns c - 1 .. c + 1 (rows that exist) against the reference tiles: the slides across a row
//         and the loads at the start of a row.
//   * Read bursts: every burst is 16 (luma tile) or 8 (chroma tile) beats, tile aligned; the totals equal the expected loads (every
//     existing tile of the three rows of every column of the band is read once per column, i.e. three times per picture).
//   * +INJECT_FAILURE is the negative control (forces one failed check).
// Defines: TB_W, TB_H, TB_FIRST, TB_ROWS, TB_TX, TB_TY (whole samples, 99 for a random current picture), TB_QP, TB_SR, TB_LAT, TB_SEED.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-2).
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_W
  `define TB_W 6
`endif
`ifndef TB_H
  `define TB_H 5
`endif
`ifndef TB_FIRST
  `define TB_FIRST 0
`endif
`ifndef TB_ROWS
  `define TB_ROWS 5
`endif
`ifndef TB_TX
  `define TB_TX 5
`endif
`ifndef TB_TY
  `define TB_TY -3
`endif
`ifndef TB_QP
  `define TB_QP 28
`endif
`ifndef TB_SR
  `define TB_SR 16
`endif
`ifndef TB_LAT
  `define TB_LAT 12
`endif
`ifndef TB_SEED
  `define TB_SEED 1
`endif

module tb_rtlnet_h264_search;

  import rtlnet_tb_pkg::*;

  localparam int W      = `TB_W;
  localparam int H      = `TB_H;
  localparam int FIRST  = `TB_FIRST;
  localparam int ROWS   = `TB_ROWS;
  localparam int TX     = `TB_TX;
  localparam int TY     = `TB_TY;
  localparam int QP     = `TB_QP;
  localparam int SR     = `TB_SR;
  localparam int LAT    = `TB_LAT;
  localparam int MAXEV  = 48;
  localparam int GOOD   = 384;
  localparam int ZBIAS  = 128;
  localparam int PW     = W * 16;
  localparam int PH     = H * 16;
  localparam int CW     = W * 8;
  localparam int CH     = H * 8;
  localparam int YBASE  = 0;
  localparam int UBASE  = W * H * 256;                 // multiple of 128
  localparam int MEM_W  = (W * H * 384) / 16 + 64;

  logic          clk = 1'b0;
  logic          resetn = 1'b0;
  always #5 clk = ~clk;

  // DUT signals.
  logic          pic_start = 1'b0;
  logic          win_req, win_go, win_busy;
  logic [31:0]   win_araddr;
  logic [7:0]    win_arlen;
  logic          win_arvalid, win_arready;
  logic [127:0]  win_rdata;
  logic [1:0]    win_rresp;
  logic          win_rvalid, win_rready;
  logic          err_resp;
  logic          mb_start = 1'b0;
  logic [6:0]    mb_src_base = '0;
  logic [5:0]    mb_pred_base = '0;
  logic          mb_idle, mb_done;
  logic signed [5:0] mb_vx, mb_vy;
  logic          src_rd_req, src_rd_gnt;
  logic [6:0]    src_rd_addr;
  logic [127:0]  src_rd_data;
  logic          pred_we;
  logic [5:0]    pred_addr;
  logic [127:0]  pred_data;
  logic          idle;
  logic          dbg_ev_v;
  logic signed [5:0] dbg_ev_vx, dbg_ev_vy;
  logic [18:0]   dbg_ev_sad;
  logic [16:0]   dbg_best_cost;

  rtlnet_h264_search #(
    .ADDR_W(32), .MAX_MB_W(120), .SR(SR), .WIN_KB(4), .MV_LINE_KB(1), .SRC_AW(7), .REF_AW(6), .MAX_EVAL(MAXEV), .GOOD_COST(GOOD), .ZERO_BIAS(ZBIAS),
    .RAM_STYLE("block"), .SRCBUF_STYLE("distributed")
  ) dut (
    .clk(clk), .resetn(resetn),
    .pic_start(pic_start), .cfg_mb_w(8'(W)), .cfg_mb_h(8'(H)), .band_first_row(8'(FIRST)), .band_rows(8'(ROWS)),
    .ref_y_base(32'(YBASE)), .ref_u_base(32'(UBASE)), .qp(6'(QP)),
    .win_req(win_req), .win_go(win_go), .win_busy(win_busy), .win_araddr(win_araddr), .win_arlen(win_arlen), .win_arvalid(win_arvalid),
    .win_arready(win_arready), .win_rdata(win_rdata), .win_rresp(win_rresp), .win_rvalid(win_rvalid), .win_rready(win_rready),
    .err_resp(err_resp),
    .mb_start(mb_start), .mb_src_base(mb_src_base), .mb_pred_base(mb_pred_base), .mb_idle(mb_idle), .mb_done(mb_done), .mb_vx(mb_vx), .mb_vy(mb_vy),
    .src_rd_req(src_rd_req), .src_rd_addr(src_rd_addr), .src_rd_gnt(src_rd_gnt), .src_rd_data(src_rd_data),
    .pred_we(pred_we), .pred_addr(pred_addr), .pred_data(pred_data),
    .idle(idle),
    .dbg_ev_v(dbg_ev_v), .dbg_ev_vx(dbg_ev_vx), .dbg_ev_vy(dbg_ev_vy), .dbg_ev_sad(dbg_ev_sad), .dbg_best_cost(dbg_best_cost)
  );

  // ---------------------------------------------------------------------------
  // Pictures: planes of the reference and the current picture; the memory image of the reference tiles
  // ---------------------------------------------------------------------------
  byte unsigned ref_y [PH][PW];
  byte unsigned ref_u [CH][CW];
  byte unsigned ref_v [CH][CW];
  byte unsigned cur_y [PH][PW];
  logic [127:0] mem [MEM_W];

  function automatic int clampi(input int v, input int lo, input int hi);
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
  endfunction

  task automatic build_pictures();
    real ph1, ph2, ph3;
    ph1 = 0.3 * `TB_SEED;
    ph2 = 1.1 * `TB_SEED;
    ph3 = 2.3 * `TB_SEED;
    for (int y = 0; y < PH; y++) begin
      for (int x = 0; x < PW; x++) begin
        real v;
        int  rn;
        v = 128.0 + 50.0 * $sin(x / 7.0 + ph1) * $cos(y / 9.0 + ph2) + 30.0 * $sin((x + 2 * y) / 13.0 + ph3) + 18.0 * $cos(x / 3.3 - y / 4.1);
        rn = $urandom_range(6, 0);
        ref_y[y][x] = 8'(clampi(int'(v) + rn - 3, 0, 255));
      end
    end
    for (int y = 0; y < CH; y++) begin
      for (int x = 0; x < CW; x++) begin
        real u, w;
        int  rn1, rn2;
        u = 128.0 + 40.0 * $sin(x / 5.0 + ph1) * $cos(y / 6.0) + 20.0 * $sin((x - y) / 8.0 + ph2);
        w = 128.0 + 40.0 * $cos(x / 4.0 - ph3) * $sin(y / 5.0 + ph1) + 20.0 * $cos((x + y) / 9.0);
        rn1 = $urandom_range(2, 0);
        rn2 = $urandom_range(2, 0);
        ref_u[y][x] = 8'(clampi(int'(u) + rn1 - 1, 0, 255));
        ref_v[y][x] = 8'(clampi(int'(w) + rn2 - 1, 0, 255));
      end
    end
    for (int y = 0; y < PH; y++) begin
      for (int x = 0; x < PW; x++) begin
        int rn3;
        rn3 = $urandom_range(4, 0);
        if (TX == 99) cur_y[y][x] = 8'($urandom_range(255, 0));
        else          cur_y[y][x] = 8'(clampi(int'(ref_y[clampi(y + TY, 0, PH - 1)][clampi(x + TX, 0, PW - 1)]) + rn3 - 2, 0, 255));
      end
    end
    // Memory image: luma tile of macroblock m at 256 m (16 rows of 16 bytes), chroma tile at UBASE + 128 m (Cb then Cr, 8 beats).
    for (int my = 0; my < H; my++) begin
      for (int mx = 0; mx < W; mx++) begin
        int m;
        m = my * W + mx;
        for (int y = 0; y < 16; y++) begin
          for (int i = 0; i < 16; i++) mem[(YBASE + 256 * m) / 16 + y][8*i +: 8] = ref_y[16 * my + y][16 * mx + i];
        end
        for (int k = 0; k < 4; k++) begin
          for (int i = 0; i < 8; i++) begin
            mem[(UBASE + 128 * m) / 16 + k][8*i +: 8]       = ref_u[8 * my + 2 * k][8 * mx + i];
            mem[(UBASE + 128 * m) / 16 + k][64 + 8*i +: 8]  = ref_u[8 * my + 2 * k + 1][8 * mx + i];
            mem[(UBASE + 128 * m) / 16 + 4 + k][8*i +: 8]       = ref_v[8 * my + 2 * k][8 * mx + i];
            mem[(UBASE + 128 * m) / 16 + 4 + k][64 + 8*i +: 8]  = ref_v[8 * my + 2 * k + 1][8 * mx + i];
          end
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Read-burst memory model (latency LAT, random gaps) and the burst checks
  // ---------------------------------------------------------------------------
  typedef struct { int unsigned addr; int len; int due; } burst_t;
  burst_t  bq [$];
  int      clk_n;
  int      cur_beat;
  int      n_ar, n_ar16, n_ar8;
  int      n_beats;
  logic    ar_ok;

  always @(negedge clk) win_arready <= (resetn && ($urandom_range(99, 0) < 70));
  always @(posedge clk) begin
    clk_n <= clk_n + 1;
    if (resetn && win_arvalid && win_arready) begin
      burst_t b;
      b.addr = win_araddr;
      b.len  = int'(win_arlen) + 1;
      b.due  = clk_n + LAT;
      bq.push_back(b);
      n_ar++;
      if (b.len == 16) n_ar16++;
      if (b.len == 8)  n_ar8++;
      tb_check((b.len == 16) || (b.len == 8), $sformatf("window burst of %0d beats", b.len));
      tb_check((b.len == 16) ? ((b.addr % 256) == 0) : ((b.addr % 128) == 0), $sformatf("window burst of %0d beats at unaligned address 0x%0h", b.len, b.addr));
      tb_check(((b.addr & 32'hFFF) + b.len * 16) <= 4096, "window burst crosses 4 KiB");
    end
  end

  // R channel driver (negedge): one beat per clock when due, with random gaps.
  always @(negedge clk) begin
    win_rvalid <= 1'b0;
    win_rdata  <= '0;
    if (resetn && (bq.size() > 0) && (clk_n >= bq[0].due) && win_rready && ($urandom_range(99, 0) < 85)) begin
      win_rvalid <= 1'b1;
      win_rdata  <= mem[(bq[0].addr / 16) + cur_beat];
      n_beats++;
      cur_beat++;
      if (cur_beat == bq[0].len) begin
        cur_beat = 0;
        void'(bq.pop_front());
      end
    end
  end
  assign win_rresp = 2'b00;

  // Grant of the window loader's channel: any time it asks and is not busy (the bench is the only reader), after a random delay.
  logic win_go_r = 1'b0;
  always @(negedge clk) win_go_r <= ($urandom_range(99, 0) < 60);
  assign win_go = win_req && !win_busy && win_go_r;

  // ---------------------------------------------------------------------------
  // Source rows served through the arbitrated read port
  // ---------------------------------------------------------------------------
  logic [127:0] srcmem [16];
  always @(negedge clk) src_rd_gnt <= ($urandom_range(99, 0) < 60);
  always @(posedge clk) begin
    if (src_rd_req && src_rd_gnt) src_rd_data <= srcmem[src_rd_addr[3:0]];
  end

  // Prediction buffer model.
  logic [127:0] predmem [64];
  always @(posedge clk) if (pred_we) predmem[pred_addr] <= pred_data;

  // ---------------------------------------------------------------------------
  // Model of the search (documentation 16.5)
  // ---------------------------------------------------------------------------
  int  mvx_m [H][W];            // model vectors of the band (pixels), by absolute row
  int  mvy_m [H][W];

  function automatic int se_bits(input int v);
    int code, n;
    code = (v > 0) ? (2 * v - 1) : (-2 * v);
    code = code + 1;
    n = 0;
    for (int i = 0; i < 20; i++) if ((code >> i) != 0) n = i;
    return 2 * n + 1;
  endfunction

  function automatic int lam_of(input int qp);
    real l;
    l = 0.92 * (2.0 ** ((qp - 12) / 6.0));
    return (int'($floor(l + 0.5)) < 1) ? 1 : int'($floor(l + 0.5));
  endfunction

  int  c_vx [$];                // candidate list of the current batch and the expected result stream
  int  c_vy [$];
  int  tr_vx [$];
  int  tr_vy [$];
  int  tr_sad [$];
  int  m_best_cost, m_bx, m_by, m_ev;
  int  m_mvp_x, m_mvp_y, m_lam;
  int  m_c, m_r;                // macroblock being modelled: column, absolute row
  int  gm_xm, gm_ym;            // vector of the macroblock searched last (raster order)

  function automatic int sad_even(input int c, input int r, input int vx, input int vy);
    int s;
    s = 0;
    for (int j = 0; j < 16; j += 2) begin
      for (int i = 0; i < 16; i++) begin
        int d;
        d = int'(cur_y[16 * r + j][16 * c + i]) - int'(ref_y[16 * r + j + vy][16 * c + i + vx]);
        s += (d < 0) ? -d : d;
      end
    end
    return s;
  endfunction

  function automatic bit legal(input int c, input int r, input int vx, input int vy);
    return (vx >= -SR) && (vx <= SR) && (vy >= -SR) && (vy <= SR) && ((16 * c + vx) >= 0) && ((16 * c + vx + 16) <= PW) &&
           ((16 * r + vy) >= 0) && ((16 * r + vy + 16) <= PH);
  endfunction

  function automatic int med3(input int a, input int b, input int c);
    int mn, mx;
    mn = (a < b) ? a : b;
    mx = (a < b) ? b : a;
    return (mn > ((mx < c) ? mx : c)) ? mn : ((mx < c) ? mx : c);
  endfunction

  // Evaluate the candidate list c_vx / c_vy (legal, in order): appends the expected results, updates the best.
  task automatic m_eval();
    for (int k = 0; k < c_vx.size(); k++) begin
      int s, cost;
      s = sad_even(m_c, m_r, c_vx[k], c_vy[k]);
      cost = 2 * s + m_lam * (se_bits(4 * c_vx[k] - m_mvp_x) + se_bits(4 * c_vy[k] - m_mvp_y) + (((c_vx[k] != 0) || (c_vy[k] != 0)) ? 8 : 0)) + (((c_vx[k] != 0) || (c_vy[k] != 0)) ? ZBIAS : 0);
      tr_vx.push_back(c_vx[k]);
      tr_vy.push_back(c_vy[k]);
      tr_sad.push_back(s);
      m_ev++;
      if (cost < m_best_cost) begin
        m_best_cost = cost;
        m_bx = c_vx[k];
        m_by = c_vy[k];
      end
    end
    c_vx.delete();
    c_vy.delete();
  endtask

  task automatic m_prop(input int vx, input int vy);
    bit dup;
    dup = 0;
    for (int k = 0; k < c_vx.size(); k++) if ((c_vx[k] == vx) && (c_vy[k] == vy)) dup = 1;
    if (!dup && legal(m_c, m_r, vx, vy)) begin
      c_vx.push_back(vx);
      c_vy.push_back(vy);
    end
  endtask

  task automatic model_search(input int c, input int r);
    bit has_a, has_b, has_c, has_d;
    int ax, ay, bx, by, cx, cy, dx, dy;
    int d_tab [5];
    int maxit [5];
    bit sq [5];
    int center_x, center_y;
    m_c = c;
    m_r = r;
    tr_vx.delete();
    tr_vy.delete();
    tr_sad.delete();
    c_vx.delete();
    c_vy.delete();
    m_ev = 0;
    m_best_cost = 32'h7FFFFFFF;
    m_lam = lam_of(QP);
    has_a = (c > 0);
    has_b = (r > FIRST);
    has_c = has_b && ((c + 1) < W);
    has_d = has_b && (c > 0);
    ax = has_a ? mvx_m[r][c-1] : 0;       ay = has_a ? mvy_m[r][c-1] : 0;
    bx = has_b ? mvx_m[r-1][c] : 0;       by = has_b ? mvy_m[r-1][c] : 0;
    cx = has_c ? mvx_m[r-1][c+1] : 0;     cy = has_c ? mvy_m[r-1][c+1] : 0;
    dx = has_d ? mvx_m[r-1][c-1] : 0;     dy = has_d ? mvy_m[r-1][c-1] : 0;
    // The approximate predictor (the median predictor of clause 8.4.1.3 over the neighbours that exist; all are inter).
    begin
      bit has_cc;
      int ccx, ccy;
      has_cc = has_c || has_d;
      ccx = has_c ? cx : dx;
      ccy = has_c ? cy : dy;
      if (!has_a && !has_b && !has_cc) begin
        m_mvp_x = 0; m_mvp_y = 0;
      end else if (!has_b && !has_cc) begin
        m_mvp_x = 4 * ax; m_mvp_y = 4 * ay;
      end else if (((has_a ? 1 : 0) + (has_b ? 1 : 0) + (has_cc ? 1 : 0)) == 1) begin
        m_mvp_x = 4 * (has_a ? ax : (has_b ? bx : ccx));
        m_mvp_y = 4 * (has_a ? ay : (has_b ? by : ccy));
      end else begin
        m_mvp_x = 4 * med3(has_a ? ax : 0, has_b ? bx : 0, has_cc ? ccx : 0);
        m_mvp_y = 4 * med3(has_a ? ay : 0, has_b ? by : 0, has_cc ? ccy : 0);
      end
      // Candidates: (0,0), the predictor, A, B, C else D.
      m_prop(0, 0);
      m_prop(m_mvp_x / 4, m_mvp_y / 4);
      if (has_a) m_prop(ax, ay);
      if (has_b) m_prop(bx, by);
      if (has_cc) m_prop(ccx, ccy);
      m_prop(gm_xm, gm_ym);
    end
    m_eval();
    center_x = m_bx;
    center_y = m_by;
    d_tab[0] = 16; d_tab[1] = 8; d_tab[2] = 4; d_tab[3] = 2; d_tab[4] = 1;
    maxit[0] = 3;  maxit[1] = 3; maxit[2] = 2; maxit[3] = 2; maxit[4] = 3;
    sq[0] = 1; sq[1] = 1; sq[2] = 1; sq[3] = 0; sq[4] = 0;
    for (int st = 0; st < 5; st++) begin
      int d;
      d = d_tab[st];
      if ((st < 4) && (m_best_cost <= GOOD)) continue;
      for (int it = 0; it < maxit[st]; it++) begin
        if (m_ev >= MAXEV) break;
        m_prop(center_x + d, center_y);
        m_prop(center_x - d, center_y);
        m_prop(center_x, center_y + d);
        m_prop(center_x, center_y - d);
        if (sq[st]) begin
          m_prop(center_x + d, center_y + d);
          m_prop(center_x - d, center_y + d);
          m_prop(center_x + d, center_y - d);
          m_prop(center_x - d, center_y - d);
        end
        m_eval();
        if ((m_bx != center_x) || (m_by != center_y)) begin
          center_x = m_bx;
          center_y = m_by;
        end else begin
          break;
        end
      end
    end
    mvx_m[r][c] = m_bx;
    mvy_m[r][c] = m_by;
    gm_xm = m_bx;
    gm_ym = m_by;
  endtask

  // ---------------------------------------------------------------------------
  // Prediction model (luma at the integer vector, chroma by equation 8-228)
  // ---------------------------------------------------------------------------
  function automatic int cref(input int pl, input int y, input int x);
    return (pl == 0) ? int'(ref_u[y][x]) : int'(ref_v[y][x]);
  endfunction

  function automatic logic [127:0] model_pred_word(input int c, input int r, input int vx, input int vy, input int w);
    logic [127:0] o;
    o = '0;
    if (w < 16) begin
      for (int i = 0; i < 16; i++) o[8*i +: 8] = ref_y[16 * r + w + vy][16 * c + i + vx];
    end else begin
      int pl, k, xi, yi, xf, yf;
      pl = (w - 16) / 4;
      k  = (w - 16) % 4;
      // Chroma vector in eighth samples: 4 x the luma vector; integer part >> 3, fraction & 7.
      xi = (4 * vx) >>> 3;
      yi = (4 * vy) >>> 3;
      xf = (4 * vx) & 7;
      yf = (4 * vy) & 7;
      for (int h = 0; h < 2; h++) begin
        for (int i = 0; i < 8; i++) begin
          int yy, xx, a, b, cc, d;
          yy = 8 * r + 2 * k + h + yi;
          xx = 8 * c + i + xi;
          a  = cref(pl, yy, xx);
          b  = (xf != 0) ? cref(pl, yy, xx + 1) : 0;
          cc = (yf != 0) ? cref(pl, yy + 1, xx) : 0;
          d  = ((xf != 0) && (yf != 0)) ? cref(pl, yy + 1, xx + 1) : 0;
          o[64 * h + 8 * i +: 8] = 8'((((8 - xf) * (8 - yf) * a) + (xf * (8 - yf) * b) + ((8 - xf) * yf * cc) + (xf * yf * d) + 32) >> 6);
        end
      end
    end
    return o;
  endfunction

  // ---------------------------------------------------------------------------
  // Window contents check: columns c - 1 .. c + 1, rows r - 1 .. r + 1 that exist, against the reference tiles
  // ---------------------------------------------------------------------------
  int win_checks;
  function automatic logic [127:0] win_word(input int slot, input int addr);
    return (slot % 2 == 0) ? dut.u_win0.g_inferred.g_generic.mem[addr] : dut.u_win1.g_inferred.g_generic.mem[addr];
  endfunction

  task automatic check_window(input int c, input int r, input int rowbase);
    for (int k = 0; k < 3; k++) begin
      int col, slot;
      col = c - 1 + k;
      if ((col >= 0) && (col < W)) begin
        slot = (rowbase + col) % 4;
        for (int wr = 0; wr < 3; wr++) begin
          int rr;
          rr = r - 1 + wr;
          if ((rr >= 0) && (rr < H)) begin
            int m;
            m = rr * W + col;
            for (int y = 0; y < 16; y++) begin
              win_checks++;
              tb_check(win_word(slot, (slot / 2) * 64 + wr * 16 + y) == mem[(YBASE + 256 * m) / 16 + y],
                       $sformatf("window luma mb (%0d,%0d) col %0d row %0d y %0d", c, r, col, rr, y));
            end
            for (int b = 0; b < 8; b++) begin
              win_checks++;
              tb_check(win_word(slot, 128 + (slot / 2) * 64 + wr * 8 + b) == mem[(UBASE + 128 * m) / 16 + b],
                       $sformatf("window chroma mb (%0d,%0d) col %0d row %0d beat %0d", c, r, col, rr, b));
            end
          end
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Collector of the candidate stream
  // ---------------------------------------------------------------------------
  int  ev_idx;
  int  ev_checks;
  int  n_evals_total;
  int  max_evals;
  always @(posedge clk) begin
    if (resetn && dbg_ev_v) begin
      int vx, vy;
      vx = int'(dbg_ev_vx);
      vy = int'(dbg_ev_vy);
      if (ev_idx < tr_vx.size()) begin
        tb_check(vx == tr_vx[ev_idx] && vy == tr_vy[ev_idx], $sformatf("mb (%0d,%0d) candidate %0d: vector (%0d,%0d) expected (%0d,%0d)", m_c, m_r, ev_idx, vx, vy,
                                                                    tr_vx[ev_idx], tr_vy[ev_idx]));
        tb_check(int'(dbg_ev_sad) == tr_sad[ev_idx], $sformatf("mb (%0d,%0d) candidate %0d (%0d,%0d): SAD %0d expected %0d", m_c, m_r, ev_idx, vx, vy, dbg_ev_sad,
                                                             tr_sad[ev_idx]));
        ev_checks++;
      end else begin
        tb_error($sformatf("mb (%0d,%0d): unexpected extra candidate result %0d", m_c, m_r, ev_idx));
      end
      tb_check(legal(m_c, m_r, vx, vy), $sformatf("mb (%0d,%0d): evaluated vector (%0d,%0d) is outside the picture or the range", m_c, m_r, vx, vy));
      ev_idx++;
    end
  end

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  int rowbase;
  int mbs;
  int exp_bursts;
  int t_wait;

  initial begin
    clk_n = 0;
    cur_beat = 0;
    n_ar = 0; n_ar16 = 0; n_ar8 = 0; n_beats = 0;
    win_checks = 0;
    ev_checks = 0;
    n_evals_total = 0;
    max_evals = 0;
    ev_idx = 0;
    mbs = 0;
    gm_xm = 0;
    gm_ym = 0;
    for (int i = 0; i < MEM_W; i++) mem[i] = '0;
    build_pictures();
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin mvx_m[y][x] = 0; mvy_m[y][x] = 0; end
    repeat (4) @(negedge clk);
    resetn = 1'b1;
    repeat (4) @(negedge clk);
    @(negedge clk);
    pic_start = 1'b1;
    @(negedge clk);
    pic_start = 1'b0;
    rowbase = 0;
    for (int r = FIRST; r < FIRST + ROWS; r++) begin
      for (int c = 0; c < W; c++) begin
        // Source rows of the macroblock.
        for (int j = 0; j < 16; j++) for (int i = 0; i < 16; i++) srcmem[j][8*i +: 8] = cur_y[16 * r + j][16 * c + i];
        model_search(c, r);
        t_wait = 0;
        while (!mb_idle && t_wait < 100000) begin @(negedge clk); t_wait++; end
        ev_idx = 0;
        mb_src_base  = 7'd0;
        mb_pred_base = ((mbs % 2) == 0) ? 6'd0 : 6'd32;
        mb_start = 1'b1;
        @(negedge clk);
        mb_start = 1'b0;
        t_wait = 0;
        while (!mb_done && t_wait < 100000) begin @(negedge clk); t_wait++; end
        tb_check(mb_done, $sformatf("mb (%0d,%0d): no done", c, r));
        @(negedge clk);
        tb_check(ev_idx == tr_vx.size(), $sformatf("mb (%0d,%0d): %0d candidate results, expected %0d", c, r, ev_idx, tr_vx.size()));
        tb_check(int'(mb_vx) == mvx_m[r][c] && int'(mb_vy) == mvy_m[r][c],
                 $sformatf("mb (%0d,%0d): vector (%0d,%0d) expected (%0d,%0d)", c, r, mb_vx, mb_vy, mvx_m[r][c], mvy_m[r][c]));
        tb_check(int'(dbg_best_cost) == m_best_cost, $sformatf("mb (%0d,%0d): best cost %0d expected %0d", c, r, dbg_best_cost, m_best_cost));
        n_evals_total += ev_idx;
        if (ev_idx > max_evals) max_evals = ev_idx;
        // Prediction at the DUT's vector.
        for (int w = 0; w < 24; w++) begin
          logic [127:0] e;
          e = model_pred_word(c, r, int'(mb_vx), int'(mb_vy), w);
          tb_check(predmem[((mbs % 2) == 0 ? 0 : 32) + w] == e,
                   $sformatf("mb (%0d,%0d) vector (%0d,%0d): prediction word %0d got %032x expected %032x", c, r, mb_vx, mb_vy, w,
                             predmem[((mbs % 2) == 0 ? 0 : 32) + w], e));
        end
        check_window(c, r, rowbase);
        mbs++;
      end
      rowbase += W;
    end
    repeat (200) @(negedge clk);
    tb_check(idle, "the stage is idle at the end of the band");
    // Burst totals: every column of the band loads the tiles of the rows r - 1, r, r + 1 that exist.
    exp_bursts = 0;
    for (int r = FIRST; r < FIRST + ROWS; r++) begin
      for (int c = 0; c < W; c++) exp_bursts += 2 * (1 + ((r > 0) ? 1 : 0) + (((r + 1) < H) ? 1 : 0));
    end
    tb_check(n_ar == exp_bursts, $sformatf("%0d window bursts, expected %0d", n_ar, exp_bursts));
    tb_check(n_ar16 == n_ar8, $sformatf("%0d luma and %0d chroma window bursts", n_ar16, n_ar8));
    $display("STAT search: %0d macroblocks, %0d candidates evaluated (mean %0d.%0d, max %0d), %0d window bursts (%0d x 16 beats, %0d x 8 beats), %0d window words checked, %0d candidate results checked",
             mbs, n_evals_total, n_evals_total / mbs, (n_evals_total * 10 / mbs) % 10, max_evals, n_ar, n_ar16, n_ar8, win_checks, ev_checks);
    tb_verdict("tb_rtlnet_h264_search");
  end

  // Watchdog.
  initial begin
    #200_000_000;
    tb_error("watchdog");
    tb_verdict("tb_rtlnet_h264_search");
  end

endmodule
