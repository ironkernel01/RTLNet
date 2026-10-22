// -----------------------------------------------------------------------------
// File: tb_rtlnet_mdio.sv
// Purpose: self-checking bench for rtlnet_mdio, the MDIO/PHY-management GPIO
//   core, against a Clause 22 slave model (rtlnet_tb_mdio_slave).
// Cases:
//   1. Reset state: mdc low, line released, phy_rst_n low, irq low.
//   2. Register header: ID "MDIO", VERSION 0x10222026, CAPS = POR_RESET_MS
//      and CLK_HZ / 1000.
//   3. Power-on PHY reset: phy_rst_n low for CLK_HZ/1000*POR_RESET_MS (+1)
//      clocks after resetn, STATUS.POR_DONE / PHY_RESET_ACTIVE before and
//      after.
//   4. CTRL: every MDC/OE/OUT combination reaches the pins and reads back;
//      PHY_RESET drives phy_rst_n; BITBANG changes only the pin bits; partial
//      writes, writes to read-only and undefined offsets change nothing;
//      undefined offsets read 0.
//   5. MDIO input: 3-clock synchronizer latency on asynchronous edges, STATUS
//      bit 0 and BITBANG bit 0 follow the pin.
//   6. PHY interrupt: STATUS bit 1, irq gated by IRQ_EN, registered latency.
//   7. Clause 22 frames bit-banged through BITBANG against the slave model:
//      PHYID1/PHYID2 reads, a write and read-back, a read of an absent PHY
//      (TA bit 2 high, data 0xFFFF); MDIO never changes while MDC is high or
//      on the rising edge; no line contention.
//   8. Warm reset: CTRL clears, the POR timer runs again.
//   Define TB_ALT_CLOCK for a 50 MHz clock and POR_RESET_MS 2.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_mdio;

  import rtlnet_tb_pkg::*;

`ifdef TB_ALT_CLOCK
  localparam int  CLK_HZ     = 50_000_000;
  localparam int  POR_MS     = 2;
  localparam real CLK_HALF   = 10.0;
`else
  localparam int  CLK_HZ     = 100_000_000;
  localparam int  POR_MS     = 1;
  localparam real CLK_HALF   = 5.0;
