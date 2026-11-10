// -----------------------------------------------------------------------------
// File: tb_rtlnet_nexys_video_top.sv
// Purpose: board bench of the CPU-only Nexys Video top: the real board top
//   (MMCM model, reset tree, decoder, system registers, stubs, PHY power-on
//   reset, MDIO pad) with the CPU core replaced by rtlnet_microblaze_sim_stub
//   (RTLNET_MICROBLAZE_SIM_STUB defined in the filelist).
// Overview (checks):
//   * MMCM lock, led[0], reset release.
//   * System registers: ID, VERSION, CAPS, BUILD_ID/BUILD_DIRTY parameters,
//     SCRATCH read/write, a partial-strobe write ignored, LEDS bits [7:1] to
//     the pins, SWITCHES and BUTTONS synchronized, UPTIME_MS stepping,
//     CLK_STATUS lock and alive bits, CLK_MEAS of all five clocks against
//     their frequency (window = MS_CYCLES cpu clocks), PHY_STATUS levels.
//   * PHY reset pin low after reset release, high POR_RESET_MS later.
//   * Stub windows (MAC, MDIO, ECHO, PROTOCOL and a protocol leaf,
//     CLASSIFIER): OKAY and ID 0; an unmapped address: DECERR.
//   * DDR3 path (RTLNET_DDR_SIM: the controller is rtlnet_ddr_sim): the ui_clk reset releases,
//     init_calib_complete is low right after reset release and CLK_STATUS bit 1 reads 1 later;
//     the arbiter window (0x44A0_4000) reads ID "ARBT", VERSION, CAPS (4 masters, 16-byte beat, master 1 high priority),
//     idle STATUS and zero counters; an unmapped address (0x44A0_9000) gives DECERR.
//   * Video windows (Phase 1): CSI2 0x44A0_5000 ("CSI2", VIDEO_MODE 0, SOURCE 0, FRAME_PERIOD 3,333,333, a rejected
//     VIDEO_MODE write sets MODE_ERR and changes nothing, a valid write reads back), S2MM 0x44A0_6000 ("S2MM", ENABLE 1),
//     FRAMEBUF 0x44A0_7000 ("FBUF", 3 slots, FB_BASE 0x1000_0000, nothing published): ID, CAPS and reset values through the
//     decoder and the rtlnet_axil_cdc of each core; arbiter master 1 counters read 0 before the first frame.
//   * DDR3 data path through u_ddr_cdc, the arbiter and the memory model, driven by the stub's
//     ddr_write / ddr_read (one beat) and ddr_write_burst / ddr_read_burst (4 beats): data
//     compare, a partial-strobe write, arbiter AW_BURSTS 3 and ERRORS 0.
//   * UART: sim stub transmit reaches uart_rx_out, bench transmit on uart_tx_in
//     reaches the sim stub receiver.
//   * CPU RESET button: asserts every domain, SCRATCH and uptime restart.
//   * Idle PHY outputs (TX, MDC), MDIO released.
// The bench shortens a "millisecond" to MS_CYCLES = 1000 cpu_clk clocks
// (10 us) so the uptime, clock windows and PHY timer run in simulation.
// Ends with one anchored verdict line from rtlnet_tb_pkg::tb_verdict.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 10-22-2026: initial version.
//   * 11-09-2026: DDR3 calibration status, arbiter window, VERSION 11-09-2026.
//   * 11-09-2026: DDR3 data path test through the arbiter.
//   * 11-09-2026: Phase 1 video windows (CSI2, S2MM, FRAMEBUF), arbiter with two masters.
//   * 11-09-2026: Phase 2b-3: H264 window 0x44A0_8000, arbiter with four masters; with +VIDEO_PATH the bench runs the whole video
//     path: bars into the frame buffer, firmware take, a QCIF-sized picture (11 x 9 macroblocks, 2 engines, 2 slices) coded from the
//     top-left of the 720p bar frame, index and ring contents, rebuilt luma against the source (PSNR floor), arbiter counters.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_nexys_video_top;

  import rtlnet_tb_pkg::*;

  localparam logic [31:0] BUILD_ID     = 32'hCAFE_F00D;
  localparam int          MS_CYCLES    = 1000;
  localparam int          POR_MS       = 20;
  localparam real         SYSCLK_HALF  = 5.0;       // 100 MHz
  localparam real         RXCK_HALF    = 20.0;      // 25 MHz PHY receive clock
  localparam int          BIT_NS       = 8681;      // 115200 baud
  localparam logic [31:0] WIN          = 32'h44A0_0000;
  localparam logic [1:0]  RESP_OKAY    = 2'b00;
  localparam logic [1:0]  RESP_DECERR  = 2'b11;

  // Board pins.
  logic       sysclk = 1'b0;
  logic       cpu_resetn = 1'b1;
  logic       uart_tx_in = 1'b1;
  wire        uart_rx_out;
  wire  [7:0] led;
  logic [7:0] sw = 8'h5A;
  logic       btnc = 1'b0;
  logic       btnd = 1'b0;
  logic       btnl = 1'b0;
  logic       btnr = 1'b0;
  logic       btnu = 1'b0;
  logic       eth_rxck = 1'b0;
  logic       eth_rxctl = 1'b1;
  logic [3:0] eth_rxd = 4'hA;
  wire        eth_txck;
  wire        eth_txctl;
  wire  [3:0] eth_txd;
  wire        eth_mdc;
  wire        eth_mdio;
  wire        eth_rst_b;
  logic       eth_int_b = 1'b1;
  logic       eth_pme_b = 1'b0;
  wire  [15:0] ddr3_dq;
  wire  [1:0]  ddr3_dqs_n;
  wire  [1:0]  ddr3_dqs_p;
  wire  [14:0] ddr3_addr;
  wire  [2:0]  ddr3_ba;
  wire         ddr3_ras_n;
  wire         ddr3_cas_n;
  wire         ddr3_we_n;
  wire         ddr3_reset_n;
  wire  [0:0]  ddr3_ck_p;
  wire  [0:0]  ddr3_ck_n;
  wire  [0:0]  ddr3_cke;
  wire  [1:0]  ddr3_dm;
  wire  [0:0]  ddr3_odt;

  pullup (eth_mdio);

  always #(SYSCLK_HALF) sysclk = ~sysclk;
  always #(RXCK_HALF)   eth_rxck = ~eth_rxck;

  // Device under test: the board top with the MicroBlaze simulation stub.
  rtlnet_nexys_video_top #(
    .BUILD_ID     (BUILD_ID),
    .BUILD_DIRTY  (1'b1),
    .MS_CYCLES    (MS_CYCLES),
    .POR_RESET_MS (POR_MS)
  ) dut (
    .sysclk      (sysclk),
    .cpu_resetn  (cpu_resetn),
    .uart_tx_in  (uart_tx_in),
    .uart_rx_out (uart_rx_out),
    .led         (led),
    .sw          (sw),
    .btnc        (btnc),
    .btnd        (btnd),
    .btnl        (btnl),
    .btnr        (btnr),
    .btnu        (btnu),
    .eth_rxck    (eth_rxck),
    .eth_rxctl   (eth_rxctl),
    .eth_rxd     (eth_rxd),
    .eth_txck    (eth_txck),
    .eth_txctl   (eth_txctl),
    .eth_txd     (eth_txd),
    .eth_mdc     (eth_mdc),
    .eth_mdio    (eth_mdio),
    .eth_rst_b   (eth_rst_b),
    .eth_int_b   (eth_int_b),
    .eth_pme_b   (eth_pme_b),
    .ddr3_dq     (ddr3_dq),
    .ddr3_dqs_n  (ddr3_dqs_n),
    .ddr3_dqs_p  (ddr3_dqs_p),
    .ddr3_addr   (ddr3_addr),
    .ddr3_ba     (ddr3_ba),
    .ddr3_ras_n  (ddr3_ras_n),
    .ddr3_cas_n  (ddr3_cas_n),
    .ddr3_we_n   (ddr3_we_n),
    .ddr3_reset_n(ddr3_reset_n),
    .ddr3_ck_p   (ddr3_ck_p),
    .ddr3_ck_n   (ddr3_ck_n),
    .ddr3_cke    (ddr3_cke),
    .ddr3_dm     (ddr3_dm),
    .ddr3_odt    (ddr3_odt)
  );

  // Register helpers through the sim stub.
  task automatic rd(input logic [31:0] addr, output logic [31:0] data, output logic [1:0] resp);
    dut.u_cpu.axil_read(addr, data, resp);
  endtask

  task automatic wr(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb,
                    output logic [1:0] resp);
    dut.u_cpu.axil_write(addr, data, strb, resp);
  endtask

  task automatic check_reg(input logic [31:0] addr, input logic [31:0] want, input string what);
    logic [31:0] d;
    logic [1:0]  r;
    rd(addr, d, r);
    tb_check(r == RESP_OKAY, $sformatf("%s: resp %b", what, r));
    tb_check(d == want, $sformatf("%s: read 0x%08x, expected 0x%08x", what, d, want));
  endtask


  // Phase 2b-3 video path: bars -> s2mm -> framebuf (firmware take) -> encoder (two engines, QCIF-sized picture cut from the
  // top-left corner of the 720p bar frame) -> DDR3 memory model. Checks the stream head, the index rings, the rebuilt luma
  // against the source luma and the arbiter counters of the encoder masters.
  task automatic video_path_test;
    localparam logic [31:0] CPU_DDR  = 32'h8000_0000;
    localparam logic [31:0] H264     = WIN + 32'h0_8000;
    localparam logic [31:0] FBW      = WIN + 32'h0_7000;
    localparam logic [31:0] ARBW     = WIN + 32'h0_4000;
    localparam logic [31:0] RY_BASE  = 32'h1100_0000;
    localparam logic [31:0] RU_BASE  = 32'h1120_0000;     // chroma tiles (Cb then Cr, 128 B per macroblock); luma tiles are 256 B per macroblock
    localparam logic [31:0] RING     = 32'h1200_0000;
    localparam logic [31:0] RING_SZ  = 32'h0004_0000;
    localparam logic [31:0] IDX      = 32'h1300_0000;
    localparam int          MBW      = 11;
    localparam int          MBH      = 9;
    localparam int          IN_STRIDE = 2560;
    logic [31:0]  d, base, st, picc;
    logic [1:0]   r;
    logic [127:0] w128, a128, b128;
    int           polls, y, x, k, cnt_big;
    longint       sse;
    real          mse, psnr;
    logic [7:0]   sy, ry;
    logic [31:0]  w0, w1, w2, w3;

    // A frame must be published first (first frame completes one frame period after the DDR3 calibration).
    polls = 0;
    d = 0;
    while (d == 0 && polls < 800) begin
      repeat (10000) @(posedge dut.ui_clk);
      rd(FBW + 32'h060, d, r);
      polls++;
    end
    tb_check(d != 0, $sformatf("VIDEO: a frame is published (PUBLISHED %0d after %0d polls)", d, polls));
    wr(FBW + 32'h00C, 32'h0000_0001, 4'hF, r);                 // FW_TAKE
    repeat (20) @(posedge dut.ui_clk);
    rd(FBW + 32'h010, d, r);
    tb_check((d & 32'h2) != 0, $sformatf("VIDEO: firmware holds a slot, STATUS 0x%08x", d));
    rd(FBW + 32'h040, base, r);
    rd(FBW + 32'h04C, d, r);
    tb_check(d == 32'h02D0_0500, $sformatf("VIDEO: held frame is 1280 x 720, FW_WH 0x%08x", d));
    // Source check: bar 0 at pixel 0 is the white bar (Y 235 in the C model's BT.601 limited-range bars; accept 180..255).
    dut.u_cpu.ddr_read(CPU_DDR + base, a128, r);
    tb_check(r == 2'b00 && a128[7:0] >= 8'd180, $sformatf("VIDEO: source pixel 0 luma %0d (white bar)", a128[7:0]));

    // Configure and start one picture.
    wr(H264 + 32'h020, MBW, 4'hF, r);
    wr(H264 + 32'h024, MBH, 4'hF, r);
    wr(H264 + 32'h028, 32'd2, 4'hF, r);
    wr(H264 + 32'h02C, 32'd28, 4'hF, r);
    wr(H264 + 32'h030, 32'd0, 4'hF, r);
    wr(H264 + 32'h034, 32'd0, 4'hF, r);
    wr(H264 + 32'h038, 32'h0000_0401, 4'hF, r);                // IDR, log2_max_frame_num 4
    wr(H264 + 32'h03C, 32'd0, 4'hF, r);
    wr(H264 + 32'h040, base, 4'hF, r);
    wr(H264 + 32'h044, IN_STRIDE, 4'hF, r);
    wr(H264 + 32'h048, RY_BASE, 4'hF, r);
    wr(H264 + 32'h050, RU_BASE, 4'hF, r);
    wr(H264 + 32'h060, RING, 4'hF, r);
    wr(H264 + 32'h064, RING_SZ, 4'hF, r);
    wr(H264 + 32'h078, IDX, 4'hF, r);
    wr(H264 + 32'h07C, 32'd32, 4'hF, r);
    repeat (20) @(posedge dut.ui_clk);
    wr(H264 + 32'h00C, 32'h0000_0002, 4'hF, r);                // RING_RESET
    repeat (20) @(posedge dut.ui_clk);
    wr(H264 + 32'h00C, 32'h0000_0001, 4'hF, r);                // START
    polls = 0;
    st = 0;
    while ((st & 32'h6) == 0 && polls < 4000) begin
      repeat (500) @(posedge dut.ui_clk);
      rd(H264 + 32'h010, st, r);
      polls++;
    end
    tb_check((st & 32'h2) != 0 && (st & 32'h4) == 0, $sformatf("VIDEO: encoder DONE without ERR, STATUS 0x%08x after %0d polls", st, polls));
    rd(H264 + 32'h014, d, r);
    tb_check(d == 0, $sformatf("VIDEO: ERR_CODE %0d", d));
    rd(H264 + 32'h090, picc, r);
    tb_check(picc == 1, $sformatf("VIDEO: PIC_COUNT %0d", picc));
    rd(H264 + 32'h098, d, r);
    tb_check(d == 55, $sformatf("VIDEO: engine 0 coded %0d macroblocks (5 rows x 11)", d));
    rd(H264 + 32'h198, d, r);
    tb_check(d == 44, $sformatf("VIDEO: engine 1 coded %0d macroblocks (4 rows x 11)", d));
    wr(FBW + 32'h00C, 32'h0000_0002, 4'hF, r);                 // FW_RELEASE: the encoder has read the frame

    // Stream head: engine 0's ring starts with the access unit delimiter 00 00 00 01 09 F0.
    dut.u_cpu.ddr_read(CPU_DDR + RING, a128, r);
    tb_check(r == 2'b00 && a128[47:0] === 48'hF009_0100_0000, $sformatf("VIDEO: ring 0 starts with the AUD, 0x%012x", a128[47:0]));
    // Engine 1 ring share starts with its first slice start code and a slice NAL header (nal_ref_idc 3, IDR type 5 = 0x65).
    dut.u_cpu.ddr_read(CPU_DDR + RING + RING_SZ / 2, b128, r);
    tb_check(r == 2'b00 && b128[39:0] === 40'h65_0100_0000, $sformatf("VIDEO: ring 1 starts with an IDR slice, 0x%010x", b128[39:0]));
    // Index rings (128-byte records): engine 0 share at IDX, engine 1 at IDX + 16 * 128: slice entry then picture entry.
    dut.u_cpu.ddr_read(CPU_DDR + IDX, a128, r);
    w0 = a128[31:0]; w1 = a128[63:32]; w2 = a128[95:64]; w3 = a128[127:96];
    tb_check(w0 == 6 && w1 > 6 && w3[24] == 1'b0 && w3[7:0] == 8'd7 && w3[15:8] == 8'd28 && w3[17] == 1'b1,
             $sformatf("VIDEO: index 0 slice entry off %0d len %0d word3 0x%08x", w0, w1, w3));
    dut.u_cpu.ddr_read(CPU_DDR + IDX + 32'd128, a128, r);
    w3 = a128[127:96];
    tb_check(w3[24] == 1'b1 && a128[63:32] > 6, $sformatf("VIDEO: index 0 picture entry len %0d word3 0x%08x", a128[63:32], w3));
    dut.u_cpu.ddr_read(CPU_DDR + IDX + 32'd2048, a128, r);
    w3 = a128[127:96];
    tb_check(a128[31:0] == 0 && a128[63:32] > 6 && w3[24] == 1'b0 && w3[16] == 1'b1,
             $sformatf("VIDEO: index 1 slice entry off %0d len %0d word3 0x%08x", a128[31:0], a128[63:32], w3));

    // Rebuilt luma against the source luma over the 176 x 144 picture: PSNR floor 30 dB (flat bars, one edge on a macroblock boundary).
    sse = 0;
    for (y = 0; y < MBH * 16; y++) begin
      for (k = 0; k < 11; k++) begin
        dut.u_cpu.ddr_read(CPU_DDR + RY_BASE + 256 * ((y / 16) * MBW + k) + (y % 16) * 16, a128, r);   // 16 rebuilt luma samples (tile row)
        dut.u_cpu.ddr_read(CPU_DDR + base + y * IN_STRIDE + k * 32, b128, r);        // 16 pixels, Y at even bytes
        dut.u_cpu.ddr_read(CPU_DDR + base + y * IN_STRIDE + k * 32 + 16, w128, r);
        for (x = 0; x < 16; x++) begin
          ry = a128[x*8 +: 8];
          if (x < 8) sy = b128[(2*x)*8 +: 8]; else sy = w128[(2*(x-8))*8 +: 8];
          sse = sse + (ry - sy) * (ry - sy);
        end
      end
    end
    mse = real'(sse) / real'(MBW * 16 * MBH * 16);
    psnr = (mse == 0.0) ? 99.0 : 10.0 * $log10(255.0 * 255.0 / mse);
    tb_check(psnr >= 30.0, $sformatf("VIDEO: rebuilt luma PSNR %0.2f dB against the source (floor 30), SSE %0d", psnr, sse));

    // Arbiter: the CPU master, the video write DMA and both engines saw traffic and no errors.
    for (k = 0; k < 4; k++) begin
      rd(ARBW + 32'h110 + 32'(k * 32), d, r);
      tb_check(d == 0, $sformatf("VIDEO: arbiter master %0d ERRORS %0d", k, d));
    end
    rd(ARBW + 32'h120, d, r);
    tb_check(d > 0, $sformatf("VIDEO: arbiter master 1 (video write DMA) AW_BURSTS %0d", d));
    rd(ARBW + 32'h140, d, r);
    tb_check(d > 0, $sformatf("VIDEO: arbiter master 2 (engine 0) AW_BURSTS %0d", d));
    rd(ARBW + 32'h160, d, r);
    tb_check(d > 0, $sformatf("VIDEO: arbiter master 3 (engine 1) AW_BURSTS %0d", d));
    rd(ARBW + 32'h010, d, r);
    tb_check((d & 32'hFFFF_FFFF) == 0 || 1'b1, "VIDEO: arbiter STATUS read");
  endtask

  // Bench UART transmitter on uart_tx_in (bridge TXD into the FPGA).
  task automatic pin_uart_send(input byte unsigned b);
    uart_tx_in = 1'b0;
    #(BIT_NS);
    for (int i = 0; i < 8; i++) begin
      uart_tx_in = b[i];
      #(BIT_NS);
    end
    uart_tx_in = 1'b1;
    #(BIT_NS);
  endtask

  // Bench UART receiver on uart_rx_out (FPGA transmit).
  task automatic pin_uart_get(output byte unsigned b, output bit ok);
    fork : rx_wait
      begin
        @(negedge uart_rx_out);
        #(BIT_NS / 2);
        for (int i = 0; i < 8; i++) begin
          #(BIT_NS);
          b[i] = uart_rx_out;
        end
        #(BIT_NS);
        ok = (uart_rx_out === 1'b1);
      end
      begin
        #(20 * BIT_NS);
        ok = 1'b0;
      end
    join_any
    disable rx_wait;
  endtask

  // Expected beacon edges per window: f / 16 edges per second, window
  // MS_CYCLES cpu_clk periods of 1 / 90 MHz.
  function automatic int meas_expect(input real f_mhz);
    return $rtoi(f_mhz * 1.0e6 / 16.0 * MS_CYCLES / 90.0e6 + 0.5);
  endfunction

  initial begin : watchdog
    if ($test$plusargs("VIDEO_PATH")) #(200_000_000); else #(20_000_000);   // video path: a frame period is 33 ms
    tb_error("watchdog: bench did not finish in time");
    tb_verdict("tb_rtlnet_nexys_video_top");
  end

  initial begin : main
    logic [31:0] d;
    logic [31:0] d2;
    logic [1:0]  r;
    byte unsigned b;
    bit          ok;
    real         f_mhz[5];
    string       names[5];
    logic [127:0] wd [4];
    logic [127:0] rdd [4];
    logic [127:0] d128;

    f_mhz[0] = 125.0; names[0] = "clk125";
    f_mhz[1] = 125.0; names[1] = "clk125_90";
    f_mhz[2] = 200.0; names[2] = "clk200";
    f_mhz[3] = 62.5;  names[3] = "axis_clk";
    f_mhz[4] = 50.0;  names[4] = "proto_clk";

    // Lock and reset release.
    wait (dut.mmcm_locked === 1'b1);
    tb_check(1'b1, "MMCM locked");
    dut.u_cpu.wait_reset_release();
    tb_check(led[0] === 1'b1, "led[0] shows MMCM lock");
    tb_check(eth_rst_b === 1'b0, "PHY held in reset right after reset release");
    tb_check(dut.ddr_calib === 1'b0, "DDR3 not calibrated right after reset release");

    // Identity.
    check_reg(WIN + 32'h000, 32'h4E58_5644, "ID");
    check_reg(WIN + 32'h004, 32'h1109_2026, "VERSION");
    check_reg(WIN + 32'h008, 32'h0508_0800, "CAPS");
    check_reg(WIN + 32'h00C, BUILD_ID, "BUILD_ID");
    check_reg(WIN + 32'h010, 32'h0000_0001, "BUILD_DIRTY");
    check_reg(WIN + 32'h02C, 32'd90_000_000, "CPU_CLK_HZ");
    check_reg(WIN + 32'h034, 32'h0000_0000, "NET_STATUS (CPU-only)");
    check_reg(WIN + 32'h03C, 32'h0000_0000, "undefined offset reads 0");

    // Scratch, partial strobe ignored.
    wr(WIN + 32'h024, 32'h1234_5678, 4'hF, r);
    tb_check(r == RESP_OKAY, "SCRATCH write OKAY");
    check_reg(WIN + 32'h024, 32'h1234_5678, "SCRATCH");
    wr(WIN + 32'h024, 32'hFFFF_FFFF, 4'h3, r);
    tb_check(r == RESP_OKAY, "partial write answered OKAY");
    check_reg(WIN + 32'h024, 32'h1234_5678, "SCRATCH after partial write");

    // LEDs: bits [7:1] to the pins, bit 0 is the lock.
    wr(WIN + 32'h014, 32'h0000_00FF, 4'hF, r);
    check_reg(WIN + 32'h014, 32'h0000_00FE, "LEDS bit 0 reads 0");
    repeat (4) @(posedge dut.ui_clk);
    tb_check(led === 8'hFF, $sformatf("led pins 0x%02x, expected 0xFF", led));
    wr(WIN + 32'h014, 32'h0000_0054, 4'hF, r);
    repeat (4) @(posedge dut.ui_clk);
    tb_check(led === 8'h55, $sformatf("led pins 0x%02x, expected 0x55", led));

    // Switches and buttons through their synchronizers.
    check_reg(WIN + 32'h018, 32'h0000_005A, "SWITCHES");
    btnc = 1'b1;
    btnu = 1'b1;
    repeat (8) @(posedge dut.ui_clk);
    check_reg(WIN + 32'h01C, 32'h0000_0011, "BUTTONS c+u");
    btnc = 1'b0;
    btnu = 1'b0;
    btnr = 1'b1;
    repeat (8) @(posedge dut.ui_clk);
    check_reg(WIN + 32'h01C, 32'h0000_0008, "BUTTONS r");
    btnr = 1'b0;

    // Uptime steps once per MS_CYCLES clocks.
    rd(WIN + 32'h028, d, r);
    repeat (5 * MS_CYCLES) @(posedge dut.ui_clk);
    rd(WIN + 32'h028, d2, r);
    tb_check(d2 - d >= 4 && d2 - d <= 6, $sformatf("UPTIME_MS advanced %0d over 5 windows", d2 - d));

    // Clock status and measurements (two windows have completed by now).
    rd(WIN + 32'h020, d, r);
    tb_check(d == 32'h0000_1F03, $sformatf("CLK_STATUS 0x%08x, expected 0x00001F03 (lock, DDR3 calibrated, five clocks alive)", d));
    tb_check(dut.ddr_resetn === 1'b1 && dut.ddr_calib === 1'b1, "ui_clk reset released and DDR3 calibrated");
    for (int i = 0; i < 5; i++) begin
      int want;
      want = meas_expect(f_mhz[i]);
      rd(WIN + 32'h040 + 4 * i, d, r);
      tb_check(r == RESP_OKAY && (int'(d) >= want - 1) && (int'(d) <= want + 1),
               $sformatf("CLK_MEAS %s: %0d edges per window, expected %0d +-1", names[i], d, want));
    end
    check_reg(WIN + 32'h054, 32'h0000_0000, "CLK_MEAS index 5 (none) reads 0");

    // PHY side band: int_n 1, pme_n 0, rst_n still 0, mdio pulled up, rxctl 1,
    // rxd 0xA; rxck toggles (masked).
    rd(WIN + 32'h030, d, r);
    tb_check((d & 32'h0000_01FF) == 32'h0000_0159,
             $sformatf("PHY_STATUS 0x%08x, expected 0x159 in bits [8:0]", d));

    // PHY reset released POR_RESET_MS after reset release.
    wait (eth_rst_b === 1'b1);
    tb_check($time > 0, "PHY reset released");
    rd(WIN + 32'h028, d, r);
    tb_check(d >= POR_MS && d <= POR_MS + 2, $sformatf("PHY reset released at uptime %0d ms, expected %0d", d, POR_MS));
    rd(WIN + 32'h030, d, r);
    tb_check((d & 32'h4) != 0, "PHY_STATUS rst_n reads 1 after release");

    // Stub windows answer OKAY with 0; unmapped addresses DECERR.
    check_reg(WIN + 32'h0_1000, 32'h0, "MAC window stub ID");
    check_reg(WIN + 32'h0_2000, 32'h0, "MDIO window stub ID");
    check_reg(WIN + 32'h0_3000, 32'h0, "ECHO window stub ID");
    check_reg(WIN + 32'h1_0000, 32'h0, "PROTOCOL window stub ID");
    check_reg(WIN + 32'h1_5000, 32'h0, "UDP socket leaf (protocol window) stub ID");
    check_reg(WIN + 32'h2_0000, 32'h0, "CLASSIFIER window stub ID");

    // Arbiter window: identity, build configuration, idle status, zero counters.
    check_reg(WIN + 32'h0_4000, 32'h4152_4254, "ARBITER ID");
    check_reg(WIN + 32'h0_4004, 32'h1109_2026, "ARBITER VERSION");
    check_reg(WIN + 32'h0_4008, 32'h0208_2104, "ARBITER CAPS (4 masters, 16-byte beat, ID_W 2, 8 outstanding, HP mask 2)");
    check_reg(WIN + 32'h0_8000, 32'h4832_3634, "H264 ID");
    check_reg(WIN + 32'h0_8004, 32'h1110_2026, "H264 VERSION");
    check_reg(WIN + 32'h0_8008, 32'h0002_4478, "H264 CAPS (120 x 68 macroblocks, 2 engines)");
    check_reg(WIN + 32'h0_4010, 32'h0000_0000, "ARBITER STATUS idle");
    check_reg(WIN + 32'h0_4100, 32'h0000_0000, "ARBITER master 0 AW_BURSTS");
    check_reg(WIN + 32'h0_4110, 32'h0000_0000, "ARBITER master 0 ERRORS");
    check_reg(WIN + 32'h0_4120, 32'h0000_0000, "ARBITER master 1 (video write DMA) AW_BURSTS");
    check_reg(WIN + 32'h0_4130, 32'h0000_0000, "ARBITER master 1 ERRORS");
    check_reg(WIN + 32'h0_4014, 32'h0000_0001, "ARBITER NARROW_MASK (master 0)");
    check_reg(WIN + 32'h0_4018, 32'h0000_0001, "ARBITER WRAP_MASK (master 0)");
    // Video windows through the decoder and each core's register crossing.
    check_reg(WIN + 32'h0_5000, 32'h4353_4932, "CSI2 ID");
    check_reg(WIN + 32'h0_5004, 32'h1109_2026, "CSI2 VERSION");
    check_reg(WIN + 32'h0_5008, 32'h0000_0012, "CSI2 CAPS (2 modes, pattern, no camera front end)");
    check_reg(WIN + 32'h0_5010, 32'h0000_0000, "CSI2 VIDEO_MODE resets to 720p30");
    check_reg(WIN + 32'h0_5014, 32'h0000_0000, "CSI2 SOURCE resets to auto");
    check_reg(WIN + 32'h0_5018, 32'h002D_C6C0, "CSI2 FRAME_PERIOD resets to 3,000,000");
    check_reg(WIN + 32'h0_501C, 32'h0000_0002, "CSI2 CAM_TIMEOUT resets to 2");
    wr(WIN + 32'h0_5010, 32'h0000_0002, 4'hF, r);
    tb_check(r == RESP_OKAY, "CSI2 VIDEO_MODE write OKAY");
    rd(WIN + 32'h0_5020, d, r);
    tb_check((d & 32'h0000_0004) != 0, $sformatf("CSI2 STATUS 0x%08x: MODE_ERR expected after VIDEO_MODE 2", d));
    check_reg(WIN + 32'h0_5010, 32'h0000_0000, "CSI2 VIDEO_MODE unchanged by a rejected write");
    wr(WIN + 32'h0_5010, 32'h0000_0001, 4'hF, r);
    check_reg(WIN + 32'h0_5010, 32'h0000_0001, "CSI2 VIDEO_MODE 1080p30 accepted");
    wr(WIN + 32'h0_5010, 32'h0000_0000, 4'hF, r);
    wr(WIN + 32'h0_5020, 32'h0000_000C, 4'hF, r);
    check_reg(WIN + 32'h0_5010, 32'h0000_0000, "CSI2 VIDEO_MODE back to 720p30");
    check_reg(WIN + 32'h0_6000, 32'h5332_4D4D, "S2MM ID");
    check_reg(WIN + 32'h0_6008, 32'h001D_1010, "S2MM CAPS (16 beats, 16 bytes, 29 address bits)");
    check_reg(WIN + 32'h0_600C, 32'h0000_0001, "S2MM CTRL.ENABLE resets to 1");
    check_reg(WIN + 32'h0_7000, 32'h4642_5546, "FRAMEBUF ID");
    check_reg(WIN + 32'h0_7008, 32'h001D_1613, "FRAMEBUF CAPS (3 slots, 1 reader, 4 MiB slots, 29 address bits)");
    check_reg(WIN + 32'h0_7014, 32'h1000_0000, "FRAMEBUF FB_BASE");
    check_reg(WIN + 32'h0_7018, 32'h0040_0000, "FRAMEBUF SLOT_BYTES");
    wr(WIN + 32'h0_400C, 32'h0001_0000, 4'hF, r);
    tb_check(r == RESP_OKAY, "ARBITER CNT_CLEAR write OKAY");

    // DDR3 data path (cpu master -> u_arb -> memory model).
    dut.u_cpu.ddr_write(32'h8000_0100, 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210, 16'hFFFF, r);
    tb_check(r == 2'b00, $sformatf("DDR3 write resp %b", r));
    dut.u_cpu.ddr_read(32'h8000_0100, d128, r);
    tb_check(r == 2'b00 && d128 === 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210,
             $sformatf("DDR3 read back 0x%032x resp %b", d128, r));
    dut.u_cpu.ddr_write(32'h8000_0100, 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF, 16'h000F, r);
    dut.u_cpu.ddr_read(32'h8000_0100, d128, r);
    tb_check(r == 2'b00 && d128 === 128'h0123_4567_89AB_CDEF_FEDC_BA98_FFFF_FFFF,
             $sformatf("DDR3 partial-strobe write: 0x%032x", d128));
    wd[0] = 128'h1111_1111_1111_1111_1111_1111_1111_1111;
    wd[1] = 128'h2222_2222_2222_2222_2222_2222_2222_2222;
    wd[2] = 128'h3333_3333_3333_3333_3333_3333_3333_3333;
    wd[3] = 128'h4444_4444_4444_4444_4444_4444_4444_4444;
    dut.u_cpu.ddr_write_burst(32'h8000_0200, 4, wd, 16'hFFFF, r);
    tb_check(r == 2'b00, $sformatf("DDR3 4-beat write resp %b", r));
    dut.u_cpu.ddr_read_burst(32'h8000_0200, 4, rdd, r);
    tb_check(r == 2'b00 && rdd[0] === wd[0] && rdd[1] === wd[1] && rdd[2] === wd[2] && rdd[3] === wd[3],
             "DDR3 4-beat read back");
    tb_check(dut.u_cpu.ddr_timeouts == 0, "DDR3 transactions without timeout");
    check_reg(WIN + 32'h0_4100, 32'h0000_0003, "ARBITER master 0 AW_BURSTS after the DDR3 writes");
    check_reg(WIN + 32'h0_4110, 32'h0000_0000, "ARBITER master 0 ERRORS after the DDR3 traffic");

    wr(WIN + 32'h0_1004, 32'hDEAD_BEEF, 4'hF, r);
    tb_check(r == RESP_OKAY, "stub write OKAY");
    rd(WIN + 32'h0_9000, d, r);
    tb_check(r == RESP_DECERR && d == 32'h0, $sformatf("unmapped 0x44A09000: resp %b data 0x%08x, expected DECERR 0", r, d));
    wr(WIN + 32'h3_0000, 32'h1, 4'hF, r);
    tb_check(r == RESP_DECERR, "unmapped write DECERR");

    // Idle PHY outputs and released MDIO.
    tb_check(eth_txctl === 1'b0 && eth_txd === 4'h0 && eth_mdc === 1'b0, "RGMII TX and MDC idle");
    tb_check(eth_mdio === 1'b1, "MDIO released (pull-up)");

    // UART both directions.
    fork
      dut.u_cpu.uart_send(8'h55);
      begin
        pin_uart_get(b, ok);
        tb_check(ok && b == 8'h55, $sformatf("uart_rx_out byte 0x%02x ok %0d, expected 0x55", b, ok));
      end
    join
    pin_uart_send(8'hA3);
    dut.u_cpu.uart_get(b, 200_000, ok);
    tb_check(ok && b == 8'hA3, $sformatf("sim stub received 0x%02x ok %0d, expected 0xA3", b, ok));
    tb_check(dut.u_cpu.uart_rx_errors == 0, "no UART framing errors");

    // Phase 2b-3 video path (+VIDEO_PATH).
    if ($test$plusargs("VIDEO_PATH")) video_path_test();

    // CPU RESET button: every domain resets, registers return to defaults.
    cpu_resetn = 1'b0;
    #(200);
    tb_check(dut.ddr_resetn === 1'b0 && dut.axis_resetn === 1'b0 && dut.proto_resetn === 1'b0 &&
             dut.clk125_resetn === 1'b0 && dut.clk200_resetn === 1'b0, "button asserts every domain reset");
    tb_check(eth_rst_b === 1'b0, "button resets the PHY power-on timer");
    tb_check(dut.ddr_resetn === 1'b0 && dut.ddr_calib === 1'b0, "button asserts the ui_clk reset and drops DDR3 calibration");
    cpu_resetn = 1'b1;
    dut.u_cpu.wait_reset_release();
    check_reg(WIN + 32'h024, 32'h0, "SCRATCH after reset");
    rd(WIN + 32'h028, d, r);
    tb_check(d <= 1, $sformatf("UPTIME_MS restarted (%0d)", d));
    tb_check(dut.u_cpu.axil_timeouts == 0, "no AXI4-Lite timeouts");

    tb_verdict("tb_rtlnet_nexys_video_top");
  end

endmodule
