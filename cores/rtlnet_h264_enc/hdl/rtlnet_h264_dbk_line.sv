// -----------------------------------------------------------------------------
// File: rtlnet_h264_dbk_line.sv
// Purpose: one line of the H.264 deblocking filter (ITU-T Rec. H.264 clause 8.7.2.3 and 8.7.2.4): the eight samples p3..p0 | q0..q3 across
//   an edge, the boundary strength and the table values of the edge in, the filtered samples out, two register stages.
// Overview:
//   * Stage 1 registers the samples and the decisions that need the whole line: filterSamplesFlag (bS != 0, |p0 - q0| < alpha,
//     |p1 - p0| < beta, |q1 - q0| < beta), ap < beta and aq < beta (luma), the bS = 4 strong condition |p0 - q0| < (alpha >> 2) + 2, tC for
//     bS < 4 (luma tC0 + (ap < beta) + (aq < beta), chroma tC0 + 1), the unclipped delta and the p1 / q1 corrections of clause 8.7.2.3.
//   * Stage 2 selects and clips: bS < 4 modifies p0 and q0 (and p1, q1 of luma when ap or aq < beta); bS = 4 the strong or the weak
//     filter of luma, the chroma filter of chroma. Samples a line does not modify pass through.
//   * chroma = 1: the line is a chroma line: only p0 and q0 are modified, tC = tC0 + 1 for bS < 4.
//   * The output registers update only for a valid input and hold otherwise (the write stage of rtlnet_h264_deblock reads them for
//     two clocks).
// Language: SystemVerilog-2012.
// Revision: 11-12-2026
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_dbk_line (
  input  logic        clk,
  input  logic        resetn,
  input  logic        v_i,
  input  logic        chroma,
  input  logic [2:0]  bs,
  input  logic [7:0]  alpha,
  input  logic [4:0]  beta,
  input  logic [4:0]  tc0,
  input  logic [31:0] p_i,     // {p3, p2, p1, p0}
  input  logic [31:0] q_i,     // {q3, q2, q1, q0}
  output logic        v_o,
  output logic [31:0] p_o,
  output logic [31:0] q_o
);

  function automatic int iabs(input int a);
    return (a < 0) ? -a : a;
  endfunction
  function automatic int clip3(input int lo, input int hi, input int v);
    return (v < lo) ? lo : ((v > hi) ? hi : v);
  endfunction
  function automatic int clip1(input int v);
    return (v < 0) ? 0 : ((v > 255) ? 255 : v);
  endfunction

  // Stage 1 registers.
  logic        v1;
  logic        chroma1, fsf1, bs4_1, apl1, aql1, small1;
  logic [7:0]  p1r [4];
  logic [7:0]  q1r [4];
  logic [5:0]  tc1;
  logic [4:0]  tc0_1;
  logic signed [9:0]  dl1;      // unclipped delta
  logic signed [9:0]  dp1_1;    // p1 correction of bS < 4 (clipped to tc0)
  logic signed [9:0]  dq1_1;

  // Stage 1 combinational.
  int p0, p1, p2, q0, q1, q2;
  // Wide integer intermediates: only the low bits reach the registers.
  /* verilator lint_off UNUSEDSIGNAL */
  int ap_v, aq_v, tcv, dl, dpv, dqv;
  /* verilator lint_on UNUSEDSIGNAL */
  logic fsf_c, apl_c, aql_c, small_c;

  always_comb begin
    p0 = int'(p_i[7:0]);   p1 = int'(p_i[15:8]);  p2 = int'(p_i[23:16]);
    q0 = int'(q_i[7:0]);   q1 = int'(q_i[15:8]);  q2 = int'(q_i[23:16]);
    fsf_c   = (bs != 3'd0) && (iabs(p0 - q0) < int'(alpha)) && (iabs(p1 - p0) < int'(beta)) && (iabs(q1 - q0) < int'(beta));
    ap_v    = iabs(p2 - p0);
    aq_v    = iabs(q2 - q0);
    apl_c   = (ap_v < int'(beta));
    aql_c   = (aq_v < int'(beta));
    small_c = (iabs(p0 - q0) < ((int'(alpha) >> 2) + 2));
    tcv     = chroma ? (int'(tc0) + 1) : (int'(tc0) + (apl_c ? 1 : 0) + (aql_c ? 1 : 0));
    dl      = (((q0 - p0) << 2) + (p1 - q1) + 4) >>> 3;
    dpv     = clip3(-int'(tc0), int'(tc0), (p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >>> 1);
    dqv     = clip3(-int'(tc0), int'(tc0), (q2 + ((p0 + q0 + 1) >> 1) - (q1 << 1)) >>> 1);
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      v1 <= 1'b0;
    end else begin
      v1 <= v_i;
    end
    if (v_i) begin
      chroma1 <= chroma;
      fsf1    <= fsf_c;
      bs4_1   <= (bs == 3'd4);
      apl1    <= apl_c;
      aql1    <= aql_c;
      small1  <= small_c;
      for (int i = 0; i < 4; i++) begin
        p1r[i] <= p_i[8*i +: 8];
        q1r[i] <= q_i[8*i +: 8];
      end
      tc1   <= 6'(tcv);
      tc0_1 <= tc0;
      dl1   <= 10'(dl);
      dp1_1 <= 10'(dpv);
      dq1_1 <= 10'(dqv);
    end
  end

  // Stage 2.
  logic [7:0] np [4];
  logic [7:0] nq [4];
  int sp0, sp1, sp2, sp3, sq0, sq1, sq2, sq3, dd;

  always_comb begin
    sp0 = int'(p1r[0]); sp1 = int'(p1r[1]); sp2 = int'(p1r[2]); sp3 = int'(p1r[3]);
    sq0 = int'(q1r[0]); sq1 = int'(q1r[1]); sq2 = int'(q1r[2]); sq3 = int'(q1r[3]);
    dd  = 0;
    for (int i = 0; i < 4; i++) begin
      np[i] = p1r[i];
      nq[i] = q1r[i];
    end
    if (fsf1) begin
      if (!bs4_1) begin
        dd    = clip3(-int'(tc1), int'(tc1), int'(dl1));
        np[0] = 8'(clip1(sp0 + dd));
        nq[0] = 8'(clip1(sq0 - dd));
        if (!chroma1 && apl1) np[1] = 8'(sp1 + int'(dp1_1));
        if (!chroma1 && aql1) nq[1] = 8'(sq1 + int'(dq1_1));
      end else if (chroma1) begin
        np[0] = 8'((2 * sp1 + sp0 + sq1 + 2) >> 2);
        nq[0] = 8'((2 * sq1 + sq0 + sp1 + 2) >> 2);
      end else begin
        if (apl1 && small1) begin
          np[0] = 8'((sp2 + 2 * sp1 + 2 * sp0 + 2 * sq0 + sq1 + 4) >> 3);
          np[1] = 8'((sp2 + sp1 + sp0 + sq0 + 2) >> 2);
          np[2] = 8'((2 * sp3 + 3 * sp2 + sp1 + sp0 + sq0 + 4) >> 3);
        end else begin
          np[0] = 8'((2 * sp1 + sp0 + sq1 + 2) >> 2);
        end
        if (aql1 && small1) begin
          nq[0] = 8'((sp1 + 2 * sp0 + 2 * sq0 + 2 * sq1 + sq2 + 4) >> 3);
          nq[1] = 8'((sp0 + sq0 + sq1 + sq2 + 2) >> 2);
          nq[2] = 8'((2 * sq3 + 3 * sq2 + sq1 + sq0 + sp0 + 4) >> 3);
        end else begin
          nq[0] = 8'((2 * sq1 + sq0 + sp1 + 2) >> 2);
        end
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, chroma1, tc0_1};

  always_ff @(posedge clk) begin
    if (!resetn) begin
      v_o <= 1'b0;
    end else begin
      v_o <= v1;
    end
    if (v1) begin
      p_o <= {np[3], np[2], np[1], np[0]};
      q_o <= {nq[3], nq[2], nq[1], nq[0]};
    end
  end

endmodule
