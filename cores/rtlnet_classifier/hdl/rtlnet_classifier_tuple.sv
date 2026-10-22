// -----------------------------------------------------------------------------
// File: rtlnet_classifier_tuple.sv
// Purpose: the tuple (ACL) table of rtlnet_classifier: ENTRIES entries, each
//   one complete L3/L4 combination (IP protocol, source IP/mask, destination
//   IP/mask, source and destination port ranges) with policer selection.
// Overview:
//   * Storage: LANES lanes as in rtlnet_classifier_table; seven words per
//     entry, each its own rtlnet_ram_core (READ_LATENCY 2, COMMON clock):
//     W0 control {VALID, PROTO_EN, POLICE_EN, POLICER, PROTO}, W1 SRC_IP,
//     W2 SRC_MASK, W3 DST_IP, W4 DST_MASK, W5 {SPORT_HI, SPORT_LO},
//     W6 {DPORT_HI, DPORT_LO}. Register window 0x900 + 0x20 e + 4 w.
//   * An entry hits an IPv4 frame (IHL 5, both addresses present) when it
//     is VALID and every part agrees: PROTO_EN -> protocol equal;
//     (ip & MASK) == (IP & MASK) for both addresses (mask 0 = any); each
//     port inside [LO, HI] inclusive. A port range 0..65535 is "any" and
//     also matches a frame without L4 ports (ICMP, fragments); any other
//     range requires has_l4 (protocol 6 or 17, not a fragment, ports
//     present). A non-IPv4 frame never hits.
//   * Same rotating scan, window and result timing as the field tables
//     (TABLE_STAGES registers after the first compare clock).
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (axis_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_classifier_tuple #(
  parameter int    ENTRIES   = 16,         // entries, power of two, LANES..16
  parameter int    LANES     = 2,          // entries per word, 2 or 4
  parameter int    WIN       = 8,          // compare window in clocks, >= ENTRIES / LANES
  parameter string RAM_STYLE = "block"
)(
  // Stream clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Configuration write bus from the register file (registered).
  input  logic        cw_en,
  input  logic [9:0]  cw_addr,
  input  logic [31:0] cw_data,
  input  logic        clr_active,
  input  logic [9:0]  clr_addr,

  // Frame snapshot, valid from win_start for the whole window.
  input  logic        win_start,
  input  logic [7:0]  f_proto,
  input  logic [31:0] f_sip,
  input  logic [31:0] f_dip,
  input  logic [15:0] f_sport,
  input  logic [15:0] f_dport,
  input  logic        f_ip,
  input  logic        f_l4,

  // Frame result, valid from res_done until the next res_done.
  output logic        res_hit,
  output logic        res_pf,
  output logic [1:0]  res_pol,
  output logic        res_done
);

  import rtlnet_classifier_pkg::*;

  localparam int DEPTH = ENTRIES / LANES;
  localparam int AW    = (DEPTH > 1) ? rtlnet_pkg::clog2i(DEPTH) : 1;
  localparam int LB    = rtlnet_pkg::clog2i(LANES);
  localparam int NW    = TUPLE_WORDS;
  localparam int WCNT  = (WIN > 1) ? rtlnet_pkg::clog2i(WIN) : 1;
  localparam logic [AW-1:0]   ROT_LAST  = DEPTH - 1;
  localparam logic [WCNT-1:0] WIN_LOAD  = WIN - 1;
  localparam logic [WCNT-1:0] WIN_ONE   = 1;
  localparam logic            WIN_SHORT = (WIN == 1);

  generate
    if (LANES != 2 && LANES != 4) begin : g_bad_lanes
      $fatal(1, "rtlnet_classifier_tuple: LANES=%0d, must be 2 or 4", LANES);
    end
    if (ENTRIES < LANES || ENTRIES > 16 || (ENTRIES & (ENTRIES - 1)) != 0) begin : g_bad_entries
      $fatal(1, "rtlnet_classifier_tuple: ENTRIES=%0d, must be a power of two, LANES..16", ENTRIES);
    end
    if (WIN < DEPTH) begin : g_bad_win
      $fatal(1, "rtlnet_classifier_tuple: WIN=%0d below the word count %0d", WIN, DEPTH);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Configuration writes.
  // ---------------------------------------------------------------------------
  logic                    cw_en_q;
  logic [9:0]              cw_addr_q;
  logic [31:0]             cw_data_q;
  logic                    clr_q;
  logic [9:0]              clr_addr_q;
  logic [3:0]              cw_entry;
  logic                    cw_hit;
  logic [LANES-1:0][NW-1:0] we;
  logic [AW-1:0]           wa;
  logic [31:0]             wd;

  // Local register copy of the write bus.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cw_en_q    <= 1'b0;
      cw_addr_q  <= '0;
      cw_data_q  <= '0;
      clr_q      <= 1'b0;
      clr_addr_q <= '0;
    end else begin
      cw_en_q    <= cw_en;
      cw_addr_q  <= cw_addr;
      cw_data_q  <= cw_data;
      clr_q      <= clr_active;
      clr_addr_q <= clr_addr;
    end
  end

  // Byte offset 0x900 + 0x20 e + 4 w: offset[11:8] is 9 (e 0..7) or A
  // (e 8..15), e = {offset[9], offset[7:5]}, w = offset[4:2].
  assign cw_entry = {cw_addr_q[7], cw_addr_q[5:3]};
  assign cw_hit   = cw_en_q && (cw_addr_q[9:8] == 2'b10) && (cw_addr_q[7] != cw_addr_q[6]) &&
                    (cw_entry < ENTRIES);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      we <= '0;
      wa <= '0;
      wd <= '0;
    end else begin
      for (int l = 0; l < LANES; l++) begin
        for (int w = 0; w < NW; w++) begin
          we[l][w] <= clr_q || (cw_hit && (cw_entry[LB-1:0] == l) && (cw_addr_q[2:0] == w));
        end
      end
      if (clr_q) begin
        wa <= clr_addr_q[AW-1:0];
        wd <= '0;
      end else begin
        wa <= (DEPTH > 1) ? cw_entry[LB +: AW] : '0;
        wd <= cw_data_q;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read side.
  // ---------------------------------------------------------------------------
  logic [AW-1:0] rot;
  logic [AW-1:0] rot_d1;
  logic [AW-1:0] rot_d2;

  // Rotating read address and its delay to the RAM output.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      rot    <= '0;
      rot_d1 <= '0;
      rot_d2 <= '0;
    end else begin
      rot    <= (rot == ROT_LAST) ? '0 : rot + 1'b1;
      rot_d1 <= rot;
      rot_d2 <= rot_d1;
    end
  end

  logic [LANES-1:0][NW-1:0][31:0] rd_w;

  genvar gl, gw;
  generate
    for (gl = 0; gl < LANES; gl++) begin : g_lane
      for (gw = 0; gw < NW; gw++) begin : g_word
        logic [31:0] q;
        // Entry word gw of lane gl.
        rtlnet_ram_core #(
          .RAM_STYLE (RAM_STYLE), .CLOCKING ("COMMON"), .DATA_W (32), .ADDR_W (AW), .READ_LATENCY (2)
        ) u_ram (
          .wr_clk (clk), .wr_en (we[gl][gw]), .wr_addr (wa), .wr_data (wd),
          .rd_clk (clk), .rd_resetn (resetn), .rd_en (1'b1), .rd_addr (rot), .rd_data (q)
        );
        assign rd_w[gl][gw] = q;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Window markers.
  // ---------------------------------------------------------------------------
  logic [WCNT-1:0] wcnt;
  logic            c0_last;

  assign c0_last = (win_start && WIN_SHORT) || (wcnt == WIN_ONE);

  always_ff @(posedge clk) begin
    if (!resetn)         wcnt <= '0;
    else if (win_start)  wcnt <= WIN_LOAD;
    else if (wcnt != '0) wcnt <= wcnt - 1'b1;
  end

  // ---------------------------------------------------------------------------
  // C1: per-lane compares in 16-bit lanes.
  // ---------------------------------------------------------------------------
  logic [LANES-1:0]      c1_peq;
  logic [LANES-1:0][31:0] c1_smd;     // (sip ^ SRC_IP) & SRC_MASK
  logic [LANES-1:0][31:0] c1_dmd;
  logic [LANES-1:0]      c1_s_lt_lo;
  logic [LANES-1:0]      c1_s_gt_hi;
  logic [LANES-1:0]      c1_s_any;
  logic [LANES-1:0]      c1_d_lt_lo;
  logic [LANES-1:0]      c1_d_gt_hi;
  logic [LANES-1:0]      c1_d_any;
  logic [LANES-1:0]      c1_valid;
  logic [LANES-1:0]      c1_pen;
  logic [LANES-1:0]      c1_pe;
  logic [LANES-1:0][1:0] c1_pol;
  logic                  c1_ip;
  logic                  c1_l4;
  logic                  c1_first;
  logic                  c1_last;
  logic                  c1_is0;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      c1_peq     <= '0;
      c1_smd     <= '0;
      c1_dmd     <= '0;
      c1_s_lt_lo <= '0;
      c1_s_gt_hi <= '0;
      c1_s_any   <= '0;
      c1_d_lt_lo <= '0;
      c1_d_gt_hi <= '0;
      c1_d_any   <= '0;
      c1_valid   <= '0;
      c1_pen     <= '0;
      c1_pe      <= '0;
      c1_pol     <= '0;
      c1_ip      <= 1'b0;
      c1_l4      <= 1'b0;
      c1_first   <= 1'b0;
      c1_last    <= 1'b0;
      c1_is0     <= 1'b0;
    end else begin
      for (int l = 0; l < LANES; l++) begin
        c1_peq[l] <= (f_proto == rd_w[l][TW_CTRL][TE_PROTO_LSB +: 8]);
        // Masked address differences, one LUT per bit.
        c1_smd[l] <= (f_sip ^ rd_w[l][TW_SRC_IP]) & rd_w[l][TW_SRC_MASK];
        c1_dmd[l] <= (f_dip ^ rd_w[l][TW_DST_IP]) & rd_w[l][TW_DST_MASK];
        c1_s_lt_lo[l] <= (f_sport < rd_w[l][TW_SPORT][15:0]);
        c1_s_gt_hi[l] <= (rd_w[l][TW_SPORT][31:16] < f_sport);
        c1_s_any[l]   <= (rd_w[l][TW_SPORT] == 32'hFFFF_0000);
        c1_d_lt_lo[l] <= (f_dport < rd_w[l][TW_DPORT][15:0]);
        c1_d_gt_hi[l] <= (rd_w[l][TW_DPORT][31:16] < f_dport);
        c1_d_any[l]   <= (rd_w[l][TW_DPORT] == 32'hFFFF_0000);
        c1_valid[l]   <= rd_w[l][TW_CTRL][TE_VALID];
        c1_pen[l]     <= rd_w[l][TW_CTRL][TE_PROTO_EN];
        c1_pe[l]      <= rd_w[l][TW_CTRL][TE_POLICE_EN];
        c1_pol[l]     <= rd_w[l][TW_CTRL][TE_POLICER_LSB +: 2];
      end
      c1_ip    <= f_ip;
      c1_l4    <= f_l4;
      c1_first <= win_start;
      c1_last  <= c0_last;
      c1_is0   <= (rot_d2 == '0);
    end
  end

  // ---------------------------------------------------------------------------
  // C2: merge address halves and port bounds.
  // ---------------------------------------------------------------------------
  logic [LANES-1:0]      c2_pok;
  logic [LANES-1:0][1:0] c2_sip;      // 16-bit halves of the masked difference are zero
  logic [LANES-1:0][1:0] c2_dip;
  logic [LANES-1:0]      c2_sport;
  logic [LANES-1:0]      c2_dport;
  logic [LANES-1:0]      c2_valid;
  logic [LANES-1:0]      c2_pe;
  logic [LANES-1:0][1:0] c2_pol;
  logic                  c2_ip;
  logic                  c2_first;
  logic                  c2_last;
  logic                  c2_is0;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      c2_pok   <= '0;
      c2_sip   <= '0;
      c2_dip   <= '0;
      c2_sport <= '0;
      c2_dport <= '0;
      c2_valid <= '0;
      c2_pe    <= '0;
      c2_pol   <= '0;
      c2_ip    <= 1'b0;
      c2_first <= 1'b0;
      c2_last  <= 1'b0;
      c2_is0   <= 1'b0;
    end else begin
      for (int l = 0; l < LANES; l++) begin
        c2_pok[l]   <= !c1_pen[l] || c1_peq[l];
        for (int c = 0; c < 2; c++) begin
          c2_sip[l][c] <= (c1_smd[l][16*c +: 16] == 16'h0000);
          c2_dip[l][c] <= (c1_dmd[l][16*c +: 16] == 16'h0000);
        end
        c2_sport[l] <= c1_s_any[l] || (c1_l4 && !c1_s_lt_lo[l] && !c1_s_gt_hi[l]);
        c2_dport[l] <= c1_d_any[l] || (c1_l4 && !c1_d_lt_lo[l] && !c1_d_gt_hi[l]);
      end
      c2_valid <= c1_valid;
      c2_pe    <= c1_pe;
      c2_pol   <= c1_pol;
      c2_ip    <= c1_ip;
      c2_first <= c1_first;
      c2_last  <= c1_last;
      c2_is0   <= c1_is0;
    end
  end

  // ---------------------------------------------------------------------------
  // C3: address/protocol part and port part of each entry.
  // ---------------------------------------------------------------------------
  logic [LANES-1:0]      c3_x;
  logic [LANES-1:0]      c3_y;
  logic [LANES-1:0]      c3_pe;
  logic [LANES-1:0][1:0] c3_pol;
  logic                  c3_first;
  logic                  c3_last;
  logic                  c3_is0;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      c3_x     <= '0;
      c3_y     <= '0;
      c3_pe    <= '0;
      c3_pol   <= '0;
      c3_first <= 1'b0;
      c3_last  <= 1'b0;
      c3_is0   <= 1'b0;
    end else begin
      for (int l = 0; l < LANES; l++) begin
        c3_x[l] <= c2_valid[l] && c2_ip && c2_pok[l] && (&c2_sip[l]) && (&c2_dip[l]);
        c3_y[l] <= c2_sport[l] && c2_dport[l];
      end
      c3_pe    <= c2_pe;
      c3_pol   <= c2_pol;
      c3_first <= c2_first;
      c3_last  <= c2_last;
      c3_is0   <= c2_is0;
    end
  end

  // ---------------------------------------------------------------------------
  // C4: entry hits.
  // ---------------------------------------------------------------------------
  logic [LANES-1:0]      c4_hit;
  logic [LANES-1:0]      c4_hp;
  logic [LANES-1:0][1:0] c4_pol;
  logic                  c4_first;
  logic                  c4_last;
  logic                  c4_is0;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      c4_hit   <= '0;
      c4_hp    <= '0;
      c4_pol   <= '0;
      c4_first <= 1'b0;
      c4_last  <= 1'b0;
      c4_is0   <= 1'b0;
    end else begin
      for (int l = 0; l < LANES; l++) begin
        c4_hit[l] <= c3_x[l] && c3_y[l];
        c4_hp[l]  <= c3_x[l] && c3_y[l] && c3_pe[l];
      end
      c4_pol   <= c3_pol;
      c4_first <= c3_first;
      c4_last  <= c3_last;
      c4_is0   <= c3_is0;
    end
  end

  // C5..C7: lane reduce, window accumulate, result latch.
  rtlnet_classifier_hitacc #(
    .LANES (LANES)
  ) u_hitacc (
    .clk        (clk),
    .resetn     (resetn),
    .hit        (c4_hit),
    .hit_police (c4_hp),
    .pol        (c4_pol),
    .win_first  (c4_first),
    .win_last   (c4_last),
    .word_is0   (c4_is0),
    .res_hit    (res_hit),
    .res_pf     (res_pf),
    .res_pol    (res_pol),
    .res_done   (res_done)
  );

endmodule
