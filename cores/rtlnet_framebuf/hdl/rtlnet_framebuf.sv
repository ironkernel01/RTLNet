// -----------------------------------------------------------------------------
// File: rtlnet_framebuf.sv
// Purpose: tear-free frame-buffer slot manager (documentation/gige.md section 6): N slots in DDR3, one writer (the write
//   DMA), NUM_READERS reader ports and the firmware as one more reader. It only hands out slot ownership; the frame
//   data moves between DDR3 and the DMAs.
// Overview:
//   * Slots: slot i is at byte offset FB_BASE + i * 2**SLOT_LOG2 in DDR3 (FB_BASE a multiple of the slot size). N = readers
//     + 2 slots (default 3 with the one reader port) let the writer always find a slot: one slot is "latest", each reader
//     can hold one, and the writer owns one.
//   * Writer: at a frame start the DMA asks for a slot (w_req, held until the answer). The manager takes the first slot after the
//     last one written, in rotation, that is not "latest" and that no reader holds (reference count 0) and answers with
//     its base (w_rsp_valid pulse, w_rsp_ok, w_rsp_base). With no such slot the frame is dropped: w_rsp_ok = 0 and it
//     is counted (DROPPED). The writer never lands on a held slot or on "latest". At the end of the frame (w_done) a good
//     frame is published: its slot becomes "latest" with its metadata (frame number, timestamp, width, height, source
//     flag 1 pattern or 0 camera); a frame that is not good is counted (BAD) and its slot goes back to the free pool,
//     "latest" unchanged. Published frames therefore appear in the order they finished.
//   * Readers: r_take[i] (a pulse) takes the latest published slot with a reference count, answered by an r_rsp_valid
//     pulse with r_rsp_ok (0 when nothing is published or the reader already holds a slot); the reader holds the slot, and
//     the slot, base and metadata outputs describe it, until r_release[i] (a pulse). A take and a publish in the same clock
//     take the previous "latest". The firmware reader works the same way through CTRL.FW_TAKE and FW_RELEASE.
//   * Registers on s_axi_aclk behind rtlnet_axil_cdc and rtlnet_axil_slave (4 KiB window); rtlnet_framebuf_regs holds the
//     register file, offsets in driver/rtlnet_framebuf.h. The per-slot metadata and reference counts are a few register
//     words (N entries), deliberately flops and not a RAM.
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk (slot manager, registers; the memory-controller user clock); s_axi_aclk (AXI4-Lite slave side of the
//   register crossing only).
// -----------------------------------------------------------------------------
module rtlnet_framebuf #(
  parameter bit    AXIL_SYNC = 1'b0,   // 1: s_axi_aclk is clk (register window without a clock crossing)
  parameter int          N           = 3,                  // slots, 2..8
  parameter int          NUM_READERS = 1,                  // external reader ports (the firmware reader is extra)
  parameter int          ADDR_W      = 29,                 // DDR3 byte address bits
  parameter int          SLOT_LOG2   = 22,                 // slot size 4 MiB
  parameter logic [31:0] FB_BASE     = 32'h1000_0000       // DDR3 byte offset of slot 0
)(
  // Core clock and its reset (synchronous, active low); the AXI4-Lite clock and its reset (released from the same
  // assertion).
  input  logic                         clk,
  input  logic                         resetn,
  input  logic                         s_axi_aclk,
  input  logic                         s_axi_aresetn,

  // Writer (rtlnet_vdma_s2mm), clk domain.
  input  logic                         w_req,
  output logic                         w_rsp_valid,
  output logic                         w_rsp_ok,
  output logic [ADDR_W-1:0]            w_rsp_base,
  input  logic                         w_done,
  input  logic                         w_done_good,
  input  logic [31:0]                  w_done_frame_num,
  input  logic [31:0]                  w_done_timestamp,
  input  logic [15:0]                  w_done_width,
  input  logic [15:0]                  w_done_height,
  input  logic                         w_done_src_pattern,

  // Reader ports, clk domain, reader i at [i*W +: W].
  input  logic [NUM_READERS-1:0]       r_take,
  input  logic [NUM_READERS-1:0]       r_release,
  output logic [NUM_READERS-1:0]       r_rsp_valid,
  output logic [NUM_READERS-1:0]       r_rsp_ok,
  output logic [NUM_READERS-1:0]       r_holds,
  output logic [NUM_READERS*8-1:0]     r_slot,
  output logic [NUM_READERS*ADDR_W-1:0] r_base,
  output logic [NUM_READERS*32-1:0]    r_frame_num,
  output logic [NUM_READERS*32-1:0]    r_timestamp,
  output logic [NUM_READERS*16-1:0]    r_width,
  output logic [NUM_READERS*16-1:0]    r_height,
  output logic [NUM_READERS-1:0]       r_src_pattern,

  // AXI4-Lite register slave, s_axi_aclk domain, 12-bit byte address, 32-bit data.
  input  logic [11:0]                  s_axi_awaddr,
  input  logic                         s_axi_awvalid,
  output logic                         s_axi_awready,
  input  logic [31:0]                  s_axi_wdata,
  input  logic [3:0]                   s_axi_wstrb,
  input  logic                         s_axi_wvalid,
  output logic                         s_axi_wready,
  output logic [1:0]                   s_axi_bresp,
  output logic                         s_axi_bvalid,
  input  logic                         s_axi_bready,
  input  logic [11:0]                  s_axi_araddr,
  input  logic                         s_axi_arvalid,
  output logic                         s_axi_arready,
  output logic [31:0]                  s_axi_rdata,
  output logic [1:0]                   s_axi_rresp,
  output logic                         s_axi_rvalid,
  input  logic                         s_axi_rready
);

  localparam int RT = NUM_READERS + 1;                    // holders: the reader ports and the firmware (index NUM_READERS)
  localparam int SW = (N > 1) ? $clog2(N) : 1;
  localparam int RC_W = 8;

  generate
    if (N < 2 || N > 8) begin : g_bad_n
      $fatal(1, "rtlnet_framebuf: N=%0d, must be 2..8", N);
    end
    if (NUM_READERS < 1 || NUM_READERS > 7) begin : g_bad_readers
      $fatal(1, "rtlnet_framebuf: NUM_READERS=%0d, must be 1..7", NUM_READERS);
    end
    if ((FB_BASE & ((32'd1 << SLOT_LOG2) - 32'd1)) != 32'd0) begin : g_bad_base
      $fatal(1, "rtlnet_framebuf: FB_BASE 0x%0h is not a multiple of the slot size 2**%0d", FB_BASE, SLOT_LOG2);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Register access
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

  // Register clock -> clk crossing of whole AXI4-Lite transactions.
  rtlnet_axil_cdc #(.ADDR_W(12), .SYNC(AXIL_SYNC)) u_axil_cdc (
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

  // ---------------------------------------------------------------------------
  // Slot state
  // ---------------------------------------------------------------------------
  logic [RC_W-1:0]  refcnt [N];
  logic [31:0]      meta_frame [N];
  logic [31:0]      meta_ts    [N];
  logic [15:0]      meta_w     [N];
  logic [15:0]      meta_h     [N];
  logic             meta_src   [N];

  logic [SW-1:0]    latest;
  logic             latest_valid;
  logic             wr_busy;
  logic [SW-1:0]    wr_slot;
  logic [SW-1:0]    last_wr;
  logic [RT-1:0]    hold;
  logic [SW-1:0]    hslot [RT];
  logic             w_req_q;

  // Next state, computed in always_comb from the events of the clock.
  logic [RC_W-1:0]  refcnt_n [N];
  logic [RT-1:0]    hold_n;
  logic [SW-1:0]    hslot_n [RT];
  logic [SW-1:0]    latest_n;
  logic             latest_valid_n;
  logic             wr_busy_n;
  logic [SW-1:0]    wr_slot_n;
  logic [SW-1:0]    last_wr_n;
  logic [RT-1:0]    rsp_valid_n;
  logic [RT-1:0]    rsp_ok_n;
  logic             w_rsp_valid_n;
  logic             w_rsp_ok_n;
  logic [SW-1:0]    w_rsp_slot_n;
  logic             publish;
  logic             ev_dropped;
  logic             ev_bad;
  logic             ev_fw_err;
  logic             ev_fw_take_ok;
  logic             req_go;
  logic             found;
  logic [SW-1:0]    sel;
  logic [SW-1:0]    cand;
  logic [RT-1:0]    take_v;
  logic [RT-1:0]    rel_v;
  logic             fw_take;
  logic             fw_release;

  assign take_v = {fw_take, r_take};
  assign rel_v  = {fw_release, r_release};
  assign req_go = w_req && !w_req_q;

  always_comb begin
    for (int i = 0; i < N; i++) refcnt_n[i] = refcnt[i];
    for (int r = 0; r < RT; r++) hslot_n[r] = hslot[r];
    hold_n         = hold;
    latest_n       = latest;
    latest_valid_n = latest_valid;
    wr_busy_n      = wr_busy;
    wr_slot_n      = wr_slot;
    last_wr_n      = last_wr;
    rsp_valid_n    = '0;
    rsp_ok_n       = '0;
    w_rsp_valid_n  = 1'b0;
    w_rsp_ok_n     = 1'b0;
    w_rsp_slot_n   = '0;
    publish        = 1'b0;
    ev_dropped     = 1'b0;
    ev_bad         = 1'b0;
    ev_fw_err      = 1'b0;
    ev_fw_take_ok  = 1'b0;
    found          = 1'b0;
    sel            = '0;
    cand           = '0;

    // Releases first: a reader that releases and takes in one clock takes again.
    for (int r = 0; r < RT; r++) begin
      if (rel_v[r]) begin
        if (hold[r]) begin
          refcnt_n[hslot[r]] = refcnt_n[hslot[r]] - RC_W'(1);
          hold_n[r]          = 1'b0;
        end else if (r == NUM_READERS) begin
          ev_fw_err = 1'b1;
        end
      end
    end

    // Takes of the latest published slot (the previous one when a frame is published in this clock).
    for (int r = 0; r < RT; r++) begin
      if (take_v[r]) begin
        rsp_valid_n[r] = 1'b1;
        if (hold_n[r] || !latest_valid) begin
          if (r == NUM_READERS) ev_fw_err = 1'b1;
        end else begin
          refcnt_n[latest] = refcnt_n[latest] + RC_W'(1);
          hold_n[r]        = 1'b1;
          hslot_n[r]       = latest;
          rsp_ok_n[r]      = 1'b1;
          if (r == NUM_READERS) ev_fw_take_ok = 1'b1;
        end
      end
    end

    // Writer: slot request, in rotation after the last slot written.
    if (req_go) begin
      for (int k = 1; k <= N; k++) begin
        cand = SW'((int'(last_wr) + k) % N);
        if (!found && !(latest_valid && (cand == latest)) && (refcnt_n[cand] == RC_W'(0))) begin
          found = 1'b1;
          sel   = cand;
        end
      end
      w_rsp_valid_n = 1'b1;
      if (found) begin
        w_rsp_ok_n   = 1'b1;
        w_rsp_slot_n = sel;
        wr_busy_n    = 1'b1;
        wr_slot_n    = sel;
        last_wr_n    = sel;
      end else begin
        ev_dropped = 1'b1;
        wr_busy_n  = 1'b0;
      end
    end

    // Writer: end of frame.
    if (w_done && wr_busy) begin
      wr_busy_n = 1'b0;
      if (w_done_good) begin
        publish        = 1'b1;
        latest_n       = wr_slot;
        latest_valid_n = 1'b1;
      end else begin
        ev_bad = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      for (int i = 0; i < N; i++) begin
        refcnt[i]     <= '0;
        meta_frame[i] <= '0;
        meta_ts[i]    <= '0;
        meta_w[i]     <= '0;
        meta_h[i]     <= '0;
        meta_src[i]   <= 1'b0;
      end
      for (int r = 0; r < RT; r++) hslot[r] <= '0;
      latest       <= '0;
      latest_valid <= 1'b0;
      wr_busy      <= 1'b0;
      wr_slot      <= '0;
      last_wr      <= SW'(N - 1);        // the first frame takes slot 0
      hold         <= '0;
      w_req_q      <= 1'b0;
      w_rsp_valid  <= 1'b0;
      w_rsp_ok     <= 1'b0;
      w_rsp_base   <= '0;
      r_rsp_valid  <= '0;
      r_rsp_ok     <= '0;
    end else begin
      for (int i = 0; i < N; i++) refcnt[i] <= refcnt_n[i];
      for (int r = 0; r < RT; r++) hslot[r] <= hslot_n[r];
      latest       <= latest_n;
      latest_valid <= latest_valid_n;
      wr_busy      <= wr_busy_n;
      wr_slot      <= wr_slot_n;
      last_wr      <= last_wr_n;
      hold         <= hold_n;
      w_req_q      <= w_req;
      w_rsp_valid  <= w_rsp_valid_n;
      w_rsp_ok     <= w_rsp_ok_n;
      w_rsp_base   <= ADDR_W'(FB_BASE) + (ADDR_W'(w_rsp_slot_n) << SLOT_LOG2);
      r_rsp_valid  <= rsp_valid_n[NUM_READERS-1:0];
      r_rsp_ok     <= rsp_ok_n[NUM_READERS-1:0];
      if (publish) begin
        meta_frame[wr_slot] <= w_done_frame_num;
        meta_ts[wr_slot]    <= w_done_timestamp;
        meta_w[wr_slot]     <= w_done_width;
        meta_h[wr_slot]     <= w_done_height;
        meta_src[wr_slot]   <= w_done_src_pattern;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Reader outputs: the held slot and its metadata
  // ---------------------------------------------------------------------------
  always_comb begin
    for (int r = 0; r < NUM_READERS; r++) begin
      r_holds[r]                  = hold[r];
      r_slot[r*8 +: 8]            = 8'(hslot[r]);
      r_base[r*ADDR_W +: ADDR_W]  = ADDR_W'(FB_BASE) + (ADDR_W'(hslot[r]) << SLOT_LOG2);
      r_frame_num[r*32 +: 32]     = meta_frame[hslot[r]];
      r_timestamp[r*32 +: 32]     = meta_ts[hslot[r]];
      r_width[r*16 +: 16]         = meta_w[hslot[r]];
      r_height[r*16 +: 16]        = meta_h[hslot[r]];
      r_src_pattern[r]            = meta_src[hslot[r]];
    end
  end

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic [N*RC_W-1:0] refcnt_flat;
  logic [31:0]       latest_base_w;
  logic [31:0]       fw_base_w;

  always_comb begin
    for (int i = 0; i < N; i++) refcnt_flat[i*RC_W +: RC_W] = refcnt[i];
  end

  assign latest_base_w = latest_valid ? (FB_BASE + (32'(latest) << SLOT_LOG2)) : 32'd0;
  assign fw_base_w     = hold[NUM_READERS] ? (FB_BASE + (32'(hslot[NUM_READERS]) << SLOT_LOG2)) : 32'd0;

  rtlnet_framebuf_regs #(
    .N         (N),
    .NUM_RD    (NUM_READERS),
    .SLOT_LOG2 (SLOT_LOG2),
    .ADDR_W    (ADDR_W),
    .FB_BASE   (FB_BASE)
  ) u_regs (
    .clk           (clk),
    .resetn        (resetn),
    .reg_wr_en     (reg_wr_en),
    .reg_wr_addr   (reg_wr_addr),
    .reg_wr_data   (reg_wr_data),
    .reg_rd_en     (reg_rd_en),
    .reg_rd_addr   (reg_rd_addr),
    .reg_rd_data   (reg_rd_data),
    .fw_take       (fw_take),
    .fw_release    (fw_release),
    .latest_valid  (latest_valid),
    .fw_holds      (hold[NUM_READERS]),
    .writing       (wr_busy),
    .latest_slot   (8'(latest)),
    .fw_slot       (8'(hslot[NUM_READERS])),
    .wr_slot       (8'(wr_slot)),
    .ev_fw_err     (ev_fw_err),
    .ev_published  (publish),
    .ev_dropped    (ev_dropped),
    .ev_bad        (ev_bad),
    .ev_fw_take_ok (ev_fw_take_ok),
    .refcnt_flat   (refcnt_flat),
    .latest_base   (latest_base_w),
    .latest_frame  (latest_valid ? meta_frame[latest] : 32'd0),
    .latest_ts     (latest_valid ? meta_ts[latest]    : 32'd0),
    .latest_w      (latest_valid ? meta_w[latest]     : 16'd0),
    .latest_h      (latest_valid ? meta_h[latest]     : 16'd0),
    .latest_src    (latest_valid ? meta_src[latest]   : 1'b0),
    .fw_base       (fw_base_w),
    .fw_frame      (hold[NUM_READERS] ? meta_frame[hslot[NUM_READERS]] : 32'd0),
    .fw_ts         (hold[NUM_READERS] ? meta_ts[hslot[NUM_READERS]]    : 32'd0),
    .fw_w          (hold[NUM_READERS] ? meta_w[hslot[NUM_READERS]]     : 16'd0),
    .fw_h          (hold[NUM_READERS] ? meta_h[hslot[NUM_READERS]]     : 16'd0),
    .fw_src        (hold[NUM_READERS] ? meta_src[hslot[NUM_READERS]]   : 1'b0)
  );

  // ---------------------------------------------------------------------------
  // Simulation checks (inert in synthesis)
  // ---------------------------------------------------------------------------
  // synthesis translate_off
  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      for (int i = 0; i < N; i++) begin
        if ((refcnt[i] == RC_W'(0)) && (refcnt_n[i] > RC_W'(RT)))
          $error("rtlnet_framebuf: reference count underflow on slot %0d", i);
        if (refcnt_n[i] > RC_W'(RT))
          $error("rtlnet_framebuf: reference count of slot %0d above the number of holders", i);
      end
      if (w_rsp_ok_n && (refcnt_n[w_rsp_slot_n] != RC_W'(0)))
        $error("rtlnet_framebuf: slot %0d granted to the writer while held", w_rsp_slot_n);
      if (w_rsp_ok_n && latest_valid && (w_rsp_slot_n == latest))
        $error("rtlnet_framebuf: the latest slot %0d granted to the writer", w_rsp_slot_n);
    end
  end
  // synthesis translate_on

endmodule
