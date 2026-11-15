// -----------------------------------------------------------------------------
// File: tb_rtlnet_csi2_rx_camera.sv
// Purpose: full-path bench of rtlnet_csi2_rx with CAMERA_RX = 1: the bench D-PHY transmitter model sends RAW10 Bayer frames (built from a
//   known RGB image by csi2_rx_model.py) on two lanes and a clock lane; the core's YUV video stream is compared bit for bit with the model,
//   the counters and status registers are read over AXI4-Lite, and the faults of the receiver are injected and counted.
// Cases (TB_GEOM 0: frame geometry 32 x 8 and 24 x 10 pixels; TB_GEOM 1: 1280 x 4 and 1920 x 4, the real line widths):
//   1. Reset values: ID, VERSION 0x11152026, CAPS (camera bit), RX_CTRL, RX_SETTLE, RX_FILTER, WB gains 0x100, BLACK, PHASE, PROC, counters 0; the
//      writable fields read back, reserved bits read 0.
//   2. Every case of the set (small: four Bayer phases with black level, gains and gamma, the second mode, short and long lines, a frame
//      cut after three lines; wide: 1280 and 1920 pixel lines): the stream is exactly the model; start of frame on the first word only, end of
//      line every W / 2 words, H lines, the sideband (width, height, camera source) is right; the counters afterwards: frames received, no error counter,
//      frame size errors for the cases whose size differs from the mode; RX_LINES and RX_PIXELS read the last frame's measured size.
//   3. (TB_GEOM 0) Faults, each followed by a frame that must be exact (recovery) and each counted: a one-bit header error (corrected,
//      the line is used), a two-bit header error (line lost), a payload CRC error (the line is used), a missing sync byte, a packet cut after
//      four pixels, a line of another data type, a lane skew of five bytes during one line, the HS clock frozen in the middle of a
//      line (the clock-loss counter, the lines after it dropped as orphans until the next frame start, the frame closed early by the next
//      frame start), a lost frame start (the eight lines are orphans and no frame appears).
//   4. RX_CLEAR clears single counters and all counters; the soft reset bit holds the receiver in reset (no frame, no event) and releases it.
//      Every case also writes HL_LEVEL and PROC bit 2 (highlight clamp: the small set has the clipped-highlight cases) and reads RAW_MAX after
//      the frame, which equals the word of csi2_rx_<set>_max.mem (maxima of the black-level-subtracted raw values per site colour).
// Plusargs: INJECT_FAILURE (the verdict fails), MUTATE (one pixel of one line is flipped on the wire, the compare must fail),
//   MUTATE_MAX (the expected RAW_MAX word is wrong in one bit, the register check must fail).
// Defines: TB_GEOM (0 small, 1 wide), TB_DIR (folder of the .mem files relative to the simulation work directory).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-15-2026
//   * 11-15-2026: initial version; HL_LEVEL, PROC bit 2 and RAW_MAX checks.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_GEOM
  `define TB_GEOM 0
`endif
`ifndef TB_DIR
  `define TB_DIR "../../cores/rtlnet_csi2_rx/testbench"
