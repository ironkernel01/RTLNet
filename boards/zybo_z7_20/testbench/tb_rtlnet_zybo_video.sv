// Purpose: PS-free end-to-end camera path of the Zybo wrapper: D-PHY pins, receiver, admission, capture, slot ownership and H.264 encode.
// Overview: the D-PHY transmitter model of the camera receiver benches (ip/rtlnet_csi2_rx/testbench, behavioural front end) sends
//   CSI-2 RAW10 frames of 32 x 16 pixels on two lanes to the wrapper's camera pins; AXI-Lite GP master BFM and two AXI3 HP byte-memory
//   slaves replace PS7. The capture DMA and the encoder (64-bit masters) are connected to the slaves directly, no bridge.
//   The HP slave model rejects what an AXI3 HP port rejects or what breaks the project's burst rules: a burst that is not INCR or not 8
//   bytes per beat, a burst across 4 KiB, WID different from AWID, WLAST wrong (W data is accepted only after its AW), an AWID or ARID with bits above the
//   encoder's 4-bit ID, a burst of fewer than 8 beats other than the encoder ring's end-of-slice tail, and (through taps on the
//   masters' 8-bit length fields, which the 4-bit AXI3 port would truncate) a burst of more than 16 beats; a hash of the memory bytes
//   written is printed. The frames are diagonal ramps (raw value 4 * (base + x + y)) that the receiver's bilinear demosaic reproduces
//   exactly in the interior, so the stored luma of every interior pixel is known.
//   Five frames in the 1080p mode prove alternate admission (3 of 5 admitted, held slot unchanged); the stored frame is checked for
//   geometry (32 x 16, every interior pixel) and neutral chroma; two frames in the 720p mode prove that every frame is admitted.
//   The receiver counters read back over AXI-Lite (frames received, every error counter zero). One real lossy/deblocked IDR encode dumps
//   Annex B and rebuilt YUV for the repository decoder comparison flow (scripts/check_board_encode.ps1).
// Plusargs: INJECT_FAILURE (the verdict fails), MUTATE (one raw pixel of the frame that is checked is changed on the wire; the
//   luma check must fail). Mutations of what the HP slave model sees (each must fail the bench through its own check): MUT_WID (one
//   WID changed), MUT_4K (one AW address moved to the last bytes of its page), MUT_LONG (one burst length seen as 17 beats at the
//   length tap), MUT_SHORT (one burst seen as a single beat), MUT_BEAT (one ARSIZE seen as 16 bytes per beat).
// Revision: 11-15-2026. Camera input through the receiver core, direct 64-bit HP connection. No foreach loops.
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
  import rtlnet_csi2_tb_pkg::*;
  import rtlnet_zybo_tb_memory::*;
  logic ctrl_clk = 0;
  logic enc_clk = 0;
  logic ctrl_resetn = 0;
  logic capture_resetn = 0;
  logic enc_resetn = 0;
  always #10 ctrl_clk = ~ctrl_clk;
  // One 90 MHz video clock drives the camera receiver, capture and encoder.
  always #5.555 enc_clk = ~enc_clk;
  logic ref_clk = 0;
  always #2.5 ref_clk = ~ref_clk;   // 200 MHz delay reference
  logic clk_p, clk_n;
  logic [1:0] dat_p, dat_n, lp_clk, lp_d0, lp_d1;
  rtlnet_csi2_tb_phy tx (.clk_p(clk_p), .clk_n(clk_n), .dat_p(dat_p), .dat_n(dat_n), .lp_clk(lp_clk), .lp_d0(lp_d0), .lp_d1(lp_d1));
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
  rtlnet_zybo_video #(.DPHY_TARGET("GENERIC"), .WIDTH_720(32), .HEIGHT_720(16), .WIDTH_1080(32), .HEIGHT_1080(16)) dut (
    .s_axi_aclk(ctrl_clk),
    .s_axi_aresetn(ctrl_resetn),
    .capture_clk(enc_clk),
    .capture_resetn(capture_resetn),
    .enc_clk(enc_clk),
    .enc_resetn(enc_resetn),
    .ref_clk(ref_clk),
    .dphy_hs_clock_clk_p(clk_p),
    .dphy_hs_clock_clk_n(clk_n),
    .dphy_clk_lp_p(lp_clk[1]),
    .dphy_clk_lp_n(lp_clk[0]),
    .dphy_data_hs_p(dat_p),
    .dphy_data_hs_n(dat_n),
    .dphy_data_lp_p({lp_d1[1], lp_d0[1]}),
    .dphy_data_lp_n({lp_d1[0], lp_d0[0]}),
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
  rtlnet_zybo_tb_hp #(.NAME("capture")) mem_cap (.clk(enc_clk), .resetn(capture_resetn),
    .awlen_wide(dut.cap_awlen),
    .arlen_wide(8'd0),
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
  rtlnet_zybo_tb_hp #(.NAME("encoder")) mem_enc (.clk(enc_clk), .resetn(enc_resetn),
    .awlen_wide(dut.enc_awlen),
    .arlen_wide(dut.enc_arlen),
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

  localparam logic [31:0] RX = 32'h44a09000;
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
  logic [1:0] rd_resp;
  // Hash of the whole byte store (to compare runs).
  function automatic longint unsigned mem_hash();
    longint unsigned h;
    h = 64'hCBF2_9CE4_8422_2325;
    for (int i=0;i<1048576;i++) h = (h ^ longint'(mem[i])) * 64'h0000_0100_0000_01B3;
    return h;
  endfunction

  always @(posedge ctrl_clk) if (ctrl_resetn && irq[0]) capture_irqs++;

  bit mutate = 1'b0;
  // One CSI-2 frame: frame start, 16 lines of 32 RAW10 pixels (diagonal ramp 4 * (base + x + y)), frame end. A line number in
  // mutate_line (>= 0) gets one raw pixel changed on the wire.
  task automatic send_frame(input integer seed, input real ui, input integer mutate_line);
    pix_q_t px;
    integer base;
    base = 40 + 20 * seed;
    tx.ui_ns = ui;
    tx.send_packet(short_pkt(2'd0, 6'h00, 16'(seed + 1)));
    for (int y = 0; y < 16; y++) begin
      px.delete();
      for (int x = 0; x < 32; x++) px.push_back(10'(4 * (base + x + y)));
      if (y == mutate_line) px[8] = px[8] ^ 10'h100;
      tx.send_packet(long_pkt(2'd0, 6'h2B, raw10_payload(px)));
    end
    tx.send_packet(short_pkt(2'd0, 6'h01, 16'(seed + 1)));
    #30000;   // frame gap: the receiver cannot be stalled, the capture path finishes the frame before the next one starts
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
               dut.fb_req,dut.fb_rsp_valid,dut.fb_rsp_ok,dut.pair_valid,dut.pair_ready,
               dut.frame_width,dut.frame_height);
      tb_verdict("tb_rtlnet_zybo_video");
    end
  endtask

  initial begin
    if (!$value$plusargs("OUT=%s",out_prefix)) out_prefix="board";
    mutate = $test$plusargs("MUTATE");
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
    cpu.rd(CAM+32'h04,v); tb_check(v==32'h11152026,"camera block VERSION");
    cpu.rd(RX,v); tb_check(v==32'h43534932,"receiver core ID");
    cpu.rd(RX+32'h04,v); tb_check(v==32'h11152026,"receiver core VERSION (camera receiver present)");
    cpu.wr(RX+32'h10,1);    // receiver geometry of the 1080p mode (32 x 16 in this bench)
    cpu.wr(RX+32'h14,1);    // camera source only
    cpu.wr(DMA+32'h14,128);
    cpu.wr(CAM+32'h10,1);   // 1080p mode (geometry shrunk to 32x16 here): the sensor runs 30 fps, every second frame is admitted
    cpu.rd(CAM+32'h18,v); tb_check(v==6000,"1080p admission PTS step 6000 (15 fps stream)");
    cpu.wr(CAM+32'h0c,1);
    #20000;
    send_frame(0, 2.381, -1);                      // 420 Mb/s per lane (1080p sensor mode)
    send_frame(1, 2.381, -1);
    send_frame(2, 2.381, mutate ? 5 : -1);         // the frame that is stored and checked
    wait_published(2);
    cpu.wr(FB+32'h0c,1);
    cpu.rd(FB+32'h10,v); tb_check(v[1],"firmware holds a slot");
    cpu.rd(FB+32'h40,slot);
    cpu.rd(FB+32'h44,v); tb_check(v==2,"admitted frame sequence advances at 30 fps");
    cpu.rd(FB+32'h48,stamp); tb_check(stamp!=0,"capture timestamp is populated");
    cpu.rd(FB+32'h4c,v); tb_check(v==32'h00100020,"captured 32x16 geometry");
    for (int k=0;k<1024;k++) snapshot[k]=mem[address(slot+(k/64)*128+(k%64))];
    for (int y=1;y<15;y++) begin
      for (int x=1;x<31;x++) begin
        expected_y=$rtoi($floor(16.0 + 219.0*(80+x+y)/255.0 + 0.5));
        actual_y=snapshot[(y*32+x)*2];
        tb_check(actual_y>=expected_y-1 && actual_y<=expected_y+1,"stored luma of every interior pixel (geometry and content)");
        tb_check(snapshot[(y*32+x)*2+1]>=127 && snapshot[(y*32+x)*2+1]<=129,"stored chroma neutral");
      end
    end
    send_frame(3, 2.381, -1);
    send_frame(4, 2.381, -1);
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
    cpu.wr(RX+32'h10,0);
    send_frame(5, 3.571, -1);                      // 280 Mb/s per lane (720p sensor mode)
    send_frame(6, 3.571, -1);
    cpu.rd(CAM+32'h20,v); tb_check(v==7,"seven camera frames observed in total");
    cpu.rd(CAM+32'h24,v); tb_check(v==5,"720p admits every frame (two more admitted)");
    // The receiver counters: seven frame starts, no error counter.
    cpu.rd(RX+32'h60+4*4,v); tb_check(v==7,"receiver FRAMES counter");
    for (int n=0;n<12;n++) begin
      if (n!=4) begin
        cpu.rd(RX+32'h60+4*n,v);
        tb_check(v==0,$sformatf("receiver error counter %0d is zero",n));
      end
    end
    // The unmapped window 0x44A0_4000 (the arbiter window of earlier boards) answers DECERR.
    cpu.read32(32'h44a04000, v, rd_resp);
    tb_check(rd_resp==2'b11,"unmapped window 0x44A04000 answers DECERR");
    mem_cap.report();
    mem_enc.report();
    tb_check(mem_cap.aw_bursts>0 && mem_enc.aw_bursts>0 && mem_enc.ar_bursts>0,"both HP ports carried write bursts and the encoder read bursts");
    tb_check(mem_cap.short_bursts==0 && mem_enc.short_bursts==0,"no burst of fewer than 8 beats except the ring tail");
    $display("MEMBYTES %016x", mem_hash());
    tb_verdict("tb_rtlnet_zybo_video");
  end
  initial begin
    #20000000;
    tb_error("board watchdog");
    tb_verdict("tb_rtlnet_zybo_video");
  end
endmodule

// PS HP slave model: per-port AXI3 ordering with a shared physical DDR byte store; checks the burst shape, the 4 KiB rule, WID, the beat count and the
// length taps of the master; NAME tags the messages.
module rtlnet_zybo_tb_hp #(
  parameter string NAME = "hp"
) (
  input logic clk,
  input logic resetn,
  // Taps on the masters' own 8-bit length fields (before the 4-bit port truncates them).
  input logic [7:0] awlen_wide,
  input logic [7:0] arlen_wide,
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
  integer aw_bursts=0;
  integer ar_bursts=0;
  integer short_bursts=0;
  integer aw_hist [0:16];
  integer ar_hist [0:16];
  bit mut_wid, mut_4k, mut_long, mut_short, mut_beat;
  bit mut_wid_done=0, mut_4k_done=0, mut_long_done=0, mut_short_done=0, mut_beat_done=0;
  initial begin
    mut_wid = $test$plusargs("MUT_WID");
    mut_4k = $test$plusargs("MUT_4K");
    mut_long = $test$plusargs("MUT_LONG");
    mut_short = $test$plusargs("MUT_SHORT");
    mut_beat = $test$plusargs("MUT_BEAT");
    for (int i=0;i<17;i++) begin aw_hist[i]=0; ar_hist[i]=0; end
  end
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
  task automatic report();
    string line;
    line = {NAME, " HP port write bursts by beats:"};
    for (int i=1;i<=16;i++) if (aw_hist[i]!=0) line = {line, $sformatf(" %0d:%0d", i, aw_hist[i])};
    $display("%s", line);
    line = {NAME, " HP port read bursts by beats:"};
    for (int i=1;i<=16;i++) if (ar_hist[i]!=0) line = {line, $sformatf(" %0d:%0d", i, ar_hist[i])};
    $display("%s", line);
  endtask
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
        logic [31:0] a_seen;
        integer beats_seen;
        integer wide_seen;
        a_seen = awaddr;
        beats_seen = awlen+1;
        wide_seen = awlen_wide+1;
        if (mut_4k && !mut_4k_done) begin a_seen = {awaddr[31:12], 12'hFF8}; mut_4k_done=1; end
        if (mut_long && !mut_long_done) begin wide_seen = 17; mut_long_done=1; end
        if (mut_short && !mut_short_done) begin beats_seen = 1; mut_short_done=1; end
        tb_check(awburst==1,$sformatf("HP %s write burst type %0d is not INCR",NAME,awburst));
        tb_check(awsize==3,$sformatf("HP %s write beat size %0d is not 8 bytes",NAME,awsize));
        tb_check(a_seen[2:0]==0,"HP write address is 8-byte aligned");
        tb_check(a_seen[11:0]+beats_seen*8<=4096,$sformatf("HP %s write crosses a 4 KiB boundary",NAME));
        tb_check(wide_seen<=16,$sformatf("HP %s write burst of %0d beats at the master (AXI3 limit 16)",NAME,wide_seen));
        tb_check(awid[5:4]==0,"HP write ID uses the 4 encoder ID bits");
        tb_check(beats_seen>1,$sformatf("HP %s single-beat write burst",NAME));
        // Fewer than 8 beats only as the encoder's end-of-slice ring tail (AWID 0, an even number of beats: whole 16-byte words of the 128-bit requester).
        if (beats_seen<8 && !(awid[3:0]==0 && (beats_seen%2)==0 && NAME=="encoder")) short_bursts++;
        aw_bursts++;
        aw_hist[beats_seen]++;
        wa=awaddr; wi=awid; wn=awlen+1; writing=1;
      end
      if (wvalid && wready) begin
        logic [5:0] wid_seen;
        wid_seen = wid;
        if (mut_wid && !mut_wid_done) begin wid_seen = wid ^ 6'd1; mut_wid_done=1; end
        tb_check(wid_seen==wi,$sformatf("HP %s WID",NAME));
        tb_check(wlast==(wn==1),"HP WLAST");
        for (int k=0;k<8;k++) if(wstrb[k]) mem[address(wa+k)]=wdata[k*8 +:8];
        wa+=8; wn--;
        if (wn==0) begin writing=0; bid<=wi; bresp<=0; bvalid<=1; end
      end
      if (arvalid && arready) begin
        logic [2:0] size_seen;
        integer wide_r;
        integer beats_r;
        size_seen = arsize;
        wide_r = arlen_wide+1;
        beats_r = arlen+1;
        if (mut_beat && !mut_beat_done) begin size_seen = 3'd4; mut_beat_done=1; end
        tb_check(arburst==1,$sformatf("HP %s read burst type %0d is not INCR",NAME,arburst));
        tb_check(size_seen==3,$sformatf("HP %s read beat size %0d is not 8 bytes",NAME,size_seen));
        tb_check(araddr[11:0]+beats_r*8<=4096,$sformatf("HP %s read crosses a 4 KiB boundary",NAME));
        tb_check(wide_r<=16,$sformatf("HP %s read burst of %0d beats at the master (AXI3 limit 16)",NAME,wide_r));
        tb_check(arid[5:4]==0,"HP read ID uses the 4 encoder ID bits");
        tb_check(beats_r>1,$sformatf("HP %s single-beat read burst",NAME));
        if (beats_r<8) short_bursts++;
        ar_bursts++;
        ar_hist[beats_r]++;
        ra=araddr; ri=arid; rn=arlen+1; reading=1;
      end else if (rvalid && rready) begin
        ra+=8; rn--;
        if(rn==0) reading=0;
      end
    end
  end
endmodule
