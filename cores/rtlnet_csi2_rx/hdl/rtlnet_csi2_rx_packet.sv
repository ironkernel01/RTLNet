// -----------------------------------------------------------------------------
// File: rtlnet_csi2_rx_packet.sv
// Purpose: CSI-2 packet layer of the camera receiver: header ECC (single-error correct, double-error detect), short and long
//   packets, the payload CRC-16, the virtual channel and data type filter and the RAW10 unpacking to 10-bit pixels.
// Overview:
//   * Input: the byte-clock pair stream of rtlnet_csi2_rx_dphy: two bytes per valid clock ({lane 1 byte, lane 0 byte}), p_first on
//     the first pair of an HS burst, p_end one clock after the last pair of a burst.
//   * One packet per HS burst: the first four bytes of a burst are the packet header. Whatever follows the packet (the HS trail
//     bytes, or a second packet chained in the same burst) is ignored until p_end. The OV5640 sends one packet per burst.
//   * Header (pair 0 = {WC low, DI}, pair 1 = {ECC, WC high}): hdr_ecc_check corrects one flipped bit and reports two as
//     uncorrectable (ev_ecc_unc: the packet is dropped, the burst is skipped). A packet of another virtual channel is dropped
//     silently. Short packets: frame start (data type 0) sets in_frame and arms the start-of-frame flag of the next line and
//     raises ev_frame; frame end (1) pushes a frame-end marker entry when a frame was open; line start/end (2, 3) are ignored; other short
//     types raise ev_dt. Long packets: a data type other than cfg_dt raises ev_dt and is skipped; a line outside a frame (no frame start seen)
//     raises ev_orphan and is skipped; a word count of zero or not a multiple of five raises ev_len (RAW10 is five bytes per four
//     pixels; the complete groups are still used).
//   * Payload: the byte pairs are taken in groups of five pairs (ten bytes, eight pixels). Pair 2 completes the first four pixels
//     (bytes 0 to 4), pair 4 the next four (bytes 5 to 9); each completion pushes one FIFO entry (e_valid, e_data, layout in
//     rtlnet_csi2_rx_pkg) with the start-of-frame flag on the first entry of the first line after a frame start and the end-of-line
//     flag on the last complete group. The CRC-16 runs over the payload bytes and is compared with the two bytes that follow; a
//     mismatch raises ev_crc after the pixels were pushed (the pixels are used, the error is counted).
//   * A burst that ends (p_end) or a new burst that starts (p_first) before the packet is complete raises ev_trunc; when the line had
//     pushed an entry, an end-of-line marker entry closes it so that the line boundary is not lost.
//   * Events are one-clock pulses in the byte clock domain; every event crosses to the core clock through rtlnet_pulse_sync in
//     rtlnet_csi2_rx.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// Clocks: byte_clk (all logic); cfg_vc and cfg_dt are levels written while the receiver is idle and are synchronized here
//   (rtlnet_sync) from the core clock, so they are asynchronous inputs.
// -----------------------------------------------------------------------------
module rtlnet_csi2_rx_packet
  import rtlnet_csi2_rx_pkg::*;
