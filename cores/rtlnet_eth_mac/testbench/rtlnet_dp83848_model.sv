// -----------------------------------------------------------------------------
// File: rtlnet_dp83848_model.sv
// Purpose: IronKernel RTLNet behavioural DP83848 Clause 22 MII data interface.
// Overview: independent PHY TX/RX clocks, nibble injection and wire capture;
//   verifies preamble, FCS and 24-nibble minimum IFG with a serial CRC oracle.
//   Faults: 1 FCS, 2 low-nibble RX_ER, 3 high-nibble RX_ER, 4 preamble RX_ER,
//   5 dangling nibble, 6 FCS corruption on a different byte, 7 RX_ER on the
//   last FCS nibble. Also false carrier (RX_ER without RX_DV) and a carrier
//   without SFD. No MDIO model.
// Language: SystemVerilog-2012, simulation only, source-available.
// Revision: 11-14-2026
//   * 11-14-2026: add MII PHY data model.
// Clocks: PHY outputs 25 MHz at 100 Mb/s or 2.5 MHz at 10 Mb/s.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
module rtlnet_dp83848_model (
  // PHY-sourced clocks and receive outputs to the MAC.
  output logic mii_rx_clk = 0,
  output logic mii_tx_clk = 0,
  output logic [3:0] mii_rxd = 0,
  output logic mii_rx_dv = 0,
  output logic mii_rx_er = 0,
  // MAC transmit pins sampled at PHY TX_CLK rising edges.
  input logic [3:0] mii_txd,
  input logic mii_tx_en
);
  import rtlnet_tb_pkg::*;
  int speed = 100;
  time half_period;
  bytes_t captured[$];
  bytes_t wire_bytes;
  byte unsigned low_nibble;
  bit high_nibble = 0;
  bit was_active = 0;
  int idle_nibbles = 100;

  // Separate phases expose accidental use of TX_CLK for receive logic.
  initial begin
    if ($value$plusargs("SPEED=%d", speed)) begin end
    half_period = (speed == 10) ? 200ns : 20ns;
    forever #(half_period) mii_tx_clk = !mii_tx_clk;
  end
  initial begin
    #7;
    wait (half_period > 0);
    forever #(half_period) mii_rx_clk = !mii_rx_clk;
  end

  // Drive on falling edges so RX inputs have half a cycle of setup and hold.
  task automatic nibble(input logic [3:0] data_nibble, input bit err);
    @(negedge mii_rx_clk);
    mii_rxd = data_nibble;
    mii_rx_dv = 1;
    mii_rx_er = err;
  endtask

  task automatic send(input bytes_t frame, input int fault, input int pre_nibbles);
    bytes_t fcs;
    bytes_t wire_frame;
    fcs = crc32_serial_fcs(frame);
    if (fault == 1) fcs[0] ^= 8'h01;
    if (fault == 6) fcs[3] ^= 8'h80;
    wire_frame = frame;
    for (int i = 0; i < 4; i++) wire_frame.push_back(fcs[i]);
    for (int i = 0; i < pre_nibbles; i++) nibble(4'h5, fault == 4 && i == 0);
    nibble(4'hd, 0);
    for (int i = 0; i < wire_frame.size(); i++) begin
      nibble(wire_frame[i][3:0], fault == 2 && i == 7);
      nibble(wire_frame[i][7:4], (fault == 3 && i == 7) || (fault == 7 && i == wire_frame.size() - 1));
    end
    if (fault == 5) nibble(4'ha, 0);
    @(negedge mii_rx_clk);
    mii_rx_dv = 0;
    mii_rx_er = 0;
    mii_rxd = 0;
    repeat (23) @(negedge mii_rx_clk);
  endtask

  // Clause 22.2.3.4 false carrier: RX_ER with RX_DV low and RXD = 0xE; the MAC ignores it.
  task automatic false_carrier(input int count);
    for (int i = 0; i < count; i++) begin
      @(negedge mii_rx_clk);
      mii_rxd = 4'he;
      mii_rx_dv = 0;
      mii_rx_er = 1;
    end
    @(negedge mii_rx_clk);
    mii_rxd = 0;
    mii_rx_er = 0;
    repeat (23) @(negedge mii_rx_clk);
  endtask

  // Carrier (RX_DV) with preamble nibbles only and no SFD; the MAC must produce nothing.
  task automatic carrier_no_sfd(input int count);
    for (int i = 0; i < count; i++) nibble(4'h5, 0);
    @(negedge mii_rx_clk);
    mii_rx_dv = 0;
    mii_rxd = 0;
    repeat (23) @(negedge mii_rx_clk);
  endtask

  // Wire frames captured and not yet fetched (a spurious frame shows here).
  function automatic int pending();
    return captured.size();
  endfunction

  // Capture the low-first wire bytes; verify independently of the byte engines.
  always @(posedge mii_tx_clk) begin
    if (mii_tx_en === 1'b1) begin
      if (!was_active) tb_check(idle_nibbles >= 24, "MII TX IFG >= 24 nibbles");
      was_active = 1;
      idle_nibbles = 0;
      if (!high_nibble) low_nibble = {4'b0, mii_txd};
      else wire_bytes.push_back({mii_txd, low_nibble[3:0]});
      high_nibble = !high_nibble;
    end else begin
      if (was_active) begin
        bytes_t payload;
        bytes_t fcs;
        payload = {};
        tb_check(!high_nibble, "MII TX contains whole bytes");
        tb_check(wire_bytes.size() >= 72, "MII TX minimum wire length");
        for (int i = 0; i < 7 && i < wire_bytes.size(); i++)
          tb_check(wire_bytes[i] == 8'h55, "MII TX preamble");
        tb_check(wire_bytes[7] == 8'hd5, "MII TX SFD / nibble order");
        for (int i = 8; i < wire_bytes.size() - 4; i++) payload.push_back(wire_bytes[i]);
        fcs = crc32_serial_fcs(payload);
        for (int i = 0; i < 4; i++)
          tb_check(wire_bytes[wire_bytes.size()-4+i] == fcs[i], "MII TX independent CRC");
        captured.push_back(payload);
        wire_bytes = {};
      end
      was_active = 0;
      high_nibble = 0;
      idle_nibbles++;
    end
  end

  // Bounded capture wait (long enough for a maximum frame at either clock rate).
  task automatic get(output bytes_t frame, output bit ok);
    int cycles;
    cycles = 0;
    while (captured.size() == 0 && cycles < 10000) begin
      @(negedge mii_tx_clk);
      cycles++;
    end
    ok = captured.size() != 0;
    if (ok) frame = captured.pop_front();
    else frame = {};
  endtask
endmodule
