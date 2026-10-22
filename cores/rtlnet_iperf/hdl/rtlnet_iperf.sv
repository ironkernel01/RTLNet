// -----------------------------------------------------------------------------
// File: rtlnet_iperf.sv
// Purpose: RTLNet iperf 2 (2.2.x) UDP server leaf. A PC running the stock
//   client measures the board without a TCP stack:
//     iperf -c <board> -u ...      the leaf counts the datagrams (bytes, loss,
//                                  out-of-order, jitter as iperf computes them)
//                                  and answers the client's FIN with the 128-byte
//                                  server report, to the client's source port;
//     iperf -c <board> -u -R ...   the leaf streams datagrams back to the
//                                  client's source port for the requested time
//                                  at the requested rate and ends the stream
//                                  with one datagram carrying the negated
//                                  sequence number.
// Overview:
//   * Leaf contract (documentation/rtlnet_architecture.md 7.5, 15.4): proto_clk,
//     s_axis_tready held 1, frames out through one rtlnet_axis_reg_slice, busy
//     registered, enable gates receive and transmit, 12-bit register port with
//     read data one clock after reg_rd_en.
//   * Wire format (iperf 2.2.x): every datagram starts with the 16-byte header
//     {id, tv_sec, tv_usec, id2}; the client test header follows from payload
//     offset 16 (flags, mBufLen at 28, mAmount at 36, upperflags at 48, lRate at
//     64) and is read only when the UDP length says it is complete (>= 88).
//     Sequence = {id2, id} when the flow's first datagram has SEQNO64B
//     (0x08000000), else the signed 32-bit id. A negative sequence is the FIN.
//   * Machines (one registered state variable each, one clocked process, a
//     recovering default):
//       capture    S_CAP_IDLE, S_CAP_RUN, S_CAP_SKIP: fields by beat index, the
//                  arrival time sampled at the last beat;
//       accounting S_AC_*: classify, open, count, order, transit, jitter, FIN,
//                  mean jitter (two divider passes), report, resend, reverse
//                  request (pacing rate by the divider);
//       reverse    S_RV_IDLE, S_RV_RUN: stream duration in 10 ms units;
//       transmit   S_TX_IDLE, S_TX_CSUM, S_TX_BEAT: report first, then a paced
//                  stream datagram, then the final datagram.
//   * Accounting, exactly as the iperf 2 server (Reporter.c, per datagram with
//     sequence magnitude p > 0, PacketID starting at 0):
//       p != PacketID + 1:  p < PacketID + 1 -> OutofOrder += 1 (an
//                           out-of-order datagram), else Lost += p - PacketID - 1;
//       PacketID = max(PacketID, p);
//       in-order datagrams only (the FIN included): transit = arrival - sent,
//       from the second one on J += (|transit - last transit| - J) / 16 and the
//       new J is added to a running sum; last transit = transit.
//     Report: datagrams = PacketID, error_cnt = max(Lost - OutofOrder, 0),
//     outorder_cnt = OutofOrder, bytes = UDP payload bytes (FIN included),
//     jitter = mean of the J samples (jitter1 seconds, jitter2 microseconds),
//     stop = first datagram's arrival to the FIN's arrival. Arrival times are
//     microseconds of this leaf; J is kept with 16 fraction bits.
//   * Accept rules (otherwise ignored): local MAC, EtherType 0x0800, IHL 5, MF = 0
//     and offset 0, UDP, local IP, destination port = UDP_PORT register, UDP
//     length >= 24 and inside the frame, frame reaches byte 64.
//   * Flow rules: one receive flow, keyed by client IP and UDP port; another
//     source is ignored while it is open; it closes on its FIN (report) or
//     after IDLE_TIMEOUT_MS of silence (no report). A FIN from the closed flow's
//     client resends the latched report; a non-FIN datagram from it opens a new
//     flow only with sequence 1 (late datagrams behind the FIN open nothing); a
//     FIN from anywhere else is ignored.
//   * Reverse: a first datagram with VERSION2 (0x04000000) and REVERSE (0x0400)
//     and CTRL.REVERSE_ALLOWED starts the stream (a repeat from the client
//     being served is ignored, another client restarts it). Length mBufLen (1470
//     when 0) clamped to 16..MAX_DGRAM_BYTES; duration |mAmount| x 10 ms
//     (negative mAmount) or BYTE_MODE_MS; rate lRate bit/s of payload (0 =
//     as fast as m_axis_tready allows) by a token bucket in 1/65536 bits.
//   * Deviations (documented in the core guide): no TCP, no -r/-d tradeoff or
//     dual tests, no enhanced (-e) report extension, sequence magnitudes and
//     counters 32 bit, byte mode runs BYTE_MODE_MS, the upper rate word ignored.
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk = proto_clk, CLK_HZ hertz; resetn synchronous, active low. No
//   crossings.
// -----------------------------------------------------------------------------
module rtlnet_iperf #(
  parameter int CLK_HZ          = 50_000_000,   // proto_clk frequency (microsecond time base)
  parameter int UDP_PORT        = 5001,         // reset value of the UDP_PORT register
  parameter int MAX_DGRAM_BYTES = 1472,         // largest reverse-stream UDP payload, 16..9000
  parameter int IDLE_TIMEOUT_MS = 3000,         // a silent receive flow closes after this
  parameter int BYTE_MODE_MS    = 10_000        // reverse duration when mAmount is not negative
)(
  // Clock and reset: proto_clk, synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Leaf enable from the wrapper (proto_clk level): 0 = ignore every frame,
  // send nothing, drop a pending report and stop a reverse stream.
  input  logic        enable,

  // Frame in, RTLNet stream (proto_clk): the wrapper's fan-out, byte 0 in
  // tdata[7:0], no FCS, padding kept. s_axis_tready is held 1.
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // Frame out, RTLNet stream (proto_clk): reports and reverse datagrams, the
  // registered outputs of one rtlnet_axis_reg_slice; no gap inside a frame.
  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  // Node address from the wrapper (proto_clk registers, read once per frame
  // sent): MAC octet 0 in [47:40], IP first octet in [31:24].
  input  logic [47:0] local_mac,
  input  logic [31:0] local_ip,

  // Leaf status (registered): high from the clock after a last beat until the
  // accounting of that frame is complete.
  output logic        busy,

  // Register port (proto_clk): one-clock write strobe; read data valid the
  // clock after reg_rd_en and held.
  input  logic        reg_wr_en,
  input  logic [11:0] reg_wr_addr,
  input  logic [31:0] reg_wr_data,
  input  logic        reg_rd_en,
  input  logic [11:0] reg_rd_addr,
  output logic [31:0] reg_rd_data
);

  import rtlnet_pkg::*;

  // ---------------------------------------------------------------------------
  // Register map: mirrors cores/rtlnet_iperf/driver/rtlnet_iperf.h (keep in step).
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID               = 12'h000;
  localparam logic [11:0] REG_VERSION          = 12'h004;
  localparam logic [11:0] REG_CAPS             = 12'h008;
  localparam logic [11:0] REG_CTRL             = 12'h00C;
  localparam logic [11:0] REG_STATUS           = 12'h010;
  localparam logic [11:0] REG_UDP_PORT         = 12'h014;
  localparam logic [11:0] REG_RX_DATAGRAMS     = 12'h018;
  localparam logic [11:0] REG_RX_BYTES_LO      = 12'h01C;
  localparam logic [11:0] REG_RX_BYTES_HI      = 12'h020;
  localparam logic [11:0] REG_RX_LOST          = 12'h024;
  localparam logic [11:0] REG_RX_OUTOFORDER    = 12'h028;
  localparam logic [11:0] REG_TX_DATAGRAMS     = 12'h02C;
  localparam logic [11:0] REG_JITTER_US16      = 12'h030;
  localparam logic [11:0] REG_REQ_RATE_BPS     = 12'h034;
  localparam logic [11:0] REG_LAST_DURATION_US = 12'h038;
  localparam logic [11:0] REG_REPORTS_SENT     = 12'h03C;
  localparam logic [31:0] ID_VALUE             = 32'h4950_5246;   // "IPRF"
  localparam logic [31:0] VERSION_VALUE        = 32'h1022_2026;
  localparam int          CTRL_REVERSE_BIT     = 0;
  localparam int          CTRL_CNT_CLEAR_BIT   = 16;
  localparam int          CLK_KHZ              = CLK_HZ / 1000;
  localparam logic [31:0] CAPS_VALUE           = {18'(CLK_KHZ), 14'(MAX_DGRAM_BYTES)};

  // ---------------------------------------------------------------------------
  // Protocol constants (iperf 2.2.x payloads.h, RFC 791, RFC 768).
  // ---------------------------------------------------------------------------
  localparam logic [15:0] IP_FRAG_MASK        = 16'h3FFF;
  localparam logic [15:0] UDP_HDR_BYTES       = 16'd8;
  localparam logic [15:0] IP_UDP_HDR_BYTES    = 16'd28;
  localparam logic [15:0] FRAME_HDR_BYTES     = 16'd42;            // Ethernet 14 + IPv4 20 + UDP 8
  localparam logic [15:0] UDP_LEN_MIN         = 16'd24;            // UDP header + 16-byte datagram header
  localparam logic [15:0] UDP_LEN_CLIENT_HDR  = 16'd88;            // + the client test header
  localparam logic [15:0] UDP_IN_FRAME_OFFSET = 16'd34;            // UDP header starts at byte 34
  localparam logic [31:0] FLAG_SEQNO64B       = 32'h0800_0000;
  localparam logic [31:0] FLAG_VERSION2       = 32'h0400_0000;
  localparam logic [15:0] UPPER_REVERSE       = 16'h0400;
  localparam logic [31:0] REPORT_FLAGS        = 32'h8800_0000;     // HEADER_VERSION1 | HEADER_SEQNO64B
  localparam logic [15:0] REPORT_PAYLOAD      = 16'd128;
  localparam logic [31:0] ONE_MILLION         = 32'd1_000_000;
  localparam logic [19:0] USEC_LAST           = 20'd999_999;
  localparam logic [31:0] IDLE_TIMEOUT_US     = IDLE_TIMEOUT_MS * 1000;
  localparam logic [31:0] BYTE_MODE_UNITS     = BYTE_MODE_MS / 10;  // 10 ms units
  localparam logic [13:0] UNIT_US_LAST        = 14'd9999;
  localparam logic [15:0] PAYLOAD_MIN         = 16'd16;
  localparam logic [15:0] PAYLOAD_MAX         = MAX_DGRAM_BYTES;
  localparam logic [15:0] PAYLOAD_DEFAULT     = (1470 > MAX_DGRAM_BYTES) ? MAX_DGRAM_BYTES : 1470;
  localparam int          JITTER_FRAC         = 16;                 // J fraction bits
  localparam int          J_W                 = 32 + JITTER_FRAC;

  // Microsecond time base: CYCLES_PER_US clocks, one more whenever the
  // accumulated fraction (CLK_HZ mod 1e6 millionths per microsecond) overflows.
  localparam int          CYCLES_PER_US       = CLK_HZ / 1_000_000;
  localparam logic [20:0] FRAC_PER_US         = CLK_HZ % 1_000_000;
  localparam int          US_DIV_W            = clog2i(CYCLES_PER_US + 1);
  localparam logic [US_DIV_W-1:0] US_DIV_SHORT = CYCLES_PER_US - 1;
  localparam logic [US_DIV_W-1:0] US_DIV_LONG  = CYCLES_PER_US;
  localparam logic [20:0] ONE_MILLION21       = 21'd1_000_000;

  // Transmit beat counter covers the longer of the report and the largest datagram.
  localparam int TX_MAX_PAYLOAD = (MAX_DGRAM_BYTES > 128) ? MAX_DGRAM_BYTES : 128;
  localparam int TX_BEAT_W      = clog2i(((TX_MAX_PAYLOAD + 42 + 7) / 8) + 1);

  // Machine states.
  localparam logic [1:0] S_CAP_IDLE = 2'd0;
  localparam logic [1:0] S_CAP_RUN  = 2'd1;
  localparam logic [1:0] S_CAP_SKIP = 2'd2;

  localparam logic [3:0] S_AC_IDLE       = 4'd0;
  localparam logic [3:0] S_AC_CLASSIFY   = 4'd1;
  localparam logic [3:0] S_AC_OPEN       = 4'd2;
  localparam logic [3:0] S_AC_COUNT      = 4'd3;
  localparam logic [3:0] S_AC_ORDER      = 4'd4;
  localparam logic [3:0] S_AC_TRANSIT    = 4'd5;
  localparam logic [3:0] S_AC_JITTER     = 4'd6;
  localparam logic [3:0] S_AC_FIN        = 4'd7;
  localparam logic [3:0] S_AC_MEAN       = 4'd8;
  localparam logic [3:0] S_AC_SPLIT      = 4'd9;
  localparam logic [3:0] S_AC_REPORT     = 4'd10;
  localparam logic [3:0] S_AC_RESEND     = 4'd11;
  localparam logic [3:0] S_AC_REVERSE    = 4'd12;
  localparam logic [3:0] S_AC_RATE       = 4'd13;
  localparam logic [3:0] S_AC_DELTA      = 4'd14;

  localparam logic S_RV_IDLE = 1'b0;
  localparam logic S_RV_RUN  = 1'b1;

  localparam logic [1:0] S_TX_IDLE = 2'd0;
  localparam logic [1:0] S_TX_CSUM = 2'd1;
  localparam logic [1:0] S_TX_BEAT = 2'd2;

  // Parameter legality.
  generate
    if (CYCLES_PER_US < 2) begin : g_bad_clk
      $fatal(1, "rtlnet_iperf: CLK_HZ=%0d, must be at least 2 MHz", CLK_HZ);
    end
    if (CLK_KHZ >= (1 << 18)) begin : g_bad_khz
      $fatal(1, "rtlnet_iperf: CLK_HZ=%0d does not fit the CAPS field (< 262.144 MHz)", CLK_HZ);
    end
    if (MAX_DGRAM_BYTES < 16 || MAX_DGRAM_BYTES > 9000) begin : g_bad_dgram
      $fatal(1, "rtlnet_iperf: MAX_DGRAM_BYTES=%0d, must be 16..9000", MAX_DGRAM_BYTES);
    end
    if (UDP_PORT < 1 || UDP_PORT > 65535) begin : g_bad_port
      $fatal(1, "rtlnet_iperf: UDP_PORT=%0d, must be 1..65535", UDP_PORT);
    end
    if (IDLE_TIMEOUT_MS < 1 || BYTE_MODE_MS < 10) begin : g_bad_times
      $fatal(1, "rtlnet_iperf: IDLE_TIMEOUT_MS >= 1 and BYTE_MODE_MS >= 10 required");
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Signals, by block.
  // ---------------------------------------------------------------------------
  // Register file.
  logic              reverse_allowed;
  logic [15:0]       port_reg;
  logic              cnt_clear;
  logic [31:0]       bytes_hi_latch;
  logic [31:0]       rd_mux;

  // Register-view statistics (cleared by CNT_CLEAR and by a flow/stream start).
  logic [31:0]       v_rx_dgrams;
  logic [63:0]       v_rx_bytes;
  logic [31:0]       v_rx_gaps;
  logic [31:0]       v_rx_ooo;
  logic [31:0]       v_tx_dgrams;
  logic [31:0]       v_reports;
  logic [31:0]       req_rate_bps;
  logic [31:0]       last_duration_us;

  // Time base.
  logic [US_DIV_W-1:0] us_div;
  logic [19:0]       us_frac;
  logic              us_tick;
  logic [31:0]       us32;
  logic [31:0]       sec;
  logic [19:0]       usec;
  logic [20:0]       us_frac_sum;
  logic              us_frac_carry;

  // Capture machine and captured fields.
  logic [1:0]        cap_state;
  logic [11:0]       cap_beat;              // saturates; fields live in beats 0-13
  logic              rx_done;               // one clock: a frame was captured
  logic              rx_hdr_ok;             // the frame reached beat 7
  logic [15:0]       rx_frame_bytes;
  logic [47:0]       rx_dst_mac;
  logic [47:0]       rx_src_mac;
  logic [15:0]       rx_ethertype;
  logic [7:0]        rx_ver_ihl;
  logic [15:0]       rx_frag;
  logic [7:0]        rx_proto;
  logic [31:0]       rx_src_ip;
  logic [31:0]       rx_dst_ip;
  logic [15:0]       rx_sport;
  logic [15:0]       rx_dport;
  logic [15:0]       rx_udp_len;
  logic [31:0]       rx_id;
  logic [31:0]       rx_tv_sec;
  logic [31:0]       rx_tv_usec;
  logic [31:0]       rx_id2;
  logic [31:0]       rx_flags;
  logic [31:0]       rx_mbuflen;
  logic [31:0]       rx_mamount;
  logic [15:0]       rx_upper;
  logic [31:0]       rx_lrate;
  logic [31:0]       rx_arr_us;
  logic [31:0]       rx_arr_sec;
  logic [19:0]       rx_arr_usec;

  // Accounting machine and flow state.
  logic [3:0]        ac_state;
  logic              rx_active;
  logic              ev_report;             // one clock: a report is ready in rp_*
  logic              ev_rv_start;           // one clock: a reverse request is ready in rvq_*
  logic              idle_clear;
  logic [47:0]       flow_mac;
  logic [31:0]       flow_ip;
  logic [15:0]       flow_port;
  logic              flow_seq64;
  logic [31:0]       flow_start_us;
  logic [31:0]       flow_start_sec;
  logic [19:0]       flow_start_usec;
  logic [31:0]       max_seq;               // iperf PacketID
  logic [31:0]       f_gaps;                // iperf Lost (sum of forward gaps)
  logic [31:0]       f_ooo;                 // iperf OutofOrder
  logic [63:0]       f_bytes;
  logic              ooo_pkt;               // the datagram being accounted is out of order
  logic              have_transit;
  logic [31:0]       last_transit;
  logic [31:0]       sent_us;               // tv_sec * 1e6 + tv_usec, modulo 2^32
  logic [31:0]       transit_q;             // arrival - sent, microseconds modulo 2^32
  logic [31:0]       jit_abs_q;             // |transit - last transit|
  logic [J_W-1:0]    jit_q;                 // J, microseconds with JITTER_FRAC fraction bits
  logic [63:0]       jit_sum;               // sum of the J samples (saturating)
  logic [31:0]       jit_cnt;
  logic              report_valid;
  logic [47:0]       rp_mac;
  logic [31:0]       rp_ip;
  logic [15:0]       rp_port;
  logic [63:0]       rp_bytes;
  logic [31:0]       rp_stop_sec;
  logic [31:0]       rp_stop_usec;
  logic [31:0]       rp_lost;
  logic [31:0]       rp_ooo;
  logic [31:0]       rp_dgrams;
  logic [31:0]       rp_jitter1;
  logic [31:0]       rp_jitter2;
  logic [47:0]       rvq_mac;
  logic [31:0]       rvq_ip;
  logic [15:0]       rvq_port;
  logic [15:0]       rvq_len;
  logic [31:0]       rvq_units;
  logic [31:0]       rvq_rate_q16;
  logic [31:0]       idle_us;

  // Divider.
  logic              div_start;
  logic [63:0]       div_dividend;
  logic [31:0]       div_divisor;
  logic              div_busy;
  logic              div_done;
  logic [63:0]       div_quotient;
  logic [31:0]       div_remainder;

  // Reverse stream control.
  logic              rv_state;
  logic [47:0]       rv_mac;
  logic [31:0]       rv_ip;
  logic [15:0]       rv_port;
  logic [15:0]       rv_len;
  logic [31:0]       rv_rate_q16;
  logic [31:0]       rv_target_units;
  logic [13:0]       rv_us;
  logic [31:0]       rv_units;

  // Transmit machine.
  logic [1:0]        tx_state;
  logic              report_pending;
  logic              rv_run_q;
  logic              rv_fin_pending;
  logic [63:0]       stream_seq;
  logic [39:0]       credit;               // token bucket, 1/65536 bits
  logic [15:0]       ip_ident;
  logic              tx_is_report;
  logic [47:0]       tx_dmac;
  logic [47:0]       tx_smac;
  logic [31:0]       tx_dip;
  logic [31:0]       tx_sip;
  logic [15:0]       tx_dport;
  logic [15:0]       tx_sport;
  logic [15:0]       tx_len;
  logic [15:0]       tx_ident;
  logic [15:0]       tx_csum;
  logic [63:0]       tx_seq;
  logic [31:0]       tx_tv_sec;
  logic [31:0]       tx_tv_usec;
  logic [63:0]       tx_r_bytes;
  logic [31:0]       tx_r_stop_sec;
  logic [31:0]       tx_r_stop_usec;
  logic [31:0]       tx_r_lost;
  logic [31:0]       tx_r_ooo;
  logic [31:0]       tx_r_dgrams;
  logic [31:0]       tx_r_jitter1;
  logic [31:0]       tx_r_jitter2;
  logic [TX_BEAT_W-1:0] tx_beat;
  logic [63:0]       tx_data;
  logic [7:0]        tx_keep;
  logic              tx_last;
  logic              tx_valid;
  logic              tx_ready;
  logic [63:0]       beat_word;

  // ---------------------------------------------------------------------------
  // Named conditions over the captured frame.
  // ---------------------------------------------------------------------------
  logic        has_client_hdr;
  logic        is_iperf;
  logic [31:0] h_flags;
  logic [31:0] h_mbuflen;
  logic [31:0] h_mamount;
  logic [15:0] h_upper;
  logic [31:0] h_lrate;
  logic        seq64;
  logic        seq_neg;
  logic [31:0] seq_mag;
  logic        seq_first;
  logic        same_flow;
  logic        same_reverse;
  logic        is_reverse_req;
  logic        late_after_flow;
  logic        idle_expired;
  logic signed [31:0] jit_d;
  logic [31:0] jit_abs;
  logic signed [J_W+1:0] jit_diff;
  logic [J_W-1:0] jit_next;
  logic [64:0] jit_sum_next;
  logic signed [21:0] dur_usec_raw;
  logic        dur_borrow;
  logic [15:0] rv_len_clamped;
  logic [31:0] rv_units_req;
  logic [32:0] dgram_cost;                 // L x 8 bits, in 1/65536 bits
  logic [39:0] credit_plus;                // credit after this clock's refill
  logic        stream_may_send;
  logic [TX_BEAT_W-1:0] tx_last_beat;
  logic [15:0] tx_frame_bytes;
  logic [7:0]  tx_last_keep;

  assign s_axis_tready  = 1'b1;
  assign has_client_hdr = (rx_udp_len >= UDP_LEN_CLIENT_HDR);
  assign is_iperf       = rx_hdr_ok && (rx_dst_mac == local_mac) && (rx_ethertype == ETHERTYPE_IPV4) &&
                          (rx_ver_ihl == IPV4_VER_IHL5) && ((rx_frag & IP_FRAG_MASK) == 16'd0) &&
                          (rx_proto == IP_PROTO_UDP) && (rx_dst_ip == local_ip) && (rx_dport == port_reg) &&
                          (rx_udp_len >= UDP_LEN_MIN) &&
                          ({1'b0, rx_udp_len} + {1'b0, UDP_IN_FRAME_OFFSET} <= {1'b0, rx_frame_bytes});
  assign h_flags        = has_client_hdr ? rx_flags   : 32'd0;
  assign h_mbuflen      = has_client_hdr ? rx_mbuflen : 32'd0;
  assign h_mamount      = has_client_hdr ? rx_mamount : 32'd0;
  assign h_upper        = has_client_hdr ? rx_upper   : 16'd0;
  assign h_lrate        = has_client_hdr ? rx_lrate   : 32'd0;
  assign seq64          = rx_active ? flow_seq64 : ((h_flags & FLAG_SEQNO64B) != 32'd0);
  assign seq_neg        = seq64 ? rx_id2[31] : rx_id[31];
  assign seq_mag        = seq_neg ? (32'd0 - rx_id) : rx_id;
  assign seq_first      = (rx_id == 32'd1) && (!seq64 || (rx_id2 == 32'd0));
  assign same_flow      = (rx_src_ip == flow_ip) && (rx_sport == flow_port);
  assign same_reverse   = (rv_state == S_RV_RUN) && (rx_src_ip == rv_ip) && (rx_sport == rv_port);
  assign is_reverse_req = ((h_flags & FLAG_VERSION2) != 32'd0) && ((h_upper & UPPER_REVERSE) != 16'd0);
  assign late_after_flow = report_valid && same_flow && !seq_first;
  assign idle_expired   = (idle_us >= IDLE_TIMEOUT_US);

  // Jitter (RFC 3550 6.4.1 as iperf applies it): D = transit - last transit.
  assign jit_d          = $signed(transit_q - last_transit);
  assign jit_abs        = jit_d[31] ? (32'd0 - $unsigned(jit_d)) : $unsigned(jit_d);
  assign jit_diff       = $signed({2'b00, jit_abs_q, {JITTER_FRAC{1'b0}}}) - $signed({2'b00, jit_q});
  assign jit_next       = J_W'($signed({2'b00, jit_q}) + (jit_diff >>> 4));
  assign jit_sum_next   = {1'b0, jit_sum} + {{(65 - J_W){1'b0}}, jit_next};

  // Flow duration with a microsecond borrow.
  assign dur_usec_raw   = $signed({2'b00, rx_arr_usec}) - $signed({2'b00, flow_start_usec});
  assign dur_borrow     = dur_usec_raw[21];

  // Reverse request: length clamp and duration.
  assign rv_len_clamped = (h_mbuflen == 32'd0)                 ? PAYLOAD_DEFAULT :
                          (h_mbuflen > {16'd0, PAYLOAD_MAX})   ? PAYLOAD_MAX :
                          (h_mbuflen < {16'd0, PAYLOAD_MIN})   ? PAYLOAD_MIN : h_mbuflen[15:0];
  assign rv_units_req   = h_mamount[31] ? (32'd0 - h_mamount) : BYTE_MODE_UNITS;

  // Token bucket: one datagram costs L x 8 bits.
  assign dgram_cost      = {14'd0, rv_len, 3'b000} << 16;
  assign stream_may_send = (rv_rate_q16 == 32'd0) || ({7'd0, credit} >= {14'd0, dgram_cost});

  // Refill: the rate per microsecond while running, capped at two datagrams.
  always_comb begin
    credit_plus = credit;
    if ((rv_state == S_RV_RUN) && us_tick && (rv_rate_q16 != 32'd0)) begin
      if ({1'b0, credit} + {9'd0, rv_rate_q16} > {7'd0, dgram_cost, 1'b0}) credit_plus = 40'({dgram_cost, 1'b0});
      else                                                                credit_plus = credit + {8'd0, rv_rate_q16};
    end
  end

  // ---------------------------------------------------------------------------
  // Register file. The read mux is registered and loads only on reg_rd_en; a
  // read of RX_BYTES_LO latches the high word for RX_BYTES_HI.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reverse_allowed <= 1'b1;
      port_reg        <= 16'(UDP_PORT);
      cnt_clear       <= 1'b0;
    end else begin
      cnt_clear <= 1'b0;
      if (reg_wr_en) begin
        case (reg_wr_addr)
          REG_CTRL: begin
            reverse_allowed <= reg_wr_data[CTRL_REVERSE_BIT];
            cnt_clear       <= reg_wr_data[CTRL_CNT_CLEAR_BIT];
          end
          REG_UDP_PORT: port_reg <= reg_wr_data[15:0];
          default: begin
          end
        endcase
      end
    end
  end

  always_comb begin
    case (reg_rd_addr)
      REG_ID:               rd_mux = ID_VALUE;
      REG_VERSION:          rd_mux = VERSION_VALUE;
      REG_CAPS:             rd_mux = CAPS_VALUE;
      REG_CTRL:             rd_mux = {31'd0, reverse_allowed};
      REG_STATUS:           rd_mux = {15'd0, enable, 14'd0, (rv_state == S_RV_RUN), rx_active};
      REG_UDP_PORT:         rd_mux = {16'd0, port_reg};
      REG_RX_DATAGRAMS:     rd_mux = v_rx_dgrams;
      REG_RX_BYTES_LO:      rd_mux = v_rx_bytes[31:0];
      REG_RX_BYTES_HI:      rd_mux = bytes_hi_latch;
      REG_RX_LOST:          rd_mux = (v_rx_gaps > v_rx_ooo) ? (v_rx_gaps - v_rx_ooo) : 32'd0;
      REG_RX_OUTOFORDER:    rd_mux = v_rx_ooo;
      REG_TX_DATAGRAMS:     rd_mux = v_tx_dgrams;
      REG_JITTER_US16:      rd_mux = jit_q[JITTER_FRAC-4 +: 32];       // J x 16
      REG_REQ_RATE_BPS:     rd_mux = req_rate_bps;
      REG_LAST_DURATION_US: rd_mux = last_duration_us;
      REG_REPORTS_SENT:     rd_mux = v_reports;
      default:              rd_mux = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data    <= 32'd0;
      bytes_hi_latch <= 32'd0;
    end else if (reg_rd_en) begin
      reg_rd_data <= rd_mux;
      if (reg_rd_addr == REG_RX_BYTES_LO) bytes_hi_latch <= v_rx_bytes[63:32];
    end
  end

  // ---------------------------------------------------------------------------
  // Time base: us_tick once per microsecond, exact on average for any CLK_HZ;
  // us32 free-running; sec and usec change in the same clock.
  // ---------------------------------------------------------------------------
  assign us_frac_sum   = {1'b0, us_frac} + FRAC_PER_US;
  assign us_frac_carry = (us_frac_sum >= ONE_MILLION21);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      us_div  <= US_DIV_SHORT;
      us_frac <= 20'd0;
      us_tick <= 1'b0;
      us32    <= 32'd0;
      sec     <= 32'd0;
      usec    <= 20'd0;
    end else begin
      us_tick <= (us_div == '0);
      if (us_div == '0) begin
        if (us_frac_carry) begin
          us_div  <= US_DIV_LONG;
          us_frac <= 20'(us_frac_sum - ONE_MILLION21);
        end else begin
          us_div  <= US_DIV_SHORT;
          us_frac <= us_frac_sum[19:0];
        end
      end else begin
        us_div <= us_div - 1'b1;
      end
      if (us_tick) begin
        us32 <= us32 + 32'd1;
        if (usec == USEC_LAST) begin
          usec <= 20'd0;
          sec  <= sec + 32'd1;
        end else begin
          usec <= usec + 20'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Capture machine. A frame that starts while the leaf is disabled or the
  // accounting of the previous frame still runs is skipped whole (S_CAP_SKIP).
  // Otherwise each beat stores its fields (byte offsets in the header); the last
  // beat stores the length and the arrival time and pulses rx_done. The fields
  // hold until the next captured frame.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cap_state      <= S_CAP_IDLE;
      cap_beat       <= 8'd0;
      rx_done        <= 1'b0;
      rx_hdr_ok      <= 1'b0;
      rx_frame_bytes <= 16'd0;
      rx_dst_mac     <= 48'd0;
      rx_src_mac     <= 48'd0;
      rx_ethertype   <= 16'd0;
      rx_ver_ihl     <= 8'd0;
      rx_frag        <= 16'd0;
      rx_proto       <= 8'd0;
      rx_src_ip      <= 32'd0;
      rx_dst_ip      <= 32'd0;
      rx_sport       <= 16'd0;
      rx_dport       <= 16'd0;
      rx_udp_len     <= 16'd0;
      rx_id          <= 32'd0;
      rx_tv_sec      <= 32'd0;
      rx_tv_usec     <= 32'd0;
      rx_id2         <= 32'd0;
      rx_flags       <= 32'd0;
      rx_mbuflen     <= 32'd0;
      rx_mamount     <= 32'd0;
      rx_upper       <= 16'd0;
      rx_lrate       <= 32'd0;
      rx_arr_us      <= 32'd0;
      rx_arr_sec     <= 32'd0;
      rx_arr_usec    <= 20'd0;
    end else begin
      rx_done <= 1'b0;
      if (s_axis_tvalid) begin
        case (cap_state)
          S_CAP_IDLE: begin                               // first beat, bytes 0-7
            if (!enable || (ac_state != S_AC_IDLE) || rx_done) begin
              if (!s_axis_tlast) cap_state <= S_CAP_SKIP;
            end else begin
              rx_hdr_ok         <= 1'b0;
              rx_dst_mac        <= be48(s_axis_tdata[47:0]);
              rx_src_mac[47:32] <= be16(s_axis_tdata[63:48]);
              cap_beat          <= 12'd1;
              if (!s_axis_tlast) cap_state <= S_CAP_RUN;
            end
          end
          S_CAP_RUN: begin
            if (cap_beat != 12'hFFF) cap_beat <= cap_beat + 12'd1;
            case (cap_beat)
              12'd1: begin                                  // 8-15: source MAC, EtherType, version/IHL
                rx_src_mac[31:0] <= be32(s_axis_tdata[31:0]);
                rx_ethertype     <= be16(s_axis_tdata[47:32]);
                rx_ver_ihl       <= s_axis_tdata[55:48];
              end
              12'd2: begin                                  // 16-23: flags/fragment, protocol
                rx_frag  <= be16(s_axis_tdata[47:32]);
                rx_proto <= s_axis_tdata[63:56];
              end
              12'd3: begin                                  // 24-31: source IP, destination IP high
                rx_src_ip        <= be32(s_axis_tdata[47:16]);
                rx_dst_ip[31:16] <= be16(s_axis_tdata[63:48]);
              end
              12'd4: begin                                  // 32-39: destination IP low, ports, length
                rx_dst_ip[15:0] <= be16(s_axis_tdata[15:0]);
                rx_sport        <= be16(s_axis_tdata[31:16]);
                rx_dport        <= be16(s_axis_tdata[47:32]);
                rx_udp_len      <= be16(s_axis_tdata[63:48]);
              end
              12'd5: begin                                  // 40-47: id, tv_sec high
                rx_id            <= be32(s_axis_tdata[47:16]);
                rx_tv_sec[31:16] <= be16(s_axis_tdata[63:48]);
              end
              12'd6: begin                                  // 48-55: tv_sec low, tv_usec, id2 high
                rx_tv_sec[15:0] <= be16(s_axis_tdata[15:0]);
                rx_tv_usec      <= be32(s_axis_tdata[47:16]);
                rx_id2[31:16]   <= be16(s_axis_tdata[63:48]);
              end
              12'd7: begin                                  // 56-63: id2 low, client flags
                rx_id2[15:0] <= be16(s_axis_tdata[15:0]);
                rx_flags     <= be32(s_axis_tdata[47:16]);
                rx_hdr_ok    <= 1'b1;
              end
              12'd8:  rx_mbuflen[31:16] <= be16(s_axis_tdata[63:48]);   // 70-71
              12'd9: begin                                  // 72-73 mBufLen low, 78-79 mAmount high
                rx_mbuflen[15:0]  <= be16(s_axis_tdata[15:0]);
                rx_mamount[31:16] <= be16(s_axis_tdata[63:48]);
              end
              12'd10: rx_mamount[15:0] <= be16(s_axis_tdata[15:0]);     // 80-81
              12'd11: rx_upper         <= be16(s_axis_tdata[31:16]);    // 90-91
              12'd13: rx_lrate         <= be32(s_axis_tdata[47:16]);    // 106-109
              default: begin
              end
            endcase
            if (s_axis_tlast) begin
              rx_frame_bytes <= {1'b0, cap_beat, 3'b000} + {12'd0, keep_bytes(s_axis_tkeep)};
              rx_arr_us      <= us32;
              rx_arr_sec     <= sec;
              rx_arr_usec    <= usec;
              rx_done        <= 1'b1;
              cap_state      <= S_CAP_IDLE;
            end
          end
          S_CAP_SKIP: begin
            if (s_axis_tlast) cap_state <= S_CAP_IDLE;
          end
          default: begin
            cap_state <= S_CAP_IDLE;
          end
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Accounting machine: one step per clock; the divider passes of a FIN or a
  // reverse request take 64 clocks each. It owns the flow, the report snapshot,
  // the register-view statistics of the receive side and the one-clock events
  // towards the transmitter and the reverse control.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      ac_state         <= S_AC_IDLE;
      busy             <= 1'b0;
      rx_active        <= 1'b0;
      ev_report        <= 1'b0;
      ev_rv_start      <= 1'b0;
      idle_clear       <= 1'b0;
      flow_mac         <= 48'd0;
      flow_ip          <= 32'd0;
      flow_port        <= 16'd0;
      flow_seq64       <= 1'b0;
      flow_start_us    <= 32'd0;
      flow_start_sec   <= 32'd0;
      flow_start_usec  <= 20'd0;
      max_seq          <= 32'd0;
      f_gaps           <= 32'd0;
      f_ooo            <= 32'd0;
      f_bytes          <= 64'd0;
      ooo_pkt          <= 1'b0;
      have_transit     <= 1'b0;
      last_transit     <= 32'd0;
      sent_us          <= 32'd0;
      transit_q        <= 32'd0;
      jit_abs_q        <= 32'd0;
      jit_q            <= '0;
      jit_sum          <= 64'd0;
      jit_cnt          <= 32'd0;
      report_valid     <= 1'b0;
      rp_mac           <= 48'd0;
      rp_ip            <= 32'd0;
      rp_port          <= 16'd0;
      rp_bytes         <= 64'd0;
      rp_stop_sec      <= 32'd0;
      rp_stop_usec     <= 32'd0;
      rp_lost          <= 32'd0;
      rp_ooo           <= 32'd0;
      rp_dgrams        <= 32'd0;
      rp_jitter1       <= 32'd0;
      rp_jitter2       <= 32'd0;
      rvq_mac          <= 48'd0;
      rvq_ip           <= 32'd0;
      rvq_port         <= 16'd0;
      rvq_len          <= 16'd0;
      rvq_units        <= 32'd0;
      rvq_rate_q16     <= 32'd0;
      div_start        <= 1'b0;
      div_dividend     <= 64'd0;
      div_divisor      <= 32'd1;
      v_rx_dgrams      <= 32'd0;
      v_rx_bytes       <= 64'd0;
      v_rx_gaps        <= 32'd0;
      v_rx_ooo         <= 32'd0;
      req_rate_bps     <= 32'd0;
      last_duration_us <= 32'd0;
    end else begin
      ev_report   <= 1'b0;
      ev_rv_start <= 1'b0;
      idle_clear  <= 1'b0;
      div_start   <= 1'b0;
      busy        <= (ac_state != S_AC_IDLE) || rx_done;
      case (ac_state)
        S_AC_IDLE: begin
          if (rx_active && idle_expired) rx_active <= 1'b0;   // silent flow: closed, no report
          if (rx_done) ac_state <= S_AC_CLASSIFY;
        end
        S_AC_CLASSIFY: begin
          if (!is_iperf) begin
            ac_state <= S_AC_IDLE;
          end else if (rx_active) begin
            ac_state <= same_flow ? S_AC_COUNT : S_AC_IDLE;   // data or FIN of the open flow
          end else if (!seq_neg) begin
            if (is_reverse_req) begin
              if (!reverse_allowed || same_reverse) ac_state <= S_AC_IDLE;
              else                                  ac_state <= S_AC_REVERSE;
            end else if (late_after_flow) begin
              ac_state <= S_AC_IDLE;                          // late datagram behind the FIN
            end else begin
              ac_state <= S_AC_OPEN;
            end
          end else if (same_flow && report_valid) begin
            ac_state <= S_AC_RESEND;                          // the client repeats its FIN
          end else begin
            ac_state <= S_AC_IDLE;                            // FIN of no known flow
          end
        end
        S_AC_OPEN: begin                                      // first datagram of a flow
          rx_active       <= 1'b1;
          report_valid    <= 1'b0;
          flow_mac        <= rx_src_mac;
          flow_ip         <= rx_src_ip;
          flow_port       <= rx_sport;
          flow_seq64      <= ((h_flags & FLAG_SEQNO64B) != 32'd0);
          flow_start_us   <= rx_arr_us;
          flow_start_sec  <= rx_arr_sec;
          flow_start_usec <= rx_arr_usec;
          max_seq         <= 32'd0;
          f_gaps          <= 32'd0;
          f_ooo           <= 32'd0;
          f_bytes         <= 64'd0;
          have_transit    <= 1'b0;
          jit_q           <= '0;
          jit_sum         <= 64'd0;
          jit_cnt         <= 32'd0;
          req_rate_bps    <= h_lrate;
          v_rx_dgrams     <= 32'd0;
          v_rx_bytes      <= 64'd0;
          v_rx_gaps       <= 32'd0;
          v_rx_ooo        <= 32'd0;
          ac_state        <= S_AC_COUNT;
        end
        S_AC_COUNT: begin                                     // every datagram of the flow, FIN included
          f_bytes     <= f_bytes + {48'd0, rx_udp_len - UDP_HDR_BYTES};
          v_rx_bytes  <= v_rx_bytes + {48'd0, rx_udp_len - UDP_HDR_BYTES};
          v_rx_dgrams <= v_rx_dgrams + 32'd1;
          idle_clear  <= 1'b1;
          ac_state    <= S_AC_ORDER;
        end
        S_AC_ORDER: begin                                     // Reporter.c: Lost, OutofOrder, PacketID
          ooo_pkt <= (seq_mag != 32'd0) && (seq_mag <= max_seq);
          if (seq_mag != 32'd0) begin
            if (seq_mag <= max_seq) begin
              f_ooo    <= f_ooo + 32'd1;
              v_rx_ooo <= v_rx_ooo + 32'd1;
            end else begin
              f_gaps    <= f_gaps + (seq_mag - max_seq - 32'd1);
              v_rx_gaps <= v_rx_gaps + (seq_mag - max_seq - 32'd1);
              max_seq   <= seq_mag;
            end
          end
          sent_us  <= (rx_tv_sec * ONE_MILLION) + rx_tv_usec;
          ac_state <= S_AC_TRANSIT;
        end
        S_AC_TRANSIT: begin                                   // transit = arrival - sent
          transit_q <= rx_arr_us - sent_us;
          ac_state  <= S_AC_DELTA;
        end
        S_AC_DELTA: begin                                     // |D| against the last in-order transit
          jit_abs_q <= jit_abs;
          ac_state  <= S_AC_JITTER;
        end
        S_AC_JITTER: begin                                    // in-order datagrams only
          if ((seq_mag != 32'd0) && !ooo_pkt) begin
            if (have_transit) begin
              jit_q   <= jit_next;
              jit_sum <= jit_sum_next[64] ? 64'hFFFF_FFFF_FFFF_FFFF : jit_sum_next[63:0];
              jit_cnt <= jit_cnt + 32'd1;
            end
            last_transit <= transit_q;
            have_transit <= 1'b1;
          end
          ac_state <= seq_neg ? S_AC_FIN : S_AC_IDLE;
        end
        S_AC_FIN: begin                                       // close the flow, snapshot the report
          rx_active        <= 1'b0;
          rp_mac           <= flow_mac;
          rp_ip            <= flow_ip;
          rp_port          <= flow_port;
          rp_bytes         <= f_bytes;
          rp_dgrams        <= max_seq;
          rp_ooo           <= f_ooo;
          rp_lost          <= (f_gaps > f_ooo) ? (f_gaps - f_ooo) : 32'd0;
          rp_stop_sec      <= rx_arr_sec - flow_start_sec - {31'd0, dur_borrow};
          rp_stop_usec     <= dur_borrow ? 32'($signed(dur_usec_raw) + $signed(22'd1_000_000)) : 32'(dur_usec_raw);
          last_duration_us <= rx_arr_us - flow_start_us;
          div_dividend     <= (jit_cnt == 32'd0) ? 64'd0 : jit_sum;
          div_divisor      <= (jit_cnt == 32'd0) ? 32'd1 : jit_cnt;
          div_start        <= 1'b1;
          ac_state         <= S_AC_MEAN;
        end
        S_AC_MEAN: begin                                      // mean J (fixed point) -> microseconds
          if (div_done) begin
            div_dividend <= div_quotient >> JITTER_FRAC;
            div_divisor  <= ONE_MILLION;
            div_start    <= 1'b1;
            ac_state     <= S_AC_SPLIT;
          end
        end
        S_AC_SPLIT: begin                                     // seconds and microseconds of the mean
          if (div_done) begin
            rp_jitter1 <= div_quotient[31:0];
            rp_jitter2 <= div_remainder;
            ac_state   <= S_AC_REPORT;
          end
        end
        S_AC_REPORT: begin
          report_valid <= 1'b1;
          ev_report    <= 1'b1;
          ac_state     <= S_AC_IDLE;
        end
        S_AC_RESEND: begin
          ev_report <= 1'b1;
          ac_state  <= S_AC_IDLE;
        end
        S_AC_REVERSE: begin                                   // -R: describe the stream, compute the rate
          rvq_mac      <= rx_src_mac;
          rvq_ip       <= rx_src_ip;
          rvq_port     <= rx_sport;
          rvq_len      <= rv_len_clamped;
          rvq_units    <= rv_units_req;
          req_rate_bps <= h_lrate;
          div_dividend <= {16'd0, h_lrate, 16'd0};
          div_divisor  <= ONE_MILLION;
          div_start    <= 1'b1;
          ac_state     <= S_AC_RATE;
        end
        S_AC_RATE: begin
          if (div_done) begin
            rvq_rate_q16 <= (div_quotient[63:32] != 32'd0) ? 32'hFFFF_FFFF : div_quotient[31:0];
            ev_rv_start  <= 1'b1;
            ac_state     <= S_AC_IDLE;
          end
        end
        default: begin
          ac_state <= S_AC_IDLE;
        end
      endcase
      if (cnt_clear) begin
        v_rx_dgrams <= 32'd0;
        v_rx_bytes  <= 64'd0;
        v_rx_gaps   <= 32'd0;
        v_rx_ooo    <= 32'd0;
      end
    end
  end

  // Divider for the mean jitter and the pacing rate.
  rtlnet_iperf_div #(.DIV_BITS(64)) u_div (
    .clk       (clk),
    .resetn    (resetn),
    .start     (div_start),
    .dividend  (div_dividend),
    .divisor   (div_divisor),
    .busy      (div_busy),
    .done      (div_done),
    .quotient  (div_quotient),
    .remainder (div_remainder)
  );

  // Idle timer: microseconds since the last counted datagram, saturating.
  always_ff @(posedge clk) begin
    if (!resetn || idle_clear)            idle_us <= 32'd0;
    else if (us_tick && !idle_expired)    idle_us <= idle_us + 32'd1;
  end

  // ---------------------------------------------------------------------------
  // Reverse stream control: a request starts (or restarts towards a new
  // client) the run; it ends when the 10 ms unit count reaches the target or
  // the leaf is disabled.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      rv_state        <= S_RV_IDLE;
      rv_mac          <= 48'd0;
      rv_ip           <= 32'd0;
      rv_port         <= 16'd0;
      rv_len          <= 16'd16;
      rv_rate_q16     <= 32'd0;
      rv_target_units <= 32'd0;
      rv_us           <= 14'd0;
      rv_units        <= 32'd0;
    end else if (!enable) begin
      rv_state <= S_RV_IDLE;
    end else if (ev_rv_start) begin
      rv_mac          <= rvq_mac;
      rv_ip           <= rvq_ip;
      rv_port         <= rvq_port;
      rv_len          <= rvq_len;
      rv_rate_q16     <= rvq_rate_q16;
      rv_target_units <= rvq_units;
      rv_us           <= 14'd0;
      rv_units        <= 32'd0;
      rv_state        <= S_RV_RUN;
    end else begin
      case (rv_state)
        S_RV_IDLE: begin
        end
        S_RV_RUN: begin
          if (us_tick) begin
            if (rv_us == UNIT_US_LAST) begin
              rv_us    <= 14'd0;
              rv_units <= rv_units + 32'd1;
            end else begin
              rv_us <= rv_us + 14'd1;
            end
          end
          if (rv_units >= rv_target_units) rv_state <= S_RV_IDLE;
        end
        default: begin
          rv_state <= S_RV_IDLE;
        end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Transmit machine. S_TX_IDLE picks a pending report, else a stream datagram
  // the token bucket allows, else the owed final datagram, and copies its
  // descriptor (one reading of the address inputs and the port register);
  // S_TX_CSUM computes the IPv4 header checksum; S_TX_BEAT loads one beat
  // whenever the slice input is empty or being taken.
  // ---------------------------------------------------------------------------
  always_comb begin
    tx_frame_bytes = tx_len + FRAME_HDR_BYTES;
    tx_last_beat   = TX_BEAT_W'((tx_frame_bytes - 16'd1) >> 3);
    tx_last_keep   = keep_mask((tx_frame_bytes[2:0] == 3'd0) ? 4'd8 : {1'b0, tx_frame_bytes[2:0]});
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      tx_state       <= S_TX_IDLE;
      report_pending <= 1'b0;
      rv_run_q       <= 1'b0;
      rv_fin_pending <= 1'b0;
      stream_seq     <= 64'd0;
      credit         <= 40'd0;
      ip_ident       <= 16'd0;
      tx_is_report   <= 1'b0;
      tx_dmac        <= 48'd0;
      tx_smac        <= 48'd0;
      tx_dip         <= 32'd0;
      tx_sip         <= 32'd0;
      tx_dport       <= 16'd0;
      tx_sport       <= 16'd0;
      tx_len         <= 16'd0;
      tx_ident       <= 16'd0;
      tx_csum        <= 16'd0;
      tx_seq         <= 64'd0;
      tx_tv_sec      <= 32'd0;
      tx_tv_usec     <= 32'd0;
      tx_r_bytes     <= 64'd0;
      tx_r_stop_sec  <= 32'd0;
      tx_r_stop_usec <= 32'd0;
      tx_r_lost      <= 32'd0;
      tx_r_ooo       <= 32'd0;
      tx_r_dgrams    <= 32'd0;
      tx_r_jitter1   <= 32'd0;
      tx_r_jitter2   <= 32'd0;
      tx_beat        <= '0;
      tx_data        <= 64'd0;
      tx_keep        <= 8'd0;
      tx_last        <= 1'b0;
      tx_valid       <= 1'b0;
      v_tx_dgrams    <= 32'd0;
      v_reports      <= 32'd0;
    end else begin
      if (ev_report) report_pending <= 1'b1;
      rv_run_q <= (rv_state == S_RV_RUN);
      if (rv_run_q && (rv_state != S_RV_RUN) && enable) rv_fin_pending <= 1'b1;   // the stream ended
      credit <= credit_plus;
      if (tx_ready) tx_valid <= 1'b0;
      case (tx_state)
        S_TX_IDLE: begin
          tx_smac  <= local_mac;
          tx_sip   <= local_ip;
          tx_sport <= port_reg;
          if (report_pending) begin                           // the server report
            report_pending <= 1'b0;
            tx_is_report   <= 1'b1;
            tx_dmac        <= rp_mac;
            tx_dip         <= rp_ip;
            tx_dport       <= rp_port;
            tx_len         <= REPORT_PAYLOAD;
            tx_ident       <= ip_ident;
            ip_ident       <= ip_ident + 16'd1;
            tx_r_bytes     <= rp_bytes;
            tx_r_stop_sec  <= rp_stop_sec;
            tx_r_stop_usec <= rp_stop_usec;
            tx_r_lost      <= rp_lost;
            tx_r_ooo       <= rp_ooo;
            tx_r_dgrams    <= rp_dgrams;
            tx_r_jitter1   <= rp_jitter1;
            tx_r_jitter2   <= rp_jitter2;
            v_reports      <= v_reports + 32'd1;
            tx_state       <= S_TX_CSUM;
          end else if ((rv_state == S_RV_RUN) && !ev_rv_start && stream_may_send) begin   // stream datagram
            tx_is_report <= 1'b0;
            tx_dmac      <= rv_mac;
            tx_dip       <= rv_ip;
            tx_dport     <= rv_port;
            tx_len       <= rv_len;
            tx_ident     <= ip_ident;
            ip_ident     <= ip_ident + 16'd1;
            tx_seq       <= stream_seq + 64'd1;
            stream_seq   <= stream_seq + 64'd1;
            tx_tv_sec    <= sec;
            tx_tv_usec   <= {12'd0, usec};
            v_tx_dgrams  <= v_tx_dgrams + 32'd1;
            if (rv_rate_q16 != 32'd0) credit <= 40'({7'd0, credit_plus} - {14'd0, dgram_cost});
            tx_state     <= S_TX_CSUM;
          end else if (rv_fin_pending && (rv_state == S_RV_IDLE) && !ev_rv_start) begin   // final datagram
            rv_fin_pending <= 1'b0;
            tx_is_report   <= 1'b0;
            tx_dmac        <= rv_mac;
            tx_dip         <= rv_ip;
            tx_dport       <= rv_port;
            tx_len         <= rv_len;
            tx_ident       <= ip_ident;
            ip_ident       <= ip_ident + 16'd1;
            tx_seq         <= 64'd0 - (stream_seq + 64'd1);
            tx_tv_sec      <= sec;
            tx_tv_usec     <= {12'd0, usec};
            tx_state       <= S_TX_CSUM;
          end
        end
        S_TX_CSUM: begin
          tx_csum  <= ipv4_header_checksum(8'h00, tx_len + IP_UDP_HDR_BYTES, tx_ident, 16'h0000, IPV4_TTL,
                                           IP_PROTO_UDP, tx_sip, tx_dip);
          tx_beat  <= '0;
          tx_state <= S_TX_BEAT;
        end
        S_TX_BEAT: begin
          if (!tx_valid || tx_ready) begin
            tx_data  <= beat_word;
            tx_keep  <= (tx_beat == tx_last_beat) ? tx_last_keep : 8'hFF;
            tx_last  <= (tx_beat == tx_last_beat);
            tx_valid <= 1'b1;
            tx_beat  <= tx_beat + 1'b1;
            if (tx_beat == tx_last_beat) tx_state <= S_TX_IDLE;
          end
        end
        default: begin
          tx_state <= S_TX_IDLE;
        end
      endcase
      if (ev_rv_start) begin                                  // a new stream: counters, bucket, no owed ending
        stream_seq     <= 64'd0;
        v_tx_dgrams    <= 32'd0;
        rv_fin_pending <= 1'b0;
        credit         <= 40'({rvq_len, 3'b000, 16'd0});
      end
      if (!enable) begin
        report_pending <= 1'b0;
        rv_fin_pending <= 1'b0;
      end
      if (cnt_clear) begin
        v_tx_dgrams <= 32'd0;
        v_reports   <= 32'd0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Beat contents (frame byte 8k+n in lane n). Header beats 0-4: Ethernet,
  // IPv4 (TTL 64, flags 0), UDP (checksum 0 = none). Report payload (bytes
  // 42-169): 16 zero bytes, flags@58, total_len1@62, total_len2@66,
  // stop_sec@70, stop_usec@74, error_cnt@78, outorder_cnt@82, datagrams@86,
  // jitter1@90, jitter2@94, zero to 169. Stream payload: id@42, tv_sec@46,
  // tv_usec@50, id2@54, zero to the end.
  // ---------------------------------------------------------------------------
  function automatic logic [63:0] pack8(input logic [7:0] b0, input logic [7:0] b1, input logic [7:0] b2,
                                        input logic [7:0] b3, input logic [7:0] b4, input logic [7:0] b5,
                                        input logic [7:0] b6, input logic [7:0] b7);
    return {b7, b6, b5, b4, b3, b2, b1, b0};
  endfunction

  logic [15:0] tx_ip_len;
  logic [15:0] tx_udp_len;
  logic [31:0] r_len1;
  logic [31:0] r_len2;

  assign tx_ip_len  = tx_len + IP_UDP_HDR_BYTES;
  assign tx_udp_len = tx_len + UDP_HDR_BYTES;
  assign r_len1     = tx_r_bytes[63:32];
  assign r_len2     = tx_r_bytes[31:0];

  always_comb begin
    beat_word = 64'd0;
    case (int'(tx_beat))
      0:             beat_word = pack8(tx_dmac[47:40], tx_dmac[39:32], tx_dmac[31:24], tx_dmac[23:16],
                                       tx_dmac[15:8], tx_dmac[7:0], tx_smac[47:40], tx_smac[39:32]);
      1:             beat_word = pack8(tx_smac[31:24], tx_smac[23:16], tx_smac[15:8], tx_smac[7:0],
                                       ETHERTYPE_IPV4[15:8], ETHERTYPE_IPV4[7:0], IPV4_VER_IHL5, 8'h00);
      2:             beat_word = pack8(tx_ip_len[15:8], tx_ip_len[7:0], tx_ident[15:8], tx_ident[7:0],
                                       8'h00, 8'h00, IPV4_TTL, IP_PROTO_UDP);
      3:             beat_word = pack8(tx_csum[15:8], tx_csum[7:0], tx_sip[31:24], tx_sip[23:16],
                                       tx_sip[15:8], tx_sip[7:0], tx_dip[31:24], tx_dip[23:16]);
      4:             beat_word = pack8(tx_dip[15:8], tx_dip[7:0], tx_sport[15:8], tx_sport[7:0],
                                       tx_dport[15:8], tx_dport[7:0], tx_udp_len[15:8], tx_udp_len[7:0]);
      5:             beat_word = tx_is_report ? 64'd0 :
                                 pack8(8'h00, 8'h00, tx_seq[31:24], tx_seq[23:16], tx_seq[15:8], tx_seq[7:0],
                                       tx_tv_sec[31:24], tx_tv_sec[23:16]);
      6:             beat_word = tx_is_report ? 64'd0 :
                                 pack8(tx_tv_sec[15:8], tx_tv_sec[7:0], tx_tv_usec[31:24], tx_tv_usec[23:16],
                                       tx_tv_usec[15:8], tx_tv_usec[7:0], tx_seq[63:56], tx_seq[55:48]);
      7:             beat_word = tx_is_report ?
                                 pack8(8'h00, 8'h00, REPORT_FLAGS[31:24], REPORT_FLAGS[23:16], REPORT_FLAGS[15:8],
                                       REPORT_FLAGS[7:0], r_len1[31:24], r_len1[23:16]) :
                                 pack8(tx_seq[47:40], tx_seq[39:32], 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);
      8:             if (tx_is_report)
                       beat_word = pack8(r_len1[15:8], r_len1[7:0], r_len2[31:24], r_len2[23:16], r_len2[15:8],
                                         r_len2[7:0], tx_r_stop_sec[31:24], tx_r_stop_sec[23:16]);
      9:             if (tx_is_report)
                       beat_word = pack8(tx_r_stop_sec[15:8], tx_r_stop_sec[7:0], tx_r_stop_usec[31:24],
                                         tx_r_stop_usec[23:16], tx_r_stop_usec[15:8], tx_r_stop_usec[7:0],
                                         tx_r_lost[31:24], tx_r_lost[23:16]);
      10:             if (tx_is_report)
                        beat_word = pack8(tx_r_lost[15:8], tx_r_lost[7:0], tx_r_ooo[31:24], tx_r_ooo[23:16],
                                          tx_r_ooo[15:8], tx_r_ooo[7:0], tx_r_dgrams[31:24], tx_r_dgrams[23:16]);
      11:             if (tx_is_report)
                        beat_word = pack8(tx_r_dgrams[15:8], tx_r_dgrams[7:0], tx_r_jitter1[31:24],
                                          tx_r_jitter1[23:16], tx_r_jitter1[15:8], tx_r_jitter1[7:0],
                                          tx_r_jitter2[31:24], tx_r_jitter2[23:16]);
      12:             if (tx_is_report)
                        beat_word = pack8(tx_r_jitter2[15:8], tx_r_jitter2[7:0], 8'h00, 8'h00, 8'h00, 8'h00,
                                          8'h00, 8'h00);
      default: beat_word = 64'd0;
    endcase
  end

  // Output register slice: its registered outputs are m_axis_*.
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

  // synthesis translate_off
  // Simulation-only visibility of a broken wrapper rule (the frame is skipped).
  always @(posedge clk) begin
    if (resetn && s_axis_tvalid && (cap_state == S_CAP_IDLE) && enable && ((ac_state != S_AC_IDLE) || rx_done))
      $warning("rtlnet_iperf: a frame started while the accounting runs (state %0d); skipped", ac_state);
  end
  // synthesis translate_on

endmodule
