// -----------------------------------------------------------------------------
// File: tb_rtlnet_eth_protocol_cpu.sv
// Purpose: self-checking bench of the rtlnet_eth_protocol CPU network path
//   (cpu_axis_ethernet_stream, architecture 7.4) with every leaf built (ARP,
//   ICMP, DHCP, iperf, UDP socket) and the leaf claim rule (7.5), driven at
//   the MAC client streams (axis_clk), the CPU streams (cpu_axis_clk ~100 MHz,
//   unrelated to proto_clk) and AXI4-Lite (s_axi_aclk 100 MHz).
// Overview:
//   * Clock pair from +CLKPAIR as tb_rtlnet_eth_protocol: 1 axis 62.5 /
//     proto 50 MHz, 2 axis 156.25 / proto 50 MHz, 3 axis 50 / proto 62.5 MHz;
//     cpu_axis_clk 9.997 ns. The DUT is built with CPU_CLASSIFIER_ENABLE = 0
//     (the classifier is its own core; drop-all until configured).
//   * Oracles: bench-built frames; frames copied to the CPU are compared byte
//     for byte with the frame offered at s_axis, CPU frames at m_axis with the
//     frame the CPU sent, replies with rtlnet_tb_eth_frames_pkg.
//   * Always-on monitors: rtlnet_tb_leaf_busy_monitor and
//     rtlnet_tb_leaf_claim_monitor on the five leaves inside the wrapper; the
//     sinks' stream rules at m_axis, m_axis_cpu_eth and m_axis_app.
//   * Phases:
//       1 register map: CAPS (all leaves, CPU path), CPU_CAPS, CTRL, STATUS,
//         CPU counters 0, classifier window 0x8000 reads 0.
//       2 claimed by hardware, not copied: ARP request for us, pings.
//       3 to the CPU byte-exact: ARP reply to us, TCP SYN to our IP, UDP to an
//         unknown port, an ARP request for another IP (broadcast), ICMP echo
//         reply and timestamp request to us, IPv6 to our MAC.
//       4 every leaf: UDP datagram to an enabled socket (delivered to the
//         application, claimed), to the iperf port (claimed), to another port
//         (CPU); DHCP START, OFFER for the current xid (REQUEST sent, claimed),
//         OFFER with a wrong xid (CPU), STOP.
//       5 CPU stalled: 12 unclaimed frames, 8 kept in order and 4 counted in
//         CPU_RX_DROPPED, STATUS.CPU_RX_FULL, a ping answered meanwhile.
//       6 CPU transmit: lengths 14..1518 byte-exact; 20 CPU frames
//         interleaved with 10 pings under 30 % egress ready, nothing lost, each
//         stream in order; priority: with egress held, a ping reply goes out
//         before a CPU frame queued earlier; guard rejects (10 and 1600 bytes)
//         counted in CPU_TX_REJECTED.
//       7 CTRL.CPU_PATH_ENABLE = 0: nothing copied, CPU frames discarded and
//         counted, hardware still answers; re-enabled.
//     After every phase: DELIVERED_FRAMES = CPU_RX_CLAIMED + CPU_RX_FRAMES +
//     CPU_RX_DROPPED (while the path is enabled), CPU_RX_CLAIMED = the sum of
//     the leaf claim pulses, CPU_RX_FRAMES = frames received at m_axis_cpu_eth,
//     the ingress identity and EGRESS_FRAMES = frames received at m_axis.
//   * +INJECT_FAILURE forces TEST FAIL (negative control).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: axis_clk, proto_clk (also app_clk), s_axi_aclk, cpu_axis_clk.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_eth_protocol_cpu;

  import rtlnet_tb_pkg::*;
  import rtlnet_tb_eth_frames_pkg::*;

  // ---------------------------------------------------------------------------
  // Register offsets (cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.h and
  // the leaf headers).
  // ---------------------------------------------------------------------------
  localparam logic [15:0] R_CAPS       = 16'h0008;
  localparam logic [15:0] R_CTRL       = 16'h000C;
  localparam logic [15:0] R_STATUS     = 16'h0010;
  localparam logic [15:0] R_CPU_CAPS   = 16'h0034;
  localparam logic [15:0] R_IN_FRAMES  = 16'h0040;
  localparam logic [15:0] R_IN_FILT    = 16'h0044;
  localparam logic [15:0] R_IN_DROP    = 16'h0048;
  localparam logic [15:0] R_EG_FRAMES  = 16'h004C;
  localparam logic [15:0] R_DELIVERED  = 16'h0050;
  localparam logic [15:0] R_CPU_RX     = 16'h0054;
  localparam logic [15:0] R_CPU_CLAIM  = 16'h0058;
  localparam logic [15:0] R_CPU_DROP   = 16'h005C;
  localparam logic [15:0] R_CPU_TX     = 16'h0060;
  localparam logic [15:0] R_CPU_TXDISC = 16'h0064;
  localparam logic [15:0] R_CPU_TXREJ  = 16'h0068;
  localparam logic [15:0] R_DHCP_CTRL  = 16'h300C;
  localparam logic [15:0] R_DHCP_XID   = 16'h302C;
  localparam logic [15:0] R_UDP_S0_CTRL = 16'h5100;
  localparam logic [15:0] R_UDP_S0_PORT = 16'h5104;
  localparam logic [31:0] CTRL_DEFAULT = 32'h0000_1F03;   // filter, CPU path, all five leaves
  localparam logic [31:0] CTRL_NO_CPU  = 32'h0000_1F01;

  localparam logic [47:0] DEF_MAC      = 48'h02_49_4B_52_4E_01;
  localparam logic [31:0] DEF_IP       = 32'hC0A901DC;
  localparam logic [47:0] PEER_MAC     = 48'h02_11_22_33_44_55;
  localparam logic [31:0] PEER_IP      = 32'hC0A90109;
  localparam logic [47:0] SERVER_MAC   = 48'h02_99_88_77_66_55;
  localparam logic [31:0] SERVER_IP    = 32'hC0A90101;
  localparam logic [31:0] OFFER_IP     = 32'hC0A90177;
  localparam logic [15:0] SOCK_PORT    = 16'd7000;
  localparam logic [15:0] CPU_ETYPE    = 16'h88B5;          // local experimental EtherType
  localparam int          ARP_WAIT     = 4000;
  localparam int          CPU_WAIT     = 20000;             // cpu_axis_clk clocks
  localparam int          CPU_SLOTS    = 8;                 // CPU_RX_FIFO_KB 16, 1518-byte frames

  // ---------------------------------------------------------------------------
  // Clocks and resets.
  // ---------------------------------------------------------------------------
  real  axis_half  = 8.000;
  real  proto_half = 10.0015;
  real  axi_half   = 5.000;
  real  cpu_half   = 4.9985;
  int   clkpair    = 1;
  logic axis_clk   = 1'b0;
  logic proto_clk  = 1'b0;
  logic s_axi_aclk = 1'b0;
  logic cpu_clk    = 1'b0;
  logic axis_resetn   = 1'b0;
  logic proto_resetn  = 1'b0;
  logic s_axi_aresetn = 1'b0;
  logic cpu_resetn    = 1'b0;

  initial begin
    if (!$value$plusargs("CLKPAIR=%d", clkpair)) clkpair = 1;
    case (clkpair)
      2:       begin axis_half = 3.200;  proto_half = 10.0015; end
      3:       begin axis_half = 10.000; proto_half = 8.0035;  end
      default: begin axis_half = 8.000;  proto_half = 10.0015; end
    endcase
    $display("tb_rtlnet_eth_protocol_cpu: CLKPAIR=%0d axis_clk %0.3f ns, proto_clk %0.3f ns, cpu_axis_clk %0.3f ns",
             clkpair, 2.0 * axis_half, 2.0 * proto_half, 2.0 * cpu_half);
  end

  initial begin #1.3; forever #(axis_half)  axis_clk   = ~axis_clk;   end
  initial begin #3.7; forever #(proto_half) proto_clk  = ~proto_clk;  end
  initial begin #2.1; forever #(axi_half)   s_axi_aclk = ~s_axi_aclk; end
  initial begin #0.4; forever #(cpu_half)   cpu_clk    = ~cpu_clk;    end

  // One assertion for every domain, each released at its own clock.
  initial begin
    #500;
    @(posedge axis_clk)   axis_resetn   <= 1'b1;
    @(posedge proto_clk)  proto_resetn  <= 1'b1;
    @(posedge s_axi_aclk) s_axi_aresetn <= 1'b1;
    @(posedge cpu_clk)    cpu_resetn    <= 1'b1;
  end

  // ---------------------------------------------------------------------------
  // DUT and bench components.
  // ---------------------------------------------------------------------------
  logic [63:0] s_tdata;      logic [7:0] s_tkeep;      logic s_tvalid, s_tlast, s_tready;
  logic [63:0] m_tdata;      logic [7:0] m_tkeep;      logic m_tvalid, m_tlast, m_tready;
  logic [63:0] app_m_tdata;  logic [7:0] app_m_tkeep;  logic app_m_tvalid, app_m_tlast, app_m_tready;
  logic [63:0] app_s_tdata;  logic [7:0] app_s_tkeep;  logic app_s_tvalid, app_s_tlast, app_s_tready;
  logic [63:0] cm_tdata;     logic [7:0] cm_tkeep;     logic cm_tvalid, cm_tlast, cm_tready;
  logic [63:0] cs_tdata;     logic [7:0] cs_tkeep;     logic cs_tvalid, cs_tlast, cs_tready;
  logic [15:0] awaddr;       logic awvalid, awready;
  logic [31:0] wdata;        logic [3:0] wstrb;        logic wvalid, wready;
  logic [1:0]  bresp;        logic bvalid, bready;
  logic [15:0] araddr;       logic arvalid, arready;
  logic [31:0] rdata;        logic [1:0] rresp;        logic rvalid, rready;
  logic        stat_ip_valid, stat_dhcp_bound, ev_rx_frame, ev_tx_frame;

  rtlnet_eth_protocol #(
    .PROTO_CLK_HZ          (50_000_000),
    .INGRESS_FIFO_KB       (16),
    .EGRESS_FIFO_KB        (8),
    .ARP_ENABLE            (1),
    .ICMP_ENABLE           (1),
    .DHCP_ENABLE           (1),
    .IPERF_ENABLE          (1),
    .UDP_ENABLE            (1),
    .CPU_PATH_ENABLE       (1),
    .CPU_RX_FIFO_KB        (16),
    .CPU_TX_FIFO_KB        (8),
    .CPU_CLASSIFIER_ENABLE (0)
  ) dut (
    .axis_clk              (axis_clk),
    .proto_clk             (proto_clk),
    .app_clk               (proto_clk),
    .s_axi_aclk            (s_axi_aclk),
    .axis_resetn           (axis_resetn),
    .proto_resetn          (proto_resetn),
    .app_resetn            (proto_resetn),
    .s_axi_aresetn         (s_axi_aresetn),
    .s_axis_tdata          (s_tdata),
    .s_axis_tkeep          (s_tkeep),
    .s_axis_tvalid         (s_tvalid),
    .s_axis_tlast          (s_tlast),
    .s_axis_tready         (s_tready),
    .m_axis_tdata          (m_tdata),
    .m_axis_tkeep          (m_tkeep),
    .m_axis_tvalid         (m_tvalid),
    .m_axis_tlast          (m_tlast),
    .m_axis_tready         (m_tready),
    .m_axis_app_tdata      (app_m_tdata),
    .m_axis_app_tkeep      (app_m_tkeep),
    .m_axis_app_tvalid     (app_m_tvalid),
    .m_axis_app_tlast      (app_m_tlast),
    .m_axis_app_tready     (app_m_tready),
    .s_axis_app_tdata      (app_s_tdata),
    .s_axis_app_tkeep      (app_s_tkeep),
    .s_axis_app_tvalid     (app_s_tvalid),
    .s_axis_app_tlast      (app_s_tlast),
    .s_axis_app_tready     (app_s_tready),
    .s_axi_awaddr          (awaddr),
    .s_axi_awvalid         (awvalid),
    .s_axi_awready         (awready),
    .s_axi_wdata           (wdata),
    .s_axi_wstrb           (wstrb),
    .s_axi_wvalid          (wvalid),
    .s_axi_wready          (wready),
    .s_axi_bresp           (bresp),
    .s_axi_bvalid          (bvalid),
    .s_axi_bready          (bready),
    .s_axi_araddr          (araddr),
    .s_axi_arvalid         (arvalid),
    .s_axi_arready         (arready),
    .s_axi_rdata           (rdata),
    .s_axi_rresp           (rresp),
    .s_axi_rvalid          (rvalid),
    .s_axi_rready          (rready),
    .cpu_axis_clk          (cpu_clk),
    .cpu_axis_resetn       (cpu_resetn),
    .m_axis_cpu_eth_tdata  (cm_tdata),
    .m_axis_cpu_eth_tkeep  (cm_tkeep),
    .m_axis_cpu_eth_tvalid (cm_tvalid),
    .m_axis_cpu_eth_tlast  (cm_tlast),
    .m_axis_cpu_eth_tready (cm_tready),
    .s_axis_cpu_eth_tdata  (cs_tdata),
    .s_axis_cpu_eth_tkeep  (cs_tkeep),
    .s_axis_cpu_eth_tvalid (cs_tvalid),
    .s_axis_cpu_eth_tlast  (cs_tlast),
    .s_axis_cpu_eth_tready (cs_tready),
    .stat_ip_valid         (stat_ip_valid),
    .stat_dhcp_bound       (stat_dhcp_bound),
    .ev_rx_frame           (ev_rx_frame),
    .ev_tx_frame           (ev_tx_frame)
  );

  // MAC side.
  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(3)) u_src (
    .clk(axis_clk), .tdata(s_tdata), .tkeep(s_tkeep), .tlast(s_tlast), .tvalid(s_tvalid), .tready(s_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(9), .NAME("m_axis")) u_sink (
    .clk(axis_clk), .resetn(axis_resetn), .tdata(m_tdata), .tkeep(m_tkeep), .tlast(m_tlast), .tvalid(m_tvalid),
    .tready(m_tready));
  // CPU side.
  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(21)) u_cpu_src (
    .clk(cpu_clk), .tdata(cs_tdata), .tkeep(cs_tkeep), .tlast(cs_tlast), .tvalid(cs_tvalid), .tready(cs_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(27), .NAME("m_axis_cpu_eth")) u_cpu_sink (
    .clk(cpu_clk), .resetn(cpu_resetn), .tdata(cm_tdata), .tkeep(cm_tkeep), .tlast(cm_tlast), .tvalid(cm_tvalid),
    .tready(cm_tready));
  // Socket application side (app_clk = proto_clk).
  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(33)) u_app_src (
    .clk(proto_clk), .tdata(app_s_tdata), .tkeep(app_s_tkeep), .tlast(app_s_tlast), .tvalid(app_s_tvalid),
    .tready(app_s_tready));
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(39), .NAME("m_axis_app")) u_app_sink (
    .clk(proto_clk), .resetn(proto_resetn), .tdata(app_m_tdata), .tkeep(app_m_tkeep), .tlast(app_m_tlast),
    .tvalid(app_m_tvalid), .tready(app_m_tready));
  // Register master.
  rtlnet_tb_axil_master #(.ADDR_W(16)) u_axi (
    .aclk(s_axi_aclk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  // Leaf-contract monitors on the five leaves inside the wrapper (index 0 UDP,
  // 1 ICMP, 2 ARP, 3 DHCP, 4 iperf).
  rtlnet_tb_leaf_busy_monitor #(.NAME("udp"))   u_busy0 (.clk(proto_clk), .resetn(proto_resetn),
    .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[0]), .s_tlast(dut.iq_last),
    .m_tvalid(dut.leaf_tvalid[0]), .m_tready(dut.leaf_tready[0]), .m_tlast(dut.leaf_tlast[0]), .busy(dut.leaf_busy[0]));
  rtlnet_tb_leaf_busy_monitor #(.NAME("icmp"))  u_busy1 (.clk(proto_clk), .resetn(proto_resetn),
    .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[1]), .s_tlast(dut.iq_last),
    .m_tvalid(dut.leaf_tvalid[1]), .m_tready(dut.leaf_tready[1]), .m_tlast(dut.leaf_tlast[1]), .busy(dut.leaf_busy[1]));
  rtlnet_tb_leaf_busy_monitor #(.NAME("arp"))   u_busy2 (.clk(proto_clk), .resetn(proto_resetn),
    .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[2]), .s_tlast(dut.iq_last),
    .m_tvalid(dut.leaf_tvalid[2]), .m_tready(dut.leaf_tready[2]), .m_tlast(dut.leaf_tlast[2]), .busy(dut.leaf_busy[2]));
  rtlnet_tb_leaf_busy_monitor #(.NAME("dhcp"))  u_busy3 (.clk(proto_clk), .resetn(proto_resetn),
    .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[3]), .s_tlast(dut.iq_last),
    .m_tvalid(dut.leaf_tvalid[3]), .m_tready(dut.leaf_tready[3]), .m_tlast(dut.leaf_tlast[3]), .busy(dut.leaf_busy[3]));
  rtlnet_tb_leaf_busy_monitor #(.NAME("iperf")) u_busy4 (.clk(proto_clk), .resetn(proto_resetn),
    .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[4]), .s_tlast(dut.iq_last),
    .m_tvalid(dut.leaf_tvalid[4]), .m_tready(dut.leaf_tready[4]), .m_tlast(dut.leaf_tlast[4]), .busy(dut.leaf_busy[4]));
  rtlnet_tb_leaf_claim_monitor #(.NAME("udp"))   u_claim0 (.clk(proto_clk), .resetn(proto_resetn),
    .enable(dut.leaf_enable[0]), .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[0]), .s_tlast(dut.iq_last),
    .busy(dut.leaf_busy[0]), .claim(dut.leaf_claim[0]));
  rtlnet_tb_leaf_claim_monitor #(.NAME("icmp"))  u_claim1 (.clk(proto_clk), .resetn(proto_resetn),
    .enable(dut.leaf_enable[1]), .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[1]), .s_tlast(dut.iq_last),
    .busy(dut.leaf_busy[1]), .claim(dut.leaf_claim[1]));
  rtlnet_tb_leaf_claim_monitor #(.NAME("arp"))   u_claim2 (.clk(proto_clk), .resetn(proto_resetn),
    .enable(dut.leaf_enable[2]), .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[2]), .s_tlast(dut.iq_last),
    .busy(dut.leaf_busy[2]), .claim(dut.leaf_claim[2]));
  rtlnet_tb_leaf_claim_monitor #(.NAME("dhcp"))  u_claim3 (.clk(proto_clk), .resetn(proto_resetn),
    .enable(dut.leaf_enable[3]), .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[3]), .s_tlast(dut.iq_last),
    .busy(dut.leaf_busy[3]), .claim(dut.leaf_claim[3]));
  rtlnet_tb_leaf_claim_monitor #(.NAME("iperf")) u_claim4 (.clk(proto_clk), .resetn(proto_resetn),
    .enable(dut.leaf_enable[4]), .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[4]), .s_tlast(dut.iq_last),
    .busy(dut.leaf_busy[4]), .claim(dut.leaf_claim[4]));

  // ---------------------------------------------------------------------------
  // Bench state and expectations.
  // ---------------------------------------------------------------------------
  int          seed         = 4321;
  int          offered      = 0;      // frames offered at s_axis
  int          exp_filtered = 0;
  int          received     = 0;      // frames taken at m_axis
  int          cpu_received = 0;      // frames taken at m_axis_cpu_eth
  int          exp_claims[5] = '{0, 0, 0, 0, 0};
  int          claims_off   = 0;      // claims while the CPU path was disabled (not in CPU_RX_CLAIMED)
  int          delivered_off = 0;     // frames dequeued while the CPU path was disabled
  int          cpu_tx_sent  = 0;      // good CPU frames expected at m_axis
  bit [15:0]   cpu_seq      = 16'd0;
  bit [15:0]   ip_ident     = 16'h0200;

  function automatic int claims_total();
    return u_claim0.claims + u_claim1.claims + u_claim2.claims + u_claim3.claims + u_claim4.claims;
  endfunction

  // ---------------------------------------------------------------------------
  // Tasks.
  // ---------------------------------------------------------------------------
  task automatic axi_wr(input logic [15:0] addr, input logic [31:0] data);
    u_axi.wr(addr, data);
  endtask

  task automatic axi_rd(input logic [15:0] addr, output logic [31:0] data);
    u_axi.rd(addr, data);
  endtask

  task automatic axi_expect(input logic [15:0] addr, input logic [31:0] exp, input string what);
    logic [31:0] v;
    u_axi.rd(addr, v);
    tb_check(v === exp, $sformatf("%s (0x%04x) = 0x%08x, expected 0x%08x", what, addr, v, exp));
  endtask

  task automatic wait_proto(input int n);
    repeat (n) @(posedge proto_clk);
  endtask

  // Offer one frame at s_axis (it passes the filter) and leave room behind it
  // so the ingress queue never fills.
  task automatic offer(input bytes_t f);
    u_src.send(f);
    offered++;
    wait_proto(40);
  endtask

  task automatic expect_mac(input string tag, input bytes_t exp, input int timeout_cycles);
    bytes_t got;
    bit     ok;
    string  why;
    u_sink.get(got, timeout_cycles, ok);
    tb_check(ok, $sformatf("%s: a frame at m_axis", tag));
    if (ok) begin
      received++;
      tb_check(bytes_equal(got, exp, why), $sformatf("%s: m_axis byte-exact (%s) got %s", tag, why, hexdump(got)));
    end
  endtask

  // The next frame at m_axis, unchecked content, with a length check.
  task automatic expect_mac_len(input string tag, input int len, input int timeout_cycles, output bytes_t got);
    bit ok;
    u_sink.get(got, timeout_cycles, ok);
    tb_check(ok, $sformatf("%s: a frame at m_axis", tag));
    if (ok) begin
      received++;
      tb_check(got.size() == len, $sformatf("%s: length %0d, expected %0d", tag, got.size(), len));
    end
  endtask

  task automatic expect_mac_none(input string tag, input int cycles);
    bit none;
    u_sink.expect_none(cycles, none);
    tb_check(none, $sformatf("%s: no frame at m_axis", tag));
    while (u_sink.frames.size() > 0) begin
      void'(u_sink.frames.pop_front());
      received++;
    end
  endtask

  task automatic expect_cpu(input string tag, input bytes_t exp, input int timeout_cycles = CPU_WAIT);
    bytes_t got;
    bit     ok;
    string  why;
    u_cpu_sink.get(got, timeout_cycles, ok);
    tb_check(ok, $sformatf("%s: a frame at m_axis_cpu_eth", tag));
    if (ok) begin
      cpu_received++;
      tb_check(bytes_equal(got, exp, why), $sformatf("%s: m_axis_cpu_eth byte-exact (%s) got %s", tag, why,
                                                      hexdump(got)));
    end
  endtask

  task automatic expect_cpu_none(input string tag, input int cycles = 3000);
    bit none;
    u_cpu_sink.expect_none(cycles, none);
    tb_check(none, $sformatf("%s: not copied to the CPU", tag));
    while (u_cpu_sink.frames.size() > 0) begin
      void'(u_cpu_sink.frames.pop_front());
      cpu_received++;
    end
  endtask

  // A frame the CPU sends: Ethernet header with the bench EtherType, a
  // sequence number, a random payload; total length len (>= 14).
  function automatic bytes_t cpu_frame(input int len, input bit [15:0] seq);
    bytes_t q;
    bytes_t r;
    q = eth_header(PEER_MAC, DEF_MAC, CPU_ETYPE);
    if (len >= 16) push16(q, seq);
    r = rand_bytes(seed, len - q.size());
    for (int i = 0; i < $size(r); i++) q.push_back(r[i]);
    while (q.size() > len) void'(q.pop_back());
    return q;
  endfunction

  function automatic bytes_t arp_reply_to_us();
    bytes_t q;
    q = eth_header(DEF_MAC, PEER_MAC, 16'h0806);
    push16(q, 16'h0001); push16(q, 16'h0800); q.push_back(8'd6); q.push_back(8'd4); push16(q, 16'h0002);
    push48(q, PEER_MAC); push32(q, PEER_IP); push48(q, DEF_MAC); push32(q, DEF_IP);
    return pad60(q);
  endfunction

  function automatic bytes_t tcp_syn(input bit [15:0] dport);
    bytes_t q;
    bytes_t ip;
    q  = eth_header(DEF_MAC, PEER_MAC, 16'h0800);
    ip = ipv4_header(16'd40, 16'h0777, 8'd6, PEER_IP, DEF_IP);
    for (int i = 0; i < $size(ip); i++) q.push_back(ip[i]);
    push16(q, 16'd49152); push16(q, dport); push32(q, 32'h1234_5678); push32(q, 32'd0);
    q.push_back(8'h50); q.push_back(8'h02); push16(q, 16'hFAF0); push16(q, 16'h0000); push16(q, 16'h0000);
    return pad60(q);
  endfunction

  // An ICMP message of another type to the local IP (correct checksum).
  function automatic bytes_t icmp_other(input byte unsigned icmp_type);
    bytes_t    q;
    bit [15:0] c;
    q = echo_request(DEF_MAC, PEER_MAC, PEER_IP, DEF_IP, 16'h0042, 16'h0001, rand_bytes(seed, 20));
    q[34] = icmp_type;
    q[36] = 8'h00; q[37] = 8'h00;
    c = inet_checksum(q, 34, q.size() - 34);
    q[36] = c[15:8]; q[37] = c[7:0];
    return pad60(q);
  endfunction

  function automatic bytes_t udp_to(input bit [47:0] dmac, input bit [31:0] dip, input bit [15:0] dport,
                                    input bytes_t payload);
    ip_ident++;
    return pad60(udp_frame(dmac, PEER_MAC, PEER_IP, dip, 16'd40000, dport, payload, ip_ident));
  endfunction

  // A DHCPOFFER from the server for chaddr = DEF_MAC (broadcast, UDP 67 -> 68).
  function automatic bytes_t dhcp_offer(input bit [31:0] xid);
    bytes_t b;
    bytes_t q;
    b.push_back(8'd2); b.push_back(8'd1); b.push_back(8'd6); b.push_back(8'd0);
    push32(b, xid); push16(b, 16'd0); push16(b, 16'h8000);
    push32(b, 32'd0); push32(b, OFFER_IP); push32(b, SERVER_IP); push32(b, 32'd0);
    push48(b, DEF_MAC);
    for (int i = 0; i < 10 + 192; i++) b.push_back(8'h00);
    push32(b, 32'h6382_5363);
    b.push_back(8'd53); b.push_back(8'd1); b.push_back(8'd2);
    b.push_back(8'd54); b.push_back(8'd4); push32(b, SERVER_IP);
    b.push_back(8'd51); b.push_back(8'd4); push32(b, 32'd86400);
    b.push_back(8'd1);  b.push_back(8'd4); push32(b, 32'hFFFF_FF00);
    b.push_back(8'd255);
    ip_ident++;
    q = udp_frame(48'hFFFF_FFFF_FFFF, SERVER_MAC, SERVER_IP, 32'hFFFF_FFFF, 16'd67, 16'd68, b, ip_ident);
    return pad60(q);
  endfunction

  // iperf 2 data datagram with sequence seq (no client header).
  function automatic bytes_t iperf_dgram(input bit [31:0] seq);
    bytes_t p;
    push32(p, seq); push32(p, 32'd1_790_000_000); push32(p, 32'd100_000); push32(p, 32'd0);
    while (p.size() < 40) p.push_back(8'h30 + 8'(p.size() % 10));
    return udp_to(DEF_MAC, DEF_IP, 16'd5001, p);
  endfunction

  // Counter identities after traffic has settled.
  task automatic check_counters(input string tag);
    logic [31:0] fr;
    logic [31:0] fi;
    logic [31:0] dr;
    logic [31:0] eg;
    logic [31:0] dl;
    logic [31:0] cr;
    logic [31:0] cc;
    logic [31:0] cd;
    wait_proto(200);
    axi_rd(R_IN_FRAMES, fr);
    axi_rd(R_IN_FILT, fi);
    axi_rd(R_IN_DROP, dr);
    axi_rd(R_EG_FRAMES, eg);
    axi_rd(R_DELIVERED, dl);
    axi_rd(R_CPU_RX, cr);
    axi_rd(R_CPU_CLAIM, cc);
    axi_rd(R_CPU_DROP, cd);
    tb_check(fr + fi + dr == 32'(offered), $sformatf("%s: ingress identity offered %0d = %0d + %0d + %0d", tag, offered,
             fr, fi, dr));
    tb_check(dr == 0 && fi == 32'(exp_filtered), $sformatf("%s: no ingress drops (%0d), filtered %0d", tag, dr, fi));
    tb_check(dl == fr, $sformatf("%s: DELIVERED_FRAMES %0d = INGRESS_FRAMES %0d", tag, dl, fr));
    tb_check(dl - 32'(delivered_off) == cr + cc + cd,
             $sformatf("%s: CPU identity DELIVERED %0d (- %0d with the path off) = TO_CPU %0d + CLAIMED %0d + DROPPED %0d",
                       tag, dl, delivered_off, cr, cc, cd));
    tb_check(cc == 32'(claims_total() - claims_off), $sformatf("%s: CPU_RX_CLAIMED %0d = leaf claims %0d - %0d", tag, cc,
             claims_total(), claims_off));
    tb_check(cr == 32'(cpu_received + u_cpu_sink.frames.size()), $sformatf("%s: CPU_RX_FRAMES %0d = frames at the CPU %0d",
             tag, cr, cpu_received + u_cpu_sink.frames.size()));
    tb_check(eg == 32'(received + u_sink.frames.size()), $sformatf("%s: EGRESS_FRAMES %0d = frames at m_axis %0d", tag, eg,
             received + u_sink.frames.size()));
    tb_check(u_claim0.claims == exp_claims[0] && u_claim1.claims == exp_claims[1] && u_claim2.claims == exp_claims[2] &&
             u_claim3.claims == exp_claims[3] && u_claim4.claims == exp_claims[4],
             $sformatf("%s: claims udp %0d/%0d icmp %0d/%0d arp %0d/%0d dhcp %0d/%0d iperf %0d/%0d", tag,
                       u_claim0.claims, exp_claims[0], u_claim1.claims, exp_claims[1], u_claim2.claims, exp_claims[2],
                       u_claim3.claims, exp_claims[3], u_claim4.claims, exp_claims[4]));
  endtask

  // ---------------------------------------------------------------------------
  // The phases.
  // ---------------------------------------------------------------------------
  initial begin : main
    bytes_t      f;
    bytes_t      g;
    bytes_t      got;
    bytes_t      q[$];
    bytes_t      cpu_q[$];
    bytes_t      ping_q[$];
    logic [31:0] v;
    logic [31:0] v0;
    logic [31:0] xid;
    bit          ok;
    string       why;
    int          n_cpu;
    int          n_ping;
    int          ping_pos;
    int          last_pos;

    wait (axis_resetn && proto_resetn && s_axi_aresetn && cpu_resetn);
    wait_proto(40);

    // ---- 1. Register map.
    axi_expect(R_CAPS, 32'h0408_103F, "CAPS (all leaves, CPU path, 16/8 KB, 4 sockets)");
    axi_expect(R_CPU_CAPS, 32'h0000_0810, "CPU_CAPS (RX 16 KB, TX 8 KB)");
    axi_expect(R_CTRL, CTRL_DEFAULT, "CTRL at reset");
    axi_expect(R_STATUS, 32'h0000_0002, "STATUS at reset (no CPU flags)");
    for (int a = 16'h0050; a <= 16'h0068; a += 4) axi_expect(16'(a), 32'h0, "CPU counter at reset");
    axi_expect(16'h8000, 32'h0, "classifier window (not built)");
    tb_check(cs_tready === 1'b1 && cm_tvalid === 1'b0, "CPU streams idle and ready after reset");

    // ---- 2. Answered by hardware, never copied to the CPU.
    f = pad60(arp_request(PEER_MAC, PEER_IP, DEF_IP));
    offer(f);
    exp_claims[2]++;
    expect_mac("ARP request for us", arp_reply(f, DEF_MAC, DEF_IP), 20 * ARP_WAIT);
    expect_cpu_none("ARP request for us");
    for (int n = 0; n < 3; n++) begin
      f = pad60(echo_request(DEF_MAC, PEER_MAC, PEER_IP, DEF_IP, 16'h7A01, 16'(n), rand_bytes(seed, 16 + 600 * n)));
      offer(f);
      exp_claims[1]++;
      expect_mac($sformatf("ping %0d", n), echo_reply(f, DEF_MAC, DEF_IP), 40000);
    end
    expect_cpu_none("pings");
    check_counters("after hardware answers");

    // ---- 3. Unclaimed frames reach the CPU byte-exact.
    f = arp_reply_to_us();
    offer(f);
    expect_cpu("ARP reply to us", f);
    f = tcp_syn(16'd7);
    offer(f);
    expect_cpu("TCP SYN to our IP", f);
    f = udp_to(DEF_MAC, DEF_IP, 16'd9999, rand_bytes(seed, 100));
    offer(f);
    expect_cpu("UDP to an unknown port", f);
    f = pad60(arp_request(PEER_MAC, PEER_IP, 32'hC0A901FE));
    offer(f);
    expect_cpu("ARP request for another IP (broadcast)", f);
    f = icmp_other(8'd0);
    offer(f);
    expect_cpu("ICMP echo reply to us", f);
    f = icmp_other(8'd13);
    offer(f);
    expect_cpu("ICMP timestamp request to us", f);
    f = pad60(eth_header(DEF_MAC, PEER_MAC, 16'h86DD));
    offer(f);
    expect_cpu("IPv6 frame to our MAC", f);
    f = udp_to(DEF_MAC, DEF_IP, 16'd9998, rand_bytes(seed, 1472));
    offer(f);
    expect_cpu("UDP to an unknown port, 1514 bytes", f);
    expect_mac_none("unclaimed frames", 3000);
    check_counters("after unclaimed frames");

    // ---- 4. Every leaf claims its own traffic.
    axi_wr(R_UDP_S0_PORT, {16'd0, SOCK_PORT});
    axi_wr(R_UDP_S0_CTRL, 32'h1);
    f = udp_to(DEF_MAC, DEF_IP, SOCK_PORT, rand_bytes(seed, 64));
    offer(f);
    exp_claims[0]++;
    u_app_sink.get(got, 20000, ok);
    tb_check(ok && got.size() == 16 + 64, $sformatf("UDP to the enabled socket delivered to the application (%0d bytes)",
             got.size()));
    expect_cpu_none("UDP to the enabled socket");
    f = iperf_dgram(32'd1);
    offer(f);
    exp_claims[4]++;
    expect_cpu_none("UDP to the iperf port");
    f = udp_to(DEF_MAC, DEF_IP, SOCK_PORT + 16'd1, rand_bytes(seed, 30));
    offer(f);
    expect_cpu("UDP to another port", f);
    // DHCP: START, DISCOVER out, OFFER for the current xid claimed (REQUEST out).
    axi_wr(R_DHCP_CTRL, 32'h1);
    expect_mac_len("DHCP DISCOVER", 342, 40000, got);
    axi_rd(R_DHCP_XID, xid);
    tb_check(got.size() >= 50 && get32(got, 46) == xid, $sformatf("DISCOVER carries XID 0x%08x", xid));
    f = dhcp_offer(xid ^ 32'h0000_0100);
    offer(f);
    expect_cpu("DHCP OFFER with a wrong xid", f);
    expect_mac_none("DHCP OFFER with a wrong xid", 3000);
    f = dhcp_offer(xid);
    offer(f);
    exp_claims[3]++;
    expect_mac_len("DHCP REQUEST after the OFFER", 342, 40000, got);
    expect_cpu_none("DHCP OFFER for our xid");
    axi_wr(R_DHCP_CTRL, 32'h2);
    expect_mac_none("DHCP STOP without a lease", 2000);
    check_counters("after the leaves");

    // ---- 5. CPU stalled: the CPU queue fills, frames are dropped and counted,
    // hardware keeps answering.
    axi_rd(R_CPU_DROP, v0);
    u_cpu_sink.ready_pct = 0;
    q.delete();
    for (int n = 0; n < CPU_SLOTS + 4; n++) begin
      q.push_back(udp_to(DEF_MAC, DEF_IP, 16'(20000 + n), rand_bytes(seed, 40 + 37 * n)));
      offer(q[n]);
    end
    wait_proto(200);
    axi_rd(R_STATUS, v);
    tb_check(v[20] === 1'b1, $sformatf("STATUS.CPU_RX_FULL while the CPU is stalled (0x%08x)", v));
    axi_rd(R_CPU_DROP, v);
    tb_check(v - v0 == 32'd4, $sformatf("CPU stalled: CPU_RX_DROPPED +%0d, expected 4", v - v0));
    f = pad60(echo_request(DEF_MAC, PEER_MAC, PEER_IP, DEF_IP, 16'h7A02, 16'd9, rand_bytes(seed, 200)));
    offer(f);
    exp_claims[1]++;
    expect_mac("ping while the CPU is stalled", echo_reply(f, DEF_MAC, DEF_IP), 40000);
    f = udp_to(DEF_MAC, DEF_IP, 16'd30000, rand_bytes(seed, 10));
    offer(f);                                                                  // dropped too
    tb_check(u_cpu_sink.frames.size() == 0, "CPU stalled: nothing completed at m_axis_cpu_eth");
    u_cpu_sink.ready_pct = 100;
    for (int n = 0; n < CPU_SLOTS; n++) expect_cpu($sformatf("kept frame %0d after the stall", n), q[n]);
    expect_cpu_none("dropped frames after the stall");
    axi_rd(R_STATUS, v);
    tb_check(v[20] === 1'b0, "STATUS.CPU_RX_FULL clear after the drain");
    check_counters("after the CPU stall");

    // ---- 6. CPU transmit.
    // Lengths, byte-exact.
    axi_rd(R_CPU_TX, v0);
    q.delete();
    q.push_back(cpu_frame(14, cpu_seq++));
    q.push_back(cpu_frame(15, cpu_seq++));
    q.push_back(cpu_frame(60, cpu_seq++));
    q.push_back(cpu_frame(61, cpu_seq++));
    q.push_back(cpu_frame(1000, cpu_seq++));
    q.push_back(cpu_frame(1517, cpu_seq++));
    q.push_back(cpu_frame(1518, cpu_seq++));
    for (int n = 0; n < $size(q); n++) u_cpu_src.send(q[n]);
    for (int n = 0; n < $size(q); n++) expect_mac($sformatf("CPU frame of %0d bytes", q[n].size()), q[n], 40000);
    axi_rd(R_CPU_TX, v);
    tb_check(v - v0 == 32'($size(q)), $sformatf("CPU_TX_FRAMES +%0d, expected %0d", v - v0, $size(q)));
    // Interleaved with pings under egress back-pressure: nothing lost, each stream in order.
    cpu_q.delete();
    ping_q.delete();
    for (int n = 0; n < 20; n++) cpu_q.push_back(cpu_frame(60 + (n * 97) % 900, cpu_seq++));
    for (int n = 0; n < 10; n++)
      ping_q.push_back(pad60(echo_request(DEF_MAC, PEER_MAC, PEER_IP, DEF_IP, 16'h7A03, 16'(n),
                                          rand_bytes(seed, (n * 131) % 500))));
    u_sink.ready_pct = 30;
    fork
      for (int n = 0; n < $size(cpu_q); n++) begin
        u_cpu_src.send(cpu_q[n]);
        repeat (n % 3) @(posedge cpu_clk);
      end
      for (int n = 0; n < $size(ping_q); n++) begin
        offer(ping_q[n]);
        wait_proto(100);
      end
    join
    n_cpu  = 0;
    n_ping = 0;
    ok     = 1'b1;
    while (ok && (n_cpu < $size(cpu_q) || n_ping < $size(ping_q))) begin
      u_sink.get(got, 400000, ok);
      if (ok) begin
        received++;
        if (got.size() >= 14 && get16(got, 12) == CPU_ETYPE) begin
          if (n_cpu < $size(cpu_q))
            tb_check(bytes_equal(got, cpu_q[n_cpu], why), $sformatf("interleaved CPU frame %0d in order, byte-exact (%s)",
                     n_cpu, why));
          n_cpu++;
        end else begin
          if (n_ping < $size(ping_q))
            tb_check(bytes_equal(got, echo_reply(ping_q[n_ping], DEF_MAC, DEF_IP), why),
                     $sformatf("interleaved ping reply %0d in order, byte-exact (%s)", n_ping, why));
          n_ping++;
        end
      end
    end
    exp_claims[1] += $size(ping_q);
    tb_check(n_cpu == $size(cpu_q) && n_ping == $size(ping_q),
             $sformatf("interleaved: %0d/%0d CPU frames, %0d/%0d ping replies", n_cpu, $size(cpu_q), n_ping, $size(ping_q)));
    u_sink.ready_pct = 100;
    expect_mac_none("after the interleaved traffic", 2000);
    // Priority: egress held; six CPU frames queue, then a ping; the reply leaves
    // before the last CPU frame (the CPU is the lowest-priority source).
    u_sink.ready_pct = 0;
    cpu_q.delete();
    for (int n = 0; n < 6; n++) begin
      cpu_q.push_back(cpu_frame(200, cpu_seq++));
      u_cpu_src.send(cpu_q[n]);
    end
    wait_proto(2000);
    f = pad60(echo_request(DEF_MAC, PEER_MAC, PEER_IP, DEF_IP, 16'h7A04, 16'd1, rand_bytes(seed, 40)));
    offer(f);
    exp_claims[1]++;
    wait_proto(500);
    tb_check(dut.leaf_tvalid[1] === 1'b1 && dut.cpu_src_tvalid === 1'b1,
             "priority: the ping reply and a CPU frame both wait at the arbiter");
    u_sink.ready_pct = 100;
    ping_pos = -1;
    last_pos = -1;
    for (int n = 0; n < 7; n++) begin
      u_sink.get(got, 40000, ok);
      tb_check(ok, $sformatf("priority: frame %0d after the release", n));
      if (ok) begin
        received++;
        if (get16(got, 12) == CPU_ETYPE) begin
          if (bytes_equal(got, cpu_q[5], why)) last_pos = n;
        end else begin
          ping_pos = n;
          tb_check(bytes_equal(got, echo_reply(f, DEF_MAC, DEF_IP), why), $sformatf("priority: ping reply (%s)", why));
        end
      end
    end
    tb_check(ping_pos >= 0 && last_pos >= 0 && ping_pos < last_pos,
             $sformatf("priority: ping reply at %0d before the last queued CPU frame at %0d", ping_pos, last_pos));
    // Guard: 10-byte and 1600-byte CPU frames are rejected and counted.
    axi_rd(R_CPU_TXREJ, v0);
    u_cpu_src.send(cpu_frame(10, cpu_seq++));
    u_cpu_src.send(cpu_frame(1600, cpu_seq++));
    g = cpu_frame(64, cpu_seq++);
    u_cpu_src.send(g);
    expect_mac("good CPU frame after two rejected ones", g, 40000);
    expect_mac_none("rejected CPU frames", 2000);
    axi_rd(R_CPU_TXREJ, v);
    tb_check(v - v0 == 32'd2, $sformatf("CPU_TX_REJECTED +%0d, expected 2", v - v0));
    check_counters("after CPU transmit");

    // ---- 7. CTRL.CPU_PATH_ENABLE = 0: nothing copied, CPU frames discarded.
    axi_wr(R_CTRL, CTRL_NO_CPU);
    axi_expect(R_CTRL, CTRL_NO_CPU, "CTRL with the CPU path disabled");
    wait_proto(20);
    begin
      logic [31:0] dl0;
      logic [31:0] cr0;
      logic [31:0] tx0;
      logic [31:0] ds0;
      int          c0;
      axi_rd(R_DELIVERED, dl0);
      axi_rd(R_CPU_RX, cr0);
      axi_rd(R_CPU_TX, tx0);
      axi_rd(R_CPU_TXDISC, ds0);
      c0 = claims_total();
      f = udp_to(DEF_MAC, DEF_IP, 16'd9999, rand_bytes(seed, 50));
      offer(f);
      expect_cpu_none("path disabled: unknown UDP");
      f = pad60(arp_request(PEER_MAC, PEER_IP, DEF_IP));
      offer(f);
      exp_claims[2]++;
      expect_mac("path disabled: ARP still answered", arp_reply(f, DEF_MAC, DEF_IP), 20 * ARP_WAIT);
      for (int n = 0; n < 3; n++) u_cpu_src.send(cpu_frame(100, cpu_seq++));
      expect_mac_none("path disabled: CPU frames discarded", 3000);
      axi_expect(R_CPU_TXDISC, ds0 + 32'd3, "CPU_TX_DISCARDED +3");
      axi_expect(R_CPU_TX, tx0, "CPU_TX_FRAMES unchanged while disabled");
      axi_expect(R_CPU_RX, cr0, "CPU_RX_FRAMES unchanged while disabled");
      axi_rd(R_DELIVERED, v);
      delivered_off += int'(v - dl0);
      claims_off    += claims_total() - c0;
      tb_check(v - dl0 == 32'd2, $sformatf("DELIVERED counts with the path disabled (+%0d)", v - dl0));
    end
    axi_wr(R_CTRL, CTRL_DEFAULT);
    wait_proto(20);
    f = udp_to(DEF_MAC, DEF_IP, 16'd9997, rand_bytes(seed, 70));
    offer(f);
    expect_cpu("path re-enabled: unknown UDP", f);
    g = cpu_frame(80, cpu_seq++);
    u_cpu_src.send(g);
    expect_mac("path re-enabled: CPU frame sent", g, 40000);
    check_counters("final");

    tb_check(u_busy0.ready_errors + u_busy1.ready_errors + u_busy2.ready_errors + u_busy3.ready_errors +
             u_busy4.ready_errors == 0, "leaves held s_axis_tready at 1");
    tb_check(u_claim0.errors + u_claim1.errors + u_claim2.errors + u_claim3.errors + u_claim4.errors == 0,
             "claim rule held on every leaf");
    $display("tb_rtlnet_eth_protocol_cpu: claims udp %0d icmp %0d arp %0d dhcp %0d iperf %0d; CPU frames %0d; m_axis %0d",
             u_claim0.claims, u_claim1.claims, u_claim2.claims, u_claim3.claims, u_claim4.claims, cpu_received, received);
    tb_verdict("tb_rtlnet_eth_protocol_cpu");
  end

  // Watchdog.
  initial begin
    #300ms;
    tb_error("watchdog: the bench did not finish");
    tb_verdict("tb_rtlnet_eth_protocol_cpu");
  end

endmodule
