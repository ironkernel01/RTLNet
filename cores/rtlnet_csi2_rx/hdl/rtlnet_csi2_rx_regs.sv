// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_regs.sv
// Purpose: register file of rtlnet_csi2_rx: ID/VERSION/CAPS header, VIDEO_MODE, SOURCE, FRAME_PERIOD,
//   CAM_TIMEOUT, STATUS with the sticky error flags, FRAME_COUNT, ACTIVE, PATTERN and PATTERN_FRAME, and with CAMERA_PRESENT the
//   registers of the camera receiver (control, status, delay taps, settle time, filter, counters, Bayer processing).
// Overview:
//   * Strobe interface of rtlnet_axil_slave: a write strobe carries a full 32-bit word; a read strobe is answered with a
//     registered read mux, data valid the clock after reg_rd_en. Undefined offsets read 0; writes to them are ignored.
//   * Rejection rules: a VIDEO_MODE value above 1 sets STATUS.MODE_ERR and leaves the
//     register unchanged; a VIDEO_MODE write whose mode minimum exceeds the present FRAME_PERIOD sets STATUS.PERIOD_ERR
//     and leaves the register unchanged; a FRAME_PERIOD below the minimum of the selected mode sets STATUS.PERIOD_ERR
//     and leaves the register unchanged; SOURCE 3 (or any value above 3) sets STATUS.SOURCE_ERR. Nothing is clamped.
//     Because both writes check the other register, FRAME_PERIOD >= the minimum of VIDEO_MODE holds at every time.
//     PATTERN: [2:0] pattern 0..4, [15:8] signed speed -32..+32, every other bit 0; anything else sets STATUS.PATTERN_ERR and
//     leaves the register unchanged. An accepted PATTERN write, and an accepted VIDEO_MODE write that changes the mode, give
//     pat_restart (one clock, registered): the pattern frame counter restarts at 0 (pattern generator).
//   * STATUS error flags are sticky and clear by writing 1; a new error in the clock of a clear keeps the flag set.
//   * Camera receiver registers (CAMERA_PRESENT = 1; with 0 they read 0, writes are ignored and VERSION stays 0x11102026): RX_CTRL, RX_STATUS,
//     RX_TAPS, RX_SETTLE, RX_FILTER, RX_CLEAR, RX_LINES, RX_PIXELS, twelve 32-bit event counters (saturating, cleared by RX_CLEAR bits or
//     bit 31 for all), BLACK, WB_R, WB_G, WB_B, PHASE, PROC (bit 0 gamma, bit 1 green equalisation, bit 2 highlight clamp), RAW_MAX (0x0A8, read
//     only: [9:0] red, [19:10] green, [29:20] blue maximum of the raw values of the last frame) and HL_LEVEL (0x0AC, [9:0] clamp level, reset 0). Fields are masked to their width, reserved bits read 0 and writes to them are
//     ignored; there are no reject flags in this block.
//   * Offsets are defined in driver/rtlnet_csi2_rx.h and mirrored here.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: PROC bit 2 (highlight clamp), RAW_MAX (0x0A8) and HL_LEVEL (0x0AC).
//   * 11-15-2026: camera receiver registers (0x040 to 0x0A4), VERSION 0x11152026 when CAMERA_PRESENT, CAPS[5] set by it.
//   * 11-10-2026: PATTERN (0x030), PATTERN_FRAME (0x034), STATUS.PATTERN_ERR, CAPS[6] moving patterns, VERSION 0x11102026.
//   * 11-09-2026: initial version.
// Clocks: clk (all logic; the memory-controller user clock).
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_regs #(
  parameter int          NUM_MODES       = 2,
  parameter bit          CAMERA_PRESENT  = 1'b0,
  parameter int          PERIOD_RESET    = 3_000_000,
  parameter int          PERIOD_MIN_720  = 3_000_000,
  parameter int          PERIOD_MIN_1080 = 2_999_250,
  parameter int          CAM_TIMEOUT_RST = 2
)(
  // Core clock and its reset (synchronous, active low).
  input  logic        clk,
  input  logic        resetn,

  // Register strobes from rtlnet_axil_slave, clk domain: one full-word write per reg_wr_en clock; reg_rd_data is due
  // the clock after reg_rd_en.
  input  logic        reg_wr_en,
  input  logic [11:0] reg_wr_addr,
  input  logic [31:0] reg_wr_data,
  input  logic        reg_rd_en,
  input  logic [11:0] reg_rd_addr,
  output logic [31:0] reg_rd_data,

  // Configuration to the datapath.
  output logic [1:0]  video_mode,
  output logic [1:0]  source,
  output logic [31:0] frame_period,
  output logic [31:0] cam_timeout,
  output logic [2:0]  pattern,
  output logic [7:0]  pat_speed,
  output logic        pat_restart,

  // Status from the datapath.
  input  logic        st_pattern,       // active source: 1 pattern, 0 camera
  input  logic        st_clk_run,       // camera byte clock running
  input  logic        ev_overrun,       // one-clock pulse: a frame tick found the previous frame still running
  input  logic [31:0] frame_count,
  input  logic [1:0]  act_mode,
  input  logic [31:0] pat_frame,

  // Camera receiver (CAMERA_PRESENT): configuration out (levels in clk), status and events in.
  output logic        rx_enable,
  output logic        rx_soft_reset,
  output logic [1:0]  rx_lane_en,
  output logic        rx_bit_rev,
  output logic [4:0]  rx_tap0,
  output logic [4:0]  rx_tap1,
  output logic [7:0]  rx_settle,
  output logic [1:0]  rx_vc,
  output logic [5:0]  rx_dt,
  output logic [9:0]  px_black,
  output logic [11:0] px_gain_r,
  output logic [11:0] px_gain_g,
  output logic [11:0] px_gain_b,
  output logic [1:0]  px_phase,
  output logic        px_gamma,
  output logic        px_geq,
  output logic        px_hl,
  output logic [9:0]  px_hl_level,
  input  logic [9:0]  px_raw_max_r,     // RAW_MAX of the last frame
  input  logic [9:0]  px_raw_max_g,
  input  logic [9:0]  px_raw_max_b,
  input  logic [11:0] rx_st,            // RX_STATUS bits [11:0]
  input  logic [15:0] rx_lines,
  input  logic [15:0] rx_pixels,
  input  logic [11:0] rx_ev             // one-clock event pulses, counter index order of the map
);

  // ---------------------------------------------------------------------------
  // Register map: mirrors cores/rtlnet_csi2_rx/driver/rtlnet_csi2_rx.h.
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID           = 12'h000;
  localparam logic [11:0] REG_VERSION      = 12'h004;
  localparam logic [11:0] REG_CAPS         = 12'h008;
  localparam logic [11:0] REG_VIDEO_MODE   = 12'h010;
  localparam logic [11:0] REG_SOURCE       = 12'h014;
  localparam logic [11:0] REG_FRAME_PERIOD = 12'h018;
  localparam logic [11:0] REG_CAM_TIMEOUT  = 12'h01C;
  localparam logic [11:0] REG_STATUS       = 12'h020;
  localparam logic [11:0] REG_FRAME_COUNT  = 12'h024;
  localparam logic [11:0] REG_ACTIVE       = 12'h028;
  localparam logic [11:0] REG_PATTERN      = 12'h030;
  localparam logic [11:0] REG_PAT_FRAME    = 12'h034;
  localparam logic [11:0] REG_RX_CTRL      = 12'h040;
  localparam logic [11:0] REG_RX_STATUS    = 12'h044;
  localparam logic [11:0] REG_RX_TAPS      = 12'h048;
  localparam logic [11:0] REG_RX_SETTLE    = 12'h04C;
  localparam logic [11:0] REG_RX_FILTER    = 12'h050;
  localparam logic [11:0] REG_RX_CLEAR     = 12'h054;
  localparam logic [11:0] REG_RX_LINES     = 12'h058;
  localparam logic [11:0] REG_RX_PIXELS    = 12'h05C;
  localparam logic [11:0] REG_CNT_BASE     = 12'h060;   // twelve counters, 4 bytes each, to 0x08C
  localparam logic [11:0] REG_BLACK        = 12'h090;
  localparam logic [11:0] REG_WB_R         = 12'h094;
  localparam logic [11:0] REG_WB_G         = 12'h098;
  localparam logic [11:0] REG_WB_B         = 12'h09C;
  localparam logic [11:0] REG_PHASE        = 12'h0A0;
  localparam logic [11:0] REG_PROC         = 12'h0A4;   // bit 0 gamma, bit 1 green equalisation, bit 2 highlight clamp
  localparam logic [11:0] REG_RAW_MAX      = 12'h0A8;   // RO: [9:0] red, [19:10] green, [29:20] blue maximum of the last frame
  localparam logic [11:0] REG_HL_LEVEL     = 12'h0AC;   // RW: [9:0] highlight clamp level
  localparam int          NUM_CNT          = 12;

  localparam int ST_PATTERN_BIT    = 0;
  localparam int ST_CLK_RUN_BIT    = 1;
  localparam int ST_MODE_ERR_BIT   = 2;
  localparam int ST_PERIOD_ERR_BIT = 3;
  localparam int ST_SOURCE_ERR_BIT = 4;
  localparam int ST_OVERRUN_BIT    = 5;
  localparam int ST_PATTERN_ERR_BIT = 6;

  localparam logic [1:0] MODE_720P30  = 2'd0;
  localparam logic [1:0] MODE_1080P30 = 2'd1;
  localparam logic [1:0] SRC_RESERVED = 2'd3;
  localparam logic [2:0] PAT_MAX      = 3'd4;
  localparam logic [31:0] PATTERN_RESET = 32'h0000_0400;   // pattern 0 (static bars), speed 4

  import rtlnet_pkg::*;

  localparam logic [31:0] CORE_ID      = id4("C", "S", "I", "2");
  localparam logic [31:0] CORE_VERSION = CAMERA_PRESENT ? 32'h1115_2026 : 32'h1110_2026;
  // CAPS: [3:0] number of video modes, [4] test-pattern generator, [5] camera front end, [6] moving patterns.
  localparam logic [31:0] CORE_CAPS    = {25'd0, 1'b1, CAMERA_PRESENT, 1'b1, 4'(NUM_MODES)};

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic        mode_err;
  logic        period_err;
  logic        source_err;
  logic        pattern_err;
  logic        overrun;
  logic        wr_video_mode;
  logic        wr_source;
  logic        wr_period;
  logic        wr_status;
  logic        wr_pattern;
  logic        pattern_valid;
  logic        set_pattern_err;
  logic        mode_change;
  logic [31:0] min_selected;
  logic [31:0] min_requested;
  logic        mode_valid;
  logic [31:0] status_word;
  logic        set_mode_err;
  logic        set_period_err;
  logic        set_source_err;

  assign wr_video_mode = reg_wr_en && (reg_wr_addr == REG_VIDEO_MODE);
  assign wr_source     = reg_wr_en && (reg_wr_addr == REG_SOURCE);
  assign wr_period     = reg_wr_en && (reg_wr_addr == REG_FRAME_PERIOD);
  assign wr_status     = reg_wr_en && (reg_wr_addr == REG_STATUS);
  assign wr_pattern    = reg_wr_en && (reg_wr_addr == REG_PATTERN);

  // Minimum FRAME_PERIOD of the selected mode and of the mode a VIDEO_MODE write requests.
  assign min_selected  = (video_mode == MODE_1080P30) ? 32'(PERIOD_MIN_1080) : 32'(PERIOD_MIN_720);
  assign mode_valid    = (reg_wr_data[31:2] == 30'd0) && (reg_wr_data[1:0] <= MODE_1080P30);
  assign min_requested = (reg_wr_data[1:0] == MODE_1080P30) ? 32'(PERIOD_MIN_1080) : 32'(PERIOD_MIN_720);

  assign set_mode_err   = wr_video_mode && !mode_valid;
  assign set_period_err = (wr_video_mode && mode_valid && (frame_period < min_requested)) ||
                          (wr_period && (reg_wr_data < min_selected));
  assign set_source_err = wr_source && ((reg_wr_data[31:2] != 30'd0) || (reg_wr_data[1:0] == SRC_RESERVED));

  // PATTERN: pattern 0..4 in [2:0], speed in [15:8] from -32 to +32 (0x00..0x20, 0xE0..0xFF), nothing else set.
  assign pattern_valid   = (reg_wr_data[31:16] == 16'd0) && (reg_wr_data[7:3] == 5'd0) && (reg_wr_data[2:0] <= PAT_MAX) &&
                           ((reg_wr_data[15:8] <= 8'd32) || (reg_wr_data[15:8] >= 8'hE0));
  assign set_pattern_err = wr_pattern && !pattern_valid;
  assign mode_change     = wr_video_mode && mode_valid && (frame_period >= min_requested) && (reg_wr_data[1:0] != video_mode);

  // Configuration registers.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      video_mode   <= MODE_720P30;
      source       <= 2'd0;
      frame_period <= 32'(PERIOD_RESET);
      cam_timeout  <= 32'(CAM_TIMEOUT_RST);
      pattern      <= PATTERN_RESET[2:0];
      pat_speed    <= PATTERN_RESET[15:8];
      pat_restart  <= 1'b0;
    end else begin
      pat_restart <= (wr_pattern && pattern_valid) || mode_change;
      if (wr_pattern && pattern_valid) begin
        pattern   <= reg_wr_data[2:0];
        pat_speed <= reg_wr_data[15:8];
      end
      if (wr_video_mode && mode_valid && (frame_period >= min_requested)) video_mode <= reg_wr_data[1:0];
      if (wr_source && !set_source_err)                                  source     <= reg_wr_data[1:0];
      if (wr_period && (reg_wr_data >= min_selected))                    frame_period <= reg_wr_data;
      if (reg_wr_en && (reg_wr_addr == REG_CAM_TIMEOUT))                 cam_timeout <= reg_wr_data;
    end
  end

  // Sticky error flags: a new error wins over a clear in the same clock.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      mode_err   <= 1'b0;
      period_err <= 1'b0;
      source_err <= 1'b0;
      overrun    <= 1'b0;
      pattern_err <= 1'b0;
    end else begin
      if (set_pattern_err)                                           pattern_err <= 1'b1;
      else if (wr_status && reg_wr_data[ST_PATTERN_ERR_BIT])         pattern_err <= 1'b0;
      if (set_mode_err)                                              mode_err   <= 1'b1;
      else if (wr_status && reg_wr_data[ST_MODE_ERR_BIT])            mode_err   <= 1'b0;
      if (set_period_err)                                            period_err <= 1'b1;
      else if (wr_status && reg_wr_data[ST_PERIOD_ERR_BIT])          period_err <= 1'b0;
      if (set_source_err)                                            source_err <= 1'b1;
      else if (wr_status && reg_wr_data[ST_SOURCE_ERR_BIT])          source_err <= 1'b0;
      if (ev_overrun)                                                overrun    <= 1'b1;
      else if (wr_status && reg_wr_data[ST_OVERRUN_BIT])             overrun    <= 1'b0;
    end
  end

  always_comb begin
    status_word                    = '0;
    status_word[ST_PATTERN_BIT]    = st_pattern;
    status_word[ST_CLK_RUN_BIT]    = st_clk_run;
    status_word[ST_MODE_ERR_BIT]   = mode_err;
    status_word[ST_PERIOD_ERR_BIT] = period_err;
    status_word[ST_SOURCE_ERR_BIT] = source_err;
    status_word[ST_OVERRUN_BIT]    = overrun;
    status_word[ST_PATTERN_ERR_BIT] = pattern_err;
  end

  // ---------------------------------------------------------------------------
  // Camera receiver registers
  // ---------------------------------------------------------------------------
  logic [31:0] cnt [0:NUM_CNT-1];
  logic [NUM_CNT-1:0] clr_mask;
  logic        wr_cam;

  assign wr_cam = CAMERA_PRESENT && reg_wr_en;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      rx_enable     <= 1'b1;
      rx_soft_reset <= 1'b0;
      rx_lane_en    <= 2'b11;
      rx_bit_rev    <= 1'b0;
      rx_tap0       <= 5'd0;
      rx_tap1       <= 5'd0;
      rx_settle     <= 8'd28;
      rx_vc         <= 2'd0;
      rx_dt         <= 6'h2B;
      px_black      <= 10'd0;
      px_gain_r     <= 12'h100;
      px_gain_g     <= 12'h100;
      px_gain_b     <= 12'h100;
      px_phase      <= 2'd0;
      px_gamma      <= 1'b0;
      px_geq        <= 1'b0;
      px_hl         <= 1'b0;
      px_hl_level   <= 10'd0;
    end else if (wr_cam) begin
      case (reg_wr_addr)
        REG_RX_CTRL: begin
          rx_enable     <= reg_wr_data[0];
          rx_soft_reset <= reg_wr_data[1];
          rx_lane_en    <= reg_wr_data[3:2];
          rx_bit_rev    <= reg_wr_data[4];
        end
        REG_RX_TAPS: begin
          rx_tap0 <= reg_wr_data[4:0];
          rx_tap1 <= reg_wr_data[12:8];
        end
        REG_RX_SETTLE: rx_settle <= reg_wr_data[7:0];
        REG_RX_FILTER: begin
          rx_vc <= reg_wr_data[1:0];
          rx_dt <= reg_wr_data[13:8];
        end
        REG_BLACK: px_black  <= reg_wr_data[9:0];
        REG_WB_R:  px_gain_r <= reg_wr_data[11:0];
        REG_WB_G:  px_gain_g <= reg_wr_data[11:0];
        REG_WB_B:  px_gain_b <= reg_wr_data[11:0];
        REG_PHASE: px_phase  <= reg_wr_data[1:0];
        REG_PROC:  begin px_gamma <= reg_wr_data[0]; px_geq <= reg_wr_data[1]; px_hl <= reg_wr_data[2]; end
        REG_HL_LEVEL: px_hl_level <= reg_wr_data[9:0];
        default: begin
        end
      endcase
    end
  end

  // Event counters: saturating; a clear in the clock of an event keeps that event.
  always_comb begin
    clr_mask = '0;
    if (wr_cam && (reg_wr_addr == REG_RX_CLEAR)) clr_mask = reg_wr_data[31] ? '1 : reg_wr_data[NUM_CNT-1:0];
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < NUM_CNT; i++) begin
      if (!resetn) begin
        cnt[i] <= '0;
      end else if (rx_ev[i]) begin
        if (clr_mask[i])       cnt[i] <= 32'd1;
        else if (cnt[i] != '1) cnt[i] <= cnt[i] + 32'd1;
      end else if (clr_mask[i]) begin
        cnt[i] <= '0;
      end
    end
  end

  logic [31:0] cnt_rd;
  always_comb begin
    cnt_rd = '0;
    for (int i = 0; i < NUM_CNT; i++) begin
      if (reg_rd_addr == (REG_CNT_BASE + 12'(4 * i))) cnt_rd = cnt[i];
    end
  end

  // Registered read mux: data the clock after reg_rd_en.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:           reg_rd_data <= CORE_ID;
        REG_VERSION:      reg_rd_data <= CORE_VERSION;
        REG_CAPS:         reg_rd_data <= CORE_CAPS;
        REG_VIDEO_MODE:   reg_rd_data <= {30'd0, video_mode};
        REG_SOURCE:       reg_rd_data <= {30'd0, source};
        REG_FRAME_PERIOD: reg_rd_data <= frame_period;
        REG_CAM_TIMEOUT:  reg_rd_data <= cam_timeout;
        REG_STATUS:       reg_rd_data <= status_word;
        REG_FRAME_COUNT:  reg_rd_data <= frame_count;
        REG_ACTIVE:       reg_rd_data <= {30'd0, act_mode};
        REG_PATTERN:      reg_rd_data <= {16'd0, pat_speed, 5'd0, pattern};
        REG_PAT_FRAME:    reg_rd_data <= pat_frame;
        REG_RX_CTRL:      reg_rd_data <= CAMERA_PRESENT ? {27'd0, rx_bit_rev, rx_lane_en, rx_soft_reset, rx_enable} : '0;
        REG_RX_STATUS:    reg_rd_data <= CAMERA_PRESENT ? {20'd0, rx_st} : '0;
        REG_RX_TAPS:      reg_rd_data <= CAMERA_PRESENT ? {19'd0, rx_tap1, 3'd0, rx_tap0} : '0;
        REG_RX_SETTLE:    reg_rd_data <= CAMERA_PRESENT ? {24'd0, rx_settle} : '0;
        REG_RX_FILTER:    reg_rd_data <= CAMERA_PRESENT ? {18'd0, rx_dt, 6'd0, rx_vc} : '0;
        REG_RX_LINES:     reg_rd_data <= CAMERA_PRESENT ? {16'd0, rx_lines} : '0;
        REG_RX_PIXELS:    reg_rd_data <= CAMERA_PRESENT ? {16'd0, rx_pixels} : '0;
        REG_BLACK:        reg_rd_data <= CAMERA_PRESENT ? {22'd0, px_black} : '0;
        REG_WB_R:         reg_rd_data <= CAMERA_PRESENT ? {20'd0, px_gain_r} : '0;
        REG_WB_G:         reg_rd_data <= CAMERA_PRESENT ? {20'd0, px_gain_g} : '0;
        REG_WB_B:         reg_rd_data <= CAMERA_PRESENT ? {20'd0, px_gain_b} : '0;
        REG_PHASE:        reg_rd_data <= CAMERA_PRESENT ? {30'd0, px_phase} : '0;
        REG_PROC:         reg_rd_data <= CAMERA_PRESENT ? {29'd0, px_hl, px_geq, px_gamma} : '0;
        REG_RAW_MAX:      reg_rd_data <= CAMERA_PRESENT ? {2'd0, px_raw_max_b, px_raw_max_g, px_raw_max_r} : '0;
        REG_HL_LEVEL:     reg_rd_data <= CAMERA_PRESENT ? {22'd0, px_hl_level} : '0;
        default:          reg_rd_data <= CAMERA_PRESENT ? cnt_rd : '0;
      endcase
    end
  end

endmodule
