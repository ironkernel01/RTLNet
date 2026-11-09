// -----------------------------------------------------------------------------
// File: rtlnet_tb_axi4_mem.sv
// Purpose: bench AXI4 slave memory model, the stand-in for the DDR3 controller
//   in every bench that reaches DDR3: sparse storage, INCR bursts, in-order
//   responses, configurable ready/valid gaps and read latency, and protocol
//   checks on everything the master side drives into it.
// Overview:
//   * Storage is an associative array of full data words keyed by word address
//     (addr >> log2(DATA_W/8)); an unwritten word reads 0. Byte strobes merge
//     into the stored word. A beat that starts at an unaligned address uses the
//     word that contains it.
//   * AW, W and AR are accepted into queues of QUEUE_DEPTH; a ready is a flop
//     that is high with probability *_READY_PCT per clock (and while its queue
//     has room). W beats may arrive before their AW; a write lands when both are
//     known, one beat per clock. B follows the last beat, in AW order. A read
//     burst starts READ_LATENCY clocks after its AR was accepted (0: the clock
//     after) and each beat is valid with probability R_VALID_PCT; bursts are
//     answered in AR order, no interleaving. B and R valid stay high until
//     ready. Responses are OKAY.
//   * Checks (tb_error from rtlnet_tb_pkg): valid or payload dropped before
//     ready on AW, W and AR; WLAST on a beat other than the last or missing on
//     the last; a burst that crosses a 4 KiB boundary; burst not INCR; size not
//     the full data width (CHECK_FULL_WIDTH, the DDR3 controller has no narrow
//     support; with CHECK_FULL_WIDTH = 0 any size up to the width passes, and the
//     4 KiB check, the beat addresses and the byte strobes follow the burst's own
//     size, a read returns the whole stored word); a W beat with no AW after
//     reset is held, not an error.
//   * WRAP bursts (ALLOW_WRAP = 1, default 0): a WRAP of 2, 4, 8 or 16 beats at an address
//     aligned to the size is accepted and models the AXI wrap (the beat address wraps at
//     the (len + 1) * 2**size byte container, which is aligned to its own size; critical
//     word first); a WRAP with another length or a misaligned start is an error, and the
//     4 KiB check does not apply to a legal WRAP. With ALLOW_WRAP = 0 a WRAP is an error
//     (burst not INCR) as before.
//   * Counters aw_count, ar_count, w_beats, r_beats count accepted bursts and
//     beats. clear_memory() empties the storage; poke() and peek() access one
//     word. resetn (synchronous, active low) clears every queue and flag, not
//     the storage.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
//   * 11-09-2026: size-aware beat addresses and 4 KiB check for CHECK_FULL_WIDTH = 0.
//   * 11-09-2026: ALLOW_WRAP, WRAP burst addressing.
// Clocks: clk.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_tb_axi4_mem #(
  parameter int ADDR_W           = 32,
  parameter int DATA_W           = 128,
  parameter int ID_W             = 8,
  parameter int READ_LATENCY     = 0,     // clocks from AR accepted to the earliest R valid
  parameter int AW_READY_PCT     = 100,   // probability per clock that awready is high, percent
  parameter int W_READY_PCT      = 100,
  parameter int AR_READY_PCT     = 100,
  parameter int B_VALID_PCT      = 100,   // probability per clock that a pending B is presented
  parameter int R_VALID_PCT      = 100,   // probability per clock that the next R beat is presented
  parameter int QUEUE_DEPTH      = 16,
  parameter int SEED             = 1,
  parameter bit CHECK_FULL_WIDTH = 1'b1,
  parameter bit ALLOW_WRAP       = 1'b0   // accept legal WRAP bursts (2, 4, 8, 16 beats, aligned) and model the wrap
)(
  input  logic                clk,
  input  logic                resetn,

  input  logic [ID_W-1:0]     awid,
  input  logic [ADDR_W-1:0]   awaddr,
  input  logic [7:0]          awlen,
  input  logic [2:0]          awsize,
  input  logic [1:0]          awburst,
  input  logic                awvalid,
  output logic                awready,

  input  logic [DATA_W-1:0]   wdata,
  input  logic [DATA_W/8-1:0] wstrb,
  input  logic                wlast,
  input  logic                wvalid,
  output logic                wready,

  output logic [ID_W-1:0]     bid,
  output logic [1:0]          bresp,
  output logic                bvalid,
  input  logic                bready,

  input  logic [ID_W-1:0]     arid,
  input  logic [ADDR_W-1:0]   araddr,
  input  logic [7:0]          arlen,
  input  logic [2:0]          arsize,
  input  logic [1:0]          arburst,
  input  logic                arvalid,
  output logic                arready,

  output logic [ID_W-1:0]     rid,
  output logic [DATA_W-1:0]   rdata,
  output logic [1:0]          rresp,
  output logic                rlast,
  output logic                rvalid,
  input  logic                rready
);

  import rtlnet_tb_pkg::*;

  localparam int STRB_W    = DATA_W / 8;
  localparam int SHIFT     = $clog2(STRB_W);
  localparam int PAGE      = 4096;
  localparam bit [1:0] BURST_INCR = 2'b01;
  localparam bit [1:0] BURST_WRAP = 2'b10;

  typedef struct {
    bit [ID_W-1:0]   id;
    bit [ADDR_W-1:0] addr;
    int              len;
    bit [2:0]        size;
    bit [1:0]        burst;
    longint          ready_at;
  } burst_t;

  typedef struct {
    bit [DATA_W-1:0] data;
    bit [STRB_W-1:0] strb;
    bit              last;
  } beat_t;

  logic [DATA_W-1:0] mem [bit [ADDR_W-1:0]];

  burst_t aw_q [$];
  beat_t  w_q  [$];
  bit [ID_W-1:0] b_q [$];
  burst_t ar_q [$];

  longint cycle;
  int unsigned rng;

  // Write engine: beat index within the head AW.
  int w_idx;

  // Read engine: burst in progress and next beat to present.
  burst_t r_cur;
  bit     r_active;
  int     r_next;

  // Stability trackers: a valid that was high without ready must repeat.
  bit              aw_hold;
  bit [ID_W-1:0]   aw_hold_id;
  bit [ADDR_W-1:0] aw_hold_addr;
  bit [7:0]        aw_hold_len;
  bit [2:0]        aw_hold_size;
  bit [1:0]        aw_hold_burst;
  bit              w_hold;
  bit [DATA_W-1:0] w_hold_data;
  bit [STRB_W-1:0] w_hold_strb;
  bit              w_hold_last;
  bit              ar_hold;
  bit [ID_W-1:0]   ar_hold_id;
  bit [ADDR_W-1:0] ar_hold_addr;
  bit [7:0]        ar_hold_len;
  bit [2:0]        ar_hold_size;
  bit [1:0]        ar_hold_burst;

  int aw_count = 0;
  int ar_count = 0;
  int w_beats  = 0;
  int r_beats  = 0;

  initial rng = SEED;

  function automatic bit chance(input int pct);
    rng = rng * 32'd1103515245 + 32'd12345;
    return int'((rng >> 8) % 100) < pct;
  endfunction

  function automatic bit [ADDR_W-SHIFT-1:0] word_key(input bit [ADDR_W-1:0] a);
    return a[ADDR_W-1:SHIFT];
  endfunction

  function automatic bit [DATA_W-1:0] peek(input bit [ADDR_W-1:0] a);
    bit [ADDR_W-1:0] k;
    k = {{SHIFT{1'b0}}, word_key(a)};
    return mem.exists(k) ? mem[k] : '0;
  endfunction

  task automatic poke(input bit [ADDR_W-1:0] a, input bit [DATA_W-1:0] d);
    bit [ADDR_W-1:0] k;
    k = {{SHIFT{1'b0}}, word_key(a)};
    mem[k] = d;
  endtask

  task automatic clear_memory();
    mem.delete();
  endtask

  // Word key of beat n of a burst: the first beat uses the start address, later
  // beats the size-aligned address plus n transfers (a full-size burst: word + n).
  // A WRAP burst wraps inside its (len + 1) * 2**size byte container, aligned to its own size.
  function automatic bit [ADDR_W-1:0] beat_key(input bit [ADDR_W-1:0] a, input bit [2:0] size, input int n,
                                               input bit [1:0] burst, input int len);
    bit [ADDR_W-1:0] ba;
    bit [ADDR_W-1:0] total;
    bit [ADDR_W-1:0] lower;
    bit [ADDR_W-1:0] off;
    ba = a;
    if (burst == BURST_WRAP) begin
      total = ADDR_W'(len + 1) << size;
      lower = a & ~(total - ADDR_W'(1));
      off   = ((a >> size << size) - lower + (ADDR_W'(n) << size)) & (total - ADDR_W'(1));
      ba    = lower + off;
    end else if (n > 0) begin
      ba = (a >> size << size) + (ADDR_W'(n) << size);
    end
    return ba >> SHIFT;
  endfunction

  // Legality of a burst presented by the master side. The 4 KiB check uses the
  // burst's own size; a narrow size passes only with CHECK_FULL_WIDTH = 0.
  task automatic check_burst(input string chan, input bit [ID_W-1:0] id, input bit [ADDR_W-1:0] a,
                             input bit [7:0] len, input bit [2:0] size, input bit [1:0] burst);
    int span;
    bit wrap_ok;
    span = int'(a[11:0]) + ((int'(len) + 1) << size);
    wrap_ok = ALLOW_WRAP && (burst == BURST_WRAP) && (len == 8'd1 || len == 8'd3 || len == 8'd7 || len == 8'd15) &&
              ((a & ((ADDR_W'(1) << size) - ADDR_W'(1))) == '0);
    if (burst != BURST_WRAP) begin
      tb_check(span <= PAGE, $sformatf("axi4_mem %s id %0d addr 0x%0h len %0d crosses a 4 KiB boundary", chan, id, a, len));
    end
    tb_check(burst == BURST_INCR || wrap_ok, $sformatf("axi4_mem %s addr 0x%0h len %0d burst %0d is not INCR or a legal WRAP", chan, a, len, burst));
    if (CHECK_FULL_WIDTH) begin
      tb_check(int'(size) == SHIFT, $sformatf("axi4_mem %s addr 0x%0h size %0d is not full width %0d", chan, a, size, SHIFT));
    end else begin
      tb_check(int'(size) <= SHIFT, $sformatf("axi4_mem %s addr 0x%0h size %0d exceeds the data width %0d", chan, a, size, SHIFT));
    end
  endtask

  always @(posedge clk) begin
    if (!resetn) begin
      awready  <= 1'b0;
      wready   <= 1'b0;
      arready  <= 1'b0;
      bvalid   <= 1'b0;
      rvalid   <= 1'b0;
      bid      <= '0;
      bresp    <= 2'b00;
      rid      <= '0;
      rdata    <= '0;
      rresp    <= 2'b00;
      rlast    <= 1'b0;
      aw_q.delete();
      w_q.delete();
      b_q.delete();
      ar_q.delete();
      w_idx    = 0;
      r_active = 1'b0;
      r_next   = 0;
      aw_hold  = 1'b0;
      w_hold   = 1'b0;
      ar_hold  = 1'b0;
      cycle    = 0;
    end else begin
      cycle = cycle + 1;

      // ---- Stability of the master-side valids ------------------------------
      if (aw_hold) begin
        tb_check(awvalid === 1'b1, "axi4_mem: awvalid dropped before awready");
        tb_check(awid === aw_hold_id && awaddr === aw_hold_addr && awlen === aw_hold_len && awsize === aw_hold_size &&
                 awburst === aw_hold_burst, "axi4_mem: AW payload changed while awvalid waited for awready");
      end
      if (w_hold) begin
        tb_check(wvalid === 1'b1, "axi4_mem: wvalid dropped before wready");
        tb_check(wdata === w_hold_data && wstrb === w_hold_strb && wlast === w_hold_last,
                 "axi4_mem: W payload changed while wvalid waited for wready");
      end
      if (ar_hold) begin
        tb_check(arvalid === 1'b1, "axi4_mem: arvalid dropped before arready");
        tb_check(arid === ar_hold_id && araddr === ar_hold_addr && arlen === ar_hold_len && arsize === ar_hold_size &&
                 arburst === ar_hold_burst, "axi4_mem: AR payload changed while arvalid waited for arready");
      end
      aw_hold = (awvalid === 1'b1) && (awready !== 1'b1);
      aw_hold_id = awid; aw_hold_addr = awaddr; aw_hold_len = awlen; aw_hold_size = awsize; aw_hold_burst = awburst;
      w_hold = (wvalid === 1'b1) && (wready !== 1'b1);
      w_hold_data = wdata; w_hold_strb = wstrb; w_hold_last = wlast;
      ar_hold = (arvalid === 1'b1) && (arready !== 1'b1);
      ar_hold_id = arid; ar_hold_addr = araddr; ar_hold_len = arlen; ar_hold_size = arsize; ar_hold_burst = arburst;

      // ---- Accept AW, W, AR --------------------------------------------------
      if (awvalid === 1'b1 && awready === 1'b1) begin
        burst_t b;
        check_burst("AW", awid, awaddr, awlen, awsize, awburst);
        b.id = awid; b.addr = awaddr; b.len = int'(awlen); b.size = awsize; b.burst = awburst; b.ready_at = 0;
        aw_q.push_back(b);
        aw_count++;
      end
      if (wvalid === 1'b1 && wready === 1'b1) begin
        beat_t t;
        t.data = wdata; t.strb = wstrb; t.last = wlast;
        w_q.push_back(t);
        w_beats++;
      end
      if (arvalid === 1'b1 && arready === 1'b1) begin
        burst_t b;
        check_burst("AR", arid, araddr, arlen, arsize, arburst);
        b.id = arid; b.addr = araddr; b.len = int'(arlen); b.size = arsize; b.burst = arburst; b.ready_at = cycle + READ_LATENCY;
        ar_q.push_back(b);
        ar_count++;
      end

      // ---- Write engine: one beat per clock ----------------------------------
      if (aw_q.size() > 0 && w_q.size() > 0) begin
        beat_t           t;
        burst_t          h;
        bit [ADDR_W-1:0] k;
        bit [DATA_W-1:0] old;
        bit [DATA_W-1:0] nw;
        t = w_q.pop_front();
        h = aw_q[0];
        k = beat_key(h.addr, h.size, w_idx, h.burst, h.len);
        old = mem.exists(k) ? mem[k] : '0;
        nw  = old;
        for (int l = 0; l < STRB_W; l++) begin
          if (t.strb[l]) nw[l*8 +: 8] = t.data[l*8 +: 8];
        end
        mem[k] = nw;
        tb_check(t.last == (w_idx == h.len), $sformatf("axi4_mem: WLAST %0d on beat %0d of a %0d-beat write (id %0d addr 0x%0h)",
                                                      t.last, w_idx, h.len + 1, h.id, h.addr));
        if (w_idx == h.len || t.last) begin
          void'(aw_q.pop_front());
          b_q.push_back(h.id);
          w_idx = 0;
        end else begin
          w_idx++;
        end
      end

      // ---- Ready flops --------------------------------------------------------
      awready <= chance(AW_READY_PCT) && (aw_q.size() < QUEUE_DEPTH);
      wready  <= chance(W_READY_PCT)  && (w_q.size() < QUEUE_DEPTH);
      arready <= chance(AR_READY_PCT) && (ar_q.size() < QUEUE_DEPTH);

      // ---- B channel ----------------------------------------------------------
      if (!bvalid || bready) begin
        if (b_q.size() > 0 && chance(B_VALID_PCT)) begin
          bvalid <= 1'b1;
          bid    <= b_q.pop_front();
          bresp  <= 2'b00;
        end else begin
          bvalid <= 1'b0;
        end
      end

      // ---- R channel ----------------------------------------------------------
      if (!rvalid || rready) begin
        bit presented;
        presented = 1'b0;
        if (!r_active && ar_q.size() > 0 && ar_q[0].ready_at <= cycle) begin
          r_cur    = ar_q.pop_front();
          r_active = 1'b1;
          r_next   = 0;
        end
        if (r_active && chance(R_VALID_PCT)) begin
          bit [ADDR_W-1:0] k;
          k = beat_key(r_cur.addr, r_cur.size, r_next, r_cur.burst, r_cur.len);
          rvalid <= 1'b1;
          rid    <= r_cur.id;
          rdata  <= mem.exists(k) ? mem[k] : '0;
          rresp  <= 2'b00;
          rlast  <= (r_next == r_cur.len);
          presented = 1'b1;
          r_beats++;
          if (r_next == r_cur.len) r_active = 1'b0;
          else                     r_next++;
        end
        if (!presented) rvalid <= 1'b0;
      end
    end
  end

endmodule
