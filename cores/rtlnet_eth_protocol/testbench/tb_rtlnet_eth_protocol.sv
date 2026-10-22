// -----------------------------------------------------------------------------
// File: tb_rtlnet_eth_protocol.sv
// Purpose: self-checking bench of the protocol wrapper rtlnet_eth_protocol with
//   its ARP and ICMP leaves (DHCP, iperf and UDP socket disabled), driven at
//   the MAC client streams (axis_clk) and through AXI4-Lite (s_axi_aclk
//   100 MHz).
// Overview:
//   * Clock pair from +CLKPAIR (unrelated periods, both directions):
//       1 (default) axis_clk 62.5 MHz (16.000 ns), proto_clk 50 MHz (20.003 ns)
//       2           axis_clk 156.25 MHz (6.400 ns), proto_clk 50 MHz (20.003 ns)
//       3           axis_clk 50 MHz (20.000 ns), proto_clk 62.5 MHz (16.007 ns)
//   * Oracles: bench-built requests and expected replies
//     (rtlnet_tb_eth_frames_pkg), byte-exact comparison; the bench counts
//     every frame it offers and checks offered = INGRESS_FILTERED +
//     INGRESS_FRAMES + INGRESS_DROPPED after every phase, EGRESS_FRAMES =
//     frames received, and the leaves' own counters through their windows.
//   * Always-on monitors: rtlnet_tb_leaf_busy_monitor on the ARP and ICMP
//     leaves inside the wrapper, at least 16 idle proto_clk clocks between
//     frames toward the leaves, no frame starts while a leaf is busy,
//     s_axis_tready never low after reset, stream rules at m_axis (sink).
//   * Phases: register map readback (wrapper and leaf windows, absent
//     windows read 0, RO and partial writes ignored); ARP and ping (payload
//     0, 64, 1472) answered; destination filter (wrong unicast, multicast,
//     one differing bit in each MAC byte, broadcast, a flood of wrong-MAC
//     frames around pings, promiscuous mode); an over-slot frame; ingress-full
//     drops with the counter identity and replies in order; egress
//     back-pressure (random and held) with nothing lost; static IP, netmask,
//     gateway and MAC changed through AXI4-Lite, ARP/ping answered for the new
//     address and not the old; leaf-enable mask; a mixed ARP/ping burst;
//     CNT_CLEAR.
//   * CPU network path present (default; CPU_CLASSIFIER_ENABLE 0) with
//     cpu_axis_clk 100 MHz and an always-ready CPU sink: every frame the
//     sink receives is counted, CPU_RX_FRAMES equals it, DELIVERED_FRAMES
//     equals the frames toward the leaves, and after CNT_CLEAR DELIVERED =
//     CPU_RX_CLAIMED + CPU_RX_FRAMES + CPU_RX_DROPPED. rtlnet_tb_leaf_claim_
//     monitor on the ARP and ICMP leaves; every answered ARP request and ping
//     is claimed (claims = REPLIES_SENT + ECHO_REPLIES).
//   * +define+TB_NO_OFFLOAD builds CPU_TCP_OFFLOAD_ENABLE = 0: CPU_CAPS bits 17/18 read 0 and
//     the 0x9000 window reads 0 (default build: bits 17/18 set, window answers ID "TCPO").
//   * +define+TB_NO_CPU_PATH builds CPU_PATH_ENABLE = 0: CAPS bit 5 and
//     CPU_CAPS read 0, CTRL bit 1 reads 0, m_axis_cpu_eth_tvalid stays 0 and
//     s_axis_cpu_eth_tready 1.
//   * The CPU path itself is proven in tb_rtlnet_eth_protocol_cpu.
//   * +INJECT_FAILURE forces TEST FAIL (negative control).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: CPU network path ports, CAPS/CTRL with the CPU path, claim
//     monitors and counts, TB_NO_CPU_PATH build.
// Clocks: axis_clk, proto_clk (also app_clk), s_axi_aclk, per +CLKPAIR;
//   cpu_axis_clk 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_eth_protocol;

  import rtlnet_tb_pkg::*;
  import rtlnet_tb_eth_frames_pkg::*;

  // ---------------------------------------------------------------------------
  // Register offsets (from cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.h).
  // ---------------------------------------------------------------------------
  localparam logic [15:0] R_ID         = 16'h0000;
  localparam logic [15:0] R_VERSION    = 16'h0004;
  localparam logic [15:0] R_CAPS       = 16'h0008;
  localparam logic [15:0] R_CTRL       = 16'h000C;
  localparam logic [15:0] R_STATUS     = 16'h0010;
  localparam logic [15:0] R_MAC_HI     = 16'h0014;
  localparam logic [15:0] R_MAC_LO     = 16'h0018;
  localparam logic [15:0] R_STATIC_IP  = 16'h001C;
  localparam logic [15:0] R_NETMASK    = 16'h0020;
  localparam logic [15:0] R_GATEWAY    = 16'h0024;
  localparam logic [15:0] R_EFF_IP     = 16'h0028;
  localparam logic [15:0] R_EFF_MASK   = 16'h002C;
  localparam logic [15:0] R_EFF_GW     = 16'h0030;
  localparam logic [15:0] R_IN_FRAMES  = 16'h0040;
  localparam logic [15:0] R_IN_FILT    = 16'h0044;
  localparam logic [15:0] R_IN_DROP    = 16'h0048;
  localparam logic [15:0] R_EG_FRAMES  = 16'h004C;
  localparam logic [15:0] ARP_BASE     = 16'h1000;
  localparam logic [15:0] ICMP_BASE    = 16'h2000;
`ifdef TB_NO_CPU_PATH
  localparam int          CPU_PATH     = 0;
`else
  localparam int          CPU_PATH     = 1;
