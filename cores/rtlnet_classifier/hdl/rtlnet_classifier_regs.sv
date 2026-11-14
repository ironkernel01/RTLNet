// -----------------------------------------------------------------------------
// File: rtlnet_classifier_regs.sv
// Purpose: register file of rtlnet_classifier: the AXI4-Lite crossing into
//   axis_clk, the control registers, the configuration write bus to the
//   table and rule memories, the clear sequence, and the read path.
// Overview:
//   * s_axi (s_axi_aclk) -> rtlnet_axil_cdc u_axil_cdc -> rtlnet_axil_slave
//     u_axil_slave (axis_clk) -> this register file, so every register and
//     memory lives in axis_clk and no counter needs its own crossing.
//   * Register offsets and bits mirror cores/rtlnet_classifier/driver/
//     rtlnet_classifier.h (localparams in rtlnet_classifier_pkg). Undefined
//     offsets read 0 and ignore writes; pulse bits read 0.
//   * Writes: the slave strobe is registered (W1). Control registers load
//     from W1. Writes to 0x400..0xFFF go out on the configuration write bus
//     (cw_*, registered); each engine decodes its own words. The same
//     writes, when they hit a defined entry word, are stored in the
//     readback mirror (u_mirror_ram, 1024 x 32, rtlnet_ram_core
//     READ_LATENCY 2), so table, tuple and rule words read back as written.
//   * Clear sequence (after reset and on CTRL.CLEAR_TABLES): MODE = DROP_ALL,
//     every table/rule mode, policer control, limit and window = 0, then
//     1024 clocks writing zero to every engine memory word and every mirror
//     word (clr_active / clr_addr); STATUS.CLEARING is set meanwhile and
//     entry writes are ignored. A zero entry is invalid (VALID = 0) and a
//     zero rule byte is don't-care.
//   * Reads: the slave takes reg_rd_data three clocks after latching the
//     read address that rtlnet_axil_cdc holds on its AR channel; the read
//     path runs freely from that held address: R0 and R1 four-to-one muxes
//     (one LUT level each), R2 group select (two LUT levels), and one LUT
//     selecting the mirror output (whose READ_LATENCY 2 read runs from
//     reg_rd_addr). No read has a side effect.
//   * Writes are pre-decoded (address block, word, entry-word class) into
//     registers alongside W1, so every enable is one LUT from flops.
//   * Policer restart: a write to a policer's CTRL, LIMIT_PKTS or
//     WINDOW_MS pulses cfg_pol_restart for that policer.
// Language: SystemVerilog-2012.
// Revision: 11-14-2026
//   * 10-22-2026: initial version.
//   * 11-14-2026: CAPS bit 27 reports RAM_STYLE "distributed" (0 for "block": earlier CAPS values unchanged).
// Clocks: s_axi_aclk (AXI4-Lite slave side of u_axil_cdc), clk (axis_clk:
//   everything else). Both resets synchronous to their clocks, active low,
//   asserted together.
// -----------------------------------------------------------------------------
module rtlnet_classifier_regs #(
  parameter int    TABLE_ENTRIES     = 16,
  parameter int    TUPLE_ENTRIES     = 16,
  parameter int    NUM_RULES         = 2,
  parameter int    NUM_POLICERS      = 4,
  parameter int    TABLE_LANES       = 2,
  parameter int    MATCH_DEPTH_BYTES = 64,
  parameter int    STRIDE_WORDS      = 64,     // rule stride in 32-bit words
  parameter int    DELAY_BEATS       = 30,
  parameter int    VERDICT_LATENCY   = 22,
  parameter string RAM_STYLE         = "block"
)(
  // AXI4-Lite slave, s_axi_aclk domain, 4 KiB window.
  input  logic                                    s_axi_aclk,
  input  logic                                    s_axi_aresetn,
  input  logic [11:0]                             s_axi_awaddr,
  input  logic                                    s_axi_awvalid,
  output logic                                    s_axi_awready,
  input  logic [31:0]                             s_axi_wdata,
  input  logic [3:0]                              s_axi_wstrb,
  input  logic                                    s_axi_wvalid,
  output logic                                    s_axi_wready,
  output logic [1:0]                              s_axi_bresp,
  output logic                                    s_axi_bvalid,
  input  logic                                    s_axi_bready,
  input  logic [11:0]                             s_axi_araddr,
  input  logic                                    s_axi_arvalid,
  output logic                                    s_axi_arready,
  output logic [31:0]                             s_axi_rdata,
  output logic [1:0]                              s_axi_rresp,
  output logic                                    s_axi_rvalid,
  input  logic                                    s_axi_rready,

  // Register-file clock (axis_clk) and its synchronous active-low reset.
  input  logic                                    clk,
  input  logic                                    resetn,

  // Configuration, registered.
  output logic [1:0]                              cfg_mode,
  output logic [5:0][7:0]                         cfg_table_mode,
  output logic [NUM_RULES-1:0][7:0]               cfg_rule_mode,
  output logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0]       cfg_pol_en,
  output logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] cfg_pol_limit,
  output logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] cfg_pol_window,
  output logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0]       cfg_pol_restart,
  output logic                                    cnt_clear,

  // Configuration write bus to the engine memories, registered: word
  // address = byte offset [11:2]; clear sequence.
  output logic                                    cw_en,
  output logic [9:0]                              cw_addr,
  output logic [31:0]                             cw_data,
  output logic                                    clr_active,
  output logic [9:0]                              clr_addr,

  // Status and counters from the engines.
  input  logic [rtlnet_classifier_pkg::NUM_COUNTERS-1:0][31:0] cnt,
  input  logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] pol_seen,
  input  logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] pol_passed,
  input  logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] pol_dropped,
  input  logic [rtlnet_classifier_pkg::MAX_POLICERS-1:0][31:0] pol_budget,
  input  logic                                    stall_event
);

  import rtlnet_classifier_pkg::*;

  localparam int R       = NUM_RULES;
  localparam int P       = MAX_POLICERS;
  localparam int SB      = rtlnet_pkg::clog2i(STRIDE_WORDS);
  localparam logic [9:0] CLR_LAST = 10'h3FF;
  localparam logic [31:0] CAPS_VALUE =
      (32'(TABLE_ENTRIES)          << CAPS_TABLE_ENTRIES_LSB) |
      (32'(TUPLE_ENTRIES)          << CAPS_TUPLE_ENTRIES_LSB) |
      (32'(NUM_RULES)              << CAPS_NUM_RULES_LSB)     |
      (32'(NUM_POLICERS)           << CAPS_NUM_POLICERS_LSB)  |
      (32'(TABLE_LANES)            << CAPS_TABLE_LANES_LSB)   |
      (32'(MATCH_DEPTH_BYTES / 8)  << CAPS_MATCH_BEATS_LSB)   |
      (32'(RAM_STYLE == "distributed") << CAPS_RAM_DIST_BIT);
  localparam logic [31:0] LATENCY_VALUE =
      (32'(DELAY_BEATS)     << LAT_DELAY_BEATS_LSB) |
      (32'(VERDICT_LATENCY) << LAT_VERDICT_LATENCY_LSB);
  localparam logic [7:0] TABLE_MODE_MASK = 8'h9F;     // bits 7, 4, 3:2, 1, 0
  localparam logic [7:0] RULE_MODE_MASK  = 8'h3F;     // bits 5:4, 3, 2, 1, 0

  // ---------------------------------------------------------------------------
  // AXI4-Lite crossing and slave.
  // ---------------------------------------------------------------------------
  logic [11:0] m_awaddr;
  logic        m_awvalid;
  logic        m_awready;
  logic [31:0] m_wdata;
  logic [3:0]  m_wstrb;
  logic        m_wvalid;
  logic        m_wready;
  logic [1:0]  m_bresp;
  logic        m_bvalid;
  logic        m_bready;
  logic [11:0] m_araddr;
  logic        m_arvalid;
  logic        m_arready;
  logic [31:0] m_rdata;
  logic [1:0]  m_rresp;
  logic        m_rvalid;
  logic        m_rready;

  logic        reg_wr_en;
  logic [11:0] reg_wr_addr;
  logic [31:0] reg_wr_data;
  logic        reg_rd_en;
  logic [11:0] reg_rd_addr;
  logic [31:0] reg_rd_data;

  // Transactions cross from s_axi_aclk to axis_clk as held bundles.
  rtlnet_axil_cdc #(
    .ADDR_W (12)
  ) u_axil_cdc (
    .s_clk         (s_axi_aclk),
    .s_resetn      (s_axi_aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .m_clk         (clk),
    .m_resetn      (resetn),
    .m_axi_awaddr  (m_awaddr),
    .m_axi_awvalid (m_awvalid),
    .m_axi_awready (m_awready),
    .m_axi_wdata   (m_wdata),
    .m_axi_wstrb   (m_wstrb),
    .m_axi_wvalid  (m_wvalid),
    .m_axi_wready  (m_wready),
    .m_axi_bresp   (m_bresp),
    .m_axi_bvalid  (m_bvalid),
    .m_axi_bready  (m_bready),
    .m_axi_araddr  (m_araddr),
    .m_axi_arvalid (m_arvalid),
    .m_axi_arready (m_arready),
    .m_axi_rdata   (m_rdata),
    .m_axi_rresp   (m_rresp),
    .m_axi_rvalid  (m_rvalid),
    .m_axi_rready  (m_rready)
  );

  // AXI4-Lite to register strobes in axis_clk (full-word writes only).
  rtlnet_axil_slave #(
    .ADDR_W (12)
  ) u_axil_slave (
    .s_axi_aclk    (clk),
    .s_axi_aresetn (resetn),
    .s_axi_awaddr  (m_awaddr),
    .s_axi_awvalid (m_awvalid),
    .s_axi_awready (m_awready),
    .s_axi_wdata   (m_wdata),
    .s_axi_wstrb   (m_wstrb),
    .s_axi_wvalid  (m_wvalid),
    .s_axi_wready  (m_wready),
    .s_axi_bresp   (m_bresp),
    .s_axi_bvalid  (m_bvalid),
    .s_axi_bready  (m_bready),
    .s_axi_araddr  (m_araddr),
    .s_axi_arvalid (m_arvalid),
    .s_axi_arready (m_arready),
    .s_axi_rdata   (m_rdata),
    .s_axi_rresp   (m_rresp),
    .s_axi_rvalid  (m_rvalid),
    .s_axi_rready  (m_rready),
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data)
  );

  // ---------------------------------------------------------------------------
  // W1: registered write strobe.
  // ---------------------------------------------------------------------------
  logic        w1_en;
  logic [11:0] w1_addr;
  logic [31:0] w1_data;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      w1_en   <= 1'b0;
      w1_addr <= '0;
      w1_data <= '0;
    end else begin
      w1_en   <= reg_wr_en;
      w1_addr <= reg_wr_addr;
      w1_data <= reg_wr_data;
    end
  end

  // Decoded W1 targets.
  logic       wr_ctrl;
  logic [5:0] wr_tmode;
  logic [R-1:0] wr_rmode;
  logic [P-1:0] wr_pctrl;
  logic [P-1:0] wr_plimit;
  logic [P-1:0] wr_pwin;
  logic       clear_req;

  // Pre-decode of the slave strobe, registered alongside W1: the address
  // block (byte offset [11:6], qualified by the strobe) and the word in the
  // block ([5:2]). Each W1 target is then the AND of one bit of each.
  logic [7:0]  pd_blk;            // block 0x000, 0x040, .., 0x1C0 written
  logic [15:0] pd_word;           // word index 0..15 in the block
  logic        pd_df;             // defined field-table entry word
  logic        pd_dt;             // defined tuple entry word
  logic        pd_dr;             // defined rule byte

  always_ff @(posedge clk) begin
    if (!resetn) begin
      pd_blk  <= '0;
      pd_word <= '0;
      pd_df   <= 1'b0;
      pd_dt   <= 1'b0;
      pd_dr   <= 1'b0;
    end else begin
      for (int j = 0; j < 8; j++)  pd_blk[j]  <= reg_wr_en && (reg_wr_addr[11:6] == 6'(j));
      for (int k = 0; k < 16; k++) pd_word[k] <= (reg_wr_addr[5:2] == 4'(k));
      pd_df <= (reg_wr_addr[11:8] >= 4'h4) && (reg_wr_addr[11:8] <= 4'h8) && (reg_wr_addr[7:4] < TABLE_ENTRIES);
      pd_dt <= ((reg_wr_addr[11:8] == 4'h9) || (reg_wr_addr[11:8] == 4'hA)) &&
               ({reg_wr_addr[9], reg_wr_addr[7:5]} < TUPLE_ENTRIES) && (reg_wr_addr[4:2] < TUPLE_WORDS);
      pd_dr <= (reg_wr_addr[11:10] == 2'b11) && ((reg_wr_addr[9:2] >> SB) < R) &&
               ((reg_wr_addr[9:2] & (STRIDE_WORDS - 1)) < MATCH_DEPTH_BYTES);
    end
  end

  // W1 targets (one LUT from the pre-decode registers).
  always_comb begin
    wr_ctrl = pd_blk[0] && pd_word[REG_CTRL[5:2]];
    for (int t = 0; t < 6; t++) wr_tmode[t] = pd_blk[0] && pd_word[8 + t];
    for (int r = 0; r < R; r++) wr_rmode[r] = pd_blk[1] && pd_word[r];
    for (int p = 0; p < P; p++) begin
      wr_pctrl[p]  = (p < NUM_POLICERS) && pd_blk[4 + p / 2] && pd_word[8 * (p % 2) + POL_CTRL];
      wr_plimit[p] = (p < NUM_POLICERS) && pd_blk[4 + p / 2] && pd_word[8 * (p % 2) + POL_LIMIT];
      wr_pwin[p]   = (p < NUM_POLICERS) && pd_blk[4 + p / 2] && pd_word[8 * (p % 2) + POL_WINDOW];
    end
    clear_req = wr_ctrl && w1_data[CTRL_CLEAR_TABLES];
  end

  // ---------------------------------------------------------------------------
  // Clear sequence.
  // ---------------------------------------------------------------------------
  logic       clearing;
  logic [9:0] clr_cnt;
  logic       clr_last;          // clr_cnt is the last word (registered compare)

  // Runs after reset and on CLEAR_TABLES: 1024 clocks of zero writes.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      clearing <= 1'b1;
      clr_cnt  <= '0;
      clr_last <= 1'b0;
    end else if (clear_req) begin
      clearing <= 1'b1;
      clr_cnt  <= '0;
      clr_last <= 1'b0;
    end else if (clearing) begin
      clr_cnt  <= clr_cnt + 1'b1;
      clr_last <= (clr_cnt == CLR_LAST - 10'd1);
      if (clr_last) clearing <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Control registers.
  // ---------------------------------------------------------------------------
  logic stall_seen;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      cfg_mode        <= MODE_DROP_ALL;
      cfg_table_mode  <= '0;
      cfg_rule_mode   <= '0;
      cfg_pol_en      <= '0;
      cfg_pol_limit   <= '0;
      cfg_pol_window  <= '0;
      cfg_pol_restart <= '0;
      cnt_clear       <= 1'b0;
      stall_seen      <= 1'b0;
    end else begin
      cnt_clear       <= wr_ctrl && w1_data[CTRL_CNT_CLEAR];
      cfg_pol_restart <= wr_pctrl | wr_plimit | wr_pwin;
      if (clear_req) begin
        cfg_mode       <= MODE_DROP_ALL;
        cfg_table_mode <= '0;
        cfg_rule_mode  <= '0;
        cfg_pol_en     <= '0;
        cfg_pol_limit  <= '0;
        cfg_pol_window <= '0;
      end else begin
        if (wr_ctrl) cfg_mode <= w1_data[CTRL_MODE_LSB +: 2];
        for (int t = 0; t < 6; t++)
          if (wr_tmode[t]) cfg_table_mode[t] <= w1_data[7:0] & TABLE_MODE_MASK;
        for (int r = 0; r < R; r++)
          if (wr_rmode[r]) cfg_rule_mode[r] <= w1_data[7:0] & RULE_MODE_MASK;
        for (int p = 0; p < P; p++) begin
          if (wr_pctrl[p])  cfg_pol_en[p]     <= w1_data[0];
          if (wr_plimit[p]) cfg_pol_limit[p]  <= w1_data;
          if (wr_pwin[p])   cfg_pol_window[p] <= w1_data;
        end
      end
      if (wr_ctrl && w1_data[CTRL_CNT_CLEAR]) stall_seen <= 1'b0;
      else if (stall_event)                   stall_seen <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Configuration write bus and the readback mirror.
  // ---------------------------------------------------------------------------
  logic        m_we;
  logic [9:0]  m_wa;
  logic [31:0] m_wd;
  logic [31:0] mirror_q;

  // Write bus and mirror write port; the clear sequence owns both while it
  // runs.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cw_en      <= 1'b0;
      cw_addr    <= '0;
      cw_data    <= '0;
      clr_active <= 1'b0;
      clr_addr   <= '0;
      m_we       <= 1'b0;
      m_wa       <= '0;
      m_wd       <= '0;
    end else begin
      cw_en      <= w1_en && !clearing && (w1_addr[11:10] != 2'b00);
      cw_addr    <= w1_addr[11:2];
      cw_data    <= w1_data;
      clr_active <= clearing;
      clr_addr   <= clr_cnt;
      if (clearing) begin
        m_we <= 1'b1;
        m_wa <= clr_cnt;
        m_wd <= '0;
      end else begin
        m_we <= w1_en && (pd_df || pd_dt || pd_dr);
        m_wa <= w1_addr[11:2];
        m_wd <= w1_data;
      end
    end
  end

  // Readback mirror of the entry memories (0x400..0xFFF), read continuously
  // from the slave's held read address.
  rtlnet_ram_core #(
    .RAM_STYLE    (RAM_STYLE),
    .CLOCKING     ("COMMON"),
    .DATA_W       (32),
    .ADDR_W       (10),
    .READ_LATENCY (2)
  ) u_mirror_ram (
    .wr_clk    (clk),
    .wr_en     (m_we),
    .wr_addr   (m_wa),
    .wr_data   (m_wd),
    .rd_clk    (clk),
    .rd_resetn (resetn),
    .rd_en     (1'b1),
    .rd_addr   (reg_rd_addr[11:2]),
    .rd_data   (mirror_q)
  );

  // ---------------------------------------------------------------------------
  // Read path: R0 / R1 four-to-one muxes, R2 group select, mirror select.
  // The read address held by rtlnet_axil_cdc on the slave's AR channel
  // (m_araddr) is valid in the clock before the slave latches it into
  // reg_rd_addr, and stays unchanged until the response; the slave takes
  // reg_rd_data three clocks after that latch, so R0, R1 and R2 run freely
  // from m_araddr.
  // ---------------------------------------------------------------------------
  logic [7:0][15:0][31:0] grp_in;
  logic [7:0][3:0][31:0]  r0_q;
  logic [11:0]            r0_addr;
  logic [7:0][31:0]       r1_grp;
  logic [11:0]            r1_addr;
  logic [31:0]            r2_mux;
  logic                   r2_mirror;

  // Readable words, grouped by address bits [8:6]; index [5:2] in a group.
  always_comb begin
    grp_in = '0;
    // Group 0: 0x000..0x03C.
    grp_in[0][0] = CLS_ID_VALUE;
    grp_in[0][1] = CLS_VERSION_VALUE;
    grp_in[0][2] = CAPS_VALUE;
    grp_in[0][3] = {30'd0, cfg_mode};
    grp_in[0][4] = (32'(clearing)   << STATUS_CLEARING) |
                   (32'(cfg_mode)   << STATUS_MODE_LSB) |
                   (32'(stall_seen) << STATUS_STALL_SEEN);
    grp_in[0][5] = LATENCY_VALUE;
    for (int t = 0; t < 6; t++) grp_in[0][8 + t] = {24'd0, cfg_table_mode[t]};
    // Group 1: 0x040..0x07C rule modes.
    for (int r = 0; r < R; r++) grp_in[1][r] = {24'd0, cfg_rule_mode[r]};
    // Group 2: 0x080..0x0BC counters.
    for (int i = 0; i < NUM_COUNTERS; i++) grp_in[2][i] = cnt[i];
    // Groups 4, 5: 0x100..0x17C policers (8 words each).
    for (int p = 0; p < NUM_POLICERS; p++) begin
      grp_in[4 + p / 2][8 * (p % 2) + POL_CTRL]    = {31'd0, cfg_pol_en[p]};
      grp_in[4 + p / 2][8 * (p % 2) + POL_LIMIT]   = cfg_pol_limit[p];
      grp_in[4 + p / 2][8 * (p % 2) + POL_WINDOW]  = cfg_pol_window[p];
      grp_in[4 + p / 2][8 * (p % 2) + POL_SEEN]    = pol_seen[p];
      grp_in[4 + p / 2][8 * (p % 2) + POL_PASSED]  = pol_passed[p];
      grp_in[4 + p / 2][8 * (p % 2) + POL_DROPPED] = pol_dropped[p];
      grp_in[4 + p / 2][8 * (p % 2) + POL_BUDGET]  = pol_budget[p];
    end
  end

  // R0: word within each quad (address [3:2]); R1: quad within the group
  // ([5:4]); R2: group ([8:6]), zero outside 0x000..0x1FF.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      r0_q      <= '0;
      r0_addr   <= '0;
      r1_grp    <= '0;
      r1_addr   <= '0;
      r2_mux    <= '0;
      r2_mirror <= 1'b0;
    end else begin
      for (int g = 0; g < 8; g++)
        for (int q = 0; q < 4; q++) r0_q[g][q] <= grp_in[g][4 * q + m_araddr[3:2]];
      r0_addr <= m_araddr;
      for (int g = 0; g < 8; g++) r1_grp[g] <= r0_q[g][r0_addr[5:4]];
      r1_addr   <= r0_addr;
      r2_mux    <= (r1_addr[11:9] == 3'b000) ? r1_grp[r1_addr[8:6]] : 32'd0;
      r2_mirror <= (r1_addr[11:10] != 2'b00);
    end
  end

  assign reg_rd_data = r2_mirror ? mirror_q : r2_mux;

endmodule
