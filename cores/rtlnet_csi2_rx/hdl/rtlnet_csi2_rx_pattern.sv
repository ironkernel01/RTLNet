// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_pattern.sv
// Purpose: test-pattern generator of rtlnet_csi2_rx (rtlnet_csi2_rx.md section 3): one
//   frame of the selected pattern (static or scrolling 75 percent color bars, a moving textured box, a noise band) as a
//   YUV422 word stream, with the line timing a sensor would produce.
// Overview:
//   * start (a one-clock pulse, accepted only while idle) latches the mode, the pattern and the speed and begins a frame.
//     A frame is H active lines (720 or 1080); line n starts n * LINE_PERIOD clocks after the frame start (4,000 clocks at
//     720p30, 2,666 at 1080p30), so the load on DDR3 and its burst pattern match the camera in the same mode. A line is W
//     words (640 or 960), one per clock while m_tready is high; a line that runs past its slot starts the next one as soon as it ends.
//   * Stream: 32-bit word = two pixels in memory byte order {Cr, Y1, Cb, Y0} (Y0 in m_tdata[7:0]); m_tuser marks the first
//     word of the frame, m_tlast the last word of every line. The word is registered (m_tvalid, m_tdata, m_tlast, m_tuser).
//   * Pattern (pattern 0 static bars, 1 scrolling bars, 2 box over the bars, 3 bars with a noise band, 4 scroll + noise
//     band + box), every frame a pure function of (mode, pattern, speed, k); k is the pattern frame counter, 0 for the first
//     frame after restart (a PATTERN write or a VIDEO_MODE change) and one more for each frame after. Exact definitions in
//     documentation section 3 and in the host models (testbench/csi2_bars_model.c, boards/nexys_video/scripts/pattern_model.py).
//   * No multiplier and no memory: the scroll offset, the box position and the noise seed are running registers that a
//     small sequencer (five phases, one per clock, after the frame start) steps by one frame while the frame is sent; the
//     per-word datapath is a three-stage pipeline (flags, colors and ramps, layer mux) behind the position counters, with
//     at most two LUT levels per stage. All stages advance on one enable (the output register is free or m_tready).
//   * busy is high from start until the last word has left the output register and m_tready accepted it.
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-10-2026: moving patterns (pattern, speed, restart ports; registered pipelined output); k restarts also on a VIDEO_MODE
//     change so one set of running registers serves both modes.
//   * 11-09-2026: initial version.
// Clocks: clk (memory-controller user clock, 90 MHz).
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_pattern #(
  parameter int WORDS_720       = 640,    // words per line, 1280 pixels
  parameter int WORDS_1080      = 960,    // words per line, 1920 pixels
  parameter int LINES_720       = 720,
  parameter int LINES_1080      = 1080,
  parameter int LINE_PERIOD_720 = 4000,   // clocks from line start to line start
  parameter int LINE_PERIOD_1080 = 2666,
  parameter int BOX_X0          = 192,    // box phase at k = 0 (0 .. W - 64 and 0 .. H - 64; benches with reduced frames set smaller values)
  parameter int BOX_Y0          = 96
)(
  // Core clock and its reset (synchronous, active low).
  input  logic        clk,
  input  logic        resetn,

  // Frame start request and the mode (0 720p30, 1 1080p30), the pattern (0..4) and the speed (signed, pixels per frame) for
  // the frame it starts. restart: one-clock pulse, k restarts at 0 (the frame that a start in the same clock begins is k = 0).
  input  logic        start,
  input  logic [1:0]  mode,
  input  logic [2:0]  pattern,
  input  logic [7:0]  speed,
  input  logic        restart,
  output logic        busy,
  output logic [31:0] pat_frame,    // frames started since the last restart (the k of the next frame)

  // Video stream, clk domain.
  output logic [31:0] m_tdata,
  output logic        m_tvalid,
  input  logic        m_tready,
  output logic        m_tlast,
  output logic        m_tuser
);

  localparam int BARS          = 8;
  localparam int BAR_IDX_W     = 3;
  localparam int COUNT_W       = 16;
  localparam logic [1:0] MODE_1080P30 = 2'd1;

  localparam logic [2:0] PAT_SCROLL = 3'd1;
  localparam logic [2:0] PAT_BOX    = 3'd2;
  localparam logic [2:0] PAT_NOISE  = 3'd3;
  localparam logic [2:0] PAT_ALL    = 3'd4;

  localparam logic [1:0] S_IDLE = 2'd0;
  localparam logic [1:0] S_PRE  = 2'd1;    // per-line flags settle
  localparam logic [1:0] S_LINE = 2'd2;    // words of a line
  localparam logic [1:0] S_GAP  = 2'd3;    // wait for the next line start

  // Geometry per mode (pixels, lines).
  localparam int BW_720    = WORDS_720 * 2 / BARS;        // 160 pixels per bar
  localparam int BW_1080   = WORDS_1080 * 2 / BARS;       // 240
  localparam int BOX       = 64;
  localparam int RX_720    = WORDS_720 * 2 - BOX;         // largest box x
  localparam int RX_1080   = WORDS_1080 * 2 - BOX;
  localparam int RY_720    = LINES_720 - BOX;
  localparam int RY_1080   = LINES_1080 - BOX;
  localparam int BAND_ROWS = 64;
  localparam int BAND_720  = ((LINES_720 / 2 - 32) / 16) * 16;     // 320
  localparam int BAND_1080 = ((LINES_1080 / 2 - 32) / 16) * 16;    // 496

  localparam logic [11:0] BOX_X0_V = 12'(BOX_X0);
  localparam logic [10:0] BOX_Y0_V = 11'(BOX_Y0);
  localparam logic [7:0]  BOX_CB = 8'd90;
  localparam logic [7:0]  BOX_CR = 8'd190;
  localparam logic [31:0] SEED_BASE = 32'hACE1_0000;
  localparam logic [31:0] SEED_STEP = 32'h9E37_79B9;

  // Bar colors {Cr, Cb, Y}, 8-bit limited range BT.709.
  function automatic logic [23:0] bar_ycc(input logic [BAR_IDX_W-1:0] idx);
    case (idx)
      3'd0:    return {8'd128, 8'd128, 8'd180};   // white 75 %
      3'd1:    return {8'd136, 8'd44,  8'd168};   // yellow
      3'd2:    return {8'd44,  8'd147, 8'd145};   // cyan
      3'd3:    return {8'd52,  8'd63,  8'd133};   // green
      3'd4:    return {8'd204, 8'd193, 8'd63};    // magenta
      3'd5:    return {8'd212, 8'd109, 8'd51};    // red
      3'd6:    return {8'd120, 8'd212, 8'd28};    // blue
      default: return {8'd128, 8'd128, 8'd16};    // black
    endcase
  endfunction

  // Luma of a bar.
  function automatic logic [7:0] bar_luma(input logic [BAR_IDX_W-1:0] idx);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [23:0] c;
    /* verilator lint_on UNUSEDSIGNAL */
    c = bar_ycc(idx);
    return c[7:0];
  endfunction

  // 32 steps of the maximal LFSR x^32 + x^22 + x^2 + x + 1 (Fibonacci, shift left): one noise word per output word.
  function automatic logic [31:0] lfsr_step32(input logic [31:0] s_in);
    logic [31:0] s;
    s = s_in;
    for (int i = 0; i < 32; i++) s = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
    return s;
  endfunction

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  // Frame configuration latched at start.
  logic                     gen_1080;
  logic                     bx_en;           // box
  logic                     bd_en;           // noise band
  logic [7:0]               w_v;             // speed
  logic [11:0]              w_bx;            // box x, y of this frame
  logic [10:0]              w_by;

  // Running registers: the state of frame k_next (the next frame to start).
  logic [BAR_IDX_W-1:0]     run_b;           // scroll: bar and pixel in the bar of the line's first pixel
  logic [7:0]               run_r;
  logic [11:0]              run_tx;          // box phase in [0, 2 * RX)
  logic [10:0]              run_ty;          // box phase in [0, 2 * RY)
  logic [31:0]              run_acc;         // k * SEED_STEP
  logic [11:0]              n_bx;            // box position of frame k_next
  logic [10:0]              n_by;
  logic [31:0]              k_next;
  logic [4:0]               ph;              // step phase, one-hot
  logic signed [12:0]       sum_r, sum_x, sum_y;
  logic                     r_neg, r_ge, x_neg, x_ge, y_neg, y_ge, x_le, y_le;

  // Position counters (stage 0).
  logic [1:0]               state;
  logic [10:0]              line;
  logic [9:0]               word;
  logic [BAR_IDX_W-1:0]     b;
  logic [7:0]               r;
  logic [11:0]              cx0;             // box column of pixel 0 of the word (signed)
  logic                     first;
  logic [10:0]              dline;           // line - w_by
  logic                     band_row;
  logic [COUNT_W-1:0]       line_timer;
  logic [9:0]               last_word;
  logic [10:0]              last_line;
  logic [COUNT_W-1:0]       line_period;
  logic                     r_wrap;
  logic                     adv;

  // Stage 1 (flags).
  logic                     s1_v, s1_last, s1_user, s1_edge, s1_hi0, s1_him, s1_ra, s1_band, s1_ry3;
  logic [BAR_IDX_W-1:0]     s1_b;
  logic [5:0]               s1_cxa, s1_cxb;
  logic [8:0]               s1_ry5;          // 5 * local row
  // Stage 2 (colors and ramps).
  logic                     s2_v, s2_last, s2_user, s2_in0, s2_in1, s2_band;
  logic [7:0]               s2_y0b, s2_y1b, s2_cbb, s2_crb, s2_t0, s2_t1;
  // Noise word.
  logic [31:0]              lfsr;

  // Constants selected by the mode of the frame.
  logic [7:0]               bw_c;
  logic [11:0]              mx_c, rx_c;
  logic [10:0]              my_c, ry_c;
  logic [10:0]              band0;
  logic [23:0]              ycc0;
  logic [7:0]               ycc1_y;
  logic [BAR_IDX_W-1:0]     s1_b1;
  /* verilator lint_off UNUSEDSIGNAL */   // the low four bits only carry into the ramp
  logic [8:0]               sum0, sum1;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0]              noise;
  logic [31:0]              word_n;
  logic [7:0]               vy;

  assign last_word   = gen_1080 ? 10'(WORDS_1080 - 1) : 10'(WORDS_720 - 1);
  assign last_line   = gen_1080 ? 11'(LINES_1080 - 1) : 11'(LINES_720 - 1);
  assign line_period = gen_1080 ? COUNT_W'(LINE_PERIOD_1080 - 1) : COUNT_W'(LINE_PERIOD_720 - 1);
  assign bw_c        = gen_1080 ? 8'(BW_1080) : 8'(BW_720);
  assign rx_c        = gen_1080 ? 12'(RX_1080) : 12'(RX_720);
  assign mx_c        = gen_1080 ? 12'(2 * RX_1080) : 12'(2 * RX_720);
  assign ry_c        = gen_1080 ? 11'(RY_1080) : 11'(RY_720);
  assign my_c        = gen_1080 ? 11'(2 * RY_1080) : 11'(2 * RY_720);
  assign band0       = gen_1080 ? 11'(BAND_1080) : 11'(BAND_720);
  // The pixel pair crosses a bar edge (pixel 1 in the next bar) when r = bw - 1; r wraps when r + 2 >= bw.
  assign r_wrap      = gen_1080 ? (r[7:1] == 7'(BW_1080 / 2 - 1)) : (r[7:1] == 7'(BW_720 / 2 - 1));
  assign vy          = {w_v[7], w_v[7:1]};

  assign adv         = !m_tvalid || m_tready;
  assign busy        = (state != S_IDLE) || s1_v || s2_v || m_tvalid;
  assign pat_frame   = k_next;

  // ---------------------------------------------------------------------------
  // Stage 0: position counters and the frame sequencer
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      state      <= S_IDLE;
      gen_1080   <= 1'b0;
      bx_en      <= 1'b0;
      bd_en      <= 1'b0;
      w_v        <= '0;
      w_bx       <= '0;
      w_by       <= '0;
      line       <= '0;
      word       <= '0;
      b          <= '0;
      r          <= '0;
      cx0        <= '0;
      first      <= 1'b0;
      lfsr       <= 32'h1;
      line_timer <= '0;
      dline      <= '0;
      band_row   <= 1'b0;
    end else begin
      dline    <= line - w_by;
      band_row <= (line >= band0) && (line < band0 + 11'(BAND_ROWS));
      // Line timer: counts from the line start, holds at the maximum.
      if (state != S_IDLE && line_timer != '1) line_timer <= line_timer + COUNT_W'(1);
      case (state)
        S_IDLE: begin
          if (start) begin
            gen_1080 <= (mode == MODE_1080P30);
            bx_en    <= (pattern == PAT_BOX) || (pattern == PAT_ALL);
            bd_en    <= (pattern == PAT_NOISE) || (pattern == PAT_ALL);
            w_v      <= speed;
            // A restart in the same clock makes this frame k = 0.
            w_bx     <= restart ? BOX_X0_V : n_bx;
            w_by     <= restart ? BOX_Y0_V : n_by;
            cx0      <= 12'd0 - (restart ? BOX_X0_V : n_bx);
            b        <= ((pattern == PAT_SCROLL) || (pattern == PAT_ALL)) && !restart ? run_b : '0;
            r        <= ((pattern == PAT_SCROLL) || (pattern == PAT_ALL)) && !restart ? run_r : '0;
            lfsr     <= ((restart ? 32'd0 : run_acc) ^ SEED_BASE) | 32'h1;
            state    <= S_PRE;
            line     <= '0;
            word     <= '0;
            first    <= 1'b1;
            line_timer <= '0;
          end
        end
        S_PRE: begin
          line_timer <= '0;
          state      <= S_LINE;
        end
        S_LINE: begin
          if (adv) begin
            first <= 1'b0;
            if (word == last_word) begin
              word <= '0;
              cx0  <= 12'd0 - w_bx;
              if (line == last_line) begin
                state <= S_IDLE;
              end else begin
                line  <= line + 11'd1;
                state <= S_GAP;
              end
            end else begin
              word <= word + 10'd1;
              cx0  <= cx0 + 12'd2;
            end
            // Bar tracking: two pixels per word; the position returns to its line start after W / 2 words.
            if (r_wrap) begin
              r <= {7'd0, r[0]};
              b <= b + BAR_IDX_W'(1);
            end else begin
              r <= r + 8'd2;
            end
          end
        end
        S_GAP: begin
          // The next line starts LINE_PERIOD clocks after the previous one began (at once if the line overran).
          if (line_timer >= line_period) begin
            line_timer <= '0;
            state      <= S_LINE;
          end
        end
        default: state <= S_IDLE;
      endcase
      // Noise word: stepped for every output word of the band.
      if (adv && s2_v && s2_band) lfsr <= lfsr_step32(lfsr);
    end
  end

  // ---------------------------------------------------------------------------
  // Frame stepping: running registers of frame k_next, five phases after a start (one clock each)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn || restart) begin
      run_b   <= '0;
      run_r   <= '0;
      run_tx  <= BOX_X0_V;
      run_ty  <= BOX_Y0_V;
      run_acc <= '0;
      n_bx    <= BOX_X0_V;
      n_by    <= BOX_Y0_V;
      ph      <= '0;
      k_next  <= (start && state == S_IDLE && resetn) ? 32'd1 : 32'd0;
      if (start && state == S_IDLE && resetn) ph <= 5'b00001;   // the started frame is k = 0: step it to k = 1
    end else begin
      ph <= {ph[3:0], 1'b0};
      if (start && state == S_IDLE) begin
        ph     <= 5'b00001;
        k_next <= k_next + 32'd1;
      end
      // Phase 1: sums.
      if (ph[0]) begin
        sum_r   <= {5'd0, run_r} - {{5{w_v[7]}}, w_v};
        sum_x   <= {1'b0, run_tx} + {{5{w_v[7]}}, w_v};
        sum_y   <= {2'd0, run_ty} + {{5{vy[7]}}, vy};
        run_acc <= run_acc + SEED_STEP;
      end
      // Phase 2: wrap flags.
      if (ph[1]) begin
        r_neg <= sum_r[12];
        r_ge  <= !sum_r[12] && (sum_r[8:0] >= {1'b0, bw_c});
        x_neg <= sum_x[12];
        x_ge  <= !sum_x[12] && (sum_x[11:0] >= mx_c);
        y_neg <= sum_y[12];
        y_ge  <= !sum_y[12] && (sum_y[10:0] >= my_c);
      end
      // Phase 3: apply the wrap.
      if (ph[2]) begin
        if (r_neg) begin
          run_r <= 8'(sum_r + 13'(bw_c));
          run_b <= run_b - BAR_IDX_W'(1);
        end else if (r_ge) begin
          run_r <= 8'(sum_r - 13'(bw_c));
          run_b <= run_b + BAR_IDX_W'(1);
        end else begin
          run_r <= sum_r[7:0];
        end
        run_tx <= x_neg ? 12'(sum_x + 13'(mx_c)) : (x_ge ? 12'(sum_x - 13'(mx_c)) : sum_x[11:0]);
        run_ty <= y_neg ? 11'(sum_y + 13'(my_c)) : (y_ge ? 11'(sum_y - 13'(my_c)) : sum_y[10:0]);
      end
      // Phase 4: fold flags of the triangle waves.
      if (ph[3]) begin
        x_le <= (run_tx <= rx_c);
        y_le <= (run_ty <= ry_c);
      end
      // Phase 5: box position of the next frame.
      if (ph[4]) begin
        n_bx <= x_le ? run_tx : (mx_c - run_tx);
        n_by <= y_le ? run_ty : (my_c - run_ty);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 1: flags from the position counters (two LUT levels at most)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      s1_v <= 1'b0;
    end else if (adv) begin
      s1_v <= (state == S_LINE);
    end
    if (adv) begin
      s1_last <= (word == last_word);
      s1_user <= first;
      s1_b    <= b;
      s1_edge <= r_wrap && r[0];
      s1_cxa  <= cx0[5:0];
      s1_cxb  <= cx0[5:0] + 6'd1;
      s1_hi0  <= (cx0[11:6] == 6'd0);
      s1_him  <= (cx0[11:6] == 6'h3F);
      s1_ry5  <= {1'b0, dline[5:0], 2'b00} + {3'b000, dline[5:0]};
      s1_ry3  <= dline[3];
      s1_ra   <= bx_en && (dline[10:6] == 5'd0);
      s1_band <= bd_en && band_row;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 2: bar colors, box texture (8x8 checkerboard of two levels plus the ramp (cx + 5 cy) >> 4)
  // ---------------------------------------------------------------------------
  assign s1_b1 = s1_b + BAR_IDX_W'(s1_edge);
  assign ycc0  = bar_ycc(s1_b);
  assign ycc1_y    = bar_luma(s1_b1);
  assign sum0  = {3'b000, s1_cxa} + s1_ry5;
  assign sum1  = {3'b000, s1_cxb} + s1_ry5;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      s2_v <= 1'b0;
    end else if (adv) begin
      s2_v <= s1_v;
    end
    if (adv) begin
      s2_last <= s1_last;
      s2_user <= s1_user;
      s2_y0b  <= ycc0[7:0];
      s2_cbb  <= ycc0[15:8];
      s2_crb  <= ycc0[23:16];
      s2_y1b  <= ycc1_y;
      s2_in0  <= s1_ra && s1_hi0;
      // Pixel 1 is in the box when cx0 is in [0, 62] or -1.
      s2_in1  <= s1_ra && ((s1_hi0 && (s1_cxa != 6'd63)) || (s1_him && (s1_cxa == 6'd63)));
      s2_t0   <= {s1_cxa[3] ^ s1_ry3, 1'b1, 1'b0, sum0[8:4]};
      s2_t1   <= {s1_cxb[3] ^ s1_ry3, 1'b1, 1'b0, sum1[8:4]};
      s2_band <= s1_band;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 3: layer mux into the output register: box over noise band over bars
  // ---------------------------------------------------------------------------
  assign noise = lfsr;
  always_comb begin
    word_n[7:0]   = s2_in0 ? s2_t0 : (s2_band ? noise[7:0]   : s2_y0b);   // Y0
    word_n[15:8]  = s2_in0 ? BOX_CB : (s2_band ? noise[15:8]  : s2_cbb);  // Cb
    word_n[23:16] = s2_in1 ? s2_t1 : (s2_band ? noise[23:16] : s2_y1b);   // Y1
    word_n[31:24] = s2_in0 ? BOX_CR : (s2_band ? noise[31:24] : s2_crb);  // Cr
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      m_tvalid <= 1'b0;
      m_tdata  <= '0;
      m_tlast  <= 1'b0;
      m_tuser  <= 1'b0;
    end else if (adv) begin
      m_tvalid <= s2_v;
      m_tdata  <= word_n;
      m_tlast  <= s2_last;
      m_tuser  <= s2_user;
    end
  end

endmodule
