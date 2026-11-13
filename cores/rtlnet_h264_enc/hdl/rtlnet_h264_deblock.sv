// -----------------------------------------------------------------------------
// File: rtlnet_h264_deblock.sv
// Purpose: in-loop deblocking filter of one encoder engine (ITU-T Rec. H.264 clause 8.7, 4:2:0, 8 bit, frame macroblocks, filter inside each
//   slice: disable_deblocking_filter_idc 2) and the delayed write of the filtered reference picture.
// Overview:
//   * Data flow. Stage A rebuilds a macroblock into the rebuilt RAM (unfiltered; intra prediction keeps using unfiltered samples). The unit copies
//     the bank into a window RAM (two sets, current and previous macroblock of the row), loads the four luma and two chroma rows above the
//     macroblock from a line store, filters in place (vertical edges left to right, then horizontal edges top to bottom, luma then chroma, as
//     clause 8.7 orders them) and retires the previous macroblock when the current one has changed its right three columns: its tile goes to a
//     staging RAM and its last rows to the line store. The reference picture in memory is the filtered one.
//   * Window. 8 RAMs of 32 bit words, bank (row mod 4, column word parity), two sets, so that one clock reads the 8 words of a vertical edge
//     segment (4 rows, the words on both sides) and 4 or 8 words of a horizontal edge segment; 4 filter lines (rtlnet_h264_dbk_line) process a
//     segment of 4 lines in two register stages. A word holds 4 samples, sample 0 in bits 7:0. Rows -4..-1 (luma) and -2..-1 (chroma) hold the
//     rows above (from the line store); the column word -1 of a macroblock is column word 3 (luma) or 1 (chroma) of the previous set.
//   * Delayed write. The samples of a tile are final in three steps: rows 0..12 (chroma rows 0..6) and all columns after the macroblock to the
//     right has filtered its left edge, rows 13..15 (chroma row 7) after the macroblock below has filtered its top edge. A tile is therefore
//     written twice with bursts of 8 beats or more and byte strobes: the main bursts (16 luma beats with beats 13..15 masked, 8 chroma beats with
//     the row 7 bytes masked) after the right neighbour, and the late bursts (8 luma beats at tile + 128 with only beats 5..7 enabled, 8 chroma beats
//     with the row 7 bytes of beats 3 and 7 enabled) after the macroblock below, or from the line store at the end of the band.
//   * Boundary strength (8.7.2.1) from the intra flag (I_PCM included), the non-zero level mask per 4x4 luma block (an 8x8 transform macroblock:
//     per 8x8 block, delivered expanded), the quarter-sample motion vector difference (>= 4 in either component) and the macroblock edge flag;
//     qP of a macroblock is the slice QP (0 for I_PCM); the chroma qP is the table of clause 8.5.8 of that value; indexA and indexB of clause
//     8.7.2.2 with the slice offsets; the 8x8 transform macroblock filters its luma edges 0 and 2 only. A macroblock whose slice has no
//     macroblock above (first row of a slice) does not filter its top edge (idc 2).
//   * Timing per macroblock: copy 98 clocks, line load 30, filter about 80, late rows about 20, retire about 70 (the right-most macroblock of a
//     row retires twice), all behind stage A of the next macroblock.
// Language: SystemVerilog-2012.
// Revision: 11-12-2026
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_deblock #(
  parameter int    ADDR_W    = 32,
  parameter int    LINE_KB   = 16,
  parameter int    REC_AW    = 8,
  parameter string RAM_STYLE = "block",
  parameter string WIN_STYLE = "distributed"
)(
  input  logic              clk,
  input  logic              resetn,

  // Picture: pulse at the accepted start. cfg_en 0: nothing is filtered (the tiles are written unchanged).
  input  logic              pic_start,
  input  logic [7:0]        cfg_mb_w,
  input  logic [7:0]        cfg_band_rows,
  input  logic              cfg_en,
  input  logic signed [3:0] cfg_a,
  input  logic signed [3:0] cfg_b,
  input  logic [5:0]        cfg_qp,

  // Macroblock: mb_start pulses while mb_ready is high; the inputs are sampled then. mb_taken pulses when the rebuilt bank has been read.
  input  logic              mb_start,
  output logic              mb_ready,
  output logic              mb_taken,
  input  logic [7:0]        mb_x,
  input  logic              mb_avt,       // the macroblock above is in the same slice (idc 2: the top edge is filtered)
  input  logic              mb_intra,     // intra macroblock (I_PCM included)
  input  logic              mb_pcm,       // I_PCM: qP 0
  input  logic              mb_t8,        // 8x8 transform: luma edges 0 and 2 only
  input  logic [15:0]       mb_nz,        // non-zero level mask per 4x4 luma block, bit 4 * by + bx (expanded for an 8x8 transform macroblock)
  input  logic signed [13:0] mb_mvx,      // motion vector, quarter samples
  input  logic signed [13:0] mb_mvy,
  input  logic [ADDR_W-1:0] mb_ty,        // luma tile address of this macroblock
  input  logic [ADDR_W-1:0] mb_tc,        // chroma tile address
  input  logic [REC_AW-1:0] mb_base,      // rebuilt RAM word address of the bank

  // Rebuilt RAM read port (latency 1).
  output logic              ram_rd_en,
  output logic [REC_AW-1:0] ram_rd_addr,
  input  logic [31:0]       ram_rd_data,

  // Tile bursts to the write master.
  output logic              rc_valid,
  output logic [ADDR_W-1:0] rc_addr,
  output logic [3:0]        rc_len,
  input  logic              rc_pop,
  output logic              rc_w_valid,
  output logic [127:0]      rc_w_data,
  output logic [15:0]       rc_w_strb,
  input  logic              rc_w_pop,

  output logic              idle
);

  localparam int LF_AW   = $clog2(LINE_KB * 1024 / 16);
  localparam int STG_AW  = 7;
  localparam int LS_BASE = 64;

  // ---------------------------------------------------------------------------
  // Tables (clause 8.7.2.2, Tables 8-16 and 8-17) and the chroma QP mapping (Table 8-15)
  // ---------------------------------------------------------------------------
  function automatic logic [7:0] alpha_f(input logic [5:0] i);
    case (i)
      6'd16: return 8'd4;   6'd17: return 8'd4;   6'd18: return 8'd5;   6'd19: return 8'd6;   6'd20: return 8'd7;
      6'd21: return 8'd8;   6'd22: return 8'd9;   6'd23: return 8'd10;  6'd24: return 8'd12;  6'd25: return 8'd13;
      6'd26: return 8'd15;  6'd27: return 8'd17;  6'd28: return 8'd20;  6'd29: return 8'd22;  6'd30: return 8'd25;
      6'd31: return 8'd28;  6'd32: return 8'd32;  6'd33: return 8'd36;  6'd34: return 8'd40;  6'd35: return 8'd45;
      6'd36: return 8'd50;  6'd37: return 8'd56;  6'd38: return 8'd63;  6'd39: return 8'd71;  6'd40: return 8'd80;
      6'd41: return 8'd90;  6'd42: return 8'd101; 6'd43: return 8'd113; 6'd44: return 8'd127; 6'd45: return 8'd144;
      6'd46: return 8'd162; 6'd47: return 8'd182; 6'd48: return 8'd203; 6'd49: return 8'd226; 6'd50: return 8'd255;
      6'd51: return 8'd255;
      default: return 8'd0;
    endcase
  endfunction

  function automatic logic [4:0] beta_f(input logic [5:0] i);
    case (i)
      6'd16, 6'd17, 6'd18: return 5'd2;
      6'd19, 6'd20, 6'd21, 6'd22: return 5'd3;
      6'd23, 6'd24, 6'd25: return 5'd4;
      6'd26, 6'd27: return 5'd6;
      6'd28, 6'd29: return 5'd7;
      6'd30, 6'd31: return 5'd8;
      6'd32, 6'd33: return 5'd9;
      6'd34, 6'd35: return 5'd10;
      6'd36, 6'd37: return 5'd11;
      6'd38, 6'd39: return 5'd12;
      6'd40, 6'd41: return 5'd13;
      6'd42, 6'd43: return 5'd14;
      6'd44, 6'd45: return 5'd15;
      6'd46, 6'd47: return 5'd16;
      6'd48, 6'd49: return 5'd17;
      6'd50, 6'd51: return 5'd18;
      default: return 5'd0;
    endcase
  endfunction

  // tC0 for bS 1, 2, 3: {t3, t2, t1}.
  function automatic logic [14:0] tc_f(input logic [5:0] i);
    case (i)
      6'd17, 6'd18, 6'd19, 6'd20: return {5'd1, 5'd0, 5'd0};
      6'd21, 6'd22: return {5'd1, 5'd1, 5'd0};
      6'd23, 6'd24, 6'd25, 6'd26: return {5'd1, 5'd1, 5'd1};
      6'd27, 6'd28, 6'd29, 6'd30: return {5'd2, 5'd1, 5'd1};
      6'd31, 6'd32: return {5'd3, 5'd2, 5'd1};
      6'd33: return {5'd3, 5'd2, 5'd2};
      6'd34: return {5'd4, 5'd2, 5'd2};
      6'd35, 6'd36: return {5'd4, 5'd3, 5'd2};
      6'd37: return {5'd5, 5'd3, 5'd3};
      6'd38, 6'd39: return {5'd6, 5'd4, 5'd3};
      6'd40: return {5'd7, 5'd5, 5'd4};
      6'd41: return {5'd8, 5'd5, 5'd4};
      6'd42: return {5'd9, 5'd6, 5'd4};
      6'd43: return {5'd10, 5'd7, 5'd5};
      6'd44: return {5'd11, 5'd8, 5'd6};
      6'd45: return {5'd13, 5'd8, 5'd6};
      6'd46: return {5'd14, 5'd10, 5'd7};
      6'd47: return {5'd16, 5'd11, 5'd8};
      6'd48: return {5'd18, 5'd12, 5'd9};
      6'd49: return {5'd20, 5'd13, 5'd10};
      6'd50: return {5'd23, 5'd15, 5'd11};
      6'd51: return {5'd25, 5'd17, 5'd13};
      default: return 15'd0;
    endcase
  endfunction

  function automatic logic [5:0] qpc_f(input logic [5:0] q);
    case (q)
      6'd30: return 6'd29; 6'd31: return 6'd30; 6'd32: return 6'd31; 6'd33: return 6'd32; 6'd34: return 6'd32;
      6'd35: return 6'd33; 6'd36: return 6'd34; 6'd37: return 6'd34; 6'd38: return 6'd35; 6'd39: return 6'd35;
      6'd40: return 6'd36; 6'd41: return 6'd36; 6'd42: return 6'd37; 6'd43: return 6'd37; 6'd44: return 6'd37;
      6'd45: return 6'd38; 6'd46: return 6'd38; 6'd47: return 6'd38; 6'd48: return 6'd39; 6'd49: return 6'd39;
      6'd50: return 6'd39; 6'd51: return 6'd39;
      default: return q;
    endcase
  endfunction

  // index = Clip3(0, 51, qPav + 2 * offset_div2), qPav = (qPp + qPq + 1) >> 1
  function automatic logic [5:0] idx_f(input logic [5:0] qp_p, input logic [5:0] qp_q, input logic signed [3:0] off);
    int v;
    v = ((int'(qp_p) + int'(qp_q) + 1) >> 1) + 2 * int'(off);
    if (v < 0) v = 0;
    if (v > 51) v = 51;
    return 6'(v);
  endfunction

  function automatic logic [2:0] bs_f(input logic intra_p, input logic intra_q, input logic mbedge, input logic nz_p, input logic nz_q,
                                      input logic mvbig);
    if (intra_p || intra_q) return mbedge ? 3'd4 : 3'd3;
    if (nz_p || nz_q)       return 3'd2;
    if (mbedge && mvbig)    return 3'd1;
    return 3'd0;
  endfunction

  function automatic logic mv_big_f(input logic signed [13:0] ax, input logic signed [13:0] ay, input logic signed [13:0] bx,
                                    input logic signed [13:0] by);
    int dx, dy;
    dx = int'(ax) - int'(bx);
    dy = int'(ay) - int'(by);
    return ((dx >= 4) || (dx <= -4) || (dy >= 4) || (dy <= -4));
  endfunction

  // ---------------------------------------------------------------------------
  // Window addressing. A word is (set, plane, row, column word); plane 0 luma (rows -4..15, column words 0..3), 1 Cb, 2 Cr (rows -2..7,
  // column words 0..1). Bank = (row mod 4, column word mod 2).
  // ---------------------------------------------------------------------------
  function automatic logic [5:0] waddr(input logic set, input int pl, input int r, input int cw);
    logic [4:0] a;
    logic [2:0] rs;
    if (pl == 0) begin
      rs = 3'((r + 4) >> 2);
      a  = {1'b0, 3'(rs), 1'(cw >> 1)};
    end else begin
      rs = 3'((r + 2) >> 2);
      a  = {1'b1, (pl == 2) ? 1'b1 : 1'b0, 1'b0, 2'(rs)};
    end
    return {set, a};
  endfunction

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  localparam logic [3:0] U_IDLE  = 4'd0;
  localparam logic [3:0] U_CP    = 4'd1;
  localparam logic [3:0] U_CTX   = 4'd2;
  localparam logic [3:0] U_FLT   = 4'd3;
  localparam logic [3:0] U_LATE  = 4'd4;
  localparam logic [3:0] U_RET   = 4'd5;
  localparam logic [3:0] U_FIN   = 4'd6;
  localparam logic [3:0] U_FLUSH = 4'd7;

  logic [3:0] st;
  logic       active;
  logic       en_p;
  logic signed [3:0] a_p, b_p;
  logic [5:0] qp_p;
  logic [7:0] w_p;                   // picture width in macroblocks
  logic [7:0]  band_p;               // band height in macroblock rows, latched at the picture start
  (* use_dsp = "yes" *) logic [15:0] mb_prod;   // macroblocks of the band: w_p * band_p, first product register
  logic [15:0] mb_total;             // macroblocks of the band: second product register (valid 3 clocks after pic_start)
  logic [15:0] mb_cnt;
  logic [7:0] row_i;
  logic       cs;                    // current window set
  logic [8:0] cnt;

  // Current, previous and above macroblock.
  logic [7:0] c_x;
  logic       c_avt, c_intra, c_t8;
  logic [5:0] c_qp;
  logic [15:0] c_nz;
  logic signed [13:0] c_mvx, c_mvy;
  logic [ADDR_W-1:0] c_ty, c_tc;
  logic [REC_AW-1:0] c_base;
  logic       p_intra;
  logic [5:0] p_qp;
  logic [15:0] p_nz;
  logic signed [13:0] p_mvx, p_mvy;
  logic       a_intra;
  logic [5:0] a_qp;
  logic [3:0] a_nzb;
  logic signed [13:0] a_mvx, a_mvy;
  logic       left_ok, top_ok;
  logic       mvbig_l, mvbig_t;
  logic [5:0] cls_a [6];
  logic [5:0] cls_b [6];

  assign left_ok = (c_x != 8'd0);
  assign top_ok  = c_avt && (row_i != 8'd0);

  // ---------------------------------------------------------------------------
  // RAMs
  // ---------------------------------------------------------------------------
  logic        wb_we [8];
  logic [5:0]  wb_wa [8];
  logic [31:0] wb_wd [8];
  logic        wb_re [8];
  logic [5:0]  wb_ra [8];
  logic [31:0] wb_rd [8];

  genvar gb;
  generate
    for (gb = 0; gb < 8; gb++) begin : g_wb
      rtlnet_ram_core #(.RAM_STYLE(WIN_STYLE), .CLOCKING("COMMON"), .DATA_W(32), .ADDR_W(6), .READ_LATENCY(1)) u_wb (
        .wr_clk(clk), .wr_en(wb_we[gb]), .wr_addr(wb_wa[gb]), .wr_data(wb_wd[gb]),
        .rd_clk(clk), .rd_resetn(resetn), .rd_en(wb_re[gb]), .rd_addr(wb_ra[gb]), .rd_data(wb_rd[gb])
      );
    end
  endgenerate

  logic              lf_we;
  logic [LF_AW-1:0]  lf_wa;
  logic [127:0]      lf_wd;
  logic              lf_re;
  logic [LF_AW-1:0]  lf_ra;
  logic [127:0]      lf_rd;
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(LF_AW), .READ_LATENCY(1)) u_lf (
    .wr_clk(clk), .wr_en(lf_we), .wr_addr(lf_wa), .wr_data(lf_wd),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(lf_re), .rd_addr(lf_ra), .rd_data(lf_rd)
  );

  logic        in_we;
  logic [6:0]  in_wa;
  logic [39:0] in_wd;
  logic        in_re;
  logic [6:0]  in_ra;
  logic [39:0] in_rd;
  rtlnet_ram_core #(.RAM_STYLE("distributed"), .CLOCKING("COMMON"), .DATA_W(40), .ADDR_W(7), .READ_LATENCY(1)) u_info (
    .wr_clk(clk), .wr_en(in_we), .wr_addr(in_wa), .wr_data(in_wd),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(in_re), .rd_addr(in_ra), .rd_data(in_rd)
  );

  logic              sg_we;
  logic [STG_AW-1:0] sg_wa;
  logic [127:0]      sg_wd;
  logic              sg_re;
  logic [STG_AW-1:0] sg_ra;
  logic [127:0]      sg_rd;
  rtlnet_ram_core #(.RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(128), .ADDR_W(STG_AW), .READ_LATENCY(1)) u_stage (
    .wr_clk(clk), .wr_en(sg_we), .wr_addr(sg_wa), .wr_data(sg_wd),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(sg_re), .rd_addr(sg_ra), .rd_data(sg_rd)
  );

  // ---------------------------------------------------------------------------
  // Window reader (one 128 bit beat of a tile row: luma row, or two chroma rows) used by the late and the retire steps
  // ---------------------------------------------------------------------------
  localparam logic [2:0] R_IDLE = 3'd0;
  localparam logic [2:0] R_A    = 3'd1;
  localparam logic [2:0] R_B    = 3'd2;
  localparam logic [2:0] R_C    = 3'd3;
  localparam logic [2:0] R_OUT  = 3'd4;

  logic        rq_go;
  logic        rq_set;
  logic [1:0]  rq_pl;
  logic signed [5:0] rq_r;
  logic        rq_ch;               // chroma beat: rows rq_r and rq_r + 1
  logic        rq_rdy;
  logic [2:0]  rst_q;
  logic        rs_set;
  logic [1:0]  rs_pl;
  logic signed [5:0] rs_r;
  logic        rs_ch;
  logic [63:0] rs_lo;
  logic        rb_v;
  logic [127:0] rb_d;
  logic        rdr_re [8];
  logic [5:0]  rdr_ra [8];

  assign rq_rdy = (rst_q == R_IDLE) || (rst_q == R_OUT);

  always_comb begin
    for (int b = 0; b < 8; b++) begin
      rdr_re[b] = 1'b0;
      rdr_ra[b] = '0;
    end
    if (rst_q == R_A) begin
      if (rs_ch) begin
        // beat {row ra cw0, cw1, row ra + 1 cw0, cw1}
        for (int w = 0; w < 2; w++) begin
          rdr_re[(int'(rs_r) & 3) * 2 + w]       = 1'b1;
          rdr_ra[(int'(rs_r) & 3) * 2 + w]       = waddr(rs_set, int'(rs_pl), int'(rs_r), w);
          rdr_re[((int'(rs_r) + 1) & 3) * 2 + w] = 1'b1;
          rdr_ra[((int'(rs_r) + 1) & 3) * 2 + w] = waddr(rs_set, int'(rs_pl), int'(rs_r) + 1, w);
        end
      end else begin
        for (int w = 0; w < 2; w++) begin
          rdr_re[(int'(rs_r) & 3) * 2 + w] = 1'b1;
          rdr_ra[(int'(rs_r) & 3) * 2 + w] = waddr(rs_set, 0, int'(rs_r), w);
        end
      end
    end else if (rst_q == R_B) begin
      for (int w = 0; w < 2; w++) begin
        rdr_re[(int'(rs_r) & 3) * 2 + w] = 1'b1;
        rdr_ra[(int'(rs_r) & 3) * 2 + w] = waddr(rs_set, 0, int'(rs_r), 2 + w);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      rst_q <= R_IDLE;
      rb_v  <= 1'b0;
      rb_d  <= '0;
      rs_lo <= '0;
      rs_set <= 1'b0;
      rs_pl <= '0;
      rs_r  <= '0;
      rs_ch <= 1'b0;
    end else begin
      rb_v <= 1'b0;
      case (rst_q)
        R_IDLE, R_OUT: begin
          rst_q <= R_IDLE;
          if (rq_go) begin
            rs_set <= rq_set;
            rs_pl  <= rq_pl;
            rs_r   <= rq_r;
            rs_ch  <= rq_ch;
            rst_q  <= R_A;
          end
        end
        R_A: begin
          rst_q <= rs_ch ? R_C : R_B;
        end
        R_B: begin
          // data of the first read (cw0, cw1) arrives now
          rs_lo[31:0]  <= wb_rd[(int'(rs_r) & 3) * 2 + 0];
          rs_lo[63:32] <= wb_rd[(int'(rs_r) & 3) * 2 + 1];
          rst_q <= R_C;
        end
        R_C: begin
          if (rs_ch) begin
            rb_d <= {wb_rd[(((int'(rs_r) + 1) & 3) * 2) + 1], wb_rd[((int'(rs_r) + 1) & 3) * 2],
                     wb_rd[(int'(rs_r) & 3) * 2 + 1], wb_rd[(int'(rs_r) & 3) * 2]};
          end else begin
            rb_d <= {wb_rd[(int'(rs_r) & 3) * 2 + 1], wb_rd[(int'(rs_r) & 3) * 2], rs_lo};
          end
          rb_v  <= 1'b1;
          rst_q <= R_OUT;
        end
        default: rst_q <= R_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Filter sequencer and the segment pipeline
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic       v;
    logic       dir;     // 0 vertical edges, 1 horizontal edges
    logic [1:0] pl;
    logic [1:0] e;
    logic [1:0] g;
    logic       ph;
  } seg_t;

  localparam logic [2:0] F_V0 = 3'd0;
  localparam logic [2:0] F_V1 = 3'd1;
  localparam logic [2:0] F_D1 = 3'd2;
  localparam logic [2:0] F_H0 = 3'd3;
  localparam logic [2:0] F_H1 = 3'd4;
  localparam logic [2:0] F_D2 = 3'd5;
  localparam logic [2:0] F_G  = 3'd6;
  localparam logic [2:0] F_END = 3'd7;

  logic [2:0] fph;
  logic [5:0] fc;
  logic       flt_run;
  seg_t       d0, d1, d2, d3, d4;

  // Slot decode.
  always_comb begin
    d0 = '0;
    case (fph)
      F_V0: begin
        d0.dir = 1'b0; d0.pl = 2'd0; d0.e = fc[3:2]; d0.g = fc[1:0]; d0.ph = 1'b0;
        d0.v = (fc[3:2] == 2'd0) ? left_ok : (c_t8 ? (fc[3:2] == 2'd2) : 1'b1);
      end
      F_V1: begin
        d0.dir = 1'b0; d0.pl = 2'd1 + {1'b0, fc[0]}; d0.e = {1'b0, fc[2]}; d0.g = {1'b0, fc[1]}; d0.ph = 1'b0;
        d0.v = fc[2] ? 1'b1 : left_ok;
      end
      F_H0: begin
        d0.dir = 1'b1; d0.pl = 2'd0; d0.e = fc[4:3]; d0.g = fc[2:1]; d0.ph = fc[0];
        d0.v = (fc[4:3] == 2'd0) ? top_ok : (c_t8 ? (fc[4:3] == 2'd2) : 1'b1);
      end
      F_H1: begin
        d0.dir = 1'b1; d0.pl = 2'd1 + {1'b0, fc[0]}; d0.e = {1'b0, fc[2]}; d0.g = {1'b0, fc[1]}; d0.ph = 1'b0;
        d0.v = fc[2] ? 1'b1 : top_ok;
      end
      default: d0 = '0;
    endcase
    if (!flt_run) d0.v = 1'b0;
  end

  // Read request of the filter (cycle of d0): bank addresses.
  logic        fr_re [8];
  logic [5:0]  fr_ra [8];
  logic        d0_chr;
  assign d0_chr = (d0.pl != 2'd0);

  always_comb begin
    int cwq, cwp, rr0, y0, kp, rowx;
    logic setp, setq;
    for (int b = 0; b < 8; b++) begin
      fr_re[b] = 1'b0;
      fr_ra[b] = '0;
    end
    cwq = 0; cwp = 0; rr0 = 0; y0 = 0; kp = 0; rowx = 0; setp = cs; setq = cs;
    if (d0.v && !d0.dir) begin
      cwq  = int'(d0.e);
      cwp  = (d0.e == 2'd0) ? (d0_chr ? 1 : 3) : (int'(d0.e) - 1);
      setp = (d0.e == 2'd0) ? ~cs : cs;
      rr0  = 4 * int'(d0.g);
      for (int i = 0; i < 4; i++) begin
        fr_re[i * 2 + (cwq & 1)] = 1'b1;
        fr_ra[i * 2 + (cwq & 1)] = waddr(setq, int'(d0.pl), rr0 + i, cwq);
        fr_re[i * 2 + (cwp & 1)] = 1'b1;
        fr_ra[i * 2 + (cwp & 1)] = waddr(setp, int'(d0.pl), rr0 + i, cwp);
      end
    end else if (d0.v && d0.dir) begin
      kp = int'(d0.g[0]);
      y0 = 4 * int'(d0.e);
      for (int i = 0; i < 4; i++) begin
        if (!d0_chr) begin
          rowx = d0.ph ? (y0 + i) : (y0 - 4 + i);
          fr_re[i * 2 + kp] = 1'b1;
          fr_ra[i * 2 + kp] = waddr(cs, 0, rowx, int'(d0.g));
        end else begin
          rowx = (i >= 2) ? (y0 - 4 + i) : (y0 + i);
          fr_re[i * 2 + kp] = 1'b1;
          fr_ra[i * 2 + kp] = waddr(cs, int'(d0.pl), rowx, int'(d0.g));
        end
      end
    end
  end

  // Parameters of the segment (cycle of d0), registered into d1's companions.
  logic [2:0]  bs_lo_c, bs_hi_c;
  logic [2:0]  cls_c;
  logic [5:0]  ia_c, ib_c;
  logic [7:0]  al_c;
  logic [4:0]  be_c;
  logic [14:0] tr_c;

  always_comb begin
    logic nzp, nzq, ip, mbe, big;
    int qbx, qby;
    bs_lo_c = 3'd0;
    bs_hi_c = 3'd0;
    cls_c   = 3'd0;
    for (int h = 0; h < 2; h++) begin
      nzp = 1'b0; nzq = 1'b0; ip = c_intra; mbe = 1'b0; big = 1'b0; qbx = 0; qby = 0;
      if (!d0.dir) begin
        if (!d0_chr) begin
          qbx = int'(d0.e);        qby = int'(d0.g);
          mbe = (d0.e == 2'd0);
          if (d0.e == 2'd0) begin nzp = p_nz[4 * qby + 3]; ip = p_intra; big = mvbig_l; end
          else              begin nzp = c_nz[4 * qby + qbx - 1]; end
        end else begin
          qbx = 2 * int'(d0.e);    qby = 2 * int'(d0.g) + h;
          mbe = (d0.e == 2'd0);
          if (d0.e == 2'd0) begin nzp = p_nz[4 * qby + 3]; ip = p_intra; big = mvbig_l; end
          else              begin nzp = c_nz[4 * qby + 1]; end
        end
      end else begin
        if (!d0_chr) begin
          qbx = int'(d0.g);        qby = int'(d0.e);
          mbe = (d0.e == 2'd0);
          if (d0.e == 2'd0) begin nzp = a_nzb[qbx]; ip = a_intra; big = mvbig_t; end
          else              begin nzp = c_nz[4 * (qby - 1) + qbx]; end
        end else begin
          qbx = 2 * int'(d0.g) + h; qby = 2 * int'(d0.e);
          mbe = (d0.e == 2'd0);
          if (d0.e == 2'd0) begin nzp = a_nzb[qbx]; ip = a_intra; big = mvbig_t; end
          else              begin nzp = c_nz[4 + qbx]; end
        end
      end
      nzq = c_nz[4 * qby + qbx];
      if (h == 0) bs_lo_c = bs_f(ip, c_intra, mbe, nzp, nzq, big);
      else        bs_hi_c = bs_f(ip, c_intra, mbe, nzp, nzq, big);
    end
    cls_c = {d0_chr, (d0.e == 2'd0) ? (d0.dir ? 2'd1 : 2'd0) : 2'd2};
    ia_c = cls_a[cls_c[2] ? (3 + int'(cls_c[1:0])) : int'(cls_c[1:0])];
    ib_c = cls_b[cls_c[2] ? (3 + int'(cls_c[1:0])) : int'(cls_c[1:0])];
    al_c = alpha_f(ia_c);
    be_c = beta_f(ib_c);
    tr_c = tc_f(ia_c);
  end

  logic [2:0]  d1_bsl, d1_bsh;
  logic [7:0]  d1_al;
  logic [4:0]  d1_be;
  logic [14:0] d1_tr;

  // Segment pipeline registers.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      d1 <= '0; d2 <= '0; d3 <= '0; d4 <= '0;
    end else begin
      d1 <= d0;
      d2 <= d1;
      d3 <= d2;
      d4 <= d3;
    end
    d1_bsl <= bs_lo_c;
    d1_bsh <= bs_hi_c;
    d1_al  <= al_c;
    d1_be  <= be_c;
    d1_tr  <= tr_c;
  end

  // Data of the read (cycle of d1): word selection per bank parity.
  logic [31:0] pw [4];
  logic [31:0] qw [4];
  logic [31:0] preg [4];
  logic        d1_chr;
  int          d1_cwp_par, d1_cwq_par, d1_kp;
  assign d1_chr = (d1.pl != 2'd0);

  always_comb begin
    d1_cwq_par = int'(d1.e[0]);
    d1_cwp_par = (d1.e == 2'd0) ? (d1_chr ? 1 : 1) : (int'(d1.e[0]) ^ 1);
    d1_kp      = int'(d1.g[0]);
    for (int j = 0; j < 4; j++) begin
      pw[j] = '0;
      qw[j] = '0;
    end
    if (!d1.dir) begin
      for (int j = 0; j < 4; j++) begin
        pw[j] = wb_rd[j * 2 + d1_cwp_par];
        qw[j] = wb_rd[j * 2 + d1_cwq_par];
      end
    end else if (!d1_chr) begin
      for (int m = 0; m < 4; m++) begin
        pw[m] = preg[m];
        qw[m] = wb_rd[m * 2 + d1_kp];
      end
    end else begin
      pw[0] = wb_rd[3 * 2 + d1_kp];
      pw[1] = wb_rd[2 * 2 + d1_kp];
      qw[0] = wb_rd[0 * 2 + d1_kp];
      qw[1] = wb_rd[1 * 2 + d1_kp];
    end
  end

  always_ff @(posedge clk) begin
    if (d1.v && d1.dir && !d1_chr && !d1.ph) begin
      for (int m = 0; m < 4; m++) preg[m] <= wb_rd[(3 - m) * 2 + d1_kp];
    end
  end

  // Four lines.
  logic        ln_v [4];
  logic [31:0] ln_p [4];
  logic [31:0] ln_q [4];
  logic [31:0] lo_p [4];
  logic [31:0] lo_q [4];
  logic        lo_v [4];   // the line outputs are consumed by the write stage in fixed clocks (d3, d4); the valid flags are not needed
  logic [2:0]  ln_bs [4];
  logic [4:0]  ln_tc [4];

  always_comb begin
    for (int j = 0; j < 4; j++) begin
      ln_bs[j] = (j < 2) ? d1_bsl : d1_bsh;
      case (ln_bs[j])
        3'd1:    ln_tc[j] = d1_tr[4:0];
        3'd2:    ln_tc[j] = d1_tr[9:5];
        3'd3:    ln_tc[j] = d1_tr[14:10];
        default: ln_tc[j] = 5'd0;
      endcase
      ln_v[j] = d1.v && !(d1.dir && !d1_chr && !d1.ph);
      if (!d1.dir) begin
        // vertical edge: line j = row j, p[m] = lane 3 - m of the p word, q[m] = lane m of the q word
        ln_p[j] = {pw[j][7:0], pw[j][15:8], pw[j][23:16], pw[j][31:24]};
        ln_q[j] = qw[j];
      end else begin
        // horizontal edge: line j = column j, p[m] = lane j of the word of row y0 - 1 - m, q[m] = lane j of the word of row y0 + m
        ln_p[j] = {pw[3][8*j +: 8], pw[2][8*j +: 8], pw[1][8*j +: 8], pw[0][8*j +: 8]};
        ln_q[j] = {qw[3][8*j +: 8], qw[2][8*j +: 8], qw[1][8*j +: 8], qw[0][8*j +: 8]};
      end
    end
  end

  genvar gl;
  generate
    for (gl = 0; gl < 4; gl++) begin : g_line
      rtlnet_h264_dbk_line u_line (
        .clk(clk), .resetn(resetn), .v_i(ln_v[gl]), .chroma(d1_chr), .bs(ln_bs[gl]), .alpha(d1_al), .beta(d1_be), .tc0(ln_tc[gl]),
        .p_i(ln_p[gl]), .q_i(ln_q[gl]), .v_o(lo_v[gl]), .p_o(lo_p[gl]), .q_o(lo_q[gl])
      );
    end
  endgenerate

  // Write stage: d3 (all words of a vertical segment, the q words of a luma horizontal segment, p0 and q0 of a chroma horizontal segment),
  // d4 (the p words of a luma horizontal segment, the line outputs are still held).
  logic        fw_we [8];
  logic [5:0]  fw_wa [8];
  logic [31:0] fw_wd [8];
  logic [31:0] pwo [4];
  logic [31:0] qwo [4];

  always_comb begin
    int cwq, cwp, y0, kp;
    logic setp, setq;
    for (int b = 0; b < 8; b++) begin
      fw_we[b] = 1'b0;
      fw_wa[b] = '0;
      fw_wd[b] = '0;
    end
    for (int j = 0; j < 4; j++) begin
      // vertical: line j is row j
      // horizontal: word m of row y0 - 1 - m (p) or y0 + m (q), lane j = line j
      pwo[j] = '0;
      qwo[j] = '0;
    end
    cwq = 0; cwp = 0; y0 = 0; kp = 0; setp = cs; setq = cs;
    // d3 is the segment whose outputs are in the line registers; d4 the one a clock older (valid for the p words of a luma horizontal segment)
    if (d3.v && !d3.dir) begin
      cwq  = int'(d3.e);
      cwp  = (d3.e == 2'd0) ? ((d3.pl != 2'd0) ? 1 : 3) : (int'(d3.e) - 1);
      setp = (d3.e == 2'd0) ? ~cs : cs;
      for (int j = 0; j < 4; j++) begin
        pwo[j] = {lo_p[j][7:0], lo_p[j][15:8], lo_p[j][23:16], lo_p[j][31:24]};
        qwo[j] = lo_q[j];
        fw_we[j * 2 + (cwp & 1)] = 1'b1;
        fw_wa[j * 2 + (cwp & 1)] = waddr(setp, int'(d3.pl), 4 * int'(d3.g) + j, cwp);
        fw_wd[j * 2 + (cwp & 1)] = pwo[j];
        fw_we[j * 2 + (cwq & 1)] = 1'b1;
        fw_wa[j * 2 + (cwq & 1)] = waddr(setq, int'(d3.pl), 4 * int'(d3.g) + j, cwq);
        fw_wd[j * 2 + (cwq & 1)] = qwo[j];
      end
    end else if (d3.v && d3.dir && (d3.pl == 2'd0) && d3.ph) begin
      // q words of a luma horizontal segment
      kp = int'(d3.g[0]);
      y0 = 4 * int'(d3.e);
      for (int m = 0; m < 4; m++) begin
        for (int j = 0; j < 4; j++) qwo[m][8*j +: 8] = lo_q[j][8*m +: 8];
        fw_we[m * 2 + kp] = 1'b1;
        fw_wa[m * 2 + kp] = waddr(cs, 0, y0 + m, int'(d3.g));
        fw_wd[m * 2 + kp] = qwo[m];
      end
    end else if (d3.v && d3.dir && (d3.pl != 2'd0)) begin
      // chroma horizontal: p0 (row y0 - 1, bank 3) and q0 (row y0, bank 0)
      kp = int'(d3.g[0]);
      y0 = 4 * int'(d3.e);
      for (int j = 0; j < 4; j++) begin
        pwo[0][8*j +: 8] = lo_p[j][7:0];
        qwo[0][8*j +: 8] = lo_q[j][7:0];
        pwo[1][8*j +: 8] = lo_p[j][15:8];
        qwo[1][8*j +: 8] = lo_q[j][15:8];
      end
      fw_we[3 * 2 + kp] = 1'b1;
      fw_wa[3 * 2 + kp] = waddr(cs, int'(d3.pl), y0 - 1, int'(d3.g));
      fw_wd[3 * 2 + kp] = pwo[0];
      fw_we[0 * 2 + kp] = 1'b1;
      fw_wa[0 * 2 + kp] = waddr(cs, int'(d3.pl), y0, int'(d3.g));
      fw_wd[0 * 2 + kp] = qwo[0];
    end else if (d4.v && d4.dir && (d4.pl == 2'd0) && d4.ph) begin
      kp = int'(d4.g[0]);
      y0 = 4 * int'(d4.e);
      for (int m = 0; m < 4; m++) begin
        for (int j = 0; j < 4; j++) pwo[m][8*j +: 8] = lo_p[j][8*m +: 8];
        fw_we[(3 - m) * 2 + kp] = 1'b1;
        fw_wa[(3 - m) * 2 + kp] = waddr(cs, 0, y0 - 1 - m, int'(d4.g));
        fw_wd[(3 - m) * 2 + kp] = pwo[m];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Job queue and burst writer
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic              kind;      // 0 main tile, 1 late rows
    logic              set;
    logic [ADDR_W-1:0] ty;
    logic [ADDR_W-1:0] tc;
  } job_t;

  job_t        jq [4];
  logic [2:0]  jq_n;
  logic [1:0]  jq_wp, jq_rp;
  logic        jq_push;
  job_t        jq_din;
  logic        ms_busy [2];
  logic        ls_busy [2];
  logic        ms_w, ls_w;

  localparam logic [1:0] W_IDLE = 2'd0;
  localparam logic [1:0] W_L    = 2'd1;
  localparam logic [1:0] W_C    = 2'd2;
  logic [1:0]  wst;
  job_t        wj;
  logic [5:0]  w_issued;
  logic [5:0]  w_popped;
  logic        w_v;
  logic        w_req;
  logic        w_more;
  logic        w_last_pop;
  logic [5:0]  w_nbeats;
  logic [STG_AW-1:0] w_addr;

  assign w_nbeats = (wst == W_L && wj.kind == 1'b0) ? 6'd16 : 6'd8;
  assign w_more   = (w_issued < w_nbeats);
  assign w_last_pop = rc_w_pop && (w_popped == (w_nbeats - 6'd1));

  always_comb begin
    w_addr = '0;
    if (wj.kind == 1'b0) begin
      if (wst == W_L) begin
        if (w_issued <= 6'd12) w_addr = {1'b0, wj.set, 5'(w_issued)};
      end else begin
        w_addr = {1'b0, wj.set, 5'(6'd13 + w_issued)};
      end
    end else begin
      if (wst == W_L) begin
        if (w_issued >= 6'd5) w_addr = 7'(LS_BASE) + {3'd0, wj.set, 3'd0} + 7'(w_issued - 6'd5);
      end else begin
        if (w_issued == 6'd3)      w_addr = 7'(LS_BASE) + {3'd0, wj.set, 3'd0} + 7'd3;
        else if (w_issued == 6'd7) w_addr = 7'(LS_BASE) + {3'd0, wj.set, 3'd0} + 7'd4;
      end
    end
  end

  assign sg_re = ((wst == W_L) || (wst == W_C)) && w_more && (!w_v || rc_w_pop);
  assign sg_ra = w_addr;
  assign rc_valid   = w_req && ((wst == W_L) || (wst == W_C));
  assign rc_addr    = (wst == W_C) ? wj.tc : ((wj.kind == 1'b0) ? wj.ty : (wj.ty + ADDR_W'(128)));
  assign rc_len     = 4'(w_nbeats - 6'd1);
  assign rc_w_valid = w_v;
  assign rc_w_data  = sg_rd;

  always_comb begin
    rc_w_strb = 16'h0000;
    if (wj.kind == 1'b0) begin
      if (wst == W_L) rc_w_strb = (w_popped <= 6'd12) ? 16'hFFFF : 16'h0000;
      else            rc_w_strb = ((w_popped == 6'd3) || (w_popped == 6'd7)) ? 16'h00FF : 16'hFFFF;
    end else begin
      if (wst == W_L) rc_w_strb = (w_popped >= 6'd5) ? 16'hFFFF : 16'h0000;
      else            rc_w_strb = ((w_popped == 6'd3) || (w_popped == 6'd7)) ? 16'hFF00 : 16'h0000;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      wst      <= W_IDLE;
      wj       <= '0;
      w_issued <= '0;
      w_popped <= '0;
      w_v      <= 1'b0;
      w_req    <= 1'b0;
      jq_n     <= '0;
      jq_wp    <= '0;
      jq_rp    <= '0;
      ms_busy[0] <= 1'b0; ms_busy[1] <= 1'b0;
      ls_busy[0] <= 1'b0; ls_busy[1] <= 1'b0;
      for (int i = 0; i < 4; i++) jq[i] <= '0;
    end else begin
      if (jq_push) begin
        jq[jq_wp] <= jq_din;
        jq_wp     <= jq_wp + 2'd1;
        if (jq_din.kind) ls_busy[jq_din.set] <= 1'b1; else ms_busy[jq_din.set] <= 1'b1;
      end
      case (wst)
        W_IDLE: begin
          if (jq_n != 3'd0) begin
            wj       <= jq[jq_rp];
            jq_rp    <= jq_rp + 2'd1;
            wst      <= W_L;
            w_req    <= 1'b1;
            w_issued <= '0;
            w_popped <= '0;
            w_v      <= 1'b0;
          end
        end
        default: begin
          if (rc_pop) w_req <= 1'b0;
          if (sg_re) w_issued <= w_issued + 6'd1;
          if (sg_re)         w_v <= 1'b1;
          else if (rc_w_pop) w_v <= 1'b0;
          if (rc_w_pop) w_popped <= w_popped + 6'd1;
          if (w_last_pop) begin
            w_popped <= '0;
            w_issued <= '0;
            if (wst == W_L) begin
              wst   <= W_C;
              w_req <= 1'b1;
            end else begin
              wst <= W_IDLE;
              if (wj.kind) ls_busy[wj.set] <= 1'b0; else ms_busy[wj.set] <= 1'b0;
            end
          end
        end
      endcase
      jq_n <= jq_n + {2'b00, jq_push} - {2'b00, (wst == W_IDLE) && (jq_n != 3'd0)};
    end
  end

  // ---------------------------------------------------------------------------
  // Main sequencer
  // ---------------------------------------------------------------------------
  logic        cp_v;
  logic [6:0]  cp_k;
  logic [3:0]  ctx_p;      // phase within a line-store beat
  logic [2:0]  ctx_s;      // beat 0..5
  logic [4:0]  n_beat;     // beat counter of the late / retire steps
  logic        ret_cur;    // retire the current set (end of row) instead of the previous
  logic [7:0]  fl_x;
  logic [2:0]  fl_c;
  logic [ADDR_W-1:0] fl_ty, fl_tc;
  logic        rb_wait;

  // Write port of the window: sources in time (copy, line load, filter).
  logic        mw_we [8];
  logic [5:0]  mw_wa [8];
  logic [31:0] mw_wd [8];

  always_comb begin
    for (int b = 0; b < 8; b++) begin
      mw_we[b] = 1'b0;
      mw_wa[b] = '0;
      mw_wd[b] = '0;
    end
    if (cp_v) begin
      // word cp_k of the rebuilt bank
      if (cp_k < 7'd64) begin
        mw_we[(int'(cp_k[5:2]) & 3) * 2 + int'(cp_k[0])] = 1'b1;
        mw_wa[(int'(cp_k[5:2]) & 3) * 2 + int'(cp_k[0])] = waddr(cs, 0, int'(cp_k[5:2]), int'(cp_k[1:0]));
        mw_wd[(int'(cp_k[5:2]) & 3) * 2 + int'(cp_k[0])] = ram_rd_data;
      end else begin
        // chroma: word w = cp_k - 64 (Cb 0..15, Cr 16..31): row w >> 1 (within the plane), column word w & 1
        mw_we[(int'(cp_k[3:1]) & 3) * 2 + int'(cp_k[0])] = 1'b1;
        mw_wa[(int'(cp_k[3:1]) & 3) * 2 + int'(cp_k[0])] = waddr(cs, cp_k[4] ? 2 : 1, int'(cp_k[3:1]), int'(cp_k[0]));
        mw_wd[(int'(cp_k[3:1]) & 3) * 2 + int'(cp_k[0])] = ram_rd_data;
      end
    end else if (st == U_CTX && (ctx_p >= 4'd2)) begin
      automatic int w = int'(ctx_p) - 2;
      automatic int rr = (ctx_s < 3'd4) ? (int'(ctx_s) - 4) : ((w >= 2) ? -1 : -2);
      automatic int cw = (ctx_s < 3'd4) ? w : (w & 1);
      automatic int pl = (ctx_s < 3'd4) ? 0 : ((ctx_s == 3'd4) ? 1 : 2);
      mw_we[(rr & 3) * 2 + (cw & 1)] = 1'b1;
      mw_wa[(rr & 3) * 2 + (cw & 1)] = waddr(cs, pl, rr, cw);
      mw_wd[(rr & 3) * 2 + (cw & 1)] = lf_rd[32 * w +: 32];
    end
  end

  always_comb begin
    for (int b = 0; b < 8; b++) begin
      wb_we[b] = mw_we[b] | fw_we[b];
      wb_wa[b] = mw_we[b] ? mw_wa[b] : fw_wa[b];
      wb_wd[b] = mw_we[b] ? mw_wd[b] : fw_wd[b];
      wb_re[b] = fr_re[b] | rdr_re[b];
      wb_ra[b] = fr_re[b] ? fr_ra[b] : rdr_ra[b];
    end
  end

  // Class parameters (computed from the registers, registered at the end of the copy).
  logic [5:0] cls_a_c [6];
  logic [5:0] cls_b_c [6];
  always_comb begin
    cls_a_c[0] = idx_f(p_qp, c_qp, a_p);
    cls_b_c[0] = idx_f(p_qp, c_qp, b_p);
    cls_a_c[1] = idx_f(a_qp, c_qp, a_p);
    cls_b_c[1] = idx_f(a_qp, c_qp, b_p);
    cls_a_c[2] = idx_f(c_qp, c_qp, a_p);
    cls_b_c[2] = idx_f(c_qp, c_qp, b_p);
    cls_a_c[3] = idx_f(qpc_f(p_qp), qpc_f(c_qp), a_p);
    cls_b_c[3] = idx_f(qpc_f(p_qp), qpc_f(c_qp), b_p);
    cls_a_c[4] = idx_f(qpc_f(a_qp), qpc_f(c_qp), a_p);
    cls_b_c[4] = idx_f(qpc_f(a_qp), qpc_f(c_qp), b_p);
    cls_a_c[5] = idx_f(qpc_f(c_qp), qpc_f(c_qp), a_p);
    cls_b_c[5] = idx_f(qpc_f(c_qp), qpc_f(c_qp), b_p);
  end

  // Bits not used: the unused bit of the information word, the valid flags of the lines, the top bit of the retire column.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = &{1'b0, in_rd[0], lo_v[0], lo_v[1], lo_v[2], lo_v[3], ret_x[7]};
  /* verilator lint_on UNUSEDSIGNAL */

  assign mb_ready = active && (st == U_IDLE);
  assign idle     = !active && !jq_push && (wst == W_IDLE) && (jq_n == 3'd0);

  logic [7:0] ret_x;
  logic [ADDR_W-1:0] ret_ty, ret_tc;
  logic ret_set;
  assign ret_x   = ret_cur ? c_x : (c_x - 8'd1);
  assign ret_ty  = ret_cur ? c_ty : (c_ty - ADDR_W'(256));
  assign ret_tc  = ret_cur ? c_tc : (c_tc - ADDR_W'(128));
  assign ret_set = ret_cur ? cs : ~cs;

  assign ram_rd_en   = (st == U_CP) && (cnt <= 9'd95);
  assign ram_rd_addr = c_base + REC_AW'(cnt);

  // The product w_p * band_p (8 x 8 bits) is used once per picture, at the end of the first macroblock, at least 96 clocks after pic_start (the
  // line-store copy of the first macroblock). Two product registers let the synthesis map it into one DSP block with its input and product
  // registers; there is no reset on them (the value is a pure function of w_p and band_p, which have one).
  always_ff @(posedge clk) begin
    mb_prod     <= 16'(w_p) * 16'(band_p);
    mb_total    <= mb_prod;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      st       <= U_IDLE;
      active   <= 1'b0;
      en_p     <= 1'b0;
      a_p      <= '0;
      b_p      <= '0;
      qp_p     <= '0;
      w_p      <= '0;
      band_p   <= '0;
      mb_cnt   <= '0;
      row_i    <= '0;
      cs       <= 1'b0;
      cnt      <= '0;
      mb_taken <= 1'b0;
      c_x <= '0; c_avt <= 1'b0; c_intra <= 1'b0; c_t8 <= 1'b0; c_qp <= '0; c_nz <= '0; c_mvx <= '0; c_mvy <= '0;
      c_ty <= '0; c_tc <= '0; c_base <= '0;
      p_intra <= 1'b0; p_qp <= '0; p_nz <= '0; p_mvx <= '0; p_mvy <= '0;
      a_intra <= 1'b0; a_qp <= '0; a_nzb <= '0; a_mvx <= '0; a_mvy <= '0;
      mvbig_l <= 1'b0; mvbig_t <= 1'b0;
      for (int i = 0; i < 6; i++) begin cls_a[i] <= '0; cls_b[i] <= '0; end
      cp_v <= 1'b0; cp_k <= '0;
      ctx_p <= '0; ctx_s <= '0; n_beat <= '0;
      ret_cur <= 1'b0;
      fl_x <= '0; fl_c <= '0; fl_ty <= '0; fl_tc <= '0;
      fph <= F_END; fc <= '0; flt_run <= 1'b0;
      ms_w <= 1'b0; ls_w <= 1'b0;
      rq_go <= 1'b0; rq_set <= 1'b0; rq_pl <= '0; rq_r <= '0; rq_ch <= 1'b0;
      jq_push <= 1'b0; jq_din <= '0;
      lf_we <= 1'b0; lf_wa <= '0; lf_wd <= '0; lf_re <= 1'b0; lf_ra <= '0;
      in_we <= 1'b0; in_wa <= '0; in_wd <= '0; in_re <= 1'b0; in_ra <= '0;
      sg_we <= 1'b0; sg_wa <= '0; sg_wd <= '0;
      rb_wait <= 1'b0;
    end else begin
      mb_taken <= 1'b0;
      jq_push  <= 1'b0;
      rq_go    <= 1'b0;
      lf_we    <= 1'b0;
      lf_re    <= 1'b0;
      in_we    <= 1'b0;
      in_re    <= 1'b0;
      sg_we    <= 1'b0;
      cp_v     <= 1'b0;

      if (pic_start) begin
        active   <= 1'b1;
        en_p     <= cfg_en;
        a_p      <= cfg_a;
        b_p      <= cfg_b;
        qp_p     <= cfg_qp;
        w_p      <= cfg_mb_w;
        band_p   <= cfg_band_rows;
        mb_cnt   <= '0;
        row_i    <= '0;
        cs       <= 1'b0;
        ms_w     <= 1'b0;
        ls_w     <= 1'b0;
        st       <= U_IDLE;
      end

      case (st)
        U_IDLE: begin
          if (mb_start && mb_ready) begin
            c_x     <= mb_x;
            c_avt   <= mb_avt;
            c_intra <= mb_intra;
            c_t8    <= mb_t8;
            c_qp    <= mb_pcm ? 6'd0 : qp_p;
            c_nz    <= mb_nz;
            c_mvx   <= mb_mvx;
            c_mvy   <= mb_mvy;
            c_ty    <= mb_ty;
            c_tc    <= mb_tc;
            c_base  <= mb_base;
            cnt     <= '0;
            st      <= U_CP;
          end
        end

        U_CP: begin
          // The information of the macroblock above is read in the first clock; the rebuilt bank word cnt is read in clock cnt and
          // written into the window in clock cnt + 1.
          in_re <= (cnt == 9'd0);
          in_ra <= c_x[6:0];
          cp_v  <= (cnt <= 9'd95);
          cp_k  <= 7'(cnt);
          cnt   <= cnt + 9'd1;
          if (cnt == 9'd2) begin
            a_intra <= in_rd[39];
            a_qp    <= in_rd[38:33];
            a_nzb   <= in_rd[32:29];
            a_mvx   <= $signed(in_rd[28:15]);
            a_mvy   <= $signed(in_rd[14:1]);
            // previous macroblock: the registers hold it (updated at FIN); the vector differences follow
          end
          if (cnt == 9'd3) begin
            mvbig_l <= mv_big_f(c_mvx, c_mvy, p_mvx, p_mvy);
            mvbig_t <= mv_big_f(c_mvx, c_mvy, a_mvx, a_mvy);
          end
          if (cnt == 9'd96) mb_taken <= 1'b1;
          if (cnt == 9'd97) begin
            for (int i = 0; i < 6; i++) begin cls_a[i] <= cls_a_c[i]; cls_b[i] <= cls_b_c[i]; end
            ctx_s <= '0;
            ctx_p <= '0;
            st    <= (row_i != 8'd0) ? U_CTX : U_FLT;
            if (row_i == 8'd0) begin
              fph <= en_p ? F_V0 : F_END;
              fc  <= '0;
              flt_run <= en_p;
            end
          end
        end

        U_CTX: begin
          // Beat ctx_s of the line store entry of this column: read in phase 0, its four words written in phases 1..4.
          if (ctx_p == 4'd0) begin
            lf_re <= 1'b1;
            lf_ra <= {c_x[LF_AW-4:0], ctx_s};
            ctx_p <= 4'd1;
          end else if (ctx_p == 4'd5) begin
            ctx_p <= 4'd0;
            if (ctx_s == 3'd5) begin
              ctx_s <= '0;
              fph   <= en_p ? F_V0 : F_END;
              fc    <= '0;
              flt_run <= en_p;
              st    <= U_FLT;
            end else begin
              ctx_s <= ctx_s + 3'd1;
            end
          end else begin
            ctx_p <= ctx_p + 4'd1;
          end
        end

        U_FLT: begin
          case (fph)
            F_V0: begin
              fc <= fc + 6'd1;
              if (fc == 6'd15) begin fph <= F_V1; fc <= '0; end
            end
            F_V1: begin
              fc <= fc + 6'd1;
              if (fc == 6'd7) begin fph <= F_D1; fc <= '0; end
            end
            F_D1: begin
              fc <= fc + 6'd1;
              if (fc == 6'd3) begin fph <= F_H0; fc <= '0; end
            end
            F_H0: begin
              fc <= fc + 6'd1;
              if (fc == 6'd31) begin fph <= F_G; fc <= '0; end
            end
            F_G: begin
              fph <= F_H1;
              fc  <= '0;
            end
            F_H1: begin
              fc <= fc + 6'd1;
              if (fc == 6'd7) begin fph <= F_D2; fc <= '0; end
            end
            F_D2: begin
              fc <= fc + 6'd1;
              if (fc == 6'd4) begin
                fph <= F_END;
                flt_run <= 1'b0;
              end
            end
            default: begin
              flt_run <= 1'b0;
              // next step
              n_beat <= '0;
              rb_wait <= 1'b0;
              if (row_i != 8'd0) begin
                st <= U_LATE;
              end else if (c_x != 8'd0) begin
                ret_cur <= 1'b0;
                st <= U_RET;
              end else if (c_x == (w_p - 8'd1)) begin
                ret_cur <= 1'b1;
                st <= U_RET;
              end else begin
                st <= U_FIN;
              end
            end
          endcase
        end

        U_LATE: begin
          // Rows -3..-1 of luma and the chroma rows -2, -1 of the window into a late staging set.
          if (!rb_wait) begin
            if (!ls_busy[ls_w] && rq_rdy) begin
              rq_go  <= 1'b1;
              rq_set <= cs;
              rq_pl  <= (n_beat < 5'd3) ? 2'd0 : ((n_beat == 5'd3) ? 2'd1 : 2'd2);
              rq_r   <= (n_beat < 5'd3) ? (6'sd0 - 6'sd3 + $signed({1'b0, n_beat})) : -6'sd2;
              rq_ch  <= (n_beat >= 5'd3);
              rb_wait <= 1'b1;
            end
          end else if (rb_v) begin
            sg_we <= 1'b1;
            sg_wa <= 7'(LS_BASE) + {3'd0, ls_w, 3'd0} + 7'(n_beat);
            sg_wd <= rb_d;
            rb_wait <= 1'b0;
            n_beat <= n_beat + 5'd1;
            if (n_beat == 5'd4) begin
              jq_push <= 1'b1;
              jq_din  <= '{kind: 1'b1, set: ls_w, ty: c_ty - (ADDR_W'(w_p) << 8), tc: c_tc - (ADDR_W'(w_p) << 7)};
              ls_w    <= ~ls_w;
              n_beat  <= '0;
              if (c_x != 8'd0) begin
                ret_cur <= 1'b0;
                st      <= U_RET;
              end else if (c_x == (w_p - 8'd1)) begin
                ret_cur <= 1'b1;
                st      <= U_RET;
              end else begin
                st <= U_FIN;
              end
            end
          end
        end

        U_RET: begin
          if (!rb_wait) begin
            if (!ms_busy[ms_w] && rq_rdy) begin
              rq_go  <= 1'b1;
              rq_set <= ret_set;
              if (n_beat < 5'd16) begin
                rq_pl <= 2'd0; rq_r <= $signed({1'b0, n_beat}); rq_ch <= 1'b0;
              end else if (n_beat < 5'd20) begin
                rq_pl <= 2'd1; rq_r <= 6'sd2 * $signed({2'b00, n_beat[1:0]}); rq_ch <= 1'b1;
              end else begin
                rq_pl <= 2'd2; rq_r <= 6'sd2 * $signed({2'b00, n_beat[1:0]}); rq_ch <= 1'b1;
              end
              rb_wait <= 1'b1;
            end
          end else if (rb_v) begin
            rb_wait <= 1'b0;
            if (n_beat <= 5'd12) begin
              sg_we <= 1'b1;
              sg_wa <= {1'b0, ms_w, n_beat};
              sg_wd <= rb_d;
            end else if (n_beat >= 5'd16) begin
              sg_we <= 1'b1;
              sg_wa <= {1'b0, ms_w, 5'(5'd13 + n_beat - 5'd16)};
              sg_wd <= rb_d;
            end
            if ((n_beat >= 5'd12) && (n_beat <= 5'd15)) begin
              lf_we <= 1'b1;
              lf_wa <= {ret_x[LF_AW-4:0], 3'(n_beat - 5'd12)};
              lf_wd <= rb_d;
            end else if (n_beat == 5'd19) begin
              lf_we <= 1'b1;
              lf_wa <= {ret_x[LF_AW-4:0], 3'd4};
              lf_wd <= rb_d;
            end else if (n_beat == 5'd23) begin
              lf_we <= 1'b1;
              lf_wa <= {ret_x[LF_AW-4:0], 3'd5};
              lf_wd <= rb_d;
            end
            n_beat <= n_beat + 5'd1;
            if (n_beat == 5'd23) begin
              jq_push <= 1'b1;
              jq_din  <= '{kind: 1'b0, set: ms_w, ty: ret_ty, tc: ret_tc};
              ms_w    <= ~ms_w;
              n_beat  <= '0;
              if (!ret_cur && (c_x == (w_p - 8'd1))) begin
                ret_cur <= 1'b1;
              end else begin
                st <= U_FIN;
              end
            end
          end
        end

        U_FIN: begin
          in_we <= 1'b1;
          in_wa <= c_x[6:0];
          in_wd <= {c_intra, c_qp, c_nz[15:12], c_mvx, c_mvy, 1'b0};
          p_intra <= c_intra;
          p_qp    <= c_qp;
          p_nz    <= c_nz;
          p_mvx   <= c_mvx;
          p_mvy   <= c_mvy;
          cs      <= ~cs;
          mb_cnt  <= mb_cnt + 16'd1;
          if (c_x == (w_p - 8'd1)) row_i <= row_i + 8'd1;
          if ((mb_cnt + 16'd1) == mb_total) begin
            // The last macroblock: the late rows of the last row's tiles come from the line store.
            fl_x   <= '0;
            fl_c   <= '0;
            fl_ty  <= c_ty - (ADDR_W'(w_p - 8'd1) << 8);
            fl_tc  <= c_tc - (ADDR_W'(w_p - 8'd1) << 7);
            st     <= U_FLUSH;
          end else begin
            st <= U_IDLE;
          end
        end

        U_FLUSH: begin
          // Per column: read the line store slots 1..5 (rows 13..15 of the luma, the chroma beats) into a late set, then queue it.
          if ((fl_c == 3'd0) && (ls_busy[ls_w])) begin
            // wait for a free set
          end else begin
            if (fl_c <= 3'd4) begin
              lf_re <= 1'b1;
              lf_ra <= {fl_x[LF_AW-4:0], 3'(fl_c + 3'd1)};
            end
            if ((fl_c >= 3'd2) && (fl_c <= 3'd6)) begin
              sg_we <= 1'b1;
              sg_wa <= 7'(LS_BASE) + {3'd0, ls_w, 3'd0} + 7'(fl_c - 3'd2);
              sg_wd <= lf_rd;
            end
            if (fl_c == 3'd7) begin
              jq_push <= 1'b1;
              jq_din  <= '{kind: 1'b1, set: ls_w, ty: fl_ty, tc: fl_tc};
              ls_w    <= ~ls_w;
              fl_c    <= '0;
              fl_ty   <= fl_ty + ADDR_W'(256);
              fl_tc   <= fl_tc + ADDR_W'(128);
              fl_x    <= fl_x + 8'd1;
              if (fl_x == (w_p - 8'd1)) begin
                active <= 1'b0;
                st     <= U_IDLE;
              end
            end else begin
              fl_c <= fl_c + 3'd1;
            end
          end
        end

        default: st <= U_IDLE;
      endcase
    end
  end

endmodule
