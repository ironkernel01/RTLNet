// -----------------------------------------------------------------------------
// File: rtlnet_eth_protocol_regs.sv
// Purpose: the wrapper register file of rtlnet_eth_protocol (window 0x0000 of
//   the protocol sub-map): node address, filter mode, leaf enables, status,
//   effective address and the frame counters, all in proto_clk.
// Overview:
//   * Register offsets and bits are defined in
//     cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.h; the localparams
//     below mirror it. Read data is registered one clock after reg_rd_en
//     (the 12-bit register port of the leaf contract). Undefined offsets read
//     0; writes to read-only offsets are ignored.
//   * Node address: LOCAL_MAC_HI/LOCAL_MAC_LO (reset DEFAULT_LOCAL_MAC),
//     STATIC_IP (DEFAULT_LOCAL_IP), NETMASK (255.255.255.0), GATEWAY
//     (192.169.1.1). A LOCAL_MAC_HI write is staged; the LOCAL_MAC_LO write
//     changes all 48 bits in one clock, so no leaf or filter ever uses a MAC
//     made of two halves.
//   * Effective address: while the DHCP leaf is present, enabled
//     (LEAF_ENABLE bit 3) and holds a lease (lease_valid), the effective IP,
//     mask and gateway are lease_ip, lease_mask and lease_router
//     (STATUS.IP_FROM_DHCP = 1); otherwise STATIC_IP, NETMASK and GATEWAY.
//     Registered; these are the leaves' local_ip / local_mask /
//     local_gateway.
//   * CTRL: FILTER_ENABLE (reset 1, 0 = promiscuous), LEAF_ENABLE (bit i =
//     leaf index i; reset and stored value masked by the present leaves),
//     CNT_CLEAR (self-clearing pulse, reads 0).
//   * Counters: the four count inputs are coherent proto_clk copies (Gray
//     crossings) of free-running axis_clk counters. A register reads the
//     count minus a base taken at the last CNT_CLEAR, so a clear is exact for
//     all four together and the axis_clk counters never jump.
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk (proto_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_eth_protocol_regs #(
  parameter logic [4:0] LEAF_PRESENT    = 5'b11111,  // bit i: leaf index i is instanced
  parameter int         INGRESS_FIFO_KB = 16,
  parameter int         EGRESS_FIFO_KB  = 8,
  parameter int         NUM_SOCKETS     = 4
)(
  // proto_clk and its synchronous active-low reset.
  input  logic        clk,
  input  logic        resetn,

  // Register port of window 0 (12-bit offset), proto_clk.
  input  logic        reg_wr_en,
  input  logic [11:0] reg_wr_addr,
  input  logic [31:0] reg_wr_data,
  input  logic        reg_rd_en,
  input  logic [11:0] reg_rd_addr,
  output logic [31:0] reg_rd_data,

  // DHCP lease from the DHCP leaf (proto_clk registers; 0 without the leaf).
  input  logic        lease_valid,
  input  logic [31:0] lease_ip,
  input  logic [31:0] lease_mask,
  input  logic [31:0] lease_router,

  // Status inputs, proto_clk: leaf busy vector by leaf index, queue and
  // controller flags.
  input  logic [4:0]  leaf_busy,
  input  logic        ingress_pending,
  input  logic        egress_full,
  input  logic        delivering,         // a frame is being delivered to the leaves
  input  logic        arbiter_active,

  // Frame counts, proto_clk copies of the axis_clk counters.
  input  logic [31:0] cnt_ingress_frames,
  input  logic [31:0] cnt_ingress_filtered,
  input  logic [31:0] cnt_ingress_dropped,
  input  logic [31:0] cnt_egress_frames,

  // Configuration out, proto_clk registers.
  output logic [47:0] local_mac,          // octet 0 in [47:40]
  output logic [31:0] effective_ip,       // first octet in [31:24]
  output logic [31:0] effective_mask,
  output logic [31:0] effective_gateway,
  output logic        ip_from_dhcp,
  output logic        filter_enable,
  output logic [4:0]  leaf_enable         // already masked by LEAF_PRESENT
);

  import rtlnet_pkg::*;

  // ---------------------------------------------------------------------------
  // Register map (mirror of cores/rtlnet_eth_protocol/driver/rtlnet_eth_protocol.h).
  // ---------------------------------------------------------------------------
  localparam logic [11:0] REG_ID                = 12'h000;
  localparam logic [11:0] REG_VERSION           = 12'h004;
  localparam logic [11:0] REG_CAPS              = 12'h008;
  localparam logic [11:0] REG_CTRL              = 12'h00C;
  localparam logic [11:0] REG_STATUS            = 12'h010;
  localparam logic [11:0] REG_LOCAL_MAC_HI      = 12'h014;
  localparam logic [11:0] REG_LOCAL_MAC_LO      = 12'h018;
  localparam logic [11:0] REG_STATIC_IP         = 12'h01C;
  localparam logic [11:0] REG_NETMASK           = 12'h020;
  localparam logic [11:0] REG_GATEWAY           = 12'h024;
  localparam logic [11:0] REG_EFFECTIVE_IP      = 12'h028;
  localparam logic [11:0] REG_EFFECTIVE_MASK    = 12'h02C;
  localparam logic [11:0] REG_EFFECTIVE_GATEWAY = 12'h030;
  localparam logic [11:0] REG_INGRESS_FRAMES    = 12'h040;
  localparam logic [11:0] REG_INGRESS_FILTERED  = 12'h044;
  localparam logic [11:0] REG_INGRESS_DROPPED   = 12'h048;
  localparam logic [11:0] REG_EGRESS_FRAMES     = 12'h04C;

  localparam int          CTRL_FILTER_ENABLE_BIT  = 0;
  localparam int          CTRL_LEAF_ENABLE_LSB    = 8;
  localparam int          CTRL_CNT_CLEAR_BIT      = 16;
  localparam int          STATUS_IP_FROM_DHCP_BIT = 0;
  localparam int          STATUS_IP_VALID_BIT     = 1;
  localparam int          STATUS_LEASE_VALID_BIT  = 2;
  localparam int          STATUS_LEAF_BUSY_LSB    = 8;
  localparam int          STATUS_INGRESS_PEND_BIT = 16;
  localparam int          STATUS_EGRESS_FULL_BIT  = 17;
  localparam int          STATUS_DELIVERING_BIT   = 18;
  localparam int          STATUS_ARBITER_BIT      = 19;
  localparam int          LEAF_DHCP               = 3;

  localparam logic [31:0] ID_VALUE        = id4("P", "R", "O", "T");
  localparam logic [31:0] VERSION_VALUE   = 32'h10222026;
  localparam logic [31:0] DEFAULT_NETMASK = {8'd255, 8'd255, 8'd255, 8'd0};
  localparam logic [31:0] DEFAULT_GATEWAY = {8'd192, 8'd169, 8'd1, 8'd1};
  localparam logic [7:0]  SOCKETS_REPORTED = LEAF_PRESENT[0] ? 8'(NUM_SOCKETS) : 8'd0;
  localparam logic [31:0] CAPS_VALUE      = {SOCKETS_REPORTED, 8'(EGRESS_FIFO_KB), 8'(INGRESS_FIFO_KB),
                                             3'd0, LEAF_PRESENT};

  logic [15:0] mac_hi_staged;
  logic [31:0] static_ip;
  logic [31:0] netmask;
  logic [31:0] gateway;
  logic [31:0] base_frames;
  logic [31:0] base_filtered;
  logic [31:0] base_dropped;
  logic [31:0] base_egress;
  logic        cnt_clear;
  logic        dhcp_in_use;
  logic [31:0] status_word;
  logic [31:0] ctrl_word;

  assign cnt_clear   = reg_wr_en && (reg_wr_addr == REG_CTRL) && reg_wr_data[CTRL_CNT_CLEAR_BIT];
  assign dhcp_in_use = LEAF_PRESENT[LEAF_DHCP] && leaf_enable[LEAF_DHCP] && lease_valid;

  // Writable registers: node address, CTRL fields, counter bases.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      local_mac     <= DEFAULT_LOCAL_MAC;
      mac_hi_staged <= DEFAULT_LOCAL_MAC[47:32];
      static_ip     <= DEFAULT_LOCAL_IP;
      netmask       <= DEFAULT_NETMASK;
      gateway       <= DEFAULT_GATEWAY;
      filter_enable <= 1'b1;
      leaf_enable   <= LEAF_PRESENT;
      base_frames   <= '0;
      base_filtered <= '0;
      base_dropped  <= '0;
      base_egress   <= '0;
    end else begin
      if (reg_wr_en) begin
        case (reg_wr_addr)
          REG_CTRL: begin
            filter_enable <= reg_wr_data[CTRL_FILTER_ENABLE_BIT];
            leaf_enable   <= reg_wr_data[CTRL_LEAF_ENABLE_LSB +: 5] & LEAF_PRESENT;
          end
          REG_LOCAL_MAC_HI: mac_hi_staged <= reg_wr_data[15:0];
          REG_LOCAL_MAC_LO: local_mac     <= {mac_hi_staged, reg_wr_data};
          REG_STATIC_IP:    static_ip     <= reg_wr_data;
          REG_NETMASK:      netmask       <= reg_wr_data;
          REG_GATEWAY:      gateway       <= reg_wr_data;
          default: ;
        endcase
      end
      if (cnt_clear) begin
        base_frames   <= cnt_ingress_frames;
        base_filtered <= cnt_ingress_filtered;
        base_dropped  <= cnt_ingress_dropped;
        base_egress   <= cnt_egress_frames;
      end
    end
  end

  // Effective address: the lease while DHCP is in use, else the static set.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      effective_ip      <= DEFAULT_LOCAL_IP;
      effective_mask    <= DEFAULT_NETMASK;
      effective_gateway <= DEFAULT_GATEWAY;
      ip_from_dhcp      <= 1'b0;
    end else begin
      ip_from_dhcp      <= dhcp_in_use;
      effective_ip      <= dhcp_in_use ? lease_ip     : static_ip;
      effective_mask    <= dhcp_in_use ? lease_mask   : netmask;
      effective_gateway <= dhcp_in_use ? lease_router : gateway;
    end
  end

  always_comb begin
    ctrl_word                                    = '0;
    ctrl_word[CTRL_FILTER_ENABLE_BIT]            = filter_enable;
    ctrl_word[CTRL_LEAF_ENABLE_LSB +: 5]         = leaf_enable;
    status_word                                  = '0;
    status_word[STATUS_IP_FROM_DHCP_BIT]         = ip_from_dhcp;
    status_word[STATUS_IP_VALID_BIT]             = (effective_ip != '0);
    status_word[STATUS_LEASE_VALID_BIT]          = lease_valid;
    status_word[STATUS_LEAF_BUSY_LSB +: 5]       = leaf_busy;
    status_word[STATUS_INGRESS_PEND_BIT]         = ingress_pending;
    status_word[STATUS_EGRESS_FULL_BIT]          = egress_full;
    status_word[STATUS_DELIVERING_BIT]           = delivering;
    status_word[STATUS_ARBITER_BIT]              = arbiter_active;
  end

  // Registered read mux.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      reg_rd_data <= '0;
    end else if (reg_rd_en) begin
      case (reg_rd_addr)
        REG_ID:                reg_rd_data <= ID_VALUE;
        REG_VERSION:           reg_rd_data <= VERSION_VALUE;
        REG_CAPS:              reg_rd_data <= CAPS_VALUE;
        REG_CTRL:              reg_rd_data <= ctrl_word;
        REG_STATUS:            reg_rd_data <= status_word;
        REG_LOCAL_MAC_HI:      reg_rd_data <= {16'd0, local_mac[47:32]};
        REG_LOCAL_MAC_LO:      reg_rd_data <= local_mac[31:0];
        REG_STATIC_IP:         reg_rd_data <= static_ip;
        REG_NETMASK:           reg_rd_data <= netmask;
        REG_GATEWAY:           reg_rd_data <= gateway;
        REG_EFFECTIVE_IP:      reg_rd_data <= effective_ip;
        REG_EFFECTIVE_MASK:    reg_rd_data <= effective_mask;
        REG_EFFECTIVE_GATEWAY: reg_rd_data <= effective_gateway;
        REG_INGRESS_FRAMES:    reg_rd_data <= cnt_ingress_frames - base_frames;
        REG_INGRESS_FILTERED:  reg_rd_data <= cnt_ingress_filtered - base_filtered;
        REG_INGRESS_DROPPED:   reg_rd_data <= cnt_ingress_dropped - base_dropped;
        REG_EGRESS_FRAMES:     reg_rd_data <= cnt_egress_frames - base_egress;
        default:               reg_rd_data <= '0;
      endcase
    end
  end

endmodule
