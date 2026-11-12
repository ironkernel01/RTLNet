// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_ipred.sv
// Purpose: self-checking bench of rtlnet_h264_ipred: Intra16x16 luma and chroma prediction (ITU-T Rec. H.264
//   clauses 8.3.3 and 8.3.4), the SAD accumulators and the mode decision.
// Overview:
//   * The reference is written here per pixel from the clause text: luma V, H, DC, Plane; chroma DC (4x4 block
//     position rules), H, V, Plane (xCF = yCF = 0); sums use p[-1,-1] where the clauses do.
//   * Each case loads random or corner-case neighbours with one of the four availability combinations, waits for
//     prep_done (at most 24 clocks), then issues every (plane, segment, row) query back to back, one per clock, and
//     checks p_valid exactly three clocks later and all four modes' samples (an illegal mode reads 0). The SAD
//     accumulators are compared 5 clocks after the last query, the decision 4 clocks after dec_start (given 4 clocks
//     after the last query) against the reference argmin (cost and tie order of the module header).
//   * Inter candidate (phase 2c-1): every query also carries four random reference samples (q_ref); the accumulators sad_iy and
//     sad_ic (SAD of source against reference over luma, and over Cb plus Cr) are compared with the reference sums, and
//     dec_cost_y / dec_cost_c with the total (SAD plus mode cost) of the chosen intra mode, valid with dec_done.
//   * Corner cases: all 0, all 255, steep gradients that saturate the plane clip, extreme above-left sample.
//   * +INJECT_FAILURE is the negative control (forces one failed check).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-10-2026: phase 2c-1: inter SAD accumulators and the cost of the chosen intra modes.
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_ipred;

  import rtlnet_tb_pkg::*;

  localparam int NUM_CASES = 480;

  logic         clk = 1'b0;
  logic         resetn = 1'b0;
  logic         nb_load = 1'b0;
  logic [127:0] nb_top_y = '0, nb_left_y = '0, nb_top_c = '0, nb_left_c = '0;
  logic [7:0]   nb_tl_y = '0, nb_tl_cb = '0, nb_tl_cr = '0;
  logic         nb_av_top = 1'b0, nb_av_left = 1'b0;
  logic         prep_done;
  logic         q_valid = 1'b0;
  logic [1:0]   q_plane = '0, q_seg = '0;
  logic [3:0]   q_y = '0;
  logic [31:0]  q_src = '0;
  logic [31:0]  q_ref = '0;
  logic [17:0]  sad_iy, sad_ic;
  logic [19:0]  dec_cost_y, dec_cost_c;
  logic         q_acc = 1'b0;
  logic         p_valid;
  logic [127:0] p_px;
  logic         dec_start = 1'b0;
  logic         dec_done;
  logic [1:0]   dec_luma_mode, dec_chroma_mode;
  logic [71:0]  sad_y, sad_c;

  always #5 clk = ~clk;

  rtlnet_h264_ipred dut (.*);

  // ---------------------------------------------------------------------------
  // Reference model (per pixel, from clauses 8.3.3 and 8.3.4)
  // ---------------------------------------------------------------------------
  int ty [16];
  int ly [16];
  int tly;
  int tc [2][8];
  int lc [2][8];
  int tlc [2];
  bit avt, avl;
  int sy [16][16];
  int sc [2][8][8];
  int ry [16][16];
  int rc [2][8][8];

  function automatic int clip1(input int v);
    if (v < 0) return 0;
    if (v > 255) return 255;
    return v;
  endfunction

  // p[x,-1] and p[-1,y] with the corner at -1.
  function automatic int ptop_y(input int x);
    if (x < 0) return tly;
    return ty[x];
  endfunction
  function automatic int pleft_y(input int y);
    if (y < 0) return tly;
    return ly[y];
  endfunction
  function automatic int ptop_c(input int p, input int x);
    if (x < 0) return tlc[p];
    return tc[p][x];
  endfunction
  function automatic int pleft_c(input int p, input int y);
    if (y < 0) return tlc[p];
    return lc[p][y];
  endfunction

  // Luma Intra16x16 sample, spec mode 0 V, 1 H, 2 DC, 3 Plane.
  function automatic int ref_y(input int mode, input int x, input int y);
    int st, sl, hh, vv, a, b, c;
    st = 0;
    sl = 0;
    for (int i = 0; i < 16; i++) begin
      st += ty[i];
      sl += ly[i];
    end
    case (mode)
      0: return ty[x];
      1: return ly[y];
      2: begin
        if (avt && avl) return (st + sl + 16) >> 5;
        if (avl)        return (sl + 8) >> 4;
        if (avt)        return (st + 8) >> 4;
        return 128;
      end
      default: begin
        hh = 0;
        vv = 0;
        for (int i = 0; i < 8; i++) begin
          hh += (i + 1) * (ptop_y(8 + i) - ptop_y(6 - i));
          vv += (i + 1) * (pleft_y(8 + i) - pleft_y(6 - i));
        end
        a = 16 * (ly[15] + ty[15]);
        b = (5 * hh + 32) >>> 6;
        c = (5 * vv + 32) >>> 6;
        return clip1((a + b * (x - 7) + c * (y - 7) + 16) >>> 5);
      end
    endcase
  endfunction

  // Chroma sample of plane p (0 Cb, 1 Cr), spec mode 0 DC, 1 H, 2 V, 3 Plane.
  function automatic int ref_c(input int p, input int mode, input int x, input int y);
    int xo, yo, st, sl, hh, vv, a, b, c;
    xo = 4 * (x / 4);
    yo = 4 * (y / 4);
    st = 0;
    sl = 0;
    for (int i = 0; i < 4; i++) begin
      st += tc[p][xo + i];
      sl += lc[p][yo + i];
    end
    case (mode)
      0: begin
        if (((xo == 0) && (yo == 0)) || ((xo > 0) && (yo > 0))) begin
          if (avt && avl) return (st + sl + 4) >> 3;
          if (avl)        return (sl + 2) >> 2;
          if (avt)        return (st + 2) >> 2;
          return 128;
        end else if ((xo > 0) && (yo == 0)) begin
          if (avt) return (st + 2) >> 2;
          if (avl) return (sl + 2) >> 2;
          return 128;
        end else begin
          if (avl) return (sl + 2) >> 2;
          if (avt) return (st + 2) >> 2;
          return 128;
        end
      end
      1: return lc[p][y];
      2: return tc[p][x];
      default: begin
        hh = 0;
        vv = 0;
        for (int i = 0; i < 4; i++) begin
          hh += (i + 1) * (ptop_c(p, 4 + i) - ptop_c(p, 2 - i));
          vv += (i + 1) * (pleft_c(p, 4 + i) - pleft_c(p, 2 - i));
        end
        a = 16 * (lc[p][7] + tc[p][7]);
        b = (34 * hh + 32) >>> 6;
        c = (34 * vv + 32) >>> 6;
        return clip1((a + b * (x - 3) + c * (y - 3) + 16) >>> 5);
      end
    endcase
  endfunction

  function automatic bit legal(input int mode, input bit luma);
    if (luma) begin
      case (mode)
        0: return avt;
        1: return avl;
        2: return 1'b1;
        default: return avt && avl;
      endcase
    end
    case (mode)
      0: return 1'b1;
      1: return avl;
      2: return avt;
      default: return avt && avl;
    endcase
  endfunction

  // Expected 4-mode word of one query.
  function automatic logic [127:0] exp_word(input int plane, input int seg, input int y);
    logic [127:0] w;
    int v;
    w = '0;
    for (int m = 0; m < 4; m++) begin
      for (int i = 0; i < 4; i++) begin
        if (plane == 0) v = ref_y(m, 4 * seg + i, y);
        else            v = ref_c(plane - 1, m, 4 * seg + i, y);
        if (legal(m, plane == 0)) w[32*m + 8*i +: 8] = 8'(v);
      end
    end
    return w;
  endfunction

  function automatic logic [31:0] src_word(input int plane, input int seg, input int y);
    logic [31:0] w;
    for (int i = 0; i < 4; i++) begin
      if (plane == 0) w[8*i +: 8] = 8'(sy[y][4 * seg + i]);
      else            w[8*i +: 8] = 8'(sc[plane - 1][y][4 * seg + i]);
    end
    return w;
  endfunction

  function automatic logic [31:0] ref_word(input int plane, input int seg, input int y);
    logic [31:0] w;
    for (int i = 0; i < 4; i++) begin
      if (plane == 0) w[8*i +: 8] = 8'(ry[y][4 * seg + i]);
      else            w[8*i +: 8] = 8'(rc[plane - 1][y][4 * seg + i]);
    end
    return w;
  endfunction

  // Reference SAD of the reference samples against the source for one query (the inter candidate).
  function automatic int ref_sad_inter(input int plane, input int seg, input int y);
    int s, p, v;
    s = 0;
    for (int i = 0; i < 4; i++) begin
      if (plane == 0) begin
        p = ry[y][4 * seg + i];
        v = sy[y][4 * seg + i];
      end else begin
        p = rc[plane - 1][y][4 * seg + i];
        v = sc[plane - 1][y][4 * seg + i];
      end
      s += (p > v) ? (p - v) : (v - p);
    end
    return s;
  endfunction

  // Reference SAD of one query for one mode.
  function automatic int ref_sad(input int plane, input int mode, input int seg, input int y);
    int s, p, v;
    s = 0;
    for (int i = 0; i < 4; i++) begin
      if (plane == 0) begin
        p = ref_y(mode, 4 * seg + i, y);
        v = sy[y][4 * seg + i];
      end else begin
        p = ref_c(plane - 1, mode, 4 * seg + i, y);
        v = sc[plane - 1][y][4 * seg + i];
      end
      s += (p > v) ? (p - v) : (v - p);
    end
    return s;
  endfunction

  // ---------------------------------------------------------------------------
  // Query driver with the three-clock expectation pipeline (stage 3c: the query has an input register)
  // ---------------------------------------------------------------------------
  bit           e_v [3];
  logic [127:0] e_px [3];
  int           qcount;
  int           pxfail;

  task automatic tick(input bit v, input int plane, input int seg, input int y, input bit acc);
    @(negedge clk);
    // Outputs now belong to the query driven three negedges ago.
    tb_check(p_valid === e_v[2], "p_valid exactly three clocks after q_valid");
    if (e_v[2] && (p_px !== e_px[2])) begin
      if (pxfail == 0) tb_error($sformatf("pred mismatch got %032x exp %032x", p_px, e_px[2]));
      pxfail++;
    end
    e_v[2]  = e_v[1];
    e_px[2] = e_px[1];
    e_v[1]  = e_v[0];
    e_px[1] = e_px[0];
    e_v[0]  = v;
    q_valid = v;
    if (v) begin
      q_plane = 2'(plane);
      q_seg   = 2'(seg);
      q_y     = 4'(y);
      q_src   = src_word(plane, seg, y);
      q_ref   = ref_word(plane, seg, y);
      q_acc   = acc;
      e_px[0] = exp_word(plane, seg, y);
      qcount++;
    end else begin
      q_acc = 1'b0;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Case generation
  // ---------------------------------------------------------------------------
  function automatic int nbval(input int kind, input int i, input int n);
    case (kind)
      0: return $urandom % 256;
      1: return 0;
      2: return 255;
      3: return (i * 255) / (n - 1);           // ramp up
      4: return 255 - (i * 255) / (n - 1);     // ramp down
      5: return (i % 2) ? 255 : 0;
      default: return 100 + ($urandom % 40);
    endcase
  endfunction

  function automatic int srcval(input int kind, input int x, input int y, input int n);
    case (kind)
      0: return $urandom % 256;
      1: return 128;
      2: return clip1(ty[x % 16] + ($urandom % 9) - 4);         // close to the above row
      3: return clip1(ly[y % 16] + ($urandom % 9) - 4);         // close to the left column
      4: return clip1(((x + y) * 255) / (2 * (n - 1)));         // diagonal ramp
      6: return ((x * 255) / (n - 1) + 255 - (y * 255) / (n - 1)) / 2;  // plane-like
      default: return ((x ^ y) & 4) ? 220 : 30;
    endcase
  endfunction

  // Reference decision: first best total in the order DC, V, H, Plane over the legal modes.
  function automatic int ref_pick(input bit luma, input longint sad [4]);
    int ord [4];
    int cost [4];
    longint best, t;
    int bm;
    if (luma) begin
      ord[0] = 2; ord[1] = 0; ord[2] = 1; ord[3] = 3;
      cost[0] = 16; cost[1] = 16; cost[2] = 0; cost[3] = 32;
    end else begin
      ord[0] = 0; ord[1] = 2; ord[2] = 1; ord[3] = 3;
      cost[0] = 0; cost[1] = 16; cost[2] = 16; cost[3] = 32;
    end
    best = sad[ord[0]] + cost[ord[0]];
    bm = ord[0];
    for (int k = 1; k < 4; k++) begin
      if (legal(ord[k], luma)) begin
        t = sad[ord[k]] + cost[ord[k]];
        if (t < best) begin
          best = t;
          bm = ord[k];
        end
      end
    end
    return bm;
  endfunction

  longint rsad_y [4];
  longint rsad_c [4];
  longint rsad_iy, rsad_ic;
  logic [127:0] hy, hl, hc, hlc;
  int kind_n, kind_l, kind_s, tlkind;
  int lat;
  int seen [8];

  initial begin
    resetn = 1'b0;
    e_v[0] = 1'b0; e_v[1] = 1'b0; e_v[2] = 1'b0; e_px[0] = '0; e_px[1] = '0; e_px[2] = '0;
    qcount = 0;
    pxfail = 0;
    for (int i = 0; i < 8; i++) seen[i] = 0;
    repeat (4) @(negedge clk);
    resetn = 1'b1;
    repeat (2) @(negedge clk);
    for (int cs = 0; cs < NUM_CASES; cs++) begin
      avt = (cs % 4) >= 2;
      avl = ((cs % 4) % 2) == 1;
      if (cs < 28) begin
        kind_n = (cs / 4) % 7;
        kind_l = ((cs / 4) + 3) % 7;
      end else begin
        kind_n = (($urandom % 3) == 0) ? ($urandom % 7) : 0;
        kind_l = kind_n;
      end
      kind_s = $urandom % 7;
      tlkind = $urandom % 4;
      for (int i = 0; i < 16; i++) begin
        ty[i] = nbval(kind_n, i, 16);
        ly[i] = nbval(kind_l, i, 16);
      end
      for (int p = 0; p < 2; p++) begin
        for (int i = 0; i < 8; i++) begin
          tc[p][i] = nbval(kind_n, i, 8);
          lc[p][i] = nbval(kind_l, i, 8);
        end
      end
      case (tlkind)
        0: tly = $urandom % 256;
        1: tly = 0;
        2: tly = 255;
        default: tly = ty[0];
      endcase
      tlc[0] = (tlkind == 1) ? 0 : (tlkind == 2) ? 255 : $urandom % 256;
      tlc[1] = (tlkind == 1) ? 255 : (tlkind == 2) ? 0 : $urandom % 256;
      for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) sy[y][x] = srcval(kind_s, x, y, 16);
      for (int p = 0; p < 2; p++) for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) sc[p][y][x] = srcval(kind_s, x, y, 8);
      // Reference samples: close to the source (small SAD), random, or equal.
      for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++)
        ry[y][x] = (cs % 3 == 0) ? sy[y][x] : ((cs % 3 == 1) ? clip1(sy[y][x] + ($urandom % 11) - 5) : ($urandom % 256));
      for (int p = 0; p < 2; p++) for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++)
        rc[p][y][x] = (cs % 3 == 0) ? sc[p][y][x] : ((cs % 3 == 1) ? clip1(sc[p][y][x] + ($urandom % 11) - 5) : ($urandom % 256));
      for (int i = 0; i < 16; i++) begin
        hy[8*i +: 8] = 8'(ty[i]);
        hl[8*i +: 8] = 8'(ly[i]);
      end
      for (int i = 0; i < 8; i++) begin
        hc[8*i +: 8] = 8'(tc[0][i]);
        hc[64 + 8*i +: 8] = 8'(tc[1][i]);
        hlc[8*i +: 8] = 8'(lc[0][i]);
        hlc[64 + 8*i +: 8] = 8'(lc[1][i]);
      end

      // Load and wait for prep_done.
      @(negedge clk);
      nb_load = 1'b1; nb_top_y = hy; nb_left_y = hl; nb_tl_y = 8'(tly); nb_top_c = hc; nb_left_c = hlc;
      nb_tl_cb = 8'(tlc[0]); nb_tl_cr = 8'(tlc[1]); nb_av_top = avt; nb_av_left = avl;
      @(negedge clk);
      nb_load = 1'b0;
      lat = 1;
      while (!prep_done && lat < 60) begin
        @(negedge clk);
        lat++;
      end
      tb_check(prep_done === 1'b1, "prep_done seen");
      tb_check(lat <= 24, $sformatf("prep_done latency %0d clocks", lat));

      for (int m = 0; m < 4; m++) begin
        rsad_y[m] = 0;
        rsad_c[m] = 0;
      end
      rsad_iy = 0;
      rsad_ic = 0;
      // Queries: luma 16 rows x 4 segments, Cb and Cr 8 rows x 2 segments, one per clock.
      for (int y = 0; y < 16; y++) begin
        for (int s = 0; s < 4; s++) begin
          tick(1'b1, 0, s, y, 1'b1);
          for (int m = 0; m < 4; m++) if (legal(m, 1'b1)) rsad_y[m] += ref_sad(0, m, s, y);
          rsad_iy += ref_sad_inter(0, s, y);
        end
      end
      for (int p = 0; p < 2; p++) begin
        for (int y = 0; y < 8; y++) begin
          for (int s = 0; s < 2; s++) begin
            tick(1'b1, p + 1, s, y, 1'b1);
            for (int m = 0; m < 4; m++) if (legal(m, 1'b0)) rsad_c[m] += ref_sad(p + 1, m, s, y);
            rsad_ic += ref_sad_inter(p + 1, s, y);
          end
        end
      end
      // The last query was driven at the previous negedge; three idle clocks, dec_start on the fourth.
      tick(1'b0, 0, 0, 0, 1'b0);
      tick(1'b0, 0, 0, 0, 1'b0);
      tick(1'b0, 0, 0, 0, 1'b0);
      tick(1'b0, 0, 0, 0, 1'b0);
      dec_start = 1'b1;
      tick(1'b0, 0, 0, 0, 1'b0);
      // Accumulators are final here (5 clocks after the last query).
      for (int m = 0; m < 4; m++) begin
        tb_check(longint'(sad_y[18*m +: 18]) == rsad_y[m], $sformatf("case %0d sad_y[%0d] %0d expected %0d", cs, m, sad_y[18*m +: 18], rsad_y[m]));
        tb_check(longint'(sad_c[18*m +: 18]) == rsad_c[m], $sformatf("case %0d sad_c[%0d] %0d expected %0d", cs, m, sad_c[18*m +: 18], rsad_c[m]));
      end
      tb_check(longint'(sad_iy) == rsad_iy, $sformatf("case %0d sad_iy %0d expected %0d", cs, sad_iy, rsad_iy));
      tb_check(longint'(sad_ic) == rsad_ic, $sformatf("case %0d sad_ic %0d expected %0d", cs, sad_ic, rsad_ic));
      dec_start = 1'b0;
      lat = 1;
      while (!dec_done && lat < 20) begin
        @(negedge clk);
        lat++;
      end
      tb_check(dec_done === 1'b1, "dec_done seen");
      tb_check(int'(dec_luma_mode) == ref_pick(1'b1, rsad_y), $sformatf("case %0d luma mode %0d expected %0d", cs, dec_luma_mode, ref_pick(1'b1, rsad_y)));
      tb_check(int'(dec_chroma_mode) == ref_pick(1'b0, rsad_c), $sformatf("case %0d chroma mode %0d expected %0d", cs, dec_chroma_mode, ref_pick(1'b0, rsad_c)));
      begin
        int cy, cc;
        cy = (dec_luma_mode == 2) ? 0 : ((dec_luma_mode == 3) ? 32 : 16);
        cc = (dec_chroma_mode == 0) ? 0 : ((dec_chroma_mode == 3) ? 32 : 16);
        tb_check(longint'(dec_cost_y) == rsad_y[dec_luma_mode] + cy, $sformatf("case %0d dec_cost_y %0d expected %0d", cs, dec_cost_y, rsad_y[dec_luma_mode] + cy));
        tb_check(longint'(dec_cost_c) == rsad_c[dec_chroma_mode] + cc, $sformatf("case %0d dec_cost_c %0d expected %0d", cs, dec_cost_c, rsad_c[dec_chroma_mode] + cc));
      end
      seen[dec_luma_mode]++;
      seen[4 + dec_chroma_mode]++;
    end
    tb_check(pxfail == 0, $sformatf("%0d prediction word mismatches", pxfail));
    $display("NOTE: tb_rtlnet_h264_ipred: %0d cases, %0d queries; chosen luma modes V/H/DC/PL %0d/%0d/%0d/%0d, chroma DC/H/V/PL %0d/%0d/%0d/%0d",
             NUM_CASES, qcount, seen[0], seen[1], seen[2], seen[3], seen[4], seen[5], seen[6], seen[7]);
    tb_verdict("tb_rtlnet_h264_ipred");
  end

  initial begin
    #500ms;
    tb_error("watchdog");
    tb_verdict("tb_rtlnet_h264_ipred");
  end

endmodule
