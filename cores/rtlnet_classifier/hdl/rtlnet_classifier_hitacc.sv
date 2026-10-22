// -----------------------------------------------------------------------------
// File: rtlnet_classifier_hitacc.sv
// Purpose: last three stages of a table engine (field table or tuple table):
//   reduce the per-lane entry hits of one table word, accumulate them over a
//   frame's compare window, pick the policer of the lowest-index policing
//   hit, and latch the frame's result.
// Overview:
//   * Inputs per clock (registered entry hits): hit[l], hit_police[l],
//     pol[l] for the LANES entries of one table word (lane l = entry
//     address*LANES + l), with the window markers first/last and word_is0
//     (the word at address 0).
//   * Stage 1 (lane reduce): any hit; first policing lane (lowest lane wins)
//     and its policer; post-wrap flag = address 0 already seen in the window.
//   * Stage 2 (accumulate): hit = OR over the window; best policing hit: the
//     window visits the table words in rotating order starting anywhere, so
//     the lowest address is the first policing hit at or after the wrap to
//     address 0, else the first one before it (pre-wrap addresses are higher
//     than every post-wrap address of the same pass).
//   * Stage 3: the result registers load on the window's last word and hold
//     until the next window ends; done pulses with the load.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (axis_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_classifier_hitacc #(
  parameter int LANES = 2                  // entries per table word, 2 or 4
)(
  // Stream clock and synchronous active-low reset.
  input  logic                   clk,
  input  logic                   resetn,

  // Entry hits of one table word per clock, with window markers.
  input  logic [LANES-1:0]       hit,
  input  logic [LANES-1:0]       hit_police,
  input  logic [LANES-1:0][1:0]  pol,
  input  logic                   win_first,
  input  logic                   win_last,
  input  logic                   word_is0,

  // Frame result, held from done until the next done.
  output logic                   res_hit,
  output logic                   res_pf,
  output logic [1:0]             res_pol,
  output logic                   res_done
);

  // Stage 1 registers.
  logic       s1_any;
  logic       s1_cf;
  logic [1:0] s1_cpol;
  logic       s1_cpw;
  logic       s1_first;
  logic       s1_last;
  logic       pw_run;

  // Stage 2 registers.
  logic       acc;
  logic       bf;
  logic [1:0] bpol;
  logic       bpw;
  logic       s2_last;

  // Lane priority (combinational part of stage 1).
  logic       cf_c;
  logic [1:0] cpol_c;
  logic       cpw_c;

  always_comb begin
    cf_c   = 1'b0;
    cpol_c = pol[LANES-1];
    for (int l = LANES - 1; l >= 0; l--) begin
      if (hit_police[l]) begin
        cf_c   = 1'b1;
        cpol_c = pol[l];
      end
    end
    cpw_c = win_first ? word_is0 : (pw_run || word_is0);
  end

  // Stage 1: lane reduce and post-wrap tracking.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      s1_any   <= 1'b0;
      s1_cf    <= 1'b0;
      s1_cpol  <= '0;
      s1_cpw   <= 1'b0;
      s1_first <= 1'b0;
      s1_last  <= 1'b0;
      pw_run   <= 1'b0;
    end else begin
      s1_any   <= |hit;
      s1_cf    <= cf_c;
      s1_cpol  <= cpol_c;
      s1_cpw   <= cpw_c;
      s1_first <= win_first;
      s1_last  <= win_last;
      pw_run   <= cpw_c;
    end
  end

  // Stage 2: window accumulation and lowest-index policing hit.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      acc     <= 1'b0;
      bf      <= 1'b0;
      bpol    <= '0;
      bpw     <= 1'b0;
      s2_last <= 1'b0;
    end else begin
      s2_last <= s1_last;
      if (s1_first) begin
        acc  <= s1_any;
        bf   <= s1_cf;
        bpol <= s1_cpol;
        bpw  <= s1_cpw;
      end else begin
        acc <= acc || s1_any;
        if (s1_cf && (!bf || (s1_cpw && !bpw))) begin
          bf   <= 1'b1;
          bpol <= s1_cpol;
          bpw  <= s1_cpw;
        end
      end
    end
  end

  // Stage 3: frame result latch.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      res_hit  <= 1'b0;
      res_pf   <= 1'b0;
      res_pol  <= '0;
      res_done <= 1'b0;
    end else begin
      res_done <= s2_last;
      if (s2_last) begin
        res_hit <= acc;
        res_pf  <= bf;
        res_pol <= bpol;
      end
    end
  end

endmodule
