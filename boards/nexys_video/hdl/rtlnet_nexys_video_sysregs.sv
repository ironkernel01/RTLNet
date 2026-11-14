// -----------------------------------------------------------------------------
// File: rtlnet_nexys_video_sysregs.sv
// Purpose: Nexys Video board system registers, window SYS (offset 0x0_0000)
//   of the RTLNet register window: board identity, build identity, LEDs,
//   switches, buttons, clock status and measurement, uptime, PHY side-band
//   pin levels and the network status summary.
// Overview:
//   * AXI4-Lite slave through rtlnet_axil_slave (ADDR_W 12, full-word writes
//     only); registered read mux, undefined offsets read 0.
//   * Register map defined in cpu/microblaze_v_h264/firmware/src/rtlnet_nexys_video_sysregs.h
//     (the single definition); the REG_* localparams below mirror it.
//   * Every asynchronous input (switches, buttons, MMCM lock, PHY pins, RGMII
//     receive pin levels, network status levels, clock beacons) enters through
//     rtlnet_sync. Only the final stage is read.
//   * UPTIME_MS counts milliseconds of cpu_clk (MS_CYCLES clocks each) from
//     reset release; tick_ms is a one-clock pulse at each millisecond.
//   * Clock monitor: each beacon is a divide-by-32 square wave of one clock;
//     both of its edges are counted over each 1 ms window, so
//     f(kHz) = CLK_MEAS[i] * 16 (with MS_CYCLES = CPU_CLK_HZ / 1000).
//   * CLK_STATUS bit 1 is the DDR3 controller's init_calib_complete (ui_clk domain,
//     asynchronous to cpu_clk), synchronized through rtlnet_sync like every other
//     asynchronous input; it reads 1 once the controller has calibrated.
//   * LEDS[7:1] are firmware-owned register bits; led[0] is driven by the
//     board top from the MMCM lock and LEDS[0] reads 0.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 10-22-2026: initial version.
//   * 11-09-2026: CLK_STATUS bit 1 = DDR3 calibration complete (input ddr_calib_async); VERSION 11-09-2026.
// Clocks: clk (cpu_clk 90 MHz) only; resetn synchronous to clk, active low.
// -----------------------------------------------------------------------------
module rtlnet_nexys_video_sysregs #(
  parameter logic [31:0] BUILD_ID    = 32'h0000_0000,  // git hash, set by the build script
  parameter logic        BUILD_DIRTY = 1'b0,           // tree had uncommitted changes
  parameter logic        NETWORK     = 1'b0,           // RTLNET_WITH_NETWORK build
  parameter int          CPU_CLK_HZ  = 90_000_000,
  parameter int          MS_CYCLES   = CPU_CLK_HZ / 1000,
  parameter int          NUM_CLK     = 5               // monitored clocks (beacons)
)(
  // cpu_clk domain clock and its synchronous active-low reset.
  input  logic               clk,
  input  logic               resetn,

  // AXI4-Lite register slave, cpu_clk, 12-bit window offset, 32-bit data.
  input  logic [11:0]        s_axi_awaddr,
  input  logic               s_axi_awvalid,
  output logic               s_axi_awready,
  input  logic [31:0]        s_axi_wdata,
  input  logic [3:0]         s_axi_wstrb,
  input  logic               s_axi_wvalid,
  output logic               s_axi_wready,
  output logic [1:0]         s_axi_bresp,
  output logic               s_axi_bvalid,
  input  logic               s_axi_bready,
  input  logic [11:0]        s_axi_araddr,
  input  logic               s_axi_arvalid,
  output logic               s_axi_arready,
  output logic [31:0]        s_axi_rdata,
  output logic [1:0]         s_axi_rresp,
  output logic               s_axi_rvalid,
  input  logic               s_axi_rready,

  // Board inputs, asynchronous levels: slide switches; buttons {u, r, l, d, c}
  // (1 = pressed); MMCM lock.
  input  logic [7:0]         sw_async,
  input  logic [4:0]         btn_async,
  input  logic               mmcm_locked_async,

  // DDR3 controller calibration complete, ui_clk domain level, asynchronous to clk.
  input  logic               ddr_calib_async,

  // PHY side-band levels, asynchronous: {mdio pad input, eth_pme_b, eth_int_b}
  // (PHY pins active low); RGMII receive pin levels {rxck, rxd[3:0], rxctl}.
  input  logic [2:0]         phy_async,
  input  logic [5:0]         rgmii_rx_async,

  // PHY reset level as driven to eth_rst_b, cpu_clk domain (register output).
  input  logic               phy_rst_n,

  // Network status levels from axis_clk / proto_clk, asynchronous:
  // {dhcp_bound, ip_valid, rx_clk_ok, speed[1:0], link_up}.
  input  logic [5:0]         net_status_async,

  // Clock beacons, one per monitored clock, asynchronous (index order of
  // NXV_CLK_IDX_* in the header: clk125, clk125_90, clk200, axis, proto).
  input  logic [NUM_CLK-1:0] clk_beacon_async,

  // Firmware-owned LED bits, cpu_clk register outputs; bit 0 is always 0.
  output logic [7:0]         led_fw,

  // One-clock pulse every millisecond (for the board top's PHY reset timer).
  output logic               tick_ms
);

  // Register offsets: mirror of rtlnet_nexys_video_sysregs.h.
  localparam logic [11:0] REG_ID          = 12'h000;
  localparam logic [11:0] REG_VERSION     = 12'h004;
  localparam logic [11:0] REG_CAPS        = 12'h008;
  localparam logic [11:0] REG_BUILD_ID    = 12'h00C;
  localparam logic [11:0] REG_BUILD_DIRTY = 12'h010;
  localparam logic [11:0] REG_LEDS        = 12'h014;
  localparam logic [11:0] REG_SWITCHES    = 12'h018;
  localparam logic [11:0] REG_BUTTONS     = 12'h01C;
  localparam logic [11:0] REG_CLK_STATUS  = 12'h020;
  localparam logic [11:0] REG_SCRATCH     = 12'h024;
  localparam logic [11:0] REG_UPTIME_MS   = 12'h028;
  localparam logic [11:0] REG_CPU_CLK_HZ  = 12'h02C;
  localparam logic [11:0] REG_PHY_STATUS  = 12'h030;
  localparam logic [11:0] REG_NET_STATUS  = 12'h034;
  localparam logic [11:0] REG_CLK_MEAS0   = 12'h040;

  localparam logic [31:0] ID_VALUE        = 32'h4E58_5644;   // "NXVD"
  localparam logic [31:0] VERSION_VALUE   = 32'h1109_2026;   // 11-09-2026
  localparam int          NUM_LEDS        = 8;
  localparam int          NUM_SW          = 8;
  localparam int          NUM_BTN         = 5;
  localparam logic [31:0] CAPS_VALUE      = {8'(NUM_BTN), 8'(NUM_SW), 8'(NUM_LEDS), 7'd0, NETWORK};
  localparam int          MEAS_W          = 20;              // >= 12500 edges per ms at 200 MHz
  localparam int          MS_W            = $clog2(MS_CYCLES);

  // Register-file strobes from the AXI4-Lite bridge.
  logic        reg_wr_en;
  logic [11:0] reg_wr_addr;
  logic [31:0] reg_wr_data;
  logic        reg_rd_en;
  logic [11:0] reg_rd_addr;
  logic [31:0] reg_rd_data;

  // Synchronized inputs.
  logic [7:0]         sw_q;
  logic [4:0]         btn_q;
  logic               locked_q;
  logic               calib_q;
  logic [2:0]         phy_q;
  logic [5:0]         rgmii_rx_q;
  logic [5:0]         net_status_q;
  logic [NUM_CLK-1:0] beacon_q;

  // Register state.
  logic [7:1]         leds;
  logic [31:0]        scratch;
  logic [MS_W-1:0]    ms_div;
  logic [31:0]        uptime_ms;
  logic [NUM_CLK-1:0] beacon_d;
  logic [NUM_CLK-1:0] beacon_edge;
  logic [NUM_CLK-1:0][MEAS_W-1:0] edge_count;
  logic [NUM_CLK-1:0][MEAS_W-1:0] clk_meas;
  logic [NUM_CLK-1:0] clk_alive;
  logic [31:0]        clk_meas_word;
  logic [2:0]         meas_index;

  generate
    if (MS_CYCLES < 2) begin : g_bad_ms
      $fatal(1, "rtlnet_nexys_video_sysregs: MS_CYCLES=%0d, must be at least 2", MS_CYCLES);
    end
    if (NUM_CLK > 8) begin : g_bad_clk
      $fatal(1, "rtlnet_nexys_video_sysregs: NUM_CLK=%0d, at most 8 measurement registers", NUM_CLK);
    end
  endgenerate

  // AXI4-Lite to register strobes (shared RTLNet bridge).
  rtlnet_axil_slave #(
    .ADDR_W (12)
  ) u_axil_slave (
    .s_axi_aclk    (clk),
    .s_axi_aresetn (resetn),
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
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data)
  );

  // Slide switch levels into cpu_clk.
  rtlnet_sync #(.WIDTH(8), .STAGES(3)) u_sw_sync (
    .clk(clk), .resetn(resetn), .d(sw_async), .q(sw_q));

  // Push button levels into cpu_clk.
  rtlnet_sync #(.WIDTH(5), .STAGES(3)) u_btn_sync (
    .clk(clk), .resetn(resetn), .d(btn_async), .q(btn_q));

  // MMCM lock into cpu_clk (status only; the reset tree uses the raw lock).
  rtlnet_sync #(.WIDTH(1), .STAGES(3)) u_lock_sync (
    .clk(clk), .resetn(resetn), .d(mmcm_locked_async), .q(locked_q));

  // DDR3 calibration-complete level into cpu_clk.
  rtlnet_sync #(.WIDTH(1), .STAGES(3)) u_calib_sync (
    .clk(clk), .resetn(resetn), .d(ddr_calib_async), .q(calib_q));

  // PHY side-band pins into cpu_clk.
  rtlnet_sync #(.WIDTH(3), .STAGES(3)) u_phy_sync (
    .clk(clk), .resetn(resetn), .d(phy_async), .q(phy_q));

  // RGMII receive pin levels into cpu_clk (observation only).
  rtlnet_sync #(.WIDTH(6), .STAGES(3)) u_rgmii_sync (
    .clk(clk), .resetn(resetn), .d(rgmii_rx_async), .q(rgmii_rx_q));

  // Network status levels from the MAC and protocol domains into cpu_clk.
  rtlnet_sync #(.WIDTH(6), .STAGES(3)) u_net_sync (
    .clk(clk), .resetn(resetn), .d(net_status_async), .q(net_status_q));

  // Clock beacons into cpu_clk.
  rtlnet_sync #(.WIDTH(NUM_CLK), .STAGES(3)) u_beacon_sync (
    .clk(clk), .resetn(resetn), .d(clk_beacon_async), .q(beacon_q));

  assign beacon_edge = beacon_q ^ beacon_d;
  assign led_fw      = {leds, 1'b0};
  assign meas_index  = reg_rd_addr[4:2];

  // Clock-alive flags: a clock whose last window counted no beacon edge is
  // stopped (or held in reset).
  always_comb begin
    for (int i = 0; i < NUM_CLK; i++) clk_alive[i] = (clk_meas[i] != '0);
  end

  // Measurement word for the CLK_MEAS register addressed by the read.
  always_comb begin
    clk_meas_word = '0;
    for (int i = 0; i < NUM_CLK; i++) begin
      if (meas_index == 3'(i)) clk_meas_word = 32'(clk_meas[i]);
    end
  end

  // Millisecond divider and uptime counter.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      ms_div    <= '0;
      tick_ms   <= 1'b0;
      uptime_ms <= '0;
    end else begin
      tick_ms <= 1'b0;
      if (ms_div == MS_W'(MS_CYCLES - 1)) begin
        ms_div    <= '0;
        tick_ms   <= 1'b1;
        uptime_ms <= uptime_ms + 1'b1;
      end else begin
        ms_div <= ms_div + 1'b1;
      end
    end
  end

  // Clock monitor: count beacon edges per millisecond window and publish the
  // count of the completed window.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      beacon_d   <= '0;
      edge_count <= '0;
      clk_meas   <= '0;
    end else begin
      beacon_d <= beacon_q;
      for (int i = 0; i < NUM_CLK; i++) begin
        if (tick_ms) begin
          clk_meas[i]   <= edge_count[i];
          edge_count[i] <= MEAS_W'(beacon_edge[i]);
        end else begin
          edge_count[i] <= edge_count[i] + MEAS_W'(beacon_edge[i]);
        end
      end
    end
  end

  // Register writes: LEDS[7:1] and SCRATCH; other offsets ignore writes.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      leds    <= '0;
      scratch <= '0;
    end else if (reg_wr_en) begin
      case (reg_wr_addr)
        REG_LEDS:    leds    <= reg_wr_data[7:1];
        REG_SCRATCH: scratch <= reg_wr_data;
        default:     ;
      endcase
    end
  end

  // Registered read mux, data due the clock after reg_rd_en.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:          reg_rd_data <= ID_VALUE;
        REG_VERSION:     reg_rd_data <= VERSION_VALUE;
        REG_CAPS:        reg_rd_data <= CAPS_VALUE;
        REG_BUILD_ID:    reg_rd_data <= BUILD_ID;
        REG_BUILD_DIRTY: reg_rd_data <= {31'd0, BUILD_DIRTY};
        REG_LEDS:        reg_rd_data <= {24'd0, led_fw};
        REG_SWITCHES:    reg_rd_data <= {24'd0, sw_q};
        REG_BUTTONS:     reg_rd_data <= {27'd0, btn_q};
        REG_CLK_STATUS:  reg_rd_data <= 32'({clk_alive, 6'd0, calib_q, locked_q});
        REG_SCRATCH:     reg_rd_data <= scratch;
        REG_UPTIME_MS:   reg_rd_data <= uptime_ms;
        REG_CPU_CLK_HZ:  reg_rd_data <= 32'(CPU_CLK_HZ);
        REG_PHY_STATUS:  reg_rd_data <= {22'd0, rgmii_rx_q, phy_q[2], phy_rst_n, phy_q[1:0]};
        REG_NET_STATUS:  reg_rd_data <= {26'd0, net_status_q};
        default: begin
          if (reg_rd_addr[11:5] == REG_CLK_MEAS0[11:5] && reg_rd_addr[1:0] == 2'b00 &&
              meas_index < 3'(NUM_CLK)) begin
            reg_rd_data <= clk_meas_word;
          end else begin
            reg_rd_data <= '0;
          end
        end
      endcase
    end
  end

endmodule
