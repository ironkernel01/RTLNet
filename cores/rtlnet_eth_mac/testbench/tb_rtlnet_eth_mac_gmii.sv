// -----------------------------------------------------------------------------
// File: tb_rtlnet_eth_mac_gmii.sv
// Purpose: GMII-level unit bench of the RTLNet MAC byte engines with the same
//   guard / packet FIFO chain the MAC uses: rtlnet_gmii_rx -> frame guard
//   (60) -> RX packet FIFO (drop when full) -> stream sink, and stream source
//   -> frame guard (14) -> TX packet FIFO -> rtlnet_gmii_tx -> GMII monitor.
// Overview:
//   * Three byte clock-enable patterns, each run after a fresh reset: ce
//     always 1 (1000 Mb/s), one cycle in ten (100 Mb/s byte rate) and an
//     irregular random pattern, on RX and TX with different phases. While
//     ce is low the RX driver puts random garbage on rxd/rx_dv/rx_er, which
//     the receiver must ignore.
//   * RX cases: good frames of random length 60..1518 (and 60, 61, 64, 1518)
//     with preamble lengths 0..7, back to back at the minimum gap; frames
//     with a bad FCS, RX_ER mid-frame, RX_ER on the SFD alone, a runt (20
//     bytes, good FCS), an oversize frame (1600 bytes, good FCS) and a tiny
//     frame (SFD + 3 bytes) are dropped and each counted once on the FIFO's
//     bad_frame; a preamble with no SFD produces nothing; RX_ER with RX_DV low
//     is ignored. Good frames arrive byte-exact and in order (sink with
//     random stalls). The receiver's m_valid is never high on two
//     consecutive clocks. Drop-when-full: with the sink stalled, 6 frames
//     give 4 stored and 2 overflow events.
//   * TX cases: frames of random length 14..1518 (and 14, 59, 60, 61, 1518):
//     the wire carries 7 x 0x55 + 0xD5, the frame zero-padded to 60, and the
//     FCS of the independent serial oracle (rtlnet_tb_pkg::crc32_serial_fcs);
//     TX_EN low between frames for at least 12 byte times, exactly 12 when
//     frames are queued; gmii_tx_er stays 0; the TX FIFO pops exactly
//     ceil(len / 8) words per frame; frame_sent pulses once per frame. With
//     enable low, frames are consumed (same pop count) and not sent, and the
//     source never blocks.
//   * One verdict line through rtlnet_tb_pkg::tb_verdict; watchdog.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: rx_clk 125 MHz, clk125 125 MHz (other phase), axis_clk 62.5 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_eth_mac_gmii;

  import rtlnet_tb_pkg::*;

  localparam int    RX_FRAMES      = 24;
  localparam int    TX_FRAMES      = 24;
  localparam int    MIN_IFG        = 12;
  localparam int    TIMEOUT_CYCLES = 400000;
  localparam time   WATCHDOG       = 60ms;

  // ---------------------------------------------------------------------------
  // Clocks and resets
  // ---------------------------------------------------------------------------
  logic rx_clk   = 1'b0;
  logic clk125   = 1'b0;
  logic axis_clk = 1'b0;
  logic arstn    = 1'b0;
  logic rx_resetn;
  logic clk125_resetn;
  logic axis_resetn;

  always #4.0 rx_clk = ~rx_clk;
  initial begin
    #1.3;
    forever #4.0 clk125 = ~clk125;
  end
  always #8.0 axis_clk = ~axis_clk;

  rtlnet_reset_sync u_rx_rst   (.clk(rx_clk),   .arstn(arstn), .resetn(rx_resetn));
  rtlnet_reset_sync u_125_rst  (.clk(clk125),   .arstn(arstn), .resetn(clk125_resetn));
  rtlnet_reset_sync u_axis_rst (.clk(axis_clk), .arstn(arstn), .resetn(axis_resetn));

  // ---------------------------------------------------------------------------
  // Byte clock-enable patterns
  // ---------------------------------------------------------------------------
  int ce_mode = 0;          // 0 always, 1 one in ten, 2 irregular
  int rx_ce_cnt = 0;
  int tx_ce_cnt = 0;
  int rx_zero_run = 0;
  int tx_zero_run = 0;
  logic tx_ce = 1'b1;

  function automatic bit ce_value(input int mode, input int cnt, input int phase, inout int zero_run);
    bit v;
    case (mode)
      0:       v = 1'b1;
      1:       v = ((cnt % 10) == phase);
      default: v = (($urandom % 4) == 0) || (zero_run >= 6);
    endcase
    zero_run = v ? 0 : zero_run + 1;
    return v;
  endfunction

  always @(posedge clk125) begin
    tx_ce_cnt <= tx_ce_cnt + 1;
    tx_ce     <= ce_value(ce_mode, tx_ce_cnt, 3, tx_zero_run);
  end

  // ---------------------------------------------------------------------------
  // GMII RX driver: symbol queue {er, dv, data}; garbage while ce is low.
  // ---------------------------------------------------------------------------
  logic [7:0] gmii_rxd   = 8'h00;
  logic       gmii_rx_dv = 1'b0;
  logic       gmii_rx_er = 1'b0;
  logic       rx_ce      = 1'b1;
  bit [9:0]   rx_sym_q[$];

  always @(posedge rx_clk) begin
    bit       v;
    bit [9:0] s;
    rx_ce_cnt <= rx_ce_cnt + 1;
    v = ce_value(ce_mode, rx_ce_cnt, 7, rx_zero_run);
    rx_ce <= v;
    if (v) begin
      if (rx_sym_q.size() != 0) s = rx_sym_q.pop_front();
      else                      s = 10'h000;
      gmii_rxd   <= s[7:0];
      gmii_rx_dv <= s[8];
      gmii_rx_er <= s[9];
    end else begin
      gmii_rxd   <= 8'($urandom);
      gmii_rx_dv <= 1'($urandom);
      gmii_rx_er <= 1'($urandom);
    end
  end

  // ---------------------------------------------------------------------------
  // RX chain under test
  // ---------------------------------------------------------------------------
  logic [63:0] rxg_data;
  logic [7:0]  rxg_keep;
  logic        rxg_valid;
  logic        rxg_last;
  logic        rxg_bad;
  logic        rx_guard_bad;
  logic        rx_s_ready;
  logic [63:0] rx_m_data;
  logic [7:0]  rx_m_keep;
  logic        rx_m_valid;
  logic        rx_m_ready;
  logic        rx_m_last;
  logic        rx_overflow;
  logic        rx_bad_frame;

  rtlnet_gmii_rx u_gmii_rx (
    .clk        (rx_clk),
    .resetn     (rx_resetn),
    .gmii_rxd   (gmii_rxd),
    .gmii_rx_dv (gmii_rx_dv),
    .gmii_rx_er (gmii_rx_er),
    .ce         (rx_ce),
    .m_data     (rxg_data),
    .m_keep     (rxg_keep),
    .m_valid    (rxg_valid),
    .m_last     (rxg_last),
    .m_bad      (rxg_bad)
  );

  rtlnet_frame_guard #(.MIN_BYTES(60), .MAX_BYTES(1518)) u_rx_guard (
    .clk(rx_clk), .resetn(rx_resetn), .keep(rxg_keep), .valid(rxg_valid), .ready(1'b1),
    .last(rxg_last), .bad_in(rxg_bad), .bad_out(rx_guard_bad));

  rtlnet_packet_fifo #(.FIFO_KB(8), .MAX_FRAME_BYTES(1518), .DROP_WHEN_FULL(1'b1)) u_rx_fifo (
    .s_clk(rx_clk), .s_resetn(rx_resetn), .s_data(rxg_data), .s_keep(rxg_keep), .s_valid(rxg_valid),
    .s_ready(rx_s_ready), .s_last(rxg_last), .s_bad(rx_guard_bad),
    .m_clk(axis_clk), .m_resetn(axis_resetn), .m_data(rx_m_data), .m_keep(rx_m_keep), .m_valid(rx_m_valid),
    .m_ready(rx_m_ready), .m_last(rx_m_last), .overflow(rx_overflow), .bad_frame(rx_bad_frame));

  rtlnet_tb_axis_sink #(.READY_PCT(70), .SEED(11), .NAME("rx_sink")) u_sink (
    .clk(axis_clk), .resetn(axis_resetn), .tdata(rx_m_data), .tkeep(rx_m_keep), .tlast(rx_m_last),
    .tvalid(rx_m_valid), .tready(rx_m_ready));

  // ---------------------------------------------------------------------------
  // TX chain under test
  // ---------------------------------------------------------------------------
  logic [63:0] src_data;
  logic [7:0]  src_keep;
  logic        src_last;
  logic        src_valid;
  logic        src_ready;
  logic        tx_guard_bad;
  logic [63:0] txf_data;
  logic [7:0]  txf_keep;
  logic        txf_valid;
  logic        txf_ready;
  logic        txf_last;
  logic        tx_overflow;
  logic        tx_bad_frame;
  logic [7:0]  gmii_txd;
  logic        gmii_tx_en;
  logic        gmii_tx_er;
  logic        frame_sent;
  logic        tx_enable = 1'b1;

  rtlnet_tb_axis_src #(.GAP_PCT(10), .SEED(5)) u_src (
    .clk(axis_clk), .tdata(src_data), .tkeep(src_keep), .tlast(src_last), .tvalid(src_valid), .tready(src_ready));

  rtlnet_frame_guard #(.MIN_BYTES(14), .MAX_BYTES(1518)) u_tx_guard (
    .clk(axis_clk), .resetn(axis_resetn), .keep(src_keep), .valid(src_valid), .ready(src_ready),
    .last(src_last), .bad_in(1'b0), .bad_out(tx_guard_bad));

  rtlnet_packet_fifo #(.FIFO_KB(8), .MAX_FRAME_BYTES(1518), .DROP_WHEN_FULL(1'b0)) u_tx_fifo (
    .s_clk(axis_clk), .s_resetn(axis_resetn), .s_data(src_data), .s_keep(src_keep), .s_valid(src_valid),
    .s_ready(src_ready), .s_last(src_last), .s_bad(tx_guard_bad),
    .m_clk(clk125), .m_resetn(clk125_resetn), .m_data(txf_data), .m_keep(txf_keep), .m_valid(txf_valid),
    .m_ready(txf_ready), .m_last(txf_last), .overflow(tx_overflow), .bad_frame(tx_bad_frame));

  rtlnet_gmii_tx u_gmii_tx (
    .clk(clk125), .resetn(clk125_resetn), .ce(tx_ce), .enable(tx_enable),
    .s_data(txf_data), .s_keep(txf_keep), .s_valid(txf_valid), .s_last(txf_last), .s_ready(txf_ready),
    .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er), .frame_sent(frame_sent));

  // ---------------------------------------------------------------------------
  // Monitors
  // ---------------------------------------------------------------------------
  int     rx_bad_events = 0;
  int     rx_ovf_events = 0;
  int     rx_double_valid = 0;
  logic   rxg_valid_q = 1'b0;
  bytes_t tx_wire_q[$];          // captured wire frames (preamble .. FCS)
  int     tx_gap_q[$];           // idle byte times before each captured frame (-1 = first)
  bytes_t tx_cur;
  int     tx_idle = -1;
  int     tx_er_seen = 0;
  int     tx_pop_words = 0;
  int     tx_pop_q[$];           // words popped per frame
  int     tx_sent_pulses = 0;

  // RX FIFO events, receiver strobe rule.
  always @(posedge axis_clk) begin
    if (axis_resetn) begin
      if (rx_bad_frame) rx_bad_events++;
      if (rx_overflow)  rx_ovf_events++;
    end
  end

  always @(posedge rx_clk) begin
    rxg_valid_q <= rxg_valid;
    if (rx_resetn && rxg_valid && rxg_valid_q) rx_double_valid++;
  end

  // GMII TX monitor: one byte per ce (the value before the advancing edge).
  always @(posedge clk125) begin
    if (clk125_resetn && tx_ce) begin
      if (gmii_tx_er !== 1'b0) tx_er_seen++;
      if (gmii_tx_en === 1'b1) begin
        if (tx_cur.size() == 0) tx_gap_q.push_back(tx_idle);
        tx_cur.push_back(gmii_txd);
      end else begin
        if (tx_cur.size() != 0) begin
          tx_wire_q.push_back(tx_cur);
          tx_cur  = {};
          tx_idle = 0;
        end
        if (tx_idle >= 0) tx_idle++;
      end
    end
  end

  // TX FIFO pop accounting and frame_sent pulses.
  always @(posedge clk125) begin
    if (clk125_resetn) begin
      if (txf_valid && txf_ready) begin
        tx_pop_words++;
        if (txf_last) begin
          tx_pop_q.push_back(tx_pop_words);
          tx_pop_words = 0;
        end
      end
      if (frame_sent) tx_sent_pulses++;
    end
  end

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function automatic bytes_t random_frame(input int len);
    bytes_t f;
    for (int i = 0; i < len; i++) f.push_back(8'($urandom));
    return f;
  endfunction

  // Queue one frame on the RX driver: n_pre preamble octets, the SFD, the
  // frame, its FCS (corrupted if bad_fcs), then gap idle symbols. er_at marks
  // one symbol index (counted from the first preamble octet) with RX_ER.
  task automatic rx_queue(input bytes_t frame, input int n_pre, input bit bad_fcs, input int er_at, input int gap,
                          input bit with_sfd = 1'b1);
    bytes_t fcs;
    bytes_t wbytes;
    fcs = crc32_serial_fcs(frame);
    if (bad_fcs) fcs[1] = fcs[1] ^ 8'h10;
    for (int i = 0; i < n_pre; i++) wbytes.push_back(8'h55);
    if (with_sfd) begin
      wbytes.push_back(8'hD5);
      for (int i = 0; i < $size(frame); i++) wbytes.push_back(frame[i]);
      for (int i = 0; i < 4; i++) wbytes.push_back(fcs[i]);
    end
    for (int i = 0; i < $size(wbytes); i++) rx_sym_q.push_back({(i == er_at), 1'b1, wbytes[i]});
    for (int i = 0; i < gap; i++) rx_sym_q.push_back(10'h000);
  endtask

  task automatic wait_rx_drained();
    int t;
    t = 0;
    while (rx_sym_q.size() != 0 && t < TIMEOUT_CYCLES) begin
      @(posedge rx_clk);
      t++;
    end
    repeat (400) @(posedge axis_clk);
  endtask

  // Check one captured wire frame against the expected client frame.
  task automatic check_tx_wire(input bytes_t wbytes, input bytes_t frame, input string tag);
    bytes_t padded;
    bytes_t body;
    bytes_t fcs;
    bit     pre_ok;
    bit     fcs_ok;
    bit     body_ok;
    string  why;
    padded = pad60(frame);
    fcs    = crc32_serial_fcs(padded);
    pre_ok = (wbytes.size() >= 8);
    for (int i = 0; i < 7 && pre_ok; i++) if (wbytes[i] != 8'h55) pre_ok = 1'b0;
    if (pre_ok && wbytes[7] != 8'hD5) pre_ok = 1'b0;
    tb_check(pre_ok, $sformatf("%s: preamble/SFD (wire %s)", tag, hexdump(wbytes, 8)));
    tb_check(wbytes.size() == padded.size() + 12, $sformatf("%s: wire length %0d, expected %0d", tag, wbytes.size(),
             padded.size() + 12));
    if (wbytes.size() == padded.size() + 12) begin
      for (int i = 8; i < 8 + $size(padded); i++) body.push_back(wbytes[i]);
      body_ok = bytes_equal(body, padded, why);
      tb_check(body_ok, $sformatf("%s: frame body %s", tag, why));
      fcs_ok = 1'b1;
      for (int i = 0; i < 4; i++) if (wbytes[8 + padded.size() + i] != fcs[i]) fcs_ok = 1'b0;
      tb_check(fcs_ok, $sformatf("%s: FCS", tag));
    end
  endtask

  // ---------------------------------------------------------------------------
  // RX tests for the current ce mode
  // ---------------------------------------------------------------------------
  task automatic run_rx(input int mode);
    bytes_t exp_q[$];
    bytes_t f;
    bytes_t got;
    bit     ok;
    string  why;
    int     n;
    int     bad_expect;
    int     lens[4];
    lens[0] = 60; lens[1] = 61; lens[2] = 64; lens[3] = 1518;
    bad_expect = 0;
    rx_bad_events = 0;
    rx_ovf_events = 0;
    u_sink.ready_pct = 70;

    // Good frames, mixed with every kind of bad frame, minimum gaps.
    for (int k = 0; k < RX_FRAMES; k++) begin
      n = (k < 4) ? lens[k] : 60 + ($urandom % (1518 - 60 + 1));
      f = random_frame(n);
      rx_queue(f, k % 8, 1'b0, -1, (k % 3 == 0) ? MIN_IFG : MIN_IFG + ($urandom % 9));
      exp_q.push_back(f);
      case (k % 8)
        1: begin rx_queue(random_frame(80), 7, 1'b1, -1, MIN_IFG); bad_expect++; end          // bad FCS
        2: begin rx_queue(random_frame(100), 7, 1'b0, 40, MIN_IFG); bad_expect++; end         // RX_ER mid-frame
        3: begin rx_queue(random_frame(72), 7, 1'b0, 7, MIN_IFG); bad_expect++; end           // RX_ER on the SFD
        4: begin rx_queue(random_frame(20), 7, 1'b0, -1, MIN_IFG); bad_expect++; end          // runt
        5: begin rx_queue(random_frame(1600), 7, 1'b0, -1, MIN_IFG); bad_expect++; end        // oversize
        6: begin rx_queue(random_frame(3), 7, 1'b1, -1, MIN_IFG); bad_expect++; end           // SFD + 3 bytes
        7: begin
             rx_queue(random_frame(10), 7, 1'b0, -1, MIN_IFG, 1'b0);                          // no SFD
             for (int i = 0; i < 4; i++) rx_sym_q.push_back(10'h200 | 10'(i));                // RX_ER, RX_DV low
           end
        default: ;
      endcase
    end
    wait_rx_drained();
    for (int k = 0; k < $size(exp_q); k++) begin
      u_sink.get(got, TIMEOUT_CYCLES, ok);
      tb_check(ok, $sformatf("mode %0d: RX frame %0d delivered", mode, k));
      if (ok) begin
        ok = bytes_equal(got, exp_q[k], why);
        tb_check(ok, $sformatf("mode %0d: RX frame %0d byte-exact: %s", mode, k, why));
      end
    end
    u_sink.expect_none(200, ok);
    tb_check(ok, $sformatf("mode %0d: no extra RX frame", mode));
    tb_check(rx_bad_events == bad_expect, $sformatf("mode %0d: RX bad_frame events %0d, expected %0d", mode,
             rx_bad_events, bad_expect));
    tb_check(rx_ovf_events == 0, $sformatf("mode %0d: no RX overflow (%0d)", mode, rx_ovf_events));
    tb_check(rx_double_valid == 0, $sformatf("mode %0d: receiver m_valid on consecutive clocks (%0d)", mode,
             rx_double_valid));

    // Drop when full: sink stalled, six frames, four slots.
    if (mode == 0) begin
      exp_q = {};
      u_sink.ready_pct = 0;
      repeat (4) @(posedge axis_clk);
      for (int k = 0; k < 6; k++) begin
        f = random_frame(64 + k);
        rx_queue(f, 7, 1'b0, -1, MIN_IFG);
        if (k < 4) exp_q.push_back(f);
      end
      wait_rx_drained();
      tb_check(rx_ovf_events == 2, $sformatf("drop-when-full: overflow events %0d, expected 2", rx_ovf_events));
      u_sink.ready_pct = 100;
      for (int k = 0; k < 4; k++) begin
        u_sink.get(got, TIMEOUT_CYCLES, ok);
        tb_check(ok && bytes_equal(got, exp_q[k], why), $sformatf("drop-when-full: stored frame %0d %s", k, why));
      end
      u_sink.expect_none(200, ok);
      tb_check(ok, "drop-when-full: only four frames stored");
    end
  endtask

  // ---------------------------------------------------------------------------
  // TX tests for the current ce mode
  // ---------------------------------------------------------------------------
  task automatic run_tx(input int mode);
    bytes_t exp_q[$];
    bytes_t f;
    bytes_t wbytes;
    int     n;
    int     t;
    int     min_gap;
    int     lens[5];
    int     pops;
    lens[0] = 14; lens[1] = 59; lens[2] = 60; lens[3] = 61; lens[4] = 1518;
    tx_wire_q = {};
    tx_gap_q  = {};
    tx_pop_q  = {};
    tx_sent_pulses = 0;
    tx_er_seen = 0;
    tx_enable = 1'b1;

    for (int k = 0; k < TX_FRAMES; k++) begin
      n = (k < 5) ? lens[k] : 14 + ($urandom % (1518 - 14 + 1));
      exp_q.push_back(random_frame(n));
    end
    // Source sends back to back (the FIFO fills and back-pressures).
    for (int k = 0; k < $size(exp_q); k++) u_src.send(exp_q[k]);
    t = 0;
    while (tx_wire_q.size() < $size(exp_q) && t < 50 * TIMEOUT_CYCLES) begin
      @(posedge clk125);
      t++;
    end
    repeat (100) @(posedge clk125);
    tb_check(tx_wire_q.size() == $size(exp_q), $sformatf("mode %0d: TX frames on the wire %0d, expected %0d", mode,
             tx_wire_q.size(), $size(exp_q)));
    min_gap = 1 << 30;
    for (int k = 0; k < $size(exp_q) && k < $size(tx_wire_q); k++) begin
      wbytes = tx_wire_q[k];
      check_tx_wire(wbytes, exp_q[k], $sformatf("mode %0d TX frame %0d (len %0d)", mode, k, exp_q[k].size()));
      if (k > 0) begin
        tb_check(tx_gap_q[k] >= MIN_IFG, $sformatf("mode %0d: TX gap before frame %0d = %0d byte times", mode, k,
                 tx_gap_q[k]));
        if (tx_gap_q[k] < min_gap) min_gap = tx_gap_q[k];
      end
    end
    tb_check(min_gap == MIN_IFG, $sformatf("mode %0d: minimum TX gap %0d, expected exactly %0d", mode, min_gap, MIN_IFG));
    tb_check(tx_pop_q.size() == $size(exp_q), $sformatf("mode %0d: TX FIFO frames popped %0d", mode, tx_pop_q.size()));
    for (int k = 0; k < $size(exp_q) && k < $size(tx_pop_q); k++) begin
      pops = (exp_q[k].size() + 7) / 8;
      tb_check(tx_pop_q[k] == pops, $sformatf("mode %0d: TX FIFO pops for frame %0d = %0d, expected %0d", mode, k,
               tx_pop_q[k], pops));
    end
    tb_check(tx_sent_pulses == $size(exp_q), $sformatf("mode %0d: frame_sent pulses %0d", mode, tx_sent_pulses));
    tb_check(tx_er_seen == 0, $sformatf("mode %0d: gmii_tx_er stayed 0", mode));

    // Disabled transmitter: frames are consumed, nothing reaches the wire.
    tx_wire_q = {};
    tx_pop_q  = {};
    tx_sent_pulses = 0;
    tx_enable = 1'b0;
    exp_q = {};
    for (int k = 0; k < 6; k++) exp_q.push_back(random_frame(14 + 200 * k));
    for (int k = 0; k < $size(exp_q); k++) u_src.send(exp_q[k]);
    t = 0;
    while (tx_pop_q.size() < $size(exp_q) && t < 50 * TIMEOUT_CYCLES) begin
      @(posedge clk125);
      t++;
    end
    repeat (200) @(posedge clk125);
    tb_check(tx_pop_q.size() == $size(exp_q), $sformatf("mode %0d: disabled TX consumed %0d frames", mode,
             tx_pop_q.size()));
    for (int k = 0; k < $size(exp_q) && k < $size(tx_pop_q); k++)
      tb_check(tx_pop_q[k] == (exp_q[k].size() + 7) / 8, $sformatf("mode %0d: disabled TX pops frame %0d", mode, k));
    tb_check(tx_wire_q.size() == 0 && tx_cur.size() == 0, $sformatf("mode %0d: disabled TX sent nothing", mode));
    tb_check(tx_sent_pulses == 0, $sformatf("mode %0d: disabled TX frame_sent pulses %0d", mode, tx_sent_pulses));

    // Re-enabled: the next frame goes out.
    tx_enable = 1'b1;
    f = random_frame(33);
    u_src.send(f);
    t = 0;
    while (tx_wire_q.size() < 1 && t < 50 * TIMEOUT_CYCLES) begin
      @(posedge clk125);
      t++;
    end
    tb_check(tx_wire_q.size() == 1, $sformatf("mode %0d: re-enabled TX sends", mode));
    if (tx_wire_q.size() == 1) check_tx_wire(tx_wire_q[0], f, $sformatf("mode %0d re-enabled frame", mode));
  endtask

  // ---------------------------------------------------------------------------
  // Sequence
  // ---------------------------------------------------------------------------
  initial begin
    bytes_t check_vec;
    // Oracle self-test: CRC-32 of "123456789" is 0xCBF43926.
    check_vec = {8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37, 8'h38, 8'h39};
    tb_check(crc32_check_value(check_vec) == 32'hCBF43926, "serial CRC oracle check value");

    for (int mode = 0; mode < 3; mode++) begin
      arstn = 1'b0;
      ce_mode = mode;
      rx_sym_q = {};
      tx_cur = {};
      tx_idle = -1;
      rx_double_valid = 0;
      repeat (20) @(posedge axis_clk);
      arstn = 1'b1;
      repeat (20) @(posedge axis_clk);
      $display("[%0t] tb_rtlnet_eth_mac_gmii: ce mode %0d", $time, mode);
      fork
        run_rx(mode);
        run_tx(mode);
      join
    end
    tb_verdict("tb_rtlnet_eth_mac_gmii");
  end

  initial begin
    #(WATCHDOG);
    tb_error("watchdog timeout");
    tb_verdict("tb_rtlnet_eth_mac_gmii");
  end

endmodule
