// -----------------------------------------------------------------------------
// File: rtlnet_mdio.sv
// Purpose: PHY management GPIO core. Firmware (cores/rtlnet_mdio/driver/
//   rtlnet_mdio.c) is the IEEE 802.3 Clause 22 MDIO master and bit-bangs MDC
//   and MDIO through these registers; the core also owns the PHY reset output
//   and the PHY interrupt input.
// Overview:
//   * Registers (AXI4-Lite through rtlnet_axil_slave, 12-bit address; offsets
//     and bits are defined in cores/rtlnet_mdio/driver/rtlnet_mdio.h):
//       0x000 ID       "MDIO"
//       0x004 VERSION  0x10222026
//       0x008 CAPS     [23:0] CLK_HZ / 1000, [31:24] POR_RESET_MS
//       0x00C CTRL     RW [0] MDC, [1] MDIO_OE (1 = drive), [2] MDIO_OUT,
//                         [8] PHY_RESET (1 = hold phy_rst_n low), [9] IRQ_EN
//       0x010 STATUS   RO [0] MDIO_IN, [1] PHY_INT (phy_int_n low),
//                         [2] POR_DONE, [3] PHY_RESET_ACTIVE (phy_rst_n low)
//       0x014 BITBANG  W  [2:0] as CTRL[2:0], PHY_RESET and IRQ_EN unchanged;
//                      R  [0] MDIO_IN
//     Undefined offsets read 0 and ignore writes. One write sets MDC, MDIO_OE
//     and MDIO_OUT together, so firmware needs one store per MDC half period.
//   * Pins: mdc, mdio_o and mdio_t are flip-flops; mdio_t = !MDIO_OE (1
//     releases the line to the board pull-up). The board top owns the IOBUF.
//     mdio_i and phy_int_n are asynchronous and enter through 3-stage
//     rtlnet_sync chains; only the last stage is read.
//   * Power-on PHY reset: phy_rst_n (a flip-flop) is low while resetn is low
//     and for POR_RESET_MS milliseconds (CLK_HZ / 1000 * POR_RESET_MS clocks)
//     after resetn is released, then follows !CTRL.PHY_RESET.
//   * irq = PHY_INT && IRQ_EN, registered, a level.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (cpu_clk, 100 MHz on the Nexys Video) only; resetn is
//   synchronous to clk, active low.
// -----------------------------------------------------------------------------
module rtlnet_mdio #(
  parameter int CLK_HZ       = 100_000_000,  // clk frequency, Hz (CAPS and POR timing)
  parameter int POR_RESET_MS = 20            // PHY reset low time after resetn, ms (1..255)
)(
  // Clock and reset: cpu_clk; resetn synchronous to it, active low.
  input  logic        clk,
  input  logic        resetn,

  // AXI4-Lite register slave, clk domain, 32-bit data, 12-bit byte address
  // (4 KiB window); single outstanding transaction, all responses OKAY.
  input  logic [11:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [11:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // MDIO pins to the board-top IOBUF (I = mdio_o, T = mdio_t, O = mdio_i).
  // mdc and mdio_o/mdio_t are clk registers, idle mdc low and line released
  // (mdio_t = 1); mdio_i is asynchronous to clk.
  output logic        mdc,
  output logic        mdio_o,
  output logic        mdio_t,
  input  logic        mdio_i,

  // PHY control: phy_rst_n to the PHY's PHYRSTB (active low, clk register);
  // phy_int_n from the PHY's INTB (active low, open drain, asynchronous).
  output logic        phy_rst_n,
  input  logic        phy_int_n,

  // Interrupt to the CPU core: level, high while the PHY interrupt is
  // asserted and CTRL.IRQ_EN is set; clk register.
  output logic        irq
);

  import rtlnet_pkg::*;

  // ---------------------------------------------------------------------------
  // Register map: mirrors cores/rtlnet_mdio/driver/rtlnet_mdio.h.
  // ---------------------------------------------------------------------------
  localparam int          ADDR_W        = 12;
  localparam logic [11:0] REG_ID        = 12'h000;
  localparam logic [11:0] REG_VERSION   = 12'h004;
  localparam logic [11:0] REG_CAPS      = 12'h008;
  localparam logic [11:0] REG_CTRL      = 12'h00C;
  localparam logic [11:0] REG_STATUS    = 12'h010;
  localparam logic [11:0] REG_BITBANG   = 12'h014;

  localparam logic [31:0] ID_VALUE      = id4("M", "D", "I", "O");
  localparam logic [31:0] VERSION_VALUE = 32'h1022_2026;

  localparam int CTRL_MDC_BIT       = 0;
  localparam int CTRL_MDIO_OE_BIT   = 1;
  localparam int CTRL_MDIO_OUT_BIT  = 2;
  localparam int CTRL_PHY_RESET_BIT = 8;
  localparam int CTRL_IRQ_EN_BIT    = 9;

  // POR timing: a CLK_KHZ-cycle millisecond prescaler and a millisecond count.
  localparam int CLK_KHZ      = CLK_HZ / 1000;
  localparam int CLK_KHZ_MAX  = (1 << 24) - 1;          // CAPS field width
  localparam int POR_MS_MAX   = 255;                    // CAPS field width
  localparam int DIV_W        = $clog2(CLK_KHZ);
  localparam int MS_W         = $clog2(POR_RESET_MS + 1);

  localparam logic [31:0] CAPS_VALUE = {8'(POR_RESET_MS), 24'(CLK_KHZ)};

  generate
    if (CLK_KHZ < 2 || CLK_KHZ > CLK_KHZ_MAX) begin : g_bad_clk
      $fatal(1, "rtlnet_mdio: CLK_HZ=%0d out of range (2 kHz .. 16.7 GHz)", CLK_HZ);
    end
    if (POR_RESET_MS < 1 || POR_RESET_MS > POR_MS_MAX) begin : g_bad_por
      $fatal(1, "rtlnet_mdio: POR_RESET_MS=%0d out of range (1 .. 255)", POR_RESET_MS);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Signals
  // ---------------------------------------------------------------------------
  logic              reg_wr_en;
  logic [ADDR_W-1:0] reg_wr_addr;
  logic [31:0]       reg_wr_data;
  logic              reg_rd_en;
  logic [ADDR_W-1:0] reg_rd_addr;
  logic [31:0]       reg_rd_data;

  logic              ctrl_phy_reset;   // CTRL.PHY_RESET
  logic              ctrl_irq_en;      // CTRL.IRQ_EN

  logic              mdio_in;          // mdio_i, last synchronizer stage
  logic              phy_int_n_s;      // phy_int_n, last synchronizer stage
  logic              phy_int;          // PHY interrupt asserted (active high)

  logic [DIV_W-1:0]  por_div;          // clocks inside the current millisecond
  logic [MS_W-1:0]   por_ms;           // completed milliseconds
  logic              por_done;         // POR_RESET_MS elapsed since resetn release

  logic [31:0]       status_word;
  logic [31:0]       ctrl_word;

  // ---------------------------------------------------------------------------
  // AXI4-Lite to register strobes; read data is due one clock after reg_rd_en.
  // ---------------------------------------------------------------------------
  rtlnet_axil_slave #(.ADDR_W(ADDR_W)) u_axil (
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

  // ---------------------------------------------------------------------------
  // Asynchronous inputs: 3-stage level synchronizers in clk. Both lines idle
  // high (MDIO pull-up, INTB open drain), so the chains reset to 1.
  // ---------------------------------------------------------------------------
  rtlnet_sync #(.WIDTH(1), .STAGES(3), .RESET_VALUE(1'b1)) u_mdio_i_sync (
    .clk    (clk),
    .resetn (resetn),
    .d      (mdio_i),
    .q      (mdio_in)
  );

  rtlnet_sync #(.WIDTH(1), .STAGES(3), .RESET_VALUE(1'b1)) u_phy_int_sync (
    .clk    (clk),
    .resetn (resetn),
    .d      (phy_int_n),
    .q      (phy_int_n_s)
  );

  assign phy_int = !phy_int_n_s;

  // ---------------------------------------------------------------------------
  // Power-on reset timer: counts POR_RESET_MS milliseconds of clk after resetn
  // is released, then holds por_done until the next reset.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      por_div  <= '0;
      por_ms   <= '0;
      por_done <= 1'b0;
    end else if (!por_done) begin
      if (por_div == DIV_W'(CLK_KHZ - 1)) begin
        por_div <= '0;
        if (por_ms == MS_W'(POR_RESET_MS - 1)) por_done <= 1'b1;
        else                                   por_ms   <= por_ms + 1'b1;
      end else begin
        por_div <= por_div + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Control register and pin flip-flops. CTRL writes all five fields; BITBANG
  // writes only the three pin fields. mdio_t is stored inverted (MDIO_OE).
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      mdc            <= 1'b0;
      mdio_o         <= 1'b0;
      mdio_t         <= 1'b1;
      ctrl_phy_reset <= 1'b0;
      ctrl_irq_en    <= 1'b0;
    end else if (reg_wr_en) begin
      if (reg_wr_addr == REG_CTRL || reg_wr_addr == REG_BITBANG) begin
        mdc    <= reg_wr_data[CTRL_MDC_BIT];
        mdio_o <= reg_wr_data[CTRL_MDIO_OUT_BIT];
        mdio_t <= !reg_wr_data[CTRL_MDIO_OE_BIT];
      end
      if (reg_wr_addr == REG_CTRL) begin
        ctrl_phy_reset <= reg_wr_data[CTRL_PHY_RESET_BIT];
        ctrl_irq_en    <= reg_wr_data[CTRL_IRQ_EN_BIT];
      end
    end
  end

  // PHY reset pin: low until the POR timer ends, then under CTRL.PHY_RESET.
  always_ff @(posedge clk) begin
    if (!resetn) phy_rst_n <= 1'b0;
    else         phy_rst_n <= por_done && !ctrl_phy_reset;
  end

  // Interrupt to the CPU: synchronized PHY interrupt gated by IRQ_EN.
  always_ff @(posedge clk) begin
    if (!resetn) irq <= 1'b0;
    else         irq <= phy_int && ctrl_irq_en;
  end

  // ---------------------------------------------------------------------------
  // Registered read mux.
  // ---------------------------------------------------------------------------
  always_comb begin
    ctrl_word                     = '0;
    ctrl_word[CTRL_MDC_BIT]       = mdc;
    ctrl_word[CTRL_MDIO_OE_BIT]   = !mdio_t;
    ctrl_word[CTRL_MDIO_OUT_BIT]  = mdio_o;
    ctrl_word[CTRL_PHY_RESET_BIT] = ctrl_phy_reset;
    ctrl_word[CTRL_IRQ_EN_BIT]    = ctrl_irq_en;
  end

  assign status_word = {28'd0, !phy_rst_n, por_done, phy_int, mdio_in};

  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:      reg_rd_data <= ID_VALUE;
        REG_VERSION: reg_rd_data <= VERSION_VALUE;
        REG_CAPS:    reg_rd_data <= CAPS_VALUE;
        REG_CTRL:    reg_rd_data <= ctrl_word;
        REG_STATUS:  reg_rd_data <= status_word;
        REG_BITBANG: reg_rd_data <= {31'd0, mdio_in};
        default:     reg_rd_data <= '0;
      endcase
    end
  end

endmodule
