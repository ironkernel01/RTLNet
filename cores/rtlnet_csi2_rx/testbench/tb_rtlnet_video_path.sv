// -----------------------------------------------------------------------------
// File: tb_rtlnet_video_path.sv
// Purpose: self-checking bench for the Phase 1 video path: rtlnet_csi2_rx (color bars) into rtlnet_vdma_s2mm into three
//   frame-buffer slots of rtlnet_framebuf, in DDR3 modelled by rtlnet_tb_axi4_mem, as wired in the board top.
// Cases:
//   1. Reset defaults only: the first published frame is 1280x720, source pattern, its bytes in the slot form the frame whose
//      CRC-32 (IEEE 802.3, the zlib crc32) equals TB_CRC720, the value printed by the C model
//      cores/rtlnet_csi2_rx/testbench/csi2_bars_model.c for 720p30.
//   2. VIDEO_MODE 1080p30: the next published frame is 1920x1080 and its CRC-32 equals TB_CRC1080.
//   3. Slots and order: published frame numbers increase, each published slot is read by a reader port (take, CRC, release)
//      while the writer continues; the writer never lands on the held slot (the slot bytes stay equal to the CRC while
//      held across further frames); S2MM FRAMES_OK equals the published count and no frame is bad or dropped; the AXI4
//      memory model reports no protocol or 4 KiB violation (rtlnet_tb_axi4_mem).
// Defines: TB_CRC720 and TB_CRC1080 (decimal in the regression line, the C model values; the defaults are the same values in hex).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

`ifndef TB_CRC720
  `define TB_CRC720 32'h6D3DF810
`endif
`ifndef TB_CRC1080
  `define TB_CRC1080 32'h8ED9EC2B
`endif

