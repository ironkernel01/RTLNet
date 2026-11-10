// -----------------------------------------------------------------------------
// File: rtlnet_vdma_s2mm_regs.sv
// Purpose: register file of rtlnet_vdma_s2mm: ID/VERSION/CAPS header, CTRL, STATUS with the sticky error flags, STRIDE and
//   the frame, burst and beat counters.
// Overview:
//   * Strobe interface of rtlnet_axil_slave: a write strobe carries a full 32-bit word; a read strobe is answered with a
//     registered read mux, data valid the clock after reg_rd_en. Undefined offsets read 0; writes to them are ignored.
//   * CTRL.ENABLE resets to 1 (the core runs with no firmware writes). CTRL.CNT_CLEAR (self-clearing, reads 0) clears
//     every counter; an event in the clock of a clear is dropped.
//   * STATUS error flags (CFG_ERR, AXI_ERR, LINE_ERR) are sticky and clear by writing 1; a new error in the clock of a clear
//     keeps the flag set.
//   * Counters are 32-bit and wrap. Offsets are defined in driver/rtlnet_vdma_s2mm.h and mirrored here.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk (all logic).
// -----------------------------------------------------------------------------
module rtlnet_vdma_s2mm_regs #(
  parameter int MAX_BURST_BEATS = 16,
  parameter int BEAT_BYTES      = 16,
  parameter int ADDR_W          = 29
)(
  // Core clock and its reset (synchronous, active low).
  input  logic              clk,
  input  logic              resetn,

  // Register strobes from rtlnet_axil_slave, clk domain.
  input  logic              reg_wr_en,
  input  logic [11:0]       reg_wr_addr,
  input  logic [31:0]       reg_wr_data,
  input  logic              reg_rd_en,
  input  logic [11:0]       reg_rd_addr,
  output logic [31:0]       reg_rd_data,

  // Configuration to the datapath.
  output logic              enable,
  output logic [31:0]       stride,

  // Datapath status and one-clock event pulses.
  input  logic              st_busy,
  input  logic              ev_cfg_err,
  input  logic              ev_axi_err,
  input  logic              ev_line_err,
  input  logic              ev_frame_ok,
  input  logic              ev_frame_bad,
  input  logic              ev_frame_drop,
  input  logic              ev_burst,
  input  logic              ev_beat,
  input  logic              ev_frame_start,
  input  logic [ADDR_W-1:0] frame_base
);

  // Register map: mirrors cores/rtlnet_vdma_s2mm/driver/rtlnet_vdma_s2mm.h.
  localparam logic [11:0] REG_ID             = 12'h000;
  localparam logic [11:0] REG_VERSION        = 12'h004;
  localparam logic [11:0] REG_CAPS           = 12'h008;
  localparam logic [11:0] REG_CTRL           = 12'h00C;
  localparam logic [11:0] REG_STATUS         = 12'h010;
  localparam logic [11:0] REG_STRIDE         = 12'h014;
  localparam logic [11:0] REG_FRAMES_OK      = 12'h018;
  localparam logic [11:0] REG_FRAMES_BAD     = 12'h01C;
  localparam logic [11:0] REG_FRAMES_DROPPED = 12'h020;
  localparam logic [11:0] REG_BURSTS         = 12'h024;
  localparam logic [11:0] REG_BEATS          = 12'h028;
  localparam logic [11:0] REG_LAST_BASE      = 12'h02C;

  localparam int CTRL_ENABLE_BIT    = 0;
  localparam int CTRL_CNT_CLEAR_BIT = 16;
  localparam int ST_BUSY_BIT        = 0;
  localparam int ST_CFG_ERR_BIT     = 1;
  localparam int ST_AXI_ERR_BIT     = 2;
  localparam int ST_LINE_ERR_BIT    = 3;

  import rtlnet_pkg::*;

  localparam logic [31:0] CORE_ID      = id4("S", "2", "M", "M");
  localparam logic [31:0] CORE_VERSION = 32'h1109_2026;
  // CAPS: [7:0] maximum burst beats, [15:8] bytes per beat, [23:16] address width.
  localparam logic [31:0] CORE_CAPS    = {8'd0, 8'(ADDR_W), 8'(BEAT_BYTES), 8'(MAX_BURST_BEATS)};

  logic        cnt_clear;
  logic        wr_status;
  logic        cfg_err;
  logic        axi_err;
  logic        line_err;
  logic [31:0] cnt_ok;
  logic [31:0] cnt_bad;
  logic [31:0] cnt_drop;
  logic [31:0] cnt_burst;
  logic [31:0] cnt_beat;
  logic [31:0] last_base_q;
  logic [31:0] status_word;

  assign cnt_clear = reg_wr_en && (reg_wr_addr == REG_CTRL) && reg_wr_data[CTRL_CNT_CLEAR_BIT];
  assign wr_status = reg_wr_en && (reg_wr_addr == REG_STATUS);

  // Configuration.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      enable <= 1'b1;
      stride <= '0;
    end else begin
      if (reg_wr_en && (reg_wr_addr == REG_CTRL))   enable <= reg_wr_data[CTRL_ENABLE_BIT];
      if (reg_wr_en && (reg_wr_addr == REG_STRIDE)) stride <= reg_wr_data;
    end
  end

  // Sticky error flags: a new error wins over a clear in the same clock.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cfg_err  <= 1'b0;
      axi_err  <= 1'b0;
      line_err <= 1'b0;
    end else begin
      if (ev_cfg_err)                                     cfg_err  <= 1'b1;
      else if (wr_status && reg_wr_data[ST_CFG_ERR_BIT])  cfg_err  <= 1'b0;
      if (ev_axi_err)                                     axi_err  <= 1'b1;
      else if (wr_status && reg_wr_data[ST_AXI_ERR_BIT])  axi_err  <= 1'b0;
      if (ev_line_err)                                    line_err <= 1'b1;
      else if (wr_status && reg_wr_data[ST_LINE_ERR_BIT]) line_err <= 1'b0;
    end
  end

  // Counters: wrap at 32 bits, cleared by CTRL.CNT_CLEAR.
  always_ff @(posedge clk) begin
    if (!resetn || cnt_clear) begin
      cnt_ok      <= '0;
      cnt_bad     <= '0;
      cnt_drop    <= '0;
      cnt_burst   <= '0;
      cnt_beat    <= '0;
      last_base_q <= '0;
    end else begin
      if (ev_frame_ok)    cnt_ok    <= cnt_ok + 32'd1;
      if (ev_frame_bad)   cnt_bad   <= cnt_bad + 32'd1;
      if (ev_frame_drop)  cnt_drop  <= cnt_drop + 32'd1;
      if (ev_burst)       cnt_burst <= cnt_burst + 32'd1;
      if (ev_beat)        cnt_beat  <= cnt_beat + 32'd1;
      if (ev_frame_start) last_base_q <= 32'(frame_base);
    end
  end

  always_comb begin
    status_word                  = '0;
    status_word[ST_BUSY_BIT]     = st_busy;
    status_word[ST_CFG_ERR_BIT]  = cfg_err;
    status_word[ST_AXI_ERR_BIT]  = axi_err;
    status_word[ST_LINE_ERR_BIT] = line_err;
  end

  // Registered read mux: data the clock after reg_rd_en.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:             reg_rd_data <= CORE_ID;
        REG_VERSION:        reg_rd_data <= CORE_VERSION;
        REG_CAPS:           reg_rd_data <= CORE_CAPS;
        REG_CTRL:           reg_rd_data <= {31'd0, enable};
        REG_STATUS:         reg_rd_data <= status_word;
        REG_STRIDE:         reg_rd_data <= stride;
        REG_FRAMES_OK:      reg_rd_data <= cnt_ok;
        REG_FRAMES_BAD:     reg_rd_data <= cnt_bad;
        REG_FRAMES_DROPPED: reg_rd_data <= cnt_drop;
        REG_BURSTS:         reg_rd_data <= cnt_burst;
        REG_BEATS:          reg_rd_data <= cnt_beat;
        REG_LAST_BASE:      reg_rd_data <= last_base_q;
        default:            reg_rd_data <= '0;
      endcase
    end
  end

endmodule
