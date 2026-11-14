// -----------------------------------------------------------------------------
// File: rtlnet_icmp.sv
// Purpose: RTLNet ICMP echo (ping) responder leaf. It answers an ICMP echo
//   request (RFC 792) for the node's own IPv4 address with an echo reply:
//   addresses swapped, type 0, both checksums correct, the data returned byte
//   for byte. It is a protocol leaf of rtlnet_eth_protocol
//   (documentation/rtlnet_architecture.md sections 7.5, 7.6, 15.4).
// Overview:
//   * One state machine (one registered state variable): S_IDLE and
//     S_RX_B1..S_RX_B5 read the header beats into named fields,
//     S_RX_PAYLOAD stores the message from frame byte 40 on in a payload RAM
//     (rtlnet_ram_core, ICMP_BUF_KB kilobytes) and sums it, S_RX_DROP drains a
//     rejected frame, S_CHECK judges the frame in one clock and computes the
//     reply checksums, S_TX_B0..S_TX_B4 send the reply header built from the
//     captured fields, S_TX_PAYLOAD replays the RAM.
//   * Accept rules (all must hold): EtherType 0x0800, version/IHL 0x45,
//     protocol 1, destination = local_ip, ICMP type 8 code 0, IP Total Length
//     28 .. MAX_PAYLOAD_BYTES + 28, the frame holds every byte the Total Length
//     promises and is longer only by Ethernet padding (a frame of at most 64
//     bytes), the ICMP checksum is correct (RFC 1071), and the frame's first
//     beat found the leaf enabled and idle. Not checked: the Ethernet
//     destination (the wrapper's filter), the request's IP header checksum
//     (the MAC's FCS covers the frame; RFC 1122 3.2.1.2 deviation), the
//     fragment fields (echoed).
//   * Checksums. The receive side sums the ICMP message except its first two
//     words (type/code and checksum) as sum_rest (RFC 1071, padding lanes
//     masked). The request is good when fold(sum_rest + checksum + type/code)
//     is 0xFFFF; the reply checksum is ~fold(sum_rest) (type/code of the
//     reply are 0), the full recompute, so the all-zero message gives 0xFFFF.
//     The reply's IP header checksum is rtlnet_pkg::ipv4_header_checksum.
//   * Sizes: RAM_WORDS = ICMP_BUF_KB * 128 64-bit words (a power of two), the
//     RAM holds frame bytes 40 on (sequence number and data);
//     MAX_PAYLOAD_BYTES = min(1472, ICMP_BUF_KB * 1024 - 2). ICMP_BUF_KB = 2
//     holds a 1472-byte payload. A larger request is dropped, never answered
//     truncated. The RAM write is gated so it can never pass RAM_WORDS.
//   * One request at a time. A frame that starts while the leaf is not idle
//     is ignored whole (in_frame tracks the frame boundary) and never
//     overwrites the stored payload. s_axis_tready is held at 1.
//   * busy (registered) is high from the clock after the last beat of a frame
//     that reaches S_CHECK until the frame is rejected or the reply's last
//     beat is handed to the output slice.
//   * enable is sampled at a frame's first beat; a request accepted before a
//     disable is still answered.
//   * claim (registered one-clock pulse, architecture 7.5): the clock after
//     S_CHECK accepts a request (every check passed, the reply follows), two
//     clocks after its last beat and while busy is high; gated by enable, so a
//     disabled leaf never claims. A rejected frame (bad checksum, size, not an
//     echo request for local_ip) is not claimed and goes to the CPU path.
//   * Registers (12-bit leaf register port, read data registered one clock
//     after reg_rd_en): offsets and bits in
//     cores/rtlnet_icmp/driver/rtlnet_icmp.h; the localparams below mirror it.
//     Counter identity once idle: ECHO_REQUESTS = ECHO_REPLIES +
//     DROPPED_CHECKSUM + DROPPED_SIZE.
//   * Latency: the reply's first beat leaves the slice 3 clocks after the
//     clock in which the request's last beat is accepted.
//   Frame layout (byte offsets): 0-5 dst MAC, 6-11 src MAC, 12-13 EtherType,
//     14 version/IHL, 15 ToS, 16-17 Total Length, 18-19 Identification,
//     20-21 flags/fragment, 22 TTL, 23 protocol, 24-25 header checksum,
//     26-29 source IP, 30-33 destination IP, 34 type, 35 code, 36-37 ICMP
//     checksum, 38-39 identifier, 40-41 sequence, 42.. data.
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 11-14-2026
//   * 11-14-2026: for a 100 MHz clock: the reply's IPv4 header checksum comes from rtlnet_ipv4_csum_pipe (three register stages, settled
//     before S_CHECK); the payload keep mask is a register (rx_keep_q, updated with rx_word); the counters act one clock after S_CHECK on
//     verdict flags registered in S_CHECK. Behaviour and latency at the ports unchanged (the counters appear one clock later).
//   * 10-22-2026: initial version.
//   * 10-22-2026: claim output (leaf contract 7.5, CPU network path).
// Clocks: clk (proto_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_icmp #(
  parameter int    ICMP_BUF_KB = 2,              // payload RAM, kilobytes (power of two)
  parameter string RAM_STYLE   = "block"         // "block" | "distributed"
)(
  // Leaf clock (proto_clk) and its synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Leaf enable from the wrapper's LEAF_ENABLE register (proto_clk level).
  input  logic        enable,

  // Frame in, RTLNet stream (frame byte 0 in tdata[7:0], padding retained);
  // s_axis_tready is a flop held at 1.
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // Reply out, RTLNet stream: the outputs of one rtlnet_axis_reg_slice.
  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  // Node address, proto_clk registers of the wrapper: MAC octet 0 in [47:40],
  // IPv4 first octet in [31:24].
  input  logic [47:0] local_mac,
  input  logic [31:0] local_ip,

  // Leaf status (registered): high while a request is judged or answered.
  output logic        busy,

  // Claim (registered one-clock pulse): the request that just ended is
  // answered; two clocks after its last beat.
  output logic        claim,

  // Leaf register port (proto_clk): write strobe, read strobe, read data one
  // clock after reg_rd_en.
  input  logic        reg_wr_en,
  input  logic [11:0] reg_wr_addr,
  input  logic [31:0] reg_wr_data,
  input  logic        reg_rd_en,
  input  logic [11:0] reg_rd_addr,
  output logic [31:0] reg_rd_data
);

  import rtlnet_pkg::*;

  // ---------------------------------------------------------------------------
  // Register map (mirror of cores/rtlnet_icmp/driver/rtlnet_icmp.h).
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID               = 12'h000;
  localparam logic [11:0] REG_VERSION          = 12'h004;
  localparam logic [11:0] REG_CAPS             = 12'h008;
  localparam logic [11:0] REG_CTRL             = 12'h00C;
  localparam logic [11:0] REG_STATUS           = 12'h010;
  localparam logic [11:0] REG_ECHO_REQUESTS    = 12'h020;
  localparam logic [11:0] REG_ECHO_REPLIES     = 12'h024;
  localparam logic [11:0] REG_DROPPED_CHECKSUM = 12'h028;
  localparam logic [11:0] REG_DROPPED_SIZE     = 12'h02C;
  localparam int          CTRL_CNT_CLEAR_BIT   = 0;
  localparam int          STATUS_ENABLED_BIT   = 0;
  localparam int          STATUS_BUSY_BIT      = 1;
  localparam logic [31:0] ID_VALUE             = id4("I", "C", "M", "P");
  localparam logic [31:0] VERSION_VALUE        = 32'h10222026;

  // ---------------------------------------------------------------------------
  // Field values and sizes.
  // ---------------------------------------------------------------------------
  localparam logic [7:0]  ICMP_TYPE_ECHO_REQUEST = 8'd8;
  localparam logic [7:0]  ICMP_TYPE_ECHO_REPLY   = 8'd0;
  localparam logic [7:0]  ICMP_CODE_ECHO         = 8'd0;
  localparam int          IP_ICMP_HDR_BYTES      = 28;      // IPv4 20 + ICMP 8: the smallest Total Length
  localparam int          MTU_PAYLOAD_BYTES      = 1472;    // 1500-byte IP datagram minus 28
  localparam int          PAYLOAD_BYTE_BIAS      = 27;      // last message byte = RAM byte (Total Length - 27)
  localparam logic [7:0]  ICMP_ID_LANES_BEAT4    = 8'hC0;   // beat 4: lanes 6-7 hold the identifier
  localparam int          PAD_LAST_WORD          = 2;       // a 64-byte frame ends in payload word 2 (beat 7)
  localparam int          RAM_WORDS              = ICMP_BUF_KB * 128;
  localparam int          RAM_AW                 = clog2i(RAM_WORDS);
  localparam int          BUF_PAYLOAD_BYTES      = RAM_WORDS * 8 - 2;
  localparam int          MAX_PAYLOAD_BYTES      = (BUF_PAYLOAD_BYTES < MTU_PAYLOAD_BYTES) ? BUF_PAYLOAD_BYTES :
                                                   MTU_PAYLOAD_BYTES;
  localparam logic [15:0] TOTAL_LEN_MIN          = 16'(IP_ICMP_HDR_BYTES);
  localparam logic [15:0] TOTAL_LEN_MAX          = 16'(MAX_PAYLOAD_BYTES + IP_ICMP_HDR_BYTES);
  localparam logic [15:0] PAYLOAD_BIAS16         = 16'(PAYLOAD_BYTE_BIAS);
  localparam logic [15:0] PAD_LAST_WORD16        = 16'(PAD_LAST_WORD);
  localparam logic [15:0] RAM_WORDS16            = 16'(RAM_WORDS);
  localparam logic [31:0] CAPS_VALUE             = {8'd0, 8'(ICMP_BUF_KB), 16'(MAX_PAYLOAD_BYTES)};

  generate
    if (ICMP_BUF_KB < 1 || (RAM_WORDS & (RAM_WORDS - 1)) != 0) begin : g_bad_buf
      $fatal(1, "rtlnet_icmp: ICMP_BUF_KB=%0d must be a power of two of at least 1", ICMP_BUF_KB);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // State encodings: one registered state variable.
  // ---------------------------------------------------------------------------
  localparam logic [3:0] S_IDLE       = 4'd0;
  localparam logic [3:0] S_RX_B1      = 4'd1;
  localparam logic [3:0] S_RX_B2      = 4'd2;
  localparam logic [3:0] S_RX_B3      = 4'd3;
  localparam logic [3:0] S_RX_B4      = 4'd4;
  localparam logic [3:0] S_RX_B5      = 4'd5;
  localparam logic [3:0] S_RX_PAYLOAD = 4'd6;
  localparam logic [3:0] S_RX_DROP    = 4'd7;
  localparam logic [3:0] S_CHECK      = 4'd8;
  localparam logic [3:0] S_TX_B0      = 4'd9;
  localparam logic [3:0] S_TX_B1      = 4'd10;
  localparam logic [3:0] S_TX_B2      = 4'd11;
  localparam logic [3:0] S_TX_B3      = 4'd12;
  localparam logic [3:0] S_TX_B4      = 4'd13;
  localparam logic [3:0] S_TX_PAYLOAD = 4'd14;

  logic [3:0]        state;
  logic              in_frame;             // 1 from a frame's first beat until its last

  // Request fields (number order) and the one reading of the local address.
  logic [47:0]       req_src_mac;
  logic [15:0]       req_ethertype;
  logic [7:0]        req_ver_ihl;
  logic [7:0]        req_tos;
  logic [15:0]       req_total;
  logic [15:0]       req_ident;
  logic [15:0]       req_flags_frag;
  logic [7:0]        req_protocol;
  logic [31:0]       req_src_ip;
  logic [31:0]       req_dst_ip;
  logic [7:0]        req_icmp_type;
  logic [7:0]        req_icmp_code;
  logic [15:0]       req_icmp_checksum;
  logic [15:0]       req_icmp_ident;
  logic [47:0]       local_mac_snap;
  logic [31:0]       local_ip_snap;
  logic [15:0]       msg_last_byte;        // RAM byte index of the message's last byte

  // Receive progress.
  logic [15:0]       rx_word;              // payload word (beat 5 + rx_word) arriving now
  logic [31:0]       sum_rest;             // RFC 1071 sum of the message from the identifier on
  logic [15:0]       frame_last_word;
  logic [7:0]        frame_last_keep;

  // Reply.
  logic [15:0]       reply_ip_checksum;
  logic [15:0]       reply_icmp_checksum;
  logic [RAM_AW-1:0] tx_word;
  logic [63:0]       ram_rd_data;

  // Output slice side.
  logic [63:0]       tx_data;
  logic [7:0]        tx_keep;
  logic              tx_last;
  logic              tx_valid;
  logic              slice_ready;

  // Counters.
  logic [31:0]       cnt_requests;
  logic [31:0]       cnt_replies;
  logic [31:0]       cnt_drop_checksum;
  logic [31:0]       cnt_drop_size;
  logic              cnt_clear;

  // ---------------------------------------------------------------------------
  // Named conditions.
  // ---------------------------------------------------------------------------
  logic              beat;
  logic [15:0]       msg_last_word;
  logic [2:0]        msg_last_lane;
  logic [7:0]        msg_last_keep;
  logic              rx_word_in_message;
  logic [7:0]        rx_word_keep;
  logic              is_ipv4_no_options;
  logic              is_icmp;
  logic              is_echo_request;
  logic              is_for_my_ip;
  logic              echo_for_us;
  logic              total_length_ok;
  logic              header_ok;
  logic              frame_has_all_bytes;
  logic              frame_only_padded;
  logic              length_ok;
  logic              checksum_ok;
  logic              request_ok;
  logic              tx_is_last_word;
  logic              tx_payload_fire;
  logic              ram_wr_req;
  logic              ram_wr_en;
  logic              ram_rd_en;
  logic [RAM_AW-1:0] ram_rd_addr;
  logic [31:0]       sum_request;
  logic [7:0]        keep_next;
  logic [7:0]        rx_keep_q;             // rx_word_keep as a register: the keep mask of payload word rx_word
  logic              chk_d;                 // one clock after S_CHECK: the registered verdict flags below are valid
  logic              v_echo_for_us;
  logic              v_length_ok;
  logic              v_total_ok;
  logic              v_checksum_ok;
  logic [15:0]       reply_ip_checksum_w;   // IPv4 header checksum of the reply from rtlnet_ipv4_csum_pipe (3 clocks after the fields)

  assign beat                = s_axis_tvalid;                  // s_axis_tready is held at 1
  assign msg_last_word       = {3'd0, msg_last_byte[15:3]};
  assign msg_last_lane       = msg_last_byte[2:0];
  assign msg_last_keep       = keep_through_lane(msg_last_lane);
  assign rx_word_in_message  = (rx_word <= msg_last_word);
  assign rx_word_keep        = rx_keep_q;
  assign keep_next           = ((rx_word + 16'd1) < msg_last_word) ? 8'hFF :
                               ((rx_word + 16'd1) == msg_last_word) ? msg_last_keep : 8'h00;   // keep mask of word rx_word + 1

  assign is_ipv4_no_options  = (req_ethertype == ETHERTYPE_IPV4) && (req_ver_ihl == IPV4_VER_IHL5);
  assign is_icmp             = (req_protocol == IP_PROTO_ICMP);
  assign is_echo_request     = (req_icmp_type == ICMP_TYPE_ECHO_REQUEST) && (req_icmp_code == ICMP_CODE_ECHO);
  assign is_for_my_ip        = (req_dst_ip == local_ip_snap);
  assign echo_for_us         = is_ipv4_no_options && is_icmp && is_echo_request && is_for_my_ip;
  assign total_length_ok     = (req_total >= TOTAL_LEN_MIN) && (req_total <= TOTAL_LEN_MAX);
  assign header_ok           = echo_for_us && total_length_ok;
  assign frame_has_all_bytes = (frame_last_word == msg_last_word) &&
                               ((frame_last_keep & msg_last_keep) == msg_last_keep);
  assign frame_only_padded   = (frame_last_word > msg_last_word) && (frame_last_word <= PAD_LAST_WORD16);
  assign length_ok           = frame_has_all_bytes || frame_only_padded;
  assign sum_request         = sum_rest + {16'd0, req_icmp_checksum} + {16'd0, req_icmp_type, req_icmp_code};
  assign checksum_ok         = (csum_fold16(sum_request) == 16'hFFFF);
  assign request_ok          = header_ok && length_ok && checksum_ok;

  // IPv4 header checksum of the reply in three register stages. Its last input, the source IP (beat 3), is registered two clocks
  // before the last beat of even the shortest request (6 beats) ends, so the value is valid in S_CHECK.
  rtlnet_ipv4_csum_pipe u_csum (
    .clk            (clk),
    .tos            (req_tos),
    .total_length   (req_total),
    .identification (req_ident),
    .flags_fragment (req_flags_frag),
    .ttl            (IPV4_TTL),
    .protocol       (IP_PROTO_ICMP),
    .src_ip         (local_ip_snap),
    .dst_ip         (req_src_ip),
    .csum           (reply_ip_checksum_w)
  );

  assign tx_is_last_word     = (16'(tx_word) == msg_last_word);
  assign tx_payload_fire     = (state == S_TX_PAYLOAD) && slice_ready;
  assign ram_rd_addr         = tx_payload_fire ? (tx_word + 1'b1) : tx_word;
  assign ram_rd_en           = (state >= S_TX_B0) && (state <= S_TX_PAYLOAD);
  // A payload word inside the message is written; the write is also gated by
  // the RAM size, so no frame can write past the buffer.
  assign ram_wr_req          = beat && ((state == S_RX_B5) || (state == S_RX_PAYLOAD)) && rx_word_in_message;
  assign ram_wr_en           = ram_wr_req && (rx_word < RAM_WORDS16);

  // s_axis_tready: a flop that is 1 from the first clock on; the leaf never
  // stalls the fan-out.
  always_ff @(posedge clk) begin
    s_axis_tready <= 1'b1;
  end

  // Frame boundary: in_frame is 1 between a frame's first and last beat, so
  // the rest of a frame that was not taken is ignored when S_IDLE returns.
  always_ff @(posedge clk) begin
    if (!resetn)   in_frame <= 1'b0;
    else if (beat) in_frame <= !s_axis_tlast;
  end

  // The state machine: receive and capture, judge, transmit. The output
  // slice's registered ready is the only transmit enable.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      state               <= S_IDLE;
      busy                <= 1'b0;
      claim               <= 1'b0;
      req_src_mac         <= '0;
      req_ethertype       <= '0;
      req_ver_ihl         <= '0;
      req_tos             <= '0;
      req_total           <= '0;
      req_ident           <= '0;
      req_flags_frag      <= '0;
      req_protocol        <= '0;
      req_src_ip          <= '0;
      req_dst_ip          <= '0;
      req_icmp_type       <= '0;
      req_icmp_code       <= '0;
      req_icmp_checksum   <= '0;
      req_icmp_ident      <= '0;
      local_mac_snap      <= '0;
      local_ip_snap       <= '0;
      msg_last_byte       <= '0;
      rx_word             <= '0;
      sum_rest            <= '0;
      rx_keep_q           <= 8'h00;
      chk_d               <= 1'b0;
      v_echo_for_us       <= 1'b0;
      v_length_ok         <= 1'b0;
      v_total_ok          <= 1'b0;
      v_checksum_ok       <= 1'b0;
      frame_last_word     <= '0;
      frame_last_keep     <= '0;
      reply_ip_checksum   <= '0;
      reply_icmp_checksum <= '0;
      tx_word             <= '0;
    end else begin
      claim <= 1'b0;
      chk_d <= (state == S_CHECK);
      if (state == S_CHECK) begin
        v_echo_for_us <= echo_for_us;
        v_length_ok   <= length_ok;
        v_total_ok    <= total_length_ok;
        v_checksum_ok <= checksum_ok;
      end
      case (state)
        // Bytes 0-7: taken only at a frame's first beat while enabled.
        S_IDLE: begin
          if (beat && !in_frame && enable) begin
            req_src_mac[47:32] <= be16(s_axis_tdata[63:48]);           // bytes 6-7
            if (!s_axis_tlast) state <= S_RX_B1;
          end
        end
        // Bytes 8-15: source MAC low, EtherType, version/IHL, ToS.
        S_RX_B1: begin
          if (beat) begin
            req_src_mac[31:0] <= be32(s_axis_tdata[31:0]);
            req_ethertype     <= be16(s_axis_tdata[47:32]);
            req_ver_ihl       <= s_axis_tdata[55:48];
            req_tos           <= s_axis_tdata[63:56];
            state             <= s_axis_tlast ? S_IDLE : S_RX_B2;
          end
        end
        // Bytes 16-23: Total Length, Identification, flags/fragment, protocol (TTL unused).
        S_RX_B2: begin
          if (beat) begin
            req_total      <= be16(s_axis_tdata[15:0]);
            req_ident      <= be16(s_axis_tdata[31:16]);
            req_flags_frag <= be16(s_axis_tdata[47:32]);
            req_protocol   <= s_axis_tdata[63:56];
            state          <= s_axis_tlast ? S_IDLE : S_RX_B3;
          end
        end
        // Bytes 24-31: source IP, destination IP high; one reading of the local address.
        S_RX_B3: begin
          if (beat) begin
            req_src_ip        <= be32(s_axis_tdata[47:16]);
            req_dst_ip[31:16] <= be16(s_axis_tdata[63:48]);
            local_mac_snap    <= local_mac;
            local_ip_snap     <= local_ip;
            msg_last_byte     <= req_total - PAYLOAD_BIAS16;
            state             <= s_axis_tlast ? S_IDLE : S_RX_B4;
          end
        end
        // Bytes 32-39: destination IP low, type, code, checksum, identifier.
        S_RX_B4: begin
          if (beat) begin
            req_dst_ip[15:0]  <= be16(s_axis_tdata[15:0]);
            req_icmp_type     <= s_axis_tdata[23:16];
            req_icmp_code     <= s_axis_tdata[31:24];
            req_icmp_checksum <= be16(s_axis_tdata[47:32]);
            req_icmp_ident    <= be16(s_axis_tdata[63:48]);
            sum_rest          <= {14'd0, beat_word_sum(s_axis_tdata, ICMP_ID_LANES_BEAT4)};
            rx_word           <= '0;
            rx_keep_q         <= (msg_last_word != 16'd0) ? 8'hFF : msg_last_keep;   // keep mask of word 0
            state             <= s_axis_tlast ? S_IDLE : S_RX_B5;
          end
        end
        // Bytes 40-47, payload word 0: every header field is known; a rejected
        // header is drained in S_RX_DROP.
        S_RX_B5: begin
          if (beat) begin
            sum_rest <= sum_rest + {14'd0, beat_word_sum(s_axis_tdata, rx_word_keep)};
            rx_word  <= rx_word + 1'b1;
            rx_keep_q <= keep_next;
            if (s_axis_tlast) begin
              frame_last_word <= rx_word;
              frame_last_keep <= s_axis_tkeep;
              busy            <= 1'b1;
              state           <= S_CHECK;
            end else begin
              state <= header_ok ? S_RX_PAYLOAD : S_RX_DROP;
            end
          end
        end
        // Payload words 1 on; words past the message (padding) are masked out.
        S_RX_PAYLOAD: begin
          if (beat) begin
            sum_rest <= sum_rest + {14'd0, beat_word_sum(s_axis_tdata, rx_word_keep)};
            rx_word  <= rx_word + 1'b1;
            rx_keep_q <= keep_next;
            if (s_axis_tlast) begin
              frame_last_word <= rx_word;
              frame_last_keep <= s_axis_tkeep;
              busy            <= 1'b1;
              state           <= S_CHECK;
            end
          end
        end
        // Rejected header: drain the frame, send nothing.
        S_RX_DROP: begin
          if (beat && s_axis_tlast) state <= S_IDLE;
        end
        // One clock: judge the request, compute the reply checksums.
        S_CHECK: begin
          tx_word             <= '0;
          reply_ip_checksum   <= reply_ip_checksum_w;
          reply_icmp_checksum <= ~csum_fold16(sum_rest);
          if (request_ok) begin
            claim <= enable;
            state <= S_TX_B0;
          end else begin
            busy  <= 1'b0;
            state <= S_IDLE;
          end
        end
        // Reply header beats; the RAM output holds payload word 0 by S_TX_PAYLOAD.
        S_TX_B0: if (slice_ready) state <= S_TX_B1;
        S_TX_B1: if (slice_ready) state <= S_TX_B2;
        S_TX_B2: if (slice_ready) state <= S_TX_B3;
        S_TX_B3: if (slice_ready) state <= S_TX_B4;
        S_TX_B4: if (slice_ready) state <= S_TX_PAYLOAD;
        // Payload words from frame byte 40 on; the last word's tkeep follows the Total Length.
        S_TX_PAYLOAD: begin
          if (slice_ready) begin
            if (tx_is_last_word) begin
              busy  <= 1'b0;
              state <= S_IDLE;
            end else begin
              tx_word <= tx_word + 1'b1;
            end
          end
        end
        default: begin
          busy  <= 1'b0;
          state <= S_IDLE;
        end
      endcase
    end
  end

  // Payload RAM: written one word per payload beat inside the message, read
  // only in the transmit states (never in the clock of a write).
  rtlnet_ram_core #(
    .RAM_STYLE    (RAM_STYLE),
    .CLOCKING     ("COMMON"),
    .DATA_W       (64),
    .ADDR_W       (RAM_AW),
    .READ_LATENCY (1)
  ) u_payload_ram (
    .wr_clk    (clk),
    .wr_en     (ram_wr_en),
    .wr_addr   (rx_word[RAM_AW-1:0]),
    .wr_data   (s_axis_tdata),
    .rd_clk    (clk),
    .rd_resetn (resetn),
    .rd_en     (ram_rd_en),
    .rd_addr   (ram_rd_addr),
    .rd_data   (ram_rd_data)
  );

  // The reply beat offered to the output slice, by state (bus lanes, high
  // lane first):
  //   B0 dst = request source MAC, src MAC high
  //   B1 src MAC low, EtherType, version/IHL, ToS (echoed)
  //   B2 Total Length, Identification, flags/fragment (echoed), TTL 64, protocol 1
  //   B3 header checksum, source IP = local IP, destination IP high
  //   B4 destination IP low, type 0, code 0, ICMP checksum, identifier
  always_comb begin
    tx_valid = 1'b1;
    tx_data  = '0;
    tx_keep  = 8'hFF;
    tx_last  = 1'b0;
    case (state)
      S_TX_B0: tx_data = {be16(local_mac_snap[47:32]), be48(req_src_mac)};
      S_TX_B1: tx_data = {req_tos, IPV4_VER_IHL5, be16(ETHERTYPE_IPV4), be32(local_mac_snap[31:0])};
      S_TX_B2: tx_data = {IP_PROTO_ICMP, IPV4_TTL, be16(req_flags_frag), be16(req_ident), be16(req_total)};
      S_TX_B3: tx_data = {be16(req_src_ip[31:16]), be32(local_ip_snap), be16(reply_ip_checksum)};
      S_TX_B4: tx_data = {be16(req_icmp_ident), be16(reply_icmp_checksum), ICMP_CODE_ECHO, ICMP_TYPE_ECHO_REPLY,
                          be16(req_src_ip[15:0])};
      S_TX_PAYLOAD: begin
        tx_data = ram_rd_data;
        tx_last = tx_is_last_word;
        tx_keep = tx_is_last_word ? msg_last_keep : 8'hFF;
      end
      default: tx_valid = 1'b0;
    endcase
  end

  // Output slice: registered ready back to the state machine, registered beat
  // to the wrapper's arbiter.
  rtlnet_axis_reg_slice #(
    .DATA_W     (64),
    .RESET_DATA (1'b1)
  ) u_tx_slice (
    .clk      (clk),
    .resetn   (resetn),
    .s_tdata  (tx_data),
    .s_tkeep  (tx_keep),
    .s_tlast  (tx_last),
    .s_tvalid (tx_valid),
    .s_tready (slice_ready),
    .m_tdata  (m_axis_tdata),
    .m_tkeep  (m_axis_tkeep),
    .m_tlast  (m_axis_tlast),
    .m_tvalid (m_axis_tvalid),
    .m_tready (m_axis_tready)
  );

  // Counters: echo requests for the local address that were taken, replies
  // handed to the slice, requests dropped for their checksum or their size.
  assign cnt_clear = reg_wr_en && (reg_wr_addr == REG_CTRL) && reg_wr_data[CTRL_CNT_CLEAR_BIT];

  always_ff @(posedge clk) begin
    if (!resetn || cnt_clear) begin
      cnt_requests      <= '0;
      cnt_replies       <= '0;
      cnt_drop_checksum <= '0;
      cnt_drop_size     <= '0;
    end else begin
      // An echo request whose Total Length is out of range is dropped at beat 5.
      if ((state == S_RX_B5) && beat && !s_axis_tlast && echo_for_us && !total_length_ok) begin
        cnt_requests  <= cnt_requests + 1'b1;
        cnt_drop_size <= cnt_drop_size + 1'b1;
      end
      if (chk_d && v_echo_for_us) begin
        cnt_requests <= cnt_requests + 1'b1;
        if (!v_total_ok || !v_length_ok) cnt_drop_size     <= cnt_drop_size + 1'b1;
        else if (!v_checksum_ok)         cnt_drop_checksum <= cnt_drop_checksum + 1'b1;
      end
      if (tx_payload_fire && tx_is_last_word) cnt_replies <= cnt_replies + 1'b1;
    end
  end

  // Registered read mux; undefined offsets read 0.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:               reg_rd_data <= ID_VALUE;
        REG_VERSION:          reg_rd_data <= VERSION_VALUE;
        REG_CAPS:             reg_rd_data <= CAPS_VALUE;
        REG_CTRL:             reg_rd_data <= '0;
        REG_STATUS: begin
          reg_rd_data                     <= '0;
          reg_rd_data[STATUS_ENABLED_BIT] <= enable;
          reg_rd_data[STATUS_BUSY_BIT]    <= busy;
        end
        REG_ECHO_REQUESTS:    reg_rd_data <= cnt_requests;
        REG_ECHO_REPLIES:     reg_rd_data <= cnt_replies;
        REG_DROPPED_CHECKSUM: reg_rd_data <= cnt_drop_checksum;
        REG_DROPPED_SIZE:     reg_rd_data <= cnt_drop_size;
        default:              reg_rd_data <= '0;
      endcase
    end
  end

  // Simulation-only guard: a write request past the RAM size (blocked by the
  // gate above) means the Total Length bound failed.
  // synthesis translate_off
  always @(posedge clk) begin
    if (resetn && ram_wr_req && (rx_word >= RAM_WORDS16)) $fatal(1, "%m: payload RAM write request past RAM_WORDS");
  end
  // synthesis translate_on

endmodule
