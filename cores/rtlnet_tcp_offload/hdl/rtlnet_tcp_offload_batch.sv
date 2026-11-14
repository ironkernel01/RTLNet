// -----------------------------------------------------------------------------
// File: rtlnet_tcp_offload_batch.sv
// Purpose: receive batching on the CPU receive stream: consecutive frames (each already followed by its 8-byte
//   trailer) are concatenated into one DMA transfer (one TLAST), so the CPU services several frames per
//   transfer.
// Overview:
//   * Input: frames of the RTLNet stream with the trailer sideband s_ttrl (frame carries a trailer). A frame
//     is [data beats, final beat padded to 8 bytes][trailer beat]; the trailer beat has tlast.
//   * Output transfer (batch) = frame 1 (padded) + trailer 1 + frame 2 + trailer 2 + ... with tlast only on
//     the last trailer. Every frame keeps its own trailer, whose length field (and marker) give the frame
//     boundary; the firmware walks the batch backwards from the end (rtlnet_tcp_offload_batch_walk).
//   * The trailer beat of a batched frame is held in a register (h_*) until the next beat shows what follows:
//       - next frame starts and no limit is reached: the held beat leaves with tlast clear (batch goes on)
//       - a limit is reached, the timer expired, the feature is off or a frame without trailer follows: it
//         leaves with tlast set (batch closed), one clock after the decision.
//     A single frame on an idle line therefore leaves when the timer register (microseconds, counted from the
//     moment the frame's trailer was held) expires; the count limit and the byte limit close the batch at once.
//   * Limits: cfg_max_frames frames per batch (0 and 1: every frame alone); byte limit cfg_max_bytes with the
//     guarantee transfer_bytes <= cfg_max_bytes for frames of at most MAX_FRAME_BYTES: after a frame the batch is
//     closed when bytes + (roundup8(MAX_FRAME_BYTES) + 8) > cfg_max_bytes, so any next frame fits.
//   * cfg_en is looked at when a trailer is held and when it is released: with the feature off a frame passes
//     as before (its trailer has tlast set) and an open batch is closed.
//   * Events (one clock pulses): batches closed, frames batched, closes by byte limit / frame count / timer /
//     other (feature off or a frame without trailer follows).
//   * Registered outputs; s_tready depends on m_tready and one flop (it feeds the registered slice upstream).
// Language: SystemVerilog-2012.
// Revision: 11-14-2026
//   * 11-14-2026: initial version.
// Clocks: clk; resetn synchronous, active low.
// -----------------------------------------------------------------------------
module rtlnet_tcp_offload_batch #(
  parameter int MAX_FRAME_BYTES = 2048   // largest frame the batch limit must leave room for (multiple of 8)
)(
  // Clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Configuration and the microsecond tick (one clock pulse per microsecond).
  input  logic        cfg_en,
  input  logic [15:0] cfg_timer_us,
  input  logic [7:0]  cfg_max_frames,
  input  logic [15:0] cfg_max_bytes,
  input  logic        us_tick,

  // Frames in (RTLNet stream plus the trailer sideband).
  input  logic [63:0] s_tdata,
  input  logic [7:0]  s_tkeep,
  input  logic        s_tvalid,
  input  logic        s_tlast,
  input  logic        s_ttrl,
  output logic        s_tready,

  // Batches out (all outputs registered).
  output logic [63:0] m_tdata,
  output logic [7:0]  m_tkeep,
  output logic        m_tvalid,
  output logic        m_tlast,
  input  logic        m_tready,

  // Status and one-clock event pulses (registered).
  output logic        idle,
  output logic        ev_batch,
  output logic        ev_frame,
  output logic        ev_cl_bytes,
  output logic        ev_cl_count,
  output logic        ev_cl_timer,
  output logic        ev_cl_other
);

  localparam int RESERVE_BEATS = MAX_FRAME_BYTES / 8 + 1;   // worst-case next frame: data beats + trailer
  localparam int UW            = 14;                         // beat counter width (batches up to 128 KiB)

  generate
    if ((MAX_FRAME_BYTES % 8) != 0 || MAX_FRAME_BYTES < 64) begin : g_bad_max
      $fatal(1, "rtlnet_tcp_offload_batch: MAX_FRAME_BYTES=%0d, must be a multiple of 8 and at least 64",
             MAX_FRAME_BYTES);
    end
  endgenerate

  logic [63:0]   h_d = '0;
  logic          h_v = 1'b0;
  logic [63:0]   o_d = '0;
  logic [7:0]    o_k = '0;
  logic          o_l = 1'b0;
  logic          o_v = 1'b0;
  logic [8:0]    nfr = '0;
  logic [UW-1:0] used = '0;
  logic [15:0]   tm = '0;

  logic          out_take;
  logic          trl_beat;
  logic          c_count;
  logic          c_bytes;
  logic          c_timer;
  logic          c_other;
  logic          want_close;
  logic          rel_last;
  logic          rel_cont;
  logic          accept;
  logic [UW-1:0] limit_beats;

  assign out_take    = !o_v || m_tready;
  assign s_tready    = !h_v && out_take;
  assign accept      = s_tvalid && s_tready;
  assign trl_beat    = s_tlast && s_ttrl;
  assign limit_beats = UW'(cfg_max_bytes[15:3]);

  assign c_count = (nfr >= {1'b0, cfg_max_frames}) || (cfg_max_frames == 8'd0);
  assign c_bytes = ((used + UW'(RESERVE_BEATS)) > limit_beats);
  assign c_timer = (tm >= cfg_timer_us);
  assign c_other = !cfg_en || (s_tvalid && !s_ttrl);
  assign want_close = c_count || c_bytes || c_timer || c_other;
  assign rel_last = h_v && out_take && want_close;
  assign rel_cont = h_v && out_take && !want_close && s_tvalid;

  assign m_tdata  = o_d;
  assign m_tkeep  = o_k;
  assign m_tlast  = o_l;
  assign m_tvalid = o_v;

  // Output register, held trailer, batch accounting.
  always_ff @(posedge clk) begin
    ev_batch    <= 1'b0;
    ev_frame    <= 1'b0;
    ev_cl_bytes <= 1'b0;
    ev_cl_count <= 1'b0;
    ev_cl_timer <= 1'b0;
    ev_cl_other <= 1'b0;
    if (!resetn) begin
      h_v  <= 1'b0;
      o_v  <= 1'b0;
      nfr  <= '0;
      used <= '0;
      tm   <= '0;
    end else begin
      if (o_v && m_tready) o_v <= 1'b0;
      if (nfr != 9'd0 && us_tick && tm != 16'hFFFF) tm <= tm + 16'd1;

      if (rel_last || rel_cont) begin
        // The held trailer leaves; tlast closes the batch.
        o_d <= h_d;
        o_k <= 8'hFF;
        o_l <= rel_last;
        o_v <= 1'b1;
        h_v <= 1'b0;
        if (rel_last) begin
          nfr         <= 9'd0;
          used        <= '0;
          ev_batch    <= 1'b1;
          ev_cl_count <= c_count;
          ev_cl_bytes <= !c_count && c_bytes;
          ev_cl_timer <= !c_count && !c_bytes && c_timer;
          ev_cl_other <= !c_count && !c_bytes && !c_timer;
        end
      end else if (accept) begin
        if (trl_beat && cfg_en) begin
          // Batched frame complete: its trailer waits for the decision.
          h_d      <= s_tdata;
          h_v      <= 1'b1;
          nfr      <= nfr + 9'd1;
          used     <= used + UW'(1);
          ev_frame <= 1'b1;
          if (nfr == 9'd0) tm <= 16'd0;
        end else begin
          // Data beat of a batched frame, or a frame outside the batching: straight to the output register.
          o_d <= s_tdata;
          o_k <= s_tkeep;
          o_l <= s_tlast;
          o_v <= 1'b1;
          if (s_ttrl && !s_tlast) used <= used + UW'(1);
          if (trl_beat) begin
            // Trailer of a frame while the feature is off: the transfer ends here (closes an open batch).
            nfr  <= 9'd0;
            used <= '0;
            if (nfr != 9'd0) begin
              ev_batch    <= 1'b1;
              ev_cl_other <= 1'b1;
            end
          end
        end
      end
    end
  end

  // Idle: nothing held or queued, no batch open.
  always_ff @(posedge clk) begin
    if (!resetn) idle <= 1'b1;
    else         idle <= !h_v && !o_v && (nfr == 9'd0) && !s_tvalid;
  end

endmodule
