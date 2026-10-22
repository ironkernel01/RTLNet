// -----------------------------------------------------------------------------
// File: rtlnet_classifier_combiner.sv
// Purpose: decision stage of rtlnet_classifier: combines the table and rule
//   results of each frame into match, applies the global MODE and the
//   policers, emits one verdict per frame in frame order, and keeps every
//   statistics counter.
// Overview:
//   * Token pipeline: one token per judged frame (accepted or overrun),
//     created in the clock the table snapshot becomes valid. The rule
//     results join the token at stage K_RULE, the table results are read at
//     stage K_TAB, both fixed by the engines' stage counts.
//   * Match (section 6.1 of the core specification): AND over every enabled
//     non-classify table of hit (EXCLUDE: !hit), AND the rule contribution:
//     with no enabled gating rule 1; when every enabled gating rule is an
//     exclude rule the AND of their !match; otherwise the OR of the
//     contributions (match, or !match for an exclude rule).
//   * MODE: 00 drop all, 01 pass all, 10 pass on match, 11 drop on match.
//     An overrun frame (judged while the tables were busy) is dropped.
//   * Policing: a frame the mode passes is policed when an enabled rule or
//     table hit with POLICE_EN; the first such hit in priority order (rules
//     0.., tuple table, MAC, ETHERTYPE, VLAN, IP, PORT; inside a table the
//     lowest entry) selects the policer. A disabled or unbuilt policer
//     passes; an enabled one passes while its budget is above zero and
//     decrements it, else drops.
//   * Policer p: per-policer millisecond prescaler (TICKS_PER_MS clocks) and
//     millisecond counter; the budget reloads to LIMIT_PKTS at the start of
//     every WINDOW_MS window (0 acts as 1); restart (a write to the
//     policer's CTRL, LIMIT_PKTS or WINDOW_MS) reloads the budget and starts
//     a new window. The budget, nonzero flag and blocking flag are
//     registered separately, so decisions must be POLICE_GAP clocks apart
//     (guaranteed by the judge acceptance in the extractor).
//   * Timing: contributions (K1), AND/OR tree and two priority groups (K2),
//     mode and final priority (K3), policer decision (P1): COMB_STAGES +
//     POLICE_STAGES registers; v_push / v_pass, ev_pass / ev_drop are flops.
//   * Counters (32-bit, wrap, cleared by cnt_clear): FRAMES, PASSED, DROPPED,
//     MODE_DROPPED, POLICE_DROPPED, TABLE_HIT[6], RULE_HIT[NUM_RULES],
//     OVERRUN_DROPPED; per policer SEEN, PASSED, DROPPED. A hit counter
//     counts the judged frames that hit the enabled table or matched the
//     enabled rule (overrun frames are not judged and count only as
//     OVERRUN_DROPPED). FRAMES = PASSED + DROPPED and DROPPED =
//     MODE_DROPPED + POLICE_DROPPED + OVERRUN_DROPPED; SEEN = PASSED +
//     DROPPED per policer.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (axis_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_classifier_combiner #(
  parameter int NUM_RULES    = 2,          // 1..4
  parameter int NUM_POLICERS = 4,          // 1..4
  parameter int K_RULE       = 5,          // token stage at which rule results are valid
  parameter int K_TAB        = 14,         // token stage at which table results are valid
  parameter int TICKS_PER_MS = 100000      // axis_clk clocks per millisecond, >= 4
)(
  // Stream clock and synchronous active-low reset.
  input  logic                                    clk,
  input  logic                                    resetn,

  // Judged frames from the extractor (pulses).
  input  logic                                    judge_acc,
  input  logic                                    judge_ovr,

  // Table results, index 0 MAC .. 4 PORT, 5 TUPLE.
  input  logic [5:0]                              tbl_hit,
  input  logic [5:0]                              tbl_pf,
  input  logic [5:0][1:0]                         tbl_pol,
  input  logic [5:0]                              tbl_done,

  // Rule results (raw match).
  input  logic [NUM_RULES-1:0]                    rule_match,
  input  logic [NUM_RULES-1:0]                    rule_done,

  // Configuration (registered copies from the register file).
  input  logic [1:0]                              cfg_mode,
  input  logic [5:0][7:0]                         cfg_table_mode,
  input  logic [NUM_RULES-1:0][7:0]               cfg_rule_mode,
  input  logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0]       cfg_pol_en,
  input  logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] cfg_pol_limit,
  input  logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] cfg_pol_window,
  input  logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0]       cfg_pol_restart,
  input  logic                                    cnt_clear,

  // Verdicts to the delay line, one per frame in frame order.
  output logic                                    v_push,
  output logic                                    v_pass,

  // Event pulses (one per verdict).
  output logic                                    ev_pass,
  output logic                                    ev_drop,

  // Counters for the register file.
  output logic [rtlnet_classifier_pkg::NUM_COUNTERS-1:0][31:0] cnt,
  output logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] pol_seen,
  output logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] pol_passed,
  output logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] pol_dropped,
  output logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] pol_budget
);

  import rtlnet_classifier_pkg::*;

  localparam int R  = NUM_RULES;
  localparam int P  = MAX_POLICERS;
  localparam int PW = rtlnet_pkg::clog2i(TICKS_PER_MS);
  localparam logic [PW-1:0] PRE_LOAD = TICKS_PER_MS - 1;
  localparam logic [PW-1:0] PRE_ONE  = 1;

  generate
    if (R < 1 || R > MAX_RULES) begin : g_bad_rules
      $fatal(1, "rtlnet_classifier_combiner: NUM_RULES=%0d, must be 1..%0d", R, MAX_RULES);
    end
    if (NUM_POLICERS < 1 || NUM_POLICERS > MAX_POLICERS) begin : g_bad_pol
      $fatal(1, "rtlnet_classifier_combiner: NUM_POLICERS=%0d, must be 1..%0d", NUM_POLICERS, MAX_POLICERS);
    end
    if (K_RULE < 1 || K_TAB <= K_RULE) begin : g_bad_k
      $fatal(1, "rtlnet_classifier_combiner: K_RULE=%0d, K_TAB=%0d out of order", K_RULE, K_TAB);
    end
    if (TICKS_PER_MS < 4) begin : g_bad_ticks
      $fatal(1, "rtlnet_classifier_combiner: TICKS_PER_MS=%0d, must be at least 4", TICKS_PER_MS);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Local configuration copies.
  // ---------------------------------------------------------------------------
  logic [1:0]          mode_q;
  logic [5:0]          t_en;
  logic [5:0]          t_ex;
  logic [5:0]          t_cls;
  logic [R-1:0]        r_en;
  logic [R-1:0]        r_ex;
  logic [R-1:0]        r_cls;
  logic [R-1:0]        r_pe;
  logic [R-1:0][1:0]   r_pol;
  logic                any_g;
  logic                all_excl;
  logic [P-1:0]        pen_q;

  // Configuration registered locally; rule-combination flags derived from it.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      mode_q   <= MODE_DROP_ALL;
      t_en     <= '0;
      t_ex     <= '0;
      t_cls    <= '0;
      r_en     <= '0;
      r_ex     <= '0;
      r_cls    <= '0;
      r_pe     <= '0;
      r_pol    <= '0;
      any_g    <= 1'b0;
      all_excl <= 1'b0;
      pen_q    <= '0;
    end else begin
      mode_q <= cfg_mode;
      for (int t = 0; t < 6; t++) begin
        t_en[t]  <= cfg_table_mode[t][TM_ENABLE];
        t_ex[t]  <= cfg_table_mode[t][TM_EXCLUDE];
        t_cls[t] <= cfg_table_mode[t][TM_CLASSIFY];
      end
      for (int r = 0; r < R; r++) begin
        r_en[r]  <= cfg_rule_mode[r][RM_ENABLE];
        r_ex[r]  <= cfg_rule_mode[r][RM_EXCLUDE];
        r_cls[r] <= cfg_rule_mode[r][RM_CLASSIFY];
        r_pe[r]  <= cfg_rule_mode[r][RM_POLICE_EN];
        r_pol[r] <= cfg_rule_mode[r][RM_POLICER_LSB +: 2];
      end
      any_g    <= |(r_en & ~r_cls);
      all_excl <= &(~(r_en & ~r_cls) | r_ex);
      for (int p = 0; p < P; p++) pen_q[p] <= (p < NUM_POLICERS) && cfg_pol_en[p];
    end
  end

  // ---------------------------------------------------------------------------
  // Token pipeline: stage k valid k clocks after the snapshot.
  // ---------------------------------------------------------------------------
  logic                        tok_v0;
  logic [K_TAB:1]              tok_v;
  logic [K_TAB:1]              tok_ovr;
  logic [K_TAB:K_RULE+1][R-1:0] tok_rm;

  assign tok_v0 = judge_acc || judge_ovr;

  // Token shift register; the rule results join at stage K_RULE.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      tok_v   <= '0;
      tok_ovr <= '0;
      tok_rm  <= '0;
    end else begin
      tok_v[1]   <= tok_v0;
      tok_ovr[1] <= judge_ovr;
      for (int k = 2; k <= K_TAB; k++) begin
        tok_v[k]   <= tok_v[k-1];
        tok_ovr[k] <= tok_ovr[k-1];
      end
      tok_rm[K_RULE+1] <= rule_match;
      for (int k = K_RULE + 2; k <= K_TAB; k++) tok_rm[k] <= tok_rm[k-1];
    end
  end

  // ---------------------------------------------------------------------------
  // K1: per-engine contributions.
  // ---------------------------------------------------------------------------
  logic                k1_v;
  logic                k1_ovr;
  logic [5:0]          k1_term;
  logic [5:0]          k1_thit;
  logic [5:0]          k1_tpf;
  logic [5:0][1:0]     k1_tpol;
  logic [R-1:0]        k1_inc;
  logic [R-1:0]        k1_ok;
  logic [R-1:0]        k1_rhit;
  logic [R-1:0]        k1_rpf;
  logic [R-1:0][1:0]   k1_rpol;
  logic [R-1:0]        rm_now;

  assign rm_now = tok_rm[K_TAB];

  always_ff @(posedge clk) begin
    if (!resetn) begin
      k1_v    <= 1'b0;
      k1_ovr  <= 1'b0;
      k1_term <= '0;
      k1_thit <= '0;
      k1_tpf  <= '0;
      k1_tpol <= '0;
      k1_inc  <= '0;
      k1_ok   <= '0;
      k1_rhit <= '0;
      k1_rpf  <= '0;
      k1_rpol <= '0;
    end else begin
      k1_v   <= tok_v[K_TAB];
      k1_ovr <= tok_ovr[K_TAB];
      for (int t = 0; t < 6; t++) begin
        k1_term[t] <= !(t_en[t] && !t_cls[t]) || (tbl_hit[t] != t_ex[t]);
        k1_thit[t] <= t_en[t] && tbl_hit[t];
        k1_tpf[t]  <= t_en[t] && tbl_pf[t];
        k1_tpol[t] <= tbl_pol[t];
      end
      for (int r = 0; r < R; r++) begin
        k1_inc[r]  <= (r_en[r] && !r_cls[r]) && (rm_now[r] != r_ex[r]);
        k1_ok[r]   <= !(r_en[r] && !r_cls[r]) || (rm_now[r] != r_ex[r]);
        k1_rhit[r] <= r_en[r] && rm_now[r];
        k1_rpf[r]  <= r_en[r] && r_pe[r] && rm_now[r];
        k1_rpol[r] <= r_pol[r];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // K2: AND/OR tree; policer priority in two groups.
  // ---------------------------------------------------------------------------
  logic                k2_v;
  logic                k2_ovr;
  logic                k2_tand;
  logic                k2_rc;
  logic                k2_fa;
  logic [1:0]          k2_pa;
  logic                k2_fb;
  logic [1:0]          k2_pb;
  logic [5:0]          k2_thit;
  logic [R-1:0]        k2_rhit;
  logic                fa_c;
  logic [1:0]          pa_c;
  logic                fb_c;
  logic [1:0]          pb_c;

  // Group A: rules 0..R-1 then the tuple table; group B: MAC .. PORT.
  always_comb begin
    fa_c = k1_tpf[TBL_TUPLE];
    pa_c = k1_tpol[TBL_TUPLE];
    for (int r = R - 1; r >= 0; r--) begin
      if (k1_rpf[r]) begin
        fa_c = 1'b1;
        pa_c = k1_rpol[r];
      end
    end
    fb_c = 1'b0;
    pb_c = k1_tpol[TBL_PORT];
    for (int t = NUM_FIELD_TABLES - 1; t >= 0; t--) begin
      if (k1_tpf[t]) begin
        fb_c = 1'b1;
        pb_c = k1_tpol[t];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      k2_v    <= 1'b0;
      k2_ovr  <= 1'b0;
      k2_tand <= 1'b0;
      k2_rc   <= 1'b0;
      k2_fa   <= 1'b0;
      k2_pa   <= '0;
      k2_fb   <= 1'b0;
      k2_pb   <= '0;
      k2_thit <= '0;
      k2_rhit <= '0;
    end else begin
      k2_v    <= k1_v;
      k2_ovr  <= k1_ovr;
      k2_tand <= &k1_term;
      k2_rc   <= !any_g || (all_excl ? (&k1_ok) : (|k1_inc));
      k2_fa   <= fa_c;
      k2_pa   <= pa_c;
      k2_fb   <= fb_c;
      k2_pb   <= pb_c;
      k2_thit <= (k1_v && !k1_ovr) ? k1_thit : '0;
      k2_rhit <= (k1_v && !k1_ovr) ? k1_rhit : '0;
    end
  end

  // ---------------------------------------------------------------------------
  // K3: mode; final policer selection.
  // ---------------------------------------------------------------------------
  logic                k3_v;
  logic                k3_ovr;
  logic                k3_pass;
  logic                k3_pf;
  logic [1:0]          k3_pol;
  logic                match_c;

  assign match_c = k2_tand && k2_rc;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      k3_v    <= 1'b0;
      k3_ovr  <= 1'b0;
      k3_pass <= 1'b0;
      k3_pf   <= 1'b0;
      k3_pol  <= '0;
    end else begin
      k3_v   <= k2_v;
      k3_ovr <= k2_ovr;
      case (mode_q)
        MODE_PASS_ALL:      k3_pass <= 1'b1;
        MODE_PASS_ON_MATCH: k3_pass <= match_c;
        MODE_DROP_ON_MATCH: k3_pass <= !match_c;
        default:            k3_pass <= 1'b0;
      endcase
      k3_pf  <= k2_fa || k2_fb;
      k3_pol <= k2_fa ? k2_pa : k2_pb;
    end
  end

  // ---------------------------------------------------------------------------
  // P1: policer decision and verdict.
  // ---------------------------------------------------------------------------
  logic [P-1:0]        pb_q;       // policer enabled and its budget is zero
  logic                p_block;
  logic                p_police;
  logic                fin_pass;
  logic                ev_mode_drop;
  logic                ev_pol_drop;
  logic                ev_ovr;
  logic [P-1:0]        ev_pseen;
  logic [P-1:0]        ev_ppass;
  logic [P-1:0]        ev_pdrop;

  assign p_block  = k3_pf && pb_q[k3_pol];
  assign p_police = k3_v && !k3_ovr && k3_pass && k3_pf && pen_q[k3_pol];
  assign fin_pass = !k3_ovr && k3_pass && !p_block;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      v_push       <= 1'b0;
      v_pass       <= 1'b0;
      ev_pass      <= 1'b0;
      ev_drop      <= 1'b0;
      ev_mode_drop <= 1'b0;
      ev_pol_drop  <= 1'b0;
      ev_ovr       <= 1'b0;
      ev_pseen     <= '0;
      ev_ppass     <= '0;
      ev_pdrop     <= '0;
    end else begin
      v_push       <= k3_v;
      v_pass       <= fin_pass;
      ev_pass      <= k3_v && fin_pass;
      ev_drop      <= k3_v && !fin_pass;
      ev_mode_drop <= k3_v && !k3_ovr && !k3_pass;
      ev_pol_drop  <= k3_v && !k3_ovr && k3_pass && p_block;
      ev_ovr       <= k3_v && k3_ovr;
      for (int p = 0; p < P; p++) begin
        ev_pseen[p] <= p_police && (k3_pol == p);
        ev_ppass[p] <= p_police && (k3_pol == p) && !pb_q[p];
        ev_pdrop[p] <= p_police && (k3_pol == p) && pb_q[p];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Policers.
  // ---------------------------------------------------------------------------
  genvar gp;
  generate
    for (gp = 0; gp < P; gp++) begin : g_pol
      logic [31:0]   limit_q;
      logic [31:0]   win_m1;
      logic          restart_q;
      logic [PW-1:0] pre;
      logic          pz_q;
      logic [31:0]   wc;
      logic [1:0]    wl_part;
      logic          wl_q;
      logic [31:0]   budget;
      logic          nz_q;
      logic          blk_q;
      logic          reload;
      logic [31:0]   seen_c;
      logic [31:0]   passed_c;
      logic [31:0]   dropped_c;

      // Configuration copies: WINDOW_MS 0 acts as 1.
      always_ff @(posedge clk) begin
        if (!resetn) begin
          limit_q   <= '0;
          win_m1    <= '0;
          restart_q <= 1'b0;
        end else begin
          limit_q   <= cfg_pol_limit[gp];
          win_m1    <= (cfg_pol_window[gp] == 32'd0) ? 32'd0 : cfg_pol_window[gp] - 32'd1;
          restart_q <= cfg_pol_restart[gp];
        end
      end

      // Millisecond prescaler (pz_q high in the clock pre is 0) and
      // millisecond counter with a registered, two-stage end-of-window flag.
      always_ff @(posedge clk) begin
        if (!resetn) begin
          pre     <= PRE_LOAD;
          pz_q    <= 1'b0;
          wc      <= '0;
          wl_part <= '0;
          wl_q    <= 1'b0;
        end else begin
          if (restart_q || pz_q) begin
            pre  <= PRE_LOAD;
            pz_q <= 1'b0;
          end else begin
            pre  <= pre - 1'b1;
            pz_q <= (pre == PRE_ONE);
          end
          if (restart_q)          wc <= '0;
          else if (pz_q && wl_q)  wc <= '0;
          else if (pz_q)          wc <= wc + 32'd1;
          wl_part[0] <= (wc[15:0]  == win_m1[15:0]);
          wl_part[1] <= (wc[31:16] == win_m1[31:16]);
          wl_q       <= &wl_part;
        end
      end

      assign reload = restart_q || (pz_q && wl_q);

      // Budget: reloads at each window start, decrements per policed pass;
      // nonzero and blocking flags registered.
      always_ff @(posedge clk) begin
        if (!resetn) begin
          budget <= '0;
          nz_q   <= 1'b0;
          blk_q  <= 1'b0;
        end else begin
          if (reload)                    budget <= limit_q;
          else if (ev_ppass[gp] && nz_q) budget <= budget - 32'd1;
          nz_q  <= (budget != 32'd0);
          blk_q <= pen_q[gp] && !nz_q;
        end
      end

      // Per-policer counters.
      always_ff @(posedge clk) begin
        if (!resetn || cnt_clear) begin
          seen_c    <= '0;
          passed_c  <= '0;
          dropped_c <= '0;
        end else begin
          if (ev_pseen[gp]) seen_c    <= seen_c + 32'd1;
          if (ev_ppass[gp]) passed_c  <= passed_c + 32'd1;
          if (ev_pdrop[gp]) dropped_c <= dropped_c + 32'd1;
        end
      end

      assign pb_q[gp]        = blk_q;
      assign pol_budget[gp]  = budget;
      assign pol_seen[gp]    = seen_c;
      assign pol_passed[gp]  = passed_c;
      assign pol_dropped[gp] = dropped_c;
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Global counters.
  // ---------------------------------------------------------------------------
  logic [NUM_COUNTERS-1:0] cnt_inc;

  // Count events, all registered.
  always_comb begin
    cnt_inc                      = '0;
    cnt_inc[CNT_FRAMES]          = ev_pass || ev_drop;
    cnt_inc[CNT_PASSED]          = ev_pass;
    cnt_inc[CNT_DROPPED]         = ev_drop;
    cnt_inc[CNT_MODE_DROPPED]    = ev_mode_drop;
    cnt_inc[CNT_POLICE_DROPPED]  = ev_pol_drop;
    cnt_inc[CNT_OVERRUN_DROPPED] = ev_ovr;
    for (int t = 0; t < 6; t++) cnt_inc[CNT_TABLE_HIT + t] = k2_thit[t];
    for (int r = 0; r < R; r++) cnt_inc[CNT_RULE_HIT + r]  = k2_rhit[r];
  end

  always_ff @(posedge clk) begin
    if (!resetn || cnt_clear) begin
      cnt <= '0;
    end else begin
      for (int i = 0; i < NUM_COUNTERS; i++) begin
        if (cnt_inc[i]) cnt[i] <= cnt[i] + 32'd1;
      end
    end
  end

  // synthesis translate_off
  // Simulation checks: the engines deliver their results exactly at the
  // token stages the stage counts predict.
  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      if (tok_v[K_RULE] && (rule_done !== {R{1'b1}}))
        $error("rtlnet_classifier_combiner: rule results not aligned with token stage K_RULE");
      if (tok_v[K_TAB] && !tok_ovr[K_TAB] && (tbl_done[0] !== 1'b1))
        $error("rtlnet_classifier_combiner: table results not aligned with token stage K_TAB");
    end
  end
  // synthesis translate_on

endmodule
