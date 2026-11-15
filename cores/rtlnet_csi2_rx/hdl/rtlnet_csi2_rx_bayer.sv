// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_bayer.sv
// Purpose: raw Bayer to RGB of the camera receiver, on the core clock: frame and line conditioning to the exact size of the video
//   mode, black level, white balance gains, bilinear demosaic over a 3 x 3 window, optional gamma, 8-bit RGB out (to rtlnet_csi2_rx_yuv).
// Overview:
//   * Input: the FIFO entries of rtlnet_csi2_rx_cdc (four 10-bit pixels per entry, start-of-frame and end-of-line flags, line-end and
//     frame-end markers). An unpacker turns them into a pixel token stream.
//   * Conditioner (feeder): every frame that starts is output as exactly cfg_w x cfg_h pixels (the mode geometry at the frame start): a
//     line with more pixels is cut at cfg_w, a short line is padded with zero pixels, a missing line (the frame ended early, or a line was lost)
//     is padded with zero lines, input lines beyond cfg_h are discarded. Input that does not belong to a frame (no start-of-frame pixel)
//     is dropped. A frame start before the frame end closes the frame early. ev_size_err pulses once at the end of a frame whose line count or
//     any line width differs from the mode; meas_lines and meas_pixels hold the lines of the last frame and the pixels of the last line as
//     received.
//   * Pipeline (one step per clock, every stage advances together while the output is ready): step (x, y) of the input; x = cfg_w and y =
//     cfg_h are virtual steps that complete the last column and last row, so a frame takes (cfg_w + 1) x (cfg_h + 1) steps. Stage 1
//     black level subtraction (floored at 0); stage 2 and 3 white balance gain of the Bayer site (R, G, B gain, unsigned 4.8 fixed point,
//     1.0 = 0x100): clip10((t * gain + 128) >> 8); the corrected pixels go through the line buffers (two lines in one rtlnet_ram_core word) so
//     that a column of three rows exists at every step; at the top row the row above is the row below, at the bottom row the row below is the
//     row above (mirror, the colour of every site is kept); the window of three columns replaces a missing left or right column the same way;
//     the demosaic output is the pixel at (x - 1, y - 1).
//   * Demosaic (centre pixel c; N, S, W, E the neighbours; D the four diagonals): R site: G = (N + S + W + E + 2) / 4, B = (D sum + 2) / 4.
//     B site: G the same, R = (D sum + 2) / 4. G site on a red row: R = (W + E + 1) / 2, B = (N + S + 1) / 2. G site on a blue row: B = (W + E + 1) / 2,
//     R = (N + S + 1) / 2. cfg_phase (2 bits) is the site of the first pixel of the first line: 0 R (RGGB), 1 G on a red row (GRBG), 2 G on a
//     blue row (GBRG), 3 B (BGGR); bit 0 mirrors the columns, bit 1 the rows of the RGGB tile, so a sensor flip or mirror needs no offset.
//   * Output stage: 10 bits to 8 bits ((v + 2) >> 2, clipped to 255), then with cfg_gamma = 1 a piecewise-linear gamma curve of 16
//     segments (about 1/2.2, breakpoints GAMMA_Y at multiples of 16), then {R, B, G} with the frame start and line end flags.
//   * Green equalisation (cfg_geq = 1): at a G site the green output is (G + (the four diagonal G + 2) / 4 + 1) / 2 instead of G. The diagonals of a G site
//     are the other kind of G (Gr and Gb), so both kinds of G come out as their mean: a sensor whose two greens differ (the OV5640 in its binned modes) otherwise
//     shows a fixed two-pixel luma pattern in flat areas. The cost is a slightly softer green at the G sites.
//   * Highlight clamp (cfg_hl = 1): the sensor clips green, its brightest channel, below full scale, so after the white balance gain a clipped
//     highlight has R and B above G and comes out pink. On the gained, demosaiced 10-bit triple (before the 8-bit scaling) a pixel with G >= cfg_hl_level
//     gets G = max(G, R, B); R and B stay. Level 0 with the clamp on qualifies every pixel (G becomes the maximum of the three everywhere).
//     With cfg_hl = 0 the output is unchanged.
//   * Raw maxima: meas_raw_max_r, _g and _b are the largest black-level-subtracted raw values (before the gain) of the red, green (both) and
//     blue sites of the last completed frame; the running maxima restart at a frame start and are published at the frame end like meas_lines.
//     They show how far the sensor is from clipping per channel.
//   * Configuration (black, gains, phase, gamma, green equalisation, highlight clamp) is taken at the start of each frame.
//   * Storage: the line buffers are one rtlnet_ram_core of LINE_KB kilobytes counted as 4-byte words (LINE_KB = 8: 2048 pixels per line,
//     20 bits per word); cfg_w must not exceed 256 * LINE_KB.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: initial version; green equalisation (cfg_geq, PROC bit 1); highlight clamp (cfg_hl, cfg_hl_level, PROC bit 2) and raw maxima.
// Clocks: clk (all logic, the core clock, one pixel per clock).
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_bayer
  import rtlnet_csi2_rx_pkg::*;
