// -----------------------------------------------------------------------------
// File: rtlnet_eth_protocol_ingress.sv
// Purpose: the axis_clk ingress side of rtlnet_eth_protocol: input register
//   slice, destination-MAC filter, first-beat drop decision in front of the
//   ingress packet FIFO, and the three ingress frame counters.
// Overview:
//   * u_in_slice: rtlnet_axis_reg_slice with its downstream ready tied 1, so
//     s_axis_tready is a flop that is 1 from the clock after reset on and the
//     MAC is never back-pressured.
//   * Filter configuration: the local MAC and FILTER_ENABLE are proto_clk
//     registers. They enter axis_clk once, 49 bits through u_filt_cfg_sync
//     (rtlnet_sync, 2 stages), and a new value is taken only when two
//     consecutive synchronized samples are equal and the chain has filled
//     after reset (the register keeps its reset value, the default MAC with
//     the filter on, until then). A change affects frames that begin after it.
//   * Filter stages, each one or two LUT levels for a fast axis_clk:
//       F1  the slice beat, plus a first-beat flag (valid and not in a frame)
//       F2  six 16-bit equality flags of the first beat's bytes 0-5: three
//           against 0xFFFF (broadcast), three against the local MAC
//       F3  candidate verdict: broadcast OR local MAC, or 1 when the filter is
//           off (promiscuous)
//       F4  per-frame pass latch: the first beat takes the candidate, later
//           beats the held verdict; a rejected frame is never offered to the
//           FIFO. Multicast and every other unicast are rejected.
//   * Drop decision (DROP_WHEN_FULL = 0 FIFO): at a frame's first beat the
//     FIFO's s_ready is the verdict. Ready: the frame is stored. Not ready (no
//     free slot): the frame is dropped whole and drop_hold withholds its
//     remaining beats, so the FIFO never starts storing it half way.
//   * Counters (32 bit, wrap, never cleared; the register file clears by
//     snapshot): FILTERED counts frames the filter discards (at the first
//     beat), FRAMES counts frames stored whole (at the last beat), DROPPED
//     counts frames that found no slot (first beat) or overran one slot
//     (ing_beats mirrors the FIFO's word count; counted at the beat the FIFO
//     discards the frame). Every frame offered is counted in exactly one of
//     the three, at one beat: offered = FILTERED + FRAMES + DROPPED.
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (axis_clk) only; resetn synchronous to it, active low. The
//   cfg_* inputs are proto_clk registers, asynchronous here.
// -----------------------------------------------------------------------------
module rtlnet_eth_protocol_ingress #(
  parameter int MAX_FRAME_BYTES = rtlnet_pkg::ETH_MAX_FRAME_BYTES   // slot size of the ingress FIFO
)(
  // axis_clk and its synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // From the MAC receive client, RTLNet stream (no FCS, padding retained);
  // s_axis_tready is a flop and never back-pressures.
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // Filter configuration, proto_clk registers (asynchronous to clk): local
  // MAC (octet 0 in [47:40]) and the filter enable (0 = promiscuous).
  input  logic [47:0] cfg_local_mac,
  input  logic        cfg_filter_enable,

  // To the ingress packet FIFO write side (axis_clk): whole frames that passed
  // the filter; fifo_ready is the FIFO's s_ready.
  output logic [63:0] fifo_data,
  output logic [7:0]  fifo_keep,
  output logic        fifo_last,
  output logic        fifo_valid,
  input  logic        fifo_ready,

  // Ingress counters, axis_clk, free-running binary (step at most 1 per clock).
  output logic [31:0] cnt_frames,
  output logic [31:0] cnt_filtered,
  output logic [31:0] cnt_dropped
);

  import rtlnet_pkg::*;

  localparam int          CFG_W          = 49;                          // {filter_enable, local MAC}
  localparam int          FILL_CLOCKS    = 4;                           // synchronizer fill after reset
  localparam logic [48:0] CFG_RESET      = {1'b1, DEFAULT_LOCAL_MAC};
  localparam int          ING_WORD_BITS  = clog2i((MAX_FRAME_BYTES + 7) / 8);   // the FIFO's WORD_BITS
  localparam int          ING_SLOT_WORDS = 1 << ING_WORD_BITS;
  localparam logic [ING_WORD_BITS-1:0] SLOT_LAST_WORD = ING_SLOT_WORDS - 1;
  localparam logic [15:0] ALL_ONES16     = 16'hFFFF;

  // Input slice outputs.
  logic [63:0]       sl_data;
  logic [7:0]        sl_keep;
  logic              sl_last;
  logic              sl_valid;

  // Filter configuration in axis_clk.
  logic [CFG_W-1:0]  cfg_sync;
  logic [CFG_W-1:0]  cfg_sync_d;
  logic [CFG_W-1:0]  cfg_stable;
  logic [2:0]        fill_count;
  logic [47:0]       filt_mac_bus;        // local MAC in bus order: octet 0 in [7:0]
  logic              filt_enable;

  // Filter stages.
  logic [63:0]       f1_data;
  logic [7:0]        f1_keep;
  logic              f1_last;
  logic              f1_valid;
  logic              f1_first;
  logic              in_frame;
  logic [63:0]       f2_data;
  logic [7:0]        f2_keep;
  logic              f2_last;
  logic              f2_valid;
  logic              f2_first;
  logic [2:0]        f2_bcast;
  logic [2:0]        f2_local;
  logic              f2_filter_on;
  logic [63:0]       f3_data;
  logic [7:0]        f3_keep;
  logic              f3_last;
  logic              f3_valid;
  logic              f3_first;
  logic              f3_cand;
  logic [63:0]       f4_data;
  logic [7:0]        f4_keep;
  logic              f4_last;
  logic              f4_valid;
  logic              f4_first;
  logic              pass_run;
  logic              filt_pulse;

  // Drop decision.
  logic              drop_hold;
  logic              enq_pulse;
  logic              drop_pulse;
  logic              over_pulse;
  logic              ing_over;
  logic [ING_WORD_BITS-1:0] ing_beats;
  logic              ing_take;

  // Input register slice: registered tready to the MAC; nothing downstream stalls.
  rtlnet_axis_reg_slice #(
    .DATA_W     (64),
    .RESET_DATA (1'b0)
  ) u_in_slice (
    .clk      (clk),
    .resetn   (resetn),
    .s_tdata  (s_axis_tdata),
    .s_tkeep  (s_axis_tkeep),
    .s_tlast  (s_axis_tlast),
    .s_tvalid (s_axis_tvalid),
    .s_tready (s_axis_tready),
    .m_tdata  (sl_data),
    .m_tkeep  (sl_keep),
    .m_tlast  (sl_last),
    .m_tvalid (sl_valid),
    .m_tready (1'b1)
  );

  // The filter configuration crosses from proto_clk once (level synchronizer).
  rtlnet_sync #(
    .WIDTH  (CFG_W),
    .STAGES (2)
  ) u_filt_cfg_sync (
    .clk    (clk),
    .resetn (resetn),
    .d      ({cfg_filter_enable, cfg_local_mac}),
    .q      (cfg_sync)
  );

  // Stability filter: a value is taken only when two consecutive synchronized
  // samples agree, after the chain has filled since reset.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cfg_sync_d <= '0;
      cfg_stable <= CFG_RESET;
      fill_count <= '0;
    end else begin
      cfg_sync_d <= cfg_sync;
      if (fill_count != 3'(FILL_CLOCKS)) fill_count <= fill_count + 1'b1;
      else if (cfg_sync == cfg_sync_d)   cfg_stable <= cfg_sync;
    end
  end

  assign filt_mac_bus = be48(cfg_stable[47:0]);
  assign filt_enable  = cfg_stable[48];

  // F1: the beat registered, with the first-beat flag.
  always_ff @(posedge clk) begin
    f1_data <= sl_data;
    f1_keep <= sl_keep;
    f1_last <= sl_last;
    if (!resetn) begin
      f1_valid <= 1'b0;
      f1_first <= 1'b0;
      in_frame <= 1'b0;
    end else begin
      f1_valid <= sl_valid;
      f1_first <= sl_valid && !in_frame;
      if (sl_valid) in_frame <= !sl_last;
    end
  end

  // F2: six 16-bit equality flags of the F1 beat (used for a first beat).
  always_ff @(posedge clk) begin
    f2_data      <= f1_data;
    f2_keep      <= f1_keep;
    f2_last      <= f1_last;
    f2_bcast[0]  <= (f1_data[15:0]  == ALL_ONES16);
    f2_bcast[1]  <= (f1_data[31:16] == ALL_ONES16);
    f2_bcast[2]  <= (f1_data[47:32] == ALL_ONES16);
    f2_local[0]  <= (f1_data[15:0]  == filt_mac_bus[15:0]);
    f2_local[1]  <= (f1_data[31:16] == filt_mac_bus[31:16]);
    f2_local[2]  <= (f1_data[47:32] == filt_mac_bus[47:32]);
    f2_filter_on <= filt_enable;
    if (!resetn) begin
      f2_valid <= 1'b0;
      f2_first <= 1'b0;
    end else begin
      f2_valid <= f1_valid;
      f2_first <= f1_first;
    end
  end

  // F3: the candidate verdict.
  always_ff @(posedge clk) begin
    f3_data <= f2_data;
    f3_keep <= f2_keep;
    f3_last <= f2_last;
    f3_cand <= !f2_filter_on || (&f2_bcast) || (&f2_local);
    if (!resetn) begin
      f3_valid <= 1'b0;
      f3_first <= 1'b0;
    end else begin
      f3_valid <= f2_valid;
      f3_first <= f2_first;
    end
  end

  // F4: the per-frame pass latch; filt_pulse is one clock per discarded frame.
  always_ff @(posedge clk) begin
    f4_data  <= f3_data;
    f4_keep  <= f3_keep;
    f4_last  <= f3_last;
    f4_first <= f3_first;
    if (!resetn) begin
      f4_valid   <= 1'b0;
      pass_run   <= 1'b0;
      filt_pulse <= 1'b0;
    end else begin
      f4_valid   <= f3_valid && (f3_first ? f3_cand : pass_run);
      filt_pulse <= f3_valid && f3_first && !f3_cand;
      if (f3_valid && f3_first) pass_run <= f3_cand;
    end
  end

  // FIFO write side: the beats of an admitted frame.
  assign fifo_data  = f4_data;
  assign fifo_keep  = f4_keep;
  assign fifo_last  = f4_last;
  assign fifo_valid = f4_valid && !drop_hold;
  assign ing_take   = fifo_valid && fifo_ready;

  // First-beat drop decision and the per-frame accounting. ing_beats counts
  // the non-final beats the FIFO accepted for the current frame (the FIFO's
  // own word count): a non-final beat at SLOT_LAST_WORD is the beat at which
  // the FIFO discards an over-slot frame.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      drop_hold  <= 1'b0;
      enq_pulse  <= 1'b0;
      drop_pulse <= 1'b0;
      over_pulse <= 1'b0;
      ing_over   <= 1'b0;
      ing_beats  <= '0;
    end else begin
      enq_pulse  <= 1'b0;
      drop_pulse <= 1'b0;
      over_pulse <= 1'b0;
      if (f4_valid) begin
        if (f4_first && !fifo_ready) begin
          drop_pulse <= 1'b1;                  // no free slot: dropped whole at its first beat
          drop_hold  <= !f4_last;
        end else if (f4_last) begin
          drop_hold  <= 1'b0;
        end
      end
      if (ing_take) begin
        if (f4_last) begin
          enq_pulse <= !ing_over;              // stored whole, unless it overran its slot
          ing_over  <= 1'b0;
          ing_beats <= '0;
        end else if (!ing_over) begin
          if (ing_beats == SLOT_LAST_WORD) begin
            over_pulse <= 1'b1;                // the FIFO discards the frame on this beat
            ing_over   <= 1'b1;
          end else begin
            ing_beats <= ing_beats + 1'b1;
          end
        end
      end
    end
  end

  // The three counters (drop_pulse and over_pulse are distinct beats of one stream).
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cnt_frames   <= '0;
      cnt_filtered <= '0;
      cnt_dropped  <= '0;
    end else begin
      if (enq_pulse)                cnt_frames   <= cnt_frames + 1'b1;
      if (filt_pulse)               cnt_filtered <= cnt_filtered + 1'b1;
      if (drop_pulse || over_pulse) cnt_dropped  <= cnt_dropped + 1'b1;
    end
  end

  // Simulation-only guard: after a frame's first beat the FIFO is never
  // unready (DROP_WHEN_FULL = 0), so an unready mid-frame beat means the
  // withholding failed.
  // synthesis translate_off
  always @(posedge clk) begin
    if (resetn && fifo_valid && !f4_first && !fifo_ready)
      $error("%m: a mid-frame beat was offered to the ingress FIFO while it was not ready");
  end
  // synthesis translate_on

endmodule
