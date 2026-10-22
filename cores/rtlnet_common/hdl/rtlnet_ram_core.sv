// -----------------------------------------------------------------------------
// File: rtlnet_ram_core.sv
// Purpose: the one RAM of RTLNet. Every core memory (packet FIFOs, payload
//   buffers, rule tables) is an instance of this simple-dual-port RAM, so a
//   retarget to another FPGA vendor or an ASIC changes this file only.
// Overview:
//   * Simple dual port: one write port (wr_clk) and one read port (rd_clk),
//     common or independent clocks, synchronous read with READ_LATENCY output
//     registers (1 or 2). rd_data shows the word READ_LATENCY clocks after a
//     cycle with rd_en high and holds until the next read. rd_resetn
//     (synchronous, active low) clears the output to zero; the storage array
//     is not reset. With READ_LATENCY = 2 the second stage advances only one
//     clock after a read, so the output is zero after reset until a new read
//     completes, on every technology.
//   * The technology is `RTLNET_TARGET from rtlnet_technology.svh (no
//     parameter). RAM_STYLE ("block" default, or "distributed") is chosen per
//     instance.
//   * AMD: a direct instance of xpm_memory_sdpram with MEMORY_PRIMITIVE =
//     RAM_STYLE.
//   * ALTERA: inferred array carrying Quartus ramstyle (M20K / MLAB).
//   * LATTICE: inferred array carrying syn_ramstyle (block_ram / distributed)
//     for Synplify Pro / LSE.
//   * GENERIC: plain behavioural model (simulation, ASIC front end); an ASIC
//     flow replaces this branch with its compiled-macro wrapper.
//   * Read-during-write to the same address: the read returns the old word on
//     every target with RAM_STYLE "block" in INDEPENDENT mode, and is undefined
//     for callers; RTLNet cores never read a word in the cycle it is written.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks:
//   * wr_clk: write port domain.
//   * rd_clk: read port domain; equal to wr_clk when CLOCKING = "COMMON".
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_ram_core #(
  parameter string  RAM_STYLE    = "block",        // "block" | "distributed"
  parameter string  CLOCKING     = "INDEPENDENT",  // "COMMON" | "INDEPENDENT"
  parameter int     DATA_W       = 64,             // word width in bits
  parameter int     ADDR_W       = 9,              // depth = 2**ADDR_W words
  parameter int     READ_LATENCY = 1               // output registers, 1 or 2
)(
  // Write port, wr_clk domain: one word per wr_en cycle.
  input  logic              wr_clk,
  input  logic              wr_en,
  input  logic [ADDR_W-1:0] wr_addr,
  input  logic [DATA_W-1:0] wr_data,

  // Read port, rd_clk domain: rd_data is valid READ_LATENCY clocks after a
  // cycle with rd_en high and holds while rd_en is low. rd_resetn is
  // synchronous, active low, and clears the output register(s) only.
  input  logic              rd_clk,
  input  logic              rd_resetn,
  input  logic              rd_en,
  input  logic [ADDR_W-1:0] rd_addr,
  output logic [DATA_W-1:0] rd_data
);

  localparam string TARGET = `RTLNET_TARGET;
  localparam int    DEPTH  = 1 << ADDR_W;

  // Parameter legality is checked at elaboration so a bad build fails in
  // synthesis and in simulation alike (IEEE 1800-2012 clause 20.11).
  generate
    if (READ_LATENCY < 1 || READ_LATENCY > 2) begin : g_bad_latency
      $fatal(1, "rtlnet_ram_core: READ_LATENCY=%0d, must be 1 or 2", READ_LATENCY);
    end
    if (RAM_STYLE != "block" && RAM_STYLE != "distributed") begin : g_bad_style
      $fatal(1, "rtlnet_ram_core: RAM_STYLE=%s, must be \"block\" or \"distributed\"", RAM_STYLE);
    end
    if (CLOCKING != "COMMON" && CLOCKING != "INDEPENDENT") begin : g_bad_clocking
      $fatal(1, "rtlnet_ram_core: CLOCKING=%s, must be \"COMMON\" or \"INDEPENDENT\"", CLOCKING);
    end
    if (TARGET != "AMD" && TARGET != "ALTERA" && TARGET != "LATTICE" && TARGET != "GENERIC") begin : g_bad_target
      $fatal(1, "rtlnet_ram_core: TARGET=%s, must be AMD, ALTERA, LATTICE or GENERIC", TARGET);
    end
  endgenerate

  generate
    if (TARGET == "AMD") begin : g_amd
      // AMD/Xilinx: XPM simple-dual-port macro (UG974). The macro owns the
      // primitive mapping, the output register and its synchronous reset.
      // XPM takes Verilog string literals (packed vectors), not SystemVerilog
      // string-typed values: convert the three selections here.
      localparam [8*20-1:0] XPM_PRIMITIVE  = (RAM_STYLE == "distributed") ? "distributed" : "block";
      localparam [8*20-1:0] XPM_CLOCKING   = (CLOCKING == "COMMON") ? "common_clock" : "independent_clock";
      localparam [8*20-1:0] XPM_WRITE_MODE = (RAM_STYLE == "distributed") ? "read_first" : "no_change";

      logic rstb;
      logic regceb;
      assign rstb = !rd_resetn;

      // Final-stage enable: tied high at latency 1; at latency 2 the read
      // enable delayed one clock, so the second stage loads exactly once per
      // read and a reset-cleared output stays cleared.
      if (READ_LATENCY == 2) begin : g_regce
        logic rd_en_d;
        always_ff @(posedge (CLOCKING == "COMMON" ? wr_clk : rd_clk)) begin
          if (!rd_resetn) rd_en_d <= 1'b0;
          else            rd_en_d <= rd_en;
        end
        assign regceb = rd_en_d;
      end else begin : g_regce1
        assign regceb = 1'b1;
      end

      xpm_memory_sdpram #(
        .ADDR_WIDTH_A            (ADDR_W),
        .ADDR_WIDTH_B            (ADDR_W),
        .AUTO_SLEEP_TIME         (0),
        .BYTE_WRITE_WIDTH_A      (DATA_W),
        .CASCADE_HEIGHT          (0),
        .CLOCKING_MODE           (XPM_CLOCKING),
        .ECC_MODE                ("no_ecc"),
        .MEMORY_INIT_FILE        ("none"),
        .MEMORY_INIT_PARAM       ("0"),
        .MEMORY_OPTIMIZATION     ("true"),
        .MEMORY_PRIMITIVE        (XPM_PRIMITIVE),
        .MEMORY_SIZE             (DATA_W * DEPTH),
        .MESSAGE_CONTROL         (0),
        .READ_DATA_WIDTH_B       (DATA_W),
        .READ_LATENCY_B          (READ_LATENCY),
        .READ_RESET_VALUE_B      ("0"),
        .RST_MODE_A              ("SYNC"),
        .RST_MODE_B              ("SYNC"),
        .SIM_ASSERT_CHK          (0),
        .USE_EMBEDDED_CONSTRAINT (0),
        .USE_MEM_INIT            (0),
        .WAKEUP_TIME             ("disable_sleep"),
        .WRITE_DATA_WIDTH_A      (DATA_W),
        .WRITE_MODE_B            (XPM_WRITE_MODE)
      ) u_xpm (
        .clka           (wr_clk),
        .ena            (wr_en),
        .wea            (wr_en),
        .addra          (wr_addr),
        .dina           (wr_data),
        .injectsbiterra (1'b0),
        .injectdbiterra (1'b0),
        .clkb           (CLOCKING == "COMMON" ? wr_clk : rd_clk),
        .rstb           (rstb),
        .enb            (rd_en),
        .regceb         (regceb),
        .addrb          (rd_addr),
        .doutb          (rd_data),
        .sleep          (1'b0),
        .sbiterrb       (),
        .dbiterrb       ()
      );
    end else begin : g_inferred
      // Altera, Lattice and generic targets: an inferred array whose literal
      // attribute steers the mapping. The read port registers rd_q on rd_en.
      logic              rclk;
      logic [DATA_W-1:0] rd_q;

      assign rclk = (CLOCKING == "COMMON") ? wr_clk : rd_clk;

      if (TARGET == "ALTERA" && RAM_STYLE == "block") begin : g_altera_block
        (* ramstyle = "no_rw_check, M20K" *) logic [DATA_W-1:0] mem [0:DEPTH-1];
        always_ff @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
        always_ff @(posedge rclk) begin
          if (!rd_resetn) rd_q <= '0;
          else if (rd_en) rd_q <= mem[rd_addr];
        end
      end else if (TARGET == "ALTERA") begin : g_altera_dist
        (* ramstyle = "no_rw_check, MLAB" *) logic [DATA_W-1:0] mem [0:DEPTH-1];
        always_ff @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
        always_ff @(posedge rclk) begin
          if (!rd_resetn) rd_q <= '0;
          else if (rd_en) rd_q <= mem[rd_addr];
        end
      end else if (TARGET == "LATTICE" && RAM_STYLE == "block") begin : g_lattice_block
        (* syn_ramstyle = "block_ram" *) logic [DATA_W-1:0] mem [0:DEPTH-1];
        always_ff @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
        always_ff @(posedge rclk) begin
          if (!rd_resetn) rd_q <= '0;
          else if (rd_en) rd_q <= mem[rd_addr];
        end
      end else if (TARGET == "LATTICE") begin : g_lattice_dist
        (* syn_ramstyle = "distributed" *) logic [DATA_W-1:0] mem [0:DEPTH-1];
        always_ff @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
        always_ff @(posedge rclk) begin
          if (!rd_resetn) rd_q <= '0;
          else if (rd_en) rd_q <= mem[rd_addr];
        end
      end else begin : g_generic
        logic [DATA_W-1:0] mem [0:DEPTH-1];
        always_ff @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
        always_ff @(posedge rclk) begin
          if (!rd_resetn) rd_q <= '0;
          else if (rd_en) rd_q <= mem[rd_addr];
        end
      end

      // READ_LATENCY = 2: a second output register loaded one clock after
      // each read (the same behaviour as the AMD branch's regceb).
      if (READ_LATENCY == 2) begin : g_lat2
        logic [DATA_W-1:0] rd_q2;
        logic              rd_en_d;
        always_ff @(posedge rclk) begin
          if (!rd_resetn) begin
            rd_en_d <= 1'b0;
            rd_q2   <= '0;
          end else begin
            rd_en_d <= rd_en;
            if (rd_en_d) rd_q2 <= rd_q;
          end
        end
        assign rd_data = rd_q2;
      end else begin : g_lat1
        assign rd_data = rd_q;
      end
    end
  endgenerate

endmodule
