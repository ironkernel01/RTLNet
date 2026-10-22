// -----------------------------------------------------------------------------
// File: rtlnet_eth_mac_regs.sv
// Purpose: register file of rtlnet_eth_mac in axis_clk: standard header,
//   CTRL, STATUS, RX_CLK_RATE, RX_IDELAY_TAP and the four frame counters,
//   plus the registered status outputs and event pulses of the MAC.
// Overview:
//   * Offsets and bits are defined once in
//     cores/rtlnet_eth_mac/driver/rtlnet_eth_mac.h; the localparams below
//     mirror that header and change with it.
//   * Bus: reg_wr_en / reg_rd_en strobes from rtlnet_axil_slave; reg_rd_data
//     is a registered read mux, valid the clock after reg_rd_en. Undefined
//     offsets read 0 and ignore writes.
//   * CTRL (RW, reset 0): bit 0 RX_EN, bit 1 TX_EN, bits 5:4 SPEED, bit 8
//     LINK_UP, bit 16 CNT_CLEAR (write 1 pulses a counter clear, reads 0).
//   * Counters (RO, 32-bit, wrap): RX_GOOD and RX_BAD and RX_OVERFLOW count
//     axis_clk events one for one; TX_FRAMES is the difference between the
//     coherent (Gray-crossed) clk125 frame total and a base captured at the
//     last clear, so it is exact across the crossing. On CNT_CLEAR every
//     counter restarts from the events of that same clock (0 or 1).
//   * Status outputs (registered): stat_link_up = CTRL.LINK_UP, stat_speed =
//     CTRL.SPEED, stat_rx_clk_ok = the RXC qualification; ev_rx_good,
//     ev_rx_bad (bad frame or overflow), ev_tx_frame are one-clock pulses.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk is axis_clk; resetn is synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_eth_mac_regs #(
  parameter int RX_FIFO_KB      = 8,
  parameter int TX_FIFO_KB      = 8,
  parameter int MAX_FRAME_BYTES = rtlnet_pkg::ETH_MAX_FRAME_BYTES,
  parameter int RX_IDELAY_TAP   = 12
)(
  // Register clock (axis_clk) and its synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Register strobes from rtlnet_axil_slave, clk domain, 12-bit byte address.
  input  logic        reg_wr_en,
  input  logic [11:0] reg_wr_addr,
  input  logic [31:0] reg_wr_data,
  input  logic        reg_rd_en,
  input  logic [11:0] reg_rd_addr,
  output logic [31:0] reg_rd_data,

  // Control levels to the MAC, clk domain registers.
  output logic        ctrl_rx_en,
  output logic        ctrl_tx_en,
  output logic [1:0]  ctrl_speed,

  // Status inputs, already in the clk domain.
  input  logic        st_rx_clk_ok,
  input  logic        st_idelay_rdy,
  input  logic        st_rx_in_reset,
  input  logic [1:0]  st_speed,
  input  logic [9:0]  st_rx_clk_rate,
  input  logic        st_inband_link,
  input  logic [1:0]  st_inband_speed,
  input  logic        st_inband_duplex,

  // Frame events in the clk domain (one-clock pulses) and the clk125 frame
  // total after its Gray crossing (steps by 0 or 1 per clock).
  input  logic        rx_good_event,
  input  logic        rx_bad_event,
  input  logic        rx_overflow_event,
  input  logic [31:0] tx_frame_total,

  // Status outputs of the MAC, clk domain, registered.
  output logic        stat_link_up,
  output logic [1:0]  stat_speed,
  output logic        stat_rx_clk_ok,
  output logic        ev_rx_good,
  output logic        ev_rx_bad,
  output logic        ev_tx_frame
);

  import rtlnet_pkg::*;

  // Register map: mirrors cores/rtlnet_eth_mac/driver/rtlnet_eth_mac.h.
  localparam logic [11:0] REG_ID            = 12'h000;
  localparam logic [11:0] REG_VERSION       = 12'h004;
  localparam logic [11:0] REG_CAPS          = 12'h008;
  localparam logic [11:0] REG_CTRL          = 12'h00C;
  localparam logic [11:0] REG_STATUS        = 12'h010;
  localparam logic [11:0] REG_RX_CLK_RATE   = 12'h014;
  localparam logic [11:0] REG_RX_IDELAY_TAP = 12'h018;
  localparam logic [11:0] REG_RX_GOOD       = 12'h020;
  localparam logic [11:0] REG_RX_BAD        = 12'h024;
  localparam logic [11:0] REG_RX_OVERFLOW   = 12'h028;
  localparam logic [11:0] REG_TX_FRAMES     = 12'h02C;

  localparam logic [31:0] ID_VALUE          = id4("M", "A", "C", "1");
  localparam logic [31:0] VERSION_VALUE     = 32'h10222026;
  localparam int          CTRL_RX_EN        = 0;
  localparam int          CTRL_TX_EN        = 1;
  localparam int          CTRL_SPEED_LSB    = 4;
  localparam int          CTRL_LINK_UP      = 8;
  localparam int          CTRL_CNT_CLEAR    = 16;
  localparam logic [31:0] CAPS_VALUE        = {16'(MAX_FRAME_BYTES), 8'(TX_FIFO_KB), 8'(RX_FIFO_KB)};
  localparam logic [31:0] TAP_VALUE         = 32'(RX_IDELAY_TAP);

  generate
    if (RX_FIFO_KB > 255 || TX_FIFO_KB > 255 || MAX_FRAME_BYTES > 65535) begin : g_bad_caps
      $fatal(1, "rtlnet_eth_mac_regs: RX_FIFO_KB=%0d / TX_FIFO_KB=%0d / MAX_FRAME_BYTES=%0d do not fit the CAPS fields",
             RX_FIFO_KB, TX_FIFO_KB, MAX_FRAME_BYTES);
    end
  endgenerate

  logic        ctrl_link_up;
  logic        cnt_clear;
  logic [31:0] rx_good_count;
  logic [31:0] rx_bad_count;
  logic [31:0] rx_overflow_count;
  logic [31:0] tx_frame_base;
  logic [31:0] tx_frame_total_q;
  logic [31:0] tx_frame_count;
  logic [31:0] status_word;
  logic [31:0] ctrl_word;
  logic        ctrl_write;

  assign ctrl_write     = reg_wr_en && (reg_wr_addr == REG_CTRL);
  assign tx_frame_count = tx_frame_total - tx_frame_base;
  assign ctrl_word      = {23'd0, ctrl_link_up, 2'b00, ctrl_speed, 2'b00, ctrl_tx_en, ctrl_rx_en};
  assign status_word    = {20'd0, st_inband_duplex, st_inband_speed, st_inband_link,
                           2'b00, st_speed, 1'b0, st_rx_in_reset, st_idelay_rdy, st_rx_clk_ok};

  // CTRL register and the CNT_CLEAR pulse.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      ctrl_rx_en   <= 1'b0;
      ctrl_tx_en   <= 1'b0;
      ctrl_speed   <= 2'b00;
      ctrl_link_up <= 1'b0;
      cnt_clear    <= 1'b0;
    end else begin
      cnt_clear <= 1'b0;
      if (ctrl_write) begin
        ctrl_rx_en   <= reg_wr_data[CTRL_RX_EN];
        ctrl_tx_en   <= reg_wr_data[CTRL_TX_EN];
        ctrl_speed   <= reg_wr_data[CTRL_SPEED_LSB +: 2];
        ctrl_link_up <= reg_wr_data[CTRL_LINK_UP];
        cnt_clear    <= reg_wr_data[CTRL_CNT_CLEAR];
      end
    end
  end

  // Frame counters: one count per event; a clear keeps the same clock's event.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      rx_good_count     <= '0;
      rx_bad_count      <= '0;
      rx_overflow_count <= '0;
      tx_frame_base     <= tx_frame_total;
      tx_frame_total_q  <= tx_frame_total;
    end else begin
      tx_frame_total_q <= tx_frame_total;
      if (cnt_clear) begin
        rx_good_count     <= {31'd0, rx_good_event};
        rx_bad_count      <= {31'd0, rx_bad_event};
        rx_overflow_count <= {31'd0, rx_overflow_event};
        tx_frame_base     <= tx_frame_total_q;
      end else begin
        rx_good_count     <= rx_good_count + {31'd0, rx_good_event};
        rx_bad_count      <= rx_bad_count + {31'd0, rx_bad_event};
        rx_overflow_count <= rx_overflow_count + {31'd0, rx_overflow_event};
      end
    end
  end

  // Registered status outputs and event pulses.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      stat_link_up   <= 1'b0;
      stat_speed     <= 2'b00;
      stat_rx_clk_ok <= 1'b0;
      ev_rx_good     <= 1'b0;
      ev_rx_bad      <= 1'b0;
      ev_tx_frame    <= 1'b0;
    end else begin
      stat_link_up   <= ctrl_link_up;
      stat_speed     <= ctrl_speed;
      stat_rx_clk_ok <= st_rx_clk_ok;
      ev_rx_good     <= rx_good_event;
      ev_rx_bad      <= rx_bad_event || rx_overflow_event;
      ev_tx_frame    <= (tx_frame_total != tx_frame_total_q);
    end
  end

  // Registered read mux.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:            reg_rd_data <= ID_VALUE;
        REG_VERSION:       reg_rd_data <= VERSION_VALUE;
        REG_CAPS:          reg_rd_data <= CAPS_VALUE;
        REG_CTRL:          reg_rd_data <= ctrl_word;
        REG_STATUS:        reg_rd_data <= status_word;
        REG_RX_CLK_RATE:   reg_rd_data <= {22'd0, st_rx_clk_rate};
        REG_RX_IDELAY_TAP: reg_rd_data <= TAP_VALUE;
        REG_RX_GOOD:       reg_rd_data <= rx_good_count;
        REG_RX_BAD:        reg_rd_data <= rx_bad_count;
        REG_RX_OVERFLOW:   reg_rd_data <= rx_overflow_count;
        REG_TX_FRAMES:     reg_rd_data <= tx_frame_count;
        default:           reg_rd_data <= '0;
      endcase
    end
  end

endmodule
