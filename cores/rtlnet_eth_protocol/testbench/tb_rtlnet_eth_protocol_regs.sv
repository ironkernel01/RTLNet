// -----------------------------------------------------------------------------
// File: tb_rtlnet_eth_protocol_regs.sv
// Purpose: self-checking unit bench of rtlnet_eth_protocol_regs, the wrapper
//   register file, covering what the wrapper bench cannot reach while the
//   DHCP leaf does not exist: the effective-address selection from a lease.
// Overview:
//   * Two instances: u_dhcp (LEAF_PRESENT = ICMP, ARP, DHCP) and u_nodhcp
//     (ICMP, ARP only). The bench drives the 12-bit register port, the lease
//     inputs, the status inputs and the counter inputs directly.
//   * Proves: reset values; effective IP/mask/gateway and STATUS.IP_FROM_DHCP
//     follow the lease only while DHCP is present, enabled (LEAF_ENABLE bit 3)
//     and lease_valid; the static registers keep their values meanwhile;
//     LEAF_ENABLE is masked by the present leaves; LOCAL_MAC_HI is staged
//     until the LOCAL_MAC_LO write; STATUS bit mapping; counters read the
//     input minus the CNT_CLEAR base, including across a 32-bit wrap; CAPS.
//   * Third instance u_cpu (CPU_PATH_PRESENT, CPU_RX_FIFO_KB 16,
//     CPU_TX_FIFO_KB 8): CAPS bit 5, CPU_CAPS, CTRL.CPU_PATH_ENABLE reset 1 /
//     write 0 / write 1 and its output, the same bit masked to 0 where the
//     path is absent, STATUS bits 20-22, and the seven new counters
//     (DELIVERED, CPU_RX_FRAMES/CLAIMED/DROPPED, CPU_TX_FRAMES/DISCARDED/
//     REJECTED) minus the CNT_CLEAR base.
//   * +INJECT_FAILURE forces TEST FAIL (negative control).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: CPU network path registers (u_cpu instance).
// Clocks: one 50 MHz clock for both instances.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_eth_protocol_regs;

  import rtlnet_tb_pkg::*;

  localparam logic [31:0] DEF_IP   = 32'hC0A901DC;
  localparam logic [31:0] DEF_MASK = 32'hFFFFFF00;
  localparam logic [31:0] DEF_GW   = 32'hC0A90101;
  localparam logic [47:0] DEF_MAC  = 48'h02_49_4B_52_4E_01;

  logic        clk = 1'b0;
  logic        resetn = 1'b0;
  always #10.0 clk = ~clk;

  logic        reg_wr_en = 1'b0;
  logic [11:0] reg_wr_addr = '0;
  logic [31:0] reg_wr_data = '0;
  logic        reg_rd_en = 1'b0;
  logic [11:0] reg_rd_addr = '0;
  logic [31:0] rd_a;
  logic [31:0] rd_b;
  logic        lease_valid = 1'b0;
  logic [31:0] lease_ip = 32'h0A00002A;
  logic [31:0] lease_mask = 32'hFFFF0000;
  logic [31:0] lease_router = 32'h0A000001;
  logic [4:0]  leaf_busy = '0;
  logic        ingress_pending = 1'b0;
  logic        egress_full = 1'b0;
  logic        delivering = 1'b0;
  logic        arbiter_active = 1'b0;
  logic [31:0] cnt_frames = '0;
  logic [31:0] cnt_filtered = '0;
  logic [31:0] cnt_dropped = '0;
  logic [31:0] cnt_egress = '0;

  logic [47:0] mac_a;
  logic [31:0] ip_a;
  logic [31:0] mask_a;
  logic [31:0] gw_a;
  logic        dhcp_a;
  logic        filt_a;
  logic [4:0]  en_a;
  logic [47:0] mac_b;
  logic [31:0] ip_b;
  logic [31:0] mask_b;
  logic [31:0] gw_b;
  logic        dhcp_b;
  logic        filt_b;
  logic [4:0]  en_b;
  logic        cpu_en_a;
  logic        cpu_en_b;
  logic        cpu_en_c;
  logic [31:0] rd_c;
  logic [47:0] mac_c;
  logic [31:0] ip_c;
  logic [31:0] mask_c;
  logic [31:0] gw_c;
  logic        dhcp_c;
  logic        filt_c;
  logic [4:0]  en_c;
  logic        cpu_rx_full = 1'b0;
  logic        cpu_rx_pending = 1'b0;
  logic        cpu_tx_pending = 1'b0;
  logic [31:0] cnt_cpu [7] = '{default: 32'd0};

  // Register file with the DHCP leaf present.
  rtlnet_eth_protocol_regs #(.LEAF_PRESENT(5'b01110), .INGRESS_FIFO_KB(16), .EGRESS_FIFO_KB(8), .NUM_SOCKETS(4)) u_dhcp (
    .clk(clk), .resetn(resetn), .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(rd_a), .lease_valid(lease_valid),
    .lease_ip(lease_ip), .lease_mask(lease_mask), .lease_router(lease_router), .leaf_busy(leaf_busy),
    .ingress_pending(ingress_pending), .egress_full(egress_full), .delivering(delivering),
    .arbiter_active(arbiter_active), .cnt_ingress_frames(cnt_frames), .cnt_ingress_filtered(cnt_filtered),
    .cnt_ingress_dropped(cnt_dropped), .cnt_egress_frames(cnt_egress), .local_mac(mac_a), .effective_ip(ip_a),
    .effective_mask(mask_a), .effective_gateway(gw_a), .ip_from_dhcp(dhcp_a), .filter_enable(filt_a),
    .leaf_enable(en_a), .cpu_rx_full(cpu_rx_full), .cpu_rx_pending(cpu_rx_pending), .cpu_tx_pending(cpu_tx_pending),
    .cnt_delivered(cnt_cpu[0]), .cnt_cpu_rx_frames(cnt_cpu[1]), .cnt_cpu_rx_claimed(cnt_cpu[2]),
    .cnt_cpu_rx_dropped(cnt_cpu[3]), .cnt_cpu_tx_frames(cnt_cpu[4]), .cnt_cpu_tx_discard(cnt_cpu[5]),
    .cnt_cpu_tx_reject(cnt_cpu[6]), .cpu_path_enable(cpu_en_a));

  // Register file without the DHCP leaf (and with the UDP socket leaf).
  rtlnet_eth_protocol_regs #(.LEAF_PRESENT(5'b00111), .INGRESS_FIFO_KB(32), .EGRESS_FIFO_KB(4), .NUM_SOCKETS(4)) u_nodhcp (
    .clk(clk), .resetn(resetn), .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(rd_b), .lease_valid(lease_valid),
    .lease_ip(lease_ip), .lease_mask(lease_mask), .lease_router(lease_router), .leaf_busy(leaf_busy),
    .ingress_pending(ingress_pending), .egress_full(egress_full), .delivering(delivering),
    .arbiter_active(arbiter_active), .cnt_ingress_frames(cnt_frames), .cnt_ingress_filtered(cnt_filtered),
    .cnt_ingress_dropped(cnt_dropped), .cnt_egress_frames(cnt_egress), .local_mac(mac_b), .effective_ip(ip_b),
    .effective_mask(mask_b), .effective_gateway(gw_b), .ip_from_dhcp(dhcp_b), .filter_enable(filt_b),
    .leaf_enable(en_b), .cpu_rx_full(cpu_rx_full), .cpu_rx_pending(cpu_rx_pending), .cpu_tx_pending(cpu_tx_pending),
    .cnt_delivered(cnt_cpu[0]), .cnt_cpu_rx_frames(cnt_cpu[1]), .cnt_cpu_rx_claimed(cnt_cpu[2]),
    .cnt_cpu_rx_dropped(cnt_cpu[3]), .cnt_cpu_tx_frames(cnt_cpu[4]), .cnt_cpu_tx_discard(cnt_cpu[5]),
    .cnt_cpu_tx_reject(cnt_cpu[6]), .cpu_path_enable(cpu_en_b));

  // Register file with the CPU network path present (all leaves).
  rtlnet_eth_protocol_regs #(.LEAF_PRESENT(5'b11111), .INGRESS_FIFO_KB(16), .EGRESS_FIFO_KB(8), .NUM_SOCKETS(4),
                             .CPU_PATH_PRESENT(1'b1), .CPU_RX_FIFO_KB(16), .CPU_TX_FIFO_KB(8)) u_cpu (
    .clk(clk), .resetn(resetn), .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(rd_c), .lease_valid(1'b0),
    .lease_ip(lease_ip), .lease_mask(lease_mask), .lease_router(lease_router), .leaf_busy(leaf_busy),
    .ingress_pending(ingress_pending), .egress_full(egress_full), .delivering(delivering),
    .arbiter_active(arbiter_active), .cnt_ingress_frames(cnt_frames), .cnt_ingress_filtered(cnt_filtered),
    .cnt_ingress_dropped(cnt_dropped), .cnt_egress_frames(cnt_egress), .local_mac(mac_c), .effective_ip(ip_c),
    .effective_mask(mask_c), .effective_gateway(gw_c), .ip_from_dhcp(dhcp_c), .filter_enable(filt_c),
    .leaf_enable(en_c), .cpu_rx_full(cpu_rx_full), .cpu_rx_pending(cpu_rx_pending), .cpu_tx_pending(cpu_tx_pending),
    .cnt_delivered(cnt_cpu[0]), .cnt_cpu_rx_frames(cnt_cpu[1]), .cnt_cpu_rx_claimed(cnt_cpu[2]),
    .cnt_cpu_rx_dropped(cnt_cpu[3]), .cnt_cpu_tx_frames(cnt_cpu[4]), .cnt_cpu_tx_discard(cnt_cpu[5]),
    .cnt_cpu_tx_reject(cnt_cpu[6]), .cpu_path_enable(cpu_en_c));

  // The same CPU path with each optional block present: classifier only, offload only, both.
  logic [31:0] rd_d;
  logic [31:0] rd_e;
  logic [31:0] rd_f;
  logic        cpu_en_d;
  logic        cpu_en_e;
  logic        cpu_en_f;
  rtlnet_eth_protocol_regs #(.LEAF_PRESENT(5'b11111), .INGRESS_FIFO_KB(16), .EGRESS_FIFO_KB(8), .NUM_SOCKETS(4),
                             .CPU_PATH_PRESENT(1'b1), .CPU_RX_FIFO_KB(16), .CPU_TX_FIFO_KB(8),
                             .CPU_CLASSIFIER_PRESENT(1'b1), .CPU_OFFLOAD_PRESENT(1'b0)) u_cpu_cls (
    .clk(clk), .resetn(resetn), .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(rd_d), .lease_valid(1'b0),
    .lease_ip(lease_ip), .lease_mask(lease_mask), .lease_router(lease_router), .leaf_busy(leaf_busy),
    .ingress_pending(ingress_pending), .egress_full(egress_full), .delivering(delivering),
    .arbiter_active(arbiter_active), .cnt_ingress_frames(cnt_frames), .cnt_ingress_filtered(cnt_filtered),
    .cnt_ingress_dropped(cnt_dropped), .cnt_egress_frames(cnt_egress),
    .cpu_rx_full(cpu_rx_full), .cpu_rx_pending(cpu_rx_pending), .cpu_tx_pending(cpu_tx_pending),
    .cnt_delivered(cnt_cpu[0]), .cnt_cpu_rx_frames(cnt_cpu[1]), .cnt_cpu_rx_claimed(cnt_cpu[2]),
    .cnt_cpu_rx_dropped(cnt_cpu[3]), .cnt_cpu_tx_frames(cnt_cpu[4]), .cnt_cpu_tx_discard(cnt_cpu[5]),
    .cnt_cpu_tx_reject(cnt_cpu[6]), .cpu_path_enable(cpu_en_d));
  rtlnet_eth_protocol_regs #(.LEAF_PRESENT(5'b11111), .INGRESS_FIFO_KB(16), .EGRESS_FIFO_KB(8), .NUM_SOCKETS(4),
                             .CPU_PATH_PRESENT(1'b1), .CPU_RX_FIFO_KB(16), .CPU_TX_FIFO_KB(8),
                             .CPU_CLASSIFIER_PRESENT(1'b0), .CPU_OFFLOAD_PRESENT(1'b1)) u_cpu_off (
    .clk(clk), .resetn(resetn), .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(rd_e), .lease_valid(1'b0),
    .lease_ip(lease_ip), .lease_mask(lease_mask), .lease_router(lease_router), .leaf_busy(leaf_busy),
    .ingress_pending(ingress_pending), .egress_full(egress_full), .delivering(delivering),
    .arbiter_active(arbiter_active), .cnt_ingress_frames(cnt_frames), .cnt_ingress_filtered(cnt_filtered),
    .cnt_ingress_dropped(cnt_dropped), .cnt_egress_frames(cnt_egress),
    .cpu_rx_full(cpu_rx_full), .cpu_rx_pending(cpu_rx_pending), .cpu_tx_pending(cpu_tx_pending),
    .cnt_delivered(cnt_cpu[0]), .cnt_cpu_rx_frames(cnt_cpu[1]), .cnt_cpu_rx_claimed(cnt_cpu[2]),
    .cnt_cpu_rx_dropped(cnt_cpu[3]), .cnt_cpu_tx_frames(cnt_cpu[4]), .cnt_cpu_tx_discard(cnt_cpu[5]),
    .cnt_cpu_tx_reject(cnt_cpu[6]), .cpu_path_enable(cpu_en_e));
  rtlnet_eth_protocol_regs #(.LEAF_PRESENT(5'b11111), .INGRESS_FIFO_KB(16), .EGRESS_FIFO_KB(8), .NUM_SOCKETS(4),
                             .CPU_PATH_PRESENT(1'b1), .CPU_RX_FIFO_KB(16), .CPU_TX_FIFO_KB(8),
                             .CPU_CLASSIFIER_PRESENT(1'b1), .CPU_OFFLOAD_PRESENT(1'b1)) u_cpu_both (
    .clk(clk), .resetn(resetn), .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(rd_f), .lease_valid(1'b0),
    .lease_ip(lease_ip), .lease_mask(lease_mask), .lease_router(lease_router), .leaf_busy(leaf_busy),
    .ingress_pending(ingress_pending), .egress_full(egress_full), .delivering(delivering),
    .arbiter_active(arbiter_active), .cnt_ingress_frames(cnt_frames), .cnt_ingress_filtered(cnt_filtered),
    .cnt_ingress_dropped(cnt_dropped), .cnt_egress_frames(cnt_egress),
    .cpu_rx_full(cpu_rx_full), .cpu_rx_pending(cpu_rx_pending), .cpu_tx_pending(cpu_tx_pending),
    .cnt_delivered(cnt_cpu[0]), .cnt_cpu_rx_frames(cnt_cpu[1]), .cnt_cpu_rx_claimed(cnt_cpu[2]),
    .cnt_cpu_rx_dropped(cnt_cpu[3]), .cnt_cpu_tx_frames(cnt_cpu[4]), .cnt_cpu_tx_discard(cnt_cpu[5]),
    .cnt_cpu_tx_reject(cnt_cpu[6]), .cpu_path_enable(cpu_en_f));

  // Read CPU_CAPS of the three builds and compare.
  task automatic expect_caps(input logic [31:0] e_cls, input logic [31:0] e_off, input logic [31:0] e_both);
    @(posedge clk);
    reg_rd_en   <= 1'b1;
    reg_rd_addr <= 12'h034;
    @(posedge clk);
    reg_rd_en   <= 1'b0;
    @(posedge clk);
    tb_check(rd_d === e_cls, $sformatf("CPU_CAPS classifier only = 0x%08x, expected 0x%08x", rd_d, e_cls));
    tb_check(rd_e === e_off, $sformatf("CPU_CAPS offload only = 0x%08x, expected 0x%08x", rd_e, e_off));
    tb_check(rd_f === e_both, $sformatf("CPU_CAPS classifier + offload = 0x%08x, expected 0x%08x", rd_f, e_both));
  endtask

  // Read one offset of the CPU-path instance.
  task automatic expect_c(input logic [11:0] addr, input logic [31:0] e, input string what);
    @(posedge clk);
    reg_rd_en   <= 1'b1;
    reg_rd_addr <= addr;
    @(posedge clk);
    reg_rd_en   <= 1'b0;
    @(posedge clk);
    tb_check(rd_c === e, $sformatf("CPU path: %s = 0x%08x, expected 0x%08x", what, rd_c, e));
  endtask

  task automatic wr(input logic [11:0] addr, input logic [31:0] data);
    @(posedge clk);
    reg_wr_en   <= 1'b1;
    reg_wr_addr <= addr;
    reg_wr_data <= data;
    @(posedge clk);
    reg_wr_en   <= 1'b0;
    repeat (2) @(posedge clk);
  endtask

  // Read the same offset from both instances.
  task automatic rd(input logic [11:0] addr, output logic [31:0] a, output logic [31:0] b);
    @(posedge clk);
    reg_rd_en   <= 1'b1;
    reg_rd_addr <= addr;
    @(posedge clk);
    reg_rd_en   <= 1'b0;
    @(posedge clk);
    a = rd_a;
    b = rd_b;
  endtask

  task automatic expect2(input logic [11:0] addr, input logic [31:0] ea, input logic [31:0] eb, input string what);
    logic [31:0] a;
    logic [31:0] b;
    rd(addr, a, b);
    tb_check(a === ea, $sformatf("DHCP present: %s = 0x%08x, expected 0x%08x", what, a, ea));
    tb_check(b === eb, $sformatf("DHCP absent: %s = 0x%08x, expected 0x%08x", what, b, eb));
  endtask

  initial begin
    repeat (5) @(posedge clk);
    resetn <= 1'b1;
    repeat (3) @(posedge clk);

    // ---- Reset values.
    expect2(12'h000, 32'h50524F54, 32'h50524F54, "ID");
    expect2(12'h008, 32'h0008_100E, 32'h0404_2007, "CAPS");
    expect2(12'h00C, 32'h0000_0E01, 32'h0000_0701, "CTRL");
    expect2(12'h010, 32'h0000_0002, 32'h0000_0002, "STATUS");
    expect2(12'h014, 32'h0000_0249, 32'h0000_0249, "LOCAL_MAC_HI");
    expect2(12'h018, 32'h4B52_4E01, 32'h4B52_4E01, "LOCAL_MAC_LO");
    expect2(12'h01C, DEF_IP, DEF_IP, "STATIC_IP");
    expect2(12'h020, DEF_MASK, DEF_MASK, "NETMASK");
    expect2(12'h024, DEF_GW, DEF_GW, "GATEWAY");
    expect2(12'h028, DEF_IP, DEF_IP, "EFFECTIVE_IP");
    expect2(12'h02C, DEF_MASK, DEF_MASK, "EFFECTIVE_MASK");
    expect2(12'h030, DEF_GW, DEF_GW, "EFFECTIVE_GATEWAY");
    expect2(12'h034, 32'h0, 32'h0, "undefined offset");
    tb_check(mac_a == DEF_MAC && ip_a == DEF_IP && filt_a && en_a == 5'b01110 && !dhcp_a, "outputs at reset (DHCP)");
    tb_check(mac_b == DEF_MAC && ip_b == DEF_IP && filt_b && en_b == 5'b00111 && !dhcp_b, "outputs at reset (no DHCP)");
    expect_c(12'h00C, 32'h0000_1F03, "CTRL at reset (CPU_PATH_ENABLE 1)");
    tb_check(cpu_en_c === 1'b1 && cpu_en_a === 1'b0 && cpu_en_b === 1'b0, "cpu_path_enable at reset: present 1, absent 0");

    // ---- A lease: used only where DHCP is present and enabled.
    lease_valid = 1'b1;
    repeat (3) @(posedge clk);
    tb_check(ip_a == lease_ip && mask_a == lease_mask && gw_a == lease_router && dhcp_a, "lease in use (DHCP)");
    tb_check(ip_b == DEF_IP && mask_b == DEF_MASK && gw_b == DEF_GW && !dhcp_b, "lease ignored (no DHCP)");
    expect2(12'h028, lease_ip, DEF_IP, "EFFECTIVE_IP with a lease");
    expect2(12'h02C, lease_mask, DEF_MASK, "EFFECTIVE_MASK with a lease");
    expect2(12'h030, lease_router, DEF_GW, "EFFECTIVE_GATEWAY with a lease");
    expect2(12'h010, 32'h0000_0007, 32'h0000_0006, "STATUS with a lease");
    // The static set can change underneath; the lease stays in use.
    wr(12'h01C, 32'h0A01_0203);
    expect2(12'h01C, 32'h0A01_0203, 32'h0A01_0203, "STATIC_IP written during a lease");
    expect2(12'h028, lease_ip, 32'h0A01_0203, "EFFECTIVE_IP during a lease");
    // DHCP disabled by LEAF_ENABLE bit 3: back to the static set.
    wr(12'h00C, 32'h0000_0601);
    expect2(12'h00C, 32'h0000_0601, 32'h0000_0601, "CTRL with DHCP disabled");
    expect2(12'h028, 32'h0A01_0203, 32'h0A01_0203, "EFFECTIVE_IP with DHCP disabled");
    expect2(12'h010, 32'h0000_0006, 32'h0000_0006, "STATUS with DHCP disabled (lease still valid)");
    wr(12'h00C, 32'h0000_1F01);
    expect2(12'h00C, 32'h0000_0E01, 32'h0000_0701, "CTRL with every bit set (masked by the present leaves)");
    expect2(12'h028, lease_ip, 32'h0A01_0203, "EFFECTIVE_IP with DHCP re-enabled");
    // A new lease value, then the lease lost.
    lease_ip     = 32'h0A00_0063;
    lease_router = 32'h0A00_00FE;
    repeat (2) @(posedge clk);
    tb_check(ip_a == 32'h0A00_0063 && gw_a == 32'h0A00_00FE, "a new lease is used at once");
    lease_valid = 1'b0;
    repeat (2) @(posedge clk);
    tb_check(ip_a == 32'h0A01_0203 && mask_a == DEF_MASK && gw_a == DEF_GW && !dhcp_a, "lease lost: static set");
    expect2(12'h010, 32'h0000_0002, 32'h0000_0002, "STATUS after the lease is lost");

    // ---- Filter enable and the staged MAC.
    wr(12'h00C, 32'h0000_0E00);
    tb_check(!filt_a && en_a == 5'b01110, "FILTER_ENABLE cleared, enables kept");
    wr(12'h00C, 32'h0000_0E01);
    wr(12'h014, 32'hFFFF_0E00);
    tb_check(mac_a == DEF_MAC, "LOCAL_MAC_HI write is staged");
    expect2(12'h014, 32'h0000_0249, 32'h0000_0249, "LOCAL_MAC_HI before the LO write");
    wr(12'h018, 32'h1122_3344);
    tb_check(mac_a == 48'h0E00_1122_3344 && mac_b == 48'h0E00_1122_3344, "LOCAL_MAC_LO write commits 48 bits");
    expect2(12'h014, 32'h0000_0E00, 32'h0000_0E00, "LOCAL_MAC_HI after the LO write");
    wr(12'h018, 32'h5566_7788);
    tb_check(mac_a == 48'h0E00_5566_7788, "a second LO write keeps the committed HI");

    // ---- STATUS inputs.
    leaf_busy       = 5'b10101;
    ingress_pending = 1'b1;
    egress_full     = 1'b1;
    delivering      = 1'b1;
    arbiter_active  = 1'b1;
    expect2(12'h010, 32'h000F_1502, 32'h000F_1502, "STATUS flags");
    leaf_busy       = '0;
    ingress_pending = 1'b0;
    egress_full     = 1'b0;
    delivering      = 1'b0;
    arbiter_active  = 1'b0;

    // ---- Counters: value minus the CNT_CLEAR base, across a wrap.
    cnt_frames   = 32'd100;
    cnt_filtered = 32'd200;
    cnt_dropped  = 32'd3;
    cnt_egress   = 32'hFFFF_FFF0;
    expect2(12'h040, 32'd100, 32'd100, "INGRESS_FRAMES");
    expect2(12'h044, 32'd200, 32'd200, "INGRESS_FILTERED");
    expect2(12'h048, 32'd3, 32'd3, "INGRESS_DROPPED");
    expect2(12'h04C, 32'hFFFF_FFF0, 32'hFFFF_FFF0, "EGRESS_FRAMES");
    wr(12'h00C, 32'h0001_0E01);
    expect2(12'h00C, 32'h0000_0E01, 32'h0000_0601, "CTRL after CNT_CLEAR");
    expect2(12'h040, 32'd0, 32'd0, "INGRESS_FRAMES after CNT_CLEAR");
    expect2(12'h04C, 32'd0, 32'd0, "EGRESS_FRAMES after CNT_CLEAR");
    cnt_frames = 32'd105;
    cnt_egress = 32'h0000_0010;
    expect2(12'h040, 32'd5, 32'd5, "INGRESS_FRAMES counts on from the clear");
    expect2(12'h04C, 32'h0000_0020, 32'h0000_0020, "EGRESS_FRAMES across the 32-bit wrap");
    expect2(12'h044, 32'd0, 32'd0, "INGRESS_FILTERED unchanged since the clear");

    // ---- CPU network path registers (u_cpu), and the bit masked where absent.
    expect_c(12'h008, 32'h0408_103F, "CAPS (all leaves, CPU path present)");
    expect_c(12'h034, 32'h0000_0810, "CPU_CAPS (RX 16 KB, TX 8 KB, no optional block)");
    expect_caps(32'h0001_0810, 32'h0006_0810, 32'h0007_0810);
    expect2(12'h034, 32'h0, 32'h0, "CPU_CAPS without the CPU path");
    wr(12'h00C, 32'h0000_1F01);
    tb_check(cpu_en_c === 1'b0, "CTRL bit 1 cleared: cpu_path_enable 0");
    expect_c(12'h00C, 32'h0000_1F01, "CTRL with the CPU path disabled");
    wr(12'h00C, 32'h0000_1F03);
    tb_check(cpu_en_c === 1'b1 && cpu_en_a === 1'b0, "CTRL bit 1 set: enable where present, masked where absent");
    expect2(12'h00C, 32'h0000_0E01, 32'h0000_0701, "CTRL bit 1 reads 0 without the CPU path");
    cpu_rx_full    = 1'b1;
    cpu_rx_pending = 1'b1;
    cpu_tx_pending = 1'b1;
    expect_c(12'h010, 32'h0070_0002, "STATUS CPU bits 20-22");
    cpu_rx_full    = 1'b0;
    expect_c(12'h010, 32'h0060_0002, "STATUS CPU_RX_FULL clear");
    cpu_rx_pending = 1'b0;
    cpu_tx_pending = 1'b0;
    for (int i = 0; i < 7; i++) cnt_cpu[i] = 32'(1000 * (i + 1) + i);
    for (int i = 0; i < 7; i++) expect_c(12'(12'h050 + 4 * i), 32'(1000 * (i + 1) + i), $sformatf("CPU counter %0d", i));
    wr(12'h00C, 32'h0001_1F03);
    for (int i = 0; i < 7; i++) expect_c(12'(12'h050 + 4 * i), 32'd0, $sformatf("CPU counter %0d after CNT_CLEAR", i));
    for (int i = 0; i < 7; i++) cnt_cpu[i] = cnt_cpu[i] + 32'(i + 1);
    for (int i = 0; i < 7; i++) expect_c(12'(12'h050 + 4 * i), 32'(i + 1), $sformatf("CPU counter %0d counts on", i));
    expect_c(12'h06C, 32'h0, "undefined offset after the CPU counters");
    expect_c(12'h080, 32'h0, "offset 0x080 unused");

    tb_verdict("tb_rtlnet_eth_protocol_regs");
  end

  initial begin
    #1ms;
    tb_error("watchdog");
    tb_verdict("tb_rtlnet_eth_protocol_regs");
  end

endmodule
