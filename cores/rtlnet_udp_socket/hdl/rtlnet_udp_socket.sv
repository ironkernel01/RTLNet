// -----------------------------------------------------------------------------
// File: rtlnet_udp_socket.sv
// Purpose: RTLNet UDP socket layer, a protocol leaf of rtlnet_eth_protocol
//   (leaf 0, highest arbiter priority). NUM_SOCKETS sockets bound to local UDP
//   ports deliver received datagrams to an application stream and send the
//   application's datagrams as Ethernet/IPv4/UDP frames
//   (documentation/rtlnet_architecture.md sections 7.5, 7.7, 15.4).
// Overview:
//   * Leaf contract (section 7.5): proto_clk, s_axis_tready held 1, m_axis is
//     the output of one rtlnet_axis_reg_slice, busy registered, the wrapper's
//     12-bit register bus, enable.
//   * Receive: rtlnet_udp_socket_rx parses every frame, writes accepted
//     datagrams (meta 0, meta 1, payload realigned to byte 0) into u_rx_fifo
//     (rtlnet_packet_fifo, proto_clk -> app_clk, UDP_RX_BUF_KB, slots of one
//     16 + 1472-byte datagram), whose read side is m_axis_app_*.
//   * Transmit: rtlnet_udp_socket_tx_check (app_clk) takes s_axis_app_*,
//     writes the payload into u_tx_fifo (app_clk -> proto_clk,
//     UDP_TX_BUF_KB, 1472-byte slots) and a descriptor (meta 0, meta 1 with
//     the length verdict) into u_tx_desc_fifo (TX_DESC_KB, 64 slots);
//     rtlnet_udp_socket_tx (proto_clk) builds and sends the frame.
//     Receive and transmit are independent: transmitting never stalls or
//     loses an input frame; busy covers receive processing only.
//   * Registers (offsets defined in driver/rtlnet_udp_socket.h, mirrored by
//     the localparams below): global ID, VERSION, CAPS, CTRL, STATUS, six
//     counters; per socket n at 0x100 + 0x40*n: CTRL, LOCAL_PORT, REMOTE_IP,
//     REMOTE_PORT, REMOTE_MAC_HI, REMOTE_MAC_LO, four counters. Counters are
//     32-bit, wrap, and clear with CTRL bit 16 CNT_CLEAR. With CONNECT_ON_RX a
//     delivered datagram loads the socket's REMOTE_* registers with its
//     sender; a register write in the same clock takes precedence.
//   * claim (leaf contract 7.5, registered one-clock pulse): from the receive
//     engine, the clock after the last beat of a datagram whose destination
//     port matches an enabled socket (delivered or dropped for a full FIFO).
//   * Not used: local_gateway (the next-hop MAC is supplied by the application
//     metadata or the socket registers; the layer resolves no addresses).
//   * Clock-domain crossings: only the three packet FIFOs (Gray frame
//     counters, instance names u_*_fifo for scripts/rtlnet_constrain_cdc.tcl).
//     Their two sides reset together (resetn and app_resetn derive from one
//     assertion in the board top).
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: claim output (leaf contract 7.5, CPU network path).
// Clocks: clk (proto_clk): parser, frame builder, registers; app_clk: the two
//   application streams and the transmit checker.
// -----------------------------------------------------------------------------
module rtlnet_udp_socket #(
  parameter int    NUM_SOCKETS   = 4,               // bound ports, 1..60
  parameter int    UDP_RX_BUF_KB = 16,              // RX packet FIFO, KiB (2 KiB per datagram slot)
  parameter int    UDP_TX_BUF_KB = 8,               // TX payload FIFO, KiB (2 KiB per datagram slot)
  parameter string RAM_STYLE     = "block"          // "block" | "distributed", every FIFO
)(
  // Leaf clock and synchronous active-low reset, proto_clk domain.
  input  logic        clk,
  input  logic        resetn,
  // Leaf enable from the wrapper's leaf-enable register (proto_clk): when low,
  // frames are ignored and application datagrams are dropped.
  input  logic        enable,

  // Frames from the wrapper fan-out, proto_clk, RTLNet stream (byte 0 in
  // tdata[7:0]); one frame at a time; never back-pressured (tready is 1).
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // Frames to the wrapper arbiter, proto_clk, RTLNet stream; registered (one
  // rtlnet_axis_reg_slice); a started frame completes without gaps.
  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  // Node address, proto_clk registers of the wrapper: MAC octet 0 in [47:40],
  // IPv4 first octet in [31:24].
  input  logic [47:0] local_mac,
  input  logic [31:0] local_ip,

  // Leaf busy, proto_clk, registered: high while a received frame is being
  // processed.
  output logic        busy,

  // Claim, proto_clk, registered one-clock pulse: the frame that just ended
  // was a datagram for an enabled socket.
  output logic        claim,

  // Wrapper register bus, proto_clk: one-clock strobes; read data valid the
  // clock after reg_rd_en.
  input  logic        reg_wr_en,
  input  logic [11:0] reg_wr_addr,
  input  logic [31:0] reg_wr_data,
  input  logic        reg_rd_en,
  input  logic [11:0] reg_rd_addr,
  output logic [31:0] reg_rd_data,

  // Application clock and its synchronous active-low reset (released with
  // resetn from the same assertion).
  input  logic        app_clk,
  input  logic        app_resetn,

  // Application RX stream, app_clk: received datagrams as meta 0, meta 1,
  // payload (architecture section 7.7); whole datagrams only.
  output logic [63:0] m_axis_app_tdata,
  output logic [7:0]  m_axis_app_tkeep,
  output logic        m_axis_app_tvalid,
  output logic        m_axis_app_tlast,
  input  logic        m_axis_app_tready,

  // Application TX stream, app_clk: datagrams to send as meta 0, meta 1,
  // payload; tready falls only between datagrams.
  input  logic [63:0] s_axis_app_tdata,
  input  logic [7:0]  s_axis_app_tkeep,
  input  logic        s_axis_app_tvalid,
  input  logic        s_axis_app_tlast,
  output logic        s_axis_app_tready,

  // Subnet configuration, proto_clk registers of the wrapper (first octet in
  // [31:24]); local_mask gives the subnet broadcast address, local_gateway is
  // not used by this revision.
  input  logic [31:0] local_mask,
  input  logic [31:0] local_gateway
);

  import rtlnet_pkg::*;
  import rtlnet_udp_socket_pkg::*;

  // ---------------------------------------------------------------------------
  // Register map: mirrors cores/rtlnet_udp_socket/driver/rtlnet_udp_socket.h.
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID            = 12'h000;
  localparam logic [11:0] REG_VERSION       = 12'h004;
  localparam logic [11:0] REG_CAPS          = 12'h008;
  localparam logic [11:0] REG_CTRL          = 12'h00C;
  localparam logic [11:0] REG_STATUS        = 12'h010;
  localparam logic [11:0] REG_RX_NO_SOCKET  = 12'h014;
  localparam logic [11:0] REG_RX_BAD        = 12'h018;
  localparam logic [11:0] REG_RX_FIFO_DROPS = 12'h01C;
  localparam logic [11:0] REG_TX_FRAMES     = 12'h020;
  localparam logic [11:0] REG_TX_DROPS      = 12'h024;
  localparam logic [11:0] REG_RX_DATAGRAMS  = 12'h028;
  localparam logic [11:0] REG_SOCK_BASE     = 12'h100;
  localparam int          SOCK_STRIDE_LOG2  = 6;          // 0x40 bytes per socket
  localparam logic [3:0]  SOCK_CTRL         = 4'h0;       // word index inside a socket block
  localparam logic [3:0]  SOCK_LOCAL_PORT   = 4'h1;
  localparam logic [3:0]  SOCK_REMOTE_IP    = 4'h2;
  localparam logic [3:0]  SOCK_REMOTE_PORT  = 4'h3;
  localparam logic [3:0]  SOCK_REMOTE_MAC_HI = 4'h4;
  localparam logic [3:0]  SOCK_REMOTE_MAC_LO = 4'h5;
  localparam logic [3:0]  SOCK_RX_DATAGRAMS = 4'h6;
  localparam logic [3:0]  SOCK_RX_DROPS     = 4'h7;
  localparam logic [3:0]  SOCK_TX_DATAGRAMS = 4'h8;
  localparam logic [3:0]  SOCK_TX_DROPS     = 4'h9;

  localparam int CTRL_RX_CSUM_CHECK_BIT  = 0;
  localparam int CTRL_CNT_CLEAR_BIT      = 16;
  localparam int SCTRL_ENABLE_BIT        = 0;
  localparam int SCTRL_CONNECT_ON_RX_BIT = 1;
  localparam int STATUS_ENABLE_BIT       = 0;
  localparam int STATUS_RX_BUSY_BIT      = 1;
  localparam int STATUS_TX_ACTIVE_BIT    = 2;
  localparam int STATUS_RX_FIFO_FULL_BIT = 3;
  localparam int STATUS_TX_PENDING_BIT   = 4;

  localparam logic [31:0] CORE_ID      = id4("U", "D", "P", "S");
  localparam logic [31:0] CORE_VERSION = 32'h1022_2026;
  // CAPS: [7:0] NUM_SOCKETS, [15:8] UDP_RX_BUF_KB, [23:16] UDP_TX_BUF_KB,
  // [24] receive UDP checksum check available.
  localparam logic [31:0] CORE_CAPS    = {7'd0, 1'b1, 8'(UDP_TX_BUF_KB), 8'(UDP_RX_BUF_KB), 8'(NUM_SOCKETS)};

  // Descriptor FIFO: 1 KiB = 64 two-word slots, more than the payload FIFO's
  // slots at any UDP_TX_BUF_KB up to 128.
  localparam int TX_DESC_KB = 1;

  generate
    if (NUM_SOCKETS < 1 || NUM_SOCKETS > MAX_SOCKETS) begin : g_bad_sockets
      $fatal(1, "rtlnet_udp_socket: NUM_SOCKETS=%0d, must be 1..%0d", NUM_SOCKETS, MAX_SOCKETS);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Register file state (proto_clk)
  // ---------------------------------------------------------------------------
  logic                         csum_check;
  logic [NUM_SOCKETS-1:0]       sock_enable;
  logic [NUM_SOCKETS-1:0]       sock_connect;
  logic [NUM_SOCKETS-1:0][15:0] sock_port;
  logic [NUM_SOCKETS-1:0][31:0] sock_remote_ip;
  logic [NUM_SOCKETS-1:0][15:0] sock_remote_port;
  logic [NUM_SOCKETS-1:0][47:0] sock_remote_mac;
  logic [NUM_SOCKETS-1:0][31:0] cnt_sock_rx;
  logic [NUM_SOCKETS-1:0][31:0] cnt_sock_rx_drop;
  logic [NUM_SOCKETS-1:0][31:0] cnt_sock_tx;
  logic [NUM_SOCKETS-1:0][31:0] cnt_sock_tx_drop;
  logic [31:0]                  cnt_rx_no_socket;
  logic [31:0]                  cnt_rx_bad;
  logic [31:0]                  cnt_rx_fifo_drops;
  logic [31:0]                  cnt_tx_frames;
  logic [31:0]                  cnt_tx_drops;
  logic [31:0]                  cnt_rx_datagrams;

  // ---------------------------------------------------------------------------
  // Engine interconnect
  // ---------------------------------------------------------------------------
  logic [63:0] rxf_data;
  logic [7:0]  rxf_keep;
  logic        rxf_last;
  logic        rxf_valid;
  logic        rxf_bad;
  logic        rxf_ready;
  logic        rx_ev_delivered;
  logic        rx_ev_fifo_drop;
  logic        rx_ev_no_socket;
  logic        rx_ev_bad;
  logic [7:0]  rx_ev_sock;
  logic [31:0] rx_ev_ip;
  logic [15:0] rx_ev_port;
  logic [47:0] rx_ev_mac;
  logic        rx_busy;

  logic [63:0] txp_s_data;
  logic [7:0]  txp_s_keep;
  logic        txp_s_valid;
  logic        txp_s_last;
  logic        txp_s_bad;
  logic        txp_s_ready;
  logic [63:0] txd_s_data;
  logic        txd_s_valid;
  logic        txd_s_last;
  logic        txd_s_ready;
  logic [63:0] txp_m_data;
  logic [7:0]  txp_m_keep;
  logic        txp_m_valid;
  logic        txp_m_last;
  logic        txp_m_ready;
  logic [63:0] txd_m_data;
  logic [7:0]  txd_m_keep;
  logic        txd_m_valid;
  logic        txd_m_last;
  logic        txd_m_ready;
  logic [63:0] txo_data;
  logic [7:0]  txo_keep;
  logic        txo_last;
  logic        txo_valid;
  logic        txo_ready;
  logic        tx_ev_sent;
  logic        tx_ev_drop;
  logic        tx_ev_drop_in_range;
  logic [7:0]  tx_ev_sock;
  logic        tx_active;

  // Register bus decode.
  logic        wr_global;
  logic        wr_sock;
  logic [5:0]  wr_sock_idx;
  logic [3:0]  wr_field;
  logic        rd_sock;
  logic [5:0]  rd_sock_idx;
  logic [3:0]  rd_field;
  logic        cnt_clear;
  logic [31:0] status_word;

  assign s_axis_tready = 1'b1;
  assign busy          = rx_busy;

  assign wr_global   = reg_wr_en && (reg_wr_addr[11:8] == 4'h0);
  assign wr_sock     = reg_wr_en && (reg_wr_addr[11:8] != 4'h0);
  assign wr_sock_idx = 6'(reg_wr_addr[11:SOCK_STRIDE_LOG2] - REG_SOCK_BASE[11:SOCK_STRIDE_LOG2]);
  assign wr_field    = reg_wr_addr[5:2];
  assign rd_sock     = (reg_rd_addr[11:8] != 4'h0);
  assign rd_sock_idx = 6'(reg_rd_addr[11:SOCK_STRIDE_LOG2] - REG_SOCK_BASE[11:SOCK_STRIDE_LOG2]);
  assign rd_field    = reg_rd_addr[5:2];
  assign cnt_clear   = wr_global && (reg_wr_addr == REG_CTRL) && reg_wr_data[CTRL_CNT_CLEAR_BIT];

  always_comb begin
    status_word                          = '0;
    status_word[STATUS_ENABLE_BIT]       = enable;
    status_word[STATUS_RX_BUSY_BIT]      = rx_busy;
    status_word[STATUS_TX_ACTIVE_BIT]    = tx_active;
    status_word[STATUS_RX_FIFO_FULL_BIT] = !rxf_ready;
    status_word[STATUS_TX_PENDING_BIT]   = txd_m_valid;
  end

  // ---------------------------------------------------------------------------
  // Receive engine and RX packet FIFO
  // ---------------------------------------------------------------------------
  // Parser, decision and realigning writer (proto_clk).
  rtlnet_udp_socket_rx #(.NUM_SOCKETS(NUM_SOCKETS)) u_rx (
    .clk            (clk),
    .resetn         (resetn),
    .enable         (enable),
    .csum_check     (csum_check),
    .s_axis_tdata   (s_axis_tdata),
    .s_axis_tkeep   (s_axis_tkeep),
    .s_axis_tvalid  (s_axis_tvalid),
    .s_axis_tlast   (s_axis_tlast),
    .local_ip       (local_ip),
    .local_mask     (local_mask),
    .sock_enable    (sock_enable),
    .sock_port      (sock_port),
    .fifo_data      (rxf_data),
    .fifo_keep      (rxf_keep),
    .fifo_last      (rxf_last),
    .fifo_valid     (rxf_valid),
    .fifo_bad       (rxf_bad),
    .fifo_ready     (rxf_ready),
    .ev_delivered   (rx_ev_delivered),
    .ev_fifo_drop   (rx_ev_fifo_drop),
    .ev_no_socket   (rx_ev_no_socket),
    .ev_bad         (rx_ev_bad),
    .ev_sock        (rx_ev_sock),
    .ev_remote_ip   (rx_ev_ip),
    .ev_remote_port (rx_ev_port),
    .ev_remote_mac  (rx_ev_mac),
    .busy           (rx_busy),
    .claim          (claim)
  );

  // RX packet FIFO, proto_clk -> app_clk: one datagram (16 metadata bytes +
  // up to 1472 payload bytes, 186 words) per 2 KiB slot; back-pressure mode,
  // so s_ready at the first write is the free-slot verdict the parser uses.
  rtlnet_packet_fifo #(
    .RAM_STYLE       (RAM_STYLE),
    .FIFO_KB         (UDP_RX_BUF_KB),
    .MAX_FRAME_BYTES (META_BYTES + MAX_PAYLOAD_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_rx_fifo (
    .s_clk     (clk),
    .s_resetn  (resetn),
    .s_data    (rxf_data),
    .s_keep    (rxf_keep),
    .s_valid   (rxf_valid),
    .s_ready   (rxf_ready),
    .s_last    (rxf_last),
    .s_bad     (rxf_bad),
    .m_clk     (app_clk),
    .m_resetn  (app_resetn),
    .m_data    (m_axis_app_tdata),
    .m_keep    (m_axis_app_tkeep),
    .m_valid   (m_axis_app_tvalid),
    .m_ready   (m_axis_app_tready),
    .m_last    (m_axis_app_tlast),
    .overflow  (),
    .bad_frame ()
  );

  // ---------------------------------------------------------------------------
  // Transmit path
  // ---------------------------------------------------------------------------
  // Application-side split into payload and descriptor, with the length verdict.
  rtlnet_udp_socket_tx_check u_tx_check (
    .clk           (app_clk),
    .resetn        (app_resetn),
    .s_axis_tdata  (s_axis_app_tdata),
    .s_axis_tkeep  (s_axis_app_tkeep),
    .s_axis_tvalid (s_axis_app_tvalid),
    .s_axis_tlast  (s_axis_app_tlast),
    .s_axis_tready (s_axis_app_tready),
    .pay_data      (txp_s_data),
    .pay_keep      (txp_s_keep),
    .pay_valid     (txp_s_valid),
    .pay_last      (txp_s_last),
    .pay_bad       (txp_s_bad),
    .pay_ready     (txp_s_ready),
    .desc_data     (txd_s_data),
    .desc_valid    (txd_s_valid),
    .desc_last     (txd_s_last),
    .desc_ready    (txd_s_ready)
  );

  // TX payload FIFO, app_clk -> proto_clk: one payload of up to 1472 bytes per
  // 2 KiB slot; a datagram flagged bad on its last beat never appears.
  rtlnet_packet_fifo #(
    .RAM_STYLE       (RAM_STYLE),
    .FIFO_KB         (UDP_TX_BUF_KB),
    .MAX_FRAME_BYTES (MAX_PAYLOAD_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_tx_fifo (
    .s_clk     (app_clk),
    .s_resetn  (app_resetn),
    .s_data    (txp_s_data),
    .s_keep    (txp_s_keep),
    .s_valid   (txp_s_valid),
    .s_ready   (txp_s_ready),
    .s_last    (txp_s_last),
    .s_bad     (txp_s_bad),
    .m_clk     (clk),
    .m_resetn  (resetn),
    .m_data    (txp_m_data),
    .m_keep    (txp_m_keep),
    .m_valid   (txp_m_valid),
    .m_ready   (txp_m_ready),
    .m_last    (txp_m_last),
    .overflow  (),
    .bad_frame ()
  );

  // TX descriptor FIFO, app_clk -> proto_clk: two words (meta 0, meta 1 with
  // the verdict) per 16-byte slot, 64 slots.
  rtlnet_packet_fifo #(
    .RAM_STYLE       (RAM_STYLE),
    .FIFO_KB         (TX_DESC_KB),
    .MAX_FRAME_BYTES (META_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_tx_desc_fifo (
    .s_clk     (app_clk),
    .s_resetn  (app_resetn),
    .s_data    (txd_s_data),
    .s_keep    (8'hFF),
    .s_valid   (txd_s_valid),
    .s_ready   (txd_s_ready),
    .s_last    (txd_s_last),
    .s_bad     (1'b0),
    .m_clk     (clk),
    .m_resetn  (resetn),
    .m_data    (txd_m_data),
    .m_keep    (txd_m_keep),
    .m_valid   (txd_m_valid),
    .m_ready   (txd_m_ready),
    .m_last    (txd_m_last),
    .overflow  (),
    .bad_frame ()
  );

  // Frame builder (proto_clk).
  rtlnet_udp_socket_tx #(.NUM_SOCKETS(NUM_SOCKETS)) u_tx (
    .clk              (clk),
    .resetn           (resetn),
    .enable           (enable),
    .local_mac        (local_mac),
    .local_ip         (local_ip),
    .sock_enable      (sock_enable),
    .sock_port        (sock_port),
    .sock_remote_ip   (sock_remote_ip),
    .sock_remote_port (sock_remote_port),
    .sock_remote_mac  (sock_remote_mac),
    .desc_data        (txd_m_data),
    .desc_valid       (txd_m_valid),
    .desc_last        (txd_m_last),
    .desc_ready       (txd_m_ready),
    .pay_data         (txp_m_data),
    .pay_keep         (txp_m_keep),
    .pay_valid        (txp_m_valid),
    .pay_last         (txp_m_last),
    .pay_ready        (txp_m_ready),
    .o_data           (txo_data),
    .o_keep           (txo_keep),
    .o_last           (txo_last),
    .o_valid          (txo_valid),
    .o_ready          (txo_ready),
    .ev_sent          (tx_ev_sent),
    .ev_drop          (tx_ev_drop),
    .ev_drop_in_range (tx_ev_drop_in_range),
    .ev_sock          (tx_ev_sock),
    .active           (tx_active)
  );

  // Leaf output register slice: every m_axis output is a flop.
  rtlnet_axis_reg_slice #(.DATA_W(64), .RESET_DATA(1'b1)) u_out_slice (
    .clk      (clk),
    .resetn   (resetn),
    .s_tdata  (txo_data),
    .s_tkeep  (txo_keep),
    .s_tlast  (txo_last),
    .s_tvalid (txo_valid),
    .s_tready (txo_ready),
    .m_tdata  (m_axis_tdata),
    .m_tkeep  (m_axis_tkeep),
    .m_tlast  (m_axis_tlast),
    .m_tvalid (m_axis_tvalid),
    .m_tready (m_axis_tready)
  );

  // ---------------------------------------------------------------------------
  // Register file: controls, socket table, counters (proto_clk)
  // ---------------------------------------------------------------------------
  // Global controls and counters.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      csum_check        <= 1'b0;
      cnt_rx_no_socket  <= '0;
      cnt_rx_bad        <= '0;
      cnt_rx_fifo_drops <= '0;
      cnt_tx_frames     <= '0;
      cnt_tx_drops      <= '0;
      cnt_rx_datagrams  <= '0;
    end else begin
      if (wr_global && (reg_wr_addr == REG_CTRL)) csum_check <= reg_wr_data[CTRL_RX_CSUM_CHECK_BIT];
      if (cnt_clear) begin
        cnt_rx_no_socket  <= '0;
        cnt_rx_bad        <= '0;
        cnt_rx_fifo_drops <= '0;
        cnt_tx_frames     <= '0;
        cnt_tx_drops      <= '0;
        cnt_rx_datagrams  <= '0;
      end else begin
        if (rx_ev_no_socket) cnt_rx_no_socket  <= cnt_rx_no_socket + 32'd1;
        if (rx_ev_bad)       cnt_rx_bad        <= cnt_rx_bad + 32'd1;
        if (rx_ev_fifo_drop) cnt_rx_fifo_drops <= cnt_rx_fifo_drops + 32'd1;
        if (tx_ev_sent)      cnt_tx_frames     <= cnt_tx_frames + 32'd1;
        if (tx_ev_drop)      cnt_tx_drops      <= cnt_tx_drops + 32'd1;
        if (rx_ev_delivered) cnt_rx_datagrams  <= cnt_rx_datagrams + 32'd1;
      end
    end
  end

  // Socket table: register writes, connect-on-receive updates, per-socket counters.
  generate
    for (genvar n = 0; n < NUM_SOCKETS; n++) begin : g_sock
      logic        wr_this;
      logic        rx_this;
      logic        tx_this;
      logic        r_enable;
      logic        r_connect;
      logic [15:0] r_port;
      logic [31:0] r_remote_ip;
      logic [15:0] r_remote_port;
      logic [47:0] r_remote_mac;
      logic [31:0] r_rx;
      logic [31:0] r_rx_drop;
      logic [31:0] r_tx;
      logic [31:0] r_tx_drop;

      assign wr_this = wr_sock && (wr_sock_idx == 6'(n));
      assign rx_this = (rx_ev_sock == 8'(n));
      assign tx_this = (tx_ev_sock == 8'(n));

      assign sock_enable[n]      = r_enable;
      assign sock_connect[n]     = r_connect;
      assign sock_port[n]        = r_port;
      assign sock_remote_ip[n]   = r_remote_ip;
      assign sock_remote_port[n] = r_remote_port;
      assign sock_remote_mac[n]  = r_remote_mac;
      assign cnt_sock_rx[n]      = r_rx;
      assign cnt_sock_rx_drop[n] = r_rx_drop;
      assign cnt_sock_tx[n]      = r_tx;
      assign cnt_sock_tx_drop[n] = r_tx_drop;

      always_ff @(posedge clk) begin
        if (!resetn) begin
          r_enable      <= 1'b0;
          r_connect     <= 1'b0;
          r_port        <= '0;
          r_remote_ip   <= '0;
          r_remote_port <= '0;
          r_remote_mac  <= '0;
          r_rx          <= '0;
          r_rx_drop     <= '0;
          r_tx          <= '0;
          r_tx_drop     <= '0;
        end else begin
          if (rx_ev_delivered && rx_this && r_connect) begin
            r_remote_ip   <= rx_ev_ip;
            r_remote_port <= rx_ev_port;
            r_remote_mac  <= rx_ev_mac;
          end
          if (wr_this) begin
            case (wr_field)
              SOCK_CTRL: begin
                r_enable  <= reg_wr_data[SCTRL_ENABLE_BIT];
                r_connect <= reg_wr_data[SCTRL_CONNECT_ON_RX_BIT];
              end
              SOCK_LOCAL_PORT:    r_port              <= reg_wr_data[15:0];
              SOCK_REMOTE_IP:     r_remote_ip         <= reg_wr_data;
              SOCK_REMOTE_PORT:   r_remote_port       <= reg_wr_data[15:0];
              SOCK_REMOTE_MAC_HI: r_remote_mac[47:32] <= reg_wr_data[15:0];
              SOCK_REMOTE_MAC_LO: r_remote_mac[31:0]  <= reg_wr_data;
              default: ;
            endcase
          end
          if (cnt_clear) begin
            r_rx      <= '0;
            r_rx_drop <= '0;
            r_tx      <= '0;
            r_tx_drop <= '0;
          end else begin
            if (rx_ev_delivered && rx_this)                   r_rx      <= r_rx + 32'd1;
            if (rx_ev_fifo_drop && rx_this)                   r_rx_drop <= r_rx_drop + 32'd1;
            if (tx_ev_sent && tx_this)                        r_tx      <= r_tx + 32'd1;
            if (tx_ev_drop && tx_ev_drop_in_range && tx_this) r_tx_drop <= r_tx_drop + 32'd1;
          end
        end
      end
    end
  endgenerate

  // Registered read mux: data valid the clock after reg_rd_en; undefined
  // offsets read 0.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      reg_rd_data <= '0;
      if (!rd_sock) begin
        case (reg_rd_addr)
          REG_ID:            reg_rd_data <= CORE_ID;
          REG_VERSION:       reg_rd_data <= CORE_VERSION;
          REG_CAPS:          reg_rd_data <= CORE_CAPS;
          REG_CTRL:          reg_rd_data <= {31'd0, csum_check};
          REG_STATUS:        reg_rd_data <= status_word;
          REG_RX_NO_SOCKET:  reg_rd_data <= cnt_rx_no_socket;
          REG_RX_BAD:        reg_rd_data <= cnt_rx_bad;
          REG_RX_FIFO_DROPS: reg_rd_data <= cnt_rx_fifo_drops;
          REG_TX_FRAMES:     reg_rd_data <= cnt_tx_frames;
          REG_TX_DROPS:      reg_rd_data <= cnt_tx_drops;
          REG_RX_DATAGRAMS:  reg_rd_data <= cnt_rx_datagrams;
          default:           reg_rd_data <= '0;
        endcase
      end else if ((rd_sock_idx < 6'(NUM_SOCKETS)) && (reg_rd_addr[1:0] == 2'b00)) begin
        case (rd_field)
          SOCK_CTRL:          reg_rd_data <= {30'd0, sock_connect[rd_sock_idx], sock_enable[rd_sock_idx]};
          SOCK_LOCAL_PORT:    reg_rd_data <= {16'd0, sock_port[rd_sock_idx]};
          SOCK_REMOTE_IP:     reg_rd_data <= sock_remote_ip[rd_sock_idx];
          SOCK_REMOTE_PORT:   reg_rd_data <= {16'd0, sock_remote_port[rd_sock_idx]};
          SOCK_REMOTE_MAC_HI: reg_rd_data <= {16'd0, sock_remote_mac[rd_sock_idx][47:32]};
          SOCK_REMOTE_MAC_LO: reg_rd_data <= sock_remote_mac[rd_sock_idx][31:0];
          SOCK_RX_DATAGRAMS:  reg_rd_data <= cnt_sock_rx[rd_sock_idx];
          SOCK_RX_DROPS:      reg_rd_data <= cnt_sock_rx_drop[rd_sock_idx];
          SOCK_TX_DATAGRAMS:  reg_rd_data <= cnt_sock_tx[rd_sock_idx];
          SOCK_TX_DROPS:      reg_rd_data <= cnt_sock_tx_drop[rd_sock_idx];
          default:            reg_rd_data <= '0;
        endcase
      end
    end
  end

endmodule
