// -----------------------------------------------------------------------------
// File: rtlnet_packet_fifo.sv
// Purpose: store-and-forward queue of whole frames in fixed-size slots, with
//   ownership of a slot handed between the write clock and the read clock by a
//   Gray-coded frame counter that moves by exactly one per frame.
// Overview:
//   * Sizing: FIFO_KB kilobytes of frame storage (8 payload bytes per 73-bit
//     word, so DEPTH_WORDS = FIFO_KB * 128). Each slot holds one frame of up to
//     MAX_FRAME_BYTES rounded up to a power-of-two word count:
//       1518 B -> 190 words -> 256-word (2 KiB) slots, so FIFO_KB = 4 gives 2
//       slots, 8 gives 4, 16 gives 8. At least two power-of-two slots are
//       required; any other size stops elaboration with $fatal.
//   * Write side (s_clk): a frame is written into a reserved slot and published
//     only on a good final beat. s_bad (accumulated over the frame, final beat
//     included), a frame longer than a slot, or a full queue drops the frame:
//     the count does not advance. With DROP_WHEN_FULL = 0, s_ready is low only
//     between frames while the queue is full (back-pressure before the first
//     beat; a started frame is never stalled). With DROP_WHEN_FULL = 1 s_ready
//     stays high and a frame that finds the queue full is consumed and dropped
//     (for sources that cannot stall, such as a PHY receiver).
//   * Read side (m_clk): one beat per clock while m_ready is high, no bubble
//     inside a frame, one idle cycle between frames. Data is held while m_ready
//     is low. A slot returns to the writer after its last beat is accepted.
//   * Events: overflow and bad_frame are one-clock pulses in m_clk (toggle
//     crossings; two events closer than the synchronizer round trip can merge).
//   * Storage is one rtlnet_ram_core instance; RAM_STYLE passes through and
//     the technology comes from rtlnet_technology.svh.
//   * Both sides must reset together (derive both resets from one assertion);
//     independent reset of one side is not supported.
//   * Instance names matter: scripts/rtlnet_constrain_cdc.tcl bounds the Gray
//     crossings of every cell matching `*u_*_fifo` by the registers
//     s_gray -> s_gray_m1 and m_gray -> m_gray_s1.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version (whole-frame slot FIFO; RAM through
//     rtlnet_ram_core; size in kilobytes).
// Clocks: s_clk (producer), m_clk (consumer); any frequencies, any relation.
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_packet_fifo #(
  parameter string RAM_STYLE       = "block",       // "block" | "distributed"
  parameter int    FIFO_KB         = 8,             // frame storage, kilobytes
  parameter int    MAX_FRAME_BYTES = rtlnet_pkg::ETH_MAX_FRAME_BYTES,
  parameter bit    DROP_WHEN_FULL  = 1'b0
)(
  // Write side, s_clk domain: RTLNet stream plus a frame-bad flag that is
  // accumulated over every accepted beat.
  input  logic        s_clk,
  input  logic        s_resetn,          // synchronous to s_clk, active low
  input  logic [63:0] s_data,
  input  logic [7:0]  s_keep,
  input  logic        s_valid,
  output logic        s_ready,
  input  logic        s_last,
  input  logic        s_bad,

  // Read side, m_clk domain: whole frames only, held while m_ready is low.
  input  logic        m_clk,
  input  logic        m_resetn,          // synchronous to m_clk, active low
  output logic [63:0] m_data,
  output logic [7:0]  m_keep,
  output logic        m_valid,
  input  logic        m_ready,
  output logic        m_last,

  // Events, m_clk domain, one-cycle pulses.
  output logic        overflow,          // a frame found no free slot
  output logic        bad_frame          // a frame was dropped as bad or oversize
);

  localparam int DEPTH_WORDS = FIFO_KB * 128;
  localparam int WORD_BITS   = rtlnet_pkg::clog2i((MAX_FRAME_BYTES + 7) / 8);
  localparam int SLOT_WORDS  = 1 << WORD_BITS;
  localparam int SLOTS       = DEPTH_WORDS / SLOT_WORDS;
  localparam int SLOT_BITS   = rtlnet_pkg::clog2i(SLOTS);
  localparam int PTR_BITS    = SLOT_BITS + 1;
  localparam int ADDR_W      = SLOT_BITS + WORD_BITS;
  localparam int MEM_W       = 73;                  // {last, keep[7:0], data[63:0]}

  // Slot geometry check: fails elaboration in synthesis and simulation.
  generate
    if (SLOTS < 2 || (SLOTS & (SLOTS - 1)) != 0 || DEPTH_WORDS != SLOTS * SLOT_WORDS) begin : g_bad_config
      $fatal(1, "rtlnet_packet_fifo: FIFO_KB=%0d with MAX_FRAME_BYTES=%0d gives SLOT_WORDS=%0d, SLOTS=%0d; need at least two power-of-two slots",
             FIFO_KB, MAX_FRAME_BYTES, SLOT_WORDS, SLOTS);
    end
  endgenerate

  localparam logic [1:0] S_IDLE  = 2'd0;
  localparam logic [1:0] S_STORE = 2'd1;
  localparam logic [1:0] S_DROP  = 2'd2;

  // ---------------------------------------------------------------------------
  // Write-side state (s_clk)
  // ---------------------------------------------------------------------------
  logic [1:0]           s_state;
  logic [PTR_BITS-1:0]  s_frame;
  logic [PTR_BITS-1:0]  s_gray;
  logic [WORD_BITS-1:0] s_word;
  logic                 s_packet_bad;
  logic [1:0]           events_s;            // [0] overflow toggle, [1] bad-frame toggle
  `RTLNET_SYNC_ATTR
  logic [PTR_BITS-1:0]  m_gray_s1;
  `RTLNET_SYNC_ATTR
  logic [PTR_BITS-1:0]  m_gray_s2;

  // ---------------------------------------------------------------------------
  // Read-side state (m_clk)
  // ---------------------------------------------------------------------------
  logic [PTR_BITS-1:0]  m_frame;
  logic [PTR_BITS-1:0]  m_gray;
  logic [WORD_BITS-1:0] m_word;
  logic [1:0]           events_seen;
  `RTLNET_SYNC_ATTR
  logic [PTR_BITS-1:0]  s_gray_m1;
  `RTLNET_SYNC_ATTR
  logic [PTR_BITS-1:0]  s_gray_m2;
  `RTLNET_SYNC_ATTR
  logic [1:0]           events_m1;
  `RTLNET_SYNC_ATTR
  logic [1:0]           events_m2;

  // ---------------------------------------------------------------------------
  // Combinational helpers
  // ---------------------------------------------------------------------------
  logic                 full;
  logic                 empty;
  logic                 store_enable;
  logic                 rd_enable;
  logic [PTR_BITS-1:0]  s_increment;
  logic [PTR_BITS-1:0]  m_increment;
  logic [PTR_BITS-1:0]  m_full_gray;
  logic [ADDR_W-1:0]    wr_addr;
  logic [ADDR_W-1:0]    rd_addr;
  logic [MEM_W-1:0]     output_word;

  assign s_increment  = s_frame + 1'b1;
  assign m_increment  = m_frame + 1'b1;
  // Full when the writer is exactly one wrap ahead: the top two Gray bits differ.
  assign m_full_gray  = m_gray_s2 ^ {2'b11, {(PTR_BITS-2){1'b0}}};
  assign full         = (s_gray == m_full_gray);
  assign empty        = (m_gray == s_gray_m2);
  assign s_ready      = s_resetn && ((s_state != S_IDLE) || !full || DROP_WHEN_FULL);
  assign store_enable = s_valid && s_ready && (s_state == S_STORE || (s_state == S_IDLE && !full));
  assign wr_addr      = {s_frame[SLOT_BITS-1:0], s_word};
  assign rd_enable    = (!m_valid || m_ready) && !(m_valid && m_last) && !empty;
  assign rd_addr      = {m_frame[SLOT_BITS-1:0], m_word};
  assign {m_last, m_keep, m_data} = output_word;
  assign overflow     = events_m2[0] ^ events_seen[0];
  assign bad_frame    = events_m2[1] ^ events_seen[1];

  // The write side reserves a whole slot before it accepts a frame's first
  // word and publishes it (frame count + 1, Gray updated) on a good last beat.
  always_ff @(posedge s_clk) begin
    if (!s_resetn) begin
      s_state      <= S_IDLE;
      s_frame      <= '0;
      s_gray       <= '0;
      s_word       <= '0;
      s_packet_bad <= 1'b0;
      events_s     <= '0;
      m_gray_s1    <= '0;
      m_gray_s2    <= '0;
    end else begin
      m_gray_s1 <= m_gray;
      m_gray_s2 <= m_gray_s1;
      if (s_valid && s_ready) begin
        case (s_state)
          S_IDLE, S_STORE: begin
            if (s_state == S_IDLE && full) begin
              events_s[0] <= ~events_s[0];
              s_state     <= s_last ? S_IDLE : S_DROP;
            end else if (s_last) begin
              if (s_packet_bad || s_bad) begin
                events_s[1] <= ~events_s[1];
              end else begin
                s_frame <= s_increment;
                s_gray  <= (s_increment >> 1) ^ s_increment;
              end
              s_word       <= '0;
              s_packet_bad <= 1'b0;
              s_state      <= S_IDLE;
            end else if (s_word == WORD_BITS'(SLOT_WORDS - 1)) begin
              events_s[1]  <= ~events_s[1];
              s_state      <= S_DROP;
              s_word       <= '0;
              s_packet_bad <= 1'b0;
            end else begin
              s_word       <= s_word + 1'b1;
              s_packet_bad <= s_packet_bad || s_bad;
              s_state      <= S_STORE;
            end
          end
          S_DROP: begin
            if (s_last) s_state <= S_IDLE;
          end
          default: begin
            s_state      <= S_IDLE;
            s_word       <= '0;
            s_packet_bad <= 1'b0;
          end
        endcase
      end
    end
  end

  // Storage: the write enable is gated by slot ownership, so a full queue can
  // never be overwritten. The RAM output register is the read data register.
  rtlnet_ram_core #(
    .RAM_STYLE    (RAM_STYLE),
    .CLOCKING     ("INDEPENDENT"),
    .DATA_W       (MEM_W),
    .ADDR_W       (ADDR_W),
    .READ_LATENCY (1)
  ) u_ram (
    .wr_clk    (s_clk),
    .wr_en     (store_enable),
    .wr_addr   (wr_addr),
    .wr_data   ({s_last, s_keep, s_data}),
    .rd_clk    (m_clk),
    .rd_resetn (m_resetn),
    .rd_en     (rd_enable),
    .rd_addr   (rd_addr),
    .rd_data   (output_word)
  );

  // The read side presents a committed slot word by word and returns the slot
  // only after its last word is accepted, so output stalls are safe.
  always_ff @(posedge m_clk) begin
    if (!m_resetn) begin
      m_frame     <= '0;
      m_gray      <= '0;
      m_word      <= '0;
      m_valid     <= 1'b0;
      s_gray_m1   <= '0;
      s_gray_m2   <= '0;
      events_m1   <= '0;
      events_m2   <= '0;
      events_seen <= '0;
    end else begin
      s_gray_m1   <= s_gray;
      s_gray_m2   <= s_gray_m1;
      events_m1   <= events_s;
      events_m2   <= events_m1;
      events_seen <= events_m2;
      if (m_valid && m_ready && m_last) begin
        m_frame <= m_increment;
        m_gray  <= (m_increment >> 1) ^ m_increment;
        m_word  <= '0;
        m_valid <= 1'b0;
      end else if (!m_valid || m_ready) begin
        m_valid <= !empty;
        if (!empty) m_word <= m_word + 1'b1;
      end
    end
  end

  // Simulation-only checks: ownership is guarded structurally above; these
  // make any violation, and any unknown output after reset, visible.
  // synthesis translate_off
  always @(posedge s_clk) begin
    if (s_resetn && store_enable && full) $fatal(1, "%m: packet FIFO write without slot ownership");
  end
  always @(posedge m_clk) begin
    if (m_resetn && (^{m_valid, m_data, m_keep, m_last, overflow, bad_frame} === 1'bx))
      $fatal(1, "%m: unknown packet FIFO output after reset");
  end
  // synthesis translate_on

endmodule
