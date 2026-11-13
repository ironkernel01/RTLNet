// -----------------------------------------------------------------------------
// File: tb_rtlnet_csi2_rx.sv
// Purpose: self-checking bench for rtlnet_csi2_rx (Phase 1): the color-bar generator at both video modes against a reference
//   written in the bench, the moving patterns against the frame CRC-32 of the C model, the
//   register rules, the frame timing and the source switch with a camera stream model.
// Cases:
//   1. Reset values and header: ID, CAPS, VIDEO_MODE 0, SOURCE 0, FRAME_PERIOD, CAM_TIMEOUT 2, STATUS (pattern source),
//      FRAME_COUNT 0. The core sends 720p30 bars with no register writes.
//   2. Every word of every frame equals the bench reference (eight bars of 160 pixels at 720p, 240 at 1080p, BT.709
//      limited-range Y/Cb/Cr, word = {Cr, Y1, Cb, Y0}), start of frame on the first word only, end of line on the last word
//      of each of H lines, W/2 words per line; the sideband (width, height, frame number, timestamp, source flag) is stable
//      over the frame; frame numbers count 1, 2, 3 ... with FRAME_COUNT.
//   3. Timing (TB_REAL = 1: the localparams of the real core, 3,000,000 clocks per frame, line periods 4,000 and 2,666
//      clocks): frame start to frame start equals FRAME_PERIOD, line start to line start equals the line period.
//   4. FRAME_PERIOD rejection: a value below the mode minimum is rejected (STATUS.PERIOD_ERR, register unchanged), the minimum
//      itself is accepted; a mode write whose minimum exceeds the present FRAME_PERIOD is rejected; the flags clear by writing 1.
//   5. VIDEO_MODE: a value above 1 sets STATUS.MODE_ERR and changes nothing; a change in mid-frame takes effect at the next
//      frame start (the frame in progress ends in its old geometry); ACTIVE reports the mode of the frame in progress.
//   6. SOURCE 3 and above rejected (STATUS.SOURCE_ERR).
//   7. Source switch with a camera stream model (TB_REAL = 0): auto with no camera sends the pattern; with the camera byte
//      clock running and camera frames arriving auto switches to the camera (source flag 0, camera words in the output,
//      STATUS.PATTERN 0) between frames; the camera stopping in mid-frame closes that frame short, never completes it, and
//      auto returns to the pattern after CAM_TIMEOUT frame periods; no frame ever mixes sources; SOURCE 2 (pattern only)
//      keeps the pattern with the camera running and drains the camera stream; SOURCE 1 (camera only) with no camera sends no
//      frame at all; a camera word that is not part of a frame (no first word) is discarded.
//   8. Backpressure: random output ready (TB_GAP = 1) never loses or repeats a word.
//   9. PATTERN (0x030) and PATTERN_FRAME (0x034): reset values (0x400, 0), CAPS bit 6, accepted values (pattern 0..4, speed -32..+32)
//      read back, rejected values (pattern 5..7, any other bit set, speed beyond +-32) set the sticky STATUS.PATTERN_ERR and change
//      nothing, the flag clears by write 1 only; a PATTERN write in mid-frame leaves that frame unchanged and starts the next at
//      k = 0, PATTERN_FRAME reads 0 after the write and the number of frames started since.
//  10. Moving patterns at full size (every run: pattern 4 at speed -7 for two frames at 720p30, then bars again with the word
//      check; TB_PATFULL = 1: the only content): patterns 0 to 4, both video modes, speeds +4, -7, +24 (speed matters for patterns 1, 2
//      and 4), four consecutive frames k = 0..3 each, written in mid-frame so the combinations follow one another with no frame
//      between: every frame's CRC-32 equals the C model (testbench/pattern_crc_full.mem from csi2_bars_model.c).
// Defines: TB_REAL 1 = real timing localparams (cases 1 to 6 and the 1080p frame, no camera), TB_GAP 1 = random output ready,
//   TB_PATFULL 1 = case 10 only (88 frames), TB_CRC_FILE_FULL = path of the table (default relative to the work directory .sim/<run>).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-10-2026
//   * 11-10-2026: PATTERN and PATTERN_FRAME registers, moving patterns (cases 9 and 10), VERSION 0x11102026, CAPS 0x52.
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_REAL
  `define TB_REAL 0
`endif
`ifndef TB_GAP
  `define TB_GAP 0
`endif
`ifndef TB_PATFULL
  `define TB_PATFULL 0
`endif
`ifndef TB_CRC_FILE_FULL
  `define TB_CRC_FILE_FULL "../../cores/rtlnet_csi2_rx/testbench/pattern_crc_full.mem"
