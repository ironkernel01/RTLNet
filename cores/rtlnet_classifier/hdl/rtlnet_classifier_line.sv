// -----------------------------------------------------------------------------
// File: rtlnet_classifier_line.sv
// Purpose: the frame path of rtlnet_classifier: ingress register, the
//   DELAY_BEATS-slot shift-register delay line, the verdict queue and the
//   verdict-gated valid at the end of the line, and the output register slice.
// Overview:
//   * Ingress: a two-register skid stage (output register + skid register);
//     s_axis_tready is a flop (skid register empty). The beat in the output
//     register is offered to the line.
//   * Line: {tlast, tkeep, tdata} (73 bits) in rtlnet_shift_reg_core
//     u_delay_line; the per-slot valid and start-of-frame bits in a
//     resettable flip-flop chain (slots 0..DELAY_BEATS-2) and the gated valid
//     of the last slot (gate_valid). A warm reset clears every slot.
//   * The line shifts on the registered enable shift_q. It shifts every
//     clock while the output can take the last slot's beat and either a beat
//     is offered or the line is between frames, so a gap-free frame leaves
//     exactly DELAY_BEATS clocks after it entered and a frame's tail never
//     waits for the next frame. It holds (no bubble enters) while a frame is
//     being received and its next beat is not yet offered: every beat of a
//     frame enters on consecutive shifts, so the first beat reaches the end
//     no earlier than DELAY_BEATS - (MATCH_BEATS - 1) clocks after the last
//     compared beat entered, whatever the gaps of the source. It also holds
//     while the output slice cannot take a beat.
//   * shift_q is computed one clock ahead from the next-state equations of
//     the ingress valid, the frame position and the output slice ready
//     (rtlnet_axis_reg_slice: s_tready next = 1 when its output register is
//     free or taken, 0 when a beat lands in its skid register).
//   * Engine tap: every beat taken into slot 0 is registered on tap_* with
//     its frame position: tap_idx (beat index, saturating at MATCH_BEATS),
//     tap_first, tap_judge (beat MATCH_BEATS-1, or the final beat of a
//     shorter frame: the beat after which the frame's decision can start).
//   * Verdict queue: QUEUE_DEPTH entries in frame order, head qe[0], count in
//     one-hot form (qoh). A verdict pushed in one clock is the head the
//     next. When a frame's first beat moves from slot DELAY_BEATS-2 into the
//     last slot the head is popped into cur_pass, which gates every beat of
//     that frame: pass sets gate_valid, drop leaves it clear and the beats
//     are consumed. A pop of an empty queue drops the frame and reports an
//     error in simulation (impossible by construction of DELAY_BEATS).
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (axis_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_classifier_line #(
  parameter int DELAY_BEATS = 30,          // slots of the delay line, >= 3
  parameter int MATCH_BEATS = 8,           // beats judged by the engines, >= 2
  parameter int QUEUE_DEPTH = 30,          // verdict queue entries, >= frames in the line
  parameter int IDX_W       = 6            // width of tap_idx, holds 0..MATCH_BEATS
)(
  // Stream clock and synchronous active-low reset.
  input  logic             clk,
  input  logic             resetn,

  // Frames in, RTLNet stream (byte 0 in tdata[7:0]); s_axis_tready is a flop.
  input  logic [63:0]      s_axis_tdata,
  input  logic [7:0]       s_axis_tkeep,
  input  logic             s_axis_tvalid,
  input  logic             s_axis_tlast,
  output logic             s_axis_tready,

  // Frames out, RTLNet stream, from the output register slice.
  output logic [63:0]      m_axis_tdata,
  output logic [7:0]       m_axis_tkeep,
  output logic             m_axis_tvalid,
  output logic             m_axis_tlast,
  input  logic             m_axis_tready,

  // Engine tap: the beat that entered slot 0 in the previous clock.
  output logic             tap_valid,
  output logic [63:0]      tap_data,
  output logic [7:0]       tap_keep,
  output logic             tap_last,
  output logic [IDX_W-1:0] tap_idx,
  output logic             tap_first,
  output logic             tap_judge,

  // Verdicts in frame order from the combiner (one pulse per frame).
  input  logic             v_push,
  input  logic             v_pass,

  // Status: one pulse per clock in which the last slot holds a passing beat
  // the output slice cannot take.
  output logic             stall_event
);

  localparam int N      = DELAY_BEATS;
  localparam int QD     = QUEUE_DEPTH;
  localparam int BEAT_W = 64 + 8 + 1;                   // {tlast, tkeep, tdata}
  localparam logic [IDX_W-1:0] IDX_SAT    = MATCH_BEATS;
  localparam logic [IDX_W-1:0] IDX_LAST   = MATCH_BEATS - 1;
  localparam logic [IDX_W-1:0] IDX_LAST_M = MATCH_BEATS - 2;

  generate
    if (N < 3) begin : g_bad_depth
      $fatal(1, "rtlnet_classifier_line: DELAY_BEATS=%0d, must be at least 3", N);
    end
    if (MATCH_BEATS < 2) begin : g_bad_match
      $fatal(1, "rtlnet_classifier_line: MATCH_BEATS=%0d, must be at least 2", MATCH_BEATS);
    end
    if (QD < N) begin : g_bad_queue
      $fatal(1, "rtlnet_classifier_line: QUEUE_DEPTH=%0d below DELAY_BEATS=%0d", QD, N);
    end
  endgenerate

  // Ingress.
  logic [BEAT_W-1:0] s_beat;
  logic [BEAT_W-1:0] in_beat;
  logic [BEAT_W-1:0] sk_beat;
  logic              in_valid;
  logic              sk_valid;
  logic              s_ready_q;
  logic              in_last;

  // Frame position of the offered beat.
  logic [IDX_W-1:0]  in_idx;
  logic              idx_is0;
  logic              idx_is_last;
  logic              idx_lt;
  logic              mid_frame;
  logic              judge;

  // Line control.
  logic              shift_q;
  logic              take;
  logic              out_s_ready;
  logic              o_ready_n;
  logic              in_valid_n;
  logic              mid_frame_n;
  logic              shift_n;

  // Slots.
  logic [N-2:0]      slot_v;
  logic [N-2:0]      slot_s;
  logic [BEAT_W-1:0] line_q;
  logic              gate_valid;
  logic              cur_pass;
  logic              pop;

  // Verdict queue.
  logic [QD-1:0]     qe;
  logic [QD:0]       qe_x;
  logic [QD:0]       qoh;
  logic              head_ok;

  assign s_beat        = {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
  assign s_axis_tready = s_ready_q;
  assign in_last       = in_beat[BEAT_W-1];
  assign take          = shift_q && in_valid;
  assign judge         = idx_lt && (idx_is_last || in_last);

  // Ingress skid stage: the output register offers a beat to the line; a
  // beat arriving while the offered beat waits lands in the skid register
  // and s_axis_tready falls the next clock.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      in_valid  <= 1'b0;
      sk_valid  <= 1'b0;
      s_ready_q <= 1'b0;
      in_beat   <= '0;
      sk_beat   <= '0;
    end else begin
      if (shift_q || !in_valid) begin
        if (sk_valid) begin
          in_beat   <= sk_beat;
          in_valid  <= 1'b1;
          sk_valid  <= 1'b0;
          s_ready_q <= 1'b1;
        end else begin
          in_beat   <= s_beat;
          in_valid  <= s_axis_tvalid && s_ready_q;
          s_ready_q <= 1'b1;
        end
      end else if (s_axis_tvalid && s_ready_q) begin
        sk_beat   <= s_beat;
        sk_valid  <= 1'b1;
        s_ready_q <= 1'b0;
      end
    end
  end

  // Frame position of the offered beat, advanced on every taken beat, with
  // registered decodes so the judge flag is one LUT.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      in_idx      <= '0;
      idx_is0     <= 1'b1;
      idx_is_last <= 1'b0;
      idx_lt      <= 1'b1;
      mid_frame   <= 1'b0;
    end else if (take) begin
      mid_frame <= !in_last;
      if (in_last) begin
        in_idx      <= '0;
        idx_is0     <= 1'b1;
        idx_is_last <= 1'b0;
        idx_lt      <= 1'b1;
      end else begin
        if (in_idx != IDX_SAT) in_idx <= in_idx + 1'b1;
        idx_is0     <= 1'b0;
        idx_is_last <= (in_idx == IDX_LAST_M);
        idx_lt      <= (in_idx < IDX_LAST);
      end
    end
  end

  // Engine tap: register every taken beat with its frame position.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      tap_valid <= 1'b0;
      tap_data  <= '0;
      tap_keep  <= '0;
      tap_last  <= 1'b0;
      tap_idx   <= '0;
      tap_first <= 1'b0;
      tap_judge <= 1'b0;
    end else begin
      tap_valid <= take;
      if (take) begin
        tap_data  <= in_beat[63:0];
        tap_keep  <= in_beat[71:64];
        tap_last  <= in_last;
        tap_idx   <= in_idx;
        tap_first <= idx_is0;
        tap_judge <= judge;
      end
    end
  end

  // Next-state of the three quantities the line enable depends on, so the
  // enable itself is a register: the output slice ready, the ingress valid
  // and the frame position at the line input.
  // in_valid_n uses s_ready_q == !sk_valid, which holds in every clock
  // except the reset clock (both 0); in that clock mid_frame_n is 0, so the
  // input term (a beat offered next clock, or between frames) is unchanged.
  // The input term is one 6-input function, shift_n one more LUT.
  always_comb begin
    o_ready_n   = (m_axis_tready || !m_axis_tvalid) ? 1'b1 :
                  (gate_valid && out_s_ready)       ? 1'b0 : out_s_ready;
    in_valid_n  = (shift_q || !in_valid) ? (sk_valid || s_axis_tvalid) : 1'b1;
    mid_frame_n = take ? !in_last : mid_frame;
    shift_n     = o_ready_n && (in_valid_n || !mid_frame_n);
  end

  // Registered line enable.
  always_ff @(posedge clk) begin
    if (!resetn) shift_q <= 1'b0;
    else         shift_q <= shift_n;
  end

  // Data slots: technology shift register, no reset on the storage.
  rtlnet_shift_reg_core #(
    .DATA_W (BEAT_W),
    .DEPTH  (N)
  ) u_delay_line (
    .clk (clk),
    .ce  (shift_q),
    .d   (in_beat),
    .q   (line_q)
  );

  // Valid and start-of-frame bits of slots 0..N-2: a resettable flip-flop
  // chain shifted with the data, so a reset can never release stale beats.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      slot_v <= '0;
      slot_s <= '0;
    end else if (shift_q) begin
      slot_v <= {slot_v[N-3:0], in_valid};
      slot_s <= {slot_s[N-3:0], in_valid && idx_is0};
    end
  end

  // A frame's first beat entering the last slot pops its verdict.
  assign pop     = shift_q && slot_v[N-2] && slot_s[N-2];
  assign head_ok = !qoh[0];
  assign qe_x    = {1'b0, qe};

  // Last slot: gated valid and the verdict of the frame occupying it. The
  // slice takes a gated beat when ready; a beat it takes without the line
  // shifting is marked consumed.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      gate_valid <= 1'b0;
      cur_pass   <= 1'b0;
    end else begin
      if (shift_q) begin
        gate_valid <= slot_v[N-2] && (slot_s[N-2] ? (qe[0] && head_ok) : cur_pass);
      end else begin
        gate_valid <= gate_valid && !out_s_ready;
      end
      if (pop) cur_pass <= qe[0] && head_ok;
    end
  end

  // Verdict queue: push at the tail (one-hot count position), pop the head;
  // both together keep the count.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      qe  <= '0;
      qoh <= {{QD{1'b0}}, 1'b1};
    end else begin
      for (int k = 0; k < QD; k++) begin
        if (pop && head_ok) begin
          qe[k] <= (v_push && qoh[k+1]) ? v_pass : qe_x[k+1];
        end else if (v_push && qoh[k]) begin
          qe[k] <= v_pass;
        end
      end
      if (v_push && !(pop && head_ok) && !qoh[QD]) qoh <= {qoh[QD-1:0], 1'b0};
      else if (!v_push && pop && head_ok)          qoh <= {1'b0, qoh[QD:1]};
    end
  end

  // Stall status: the last slot holds a passing beat the slice cannot take.
  always_ff @(posedge clk) begin
    if (!resetn) stall_event <= 1'b0;
    else         stall_event <= gate_valid && !out_s_ready;
  end

  // Output register slice: every m_axis output is a flop and the downstream
  // ready reaches only shift_q's next-state logic.
  rtlnet_axis_reg_slice #(
    .DATA_W     (64),
    .RESET_DATA (1'b1)
  ) u_out_slice (
    .clk      (clk),
    .resetn   (resetn),
    .s_tdata  (line_q[63:0]),
    .s_tkeep  (line_q[71:64]),
    .s_tlast  (line_q[72]),
    .s_tvalid (gate_valid),
    .s_tready (out_s_ready),
    .m_tdata  (m_axis_tdata),
    .m_tkeep  (m_axis_tkeep),
    .m_tlast  (m_axis_tlast),
    .m_tvalid (m_axis_tvalid),
    .m_tready (m_axis_tready)
  );

  // synthesis translate_off
  // Simulation checks: a verdict is present for every frame reaching the end
  // of the line; the queue never overflows; the line never shifts a gated
  // beat away while the slice refuses it.
  logic sim_run = 1'b0;
  always @(posedge clk) begin
    sim_run <= (resetn === 1'b1);
    if (sim_run && resetn === 1'b1 && (s_ready_q == sk_valid))
      $error("rtlnet_classifier_line: ingress ready is not the inverse of the skid valid");
    if (resetn === 1'b1) begin
      if (pop && !head_ok)
        $error("rtlnet_classifier_line: frame reached the end of the delay line before its verdict");
      if (v_push && qoh[QD] && !(pop && head_ok))
        $error("rtlnet_classifier_line: verdict queue overflow");
      if (shift_q && gate_valid && !out_s_ready)
        $error("rtlnet_classifier_line: line shifted while the output slice refused a beat");
    end
  end
  // synthesis translate_on

endmodule
