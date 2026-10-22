// -----------------------------------------------------------------------------
// File: rtlnet_gmii_rx.sv
// Purpose: GMII byte receiver of the RTLNet tri-speed MAC. Finds the start of
//   frame delimiter, strips preamble, SFD and FCS, checks the CRC-32 residue
//   and packs the client bytes into 64-bit RTLNet beats with one verdict per
//   frame on the final beat.
// Overview:
//   * Byte clock enable: every register advances only in a cycle with ce = 1
//     (1 at 1000 Mb/s; once per byte and in every RX_DV-low cycle at 10/100).
//     In a cycle with ce = 0 the output strobes are forced low, so every beat
//     is presented for exactly one clock (the frame guard and the packet FIFO
//     downstream have no ready).
//   * States: S_IDLE waits for RX_DV (a first RX_DV octet equal to the SFD
//     goes straight to S_DATA); S_PREAMBLE accepts any octet until the SFD
//     (value and count of the 0x55 octets are not checked); S_DATA folds
//     every byte into the CRC and the 4-byte delay line; S_FLUSH presents the
//     final beat, its tkeep and the verdict together one clock after RX_DV
//     fell, when the CRC over the last FCS octet is in its register.
//   * FCS stripping: the delay line holds the last four received bytes; a
//     byte leaves it only when four newer bytes exist, so the four FCS octets
//     never reach the client. The released byte waits one accepted byte in a
//     staging register so the final client byte is known to be final before
//     it is packed.
//   * Verdict (m_bad, final beat only): RX_ER seen with RX_DV on any octet
//     from the first RX_DV octet to the last FCS octet, or a CRC-32 register
//     not equal to the residue 0xDEBB20E3 (IEEE 802.3 clause 3.2.9). A frame
//     with one to four octets after the SFD produces one bad 1-byte beat, so
//     it is dropped and counted downstream; a frame that ends before the SFD
//     produces nothing. Runt and oversize frames are forwarded with their
//     CRC verdict; the frame guard judges the length.
//   * Pure fabric logic, no vendor primitive.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk is rx_clk (125 / 25 / 2.5 MHz, stops on link loss); resetn is
//   synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_gmii_rx (
  // Receive clock (the PHY's RXC through the pin layer) and the receive-path
  // reset, synchronous to it, active low.
  input  logic        clk,
  input  logic        resetn,

  // GMII receive byte stream, clk domain, from the RGMII pin layer: data,
  // data valid, receive error, and the byte clock enable (1 at 1000 Mb/s;
  // at 10/100 Mb/s 1 for every delivered byte and every RX_DV-low cycle).
  input  logic [7:0]  gmii_rxd,
  input  logic        gmii_rx_dv,
  input  logic        gmii_rx_er,
  input  logic        ce,

  // Frame beats out, clk domain, single-cycle strobes with no ready: byte 0
  // of the frame in m_data[7:0], contiguous tkeep on the final beat, no
  // preamble/SFD/FCS, receive padding kept. m_bad is the frame verdict, valid
  // on the m_last beat and 0 on every other beat.
  output logic [63:0] m_data,
  output logic [7:0]  m_keep,
  output logic        m_valid,
  output logic        m_last,
  output logic        m_bad
);

  import rtlnet_pkg::*;

  localparam logic [1:0] S_IDLE     = 2'd0;
  localparam logic [1:0] S_PREAMBLE = 2'd1;
  localparam logic [1:0] S_DATA     = 2'd2;
  localparam logic [1:0] S_FLUSH    = 2'd3;

  localparam logic [2:0] FCS_BYTES  = 3'd4;           // octets held back by the delay line
  localparam logic [2:0] LAST_LANE  = 3'd7;

  // ---------------------------------------------------------------------------
  // State, delay line, CRC and packer
  // ---------------------------------------------------------------------------
  logic [1:0]  state;
  logic [31:0] delay_line;     // last four received bytes, oldest in [31:24]
  logic [2:0]  fill_count;     // bytes received after the SFD, saturating at 4
  logic [31:0] crc;            // CRC-32 register over every byte after the SFD
  logic        er_seen;        // RX_ER seen on an RX_DV octet of this frame
  logic [7:0]  held_byte;      // released client byte waiting for the next byte
  logic        held_valid;
  logic [63:0] pack_data;      // beat under construction, unused lanes zero
  logic [2:0]  pack_count;     // lanes filled in pack_data (0..7)

  // ---------------------------------------------------------------------------
  // Combinational helpers
  // ---------------------------------------------------------------------------
  logic [31:0] crc_next;
  logic        armed;
  logic [63:0] tail_data;
  logic [7:0]  tail_keep;
  logic        frame_bad;

  assign crc_next  = crc32_byte(crc, gmii_rxd);
  assign armed     = (fill_count == FCS_BYTES);
  assign tail_data = pack_data | ({56'd0, held_byte} << {pack_count, 3'b000});
  assign tail_keep = keep_mask({1'b0, pack_count} + 4'd1);
  assign frame_bad = er_seen || (crc != CRC32_RESIDUE);

  // Receiver: one registered state variable; every register advances on ce.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      state      <= S_IDLE;
      delay_line <= '0;
      fill_count <= '0;
      crc        <= CRC32_INITIAL;
      er_seen    <= 1'b0;
      held_byte  <= '0;
      held_valid <= 1'b0;
      pack_data  <= '0;
      pack_count <= '0;
      m_data     <= '0;
      m_keep     <= '0;
      m_valid    <= 1'b0;
      m_last     <= 1'b0;
      m_bad      <= 1'b0;
    end else if (!ce) begin
      m_valid <= 1'b0;
      m_last  <= 1'b0;
      m_bad   <= 1'b0;
    end else begin
      m_valid <= 1'b0;
      m_last  <= 1'b0;
      m_bad   <= 1'b0;
      case (state)
        S_IDLE: begin
          delay_line <= '0;
          fill_count <= '0;
          crc        <= CRC32_INITIAL;
          held_valid <= 1'b0;
          pack_data  <= '0;
          pack_count <= '0;
          if (gmii_rx_dv) begin
            er_seen <= gmii_rx_er;
            state   <= (gmii_rxd == ETH_SFD) ? S_DATA : S_PREAMBLE;
          end
        end

        S_PREAMBLE: begin
          if (!gmii_rx_dv) begin
            state <= S_IDLE;
          end else begin
            er_seen <= er_seen || gmii_rx_er;
            if (gmii_rxd == ETH_SFD) state <= S_DATA;
          end
        end

        S_DATA: begin
          if (gmii_rx_dv) begin
            crc        <= crc_next;
            er_seen    <= er_seen || gmii_rx_er;
            delay_line <= {delay_line[23:0], gmii_rxd};
            held_byte  <= delay_line[31:24];
            held_valid <= armed;
            if (!armed) fill_count <= fill_count + 1'b1;
            // The staged byte is not the final client byte (RX_DV is still
            // high): pack it, emitting a full beat on lane 7.
            if (held_valid) begin
              if (pack_count == LAST_LANE) begin
                m_data     <= {held_byte, pack_data[55:0]};
                m_keep     <= 8'hFF;
                m_valid    <= 1'b1;
                pack_data  <= '0;
                pack_count <= '0;
              end else begin
                pack_data[8*pack_count +: 8] <= held_byte;
                pack_count                   <= pack_count + 1'b1;
              end
            end
          end else begin
            state <= S_FLUSH;
          end
        end

        S_FLUSH: begin
          if (held_valid) begin
            m_data  <= tail_data;
            m_keep  <= tail_keep;
            m_valid <= 1'b1;
            m_last  <= 1'b1;
            m_bad   <= frame_bad;
          end else if (fill_count != 3'd0) begin
            // One to four octets after the SFD: a bad 1-byte frame.
            m_data  <= '0;
            m_keep  <= 8'h01;
            m_valid <= 1'b1;
            m_last  <= 1'b1;
            m_bad   <= 1'b1;
          end
          held_valid <= 1'b0;
          pack_data  <= '0;
          pack_count <= '0;
          state      <= S_IDLE;
        end

        default: begin
          held_valid <= 1'b0;
          pack_data  <= '0;
          pack_count <= '0;
          state      <= S_IDLE;
        end
      endcase
    end
  end

endmodule
