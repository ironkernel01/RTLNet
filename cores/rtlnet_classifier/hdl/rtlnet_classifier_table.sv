// -----------------------------------------------------------------------------
// File: rtlnet_classifier_table.sv
// Purpose: one field table of rtlnet_classifier (MAC, ETHERTYPE, VLAN, IP or
//   PORT): ENTRIES entries compared against a frame's field snapshot in
//   single-value, range or data/mask mode, source / destination / either /
//   both, with the PORT table's protocol qualifier and policer selection.
// Overview:
//   * Storage: LANES lanes; lane l holds entries e with e mod LANES = l at
//     address e / LANES. Each entry word is its own rtlnet_ram_core
//     (READ_LATENCY 2, COMMON clock), so every 32-bit register write updates
//     exactly one word: W0 SRC_VALUE[31:0], W1 control + SRC_VALUE[47:32],
//     W2 DST_VALUE[31:0], W3 DST_VALUE[47:32] (W2/W3 only with a destination
//     field, W3 only for 48-bit fields). Port A: register writes and the
//     clear sequence; port B: the engine.
//   * Scan: the read address rotates through the words every clock. A frame
//     is compared during the WIN clocks after its snapshot loads (WIN >= the
//     table's word count), so every entry is seen once whatever the
//     rotation phase; the frame's hit is the OR over the window.
//   * Pairs: in range and data/mask modes lanes 2k and 2k+1 of a word form
//     entry pair (2k, 2k+1): range low/high (inclusive) or value/mask
//     ((field & mask) == (value & mask)). The control word of the even
//     entry governs the pair; the odd entry supplies only values.
//   * Entry hit: VALID, side hits combined by SRC_EN / DST_EN / BOTH (both
//     enabled: BOTH 1 = AND, 0 = OR; neither: no hit), absent fields never
//     hit, PORT table only: PROTO_EN requires the frame's IP protocol to
//     equal PROTO. COMPARE 11 is reserved and never hits.
//   * Timing: 16-bit compare lanes (equality, less-than), the masked
//     difference (field ^ value) & mask registered per bit and reduced to
//     16-bit zero flags in the next stage
//     registered, merged most-significant first in the next stage, then side
//     hit, entry hit and rtlnet_classifier_hitacc (lane reduce, window
//     accumulate, result latch): TABLE_STAGES registers after the first
//     compare cycle; no stage has more than two LUT levels plus carry.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (axis_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_classifier_table #(
  parameter int    TABLE_IDX = 0,          // 0 MAC .. 4 PORT: register window 0x400 + 0x100 TABLE_IDX
  parameter int    FW        = 48,         // field width, 1..48
  parameter bit    HAS_DST   = 1'b1,       // the field has a destination side
  parameter bit    HAS_PROTO = 1'b0,       // PROTO_EN / PROTO qualify a hit (PORT table)
  parameter int    ENTRIES   = 16,         // entries, power of two, >= LANES
  parameter int    LANES     = 2,          // entries per word, 2 or 4
  parameter int    WIN       = 8,          // compare window in clocks, >= ENTRIES / LANES
  parameter string RAM_STYLE = "block"
)(
  // Stream clock and synchronous active-low reset.
  input  logic          clk,
  input  logic          resetn,

  // Configuration write bus from the register file (registered): word
  // address = byte offset [11:2]; clear sequence writes zero everywhere.
  input  logic          cw_en,
  input  logic [9:0]    cw_addr,
  input  logic [31:0]   cw_data,
  input  logic          clr_active,
  input  logic [9:0]    clr_addr,

  // TABLE_MODE.COMPARE (registered copy).
  input  logic [1:0]    cfg_compare,

  // Frame snapshot: valid from win_start (pulse, first compare clock) for
  // the whole window.
  input  logic          win_start,
  input  logic [FW-1:0] f_src,
  input  logic [FW-1:0] f_dst,
  input  logic          f_sp,
  input  logic          f_dp,
  input  logic [7:0]    f_proto,

  // Frame result, valid from res_done until the next res_done.
  output logic          res_hit,
  output logic          res_pf,
  output logic [1:0]    res_pol,
  output logic          res_done
);

  import rtlnet_classifier_pkg::*;

  localparam int DEPTH = ENTRIES / LANES;                         // words per lane
  localparam int AW    = (DEPTH > 1) ? rtlnet_pkg::clog2i(DEPTH) : 1;
  localparam int LB    = rtlnet_pkg::clog2i(LANES);               // lane bits of an entry index
  localparam int EB    = rtlnet_pkg::clog2i(ENTRIES);             // entry index bits
  localparam int CH    = (FW + 15) / 16;                           // 16-bit compare chunks
  localparam int FWX   = 16 * CH;                                  // field width rounded to chunks
  localparam int FWM   = FWX;                                      // masked-difference width
  localparam int W0_W  = (FW < 32) ? FW : 32;
  localparam int W3_W  = (FW > 32) ? FW - 32 : 1;
  localparam int WCNT  = (WIN > 1) ? rtlnet_pkg::clog2i(WIN) : 1;
  localparam logic [3:0]      WIN_SEL   = 4 + TABLE_IDX;           // byte offset [11:8]
  localparam logic [AW-1:0]   ROT_LAST  = DEPTH - 1;
  localparam logic [WCNT-1:0] WIN_LOAD  = WIN - 1;
  localparam logic [WCNT-1:0] WIN_ONE   = 1;
  localparam logic            WIN_SHORT = (WIN == 1);

  generate
    if (LANES != 2 && LANES != 4) begin : g_bad_lanes
      $fatal(1, "rtlnet_classifier_table: LANES=%0d, must be 2 or 4", LANES);
    end
    if (ENTRIES < LANES || ENTRIES > 16 || (ENTRIES & (ENTRIES - 1)) != 0) begin : g_bad_entries
      $fatal(1, "rtlnet_classifier_table: ENTRIES=%0d, must be a power of two, LANES..16", ENTRIES);
    end
    if (WIN < DEPTH) begin : g_bad_win
      $fatal(1, "rtlnet_classifier_table: WIN=%0d below the word count %0d", WIN, DEPTH);
    end
    if (FW < 1 || FW > 48) begin : g_bad_fw
      $fatal(1, "rtlnet_classifier_table: FW=%0d, must be 1..48", FW);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Configuration writes: local copy of the bus, then per-word decode.
  // ---------------------------------------------------------------------------
  logic                          cw_en_q;
  logic [9:0]                    cw_addr_q;
  logic [31:0]                   cw_data_q;
  logic                          clr_q;
  logic [9:0]                    clr_addr_q;
  logic [LANES-1:0][3:0]         we;                 // [lane][word]
  logic [AW-1:0]                 wa;
  logic [31:0]                   wd;

  // Local register copy of the write bus (fanout relief, one LUT level to
  // the decode).
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

  // Decode: byte offset 0x400 + 0x100 TABLE_IDX + 0x10 e + 4 w, entry e in
  // lane e mod LANES at word e / LANES; the clear sequence writes zero to
  // every word of every lane.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      we <= '0;
      wa <= '0;
      wd <= '0;
    end else begin
      for (int l = 0; l < LANES; l++) begin
        for (int w = 0; w < 4; w++) begin
          we[l][w] <= clr_q ||
                      (cw_en_q && (cw_addr_q[9:6] == WIN_SEL) && (cw_addr_q[5:2] < ENTRIES) &&
                       (cw_addr_q[2 +: LB] == l) && (cw_addr_q[1:0] == w));
        end
      end
      if (clr_q) begin
        wa <= clr_addr_q[AW-1:0];
        wd <= '0;
      end else begin
        wa <= (DEPTH > 1) ? cw_addr_q[2 + LB +: AW] : '0;
        wd <= cw_data_q;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read side: rotating word address, aligned with the RAM output.
  // ---------------------------------------------------------------------------
  logic [AW-1:0] rot;
  logic [AW-1:0] rot_d1;
  logic [AW-1:0] rot_d2;

  // Rotating read address and its two-clock delay (RAM READ_LATENCY 2).
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

  // Entry words per lane.
  logic [LANES-1:0][31:0] rd_w0;
  logic [LANES-1:0][31:0] rd_w1;
  logic [LANES-1:0][31:0] rd_w2;
  logic [LANES-1:0][15:0] rd_w3;

  genvar gl;
  generate
    for (gl = 0; gl < LANES; gl++) begin : g_lane
      logic [W0_W-1:0] q0;
      logic [31:0]     q1;

      // W0: SRC_VALUE[31:0] (or the whole field below 32 bits).
      rtlnet_ram_core #(
        .RAM_STYLE (RAM_STYLE), .CLOCKING ("COMMON"), .DATA_W (W0_W), .ADDR_W (AW), .READ_LATENCY (2)
      ) u_ram_w0 (
        .wr_clk (clk), .wr_en (we[gl][0]), .wr_addr (wa), .wr_data (wd[W0_W-1:0]),
        .rd_clk (clk), .rd_resetn (resetn), .rd_en (1'b1), .rd_addr (rot), .rd_data (q0)
      );
      // W1: control word and SRC_VALUE[47:32].
      rtlnet_ram_core #(
        .RAM_STYLE (RAM_STYLE), .CLOCKING ("COMMON"), .DATA_W (32), .ADDR_W (AW), .READ_LATENCY (2)
      ) u_ram_w1 (
        .wr_clk (clk), .wr_en (we[gl][1]), .wr_addr (wa), .wr_data (wd),
        .rd_clk (clk), .rd_resetn (resetn), .rd_en (1'b1), .rd_addr (rot), .rd_data (q1)
      );
      assign rd_w0[gl] = 32'(q0);
      assign rd_w1[gl] = q1;

      if (HAS_DST) begin : g_dst
        logic [W0_W-1:0] q2;
        // W2: DST_VALUE[31:0].
        rtlnet_ram_core #(
          .RAM_STYLE (RAM_STYLE), .CLOCKING ("COMMON"), .DATA_W (W0_W), .ADDR_W (AW), .READ_LATENCY (2)
        ) u_ram_w2 (
          .wr_clk (clk), .wr_en (we[gl][2]), .wr_addr (wa), .wr_data (wd[W0_W-1:0]),
          .rd_clk (clk), .rd_resetn (resetn), .rd_en (1'b1), .rd_addr (rot), .rd_data (q2)
        );
        assign rd_w2[gl] = 32'(q2);
        if (FW > 32) begin : g_w3
          logic [W3_W-1:0] q3;
          // W3: DST_VALUE[47:32].
          rtlnet_ram_core #(
            .RAM_STYLE (RAM_STYLE), .CLOCKING ("COMMON"), .DATA_W (W3_W), .ADDR_W (AW), .READ_LATENCY (2)
          ) u_ram_w3 (
            .wr_clk (clk), .wr_en (we[gl][3]), .wr_addr (wa), .wr_data (wd[W3_W-1:0]),
            .rd_clk (clk), .rd_resetn (resetn), .rd_en (1'b1), .rd_addr (rot), .rd_data (q3)
          );
          assign rd_w3[gl] = 16'(q3);
        end else begin : g_no_w3
          assign rd_w3[gl] = '0;
        end
      end else begin : g_no_dst
        assign rd_w2[gl] = '0;
        assign rd_w3[gl] = '0;
      end
    end
  endgenerate

  // Entry values per lane, zero-extended to whole chunks.
  logic [LANES-1:0][FWX-1:0] v_src;
  logic [LANES-1:0][FWX-1:0] v_dst;
  logic [FWX-1:0]            fx_src;
  logic [FWX-1:0]            fx_dst;

  logic [LANES-1:0][47:0]    v_src48;
  logic [LANES-1:0][47:0]    v_dst48;
  logic [FWM-1:0]            fm_src;
  logic [FWM-1:0]            fm_dst;
  logic [LANES-1:0][FWM-1:0] vm_src;
  logic [LANES-1:0][FWM-1:0] vm_dst;

  always_comb begin
    fx_src         = '0;
    fx_src[FW-1:0] = f_src;
    fx_dst         = '0;
    fx_dst[FW-1:0] = f_dst;
    for (int l = 0; l < LANES; l++) begin
      v_src48[l] = {rd_w1[l][15:0], rd_w0[l]};
      v_dst48[l] = {rd_w3[l], rd_w2[l]};
      v_src[l]   = v_src48[l][FWX-1:0];
      v_dst[l]   = v_dst48[l][FWX-1:0];
      vm_src[l]  = '0;
      vm_dst[l]  = '0;
      vm_src[l][FW-1:0] = v_src48[l][FW-1:0];
      vm_dst[l][FW-1:0] = v_dst48[l][FW-1:0];
    end
    fm_src         = '0;
    fm_src[FW-1:0] = f_src;
    fm_dst         = '0;
    fm_dst[FW-1:0] = f_dst;
  end

  // ---------------------------------------------------------------------------
  // Window markers: first compare clock = win_start, then WIN-1 more.
  // ---------------------------------------------------------------------------
  logic [WCNT-1:0] wcnt;
  logic            c0_first;
  logic            c0_last;
  logic            c0_is0;

  assign c0_first = win_start;
  assign c0_last  = (win_start && WIN_SHORT) || (wcnt == WIN_ONE);
  assign c0_is0   = (rot_d2 == '0);

  // Window counter: clocks remaining after the current one.
  always_ff @(posedge clk) begin
    if (!resetn)              wcnt <= '0;
    else if (win_start)       wcnt <= WIN_LOAD;
    else if (wcnt != '0)      wcnt <= wcnt - 1'b1;
  end

  // ---------------------------------------------------------------------------
  // C1: 16-bit chunk compares per lane and side; masked equality per pair.
  // ---------------------------------------------------------------------------
  logic [LANES-1:0][CH-1:0] c1_eq_s;
  logic [LANES-1:0][CH-1:0] c1_lt_s;
  logic [LANES-1:0][FWM-1:0] c1_md_s;     // (field ^ value) & mask, even lanes
  logic [LANES-1:0][CH-1:0] c1_eq_d;
  logic [LANES-1:0][CH-1:0] c1_lt_d;
  logic [LANES-1:0][FWM-1:0] c1_md_d;
  logic [LANES-1:0][15:0]   c1_ctl;      // control word bits [31:16]
  logic [LANES-1:0]         c1_pok;      // protocol qualifier passes
  logic                     c1_sp;
  logic                     c1_dp;
  logic                     c1_first;
  logic                     c1_last;
  logic                     c1_is0;

  // Chunk compares (one LUT level plus carry, or two LUT levels).
  always_ff @(posedge clk) begin
    if (!resetn) begin
      c1_eq_s  <= '0;
      c1_lt_s  <= '0;
      c1_md_s  <= '0;
      c1_eq_d  <= '0;
      c1_lt_d  <= '0;
      c1_md_d  <= '0;
      c1_ctl   <= '0;
      c1_pok   <= '0;
      c1_sp    <= 1'b0;
      c1_dp    <= 1'b0;
      c1_first <= 1'b0;
      c1_last  <= 1'b0;
      c1_is0   <= 1'b0;
    end else begin
      for (int l = 0; l < LANES; l++) begin
        for (int c = 0; c < CH; c++) begin
          c1_eq_s[l][c]  <= (fx_src[16*c +: 16] == v_src[l][16*c +: 16]);
          c1_lt_s[l][c]  <= (fx_src[16*c +: 16] <  v_src[l][16*c +: 16]);
          c1_eq_d[l][c]  <= HAS_DST && (fx_dst[16*c +: 16] == v_dst[l][16*c +: 16]);
          c1_lt_d[l][c]  <= HAS_DST && (fx_dst[16*c +: 16] <  v_dst[l][16*c +: 16]);
        end
        // Masked difference of a pair (even lane: value, odd lane: mask),
        // one LUT per bit; odd lanes have none (all ones: never zero).
        if ((l % 2) == 0) begin
          c1_md_s[l] <= (fm_src ^ vm_src[l]) & vm_src[(l | 1)];
          c1_md_d[l] <= HAS_DST ? ((fm_dst ^ vm_dst[l]) & vm_dst[(l | 1)]) : '1;
        end else begin
          c1_md_s[l] <= '1;
          c1_md_d[l] <= '1;
        end
        c1_ctl[l] <= rd_w1[l][31:16];
        c1_pok[l] <= !HAS_PROTO || !rd_w1[l][FE_PROTO_EN] ||
                     (f_proto == rd_w1[l][FE_PROTO_LSB +: 8]);
      end
      c1_sp    <= f_sp;
      c1_dp    <= f_dp && HAS_DST;
      c1_first <= c0_first;
      c1_last  <= c0_last;
      c1_is0   <= c0_is0;
    end
  end

  // ---------------------------------------------------------------------------
  // C2: merge chunks (most significant first).
  // ---------------------------------------------------------------------------
  logic [LANES-1:0] c2_eq_s;
  logic [LANES-1:0] c2_lt_s;
  logic [LANES-1:0][CH-1:0] c2_mz_s;     // 16-bit chunk of the masked difference is zero
  logic [LANES-1:0] c2_eq_d;
  logic [LANES-1:0] c2_lt_d;
  logic [LANES-1:0][CH-1:0] c2_mz_d;
  logic [LANES-1:0][15:0] c2_ctl;
  logic [LANES-1:0] c2_pok;
  logic             c2_sp;
  logic             c2_dp;
  logic             c2_first;
  logic             c2_last;
  logic             c2_is0;

  // Chunk merge: field < value when a more significant chunk is less and
  // all above it are equal.
  function automatic logic merge_lt(input logic [CH-1:0] lt, input logic [CH-1:0] eq);
    logic r;
    logic all_eq;
    r      = 1'b0;
    all_eq = 1'b1;
    for (int c = CH - 1; c >= 0; c--) begin
      r      = r || (all_eq && lt[c]);
      all_eq = all_eq && eq[c];
    end
    return r;
  endfunction

  always_ff @(posedge clk) begin
    if (!resetn) begin
      c2_eq_s  <= '0;
      c2_lt_s  <= '0;
      c2_mz_s  <= '0;
      c2_eq_d  <= '0;
      c2_lt_d  <= '0;
      c2_mz_d  <= '0;
      c2_ctl   <= '0;
      c2_pok   <= '0;
      c2_sp    <= 1'b0;
      c2_dp    <= 1'b0;
      c2_first <= 1'b0;
      c2_last  <= 1'b0;
      c2_is0   <= 1'b0;
    end else begin
      for (int l = 0; l < LANES; l++) begin
        c2_eq_s[l]  <= &c1_eq_s[l];
        c2_lt_s[l]  <= merge_lt(c1_lt_s[l], c1_eq_s[l]);
        for (int c = 0; c < CH; c++) c2_mz_s[l][c] <= (c1_md_s[l][16*c +: 16] == 16'h0000);
        c2_eq_d[l]  <= &c1_eq_d[l];
        c2_lt_d[l]  <= merge_lt(c1_lt_d[l], c1_eq_d[l]);
        for (int c = 0; c < CH; c++) c2_mz_d[l][c] <= (c1_md_d[l][16*c +: 16] == 16'h0000);
      end
      c2_ctl   <= c1_ctl;
      c2_pok   <= c1_pok;
      c2_sp    <= c1_sp;
      c2_dp    <= c1_dp;
      c2_first <= c1_first;
      c2_last  <= c1_last;
      c2_is0   <= c1_is0;
    end
  end

  // ---------------------------------------------------------------------------
  // C3: side hits per compare unit (lane in single mode, even lane of a pair
  // in range / data-mask mode), gated by field presence.
  // ---------------------------------------------------------------------------
  logic [1:0]       mode_q;
  logic [LANES-1:0] c3_s;
  logic [LANES-1:0] c3_d;
  logic [LANES-1:0] c3_act;
  logic [LANES-1:0][15:0] c3_ctl;
  logic [LANES-1:0] c3_pok;
  logic             c3_first;
  logic             c3_last;
  logic             c3_is0;

  // Local registered copy of the compare mode.
  always_ff @(posedge clk) begin
    if (!resetn) mode_q <= CMP_SINGLE;
    else         mode_q <= cfg_compare;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      c3_s     <= '0;
      c3_d     <= '0;
      c3_act   <= '0;
      c3_ctl   <= '0;
      c3_pok   <= '0;
      c3_first <= 1'b0;
      c3_last  <= 1'b0;
      c3_is0   <= 1'b0;
    end else begin
      for (int l = 0; l < LANES; l++) begin
        case (mode_q)
          CMP_SINGLE: begin
            c3_s[l]   <= c2_sp && c2_eq_s[l];
            c3_d[l]   <= c2_dp && c2_eq_d[l];
            c3_act[l] <= 1'b1;
          end
          CMP_RANGE: begin
            c3_s[l]   <= ((l % 2) == 0) && c2_sp && !c2_lt_s[l] && (c2_lt_s[l | 1] || c2_eq_s[l | 1]);
            c3_d[l]   <= ((l % 2) == 0) && c2_dp && !c2_lt_d[l] && (c2_lt_d[l | 1] || c2_eq_d[l | 1]);
            c3_act[l] <= ((l % 2) == 0);
          end
          CMP_MASK: begin
            c3_s[l]   <= ((l % 2) == 0) && c2_sp && (&c2_mz_s[l]);
            c3_d[l]   <= ((l % 2) == 0) && c2_dp && (&c2_mz_d[l]);
            c3_act[l] <= ((l % 2) == 0);
          end
          default: begin
            c3_s[l]   <= 1'b0;
            c3_d[l]   <= 1'b0;
            c3_act[l] <= 1'b0;
          end
        endcase
      end
      c3_ctl   <= c2_ctl;
      c3_pok   <= c2_pok;
      c3_first <= c2_first;
      c3_last  <= c2_last;
      c3_is0   <= c2_is0;
    end
  end

  // ---------------------------------------------------------------------------
  // C4: entry hits with the control word (bit n of c3_ctl = word bit n + 16).
  // ---------------------------------------------------------------------------
  localparam int CB_VALID  = FE_VALID - 16;
  localparam int CB_SRC_EN = FE_SRC_EN - 16;
  localparam int CB_DST_EN = FE_DST_EN - 16;
  localparam int CB_BOTH   = FE_BOTH - 16;
  localparam int CB_PE     = FE_POLICE_EN - 16;
  localparam int CB_POL    = FE_POLICER_LSB - 16;

  logic [LANES-1:0]      c4_hit;
  logic [LANES-1:0]      c4_hp;
  logic [LANES-1:0][1:0] c4_pol;
  logic                  c4_first;
  logic                  c4_last;
  logic                  c4_is0;
  logic [LANES-1:0]      side_hit;

  // Source / destination combination of one entry.
  always_comb begin
    for (int l = 0; l < LANES; l++) begin
      if (c3_ctl[l][CB_SRC_EN] && c3_ctl[l][CB_DST_EN])
        side_hit[l] = c3_ctl[l][CB_BOTH] ? (c3_s[l] && c3_d[l]) : (c3_s[l] || c3_d[l]);
      else if (c3_ctl[l][CB_SRC_EN])
        side_hit[l] = c3_s[l];
      else if (c3_ctl[l][CB_DST_EN])
        side_hit[l] = c3_d[l];
      else
        side_hit[l] = 1'b0;
    end
  end

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
        c4_hit[l] <= c3_act[l] && c3_ctl[l][CB_VALID] && c3_pok[l] && side_hit[l];
        c4_hp[l]  <= c3_act[l] && c3_ctl[l][CB_VALID] && c3_pok[l] && side_hit[l] && c3_ctl[l][CB_PE];
        c4_pol[l] <= c3_ctl[l][CB_POL +: 2];
      end
      c4_first <= c3_first;
      c4_last  <= c3_last;
      c4_is0   <= c3_is0;
    end
  end

  // ---------------------------------------------------------------------------
  // C5..C7: lane reduce, window accumulate, result latch.
  // ---------------------------------------------------------------------------
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