(
  // Byte clock and its synchronous active-low reset.
  input  logic              byte_clk,
  input  logic              byte_resetn,

  // Filter configuration, asynchronous levels (core clock domain).
  input  logic [1:0]        cfg_vc,
  input  logic [5:0]        cfg_dt,

  // Pair stream from the D-PHY layer, byte_clk domain.
  input  logic              p_valid,
  input  logic [15:0]       p_data,
  input  logic              p_first,
  input  logic              p_end,

  // FIFO entries, byte_clk domain (no back pressure: the FIFO drops an entry when full).
  output logic              e_valid,
  output logic [ENT_W-1:0]  e_data,

  // Event pulses, byte_clk domain.
  output logic              ev_ecc_corr,
  output logic              ev_ecc_unc,
  output logic              ev_crc,
  output logic              ev_trunc,
  output logic              ev_dt,
  output logic              ev_frame,
  output logic              ev_orphan,
  output logic              ev_len,

  // Status, byte_clk domain.
  output logic              st_in_frame
);

  typedef enum logic [1:0] {S_IDLE, S_HDR, S_PAY, S_WAIT} state_t;

  state_t        state;
  logic [15:0]   hdr0;
  logic [15:0]   wc;
  logic [16:0]   bpos;            // bytes of the packet payload and CRC consumed before the current pair
  logic [2:0]    pj;              // pair index inside a group of five pairs
  logic [15:0]   crc;
  logic [7:0]    crc_lo;
  logic [15:0]   g0, g1, g3;
  logic [7:0]    h5;
  logic          pend_sof;
  logic          line_emitted;
  logic          eol_sent;

  logic [1:0]    vc_s;
  logic [5:0]    dt_s;

  rtlnet_sync #(.WIDTH(8), .STAGES(2)) u_cfg_sync (
    .clk(byte_clk), .resetn(byte_resetn), .d({cfg_vc, cfg_dt}), .q({vc_s, dt_s})
  );

  // Remainder of x by 5 without a divider: floor(x / 5) = (x * 52429) >> 18 for every 16-bit x.
  function automatic logic [2:0] mod5(input logic [15:0] x);
    logic [33:0] m;
    logic [15:0] q;
    m = 34'(x) * 34'd52429;
    q = 16'(m >> 18);
    mod5 = 3'(x - q * 16'd5);
  endfunction

  // ---------------------------------------------------------------------------
  // Header decode (combinational, on the second pair)
  // ---------------------------------------------------------------------------
  logic [25:0]  chk;
  logic [1:0]   chk_st;
  logic [23:0]  chk_bits;
  logic [7:0]   h_di;
  logic [15:0]  h_wc;
  logic         h_short;

  assign chk      = hdr_ecc_check({p_data[7:0], hdr0[15:8], hdr0[7:0]}, p_data[15:8]);
  assign chk_st   = chk[25:24];
  assign chk_bits = chk[23:0];
  assign h_di     = chk_bits[7:0];
  assign h_wc     = chk_bits[23:8];
  assign h_short  = (h_di[5:4] == 2'b00);

  // ---------------------------------------------------------------------------
  // Payload pair classification
  // ---------------------------------------------------------------------------
  logic [16:0]  idx0, idx1;
  logic [16:0]  wc17;
  logic         lo_pay, hi_pay, lo_crc_lo, lo_crc_hi, hi_crc_lo, hi_crc_hi;
  logic [15:0]  crc_n;
  logic [7:0]   crc_lo_n, crc_hi_n;
  logic         pay_done;
  logic         emit_a, emit_b;
  logic [16:0]  rem_a, rem_b;
  logic [7:0]   b4, b8, b9;
  logic [39:0]  pix_a, pix_b;

  assign idx0      = bpos;
  assign idx1      = bpos + 17'd1;
  assign wc17      = {1'b0, wc};
  assign lo_pay    = (idx0 < wc17);
  assign hi_pay    = (idx1 < wc17);
  assign lo_crc_lo = (idx0 == wc17);
  assign lo_crc_hi = (idx0 == wc17 + 17'd1);
  assign hi_crc_lo = (idx1 == wc17);
  assign hi_crc_hi = (idx1 == wc17 + 17'd1);
  assign pay_done  = lo_crc_hi || hi_crc_hi;

  always_comb begin
    crc_n = crc;
    if (lo_pay) crc_n = crc16_byte(crc_n, p_data[7:0]);
    if (hi_pay) crc_n = crc16_byte(crc_n, p_data[15:8]);
    crc_lo_n = crc_lo;
    if (lo_crc_lo)      crc_lo_n = p_data[7:0];
    else if (hi_crc_lo) crc_lo_n = p_data[15:8];
    crc_hi_n = lo_crc_hi ? p_data[7:0] : p_data[15:8];
  end

  assign b4 = p_data[7:0];
  assign b8 = p_data[7:0];
  assign b9 = p_data[15:8];
  assign pix_a = {{g1[15:8], b4[7:6]}, {g1[7:0], b4[5:4]}, {g0[15:8], b4[3:2]}, {g0[7:0], b4[1:0]}};
  assign pix_b = {{b8, b9[7:6]}, {g3[15:8], b9[5:4]}, {g3[7:0], b9[3:2]}, {h5, b9[1:0]}};
  assign rem_a  = wc17 - idx0 - 17'd1;
  assign rem_b  = wc17 - idx1 - 17'd1;
  assign emit_a = (state == S_PAY) && p_valid && (pj == 3'd2) && lo_pay;
  assign emit_b = (state == S_PAY) && p_valid && (pj == 3'd4) && hi_pay;

  logic abort_now;
  assign abort_now = p_end || (p_valid && p_first && (state != S_IDLE));

  function automatic logic [ENT_W-1:0] make_entry(input logic fe, input logic eol, input logic sof, input logic [2:0] cnt,
                                                  input logic [39:0] pix);
    make_entry = {fe, eol, sof, cnt, pix};
  endfunction

  always_ff @(posedge byte_clk) begin
    if (!byte_resetn) begin
      state        <= S_IDLE;
      hdr0         <= '0;
      wc           <= '0;
      bpos         <= '0;
      pj           <= '0;
      crc          <= 16'hFFFF;
      crc_lo       <= '0;
      g0           <= '0;
      g1           <= '0;
      g3           <= '0;
      h5           <= '0;
      pend_sof     <= 1'b0;
      line_emitted <= 1'b0;
      eol_sent     <= 1'b0;
      st_in_frame  <= 1'b0;
      e_valid      <= 1'b0;
      e_data       <= '0;
      ev_ecc_corr  <= 1'b0;
      ev_ecc_unc   <= 1'b0;
      ev_crc       <= 1'b0;
      ev_trunc     <= 1'b0;
      ev_dt        <= 1'b0;
      ev_frame     <= 1'b0;
      ev_orphan    <= 1'b0;
      ev_len       <= 1'b0;
    end else begin
      e_valid     <= 1'b0;
      ev_ecc_corr <= 1'b0;
      ev_ecc_unc  <= 1'b0;
      ev_crc      <= 1'b0;
      ev_trunc    <= 1'b0;
      ev_dt       <= 1'b0;
      ev_frame    <= 1'b0;
      ev_orphan   <= 1'b0;
      ev_len      <= 1'b0;

      // End or restart of a burst: an unfinished packet is truncated.
      if (abort_now) begin
        if ((state == S_HDR) || (state == S_PAY)) begin
          ev_trunc <= 1'b1;
          if (line_emitted && !eol_sent) begin
            e_valid <= 1'b1;
            e_data  <= make_entry(1'b0, 1'b1, 1'b0, 3'd0, 40'd0);
          end
        end
        state        <= S_IDLE;
        line_emitted <= 1'b0;
        eol_sent     <= 1'b0;
      end

      if (p_valid && p_first) begin
        // First pair of a burst: the packet header starts (an unfinished packet was truncated above).
        hdr0  <= p_data;
        state <= S_HDR;
      end else if (p_valid) begin
        case (state)
          S_HDR: begin
            begin
              state <= S_WAIT;
              if (chk_st == 2'd2) begin
                ev_ecc_unc <= 1'b1;
              end else begin
                if (chk_st == 2'd1) ev_ecc_corr <= 1'b1;
                if (h_di[7:6] != vc_s) begin
                  // another virtual channel: dropped silently
                end else if (h_short) begin
                  case (h_di[5:0])
                    DT_FS: begin
                      ev_frame    <= 1'b1;
                      st_in_frame <= 1'b1;
                      pend_sof    <= 1'b1;
                    end
                    DT_FE: begin
                      if (st_in_frame) begin
                        e_valid     <= 1'b1;
                        e_data      <= make_entry(1'b1, 1'b0, 1'b0, 3'd0, 40'd0);
                        st_in_frame <= 1'b0;
                        pend_sof    <= 1'b0;
                      end
                    end
                    DT_LS, DT_LE: begin
                    end
                    default: ev_dt <= 1'b1;
                  endcase
                end else if (h_di[5:0] != dt_s) begin
                  ev_dt <= 1'b1;
                end else if (!st_in_frame) begin
                  ev_orphan <= 1'b1;
                end else if (h_wc == 16'd0) begin
                  ev_len <= 1'b1;
                end else begin
                  if (mod5(h_wc) != 3'd0) ev_len <= 1'b1;
                  state        <= S_PAY;
                  wc           <= h_wc;
                  bpos         <= '0;
                  pj           <= '0;
                  crc          <= 16'hFFFF;
                  crc_lo       <= '0;
                  line_emitted <= 1'b0;
                  eol_sent     <= 1'b0;
                end
              end
            end
          end
          S_PAY: begin
            begin
              crc    <= crc_n;
              crc_lo <= crc_lo_n;
              bpos   <= bpos + 17'd2;
              pj     <= (pj == 3'd4) ? 3'd0 : (pj + 3'd1);
              case (pj)
                3'd0: g0 <= p_data;
                3'd1: g1 <= p_data;
                3'd2: h5 <= p_data[15:8];
                3'd3: g3 <= p_data;
                default: begin
                end
              endcase
              if (emit_a) begin
                e_valid      <= 1'b1;
                e_data       <= make_entry(1'b0, (rem_a < 17'd5), pend_sof, 3'd4, pix_a);
                pend_sof     <= 1'b0;
                line_emitted <= 1'b1;
                if (rem_a < 17'd5) eol_sent <= 1'b1;
              end else if (emit_b) begin
                e_valid      <= 1'b1;
                e_data       <= make_entry(1'b0, (rem_b < 17'd5), pend_sof, 3'd4, pix_b);
                pend_sof     <= 1'b0;
                line_emitted <= 1'b1;
                if (rem_b < 17'd5) eol_sent <= 1'b1;
              end
              if (pay_done) begin
                state <= S_WAIT;
                if ({crc_hi_n, crc_lo_n} != crc_n) ev_crc <= 1'b1;
              end
            end
          end
          default: begin
          end
        endcase
      end
    end
  end

endmodule