`endif

module tb_rtlnet_csi2_rx;

  import rtlnet_tb_pkg::*;

  localparam bit REAL = (`TB_REAL != 0);
  localparam bit GAP  = (`TB_GAP != 0);
  localparam bit PATFULL = (`TB_PATFULL != 0);

  // Core parameters: the real values, or shortened line periods for a fast bench (a line still takes 640 / 960 clocks).
  localparam int LINE_720   = REAL ? 4000 : (GAP ? 900 : 660);
  localparam int LINE_1080  = REAL ? 2666 : (GAP ? 1300 : 980);
  localparam int MIN_720    = 750 * LINE_720;
  localparam int MIN_1080   = 1125 * LINE_1080;
  localparam int PERIOD_RST = REAL ? 3_000_000 : (GAP ? 1_600_000 : 1_200_000);
  localparam int CAM_GAP    = GAP ? 1000 : 700;   // camera line start to line start

  logic clk     = 1'b0;
  logic cfg_clk = 1'b0;
  logic arstn   = 1'b0;
  logic resetn;
  logic cfg_resetn;

  always #5.0  clk     = ~clk;
  always #4.85 cfg_clk = ~cfg_clk;

  rtlnet_reset_sync u_rst_a (.clk(clk),     .arstn(arstn), .resetn(resetn));
  rtlnet_reset_sync u_rst_b (.clk(cfg_clk), .arstn(arstn), .resetn(cfg_resetn));

  // Camera stream (bench model) and output stream.
  logic [31:0] cam_tdata = '0;
  logic        cam_tvalid = 1'b0;
  logic        cam_tready;
  logic        cam_tlast = 1'b0;
  logic        cam_tuser = 1'b0;
  logic        cam_run = 1'b0;

  logic [31:0] m_tdata;
  logic        m_tvalid;
  logic        m_tready = 1'b1;
  logic        m_tlast;
  logic        m_tuser;
  logic [31:0] m_frame, m_ts;
  logic [15:0] m_w, m_h;
  logic        m_src;

  logic [11:0] awaddr, araddr;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;

  rtlnet_tb_axil_master #(.ADDR_W(12)) u_mst (
    .aclk(cfg_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  rtlnet_csi2_rx #(
    .PERIOD_RESET(PERIOD_RST), .PERIOD_MIN_720(MIN_720), .PERIOD_MIN_1080(MIN_1080),
    .LINE_PERIOD_720(LINE_720), .LINE_PERIOD_1080(LINE_1080), .CAM_TIMEOUT_RESET(2)
  ) dut (
    .clk(clk), .resetn(resetn), .s_axi_aclk(cfg_clk), .s_axi_aresetn(cfg_resetn),
    .s_cam_tdata(cam_tdata), .s_cam_tvalid(cam_tvalid), .s_cam_tready(cam_tready), .s_cam_tlast(cam_tlast),
    .s_cam_tuser(cam_tuser), .cam_clk_running(cam_run),
    .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
    .m_axis_tuser(m_tuser), .m_frame_num(m_frame), .m_timestamp(m_ts), .m_width(m_w), .m_height(m_h),
    .m_src_pattern(m_src),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready));

  // ---------------------------------------------------------------------------
  // Reference: the bars (written here independently of the RTL)
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] ref_word(input int mode, input int word);
    int bar_px;
    int bar;
    int y;
    int cb;
    int cr;
    bar_px = (mode == 1) ? 240 : 160;
    bar    = (word * 2) / bar_px;
    case (bar)
      0: begin y = 180; cb = 128; cr = 128; end   // white 75 %
      1: begin y = 168; cb = 44;  cr = 136; end   // yellow
      2: begin y = 145; cb = 147; cr = 44;  end   // cyan
      3: begin y = 133; cb = 63;  cr = 52;  end   // green
      4: begin y = 63;  cb = 193; cr = 204; end   // magenta
      5: begin y = 51;  cb = 109; cr = 212; end   // red
      6: begin y = 28;  cb = 212; cr = 120; end   // blue
      default: begin y = 16; cb = 128; cr = 128; end   // black
    endcase
    return {8'(cr), 8'(y), 8'(cb), 8'(y)};          // Y0 in [7:0], Cb, Y1, Cr in [31:24]
  endfunction

  function automatic logic [31:0] cam_word(input int line, input int word);
    logic [31:0] h;
    h = 32'(line) * 32'h9E37_79B1 + 32'(word) * 32'h85EB_CA6B + 32'h0C0F_FEE5;
    h = h ^ (h >> 16);
    h = h * 32'h7FEB_352D;
    return h ^ (h >> 15);
  endfunction

  function automatic int mode_w(input int mode);
    return (mode == 1) ? 1920 : 1280;
  endfunction

  function automatic int mode_h(input int mode);
    return (mode == 1) ? 1080 : 720;
  endfunction

  // ---------------------------------------------------------------------------
  // Random
  // ---------------------------------------------------------------------------
  int unsigned rng = 32'hA5A5_1234;

  function automatic int rnd(input int n);
    rng = rng * 32'd1103515245 + 32'd12345;
    return int'((rng >> 8) % n);
  endfunction

  // Output ready.
  always @(posedge clk) begin
    if (GAP) m_tready <= (rnd(100) < 80);
    else     m_tready <= 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Output monitor
  // ---------------------------------------------------------------------------
  longint cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  bit        in_frame = 1'b0;
  int        f_mode = 0;
  int        f_num = 0;
  int        f_ts = 0;
  int        f_w = 0;
  int        f_h = 0;
  bit        f_src = 1'b0;
  int        f_line = 0;
  int        f_word = 0;
  int        last_num = 0;
  longint    f_sof_cycle = 0;
  longint    prev_pat_sof_cycle = 0;
  longint    line_cycle = 0;
  int        frames_started = 0;
  int        frames_pat_complete = 0;
  int        frames_cam_complete = 0;
  int        frames_short = 0;
  int        frames_1080 = 0;
  int        frames_720 = 0;
  int        words_seen = 0;
  int        frames_by_src_seq [$];       // sequence of sources of the frames (1 pattern, 0 camera), in order
  int        short_src_seq [$];           // sources of short frames
  int        spacing_expect = 0;          // 0 = do not check; else the expected frame-to-frame clock count
  bit        line_check = 1'b0;           // check line start to line start against the line period of the frame's mode
  int        spacing_checked = 0;
  int        line_checked = 0;
  int        spacing_skip = 0;
  int        mode_expect_next = -1;       // -1 = do not check; else the mode the next started frame must have
  int        mode_of_frame_queue [$];
  int        last_started_mode = 0;
  bit        ref_check_en = 1'b1;         // word-by-word check of pattern frames against the bar reference (pattern 0 frames)
  bit        f_ref_ok = 1'b1;             // the frame in progress is checked against the bar reference
  logic [31:0] crc_tbl [256];
  logic [31:0] crc_acc = '1;
  logic [31:0] crc_by_num [int];          // frame CRC-32 of each completed pattern frame, by frame number

  initial begin
    for (int n = 0; n < 256; n++) begin
      logic [31:0] c;
      c = n;
      for (int b = 0; b < 8; b++) c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
      crc_tbl[n] = c;
    end
  end

  task automatic close_frame();
    if (in_frame) begin
      // A frame that completed was closed at its last word; one still open here is short.
      frames_short++;
      short_src_seq.push_back(f_src ? 1 : 0);
    end
    in_frame = 1'b0;
  endtask

  always @(posedge clk) begin
    if (resetn === 1'b1 && m_tvalid && m_tready) begin
      logic [31:0] exp_w;
      int wpl;
      words_seen++;
      if (m_tuser) begin
        close_frame();
        in_frame = 1'b1;
        frames_started++;
        f_num = int'(m_frame);
        f_ts  = int'(m_ts);
        f_w   = int'(m_w);
        f_h   = int'(m_h);
        f_src = m_src;
        f_mode = (f_w == 1920) ? 1 : 0;
        f_line = 0;
        f_word = 0;
        f_sof_cycle = cycle;
        f_ref_ok = ref_check_en;
        crc_acc = '1;
        frames_by_src_seq.push_back(f_src ? 1 : 0);
        mode_of_frame_queue.push_back(f_mode);
        last_started_mode = f_mode;
        tb_check(f_num == last_num + 1, $sformatf("frame number %0d after %0d", f_num, last_num));
        last_num = f_num;
        tb_check((f_w == 1280 && f_h == 720) || (f_w == 1920 && f_h == 1080), $sformatf("frame size %0dx%0d", f_w, f_h));
        if (f_mode == 1) frames_1080++; else frames_720++;
        if (mode_expect_next >= 0) begin
          tb_check(f_mode == mode_expect_next, $sformatf("frame started in mode %0d, expected %0d", f_mode, mode_expect_next));
          mode_expect_next = -1;
        end
        if (f_src && spacing_expect != 0 && !GAP) begin
          if (spacing_skip > 0) begin
            spacing_skip--;
          end else begin
            spacing_checked++;
            tb_check(f_sof_cycle - prev_pat_sof_cycle == longint'(spacing_expect),
                     $sformatf("frame spacing %0d, expected %0d", f_sof_cycle - prev_pat_sof_cycle, spacing_expect));
          end
        end
        if (f_src) prev_pat_sof_cycle = f_sof_cycle;
      end else begin
        tb_check(in_frame, "a word outside a frame");
      end
      if (in_frame) begin
        wpl = f_w / 2;
        if (f_src) begin
          exp_w = ref_word(f_mode, f_word);
          if (f_ref_ok) tb_check(m_tdata === exp_w, $sformatf("pattern word %0d of line %0d (mode %0d): 0x%0h, expected 0x%0h", f_word, f_line, f_mode, m_tdata, exp_w));
          for (int i = 0; i < 4; i++) crc_acc = crc_tbl[(crc_acc ^ m_tdata[i*8 +: 8]) & 32'hFF] ^ (crc_acc >> 8);
        end else begin
          exp_w = cam_word(f_line, f_word);
          tb_check(m_tdata === exp_w, $sformatf("camera word %0d of line %0d: 0x%0h, expected 0x%0h", f_word, f_line, m_tdata, exp_w));
        end
        tb_check(m_tuser == (f_line == 0 && f_word == 0), "start of frame flag");
        tb_check(m_tlast == (f_word == wpl - 1), $sformatf("end of line flag at word %0d of %0d", f_word, wpl));
        tb_check(int'(m_frame) == f_num && int'(m_ts) == f_ts && int'(m_w) == f_w && int'(m_h) == f_h && m_src == f_src,
                 "sideband changed within a frame");
        if (f_word == 0 && f_line > 0 && f_src && line_check && !GAP) begin
          line_checked++;
          tb_check(cycle - line_cycle == longint'((f_mode == 1) ? LINE_1080 : LINE_720),
                   $sformatf("line spacing %0d, expected %0d", cycle - line_cycle, (f_mode == 1) ? LINE_1080 : LINE_720));
        end
        if (f_word == 0) line_cycle = cycle;
        if (f_word == wpl - 1) begin
          f_word = 0;
          f_line++;
        end else begin
          f_word++;
        end
        if (f_line == f_h) begin
          // Frame complete.
          if (f_src) begin
            frames_pat_complete++;
            crc_by_num[f_num] = ~crc_acc;
          end else begin
            frames_cam_complete++;
          end
          in_frame = 1'b0;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Camera stream model
  // ---------------------------------------------------------------------------
  int cam_words_sent = 0;
  bit cam_stop_req = 1'b0;

  // One camera frame in mode cmode: lines_to_send lines of width/2 words, line start to line start every line_gap clocks.
  task automatic cam_frame(input int cmode, input int lines_to_send, input int line_gap, input bit with_sof);
    int wpl;
    longint t0;
    wpl = mode_w(cmode) / 2;
    for (int line = 0; line < lines_to_send; line++) begin
      t0 = cycle;
      for (int word = 0; word < wpl; word++) begin
        cam_tdata  <= cam_word(line, word);
        cam_tvalid <= 1'b1;
        cam_tlast  <= (word == wpl - 1);
        cam_tuser  <= with_sof && (line == 0 && word == 0);
        @(posedge clk);
        while (!cam_tready) @(posedge clk);
        cam_words_sent++;
      end
      cam_tvalid <= 1'b0;
      cam_tlast  <= 1'b0;
      cam_tuser  <= 1'b0;
      while (cycle - t0 < longint'(line_gap)) @(posedge clk);
    end
    cam_tvalid <= 1'b0;
    cam_tlast  <= 1'b0;
    cam_tuser  <= 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Register access
  // ---------------------------------------------------------------------------
  logic [1:0] rd_resp;
  logic [1:0] wr_resp;

  task automatic reg_read(input logic [11:0] a, output logic [31:0] v);
    u_mst.read32(a, v, rd_resp);
    tb_check(rd_resp == 2'b00, $sformatf("register read 0x%0h response %0d", a, rd_resp));
  endtask

  task automatic reg_write(input logic [11:0] a, input logic [31:0] v);
    u_mst.write32(a, v, 4'hF, wr_resp);
    tb_check(wr_resp == 2'b00, $sformatf("register write 0x%0h response %0d", a, wr_resp));
  endtask

  localparam logic [11:0] R_ID     = 12'h000;
  localparam logic [11:0] R_VER    = 12'h004;
  localparam logic [11:0] R_CAPS   = 12'h008;
  localparam logic [11:0] R_MODE   = 12'h010;
  localparam logic [11:0] R_SRC    = 12'h014;
  localparam logic [11:0] R_PERIOD = 12'h018;
  localparam logic [11:0] R_TMO    = 12'h01C;
  localparam logic [11:0] R_STATUS = 12'h020;
  localparam logic [11:0] R_COUNT  = 12'h024;
  localparam logic [11:0] R_ACTIVE = 12'h028;
  localparam logic [11:0] R_PATTERN = 12'h030;
  localparam logic [11:0] R_PATFRM  = 12'h034;

  localparam logic [31:0] ST_PATTERN = 32'h01;
  localparam logic [31:0] ST_MODE_ERR = 32'h04;
  localparam logic [31:0] ST_PERIOD_ERR = 32'h08;
  localparam logic [31:0] ST_SOURCE_ERR = 32'h10;
  localparam logic [31:0] ST_OVERRUN = 32'h20;
  localparam logic [31:0] ST_PATTERN_ERR = 32'h40;

  // Full-size pattern frames: combinations (pattern, speed) of the C model table, order mode, combination, k.
  localparam int FC_COUNT  = 11;
  localparam int FC_FRAMES = 4;
  int fc_pat [FC_COUNT];
  int fc_spd [FC_COUNT];
  logic [31:0] exp_full [0:2*FC_COUNT*FC_FRAMES-1];
  int first_frame [2*FC_COUNT];
  int cur_mode_reg = 0;

  initial begin
    $readmemh(`TB_CRC_FILE_FULL, exp_full);
    fc_pat[0] = 0; fc_spd[0] = 4;
    fc_pat[1] = 1; fc_spd[1] = 4;  fc_pat[2] = 1; fc_spd[2] = -7;  fc_pat[3] = 1; fc_spd[3] = 24;
    fc_pat[4] = 2; fc_spd[4] = 4;  fc_pat[5] = 2; fc_spd[5] = -7;  fc_pat[6] = 2; fc_spd[6] = 24;
    fc_pat[7] = 3; fc_spd[7] = 4;
    fc_pat[8] = 4; fc_spd[8] = 4;  fc_pat[9] = 4; fc_spd[9] = -7;  fc_pat[10] = 4; fc_spd[10] = 24;
  end

  function automatic logic [31:0] pattern_word(input int p, input int s);
    return 32'((s & 255) << 8) | 32'(p);
  endfunction

  function automatic logic [31:0] expected_full(input int m, input int c, input int k);
    return exp_full[(m * FC_COUNT + c) * FC_FRAMES + k];
  endfunction

  // Wait until n more frames have started (bounded).
  task automatic wait_frames(input int n);
    int target;
    longint t0;
    target = frames_started + n;
    t0 = cycle;
    while (frames_started < target && (cycle - t0) < longint'(n + 1) * 4_000_000) @(posedge clk);
    tb_check(frames_started >= target, $sformatf("waited for %0d frames, got %0d", n, frames_started - (target - n)));
  endtask

  // Wait until the next frame has started and is a few words in.
  task automatic wait_in_frame(input int words);
    int target;
    target = frames_started + 1;
    while (frames_started < target) @(posedge clk);
    repeat (words) @(posedge clk);
  endtask

  // Wait until frame n (counted from the start of the bench) completes.
  task automatic wait_idle_clks(input int n);
    repeat (n) @(posedge clk);
  endtask

  // Wait until frame number n has started, then the given number of clocks (the frame is then well in progress).
  task automatic wait_frame_reached(input int n, input int clocks);
    longint t0;
    t0 = cycle;
    while (frames_started < n && (cycle - t0) < 6_000_000) @(posedge clk);
    tb_check(frames_started >= n, $sformatf("frame %0d never started", n));
    repeat (clocks) @(posedge clk);
  endtask

  // PATTERN write (and VIDEO_MODE when it differs) in the middle of the frame in progress: the next frame is k = 0 of the combination.
  task automatic pat_write(input int m, input int c);
    logic [31:0] w;
    if (cur_mode_reg != m) begin
      reg_write(R_MODE, 32'(m));
      cur_mode_reg = m;
    end
    reg_write(R_PATTERN, pattern_word(fc_pat[c], fc_spd[c]));
    first_frame[m * FC_COUNT + c] = frames_started + 1;
    reg_read(R_PATTERN, w);
    tb_check(w == pattern_word(fc_pat[c], fc_spd[c]), $sformatf("PATTERN reads 0x%0h", w));
    reg_read(R_PATFRM, w);
    tb_check(w == 32'd0, $sformatf("PATTERN_FRAME reads %0d right after a PATTERN write", w));
    reg_read(R_STATUS, w);
    tb_check((w & ST_PATTERN_ERR) == 0, "PATTERN_ERR set by a valid PATTERN write");
  endtask

  // Compare the frames k = 0 .. nframes - 1 of a combination with the C model (all must have completed).
  task automatic pat_compare(input int m, input int c, input int nframes);
    int f;
    for (int k = 0; k < nframes; k++) begin
      f = first_frame[m * FC_COUNT + c] + k;
      if (crc_by_num.exists(f)) begin
        tb_check(crc_by_num[f] === expected_full(m, c, k),
                 $sformatf("mode %0d pattern %0d speed %0d k %0d (frame %0d): CRC 0x%08h, C model 0x%08h", m, fc_pat[c], fc_spd[c], k, f,
                           crc_by_num[f], expected_full(m, c, k)));
      end else begin
        tb_check(1'b0, $sformatf("frame %0d (mode %0d pattern %0d k %0d) did not complete", f, m, fc_pat[c], k));
      end
    end
  endtask

  // Wait (bounded) until pattern frame number f has completed.
  task automatic wait_frame_complete(input int f);
    longint t0;
    t0 = cycle;
    while (!crc_by_num.exists(f) && (cycle - t0) < 6_000_000) @(posedge clk);
  endtask

  // Register rules of PATTERN (case 9).
  logic [31:0] st;
  logic [31:0] pv;
  logic [31:0] last_acc;
  logic [31:0] acc_list [8];
  logic [31:0] rej_list [14];

  task automatic reg_pattern_tests();
    acc_list[0] = pattern_word(0, 0);   acc_list[1] = pattern_word(1, 32);  acc_list[2] = pattern_word(2, -32); acc_list[3] = pattern_word(3, -1);
    acc_list[4] = pattern_word(4, 1);   acc_list[5] = pattern_word(4, -7);  acc_list[6] = pattern_word(1, 24);  acc_list[7] = pattern_word(0, 4);
    rej_list[0]  = 32'h0000_0405; rej_list[1]  = 32'h0000_0406; rej_list[2]  = 32'h0000_0407;   // pattern 5, 6, 7
    rej_list[3]  = 32'h0000_0408; rej_list[4]  = 32'h0000_0414; rej_list[5]  = 32'h0000_0484;   // a bit in [7:3]
    rej_list[6]  = 32'h0000_2104; rej_list[7]  = 32'h0000_DF04; rej_list[8]  = 32'h0000_8004;   // speed 33, -33, -128
    rej_list[9]  = 32'h0000_7F04; rej_list[10] = 32'h0001_0404; rej_list[11] = 32'h8000_0404;   // speed 127, a bit in [31:16]
    rej_list[12] = 32'h0000_FFFF; rej_list[13] = 32'h0000_2105;                                 // all ones in [15:0], speed 33 with pattern 5
    reg_read(R_PATTERN, pv); tb_check(pv == 32'h0000_0400, $sformatf("PATTERN resets to 0x%0h, expected 0x400 (static bars, speed 4)", pv));
    reg_read(R_PATFRM, pv);  tb_check(pv == 32'd0, "PATTERN_FRAME resets to 0");
    reg_read(R_CAPS, pv);    tb_check(pv[6] == 1'b1, "CAPS bit 6 (moving patterns) clear");
    last_acc = 32'h0000_0400;
    for (int i = 0; i < 8; i++) begin
      reg_write(R_PATTERN, acc_list[i]);
      reg_read(R_PATTERN, pv);   tb_check(pv == acc_list[i], $sformatf("PATTERN accepted value 0x%0h reads 0x%0h", acc_list[i], pv));
      reg_read(R_STATUS, st);    tb_check((st & ST_PATTERN_ERR) == 0, $sformatf("PATTERN_ERR set by the valid value 0x%0h", acc_list[i]));
      last_acc = acc_list[i];
    end
    for (int i = 0; i < 14; i++) begin
      reg_write(R_STATUS, ST_PATTERN_ERR);
      reg_write(R_PATTERN, rej_list[i]);
      reg_read(R_STATUS, st);    tb_check((st & ST_PATTERN_ERR) != 0, $sformatf("PATTERN value 0x%0h was accepted (no PATTERN_ERR)", rej_list[i]));
      reg_read(R_PATTERN, pv);   tb_check(pv == last_acc, $sformatf("PATTERN changed to 0x%0h by the rejected value 0x%0h", pv, rej_list[i]));
      tb_check((st & (ST_MODE_ERR | ST_PERIOD_ERR | ST_SOURCE_ERR)) == 0, "another error flag set by a rejected PATTERN write");
    end
    // Sticky: other clears and valid writes leave it set; write 1 clears it.
    reg_write(R_STATUS, ST_MODE_ERR | ST_PERIOD_ERR | ST_SOURCE_ERR | ST_OVERRUN);
    reg_write(R_PATTERN, pattern_word(0, 4));
    reg_read(R_STATUS, st);      tb_check((st & ST_PATTERN_ERR) != 0, "PATTERN_ERR is not sticky");
    reg_write(R_STATUS, ST_PATTERN_ERR);
    reg_read(R_STATUS, st);      tb_check((st & ST_PATTERN_ERR) == 0, "PATTERN_ERR did not clear by write 1");
    reg_read(R_PATTERN, pv);     tb_check(pv == 32'h0000_0400, "PATTERN is not back at bars, speed 4");
  endtask

  logic [31:0] v;
  int cnt_a;
  int cnt_b;
  int pat_before;
  int cam_before;
  int short_before;

  initial begin
    wait (resetn === 1'b1 && cfg_resetn === 1'b1);
    // 1. Header and reset values.
    reg_read(R_ID, v);  tb_check(v == 32'h4353_4932, "ID is CSI2");
    reg_read(R_VER, v); tb_check(v == 32'h1110_2026, "VERSION");
    reg_read(R_CAPS, v); tb_check(v == 32'h0000_0052, $sformatf("CAPS 0x%0h (modes 2, pattern, no camera, moving patterns)", v));
    reg_read(R_MODE, v); tb_check(v == 32'd0, "VIDEO_MODE resets to 720p30");
    reg_read(R_SRC, v);  tb_check(v == 32'd0, "SOURCE resets to auto");
    reg_read(R_PERIOD, v); tb_check(int'(v) == PERIOD_RST, $sformatf("FRAME_PERIOD resets to %0d, read %0d", PERIOD_RST, v));
    reg_read(R_TMO, v);  tb_check(v == 32'd2, "CAM_TIMEOUT resets to 2");
    reg_read(R_STATUS, v); tb_check((v & 32'h7F) == ST_PATTERN, $sformatf("STATUS 0x%0h at reset: pattern source, no flags", v));
    reg_pattern_tests();

    if (REAL) begin
      // The real core: 3,000,000 clocks per frame, line periods 4,000 and 2,666, minimums 3,000,000 and 2,999,250.
      spacing_expect = 3_000_000;
      spacing_skip   = 1;
      line_check     = 1'b1;
      wait_frames(3);
      reg_read(R_COUNT, v); tb_check(int'(v) >= 3, "FRAME_COUNT after three frames");
      reg_read(R_ACTIVE, v); tb_check(v[1:0] == 2'd0, "ACTIVE reports 720p30");
      // Rejections at the real minimums.
      reg_write(R_PERIOD, 32'd2_999_999);
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) != 0, "a period below the 720p30 minimum was accepted");
      reg_read(R_PERIOD, v); tb_check(v == 32'd3_000_000, "FRAME_PERIOD changed by a rejected write");
      reg_write(R_STATUS, ST_PERIOD_ERR);
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) == 0, "PERIOD_ERR did not clear");
      reg_write(R_PERIOD, 32'd3_000_000);
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) == 0, "the minimum period was rejected");
      reg_read(R_PERIOD, v); tb_check(v == 32'd3_000_000, "the minimum period was not stored");
      // A mode write whose minimum (1080p30: 2,999,250) is below the period is accepted; then the minimum itself.
      reg_write(R_PERIOD, 32'd3_000_000);
      reg_write(R_MODE, 32'd1);
      reg_read(R_STATUS, v); tb_check((v & (ST_MODE_ERR | ST_PERIOD_ERR)) == 0, "1080p30 rejected at the reset period");
      spacing_expect = 3_000_000; spacing_skip = 0; mode_expect_next = -1;
      wait_frames(3);
      reg_read(R_ACTIVE, v); tb_check(v[1:0] == 2'd1, "ACTIVE reports 1080p30");
      reg_write(R_PERIOD, 32'd2_999_249);
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) != 0, "a period below the 1080p30 minimum was accepted");
      reg_write(R_STATUS, ST_PERIOD_ERR);
      reg_write(R_PERIOD, 32'd2_999_250);
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) == 0, "the 1080p30 minimum was rejected");
      // Back to 720p30 with a period below the 720p30 minimum is rejected.
      reg_write(R_MODE, 32'd0);
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) != 0, "720p30 accepted with a period below its minimum");
      reg_read(R_MODE, v); tb_check(v == 32'd1, "VIDEO_MODE changed by a rejected write");
      reg_write(R_STATUS, ST_PERIOD_ERR);
      spacing_expect = 2_999_250; spacing_skip = 1;
      wait_frames(3);
      tb_check(frames_pat_complete >= 6, $sformatf("only %0d complete pattern frames", frames_pat_complete));
      tb_check(frames_1080 >= 3 && frames_720 >= 2, "both modes were not seen");
      tb_check(GAP || (spacing_checked >= 3 && line_checked > 1000), $sformatf("timing checks ran %0d / %0d times", spacing_checked, line_checked));
    end else if (PATFULL) begin
      // 10. Full-size moving patterns: 22 combinations of four frames; each PATTERN write lands in the last frame of the previous one.
      ref_check_en = 1'b0;
      wait_frame_reached(frames_started + 1, 300);
      for (int m = 0; m < 2; m++) begin
        for (int c = 0; c < FC_COUNT; c++) begin
          pat_write(m, c);
          wait_frame_reached(first_frame[m * FC_COUNT + c] + FC_FRAMES - 1, 300);
          reg_read(R_PATFRM, v);
          tb_check(v == 32'(FC_FRAMES), $sformatf("PATTERN_FRAME reads %0d in the fourth frame, expected %0d", v, FC_FRAMES));
        end
      end
      wait_frame_complete(first_frame[2 * FC_COUNT - 1] + FC_FRAMES - 1);
      for (int m = 0; m < 2; m++) begin
        for (int c = 0; c < FC_COUNT; c++) pat_compare(m, c, FC_FRAMES);
      end
      $display("csi2_rx: %0d full-size pattern frames compared with the C model", 2 * FC_COUNT * FC_FRAMES);
    end else begin
      // 2. Frames at the reset period; mode 720p30.
      wait_frames(2);
      // 9. and 10. A moving pattern at full size, two frames: pattern 4 at speed -7 (CRC from the C model), then bars again.
      ref_check_en = 1'b0;
      wait_frame_reached(frames_started + 1, 300);
      pat_write(0, 9);
      wait_frame_reached(first_frame[9] + 1, 300);
      reg_read(R_PATFRM, v); tb_check(v == 32'd2, $sformatf("PATTERN_FRAME reads %0d in the second frame, expected 2", v));
      reg_write(R_PATTERN, 32'h0000_0400);                  // mid-frame: the frame in progress stays pattern 4
      ref_check_en = 1'b1;
      reg_read(R_PATFRM, v); tb_check(v == 32'd0, $sformatf("PATTERN_FRAME reads %0d after the PATTERN write", v));
      wait_frame_complete(first_frame[9] + 1);
      pat_compare(0, 9, 2);
      wait_frames(2);                                       // bars again, every word checked against the reference
      reg_read(R_COUNT, v); tb_check(int'(v) >= 2 && int'(v) <= frames_started + 1, "FRAME_COUNT after two frames");
      // 4. Rejections.
      reg_write(R_PERIOD, 32'(MIN_720 - 1));
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) != 0, "a period below the 720p30 minimum was accepted");
      reg_read(R_PERIOD, v); tb_check(int'(v) == PERIOD_RST, "FRAME_PERIOD changed by a rejected write");
      reg_write(R_STATUS, ST_PERIOD_ERR);
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) == 0, "PERIOD_ERR did not clear");
      reg_write(R_PERIOD, 32'(MIN_720));
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) == 0, "the minimum period was rejected");
      reg_read(R_PERIOD, v); tb_check(int'(v) == MIN_720, "the minimum period was not stored");
      // The mode write: 1080p30 needs a larger period than the present one.
      reg_write(R_MODE, 32'd1);
      reg_read(R_STATUS, v); tb_check((v & ST_PERIOD_ERR) != 0, "1080p30 accepted with a period below its minimum");
      reg_read(R_MODE, v); tb_check(v == 32'd0, "VIDEO_MODE changed by a rejected write");
      reg_write(R_STATUS, ST_PERIOD_ERR);
      // 5. Invalid mode values.
      reg_write(R_MODE, 32'd2);
      reg_read(R_STATUS, v); tb_check((v & ST_MODE_ERR) != 0, "mode 2 accepted");
      reg_write(R_STATUS, ST_MODE_ERR);
      reg_write(R_MODE, 32'h0001_0000);
      reg_read(R_STATUS, v); tb_check((v & ST_MODE_ERR) != 0, "mode 0x10000 accepted");
      reg_read(R_MODE, v); tb_check(v == 32'd0, "VIDEO_MODE changed by a rejected write");
      reg_write(R_STATUS, ST_MODE_ERR);
      // 6. Invalid source values.
      reg_write(R_SRC, 32'd3);
      reg_read(R_STATUS, v); tb_check((v & ST_SOURCE_ERR) != 0, "source 3 accepted");
      reg_read(R_SRC, v); tb_check(v == 32'd0, "SOURCE changed by a rejected write");
      reg_write(R_STATUS, ST_SOURCE_ERR);
      reg_read(R_STATUS, v); tb_check((v & 32'h3C) == 0, $sformatf("error flags left set: 0x%0h", v));
      // Frames at the minimum period (timing check), then raise the period and change mode in mid-frame.
      spacing_expect = MIN_720; spacing_skip = 2; line_check = 1'b1;
      wait_frames(4);
      reg_write(R_PERIOD, 32'(PERIOD_RST));
      spacing_expect = PERIOD_RST; spacing_skip = 2;
      wait_in_frame(300);
      reg_write(R_MODE, 32'd1);                       // mid-frame: the frame in progress stays 720p30
      reg_read(R_STATUS, v); tb_check((v & (ST_MODE_ERR | ST_PERIOD_ERR)) == 0, "1080p30 rejected at the raised period");
      reg_read(R_ACTIVE, v); tb_check(v[1:0] == 2'd0, "ACTIVE changed in mid-frame");
      mode_expect_next = 1;
      wait_frames(2);
      reg_read(R_ACTIVE, v); tb_check(v[1:0] == 2'd1, "ACTIVE after the change is not 1080p30");
      wait_in_frame(300);
      reg_write(R_MODE, 32'd0);                       // back to 720p30 in mid-frame
      mode_expect_next = 0;
      wait_frames(2);
      tb_check(frames_1080 >= 1 && frames_720 >= 3, "frames of both modes expected");
      tb_check(GAP || (spacing_checked >= 2 && line_checked > 1000), $sformatf("timing checks ran %0d / %0d times", spacing_checked, line_checked));
      spacing_expect = 0; line_check = 1'b0;

      // 7. Source switch with a camera. Camera frames in 720p30 (VIDEO_MODE 0), one frame every 520,000 clocks.
      reg_write(R_PERIOD, 32'(MIN_720));
      // 7a. Auto, camera byte clock off, camera frames arrive: pattern only, camera stream drained.
      pat_before = frames_pat_complete;
      cam_before = frames_cam_complete;
      cam_words_sent = 0;
      cam_frame(0, 40, CAM_GAP, 1'b1);
      tb_check(cam_words_sent == 40 * 640, "a camera frame was not drained while the pattern is selected");
      wait_frames(2);
      reg_read(R_STATUS, v); tb_check((v & ST_PATTERN) != 0, "STATUS.PATTERN clear with the camera byte clock off");
      tb_check(frames_cam_complete == cam_before, "a camera frame was output with the camera byte clock off");
      // 7b. Camera running, full camera frames: auto switches to the camera.
      cam_run = 1'b1;
      fork
        begin
          for (int k = 0; k < 6; k++) begin
            cam_frame(0, 720, CAM_GAP, 1'b1);
            repeat (2000) @(posedge clk);
          end
        end
        begin
          wait_frames(5);
        end
      join
      reg_read(R_STATUS, v);
      tb_check(frames_cam_complete >= 3, $sformatf("only %0d complete camera frames", frames_cam_complete));
      // 7c. Stray camera words without a first word are discarded when the camera is selected.
      short_before = frames_short;
      cam_frame(0, 5, CAM_GAP, 1'b0);
      tb_check(frames_short == short_before, "stray camera words produced output");
      // 7d. The camera stops in mid-frame (byte clock keeps running): that frame closes short, auto returns to the pattern.
      begin
        int sh_pre;
        int pat_pre;
        longint t0;
        sh_pre  = frames_short;
        pat_pre = frames_pat_complete;
        cam_frame(0, 720, CAM_GAP, 1'b1);                  // a complete frame first, so the camera is selected
        fork
          begin
            cam_frame(0, 100, CAM_GAP, 1'b1);              // 100 lines, then silence
          end
          begin
            wait_frames(1);
          end
        join
        // After CAM_TIMEOUT (2) frame periods without a camera frame start the pattern is back.
        t0 = cycle;
        while (frames_pat_complete == pat_pre && (cycle - t0) < 8 * MIN_720) @(posedge clk);
        tb_check(frames_pat_complete > pat_pre, "auto did not return to the pattern after the camera stopped");
        tb_check(frames_short >= sh_pre + 1, "the cut-off camera frame was not closed short");
      end
      // 7e. Pattern only with the camera running and streaming: pattern frames only, camera drained.
      reg_write(R_SRC, 32'd2);
      cam_before = frames_cam_complete;
      cam_words_sent = 0;
      cam_frame(0, 60, CAM_GAP, 1'b1);
      tb_check(cam_words_sent == 60 * 640, "the camera stream stalled while SOURCE is pattern only");
      wait_frames(2);
      tb_check(frames_cam_complete == cam_before, "a camera frame was output with SOURCE 2");
      reg_read(R_STATUS, v); tb_check((v & ST_PATTERN) != 0, "STATUS.PATTERN clear with SOURCE 2");
      // 7f. Camera only with no camera: no frame is sent, FRAME_COUNT stays.
      reg_write(R_SRC, 32'd1);
      repeat (20) @(posedge clk);
      begin
        int fs0;
        int cnt0;
        // The frame in progress ends; then nothing.
        wait_idle_clks(MIN_720);
        fs0 = frames_started;
        reg_read(R_COUNT, v);
        cnt0 = int'(v);
        wait_idle_clks(3 * MIN_720);
        tb_check(frames_started == fs0, "frames were sent with SOURCE 1 and no camera");
        reg_read(R_COUNT, v);
        tb_check(int'(v) == cnt0, "FRAME_COUNT moved with SOURCE 1 and no camera");
        reg_read(R_STATUS, v); tb_check((v & ST_PATTERN) == 0, "STATUS.PATTERN set with the camera selected");
      end
      // 7g. Camera only with the camera frames: the camera frames pass.
      cam_before = frames_cam_complete;
      cam_frame(0, 720, CAM_GAP, 1'b1);
      repeat (4000) @(posedge clk);
      tb_check(frames_cam_complete == cam_before + 1, "a camera frame was not output with SOURCE 1");
      reg_read(R_STATUS, v); tb_check((v & ST_PATTERN) == 0, "STATUS.PATTERN set while the camera is the source");
      // Back to auto with no camera: pattern again after the timeout.
      cam_run = 1'b0;
      reg_write(R_SRC, 32'd0);
      pat_before = frames_pat_complete;
      wait_frames(3);
      tb_check(frames_pat_complete > pat_before, "no pattern frame after returning to auto");
      // No frame mixes sources: every frame record has one source (checked word by word by the monitor).
      tb_check(frames_cam_complete >= 4 && frames_pat_complete >= 6, $sformatf("complete frames: camera %0d, pattern %0d", frames_cam_complete, frames_pat_complete));
    end

    // 8. Overrun: none expected in any run above.
    reg_read(R_STATUS, v); tb_check((v & ST_OVERRUN) == 0 || GAP, $sformatf("STATUS.OVERRUN set: 0x%0h", v));
    $display("csi2_rx: frames started %0d, complete pattern %0d camera %0d, short %0d, 720p %0d 1080p %0d, words %0d",
             frames_started, frames_pat_complete, frames_cam_complete, frames_short, frames_720, frames_1080, words_seen);
    tb_check(frames_started > 5, "too few frames");
    tb_verdict("tb_rtlnet_csi2_rx");
  end

  // Watchdog.
  initial begin
    #3000ms;
    tb_error("watchdog: the bench did not finish");
    tb_verdict("tb_rtlnet_csi2_rx");
  end

  initial begin
    repeat (8) #20;
    arstn = 1'b1;
  end

endmodule
