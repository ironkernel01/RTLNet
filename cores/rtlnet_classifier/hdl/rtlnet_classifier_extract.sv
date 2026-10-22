// -----------------------------------------------------------------------------
// File: rtlnet_classifier_extract.sv
// Purpose: field extractor of rtlnet_classifier: captures the header bytes of
//   each frame from the engine tap, decides which frames the table engines
//   judge, and loads the per-table field snapshot the table engines compare.
// Overview:
//   * Capture: frame bytes 0..8*CAP_BEATS-1 (CAP_BEATS = min(6, MATCH_BEATS))
//     with a present bit per byte (tkeep); a byte of a shorter frame is
//     absent, never zero. Flags registered as their beat arrives: is_vlan
//     (bytes 12..13 = 0x8100), EtherType 0x0800 and version/IHL 0x45 at the
//     untagged and tagged offsets, fragment-free (flags/offset & 0x3FFF = 0)
//     and protocol 6 or 17 at both offsets.
//   * Judge: tap_judge marks the beat after which a frame's fields are final
//     (beat MATCH_BEATS-1 or the final beat of a shorter frame). A judge is
//     accepted when at least JUDGE_GAP clocks passed since the previous
//     accepted one (the table window and the policer feedback); otherwise it
//     is an overrun (only possible for frames shorter than 60 bytes, see the
//     core documentation) and the combiner drops that frame. judge_acc /
//     judge_ovr pulse in the clock the snapshot becomes valid.
//   * Snapshot (loaded by an accepted judge, held until the next one), field
//     values in number order (first wire byte most significant):
//       MAC        src = bytes 6..11, dst = bytes 0..5
//       ETHERTYPE  bytes 12..13, VLAN-aware on a tagged frame bytes 16..17
//       VLAN       {PCP, VID} in data/mask compare, {000, VID} otherwise;
//                  present only on a tagged frame
//       IP         source/destination IPv4 (bytes 26..29 / 30..33, tagged
//                  +4 when VLAN-aware), present only on IPv4 (IHL 5)
//       PORT       source/destination L4 port (34..35 / 36..37, tagged +4)
//                  and the IP protocol, present only with has_l4 (IPv4,
//                  protocol 6 or 17, not a fragment)
//       TUPLE      protocol, both addresses, both ports with the same rules
//     A non-VLAN-aware table on a tagged frame sees EtherType 0x8100, so its
//     IP and port fields are absent.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (axis_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_classifier_extract #(
  parameter int MATCH_BEATS = 8,           // beats judged, 5..32
  parameter int IDX_W       = 6,           // tap_idx width
  parameter int JUDGE_GAP   = 8            // clocks between accepted judges
)(
  // Stream clock and synchronous active-low reset.
  input  logic             clk,
  input  logic             resetn,

  // Engine tap from the delay line (one registered beat per clock at most).
  input  logic             tap_valid,
  input  logic [63:0]      tap_data,
  input  logic [7:0]       tap_keep,
  input  logic [IDX_W-1:0] tap_idx,
  input  logic             tap_first,
  input  logic             tap_judge,

  // Configuration (registered copies): VLAN_AWARE per table index 0..5, and
  // VLAN table compare mode is data/mask.
  input  logic [5:0]       cfg_aware,
  input  logic             cfg_vlan_mask,

  // Judge decision, pulses in the first clock the snapshot is valid.
  output logic             judge_acc,
  output logic             judge_ovr,

  // MAC table snapshot.
  output logic [47:0]      f_mac_src,
  output logic [47:0]      f_mac_dst,
  output logic             f_mac_sp,
  output logic             f_mac_dp,

  // ETHERTYPE table snapshot.
  output logic [15:0]      f_et,
  output logic             f_et_p,

  // VLAN table snapshot.
  output logic [14:0]      f_vlan,
  output logic             f_vlan_p,

  // IP table snapshot.
  output logic [31:0]      f_ip_src,
  output logic [31:0]      f_ip_dst,
  output logic             f_ip_sp,
  output logic             f_ip_dp,

  // PORT table snapshot.
  output logic [15:0]      f_port_src,
  output logic [15:0]      f_port_dst,
  output logic             f_port_sp,
  output logic             f_port_dp,
  output logic [7:0]       f_port_proto,

  // Tuple table snapshot.
  output logic [7:0]       f_tu_proto,
  output logic [31:0]      f_tu_sip,
  output logic [31:0]      f_tu_dip,
  output logic [15:0]      f_tu_sport,
  output logic [15:0]      f_tu_dport,
  output logic             f_tu_ip,
  output logic             f_tu_l4
);

  import rtlnet_classifier_pkg::*;

  localparam int CAP_BEATS = (MATCH_BEATS < 6) ? MATCH_BEATS : 6;
  localparam int CAP_BYTES = 8 * CAP_BEATS;
  localparam int ALL_BYTES = 48;
  localparam int GAP_W     = rtlnet_pkg::clog2i(JUDGE_GAP + 1);
  localparam logic [GAP_W-1:0] GAP_LOAD = JUDGE_GAP - 1;
  localparam logic [GAP_W-1:0] GAP_ONE  = 1;
  localparam logic             GAP_MULTI = (JUDGE_GAP > 1);

  localparam logic [15:0] ETYPE_VLAN = rtlnet_pkg::ETHERTYPE_VLAN;
  localparam logic [15:0] ETYPE_IPV4 = rtlnet_pkg::ETHERTYPE_IPV4;
  localparam logic [7:0]  VER_IHL5   = rtlnet_pkg::IPV4_VER_IHL5;
  localparam logic [7:0]  PROTO_TCP  = rtlnet_pkg::IP_PROTO_TCP;
  localparam logic [7:0]  PROTO_UDP  = rtlnet_pkg::IP_PROTO_UDP;
  localparam logic [15:0] FRAG_MASK  = 16'h3FFF;    // MF flag and fragment offset

  generate
    if (JUDGE_GAP < 1) begin : g_bad_gap
      $fatal(1, "rtlnet_classifier_extract: JUDGE_GAP=%0d, must be at least 1", JUDGE_GAP);
    end
  endgenerate

  // Capture registers: beat slots and their keep bits.
  logic [63:0] cap_data [0:CAP_BEATS-1];
  logic [7:0]  cap_keep [0:CAP_BEATS-1];
  logic [7:0]  b        [0:ALL_BYTES-1];      // byte view, 0 beyond the capture
  logic        p        [0:ALL_BYTES-1];      // present view, 0 beyond the capture

  // Header flags.
  logic        fl_vlan;
  logic        fl_etu_ip;
  logic        fl_ihl_u;
  logic        fl_ett_ip;
  logic        fl_ihl_t;
  logic        fl_frag_u;
  logic        fl_frag_t;
  logic        fl_l4_u;
  logic        fl_l4_t;

  // Judge control.
  logic             judge_q;
  logic             busy_q;
  logic [GAP_W-1:0] gap_cnt;
  logic             accept;

  // Per-table offset selection (VLAN-aware table on a tagged frame).
  logic        sel_et;
  logic        sel_ip;
  logic        sel_po;
  logic        sel_tu;

  // Beat slots: slot k loads beat k; beat 0 also clears the keep bits of
  // the later slots, so a short frame leaves them absent.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      for (int k = 0; k < CAP_BEATS; k++) begin
        cap_data[k] <= '0;
        cap_keep[k] <= '0;
      end
    end else if (tap_valid) begin
      for (int k = 0; k < CAP_BEATS; k++) begin
        if (tap_idx == k) begin
          cap_data[k] <= tap_data;
          cap_keep[k] <= tap_keep;
        end else if (tap_first) begin
          cap_keep[k] <= '0;
        end
      end
    end
  end

  // Byte and present views of the capture (constant indexing).
  always_comb begin
    for (int i = 0; i < ALL_BYTES; i++) begin
      if (i < CAP_BYTES) begin
        b[i] = cap_data[i / 8][8 * (i % 8) +: 8];
        p[i] = cap_keep[i / 8][i % 8];
      end else begin
        b[i] = 8'h00;
        p[i] = 1'b0;
      end
    end
  end

  // Header flags, each registered from the tap as its beat arrives and
  // cleared by the first beat of the next frame.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      fl_vlan   <= 1'b0;
      fl_etu_ip <= 1'b0;
      fl_ihl_u  <= 1'b0;
      fl_ett_ip <= 1'b0;
      fl_ihl_t  <= 1'b0;
      fl_frag_u <= 1'b0;
      fl_frag_t <= 1'b0;
      fl_l4_u   <= 1'b0;
      fl_l4_t   <= 1'b0;
    end else if (tap_valid) begin
      if (tap_first) begin
        fl_vlan   <= 1'b0;
        fl_etu_ip <= 1'b0;
        fl_ihl_u  <= 1'b0;
        fl_ett_ip <= 1'b0;
        fl_ihl_t  <= 1'b0;
        fl_frag_u <= 1'b0;
        fl_frag_t <= 1'b0;
        fl_l4_u   <= 1'b0;
        fl_l4_t   <= 1'b0;
      end
      // Beat 1: bytes 8..15 (EtherType 12..13, untagged version/IHL 14).
      if (tap_idx == 1) begin
        fl_vlan   <= tap_keep[5] && ({tap_data[39:32], tap_data[47:40]} == ETYPE_VLAN);
        fl_etu_ip <= tap_keep[5] && ({tap_data[39:32], tap_data[47:40]} == ETYPE_IPV4);
        fl_ihl_u  <= tap_keep[6] && (tap_data[55:48] == VER_IHL5);
      end
      // Beat 2: bytes 16..23 (inner EtherType 16..17, tagged IHL 18,
      // untagged flags/offset 20..21, untagged protocol 23).
      if (tap_idx == 2) begin
        fl_ett_ip <= tap_keep[1] && ({tap_data[7:0], tap_data[15:8]} == ETYPE_IPV4);
        fl_ihl_t  <= tap_keep[2] && (tap_data[23:16] == VER_IHL5);
        fl_frag_u <= tap_keep[5] && (({tap_data[39:32], tap_data[47:40]} & FRAG_MASK) == 16'h0000);
        fl_l4_u   <= tap_keep[7] && ((tap_data[63:56] == PROTO_TCP) || (tap_data[63:56] == PROTO_UDP));
      end
      // Beat 3: bytes 24..31 (tagged flags/offset 24..25, tagged protocol 27).
      if (tap_idx == 3) begin
        fl_frag_t <= tap_keep[1] && (({tap_data[7:0], tap_data[15:8]} & FRAG_MASK) == 16'h0000);
        fl_l4_t   <= tap_keep[3] && ((tap_data[31:24] == PROTO_TCP) || (tap_data[31:24] == PROTO_UDP));
      end
    end
  end

  // Judge acceptance: at least JUDGE_GAP clocks between accepted judges.
  assign accept = judge_q && !busy_q;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      judge_q   <= 1'b0;
      busy_q    <= 1'b0;
      gap_cnt   <= '0;
      judge_acc <= 1'b0;
      judge_ovr <= 1'b0;
    end else begin
      judge_q   <= tap_valid && tap_judge;
      judge_acc <= accept;
      judge_ovr <= judge_q && busy_q;
      if (accept) begin
        gap_cnt <= GAP_LOAD;
        busy_q  <= GAP_MULTI;
      end else begin
        if (gap_cnt != '0) gap_cnt <= gap_cnt - 1'b1;
        busy_q <= (gap_cnt > GAP_ONE);
      end
    end
  end

  assign sel_et = cfg_aware[TBL_ETHERTYPE] && fl_vlan;
  assign sel_ip = cfg_aware[TBL_IP]        && fl_vlan;
  assign sel_po = cfg_aware[TBL_PORT]      && fl_vlan;
  assign sel_tu = cfg_aware[TBL_TUPLE]     && fl_vlan;

  // Snapshot for the table engines, loaded by an accepted judge.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      f_mac_src    <= '0;
      f_mac_dst    <= '0;
      f_mac_sp     <= 1'b0;
      f_mac_dp     <= 1'b0;
      f_et         <= '0;
      f_et_p       <= 1'b0;
      f_vlan       <= '0;
      f_vlan_p     <= 1'b0;
      f_ip_src     <= '0;
      f_ip_dst     <= '0;
      f_ip_sp      <= 1'b0;
      f_ip_dp      <= 1'b0;
      f_port_src   <= '0;
      f_port_dst   <= '0;
      f_port_sp    <= 1'b0;
      f_port_dp    <= 1'b0;
      f_port_proto <= '0;
      f_tu_proto   <= '0;
      f_tu_sip     <= '0;
      f_tu_dip     <= '0;
      f_tu_sport   <= '0;
      f_tu_dport   <= '0;
      f_tu_ip      <= 1'b0;
      f_tu_l4      <= 1'b0;
    end else if (accept) begin
      // MAC.
      f_mac_dst <= {b[0], b[1], b[2], b[3], b[4], b[5]};
      f_mac_src <= {b[6], b[7], b[8], b[9], b[10], b[11]};
      f_mac_dp  <= p[5];
      f_mac_sp  <= p[11];
      // ETHERTYPE.
      f_et   <= sel_et ? {b[16], b[17]} : {b[12], b[13]};
      f_et_p <= sel_et ? p[17] : p[13];
      // VLAN.
      f_vlan   <= cfg_vlan_mask ? {b[14][7:5], b[14][3:0], b[15]} : {3'b000, b[14][3:0], b[15]};
      f_vlan_p <= fl_vlan && p[15];
      // IP.
      f_ip_src <= sel_ip ? {b[30], b[31], b[32], b[33]} : {b[26], b[27], b[28], b[29]};
      f_ip_dst <= sel_ip ? {b[34], b[35], b[36], b[37]} : {b[30], b[31], b[32], b[33]};
      f_ip_sp  <= sel_ip ? (fl_ett_ip && fl_ihl_t && p[33]) : (fl_etu_ip && fl_ihl_u && p[29]);
      f_ip_dp  <= sel_ip ? (fl_ett_ip && fl_ihl_t && p[37]) : (fl_etu_ip && fl_ihl_u && p[33]);
      // PORT.
      f_port_src   <= sel_po ? {b[38], b[39]} : {b[34], b[35]};
      f_port_dst   <= sel_po ? {b[40], b[41]} : {b[36], b[37]};
      f_port_proto <= sel_po ? b[27] : b[23];
      f_port_sp    <= sel_po ? (fl_ett_ip && fl_ihl_t && fl_frag_t && fl_l4_t && p[39])
                             : (fl_etu_ip && fl_ihl_u && fl_frag_u && fl_l4_u && p[35]);
      f_port_dp    <= sel_po ? (fl_ett_ip && fl_ihl_t && fl_frag_t && fl_l4_t && p[41])
                             : (fl_etu_ip && fl_ihl_u && fl_frag_u && fl_l4_u && p[37]);
      // TUPLE.
      f_tu_proto <= sel_tu ? b[27] : b[23];
      f_tu_sip   <= sel_tu ? {b[30], b[31], b[32], b[33]} : {b[26], b[27], b[28], b[29]};
      f_tu_dip   <= sel_tu ? {b[34], b[35], b[36], b[37]} : {b[30], b[31], b[32], b[33]};
      f_tu_sport <= sel_tu ? {b[38], b[39]} : {b[34], b[35]};
      f_tu_dport <= sel_tu ? {b[40], b[41]} : {b[36], b[37]};
      f_tu_ip    <= sel_tu ? (fl_ett_ip && fl_ihl_t && p[37]) : (fl_etu_ip && fl_ihl_u && p[33]);
      f_tu_l4    <= sel_tu ? (fl_ett_ip && fl_ihl_t && fl_frag_t && fl_l4_t && p[41])
                           : (fl_etu_ip && fl_ihl_u && fl_frag_u && fl_l4_u && p[37]);
    end
  end

endmodule
