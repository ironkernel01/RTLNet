// -----------------------------------------------------------------------------
// File: rtlnet_axi_cdc.sv
// Purpose: carry a full AXI4 interface (bursts, IDs, strobes) from one clock to
//   an unrelated clock, any frequency ratio. The first user is the CPU cache
//   port (cpu_clk) into the DDR3 controller clock (ui_clk); the H.264 engine
//   DMA (150 MHz) uses the same core.
// Overview:
//   * Five channels, five rtlnet_packet_fifo instances: u_aw_fifo, u_w_fifo,
//     u_ar_fifo (slave clock to master clock) and u_b_fifo, u_r_fifo (master clock
//     to slave clock). The FIFO Gray frame counters and event toggles are the
//     only clock crossings; scripts/rtlnet_constrain_cdc.tcl bounds them by the
//     name u_*_fifo (class fifo). The core adds no other crossing and no
//     combinational path between the two clocks.
//   * A beat becomes a short frame of 64-bit words (72 payload bits per word,
//     {keep, data}) through rtlnet_axi_cdc_ser and is rebuilt after the FIFO by
//     rtlnet_axi_cdc_des, both in the clock of their side. AW, AR and B beats
//     are one-beat frames; the W frame ends on WLAST and the R frame on RLAST, so
//     a burst is committed to the other clock only when whole (store and
//     forward).
//   * Each channel is one in-order queue, so every ordering AXI requires per ID
//     (and across IDs) is kept; B and R return in the order the master side
//     slave answers.
//   * Sizing: MAX_BURST_BEATS is the longest burst in beats (AxLEN + 1) the core
//     carries. The W and R FIFOs hold at least two such bursts; a configuration
//     that cannot stops elaboration with $fatal. A longer burst is a sim $fatal
//     at AW or AR and, in hardware, would be dropped by the FIFO (not supported).
//   * Reset: the two resets must release from one assertion. A reset in
//     mid-traffic discards what is queued; an AXI master with an outstanding
//     transaction must be reset as well.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: s_clk (AXI4 slave side), m_clk (AXI4 master side); any frequencies,
//   any relation.
// -----------------------------------------------------------------------------
module rtlnet_axi_cdc #(
  parameter int    ADDR_W          = 29,            // address width
  parameter int    DATA_W          = 128,           // 32, 64 or 128
  parameter int    ID_W            = 2,             // ID width, at least 1
  parameter int    MAX_BURST_BEATS = 16,            // longest burst, 1..256 beats
  parameter string AW_RAM_STYLE    = "distributed", // "block" | "distributed" per FIFO
  parameter string W_RAM_STYLE     = "block",
  parameter string B_RAM_STYLE     = "distributed",
  parameter string AR_RAM_STYLE    = "distributed",
  parameter string R_RAM_STYLE     = "block",
  parameter int    AW_FIFO_KB      = 1,             // storage per FIFO, kilobytes (128 words per KB)
  parameter int    W_FIFO_KB       = 1,
  parameter int    B_FIFO_KB       = 1,
  parameter int    AR_FIFO_KB      = 1,
  parameter int    R_FIFO_KB       = 1
)(
  // AXI4 slave, s_clk domain.
  input  logic                  s_clk,
  input  logic                  s_resetn,          // synchronous to s_clk, active low
  input  logic [ID_W-1:0]       s_axi_awid,
  input  logic [ADDR_W-1:0]     s_axi_awaddr,
  input  logic [7:0]            s_axi_awlen,
  input  logic [2:0]            s_axi_awsize,
  input  logic [1:0]            s_axi_awburst,
  input  logic                  s_axi_awlock,
  input  logic [3:0]            s_axi_awcache,
  input  logic [2:0]            s_axi_awprot,
  input  logic [3:0]            s_axi_awqos,
  input  logic                  s_axi_awvalid,
  output logic                  s_axi_awready,
  input  logic [DATA_W-1:0]     s_axi_wdata,
  input  logic [DATA_W/8-1:0]   s_axi_wstrb,
  input  logic                  s_axi_wlast,
  input  logic                  s_axi_wvalid,
  output logic                  s_axi_wready,
  output logic [ID_W-1:0]       s_axi_bid,
  output logic [1:0]            s_axi_bresp,
  output logic                  s_axi_bvalid,
  input  logic                  s_axi_bready,
  input  logic [ID_W-1:0]       s_axi_arid,
  input  logic [ADDR_W-1:0]     s_axi_araddr,
  input  logic [7:0]            s_axi_arlen,
  input  logic [2:0]            s_axi_arsize,
  input  logic [1:0]            s_axi_arburst,
  input  logic                  s_axi_arlock,
  input  logic [3:0]            s_axi_arcache,
  input  logic [2:0]            s_axi_arprot,
  input  logic [3:0]            s_axi_arqos,
  input  logic                  s_axi_arvalid,
  output logic                  s_axi_arready,
  output logic [ID_W-1:0]       s_axi_rid,
  output logic [DATA_W-1:0]     s_axi_rdata,
  output logic [1:0]            s_axi_rresp,
  output logic                  s_axi_rlast,
  output logic                  s_axi_rvalid,
  input  logic                  s_axi_rready,

  // AXI4 master, m_clk domain.
  input  logic                  m_clk,
  input  logic                  m_resetn,          // synchronous to m_clk, active low
  output logic [ID_W-1:0]       m_axi_awid,
  output logic [ADDR_W-1:0]     m_axi_awaddr,
  output logic [7:0]            m_axi_awlen,
  output logic [2:0]            m_axi_awsize,
  output logic [1:0]            m_axi_awburst,
  output logic                  m_axi_awlock,
  output logic [3:0]            m_axi_awcache,
  output logic [2:0]            m_axi_awprot,
  output logic [3:0]            m_axi_awqos,
  output logic                  m_axi_awvalid,
  input  logic                  m_axi_awready,
  output logic [DATA_W-1:0]     m_axi_wdata,
  output logic [DATA_W/8-1:0]   m_axi_wstrb,
  output logic                  m_axi_wlast,
  output logic                  m_axi_wvalid,
  input  logic                  m_axi_wready,
  input  logic [ID_W-1:0]       m_axi_bid,
  input  logic [1:0]            m_axi_bresp,
  input  logic                  m_axi_bvalid,
  output logic                  m_axi_bready,
  output logic [ID_W-1:0]       m_axi_arid,
  output logic [ADDR_W-1:0]     m_axi_araddr,
  output logic [7:0]            m_axi_arlen,
  output logic [2:0]            m_axi_arsize,
  output logic [1:0]            m_axi_arburst,
  output logic                  m_axi_arlock,
  output logic [3:0]            m_axi_arcache,
  output logic [2:0]            m_axi_arprot,
  output logic [3:0]            m_axi_arqos,
  output logic                  m_axi_arvalid,
  input  logic                  m_axi_arready,
  input  logic [ID_W-1:0]       m_axi_rid,
  input  logic [DATA_W-1:0]     m_axi_rdata,
  input  logic [1:0]            m_axi_rresp,
  input  logic                  m_axi_rlast,
  input  logic                  m_axi_rvalid,
  output logic                  m_axi_rready
);

  // ---------------------------------------------------------------------------
  // Geometry: beat widths, words per beat, frame sizes
  // ---------------------------------------------------------------------------
  localparam int A_BITS = ID_W + ADDR_W + 8 + 3 + 2 + 1 + 4 + 3 + 4;   // {id, addr, len, size, burst, lock, cache, prot, qos}
  localparam int W_BITS = DATA_W + DATA_W / 8;                         // {strb, data}
  localparam int B_BITS = ID_W + 2;                                    // {id, resp}
  localparam int R_BITS = ID_W + 2 + DATA_W;                           // {id, resp, data}
  localparam int A_WORDS = (A_BITS + 71) / 72;
  localparam int W_WORDS = (W_BITS + 71) / 72;
  localparam int B_WORDS = (B_BITS + 71) / 72;
  localparam int R_WORDS = (R_BITS + 71) / 72;

  // Largest frame of each FIFO in bytes (the packet FIFO rounds a slot up to a power of two words).
  localparam int A_FRAME_BYTES = 8 * ((A_WORDS > 2) ? A_WORDS : 2);
  localparam int B_FRAME_BYTES = 8 * ((B_WORDS > 2) ? B_WORDS : 2);
  localparam int W_FRAME_BYTES = 8 * W_WORDS * MAX_BURST_BEATS;
  localparam int R_FRAME_BYTES = 8 * R_WORDS * MAX_BURST_BEATS;

  localparam int W_SLOT_WORDS = 1 << rtlnet_pkg::clog2i(W_WORDS * MAX_BURST_BEATS);
  localparam int R_SLOT_WORDS = 1 << rtlnet_pkg::clog2i(R_WORDS * MAX_BURST_BEATS);

  generate
    if (DATA_W != 32 && DATA_W != 64 && DATA_W != 128) begin : g_bad_data_w
      $fatal(1, "rtlnet_axi_cdc: DATA_W=%0d, need 32, 64 or 128", DATA_W);
    end
    if (ID_W < 1 || ID_W > 32) begin : g_bad_id_w
      $fatal(1, "rtlnet_axi_cdc: ID_W=%0d, need 1..32", ID_W);
    end
    if (MAX_BURST_BEATS < 1 || MAX_BURST_BEATS > 256) begin : g_bad_burst
      $fatal(1, "rtlnet_axi_cdc: MAX_BURST_BEATS=%0d, need 1..256", MAX_BURST_BEATS);
    end
    if (W_FIFO_KB * 128 < 2 * W_SLOT_WORDS) begin : g_small_w
      $fatal(1, "rtlnet_axi_cdc: W_FIFO_KB=%0d holds %0d words; a %0d-beat burst needs a %0d-word slot and two slots",
             W_FIFO_KB, W_FIFO_KB * 128, MAX_BURST_BEATS, W_SLOT_WORDS);
    end
    if (R_FIFO_KB * 128 < 2 * R_SLOT_WORDS) begin : g_small_r
      $fatal(1, "rtlnet_axi_cdc: R_FIFO_KB=%0d holds %0d words; a %0d-beat burst needs a %0d-word slot and two slots",
             R_FIFO_KB, R_FIFO_KB * 128, MAX_BURST_BEATS, R_SLOT_WORDS);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // AW: s_clk beat -> words -> u_aw_fifo -> m_clk beat
  // ---------------------------------------------------------------------------
  logic        aw_s_valid, aw_s_ready, aw_s_last;
  logic [63:0] aw_s_data;
  logic [7:0]  aw_s_keep;
  logic        aw_m_valid, aw_m_ready, aw_m_last;
  logic [63:0] aw_m_data;
  logic [7:0]  aw_m_keep;
  logic [A_BITS-1:0] aw_m_beat;
  logic        aw_ovf, aw_bad;

  rtlnet_axi_cdc_ser #(.BITS(A_BITS), .WORDS(A_WORDS)) u_aw_ser (
    .clk       (s_clk),
    .resetn    (s_resetn),
    .in_valid  (s_axi_awvalid),
    .in_ready  (s_axi_awready),
    .in_data   ({s_axi_awid, s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awburst, s_axi_awlock,
                 s_axi_awcache, s_axi_awprot, s_axi_awqos}),
    .in_last   (1'b1),
    .out_valid (aw_s_valid),
    .out_ready (aw_s_ready),
    .out_data  (aw_s_data),
    .out_keep  (aw_s_keep),
    .out_last  (aw_s_last)
  );

  rtlnet_packet_fifo #(
    .RAM_STYLE       (AW_RAM_STYLE),
    .FIFO_KB         (AW_FIFO_KB),
    .MAX_FRAME_BYTES (A_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_aw_fifo (
    .s_clk     (s_clk),
    .s_resetn  (s_resetn),
    .s_data    (aw_s_data),
    .s_keep    (aw_s_keep),
    .s_valid   (aw_s_valid),
    .s_ready   (aw_s_ready),
    .s_last    (aw_s_last),
    .s_bad     (1'b0),
    .m_clk     (m_clk),
    .m_resetn  (m_resetn),
    .m_data    (aw_m_data),
    .m_keep    (aw_m_keep),
    .m_valid   (aw_m_valid),
    .m_ready   (aw_m_ready),
    .m_last    (aw_m_last),
    .overflow  (aw_ovf),
    .bad_frame (aw_bad)
  );

  rtlnet_axi_cdc_des #(.BITS(A_BITS), .WORDS(A_WORDS)) u_aw_des (
    .clk       (m_clk),
    .resetn    (m_resetn),
    .in_valid  (aw_m_valid),
    .in_ready  (aw_m_ready),
    .in_data   (aw_m_data),
    .in_keep   (aw_m_keep),
    .in_last   (aw_m_last),
    .out_valid (m_axi_awvalid),
    .out_ready (m_axi_awready),
    .out_data  (aw_m_beat),
    .out_last  ()
  );

  assign {m_axi_awid, m_axi_awaddr, m_axi_awlen, m_axi_awsize, m_axi_awburst, m_axi_awlock,
          m_axi_awcache, m_axi_awprot, m_axi_awqos} = aw_m_beat;

  // ---------------------------------------------------------------------------
  // W: s_clk beat -> words (frame ends on WLAST) -> u_w_fifo -> m_clk beat
  // ---------------------------------------------------------------------------
  logic        w_s_valid, w_s_ready, w_s_last;
  logic [63:0] w_s_data;
  logic [7:0]  w_s_keep;
  logic        w_m_valid, w_m_ready, w_m_last;
  logic [63:0] w_m_data;
  logic [7:0]  w_m_keep;
  logic [W_BITS-1:0] w_m_beat;
  logic        w_ovf, w_bad;

  rtlnet_axi_cdc_ser #(.BITS(W_BITS), .WORDS(W_WORDS)) u_w_ser (
    .clk       (s_clk),
    .resetn    (s_resetn),
    .in_valid  (s_axi_wvalid),
    .in_ready  (s_axi_wready),
    .in_data   ({s_axi_wstrb, s_axi_wdata}),
    .in_last   (s_axi_wlast),
    .out_valid (w_s_valid),
    .out_ready (w_s_ready),
    .out_data  (w_s_data),
    .out_keep  (w_s_keep),
    .out_last  (w_s_last)
  );

  rtlnet_packet_fifo #(
    .RAM_STYLE       (W_RAM_STYLE),
    .FIFO_KB         (W_FIFO_KB),
    .MAX_FRAME_BYTES (W_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_w_fifo (
    .s_clk     (s_clk),
    .s_resetn  (s_resetn),
    .s_data    (w_s_data),
    .s_keep    (w_s_keep),
    .s_valid   (w_s_valid),
    .s_ready   (w_s_ready),
    .s_last    (w_s_last),
    .s_bad     (1'b0),
    .m_clk     (m_clk),
    .m_resetn  (m_resetn),
    .m_data    (w_m_data),
    .m_keep    (w_m_keep),
    .m_valid   (w_m_valid),
    .m_ready   (w_m_ready),
    .m_last    (w_m_last),
    .overflow  (w_ovf),
    .bad_frame (w_bad)
  );

  rtlnet_axi_cdc_des #(.BITS(W_BITS), .WORDS(W_WORDS)) u_w_des (
    .clk       (m_clk),
    .resetn    (m_resetn),
    .in_valid  (w_m_valid),
    .in_ready  (w_m_ready),
    .in_data   (w_m_data),
    .in_keep   (w_m_keep),
    .in_last   (w_m_last),
    .out_valid (m_axi_wvalid),
    .out_ready (m_axi_wready),
    .out_data  (w_m_beat),
    .out_last  (m_axi_wlast)
  );

  assign {m_axi_wstrb, m_axi_wdata} = w_m_beat;

  // ---------------------------------------------------------------------------
  // B: m_clk beat -> words -> u_b_fifo -> s_clk beat
  // ---------------------------------------------------------------------------
  logic        b_s_valid, b_s_ready, b_s_last;
  logic [63:0] b_s_data;
  logic [7:0]  b_s_keep;
  logic        b_m_valid, b_m_ready, b_m_last;
  logic [63:0] b_m_data;
  logic [7:0]  b_m_keep;
  logic [B_BITS-1:0] b_m_beat;
  logic        b_ovf, b_bad;

  rtlnet_axi_cdc_ser #(.BITS(B_BITS), .WORDS(B_WORDS)) u_b_ser (
    .clk       (m_clk),
    .resetn    (m_resetn),
    .in_valid  (m_axi_bvalid),
    .in_ready  (m_axi_bready),
    .in_data   ({m_axi_bid, m_axi_bresp}),
    .in_last   (1'b1),
    .out_valid (b_s_valid),
    .out_ready (b_s_ready),
    .out_data  (b_s_data),
    .out_keep  (b_s_keep),
    .out_last  (b_s_last)
  );

  // The B FIFO writes in m_clk and reads in s_clk: its "s" side is the master clock.
  rtlnet_packet_fifo #(
    .RAM_STYLE       (B_RAM_STYLE),
    .FIFO_KB         (B_FIFO_KB),
    .MAX_FRAME_BYTES (B_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_b_fifo (
    .s_clk     (m_clk),
    .s_resetn  (m_resetn),
    .s_data    (b_s_data),
    .s_keep    (b_s_keep),
    .s_valid   (b_s_valid),
    .s_ready   (b_s_ready),
    .s_last    (b_s_last),
    .s_bad     (1'b0),
    .m_clk     (s_clk),
    .m_resetn  (s_resetn),
    .m_data    (b_m_data),
    .m_keep    (b_m_keep),
    .m_valid   (b_m_valid),
    .m_ready   (b_m_ready),
    .m_last    (b_m_last),
    .overflow  (b_ovf),
    .bad_frame (b_bad)
  );

  rtlnet_axi_cdc_des #(.BITS(B_BITS), .WORDS(B_WORDS)) u_b_des (
    .clk       (s_clk),
    .resetn    (s_resetn),
    .in_valid  (b_m_valid),
    .in_ready  (b_m_ready),
    .in_data   (b_m_data),
    .in_keep   (b_m_keep),
    .in_last   (b_m_last),
    .out_valid (s_axi_bvalid),
    .out_ready (s_axi_bready),
    .out_data  (b_m_beat),
    .out_last  ()
  );

  assign {s_axi_bid, s_axi_bresp} = b_m_beat;

  // ---------------------------------------------------------------------------
  // AR: s_clk beat -> words -> u_ar_fifo -> m_clk beat
  // ---------------------------------------------------------------------------
  logic        ar_s_valid, ar_s_ready, ar_s_last;
  logic [63:0] ar_s_data;
  logic [7:0]  ar_s_keep;
  logic        ar_m_valid, ar_m_ready, ar_m_last;
  logic [63:0] ar_m_data;
  logic [7:0]  ar_m_keep;
  logic [A_BITS-1:0] ar_m_beat;
  logic        ar_ovf, ar_bad;

  rtlnet_axi_cdc_ser #(.BITS(A_BITS), .WORDS(A_WORDS)) u_ar_ser (
    .clk       (s_clk),
    .resetn    (s_resetn),
    .in_valid  (s_axi_arvalid),
    .in_ready  (s_axi_arready),
    .in_data   ({s_axi_arid, s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arburst, s_axi_arlock,
                 s_axi_arcache, s_axi_arprot, s_axi_arqos}),
    .in_last   (1'b1),
    .out_valid (ar_s_valid),
    .out_ready (ar_s_ready),
    .out_data  (ar_s_data),
    .out_keep  (ar_s_keep),
    .out_last  (ar_s_last)
  );

  rtlnet_packet_fifo #(
    .RAM_STYLE       (AR_RAM_STYLE),
    .FIFO_KB         (AR_FIFO_KB),
    .MAX_FRAME_BYTES (A_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_ar_fifo (
    .s_clk     (s_clk),
    .s_resetn  (s_resetn),
    .s_data    (ar_s_data),
    .s_keep    (ar_s_keep),
    .s_valid   (ar_s_valid),
    .s_ready   (ar_s_ready),
    .s_last    (ar_s_last),
    .s_bad     (1'b0),
    .m_clk     (m_clk),
    .m_resetn  (m_resetn),
    .m_data    (ar_m_data),
    .m_keep    (ar_m_keep),
    .m_valid   (ar_m_valid),
    .m_ready   (ar_m_ready),
    .m_last    (ar_m_last),
    .overflow  (ar_ovf),
    .bad_frame (ar_bad)
  );

  rtlnet_axi_cdc_des #(.BITS(A_BITS), .WORDS(A_WORDS)) u_ar_des (
    .clk       (m_clk),
    .resetn    (m_resetn),
    .in_valid  (ar_m_valid),
    .in_ready  (ar_m_ready),
    .in_data   (ar_m_data),
    .in_keep   (ar_m_keep),
    .in_last   (ar_m_last),
    .out_valid (m_axi_arvalid),
    .out_ready (m_axi_arready),
    .out_data  (ar_m_beat),
    .out_last  ()
  );

  assign {m_axi_arid, m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst, m_axi_arlock,
          m_axi_arcache, m_axi_arprot, m_axi_arqos} = ar_m_beat;

  // ---------------------------------------------------------------------------
  // R: m_clk beat -> words (frame ends on RLAST) -> u_r_fifo -> s_clk beat
  // ---------------------------------------------------------------------------
  logic        r_s_valid, r_s_ready, r_s_last;
  logic [63:0] r_s_data;
  logic [7:0]  r_s_keep;
  logic        r_m_valid, r_m_ready, r_m_last;
  logic [63:0] r_m_data;
  logic [7:0]  r_m_keep;
  logic [R_BITS-1:0] r_m_beat;
  logic        r_ovf, r_bad;

  rtlnet_axi_cdc_ser #(.BITS(R_BITS), .WORDS(R_WORDS)) u_r_ser (
    .clk       (m_clk),
    .resetn    (m_resetn),
    .in_valid  (m_axi_rvalid),
    .in_ready  (m_axi_rready),
    .in_data   ({m_axi_rid, m_axi_rresp, m_axi_rdata}),
    .in_last   (m_axi_rlast),
    .out_valid (r_s_valid),
    .out_ready (r_s_ready),
    .out_data  (r_s_data),
    .out_keep  (r_s_keep),
    .out_last  (r_s_last)
  );

  rtlnet_packet_fifo #(
    .RAM_STYLE       (R_RAM_STYLE),
    .FIFO_KB         (R_FIFO_KB),
    .MAX_FRAME_BYTES (R_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_r_fifo (
    .s_clk     (m_clk),
    .s_resetn  (m_resetn),
    .s_data    (r_s_data),
    .s_keep    (r_s_keep),
    .s_valid   (r_s_valid),
    .s_ready   (r_s_ready),
    .s_last    (r_s_last),
    .s_bad     (1'b0),
    .m_clk     (s_clk),
    .m_resetn  (s_resetn),
    .m_data    (r_m_data),
    .m_keep    (r_m_keep),
    .m_valid   (r_m_valid),
    .m_ready   (r_m_ready),
    .m_last    (r_m_last),
    .overflow  (r_ovf),
    .bad_frame (r_bad)
  );

  rtlnet_axi_cdc_des #(.BITS(R_BITS), .WORDS(R_WORDS)) u_r_des (
    .clk       (s_clk),
    .resetn    (s_resetn),
    .in_valid  (r_m_valid),
    .in_ready  (r_m_ready),
    .in_data   (r_m_data),
    .in_keep   (r_m_keep),
    .in_last   (r_m_last),
    .out_valid (s_axi_rvalid),
    .out_ready (s_axi_rready),
    .out_data  (r_m_beat),
    .out_last  (s_axi_rlast)
  );

  assign {s_axi_rid, s_axi_rresp, s_axi_rdata} = r_m_beat;

  // ---------------------------------------------------------------------------
  // Simulation-only checks: a frame the FIFO had to drop (burst longer than
  // MAX_BURST_BEATS, or a W/R frame with a misplaced LAST) and a burst longer
  // than the sized maximum are fatal.
  // ---------------------------------------------------------------------------
  // synthesis translate_off
  always @(posedge s_clk) begin
    if (s_resetn && s_axi_awvalid && s_axi_awready && (int'(s_axi_awlen) + 1 > MAX_BURST_BEATS))
      $fatal(1, "%m: AW burst of %0d beats exceeds MAX_BURST_BEATS=%0d", int'(s_axi_awlen) + 1, MAX_BURST_BEATS);
    if (s_resetn && s_axi_arvalid && s_axi_arready && (int'(s_axi_arlen) + 1 > MAX_BURST_BEATS))
      $fatal(1, "%m: AR burst of %0d beats exceeds MAX_BURST_BEATS=%0d", int'(s_axi_arlen) + 1, MAX_BURST_BEATS);
    if (s_resetn && (b_ovf || b_bad || r_ovf || r_bad))
      $fatal(1, "%m: B or R FIFO dropped a frame (overflow %b%b, bad %b%b)", b_ovf, r_ovf, b_bad, r_bad);
  end
  always @(posedge m_clk) begin
    if (m_resetn && (aw_ovf || aw_bad || w_ovf || w_bad || ar_ovf || ar_bad))
      $fatal(1, "%m: AW, W or AR FIFO dropped a frame (overflow %b%b%b, bad %b%b%b)",
             aw_ovf, w_ovf, ar_ovf, aw_bad, w_bad, ar_bad);
  end
  // synthesis translate_on

endmodule
