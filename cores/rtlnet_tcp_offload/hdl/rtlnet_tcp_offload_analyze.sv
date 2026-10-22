// -----------------------------------------------------------------------------
// File: rtlnet_tcp_offload_analyze.sv
// Purpose: the checksum engine of rtlnet_tcp_offload: parses the Ethernet /
//   (optional 802.1Q) / IPv4 headers of a frame while it streams past, sums the
//   IPv4 header and the TCP/UDP pseudo-header plus segment with the
//   ones'-complement arithmetic of RFC 1071, and delivers one result record per
//   frame a fixed ANALYZE_LAT enabled clocks after the frame's final beat.
// Overview:
//   * Streaming, no frame store. One beat per enabled clock. The pipeline runs
//     in "line time": every register advances only when `en` is high, so a
//     caller that stalls its data path (the receive line) stalls the engine
//     with it and the result stays aligned with the frame's final beat. The
//     transmit instance ties en to 1. A clock with `fire` low is a bubble that
//     travels through the pipeline; frames may have gaps.
//   * Stage A: beat counter (index, one-hot position of beats 0..4, flags),
//     registered beat P1. Header capture from P1: the Ethernet type words, the
//     IPv4 version/IHL, total length, fragment word and protocol bytes of both
//     the untagged and the tagged layout (one capture register each; the tag
//     selects later). Derived registers D1 (select by tag), D2 (IP header end
//     x, segment end, protocol class) and D3 (beat/lane form of the ends and
//     of the L4 checksum field offset). The context register P5 latches D3 for
//     each beat; its read happens 4 clocks after the beat was offered, which
//     is after the header fields (all in beats 0..3) of the same frame are
//     valid at D3 for every beat from beat 4 on (back-to-back beats), and
//     before the next frame's first captured fields can reach D1 (see the
//     timing table in documentation/rtlnet_tcp_offload.md).
//   * Masks: for each beat, per-lane byte masks for the IPv4 header range
//     [E, E+4*IHL), the pseudo-header address bytes and the L4 range
//     [E+4*IHL, E+total_len) (E = 14 or 18), built from the beat index with
//     registered subtract / flag / lane / combine stages (M1..M4). Padding
//     past the IP total length is never in a mask. In transmit mode the
//     existing IPv4 and L4 checksum fields are masked out (treated as zero);
//     in receive mode they are kept and the L4 checksum field is summed alone
//     (third tree) to detect a UDP checksum of zero.
//   * Sums: the data beat is delayed by rtlnet_shift_reg_core to meet its
//     masks; S1 and S2 add the four aligned 16-bit words under the mask (two
//     17-bit adders, one 18-bit adder), S3 accumulates in 26 bits (256 beats
//     of four words fit). All adders are one LUT level plus carry chain.
//   * Decisions F1..F4 (parallel to the sums): frame length, header end <=
//     frame length, segment end <= frame length, L4 length and its minimum
//     (TCP 20, UDP 8), IHL >= 5, version 4, EtherType, protocol class,
//     fragment flag, giving hdr_valid, l4_cand, l4_elig. Static fields then
//     ride rtlnet_shift_reg_core delays until the sums finish.
//   * Finish J1..J3 and R: header sum folded twice; pseudo-header extra
//     (L4 length + protocol) added, segment sum folded twice; all-ones tests.
//   * The consumers (transmit patching, receive trailer) interpret the folded
//     sums: transmit uses ~sum (checksum with the field treated as 0),
//     receive checks sum == 0xFFFF with the field included.
//   * Frames longer than 256 beats set res_ovf (matches rtlnet_packet_fifo's
//     slot overflow for the default 1518-byte slot); their flags are cleared.
// Result record (valid with res_v, all registered):
//   res_cfg (cfg_in sampled at the frame's first beat), res_tag, res_is_ipv4,
//   res_is_tcp, res_is_udp, res_frag, res_hdr_valid (IPv4, IHL>=5, header
//   inside the frame), res_l4_cand (hdr_valid, TCP/UDP, not a fragment),
//   res_l4_elig (l4_cand and the segment lies inside the frame and holds its
//   header), res_udp_none (receive: UDP checksum field is zero), res_ip_good /
//   res_l4_good (folded sum == 0xFFFF), res_ip_fold, res_l4_fold, res_len
//   (bytes, up to 3072), res_l4s (L4 start offset), res_l4c (offset of the L4
//   checksum field), res_ovf.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk; resetn synchronous, active low. All registers advance on en.
// -----------------------------------------------------------------------------
module rtlnet_tcp_offload_analyze #(
  parameter bit RX_MODE = 1'b0             // 0 transmit (mask checksum fields), 1 receive (keep them)
)(
  // Clock, reset, line-time enable.
  input  logic        clk,
  input  logic        resetn,
  input  logic        en,

  // Beat offered this clock (taken when en is high): RTLNet stream.
  input  logic        fire,
  input  logic [63:0] s_data,
  input  logic [7:0]  s_keep,
  input  logic        s_last,
  input  logic [1:0]  cfg_in,              // sampled at the first beat of each frame

  // Result record, ANALYZE_LAT enabled clocks after the final beat.
  output logic        res_v,
  output logic [1:0]  res_cfg,
  output logic        res_tag,
  output logic        res_is_ipv4,
  output logic        res_is_tcp,
  output logic        res_is_udp,
  output logic        res_frag,
  output logic        res_hdr_valid,
  output logic        res_l4_cand,
  output logic        res_l4_elig,
  output logic        res_udp_none,
  output logic        res_ip_good,
  output logic        res_l4_good,
  output logic [15:0] res_ip_fold,
  output logic [15:0] res_l4_fold,
  output logic [11:0] res_len,
  output logic [6:0]  res_l4s,
  output logic [6:0]  res_l4c,
  output logic        res_ovf
);

  import rtlnet_tcp_offload_pkg::*;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  // Number of bytes in a final beat modulo 8 (thermometer tkeep; a full beat is 0).
  function automatic logic [2:0] keep_lo(input logic [7:0] k);
    case (k)
      8'h01:   return 3'd1;
      8'h03:   return 3'd2;
      8'h07:   return 3'd3;
      8'h0F:   return 3'd4;
      8'h1F:   return 3'd5;
      8'h3F:   return 3'd6;
      8'h7F:   return 3'd7;
      default: return 3'd0;
    endcase
  endfunction

  // Big-endian 16-bit word j of a bus-order beat with its two byte lanes masked.
  function automatic logic [15:0] mword(input logic [63:0] d, input logic [7:0] m, input int j);
    return {d[16*j +: 8] & {8{m[2*j]}}, d[16*j + 8 +: 8] & {8{m[2*j+1]}}};
  endfunction

  typedef struct packed {
    logic       last;
    logic       first;
    logic [8:0] idx;
    logic [3:0] idx4;
    logic [4:0] pos;                       // one-hot beat 0..4
    logic       ge5;
    logic       lt4;
    logic [1:0] cfg;
    logic [7:0] keep;
  } ctl_t;

  typedef struct packed {
    logic        l4_cand;
    logic        l4_elig;
    logic        hdr_ok;
    logic        is_ipv4;
    logic        tag;
    logic        tcp;
    logic        udp;
    logic        frag;
    logic        ovf;
    logic [1:0]  cfg;
    logic [12:0] fl;
    logic [6:0]  l4s;
    logic [6:0]  off;
  } bun_t;

  // ---------------------------------------------------------------------------
  // Stage A: beat counter and P1
  // ---------------------------------------------------------------------------
  logic [8:0]  cnt_idx   = '0;
  logic        cnt_first = 1'b1;
  logic [1:0]  frame_cfg = '0;
  ctl_t        c1 = '0, c2 = '0, c3 = '0, c4 = '0, c5 = '0;
  logic [5:1]  cv = '0;                  // valid of P1..P5 (the only reset registers of the control pipeline)
  logic [63:0] p1_data = '0;
  logic        tag3 = 1'b0, tag4 = 1'b0, tag5 = 1'b0;

  // Counter and first-beat flag advance on every taken beat; the index
  // saturates at 384 (bit 8 and bit 7 set): ovf is bit 8.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      cnt_idx   <= '0;
      cnt_first <= 1'b1;
      frame_cfg <= '0;
    end else if (en && fire) begin
      cnt_first <= s_last;
      if (cnt_first) frame_cfg <= cfg_in;
      if (s_last)                           cnt_idx <= '0;
      else if (!(cnt_idx[8] && cnt_idx[7])) cnt_idx <= cnt_idx + 9'd1;
    end
  end

  // Valid chain P1..P5.
  always_ff @(posedge clk) begin
    if (!resetn)  cv <= '0;
    else if (en)  cv <= {cv[4:1], fire};
  end

  // P1 and the per-beat control pipeline P2..P5 (one-hot position and flags are decoded from the
  // counter register, two LUT levels; no reset: the valid chain qualifies every use).
  always_ff @(posedge clk) begin
    if (en) begin
      c1.last  <= s_last;
      c1.first <= cnt_first;
      c1.idx   <= cnt_idx;
      c1.idx4  <= (|cnt_idx[8:4]) ? 4'hF : cnt_idx[3:0];
      for (int i = 0; i < 5; i++) c1.pos[i] <= (cnt_idx == 9'(i));
      c1.ge5   <= (|cnt_idx[8:3]) || (cnt_idx[2] && (cnt_idx[1] || cnt_idx[0]));
      c1.lt4   <= (cnt_idx[8:2] == 7'd0);
      c1.cfg   <= cnt_first ? cfg_in : frame_cfg;
      c1.keep  <= s_keep;
      c2 <= c1;
      c3 <= c2;
      c4 <= c3;
      c5 <= c4;
    end
  end

  always_ff @(posedge clk) begin
    if (en) p1_data <= s_data;
  end

  // ---------------------------------------------------------------------------
  // Header capture from P1 (registers visible one clock later)
  // ---------------------------------------------------------------------------
  logic        cap_tag_a = 1'b0, cap_ip_a = 1'b0, cap_hi0 = 1'b0;      // EtherType byte compares (halves)
  logic [7:0]  cap_vi = '0;
  logic        cap2_ip_a = 1'b0, cap2_ip_b = 1'b0;
  logic        cap2_fragu_a = 1'b0, cap2_fragu_b = 1'b0, cap3_fragt_a = 1'b0, cap3_fragt_b = 1'b0;
  logic        cap_tag, cap_ip, cap2_ip, cap2_fragu, cap3_fragt;

  assign cap_tag    = cap_tag_a && cap_hi0;
  assign cap_ip     = cap_ip_a && cap_hi0;
  assign cap2_ip    = cap2_ip_a && cap2_ip_b;
  assign cap2_fragu = cap2_fragu_a || cap2_fragu_b;
  assign cap3_fragt = cap3_fragt_a || cap3_fragt_b;
  logic [7:0]  cap2_vi = '0, cap2_proto = '0, cap3_proto = '0;
  logic [15:0] cap2_tlu = '0, cap2_tlt = '0;

  always_ff @(posedge clk) begin
    if (en) begin
      if (cv[1] && c1.pos[1]) begin
        cap_tag_a <= (p1_data[39:32] == 8'h81);           // byte 12 = 81 (tag)
        cap_ip_a  <= (p1_data[39:32] == 8'h08);           // byte 12 = 08 (IPv4)
        cap_hi0   <= (p1_data[47:40] == 8'h00);           // byte 13 = 00
        cap_vi  <= p1_data[55:48];                        // byte 14: version / IHL (untagged)
      end
      if (cv[1] && c1.pos[2]) begin
        cap2_ip_a  <= (p1_data[7:0] == 8'h08);            // bytes 16,17 = 08 00 (tagged)
        cap2_ip_b  <= (p1_data[15:8] == 8'h00);
        cap2_vi    <= p1_data[23:16];                     // byte 18: version / IHL (tagged)
        cap2_tlu   <= {p1_data[7:0], p1_data[15:8]};      // bytes 16,17: total length (untagged)
        cap2_tlt   <= {p1_data[39:32], p1_data[47:40]};   // bytes 20,21: total length (tagged)
        cap2_fragu_a <= |p1_data[47:40];                  // bytes 20,21: MF / offset (untagged)
        cap2_fragu_b <= |p1_data[37:32];
        cap2_proto <= p1_data[63:56];                     // byte 23: protocol (untagged)
      end
      if (cv[1] && c1.pos[3]) begin
        cap3_fragt_a <= |p1_data[15:8];                   // bytes 24,25: MF / offset (tagged)
        cap3_fragt_b <= |p1_data[5:0];
        cap3_proto <= p1_data[31:24];                     // byte 27: protocol (tagged)
      end
    end
  end

  // ---------------------------------------------------------------------------
  // D1..D3: derived per-frame values (valid for the current frame from beat 4)
  // ---------------------------------------------------------------------------
  logic        d1_tag = 1'b0, d1_ver_ok = 1'b0, d1_et_ok = 1'b0, d1_frag = 1'b0;
  logic [3:0]  d1_ihl = '0;
  logic [15:0] d1_tl = '0;
  logic [7:0]  d1_proto = '0;

  logic        d2_tag = 1'b0, d2_ver_ok = 1'b0, d2_et_ok = 1'b0, d2_frag = 1'b0, d2_udp = 1'b0, d2_tcp = 1'b0;
  logic [3:0]  d2_ihl = '0;
  logic [15:0] d2_tl = '0;
  logic [7:0]  d2_proto = '0;
  logic [4:0]  d2_x = '0;                 // L4 start = 4 x + 2
  logic [16:0] d2_l4e = '0;               // L4 end offset = E + total length

  logic        d3_ver_ok = 1'b0, d3_et_ok = 1'b0, d3_frag = 1'b0, d3_udp = 1'b0, d3_tcp = 1'b0;
  logic [3:0]  d3_ihl = '0;
  logic [15:0] d3_tl = '0;
  logic [7:0]  d3_proto = '0;
  logic [4:0]  d3_x = '0;
  logic [16:0] d3_l4e = '0;
  logic [7:0]  d3_ke = '0;                // min(L4 end / 8, 255)
  logic [2:0]  d3_elo = '0;               // L4 end modulo 8
  logic [6:0]  d3_off = '0;               // L4 checksum field offset

  always_ff @(posedge clk) begin
    if (en) begin
      d1_tag    <= cap_tag;
      d1_ihl    <= cap_tag ? cap2_vi[3:0] : cap_vi[3:0];
      d1_ver_ok <= ((cap_tag ? cap2_vi[7:4] : cap_vi[7:4]) == 4'h4);
      d1_et_ok  <= cap_tag ? cap2_ip : cap_ip;
      d1_tl     <= cap_tag ? cap2_tlt : cap2_tlu;
      d1_proto  <= cap_tag ? cap3_proto : cap2_proto;
      d1_frag   <= cap_tag ? cap3_fragt : cap2_fragu;

      d2_tag    <= d1_tag;
      d2_ihl    <= d1_ihl;
      d2_ver_ok <= d1_ver_ok;
      d2_et_ok  <= d1_et_ok;
      d2_tl     <= d1_tl;
      d2_proto  <= d1_proto;
      d2_frag   <= d1_frag;
      d2_udp    <= (d1_proto == 8'd17);
      d2_tcp    <= (d1_proto == 8'd6);
      d2_x      <= {1'b0, d1_ihl} + (d1_tag ? 5'd4 : 5'd3);
      d2_l4e    <= {1'b0, d1_tl} + (d1_tag ? 17'd18 : 17'd14);

      d3_ihl    <= d2_ihl;
      d3_ver_ok <= d2_ver_ok;
      d3_et_ok  <= d2_et_ok;
      d3_tl     <= d2_tl;
      d3_proto  <= d2_proto;
      d3_frag   <= d2_frag;
      d3_udp    <= d2_udp;
      d3_tcp    <= d2_tcp;
      d3_x      <= d2_x;
      d3_l4e    <= d2_l4e;
      d3_ke     <= (|d2_l4e[16:11]) ? 8'hFF : d2_l4e[10:3];
      d3_elo    <= d2_l4e[2:0];
      d3_off    <= {d2_x, 2'b10} + (d2_udp ? 7'd6 : 7'd16);
    end
  end

  // Per-beat tag copy: cap_tag is read two clocks after the beat was offered.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      tag3 <= 1'b0; tag4 <= 1'b0; tag5 <= 1'b0;
    end else if (en) begin
      tag3 <= cap_tag;
      tag4 <= tag3;
      tag5 <= tag4;
    end
  end

  // ---------------------------------------------------------------------------
  // P5 context: D3 read four clocks after the beat was offered.
  // ---------------------------------------------------------------------------
  logic        x_ver_ok = 1'b0, x_et_ok = 1'b0, x_frag = 1'b0, x_udp = 1'b0, x_tcp = 1'b0;
  logic [3:0]  x_ihl = '0;
  logic [15:0] x_tl = '0;
  logic [7:0]  x_proto = '0;
  logic [4:0]  x_x = '0;
  logic [16:0] x_l4e = '0;
  logic [7:0]  x_ke = '0;
  logic [2:0]  x_elo = '0;
  logic [6:0]  x_off = '0;

  always_ff @(posedge clk) begin
    if (en) begin
      x_ihl    <= d3_ihl;
      x_ver_ok <= d3_ver_ok;
      x_et_ok  <= d3_et_ok;
      x_tl     <= d3_tl;
      x_proto  <= d3_proto;
      x_frag   <= d3_frag;
      x_udp    <= d3_udp;
      x_tcp    <= d3_tcp;
      x_x      <= d3_x;
      x_l4e    <= d3_l4e;
      x_ke     <= d3_ke;
      x_elo    <= d3_elo;
      x_off    <= d3_off;
    end
  end

  // ---------------------------------------------------------------------------
  // Masks M1..M4
  // ---------------------------------------------------------------------------
  logic [4:0] m1_ds = '0;
  logic [8:0] m1_de = '0;
  logic       m1_ceq = 1'b0;
  logic [2:0] m1_slo = '0, m1_elo = '0;
  logic [1:0] m1_clo = '0;
  logic       m1_tag = 1'b0, m1_ge5 = 1'b0, m1_lt4 = 1'b0;
  logic [4:0] m1_pos = '0;

  logic       m2_spos = 1'b0, m2_seq = 1'b0, m2_epos = 1'b0, m2_eeq = 1'b0, m2_ceq = 1'b0;
  logic [2:0] m2_slo = '0, m2_elo = '0;
  logic [1:0] m2_clo = '0;
  logic       m2_tag = 1'b0, m2_ge5 = 1'b0, m2_lt4 = 1'b0;
  logic [4:0] m2_pos = '0;

  logic [7:0] m3_ipend = '0, m3_l4end = '0, m3_ipst = '0, m3_ipex = '0, m3_pseu = '0, m3_cex = '0, m3_cfld = '0;
  logic [7:0] m4_ipm = '0, m4_l4m = '0, m4_fldm = '0;

  always_ff @(posedge clk) begin
    if (en) begin
      // M1: distance of this beat to the IP header end (beats) and to the L4 end; checksum-field beat match.
      m1_ds   <= {1'b0, x_x[4:1]} - {1'b0, c5.idx4};
      m1_de   <= {1'b0, x_ke} - {1'b0, c5.idx[7:0]};
      m1_ceq  <= (c5.idx4 == x_off[6:3]);
      m1_slo  <= {x_x[0], 2'b10};
      m1_elo  <= x_elo;
      m1_clo  <= x_off[2:1];
      m1_tag  <= tag5;
      m1_ge5  <= c5.ge5;
      m1_lt4  <= c5.lt4;
      m1_pos  <= c5.pos;

      // M2: flags.
      m2_spos <= !m1_ds[4] && (|m1_ds[3:0]);
      m2_seq  <= (m1_ds == 5'd0);
      m2_epos <= !m1_de[8] && (|m1_de[7:0]);
      m2_eeq  <= (m1_de == 9'd0);
      m2_ceq  <= m1_ceq;
      m2_slo  <= m1_slo;
      m2_elo  <= m1_elo;
      m2_clo  <= m1_clo;
      m2_tag  <= m1_tag;
      m2_ge5  <= m1_ge5;
      m2_lt4  <= m1_lt4;
      m2_pos  <= m1_pos;

      // M3: per-lane masks. ipend: byte before the L4 start (beats 0..3 are always inside the IP area);
      // l4end: byte before the L4 end; ipst: byte at or after the IP header start; ipex: IP checksum word;
      // pseu: pseudo-header address bytes; cex / cfld: L4 checksum field (excluded in transmit, selected in receive).
      for (int l = 0; l < 8; l++) begin
        m3_ipend[l] <= m2_lt4 || m2_spos || (m2_seq && (3'(l) < m2_slo));
        m3_l4end[l] <= m2_epos || (m2_eeq && (3'(l) < m2_elo));
        m3_ipst[l]  <= !(m2_pos[0] || m2_pos[1] || m2_pos[2])
                       || (m2_pos[2] && (!m2_tag || l >= 2))
                       || (m2_pos[1] && !m2_tag && l >= 6);
        m3_ipex[l]  <= !RX_MODE && m2_pos[3] && (m2_tag ? (l == 4 || l == 5) : (l == 0 || l == 1));
        m3_pseu[l]  <= (m2_pos[3] && (m2_tag ? (l >= 6) : (l >= 2)))
                       || (m2_pos[4] && (m2_tag ? (l <= 5) : (l <= 1)));
        m3_cex[l]   <= !RX_MODE && m2_ceq && m2_ge5 && (m2_clo == 2'(l / 2));
        m3_cfld[l]  <= RX_MODE && m2_ceq && m2_ge5 && (m2_clo == 2'(l / 2));
      end

      // M4: final masks.
      m4_ipm  <= m3_ipst & ~m3_ipex & m3_ipend;
      m4_l4m  <= (~m3_ipend & m3_l4end & ~m3_cex) | m3_pseu;
      m4_fldm <= m3_cfld;
    end
  end

  // ---------------------------------------------------------------------------
  // Control chain to the accumulators: M1 .. S2 (valid / last / first).
  // ---------------------------------------------------------------------------
  logic [2:0] lf [6:11];
  logic [2:0] lf5;
  assign lf5 = {cv[5], c5.last, c5.first};

  always_ff @(posedge clk) begin
    if (!resetn) begin
      for (int i = 6; i <= 11; i++) lf[i] <= '0;
    end else if (en) begin
      lf[6] <= lf5;
      for (int i = 7; i <= 11; i++) lf[i] <= lf[i-1];
    end
  end

  // ---------------------------------------------------------------------------
  // Sums S1..S3
  // ---------------------------------------------------------------------------
  logic [63:0] s1_d;

  rtlnet_shift_reg_core #(
    .DATA_W (64),
    .DEPTH  (8)
  ) u_data_dly (
    .clk (clk),
    .ce  (en),
    .d   (p1_data),
    .q   (s1_d)
  );

  logic [16:0] s1_ip0 = '0, s1_ip1 = '0, s1_l40 = '0, s1_l41 = '0, s1_fl0 = '0, s1_fl1 = '0;
  logic [17:0] s2_ip = '0, s2_l4 = '0, s2_fl = '0;
  logic [25:0] acc_ip = '0, acc_l4 = '0;
  logic [17:0] acc_fl = '0;
  logic        acc_done = 1'b0;

  always_ff @(posedge clk) begin
    if (en) begin
      s1_ip0 <= {1'b0, mword(s1_d, m4_ipm, 0)} + {1'b0, mword(s1_d, m4_ipm, 1)};
      s1_ip1 <= {1'b0, mword(s1_d, m4_ipm, 2)} + {1'b0, mword(s1_d, m4_ipm, 3)};
      s1_l40 <= {1'b0, mword(s1_d, m4_l4m, 0)} + {1'b0, mword(s1_d, m4_l4m, 1)};
      s1_l41 <= {1'b0, mword(s1_d, m4_l4m, 2)} + {1'b0, mword(s1_d, m4_l4m, 3)};
      if (RX_MODE) begin
        s1_fl0 <= {1'b0, mword(s1_d, m4_fldm, 0)} + {1'b0, mword(s1_d, m4_fldm, 1)};
        s1_fl1 <= {1'b0, mword(s1_d, m4_fldm, 2)} + {1'b0, mword(s1_d, m4_fldm, 3)};
      end
      s2_ip <= {1'b0, s1_ip0} + {1'b0, s1_ip1};
      s2_l4 <= {1'b0, s1_l40} + {1'b0, s1_l41};
      if (RX_MODE) s2_fl <= {1'b0, s1_fl0} + {1'b0, s1_fl1};
      if (lf[11][2]) begin
        acc_ip <= lf[11][0] ? {8'd0, s2_ip} : acc_ip + {8'd0, s2_ip};
        acc_l4 <= lf[11][0] ? {8'd0, s2_l4} : acc_l4 + {8'd0, s2_l4};
        if (RX_MODE) acc_fl <= lf[11][0] ? s2_fl : acc_fl + s2_fl;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn)  acc_done <= 1'b0;
    else if (en)  acc_done <= lf[11][2] && lf[11][1];
  end

  // ---------------------------------------------------------------------------
  // Decisions F1..F4
  // ---------------------------------------------------------------------------
  // F1 (from the P5 context): frame length and field copies.
  logic [12:0] f1_fl = '0;
  logic [3:0]  f1_ihl = '0;
  logic [15:0] f1_tl = '0;
  logic [16:0] f1_l4e = '0;
  logic [4:0]  f1_x = '0;
  logic [6:0]  f1_off = '0;
  logic [7:0]  f1_proto = '0;
  logic        f1_tag = 1'b0, f1_ver = 1'b0, f1_et = 1'b0, f1_tcp = 1'b0, f1_udp = 1'b0, f1_frag = 1'b0;
  logic        f1_short = 1'b0, f1_ovf = 1'b0;
  logic [1:0]  f1_cfg = '0;

  // F2: header / segment end against the frame length, L4 length.
  logic        f2_aneg = 1'b0, f2_bneg = 1'b0, f2_lneg = 1'b0, f2_ihl5 = 1'b0;
  logic [15:0] f2_l4len = '0;
  logic [12:0] f2_fl = '0;
  logic [4:0]  f2_x = '0;
  logic [6:0]  f2_off = '0;
  logic [7:0]  f2_proto = '0;
  logic        f2_tag = 1'b0, f2_ver = 1'b0, f2_et = 1'b0, f2_tcp = 1'b0, f2_udp = 1'b0, f2_frag = 1'b0;
  logic        f2_short = 1'b0, f2_ovf = 1'b0;
  logic [1:0]  f2_cfg = '0;

  // F3: header decision, length tests, pseudo-header extra.
  logic        f3_hdr = 1'b0, f3_g8a = 1'b0, f3_g8b = 1'b0, f3_g20b = 1'b0, f3_lneg = 1'b0, f3_bneg = 1'b0, f3_ipv4 = 1'b0;
  logic [16:0] f3_extra = '0;
  logic [12:0] f3_fl = '0;
  logic [4:0]  f3_x = '0;
  logic [6:0]  f3_off = '0;
  logic        f3_tag = 1'b0, f3_tcp = 1'b0, f3_udp = 1'b0, f3_frag = 1'b0, f3_ovf = 1'b0;
  logic [1:0]  f3_cfg = '0;

  bun_t        f4 = '0;

  always_ff @(posedge clk) begin
    if (en) begin
      f1_fl    <= {(c5.idx + {8'd0, c5.keep[7]}), keep_lo(c5.keep)};
      f1_ihl   <= x_ihl;
      f1_tl    <= x_tl;
      f1_l4e   <= x_l4e;
      f1_x     <= x_x;
      f1_off   <= x_off;
      f1_proto <= x_proto;
      f1_tag   <= tag5 && !c5.pos[0];
      f1_ver   <= x_ver_ok;
      f1_et    <= x_et_ok;
      f1_tcp   <= x_tcp;
      f1_udp   <= x_udp;
      f1_frag  <= x_frag;
      f1_short <= c5.lt4;
      f1_ovf   <= c5.idx[8];
      f1_cfg   <= c5.cfg;

      f2_aneg  <= ({1'b0, f1_fl} < {6'd0, f1_x, 2'b10});
      f2_bneg  <= ({4'd0, f1_fl} < f1_l4e);
      f2_lneg  <= (f1_tl < {10'd0, f1_ihl, 2'b00});
      f2_l4len <= f1_tl - {10'd0, f1_ihl, 2'b00};
      f2_ihl5  <= f1_ihl[3] || (f1_ihl[2] && (f1_ihl[1] || f1_ihl[0]));
      f2_fl    <= f1_fl;
      f2_x     <= f1_x;
      f2_off   <= f1_off;
      f2_proto <= f1_proto;
      f2_tag   <= f1_tag;
      f2_ver   <= f1_ver;
      f2_et    <= f1_et;
      f2_tcp   <= f1_tcp;
      f2_udp   <= f1_udp;
      f2_frag  <= f1_frag;
      f2_short <= f1_short;
      f2_ovf   <= f1_ovf;
      f2_cfg   <= f1_cfg;

      f3_hdr   <= f2_et && f2_ver && f2_ihl5 && !f2_aneg && !f2_short && !f2_ovf;
      f3_ipv4  <= f2_et && f2_ver && !f2_short && !f2_ovf;
      f3_g8a   <= |f2_l4len[15:8];                       // L4 length >= 256
      f3_g8b   <= |f2_l4len[7:3];                        // L4 length >= 8 within the low byte
      f3_g20b  <= (|f2_l4len[7:5]) || (f2_l4len[4] && (f2_l4len[3] || f2_l4len[2]));   // >= 20 within the low byte
      f3_lneg  <= f2_lneg;
      f3_bneg  <= f2_bneg;
      f3_extra <= {1'b0, f2_l4len} + {9'd0, f2_proto};
      f3_fl    <= f2_fl;
      f3_x     <= f2_x;
      f3_off   <= f2_off;
      f3_tag   <= f2_tag;
      f3_tcp   <= f2_tcp;
      f3_udp   <= f2_udp;
      f3_frag  <= f2_frag;
      f3_ovf   <= f2_ovf;
      f3_cfg   <= f2_cfg;

      f4.hdr_ok  <= f3_hdr;
      f4.is_ipv4 <= f3_ipv4;
      f4.l4_cand <= f3_hdr && (f3_tcp || f3_udp) && !f3_frag;
      f4.l4_elig <= f3_hdr && (f3_tcp || f3_udp) && !f3_frag && !f3_lneg && !f3_bneg
                    && (f3_g8a || (f3_udp ? f3_g8b : f3_g20b));
      f4.tag     <= f3_tag;
      f4.tcp     <= f3_tcp && f3_ipv4;
      f4.udp     <= f3_udp && f3_ipv4;
      f4.frag    <= f3_frag && f3_ipv4;
      f4.ovf     <= f3_ovf;
      f4.cfg     <= f3_cfg;
      f4.fl      <= f3_fl;
      f4.l4s     <= {f3_x, 2'b10};
      f4.off     <= f3_off;
    end
  end

  // Static fields wait for the sums: extra to J1, bundle to the result stage.
  logic [16:0] j_extra;
  bun_t        r_bun;

  rtlnet_shift_reg_core #(
    .DATA_W (17),
    .DEPTH  (4)
  ) u_extra_dly (
    .clk (clk),
    .ce  (en),
    .d   (f3_extra),
    .q   (j_extra)
  );

  rtlnet_shift_reg_core #(
    .DATA_W ($bits(bun_t)),
    .DEPTH  (6)
  ) u_bundle_dly (
    .clk (clk),
    .ce  (en),
    .d   (f4),
    .q   (r_bun)
  );

  // ---------------------------------------------------------------------------
  // Finish J1..J3, R
  // ---------------------------------------------------------------------------
  logic [16:0] j1_ip = '0;
  logic [25:0] j1_l4 = '0;
  logic        j1_fa = 1'b0, j1_fb = 1'b0;
  logic [15:0] j2_ip = '0;
  logic [16:0] j2_l4 = '0;
  logic        j2_fnz = 1'b0;
  logic [15:0] j3_ip = '0, j3_l4 = '0;
  logic        j3_ipg = 1'b0, j3_fnz = 1'b0;
  logic [3:0]  jv = '0;                   // done strobe through J1, J2, J3, R

  always_ff @(posedge clk) begin
    if (!resetn) jv <= '0;
    else if (en) jv <= {jv[2:0], acc_done};
  end

  always_ff @(posedge clk) begin
    if (en) begin
      j1_ip  <= {1'b0, acc_ip[15:0]} + {7'd0, acc_ip[25:16]};
      j1_l4  <= acc_l4 + {9'd0, j_extra};
      j1_fa  <= |acc_fl[15:8];
      j1_fb  <= |acc_fl[7:0];
      j2_ip  <= j1_ip[15:0] + {15'd0, j1_ip[16]};
      j2_l4  <= {1'b0, j1_l4[15:0]} + {7'd0, j1_l4[25:16]};
      j2_fnz <= j1_fa || j1_fb;
      j3_ip  <= j2_ip;
      j3_ipg <= (j2_ip == 16'hFFFF);
      j3_l4  <= j2_l4[15:0] + {15'd0, j2_l4[16]};
      j3_fnz <= j2_fnz;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      res_v <= 1'b0;
    end else if (en) begin
      res_v <= jv[2];
    end
  end

  always_ff @(posedge clk) begin
    if (en) begin
      res_ip_fold   <= j3_ip;
      res_ip_good   <= j3_ipg;
      res_l4_fold   <= j3_l4;
      res_l4_good   <= (j3_l4 == 16'hFFFF);
      res_udp_none  <= RX_MODE && r_bun.udp && !j3_fnz;
      res_cfg       <= r_bun.cfg;
      res_tag       <= r_bun.tag;
      res_is_ipv4   <= r_bun.is_ipv4;
      res_is_tcp    <= r_bun.tcp;
      res_is_udp    <= r_bun.udp;
      res_frag      <= r_bun.frag;
      res_hdr_valid <= r_bun.hdr_ok;
      res_l4_cand   <= r_bun.l4_cand;
      res_l4_elig   <= r_bun.l4_elig;
      res_len       <= r_bun.fl[11:0];
      res_l4s       <= r_bun.l4s;
      res_l4c       <= r_bun.off;
      res_ovf       <= r_bun.ovf;
    end
  end

  // Simulation-only check of the latency contract.
  // synthesis translate_off
  logic [ANALYZE_LAT-1:0] chk_pipe = '0;
  always @(posedge clk) begin
    if (!resetn) chk_pipe <= '0;
    else if (en) begin
      chk_pipe <= {chk_pipe[ANALYZE_LAT-2:0], fire && s_last};
      if (res_v !== chk_pipe[ANALYZE_LAT-1]) $fatal(1, "%m: result strobe not ANALYZE_LAT clocks after the final beat");
    end
  end
  // synthesis translate_on

endmodule
