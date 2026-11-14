// -----------------------------------------------------------------------------
// File: rtlnet_udp_socket_tx.sv
// Purpose: transmit frame builder of the RTLNet UDP socket layer (proto_clk).
//   Takes one descriptor (meta 0, meta 1 with the write-side verdict) from the
//   TX descriptor FIFO, decides to send or drop, builds the Ethernet II, IPv4
//   and UDP headers and emits the frame with the payload from the TX payload
//   FIFO realigned to frame byte 42.
// Overview:
//   * Drop (counted, no frame) when the write-side verdict is bad, the socket
//     index is not below NUM_SOCKETS, the socket is disabled, or the leaf is
//     disabled. A dropped datagram with a payload frame in the payload FIFO
//     (non-zero length, good verdict) has that frame read and discarded.
//   * Header (RFC 894, RFC 791, RFC 768):
//       destination MAC/IP/port: meta 1 MAC, meta 0 IP and port, or the
//         socket's REMOTE_* registers when flags bit 0 USE_SOCKET_REMOTE is set
//       source MAC local_mac, source IP local_ip (taken once per datagram),
//         source port the socket's LOCAL_PORT
//       EtherType 0x0800, version/IHL 0x45, ToS 0, total length L + 28,
//         identification from a counter (0 after reset, +1 per frame sent),
//         flags/fragment 0x4000 (DF), TTL 64, protocol 17, header checksum
//         from rtlnet_pkg::ipv4_header_checksum (registered one clock before
//         the first beat), UDP length L + 8, UDP checksum 0 (RFC 768: none).
//   * Beats: 0-4 are header beats from registered fields; beat 5+m carries
//     payload word m lanes 0-5 in lanes 2-7 and word m-1 lanes 6-7 in lanes
//     0-1 (beat 5: the UDP checksum 0x0000). A final payload word with 7 or 8
//     bytes leaves one more beat (`T_FLUSH`); a zero-length datagram ends with
//     beat 5 holding the checksum only (tkeep 0x03). Short frames are padded
//     to 60 bytes by the MAC.
//   * A frame starts only when its payload frame is visible in the payload
//     FIFO, whose read side has no bubble inside a frame, so the frame is
//     offered without gaps; o_ready (the output slice) is the only stall.
// Language: SystemVerilog-2012.
// Revision: 11-14-2026
//   * 11-14-2026: the IPv4 header checksum comes from rtlnet_ipv4_csum_pipe (three register stages, T_SUM takes four clocks
//     instead of one). Behaviour at the ports unchanged.
//   * 10-22-2026: initial version.
// Clocks: clk (proto_clk); resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_udp_socket_tx #(
  parameter int NUM_SOCKETS = 4                      // sockets in the table, 1..60
)(
  // Clock and synchronous active-low reset, proto_clk domain.
  input  logic                         clk,
  input  logic                         resetn,

  // Leaf enable and node address (proto_clk registers of the wrapper).
  input  logic                         enable,
  input  logic [47:0]                  local_mac,
  input  logic [31:0]                  local_ip,

  // Socket table, proto_clk registers.
  input  logic [NUM_SOCKETS-1:0]       sock_enable,
  input  logic [NUM_SOCKETS-1:0][15:0] sock_port,
  input  logic [NUM_SOCKETS-1:0][31:0] sock_remote_ip,
  input  logic [NUM_SOCKETS-1:0][15:0] sock_remote_port,
  input  logic [NUM_SOCKETS-1:0][47:0] sock_remote_mac,

  // TX descriptor FIFO read side (proto_clk): word 0 meta 0, word 1 meta 1.
  input  logic [63:0]                  desc_data,
  input  logic                         desc_valid,
  input  logic                         desc_last,
  output logic                         desc_ready,

  // TX payload FIFO read side (proto_clk): one frame per non-empty good datagram.
  input  logic [63:0]                  pay_data,
  input  logic [7:0]                   pay_keep,
  input  logic                         pay_valid,
  input  logic                         pay_last,
  output logic                         pay_ready,

  // Frame out to the leaf's output register slice (RTLNet stream).
  output logic [63:0]                  o_data,
  output logic [7:0]                   o_keep,
  output logic                         o_last,
  output logic                         o_valid,
  input  logic                         o_ready,

  // Events, one-clock pulses, with the datagram's socket index.
  output logic                         ev_sent,            // last beat of a frame accepted
  output logic                         ev_drop,            // datagram dropped
  output logic                         ev_drop_in_range,   // ... and its socket index is valid
  output logic [7:0]                   ev_sock,

  // Status: a datagram is being processed.
  output logic                         active
);

  import rtlnet_pkg::*;
  import rtlnet_udp_socket_pkg::*;

  localparam logic [3:0] T_IDLE    = 4'd0;   // waiting for descriptor word 0
  localparam logic [3:0] T_DESC1   = 4'd1;   // descriptor word 1
  localparam logic [3:0] T_DECIDE  = 4'd2;   // send or drop; header fields
  localparam logic [3:0] T_SUM     = 4'd3;   // IPv4 header checksum
  localparam logic [3:0] T_WAITPAY = 4'd4;   // payload frame visible in the FIFO
  localparam logic [3:0] T_HDR     = 4'd5;   // header beats 0..4
  localparam logic [3:0] T_PAY     = 4'd6;   // payload-carrying beats
  localparam logic [3:0] T_FLUSH   = 4'd7;   // final beat from the held tail
  localparam logic [3:0] T_DISCARD = 4'd8;   // read and drop a payload frame

  localparam logic [2:0]  LAST_HDR_BEAT = 3'd4;
  localparam logic [15:0] IP_OVERHEAD   = 16'(IPV4_HEADER_BYTES + UDP_HEADER_BYTES);
  localparam logic [15:0] UDP_OVERHEAD  = 16'(UDP_HEADER_BYTES);
  localparam logic [3:0]  TAIL_BYTES    = 4'd2;   // lanes 0-1 of a payload-carrying beat
  localparam logic [3:0]  LANES_FROM_WORD = 4'd6; // payload bytes moved into lanes 2-7

  logic [3:0]  state;
  logic [2:0]  hdr_idx;
  logic [63:0] meta0;
  logic [63:0] meta1;
  logic [15:0] len;
  logic [7:0]  sock;
  logic [7:0]  flags;
  logic        in_range;
  logic        has_payload;
  logic        drop;
  logic [$clog2(NUM_SOCKETS > 1 ? NUM_SOCKETS : 2)-1:0] sidx;

  // Header fields of the frame being built (number order).
  logic [47:0] h_dst_mac;
  logic [47:0] h_src_mac;
  logic [31:0] h_dst_ip;
  logic [31:0] h_src_ip;
  logic [15:0] h_src_port;
  logic [15:0] h_dst_port;
  logic [15:0] h_total_len;
  logic [15:0] h_udp_len;
  logic [15:0] h_ident;
  logic [15:0] h_csum;
  logic [15:0] h_csum_w;           // IPv4 header checksum from rtlnet_ipv4_csum_pipe (3 clocks after the header fields)
  logic [1:0]  csum_wait;          // clocks spent in T_SUM
  logic [15:0] ident_next;
  logic [15:0] tail;               // lanes 6-7 of the previous payload word
  logic [3:0]  flush_n;            // bytes in the final flush beat

  logic        o_fire;

  // IPv4 header checksum in three register stages (a one-clock nine-operand sum does not fit a 100 MHz clock).
  rtlnet_ipv4_csum_pipe u_csum (
    .clk            (clk),
    .tos            (IPV4_TOS_SENT),
    .total_length   (h_total_len),
    .identification (h_ident),
    .flags_fragment (IPV4_FLAGS_DF),
    .ttl            (IPV4_TTL),
    .protocol       (IP_PROTO_UDP),
    .src_ip         (h_src_ip),
    .dst_ip         (h_dst_ip),
    .csum           (h_csum_w)
  );
  logic [3:0]  pay_bytes;
  logic [63:0] hdr_beat;

  assign len         = meta0[15:0];
  assign sock        = meta1[META1_SOCK_LSB +: SOCK_IDX_W];
  assign flags       = meta1[META1_FLAG_LSB +: 8];
  assign in_range    = (sock < 8'(NUM_SOCKETS));
  assign sidx        = in_range ? sock[$bits(sidx)-1:0] : '0;
  assign has_payload = (len != 16'd0) && !flags[FLAG_TX_BAD];
  assign drop        = flags[FLAG_TX_BAD] || !in_range || !sock_enable[sidx] || !enable;
  assign o_fire      = o_valid && o_ready;
  assign pay_bytes   = keep_bytes(pay_keep);
  assign active      = (state != T_IDLE);
  assign ev_sock     = sock;

  // Header beats in bus order (byte 8k+i in lanes i).
  always_comb begin
    case (hdr_idx)
      3'd0:    hdr_beat = {be16(h_src_mac[47:32]), be48(h_dst_mac)};
      3'd1:    hdr_beat = {IPV4_TOS_SENT, IPV4_VER_IHL5, be16(ETHERTYPE_IPV4), be32(h_src_mac[31:0])};
      3'd2:    hdr_beat = {IP_PROTO_UDP, IPV4_TTL, be16(IPV4_FLAGS_DF), be16(h_ident), be16(h_total_len)};
      3'd3:    hdr_beat = {be16(h_dst_ip[31:16]), be32(h_src_ip), be16(h_csum)};
      default: hdr_beat = {be16(h_udp_len), be16(h_dst_port), be16(h_src_port), be16(h_dst_ip[15:0])};
    endcase
  end

  // Output beat mux and FIFO read strobes.
  always_comb begin
    o_valid    = 1'b0;
    o_data     = hdr_beat;
    o_keep     = 8'hFF;
    o_last     = 1'b0;
    desc_ready = 1'b0;
    pay_ready  = 1'b0;
    case (state)
      T_IDLE, T_DESC1: desc_ready = 1'b1;
      T_HDR: o_valid = 1'b1;
      T_PAY: begin
        o_valid   = pay_valid;
        o_data    = {pay_data[47:0], tail};
        pay_ready = o_ready;
        if (pay_last && pay_bytes <= LANES_FROM_WORD) begin
          o_keep = keep_mask(TAIL_BYTES + pay_bytes);
          o_last = 1'b1;
        end
      end
      T_FLUSH: begin
        o_valid = 1'b1;
        o_data  = {48'd0, tail};
        o_keep  = keep_mask(flush_n);
        o_last  = 1'b1;
      end
      T_DISCARD: pay_ready = 1'b1;
      default: ;
    endcase
  end

  // Frame builder sequencer.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      state            <= T_IDLE;
      hdr_idx          <= '0;
      meta0            <= '0;
      meta1            <= '0;
      h_dst_mac        <= '0;
      h_src_mac        <= '0;
      h_dst_ip         <= '0;
      h_src_ip         <= '0;
      h_src_port       <= '0;
      h_dst_port       <= '0;
      h_total_len      <= '0;
      h_udp_len        <= '0;
      h_ident          <= '0;
      h_csum           <= '0;
      csum_wait        <= 2'd0;
      ident_next       <= '0;
      tail             <= '0;
      flush_n          <= '0;
      ev_sent          <= 1'b0;
      ev_drop          <= 1'b0;
      ev_drop_in_range <= 1'b0;
    end else begin
      ev_sent          <= 1'b0;
      ev_drop          <= 1'b0;
      ev_drop_in_range <= 1'b0;
      case (state)
        T_IDLE: begin
          if (desc_valid) begin
            meta0 <= desc_data;
            state <= desc_last ? T_IDLE : T_DESC1;
          end
        end
        T_DESC1: begin
          if (desc_valid) begin
            meta1 <= desc_data;
            state <= desc_last ? T_DECIDE : T_DESC1;
          end
        end
        T_DECIDE: begin
          h_src_mac   <= local_mac;
          h_src_ip    <= local_ip;
          h_src_port  <= sock_port[sidx];
          h_total_len <= len + IP_OVERHEAD;
          h_udp_len   <= len + UDP_OVERHEAD;
          h_ident     <= ident_next;
          if (flags[FLAG_TX_USE_SOCKET_REMOTE]) begin
            h_dst_mac  <= sock_remote_mac[sidx];
            h_dst_ip   <= sock_remote_ip[sidx];
            h_dst_port <= sock_remote_port[sidx];
          end else begin
            h_dst_mac  <= meta1[META1_MAC_LSB +: 48];
            h_dst_ip   <= meta0[META0_IP_LSB +: 32];
            h_dst_port <= meta0[META0_PORT_LSB +: 16];
          end
          if (drop) begin
            ev_drop          <= 1'b1;
            ev_drop_in_range <= in_range;
            state            <= has_payload ? T_DISCARD : T_IDLE;
          end else begin
            state <= T_SUM;
          end
        end
        T_SUM: begin
          // The checksum pipeline needs 3 clocks after the header fields settle: leave on the fourth clock.
          csum_wait <= csum_wait + 2'd1;
          if (csum_wait == 2'd3) begin
            h_csum    <= h_csum_w;
            csum_wait <= 2'd0;
            state     <= T_WAITPAY;
          end
        end
        T_WAITPAY: begin
          hdr_idx <= '0;
          tail    <= '0;
          if (!has_payload || pay_valid) state <= T_HDR;
        end
        T_HDR: begin
          if (o_fire) begin
            if (hdr_idx == LAST_HDR_BEAT) begin
              if (has_payload) begin
                state <= T_PAY;
              end else begin
                flush_n <= TAIL_BYTES;
                state   <= T_FLUSH;
              end
            end else begin
              hdr_idx <= hdr_idx + 3'd1;
            end
          end
        end
        T_PAY: begin
          if (o_fire) begin
            tail <= pay_data[63:48];
            if (pay_last) begin
              if (pay_bytes <= LANES_FROM_WORD) begin
                ev_sent    <= 1'b1;
                ident_next <= ident_next + 16'd1;
                state      <= T_IDLE;
              end else begin
                flush_n <= pay_bytes - LANES_FROM_WORD;
                state   <= T_FLUSH;
              end
            end
          end
        end
        T_FLUSH: begin
          if (o_fire) begin
            ev_sent    <= 1'b1;
            ident_next <= ident_next + 16'd1;
            state      <= T_IDLE;
          end
        end
        T_DISCARD: begin
          if (pay_valid && pay_last) state <= T_IDLE;
        end
        default: state <= T_IDLE;
      endcase
    end
  end

  // Simulation-only check: a frame, once started, is never starved by the
  // payload FIFO (it has no bubble inside a frame).
  // synthesis translate_off
  always @(posedge clk) begin
    if (resetn && (state == T_PAY) && !pay_valid)
      $error("%m: payload FIFO bubble inside a frame");
  end
  // synthesis translate_on

endmodule
