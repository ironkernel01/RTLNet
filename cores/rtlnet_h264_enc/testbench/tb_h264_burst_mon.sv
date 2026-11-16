// -----------------------------------------------------------------------------
// File: tb_h264_burst_mon.sv
// Purpose: burst-shape monitor of the encoder's AXI4 master ports (the DDR3 rule: bursts only, no single-beat
//   transactions in streaming): checks every accepted AW and AR of every engine port and keeps a beat-count histogram
//   per master and kind.
// Overview:
//   * Kinds: AR input-frame row bursts (ARID 0); AR reference reads (ARID 1, phase 2c-1: the co-located macroblock of the
//     reference picture, a 16-beat luma tile burst and an 8-beat chroma tile burst); the encoder's AWID: AW ring (ID 0), AW index
//     record (ID 1), AW rebuilt tile (ID 2).
//   * Rules, each failing the bench through tb_error: an AR of one beat; an AW of one beat from the index or the rebuilt
//     tile writer; an index record that is not 8 beats; a rebuilt tile that is not 16 beats (luma) or 8 beats (chroma);
//     a read burst that is not a whole number of macroblock rows (an even number of beats); a reference read (ARID 1) of any
//     length but 16 or 8 beats (so never one beat), and a different number of 16-beat and 8-beat reference reads at report().
//     A single-beat ring AW is allowed (it is a slice-end, ring-end or 4 KiB-end tail by construction of the ring writer)
//     and counted: report() checks that count against max_ring_tail1.
//   * report() prints one HIST line per engine and kind: the number of bursts per beat count, and a SUMMARY line.
//   * AXI_W (default 128): the bus width, 128 or 64. The rules are those of the bytes per burst: with 64 bits a beat is 8 bytes, input
//     rows are 4 * n_mb beats, an index record is 16 beats, the rebuilt tiles and the reference tiles leave as bursts of 16 beats (a luma
//     tile of 256 bytes as two of 128 bytes, so the count of 16-beat reference reads is three per chroma tile), a ring tail of one 16-byte word is a two-beat burst, and no burst has more than 16 beats (AXI3).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-15-2026
//   * 11-15-2026: AXI_W parameter.
//   * 11-10-2026: initial version.
//   * 11-10-2026: phase 2c-1: reference reads (ARID 1) classified and checked.
// Clocks: clk.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_h264_burst_mon #(
  parameter int NE   = 1,
  parameter int ID_W = 4,
  parameter int AXI_W = 128
)(
  input  logic                clk,
  input  logic                resetn,
  input  logic [NE*ID_W-1:0]  awid,
  input  logic [NE*8-1:0]     awlen,
  input  logic [NE-1:0]       awvalid,
  input  logic [NE-1:0]       awready,
  input  logic [NE*ID_W-1:0]  arid,
  input  logic [NE*8-1:0]     arlen,
  input  logic [NE-1:0]       arvalid,
  input  logic [NE-1:0]       arready
);

  import rtlnet_tb_pkg::*;

  // hist[engine][kind][beats]: kind 0 AR input, 1 AW ring, 2 AW index, 3 AW rebuilt tile, 4 AR reference; beats 1..16.
  localparam int NB = AXI_W / 8;       // bytes per beat
  int hist [NE][5][17];
  int viol_count = 0;

  always @(posedge clk) begin
    if (resetn) begin
      for (int e = 0; e < NE; e++) begin
        if (arvalid[e] && arready[e]) begin
          int b;
          b = int'(arlen[e*8 +: 8]) + 1;
          if (b < 2) begin tb_error($sformatf("burst monitor: engine %0d single-beat AR (len 0)", e)); viol_count++; end
          if (b > 16) b = 16;
          if (arid[e*ID_W +: 2] == 2'd1) begin
            hist[e][4][b]++;
            if (((b * NB) != 256) && ((b * NB) != 128)) begin
              tb_error($sformatf("burst monitor: engine %0d reference read of %0d beats, must be a luma tile (256 bytes) or a chroma tile (128 bytes)", e, b)); viol_count++;
            end
          end else begin
            hist[e][0][b]++;
            if (((b * NB) % 32) != 0) begin tb_error($sformatf("burst monitor: engine %0d AR of %0d beats, not whole macroblock rows", e, b)); viol_count++; end
          end
        end
        if (awvalid[e] && awready[e]) begin
          int b;
          int k;
          b = int'(awlen[e*8 +: 8]) + 1;
          k = int'(awid[e*ID_W +: 2]);
          if (k > 2) begin
            tb_error($sformatf("burst monitor: engine %0d AW with unknown ID %0d", e, k)); viol_count++;
          end else begin
            hist[e][k+1][b]++;
            if ((k == 1) && ((b * NB) != 128)) begin tb_error($sformatf("burst monitor: engine %0d index record of %0d beats, must be 128 bytes", e, b)); viol_count++; end
            if ((k == 2) && ((b * NB) != 256) && ((b * NB) != 128)) begin
              tb_error($sformatf("burst monitor: engine %0d rebuilt tile burst of %0d beats, must be 256 or 128 bytes", e, b)); viol_count++;
            end
            if ((k == 2) && (b == 1)) begin tb_error($sformatf("burst monitor: engine %0d single-beat rebuilt-picture AW", e)); viol_count++; end
          end
        end
      end
    end
  end

  function automatic int count_of(input int e, input int k);
    int n;
    n = 0;
    for (int b = 1; b <= 16; b++) n += hist[e][k][b];
    return n;
  endfunction

  // Print the histograms; max_ring_tail1 bounds the single-beat ring bursts (slice, ring and 4 KiB tails).
  task automatic report(input int max_ring_tail1);
    string names [5];
    names[0] = "AR_input   ";
    names[1] = "AW_ring    ";
    names[2] = "AW_index   ";
    names[3] = "AW_rebuilt ";
    names[4] = "AR_reference";
    for (int e = 0; e < NE; e++) begin
      for (int k = 0; k < 5; k++) begin
        string line;
        line = $sformatf("HIST eng%0d %s bursts=%0d beats:count", e, names[k], count_of(e, k));
        for (int b = 1; b <= 16; b++) begin
          if (hist[e][k][b] != 0) line = {line, $sformatf(" %0d:%0d", b, hist[e][k][b])};
        end
        $display("%s", line);
      end
      if (AXI_W == 128) begin
        tb_check(hist[e][4][16] == hist[e][4][8], $sformatf("burst monitor: engine %0d has %0d luma and %0d chroma reference reads", e, hist[e][4][16], hist[e][4][8]));
      end else begin
        tb_check((hist[e][4][16] % 3) == 0, $sformatf("burst monitor: engine %0d has %0d reference reads of 128 bytes, not three per chroma tile", e, hist[e][4][16]));
      end
      tb_check(hist[e][1][16 / NB] <= max_ring_tail1,
               $sformatf("burst monitor: engine %0d has %0d one-word ring bursts, more than the %0d tails of the run", e, hist[e][1][16 / NB], max_ring_tail1));
      $display("SUMMARY eng%0d single-beat AR %0d, ring AW tails %0d (limit %0d), index AW 1-beat %0d, rebuilt AW 1-beat %0d, reference reads %0d x 16 beats and %0d x 8 beats",
               e, hist[e][0][1] + hist[e][4][1], hist[e][1][16 / NB], max_ring_tail1, hist[e][2][1], hist[e][3][1], hist[e][4][16], hist[e][4][8]);
    end
  endtask

endmodule
