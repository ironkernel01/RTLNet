// -----------------------------------------------------------------------------
// File: tb_rtlnet_ipv4_csum_pipe.sv
// Purpose: self-checking bench of rtlnet_ipv4_csum_pipe against rtlnet_pkg::ipv4_header_checksum.
// Cases: 20000 header field sets (corner sets, then random) each held for 4 clocks; the output must equal the function;
//   then inputs changing every clock: the output follows with three register stages of delay.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-14-2026
//   * 11-14-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_ipv4_csum_pipe;

  import rtlnet_pkg::*;
  import rtlnet_tb_pkg::*;

  logic        clk = 1'b0;
  logic [7:0]  tos = '0;
  logic [15:0] tl = '0;
  logic [15:0] id = '0;
  logic [15:0] ff = '0;
  logic [7:0]  ttl = '0;
  logic [7:0]  proto = '0;
  logic [31:0] sip = '0;
  logic [31:0] dip = '0;
  logic [15:0] csum;

  always #5.0 clk = ~clk;

  rtlnet_ipv4_csum_pipe dut (
    .clk(clk), .tos(tos), .total_length(tl), .identification(id), .flags_fragment(ff), .ttl(ttl), .protocol(proto),
    .src_ip(sip), .dst_ip(dip), .csum(csum));

  logic [15:0] exp_q [0:2];

  function automatic logic [15:0] expected();
    return ipv4_header_checksum(tos, tl, id, ff, ttl, proto, sip, dip);
  endfunction

  task automatic drive(input logic [7:0] a, input logic [15:0] b, input logic [15:0] c, input logic [15:0] d,
                       input logic [7:0] e, input logic [7:0] f, input logic [31:0] g, input logic [31:0] h);
    tos = a; tl = b; id = c; ff = d; ttl = e; proto = f; sip = g; dip = h;
  endtask

  initial begin
    automatic int unsigned seed = 32'h1234_5678;
    automatic logic [15:0] want;
    for (int n = 0; n < 20000; n++) begin
      case (n)
        0: drive(8'h00, 16'h0000, 16'h0000, 16'h0000, 8'h00, 8'h00, 32'h0, 32'h0);
        1: drive(8'hFF, 16'hFFFF, 16'hFFFF, 16'hFFFF, 8'hFF, 8'hFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
        2: drive(8'h00, 16'hFFFF, 16'h0000, 16'h0000, 8'h00, 8'h00, 32'h0000_0000, 32'h0000_0000);
        3: drive(8'h00, 16'h0001, 16'h0000, 16'h0000, 8'h00, 8'h00, 32'hFFFE_0000, 32'h0000_0000);
        default: drive($urandom(seed), $urandom(seed), $urandom(seed), $urandom(seed), $urandom(seed), $urandom(seed),
                       $urandom(seed), $urandom(seed));
      endcase
      want = expected();
      repeat (4) @(posedge clk);
      #1;
      tb_check(csum === want, $sformatf("set %0d: csum %04x, expected %04x", n, csum, want));
    end
    exp_q[0] = '0; exp_q[1] = '0; exp_q[2] = '0;
    for (int n = 0; n < 2000; n++) begin
      drive($urandom(seed), $urandom(seed), $urandom(seed), $urandom(seed), $urandom(seed), $urandom(seed), $urandom(seed), $urandom(seed));
      exp_q[2] = exp_q[1]; exp_q[1] = exp_q[0]; exp_q[0] = expected();
      @(posedge clk);
      #1;
      if (n >= 4) tb_check(csum === exp_q[2], $sformatf("streaming %0d: csum %04x, expected %04x", n, csum, exp_q[2]));
    end
    tb_verdict("tb_rtlnet_ipv4_csum_pipe");
  end

endmodule
