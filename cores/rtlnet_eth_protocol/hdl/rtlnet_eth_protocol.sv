// -----------------------------------------------------------------------------
// File: rtlnet_eth_protocol.sv
// Purpose: the RTLNet protocol wrapper (documentation/rtlnet_architecture.md
//   sections 7.4, 7.5, 15.3, 15.4). It sits on the MAC client streams, keeps
//   the node address, filters by destination MAC, queues frames between the
//   MAC clock and the protocol clock, presents one frame at a time to every
//   protocol leaf and returns their replies to the MAC through a fixed-
//   priority, per-frame arbiter. Every frame no enabled leaf claims is copied
//   to the CPU network path (cpu_axis_ethernet_stream), and the CPU's frames
//   join the arbiter as its lowest-priority source.
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
//   * CPU network path (architecture 7.4, CPU_PATH_ENABLE generate):
//       - Copy: the dequeue controller writes every frame it presents to the
//         leaves into u_cpu_rx_fifo (CPU_RX_FIFO_KB, proto_clk ->
//         cpu_axis_clk, DROP_WHEN_FULL = 0) in the same clocks. At a frame's
//         first beat the FIFO's s_ready decides: ready, the copy is written;
//         not ready (no free slot), nothing of the frame is written. The
//         leaves are never stalled: the FIFO's s_ready is high for the rest
//         of a started frame. CTRL.CPU_PATH_ENABLE is sampled at the first
//         beat.
//       - Verdict: the copy's last beat is held in cp_hold_* until the
//         dequeue controller would admit the next frame (DQ_WAIT with no leaf
//         busy, so the 16-clock gap has elapsed). leaf_claim pulses (masked by
//         LEAF_ENABLE) accumulate from the frame's first beat to that clock,
//         that clock included. Claimed: the held beat is written with s_bad
//         (the FIFO drops the copy); otherwise the copy is committed.
//       - Counters (proto_clk, at the verdict, only for frames that found the
//         path enabled): CPU_RX_CLAIMED, CPU_RX_FRAMES (committed),
//         CPU_RX_DROPPED (unclaimed, but no free slot at the first beat).
//         DELIVERED_FRAMES counts every frame dequeued to the leaves. With the
//         path enabled throughout: DELIVERED = CPU_RX_CLAIMED + CPU_RX_FRAMES
//         + CPU_RX_DROPPED.
//       - Output (cpu_axis_clk): u_cpu_rx_fifo -> u_cpu_classifier
//         (rtlnet_classifier, AXIS_CLK_HZ = CPU_AXIS_CLK_HZ; drop-all until
//         firmware configures it; the broadcast storm limiter is its first
//         configuration) -> m_axis_cpu_eth. With CPU_CLASSIFIER_ENABLE = 0 the
//         queue drives m_axis_cpu_eth through u_cpu_rx_slice instead.
//       - Classifier registers: with the classifier built, u_cpu_axil_dec
//         (rtlnet_axil_decoder, s_axi_aclk) sends sub-map 0x8000-0x8FFF to
//         u_cpu_classifier.s_axi (its own crossing) and every other address
//         to u_axil_cdc. Without it the 0x8000 window reads 0 like any unused
//         window.
//       - Transmit: s_axis_cpu_eth -> u_cpu_tx_guard (rtlnet_frame_guard, 14
//         .. ETH_MAX_FRAME_BYTES, legal tkeep) -> u_cpu_tx_fifo
//         (CPU_TX_FIFO_KB, cpu_axis_clk -> proto_clk, DROP_WHEN_FULL = 0, so
//         s_axis_cpu_eth_tready falls only between frames) -> discard gate
//         -> u_cpu_tx_slice -> arbiter source 5, after iperf. CPU_TX_REJECTED
//         counts guard rejections in cpu_axis_clk (u_cnt_cpu_reject_sync);
//         with CTRL.CPU_PATH_ENABLE clear (sampled at a frame's first beat on
//         the read side) whole frames are read and discarded
//         (CPU_TX_DISCARDED); CPU_TX_FRAMES counts frames the arbiter takes.
//       - CPU_PATH_ENABLE = 0: no queues; m_axis_cpu_eth_tvalid 0,
//         s_axis_cpu_eth_tready 1 (every CPU beat is consumed and ignored),
//         CPU counters 0, CAPS.CPU_PATH_PRESENT 0.
//   * Simulation-only check: every leaf holds s_axis_tready at 1 while a
//     beat is presented (the fan-out depends on it).
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 11-14-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: leaf claim inputs; CPU network path (u_cpu_rx_fifo,
//     u_cpu_tx_fifo, arbiter source 5); u_cpu_classifier on the CPU receive
//     stream with its register window 0x8000; DELIVERED and CPU counters.
//   * 11-14-2026: CLS_* parameters pass the classifier's sizes and RAM style through to u_cpu_classifier
//     (defaults equal the classifier's own).
// Clocks:
//   * axis_clk: MAC client streams; axis_resetn synchronous to it.
//   * proto_clk: leaves and register file; proto_resetn synchronous to it.
//   * app_clk: the UDP socket application streams; app_resetn synchronous.
//   * s_axi_aclk: AXI4-Lite slave; s_axi_aresetn synchronous to it.
//   * cpu_axis_clk: the CPU network streams; cpu_axis_resetn synchronous.
//   All five resets derive from one assertion in the board top (the packet
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
  parameter int    CPU_PATH_ENABLE = 1,            // build the CPU network path
  parameter int    CPU_RX_FIFO_KB  = 16,           // CPU receive queue, kilobytes
  parameter int    CPU_TX_FIFO_KB  = 8,            // CPU transmit queue, kilobytes
  parameter int    CPU_CLASSIFIER_ENABLE = 1,      // build u_cpu_classifier on the CPU receive stream
  parameter int    CPU_TCP_OFFLOAD_ENABLE = 1,     // build u_cpu_offload (checksum insert on TX, trailer on RX)
  parameter int    CPU_TCP_OFFLOAD_ACK_COALESCE = 0, // u_cpu_offload: build the ACK coalescer (needs the trailer, CTRL.rx_csum)
  parameter int    CPU_TCP_OFFLOAD_RX_BATCH = 0,   // u_cpu_offload: build the receive batcher (several frames per DMA transfer)
  parameter int    CPU_TCP_OFFLOAD_ACK_FLOWS = 4,  // u_cpu_offload: ACK coalescer flow table entries
  parameter int    CPU_AXIS_CLK_HZ = 100_000_000,  // cpu_axis_clk frequency (classifier policer tick)
  parameter int    CLS_TABLE_ENTRIES     = 16,     // u_cpu_classifier TABLE_ENTRIES (2, 4, 8, 16)
  parameter int    CLS_TUPLE_ENTRIES     = 16,     // u_cpu_classifier TUPLE_ENTRIES (2, 4, 8, 16)
  parameter int    CLS_TABLE_LANES       = 2,      // u_cpu_classifier TABLE_LANES (2 or 4)
  parameter int    CLS_NUM_RULES         = 2,      // u_cpu_classifier NUM_RULES (1..4)
  parameter int    CLS_NUM_POLICERS      = 4,      // u_cpu_classifier NUM_POLICERS (1..4)
  parameter int    CLS_MATCH_DEPTH_BYTES = 64,     // u_cpu_classifier MATCH_DEPTH_BYTES (40..256, multiple of 8)
  parameter string CLS_RAM_STYLE         = "block", // u_cpu_classifier RAM_STYLE ("block" | "distributed")
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

  // CPU clock (cpu_clk) of the CPU network streams and its synchronous
  // active-low reset (from the same assertion as the other resets).
  input  logic        cpu_axis_clk,
  input  logic        cpu_axis_resetn,

  // cpu_axis_ethernet_stream ingress (cpu_axis_clk): unclaimed frames to the
  // CPU, whole Ethernet frames without FCS, registered outputs.
  output logic [63:0] m_axis_cpu_eth_tdata,
  output logic [7:0]  m_axis_cpu_eth_tkeep,
  output logic        m_axis_cpu_eth_tvalid,
  output logic        m_axis_cpu_eth_tlast,
  input  logic        m_axis_cpu_eth_tready,

  // cpu_axis_ethernet_stream egress (cpu_axis_clk): frames from the CPU,
  // 14..1518 bytes without FCS; tready falls only between frames.
  input  logic [63:0] s_axis_cpu_eth_tdata,
  input  logic [7:0]  s_axis_cpu_eth_tkeep,
  input  logic        s_axis_cpu_eth_tvalid,
  input  logic        s_axis_cpu_eth_tlast,
  output logic        s_axis_cpu_eth_tready,

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
  // Arbiter sources: the leaves at their indices, then the CPU (lowest).
  localparam int         N_SRC        = N_LEAVES + 1;
  localparam int         SRC_CPU      = N_LEAVES;
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

  localparam bit         CPU_PRESENT            = (CPU_PATH_ENABLE != 0);
  localparam bit         CLASSIFIER_PRESENT     = CPU_PRESENT && (CPU_CLASSIFIER_ENABLE != 0);
  // Classifier register window in the sub-map (decoded in s_axi_aclk).
  localparam logic [15:0] WIN_CLASSIFIER_BASE   = 16'h8000;
  localparam logic [15:0] WIN_CLASSIFIER_SIZE   = 16'h1000;
  localparam bit         OFFLOAD_PRESENT        = CPU_PRESENT && (CPU_TCP_OFFLOAD_ENABLE != 0);
  // Checksum offload register window in the sub-map (decoded in s_axi_aclk).
  localparam logic [15:0] WIN_OFFLOAD_BASE      = 16'h9000;
  localparam logic [15:0] WIN_OFFLOAD_SIZE      = 16'h1000;
  localparam logic [15:0] WIN_SUBMAP_SIZE       = 16'h0000;   // 64 KiB (wraps to 0 in 16 bits)

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
  logic                   dq_in_frame;         // a frame toward the leaves has started, not ended
  logic                   dq_first;            // this beat is a frame's first
  logic                   dq_admit;            // DQ_WAIT -> DQ_PASS this clock
  logic [31:0]            cnt_delivered;

  // Leaf vectors, packed by leaf index. Nets: each slice is driven by its own
  // leaf instance or by the tie-offs of a disabled leaf.
  wire  [N_LEAVES*64-1:0] leaf_tdata;
  wire  [N_LEAVES*8-1:0]  leaf_tkeep;
  wire  [N_LEAVES-1:0]    leaf_tvalid;
  wire  [N_LEAVES-1:0]    leaf_tlast;
  logic [N_LEAVES-1:0]    leaf_tready;
  wire  [N_LEAVES-1:0]    leaf_s_tready;
  wire  [N_LEAVES-1:0]    leaf_busy;
  wire  [N_LEAVES-1:0]    leaf_claim;
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

  // CPU network path (proto_clk side) and its counters.
  logic                   cpu_path_enable;     // CTRL.CPU_PATH_ENABLE (masked by CPU_PRESENT)
  logic [63:0]            cpu_src_tdata;       // CPU frames toward the arbiter (source 5)
  logic [7:0]             cpu_src_tkeep;
  logic                   cpu_src_tvalid;
  logic                   cpu_src_tlast;
  logic                   cpu_src_tready;
  logic                   st_cpu_rx_full;
  logic                   st_cpu_rx_pending;
  logic                   st_cpu_tx_pending;
  logic [31:0]            cnt_cpu_rx_frames;
  logic [31:0]            cnt_cpu_rx_claimed;
  logic [31:0]            cnt_cpu_rx_dropped;
  logic [31:0]            cnt_cpu_tx_frames;
  logic [31:0]            cnt_cpu_tx_discard;
  logic [31:0]            cnt_cpu_tx_reject;
  // Classifier register port (s_axi_aclk), from u_cpu_axil_dec.
  logic [11:0]            cl_awaddr;
  logic                   cl_awvalid;
  logic                   cl_awready;
  logic [31:0]            cl_wdata;
  logic [3:0]             cl_wstrb;
  logic                   cl_wvalid;
  logic                   cl_wready;
  logic [1:0]             cl_bresp;
  logic                   cl_bvalid;
  logic                   cl_bready;
  logic [11:0]            cl_araddr;
  logic                   cl_arvalid;
  logic                   cl_arready;
  logic [31:0]            cl_rdata;
  logic [1:0]             cl_rresp;
  logic                   cl_rvalid;
  logic                   cl_rready;
  // Checksum offload register port (s_axi_aclk), from u_cpu_axil_dec.
  logic [11:0]            of_awaddr;
  logic                   of_awvalid;
  logic                   of_awready;
  logic [31:0]            of_wdata;
  logic [3:0]             of_wstrb;
  logic                   of_wvalid;
  logic                   of_wready;
  logic [1:0]             of_bresp;
  logic                   of_bvalid;
  logic                   of_bready;
  logic [11:0]            of_araddr;
  logic                   of_arvalid;
  logic                   of_arready;
  logic [31:0]            of_rdata;
  logic [1:0]             of_rresp;
  logic                   of_rvalid;
  logic                   of_rready;
  // The wrapper's own register path (s_axi_aclk), into u_axil_cdc.
  logic [15:0]            w_awaddr;
  logic                   w_awvalid;
  logic                   w_awready;
  logic [31:0]            w_wdata;
  logic [3:0]             w_wstrb;
  logic                   w_wvalid;
  logic                   w_wready;
  logic [1:0]             w_bresp;
  logic                   w_bvalid;
  logic                   w_bready;
  logic [15:0]            w_araddr;
  logic                   w_arvalid;
  logic                   w_arready;
  logic [31:0]            w_rdata;
  logic [1:0]             w_rresp;
  logic                   w_rvalid;
  logic                   w_rready;

  // Arbiter sources (leaves 0..4, CPU 5).
  wire  [N_SRC*64-1:0]    src_tdata;
  wire  [N_SRC*8-1:0]     src_tkeep;
  wire  [N_SRC-1:0]       src_tvalid;
  wire  [N_SRC-1:0]       src_tlast;
  logic [N_SRC-1:0]       src_tready;

  // Arbiter.
  logic [N_SRC:0]         grant;               // bit 0 idle, bit i+1 source i
  logic [N_SRC:0]         pick;
  logic [N_SRC-1:0]       gnt;
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
  assign dq_first       = leaf_in_tvalid && !dq_in_frame;
  // The clock the controller admits the next frame: the claim verdict of the
  // previous frame is final here (gap elapsed, no leaf busy).
  assign dq_admit       = (dq_state == DQ_WAIT) && !(|leaf_busy);

  // Frame boundary toward the leaves and the DELIVERED_FRAMES count.
  always_ff @(posedge proto_clk) begin
    if (!proto_resetn) begin
      dq_in_frame   <= 1'b0;
      cnt_delivered <= '0;
    end else if (leaf_in_tvalid) begin
      dq_in_frame <= !iq_last;
      if (iq_last) cnt_delivered <= cnt_delivered + 32'd1;
    end
  end

  // ===========================================================================
  // s_axi_aclk: classifier window. With the classifier built, u_cpu_axil_dec
  // routes 0x8000-0x8FFF to u_cpu_classifier (slave 0, lowest index wins) and
  // the whole remaining sub-map to the wrapper's crossing (slave 1, 64 KiB
  // window: size 0 in 16 address bits). Without it s_axi goes straight on.
  // ===========================================================================
  generate
    if (CLASSIFIER_PRESENT || OFFLOAD_PRESENT) begin : g_cl_dec
      logic [47:0] dec_awaddr;
      logic [47:0] dec_araddr;

      rtlnet_axil_decoder #(
        .N          (3),
        .ADDR_W     (16),
        .SLAVE_BASE ({16'h0000, WIN_OFFLOAD_BASE, WIN_CLASSIFIER_BASE}),
        .SLAVE_SIZE ({WIN_SUBMAP_SIZE, WIN_OFFLOAD_SIZE, WIN_CLASSIFIER_SIZE})
      ) u_cpu_axil_dec (
        .aclk          (s_axi_aclk),
        .aresetn       (s_axi_aresetn),
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
        .m_axi_awaddr  (dec_awaddr),
        .m_axi_awvalid ({w_awvalid, of_awvalid, cl_awvalid}),
        .m_axi_awready ({w_awready, of_awready, cl_awready}),
        .m_axi_wdata   ({w_wdata, of_wdata, cl_wdata}),
        .m_axi_wstrb   ({w_wstrb, of_wstrb, cl_wstrb}),
        .m_axi_wvalid  ({w_wvalid, of_wvalid, cl_wvalid}),
        .m_axi_wready  ({w_wready, of_wready, cl_wready}),
        .m_axi_bresp   ({w_bresp, of_bresp, cl_bresp}),
        .m_axi_bvalid  ({w_bvalid, of_bvalid, cl_bvalid}),
        .m_axi_bready  ({w_bready, of_bready, cl_bready}),
        .m_axi_araddr  (dec_araddr),
        .m_axi_arvalid ({w_arvalid, of_arvalid, cl_arvalid}),
        .m_axi_arready ({w_arready, of_arready, cl_arready}),
        .m_axi_rdata   ({w_rdata, of_rdata, cl_rdata}),
        .m_axi_rresp   ({w_rresp, of_rresp, cl_rresp}),
        .m_axi_rvalid  ({w_rvalid, of_rvalid, cl_rvalid}),
        .m_axi_rready  ({w_rready, of_rready, cl_rready})
      );

      assign cl_awaddr = dec_awaddr[11:0];
      assign cl_araddr = dec_araddr[11:0];
      assign of_awaddr = dec_awaddr[27:16];
      assign of_araddr = dec_araddr[27:16];
      assign w_awaddr  = dec_awaddr[47:32];
      assign w_araddr  = dec_araddr[47:32];

      // A window without its block answers like any unused window: zero, OKAY, writes ignored.
      if (!CLASSIFIER_PRESENT) begin : g_cl_null
        rtlnet_axil_slave #(.ADDR_W(12)) u_cl_null (
          .s_axi_aclk    (s_axi_aclk),
          .s_axi_aresetn (s_axi_aresetn),
          .s_axi_awaddr  (cl_awaddr),
          .s_axi_awvalid (cl_awvalid),
          .s_axi_awready (cl_awready),
          .s_axi_wdata   (cl_wdata),
          .s_axi_wstrb   (cl_wstrb),
          .s_axi_wvalid  (cl_wvalid),
          .s_axi_wready  (cl_wready),
          .s_axi_bresp   (cl_bresp),
          .s_axi_bvalid  (cl_bvalid),
          .s_axi_bready  (cl_bready),
          .s_axi_araddr  (cl_araddr),
          .s_axi_arvalid (cl_arvalid),
          .s_axi_arready (cl_arready),
          .s_axi_rdata   (cl_rdata),
          .s_axi_rresp   (cl_rresp),
          .s_axi_rvalid  (cl_rvalid),
          .s_axi_rready  (cl_rready),
          .reg_wr_en     (),
          .reg_wr_addr   (),
          .reg_wr_data   (),
          .reg_rd_en     (),
          .reg_rd_addr   (),
          .reg_rd_data   (32'd0)
        );
      end
      if (!OFFLOAD_PRESENT) begin : g_of_null
        rtlnet_axil_slave #(.ADDR_W(12)) u_of_null (
          .s_axi_aclk    (s_axi_aclk),
          .s_axi_aresetn (s_axi_aresetn),
          .s_axi_awaddr  (of_awaddr),
          .s_axi_awvalid (of_awvalid),
          .s_axi_awready (of_awready),
          .s_axi_wdata   (of_wdata),
          .s_axi_wstrb   (of_wstrb),
          .s_axi_wvalid  (of_wvalid),
          .s_axi_wready  (of_wready),
          .s_axi_bresp   (of_bresp),
          .s_axi_bvalid  (of_bvalid),
          .s_axi_bready  (of_bready),
          .s_axi_araddr  (of_araddr),
          .s_axi_arvalid (of_arvalid),
          .s_axi_arready (of_arready),
          .s_axi_rdata   (of_rdata),
          .s_axi_rresp   (of_rresp),
          .s_axi_rvalid  (of_rvalid),
          .s_axi_rready  (of_rready),
          .reg_wr_en     (),
          .reg_wr_addr   (),
          .reg_wr_data   (),
          .reg_rd_en     (),
          .reg_rd_addr   (),
          .reg_rd_data   (32'd0)
        );
      end
    end else begin : g_no_cl_dec
      assign w_awaddr      = s_axi_awaddr;
      assign w_awvalid     = s_axi_awvalid;
      assign s_axi_awready = w_awready;
      assign w_wdata       = s_axi_wdata;
      assign w_wstrb       = s_axi_wstrb;
      assign w_wvalid      = s_axi_wvalid;
      assign s_axi_wready  = w_wready;
      assign s_axi_bresp   = w_bresp;
      assign s_axi_bvalid  = w_bvalid;
      assign w_bready      = s_axi_bready;
      assign w_araddr      = s_axi_araddr;
      assign w_arvalid     = s_axi_arvalid;
      assign s_axi_arready = w_arready;
      assign s_axi_rdata   = w_rdata;
      assign s_axi_rresp   = w_rresp;
      assign s_axi_rvalid  = w_rvalid;
      assign w_rready      = s_axi_rready;
      assign cl_awaddr     = '0;
      assign cl_awvalid    = 1'b0;
      assign cl_awready    = 1'b0;
      assign cl_wdata      = '0;
      assign cl_wstrb      = '0;
      assign cl_wvalid     = 1'b0;
      assign cl_wready     = 1'b0;
      assign cl_bresp      = '0;
      assign cl_bvalid     = 1'b0;
      assign cl_bready     = 1'b0;
      assign cl_araddr     = '0;
      assign cl_arvalid    = 1'b0;
      assign cl_arready    = 1'b0;
      assign cl_rdata      = '0;
      assign cl_rresp      = '0;
      assign cl_rvalid     = 1'b0;
      assign cl_rready     = 1'b0;
      assign of_awaddr     = '0;
      assign of_awvalid    = 1'b0;
      assign of_awready    = 1'b0;
      assign of_wdata      = '0;
      assign of_wstrb      = '0;
      assign of_wvalid     = 1'b0;
      assign of_wready     = 1'b0;
      assign of_bresp      = '0;
      assign of_bvalid     = 1'b0;
      assign of_bready     = 1'b0;
      assign of_araddr     = '0;
      assign of_arvalid    = 1'b0;
      assign of_arready    = 1'b0;
      assign of_rdata      = '0;
      assign of_rresp      = '0;
      assign of_rvalid     = 1'b0;
      assign of_rready     = 1'b0;
    end
  endgenerate

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
    .s_axi_awaddr  (w_awaddr),
    .s_axi_awvalid (w_awvalid),
    .s_axi_awready (w_awready),
    .s_axi_wdata   (w_wdata),
    .s_axi_wstrb   (w_wstrb),
    .s_axi_wvalid  (w_wvalid),
    .s_axi_wready  (w_wready),
    .s_axi_bresp   (w_bresp),
    .s_axi_bvalid  (w_bvalid),
    .s_axi_bready  (w_bready),
    .s_axi_araddr  (w_araddr),
    .s_axi_arvalid (w_arvalid),
    .s_axi_arready (w_arready),
    .s_axi_rdata   (w_rdata),
    .s_axi_rresp   (w_rresp),
    .s_axi_rvalid  (w_rvalid),
    .s_axi_rready  (w_rready),
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

  // ===========================================================================
  // CPU network path (architecture 7.4): copy, verdict, queues, classifier.
  // ===========================================================================
  generate
    if (CPU_PRESENT) begin : g_cpu
      // proto_clk copy and verdict state.
      logic        cp_track;              // this frame found the path enabled (counted on the CPU side)
      logic        cp_copy;               // this frame's copy is being written
      logic        cp_pending;            // a counted frame waits for its verdict
      logic        cp_claimed;            // a claim pulse since the frame's first beat
      logic [63:0] cp_hold_data;          // the copy's last beat, held for the verdict
      logic [7:0]  cp_hold_keep;
      logic        claim_now;
      logic        copy_now;
      logic        verdict;
      logic        claimed_final;
      // u_cpu_rx_fifo write side (proto_clk) and read side (cpu_axis_clk).
      logic [63:0] crx_s_data;
      logic [7:0]  crx_s_keep;
      logic        crx_s_valid;
      logic        crx_s_ready;
      logic        crx_s_last;
      logic        crx_s_bad;
      logic [63:0] crx_m_data;
      logic [7:0]  crx_m_keep;
      logic        crx_m_valid;
      logic        crx_m_ready;
      logic        crx_m_last;
      // Classifier (or registered queue) output toward the receive offload, and the offload's
      // transmit output toward the legality guard and u_cpu_tx_fifo.
      logic [63:0] cls_m_data;
      logic [7:0]  cls_m_keep;
      logic        cls_m_valid;
      logic        cls_m_last;
      logic        cls_m_ready;
      logic [63:0] tin_data;
      logic [7:0]  tin_keep;
      logic        tin_valid;
      logic        tin_last;
      logic        tin_ready;
      // u_cpu_tx_fifo write side (cpu_axis_clk) and read side (proto_clk).
      logic        ctx_s_bad;
      logic [31:0] cx_cnt_reject;
      logic [63:0] ctx_m_data;
      logic [7:0]  ctx_m_keep;
      logic        ctx_m_valid;
      logic        ctx_m_ready;
      logic        ctx_m_last;
      logic        ctx_in_frame;
      logic        ctx_drop;              // the frame at the read side is being discarded
      logic        ctx_drop_now;
      logic        slice_s_ready;

      assign claim_now     = |(leaf_claim & leaf_enable);
      assign copy_now      = dq_first ? (cpu_path_enable && crx_s_ready) : cp_copy;
      assign verdict       = cp_pending && dq_admit;
      assign claimed_final = cp_claimed || claim_now;

      // u_cpu_rx_fifo write port: the frame's beats as the leaves take them,
      // all but the last; the held last beat in the verdict clock (the
      // controller is in DQ_WAIT then, so the two never coincide).
      assign crx_s_valid = (leaf_in_tvalid && !iq_last && copy_now) || (verdict && cp_copy);
      assign crx_s_data  = verdict ? cp_hold_data : iq_data;
      assign crx_s_keep  = verdict ? cp_hold_keep : iq_keep;
      assign crx_s_last  = verdict;
      assign crx_s_bad   = verdict && claimed_final;

      // Per-frame copy state, claim accumulation and the verdict counters.
      always_ff @(posedge proto_clk) begin
        if (!proto_resetn) begin
          cp_track           <= 1'b0;
          cp_copy            <= 1'b0;
          cp_pending         <= 1'b0;
          cp_claimed         <= 1'b0;
          cp_hold_data       <= '0;
          cp_hold_keep       <= '0;
          cnt_cpu_rx_frames  <= '0;
          cnt_cpu_rx_claimed <= '0;
          cnt_cpu_rx_dropped <= '0;
        end else begin
          if (dq_first) begin
            cp_track   <= cpu_path_enable;
            cp_copy    <= cpu_path_enable && crx_s_ready;
            cp_claimed <= 1'b0;
          end else if (claim_now) begin
            cp_claimed <= 1'b1;
          end
          if (leaf_in_tvalid && iq_last) begin
            cp_hold_data <= iq_data;
            cp_hold_keep <= iq_keep;
            cp_pending   <= dq_first ? cpu_path_enable : cp_track;
          end
          if (verdict) begin
            cp_pending <= 1'b0;
            cp_copy    <= 1'b0;
            if (claimed_final) cnt_cpu_rx_claimed <= cnt_cpu_rx_claimed + 32'd1;
            else if (cp_copy)  cnt_cpu_rx_frames  <= cnt_cpu_rx_frames + 32'd1;
            else               cnt_cpu_rx_dropped <= cnt_cpu_rx_dropped + 32'd1;
          end
        end
      end

      // CPU receive queue, proto_clk -> cpu_axis_clk (instance name used by
      // the CDC constraint script).
      rtlnet_packet_fifo #(
        .RAM_STYLE       (RAM_STYLE),
        .FIFO_KB         (CPU_RX_FIFO_KB),
        .MAX_FRAME_BYTES (ETH_MAX_FRAME_BYTES),
        .DROP_WHEN_FULL  (1'b0)
      ) u_cpu_rx_fifo (
        .s_clk     (proto_clk),
        .s_resetn  (proto_resetn),
        .s_data    (crx_s_data),
        .s_keep    (crx_s_keep),
        .s_valid   (crx_s_valid),
        .s_ready   (crx_s_ready),
        .s_last    (crx_s_last),
        .s_bad     (crx_s_bad),
        .m_clk     (cpu_axis_clk),
        .m_resetn  (cpu_axis_resetn),
        .m_data    (crx_m_data),
        .m_keep    (crx_m_keep),
        .m_valid   (crx_m_valid),
        .m_ready   (crx_m_ready),
        .m_last    (crx_m_last),
        .overflow  (),
        .bad_frame ()
      );

      if (CLASSIFIER_PRESENT) begin : g_classifier
        // CPU-path classifier (cores/rtlnet_classifier, its section 2 ports):
        // every frame toward the CPU is filtered; registers at 0x8000.
        rtlnet_classifier #(
          .AXIS_CLK_HZ       (CPU_AXIS_CLK_HZ),
          .TABLE_ENTRIES     (CLS_TABLE_ENTRIES),
          .TUPLE_ENTRIES     (CLS_TUPLE_ENTRIES),
          .TABLE_LANES       (CLS_TABLE_LANES),
          .NUM_RULES         (CLS_NUM_RULES),
          .NUM_POLICERS      (CLS_NUM_POLICERS),
          .MATCH_DEPTH_BYTES (CLS_MATCH_DEPTH_BYTES),
          .RAM_STYLE         (CLS_RAM_STYLE)
        ) u_cpu_classifier (
          .axis_clk      (cpu_axis_clk),
          .axis_resetn   (cpu_axis_resetn),
          .s_axi_aclk    (s_axi_aclk),
          .s_axi_aresetn (s_axi_aresetn),
          .s_axis_tdata  (crx_m_data),
          .s_axis_tkeep  (crx_m_keep),
          .s_axis_tvalid (crx_m_valid),
          .s_axis_tlast  (crx_m_last),
          .s_axis_tready (crx_m_ready),
          .m_axis_tdata  (cls_m_data),
          .m_axis_tkeep  (cls_m_keep),
          .m_axis_tvalid (cls_m_valid),
          .m_axis_tlast  (cls_m_last),
          .m_axis_tready (cls_m_ready),
          .s_axi_awaddr  (cl_awaddr),
          .s_axi_awvalid (cl_awvalid),
          .s_axi_awready (cl_awready),
          .s_axi_wdata   (cl_wdata),
          .s_axi_wstrb   (cl_wstrb),
          .s_axi_wvalid  (cl_wvalid),
          .s_axi_wready  (cl_wready),
          .s_axi_bresp   (cl_bresp),
          .s_axi_bvalid  (cl_bvalid),
          .s_axi_bready  (cl_bready),
          .s_axi_araddr  (cl_araddr),
          .s_axi_arvalid (cl_arvalid),
          .s_axi_arready (cl_arready),
          .s_axi_rdata   (cl_rdata),
          .s_axi_rresp   (cl_rresp),
          .s_axi_rvalid  (cl_rvalid),
          .s_axi_rready  (cl_rready),
          .ev_pass       (),
          .ev_drop       ()
        );
      end else begin : g_no_classifier
        // Registered CPU receive stream straight from the queue.
        rtlnet_axis_reg_slice #(
          .DATA_W     (64),
          .RESET_DATA (1'b1)
        ) u_cpu_rx_slice (
          .clk      (cpu_axis_clk),
          .resetn   (cpu_axis_resetn),
          .s_tdata  (crx_m_data),
          .s_tkeep  (crx_m_keep),
          .s_tlast  (crx_m_last),
          .s_tvalid (crx_m_valid),
          .s_tready (crx_m_ready),
          .m_tdata  (cls_m_data),
          .m_tkeep  (cls_m_keep),
          .m_tlast  (cls_m_last),
          .m_tvalid (cls_m_valid),
          .m_tready (cls_m_ready)
        );
      end

      if (OFFLOAD_PRESENT) begin : g_offload
        // Checksum offload on the CPU DMA streams (cores/rtlnet_tcp_offload): receive frames get a
        // checksum trailer, transmit frames get their checksum fields inserted; registers at 0x9000.
        rtlnet_tcp_offload #(
          .RAM_STYLE    (RAM_STYLE),
          .ACK_COALESCE (CPU_TCP_OFFLOAD_ACK_COALESCE),
          .ACK_FLOWS    (CPU_TCP_OFFLOAD_ACK_FLOWS),
          .RX_BATCH     (CPU_TCP_OFFLOAD_RX_BATCH),
          .CLK_HZ       (CPU_AXIS_CLK_HZ)
        ) u_cpu_offload (
          .clk              (cpu_axis_clk),
          .resetn           (cpu_axis_resetn),
          .s_axi_aclk       (s_axi_aclk),
          .s_axi_aresetn    (s_axi_aresetn),
          .s_axis_tx_tdata  (s_axis_cpu_eth_tdata),
          .s_axis_tx_tkeep  (s_axis_cpu_eth_tkeep),
          .s_axis_tx_tvalid (s_axis_cpu_eth_tvalid),
          .s_axis_tx_tlast  (s_axis_cpu_eth_tlast),
          .s_axis_tx_tready (s_axis_cpu_eth_tready),
          .m_axis_tx_tdata  (tin_data),
          .m_axis_tx_tkeep  (tin_keep),
          .m_axis_tx_tvalid (tin_valid),
          .m_axis_tx_tlast  (tin_last),
          .m_axis_tx_tready (tin_ready),
          .s_axis_rx_tdata  (cls_m_data),
          .s_axis_rx_tkeep  (cls_m_keep),
          .s_axis_rx_tvalid (cls_m_valid),
          .s_axis_rx_tlast  (cls_m_last),
          .s_axis_rx_tready (cls_m_ready),
          .m_axis_rx_tdata  (m_axis_cpu_eth_tdata),
          .m_axis_rx_tkeep  (m_axis_cpu_eth_tkeep),
          .m_axis_rx_tvalid (m_axis_cpu_eth_tvalid),
          .m_axis_rx_tlast  (m_axis_cpu_eth_tlast),
          .m_axis_rx_tready (m_axis_cpu_eth_tready),
          .s_axi_awaddr     (of_awaddr),
          .s_axi_awvalid    (of_awvalid),
          .s_axi_awready    (of_awready),
          .s_axi_wdata      (of_wdata),
          .s_axi_wstrb      (of_wstrb),
          .s_axi_wvalid     (of_wvalid),
          .s_axi_wready     (of_wready),
          .s_axi_bresp      (of_bresp),
          .s_axi_bvalid     (of_bvalid),
          .s_axi_bready     (of_bready),
          .s_axi_araddr     (of_araddr),
          .s_axi_arvalid    (of_arvalid),
          .s_axi_arready    (of_arready),
          .s_axi_rdata      (of_rdata),
          .s_axi_rresp      (of_rresp),
          .s_axi_rvalid     (of_rvalid),
          .s_axi_rready     (of_rready)
        );
      end else begin : g_no_offload
        assign m_axis_cpu_eth_tdata  = cls_m_data;
        assign m_axis_cpu_eth_tkeep  = cls_m_keep;
        assign m_axis_cpu_eth_tvalid = cls_m_valid;
        assign m_axis_cpu_eth_tlast  = cls_m_last;
        assign cls_m_ready           = m_axis_cpu_eth_tready;
        assign tin_data              = s_axis_cpu_eth_tdata;
        assign tin_keep              = s_axis_cpu_eth_tkeep;
        assign tin_valid             = s_axis_cpu_eth_tvalid;
        assign tin_last              = s_axis_cpu_eth_tlast;
        assign s_axis_cpu_eth_tready = tin_ready;
      end

      // CPU transmit legality: 14..ETH_MAX_FRAME_BYTES bytes, legal tkeep.
      rtlnet_frame_guard #(
        .MIN_BYTES (ETH_MIN_TX_BYTES),
        .MAX_BYTES (ETH_MAX_FRAME_BYTES)
      ) u_cpu_tx_guard (
        .clk     (cpu_axis_clk),
        .resetn  (cpu_axis_resetn),
        .keep    (tin_keep),
        .valid   (tin_valid),
        .ready   (tin_ready),
        .last    (tin_last),
        .bad_in  (1'b0),
        .bad_out (ctx_s_bad)
      );

      // Guard rejections, counted at the rejected frame's last beat
      // (cpu_axis_clk), crossed to proto_clk below.
      always_ff @(posedge cpu_axis_clk) begin
        if (!cpu_axis_resetn) cx_cnt_reject <= '0;
        else if (tin_valid && tin_ready && tin_last && ctx_s_bad)
          cx_cnt_reject <= cx_cnt_reject + 32'd1;
      end

      rtlnet_gray_sync #(.WIDTH(32), .STAGES(2)) u_cnt_cpu_reject_sync (
        .src_clk(cpu_axis_clk), .src_resetn(cpu_axis_resetn), .src_count(cx_cnt_reject),
        .dst_clk(proto_clk), .dst_resetn(proto_resetn), .dst_count(cnt_cpu_tx_reject));

      // CPU transmit queue, cpu_axis_clk -> proto_clk; s_ready back-pressures
      // the CPU between frames only.
      rtlnet_packet_fifo #(
        .RAM_STYLE       (RAM_STYLE),
        .FIFO_KB         (CPU_TX_FIFO_KB),
        .MAX_FRAME_BYTES (ETH_MAX_FRAME_BYTES),
        .DROP_WHEN_FULL  (1'b0)
      ) u_cpu_tx_fifo (
        .s_clk     (cpu_axis_clk),
        .s_resetn  (cpu_axis_resetn),
        .s_data    (tin_data),
        .s_keep    (tin_keep),
        .s_valid   (tin_valid),
        .s_ready   (tin_ready),
        .s_last    (tin_last),
        .s_bad     (ctx_s_bad),
        .m_clk     (proto_clk),
        .m_resetn  (proto_resetn),
        .m_data    (ctx_m_data),
        .m_keep    (ctx_m_keep),
        .m_valid   (ctx_m_valid),
        .m_ready   (ctx_m_ready),
        .m_last    (ctx_m_last),
        .overflow  (),
        .bad_frame ()
      );

      // Discard gate: with the path disabled at a frame's first beat, the
      // whole frame is read and dropped (and counted at its last beat).
      assign ctx_drop_now = ctx_in_frame ? ctx_drop : !cpu_path_enable;
      assign ctx_m_ready  = ctx_drop_now || slice_s_ready;

      always_ff @(posedge proto_clk) begin
        if (!proto_resetn) begin
          ctx_in_frame       <= 1'b0;
          ctx_drop           <= 1'b0;
          cnt_cpu_tx_discard <= '0;
        end else if (ctx_m_valid && ctx_m_ready) begin
          ctx_in_frame <= !ctx_m_last;
          if (!ctx_in_frame) ctx_drop <= !cpu_path_enable;
          if (ctx_m_last && ctx_drop_now) cnt_cpu_tx_discard <= cnt_cpu_tx_discard + 32'd1;
        end
      end

      // Registered CPU source toward the arbiter (a started frame has no gap
      // the arbiter has to wait for longer than the queue's read side).
      rtlnet_axis_reg_slice #(
        .DATA_W     (64),
        .RESET_DATA (1'b0)
      ) u_cpu_tx_slice (
        .clk      (proto_clk),
        .resetn   (proto_resetn),
        .s_tdata  (ctx_m_data),
        .s_tkeep  (ctx_m_keep),
        .s_tlast  (ctx_m_last),
        .s_tvalid (ctx_m_valid && !ctx_drop_now),
        .s_tready (slice_s_ready),
        .m_tdata  (cpu_src_tdata),
        .m_tkeep  (cpu_src_tkeep),
        .m_tlast  (cpu_src_tlast),
        .m_tvalid (cpu_src_tvalid),
        .m_tready (cpu_src_tready)
      );

      // CPU frames taken by the arbiter.
      always_ff @(posedge proto_clk) begin
        if (!proto_resetn)                                       cnt_cpu_tx_frames <= '0;
        else if (cpu_src_tvalid && cpu_src_tready && cpu_src_tlast) cnt_cpu_tx_frames <= cnt_cpu_tx_frames + 32'd1;
      end

      // STATUS flags.
      always_ff @(posedge proto_clk) begin
        if (!proto_resetn) begin
          st_cpu_rx_full    <= 1'b0;
          st_cpu_rx_pending <= 1'b0;
          st_cpu_tx_pending <= 1'b0;
        end else begin
          st_cpu_rx_full    <= !crx_s_ready;
          st_cpu_rx_pending <= cp_pending;
          st_cpu_tx_pending <= ctx_m_valid;
        end
      end

      // Simulation-only check: a started copy is never refused by the queue.
      // synthesis translate_off
      always @(posedge proto_clk) begin
        if (proto_resetn && crx_s_valid && !crx_s_ready)
          $error("%m: CPU RX queue refused a beat of a started copy");
      end
      // synthesis translate_on
    end else begin : g_no_cpu
      assign m_axis_cpu_eth_tdata  = '0;
      assign m_axis_cpu_eth_tkeep  = '0;
      assign m_axis_cpu_eth_tvalid = 1'b0;
      assign m_axis_cpu_eth_tlast  = 1'b0;
      assign s_axis_cpu_eth_tready = 1'b1;
      assign cpu_src_tdata         = '0;
      assign cpu_src_tkeep         = '0;
      assign cpu_src_tvalid        = 1'b0;
      assign cpu_src_tlast         = 1'b0;
      assign st_cpu_rx_full        = 1'b0;
      assign st_cpu_rx_pending     = 1'b0;
      assign st_cpu_tx_pending     = 1'b0;
      assign cnt_cpu_rx_frames     = '0;
      assign cnt_cpu_rx_claimed    = '0;
      assign cnt_cpu_rx_dropped    = '0;
      assign cnt_cpu_tx_frames     = '0;
      assign cnt_cpu_tx_discard    = '0;
      assign cnt_cpu_tx_reject     = '0;
    end
  endgenerate

  // Wrapper register file: node address, CTRL, STATUS, counters.
  rtlnet_eth_protocol_regs #(
    .LEAF_PRESENT    (LEAF_PRESENT),
    .INGRESS_FIFO_KB (INGRESS_FIFO_KB),
    .EGRESS_FIFO_KB  (EGRESS_FIFO_KB),
    .NUM_SOCKETS     (NUM_SOCKETS),
    .CPU_PATH_PRESENT        (CPU_PRESENT),
    .CPU_CLASSIFIER_PRESENT  (CLASSIFIER_PRESENT),
    .CPU_OFFLOAD_PRESENT     (OFFLOAD_PRESENT),
    .CPU_RX_FIFO_KB          (CPU_RX_FIFO_KB),
    .CPU_TX_FIFO_KB          (CPU_TX_FIFO_KB)
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
    .cpu_rx_full          (st_cpu_rx_full),
    .cpu_rx_pending       (st_cpu_rx_pending),
    .cpu_tx_pending       (st_cpu_tx_pending),
    .cnt_ingress_frames   (pr_cnt_frames),
    .cnt_ingress_filtered (pr_cnt_filtered),
    .cnt_ingress_dropped  (pr_cnt_dropped),
    .cnt_egress_frames    (pr_cnt_egress),
    .cnt_delivered        (cnt_delivered),
    .cnt_cpu_rx_frames    (cnt_cpu_rx_frames),
    .cnt_cpu_rx_claimed   (cnt_cpu_rx_claimed),
    .cnt_cpu_rx_dropped   (cnt_cpu_rx_dropped),
    .cnt_cpu_tx_frames    (cnt_cpu_tx_frames),
    .cnt_cpu_tx_discard   (cnt_cpu_tx_discard),
    .cnt_cpu_tx_reject    (cnt_cpu_tx_reject),
    .local_mac            (local_mac),
    .effective_ip         (local_ip),
    .effective_mask       (local_mask),
    .effective_gateway    (local_gateway),
    .ip_from_dhcp         (ip_from_dhcp),
    .filter_enable        (filter_enable),
    .leaf_enable          (leaf_enable),
    .cpu_path_enable      (cpu_path_enable)
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
        .claim             (leaf_claim[LEAF_UDP]),
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
      assign leaf_claim[LEAF_UDP]            = 1'b0;
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
        .claim         (leaf_claim[LEAF_ICMP]),
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
      assign leaf_claim[LEAF_ICMP]            = 1'b0;
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
        .claim         (leaf_claim[LEAF_ARP]),
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
      assign leaf_claim[LEAF_ARP]            = 1'b0;
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
        .claim         (leaf_claim[LEAF_DHCP]),
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
      assign leaf_claim[LEAF_DHCP]            = 1'b0;
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
        .claim         (leaf_claim[LEAF_IPERF]),
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
      assign leaf_claim[LEAF_IPERF]            = 1'b0;
      assign leaf_rd_data[LEAF_IPERF*32 +: 32] = '0;
    end
  endgenerate

  // ===========================================================================
  // proto_clk: arbiter. Sources 0..4 are the leaves, source 5 the CPU (lowest
  // priority). grant is one-hot (bit 0 idle, bit i+1 source i). At idle the
  // lowest-index source with a registered tvalid is granted; the grant holds
  // until that source's last beat is accepted (no preemption), then returns
  // to idle for one clock. Only the granted source sees ready.
  // ===========================================================================
  assign src_tdata  = {cpu_src_tdata, leaf_tdata};
  assign src_tkeep  = {cpu_src_tkeep, leaf_tkeep};
  assign src_tvalid = {cpu_src_tvalid, leaf_tvalid};
  assign src_tlast  = {cpu_src_tlast, leaf_tlast};
  assign leaf_tready    = src_tready[N_LEAVES-1:0];
  assign cpu_src_tready = src_tready[SRC_CPU];

  always_comb begin
    pick    = '0;
    pick[0] = 1'b1;
    for (int i = N_SRC - 1; i >= 0; i--) begin
      if (src_tvalid[i]) begin
        pick      = '0;
        pick[i+1] = 1'b1;
      end
    end
  end

  assign gnt        = grant[N_SRC:1];
  assign last_taken = (|(gnt & src_tvalid & src_tlast)) && arb_s_ready;

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

  assign src_tready = gnt & {N_SRC{arb_s_ready}};

  // Output mux: AND-OR over the granted source.
  always_comb begin
    sel_tdata  = '0;
    sel_tkeep  = '0;
    sel_tvalid = 1'b0;
    sel_tlast  = 1'b0;
    for (int i = 0; i < N_SRC; i++) begin
      sel_tdata  = sel_tdata  | ({64{gnt[i]}} & src_tdata[i*64 +: 64]);
      sel_tkeep  = sel_tkeep  | ({8{gnt[i]}} & src_tkeep[i*8 +: 8]);
      sel_tvalid = sel_tvalid | (gnt[i] && src_tvalid[i]);
      sel_tlast  = sel_tlast  | (gnt[i] && src_tlast[i]);
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
