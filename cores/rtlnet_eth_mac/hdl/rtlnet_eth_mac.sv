// -----------------------------------------------------------------------------
// File: rtlnet_eth_mac.sv
// Purpose: RTLNet 10/100/1000 Mb/s full-duplex RGMII Ethernet MAC between the
//   RTL8211E RGMII pins and the 64-bit RTLNet stream, with its AXI4-Lite
//   register file (architecture section 7.2, port list section 15.1).
// Overview:
//   * Receive: rgmii_rx* -> u_rgmii_io (`RTLNET_RGMII_IO: DDR capture, 10/100
//     nibble pairing aligned on the SFD) -> u_gmii_rx (SFD, CRC-32 check, FCS
//     strip, 8 -> 64 packing) -> u_rx_guard (60..MAX_FRAME_BYTES, tkeep
//     rules) -> u_rx_fifo (store and forward, rx_clk -> axis_clk, drop when
//     full) -> u_rx_slice -> m_axis_rx. Bad FCS, RX_ER, runt, oversize and
//     overflowing frames are dropped whole and counted.
//   * Transmit: s_axis_tx -> u_tx_slice -> u_tx_guard (14..MAX_FRAME_BYTES)
//     -> u_tx_fifo (store and forward, axis_clk -> clk125, back-pressure) ->
//     u_gmii_tx (preamble, pad to 60, FCS, 12-byte gap, byte clock enable)
//     -> u_rgmii_io -> rgmii_tx*.
//   * Speed: CTRL.SPEED, written by firmware from the PHY's PHYSR (MDIO is
//     bit-banged by firmware through rtlnet_mdio). It crosses into clk125 and
//     rx_clk through rtlnet_sync plus a two-sample stability filter. The
//     RGMII in-band status is decoded for STATUS only and gates nothing.
//   * Receive-path reset: the receive engine (rx_clk) and the RX FIFO read
//     side (axis_clk) are held in reset unless CTRL.RX_EN = 1, the RXC rate
//     detector (u_rxc_rate) has measured RXC in the band of the configured
//     speed for two consecutive 32.8 us windows, and IDELAYCTRL is ready.
//     A speed change clears the rate verdict, so it always passes the receive
//     path through reset. The decision (rx_run_req, clk125) crosses into
//     axis_clk, where rx_path_on applies it at an m_axis_rx frame boundary
//     (a frame partly delivered completes; the FIFO holds it whole), then
//     asserts both receive resets together through rtlnet_reset_sync (rx_clk
//     and axis_clk), asynchronously, so RXC may be stopped.
//   * Transmit enable: CTRL.TX_EN = 0 makes the transmitter consume every
//     frame that reaches the head of the TX FIFO and send nothing (not
//     counted in TX_FRAMES); s_axis_tx keeps flowing and no stale frame is
//     sent when TX_EN returns to 1. A frame already on the wire completes.
//   * Registers in axis_clk: s_axi (s_axi_aclk) -> u_axil_cdc ->
//     u_axil_slave -> u_regs. Map in driver/rtlnet_eth_mac.h.
//   * Counters are exact: RX_GOOD counts m_axis_rx last-beat handshakes, RX_BAD
//     and RX_OVERFLOW count the RX FIFO's axis_clk bad_frame and overflow
//     events, TX_FRAMES counts frames sent (clk125) through rtlnet_gray_sync.
//   * No local address register: the protocol wrapper owns the addresses.
//   * The PHY's internal RX clock delay (RTL8211E extension page 0xA4
//     register 28, set by the MDIO driver) is required: the pin layer
//     captures RXD/RX_CTL centred on RXC.
//   * Instance names u_rgmii_io, u_rx_fifo, u_tx_fifo and the synchronizer
//     instances are referenced by the board constraints; keep them stable.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks:
//   * clk125 (125 MHz): transmit engine, TX FIFO read side, rate detector,
//     receive-run decision. clk125_90 (125 MHz, 90 deg, same MMCM): TXC only.
//   * clk200 (200 MHz): IDELAYCTRL reference.
//   * axis_clk (62.5 MHz on the Nexys Video): client streams, FIFO client
//     sides, register file, status.
//   * s_axi_aclk (cpu_clk): AXI4-Lite slave side of u_axil_cdc.
//   * rx_clk (internal, BUFR of RXC: 125 / 25 / 2.5 MHz): receive engine and
//     RX FIFO write side; this core generates its reset.
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_eth_mac #(
  parameter int    RX_FIFO_KB      = 8,                                // RX packet FIFO, kilobytes
  parameter int    TX_FIFO_KB      = 8,                                // TX packet FIFO, kilobytes
  parameter int    MAX_FRAME_BYTES = rtlnet_pkg::ETH_MAX_FRAME_BYTES,  // client frame limit, FCS excluded
  parameter int    RX_IDELAY_TAP   = 12,                               // RXD/RX_CTL input delay tap
  parameter string RAM_STYLE       = "block"                           // FIFO storage: "block" | "distributed"
)(
  // Clocks: clk125 / clk125_90 / clk200 / axis_clk from the board MMCM,
  // s_axi_aclk the CPU clock.
  input  logic        clk125,
  input  logic        clk125_90,
  input  logic        clk200,
  input  logic        axis_clk,
  input  logic        s_axi_aclk,

  // Resets, each synchronous to its clock, active low, all released from one
  // assertion in the board top (the packet FIFOs need both sides together).
  input  logic        clk125_resetn,
  input  logic        clk200_resetn,
  input  logic        axis_resetn,
  input  logic        s_axi_aresetn,

  // RGMII pins to the Realtek RTL8211E (2.5 V). RXC centred on RXD/RX_CTL by
  // the PHY's RX delay; TXC forwarded 90 degrees after TXD/TX_CTL.
  input  logic        rgmii_rxc,
  input  logic [3:0]  rgmii_rxd,
  input  logic        rgmii_rx_ctl,
  output logic        rgmii_txc,
  output logic [3:0]  rgmii_txd,
  output logic        rgmii_tx_ctl,

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
  // speed (00 10M, 01 100M, 10 1000M), RXC qualified, one-clock frame events
  // (for LEDs).
  output logic        stat_link_up,
  output logic [1:0]  stat_speed,
  output logic        stat_rx_clk_ok,
  output logic        ev_rx_good,
  output logic        ev_rx_bad,
  output logic        ev_tx_frame
);

  import rtlnet_pkg::*;

  localparam int ADDR_W        = 12;
  localparam int CTRL_SYNC_W   = 4;          // {rx_en, tx_en, speed[1:0]}
  localparam int INBAND_W      = 4;          // {duplex, speed[1:0], link}
  localparam int RATE_W        = 10;

  generate
    if (MAX_FRAME_BYTES < ETH_MIN_FRAME_BYTES) begin : g_bad_frame
      $fatal(1, "rtlnet_eth_mac: MAX_FRAME_BYTES=%0d is below %0d", MAX_FRAME_BYTES, ETH_MIN_FRAME_BYTES);
    end
    if (RX_IDELAY_TAP < 0 || RX_IDELAY_TAP > 31) begin : g_bad_tap
      $fatal(1, "rtlnet_eth_mac: RX_IDELAY_TAP=%0d, must be 0..31", RX_IDELAY_TAP);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Register bus (axis_clk after the crossing)
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Control and status crossings
  // ---------------------------------------------------------------------------
  logic                   ctrl_rx_en;          // axis_clk
  logic                   ctrl_tx_en;
  logic [1:0]             ctrl_speed;
  logic [CTRL_SYNC_W-1:0] ctrl_s125;           // clk125, synchronizer output
  logic [CTRL_SYNC_W-1:0] ctrl_s125_q;
  logic                   rx_en_125;           // clk125, filtered
  logic                   tx_en_125;
  logic [1:0]             speed_125;
  logic                   idelay_rdy;          // clk200-derived level from the pin layer
  logic                   idelay_rdy_125;
  logic                   rate_ok_125;
  logic [RATE_W-1:0]      rate_count_125;
  logic                   rx_run_req;          // clk125: the receive path may run
  logic [1:0]             speed_rx_s;          // rx_clk, synchronizer output
  logic [1:0]             speed_rx_q = 2'b00;
  logic [1:0]             speed_rx = 2'b00;    // rx_clk, filtered (free-running)
  logic                   rx_run_req_axis;     // axis_clk
  logic                   rx_path_on = 1'b0;   // axis_clk: async-assert source of both receive resets
  logic                   rx_open;             // axis_clk: a frame is partly through the RX FIFO read side
  logic                   rx_resetn;           // rx_clk receive reset
  logic                   rx_m_resetn;         // axis_clk RX FIFO read-side reset
  logic                   rate_ok_axis;
  logic                   idelay_rdy_axis;
  logic [RATE_W-1:0]      rate_s_axis;
  logic [RATE_W-1:0]      rate_s_axis_q;
  logic [RATE_W-1:0]      rate_axis;
  logic [1:0]             speed_s_axis;
  logic [1:0]             speed_s_axis_q;
  logic [1:0]             speed_axis;
  logic [INBAND_W-1:0]    inband_rx;           // rx_clk
  logic [INBAND_W-1:0]    inband_s_axis;
  logic [INBAND_W-1:0]    inband_s_axis_q;
  logic [INBAND_W-1:0]    inband_axis;
  logic [31:0]            tx_frame_total_125;
  logic [31:0]            tx_frame_total_axis;
  logic                   tx_frame_sent;

  // ---------------------------------------------------------------------------
  // Pin layer and GMII
  // ---------------------------------------------------------------------------
  logic        rx_clk;
  logic [7:0]  gmii_rxd;
  logic        gmii_rx_dv;
  logic        gmii_rx_er;
  logic        gmii_rx_ce;
  logic [7:0]  gmii_txd;
  logic        gmii_tx_en;
  logic        gmii_tx_er;
  logic        tx_ce;

  // ---------------------------------------------------------------------------
  // Receive chain
  // ---------------------------------------------------------------------------
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

  // ===========================================================================
  // Registers: AXI4-Lite crossing, strobe bridge, register file.
  // ===========================================================================

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
    .RX_IDELAY_TAP   (RX_IDELAY_TAP)
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
    .st_rx_clk_ok      (rate_ok_axis),
    .st_idelay_rdy     (idelay_rdy_axis),
    .st_rx_in_reset    (!(rx_path_on && rx_m_resetn)),
    .st_speed          (speed_axis),
    .st_rx_clk_rate    (rate_axis),
    .st_inband_link    (inband_axis[0]),
    .st_inband_speed   (inband_axis[2:1]),
    .st_inband_duplex  (inband_axis[3]),
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

  // ===========================================================================
  // Control into clk125 and the receive-run decision.
  // ===========================================================================

  // CTRL levels into clk125.
  rtlnet_sync #(
    .WIDTH  (CTRL_SYNC_W),
    .STAGES (3)
  ) u_ctrl_sync (
    .clk    (clk125),
    .resetn (clk125_resetn),
    .d      ({ctrl_rx_en, ctrl_tx_en, ctrl_speed}),
    .q      (ctrl_s125)
  );

  // IDELAYCTRL ready into clk125.
  rtlnet_sync #(
    .WIDTH  (1),
    .STAGES (3)
  ) u_idelay_rdy_sync (
    .clk    (clk125),
    .resetn (clk125_resetn),
    .d      (idelay_rdy),
    .q      (idelay_rdy_125)
  );

  // Two-sample stability filter: a control word is taken only when two
  // consecutive synchronized samples agree (no torn multi-bit value).
  always_ff @(posedge clk125) begin
    if (!clk125_resetn) begin
      ctrl_s125_q <= '0;
      rx_en_125   <= 1'b0;
      tx_en_125   <= 1'b0;
      speed_125   <= 2'b00;
    end else begin
      ctrl_s125_q <= ctrl_s125;
      if (ctrl_s125 == ctrl_s125_q) begin
        {rx_en_125, tx_en_125, speed_125} <= ctrl_s125;
      end
    end
  end

  // RXC rate detector: qualifies RXC for the configured speed.
  rtlnet_eth_rxc_rate u_rxc_rate (
    .clk125        (clk125),
    .clk125_resetn (clk125_resetn),
    .rx_clk        (rx_clk),
    .speed         (speed_125),
    .rate_ok       (rate_ok_125),
    .rate_count    (rate_count_125)
  );

  // Receive-run decision, registered so the reset path never sees a glitch.
  always_ff @(posedge clk125) begin
    if (!clk125_resetn) rx_run_req <= 1'b0;
    else                rx_run_req <= rx_en_125 && rate_ok_125 && idelay_rdy_125;
  end

  // ===========================================================================
  // Receive-path reset: applied at an m_axis_rx frame boundary in axis_clk.
  // ===========================================================================

  // Receive-run decision into axis_clk.
  rtlnet_sync #(
    .WIDTH  (1),
    .STAGES (3)
  ) u_rx_run_sync (
    .clk    (axis_clk),
    .resetn (axis_resetn),
    .d      (rx_run_req),
    .q      (rx_run_req_axis)
  );

  assign rx_take      = rx_fifo_valid && rx_fifo_ready;
  assign rx_open_next = rx_take ? !rx_fifo_last : rx_open;

  // rx_path_on rises with the request and falls only between frames.
  always_ff @(posedge axis_clk) begin
    if (!axis_resetn) begin
      rx_open    <= 1'b0;
      rx_path_on <= 1'b0;
    end else begin
      rx_open <= rx_open_next;
      if (rx_run_req_axis)    rx_path_on <= 1'b1;
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

  // Configured speed into rx_clk for the 10/100 pairing (free-running: the
  // value is settled long before the receive reset releases).
  rtlnet_sync #(
    .WIDTH  (2),
    .STAGES (3)
  ) u_speed_rx_sync (
    .clk    (rx_clk),
    .resetn (1'b1),
    .d      (speed_125),
    .q      (speed_rx_s)
  );

  // Two-sample stability filter in rx_clk.
  always_ff @(posedge rx_clk) begin
    speed_rx_q <= speed_rx_s;
    if (speed_rx_s == speed_rx_q) speed_rx <= speed_rx_s;
  end

  // ===========================================================================
  // Status into axis_clk (levels, each with a two-sample filter if multi-bit).
  // ===========================================================================

  // RXC verdict into axis_clk.
  rtlnet_sync #(
    .WIDTH  (1),
    .STAGES (3)
  ) u_rate_ok_sync (
    .clk    (axis_clk),
    .resetn (axis_resetn),
    .d      (rate_ok_125),
    .q      (rate_ok_axis)
  );

  // IDELAYCTRL ready into axis_clk.
  rtlnet_sync #(
    .WIDTH  (1),
    .STAGES (3)
  ) u_idelay_rdy_axis_sync (
    .clk    (axis_clk),
    .resetn (axis_resetn),
    .d      (idelay_rdy),
    .q      (idelay_rdy_axis)
  );

  // Last rate window count into axis_clk (changes once per 32.8 us).
  rtlnet_sync #(
    .WIDTH  (RATE_W),
    .STAGES (3)
  ) u_rate_sync (
    .clk    (axis_clk),
    .resetn (axis_resetn),
    .d      (rate_count_125),
    .q      (rate_s_axis)
  );

  // Speed in effect (clk125) into axis_clk.
  rtlnet_sync #(
    .WIDTH  (2),
    .STAGES (3)
  ) u_speed_axis_sync (
    .clk    (axis_clk),
    .resetn (axis_resetn),
    .d      (speed_125),
    .q      (speed_s_axis)
  );

  // In-band status (rx_clk) into axis_clk.
  rtlnet_sync #(
    .WIDTH  (INBAND_W),
    .STAGES (3)
  ) u_inband_sync (
    .clk    (axis_clk),
    .resetn (axis_resetn),
    .d      (inband_rx),
    .q      (inband_s_axis)
  );

  // Two-sample stability filters for the multi-bit status words.
  always_ff @(posedge axis_clk) begin
    if (!axis_resetn) begin
      rate_s_axis_q   <= '0;
      rate_axis       <= '0;
      speed_s_axis_q  <= '0;
      speed_axis      <= '0;
      inband_s_axis_q <= '0;
      inband_axis     <= '0;
    end else begin
      rate_s_axis_q   <= rate_s_axis;
      speed_s_axis_q  <= speed_s_axis;
      inband_s_axis_q <= inband_s_axis;
      if (rate_s_axis == rate_s_axis_q)     rate_axis   <= rate_s_axis;
      if (speed_s_axis == speed_s_axis_q)   speed_axis  <= speed_s_axis;
      if (inband_s_axis == inband_s_axis_q) inband_axis <= inband_s_axis;
    end
  end

  // Frames sent: clk125 total, crossed coherently into axis_clk.
  always_ff @(posedge clk125) begin
    if (!clk125_resetn)     tx_frame_total_125 <= '0;
    else if (tx_frame_sent) tx_frame_total_125 <= tx_frame_total_125 + 32'd1;
  end

  rtlnet_gray_sync #(
    .WIDTH  (32),
    .STAGES (2)
  ) u_tx_count_sync (
    .src_clk    (clk125),
    .src_resetn (clk125_resetn),
    .src_count  (tx_frame_total_125),
    .dst_clk    (axis_clk),
    .dst_resetn (axis_resetn),
    .dst_count  (tx_frame_total_axis)
  );

  // ===========================================================================
  // RGMII pin layer (technology from rtlnet_technology.svh).
  // ===========================================================================
  `RTLNET_RGMII_IO #(
    .RX_IDELAY_TAP (RX_IDELAY_TAP)
  ) u_rgmii_io (
    .clk125        (clk125),
    .clk125_resetn (clk125_resetn),
    .clk125_90     (clk125_90),
    .clk200        (clk200),
    .clk200_resetn (clk200_resetn),
    .tx_speed      (speed_125),
    .rx_speed      (speed_rx),
    .rgmii_rxc     (rgmii_rxc),
    .rgmii_rxd     (rgmii_rxd),
    .rgmii_rx_ctl  (rgmii_rx_ctl),
    .rgmii_txc     (rgmii_txc),
    .rgmii_txd     (rgmii_txd),
    .rgmii_tx_ctl  (rgmii_tx_ctl),
    .rx_clk        (rx_clk),
    .rx_resetn     (rx_resetn),
    .gmii_rxd      (gmii_rxd),
    .gmii_rx_dv    (gmii_rx_dv),
    .gmii_rx_er    (gmii_rx_er),
    .gmii_rx_ce    (gmii_rx_ce),
    .inband_link   (inband_rx[0]),
    .inband_speed  (inband_rx[2:1]),
    .inband_duplex (inband_rx[3]),
    .idelay_rdy    (idelay_rdy),
    .gmii_txd      (gmii_txd),
    .gmii_tx_en    (gmii_tx_en),
    .gmii_tx_er    (gmii_tx_er),
    .tx_ce         (tx_ce)
  );

  // ===========================================================================
  // Receive chain
  // ===========================================================================

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

  // Store and forward, axis_clk -> clk125, back-pressure when full.
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
    .m_clk     (clk125),
    .m_resetn  (clk125_resetn),
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
    .clk        (clk125),
    .resetn     (clk125_resetn),
    .ce         (tx_ce),
    .enable     (tx_en_125),
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
