// -----------------------------------------------------------------------------
// File: tb_rtlnet_primitives.sv
// Purpose: self-checking bench for the small shared primitives and the shared
//   package: rtlnet_pulse_sync, rtlnet_gray_sync, rtlnet_sync,
//   rtlnet_reset_sync, rtlnet_ram_core (block and distributed, read latency 1
//   and 2, common and independent clocks) and the rtlnet_pkg functions.
// Cases:
//   1. rtlnet_pkg: crc32_bytes against the independent serial oracle on 200
//      random frames, the "123456789" check value 0xCBF43926, the FCS residue
//      0xDEBB20E3; keep_bytes/keep_mask round trip; be16/be32/be48 inverses;
//      ipv4_header_checksum against the bench's RFC 1071 builder.
//   2. Pulse crossing: 500 events, slow-to-fast and fast-to-slow, spaced by
//      at least 4 destination periods, all delivered, none duplicated.
//   3. Gray counter crossing: a counter stepping randomly by 0 or 1 in the
//      source; the destination value never decreases, never exceeds the source
//      and equals it after the source stops.
//   4. Reset synchronizer: asserts with the clock stopped, releases after
//      STAGES edges.
//   5. RAM core: 4 configurations write/read random words; data holds while
//      rd_en is low; reset clears the output register.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_primitives;

  import rtlnet_pkg::*;
  import rtlnet_tb_pkg::*;

  logic clk_a = 0;   // 100 MHz
  logic clk_b = 0;   // 33.3 MHz
  logic arstn = 0;
  logic a_resetn, b_resetn;
  bit   stop_b = 0;

  always #5.0  clk_a = ~clk_a;
  always #15.0 if (!stop_b) clk_b = ~clk_b;

  rtlnet_reset_sync u_ra (.clk(clk_a), .arstn(arstn), .resetn(a_resetn));
  rtlnet_reset_sync u_rb (.clk(clk_b), .arstn(arstn), .resetn(b_resetn));

  // ---------------------------------------------------------------------------
  // Pulse crossings both ways
  // ---------------------------------------------------------------------------
  logic ab_src = 0, ab_dst, ba_src = 0, ba_dst;
  int   ab_seen = 0, ba_seen = 0;

  rtlnet_pulse_sync u_ps_ab (.src_clk(clk_a), .src_resetn(a_resetn), .src_pulse(ab_src),
                             .dst_clk(clk_b), .dst_resetn(b_resetn), .dst_pulse(ab_dst));
  rtlnet_pulse_sync u_ps_ba (.src_clk(clk_b), .src_resetn(b_resetn), .src_pulse(ba_src),
                             .dst_clk(clk_a), .dst_resetn(a_resetn), .dst_pulse(ba_dst));
  always @(posedge clk_b) if (ab_dst) ab_seen++;
  always @(posedge clk_a) if (ba_dst) ba_seen++;

  // ---------------------------------------------------------------------------
  // Gray counter crossing fast -> slow
  // ---------------------------------------------------------------------------
  logic [15:0] g_src = 0;
  logic [15:0] g_dst;
  logic        g_run = 0;
  logic [15:0] g_dst_prev = 0;
  int unsigned g_rng = 5;

  rtlnet_gray_sync #(.WIDTH(16)) u_gs (.src_clk(clk_a), .src_resetn(a_resetn), .src_count(g_src),
                                       .dst_clk(clk_b), .dst_resetn(b_resetn), .dst_count(g_dst));
  always @(posedge clk_a) begin
    g_rng = g_rng * 1103515245 + 12345;
    if (a_resetn && g_run && ((g_rng >> 16) & 1)) g_src <= g_src + 1'b1;
  end
  always @(posedge clk_b) begin
    if (b_resetn) begin
      if (g_dst < g_dst_prev) tb_error($sformatf("gray: count went backwards %0d -> %0d", g_dst_prev, g_dst));
      if (g_dst > g_src)      tb_error($sformatf("gray: count %0d ahead of source %0d", g_dst, g_src));
      g_dst_prev <= g_dst;
    end else begin
      g_dst_prev <= '0;
    end
  end

  // ---------------------------------------------------------------------------
  // RAM core in four configurations
  // ---------------------------------------------------------------------------
  localparam int RW = 20;
  localparam int RA = 6;
  logic [RA-1:0] r_waddr, r_raddr;
  logic [RW-1:0] r_wdata;
  logic          r_wen = 0, r_ren = 0;
  logic [RW-1:0] r_q [0:3];

  rtlnet_ram_core #(.RAM_STYLE("block"), .CLOCKING("INDEPENDENT"), .DATA_W(RW), .ADDR_W(RA), .READ_LATENCY(1)) u_ram0 (
    .wr_clk(clk_a), .wr_en(r_wen), .wr_addr(r_waddr), .wr_data(r_wdata),
    .rd_clk(clk_a), .rd_resetn(a_resetn), .rd_en(r_ren), .rd_addr(r_raddr), .rd_data(r_q[0]));
  rtlnet_ram_core #(.RAM_STYLE("block"), .CLOCKING("COMMON"), .DATA_W(RW), .ADDR_W(RA), .READ_LATENCY(2)) u_ram1 (
    .wr_clk(clk_a), .wr_en(r_wen), .wr_addr(r_waddr), .wr_data(r_wdata),
    .rd_clk(clk_a), .rd_resetn(a_resetn), .rd_en(r_ren), .rd_addr(r_raddr), .rd_data(r_q[1]));
  rtlnet_ram_core #(.RAM_STYLE("distributed"), .CLOCKING("COMMON"), .DATA_W(RW), .ADDR_W(RA), .READ_LATENCY(1)) u_ram2 (
    .wr_clk(clk_a), .wr_en(r_wen), .wr_addr(r_waddr), .wr_data(r_wdata),
    .rd_clk(clk_a), .rd_resetn(a_resetn), .rd_en(r_ren), .rd_addr(r_raddr), .rd_data(r_q[2]));
  rtlnet_ram_core #(.RAM_STYLE("distributed"), .CLOCKING("INDEPENDENT"), .DATA_W(RW), .ADDR_W(RA), .READ_LATENCY(2)) u_ram3 (
    .wr_clk(clk_a), .wr_en(r_wen), .wr_addr(r_waddr), .wr_data(r_wdata),
    .rd_clk(clk_a), .rd_resetn(a_resetn), .rd_en(r_ren), .rd_addr(r_raddr), .rd_data(r_q[3]));

  logic [RW-1:0] r_model [0:(1<<RA)-1];

  // ---------------------------------------------------------------------------
  // Sequence
  // ---------------------------------------------------------------------------
  initial begin : main
    bytes_t      f;
    bytes_t      fcs;
    logic [31:0] c;
    int unsigned rng;
    bytes_t      hdr;
    logic [15:0] hc;
    logic [7:0]  ascii [9];

    rng = 77;

    // Case 1: package functions.
    for (int k = 0; k < 200; k++) begin
      int n;
      rng = rng * 1664525 + 1013904223;
      n = 1 + (rng >> 20) % 200;
      f = {};
      for (int i = 0; i < n; i++) begin rng = rng * 1664525 + 1013904223; f.push_back(8'(rng >> 24)); end
      c = CRC32_INITIAL;
      for (int i = 0; i < n; i += 8) begin
        logic [63:0] w;
        int cnt;
        w = '0;
        cnt = (n - i >= 8) ? 8 : n - i;
        for (int l = 0; l < cnt; l++) w[8*l +: 8] = f[i + l];
        c = crc32_bytes(c, w, 4'(cnt));
      end
      fcs = crc32_serial_fcs(f);
      tb_check(~c == {fcs[3], fcs[2], fcs[1], fcs[0]},
               $sformatf("crc32_bytes vs serial oracle, %0d bytes: 0x%08x vs 0x%02x%02x%02x%02x", n, ~c, fcs[3], fcs[2], fcs[1], fcs[0]));
      // Residue over frame + FCS.
      for (int i = 0; i < $size(fcs); i++) c = crc32_byte(c, fcs[i]);
      tb_check(c == CRC32_RESIDUE, $sformatf("FCS residue 0x%08x", c));
    end
    f = {};
    ascii = '{8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37, 8'h38, 8'h39};
    for (int i = 0; i < $size(ascii); i++) f.push_back(ascii[i]);
    tb_check(crc32_check_value(f) == 32'hCBF43926, $sformatf("serial oracle check value 0x%08x", crc32_check_value(f)));
    c = CRC32_INITIAL;
    for (int i = 0; i < $size(f); i++) c = crc32_byte(c, f[i]);
    tb_check(~c == 32'hCBF43926, $sformatf("crc32_byte check value 0x%08x", ~c));
    for (int n = 0; n <= 8; n++) tb_check(keep_bytes(keep_mask(4'(n))) == ((n == 0) ? 0 : n), $sformatf("keep round trip %0d", n));
    tb_check(keep_bytes(8'h05) == 0 && keep_bytes(8'h80) == 0, "non-contiguous keep");
    tb_check(be16(be16(16'h1234)) == 16'h1234 && be16(16'h1234) == 16'h3412, "be16");
    tb_check(be32(32'h11223344) == 32'h44332211, "be32");
    tb_check(be48(48'h112233445566) == 48'h665544332211, "be48");
    hdr = ipv4_header(16'd84, 16'h1C46, 8'd1, 32'hC0A80001, 32'hC0A800C7, 8'd64, 16'h4000, 8'h00);
    hc  = ipv4_header_checksum(8'h00, 16'd84, 16'h1C46, 16'h4000, 8'd64, 8'd1, 32'hC0A80001, 32'hC0A800C7);
    tb_check(hc == get16(hdr, 10), $sformatf("ipv4_header_checksum 0x%04x vs 0x%04x", hc, get16(hdr, 10)));
    tb_check(inet_sum(hdr, 0, 20) == 16'hFFFF, "IPv4 header folds to 0xFFFF");

    #100 arstn = 1'b1;
    repeat (20) @(posedge clk_b);

    // Case 2: pulse crossings.
    fork
      begin
        for (int k = 0; k < 500; k++) begin
          @(posedge clk_a) ab_src <= 1'b1;
          @(posedge clk_a) ab_src <= 1'b0;
          repeat (14) @(posedge clk_a);       // >= 4 clk_b periods
        end
      end
      begin
        for (int k = 0; k < 500; k++) begin
          @(posedge clk_b) ba_src <= 1'b1;
          @(posedge clk_b) ba_src <= 1'b0;
          repeat (2) @(posedge clk_b);        // >= 4 clk_a periods
        end
      end
    join
    repeat (20) @(posedge clk_b);
    tb_check(ab_seen == 500, $sformatf("pulse a->b delivered %0d of 500", ab_seen));
    tb_check(ba_seen == 500, $sformatf("pulse b->a delivered %0d of 500", ba_seen));

    // Case 3: Gray counter.
    g_run = 1;
    repeat (20000) @(posedge clk_a);
    g_run = 0;
    repeat (20) @(posedge clk_b);
    tb_check(g_dst == g_src && g_src > 1000, $sformatf("gray final %0d vs source %0d", g_dst, g_src));

    // Case 5: RAM core.
    for (int i = 0; i < (1 << RA); i++) begin
      rng = rng * 1664525 + 1013904223;
      @(posedge clk_a);
      r_wen <= 1; r_waddr <= RA'(i); r_wdata <= RW'(rng >> 8);
      r_model[i] = RW'(rng >> 8);
    end
    @(posedge clk_a) r_wen <= 0;
    for (int k = 0; k < 300; k++) begin
      int a;
      rng = rng * 1664525 + 1013904223;
      a = (rng >> 20) % (1 << RA);
      @(posedge clk_a); r_ren <= 1; r_raddr <= RA'(a);
      @(posedge clk_a); r_ren <= 0;
      @(posedge clk_a);
      #1;
      tb_check(r_q[0] == r_model[a] && r_q[2] == r_model[a],
               $sformatf("RAM latency-1 read %0d: %h %h expected %h", a, r_q[0], r_q[2], r_model[a]));
      @(posedge clk_a);
      #1;
      tb_check(r_q[1] == r_model[a] && r_q[3] == r_model[a],
               $sformatf("RAM latency-2 read %0d: %h %h expected %h", a, r_q[1], r_q[3], r_model[a]));
      repeat (3) @(posedge clk_a);
      #1;
      tb_check(r_q[0] == r_model[a] && r_q[1] == r_model[a] && r_q[2] == r_model[a] && r_q[3] == r_model[a],
               "RAM output did not hold with rd_en low");
    end

    // Case 4: reset synchronizer asserts with its clock stopped.
    stop_b = 1;
    #100;
    arstn = 1'b0;
    #1;
    tb_check(b_resetn == 1'b0, "reset sync did not assert with the clock stopped");
    arstn = 1'b1;
    stop_b = 0;
    repeat (3) @(posedge clk_b);
    #1;
    tb_check(b_resetn == 1'b0, "reset sync released before STAGES edges");
    repeat (2) @(posedge clk_b);
    #1;
    tb_check(b_resetn == 1'b1, "reset sync did not release after STAGES edges");
    // The same assertion reset the clk_a domain: every RAM output register
    // was cleared and holds zero with rd_en low.
    repeat (6) @(posedge clk_a);
    #1;
    tb_check(r_q[0] == '0 && r_q[1] == '0 && r_q[2] == '0 && r_q[3] == '0,
             $sformatf("RAM output not cleared by reset: %h %h %h %h", r_q[0], r_q[1], r_q[2], r_q[3]));
    tb_verdict("tb_rtlnet_primitives");
  end

  initial begin
    #20ms;
    tb_error("watchdog timeout");
    tb_verdict("tb_rtlnet_primitives");
  end

endmodule
