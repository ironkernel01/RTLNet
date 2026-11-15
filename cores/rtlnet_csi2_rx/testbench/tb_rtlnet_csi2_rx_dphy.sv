// -----------------------------------------------------------------------------
// File: tb_rtlnet_csi2_rx_dphy.sv
// Purpose: self-checking bench for rtlnet_csi2_rx_dphy (behavioural front end, TARGET "GENERIC") with the bench D-PHY transmitter model:
//   LP sequences, HS settle, HS clock detection, sync byte alignment, lane deskew and the pair stream.
// Cases:
//   1. Reset: no clock running, no lane in a burst.
//   2. Bit rates 420, 280, 140 and 100 Mb/s per lane (continuous clock, two lanes): a packet of 4 + 58 + 2 bytes arrives as the pair stream
//      of the expected bytes, one p_first, one p_end, no ev_sot; the first pair has p_first; st_clk_running is high.
//   2b. The shortest HS trail (8 bit times) and a long one (40) at every bit rate: all 22 real pairs of the packet arrive, at most 12 junk pairs.
//   3. Packet lengths 4 (short packet), 5, 6, 7, 64 and 1602 bytes: odd lengths too.
//   4. Lane skew: lane 1 behind lane 0 and lane 0 behind lane 1 by 0, 0.3, 1, 3, 5, 7.5, 8, 9.5, 12, 15.5, 19.9 and 23 bit times (up to three
//      bytes): the pair stream is correct. A skew of 40 bit times (five bytes) is beyond the range: no pair, ev_sot once.
//   5. Missing sync byte on lane 0, on lane 1, on both: no pair, ev_sot once per burst; the next burst is received.
//   6. Single lane (lane_en = 01): the pairs are consecutive bytes of lane 0.
//   7. (TB_NONCONT = 1, the NONCONT_CLOCK build) Non-continuous clock: the clock lane LP sequence, the clock starts before the data and stops after it; every packet is received; the
//      clock detector shows running during the burst and stopped after it.
//   8. (TB_NONCONT = 0) Clock freeze in the middle of a burst (continuous clock): st_clk_running falls, the rest of the burst gives ev_sot, the pair stream
//      of the burst is not completed; the next packet is received correctly.
//   9. Disabled receiver (cfg_enable = 0): bursts are ignored.
//  10. Back-to-back bursts (the gap is T_HS-EXIT) are all received.
// Defines: TB_NONCONT (0 default: continuous clock build; 1: NONCONT_CLOCK build).
// Plusargs: INJECT_FAILURE (the verdict fails), MUTATE (the expected stream of case 2 is perturbed: the compare must fail).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_NONCONT
  `define TB_NONCONT 0
`endif

