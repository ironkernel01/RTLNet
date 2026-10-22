// -----------------------------------------------------------------------------
// File: rtlnet_tcp_offload_rx.sv
// Purpose: ingress half of rtlnet_tcp_offload (classifier output -> offload ->
//   AXI DMA S2MM): computes the IPv4 header check and the TCP / UDP checksum
//   while a frame streams and delivers the result in an 8-byte trailer beat
//   after the frame. No frame store, no drop: the CPU decides.
// Overview:
//   * Cut-through. The frame's beats enter a delay line of RX_DELAY slots
//     (rtlnet_shift_reg_core for the data, flip-flops for the valid chain) while
//     rtlnet_tcp_offload_analyze runs over the same beats in line time; the
//     result reaches the trailer register in the clock the frame's final beat
//     reaches the end of the line. The line advances only while the output slice
//     can take a beat and no trailer is pending, and the engine advances with it.
//   * With CTRL.rx_csum set at a frame's first beat the frame leaves with its
//     final data beat padded to 8 bytes (tkeep 0xFF, pad bytes 0, tlast clear)
//     followed by one trailer beat (tkeep 0xFF, tlast). The trailer is always at
//     byte offset roundup8(frame length). Every frame gets one, IP or not.
//   * Trailer, little-endian 64-bit word:
//       [15:0]  frame length in bytes (before padding)
//       [31:16] folded ones'-complement sum of pseudo-header + segment, checksum
//               field included (0xFFFF for a correct segment); 0 unless a TCP/UDP
//               segment inside the frame was summed
//       [47:32] flags: b0 is_ipv4, b1 is_tcp, b2 is_udp, b3 vlan, b4 fragment,
//               b5 ip_ok, b6 l4_ok, b7 verified (both checks were possible), rest 0
//       [55:48] L4 offset from the frame start (0 unless the IPv4 header is valid)
//       [63:56] marker 0xA5 (upper nibble 0xA: trailer, lower nibble 5: layout version)
//   * With rx_csum clear at a frame's first beat the frame passes bit-exact (the
//     enable changes only at frame boundaries).
//   * Cost: one beat per frame (the trailer). The final data beat is padded in
//     place, so there is no padding beat.
//   * All outputs are flops (output rtlnet_axis_reg_slice).
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk; resetn synchronous, active low.
// -----------------------------------------------------------------------------
module rtlnet_tcp_offload_rx (
  // Clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // CTRL.rx_csum from the register file (sampled at each frame's first beat).
  input  logic        cfg_rx,

  // Frames from the classifier, RTLNet stream (s_axis_tready is a flop).
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // Frames (and trailers) to the DMA, RTLNet stream (all outputs registered).
  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  // Status and one-clock event pulses (registered).
  output logic        idle,
  output logic        ev_frame,
  output logic        ev_verified,
  output logic        ev_ip_bad,
  output logic        ev_l4_bad,
  output logic        ev_unverified
);

  import rtlnet_tcp_offload_pkg::*;

  localparam int DL = RX_DELAY;

  // ---------------------------------------------------------------------------
  // Input slice and the line enable
  // ---------------------------------------------------------------------------
  logic [63:0] in_d;
  logic [7:0]  in_k;
  logic        in_v;
  logic        in_l;
  logic        adv;
  logic        o_rdy;
  logic        tr_pend = 1'b0;

  rtlnet_axis_reg_slice #(
    .DATA_W (64)
  ) u_in_slice (
    .clk      (clk),
    .resetn   (resetn),
    .s_tdata  (s_axis_tdata),
    .s_tkeep  (s_axis_tkeep),
    .s_tlast  (s_axis_tlast),
    .s_tvalid (s_axis_tvalid),
    .s_tready (s_axis_tready),
    .m_tdata  (in_d),
    .m_tkeep  (in_k),
    .m_tlast  (in_l),
    .m_tvalid (in_v),
    .m_tready (adv)
  );

  // The line advances when the output can take a beat and no trailer is waiting.
  assign adv = o_rdy && !tr_pend;

  // rx_csum is sampled at a frame's first beat and applies to the whole frame.
  logic rx_first = 1'b1;
  logic rx_fen   = 1'b0;
  logic beat_en;

  assign beat_en = rx_first ? cfg_rx : rx_fen;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      rx_first <= 1'b1;
      rx_fen   <= 1'b0;
    end else if (adv && in_v) begin
      rx_first <= in_l;
      if (rx_first) rx_fen <= cfg_rx;
    end
  end

  // ---------------------------------------------------------------------------
  // Delay line and engine
  // ---------------------------------------------------------------------------
  logic [DL-1:0] v_ch = '0;
  logic [63:0]   le_d;
  logic [7:0]    le_k;
  logic          le_l;
  logic          le_en;
  logic          le_v;

  rtlnet_shift_reg_core #(
    .DATA_W (74),
    .DEPTH  (DL)
  ) u_line (
    .clk (clk),
    .ce  (adv),
    .d   ({beat_en, in_l, in_k, in_d}),
    .q   ({le_en, le_l, le_k, le_d})
  );

  always_ff @(posedge clk) begin
    if (!resetn)  v_ch <= '0;
    else if (adv) v_ch <= {v_ch[DL-2:0], in_v};
  end

  assign le_v = v_ch[DL-1];

  logic        r_v;
  logic        r_tag, r_ipv4, r_tcp, r_udp, r_frag, r_hdr, r_elig, r_unone, r_ipg, r_l4g;
  logic [15:0] r_l4fold;
  logic [11:0] r_len;
  logic [6:0]  r_l4s;

  rtlnet_tcp_offload_analyze #(
    .RX_MODE (1'b1)
  ) u_an (
    .clk           (clk),
    .resetn        (resetn),
    .en            (adv),
    .fire          (in_v),
    .s_data        (in_d),
    .s_keep        (in_k),
    .s_last        (in_l),
    .cfg_in        (2'b00),
    .res_v         (r_v),
    .res_cfg       (),
    .res_tag       (r_tag),
    .res_is_ipv4   (r_ipv4),
    .res_is_tcp    (r_tcp),
    .res_is_udp    (r_udp),
    .res_frag      (r_frag),
    .res_hdr_valid (r_hdr),
    .res_l4_cand   (),
    .res_l4_elig   (r_elig),
    .res_udp_none  (r_unone),
    .res_ip_good   (r_ipg),
    .res_l4_good   (r_l4g),
    .res_ip_fold   (),
    .res_l4_fold   (r_l4fold),
    .res_len       (r_len),
    .res_l4s       (r_l4s),
    .res_l4c       (),
    .res_ovf       ()
  );

  // ---------------------------------------------------------------------------
  // Trailer register (aligned with the final beat at the end of the line)
  // ---------------------------------------------------------------------------
  logic [63:0] trl = '0;
  logic        t_ipok, t_verified, t_l4ok;

  assign t_ipok     = r_hdr && r_ipg;
  assign t_verified = r_hdr && r_elig && !r_unone;
  assign t_l4ok     = t_verified && r_l4g;

  always_ff @(posedge clk) begin
    if (adv) begin
      trl[TRL_LEN_LSB +: 16]   <= {4'd0, r_len};
      trl[TRL_SUM_LSB +: 16]   <= r_elig ? r_l4fold : 16'd0;
      trl[TRL_FLAGS_LSB +: 16] <= {8'd0, t_verified, t_l4ok, t_ipok, r_frag, r_tag, r_udp, r_tcp, r_ipv4};
      trl[TRL_L4OFF_LSB +: 8]  <= r_hdr ? {1'b0, r_l4s} : 8'd0;
      trl[TRL_MARKER_LSB +: 8] <= TRAILER_MARKER;
    end
  end

  // ---------------------------------------------------------------------------
  // Output: padded data beats, then the trailer beat
  // ---------------------------------------------------------------------------
  logic [63:0] tr_data = '0;
  logic [63:0] o_d;
  logic [7:0]  o_k;
  logic        o_l;
  logic        o_v;
  logic        deliver_last;

  assign deliver_last = adv && le_v && le_l && le_en;

  always_comb begin
    for (int l = 0; l < 8; l++) o_d[8*l +: 8] = le_en ? (le_d[8*l +: 8] & {8{le_k[l]}}) : le_d[8*l +: 8];
    o_k = (le_en && le_l) ? 8'hFF : le_k;
    o_l = le_l && !le_en;
    o_v = le_v;
  end

  // A pending trailer is presented until the slice takes it; the line is stopped meanwhile.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      tr_pend <= 1'b0;
    end else if (deliver_last) begin
      tr_pend <= 1'b1;
    end else if (tr_pend && o_rdy) begin
      tr_pend <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (deliver_last) tr_data <= trl;
  end

  rtlnet_axis_reg_slice #(
    .DATA_W (64)
  ) u_out_slice (
    .clk      (clk),
    .resetn   (resetn),
    .s_tdata  (tr_pend ? tr_data : o_d),
    .s_tkeep  (tr_pend ? 8'hFF : o_k),
    .s_tlast  (tr_pend ? 1'b1 : o_l),
    .s_tvalid (tr_pend || o_v),
    .s_tready (o_rdy),
    .m_tdata  (m_axis_tdata),
    .m_tkeep  (m_axis_tkeep),
    .m_tlast  (m_axis_tlast),
    .m_tvalid (m_axis_tvalid),
    .m_tready (m_axis_tready)
  );

  // ---------------------------------------------------------------------------
  // Events (from the trailer flags as the final beat leaves) and idle
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      ev_frame      <= 1'b0;
      ev_verified   <= 1'b0;
      ev_ip_bad     <= 1'b0;
      ev_l4_bad     <= 1'b0;
      ev_unverified <= 1'b0;
      idle          <= 1'b1;
    end else begin
      ev_frame      <= deliver_last;
      ev_verified   <= deliver_last && trl[TRL_FLAGS_LSB + TRLF_VERIFIED] && trl[TRL_FLAGS_LSB + TRLF_IP_OK]
                       && trl[TRL_FLAGS_LSB + TRLF_L4_OK];
      ev_ip_bad     <= deliver_last && trl[TRL_FLAGS_LSB + TRLF_IS_IPV4] && !trl[TRL_FLAGS_LSB + TRLF_IP_OK];
      ev_l4_bad     <= deliver_last && trl[TRL_FLAGS_LSB + TRLF_VERIFIED] && !trl[TRL_FLAGS_LSB + TRLF_L4_OK];
      ev_unverified <= deliver_last && !trl[TRL_FLAGS_LSB + TRLF_VERIFIED];
      idle          <= !(|v_ch) && !tr_pend && !in_v && !m_axis_tvalid;
    end
  end

endmodule
