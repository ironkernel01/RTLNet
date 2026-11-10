// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_pattern.sv
// Purpose: 75 percent color-bar generator of rtlnet_csi2_rx (documentation/gige.md section 5.4): one frame of eight
//   static vertical bars as a YUV422 word stream, with the line timing a sensor would produce.
// Overview:
//   * start (a one-clock pulse, accepted only while idle) latches the mode and begins a frame. A frame is H active lines
//     (720 or 1080); line n starts n * LINE_PERIOD clocks after the frame start (4,444 clocks at 720p30, 2,962 at
//     1080p30), so the load on DDR3 and its burst pattern match the camera in the same mode. A line is W words (640 or
//     960), one per clock while tready is high; a line that runs past its slot starts the next one as soon as it ends.
//   * Stream: 32-bit word = two pixels in memory byte order {Cr, Y1, Cb, Y0} (Y0 in tdata[7:0]); tuser marks the first
//     word of the frame (start of frame), tlast the last word of every line (end of line).
//   * Bars: eight bars of W/8 words (80 or 120, that is 160 or 240 pixels), every line identical. Colors are the
//     ITU-R BT.709 8-bit limited-range values of section 5.4, both pixels of a word take the bar's luma.
//   * busy is high from start until the last word of the last line is accepted.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk (memory-controller user clock, 100 MHz).
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_pattern #(
  parameter int WORDS_720       = 640,    // words per line, 1280 pixels
  parameter int WORDS_1080      = 960,    // words per line, 1920 pixels
  parameter int LINES_720       = 720,
  parameter int LINES_1080      = 1080,
  parameter int LINE_PERIOD_720 = 4444,   // clocks from line start to line start
  parameter int LINE_PERIOD_1080 = 2962
)(
  // Core clock and its reset (synchronous, active low).
  input  logic        clk,
  input  logic        resetn,

  // Frame start request and the mode (0 720p30, 1 1080p30) for the frame it starts.
  input  logic        start,
  input  logic [1:0]  mode,
  output logic        busy,

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

  localparam logic [1:0] S_IDLE = 2'd0;
  localparam logic [1:0] S_LINE = 2'd1;    // words of a line
  localparam logic [1:0] S_GAP  = 2'd2;    // wait for the next line start

  // Bar colors {Cr, Cb, Y} (gige.md section 5.4), 8-bit limited range BT.709.
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

  logic [1:0]               state;
  logic                     gen_1080;
  logic [10:0]              line;
  logic [9:0]               word;
  logic [BAR_IDX_W-1:0]     bar;
  logic [6:0]               bar_word;
  logic [COUNT_W-1:0]       line_timer;
  logic [9:0]               last_word;
  logic [10:0]              last_line;
  logic [6:0]               last_bar_word;
  logic [COUNT_W-1:0]       line_period;
  logic [23:0]              ycc;
  logic                     word_fire;
  logic                     last_word_fire;

  assign last_word     = gen_1080 ? 10'(WORDS_1080 - 1) : 10'(WORDS_720 - 1);
  assign last_line     = gen_1080 ? 11'(LINES_1080 - 1) : 11'(LINES_720 - 1);
  assign last_bar_word = gen_1080 ? 7'(WORDS_1080 / BARS - 1) : 7'(WORDS_720 / BARS - 1);
  assign line_period   = gen_1080 ? COUNT_W'(LINE_PERIOD_1080 - 1) : COUNT_W'(LINE_PERIOD_720 - 1);
  assign ycc           = bar_ycc(bar);

  assign m_tvalid       = (state == S_LINE);
  assign m_tdata        = {ycc[23:16], ycc[7:0], ycc[15:8], ycc[7:0]};   // {Cr, Y1, Cb, Y0}
  assign m_tlast        = (word == last_word);
  assign m_tuser        = (line == 11'd0) && (word == 10'd0);
  assign busy           = (state != S_IDLE);
  assign word_fire      = m_tvalid && m_tready;
  assign last_word_fire = word_fire && m_tlast;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state      <= S_IDLE;
      gen_1080   <= 1'b0;
      line       <= '0;
      word       <= '0;
      bar        <= '0;
      bar_word   <= '0;
      line_timer <= '0;
    end else begin
      // Line timer: counts from the line start, holds at the line period.
      if (state != S_IDLE && line_timer != '1) line_timer <= line_timer + COUNT_W'(1);
      case (state)
        S_IDLE: begin
          if (start) begin
            gen_1080   <= (mode == MODE_1080P30);
            state      <= S_LINE;
            line       <= '0;
            word       <= '0;
            bar        <= '0;
            bar_word   <= '0;
            line_timer <= '0;
          end
        end
        S_LINE: begin
          if (word_fire) begin
            if (word == last_word) begin
              word     <= '0;
              bar      <= '0;
              bar_word <= '0;
              if (line == last_line) begin
                state <= S_IDLE;
              end else begin
                line  <= line + 11'd1;
                state <= S_GAP;
              end
            end else begin
              word <= word + 10'd1;
              if (bar_word == last_bar_word) begin
                bar_word <= '0;
                bar      <= bar + BAR_IDX_W'(1);
              end else begin
                bar_word <= bar_word + 7'd1;
              end
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
    end
  end

endmodule
