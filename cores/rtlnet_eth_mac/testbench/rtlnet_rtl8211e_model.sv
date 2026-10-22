// -----------------------------------------------------------------------------
// File: rtlnet_rtl8211e_model.sv
// Purpose: behavioural model of the Realtek RTL8211E-VB/VL Gigabit PHY at its
//   RGMII and MDIO pins, for the RTLNet MAC bench, the MDIO driver tests and
//   the board bench. Written from the RTL8211E-VB-VL-CG datasheet Rev. 1.6
//   (page numbers are the document's printed pages) and the Nexys Video
//   board facts; behaviour the datasheet does not state is marked (verify).
// Overview:
//   * Reset pin (Table 6 p.11, Fig. 10 p.29): phy_rst_n low stops RXC, holds
//     RXD/RX_CTL low, clears every register to its default and ignores MDIO.
//     After release the model waits RESET_SETTLE_NS (datasheet 30 ms; benches
//     shorten it) before it answers MDIO, then LINK_UP_DELAY_NS (stands in for
//     auto-negotiation; not a datasheet figure, verify) before link up.
//   * Link: the link partner advertises every speed up to PARTNER_SPEED
//     (run-time: set_partner_speed). With BMCR.ANE = 1 the link speed is the
//     highest speed both sides advertise (local: GBCR 9.9/9.8 for 1000, ANAR
//     4.8/4.7 for 100, ANAR 4.6/4.5 for 10), full duplex; with ANE = 0 it is the
//     forced BMCR speed {0.6, 0.13} and duplex 0.8. A BMCR reset, restart-AN,
//     a change of the ANE/speed/duplex/power-down bits, a partner speed change
//     or set_cable(0/1) drops the link and brings it up again after the delay
//     (SPEED_CHANGE_DELAY_NS for a partner change, LINK_UP_DELAY_NS else).
//     Power-down (0.11) keeps the link down.
//   * RGMII RX (PHY -> MAC, Table 3 p.9): RXC runs at 125 / 25 / 2.5 MHz while
//     linked, stopped low otherwise. 1000: low nibble and RX_DV on the RXC
//     rising edge, high nibble and RX_DV xor RX_ER on the falling edge. 10/100:
//     one nibble per RXC cycle on the rising edge, low nibble first; RX_CTL on
//     the falling edge is RX_DV xor RX_ER. RXD/RX_CTL change on the internal
//     clock edges; the RXC pin is that clock delayed by DELAY_PS (2 ns) when
//     the RX delay is on (the delay sits on the clock, Fig. 33 p.64), plus
//     SKEW_PS. Frames: 7 x 0x55, 0xD5, the bytes, then IFG_BYTES of idle.
//   * In-band status (INBAND_STATUS = 1; undocumented in the datasheet,
//     observed on the Nexys Video): idle RXD = {duplex, speed[1:0], link} on
//     both edges with RX_CTL low; 0000 with INBAND_STATUS = 0 or no link.
//   * RGMII delay over MDIO (section 7.10.5 p.21; Tables 43/44 p.42-43):
//     PAGSEL (reg 31, bits 2:0) and EPAGSR (reg 30, bits 7:0) are read/write;
//     with PAGSEL = 7 and EPAGSR = 0xA4, register 28 is the extension
//     register (all 16 bits read/write, reset 0x8575 as read on the board;
//     bit 13 = 1 hands the delays to bit 12 (TX) and bit 11 (RX), else the
//     RXDLY/TXDLY straps decide). The bit meanings are not in the datasheet
//     (verify; they follow the Linux driver's defines).
//   * RGMII TX (MAC -> PHY): TXD/TX_CTL sampled on TXC (delayed by DELAY_PS
//     when the TX delay is on, Fig. 32 p.63). 1000: both edges; 10/100: one
//     nibble per rising edge, TX_CTL on the falling edge = TX_EN xor TX_ER.
//     Setup and hold at every sampling edge are checked against RX_SETUP_PS /
//     RX_HOLD_PS (Table 65 p.65: 1.0 ns at the receiver); each violation
//     increments tx_viol_count. The capture records the whole wire frame and
//     checks the preamble (7 x 0x55 + 0xD5), the FCS (independent serial
//     oracle), TX_ER and a dangling nibble; it also records the gap before
//     the frame, the smallest setup and hold of the frame and the TXC period.
//   * Loopback (BMCR 0.14): every captured frame with a good preamble is also
//     sent back on RX, as received (FCS included).
//   * MDIO slave (Clause 22, section 7.10.4 p.19-20): 32-bit preamble, ST 01,
//     OP 10 read / 01 write, PHYAD (PHYAD parameter, address 0 always
//     answers), REGAD, TA, 16 data bits MSB first; MDIO is sampled on the MDC
//     rising edge and read data is driven MDIO_OUT_DELAY_NS after it.
//     Registers: BMCR 0 (RW, 0x1140; bit 15 reads 1 for SOFT_RESET_NS after a
//     reset write, then BMCR returns to 0x1140; bit 9 self-clears), BMSR 1
//     (0x7949, bits 5 and 2 set while linked; bit 2 is real-time, not
//     latching, verify), PHYID1 2 (0x001C), PHYID2 3 (0xC915), ANAR 4 (RW,
//     0x05E1), ANLPAR 5 (model partner: 0x45E1 / 0x41E1 / 0x4061 by partner
//     speed while linked, verify), GBCR 9 (RW, 0x0200), GBSR 10 (0x3800
//     while linked at 1000, verify), PHYSR 17 (15:14 speed, 13 duplex, 11
//     resolved, 10 link, 1 local receiver ok), 28/30/31 above. Other
//     registers read 0 and ignore writes. A software reset restores BMCR only
//     (verify).
//   * Fault injection on injected frames (fault mask): FAULT_RX_ER sets RX_ER
//     on byte RX_ER_BYTE after the SFD; FAULT_DANGLING (10/100) sends one
//     extra nibble 0x3 after the last byte; FAULT_SHORT_PREAMBLE sends 14
//     instead of 15 preamble nibbles at 10/100 (a receiver must align on the
//     SFD) and 3 preamble octets at 1000. force_rxc_speed() runs RXC and the
//     RX framing at another speed than PHYSR reports (mismatch test).
//   * Not modelled: MII/GMII pins, the analog side, auto-negotiation pages,
//     LEDs, INTB/PMEB, EEE and the low-power-idle code, interrupts, other
//     registers, MDIO timing checks.
// User tasks (call hierarchically, e.g. u_phy.inject(frame)):
//   inject(frame, faults)         frame without FCS; the model appends the FCS
//   inject_raw(bytes, faults)     bytes after the SFD as sent (FCS included)
//   wait_rx_idle(timeout_ns, ok)  until every injected frame has been sent
//   get_tx_frame(frame, fcs_ok, pre_ok, err, timeout_ns, got)
//                                 next captured TX frame, FCS stripped
//   set_partner_speed(code)       00 10M, 01 100M, 10 1000M (link renegotiates)
//   set_cable(connected)          0 = link down, 1 = link back after the delay
//   force_rxc_speed(code)         11 = RXC follows the link (default)
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: rxc (output, generated), txc and mdc (inputs from the MAC / MDIO
//   master).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_rtl8211e_model #(
  parameter string      NAME                  = "rtl8211e",
  parameter int         PHYAD                 = 1,              // PHYAD strap (Nexys Video: 1)
  parameter bit         RXDLY_STRAP           = 1'b0,           // RXDLY strap (Nexys Video: no delay)
  parameter bit         TXDLY_STRAP           = 1'b0,           // TXDLY strap (Nexys Video: no delay)
  parameter int         DELAY_PS              = 2000,           // internal RGMII clock delay (Table 13 p.16)
  parameter int         SKEW_PS               = 0,              // extra RXC / TXC-sample skew
  parameter logic [1:0] PARTNER_SPEED         = 2'b10,          // link partner's highest speed
  parameter bit         INBAND_STATUS         = 1'b1,           // drive the in-band status on idle RXD
  parameter int         RESET_SETTLE_NS       = 30_000_000,     // reset release to MDIO access (30 ms)
  parameter int         LINK_UP_DELAY_NS      = 2_000_000_000,  // MDIO access / relink to link up
  parameter int         SPEED_CHANGE_DELAY_NS = 2_000_000_000,  // link down time on a partner speed change
  parameter int         SOFT_RESET_NS         = 20_000,         // BMCR.15 reads 1 this long (verify)
  parameter int         RX_SETUP_PS           = 1000,           // TX capture setup (Table 65 p.65)
  parameter int         RX_HOLD_PS            = 1000,           // TX capture hold
  parameter int         IFG_BYTES             = 12,             // idle byte times after each injected frame
  parameter int         RX_ER_BYTE            = 40,             // byte after the SFD carrying FAULT_RX_ER
  parameter int         MDIO_OUT_DELAY_NS     = 10,             // MDC rising edge to read data
  parameter bit         VERBOSE               = 1'b0
)(
  // Hardware reset (PHYRSTB), active low.
  input  logic       phy_rst_n,

  // Management interface: MDC from the station, MDIO open drain (the bench
  // provides the board's pull-up).
  input  logic       mdc,
  inout  wire        mdio,

  // RGMII receive, PHY to MAC.
  output logic       rxc,
  output logic [3:0] rxd,
  output logic       rx_ctl,

  // RGMII transmit, MAC to PHY.
  input  logic       txc,
  input  logic [3:0] txd,
  input  logic       tx_ctl,

  // Model-only status (not device pins).
  output logic       link_up,
  output logic [1:0] link_speed,
  output logic       rxdly_on,
  output logic       txdly_on,
  output int         tx_viol_count
);

  import rtlnet_tb_pkg::*;

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  localparam int          FAULT_RX_ER          = 1;
  localparam int          FAULT_DANGLING       = 2;
  localparam int          FAULT_SHORT_PREAMBLE = 4;
  localparam logic [15:0] BMCR_DEFAULT  = 16'h1140;   // Table 23 p.31-32
  localparam logic [15:0] BMSR_BASE     = 16'h7949;   // Table 24 p.32-34
  localparam logic [15:0] BMSR_LINKED   = 16'h0024;   // AN complete, link status
  localparam logic [15:0] PHYID1        = 16'h001C;   // Table 25 p.34
  localparam logic [15:0] PHYID2        = 16'hC915;   // Table 26 p.34
  localparam logic [15:0] ANAR_DEFAULT  = 16'h05E1;   // Table 27 p.34-35
  localparam logic [15:0] ANLPAR_1000   = 16'h45E1;   // model partner (verify)
  localparam logic [15:0] ANLPAR_100    = 16'h41E1;
  localparam logic [15:0] ANLPAR_10     = 16'h4061;
  localparam logic [15:0] GBCR_DEFAULT  = 16'h0200;   // Table 32 p.37
  localparam logic [15:0] GBSR_LINKED   = 16'h3800;   // model choice (verify)
  localparam logic [15:0] EXT28_DEFAULT = 16'h8575;   // read on the Nexys Video board
  localparam logic [7:0]  EXT_PAGE_A4   = 8'hA4;
  localparam logic [2:0]  PAGSEL_EXT    = 3'd7;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic [15:0] bmcr      = BMCR_DEFAULT;
  logic [15:0] anar      = ANAR_DEFAULT;
  logic [15:0] gbcr      = GBCR_DEFAULT;
  logic [2:0]  pagsel    = 3'd0;
  logic [7:0]  epagsr    = 8'd0;
  logic [15:0] ext28     = EXT28_DEFAULT;
  bit          mdio_ready = 1'b0;          // reset settled: MDIO answers
  bit          soft_reset_busy = 1'b0;
  bit          link_up_i  = 1'b0;
  logic [1:0]  spd_i      = 2'b10;         // speed of the current link
  bit          duplex_i   = 1'b1;
  logic [1:0]  partner_spd = PARTNER_SPEED;
  bit          cable      = 1'b1;
  logic [1:0]  rxc_force  = 2'b11;
  int          relink_req = 0;             // incremented by every relink request
  int          relink_delay_ns = LINK_UP_DELAY_NS;
  logic        mdio_oe    = 1'b0;
  logic        mdio_o     = 1'b0;
  logic        rxc_ref    = 1'b0;          // internal RX clock (undelayed)
  logic        rxc_nodly  = 1'b0;
  logic        rxc_dly    = 1'b0;
  logic        txc_nodly  = 1'b0;
  logic        txc_dly    = 1'b0;
  logic        txc_s;                      // TX sampling clock
  logic [1:0]  rxc_spd;
  bytes_t      rx_frame_q[$];              // frames to send (bytes after the SFD)
  int          rx_fault_q[$];
  bit          rx_busy    = 1'b0;

  // TX capture state
  bytes_t      cap_bytes;
  bit          cap_active  = 1'b0;
  bit          cap_err     = 1'b0;
  bit          cap_en      = 1'b0;
  bit          cap_nib_hi  = 1'b0;
  logic [3:0]  cap_lo      = 4'h0;
  realtime     t_txd_chg   = 0;
  realtime     t_ctl_chg   = 0;
  realtime     t_edge_txd  = 0;           // sampling edge of a pending TXD hold check
  realtime     t_edge_ctl  = 0;           // sampling edge of a pending TX_CTL hold check
  realtime     t_last_end  = -1;
  realtime     t_prev_rise = -1;
  bit          hold_txd_pending = 1'b0;
  bit          hold_ctl_pending = 1'b0;
  realtime     cap_setup_min = 1.0e9;
  realtime     cap_hold_min  = 1.0e9;
  realtime     cap_gap       = -1;
  bytes_t      cap_frame_q[$];             // wire bytes from the first preamble octet
  bit          cap_err_q[$];
  realtime     cap_gap_q[$];
  realtime     cap_setup_q[$];
  realtime     cap_hold_q[$];

  // Results of the last get_tx_frame (read hierarchically by a bench).
  realtime     last_gap_ns       = -1;     // TX_EN low time before the frame
  realtime     last_setup_min_ns = 0;      // smallest setup in the frame
  realtime     last_hold_min_ns  = 0;      // smallest hold in the frame
  realtime     tx_period_ns      = 0;      // last measured TXC period
  int          rx_frames_sent    = 0;
  int          tx_frames_seen    = 0;

  // ---------------------------------------------------------------------------
  // Pins and status
  // ---------------------------------------------------------------------------
  assign mdio          = mdio_oe ? mdio_o : 1'bz;
  assign rxdly_on      = ext28[13] ? ext28[11] : RXDLY_STRAP;
  assign txdly_on      = ext28[13] ? ext28[12] : TXDLY_STRAP;
  assign rxc           = rxdly_on ? rxc_dly : rxc_nodly;
  assign txc_s         = txdly_on ? txc_dly : txc_nodly;
  assign rxc_spd       = (rxc_force == 2'b11) ? spd_i : rxc_force;
  assign link_up       = link_up_i;
  assign link_speed    = spd_i;

  initial tx_viol_count = 0;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function automatic realtime half_period(input logic [1:0] s);
    case (s)
      2'b00:   return 200.0;               // 10 Mb/s: 400 ns RXC
      2'b01:   return 20.0;                // 100 Mb/s: 40 ns
      default: return 4.0;                 // 1000 Mb/s: 8 ns
    endcase
  endfunction

  function automatic bit pin_high(input logic v);
    return (v === 1'b1);
  endfunction

  // Highest speed both sides advertise (auto-negotiation; the partner
  // advertises every speed up to partner_spd) or the forced speed; ok = 0
  // when there is no common speed.
  task automatic resolve(output logic [1:0] spd, output bit dup, output bit ok);
    if (bmcr[12]) begin
      ok  = 1'b1;
      dup = 1'b1;
      if (partner_spd >= 2'b10 && (gbcr[9] || gbcr[8]))      spd = 2'b10;
      else if (partner_spd >= 2'b01 && (anar[8] || anar[7])) spd = 2'b01;
      else if (anar[6] || anar[5])                           spd = 2'b00;
      else begin
        spd = 2'b00;
        ok  = 1'b0;
      end
    end else begin
      spd = {bmcr[6], bmcr[13]};
      if (spd == 2'b11) spd = 2'b10;
      dup = bmcr[8];
      ok  = 1'b1;
    end
  endtask

  task automatic note(input string msg);
    if (VERBOSE) $display("[%0t] %s: %s", $time, NAME, msg);
  endtask

  task automatic request_relink(input int delay_ns);
    relink_delay_ns = delay_ns;
    relink_req++;
  endtask

  // Wait delay_ns unless reset asserts or a new relink request arrives.
  task automatic wait_abortable(input int delay_ns, input int req_seen, output bit aborted);
    longint left;
    longint step;
    left = delay_ns;
    aborted = 1'b0;
    while (left > 0 && !aborted) begin
      step = (left > 1000) ? 1000 : left;
      #(step * 1ns);
      left -= step;
      if (!pin_high(phy_rst_n) || relink_req != req_seen) aborted = 1'b1;
    end
  endtask

  task automatic regs_to_default();
    bmcr            = BMCR_DEFAULT;
    anar            = ANAR_DEFAULT;
    gbcr            = GBCR_DEFAULT;
    pagsel          = 3'd0;
    epagsr          = 8'd0;
    ext28           = EXT28_DEFAULT;
    soft_reset_busy = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Reset and link state (the only writer of link_up_i, spd_i, mdio_ready).
  // ---------------------------------------------------------------------------
  initial begin : p_link
    bit         aborted;
    int         seen;
    logic [1:0] spd;
    bit         dup;
    bit         ok;
    forever begin
      link_up_i = 1'b0;
      if (!pin_high(phy_rst_n) || !mdio_ready) begin
        mdio_ready = 1'b0;
        regs_to_default();
        wait (pin_high(phy_rst_n));
        seen = relink_req;
        wait_abortable(RESET_SETTLE_NS, seen, aborted);
        if (!pin_high(phy_rst_n)) continue;
        mdio_ready = 1'b1;
        relink_delay_ns = LINK_UP_DELAY_NS;
        note("reset settled, MDIO ready");
      end
      seen = relink_req;
      resolve(spd, dup, ok);
      if (!cable || bmcr[11] || !ok) begin
        wait (!pin_high(phy_rst_n) || relink_req != seen);
        continue;
      end
      wait_abortable(relink_delay_ns, seen, aborted);
      if (aborted) continue;
      resolve(spd, dup, ok);
      spd_i     = spd;
      duplex_i  = dup;
      link_up_i = 1'b1;
      note($sformatf("link up, speed code %0d", spd));
      wait (!pin_high(phy_rst_n) || relink_req != seen);
      note("link down");
    end
  end

  // ---------------------------------------------------------------------------
  // RX clock: internal reference while linked, delayed copies for the pin.
  // ---------------------------------------------------------------------------
  initial begin : p_rxc
    forever begin
      if (link_up_i && pin_high(phy_rst_n)) begin
        #(half_period(rxc_spd));
        rxc_ref = ~rxc_ref;
      end else begin
        rxc_ref = 1'b0;
        wait (link_up_i && pin_high(phy_rst_n));
      end
    end
  end

  always @(rxc_ref) begin
    rxc_nodly <= #(SKEW_PS * 1ps) rxc_ref;
    rxc_dly   <= #((DELAY_PS + SKEW_PS) * 1ps) rxc_ref;
  end

  always @(txc) begin
    txc_nodly <= #(SKEW_PS * 1ps) txc;
    txc_dly   <= #((DELAY_PS + SKEW_PS) * 1ps) txc;
  end

  // ---------------------------------------------------------------------------
  // RX driver: idle (in-band status) and injected frames.
  // ---------------------------------------------------------------------------
  function automatic logic [3:0] idle_nibble();
    if (INBAND_STATUS && link_up_i) return {duplex_i, spd_i, 1'b1};
    return 4'h0;
  endfunction

  initial begin : p_rx
    bytes_t f;
    int     faults;
    int     idle_left;
    rxd       = 4'h0;
    rx_ctl    = 1'b0;
    idle_left = 0;
    forever begin
      if (!(link_up_i && pin_high(phy_rst_n))) begin
        rxd     = 4'h0;
        rx_ctl  = 1'b0;
        rx_busy = 1'b0;
        wait (link_up_i && pin_high(phy_rst_n));
        idle_left = IFG_BYTES * 2;
      end else begin
        @(posedge rxc_ref or negedge link_up_i);
        if (!link_up_i) begin
          rxd    = 4'h0;
          rx_ctl = 1'b0;
        end else if (rx_frame_q.size() != 0 && idle_left == 0) begin
          rx_busy = 1'b1;
          f       = rx_frame_q.pop_front();
          faults  = rx_fault_q.pop_front();
          send_frame_from_edge(f, faults);
          rx_frames_sent++;
          rxd       = idle_nibble();
          rx_ctl    = 1'b0;
          idle_left = (rxc_spd[1] ? 1 : 2) * IFG_BYTES - 1;
          rx_busy   = (rx_frame_q.size() != 0);
        end else begin
          rxd    = idle_nibble();
          rx_ctl = 1'b0;
          if (idle_left > 0) idle_left--;
          rx_busy = (rx_frame_q.size() != 0);
        end
      end
    end
  end

  // Drive one frame starting on the internal RXC rising edge just taken:
  // preamble, SFD, bytes (and the fault variants), then wait one more rising
  // edge, where the caller drives idle.
  task automatic send_frame_from_edge(input bytes_t frame, input int faults);
    bytes_t     wbytes;
    int         n_pre;
    logic [3:0] nibs[$];
    bit         er_nib[$];
    logic [7:0] b;
    if (rxc_spd[1]) begin
      n_pre = (faults & FAULT_SHORT_PREAMBLE) ? 3 : 7;
      for (int i = 0; i < n_pre; i++) wbytes.push_back(8'h55);
      wbytes.push_back(8'hD5);
      for (int i = 0; i < $size(frame); i++) wbytes.push_back(frame[i]);
      for (int i = 0; i < $size(wbytes); i++) begin
        if (i != 0) @(posedge rxc_ref);
        if (!link_up_i) return;
        rxd    = wbytes[i][3:0];
        rx_ctl = 1'b1;
        @(negedge rxc_ref);
        rxd    = wbytes[i][7:4];
        rx_ctl = !((faults & FAULT_RX_ER) && (i == n_pre + 1 + RX_ER_BYTE));
      end
    end else begin
      n_pre = (faults & FAULT_SHORT_PREAMBLE) ? 14 : 15;
      for (int i = 0; i < n_pre; i++) begin
        nibs.push_back(4'h5);
        er_nib.push_back(1'b0);
      end
      nibs.push_back(4'hD);
      er_nib.push_back(1'b0);
      for (int i = 0; i < $size(frame); i++) begin
        b = frame[i];
        nibs.push_back(b[3:0]);
        er_nib.push_back((faults & FAULT_RX_ER) && (i == RX_ER_BYTE));
        nibs.push_back(b[7:4]);
        er_nib.push_back((faults & FAULT_RX_ER) && (i == RX_ER_BYTE));
      end
      if (faults & FAULT_DANGLING) begin
        nibs.push_back(4'h3);
        er_nib.push_back(1'b0);
      end
      for (int i = 0; i < $size(nibs); i++) begin
        if (i != 0) @(posedge rxc_ref);
        if (!link_up_i) return;
        rxd    = nibs[i];
        rx_ctl = 1'b1;
        @(negedge rxc_ref);
        rx_ctl = !er_nib[i];
      end
    end
    @(posedge rxc_ref);
  endtask

  // ---------------------------------------------------------------------------
  // TX capture and timing checks.
  // ---------------------------------------------------------------------------
  always @(txd)    t_txd_chg = $realtime;
  always @(tx_ctl) t_ctl_chg = $realtime;

  // Hold check at each TXD / TX_CTL change after a sampling edge.
  always @(txd) begin
    if (hold_txd_pending) begin
      hold_txd_pending = 1'b0;
      check_hold($realtime - t_edge_txd, "TXD");
    end
  end

  always @(tx_ctl) begin
    if (hold_ctl_pending) begin
      hold_ctl_pending = 1'b0;
      check_hold($realtime - t_edge_ctl, "TX_CTL");
    end
  end

  task automatic check_hold(input realtime h, input string what);
    if (h < cap_hold_min) cap_hold_min = h;
    if (h * 1000.0 < RX_HOLD_PS) begin
      tx_viol_count++;
      $display("[%0t] %s: TX hold violation on %s, %0.3f ns", $time, NAME, what, h);
    end
  endtask

  task automatic check_setup(input bit chk_txd, input bit chk_ctl);
    realtime s;
    s = 1.0e9;
    if (chk_txd && ($realtime - t_txd_chg) < s) s = $realtime - t_txd_chg;
    if (chk_ctl && ($realtime - t_ctl_chg) < s) s = $realtime - t_ctl_chg;
    if (s < cap_setup_min) cap_setup_min = s;
    if (s * 1000.0 < RX_SETUP_PS) begin
      tx_viol_count++;
      $display("[%0t] %s: TX setup violation, %0.3f ns", $time, NAME, s);
    end
    if (chk_txd) begin
      t_edge_txd       = $realtime;
      hold_txd_pending = 1'b1;
    end
    if (chk_ctl) begin
      t_edge_ctl       = $realtime;
      hold_ctl_pending = 1'b1;
    end
  endtask

  task automatic cap_start();
    cap_active    = 1'b1;
    cap_err       = 1'b0;
    cap_nib_hi    = 1'b0;
    cap_bytes     = {};
    cap_gap       = (t_last_end < 0.0) ? -1.0 : ($realtime - t_last_end);
    cap_setup_min = 1.0e9;
    cap_hold_min  = 1.0e9;
  endtask

  task automatic cap_end();
    bit     pre_ok;
    bytes_t payload;
    cap_active = 1'b0;
    t_last_end = $realtime;
    if (cap_nib_hi) cap_err = 1'b1;
    cap_frame_q.push_back(cap_bytes);
    cap_err_q.push_back(cap_err);
    cap_gap_q.push_back(cap_gap);
    cap_setup_q.push_back(cap_setup_min);
    cap_hold_q.push_back(cap_hold_min);
    tx_frames_seen++;
    note($sformatf("TX frame captured, %0d wire bytes", cap_bytes.size()));
    if (bmcr[14]) begin
      pre_ok = (cap_bytes.size() > 8);
      for (int i = 0; i < 7 && pre_ok; i++) if (cap_bytes[i] != 8'h55) pre_ok = 1'b0;
      if (pre_ok && cap_bytes[7] != 8'hD5) pre_ok = 1'b0;
      if (pre_ok) begin
        for (int i = 8; i < $size(cap_bytes); i++) payload.push_back(cap_bytes[i]);
        rx_frame_q.push_back(payload);
        rx_fault_q.push_back(0);
      end
    end
  endtask

  always @(posedge txc_s) begin
    if (t_prev_rise >= 0) tx_period_ns = $realtime - t_prev_rise;
    t_prev_rise = $realtime;
    if (pin_high(phy_rst_n) && link_up_i) begin
      check_setup(1'b1, 1'b1);
      cap_en = (tx_ctl === 1'b1);
      if (spd_i[1]) begin
        cap_lo = txd;
      end else if (cap_en) begin
        if (!cap_active) cap_start();
        if (!cap_nib_hi) begin
          cap_lo     = txd;
          cap_nib_hi = 1'b1;
        end else begin
          cap_bytes.push_back({txd, cap_lo});
          cap_nib_hi = 1'b0;
        end
      end else if (cap_active) begin
        cap_end();
      end
    end
  end

  always @(negedge txc_s) begin
    if (pin_high(phy_rst_n) && link_up_i) begin
      check_setup(spd_i[1], 1'b1);
      if (cap_en && ((tx_ctl === 1'b1) != cap_en)) cap_err = 1'b1;   // TX_EN xor TX_ER = 0: TX_ER
      if (spd_i[1]) begin
        if (cap_en) begin
          if (!cap_active) cap_start();
          cap_bytes.push_back({txd, cap_lo});
        end else if (cap_active) begin
          cap_end();
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // MDIO slave (Clause 22).
  // ---------------------------------------------------------------------------
  function automatic logic [15:0] read_reg(input logic [4:0] regad);
    logic [15:0] v;
    case (regad)
      5'd0:  v = bmcr | (soft_reset_busy ? 16'h8000 : 16'h0000);
      5'd1:  v = BMSR_BASE | (link_up_i ? BMSR_LINKED : 16'h0000);
      5'd2:  v = PHYID1;
      5'd3:  v = PHYID2;
      5'd4:  v = anar;
      5'd5:  v = !link_up_i || !bmcr[12] ? 16'h0000 :
                 (partner_spd == 2'b00) ? ANLPAR_10 : (partner_spd == 2'b01) ? ANLPAR_100 : ANLPAR_1000;
      5'd9:  v = gbcr;
      5'd10: v = (link_up_i && spd_i == 2'b10) ? GBSR_LINKED : 16'h0000;
      5'd17: v = {spd_i, duplex_i, 1'b0, link_up_i, link_up_i, 8'h00, link_up_i, 1'b0};
      5'd28: v = (pagsel == PAGSEL_EXT && epagsr == EXT_PAGE_A4) ? ext28 : 16'h0000;
      5'd30: v = {8'h00, epagsr};
      5'd31: v = {13'd0, pagsel};
      default: v = 16'h0000;
    endcase
    return v;
  endfunction

  task automatic write_reg(input logic [4:0] regad, input logic [15:0] v);
    logic [15:0] old;
    case (regad)
      5'd0: begin
        old = bmcr;
        if (v[15]) begin
          bmcr = BMCR_DEFAULT;
          soft_reset_busy = 1'b1;
          fork
            begin
              #(SOFT_RESET_NS * 1ns);
              soft_reset_busy = 1'b0;
            end
          join_none
          request_relink(LINK_UP_DELAY_NS);
        end else begin
          bmcr = {v[15:10], 1'b0, v[8:0]};
          if (v[9] || ((old ^ bmcr) & 16'h3940) != 16'h0000) request_relink(LINK_UP_DELAY_NS);
        end
        note($sformatf("BMCR <= 0x%04x", v));
      end
      5'd4:  anar = {v[15:5], 5'b00001};
      5'd9:  gbcr = v;
      5'd28: if (pagsel == PAGSEL_EXT && epagsr == EXT_PAGE_A4) ext28 = v;
      5'd30: epagsr = v[7:0];
      5'd31: pagsel = v[2:0];
      default: ;
    endcase
  endtask

  function automatic bit mdio_bit();
    return (mdio !== 1'b0);                // released line reads 1 (pull-up)
  endfunction

  initial begin : p_mdio
    int          ones;
    logic [13:0] hdr;
    logic [15:0] data;
    bit          addressed;
    forever begin
      ones = 0;
      while (ones < 32) begin
        @(posedge mdc);
        if (mdio_ready && pin_high(phy_rst_n) && mdio_bit()) ones++;
        else                                                ones = 0;
      end
      // Remaining preamble ones, then ST (01).
      do @(posedge mdc); while (mdio_bit());
      hdr[13] = 1'b0;
      for (int i = 12; i >= 0; i--) begin
        @(posedge mdc);
        hdr[i] = mdio_bit();
      end
      addressed = (hdr[12] == 1'b1) && ((hdr[9:5] == 5'(PHYAD)) || (hdr[9:5] == 5'd0) || (PHYAD == 0)) &&
                  mdio_ready && pin_high(phy_rst_n);
      if (hdr[11:10] == 2'b10) begin
        // Read: TA bit 1 released by both, TA bit 2 driven 0 by the PHY.
        data = read_reg(hdr[4:0]);
        @(posedge mdc);
        if (addressed) begin
          #(MDIO_OUT_DELAY_NS * 1ns);
          mdio_o  = 1'b0;
          mdio_oe = 1'b1;
        end
        for (int i = 15; i >= 0; i--) begin
          @(posedge mdc);
          if (addressed) begin
            #(MDIO_OUT_DELAY_NS * 1ns);
            mdio_o = data[i];
          end
        end
        @(posedge mdc);
        #(MDIO_OUT_DELAY_NS * 1ns);
        mdio_oe = 1'b0;
        note($sformatf("MDIO read reg %0d = 0x%04x%s", hdr[4:0], data, addressed ? "" : " (not addressed)"));
      end else if (hdr[11:10] == 2'b01) begin
        @(posedge mdc);
        @(posedge mdc);
        for (int i = 15; i >= 0; i--) begin
          @(posedge mdc);
          data[i] = mdio_bit();
        end
        if (addressed) write_reg(hdr[4:0], data);
        note($sformatf("MDIO write reg %0d = 0x%04x%s", hdr[4:0], data, addressed ? "" : " (not addressed)"));
      end
    end
  end

  // ---------------------------------------------------------------------------
  // User tasks
  // ---------------------------------------------------------------------------
  // Queue a frame (no FCS): the model appends the FCS.
  task automatic inject(input bytes_t frame, input int faults = 0);
    bytes_t f;
    bytes_t fcs;
    f   = frame;
    fcs = crc32_serial_fcs(frame);
    for (int i = 0; i < 4; i++) f.push_back(fcs[i]);
    rx_frame_q.push_back(f);
    rx_fault_q.push_back(faults);
    rx_busy = 1'b1;
  endtask

  // Queue the bytes after the SFD exactly as given (FCS included or not).
  task automatic inject_raw(input bytes_t bytes, input int faults = 0);
    rx_frame_q.push_back(bytes);
    rx_fault_q.push_back(faults);
    rx_busy = 1'b1;
  endtask

  // Wait until every queued frame has left the RX pins.
  task automatic wait_rx_idle(input int timeout_ns, output bit ok);
    int t;
    t = 0;
    while ((rx_busy || rx_frame_q.size() != 0) && t < timeout_ns) begin
      #100ns;
      t += 100;
    end
    ok = !(rx_busy || rx_frame_q.size() != 0);
  endtask

  // Next captured TX frame: bytes after the SFD without the FCS, the FCS
  // verdict of the serial oracle, the preamble verdict and TX_ER / dangling
  // nibble. last_gap_ns / last_setup_min_ns / last_hold_min_ns describe it.
  task automatic get_tx_frame(output bytes_t frame, output bit fcs_ok, output bit pre_ok, output bit err,
                              input int timeout_ns, output bit got);
    bytes_t w;
    bytes_t fcs;
    int     t;
    int     n;
    t = 0;
    frame  = {};
    fcs_ok = 1'b0;
    pre_ok = 1'b0;
    err    = 1'b0;
    while (cap_frame_q.size() == 0 && t < timeout_ns) begin
      #100ns;
      t += 100;
    end
    got = (cap_frame_q.size() != 0);
    if (!got) return;
    w                 = cap_frame_q.pop_front();
    err               = cap_err_q.pop_front();
    last_gap_ns       = cap_gap_q.pop_front();
    last_setup_min_ns = cap_setup_q.pop_front();
    last_hold_min_ns  = cap_hold_q.pop_front();
    pre_ok = (w.size() >= 12);
    for (int i = 0; i < 7 && pre_ok; i++) if (w[i] != 8'h55) pre_ok = 1'b0;
    if (pre_ok && w[7] != 8'hD5) pre_ok = 1'b0;
    if (w.size() >= 12) begin
      n = w.size() - 12;
      for (int i = 0; i < n; i++) frame.push_back(w[8 + i]);
      fcs    = crc32_serial_fcs(frame);
      fcs_ok = 1'b1;
      for (int i = 0; i < 4; i++) if (w[8 + n + i] != fcs[i]) fcs_ok = 1'b0;
    end
  endtask

  // Link partner speed change: the link renegotiates.
  task automatic set_partner_speed(input logic [1:0] code);
    partner_spd = code;
    request_relink(SPEED_CHANGE_DELAY_NS);
  endtask

  // Cable unplugged (0) or plugged in (1).
  task automatic set_cable(input bit connected);
    cable = connected;
    request_relink(LINK_UP_DELAY_NS);
  endtask

  // RXC and RX framing at another speed than PHYSR reports (11 = follow).
  task automatic force_rxc_speed(input logic [1:0] code);
    rxc_force = code;
  endtask

endmodule
