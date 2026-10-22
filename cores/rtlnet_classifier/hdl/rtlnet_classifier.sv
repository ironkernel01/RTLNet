// -----------------------------------------------------------------------------
// File: rtlnet_classifier.sv
// Purpose: configurable MAC / EtherType / VLAN / IPv4 / L4 frame filter and
//   classifier on an RTLNet stream. Every frame passes through a
//   shift-register delay line while field tables, a tuple (ACL) table and
//   positional byte rule engines judge its first MATCH_DEPTH_BYTES bytes;
//   at the end of the line the unmodified frame leaves with its valid set
//   (pass) or cleared (drop) by the combined, policed decision.
// Overview:
//   * Specification: cores/rtlnet_classifier/documentation/rtlnet_classifier.md.
//   * Blocks: u_regs (AXI4-Lite crossing, register file, clear sequence,
//     readback), u_line (ingress, delay line u_delay_line, verdict queue,
//     gate, output slice), u_extract (field capture, judge acceptance,
//     snapshot), u_tbl_mac/u_tbl_ethertype/u_tbl_vlan/u_tbl_ip/u_tbl_port
//     (field tables), u_tuple (ACL), g_rule[r].u_rule (rule engines),
//     u_combiner (match, MODE, policers, counters, verdicts).
//   * Power-up and after CLEAR_TABLES: MODE = DROP_ALL, every entry invalid,
//     every table, rule and policer disabled: nothing passes until the
//     driver configures the filter.
//   * Derived timing (all localparams, from the stage counts in
//     rtlnet_classifier_pkg): WIN = max(TABLE_ENTRIES, TUPLE_ENTRIES) /
//     TABLE_LANES table words per frame; VERDICT_LATENCY = clocks from the
//     last compared beat entering the line to its verdict at the queue head;
//     DELAY_BEATS = MATCH_DEPTH_BYTES / 8 + VERDICT_LATENCY. A gap-free
//     frame leaves m_axis DELAY_BEATS + 2 clocks after s_axis accepted it
//     (ingress register and output slice).
//   * Throughput: one beat per clock; consecutive judged frames must be at
//     least JUDGE_GAP = max(WIN, POLICE_GAP) clocks apart, which every frame
//     of 57 bytes or more guarantees when WIN <= 8 (checked at elaboration);
//     a shorter frame judged too soon after the previous one is dropped and
//     counted (OVERRUN_DROPPED).
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks:
//   * axis_clk: frame path, engines, register file (AXIS_CLK_HZ).
//   * s_axi_aclk: AXI4-Lite slave side of the register crossing only.
//   Resets synchronous to their clocks, active low, asserted together.
// -----------------------------------------------------------------------------
module rtlnet_classifier #(
  parameter int    AXIS_CLK_HZ       = 100_000_000,  // stream clock (policer millisecond tick)
  parameter int    TABLE_ENTRIES     = 16,           // entries per field table: 2, 4, 8, 16
  parameter int    TUPLE_ENTRIES     = 16,           // tuple entries: 2, 4, 8, 16
  parameter int    TABLE_LANES       = 2,            // entries compared per clock: 2 or 4
  parameter int    NUM_RULES         = 2,            // positional rule engines: 1..4
  parameter int    NUM_POLICERS      = 4,            // policers: 1..4
  parameter int    MATCH_DEPTH_BYTES = 64,           // bytes judged by the rules, 40..256, multiple of 8
  parameter string RAM_STYLE         = "block"       // tables and buffers: "block" | "distributed"
)(
  // Stream clock (AXIS_CLK_HZ) and its synchronous active-low reset.
  input  logic        axis_clk,
  input  logic        axis_resetn,

  // Register clock (CPU AXI4-Lite) and its synchronous active-low reset.
  input  logic        s_axi_aclk,
  input  logic        s_axi_aresetn,

  // Frames in, axis_clk: RTLNet stream, byte 0 in tdata[7:0], tkeep
  // contiguous on the final beat; s_axis_tready is a flop.
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // Frames out, axis_clk: the passed frames, unmodified, every output a flop
  // (rtlnet_axis_reg_slice).
  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  // AXI4-Lite register slave, s_axi_aclk, 4 KiB window (12-bit byte offset).
  input  logic [11:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [11:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // Verdict events, axis_clk: one single-clock pulse per frame decision.
  output logic        ev_pass,
  output logic        ev_drop
);

  import rtlnet_classifier_pkg::*;

  // ---------------------------------------------------------------------------
  // Derived parameters.
  // ---------------------------------------------------------------------------
  localparam int M            = MATCH_DEPTH_BYTES / 8;
  localparam int IDX_W        = rtlnet_pkg::clog2i(M + 1);
  localparam int SCAN_FIELD   = TABLE_ENTRIES / TABLE_LANES;
  localparam int SCAN_TUPLE   = TUPLE_ENTRIES / TABLE_LANES;
  localparam int WIN          = (SCAN_FIELD > SCAN_TUPLE) ? SCAN_FIELD : SCAN_TUPLE;
  localparam int JUDGE_GAP    = (WIN > POLICE_GAP) ? WIN : POLICE_GAP;
  localparam int SNAP_OFFSET  = TAP_STAGES + CAPTURE_STAGES + SNAPSHOT_STAGES;
  localparam int K_RULE       = TAP_STAGES + RULE_STAGES - SNAP_OFFSET;
  localparam int K_TAB        = (WIN - 1) + TABLE_STAGES;
  localparam int VERDICT_LATENCY = SNAP_OFFSET + K_TAB + COMB_STAGES + POLICE_STAGES + QUEUE_STAGES;
  localparam int DELAY_BEATS  = M + VERDICT_LATENCY;
  localparam int QUEUE_DEPTH  = DELAY_BEATS;
  localparam int MATCH_P2     = 1 << rtlnet_pkg::clog2i(MATCH_DEPTH_BYTES);
  localparam int STRIDE_WORDS = (MATCH_P2 > 64) ? MATCH_P2 : 64;   // RULE_STRIDE / 4
  localparam int TICKS_PER_MS = AXIS_CLK_HZ / 1000;

  generate
    if ((MATCH_DEPTH_BYTES % 8) != 0 || MATCH_DEPTH_BYTES < 40 || MATCH_DEPTH_BYTES > 256) begin : g_bad_depth
      $fatal(1, "rtlnet_classifier: MATCH_DEPTH_BYTES=%0d, must be a multiple of 8 in 40..256", MATCH_DEPTH_BYTES);
    end
    if (TABLE_LANES != 2 && TABLE_LANES != 4) begin : g_bad_lanes
      $fatal(1, "rtlnet_classifier: TABLE_LANES=%0d, must be 2 or 4", TABLE_LANES);
    end
    if (NUM_RULES < 1 || NUM_RULES > MAX_RULES || NUM_RULES * STRIDE_WORDS > 256) begin : g_bad_rules
      $fatal(1, "rtlnet_classifier: NUM_RULES=%0d does not fit the rule window at %0d bytes", NUM_RULES,
             MATCH_DEPTH_BYTES);
    end
    if (NUM_POLICERS < 1 || NUM_POLICERS > MAX_POLICERS) begin : g_bad_pol
      $fatal(1, "rtlnet_classifier: NUM_POLICERS=%0d, must be 1..%0d", NUM_POLICERS, MAX_POLICERS);
    end
    if (TICKS_PER_MS < 4) begin : g_bad_clk
      $fatal(1, "rtlnet_classifier: AXIS_CLK_HZ=%0d, must be at least 4000", AXIS_CLK_HZ);
    end
    // Line rate: back-to-back 60-byte frames at one beat per clock are judged
    // MIN_FRAME_BEATS clocks apart; the tables must finish a frame in that time.
    if (WIN > MIN_FRAME_BEATS) begin : g_bad_rate
      $fatal(1, "rtlnet_classifier: %0d table words per frame exceed %0d clocks per minimum frame; raise TABLE_LANES",
             WIN, MIN_FRAME_BEATS);
    end
    // The verdict must be at the queue head before the frame's first beat
    // leaves the delay line.
    if (DELAY_BEATS < M + VERDICT_LATENCY || DELAY_BEATS < 3) begin : g_bad_delay
      $fatal(1, "rtlnet_classifier: DELAY_BEATS=%0d below MATCH_BEATS + VERDICT_LATENCY", DELAY_BEATS);
    end
    if (K_RULE < 1 || K_RULE >= K_TAB) begin : g_bad_align
      $fatal(1, "rtlnet_classifier: rule results (stage %0d) not ahead of table results (stage %0d)", K_RULE,
             K_TAB);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Signals.
  // ---------------------------------------------------------------------------
  logic [1:0]                       cfg_mode;
  logic [5:0][7:0]                  cfg_table_mode;
  logic [NUM_RULES-1:0][7:0]        cfg_rule_mode;
  logic [MAX_POLICERS-1:0]          cfg_pol_en;
  logic [MAX_POLICERS-1:0][31:0]    cfg_pol_limit;
  logic [MAX_POLICERS-1:0][31:0]    cfg_pol_window;
  logic [MAX_POLICERS-1:0]          cfg_pol_restart;
  logic                             cnt_clear;
  logic                             cw_en;
  logic [9:0]                       cw_addr;
  logic [31:0]                      cw_data;
  logic                             clr_active;
  logic [9:0]                       clr_addr;
  logic [NUM_COUNTERS-1:0][31:0]    cnt;
  logic [MAX_POLICERS-1:0][31:0]    pol_seen;
  logic [MAX_POLICERS-1:0][31:0]    pol_passed;
  logic [MAX_POLICERS-1:0][31:0]    pol_dropped;
  logic [MAX_POLICERS-1:0][31:0]    pol_budget;
  logic                             stall_event;

  logic                             tap_valid;
  logic [63:0]                      tap_data;
  logic [7:0]                       tap_keep;
  logic                             tap_last;
  logic [IDX_W-1:0]                 tap_idx;
  logic                             tap_first;
  logic                             tap_judge;
  logic                             v_push;
  logic                             v_pass;

  logic [5:0]                       aware_q;
  logic                             vlan_mask_q;
  logic                             judge_acc;
  logic                             judge_ovr;
  logic [47:0]                      f_mac_src;
  logic [47:0]                      f_mac_dst;
  logic                             f_mac_sp;
  logic                             f_mac_dp;
  logic [15:0]                      f_et;
  logic                             f_et_p;
  logic [14:0]                      f_vlan;
  logic                             f_vlan_p;
  logic [31:0]                      f_ip_src;
  logic [31:0]                      f_ip_dst;
  logic                             f_ip_sp;
  logic                             f_ip_dp;
  logic [15:0]                      f_port_src;
  logic [15:0]                      f_port_dst;
  logic                             f_port_sp;
  logic                             f_port_dp;
  logic [7:0]                       f_port_proto;
  logic [7:0]                       f_tu_proto;
  logic [31:0]                      f_tu_sip;
  logic [31:0]                      f_tu_dip;
  logic [15:0]                      f_tu_sport;
  logic [15:0]                      f_tu_dport;
  logic                             f_tu_ip;
  logic                             f_tu_l4;

  logic [5:0]                       tbl_hit;
  logic [5:0]                       tbl_pf;
  logic [5:0][1:0]                  tbl_pol;
  logic [5:0]                       tbl_done;
  logic [NUM_RULES-1:0]             rule_match;
  logic [NUM_RULES-1:0]             rule_done;

  // ---------------------------------------------------------------------------
  // Register file.
  // ---------------------------------------------------------------------------
  rtlnet_classifier_regs #(
    .TABLE_ENTRIES     (TABLE_ENTRIES),
    .TUPLE_ENTRIES     (TUPLE_ENTRIES),
    .NUM_RULES         (NUM_RULES),
    .NUM_POLICERS      (NUM_POLICERS),
    .TABLE_LANES       (TABLE_LANES),
    .MATCH_DEPTH_BYTES (MATCH_DEPTH_BYTES),
    .STRIDE_WORDS      (STRIDE_WORDS),
    .DELAY_BEATS       (DELAY_BEATS),
    .VERDICT_LATENCY   (VERDICT_LATENCY),
    .RAM_STYLE         (RAM_STYLE)
  ) u_regs (
    .s_axi_aclk      (s_axi_aclk),
    .s_axi_aresetn   (s_axi_aresetn),
    .s_axi_awaddr    (s_axi_awaddr),
    .s_axi_awvalid   (s_axi_awvalid),
    .s_axi_awready   (s_axi_awready),
    .s_axi_wdata     (s_axi_wdata),
    .s_axi_wstrb     (s_axi_wstrb),
    .s_axi_wvalid    (s_axi_wvalid),
    .s_axi_wready    (s_axi_wready),
    .s_axi_bresp     (s_axi_bresp),
    .s_axi_bvalid    (s_axi_bvalid),
    .s_axi_bready    (s_axi_bready),
    .s_axi_araddr    (s_axi_araddr),
    .s_axi_arvalid   (s_axi_arvalid),
    .s_axi_arready   (s_axi_arready),
    .s_axi_rdata     (s_axi_rdata),
    .s_axi_rresp     (s_axi_rresp),
    .s_axi_rvalid    (s_axi_rvalid),
    .s_axi_rready    (s_axi_rready),
    .clk             (axis_clk),
    .resetn          (axis_resetn),
    .cfg_mode        (cfg_mode),
    .cfg_table_mode  (cfg_table_mode),
    .cfg_rule_mode   (cfg_rule_mode),
    .cfg_pol_en      (cfg_pol_en),
    .cfg_pol_limit   (cfg_pol_limit),
    .cfg_pol_window  (cfg_pol_window),
    .cfg_pol_restart (cfg_pol_restart),
    .cnt_clear       (cnt_clear),
    .cw_en           (cw_en),
    .cw_addr         (cw_addr),
    .cw_data         (cw_data),
    .clr_active      (clr_active),
    .clr_addr        (clr_addr),
    .cnt             (cnt),
    .pol_seen        (pol_seen),
    .pol_passed      (pol_passed),
    .pol_dropped     (pol_dropped),
    .pol_budget      (pol_budget),
    .stall_event     (stall_event)
  );

  // ---------------------------------------------------------------------------
  // Frame path: ingress, delay line, verdict queue, gate, output slice.
  // ---------------------------------------------------------------------------
  rtlnet_classifier_line #(
    .DELAY_BEATS (DELAY_BEATS),
    .MATCH_BEATS (M),
    .QUEUE_DEPTH (QUEUE_DEPTH),
    .IDX_W       (IDX_W)
  ) u_line (
    .clk           (axis_clk),
    .resetn        (axis_resetn),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tkeep  (s_axis_tkeep),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tlast  (s_axis_tlast),
    .s_axis_tready (s_axis_tready),
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tkeep  (m_axis_tkeep),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tlast  (m_axis_tlast),
    .m_axis_tready (m_axis_tready),
    .tap_valid     (tap_valid),
    .tap_data      (tap_data),
    .tap_keep      (tap_keep),
    .tap_last      (tap_last),
    .tap_idx       (tap_idx),
    .tap_first     (tap_first),
    .tap_judge     (tap_judge),
    .v_push        (v_push),
    .v_pass        (v_pass),
    .stall_event   (stall_event)
  );

  // ---------------------------------------------------------------------------
  // Field extractor.
  // ---------------------------------------------------------------------------
  // Local copies of the VLAN-aware bits and the VLAN compare mode.
  always_ff @(posedge axis_clk) begin
    if (!axis_resetn) begin
      aware_q     <= '0;
      vlan_mask_q <= 1'b0;
    end else begin
      for (int t = 0; t < 6; t++) aware_q[t] <= cfg_table_mode[t][TM_VLAN_AWARE];
      vlan_mask_q <= (cfg_table_mode[TBL_VLAN][TM_COMPARE_LSB +: 2] == CMP_MASK);
    end
  end

  rtlnet_classifier_extract #(
    .MATCH_BEATS (M),
    .IDX_W       (IDX_W),
    .JUDGE_GAP   (JUDGE_GAP)
  ) u_extract (
    .clk           (axis_clk),
    .resetn        (axis_resetn),
    .tap_valid     (tap_valid),
    .tap_data      (tap_data),
    .tap_keep      (tap_keep),
    .tap_idx       (tap_idx),
    .tap_first     (tap_first),
    .tap_judge     (tap_judge),
    .cfg_aware     (aware_q),
    .cfg_vlan_mask (vlan_mask_q),
    .judge_acc     (judge_acc),
    .judge_ovr     (judge_ovr),
    .f_mac_src     (f_mac_src),
    .f_mac_dst     (f_mac_dst),
    .f_mac_sp      (f_mac_sp),
    .f_mac_dp      (f_mac_dp),
    .f_et          (f_et),
    .f_et_p        (f_et_p),
    .f_vlan        (f_vlan),
    .f_vlan_p      (f_vlan_p),
    .f_ip_src      (f_ip_src),
    .f_ip_dst      (f_ip_dst),
    .f_ip_sp       (f_ip_sp),
    .f_ip_dp       (f_ip_dp),
    .f_port_src    (f_port_src),
    .f_port_dst    (f_port_dst),
    .f_port_sp     (f_port_sp),
    .f_port_dp     (f_port_dp),
    .f_port_proto  (f_port_proto),
    .f_tu_proto    (f_tu_proto),
    .f_tu_sip      (f_tu_sip),
    .f_tu_dip      (f_tu_dip),
    .f_tu_sport    (f_tu_sport),
    .f_tu_dport    (f_tu_dport),
    .f_tu_ip       (f_tu_ip),
    .f_tu_l4       (f_tu_l4)
  );

  // ---------------------------------------------------------------------------
  // Field tables.
  // ---------------------------------------------------------------------------
  // MAC: 48-bit source and destination MAC.
  rtlnet_classifier_table #(
    .TABLE_IDX (TBL_MAC), .FW (48), .HAS_DST (1'b1), .HAS_PROTO (1'b0),
    .ENTRIES (TABLE_ENTRIES), .LANES (TABLE_LANES), .WIN (WIN), .RAM_STYLE (RAM_STYLE)
  ) u_tbl_mac (
    .clk (axis_clk), .resetn (axis_resetn),
    .cw_en (cw_en), .cw_addr (cw_addr), .cw_data (cw_data), .clr_active (clr_active), .clr_addr (clr_addr),
    .cfg_compare (cfg_table_mode[TBL_MAC][TM_COMPARE_LSB +: 2]),
    .win_start (judge_acc), .f_src (f_mac_src), .f_dst (f_mac_dst), .f_sp (f_mac_sp), .f_dp (f_mac_dp),
    .f_proto (8'h00),
    .res_hit (tbl_hit[TBL_MAC]), .res_pf (tbl_pf[TBL_MAC]), .res_pol (tbl_pol[TBL_MAC]),
    .res_done (tbl_done[TBL_MAC])
  );

  // ETHERTYPE: 16-bit EtherType, source side only.
  rtlnet_classifier_table #(
    .TABLE_IDX (TBL_ETHERTYPE), .FW (16), .HAS_DST (1'b0), .HAS_PROTO (1'b0),
    .ENTRIES (TABLE_ENTRIES), .LANES (TABLE_LANES), .WIN (WIN), .RAM_STYLE (RAM_STYLE)
  ) u_tbl_ethertype (
    .clk (axis_clk), .resetn (axis_resetn),
    .cw_en (cw_en), .cw_addr (cw_addr), .cw_data (cw_data), .clr_active (clr_active), .clr_addr (clr_addr),
    .cfg_compare (cfg_table_mode[TBL_ETHERTYPE][TM_COMPARE_LSB +: 2]),
    .win_start (judge_acc), .f_src (f_et), .f_dst (16'h0000), .f_sp (f_et_p), .f_dp (1'b0),
    .f_proto (8'h00),
    .res_hit (tbl_hit[TBL_ETHERTYPE]), .res_pf (tbl_pf[TBL_ETHERTYPE]), .res_pol (tbl_pol[TBL_ETHERTYPE]),
    .res_done (tbl_done[TBL_ETHERTYPE])
  );

  // VLAN: {PCP, VID} (data/mask) or VID, source side only, tagged frames.
  rtlnet_classifier_table #(
    .TABLE_IDX (TBL_VLAN), .FW (15), .HAS_DST (1'b0), .HAS_PROTO (1'b0),
    .ENTRIES (TABLE_ENTRIES), .LANES (TABLE_LANES), .WIN (WIN), .RAM_STYLE (RAM_STYLE)
  ) u_tbl_vlan (
    .clk (axis_clk), .resetn (axis_resetn),
    .cw_en (cw_en), .cw_addr (cw_addr), .cw_data (cw_data), .clr_active (clr_active), .clr_addr (clr_addr),
    .cfg_compare (cfg_table_mode[TBL_VLAN][TM_COMPARE_LSB +: 2]),
    .win_start (judge_acc), .f_src (f_vlan), .f_dst (15'h0000), .f_sp (f_vlan_p), .f_dp (1'b0),
    .f_proto (8'h00),
    .res_hit (tbl_hit[TBL_VLAN]), .res_pf (tbl_pf[TBL_VLAN]), .res_pol (tbl_pol[TBL_VLAN]),
    .res_done (tbl_done[TBL_VLAN])
  );

  // IP: source and destination IPv4.
  rtlnet_classifier_table #(
    .TABLE_IDX (TBL_IP), .FW (32), .HAS_DST (1'b1), .HAS_PROTO (1'b0),
    .ENTRIES (TABLE_ENTRIES), .LANES (TABLE_LANES), .WIN (WIN), .RAM_STYLE (RAM_STYLE)
  ) u_tbl_ip (
    .clk (axis_clk), .resetn (axis_resetn),
    .cw_en (cw_en), .cw_addr (cw_addr), .cw_data (cw_data), .clr_active (clr_active), .clr_addr (clr_addr),
    .cfg_compare (cfg_table_mode[TBL_IP][TM_COMPARE_LSB +: 2]),
    .win_start (judge_acc), .f_src (f_ip_src), .f_dst (f_ip_dst), .f_sp (f_ip_sp), .f_dp (f_ip_dp),
    .f_proto (8'h00),
    .res_hit (tbl_hit[TBL_IP]), .res_pf (tbl_pf[TBL_IP]), .res_pol (tbl_pol[TBL_IP]),
    .res_done (tbl_done[TBL_IP])
  );

  // PORT: source and destination L4 port, protocol qualifier.
  rtlnet_classifier_table #(
    .TABLE_IDX (TBL_PORT), .FW (16), .HAS_DST (1'b1), .HAS_PROTO (1'b1),
    .ENTRIES (TABLE_ENTRIES), .LANES (TABLE_LANES), .WIN (WIN), .RAM_STYLE (RAM_STYLE)
  ) u_tbl_port (
    .clk (axis_clk), .resetn (axis_resetn),
    .cw_en (cw_en), .cw_addr (cw_addr), .cw_data (cw_data), .clr_active (clr_active), .clr_addr (clr_addr),
    .cfg_compare (cfg_table_mode[TBL_PORT][TM_COMPARE_LSB +: 2]),
    .win_start (judge_acc), .f_src (f_port_src), .f_dst (f_port_dst), .f_sp (f_port_sp), .f_dp (f_port_dp),
    .f_proto (f_port_proto),
    .res_hit (tbl_hit[TBL_PORT]), .res_pf (tbl_pf[TBL_PORT]), .res_pol (tbl_pol[TBL_PORT]),
    .res_done (tbl_done[TBL_PORT])
  );

  // ---------------------------------------------------------------------------
  // Tuple (ACL) table.
  // ---------------------------------------------------------------------------
  rtlnet_classifier_tuple #(
    .ENTRIES (TUPLE_ENTRIES), .LANES (TABLE_LANES), .WIN (WIN), .RAM_STYLE (RAM_STYLE)
  ) u_tuple (
    .clk (axis_clk), .resetn (axis_resetn),
    .cw_en (cw_en), .cw_addr (cw_addr), .cw_data (cw_data), .clr_active (clr_active), .clr_addr (clr_addr),
    .win_start (judge_acc), .f_proto (f_tu_proto), .f_sip (f_tu_sip), .f_dip (f_tu_dip),
    .f_sport (f_tu_sport), .f_dport (f_tu_dport), .f_ip (f_tu_ip), .f_l4 (f_tu_l4),
    .res_hit (tbl_hit[TBL_TUPLE]), .res_pf (tbl_pf[TBL_TUPLE]), .res_pol (tbl_pol[TBL_TUPLE]),
    .res_done (tbl_done[TBL_TUPLE])
  );

  // ---------------------------------------------------------------------------
  // Rule engines.
  // ---------------------------------------------------------------------------
  genvar gr;
  generate
    for (gr = 0; gr < NUM_RULES; gr++) begin : g_rule
      // Positional byte rule gr.
      rtlnet_classifier_rule #(
        .RULE_IDX (gr), .MATCH_BEATS (M), .IDX_W (IDX_W), .STRIDE_WORDS (STRIDE_WORDS),
        .RAM_STYLE (RAM_STYLE)
      ) u_rule (
        .clk (axis_clk), .resetn (axis_resetn),
        .cw_en (cw_en), .cw_addr (cw_addr), .cw_data (cw_data), .clr_active (clr_active), .clr_addr (clr_addr),
        .tap_valid (tap_valid), .tap_data (tap_data), .tap_keep (tap_keep), .tap_idx (tap_idx),
        .tap_first (tap_first), .tap_judge (tap_judge),
        .r_match (rule_match[gr]), .r_done (rule_done[gr])
      );
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Combiner, policers, counters.
  // ---------------------------------------------------------------------------
  rtlnet_classifier_combiner #(
    .NUM_RULES    (NUM_RULES),
    .NUM_POLICERS (NUM_POLICERS),
    .K_RULE       (K_RULE),
    .K_TAB        (K_TAB),
    .TICKS_PER_MS (TICKS_PER_MS)
  ) u_combiner (
    .clk             (axis_clk),
    .resetn          (axis_resetn),
    .judge_acc       (judge_acc),
    .judge_ovr       (judge_ovr),
    .tbl_hit         (tbl_hit),
    .tbl_pf          (tbl_pf),
    .tbl_pol         (tbl_pol),
    .tbl_done        (tbl_done),
    .rule_match      (rule_match),
    .rule_done       (rule_done),
    .cfg_mode        (cfg_mode),
    .cfg_table_mode  (cfg_table_mode),
    .cfg_rule_mode   (cfg_rule_mode),
    .cfg_pol_en      (cfg_pol_en),
    .cfg_pol_limit   (cfg_pol_limit),
    .cfg_pol_window  (cfg_pol_window),
    .cfg_pol_restart (cfg_pol_restart),
    .cnt_clear       (cnt_clear),
    .v_push          (v_push),
    .v_pass          (v_pass),
    .ev_pass         (ev_pass),
    .ev_drop         (ev_drop),
    .cnt             (cnt),
    .pol_seen        (pol_seen),
    .pol_passed      (pol_passed),
    .pol_dropped     (pol_dropped),
    .pol_budget      (pol_budget)
  );

endmodule
