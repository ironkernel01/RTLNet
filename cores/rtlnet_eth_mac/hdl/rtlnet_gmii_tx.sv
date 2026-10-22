// -----------------------------------------------------------------------------
// File: rtlnet_gmii_tx.sv
// Purpose: GMII byte transmitter of the RTLNet tri-speed MAC. Takes whole
//   frames from the TX packet FIFO as 64-bit RTLNet beats and sends preamble,
//   SFD, the client bytes, zero padding to MIN_FRAME_BYTES, the FCS and the
//   interframe gap, one byte per byte clock enable.
// Overview:
//   * Byte clock enable: every register except the frame_sent strobe
//     advances only in a cycle with ce = 1 (1 at 1000 Mb/s, one pulse per
//     byte period at 10/100), so one module serves the three speeds.
//   * Double-buffered downsizer: `active` drains onto GMII lane by lane,
//     `next` is a prefetched beat. s_ready = resetn && ce && !next_valid, so
//     every FIFO pop lands in `next` in the same clock (a pop while ce is low
//     would never be latched). Inside S_DATA the last lane of a non-final
//     beat swaps `next` into `active` on the same edge (no gap); a separate
//     promotion fills an empty `active` (first beat of a frame).
//   * The FIFO publishes only whole frames, so once a frame starts every beat
//     is resident and arrives within one beat time: no underflow. A
//     simulation-only check reports a violation.
//   * States: S_IDLE (GMII idle, counts the interframe gap), S_PREAMBLE (7 x
//     0x55, 0xD5), S_DATA, S_PAD (0x00 octets up to MIN_FRAME_BYTES), S_FCS
//     (~CRC, low octet first), S_DISCARD (frame dropped while disabled).
//   * Interframe gap: IFG_BYTES byte times with TX_EN low between the last
//     FCS octet and the next preamble (96 bit times at every speed).
//   * Enable: sampled when a frame would start. With enable low the frame is
//     consumed from the FIFO (one beat per ce) and not sent (S_DISCARD); a
//     frame already started always completes.
//   * frame_sent: one clk pulse when the last FCS octet is launched.
//   * gmii_tx_er is always 0 (the MAC never signals a transmit error).
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk is clk125; resetn is synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_gmii_tx #(
  parameter int MIN_FRAME_BYTES = rtlnet_pkg::ETH_MIN_FRAME_BYTES,  // pad target, FCS excluded
  parameter int IFG_BYTES       = 12                                 // interframe gap, byte times
)(
  // Transmit byte clock (clk125) and its synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Pacing and control, clk domain: byte clock enable from the pin layer
  // (1 at 1000 Mb/s, one pulse per byte at 10/100) and the transmit enable
  // (level; low = frames are consumed and discarded at frame boundaries).
  input  logic        ce,
  input  logic        enable,

  // Frame beats in from the TX packet FIFO read side, clk domain: byte 0 in
  // s_data[7:0], contiguous tkeep on the final beat, no preamble or FCS.
  // s_ready is combinational from a register and ce.
  input  logic [63:0] s_data,
  input  logic [7:0]  s_keep,
  input  logic        s_valid,
  input  logic        s_last,
  output logic        s_ready,

  // GMII transmit byte stream to the pin layer, clk domain, registered.
  output logic [7:0]  gmii_txd,
  output logic        gmii_tx_en,
  output logic        gmii_tx_er,

  // Event, clk domain: one-clock pulse per frame sent (last FCS octet).
  output logic        frame_sent
);

  import rtlnet_pkg::*;

  localparam logic [2:0] S_IDLE     = 3'd0;
  localparam logic [2:0] S_PREAMBLE = 3'd1;
  localparam logic [2:0] S_DATA     = 3'd2;
  localparam logic [2:0] S_PAD      = 3'd3;
  localparam logic [2:0] S_FCS      = 3'd4;
  localparam logic [2:0] S_DISCARD  = 3'd5;

  localparam logic [2:0] PREAMBLE_OCTETS = 3'd7;   // 0x55 octets before the SFD
  localparam logic [1:0] FCS_LAST_LANE   = 2'd3;
  localparam int         COUNT_W         = clog2i(MIN_FRAME_BYTES + 1);
  localparam int         IFG_W           = clog2i(IFG_BYTES + 1);

  generate
    if (MIN_FRAME_BYTES < 1 || IFG_BYTES < 1) begin : g_bad_config
      $fatal(1, "rtlnet_gmii_tx: MIN_FRAME_BYTES=%0d and IFG_BYTES=%0d must be at least 1", MIN_FRAME_BYTES, IFG_BYTES);
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // State and downsizer registers
  // ---------------------------------------------------------------------------
  logic [2:0]         state;
  logic [63:0]        active_data;
  logic [7:0]         active_keep;
  logic               active_last;
  logic               active_valid;
  logic [2:0]         lane;          // byte of active_data sent next
  logic [63:0]        next_data;
  logic [7:0]         next_keep;
  logic               next_last;
  logic               next_valid;
  logic [2:0]         pre_count;     // preamble octets sent (7 = SFD next)
  logic [COUNT_W-1:0] byte_count;    // data + pad octets sent, saturating at MIN_FRAME_BYTES
  logic [31:0]        crc;
  logic [31:0]        fcs_reg;       // ~crc, latched at the first FCS octet
  logic [1:0]         fcs_lane;
  logic [IFG_W-1:0]   ifg_count;

  // ---------------------------------------------------------------------------
  // Combinational helpers
  // ---------------------------------------------------------------------------
  logic [3:0]         active_count;
  logic [7:0]         active_byte;
  logic               active_last_lane;
  logic [31:0]        crc_data;
  logic [31:0]        crc_pad;
  logic [COUNT_W:0]   count_plus1;
  logic               pad_more;
  logic [COUNT_W-1:0] count_inc;

  assign active_count     = keep_bytes(active_keep);
  assign active_byte      = active_data[8*lane +: 8];
  assign active_last_lane = ({1'b0, lane} == (active_count - 4'd1));
  assign crc_data         = crc32_byte(crc, active_byte);
  assign crc_pad          = crc32_byte(crc, 8'h00);
  assign count_plus1      = {1'b0, byte_count} + 1'b1;
  assign pad_more         = (count_plus1 < (COUNT_W+1)'(MIN_FRAME_BYTES));
  assign count_inc        = (byte_count == COUNT_W'(MIN_FRAME_BYTES)) ? byte_count : (byte_count + 1'b1);
  assign s_ready          = resetn && ce && !next_valid;

  // Transmitter: prefetch, promotion and the frame state machine, all on ce.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      state        <= S_IDLE;
      active_data  <= '0;
      active_keep  <= '0;
      active_last  <= 1'b0;
      active_valid <= 1'b0;
      lane         <= '0;
      next_data    <= '0;
      next_keep    <= '0;
      next_last    <= 1'b0;
      next_valid   <= 1'b0;
      pre_count    <= '0;
      byte_count   <= '0;
      crc          <= CRC32_INITIAL;
      fcs_reg      <= '0;
      fcs_lane     <= '0;
      ifg_count    <= '0;
      gmii_txd     <= '0;
      gmii_tx_en   <= 1'b0;
      gmii_tx_er   <= 1'b0;
      frame_sent   <= 1'b0;
    end else begin
      frame_sent <= 1'b0;
      if (ce) begin
        gmii_tx_er <= 1'b0;

        // Prefetch into `next` whenever it is empty.
        if (s_valid && s_ready) begin
          next_data  <= s_data;
          next_keep  <= s_keep;
          next_last  <= s_last;
          next_valid <= 1'b1;
        end

        // Promotion into an empty `active` (first beat of a frame).
        if (!active_valid && next_valid) begin
          active_data  <= next_data;
          active_keep  <= next_keep;
          active_last  <= next_last;
          active_valid <= 1'b1;
          next_valid   <= 1'b0;
          lane         <= '0;
        end

        case (state)
          S_IDLE: begin
            gmii_tx_en <= 1'b0;
            if (ifg_count != '0) begin
              ifg_count <= ifg_count - 1'b1;
            end else if (active_valid) begin
              if (enable) begin
                crc        <= CRC32_INITIAL;
                byte_count <= '0;
                pre_count  <= '0;
                state      <= S_PREAMBLE;
              end else begin
                state <= S_DISCARD;
              end
            end
          end

          S_PREAMBLE: begin
            gmii_tx_en <= 1'b1;
            gmii_txd   <= (pre_count == PREAMBLE_OCTETS) ? ETH_SFD : ETH_PREAMBLE;
            if (pre_count == PREAMBLE_OCTETS) state <= S_DATA;
            else                              pre_count <= pre_count + 1'b1;
          end

          S_DATA: begin
            if (active_valid) begin
              gmii_tx_en <= 1'b1;
              gmii_txd   <= active_byte;
              crc        <= crc_data;
              byte_count <= count_inc;
              if (active_last_lane) begin
                if (active_last) begin
                  active_valid <= 1'b0;
                  state        <= pad_more ? S_PAD : S_FCS;
                end else if (next_valid) begin
                  // Same-edge swap: `active` never empties inside a frame.
                  active_data <= next_data;
                  active_keep <= next_keep;
                  active_last <= next_last;
                  next_valid  <= 1'b0;
                  lane        <= '0;
                end else begin
                  active_valid <= 1'b0;
                end
              end else begin
                lane <= lane + 1'b1;
              end
            end
          end

          S_PAD: begin
            gmii_tx_en <= 1'b1;
            gmii_txd   <= 8'h00;
            crc        <= crc_pad;
            byte_count <= count_inc;
            if (!pad_more) state <= S_FCS;
          end

          S_FCS: begin
            gmii_tx_en <= 1'b1;
            if (fcs_lane == 2'd0) begin
              fcs_reg  <= ~crc;
              gmii_txd <= ~crc[7:0];
            end else begin
              gmii_txd <= fcs_reg[8*fcs_lane +: 8];
            end
            if (fcs_lane == FCS_LAST_LANE) begin
              fcs_lane   <= '0;
              ifg_count  <= IFG_W'(IFG_BYTES - 1);
              frame_sent <= 1'b1;
              state      <= S_IDLE;
            end else begin
              fcs_lane <= fcs_lane + 1'b1;
            end
          end

          S_DISCARD: begin
            gmii_tx_en <= 1'b0;
            if (active_valid) begin
              if (active_last) begin
                active_valid <= 1'b0;
                state        <= S_IDLE;
              end else if (next_valid) begin
                active_data <= next_data;
                active_keep <= next_keep;
                active_last <= next_last;
                next_valid  <= 1'b0;
                lane        <= '0;
              end else begin
                active_valid <= 1'b0;
              end
            end
          end

          default: begin
            gmii_tx_en <= 1'b0;
            fcs_lane   <= '0;
            state      <= S_IDLE;
          end
        endcase
      end
    end
  end

  // Simulation-only: a frame in S_DATA without a beat would repeat bytes on
  // the wire; the store-and-forward FIFO makes it impossible.
  // synthesis translate_off
  always @(posedge clk) begin
    if (resetn && ce && state == S_DATA && !active_valid)
      $error("%m: TX underflow, no beat available inside a frame");
  end
  // synthesis translate_on

endmodule
