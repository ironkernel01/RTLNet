// -----------------------------------------------------------------------------
// File: rtlnet_h264_ring_wr.sv
// Purpose: compressed-ring writer of the H.264 encoder: gathers the packer's NAL byte stream into
//   16-byte words, cuts them into AXI bursts in the compressed ring, keeps the ring pointers and the
//   fill level, and writes the index entry of every slice and every picture.
// Overview:
//   * Ring: ring_base, ring_size (bytes, multiple of 16). The write position wpos is a byte offset in the
//     ring. Bytes are accepted while fill < ring_size (the full guard: the writer stalls and never
//     overwrites unread data). Firmware reports consumption by writing the read pointer (a byte
//     offset); the new fill is fill - ((rptr - old rptr) mod ring_size). A step of the whole ring size
//     is not representable; firmware advances in steps smaller than the ring. A read pointer at or beyond ring_size, or a step larger than
//     the fill, is ignored and pulses err_rptr.
//   * Words: bytes fill a 16-byte word lane by lane (lane = wpos[3:0]). A word is pushed to the word
//     FIFO when its last lane is written or when a NAL unit ends (a partial word carries byte strobes; the
//     next bytes continue in the same 16-byte slot with their own strobes, so the stream stays contiguous).
//   * Bursts: consecutive pushed words form one burst of at most 16 beats that never crosses a 4 KiB
//     boundary or the ring end and always ends at a NAL unit end. A descriptor (address, beats-1, byte
//     count) goes to the write master; the data beats come from the word FIFO.
//   * wptr (ring_wptr) is the position after the last burst whose write response arrived, so every byte
//     below it is visible in memory.
//   * Index ring: idx_base, idx_entries entries of 16 bytes. Entry words, little endian, word 0 first:
//       word 0  byte offset in the ring of the first byte of the NAL unit (the start code)
//               (picture entry: of the picture's first NAL unit, the access unit delimiter)
//       word 1  length in bytes, start code and emulation-prevention bytes included
//               (picture entry: all NAL units of the picture)
//       word 2  [15:0] picture number, [31:16] slice number (picture entry: number of slices)
//       word 3  [7:0] slice type, [15:8] QP, [16] last slice of the picture, [17] IDR picture,
//               [24] entry kind (0 slice, 1 picture)
//     A slice entry is written when its NAL unit is complete in the ring (all response beats back);
//     the picture entry follows the last slice's entry. idx_wptr is the index of the next entry
//     to be written, advanced after the entry's write response; idx_rptr_wr reports consumed entries.
//     A full index ring stalls the entry writer, and through it the packer.
//   * Overflow and underflow of every queue are gated in logic; a simulation check reports an attempt
//     (an accepted byte with the ring full is one of them).
// Language: SystemVerilog-2012.
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_ring_wr #(
  parameter int    ADDR_W    = 32,
  parameter int    FIFO_KB   = 1,
  parameter string RAM_STYLE = "block"
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // Ring and index-ring configuration, clk domain: stable while a picture runs. ring_reset pulses to
  // clear the pointers, the fill level and the index counters (use with the ring empty).
  input  logic [ADDR_W-1:0] ring_base,
  input  logic [31:0]       ring_size,
  input  logic [ADDR_W-1:0] idx_base,
  input  logic [31:0]       idx_entries,
  input  logic              ring_reset,

  // Read pointers written by firmware, clk domain: rptr_wr pulses with the new byte offset, idx_rptr_wr
  // with the new entry index.
  input  logic              rptr_wr,
  input  logic [31:0]       rptr_val,
  input  logic              idx_rptr_wr,
  input  logic [31:0]       idx_rptr_val,

  // NAL byte stream from the bit packer, clk domain: a byte moves in a clock with u_valid and u_ready high. u_ready is a
  // register (a two-entry skid buffer sits between the stream and the writer).
  input  logic              u_valid,
  output logic              u_ready,
  input  logic [7:0]        u_data,
  input  logic              u_first,
  input  logic              u_last,
  input  logic              u_kind,

  // Metadata of the slice in the packer, clk domain: sampled when the slice's last byte is accepted.
  input  logic [15:0]       m_pic,
  input  logic [15:0]       m_slice,
  input  logic [15:0]       m_nslices,
  input  logic [7:0]        m_qp,
  input  logic [7:0]        m_type,
  input  logic              m_idr,
  input  logic              m_last_slice,

  // Ring burst to the write master, clk domain: descriptor valid with address and beats-1; the master pops it
  // with rg_pop and then takes the beats with rg_w_pop.
  output logic              rg_valid,
  output logic [ADDR_W-1:0] rg_addr,
  output logic [3:0]        rg_len,
  input  logic              rg_pop,
  output logic              rg_w_valid,
  output logic [127:0]      rg_w_data,
  output logic [15:0]       rg_w_strb,
  input  logic              rg_w_pop,

  // Index entry to the write master, clk domain: one 16-byte beat; ix_ack pulses when it is taken.
  output logic              ix_valid,
  output logic [ADDR_W-1:0] ix_addr,
  output logic [127:0]      ix_data,
  input  logic              ix_ack,

  // Write response events from the write master, clk domain, one clock each.
  input  logic              ev_b_ring_i,
  input  logic              ev_b_idx_i,

  // Status, clk domain: ring write pointer (visible data), fill in bytes, index write pointer (entry
  // index), index fill in entries; nal_done pulses the clock after a NAL unit's last byte is accepted;
  // ring_stall is high while a byte waits only because the ring is full; idle is high when nothing is
  // pending anywhere in the writer; err_rptr pulses on a rejected read-pointer write.
  output logic [31:0]       ring_wptr,
  output logic [31:0]       ring_fill,
  output logic [31:0]       idx_wptr,
  output logic [31:0]       idx_fill_o,
  output logic              nal_done,
  output logic              ring_stall,
  output logic              idle,
  output logic              err_rptr
);

  import rtlnet_h264_pkg::*;

  localparam int FDEPTH = (FIFO_KB * 1024) / 16;
  localparam int FAW    = $clog2(FDEPTH);
  localparam int DQD    = 4;
  localparam int IFD    = 8;
  localparam int EQD    = 4;
  localparam int BURST_MAX_BEATS = 16;

  // Gather state.
  logic [31:0]  wpos;
  logic [127:0] wdat;
  logic [15:0]  wmask;
  logic [31:0]  fill;
  logic [31:0]  total;
  logic [31:0]  rptr_q;
  logic [31:0]  wptr_vis;
  logic [31:0]  comp_total;
  logic [31:0]  nal_start_off;
  logic [31:0]  nal_start_total;
  logic [31:0]  pic_start_off;
  logic [31:0]  pic_start_total;
  logic [4:0]   b_beats;
  logic [ADDR_W-1:0] b_addr;
  logic [9:0]   bb;

  // Word FIFO (RAM) and its first-word-fall-through adapter.
  logic [FAW-1:0] ff_wp;
  logic [FAW-1:0] ff_rp;
  logic [FAW:0]   ff_cnt;
  logic           ff_rd_en;
  logic [143:0]   ff_rd_data;
  logic           rd_infl;
  logic           q_valid;
  logic [143:0]   q_data;

  // Descriptor queue and in-flight byte queue.
  logic [ADDR_W-1:0] dq_addr [DQD];
  logic [3:0]        dq_len  [DQD];
  logic [9:0]        dq_bytes[DQD];
  logic [1:0]        dq_wp;
  logic [1:0]        dq_rp;
  logic [2:0]        dq_cnt;
  logic [9:0]        ifq [IFD];
  logic [2:0]        ifq_wp;
  logic [2:0]        ifq_rp;
  logic [3:0]        ifq_cnt;

  // Index entry queue.
  logic [31:0]  eq_w0 [EQD];
  logic [31:0]  eq_w1 [EQD];
  logic [31:0]  eq_w2 [EQD];
  logic [31:0]  eq_w3 [EQD];
  logic [31:0]  eq_end[EQD];
  logic [1:0]   eq_wp;
  logic [1:0]   eq_rp;
  logic [2:0]   eq_cnt;
  logic         pic_pend;
  logic         pic_open;
  logic [31:0]  pe_off;
  logic [31:0]  pe_len;
  logic [31:0]  pe_end;
  logic [31:0]  pe_w2;
  logic [31:0]  pe_w3;

  // Index ring state.
  logic [31:0]  idx_wr_off;
  logic [31:0]  idx_fill;
  logic [31:0]  idx_vis;
  logic [31:0]  idx_rq;
  logic [3:0]   idx_infl;

  // Combinational.
  // Input skid buffer: m_* is the byte the writer works on (i_*), k_* holds a byte that arrived while m_* was stalled.
  logic         m_valid;
  logic [10:0]  m_pack;
  logic         k_valid;
  logic [10:0]  k_pack;
  logic         in_fire;
  logic         i_valid;
  logic         i_ready;
  logic [7:0]   i_data;
  logic         i_first;
  logic         i_last;
  logic         i_kind;
  logic         accept;
  logic         ring_room;
  logic         ff_space;
  logic         ff_space_q;
  logic         dq_space_q;
  logic         eq_space_q;
  logic [ADDR_W-1:0] waddr_q;
  logic         dq_space;
  logic         eq_space;
  logic [3:0]   lane;
  logic         full_word;
  logic         push;
  logic [127:0] wdat_m;
  logic [15:0]  wmask_m;
  logic [ADDR_W-1:0] waddr;
  logic [4:0]   beats_n;
  logic [ADDR_W-1:0] start_addr;
  logic         close;
  logic [31:0]  wpos_inc;
  logic         slice_last;
  logic         eq_push;
  logic [31:0]  ent_w0;
  logic [31:0]  ent_w1;
  logic [31:0]  ent_w2;
  logic [31:0]  ent_w3;
  logic [31:0]  ent_end;
  logic         cons_ok;
  logic         rptr_apply;
  logic         icons_ok;
  logic         idx_apply;

  // Read-pointer pipeline: stage 1 captures the write, stage 2 computes the step (new pointer minus old, modulo
  // the ring) and its range check, stage 3 (cs_v, ics_v) compares the step with the fill level and applies it.
  logic         rq_v;
  logic [31:0]  rq_val;
  logic         cs_v;
  logic [31:0]  cs_val;
  logic [31:0]  cs_newp;
  logic         cs_range;
  logic         iq_v;
  logic [31:0]  iq_val;
  logic         ics_v;
  logic [31:0]  ics_val;
  logic [31:0]  ics_newp;
  logic         ics_range;
  logic         err_q;

  // Ring position: bytes left up to the ring end (loaded with ring_size at ring_reset) and the registered room flag
  // (fill below ring_size - 4: a byte accepted from a flag one clock old cannot overfill the ring).
  logic [31:0]  to_end;
  logic         at_end_q;
  logic [31:0]  room_lim;
  logic         room_q;
  logic         comp_ok;
  // Only the sign bit of the difference is used (serial-number comparison of the byte totals).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0]  comp_diff;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0]  idx_limit;
  logic         ix_take;
  logic         comp_ok_q;
  logic         idle_c;
  logic         idx_room_q;
  logic         take_q;
  // Write responses, registered once, and the ring-response handler: pending count, then two clocks per response.
  logic         ev_b_ring;
  logic         ev_b_idx;
  logic [3:0]   b_pend;
  logic         b_start;
  logic         p1;
  logic [3:0]   bi_pend;
  logic         bi_start;
  logic         pi1;
  logic         pi2;
  logic [31:0]  pi_sum;
  logic [31:0]  pi_next;
  logic [9:0]   p1_bytes;
  logic [31:0]  p1_sum;

  assign ring_wptr  = wptr_vis;
  assign ring_fill  = fill;
  assign idx_wptr   = idx_vis;
  assign idx_fill_o = idx_fill;

  // ---------------------------------------------------------------------------
  // Byte acceptance and word gather
  // ---------------------------------------------------------------------------
  assign u_ready = !k_valid;
  assign in_fire = u_valid && u_ready;
  assign i_valid = m_valid;
  assign {i_kind, i_last, i_first, i_data} = m_pack;
  assign ring_room = room_q;
  // Registered space flags with margins for the one clock of staleness (one push, descriptor or entry pair per clock).
  assign ff_space  = ff_space_q;
  assign dq_space  = dq_space_q;
  assign eq_space  = eq_space_q;
  assign i_ready   = ring_room && ff_space && dq_space && eq_space && !pic_pend && !cs_v;
  assign accept    = i_valid && i_ready;
  assign ring_stall = i_valid && !ring_room;

  assign lane      = wpos[3:0];
  assign full_word = (lane == 4'd15);
  assign push      = accept && (full_word || i_last);
  assign waddr     = waddr_q;
  assign wpos_inc  = at_end_q ? 32'd0 : (wpos + 32'd1);
  assign beats_n   = b_beats + 5'd1;
  assign start_addr = (b_beats == 5'd0) ? waddr : b_addr;
  assign close     = push && ((beats_n == 5'(BURST_MAX_BEATS)) || i_last ||
                              (full_word && (waddr[11:4] == 8'hFF)) ||
                              (full_word && at_end_q));
  assign slice_last = accept && i_last && (i_kind == NAL_SLICE);

  always_comb begin
    wdat_m = wdat;
    wmask_m = wmask;
    wdat_m[8*lane +: 8] = i_data;
    wmask_m[lane] = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Read-pointer accounting
  // ---------------------------------------------------------------------------
  always_comb begin
    cons_ok    = cs_range && (cs_val <= fill);
    rptr_apply = cs_v && cons_ok;
    icons_ok   = ics_range && (ics_val <= idx_fill);
    idx_apply  = ics_v && icons_ok;
  end
  assign err_rptr = err_q;

  // ---------------------------------------------------------------------------
  // Index entries
  // ---------------------------------------------------------------------------
  assign eq_push = slice_last || pic_pend;
  always_comb begin
    if (pic_pend) begin
      ent_w0  = pe_off;
      ent_w1  = pe_len;
      ent_w2  = pe_w2;
      ent_w3  = pe_w3;
      ent_end = pe_end;
    end else begin
      ent_w0  = nal_start_off;
      ent_w1  = total + 32'd1 - nal_start_total;
      ent_w2  = {m_slice, m_pic};
      ent_w3  = {7'd0, IDX_KIND_SLICE, 6'd0, m_idr, m_last_slice, m_qp, m_type};
      ent_end = total + 32'd1;
    end
  end

  assign idx_limit = {idx_entries[27:0], 4'd0};
  assign comp_diff = comp_total - eq_end[eq_rp];
  assign comp_ok   = !comp_diff[31];
  // The head entry moves into the request register (ix_valid, ix_addr, ix_data) when its slice is in memory and the
  // index ring has room; the entry counts as written from then on and the request waits for the master's ix_ack.
  // comp_ok_q and idx_room_q are registered from the previous clock's head entry and fill level: take_q blocks the
  // clock after a take, so a stale value never starts a take.
  assign ix_take   = !ix_valid && comp_ok_q && idx_room_q && !take_q && !ics_v;

  // ---------------------------------------------------------------------------
  // Descriptor queue to the write master
  // ---------------------------------------------------------------------------
  assign rg_valid = (dq_cnt != 3'd0);
  assign rg_addr  = dq_addr[dq_rp];
  assign rg_len   = dq_len[dq_rp];
  assign b_start = (b_pend != 4'd0) && !p1;
  assign bi_start = (bi_pend != 4'd0) && !pi1 && !pi2;

  // ---------------------------------------------------------------------------
  // Word FIFO
  // ---------------------------------------------------------------------------
  rtlnet_ram_core #(
    .RAM_STYLE(RAM_STYLE), .CLOCKING("COMMON"), .DATA_W(144), .ADDR_W(FAW), .READ_LATENCY(1)
  ) u_word_fifo (
    .wr_clk(clk), .wr_en(push), .wr_addr(ff_wp), .wr_data({wmask_m, wdat_m}),
    .rd_clk(clk), .rd_resetn(resetn), .rd_en(ff_rd_en), .rd_addr(ff_rp), .rd_data(ff_rd_data)
  );

  assign ff_rd_en   = (ff_cnt != '0) && !rd_infl && (!q_valid || rg_w_pop);
  assign rg_w_valid = q_valid;
  assign rg_w_data  = q_data[127:0];
  assign rg_w_strb  = q_data[143:128];

  assign idle_c = !m_valid && !k_valid && (ff_cnt == '0) && !q_valid && !rd_infl && (dq_cnt == 3'd0) && (ifq_cnt == 4'd0) && (b_pend == 4'd0) && !p1 && (bi_pend == 4'd0) && !pi1 && !pi2 &&
                (eq_cnt == 3'd0) && !ix_valid && !pic_pend && (b_beats == 5'd0) && (bb == 10'd0) && (wmask == 16'd0) &&
                (idx_infl == 4'd0);

  // idle is registered: it can only fall because new work arrives, and none arrives once a picture's bytes are all in.
  always_ff @(posedge clk) begin
    if (!resetn) idle <= 1'b0;
    else         idle <= idle_c;
  end

  // ---------------------------------------------------------------------------
  // State update
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!resetn) begin
      ix_valid        <= 1'b0;
      comp_ok_q       <= 1'b0;
      idx_room_q      <= 1'b0;
      take_q          <= 1'b0;
      ix_addr         <= '0;
      ix_data         <= '0;
      m_valid         <= 1'b0;
      m_pack          <= '0;
      k_valid         <= 1'b0;
      k_pack          <= '0;
      wpos            <= '0;
      to_end          <= '0;
      at_end_q        <= 1'b0;
      waddr_q         <= '0;
      ff_space_q      <= 1'b0;
      dq_space_q      <= 1'b0;
      eq_space_q      <= 1'b0;
      room_lim        <= '0;
      room_q          <= 1'b0;
      rq_v            <= 1'b0;
      rq_val          <= '0;
      cs_v            <= 1'b0;
      cs_val          <= '0;
      cs_newp         <= '0;
      cs_range        <= 1'b0;
      iq_v            <= 1'b0;
      iq_val          <= '0;
      ics_v           <= 1'b0;
      ics_val         <= '0;
      ics_newp        <= '0;
      ics_range       <= 1'b0;
      err_q           <= 1'b0;
      wdat            <= '0;
      wmask           <= '0;
      fill            <= '0;
      total           <= '0;
      rptr_q          <= '0;
      wptr_vis        <= '0;
      comp_total      <= '0;
      nal_start_off   <= '0;
      nal_start_total <= '0;
      pic_start_off   <= '0;
      pic_start_total <= '0;
      b_beats         <= '0;
      b_addr          <= '0;
      bb              <= '0;
      ff_wp           <= '0;
      ff_rp           <= '0;
      ff_cnt          <= '0;
      rd_infl         <= 1'b0;
      q_valid         <= 1'b0;
      q_data          <= '0;
      dq_wp           <= '0;
      dq_rp           <= '0;
      dq_cnt          <= '0;
      ifq_wp          <= '0;
      ifq_rp          <= '0;
      ev_b_ring       <= 1'b0;
      ev_b_idx        <= 1'b0;
      b_pend          <= '0;
      bi_pend         <= '0;
      pi1             <= 1'b0;
      pi2             <= 1'b0;
      pi_sum          <= '0;
      pi_next         <= '0;
      p1              <= 1'b0;
      p1_bytes        <= '0;
      p1_sum          <= '0;
      ifq_cnt         <= '0;
      eq_wp           <= '0;
      eq_rp           <= '0;
      eq_cnt          <= '0;
      pic_pend        <= 1'b0;
      pic_open        <= 1'b0;
      pe_off          <= '0;
      pe_len          <= '0;
      pe_end          <= '0;
      pe_w2           <= '0;
      pe_w3           <= '0;
      idx_wr_off      <= '0;
      idx_fill        <= '0;
      idx_vis         <= '0;
      idx_rq          <= '0;
      idx_infl        <= '0;
      nal_done        <= 1'b0;
    end else begin
      nal_done <= accept && i_last;

      comp_ok_q  <= (eq_cnt != 3'd0) && comp_ok;
      idx_room_q <= (idx_fill < idx_entries);
      take_q     <= ix_take;

      // Index request register.
      if (ix_take) begin
        ix_valid <= 1'b1;
        ix_addr  <= idx_base + idx_wr_off;
        ix_data  <= {eq_w3[eq_rp], eq_w2[eq_rp], eq_w1[eq_rp], eq_w0[eq_rp]};
      end else if (ix_ack) begin
        ix_valid <= 1'b0;
      end

      // Input skid buffer.
      if (accept || !m_valid) begin
        if (k_valid) begin
          m_valid <= 1'b1;
          m_pack  <= k_pack;
          k_valid <= 1'b0;
        end else begin
          m_valid <= in_fire;
          m_pack  <= {u_kind, u_last, u_first, u_data};
        end
      end else if (in_fire) begin
        k_valid <= 1'b1;
        k_pack  <= {u_kind, u_last, u_first, u_data};
      end

      // Gather.
      if (accept) begin
        wpos  <= wpos_inc;
        total <= total + 32'd1;
        if (i_first) begin
          nal_start_off   <= wpos;
          nal_start_total <= total;
          if (!pic_open) begin
            pic_open        <= 1'b1;
            pic_start_off   <= wpos;
            pic_start_total <= total;
          end
        end
        if (push) begin
          wdat  <= '0;
          wmask <= '0;
        end else begin
          wdat  <= wdat_m;
          wmask <= wmask_m;
        end
      end

      // Fill level.
      if (rptr_apply) begin
        fill   <= fill - cs_val;
        rptr_q <= cs_newp;
      end else if (accept) begin
        fill <= fill + 32'd1;
      end
      rq_v     <= rptr_wr;
      rq_val   <= rptr_val;
      cs_v     <= rq_v;
      cs_newp  <= rq_val;
      cs_range <= (rq_val < ring_size);
      cs_val   <= (rq_val >= rptr_q) ? (rq_val - rptr_q) : (rq_val + ring_size - rptr_q);
      iq_v      <= idx_rptr_wr;
      iq_val    <= idx_rptr_val;
      ics_v     <= iq_v;
      ics_newp  <= iq_val;
      ics_range <= (iq_val < idx_entries);
      ics_val   <= (iq_val >= idx_rq) ? (iq_val - idx_rq) : (iq_val + idx_entries - idx_rq);
      err_q     <= (cs_v && !cons_ok) || (ics_v && !icons_ok);
      room_lim  <= ring_size - 32'd4;
      room_q    <= (fill < room_lim);
      if (accept) begin
        to_end   <= at_end_q ? ring_size : (to_end - 32'd1);
        at_end_q <= (to_end == 32'd2);
      end
      if (accept && full_word) waddr_q <= at_end_q ? ring_base : (waddr_q + 32'd16);
      ff_space_q <= (ff_cnt < (FAW + 1)'(FDEPTH - 3));
      dq_space_q <= (dq_cnt <= 3'(DQD - 2));
      eq_space_q <= (eq_cnt <= 3'(EQD - 3));

      // Word FIFO write pointer and burst assembly.
      if (push) ff_wp <= ff_wp + 1'b1;
      if (close) begin
        dq_addr[dq_wp]  <= start_addr;
        dq_len[dq_wp]   <= 4'(beats_n - 5'd1);
        dq_bytes[dq_wp] <= bb + 10'd1;
        dq_wp           <= dq_wp + 2'd1;
        b_beats         <= 5'd0;
        bb              <= 10'd0;
      end else if (push) begin
        b_beats <= beats_n;
        b_addr  <= start_addr;
        bb      <= bb + 10'd1;
      end else if (accept) begin
        bb      <= bb + 10'd1;
      end

      // Word FIFO read side.
      rd_infl <= ff_rd_en;
      if (ff_rd_en) ff_rp <= ff_rp + 1'b1;
      case ({push, ff_rd_en})
        2'b10:   ff_cnt <= ff_cnt + 1'b1;
        2'b01:   ff_cnt <= ff_cnt - 1'b1;
        default: ff_cnt <= ff_cnt;
      endcase
      if (rd_infl) begin
        q_valid <= 1'b1;
        q_data  <= ff_rd_data;
      end else if (rg_w_pop) begin
        q_valid <= 1'b0;
      end

      // Descriptor queue pop and the in-flight byte queue.
      if (rg_pop) begin
        dq_rp <= dq_rp + 2'd1;
        ifq[ifq_wp] <= dq_bytes[dq_rp];
        ifq_wp <= ifq_wp + 3'd1;
      end
      case ({close, rg_pop})
        2'b10:   dq_cnt <= dq_cnt + 3'd1;
        2'b01:   dq_cnt <= dq_cnt - 3'd1;
        default: dq_cnt <= dq_cnt;
      endcase
      ev_b_ring <= ev_b_ring_i;
      ev_b_idx  <= ev_b_idx_i;
      case ({ev_b_ring, b_start})
        2'b10:   b_pend <= b_pend + 4'd1;
        2'b01:   b_pend <= b_pend - 4'd1;
        default: b_pend <= b_pend;
      endcase
      p1 <= b_start;
      if (b_start) begin
        ifq_rp   <= ifq_rp + 3'd1;
        p1_bytes <= ifq[ifq_rp];
        p1_sum   <= wptr_vis + {22'd0, ifq[ifq_rp]};
      end
      if (p1) begin
        wptr_vis   <= (p1_sum >= ring_size) ? (p1_sum - ring_size) : p1_sum;
        comp_total <= comp_total + {22'd0, p1_bytes};
      end
      case ({rg_pop, b_start})
        2'b10:   ifq_cnt <= ifq_cnt + 4'd1;
        2'b01:   ifq_cnt <= ifq_cnt - 4'd1;
        default: ifq_cnt <= ifq_cnt;
      endcase

      // Index entry queue: slice entry, then the picture entry of the last slice.
      if (slice_last && m_last_slice) begin
        pic_pend <= 1'b1;
        pic_open <= 1'b0;
        pe_off   <= pic_start_off;
        pe_len   <= total + 32'd1 - pic_start_total;
        pe_end   <= total + 32'd1;
        pe_w2    <= {m_nslices, m_pic};
        pe_w3    <= {7'd0, IDX_KIND_PICTURE, 6'd0, m_idr, 1'b1, m_qp, SLICE_TYPE_I_ALL};
      end else if (pic_pend) begin
        pic_pend <= 1'b0;
      end
      if (eq_push) begin
        eq_w0[eq_wp]  <= ent_w0;
        eq_w1[eq_wp]  <= ent_w1;
        eq_w2[eq_wp]  <= ent_w2;
        eq_w3[eq_wp]  <= ent_w3;
        eq_end[eq_wp] <= ent_end;
        eq_wp         <= eq_wp + 2'd1;
      end
      if (ix_take) eq_rp <= eq_rp + 2'd1;
      case ({eq_push, ix_take})
        2'b10:   eq_cnt <= eq_cnt + 3'd1;
        2'b01:   eq_cnt <= eq_cnt - 3'd1;
        default: eq_cnt <= eq_cnt;
      endcase

      // Index ring write position, fill and visibility.
      if (ix_take) begin
        idx_wr_off <= ((idx_wr_off + 32'd16) >= idx_limit) ? 32'd0 : (idx_wr_off + 32'd16);
        idx_infl   <= ev_b_idx ? idx_infl : (idx_infl + 4'd1);
      end else if (ev_b_idx && (idx_infl != 4'd0)) begin
        idx_infl <= idx_infl - 4'd1;
      end
      if (idx_apply) begin
        idx_fill <= idx_fill - ics_val;
        idx_rq   <= ics_newp;
      end else if (ix_take) begin
        idx_fill <= idx_fill + 32'd1;
      end
      // Index responses: counted, then applied one at a time over two clocks (next position, then the update).
      case ({ev_b_idx, bi_start})
        2'b10:   bi_pend <= bi_pend + 4'd1;
        2'b01:   bi_pend <= bi_pend - 4'd1;
        default: bi_pend <= bi_pend;
      endcase
      pi1 <= bi_start;
      pi2 <= pi1;
      if (bi_start) pi_sum <= idx_vis + 32'd1;
      if (pi1) pi_next <= (pi_sum >= idx_entries) ? 32'd0 : pi_sum;
      if (pi2) idx_vis <= pi_next;

      // Ring reset: pointers, fill level and index counters (queues are empty by contract).
      if (ring_reset) begin
        wpos       <= '0;
        to_end     <= ring_size;
        at_end_q   <= 1'b0;
        waddr_q    <= ring_base;
        fill       <= '0;
        rptr_q     <= '0;
        wptr_vis   <= '0;
        idx_wr_off <= '0;
        idx_fill   <= '0;
        idx_vis    <= '0;
        idx_rq     <= '0;
      end
    end
  end

  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (resetn) begin
      if (accept && !ring_room) $error("rtlnet_h264_ring_wr: byte accepted with the ring full");
      if (push && (ff_cnt >= (FAW + 1)'(FDEPTH))) $error("rtlnet_h264_ring_wr: word FIFO overflow");
      if (close && (dq_cnt >= 3'(DQD))) $error("rtlnet_h264_ring_wr: descriptor queue overflow");
      if (rg_pop && (dq_cnt == 3'd0)) $error("rtlnet_h264_ring_wr: descriptor queue underflow");
      if (rg_pop && (ifq_cnt >= 4'(IFD))) $error("rtlnet_h264_ring_wr: in-flight queue overflow");
      if (ev_b_ring && (b_pend == 4'd15)) $error("rtlnet_h264_ring_wr: pending ring response counter overflow");
      if (b_start && (ifq_cnt == 4'd0)) $error("rtlnet_h264_ring_wr: ring write response with no burst in flight");
      if (eq_push && (eq_cnt >= 3'(EQD))) $error("rtlnet_h264_ring_wr: entry queue overflow");
      if (ev_b_idx && (idx_infl == 4'd0)) $error("rtlnet_h264_ring_wr: index write response with no entry in flight");
      if (ix_take && (idx_fill >= idx_entries)) $error("rtlnet_h264_ring_wr: index ring overflow");
      if (cs_v && !cons_ok) $error("rtlnet_h264_ring_wr: read pointer 0x%0h rejected (fill %0d)", cs_newp, fill);
      if (fill > ring_size) $error("rtlnet_h264_ring_wr: fill %0d above ring size %0d", fill, ring_size);
    end
  end
  // synthesis translate_on

endmodule
