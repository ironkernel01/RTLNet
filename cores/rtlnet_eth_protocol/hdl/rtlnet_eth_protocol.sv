// -----------------------------------------------------------------------------
// File: rtlnet_eth_protocol.sv
// Purpose: the RTLNet protocol wrapper (documentation/rtlnet_architecture.md
//   sections 7.4, 7.5, 15.3, 15.4). It sits on the MAC client streams, keeps
//   the node address, filters by destination MAC, queues frames between the
//   MAC clock and the protocol clock, presents one frame at a time to every
//   protocol leaf and returns their replies to the MAC through a fixed-
//   priority, per-frame arbiter.
// Overview:
//   * axis_clk (MAC client, 62.5 MHz at 1G, 156.25/390.625 MHz at 10G/25G):
//     only the ingress block (input slice, destination-MAC filter, first-beat
//     drop decision, ingress counters; rtlnet_eth_protocol_ingress), the
//     ingress FIFO write side, the egress FIFO read side, the output slice
//     and the egress counter.
//   * proto_clk (50 MHz on the Nexys Video): the ingress FIFO read side, the
//     dequeue controller, the leaves, the arbiter and its slice, the egress
//     FIFO write side, the register file.
//       s_axis -> ingress (slice, filter F1..F4, drop) -> u_ingress_fifo
//       -> dequeue (S_GAP 16 clocks, S_WAIT no leaf busy, S_PASS one frame)
//       -> fan-out to every leaf -> arbiter (grant per frame, fixed priority)
//       -> u_arb_slice -> u_egress_fifo -> u_out_slice -> m_axis
//   * Leaves, fixed indices (also the arbiter priority, 0 highest) and
//     register windows (address[15:12]):
//       index 0 UDP socket (window 5), 1 ICMP (2), 2 ARP (1), 3 DHCP (3),
//       4 iperf (4); window 0 is the wrapper register file. Each leaf is
//       instanced under its *_ENABLE generate with the exact ports of 15.4; a
//       disabled branch ties the leaf's outputs to idle (tvalid 0, busy 0,
//       read data 0, s_axis_tready 1) and the application ports idle
//       (m_axis_app_tvalid 0, s_axis_app_tready 1).
//   * Queues: rtlnet_packet_fifo u_ingress_fifo (INGRESS_FIFO_KB, axis_clk to
//     proto_clk) and u_egress_fifo (EGRESS_FIFO_KB, proto_clk to axis_clk),
//     both DROP_WHEN_FULL = 0. The ingress drop is decided in axis_clk at a
//     frame's first beat (exact counter); a full egress queue back-pressures
//     the arbiter and so the leaves, nothing is lost.
//   * Address: the wrapper owns the node address as proto_clk registers
//     (rtlnet_eth_protocol_regs); the leaves read local_mac and the
//     effective local_ip / local_mask / local_gateway with no crossing. Only
//     the filter's copy of the MAC (and FILTER_ENABLE) crosses into axis_clk.
//   * Registers: s_axi (ADDR_W 16, s_axi_aclk) -> u_axil_cdc (to proto_clk)
//     -> u_axil_slave -> window decode. Leaf strobes are gated by window;
//     the read mux selects by the window registered at reg_rd_en and returns
//     0 for an absent leaf or an unused window.
//   * Counters INGRESS_FRAMES/FILTERED/DROPPED count in axis_clk (ingress
//     block), EGRESS_FRAMES at the m_axis last-beat handshake; each crosses
//     to proto_clk through rtlnet_gray_sync.
//   * Status outputs for LEDs (proto_clk, registered): stat_ip_valid (the
//     effective IP is not 0.0.0.0), stat_dhcp_bound (the effective IP is a
//     DHCP lease), ev_rx_frame (one clock per frame delivered to the
//     leaves), ev_tx_frame (one clock per frame written to the egress queue).
//   * Simulation-only check: every leaf holds s_axis_tready at 1 while a
//     beat is presented (the fan-out depends on it).
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks:
//   * axis_clk: MAC client streams; axis_resetn synchronous to it.
//   * proto_clk: leaves and register file; proto_resetn synchronous to it.
//   * app_clk: the UDP socket application streams; app_resetn synchronous.
//   * s_axi_aclk: AXI4-Lite slave; s_axi_aresetn synchronous to it.
//   All four resets derive from one assertion in the board top (the packet
//   FIFOs and rtlnet_axil_cdc require both sides to reset together).
// -----------------------------------------------------------------------------
module rtlnet_eth_protocol #(
  parameter int    PROTO_CLK_HZ    = 50_000_000,   // proto_clk frequency, Hz
  parameter int    INGRESS_FIFO_KB = 16,           // ingress queue, kilobytes
  parameter int    EGRESS_FIFO_KB  = 8,            // egress queue, kilobytes
  parameter int    ARP_ENABLE      = 1,
  parameter int    ICMP_ENABLE     = 1,
  parameter int    DHCP_ENABLE     = 1,
  parameter int    IPERF_ENABLE    = 1,
  parameter int    UDP_ENABLE      = 1,
  parameter int    ICMP_BUF_KB     = 2,
  parameter int    DHCP_BUF_KB     = 1,
  parameter int    IPERF_PORT      = 5001,
  parameter int    NUM_SOCKETS     = 4,
  parameter int    UDP_RX_BUF_KB   = 16,
  parameter int    UDP_TX_BUF_KB   = 8,
  parameter string RAM_STYLE       = "block"       // "block" | "distributed", every buffer
)(
  // Clocks: axis_clk (MAC client), proto_clk (leaves, registers), app_clk
  // (socket application streams), s_axi_aclk (AXI4-Lite, cpu_clk).
  input  logic        axis_clk,
  input  logic        proto_clk,
  input  logic        app_clk,
  input  logic        s_axi_aclk,

  // Resets, synchronous active low, one per clock, from one assertion.
  input  logic        axis_resetn,
  input  logic        proto_resetn,
  input  logic        app_resetn,
  input  logic        s_axi_aresetn,

  // From MAC RX, axis_clk, RTLNet stream; s_axis_tready is a flop and never
  // back-pressures (a full ingress queue drops whole frames and counts them).
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // To MAC TX, axis_clk, RTLNet stream: whole frames from the egress queue,
  // the outputs of one register slice; m_axis_tready may stall at any time.
  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  // Application RX, socket payload out (app_clk): two metadata beats and the
  // payload (architecture 7.7), from the UDP socket leaf.
  output logic [63:0] m_axis_app_tdata,
  output logic [7:0]  m_axis_app_tkeep,
  output logic        m_axis_app_tvalid,
  output logic        m_axis_app_tlast,
  input  logic        m_axis_app_tready,

  // Application TX, socket payload in (app_clk), to the UDP socket leaf.
  input  logic [63:0] s_axis_app_tdata,
  input  logic [7:0]  s_axis_app_tkeep,
  input  logic        s_axis_app_tvalid,
  input  logic        s_axis_app_tlast,
  output logic        s_axis_app_tready,

  // AXI4-Lite slave, s_axi_aclk, 32-bit data, 16-bit byte address (the 64 KiB
  // protocol sub-map of architecture 6.1).
  input  logic [15:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [15:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // Status for LEDs only, proto_clk, registered (levels and one-clock events).
  output logic        stat_ip_valid,
  output logic        stat_dhcp_bound,
  output logic        ev_rx_frame,
  output logic        ev_tx_frame
);

  import rtlnet_pkg::*;

  // ---------------------------------------------------------------------------
  // Leaf table: index = arbiter priority (0 highest), fixed whatever is enabled.
  // ---------------------------------------------------------------------------
  localparam int         N_LEAVES     = 5;
  localparam int         LEAF_UDP     = 0;
  localparam int         LEAF_ICMP    = 1;
  localparam int         LEAF_ARP     = 2;
  localparam int         LEAF_DHCP    = 3;
  localparam int         LEAF_IPERF   = 4;
  // Register windows, address[15:12].
  localparam logic [3:0] WIN_WRAPPER  = 4'd0;
  localparam logic [3:0] WIN_ARP      = 4'd1;
  localparam logic [3:0] WIN_ICMP     = 4'd2;
  localparam logic [3:0] WIN_DHCP     = 4'd3;
  localparam logic [3:0] WIN_IPERF    = 4'd4;
  localparam logic [3:0] WIN_UDP      = 4'd5;
  localparam logic [4:0] LEAF_PRESENT = {(IPERF_ENABLE != 0), (DHCP_ENABLE != 0), (ARP_ENABLE != 0),
                                         (ICMP_ENABLE != 0), (UDP_ENABLE != 0)};
  // Derived leaf parameters (15.4): ARP reply delay 25 us, DHCP millisecond tick.
  localparam int         ARP_REPLY_DELAY_CYCLES = PROTO_CLK_HZ / 40_000;
  localparam int         DHCP_MS_CYCLES         = PROTO_CLK_HZ / 1_000;
  localparam int         IPERF_MAX_DGRAM_BYTES  = 1472;
  // Dequeue gap: at least the 12-clock busy rule of 7.5, with margin.
  localparam int         FRAME_GAP_CYCLES       = 16;
  localparam int         GAP_W                  = 5;
  localparam logic [GAP_W-1:0] GAP_RELOAD       = FRAME_GAP_CYCLES - 1;

  localparam logic [1:0] DQ_GAP  = 2'd0;
  localparam logic [1:0] DQ_WAIT = 2'd1;
  localparam logic [1:0] DQ_PASS = 2'd2;

  // ---------------------------------------------------------------------------
  // Signals.
  // ---------------------------------------------------------------------------
  // Ingress (axis_clk) and the ingress queue.
  logic [63:0]            ing_data;
  logic [7:0]             ing_keep;
  logic                   ing_last;
  logic                   ing_valid;
  logic                   ing_ready;
  logic [31:0]            ax_cnt_frames;
  logic [31:0]            ax_cnt_filtered;
  logic [31:0]            ax_cnt_dropped;
  logic [31:0]            ax_cnt_egress;
  logic [63:0]            iq_data;
  logic [7:0]             iq_keep;
  logic                   iq_valid;
  logic                   iq_last;
  logic                   iq_ready;

  // Egress queue.
  logic [63:0]            eq_s_data;
  logic [7:0]             eq_s_keep;
  logic                   eq_s_valid;
  logic                   eq_s_last;
  logic                   eq_s_ready;
  logic [63:0]            eq_m_data;
  logic [7:0]             eq_m_keep;
  logic                   eq_m_valid;
  logic                   eq_m_last;
  logic                   eq_m_ready;

  // Counter copies in proto_clk.
  logic [31:0]            pr_cnt_frames;
  logic [31:0]            pr_cnt_filtered;
  logic [31:0]            pr_cnt_dropped;
  logic [31:0]            pr_cnt_egress;

  // Dequeue controller and the leaf fan-out.
  logic [1:0]             dq_state;
  logic [GAP_W-1:0]       gap_count;
  logic                   leaf_in_tvalid;

  // Leaf vectors, packed by leaf index. Nets: each slice is driven by its own
  // leaf instance or by the tie-offs of a disabled leaf.
  wire  [N_LEAVES*64-1:0] leaf_tdata;
  wire  [N_LEAVES*8-1:0]  leaf_tkeep;
  wire  [N_LEAVES-1:0]    leaf_tvalid;
  wire  [N_LEAVES-1:0]    leaf_tlast;
  logic [N_LEAVES-1:0]    leaf_tready;
  wire  [N_LEAVES-1:0]    leaf_s_tready;
  wire  [N_LEAVES-1:0]    leaf_busy;
  logic [N_LEAVES-1:0]    leaf_enable;
  wire  [N_LEAVES-1:0]    leaf_reg_wr_en;
  wire  [N_LEAVES-1:0]    leaf_reg_rd_en;
  wire  [N_LEAVES*32-1:0] leaf_rd_data;

  // Node address (proto_clk registers of the register file).
  logic [47:0]            local_mac;
  logic [31:0]            local_ip;
  logic [31:0]            local_mask;
  logic [31:0]            local_gateway;
  logic                   ip_from_dhcp;
  logic                   filter_enable;

  // DHCP lease (proto_clk, from the DHCP leaf; 0 without it).
  logic                   lease_valid;
  logic [31:0]            lease_ip;
  logic [31:0]            lease_mask;
  logic [31:0]            lease_router;
  logic [31:0]            lease_server;
  logic [31:0]            lease_time_s;

  // Arbiter.
  logic [N_LEAVES:0]      grant;               // bit 0 idle, bit i+1 leaf i
  logic [N_LEAVES:0]      pick;
  logic [N_LEAVES-1:0]    gnt;
  logic                   last_taken;
  logic                   arb_s_ready;
  logic [63:0]            sel_tdata;
  logic [7:0]             sel_tkeep;
  logic                   sel_tvalid;
  logic                   sel_tlast;

  // Register path (proto_clk side of the crossing).
  logic [15:0]            p_awaddr;
  logic                   p_awvalid;
  logic                   p_awready;
  logic [31:0]            p_wdata;
  logic [3:0]             p_wstrb;
  logic                   p_wvalid;
  logic                   p_wready;
  logic [1:0]             p_bresp;
  logic                   p_bvalid;
  logic                   p_bready;
  logic [15:0]            p_araddr;
  logic                   p_arvalid;
  logic                   p_arready;
  logic [31:0]            p_rdata;
  logic [1:0]             p_rresp;
  logic                   p_rvalid;
  logic                   p_rready;
  logic                   reg_wr_en;
  logic [15:0]            reg_wr_addr;
  logic [31:0]            reg_wr_data;
  logic                   reg_rd_en;
  logic [15:0]            reg_rd_addr;
  logic [31:0]            reg_rd_data;
  logic [3:0]             rd_window;
  logic                   wrap_reg_wr_en;
  logic                   wrap_reg_rd_en;
  logic [31:0]            wrap_rd_data;

  // Status flags (proto_clk, registered).
  logic                   st_ingress_pending;
  logic                   st_egress_full;
  logic                   st_delivering;
  logic                   st_arbiter_active;

  // ===========================================================================
  // axis_clk: ingress block, queues' fast sides, output slice, egress counter.
  // ===========================================================================

  // Input slice, destination-MAC filter, first-beat drop and ingress counters.
  rtlnet_eth_protocol_ingress #(
    .MAX_FRAME_BYTES (ETH_MAX_FRAME_BYTES)
  ) u_ingress (
    .clk               (axis_clk),
    .resetn            (axis_resetn),
    .s_axis_tdata      (s_axis_tdata),
    .s_axis_tkeep      (s_axis_tkeep),
    .s_axis_tvalid     (s_axis_tvalid),
    .s_axis_tlast      (s_axis_tlast),
    .s_axis_tready     (s_axis_tready),
    .cfg_local_mac     (local_mac),
    .cfg_filter_enable (filter_enable),
    .fifo_data         (ing_data),
    .fifo_keep         (ing_keep),
    .fifo_last         (ing_last),
    .fifo_valid        (ing_valid),
    .fifo_ready        (ing_ready),
    .cnt_frames        (ax_cnt_frames),
    .cnt_filtered      (ax_cnt_filtered),
    .cnt_dropped       (ax_cnt_dropped)
  );

  // Ingress queue, axis_clk -> proto_clk, whole frames (instance name used by
  // the CDC constraint script).
  rtlnet_packet_fifo #(
    .RAM_STYLE       (RAM_STYLE),
    .FIFO_KB         (INGRESS_FIFO_KB),
    .MAX_FRAME_BYTES (ETH_MAX_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_ingress_fifo (
    .s_clk     (axis_clk),
    .s_resetn  (axis_resetn),
    .s_data    (ing_data),
    .s_keep    (ing_keep),
    .s_valid   (ing_valid),
    .s_ready   (ing_ready),
    .s_last    (ing_last),
    .s_bad     (1'b0),
    .m_clk     (proto_clk),
    .m_resetn  (proto_resetn),
    .m_data    (iq_data),
    .m_keep    (iq_keep),
    .m_valid   (iq_valid),
    .m_ready   (iq_ready),
    .m_last    (iq_last),
    .overflow  (),
    .bad_frame ()
  );

  // Egress queue, proto_clk -> axis_clk; never drops (back-pressures the arbiter).
  rtlnet_packet_fifo #(
    .RAM_STYLE       (RAM_STYLE),
    .FIFO_KB         (EGRESS_FIFO_KB),
    .MAX_FRAME_BYTES (ETH_MAX_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_egress_fifo (
    .s_clk     (proto_clk),
    .s_resetn  (proto_resetn),
    .s_data    (eq_s_data),
    .s_keep    (eq_s_keep),
    .s_valid   (eq_s_valid),
    .s_ready   (eq_s_ready),
    .s_last    (eq_s_last),
    .s_bad     (1'b0),
    .m_clk     (axis_clk),
    .m_resetn  (axis_resetn),
    .m_data    (eq_m_data),
    .m_keep    (eq_m_keep),
    .m_valid   (eq_m_valid),
    .m_ready   (eq_m_ready),
    .m_last    (eq_m_last),
    .overflow  (),
    .bad_frame ()
  );

  // Output slice: registered beat to the MAC, registered ready to the queue.
  rtlnet_axis_reg_slice #(
    .DATA_W     (64),
    .RESET_DATA (1'b1)
  ) u_out_slice (
    .clk      (axis_clk),
    .resetn   (axis_resetn),
    .s_tdata  (eq_m_data),
    .s_tkeep  (eq_m_keep),
    .s_tlast  (eq_m_last),
    .s_tvalid (eq_m_valid),
    .s_tready (eq_m_ready),
    .m_tdata  (m_axis_tdata),
    .m_tkeep  (m_axis_tkeep),
    .m_tlast  (m_axis_tlast),
    .m_tvalid (m_axis_tvalid),
    .m_tready (m_axis_tready)
  );

  // Egress frame counter: one per frame accepted by the MAC.
  always_ff @(posedge axis_clk) begin
    if (!axis_resetn)                                     ax_cnt_egress <= '0;
    else if (m_axis_tvalid && m_axis_tready && m_axis_tlast) ax_cnt_egress <= ax_cnt_egress + 1'b1;
  end

  // The four counters cross to proto_clk as Gray codes (each steps by at most
  // one per axis_clk).
  rtlnet_gray_sync #(.WIDTH(32), .STAGES(2)) u_cnt_frames_sync (
    .src_clk(axis_clk), .src_resetn(axis_resetn), .src_count(ax_cnt_frames),
    .dst_clk(proto_clk), .dst_resetn(proto_resetn), .dst_count(pr_cnt_frames));
  rtlnet_gray_sync #(.WIDTH(32), .STAGES(2)) u_cnt_filtered_sync (
    .src_clk(axis_clk), .src_resetn(axis_resetn), .src_count(ax_cnt_filtered),
    .dst_clk(proto_clk), .dst_resetn(proto_resetn), .dst_count(pr_cnt_filtered));
  rtlnet_gray_sync #(.WIDTH(32), .STAGES(2)) u_cnt_dropped_sync (
    .src_clk(axis_clk), .src_resetn(axis_resetn), .src_count(ax_cnt_dropped),
    .dst_clk(proto_clk), .dst_resetn(proto_resetn), .dst_count(pr_cnt_dropped));
  rtlnet_gray_sync #(.WIDTH(32), .STAGES(2)) u_cnt_egress_sync (
    .src_clk(axis_clk), .src_resetn(axis_resetn), .src_count(ax_cnt_egress),
    .dst_clk(proto_clk), .dst_resetn(proto_resetn), .dst_count(pr_cnt_egress));

  // ===========================================================================
  // proto_clk: dequeue controller.
  //   DQ_GAP   FRAME_GAP_CYCLES idle clocks after each frame and after reset
  //   DQ_WAIT  until no leaf is busy
  //   DQ_PASS  one frame to every leaf; back to DQ_GAP after its last beat
  // ===========================================================================
  always_ff @(posedge proto_clk) begin
    if (!proto_resetn) begin
      dq_state  <= DQ_GAP;
      gap_count <= GAP_RELOAD;
    end else begin
      case (dq_state)
        DQ_GAP: begin
          if (gap_count == '0) dq_state  <= DQ_WAIT;
          else                 gap_count <= gap_count - 1'b1;
        end
        DQ_WAIT: begin
          if (!(|leaf_busy)) dq_state <= DQ_PASS;
        end
        DQ_PASS: begin
          if (iq_valid && iq_last) begin
            dq_state  <= DQ_GAP;
            gap_count <= GAP_RELOAD;
          end
        end
        default: begin
          dq_state  <= DQ_GAP;
          gap_count <= GAP_RELOAD;
        end
      endcase
    end
  end

  assign iq_ready       = (dq_state == DQ_PASS);
  assign leaf_in_tvalid = iq_valid && iq_ready;

  // ===========================================================================
  // proto_clk: register path. AXI4-Lite crosses from s_axi_aclk once, then a
  // 16-bit register-strobe bridge and the window decode.
  // ===========================================================================
  rtlnet_axil_cdc #(
    .ADDR_W (16),
    .STAGES (3)
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
    .m_clk         (proto_clk),
    .m_resetn      (proto_resetn),
    .m_axi_awaddr  (p_awaddr),
    .m_axi_awvalid (p_awvalid),
    .m_axi_awready (p_awready),
    .m_axi_wdata   (p_wdata),
    .m_axi_wstrb   (p_wstrb),
    .m_axi_wvalid  (p_wvalid),
    .m_axi_wready  (p_wready),
    .m_axi_bresp   (p_bresp),
    .m_axi_bvalid  (p_bvalid),
    .m_axi_bready  (p_bready),
    .m_axi_araddr  (p_araddr),
    .m_axi_arvalid (p_arvalid),
    .m_axi_arready (p_arready),
    .m_axi_rdata   (p_rdata),
    .m_axi_rresp   (p_rresp),
    .m_axi_rvalid  (p_rvalid),
    .m_axi_rready  (p_rready)
  );

  // AXI4-Lite to one-clock register strobes in proto_clk.
  rtlnet_axil_slave #(
    .ADDR_W (16)
  ) u_axil_slave (
    .s_axi_aclk    (proto_clk),
    .s_axi_aresetn (proto_resetn),
    .s_axi_awaddr  (p_awaddr),
    .s_axi_awvalid (p_awvalid),
    .s_axi_awready (p_awready),
    .s_axi_wdata   (p_wdata),
    .s_axi_wstrb   (p_wstrb),
    .s_axi_wvalid  (p_wvalid),
    .s_axi_wready  (p_wready),
    .s_axi_bresp   (p_bresp),
    .s_axi_bvalid  (p_bvalid),
    .s_axi_bready  (p_bready),
    .s_axi_araddr  (p_araddr),
    .s_axi_arvalid (p_arvalid),
    .s_axi_arready (p_arready),
    .s_axi_rdata   (p_rdata),
    .s_axi_rresp   (p_rresp),
    .s_axi_rvalid  (p_rvalid),
    .s_axi_rready  (p_rready),
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data)
  );

  // Window decode: one strobe per register file.
  assign wrap_reg_wr_en             = reg_wr_en && (reg_wr_addr[15:12] == WIN_WRAPPER);
  assign wrap_reg_rd_en             = reg_rd_en && (reg_rd_addr[15:12] == WIN_WRAPPER);
  assign leaf_reg_wr_en[LEAF_UDP]   = reg_wr_en && (reg_wr_addr[15:12] == WIN_UDP);
  assign leaf_reg_wr_en[LEAF_ICMP]  = reg_wr_en && (reg_wr_addr[15:12] == WIN_ICMP);
  assign leaf_reg_wr_en[LEAF_ARP]   = reg_wr_en && (reg_wr_addr[15:12] == WIN_ARP);
  assign leaf_reg_wr_en[LEAF_DHCP]  = reg_wr_en && (reg_wr_addr[15:12] == WIN_DHCP);
  assign leaf_reg_wr_en[LEAF_IPERF] = reg_wr_en && (reg_wr_addr[15:12] == WIN_IPERF);
  assign leaf_reg_rd_en[LEAF_UDP]   = reg_rd_en && (reg_rd_addr[15:12] == WIN_UDP);
  assign leaf_reg_rd_en[LEAF_ICMP]  = reg_rd_en && (reg_rd_addr[15:12] == WIN_ICMP);
  assign leaf_reg_rd_en[LEAF_ARP]   = reg_rd_en && (reg_rd_addr[15:12] == WIN_ARP);
  assign leaf_reg_rd_en[LEAF_DHCP]  = reg_rd_en && (reg_rd_addr[15:12] == WIN_DHCP);
  assign leaf_reg_rd_en[LEAF_IPERF] = reg_rd_en && (reg_rd_addr[15:12] == WIN_IPERF);

  // The window of the read in flight, registered with the register files' muxes.
  always_ff @(posedge proto_clk) begin
    if (!proto_resetn)  rd_window <= WIN_WRAPPER;
    else if (reg_rd_en) rd_window <= reg_rd_addr[15:12];
  end

  // Read data: the selected file's registered output (an absent leaf reads 0).
  always_comb begin
    case (rd_window)
      WIN_WRAPPER: reg_rd_data = wrap_rd_data;
      WIN_ARP:     reg_rd_data = leaf_rd_data[LEAF_ARP*32 +: 32];
      WIN_ICMP:    reg_rd_data = leaf_rd_data[LEAF_ICMP*32 +: 32];
      WIN_DHCP:    reg_rd_data = leaf_rd_data[LEAF_DHCP*32 +: 32];
      WIN_IPERF:   reg_rd_data = leaf_rd_data[LEAF_IPERF*32 +: 32];
      WIN_UDP:     reg_rd_data = leaf_rd_data[LEAF_UDP*32 +: 32];
      default:     reg_rd_data = '0;
    endcase
  end

  // Status flags for the STATUS register.
  always_ff @(posedge proto_clk) begin
    if (!proto_resetn) begin
      st_ingress_pending <= 1'b0;
      st_egress_full     <= 1'b0;
      st_delivering      <= 1'b0;
      st_arbiter_active  <= 1'b0;
    end else begin
      st_ingress_pending <= iq_valid;
      st_egress_full     <= !eq_s_ready;
      st_delivering      <= leaf_in_tvalid;
      st_arbiter_active  <= !grant[0];
    end
  end

  // Wrapper register file: node address, CTRL, STATUS, counters.
  rtlnet_eth_protocol_regs #(
    .LEAF_PRESENT    (LEAF_PRESENT),
    .INGRESS_FIFO_KB (INGRESS_FIFO_KB),
    .EGRESS_FIFO_KB  (EGRESS_FIFO_KB),
    .NUM_SOCKETS     (NUM_SOCKETS)
  ) u_regs (
    .clk                  (proto_clk),
    .resetn               (proto_resetn),
    .reg_wr_en            (wrap_reg_wr_en),
    .reg_wr_addr          (reg_wr_addr[11:0]),
    .reg_wr_data          (reg_wr_data),
    .reg_rd_en            (wrap_reg_rd_en),
    .reg_rd_addr          (reg_rd_addr[11:0]),
    .reg_rd_data          (wrap_rd_data),
    .lease_valid          (lease_valid),
    .lease_ip             (lease_ip),
    .lease_mask           (lease_mask),
    .lease_router         (lease_router),
    .leaf_busy            (leaf_busy),
    .ingress_pending      (st_ingress_pending),
    .egress_full          (st_egress_full),
    .delivering           (st_delivering),
    .arbiter_active       (st_arbiter_active),
    .cnt_ingress_frames   (pr_cnt_frames),
    .cnt_ingress_filtered (pr_cnt_filtered),
    .cnt_ingress_dropped  (pr_cnt_dropped),
    .cnt_egress_frames    (pr_cnt_egress),
    .local_mac            (local_mac),
    .effective_ip         (local_ip),
    .effective_mask       (local_mask),
    .effective_gateway    (local_gateway),
    .ip_from_dhcp         (ip_from_dhcp),
    .filter_enable        (filter_enable),
    .leaf_enable          (leaf_enable)
  );

  // ===========================================================================
  // proto_clk: the leaves (architecture 15.4), one generate per enable.
  // ===========================================================================

  // Leaf 0: UDP socket layer, with the application streams and the effective
  // mask and gateway.
  generate
    if (UDP_ENABLE != 0) begin : g_udp
      rtlnet_udp_socket #(
        .NUM_SOCKETS   (NUM_SOCKETS),
        .UDP_RX_BUF_KB (UDP_RX_BUF_KB),
        .UDP_TX_BUF_KB (UDP_TX_BUF_KB),
        .RAM_STYLE     (RAM_STYLE)
      ) u_udp_socket (
        .clk               (proto_clk),
        .resetn            (proto_resetn),
        .enable            (leaf_enable[LEAF_UDP]),
        .s_axis_tdata      (iq_data),
        .s_axis_tkeep      (iq_keep),
        .s_axis_tvalid     (leaf_in_tvalid),
        .s_axis_tlast      (iq_last),
        .s_axis_tready     (leaf_s_tready[LEAF_UDP]),
        .m_axis_tdata      (leaf_tdata[LEAF_UDP*64 +: 64]),
        .m_axis_tkeep      (leaf_tkeep[LEAF_UDP*8 +: 8]),
        .m_axis_tvalid     (leaf_tvalid[LEAF_UDP]),
        .m_axis_tlast      (leaf_tlast[LEAF_UDP]),
        .m_axis_tready     (leaf_tready[LEAF_UDP]),
        .local_mac         (local_mac),
        .local_ip          (local_ip),
        .busy              (leaf_busy[LEAF_UDP]),
        .reg_wr_en         (leaf_reg_wr_en[LEAF_UDP]),
        .reg_wr_addr       (reg_wr_addr[11:0]),
        .reg_wr_data       (reg_wr_data),
        .reg_rd_en         (leaf_reg_rd_en[LEAF_UDP]),
        .reg_rd_addr       (reg_rd_addr[11:0]),
        .reg_rd_data       (leaf_rd_data[LEAF_UDP*32 +: 32]),
        .app_clk           (app_clk),
        .app_resetn        (app_resetn),
        .m_axis_app_tdata  (m_axis_app_tdata),
        .m_axis_app_tkeep  (m_axis_app_tkeep),
        .m_axis_app_tvalid (m_axis_app_tvalid),
        .m_axis_app_tlast  (m_axis_app_tlast),
        .m_axis_app_tready (m_axis_app_tready),
        .s_axis_app_tdata  (s_axis_app_tdata),
        .s_axis_app_tkeep  (s_axis_app_tkeep),
        .s_axis_app_tvalid (s_axis_app_tvalid),
        .s_axis_app_tlast  (s_axis_app_tlast),
        .s_axis_app_tready (s_axis_app_tready),
        .local_mask        (local_mask),
        .local_gateway     (local_gateway)
      );
    end else begin : g_no_udp
      assign leaf_tdata[LEAF_UDP*64 +: 64]   = '0;
      assign leaf_tkeep[LEAF_UDP*8 +: 8]     = '0;
      assign leaf_tvalid[LEAF_UDP]           = 1'b0;
      assign leaf_tlast[LEAF_UDP]            = 1'b0;
      assign leaf_s_tready[LEAF_UDP]         = 1'b1;
      assign leaf_busy[LEAF_UDP]             = 1'b0;
      assign leaf_rd_data[LEAF_UDP*32 +: 32] = '0;
      assign m_axis_app_tdata                = '0;
      assign m_axis_app_tkeep                = '0;
      assign m_axis_app_tvalid               = 1'b0;
      assign m_axis_app_tlast                = 1'b0;
      assign s_axis_app_tready               = 1'b1;
    end
  endgenerate

  // Leaf 1: ICMP echo responder.
  generate
    if (ICMP_ENABLE != 0) begin : g_icmp
      rtlnet_icmp #(
        .ICMP_BUF_KB (ICMP_BUF_KB),
        .RAM_STYLE   (RAM_STYLE)
      ) u_icmp (
        .clk           (proto_clk),
        .resetn        (proto_resetn),
        .enable        (leaf_enable[LEAF_ICMP]),
        .s_axis_tdata  (iq_data),
        .s_axis_tkeep  (iq_keep),
        .s_axis_tvalid (leaf_in_tvalid),
        .s_axis_tlast  (iq_last),
        .s_axis_tready (leaf_s_tready[LEAF_ICMP]),
        .m_axis_tdata  (leaf_tdata[LEAF_ICMP*64 +: 64]),
        .m_axis_tkeep  (leaf_tkeep[LEAF_ICMP*8 +: 8]),
        .m_axis_tvalid (leaf_tvalid[LEAF_ICMP]),
        .m_axis_tlast  (leaf_tlast[LEAF_ICMP]),
        .m_axis_tready (leaf_tready[LEAF_ICMP]),
        .local_mac     (local_mac),
        .local_ip      (local_ip),
        .busy          (leaf_busy[LEAF_ICMP]),
        .reg_wr_en     (leaf_reg_wr_en[LEAF_ICMP]),
        .reg_wr_addr   (reg_wr_addr[11:0]),
        .reg_wr_data   (reg_wr_data),
        .reg_rd_en     (leaf_reg_rd_en[LEAF_ICMP]),
        .reg_rd_addr   (reg_rd_addr[11:0]),
        .reg_rd_data   (leaf_rd_data[LEAF_ICMP*32 +: 32])
      );
    end else begin : g_no_icmp
      assign leaf_tdata[LEAF_ICMP*64 +: 64]   = '0;
      assign leaf_tkeep[LEAF_ICMP*8 +: 8]     = '0;
      assign leaf_tvalid[LEAF_ICMP]           = 1'b0;
      assign leaf_tlast[LEAF_ICMP]            = 1'b0;
      assign leaf_s_tready[LEAF_ICMP]         = 1'b1;
      assign leaf_busy[LEAF_ICMP]             = 1'b0;
      assign leaf_rd_data[LEAF_ICMP*32 +: 32] = '0;
    end
  endgenerate

  // Leaf 2: ARP responder (reply delay 25 us of proto_clk).
  generate
    if (ARP_ENABLE != 0) begin : g_arp
      rtlnet_arp #(
        .REPLY_DELAY_CYCLES (ARP_REPLY_DELAY_CYCLES)
      ) u_arp (
        .clk           (proto_clk),
        .resetn        (proto_resetn),
        .enable        (leaf_enable[LEAF_ARP]),
        .s_axis_tdata  (iq_data),
        .s_axis_tkeep  (iq_keep),
        .s_axis_tvalid (leaf_in_tvalid),
        .s_axis_tlast  (iq_last),
        .s_axis_tready (leaf_s_tready[LEAF_ARP]),
        .m_axis_tdata  (leaf_tdata[LEAF_ARP*64 +: 64]),
        .m_axis_tkeep  (leaf_tkeep[LEAF_ARP*8 +: 8]),
        .m_axis_tvalid (leaf_tvalid[LEAF_ARP]),
        .m_axis_tlast  (leaf_tlast[LEAF_ARP]),
        .m_axis_tready (leaf_tready[LEAF_ARP]),
        .local_mac     (local_mac),
        .local_ip      (local_ip),
        .busy          (leaf_busy[LEAF_ARP]),
        .reg_wr_en     (leaf_reg_wr_en[LEAF_ARP]),
        .reg_wr_addr   (reg_wr_addr[11:0]),
        .reg_wr_data   (reg_wr_data),
        .reg_rd_en     (leaf_reg_rd_en[LEAF_ARP]),
        .reg_rd_addr   (reg_rd_addr[11:0]),
        .reg_rd_data   (leaf_rd_data[LEAF_ARP*32 +: 32])
      );
    end else begin : g_no_arp
      assign leaf_tdata[LEAF_ARP*64 +: 64]   = '0;
      assign leaf_tkeep[LEAF_ARP*8 +: 8]     = '0;
      assign leaf_tvalid[LEAF_ARP]           = 1'b0;
      assign leaf_tlast[LEAF_ARP]            = 1'b0;
      assign leaf_s_tready[LEAF_ARP]         = 1'b1;
      assign leaf_busy[LEAF_ARP]             = 1'b0;
      assign leaf_rd_data[LEAF_ARP*32 +: 32] = '0;
    end
  endgenerate

  // Leaf 3: DHCP client, with the lease outputs that drive the effective address.
  generate
    if (DHCP_ENABLE != 0) begin : g_dhcp
      rtlnet_dhcp #(
        .MS_CYCLES   (DHCP_MS_CYCLES),
        .DHCP_BUF_KB (DHCP_BUF_KB),
        .RAM_STYLE   (RAM_STYLE)
      ) u_dhcp (
        .clk           (proto_clk),
        .resetn        (proto_resetn),
        .enable        (leaf_enable[LEAF_DHCP]),
        .s_axis_tdata  (iq_data),
        .s_axis_tkeep  (iq_keep),
        .s_axis_tvalid (leaf_in_tvalid),
        .s_axis_tlast  (iq_last),
        .s_axis_tready (leaf_s_tready[LEAF_DHCP]),
        .m_axis_tdata  (leaf_tdata[LEAF_DHCP*64 +: 64]),
        .m_axis_tkeep  (leaf_tkeep[LEAF_DHCP*8 +: 8]),
        .m_axis_tvalid (leaf_tvalid[LEAF_DHCP]),
        .m_axis_tlast  (leaf_tlast[LEAF_DHCP]),
        .m_axis_tready (leaf_tready[LEAF_DHCP]),
        .local_mac     (local_mac),
        .local_ip      (local_ip),
        .busy          (leaf_busy[LEAF_DHCP]),
        .reg_wr_en     (leaf_reg_wr_en[LEAF_DHCP]),
        .reg_wr_addr   (reg_wr_addr[11:0]),
        .reg_wr_data   (reg_wr_data),
        .reg_rd_en     (leaf_reg_rd_en[LEAF_DHCP]),
        .reg_rd_addr   (reg_rd_addr[11:0]),
        .reg_rd_data   (leaf_rd_data[LEAF_DHCP*32 +: 32]),
        .lease_valid   (lease_valid),
        .lease_ip      (lease_ip),
        .lease_mask    (lease_mask),
        .lease_router  (lease_router),
        .lease_server  (lease_server),
        .lease_time_s  (lease_time_s)
      );
    end else begin : g_no_dhcp
      assign leaf_tdata[LEAF_DHCP*64 +: 64]   = '0;
      assign leaf_tkeep[LEAF_DHCP*8 +: 8]     = '0;
      assign leaf_tvalid[LEAF_DHCP]           = 1'b0;
      assign leaf_tlast[LEAF_DHCP]            = 1'b0;
      assign leaf_s_tready[LEAF_DHCP]         = 1'b1;
      assign leaf_busy[LEAF_DHCP]             = 1'b0;
      assign leaf_rd_data[LEAF_DHCP*32 +: 32] = '0;
      assign lease_valid                      = 1'b0;
      assign lease_ip                         = '0;
      assign lease_mask                       = '0;
      assign lease_router                     = '0;
      assign lease_server                     = '0;
      assign lease_time_s                     = '0;
    end
  endgenerate

  // Leaf 4: iperf 2 UDP server.
  generate
    if (IPERF_ENABLE != 0) begin : g_iperf
      rtlnet_iperf #(
        .CLK_HZ          (PROTO_CLK_HZ),
        .UDP_PORT        (IPERF_PORT),
        .MAX_DGRAM_BYTES (IPERF_MAX_DGRAM_BYTES)
      ) u_iperf (
        .clk           (proto_clk),
        .resetn        (proto_resetn),
        .enable        (leaf_enable[LEAF_IPERF]),
        .s_axis_tdata  (iq_data),
        .s_axis_tkeep  (iq_keep),
        .s_axis_tvalid (leaf_in_tvalid),
        .s_axis_tlast  (iq_last),
        .s_axis_tready (leaf_s_tready[LEAF_IPERF]),
        .m_axis_tdata  (leaf_tdata[LEAF_IPERF*64 +: 64]),
        .m_axis_tkeep  (leaf_tkeep[LEAF_IPERF*8 +: 8]),
        .m_axis_tvalid (leaf_tvalid[LEAF_IPERF]),
        .m_axis_tlast  (leaf_tlast[LEAF_IPERF]),
        .m_axis_tready (leaf_tready[LEAF_IPERF]),
        .local_mac     (local_mac),
        .local_ip      (local_ip),
        .busy          (leaf_busy[LEAF_IPERF]),
        .reg_wr_en     (leaf_reg_wr_en[LEAF_IPERF]),
        .reg_wr_addr   (reg_wr_addr[11:0]),
        .reg_wr_data   (reg_wr_data),
        .reg_rd_en     (leaf_reg_rd_en[LEAF_IPERF]),
        .reg_rd_addr   (reg_rd_addr[11:0]),
        .reg_rd_data   (leaf_rd_data[LEAF_IPERF*32 +: 32])
      );
    end else begin : g_no_iperf
      assign leaf_tdata[LEAF_IPERF*64 +: 64]   = '0;
      assign leaf_tkeep[LEAF_IPERF*8 +: 8]     = '0;
      assign leaf_tvalid[LEAF_IPERF]           = 1'b0;
      assign leaf_tlast[LEAF_IPERF]            = 1'b0;
      assign leaf_s_tready[LEAF_IPERF]         = 1'b1;
      assign leaf_busy[LEAF_IPERF]             = 1'b0;
      assign leaf_rd_data[LEAF_IPERF*32 +: 32] = '0;
    end
  endgenerate

  // ===========================================================================
  // proto_clk: arbiter. grant is one-hot (bit 0 idle, bit i+1 leaf i). At idle
  // the lowest-index leaf with a registered tvalid is granted; the grant holds
  // until that leaf's last beat is accepted (no preemption), then returns to
  // idle for one clock. Only the granted leaf sees ready.
  // ===========================================================================
  always_comb begin
    pick    = '0;
    pick[0] = 1'b1;
    for (int i = N_LEAVES - 1; i >= 0; i--) begin
      if (leaf_tvalid[i]) begin
        pick      = '0;
        pick[i+1] = 1'b1;
      end
    end
  end

  assign gnt        = grant[N_LEAVES:1];
  assign last_taken = (|(gnt & leaf_tvalid & leaf_tlast)) && arb_s_ready;

  always_ff @(posedge proto_clk) begin
    if (!proto_resetn) begin
      grant    <= '0;
      grant[0] <= 1'b1;
    end else if (grant[0]) begin
      grant <= pick;
    end else if (last_taken || !(|gnt)) begin
      grant    <= '0;
      grant[0] <= 1'b1;
    end
  end

  assign leaf_tready = gnt & {N_LEAVES{arb_s_ready}};

  // Output mux: AND-OR over the granted leaf.
  always_comb begin
    sel_tdata  = '0;
    sel_tkeep  = '0;
    sel_tvalid = 1'b0;
    sel_tlast  = 1'b0;
    for (int i = 0; i < N_LEAVES; i++) begin
      sel_tdata  = sel_tdata  | ({64{gnt[i]}} & leaf_tdata[i*64 +: 64]);
      sel_tkeep  = sel_tkeep  | ({8{gnt[i]}} & leaf_tkeep[i*8 +: 8]);
      sel_tvalid = sel_tvalid | (gnt[i] && leaf_tvalid[i]);
      sel_tlast  = sel_tlast  | (gnt[i] && leaf_tlast[i]);
    end
  end

  // Arbiter slice: registered ready to the leaves, registered beat to the
  // egress queue, whose s_ready back-pressures it.
  rtlnet_axis_reg_slice #(
    .DATA_W     (64),
    .RESET_DATA (1'b0)
  ) u_arb_slice (
    .clk      (proto_clk),
    .resetn   (proto_resetn),
    .s_tdata  (sel_tdata),
    .s_tkeep  (sel_tkeep),
    .s_tlast  (sel_tlast),
    .s_tvalid (sel_tvalid),
    .s_tready (arb_s_ready),
    .m_tdata  (eq_s_data),
    .m_tkeep  (eq_s_keep),
    .m_tlast  (eq_s_last),
    .m_tvalid (eq_s_valid),
    .m_tready (eq_s_ready)
  );

  // ===========================================================================
  // proto_clk: LED status outputs.
  // ===========================================================================
  always_ff @(posedge proto_clk) begin
    if (!proto_resetn) begin
      stat_ip_valid   <= 1'b0;
      stat_dhcp_bound <= 1'b0;
      ev_rx_frame     <= 1'b0;
      ev_tx_frame     <= 1'b0;
    end else begin
      stat_ip_valid   <= (local_ip != '0);
      stat_dhcp_bound <= ip_from_dhcp;
      ev_rx_frame     <= leaf_in_tvalid && iq_last;
      ev_tx_frame     <= eq_s_valid && eq_s_ready && eq_s_last;
    end
  end

  // Simulation-only check: the fan-out is correct only if every leaf holds
  // s_axis_tready at 1 while a beat is presented.
  // synthesis translate_off
  always @(posedge proto_clk) begin
    if (proto_resetn && leaf_in_tvalid && !(&leaf_s_tready))
      $error("%m: a leaf s_axis_tready is low (%b) while a frame beat is presented", leaf_s_tready);
  end
  // synthesis translate_on

endmodule
