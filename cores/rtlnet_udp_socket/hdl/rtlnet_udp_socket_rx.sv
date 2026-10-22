// -----------------------------------------------------------------------------
// File: rtlnet_udp_socket_rx.sv
// Purpose: receive engine of the RTLNet UDP socket layer. Parses each frame
//   the protocol wrapper fans out, decides at beat 4 whether it is a datagram
//   for an enabled socket, and writes the two metadata beats and the payload,
//   realigned from frame byte 42 to byte 0, into the RX packet FIFO.
// Overview:
//   * The input never stalls (the leaf holds s_axis_tready at 1); every beat
//     is taken as it arrives. A frame is taken only if its first beat finds
//     the engine idle; a frame that starts while it is busy is ignored whole
//     (`in_frame` tracks the input frame boundaries independently).
//   * Fields by beat (beat k = frame bytes 8k..8k+7, byte 8k in tdata[7:0]):
//       0: source MAC octets 0-1           1: source MAC 2-5, EtherType, ver/IHL
//       2: total length, flags/fragment, protocol
//       3: source IP, destination IP 0-1   4: destination IP 2-3, ports, UDP length
//       5: UDP checksum, payload bytes 0-5
//   * Decision at beat 4 (one clock, from the beat and the fields captured):
//       not IPv4, not UDP, not for local_ip / 255.255.255.255 /
//         (local_ip | ~local_mask), or the leaf disabled  -> ignored, no event
//       version/IHL != 0x45, MF set or fragment offset != 0, total length
//         outside 28..1500, UDP length != total length - 20, bad IPv4 header
//         checksum, or the frame ending at beat 4         -> ev_bad
//       no enabled socket with LOCAL_PORT == destination port -> ev_no_socket
//       socket found but the FIFO has no free slot        -> ev_fifo_drop
//       otherwise accepted: meta 0, meta 1, payload written
//     The lowest-index enabled socket with a matching port wins. The FIFO is
//     idle at the decision (the previous datagram's last write precedes the
//     engine's return to idle), so its s_ready is the free-slot verdict and
//     stays 1 until this datagram's first write.
//   * Realignment: payload word m = frame bytes 42+8m..49+8m = beat 5+m lanes
//     2-7 joined to beat 6+m lanes 0-1. `hold` keeps lanes 2-7 of the latest
//     beat; a word is emitted into the one-word register `pay_*` when its last
//     byte arrives. A final word whose bytes all sit in lanes 2-7 (1..6 bytes
//     left) is emitted from `hold` on the next clock (`flush_pend`). Ethernet
//     padding after the datagram is never written.
//   * FIFO write order: meta 0 (clock after the decision), meta 1 (next
//     clock), then each payload word one clock after it is formed. The first
//     payload word cannot be formed before meta 1 is written (it needs beat 6),
//     so `pay_*` never has to hold a word for more than one clock except a
//     truncation marker loaded while meta 1 is pending.
//   * Late verdicts on the final FIFO beat (s_bad drops the whole datagram in
//     the FIFO, and the end event becomes ev_bad): the frame ends before the
//     datagram does (`short_now`), or, with csum_check set, a non-zero UDP
//     checksum that does not verify (RFC 768 pseudo-header sum, RFC 1071).
//     A zero-length datagram writes meta 1 (with tlast) only once byte 41 has
//     arrived, so the same verdicts apply to it.
//   * Events are one-clock registered pulses; ev_sock and ev_remote_* hold
//     the datagram's socket and sender while the pulse is high.
//   * busy is a flop: high from the clock after a frame's first beat until
//     the engine is idle again (the end of the frame or the datagram's last
//     FIFO write, whichever is later).
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (proto_clk); resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_udp_socket_rx #(
  parameter int NUM_SOCKETS = 4                      // sockets in the table, 1..60
)(
  // Clock and synchronous active-low reset, proto_clk domain.
  input  logic                         clk,
  input  logic                         resetn,

  // Controls (proto_clk registers): leaf enable from the wrapper, UDP checksum
  // verification from the layer's CTRL register.
  input  logic                         enable,
  input  logic                         csum_check,

  // Frames from the wrapper fan-out, RTLNet stream (byte 0 in tdata[7:0]);
  // never back-pressured: every valid beat is consumed.
  input  logic [63:0]                  s_axis_tdata,
  input  logic [7:0]                   s_axis_tkeep,
  input  logic                         s_axis_tvalid,
  input  logic                         s_axis_tlast,

  // Node address, proto_clk registers of the wrapper (first octet in [31:24]).
  input  logic [31:0]                  local_ip,
  input  logic [31:0]                  local_mask,

  // Socket table, proto_clk registers: enable and local port per socket.
  input  logic [NUM_SOCKETS-1:0]       sock_enable,
  input  logic [NUM_SOCKETS-1:0][15:0] sock_port,

  // RX packet FIFO write side (proto_clk): metadata and realigned payload;
  // fifo_bad on the final beat drops the datagram inside the FIFO.
  output logic [63:0]                  fifo_data,
  output logic [7:0]                   fifo_keep,
  output logic                         fifo_last,
  output logic                         fifo_valid,
  output logic                         fifo_bad,
  input  logic                         fifo_ready,

  // Events, one-clock pulses, with the datagram's socket and sender.
  output logic                         ev_delivered,     // datagram committed to the FIFO
  output logic                         ev_fifo_drop,     // socket matched, FIFO full
  output logic                         ev_no_socket,     // valid datagram, no enabled socket
  output logic                         ev_bad,           // header, length or checksum error
  output logic [7:0]                   ev_sock,
  output logic [31:0]                  ev_remote_ip,
  output logic [15:0]                  ev_remote_port,
  output logic [47:0]                  ev_remote_mac,

  // Leaf busy (registered).
  output logic                         busy
);

  import rtlnet_pkg::*;
  import rtlnet_udp_socket_pkg::*;

  localparam logic [2:0] S_IDLE    = 3'd0;   // waiting for the first beat of a frame
  localparam logic [2:0] S_HDR     = 3'd1;   // beats 1..4, decision at beat 4
  localparam logic [2:0] S_META0   = 3'd2;   // write meta 0
  localparam logic [2:0] S_META1   = 3'd3;   // write meta 1 (zero length: once byte 41 is in)
  localparam logic [2:0] S_PAYLOAD = 3'd4;   // write payload words until the last
  localparam logic [2:0] S_DRAIN   = 3'd5;   // wait for the end of the input frame

  localparam logic [11:0] PAYLOAD_OFFSET = 12'(UDP_PAYLOAD_OFFSET);
  localparam logic [15:0] MIN_TOTAL_LEN  = 16'(IPV4_HEADER_BYTES + UDP_HEADER_BYTES);
  localparam logic [15:0] MAX_TOTAL_LEN  = 16'(IPV4_MTU_BYTES);
  localparam logic [15:0] IPV4_HDR_LEN   = 16'(IPV4_HEADER_BYTES);
  localparam logic [15:0] UDP_HDR_LEN    = 16'(UDP_HEADER_BYTES);
  localparam logic [7:0]  LAST_HDR_BEAT  = 8'(BEAT_IP_DST_LO);
  localparam logic [7:0]  FIRST_PAY_BEAT = 8'(BEAT_FIRST_PAYLOAD);
  localparam logic [7:0]  LANES_UDP_HDR  = 8'hFC;   // beat 4 lanes 2..7: ports and UDP length
  localparam logic [15:0] HEADER_SUM_OK  = 16'hFFFF;

  // ---------------------------------------------------------------------------
  // Input framing
  // ---------------------------------------------------------------------------
  logic        beat;
  logic        in_frame;           // inside an input frame (after a non-final beat)
  logic [7:0]  beat_idx;           // index of the beat on the bus within its frame (saturates)
  logic [11:0] bytes_through;      // frame bytes up to and including this beat

  // ---------------------------------------------------------------------------
  // Engine state and captured header fields
  // ---------------------------------------------------------------------------
  logic [2:0]  state;
  logic        busy_q;
  logic [47:0] f_src_mac;
  logic [15:0] f_ethertype;
  logic [7:0]  f_ver_ihl;
  logic [15:0] f_total_len;
  logic [15:0] f_flags_frag;
  logic [7:0]  f_proto;
  logic [31:0] f_src_ip;
  logic [15:0] f_dst_ip_hi;
  logic [19:0] f_hdr_sum;          // IPv4 header words of beats 1..3 (nine words)

  // Metadata of the accepted datagram.
  logic [31:0] meta_ip;
  logic [15:0] meta_port;
  logic [15:0] meta_len;
  logic [7:0]  meta_sock;
  logic [7:0]  meta_flags;
  logic [47:0] meta_mac;
  logic [11:0] need_end;           // frame bytes needed: 42 + payload length

  // ---------------------------------------------------------------------------
  // Decision (combinational, used on the beat-4 clock)
  // ---------------------------------------------------------------------------
  logic [31:0] d_dst_ip;
  logic [15:0] d_src_port;
  logic [15:0] d_dst_port;
  logic [15:0] d_udp_len;
  logic [15:0] d_payload_len;
  logic        d_for_us;
  logic        d_candidate;
  logic        d_hdr_sum_ok;
  logic        d_bad;
  logic        d_match;
  logic [7:0]  d_match_idx;
  logic [7:0]  d_flags;
  logic        d_beat;             // the beat-4 decision clock

  // ---------------------------------------------------------------------------
  // Payload capture, realignment and checksum
  // ---------------------------------------------------------------------------
  logic        cap_active;         // payload words still to be formed from input beats
  logic [10:0] pay_rem;            // payload bytes not yet emitted
  logic [47:0] hold;               // lanes 2..7 of the latest payload-carrying beat
  logic        flush_pend;         // final word (1..6 bytes) waits in `hold`
  logic        pay_valid;
  logic [63:0] pay_data;
  logic [7:0]  pay_keep;
  logic        pay_last;
  logic        pay_bad;
  logic        rx_complete;        // every datagram byte has arrived
  logic        rx_short;           // the frame ended before the datagram did
  logic [31:0] csum_acc;           // UDP pseudo-header + datagram word sum
  logic [11:0] csum_rem;           // datagram bytes still to be summed (from byte 40)
  logic [15:0] udp_csum_field;
  logic        csum_on;
  logic        csum_bad;

  logic        cap_beat;
  logic        cap_first;
  logic        cap_emit;
  logic [3:0]  emit_n;
  logic        emit_last;
  logic [10:0] rem_after;
  logic        short_now;
  logic        track_beat;
  logic [7:0]  csum_lanes;
  logic [3:0]  csum_take;

  logic        fifo_fire;
  logic        final_write;

  assign beat          = s_axis_tvalid;
  assign bytes_through = {1'b0, beat_idx, 3'b000} + (s_axis_tlast ? {8'd0, keep_bytes(s_axis_tkeep)} : 12'd8);
  assign busy          = busy_q;
  assign ev_sock        = meta_sock;
  assign ev_remote_ip   = meta_ip;
  assign ev_remote_port = meta_port;
  assign ev_remote_mac  = meta_mac;

  // Fields of beat 4 and the decision.
  assign d_dst_ip      = {f_dst_ip_hi, be16(s_axis_tdata[15:0])};
  assign d_src_port    = be16(s_axis_tdata[31:16]);
  assign d_dst_port    = be16(s_axis_tdata[47:32]);
  assign d_udp_len     = be16(s_axis_tdata[63:48]);
  assign d_payload_len = d_udp_len - UDP_HDR_LEN;
  assign d_for_us      = (d_dst_ip == local_ip) || (d_dst_ip == IPV4_LIMITED_BCAST) ||
                         (d_dst_ip == (local_ip | ~local_mask));
  assign d_candidate   = enable && (f_ethertype == ETHERTYPE_IPV4) && (f_proto == IP_PROTO_UDP) && d_for_us;
  assign d_hdr_sum_ok  = (csum_fold16({12'd0, f_hdr_sum} + {16'd0, be16(s_axis_tdata[15:0])}) == HEADER_SUM_OK);
  assign d_bad         = (f_ver_ihl != IPV4_VER_IHL5) || f_flags_frag[IPV4_MF_BIT] ||
                         (f_flags_frag[IPV4_MF_BIT-1:0] != '0) ||
                         (f_total_len < MIN_TOTAL_LEN) || (f_total_len > MAX_TOTAL_LEN) ||
                         (d_udp_len != f_total_len - IPV4_HDR_LEN) || !d_hdr_sum_ok || s_axis_tlast;
  assign d_beat        = (state == S_HDR) && beat && (beat_idx == LAST_HDR_BEAT);

  // Receive flags of meta 1.
  always_comb begin
    d_flags                     = 8'h00;
    d_flags[FLAG_RX_BROADCAST]  = (d_dst_ip != local_ip);
    d_flags[FLAG_RX_OFF_SUBNET] = (((f_src_ip ^ local_ip) & local_mask) != 32'd0);
  end

  // Socket match: lowest index wins (the loop runs downward, the last hit is kept).
  always_comb begin
    d_match     = 1'b0;
    d_match_idx = '0;
    for (int i = NUM_SOCKETS - 1; i >= 0; i--) begin
      if (sock_enable[i] && (sock_port[i] == d_dst_port)) begin
        d_match     = 1'b1;
        d_match_idx = 8'(i);
      end
    end
  end

  // Payload word formation on the current beat.
  assign track_beat = beat && ((state == S_META0) || (state == S_META1) || (state == S_PAYLOAD));
  assign cap_beat   = track_beat && cap_active;
  assign cap_first  = cap_beat && (beat_idx == FIRST_PAY_BEAT);
  assign cap_emit   = cap_beat && (beat_idx > FIRST_PAY_BEAT);
  assign emit_n     = (pay_rem >= 11'd8) ? 4'd8 : pay_rem[3:0];
  assign emit_last  = (pay_rem <= 11'd8);
  assign rem_after  = pay_rem - {7'd0, emit_n};
  assign short_now  = track_beat && s_axis_tlast && (bytes_through < need_end);

  // Checksum lanes of the current beat: datagram bytes only, padding masked.
  assign csum_take  = (csum_rem >= 12'd8) ? 4'd8 : csum_rem[3:0];
  assign csum_lanes = keep_mask(csum_take);
  assign csum_bad   = csum_on && (udp_csum_field != 16'h0000) && (csum_fold16(csum_acc) != HEADER_SUM_OK);

  // FIFO write port: meta 0, meta 1, then the payload register.
  always_comb begin
    fifo_valid = 1'b0;
    fifo_data  = pay_data;
    fifo_keep  = pay_keep;
    fifo_last  = 1'b0;
    fifo_bad   = 1'b0;
    case (state)
      S_META0: begin
        fifo_valid = 1'b1;
        fifo_data  = meta0_pack(meta_ip, meta_port, meta_len);
        fifo_keep  = 8'hFF;
      end
      S_META1: begin
        fifo_valid = (meta_len != 16'd0) || rx_complete || rx_short;
        fifo_data  = meta1_pack(meta_sock, meta_flags, meta_mac);
        fifo_keep  = 8'hFF;
        fifo_last  = (meta_len == 16'd0);
        fifo_bad   = (meta_len == 16'd0) && (rx_short || csum_bad);
      end
      S_PAYLOAD: begin
        fifo_valid = pay_valid;
        fifo_last  = pay_last;
        fifo_bad   = pay_last && (pay_bad || csum_bad);
      end
      default: fifo_valid = 1'b0;
    endcase
  end

  assign fifo_fire   = fifo_valid && fifo_ready;
  assign final_write = fifo_fire && fifo_last;

  // Input frame boundaries and beat index, independent of the engine, so a
  // frame that starts while the engine is busy is recognised and skipped.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      in_frame <= 1'b0;
      beat_idx <= '0;
    end else if (beat) begin
      in_frame <= !s_axis_tlast;
      if (s_axis_tlast)           beat_idx <= '0;
      else if (beat_idx != 8'hFF) beat_idx <= beat_idx + 8'd1;
    end
  end

  // Engine: header capture, decision, metadata and payload writes, events.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      state          <= S_IDLE;
      busy_q         <= 1'b0;
      f_src_mac      <= '0;
      f_ethertype    <= '0;
      f_ver_ihl      <= '0;
      f_total_len    <= '0;
      f_flags_frag   <= '0;
      f_proto        <= '0;
      f_src_ip       <= '0;
      f_dst_ip_hi    <= '0;
      f_hdr_sum      <= '0;
      meta_ip        <= '0;
      meta_port      <= '0;
      meta_len       <= '0;
      meta_sock      <= '0;
      meta_flags     <= '0;
      meta_mac       <= '0;
      need_end       <= '0;
      ev_delivered   <= 1'b0;
      ev_fifo_drop   <= 1'b0;
      ev_no_socket   <= 1'b0;
      ev_bad         <= 1'b0;
    end else begin
      ev_delivered <= 1'b0;
      ev_fifo_drop <= 1'b0;
      ev_no_socket <= 1'b0;
      ev_bad       <= 1'b0;
      case (state)
        S_IDLE: begin
          if (beat && !in_frame) begin
            f_src_mac[47:32] <= be16(s_axis_tdata[63:48]);
            busy_q           <= 1'b1;
            state            <= s_axis_tlast ? S_DRAIN : S_HDR;
          end
        end
        S_HDR: begin
          if (beat) begin
            case (beat_idx)
              8'd1: begin
                f_src_mac[31:0] <= be32(s_axis_tdata[31:0]);
                f_ethertype     <= be16(s_axis_tdata[47:32]);
                f_ver_ihl       <= s_axis_tdata[55:48];
                f_hdr_sum       <= {4'd0, s_axis_tdata[55:48], s_axis_tdata[63:56]};
              end
              8'd2: begin
                f_total_len  <= be16(s_axis_tdata[15:0]);
                f_flags_frag <= be16(s_axis_tdata[47:32]);
                f_proto      <= s_axis_tdata[63:56];
                f_hdr_sum    <= f_hdr_sum + {2'b00, beat_word_sum(s_axis_tdata, 8'hFF)};
              end
              8'd3: begin
                f_src_ip    <= be32(s_axis_tdata[47:16]);
                f_dst_ip_hi <= be16(s_axis_tdata[63:48]);
                f_hdr_sum   <= f_hdr_sum + {2'b00, beat_word_sum(s_axis_tdata, 8'hFF)};
              end
              default: ;
            endcase
            if (d_beat) begin
              meta_ip    <= f_src_ip;
              meta_port  <= d_src_port;
              meta_len   <= d_payload_len;
              meta_sock  <= d_match_idx;
              meta_mac   <= f_src_mac;
              meta_flags <= d_flags;
              need_end   <= PAYLOAD_OFFSET + d_payload_len[11:0];
              if (!d_candidate) begin
                state <= S_DRAIN;
              end else if (d_bad) begin
                ev_bad <= 1'b1;
                state  <= S_DRAIN;
              end else if (!d_match) begin
                ev_no_socket <= 1'b1;
                state        <= S_DRAIN;
              end else if (!fifo_ready) begin
                ev_fifo_drop <= 1'b1;
                state        <= S_DRAIN;
              end else begin
                state <= S_META0;
              end
            end else if (s_axis_tlast) begin
              state <= S_DRAIN;
            end
          end
        end
        S_META0: begin
          if (fifo_fire) state <= S_META1;
        end
        S_META1: begin
          if (fifo_fire) state <= (meta_len == 16'd0) ? S_DRAIN : S_PAYLOAD;
        end
        S_PAYLOAD: begin
          if (final_write) state <= S_DRAIN;
        end
        S_DRAIN: begin
          if (!in_frame) begin
            state  <= S_IDLE;
            busy_q <= 1'b0;
          end
        end
        default: begin
          state  <= S_DRAIN;
          busy_q <= 1'b1;
        end
      endcase
      // End of an accepted datagram: committed, or dropped by its late verdict.
      if (final_write) begin
        ev_delivered <= !fifo_bad;
        ev_bad       <= fifo_bad;
      end
    end
  end

  // Payload words, completion flags and the UDP checksum. Loads of `pay_*`
  // come from exactly one source per clock: an input beat that completes a
  // word (or ends the frame early), or the flush of a final short word.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cap_active     <= 1'b0;
      pay_rem        <= '0;
      hold           <= '0;
      flush_pend     <= 1'b0;
      pay_valid      <= 1'b0;
      pay_data       <= '0;
      pay_keep       <= '0;
      pay_last       <= 1'b0;
      pay_bad        <= 1'b0;
      rx_complete    <= 1'b0;
      rx_short       <= 1'b0;
      csum_acc       <= '0;
      csum_rem       <= '0;
      udp_csum_field <= '0;
      csum_on        <= 1'b0;
    end else begin
      if ((state == S_PAYLOAD) && fifo_fire) pay_valid <= 1'b0;

      if (d_beat) begin
        // Start of an accepted (or not) datagram: arm capture and the checksum.
        cap_active  <= d_candidate && !d_bad && d_match && fifo_ready && (d_payload_len != 16'd0);
        pay_rem     <= d_payload_len[10:0];
        flush_pend  <= 1'b0;
        rx_complete <= 1'b0;
        rx_short    <= 1'b0;
        csum_on     <= csum_check;
        csum_rem    <= d_payload_len[11:0] + 12'd2;
        csum_acc    <= {16'd0, f_src_ip[31:16]} + {16'd0, f_src_ip[15:0]} +
                       {16'd0, d_dst_ip[31:16]} + {16'd0, d_dst_ip[15:0]} +
                       {24'd0, IP_PROTO_UDP} + {16'd0, d_udp_len} +
                       {14'd0, beat_word_sum(s_axis_tdata, LANES_UDP_HDR)};
      end else begin
        if (track_beat) begin
          if (beat_idx == FIRST_PAY_BEAT) udp_csum_field <= be16(s_axis_tdata[15:0]);
          if (bytes_through >= need_end) rx_complete <= 1'b1;
          if (short_now)                  rx_short    <= 1'b1;
          if (csum_rem != 12'd0) begin
            csum_acc <= csum_acc + {14'd0, beat_word_sum(s_axis_tdata, csum_lanes)};
            csum_rem <= csum_rem - {8'd0, csum_take};
          end
          if (s_axis_tlast) csum_rem <= '0;
        end

        if (cap_beat) begin
          hold <= s_axis_tdata[63:16];
          if (short_now) begin
            // The frame ends inside the datagram: close the FIFO frame as bad.
            pay_valid  <= 1'b1;
            pay_data   <= {s_axis_tdata[15:0], hold};
            pay_keep   <= 8'hFF;
            pay_last   <= 1'b1;
            pay_bad    <= 1'b1;
            cap_active <= 1'b0;
          end else if (cap_first) begin
            if (pay_rem <= 11'd6) begin
              flush_pend <= 1'b1;
              cap_active <= 1'b0;
            end
          end else if (cap_emit) begin
            pay_valid <= 1'b1;
            pay_data  <= {s_axis_tdata[15:0], hold};
            pay_keep  <= keep_mask(emit_n);
            pay_last  <= emit_last;
            pay_bad   <= 1'b0;
            pay_rem   <= rem_after;
            if (emit_last) begin
              cap_active <= 1'b0;
            end else if (rem_after <= 11'd6) begin
              flush_pend <= 1'b1;
              cap_active <= 1'b0;
            end
          end
        end else if (flush_pend) begin
          pay_valid  <= 1'b1;
          pay_data   <= {16'd0, hold};
          pay_keep   <= keep_mask(pay_rem[3:0]);
          pay_last   <= 1'b1;
          pay_bad    <= rx_short;
          flush_pend <= 1'b0;
        end
      end
    end
  end

  // Simulation-only checks: the FIFO always has room for an accepted
  // datagram's writes, and the payload register is never overwritten.
  // synthesis translate_off
  always @(posedge clk) begin
    if (resetn) begin
      if (fifo_valid && !fifo_ready)
        $error("%m: RX FIFO write refused (free slot checked at the decision)");
      if (pay_valid && !((state == S_PAYLOAD) && fifo_fire) &&
          ((cap_beat && (short_now || cap_emit)) || (!cap_beat && flush_pend)))
        $error("%m: payload word register overwritten");
    end
  end
  // synthesis translate_on

endmodule
