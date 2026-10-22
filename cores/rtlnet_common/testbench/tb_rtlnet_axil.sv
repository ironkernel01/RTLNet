// -----------------------------------------------------------------------------
// File: tb_rtlnet_axil.sv
// Purpose: self-checking bench for the AXI4-Lite plumbing: rtlnet_axil_decoder
//   routing to three windows, rtlnet_axil_cdc into two unrelated clocks, and
//   rtlnet_axil_slave in front of a register file in each window.
// Cases:
//   1. Register write/read-back in every window (CPU clock 100 MHz; windows at
//      100 MHz direct, 50.3 MHz and 62.7 MHz through the CDC), 300 random
//      accesses checked against a bench model.
//   2. A partial write (wstrb != 4'hF) is answered OKAY and changes nothing.
//   3. An unmapped address is answered DECERR on both write and read.
//   4. Window boundaries: first and last word of each window hit the right
//      register file.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_axil;

  import rtlnet_tb_pkg::*;

  localparam int N = 3;
  localparam logic [N*32-1:0] BASES = {32'h0001_0000, 32'h0000_1000, 32'h0000_0000};
  localparam logic [N*32-1:0] SIZES = {32'h0001_0000, 32'h0000_1000, 32'h0000_1000};

  logic cpu_clk = 0;
  logic clk_b   = 0;
  logic clk_c   = 0;
  logic arstn   = 0;
  logic cpu_resetn, b_resetn, c_resetn;

  always #5.0   cpu_clk = ~cpu_clk;
  always #9.94  clk_b   = ~clk_b;
  always #7.97  clk_c   = ~clk_c;

  rtlnet_reset_sync u_r0 (.clk(cpu_clk), .arstn(arstn), .resetn(cpu_resetn));
  rtlnet_reset_sync u_r1 (.clk(clk_b),   .arstn(arstn), .resetn(b_resetn));
  rtlnet_reset_sync u_r2 (.clk(clk_c),   .arstn(arstn), .resetn(c_resetn));

  // Master
  logic [31:0] awaddr, araddr, wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;

  rtlnet_tb_axil_master #(.ADDR_W(32)) u_mst (
    .aclk(cpu_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  // Decoder outputs
  logic [N*32-1:0] m_awaddr, m_araddr, m_wdata, m_rdata;
  logic [N*4-1:0]  m_wstrb;
  logic [N*2-1:0]  m_bresp, m_rresp;
  logic [N-1:0]    m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [N-1:0]    m_arvalid, m_arready, m_rvalid, m_rready;

  rtlnet_axil_decoder #(.N(N), .ADDR_W(32), .SLAVE_BASE(BASES), .SLAVE_SIZE(SIZES)) u_dec (
    .aclk(cpu_clk), .aresetn(cpu_resetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
    .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .m_axi_awaddr(m_awaddr), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready), .m_axi_wdata(m_wdata),
    .m_axi_wstrb(m_wstrb), .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready), .m_axi_bresp(m_bresp),
    .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready), .m_axi_araddr(m_araddr), .m_axi_arvalid(m_arvalid),
    .m_axi_arready(m_arready), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rvalid(m_rvalid),
    .m_axi_rready(m_rready));

  // ---------------------------------------------------------------------------
  // One window: optional CDC, then rtlnet_axil_slave + a 64-word register file.
  // ---------------------------------------------------------------------------
  genvar gw;
  generate
    for (gw = 0; gw < N; gw++) begin : g_win
      localparam int AW = (gw == 2) ? 16 : 12;
      logic          wclk;
      logic          wresetn;
      logic [AW-1:0] awaddr_i, araddr_i;
      logic [31:0]   wdata_i, rdata_i;
      logic [3:0]    wstrb_i;
      logic [1:0]    bresp_i, rresp_i;
      logic          awvalid_i, awready_i, wvalid_i, wready_i, bvalid_i, bready_i;
      logic          arvalid_i, arready_i, rvalid_i, rready_i;

      if (gw == 0) begin : g_direct
        assign wclk = cpu_clk; assign wresetn = cpu_resetn;
        assign awaddr_i  = m_awaddr[gw*32 +: AW]; assign awvalid_i = m_awvalid[gw]; assign m_awready[gw] = awready_i;
        assign wdata_i   = m_wdata[gw*32 +: 32];  assign wstrb_i   = m_wstrb[gw*4 +: 4];
        assign wvalid_i  = m_wvalid[gw];          assign m_wready[gw]  = wready_i;
        assign m_bresp[gw*2 +: 2] = bresp_i;      assign m_bvalid[gw]  = bvalid_i; assign bready_i = m_bready[gw];
        assign araddr_i  = m_araddr[gw*32 +: AW]; assign arvalid_i = m_arvalid[gw]; assign m_arready[gw] = arready_i;
        assign m_rdata[gw*32 +: 32] = rdata_i;    assign m_rresp[gw*2 +: 2] = rresp_i;
        assign m_rvalid[gw] = rvalid_i;           assign rready_i = m_rready[gw];
      end else begin : g_cdc
        assign wclk    = (gw == 1) ? clk_b : clk_c;
        assign wresetn = (gw == 1) ? b_resetn : c_resetn;
        // CPU-clock AXI4-Lite into the window clock.
        rtlnet_axil_cdc #(.ADDR_W(AW)) u_cdc (
          .s_clk(cpu_clk), .s_resetn(cpu_resetn),
          .s_axi_awaddr(m_awaddr[gw*32 +: AW]), .s_axi_awvalid(m_awvalid[gw]), .s_axi_awready(m_awready[gw]),
          .s_axi_wdata(m_wdata[gw*32 +: 32]), .s_axi_wstrb(m_wstrb[gw*4 +: 4]), .s_axi_wvalid(m_wvalid[gw]),
          .s_axi_wready(m_wready[gw]), .s_axi_bresp(m_bresp[gw*2 +: 2]), .s_axi_bvalid(m_bvalid[gw]),
          .s_axi_bready(m_bready[gw]), .s_axi_araddr(m_araddr[gw*32 +: AW]), .s_axi_arvalid(m_arvalid[gw]),
          .s_axi_arready(m_arready[gw]), .s_axi_rdata(m_rdata[gw*32 +: 32]), .s_axi_rresp(m_rresp[gw*2 +: 2]),
          .s_axi_rvalid(m_rvalid[gw]), .s_axi_rready(m_rready[gw]),
          .m_clk(wclk), .m_resetn(wresetn),
          .m_axi_awaddr(awaddr_i), .m_axi_awvalid(awvalid_i), .m_axi_awready(awready_i),
          .m_axi_wdata(wdata_i), .m_axi_wstrb(wstrb_i), .m_axi_wvalid(wvalid_i), .m_axi_wready(wready_i),
          .m_axi_bresp(bresp_i), .m_axi_bvalid(bvalid_i), .m_axi_bready(bready_i),
          .m_axi_araddr(araddr_i), .m_axi_arvalid(arvalid_i), .m_axi_arready(arready_i),
          .m_axi_rdata(rdata_i), .m_axi_rresp(rresp_i), .m_axi_rvalid(rvalid_i), .m_axi_rready(rready_i));
      end

      logic          reg_wr_en, reg_rd_en;
      logic [AW-1:0] reg_wr_addr, reg_rd_addr;
      logic [31:0]   reg_wr_data, reg_rd_data;
      logic [31:0]   regs [0:63];

      rtlnet_axil_slave #(.ADDR_W(AW)) u_slave (
        .s_axi_aclk(wclk), .s_axi_aresetn(wresetn),
        .s_axi_awaddr(awaddr_i), .s_axi_awvalid(awvalid_i), .s_axi_awready(awready_i), .s_axi_wdata(wdata_i),
        .s_axi_wstrb(wstrb_i), .s_axi_wvalid(wvalid_i), .s_axi_wready(wready_i), .s_axi_bresp(bresp_i),
        .s_axi_bvalid(bvalid_i), .s_axi_bready(bready_i), .s_axi_araddr(araddr_i), .s_axi_arvalid(arvalid_i),
        .s_axi_arready(arready_i), .s_axi_rdata(rdata_i), .s_axi_rresp(rresp_i), .s_axi_rvalid(rvalid_i),
        .s_axi_rready(rready_i),
        .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
        .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data));

      // Register file: 64 words at offsets 0..0xFC plus the top word of the
      // window aliased onto word 63 (boundary case).
      function automatic int widx(input logic [AW-1:0] a);
        return (a[AW-1:2] == {(AW-2){1'b1}}) ? 63 : int'(a[7:2]) % 63;
      endfunction
      initial for (int i = 0; i < 64; i++) regs[i] = 32'h0;
      always @(posedge wclk) begin
        if (reg_wr_en) regs[widx(reg_wr_addr)] <= reg_wr_data ^ (32'h1111_0000 * (gw + 1));
        if (reg_rd_en) reg_rd_data <= regs[widx(reg_rd_addr)];
      end
    end
  endgenerate

  // Bench model of all three register files.
  logic [31:0] model [0:N-1][0:63];

  function automatic int win_of(input logic [31:0] a);
    for (int i = 0; i < N; i++)
      if ((a & ~(SIZES[i*32 +: 32] - 1)) == BASES[i*32 +: 32]) return i;
    return -1;
  endfunction

  function automatic int idx_of(input int w, input logic [31:0] a);
    int aw;
    aw = (w == 2) ? 16 : 12;
    if (((a & ((1 << aw) - 1)) >> 2) == ((1 << (aw - 2)) - 1)) return 63;
    return ((a >> 2) & 63) % 63;
  endfunction

  initial begin : main
    logic [31:0] a, d, r;
    logic [1:0]  resp;
    int          w;
    int unsigned rng;

    rng = 99;
    for (int i = 0; i < N; i++) for (int j = 0; j < 64; j++) model[i][j] = 0;
    #100 arstn = 1'b1;
    repeat (20) @(posedge cpu_clk);

    // Case 1: random accesses in all windows.
    for (int k = 0; k < 300; k++) begin
      rng = rng * 1664525 + 1013904223;
      w = (rng >> 24) % N;
      a = BASES[w*32 +: 32] + (((rng >> 4) & 63) << 2);
      if ((rng >> 12) & 1) begin
        rng = rng * 1664525 + 1013904223;
        d = rng;
        u_mst.wr(a, d);
        model[w][idx_of(w, a)] = d ^ (32'h1111_0000 * (w + 1));
      end else begin
        u_mst.rd(a, r);
        tb_check(r == model[w][idx_of(w, a)],
                 $sformatf("read 0x%08x = 0x%08x, expected 0x%08x", a, r, model[w][idx_of(w, a)]));
      end
    end

    // Case 2: a partial write changes nothing.
    for (w = 0; w < N; w++) begin
      a = BASES[w*32 +: 32] + 32'h10;
      u_mst.write32(a, 32'hDEAD_BEEF, 4'h3, resp);
      tb_check(resp == 2'b00, $sformatf("partial write window %0d response %0d", w, resp));
      u_mst.rd(a, r);
      tb_check(r == model[w][idx_of(w, a)], $sformatf("partial write changed window %0d", w));
    end

    // Case 3: unmapped address.
    u_mst.write32(32'h0000_8000, 32'h1, 4'hF, resp);
    tb_check(resp == 2'b11, $sformatf("unmapped write response %0d, expected DECERR", resp));
    u_mst.read32(32'h0004_0000, r, resp);
    tb_check(resp == 2'b11 && r == 0, $sformatf("unmapped read response %0d data 0x%08x", resp, r));

    // Case 4: window boundaries.
    for (w = 0; w < N; w++) begin
      a = BASES[w*32 +: 32];
      u_mst.wr(a, 32'h0A0A_0000 + w);
      model[w][idx_of(w, a)] = (32'h0A0A_0000 + w) ^ (32'h1111_0000 * (w + 1));
      a = BASES[w*32 +: 32] + SIZES[w*32 +: 32] - 4;
      u_mst.wr(a, 32'h0B0B_0000 + w);
      model[w][63] = (32'h0B0B_0000 + w) ^ (32'h1111_0000 * (w + 1));
    end
    for (w = 0; w < N; w++) begin
      u_mst.rd(BASES[w*32 +: 32], r);
      tb_check(r == model[w][0], $sformatf("window %0d first word 0x%08x", w, r));
      u_mst.rd(BASES[w*32 +: 32] + SIZES[w*32 +: 32] - 4, r);
      tb_check(r == model[w][63], $sformatf("window %0d last word 0x%08x", w, r));
    end

    tb_verdict("tb_rtlnet_axil");
  end

  initial begin
    #20ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_rtlnet_axil");
  end

endmodule
