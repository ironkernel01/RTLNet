// -----------------------------------------------------------------------------
// File: tb_rtlnet_vdma_s2mm.sv
// Purpose: self-checking bench for rtlnet_vdma_s2mm against the AXI4 memory model (rtlnet_tb_axi4_mem) with random ready
//   and valid gaps on both sides.
// Cases (one run, in order; TB_FULL adds two full-size frames):
//   1. Packed frame (STRIDE 0), 64x4: every byte in memory equals the stream word order (Y0 Cb Y1 Cr, word 0 in the low
//      bytes of a beat), no other word is written, the burst sequence equals the bench's own splitter.
//   2. Stride: 256x8 at stride 1,024; 8x20 at stride 16 (one beat per line, bursts of one beat).
//   3. The 4 KiB rule: base 0xF80 with 512x6 at stride 1,040 (lines wander across pages; the first burst of the first
//      line is cut at the page end); every AW is compared with the independent splitter; the memory model checks that no
//      burst crosses 4 KiB; bursts never exceed 16 beats.
//   4. Geometry errors (width not a multiple of 8 pixels, height 0, stride below the line bytes or not a multiple of 16):
//      the frame is dropped, STATUS.CFG_ERR sets, nothing is written, the next frame is normal.
//   5. No slot (the frame buffer answers not ok): the frame is dropped and discarded, nothing is written.
//   6. Disabled (CTRL.ENABLE 0): frames are discarded; enabled again the next frame is written.
//   7. Line errors: a missing tlast and an early tlast mark the frame not good (STATUS.LINE_ERR), the data still follow
//      the word counts.
//   8. Cut-off frame (a new first word after 3 of 8 lines): the three lines are written, the rest is padded with zero
//      beats, fb_done reports not good, the next frame is normal and good.
//   9. Write error: a SLVERR response marks the frame not good and sets STATUS.AXI_ERR.
//  10. Registers: ID, CAPS, STRIDE, FRAMES_OK / BAD / DROPPED, BURSTS and BEATS against the bench's counts and the memory
//      model's, LAST_BASE, STATUS write-1-to-clear, CNT_CLEAR.
//  11. fb_done carries the sideband of its frame; fb_done_good only for a good frame.
// Defines: TB_GAP 1 = random gaps (stream valid, AW/W/B ready), TB_FULL 1 = also 1280x720 and 1920x1080 frames, TB_BURST
//   MAX_BURST_BEATS, TB_FKB FIFO kilobytes.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_GAP
  `define TB_GAP 1
`endif
`ifndef TB_FULL
  `define TB_FULL 0
`endif
`ifndef TB_BURST
  `define TB_BURST 16
`endif
`ifndef TB_FKB
  `define TB_FKB 2
