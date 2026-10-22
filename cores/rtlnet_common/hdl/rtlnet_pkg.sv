// -----------------------------------------------------------------------------
// File: rtlnet_pkg.sv
// Purpose: single source of the constants and pure functions every RTLNet core
//   shares: the RTLNet stream geometry, Ethernet/IP protocol numbers, byte-order
//   helpers, TKEEP decode, CRC-32 (IEEE 802.3 FCS) and the RFC 1071
//   ones'-complement checksum helpers.
// Overview:
//   * RTLNet stream: 64-bit tdata, frame byte 0 in tdata[7:0], 8-bit tkeep
//     contiguous from bit 0 on the final beat (documentation/rtlnet_architecture.md
//     section 4).
//   * be16/be32/be48 convert between "bus order" (first wire byte in the low
//     lane) and "number order" (first wire byte most significant). Each is its
//     own inverse.
//   * crc32_byte/crc32_bytes are written as bit loops; synthesis unrolls them
//     into balanced XOR networks. Reflected polynomial 0xEDB88320, initial value
//     0xFFFFFFFF, residue 0xDEBB20E3 over frame + FCS (IEEE 802.3 clause 3.2.9).
//   * All functions are automatic and side-effect free so every FPGA and ASIC
//     synthesis tool accepts them.
// Language: SystemVerilog-2012 (synthesizable package).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: none (package).
// -----------------------------------------------------------------------------
package rtlnet_pkg;

  // ---------------------------------------------------------------------------
  // RTLNet stream geometry
  // ---------------------------------------------------------------------------
  localparam int RTLNET_DATA_W = 64;
  localparam int RTLNET_KEEP_W = RTLNET_DATA_W / 8;

  // Largest client frame (destination MAC to last payload/pad byte, no FCS).
  localparam int ETH_MAX_FRAME_BYTES = 1518;
  // Smallest client frame the MAC accepts on transmit (one Ethernet header).
  localparam int ETH_MIN_TX_BYTES    = 14;
  // Smallest frame on the wire excluding FCS (IEEE 802.3 minimum 64 with FCS).
  localparam int ETH_MIN_FRAME_BYTES = 60;

  // ---------------------------------------------------------------------------
  // Protocol numbers (IANA / IEEE)
  // ---------------------------------------------------------------------------
  localparam logic [15:0] ETHERTYPE_IPV4 = 16'h0800;
  localparam logic [15:0] ETHERTYPE_ARP  = 16'h0806;
  localparam logic [15:0] ETHERTYPE_VLAN = 16'h8100;
  localparam logic [15:0] ETHERTYPE_IPV6 = 16'h86DD;
  localparam logic [7:0]  IP_PROTO_ICMP  = 8'd1;
  localparam logic [7:0]  IP_PROTO_TCP   = 8'd6;
  localparam logic [7:0]  IP_PROTO_UDP   = 8'd17;
  localparam logic [7:0]  IPV4_VER_IHL5  = 8'h45;
  localparam logic [7:0]  IPV4_TTL       = 8'd64;

  // Ethernet preamble octet, start-of-frame delimiter (IEEE 802.3 clause 3.2.1/3.2.2).
  localparam logic [7:0]  ETH_PREAMBLE   = 8'h55;
  localparam logic [7:0]  ETH_SFD        = 8'hD5;

  // CRC-32 constants (IEEE 802.3 clause 3.2.9), reflected form.
  localparam logic [31:0] CRC32_POLY_REFLECTED = 32'hEDB88320;
  localparam logic [31:0] CRC32_INITIAL        = 32'hFFFFFFFF;
  localparam logic [31:0] CRC32_RESIDUE        = 32'hDEBB20E3;

  // Default node address: a locally administered unicast MAC (bit 1 of octet 0
  // set, bit 0 clear) and a static IPv4 address. Firmware overrides both.
  localparam logic [47:0] DEFAULT_LOCAL_MAC = 48'h02_49_4B_52_4E_01;
  localparam logic [31:0] DEFAULT_LOCAL_IP  = {8'd192, 8'd168, 8'd1, 8'd220};

  // ---------------------------------------------------------------------------
  // Byte-order helpers: bus order (first wire byte in bits [7:0]) <-> number
  // order (first wire byte most significant). Each is its own inverse.
  // ---------------------------------------------------------------------------
  function automatic logic [15:0] be16(input logic [15:0] x);
    return {x[7:0], x[15:8]};
  endfunction

  function automatic logic [31:0] be32(input logic [31:0] x);
    return {x[7:0], x[15:8], x[23:16], x[31:24]};
  endfunction

  function automatic logic [47:0] be48(input logic [47:0] x);
    return {x[7:0], x[15:8], x[23:16], x[31:24], x[39:32], x[47:40]};
  endfunction

  // ---------------------------------------------------------------------------
  // TKEEP helpers. keep_bytes returns 0 for an empty or non-contiguous mask, so
  // a caller treats 0 as malformed. An eight-way case, not a popcount.
  // ---------------------------------------------------------------------------
  function automatic logic [3:0] keep_bytes(input logic [7:0] keep);
    case (keep)
      8'h01:   return 4'd1;
      8'h03:   return 4'd2;
      8'h07:   return 4'd3;
      8'h0F:   return 4'd4;
      8'h1F:   return 4'd5;
      8'h3F:   return 4'd6;
      8'h7F:   return 4'd7;
      8'hFF:   return 4'd8;
      default: return 4'd0;
    endcase
  endfunction

  // Contiguous mask for n bytes, n = 0..8.
  function automatic logic [7:0] keep_mask(input logic [3:0] n);
    case (n)
      4'd0:    return 8'h00;
      4'd1:    return 8'h01;
      4'd2:    return 8'h03;
      4'd3:    return 8'h07;
      4'd4:    return 8'h0F;
      4'd5:    return 8'h1F;
      4'd6:    return 8'h3F;
      4'd7:    return 8'h7F;
      default: return 8'hFF;
    endcase
  endfunction

  // Mask covering lanes 0..lane (inclusive), lane = 0..7.
  function automatic logic [7:0] keep_through_lane(input logic [2:0] lane);
    return keep_mask({1'b0, lane} + 4'd1);
  endfunction

  // ---------------------------------------------------------------------------
  // CRC-32, reflected, LSB of each octet first (IEEE 802.3 FCS).
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] crc32_byte(input logic [31:0] crc, input logic [7:0] data);
    logic [31:0] c;
    c = crc;
    for (int crc_bit = 0; crc_bit < 8; crc_bit++) begin
      if (c[0] ^ data[crc_bit]) c = (c >> 1) ^ CRC32_POLY_REFLECTED;
      else                c = (c >> 1);
    end
    return c;
  endfunction

  // Absorb the low `count` bytes (0..8) of a beat, byte 0 first.
  function automatic logic [31:0] crc32_bytes(input logic [31:0] crc, input logic [63:0] data,
                                              input logic [3:0] count);
    logic [31:0] c;
    c = crc;
    for (int crc_lane = 0; crc_lane < 8; crc_lane++) begin
      if (crc_lane < count) c = crc32_byte(c, data[8*crc_lane +: 8]);
    end
    return c;
  endfunction

  // ---------------------------------------------------------------------------
  // RFC 1071 ones'-complement arithmetic.
  // Sums are carried unfolded in 32 bits; csum_fold16 folds end-around carry
  // twice (the first fold leaves at most one carry bit).
  // ---------------------------------------------------------------------------
  function automatic logic [15:0] csum_fold16(input logic [31:0] sum);
    logic [31:0] s;
    s = {16'd0, sum[15:0]} + {16'd0, sum[31:16]};
    s = {16'd0, s[15:0]} + {16'd0, s[31:16]};
    return s[15:0];
  endfunction

  // Sum of the four big-endian 16-bit words of a bus-order beat, lanes outside
  // `lanes` forced to zero (an odd final byte becomes a zero-padded word).
  // Valid when the checksummed region starts at an even frame offset.
  function automatic logic [17:0] beat_word_sum(input logic [63:0] data, input logic [7:0] lanes);
    logic [63:0] d;
    logic [17:0] s;
    for (int sum_lane = 0; sum_lane < 8; sum_lane++) d[8*sum_lane +: 8] = lanes[sum_lane] ? data[8*sum_lane +: 8] : 8'h00;
    s = 18'd0;
    for (int sum_word = 0; sum_word < 4; sum_word++) s = s + {2'b00, d[16*sum_word +: 8], d[16*sum_word + 8 +: 8]};
    return s;
  endfunction

  // IPv4 header checksum over a 20-byte header with no options, given the
  // fields in number order (RFC 791 section 3.1, RFC 1071).
  function automatic logic [15:0] ipv4_header_checksum(
      input logic [7:0]  tos,
      input logic [15:0] total_length,
      input logic [15:0] identification,
      input logic [15:0] flags_fragment,
      input logic [7:0]  ttl,
      input logic [7:0]  protocol,
      input logic [31:0] src_ip,
      input logic [31:0] dst_ip);
    logic [31:0] s;
    s = {16'd0, IPV4_VER_IHL5, tos}
      + {16'd0, total_length}
      + {16'd0, identification}
      + {16'd0, flags_fragment}
      + {16'd0, ttl, protocol}
      + {16'd0, src_ip[31:16]} + {16'd0, src_ip[15:0]}
      + {16'd0, dst_ip[31:16]} + {16'd0, dst_ip[15:0]};
    return ~csum_fold16(s);
  endfunction

  // ---------------------------------------------------------------------------
  // Register-map helpers
  // ---------------------------------------------------------------------------
  // Four ASCII characters as a 32-bit ID word, first character most significant.
  function automatic logic [31:0] id4(input logic [7:0] a, input logic [7:0] b,
                                      input logic [7:0] c, input logic [7:0] d);
    return {a, b, c, d};
  endfunction

  // Integer ceiling log2 for elaboration-time sizing (returns 0 for x <= 1).
  function automatic int clog2i(input int x);
    int r;
    r = 0;
    while ((1 << r) < x) r++;
    return r;
  endfunction

endpackage
