// Purpose: PS-free end-to-end RGB camera capture, slot ownership and H.264 encode.
// Overview: AXI-Lite GP master BFM and two AXI3 HP byte-memory slaves replace PS7.
//   Five small camera frames in the 1080p mode prove alternate admission and a held slot's integrity; two more in the 720p mode prove that every frame is admitted.
//   One real lossy/deblocked IDR encode dumps Annex B and rebuilt YUV for the
//   repository decoder comparison flow. The sensor/D-PHY is outside this bench.
// Revision: 11-14-2026. Initial board bench. No foreach loops.
`timescale 1ns/1ps
package rtlnet_zybo_tb_memory;
  byte unsigned mem [0:1048575];
  function automatic integer address(input logic [31:0] physical);
    integer base;
    case (physical[31:20])
      12'h100: base = 0;
      12'h104: base = 65536;
      12'h108: base = 131072;
      12'h110: base = 196608;
      12'h112: base = 262144;
      12'h114: base = 327680;
      12'h116: base = 393216;
      12'h120: base = 458752;
      12'h130: base = 524288;
      default: begin $error("unmapped PS DDR address %08x", physical); base = 983040; end
    endcase
    if (physical[19:16] != 0) $error("small bench region overflow %08x", physical);
    return base + physical[15:0];
  endfunction
  function automatic logic [31:0] word32(input logic [31:0] physical);
    logic [31:0] value;
    for (int k=0; k<4; k++) value[8*k +: 8] = mem[address(physical+k)];
    return value;
  endfunction
endpackage

module tb_rtlnet_zybo_video;
  import rtlnet_tb_pkg::*;
  import rtlnet_zybo_tb_memory::*;
  logic ctrl_clk = 0;
  logic enc_clk = 0;
  logic ctrl_resetn = 0;
  logic capture_resetn = 0;
  logic enc_resetn = 0;
  always #10 ctrl_clk = ~ctrl_clk;
  // One 90 MHz video clock drives the camera chain, capture and encoder (board clock plan 11-14-2026).
  always #5.555 enc_clk = ~enc_clk;
  logic [23:0] s_axis_video_tdata = '0;
  logic  s_axis_video_tvalid = '0;
  logic  s_axis_video_tready;
  logic  s_axis_video_tuser = '0;
  logic  s_axis_video_tlast = '0;
  logic [31:0] s_axi_awaddr;
  logic  s_axi_awvalid;
  logic  s_axi_awready;
  logic [31:0] s_axi_wdata;
  logic [3:0] s_axi_wstrb;
  logic  s_axi_wvalid;
  logic  s_axi_wready;
  logic [1:0] s_axi_bresp;
  logic  s_axi_bvalid;
  logic  s_axi_bready;
  logic [31:0] s_axi_araddr;
  logic  s_axi_arvalid;
  logic  s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0] s_axi_rresp;
  logic  s_axi_rvalid;
  logic  s_axi_rready;
  logic [5:0] m_axi_cap_awid;
  logic [31:0] m_axi_cap_awaddr;
  logic [3:0] m_axi_cap_awlen;
  logic [2:0] m_axi_cap_awsize;
  logic [1:0] m_axi_cap_awburst;
  logic  m_axi_cap_awvalid;
  logic  m_axi_cap_awready;
  logic [5:0] m_axi_cap_wid;
  logic [63:0] m_axi_cap_wdata;
  logic [7:0] m_axi_cap_wstrb;
  logic  m_axi_cap_wlast;
  logic  m_axi_cap_wvalid;
  logic  m_axi_cap_wready;
  logic [5:0] m_axi_cap_bid;
  logic [1:0] m_axi_cap_bresp;
  logic  m_axi_cap_bvalid;
  logic  m_axi_cap_bready;
  logic [5:0] m_axi_cap_arid;
  logic [31:0] m_axi_cap_araddr;
  logic [3:0] m_axi_cap_arlen;
  logic [2:0] m_axi_cap_arsize;
  logic [1:0] m_axi_cap_arburst;
  logic  m_axi_cap_arvalid;
  logic  m_axi_cap_arready;
  logic [5:0] m_axi_cap_rid;
  logic [63:0] m_axi_cap_rdata;
  logic [1:0] m_axi_cap_rresp;
  logic  m_axi_cap_rlast;
  logic  m_axi_cap_rvalid;
  logic  m_axi_cap_rready;
  logic [5:0] m_axi_enc_awid;
  logic [31:0] m_axi_enc_awaddr;
  logic [3:0] m_axi_enc_awlen;
  logic [2:0] m_axi_enc_awsize;
  logic [1:0] m_axi_enc_awburst;
  logic  m_axi_enc_awvalid;
  logic  m_axi_enc_awready;
  logic [5:0] m_axi_enc_wid;
  logic [63:0] m_axi_enc_wdata;
  logic [7:0] m_axi_enc_wstrb;
  logic  m_axi_enc_wlast;
  logic  m_axi_enc_wvalid;
  logic  m_axi_enc_wready;
  logic [5:0] m_axi_enc_bid;
  logic [1:0] m_axi_enc_bresp;
  logic  m_axi_enc_bvalid;
  logic  m_axi_enc_bready;
  logic [5:0] m_axi_enc_arid;
  logic [31:0] m_axi_enc_araddr;
  logic [3:0] m_axi_enc_arlen;
  logic [2:0] m_axi_enc_arsize;
  logic [1:0] m_axi_enc_arburst;
  logic  m_axi_enc_arvalid;
  logic  m_axi_enc_arready;
  logic [5:0] m_axi_enc_rid;
  logic [63:0] m_axi_enc_rdata;
  logic [1:0] m_axi_enc_rresp;
  logic  m_axi_enc_rlast;
  logic  m_axi_enc_rvalid;
  logic  m_axi_enc_rready;
  logic [1:0] irq;
  rtlnet_zybo_video_bd #(.WIDTH_720(32), .HEIGHT_720(16), .WIDTH_1080(32), .HEIGHT_1080(16)) dut (
    .s_axi_aclk(ctrl_clk),
    .s_axi_aresetn(ctrl_resetn),
    .capture_clk(enc_clk),
    .capture_resetn(capture_resetn),
    .enc_clk(enc_clk),
    .enc_resetn(enc_resetn),
    .s_axis_video_tdata(s_axis_video_tdata),
    .s_axis_video_tvalid(s_axis_video_tvalid),
    .s_axis_video_tready(s_axis_video_tready),
    .s_axis_video_tuser(s_axis_video_tuser),
    .s_axis_video_tlast(s_axis_video_tlast),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .m_axi_cap_awid(m_axi_cap_awid),
    .m_axi_cap_awaddr(m_axi_cap_awaddr),
    .m_axi_cap_awlen(m_axi_cap_awlen),
    .m_axi_cap_awsize(m_axi_cap_awsize),
    .m_axi_cap_awburst(m_axi_cap_awburst),
    .m_axi_cap_awvalid(m_axi_cap_awvalid),
    .m_axi_cap_awready(m_axi_cap_awready),
    .m_axi_cap_wid(m_axi_cap_wid),
    .m_axi_cap_wdata(m_axi_cap_wdata),
    .m_axi_cap_wstrb(m_axi_cap_wstrb),
    .m_axi_cap_wlast(m_axi_cap_wlast),
    .m_axi_cap_wvalid(m_axi_cap_wvalid),
    .m_axi_cap_wready(m_axi_cap_wready),
    .m_axi_cap_bid(m_axi_cap_bid),
    .m_axi_cap_bresp(m_axi_cap_bresp),
    .m_axi_cap_bvalid(m_axi_cap_bvalid),
    .m_axi_cap_bready(m_axi_cap_bready),
    .m_axi_cap_arid(m_axi_cap_arid),
    .m_axi_cap_araddr(m_axi_cap_araddr),
    .m_axi_cap_arlen(m_axi_cap_arlen),
    .m_axi_cap_arsize(m_axi_cap_arsize),
    .m_axi_cap_arburst(m_axi_cap_arburst),
    .m_axi_cap_arvalid(m_axi_cap_arvalid),
    .m_axi_cap_arready(m_axi_cap_arready),
    .m_axi_cap_rid(m_axi_cap_rid),
    .m_axi_cap_rdata(m_axi_cap_rdata),
    .m_axi_cap_rresp(m_axi_cap_rresp),
    .m_axi_cap_rlast(m_axi_cap_rlast),
    .m_axi_cap_rvalid(m_axi_cap_rvalid),
    .m_axi_cap_rready(m_axi_cap_rready),
    .m_axi_enc_awid(m_axi_enc_awid),
    .m_axi_enc_awaddr(m_axi_enc_awaddr),
    .m_axi_enc_awlen(m_axi_enc_awlen),
    .m_axi_enc_awsize(m_axi_enc_awsize),
    .m_axi_enc_awburst(m_axi_enc_awburst),
    .m_axi_enc_awvalid(m_axi_enc_awvalid),
    .m_axi_enc_awready(m_axi_enc_awready),
    .m_axi_enc_wid(m_axi_enc_wid),
    .m_axi_enc_wdata(m_axi_enc_wdata),
    .m_axi_enc_wstrb(m_axi_enc_wstrb),
    .m_axi_enc_wlast(m_axi_enc_wlast),
    .m_axi_enc_wvalid(m_axi_enc_wvalid),
    .m_axi_enc_wready(m_axi_enc_wready),
    .m_axi_enc_bid(m_axi_enc_bid),
    .m_axi_enc_bresp(m_axi_enc_bresp),
    .m_axi_enc_bvalid(m_axi_enc_bvalid),
    .m_axi_enc_bready(m_axi_enc_bready),
    .m_axi_enc_arid(m_axi_enc_arid),
    .m_axi_enc_araddr(m_axi_enc_araddr),
    .m_axi_enc_arlen(m_axi_enc_arlen),
    .m_axi_enc_arsize(m_axi_enc_arsize),
    .m_axi_enc_arburst(m_axi_enc_arburst),
    .m_axi_enc_arvalid(m_axi_enc_arvalid),
    .m_axi_enc_arready(m_axi_enc_arready),
    .m_axi_enc_rid(m_axi_enc_rid),
    .m_axi_enc_rdata(m_axi_enc_rdata),
    .m_axi_enc_rresp(m_axi_enc_rresp),
    .m_axi_enc_rlast(m_axi_enc_rlast),
    .m_axi_enc_rvalid(m_axi_enc_rvalid),
    .m_axi_enc_rready(m_axi_enc_rready),
    .irq(irq)
  );
  rtlnet_tb_axil_master cpu (.aclk(ctrl_clk),
    .awaddr(s_axi_awaddr),
    .awvalid(s_axi_awvalid),
    .awready(s_axi_awready),
    .wdata(s_axi_wdata),
    .wstrb(s_axi_wstrb),
    .wvalid(s_axi_wvalid),
    .wready(s_axi_wready),
    .bresp(s_axi_bresp),
    .bvalid(s_axi_bvalid),
    .bready(s_axi_bready),
    .araddr(s_axi_araddr),
    .arvalid(s_axi_arvalid),
    .arready(s_axi_arready),
    .rdata(s_axi_rdata),
    .rresp(s_axi_rresp),
    .rvalid(s_axi_rvalid),
    .rready(s_axi_rready)
  );
  rtlnet_zybo_tb_hp mem_cap (.clk(enc_clk), .resetn(capture_resetn),
    .awid(m_axi_cap_awid),
    .awaddr(m_axi_cap_awaddr),
    .awlen(m_axi_cap_awlen),
    .awsize(m_axi_cap_awsize),
    .awburst(m_axi_cap_awburst),
    .awvalid(m_axi_cap_awvalid),
    .awready(m_axi_cap_awready),
    .wid(m_axi_cap_wid),
    .wdata(m_axi_cap_wdata),
    .wstrb(m_axi_cap_wstrb),
    .wlast(m_axi_cap_wlast),
    .wvalid(m_axi_cap_wvalid),
    .wready(m_axi_cap_wready),
    .bid(m_axi_cap_bid),
    .bresp(m_axi_cap_bresp),
    .bvalid(m_axi_cap_bvalid),
    .bready(m_axi_cap_bready),
    .arid(m_axi_cap_arid),
    .araddr(m_axi_cap_araddr),
    .arlen(m_axi_cap_arlen),
    .arsize(m_axi_cap_arsize),
    .arburst(m_axi_cap_arburst),
    .arvalid(m_axi_cap_arvalid),
    .arready(m_axi_cap_arready),
    .rid(m_axi_cap_rid),
    .rdata(m_axi_cap_rdata),
    .rresp(m_axi_cap_rresp),
    .rlast(m_axi_cap_rlast),
    .rvalid(m_axi_cap_rvalid),
    .rready(m_axi_cap_rready)
  );
  rtlnet_zybo_tb_hp mem_enc (.clk(enc_clk), .resetn(enc_resetn),
    .awid(m_axi_enc_awid),
    .awaddr(m_axi_enc_awaddr),
    .awlen(m_axi_enc_awlen),
    .awsize(m_axi_enc_awsize),
    .awburst(m_axi_enc_awburst),
    .awvalid(m_axi_enc_awvalid),
    .awready(m_axi_enc_awready),
    .wid(m_axi_enc_wid),
    .wdata(m_axi_enc_wdata),
    .wstrb(m_axi_enc_wstrb),
    .wlast(m_axi_enc_wlast),
    .wvalid(m_axi_enc_wvalid),
    .wready(m_axi_enc_wready),
    .bid(m_axi_enc_bid),
    .bresp(m_axi_enc_bresp),
    .bvalid(m_axi_enc_bvalid),
    .bready(m_axi_enc_bready),
    .arid(m_axi_enc_arid),
    .araddr(m_axi_enc_araddr),
    .arlen(m_axi_enc_arlen),
    .arsize(m_axi_enc_arsize),
    .arburst(m_axi_enc_arburst),
    .arvalid(m_axi_enc_arvalid),
    .arready(m_axi_enc_arready),
    .rid(m_axi_enc_rid),
    .rdata(m_axi_enc_rdata),
    .rresp(m_axi_enc_rresp),
    .rlast(m_axi_enc_rlast),
    .rvalid(m_axi_enc_rvalid),
    .rready(m_axi_enc_rready)
  );

  localparam logic [31:0] CAM = 32'h44a05000;
  localparam logic [31:0] DMA = 32'h44a06000;
  localparam logic [31:0] FB = 32'h44a07000;
  localparam logic [31:0] ENC = 32'h44a08000;
  logic [31:0] v;
  logic [31:0] slot;
  logic [31:0] stamp;
  logic [31:0] stream_length;
  logic [31:0] stream_offset;
  byte unsigned snapshot [0:1023];
  byte unsigned reconstructed [0:767];
  integer capture_irqs = 0;
  integer f;
  logic [127:0] dump_word;
  integer expected_y;
  integer actual_y;
  string out_prefix = "board";
  integer timeout_count;

  always @(posedge ctrl_clk) if (ctrl_resetn && irq[0]) capture_irqs++;

  // The camera side models the CSI-2 receiver output: pixels arrive at the sensor link rate (pace_num/pace_den
  // pixels per video clock) into a receiver FIFO model (backlog) and are offered one per clock when the
  // capture path accepts. The backlog peak must stay far below the receiver line buffer (2048 beats x 4 pixels).
  integer pace_num = 1;
  integer pace_den = 1;
  integer pace_acc = 0;
  integer backlog = 0;
  integer backlog_peak = 0;
  integer stall_cycles = 0;
  logic pace_en = 0;
  always @(posedge enc_clk) begin
    if (pace_en) begin
      pace_acc = pace_acc + pace_num;
      if (pace_acc >= pace_den) begin pace_acc = pace_acc - pace_den; backlog = backlog + 1; end
    end
    if (pace_en && s_axis_video_tvalid && s_axis_video_tready) backlog = backlog - 1;
    if (pace_en && s_axis_video_tvalid && !s_axis_video_tready) stall_cycles = stall_cycles + 1;
    if (backlog > backlog_peak) backlog_peak = backlog;
  end
  task automatic camera_frame(input integer seed, input integer num, input integer den);
    integer gray;
    pace_num = num; pace_den = den; pace_acc = 0; backlog = 0;
    pace_en = (num != den);
    for (int y=0; y<16; y++) begin
      for (int x=0; x<32; x++) begin
        @(negedge enc_clk);
        if (pace_en) begin
          s_axis_video_tvalid = 0;
          while (backlog <= 0) @(negedge enc_clk);
        end
        gray = (seed*19 + x*3 + y*5) & 255;
        s_axis_video_tdata = {3{gray[7:0]}};
        s_axis_video_tuser = (x==0 && y==0);
        s_axis_video_tlast = (x==31);
        s_axis_video_tvalid = 1;
        do @(posedge enc_clk); while (!s_axis_video_tready);
      end
    end
    @(negedge enc_clk);
    s_axis_video_tvalid = 0;
    s_axis_video_tuser = 0;
    s_axis_video_tlast = 0;
    pace_en = 0;
    repeat (50) @(negedge enc_clk);
  endtask
  task automatic wait_published(input integer count);
    integer n;
    logic [31:0] published;
    n=0;
    published=0;
    while (published < count && n<2000) begin
      cpu.rd(FB+32'h60,published);
      n++;
    end
    tb_check(published==count,"capture publication count");
    if (published!=count) begin
      cpu.rd(CAM+32'h0c,v); $display("DBG camera enable %08x",v);
      cpu.rd(CAM+32'h20,v); $display("DBG camera seen %08x",v);
      cpu.rd(CAM+32'h24,v); $display("DBG camera admitted %08x",v);
      cpu.rd(DMA+32'h10,v); $display("DBG DMA status %08x",v);
      cpu.rd(DMA+32'h18,v); $display("DBG DMA good %08x",v);
      cpu.rd(DMA+32'h1c,v); $display("DBG DMA bad %08x",v);
      cpu.rd(DMA+32'h20,v); $display("DBG DMA dropped %08x",v);
      $display("DBG req %b rsp %b ok %b pair valid %b ready %b, frame WH %d %d",
               dut.u_rtl.fb_req,dut.u_rtl.fb_rsp_valid,dut.u_rtl.fb_rsp_ok,dut.u_rtl.pair_valid,dut.u_rtl.pair_ready,
               dut.u_rtl.frame_width,dut.u_rtl.frame_height);
      tb_verdict("tb_rtlnet_zybo_video");
    end
  endtask

  initial begin
    if (!$value$plusargs("OUT=%s",out_prefix)) out_prefix="board";
    for (int k=0;k<1048576;k++) mem[k]=8'ha5;
    repeat (15) @(negedge ctrl_clk);
    @(negedge enc_clk); capture_resetn=1;
    @(negedge enc_clk); enc_resetn=1;
    @(negedge ctrl_clk); ctrl_resetn=1;
    repeat (10) @(negedge ctrl_clk);
    cpu.rd(CAM,v); tb_check(v==32'h5a43414d,"camera board ID");
    cpu.rd(DMA,v); tb_check(v==32'h53324d4d,"capture DMA ID");
    cpu.rd(FB,v); tb_check(v==32'h46425546,"framebuf ID");
    cpu.rd(ENC,v); tb_check(v==32'h48323634,"encoder ID");
    cpu.rd(ENC+8,v); tb_check(v[19:16]==1 && v[22],"one engine with deblocking");
    cpu.wr(DMA+32'h14,128);
    cpu.wr(CAM+32'h10,1);   // 1080p mode (geometry shrunk to 32x16 here): the sensor runs 30 fps, every second frame is admitted
    cpu.rd(CAM+32'h18,v); tb_check(v==6000,"1080p admission PTS step 6000 (15 fps stream)");
    cpu.wr(CAM+32'h0c,1);
    camera_frame(0, 1, 1);
    camera_frame(1, 1, 1);
    camera_frame(2, 56, 90);   // 720p sensor mode link rate: 56 Mpixel/s at 90 MHz
    wait_published(2);
    cpu.wr(FB+32'h0c,1);
    cpu.rd(FB+32'h10,v); tb_check(v[1],"firmware holds a slot");
    cpu.rd(FB+32'h40,slot);
    cpu.rd(FB+32'h44,v); tb_check(v==2,"admitted frame sequence advances at 30 fps");
    cpu.rd(FB+32'h48,stamp); tb_check(stamp!=0,"capture timestamp is populated");
    cpu.rd(FB+32'h4c,v); tb_check(v==32'h00100020,"captured 32x16 geometry");
    for (int k=0;k<1024;k++) snapshot[k]=mem[address(slot+(k/64)*128+(k%64))];
    for (int y=0;y<16;y++) begin
      for (int x=0;x<32;x++) begin
        expected_y=$rtoi($floor(16.0 + 219.0*((38+x*3+y*5)&255)/255.0 + 0.5));
        actual_y=snapshot[(y*32+x)*2];
        tb_check(actual_y>=expected_y-1 && actual_y<=expected_y+1,"capture BT.709 luma");
        tb_check(snapshot[(y*32+x)*2+1]==128,"capture neutral chroma");
      end
    end
    camera_frame(3, 84, 90);   // 1080p30 sensor: lanes at 420 Mb/s (84 Mpixel/s burst) against one pixel per 90 MHz clock
    camera_frame(4, 42, 90);   // slower link rate (the former 1080p15 table, 42 Mpixel/s)
    tb_check(backlog_peak < 64, "receiver backlog stays far below the line buffer at the sensor link rates");
    $display("BENCH: receiver backlog peak %0d pixels, source stall cycles %0d", backlog_peak, stall_cycles);
    wait_published(3);
    for (int k=0;k<1024;k++)
      tb_check(mem[address(slot+(k/64)*128+(k%64))]==snapshot[k],"held slot never overwritten");
    cpu.rd(CAM+32'h20,v); tb_check(v==5,"all five camera frames observed");
    cpu.rd(CAM+32'h24,v); tb_check(v==3,"alternate frame admission");
    cpu.wr(ENC+32'h20,2);
    cpu.wr(ENC+32'h24,1);
    cpu.wr(ENC+32'h28,1);
    cpu.wr(ENC+32'h2c,28);
    cpu.wr(ENC+32'h30,0);
    cpu.wr(ENC+32'h34,0);
    cpu.wr(ENC+32'h38,32'h401);
    cpu.wr(ENC+32'h40,slot);
    cpu.wr(ENC+32'h44,128);
    cpu.wr(ENC+32'h48,32'h11000000);
    cpu.wr(ENC+32'h50,32'h11200000);
    cpu.wr(ENC+32'h54,32'h11400000);
    cpu.wr(ENC+32'h58,32'h11600000);
    cpu.wr(ENC+32'h60,32'h12000000);
    cpu.wr(ENC+32'h64,65536);
    cpu.wr(ENC+32'h78,32'h13000000);
    cpu.wr(ENC+32'h7c,64);
    cpu.wr(ENC+32'h0c,2);
    cpu.wr(ENC+32'hd4,3);
    cpu.wr(ENC+32'h0c,32'h101);
    timeout_count=0;
    v=0;
    while (!v[1] && !v[2] && timeout_count<4000) begin
      cpu.rd(ENC+32'h10,v);
      timeout_count++;
    end
    tb_check(v[1] && !v[2],"small-picture real encoder completes without error");
    if (!v[1] || v[2]) begin
      $display("DBG encoder status %08x",v);
      cpu.rd(ENC+32'h14,v); $display("DBG encoder error %08x",v);
      cpu.rd(32'h44a04010,v); $display("DBG arbiter status %08x",v);
      cpu.rd(32'h44a04040,v); $display("DBG arbiter capture %08x",v);
      cpu.rd(32'h44a04044,v); $display("DBG arbiter address %08x",v);
      tb_verdict("tb_rtlnet_zybo_video");
    end
    repeat (6) @(negedge ctrl_clk);
    tb_check(irq[1],"encoder IRQ reaches GIC stub");
    tb_check(capture_irqs==3,"three publication IRQs reach GIC stub");
    cpu.wr(ENC+32'hd0,1);
    repeat (6) @(negedge ctrl_clk);
    tb_check(!irq[1],"encoder interrupt acknowledgement deasserts GIC input");
    cpu.rd(ENC+32'h80,v); tb_check(v==2,"slice and picture index records published");
    stream_offset=word32(32'h13000080);
    stream_length=word32(32'h13000084);
    tb_check(stream_length>10 && stream_length<65536,"index picture length bounded");
    if (stream_length<=10 || stream_length>=65536) tb_verdict("tb_rtlnet_zybo_video");
    tb_check(word32(32'h12000000+stream_offset)==32'h01000000,"Annex B delimiter start code");
    f=$fopen({out_prefix,"_stream.hex"},"w");
    tb_check(f!=0,"stream dump opens");
    for (int i=0;i<stream_length;i+=16) begin
      dump_word=0;
      for (int k=0;k<16;k++) begin
        if (i+k<stream_length) dump_word[8*k +:8]=mem[address(32'h12000000+stream_offset+i+k)];
      end
      $fdisplay(f,"%032x",dump_word);
    end
    $fclose(f);
    for (int y=0;y<16;y++) begin
      for (int x=0;x<32;x++) reconstructed[y*32+x]=
        mem[address(32'h11000000+(x/16)*256+y*16+x%16)];
    end
    for (int y=0;y<8;y++) begin
      for (int x=0;x<16;x++) begin
        reconstructed[512+y*16+x]=mem[address(32'h11200000+(x/8)*128+y*8+x%8)];
        reconstructed[640+y*16+x]=mem[address(32'h11200000+(x/8)*128+64+y*8+x%8)];
      end
    end
    f=$fopen({out_prefix,"_rec0.hex"},"w");
    tb_check(f!=0,"reconstruction dump opens");
    for (int i=0;i<768;i+=16) begin
      for (int k=0;k<16;k++) dump_word[8*k +:8]=reconstructed[i+k];
      $fdisplay(f,"%032x",dump_word);
    end
    $fclose(f);
    f=$fopen({out_prefix,"_info.txt"},"w");
    $fdisplay(f,"stream_bytes=%0d",stream_length);
    $fdisplay(f,"mbw=2\nmbh=1\nslices=1\nengines=1\npics=1");
    $fdisplay(f,"ry_stride=32\nrc_stride=16\nry_size=512\nrc_size=128");
    $fclose(f);
    cpu.wr(FB+32'h0c,2);
    // 720p mode: the sensor runs 30 fps and every frame is admitted (30 fps stream, PTS step 3000)
    cpu.wr(CAM+32'h10,0);
    cpu.rd(CAM+32'h18,v); tb_check(v==3000,"720p admission PTS step 3000 (30 fps stream)");
    camera_frame(5, 1, 1);
    camera_frame(6, 1, 1);
    cpu.rd(CAM+32'h20,v); tb_check(v==7,"seven camera frames observed in total");
    cpu.rd(CAM+32'h24,v); tb_check(v==5,"720p admits every frame (two more admitted)");
    tb_verdict("tb_rtlnet_zybo_video");
  end
  initial begin
    #20000000;
    tb_error("board watchdog");
    tb_verdict("tb_rtlnet_zybo_video");
  end
endmodule

// PS HP slave model: per-port AXI3 ordering with a shared physical DDR byte store.
module rtlnet_zybo_tb_hp (
  input logic clk,
  input logic resetn,
  input logic [5:0] awid,
  input logic [31:0] awaddr,
  input logic [3:0] awlen,
  input logic [2:0] awsize,
  input logic [1:0] awburst,
  input logic  awvalid,
  output logic  awready,
  input logic [5:0] wid,
  input logic [63:0] wdata,
  input logic [7:0] wstrb,
  input logic  wlast,
  input logic  wvalid,
  output logic  wready,
  output logic [5:0] bid,
  output logic [1:0] bresp,
  output logic  bvalid,
  input logic  bready,
  input logic [5:0] arid,
  input logic [31:0] araddr,
  input logic [3:0] arlen,
  input logic [2:0] arsize,
  input logic [1:0] arburst,
  input logic  arvalid,
  output logic  arready,
  output logic [5:0] rid,
  output logic [63:0] rdata,
  output logic [1:0] rresp,
  output logic  rlast,
  output logic  rvalid,
  input logic  rready
);
  import rtlnet_tb_pkg::*;
  import rtlnet_zybo_tb_memory::*;
  logic writing=0;
  logic reading=0;
  logic [31:0] wa=0;
  logic [31:0] ra=32'h10000000;
  logic [5:0] wi=0;
  logic [5:0] ri=0;
  integer wn=0;
  integer rn=0;
  logic we=0;
  logic re=0;
  assign awready=resetn && !writing && !bvalid && we;
  assign wready=resetn && writing && we;
  assign arready=resetn && !reading && re;
  assign rid=ri;
  assign rlast=(rn==1);
  assign rvalid=reading && re;
  assign rresp=2'b00;
  for (genvar b=0;b<8;b++) begin : g_read_bytes
    assign rdata[b*8 +:8]=mem[address(ra+b)];
  end
  always @(negedge clk) begin
    we=($urandom%4)!=0;
    if (!rvalid || rready) re=($urandom%4)!=0;
  end
  always @(posedge clk) begin
    if (!resetn) begin
      writing=0;
      reading=0;
      bvalid<=0;
      bid<=0;
      bresp<=0;
    end else begin
      if (bvalid && bready) bvalid<=0;
      if (awvalid && awready) begin
        tb_check(awsize==3 && awburst==1,"HP write shape");
        tb_check(awaddr[11:0]+(awlen+1)*8<=4096,"HP write within page");
        wa=awaddr; wi=awid; wn=awlen+1; writing=1;
      end
      if (wvalid && wready) begin
        tb_check(wid==wi,"HP WID");
        tb_check(wlast==(wn==1),"HP WLAST");
        for (int k=0;k<8;k++) if(wstrb[k]) mem[address(wa+k)]=wdata[k*8 +:8];
        wa+=8; wn--;
        if (wn==0) begin writing=0; bid<=wi; bresp<=0; bvalid<=1; end
      end
      if (arvalid && arready) begin
        tb_check(arsize==3 && arburst==1,"HP read shape");
        tb_check(araddr[11:0]+(arlen+1)*8<=4096,"HP read within page");
        ra=araddr; ri=arid; rn=arlen+1; reading=1;
      end else if (rvalid && rready) begin
        ra+=8; rn--;
        if(rn==0) reading=0;
      end
    end
  end
endmodule
