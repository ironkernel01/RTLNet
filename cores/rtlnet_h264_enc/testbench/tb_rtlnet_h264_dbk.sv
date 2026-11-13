// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_dbk.sv
// Purpose: self-checking bench of rtlnet_h264_deblock (the in-loop deblocking filter and the delayed reference write) against the clause 8.7 model
//   of h264_deblock_model.py (vectors from h264_dbk_vec.py).
// Overview:
//   * +VEC=<prefix>: reads <prefix>_vec.hex (header, per macroblock information and the 96 rebuilt words) and <prefix>_exp.hex (filtered tiles).
//     The bench plays the engine: it loads each macroblock into a rebuilt-RAM model, pulses mb_start when mb_ready is high, waits for mb_taken,
//     and goes on with the next macroblock after a random pause (+GAP=<max clocks>), so the unit overlaps its work with the next macroblock.
//   * The write master is modelled: random acceptance of descriptors and beats; every burst is checked (INCR 16-byte beats, 8 beats or more, aligned,
//     not crossing 4 KiB) and the beats are applied with their byte strobes to a luma and a chroma tile memory. The final memory must equal the
//     expected tiles byte for byte and every byte must have been written exactly once.
//   * +INJECT_FAILURE forces one failed check (negative control). +SEED=<n> seeds the random handshakes.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-12-2026
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_dbk;

  import rtlnet_tb_pkg::*;

  localparam int MAXW   = 120000;
  localparam int MAXMB  = 1024;
  localparam int YBASE  = 32'h0010_0000;
  localparam int CBASE  = 32'h0020_0000;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #5 clk = ~clk;

  // DUT ports.
  logic        pic_start = 1'b0;
  logic [7:0]  cfg_mb_w = 8'd0, cfg_band_rows = 8'd0;
  logic        cfg_en = 1'b0;
  logic signed [3:0] cfg_a = '0, cfg_b = '0;
  logic [5:0]  cfg_qp = '0;
  logic        mb_start = 1'b0;
  logic        mb_ready, mb_taken;
  logic [7:0]  mb_x = '0;
  logic        mb_avt = 1'b0, mb_intra = 1'b0, mb_pcm = 1'b0, mb_t8 = 1'b0;
  logic [15:0] mb_nz = '0;
  logic signed [13:0] mb_mvx = '0, mb_mvy = '0;
  logic [31:0] mb_ty = '0, mb_tc = '0;
  logic [7:0]  mb_base = 8'd0;
  logic        ram_rd_en;
  logic [7:0]  ram_rd_addr;
  logic [31:0] ram_rd_data = '0;
  logic        rc_valid;
  logic [31:0] rc_addr;
  logic [3:0]  rc_len;
  logic        rc_pop = 1'b0;
  logic        rc_w_valid;
  logic [127:0] rc_w_data;
  logic [15:0] rc_w_strb;
  logic        rc_w_pop = 1'b0;
  logic        idle;

  rtlnet_h264_deblock #(.ADDR_W(32), .LINE_KB(16), .REC_AW(8), .RAM_STYLE("block"), .WIN_STYLE("distributed")) dut (.*);

  // Vectors and memories.
  logic [31:0] vec [MAXW];
  logic [31:0] expw [MAXMB * 96];
  logic [31:0] rec [256];
  byte unsigned ymem [MAXMB * 256];
  byte unsigned cmem [MAXMB * 128];
  int          ycnt [MAXMB * 256];
  int          ccnt [MAXMB * 128];
  string       prefix;
  int          seed;
  logic [31:0] rng = 32'h1234_5678;
  function automatic int rnd(input int n);
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return int'(rng % 32'(n));
  endfunction
  int          gap;
  int          mbw, mbh, nmb;
  int          fails;
  int          bursts, beats_l, beats_c;

  // +TRACE: state changes of the unit.
  logic trace_on;
  initial trace_on = $test$plusargs("TRACE");
  always @(dut.st) if (trace_on) $display("%0t st=%0d x=%0d row=%0d cnt=%0d", $time, dut.st, dut.c_x, dut.row_i, dut.cnt);

  // Rebuilt RAM model: latency 1.
  always @(posedge clk) begin
    if (ram_rd_en) ram_rd_data <= rec[ram_rd_addr];
  end

  // Write master model.
  int          wm_left;
  logic [31:0] wm_addr;
  int          wm_beat;
  int          rnd_a, rnd_b;
  always @(negedge clk) begin
    rc_pop   <= 1'b0;
    rc_w_pop <= 1'b0;
    if (resetn) begin
      if (wm_left == 0) begin
        if (rc_valid && !rc_pop && (rnd(100) < 60)) begin
          rc_pop <= 1'b1;
          wm_left = int'(rc_len) + 1;
          wm_addr = rc_addr;
          wm_beat = 0;
          bursts++;
          if (wm_left < 8) tb_error($sformatf("burst of %0d beats at %08x", wm_left, rc_addr));
          if (rc_addr[3:0] != 4'd0) tb_error($sformatf("unaligned burst %08x", rc_addr));
          if (((rc_addr & 32'hFFF) + wm_left * 16) > 4096) tb_error($sformatf("burst %08x x %0d crosses 4 KiB", rc_addr, wm_left));
          if (rc_addr >= CBASE) beats_c += wm_left; else beats_l += wm_left;
        end
      end else if (rc_w_valid && (rnd(100) < 70) && !rc_w_pop) begin
        rc_w_pop <= 1'b1;
        for (int b = 0; b < 16; b++) begin
          if (rc_w_strb[b]) begin
            automatic int a = int'(wm_addr) + wm_beat * 16 + b;
            if (a >= CBASE) begin
              if (((a - CBASE) < MAXMB * 128)) begin cmem[a - CBASE] = rc_w_data[8*b +: 8]; ccnt[a - CBASE]++; end
            end else begin
              if (((a - YBASE) < MAXMB * 256)) begin ymem[a - YBASE] = rc_w_data[8*b +: 8]; ycnt[a - YBASE]++; end
            end
          end
        end
        wm_beat++;
        wm_left--;
      end
    end
  end

  task automatic load_mb(input int m);
    int base;
    base = 6 + m * 100;
    for (int i = 0; i < 96; i++) rec[i] = vec[base + 4 + i];
  endtask

  int mism_y, mism_c, once_bad;
  initial begin
    fails = 0; bursts = 0; beats_l = 0; beats_c = 0; wm_left = 0; seed = 1; gap = 0;
    if (!$value$plusargs("VEC=%s", prefix)) begin
      tb_error("no +VEC");
      tb_verdict("tb_rtlnet_h264_dbk");
    end
    void'($value$plusargs("SEED=%d", seed));
    rng = 32'h1234_5678 ^ (32'(seed) * 32'h9E37_79B9);
    void'($value$plusargs("GAP=%d", gap));
    $readmemh({prefix, "_vec.hex"}, vec);
    $readmemh({prefix, "_exp.hex"}, expw);
    mbw = int'(vec[0]);
    mbh = int'(vec[1]);
    nmb = mbw * mbh;
    resetn = 1'b0;
    repeat (6) @(negedge clk);
    resetn = 1'b1;
    repeat (3) @(negedge clk);
    cfg_mb_w = 8'(mbw);
    cfg_band_rows = 8'(mbh);
    cfg_en = vec[2][0];
    cfg_a = vec[3][3:0];
    cfg_b = vec[4][3:0];
    cfg_qp = vec[5][5:0];
    pic_start = 1'b1;
    @(negedge clk);
    pic_start = 1'b0;
    @(negedge clk);
    for (int m = 0; m < nmb; m++) begin
      automatic int ib = 6 + m * 100;
      while (!mb_ready) @(negedge clk);
      load_mb(m);
      mb_x     = vec[ib][7:0];
      mb_avt   = vec[ib][8];
      mb_intra = vec[ib][9];
      mb_pcm   = vec[ib][10];
      mb_t8    = vec[ib][11];
      mb_nz    = vec[ib + 1][15:0];
      mb_mvx   = vec[ib + 2][13:0];
      mb_mvy   = vec[ib + 3][13:0];
      mb_ty    = YBASE + 256 * m;
      mb_tc    = CBASE + 128 * m;
      mb_base  = 8'd0;
      mb_start = 1'b1;
      @(negedge clk);
      mb_start = 1'b0;
      while (!mb_taken) @(negedge clk);
      if (gap > 0) repeat (rnd(gap + 1)) @(negedge clk);
    end
    // wait for the unit to go idle and the writer to drain
    repeat (50) @(negedge clk);
    begin
      automatic int guard = 0;
      while (!idle && guard < 200000) begin @(negedge clk); guard++; end
      repeat (200) @(negedge clk);
      while (wm_left != 0 && guard < 400000) begin @(negedge clk); guard++; end
    end
    tb_check(idle, "unit idle at the end");
    mism_y = 0; mism_c = 0; once_bad = 0;
    for (int m = 0; m < nmb; m++) begin
      for (int w = 0; w < 96; w++) begin
        for (int b = 0; b < 4; b++) begin
          automatic int off = (w < 64) ? (m * 256 + w * 4 + b) : (m * 128 + (w - 64) * 4 + b);
          automatic logic [7:0] g = (w < 64) ? ymem[off] : cmem[off];
          automatic int   c = (w < 64) ? ycnt[off] : ccnt[off];
          if (g !== expw[m * 96 + w][8*b +: 8]) begin
            if (w < 64) mism_y++; else mism_c++;
            if (mism_y + mism_c == 1) tb_error($sformatf("first mismatch: mb %0d (x %0d y %0d) word %0d byte %0d got %02x expected %02x", m, m % mbw, m / mbw, w, b, g,
                                                          expw[m * 96 + w][8*b +: 8]));
          end
          if (c != 1) once_bad++;
        end
      end
    end
    tb_check(mism_y == 0, $sformatf("%0d luma byte mismatches", mism_y));
    tb_check(mism_c == 0, $sformatf("%0d chroma byte mismatches", mism_c));
    tb_check(once_bad == 0, $sformatf("%0d bytes not written exactly once", once_bad));
    $display("NOTE: tb_rtlnet_h264_dbk: %0d macroblocks, %0d bursts, %0d luma beats, %0d chroma beats (%0d beats per macroblock)", nmb, bursts, beats_l, beats_c,
             (beats_l + beats_c) / nmb);
    if ($test$plusargs("INJECT_FAILURE")) tb_error("injected failure");
    tb_verdict("tb_rtlnet_h264_dbk");
  end

  initial begin
    #400ms;
    tb_error("timeout");
    tb_verdict("tb_rtlnet_h264_dbk");
  end

endmodule
