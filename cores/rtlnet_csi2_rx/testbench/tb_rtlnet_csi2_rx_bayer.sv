// -----------------------------------------------------------------------------
// File: tb_rtlnet_csi2_rx_bayer.sv
// Purpose: self-checking bench for rtlnet_csi2_rx_bayer followed by rtlnet_csi2_rx_yuv: raw Bayer entries in, YUV words out, compared
//   bit for bit with the Python model (csi2_rx_model.py) over a set of cases.
// Cases (TB_SETNUM selects the case set; the table, raw pixels and expected words come from csi2_rx_<set>_cfg/raw/exp.mem):
//   small: all four Bayer phases with black level, gains and gamma; the second mode geometry; a frame whose lines are shorter and a
//     frame with fewer lines than the mode (padded with zero pixels and zero lines); a frame with longer lines and more lines (cut).
//   fault: a line that never arrives (the frame gets a zero line at the end), a line closed by an end-of-line marker after four pixels.
//   wide: lines of 1280 and 1920 pixels.
//   Every set: each case twice, once with random gaps between the entries and a random output ready, once back to back at full speed;
//   the output structure (start of frame on the first word only, end of line after W / 2 words, H lines, nothing after the frame)
//   and ev_size_err (one pulse for every frame whose size differs from the mode, none otherwise) are checked; meas_lines and
//   meas_pixels after each case; entries that do not belong to a frame are dropped; a frame start inside a frame closes the frame
//   early (small set: three lines of one frame, then a full frame; both frames are exact against the model).
// Plusargs: INJECT_FAILURE (the verdict fails), MUTATE (one pixel of one entry is flipped on the way in: the compare must fail).
// Defines: TB_SETNUM (0 small, 1 fault, 2 wide; default 0), TB_DIR (folder of the .mem files relative to the simulation work directory).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_SETNUM
  `define TB_SETNUM 0
`endif
`ifndef TB_DIR
  `define TB_DIR "../../cores/rtlnet_csi2_rx/testbench"
