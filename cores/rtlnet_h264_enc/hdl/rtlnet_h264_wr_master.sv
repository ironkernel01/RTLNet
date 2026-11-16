// -----------------------------------------------------------------------------
// File: rtlnet_h264_wr_master.sv
// Purpose: the write side of the encoder's single AXI4 master: carries three kinds of write from
//   the encoder (compressed-ring bursts, index records, rebuilt-picture tiles) one burst at a time.
// Overview:
//   * Three requesters, served round robin one burst per grant: the ring and the rebuilt-picture writer (each a
//     descriptor with address and length, the data beats pulled from the requester's own beat stream) and the index
//     writer (one 128-byte record: 8 beats, the first carries the entry, the other 7 are zero). Every burst is
//     INCR, size 16 bytes (the full 128-bit data width), at most 16 beats and, by construction of the requesters,
//     never crosses a 4 KiB boundary. No requester issues a single-beat burst except the ring's end-of-slice tail.
//   * AWID selects the requester (0 ring, 1 index, 2 rebuilt picture); the B response is routed back
//     to the requester by BID as an event pulse. At most MAX_OUT writes are outstanding; a new grant
//     waits while the limit is reached (counter overflow is gated in logic and checked in simulation).
//     The count is per burst, so it is the same for a 1-beat and a 16-beat burst.
//   * A B response other than OKAY pulses err_resp.
//   * A simulation check reports an AW that is not INCR, not full width, longer than 16 beats or
//     crossing 4 KiB.
//   * AXI_DATA_W (default 128): the width of the AXI4 W channel. The three requesters always deliver 128-bit beats and a burst of n
//     beats of 16 bytes; with 128 the bus carries them as they are (the code path below is the whole 128-bit design). With 64 each
//     128-bit beat leaves as two 64-bit beats, low half first (byte order in memory unchanged), the requester's beat is held until its
//     upper half is taken (the pop comes with the upper half), and a burst of more than 8 requester beats (more than 16 bus beats, the
//     AXI3 limit of the Zynq HP ports) leaves as two bursts of ceil(n / 2) and floor(n / 2) requester beats, so no bus burst has
//     fewer than 8 beats unless the requester's burst had fewer than 4 (an end-of-slice tail). The first of two bursts carries AWID
//     bit 2 (the requester id in bits 1:0 is unchanged); the B events of the requesters count only the burst without that bit, so
//     each requester burst gives one event. W follows its AW (the W channel waits for the AW handshake of its burst), WID of an AXI3
//     port equals AWID, which holds for the whole burst. ID_W must be at least 3 for 64 bits. AWLEN is at most 15.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: AXI_DATA_W parameter (128 default, 64).
//   * 11-09-2026: initial version.
//   * 11-10-2026: burst-only DDR3 access: the rebuilt-picture writer requests a tile burst with a beat stream (rc_w_*),
//     the index entry is an 8-beat record.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_wr_master #(
  parameter int ADDR_W      = 32,
  parameter int ID_W        = 4,
  parameter int MAX_OUT     = 8,
  parameter int AXI_DATA_W  = 128    // width of the AXI4 W channel in bits: 128 or 64
)(
  // Clock and synchronous active-low reset.
  input  logic              clk,
  input  logic              resetn,

  // Ring burst request from rtlnet_h264_ring_wr: descriptor valid with address and beats-1; rg_pop pulses in
  // the grant clock. The data beats come from the ring word FIFO (rg_w_*): rg_w_pop pulses per beat taken.
  input  logic              rg_valid,
  input  logic [ADDR_W-1:0] rg_addr,
  input  logic [3:0]        rg_len,
  output logic              rg_pop,
  input  logic              rg_w_valid,
  input  logic [127:0]      rg_w_data,
  input  logic [15:0]       rg_w_strb,
  output logic              rg_w_pop,

  // Index record request from rtlnet_h264_ring_wr: one 128-byte record (the 16-byte entry in beat 0); ix_ack pulses in
  // the grant clock.
  input  logic              ix_valid,
  input  logic [ADDR_W-1:0] ix_addr,
  input  logic [127:0]      ix_data,
  output logic              ix_ack,

  // Rebuilt-picture tile burst request from rtlnet_h264_recon_wr: descriptor valid with address and beats-1; rc_pop pulses
  // in the grant clock; the beats (with their byte strobes rc_w_strb) come from rc_w_*: rc_w_pop pulses per beat taken.
  input  logic              rc_valid,
  input  logic [ADDR_W-1:0] rc_addr,
  input  logic [3:0]        rc_len,
  output logic              rc_pop,
  input  logic              rc_w_valid,
  input  logic [127:0]      rc_w_data,
  input  logic [15:0]       rc_w_strb,
  output logic              rc_w_pop,

  // AXI4 write channels, clk domain.
  output logic [ID_W-1:0]   awid,
  output logic [ADDR_W-1:0] awaddr,
  output logic [7:0]        awlen,
  output logic [2:0]        awsize,
  output logic [1:0]        awburst,
  output logic              awvalid,
  input  logic              awready,
  output logic [AXI_DATA_W-1:0]   wdata,
  output logic [AXI_DATA_W/8-1:0] wstrb,
  output logic              wlast,
  output logic              wvalid,
  input  logic              wready,
  // Only the low two bits of bid select the requester (IDs 0..2); the upper bits are unused here.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [ID_W-1:0]   bid,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [1:0]        bresp,
  input  logic              bvalid,
  output logic              bready,

  // Response events, one clock each: a B arrived for the ring, the index writer or the rebuilt-picture writer;
  // err_resp for a B that is not OKAY.
  output logic              ev_b_ring,
  output logic              ev_b_idx,
  output logic              ev_b_rec,
  output logic              err_resp,

  // Status: a burst is being sent; writes accepted and not yet answered.
  output logic              busy,
  output logic [4:0]        outstanding
);

  import rtlnet_h264_pkg::*;

  localparam logic       M_IDLE = 1'b0;
  localparam logic       M_XFER = 1'b1;
  localparam logic [1:0] SEL_RING = 2'd0;
  localparam logic [1:0] SEL_IDX  = 2'd1;
  localparam logic [1:0] SEL_REC  = 2'd2;

  logic        st;
  logic [1:0]  sel;
  logic [1:0]  rr;
  logic [4:0]  w_left;               // requester beats (16 bytes) left in the burst
  logic [127:0] ld_data;
  logic        can_grant;
  logic [1:0]  gnt;
  logic        gnt_valid;
  logic        done_xfer;
  logic        w_hs;
  logic        b_dec;
  logic        src_valid;
  logic [127:0] src_data;
  logic [15:0] src_strb;
  logic        src_pop;
  logic [4:0]  c_left;               // bus beats left in the burst on the bus (128 bits: the requester beats left)
  logic [4:0]  g_n;
  logic        g_split;
  logic [4:0]  g_hi;
  logic [4:0]  g_bus;
  logic [4:0]  nxt_bus;
  logic        bid_last;

  // 64-bit bus only (constant 0 and removed for 128 bits): upper half next, bus beats left in the current burst, a second burst follows.
  localparam bit SPLIT = (AXI_DATA_W == 64);
  logic        half;
  logic [4:0]  c_beats;
  logic        more;
  logic [ADDR_W-1:0] nxt_addr;
  logic [4:0]  nxt_n;

  generate
    if (AXI_DATA_W != 128 && AXI_DATA_W != 64) begin : g_bad_width
      $fatal(1, "rtlnet_h264_wr_master: AXI_DATA_W=%0d, must be 128 or 64", AXI_DATA_W);
    end
    if (AXI_DATA_W == 64 && ID_W < 3) begin : g_bad_id
      $fatal(1, "rtlnet_h264_wr_master: ID_W=%0d, at least 3 for AXI_DATA_W 64 (AWID bit 2 marks a split burst)", ID_W);
    end
  endgenerate

  assign can_grant = (st == M_IDLE) && (outstanding < 5'(MAX_OUT));
  assign busy      = (st == M_XFER);
  assign awsize    = 3'(AXI_DATA_W == 128 ? 4 : 3);
  assign awburst   = 2'b01;
  assign bready    = 1'b1;

  // Round-robin pick: the first requester at or after rr.
  always_comb begin
    gnt_valid = 1'b0;
    gnt       = SEL_RING;
    for (int k = 0; k < 3; k++) begin
      if (!gnt_valid) begin
        case ((int'(rr) + k) % 3)
          0: if (rg_valid) begin gnt = SEL_RING; gnt_valid = 1'b1; end
          1: if (ix_valid) begin gnt = SEL_IDX;  gnt_valid = 1'b1; end
          default: if (rc_valid) begin gnt = SEL_REC; gnt_valid = 1'b1; end
        endcase
      end
    end
  end

  assign rg_pop = can_grant && gnt_valid && (gnt == SEL_RING);
  assign ix_ack = can_grant && gnt_valid && (gnt == SEL_IDX);
  assign rc_pop = can_grant && gnt_valid && (gnt == SEL_REC);

  // Requester beats of the burst being granted (the requester's own length, before any split), and its bus bursts (64-bit bus: a burst of more than 8
  // requester beats leaves as ceil(n / 2) and the rest; each requester beat is two bus beats).
  always_comb begin
    case (gnt)
      SEL_RING: g_n = {1'b0, rg_len} + 5'd1;
      SEL_IDX:  g_n = 5'(IDX_REC_BEATS);
      default:  g_n = {1'b0, rc_len} + 5'd1;
    endcase
    g_split = (g_n > 5'd8);
    g_hi    = 5'((6'(g_n) + 6'd1) >> 1);
    g_bus   = 5'({(g_split ? g_hi : g_n), 1'b0});
  end
  assign nxt_bus = 5'({nxt_n, 1'b0});

  // Beat source of the burst in progress: the ring and tile streams hold their beat until it is taken; the index record
  // is generated here (beat 0 the entry, the others zero).
  always_comb begin
    case (sel)
      SEL_RING: src_valid = rg_w_valid;
      SEL_REC:  src_valid = rc_w_valid;
      default:  src_valid = 1'b1;
    endcase
  end

  assign src_data = (sel == SEL_RING) ? rg_w_data : ((sel == SEL_REC) ? rc_w_data :
                    ((w_left == 5'(IDX_REC_BEATS)) ? ld_data : 128'd0));
  assign src_strb = (sel == SEL_RING) ? rg_w_strb : ((sel == SEL_REC) ? rc_w_strb : 16'hFFFF);
  generate
    if (AXI_DATA_W == 128) begin : g_w128
      assign wdata  = src_data;
      assign wstrb  = src_strb;
      assign wvalid = (st == M_XFER) && (w_left != 5'd0) && src_valid;
    end else begin : g_w64
      assign wdata  = half ? src_data[127:64] : src_data[63:0];
      assign wstrb  = half ? src_strb[15:8] : src_strb[7:0];
      assign wvalid = (st == M_XFER) && !awvalid && (w_left != 5'd0) && src_valid;
    end
  endgenerate
  assign c_left   = SPLIT ? c_beats : w_left;
  assign wlast    = (c_left == 5'd1);
  assign w_hs     = wvalid && wready;
  assign src_pop  = SPLIT ? (w_hs && half) : w_hs;
  assign rg_w_pop = src_pop && (sel == SEL_RING);
  assign rc_w_pop = src_pop && (sel == SEL_REC);
  assign done_xfer = (st == M_XFER) && !awvalid && ((c_left == 5'd0) || (w_hs && (c_left == 5'd1)));
  assign bid_last   = SPLIT ? !bid[2] : 1'b1;

  assign ev_b_ring = bvalid && bid_last && (bid[1:0] == 2'd0);
  assign ev_b_idx  = bvalid && bid_last && (bid[1:0] == 2'd1);
  assign ev_b_rec  = bvalid && bid_last && (bid[1:0] == 2'd2);
  assign err_resp  = bvalid && (bresp != 2'b00);
  assign b_dec     = bvalid;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      st          <= M_IDLE;
      sel         <= SEL_RING;
      rr          <= 2'd0;
      w_left      <= '0;
      ld_data     <= '0;
      awid        <= '0;
      awaddr      <= '0;
      awlen       <= '0;
      awvalid     <= 1'b0;
      outstanding <= '0;
      half        <= 1'b0;
      c_beats     <= '0;
      more        <= 1'b0;
      nxt_addr    <= '0;
      nxt_n       <= '0;
    end else begin
      case (st)
        M_IDLE: begin
          if (can_grant && gnt_valid) begin
            st      <= M_XFER;
            sel     <= gnt;
            rr      <= (gnt == SEL_REC) ? 2'd0 : (gnt + 2'd1);
            awvalid <= 1'b1;
            awid    <= ID_W'(gnt);
            case (gnt)
              SEL_RING: begin
                awaddr <= rg_addr;
                awlen  <= {4'd0, rg_len};
                w_left <= {1'b0, rg_len} + 5'd1;
              end
              SEL_IDX: begin
                awaddr  <= ix_addr;
                awlen   <= 8'(IDX_REC_BEATS - 1);
                w_left  <= 5'(IDX_REC_BEATS);
                ld_data <= ix_data;
              end
              default: begin
                awaddr <= rc_addr;
                awlen  <= {4'd0, rc_len};
                w_left <= {1'b0, rc_len} + 5'd1;
              end
            endcase
            // 64-bit bus: the first (or only) bus burst of g_n requester beats; a longer burst continues as a second one.
            if (SPLIT) begin
              awlen   <= 8'(g_bus) - 8'd1;
              c_beats <= g_bus;
              more    <= g_split;
              nxt_n   <= g_n - g_hi;
              if (g_split) awid <= ID_W'(gnt) | ID_W'(4);
              case (gnt)
                SEL_RING: nxt_addr <= rg_addr + (ADDR_W'(g_hi) << 4);
                SEL_IDX:  nxt_addr <= ix_addr + (ADDR_W'(g_hi) << 4);
                default:  nxt_addr <= rc_addr + (ADDR_W'(g_hi) << 4);
              endcase
            end
          end
        end
        default: begin
          if (awvalid && awready) awvalid <= 1'b0;
          if (src_pop) w_left <= w_left - 5'd1;
          if (SPLIT) begin
            if (w_hs) begin
              c_beats <= c_beats - 5'd1;
              half    <= !half;
            end
            if (done_xfer) begin
              if (more) begin
                awvalid <= 1'b1;
                awaddr  <= nxt_addr;
                awlen   <= 8'(nxt_bus) - 8'd1;
                awid    <= awid & ~ID_W'(4);
                c_beats <= nxt_bus;
                more    <= 1'b0;
              end else begin
                st <= M_IDLE;
              end
            end
          end else if (done_xfer) begin
            st <= M_IDLE;
          end
        end
      endcase
      // Outstanding writes: +1 when a burst is fully sent, -1 per B (never below zero).
      if (done_xfer && !b_dec) begin
        outstanding <= outstanding + 5'd1;
      end else if (!done_xfer && b_dec && (outstanding != 5'd0)) begin
        outstanding <= outstanding - 5'd1;
      end
    end
  end

  // synthesis translate_off
  always_ff @(posedge clk) begin
    if (resetn) begin
      if (awvalid && awready) begin
        if (awburst != 2'b01) $error("rtlnet_h264_wr_master: AW burst type %0d, must be INCR", awburst);
        if (awsize != 3'(AXI_DATA_W == 128 ? 4 : 3)) $error("rtlnet_h264_wr_master: AW size %0d, must be the full bus width", awsize);
        if (awlen > 8'd15) $error("rtlnet_h264_wr_master: AW length %0d beats, at most 16", awlen + 1);
        if (((awaddr & 32'hFFF) + (({24'd0, awlen} + 32'd1) << (AXI_DATA_W == 128 ? 4 : 3))) > 32'h1000) begin
          $error("rtlnet_h264_wr_master: AW 0x%0h len %0d crosses a 4 KiB boundary", awaddr, awlen);
        end
      end
      if (bvalid && (outstanding == 5'd0)) $error("rtlnet_h264_wr_master: B response with no write outstanding");
      if (done_xfer && (outstanding >= 5'd31)) $error("rtlnet_h264_wr_master: outstanding counter overflow");
    end
  end
  // synthesis translate_on

endmodule
