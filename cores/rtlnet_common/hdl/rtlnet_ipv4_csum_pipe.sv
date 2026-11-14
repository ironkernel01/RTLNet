// -----------------------------------------------------------------------------
// File: rtlnet_ipv4_csum_pipe.sv
// Purpose: pipelined IPv4 header checksum for the protocol leaves: the same value as rtlnet_pkg::ipv4_header_checksum,
//   computed in three register stages so that no stage is longer than one ternary adder (a leaf at 100 MHz cannot afford
//   the nine-operand sum and two folds of the function in one clock).
// Overview:
//   * Free running, no handshake: the output is valid LATENCY (3) clocks after the inputs have been stable. The leaves hold
//     the header fields in registers for several clocks anyway (they wait for the checksum before the header leaves), so the
//     leaf waits LATENCY clocks in its checksum state instead of computing the checksum combinationally.
//   * Stage 1: three sums of three 16-bit words each. Stage 2: the three sums added. Stage 3: end-around carry folded twice
//     and inverted (RFC 1071, as csum_fold16).
//   * No reset: the registers carry data only; the value is meaningful only LATENCY clocks after stable inputs.
// Language: SystemVerilog-2012.
// Revision: 11-14-2026
//   * 11-14-2026: initial version.
// Clocks: clk, every input and the output synchronous to it.
// -----------------------------------------------------------------------------
module rtlnet_ipv4_csum_pipe
  import rtlnet_pkg::*;
(
  input  logic        clk,

  // Header fields (hold them stable for LATENCY clocks).
  input  logic [7:0]  tos,
  input  logic [15:0] total_length,
  input  logic [15:0] identification,
  input  logic [15:0] flags_fragment,
  input  logic [7:0]  ttl,
  input  logic [7:0]  protocol,
  input  logic [31:0] src_ip,
  input  logic [31:0] dst_ip,

  // The header checksum, as rtlnet_pkg::ipv4_header_checksum, LATENCY clocks after the inputs.
  output logic [15:0] csum
);

  localparam int LATENCY = 3;

  logic [17:0] g0;
  logic [17:0] g1;
  logic [17:0] g2;
  logic [19:0] t;
  logic [16:0] f1;
  logic [15:0] f2;

  always_ff @(posedge clk) begin
    g0 <= {2'd0, IPV4_VER_IHL5, tos} + {2'd0, total_length} + {2'd0, identification};
    g1 <= {2'd0, flags_fragment} + {2'd0, ttl, protocol} + {2'd0, src_ip[31:16]};
    g2 <= {2'd0, src_ip[15:0]} + {2'd0, dst_ip[31:16]} + {2'd0, dst_ip[15:0]};
    t  <= {2'd0, g0} + {2'd0, g1} + {2'd0, g2};
    csum <= ~f2;
  end

  always_comb begin
    f1 = {1'b0, t[15:0]} + {13'd0, t[19:16]};
    f2 = f1[15:0] + {15'd0, f1[16]};
  end

endmodule
