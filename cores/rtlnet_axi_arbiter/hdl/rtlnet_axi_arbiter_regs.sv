// -----------------------------------------------------------------------------
// File: rtlnet_axi_arbiter_regs.sv
// Purpose: register file of rtlnet_axi_arbiter: ID/VERSION/CAPS header, CTRL,
//   STATUS with the sticky error flag, and the per-master traffic counters.
// Overview:
//   * Strobe interface of rtlnet_axil_slave: a write strobe carries a full
//     32-bit word; a read strobe is answered with a registered read mux, data
//     valid the clock after reg_rd_en. Undefined offsets read 0; writes to them
//     are ignored.
//   * Counters are 32-bit, wrap, reset to 0 and clear on CTRL.CNT_CLEAR
//     (self-clearing). A counter event in the clock of a clear is dropped.
//   * STATUS.ERR is set by any ev_err_wr or ev_err_rd pulse and cleared by writing 1 to it; a
//     new error in the clock of the clear keeps the flag set. err_irq is that
//     flag, a flop output.
//   * Offsets are defined in driver/rtlnet_axi_arbiter.h and mirrored here.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
//   * 11-09-2026: read-only NARROW register (offset 0x014) reports NARROW_MASK.
// Clocks: clk (all logic).
// -----------------------------------------------------------------------------
module rtlnet_axi_arbiter_regs #(
  parameter int                       NUM_MASTERS     = 3,
  parameter int                       DATA_W          = 128,
  parameter int                       ID_W            = 4,
  parameter int                       MAX_OUTSTANDING = 8,
  parameter logic [NUM_MASTERS-1:0]   HIGH_PRIO_MASK  = 'b1,
  parameter logic [NUM_MASTERS-1:0]   NARROW_MASK     = '0
)(
  // Arbiter data clock (the memory controller user clock) and its reset
  // (synchronous, active low).
  input  logic                   clk,
  input  logic                   resetn,

  // Register strobes from rtlnet_axil_slave, clk domain: one full-word write
  // per reg_wr_en clock; reg_rd_data is due the clock after reg_rd_en.
  input  logic                   reg_wr_en,
  input  logic [11:0]            reg_wr_addr,
  input  logic [31:0]            reg_wr_data,
  input  logic                   reg_rd_en,
  input  logic [11:0]            reg_rd_addr,
  output logic [31:0]            reg_rd_data,

  // One-clock event pulses from the datapath, clk domain, one bit per master:
  // legal AW or AR granted and forwarded, W beat forwarded, R beat returned from
  // the memory controller, illegal write or read burst answered by the arbiter
  // (both may pulse in one clock), and a clock with awvalid or arvalid high and
  // not granted.
  input  logic [NUM_MASTERS-1:0] ev_aw_burst,
  input  logic [NUM_MASTERS-1:0] ev_ar_burst,
  input  logic [NUM_MASTERS-1:0] ev_w_beat,
  input  logic [NUM_MASTERS-1:0] ev_r_beat,
  input  logic [NUM_MASTERS-1:0] ev_err_wr,
  input  logic [NUM_MASTERS-1:0] ev_err_rd,
  input  logic [NUM_MASTERS-1:0] ev_wait,

  // Direction status, clk domain: a write (read) is accepted and its response
  // is not yet delivered.
  input  logic                   wr_busy,
  input  logic                   rd_busy,

  // Error interrupt, clk domain: level, high while STATUS.ERR is set.
  output logic                   err_irq
);

  import rtlnet_pkg::*;

  // ---------------------------------------------------------------------------
  // Register map: mirrors cores/rtlnet_axi_arbiter/driver/rtlnet_axi_arbiter.h.
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID      = 12'h000;
  localparam logic [11:0] REG_VERSION = 12'h004;
  localparam logic [11:0] REG_CAPS    = 12'h008;
  localparam logic [11:0] REG_CTRL    = 12'h00C;
  localparam logic [11:0] REG_STATUS  = 12'h010;
  localparam logic [11:0] REG_NARROW   = 12'h014;  // read-only: NARROW_MASK in [7:0]

  localparam int CTRL_CNT_CLEAR_BIT = 16;
  localparam int STATUS_ERR_BIT     = 0;
  localparam int STATUS_WR_BUSY_BIT = 1;
  localparam int STATUS_RD_BUSY_BIT = 2;

  // Per-master window: base 0x100, stride 0x20 (address bits [7:5] select the
  // master), counters at the offsets below.
  localparam logic [3:0] MASTER_WINDOW     = 4'h1;
  localparam int         MASTER_SEL_LSB    = 5;
  localparam int         MASTER_SEL_W      = 3;
  localparam logic [4:0] OFF_AW_BURSTS     = 5'h00;
  localparam logic [4:0] OFF_AR_BURSTS     = 5'h04;
  localparam logic [4:0] OFF_W_BEATS       = 5'h08;
  localparam logic [4:0] OFF_R_BEATS       = 5'h0C;
  localparam logic [4:0] OFF_ERRORS        = 5'h10;
  localparam logic [4:0] OFF_WAIT_CYCLES   = 5'h14;

  localparam logic [31:0] CORE_ID      = id4("A", "R", "B", "T");
  localparam logic [31:0] CORE_VERSION = 32'h1109_2026;
  localparam int          CAPS_BYTES_W = 8;
  localparam int          CAPS_MAX_W   = 8;
  localparam int          CAPS_MASK_W  = 8;
  // CAPS: [3:0] NUM_MASTERS, [11:4] DATA_W/8, [15:12] ID_W, [23:16] MAX_OUTSTANDING,
  // [31:24] HIGH_PRIO_MASK.
  localparam logic [31:0] CORE_CAPS =
      {CAPS_MASK_W'(HIGH_PRIO_MASK), CAPS_MAX_W'(MAX_OUTSTANDING), 4'(ID_W), CAPS_BYTES_W'(DATA_W / 8),
       4'(NUM_MASTERS)};

  // NARROW register: [7:0] NARROW_MASK (masters that may issue narrow transfers).
  localparam logic [31:0] CORE_NARROW = 32'(NARROW_MASK);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic        cnt_clear;
  logic        status_err;
  logic        err_clear;
  logic [31:0] status_word;
  logic [31:0] cnt_aw    [NUM_MASTERS];
  logic [31:0] cnt_ar    [NUM_MASTERS];
  logic [31:0] cnt_w     [NUM_MASTERS];
  logic [31:0] cnt_r     [NUM_MASTERS];
  logic [31:0] cnt_err   [NUM_MASTERS];
  logic [31:0] cnt_wait  [NUM_MASTERS];

  logic [MASTER_SEL_W-1:0] rd_master;
  logic [31:0]             master_word;

  assign cnt_clear = reg_wr_en && (reg_wr_addr == REG_CTRL) && reg_wr_data[CTRL_CNT_CLEAR_BIT];
  assign err_clear = reg_wr_en && (reg_wr_addr == REG_STATUS) && reg_wr_data[STATUS_ERR_BIT];
  assign err_irq   = status_err;
  assign rd_master = reg_rd_addr[MASTER_SEL_LSB +: MASTER_SEL_W];

  always_comb begin
    status_word                     = '0;
    status_word[STATUS_ERR_BIT]     = status_err;
    status_word[STATUS_WR_BUSY_BIT] = wr_busy;
    status_word[STATUS_RD_BUSY_BIT] = rd_busy;
  end

  // Sticky error flag: set by any illegal burst, cleared by writing 1; a new
  // error wins over a clear in the same clock.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      status_err <= 1'b0;
    end else if ((|ev_err_wr) || (|ev_err_rd)) begin
      status_err <= 1'b1;
    end else if (err_clear) begin
      status_err <= 1'b0;
    end
  end

  // Per-master counters: wrap at 32 bits, cleared by CTRL.CNT_CLEAR.
  always_ff @(posedge clk) begin
    for (int i = 0; i < NUM_MASTERS; i++) begin
      if (!resetn || cnt_clear) begin
        cnt_aw[i]   <= '0;
        cnt_ar[i]   <= '0;
        cnt_w[i]    <= '0;
        cnt_r[i]    <= '0;
        cnt_err[i]  <= '0;
        cnt_wait[i] <= '0;
      end else begin
        if (ev_aw_burst[i]) cnt_aw[i]   <= cnt_aw[i] + 32'd1;
        if (ev_ar_burst[i]) cnt_ar[i]   <= cnt_ar[i] + 32'd1;
        if (ev_w_beat[i])   cnt_w[i]    <= cnt_w[i] + 32'd1;
        if (ev_r_beat[i])   cnt_r[i]    <= cnt_r[i] + 32'd1;
        if (ev_err_wr[i] || ev_err_rd[i]) begin
          cnt_err[i] <= cnt_err[i] + {31'd0, ev_err_wr[i]} + {31'd0, ev_err_rd[i]};
        end
        if (ev_wait[i])     cnt_wait[i] <= cnt_wait[i] + 32'd1;
      end
    end
  end

  // Selected master's counter for the offset being read; 0 for an undefined
  // offset or a master index at or above NUM_MASTERS.
  always_comb begin
    master_word = '0;
    for (int i = 0; i < NUM_MASTERS; i++) begin
      if (rd_master == MASTER_SEL_W'(i)) begin
        case (reg_rd_addr[4:0])
          OFF_AW_BURSTS:   master_word = cnt_aw[i];
          OFF_AR_BURSTS:   master_word = cnt_ar[i];
          OFF_W_BEATS:     master_word = cnt_w[i];
          OFF_R_BEATS:     master_word = cnt_r[i];
          OFF_ERRORS:      master_word = cnt_err[i];
          OFF_WAIT_CYCLES: master_word = cnt_wait[i];
          default:         master_word = '0;
        endcase
      end
    end
  end

  // Registered read mux: data the clock after reg_rd_en.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      reg_rd_data <= '0;
      if (reg_rd_addr[11:8] == MASTER_WINDOW) begin
        reg_rd_data <= master_word;
      end else begin
        case (reg_rd_addr)
          REG_ID:      reg_rd_data <= CORE_ID;
          REG_VERSION: reg_rd_data <= CORE_VERSION;
          REG_CAPS:    reg_rd_data <= CORE_CAPS;
          REG_CTRL:    reg_rd_data <= '0;
          REG_STATUS:  reg_rd_data <= status_word;
          REG_NARROW:  reg_rd_data <= CORE_NARROW;
          default:     reg_rd_data <= '0;
        endcase
      end
    end
  end

endmodule
