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
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: s_axi_aclk (AXI4-Lite side of u_axil_cdc), clk (everything else).
//   Both resets synchronous, active low, asserted together.
// -----------------------------------------------------------------------------
module rtlnet_tcp_offload_regs #(
  parameter int TX_BUF_KB       = 4,
  parameter int MAX_FRAME_BYTES = 1518
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

  // Status and event pulses from the datapaths (clk domain, registered).
  input  logic        tx_idle,
  input  logic        rx_idle,
  input  logic [rtlnet_tcp_offload_pkg::NUM_TX_COUNTERS-1:0] tx_ev,
  input  logic [rtlnet_tcp_offload_pkg::NUM_RX_COUNTERS-1:0] rx_ev
);

  import rtlnet_tcp_offload_pkg::*;

  localparam int NCNT = NUM_TX_COUNTERS + NUM_RX_COUNTERS;

  localparam logic [31:0] CAPS_VALUE =
      (32'd1 << CAPS_TX_PRESENT) | (32'd1 << CAPS_RX_PRESENT) | (32'd1 << CAPS_INS_IP) |
      (32'd1 << CAPS_INS_TCP) | (32'd1 << CAPS_INS_UDP) | (32'd1 << CAPS_VLAN) |
      (32'(TX_BUF_KB) << CAPS_TX_BUF_LSB) | (32'(MAX_FRAME_BYTES) << CAPS_MAX_FRM_LSB);
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
    word[REG_CTRL >> 2]    = {29'd0, ctrl};
    word[REG_STATUS >> 2]  = {30'd0, rx_idle, tx_idle};
    word[REG_LATENCY >> 2] = LATENCY_VALUE;
    for (int i = 0; i < NUM_TX_COUNTERS; i++) word[(REG_CNT_TX >> 2) + i] = cnt[i];
    for (int i = 0; i < NUM_RX_COUNTERS; i++) word[(REG_CNT_RX >> 2) + i] = cnt[NUM_TX_COUNTERS + i];
  end

  always_ff @(posedge clk) begin
    for (int g = 0; g < 4; g++) grp[g] <= word[8*g + int'(reg_rd_addr[4:2])];
    grp_sel     <= reg_rd_addr[6:5];
    win_q       <= (reg_rd_addr[11:7] == 5'd0);
    reg_rd_data <= win_q ? grp[grp_sel] : 32'd0;
  end

endmodule
