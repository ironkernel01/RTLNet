// -----------------------------------------------------------------------------
// File: rtlnet_eth_mac_mii.sv
// Purpose: IronKernel RTLNet 10/100 full-duplex Clause 22 MII MAC.
// Overview: reuses the GMII engines, packet FIFOs, guards, slices, registers
//   and CDC primitives of the RGMII top. The separate integration leaves the
//   RGMII hierarchy and sources unchanged. Both pin clocks come from the PHY.
//   CTRL.SPEED remains firmware-selected; RXC measurement qualifies it.
//   Reserved/gigabit speeds hold RX reset and discard queued TX frames.
// Language: SystemVerilog-2012, source-available.
// Revision: 11-14-2026
//   * 11-14-2026: add independent MII integration and client-clock measurement.
// Clocks: axis_clk, s_axi_aclk, mii_rx_clk, mii_tx_clk; no generated clocks.
// -----------------------------------------------------------------------------
module rtlnet_eth_mac_mii #(
  parameter int    RX_FIFO_KB      = 8,                                // RX packet FIFO, kilobytes
  parameter int    TX_FIFO_KB      = 8,                                // TX packet FIFO, kilobytes
  parameter int    MAX_FRAME_BYTES = rtlnet_pkg::ETH_MAX_FRAME_BYTES,  // client frame limit, FCS excluded
  parameter int    AXIS_CLK_HZ     = 62_500_000,                       // client reference rate in Hz
  parameter string RAM_STYLE       = "block"                           // FIFO storage: "block" | "distributed"
)(
  // Independent client and register clocks; no 125 MHz or delay reference clock.
  input  logic        axis_clk,
  input  logic        s_axi_aclk,
  // Active-low client/register resets, released from one board reset assertion.
  input  logic        axis_resetn,
  input  logic        s_axi_aresetn,
  // Clause 22 MII: both clocks are PHY outputs, 25 MHz or 2.5 MHz.
  input  logic        mii_rx_clk,
  input  logic        mii_tx_clk,
  input  logic [3:0]  mii_rxd,
  input  logic        mii_rx_dv,
  input  logic        mii_rx_er,
  output logic [3:0]  mii_txd,
  output logic        mii_tx_en,

  // Received frames, axis_clk domain, RTLNet stream: destination MAC to the
  // last payload/pad byte, byte 0 in tdata[7:0], no preamble/SFD/FCS, whole
  // good frames only.
  output logic [63:0] m_axis_rx_tdata,
  output logic [7:0]  m_axis_rx_tkeep,
  output logic        m_axis_rx_tvalid,
  output logic        m_axis_rx_tlast,
  input  logic        m_axis_rx_tready,

  // Frames to send, axis_clk domain, RTLNet stream, 14..MAX_FRAME_BYTES
  // bytes; the MAC pads to 60 and appends the FCS. tready is a register.
  input  logic [63:0] s_axis_tx_tdata,
  input  logic [7:0]  s_axis_tx_tkeep,
  input  logic        s_axis_tx_tvalid,
  input  logic        s_axis_tx_tlast,
  output logic        s_axis_tx_tready,

  // Register slave, AXI4-Lite, s_axi_aclk domain, 12-bit byte address.
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

  // Status, axis_clk domain, registered: firmware link flag, configured
  // speed (00 10M, 01 100M, 10/11 unsupported), RXC qualified, one-clock frame events
  // (for LEDs).
  output logic        stat_link_up,
  output logic [1:0]  stat_speed,
  output logic        stat_rx_clk_ok,
  output logic        ev_rx_good,
  output logic        ev_rx_bad,
  output logic        ev_tx_frame
);

  import rtlnet_pkg::*;
  localparam int ADDR_W = 12;
  logic ctrl_rx_en;
  logic ctrl_tx_en;
  logic [1:0] ctrl_speed;
  logic [2:0] tx_ctrl_sync;
  logic [2:0] tx_ctrl_q;
  logic tx_enable;
  logic [1:0] tx_speed;
  logic tx_resetn;
  logic rate_ok;
  logic [9:0] rate_count;
  logic rx_run_req;
  logic rx_path_on = 1'b0;
  logic rx_open;
  logic rx_resetn;
  logic rx_m_resetn;
  logic rx_clk;
  logic tx_clk;
  logic [31:0] tx_frame_total;
  logic [31:0] tx_frame_total_axis;
  logic tx_frame_sent;
  logic [7:0] gmii_rxd;
  logic gmii_rx_dv;
  logic gmii_rx_er;
  logic gmii_rx_ce;
  logic [7:0] gmii_txd;
  logic gmii_tx_en;
  logic gmii_tx_er;
  logic tx_ce;
  // Reject limits unsupported by the common Ethernet engines.
  generate
    if (MAX_FRAME_BYTES < ETH_MIN_FRAME_BYTES) begin : g_bad_frame
      $fatal(1, "rtlnet_eth_mac_mii: MAX_FRAME_BYTES is below 60");
    end
  endgenerate

  logic [ADDR_W-1:0] r_awaddr;
  logic              r_awvalid;
  logic              r_awready;
  logic [31:0]       r_wdata;
  logic [3:0]        r_wstrb;
  logic              r_wvalid;
  logic              r_wready;
  logic [1:0]        r_bresp;
  logic              r_bvalid;
  logic              r_bready;
  logic [ADDR_W-1:0] r_araddr;
  logic              r_arvalid;
  logic              r_arready;
  logic [31:0]       r_rdata;
  logic [1:0]        r_rresp;
  logic              r_rvalid;
  logic              r_rready;
  logic              reg_wr_en;
  logic [ADDR_W-1:0] reg_wr_addr;
  logic [31:0]       reg_wr_data;
  logic              reg_rd_en;
  logic [ADDR_W-1:0] reg_rd_addr;
  logic [31:0]       reg_rd_data;

  logic [63:0] rxg_data;
  logic [7:0]  rxg_keep;
  logic        rxg_valid;
  logic        rxg_last;
  logic        rxg_bad;
  logic        rx_guard_bad;
  logic        rx_fifo_s_ready;               // always 1 (drop when full)
  logic [63:0] rx_fifo_data;
  logic [7:0]  rx_fifo_keep;
  logic        rx_fifo_valid;
  logic        rx_fifo_ready;
  logic        rx_fifo_last;
  logic        rx_overflow;
  logic        rx_bad_frame;
  logic        rx_slice_valid;
  logic        rx_slice_ready;
  logic        rx_take;
  logic        rx_open_next;
  logic        rx_good_event;

  // ---------------------------------------------------------------------------
  // Transmit chain
  // ---------------------------------------------------------------------------
  logic [63:0] txc_data;
  logic [7:0]  txc_keep;
  logic        txc_valid;
  logic        txc_last;
  logic        txc_ready;
  logic        tx_guard_bad;
  logic [63:0] txf_data;
  logic [7:0]  txf_keep;
  logic        txf_valid;
  logic        txf_last;
  logic        txf_ready;
  logic        tx_overflow_unused;            // DROP_WHEN_FULL = 0: never pulses
  logic        tx_bad_frame_unused;           // malformed client frames are dropped silently

  // The whole AXI4-Lite transaction crosses from s_axi_aclk into axis_clk.
  rtlnet_axil_cdc #(
    .ADDR_W (ADDR_W)
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
    .m_clk         (axis_clk),
    .m_resetn      (axis_resetn),
    .m_axi_awaddr  (r_awaddr),
    .m_axi_awvalid (r_awvalid),
    .m_axi_awready (r_awready),
    .m_axi_wdata   (r_wdata),
    .m_axi_wstrb   (r_wstrb),
    .m_axi_wvalid  (r_wvalid),
    .m_axi_wready  (r_wready),
    .m_axi_bresp   (r_bresp),
    .m_axi_bvalid  (r_bvalid),
    .m_axi_bready  (r_bready),
    .m_axi_araddr  (r_araddr),
    .m_axi_arvalid (r_arvalid),
    .m_axi_arready (r_arready),
    .m_axi_rdata   (r_rdata),
    .m_axi_rresp   (r_rresp),
    .m_axi_rvalid  (r_rvalid),
    .m_axi_rready  (r_rready)
  );

  // AXI4-Lite to one-clock register strobes in axis_clk.
  rtlnet_axil_slave #(
    .ADDR_W (ADDR_W)
  ) u_axil_slave (
    .s_axi_aclk    (axis_clk),
    .s_axi_aresetn (axis_resetn),
    .s_axi_awaddr  (r_awaddr),
    .s_axi_awvalid (r_awvalid),
    .s_axi_awready (r_awready),
    .s_axi_wdata   (r_wdata),
    .s_axi_wstrb   (r_wstrb),
    .s_axi_wvalid  (r_wvalid),
    .s_axi_wready  (r_wready),
    .s_axi_bresp   (r_bresp),
    .s_axi_bvalid  (r_bvalid),
    .s_axi_bready  (r_bready),
    .s_axi_araddr  (r_araddr),
    .s_axi_arvalid (r_arvalid),
    .s_axi_arready (r_arready),
    .s_axi_rdata   (r_rdata),
    .s_axi_rresp   (r_rresp),
    .s_axi_rvalid  (r_rvalid),
    .s_axi_rready  (r_rready),
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data)
  );

  // Register file, counters and the registered status outputs.
  rtlnet_eth_mac_regs #(
    .RX_FIFO_KB      (RX_FIFO_KB),
    .TX_FIFO_KB      (TX_FIFO_KB),
    .MAX_FRAME_BYTES (MAX_FRAME_BYTES),
    .RX_IDELAY_TAP   (0)
  ) u_regs (
    .clk               (axis_clk),
    .resetn            (axis_resetn),
    .reg_wr_en         (reg_wr_en),
    .reg_wr_addr       (reg_wr_addr),
    .reg_wr_data       (reg_wr_data),
    .reg_rd_en         (reg_rd_en),
    .reg_rd_addr       (reg_rd_addr),
    .reg_rd_data       (reg_rd_data),
    .ctrl_rx_en        (ctrl_rx_en),
    .ctrl_tx_en        (ctrl_tx_en),
    .ctrl_speed        (ctrl_speed),
    .st_rx_clk_ok      (rate_ok),
    .st_idelay_rdy     (1'b1),
    .st_rx_in_reset    (!(rx_path_on && rx_m_resetn)),
    .st_speed          (ctrl_speed),
    .st_rx_clk_rate    (rate_count),
    .st_inband_link    (1'b0),
    .st_inband_speed   (2'b00),
    .st_inband_duplex  (1'b0),
    .rx_good_event     (rx_good_event),
    .rx_bad_event      (rx_bad_frame),
    .rx_overflow_event (rx_overflow),
    .tx_frame_total    (tx_frame_total_axis),
    .stat_link_up      (stat_link_up),
    .stat_speed        (stat_speed),
    .stat_rx_clk_ok    (stat_rx_clk_ok),
    .ev_rx_good        (ev_rx_good),
    .ev_rx_bad         (ev_rx_bad),
    .ev_tx_frame       (ev_tx_frame)
  );

  // CTRL crosses into PHY TX_CLK with the established synchronizer/filter scheme.
  rtlnet_sync #(.WIDTH(3), .STAGES(3)) u_ctrl_sync (
    .clk(tx_clk), .resetn(tx_resetn), .d({ctrl_tx_en, ctrl_speed}), .q(tx_ctrl_sync)
  );
  // Only stable synchronized controls reach the transmitter.
  always_ff @(posedge tx_clk) begin
    if (!tx_resetn) begin
      tx_ctrl_q <= '0;
      tx_enable <= 1'b0;
      tx_speed <= '0;
    end else begin
      tx_ctrl_q <= tx_ctrl_sync;
      if (tx_ctrl_q == tx_ctrl_sync) {tx_enable, tx_speed} <= tx_ctrl_sync;
    end
  end

  // TX FIFO and engine reset share the client assertion, with PHY-clock release.
  rtlnet_reset_sync u_tx_reset_sync (
    .clk(tx_clk), .arstn(axis_resetn), .resetn(tx_resetn)
  );
  // RXC rate qualifies the firmware speed without a 125 MHz reference.
  rtlnet_mii_rxc_rate #(.REF_CLK_HZ(AXIS_CLK_HZ)) u_rxc_rate (
    .ref_clk(axis_clk), .ref_resetn(axis_resetn), .rx_clk(rx_clk),
    .speed(ctrl_speed), .rate_ok(rate_ok), .rate_count(rate_count)
  );
  // Keep the receive reset decision alive even if either PHY clock stops.
  always_ff @(posedge axis_clk) begin
    if (!axis_resetn) rx_run_req <= 1'b0;
    else rx_run_req <= ctrl_rx_en && rate_ok;
  end

  assign rx_take      = rx_fifo_valid && rx_fifo_ready;
  assign rx_open_next = rx_take ? !rx_fifo_last : rx_open;

  // rx_path_on rises with the request and falls only between frames.
  always_ff @(posedge axis_clk) begin
    if (!axis_resetn) begin
      rx_open    <= 1'b0;
      rx_path_on <= 1'b0;
    end else begin
      rx_open <= rx_open_next;
      if (rx_run_req)    rx_path_on <= 1'b1;
      else if (!rx_open_next) rx_path_on <= 1'b0;
    end
  end

  // Receive reset in rx_clk: asserts with RXC stopped, releases on RXC.
  rtlnet_reset_sync u_rx_reset_sync (
    .clk    (rx_clk),
    .arstn  (rx_path_on),
    .resetn (rx_resetn)
  );

  // RX FIFO read-side reset in axis_clk, from the same assertion.
  rtlnet_reset_sync u_rx_m_reset_sync (
    .clk    (axis_clk),
    .arstn  (rx_path_on),
    .resetn (rx_m_resetn)
  );

  // Count transmitted frames in the PHY clock and cross the total coherently.
  always_ff @(posedge tx_clk) begin
    if (!tx_resetn) tx_frame_total <= '0;
    else if (tx_frame_sent) tx_frame_total <= tx_frame_total + 32'd1;
  end
  // Gray counter crossing keeps the register block event accounting unchanged.
  rtlnet_gray_sync #(.WIDTH(32), .STAGES(2)) u_tx_count_sync (
    .src_clk(tx_clk), .src_resetn(tx_resetn), .src_count(tx_frame_total),
    .dst_clk(axis_clk), .dst_resetn(axis_resetn), .dst_count(tx_frame_total_axis)
  );
  // PHY clock buffers, the only vendor primitives of this top level.
  rtlnet_mii_clkbuf u_rx_clkbuf (.clk_in(mii_rx_clk), .clk_out(rx_clk));
  rtlnet_mii_clkbuf u_tx_clkbuf (.clk_in(mii_tx_clk), .clk_out(tx_clk));
  // Vendor-neutral SDR nibble conversion, with no DDR or delay primitives.
  rtlnet_mii_io u_mii_io (
    .mii_rx_clk(rx_clk), .rx_resetn(rx_resetn),
    .mii_rxd(mii_rxd), .mii_rx_dv(mii_rx_dv), .mii_rx_er(mii_rx_er),
    .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er), .gmii_rx_ce(gmii_rx_ce),
    .mii_tx_clk(tx_clk), .tx_resetn(tx_resetn),
    .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .tx_ce(tx_ce),
    .mii_txd(mii_txd), .mii_tx_en(mii_tx_en)
  );

  // GMII bytes to verdict-carrying 64-bit beats.
  rtlnet_gmii_rx u_gmii_rx (
    .clk        (rx_clk),
    .resetn     (rx_resetn),
    .gmii_rxd   (gmii_rxd),
    .gmii_rx_dv (gmii_rx_dv),
    .gmii_rx_er (gmii_rx_er),
    .ce         (gmii_rx_ce),
    .m_data     (rxg_data),
    .m_keep     (rxg_keep),
    .m_valid    (rxg_valid),
    .m_last     (rxg_last),
    .m_bad      (rxg_bad)
  );

  // Length and tkeep verdict, ORed with the FCS / RX_ER verdict.
  rtlnet_frame_guard #(
    .MIN_BYTES (ETH_MIN_FRAME_BYTES),
    .MAX_BYTES (MAX_FRAME_BYTES)
  ) u_rx_guard (
    .clk     (rx_clk),
    .resetn  (rx_resetn),
    .keep    (rxg_keep),
    .valid   (rxg_valid),
    .ready   (1'b1),
    .last    (rxg_last),
    .bad_in  (rxg_bad),
    .bad_out (rx_guard_bad)
  );

  // Store and forward, rx_clk -> axis_clk; a frame meeting a full queue is
  // consumed and counted as overflow (the receiver cannot stall).
  rtlnet_packet_fifo #(
    .RAM_STYLE       (RAM_STYLE),
    .FIFO_KB         (RX_FIFO_KB),
    .MAX_FRAME_BYTES (MAX_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b1)
  ) u_rx_fifo (
    .s_clk     (rx_clk),
    .s_resetn  (rx_resetn),
    .s_data    (rxg_data),
    .s_keep    (rxg_keep),
    .s_valid   (rxg_valid),
    .s_ready   (rx_fifo_s_ready),
    .s_last    (rxg_last),
    .s_bad     (rx_guard_bad),
    .m_clk     (axis_clk),
    .m_resetn  (rx_m_resetn),
    .m_data    (rx_fifo_data),
    .m_keep    (rx_fifo_keep),
    .m_valid   (rx_fifo_valid),
    .m_ready   (rx_fifo_ready),
    .m_last    (rx_fifo_last),
    .overflow  (rx_overflow),
    .bad_frame (rx_bad_frame)
  );

  // No new frame leaves the FIFO once rx_path_on has fallen.
  assign rx_slice_valid = rx_fifo_valid && rx_path_on;
  assign rx_fifo_ready  = rx_slice_ready && rx_path_on;
  assign rx_good_event  = m_axis_rx_tvalid && m_axis_rx_tready && m_axis_rx_tlast;

  // Registered client boundary (every m_axis_rx output is a flop).
  rtlnet_axis_reg_slice #(
    .DATA_W     (64),
    .RESET_DATA (1'b1)
  ) u_rx_slice (
    .clk      (axis_clk),
    .resetn   (axis_resetn),
    .s_tdata  (rx_fifo_data),
    .s_tkeep  (rx_fifo_keep),
    .s_tlast  (rx_fifo_last),
    .s_tvalid (rx_slice_valid),
    .s_tready (rx_slice_ready),
    .m_tdata  (m_axis_rx_tdata),
    .m_tkeep  (m_axis_rx_tkeep),
    .m_tlast  (m_axis_rx_tlast),
    .m_tvalid (m_axis_rx_tvalid),
    .m_tready (m_axis_rx_tready)
  );

  // ===========================================================================
  // Transmit chain
  // ===========================================================================

  // Registered client boundary (s_axis_tx_tready is a flop).
  rtlnet_axis_reg_slice #(
    .DATA_W     (64),
    .RESET_DATA (1'b1)
  ) u_tx_slice (
    .clk      (axis_clk),
    .resetn   (axis_resetn),
    .s_tdata  (s_axis_tx_tdata),
    .s_tkeep  (s_axis_tx_tkeep),
    .s_tlast  (s_axis_tx_tlast),
    .s_tvalid (s_axis_tx_tvalid),
    .s_tready (s_axis_tx_tready),
    .m_tdata  (txc_data),
    .m_tkeep  (txc_keep),
    .m_tlast  (txc_last),
    .m_tvalid (txc_valid),
    .m_tready (txc_ready)
  );

  // Client frame legality: 14..MAX_FRAME_BYTES bytes, legal tkeep.
  rtlnet_frame_guard #(
    .MIN_BYTES (ETH_MIN_TX_BYTES),
    .MAX_BYTES (MAX_FRAME_BYTES)
  ) u_tx_guard (
    .clk     (axis_clk),
    .resetn  (axis_resetn),
    .keep    (txc_keep),
    .valid   (txc_valid),
    .ready   (txc_ready),
    .last    (txc_last),
    .bad_in  (1'b0),
    .bad_out (tx_guard_bad)
  );

  // Store and forward, axis_clk -> mii_tx_clk, back-pressure when full.
  rtlnet_packet_fifo #(
    .RAM_STYLE       (RAM_STYLE),
    .FIFO_KB         (TX_FIFO_KB),
    .MAX_FRAME_BYTES (MAX_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_tx_fifo (
    .s_clk     (axis_clk),
    .s_resetn  (axis_resetn),
    .s_data    (txc_data),
    .s_keep    (txc_keep),
    .s_valid   (txc_valid),
    .s_ready   (txc_ready),
    .s_last    (txc_last),
    .s_bad     (tx_guard_bad),
    .m_clk     (tx_clk),
    .m_resetn  (tx_resetn),
    .m_data    (txf_data),
    .m_keep    (txf_keep),
    .m_valid   (txf_valid),
    .m_ready   (txf_ready),
    .m_last    (txf_last),
    .overflow  (tx_overflow_unused),
    .bad_frame (tx_bad_frame_unused)
  );

  // Beats to GMII bytes: preamble, pad, FCS, interframe gap.
  rtlnet_gmii_tx #(
    .MIN_FRAME_BYTES (ETH_MIN_FRAME_BYTES),
    .IFG_BYTES       (12)
  ) u_gmii_tx (
    .clk        (tx_clk),
    .resetn     (tx_resetn),
    .ce         (tx_ce),
    .enable     (tx_enable && !tx_speed[1]),
    .s_data     (txf_data),
    .s_keep     (txf_keep),
    .s_valid    (txf_valid),
    .s_last     (txf_last),
    .s_ready    (txf_ready),
    .gmii_txd   (gmii_txd),
    .gmii_tx_en (gmii_tx_en),
    .gmii_tx_er (gmii_tx_er),
    .frame_sent (tx_frame_sent)
  );

endmodule