module tb_rtlnet_csi2_rx_dphy;

  localparam bit NONCONT = (`TB_NONCONT != 0);

  import rtlnet_tb_pkg::*;
  import rtlnet_csi2_tb_pkg::*;

  logic ref_clk = 1'b0;
  always #2.5 ref_clk = ~ref_clk;
  logic arstn = 1'b0;

  logic clk_p, clk_n;
  logic [1:0] dat_p, dat_n, lp_clk, lp_d0, lp_d1;

  logic [4:0] cfg_tap0 = '0, cfg_tap1 = '0;
  logic [7:0] cfg_settle = 8'd28;
  logic [1:0] cfg_lane_en = 2'b11;
  logic       cfg_enable = 1'b1;
  logic       cfg_bit_rev = 1'b0;

  logic        byte_clk, byte_resetn, byte_resetn_g;
  logic        p_valid, p_first, p_end, ev_sot;
  logic [15:0] p_data;
  logic        st_clk_running, st_dlyctl_rdy;
  logic [1:0]  st_hs, st_locked, st_lp_d0, st_lp_d1;

  rtlnet_csi2_tb_phy tx (.clk_p(clk_p), .clk_n(clk_n), .dat_p(dat_p), .dat_n(dat_n), .lp_clk(lp_clk), .lp_d0(lp_d0), .lp_d1(lp_d1));

  rtlnet_csi2_rx_dphy #(.TARGET("GENERIC"), .NONCONT_CLOCK(NONCONT)) dut (
    .ref_clk(ref_clk), .arstn(arstn),
    .hs_clk_p(clk_p), .hs_clk_n(clk_n), .hs_dat_p(dat_p), .hs_dat_n(dat_n), .lp_clk(lp_clk), .lp_d0(lp_d0), .lp_d1(lp_d1),
    .cfg_tap0(cfg_tap0), .cfg_tap1(cfg_tap1), .cfg_settle(cfg_settle), .cfg_lane_en(cfg_lane_en), .cfg_enable(cfg_enable),
    .cfg_bit_rev(cfg_bit_rev),
    .byte_clk(byte_clk), .byte_resetn(byte_resetn), .byte_resetn_g(byte_resetn_g),
    .p_valid(p_valid), .p_data(p_data), .p_first(p_first), .p_end(p_end), .ev_sot(ev_sot),
    .st_clk_running(st_clk_running), .st_hs(st_hs), .st_locked(st_locked), .st_lp_d0(st_lp_d0), .st_lp_d1(st_lp_d1),
    .st_dlyctl_rdy(st_dlyctl_rdy));

  // Monitor of the pair stream.
  bit [15:0] rx [$];
  int        n_first = 0, n_end = 0, n_sot = 0, n_valid_after_end = 0;
  bit        seen_end = 1'b0;
  bit        collecting = 1'b0;
  bit        mutate = 1'b0;

  // Pairs are collected from p_first to p_end; pairs outside a burst (the output hold of the previous burst after a stopped clock restarted)
  // are not part of a packet.
  always @(posedge byte_clk) begin
    if (byte_resetn_g) begin
      if (p_valid) begin
        if (p_first) begin n_first++; collecting = 1'b1; end
        if (collecting) rx.push_back(p_data);
        if (seen_end && !p_first) n_valid_after_end++;
      end
      if (p_end) begin n_end++; seen_end = 1'b1; collecting = 1'b0; end
      if (p_first) seen_end = 1'b0;
      if (ev_sot) n_sot++;
    end
  end

  task automatic clear_mon();
    rx.delete();
    n_first = 0; n_end = 0; n_sot = 0; n_valid_after_end = 0; seen_end = 1'b0; collecting = 1'b0;
  endtask

  // Compare the received pairs with a packet: the first ceil(len / 2) pairs must equal the packet bytes, the rest is trail.
  task automatic check_packet(input bytes_t pkt, input string tag, input bit chk_end = 1'b1);
    int npairs;
    int bad;
    npairs = (pkt.size() + 1) / 2;
    tb_check(n_first == 1, $sformatf("%s: p_first count %0d", tag, n_first));
    if (chk_end) tb_check(n_end == 1, $sformatf("%s: p_end count %0d", tag, n_end));
    tb_check(n_sot == 0, $sformatf("%s: ev_sot count %0d", tag, n_sot));
    tb_check(rx.size() >= npairs, $sformatf("%s: %0d pairs received, %0d expected", tag, rx.size(), npairs));
    bad = 0;
    for (int i = 0; i < npairs && i < rx.size(); i++) begin
      bit [15:0] e;
      e = pair_at(pkt, i);
      if (mutate && i == 1) e = e ^ 16'h0100;
      // An odd packet: the high byte of the last pair is the first trail byte and is not compared.
      if (i == npairs - 1 && (pkt.size() % 2) == 1) begin
        if (rx[i][7:0] !== e[7:0]) bad++;
      end else if (rx[i] !== e) begin
        bad++;
      end
    end
    tb_check(bad == 0, $sformatf("%s: %0d pair mismatches", tag, bad));
    tb_check(n_valid_after_end == 0, $sformatf("%s: pairs after p_end", tag));
  endtask

  function automatic bytes_t make_pkt(input int len, input int seed);
    bytes_t b;
    for (int i = 0; i < len; i++) b.push_back(8'((i * 37 + seed * 11 + (i >> 3) * 5 + 1) & 8'hFF));
    return b;
  endfunction

  // Send one packet and give the receiver time to finish.
  task automatic run_packet(input bytes_t pkt, input string tag, input bit check);
    clear_mon();
    tx.send_packet(pkt);
    repeat (200) @(posedge ref_clk);
    if (check) check_packet(pkt, tag);
  endtask

  initial begin
    bytes_t pkt;
    real uis [4];
    real sk [12];
    mutate = $test$plusargs("MUTATE");
    tx.omit_sync[0] = 1'b0;
    // 1. Reset.
    repeat (20) @(posedge ref_clk);
    tb_check(!st_clk_running, "clock running during reset");
    arstn = 1'b1;
    repeat (200) @(posedge ref_clk);
    tb_check(st_clk_running, "HS clock not detected");
    tb_check(st_hs == 2'b00, "lane in a burst while idle");
    tb_check(st_lp_d0 == 2'b11 && st_lp_d1 == 2'b11, "LP state of the lanes is not stop");

    // 2. Bit rates.
    uis[0] = 2.381; uis[1] = 3.571; uis[2] = 7.143; uis[3] = 10.0;
    for (int r = 0; r < 4; r++) begin
      tx.ui_ns = uis[r];
      pkt = make_pkt(64, r);
      run_packet(pkt, $sformatf("rate %0d", r), 1'b1);
    end
    tx.ui_ns = 2.381;
    // The shortest HS trail (8 bit times) and a long one: no real pair is lost to the burst end at any bit rate.
    for (int tu = 0; tu < 2; tu++) begin
      tx.trail_ui = (tu == 0) ? 8 : 40;
      for (int r = 0; r < 4; r++) begin
        tx.ui_ns = uis[r];
        pkt = make_pkt(40, 3);
        run_packet(pkt, $sformatf("trail %0d bit times, rate %0d", tx.trail_ui, r), 1'b1);
        tb_check(rx.size() >= 22 && rx.size() <= 22 + 12, $sformatf("trail %0d, rate %0d: %0d pairs (22 real)", tx.trail_ui, r, rx.size()));
      end
    end
    tx.trail_ui = 40;
    tx.ui_ns = 2.381;

    // 3. Lengths.
    begin
      int lens [6];
      lens[0] = 4; lens[1] = 5; lens[2] = 6; lens[3] = 7; lens[4] = 64; lens[5] = 1602;
      for (int i = 0; i < 6; i++) begin
        pkt = make_pkt(lens[i], 20 + i);
        run_packet(pkt, $sformatf("length %0d", lens[i]), 1'b1);
      end
    end

    // 4. Lane skew.
    sk[0] = 0.0; sk[1] = 0.3; sk[2] = 1.0; sk[3] = 3.0; sk[4] = 5.0; sk[5] = 7.5; sk[6] = 8.0; sk[7] = 9.5; sk[8] = 12.0;
    sk[9] = 15.5; sk[10] = 19.9; sk[11] = 23.0;
    for (int s = 0; s < 12; s++) begin
      for (int side = 0; side < 2; side++) begin
        tx.skew_ui[0] = (side == 0) ? 0.0 : sk[s];
        tx.skew_ui[1] = (side == 0) ? sk[s] : 0.0;
        pkt = make_pkt(40, 30 + s);
        run_packet(pkt, $sformatf("skew %0.1f side %0d", sk[s], side), 1'b1);
      end
    end
    tx.skew_ui[0] = 40.0; tx.skew_ui[1] = 0.0;
    clear_mon();
    tx.send_packet(make_pkt(40, 50));
    repeat (200) @(posedge ref_clk);
    tb_check(n_first == 0 && rx.size() == 0, "pairs received with a skew of five bytes");
    tb_check(n_sot == 1, $sformatf("skew beyond range: ev_sot count %0d", n_sot));
    tx.skew_ui[0] = 0.0; tx.skew_ui[1] = 40.0;
    clear_mon();
    tx.send_packet(make_pkt(40, 51));
    repeat (200) @(posedge ref_clk);
    tb_check(n_first == 0 && rx.size() == 0, "pairs received with a skew of five bytes (lane 1)");
    tb_check(n_sot == 1, $sformatf("skew beyond range (lane 1): ev_sot count %0d", n_sot));
    tx.skew_ui[0] = 0.0; tx.skew_ui[1] = 0.0;
    pkt = make_pkt(40, 52);
    run_packet(pkt, "recovery after the skew error", 1'b1);

    // 5. Missing sync byte.
    for (int m = 1; m < 4; m++) begin
      tx.omit_sync[0] = m[0]; tx.omit_sync[1] = m[1];
      clear_mon();
      tx.send_packet(make_pkt(40, 60 + m));
      repeat (200) @(posedge ref_clk);
      tb_check(n_first == 0 && rx.size() == 0, $sformatf("pairs received with a missing sync (mask %0d)", m));
      tb_check(n_sot == 1, $sformatf("missing sync mask %0d: ev_sot count %0d", m, n_sot));
      tx.omit_sync[0] = 1'b0; tx.omit_sync[1] = 1'b0;
      run_packet(make_pkt(40, 70 + m), $sformatf("recovery after a missing sync %0d", m), 1'b1);
    end

    // 6. Single lane.
    cfg_lane_en = 2'b01;
    tx.lanes = 1;
    repeat (50) @(posedge ref_clk);
    pkt = make_pkt(46, 80);
    run_packet(pkt, "single lane", 1'b1);
    pkt = make_pkt(47, 81);
    run_packet(pkt, "single lane odd", 1'b1);
    cfg_lane_en = 2'b11;
    tx.lanes = 2;
    repeat (50) @(posedge ref_clk);

    // 7. Non-continuous clock (NONCONT_CLOCK = 1 build only).
    if (NONCONT) begin
    tx.set_continuous(1'b0);
    repeat (300) @(posedge ref_clk);
    tb_check(!st_clk_running, "clock running with the clock stopped");
    for (int i = 0; i < 3; i++) begin
      pkt = make_pkt(36 + 8 * i, 90 + i);
      clear_mon();
      fork
        tx.send_packet(pkt);
        begin
          int seen;
          seen = 0;
          repeat (800) begin
            @(posedge ref_clk);
            if (st_clk_running) seen = 1;
          end
          tb_check(seen == 1, "clock detector never showed running during a non-continuous burst");
        end
      join
      repeat (200) @(posedge ref_clk);
      // With a stopped clock the end of the burst completes with the next clock start (NONCONT_CLOCK): not checked here.
      check_packet(pkt, $sformatf("non-continuous %0d", i), 1'b0);
      tb_check(!st_clk_running, "clock still running after the burst stopped it");
    end
    clear_mon();
    tx.set_continuous(1'b1);
    repeat (300) @(posedge ref_clk);
    tb_check(st_clk_running, "clock not detected after the return to the continuous clock");
    tb_check(n_end == 1, $sformatf("the end of the last non-continuous burst was not completed by the restarted clock (%0d)", n_end));
    end

    // 8. Clock freeze in the middle of a burst (continuous clock build: the logic restarts with the clock).
    if (!NONCONT) begin
    clear_mon();
    fork
      tx.send_packet(make_pkt(400, 100));
      begin
        int low;
        low = 0;
        #900;
        fork
          tx.freeze_clock(800.0);
          begin
            repeat (200) begin
              @(posedge ref_clk);
              if (!st_clk_running) low = 1;
            end
          end
        join
        tb_check(low == 1, "st_clk_running did not fall during the clock freeze");
      end
    join
    repeat (400) @(posedge ref_clk);
    tb_check(st_clk_running, "clock not running again after the freeze");
    tb_check(n_sot == 1, $sformatf("clock freeze: ev_sot count %0d", n_sot));
    run_packet(make_pkt(64, 101), "recovery after a clock freeze", 1'b1);
    end

    // 9. Disabled receiver.
    cfg_enable = 1'b0;
    repeat (50) @(posedge ref_clk);
    clear_mon();
    tx.send_packet(make_pkt(40, 110));
    repeat (200) @(posedge ref_clk);
    tb_check(n_first == 0 && rx.size() == 0 && n_sot == 0, "burst received with the receiver disabled");
    cfg_enable = 1'b1;
    repeat (100) @(posedge ref_clk);
    run_packet(make_pkt(40, 111), "enabled again", 1'b1);

    // 10. Back-to-back bursts.
    clear_mon();
    for (int i = 0; i < 6; i++) tx.send_packet(make_pkt(20 + i, 120 + i));
    repeat (200) @(posedge ref_clk);
    tb_check(n_first == 6 && n_end == 6, $sformatf("back to back: %0d bursts started, %0d ended", n_first, n_end));
    tb_check(n_sot == 0, "back to back: ev_sot");

    tb_verdict("tb_rtlnet_csi2_rx_dphy");
  end

  initial begin
    #50ms;
    tb_error("bench timeout");
    tb_verdict("tb_rtlnet_csi2_rx_dphy");
  end

endmodule