module tb_rtlnet_video_path;

  import rtlnet_tb_pkg::*;

  localparam int ADDR_W     = 29;
  localparam int LINE_720   = 660;
  localparam int LINE_1080  = 980;
  localparam int MIN_720    = 750 * LINE_720;
  localparam int MIN_1080   = 1125 * LINE_1080;
  localparam int PERIOD_RST = 1_200_000;
  localparam logic [31:0] FB_BASE = 32'h1000_0000;
  localparam int SLOT_LOG2  = 22;

  logic clk     = 1'b0;
  logic cfg_clk = 1'b0;
  logic arstn   = 1'b0;
  logic resetn;
  logic cfg_resetn;

  always #5.0  clk     = ~clk;
  always #4.85 cfg_clk = ~cfg_clk;

  rtlnet_reset_sync u_rst_a (.clk(clk),     .arstn(arstn), .resetn(resetn));
  rtlnet_reset_sync u_rst_b (.clk(cfg_clk), .arstn(arstn), .resetn(cfg_resetn));

  // csi2_rx -> s2mm stream.
  logic [31:0] v_tdata;
  logic        v_tvalid, v_tready, v_tlast, v_tuser;
  logic [31:0] v_frame, v_ts;
  logic [15:0] v_w, v_h;
  logic        v_src;

  // s2mm <-> framebuf.
  logic              fb_req, fb_rsp_valid, fb_rsp_ok;
  logic [ADDR_W-1:0] fb_rsp_base;
  logic              fb_done, fb_done_good, fb_done_src;
  logic [31:0]       fb_done_frame, fb_done_ts;
  logic [15:0]       fb_done_w, fb_done_h;

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
  logic [1:0]        bresp;
  logic              bvalid, bready;

  // Register masters: csi2 only (the other windows are idle).
  logic [11:0] c_awaddr, c_araddr;
  logic [31:0] c_wdata, c_rdata;
  logic [3:0]  c_wstrb;
  logic [1:0]  c_bresp, c_rresp;
  logic        c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready, c_arvalid, c_arready, c_rvalid, c_rready;

  rtlnet_tb_axil_master #(.ADDR_W(12)) u_mst (
    .aclk(cfg_clk), .awaddr(c_awaddr), .awvalid(c_awvalid), .awready(c_awready), .wdata(c_wdata), .wstrb(c_wstrb),
    .wvalid(c_wvalid), .wready(c_wready), .bresp(c_bresp), .bvalid(c_bvalid), .bready(c_bready), .araddr(c_araddr),
    .arvalid(c_arvalid), .arready(c_arready), .rdata(c_rdata), .rresp(c_rresp), .rvalid(c_rvalid), .rready(c_rready));

  logic [31:0] cam_tdata = '0;
  logic        cam_tvalid = 1'b0;
  logic        cam_tready;

  rtlnet_csi2_rx #(
    .PERIOD_RESET(PERIOD_RST), .PERIOD_MIN_720(MIN_720), .PERIOD_MIN_1080(MIN_1080),
    .LINE_PERIOD_720(LINE_720), .LINE_PERIOD_1080(LINE_1080), .CAM_TIMEOUT_RESET(2)
  ) u_csi2 (
    .clk(clk), .resetn(resetn), .s_axi_aclk(cfg_clk), .s_axi_aresetn(cfg_resetn),
    .s_cam_tdata(cam_tdata), .s_cam_tvalid(cam_tvalid), .s_cam_tready(cam_tready), .s_cam_tlast(1'b0),
    .s_cam_tuser(1'b0), .cam_clk_running(1'b0),
    .m_axis_tdata(v_tdata), .m_axis_tvalid(v_tvalid), .m_axis_tready(v_tready), .m_axis_tlast(v_tlast),
    .m_axis_tuser(v_tuser), .m_frame_num(v_frame), .m_timestamp(v_ts), .m_width(v_w), .m_height(v_h),
    .m_src_pattern(v_src),
    .s_axi_awaddr(c_awaddr), .s_axi_awvalid(c_awvalid), .s_axi_awready(c_awready), .s_axi_wdata(c_wdata),
    .s_axi_wstrb(c_wstrb), .s_axi_wvalid(c_wvalid), .s_axi_wready(c_wready), .s_axi_bresp(c_bresp),
    .s_axi_bvalid(c_bvalid), .s_axi_bready(c_bready), .s_axi_araddr(c_araddr), .s_axi_arvalid(c_arvalid),
    .s_axi_arready(c_arready), .s_axi_rdata(c_rdata), .s_axi_rresp(c_rresp), .s_axi_rvalid(c_rvalid),
    .s_axi_rready(c_rready));

  rtlnet_vdma_s2mm #(.ADDR_W(ADDR_W), .ID_W(1), .MAX_BURST_BEATS(16), .FIFO_KB(2)) u_s2mm (
    .clk(clk), .resetn(resetn), .s_axi_aclk(cfg_clk), .s_axi_aresetn(cfg_resetn),
    .s_axis_tdata(v_tdata), .s_axis_tvalid(v_tvalid), .s_axis_tready(v_tready), .s_axis_tlast(v_tlast),
    .s_axis_tuser(v_tuser), .s_width(v_w), .s_height(v_h), .s_frame_num(v_frame), .s_timestamp(v_ts),
    .s_src_pattern(v_src),
    .fb_req(fb_req), .fb_rsp_valid(fb_rsp_valid), .fb_rsp_ok(fb_rsp_ok), .fb_rsp_base(fb_rsp_base),
    .fb_done(fb_done), .fb_done_good(fb_done_good), .fb_done_frame_num(fb_done_frame), .fb_done_timestamp(fb_done_ts),
    .fb_done_width(fb_done_w), .fb_done_height(fb_done_h), .fb_done_src_pattern(fb_done_src),
    .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid), .m_axi_wready(wready), .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    .s_axi_awaddr(12'd0), .s_axi_awvalid(1'b0), .s_axi_awready(), .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0),
    .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
    .s_axi_araddr(12'd0), .s_axi_arvalid(1'b0), .s_axi_arready(), .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(),
    .s_axi_rready(1'b1));

  logic              r_take = 1'b0;
  logic              r_release = 1'b0;
  logic              r_rsp_valid, r_rsp_ok, r_holds;
  logic [7:0]        r_slot;
  logic [ADDR_W-1:0] r_base;
  logic [31:0]       r_frame, r_ts;
  logic [15:0]       r_w, r_h;
  logic              r_src;

  rtlnet_framebuf #(.N(3), .NUM_READERS(1), .ADDR_W(ADDR_W), .SLOT_LOG2(SLOT_LOG2), .FB_BASE(FB_BASE)) u_fb (
    .clk(clk), .resetn(resetn), .s_axi_aclk(cfg_clk), .s_axi_aresetn(cfg_resetn),
    .w_req(fb_req), .w_rsp_valid(fb_rsp_valid), .w_rsp_ok(fb_rsp_ok), .w_rsp_base(fb_rsp_base),
    .w_done(fb_done), .w_done_good(fb_done_good), .w_done_frame_num(fb_done_frame), .w_done_timestamp(fb_done_ts),
    .w_done_width(fb_done_w), .w_done_height(fb_done_h), .w_done_src_pattern(fb_done_src),
    .r_take(r_take), .r_release(r_release), .r_rsp_valid(r_rsp_valid), .r_rsp_ok(r_rsp_ok), .r_holds(r_holds),
    .r_slot(r_slot), .r_base(r_base), .r_frame_num(r_frame), .r_timestamp(r_ts), .r_width(r_w), .r_height(r_h),
    .r_src_pattern(r_src),
    .s_axi_awaddr(12'd0), .s_axi_awvalid(1'b0), .s_axi_awready(), .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0),
    .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b1),
    .s_axi_araddr(12'd0), .s_axi_arvalid(1'b0), .s_axi_arready(), .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(),
    .s_axi_rready(1'b1));

  rtlnet_tb_axi4_mem #(
    .ADDR_W(ADDR_W), .DATA_W(128), .ID_W(1), .READ_LATENCY(0),
    .AW_READY_PCT(70), .W_READY_PCT(80), .AR_READY_PCT(100), .B_VALID_PCT(70), .R_VALID_PCT(100), .SEED(3)
  ) u_mem (
    .clk(clk), .resetn(resetn),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid),
    .awready(awready), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .arid(1'b0), .araddr('0), .arlen(8'd0), .arsize(3'd4), .arburst(2'b01), .arvalid(1'b0), .arready(),
    .rid(), .rdata(), .rresp(), .rlast(), .rvalid(), .rready(1'b1));

  // ---------------------------------------------------------------------------
  // CRC-32 (reflected 0xEDB88320, table form; independent of the RTL)
  // ---------------------------------------------------------------------------
  logic [31:0] crc_tbl [256];
  initial begin
    for (int n = 0; n < 256; n++) begin
      logic [31:0] c;
      c = 32'(n);
      for (int k = 0; k < 8; k++) c = c[0] ? (32'hEDB88320 ^ (c >> 1)) : (c >> 1);
      crc_tbl[n] = c;
    end
  end

  // CRC-32 of a packed frame in memory: h lines of w*2 bytes at base + line * w*2.
  function automatic logic [31:0] frame_crc(input logic [ADDR_W-1:0] base, input int w_px, input int h);
    logic [31:0] c;
    logic [127:0] beat;
    c = 32'hFFFF_FFFF;
    for (int off = 0; off < w_px * 2 * h; off += 16) begin
      beat = u_mem.peek(ADDR_W'(base + off));
      for (int b = 0; b < 16; b++) c = crc_tbl[(c ^ beat[b*8 +: 8]) & 32'hFF] ^ (c >> 8);
    end
    return ~c;
  endfunction

  logic [1:0] rd_resp, wr_resp;
  logic [31:0] v;

  task automatic reg_read(input logic [11:0] a, output logic [31:0] val);
    u_mst.read32(a, val, rd_resp);
    tb_check(rd_resp == 2'b00, "register read response");
  endtask

  task automatic reg_write(input logic [11:0] a, input logic [31:0] val);
    u_mst.write32(a, val, 4'hF, wr_resp);
    tb_check(wr_resp == 2'b00, "register write response");
  endtask

  // Publish monitor: frame numbers in order.
  int pub_count = 0;
  int pub_last_num = 0;
  int pub_w = 0;
  int bad_count = 0;
  always @(posedge clk) begin
    if (resetn === 1'b1 && fb_done) begin
      if (fb_done_good) begin
        pub_count++;
        tb_check(int'(fb_done_frame) > pub_last_num, "published frame numbers do not increase");
        pub_last_num = int'(fb_done_frame);
        pub_w = int'(fb_done_w);
      end else begin
        bad_count++;
      end
    end
  end

  // Take the latest slot, CRC it, hold it across further frames, check again, release. Returns the held frame's description.
  task automatic take_and_check(input int exp_w, input int exp_h, input logic [31:0] exp_crc, input string tag);
    logic [31:0] c1;
    logic [31:0] c2;
    int           pub_before;
    r_take <= 1'b1;
    @(posedge clk);
    r_take <= 1'b0;
    while (!r_rsp_valid) @(posedge clk);
    tb_check(r_rsp_ok, {tag, ": take refused"});
    if (r_rsp_ok) begin
      tb_check(int'(r_w) == exp_w && int'(r_h) == exp_h && r_src, $sformatf("%s: frame %0dx%0d src %0d", tag, r_w, r_h, r_src));
      c1 = frame_crc(r_base, exp_w, exp_h);
      tb_check(c1 == exp_crc, $sformatf("%s: CRC-32 0x%08h, C model 0x%08h", tag, c1, exp_crc));
      // Hold across more frames: the slot must not change.
      pub_before = pub_count;
      while (pub_count < pub_before + 2) @(posedge clk);
      c2 = frame_crc(r_base, exp_w, exp_h);
      tb_check(c2 == exp_crc, $sformatf("%s: the held slot changed while held (0x%08h)", tag, c2));
      r_release <= 1'b1;
      @(posedge clk);
      r_release <= 1'b0;
    end
    repeat (4) @(posedge clk);
  endtask

  initial begin
    wait (resetn === 1'b1 && cfg_resetn === 1'b1);
    // 1. Defaults only: 720p30 bars.
    while (pub_count < 2) @(posedge clk);
    take_and_check(1280, 720, 32'(`TB_CRC720), "720p30");
    // 2. 1080p30.
    reg_write(12'h018, 32'(PERIOD_RST));
    reg_write(12'h010, 32'd1);
    reg_read(12'h010, v);
    tb_check(v == 32'd1, "VIDEO_MODE write rejected");
    while (pub_w != 1920) @(posedge clk);
    // A second 1080p frame follows, so the latest published frame is 1080p30.
    begin
      int target;
      target = pub_count + 1;
      while (pub_count < target) @(posedge clk);
    end
    take_and_check(1920, 1080, 32'(`TB_CRC1080), "1080p30");
    // 3. Counters: after a publish, FRAMES_OK equals the published count.
    begin
      int target;
      target = pub_count + 1;
      while (pub_count < target) @(posedge clk);
      repeat (10) @(posedge clk);
      tb_check(u_s2mm.u_regs.cnt_ok == 32'(pub_count), $sformatf("S2MM FRAMES_OK %0d, published %0d", u_s2mm.u_regs.cnt_ok, pub_count));
      tb_check(u_s2mm.u_regs.cnt_drop == 32'd0, "S2MM dropped frames");
      tb_check(u_s2mm.u_regs.cnt_bad == 32'd0, "S2MM bad frames");
      tb_check(bad_count == 0, $sformatf("%0d frames reported not good", bad_count));
      tb_check(u_fb.u_regs.cnt_pub == 32'(pub_count), "framebuf PUBLISHED");
      tb_check(u_fb.u_regs.cnt_drop == 32'd0, "framebuf DROPPED");
    end
    $display("video path: published %0d, bad %0d", pub_count, bad_count);
    tb_verdict("tb_rtlnet_video_path");
  end

  // Watchdog.
  initial begin
    #2000ms;
    tb_error("watchdog: the bench did not finish");
    tb_verdict("tb_rtlnet_video_path");
  end

  initial begin
    repeat (8) #20;
    arstn = 1'b1;
  end

endmodule