`endif

module tb_rtlnet_vdma_s2mm;

  import rtlnet_tb_pkg::*;

  localparam int ADDR_W  = 29;
  localparam int GAP     = `TB_GAP;
  localparam int MAXB    = `TB_BURST;

  logic clk     = 1'b0;
  logic cfg_clk = 1'b0;
  logic arstn   = 1'b0;
  logic resetn;
  logic cfg_resetn;

  always #5.0  clk     = ~clk;
  always #4.85 cfg_clk = ~cfg_clk;

  rtlnet_reset_sync u_rst_a (.clk(clk),     .arstn(arstn), .resetn(resetn));
  rtlnet_reset_sync u_rst_b (.clk(cfg_clk), .arstn(arstn), .resetn(cfg_resetn));

  // Stream and sideband.
  logic [31:0]       s_tdata = '0;
  logic              s_tvalid = 1'b0;
  logic              s_tready;
  logic              s_tlast = 1'b0;
  logic              s_tuser = 1'b0;
  logic [15:0]       s_width = '0;
  logic [15:0]       s_height = '0;
  logic [31:0]       s_frame = '0;
  logic [31:0]       s_ts = '0;
  logic              s_src = 1'b0;

  // Frame-buffer side (bench stub).
  logic              fb_req;
  logic              fb_rsp_valid = 1'b0;
  logic              fb_rsp_ok = 1'b0;
  logic [ADDR_W-1:0] fb_rsp_base = '0;
  logic              fb_done;
  logic              fb_done_good;
  logic [31:0]       fb_done_frame;
  logic [31:0]       fb_done_ts;
  logic [15:0]       fb_done_w;
  logic [15:0]       fb_done_h;
  logic              fb_done_src;

  // AXI4.
  logic [0:0]        awid, bid;
  logic [ADDR_W-1:0] awaddr;
  logic [7:0]        awlen;
  logic [2:0]        awsize;
  logic [1:0]        awburst;
  logic              awvalid, awready;
  logic [127:0]      wdata;
  logic [15:0]       wstrb;
  logic              wlast, wvalid, wready;
  logic [1:0]        bresp_mem, bresp_dut;
  logic              bvalid, bready;
  logic              inject_axi_err = 1'b0;

  assign bresp_dut = inject_axi_err ? 2'b10 : bresp_mem;

  logic [11:0] awaddr_l, araddr_l;
  logic [31:0] wdata_l, rdata_l;
  logic [3:0]  wstrb_l;
  logic [1:0]  bresp_l, rresp_l;
  logic        awvalid_l, awready_l, wvalid_l, wready_l, bvalid_l, bready_l, arvalid_l, arready_l, rvalid_l, rready_l;

  rtlnet_tb_axil_master #(.ADDR_W(12)) u_mst (
    .aclk(cfg_clk), .awaddr(awaddr_l), .awvalid(awvalid_l), .awready(awready_l), .wdata(wdata_l), .wstrb(wstrb_l),
    .wvalid(wvalid_l), .wready(wready_l), .bresp(bresp_l), .bvalid(bvalid_l), .bready(bready_l), .araddr(araddr_l),
    .arvalid(arvalid_l), .arready(arready_l), .rdata(rdata_l), .rresp(rresp_l), .rvalid(rvalid_l), .rready(rready_l));

  rtlnet_vdma_s2mm #(
    .ADDR_W(ADDR_W), .ID_W(1), .MAX_BURST_BEATS(MAXB), .FIFO_KB(`TB_FKB)
  ) dut (
    .clk(clk), .resetn(resetn), .s_axi_aclk(cfg_clk), .s_axi_aresetn(cfg_resetn),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
    .s_axis_tuser(s_tuser), .s_width(s_width), .s_height(s_height), .s_frame_num(s_frame), .s_timestamp(s_ts),
    .s_src_pattern(s_src),
    .fb_req(fb_req), .fb_rsp_valid(fb_rsp_valid), .fb_rsp_ok(fb_rsp_ok), .fb_rsp_base(fb_rsp_base),
    .fb_done(fb_done), .fb_done_good(fb_done_good), .fb_done_frame_num(fb_done_frame), .fb_done_timestamp(fb_done_ts),
    .fb_done_width(fb_done_w), .fb_done_height(fb_done_h), .fb_done_src_pattern(fb_done_src),
    .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid), .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp_dut), .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    .s_axi_awaddr(awaddr_l), .s_axi_awvalid(awvalid_l), .s_axi_awready(awready_l), .s_axi_wdata(wdata_l),
    .s_axi_wstrb(wstrb_l), .s_axi_wvalid(wvalid_l), .s_axi_wready(wready_l), .s_axi_bresp(bresp_l),
    .s_axi_bvalid(bvalid_l), .s_axi_bready(bready_l), .s_axi_araddr(araddr_l), .s_axi_arvalid(arvalid_l),
    .s_axi_arready(arready_l), .s_axi_rdata(rdata_l), .s_axi_rresp(rresp_l), .s_axi_rvalid(rvalid_l),
    .s_axi_rready(rready_l));

  rtlnet_tb_axi4_mem #(
    .ADDR_W(ADDR_W), .DATA_W(128), .ID_W(1), .READ_LATENCY(0),
    .AW_READY_PCT(GAP ? 55 : 100), .W_READY_PCT(GAP ? 60 : 100), .AR_READY_PCT(100),
    .B_VALID_PCT(GAP ? 50 : 100), .R_VALID_PCT(100), .SEED(7)
  ) u_mem (
    .clk(clk), .resetn(resetn),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid),
    .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp_mem), .bvalid(bvalid), .bready(bready),
    .arid(1'b0), .araddr('0), .arlen(8'd0), .arsize(3'd4), .arburst(2'b01), .arvalid(1'b0), .arready(),
    .rid(), .rdata(), .rresp(), .rlast(), .rvalid(), .rready(1'b1));

  // ---------------------------------------------------------------------------
  // Random numbers
  // ---------------------------------------------------------------------------
  int unsigned rng = 32'hC0FF_EE11;

  function automatic int rnd(input int n);
    rng = rng * 32'd1103515245 + 32'd12345;
    return int'((rng >> 8) % n);
  endfunction

  // Stream word of (frame, line, word): a hash, so a misplaced word shows.
  function automatic logic [31:0] pix(input int frame, input int line, input int word);
    logic [31:0] h;
    h = 32'(frame) * 32'h9E37_79B1 + 32'(line) * 32'h85EB_CA6B + 32'(word) * 32'hC2B2_AE35 + 32'h1357_9BDF;
    h = h ^ (h >> 15);
    h = h * 32'h2C1B_3C6D;
    h = h ^ (h >> 13);
    return h;
  endfunction

  // ---------------------------------------------------------------------------
  // Frame-buffer stub: answers a request after a few clocks with the next configured answer.
  // ---------------------------------------------------------------------------
  logic [ADDR_W-1:0] stub_base = '0;
  bit                stub_ok = 1'b1;
  int                stub_requests = 0;

  // Expected bursts of the frame granted last (independent splitter), consumed by the AW monitor.
  int                exp_aw_addr [$];
  int                exp_aw_len  [$];
  int                exp_w_beats = 0;
  int                cur_stride_eff = 0;
  int                cur_bpl = 0;
  int                cur_h = 0;
  int                bursts_total = 0;
  int                beats_total = 0;
  bit                stub_arm = 1'b0;

  task automatic gen_bursts(input int base, input int stride, input int bpl, input int h);
    for (int line = 0; line < h; line++) begin
      int a;
      int left;
      a = base + line * stride;
      left = bpl;
      while (left > 0) begin
        int to_page;
        int len;
        to_page = (4096 - (a % 4096)) / 16;
        len = MAXB;
        if (left < len) len = left;
        if (to_page < len) len = to_page;
        exp_aw_addr.push_back(a);
        exp_aw_len.push_back(len);
        a += len * 16;
        left -= len;
      end
    end
  endtask

  always @(posedge clk) begin
    if (resetn === 1'b1) begin
      fb_rsp_valid <= 1'b0;
      if (fb_req && stub_arm) begin
        stub_arm <= 1'b0;
        stub_requests++;
        repeat (1 + rnd(4)) @(posedge clk);
        fb_rsp_valid <= 1'b1;
        fb_rsp_ok    <= stub_ok;
        fb_rsp_base  <= stub_base;
        @(posedge clk);
        fb_rsp_valid <= 1'b0;
      end
    end
  end

  // AW monitor: every burst equals the splitter's next one; legality.
  int aw_seen = 0;
  always @(posedge clk) begin
    if (resetn === 1'b1 && awvalid && awready) begin
      aw_seen++;
      tb_check(exp_aw_addr.size() > 0, "AW with no burst expected");
      if (exp_aw_addr.size() > 0) begin
        int ea;
        int el;
        ea = exp_aw_addr.pop_front();
        el = exp_aw_len.pop_front();
        tb_check(int'(awaddr) == ea, $sformatf("AW addr 0x%0h, expected 0x%0h", awaddr, ea));
        tb_check(int'(awlen) + 1 == el, $sformatf("AW beats %0d, expected %0d (addr 0x%0h)", int'(awlen) + 1, el, awaddr));
      end
      tb_check(int'(awlen) + 1 <= 16 && int'(awlen) + 1 <= MAXB, "burst longer than the maximum");
      tb_check(awsize == 3'd4 && awburst == 2'b01 && awid == 1'b0, "AW size, burst type or ID");
      tb_check(((int'(awaddr) % 4096) + (int'(awlen) + 1) * 16) <= 4096, "burst crosses 4 KiB");
    end
  end

  // fb_done monitor.
  int  done_count = 0;
  int  done_good_count = 0;
  bit  last_done_good = 1'b0;
  int  last_done_frame = 0;
  int  last_done_w = 0;
  int  last_done_h = 0;
  bit  last_done_src = 1'b0;
  int  last_done_ts = 0;
  always @(posedge clk) begin
    if (resetn === 1'b1 && fb_done) begin
      done_count++;
      last_done_good  = fb_done_good;
      last_done_frame = int'(fb_done_frame);
      last_done_w     = int'(fb_done_w);
      last_done_h     = int'(fb_done_h);
      last_done_src   = fb_done_src;
      last_done_ts    = int'(fb_done_ts);
      if (fb_done_good) done_good_count++;
    end
  end

  // ---------------------------------------------------------------------------
  // Stream driver
  // ---------------------------------------------------------------------------
  // lines_sent: lines actually sent (less than h = a cut-off frame); tmode: 0 normal, 1 no tlast on line 1, 2 an early tlast
  // at word 3 of line 1 and none at its end. frame_id seeds the pixel words.
  task automatic send_words(input int frame_id, input int w_px, input int h, input int lines_sent, input int tmode);
    int wpl;
    wpl = w_px / 2;
    for (int line = 0; line < lines_sent; line++) begin
      for (int word = 0; word < wpl; word++) begin
        bit last;
        last = (word == wpl - 1);
        if (tmode == 1 && line == 1) last = 1'b0;
        if (tmode == 2 && line == 1) last = (word == 3);
        if (GAP != 0) begin
          if (rnd(100) < 30) begin
            s_tvalid <= 1'b0;
            repeat (1 + rnd(4)) @(posedge clk);
          end
        end
        s_tdata  <= pix(frame_id, line, word);
        s_tvalid <= 1'b1;
        s_tlast  <= last;
        s_tuser  <= (line == 0 && word == 0);
        @(posedge clk);
        while (!s_tready) @(posedge clk);
      end
    end
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;
    s_tuser  <= 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Register access
  // ---------------------------------------------------------------------------
  logic [1:0]  rd_resp;
  logic [1:0]  wr_resp;

  task automatic reg_read(input logic [11:0] a, output logic [31:0] v);
    u_mst.read32(a, v, rd_resp);
    tb_check(rd_resp == 2'b00, $sformatf("register read 0x%0h response %0d", a, rd_resp));
  endtask

  task automatic reg_write(input logic [11:0] a, input logic [31:0] v);
    u_mst.write32(a, v, 4'hF, wr_resp);
    tb_check(wr_resp == 2'b00, $sformatf("register write 0x%0h response %0d", a, wr_resp));
  endtask

  localparam logic [11:0] R_ID      = 12'h000;
  localparam logic [11:0] R_CAPS    = 12'h008;
  localparam logic [11:0] R_CTRL    = 12'h00C;
  localparam logic [11:0] R_STATUS  = 12'h010;
  localparam logic [11:0] R_STRIDE  = 12'h014;
  localparam logic [11:0] R_OK      = 12'h018;
  localparam logic [11:0] R_BAD     = 12'h01C;
  localparam logic [11:0] R_DROP    = 12'h020;
  localparam logic [11:0] R_BURSTS  = 12'h024;
  localparam logic [11:0] R_BEATS   = 12'h028;
  localparam logic [11:0] R_LAST    = 12'h02C;

  // ---------------------------------------------------------------------------
  // Frame scenarios
  // ---------------------------------------------------------------------------
  int frame_ctr   = 0;
  int exp_ok      = 0;
  int exp_bad     = 0;
  int exp_drop    = 0;
  int exp_cfg_err = 0;
  int exp_line_err = 0;
  int exp_axi_err = 0;
  int last_base_exp = 0;

  // Run one frame through the DUT. wants: 0 = write expected, 1 = dropped by geometry, 2 = dropped by the frame buffer,
  // 3 = dropped because disabled. good_exp: the frame must be reported good (only for wants 0).
  // valid_lines: lines of real data expected in memory (the rest zero); 0 for a dropped frame.
  task automatic run_frame(input int base, input int w_px, input int h, input int stride_reg, input int lines_sent,
                           input int tmode, input int wants, input bit good_exp, input int valid_lines, input bit src);
    int stride_eff;
    int bpl;
    int expected_words;
    int done_before;
    int t;
    bit cfg_ok;
    int id;
    frame_ctr++;
    id = frame_ctr;
    bpl = w_px / 8;
    stride_eff = (stride_reg == 0) ? w_px * 2 : stride_reg;
    done_before = done_count;
    u_mem.clear_memory();
    reg_write(R_STRIDE, 32'(stride_reg));
    s_width  <= 16'(w_px);
    s_height <= 16'(h);
    s_frame  <= 32'(id);
    s_ts     <= 32'(id * 1000 + 17);
    s_src    <= src;
    stub_base <= ADDR_W'(base);
    stub_ok   <= (wants != 2);
    stub_arm  <= 1'b1;
    exp_aw_addr.delete();
    exp_aw_len.delete();
    if (wants == 0) gen_bursts(base, stride_eff, bpl, h);
    @(posedge clk);
    send_words(id, w_px, h, lines_sent, tmode);
    if (wants == 0) begin
      // Wait for the frame to be reported.
      t = 0;
      if (lines_sent < h) begin
        // Cut-off: the next frame's first word completes it; a short follow-up frame is sent by the caller.
      end else begin
        while (done_count == done_before && t < 3_000_000) begin @(posedge clk); t++; end
        tb_check(done_count == done_before + 1, $sformatf("frame %0d (id) was not reported done", id));
        tb_check(last_done_good == good_exp, $sformatf("frame %0d done good=%0d, expected %0d", id, last_done_good, good_exp));
        tb_check(last_done_frame == id && last_done_w == w_px && last_done_h == h && last_done_src == src &&
                 last_done_ts == id * 1000 + 17, "fb_done sideband");
      end
    end else begin
      repeat (60) @(posedge clk);
      tb_check(done_count == done_before, $sformatf("a dropped frame (%0d) was reported done", id));
      tb_check(aw_seen == aw_prev, "a dropped frame wrote to memory");
    end
    if (wants == 0 && lines_sent == h) begin
      // Memory content: valid lines equal the stream, the rest zero, no other word written.
      int bad_cnt;
      bad_cnt = 0;
      for (int line = 0; line < h; line++) begin
        for (int beat = 0; beat < bpl; beat++) begin
          logic [127:0] e;
          logic [127:0] g;
          e = '0;
          if (line < valid_lines) begin
            for (int k = 0; k < 4; k++) e[k*32 +: 32] = pix(id, line, beat * 4 + k);
          end
          g = u_mem.peek(ADDR_W'(base + line * stride_eff + beat * 16));
          if (g !== e) begin
            bad_cnt++;
            if (bad_cnt < 4) tb_check(1'b0, $sformatf("frame %0d line %0d beat %0d: memory 0x%0h, expected 0x%0h", id, line, beat, g, e));
          end
        end
      end
      tb_check(bad_cnt == 0, $sformatf("frame %0d: %0d wrong beats", id, bad_cnt));
      tb_check(u_mem.mem.num() == h * bpl, $sformatf("frame %0d wrote %0d words, expected %0d", id, u_mem.mem.num(), h * bpl));
      tb_check(exp_aw_addr.size() == 0, $sformatf("frame %0d: %0d bursts never issued", id, exp_aw_addr.size()));
    end
    aw_prev = aw_seen;
  endtask

  int aw_prev = 0;

  initial begin
    logic [31:0] v;
    int bursts_before;
    wait (resetn === 1'b1 && cfg_resetn === 1'b1);
    repeat (10) @(posedge clk);
    // Header.
    reg_read(R_ID, v);   tb_check(v == 32'h5332_4D4D, "ID is S2MM");
    reg_read(R_CAPS, v); tb_check(v == {8'd0, 8'(ADDR_W), 8'd16, 8'(MAXB)}, $sformatf("CAPS 0x%0h", v));
    reg_read(R_CTRL, v); tb_check(v == 32'd1, "ENABLE resets to 1");

    // 1. Packed.
    run_frame(32'h0010_0000, 64, 4, 0, 4, 0, 0, 1'b1, 4, 1'b1);
    exp_ok++;
    // 2. Stride.
    run_frame(32'h0020_0000, 256, 8, 1024, 8, 0, 0, 1'b1, 8, 1'b0);
    exp_ok++;
    run_frame(32'h0030_0000, 8, 20, 16, 20, 0, 0, 1'b1, 20, 1'b1);
    exp_ok++;
    // 3. The 4 KiB rule.
    run_frame(32'h0040_0F80, 512, 6, 1040, 6, 0, 0, 1'b1, 6, 1'b0);
    exp_ok++;
    run_frame(32'h0050_0F00, 1024, 3, 0, 3, 0, 0, 1'b1, 3, 1'b1);
    exp_ok++;
    // 4. Geometry errors.
    run_frame(32'h0060_0000, 12, 4, 0, 4, 0, 1, 1'b0, 0, 1'b0);   exp_drop++; exp_cfg_err++;
    run_frame(32'h0060_0000, 64, 4, 8, 4, 0, 1, 1'b0, 0, 1'b0);   exp_drop++; exp_cfg_err++;   // stride below the line bytes
    run_frame(32'h0060_0000, 64, 4, 136, 4, 0, 1, 1'b0, 0, 1'b0); exp_drop++; exp_cfg_err++;   // stride not a multiple of 16
    run_frame(32'h0060_0000, 64, 0, 0, 1, 0, 1, 1'b0, 0, 1'b0);   exp_drop++; exp_cfg_err++;   // height 0
    run_frame(32'h0070_0000, 64, 2, 0, 2, 0, 0, 1'b1, 2, 1'b1);   exp_ok++;                    // normal again
    // 5. No slot.
    run_frame(32'h0080_0000, 64, 4, 0, 4, 0, 2, 1'b0, 0, 1'b0);   exp_drop++;
    run_frame(32'h0090_0000, 64, 4, 0, 4, 0, 0, 1'b1, 4, 1'b0);   exp_ok++;
    // 6. Disabled.
    reg_write(R_CTRL, 32'd0);
    run_frame(32'h00A0_0000, 64, 4, 0, 4, 0, 3, 1'b0, 0, 1'b0);   exp_drop++;
    reg_write(R_CTRL, 32'd1);
    run_frame(32'h00B0_0000, 64, 4, 0, 4, 0, 0, 1'b1, 4, 1'b1);   exp_ok++;
    // 7. Line errors.
    run_frame(32'h00C0_0000, 64, 4, 0, 4, 1, 0, 1'b0, 4, 1'b0);   exp_bad++; exp_line_err++;
    run_frame(32'h00D0_0000, 64, 4, 0, 4, 2, 0, 1'b0, 4, 1'b1);   exp_bad++; exp_line_err++;
    // 9. Write error.
    inject_axi_err = 1'b1;
    run_frame(32'h00E0_0000, 64, 4, 0, 4, 0, 0, 1'b0, 4, 1'b0);   exp_bad++; exp_axi_err++;
    inject_axi_err = 1'b0;
    run_frame(32'h00F0_0000, 64, 4, 0, 4, 0, 0, 1'b1, 4, 1'b0);   exp_ok++;

    // 8. Cut-off frame: 3 of 8 lines, then a normal frame. The memory check of the cut-off frame is done here.
    begin
      int id_cut;
      int done_before;
      u_mem.clear_memory();
      exp_aw_addr.delete();
      exp_aw_len.delete();
      frame_ctr++;
      id_cut = frame_ctr;
      done_before = done_count;
      reg_write(R_STRIDE, 32'd0);
      s_width <= 16'd64; s_height <= 16'd8; s_frame <= 32'(id_cut); s_ts <= 32'd5; s_src <= 1'b1;
      stub_base <= 29'h0100_0000; stub_ok <= 1'b1; stub_arm <= 1'b1;
      gen_bursts(32'h0100_0000, 128, 8, 8);
      @(posedge clk);
      send_words(id_cut, 64, 8, 3, 0);
      repeat (50) @(posedge clk);
      tb_check(done_count == done_before, "a cut-off frame was reported done before its end");
      // The next frame's first word arrives: the cut-off frame is padded and reported not good.
      frame_ctr++;
      stub_base <= 29'h0110_0000; stub_ok <= 1'b1; stub_arm <= 1'b1;
      s_frame <= 32'(frame_ctr); s_ts <= 32'd6;
      gen_bursts(32'h0110_0000, 128, 8, 8);
      // Check the cut-off frame's memory when its done arrives, the new frame's words follow.
      fork
        begin
          int t;
          t = 0;
          // Words of the new frame start now; they wait until the padded frame completes.
          send_words(frame_ctr, 64, 8, 8, 0);
        end
        begin
          int t2;
          t2 = 0;
          while (done_count == done_before && t2 < 200000) begin @(posedge clk); t2++; end
          tb_check(done_count == done_before + 1, "the cut-off frame was not reported done");
          tb_check(!last_done_good, "a cut-off frame was reported good");
          tb_check(last_done_frame == id_cut, "cut-off frame sideband");
          for (int line = 0; line < 8; line++) begin
            for (int beat = 0; beat < 8; beat++) begin
              logic [127:0] e;
              logic [127:0] g;
              e = '0;
              if (line < 3) begin
                for (int k = 0; k < 4; k++) e[k*32 +: 32] = pix(id_cut, line, beat * 4 + k);
              end
              g = u_mem.peek(29'(32'h0100_0000 + line * 128 + beat * 16));
              tb_check(g === e, $sformatf("cut-off frame line %0d beat %0d: 0x%0h, expected 0x%0h", line, beat, g, e));
            end
          end
        end
      join
      exp_bad++; exp_line_err++;
      // The follow-up frame completes normally and good.
      begin
        int t3;
        t3 = 0;
        while (done_count == done_before + 1 && t3 < 200000) begin @(posedge clk); t3++; end
        tb_check(done_count == done_before + 2, "the frame after a cut-off frame was not reported");
        tb_check(last_done_good, "the frame after a cut-off frame was not good");
        exp_ok++;
      end
    end

    // Optional full-size frames (real 720p and 1080p geometry, packed).
    if (`TB_FULL) begin
      run_frame(32'h0200_0000, 1280, 720, 0, 720, 0, 0, 1'b1, 720, 1'b1);   exp_ok++;
      run_frame(32'h0240_0000, 1920, 1080, 0, 1080, 0, 0, 1'b1, 1080, 1'b1); exp_ok++;
    end

    // 10. Registers.
    repeat (50) @(posedge clk);
    reg_read(R_OK, v);   tb_check(int'(v) == exp_ok,   $sformatf("FRAMES_OK %0d, expected %0d", v, exp_ok));
    reg_read(R_BAD, v);  tb_check(int'(v) == exp_bad,  $sformatf("FRAMES_BAD %0d, expected %0d", v, exp_bad));
    reg_read(R_DROP, v); tb_check(int'(v) == exp_drop, $sformatf("FRAMES_DROPPED %0d, expected %0d", v, exp_drop));
    reg_read(R_BURSTS, v); tb_check(int'(v) == u_mem.aw_count, $sformatf("BURSTS %0d, memory model %0d", v, u_mem.aw_count));
    reg_read(R_BEATS, v);  tb_check(int'(v) == u_mem.w_beats, $sformatf("BEATS %0d, memory model %0d", v, u_mem.w_beats));
    reg_read(R_STATUS, v);
    tb_check(v[1] == 1'b1 && v[2] == 1'b1 && v[3] == 1'b1, $sformatf("STATUS 0x%0h: CFG_ERR, AXI_ERR and LINE_ERR expected set", v));
    tb_check(v[0] == 1'b0, "STATUS.BUSY while idle");
    reg_write(R_STATUS, 32'h0000_000E);
    reg_read(R_STATUS, v);
    tb_check(v[3:1] == 3'b000, "STATUS error flags did not clear");
    reg_read(R_LAST, v);
    tb_check(v != 32'd0, "LAST_BASE is 0");
    reg_write(R_STRIDE, 32'd2048);
    reg_read(R_STRIDE, v); tb_check(v == 32'd2048, "STRIDE read-back");
    reg_write(R_CTRL, 32'h0001_0001);
    reg_read(R_OK, v);   tb_check(v == 32'd0, "FRAMES_OK after CNT_CLEAR");
    reg_read(R_BURSTS, v); tb_check(v == 32'd0, "BURSTS after CNT_CLEAR");
    reg_read(R_CTRL, v); tb_check(v == 32'd1, "ENABLE kept by a CNT_CLEAR write");
    // Coverage of the scenario.
    tb_check(exp_ok >= 10 && exp_bad >= 4 && exp_drop >= 6, "scenario count");
    $display("s2mm: frames ok %0d bad %0d dropped %0d, AW seen %0d", exp_ok, exp_bad, exp_drop, aw_seen);
    tb_verdict("tb_rtlnet_vdma_s2mm");
  end

  // Watchdog.
  initial begin
    #2000ms;
    tb_error("watchdog: the bench did not finish");
    tb_verdict("tb_rtlnet_vdma_s2mm");
  end

  initial begin
    repeat (8) #20;
    arstn = 1'b1;
  end

endmodule
