// -----------------------------------------------------------------------------
// File: tb_h264_axi_mem.sv
// Purpose: AXI4 slave memory model of the rtlnet_h264_top benches: flat 128-bit word array loaded with $readmemh,
//   byte-strobe writes, INCR bursts, in-order responses, configurable read latency and random ready/valid
//   gaps, and protocol checks on everything the encoder drives (Verilator 5 and Active-HDL compatible).
// Overview:
//   * Storage mem[0:WORDS-1] of 128-bit words (byte 0 in bits [7:0]); the bench loads and dumps it directly.
//   * AW and AR are queued (depth 32). W beats are accepted once an AW is queued; a write lands beat by beat with the
//     byte strobes merged. B follows the last beat, in AW order. A read burst starts READ_LAT clocks after the AR
//     was accepted (latency overlaps across queued reads, like a pipelined memory controller); bursts are answered in AR order with no interleaving. B and R valid hold until
//     ready. Every ready and valid beat is gated by a per-clock probability (GAP_PCT percent of clocks pass).
//   * Checks (the arbiter rejects the same, rtlnet_axi_arbiter.sv): burst not INCR, size not 16 bytes, more than 16
//     beats, 4 KiB crossing, WLAST not on the last beat, valid or payload changing before ready, an address
//     beyond the array.
//   * Counters: aw_count, ar_count, w_beats, r_beats.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_h264_axi_mem #(
  parameter int WORDS_LOG2 = 20,
  parameter int ID_W       = 4,
  parameter int READ_LAT   = 0,
  parameter int GAP_PCT    = 0,
  parameter int SEED       = 1
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // AXI4 slave, clk domain.
  input  logic [ID_W-1:0]   awid,
  input  logic [31:0]       awaddr,
  input  logic [7:0]        awlen,
  input  logic [2:0]        awsize,
  input  logic [1:0]        awburst,
  input  logic              awvalid,
  output logic              awready,
  input  logic [127:0]      wdata,
  input  logic [15:0]       wstrb,
  input  logic              wlast,
  input  logic              wvalid,
  output logic              wready,
  output logic [ID_W-1:0]   bid,
  output logic [1:0]        bresp,
  output logic              bvalid,
  input  logic              bready,
  input  logic [ID_W-1:0]   arid,
  input  logic [31:0]       araddr,
  input  logic [7:0]        arlen,
  input  logic [2:0]        arsize,
  input  logic [1:0]        arburst,
  input  logic              arvalid,
  output logic              arready,
  output logic [ID_W-1:0]   rid,
  output logic [127:0]      rdata,
  output logic [1:0]        rresp,
  output logic              rlast,
  output logic              rvalid,
  input  logic              rready
);

  localparam int WORDS = 1 << WORDS_LOG2;
  localparam int QD    = 32;

  logic [127:0] mem [0:WORDS-1];

  longint unsigned aw_count = 0;
  longint unsigned ar_count = 0;
  longint unsigned w_beats  = 0;
  longint unsigned r_beats  = 0;

  // Queues.
  logic [31:0]     awq_addr [QD];
  logic [7:0]      awq_len  [QD];
  logic [ID_W-1:0] awq_id   [QD];
  int              awq_rd = 0, awq_wr = 0, awq_cnt = 0;
  logic [31:0]     arq_addr [QD];
  logic [7:0]      arq_len  [QD];
  logic [ID_W-1:0] arq_id   [QD];
  longint unsigned arq_t    [QD];
  longint unsigned cyc = 0;
  int              arq_rd = 0, arq_wr = 0, arq_cnt = 0;
  logic [ID_W-1:0] bq_id    [QD];
  int              bq_rd = 0, bq_wr = 0, bq_cnt = 0;

  // Write beat state.
  int              w_beat = 0;
  // Read burst state.
  bit              r_active = 0;
  logic [31:0]     r_addr;
  int              r_left = 0;
  logic [ID_W-1:0] r_id;
  int              r_wait = 0;

  // Hold checks.
  bit              aw_held = 0;
  bit              ar_held = 0;
  bit              w_held = 0;
  logic [31:0]     aw_hold_addr, ar_hold_addr;
  logic [127:0]    w_hold_data;

  int unsigned     rng;

  function automatic bit pass_gap();
    if (GAP_PCT == 0) return 1'b1;
    return (($urandom % 100) >= GAP_PCT);
  endfunction

  function automatic void check_burst(input string what, input logic [31:0] addr, input logic [7:0] len,
                                      input logic [2:0] size, input logic [1:0] burst);
    if (burst != 2'b01) $error("tb_h264_axi_mem: %s burst type %0d, must be INCR", what, burst);
    if (size != 3'd4)   $error("tb_h264_axi_mem: %s size %0d, must be the full 16-byte width", what, size);
    if (len > 8'd15)    $error("tb_h264_axi_mem: %s length %0d beats, at most 16", what, len + 1);
    if (((addr & 32'hFFF) + ((len + 1) * 16)) > 32'h1000) $error("tb_h264_axi_mem: %s 0x%08x len %0d crosses 4 KiB", what, addr, len);
    if ((addr[3:0] != 4'd0)) $error("tb_h264_axi_mem: %s 0x%08x not 16-byte aligned", what, addr);
    if ((addr >> 4) >= WORDS) $error("tb_h264_axi_mem: %s 0x%08x beyond the memory array", what, addr);
  endfunction

  always @(posedge clk) begin
    if (!resetn) begin
      awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; bid <= '0; bresp <= 2'b00;
      arready <= 1'b0; rvalid <= 1'b0; rlast <= 1'b0; rdata <= '0; rid <= '0; rresp <= 2'b00;
      awq_rd = 0; awq_wr = 0; awq_cnt = 0;
      arq_rd = 0; arq_wr = 0; arq_cnt = 0;
      bq_rd = 0; bq_wr = 0; bq_cnt = 0;
      w_beat = 0; r_active = 0; r_left = 0; r_wait = 0;
      aw_held = 0; ar_held = 0; w_held = 0;
    end else begin
      cyc++;
      // Hold checks on the previous clock's valid without ready.
      if (aw_held && (!awvalid || awaddr !== aw_hold_addr)) $error("tb_h264_axi_mem: AW dropped or changed before ready");
      if (ar_held && (!arvalid || araddr !== ar_hold_addr)) $error("tb_h264_axi_mem: AR dropped or changed before ready");
      if (w_held && (!wvalid || wdata !== w_hold_data)) $error("tb_h264_axi_mem: W dropped or changed before ready");
      aw_held = awvalid && !awready; aw_hold_addr = awaddr;
      ar_held = arvalid && !arready; ar_hold_addr = araddr;
      w_held  = wvalid && !wready;   w_hold_data  = wdata;

      // AW accept.
      if (awvalid && awready) begin
        check_burst("AW", awaddr, awlen, awsize, awburst);
        if (awq_cnt >= QD) $error("tb_h264_axi_mem: AW queue overflow");
        awq_addr[awq_wr] = awaddr; awq_len[awq_wr] = awlen; awq_id[awq_wr] = awid;
        awq_wr = (awq_wr + 1) % QD; awq_cnt++; aw_count++;
      end
      // W beat accept.
      if (wvalid && wready) begin
        if (awq_cnt == 0) $error("tb_h264_axi_mem: W beat accepted with no AW");
        else begin
          logic [31:0] a;
          logic [127:0] w;
          a = awq_addr[awq_rd] + (w_beat * 16);
          w = mem[a >> 4];
          for (int b = 0; b < 16; b++) if (wstrb[b]) w[8*b +: 8] = wdata[8*b +: 8];
          mem[a >> 4] = w;
          w_beats++;
          if (wlast != (w_beat == awq_len[awq_rd])) $error("tb_h264_axi_mem: WLAST wrong at beat %0d of %0d", w_beat, awq_len[awq_rd] + 1);
          if (w_beat == awq_len[awq_rd]) begin
            bq_id[bq_wr] = awq_id[awq_rd]; bq_wr = (bq_wr + 1) % QD; bq_cnt++;
            awq_rd = (awq_rd + 1) % QD; awq_cnt--;
            w_beat = 0;
          end else begin
            w_beat++;
          end
        end
      end
      // B channel.
      if (bvalid && bready) bvalid <= 1'b0;
      if ((!bvalid || bready) && bq_cnt > 0 && pass_gap()) begin
        bvalid <= 1'b1; bid <= bq_id[bq_rd]; bresp <= 2'b00;
        bq_rd = (bq_rd + 1) % QD; bq_cnt--;
      end
      // AR accept.
      if (arvalid && arready) begin
        check_burst("AR", araddr, arlen, arsize, arburst);
        if (arq_cnt >= QD) $error("tb_h264_axi_mem: AR queue overflow");
        arq_addr[arq_wr] = araddr; arq_len[arq_wr] = arlen; arq_id[arq_wr] = arid; arq_t[arq_wr] = cyc;
        arq_wr = (arq_wr + 1) % QD; arq_cnt++; ar_count++;
      end
      // R channel.
      if (rvalid && rready) begin
        rvalid <= 1'b0; rlast <= 1'b0;
        r_beats++;
      end
      if (!r_active && arq_cnt > 0 && (cyc >= arq_t[arq_rd] + READ_LAT)) begin
        r_active = 1; r_addr = arq_addr[arq_rd]; r_left = arq_len[arq_rd] + 1; r_id = arq_id[arq_rd];
        r_wait = 0;
        arq_rd = (arq_rd + 1) % QD; arq_cnt--;
      end else if (r_active && (!rvalid || rready) && !(rvalid && !rready)) begin
        if (r_wait > 0) r_wait--;
        else if (pass_gap()) begin
          rvalid <= 1'b1; rdata <= mem[r_addr >> 4]; rid <= r_id; rresp <= 2'b00; rlast <= (r_left == 1);
          r_addr = r_addr + 16; r_left--;
          if (r_left == 0) r_active = 0;
        end
      end
      // Ready generation (registered).
      awready <= (awq_cnt < QD - 2) && pass_gap();
      arready <= (arq_cnt < QD - 2) && pass_gap();
      wready  <= (awq_cnt > 0) && pass_gap();
    end
  end

endmodule
