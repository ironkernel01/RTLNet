// -----------------------------------------------------------------------------
// File: rtlnet_dhcp.sv
// Purpose: RTLNet DHCP client leaf (RFC 2131, RFC 2132). Obtains an IPv4 lease
//   with DISCOVER / OFFER / REQUEST / ACK, holds it, renews it at T1, drops it
//   on expiry, on a DHCPNAK while renewing or on a STOP command, and releases
//   it with a DHCPRELEASE on STOP. Firmware controls it through the leaf's
//   register port; the lease leaves on registered level outputs that the
//   protocol wrapper turns into the node's effective address.
// Overview:
//   * Leaf contract (documentation/rtlnet_architecture.md 7.5, 15.4): proto_clk,
//     s_axis_tready held 1, replies through one rtlnet_axis_reg_slice, busy
//     registered, enable gates receive and transmit, 12-bit register port with
//     read data one clock after reg_rd_en.
//   * Three machines, each one registered state variable in one clocked process
//     with a recovering default:
//       client   S_INIT, S_SELECTING, S_REQUESTING, S_BOUND, S_RENEWING, S_FAIL
//                (RFC 2131 4.4, Figure 5); the code is STATUS[2:0].
//       receive  S_RX_IDLE, S_RX_HDR, S_RX_TAIL, S_RX_END, S_OPT_CODE,
//                S_OPT_LEN, S_OPT_DATA, S_RX_DONE: header checks beat by beat
//                while the frame is written to the receive RAM, then an option
//                walk over the RAM (RFC 2132 2), two clocks per option byte.
//       transmit S_TX_IDLE, S_TX_CSUM, S_TX_BEAT: one 342-byte frame (43 beats)
//                built from a descriptor snapshot.
//   * Accepted frame (all must hold, otherwise ignored with no effect): client
//     state expects a reply (SELECTING, REQUESTING, RENEWING), leaf enabled,
//     Ethernet destination local MAC or broadcast, EtherType 0x0800, IPv4
//     version/IHL 0x45, MF = 0 and fragment offset 0, protocol 17, UDP 67 -> 68,
//     BOOTP op 2, chaddr = local MAC, magic cookie 99.130.83.99 at bytes
//     278-281, frame no longer than the RAM, IP total length inside the frame,
//     an end option inside the IP datagram, no option running past it, option
//     53 present; and at the end of the walk xid = the client's current xid.
//     IP destination and the IP/UDP checksums are not checked (the MAC's FCS
//     covers the frame).
//   * Option walk: bounded by the last byte of the IP datagram (14 + IP total
//     length - 1), never by the RAM size or the Ethernet padding. 0 pad, 255
//     end, otherwise code, length, data. Taken: 53 (first data byte), 54, 51,
//     1, 3 (first four data bytes, first byte most significant, when the length
//     is at least 4); every other option is skipped by its length; a repeated
//     option replaces the earlier one.
//   * Lease outputs change only on a binding ACK (load) or a lease loss (clear
//     to 0). lease_valid falls on expiry (any state), a DHCPNAK while RENEWING,
//     or STOP. START restarts the acquisition and keeps a held lease running.
//   * Transmitted frames, 342 bytes: DISCOVER, selecting REQUEST (options 50 and
//     54), renewing REQUEST (broadcast, ciaddr and IP source = lease), RELEASE
//     (unicast to the server MAC of the binding ACK, IP destination = server,
//     options 53 = 7, 61, 54). Byte map: cores/rtlnet_dhcp/documentation.
//   * RFC 2131 deviations (documented in the core guide): S_FAIL after
//     MAX_TRIES; no INIT-REBOOT, no REBINDING state, no T2; the renewal is the
//     broadcast form from T1 to expiry; T1 = lease/2 (options 58, 59 not
//     read); no DECLINE or ARP probe; first OFFER taken; retransmission start
//     OFFER_TIMEOUT_MS, doubled, capped at RETRY_CAP_MS, not randomised; secs
//     field 0; a lease below LEASE_MIN_S is raised to LEASE_MIN_S; a missing
//     option 51 gives 3600 s; timing from the ACK, not the REQUEST.
//   * local_ip (the wrapper's effective address) is not used: the frames take
//     0.0.0.0 or the leaf's own lease_ip, which is the effective address while
//     lease_valid.
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk = proto_clk (50 MHz on the Nexys Video, MS_CYCLES clocks per
//   millisecond); resetn synchronous, active low. No crossings.
// -----------------------------------------------------------------------------
module rtlnet_dhcp #(
  parameter int    MS_CYCLES        = 50_000,   // proto_clk cycles per millisecond
  parameter int    DHCP_BUF_KB      = 1,        // receive RAM, KiB (1, 2, 4, 8, 16); 1 KiB holds a 590-byte message
  parameter string RAM_STYLE        = "block",  // "block" | "distributed"
  parameter int    OFFER_TIMEOUT_MS = 4000,     // first retransmission wait (RFC 2131 4.1: 4 s)
  parameter int    RETRY_CAP_MS     = 64000,    // backoff ceiling (RFC 2131 4.1: 64 s)
  parameter int    MAX_TRIES        = 5,        // sends per phase (and NAKs per acquisition) before S_FAIL
  parameter int    RENEW_RETRY_S    = 60,       // seconds between renewal REQUESTs
  parameter int    LEASE_MIN_S      = 10        // shortest lease accepted (raised to this)
)(
  // Clock and reset: proto_clk, synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Leaf enable from the wrapper's leaf-enable register (proto_clk level):
  // 0 = ignore every frame and send nothing (timers and commands still run).
  input  logic        enable,

  // Frame in, RTLNet stream (proto_clk): every frame of the wrapper's fan-out,
  // byte 0 in tdata[7:0], no FCS, padding kept. s_axis_tready is held 1.
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // Frame out, RTLNet stream (proto_clk): 342-byte DHCP frames, the registered
  // outputs of one rtlnet_axis_reg_slice; a started frame has no gaps.
  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  // Node address from the wrapper (proto_clk registers): MAC octet 0 in
  // [47:40]; local_ip is the effective address (unused, see header).
  input  logic [47:0] local_mac,
  input  logic [31:0] local_ip,

  // Leaf status (registered): high while a captured frame is received or
  // parsed and for the clock after the last beat of any frame.
  output logic        busy,

  // Register port (proto_clk), the wrapper's internal register bus: one-clock
  // write strobe; read data valid the clock after reg_rd_en and held.
  input  logic        reg_wr_en,
  input  logic [11:0] reg_wr_addr,
  input  logic [31:0] reg_wr_data,
  input  logic        reg_rd_en,
  input  logic [11:0] reg_rd_addr,
  output logic [31:0] reg_rd_data,

  // Lease result (proto_clk, registered): first octet in [31:24]; change only
  // on a binding ACK or a lease loss. lease_time_s 0xFFFFFFFF = infinite.
  output logic        lease_valid,
  output logic [31:0] lease_ip,
  output logic [31:0] lease_mask,
  output logic [31:0] lease_router,
  output logic [31:0] lease_server,
  output logic [31:0] lease_time_s
);

  import rtlnet_pkg::*;

  // ---------------------------------------------------------------------------
  // Register map: mirrors cores/rtlnet_dhcp/driver/rtlnet_dhcp.h (keep in step).
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID              = 12'h000;
  localparam logic [11:0] REG_VERSION         = 12'h004;
  localparam logic [11:0] REG_CAPS            = 12'h008;
  localparam logic [11:0] REG_CTRL            = 12'h00C;
  localparam logic [11:0] REG_STATUS          = 12'h010;
  localparam logic [11:0] REG_LEASE_IP        = 12'h014;
  localparam logic [11:0] REG_LEASE_MASK      = 12'h018;
  localparam logic [11:0] REG_LEASE_ROUTER    = 12'h01C;
  localparam logic [11:0] REG_LEASE_SERVER    = 12'h020;
  localparam logic [11:0] REG_LEASE_TIME_S    = 12'h024;
  localparam logic [11:0] REG_LEASE_ELAPSED_S = 12'h028;
  localparam logic [11:0] REG_XID             = 12'h02C;
  localparam logic [11:0] REG_DISCOVERS_SENT  = 12'h030;
  localparam logic [11:0] REG_OFFERS_RX       = 12'h034;
  localparam logic [11:0] REG_REQUESTS_SENT   = 12'h038;
  localparam logic [11:0] REG_ACKS_RX         = 12'h03C;
  localparam logic [11:0] REG_NAKS_RX         = 12'h040;
  localparam logic [11:0] REG_LEASES_LOST     = 12'h044;
  localparam logic [11:0] REG_RELEASES_SENT   = 12'h048;
  localparam logic [31:0] ID_VALUE            = 32'h4448_4350;   // "DHCP"
  localparam logic [31:0] VERSION_VALUE       = 32'h1022_2026;
  localparam int          CTRL_START_BIT      = 0;
  localparam int          CTRL_STOP_BIT       = 1;
  localparam int          CTRL_AUTO_BIT       = 2;
  localparam int          CTRL_RENEW_BIT      = 3;
  localparam int          CTRL_CNT_CLEAR_BIT  = 16;

  // ---------------------------------------------------------------------------
  // Sizes and protocol constants.
  // ---------------------------------------------------------------------------
  localparam int BUF_WORDS = DHCP_BUF_KB * 128;                  // 64-bit words
  localparam int ADDR_W    = clog2i(BUF_WORDS);
  localparam int MSW       = clog2i(MS_CYCLES);
  localparam logic [ADDR_W:0] BEAT_FULL = BUF_WORDS;             // rx_beat value past the last RAM word
  localparam int POS_W     = 17;                                  // byte positions and bounds

  localparam logic [15:0] IP_FRAG_MASK      = 16'h3FFF;          // RFC 791 3.1: MF + offset, DF ignored
  localparam logic [15:0] PORT_BOOTPS       = 16'd67;            // RFC 2131 4.1
  localparam logic [15:0] PORT_BOOTPC       = 16'd68;
  localparam logic [15:0] TX_IP_TOTAL_LEN   = 16'd328;           // 20 IP + 8 UDP + 300 BOOTP
  localparam logic [15:0] TX_UDP_LEN        = 16'd308;
  localparam logic [31:0] IP_LIMITED_BCAST  = 32'hFFFF_FFFF;
  localparam logic [47:0] MAC_BCAST         = 48'hFFFF_FFFF_FFFF;
  localparam logic [7:0]  BOOTP_OP_REQUEST  = 8'd1;              // RFC 2131 2, Table 1
  localparam logic [7:0]  BOOTP_OP_REPLY    = 8'd2;
  localparam logic [7:0]  BOOTP_HTYPE_ETH   = 8'd1;
  localparam logic [7:0]  BOOTP_HLEN_ETH    = 8'd6;
  localparam logic [7:0]  FLAGS_BROADCAST   = 8'h80;             // RFC 2131 2, Figure 2 (byte 52)
  localparam logic [31:0] MAGIC_COOKIE      = 32'h6382_5363;     // RFC 2132 2
  localparam logic [7:0]  OPT_PAD           = 8'd0;              // RFC 2132 3.1
  localparam logic [7:0]  OPT_SUBNET_MASK   = 8'd1;              // RFC 2132 3.3
  localparam logic [7:0]  OPT_ROUTER        = 8'd3;              // RFC 2132 3.5
  localparam logic [7:0]  OPT_DNS           = 8'd6;              // RFC 2132 3.8 (requested only)
  localparam logic [7:0]  OPT_REQUESTED_IP  = 8'd50;             // RFC 2132 9.1
  localparam logic [7:0]  OPT_LEASE_TIME    = 8'd51;             // RFC 2132 9.2
  localparam logic [7:0]  OPT_MSG_TYPE      = 8'd53;             // RFC 2132 9.6
  localparam logic [7:0]  OPT_SERVER_ID     = 8'd54;             // RFC 2132 9.7
  localparam logic [7:0]  OPT_PARAM_LIST    = 8'd55;             // RFC 2132 9.8
  localparam logic [7:0]  OPT_CLIENT_ID     = 8'd61;             // RFC 2132 9.14
  localparam logic [7:0]  OPT_END           = 8'd255;            // RFC 2132 3.2
  localparam logic [7:0]  OPT_LEN_ADDR      = 8'd4;
  localparam logic [7:0]  OPT_LEN_TYPE      = 8'd1;
  localparam logic [7:0]  OPT_LEN_CLIENT_ID = 8'd7;
  localparam logic [7:0]  OPT_LEN_PARAMS    = 8'd4;
  localparam logic [7:0]  DHCPDISCOVER      = 8'd1;              // RFC 2132 9.6
  localparam logic [7:0]  DHCPOFFER         = 8'd2;
  localparam logic [7:0]  DHCPREQUEST       = 8'd3;
  localparam logic [7:0]  DHCPACK           = 8'd5;
  localparam logic [7:0]  DHCPNAK           = 8'd6;
  localparam logic [7:0]  DHCPRELEASE       = 8'd7;

  localparam logic [POS_W-1:0] OPT_FIRST_BYTE = 17'd282;         // first option byte after the cookie
  localparam logic [POS_W-1:0] ETH_HDR_BYTES  = 17'd14;
  localparam int          RX_BEAT_ETHTYPE   = 1;                  // beat index of each checked region
  localparam int          RX_BEAT_FRAG      = 2;
  localparam int          RX_BEAT_PORTS     = 4;
  localparam int          RX_BEAT_OP_XID    = 5;
  localparam int          RX_BEAT_XID_LO    = 6;
  localparam int          RX_BEAT_YIADDR    = 7;
  localparam int          RX_BEAT_CHADDR_A  = 8;
  localparam int          RX_BEAT_CHADDR_B  = 9;
  localparam int          RX_BEAT_COOKIE_A  = 34;                 // bytes 272-279
  localparam int          RX_BEAT_COOKIE_B  = 35;                 // bytes 280-287
  localparam logic [5:0]  TX_BEAT_LAST      = 6'd42;              // 342 bytes = 43 beats
  localparam logic [7:0]  TX_KEEP_LAST      = 8'h3F;              // 342 mod 8 = 6

  localparam logic [31:0] LEASE_DEFAULT_S   = 32'd3600;           // option 51 missing
  localparam logic [31:0] LEASE_INFINITE    = 32'hFFFF_FFFF;      // RFC 2131 3.3
  localparam logic [31:0] LEASE_MIN         = LEASE_MIN_S;
  localparam logic [15:0] FIRST_WAIT_MS     = OFFER_TIMEOUT_MS;
  localparam logic [15:0] WAIT_CAP_MS       = RETRY_CAP_MS;
  localparam logic [15:0] RENEW_RETRY       = RENEW_RETRY_S;
  localparam logic [3:0]  TRIES_MAX         = MAX_TRIES;
  localparam logic [3:0]  NAKS_LAST         = MAX_TRIES - 1;
  localparam logic [9:0]  MS_PER_S_LAST     = 10'd999;
  localparam logic [MSW-1:0] MS_LAST        = MS_CYCLES - 1;
  localparam logic [31:0] CAPS_VALUE        = {15'd0, 1'b1, 4'd0, TRIES_MAX, 8'(DHCP_BUF_KB)};

  // Client states (STATUS[2:0] codes, rtlnet_dhcp.h RTLNET_DHCP_STATE_*).
  localparam logic [2:0] S_INIT       = 3'd0;
  localparam logic [2:0] S_SELECTING  = 3'd1;
  localparam logic [2:0] S_REQUESTING = 3'd2;
  localparam logic [2:0] S_BOUND      = 3'd3;
  localparam logic [2:0] S_RENEWING   = 3'd4;
  localparam logic [2:0] S_FAIL       = 3'd5;

  // Receive machine states.
  localparam logic [2:0] S_RX_IDLE  = 3'd0;
  localparam logic [2:0] S_RX_HDR   = 3'd1;
  localparam logic [2:0] S_RX_TAIL  = 3'd2;
  localparam logic [2:0] S_RX_END   = 3'd3;
  localparam logic [2:0] S_OPT_CODE = 3'd4;
  localparam logic [2:0] S_OPT_LEN  = 3'd5;
  localparam logic [2:0] S_OPT_DATA = 3'd6;
  localparam logic [2:0] S_RX_DONE  = 3'd7;

  // Transmit machine states and frame kinds.
  localparam logic [1:0] S_TX_IDLE  = 2'd0;
  localparam logic [1:0] S_TX_CSUM  = 2'd1;
  localparam logic [1:0] S_TX_BEAT  = 2'd2;
  localparam logic [1:0] K_DISCOVER = 2'd0;                       // RFC 2131 3.1 step 1
  localparam logic [1:0] K_REQ_SEL  = 2'd1;                       // 3.1 step 3: options 50, 54
  localparam logic [1:0] K_REQ_REN  = 2'd2;                       // 4.4.5: ciaddr = lease, broadcast
  localparam logic [1:0] K_RELEASE  = 2'd3;                       // 4.4.6: unicast to the server

  // Parameter legality: stops synthesis and simulation alike.
  generate
    if (DHCP_BUF_KB != 1 && DHCP_BUF_KB != 2 && DHCP_BUF_KB != 4 && DHCP_BUF_KB != 8 && DHCP_BUF_KB != 16)
    begin : g_bad_buf
      $fatal(1, "rtlnet_dhcp: DHCP_BUF_KB=%0d, must be 1, 2, 4, 8 or 16", DHCP_BUF_KB);
    end
    if (MS_CYCLES < 8) begin : g_bad_ms
      $fatal(1, "rtlnet_dhcp: MS_CYCLES=%0d, must be at least 8", MS_CYCLES);
    end
    if (OFFER_TIMEOUT_MS < 1 || OFFER_TIMEOUT_MS > RETRY_CAP_MS || RETRY_CAP_MS > 65535) begin : g_bad_wait
      $fatal(1, "rtlnet_dhcp: need 1 <= OFFER_TIMEOUT_MS <= RETRY_CAP_MS <= 65535");
    end
    if (MAX_TRIES < 1 || MAX_TRIES > 15) begin : g_bad_tries
      $fatal(1, "rtlnet_dhcp: MAX_TRIES=%0d, must be 1..15", MAX_TRIES);
    end
    if (RENEW_RETRY_S < 1 || RENEW_RETRY_S > 65535) begin : g_bad_renew
      $fatal(1, "rtlnet_dhcp: RENEW_RETRY_S=%0d, must be 1..65535", RENEW_RETRY_S);
    end
    if (LEASE_MIN_S < 2) begin : g_bad_lease_min
      $fatal(1, "rtlnet_dhcp: LEASE_MIN_S=%0d, must be at least 2 (T1 >= 1 s)", LEASE_MIN_S);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Signals, by block.
  // ---------------------------------------------------------------------------
  // Register file.
  logic              cmd_start;            // one-clock command pulses from CTRL
  logic              cmd_stop;
  logic              cmd_renew;
  logic              cnt_clear;
  logic              auto_flag;
  logic [31:0]       rd_mux;

  // Counters.
  logic [31:0]       cnt_discovers;
  logic [31:0]       cnt_offers;
  logic [31:0]       cnt_requests;
  logic [31:0]       cnt_acks;
  logic [31:0]       cnt_naks;
  logic [31:0]       cnt_lost;
  logic [31:0]       cnt_releases;

  // Time base.
  logic [MSW-1:0]    ms_count;
  logic              ms_tick;
  logic [9:0]        ms_of_s;
  logic              s_tick;
  logic              s_restart;            // the binding ACK restarts the second count

  // Client machine.
  logic [2:0]        cl_state;
  logic              fail;
  logic [31:0]       xid_ctr;              // free-running, sampled for each new xid
  logic [31:0]       xid;
  logic [31:0]       offered_ip;           // yiaddr of the OFFER taken
  logic [31:0]       offer_server;         // option 54 of the OFFER taken
  logic [47:0]       server_mac;           // Ethernet source of the binding ACK
  logic [3:0]        tries;
  logic [3:0]        naks_seen;
  logic [15:0]       wait_ms;
  logic [15:0]       limit_ms;
  logic [15:0]       renew_wait_s;
  logic [31:0]       lease_elapsed_s;
  logic              tx_req;               // one clock: send one frame described by req_*
  logic [1:0]        req_kind;
  logic [31:0]       req_ciaddr;
  logic [31:0]       req_ip;
  logic [31:0]       req_server;
  logic [47:0]       req_dmac;

  // Frame tracker and receive machine.
  logic              in_frame;             // between a first beat and its last beat
  logic [2:0]        rx_state;
  logic [ADDR_W:0]   rx_beat;              // beat index on the bus; BUF_WORDS = past the RAM (saturated)
  logic              rx_over;              // a beat fell past the RAM
  logic [15:0]       rx_ip_len;            // IPv4 total length
  logic [POS_W-1:0]  rx_frame_last;        // index of the last frame byte
  logic [POS_W-1:0]  rx_bound;             // index of the last byte of the IP datagram
  logic [47:0]       rx_src_mac;
  logic [31:0]       rx_xid;
  logic [31:0]       rx_yiaddr;
  logic [7:0]        rx_type;
  logic              rx_has_type;
  logic [31:0]       rx_server;
  logic              rx_has_server;
  logic [31:0]       rx_lease;
  logic              rx_has_lease;
  logic [31:0]       rx_mask;
  logic [31:0]       rx_router;
  logic              rx_msg_valid;         // one clock: a parsed message for the client
  logic              frame_end;            // one clock after any frame's last beat

  // Receive RAM and option walk.
  logic              ram_wr_en;
  logic [ADDR_W-1:0] ram_wr_addr;
  logic [63:0]       ram_wr_data;
  logic [63:0]       ram_rd_data;
  logic [POS_W-1:0]  opt_pos;              // frame byte read by the walk
  logic              opt_rdy;              // ram_rd_data holds the word of opt_pos
  logic [7:0]        opt_code;
  logic [POS_W-1:0]  opt_next;
  logic [2:0]        opt_left;
  logic [31:0]       opt_value;

  // Transmit machine.
  logic [1:0]        tx_state;
  logic              tx_pending;
  logic [5:0]        tx_beat;
  logic [15:0]       ip_ident;
  logic [1:0]        tx_kind;
  logic [47:0]       tx_smac;
  logic [47:0]       tx_dmac;
  logic [31:0]       tx_sip;
  logic [31:0]       tx_dip;
  logic [31:0]       tx_xid;
  logic [15:0]       tx_ident;
  logic [31:0]       tx_ciaddr;
  logic [31:0]       tx_req_ip;
  logic [31:0]       tx_server;
  logic [15:0]       tx_csum;
  logic [63:0]       tx_data;
  logic [7:0]        tx_keep;
  logic              tx_last;
  logic              tx_valid;
  logic              tx_ready;
  logic [63:0]       beat_word;

  // ---------------------------------------------------------------------------
  // Named conditions.
  // ---------------------------------------------------------------------------
  logic        first_beat;
  logic        expects_reply;
  logic        dst_ok;
  logic        beat_ok;
  logic [3:0]  last_lane_bytes;
  logic [POS_W-1:0] frame_last_now;
  logic [POS_W-1:0] ip_last_byte;
  logic [7:0]  opt_byte;
  logic [POS_W-1:0] opt_last_data;
  logic        opt_want_type;
  logic        opt_want_word;
  logic        msg_ok;
  logic        got_offer;
  logic        got_ack;
  logic        got_nak;
  logic        in_wait;
  logic        timeout_due;
  logic        lease_infinite;
  logic        t1_due;
  logic        lease_expired;
  logic        ack_binds;
  logic        lease_lost;
  logic        restart;
  logic [15:0] next_limit;
  logic [31:0] new_xid;
  logic [31:0] lease_take;
  logic [31:0] rx_lease_eff;

  assign s_axis_tready = 1'b1;
  assign first_beat    = s_axis_tvalid && !in_frame;
  assign expects_reply = (cl_state == S_SELECTING) || (cl_state == S_REQUESTING) || (cl_state == S_RENEWING);
  assign dst_ok        = (be48(s_axis_tdata[47:0]) == local_mac) || (s_axis_tdata[47:0] == MAC_BCAST);
  assign last_lane_bytes = keep_bytes(s_axis_tkeep);
  assign frame_last_now  = {rx_beat, 3'b000} + {13'd0, last_lane_bytes} - 17'd1;
  assign ip_last_byte    = ETH_HDR_BYTES + {1'b0, rx_ip_len} - 17'd1;

  // Per-beat header rule (bus order: frame byte 8k+n is tdata[8n+7:8n]).
  always_comb begin
    beat_ok = 1'b1;
    case (rx_beat)
      RX_BEAT_ETHTYPE:  beat_ok = (be16(s_axis_tdata[47:32]) == ETHERTYPE_IPV4) && (s_axis_tdata[55:48] == IPV4_VER_IHL5);
      RX_BEAT_FRAG:     beat_ok = ((be16(s_axis_tdata[47:32]) & IP_FRAG_MASK) == 16'd0) &&
                                  (s_axis_tdata[63:56] == IP_PROTO_UDP);
      RX_BEAT_PORTS:    beat_ok = (be16(s_axis_tdata[31:16]) == PORT_BOOTPS) && (be16(s_axis_tdata[47:32]) == PORT_BOOTPC);
      RX_BEAT_OP_XID:   beat_ok = (s_axis_tdata[23:16] == BOOTP_OP_REPLY);
      RX_BEAT_CHADDR_A: beat_ok = (be16(s_axis_tdata[63:48]) == local_mac[47:32]);
      RX_BEAT_CHADDR_B: beat_ok = (be32(s_axis_tdata[31:0]) == local_mac[31:0]);
      RX_BEAT_COOKIE_A: beat_ok = (be16(s_axis_tdata[63:48]) == MAGIC_COOKIE[31:16]);
      RX_BEAT_COOKIE_B: beat_ok = (be16(s_axis_tdata[15:0]) == MAGIC_COOKIE[15:0]);
      default:          beat_ok = 1'b1;
    endcase
  end

  assign opt_byte      = ram_rd_data[{opt_pos[2:0], 3'b000} +: 8];
  assign opt_last_data = opt_pos + {9'd0, opt_byte};
  assign opt_want_type = (opt_code == OPT_MSG_TYPE) && (opt_byte >= OPT_LEN_TYPE);
  assign opt_want_word = ((opt_code == OPT_SERVER_ID) || (opt_code == OPT_LEASE_TIME) ||
                          (opt_code == OPT_SUBNET_MASK) || (opt_code == OPT_ROUTER)) && (opt_byte >= OPT_LEN_ADDR);

  assign msg_ok         = rx_msg_valid && (rx_xid == xid);
  assign got_offer      = msg_ok && (rx_type == DHCPOFFER) && rx_has_server;
  assign got_ack        = msg_ok && (rx_type == DHCPACK);
  assign got_nak        = msg_ok && (rx_type == DHCPNAK);
  assign in_wait        = (cl_state == S_SELECTING) || (cl_state == S_REQUESTING);
  assign timeout_due    = (wait_ms >= limit_ms);
  assign lease_infinite = (lease_time_s == LEASE_INFINITE);
  assign t1_due         = lease_valid && !lease_infinite && (lease_elapsed_s >= {1'b0, lease_time_s[31:1]});
  assign lease_expired  = lease_valid && !lease_infinite && (lease_elapsed_s >= lease_time_s);
  assign ack_binds      = got_ack && ((cl_state == S_REQUESTING) || (cl_state == S_RENEWING));
  // A held lease ends: expiry in any state, or a DHCPNAK while renewing (RFC 2131 4.4.5, 3.1 step 5).
  assign lease_lost     = lease_valid && !ack_binds && (lease_expired || ((cl_state == S_RENEWING) && got_nak));
  // A new acquisition: START, a DHCPNAK while requesting that is not the last allowed, or the end of
  // the lease / a DHCPNAK while renewing.
  assign restart        = cmd_start ||
                          ((cl_state == S_REQUESTING) && got_nak && (naks_seen != NAKS_LAST)) ||
                          ((cl_state == S_RENEWING) && !ack_binds && (got_nak || lease_expired));
  assign next_limit     = ({1'b0, limit_ms} + {1'b0, limit_ms} > {1'b0, WAIT_CAP_MS}) ? WAIT_CAP_MS : (limit_ms << 1);
  assign new_xid        = xid_ctr ^ local_mac[31:0];
  assign rx_lease_eff   = rx_has_lease ? rx_lease : LEASE_DEFAULT_S;
  assign lease_take     = (rx_lease_eff < LEASE_MIN) ? LEASE_MIN : rx_lease_eff;

  // ---------------------------------------------------------------------------
  // Register file: CTRL decodes into one-clock command pulses (pulse bits read
  // 0); the read mux is registered and loads only on reg_rd_en.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cmd_start <= 1'b0;
      cmd_stop  <= 1'b0;
      cmd_renew <= 1'b0;
      cnt_clear <= 1'b0;
      auto_flag <= 1'b0;
    end else begin
      cmd_start <= 1'b0;
      cmd_stop  <= 1'b0;
      cmd_renew <= 1'b0;
      cnt_clear <= 1'b0;
      if (reg_wr_en && (reg_wr_addr == REG_CTRL)) begin
        cmd_start <= reg_wr_data[CTRL_START_BIT];
        cmd_stop  <= reg_wr_data[CTRL_STOP_BIT];
        cmd_renew <= reg_wr_data[CTRL_RENEW_BIT];
        cnt_clear <= reg_wr_data[CTRL_CNT_CLEAR_BIT];
        auto_flag <= reg_wr_data[CTRL_AUTO_BIT];
      end
    end
  end

  always_comb begin
    case (reg_rd_addr)
      REG_ID:              rd_mux = ID_VALUE;
      REG_VERSION:         rd_mux = VERSION_VALUE;
      REG_CAPS:            rd_mux = CAPS_VALUE;
      REG_CTRL:            rd_mux = {29'd0, auto_flag, 2'b00};
      REG_STATUS:          rd_mux = {15'd0, enable, 6'd0, fail, lease_valid, 5'd0, cl_state};
      REG_LEASE_IP:        rd_mux = lease_ip;
      REG_LEASE_MASK:      rd_mux = lease_mask;
      REG_LEASE_ROUTER:    rd_mux = lease_router;
      REG_LEASE_SERVER:    rd_mux = lease_server;
      REG_LEASE_TIME_S:    rd_mux = lease_time_s;
      REG_LEASE_ELAPSED_S: rd_mux = lease_elapsed_s;
      REG_XID:             rd_mux = xid;
      REG_DISCOVERS_SENT:  rd_mux = cnt_discovers;
      REG_OFFERS_RX:       rd_mux = cnt_offers;
      REG_REQUESTS_SENT:   rd_mux = cnt_requests;
      REG_ACKS_RX:         rd_mux = cnt_acks;
      REG_NAKS_RX:         rd_mux = cnt_naks;
      REG_LEASES_LOST:     rd_mux = cnt_lost;
      REG_RELEASES_SENT:   rd_mux = cnt_releases;
      default:             rd_mux = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!resetn)        reg_rd_data <= 32'd0;
    else if (reg_rd_en) reg_rd_data <= rd_mux;
  end

  // ---------------------------------------------------------------------------
  // Time base: ms_tick every MS_CYCLES clocks (free-running); s_tick every 1000
  // ms counted from the last binding ACK, so T1 and expiry are whole seconds
  // from the ACK.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      ms_count <= '0;
      ms_tick  <= 1'b0;
      ms_of_s  <= 10'd0;
      s_tick   <= 1'b0;
    end else begin
      ms_tick <= (ms_count == MS_LAST);
      s_tick  <= 1'b0;
      if (ms_count == MS_LAST) ms_count <= '0;
      else                     ms_count <= ms_count + 1'b1;
      if (s_restart) begin
        ms_of_s <= 10'd0;
      end else if (ms_tick) begin
        if (ms_of_s == MS_PER_S_LAST) begin
          ms_of_s <= 10'd0;
          s_tick  <= 1'b1;
        end else begin
          ms_of_s <= ms_of_s + 10'd1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Client machine (RFC 2131 4.4, Figure 5). Priority each clock: reset, STOP,
  // a restart (START, NAK, lease end while renewing), a binding ACK, then the
  // state's own rule. A lease loss (expiry anywhere, NAK while renewing) is
  // applied in parallel. Every timer is cleared in the assignment that makes
  // its transition, so no event fires twice. Frame requests set req_* and
  // tx_req in the same clock.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cl_state        <= S_INIT;
      fail            <= 1'b0;
      xid_ctr         <= 32'd0;
      xid             <= 32'd0;
      offered_ip      <= 32'd0;
      offer_server    <= 32'd0;
      server_mac      <= 48'd0;
      tries           <= 4'd0;
      naks_seen       <= 4'd0;
      wait_ms         <= 16'd0;
      limit_ms        <= FIRST_WAIT_MS;
      renew_wait_s    <= 16'd0;
      lease_elapsed_s <= 32'd0;
      s_restart       <= 1'b0;
      tx_req          <= 1'b0;
      req_kind        <= K_DISCOVER;
      req_ciaddr      <= 32'd0;
      req_ip          <= 32'd0;
      req_server      <= 32'd0;
      req_dmac        <= MAC_BCAST;
      lease_valid     <= 1'b0;
      lease_ip        <= 32'd0;
      lease_mask      <= 32'd0;
      lease_router    <= 32'd0;
      lease_server    <= 32'd0;
      lease_time_s    <= 32'd0;
      cnt_offers      <= 32'd0;
      cnt_acks        <= 32'd0;
      cnt_naks        <= 32'd0;
      cnt_lost        <= 32'd0;
    end else begin
      xid_ctr   <= xid_ctr + 32'd1;
      tx_req    <= 1'b0;
      s_restart <= 1'b0;
      if (ms_tick && in_wait && (wait_ms != 16'hFFFF)) wait_ms <= wait_ms + 16'd1;
      if (s_tick && (cl_state == S_RENEWING) && (renew_wait_s != 16'hFFFF)) renew_wait_s <= renew_wait_s + 16'd1;
      if (s_tick && lease_valid && (lease_elapsed_s != 32'hFFFF_FFFF)) lease_elapsed_s <= lease_elapsed_s + 32'd1;

      // Lease loss, in parallel with the state rules below.
      if (lease_lost) begin
        lease_valid  <= 1'b0;
        lease_ip     <= 32'd0;
        lease_mask   <= 32'd0;
        lease_router <= 32'd0;
        lease_server <= 32'd0;
        lease_time_s <= 32'd0;
        cnt_lost     <= cnt_lost + 32'd1;
      end

      if (cmd_stop) begin
        // Drop the lease; a held lease is released (RFC 2131 4.4.6) to the
        // server that granted it.
        if (lease_valid) begin
          tx_req     <= 1'b1;
          req_kind   <= K_RELEASE;
          req_ciaddr <= lease_ip;
          req_ip     <= 32'd0;
          req_server <= lease_server;
          req_dmac   <= server_mac;
          xid        <= new_xid;
        end
        lease_valid  <= 1'b0;
        lease_ip     <= 32'd0;
        lease_mask   <= 32'd0;
        lease_router <= 32'd0;
        lease_server <= 32'd0;
        lease_time_s <= 32'd0;
        fail         <= 1'b0;
        tries        <= 4'd0;
        naks_seen    <= 4'd0;
        wait_ms      <= 16'd0;
        cl_state     <= S_INIT;
      end else if (restart) begin
        // RFC 2131 3.1 step 1: a new xid and a broadcast DHCPDISCOVER.
        xid        <= new_xid;
        tx_req     <= 1'b1;
        req_kind   <= K_DISCOVER;
        req_ciaddr <= 32'd0;
        req_ip     <= 32'd0;
        req_server <= 32'd0;
        req_dmac   <= MAC_BCAST;
        limit_ms   <= FIRST_WAIT_MS;
        wait_ms    <= 16'd0;
        tries      <= 4'd1;
        fail       <= 1'b0;
        if (got_nak && !cmd_start) cnt_naks <= cnt_naks + 32'd1;
        if (cmd_start || (cl_state == S_RENEWING)) naks_seen <= 4'd0;
        else                                       naks_seen <= naks_seen + 4'd1;
        cl_state   <= S_SELECTING;
      end else if (ack_binds) begin
        // RFC 2131 3.1 step 5, 4.4.5: the lease starts; every output loads on
        // this edge and the second count restarts.
        lease_valid     <= 1'b1;
        lease_ip        <= rx_yiaddr;
        lease_mask      <= rx_mask;
        lease_router    <= rx_router;
        lease_server    <= rx_has_server ? rx_server : ((cl_state == S_RENEWING) ? lease_server : offer_server);
        lease_time_s    <= lease_take;
        server_mac      <= rx_src_mac;
        lease_elapsed_s <= 32'd0;
        s_restart       <= 1'b1;
        fail            <= 1'b0;
        cnt_acks        <= cnt_acks + 32'd1;
        cl_state        <= S_BOUND;
      end else begin
        case (cl_state)
          S_INIT: begin
          end
          S_SELECTING: begin
            // RFC 2131 3.1 step 2-3: take the first OFFER with a server
            // identifier, answer with the selecting REQUEST.
            if (got_offer) begin
              offered_ip   <= rx_yiaddr;
              offer_server <= rx_server;
              tx_req       <= 1'b1;
              req_kind     <= K_REQ_SEL;
              req_ciaddr   <= 32'd0;
              req_ip       <= rx_yiaddr;
              req_server   <= rx_server;
              req_dmac     <= MAC_BCAST;
              limit_ms     <= FIRST_WAIT_MS;
              wait_ms      <= 16'd0;
              tries        <= 4'd1;
              cnt_offers   <= cnt_offers + 32'd1;
              cl_state     <= S_REQUESTING;
            end else if (timeout_due) begin
              // RFC 2131 4.1: retransmit with a doubled wait; give up after MAX_TRIES sends.
              if (tries >= TRIES_MAX) begin
                fail     <= 1'b1;
                cl_state <= S_FAIL;
              end else begin
                tx_req   <= 1'b1;
                tries    <= tries + 4'd1;
                limit_ms <= next_limit;
                wait_ms  <= 16'd0;
              end
            end
          end
          S_REQUESTING: begin
            // ACK handled above; a NAK reaching here is the last one allowed.
            if (got_nak) begin
              cnt_naks <= cnt_naks + 32'd1;
              fail     <= 1'b1;
              cl_state <= S_FAIL;
            end else if (timeout_due) begin
              if (tries >= TRIES_MAX) begin
                fail     <= 1'b1;
                cl_state <= S_FAIL;
              end else begin
                tx_req   <= 1'b1;
                tries    <= tries + 4'd1;
                limit_ms <= next_limit;
                wait_ms  <= 16'd0;
              end
            end
          end
          S_BOUND: begin
            // RFC 2131 4.4.5: at T1 (lease/2), or on RENEW_NOW, extend the lease.
            if (t1_due || cmd_renew) begin
              xid          <= new_xid;
              tx_req       <= 1'b1;
              req_kind     <= K_REQ_REN;
              req_ciaddr   <= lease_ip;
              req_ip       <= 32'd0;
              req_server   <= 32'd0;
              req_dmac     <= MAC_BCAST;
              renew_wait_s <= 16'd0;
              cl_state     <= S_RENEWING;
            end
          end
          S_RENEWING: begin
            // ACK, NAK and the lease end are handled above; resend every RENEW_RETRY_S.
            if (renew_wait_s >= RENEW_RETRY) begin
              tx_req       <= 1'b1;
              renew_wait_s <= 16'd0;
            end
          end
          S_FAIL: begin
          end
          default: begin
            cl_state <= S_INIT;
          end
        endcase
      end

      if (cnt_clear) begin
        cnt_offers <= 32'd0;
        cnt_acks   <= 32'd0;
        cnt_naks   <= 32'd0;
        cnt_lost   <= 32'd0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Frame tracker: in_frame is 1 from a first beat to its last beat whatever the
  // receive machine does, so a frame that starts while the machine is busy is
  // skipped whole. frame_end pulses the clock after every last beat.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      in_frame  <= 1'b0;
      frame_end <= 1'b0;
    end else begin
      frame_end <= s_axis_tvalid && s_axis_tlast;
      if (s_axis_tvalid) in_frame <= !s_axis_tlast;
    end
  end

  // ---------------------------------------------------------------------------
  // Receive machine. S_RX_IDLE takes the first beat of a frame the client
  // expects; S_RX_HDR checks each header beat as it passes and writes every beat
  // to the RAM (registered write, one clock behind the bus); S_RX_TAIL takes the
  // rest; S_RX_END judges the lengths after the last write; the option walk
  // reads the RAM one byte per two clocks (opt_rdy); S_RX_DONE hands the verdict
  // to the client machine.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      rx_state      <= S_RX_IDLE;
      rx_beat       <= '0;
      rx_over       <= 1'b0;
      rx_ip_len     <= 16'd0;
      rx_frame_last <= '0;
      rx_bound      <= '0;
      rx_src_mac    <= 48'd0;
      rx_xid        <= 32'd0;
      rx_yiaddr     <= 32'd0;
      rx_type       <= 8'd0;
      rx_has_type   <= 1'b0;
      rx_server     <= 32'd0;
      rx_has_server <= 1'b0;
      rx_lease      <= 32'd0;
      rx_has_lease  <= 1'b0;
      rx_mask       <= 32'd0;
      rx_router     <= 32'd0;
      rx_msg_valid  <= 1'b0;
      ram_wr_en     <= 1'b0;
      ram_wr_addr   <= '0;
      ram_wr_data   <= 64'd0;
      opt_pos       <= '0;
      opt_rdy       <= 1'b0;
      opt_code      <= 8'd0;
      opt_next      <= '0;
      opt_left      <= 3'd0;
      opt_value     <= 32'd0;
    end else begin
      rx_msg_valid <= 1'b0;
      ram_wr_en    <= 1'b0;
      ram_wr_data  <= s_axis_tdata;
      ram_wr_addr  <= rx_beat[ADDR_W-1:0];
      opt_rdy      <= 1'b1;
      case (rx_state)
        S_RX_IDLE: begin                                   // bytes 0-7: destination, source octets 0-1
          rx_beat <= '0;
          rx_over <= 1'b0;
          if (first_beat && enable && expects_reply && dst_ok && !s_axis_tlast) begin
            ram_wr_en          <= 1'b1;
            ram_wr_addr        <= '0;
            rx_src_mac[47:32]  <= be16(s_axis_tdata[63:48]);
            rx_beat            <= {{ADDR_W{1'b0}}, 1'b1};
            rx_has_type        <= 1'b0;
            rx_has_server      <= 1'b0;
            rx_has_lease       <= 1'b0;
            rx_mask            <= 32'd0;
            rx_router          <= 32'd0;
            rx_state           <= S_RX_HDR;
          end
        end
        S_RX_HDR: begin                                    // beats 1-35: checked regions
          if (s_axis_tvalid) begin
            ram_wr_en <= 1'b1;
            rx_beat   <= rx_beat + 1'b1;
            case (rx_beat)
              RX_BEAT_ETHTYPE: rx_src_mac[31:0] <= be32(s_axis_tdata[31:0]);
              RX_BEAT_FRAG:    rx_ip_len        <= be16(s_axis_tdata[15:0]);
              RX_BEAT_OP_XID:  rx_xid[31:16]    <= be16(s_axis_tdata[63:48]);
              RX_BEAT_XID_LO:  rx_xid[15:0]     <= be16(s_axis_tdata[15:0]);
              RX_BEAT_YIADDR:  rx_yiaddr        <= be32(s_axis_tdata[47:16]);
              default: begin
              end
            endcase
            if (!beat_ok) begin
              rx_state <= S_RX_IDLE;                       // a failed rule: the rest is skipped
            end else if (s_axis_tlast) begin
              if (rx_beat == RX_BEAT_COOKIE_B) begin       // the options end inside beat 35
                rx_frame_last <= frame_last_now;
                rx_state      <= S_RX_END;
              end else begin
                rx_state <= S_RX_IDLE;                     // shorter than the cookie
              end
            end else if (rx_beat == RX_BEAT_COOKIE_B) begin
              rx_state <= S_RX_TAIL;
            end
          end
        end
        S_RX_TAIL: begin                                   // beats 36 to the last, while they fit
          if (s_axis_tvalid) begin
            if (rx_beat == BEAT_FULL) begin
              rx_over <= 1'b1;
            end else begin
              ram_wr_en <= 1'b1;
              rx_beat   <= rx_beat + 1'b1;
            end
            if (s_axis_tlast) begin
              rx_frame_last <= frame_last_now;
              rx_state      <= S_RX_END;
            end
          end
        end
        S_RX_END: begin                                    // the last word is written this clock
          rx_bound <= ip_last_byte;
          opt_pos  <= OPT_FIRST_BYTE;
          opt_rdy  <= 1'b0;
          if (rx_over || (ip_last_byte > rx_frame_last)) rx_state <= S_RX_IDLE;   // too long, or truncated
          else                                           rx_state <= S_OPT_CODE;
        end
        S_OPT_CODE: begin                                  // RFC 2132 2: code byte
          if (opt_rdy) begin
            if (opt_pos > rx_bound) begin                  // no end option inside the datagram
              rx_state <= S_RX_IDLE;
            end else if (opt_byte == OPT_END) begin        // RFC 2132 3.2
              rx_state <= S_RX_DONE;
            end else if (opt_byte == OPT_PAD) begin        // RFC 2132 3.1
              opt_pos <= opt_pos + 17'd1;
              opt_rdy <= 1'b0;
            end else begin
              opt_code <= opt_byte;
              opt_pos  <= opt_pos + 17'd1;
              opt_rdy  <= 1'b0;
              rx_state <= S_OPT_LEN;
            end
          end
        end
        S_OPT_LEN: begin                                   // length byte
          if (opt_rdy) begin
            if ((opt_pos > rx_bound) || (opt_last_data > rx_bound)) begin
              rx_state <= S_RX_IDLE;                       // runs past the datagram
            end else if (opt_want_type || opt_want_word) begin
              opt_next  <= opt_last_data + 17'd1;
              opt_left  <= opt_want_type ? 3'd1 : 3'd4;
              opt_value <= 32'd0;
              opt_pos   <= opt_pos + 17'd1;
              opt_rdy   <= 1'b0;
              rx_state  <= S_OPT_DATA;
            end else begin                                 // not wanted or too short: skip
              opt_pos  <= opt_last_data + 17'd1;
              opt_rdy  <= 1'b0;
              rx_state <= S_OPT_CODE;
            end
          end
        end
        S_OPT_DATA: begin                                  // first data bytes, most significant first
          if (opt_rdy) begin
            opt_value <= {opt_value[23:0], opt_byte};
            if (opt_left == 3'd1) begin
              case (opt_code)
                OPT_MSG_TYPE: begin
                  rx_type     <= opt_byte;
                  rx_has_type <= 1'b1;
                end
                OPT_SERVER_ID: begin
                  rx_server     <= {opt_value[23:0], opt_byte};
                  rx_has_server <= 1'b1;
                end
                OPT_LEASE_TIME: begin
                  rx_lease     <= {opt_value[23:0], opt_byte};
                  rx_has_lease <= 1'b1;
                end
                OPT_SUBNET_MASK: rx_mask   <= {opt_value[23:0], opt_byte};
                OPT_ROUTER:      rx_router <= {opt_value[23:0], opt_byte};
                default: begin
                end
              endcase
              opt_pos  <= opt_next;
              opt_rdy  <= 1'b0;
              rx_state <= S_OPT_CODE;
            end else begin
              opt_left <= opt_left - 3'd1;
              opt_pos  <= opt_pos + 17'd1;
              opt_rdy  <= 1'b0;
            end
          end
        end
        S_RX_DONE: begin                                   // a message needs option 53
          rx_msg_valid <= rx_has_type;
          rx_state     <= S_RX_IDLE;
        end
        default: begin
          rx_state <= S_RX_IDLE;
        end
      endcase
    end
  end

  // busy: the receive machine holds a frame, or a frame ended last clock.
  always_ff @(posedge clk) begin
    if (!resetn) busy <= 1'b0;
    else         busy <= (rx_state != S_RX_IDLE) || frame_end;
  end

  // Receive RAM: one captured frame, written one clock behind the bus, read at
  // the walk position (latency 1, read port always enabled).
  rtlnet_ram_core #(
    .RAM_STYLE    (RAM_STYLE),
    .CLOCKING     ("COMMON"),
    .DATA_W       (64),
    .ADDR_W       (ADDR_W),
    .READ_LATENCY (1)
  ) u_rx_ram (
    .wr_clk    (clk),
    .wr_en     (ram_wr_en),
    .wr_addr   (ram_wr_addr),
    .wr_data   (ram_wr_data),
    .rd_clk    (clk),
    .rd_resetn (resetn),
    .rd_en     (1'b1),
    .rd_addr   (opt_pos[ADDR_W+2:3]),
    .rd_data   (ram_rd_data)
  );

  // ---------------------------------------------------------------------------
  // Transmit machine. S_TX_IDLE takes a pending request and copies its
  // descriptor (one reading of the MAC and the client's req_* registers per
  // frame; a disabled leaf drops the request); S_TX_CSUM computes the IPv4
  // header checksum (RFC 791 3.1, RFC 1071); S_TX_BEAT loads one beat whenever
  // the slice input is empty or being taken. The frame counters count frames
  // as they start.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      tx_state      <= S_TX_IDLE;
      tx_pending    <= 1'b0;
      tx_beat       <= 6'd0;
      ip_ident      <= 16'd0;
      tx_kind       <= K_DISCOVER;
      tx_smac       <= 48'd0;
      tx_dmac       <= 48'd0;
      tx_sip        <= 32'd0;
      tx_dip        <= 32'd0;
      tx_xid        <= 32'd0;
      tx_ident      <= 16'd0;
      tx_ciaddr     <= 32'd0;
      tx_req_ip     <= 32'd0;
      tx_server     <= 32'd0;
      tx_csum       <= 16'd0;
      tx_data       <= 64'd0;
      tx_keep       <= 8'd0;
      tx_last       <= 1'b0;
      tx_valid      <= 1'b0;
      cnt_discovers <= 32'd0;
      cnt_requests  <= 32'd0;
      cnt_releases  <= 32'd0;
    end else begin
      if (tx_ready) tx_valid <= 1'b0;
      case (tx_state)
        S_TX_IDLE: begin
          if (tx_pending) begin
            tx_pending <= 1'b0;
            if (enable) begin
              tx_kind   <= req_kind;
              tx_smac   <= local_mac;
              tx_dmac   <= req_dmac;
              tx_sip    <= req_ciaddr;
              tx_dip    <= (req_kind == K_RELEASE) ? req_server : IP_LIMITED_BCAST;
              tx_xid    <= xid;
              tx_ident  <= ip_ident;
              tx_ciaddr <= req_ciaddr;
              tx_req_ip <= req_ip;
              tx_server <= req_server;
              ip_ident  <= ip_ident + 16'd1;
              case (req_kind)
                K_DISCOVER: cnt_discovers <= cnt_discovers + 32'd1;
                K_RELEASE:  cnt_releases  <= cnt_releases + 32'd1;
                default:    cnt_requests  <= cnt_requests + 32'd1;
              endcase
              tx_state  <= S_TX_CSUM;
            end
          end
        end
        S_TX_CSUM: begin
          tx_csum  <= ipv4_header_checksum(8'h00, TX_IP_TOTAL_LEN, tx_ident, 16'h0000, IPV4_TTL, IP_PROTO_UDP,
                                           tx_sip, tx_dip);
          tx_beat  <= 6'd0;
          tx_state <= S_TX_BEAT;
        end
        S_TX_BEAT: begin
          if (!tx_valid || tx_ready) begin
            tx_data  <= beat_word;
            tx_keep  <= (tx_beat == TX_BEAT_LAST) ? TX_KEEP_LAST : 8'hFF;
            tx_last  <= (tx_beat == TX_BEAT_LAST);
            tx_valid <= 1'b1;
            tx_beat  <= tx_beat + 6'd1;
            if (tx_beat == TX_BEAT_LAST) tx_state <= S_TX_IDLE;
          end
        end
        default: begin
          tx_state <= S_TX_IDLE;
        end
      endcase
      if (tx_req) tx_pending <= 1'b1;                       // kept when it meets a pickup
      if (cnt_clear) begin
        cnt_discovers <= 32'd0;
        cnt_requests  <= 32'd0;
        cnt_releases  <= 32'd0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Beat contents of the 342-byte frame (bytes listed in wire order, frame byte
  // 8k+n in lane n). Offsets: Ethernet 0-13, IPv4 14-33, UDP 34-41, BOOTP 42-341
  // (op 42, xid 46-49, flags 52-53, ciaddr 54-57, chaddr 70-75, cookie 278-281,
  // options 282-312, zero to 341).
  // ---------------------------------------------------------------------------
  function automatic logic [63:0] pack8(input logic [7:0] b0, input logic [7:0] b1, input logic [7:0] b2,
                                        input logic [7:0] b3, input logic [7:0] b4, input logic [7:0] b5,
                                        input logic [7:0] b6, input logic [7:0] b7);
    return {b7, b6, b5, b4, b3, b2, b1, b0};
  endfunction

  logic        k_sel;                      // options 50 and 54 of the selecting REQUEST
  logic        k_rel;                      // DHCPRELEASE
  logic [7:0]  k_type;
  logic [7:0]  k_flags;

  assign k_sel   = (tx_kind == K_REQ_SEL);
  assign k_rel   = (tx_kind == K_RELEASE);
  assign k_type  = (tx_kind == K_DISCOVER) ? DHCPDISCOVER : (k_rel ? DHCPRELEASE : DHCPREQUEST);
  assign k_flags = ((tx_kind == K_DISCOVER) || k_sel) ? FLAGS_BROADCAST : 8'h00;

  always_comb begin
    case (tx_beat)
      6'd0:  beat_word = pack8(tx_dmac[47:40], tx_dmac[39:32], tx_dmac[31:24], tx_dmac[23:16],
                               tx_dmac[15:8], tx_dmac[7:0], tx_smac[47:40], tx_smac[39:32]);
      6'd1:  beat_word = pack8(tx_smac[31:24], tx_smac[23:16], tx_smac[15:8], tx_smac[7:0],
                               ETHERTYPE_IPV4[15:8], ETHERTYPE_IPV4[7:0], IPV4_VER_IHL5, 8'h00);
      6'd2:  beat_word = pack8(TX_IP_TOTAL_LEN[15:8], TX_IP_TOTAL_LEN[7:0], tx_ident[15:8], tx_ident[7:0],
                               8'h00, 8'h00, IPV4_TTL, IP_PROTO_UDP);
      6'd3:  beat_word = pack8(tx_csum[15:8], tx_csum[7:0], tx_sip[31:24], tx_sip[23:16],
                               tx_sip[15:8], tx_sip[7:0], tx_dip[31:24], tx_dip[23:16]);
      6'd4:  beat_word = pack8(tx_dip[15:8], tx_dip[7:0], PORT_BOOTPC[15:8], PORT_BOOTPC[7:0],
                               PORT_BOOTPS[15:8], PORT_BOOTPS[7:0], TX_UDP_LEN[15:8], TX_UDP_LEN[7:0]);
      6'd5:  beat_word = pack8(8'h00, 8'h00, BOOTP_OP_REQUEST, BOOTP_HTYPE_ETH,
                               BOOTP_HLEN_ETH, 8'h00, tx_xid[31:24], tx_xid[23:16]);
      6'd6:  beat_word = pack8(tx_xid[15:8], tx_xid[7:0], 8'h00, 8'h00,
                               k_flags, 8'h00, tx_ciaddr[31:24], tx_ciaddr[23:16]);
      6'd7:  beat_word = pack8(tx_ciaddr[15:8], tx_ciaddr[7:0], 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);
      6'd8:  beat_word = pack8(8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, tx_smac[47:40], tx_smac[39:32]);
      6'd9:  beat_word = pack8(tx_smac[31:24], tx_smac[23:16], tx_smac[15:8], tx_smac[7:0],
                               8'h00, 8'h00, 8'h00, 8'h00);
      6'd34: beat_word = pack8(8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, MAGIC_COOKIE[31:24], MAGIC_COOKIE[23:16]);
      6'd35: beat_word = pack8(MAGIC_COOKIE[15:8], MAGIC_COOKIE[7:0], OPT_MSG_TYPE, OPT_LEN_TYPE,
                               k_type, OPT_CLIENT_ID, OPT_LEN_CLIENT_ID, BOOTP_HTYPE_ETH);
      6'd36: beat_word = pack8(tx_smac[47:40], tx_smac[39:32], tx_smac[31:24], tx_smac[23:16],
                               tx_smac[15:8], tx_smac[7:0], k_rel ? OPT_PAD : OPT_PARAM_LIST,
                               k_rel ? OPT_PAD : OPT_LEN_PARAMS);
      6'd37: beat_word = pack8(k_rel ? OPT_PAD : OPT_SUBNET_MASK, k_rel ? OPT_PAD : OPT_ROUTER,
                               k_rel ? OPT_PAD : OPT_DNS, k_rel ? OPT_PAD : OPT_LEASE_TIME,
                               k_sel ? OPT_REQUESTED_IP : OPT_PAD, k_sel ? OPT_LEN_ADDR : OPT_PAD,
                               k_sel ? tx_req_ip[31:24] : 8'h00, k_sel ? tx_req_ip[23:16] : 8'h00);
      6'd38: beat_word = pack8(k_sel ? tx_req_ip[15:8] : 8'h00, k_sel ? tx_req_ip[7:0] : 8'h00,
                               (k_sel || k_rel) ? OPT_SERVER_ID : OPT_PAD, (k_sel || k_rel) ? OPT_LEN_ADDR : OPT_PAD,
                               (k_sel || k_rel) ? tx_server[31:24] : 8'h00, (k_sel || k_rel) ? tx_server[23:16] : 8'h00,
                               (k_sel || k_rel) ? tx_server[15:8] : 8'h00, (k_sel || k_rel) ? tx_server[7:0] : 8'h00);
      6'd39: beat_word = pack8(OPT_END, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00);
      default: beat_word = 64'd0;
    endcase
  end

  // Output register slice: its registered outputs are m_axis_*, its registered
  // s_tready paces the beat loader; m_axis_tready reaches nothing else.
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
  // Simulation-only visibility of a broken wrapper rule (the leaf stays safe:
  // such a frame is ignored whole).
  always @(posedge clk) begin
    if (resetn && first_beat && (rx_state != S_RX_IDLE))
      $warning("rtlnet_dhcp: a frame started while the receive machine is busy (state %0d); ignored", rx_state);
  end
  // synthesis translate_on

endmodule
