// -----------------------------------------------------------------------------
// File: rtlnet_udp_socket_pkg.sv
// Purpose: constants shared by the modules of the RTLNet UDP socket layer:
//   frame offsets of the Ethernet/IPv4/UDP headers the layer parses and
//   builds, the size limits, and the bit fields of the two metadata beats of
//   the application stream (documentation/rtlnet_architecture.md section 7.7).
// Overview:
//   * Application stream, both directions (64-bit RTLNet stream):
//       meta 0  [63:32] remote IPv4 address (first octet in [63:56])
//               [31:16] remote UDP port
//               [15:0]  payload length in bytes (0..MAX_PAYLOAD_BYTES)
//       meta 1  [63:56] socket index
//               [55:48] flags
//               [47:0]  remote MAC address (octet 0 in [47:40])
//       payload byte 0 in tdata[7:0], tkeep on the last beat, tlast.
//     A zero-length datagram is the two metadata beats with tlast on meta 1.
//   * Receive flags (socket layer to application): bit 0 BROADCAST (sent to
//     255.255.255.255 or to the subnet broadcast address), bit 1 OFF_SUBNET
//     (the sender is outside local_ip/local_mask). Bits 7:2 read 0.
//   * Transmit flags (application to socket layer): bit 0 USE_SOCKET_REMOTE
//     (take the destination IP, port and MAC from the socket registers instead
//     of the metadata). Bits 7:1 are reserved, written 0 and ignored; inside
//     the layer bit 7 carries the write-side length verdict (FLAG_TX_BAD).
//   * Register offsets live once, in driver/rtlnet_udp_socket.h; the register
//     file mirrors them as localparams.
// Language: SystemVerilog-2012 (synthesizable package).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: none (package).
// -----------------------------------------------------------------------------
package rtlnet_udp_socket_pkg;

  // ---------------------------------------------------------------------------
  // Frame geometry (byte offsets from the first byte of the Ethernet header)
  // ---------------------------------------------------------------------------
  localparam int UDP_PAYLOAD_OFFSET = 42;            // 14 Ethernet + 20 IPv4 + 8 UDP
  localparam int UDP_HEADER_OFFSET  = 34;            // first byte of the UDP header
  localparam int IPV4_HEADER_BYTES  = 20;            // IHL 5, no options
  localparam int UDP_HEADER_BYTES   = 8;
  localparam int IPV4_MTU_BYTES     = 1500;          // largest IPv4 total length accepted
  localparam int MAX_PAYLOAD_BYTES  = IPV4_MTU_BYTES - IPV4_HEADER_BYTES - UDP_HEADER_BYTES; // 1472
  localparam int META_BYTES         = 16;            // two metadata beats

  // Beat numbers of the receive parser (beat k = frame bytes 8k..8k+7).
  localparam int BEAT_IP_DST_LO     = 4;             // bytes 32..39: dst IP low, ports, UDP length
  localparam int BEAT_FIRST_PAYLOAD = 5;             // bytes 40..47: UDP checksum, payload 0..5

  // IPv4 header constants.
  localparam logic [15:0] IPV4_FLAGS_DF    = 16'h4000; // flags/fragment word sent: DF, offset 0
  localparam int          IPV4_MF_BIT      = 13;       // more-fragments bit of the flags/fragment word
  localparam logic [7:0]  IPV4_TOS_SENT    = 8'h00;
  localparam logic [31:0] IPV4_LIMITED_BCAST = 32'hFFFF_FFFF;

  // Socket index width in meta 1, and the index the write-side checker puts on
  // a datagram that never delivered a meta 1 beat (always out of range).
  localparam int          SOCK_IDX_W       = 8;
  localparam logic [7:0]  SOCK_IDX_NONE    = 8'hFF;
  localparam int          MAX_SOCKETS      = 60;       // 0x100 + 0x40*n must stay inside 4 KiB

  // ---------------------------------------------------------------------------
  // Metadata fields
  // ---------------------------------------------------------------------------
  localparam int META0_IP_LSB   = 32;
  localparam int META0_PORT_LSB = 16;
  localparam int META0_LEN_LSB  = 0;
  localparam int META1_SOCK_LSB = 56;
  localparam int META1_FLAG_LSB = 48;
  localparam int META1_MAC_LSB  = 0;

  localparam int FLAG_RX_BROADCAST         = 0;
  localparam int FLAG_RX_OFF_SUBNET        = 1;
  localparam int FLAG_TX_USE_SOCKET_REMOTE = 0;
  localparam int FLAG_TX_BAD               = 7;        // internal: datagram failed the write-side check

  // Build a metadata beat from its fields.
  function automatic logic [63:0] meta0_pack(input logic [31:0] ip, input logic [15:0] port,
                                             input logic [15:0] len);
    return {ip, port, len};
  endfunction

  function automatic logic [63:0] meta1_pack(input logic [7:0] sock, input logic [7:0] flags,
                                             input logic [47:0] mac);
    return {sock, flags, mac};
  endfunction

endpackage