`endif
`ifdef TB_NO_OFFLOAD
  localparam int          OFFLOAD      = 0;
`else
  localparam int          OFFLOAD      = 1;
`endif
  localparam logic [15:0] R_CPU_CAPS   = 16'h0034;
  localparam logic [15:0] R_DELIVERED  = 16'h0050;
  localparam logic [15:0] R_CPU_RX     = 16'h0054;
  localparam logic [15:0] R_CPU_CLAIM  = 16'h0058;
  localparam logic [15:0] R_CPU_DROP   = 16'h005C;
  // Filter on, CPU path on (when built), LEAF_ENABLE = ICMP | ARP.
  localparam logic [31:0] CTRL_DEFAULT = 32'h0000_0601 | ((CPU_PATH != 0) ? 32'h2 : 32'h0);
  localparam logic [31:0] CAPS_VALUE   = 32'h0008_1006 | ((CPU_PATH != 0) ? 32'h20 : 32'h0);

  localparam logic [47:0] DEF_MAC      = 48'h02_49_4B_52_4E_01;
  localparam logic [31:0] DEF_IP       = 32'hC0A901DC;
  localparam logic [47:0] PEER_MAC     = 48'h02_11_22_33_44_55;
  localparam logic [31:0] PEER_IP      = 32'hC0A90109;
  localparam int          GAP_MIN      = 16;
  localparam int          ARP_WAIT     = 4000;            // proto clocks: 1250-clock reply delay plus margin

  // ---------------------------------------------------------------------------
  // Clocks and resets.
  // ---------------------------------------------------------------------------
  real  axis_half  = 8.000;
  real  proto_half = 10.0015;
  real  axi_half   = 5.000;
  int   clkpair    = 1;
  logic axis_clk   = 1'b0;
  logic proto_clk  = 1'b0;
  logic s_axi_aclk = 1'b0;
  logic cpu_clk    = 1'b0;
  logic cpu_resetn     = 1'b0;
  logic axis_resetn    = 1'b0;
  logic proto_resetn   = 1'b0;
  logic s_axi_aresetn  = 1'b0;

  initial begin
    if (!$value$plusargs("CLKPAIR=%d", clkpair)) clkpair = 1;
    case (clkpair)
      2:       begin axis_half = 3.200;  proto_half = 10.0015; end
      3:       begin axis_half = 10.000; proto_half = 8.0035;  end
      default: begin axis_half = 8.000;  proto_half = 10.0015; end
    endcase
    $display("tb_rtlnet_eth_protocol: CLKPAIR=%0d axis_clk %0.3f ns, proto_clk %0.3f ns", clkpair, 2.0 * axis_half,
             2.0 * proto_half);
  end

  initial begin
    #1.3;
    forever #(axis_half) axis_clk = ~axis_clk;
  end
  initial begin
    #3.7;
    forever #(proto_half) proto_clk = ~proto_clk;
  end
  initial begin
    #2.1;
    forever #(axi_half) s_axi_aclk = ~s_axi_aclk;
  end
  initial begin
    #0.7;
    forever #(4.9985) cpu_clk = ~cpu_clk;
  end

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
  logic [63:0] s_tdata;
  logic [7:0]  s_tkeep;
  logic        s_tvalid;
  logic        s_tlast;
  logic        s_tready;
  logic [63:0] m_tdata;
  logic [7:0]  m_tkeep;
  logic        m_tvalid;
  logic        m_tlast;
  logic        m_tready;
  logic [63:0] app_m_tdata;
  logic [7:0]  app_m_tkeep;
  logic        app_m_tvalid;
  logic        app_m_tlast;
  logic        app_s_tready;
  logic [15:0] awaddr;
  logic        awvalid;
  logic        awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;
  logic [15:0] araddr;
  logic        arvalid;
  logic        arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;
  logic        stat_ip_valid;
  logic        stat_dhcp_bound;
  logic        ev_rx_frame;
  logic        ev_tx_frame;
  logic [63:0] cpu_m_tdata;
  logic [7:0]  cpu_m_tkeep;
  logic        cpu_m_tvalid;
  logic        cpu_m_tlast;
  logic        cpu_m_tready;
  logic [63:0] cpu_s_tdata;
  logic [7:0]  cpu_s_tkeep;
  logic        cpu_s_tvalid;
  logic        cpu_s_tlast;
  logic        cpu_s_tready;

  // The wrapper with ARP and ICMP only.
  rtlnet_eth_protocol #(
    .PROTO_CLK_HZ    (50_000_000),
    .INGRESS_FIFO_KB (16),
    .EGRESS_FIFO_KB  (8),
    .ARP_ENABLE      (1),
    .ICMP_ENABLE     (1),
    .DHCP_ENABLE     (0),
    .IPERF_ENABLE    (0),
    .UDP_ENABLE      (0),
    .CPU_PATH_ENABLE       (CPU_PATH),
    .CPU_CLASSIFIER_ENABLE (0),
    .CPU_TCP_OFFLOAD_ENABLE (OFFLOAD)
  ) dut (
    .axis_clk          (axis_clk),
    .proto_clk         (proto_clk),
    .app_clk           (proto_clk),
    .s_axi_aclk        (s_axi_aclk),
    .axis_resetn       (axis_resetn),
    .proto_resetn      (proto_resetn),
    .app_resetn        (proto_resetn),
    .s_axi_aresetn     (s_axi_aresetn),
    .s_axis_tdata      (s_tdata),
    .s_axis_tkeep      (s_tkeep),
    .s_axis_tvalid     (s_tvalid),
    .s_axis_tlast      (s_tlast),
    .s_axis_tready     (s_tready),
    .m_axis_tdata      (m_tdata),
    .m_axis_tkeep      (m_tkeep),
    .m_axis_tvalid     (m_tvalid),
    .m_axis_tlast      (m_tlast),
    .m_axis_tready     (m_tready),
    .m_axis_app_tdata  (app_m_tdata),
    .m_axis_app_tkeep  (app_m_tkeep),
    .m_axis_app_tvalid (app_m_tvalid),
    .m_axis_app_tlast  (app_m_tlast),
    .m_axis_app_tready (1'b1),
    .s_axis_app_tdata  (64'd0),
    .s_axis_app_tkeep  (8'd0),
    .s_axis_app_tvalid (1'b0),
    .s_axis_app_tlast  (1'b0),
    .s_axis_app_tready (app_s_tready),
    .s_axi_awaddr      (awaddr),
    .s_axi_awvalid     (awvalid),
    .s_axi_awready     (awready),
    .s_axi_wdata       (wdata),
    .s_axi_wstrb       (wstrb),
    .s_axi_wvalid      (wvalid),
    .s_axi_wready      (wready),
    .s_axi_bresp       (bresp),
    .s_axi_bvalid      (bvalid),
    .s_axi_bready      (bready),
    .s_axi_araddr      (araddr),
    .s_axi_arvalid     (arvalid),
    .s_axi_arready     (arready),
    .s_axi_rdata       (rdata),
    .s_axi_rresp       (rresp),
    .s_axi_rvalid      (rvalid),
    .s_axi_rready      (rready),
    .cpu_axis_clk          (cpu_clk),
    .cpu_axis_resetn       (cpu_resetn),
    .m_axis_cpu_eth_tdata  (cpu_m_tdata),
    .m_axis_cpu_eth_tkeep  (cpu_m_tkeep),
    .m_axis_cpu_eth_tvalid (cpu_m_tvalid),
    .m_axis_cpu_eth_tlast  (cpu_m_tlast),
    .m_axis_cpu_eth_tready (cpu_m_tready),
    .s_axis_cpu_eth_tdata  (cpu_s_tdata),
    .s_axis_cpu_eth_tkeep  (cpu_s_tkeep),
    .s_axis_cpu_eth_tvalid (cpu_s_tvalid),
    .s_axis_cpu_eth_tlast  (cpu_s_tlast),
    .s_axis_cpu_eth_tready (cpu_s_tready),
    .stat_ip_valid     (stat_ip_valid),
    .stat_dhcp_bound   (stat_dhcp_bound),
    .ev_rx_frame       (ev_rx_frame),
    .ev_tx_frame       (ev_tx_frame)
  );

  // MAC receive side (frames in) and transmit side (replies out).
  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(3)) u_src (
    .clk(axis_clk), .tdata(s_tdata), .tkeep(s_tkeep), .tlast(s_tlast), .tvalid(s_tvalid), .tready(s_tready));

  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(9), .NAME("m_axis")) u_sink (
    .clk(axis_clk), .resetn(axis_resetn), .tdata(m_tdata), .tkeep(m_tkeep), .tlast(m_tlast), .tvalid(m_tvalid),
    .tready(m_tready));

  // CPU network streams: an always-ready sink, an idle source.
  rtlnet_tb_axis_sink #(.READY_PCT(100), .SEED(13), .NAME("m_axis_cpu_eth")) u_cpu_sink (
    .clk(cpu_clk), .resetn(cpu_resetn), .tdata(cpu_m_tdata), .tkeep(cpu_m_tkeep), .tlast(cpu_m_tlast),
    .tvalid(cpu_m_tvalid), .tready(cpu_m_tready));
  rtlnet_tb_axis_src #(.GAP_PCT(0), .SEED(15)) u_cpu_src (
    .clk(cpu_clk), .tdata(cpu_s_tdata), .tkeep(cpu_s_tkeep), .tlast(cpu_s_tlast), .tvalid(cpu_s_tvalid),
    .tready(cpu_s_tready));

  // CPU side.
  rtlnet_tb_axil_master #(.ADDR_W(16)) u_axi (
    .aclk(s_axi_aclk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  // Leaf-contract monitors on the leaves inside the wrapper (index 1 ICMP, 2 ARP).
  rtlnet_tb_leaf_busy_monitor #(.NAME("wrapper icmp")) u_icmp_mon (
    .clk(proto_clk), .resetn(proto_resetn), .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[1]),
    .s_tlast(dut.iq_last), .m_tvalid(dut.leaf_tvalid[1]), .m_tready(dut.leaf_tready[1]), .m_tlast(dut.leaf_tlast[1]),
    .busy(dut.leaf_busy[1]));
  rtlnet_tb_leaf_busy_monitor #(.NAME("wrapper arp")) u_arp_mon (
    .clk(proto_clk), .resetn(proto_resetn), .s_tvalid(dut.leaf_in_tvalid), .s_tready(dut.leaf_s_tready[2]),
    .s_tlast(dut.iq_last), .m_tvalid(dut.leaf_tvalid[2]), .m_tready(dut.leaf_tready[2]), .m_tlast(dut.leaf_tlast[2]),
    .busy(dut.leaf_busy[2]));
  rtlnet_tb_leaf_claim_monitor #(.NAME("wrapper icmp")) u_icmp_claim (
    .clk(proto_clk), .resetn(proto_resetn), .enable(dut.leaf_enable[1]), .s_tvalid(dut.leaf_in_tvalid),
    .s_tready(dut.leaf_s_tready[1]), .s_tlast(dut.iq_last), .busy(dut.leaf_busy[1]), .claim(dut.leaf_claim[1]));
  rtlnet_tb_leaf_claim_monitor #(.NAME("wrapper arp")) u_arp_claim (
    .clk(proto_clk), .resetn(proto_resetn), .enable(dut.leaf_enable[2]), .s_tvalid(dut.leaf_in_tvalid),
    .s_tready(dut.leaf_s_tready[2]), .s_tlast(dut.iq_last), .busy(dut.leaf_busy[2]), .claim(dut.leaf_claim[2]));

  // ---------------------------------------------------------------------------
  // Always-on monitors.
  // ---------------------------------------------------------------------------
  int  idle_since_frame = 1000;
  bit  leaf_in_frame    = 1'b0;
  int  leaf_frames      = 0;
  int  gap_errors       = 0;
  int  busy_start_errors = 0;
  int  tready_errors    = 0;
  int  axis_cycles      = 0;
  int  ev_rx_count      = 0;
  int  ev_tx_count      = 0;

  // Frames toward the leaves: gap and no-busy rules of the leaf contract.
  always @(posedge proto_clk) begin
    if (proto_resetn) begin
      if (ev_rx_frame) ev_rx_count++;
      if (ev_tx_frame) ev_tx_count++;
      if (dut.leaf_in_tvalid) begin
        if (!leaf_in_frame) begin
          leaf_frames++;
          if (idle_since_frame < GAP_MIN && gap_errors < 4) begin
            gap_errors++;
            tb_error($sformatf("frame toward the leaves after %0d idle clocks (minimum %0d)", idle_since_frame,
                               GAP_MIN));
          end
          if (dut.leaf_busy != '0 && busy_start_errors < 4) begin
            busy_start_errors++;
            tb_error($sformatf("frame toward the leaves while a leaf is busy (%b)", dut.leaf_busy));
          end
          leaf_in_frame = 1'b1;
        end
        if (dut.iq_last) begin
          leaf_in_frame    = 1'b0;
          idle_since_frame = 0;
        end
      end else if (!leaf_in_frame && idle_since_frame < 1000) begin
        idle_since_frame++;
      end
    end
  end

  // s_axis_tready never low after reset (the MAC is never back-pressured).
  always @(posedge axis_clk) begin
    if (axis_resetn) begin
      axis_cycles++;
      if (axis_cycles > 2 && s_tready !== 1'b1 && tready_errors < 4) begin
        tready_errors++;
        tb_error("s_axis_tready low after reset");
      end
    end else begin
      axis_cycles = 0;
    end
  end

  // ---------------------------------------------------------------------------
  // Bench state: the DUT's address as programmed, and the expected counters.
  // ---------------------------------------------------------------------------
  logic [47:0] cur_mac = DEF_MAC;
  logic [31:0] cur_ip  = DEF_IP;
  int          seed    = 1234;
  int          offered = 0;           // frames offered since the last CNT_CLEAR
  int          exp_frames   = 0;
  int          exp_filtered = 0;
  int          exp_dropped  = 0;
  int          received     = 0;      // replies received since the last CNT_CLEAR
  int          arp_replies  = 0;
  int          icmp_replies = 0;

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

  // Offer one frame at the MAC receive side. kind: 0 stored, 1 filtered,
  // 2 dropped, 3 unknown (stored or dropped: resolved by the caller).
  task automatic offer(input bytes_t f, input int kind);
    u_src.send(f);
    offered++;
    if (kind == 0) exp_frames++;
    if (kind == 1) exp_filtered++;
    if (kind == 2) exp_dropped++;
  endtask

  task automatic expect_frame(input string tag, input bytes_t exp, input int timeout_cycles);
    bytes_t got;
    bit     ok;
    string  why;
    u_sink.get(got, timeout_cycles, ok);
    tb_check(ok, $sformatf("%s: a frame arrived", tag));
    if (ok) begin
      received++;
      tb_check(bytes_equal(got, exp, why), $sformatf("%s: byte-exact (%s) got %s", tag, why, hexdump(got)));
    end
  endtask

  task automatic expect_nothing(input string tag, input int cycles);
    bit none;
    u_sink.expect_none(cycles, none);
    tb_check(none, $sformatf("%s: no frame", tag));
    if (!none) begin
      bytes_t junk;
      bit     ok;
      u_sink.get(junk, 1, ok);
      received++;
    end
  endtask

  // ARP request for ip from the peer, answered (or not) with the current address.
  task automatic arp_case(input string tag, input bit [31:0] tpa, input bit answered,
                          input bit [47:0] sha = PEER_MAC);
    bytes_t req;
    req = pad60(arp_request(sha, PEER_IP, tpa));
    offer(req, 0);
    if (answered) begin
      expect_frame(tag, arp_reply(req, cur_mac, cur_ip), 20 * ARP_WAIT);
      arp_replies++;
    end else begin
      expect_nothing(tag, 2 * ARP_WAIT);
    end
  endtask

  // Ping to (dst_mac, ip) with a payload of n bytes; kind as in offer().
  task automatic ping_case(input string tag, input bit [47:0] dst_mac, input bit [31:0] ip, input int n,
                           input bit answered, input int kind = 0);
    bytes_t req;
    req = pad60(echo_request(dst_mac, PEER_MAC, PEER_IP, ip, 16'h7A01, 16'(n), rand_bytes(seed, n)));
    offer(req, kind);
    if (answered) begin
      expect_frame(tag, echo_reply(req, cur_mac, cur_ip), 40000);
      icmp_replies++;
    end else begin
      expect_nothing(tag, 3000);
    end
  endtask

  // Counter identity and expected values (after traffic has settled).
  task automatic check_counters(input string tag);
    logic [31:0] fr;
    logic [31:0] fi;
    logic [31:0] dr;
    logic [31:0] eg;
    wait_proto(50);
    axi_rd(R_IN_FRAMES, fr);
    axi_rd(R_IN_FILT, fi);
    axi_rd(R_IN_DROP, dr);
    axi_rd(R_EG_FRAMES, eg);
    tb_check(fr + fi + dr == 32'(offered), $sformatf("%s: identity offered %0d = frames %0d + filtered %0d + dropped %0d",
             tag, offered, fr, fi, dr));
    tb_check(fr == 32'(exp_frames), $sformatf("%s: INGRESS_FRAMES %0d, expected %0d", tag, fr, exp_frames));
    tb_check(fi == 32'(exp_filtered), $sformatf("%s: INGRESS_FILTERED %0d, expected %0d", tag, fi, exp_filtered));
    tb_check(dr == 32'(exp_dropped), $sformatf("%s: INGRESS_DROPPED %0d, expected %0d", tag, dr, exp_dropped));
    tb_check(eg == 32'(received), $sformatf("%s: EGRESS_FRAMES %0d, expected %0d", tag, eg, received));
  endtask

  // Program the node address through AXI4-Lite.
  task automatic set_mac(input logic [47:0] mac);
    axi_wr(R_MAC_HI, {16'd0, mac[47:32]});
    axi_wr(R_MAC_LO, mac[31:0]);
    cur_mac = mac;
    wait_proto(20);
  endtask

  task automatic set_ip(input logic [31:0] ip);
    axi_wr(R_STATIC_IP, ip);
    cur_ip = ip;
    wait_proto(10);
  endtask

  // ---------------------------------------------------------------------------
  // The phases.
  // ---------------------------------------------------------------------------
  initial begin : main
    logic [31:0] v;
    logic [31:0] d0;
    logic [31:0] f0;
    logic [1:0]  resp;
    bytes_t      reqs[$];
    bytes_t      got;
    bit          ok;
    string       why;
    int          n_burst;
    int          r_burst;
    int          last_seq;
    int          seq;

    wait (axis_resetn && proto_resetn && s_axi_aresetn);
    wait_proto(40);

    // ---- Register map at reset: wrapper window.
    axi_expect(R_ID, 32'h50524F54, "ID");
    axi_expect(R_VERSION, 32'h10222026, "VERSION");
    axi_expect(R_CAPS, CAPS_VALUE, "CAPS (ICMP, ARP present, CPU path per build; 16/8 KB; 0 sockets)");
    axi_expect(R_CPU_CAPS, (CPU_PATH == 0) ? 32'h0 : ((OFFLOAD != 0) ? 32'h0006_0810 : 32'h0000_0810),
               "CPU_CAPS (CPU RX 16 KB, TX 8 KB, offload TX+RX bits 17/18 when built, classifier bit 16 clear)");
    axi_expect(16'h8000, 32'h0, "classifier window (not built) reads 0");
    axi_expect(16'h9000, (CPU_PATH != 0 && OFFLOAD != 0) ? 32'h5443_504F : 32'h0, "offload window ID (0 when not built)");
    axi_expect(16'h9004, (CPU_PATH != 0 && OFFLOAD != 0) ? 32'h1022_2026 : 32'h0, "offload window VERSION (0 when not built)");
    axi_expect(R_CTRL, CTRL_DEFAULT, "CTRL");
    axi_expect(R_STATUS, 32'h0000_0002, "STATUS (IP valid, static)");
    axi_expect(R_MAC_HI, 32'h0000_0249, "LOCAL_MAC_HI");
    axi_expect(R_MAC_LO, 32'h4B52_4E01, "LOCAL_MAC_LO");
    axi_expect(R_STATIC_IP, DEF_IP, "STATIC_IP");
    axi_expect(R_NETMASK, 32'hFFFF_FF00, "NETMASK");
    axi_expect(R_GATEWAY, 32'hC0A9_0101, "GATEWAY");
    axi_expect(R_EFF_IP, DEF_IP, "EFFECTIVE_IP");
    axi_expect(R_EFF_MASK, 32'hFFFF_FF00, "EFFECTIVE_MASK");
    axi_expect(R_EFF_GW, 32'hC0A9_0101, "EFFECTIVE_GATEWAY");
    axi_expect(R_IN_FRAMES, 32'h0, "INGRESS_FRAMES");
    axi_expect(R_IN_FILT, 32'h0, "INGRESS_FILTERED");
    axi_expect(R_IN_DROP, 32'h0, "INGRESS_DROPPED");
    axi_expect(R_EG_FRAMES, 32'h0, "EGRESS_FRAMES");
    axi_expect(16'h0FFC, 32'h0, "undefined wrapper offset");
    // Leaf windows: ARP, ICMP; absent leaves and unused windows read 0.
    axi_expect(ARP_BASE + 16'h000, 32'h41525031, "ARP ID");
    axi_expect(ARP_BASE + 16'h004, 32'h10222026, "ARP VERSION");
    axi_expect(ARP_BASE + 16'h008, 32'd1250, "ARP CAPS (reply delay 25 us at 50 MHz)");
    axi_expect(ICMP_BASE + 16'h000, 32'h49434D50, "ICMP ID");
    axi_expect(ICMP_BASE + 16'h008, 32'h0002_05C0, "ICMP CAPS (2 KB, 1472 bytes)");
    axi_expect(16'h3000, 32'h0, "DHCP window (absent)");
    axi_expect(16'h4000, 32'h0, "iperf window (absent)");
    axi_expect(16'h5000, 32'h0, "UDP socket window (absent)");
    axi_expect(16'h6000, 32'h0, "unused window 6");
    axi_expect(16'hF004, 32'h0, "unused window 15");
    // Read-only and partial writes are ignored; writes to absent windows are harmless.
    axi_wr(R_ID, 32'h1234_5678);
    axi_wr(R_EFF_IP, 32'h0102_0304);
    axi_wr(16'h3000, 32'hFFFF_FFFF);
    u_axi.write32(R_STATIC_IP, 32'h0A0A_0A0A, 4'h3, resp);
    tb_check(resp == 2'b00, "partial write answered OKAY");
    axi_expect(R_ID, 32'h50524F54, "ID after a write");
    axi_expect(R_EFF_IP, DEF_IP, "EFFECTIVE_IP after a write");
    axi_expect(R_STATIC_IP, DEF_IP, "STATIC_IP after a partial write");
    tb_check(stat_ip_valid === 1'b1 && stat_dhcp_bound === 1'b0, "LED status: IP valid, not DHCP");
    tb_check(app_m_tvalid === 1'b0 && app_s_tready === 1'b1, "UDP disabled: application ports idle");
    if (CPU_PATH == 0) tb_check(cpu_m_tvalid === 1'b0 && cpu_s_tready === 1'b1,
                                "CPU path not built: m_axis_cpu_eth idle, s_axis_cpu_eth_tready 1");

    // ---- ARP and ping answered with the default address.
    arp_case("ARP for the default IP", cur_ip, 1'b1);
    ping_case("ping payload 0", cur_mac, cur_ip, 0, 1'b1);
    ping_case("ping payload 64", cur_mac, cur_ip, 64, 1'b1);
    ping_case("ping payload 1472", cur_mac, cur_ip, 1472, 1'b1);
    ping_case("ping broadcast destination", 48'hFFFF_FFFF_FFFF, cur_ip, 32, 1'b1);
    check_counters("after ARP and ping");

    // ---- Destination-MAC filter.
    ping_case("wrong unicast", 48'h02_49_4B_52_4E_02, cur_ip, 16, 1'b0, 1);
    ping_case("multicast", 48'h01_00_5E_00_00_01, cur_ip, 16, 1'b0, 1);
    ping_case("multicast with the local MAC tail", 48'h01_49_4B_52_4E_01, cur_ip, 16, 1'b0, 1);
    for (int b = 0; b < 6; b++) begin
      for (int k = 0; k < 8; k += 7) begin
        ping_case($sformatf("one differing bit %0d in MAC byte %0d", k, b), cur_mac ^ (48'd1 << (8 * (5 - b) + k)),
                  cur_ip, 8, 1'b0, 1);
      end
    end
    // A frame for us that no leaf answers is stored, not filtered.
    offer(pad60(eth_header(cur_mac, PEER_MAC, 16'h86DD)), 0);
    expect_nothing("IPv6 frame to the local MAC", 3000);
    // A flood of wrong-MAC frames back to back with two pings inside it.
    for (int i = 0; i < 40; i++) begin
      offer(pad60(echo_request(48'h02_00_00_00_00_00 + i, PEER_MAC, PEER_IP, cur_ip, 1, 16'(i), rand_bytes(seed, 8))), 1);
      if (i == 13 || i == 27) begin
        reqs.push_back(pad60(echo_request(cur_mac, PEER_MAC, PEER_IP, cur_ip, 2, 16'(i), rand_bytes(seed, 20))));
        offer(reqs[$], 0);
      end
    end
    for (int i = 0; i < 2; i++) begin
      expect_frame($sformatf("ping %0d inside a wrong-MAC flood", i), echo_reply(reqs[i], cur_mac, cur_ip), 40000);
      icmp_replies++;
    end
    expect_nothing("wrong-MAC flood", 3000);
    reqs.delete();
    // Promiscuous mode: a wrong-unicast ping reaches the leaves and is answered.
    axi_wr(R_CTRL, CTRL_DEFAULT & ~32'h1);
    axi_expect(R_CTRL, CTRL_DEFAULT & ~32'h1, "CTRL promiscuous");
    wait_proto(10);
    ping_case("promiscuous: wrong unicast answered", 48'h02_49_4B_52_4E_02, cur_ip, 16, 1'b1, 0);
    ping_case("promiscuous: multicast answered", 48'h01_00_5E_00_00_01, cur_ip, 16, 1'b1, 0);
    axi_wr(R_CTRL, CTRL_DEFAULT);
    wait_proto(10);
    ping_case("filter restored: wrong unicast filtered", 48'h02_49_4B_52_4E_02, cur_ip, 16, 1'b0, 1);
    // An over-slot frame (2100 bytes) to the local MAC is dropped and counted.
    offer(echo_request(cur_mac, PEER_MAC, PEER_IP, cur_ip, 3, 3, rand_bytes(seed, 2058)), 2);
    expect_nothing("over-slot frame", 3000);
    ping_case("ping after the over-slot frame", cur_mac, cur_ip, 100, 1'b1);
    check_counters("after the filter cases");

    // ---- Ingress full: a line-rate burst of large pings; replies + drops = burst.
    axi_rd(R_IN_DROP, d0);
    axi_rd(R_IN_FRAMES, f0);
    n_burst = 40;
    for (int i = 0; i < n_burst; i++) begin
      reqs.push_back(echo_request(cur_mac, PEER_MAC, PEER_IP, cur_ip, 16'h0B57, 16'(i), rand_bytes(seed, 1400)));
      u_src.send(reqs[i]);
      offered++;
    end
    r_burst  = 0;
    last_seq = -1;
    ok       = 1'b1;
    while (ok) begin
      u_sink.get(got, 60000, ok);
      if (ok) begin
        received++;
        icmp_replies++;
        r_burst++;
        seq = get16(got, 40);
        tb_check(seq > last_seq && seq < n_burst, $sformatf("burst reply sequence %0d after %0d (in order)", seq, last_seq));
        if (seq < n_burst) tb_check(bytes_equal(got, echo_reply(reqs[seq], cur_mac, cur_ip), why),
                                    $sformatf("burst reply %0d byte-exact (%s)", seq, why));
        last_seq = seq;
      end
    end
    wait_proto(50);
    axi_rd(R_IN_DROP, v);
    v = v - d0;
    $display("tb_rtlnet_eth_protocol: burst of %0d pings: %0d answered, %0d dropped", n_burst, r_burst, v);
    tb_check(v >= 1, $sformatf("ingress full: frames dropped (%0d)", v));
    tb_check(32'(r_burst) + v == 32'(n_burst), $sformatf("ingress full: replies %0d + drops %0d = %0d", r_burst, v,
             n_burst));
    exp_dropped += int'(v);
    exp_frames  += r_burst;
    reqs.delete();
    check_counters("after the ingress-full burst");

    // ---- Egress back-pressure: random 30 % ready, then a held stall; nothing lost.
    u_sink.ready_pct = 30;
    for (int i = 0; i < 10; i++) begin
      reqs.push_back(pad60(echo_request(cur_mac, PEER_MAC, PEER_IP, cur_ip, 16'h0E91, 16'(i),
                                        rand_bytes(seed, (i * 137) % 700))));
      offer(reqs[i], 0);
    end
    for (int i = 0; i < 10; i++) begin
      expect_frame($sformatf("back-pressure reply %0d", i), echo_reply(reqs[i], cur_mac, cur_ip), 400000);
      icmp_replies++;
    end
    reqs.delete();
    u_sink.ready_pct = 0;
    for (int i = 0; i < 6; i++) begin
      reqs.push_back(pad60(echo_request(cur_mac, PEER_MAC, PEER_IP, cur_ip, 16'h0E92, 16'(i), rand_bytes(seed, 300))));
      offer(reqs[i], 0);
    end
    arp_case("ARP queued behind held replies (sent, checked below)", cur_ip, 1'b0);
    wait_proto(2000);
    axi_rd(R_STATUS, v);
    tb_check(v[17] === 1'b1, $sformatf("STATUS.EGRESS_FULL during the held stall (0x%08x)", v));
    tb_check(u_sink.frames.size() == 0, "held stall: nothing completed");
    u_sink.ready_pct = 100;
    for (int i = 0; i < 6; i++) begin
      expect_frame($sformatf("held-stall reply %0d", i), echo_reply(reqs[i], cur_mac, cur_ip), 400000);
      icmp_replies++;
    end
    // The ARP request offered during the stall is answered last.
    reqs.delete();
    u_sink.get(got, 20 * ARP_WAIT, ok);
    tb_check(ok, "ARP reply after the held stall arrived");
    if (ok) begin
      received++;
      arp_replies++;
      tb_check(bytes_equal(got, arp_reply(pad60(arp_request(PEER_MAC, PEER_IP, cur_ip)), cur_mac, cur_ip), why),
               $sformatf("ARP reply after the held stall byte-exact (%s)", why));
    end
    check_counters("after egress back-pressure");

    // ---- Address registers through AXI4-Lite.
    set_ip(32'h0A01_0203);
    axi_expect(R_STATIC_IP, 32'h0A01_0203, "STATIC_IP written");
    axi_expect(R_EFF_IP, 32'h0A01_0203, "EFFECTIVE_IP follows STATIC_IP");
    arp_case("ARP for the new static IP", cur_ip, 1'b1);
    arp_case("ARP for the old IP", DEF_IP, 1'b0);
    ping_case("ping to the new static IP", cur_mac, cur_ip, 48, 1'b1);
    ping_case("ping to the old IP", cur_mac, DEF_IP, 48, 1'b0);
    axi_wr(R_NETMASK, 32'hFFFF_0000);
    axi_wr(R_GATEWAY, 32'h0A01_0001);
    axi_expect(R_NETMASK, 32'hFFFF_0000, "NETMASK written");
    axi_expect(R_GATEWAY, 32'h0A01_0001, "GATEWAY written");
    axi_expect(R_EFF_MASK, 32'hFFFF_0000, "EFFECTIVE_MASK follows NETMASK");
    axi_expect(R_EFF_GW, 32'h0A01_0001, "EFFECTIVE_GATEWAY follows GATEWAY");
    // MAC: the HI write is staged, the LO write changes all 48 bits.
    axi_wr(R_MAC_HI, 32'h0000_0E00);
    axi_expect(R_MAC_HI, 32'h0000_0249, "LOCAL_MAC_HI unchanged until the LO write");
    set_mac(48'h0E_00_11_22_33_44);
    axi_expect(R_MAC_HI, 32'h0000_0E00, "LOCAL_MAC_HI written");
    axi_expect(R_MAC_LO, 32'h1122_3344, "LOCAL_MAC_LO written");
    ping_case("ping to the old MAC: filtered", DEF_MAC, cur_ip, 24, 1'b0, 1);
    ping_case("ping to the new MAC: answered from it", cur_mac, cur_ip, 24, 1'b1);
    arp_case("ARP answered with the new MAC", cur_ip, 1'b1);
    // Back to the defaults.
    set_mac(DEF_MAC);
    set_ip(DEF_IP);
    axi_wr(R_NETMASK, 32'hFFFF_FF00);
    axi_wr(R_GATEWAY, 32'hC0A9_0101);
    ping_case("ping after restoring the address", cur_mac, cur_ip, 10, 1'b1);
    check_counters("after the address registers");

    // ---- Leaf-enable mask: ARP off, then ICMP off; absent bits stay 0.
    axi_wr(R_CTRL, 32'h0000_1F01 & ~32'h0000_0400);
    axi_expect(R_CTRL, 32'h0000_0201, "CTRL with ARP disabled (absent bits masked)");
    wait_proto(10);
    arp_case("ARP disabled: no reply", cur_ip, 1'b0);
    ping_case("ARP disabled: ping still answered", cur_mac, cur_ip, 12, 1'b1);
    axi_wr(R_CTRL, 32'h0000_0401);
    wait_proto(10);
    ping_case("ICMP disabled: no reply", cur_mac, cur_ip, 12, 1'b0);
    arp_case("ICMP disabled: ARP answered", cur_ip, 1'b1);
    axi_wr(R_CTRL, CTRL_DEFAULT);
    axi_expect(R_CTRL, CTRL_DEFAULT, "CTRL restored");
    check_counters("after the leaf-enable mask");

    // ---- Mixed burst, back to back: replies in order (ARP after its 25 us delay).
    begin
      bytes_t a1;
      bytes_t p1;
      bytes_t p2;
      bytes_t a2;
      p1 = pad60(echo_request(cur_mac, PEER_MAC, PEER_IP, cur_ip, 9, 1, rand_bytes(seed, 30)));
      a1 = pad60(arp_request(48'h02_A1_A1_A1_A1_A1, PEER_IP, cur_ip));
      p2 = pad60(echo_request(cur_mac, PEER_MAC, PEER_IP, cur_ip, 9, 2, rand_bytes(seed, 300)));
      a2 = pad60(arp_request(48'h02_A2_A2_A2_A2_A2, 32'hC0A90177, cur_ip));
      offer(p1, 0);
      offer(a1, 0);
      offer(p2, 0);
      offer(a2, 0);
      expect_frame("mixed burst: ping 1", echo_reply(p1, cur_mac, cur_ip), 40000);
      expect_frame("mixed burst: ARP 1", arp_reply(a1, cur_mac, cur_ip), 20 * ARP_WAIT);
      expect_frame("mixed burst: ping 2", echo_reply(p2, cur_mac, cur_ip), 40000);
      expect_frame("mixed burst: ARP 2", arp_reply(a2, cur_mac, cur_ip), 20 * ARP_WAIT);
      icmp_replies += 2;
      arp_replies  += 2;
    end
    check_counters("after the mixed burst");

    // ---- Leaf counters through their windows, LED events.
    axi_expect(ARP_BASE + 16'h024, 32'(arp_replies), "ARP REPLIES_SENT");
    axi_expect(ICMP_BASE + 16'h024, 32'(icmp_replies), "ICMP ECHO_REPLIES");
    tb_check(ev_tx_count == received, $sformatf("ev_tx_frame pulses %0d = frames sent %0d", ev_tx_count, received));
    tb_check(ev_rx_count == leaf_frames, $sformatf("ev_rx_frame pulses %0d = frames to the leaves %0d", ev_rx_count,
             leaf_frames));
    tb_check(leaf_frames == exp_frames, $sformatf("frames delivered to the leaves %0d = stored %0d", leaf_frames,
             exp_frames));
    // Claims: every answered request, nothing else.
    tb_check(u_arp_claim.claims == arp_replies, $sformatf("ARP claims %0d = ARP replies %0d", u_arp_claim.claims,
             arp_replies));
    tb_check(u_icmp_claim.claims == icmp_replies, $sformatf("ICMP claims %0d = ICMP replies %0d", u_icmp_claim.claims,
             icmp_replies));
    axi_expect(R_DELIVERED, 32'(leaf_frames), "DELIVERED_FRAMES = frames toward the leaves");
    axi_rd(R_CPU_RX, v);
    tb_check(v == 32'(u_cpu_sink.frame_count), $sformatf("CPU_RX_FRAMES %0d = frames at m_axis_cpu_eth %0d", v,
             u_cpu_sink.frame_count));
    if (CPU_PATH != 0) tb_check(v > 0, "unanswered frames reached the CPU");
    else               tb_check(u_cpu_sink.frame_count == 0, "no CPU path: nothing reached the CPU");

    // ---- CNT_CLEAR: the four counters restart from 0 together.
    axi_wr(R_CTRL, CTRL_DEFAULT | 32'h0001_0000);
    axi_expect(R_CTRL, CTRL_DEFAULT, "CTRL after CNT_CLEAR (pulse reads 0)");
    offered      = 0;
    exp_frames   = 0;
    exp_filtered = 0;
    exp_dropped  = 0;
    received     = 0;
    check_counters("after CNT_CLEAR");
    ping_case("ping after CNT_CLEAR", cur_mac, cur_ip, 5, 1'b1);
    ping_case("filtered after CNT_CLEAR", 48'h02_00_00_00_00_99, cur_ip, 5, 1'b0, 1);
    check_counters("traffic after CNT_CLEAR");
    begin
      logic [31:0] dl;
      logic [31:0] cr;
      logic [31:0] cc;
      logic [31:0] cd;
      axi_rd(R_DELIVERED, dl);
      axi_rd(R_CPU_RX, cr);
      axi_rd(R_CPU_CLAIM, cc);
      axi_rd(R_CPU_DROP, cd);
      tb_check(dl == 32'd1, $sformatf("DELIVERED after CNT_CLEAR %0d, expected 1", dl));
      if (CPU_PATH != 0) begin
        tb_check(dl == cr + cc + cd, $sformatf("CPU identity: DELIVERED %0d = TO_CPU %0d + CLAIMED %0d + DROPPED %0d",
                 dl, cr, cc, cd));
        tb_check(cc == 32'd1, "the ping after CNT_CLEAR was claimed");
      end else begin
        tb_check(cr + cc + cd == 32'd0, "no CPU path: CPU counters stay 0");
      end
    end

    tb_check(u_icmp_mon.ready_errors == 0 && u_arp_mon.ready_errors == 0, "leaves held s_axis_tready at 1");
    tb_verdict("tb_rtlnet_eth_protocol");
  end

  // Watchdog.
  initial begin
    #300ms;
    tb_error("watchdog: the bench did not finish");
    tb_verdict("tb_rtlnet_eth_protocol");
  end

endmodule
