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
// Language: SystemVerilog-2012.
// Revision: 11-10-2026
//   * 11-09-2026: initial version.
//   * 11-10-2026: burst-only DDR3 access: the rebuilt-picture writer requests a tile burst with a beat stream (rc_w_*),
//     the index entry is an 8-beat record.
// Clocks: clk.
// -----------------------------------------------------------------------------
module rtlnet_h264_wr_master #(
  parameter int ADDR_W  = 32,
  parameter int ID_W    = 4,
  parameter int MAX_OUT = 8
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
  output logic [127:0]      wdata,
  output logic [15:0]       wstrb,
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
  logic [4:0]  w_left;
  logic [127:0] ld_data;
  logic        can_grant;
  logic [1:0]  gnt;
  logic        gnt_valid;
  logic        done_xfer;
  logic        w_hs;
  logic        b_dec;
  logic        src_valid;

  assign can_grant = (st == M_IDLE) && (outstanding < 5'(MAX_OUT));
  assign busy      = (st == M_XFER);
  assign awsize    = 3'd4;
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

  // Beat source of the burst in progress: the ring and tile streams hold their beat until it is taken; the index record
  // is generated here (beat 0 the entry, the others zero).
  always_comb begin
    case (sel)
      SEL_RING: src_valid = rg_w_valid;
      SEL_REC:  src_valid = rc_w_valid;
      default:  src_valid = 1'b1;
    endcase
  end

  assign wvalid   = (st == M_XFER) && (w_left != 5'd0) && src_valid;
  assign wdata    = (sel == SEL_RING) ? rg_w_data : ((sel == SEL_REC) ? rc_w_data :
                    ((w_left == 5'(IDX_REC_BEATS)) ? ld_data : 128'd0));
  assign wstrb    = (sel == SEL_RING) ? rg_w_strb : ((sel == SEL_REC) ? rc_w_strb : 16'hFFFF);
  assign wlast    = (w_left == 5'd1);
  assign w_hs     = wvalid && wready;
  assign rg_w_pop = w_hs && (sel == SEL_RING);
  assign rc_w_pop = w_hs && (sel == SEL_REC);
  assign done_xfer = (st == M_XFER) && !awvalid && ((w_left == 5'd0) || (w_hs && (w_left == 5'd1)));

  assign ev_b_ring = bvalid && (bid[1:0] == 2'd0);
  assign ev_b_idx  = bvalid && (bid[1:0] == 2'd1);
  assign ev_b_rec  = bvalid && (bid[1:0] == 2'd2);
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
          end
        end
        default: begin
          if (awvalid && awready) awvalid <= 1'b0;
          if (w_hs) w_left <= w_left - 5'd1;
          if (done_xfer) st <= M_IDLE;
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
        if (awsize != 3'd4) $error("rtlnet_h264_wr_master: AW size %0d, must be the full 16-byte width", awsize);
        if (awlen > 8'd15) $error("rtlnet_h264_wr_master: AW length %0d beats, at most 16", awlen + 1);
        if (((awaddr & 32'hFFF) + (({24'd0, awlen} + 32'd1) << 4)) > 32'h1000) begin
          $error("rtlnet_h264_wr_master: AW 0x%0h len %0d crosses a 4 KiB boundary", awaddr, awlen);
        end
      end
      if (bvalid && (outstanding == 5'd0)) $error("rtlnet_h264_wr_master: B response with no write outstanding");
      if (done_xfer && (outstanding >= 5'd31)) $error("rtlnet_h264_wr_master: outstanding counter overflow");
    end
  end
  // synthesis translate_on

endmodule
