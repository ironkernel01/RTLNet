// -----------------------------------------------------------------------------
// File: tb_rtlnet_csi2_rx_pattern.sv
// Purpose: self-checking bench for rtlnet_csi2_rx_pattern on reduced frames (320 x 96 and 448 x 128 pixels, bar width 40 and
//   56): every moving pattern over long frame sequences against the CRC-32 of the C model (csi2_bars_model.c --crc-mem-small).
// Cases:
//   1. For both modes and 17 combinations of pattern 0..4 and speed (4, -7, 24, +32, -32 for patterns 1, 2 and 4), 24 frames
//      k = 0..23 started back to back: the CRC-32 of the frame bytes (Y0 Cb Y1 Cr, packed lines) equals the C model, the frame
//      has W / 2 words in each of H lines, tuser on the first word only, tlast on the last word of each line. The 24 frames take the
//      scroll offset through its wrap, the box through every bounce and fold of its triangle waves (the box phase starts at 48, 8).
//   2. A restart in the same clock as the start (the PATTERN register and its restart pulse appear together): that frame is k = 0
//      of the new pattern, the next is k = 1. A restart one clock before the start, and in the middle of a frame (the frame
//      in progress finishes unchanged, the next is k = 0 of the new pattern). A start one clock before the new pattern appears
//      sends the old pattern's next frame.
//   3. pat_frame counts the frames started since the restart (0 after it); busy is low between frames and high from the start
//      until the last word is accepted.
//   4. TB_GAP = 1: random output ready (75 percent) and a 500-clock stall in the middle of a line: the CRCs are unchanged.
//   5. TB_GAP = 0: line start to line start equals the line period (180 and 250 clocks).
// Defines: TB_GAP (default 0), TB_CRC_FILE (path of the table, default relative to the simulation work directory .sim/<run>).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-10-2026
//   * 11-10-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_GAP
  `define TB_GAP 0
`endif
`ifndef TB_CRC_FILE
  `define TB_CRC_FILE "../../cores/rtlnet_csi2_rx/testbench/pattern_crc_small.mem"