`endif

module tb_rtlnet_csi2_rx_bayer;

  import rtlnet_tb_pkg::*;
  import rtlnet_csi2_rx_pkg::*;

  localparam string SETNAME = (`TB_SETNUM == 0) ? "small" : ((`TB_SETNUM == 1) ? "fault" : "wide");

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #5.5 clk = ~clk;

  // Case memories.
  logic [31:0] cfgm [0:1023];
  logic [9:0]  rawm [0:16383];
  logic [31:0] expm [0:8191];

  // DUT: bayer into yuv.
  logic              e_valid = 1'b0;
  logic [ENT_W-1:0]  e_data  = '0;
  logic              e_ready;
  logic [11:0]       cfg_w = 12'd16, cfg_h = 12'd8;
  logic [9:0]        cfg_black = '0;
  logic [11:0]       cfg_gr = 12'h100, cfg_gg = 12'h100, cfg_gb = 12'h100;
  logic [1:0]        cfg_phase = '0;
  logic              cfg_gamma = 1'b0;
  logic [23:0]       rgb_data;
  logic              rgb_valid, rgb_ready, rgb_sof, rgb_eol;
  logic              ev_size_err;
  logic [15:0]       meas_lines, meas_pixels;
  logic [31:0]       y_data;
  logic              y_valid, y_ready = 1'b1, y_user, y_last, y_fmt_err;

  rtlnet_csi2_rx_bayer #(.RAM_STYLE("block"), .LINE_KB(8)) dut (
    .clk(clk), .resetn(resetn), .e_valid(e_valid), .e_data(e_data), .e_ready(e_ready),
    .cfg_w(cfg_w), .cfg_h(cfg_h), .cfg_black(cfg_black), .cfg_gain_r(cfg_gr), .cfg_gain_g(cfg_gg), .cfg_gain_b(cfg_gb),
    .cfg_phase(cfg_phase), .cfg_gamma(cfg_gamma),
    .o_data(rgb_data), .o_valid(rgb_valid), .o_ready(rgb_ready), .o_sof(rgb_sof), .o_eol(rgb_eol),
    .ev_size_err(ev_size_err), .meas_lines(meas_lines), .meas_pixels(meas_pixels));

  rtlnet_csi2_rx_yuv u_yuv (
    .clk(clk), .resetn(resetn), .s_axis_tdata(rgb_data), .s_axis_tvalid(rgb_valid), .s_axis_tready(rgb_ready),
    .s_axis_tuser(rgb_sof), .s_axis_tlast(rgb_eol), .m_axis_tdata(y_data), .m_axis_tvalid(y_valid), .m_axis_tready(y_ready),
    .m_axis_tuser(y_user), .m_axis_tlast(y_last), .format_error(y_fmt_err));

  // ---------------------------------------------------------------------------
  // Random numbers and gap control
  // ---------------------------------------------------------------------------
  bit          gaps = 1'b0;
  logic [31:0] lfsr = 32'hACE1_2468;
  function automatic logic [31:0] next_rand(input logic [31:0] v);
    logic [31:0] r;
    r = v;
    r = r ^ (r << 13);
    r = r ^ (r >> 17);
    r = r ^ (r << 5);
    return r;
  endfunction

  always @(posedge clk) begin
    lfsr <= next_rand(lfsr);
    y_ready <= gaps ? (lfsr[7:5] != 3'd0) : 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Output monitor: queue of expected frames, word and structure checks
  // ---------------------------------------------------------------------------
  int  q_off [$];
  int  q_w   [$];
  int  q_h   [$];
  int  frames_out = 0;
  int  cur_off = 0, cur_w = 0, cur_h = 0, cur_idx = 0, cur_line = 0, cur_col = 0;
  bit  in_frame = 1'b0;
  int  word_errs = 0;
  int  words_seen = 0;
  bit  mutate = 1'b0;
  int  size_err_events = 0;

  always @(posedge clk) if (ev_size_err) size_err_events++;

  always @(posedge clk) begin
    if (resetn && y_valid && y_ready) begin
      words_seen++;
      if (y_user) begin
        tb_check(!in_frame, "frame start before the previous frame finished");
        tb_check(q_off.size() > 0, "output frame without an expected frame");
        if (q_off.size() > 0) begin
          cur_off = q_off.pop_front(); cur_w = q_w.pop_front(); cur_h = q_h.pop_front();
        end
        in_frame = 1'b1; cur_idx = 0; cur_line = 0; cur_col = 0;
      end else begin
        tb_check(in_frame, "word outside a frame");
      end
      if (in_frame) begin
        if (y_data !== expm[cur_off + cur_idx]) begin
          word_errs++;
          if (word_errs <= 5)
            $display("WORD MISMATCH frame %0d word %0d (line %0d col %0d): got %08x expected %08x", frames_out, cur_idx, cur_line, cur_col,
                     y_data, expm[cur_off + cur_idx]);
        end
        tb_check(y_user == (cur_idx == 0), "tuser only on the first word");
        tb_check(y_last == (cur_col == cur_w / 2 - 1), "tlast on the last word of every line");
        cur_idx++;
        if (cur_col == cur_w / 2 - 1) begin cur_col = 0; cur_line++; end else cur_col++;
        if (cur_line == cur_h) begin
          in_frame = 1'b0;
          frames_out++;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Entry driver
  // ---------------------------------------------------------------------------
  task automatic push_entry(input logic [ENT_W-1:0] d);
    // Random idle gaps in gap mode; wait for e_ready.
    if (gaps) begin
      repeat (int'(lfsr[3:0]) % 6) @(posedge clk);
    end
    e_data  <= d;
    e_valid <= 1'b1;
    @(posedge clk);
    while (!e_ready) @(posedge clk);
    e_valid <= 1'b0;
  endtask

  function automatic logic [ENT_W-1:0] mk(input logic fe, input logic eol, input logic sof, input logic [2:0] cnt,
                                          input logic [9:0] p0, input logic [9:0] p1, input logic [9:0] p2, input logic [9:0] p3);
    return {fe, eol, sof, cnt, p3, p2, p1, p0};
  endfunction

  // Send the lines of one case: rows of the raw memory at roff, kind 1 = line k missing, kind 2 = line k cut to 4 pixels.
  task automatic send_lines(input int roff, input int iw, input int ih, input int kind, input int kline, input int first_line,
                            input int last_line, input bit sof_first, input bit send_fe);
    bit first;
    first = sof_first;
    for (int y = first_line; y < last_line; y++) begin
      if (!(kind == 1 && y == kline)) begin
        int groups;
        groups = (kind == 2 && y == kline) ? 1 : (iw / 4);
        for (int g = 0; g < groups; g++) begin
          logic [9:0] a, b, c, d;
          a = rawm[roff + y * iw + g * 4 + 0];
          b = rawm[roff + y * iw + g * 4 + 1];
          c = rawm[roff + y * iw + g * 4 + 2];
          d = rawm[roff + y * iw + g * 4 + 3];
          if (mutate && y == 1 && g == 1) a = a ^ 10'h010;
          push_entry(mk(1'b0, (g == iw / 4 - 1), first, 3'd4, a, b, c, d));
          first = 1'b0;
        end
        if (kind == 2 && y == kline) push_entry(mk(1'b0, 1'b1, 1'b0, 3'd0, '0, '0, '0, '0));
      end
    end
    if (send_fe) push_entry(mk(1'b1, 1'b0, 1'b0, 3'd0, '0, '0, '0, '0));
  endtask

  task automatic apply_cfg(input int base);
    cfg_w     <= cfgm[base + 2][11:0];
    cfg_h     <= cfgm[base + 3][11:0];
    cfg_phase <= cfgm[base + 5][1:0];
    cfg_black <= cfgm[base + 6][9:0];
    cfg_gr    <= cfgm[base + 7][11:0];
    cfg_gg    <= cfgm[base + 8][11:0];
    cfg_gb    <= cfgm[base + 9][11:0];
    cfg_gamma <= cfgm[base + 10][0];
    @(posedge clk);
  endtask

  // Wait until n frames are out (timeout in clocks).
  task automatic wait_frames(input int n, input int timeout);
    int t;
    t = 0;
    while (frames_out < n && t < timeout) begin
      @(posedge clk);
      t++;
    end
    tb_check(frames_out >= n, $sformatf("frames out %0d, expected %0d (timeout)", frames_out, n));
  endtask

  int ncases;
  int exp_size_events = 0;

  initial begin
    int total_frames;
    int base, iw, ih, W, H, roff, eoff, kind, kline;
    mutate = $test$plusargs("MUTATE");
    $readmemh({`TB_DIR, "/csi2_rx_", SETNAME, "_cfg.mem"}, cfgm);
    $readmemh({`TB_DIR, "/csi2_rx_", SETNAME, "_raw.mem"}, rawm);
    $readmemh({`TB_DIR, "/csi2_rx_", SETNAME, "_exp.mem"}, expm);
    ncases = int'(cfgm[0]);
    tb_check(ncases > 0, "case table is empty");
    repeat (6) @(posedge clk);
    resetn <= 1'b1;
    repeat (6) @(posedge clk);

    // Entries that belong to no frame are dropped: a line without a start-of-frame flag and a frame end marker.
    push_entry(mk(1'b0, 1'b1, 1'b0, 3'd4, 10'd1, 10'd2, 10'd3, 10'd4));
    push_entry(mk(1'b1, 1'b0, 1'b0, 3'd0, '0, '0, '0, '0));
    repeat (40) @(posedge clk);
    tb_check(words_seen == 0, "entries without a frame start produced output");

    total_frames = 0;
    for (int pass = 0; pass < 2; pass++) begin
      gaps = (pass == 0);
      for (int ci = 0; ci < ncases; ci++) begin
        base = 1 + ci * 16;
        iw = int'(cfgm[base + 0]); ih = int'(cfgm[base + 1]); W = int'(cfgm[base + 2]); H = int'(cfgm[base + 3]);
        roff = int'(cfgm[base + 11]); eoff = int'(cfgm[base + 12]); kind = int'(cfgm[base + 13]); kline = int'(cfgm[base + 14]);
        apply_cfg(base);
        q_off.push_back(eoff); q_w.push_back(W); q_h.push_back(H);
        if (iw != W || ih != H || kind != 0) exp_size_events++;
        send_lines(roff, iw, ih, kind, kline, 0, (kind == 3) ? kline : ih, 1'b1, 1'b1);
        total_frames++;
        wait_frames(total_frames, 2_000_000);
        repeat (30) @(posedge clk);
        tb_check(meas_lines == ((kind == 1) ? ih - 1 : ((kind == 3) ? kline : ih)), $sformatf("case %0d meas_lines %0d", ci, meas_lines));
      end
    end

    // A frame start inside a frame: the case with kind 3 (first k lines, no frame end), directly followed by case 0.
    for (int ci = 0; ci < ncases; ci++) begin
      if (int'(cfgm[1 + ci * 16 + 13]) == 3) begin
        int c0;
        c0 = 0;
        // The frame that follows is the first case that is exact (kind 0, input size equal to the mode).
        for (int k = ncases - 1; k >= 0; k--) begin
          if (int'(cfgm[1 + k * 16 + 13]) == 0 && cfgm[1 + k * 16 + 0] == cfgm[1 + k * 16 + 2] && cfgm[1 + k * 16 + 1] == cfgm[1 + k * 16 + 3]) c0 = k;
        end
        gaps = 1'b0;
        base = 1 + ci * 16;
        iw = int'(cfgm[base + 0]); ih = int'(cfgm[base + 1]); W = int'(cfgm[base + 2]); H = int'(cfgm[base + 3]);
        roff = int'(cfgm[base + 11]); eoff = int'(cfgm[base + 12]); kline = int'(cfgm[base + 14]);
        apply_cfg(base);
        q_off.push_back(eoff); q_w.push_back(W); q_h.push_back(H);
        send_lines(roff, iw, ih, 0, 0, 0, kline, 1'b1, 1'b0);
        exp_size_events++;
        base = 1 + c0 * 16;
        iw = int'(cfgm[base + 0]); ih = int'(cfgm[base + 1]); W = int'(cfgm[base + 2]); H = int'(cfgm[base + 3]);
        roff = int'(cfgm[base + 11]); eoff = int'(cfgm[base + 12]);
        apply_cfg(base);
        q_off.push_back(eoff); q_w.push_back(W); q_h.push_back(H);
        send_lines(roff, iw, ih, 0, 0, 0, ih, 1'b1, 1'b1);
        total_frames += 2;
        wait_frames(total_frames, 2_000_000);
        repeat (50) @(posedge clk);
      end
    end

    tb_check(size_err_events == exp_size_events, $sformatf("ev_size_err pulses %0d, expected %0d", size_err_events, exp_size_events));
    tb_check(word_errs == 0, $sformatf("%0d word mismatches", word_errs));
    tb_check(!y_fmt_err, "yuv format_error set");
    tb_verdict("tb_rtlnet_csi2_rx_bayer");
  end

  initial begin
    #500ms;
    tb_error("bench timeout");
    tb_verdict("tb_rtlnet_csi2_rx_bayer");
  end

endmodule
