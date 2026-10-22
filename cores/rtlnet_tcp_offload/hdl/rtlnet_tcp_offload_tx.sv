// -----------------------------------------------------------------------------
// File: rtlnet_tcp_offload_tx.sv
// Purpose: egress half of rtlnet_tcp_offload (CPU DMA MM2S -> offload -> CPU
//   TX FIFO): inserts the IPv4 header checksum and the TCP / UDP checksum into
//   frames the CPU sends with those fields unfilled.
// Overview:
//   * Store and forward. The checksum fields precede the data they cover, so a
//     frame is written whole into rtlnet_packet_fifo (u_tx_fifo, TX_BUF_KB) while
//     rtlnet_tcp_offload_analyze streams over the same beats. When the engine's
//     result is ready (ANALYZE_LAT + 1 clocks after the final beat) one
//     sideband entry per frame is written: {ip_en, l4_en, tag, the beat of
//     the L4 checksum field, its lane mask, IPv4 checksum, L4 checksum}.
//   * Sideband queue: rtlnet_ram_core (SB_RAM_STYLE), depth twice the number of
//     frame slots (an entry exists only for a frame that holds a slot). The head
//     entry is read continuously; sb_ok says the head word is valid.
//   * Read side: a frame's first beat leaves the packet FIFO only when sb_ok
//     is high; the entry is then copied to cur_* and popped. For every beat taken the
//     patch flags of that beat are registered with it (beat 3 for the IPv4
//     checksum, the entry's beat for the L4 checksum, one 2-byte lane pair each);
//     the next stage replaces those byte lanes with the checksum bytes.
//   * Pass-through: with both enables clear in CTRL at a frame's first beat,
//     the entry carries ip_en = l4_en = 0 and every byte is untouched. The
//     CTRL value is sampled at the first beat of each frame.
//   * The IPv4 checksum is ~sum of the header with its own field as zero. The L4
//     checksum is ~sum of pseudo-header + segment with its field as zero; a UDP
//     result of 0x0000 is sent as 0xFFFF. Bytes after the IP total length (Ethernet
//     padding) are not summed. L4 is skipped (counted) for fragments and other
//     protocols; frames with inconsistent lengths are skipped and counted as
//     malformed. Frames longer than a buffer slot (256 beats) are dropped and counted.
//   * Throughput: one beat per clock; the packet FIFO inserts one idle clock
//     between frames on its read side. The first frame after idle sees the
//     analysis latency; with TX_BUF_KB 4 (two slots) frames shorter than the
//     latency leave gaps, a larger TX_BUF_KB removes them (see the core guide).
//   * All outputs are flops (output rtlnet_axis_reg_slice).
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk; resetn synchronous, active low.
// -----------------------------------------------------------------------------
module rtlnet_tcp_offload_tx #(
  parameter string RAM_STYLE       = "block",       // frame buffer: "block" | "distributed"
  parameter string SB_RAM_STYLE    = "distributed", // sideband queue
  parameter int    TX_BUF_KB       = 4,             // frame buffer, kilobytes (two 2 KiB slots per 4)
  parameter int    MAX_FRAME_BYTES = 1518
)(
  // Clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Insert enables from the register file (sampled at each frame's first beat).
  input  logic        cfg_ip,
  input  logic        cfg_l4,

  // Frames from the CPU DMA, RTLNet stream (s_axis_tready is a flop).
  input  logic [63:0] s_axis_tdata,
  input  logic [7:0]  s_axis_tkeep,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  // Frames to the CPU TX FIFO, RTLNet stream (all outputs registered).
  output logic [63:0] m_axis_tdata,
  output logic [7:0]  m_axis_tkeep,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  // Status and one-clock event pulses (registered).
  output logic        idle,
  output logic        ev_frame,
  output logic        ev_ip,
  output logic        ev_l4,
  output logic        ev_skip,
  output logic        ev_malf,
  output logic        ev_drop
);

  import rtlnet_tcp_offload_pkg::*;

  // Geometry shared with rtlnet_packet_fifo (slot = 2**WORD_BITS words).
  localparam int WORD_BITS = rtlnet_pkg::clog2i((MAX_FRAME_BYTES + 7) / 8);
  localparam int SLOTS     = (TX_BUF_KB * 128) >> WORD_BITS;
  localparam int SB_BITS   = rtlnet_pkg::clog2i(SLOTS) + 1;
  localparam int SB_W      = 47;

  generate
    if (WORD_BITS != 8) begin : g_bad_frame
      $fatal(1, "rtlnet_tcp_offload_tx: MAX_FRAME_BYTES=%0d must give 256-word slots (1025..2048 bytes)", MAX_FRAME_BYTES);
    end
    if (SLOTS < 2) begin : g_bad_slots
      $fatal(1, "rtlnet_tcp_offload_tx: TX_BUF_KB=%0d holds %0d slots, need at least 2", TX_BUF_KB, SLOTS);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Input slice and frame buffer
  // ---------------------------------------------------------------------------
  logic [63:0] in_d;
  logic [7:0]  in_k;
  logic        in_v;
  logic        in_l;
  logic        fifo_rdy;
  logic [63:0] ff_d;
  logic [7:0]  ff_k;
  logic        ff_v;
  logic        ff_l;
  logic        ff_rdy;

  // Registered ready towards the DMA; its output register feeds the FIFO and the engine.
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
    .m_tready (fifo_rdy)
  );

  // Whole frames in, whole frames out; back-pressure only between frames (never drops).
  rtlnet_packet_fifo #(
    .RAM_STYLE       (RAM_STYLE),
    .FIFO_KB         (TX_BUF_KB),
    .MAX_FRAME_BYTES (MAX_FRAME_BYTES),
    .DROP_WHEN_FULL  (1'b0)
  ) u_tx_fifo (
    .s_clk     (clk),
    .s_resetn  (resetn),
    .s_data    (in_d),
    .s_keep    (in_k),
    .s_valid   (in_v),
    .s_ready   (fifo_rdy),
    .s_last    (in_l),
    .s_bad     (1'b0),
    .m_clk     (clk),
    .m_resetn  (resetn),
    .m_data    (ff_d),
    .m_keep    (ff_k),
    .m_valid   (ff_v),
    .m_ready   (ff_rdy),
    .m_last    (ff_l),
    .overflow  (),
    .bad_frame ()
  );

  // ---------------------------------------------------------------------------
  // Checksum engine on the beats the FIFO accepts
  // ---------------------------------------------------------------------------
  logic        fire;
  logic        an_fire = 1'b0;
  logic [63:0] an_d = '0;
  logic [7:0]  an_k = '0;
  logic        an_l = 1'b0;
  logic        r_v;
  logic [1:0]  r_cfg;
  logic        r_tag, r_ipv4, r_udp, r_hdr, r_cand, r_elig, r_l4good, r_ovf;
  logic [15:0] r_ipfold, r_l4fold;
  logic [6:0]  r_l4c;

  assign fire = in_v && fifo_rdy;

  // One register stage between the buffer's (combinational) ready and the engine.
  always_ff @(posedge clk) begin
    if (!resetn) an_fire <= 1'b0;
    else         an_fire <= fire;
    an_d <= in_d;
    an_k <= in_k;
    an_l <= in_l;
  end

  rtlnet_tcp_offload_analyze #(
    .RX_MODE (1'b0)
  ) u_an (
    .clk           (clk),
    .resetn        (resetn),
    .en            (1'b1),
    .fire          (an_fire),
    .s_data        (an_d),
    .s_keep        (an_k),
    .s_last        (an_l),
    .cfg_in        ({cfg_l4, cfg_ip}),
    .res_v         (r_v),
    .res_cfg       (r_cfg),
    .res_tag       (r_tag),
    .res_is_ipv4   (r_ipv4),
    .res_is_tcp    (),
    .res_is_udp    (r_udp),
    .res_frag      (),
    .res_hdr_valid (r_hdr),
    .res_l4_cand   (r_cand),
    .res_l4_elig   (r_elig),
    .res_udp_none  (),
    .res_ip_good   (),
    .res_l4_good   (r_l4good),
    .res_ip_fold   (r_ipfold),
    .res_l4_fold   (r_l4fold),
    .res_len       (),
    .res_l4s       (),
    .res_l4c       (r_l4c),
    .res_ovf       (r_ovf)
  );

  // ---------------------------------------------------------------------------
  // Consumer stage: sideband entry and events (visible TX_SB_LAT clocks after the final beat)
  // ---------------------------------------------------------------------------
  logic            sb_wr = 1'b0;
  logic [SB_W-1:0] sb_wd = '0;

  // Entry layout (SB_W bits): [0] ip_en, [1] l4_en, [2] tag, [6:3] l4_beat, [14:7] l4 lane mask,
  // [30:15] IPv4 checksum, [46:31] L4 checksum.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      sb_wr    <= 1'b0;
      sb_wd    <= '0;
      ev_frame <= 1'b0;
      ev_ip    <= 1'b0;
      ev_l4    <= 1'b0;
      ev_skip  <= 1'b0;
      ev_malf  <= 1'b0;
      ev_drop  <= 1'b0;
    end else begin
      sb_wr <= r_v && !r_ovf;
      sb_wd[0]     <= r_cfg[0] && r_hdr;
      sb_wd[1]     <= r_cfg[1] && r_elig;
      sb_wd[2]     <= r_tag;
      sb_wd[6:3]   <= r_l4c[6:3];
      for (int l = 0; l < 8; l++) sb_wd[7 + l] <= (r_l4c[2:1] == 2'(l / 2));
      sb_wd[30:15] <= ~r_ipfold;
      sb_wd[46:31] <= ~r_l4fold | {16{r_udp && r_l4good}};
      ev_frame <= r_v && !r_ovf;
      ev_ip    <= r_v && !r_ovf && r_cfg[0] && r_hdr;
      ev_l4    <= r_v && !r_ovf && r_cfg[1] && r_elig;
      ev_skip  <= r_v && !r_ovf && r_cfg[1] && r_hdr && !r_cand;
      ev_malf  <= r_v && !r_ovf && (r_cfg[0] || r_cfg[1]) && r_ipv4 && (!r_hdr || (r_cfg[1] && r_cand && !r_elig));
      ev_drop  <= r_v && r_ovf;
    end
  end

  // ---------------------------------------------------------------------------
  // Sideband queue
  // ---------------------------------------------------------------------------
  logic [SB_BITS:0]  sb_wptr = '0;
  logic [SB_BITS:0]  sb_rptr = '0;
  logic              sb_ok   = 1'b0;
  logic              sb_pop;
  logic [SB_W-1:0]   sb_rd;

  rtlnet_ram_core #(
    .RAM_STYLE    (SB_RAM_STYLE),
    .CLOCKING     ("COMMON"),
    .DATA_W       (SB_W),
    .ADDR_W       (SB_BITS),
    .READ_LATENCY (1)
  ) u_sb_ram (
    .wr_clk    (clk),
    .wr_en     (sb_wr),
    .wr_addr   (sb_wptr[SB_BITS-1:0]),
    .wr_data   (sb_wd),
    .rd_clk    (clk),
    .rd_resetn (resetn),
    .rd_en     (1'b1),
    .rd_addr   (sb_rptr[SB_BITS-1:0]),
    .rd_data   (sb_rd)
  );

  // The head word is valid one clock after the pointers show an entry, provided the
  // read pointer did not move in between.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      sb_wptr <= '0;
      sb_rptr <= '0;
      sb_ok   <= 1'b0;
    end else begin
      if (sb_wr)  sb_wptr <= sb_wptr + 1'b1;
      if (sb_pop) sb_rptr <= sb_rptr + 1'b1;
      sb_ok <= (sb_wptr != sb_rptr) && !sb_pop;
    end
  end

  // ---------------------------------------------------------------------------
  // Read side: gate a frame's first beat on its sideband entry, flag the beats to patch
  // ---------------------------------------------------------------------------
  logic        rd_first = 1'b1;
  logic [3:0]  rd_idx   = '0;
  logic        cur_ip_en = 1'b0, cur_l4_en = 1'b0, cur_tag = 1'b0;
  logic [3:0]  cur_beat = '0;
  logic [7:0]  cur_lmask = '0;
  logic [15:0] cur_ip_csum = '0, cur_l4_csum = '0;

  logic        go_ok;
  logic        p_v = 1'b0;
  logic        p_can;
  logic        take;
  logic [63:0] p_d = '0;
  logic [7:0]  p_k = '0;
  logic        p_l = 1'b0;
  logic [7:0]  p_rep_ip = '0, p_rep_l4 = '0;
  logic        o_rdy;

  assign go_ok  = !rd_first || sb_ok;
  assign p_can  = !p_v || o_rdy;
  assign ff_rdy = go_ok && p_can;
  assign take   = ff_v && ff_rdy;
  assign sb_pop = take && rd_first;

  // Patch stage register: the FIFO beat with its byte-lane replace flags.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      rd_first    <= 1'b1;
      rd_idx      <= '0;
      p_v         <= 1'b0;
      p_rep_ip    <= '0;
      p_rep_l4    <= '0;
      cur_ip_en   <= 1'b0;
      cur_l4_en   <= 1'b0;
    end else begin
      if (o_rdy) p_v <= 1'b0;
      if (take) begin
        p_v  <= 1'b1;
        p_d  <= ff_d;
        p_k  <= ff_k;
        p_l  <= ff_l;
        rd_first <= ff_l;
        rd_idx   <= ff_l ? 4'd0 : ((rd_idx == 4'd15) ? rd_idx : rd_idx + 4'd1);
        if (rd_first) begin
          cur_ip_en   <= sb_rd[0];
          cur_l4_en   <= sb_rd[1];
          cur_tag     <= sb_rd[2];
          cur_beat     <= sb_rd[6:3];
          cur_lmask   <= sb_rd[14:7];
          cur_ip_csum <= sb_rd[30:15];
          cur_l4_csum <= sb_rd[46:31];
        end
        // The IPv4 checksum is in beat 3 (lanes 0,1 untagged; 4,5 tagged); the L4 field in the entry's beat.
        for (int l = 0; l < 8; l++) begin
          p_rep_ip[l] <= (rd_idx == 4'd3) && !rd_first && cur_ip_en && (cur_tag ? (l == 4 || l == 5) : (l == 0 || l == 1));
          p_rep_l4[l] <= (rd_idx == cur_beat) && !rd_first && cur_l4_en && cur_lmask[l];
        end
      end
    end
  end

  // Byte-lane replace between the patch register and the output slice.
  logic [63:0] q_d;

  always_comb begin
    for (int l = 0; l < 8; l++) begin
      if (p_rep_ip[l])      q_d[8*l +: 8] = (l % 2 == 0) ? cur_ip_csum[15:8] : cur_ip_csum[7:0];
      else if (p_rep_l4[l]) q_d[8*l +: 8] = (l % 2 == 0) ? cur_l4_csum[15:8] : cur_l4_csum[7:0];
      else                  q_d[8*l +: 8] = p_d[8*l +: 8];
    end
  end

  rtlnet_axis_reg_slice #(
    .DATA_W (64)
  ) u_out_slice (
    .clk      (clk),
    .resetn   (resetn),
    .s_tdata  (q_d),
    .s_tkeep  (p_k),
    .s_tlast  (p_l),
    .s_tvalid (p_v),
    .s_tready (o_rdy),
    .m_tdata  (m_axis_tdata),
    .m_tkeep  (m_axis_tkeep),
    .m_tlast  (m_axis_tlast),
    .m_tvalid (m_axis_tvalid),
    .m_tready (m_axis_tready)
  );

  // ---------------------------------------------------------------------------
  // Idle: no frame accepted by the buffer and not yet delivered
  // ---------------------------------------------------------------------------
  logic [5:0] inflight = '0;
  logic       in_first = 1'b1;
  logic       inc_q = 1'b0;
  logic       dec_q = 1'b0;

  // Frame start and frame end events are registered before they count (keeps the buffer's
  // ready logic out of the counter), and idle waits for them.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      inflight <= '0;
      in_first <= 1'b1;
      inc_q    <= 1'b0;
      dec_q    <= 1'b0;
      idle     <= 1'b1;
    end else begin
      if (an_fire) in_first <= an_l;
      inc_q <= an_fire && in_first;
      dec_q <= (take && ff_l) || ev_drop;
      case ({inc_q, dec_q})
        2'b10:   inflight <= inflight + 6'd1;
        2'b01:   inflight <= inflight - 6'd1;
        default: inflight <= inflight;
      endcase
      idle <= (inflight == 6'd0) && !in_v && !p_v && !m_axis_tvalid && !inc_q && !dec_q && !an_fire;
    end
  end

  // Simulation-only checks: the sideband queue never overflows and never underflows.
  // synthesis translate_off
  logic [SB_BITS:0] sb_cnt;
  assign sb_cnt = sb_wptr - sb_rptr;

  always @(posedge clk) begin
    if (resetn) begin
      if (sb_wr && (sb_cnt >= (SB_BITS+1)'(SLOTS))) $fatal(1, "%m: sideband queue holds more entries than frame slots");
      if (sb_pop && (sb_wptr == sb_rptr)) $fatal(1, "%m: sideband queue underflow");
    end
  end
  // synthesis translate_on

endmodule
