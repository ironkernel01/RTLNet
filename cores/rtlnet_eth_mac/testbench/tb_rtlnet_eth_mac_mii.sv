// -----------------------------------------------------------------------------
// File: tb_rtlnet_eth_mac_mii.sv
// Purpose: IronKernel RTLNet MII integration bench with independent wire CRC oracle.
// Overview: both PHY clock rates, min/max frames, padding, back-to-back traffic,
//   odd preamble alignment, FCS/RX_ER/dangling/runt/oversize rejection and status.
// Language: SystemVerilog-2012, simulation only, source-available.
// Revision: 11-14-2026
//   * 11-14-2026: add DP83848 MII regression.
// Clocks: axis_clk 62.5 MHz, s_axi_aclk 100 MHz; PHY TX/RX 25 or 2.5 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
module tb_rtlnet_eth_mac_mii;
  import rtlnet_tb_pkg::*;
  logic axis_clk = 0;
  logic s_axi_aclk = 0;
  logic axis_resetn = 0;
  logic s_axi_aresetn = 0;
  logic mii_rx_clk;
  logic mii_tx_clk;
  logic [3:0] mii_rxd;
  logic mii_rx_dv;
  logic mii_rx_er;
  logic [3:0] mii_txd;
  logic mii_tx_en;
  always #8 axis_clk = !axis_clk;
  always #5 s_axi_aclk = !s_axi_aclk;
  logic [63:0] rx_tdata;
  logic [7:0]  rx_tkeep;
  logic        rx_tvalid;
  logic        rx_tlast;
  logic        rx_tready;
  logic [63:0] tx_tdata;
  logic [7:0]  tx_tkeep;
  logic        tx_tvalid;
  logic        tx_tlast;
  logic        tx_tready;
  logic [11:0] awaddr;
  logic        awvalid;
  logic        awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;
  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;
  logic [11:0] araddr;
  logic        arvalid;
  logic        arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;
  logic        stat_link_up;
  logic [1:0]  stat_speed;
  logic        stat_rx_clk_ok;
  logic        ev_rx_good;
  logic        ev_rx_bad;
  logic        ev_tx_frame;
  // MAC integrates shared byte engines and FIFOs with independent PHY clocks.
  rtlnet_eth_mac_mii u_dut (
    .axis_clk(axis_clk), .s_axi_aclk(s_axi_aclk),
    .axis_resetn(axis_resetn), .s_axi_aresetn(s_axi_aresetn),
    .mii_rx_clk(mii_rx_clk), .mii_tx_clk(mii_tx_clk),
    .mii_rxd(mii_rxd), .mii_rx_dv(mii_rx_dv), .mii_rx_er(mii_rx_er),
    .mii_txd(mii_txd), .mii_tx_en(mii_tx_en),
    .m_axis_rx_tdata  (rx_tdata),
    .m_axis_rx_tkeep  (rx_tkeep),
    .m_axis_rx_tvalid (rx_tvalid),
    .m_axis_rx_tlast  (rx_tlast),
    .m_axis_rx_tready (rx_tready),
    .s_axis_tx_tdata  (tx_tdata),
    .s_axis_tx_tkeep  (tx_tkeep),
    .s_axis_tx_tvalid (tx_tvalid),
    .s_axis_tx_tlast  (tx_tlast),
    .s_axis_tx_tready (tx_tready),
    .s_axi_awaddr     (awaddr),
    .s_axi_awvalid    (awvalid),
    .s_axi_awready    (awready),
    .s_axi_wdata      (wdata),
    .s_axi_wstrb      (wstrb),
    .s_axi_wvalid     (wvalid),
    .s_axi_wready     (wready),
    .s_axi_bresp      (bresp),
    .s_axi_bvalid     (bvalid),
    .s_axi_bready     (bready),
    .s_axi_araddr     (araddr),
    .s_axi_arvalid    (arvalid),
    .s_axi_arready    (arready),
    .s_axi_rdata      (rdata),
    .s_axi_rresp      (rresp),
    .s_axi_rvalid     (rvalid),
    .s_axi_rready     (rready),
    .stat_link_up     (stat_link_up),
    .stat_speed       (stat_speed),
    .stat_rx_clk_ok   (stat_rx_clk_ok),
    .ev_rx_good       (ev_rx_good),
    .ev_rx_bad        (ev_rx_bad),
    .ev_tx_frame      (ev_tx_frame)
  );
  rtlnet_tb_axil_master #(.ADDR_W(12)) u_axil (
    .aclk(s_axi_aclk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  rtlnet_tb_axis_src #(.GAP_PCT(5), .SEED(3)) u_src (
    .clk(axis_clk), .tdata(tx_tdata), .tkeep(tx_tkeep), .tlast(tx_tlast), .tvalid(tx_tvalid), .tready(tx_tready));

  rtlnet_tb_axis_sink #(.READY_PCT(90), .SEED(17), .NAME("m_axis_rx")) u_sink (
    .clk(axis_clk), .resetn(axis_resetn), .tdata(rx_tdata), .tkeep(rx_tkeep), .tlast(rx_tlast),
    .tvalid(rx_tvalid), .tready(rx_tready));

  // PHY drives both clocks with deliberately independent phase.
  rtlnet_dp83848_model u_phy (
    .mii_rx_clk(mii_rx_clk), .mii_tx_clk(mii_tx_clk),
    .mii_rxd(mii_rxd), .mii_rx_dv(mii_rx_dv), .mii_rx_er(mii_rx_er),
    .mii_txd(mii_txd), .mii_tx_en(mii_tx_en)
  );
  int speed_mbps;
  logic [31:0] ctrl;
  logic [31:0] value;
  bytes_t frame;
  bytes_t got;
  bit ok;
  int expected_good = 0;
  int expected_bad = 0;
  int expected_tx = 0;

  function automatic bytes_t pattern(input int length, input int seed);
    bytes_t f;
    for (int i = 0; i < length; i++) f.push_back(byte'(seed + i * 37));
    return f;
  endfunction

  task automatic equal_frame(input bytes_t actual, input bytes_t want, input string label_text);
    tb_check(actual.size() == want.size(), {label_text, " length"});
    for (int i = 0; i < want.size() && i < actual.size(); i++)
      tb_check(actual[i] === want[i], $sformatf("%s byte %0d", label_text, i));
  endtask

  task automatic receive_good(input int length, input int pre_nibbles);
    frame = pattern(length, length);
    u_phy.send(frame, 0, pre_nibbles);
    u_sink.get(got, 200000, ok);
    tb_check(ok, "RX completes");
    equal_frame(got, frame, "RX");
    expected_good++;
  endtask

  task automatic transmit_check(input bytes_t want);
    bytes_t padded;
    u_phy.get(got, ok);
    tb_check(ok, "TX completes");
    padded = want;
    while (padded.size() < 60) padded.push_back(0);
    equal_frame(got, padded, "TX");
    expected_tx++;
  endtask

  // End-to-end cases; corruption is checked through counters and absence at the client.
  initial begin
    speed_mbps = 100;
    if ($value$plusargs("SPEED=%d", speed_mbps)) begin end
    ctrl = (speed_mbps == 100) ? 32'h113 : 32'h103;
    #1000;
    axis_resetn = 1;
    s_axi_aresetn = 1;
    u_axil.wr(12'h00c, ctrl);
    #150000;
    u_axil.rd(12'h010, value);
    tb_check(value[2:0] == 3'b011, "RX clock qualifies and MII ready");
    tb_check(value[5:4] == ctrl[5:4], "STATUS speed encoding");
    tb_check(value[11:8] == 0, "MII has no in-band status");
    u_axil.rd(12'h014, value);
    tb_check(speed_mbps == 100 ? (value >= 88 && value <= 116) : (value >= 8 && value <= 13), "RXC measured rate");
    receive_good(60, 15);
    receive_good(1518, 14);
    // Shortened preambles: SFD preceded by one, two and three preamble nibbles.
    receive_good(61, 1);
    receive_good(62, 2);
    receive_good(63, 3);
    // False carrier and a carrier without SFD are ignored, the next frame is intact.
    u_phy.false_carrier(3);
    u_phy.carrier_no_sfd(20);
    receive_good(64, 15);
    // Minimum IFG back-to-back RX, with sink back-pressure.
    frame = pattern(61, 23);
    u_phy.send(frame, 0, 5);
    u_phy.send(frame, 0, 15);
    for (int i = 0; i < 2; i++) begin
      u_sink.get(got, 200000, ok);
      tb_check(ok, "back-to-back RX");
      equal_frame(got, frame, "RX queued");
      expected_good++;
    end
    // FCS, RX_ER on either nibble, preamble error, dangling nibble, runt, oversize.
    for (int fault = 1; fault <= 7; fault++) begin
      frame = pattern(60, fault);
      u_phy.send(frame, fault, 15);
      expected_bad++;
    end
    frame = pattern(59, 91);
    u_phy.send(frame, 0, 15);
    expected_bad++;
    frame = pattern(1519, 92);
    u_phy.send(frame, 0, 15);
    expected_bad++;
    // Frames with 4 octets after the SFD (empty payload) and a 10-octet runt, valid FCS.
    frame = pattern(0, 0);
    u_phy.send(frame, 0, 15);
    expected_bad++;
    frame = pattern(6, 93);
    u_phy.send(frame, 0, 15);
    expected_bad++;
    // Good frame right behind the rejected ones.
    receive_good(60, 15);
    u_sink.expect_none(1000, ok);
    tb_check(ok, "bad RX frames never delivered");
    // Queue frames before transmission; the model verifies CRC, nibble order and IFG.
    frame = pattern(14, 1);
    u_src.send(frame);
    transmit_check(frame);
    frame = pattern(1518, 2);
    u_src.send(frame);
    transmit_check(frame);
    frame = pattern(60, 3);
    u_src.send(frame);
    u_src.send(frame);
    transmit_check(frame);
    transmit_check(frame);
    // TX_EN = 0: queued frames are consumed and nothing is sent; sending resumes afterwards.
    u_axil.wr(12'h00c, ctrl & ~32'h2);
    #20000;
    frame = pattern(80, 5);
    u_src.send(frame);
    #200000;
    tb_check(u_phy.pending() == 0, "TX_EN low sends nothing");
    u_axil.wr(12'h00c, ctrl);
    #20000;
    frame = pattern(70, 6);
    u_src.send(frame);
    transmit_check(frame);
    tb_check(u_phy.pending() == 0, "no spurious TX frame");
    repeat (100) @(posedge axis_clk);
    u_axil.rd(12'h020, value);
    tb_check(value == expected_good, "RX_GOOD exact");
    u_axil.rd(12'h024, value);
    tb_check(value == expected_bad, "RX_BAD exact");
    u_axil.rd(12'h02c, value);
    tb_check(value == expected_tx, "TX_FRAMES exact");
    // A mismatched speed must gate receive even though RXC keeps running.
    u_axil.wr(12'h00c, ctrl ^ 32'h10);
    #150000;
    u_axil.rd(12'h010, value);
    tb_check(!value[0] && value[2], "mismatched clock holds RX reset");
    frame = pattern(60, 4);
    u_phy.send(frame, 0, 15);
    u_sink.expect_none(1000, ok);
    tb_check(ok, "mismatched rate admits nothing");
    u_axil.wr(12'h00c, ctrl);
    #150000;
    receive_good(60, 15);
    tb_verdict("tb_rtlnet_eth_mac_mii");
  end
  // Bounded watchdog also emits the single verdict on a hung transaction.
  initial begin
    #30ms;
    tb_error("watchdog");
    tb_verdict("tb_rtlnet_eth_mac_mii");
  end
endmodule
