// Purpose: integrate the IronKernel CSI-2 camera receiver, capture and one Baseline H.264 engine with PS HP ports.
// Overview: the receiver (rtlnet_csi2_rx, CAMERA_RX = 1) takes the camera D-PHY pins and delivers YUV422 pairs at capture_clk;
//   the camera admission below selects the frames (720p every frame, 1080p every second frame), the capture DMA writes them to DDR
//   frames and the encoder reads completed DDR frames at enc_clk. Software owns framebuf's firmware-reader handshake.
//   The capture DMA and the encoder are 64-bit masters (AXI_DATA_W 64): each connects straight to its HP port, no bridge and no
//   arbiter. The masters issue bursts of at most 16 beats (AWLEN and ARLEN are 4 bits on AXI3), WID is AWID, and the two
//   IDs are zero-extended to the 6 bits of the port.
//   GP0 AXI-Lite decodes five 4 KiB windows at 0x44A0_5000..0x44A0_9000 (receiver at 0x44A0_9000); 0x44A0_4000 is unmapped (DECERR).
//   Camera register contract is cpu/zynq7_h264/firmware/src/rtlnet_camera.h.
//   Capture IRQ is an edge pulse at s_axi_aclk, encoder IRQ a synchronized level.
//   Frame events are separated by at least 16 ms (>4 control clocks), satisfying
//   the open-loop pulse synchronizer's minimum spacing. Resets assert together.
// Language: SystemVerilog-2012.
// Revision: 11-15-2026.
module rtlnet_zybo_video #(
  parameter string DPHY_TARGET = "AMD",   // bench only: any other value selects the behavioural D-PHY front end; stays "AMD" in the board design
  parameter bit HIGH_PROFILE = 1'b0,
  parameter bit HP_T8 = 1'b1,
  parameter bit HP_T8_AUTO = 1'b1,
  parameter bit DEBLOCK = 1'b1,
  parameter int WIDTH_720 = 1280,
  parameter int HEIGHT_720 = 720,
  parameter int WIDTH_1080 = 1920,
  parameter int HEIGHT_1080 = 1080
) (
  // PS control clock 50 MHz and its synchronous active-low reset.
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn" *)
  input logic s_axi_aclk,
  input logic s_axi_aresetn,
  // Video clock (90 MHz, the same clock as enc_clk in the board design), receiver and capture HP bus; reset releases locally.
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXI_CAP, ASSOCIATED_RESET capture_resetn" *)
  input logic capture_clk,
  input logic capture_resetn,
  // Encoder clock 90 MHz and HP bus; reset releases locally.
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXI_ENC, ASSOCIATED_RESET enc_resetn" *)
  input logic enc_clk,
  input logic enc_resetn,
  // 200 MHz D-PHY delay reference and the camera pins (names equal the board pin constraints).
  (* X_INTERFACE_IGNORE = "true" *)
  input logic ref_clk,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic dphy_hs_clock_clk_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic dphy_hs_clock_clk_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic dphy_clk_lp_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic dphy_clk_lp_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic [1:0] dphy_data_hs_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic [1:0] dphy_data_hs_n,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic [1:0] dphy_data_lp_p,
  (* X_INTERFACE_IGNORE = "true" *)
  input logic [1:0] dphy_data_lp_n,
  // S_AXI AXI4LITE: explicit physical bus, with byte enables and response IDs.
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 32" *)
  input logic [31:0] s_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
  input logic s_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
  output logic s_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
  input logic [31:0] s_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
  input logic [3:0] s_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
  input logic s_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
  output logic s_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
  output logic [1:0] s_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
  output logic s_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
  input logic s_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
  input logic [31:0] s_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
  input logic s_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
  output logic s_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
  output logic [31:0] s_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
  output logic [1:0] s_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
  output logic s_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
  input logic s_axi_rready,
  // M_AXI_CAP AXI3: explicit physical bus, with byte enables and response IDs.
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP AWID" *)
  output logic [5:0] m_axi_cap_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP AWADDR" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI3, DATA_WIDTH 64, ADDR_WIDTH 32" *)
  output logic [31:0] m_axi_cap_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP AWLEN" *)
  output logic [3:0] m_axi_cap_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP AWSIZE" *)
  output logic [2:0] m_axi_cap_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP AWBURST" *)
  output logic [1:0] m_axi_cap_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP AWVALID" *)
  output logic m_axi_cap_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP AWREADY" *)
  input logic m_axi_cap_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP WID" *)
  output logic [5:0] m_axi_cap_wid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP WDATA" *)
  output logic [63:0] m_axi_cap_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP WSTRB" *)
  output logic [7:0] m_axi_cap_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP WLAST" *)
  output logic m_axi_cap_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP WVALID" *)
  output logic m_axi_cap_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP WREADY" *)
  input logic m_axi_cap_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP BID" *)
  input logic [5:0] m_axi_cap_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP BRESP" *)
  input logic [1:0] m_axi_cap_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP BVALID" *)
  input logic m_axi_cap_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP BREADY" *)
  output logic m_axi_cap_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP ARID" *)
  output logic [5:0] m_axi_cap_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP ARADDR" *)
  output logic [31:0] m_axi_cap_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP ARLEN" *)
  output logic [3:0] m_axi_cap_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP ARSIZE" *)
  output logic [2:0] m_axi_cap_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP ARBURST" *)
  output logic [1:0] m_axi_cap_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP ARVALID" *)
  output logic m_axi_cap_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP ARREADY" *)
  input logic m_axi_cap_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP RID" *)
  input logic [5:0] m_axi_cap_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP RDATA" *)
  input logic [63:0] m_axi_cap_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP RRESP" *)
  input logic [1:0] m_axi_cap_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP RLAST" *)
  input logic m_axi_cap_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP RVALID" *)
  input logic m_axi_cap_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_CAP RREADY" *)
  output logic m_axi_cap_rready,
  // M_AXI_ENC AXI3: explicit physical bus, with byte enables and response IDs.
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC AWID" *)
  output logic [5:0] m_axi_enc_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC AWADDR" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI3, DATA_WIDTH 64, ADDR_WIDTH 32" *)
  output logic [31:0] m_axi_enc_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC AWLEN" *)
  output logic [3:0] m_axi_enc_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC AWSIZE" *)
  output logic [2:0] m_axi_enc_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC AWBURST" *)
  output logic [1:0] m_axi_enc_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC AWVALID" *)
  output logic m_axi_enc_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC AWREADY" *)
  input logic m_axi_enc_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC WID" *)
  output logic [5:0] m_axi_enc_wid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC WDATA" *)
  output logic [63:0] m_axi_enc_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC WSTRB" *)
  output logic [7:0] m_axi_enc_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC WLAST" *)
  output logic m_axi_enc_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC WVALID" *)
  output logic m_axi_enc_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC WREADY" *)
  input logic m_axi_enc_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC BID" *)
  input logic [5:0] m_axi_enc_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC BRESP" *)
  input logic [1:0] m_axi_enc_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC BVALID" *)
  input logic m_axi_enc_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC BREADY" *)
  output logic m_axi_enc_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC ARID" *)
  output logic [5:0] m_axi_enc_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC ARADDR" *)
  output logic [31:0] m_axi_enc_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC ARLEN" *)
  output logic [3:0] m_axi_enc_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC ARSIZE" *)
  output logic [2:0] m_axi_enc_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC ARBURST" *)
  output logic [1:0] m_axi_enc_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC ARVALID" *)
  output logic m_axi_enc_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC ARREADY" *)
  input logic m_axi_enc_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC RID" *)
  input logic [5:0] m_axi_enc_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC RDATA" *)
  input logic [63:0] m_axi_enc_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC RRESP" *)
  input logic [1:0] m_axi_enc_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC RLAST" *)
  input logic m_axi_enc_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC RVALID" *)
  input logic m_axi_enc_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_ENC RREADY" *)
  output logic m_axi_enc_rready,
  // GIC fabric inputs: bit 0 capture publication edge, bit 1 encoder level.
  (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
  (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
  output logic [1:0] irq
);
  logic [159:0] d_awaddr;
  logic [4:0] d_awvalid;
  logic [4:0] d_awready;
  logic [159:0] d_wdata;
  logic [19:0] d_wstrb;
  logic [4:0] d_wvalid;
  logic [4:0] d_wready;
  logic [9:0] d_bresp;
  logic [4:0] d_bvalid;
  logic [4:0] d_bready;
  logic [159:0] d_araddr;
  logic [4:0] d_arvalid;
  logic [4:0] d_arready;
  logic [159:0] d_rdata;
  logic [9:0] d_rresp;
  logic [4:0] d_rvalid;
  logic [4:0] d_rready;
  logic [29:0] cap_addr;
  logic [7:0] cap_awlen;
  logic [3:0] enc_awid;
  logic [7:0] enc_awlen;
  logic [3:0] enc_bid;
  logic [3:0] enc_arid;
  logic [7:0] enc_arlen;
  logic fb_req;
  logic fb_rsp_valid;
  logic fb_rsp_ok;
  logic [31:0] fb_rsp_base;
  logic fb_done;
  logic fb_done_good;
  logic [31:0] fb_done_frame_num;
  logic [31:0] fb_done_timestamp;
  logic [15:0] fb_done_width;
  logic [15:0] fb_done_height;
  logic fb_done_src_pattern;
  logic [31:0] pixel_pair;
  logic pair_valid;
  logic pair_ready;
  logic pair_sof;
  logic pair_eol;
  logic [31:0] adp_pair;
  logic adp_valid;
  logic adp_ready;
  logic adp_sof;
  logic adp_eol;
  logic [4:0] slice_keep_unused;
  logic [31:0] rx_tdata;
  logic rx_tvalid;
  logic rx_tready;
  logic rx_tlast;
  logic rx_tuser;
  logic [6:0] slice_data_unused;
  logic encoder_irq;
  logic camera_enable;
  logic camera_mode;
  logic skip_phase;
  logic frame_admit;
  logic admit;
  logic [31:0] frame_seq;
  logic [31:0] frame_timestamp;
  logic [31:0] capture_ticks;
  logic [7:0] capture_sub_us;
  logic [15:0] frame_width;
  logic [15:0] frame_height;
  logic cam_reg_wr;
  logic cam_reg_rd;
  logic [11:0] cam_reg_wa;
  logic [11:0] cam_reg_ra;
  logic [31:0] cam_reg_wd;
  logic [31:0] cam_reg_q;
  logic [31:0] frames_seen;
  logic [31:0] frames_admitted;
  logic [11:0] camreg_awaddr;
  logic camreg_awvalid;
  logic camreg_awready;
  logic [31:0] camreg_wdata;
  logic [3:0] camreg_wstrb;
  logic camreg_wvalid;
  logic camreg_wready;
  logic [1:0] camreg_bresp;
  logic camreg_bvalid;
  logic camreg_bready;
  logic [11:0] camreg_araddr;
  logic camreg_arvalid;
  logic camreg_arready;
  logic [31:0] camreg_rdata;
  logic [1:0] camreg_rresp;
  logic camreg_rvalid;
  logic camreg_rready;
  // u_decode implements rtlnet_axil_decoder in its explicitly connected clock domain.
  rtlnet_axil_decoder #(.N(5), .SLAVE_BASE({32'h44a09000,32'h44a08000,32'h44a07000,32'h44a06000,32'h44a05000}), .SLAVE_SIZE({5{32'h1000}})) u_decode (
    .aclk(s_axi_aclk),
    .aresetn(s_axi_aresetn),
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
    .m_axi_awaddr(d_awaddr),
    .m_axi_awvalid(d_awvalid),
    .m_axi_awready(d_awready),
    .m_axi_wdata(d_wdata),
    .m_axi_wstrb(d_wstrb),
    .m_axi_wvalid(d_wvalid),
    .m_axi_wready(d_wready),
    .m_axi_bresp(d_bresp),
    .m_axi_bvalid(d_bvalid),
    .m_axi_bready(d_bready),
    .m_axi_araddr(d_araddr),
    .m_axi_arvalid(d_arvalid),
    .m_axi_arready(d_arready),
    .m_axi_rdata(d_rdata),
    .m_axi_rresp(d_rresp),
    .m_axi_rvalid(d_rvalid),
    .m_axi_rready(d_rready)
  );
  // u_camera_cdc implements rtlnet_axil_cdc in its explicitly connected clock domain.
  rtlnet_axil_cdc #(.ADDR_W(12)) u_camera_cdc (
    .s_clk(s_axi_aclk),
    .s_resetn(s_axi_aresetn),
    .s_axi_awaddr(d_awaddr[0 +: 12]),
    .s_axi_awvalid(d_awvalid[0 +: 1]),
    .s_axi_awready(d_awready[0 +: 1]),
    .s_axi_wdata(d_wdata[0 +: 32]),
    .s_axi_wstrb(d_wstrb[0 +: 4]),
    .s_axi_wvalid(d_wvalid[0 +: 1]),
    .s_axi_wready(d_wready[0 +: 1]),
    .s_axi_bresp(d_bresp[0 +: 2]),
    .s_axi_bvalid(d_bvalid[0 +: 1]),
    .s_axi_bready(d_bready[0 +: 1]),
    .s_axi_araddr(d_araddr[0 +: 12]),
    .s_axi_arvalid(d_arvalid[0 +: 1]),
    .s_axi_arready(d_arready[0 +: 1]),
    .s_axi_rdata(d_rdata[0 +: 32]),
    .s_axi_rresp(d_rresp[0 +: 2]),
    .s_axi_rvalid(d_rvalid[0 +: 1]),
    .s_axi_rready(d_rready[0 +: 1]),
    .m_clk(capture_clk),
    .m_resetn(capture_resetn),
    .m_axi_awaddr(camreg_awaddr),
    .m_axi_awvalid(camreg_awvalid),
    .m_axi_awready(camreg_awready),
    .m_axi_wdata(camreg_wdata),
    .m_axi_wstrb(camreg_wstrb),
    .m_axi_wvalid(camreg_wvalid),
    .m_axi_wready(camreg_wready),
    .m_axi_bresp(camreg_bresp),
    .m_axi_bvalid(camreg_bvalid),
    .m_axi_bready(camreg_bready),
    .m_axi_araddr(camreg_araddr),
    .m_axi_arvalid(camreg_arvalid),
    .m_axi_arready(camreg_arready),
    .m_axi_rdata(camreg_rdata),
    .m_axi_rresp(camreg_rresp),
    .m_axi_rvalid(camreg_rvalid),
    .m_axi_rready(camreg_rready)
  );
  // u_camera_regs implements rtlnet_axil_slave in its explicitly connected clock domain.
  rtlnet_axil_slave #(.ADDR_W(12)) u_camera_regs (
    .s_axi_aclk(capture_clk),
    .s_axi_aresetn(capture_resetn),
    .s_axi_awaddr(camreg_awaddr[11:0]),
    .s_axi_awvalid(camreg_awvalid),
    .s_axi_awready(camreg_awready),
    .s_axi_wdata(camreg_wdata),
    .s_axi_wstrb(camreg_wstrb),
    .s_axi_wvalid(camreg_wvalid),
    .s_axi_wready(camreg_wready),
    .s_axi_bresp(camreg_bresp),
    .s_axi_bvalid(camreg_bvalid),
    .s_axi_bready(camreg_bready),
    .s_axi_araddr(camreg_araddr[11:0]),
    .s_axi_arvalid(camreg_arvalid),
    .s_axi_arready(camreg_arready),
    .s_axi_rdata(camreg_rdata),
    .s_axi_rresp(camreg_rresp),
    .s_axi_rvalid(camreg_rvalid),
    .s_axi_rready(camreg_rready),
    .reg_wr_en(cam_reg_wr),
    .reg_wr_addr(cam_reg_wa),
    .reg_wr_data(cam_reg_wd),
    .reg_rd_en(cam_reg_rd),
    .reg_rd_addr(cam_reg_ra),
    .reg_rd_data(cam_reg_q)
  );
  // 720p (mode 0): the sensor runs 30 fps and every frame is admitted; 1080p (mode 1): the sensor runs 30 fps and every second frame is admitted (15 fps).
  assign admit = rx_tuser ? (camera_enable && (!camera_mode || !skip_phase)) : frame_admit;
  assign rx_tready = !admit || adp_ready;
  // Camera configuration and metadata live in the capture domain behind a whole-transaction CDC.
  always_ff @(posedge capture_clk) begin
    if (!capture_resetn) begin
      camera_enable <= 1'b0;
      camera_mode <= 1'b0;
      skip_phase <= 1'b0;
      frame_admit <= 1'b0;
      frame_seq <= '0;
      frame_timestamp <= '0;
      frame_width <= WIDTH_720;
      frame_height <= HEIGHT_720;
      capture_ticks <= '0;
      capture_sub_us <= '0;
      frames_seen <= '0;
      frames_admitted <= '0;
      cam_reg_q <= '0;
    end else begin
      if (capture_sub_us == 89) begin
        capture_sub_us <= '0;
        capture_ticks <= capture_ticks + 1'b1;
      end else capture_sub_us <= capture_sub_us + 1'b1;
      if (cam_reg_wr && cam_reg_wa == 12'h00c) camera_enable <= cam_reg_wd[0];
      if (cam_reg_wr && cam_reg_wa == 12'h010 && cam_reg_wd < 2) camera_mode <= cam_reg_wd[0];
      if (rx_tvalid && rx_tready && rx_tuser) begin
        frames_seen <= frames_seen + 1'b1;
        skip_phase <= !skip_phase;
        frame_admit <= admit;
        if (admit) begin
          frame_seq <= frame_seq + 1'b1;
          frames_admitted <= frames_admitted + 1'b1;
          frame_timestamp <= capture_ticks;
          frame_width <= camera_mode ? WIDTH_1080 : WIDTH_720;
          frame_height <= camera_mode ? HEIGHT_1080 : HEIGHT_720;
        end
      end
      if (cam_reg_rd) begin
        case (cam_reg_ra)
          12'h000: cam_reg_q <= 32'h5a43414d;
          12'h004: cam_reg_q <= 32'h11152026;
          12'h008: cam_reg_q <= 32'h00000002;
          12'h00c: cam_reg_q <= {31'd0, camera_enable};
          12'h010: cam_reg_q <= {31'd0, camera_mode};
          12'h018: cam_reg_q <= camera_mode ? 32'd6000 : 32'd3000;
          12'h020: cam_reg_q <= frames_seen;
          12'h024: cam_reg_q <= frames_admitted;
          default: cam_reg_q <= '0;
        endcase
      end
    end
  end
  // u_rx is the IronKernel CSI-2 camera receiver (rtlnet_csi2_rx, CAMERA_RX = 1): D-PHY pins in, YUV422 pairs out in capture_clk.
  // It cannot be stalled: its byte-clock FIFO drops and counts entries when the capture path is not ready (OVF counter).
  // The camera admission above discards the frames that are not admitted (ready high), so a skipped frame never stalls it.
  // Register window 0x44A0_9000 (index 5 of u_decode); the window has its own clock crossing inside the core.
  assign adp_valid = rx_tvalid && admit;
  assign adp_pair = rx_tdata;
  assign adp_sof = rx_tuser;
  assign adp_eol = rx_tlast;
  rtlnet_csi2_rx #(.CAMERA_RX(1'b1), .DPHY_TARGET(DPHY_TARGET), .NONCONT_CLOCK(1'b0), .IDELAYCTRL_INST(1'b1), .HS_DIFF_TERM(1'b0),
                     .WIDTH_720(WIDTH_720), .HEIGHT_720(HEIGHT_720), .WIDTH_1080(WIDTH_1080), .HEIGHT_1080(HEIGHT_1080)) u_rx (
    .clk(capture_clk),
    .resetn(capture_resetn),
    .s_axi_aclk(s_axi_aclk),
    .s_axi_aresetn(s_axi_aresetn),
    .s_cam_tdata(32'd0),
    .s_cam_tvalid(1'b0),
    .s_cam_tready(),
    .s_cam_tlast(1'b0),
    .s_cam_tuser(1'b0),
    .cam_clk_running(1'b0),
    .ref_clk(ref_clk),
    .dphy_clk_p(dphy_hs_clock_clk_p),
    .dphy_clk_n(dphy_hs_clock_clk_n),
    .dphy_clk_lp_p(dphy_clk_lp_p),
    .dphy_clk_lp_n(dphy_clk_lp_n),
    .dphy_dat_p(dphy_data_hs_p),
    .dphy_dat_n(dphy_data_hs_n),
    .dphy_dat_lp_p(dphy_data_lp_p),
    .dphy_dat_lp_n(dphy_data_lp_n),
    .m_axis_tdata(rx_tdata),
    .m_axis_tvalid(rx_tvalid),
    .m_axis_tready(rx_tready),
    .m_axis_tlast(rx_tlast),
    .m_axis_tuser(rx_tuser),
    .m_frame_num(),
    .m_timestamp(),
    .m_width(),
    .m_height(),
    .m_src_pattern(),
    .s_axi_awaddr(d_awaddr[128 +: 12]),
    .s_axi_awvalid(d_awvalid[4 +: 1]),
    .s_axi_awready(d_awready[4 +: 1]),
    .s_axi_wdata(d_wdata[128 +: 32]),
    .s_axi_wstrb(d_wstrb[16 +: 4]),
    .s_axi_wvalid(d_wvalid[4 +: 1]),
    .s_axi_wready(d_wready[4 +: 1]),
    .s_axi_bresp(d_bresp[8 +: 2]),
    .s_axi_bvalid(d_bvalid[4 +: 1]),
    .s_axi_bready(d_bready[4 +: 1]),
    .s_axi_araddr(d_araddr[128 +: 12]),
    .s_axi_arvalid(d_arvalid[4 +: 1]),
    .s_axi_arready(d_arready[4 +: 1]),
    .s_axi_rdata(d_rdata[128 +: 32]),
    .s_axi_rresp(d_rresp[8 +: 2]),
    .s_axi_rvalid(d_rvalid[4 +: 1]),
    .s_axi_rready(d_rready[4 +: 1])
  );
  // The capture FIFO state must not reach the receiver pipeline combinationally (the admission ready of the pairs would fan out
  // through the receiver's clock enables): u_pair_slice ends that path at a flop.
  // SOF travels with the data in bit 32; bits 39:33 are zero. One extra clock of latency.
  rtlnet_axis_reg_slice #(.DATA_W(40), .RESET_DATA(1'b1)) u_pair_slice (
    .clk(capture_clk),
    .resetn(capture_resetn),
    .s_tdata({7'd0, adp_sof, adp_pair}),
    .s_tkeep(5'h1f),
    .s_tlast(adp_eol),
    .s_tvalid(adp_valid),
    .s_tready(adp_ready),
    .m_tdata({slice_data_unused, pair_sof, pixel_pair}),
    .m_tkeep(slice_keep_unused),
    .m_tlast(pair_eol),
    .m_tvalid(pair_valid),
    .m_tready(pair_ready)
  );
  // Capture uses 30 address bits to avoid the existing core's 32-bit shift overflow in cfg_ok.
  assign m_axi_cap_awaddr = {2'b0, cap_addr};
  // u_capture implements rtlnet_vdma_s2mm in its explicitly connected clock domain, 64-bit beats of at most 16 per burst: it drives
  // the HP2 port directly. The master has no read channel (the read channel of the port is idle); WID is AWID (constant 0).
  rtlnet_vdma_s2mm #(.ADDR_W(30), .ID_W(6), .AXI_DATA_W(64), .MAX_BURST_BEATS(16)) u_capture (
    .clk(capture_clk),
    .resetn(capture_resetn),
    .s_axi_aclk(s_axi_aclk),
    .s_axi_aresetn(s_axi_aresetn),
    .s_axis_tdata(pixel_pair),
    .s_axis_tvalid(pair_valid),
    .s_axis_tready(pair_ready),
    .s_axis_tlast(pair_eol),
    .s_axis_tuser(pair_sof),
    .s_width(frame_width),
    .s_height(frame_height),
    .s_frame_num(frame_seq),
    .s_timestamp(frame_timestamp),
    .s_src_pattern(1'b0),
    .fb_req(fb_req),
    .fb_rsp_valid(fb_rsp_valid),
    .fb_rsp_ok(fb_rsp_ok),
    .fb_rsp_base(fb_rsp_base[29:0]),
    .fb_done(fb_done),
    .fb_done_good(fb_done_good),
    .fb_done_frame_num(fb_done_frame_num),
    .fb_done_timestamp(fb_done_timestamp),
    .fb_done_width(fb_done_width),
    .fb_done_height(fb_done_height),
    .fb_done_src_pattern(fb_done_src_pattern),
    .m_axi_awid(m_axi_cap_awid),
    .m_axi_awaddr(cap_addr),
    .m_axi_awlen(cap_awlen),
    .m_axi_awsize(m_axi_cap_awsize),
    .m_axi_awburst(m_axi_cap_awburst),
    .m_axi_awvalid(m_axi_cap_awvalid),
    .m_axi_awready(m_axi_cap_awready),
    .m_axi_wdata(m_axi_cap_wdata),
    .m_axi_wstrb(m_axi_cap_wstrb),
    .m_axi_wlast(m_axi_cap_wlast),
    .m_axi_wvalid(m_axi_cap_wvalid),
    .m_axi_wready(m_axi_cap_wready),
    .m_axi_bid(m_axi_cap_bid),
    .m_axi_bresp(m_axi_cap_bresp),
    .m_axi_bvalid(m_axi_cap_bvalid),
    .m_axi_bready(m_axi_cap_bready),
    .s_axi_awaddr(d_awaddr[32 +: 12]),
    .s_axi_awvalid(d_awvalid[1 +: 1]),
    .s_axi_awready(d_awready[1 +: 1]),
    .s_axi_wdata(d_wdata[32 +: 32]),
    .s_axi_wstrb(d_wstrb[4 +: 4]),
    .s_axi_wvalid(d_wvalid[1 +: 1]),
    .s_axi_wready(d_wready[1 +: 1]),
    .s_axi_bresp(d_bresp[2 +: 2]),
    .s_axi_bvalid(d_bvalid[1 +: 1]),
    .s_axi_bready(d_bready[1 +: 1]),
    .s_axi_araddr(d_araddr[32 +: 12]),
    .s_axi_arvalid(d_arvalid[1 +: 1]),
    .s_axi_arready(d_arready[1 +: 1]),
    .s_axi_rdata(d_rdata[32 +: 32]),
    .s_axi_rresp(d_rresp[2 +: 2]),
    .s_axi_rvalid(d_rvalid[1 +: 1]),
    .s_axi_rready(d_rready[1 +: 1])
  );
  // u_framebuf implements rtlnet_framebuf in its explicitly connected clock domain.
  rtlnet_framebuf #(.ADDR_W(32), .N(3), .NUM_READERS(1)) u_framebuf (
    .clk(capture_clk),
    .resetn(capture_resetn),
    .s_axi_aclk(s_axi_aclk),
    .s_axi_aresetn(s_axi_aresetn),
    .w_req(fb_req),
    .w_rsp_valid(fb_rsp_valid),
    .w_rsp_ok(fb_rsp_ok),
    .w_rsp_base(fb_rsp_base),
    .w_done(fb_done),
    .w_done_good(fb_done_good),
    .w_done_frame_num(fb_done_frame_num),
    .w_done_timestamp(fb_done_timestamp),
    .w_done_width(fb_done_width),
    .w_done_height(fb_done_height),
    .w_done_src_pattern(fb_done_src_pattern),
    .r_take(1'b0),
    .r_release(1'b0),
    .r_rsp_valid(),
    .r_rsp_ok(),
    .r_holds(),
    .r_slot(),
    .r_base(),
    .r_frame_num(),
    .r_timestamp(),
    .r_width(),
    .r_height(),
    .r_src_pattern(),
    .s_axi_awaddr(d_awaddr[64 +: 12]),
    .s_axi_awvalid(d_awvalid[2 +: 1]),
    .s_axi_awready(d_awready[2 +: 1]),
    .s_axi_wdata(d_wdata[64 +: 32]),
    .s_axi_wstrb(d_wstrb[8 +: 4]),
    .s_axi_wvalid(d_wvalid[2 +: 1]),
    .s_axi_wready(d_wready[2 +: 1]),
    .s_axi_bresp(d_bresp[4 +: 2]),
    .s_axi_bvalid(d_bvalid[2 +: 1]),
    .s_axi_bready(d_bready[2 +: 1]),
    .s_axi_araddr(d_araddr[64 +: 12]),
    .s_axi_arvalid(d_arvalid[2 +: 1]),
    .s_axi_arready(d_arready[2 +: 1]),
    .s_axi_rdata(d_rdata[64 +: 32]),
    .s_axi_rresp(d_rresp[4 +: 2]),
    .s_axi_rvalid(d_rvalid[2 +: 1]),
    .s_axi_rready(d_rready[2 +: 1])
  );
  // u_encoder implements rtlnet_h264_top in its explicitly connected clock domain.
  rtlnet_h264_top #(.NUM_ENGINES(1), .ID_W(4), .AXI_DATA_W(64), .HIGH_PROFILE(HIGH_PROFILE), .HP_T8(HP_T8), .HP_T8_AUTO(HP_T8_AUTO), .DEBLOCK(DEBLOCK)) u_encoder (
    .enc_clk(enc_clk),
    .enc_resetn(enc_resetn),
    .s_axi_aclk(s_axi_aclk),
    .s_axi_aresetn(s_axi_aresetn),
    .s_axi_awaddr(d_awaddr[96 +: 12]),
    .s_axi_awvalid(d_awvalid[3 +: 1]),
    .s_axi_awready(d_awready[3 +: 1]),
    .s_axi_wdata(d_wdata[96 +: 32]),
    .s_axi_wstrb(d_wstrb[12 +: 4]),
    .s_axi_wvalid(d_wvalid[3 +: 1]),
    .s_axi_wready(d_wready[3 +: 1]),
    .s_axi_bresp(d_bresp[6 +: 2]),
    .s_axi_bvalid(d_bvalid[3 +: 1]),
    .s_axi_bready(d_bready[3 +: 1]),
    .s_axi_araddr(d_araddr[96 +: 12]),
    .s_axi_arvalid(d_arvalid[3 +: 1]),
    .s_axi_arready(d_arready[3 +: 1]),
    .s_axi_rdata(d_rdata[96 +: 32]),
    .s_axi_rresp(d_rresp[6 +: 2]),
    .s_axi_rvalid(d_rvalid[3 +: 1]),
    .s_axi_rready(d_rready[3 +: 1]),
    .m_axi_awid(enc_awid),
    .m_axi_awaddr(m_axi_enc_awaddr),
    .m_axi_awlen(enc_awlen),
    .m_axi_awsize(m_axi_enc_awsize),
    .m_axi_awburst(m_axi_enc_awburst),
    .m_axi_awvalid(m_axi_enc_awvalid),
    .m_axi_awready(m_axi_enc_awready),
    .m_axi_wdata(m_axi_enc_wdata),
    .m_axi_wstrb(m_axi_enc_wstrb),
    .m_axi_wlast(m_axi_enc_wlast),
    .m_axi_wvalid(m_axi_enc_wvalid),
    .m_axi_wready(m_axi_enc_wready),
    .m_axi_bid(enc_bid),
    .m_axi_bresp(m_axi_enc_bresp),
    .m_axi_bvalid(m_axi_enc_bvalid),
    .m_axi_bready(m_axi_enc_bready),
    .m_axi_arid(enc_arid),
    .m_axi_araddr(m_axi_enc_araddr),
    .m_axi_arlen(enc_arlen),
    .m_axi_arsize(m_axi_enc_arsize),
    .m_axi_arburst(m_axi_enc_arburst),
    .m_axi_arvalid(m_axi_enc_arvalid),
    .m_axi_arready(m_axi_enc_arready),
    .m_axi_rdata(m_axi_enc_rdata),
    .m_axi_rresp(m_axi_enc_rresp),
    .m_axi_rlast(m_axi_enc_rlast),
    .m_axi_rvalid(m_axi_enc_rvalid),
    .m_axi_rready(m_axi_enc_rready),
    .irq(encoder_irq)
  );
  // HP port glue: the encoder IDs (4 bits) are zero-extended to the 6 bits of the port, WID equals AWID, the AXI3 length fields are the low four
  // bits (the masters never issue more than 16 beats; the simulation check below reports a longer burst). The capture master drives a 6-bit AWID
  // of constant 0 and has no read channel, whose port signals are idle.
  assign enc_bid = m_axi_enc_bid[3:0];
  assign m_axi_enc_awid = {2'b00, enc_awid};
  assign m_axi_enc_wid = {2'b00, enc_awid};
  assign m_axi_enc_awlen = enc_awlen[3:0];
  assign m_axi_enc_arid = {2'b00, enc_arid};
  assign m_axi_enc_arlen = enc_arlen[3:0];
  assign m_axi_cap_wid = m_axi_cap_awid;
  assign m_axi_cap_awlen = cap_awlen[3:0];
  assign m_axi_cap_arid = '0;
  assign m_axi_cap_araddr = '0;
  assign m_axi_cap_arlen = '0;
  assign m_axi_cap_arsize = 3'd3;
  assign m_axi_cap_arburst = 2'b01;
  assign m_axi_cap_arvalid = 1'b0;
  assign m_axi_cap_rready = 1'b0;
  // synthesis translate_off
  always @(posedge enc_clk) begin
    if (enc_resetn && ((m_axi_enc_awvalid && (enc_awlen > 8'd15)) || (m_axi_enc_arvalid && (enc_arlen > 8'd15))))
      $error("rtlnet_zybo_video: encoder burst longer than 16 beats at the HP port");
  end
  always @(posedge capture_clk) begin
    if (capture_resetn && m_axi_cap_awvalid && (cap_awlen > 8'd15))
      $error("rtlnet_zybo_video: capture burst longer than 16 beats at the HP port");
  end
  // synthesis translate_on
  // u_capture_irq implements rtlnet_pulse_sync in its explicitly connected clock domain.
  rtlnet_pulse_sync #(.STAGES(3)) u_capture_irq (
    .src_clk(capture_clk),
    .src_resetn(capture_resetn),
    .src_pulse(fb_done && fb_done_good),
    .dst_clk(s_axi_aclk),
    .dst_resetn(s_axi_aresetn),
    .dst_pulse(irq[0])
  );
  // The encoder interrupt level (enable AND status) is combinational in the encoder register file; it is
  // registered in enc_clk first so that a flop, not logic, drives the synchronizer (CDC-10).
  logic encoder_irq_q;
  always_ff @(posedge enc_clk) begin
    if (!enc_resetn) encoder_irq_q <= 1'b0;
    else encoder_irq_q <= encoder_irq;
  end
  // u_encoder_irq implements rtlnet_sync in its explicitly connected clock domain.
  rtlnet_sync #(.WIDTH(1)) u_encoder_irq (
    .clk(s_axi_aclk),
    .resetn(s_axi_aresetn),
    .d(encoder_irq_q),
    .q(irq[1])
  );
endmodule
