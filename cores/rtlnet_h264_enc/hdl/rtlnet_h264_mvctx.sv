// -----------------------------------------------------------------------------
// File: rtlnet_h264_mvctx.sv
// Purpose: motion vector context of stage A for P slices: the motion vectors and the inter flag of the macroblock to the left
//   and of the macroblock row above, and the prediction of the current macroblock (rtlnet_h264_mvpred).
// Overview:
//   * start (one clock, with mb_x and the availability of the above, above-right and left macroblocks) fetches the context:
//     the above row's entries of columns mb_x and mb_x + 1 from a line RAM (rtlnet_ram_core, one 32-bit word per column:
//     bit 31 inter, [29:16] mv y, [13:0] mv x, 14-bit quarter-sample components) and takes the left macroblock from registers;
//     the above-left entry D is the entry that was column mb_x of the previous macroblock's start (the line RAM word of
//     column mb_x - 1 has been overwritten by then). Seven clocks after start, ready pulses: mvp (clause 8.4.1.3) and the
//     P_Skip motion vector (clause 8.4.1.1) are valid and stay until the next start.
//   * upd (one clock, at the end of a macroblock, with upd_inter and the motion vector of the macroblock; an intra or I_PCM
//     macroblock has upd_inter 0 and mv 0, a P_Skip macroblock upd_inter 1 and the skip motion vector) writes the line RAM
//     word of the macroblock's column and the left registers.
//   * The entries of the neighbours (nb_*) are visible for the caller that needs the vectors themselves (the motion search of
//     phase 2c-2 uses them as search candidates).
//   * Availability is the caller's: av_top (not the first row of the slice), av_left (not the first column), av_tr (av_top and
//     a column to the right). The line RAM is not cleared between slices or pictures: entries of unavailable neighbours are
//     never used.
//   * MV_LINE_KB sizes the line RAM (one 32-bit word per column plus the above-right column: at least MAX_MB_W + 1 words).
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-10-2026: initial version (phase 2c-1).
//   * 11-10-2026: phase 2c-2: skip_zero from the registered skip vector (timing); neighbour entries exported.
//   * 11-12-2026: stage 3c: the prediction in three clocks with registers between the stages (timing); ready seven clocks after start, not five.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_mvctx #(
  parameter int    MAX_MB_W   = 120,
  parameter int    MV_LINE_KB = 1,
  parameter string RAM_STYLE  = "block"
)(
  input  logic                              clk,
  input  logic                              resetn,

  input  logic                              start,
  input  logic [6:0]                        mb_x,
  input  logic                              av_top,
  input  logic                              av_left,
  input  logic                              av_tr,
  output logic                              ready,
  output logic signed [13:0]                mvp_x,
  output logic signed [13:0]                mvp_y,
  output logic signed [13:0]                skip_x,
  output logic signed [13:0]                skip_y,
  output logic                              skip_zero,
  // The neighbours' entries (valid from ready): left A, above B, above-right C, above-left D. The motion search takes its candidate
  // vectors from them (phase 2c-2); their availability is the caller's.
  output logic                              nb_a_inter,
  output logic signed [13:0]                nb_a_mvx,
  output logic signed [13:0]                nb_a_mvy,
  output logic                              nb_b_inter,
  output logic signed [13:0]                nb_b_mvx,
  output logic signed [13:0]                nb_b_mvy,
  output logic                              nb_c_inter,
  output logic signed [13:0]                nb_c_mvx,
  output logic signed [13:0]                nb_c_mvy,
  output logic                              nb_d_inter,
  output logic signed [13:0]                nb_d_mvx,
  output logic signed [13:0]                nb_d_mvy,

  input  logic                              upd,
  input  logic                              upd_inter,
  input  logic signed [13:0]                upd_mvx,
  input  logic signed [13:0]                upd_mvy
);

  localparam int AW = $clog2(MV_LINE_KB * 1024 / 4);

  generate
    if ((MAX_MB_W + 1) > (1 << AW)) begin : g_small
      $fatal(1, "rtlnet_h264_mvctx: MV_LINE_KB=%0d too small for MAX_MB_W=%0d", MV_LINE_KB, MAX_MB_W);
    end
  endgenerate

  logic [2:0]            cnt;
  logic                  run;
  logic [6:0]            x_q;
  logic                  avt_q, avl_q, avtr_q;
  logic                  l_inter;
  logic signed [13:0]    l_mvx, l_mvy;
  logic                  b_inter, c_inter, d_inter;
  logic signed [13:0]    b_mvx, b_mvy, c_mvx, c_mvy, d_mvx, d_mvy;

  logic                  rd_en;
  logic [AW-1:0]         rd_addr;
  logic [31:0]           rd_data;
  logic                  wr_en;
  logic [AW-1:0]         wr_addr;
  logic [31:0]           wr_data;

  logic signed [13:0]    p_mvp_x, p_mvp_y, p_skip_x, p_skip_y;

  assign rd_en   = run && (cnt <= 3'd1);
  assign rd_addr = AW'(x_q) + AW'(cnt[0]);
  assign wr_en   = upd;
  assign wr_addr = AW'(x_q);
  assign wr_data = {upd_inter, 1'b0, upd_mvy, 2'b00, upd_mvx};

  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(32), .ADDR_W(AW), .READ_LATENCY(1)) u_line (
    .wr_clk(clk), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data)
  );

  assign skip_zero = (skip_x == 14'sd0) && (skip_y == 14'sd0);
  assign nb_a_inter = l_inter;  assign nb_a_mvx = l_mvx;  assign nb_a_mvy = l_mvy;
  assign nb_b_inter = b_inter;  assign nb_b_mvx = b_mvx;  assign nb_b_mvy = b_mvy;
  assign nb_c_inter = c_inter;  assign nb_c_mvx = c_mvx;  assign nb_c_mvy = c_mvy;
  assign nb_d_inter = d_inter;  assign nb_d_mvx = d_mvx;  assign nb_d_mvy = d_mvy;

  // The prediction in three stages with a register between them (stage 3c; the stages are the modules of rtlnet_h264_mvpred): neighbour
  // rules into the S1 registers (clock 3 after start), ordering and single-neighbour selection into the S2 registers (clock 4), median and
  // skip multiplexers into mvp and skip (clock 5). skip_zero is the compare of the registered skip vector (timing).
  logic signed [13:0] s1_ax, s1_ay, s1_bx, s1_by, s1_cx, s1_cy;
  logic               s1_one, s1_ra, s1_rb, s1_szf;
  logic signed [13:0] w_ax, w_ay, w_bx, w_by, w_cx, w_cy;
  logic               w_one, w_ra, w_rb, w_szf;
  rtlnet_h264_mvpred_s1 #(.MVW(14)) u_s1 (
    .av_a(avl_q),  .inter_a(l_inter), .mvx_a(l_mvx), .mvy_a(l_mvy),
    .av_b(avt_q),  .inter_b(b_inter), .mvx_b(b_mvx), .mvy_b(b_mvy),
    .av_c(avtr_q), .inter_c(c_inter), .mvx_c(c_mvx), .mvy_c(c_mvy),
    .av_d(avt_q && avl_q), .inter_d(d_inter), .mvx_d(d_mvx), .mvy_d(d_mvy),
    .ax(w_ax), .ay(w_ay), .bx(w_bx), .by(w_by), .cx(w_cx), .cy(w_cy), .one(w_one), .ra(w_ra), .rb(w_rb), .skip_zero_f(w_szf)
  );

  logic signed [13:0] w_xmn, w_xmx, w_xc, w_xone, w_ymn, w_ymx, w_yc, w_yone;
  logic               w_xlt, w_ylt;
  rtlnet_h264_mvpred_s2 #(.MVW(14)) u_s2x (.a(s1_ax), .b(s1_bx), .c(s1_cx), .ra(s1_ra), .rb(s1_rb), .mn(w_xmn), .mx(w_xmx), .c_o(w_xc), .lt(w_xlt), .one_v(w_xone));
  rtlnet_h264_mvpred_s2 #(.MVW(14)) u_s2y (.a(s1_ay), .b(s1_by), .c(s1_cy), .ra(s1_ra), .rb(s1_rb), .mn(w_ymn), .mx(w_ymx), .c_o(w_yc), .lt(w_ylt), .one_v(w_yone));

  logic signed [13:0] s2_xmn, s2_xmx, s2_xc, s2_xone, s2_ymn, s2_ymx, s2_yc, s2_yone;
  logic               s2_xlt, s2_ylt, s2_one, s2_szf;
  rtlnet_h264_mvpred_s3 #(.MVW(14)) u_s3x (.mn(s2_xmn), .mx(s2_xmx), .c(s2_xc), .lt(s2_xlt), .one_v(s2_xone), .one(s2_one), .skip_zero_f(s2_szf), .mvp(p_mvp_x), .skip(p_skip_x));
  rtlnet_h264_mvpred_s3 #(.MVW(14)) u_s3y (.mn(s2_ymn), .mx(s2_ymx), .c(s2_yc), .lt(s2_ylt), .one_v(s2_yone), .one(s2_one), .skip_zero_f(s2_szf), .mvp(p_mvp_y), .skip(p_skip_y));

  always_ff @(posedge clk) begin
    if (!resetn) begin
      cnt       <= '0;
      run       <= 1'b0;
      x_q       <= '0;
      avt_q     <= 1'b0;
      avl_q     <= 1'b0;
      avtr_q    <= 1'b0;
      l_inter   <= 1'b0;
      l_mvx     <= '0;
      l_mvy     <= '0;
      b_inter   <= 1'b0;
      c_inter   <= 1'b0;
      d_inter   <= 1'b0;
      b_mvx     <= '0;
      b_mvy     <= '0;
      c_mvx     <= '0;
      c_mvy     <= '0;
      d_mvx     <= '0;
      d_mvy     <= '0;
      ready     <= 1'b0;
      mvp_x     <= '0;
      mvp_y     <= '0;
      skip_x    <= '0;
      skip_y    <= '0;
    end else begin
      ready <= 1'b0;
      if (upd) begin
        l_inter <= upd_inter;
        l_mvx   <= upd_mvx;
        l_mvy   <= upd_mvy;
      end
      if (start) begin
        run    <= 1'b1;
        cnt    <= '0;
        x_q    <= mb_x;
        avt_q  <= av_top;
        avl_q  <= av_left;
        avtr_q <= av_tr;
        // The above-left entry is the above entry of the previous macroblock's own column.
        d_inter <= b_inter;
        d_mvx   <= b_mvx;
        d_mvy   <= b_mvy;
      end else if (run) begin
        cnt <= cnt + 3'd1;
        // The word of column x_q is on rd_data in clock 1, that of column x_q + 1 in clock 2.
        if (cnt == 3'd1) begin
          b_inter <= rd_data[31];
          b_mvy   <= signed'(rd_data[29:16]);
          b_mvx   <= signed'(rd_data[13:0]);
        end
        if (cnt == 3'd2) begin
          c_inter <= rd_data[31];
          c_mvy   <= signed'(rd_data[29:16]);
          c_mvx   <= signed'(rd_data[13:0]);
        end
        if (cnt == 3'd3) begin
          s1_ax <= w_ax; s1_ay <= w_ay; s1_bx <= w_bx; s1_by <= w_by; s1_cx <= w_cx; s1_cy <= w_cy;
          s1_one <= w_one; s1_ra <= w_ra; s1_rb <= w_rb; s1_szf <= w_szf;
        end
        if (cnt == 3'd4) begin
          s2_xmn <= w_xmn; s2_xmx <= w_xmx; s2_xc <= w_xc; s2_xone <= w_xone; s2_xlt <= w_xlt;
          s2_ymn <= w_ymn; s2_ymx <= w_ymx; s2_yc <= w_yc; s2_yone <= w_yone; s2_ylt <= w_ylt;
          s2_one <= s1_one; s2_szf <= s1_szf;
        end
        if (cnt == 3'd5) begin
          mvp_x     <= p_mvp_x;
          mvp_y     <= p_mvp_y;
          skip_x    <= p_skip_x;
          skip_y    <= p_skip_y;
        end
        if (cnt == 3'd6) begin
          ready <= 1'b1;
          run   <= 1'b0;
        end
      end
    end
  end

  // Unused bits of the line RAM word and of the read data.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = rd_data[30] | (|rd_data[15:14]);
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