#(
  parameter string RAM_STYLE = "block",     // "block" | "distributed"
  parameter int    LINE_KB   = 8            // line buffer storage in kilobytes of 4-byte words
)(
  // Core clock and its synchronous active-low reset.
  input  logic             clk,
  input  logic             resetn,

  // FIFO entries.
  input  logic             e_valid,
  input  logic [ENT_W-1:0] e_data,
  output logic             e_ready,

  // Frame geometry (at the frame start) and processing configuration (levels in clk).
  input  logic [11:0]      cfg_w,
  input  logic [11:0]      cfg_h,
  input  logic [9:0]       cfg_black,
  input  logic [11:0]      cfg_gain_r,
  input  logic [11:0]      cfg_gain_g,
  input  logic [11:0]      cfg_gain_b,
  input  logic [1:0]       cfg_phase,
  input  logic             cfg_gamma,
  input  logic             cfg_geq,       // green equalisation: G at a G site = (G + mean of the four diagonal G) / 2
  input  logic             cfg_hl,        // highlight clamp: G >= cfg_hl_level gives G = max(G, R, B)
  input  logic [9:0]       cfg_hl_level,

  // RGB out: {R[23:16], B[15:8], G[7:0]}.
  output logic [23:0]      o_data,
  output logic             o_valid,
  input  logic             o_ready,
  output logic             o_sof,
  output logic             o_eol,

  // Events and measurements.
  output logic             ev_size_err,
  output logic [15:0]      meas_lines,
  output logic [15:0]      meas_pixels,
  output logic [9:0]       meas_raw_max_r,   // maxima of the last frame, black level subtracted, before the gain
  output logic [9:0]       meas_raw_max_g,
  output logic [9:0]       meas_raw_max_b
);

  localparam int ADDR_W = $clog2(LINE_KB * 256);

  // Gamma curve of the segments: GAMMA_Y[k] is the output at input 16 * k (output 255 at k = 16).
  localparam logic [7:0] GAMMA_Y [0:16] = '{
    8'd0, 8'd72, 8'd99, 8'd119, 8'd136, 8'd151, 8'd164, 8'd175, 8'd186, 8'd197, 8'd206, 8'd215, 8'd224, 8'd232, 8'd240, 8'd248, 8'd255
  };

  typedef enum logic [2:0] {F_IDLE, F_LINE, F_CLOSE, F_VLINE, F_FEWAIT} fstate_t;
  localparam logic [1:0] K_PIX = 2'd0;
  localparam logic [1:0] K_EOL = 2'd1;
  localparam logic [1:0] K_FE  = 2'd2;

  typedef struct packed {
    logic        v;
    logic [11:0] x;
    logic        xp, yp, xW, x0, y0, y1, yH, vcol;
    logic [1:0]  ph;
    logic        gm;
    logic        ge;
    logic        hl;
    logic [9:0]  hll;
  } step_t;

  logic adv;

  // ---------------------------------------------------------------------------
  // Unpacker: entries to tokens
  // ---------------------------------------------------------------------------
  logic              ent_v;
  logic [ENT_W-1:0]  ent;
  logic [1:0]        idx;
  logic [2:0]        ent_cnt;
  logic              u_valid;
  logic [1:0]        u_kind;
  logic [9:0]        u_pix;
  logic              u_sof, u_eol, u_last;
  logic              tk;

  assign ent_cnt = ent[ENT_CNT +: 3];

  always_comb begin
    u_valid = ent_v;
    u_kind  = K_PIX;
    u_pix   = '0;
    u_sof   = 1'b0;
    u_eol   = 1'b0;
    u_last  = 1'b1;
    if (ent_cnt == 3'd0) begin
      u_kind = ent[ENT_FE] ? K_FE : K_EOL;
    end else begin
      case (idx)
        2'd0:    u_pix = ent[9:0];
        2'd1:    u_pix = ent[19:10];
        2'd2:    u_pix = ent[29:20];
        default: u_pix = ent[39:30];
      endcase
      u_sof  = ent[ENT_SOF] && (idx == 2'd0);
      u_last = ({1'b0, idx} == (ent_cnt - 3'd1));
      u_eol  = ent[ENT_EOL] && u_last;
    end
  end

  assign e_ready = !ent_v || (tk && u_last);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      ent_v <= 1'b0;
      ent   <= '0;
      idx   <= '0;
    end else begin
      if (e_valid && e_ready) begin
        ent   <= e_data;
        ent_v <= 1'b1;
        idx   <= '0;
      end else if (tk) begin
        if (u_last) ent_v <= 1'b0;
        else        idx   <= idx + 2'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Feeder: frame and line conditioning
  // ---------------------------------------------------------------------------
  fstate_t       fstate;
  logic [11:0]   fw, fh;
  logic [11:0]   x, y;
  logic          line_open, early, frame_first, line_real, size_bad;
  logic [15:0]   px_cnt, lines_in;
  logic [9:0]    lat_black;
  logic [11:0]   lat_gr, lat_gg, lat_gb;
  logic [1:0]    lat_ph;
  logic          lat_gm, lat_ge, lat_hl;
  logic [9:0]    lat_hll;
  logic [9:0]    run_max_r, run_max_g, run_max_b;
  logic          em, em_vcol, em_vrow;
  logic [9:0]    em_pix;
  logic          stop_case;
  logic          closed;
  logic          fin_frame;

  always_comb begin
    tk      = 1'b0;
    em      = 1'b0;
    em_vcol = 1'b0;
    em_vrow = 1'b0;
    em_pix  = '0;
    case (fstate)
      F_IDLE: begin
        tk = adv && u_valid && !((u_kind == K_PIX) && u_sof);
      end
      F_LINE: begin
        if (adv) begin
          if (x == fw) begin
            em = 1'b1; em_vcol = 1'b1;
          end else if (!line_open || early) begin
            em = 1'b1;
          end else if (u_valid) begin
            em = 1'b1;
            if ((u_kind == K_PIX) && (!u_sof || frame_first)) begin
              tk = 1'b1; em_pix = u_pix;
            end else if (u_kind == K_EOL) begin
              tk = 1'b1;
            end
          end
        end
      end
      F_CLOSE: begin
        tk = adv && line_open && !early && u_valid && (((u_kind == K_PIX) && !u_sof) || (u_kind == K_EOL));
      end
      F_VLINE: begin
        if (adv) begin
          em = 1'b1; em_vrow = 1'b1; em_vcol = (x == fw);
        end
      end
      default: begin   // F_FEWAIT
        tk = adv && u_valid && (((u_kind == K_PIX) && !u_sof) || (u_kind != K_PIX));
      end
    endcase
  end

  assign stop_case = (fstate == F_LINE) && em && !em_vcol && line_open && !early && u_valid && !tk;
  assign closed    = !line_open || early;
  assign fin_frame = (fstate == F_FEWAIT) && adv && u_valid && ((u_kind == K_FE) || ((u_kind == K_PIX) && u_sof));

  step_t s0;
  logic [9:0] s0_pix;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      fstate      <= F_IDLE;
      fw          <= '0;
      fh          <= '0;
      x           <= '0;
      y           <= '0;
      line_open   <= 1'b0;
      early       <= 1'b0;
      frame_first <= 1'b0;
      line_real   <= 1'b0;
      size_bad    <= 1'b0;
      px_cnt      <= '0;
      lines_in    <= '0;
      lat_black   <= '0;
      lat_gr      <= 12'h100;
      lat_gg      <= 12'h100;
      lat_gb      <= 12'h100;
      lat_ph      <= '0;
      lat_gm      <= 1'b0;
      lat_ge      <= 1'b0;
      lat_hl      <= 1'b0;
      lat_hll     <= '0;
      meas_raw_max_r <= '0;
      meas_raw_max_g <= '0;
      meas_raw_max_b <= '0;
      meas_lines  <= '0;
      meas_pixels <= '0;
      ev_size_err <= 1'b0;
      s0          <= '0;
      s0_pix      <= '0;
    end else begin
      ev_size_err <= 1'b0;
      if (adv) begin
        s0.v <= 1'b0;
      end
      case (fstate)
        F_IDLE: begin
          if (adv && u_valid && (u_kind == K_PIX) && u_sof) begin
            fw          <= cfg_w;
            fh          <= cfg_h;
            x           <= '0;
            y           <= '0;
            line_open   <= 1'b1;
            early       <= 1'b0;
            frame_first <= 1'b1;
            line_real   <= 1'b0;
            size_bad    <= 1'b0;
            px_cnt      <= '0;
            lines_in    <= '0;
            lat_black   <= cfg_black;
            lat_gr      <= cfg_gain_r;
            lat_gg      <= cfg_gain_g;
            lat_gb      <= cfg_gain_b;
            lat_ph      <= cfg_phase;
            lat_gm      <= cfg_gamma;
            lat_ge      <= cfg_geq;
            lat_hl      <= cfg_hl;
            lat_hll     <= cfg_hl_level;
            fstate      <= F_LINE;
          end
        end
        F_LINE: begin
          if (em) begin
            x <= em_vcol ? 12'd0 : (x + 12'd1);
            if (em_vcol) fstate <= F_CLOSE;
          end
          if (tk) begin
            frame_first <= 1'b0;
            line_real   <= 1'b1;
            if (u_kind == K_PIX) begin
              px_cnt <= px_cnt + 16'd1;
              if (u_eol) line_open <= 1'b0;
            end else begin
              line_open <= 1'b0;
            end
          end
          if (stop_case) begin
            early     <= 1'b1;
            line_open <= 1'b0;
          end
        end
        F_CLOSE: begin
          if (tk) begin
            line_real <= 1'b1;
            if (u_kind == K_PIX) begin
              px_cnt <= px_cnt + 16'd1;
              if (u_eol) line_open <= 1'b0;
            end else begin
              line_open <= 1'b0;
            end
          end else if (adv && line_open && !early && u_valid) begin
            early     <= 1'b1;               // frame end or a new frame start inside the line
            line_open <= 1'b0;
          end
          if (adv && closed) begin
            if (line_real) begin
              lines_in    <= lines_in + 16'd1;
              meas_pixels <= px_cnt;
              if (px_cnt != {4'd0, fw}) size_bad <= 1'b1;
            end
            px_cnt      <= '0;
            line_real   <= 1'b0;
            frame_first <= 1'b0;
            y           <= y + 12'd1;
            x           <= '0;
            line_open   <= !early;
            fstate      <= ((y + 12'd1) == fh) ? F_VLINE : F_LINE;
          end
        end
        F_VLINE: begin
          if (em) begin
            x <= em_vcol ? 12'd0 : (x + 12'd1);
            if (em_vcol) fstate <= F_FEWAIT;
          end
        end
        default: begin   // F_FEWAIT
          if (tk && (((u_kind == K_PIX) && u_eol) || (u_kind == K_EOL))) lines_in <= lines_in + 16'd1;
          if (fin_frame) begin
            ev_size_err <= early || (lines_in != {4'd0, fh}) || size_bad;
            meas_lines  <= lines_in;
            meas_raw_max_r <= run_max_r;
            meas_raw_max_g <= run_max_g;
            meas_raw_max_b <= run_max_b;
            fstate      <= F_IDLE;
          end
        end
      endcase
      // Step register: only while the pipeline advances.
      if (adv && em) begin
        s0.v    <= 1'b1;
        s0.x    <= x;
        s0.xp   <= x[0];
        s0.yp   <= y[0];
        s0.xW   <= em_vcol;
        s0.x0   <= (x == 12'd0);
        s0.y0   <= (y == 12'd0);
        s0.y1   <= (y == 12'd1);
        s0.yH   <= em_vrow;
        s0.vcol <= em_vcol;
        s0.ph   <= lat_ph;
        s0.gm   <= lat_gm;
        s0.ge   <= lat_ge;
        s0.hl   <= lat_hl;
        s0.hll  <= lat_hll;
        s0_pix  <= em_pix;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 1: black level; stage 2: gain product; stage 3: rounding and clip
  // ---------------------------------------------------------------------------
  step_t        s1, s2, s3;
  logic [9:0]   s1_t;
  logic [11:0]  s1_g;
  logic [21:0]  s2_p;
  logic [9:0]   s3_cp;
  logic         site_u, site_v;
  logic [11:0]  gain_sel;
  logic [21:0]  prod_r;

  assign site_u = s0.xp ^ s0.ph[0];
  assign site_v = s0.yp ^ s0.ph[1];
  assign gain_sel = (!site_u && !site_v) ? lat_gr : ((site_u && site_v) ? lat_gb : lat_gg);
  assign prod_r   = 22'(s2_p + 22'd128) >> 8;

  // Raw maxima: s1 holds the step of s1_t (black level subtracted raw value of that step); the site is decoded from s1 like the gain from s0.
  logic s1_u, s1_v;
  assign s1_u = s1.xp ^ s1.ph[0];
  assign s1_v = s1.yp ^ s1.ph[1];

  always_ff @(posedge clk) begin
    if (!resetn) begin
      run_max_r <= '0; run_max_g <= '0; run_max_b <= '0;
    end else if ((fstate == F_IDLE) && adv && u_valid && (u_kind == K_PIX) && u_sof) begin
      run_max_r <= '0; run_max_g <= '0; run_max_b <= '0;
    end else if (adv && s1.v) begin
      if (!s1_u && !s1_v) begin
        if (s1_t > run_max_r) run_max_r <= s1_t;
      end else if (s1_u && s1_v) begin
        if (s1_t > run_max_b) run_max_b <= s1_t;
      end else begin
        if (s1_t > run_max_g) run_max_g <= s1_t;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      s1 <= '0; s2 <= '0; s3 <= '0;
      s1_t <= '0; s1_g <= '0; s2_p <= '0; s3_cp <= '0;
    end else if (adv) begin
      s1   <= s0;
      s1_t <= (s0_pix > lat_black) ? (s0_pix - lat_black) : 10'd0;
      s1_g <= gain_sel;
      s2   <= s1;
      s2_p <= s1_t * s1_g;
      s3   <= s2;
      s3_cp <= (prod_r > 22'd1023) ? 10'd1023 : prod_r[9:0];
    end
  end

  // ---------------------------------------------------------------------------
  // Line buffers and the column of three rows (stage 3)
  // ---------------------------------------------------------------------------
  logic [19:0]  ram_q;
  logic         ram_wr;
  logic         ram_rd;
  logic [9:0]   c_top, c_mid, c_bot;
  logic [9:0]   l1, l2;

  assign ram_rd = adv && s2.v && !s2.vcol;
  assign ram_wr = adv && s3.v && !s3.vcol && !s3.yH;
  assign l1 = ram_q[9:0];
  assign l2 = ram_q[19:10];

  always_comb begin
    c_top = l2;
    c_mid = l1;
    c_bot = s3_cp;
    if (s3.y1) c_top = c_bot;
    if (s3.yH) c_bot = c_top;
  end

  rtlnet_ram_core #(
    .RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(20), .ADDR_W(ADDR_W), .READ_LATENCY(1)
  ) u_lines (
    .wr_clk(clk), .wr_en(ram_wr), .wr_addr(s3.x[ADDR_W-1:0]), .wr_data({l1, s3_cp}),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(ram_rd), .rd_addr(s2.x[ADDR_W-1:0]), .rd_data(ram_q)
  );

  // ---------------------------------------------------------------------------
  // Stage 4: window of three columns
  // ---------------------------------------------------------------------------
  step_t         s4;
  logic [29:0]   w0, w1, w2;     // {top, mid, bot} of the columns x - 2, x - 1, x

  always_ff @(posedge clk) begin
    if (!resetn) begin
      s4 <= '0; w0 <= '0; w1 <= '0; w2 <= '0;
    end else if (adv) begin
      s4 <= s3;
      if (s3.v) begin
        w0 <= w1;
        w1 <= w2;
        w2 <= {c_top, c_mid, c_bot};
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 5: demosaic
  // ---------------------------------------------------------------------------
  logic [29:0]  lc, cc, rc;
  logic [9:0]   n_p, s_p, w_p, e_p, nw_p, ne_p, sw_p, se_p, c_p;
  logic [11:0]  cross4, diag4, horz2, vert2;
  logic [9:0]   d_r, d_g, d_b, g_eq;
  logic         cu, cv;
  logic         d_v, d_sof, d_eol, d_gm;
  step_t        s5;

  always_comb begin
    // Missing left column at the first output column (x = 1), missing right column at the virtual column.
    cc = w1;
    lc = (s4.x == 12'd1) ? w2 : w0;
    rc = s4.xW ? w0 : w2;
    n_p  = cc[29:20];  c_p  = cc[19:10];  s_p  = cc[9:0];
    nw_p = lc[29:20];  w_p  = lc[19:10];  sw_p = lc[9:0];
    ne_p = rc[29:20];  e_p  = rc[19:10];  se_p = rc[9:0];
    cross4 = 12'(n_p) + 12'(s_p) + 12'(w_p) + 12'(e_p) + 12'd2;
    diag4  = 12'(nw_p) + 12'(ne_p) + 12'(sw_p) + 12'(se_p) + 12'd2;
    horz2  = 12'(w_p) + 12'(e_p) + 12'd1;
    vert2  = 12'(n_p) + 12'(s_p) + 12'd1;
    g_eq   = 10'((12'(c_p) + 12'(diag4 >> 2) + 12'd1) >> 1);
    cu = !s4.xp ^ s4.ph[0];
    cv = !s4.yp ^ s4.ph[1];
    d_r = c_p; d_g = c_p; d_b = c_p;
    if (!cu && !cv) begin            // R site
      d_r = c_p; d_g = 10'(cross4 >> 2); d_b = 10'(diag4 >> 2);
    end else if (cu && cv) begin     // B site
      d_b = c_p; d_g = 10'(cross4 >> 2); d_r = 10'(diag4 >> 2);
    end else if (cu && !cv) begin    // G on a red row
      d_g = s4.ge ? g_eq : c_p; d_r = 10'(horz2 >> 1); d_b = 10'(vert2 >> 1);
    end else begin                   // G on a blue row
      d_g = s4.ge ? g_eq : c_p; d_b = 10'(horz2 >> 1); d_r = 10'(vert2 >> 1);
    end
  end

  logic [9:0] r5, g5, b5;
  logic       v5, sof5, eol5, gm5, hl5;
  logic [9:0] hll5;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      r5 <= '0; g5 <= '0; b5 <= '0; v5 <= 1'b0; sof5 <= 1'b0; eol5 <= 1'b0; gm5 <= 1'b0; hl5 <= 1'b0; hll5 <= '0;
    end else if (adv) begin
      r5   <= d_r;
      g5   <= d_g;
      b5   <= d_b;
      v5   <= s4.v && !s4.y0 && !s4.x0;
      sof5 <= s4.v && (s4.x == 12'd1) && s4.y1;
      eol5 <= s4.xW;
      gm5  <= s4.gm;
      hl5  <= s4.hl;
      hll5 <= s4.hll;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 6: scale to 8 bits; stage 7: gamma and the output register
  // ---------------------------------------------------------------------------
  function automatic logic [7:0] to8(input logic [9:0] v);
    logic [10:0] t;
    t = 11'(v) + 11'd2;
    to8 = (t[10:2] > 9'd255) ? 8'd255 : t[9:2];
  endfunction

  function automatic logic [7:0] gamma8(input logic [7:0] v, input logic en);
    logic [4:0]  seg;
    logic [3:0]  frac;
    logic [7:0]  y0v, y1v;
    logic [11:0] prod;
    seg  = {1'b0, v[7:4]};
    frac = v[3:0];
    y0v  = GAMMA_Y[seg];
    y1v  = GAMMA_Y[seg + 5'd1];
    prod = 12'(y1v - y0v) * 12'(frac);
    gamma8 = en ? (y0v + 8'(prod >> 4)) : v;
  endfunction

  logic [7:0] r6, g6, b6;
  logic       v6, sof6, eol6, gm6;
  logic [9:0] g5_hl, gmax;

  // Highlight clamp on the registered demosaic output: G >= level lifts G to the largest of the three.
  always_comb begin
    gmax  = (r5 > b5) ? r5 : b5;
    if (g5 > gmax) gmax = g5;
    g5_hl = (hl5 && (g5 >= hll5)) ? gmax : g5;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      r6 <= '0; g6 <= '0; b6 <= '0; v6 <= 1'b0; sof6 <= 1'b0; eol6 <= 1'b0; gm6 <= 1'b0;
    end else if (adv) begin
      r6 <= to8(r5); g6 <= to8(g5_hl); b6 <= to8(b5);
      v6 <= v5; sof6 <= sof5; eol6 <= eol5; gm6 <= gm5;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      o_data  <= '0;
      o_valid <= 1'b0;
      o_sof   <= 1'b0;
      o_eol   <= 1'b0;
    end else if (adv) begin
      o_valid <= v6;
      o_sof   <= sof6;
      o_eol   <= eol6;
      o_data  <= {gamma8(r6, gm6), gamma8(b6, gm6), gamma8(g6, gm6)};
    end
  end

  assign adv = !o_valid || o_ready;

endmodule
