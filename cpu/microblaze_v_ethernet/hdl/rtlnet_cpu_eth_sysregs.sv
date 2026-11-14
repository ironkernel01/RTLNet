// -----------------------------------------------------------------------------
// File: rtlnet_cpu_eth_sysregs.sv
// Purpose: board-independent system registers of the Ethernet CPU core, window SYS (offset 0x0_0000) of the RTLNet
//   register window: board and build identity, the facts the firmware needs about the board (clock rate, link modes),
//   LEDs, switches, buttons, uptime, a millisecond tick, PHY side-band pin levels and the network status summary.
// Overview:
//   * AXI4-Lite slave through rtlnet_axil_slave (ADDR_W 12, full-word writes only); registered read mux, undefined
//     offsets read 0.
//   * Register map defined in cpu/microblaze_v_ethernet/driver/rtlnet_cpu_eth_sysregs.h (the single definition); the
//     REG_* localparams below mirror it. Change both in the same commit.
//   * The block names no board, pin or part. The board top sets the parameters: BOARD_ID (four ASCII characters,
//     for the banner), CPU_CLK_HZ (the clock rate of this block's clk), LINK_CAPS (bit 0 10 Mb/s full duplex, bit 1
//     100 Mb/s, bit 2 1000 Mb/s; half duplex is never offered) and the widths of the LED, switch and button vectors.
//     The firmware reads these registers and identifies the PHY by its MDIO ID registers, so it carries no board
//     specific source.
//   * Every asynchronous input (switches, buttons, clock lock, PHY pins, network status levels) enters through
//     rtlnet_sync. Only the final stage is read.
//   * UPTIME_MS counts milliseconds of clk (MS_CYCLES clocks each) from reset release; tick_ms is a one-clock pulse at
//     each millisecond.
//   * LEDS[NUM_LED-1:1] are firmware-owned register bits; led_fw bit 0 is 0 (the board top drives its first LED from
//     the clock lock, by the convention of the H.264 design) and LEDS[0] reads 0.
// Language: SystemVerilog-2012.
// Revision: 11-14-2026
//   * 11-14-2026: initial version.
// Clocks: clk only; resetn synchronous to clk, active low.
// -----------------------------------------------------------------------------
module rtlnet_cpu_eth_sysregs #(
  parameter logic [31:0] BUILD_ID    = 32'h0000_0000,  // git hash, set by the build script
  parameter logic        BUILD_DIRTY = 1'b0,           // tree had uncommitted changes
  parameter logic [31:0] BOARD_ID    = 32'h0000_0000,  // four ASCII characters naming the board, first character in [31:24]
  parameter int          CPU_CLK_HZ  = 100_000_000,    // frequency of clk
  parameter int          MS_CYCLES   = CPU_CLK_HZ / 1000,
  parameter logic [2:0]  LINK_CAPS   = 3'b111,         // [0] 10 Mb/s, [1] 100 Mb/s, [2] 1000 Mb/s, full duplex
  parameter int          NUM_LED     = 8,
  parameter int          NUM_SW      = 8,
  parameter int          NUM_BTN     = 5
)(
  // clk domain clock and its synchronous active-low reset.
  input  logic               clk,
  input  logic               resetn,

  // AXI4-Lite register slave, clk, 12-bit window offset, 32-bit data.
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

  // Board inputs, asynchronous levels: slide switches; buttons (1 = pressed);
  // clock lock (1 = all clocks locked).
  input  logic [NUM_SW-1:0]  sw_async,
  input  logic [NUM_BTN-1:0] btn_async,
  input  logic               clk_locked_async,

  // PHY side-band levels, asynchronous: {mdio pad input, phy_int_n} (the interrupt pin is active low).
  input  logic [1:0]         phy_async,

  // PHY reset level as driven to the PHY, clk domain (register output).
  input  logic               phy_rst_n,

  // Network status levels from the MAC and protocol domains, asynchronous:
  // {dhcp_bound, ip_valid, rx_clk_ok, speed[1:0], link_up}.
  input  logic [5:0]         net_status_async,

  // Firmware-owned LED bits, clk register outputs; bit 0 is always 0.
  output logic [NUM_LED-1:0] led_fw,

  // One-clock pulse every millisecond.
  output logic               tick_ms
);

  // Register offsets: mirror of rtlnet_cpu_eth_sysregs.h.
  localparam logic [11:0] REG_ID          = 12'h000;
  localparam logic [11:0] REG_VERSION     = 12'h004;
  localparam logic [11:0] REG_CAPS        = 12'h008;
  localparam logic [11:0] REG_BUILD_ID    = 12'h00C;
  localparam logic [11:0] REG_BUILD_DIRTY = 12'h010;
  localparam logic [11:0] REG_BOARD_ID    = 12'h014;
  localparam logic [11:0] REG_CPU_CLK_HZ  = 12'h018;
  localparam logic [11:0] REG_LINK_CAPS   = 12'h01C;
  localparam logic [11:0] REG_UPTIME_MS   = 12'h020;
  localparam logic [11:0] REG_LEDS        = 12'h024;
  localparam logic [11:0] REG_SWITCHES    = 12'h028;
  localparam logic [11:0] REG_BUTTONS     = 12'h02C;
  localparam logic [11:0] REG_SCRATCH     = 12'h030;
  localparam logic [11:0] REG_CLK_STATUS  = 12'h034;
  localparam logic [11:0] REG_PHY_STATUS  = 12'h038;
  localparam logic [11:0] REG_NET_STATUS  = 12'h03C;

  localparam logic [31:0] ID_VALUE        = 32'h4554_4853;   // "ETHS"
  localparam logic [31:0] VERSION_VALUE   = 32'h1114_2026;   // 11-14-2026
  localparam logic [31:0] CAPS_VALUE      = {8'(NUM_BTN), 8'(NUM_SW), 8'(NUM_LED), 8'd0};
  localparam int          MS_W            = $clog2(MS_CYCLES);

  // Register-file strobes from the AXI4-Lite bridge.
  logic        reg_wr_en;
  logic [11:0] reg_wr_addr;
  logic [31:0] reg_wr_data;
  logic        reg_rd_en;
  logic [11:0] reg_rd_addr;
  logic [31:0] reg_rd_data;

  // Synchronized inputs.
  logic [NUM_SW-1:0]  sw_q;
  logic [NUM_BTN-1:0] btn_q;
  logic               locked_q;
  logic [1:0]         phy_q;
  logic [5:0]         net_status_q;

  // Register state.
  logic [NUM_LED-1:1] leds;
  logic [31:0]        scratch;
  logic [MS_W-1:0]    ms_div;
  logic [31:0]        uptime_ms;

  generate
    if (MS_CYCLES < 2) begin : g_bad_ms
      $fatal(1, "rtlnet_cpu_eth_sysregs: MS_CYCLES=%0d, must be at least 2", MS_CYCLES);
    end
    if (NUM_LED < 2 || NUM_LED > 32 || NUM_SW > 32 || NUM_BTN > 32) begin : g_bad_width
      $fatal(1, "rtlnet_cpu_eth_sysregs: NUM_LED=%0d (2..32), NUM_SW=%0d, NUM_BTN=%0d (at most 32)", NUM_LED, NUM_SW, NUM_BTN);
    end
    if (LINK_CAPS == 3'b000) begin : g_bad_caps
      $fatal(1, "rtlnet_cpu_eth_sysregs: LINK_CAPS must name at least one mode");
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

  // Slide switch levels into clk.
  rtlnet_sync #(.WIDTH(NUM_SW), .STAGES(3)) u_sw_sync (
    .clk(clk), .resetn(resetn), .d(sw_async), .q(sw_q));

  // Push button levels into clk.
  rtlnet_sync #(.WIDTH(NUM_BTN), .STAGES(3)) u_btn_sync (
    .clk(clk), .resetn(resetn), .d(btn_async), .q(btn_q));

  // Clock lock into clk (status only; the reset tree uses the raw lock).
  rtlnet_sync #(.WIDTH(1), .STAGES(3)) u_lock_sync (
    .clk(clk), .resetn(resetn), .d(clk_locked_async), .q(locked_q));

  // PHY side-band pins into clk.
  rtlnet_sync #(.WIDTH(2), .STAGES(3)) u_phy_sync (
    .clk(clk), .resetn(resetn), .d(phy_async), .q(phy_q));

  // Network status levels from the MAC and protocol domains into clk.
  rtlnet_sync #(.WIDTH(6), .STAGES(3)) u_net_sync (
    .clk(clk), .resetn(resetn), .d(net_status_async), .q(net_status_q));

  assign led_fw = {leds, 1'b0};

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

  // Register writes: LEDS[NUM_LED-1:1] and SCRATCH; other offsets ignore writes.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      leds    <= '0;
      scratch <= '0;
    end else if (reg_wr_en) begin
      case (reg_wr_addr)
        REG_LEDS:    leds    <= reg_wr_data[NUM_LED-1:1];
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
        REG_BOARD_ID:    reg_rd_data <= BOARD_ID;
        REG_CPU_CLK_HZ:  reg_rd_data <= 32'(CPU_CLK_HZ);
        REG_LINK_CAPS:   reg_rd_data <= {29'd0, LINK_CAPS};
        REG_UPTIME_MS:   reg_rd_data <= uptime_ms;
        REG_LEDS:        reg_rd_data <= 32'(led_fw);
        REG_SWITCHES:    reg_rd_data <= 32'(sw_q);
        REG_BUTTONS:     reg_rd_data <= 32'(btn_q);
        REG_SCRATCH:     reg_rd_data <= scratch;
        REG_CLK_STATUS:  reg_rd_data <= {31'd0, locked_q};
        REG_PHY_STATUS:  reg_rd_data <= {29'd0, phy_q[1], phy_rst_n, phy_q[0]};
        REG_NET_STATUS:  reg_rd_data <= {26'd0, net_status_q};
        default:         reg_rd_data <= '0;
      endcase
    end
  end

endmodule
