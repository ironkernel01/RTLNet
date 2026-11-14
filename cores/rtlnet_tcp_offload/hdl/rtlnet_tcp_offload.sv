// -----------------------------------------------------------------------------
// File: rtlnet_tcp_offload.sv
// Purpose: IPv4 / TCP / UDP checksum offload on the CPU DMA stream: inserts the
//   checksums of frames the CPU transmits and computes them for frames the CPU
//   receives, so the CPU's network stack skips that work.
// Overview:
//   * Egress (CPU DMA MM2S -> offload -> CPU TX FIFO): rtlnet_tcp_offload_tx,
//     store and forward, patches the IPv4 header checksum and the TCP / UDP
//     checksum in place (CTRL.tx_ip_csum, CTRL.tx_l4_csum). The existing field
//     contents are ignored. VLAN (one 802.1Q tag) aware.
//   * Ingress (classifier output -> offload -> AXI DMA S2MM): rtlnet_tcp_offload_rx,
//     cut-through, checks the IPv4 header and the TCP / UDP checksum while the
//     frame streams and appends an 8-byte trailer beat with the result
//     (CTRL.rx_csum). Nothing is dropped in hardware.
//   * Both paths are bit-exact pass-through while CTRL is 0 (power-up value).
//   * Registers: standard header ID "TCPO" / VERSION / CAPS, CTRL, STATUS (idle
//     bits), LATENCY, CNT_CLEAR and eleven counters (rtlnet_tcp_offload_regs).
//     Planned protocol sub-map slot 0x9000 (0x44A1_9000), not wired here.
//   * Everything runs in clk (the CPU stream clock); the register file crosses
//     from s_axi_aclk inside rtlnet_tcp_offload_regs.
//   * Optional receive features (parameters, 0 = not built, the netlist is then the one without them):
//     ACK_COALESCE (rtlnet_tcp_offload_ackco: pure TCP ACKs of a flow are held, only the newest per interval
//     is forwarded) and RX_BATCH (rtlnet_tcp_offload_batch: consecutive frames, each with its trailer, in one
//     DMA transfer). Order: rx -> ackco -> batch -> DMA. Both need CTRL.rx_csum (they work on the trailer);
//     enable bits CTRL.ack_coalesce / CTRL.rx_batch, power-up 0 = bit-exact as without them.
// Language: SystemVerilog-2012.
// Revision: 11-14-2026
//   * 11-14-2026: parameters ACK_COALESCE, RX_BATCH, ACK_FLOWS, ACK_RAM_STYLE, RX_BATCH_MAX_FRAME_BYTES, CLK_HZ.
//   * 10-22-2026: initial version.
// Clocks: clk (stream), s_axi_aclk (registers); each reset synchronous, active
//   low, asserted together.
// -----------------------------------------------------------------------------
module rtlnet_tcp_offload #(
  parameter string RAM_STYLE       = "block",       // TX frame buffer: "block" | "distributed"
  parameter string SB_RAM_STYLE    = "distributed", // TX sideband queue
  parameter int    TX_BUF_KB       = 8,             // TX frame buffer, kilobytes (8 = four maximum frames: full rate)
  parameter int    MAX_FRAME_BYTES = 1518,
  parameter int    ACK_COALESCE    = 0,             // 1: build the ACK coalescer (receive path)
  parameter int    ACK_FLOWS       = 4,             // coalescer flow table entries, 2..16
  parameter string ACK_RAM_STYLE   = "distributed", // coalescer slot RAM ((ACK_FLOWS + 2) x 128 bytes)
  parameter int    RX_BATCH        = 0,             // 1: build the receive batcher
  parameter int    RX_BATCH_MAX_FRAME_BYTES = 2048, // largest frame a batch byte limit keeps room for (multiple of 8)
  parameter int    CLK_HZ          = 100_000_000    // clk frequency, for the microsecond tick of the two features
)(
  // Clocks and resets.
  input  logic        clk,
  input  logic        resetn,
  input  logic        s_axi_aclk,
  input  logic        s_axi_aresetn,

  // TX: frames from the CPU DMA (MM2S), RTLNet stream.
  input  logic [63:0] s_axis_tx_tdata,
  input  logic [7:0]  s_axis_tx_tkeep,
  input  logic        s_axis_tx_tvalid,
  input  logic        s_axis_tx_tlast,
  output logic        s_axis_tx_tready,

  // TX: frames to the CPU TX FIFO, RTLNet stream.
  output logic [63:0] m_axis_tx_tdata,
  output logic [7:0]  m_axis_tx_tkeep,
  output logic        m_axis_tx_tvalid,
  output logic        m_axis_tx_tlast,
  input  logic        m_axis_tx_tready,

  // RX: frames from the classifier, RTLNet stream.
  input  logic [63:0] s_axis_rx_tdata,
  input  logic [7:0]  s_axis_rx_tkeep,
  input  logic        s_axis_rx_tvalid,
  input  logic        s_axis_rx_tlast,
  output logic        s_axis_rx_tready,

  // RX: frames and trailers to the CPU DMA (S2MM), RTLNet stream.
  output logic [63:0] m_axis_rx_tdata,
  output logic [7:0]  m_axis_rx_tkeep,
  output logic        m_axis_rx_tvalid,
  output logic        m_axis_rx_tlast,
  input  logic        m_axis_rx_tready,

  // Registers, AXI4-Lite slave in s_axi_aclk, 12-bit address.
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
  input  logic        s_axi_rready
);

  import rtlnet_tcp_offload_pkg::*;

  logic cfg_tx_ip;
  logic cfg_tx_l4;
  logic cfg_rx;
  logic tx_idle;
  logic rx_idle;
  logic [NUM_TX_COUNTERS-1:0] tx_ev;
  logic [NUM_RX_COUNTERS-1:0] rx_ev;

  // Feature configuration, status and events (constant when the feature is not built).
  localparam bit FEAT         = (ACK_COALESCE != 0) || (RX_BATCH != 0);
  localparam int BAT_RESERVE  = (RX_BATCH != 0) ? (RX_BATCH_MAX_FRAME_BYTES + 8) : 0;
  localparam int TICK_CLKS    = CLK_HZ / 1_000_000;

  logic        cfg_ack_en;
  logic [15:0] cfg_ack_timer;
  logic [7:0]  cfg_ack_limit;
  logic        cfg_bat_en;
  logic [15:0] cfg_bat_timer;
  logic [7:0]  cfg_bat_frames;
  logic [15:0] cfg_bat_bytes;
  logic        ack_idle;
  logic        bat_idle;
  logic [NUM_ACK_COUNTERS-1:0] ack_ev;
  logic [NUM_BAT_COUNTERS-1:0] bat_ev;

  // Registers, counters and the AXI4-Lite crossing.
  rtlnet_tcp_offload_regs #(
    .TX_BUF_KB         (TX_BUF_KB),
    .MAX_FRAME_BYTES   (MAX_FRAME_BYTES),
    .ACK_COALESCE      (ACK_COALESCE),
    .RX_BATCH          (RX_BATCH),
    .ACK_FLOWS         (ACK_FLOWS),
    .BAT_RESERVE_BYTES (BAT_RESERVE)
  ) u_regs (
    .s_axi_aclk    (s_axi_aclk),
    .s_axi_aresetn (s_axi_aresetn),
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
    .clk           (clk),
    .resetn        (resetn),
    .cfg_tx_ip     (cfg_tx_ip),
    .cfg_tx_l4     (cfg_tx_l4),
    .cfg_rx        (cfg_rx),
    .cfg_ack_en    (cfg_ack_en),
    .cfg_ack_timer (cfg_ack_timer),
    .cfg_ack_limit (cfg_ack_limit),
    .cfg_bat_en    (cfg_bat_en),
    .cfg_bat_timer (cfg_bat_timer),
    .cfg_bat_frames(cfg_bat_frames),
    .cfg_bat_bytes (cfg_bat_bytes),
    .tx_idle       (tx_idle),
    .rx_idle       (rx_idle),
    .ack_idle      (ack_idle),
    .bat_idle      (bat_idle),
    .tx_ev         (tx_ev),
    .rx_ev         (rx_ev),
    .ack_ev        (ack_ev),
    .bat_ev        (bat_ev)
  );

  // Egress datapath.
  rtlnet_tcp_offload_tx #(
    .RAM_STYLE       (RAM_STYLE),
    .SB_RAM_STYLE    (SB_RAM_STYLE),
    .TX_BUF_KB       (TX_BUF_KB),
    .MAX_FRAME_BYTES (MAX_FRAME_BYTES)
  ) u_tx (
    .clk           (clk),
    .resetn        (resetn),
    .cfg_ip        (cfg_tx_ip),
    .cfg_l4        (cfg_tx_l4),
    .s_axis_tdata  (s_axis_tx_tdata),
    .s_axis_tkeep  (s_axis_tx_tkeep),
    .s_axis_tvalid (s_axis_tx_tvalid),
    .s_axis_tlast  (s_axis_tx_tlast),
    .s_axis_tready (s_axis_tx_tready),
    .m_axis_tdata  (m_axis_tx_tdata),
    .m_axis_tkeep  (m_axis_tx_tkeep),
    .m_axis_tvalid (m_axis_tx_tvalid),
    .m_axis_tlast  (m_axis_tx_tlast),
    .m_axis_tready (m_axis_tx_tready),
    .idle          (tx_idle),
    .ev_frame      (tx_ev[CNT_TX_FRAMES]),
    .ev_ip         (tx_ev[CNT_TX_IP_PATCHED]),
    .ev_l4         (tx_ev[CNT_TX_L4_PATCHED]),
    .ev_skip       (tx_ev[CNT_TX_SKIPPED]),
    .ev_malf       (tx_ev[CNT_TX_MALFORMED]),
    .ev_drop       (tx_ev[CNT_TX_DROPPED])
  );

  // Ingress datapath: rx (trailer) -> [ackco] -> [batch] -> DMA. u_rx stays at this level in every build.
  logic [63:0] rx_d;
  logic [7:0]  rx_k;
  logic        rx_v;
  logic        rx_l;
  logic        rx_t;
  logic        rx_r;

  rtlnet_tcp_offload_rx #(
    .SIDEBAND (FEAT)
  ) u_rx (
    .clk           (clk),
    .resetn        (resetn),
    .cfg_rx        (cfg_rx),
    .s_axis_tdata  (s_axis_rx_tdata),
    .s_axis_tkeep  (s_axis_rx_tkeep),
    .s_axis_tvalid (s_axis_rx_tvalid),
    .s_axis_tlast  (s_axis_rx_tlast),
    .s_axis_tready (s_axis_rx_tready),
    .m_axis_tdata  (rx_d),
    .m_axis_tkeep  (rx_k),
    .m_axis_tvalid (rx_v),
    .m_axis_tlast  (rx_l),
    .m_axis_trl    (rx_t),
    .m_axis_tready (rx_r),
    .idle          (rx_idle),
    .ev_frame      (rx_ev[CNT_RX_FRAMES]),
    .ev_verified   (rx_ev[CNT_RX_VERIFIED]),
    .ev_ip_bad     (rx_ev[CNT_RX_IP_BAD]),
    .ev_l4_bad     (rx_ev[CNT_RX_L4_BAD]),
    .ev_unverified (rx_ev[CNT_RX_UNVERIFIED])
  );

  generate
    if (!FEAT) begin : g_rx_plain
      assign m_axis_rx_tdata  = rx_d;
      assign m_axis_rx_tkeep  = rx_k;
      assign m_axis_rx_tvalid = rx_v;
      assign m_axis_rx_tlast  = rx_l;
      assign rx_r             = m_axis_rx_tready;
      assign ack_idle = 1'b1;
      assign bat_idle = 1'b1;
      assign ack_ev   = '0;
      assign bat_ev   = '0;
    end else begin : g_rx_feat
      // Microsecond tick shared by the two features.
      localparam int TW = $clog2(TICK_CLKS + 1);
      logic [TW-1:0] tick_cnt = '0;
      logic          us_tick  = 1'b0;

      if (TICK_CLKS < 1) begin : g_bad_clk
        $fatal(1, "rtlnet_tcp_offload: CLK_HZ=%0d, must be at least 1000000 for the microsecond tick", CLK_HZ);
      end

      always_ff @(posedge clk) begin
        if (!resetn || tick_cnt == TW'(TICK_CLKS - 1)) tick_cnt <= '0;
        else                                           tick_cnt <= tick_cnt + 1'b1;
        us_tick <= resetn && (tick_cnt == TW'(TICK_CLKS - 1));
      end

      // Stage outputs of the optional ackco (stream plus trailer sideband).
      logic [63:0] a_d;
      logic [7:0]  a_k;
      logic        a_v;
      logic        a_l;
      logic        a_t;
      logic        a_r;

      if (ACK_COALESCE != 0) begin : g_ack
        rtlnet_tcp_offload_ackco #(
          .FLOWS     (ACK_FLOWS),
          .RAM_STYLE (ACK_RAM_STYLE)
        ) u_ackco (
          .clk          (clk),
          .resetn       (resetn),
          .cfg_en       (cfg_ack_en),
          .cfg_timer_us (cfg_ack_timer),
          .cfg_limit    (cfg_ack_limit),
          .us_tick      (us_tick),
          .s_tdata      (rx_d),
          .s_tkeep      (rx_k),
          .s_tvalid     (rx_v),
          .s_tlast      (rx_l),
          .s_ttrl       (rx_t),
          .s_tready     (rx_r),
          .m_tdata      (a_d),
          .m_tkeep      (a_k),
          .m_tvalid     (a_v),
          .m_tlast      (a_l),
          .m_ttrl       (a_t),
          .m_tready     (a_r),
          .idle         (ack_idle),
          .ev_cand      (ack_ev[CNT_ACK_CAND]),
          .ev_drop      (ack_ev[CNT_ACK_DROPPED]),
          .ev_fwd       (ack_ev[CNT_ACK_FWD]),
          .ev_fl_timer  (ack_ev[CNT_ACK_FL_TIMER]),
          .ev_fl_limit  (ack_ev[CNT_ACK_FL_LIMIT]),
          .ev_fl_order  (ack_ev[CNT_ACK_FL_ORDER])
        );
      end else begin : g_noack
        assign a_d      = rx_d;
        assign a_k      = rx_k;
        assign a_v      = rx_v;
        assign a_l      = rx_l;
        assign a_t      = rx_t;
        assign rx_r     = a_r;
        assign ack_idle = 1'b1;
        assign ack_ev   = '0;
      end

      if (RX_BATCH != 0) begin : g_bat
        rtlnet_tcp_offload_batch #(
          .MAX_FRAME_BYTES (RX_BATCH_MAX_FRAME_BYTES)
        ) u_batch (
          .clk            (clk),
          .resetn         (resetn),
          .cfg_en         (cfg_bat_en),
          .cfg_timer_us   (cfg_bat_timer),
          .cfg_max_frames (cfg_bat_frames),
          .cfg_max_bytes  (cfg_bat_bytes),
          .us_tick        (us_tick),
          .s_tdata        (a_d),
          .s_tkeep        (a_k),
          .s_tvalid       (a_v),
          .s_tlast        (a_l),
          .s_ttrl         (a_t),
          .s_tready       (a_r),
          .m_tdata        (m_axis_rx_tdata),
          .m_tkeep        (m_axis_rx_tkeep),
          .m_tvalid       (m_axis_rx_tvalid),
          .m_tlast        (m_axis_rx_tlast),
          .m_tready       (m_axis_rx_tready),
          .idle           (bat_idle),
          .ev_batch       (bat_ev[CNT_BAT_BATCHES]),
          .ev_frame       (bat_ev[CNT_BAT_FRAMES]),
          .ev_cl_bytes    (bat_ev[CNT_BAT_CL_BYTES]),
          .ev_cl_count    (bat_ev[CNT_BAT_CL_COUNT]),
          .ev_cl_timer    (bat_ev[CNT_BAT_CL_TIMER]),
          .ev_cl_other    (bat_ev[CNT_BAT_CL_OTHER])
        );
      end else begin : g_nobat
        assign m_axis_rx_tdata  = a_d;
        assign m_axis_rx_tkeep  = a_k;
        assign m_axis_rx_tvalid = a_v;
        assign m_axis_rx_tlast  = a_l;
        assign a_r              = m_axis_rx_tready;
        assign bat_idle         = 1'b1;
        assign bat_ev           = '0;
      end
    end
  endgenerate

endmodule
