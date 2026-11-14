// -----------------------------------------------------------------------------
// File: rtlnet_tcp_offload_ackco.sv
// Purpose: ACK coalescing on the CPU receive stream (frames followed by the 8-byte checksum trailer of
//   rtlnet_tcp_offload_rx): pure TCP acknowledgements of one flow are held back and only the newest one per
//   interval is forwarded, so the CPU handles one acknowledgement instead of many.
// Overview:
//   * Position: after rtlnet_tcp_offload_rx, before the batcher / the DMA. A frame is a coalescing candidate
//     only when its trailer says IPv4, TCP, not a fragment, not VLAN, IPv4 header and TCP checksum verified good
//     (trailer flags & 0xFF == 0xE3), and its bytes say: IHL 5, TCP flags exactly ACK (0x10, reserved bits 0),
//     no payload (IP total length 40 with no TCP options, or 52 with exactly the NOP NOP timestamp option
//     01 01 08 0A). Every other option layout (SACK blocks, MSS, window scale, ...) is not a candidate: an
//     allow-list, so no unknown option can be swallowed.
//   * Flow table: FLOWS entries keyed by the 4-tuple (source and destination address and port). A candidate of an
//     unknown flow takes an invalid entry, else the least recently used one (a held ACK of the victim is
//     forwarded first). Per entry: key, held slot, held ack and seq, last candidate ack, coalesce count, start
//     time, LRU rank.
//   * Rules for a candidate N of a known flow:
//       held ACK H present:
//         ack(N) > ack(H) and seq(N) >= seq(H) (32-bit sequence space)  -> H is dropped, N is held (count + 1);
//             when the count reaches the limit register N is forwarded at once instead (flush by limit)
//         otherwise (same ack: duplicate ACK or window update; lower ack; lower seq: keep-alive or old ACK)
//             -> H is forwarded, then N is forwarded at once (order kept, flush by ordering)
//       no held ACK:
//         ack(N) equal to or lower than the last candidate ack of the flow -> forwarded at once
//         (a duplicate ACK is never delayed: fast retransmit counts them)
//         otherwise N is held and its timer starts.
//     Equal acknowledgement numbers are never dropped, so duplicate ACKs and window updates always reach the
//     CPU. A newer ACK carries the newest window and timestamp, so replacing the older one loses nothing.
//   * Any non-candidate frame of a held flow (data, bad checksum, other flags) first forwards the held ACK. A
//     TCP frame whose flow cannot be read (VLAN tag, IP options, fragment) or a frame without trailer forwards
//     every held ACK. Frames of other flows and non-TCP frames are never delayed.
//   * A held ACK is forwarded when its age reaches the timer register (microseconds), when the count limit is
//     reached, when the feature is switched off (all held ACKs), or by the rules above.
//   * Datapath: the first ACK_HEAD_BEATS (10) beats of every frame are staged in a slot of 16 beats (one RAM,
//     FLOWS + 2 slots); a frame of up to 10 beats (candidate, ARP, short frames) is decided as a whole, a longer
//     frame is decided on its head and the rest passes cut-through after the head. Slots are never copied: a
//     held ACK stays in its slot, a replaced one frees its slot. Output order: emit queue, one frame at a time.
//   * A timer flush forgets the flow's last ACK; switching the feature off forgets the whole table.
//   * Disabled (cfg_en low at a frame's first beat) every frame passes unchanged (bit-identical, latency and
//     frame period grow by the staging).
//   * Events (one clock pulses): candidates seen, held ACKs dropped, candidate ACKs forwarded, flushes by timer /
//     limit / ordering. At idle: candidates = dropped + forwarded.
//   * Sideband s_ttrl / m_ttrl: the frame carries a trailer (follows every beat of the frame).
// Language: SystemVerilog-2012.
// Revision: 11-14-2026
//   * 11-14-2026: initial version.
// Clocks: clk; resetn synchronous, active low.
// -----------------------------------------------------------------------------
module rtlnet_tcp_offload_ackco #(
  parameter int    FLOWS     = 4,             // flow table entries, 2..16
  parameter string RAM_STYLE = "distributed"  // slot RAM (FLOWS + 2 slots of 16 beats, 128 bytes each)
)(
  // Clock and synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Configuration from the register file and the microsecond tick (one clock pulse per microsecond).
  input  logic        cfg_en,
  input  logic [15:0] cfg_timer_us,
  input  logic [7:0]  cfg_limit,
  input  logic        us_tick,

  // Frames in (RTLNet stream plus the trailer sideband, tready combinational from state flops).
  input  logic [63:0] s_tdata,
  input  logic [7:0]  s_tkeep,
  input  logic        s_tvalid,
  input  logic        s_tlast,
  input  logic        s_ttrl,
  output logic        s_tready,

  // Frames out (all outputs registered).
  output logic [63:0] m_tdata,
  output logic [7:0]  m_tkeep,
  output logic        m_tvalid,
  output logic        m_tlast,
  output logic        m_ttrl,
  input  logic        m_tready,

  // Status and one-clock event pulses (registered).
  output logic        idle,
  output logic        ev_cand,
  output logic        ev_drop,
  output logic        ev_fwd,
  output logic        ev_fl_timer,
  output logic        ev_fl_limit,
  output logic        ev_fl_order
);

  import rtlnet_tcp_offload_pkg::*;

  localparam int SLOTS  = FLOWS + 2;
  localparam int SLOT_W = $clog2(SLOTS);
  localparam int FW     = $clog2(FLOWS);
  localparam int ADDR_W = SLOT_W + 4;
  localparam int HEAD   = ACK_HEAD_BEATS;
  localparam int QCW    = $clog2(SLOTS + 1);

  // Candidate shape constants (byte offsets from the frame start, all fields big endian on the wire).
  localparam logic [7:0]  ETH_IPV4_HI = 8'h08;
  localparam logic [7:0]  IPV4_IHL5   = 8'h45;
  localparam logic [7:0]  PROTO_TCP   = 8'h06;
  localparam logic [7:0]  FLAGS_ACK   = 8'h10;
  localparam logic [7:0]  DO_5WORDS   = 8'h50;
  localparam logic [7:0]  DO_8WORDS   = 8'h80;
  localparam logic [15:0] TL_NOOPT    = 16'd40;
  localparam logic [15:0] TL_TS       = 16'd52;
  localparam logic [15:0] OPT_NOPNOP  = 16'h0101;   // {byte 55, byte 54}
  localparam logic [15:0] OPT_TS      = 16'h0A08;   // {byte 57, byte 56}: kind 8, length 10
  localparam logic [7:0]  TRF_CAND    = 8'hE3;      // ipv4 tcp !udp !vlan !frag ip_ok l4_ok verified
  localparam int          ETH_HDR     = 14;

  generate
    if (FLOWS < 2 || FLOWS > 16) begin : g_bad_flows
      $fatal(1, "rtlnet_tcp_offload_ackco: FLOWS=%0d, must be 2..16", FLOWS);
    end
  endgenerate

  // Input state machine.
  localparam logic [2:0] S_ARB   = 3'd0;
  localparam logic [2:0] S_CAP   = 3'd1;
  localparam logic [2:0] S_DEC1  = 3'd2;
  localparam logic [2:0] S_DEC2  = 3'd3;
  localparam logic [2:0] S_FLUSH = 3'd4;
  localparam logic [2:0] S_FINAL = 3'd5;
  localparam logic [2:0] S_TAIL  = 3'd6;

  // Final action of a frame.
  localparam logic [1:0] FM_EMIT       = 2'd0;   // forward the staged frame
  localparam logic [1:0] FM_HOLD       = 2'd1;   // hold it as the flow's ACK
  localparam logic [1:0] FM_REPL       = 2'd2;   // it replaces the held ACK
  localparam logic [1:0] FM_REPL_FLUSH = 2'd3;   // it replaces the held ACK and is forwarded (count limit)

  // Flush cause.
  localparam logic [1:0] FC_ORDER = 2'd0;
  localparam logic [1:0] FC_TIMER = 2'd1;

  // Output state machine.
  localparam logic [1:0] O_IDLE = 2'd0;
  localparam logic [1:0] O_HEAD = 2'd1;
  localparam logic [1:0] O_TAIL = 2'd2;

  // ---------------------------------------------------------------------------
  // Sequence-space compare: a is after b.
  // ---------------------------------------------------------------------------
  function automatic logic seq_gt(input logic [31:0] a, input logic [31:0] b);
    logic [31:0] d;
    d = a - b;
    return (d != 32'd0) && !d[31];
  endfunction

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic [2:0]        state = S_ARB;
  logic              stg_v;
  logic [SLOT_W-1:0] stg;
  logic [3:0]        bcnt;
  logic              f_en;
  logic              f_long;
  logic [15:0]       now_us = '0;

  // Slot bookkeeping.
  logic [SLOTS-1:0]  sfree;
  logic [3:0]        sl_nb   [0:SLOTS-1] = '{default: '0};
  logic [7:0]        sl_keep [0:SLOTS-1] = '{default: '0};
  logic              sl_e    [0:SLOTS-1] = '{default: 1'b0};

  // Parsed fields of the frame being staged (cleared at its start).
  logic              p_et_ok = 1'b0, p_vlan = 1'b0, p_ihl45 = 1'b0, p_tcp = 1'b0, p_fragfree = 1'b0;
  logic [15:0]       p_tl = '0;
  logic [31:0]       p_sip = '0, p_dip = '0;
  logic [15:0]       p_sport = '0, p_dport = '0;
  logic [31:0]       p_seq = '0, p_ack = '0;
  logic [7:0]        p_do = '0, p_flags = '0;
  logic [15:0]       p_opt0 = '0, p_opt1 = '0;
  logic [15:0]       p_tflags = '0, p_tlen = '0;
  logic [95:0]       pkey;

  assign pkey = {p_sip, p_dip, p_sport, p_dport};

  // Flow table.
  logic [FLOWS-1:0]  fl_valid;
  logic [95:0]       fl_key    [0:FLOWS-1] = '{default: '0};
  logic [FLOWS-1:0]  held;
  logic [SLOT_W-1:0] h_slot    [0:FLOWS-1] = '{default: '0};
  logic [31:0]       h_ack     [0:FLOWS-1] = '{default: '0};
  logic [31:0]       h_seq     [0:FLOWS-1] = '{default: '0};
  logic [7:0]        h_cnt     [0:FLOWS-1] = '{default: '0};
  logic [15:0]       h_start   [0:FLOWS-1] = '{default: '0};
  logic [31:0]       l_ack     [0:FLOWS-1] = '{default: '0};
  logic [FLOWS-1:0]  l_valid;
  logic [3:0]        rank      [0:FLOWS-1];
  logic [FLOWS-1:0]  exp_r;

  // Decision pipeline registers.
  logic              cand_q, keyok_q, flushall_q;
  logic [FLOWS-1:0]  hit_v, gt_held_v, ge_seq_v, gt_last_v;
  logic [FLOWS-1:0]  fl_mask;
  logic [1:0]        fcause;
  logic              fl_to_final;
  logic [1:0]        fin_mode;
  logic [FW-1:0]     tf;
  logic              is_cand;
  logic              new_flow;
  logic              gt_last_q;

  // Emit queue.
  logic [SLOT_W-1:0] q_slot [0:SLOTS-1] = '{default: '0};
  logic              q_tail [0:SLOTS-1] = '{default: 1'b0};
  logic [QCW-1:0]    q_cnt;
  logic [SLOT_W-1:0] q_wr, q_rd;
  logic              q_push;
  logic [SLOT_W-1:0] q_push_slot;
  logic              q_push_tail;
  logic              q_pop;
  logic              q_full;

  // Output state.
  logic [1:0]        o_state = O_IDLE;
  logic [SLOT_W-1:0] o_slot = '0;
  logic [3:0]        o_nb;
  logic [3:0]        o_bi;
  logic              o_tail = 1'b0;
  logic              o_e = 1'b0;
  logic [7:0]        o_klast = '0;
  logic              d_v;
  logic [3:0]        d_idx;
  logic              o_rdy;
  logic [63:0]       rd_data;
  logic              rd_en;
  logic              wr_en;
  logic              o_free;
  logic [SLOT_W-1:0] o_free_slot;

  // ---------------------------------------------------------------------------
  // Combinational helpers
  // ---------------------------------------------------------------------------
  logic              held_any;
  logic              exp_any;
  logic [FLOWS-1:0]  exp_vec;
  logic              free_any;
  logic [SLOT_W-1:0] free_idx;

  assign q_full   = (q_cnt == QCW'(SLOTS));
  assign held_any = |held;
  assign exp_vec  = exp_r & held;
  assign exp_any  = |exp_vec;

  always_comb begin
    free_any = 1'b0;
    free_idx = '0;
    for (int i = SLOTS - 1; i >= 0; i--) begin
      if (sfree[i]) begin
        free_any = 1'b1;
        free_idx = SLOT_W'(i);
      end
    end
  end

  // Lowest set flow in the flush mask.
  logic              fm_any;
  logic [FW-1:0]     fm_idx;

  always_comb begin
    fm_any = 1'b0;
    fm_idx = '0;
    for (int i = FLOWS - 1; i >= 0; i--) begin
      if (fl_mask[i]) begin
        fm_any = 1'b1;
        fm_idx = FW'(i);
      end
    end
  end

  // Decision (state S_DEC2): everything below is a function of the S_DEC1 registers.
  logic              d_hit_any;
  logic [FW-1:0]     d_hit_idx;
  logic              d_inv_any;
  logic [FW-1:0]     d_inv_idx;
  logic [FW-1:0]     d_lru_idx;
  logic [FW-1:0]     d_vic;
  logic [FW-1:0]     d_flow;
  logic              d_held;
  logic              d_replace_ok;
  logic              d_lim_hit;
  logic              d_last_v;
  logic              d_gt_last;
  logic [FLOWS-1:0]  d_mask;
  logic [1:0]        d_fin;
  logic              d_new;

  always_comb begin
    d_hit_any = 1'b0;
    d_hit_idx = '0;
    d_inv_any = 1'b0;
    d_inv_idx = '0;
    d_lru_idx = '0;
    for (int i = FLOWS - 1; i >= 0; i--) begin
      if (hit_v[i]) begin
        d_hit_any = 1'b1;
        d_hit_idx = FW'(i);
      end
      if (!fl_valid[i]) begin
        d_inv_any = 1'b1;
        d_inv_idx = FW'(i);
      end
      if (rank[i] == 4'(FLOWS - 1)) d_lru_idx = FW'(i);
    end
    d_vic  = d_inv_any ? d_inv_idx : d_lru_idx;
    d_new  = cand_q && !d_hit_any;
    d_flow = d_hit_any ? d_hit_idx : d_vic;
    d_held = held[d_flow] && !d_new;
    d_replace_ok = gt_held_v[d_flow] && ge_seq_v[d_flow];
    d_lim_hit    = ({1'b0, h_cnt[d_flow]} + 9'd1) >= {1'b0, cfg_limit};
    d_last_v     = l_valid[d_flow] && !d_new;
    d_gt_last    = gt_last_v[d_flow];
    d_mask = '0;
    d_fin  = FM_EMIT;
    if (!cand_q) begin
      if (flushall_q) d_mask = held;
      else if (keyok_q && d_hit_any && held[d_hit_idx]) d_mask[d_hit_idx] = 1'b1;
    end else if (d_new) begin
      if (held[d_vic]) d_mask[d_vic] = 1'b1;   // evict: forward the victim's held ACK first
      d_fin = FM_HOLD;
    end else if (d_held) begin
      if (d_replace_ok) d_fin = d_lim_hit ? FM_REPL_FLUSH : FM_REPL;
      else begin
        d_mask[d_flow] = 1'b1;
        d_fin = FM_EMIT;
      end
    end else begin
      d_fin = (d_last_v && !d_gt_last) ? FM_EMIT : FM_HOLD;
    end
  end

  // ---------------------------------------------------------------------------
  // Slot RAM
  // ---------------------------------------------------------------------------
  rtlnet_ram_core #(
    .RAM_STYLE    (RAM_STYLE),
    .CLOCKING     ("COMMON"),
    .DATA_W       (64),
    .ADDR_W       (ADDR_W),
    .READ_LATENCY (1)
  ) u_slots (
    .wr_clk    (clk),
    .wr_en     (wr_en),
    .wr_addr   ({stg, bcnt}),
    .wr_data   (s_tdata),
    .rd_clk    (clk),
    .rd_resetn (resetn),
    .rd_en     (rd_en),
    .rd_addr   ({o_slot, o_bi}),
    .rd_data   (rd_data)
  );

  // The tail of a long frame passes straight to the output slice.
  logic tail_pass;
  logic accept;
  assign tail_pass = (state == S_TAIL) && (o_state == O_TAIL);
  assign s_tready  = (state == S_CAP) || (tail_pass && o_rdy);
  assign accept    = s_tvalid && s_tready;
  assign wr_en     = (state == S_CAP) && accept;

  // ---------------------------------------------------------------------------
  // Microsecond clock
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn)      now_us <= '0;
    else if (us_tick) now_us <= now_us + 16'd1;
  end

  // Held ACK timers: sticky expiry flag per flow.
  always_ff @(posedge clk) begin
    for (int i = 0; i < FLOWS; i++) begin
      if (!resetn || !held[i])                                       exp_r[i] <= 1'b0;
      else if ((now_us - h_start[i]) >= cfg_timer_us)                exp_r[i] <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Slot free bookkeeping
  // ---------------------------------------------------------------------------
  logic [SLOTS-1:0] free_set;
  logic [SLOTS-1:0] alloc_clr;
  logic             repl_free;
  logic [SLOT_W-1:0] repl_slot;

  assign repl_free = (state == S_FINAL) && ((fin_mode == FM_REPL) || (fin_mode == FM_REPL_FLUSH)) &&
                     (fin_mode == FM_REPL ? 1'b1 : !q_full);
  assign repl_slot = h_slot[tf];

  always_comb begin
    free_set  = '0;
    alloc_clr = '0;
    if (o_free)    free_set[o_free_slot] = 1'b1;
    if (repl_free) free_set[repl_slot]   = 1'b1;
    if ((state == S_ARB) && !(!cfg_en && held_any) && !exp_any && s_tvalid && free_any) alloc_clr[free_idx] = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Emit queue push (S_FLUSH one held ACK, S_FINAL the staged frame)
  // ---------------------------------------------------------------------------
  always_comb begin
    q_push      = 1'b0;
    q_push_slot = '0;
    q_push_tail = 1'b0;
    if (state == S_FLUSH && fm_any && !q_full) begin
      q_push      = 1'b1;
      q_push_slot = h_slot[fm_idx];
    end else if (state == S_FINAL && !q_full && (fin_mode == FM_EMIT || fin_mode == FM_REPL_FLUSH)) begin
      q_push      = 1'b1;
      q_push_slot = stg;
      q_push_tail = f_long;
    end
  end

  // ---------------------------------------------------------------------------
  // Input state machine: arbitration, capture, decision, flush, final action, tail
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    ev_cand     <= 1'b0;
    ev_drop     <= 1'b0;
    ev_fwd      <= 1'b0;
    ev_fl_timer <= 1'b0;
    ev_fl_limit <= 1'b0;
    ev_fl_order <= 1'b0;
    if (!resetn) begin
      state       <= S_ARB;
      stg_v       <= 1'b0;
      stg         <= '0;
      bcnt        <= '0;
      f_en        <= 1'b0;
      f_long      <= 1'b0;
      fl_valid    <= '0;
      held        <= '0;
      l_valid     <= '0;
      fl_mask     <= '0;
      fcause      <= FC_ORDER;
      fl_to_final <= 1'b0;
      fin_mode    <= FM_EMIT;
      tf          <= '0;
      is_cand     <= 1'b0;
      new_flow    <= 1'b0;
      gt_last_q   <= 1'b0;
      cand_q      <= 1'b0;
      keyok_q     <= 1'b0;
      flushall_q  <= 1'b0;
      hit_v       <= '0;
      gt_held_v   <= '0;
      ge_seq_v    <= '0;
      gt_last_v   <= '0;
      for (int i = 0; i < FLOWS; i++) rank[i] <= 4'(i);
    end else begin
      case (state)
        // Between frames: flush requests first (feature off, expired timers), then start the next frame.
        S_ARB: begin
          // Switched off: the flow table is forgotten (a later enable starts clean).
          if (!cfg_en) begin
            fl_valid <= '0;
            l_valid  <= '0;
          end
          if (!cfg_en && held_any) begin
            fl_mask     <= held;
            fcause      <= FC_ORDER;
            fl_to_final <= 1'b0;
            state       <= S_FLUSH;
          end else if (exp_any) begin
            fl_mask     <= exp_vec;
            fcause      <= FC_TIMER;
            fl_to_final <= 1'b0;
            state       <= S_FLUSH;
          end else if (s_tvalid && free_any) begin
            stg    <= free_idx;
            bcnt   <= '0;
            f_en   <= cfg_en;
            f_long <= 1'b0;
            p_et_ok    <= 1'b0;
            p_vlan     <= 1'b0;
            p_ihl45    <= 1'b0;
            p_tcp      <= 1'b0;
            p_fragfree <= 1'b0;
            p_tl       <= '0;
            p_do       <= '0;
            p_flags    <= '0;
            p_opt0     <= '0;
            p_opt1     <= '0;
            p_tflags   <= '0;
            p_tlen     <= '0;
            state      <= S_CAP;
          end
        end

        // Stage the frame: beats into the slot RAM, header fields into registers.
        S_CAP: begin
          if (accept) begin
            sl_keep[stg] <= s_tkeep;
            if (bcnt == 4'd0) sl_e[stg] <= s_ttrl;
            case (bcnt)
              4'd1: begin
                p_et_ok <= (s_tdata[39:32] == ETH_IPV4_HI) && (s_tdata[47:40] == 8'h00);
                p_vlan  <= (s_tdata[39:32] == 8'h81) && (s_tdata[47:40] == 8'h00);
                p_ihl45 <= (s_tdata[55:48] == IPV4_IHL5);
              end
              4'd2: begin
                p_tl       <= {s_tdata[7:0], s_tdata[15:8]};
                p_fragfree <= (({s_tdata[39:32], s_tdata[47:40]} & 16'h3FFF) == 16'h0000);
                p_tcp      <= (s_tdata[63:56] == PROTO_TCP);
              end
              4'd3: begin
                p_sip[31:0]  <= s_tdata[47:16];
                p_dip[15:0]  <= s_tdata[63:48];
              end
              4'd4: begin
                p_dip[31:16] <= s_tdata[15:0];
                p_sport      <= s_tdata[31:16];
                p_dport      <= s_tdata[47:32];
                p_seq[31:16] <= {s_tdata[55:48], s_tdata[63:56]};
              end
              4'd5: begin
                p_seq[15:0] <= {s_tdata[7:0], s_tdata[15:8]};
                p_ack       <= {s_tdata[23:16], s_tdata[31:24], s_tdata[39:32], s_tdata[47:40]};
                p_do        <= s_tdata[55:48];
                p_flags     <= s_tdata[63:56];
              end
              4'd6: p_opt0 <= s_tdata[63:48];
              4'd7: p_opt1 <= s_tdata[15:0];
              default: ;
            endcase
            bcnt <= bcnt + 4'd1;
            if (s_tlast) begin
              sl_nb[stg] <= bcnt + 4'd1;
              f_long     <= 1'b0;
              if (s_ttrl) begin
                p_tflags <= s_tdata[47:32];
                p_tlen   <= s_tdata[15:0];
              end
              state <= S_DEC1;
            end else if (bcnt == 4'(HEAD - 1)) begin
              sl_nb[stg] <= 4'(HEAD);
              f_long     <= 1'b1;
              state      <= S_DEC1;
            end
          end
        end

        // Compare against the flow table, evaluate the candidate rules (registered).
        S_DEC1: begin
          cand_q <= f_en && sl_e[stg] && !f_long && (p_tflags[7:0] == TRF_CAND) &&
                    ({1'b0, p_tlen} >= (17'(p_tl) + 17'(ETH_HDR))) &&
                    p_et_ok && p_ihl45 && p_tcp && p_fragfree && (p_flags == FLAGS_ACK) &&
                    ( ((p_do == DO_5WORDS) && (p_tl == TL_NOOPT)) ||
                      ((p_do == DO_8WORDS) && (p_tl == TL_TS) && (p_opt0 == OPT_NOPNOP) && (p_opt1 == OPT_TS)) );
          keyok_q <= f_en && p_et_ok && p_ihl45 && p_tcp && p_fragfree;
          flushall_q <= !f_en || !sl_e[stg] || p_vlan || (p_et_ok && p_tcp && !(p_ihl45 && p_fragfree));
          for (int i = 0; i < FLOWS; i++) begin
            hit_v[i]     <= fl_valid[i] && (fl_key[i] == pkey);
            gt_held_v[i] <= seq_gt(p_ack, h_ack[i]);
            ge_seq_v[i]  <= !seq_gt(h_seq[i], p_seq);
            gt_last_v[i] <= seq_gt(p_ack, l_ack[i]);
          end
          state <= S_DEC2;
        end

        // Decide: which held ACKs to flush first, and what happens to the staged frame.
        S_DEC2: begin
          fl_mask     <= d_mask;
          fcause      <= FC_ORDER;
          fl_to_final <= 1'b1;
          fin_mode    <= d_fin;
          tf          <= d_flow;
          is_cand     <= cand_q;
          new_flow    <= d_new;
          gt_last_q   <= d_gt_last || d_new;
          state       <= S_FLUSH;
        end

        // Forward held ACKs one per clock into the emit queue.
        S_FLUSH: begin
          if (fm_any) begin
            if (!q_full) begin
              fl_mask[fm_idx] <= 1'b0;
              held[fm_idx]    <= 1'b0;
              ev_fwd          <= 1'b1;
              if (fcause == FC_TIMER) begin
                ev_fl_timer      <= 1'b1;
                l_valid[fm_idx]  <= 1'b0;   // an idle flow starts clean: its next ACK is held, not compared to an old one
              end else begin
                ev_fl_order <= 1'b1;
              end
            end
          end else begin
            state <= fl_to_final ? S_FINAL : S_ARB;
          end
        end

        // Final action on the staged frame.
        S_FINAL: begin
          case (fin_mode)
            FM_EMIT: begin
              if (!q_full) begin
                if (is_cand) begin
                  ev_cand <= 1'b1;
                  ev_fwd  <= 1'b1;
                end
                state <= f_long ? S_TAIL : S_ARB;
              end
            end
            FM_HOLD: begin
              if (new_flow) begin
                fl_valid[tf] <= 1'b1;
                fl_key[tf]   <= pkey;
              end
              held[tf]    <= 1'b1;
              h_slot[tf]  <= stg;
              h_ack[tf]   <= p_ack;
              h_seq[tf]   <= p_seq;
              h_cnt[tf]   <= 8'd0;
              h_start[tf] <= now_us;
              ev_cand     <= 1'b1;
              state       <= S_ARB;
            end
            FM_REPL: begin
              h_slot[tf] <= stg;
              h_ack[tf]  <= p_ack;
              h_seq[tf]  <= p_seq;
              h_cnt[tf]  <= h_cnt[tf] + 8'd1;
              ev_cand    <= 1'b1;
              ev_drop    <= 1'b1;
              state      <= S_ARB;
            end
            FM_REPL_FLUSH: begin
              if (!q_full) begin
                held[tf]    <= 1'b0;
                ev_cand     <= 1'b1;
                ev_drop     <= 1'b1;
                ev_fwd      <= 1'b1;
                ev_fl_limit <= 1'b1;
                state       <= S_ARB;
              end
            end
            default: state <= S_ARB;
          endcase
          if (is_cand) begin
            if (!l_valid[tf] || gt_last_q) l_ack[tf] <= p_ack;
            l_valid[tf] <= 1'b1;
            for (int i = 0; i < FLOWS; i++) begin
              if (FW'(i) == tf) rank[i] <= 4'd0;
              else if (rank[i] < rank[tf]) rank[i] <= rank[i] + 4'd1;
            end
          end
        end

        // The rest of a long frame passes through after its head; done at the last beat.
        S_TAIL: begin
          if (accept && s_tlast) state <= S_ARB;
        end

        default: state <= S_ARB;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Slot allocation flags
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) sfree <= '1;
    else         sfree <= (sfree & ~alloc_clr) | free_set;
  end

  // ---------------------------------------------------------------------------
  // Emit queue
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      q_cnt <= '0;
      q_wr  <= '0;
      q_rd  <= '0;
    end else begin
      if (q_push) begin
        q_slot[q_wr] <= q_push_slot;
        q_tail[q_wr] <= q_push_tail;
        q_wr         <= (q_wr == SLOT_W'(SLOTS - 1)) ? '0 : q_wr + 1'b1;
      end
      if (q_pop) q_rd <= (q_rd == SLOT_W'(SLOTS - 1)) ? '0 : q_rd + 1'b1;
      q_cnt <= q_cnt + QCW'(q_push) - QCW'(q_pop);
    end
  end

  // ---------------------------------------------------------------------------
  // Output state machine: pop a frame, read its head from the slot RAM (prefetch, one beat ahead), then
  // pass the tail of a long frame from the input.
  // ---------------------------------------------------------------------------
  logic        consume;
  logic        last_beat;
  logic        rd_issue;
  logic [63:0] sl_data;
  logic [7:0]  sl_k;
  logic        sl_l;
  logic        sl_v;
  logic        sl_e_out;

  assign consume   = d_v && o_rdy && (o_state == O_HEAD);
  assign last_beat = (d_idx == (o_nb - 4'd1));
  assign rd_issue  = (o_state == O_HEAD) && (o_bi != o_nb) && (!d_v || o_rdy);
  assign rd_en     = rd_issue;
  assign q_pop     = (o_state == O_IDLE) && (q_cnt != '0);
  assign o_free    = consume && last_beat;
  assign o_free_slot = o_slot;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      o_state <= O_IDLE;
      d_v     <= 1'b0;
      o_bi    <= '0;
      o_nb    <= '0;
      d_idx   <= '0;
    end else begin
      case (o_state)
        O_IDLE: begin
          if (q_cnt != '0) begin
            o_slot  <= q_slot[q_rd];
            o_tail  <= q_tail[q_rd];
            o_nb    <= sl_nb[q_slot[q_rd]];
            o_e     <= sl_e[q_slot[q_rd]];
            o_klast <= sl_keep[q_slot[q_rd]];
            o_bi    <= '0;
            d_v     <= 1'b0;
            o_state <= O_HEAD;
          end
        end
        O_HEAD: begin
          if (rd_issue) begin
            o_bi  <= o_bi + 4'd1;
            d_idx <= o_bi;
            d_v   <= 1'b1;
          end else if (consume) begin
            d_v <= 1'b0;
          end
          if (consume && last_beat) begin
            d_v     <= 1'b0;
            o_state <= o_tail ? O_TAIL : O_IDLE;
          end
        end
        O_TAIL: begin
          if (accept && s_tlast && (state == S_TAIL)) o_state <= O_IDLE;
        end
        default: o_state <= O_IDLE;
      endcase
    end
  end

  // Beat into the output slice.
  always_comb begin
    if (o_state == O_TAIL) begin
      sl_v     = s_tvalid && (state == S_TAIL);
      sl_data  = s_tdata;
      sl_k     = s_tkeep;
      sl_l     = s_tlast;
    end else begin
      sl_v     = (o_state == O_HEAD) && d_v;
      sl_data  = rd_data;
      sl_k     = last_beat ? o_klast : 8'hFF;
      sl_l     = last_beat && !o_tail;
    end
    sl_e_out = o_e;
  end

  logic [71:0] os_d;
  logic [8:0]  os_k;

  rtlnet_axis_reg_slice #(
    .DATA_W (72)
  ) u_out_slice (
    .clk      (clk),
    .resetn   (resetn),
    .s_tdata  ({7'd0, sl_e_out, sl_data}),
    .s_tkeep  ({1'b0, sl_k}),
    .s_tlast  (sl_l),
    .s_tvalid (sl_v),
    .s_tready (o_rdy),
    .m_tdata  (os_d),
    .m_tkeep  (os_k),
    .m_tlast  (m_tlast),
    .m_tvalid (m_tvalid),
    .m_tready (m_tready)
  );

  assign m_tdata = os_d[63:0];
  assign m_ttrl  = os_d[64];
  assign m_tkeep = os_k[7:0];

  // ---------------------------------------------------------------------------
  // Idle: nothing held, nothing staged or queued, output empty.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) idle <= 1'b1;
    else         idle <= !held_any && (state == S_ARB) && !s_tvalid && (q_cnt == '0) && (o_state == O_IDLE) &&
                         !m_tvalid && !d_v;
  end

endmodule