`endif
  localparam int  POR_CYCLES = (CLK_HZ / 1000) * POR_MS;
  localparam int  HALF_CLKS  = 25;            // extra clocks per MDC half period

  localparam logic [11:0] A_ID      = 12'h000;
  localparam logic [11:0] A_VERSION = 12'h004;
  localparam logic [11:0] A_CAPS    = 12'h008;
  localparam logic [11:0] A_CTRL    = 12'h00C;
  localparam logic [11:0] A_STATUS  = 12'h010;
  localparam logic [11:0] A_BITBANG = 12'h014;

  localparam logic [31:0] C_MDC   = 32'h001;
  localparam logic [31:0] C_OE    = 32'h002;
  localparam logic [31:0] C_OUT   = 32'h004;
  localparam logic [31:0] C_RST   = 32'h100;
  localparam logic [31:0] C_IRQEN = 32'h200;

  localparam logic [31:0] S_MDIO_IN = 32'h1;
  localparam logic [31:0] S_PHY_INT = 32'h2;
  localparam logic [31:0] S_POR     = 32'h4;
  localparam logic [31:0] S_RSTACT  = 32'h8;

  logic clk    = 1'b0;
  logic resetn = 1'b0;
  always #(CLK_HALF) clk = ~clk;

  // AXI4-Lite master
  logic [11:0] awaddr;
  logic [11:0] araddr;
  logic [31:0] wdata;
  logic [31:0] rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp;
  logic [1:0]  rresp;
  logic        awvalid;
  logic        awready;
  logic        wvalid;
  logic        wready;
  logic        bvalid;
  logic        bready;
  logic        arvalid;
  logic        arready;
  logic        rvalid;
  logic        rready;

  rtlnet_tb_axil_master #(.ADDR_W(12)) u_mst (
    .aclk(clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  // DUT pins
  logic mdc;
  logic mdio_o;
  logic mdio_t;
  logic mdio_i;
  logic phy_rst_n;
  logic phy_int_n = 1'b1;
  logic irq;

  rtlnet_mdio #(.CLK_HZ(CLK_HZ), .POR_RESET_MS(POR_MS)) u_dut (
    .clk(clk), .resetn(resetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .mdc(mdc), .mdio_o(mdio_o), .mdio_t(mdio_t), .mdio_i(mdio_i),
    .phy_rst_n(phy_rst_n), .phy_int_n(phy_int_n), .irq(irq));

  // ---------------------------------------------------------------------------
  // Board model: the MDIO line with its pull-up, the slave, and a bench
  // override of the pin for the synchronizer case.
  // ---------------------------------------------------------------------------
  logic slv_en;
  logic slv_val;
  logic mdio_line;
  logic force_en  = 1'b0;
  logic force_val = 1'b1;
  int   contention = 0;

  rtlnet_tb_mdio_slave #(.PHY_ADDR(5'd1), .T_VALID_NS(100)) u_slave (
    .mdc(mdc), .mdio(mdio_line), .drive_en(slv_en), .drive_val(slv_val));

  always_comb begin
    if (!mdio_t && slv_en)  mdio_line = 1'bx;
    else if (!mdio_t)       mdio_line = mdio_o;
    else if (slv_en)        mdio_line = slv_val;
    else                    mdio_line = 1'b1;
  end
  assign mdio_i = force_en ? force_val : mdio_line;

  always @(posedge clk) if (!mdio_t && slv_en) contention++;

  // Setup/hold monitor, enabled for the frame case: the driven MDIO level may
  // change only while MDC is low and never on the clock that raises MDC.
  logic mon_en      = 1'b0;
  logic prev_mdc    = 1'b0;
  logic prev_mdio_o = 1'b0;
  logic prev_mdio_t = 1'b1;
  int   sh_violations = 0;
  always @(posedge clk) begin
    if (mon_en && (mdio_o !== prev_mdio_o || mdio_t !== prev_mdio_t) && mdc && (!mdio_t || !prev_mdio_t)) begin
      sh_violations++;
      $display("SETUP/HOLD @%0t: MDIO changed with MDC high (o %b->%b, t %b->%b, mdc %b->%b)",
               $time, prev_mdio_o, mdio_o, prev_mdio_t, mdio_t, prev_mdc, mdc);
    end
    prev_mdc    <= mdc;
    prev_mdio_o <= mdio_o;
    prev_mdio_t <= mdio_t;
  end

  // POR measurement: clocks with resetn high and phy_rst_n low, and a count
  // of clocks on which phy_rst_n is high although resetn has been low since
  // the previous clock (the synchronous reset acts on the first such edge).
  int   por_low_cycles = 0;
  int   rst_glitch     = 0;
  logic prev_resetn    = 1'b0;
  always @(posedge clk) begin
    if (!resetn) begin
      por_low_cycles <= 0;
      if (phy_rst_n && !prev_resetn) rst_glitch++;
    end else if (!phy_rst_n) begin
      por_low_cycles <= por_low_cycles + 1;
    end
    prev_resetn <= resetn;
  end

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  task automatic rd_check(input logic [11:0] a, input logic [31:0] exp, input string what);
    logic [31:0] d;
    u_mst.rd(a, d);
    tb_check(d === exp, $sformatf("%s: read 0x%03x = 0x%08x, expected 0x%08x", what, a, d, exp));
  endtask

  task automatic wait_clks(input int n);
    repeat (n) @(posedge clk);
  endtask

  // Observed signals for latency measurements.
  localparam int P_MDIO_IN = 0;   // u_dut.mdio_in, last synchronizer stage
  localparam int P_PHY_INT = 1;   // u_dut.phy_int_n_s, last synchronizer stage
  localparam int P_IRQ     = 2;   // irq pin

  function automatic logic probe(input int sel);
    case (sel)
      P_MDIO_IN: return u_dut.mdio_in;
      P_PHY_INT: return u_dut.phy_int_n_s;
      default:   return irq;
    endcase
  endfunction

  // Count clock edges until the probed signal reaches val (bounded); returns
  // -1 on timeout.
  task automatic edges_until(input int sel, input logic val, input int max, output int n);
    n = 0;
    while (probe(sel) !== val && n < max) begin
      @(posedge clk);
      #0.1;
      n++;
    end
    if (probe(sel) !== val) n = -1;
  endtask

  // Bit-bang primitives: one BITBANG store per MDC half period.
  task automatic bb(input logic mdc_v, input logic oe, input logic out);
    u_mst.wr(A_BITBANG, {29'd0, out, oe, mdc_v});
  endtask

  task automatic out_bit(input logic b);
    bb(1'b0, 1'b1, b);
    wait_clks(HALF_CLKS);
    bb(1'b1, 1'b1, b);
    wait_clks(HALF_CLKS);
  endtask

  task automatic in_bit(output logic b);
    logic [31:0] d;
    bb(1'b0, 1'b0, 1'b0);
    wait_clks(HALF_CLKS);
    u_mst.rd(A_BITBANG, d);
    b = d[0];
    bb(1'b1, 1'b0, 1'b0);
    wait_clks(HALF_CLKS);
  endtask

  task automatic idle_slot();
    bb(1'b0, 1'b0, 1'b0);
    wait_clks(2 * HALF_CLKS);
  endtask

  task automatic c22_header(input logic [1:0] op, input logic [4:0] phyad, input logic [4:0] regad);
    for (int i = 0; i < 32; i++) out_bit(1'b1);
    out_bit(1'b0);
    out_bit(1'b1);
    out_bit(op[1]);
    out_bit(op[0]);
    for (int i = 4; i >= 0; i--) out_bit(phyad[i]);
    for (int i = 4; i >= 0; i--) out_bit(regad[i]);
  endtask

  task automatic c22_read(input logic [4:0] phyad, input logic [4:0] regad, output logic [15:0] data,
                          output logic ta_ok);
    logic b;
    logic ta2;
    c22_header(2'b10, phyad, regad);
    in_bit(b);
    in_bit(ta2);
    ta_ok = (ta2 === 1'b0);
    data  = '0;
    for (int i = 15; i >= 0; i--) begin
      in_bit(b);
      data[i] = b;
    end
    idle_slot();
  endtask

  task automatic c22_write(input logic [4:0] phyad, input logic [4:0] regad, input logic [15:0] data);
    c22_header(2'b01, phyad, regad);
    out_bit(1'b1);
    out_bit(1'b0);
    for (int i = 15; i >= 0; i--) out_bit(data[i]);
    idle_slot();
  endtask

  // ---------------------------------------------------------------------------
  // Watchdog
  // ---------------------------------------------------------------------------
  initial begin
    #(50_000_000);
    tb_error("watchdog: bench did not finish in 50 ms");
    tb_verdict("tb_rtlnet_mdio");
  end

  // ---------------------------------------------------------------------------
  // Main sequence
  // ---------------------------------------------------------------------------
  initial begin : main
    logic [31:0] d;
    logic [31:0] v;
    logic [15:0] r16;
    logic        ta_ok;
    logic [1:0]  resp;
    int          n;
    int          s_rd;
    int          s_wr;
    int          s_ign;
    int          s_err;
    int          s_con;
    int          s_shv;
    int unsigned rng;
    logic        lvl;

    rng = 32'h1234_5678;

    // Case 1: reset state.
    wait_clks(10);
    tb_check(mdc === 1'b0,       "reset: mdc low");
    tb_check(mdio_t === 1'b1,    "reset: mdio released");
    tb_check(phy_rst_n === 1'b0, "reset: phy_rst_n low");
    tb_check(irq === 1'b0,       "reset: irq low");
    @(posedge clk) resetn <= 1'b1;

    // Case 2: register header (inside the POR window).
    rd_check(A_ID,      32'h4D44494F, "ID");
    rd_check(A_VERSION, 32'h10222026, "VERSION");
    rd_check(A_CAPS,    {8'(POR_MS), 24'(CLK_HZ / 1000)}, "CAPS");

    // Case 3: POR in progress.
    rd_check(A_STATUS, S_MDIO_IN | S_RSTACT, "STATUS during POR");
    rd_check(A_CTRL,   32'h0, "CTRL reset value");
    tb_check(phy_rst_n === 1'b0, "POR: phy_rst_n low early in the window");
    wait (phy_rst_n === 1'b1);
    @(posedge clk);
    tb_check(por_low_cycles >= POR_CYCLES && por_low_cycles <= POR_CYCLES + 2,
             $sformatf("POR: phy_rst_n low %0d clocks after resetn, expected %0d..%0d",
                       por_low_cycles, POR_CYCLES, POR_CYCLES + 2));
    tb_check(rst_glitch == 0, "POR: phy_rst_n high while resetn low");
    rd_check(A_STATUS, S_MDIO_IN | S_POR, "STATUS after POR");
    wait_clks(100);
    tb_check(phy_rst_n === 1'b1, "POR: phy_rst_n stays high");

    // Case 4: CTRL pin combinations.
    for (int k = 0; k < 8; k++) begin
      v = 32'(k);
      u_mst.wr(A_CTRL, v);
      wait_clks(1);
      tb_check(mdc === v[0],     $sformatf("CTRL %0d: mdc", k));
      tb_check(mdio_t === !v[1], $sformatf("CTRL %0d: mdio_t", k));
      tb_check(mdio_o === v[2],  $sformatf("CTRL %0d: mdio_o", k));
      rd_check(A_CTRL, v, $sformatf("CTRL %0d readback", k));
    end
    u_mst.wr(A_CTRL, 32'h0);

    // PHY_RESET drives the pin and STATUS.
    u_mst.wr(A_CTRL, C_RST);
    wait_clks(2);
    tb_check(phy_rst_n === 1'b0, "CTRL.PHY_RESET: phy_rst_n low");
    rd_check(A_STATUS, S_MDIO_IN | S_POR | S_RSTACT, "STATUS with PHY_RESET");
    u_mst.wr(A_CTRL, 32'h0);
    wait_clks(2);
    tb_check(phy_rst_n === 1'b1, "CTRL.PHY_RESET clear: phy_rst_n high");

    // BITBANG changes only the pin bits.
    u_mst.wr(A_CTRL, C_RST | C_IRQEN | C_MDC);
    u_mst.wr(A_BITBANG, 32'hFFFF_FFF6);    // OUT=1, OE=1, MDC=0; upper bits must be ignored
    rd_check(A_CTRL, C_RST | C_IRQEN | C_OE | C_OUT, "BITBANG keeps PHY_RESET/IRQ_EN");
    tb_check(mdc === 1'b0 && mdio_t === 1'b0 && mdio_o === 1'b1, "BITBANG pins");
    tb_check(phy_rst_n === 1'b0, "BITBANG keeps phy_rst_n low");
    u_mst.wr(A_CTRL, 32'h0);

    // Partial write, read-only and undefined offsets.
    u_mst.write32(A_CTRL, C_MDC | C_OE, 4'h1, resp);
    tb_check(resp == 2'b00, "partial write answered OKAY");
    rd_check(A_CTRL, 32'h0, "partial write ignored");
    u_mst.wr(A_ID, 32'h0);
    u_mst.wr(A_VERSION, 32'h0);
    u_mst.wr(A_CAPS, 32'h0);
    u_mst.wr(A_STATUS, 32'hFFFF_FFFF);
    u_mst.wr(12'h018, 32'hFFFF_FFFF);
    u_mst.wr(12'hFFC, 32'hFFFF_FFFF);
    rd_check(A_ID,      32'h4D44494F, "ID after write");
    rd_check(A_VERSION, 32'h10222026, "VERSION after write");
    rd_check(A_CAPS,    {8'(POR_MS), 24'(CLK_HZ / 1000)}, "CAPS after write");
    rd_check(A_CTRL,    32'h0, "CTRL unchanged by other writes");
    tb_check(mdc === 1'b0 && mdio_t === 1'b1 && phy_rst_n === 1'b1 && irq === 1'b0,
             "pins unchanged by writes to other offsets");
    rd_check(12'h018, 32'h0, "undefined 0x018 reads 0");
    rd_check(12'h100, 32'h0, "undefined 0x100 reads 0");
    rd_check(12'hFFC, 32'h0, "undefined 0xFFC reads 0");
    rd_check(12'h00E, 32'h0, "misaligned 0x00E reads 0");

    // Case 5: MDIO input synchronizer.
    force_en = 1'b1;
    for (int k = 0; k < 20; k++) begin
      rng = rng * 1664525 + 1013904223;
      lvl = !force_val;
      @(posedge clk);
      #(1.0 + (rng % 8));                       // asynchronous to clk
      force_val = lvl;
      edges_until(P_MDIO_IN, lvl, 10, n);
      tb_check(n == 3, $sformatf("MDIO_IN synchronizer latency %0d clocks, expected 3", n));
      rd_check(A_STATUS,  {31'd0, lvl} | S_POR, $sformatf("STATUS.MDIO_IN follows pin (%0d)", k));
      rd_check(A_BITBANG, {31'd0, lvl}, $sformatf("BITBANG reads MDIO_IN (%0d)", k));
    end
    force_val = 1'b1;
    wait_clks(5);
    force_en = 1'b0;

    // Case 6: PHY interrupt and irq gating.
    @(posedge clk);
    #3.3;
    phy_int_n = 1'b0;
    edges_until(P_PHY_INT, 1'b0, 10, n);
    tb_check(n == 3, $sformatf("PHY_INT synchronizer latency %0d, expected 3", n));
    rd_check(A_STATUS, S_MDIO_IN | S_POR | S_PHY_INT, "STATUS.PHY_INT set");
    wait_clks(20);
    tb_check(irq === 1'b0, "irq stays low with IRQ_EN 0");
    u_mst.wr(A_CTRL, C_IRQEN);
    edges_until(P_IRQ, 1'b1, 10, n);
    tb_check(n >= 0 && n <= 2, $sformatf("irq rises %0d clocks after IRQ_EN", n));
    @(posedge clk);
    #3.3;
    phy_int_n = 1'b1;
    edges_until(P_IRQ, 1'b0, 10, n);
    tb_check(n == 4, $sformatf("irq falls %0d clocks after phy_int_n release, expected 4", n));
    rd_check(A_STATUS, S_MDIO_IN | S_POR, "STATUS.PHY_INT clear");
    @(posedge clk);
    #3.3;
    phy_int_n = 1'b0;
    edges_until(P_IRQ, 1'b1, 10, n);
    tb_check(n == 4, $sformatf("irq rises %0d clocks after phy_int_n assert, expected 4", n));
    u_mst.wr(A_CTRL, 32'h0);
    edges_until(P_IRQ, 1'b0, 10, n);
    tb_check(n >= 0 && n <= 2, "irq falls when IRQ_EN clears");
    wait_clks(20);
    tb_check(irq === 1'b0, "irq low with interrupt asserted and IRQ_EN 0");
    phy_int_n = 1'b1;

    // Case 7: Clause 22 frames through BITBANG. The CTRL case above clocked
    // the slave with arbitrary levels (it reports one short preamble there),
    // so its counters are taken as deltas.
    mon_en = 1'b1;
    s_rd  = u_slave.frames_read;
    s_wr  = u_slave.frames_write;
    s_ign = u_slave.frames_ignored;
    s_err = u_slave.frame_errors;
    s_con = contention;
    s_shv = sh_violations;
    c22_read(5'd1, 5'd2, r16, ta_ok);
    tb_check(ta_ok, "read PHYID1: TA bit 2 low");
    tb_check(r16 === 16'h001C, $sformatf("read PHYID1 = 0x%04x, expected 0x001C", r16));
    c22_read(5'd1, 5'd3, r16, ta_ok);
    tb_check(ta_ok, "read PHYID2: TA bit 2 low");
    tb_check(r16 === 16'hC915, $sformatf("read PHYID2 = 0x%04x, expected 0xC915", r16));
    c22_write(5'd1, 5'd4, 16'h01A5);
    tb_check(u_slave.regs[4] === 16'h01A5, $sformatf("write ANAR: slave holds 0x%04x", u_slave.regs[4]));
    c22_read(5'd1, 5'd4, r16, ta_ok);
    tb_check(ta_ok && r16 === 16'h01A5, $sformatf("read back ANAR = 0x%04x", r16));
    c22_write(5'd1, 5'd31, 16'h5AC3);
    c22_read(5'd1, 5'd31, r16, ta_ok);
    tb_check(ta_ok && r16 === 16'h5AC3, $sformatf("read back reg 31 = 0x%04x", r16));
    c22_read(5'd5, 5'd2, r16, ta_ok);
    tb_check(!ta_ok, "read of absent PHY 5: TA bit 2 high (no PHY)");
    tb_check(r16 === 16'hFFFF, $sformatf("read of absent PHY 5 = 0x%04x, expected 0xFFFF", r16));
    c22_read(5'd1, 5'd0, r16, ta_ok);
    tb_check(ta_ok && r16 === 16'h1140, $sformatf("read BMCR after absent-PHY frame = 0x%04x", r16));
    tb_check(u_slave.frames_read - s_rd == 5,
             $sformatf("slave saw %0d reads, expected 5", u_slave.frames_read - s_rd));
    tb_check(u_slave.frames_write - s_wr == 2,
             $sformatf("slave saw %0d writes, expected 2", u_slave.frames_write - s_wr));
    tb_check(u_slave.frames_ignored - s_ign == 1,
             $sformatf("slave ignored %0d frames, expected 1", u_slave.frames_ignored - s_ign));
    tb_check(u_slave.frame_errors - s_err == 0,
             $sformatf("slave frame errors %0d", u_slave.frame_errors - s_err));
    tb_check(contention - s_con == 0, $sformatf("MDIO contention on %0d clocks", contention - s_con));
    tb_check(sh_violations - s_shv == 0, $sformatf("%0d MDIO setup/hold violations", sh_violations - s_shv));
    tb_check(mdc === 1'b0 && mdio_t === 1'b1, "bus idle after frames");
    mon_en = 1'b0;

    // Case 8: warm reset clears CTRL and restarts the POR timer.
    u_mst.wr(A_CTRL, C_IRQEN | C_OE | C_MDC);
    @(posedge clk) resetn <= 1'b0;
    wait_clks(5);
    tb_check(phy_rst_n === 1'b0 && mdc === 1'b0 && mdio_t === 1'b1, "warm reset: pins to reset state");
    @(posedge clk) resetn <= 1'b1;
    rd_check(A_CTRL, 32'h0, "warm reset: CTRL cleared");
    rd_check(A_STATUS, S_MDIO_IN | S_RSTACT, "warm reset: POR running");
    wait (phy_rst_n === 1'b1);
    @(posedge clk);
    tb_check(por_low_cycles >= POR_CYCLES && por_low_cycles <= POR_CYCLES + 2,
             $sformatf("warm reset: phy_rst_n low %0d clocks, expected %0d..%0d",
                       por_low_cycles, POR_CYCLES, POR_CYCLES + 2));
    tb_check(rst_glitch == 0, "warm reset: phy_rst_n high while resetn low");

    tb_verdict("tb_rtlnet_mdio");
  end

endmodule
