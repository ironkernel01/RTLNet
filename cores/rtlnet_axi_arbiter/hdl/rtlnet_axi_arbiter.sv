// -----------------------------------------------------------------------------
// File: rtlnet_axi_arbiter.sv
// Purpose: N:1 AXI4 arbiter in front of the DDR3 memory controller
//   (documentation/gige.md sections 5.1, 6, 7). Masters (capture write DMA,
//   encoder DMAs, CPU caches) share the one memory-controller AXI port.
// Overview:
//   * All data ports run on clk (the controller user clock). Ports are packed
//     vectors, master i at [i*W +: W]. The master-port ID is ID_W + IDX_W bits
//     wide, IDX_W = max(1, clog2(NUM_MASTERS)), master index in the upper bits.
//   * Write path: AW arbitration per transaction (fixed priority group first,
//     lowest index wins; then round robin over the rest, the pointer moves past
//     each round-robin grant). The granted AW is registered into the master-side
//     AW port with the index added to its ID, and its index is pushed into the
//     W-order queue (depth MAX_OUTSTANDING). The W channel is connected to the
//     master at the head of that queue until its WLAST beat; no W interleaving.
//     A grant waits while the queue is full or MAX_OUTSTANDING writes are in
//     flight. B is routed by the upper ID bits and returned with the original ID.
//   * Read path: independent AR arbitration with the same policy and limit; R
//     beats are routed by the upper ID bits and returned with the original ID.
//   * Burst legality, checked on each granted AW and AR: burst INCR, size equal
//     to the full data width (any size up to the full width for a master whose
//     NARROW_MASK bit is set, such as a write-through CPU cache), no 4 KiB
//     boundary crossing computed from the burst's own size, from the start address
//     aligned down to that size (an unaligned INCR start is legal). A master whose
//     WRAP_MASK bit is set may also issue a WRAP burst of 2, 4, 8 or 16 beats
//     at an address aligned to the size (a cache line fill, critical word first);
//     it is forwarded unchanged and the memory controller applies the wrap. A
//     legal WRAP never crosses 4 KiB: its container is at most 16 beats * 16 bytes
//     = 256 bytes, a power of two aligned to its own size, so the container lies
//     inside one 4 KiB page; the 4 KiB rule therefore does not apply to a WRAP.
//     Any other WRAP (master not in WRAP_MASK, length not 2/4/8/16, misaligned
//     start) is illegal. An illegal burst is
//     not forwarded. The arbiter answers it after every earlier transaction of
//     that master in the same direction has completed: a write accepts and
//     discards W beats up to WLAST and returns BRESP SLVERR; a read returns
//     len + 1 beats with RRESP SLVERR, RDATA 0, RLAST on the last. Until the
//     answer is delivered the master's further AW (AR) are not arbitrated, so
//     same-ID order holds. Each illegal burst counts in the master's ERRORS
//     register and sets the sticky STATUS.ERR (err_irq). The first illegal burst
//     after a clear is also captured (direction, master, address, len, size,
//     burst type and which rule failed) in read-only registers that hold it until
//     CTRL.CNT_CLEAR or a STATUS.ERR clear.
//   * Overflow and underflow of every queue and counter are gated in logic; a
//     simulation check reports an attempt (fpga.md section 9).
//   * Registers on s_axi_aclk behind rtlnet_axil_cdc and rtlnet_axil_slave
//     (4 KiB window); rtlnet_axi_arbiter_regs holds the register file;
//     offsets in driver/rtlnet_axi_arbiter.h.
//   * The W-order queue is a shift queue in flops (depth 8 by default, head at
//     entry 0), deliberately not a RAM: it is a handful of bits read in the
//     same clock it is written.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
//   * 11-09-2026: NARROW_MASK parameter, narrow transfers for selected masters.
//   * 11-09-2026: WRAP_MASK parameter (legal WRAP bursts), sticky first-illegal-burst capture registers.
//   * 11-09-2026: 4 KiB rule measured from the size-aligned start (unaligned INCR start is legal).
// Clocks: clk (arbiter, datapath, register file); s_axi_aclk (AXI4-Lite slave
//   side of the register crossing only).
// -----------------------------------------------------------------------------
module rtlnet_axi_arbiter #(
  parameter int                     NUM_MASTERS     = 3,    // 1..8
  parameter int                     ADDR_W          = 32,
  parameter int                     DATA_W          = 128,  // 32, 64 or 128; beat = DATA_W/8 bytes
  parameter int                     ID_W            = 4,    // slave-side ID width; master side is ID_W + IDX_W
  parameter logic [NUM_MASTERS-1:0] HIGH_PRIO_MASK  = 'b1,  // masters that win over the round-robin group
  parameter logic [NUM_MASTERS-1:0] NARROW_MASK     = '0,   // masters that may issue sizes below the full width
  parameter logic [NUM_MASTERS-1:0] WRAP_MASK       = '0,   // masters that may issue legal WRAP bursts
  parameter int                     MAX_OUTSTANDING = 8,    // per direction, whole arbiter
  // Derived, not for override: master-index bits and the master-side ID width.
  localparam int                    IDX_W           = (NUM_MASTERS > 1) ? $clog2(NUM_MASTERS) : 1,
  localparam int                    MID_W           = ID_W + IDX_W
)(
  // Data clock (memory controller user clock, 100 MHz) and its reset
  // (synchronous, active low). The register clock and its reset (synchronous,
  // active low, released with resetn from the same assertion).
  input  logic                              clk,
  input  logic                              resetn,
  input  logic                              s_axi_aclk,
  input  logic                              s_axi_aresetn,

  // Master-facing AW channel, clk domain, one slice per master (AXI4, INCR
  // full-width bursts only; see the legality rules above).
  input  logic [NUM_MASTERS*ID_W-1:0]       s_awid,
  input  logic [NUM_MASTERS*ADDR_W-1:0]     s_awaddr,
  input  logic [NUM_MASTERS*8-1:0]          s_awlen,
  input  logic [NUM_MASTERS*3-1:0]          s_awsize,
  input  logic [NUM_MASTERS*2-1:0]          s_awburst,
  input  logic [NUM_MASTERS-1:0]            s_awvalid,
  output logic [NUM_MASTERS-1:0]            s_awready,

  // Master-facing W channel, clk domain. Beats follow the AW order of the
  // arbiter (no W interleaving).
  input  logic [NUM_MASTERS*DATA_W-1:0]     s_wdata,
  input  logic [NUM_MASTERS*DATA_W/8-1:0]   s_wstrb,
  input  logic [NUM_MASTERS-1:0]            s_wlast,
  input  logic [NUM_MASTERS-1:0]            s_wvalid,
  output logic [NUM_MASTERS-1:0]            s_wready,

  // Master-facing B channel, clk domain: write response with the master's own ID.
  output logic [NUM_MASTERS*ID_W-1:0]       s_bid,
  output logic [NUM_MASTERS*2-1:0]          s_bresp,
  output logic [NUM_MASTERS-1:0]            s_bvalid,
  input  logic [NUM_MASTERS-1:0]            s_bready,

  // Master-facing AR channel, clk domain.
  input  logic [NUM_MASTERS*ID_W-1:0]       s_arid,
  input  logic [NUM_MASTERS*ADDR_W-1:0]     s_araddr,
  input  logic [NUM_MASTERS*8-1:0]          s_arlen,
  input  logic [NUM_MASTERS*3-1:0]          s_arsize,
  input  logic [NUM_MASTERS*2-1:0]          s_arburst,
  input  logic [NUM_MASTERS-1:0]            s_arvalid,
  output logic [NUM_MASTERS-1:0]            s_arready,

  // Master-facing R channel, clk domain: read data with the master's own ID.
  output logic [NUM_MASTERS*ID_W-1:0]       s_rid,
  output logic [NUM_MASTERS*DATA_W-1:0]     s_rdata,
  output logic [NUM_MASTERS*2-1:0]          s_rresp,
  output logic [NUM_MASTERS-1:0]            s_rlast,
  output logic [NUM_MASTERS-1:0]            s_rvalid,
  input  logic [NUM_MASTERS-1:0]            s_rready,

  // Memory-controller AW channel, clk domain: registered, ID widened by the
  // master index; lock, cache, prot and qos are constants (AWCACHE 4'b0011:
  // bufferable, modifiable).
  output logic [MID_W-1:0]                  m_axi_awid,
  output logic [ADDR_W-1:0]                 m_axi_awaddr,
  output logic [7:0]                        m_axi_awlen,
  output logic [2:0]                        m_axi_awsize,
  output logic [1:0]                        m_axi_awburst,
  output logic                              m_axi_awlock,
  output logic [3:0]                        m_axi_awcache,
  output logic [2:0]                        m_axi_awprot,
  output logic [3:0]                        m_axi_awqos,
  output logic                              m_axi_awvalid,
  input  logic                              m_axi_awready,

  // Memory-controller W channel, clk domain: the head master's beats; valid
  // is held until ready.
  output logic [DATA_W-1:0]                 m_axi_wdata,
  output logic [DATA_W/8-1:0]               m_axi_wstrb,
  output logic                              m_axi_wlast,
  output logic                              m_axi_wvalid,
  input  logic                              m_axi_wready,

  // Memory-controller B channel, clk domain: the ID carries the master index
  // in its upper bits.
  input  logic [MID_W-1:0]                  m_axi_bid,
  input  logic [1:0]                        m_axi_bresp,
  input  logic                              m_axi_bvalid,
  output logic                              m_axi_bready,

  // Memory-controller AR channel, clk domain: registered, ID widened, constants
  // as on AW.
  output logic [MID_W-1:0]                  m_axi_arid,
  output logic [ADDR_W-1:0]                 m_axi_araddr,
  output logic [7:0]                        m_axi_arlen,
  output logic [2:0]                        m_axi_arsize,
  output logic [1:0]                        m_axi_arburst,
  output logic                              m_axi_arlock,
  output logic [3:0]                        m_axi_arcache,
  output logic [2:0]                        m_axi_arprot,
  output logic [3:0]                        m_axi_arqos,
  output logic                              m_axi_arvalid,
  input  logic                              m_axi_arready,

  // Memory-controller R channel, clk domain.
  input  logic [MID_W-1:0]                  m_axi_rid,
  input  logic [DATA_W-1:0]                 m_axi_rdata,
  input  logic [1:0]                        m_axi_rresp,
  input  logic                              m_axi_rlast,
  input  logic                              m_axi_rvalid,
  output logic                              m_axi_rready,

  // AXI4-Lite register slave, s_axi_aclk domain, 12-bit byte address, 32-bit data.
  input  logic [11:0]                       s_axi_awaddr,
  input  logic                              s_axi_awvalid,
  output logic                              s_axi_awready,
  input  logic [31:0]                       s_axi_wdata,
  input  logic [3:0]                        s_axi_wstrb,
  input  logic                              s_axi_wvalid,
  output logic                              s_axi_wready,
  output logic [1:0]                        s_axi_bresp,
  output logic                              s_axi_bvalid,
  input  logic                              s_axi_bready,
  input  logic [11:0]                       s_axi_araddr,
  input  logic                              s_axi_arvalid,
  output logic                              s_axi_arready,
  output logic [31:0]                       s_axi_rdata,
  output logic [1:0]                        s_axi_rresp,
  output logic                              s_axi_rvalid,
  input  logic                              s_axi_rready,

  // Error interrupt, clk domain: level, high while STATUS.ERR is set.
  output logic                              err_irq
);

  // ---------------------------------------------------------------------------
  // Derived constants
  // ---------------------------------------------------------------------------
  localparam int STRB_W    = DATA_W / 8;
  localparam int SIZE_FULL  = $clog2(STRB_W);       // AxSIZE of a full-width beat
  localparam int CNT_W      = $clog2(MAX_OUTSTANDING + 1);

  localparam int BOUNDARY_BYTES = 4096;             // AXI burst boundary
  localparam int BOUNDARY_BITS  = 12;
  localparam int SPAN_W         = 14;               // offset + burst bytes, at most 4095 + 4096

  localparam logic [1:0] BURST_INCR  = 2'b01;
  localparam logic [1:0] BURST_WRAP  = 2'b10;
  localparam int         FAIL_BURST  = 0;           // failed-rule bits: burst type (also a bad WRAP)
  localparam int         FAIL_SIZE   = 1;           //   size
  localparam int         FAIL_4K     = 2;           //   4 KiB boundary
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam int         LEN_BIAS    = 1;           // AxLEN counts beats minus one

  localparam logic [3:0] CONST_CACHE = 4'b0011;     // bufferable, modifiable
  localparam logic [2:0] CONST_PROT  = 3'b000;
  localparam logic [3:0] CONST_QOS   = 4'b0000;

  generate
    if (NUM_MASTERS < 1 || NUM_MASTERS > 8) begin : g_bad_masters
      $fatal(1, "rtlnet_axi_arbiter: NUM_MASTERS=%0d, must be 1..8", NUM_MASTERS);
    end
    if (DATA_W != 32 && DATA_W != 64 && DATA_W != 128) begin : g_bad_data_w
      $fatal(1, "rtlnet_axi_arbiter: DATA_W=%0d, must be 32, 64 or 128", DATA_W);
    end
    if (ID_W < 1 || ID_W > 15) begin : g_bad_id_w
      $fatal(1, "rtlnet_axi_arbiter: ID_W=%0d, must be 1..15", ID_W);
    end
    if (MAX_OUTSTANDING < 1 || MAX_OUTSTANDING > 255) begin : g_bad_max
      $fatal(1, "rtlnet_axi_arbiter: MAX_OUTSTANDING=%0d, must be 1..255", MAX_OUTSTANDING);
    end
    if (ADDR_W < BOUNDARY_BITS || ADDR_W > 64) begin : g_bad_addr_w
      $fatal(1, "rtlnet_axi_arbiter: ADDR_W=%0d, must be 12..64", ADDR_W);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Arbitration functions
  // ---------------------------------------------------------------------------
  // Winner among the requests: the lowest-index high-priority master, else the
  // first round-robin master at or after ptr. Returns {found, index}.
  function automatic logic [IDX_W:0] pick(input logic [NUM_MASTERS-1:0] req, input logic [IDX_W-1:0] ptr);
    logic [NUM_MASTERS-1:0] hp_req;
    logic [NUM_MASTERS-1:0] rr_req;
    logic                   found;
    logic [IDX_W-1:0]       idx;
    int                     j;
    hp_req = req & HIGH_PRIO_MASK;
    rr_req = req & ~HIGH_PRIO_MASK;
    found  = 1'b0;
    idx    = '0;
    if (hp_req != '0) begin
      found = 1'b1;
      for (int i = NUM_MASTERS - 1; i >= 0; i--) begin
        if (hp_req[i]) idx = IDX_W'(i);
      end
    end else begin
      for (int k = NUM_MASTERS - 1; k >= 0; k--) begin
        j = (int'(ptr) + k) % NUM_MASTERS;
        if (rr_req[j]) begin
          found = 1'b1;
          idx   = IDX_W'(j);
        end
      end
    end
    return {found, idx};
  endfunction

  // Round-robin pointer after a grant: the master after the winner.
  function automatic logic [IDX_W-1:0] after_grant(input logic [IDX_W-1:0] idx);
    return (int'(idx) == NUM_MASTERS - 1) ? '0 : IDX_W'(int'(idx) + 1);
  endfunction

  // Failed-rule flags of a burst (all zero: legal), {4 KiB, size, burst type}.
  //   * burst type: not INCR, unless the master may WRAP (wrap_ok) and the burst is a
  //     WRAP of 2, 4, 8 or 16 beats at an address aligned to its size;
  //   * size: a full-width master must use the full-width size; a narrow master
  //     (NARROW_MASK) may use any size up to the full width;
  //   * 4 KiB (INCR): aligned_start + (len + 1) * bytes > 4096, bytes per beat from the
  //     burst's own size and aligned_start = addr[11:0] rounded down to the size. AXI
  //     (IHI 0022, burst address: the first beat may be unaligned, later beats are
  //     aligned to the transfer size) puts the bytes of an INCR burst between the
  //     aligned start and the end of its last beat, so an unaligned start does not add
  //     to the span: size 2, len 0 at 0xFFD is one legal beat (lanes by WSTRB).
  //     Not applied to a WRAP: a legal WRAP container is at most 256 bytes and
  //     aligned to its own size, so it cannot cross 4 KiB.
  function automatic logic [2:0] burst_fail(input logic [11:0] addr_low, input logic [7:0] len,
                                            input logic [2:0] size, input logic [1:0] burst,
                                            input logic narrow, input logic wrap_ok);
    logic [SPAN_W-1:0] bytes;
    logic [SPAN_W-1:0] span;
    logic [11:0]       start_aligned;
    logic              size_ok;
    logic              is_wrap;
    logic              wrap_len_ok;
    logic              aligned;
    logic              wrap_legal;
    logic [2:0]        f;
    bytes       = (SPAN_W'(len) + SPAN_W'(LEN_BIAS)) << size;
    start_aligned = addr_low & ~((12'd1 << size) - 12'd1);
    span        = SPAN_W'(start_aligned) + bytes;
    size_ok     = narrow ? (size <= 3'(SIZE_FULL)) : (size == 3'(SIZE_FULL));
    is_wrap     = (burst == BURST_WRAP);
    wrap_len_ok = (len == 8'd1) || (len == 8'd3) || (len == 8'd7) || (len == 8'd15);
    aligned     = ((addr_low & ((12'd1 << size) - 12'd1)) == 12'd0);
    wrap_legal  = wrap_ok && is_wrap && wrap_len_ok && aligned;
    f[FAIL_BURST] = !((burst == BURST_INCR) || wrap_legal);
    f[FAIL_SIZE]  = !size_ok;
    f[FAIL_4K]    = !is_wrap && (span > SPAN_W'(BOUNDARY_BYTES));
    return f;
  endfunction

  // ---------------------------------------------------------------------------
  // AXI4-Lite crossing, register strobes and counter events
  // ---------------------------------------------------------------------------
  logic [11:0] c_awaddr;
  logic        c_awvalid;
  logic        c_awready;
  logic [31:0] c_wdata;
  logic [3:0]  c_wstrb;
  logic        c_wvalid;
  logic        c_wready;
  logic [1:0]  c_bresp;
  logic        c_bvalid;
  logic        c_bready;
  logic [11:0] c_araddr;
  logic        c_arvalid;
  logic        c_arready;
  logic [31:0] c_rdata;
  logic [1:0]  c_rresp;
  logic        c_rvalid;
  logic        c_rready;
  logic        reg_wr_en;
  logic [11:0] reg_wr_addr;
  logic [31:0] reg_wr_data;
  logic        reg_rd_en;
  logic [11:0] reg_rd_addr;
  logic [31:0] reg_rd_data;

  logic [NUM_MASTERS-1:0] ev_aw_burst;
  logic [NUM_MASTERS-1:0] ev_ar_burst;
  logic [NUM_MASTERS-1:0] ev_w_beat;
  logic [NUM_MASTERS-1:0] ev_r_beat;
  logic [NUM_MASTERS-1:0] ev_err_wr;
  logic [NUM_MASTERS-1:0] ev_err_rd;
  logic [NUM_MASTERS-1:0] ev_wait;
  logic                   wr_busy;
  logic                   rd_busy;
  logic                   cap_ev;
  logic                   cap_dir;
  logic [IDX_W-1:0]       cap_idx;
  logic [2:0]             cap_master;
  logic [63:0]            cap_addr;
  logic [7:0]             cap_len;
  logic [2:0]             cap_size;
  logic [1:0]             cap_burst;
  logic [2:0]             cap_fail;

  // ---------------------------------------------------------------------------
  // Write path state
  // ---------------------------------------------------------------------------
  logic [NUM_MASTERS-1:0] aw_req;
  logic                   aw_found;
  logic [IDX_W-1:0]       aw_idx;
  logic [IDX_W-1:0]       aw_rr;
  logic                   aw_space;
  logic                   aw_slot_free;
  logic                   aw_fire;
  logic                   aw_fire_legal;
  logic                   aw_fire_ill;
  logic                   aw_legal;
  logic [2:0]             aw_fail;
  logic [ID_W-1:0]        g_awid;
  logic [ADDR_W-1:0]      g_awaddr;
  logic [7:0]             g_awlen;
  logic [2:0]             g_awsize;
  logic [1:0]             g_awburst;

  logic [CNT_W-1:0]       wr_inflight;
  logic [CNT_W-1:0]       wr_pend       [NUM_MASTERS];
  logic [NUM_MASTERS-1:0] wr_err_pend;
  logic [NUM_MASTERS-1:0] wr_err_wdone;
  logic [ID_W-1:0]        err_awid      [NUM_MASTERS];
  logic [NUM_MASTERS-1:0] err_b_valid;

  logic [IDX_W-1:0]       wq_idx        [MAX_OUTSTANDING];
  logic                   wq_ill        [MAX_OUTSTANDING];
  logic [CNT_W-1:0]       wq_count;
  logic                   wq_full;
  logic                   wq_nonempty;
  logic                   wq_push;
  logic                   wq_pop;
  logic [IDX_W-1:0]       w_head_idx;
  logic                   w_head_ill;
  logic [NUM_MASTERS-1:0] w_hs;

  logic [IDX_W-1:0]       b_idx;
  logic [NUM_MASTERS-1:0] b_sel;
  logic [NUM_MASTERS-1:0] b_hs;
  logic [NUM_MASTERS-1:0] err_b_hs;

  // ---------------------------------------------------------------------------
  // Read path state
  // ---------------------------------------------------------------------------
  logic [NUM_MASTERS-1:0] ar_req;
  logic                   ar_found;
  logic [IDX_W-1:0]       ar_idx;
  logic [IDX_W-1:0]       ar_rr;
  logic                   ar_space;
  logic                   ar_slot_free;
  logic                   ar_fire;
  logic                   ar_fire_legal;
  logic                   ar_fire_ill;
  logic                   ar_legal;
  logic [2:0]             ar_fail;
  logic [ID_W-1:0]        g_arid;
  logic [ADDR_W-1:0]      g_araddr;
  logic [7:0]             g_arlen;
  logic [2:0]             g_arsize;
  logic [1:0]             g_arburst;

  logic [CNT_W-1:0]       rd_inflight;
  logic [CNT_W-1:0]       rd_pend       [NUM_MASTERS];
  logic [NUM_MASTERS-1:0] rd_err_pend;
  logic [ID_W-1:0]        err_arid      [NUM_MASTERS];
  logic [7:0]             rd_err_left   [NUM_MASTERS];
  logic [NUM_MASTERS-1:0] err_r_valid;

  logic [IDX_W-1:0]       r_idx;
  logic [NUM_MASTERS-1:0] r_sel;
  logic [NUM_MASTERS-1:0] r_hs;
  logic [NUM_MASTERS-1:0] err_r_hs;

  // ---------------------------------------------------------------------------
  // Register access
  // ---------------------------------------------------------------------------
  // CPU clock -> clk crossing of whole AXI4-Lite transactions.
  rtlnet_axil_cdc #(.ADDR_W(12)) u_axil_cdc (
    .s_clk         (s_axi_aclk),
    .s_resetn      (s_axi_aresetn),
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
    .m_clk         (clk),
    .m_resetn      (resetn),
    .m_axi_awaddr  (c_awaddr),
    .m_axi_awvalid (c_awvalid),
    .m_axi_awready (c_awready),
    .m_axi_wdata   (c_wdata),
    .m_axi_wstrb   (c_wstrb),
    .m_axi_wvalid  (c_wvalid),
    .m_axi_wready  (c_wready),
    .m_axi_bresp   (c_bresp),
    .m_axi_bvalid  (c_bvalid),
    .m_axi_bready  (c_bready),
    .m_axi_araddr  (c_araddr),
    .m_axi_arvalid (c_arvalid),
    .m_axi_arready (c_arready),
    .m_axi_rdata   (c_rdata),
    .m_axi_rresp   (c_rresp),
    .m_axi_rvalid  (c_rvalid),
    .m_axi_rready  (c_rready)
  );

  // AXI4-Lite to register strobes in clk.
  rtlnet_axil_slave #(.ADDR_W(12)) u_axil_slave (
    .s_axi_aclk    (clk),
    .s_axi_aresetn (resetn),
    .s_axi_awaddr  (c_awaddr),
    .s_axi_awvalid (c_awvalid),
    .s_axi_awready (c_awready),
    .s_axi_wdata   (c_wdata),
    .s_axi_wstrb   (c_wstrb),
    .s_axi_wvalid  (c_wvalid),
    .s_axi_wready  (c_wready),
    .s_axi_bresp   (c_bresp),
    .s_axi_bvalid  (c_bvalid),
    .s_axi_bready  (c_bready),
    .s_axi_araddr  (c_araddr),
    .s_axi_arvalid (c_arvalid),
    .s_axi_arready (c_arready),
    .s_axi_rdata   (c_rdata),
    .s_axi_rresp   (c_rresp),
    .s_axi_rvalid  (c_rvalid),
    .s_axi_rready  (c_rready),
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data)
  );

  // Register file: ID/VERSION/CAPS, CTRL, STATUS, per-master counters.
  rtlnet_axi_arbiter_regs #(
    .NUM_MASTERS     (NUM_MASTERS),
    .DATA_W          (DATA_W),
    .ID_W            (ID_W),
    .MAX_OUTSTANDING (MAX_OUTSTANDING),
    .HIGH_PRIO_MASK  (HIGH_PRIO_MASK),
    .NARROW_MASK     (NARROW_MASK),
    .WRAP_MASK       (WRAP_MASK)
  ) u_regs (
    .clk         (clk),
    .resetn      (resetn),
    .reg_wr_en   (reg_wr_en),
    .reg_wr_addr (reg_wr_addr),
    .reg_wr_data (reg_wr_data),
    .reg_rd_en   (reg_rd_en),
    .reg_rd_addr (reg_rd_addr),
    .reg_rd_data (reg_rd_data),
    .ev_aw_burst (ev_aw_burst),
    .ev_ar_burst (ev_ar_burst),
    .ev_w_beat   (ev_w_beat),
    .ev_r_beat   (ev_r_beat),
    .ev_err_wr   (ev_err_wr),
    .ev_err_rd   (ev_err_rd),
    .ev_wait     (ev_wait),
    .wr_busy     (wr_busy),
    .rd_busy     (rd_busy),
    .cap_ev      (cap_ev),
    .cap_dir     (cap_dir),
    .cap_master  (cap_master),
    .cap_addr    (cap_addr),
    .cap_len     (cap_len),
    .cap_size    (cap_size),
    .cap_burst   (cap_burst),
    .cap_fail    (cap_fail),
    .err_irq     (err_irq)
  );

  // First-illegal-burst capture source: the illegal AW, else the illegal AR when
  // both are granted in one clock (the AR is then counted but not captured).
  assign cap_ev    = aw_fire_ill || ar_fire_ill;
  assign cap_dir   = !aw_fire_ill;
  assign cap_idx   = aw_fire_ill ? aw_idx : ar_idx;
  assign cap_master = 3'(cap_idx);
  assign cap_addr  = 64'(aw_fire_ill ? g_awaddr : g_araddr);
  assign cap_len   = aw_fire_ill ? g_awlen : g_arlen;
  assign cap_size  = aw_fire_ill ? g_awsize : g_arsize;
  assign cap_burst = aw_fire_ill ? g_awburst : g_arburst;
  assign cap_fail  = aw_fire_ill ? aw_fail : ar_fail;

  // ---------------------------------------------------------------------------
  // Constant master-side outputs
  // ---------------------------------------------------------------------------
  assign m_axi_awlock  = 1'b0;
  assign m_axi_awcache = CONST_CACHE;
  assign m_axi_awprot  = CONST_PROT;
  assign m_axi_awqos   = CONST_QOS;
  assign m_axi_arlock  = 1'b0;
  assign m_axi_arcache = CONST_CACHE;
  assign m_axi_arprot  = CONST_PROT;
  assign m_axi_arqos   = CONST_QOS;

  // ---------------------------------------------------------------------------
  // Write path: AW arbitration
  // ---------------------------------------------------------------------------
  // A master whose illegal write is still unanswered is not arbitrated.
  always_comb begin
    for (int i = 0; i < NUM_MASTERS; i++) begin
      aw_req[i] = s_awvalid[i] && !wr_err_pend[i];
    end
  end

  assign {aw_found, aw_idx} = pick(aw_req, aw_rr);

  assign g_awid    = s_awid[aw_idx * ID_W +: ID_W];
  assign g_awaddr  = s_awaddr[aw_idx * ADDR_W +: ADDR_W];
  assign g_awlen   = s_awlen[aw_idx * 8 +: 8];
  assign g_awsize  = s_awsize[aw_idx * 3 +: 3];
  assign g_awburst = s_awburst[aw_idx * 2 +: 2];
  assign aw_fail   = burst_fail(g_awaddr[BOUNDARY_BITS-1:0], g_awlen, g_awsize, g_awburst, NARROW_MASK[aw_idx],
                                WRAP_MASK[aw_idx]);
  assign aw_legal  = (aw_fail == 3'b000);

  assign wq_full      = (wq_count == CNT_W'(MAX_OUTSTANDING));
  assign wq_nonempty  = (wq_count != '0);
  assign aw_space     = !wq_full && (wr_inflight != CNT_W'(MAX_OUTSTANDING));
  assign aw_slot_free = !m_axi_awvalid || m_axi_awready;
  assign aw_fire      = aw_found && aw_space && aw_slot_free;
  assign aw_fire_legal = aw_fire && aw_legal;
  assign aw_fire_ill   = aw_fire && !aw_legal;

  always_comb begin
    for (int i = 0; i < NUM_MASTERS; i++) begin
      s_awready[i]   = aw_fire && (aw_idx == IDX_W'(i));
      ev_aw_burst[i] = aw_fire_legal && (aw_idx == IDX_W'(i));
      ev_err_wr[i]   = aw_fire_ill && (aw_idx == IDX_W'(i));
    end
  end

  // Master-side AW register: loaded by a legal grant, released when accepted.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      m_axi_awvalid <= 1'b0;
      m_axi_awid    <= '0;
      m_axi_awaddr  <= '0;
      m_axi_awlen   <= '0;
      m_axi_awsize  <= '0;
      m_axi_awburst <= '0;
      aw_rr         <= '0;
    end else begin
      if (aw_fire_legal) begin
        m_axi_awvalid <= 1'b1;
        m_axi_awid    <= {aw_idx, g_awid};
        m_axi_awaddr  <= g_awaddr;
        m_axi_awlen   <= g_awlen;
        m_axi_awsize  <= g_awsize;
        m_axi_awburst <= g_awburst;
      end else if (m_axi_awready) begin
        m_axi_awvalid <= 1'b0;
      end
      if (aw_fire && !HIGH_PRIO_MASK[aw_idx]) aw_rr <= after_grant(aw_idx);
    end
  end

  // ---------------------------------------------------------------------------
  // Write path: W-order queue and W routing
  // ---------------------------------------------------------------------------
  assign wq_push    = aw_fire;
  assign w_head_idx = wq_idx[0];
  assign w_head_ill = wq_ill[0];

  // W beats of the head master: forwarded, or discarded for an illegal burst.
  always_comb begin
    m_axi_wvalid = 1'b0;
    m_axi_wdata  = '0;
    m_axi_wstrb  = '0;
    m_axi_wlast  = 1'b0;
    s_wready     = '0;
    if (wq_nonempty) begin
      for (int i = 0; i < NUM_MASTERS; i++) begin
        if (w_head_idx == IDX_W'(i)) begin
          if (w_head_ill) begin
            s_wready[i] = 1'b1;
          end else begin
            m_axi_wvalid = s_wvalid[i];
            m_axi_wdata  = s_wdata[i * DATA_W +: DATA_W];
            m_axi_wstrb  = s_wstrb[i * STRB_W +: STRB_W];
            m_axi_wlast  = s_wlast[i];
            s_wready[i]  = m_axi_wready;
          end
        end
      end
    end
  end

  always_comb begin
    for (int i = 0; i < NUM_MASTERS; i++) begin
      w_hs[i]      = s_wvalid[i] && s_wready[i];
      ev_w_beat[i] = w_hs[i] && !w_head_ill;
    end
  end

  assign wq_pop = |(w_hs & s_wlast);

  // W-order queue: shift queue, head at entry 0. Pushes and pops are guarded
  // here as well as at the AW grant, so a violation cannot corrupt it.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      wq_count <= '0;
      for (int k = 0; k < MAX_OUTSTANDING; k++) begin
        wq_idx[k] <= '0;
        wq_ill[k] <= 1'b0;
      end
    end else begin
      if (wq_pop && wq_nonempty) begin
        for (int k = 0; k < MAX_OUTSTANDING - 1; k++) begin
          wq_idx[k] <= wq_idx[k + 1];
          wq_ill[k] <= wq_ill[k + 1];
        end
      end
      if (wq_push && !wq_full) begin
        wq_idx[wq_count - ((wq_pop && wq_nonempty) ? CNT_W'(1) : CNT_W'(0))] <= aw_idx;
        wq_ill[wq_count - ((wq_pop && wq_nonempty) ? CNT_W'(1) : CNT_W'(0))] <= !aw_legal;
      end
      case ({(wq_push && !wq_full), (wq_pop && wq_nonempty)})
        2'b10:   wq_count <= wq_count + CNT_W'(1);
        2'b01:   wq_count <= wq_count - CNT_W'(1);
        default: wq_count <= wq_count;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Write path: B routing, per-master pending counts, illegal-write answers
  // ---------------------------------------------------------------------------
  assign b_idx = m_axi_bid[ID_W +: IDX_W];

  always_comb begin
    m_axi_bready = 1'b0;
    for (int i = 0; i < NUM_MASTERS; i++) begin
      // The illegal answer needs its W beats discarded and every earlier legal
      // write of the master answered; the master's AW is blocked meanwhile, so
      // no legal B can arrive for it at the same time.
      err_b_valid[i] = wr_err_pend[i] && wr_err_wdone[i] && (wr_pend[i] == '0);
      b_sel[i]       = m_axi_bvalid && (b_idx == IDX_W'(i));
      b_hs[i]        = b_sel[i] && s_bready[i];
      err_b_hs[i]    = err_b_valid[i] && s_bready[i];
      s_bvalid[i]    = b_sel[i] || err_b_valid[i];
      s_bid[i * ID_W +: ID_W]   = err_b_valid[i] ? err_awid[i] : m_axi_bid[ID_W-1:0];
      s_bresp[i * 2 +: 2]       = err_b_valid[i] ? RESP_SLVERR : m_axi_bresp;
      if (b_idx == IDX_W'(i)) m_axi_bready = s_bready[i];
    end
  end

  // Pending writes per master and in flight in total (forwarded writes only).
  always_ff @(posedge clk) begin
    if (!resetn) begin
      wr_inflight  <= '0;
      wr_err_pend  <= '0;
      wr_err_wdone <= '0;
      for (int i = 0; i < NUM_MASTERS; i++) begin
        wr_pend[i]  <= '0;
        err_awid[i] <= '0;
      end
    end else begin
      case ({(aw_fire_legal && (wr_inflight != CNT_W'(MAX_OUTSTANDING))), (m_axi_bvalid && m_axi_bready &&
                                                                         (wr_inflight != '0))})
        2'b10:   wr_inflight <= wr_inflight + CNT_W'(1);
        2'b01:   wr_inflight <= wr_inflight - CNT_W'(1);
        default: wr_inflight <= wr_inflight;
      endcase
      for (int i = 0; i < NUM_MASTERS; i++) begin
        case ({(ev_aw_burst[i] && (wr_pend[i] != CNT_W'(MAX_OUTSTANDING))), (b_hs[i] && (wr_pend[i] != '0))})
          2'b10:   wr_pend[i] <= wr_pend[i] + CNT_W'(1);
          2'b01:   wr_pend[i] <= wr_pend[i] - CNT_W'(1);
          default: wr_pend[i] <= wr_pend[i];
        endcase
        if (ev_err_wr[i]) begin
          wr_err_pend[i] <= 1'b1;
          err_awid[i]    <= g_awid;
        end
        if (wq_pop && w_head_ill && (w_head_idx == IDX_W'(i))) wr_err_wdone[i] <= 1'b1;
        if (err_b_hs[i]) begin
          wr_err_pend[i]  <= 1'b0;
          wr_err_wdone[i] <= 1'b0;
        end
      end
    end
  end

  assign wr_busy = (wr_inflight != '0) || (wr_err_pend != '0);

  // ---------------------------------------------------------------------------
  // Read path: AR arbitration
  // ---------------------------------------------------------------------------
  always_comb begin
    for (int i = 0; i < NUM_MASTERS; i++) begin
      ar_req[i] = s_arvalid[i] && !rd_err_pend[i];
    end
  end

  assign {ar_found, ar_idx} = pick(ar_req, ar_rr);

  assign g_arid    = s_arid[ar_idx * ID_W +: ID_W];
  assign g_araddr  = s_araddr[ar_idx * ADDR_W +: ADDR_W];
  assign g_arlen   = s_arlen[ar_idx * 8 +: 8];
  assign g_arsize  = s_arsize[ar_idx * 3 +: 3];
  assign g_arburst = s_arburst[ar_idx * 2 +: 2];
  assign ar_fail   = burst_fail(g_araddr[BOUNDARY_BITS-1:0], g_arlen, g_arsize, g_arburst, NARROW_MASK[ar_idx],
                                WRAP_MASK[ar_idx]);
  assign ar_legal  = (ar_fail == 3'b000);

  assign ar_space      = (rd_inflight != CNT_W'(MAX_OUTSTANDING));
  assign ar_slot_free  = !m_axi_arvalid || m_axi_arready;
  assign ar_fire       = ar_found && ar_space && ar_slot_free;
  assign ar_fire_legal = ar_fire && ar_legal;
  assign ar_fire_ill   = ar_fire && !ar_legal;

  always_comb begin
    for (int i = 0; i < NUM_MASTERS; i++) begin
      s_arready[i]   = ar_fire && (ar_idx == IDX_W'(i));
      ev_ar_burst[i] = ar_fire_legal && (ar_idx == IDX_W'(i));
      ev_err_rd[i]   = ar_fire_ill && (ar_idx == IDX_W'(i));
    end
  end

  // Master-side AR register.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      m_axi_arvalid <= 1'b0;
      m_axi_arid    <= '0;
      m_axi_araddr  <= '0;
      m_axi_arlen   <= '0;
      m_axi_arsize  <= '0;
      m_axi_arburst <= '0;
      ar_rr         <= '0;
    end else begin
      if (ar_fire_legal) begin
        m_axi_arvalid <= 1'b1;
        m_axi_arid    <= {ar_idx, g_arid};
        m_axi_araddr  <= g_araddr;
        m_axi_arlen   <= g_arlen;
        m_axi_arsize  <= g_arsize;
        m_axi_arburst <= g_arburst;
      end else if (m_axi_arready) begin
        m_axi_arvalid <= 1'b0;
      end
      if (ar_fire && !HIGH_PRIO_MASK[ar_idx]) ar_rr <= after_grant(ar_idx);
    end
  end

  // ---------------------------------------------------------------------------
  // Read path: R routing, per-master pending counts, illegal-read answers
  // ---------------------------------------------------------------------------
  assign r_idx = m_axi_rid[ID_W +: IDX_W];

  always_comb begin
    m_axi_rready = 1'b0;
    for (int i = 0; i < NUM_MASTERS; i++) begin
      // Same argument as for B: the answer starts once the master has no
      // forwarded read left, and its AR is blocked meanwhile.
      err_r_valid[i] = rd_err_pend[i] && (rd_pend[i] == '0);
      r_sel[i]       = m_axi_rvalid && (r_idx == IDX_W'(i));
      r_hs[i]        = r_sel[i] && s_rready[i];
      err_r_hs[i]    = err_r_valid[i] && s_rready[i];
      s_rvalid[i]    = r_sel[i] || err_r_valid[i];
      s_rid[i * ID_W +: ID_W]       = err_r_valid[i] ? err_arid[i] : m_axi_rid[ID_W-1:0];
      s_rdata[i * DATA_W +: DATA_W] = err_r_valid[i] ? '0 : m_axi_rdata;
      s_rresp[i * 2 +: 2]           = err_r_valid[i] ? RESP_SLVERR : m_axi_rresp;
      s_rlast[i]                    = err_r_valid[i] ? (rd_err_left[i] == 8'd0) : m_axi_rlast;
      ev_r_beat[i]                  = r_hs[i];
      if (r_idx == IDX_W'(i)) m_axi_rready = s_rready[i];
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      rd_inflight <= '0;
      rd_err_pend <= '0;
      for (int i = 0; i < NUM_MASTERS; i++) begin
        rd_pend[i]     <= '0;
        err_arid[i]    <= '0;
        rd_err_left[i] <= '0;
      end
    end else begin
      case ({(ar_fire_legal && (rd_inflight != CNT_W'(MAX_OUTSTANDING))), (m_axi_rvalid && m_axi_rready &&
                                                                         m_axi_rlast && (rd_inflight != '0))})
        2'b10:   rd_inflight <= rd_inflight + CNT_W'(1);
        2'b01:   rd_inflight <= rd_inflight - CNT_W'(1);
        default: rd_inflight <= rd_inflight;
      endcase
      for (int i = 0; i < NUM_MASTERS; i++) begin
        case ({(ev_ar_burst[i] && (rd_pend[i] != CNT_W'(MAX_OUTSTANDING))), (r_hs[i] && m_axi_rlast &&
                                                                          (rd_pend[i] != '0))})
          2'b10:   rd_pend[i] <= rd_pend[i] + CNT_W'(1);
          2'b01:   rd_pend[i] <= rd_pend[i] - CNT_W'(1);
          default: rd_pend[i] <= rd_pend[i];
        endcase
        if (ev_err_rd[i]) begin
          rd_err_pend[i]  <= 1'b1;
          err_arid[i]     <= g_arid;
          rd_err_left[i]  <= g_arlen;
        end
        if (err_r_hs[i]) begin
          if (rd_err_left[i] == 8'd0) rd_err_pend[i] <= 1'b0;
          else                        rd_err_left[i] <= rd_err_left[i] - 8'd1;
        end
      end
    end
  end

  assign rd_busy = (rd_inflight != '0) || (rd_err_pend != '0);

  // ---------------------------------------------------------------------------
  // Wait cycles: a clock with awvalid or arvalid high and not granted.
  // ---------------------------------------------------------------------------
  always_comb begin
    for (int i = 0; i < NUM_MASTERS; i++) begin
      ev_wait[i] = (s_awvalid[i] && !s_awready[i]) || (s_arvalid[i] && !s_arready[i]);
    end
  end

  // ---------------------------------------------------------------------------
  // Simulation checks (inert in synthesis)
  // ---------------------------------------------------------------------------
  // synthesis translate_off
  // sim_quiet_illegal: a bench that provokes illegal bursts on purpose sets it
  // so the report is a note and the run log stays free of error lines.
  bit sim_quiet_illegal = 1'b0;

  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      if (aw_fire_ill) begin
        if (sim_quiet_illegal)
          $display("NOTE: rtlnet_axi_arbiter: illegal write burst master %0d addr 0x%0h len %0d size %0d burst %0d fail %b",
                   aw_idx, g_awaddr, g_awlen, g_awsize, g_awburst, aw_fail);
        else
          $error("rtlnet_axi_arbiter: illegal write burst master %0d addr 0x%0h len %0d size %0d burst %0d fail %b",
                 aw_idx, g_awaddr, g_awlen, g_awsize, g_awburst, aw_fail);
      end
      if (ar_fire_ill) begin
        if (sim_quiet_illegal)
          $display("NOTE: rtlnet_axi_arbiter: illegal read burst master %0d addr 0x%0h len %0d size %0d burst %0d fail %b",
                   ar_idx, g_araddr, g_arlen, g_arsize, g_arburst, ar_fail);
        else
          $error("rtlnet_axi_arbiter: illegal read burst master %0d addr 0x%0h len %0d size %0d burst %0d fail %b",
                 ar_idx, g_araddr, g_arlen, g_arsize, g_arburst, ar_fail);
      end
      if (wq_push && wq_full)
        $error("rtlnet_axi_arbiter: W-order queue overflow");
      if (wq_pop && !wq_nonempty)
        $error("rtlnet_axi_arbiter: W-order queue underflow");
      if (aw_fire_legal && (wr_inflight == CNT_W'(MAX_OUTSTANDING)))
        $error("rtlnet_axi_arbiter: write in-flight counter overflow");
      if (m_axi_bvalid && m_axi_bready && (wr_inflight == '0))
        $error("rtlnet_axi_arbiter: write in-flight counter underflow (B with no write in flight)");
      if (ar_fire_legal && (rd_inflight == CNT_W'(MAX_OUTSTANDING)))
        $error("rtlnet_axi_arbiter: read in-flight counter overflow");
      if (m_axi_rvalid && m_axi_rready && m_axi_rlast && (rd_inflight == '0))
        $error("rtlnet_axi_arbiter: read in-flight counter underflow (R with no read in flight)");
      if (m_axi_bvalid && (int'(b_idx) >= NUM_MASTERS))
        $error("rtlnet_axi_arbiter: B for master index %0d, only %0d masters", b_idx, NUM_MASTERS);
      if (m_axi_rvalid && (int'(r_idx) >= NUM_MASTERS))
        $error("rtlnet_axi_arbiter: R for master index %0d, only %0d masters", r_idx, NUM_MASTERS);
      for (int i = 0; i < NUM_MASTERS; i++) begin
        if (ev_aw_burst[i] && (wr_pend[i] == CNT_W'(MAX_OUTSTANDING)))
          $error("rtlnet_axi_arbiter: master %0d write pending counter overflow", i);
        if (b_hs[i] && (wr_pend[i] == '0))
          $error("rtlnet_axi_arbiter: master %0d B with no write pending", i);
        if (ev_ar_burst[i] && (rd_pend[i] == CNT_W'(MAX_OUTSTANDING)))
          $error("rtlnet_axi_arbiter: master %0d read pending counter overflow", i);
        if (r_hs[i] && m_axi_rlast && (rd_pend[i] == '0))
          $error("rtlnet_axi_arbiter: master %0d R with no read pending", i);
      end
    end
  end
  // synthesis translate_on

endmodule
