// -----------------------------------------------------------------------------
// File: rtlnet_arp.sv
// Purpose: RTLNet ARP responder leaf (RFC 826 over RFC 894 Ethernet II). It
//   answers an ARP request for the node's own IPv4 address with a 42-byte
//   unicast ARP reply and ignores every other frame. It is a protocol leaf of
//   rtlnet_eth_protocol (documentation/rtlnet_architecture.md sections 7.5,
//   15.4) and keeps no translation table.
// Overview:
//   * Two state machines, one registered state variable each:
//       rx_state  S_RX_B0..S_RX_B5, S_RX_TAIL   one state per request beat
//       tx_state  S_TX_IDLE, S_TX_DELAY, S_TX_B0..S_TX_B5
//     The receive machine captures the RFC 826 fields beat by beat and judges
//     the request at beat 5 (bytes 40-47). The transmit machine waits
//     REPLY_DELAY_CYCLES, then offers the six reply beats to one
//     rtlnet_axis_reg_slice. The reply is the RFC 826 swap: the request's
//     sender becomes the target, the local addresses become the sender,
//     ar$op becomes ares_op$REPLY.
//   * Accept rules (all must hold): EtherType 0x0806, ar$hrd 1, ar$pro 0x0800,
//     ar$hln 6, ar$pln 4, ar$op 1 (request), ar$tpa = local_ip, bytes 40-41
//     present in tkeep, and the frame's first beat found the leaf enabled and
//     idle. Bytes past 41 are Ethernet padding and are ignored. The Ethernet
//     destination is not checked (the wrapper's filter does that).
//   * One request at a time. A frame that starts while a reply is pending or
//     being sent is ignored whole: its reply fields are never captured, so the
//     reply in progress cannot be overwritten. s_axis_tready is held at 1.
//   * busy (registered) is high from the decision (two clocks after the
//     request's last beat) until the reply's last beat is handed to the output
//     slice, the reply delay included.
//   * enable is sampled at a frame's first beat: a frame that starts while the
//     leaf is disabled is ignored. A request accepted before a disable is
//     still answered.
//   * claim (registered one-clock pulse, architecture 7.5): the clock after
//     the last beat of every request this leaf answers (the clock rx_frame_end
//     is high, one clock before busy rises), gated by enable at that edge, so
//     a disabled leaf never claims. The wrapper keeps a claimed frame from the
//     CPU network path.
//   * Registers (12-bit leaf register port, read data registered one clock
//     after reg_rd_en): offsets and bits are defined in
//     cores/rtlnet_arp/driver/rtlnet_arp.h; the localparams below mirror it.
//   * Latency: the reply's first beat leaves the slice REPLY_DELAY_CYCLES + 4
//     clocks after the clock in which the request's last beat is accepted.
//   Request/reply layout (byte offsets, beat k = bytes 8k..8k+7):
//     0-5 dst MAC, 6-11 src MAC, 12-13 EtherType, 14-15 ar$hrd, 16-17 ar$pro,
//     18 ar$hln, 19 ar$pln, 20-21 ar$op, 22-27 ar$sha, 28-31 ar$spa,
//     32-37 ar$tha, 38-41 ar$tpa.
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: claim output (leaf contract 7.5, CPU network path).
// Clocks: clk (proto_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_arp #(
  parameter int REPLY_DELAY_CYCLES = 1250        // clk cycles from the decision to the first reply beat
)(
  // Leaf clock (proto_clk) and its synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Leaf enable from the wrapper's LEAF_ENABLE register (proto_clk level).
  input  logic        enable,

  // Frame in, RTLNet stream (frame byte 0 in tdata[7:0], padding retained);
  // s_axis_tready is a flop held at 1 after reset.
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

  // Leaf status (registered): high while a request is being answered.
  output logic        busy,

  // Claim (registered one-clock pulse): this leaf answers the frame that just
  // ended; issued the clock after its last beat.
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
  // Register map (mirror of cores/rtlnet_arp/driver/rtlnet_arp.h).
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID              = 12'h000;
  localparam logic [11:0] REG_VERSION         = 12'h004;
  localparam logic [11:0] REG_CAPS            = 12'h008;
  localparam logic [11:0] REG_CTRL            = 12'h00C;
  localparam logic [11:0] REG_STATUS          = 12'h010;
  localparam logic [11:0] REG_REQUESTS_FOR_US = 12'h020;
  localparam logic [11:0] REG_REPLIES_SENT    = 12'h024;
  localparam logic [11:0] REG_IGNORED         = 12'h028;
  localparam int          CTRL_CNT_CLEAR_BIT  = 0;
  localparam int          STATUS_ENABLED_BIT  = 0;
  localparam int          STATUS_BUSY_BIT     = 1;
  localparam logic [31:0] ID_VALUE            = id4("A", "R", "P", "1");
  localparam logic [31:0] VERSION_VALUE       = 32'h10222026;

  // ---------------------------------------------------------------------------
  // RFC 826 field values matched or emitted.
  // ---------------------------------------------------------------------------
  localparam logic [15:0] ARP_HTYPE_ETH    = 16'h0001;   // ar$hrd, bytes 14-15
  localparam logic [15:0] ARP_PTYPE_IPV4   = 16'h0800;   // ar$pro, bytes 16-17
  localparam logic [7:0]  ARP_HLEN         = 8'd6;       // ar$hln, byte 18
  localparam logic [7:0]  ARP_PLEN         = 8'd4;       // ar$pln, byte 19
  localparam logic [15:0] ARP_OPER_REQUEST = 16'h0001;   // ares_op$REQUEST
  localparam logic [15:0] ARP_OPER_REPLY   = 16'h0002;   // ares_op$REPLY
  localparam logic [7:0]  KEEP_FULL        = 8'hFF;
  localparam logic [7:0]  KEEP_REPLY_LAST  = 8'h03;      // reply beat 5 holds bytes 40-41

  localparam int                 DELAY_W    = (clog2i(REPLY_DELAY_CYCLES + 1) < 1) ? 1 : clog2i(REPLY_DELAY_CYCLES + 1);
  localparam logic [DELAY_W-1:0] DELAY_LOAD = REPLY_DELAY_CYCLES;

  generate
    if (REPLY_DELAY_CYCLES < 0) begin : g_bad_delay
      $fatal(1, "rtlnet_arp: REPLY_DELAY_CYCLES=%0d must not be negative", REPLY_DELAY_CYCLES);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // State encodings.
  // ---------------------------------------------------------------------------
  localparam logic [2:0] S_RX_B0   = 3'd0;
  localparam logic [2:0] S_RX_B1   = 3'd1;
  localparam logic [2:0] S_RX_B2   = 3'd2;
  localparam logic [2:0] S_RX_B3   = 3'd3;
  localparam logic [2:0] S_RX_B4   = 3'd4;
  localparam logic [2:0] S_RX_B5   = 3'd5;
  localparam logic [2:0] S_RX_TAIL = 3'd6;

  localparam logic [2:0] S_TX_IDLE  = 3'd0;
  localparam logic [2:0] S_TX_DELAY = 3'd1;
  localparam logic [2:0] S_TX_B0    = 3'd2;
  localparam logic [2:0] S_TX_B1    = 3'd3;
  localparam logic [2:0] S_TX_B2    = 3'd4;
  localparam logic [2:0] S_TX_B3    = 3'd5;
  localparam logic [2:0] S_TX_B4    = 3'd6;
  localparam logic [2:0] S_TX_B5    = 3'd7;

  // ---------------------------------------------------------------------------
  // Receive machine and captured fields (number order: first wire byte most
  // significant).
  // ---------------------------------------------------------------------------
  logic [2:0]         rx_state;
  logic               frame_taken;         // this frame began while enabled and idle
  logic               frame_is_arp;        // this frame's EtherType is 0x0806
  logic               request_ok;          // beat-5 verdict, held for the padding beats
  logic               rx_frame_end;        // one clock: a taken frame that is a valid request ended
  logic [15:0]        rx_ethertype;
  logic [15:0]        rx_htype;
  logic [15:0]        rx_ptype;
  logic [7:0]         rx_hlen;
  logic [7:0]         rx_plen;
  logic [15:0]        rx_oper;
  logic [47:0]        rx_sha;              // reply destination and ar$tha
  logic [31:0]        rx_spa;              // reply ar$tpa
  logic [15:0]        rx_tpa_high;

  // Transmit machine.
  logic [2:0]         tx_state;
  logic [DELAY_W-1:0] delay_count;
  logic [47:0]        reply_mac;           // local MAC, read once at the decision
  logic [31:0]        reply_ip;            // local IP, read once at the decision
  logic [63:0]        tx_data;
  logic [7:0]         tx_keep;
  logic               tx_last;
  logic               tx_valid;
  logic               tx_ready;

  // Counters and register file.
  logic [31:0]        cnt_requests;
  logic [31:0]        cnt_replies;
  logic [31:0]        cnt_ignored;
  logic               cnt_clear;

  // ---------------------------------------------------------------------------
  // Named conditions.
  // ---------------------------------------------------------------------------
  logic beat;
  logic tx_is_idle;
  logic start_reply;
  logic reply_beat_taken;
  logic beat1_is_arp;
  logic tpa_low_local;
  logic request_ok_now;
  logic answer_now;
  logic arp_now;

  assign beat             = s_axis_tvalid;                      // s_axis_tready is held at 1
  assign tx_is_idle       = (tx_state == S_TX_IDLE);
  assign start_reply      = rx_frame_end;
  assign reply_beat_taken = tx_valid && tx_ready;
  assign beat1_is_arp     = (be16(s_axis_tdata[47:32]) == ETHERTYPE_ARP);
  assign tpa_low_local    = (be16(s_axis_tdata[15:0]) == local_ip[15:0]);
  // RFC 826 "Packet Reception": hardware type, protocol type, the optional
  // length checks (made strictly), "Am I the target protocol address?",
  // "Is the opcode ares_op$REQUEST?"; plus bytes 40-41 present.
  assign request_ok_now   = (rx_ethertype == ETHERTYPE_ARP) && (rx_htype == ARP_HTYPE_ETH) &&
                            (rx_ptype == ARP_PTYPE_IPV4) && (rx_hlen == ARP_HLEN) && (rx_plen == ARP_PLEN) &&
                            (rx_oper == ARP_OPER_REQUEST) && (rx_tpa_high == local_ip[31:16]) && tpa_low_local &&
                            s_axis_tkeep[0] && s_axis_tkeep[1];
  // At a frame's last beat: answer it, or (an ARP frame) count it as ignored.
  assign answer_now       = frame_taken && (((rx_state == S_RX_B5) && request_ok_now) ||
                                            ((rx_state == S_RX_TAIL) && request_ok));
  assign arp_now          = (rx_state == S_RX_B1) ? beat1_is_arp : ((rx_state != S_RX_B0) && frame_is_arp);

  // s_axis_tready: a flop that is 1 from the first clock on (in reset too); the
  // leaf never stalls the fan-out.
  always_ff @(posedge clk) begin
    s_axis_tready <= 1'b1;
  end

  // Receive machine: the state is the beat number of the frame. The check
  // fields are captured for every frame (only a taken frame's verdict is ever
  // used); the reply fields (ar$sha, ar$spa) only for a taken frame, so a
  // frame that arrives during a reply never disturbs it.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      rx_state     <= S_RX_B0;
      frame_taken  <= 1'b0;
      frame_is_arp <= 1'b0;
      request_ok   <= 1'b0;
      rx_frame_end <= 1'b0;
      claim        <= 1'b0;
      rx_ethertype <= '0;
      rx_htype     <= '0;
      rx_ptype     <= '0;
      rx_hlen      <= '0;
      rx_plen      <= '0;
      rx_oper      <= '0;
      rx_sha       <= '0;
      rx_spa       <= '0;
      rx_tpa_high  <= '0;
    end else begin
      rx_frame_end <= 1'b0;
      claim        <= 1'b0;
      if (beat) begin
        if (s_axis_tlast) rx_frame_end <= answer_now;
        if (s_axis_tlast) claim        <= answer_now && enable;
        case (rx_state)
          S_RX_B0: begin                       // bytes 0-7: Ethernet destination, source MAC high
            frame_taken  <= enable && tx_is_idle && !start_reply;
            frame_is_arp <= 1'b0;
            request_ok   <= 1'b0;
            rx_state     <= s_axis_tlast ? S_RX_B0 : S_RX_B1;
          end
          S_RX_B1: begin                       // bytes 8-15: source MAC low, EtherType, ar$hrd
            rx_ethertype <= be16(s_axis_tdata[47:32]);
            rx_htype     <= be16(s_axis_tdata[63:48]);
            frame_is_arp <= beat1_is_arp;
            rx_state     <= s_axis_tlast ? S_RX_B0 : S_RX_B2;
          end
          S_RX_B2: begin                       // bytes 16-23: ar$pro, ar$hln, ar$pln, ar$op, ar$sha high
            rx_ptype <= be16(s_axis_tdata[15:0]);
            rx_hlen  <= s_axis_tdata[23:16];
            rx_plen  <= s_axis_tdata[31:24];
            rx_oper  <= be16(s_axis_tdata[47:32]);
            if (frame_taken) rx_sha[47:32] <= be16(s_axis_tdata[63:48]);
            rx_state <= s_axis_tlast ? S_RX_B0 : S_RX_B3;
          end
          S_RX_B3: begin                       // bytes 24-31: ar$sha low, ar$spa
            if (frame_taken) begin
              rx_sha[31:0] <= be32(s_axis_tdata[31:0]);
              rx_spa       <= be32(s_axis_tdata[63:32]);
            end
            rx_state <= s_axis_tlast ? S_RX_B0 : S_RX_B4;
          end
          S_RX_B4: begin                       // bytes 32-39: ar$tha (ignored), ar$tpa high
            rx_tpa_high <= be16(s_axis_tdata[63:48]);
            rx_state    <= s_axis_tlast ? S_RX_B0 : S_RX_B5;
          end
          S_RX_B5: begin                       // bytes 40-47: ar$tpa low, then padding
            request_ok <= request_ok_now;
            rx_state   <= s_axis_tlast ? S_RX_B0 : S_RX_TAIL;
          end
          S_RX_TAIL: begin                     // Ethernet padding, ignored
            if (s_axis_tlast) rx_state <= S_RX_B0;
          end
          default: rx_state <= S_RX_B0;
        endcase
      end
    end
  end

  // Transmit machine: latch the local address once at the decision, count the
  // reply delay, then hand the six reply beats to the output slice.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      tx_state    <= S_TX_IDLE;
      busy        <= 1'b0;
      delay_count <= '0;
      reply_mac   <= '0;
      reply_ip    <= '0;
    end else begin
      case (tx_state)
        S_TX_IDLE: begin
          if (start_reply) begin
            reply_mac   <= local_mac;
            reply_ip    <= local_ip;
            delay_count <= DELAY_LOAD;
            busy        <= 1'b1;
            tx_state    <= S_TX_DELAY;
          end
        end
        S_TX_DELAY: begin                      // REPLY_DELAY_CYCLES + 1 clocks
          if (delay_count == '0) tx_state    <= S_TX_B0;
          else                   delay_count <= delay_count - 1'b1;
        end
        S_TX_B0: if (reply_beat_taken) tx_state <= S_TX_B1;
        S_TX_B1: if (reply_beat_taken) tx_state <= S_TX_B2;
        S_TX_B2: if (reply_beat_taken) tx_state <= S_TX_B3;
        S_TX_B3: if (reply_beat_taken) tx_state <= S_TX_B4;
        S_TX_B4: if (reply_beat_taken) tx_state <= S_TX_B5;
        S_TX_B5: begin
          if (reply_beat_taken) begin
            busy     <= 1'b0;
            tx_state <= S_TX_IDLE;
          end
        end
        default: begin
          busy     <= 1'b0;
          tx_state <= S_TX_IDLE;
        end
      endcase
    end
  end

  // The reply beat of the current transmit state (bus lanes, high lane first):
  //   B0 dst = request ar$sha, src MAC high   B1 src MAC low, EtherType, ar$hrd
  //   B2 ar$pro, ar$hln, ar$pln, ar$op = 2, ar$sha high = local MAC
  //   B3 ar$sha low, ar$spa = local IP        B4 ar$tha = request ar$sha, ar$tpa high
  //   B5 ar$tpa low = request ar$spa low (tkeep 0x03, tlast)
  always_comb begin
    tx_valid = 1'b1;
    tx_data  = '0;
    tx_keep  = KEEP_FULL;
    tx_last  = 1'b0;
    case (tx_state)
      S_TX_B0: tx_data = {be16(reply_mac[47:32]), be48(rx_sha)};
      S_TX_B1: tx_data = {be16(ARP_HTYPE_ETH), be16(ETHERTYPE_ARP), be32(reply_mac[31:0])};
      S_TX_B2: tx_data = {be16(reply_mac[47:32]), be16(ARP_OPER_REPLY), ARP_PLEN, ARP_HLEN, be16(ARP_PTYPE_IPV4)};
      S_TX_B3: tx_data = {be32(reply_ip), be32(reply_mac[31:0])};
      S_TX_B4: tx_data = {be16(rx_spa[31:16]), be48(rx_sha)};
      S_TX_B5: begin
        tx_data = {48'd0, be16(rx_spa[15:0])};
        tx_keep = KEEP_REPLY_LAST;
        tx_last = 1'b1;
      end
      default: tx_valid = 1'b0;
    endcase
  end

  // Output slice: registered ready back to the transmit machine, registered
  // beat to the wrapper's arbiter.
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
    .s_tready (tx_ready),
    .m_tdata  (m_axis_tdata),
    .m_tkeep  (m_axis_tkeep),
    .m_tlast  (m_axis_tlast),
    .m_tvalid (m_axis_tvalid),
    .m_tready (m_axis_tready)
  );

  // Counters: requests for the local address (answered or not), replies
  // handed to the output slice, ARP frames that were not answered.
  assign cnt_clear = reg_wr_en && (reg_wr_addr == REG_CTRL) && reg_wr_data[CTRL_CNT_CLEAR_BIT];

  always_ff @(posedge clk) begin
    if (!resetn || cnt_clear) begin
      cnt_requests <= '0;
      cnt_replies  <= '0;
      cnt_ignored  <= '0;
    end else begin
      if (beat && s_axis_tlast && answer_now)               cnt_requests <= cnt_requests + 1'b1;
      if (beat && s_axis_tlast && !answer_now && arp_now)   cnt_ignored  <= cnt_ignored + 1'b1;
      if ((tx_state == S_TX_B5) && reply_beat_taken)        cnt_replies  <= cnt_replies + 1'b1;
    end
  end

  // Registered read mux; undefined offsets read 0.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:              reg_rd_data <= ID_VALUE;
        REG_VERSION:         reg_rd_data <= VERSION_VALUE;
        REG_CAPS:            reg_rd_data <= 32'(REPLY_DELAY_CYCLES);
        REG_CTRL:            reg_rd_data <= '0;
        REG_STATUS: begin
          reg_rd_data                     <= '0;
          reg_rd_data[STATUS_ENABLED_BIT] <= enable;
          reg_rd_data[STATUS_BUSY_BIT]    <= busy;
        end
        REG_REQUESTS_FOR_US: reg_rd_data <= cnt_requests;
        REG_REPLIES_SENT:    reg_rd_data <= cnt_replies;
        REG_IGNORED:         reg_rd_data <= cnt_ignored;
        default:             reg_rd_data <= '0;
      endcase
    end
  end

endmodule
