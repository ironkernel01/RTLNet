// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_xform.sv
// Purpose: self-checking bench of the H.264 transform and quantizer units rtlnet_h264_fwdq, rtlnet_h264_invq,
//   rtlnet_h264_dcq_luma and rtlnet_h264_dcq_chroma against reference procedures written in this bench from the
//   formulas (matrix-form forward transform and quantizer; the decoder side written from ITU-T Rec. H.264 clauses
//   8.5.10 to 8.5.12 in their LevelScale form, not in the units' simplified form).
// Overview:
//   * fwdq: all QP 0..51 with 40 residual blocks per QP (zero, +255, -255, two checkerboards, 16 single-position impulses,
//     random full range, random small, random medium), then a stream whose QP changes at every block. Levels (16 per
//     block, DC position 0), W00, tag and the fixed latency of 8 clocks are checked; blocks run back to back and with
//     random gaps; qp and tag change on the non-first rows to show that they are sampled with the first row only.
//   * invq: random level blocks with a random scaled DC for all QP 0..51 and a mixed-QP stream; residuals compared with
//     the reference decoder process (tag and latency 8 checked).
//   * Chain: per QP a luma macroblock (16 blocks, fwdq, dcq_luma, invq) and both chroma planes (4 blocks each, QPc from the
//     package function, checked against a bench table, fwdq, dcq_chroma, invq): levels, DC levels, scaled DC values and
//     residuals compared with the reference chain.
//   * +INJECT_FAILURE is the negative control (forces one failed check). Checks use comparisons on whole values; no
//     foreach loops.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-10-2026: phase 2c-1: the chroma DC unit's inter rounding offset; inter modes of fwdq (in_inter: rounding offset 1/6; in_full: the DC position is quantized) and invq
//     (in_full: the DC position is dequantized like the others), swept over all QP in the same ways as the intra modes.
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_xform;

  import rtlnet_tb_pkg::*;
  import rtlnet_h264_pkg::*;

  logic clk    = 1'b0;
  logic resetn = 1'b0;
  always #5 clk = ~clk;

  int unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ---------------------------------------------------------------------------
  // DUT signals
  // ---------------------------------------------------------------------------
  logic [5:0]  f_qp = '0;
  logic        f_valid = 1'b0;
  logic        f_first = 1'b0;
  logic [35:0] f_res = '0;
  logic [7:0]  f_tag = '0;
  logic        f_inter = 1'b0;
  logic        f_full = 1'b0;
  logic        i_full = 1'b0;
  // Mode of the blocks of the running test (sampled by the DUT with the first row; random on the other rows).
  logic        m_inter = 1'b0;
  logic        m_full = 1'b0;
  logic        fo_valid, fo_dc_valid;
  logic [1:0]  fo_row;
  logic [47:0] fo_lvl;
  logic [15:0] fo_dc;
  logic [7:0]  fo_tag;

  logic [5:0]  i_qp = '0;
  logic        i_valid = 1'b0;
  logic        i_first = 1'b0;
  logic [47:0] i_lvl = '0;
  logic [19:0] i_dc = '0;
  logic [7:0]  i_tag = '0;
  logic        io_valid;
  logic [1:0]  io_row;
  logic [63:0] io_res;
  logic [7:0]  io_tag;
  logic [1:0]  io_pl, io_sg;
  logic [3:0]  io_yy;

  logic         l_start = 1'b0;
  logic [5:0]   l_qp = '0;
  logic [255:0] l_w = '0;
  logic         l_busy, l_done, l_nz;
  logic [191:0] l_lvl;
  logic [319:0] l_dc;

  logic         c_start = 1'b0;
  logic [5:0]   c_qpc = '0;
  logic         c_inter = 1'b0;
  logic [63:0]  c_w = '0;
  logic         c_busy, c_done, c_nz;
  logic [47:0]  c_lvl;
  logic [79:0]  c_dc;

  rtlnet_h264_fwdq u_fwdq (
    .clk(clk), .resetn(resetn), .qp(f_qp), .in_valid(f_valid), .in_first(f_first), .in_res(f_res), .in_tag(f_tag),
    .in_inter(f_inter), .in_full(f_full),
    .out_valid(fo_valid), .out_row(fo_row), .out_lvl(fo_lvl), .out_dc_valid(fo_dc_valid), .out_dc(fo_dc), .out_tag(fo_tag)
  );

  rtlnet_h264_invq u_invq (
    .clk(clk), .resetn(resetn), .qp(i_qp), .in_valid(i_valid), .in_first(i_first), .in_lvl(i_lvl), .in_dc(i_dc),
    .in_tag(i_tag), .in_full(i_full), .out_valid(io_valid), .out_row(io_row), .out_res(io_res), .out_tag(io_tag),
    .out_pl(io_pl), .out_sg(io_sg), .out_yy(io_yy)
  );

  // The decoded tag outputs (plane, segment, row of the plane's part) against the block numbering: 0..15 luma raster, 16..19 Cb, 20..23 Cr.
  always @(negedge clk) begin
    if (io_valid && (io_tag[4:0] < 5'd24)) begin
      automatic int b_ = int'(io_tag[4:0]);
      automatic int pl_ = (b_ < 16) ? 0 : ((b_ < 20) ? 1 : 2);
      automatic int sg_ = (b_ < 16) ? (b_ % 4) : (b_ % 2);
      automatic int yy_ = (b_ < 16) ? (4 * (b_ / 4) + int'(io_row)) : (4 * ((b_ % 4) / 2) + int'(io_row));
      tb_check(int'(io_pl) == pl_ && int'(io_sg) == sg_ && int'(io_yy) == yy_, $sformatf("invq decoded tag: block %0d row %0d", b_, io_row));
    end
  end

  rtlnet_h264_dcq_luma u_dcl (
    .clk(clk), .resetn(resetn), .start(l_start), .qp(l_qp), .w_in(l_w), .busy(l_busy), .done(l_done),
    .lvl_out(l_lvl), .nz(l_nz), .dc_out(l_dc)
  );

  rtlnet_h264_dcq_chroma u_dcc (
    .clk(clk), .resetn(resetn), .start(c_start), .qpc(c_qpc), .inter(c_inter), .w_in(c_w), .busy(c_busy), .done(c_done),
    .lvl_out(c_lvl), .nz(c_nz), .dc_out(c_dc)
  );

  // ---------------------------------------------------------------------------
  // Reference tables and procedures (integer math, independent of the units)
  // ---------------------------------------------------------------------------
  localparam int CF [4][4] = '{'{1, 1, 1, 1}, '{2, 1, -1, -2}, '{1, -1, -1, 1}, '{1, -2, 2, -1}};
  localparam int HD [4][4] = '{'{1, 1, 1, 1}, '{1, 1, -1, -1}, '{1, -1, -1, 1}, '{1, -1, 1, -1}};
  localparam int MFT [6][3] = '{'{13107, 5243, 8066}, '{11916, 4660, 7490}, '{10082, 4194, 6554},
                                '{9362, 3647, 5825}, '{8192, 3355, 5243}, '{7282, 2893, 4559}};
  localparam int VT [6][3] = '{'{10, 16, 13}, '{11, 18, 14}, '{13, 20, 16}, '{14, 23, 18}, '{16, 25, 20}, '{18, 29, 23}};
  // QPc for qPI 30..51 (Table 8-15).
  localparam int QPC_T [22] = '{29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39};

  function automatic int ref_qpc(input int qp);
    if (qp < 30) return qp;
    return QPC_T[qp - 30];
  endfunction

  // Position class of raster position p: 0 both even, 1 both odd, 2 other.
  function automatic int pclass(input int p);
    int r, c;
    r = p / 4;
    c = p % 4;
    if ((r % 2 == 0) && (c % 2 == 0)) return 0;
    if ((r % 2 == 1) && (c % 2 == 1)) return 1;
    return 2;
  endfunction

  function automatic longint iabs(input longint v);
    return (v < 0) ? -v : v;
  endfunction

  // Forward core transform W = Cf X Cf^T of a 4x4 block in raster order.
  task automatic ref_fwd(input int x[16], output int w[16]);
    int t [16];
    for (int i = 0; i < 4; i++) begin
      for (int j = 0; j < 4; j++) begin
        t[i*4 + j] = 0;
        for (int k = 0; k < 4; k++) t[i*4 + j] += CF[i][k] * x[k*4 + j];
      end
    end
    for (int i = 0; i < 4; i++) begin
      for (int j = 0; j < 4; j++) begin
        w[i*4 + j] = 0;
        for (int k = 0; k < 4; k++) w[i*4 + j] += t[i*4 + k] * CF[j][k];
      end
    end
  endtask

  // Quantizer: min(2047, (|v| * mf + off) >> sh) with the sign of v.
  function automatic int ref_quant(input longint v, input longint mf, input longint off, input int sh);
    longint q;
    q = (iabs(v) * mf + off) >> sh;
    if (q > 2047) q = 2047;
    return (v < 0) ? -int'(q) : int'(q);
  endfunction

  function automatic int ref_ac_lvl(input int w, input int qp, input int pos);
    int qbits;
    qbits = 15 + qp / 6;
    return ref_quant(w, MFT[qp % 6][pclass(pos)], m_inter ? ((64'd1 << qbits) / 6) : ((64'd1 << qbits) / 3), qbits);
  endfunction

  // Luma DC: Yf = H Wd H, level = (|Yf| MF + 4f) >> (qbits + 2).
  task automatic ref_dc_luma_q(input int wd[16], input int qp, output int lvl[16]);
    int t [16];
    int y [16];
    int qbits;
    for (int i = 0; i < 4; i++)
      for (int j = 0; j < 4; j++) begin
        t[i*4 + j] = 0;
        for (int k = 0; k < 4; k++) t[i*4 + j] += HD[i][k] * wd[k*4 + j];
      end
    for (int i = 0; i < 4; i++)
      for (int j = 0; j < 4; j++) begin
        y[i*4 + j] = 0;
        for (int k = 0; k < 4; k++) y[i*4 + j] += t[i*4 + k] * HD[k][j];
      end
    qbits = 15 + qp / 6;
    for (int i = 0; i < 16; i++) lvl[i] = ref_quant(y[i], MFT[qp % 6][0], 4 * ((64'd1 << qbits) / 3), qbits + 2);
  endtask

  // Chroma DC: Yc = [1 1; 1 -1] Wd [1 1; 1 -1], level = (|Yc| MF + 2f) >> (qbits + 1).
  task automatic ref_dc_chroma_q(input int wd[4], input int qpc, output int lvl[4]);
    int y [4];
    int qbits;
    y[0] = wd[0] + wd[1] + wd[2] + wd[3];
    y[1] = wd[0] - wd[1] + wd[2] - wd[3];
    y[2] = wd[0] + wd[1] - wd[2] - wd[3];
    y[3] = wd[0] - wd[1] - wd[2] + wd[3];
    qbits = 15 + qpc / 6;
    for (int i = 0; i < 4; i++) lvl[i] = ref_quant(y[i], MFT[qpc % 6][0], m_inter ? (2 * ((64'd1 << qbits) / 6)) : (2 * ((64'd1 << qbits) / 3)), qbits + 1);
  endtask

  // Clause 8.5.9 / 8.5.12.1 LevelScale form for one coefficient at raster position pos (flat weights 16).
  function automatic longint ref_scale_ac(input int lvl, input int qp, input int pos);
    longint ls, v;
    ls = 16 * VT[qp % 6][pclass(pos)];
    v  = lvl * ls;
    if (qp >= 24) return v <<< (qp / 6 - 4);
    return (v + (longint'(1) <<< (3 - qp / 6))) >>> (4 - qp / 6);
  endfunction

  // Clause 8.5.10: Intra16x16 luma DC (c is the level matrix, raster).
  task automatic ref_dc_luma_dec(input int c[16], input int qp, output int dcy[16]);
    longint t [16];
    longint f [16];
    longint ls;
    ls = 16 * VT[qp % 6][0];
    for (int i = 0; i < 4; i++)
      for (int j = 0; j < 4; j++) begin
        t[i*4 + j] = 0;
        for (int k = 0; k < 4; k++) t[i*4 + j] += HD[i][k] * c[k*4 + j];
      end
    for (int i = 0; i < 4; i++)
      for (int j = 0; j < 4; j++) begin
        f[i*4 + j] = 0;
        for (int k = 0; k < 4; k++) f[i*4 + j] += t[i*4 + k] * HD[k][j];
      end
    for (int i = 0; i < 16; i++) begin
      if (qp >= 36) dcy[i] = int'((f[i] * ls) <<< (qp / 6 - 6));
      else          dcy[i] = int'((f[i] * ls + (longint'(1) <<< (5 - qp / 6))) >>> (6 - qp / 6));
    end
  endtask

  // Clause 8.5.11.2: chroma DC for 4:2:0.
  task automatic ref_dc_chroma_dec(input int c[4], input int qpc, output int dcc[4]);
    longint f [4];
    longint ls;
    ls = 16 * VT[qpc % 6][0];
    f[0] = c[0] + c[1] + c[2] + c[3];
    f[1] = c[0] - c[1] + c[2] - c[3];
    f[2] = c[0] + c[1] - c[2] - c[3];
    f[3] = c[0] - c[1] - c[2] + c[3];
    for (int i = 0; i < 4; i++) dcc[i] = int'(((f[i] * ls) <<< (qpc / 6)) >>> 5);
  endtask

  // Clause 8.5.12: scaling of the AC levels (dc replaces position 0) and the inverse 4x4 transform, residual (h + 32) >> 6.
  task automatic ref_inv(input int lvl[16], input int dc, input int qp, output int res[16]);
    longint d [16];
    longint e [16];
    longint g [16];
    longint h [16];
    longint x;
    for (int p = 0; p < 16; p++) d[p] = ((p == 0) && !m_full) ? longint'(dc) : ref_scale_ac(lvl[p], qp, p);
    for (int i = 0; i < 4; i++) begin
      e[i*4 + 0] = d[i*4 + 0] + d[i*4 + 2];
      e[i*4 + 1] = d[i*4 + 0] - d[i*4 + 2];
      e[i*4 + 2] = (d[i*4 + 1] >>> 1) - d[i*4 + 3];
      e[i*4 + 3] = d[i*4 + 1] + (d[i*4 + 3] >>> 1);
      g[i*4 + 0] = e[i*4 + 0] + e[i*4 + 3];
      g[i*4 + 1] = e[i*4 + 1] + e[i*4 + 2];
      g[i*4 + 2] = e[i*4 + 1] - e[i*4 + 2];
      g[i*4 + 3] = e[i*4 + 0] - e[i*4 + 3];
    end
    for (int j = 0; j < 4; j++) begin
      e[0*4 + j] = g[0*4 + j] + g[2*4 + j];
      e[1*4 + j] = g[0*4 + j] - g[2*4 + j];
      e[2*4 + j] = (g[1*4 + j] >>> 1) - g[3*4 + j];
      e[3*4 + j] = g[1*4 + j] + (g[3*4 + j] >>> 1);
      h[0*4 + j] = e[0*4 + j] + e[3*4 + j];
      h[1*4 + j] = e[1*4 + j] + e[2*4 + j];
      h[2*4 + j] = e[1*4 + j] - e[2*4 + j];
      h[3*4 + j] = e[0*4 + j] - e[3*4 + j];
    end
    for (int p = 0; p < 16; p++) begin
      x = (h[p] + 32) >>> 6;
      if (x > 32767) x = 32767;
      if (x < -32767) x = -32767;
      res[p] = int'(x);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Random helpers
  // ---------------------------------------------------------------------------
  function automatic int rr(input int lo, input int hi);
    return lo + int'($urandom % unsigned'(hi - lo + 1));
  endfunction

  function automatic int rgap();
    if (rr(0, 99) < 65) return 0;
    return rr(1, 4);
  endfunction

  // ---------------------------------------------------------------------------
  // Drivers and monitors
  // ---------------------------------------------------------------------------
  int          f_in_cyc [256];
  int          i_in_cyc [256];
  int          fg_lvl [256][16];
  int          fg_dc [256];
  int          fg_rows [256];
  int          fg_lat [256];
  int          ig_res [256][16];
  int          ig_rows [256];
  int          ig_lat [256];

  task automatic clear_f();
    for (int t = 0; t < 256; t++) begin
      fg_rows[t] = 0; fg_lat[t] = -1; fg_dc[t] = 0;
      for (int p = 0; p < 16; p++) fg_lvl[t][p] = 0;
    end
  endtask

  task automatic clear_i();
    for (int t = 0; t < 256; t++) begin
      ig_rows[t] = 0; ig_lat[t] = -1;
      for (int p = 0; p < 16; p++) ig_res[t][p] = 0;
    end
  endtask

  always @(negedge clk) begin
    if (fo_valid) begin
      for (int c = 0; c < 4; c++) fg_lvl[fo_tag][4*fo_row + c] = int'($signed(fo_lvl[12*c +: 12]));
      fg_rows[fo_tag] = fg_rows[fo_tag] + 1;
      if (fo_dc_valid) begin
        fg_dc[fo_tag]  = int'($signed(fo_dc));
        fg_lat[fo_tag] = int'(cyc) - f_in_cyc[fo_tag];
      end
    end
    if (io_valid) begin
      for (int c = 0; c < 4; c++) ig_res[io_tag][4*io_row + c] = int'($signed(io_res[16*c +: 16]));
      ig_rows[io_tag] = ig_rows[io_tag] + 1;
      if (io_row == 2'd0) ig_lat[io_tag] = int'(cyc) - i_in_cyc[io_tag];
    end
  end

  // Send one residual block (raster x) with qp and tag; gap idle clocks first.
  task automatic send_fwd(input int x[16], input int qp, input int tag, input int gap);
    for (int g = 0; g < gap; g++) begin
      @(negedge clk);
      f_valid = 1'b0;
      f_first = 1'b0;
    end
    for (int r = 0; r < 4; r++) begin
      @(negedge clk);
      f_valid = 1'b1;
      f_first = (r == 0);
      f_qp    = 6'((r == 0) ? qp : rr(0, 51));
      f_tag   = 8'((r == 0) ? tag : rr(0, 255));
      f_inter = (r == 0) ? m_inter : 1'(rr(0, 1));
      f_full  = (r == 0) ? m_full : 1'(rr(0, 1));
      for (int c = 0; c < 4; c++) f_res[9*c +: 9] = 9'(x[4*r + c]);
      if (r == 0) f_in_cyc[tag] = int'(cyc);
    end
  endtask

  task automatic idle_f();
    @(negedge clk);
    f_valid = 1'b0;
    f_first = 1'b0;
  endtask

  task automatic send_inv(input int lvl[16], input int dc, input int qp, input int tag, input int gap);
    for (int g = 0; g < gap; g++) begin
      @(negedge clk);
      i_valid = 1'b0;
      i_first = 1'b0;
    end
    for (int r = 0; r < 4; r++) begin
      @(negedge clk);
      i_valid = 1'b1;
      i_first = (r == 0);
      i_qp    = 6'((r == 0) ? qp : rr(0, 51));
      i_tag   = 8'((r == 0) ? tag : rr(0, 255));
      i_dc    = 20'((r == 0) ? dc : rr(-500000, 500000));
      i_full  = (r == 0) ? m_full : 1'(rr(0, 1));
      for (int c = 0; c < 4; c++) i_lvl[12*c +: 12] = 12'(lvl[4*r + c]);
      if (r == 0) i_in_cyc[tag] = int'(cyc);
    end
  endtask

  task automatic idle_i();
    @(negedge clk);
    i_valid = 1'b0;
    i_first = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Block generators
  // ---------------------------------------------------------------------------
  // Residual block n of the per-QP fwdq list.
  task automatic make_res(input int n, output int x[16]);
    for (int p = 0; p < 16; p++) x[p] = 0;
    if (n == 0) begin
      // zero
    end else if (n == 1) begin
      for (int p = 0; p < 16; p++) x[p] = 255;
    end else if (n == 2) begin
      for (int p = 0; p < 16; p++) x[p] = -255;
    end else if (n == 3) begin
      for (int p = 0; p < 16; p++) x[p] = (((p / 4) + (p % 4)) % 2 == 0) ? 255 : -255;
    end else if (n == 4) begin
      for (int p = 0; p < 16; p++) x[p] = (((p / 4) + (p % 4)) % 2 == 0) ? -255 : 255;
    end else if (n < 21) begin
      x[n - 5] = ((n % 2) == 0) ? 255 : -255;
    end else if (n < 31) begin
      for (int p = 0; p < 16; p++) x[p] = rr(-255, 255);
    end else if (n < 39) begin
      for (int p = 0; p < 16; p++) x[p] = rr(-8, 8);
    end else begin
      for (int p = 0; p < 16; p++) x[p] = rr(-60, 60);
    end
  endtask

  // Compare the captured fwdq outputs of tags 0..n-1 against references of blocks xs/qps.
  int xs [256][16];
  int qs [256];

  task automatic check_fwd(input int n, input string what);
    int w [16];
    int lv;
    for (int b = 0; b < n; b++) begin
      ref_fwd(xs[b], w);
      tb_check(fg_rows[b] == 4, $sformatf("%s block %0d: %0d output rows", what, b, fg_rows[b]));
      tb_check(fg_lat[b] == 8, $sformatf("%s block %0d: latency %0d", what, b, fg_lat[b]));
      tb_check(fg_dc[b] == w[0], $sformatf("%s block %0d qp %0d: W00 %0d, expected %0d", what, b, qs[b], fg_dc[b], w[0]));
      for (int p = 0; p < 16; p++) begin
        lv = ((p == 0) && !m_full) ? 0 : ref_ac_lvl(w[p], qs[b], p);
        tb_check(fg_lvl[b][p] == lv, $sformatf("%s block %0d qp %0d pos %0d: level %0d, expected %0d", what, b, qs[b], p, fg_lvl[b][p], lv));
      end
    end
  endtask

  task automatic fwd_qp_sweep();
    int x [16];
    int qp;
    qp = 0;
    while (qp < 52) begin
      clear_f();
      for (int n = 0; n < 40; n++) begin
        make_res(n, x);
        for (int p = 0; p < 16; p++) xs[n][p] = x[p];
        qs[n] = qp;
        send_fwd(x, qp, n, rgap());
      end
      idle_f();
      repeat (24) @(negedge clk);
      check_fwd(40, $sformatf("fwdq qp %0d", qp));
      qp++;
    end
  endtask

  // Mixed-QP stream: the QP changes at every block (back to back and with gaps).
  task automatic fwd_mixed();
    int x [16];
    for (int round = 0; round < 6; round++) begin
      clear_f();
      for (int n = 0; n < 200; n++) begin
        make_res(rr(0, 44), x);
        for (int p = 0; p < 16; p++) xs[n][p] = x[p];
        qs[n] = rr(0, 51);
        send_fwd(x, qs[n], n, (round % 2 == 0) ? 0 : rgap());
      end
      idle_f();
      repeat (24) @(negedge clk);
      check_fwd(200, $sformatf("fwdq mixed round %0d", round));
    end
  endtask

  // invq with random levels and DC.
  int ilv [256][16];
  int idc [256];

  task automatic check_inv(input int n, input string what);
    int d [16];
    int r [16];
    for (int b = 0; b < n; b++) begin
      for (int p = 0; p < 16; p++) d[p] = ilv[b][p];
      ref_inv(d, idc[b], qs[b], r);
      tb_check(ig_rows[b] == 4, $sformatf("%s block %0d: %0d output rows", what, b, ig_rows[b]));
      tb_check(ig_lat[b] == 8, $sformatf("%s block %0d: latency %0d", what, b, ig_lat[b]));
      for (int p = 0; p < 16; p++)
        tb_check(ig_res[b][p] == r[p], $sformatf("%s block %0d qp %0d pos %0d: residual %0d, expected %0d", what, b, qs[b], p, ig_res[b][p], r[p]));
    end
  endtask

  task automatic make_lvl(input int qp, input int style, output int lv[16], output int dc);
    int lim;
    lim = 20000 / (29 * (1 << (qp / 6)));
    if (lim > 2047) lim = 2047;
    if (lim < 1) lim = 1;
    for (int p = 0; p < 16; p++) begin
      case (style % 4)
        0: lv[p] = rr(-3, 3);
        1: lv[p] = rr(-lim, lim);
        2: lv[p] = (rr(0, 3) == 0) ? rr(-lim, lim) : 0;
        default: lv[p] = (p == 5) ? lim : ((p == 10) ? -lim : 0);
      endcase
    end
    dc = rr(-12000, 12000);
  endtask

  task automatic inv_sweep();
    int lv [16];
    int dc;
    int qp;
    qp = 0;
    while (qp < 52) begin
      clear_i();
      for (int n = 0; n < 24; n++) begin
        make_lvl(qp, n, lv, dc);
        for (int p = 0; p < 16; p++) ilv[n][p] = lv[p];
        idc[n] = dc;
        qs[n]  = qp;
        send_inv(lv, dc, qp, n, rgap());
      end
      idle_i();
      repeat (24) @(negedge clk);
      check_inv(24, $sformatf("invq qp %0d", qp));
      qp++;
    end
    for (int round = 0; round < 4; round++) begin
      clear_i();
      for (int n = 0; n < 200; n++) begin
        qs[n] = rr(0, 51);
        make_lvl(qs[n], rr(0, 3), lv, dc);
        for (int p = 0; p < 16; p++) ilv[n][p] = lv[p];
        idc[n] = dc;
        send_inv(lv, dc, qs[n], n, (round % 2 == 0) ? 0 : rgap());
      end
      idle_i();
      repeat (24) @(negedge clk);
      check_inv(200, $sformatf("invq mixed round %0d", round));
    end
  endtask

  // ---------------------------------------------------------------------------
  // DC units and chains
  // ---------------------------------------------------------------------------
  int dl_lat, dc_lat;
  logic [191:0] dl_lvl;
  logic [319:0] dl_dc;
  logic         dl_nz;
  logic [47:0]  dcc_lvl;
  logic [79:0]  dcc_dc;
  logic         dcc_nz;

  task automatic run_dcl(input int qp, input logic [255:0] w);
    int t0;
    @(negedge clk);
    l_start = 1'b1;
    l_qp    = 6'(qp);
    l_w     = w;
    t0      = int'(cyc);
    @(negedge clk);
    l_start = 1'b0;
    l_qp    = 6'(rr(0, 51));
    l_w     = {8{32'($urandom)}};
    while (!l_done) @(negedge clk);
    dl_lat = int'(cyc) - t0;
    dl_lvl = l_lvl;
    dl_dc  = l_dc;
    dl_nz  = l_nz;
    @(negedge clk);
  endtask

  task automatic run_dcc(input int qpc, input logic [63:0] w);
    int t0;
    @(negedge clk);
    c_start = 1'b1;
    c_qpc   = 6'(qpc);
    c_inter = m_inter;
    c_w     = w;
    t0      = int'(cyc);
    @(negedge clk);
    c_start = 1'b0;
    c_qpc   = 6'(rr(0, 51));
    c_inter = 1'(rr(0, 1));
    c_w     = {2{32'($urandom)}};
    while (!c_done) @(negedge clk);
    dc_lat = int'(cyc) - t0;
    dcc_lvl = c_lvl;
    dcc_dc  = c_dc;
    dcc_nz  = c_nz;
    @(negedge clk);
  endtask

  // Style of the residual for the chain blocks.
  task automatic make_chain_res(input int style, output int x[16]);
    for (int p = 0; p < 16; p++) begin
      case (style % 4)
        0: x[p] = rr(-255, 255);
        1: x[p] = rr(-8, 8);
        2: x[p] = 40 + (p % 4) * 3 - (p / 4) * 2 + rr(-2, 2);
        default: x[p] = ((p / 4) < 2) ? rr(100, 255) : rr(-255, -100);
      endcase
    end
  endtask

  // Full chain of one plane: nb blocks, luma (16, dcq_luma, qp) or chroma (4, dcq_chroma, qpc).
  task automatic chain(input bit luma, input int qp, input int style, input string what);
    int nb;
    int x [16];
    int w [16];
    int rl [16];
    int rdc [16];
    int rdcd [16];
    int wd [16];
    int wc [4];
    int lc [4];
    int dcc [4];
    int lcc [4];
    int cres [16];
    int tmp [16];
    logic [255:0] wv;
    logic [63:0]  wv4;
    logic [191:0] dlv;
    int  exp_ac [16][16];
    int  exp_w00 [16];
    int  exp_dcy [16];
    nb = luma ? 16 : 4;
    clear_f();
    for (int b = 0; b < nb; b++) begin
      make_chain_res(style + b / 5, x);
      for (int p = 0; p < 16; p++) xs[b][p] = x[p];
      qs[b] = qp;
      send_fwd(x, qp, b, 0);
    end
    idle_f();
    repeat (24) @(negedge clk);
    check_fwd(nb, what);
    // Reference levels and DC chain.
    for (int b = 0; b < nb; b++) begin
      ref_fwd(xs[b], w);
      exp_w00[b] = w[0];
      for (int p = 0; p < 16; p++) exp_ac[b][p] = (p == 0) ? 0 : ref_ac_lvl(w[p], qp, p);
    end
    wv  = '0;
    wv4 = '0;
    // The DC units take the RTL fwdq W00 values (already compared equal to the reference).
    for (int b = 0; b < nb; b++) begin
      wv[16*b +: 16]  = 16'(fg_dc[b]);
      wv4[16*b +: 16] = 16'(fg_dc[b]);
    end
    if (luma) begin
      for (int b = 0; b < 16; b++) wd[b] = exp_w00[b];
      ref_dc_luma_q(wd, qp, rdc);
      ref_dc_luma_dec(rdc, qp, exp_dcy);
      run_dcl(qp, wv);
      tb_check(dl_lat == 34, $sformatf("%s dcq_luma latency %0d", what, dl_lat));
      for (int i = 0; i < 16; i++) begin
        tb_check(int'($signed(dl_lvl[12*i +: 12])) == rdc[i], $sformatf("%s dcq_luma qp %0d level %0d: %0d, expected %0d", what, qp, i, int'($signed(dl_lvl[12*i +: 12])), rdc[i]));
        tb_check(int'($signed(dl_dc[20*i +: 20])) == exp_dcy[i], $sformatf("%s dcq_luma qp %0d dcY %0d: %0d, expected %0d", what, qp, i, int'($signed(dl_dc[20*i +: 20])), exp_dcy[i]));
      end
    end else begin
      for (int b = 0; b < 4; b++) wc[b] = exp_w00[b];
      ref_dc_chroma_q(wc, qp, lc);
      ref_dc_chroma_dec(lc, qp, dcc);
      run_dcc(qp, wv4);
      tb_check(dc_lat == 7, $sformatf("%s dcq_chroma latency %0d", what, dc_lat));
      for (int i = 0; i < 4; i++) begin
        tb_check(int'($signed(dcc_lvl[12*i +: 12])) == lc[i], $sformatf("%s dcq_chroma qpc %0d level %0d: %0d, expected %0d", what, qp, i, int'($signed(dcc_lvl[12*i +: 12])), lc[i]));
        tb_check(int'($signed(dcc_dc[20*i +: 20])) == dcc[i], $sformatf("%s dcq_chroma qpc %0d dcC %0d: %0d, expected %0d", what, qp, i, int'($signed(dcc_dc[20*i +: 20])), dcc[i]));
      end
    end
    // Residuals: RTL levels and RTL scaled DC into invq against the reference chain.
    clear_i();
    for (int b = 0; b < nb; b++) begin
      for (int p = 0; p < 16; p++) ilv[b][p] = fg_lvl[b][p];
      idc[b] = luma ? int'($signed(dl_dc[20*b +: 20])) : int'($signed(dcc_dc[20*b +: 20]));
      qs[b]  = qp;
      send_inv(ilv[b], idc[b], qp, b, 0);
    end
    idle_i();
    repeat (24) @(negedge clk);
    for (int b = 0; b < nb; b++) begin
      for (int p = 0; p < 16; p++) tmp[p] = exp_ac[b][p];
      ref_inv(tmp, luma ? exp_dcy[b] : dcc[b], qp, cres);
      tb_check(ig_rows[b] == 4, $sformatf("%s chain block %0d rows %0d", what, b, ig_rows[b]));
      for (int p = 0; p < 16; p++)
        tb_check(ig_res[b][p] == cres[p], $sformatf("%s chain block %0d qp %0d pos %0d: residual %0d, expected %0d", what, b, qp, p, ig_res[b][p], cres[p]));
    end
    // The reconstruction error stays small at low QP (the chain codes the right content).
    if (qp <= 12) begin
      for (int b = 0; b < nb; b++)
        for (int p = 0; p < 16; p++)
          tb_check(iabs(ig_res[b][p] - xs[b][p]) <= 8, $sformatf("%s chain block %0d qp %0d pos %0d: reconstruction %0d, source %0d", what, b, qp, p, ig_res[b][p], xs[b][p]));
    end
    // Silence unused scratch.
    rl[0] = 0; rdcd[0] = 0; lcc[0] = 0; dlv = '0;
  endtask

  initial begin
    for (int q = 0; q < 52; q++) tb_check(int'(h264_qpc(6'(q))) == ref_qpc(q), $sformatf("h264_qpc(%0d)", q));
    clear_f();
    clear_i();
    resetn = 1'b0;
    repeat (6) @(negedge clk);
    resetn = 1'b1;
    repeat (4) @(negedge clk);

    fwd_qp_sweep();
    fwd_mixed();
    inv_sweep();
    // Inter modes (phase 2c-1): rounding offset 1/6 with the DC position left out (chroma blocks) and quantized (luma blocks).
    m_inter = 1'b1; m_full = 1'b0;
    fwd_qp_sweep();
    m_full = 1'b1;
    fwd_qp_sweep();
    fwd_mixed();
    inv_sweep();
    // The chroma chains of an inter macroblock: AC quantizer and the chroma DC unit with the rounding offset 1/6.
    m_full = 1'b0;
    for (int qp = 0; qp < 52; qp++) begin
      for (int style = 0; style < 4; style++) chain(1'b0, ref_qpc(qp), style, $sformatf("inter chroma chain qpc %0d style %0d", ref_qpc(qp), style));
    end
    m_inter = 1'b0; m_full = 1'b0;
    for (int qp = 0; qp < 52; qp++) begin
      for (int style = 0; style < 4; style++) begin
        chain(1'b1, qp, style, $sformatf("luma chain qp %0d style %0d", qp, style));
        chain(1'b0, ref_qpc(qp), style, $sformatf("chroma chain qpc %0d style %0d", ref_qpc(qp), style));
      end
    end
    tb_verdict("tb_rtlnet_h264_xform");
  end

  initial begin
    repeat (40_000_000) @(posedge clk);
    tb_error("watchdog: simulation limit reached");
    tb_verdict("tb_rtlnet_h264_xform");
  end

endmodule
