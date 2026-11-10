// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_regs.sv
// Purpose: register file of rtlnet_csi2_rx (Phase 1): ID/VERSION/CAPS header, VIDEO_MODE, SOURCE, FRAME_PERIOD,
//   CAM_TIMEOUT, STATUS with the sticky error flags, FRAME_COUNT and ACTIVE.
// Overview:
//   * Strobe interface of rtlnet_axil_slave: a write strobe carries a full 32-bit word; a read strobe is answered with a
//     registered read mux, data valid the clock after reg_rd_en. Undefined offsets read 0; writes to them are ignored.
//   * Rejection rules (documentation/gige.md section 5.4): a VIDEO_MODE value above 1 sets STATUS.MODE_ERR and leaves the
//     register unchanged; a VIDEO_MODE write whose mode minimum exceeds the present FRAME_PERIOD sets STATUS.PERIOD_ERR
//     and leaves the register unchanged; a FRAME_PERIOD below the minimum of the selected mode sets STATUS.PERIOD_ERR
//     and leaves the register unchanged; SOURCE 3 (or any value above 3) sets STATUS.SOURCE_ERR. Nothing is clamped.
//     Because both writes check the other register, FRAME_PERIOD >= the minimum of VIDEO_MODE holds at every time.
//   * STATUS error flags are sticky and clear by writing 1; a new error in the clock of a clear keeps the flag set.
//   * Offsets are defined in driver/rtlnet_csi2_rx.h and mirrored here.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk (all logic; the memory-controller user clock).
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_regs #(
  parameter int          NUM_MODES       = 2,
  parameter bit          CAMERA_PRESENT  = 1'b0,
  parameter int          PERIOD_RESET    = 3_333_333,
  parameter int          PERIOD_MIN_720  = 3_333_000,
  parameter int          PERIOD_MIN_1080 = 3_332_250,
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

  // Status from the datapath.
  input  logic        st_pattern,       // active source: 1 pattern, 0 camera
  input  logic        st_clk_run,       // camera byte clock running
  input  logic        ev_overrun,       // one-clock pulse: a frame tick found the previous frame still running
  input  logic [31:0] frame_count,
  input  logic [1:0]  act_mode
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

  localparam int ST_PATTERN_BIT    = 0;
  localparam int ST_CLK_RUN_BIT    = 1;
  localparam int ST_MODE_ERR_BIT   = 2;
  localparam int ST_PERIOD_ERR_BIT = 3;
  localparam int ST_SOURCE_ERR_BIT = 4;
  localparam int ST_OVERRUN_BIT    = 5;

  localparam logic [1:0] MODE_720P30  = 2'd0;
  localparam logic [1:0] MODE_1080P30 = 2'd1;
  localparam logic [1:0] SRC_RESERVED = 2'd3;

  import rtlnet_pkg::*;

  localparam logic [31:0] CORE_ID      = id4("C", "S", "I", "2");
  localparam logic [31:0] CORE_VERSION = 32'h1109_2026;
  // CAPS: [3:0] number of video modes, [4] test-pattern generator, [5] camera front end.
  localparam logic [31:0] CORE_CAPS    = {26'd0, CAMERA_PRESENT, 1'b1, 4'(NUM_MODES)};

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic        mode_err;
  logic        period_err;
  logic        source_err;
  logic        overrun;
  logic        wr_video_mode;
  logic        wr_source;
  logic        wr_period;
  logic        wr_status;
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

  // Minimum FRAME_PERIOD of the selected mode and of the mode a VIDEO_MODE write requests.
  assign min_selected  = (video_mode == MODE_1080P30) ? 32'(PERIOD_MIN_1080) : 32'(PERIOD_MIN_720);
  assign mode_valid    = (reg_wr_data[31:2] == 30'd0) && (reg_wr_data[1:0] <= MODE_1080P30);
  assign min_requested = (reg_wr_data[1:0] == MODE_1080P30) ? 32'(PERIOD_MIN_1080) : 32'(PERIOD_MIN_720);

  assign set_mode_err   = wr_video_mode && !mode_valid;
  assign set_period_err = (wr_video_mode && mode_valid && (frame_period < min_requested)) ||
                          (wr_period && (reg_wr_data < min_selected));
  assign set_source_err = wr_source && ((reg_wr_data[31:2] != 30'd0) || (reg_wr_data[1:0] == SRC_RESERVED));

  // Configuration registers.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      video_mode   <= MODE_720P30;
      source       <= 2'd0;
      frame_period <= 32'(PERIOD_RESET);
      cam_timeout  <= 32'(CAM_TIMEOUT_RST);
    end else begin
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
    end else begin
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
        default:          reg_rd_data <= '0;
      endcase
    end
  end

endmodule