`endif

module tb_rtlnet_csi2_rx_pattern;

  import rtlnet_tb_pkg::*;

  localparam bit GAP = (`TB_GAP != 0);

  localparam int WORDS0 = 160;
  localparam int WORDS1 = 224;
  localparam int LINES0 = 96;
  localparam int LINES1 = 128;
  localparam int PERIOD0 = 180;
  localparam int PERIOD1 = 250;
  localparam int NCOMBO  = 17;
  localparam int NFRAMES = 24;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #5.0 clk = ~clk;

  logic        start = 1'b0;
  logic [1:0]  mode = 2'd0;
  logic [2:0]  pattern = 3'd0;
  logic [7:0]  speed = 8'd4;
  logic        restart = 1'b0;
  logic        busy;
  logic [31:0] pat_frame;
  logic [31:0] m_tdata;
  logic        m_tvalid;
  logic        m_tready = 1'b1;
  logic        m_tlast;
  logic        m_tuser;

  rtlnet_csi2_rx_pattern #(
    .WORDS_720(WORDS0), .WORDS_1080(WORDS1), .LINES_720(LINES0), .LINES_1080(LINES1),
    .LINE_PERIOD_720(PERIOD0), .LINE_PERIOD_1080(PERIOD1), .BOX_X0(48), .BOX_Y0(8)
  ) dut (
    .clk(clk), .resetn(resetn), .start(start), .mode(mode), .pattern(pattern), .speed(speed), .restart(restart),
    .busy(busy), .pat_frame(pat_frame),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast), .m_tuser(m_tuser));

  // Expected CRCs from the C model, order mode, combination, k.
  logic [31:0] exp_crc [0:2*NCOMBO*NFRAMES-1];
  int cpat [NCOMBO];
  int cspd [NCOMBO];

  initial begin
    $readmemh(`TB_CRC_FILE, exp_crc);
    cpat[0]  = 0; cspd[0]  = 4;
    cpat[1]  = 1; cspd[1]  = 4;   cpat[2]  = 1; cspd[2]  = -7;  cpat[3]  = 1; cspd[3]  = 24;  cpat[4]  = 1; cspd[4]  = 32;  cpat[5]  = 1; cspd[5]  = -32;
    cpat[6]  = 2; cspd[6]  = 4;   cpat[7]  = 2; cspd[7]  = -7;  cpat[8]  = 2; cspd[8]  = 24;  cpat[9]  = 2; cspd[9]  = 32;  cpat[10] = 2; cspd[10] = -32;
    cpat[11] = 3; cspd[11] = 4;
    cpat[12] = 4; cspd[12] = 4;   cpat[13] = 4; cspd[13] = -7;  cpat[14] = 4; cspd[14] = 24;  cpat[15] = 4; cspd[15] = 32;  cpat[16] = 4; cspd[16] = -32;
  end

  function automatic logic [31:0] expected(input int m, input int c, input int k);
    return exp_crc[(m * NCOMBO + c) * NFRAMES + k];
  endfunction

  // ---------------------------------------------------------------------------
  // Random output ready and a deterministic stall (driven from the monitor block below)
  // ---------------------------------------------------------------------------
  int unsigned rng = 32'hC0DE_1234;
  int stall_left = 0;
  longint cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  // ---------------------------------------------------------------------------
  // Output monitor: CRC-32 of the frame bytes, structure checks
  // ---------------------------------------------------------------------------
  logic [31:0] crc_tbl [256];
  initial begin
    for (int n = 0; n < 256; n++) begin
      logic [31:0] c;
      c = n;
      for (int b = 0; b < 8; b++) c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
      crc_tbl[n] = c;
    end
  end

  logic [31:0] crc_acc = '1;
  logic [31:0] frame_crc_v = '0;
  int          frames_done = 0;
  int          mon_line = 0;
  int          mon_word = 0;
  int          frame_words = 0;
  int          cur_w = 0;
  int          cur_h = 0;
  int          cur_period = 0;
  bit          in_frame = 1'b0;
  longint      line_cycle = 0;
  int          line_checked = 0;
  int          words_total = 0;
  logic [31:0] pat_frame_at_done = '0;

  always @(posedge clk) begin
    if (resetn === 1'b1 && m_tvalid && m_tready) begin
      words_total++;
      tb_check(busy, "busy low while a word is presented");
      if (m_tuser) begin
        tb_check(!in_frame, "start of frame inside a frame");
        in_frame = 1'b1;
        mon_line = 0;
        mon_word = 0;
        crc_acc = '1;
        cur_w = (mode == 2'd1) ? WORDS1 : WORDS0;
        cur_h = (mode == 2'd1) ? LINES1 : LINES0;
        cur_period = (mode == 2'd1) ? PERIOD1 : PERIOD0;
      end
      tb_check(in_frame, "a word outside a frame");
      tb_check(m_tuser == (mon_line == 0 && mon_word == 0), "tuser");
      tb_check(m_tlast == (mon_word == cur_w - 1), $sformatf("tlast at word %0d of %0d", mon_word, cur_w));
      for (int i = 0; i < 4; i++) crc_acc = crc_tbl[(crc_acc ^ m_tdata[i*8 +: 8]) & 32'hFF] ^ (crc_acc >> 8);
      if (mon_word == 0 && mon_line > 0 && !GAP) begin
        line_checked++;
        tb_check(cycle - line_cycle == longint'(cur_period), $sformatf("line spacing %0d, expected %0d", cycle - line_cycle, cur_period));
      end
      if (mon_word == 0) line_cycle = cycle;
      if (mon_word == cur_w - 1) begin
        mon_word = 0;
        mon_line++;
      end else begin
        mon_word++;
      end
      if (mon_line == cur_h) begin
        frame_crc_v = ~crc_acc;
        in_frame = 1'b0;
        pat_frame_at_done = pat_frame;
        frames_done++;
      end
      // The long stall of case 4: 500 clocks in the middle of line 5 of the frames of mode 1, pattern 4, speed 24.
      if (GAP && in_frame && mon_line == 5 && mon_word == 100 && mode == 2'd1 && pattern == 3'd4 && speed == 8'd24) stall_left = 500;
    end
    // Output ready for the next clock.
    rng = rng * 32'd1103515245 + 32'd12345;
    if (stall_left > 0) begin
      m_tready <= 1'b0;
      stall_left = stall_left - 1;
    end else if (GAP) begin
      m_tready <= (int'((rng >> 8) % 100) < 75);
    end else begin
      m_tready <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  int frames_started_by_tb = 0;

  // Pulse start for one clock (the generator is idle) and return at once.
  task automatic pulse_start();
    @(posedge clk);
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;
    frames_started_by_tb++;
  endtask

  // Wait until the frame count reaches n (bounded).
  task automatic wait_done(input int n);
    longint t0;
    t0 = cycle;
    while (frames_done < n && (cycle - t0) < 3_000_000) @(posedge clk);
    tb_check(frames_done >= n, $sformatf("frame %0d did not complete", n));
    @(posedge clk);
    @(posedge clk);
  endtask

  // Wait for the generator to go idle after the last word.
  task automatic wait_idle();
    longint t0;
    t0 = cycle;
    while (busy && (cycle - t0) < 3_000_000) @(posedge clk);
    tb_check(!busy, "busy did not fall after the frame");
  endtask

  // One frame: start it, wait for its last word, return its CRC.
  task automatic one_frame(output logic [31:0] crc);
    int target;
    target = frames_done + 1;
    pulse_start();
    wait_done(target);
    wait_idle();
    crc = frame_crc_v;
  endtask

  // Set the pattern registers and give the restart pulse the register file gives one clock later.
  task automatic set_pattern(input int p, input int s, input int m);
    @(posedge clk);
    pattern <= 3'(p);
    speed   <= 8'(s);
    mode    <= 2'(m);
    restart <= 1'b1;
    @(posedge clk);
    restart <= 1'b0;
    @(posedge clk);
  endtask

  logic [31:0] got;
  int checked = 0;
  int errors_seen = 0;

  initial begin
    wait (resetn === 1'b1);
    repeat (4) @(posedge clk);
    tb_check(!busy, "busy after reset");
    tb_check(pat_frame == 32'd0, "pat_frame after reset");

    // 1. Every combination, 24 frames each, both modes.
    for (int m = 0; m < 2; m++) begin
      for (int c = 0; c < NCOMBO; c++) begin
        set_pattern(cpat[c], cspd[c], m);
        tb_check(pat_frame == 32'd0, "pat_frame is not 0 after a restart");
        for (int k = 0; k < NFRAMES; k++) begin
          one_frame(got);
          tb_check(got === expected(m, c, k), $sformatf("mode %0d pattern %0d speed %0d k %0d: CRC 0x%08h, C model 0x%08h", m, cpat[c], cspd[c], k, got, expected(m, c, k)));
          tb_check(pat_frame_at_done == 32'(k + 1), $sformatf("pat_frame %0d after frame k %0d", pat_frame_at_done, k));
          checked++;
        end
      end
    end

    // 2. Restart timing against the start. Combination 14 (pattern 4, speed 24) then 7 (pattern 2, speed -7), mode 1.
    set_pattern(cpat[14], cspd[14], 1);
    one_frame(got); tb_check(got === expected(1, 14, 0), "restart case: k 0");
    one_frame(got); tb_check(got === expected(1, 14, 1), "restart case: k 1");
    // 2a. Start in the clock the restart appears: the frame is k = 0 of the new pattern.
    @(posedge clk);
    pattern <= 3'(cpat[7]); speed <= 8'(cspd[7]); restart <= 1'b1; start <= 1'b1;
    @(posedge clk);
    restart <= 1'b0; start <= 1'b0;
    wait_done(frames_done + 1); wait_idle();
    tb_check(frame_crc_v === expected(1, 7, 0), "start in the restart clock: not k = 0 of the new pattern");
    one_frame(got); tb_check(got === expected(1, 7, 1), "start in the restart clock: next frame is not k = 1");
    // 2b. Start one clock before the new pattern appears: the old pattern's next frame, then k = 0 of the new one.
    begin
      int target;
      target = frames_done + 1;
      @(posedge clk);
      start <= 1'b1;
      @(posedge clk);
      start <= 1'b0;
      pattern <= 3'(cpat[14]); speed <= 8'(cspd[14]); restart <= 1'b1;
      @(posedge clk);
      restart <= 1'b0;
      wait_done(target); wait_idle();
      tb_check(frame_crc_v === expected(1, 7, 2), "start before the restart: the old pattern's frame is not k = 2");
      one_frame(got); tb_check(got === expected(1, 14, 0), "start before the restart: next frame is not k = 0 of the new pattern");
    end
    // 2c. Restart in the middle of a frame: that frame finishes as it began, the next is k = 0 of the new pattern.
    begin
      int target;
      target = frames_done + 1;
      pulse_start();
      repeat (3000) @(posedge clk);
      tb_check(busy && in_frame, "no frame in progress at the mid-frame restart");
      pattern <= 3'(cpat[3]); speed <= 8'(cspd[3]); restart <= 1'b1;
      @(posedge clk);
      restart <= 1'b0;
      wait_done(target); wait_idle();
      tb_check(frame_crc_v === expected(1, 14, 1), "mid-frame restart: the frame in progress changed");
      one_frame(got); tb_check(got === expected(1, 3, 0), "mid-frame restart: next frame is not k = 0");
      tb_check(pat_frame_at_done == 32'd1, "pat_frame after the mid-frame restart case");
    end

    // 3. busy: low in the idle time between frames.
    tb_check(!busy, "busy while idle");
    repeat (50) @(posedge clk);
    tb_check(!busy && pat_frame == 32'd1, "pat_frame or busy changed while idle");

    tb_check(checked == 2 * NCOMBO * NFRAMES, $sformatf("checked %0d frames", checked));
    tb_check(GAP || line_checked > 20000, $sformatf("line spacing checked %0d times", line_checked));
    $display("csi2_pattern: %0d frames checked against the C model, %0d words, %0d line spacings, GAP %0d", checked, words_total, line_checked, GAP);
    tb_verdict("tb_rtlnet_csi2_rx_pattern");
  end

  initial begin
    #2000ms;
    tb_error("watchdog: the bench did not finish");
    tb_verdict("tb_rtlnet_csi2_rx_pattern");
  end

  initial begin
    repeat (8) #20;
    resetn = 1'b1;
  end

endmodule