`endif

module tb_rtlnet_csi2_rx_camera;

  import rtlnet_tb_pkg::*;
  import rtlnet_csi2_tb_pkg::*;

  localparam bit WIDE = (`TB_GEOM != 0);
  localparam string SETNAME = WIDE ? "wide" : "small";
  localparam int W0 = WIDE ? 1280 : 32;
  localparam int H0 = WIDE ? 4 : 8;
  localparam int W1 = WIDE ? 1920 : 24;
  localparam int H1 = WIDE ? 4 : 10;

  // Register offsets.
  localparam int R_ID = 'h000, R_VERSION = 'h004, R_CAPS = 'h008, R_VIDEO_MODE = 'h010, R_SOURCE = 'h014, R_STATUS = 'h020,
                 R_FRAME_COUNT = 'h024, R_RX_CTRL = 'h040, R_RX_STATUS = 'h044, R_RX_TAPS = 'h048, R_RX_SETTLE = 'h04C,
                 R_RX_FILTER = 'h050, R_RX_CLEAR = 'h054, R_RX_LINES = 'h058, R_RX_PIXELS = 'h05C, R_CNT = 'h060,
                 R_BLACK = 'h090, R_WB_R = 'h094, R_WB_G = 'h098, R_WB_B = 'h09C, R_PHASE = 'h0A0, R_PROC = 'h0A4, R_RAW_MAX = 'h0A8, R_HL_LEVEL = 'h0AC;
  localparam int C_ECC_CORR = 0, C_ECC_UNC = 1, C_CRC = 2, C_SOT = 3, C_FRAMES = 4, C_DT = 5, C_TRUNC = 6, C_OVF = 7, C_SIZE = 8,
                 C_ORPHAN = 9, C_LEN = 10, C_CLKLOSS = 11;

  // Clocks and resets.
  logic clk = 1'b0, cfg_clk = 1'b0, ref_clk = 1'b0;
  logic arstn = 1'b0;
  logic resetn, cfg_resetn;
  always #5.5  clk     = ~clk;
  always #5.1  cfg_clk = ~cfg_clk;
  always #2.5  ref_clk = ~ref_clk;
  rtlnet_reset_sync u_rst_a (.clk(clk),     .arstn(arstn), .resetn(resetn));
  rtlnet_reset_sync u_rst_b (.clk(cfg_clk), .arstn(arstn), .resetn(cfg_resetn));

  // Pins from the transmitter model.
  logic clk_p, clk_n;
  logic [1:0] dat_p, dat_n, lp_clk, lp_d0, lp_d1;
  rtlnet_csi2_tb_phy tx (.clk_p(clk_p), .clk_n(clk_n), .dat_p(dat_p), .dat_n(dat_n), .lp_clk(lp_clk), .lp_d0(lp_d0), .lp_d1(lp_d1));

  // Output stream and AXI4-Lite.
  logic [31:0] m_tdata;
  logic        m_tvalid, m_tready = 1'b1, m_tlast, m_tuser;
  logic [31:0] m_frame, m_ts;
  logic [15:0] m_w, m_h;
  logic        m_src;
  logic [11:0] awaddr, araddr;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic        cam_tready_nc;

  rtlnet_tb_axil_master #(.ADDR_W(12)) u_mst (
    .aclk(cfg_clk), .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
    .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready), .araddr(araddr),
    .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready));

  rtlnet_csi2_rx #(
    .CAMERA_RX(1'b1), .DPHY_TARGET("GENERIC"), .HS_DIFF_TERM(1'b0), .FIFO_KB(4), .LINE_KB(8),
    .WIDTH_720(W0), .HEIGHT_720(H0), .WIDTH_1080(W1), .HEIGHT_1080(H1)
  ) dut (
    .clk(clk), .resetn(resetn), .s_axi_aclk(cfg_clk), .s_axi_aresetn(cfg_resetn),
    .s_cam_tdata(32'd0), .s_cam_tvalid(1'b0), .s_cam_tready(cam_tready_nc), .s_cam_tlast(1'b0), .s_cam_tuser(1'b0), .cam_clk_running(1'b0),
    .ref_clk(ref_clk), .dphy_clk_p(clk_p), .dphy_clk_n(clk_n), .dphy_clk_lp_p(lp_clk[1]), .dphy_clk_lp_n(lp_clk[0]),
    .dphy_dat_p(dat_p), .dphy_dat_n(dat_n), .dphy_dat_lp_p({lp_d1[1], lp_d0[1]}), .dphy_dat_lp_n({lp_d1[0], lp_d0[0]}),
    .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
    .m_frame_num(m_frame), .m_timestamp(m_ts), .m_width(m_w), .m_height(m_h), .m_src_pattern(m_src),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
    .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
    .s_axi_rvalid(rvalid), .s_axi_rready(rready));

  // Case memories: set A (small or wide), set B (fault, geometry 0 only).
  logic [31:0] cfgA [0:1023];
  logic [9:0]  rawA [0:16383];
  logic [31:0] expA [0:8191];
  logic [31:0] maxA [0:255];
  bit mutate_max = 1'b0;
  logic [31:0] cfgB [0:1023];
  logic [9:0]  rawB [0:4095];
  logic [31:0] expB [0:4095];

  bit mutate = 1'b0;

  // Register access.
  task automatic wr(input int addr, input logic [31:0] d);
    logic [1:0] r;
    u_mst.write32(12'(addr), d, 4'hF, r);
    tb_check(r == 2'b00, $sformatf("write 0x%03x response %0d", addr, r));
  endtask

  task automatic rd(input int addr, output logic [31:0] d);
    logic [1:0] r;
    u_mst.read32(12'(addr), d, r);
    tb_check(r == 2'b00, $sformatf("read 0x%03x response %0d", addr, r));
  endtask

  task automatic expect_reg(input int addr, input logic [31:0] e, input string tag);
    logic [31:0] d;
    rd(addr, d);
    tb_check(d === e, $sformatf("%s: register 0x%03x = %08x, expected %08x", tag, addr, d, e));
  endtask

  task automatic expect_cnt(input int idx, input int e, input string tag);
    logic [31:0] d;
    rd(R_CNT + 4 * idx, d);
    tb_check(d == e, $sformatf("%s: counter %0d = %0d, expected %0d", tag, idx, d, e));
  endtask

  // Output monitor with a queue of expected frames: {array 0 A, 1 B, offset, W, H}.
  int q_set [$];
  int q_off [$];
  int q_w   [$];
  int q_h   [$];
  int frames_out = 0;
  int cur_set = 0, cur_off = 0, cur_w = 0, cur_h = 0, cur_idx = 0, cur_line = 0, cur_col = 0;
  bit in_frame = 1'b0;
  int word_errs = 0;
  int words_total = 0;
  bit src_ok = 1'b1;

  always @(posedge clk) begin
    if (resetn && m_tvalid && m_tready) begin
      words_total++;
      if (m_tuser) begin
        tb_check(!in_frame, "frame start before the previous frame finished");
        tb_check(q_off.size() > 0, "output frame without an expected frame");
        if (q_off.size() > 0) begin
          cur_set = q_set.pop_front(); cur_off = q_off.pop_front(); cur_w = q_w.pop_front(); cur_h = q_h.pop_front();
        end
        in_frame = 1'b1; cur_idx = 0; cur_line = 0; cur_col = 0;
        tb_check(m_src == 1'b0, "camera frame flagged as pattern");
        tb_check(int'(m_w) == cur_w && int'(m_h) == cur_h, $sformatf("sideband %0dx%0d, expected %0dx%0d", m_w, m_h, cur_w, cur_h));
      end else begin
        tb_check(in_frame, "word outside a frame");
      end
      if (in_frame) begin
        logic [31:0] e;
        e = (cur_set == 0) ? expA[cur_off + cur_idx] : expB[cur_off + cur_idx];
        if (m_tdata !== e) begin
          word_errs++;
          if (word_errs <= 5)
            $display("WORD MISMATCH frame %0d word %0d (line %0d col %0d): got %08x expected %08x", frames_out, cur_idx, cur_line, cur_col, m_tdata, e);
        end
        tb_check(m_tuser == (cur_idx == 0), "tuser only on the first word");
        tb_check(m_tlast == (cur_col == cur_w / 2 - 1), "tlast on the last word of every line");
        cur_idx++;
        if (cur_col == cur_w / 2 - 1) begin cur_col = 0; cur_line++; end else cur_col++;
        if (cur_line == cur_h) begin in_frame = 1'b0; frames_out++; end
      end
    end
  end

  task automatic wait_frames(input int n, input int timeout_clks);
    int t;
    t = 0;
    while (frames_out < n && t < timeout_clks) begin @(posedge clk); t++; end
    tb_check(frames_out >= n, $sformatf("frames out %0d, expected %0d (timeout)", frames_out, n));
  endtask

  // Configure the Bayer processing and the mode from a case table row.
  task automatic apply_case(input int set, input int base);
    logic [31:0] c [16];
    for (int i = 0; i < 16; i++) c[i] = (set == 0) ? cfgA[base + i] : cfgB[base + i];
    wr(R_VIDEO_MODE, c[4]);
    wr(R_PHASE, c[5]);
    wr(R_BLACK, c[6]);
    wr(R_WB_R, c[7]);
    wr(R_WB_G, c[8]);
    wr(R_WB_B, c[9]);
    wr(R_HL_LEVEL, c[15]);
    wr(R_PROC, c[10]);
  endtask

  function automatic pix_q_t line_pixels(input int set, input int roff, input int iw, input int y, input int npx);
    pix_q_t px;
    for (int x = 0; x < npx; x++) px.push_back((set == 0) ? rawA[roff + y * iw + x] : rawB[roff + y * iw + x]);
    return px;
  endfunction

  // Fault kinds of one line.
  localparam int F_NONE = 0, F_ECC1 = 1, F_ECC2 = 2, F_CRC = 3, F_NOSYNC = 4, F_CUT = 5, F_DT = 6, F_SKEW = 7, F_FREEZE = 8;

  // Send one frame: frame start (unless nofs), lines 0..nlines-1 of the case, frame end (unless nofe); fault on line fline.
  task automatic send_frame(input int set, input int base, input int nlines, input int fault, input int fline, input bit nofs, input bit nofe);
    int iw, ih, roff;
    bytes_t pkt;
    pix_q_t px;
    iw = int'((set == 0) ? cfgA[base + 0] : cfgB[base + 0]);
    ih = int'((set == 0) ? cfgA[base + 1] : cfgB[base + 1]);
    roff = int'((set == 0) ? cfgA[base + 11] : cfgB[base + 11]);
    if (!nofs) tx.send_packet(short_pkt(2'd0, 6'h00, 16'd1));
    for (int y = 0; y < nlines; y++) begin
      px  = line_pixels(set, roff, iw, y, iw);
      if (mutate && y == 1) px[2] = px[2] ^ 10'h020;
      pkt = long_pkt(2'd0, 6'h2B, raw10_payload(px));
      if (y == fline) begin
        case (fault)
          F_ECC1: begin
            pkt = flip_bit(pkt, 13);
            tx.send_packet(pkt);
          end
          F_ECC2: begin
            pkt = flip_bit(flip_bit(pkt, 3), 21);
            tx.send_packet(pkt);
          end
          F_CRC: begin
            pkt = long_pkt(2'd0, 6'h2B, raw10_payload(px), 5);
            tx.send_packet(pkt);
          end
          F_NOSYNC: begin
            tx.omit_sync[0] = 1'b1; tx.omit_sync[1] = 1'b1;
            tx.send_packet(pkt);
            tx.omit_sync[0] = 1'b0; tx.omit_sync[1] = 1'b0;
          end
          F_CUT: begin
            bytes_t cutp;
            // The header and four pixels (five payload bytes): nine bytes.
            for (int i = 0; i < 9; i++) cutp.push_back(pkt[i]);
            tx.send_packet(cutp);
          end
          F_DT: begin
            pkt = long_pkt(2'd0, 6'h2A, raw10_payload(px));
            tx.send_packet(pkt);
          end
          F_SKEW: begin
            tx.skew_ui[1] = 40.0;
            tx.send_packet(pkt);
            tx.skew_ui[1] = 0.0;
          end
          F_FREEZE: begin
            fork
              tx.send_packet(pkt);
              begin
                #450;
                tx.freeze_clock(900.0);
              end
            join
          end
          default: tx.send_packet(pkt);
        endcase
      end else begin
        tx.send_packet(pkt);
      end
    end
    if (!nofe) tx.send_packet(short_pkt(2'd0, 6'h01, 16'd1));
  endtask

  int sent_frames = 0;
  int exp_size = 0;

  task automatic queue_frame(input int set, input int off, input int w, input int h);
    q_set.push_back(set); q_off.push_back(off); q_w.push_back(w); q_h.push_back(h);
  endtask

  initial begin
    logic [31:0] d;
    int base, W, H, iw, ih, kind, kline, roff, eoff, nlines;
    int ncA, ncB;
    mutate = $test$plusargs("MUTATE");
    mutate_max = $test$plusargs("MUTATE_MAX");
    $readmemh($sformatf("%s/csi2_rx_%s_cfg.mem", `TB_DIR, SETNAME), cfgA);
    $readmemh($sformatf("%s/csi2_rx_%s_raw.mem", `TB_DIR, SETNAME), rawA);
    $readmemh($sformatf("%s/csi2_rx_%s_exp.mem", `TB_DIR, SETNAME), expA);
    $readmemh($sformatf("%s/csi2_rx_%s_max.mem", `TB_DIR, SETNAME), maxA);
    if (!WIDE) begin
      $readmemh($sformatf("%s/csi2_rx_fault_cfg.mem", `TB_DIR), cfgB);
      $readmemh($sformatf("%s/csi2_rx_fault_raw.mem", `TB_DIR), rawB);
      $readmemh($sformatf("%s/csi2_rx_fault_exp.mem", `TB_DIR), expB);
    end
    ncA = int'(cfgA[0]);
    ncB = int'(cfgB[0]);
    repeat (10) @(posedge cfg_clk);
    arstn = 1'b1;
    repeat (400) @(posedge cfg_clk);

    // 1. Reset values and register behaviour.
    expect_reg(R_ID, 32'h43534932, "reset");
    expect_reg(R_VERSION, 32'h11152026, "reset");
    expect_reg(R_CAPS, 32'h00000072, "reset");
    expect_reg(R_RX_CTRL, 32'h0000000D, "reset");
    expect_reg(R_RX_SETTLE, 32'h0000001C, "reset");
    expect_reg(R_RX_FILTER, 32'h00002B00, "reset");
    expect_reg(R_RX_TAPS, 32'h0, "reset");
    expect_reg(R_WB_R, 32'h100, "reset");
    expect_reg(R_WB_G, 32'h100, "reset");
    expect_reg(R_WB_B, 32'h100, "reset");
    expect_reg(R_BLACK, 32'h0, "reset");
    expect_reg(R_PHASE, 32'h0, "reset");
    expect_reg(R_PROC, 32'h0, "reset");
    expect_reg(R_RAW_MAX, 32'h0, "reset");
    expect_reg(R_HL_LEVEL, 32'h0, "reset");
    for (int i = 0; i < 12; i++) expect_cnt(i, 0, "reset");
    rd(R_RX_STATUS, d);
    tb_check(d[0] === 1'b1, "RX_STATUS: HS clock not running");
    tb_check(d[2:1] === 2'b00, "RX_STATUS: lane in a burst while idle");
    tb_check(d[11:8] === 4'b1111, "RX_STATUS: LP state of lane 0 is not stop");
    tb_check(d[11:10] === 2'b11, "RX_STATUS: LP state of lane 1 is not stop");
    wr(R_RX_TAPS, 32'hFFFF_FFFF);
    expect_reg(R_RX_TAPS, 32'h0000_1F1F, "taps mask");
    wr(R_RX_TAPS, 32'h0);
    wr(R_RX_FILTER, 32'hFFFF_FFFF);
    expect_reg(R_RX_FILTER, 32'h0000_3F03, "filter mask");
    wr(R_RX_FILTER, 32'h0000_2B00);
    wr(R_PHASE, 32'hFFFF_FFFF);
    expect_reg(R_PHASE, 32'h3, "phase mask");
    wr(R_PROC, 32'hFFFF_FFFF);
    expect_reg(R_PROC, 32'h7, "proc mask (gamma, green equalisation, highlight clamp)");
    wr(R_PROC, 32'h4);
    expect_reg(R_PROC, 32'h4, "proc highlight clamp alone");
    wr(R_HL_LEVEL, 32'hFFFF_FFFF);
    expect_reg(R_HL_LEVEL, 32'h3FF, "hl level mask");
    wr(R_HL_LEVEL, 32'h2B5);
    expect_reg(R_HL_LEVEL, 32'h2B5, "hl level write");
    wr(R_RAW_MAX, 32'hFFFF_FFFF);
    expect_reg(R_RAW_MAX, 32'h0, "raw max is read only");
    wr(R_HL_LEVEL, 32'h0);
    wr(R_PROC, 32'h2);
    expect_reg(R_PROC, 32'h2, "proc green equalisation alone");
    wr(R_PROC, 32'h0);
    wr(R_BLACK, 32'hFFFF_FFFF);
    expect_reg(R_BLACK, 32'h3FF, "black mask");
    wr(R_WB_G, 32'hFFFF_FFFF);
    expect_reg(R_WB_G, 32'hFFF, "gain mask");
    wr(R_PHASE, 0); wr(R_BLACK, 0); wr(R_WB_G, 32'h100);
    wr(R_SOURCE, 32'd1);   // camera only

    // 2. The case set.
    for (int pass = 0; pass < 1; pass++) begin
      for (int ci = 0; ci < ncA; ci++) begin
        base = 1 + ci * 16;
        iw = int'(cfgA[base + 0]); ih = int'(cfgA[base + 1]); W = int'(cfgA[base + 2]); H = int'(cfgA[base + 3]);
        roff = int'(cfgA[base + 11]); eoff = int'(cfgA[base + 12]); kind = int'(cfgA[base + 13]); kline = int'(cfgA[base + 14]);
        apply_case(0, base);
        nlines = (kind == 3) ? kline : ih;
        queue_frame(0, eoff, W, H);
        if (iw != W || ih != H || kind != 0) exp_size++;
        send_frame(0, base, nlines, F_NONE, -1, 1'b0, 1'b0);
        sent_frames++;
        wait_frames(sent_frames, 400_000);
        repeat (200) @(posedge clk);
        expect_reg(R_RX_PIXELS, iw, $sformatf("case %0d RX_PIXELS", ci));
        expect_reg(R_RX_LINES, nlines, $sformatf("case %0d RX_LINES", ci));
        expect_reg(R_RAW_MAX, mutate_max ? (maxA[ci] ^ 32'h1) : maxA[ci], $sformatf("case %0d RAW_MAX", ci));
        expect_reg(R_FRAME_COUNT, sent_frames, $sformatf("case %0d FRAME_COUNT", ci));
      end
    end
    expect_cnt(C_FRAMES, sent_frames, "frames");
    expect_cnt(C_SIZE, exp_size, "size errors");
    for (int i = 0; i < 12; i++) begin
      if (i != C_FRAMES && i != C_SIZE) expect_cnt(i, 0, "clean run");
    end
    tb_check(word_errs == 0, $sformatf("%0d word mismatches in the case set", word_errs));

    if (!WIDE) begin
      // 3. Faults on the exact frame of the fault set: case 3 (exact_f), expected words of the fault cases 0 (lost line 3), 1 (line 5 with
      // four pixels), 3 (exact), 4 (cut after three lines).
      base = 1 + 3 * 16;
      apply_case(1, base);
      wr(R_RX_CLEAR, 32'h8000_0000);
      begin
        int fcase [8];
        int ffault [8];
        int fline  [8];
        string fname [8];
        int cl [8];   // expected counters: [i] = counter index checked, value 1
        fname[0] = "one-bit header error";   ffault[0] = F_ECC1;   fline[0] = 3; fcase[0] = 3; cl[0] = C_ECC_CORR;
        fname[1] = "two-bit header error";   ffault[1] = F_ECC2;   fline[1] = 3; fcase[1] = 0; cl[1] = C_ECC_UNC;
        fname[2] = "payload CRC error";      ffault[2] = F_CRC;    fline[2] = 3; fcase[2] = 3; cl[2] = C_CRC;
        fname[3] = "missing sync byte";      ffault[3] = F_NOSYNC; fline[3] = 3; fcase[3] = 0; cl[3] = C_SOT;
        fname[4] = "cut packet";             ffault[4] = F_CUT;    fline[4] = 5; fcase[4] = 1; cl[4] = C_TRUNC;
        fname[5] = "wrong data type";        ffault[5] = F_DT;     fline[5] = 3; fcase[5] = 0; cl[5] = C_DT;
        fname[6] = "lane skew of five bytes"; ffault[6] = F_SKEW;  fline[6] = 3; fcase[6] = 0; cl[6] = C_SOT;
        for (int f = 0; f < 7; f++) begin
          wr(R_RX_CLEAR, 32'h8000_0000);
          queue_frame(1, int'(cfgB[1 + fcase[f] * 16 + 12]), W0, H0);
          send_frame(1, base, 8, ffault[f], fline[f], 1'b0, 1'b0);
          sent_frames++;
          wait_frames(sent_frames, 400_000);
          repeat (200) @(posedge clk);
          for (int i = 0; i < 12; i++) begin
            int e;
            e = 0;
            if (i == cl[f]) e = 1;
            if (i == C_FRAMES) e = 1;
            if (i == C_SIZE) e = (fcase[f] == 3) ? 0 : 1;
            expect_cnt(i, e, fname[f]);
          end
          // Recovery: an exact frame.
          queue_frame(1, int'(cfgB[1 + 3 * 16 + 12]), W0, H0);
          send_frame(1, base, 8, F_NONE, -1, 1'b0, 1'b0);
          sent_frames++;
          wait_frames(sent_frames, 400_000);
          repeat (200) @(posedge clk);
          tb_check(word_errs == 0, $sformatf("%s: word mismatches in the stream (including the recovery frame)", fname[f]));
        end
      end

      // Clock freeze in the middle of line 3, then the next frame.
      wr(R_RX_CLEAR, 32'h8000_0000);
      queue_frame(1, int'(cfgB[1 + 4 * 16 + 12]), W0, H0);    // the frame cut after three lines (closed early by the next frame start)
      send_frame(1, base, 8, F_FREEZE, 3, 1'b0, 1'b0);
      repeat (400) @(posedge clk);
      queue_frame(1, int'(cfgB[1 + 3 * 16 + 12]), W0, H0);
      send_frame(1, base, 8, F_NONE, -1, 1'b0, 1'b0);
      sent_frames += 2;
      wait_frames(sent_frames, 400_000);
      repeat (200) @(posedge clk);
      expect_cnt(C_CLKLOSS, 1, "clock freeze");
      expect_cnt(C_SOT, 1, "clock freeze");
      expect_cnt(C_SIZE, 1, "clock freeze");
      expect_cnt(C_ORPHAN, 4, "clock freeze");
      expect_cnt(C_FRAMES, 2, "clock freeze");   // the frame start of the cut frame and the one of the recovery frame
      tb_check(word_errs == 0, "clock freeze: word mismatches");

      // A frame start that never arrives: the eight lines are orphans and no frame appears.
      wr(R_RX_CLEAR, 32'h8000_0000);
      send_frame(1, base, 8, F_NONE, -1, 1'b1, 1'b0);
      repeat (300) @(posedge clk);
      expect_cnt(C_ORPHAN, 8, "lost frame start");
      expect_cnt(C_FRAMES, 0, "lost frame start");
      tb_check(frames_out == sent_frames, "lost frame start: a frame appeared");
      queue_frame(1, int'(cfgB[1 + 3 * 16 + 12]), W0, H0);
      send_frame(1, base, 8, F_NONE, -1, 1'b0, 1'b0);
      sent_frames++;
      wait_frames(sent_frames, 400_000);
      tb_check(word_errs == 0, "lost frame start: recovery frame mismatches");

      // 4. Counter clears and the soft reset.
      wr(R_RX_CLEAR, 32'h8000_0000);
      expect_cnt(C_ORPHAN, 0, "clear all");
      send_frame(1, base, 8, F_NONE, -1, 1'b1, 1'b0);
      repeat (300) @(posedge clk);
      expect_cnt(C_ORPHAN, 8, "orphans again");
      expect_cnt(C_FRAMES, 0, "frames count of the orphans");
      wr(R_RX_CLEAR, 32'h1 << C_ORPHAN);
      expect_cnt(C_ORPHAN, 0, "clear one");
      wr(R_RX_CTRL, 32'h0000_000F);                 // soft reset
      repeat (200) @(posedge cfg_clk);
      begin
        int fr;
        fr = frames_out;
        send_frame(1, base, 8, F_NONE, -1, 1'b0, 1'b0);
        repeat (300) @(posedge clk);
        tb_check(frames_out == fr, "a frame came out while the receiver was in soft reset");
        expect_cnt(C_FRAMES, 0, "soft reset");
        wr(R_RX_CTRL, 32'h0000_000D);
        repeat (800) @(posedge cfg_clk);
      end
      queue_frame(1, int'(cfgB[1 + 3 * 16 + 12]), W0, H0);
      send_frame(1, base, 8, F_NONE, -1, 1'b0, 1'b0);
      sent_frames++;
      wait_frames(sent_frames, 400_000);
      tb_check(word_errs == 0, "after the soft reset: frame mismatches");
      expect_cnt(C_FRAMES, 1, "after the soft reset");
    end

    tb_verdict("tb_rtlnet_csi2_rx_camera");
  end

  initial begin
    #900ms;
    tb_error("bench timeout");
    tb_verdict("tb_rtlnet_csi2_rx_camera");
  end

endmodule
