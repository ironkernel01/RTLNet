// -----------------------------------------------------------------------------
// File: rtlnet_framebuf_regs.sv
// Purpose: register file of rtlnet_framebuf: ID/VERSION/CAPS header, CTRL (firmware take and release commands, counter
//   clear), STATUS, the geometry, the latest-frame and firmware-held-frame descriptions, the counters and the per-slot
//   reference counts.
// Overview:
//   * Strobe interface of rtlnet_axil_slave: a write strobe carries a full 32-bit word; a read strobe is answered with a
//     registered read mux, data valid the clock after reg_rd_en. Undefined offsets read 0; writes to them are ignored.
//   * CTRL bits are commands: FW_TAKE and FW_RELEASE become one-clock pulses to the slot manager, CNT_CLEAR clears the
//     counters (self-clearing; an event in the clock of a clear is dropped). CTRL reads 0.
//   * STATUS.FW_ERR is sticky (set by the slot manager when a firmware take finds nothing published or a slot already
//     held, or a release finds none held) and clears by writing 1; a new error in the clock of a clear keeps it set.
//   * Offsets are defined in driver/rtlnet_framebuf.h and mirrored here.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk (all logic).
// -----------------------------------------------------------------------------
module rtlnet_framebuf_regs #(
  parameter int          N          = 3,
  parameter int          NUM_RD     = 1,
  parameter int          SLOT_LOG2  = 22,
  parameter int          ADDR_W     = 29,
  parameter logic [31:0] FB_BASE    = 32'h1000_0000
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

  // Commands to the slot manager, one-clock pulses.
  output logic              fw_take,
  output logic              fw_release,

  // Status and events from the slot manager.
  input  logic              latest_valid,
  input  logic              fw_holds,
  input  logic              writing,
  input  logic [7:0]        latest_slot,
  input  logic [7:0]        fw_slot,
  input  logic [7:0]        wr_slot,
  input  logic              ev_fw_err,
  input  logic              ev_published,
  input  logic              ev_dropped,
  input  logic              ev_bad,
  input  logic              ev_fw_take_ok,
  input  logic [N*8-1:0]    refcnt_flat,

  // Frame descriptions: latest published, and held by the firmware.
  input  logic [31:0]       latest_base,
  input  logic [31:0]       latest_frame,
  input  logic [31:0]       latest_ts,
  input  logic [15:0]       latest_w,
  input  logic [15:0]       latest_h,
  input  logic              latest_src,
  input  logic [31:0]       fw_base,
  input  logic [31:0]       fw_frame,
  input  logic [31:0]       fw_ts,
  input  logic [15:0]       fw_w,
  input  logic [15:0]       fw_h,
  input  logic              fw_src
);

  // Register map: mirrors cores/rtlnet_framebuf/driver/rtlnet_framebuf.h.
  localparam logic [11:0] REG_ID           = 12'h000;
  localparam logic [11:0] REG_VERSION      = 12'h004;
  localparam logic [11:0] REG_CAPS         = 12'h008;
  localparam logic [11:0] REG_CTRL         = 12'h00C;
  localparam logic [11:0] REG_STATUS       = 12'h010;
  localparam logic [11:0] REG_FB_BASE      = 12'h014;
  localparam logic [11:0] REG_SLOT_BYTES   = 12'h018;
  localparam logic [11:0] REG_LATEST_BASE  = 12'h020;
  localparam logic [11:0] REG_LATEST_FRAME = 12'h024;
  localparam logic [11:0] REG_LATEST_TS    = 12'h028;
  localparam logic [11:0] REG_LATEST_WH    = 12'h02C;
  localparam logic [11:0] REG_LATEST_SRC   = 12'h030;
  localparam logic [11:0] REG_FW_BASE      = 12'h040;
  localparam logic [11:0] REG_FW_FRAME     = 12'h044;
  localparam logic [11:0] REG_FW_TS        = 12'h048;
  localparam logic [11:0] REG_FW_WH        = 12'h04C;
  localparam logic [11:0] REG_FW_SRC       = 12'h050;
  localparam logic [11:0] REG_PUBLISHED    = 12'h060;
  localparam logic [11:0] REG_DROPPED      = 12'h064;
  localparam logic [11:0] REG_BAD          = 12'h068;
  localparam logic [11:0] REG_FW_TAKES     = 12'h06C;
  localparam logic [11:0] REG_REFCNT       = 12'h080;   // + 4 * slot

  localparam int CTRL_FW_TAKE_BIT    = 0;
  localparam int CTRL_FW_RELEASE_BIT = 1;
  localparam int CTRL_CNT_CLEAR_BIT  = 16;
  localparam int ST_LATEST_VALID_BIT = 0;
  localparam int ST_FW_HOLDS_BIT     = 1;
  localparam int ST_WRITING_BIT      = 2;
  localparam int ST_FW_ERR_BIT       = 3;

  import rtlnet_pkg::*;

  localparam logic [31:0] CORE_ID      = id4("F", "B", "U", "F");
  localparam logic [31:0] CORE_VERSION = 32'h1109_2026;
  // CAPS: [3:0] slots, [7:4] reader ports, [15:8] log2 of the slot size, [23:16] DDR3 address width.
  localparam logic [31:0] CORE_CAPS    = {8'd0, 8'(ADDR_W), 8'(SLOT_LOG2), 4'(NUM_RD), 4'(N)};

  logic        wr_ctrl;
  logic        cnt_clear;
  logic        fw_err;
  logic [31:0] cnt_pub;
  logic [31:0] cnt_drop;
  logic [31:0] cnt_bad;
  logic [31:0] cnt_take;
  logic [31:0] status_word;
  logic [31:0] ref_word;

  assign wr_ctrl    = reg_wr_en && (reg_wr_addr == REG_CTRL);
  assign cnt_clear  = wr_ctrl && reg_wr_data[CTRL_CNT_CLEAR_BIT];

  // Command pulses.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      fw_take    <= 1'b0;
      fw_release <= 1'b0;
    end else begin
      fw_take    <= wr_ctrl && reg_wr_data[CTRL_FW_TAKE_BIT];
      fw_release <= wr_ctrl && reg_wr_data[CTRL_FW_RELEASE_BIT];
    end
  end

  // Sticky firmware error flag: a new error wins over a clear in the same clock.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      fw_err <= 1'b0;
    end else if (ev_fw_err) begin
      fw_err <= 1'b1;
    end else if (reg_wr_en && (reg_wr_addr == REG_STATUS) && reg_wr_data[ST_FW_ERR_BIT]) begin
      fw_err <= 1'b0;
    end
  end

  // Counters: wrap at 32 bits, cleared by CTRL.CNT_CLEAR.
  always_ff @(posedge clk) begin
    if (!resetn || cnt_clear) begin
      cnt_pub  <= '0;
      cnt_drop <= '0;
      cnt_bad  <= '0;
      cnt_take <= '0;
    end else begin
      if (ev_published)   cnt_pub  <= cnt_pub + 32'd1;
      if (ev_dropped)     cnt_drop <= cnt_drop + 32'd1;
      if (ev_bad)         cnt_bad  <= cnt_bad + 32'd1;
      if (ev_fw_take_ok)  cnt_take <= cnt_take + 32'd1;
    end
  end

  always_comb begin
    status_word                     = '0;
    status_word[ST_LATEST_VALID_BIT] = latest_valid;
    status_word[ST_FW_HOLDS_BIT]     = fw_holds;
    status_word[ST_WRITING_BIT]      = writing;
    status_word[ST_FW_ERR_BIT]       = fw_err;
    status_word[15:8]                = latest_slot;
    status_word[23:16]               = fw_slot;
    status_word[31:24]               = wr_slot;
  end

  // Reference count of the slot being read (offsets REG_REFCNT + 4 * slot); 0 beyond N slots.
  always_comb begin
    ref_word = '0;
    for (int i = 0; i < N; i++) begin
      if (reg_rd_addr == (REG_REFCNT + 12'(4 * i))) ref_word = 32'(refcnt_flat[i*8 +: 8]);
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
        REG_CTRL:         reg_rd_data <= '0;
        REG_STATUS:       reg_rd_data <= status_word;
        REG_FB_BASE:      reg_rd_data <= FB_BASE;
        REG_SLOT_BYTES:   reg_rd_data <= 32'd1 << SLOT_LOG2;
        REG_LATEST_BASE:  reg_rd_data <= latest_base;
        REG_LATEST_FRAME: reg_rd_data <= latest_frame;
        REG_LATEST_TS:    reg_rd_data <= latest_ts;
        REG_LATEST_WH:    reg_rd_data <= {latest_h, latest_w};
        REG_LATEST_SRC:   reg_rd_data <= {31'd0, latest_src};
        REG_FW_BASE:      reg_rd_data <= fw_base;
        REG_FW_FRAME:     reg_rd_data <= fw_frame;
        REG_FW_TS:        reg_rd_data <= fw_ts;
        REG_FW_WH:        reg_rd_data <= {fw_h, fw_w};
        REG_FW_SRC:       reg_rd_data <= {31'd0, fw_src};
        REG_PUBLISHED:    reg_rd_data <= cnt_pub;
        REG_DROPPED:      reg_rd_data <= cnt_drop;
        REG_BAD:          reg_rd_data <= cnt_bad;
        REG_FW_TAKES:     reg_rd_data <= cnt_take;
        default:          reg_rd_data <= ref_word;
      endcase
    end
  end

endmodule
