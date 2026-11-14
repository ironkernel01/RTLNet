// -----------------------------------------------------------------------------
// File: rtlnet_tcp_offload_regs.sv
// Purpose: register file of rtlnet_tcp_offload: the AXI4-Lite crossing into the
//   stream clock, CTRL, STATUS, CAPS, LATENCY and the event counters.
// Overview:
//   * s_axi (s_axi_aclk) -> rtlnet_axil_cdc u_axil_cdc -> rtlnet_axil_slave
//     u_axil_slave (clk) -> this register file, so every register and counter
//     lives in the stream clock and no counter needs its own crossing.
//   * Offsets and bits mirror cores/rtlnet_tcp_offload/driver/rtlnet_tcp_offload.h
//     (localparams in rtlnet_tcp_offload_pkg). Undefined offsets read 0 and
//     ignore writes.
//   * CTRL (0x00C) reads back exactly as written (bits 2:0; the others read 0).
//     Power-up value 0: both insert paths and the receive trailer off, the core
//     is a pure pass-through. The datapaths sample CTRL at each frame's first beat.
//   * CNT_CLEAR (0x018) is a write-only pulse register: writing bit 0 clears
//     every counter; it reads 0. Counters are 32-bit, wrap, and are read
//     directly (a 32-bit read is one AXI transaction).
//   * Read path: two registered stages (8:1 mux, then 4:1 group mux) from the
//     held read address, data due three clocks after the address is latched.
// Language: SystemVerilog-2012.
//   * Feature registers (appended, present only in a build with ACK_COALESCE or RX_BATCH, otherwise they read 0
//     and ignore writes, so the register file of the first version is unchanged): CTRL bits 3 (ack_coalesce)
//     and 4 (rx_batch), STATUS bits 2 and 3, CAPS bits 6 and 7, CAPS2 (0x01C), the configuration registers
//     0x020..0x030 and the counter blocks 0x080 (ACK) and 0x0A0 (batch). Their read path is a second, parallel
//     8:1 stage for the offsets 0x080..0x0FF.
// Revision: 11-14-2026
//   * 11-14-2026: feature registers (see above).
//   * 10-22-2026: initial version.
// Clocks: s_axi_aclk (AXI4-Lite side of u_axil_cdc), clk (everything else).
//   Both resets synchronous, active low, asserted together.
// -----------------------------------------------------------------------------
module rtlnet_tcp_offload_regs #(
  parameter int TX_BUF_KB         = 8,
  parameter int MAX_FRAME_BYTES   = 1518,
  parameter int ACK_COALESCE      = 0,      // 1: ACK coalescer built (registers, counters)
  parameter int RX_BATCH          = 0,      // 1: receive batcher built
  parameter int ACK_FLOWS         = 4,      // CAPS2: flow table entries
  parameter int BAT_RESERVE_BYTES = 0       // CAPS2: bytes the batch byte limit keeps free for the next frame
)(
  // AXI4-Lite slave, s_axi_aclk domain, 4 KiB window.
  input  logic        s_axi_aclk,
  input  logic        s_axi_aresetn,
  input  logic [11:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [11:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // Register-file clock (the stream clock) and its synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Configuration, registered.
  output logic        cfg_tx_ip,
  output logic        cfg_tx_l4,
  output logic        cfg_rx,
  output logic        cfg_ack_en,
  output logic [15:0] cfg_ack_timer,
  output logic [7:0]  cfg_ack_limit,
  output logic        cfg_bat_en,
  output logic [15:0] cfg_bat_timer,
  output logic [7:0]  cfg_bat_frames,
  output logic [15:0] cfg_bat_bytes,

  // Status and event pulses from the datapaths (clk domain, registered).
  input  logic        tx_idle,
  input  logic        rx_idle,
  input  logic        ack_idle,
  input  logic        bat_idle,
  input  logic [rtlnet_tcp_offload_pkg::NUM_TX_COUNTERS-1:0] tx_ev,
  input  logic [rtlnet_tcp_offload_pkg::NUM_RX_COUNTERS-1:0] rx_ev,
  input  logic [rtlnet_tcp_offload_pkg::NUM_ACK_COUNTERS-1:0] ack_ev,
  input  logic [rtlnet_tcp_offload_pkg::NUM_BAT_COUNTERS-1:0] bat_ev
);

  import rtlnet_tcp_offload_pkg::*;

  localparam int NCNT = NUM_TX_COUNTERS + NUM_RX_COUNTERS;
  localparam bit FEAT = (ACK_COALESCE != 0) || (RX_BATCH != 0);

  localparam logic [31:0] CAPS_VALUE =
      (32'd1 << CAPS_TX_PRESENT) | (32'd1 << CAPS_RX_PRESENT) | (32'd1 << CAPS_INS_IP) |
      (32'd1 << CAPS_INS_TCP) | (32'd1 << CAPS_INS_UDP) | (32'd1 << CAPS_VLAN) |
      (32'(TX_BUF_KB) << CAPS_TX_BUF_LSB) | (32'(MAX_FRAME_BYTES) << CAPS_MAX_FRM_LSB) |
      ((ACK_COALESCE != 0) ? (32'd1 << CAPS_ACK_COAL) : 32'd0) | ((RX_BATCH != 0) ? (32'd1 << CAPS_RX_BATCH) : 32'd0);
  // CAPS2: [7:0] ACK_FLOWS, [23:8] BAT_RESERVE_BYTES (each only when its feature is built).
  localparam logic [31:0] CAPS2_VALUE =
      ((ACK_COALESCE != 0) ? 32'(ACK_FLOWS) : 32'd0) | ((RX_BATCH != 0) ? (32'(BAT_RESERVE_BYTES) << 8) : 32'd0);
  localparam logic [31:0] LATENCY_VALUE = 32'(TX_SB_LAT) | (32'(RX_DELAY) << 8);

  // ---------------------------------------------------------------------------
  // AXI4-Lite crossing and slave
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

  // Transactions cross from s_axi_aclk to clk as held bundles.
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

  // AXI4-Lite to register strobes in clk (full-word writes only).
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
  // CTRL and the counter clear pulse
  // ---------------------------------------------------------------------------
  logic [2:0]  ctrl;
  logic        cnt_clear;
  logic        w0_en;
  logic        w0_hi0;
  logic        w0_ctrl;
  logic        w0_clr;
  logic [31:0] w0_data;
  logic        w1_ctrl;
  logic        w1_clr;
  logic [31:0] w1_data;

  // W0: strobe and the two halves of the address compare; W1: the decoded targets; then the update.
  // Every register enable is one LUT from flops.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      w0_en     <= 1'b0;
      w0_hi0    <= 1'b0;
      w0_ctrl   <= 1'b0;
      w0_clr    <= 1'b0;
      w0_data   <= 32'd0;
      w1_ctrl   <= 1'b0;
      w1_clr    <= 1'b0;
      w1_data   <= 32'd0;
      ctrl      <= 3'b000;
      cnt_clear <= 1'b0;
    end else begin
      w0_en     <= reg_wr_en;
      w0_hi0    <= (reg_wr_addr[11:5] == 7'd0);
      w0_ctrl   <= (reg_wr_addr[4:0] == REG_CTRL[4:0]);
      w0_clr    <= (reg_wr_addr[4:0] == REG_CNT_CLEAR[4:0]);
      w0_data   <= reg_wr_data;
      w1_ctrl   <= w0_en && w0_hi0 && w0_ctrl;
      w1_clr    <= w0_en && w0_hi0 && w0_clr;
      w1_data   <= w0_data;
      cnt_clear <= w1_clr && w1_data[0];
      if (w1_ctrl) ctrl <= w1_data[2:0];
    end
  end

  assign cfg_tx_ip = ctrl[CTRL_TX_IP_CSUM];
  assign cfg_tx_l4 = ctrl[CTRL_TX_L4_CSUM];
  assign cfg_rx    = ctrl[CTRL_RX_CSUM];

  // ---------------------------------------------------------------------------
  // Counters
  // ---------------------------------------------------------------------------
  logic [31:0]     cnt [0:NCNT-1];
  logic [NCNT-1:0] ev;

  assign ev = {rx_ev, tx_ev};

  // ---------------------------------------------------------------------------
  // Feature registers and counters (ACK_COALESCE / RX_BATCH builds only)
  // ---------------------------------------------------------------------------
  logic [1:0]  ctrl_ext;
  logic [15:0] ack_timer_r;
  logic [7:0]  ack_limit_r;
  logic [15:0] bat_timer_r;
  logic [7:0]  bat_frames_r;
  logic [15:0] bat_bytes_r;
  logic [31:0] cnt_ack [0:NUM_ACK_COUNTERS-1];
  logic [31:0] cnt_bat [0:NUM_BAT_COUNTERS-1];

  generate
    if (FEAT) begin : g_feat
      localparam logic [1:0] CTRL_EXT_MASK = {RX_BATCH != 0, ACK_COALESCE != 0};
      logic [11:0] w0_addr;
      logic        w1_ack_t, w1_ack_l, w1_bat_t, w1_bat_f, w1_bat_b;

      // Same two-stage write path as CTRL: strobe and address first, decoded targets next, then the update.
      always_ff @(posedge clk) begin
        if (!resetn) begin
          w0_addr      <= 12'd0;
          w1_ack_t     <= 1'b0;
          w1_ack_l     <= 1'b0;
          w1_bat_t     <= 1'b0;
          w1_bat_f     <= 1'b0;
          w1_bat_b     <= 1'b0;
          ctrl_ext     <= 2'b00;
          ack_timer_r  <= (ACK_COALESCE != 0) ? 16'(ACK_TIMER_DEFAULT_US) : 16'd0;
          ack_limit_r  <= (ACK_COALESCE != 0) ? 8'(ACK_LIMIT_DEFAULT) : 8'd0;
          bat_timer_r  <= (RX_BATCH != 0) ? 16'(BAT_TIMER_DEFAULT_US) : 16'd0;
          bat_frames_r <= (RX_BATCH != 0) ? 8'(BAT_FRAMES_DEFAULT) : 8'd0;
          bat_bytes_r  <= (RX_BATCH != 0) ? 16'(BAT_BYTES_DEFAULT) : 16'd0;
        end else begin
          w0_addr  <= reg_wr_addr;
          w1_ack_t <= w0_en && (w0_addr == REG_ACK_TIMER) && (ACK_COALESCE != 0);
          w1_ack_l <= w0_en && (w0_addr == REG_ACK_LIMIT) && (ACK_COALESCE != 0);
          w1_bat_t <= w0_en && (w0_addr == REG_BAT_TIMER) && (RX_BATCH != 0);
          w1_bat_f <= w0_en && (w0_addr == REG_BAT_FRAMES) && (RX_BATCH != 0);
          w1_bat_b <= w0_en && (w0_addr == REG_BAT_BYTES) && (RX_BATCH != 0);
          if (w1_ctrl)  ctrl_ext     <= w1_data[CTRL_ACK_COAL +: 2] & CTRL_EXT_MASK;
          if (w1_ack_t) ack_timer_r  <= w1_data[15:0];
          if (w1_ack_l) ack_limit_r  <= w1_data[7:0];
          if (w1_bat_t) bat_timer_r  <= w1_data[15:0];
          if (w1_bat_f) bat_frames_r <= w1_data[7:0];
          if (w1_bat_b) bat_bytes_r  <= w1_data[15:0];
        end
      end

      always_ff @(posedge clk) begin
        for (int i = 0; i < NUM_ACK_COUNTERS; i++) begin
          if (!resetn || cnt_clear) cnt_ack[i] <= 32'd0;
          else if (ack_ev[i])       cnt_ack[i] <= cnt_ack[i] + 32'd1;
        end
        for (int i = 0; i < NUM_BAT_COUNTERS; i++) begin
          if (!resetn || cnt_clear) cnt_bat[i] <= 32'd0;
          else if (bat_ev[i])       cnt_bat[i] <= cnt_bat[i] + 32'd1;
        end
      end
    end else begin : g_nofeat
      always_comb begin
        ctrl_ext     = 2'b00;
        ack_timer_r  = 16'd0;
        ack_limit_r  = 8'd0;
        bat_timer_r  = 16'd0;
        bat_frames_r = 8'd0;
        bat_bytes_r  = 16'd0;
        for (int i = 0; i < NUM_ACK_COUNTERS; i++) cnt_ack[i] = 32'd0;
        for (int i = 0; i < NUM_BAT_COUNTERS; i++) cnt_bat[i] = 32'd0;
      end
    end
  endgenerate

  assign cfg_ack_en     = ctrl_ext[0];
  assign cfg_bat_en     = ctrl_ext[1];
  assign cfg_ack_timer  = ack_timer_r;
  assign cfg_ack_limit  = ack_limit_r;
  assign cfg_bat_frames = bat_frames_r;
  assign cfg_bat_timer  = bat_timer_r;
  assign cfg_bat_bytes  = bat_bytes_r;

  always_ff @(posedge clk) begin
    for (int i = 0; i < NCNT; i++) begin
      if (!resetn || cnt_clear) cnt[i] <= 32'd0;
      else if (ev[i])           cnt[i] <= cnt[i] + 32'd1;
    end
  end

  // ---------------------------------------------------------------------------
  // Read path: word index = reg_rd_addr[6:2]; words 0..7 header, 16..21 TX, 24..28 RX
  // ---------------------------------------------------------------------------
  logic [31:0] word [0:31];
  logic [31:0] grp  [0:3];
  logic [1:0]  grp_sel;
  logic        win_q;

  always_comb begin
    for (int i = 0; i < 32; i++) word[i] = 32'd0;
    word[REG_ID >> 2]      = TXO_ID_VALUE;
    word[REG_VERSION >> 2] = TXO_VERSION_VALUE;
    word[REG_CAPS >> 2]    = CAPS_VALUE;
    word[REG_CTRL >> 2]    = {27'd0, ctrl_ext, ctrl};
    word[REG_STATUS >> 2]  = {28'd0, (RX_BATCH != 0) && bat_idle, (ACK_COALESCE != 0) && ack_idle, rx_idle, tx_idle};
    word[REG_CAPS2 >> 2]      = CAPS2_VALUE;
    word[REG_ACK_TIMER >> 2]  = {16'd0, ack_timer_r};
    word[REG_ACK_LIMIT >> 2]  = {24'd0, ack_limit_r};
    word[REG_BAT_TIMER >> 2]  = {16'd0, bat_timer_r};
    word[REG_BAT_FRAMES >> 2] = {24'd0, bat_frames_r};
    word[REG_BAT_BYTES >> 2]  = {16'd0, bat_bytes_r};
    word[REG_LATENCY >> 2] = LATENCY_VALUE;
    for (int i = 0; i < NUM_TX_COUNTERS; i++) word[(REG_CNT_TX >> 2) + i] = cnt[i];
    for (int i = 0; i < NUM_RX_COUNTERS; i++) word[(REG_CNT_RX >> 2) + i] = cnt[NUM_TX_COUNTERS + i];
  end

  generate
    if (!FEAT) begin : g_rd_base
      always_ff @(posedge clk) begin
        for (int g = 0; g < 4; g++) grp[g] <= word[8*g + int'(reg_rd_addr[4:2])];
        grp_sel     <= reg_rd_addr[6:5];
        win_q       <= (reg_rd_addr[11:7] == 5'd0);
        reg_rd_data <= win_q ? grp[grp_sel] : 32'd0;
      end
    end else begin : g_rd_ext
      // Second 128-byte half (0x080..0x0FF): the ACK and batch counters.
      logic [31:0] word_hi [0:31];
      logic [31:0] grp_hi  [0:3];
      logic        hi_q;

      always_comb begin
        for (int i = 0; i < 32; i++) word_hi[i] = 32'd0;
        for (int i = 0; i < NUM_ACK_COUNTERS; i++) word_hi[((REG_CNT_ACK - 12'h080) >> 2) + i] = cnt_ack[i];
        for (int i = 0; i < NUM_BAT_COUNTERS; i++) word_hi[((REG_CNT_BAT - 12'h080) >> 2) + i] = cnt_bat[i];
      end

      always_ff @(posedge clk) begin
        for (int g = 0; g < 4; g++) begin
          grp[g]    <= word[8*g + int'(reg_rd_addr[4:2])];
          grp_hi[g] <= word_hi[8*g + int'(reg_rd_addr[4:2])];
        end
        grp_sel     <= reg_rd_addr[6:5];
        hi_q        <= reg_rd_addr[7];
        win_q       <= (reg_rd_addr[11:8] == 4'd0);
        reg_rd_data <= !win_q ? 32'd0 : (hi_q ? grp_hi[grp_sel] : grp[grp_sel]);
      end
    end
  endgenerate

endmodule
