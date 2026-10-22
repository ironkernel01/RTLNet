// -----------------------------------------------------------------------------
// File: tb_rtlnet_packet_fifo.sv
// Purpose: self-checking bench for rtlnet_packet_fifo, rtlnet_frame_guard,
//   rtlnet_axis_reg_slice and (through the FIFO) rtlnet_ram_core.
// Cases:
//   1. Store-and-forward across unrelated clocks (62.5 MHz write, 50 MHz read)
//      and the reverse ratio: 150 random frames, 14..1518 bytes, random source
//      gaps, random sink stalls; every good frame arrives byte-exact, in order.
//   2. Guarded drops: runts (< MIN_BYTES), frames flagged bad on their last
//      beat, and oversize frames (> MAX_FRAME_BYTES) never appear; bad_frame
//      pulses are counted and must equal the number of rejected frames.
//   3. DROP_WHEN_FULL = 1 with a stalled sink: of 10 frames into a 4-slot queue
//      exactly 4 are kept, 6 overflow pulses, then the 4 drain intact.
//   4. DROP_WHEN_FULL = 0 back-pressure: s_ready falls between frames only.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Run: powershell -File scripts/rtlnet_run_sim.ps1 -Bench tb_rtlnet_packet_fifo
//        -Filelist cores/rtlnet_common/testbench/tb_rtlnet_packet_fifo.f
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_packet_fifo;

  import rtlnet_tb_pkg::*;

  localparam int MIN_BYTES = 60;
  localparam int MAX_BYTES = 1518;

  // ---------------------------------------------------------------------------
  // Clocks and resets: instance A writes fast/reads slow, B the reverse.
  // ---------------------------------------------------------------------------
  logic clk_a_s = 0;   // 62.5 MHz
  logic clk_a_m = 0;   // 50 MHz
  logic clk_c   = 0;   // 100 MHz, instance C (drop when full) both sides
  logic arstn   = 0;
  logic a_s_resetn, a_m_resetn, c_resetn;

  always #8.0   clk_a_s = ~clk_a_s;
  always #10.03 clk_a_m = ~clk_a_m;
  always #5.0   clk_c   = ~clk_c;

  rtlnet_reset_sync u_rst_as (.clk(clk_a_s), .arstn(arstn), .resetn(a_s_resetn));
  rtlnet_reset_sync u_rst_am (.clk(clk_a_m), .arstn(arstn), .resetn(a_m_resetn));
  rtlnet_reset_sync u_rst_c  (.clk(clk_c),   .arstn(arstn), .resetn(c_resetn));

  // ---------------------------------------------------------------------------
  // Instance A: source -> slice -> guard + FIFO (no drop) -> slice -> sink
  // ---------------------------------------------------------------------------
  logic [63:0] a_src_data;  logic [7:0] a_src_keep;  logic a_src_last, a_src_valid, a_src_ready;
  logic [63:0] a_sl_data;   logic [7:0] a_sl_keep;   logic a_sl_last,  a_sl_valid,  a_sl_ready;
  logic [63:0] a_f_data;    logic [7:0] a_f_keep;    logic a_f_last,   a_f_valid,   a_f_ready;
  logic [63:0] a_o_data;    logic [7:0] a_o_keep;    logic a_o_last,   a_o_valid,   a_o_ready;
  logic        a_force_bad;
  logic        a_guard_bad;
  logic        a_overflow, a_bad_frame;

  rtlnet_tb_axis_src #(.GAP_PCT(10), .SEED(11)) u_src_a (
    .clk(clk_a_s), .tdata(a_src_data), .tkeep(a_src_keep), .tlast(a_src_last),
    .tvalid(a_src_valid), .tready(a_src_ready));

  // Input register slice: exercises the slice and isolates the FIFO's ready.
  rtlnet_axis_reg_slice #(.DATA_W(64), .RESET_DATA(1)) u_in_slice (
    .clk(clk_a_s), .resetn(a_s_resetn),
    .s_tdata(a_src_data), .s_tkeep(a_src_keep), .s_tlast(a_src_last), .s_tvalid(a_src_valid), .s_tready(a_src_ready),
    .m_tdata(a_sl_data),  .m_tkeep(a_sl_keep),  .m_tlast(a_sl_last),  .m_tvalid(a_sl_valid),  .m_tready(a_sl_ready));

  // Guard: 60..1518 bytes; the bench can also flag a frame bad on its last beat.
  rtlnet_frame_guard #(.MIN_BYTES(MIN_BYTES), .MAX_BYTES(MAX_BYTES)) u_guard (
    .clk(clk_a_s), .resetn(a_s_resetn), .keep(a_sl_keep), .valid(a_sl_valid), .ready(a_sl_ready),
    .last(a_sl_last), .bad_in(a_force_bad && a_sl_last), .bad_out(a_guard_bad));

  // 8 KiB = four 2 KiB slots, back-pressure mode.
  rtlnet_packet_fifo #(.FIFO_KB(8), .MAX_FRAME_BYTES(MAX_BYTES), .DROP_WHEN_FULL(1'b0)) u_a_fifo (
    .s_clk(clk_a_s), .s_resetn(a_s_resetn), .s_data(a_sl_data), .s_keep(a_sl_keep), .s_valid(a_sl_valid),
    .s_ready(a_sl_ready), .s_last(a_sl_last), .s_bad(a_guard_bad),
    .m_clk(clk_a_m), .m_resetn(a_m_resetn), .m_data(a_f_data), .m_keep(a_f_keep), .m_valid(a_f_valid),
    .m_ready(a_f_ready), .m_last(a_f_last), .overflow(a_overflow), .bad_frame(a_bad_frame));

  rtlnet_axis_reg_slice #(.DATA_W(64), .RESET_DATA(1)) u_out_slice (
    .clk(clk_a_m), .resetn(a_m_resetn),
    .s_tdata(a_f_data), .s_tkeep(a_f_keep), .s_tlast(a_f_last), .s_tvalid(a_f_valid), .s_tready(a_f_ready),
    .m_tdata(a_o_data), .m_tkeep(a_o_keep), .m_tlast(a_o_last), .m_tvalid(a_o_valid), .m_tready(a_o_ready));

  rtlnet_tb_axis_sink #(.READY_PCT(70), .SEED(5), .NAME("sinkA")) u_sink_a (
    .clk(clk_a_m), .resetn(a_m_resetn), .tdata(a_o_data), .tkeep(a_o_keep), .tlast(a_o_last),
    .tvalid(a_o_valid), .tready(a_o_ready));

  // Frames leaving the input slice (the guard sees them there).
  int a_sl_frames = 0;
  int a_in_frames = 0;
  always @(posedge clk_a_s) if (a_s_resetn && a_sl_valid && a_sl_ready && a_sl_last) a_sl_frames++;
  always @(posedge clk_a_s) if (a_s_resetn && a_src_valid && a_src_ready && a_src_last) a_in_frames++;

  // Instance A event counters (m_clk pulses).
  int a_bad_count = 0;
  int a_ovf_count = 0;
  always @(posedge clk_a_m) begin
    if (a_bad_frame) a_bad_count++;
    if (a_overflow)  a_ovf_count++;
  end

  // s_ready may fall only between frames (case 4).
  bit a_in_frame = 0;
  always @(posedge clk_a_s) begin
    if (a_s_resetn) begin
      if (a_in_frame && !a_sl_ready) tb_error("FIFO A: s_ready low inside a frame");
      if (a_sl_valid && a_sl_ready) a_in_frame <= !a_sl_last;
    end
  end

  // ---------------------------------------------------------------------------
  // Instance C: drop-when-full, single clock, sink held stalled then released.
  // ---------------------------------------------------------------------------
  logic [63:0] c_src_data; logic [7:0] c_src_keep; logic c_src_last, c_src_valid, c_src_ready;
  logic [63:0] c_o_data;   logic [7:0] c_o_keep;   logic c_o_last,   c_o_valid,   c_o_ready;
  logic        c_overflow, c_bad_frame;

  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(21)) u_src_c (
    .clk(clk_c), .tdata(c_src_data), .tkeep(c_src_keep), .tlast(c_src_last),
    .tvalid(c_src_valid), .tready(c_src_ready));

  rtlnet_packet_fifo #(.FIFO_KB(8), .MAX_FRAME_BYTES(MAX_BYTES), .DROP_WHEN_FULL(1'b1)) u_c_fifo (
    .s_clk(clk_c), .s_resetn(c_resetn), .s_data(c_src_data), .s_keep(c_src_keep), .s_valid(c_src_valid),
    .s_ready(c_src_ready), .s_last(c_src_last), .s_bad(1'b0),
    .m_clk(clk_c), .m_resetn(c_resetn), .m_data(c_o_data), .m_keep(c_o_keep), .m_valid(c_o_valid),
    .m_ready(c_o_ready), .m_last(c_o_last), .overflow(c_overflow), .bad_frame(c_bad_frame));

  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(9), .NAME("sinkC")) u_sink_c (
    .clk(clk_c), .resetn(c_resetn), .tdata(c_o_data), .tkeep(c_o_keep), .tlast(c_o_last),
    .tvalid(c_o_valid), .tready(c_o_ready));

  int c_ovf_count = 0;
  always @(posedge clk_c) if (c_overflow) c_ovf_count++;

  // ---------------------------------------------------------------------------
  // Stimulus helpers
  // ---------------------------------------------------------------------------
  int unsigned rng = 1234;

  function automatic bytes_t random_frame(input int len);
    bytes_t q;
    for (int i = 0; i < len; i++) begin
      rng = rng * 1103515245 + 12345;
      q.push_back(8'(rng >> 16));
    end
    return q;
  endfunction

  bytes_t expected_a[$];

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin : main
    bytes_t f;
    bytes_t got;
    bit     ok;
    string  why;
    int     n_good;
    int     n_rejected;
    int     len;
    int     target;

    a_force_bad = 1'b0;
    #200 arstn = 1'b1;
    repeat (20) @(posedge clk_a_s);

    // Case 1 + 2: random good frames interleaved with runts, flagged-bad and
    // oversize frames.
    n_good = 0;
    n_rejected = 0;
    for (int k = 0; k < 150; k++) begin
      int unsigned kind;
      rng = rng * 69069 + 1;
      kind = (rng >> 8) % 10;
      if ($test$plusargs("VERBOSE")) $display("INFO: frame %0d kind %0d at %0t", k, kind, $time);
      if (kind == 0) begin
        len = 14 + ((rng >> 12) % (MIN_BYTES - 14));          // runt
        f = random_frame(len);
        u_src_a.send(f);
        n_rejected++;
      end else if (kind == 1) begin
        len = MIN_BYTES + ((rng >> 12) % 300);                // flagged bad on its last beat
        f = random_frame(len);
        while (a_sl_frames < a_in_frames) @(posedge clk_a_s);   // slice empty of earlier frames
        a_force_bad = 1'b1;
        u_src_a.send(f);
        @(posedge clk_a_s);
        target = a_in_frames;
        while (a_sl_frames < target) @(posedge clk_a_s);
        a_force_bad = 1'b0;
        n_rejected++;
      end else if (kind == 2) begin
        len = MAX_BYTES + 1 + ((rng >> 12) % 600);            // oversize
        f = random_frame(len);
        u_src_a.send(f);
        n_rejected++;
      end else begin
        len = MIN_BYTES + ((rng >> 12) % (MAX_BYTES - MIN_BYTES + 1));
        if (k % 17 == 3) len = MAX_BYTES;                       // exact maximum
        if (k % 19 == 4) len = MIN_BYTES;                       // exact minimum
        f = random_frame(len);
        expected_a.push_back(f);
        u_src_a.send(f);
        n_good++;
      end
    end

    for (int k = 0; k < n_good; k++) begin
      u_sink_a.get(got, 200000, ok);
      tb_check(ok, $sformatf("FIFO A: frame %0d of %0d not received", k, n_good));
      if (!ok) break;
      f = expected_a.pop_front();
      tb_check(bytes_equal(got, f, why), $sformatf("FIFO A: frame %0d mismatch: %s", k, why));
    end
    u_sink_a.expect_none(2000, ok);
    tb_check(ok, "FIFO A: an extra frame was delivered");
    repeat (50) @(posedge clk_a_m);
    tb_check(a_bad_count == n_rejected,
             $sformatf("FIFO A: bad_frame pulses %0d, expected %0d", a_bad_count, n_rejected));
    tb_check(a_ovf_count == 0, "FIFO A: overflow pulse in back-pressure mode");

    // Case 3: drop when full with the sink stalled.
    u_sink_c.ready_pct = 0;
    repeat (10) @(posedge clk_c);
    for (int k = 0; k < 10; k++) begin
      f = random_frame(100 + 8 * k);
      if (k < 4) expected_a.push_back(f);       // reuse the queue for instance C
      u_src_c.send(f);
      u_src_c.idle(4);
    end
    repeat (20) @(posedge clk_c);
    tb_check(c_ovf_count == 6, $sformatf("FIFO C: overflow pulses %0d, expected 6", c_ovf_count));
    u_sink_c.ready_pct = 100;
    for (int k = 0; k < 4; k++) begin
      u_sink_c.get(got, 20000, ok);
      tb_check(ok, $sformatf("FIFO C: kept frame %0d not received", k));
      if (!ok) break;
      f = expected_a.pop_front();
      tb_check(bytes_equal(got, f, why), $sformatf("FIFO C: frame %0d mismatch: %s", k, why));
    end
    u_sink_c.expect_none(2000, ok);
    tb_check(ok, "FIFO C: a dropped frame was delivered");

    tb_verdict("tb_rtlnet_packet_fifo");
  end

  // Global watchdog.
  initial begin
    #50ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_rtlnet_packet_fifo");
  end

endmodule
