// -----------------------------------------------------------------------------
// File: tb_rtlnet_eth_mac.sv
// Purpose: full-MAC bench of rtlnet_eth_mac with its pin layer (AMD unisim
//   primitives by default, behavioural with RTLNET_TECH_GENERIC) against the
//   RTL8211E model, registers driven through rtlnet_tb_axil_master and an
//   MDIO master in the bench, the way firmware brings the link up.
// Overview:
//   * +SPEED=1000|100|10 (default 1000) selects the link partner's speed and
//     so the link speed; +SPEED=<mbps>,WALK (or +WALK) adds a live speed walk
//     through the other two speeds and back.
//   * Bring-up: PHY reset pin, MDIO ID/BMCR/BMSR/ANAR/GBCR checks, BMCR soft
//     reset with bit 15 polled until clear, RX clock delay enabled through
//     PAGSEL 7 / EPAGSR 0xA4 / register 28 bits 13 and 11 with read-back,
//     link and PHYSR (speed, duplex, resolved, link).
//   * Mismatch: CTRL selects a speed that RXC does not run at: RX_CLK_OK stays
//     0, the receive path stays in reset, injected frames are not admitted
//     and no counter moves; RX_CLK_RATE reads the true rate.
//   * Running: STATUS (RXC ok, delay ready, out of reset, speed in effect,
//     in-band link/speed/duplex), status outputs; injected frames (60..1518
//     bytes, one with a 3-octet / 14-nibble preamble) arrive byte-exact on
//     m_axis_rx with sink stalls; bad FCS, runt, oversize, RX_ER and (10/100)
//     dangling-nibble frames are dropped and counted in RX_BAD exactly;
//     frames on s_axis_tx (14..1518 bytes) are captured by the model with a
//     good preamble, zero padding to 60, the right FCS, no TX_ER, a gap of at
//     least 12 byte times, setup/hold within the model's 1 ns limits (and at
//     10/100 at least 20 % of the nibble period) and the nominal TXC period.
//   * PHY loopback (BMCR 0.14): a transmitted frame comes back byte-exact.
//   * PHY link resolution: dropping the 1000 advertisement (GBCR) or the 100
//     advertisement (ANAR) with restart-AN, or a forced 10 Mb/s BMCR, gives
//     the expected PHYSR speed; the MAC follows and passes traffic; the
//     defaults are restored the same way.
//   * RX overflow with the client stalled: 6 frames, 4 stored, RX_OVERFLOW 2.
//   * TX_EN = 0 discards queued frames without blocking s_axis_tx; RX_EN = 0
//     holds the receive path in reset; a speed write that mismatches RXC
//     resets the receive path; CNT_CLEAR zeroes every counter; the ev_*
//     pulse counts equal the counters.
//   * One verdict line; watchdog.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk125 8 ns, clk125_90 the same 2 ns later, clk200 5 ns, axis_clk
//   16 ns, s_axi_aclk 10 ns; RXC from the PHY model.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_eth_mac;

  import rtlnet_tb_pkg::*;

  // Register map (driver header cores/rtlnet_eth_mac/driver/rtlnet_eth_mac.h).
  localparam logic [11:0] REG_ID            = 12'h000;
  localparam logic [11:0] REG_VERSION       = 12'h004;
  localparam logic [11:0] REG_CAPS          = 12'h008;
  localparam logic [11:0] REG_CTRL          = 12'h00C;
  localparam logic [11:0] REG_STATUS        = 12'h010;
  localparam logic [11:0] REG_RX_CLK_RATE   = 12'h014;
  localparam logic [11:0] REG_RX_IDELAY_TAP = 12'h018;
  localparam logic [11:0] REG_RX_GOOD       = 12'h020;
  localparam logic [11:0] REG_RX_BAD        = 12'h024;
  localparam logic [11:0] REG_RX_OVERFLOW   = 12'h028;
  localparam logic [11:0] REG_TX_FRAMES     = 12'h02C;
  localparam logic [31:0] CTRL_RX_EN        = 32'h0000_0001;
  localparam logic [31:0] CTRL_TX_EN        = 32'h0000_0002;
  localparam logic [31:0] CTRL_LINK_UP      = 32'h0000_0100;
  localparam logic [31:0] CTRL_CNT_CLEAR    = 32'h0001_0000;
  localparam logic [31:0] ST_RX_CLK_OK      = 32'h0000_0001;
  localparam logic [31:0] ST_IDELAY_RDY     = 32'h0000_0002;
  localparam logic [31:0] ST_RX_IN_RESET    = 32'h0000_0004;

  localparam int  PHYAD          = 1;
  localparam time MDC_HALF       = 200ns;
  localparam time WATCHDOG       = 200ms;
  localparam int  FAULT_RX_ER    = 1;
  localparam int  FAULT_DANGLING = 2;
  localparam int  FAULT_SHORT    = 4;

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic clk125     = 1'b0;
  logic clk125_90  = 1'b0;
  logic clk200     = 1'b0;
  logic axis_clk   = 1'b0;
  logic s_axi_aclk = 1'b0;
  logic arstn      = 1'b0;
  logic phy_rst_n  = 1'b0;
  logic clk125_resetn;
  logic clk200_resetn;
  logic axis_resetn;
  logic s_axi_aresetn;

  always #4.0 clk125 = ~clk125;
  initial begin
    #2.0;
    forever #4.0 clk125_90 = ~clk125_90;
  end
  always #2.5 clk200 = ~clk200;
  always #8.0 axis_clk = ~axis_clk;
  always #5.0 s_axi_aclk = ~s_axi_aclk;

  // One assertion, one release per domain (as the board top does).
  rtlnet_reset_sync u_rst_125  (.clk(clk125),     .arstn(arstn), .resetn(clk125_resetn));
  rtlnet_reset_sync u_rst_200  (.clk(clk200),     .arstn(arstn), .resetn(clk200_resetn));
  rtlnet_reset_sync u_rst_axis (.clk(axis_clk),   .arstn(arstn), .resetn(axis_resetn));
  rtlnet_reset_sync u_rst_axi  (.clk(s_axi_aclk), .arstn(arstn), .resetn(s_axi_aresetn));

  // ---------------------------------------------------------------------------
  // DUT, PHY model, bus models
  // ---------------------------------------------------------------------------
  logic        rgmii_rxc;
  logic [3:0]  rgmii_rxd;
  logic        rgmii_rx_ctl;
  logic        rgmii_txc;
  logic [3:0]  rgmii_txd;
  logic        rgmii_tx_ctl;
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
  logic        mdc  = 1'b0;
  logic        m_oe = 1'b0;
  logic        m_o  = 1'b1;
  wire         mdio;
  logic        phy_link_up;
  logic [1:0]  phy_link_speed;
  logic        phy_rxdly_on;
  logic        phy_txdly_on;
  int          phy_tx_viol;

  assign mdio = m_oe ? m_o : 1'bz;
  pullup (mdio);

  rtlnet_eth_mac u_dut (
    .clk125           (clk125),
    .clk125_90        (clk125_90),
    .clk200           (clk200),
    .axis_clk         (axis_clk),
    .s_axi_aclk       (s_axi_aclk),
    .clk125_resetn    (clk125_resetn),
    .clk200_resetn    (clk200_resetn),
    .axis_resetn      (axis_resetn),
    .s_axi_aresetn    (s_axi_aresetn),
    .rgmii_rxc        (rgmii_rxc),
    .rgmii_rxd        (rgmii_rxd),
    .rgmii_rx_ctl     (rgmii_rx_ctl),
    .rgmii_txc        (rgmii_txc),
    .rgmii_txd        (rgmii_txd),
    .rgmii_tx_ctl     (rgmii_tx_ctl),
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

  rtlnet_rtl8211e_model #(
    .NAME                  ("phy"),
    .PHYAD                 (PHYAD),
    .RESET_SETTLE_NS       (5_000),
    .LINK_UP_DELAY_NS      (20_000),
    .SPEED_CHANGE_DELAY_NS (20_000),
    .SOFT_RESET_NS         (60_000)
  ) u_phy (
    .phy_rst_n     (phy_rst_n),
    .mdc           (mdc),
    .mdio          (mdio),
    .rxc           (rgmii_rxc),
    .rxd           (rgmii_rxd),
    .rx_ctl        (rgmii_rx_ctl),
    .txc           (rgmii_txc),
    .txd           (rgmii_txd),
    .tx_ctl        (rgmii_tx_ctl),
    .link_up       (phy_link_up),
    .link_speed    (phy_link_speed),
    .rxdly_on      (phy_rxdly_on),
    .txdly_on      (phy_txdly_on),
    .tx_viol_count (phy_tx_viol)
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

  // Event pulse counters.
  int ev_good_n = 0;
  int ev_bad_n  = 0;
  int ev_tx_n   = 0;

  always @(posedge axis_clk) begin
    if (axis_resetn) begin
      if (ev_rx_good)  ev_good_n++;
      if (ev_rx_bad)   ev_bad_n++;
      if (ev_tx_frame) ev_tx_n++;
    end
  end

  // ---------------------------------------------------------------------------
  // Test state
  // ---------------------------------------------------------------------------
  int         speed_mbps = 1000;
  logic [1:0] spd_code   = 2'b10;
  int         byte_ns    = 8;
  int         frame_timeout_ns;
  int         exp_rx_good = 0;
  int         exp_rx_bad  = 0;
  int         exp_rx_ovf  = 0;
  int         exp_tx      = 0;

  function automatic logic [1:0] code_of(input int mbps);
    return (mbps == 10) ? 2'b00 : (mbps == 100) ? 2'b01 : 2'b10;
  endfunction

  function automatic int byte_ns_of(input logic [1:0] code);
    return (code == 2'b00) ? 800 : (code == 2'b01) ? 80 : 8;
  endfunction

  function automatic bytes_t random_frame(input int len);
    bytes_t f;
    f = eth_header(48'h02_49_4B_52_4E_01, 48'h02_00_00_00_00_AA, 16'h88B5);
    while (f.size() < len) f.push_back(8'($urandom));
    while (f.size() > len) void'(f.pop_back());
    return f;
  endfunction

  // ---------------------------------------------------------------------------
  // MDIO master (Clause 22, bit-banged as the firmware does)
  // ---------------------------------------------------------------------------
  task automatic mdio_bit_out(input bit b);
    m_oe = 1'b1;
    m_o  = b;
    #(MDC_HALF);
    mdc = 1'b1;
    #(MDC_HALF);
    mdc = 1'b0;
  endtask

  task automatic mdio_header(input logic [1:0] op, input logic [4:0] regad);
    for (int i = 0; i < 32; i++) mdio_bit_out(1'b1);
    mdio_bit_out(1'b0);
    mdio_bit_out(1'b1);
    mdio_bit_out(op[1]);
    mdio_bit_out(op[0]);
    for (int i = 4; i >= 0; i--) mdio_bit_out(PHYAD[i]);
    for (int i = 4; i >= 0; i--) mdio_bit_out(regad[i]);
  endtask

  task automatic mdio_write(input logic [4:0] regad, input logic [15:0] data);
    mdio_header(2'b01, regad);
    mdio_bit_out(1'b1);
    mdio_bit_out(1'b0);
    for (int i = 15; i >= 0; i--) mdio_bit_out(data[i]);
    m_oe = 1'b0;
    #(4 * MDC_HALF);
  endtask

  task automatic mdio_read(input logic [4:0] regad, output logic [15:0] data, output bit ta_ok);
    mdio_header(2'b10, regad);
    m_oe = 1'b0;
    #(MDC_HALF);
    mdc = 1'b1;
    #(MDC_HALF);
    mdc = 1'b0;
    #(MDC_HALF);
    mdc   = 1'b1;
    ta_ok = (mdio === 1'b0);
    #(MDC_HALF);
    mdc = 1'b0;
    for (int i = 15; i >= 0; i--) begin
      #(MDC_HALF);
      mdc     = 1'b1;
      data[i] = (mdio !== 1'b0);
      #(MDC_HALF);
      mdc = 1'b0;
    end
    #(4 * MDC_HALF);
  endtask

  task automatic mdio_rd_check(input logic [4:0] regad, input logic [15:0] mask, input logic [15:0] exp,
                               input string what);
    logic [15:0] v;
    bit          ta;
    mdio_read(regad, v, ta);
    tb_check(ta && ((v & mask) == exp), $sformatf("MDIO %s: reg %0d = 0x%04x (TA %0d), expected 0x%04x under mask 0x%04x",
             what, regad, v, ta, exp, mask));
  endtask

  // ---------------------------------------------------------------------------
  // Register helpers
  // ---------------------------------------------------------------------------
  task automatic reg_rd(input logic [11:0] a, output logic [31:0] d);
    u_axil.rd(a, d);
  endtask

  task automatic reg_wr(input logic [11:0] a, input logic [31:0] d);
    u_axil.wr(a, d);
  endtask

  task automatic reg_check(input logic [11:0] a, input logic [31:0] exp, input string what);
    logic [31:0] v;
    reg_rd(a, v);
    tb_check(v == exp, $sformatf("%s: reg 0x%03x = 0x%08x, expected 0x%08x", what, a, v, exp));
  endtask

  function automatic logic [31:0] ctrl_word(input logic [1:0] code, input bit rx, input bit tx, input bit link);
    return {23'd0, link, 2'b00, code, 2'b00, tx, rx};
  endfunction

  // Poll STATUS until the receive path runs (RXC ok, out of reset).
  task automatic wait_rx_ready(input int timeout_us, output bit ok);
    logic [31:0] st;
    time         t_end;
    t_end = $time + timeout_us * 1us;
    ok = 1'b0;
    while (!ok && $time < t_end) begin
      reg_rd(REG_STATUS, st);
      ok = st[0] && !st[2];
      if (!ok) #2us;
    end
  endtask

  task automatic check_counters(input string what);
    reg_check(REG_RX_GOOD, 32'(exp_rx_good), {what, ": RX_GOOD"});
    reg_check(REG_RX_BAD, 32'(exp_rx_bad), {what, ": RX_BAD"});
    reg_check(REG_RX_OVERFLOW, 32'(exp_rx_ovf), {what, ": RX_OVERFLOW"});
    reg_check(REG_TX_FRAMES, 32'(exp_tx), {what, ": TX_FRAMES"});
  endtask

  // ---------------------------------------------------------------------------
  // Traffic
  // ---------------------------------------------------------------------------
  // Inject good frames and expect them byte-exact on m_axis_rx.
  task automatic rx_good_frames(input int n, input int max_len, input string what);
    bytes_t exp_q[$];
    bytes_t f;
    bytes_t got;
    bit     ok;
    string  why;
    int     len;
    for (int k = 0; k < n; k++) begin
      case (k)
        0:       len = 60;
        1:       len = 61;
        2:       len = 64;
        3:       len = max_len;
        default: len = 60 + ($urandom % (max_len - 60 + 1));
      endcase
      f = random_frame(len);
      u_phy.inject(f, (k == 1) ? FAULT_SHORT : 0);
      exp_q.push_back(f);
    end
    for (int k = 0; k < $size(exp_q); k++) begin
      u_sink.get(got, frame_timeout_ns / 16 * 2 + 20000, ok);
      tb_check(ok, $sformatf("%s: RX frame %0d (len %0d) delivered", what, k, exp_q[k].size()));
      if (ok) begin
        ok = bytes_equal(got, exp_q[k], why);
        tb_check(ok, $sformatf("%s: RX frame %0d byte-exact: %s", what, k, why));
      end
    end
    exp_rx_good += n;
  endtask

  // Inject frames the MAC must drop; expect nothing on m_axis_rx.
  task automatic rx_bad_frames(input string what);
    bytes_t f;
    bytes_t fcs;
    bit     ok;
    int     n;
    n = 0;
    f   = random_frame(80);
    fcs = crc32_serial_fcs(f);
    for (int i = 0; i < 4; i++) f.push_back(fcs[i]);
    f[f.size() - 2] = f[f.size() - 2] ^ 8'h01;
    u_phy.inject_raw(f, 0);                               // bad FCS
    n++;
    u_phy.inject(random_frame(40), 0);                    // runt
    n++;
    u_phy.inject(random_frame(1530), 0);                  // oversize
    n++;
    u_phy.inject(random_frame(100), FAULT_RX_ER);         // RX_ER
    n++;
    if (spd_code != 2'b10) begin
      u_phy.inject(random_frame(90), FAULT_DANGLING);     // half byte at the end
      n++;
    end
    u_phy.wait_rx_idle(frame_timeout_ns * 6, ok);
    tb_check(ok, $sformatf("%s: bad frames sent", what));
    u_sink.expect_none(2000, ok);
    tb_check(ok, $sformatf("%s: no bad frame delivered", what));
    exp_rx_bad += n;
  endtask

  // Send frames on s_axis_tx and check each at the PHY.
  task automatic tx_frames(input int n, input int max_len, input string what);
    bytes_t sent_q[$];
    bytes_t got;
    bit     fcs_ok;
    bit     pre_ok;
    bit     err;
    bit     ok;
    string  why;
    int     len;
    real    nib_ns;
    real    setup_min;
    real    hold_min;
    setup_min = 1.0e9;
    hold_min  = 1.0e9;
    for (int k = 0; k < n; k++) begin
      case (k)
        0:       len = 14;
        1:       len = 42;
        2:       len = 60;
        3:       len = max_len;
        default: len = 14 + ($urandom % (max_len - 14 + 1));
      endcase
      sent_q.push_back(random_frame(len));
    end
    fork
      begin
        for (int k = 0; k < $size(sent_q); k++) u_src.send(sent_q[k]);
      end
      begin
        for (int k = 0; k < $size(sent_q); k++) begin
          u_phy.get_tx_frame(got, fcs_ok, pre_ok, err, frame_timeout_ns * 2 + 100000, ok);
          tb_check(ok, $sformatf("%s: TX frame %0d captured", what, k));
          if (ok) begin
            tb_check(pre_ok, $sformatf("%s: TX frame %0d preamble/SFD", what, k));
            tb_check(fcs_ok, $sformatf("%s: TX frame %0d FCS", what, k));
            tb_check(!err, $sformatf("%s: TX frame %0d TX_ER/dangling nibble", what, k));
            ok = bytes_equal(got, pad60(sent_q[k]), why);
            tb_check(ok, $sformatf("%s: TX frame %0d (len %0d) padded body: %s", what, k, sent_q[k].size(), why));
            if (u_phy.last_gap_ns >= 0)
              tb_check(u_phy.last_gap_ns >= 12.0 * byte_ns - 0.01,
                       $sformatf("%s: TX gap before frame %0d = %0.1f ns (12 byte times = %0d ns)", what, k,
                                 u_phy.last_gap_ns, 12 * byte_ns));
            if (u_phy.last_setup_min_ns < setup_min) setup_min = u_phy.last_setup_min_ns;
            if (u_phy.last_hold_min_ns < hold_min)   hold_min  = u_phy.last_hold_min_ns;
            tb_check(u_phy.last_setup_min_ns >= 1.0 && u_phy.last_hold_min_ns >= 1.0,
                     $sformatf("%s: TX frame %0d setup %0.3f / hold %0.3f ns", what, k, u_phy.last_setup_min_ns,
                               u_phy.last_hold_min_ns));
            if (spd_code != 2'b10) begin
              nib_ns = byte_ns / 2.0;
              tb_check(u_phy.last_setup_min_ns >= 0.2 * nib_ns && u_phy.last_hold_min_ns >= 0.2 * nib_ns,
                       $sformatf("%s: TX frame %0d 10/100 margin setup %0.1f / hold %0.1f ns (nibble %0.0f ns)", what,
                                 k, u_phy.last_setup_min_ns, u_phy.last_hold_min_ns, nib_ns));
            end
          end
        end
      end
    join
    $display("[%0t] tb_rtlnet_eth_mac: %s at code %0d: TX setup min %0.3f ns, hold min %0.3f ns, TXC period %0.3f ns",
             $time, what, spd_code, setup_min, hold_min, u_phy.tx_period_ns);
    tb_check(u_phy.tx_period_ns > byte_ns * ((spd_code == 2'b10) ? 1.0 : 0.5) - 0.01 &&
             u_phy.tx_period_ns < byte_ns * ((spd_code == 2'b10) ? 1.0 : 0.5) + 0.01,
             $sformatf("%s: TXC period %0.2f ns", what, u_phy.tx_period_ns));
    exp_tx += n;
  endtask

  // Running checks after the receive path is up at spd_code.
  task automatic check_running(input string what);
    logic [31:0] st;
    logic [31:0] rate;
    int          lo;
    int          hi;
    reg_rd(REG_STATUS, st);
    tb_check(st[0] && st[1] && !st[2], $sformatf("%s: STATUS 0x%08x RX_CLK_OK, IDELAY_RDY, not in reset", what, st));
    tb_check(st[5:4] == spd_code, $sformatf("%s: STATUS speed %0d, expected %0d", what, st[5:4], spd_code));
    tb_check(st[8] && st[10:9] == spd_code && st[11], $sformatf("%s: in-band link/speed/duplex 0x%08x", what, st));
    reg_rd(REG_RX_CLK_RATE, rate);
    lo = (spd_code == 2'b10) ? 500 : (spd_code == 2'b01) ? 100 : 9;
    hi = (spd_code == 2'b10) ? 524 : (spd_code == 2'b01) ? 105 : 11;
    tb_check(rate >= lo && rate <= hi, $sformatf("%s: RX_CLK_RATE %0d, expected %0d..%0d", what, rate, lo, hi));
    tb_check(stat_link_up && stat_speed == spd_code && stat_rx_clk_ok,
             $sformatf("%s: status outputs link %0d speed %0d rx_clk_ok %0d", what, stat_link_up, stat_speed,
                       stat_rx_clk_ok));
  endtask

  // Poll PHYSR until the PHY reports the link at `code`.
  task automatic wait_phy_link(input logic [1:0] code, input string what);
    logic [15:0] v;
    bit          ta;
    bit          ok;
    ok = 1'b0;
    for (int i = 0; i < 200 && !ok; i++) begin
      mdio_read(5'd17, v, ta);
      ok = ta && v[10] && v[11] && (v[15:14] == code) && v[13];
    end
    tb_check(ok, $sformatf("%s: PHYSR 0x%04x link up at code %0d, full duplex, resolved", what, v, code));
  endtask

  // Firmware speed follow: write CTRL and wait for the receive path.
  task automatic mac_follow(input logic [1:0] code, input string what);
    bit ok;
    spd_code = code;
    byte_ns  = byte_ns_of(code);
    frame_timeout_ns = (1518 + 30) * byte_ns;
    reg_wr(REG_CTRL, ctrl_word(code, 1'b1, 1'b1, 1'b1));
    wait_rx_ready(400, ok);
    tb_check(ok, $sformatf("%s: receive path running at code %0d", what, code));
  endtask

  // ---------------------------------------------------------------------------
  // Sequence
  // ---------------------------------------------------------------------------
  initial begin
    logic [31:0] v32;
    logic [15:0] v16;
    bit          ta;
    bit          ok;
    bytes_t      f;
    bytes_t      got;
    string       why;
    logic [1:0]  wrong;
    logic [1:0]  walk_codes[3];
    int          n_walk;
    string       opt;
    bit          walk;

    // +SPEED=<mbps>[,WALK]: one plusarg carries both options (the runner passes
    // a comma-joined list as one argument); a separate +WALK also works.
    walk = $test$plusargs("WALK");
    if ($value$plusargs("SPEED=%s", opt)) begin
      speed_mbps = opt.atoi();
      for (int i = 0; i + 4 <= opt.len(); i++) if (opt.substr(i, i + 3) == "WALK") walk = 1'b1;
    end else begin
      speed_mbps = 1000;
    end
    spd_code = code_of(speed_mbps);
    byte_ns  = byte_ns_of(spd_code);
    frame_timeout_ns = (1518 + 30) * byte_ns;
    $display("[%0t] tb_rtlnet_eth_mac: link speed %0d Mb/s%s", $time, speed_mbps, walk ? ", speed walk" : "");
    u_phy.set_partner_speed(spd_code);

    // Resets: one assertion for the FPGA, then the PHY reset pin.
    repeat (20) @(posedge axis_clk);
    arstn = 1'b1;
    #1us;
    phy_rst_n = 1'b1;

    // ---- MDIO bring-up (what the MDIO driver does) ----
    ok = 1'b0;
    for (int i = 0; i < 50 && !ok; i++) begin
      mdio_read(5'd2, v16, ta);
      ok = ta && (v16 == 16'h001C);
    end
    tb_check(ok, "MDIO: PHYID1 0x001C after the reset settle");
    mdio_rd_check(5'd3, 16'hFFFF, 16'hC915, "PHYID2");
    mdio_rd_check(5'd0, 16'hFFFF, 16'h1140, "BMCR default");
    mdio_rd_check(5'd4, 16'hFFFF, 16'h05E1, "ANAR default");
    mdio_rd_check(5'd9, 16'hFFFF, 16'h0200, "GBCR default");
    mdio_rd_check(5'd1, 16'hFFDB, 16'h7949, "BMSR capability bits");
    mdio_write(5'd0, 16'h9140);                            // soft reset
    mdio_read(5'd0, v16, ta);
    tb_check(ta && v16[15], $sformatf("MDIO: BMCR.15 reads 1 during soft reset (0x%04x)", v16));
    ok = 1'b0;
    for (int i = 0; i < 20 && !ok; i++) begin
      mdio_read(5'd0, v16, ta);
      ok = ta && !v16[15];
    end
    tb_check(ok && v16 == 16'h1140, $sformatf("MDIO: soft reset self-clears to 0x1140 (0x%04x)", v16));
    // RX clock delay on: extension page 0xA4, register 28 bits 13 and 11.
    mdio_write(5'd31, 16'h0007);
    mdio_write(5'd30, 16'h00A4);
    mdio_rd_check(5'd28, 16'hFFFF, 16'h8575, "ext 0xA4 reg 28 default");
    mdio_write(5'd28, 16'h8575 | 16'h2800);
    mdio_rd_check(5'd28, 16'hFFFF, 16'hAD75, "ext 0xA4 reg 28 read-back");
    mdio_write(5'd31, 16'h0000);
    mdio_rd_check(5'd28, 16'hFFFF, 16'h0000, "reg 28 outside the extension page");
    tb_check(phy_rxdly_on && !phy_txdly_on, "PHY RX delay on, TX delay off");
    wait_phy_link(spd_code, "bring-up");
    mdio_rd_check(5'd1, 16'h0024, 16'h0024, "BMSR link / AN complete");
    mdio_rd_check(5'd10, 16'hFFFF, (spd_code == 2'b10) ? 16'h3800 : 16'h0000, "GBSR");
    mdio_rd_check(5'd5, 16'hFFFF, (spd_code == 2'b10) ? 16'h45E1 : (spd_code == 2'b01) ? 16'h41E1 : 16'h4061,
                  "ANLPAR of the model partner");

    // ---- MAC identity and reset state ----
    reg_check(REG_ID, 32'h4D414331, "ID");
    reg_check(REG_VERSION, 32'h10222026, "VERSION");
    reg_check(REG_CAPS, {16'd1518, 8'd8, 8'd8}, "CAPS");
    reg_check(REG_RX_IDELAY_TAP, 32'd12, "RX_IDELAY_TAP");
    reg_check(REG_CTRL, 32'h0, "CTRL reset value");
    reg_check(12'h01C, 32'h0, "undefined offset reads 0");
    reg_rd(REG_STATUS, v32);
    // CTRL.SPEED resets to 10 Mb/s, so RXC qualifies at reset only on a 10 Mb/s link.
    tb_check(v32[1] && v32[2] && (v32[0] == (spd_code == 2'b00)),
             $sformatf("STATUS after reset 0x%08x: delay ready, RX in reset, RXC qualified only at 10 Mb/s", v32));
    check_counters("reset");

    // ---- Mismatch: CTRL speed differs from RXC ----
    wrong = (spd_code == 2'b10) ? 2'b01 : (spd_code == 2'b01) ? 2'b00 : 2'b10;
    reg_wr(REG_CTRL, ctrl_word(wrong, 1'b1, 1'b1, 1'b1));
    #150us;
    reg_rd(REG_STATUS, v32);
    tb_check(!v32[0] && v32[2], $sformatf("mismatch: STATUS 0x%08x RX_CLK_OK 0, RX in reset", v32));
    tb_check(!stat_rx_clk_ok, "mismatch: stat_rx_clk_ok low");
    reg_rd(REG_RX_CLK_RATE, v32);
    tb_check((spd_code == 2'b10 && v32 >= 500 && v32 <= 524) || (spd_code == 2'b01 && v32 >= 100 && v32 <= 105) ||
             (spd_code == 2'b00 && v32 >= 9 && v32 <= 11), $sformatf("mismatch: RX_CLK_RATE %0d is the true rate", v32));
    for (int k = 0; k < 2; k++) u_phy.inject(random_frame(64), 0);
    u_phy.wait_rx_idle(frame_timeout_ns * 3, ok);
    u_sink.expect_none(1000, ok);
    tb_check(ok, "mismatch: no frame admitted");
    check_counters("mismatch");
    tb_check(ev_good_n == 0 && ev_bad_n == 0, "mismatch: no ev_rx_good / ev_rx_bad pulse");

    // ---- Correct speed: the receive path runs ----
    mac_follow(spd_code, "follow");
    check_running("running");
    rx_good_frames((spd_code == 2'b10) ? 16 : (spd_code == 2'b01) ? 8 : 4,
                   (spd_code == 2'b00) ? 600 : 1518, "RX good");
    rx_bad_frames("RX bad");
    check_counters("after RX");
    tx_frames((spd_code == 2'b10) ? 16 : (spd_code == 2'b01) ? 8 : 4, (spd_code == 2'b00) ? 600 : 1518, "TX");
    #5us;
    check_counters("after TX");

    // ---- PHY loopback: a transmitted frame comes back ----
    mdio_write(5'd0, 16'h5140);
    f = random_frame(100);
    u_src.send(f);
    u_sink.get(got, frame_timeout_ns / 8 + 20000, ok);
    tb_check(ok && bytes_equal(got, f, why), $sformatf("loopback: frame returned byte-exact %s", why));
    u_phy.get_tx_frame(got, ok, ok, ok, 1000, ok);           // drop the wire copy
    mdio_write(5'd0, 16'h1140);
    exp_tx++;
    exp_rx_good++;
    #5us;
    check_counters("after loopback");

    // ---- RX overflow: client stalled, 6 frames, 4 slots ----
    begin
      bytes_t ovf_q[$];
      u_sink.ready_pct = 0;
      #1us;
      for (int k = 0; k < 6; k++) begin
        f = random_frame(64 + k);
        u_phy.inject(f, 0);
        if (k < 4) ovf_q.push_back(f);
      end
      u_phy.wait_rx_idle(frame_timeout_ns, ok);
      #5us;
      reg_rd(REG_RX_OVERFLOW, v32);
      tb_check(v32 == 32'd2, $sformatf("overflow: RX_OVERFLOW %0d, expected 2", v32));
      u_sink.ready_pct = 100;
      for (int k = 0; k < 4; k++) begin
        u_sink.get(got, 20000, ok);
        tb_check(ok && bytes_equal(got, ovf_q[k], why), $sformatf("overflow: stored frame %0d %s", k, why));
      end
      u_sink.expect_none(1000, ok);
      tb_check(ok, "overflow: only four frames stored");
      u_sink.ready_pct = 90;
      exp_rx_good += 4;
      exp_rx_ovf  += 2;
    end
    check_counters("after overflow");

    // ---- TX_EN = 0: frames consumed, not sent, s_axis_tx not blocked ----
    reg_wr(REG_CTRL, ctrl_word(spd_code, 1'b1, 1'b0, 1'b1));
    #2us;
    for (int k = 0; k < 6; k++) u_src.send(random_frame(200));
    tb_check(1'b1, "TX disabled: s_axis_tx accepted 6 frames (8 KiB queue, no block)");
    u_phy.get_tx_frame(got, ok, ok, ok, frame_timeout_ns * 2 + 20000, ok);
    tb_check(!ok, "TX disabled: nothing on the wire");
    reg_wr(REG_CTRL, ctrl_word(spd_code, 1'b1, 1'b1, 1'b1));
    tx_frames(1, 100, "TX re-enabled");
    #5us;
    check_counters("after TX disable");

    // ---- RX_EN = 0: receive path held in reset ----
    reg_wr(REG_CTRL, ctrl_word(spd_code, 1'b0, 1'b1, 1'b1));
    #2us;
    reg_rd(REG_STATUS, v32);
    tb_check(v32[2], $sformatf("RX disabled: STATUS 0x%08x RX in reset", v32));
    u_phy.inject(random_frame(70), 0);
    u_phy.wait_rx_idle(frame_timeout_ns, ok);
    u_sink.expect_none(1000, ok);
    tb_check(ok, "RX disabled: frame not admitted");
    mac_follow(spd_code, "RX re-enabled");
    rx_good_frames(1, 200, "RX re-enabled");

    // ---- A speed write that mismatches RXC resets the receive path ----
    reg_wr(REG_CTRL, ctrl_word(wrong, 1'b1, 1'b1, 1'b1));
    #2us;
    reg_rd(REG_STATUS, v32);
    tb_check(v32[2] && !v32[0], $sformatf("speed write: STATUS 0x%08x receive path reset at once", v32));
    mac_follow(spd_code, "speed restored");
    rx_good_frames(1, 200, "speed restored");
    check_counters("after RX enable / speed tests");

    // ---- Event pulses equal the counters, then CNT_CLEAR ----
    tb_check(ev_good_n == exp_rx_good, $sformatf("ev_rx_good pulses %0d, RX_GOOD %0d", ev_good_n, exp_rx_good));
    tb_check(ev_bad_n == exp_rx_bad + exp_rx_ovf, $sformatf("ev_rx_bad pulses %0d, RX_BAD + RX_OVERFLOW %0d", ev_bad_n,
             exp_rx_bad + exp_rx_ovf));
    tb_check(ev_tx_n == exp_tx, $sformatf("ev_tx_frame pulses %0d, TX_FRAMES %0d", ev_tx_n, exp_tx));
    reg_wr(REG_CTRL, ctrl_word(spd_code, 1'b1, 1'b1, 1'b1) | CTRL_CNT_CLEAR);
    reg_check(REG_CTRL, ctrl_word(spd_code, 1'b1, 1'b1, 1'b1), "CTRL after CNT_CLEAR (pulse reads 0)");
    exp_rx_good = 0;
    exp_rx_bad  = 0;
    exp_rx_ovf  = 0;
    exp_tx      = 0;
    check_counters("after CNT_CLEAR");
    rx_good_frames(1, 100, "after clear");
    tx_frames(1, 100, "after clear");
    #5us;
    check_counters("counting after CNT_CLEAR");

    // ---- PHY link resolution: advertisement (1000, 100) or forced speed (10) ----
    begin
      logic [1:0] low;
      logic [1:0] orig;
      orig = spd_code;
      if (spd_code == 2'b10) begin
        mdio_write(5'd9, 16'h0000);                      // stop advertising 1000BASE-T
        mdio_write(5'd0, 16'h1340);                      // restart auto-negotiation
        low = 2'b01;
      end else if (spd_code == 2'b01) begin
        mdio_write(5'd4, 16'h0061);                      // advertise 10 Mb/s only
        mdio_write(5'd0, 16'h1340);
        low = 2'b00;
      end else begin
        mdio_write(5'd0, 16'h0100);                      // auto-negotiation off, forced 10 Mb/s full duplex
        low = 2'b00;
      end
      mdio_rd_check(5'd0, 16'h0200, 16'h0000, "BMCR restart-AN bit self-clears");
      #80us;
      wait_phy_link(low, "advertisement / forced speed");
      if (orig == 2'b00) mdio_rd_check(5'd5, 16'hFFFF, 16'h0000, "ANLPAR with auto-negotiation off");
      mac_follow(low, "advertisement / forced speed");
      rx_good_frames(1, 100, "advertisement / forced speed");
      tx_frames(1, 100, "advertisement / forced speed");
      mdio_write(5'd9, 16'h0200);
      mdio_write(5'd4, 16'h05E1);
      mdio_write(5'd0, 16'h1340);
      #80us;
      wait_phy_link(orig, "defaults restored");
      mac_follow(orig, "defaults restored");
      rx_good_frames(1, 100, "defaults restored");
      #5us;
      check_counters("after link resolution tests");
    end

    // ---- Live speed walk (+WALK): PHY renegotiates, firmware follows ----
    if (walk) begin
      n_walk = 0;
      for (int c = 2; c >= 0; c--) if (2'(c) != spd_code) walk_codes[n_walk++] = 2'(c);
      walk_codes[n_walk++] = spd_code;
      for (int w = 0; w < n_walk; w++) begin
        $display("[%0t] tb_rtlnet_eth_mac: speed walk to code %0d", $time, walk_codes[w]);
        u_phy.set_partner_speed(walk_codes[w]);
        #80us;
        reg_rd(REG_STATUS, v32);
        tb_check(!v32[0] && v32[2], $sformatf("walk %0d: link drop resets the receive path (STATUS 0x%08x)", w, v32));
        wait_phy_link(walk_codes[w], $sformatf("walk %0d", w));
        mac_follow(walk_codes[w], $sformatf("walk %0d", w));
        check_running($sformatf("walk %0d", w));
        rx_good_frames(4, (walk_codes[w] == 2'b00) ? 200 : 600, $sformatf("walk %0d RX", w));
        tx_frames(4, (walk_codes[w] == 2'b00) ? 200 : 600, $sformatf("walk %0d TX", w));
        #5us;
        check_counters($sformatf("walk %0d", w));
      end
    end

    tb_check(phy_tx_viol == 0, $sformatf("PHY model TX setup/hold violations: %0d", phy_tx_viol));
    tb_verdict("tb_rtlnet_eth_mac");
  end

  initial begin
    #(WATCHDOG);
    tb_error("watchdog timeout");
    tb_verdict("tb_rtlnet_eth_mac");
  end

endmodule
