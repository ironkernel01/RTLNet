// -----------------------------------------------------------------------------
// File: tb_rtlnet_csi2_rx_packet.sv
// Purpose: self-checking bench for rtlnet_csi2_rx_packet: header ECC, short and long packets, CRC-16, the virtual channel and data type
//   filter, RAW10 unpacking, truncation and the frame state, driven with the pair stream of the lane merge.
// Cases:
//   1. Frame start, three RAW10 lines, frame end: the FIFO entries equal the bench unpacking (four 10-bit pixels per entry, start of frame
//      on the first entry of the first line only, end of line on the last entry of every line, a frame-end marker entry), no error event.
//   2. Line lengths of 20 to 2400 bytes (4 to 1920 pixels), word counts of odd and even byte count: entries and flags correct.
//   3. Every single-bit error of the 32 header bits (data identifier, word count, ECC byte) on a long packet and on a frame start: corrected
//      (ev_ecc_corr once), the packet is used unchanged. All 496 double-bit errors of a frame start: ev_ecc_unc once, no frame start; 120
//      double-bit errors of a long packet: ev_ecc_unc once, no entry.
//   4. Payload CRC: each of the 16 CRC bits flipped, and a flipped payload bit: ev_crc once and the (corrupt) pixels are still pushed.
//   5. Filter: another virtual channel is dropped without any event, a long packet of data type 0x2A or 0x12 and the short types 0x08 and 0x0F
//      raise ev_dt and push nothing, line start and line end are ignored, a line outside a frame raises ev_orphan.
//   6. Word count 0 and word counts that are not a multiple of five raise ev_len (complete groups are still pushed).
//   7. Truncation: a burst that ends after 1, 2, 3, 5, 10 and N - 1 pairs of a 40-byte-payload line raises ev_trunc once; the entries pushed
//      so far are closed by an end-of-line marker entry; a new burst without the end of the previous one (p_first) does the same and its own
//      packet is decoded.
//   8. HS trail bytes after the packet (all-zero, all-one and mixed pairs) and a second packet chained in the same burst are ignored.
//   9. The pair stream with random gaps (valid low between pairs) gives the same entries as the continuous stream.
//  10. Frame start while a frame is open: both are counted, the second arms the start flag again.
// Plusargs: INJECT_FAILURE (the verdict fails), MUTATE (the expected value of one entry is perturbed: the compare must fail).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_csi2_rx_packet;

  import rtlnet_tb_pkg::*;
  import rtlnet_csi2_tb_pkg::*;
  import rtlnet_csi2_rx_pkg::*;

  logic clk = 1'b0;
  always #9.5 clk = ~clk;
  logic resetn = 1'b0;

  logic [1:0]  cfg_vc = 2'd0;
  logic [5:0]  cfg_dt = 6'h2B;
  logic        p_valid = 1'b0, p_first = 1'b0, p_end = 1'b0;
  logic [15:0] p_data = '0;
  logic        e_valid;
  logic [ENT_W-1:0] e_data;
  logic        ev_ecc_corr, ev_ecc_unc, ev_crc, ev_trunc, ev_dt, ev_frame, ev_orphan, ev_len;
  logic        st_in_frame;

  rtlnet_csi2_rx_packet dut (
    .byte_clk(clk), .byte_resetn(resetn), .cfg_vc(cfg_vc), .cfg_dt(cfg_dt),
    .p_valid(p_valid), .p_data(p_data), .p_first(p_first), .p_end(p_end),
    .e_valid(e_valid), .e_data(e_data),
    .ev_ecc_corr(ev_ecc_corr), .ev_ecc_unc(ev_ecc_unc), .ev_crc(ev_crc), .ev_trunc(ev_trunc), .ev_dt(ev_dt),
    .ev_frame(ev_frame), .ev_orphan(ev_orphan), .ev_len(ev_len), .st_in_frame(st_in_frame));

  // Monitor.
  bit [ENT_W-1:0] ents [$];
  int ev_cnt [8];
  bit mutate = 1'b0;
  logic [31:0] lfsr = 32'h1357_9BDF;

  always @(posedge clk) begin
    lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    if (e_valid) ents.push_back(e_data);
    if (ev_ecc_corr) ev_cnt[0]++;
    if (ev_ecc_unc)  ev_cnt[1]++;
    if (ev_crc)      ev_cnt[2]++;
    if (ev_trunc)    ev_cnt[3]++;
    if (ev_dt)       ev_cnt[4]++;
    if (ev_frame)    ev_cnt[5]++;
    if (ev_orphan)   ev_cnt[6]++;
    if (ev_len)      ev_cnt[7]++;
  end

  task automatic clear_mon();
    ents.delete();
    for (int i = 0; i < 8; i++) ev_cnt[i] = 0;
  endtask

  // Drive one burst: pairs of the packet (the first pair p_first), optionally cut after cut_pairs pairs (0 = whole), trail pairs after
  // it, random gaps, then p_end (end_burst = 0 leaves the burst open for the next one).
  task automatic drive(input bytes_t pkt, input int cut_pairs, input bit [15:0] trail, input int trail_pairs, input bit gapped,
                       input bit end_burst);
    int n;
    n = (pkt.size() + 1) / 2;
    if (cut_pairs > 0 && cut_pairs < n) n = cut_pairs;
    for (int i = 0; i < n + trail_pairs; i++) begin
      if (gapped) begin
        while (lfsr[2:0] < 3'd3) begin
          p_valid <= 1'b0; p_first <= 1'b0; p_end <= 1'b0;
          @(posedge clk);
        end
      end
      p_valid <= 1'b1;
      p_first <= (i == 0);
      p_end   <= 1'b0;
      p_data  <= (i < n) ? pair_at(pkt, i) : trail;
      @(posedge clk);
    end
    p_valid <= 1'b0; p_first <= 1'b0;
    if (end_burst) begin
      @(posedge clk);
      p_end <= 1'b1;
      @(posedge clk);
      p_end <= 1'b0;
    end
    repeat (4) @(posedge clk);
  endtask

  function automatic int exp_wc_groups(input int wc);
    return wc / 5;
  endfunction

  // Entries expected for one line of pixels: groups of four, sof on the first, eol on the last (when keep_eol).
  function automatic void add_line_entries(ref bit [ENT_W-1:0] q [$], input pix_q_t px, input bit sof, input bit eol_on_last);
    for (int g = 0; g + 3 < px.size(); g += 4) begin
      bit last;
      last = (g + 4 >= px.size());
      q.push_back({1'b0, (last && eol_on_last), (sof && g == 0), 3'd4, px[g + 3], px[g + 2], px[g + 1], px[g + 0]});
    end
  endfunction

  function automatic pix_q_t make_pixels(input int n, input int seed);
    pix_q_t p;
    for (int i = 0; i < n; i++) p.push_back(10'((i * 97 + seed * 31 + (i >> 2) * 13 + 5) & 10'h3FF));
    return p;
  endfunction

  function automatic bytes_t line_pkt(input pix_q_t px, input int flip_crc = -1);
    return long_pkt(2'd0, 6'h2B, raw10_payload(px), flip_crc);
  endfunction

  task automatic check_events(input string tag, input int e0, input int e1, input int e2, input int e3, input int e4, input int e5,
                              input int e6, input int e7);
    int ex [8];
    string nm [8];
    ex[0] = e0; ex[1] = e1; ex[2] = e2; ex[3] = e3; ex[4] = e4; ex[5] = e5; ex[6] = e6; ex[7] = e7;
    nm[0] = "ecc_corr"; nm[1] = "ecc_unc"; nm[2] = "crc"; nm[3] = "trunc"; nm[4] = "dt"; nm[5] = "frame"; nm[6] = "orphan"; nm[7] = "len";
    for (int i = 0; i < 8; i++) tb_check(ev_cnt[i] == ex[i], $sformatf("%s: %s count %0d, expected %0d", tag, nm[i], ev_cnt[i], ex[i]));
  endtask

  task automatic check_entries(input string tag, input bit [ENT_W-1:0] q [$]);
    int bad;
    tb_check(ents.size() == q.size(), $sformatf("%s: %0d entries, expected %0d", tag, ents.size(), q.size()));
    bad = 0;
    for (int i = 0; i < q.size() && i < ents.size(); i++) begin
      bit [ENT_W-1:0] e;
      e = q[i];
      if (mutate && i == 1) e = e ^ 46'h1;
      if (ents[i] !== e) begin
        bad++;
        if (bad <= 3) $display("%s: entry %0d got %012x expected %012x", tag, i, ents[i], e);
      end
    end
    tb_check(bad == 0, $sformatf("%s: %0d entry mismatches", tag, bad));
  endtask

  bytes_t fs_pkt, fe_pkt;
  bit [ENT_W-1:0] expq [$];

  // Frame start so that a line is accepted, then clear the monitor.
  task automatic open_frame();
    drive(short_pkt(2'd0, 6'h00, 16'd1), 0, 16'h0000, 3, 1'b0, 1'b1);
  endtask

  task automatic close_frame();
    drive(short_pkt(2'd0, 6'h01, 16'd1), 0, 16'h0000, 3, 1'b0, 1'b1);
  endtask

  initial begin
    pix_q_t px, px2, px3;
    bytes_t pk;
    bytes_t bad_pk;
    bytes_t empty;
    int lens [8];
    mutate = $test$plusargs("MUTATE");
    repeat (6) @(posedge clk);
    resetn <= 1'b1;
    repeat (6) @(posedge clk);

    // 1. A small frame.
    clear_mon();
    px  = make_pixels(32, 1);
    px2 = make_pixels(32, 2);
    px3 = make_pixels(32, 3);
    open_frame();
    tb_check(st_in_frame, "frame start did not open the frame");
    drive(line_pkt(px), 0, 16'h0000, 3, 1'b0, 1'b1);
    drive(line_pkt(px2), 0, 16'hFFFF, 3, 1'b0, 1'b1);
    drive(line_pkt(px3), 0, 16'hFF00, 3, 1'b0, 1'b1);
    close_frame();
    expq.delete();
    add_line_entries(expq, px, 1'b1, 1'b1);
    add_line_entries(expq, px2, 1'b0, 1'b1);
    add_line_entries(expq, px3, 1'b0, 1'b1);
    expq.push_back({1'b1, 1'b0, 1'b0, 3'd0, 40'd0});
    check_entries("frame", expq);
    check_events("frame", 0, 0, 0, 0, 0, 1, 0, 0);
    tb_check(!st_in_frame, "frame end did not close the frame");

    // 2. Lengths.
    lens[0] = 4; lens[1] = 8; lens[2] = 12; lens[3] = 20; lens[4] = 36; lens[5] = 64; lens[6] = 1280; lens[7] = 1920;
    for (int i = 0; i < 8; i++) begin
      clear_mon();
      px = make_pixels(lens[i], 10 + i);
      open_frame();
      ents.delete();
      drive(line_pkt(px), 0, 16'h0000, 3, 1'b0, 1'b1);
      expq.delete();
      add_line_entries(expq, px, 1'b1, 1'b1);
      check_entries($sformatf("length %0d px", lens[i]), expq);
      check_events($sformatf("length %0d px", lens[i]), 0, 0, 0, 0, 0, 1, 0, 0);
      close_frame();
    end

    // 3. Header bit errors.
    px = make_pixels(16, 20);
    for (int b = 0; b < 32; b++) begin
      clear_mon();
      open_frame();
      ents.delete(); ev_cnt[5] = 0;
      pk = flip_bit(line_pkt(px), b);
      drive(pk, 0, 16'h0000, 3, 1'b0, 1'b1);
      expq.delete();
      add_line_entries(expq, px, 1'b1, 1'b1);
      check_entries($sformatf("long packet, header bit %0d flipped", b), expq);
      check_events($sformatf("long packet, header bit %0d flipped", b), 1, 0, 0, 0, 0, 0, 0, 0);
      close_frame();
      // A frame start with a flipped bit.
      clear_mon();
      drive(flip_bit(short_pkt(2'd0, 6'h00, 16'd7), b), 0, 16'h0000, 3, 1'b0, 1'b1);
      check_events($sformatf("frame start, header bit %0d flipped", b), 1, 0, 0, 0, 0, 1, 0, 0);
      tb_check(st_in_frame, $sformatf("frame start with bit %0d flipped did not open the frame", b));
      close_frame();
    end
    for (int a = 0; a < 32; a++) begin
      for (int b = a + 1; b < 32; b++) begin
        clear_mon();
        pk = flip_bit(flip_bit(short_pkt(2'd0, 6'h00, 16'd7), a), b);
        drive(pk, 0, 16'h0000, 2, 1'b0, 1'b1);
        if (ev_cnt[1] != 1 || ev_cnt[5] != 0 || ents.size() != 0 || st_in_frame)
          tb_check(1'b0, $sformatf("double error bits %0d,%0d on a frame start: unc %0d frame %0d", a, b, ev_cnt[1], ev_cnt[5]));
        else tb_check(1'b1, "double error");
        close_frame();
      end
    end
    open_frame();
    for (int k = 0; k < 120; k++) begin
      int a, b;
      a = (k * 7) % 32;
      b = (a + 1 + (k * 5) % 30) % 32;
      if (a == b) b = (b + 1) % 32;
      clear_mon();
      pk = flip_bit(flip_bit(line_pkt(px), a), b);
      drive(pk, 0, 16'h0000, 2, 1'b0, 1'b1);
      tb_check(ev_cnt[1] == 1 && ents.size() == 0 && ev_cnt[0] == 0, $sformatf("double error bits %0d,%0d on a line: unc %0d entries %0d", a, b, ev_cnt[1], ents.size()));
    end
    close_frame();

    // 4. CRC.
    open_frame();
    for (int c = 0; c < 16; c++) begin
      clear_mon();
      drive(line_pkt(px, c), 0, 16'h0000, 3, 1'b0, 1'b1);
      expq.delete();
      add_line_entries(expq, px, 1'b1, 1'b1);
      check_entries($sformatf("crc bit %0d", c), expq);
      check_events($sformatf("crc bit %0d", c), 0, 0, 1, 0, 0, 0, 0, 0);
      close_frame();
      open_frame();
    end
    begin
      // A flipped payload bit: the pixels of the corrupt payload are pushed, the CRC is of the original payload.
      bytes_t pay, pay_bad;
      bit [15:0] cc;
      pix_q_t px_bad;
      bit [9:0] t10;
      pay = raw10_payload(px);
      pay_bad = flip_bit(pay, 3 * 8 + 2);
      cc = crc16_of(pay);
      bad_pk = header_bytes(2'd0, 6'h2B, 16'(pay.size()));
      for (int i = 0; i < pay_bad.size(); i++) bad_pk.push_back(pay_bad[i]);
      bad_pk.push_back(cc[7:0]);
      bad_pk.push_back(cc[15:8]);
      px_bad = px;
      // Byte 3 holds the high eight bits of pixel 3: bit 2 of the byte is bit 4 of the pixel.
      t10 = px_bad[3];
      t10[4] = ~t10[4];
      px_bad[3] = t10;
      clear_mon();
      drive(bad_pk, 0, 16'h0000, 3, 1'b0, 1'b1);
      expq.delete();
      add_line_entries(expq, px_bad, 1'b1, 1'b1);
      check_entries("flipped payload bit", expq);
      check_events("flipped payload bit", 0, 0, 1, 0, 0, 0, 0, 0);
    end
    close_frame();

    // 5. Filter.
    clear_mon();
    drive(short_pkt(2'd1, 6'h00, 16'd1), 0, 16'h0000, 3, 1'b0, 1'b1);
    tb_check(!st_in_frame, "a frame start of another virtual channel opened the frame");
    open_frame();
    clear_mon();
    drive(long_pkt(2'd1, 6'h2B, raw10_payload(px)), 0, 16'h0000, 3, 1'b0, 1'b1);
    drive(short_pkt(2'd2, 6'h08, 16'd0), 0, 16'h0000, 3, 1'b0, 1'b1);
    tb_check(ents.size() == 0, "other virtual channel pushed entries");
    check_events("other virtual channel", 0, 0, 0, 0, 0, 0, 0, 0);
    clear_mon();
    drive(long_pkt(2'd0, 6'h2A, raw10_payload(px)), 0, 16'h0000, 3, 1'b0, 1'b1);
    drive(long_pkt(2'd0, 6'h12, raw10_payload(px)), 0, 16'h0000, 3, 1'b0, 1'b1);
    drive(short_pkt(2'd0, 6'h08, 16'd0), 0, 16'h0000, 3, 1'b0, 1'b1);
    drive(short_pkt(2'd0, 6'h0F, 16'd0), 0, 16'h0000, 3, 1'b0, 1'b1);
    tb_check(ents.size() == 0, "wrong data type pushed entries");
    check_events("wrong data type", 0, 0, 0, 0, 4, 0, 0, 0);
    clear_mon();
    drive(short_pkt(2'd0, 6'h02, 16'd5), 0, 16'h0000, 3, 1'b0, 1'b1);
    drive(short_pkt(2'd0, 6'h03, 16'd5), 0, 16'h0000, 3, 1'b0, 1'b1);
    check_events("line start / end", 0, 0, 0, 0, 0, 0, 0, 0);
    tb_check(st_in_frame, "line start / end changed the frame state");
    close_frame();
    clear_mon();
    drive(line_pkt(px), 0, 16'h0000, 3, 1'b0, 1'b1);
    tb_check(ents.size() == 0, "a line outside a frame pushed entries");
    check_events("orphan line", 0, 0, 0, 0, 0, 0, 1, 0);

    // 6. Word counts.
    open_frame();
    clear_mon();
    drive(long_pkt(2'd0, 6'h2B, empty), 0, 16'h0000, 3, 1'b0, 1'b1);
    check_events("word count 0", 0, 0, 0, 0, 0, 0, 0, 1);
    tb_check(ents.size() == 0, "word count 0 pushed entries");
    for (int wcn = 1; wcn <= 14; wcn++) begin
      bytes_t pay;
      int groups;
      pay.delete();
      for (int i = 0; i < wcn; i++) pay.push_back(8'((i * 29 + 7) & 8'hFF));
      clear_mon();
      drive(long_pkt(2'd0, 6'h2B, pay), 0, 16'h0000, 3, 1'b0, 1'b1);
      groups = wcn / 5;
      tb_check(ents.size() == groups, $sformatf("word count %0d: %0d entries, expected %0d", wcn, ents.size(), groups));
      if (groups > 0) tb_check(ents[ents.size() - 1][ENT_EOL], $sformatf("word count %0d: no end of line on the last group", wcn));
      tb_check(ev_cnt[7] == ((wcn % 5) != 0 ? 1 : 0), $sformatf("word count %0d: ev_len %0d", wcn, ev_cnt[7]));
      tb_check(ev_cnt[2] == 0, $sformatf("word count %0d: crc error %0d", wcn, ev_cnt[2]));
    end
    close_frame();

    // 7. Truncation.
    begin
      int cuts [6];
      pix_q_t px40;
      px40 = make_pixels(32, 50);
      pk = line_pkt(px40);
      cuts[0] = 1; cuts[1] = 2; cuts[2] = 3; cuts[3] = 5; cuts[4] = 10; cuts[5] = (pk.size() + 1) / 2 - 1;
      for (int i = 0; i < 6; i++) begin
        int emitted, marker;
        open_frame();
        clear_mon();
        drive(pk, cuts[i], 16'h0000, 0, 1'b0, 1'b1);
        check_events($sformatf("truncated after %0d pairs", cuts[i]), 0, 0, 0, 1, 0, 0, 0, 0);
        // Payload pair p completes group one at pair index 2 and group two at 4 of every five payload pairs.
        emitted = 0;
        for (int p = 0; p < cuts[i] - 2; p++) if (p % 5 == 2 || p % 5 == 4) emitted++;
        marker = (emitted > 0 && emitted < 8) ? 1 : 0;
        tb_check(ents.size() == emitted + marker, $sformatf("truncated after %0d pairs: %0d entries, expected %0d", cuts[i], ents.size(), emitted + marker));
        if (marker == 1) tb_check(ents[ents.size() - 1][ENT_EOL] && ents[ents.size() - 1][ENT_CNT +: 3] == 3'd0, "truncated line is not closed by an end-of-line marker");
        if (emitted == 8) tb_check(ents[ents.size() - 1][ENT_EOL], "a line complete up to its CRC has no end of line");
        close_frame();
      end
      // A new burst without the end of the previous one.
      open_frame();
      clear_mon();
      drive(pk, 8, 16'h0000, 0, 1'b0, 1'b0);
      drive(pk, 0, 16'h0000, 2, 1'b0, 1'b1);
      check_events("burst restart", 0, 0, 0, 1, 0, 0, 0, 0);
      tb_check(ents.size() > 0 && ents[ents.size() - 1][ENT_EOL] == 1'b1, "burst restart: the following packet was not decoded");
      close_frame();
    end

    // 8. Trail bytes and a chained packet.
    open_frame();
    clear_mon();
    px = make_pixels(16, 60);
    drive(line_pkt(px), 0, 16'h0000, 6, 1'b0, 1'b1);
    drive(line_pkt(px), 0, 16'hFFFF, 6, 1'b0, 1'b1);
    drive(short_pkt(2'd0, 6'h01, 16'd1), 0, 16'h0000, 6, 1'b0, 1'b1);
    check_events("trail", 0, 0, 0, 0, 0, 0, 0, 0);
    tb_check(ents.size() == 4 + 4 + 1, $sformatf("trail: %0d entries", ents.size()));
    tb_check(!st_in_frame, "trail: frame end lost");
    open_frame();
    clear_mon();
    begin
      bytes_t two;
      two = line_pkt(px);
      pk = short_pkt(2'd0, 6'h01, 16'd1);
      for (int i = 0; i < pk.size(); i++) two.push_back(pk[i]);
      drive(two, 0, 16'h0000, 2, 1'b0, 1'b1);
      check_events("chained packet", 0, 0, 0, 0, 0, 0, 0, 0);
      tb_check(ents.size() == 4 && st_in_frame, "a second packet in the same burst was not ignored");
    end
    close_frame();

    // 9. Gaps.
    open_frame();
    clear_mon();
    px = make_pixels(64, 70);
    drive(line_pkt(px), 0, 16'h0000, 3, 1'b1, 1'b1);
    expq.delete();
    add_line_entries(expq, px, 1'b1, 1'b1);
    check_entries("gapped pair stream", expq);
    check_events("gapped pair stream", 0, 0, 0, 0, 0, 0, 0, 0);
    close_frame();

    // 10. Frame start inside a frame.
    clear_mon();
    open_frame();
    open_frame();
    drive(line_pkt(px), 0, 16'h0000, 3, 1'b0, 1'b1);
    check_events("double frame start", 0, 0, 0, 0, 0, 2, 0, 0);
    tb_check(ents.size() == 16 && ents[0][ENT_SOF], "double frame start: the line after it does not carry the start flag");
    close_frame();

    tb_verdict("tb_rtlnet_csi2_rx_packet");
  end

  initial begin
    #200ms;
    tb_error("bench timeout");
    tb_verdict("tb_rtlnet_csi2_rx_packet");
  end

endmodule
