// -----------------------------------------------------------------------------
// File: rtlnet_eth_protocol_regs.sv
// Purpose: the wrapper register file of rtlnet_eth_protocol (window 0x0000 of
//   the protocol sub-map): node address, filter mode, leaf enables, CPU
//   network path enable, status, effective address and the frame counters,
//   all in proto_clk.
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
//   * CTRL: FILTER_ENABLE (reset 1, 0 = promiscuous), CPU_PATH_ENABLE (reset
//     1, stored masked by CPU_PATH_PRESENT), LEAF_ENABLE (bit i = leaf index
//     i; reset and stored value masked by the present leaves), CNT_CLEAR
//     (self-clearing pulse, reads 0).
//   * Counters: every count input is a free-running proto_clk count (the
//     axis_clk counters arrive through Gray crossings). A register reads the
//     count minus a base taken at the last CNT_CLEAR, so a clear is exact for
//     all counters together and no source counter ever jumps.
// Language: SystemVerilog-2012 (synthesizable subset).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
//   * 10-22-2026: CPU network path (CTRL.CPU_PATH_ENABLE, CAPS bit 5,
//     CPU_CAPS, STATUS bits 20-22, DELIVERED and CPU counters).
// Clocks: clk (proto_clk) only; resetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_eth_protocol_regs #(
  parameter logic [4:0] LEAF_PRESENT            = 5'b11111,  // bit i: leaf index i is instanced
  parameter int         INGRESS_FIFO_KB         = 16,
  parameter int         EGRESS_FIFO_KB          = 8,
  parameter int         NUM_SOCKETS             = 4,
  parameter bit         CPU_PATH_PRESENT        = 1'b0,      // the CPU network path is built
  parameter int         CPU_RX_FIFO_KB          = 16,
  parameter int         CPU_TX_FIFO_KB          = 8
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
  input  logic        cpu_rx_full,        // the CPU RX queue has no free slot
  input  logic        cpu_rx_pending,     // a CPU copy waits for its claim verdict
  input  logic        cpu_tx_pending,     // a CPU frame waits at the CPU TX queue output

  // Frame counts, proto_clk copies of the axis_clk counters.
  input  logic [31:0] cnt_ingress_frames,
  input  logic [31:0] cnt_ingress_filtered,
  input  logic [31:0] cnt_ingress_dropped,
  input  logic [31:0] cnt_egress_frames,

  // Frame counts of the CPU network path (proto_clk).
  input  logic [31:0] cnt_delivered,      // frames dequeued to the leaves
  input  logic [31:0] cnt_cpu_rx_frames,  // copies committed to the CPU RX queue
  input  logic [31:0] cnt_cpu_rx_claimed, // copies dropped: a leaf claimed the frame
  input  logic [31:0] cnt_cpu_rx_dropped, // unclaimed frames lost: CPU RX queue full
  input  logic [31:0] cnt_cpu_tx_frames,  // CPU frames handed to the egress queue
  input  logic [31:0] cnt_cpu_tx_discard, // CPU frames discarded with the path disabled
  input  logic [31:0] cnt_cpu_tx_reject,  // CPU frames rejected by the length/tkeep guard

  // Configuration out, proto_clk registers.
  output logic [47:0] local_mac,          // octet 0 in [47:40]
  output logic [31:0] effective_ip,       // first octet in [31:24]
  output logic [31:0] effective_mask,
  output logic [31:0] effective_gateway,
  output logic        ip_from_dhcp,
  output logic        filter_enable,
  output logic [4:0]  leaf_enable,        // already masked by LEAF_PRESENT
  output logic        cpu_path_enable     // already masked by CPU_PATH_PRESENT
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
  localparam logic [11:0] REG_CPU_CAPS          = 12'h034;
  localparam logic [11:0] REG_INGRESS_FRAMES    = 12'h040;
  localparam logic [11:0] REG_INGRESS_FILTERED  = 12'h044;
  localparam logic [11:0] REG_INGRESS_DROPPED   = 12'h048;
  localparam logic [11:0] REG_EGRESS_FRAMES     = 12'h04C;
  localparam logic [11:0] REG_DELIVERED_FRAMES  = 12'h050;
  localparam logic [11:0] REG_CPU_RX_FRAMES     = 12'h054;
  localparam logic [11:0] REG_CPU_RX_CLAIMED    = 12'h058;
  localparam logic [11:0] REG_CPU_RX_DROPPED    = 12'h05C;
  localparam logic [11:0] REG_CPU_TX_FRAMES     = 12'h060;
  localparam logic [11:0] REG_CPU_TX_DISCARDED  = 12'h064;
  localparam logic [11:0] REG_CPU_TX_REJECTED   = 12'h068;

  localparam int          CTRL_FILTER_ENABLE_BIT   = 0;
  localparam int          CTRL_CPU_PATH_ENABLE_BIT = 1;
  localparam int          CTRL_LEAF_ENABLE_LSB     = 8;
  localparam int          CTRL_CNT_CLEAR_BIT       = 16;
  localparam int          CAPS_CPU_PATH_BIT        = 5;
  localparam int          STATUS_IP_FROM_DHCP_BIT  = 0;
  localparam int          STATUS_IP_VALID_BIT      = 1;
  localparam int          STATUS_LEASE_VALID_BIT   = 2;
  localparam int          STATUS_LEAF_BUSY_LSB     = 8;
  localparam int          STATUS_INGRESS_PEND_BIT  = 16;
  localparam int          STATUS_EGRESS_FULL_BIT   = 17;
  localparam int          STATUS_DELIVERING_BIT    = 18;
  localparam int          STATUS_ARBITER_BIT       = 19;
  localparam int          STATUS_CPU_RX_FULL_BIT   = 20;
  localparam int          STATUS_CPU_RX_PEND_BIT   = 21;
  localparam int          STATUS_CPU_TX_PEND_BIT   = 22;
  localparam int          LEAF_DHCP                = 3;

  // Counter slots (index into the count and base arrays).
  localparam int          N_CNT          = 11;
  localparam int          C_IN_FRAMES    = 0;
  localparam int          C_IN_FILTERED  = 1;
  localparam int          C_IN_DROPPED   = 2;
  localparam int          C_EGRESS       = 3;
  localparam int          C_DELIVERED    = 4;
  localparam int          C_CPU_RX       = 5;
  localparam int          C_CPU_CLAIMED  = 6;
  localparam int          C_CPU_DROPPED  = 7;
  localparam int          C_CPU_TX       = 8;
  localparam int          C_CPU_DISCARD  = 9;
  localparam int          C_CPU_REJECT   = 10;

  localparam logic [31:0] ID_VALUE         = id4("P", "R", "O", "T");
  localparam logic [31:0] VERSION_VALUE    = 32'h10222026;
  localparam logic [31:0] DEFAULT_NETMASK  = {8'd255, 8'd255, 8'd255, 8'd0};
  localparam logic [31:0] DEFAULT_GATEWAY  = {8'd192, 8'd169, 8'd1, 8'd1};
  localparam logic [7:0]  SOCKETS_REPORTED = LEAF_PRESENT[0] ? 8'(NUM_SOCKETS) : 8'd0;
  localparam logic [31:0] CAPS_VALUE       = {SOCKETS_REPORTED, 8'(EGRESS_FIFO_KB), 8'(INGRESS_FIFO_KB),
                                              2'd0, CPU_PATH_PRESENT, LEAF_PRESENT};
  localparam logic [31:0] CPU_CAPS_VALUE   = CPU_PATH_PRESENT ? {16'd0, 8'(CPU_TX_FIFO_KB), 8'(CPU_RX_FIFO_KB)} : 32'd0;

  logic [15:0] mac_hi_staged;
  logic [31:0] static_ip;
  logic [31:0] netmask;
  logic [31:0] gateway;
  logic        cnt_clear;
  logic        dhcp_in_use;
  logic [31:0] status_word;
  logic [31:0] ctrl_word;
  logic [31:0] cnt_now  [N_CNT];
  logic [31:0] cnt_base [N_CNT];

  assign cnt_clear   = reg_wr_en && (reg_wr_addr == REG_CTRL) && reg_wr_data[CTRL_CNT_CLEAR_BIT];
  assign dhcp_in_use = LEAF_PRESENT[LEAF_DHCP] && leaf_enable[LEAF_DHCP] && lease_valid;

  // The free-running counts, by slot.
  always_comb begin
    cnt_now[C_IN_FRAMES]   = cnt_ingress_frames;
    cnt_now[C_IN_FILTERED] = cnt_ingress_filtered;
    cnt_now[C_IN_DROPPED]  = cnt_ingress_dropped;
    cnt_now[C_EGRESS]      = cnt_egress_frames;
    cnt_now[C_DELIVERED]   = cnt_delivered;
    cnt_now[C_CPU_RX]      = cnt_cpu_rx_frames;
    cnt_now[C_CPU_CLAIMED] = cnt_cpu_rx_claimed;
    cnt_now[C_CPU_DROPPED] = cnt_cpu_rx_dropped;
    cnt_now[C_CPU_TX]      = cnt_cpu_tx_frames;
    cnt_now[C_CPU_DISCARD] = cnt_cpu_tx_discard;
    cnt_now[C_CPU_REJECT]  = cnt_cpu_tx_reject;
  end

  // Writable registers: node address, CTRL fields.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      local_mac       <= DEFAULT_LOCAL_MAC;
      mac_hi_staged   <= DEFAULT_LOCAL_MAC[47:32];
      static_ip       <= DEFAULT_LOCAL_IP;
      netmask         <= DEFAULT_NETMASK;
      gateway         <= DEFAULT_GATEWAY;
      filter_enable   <= 1'b1;
      cpu_path_enable <= CPU_PATH_PRESENT;
      leaf_enable     <= LEAF_PRESENT;
    end else begin
      if (reg_wr_en) begin
        case (reg_wr_addr)
          REG_CTRL: begin
            filter_enable   <= reg_wr_data[CTRL_FILTER_ENABLE_BIT];
            cpu_path_enable <= reg_wr_data[CTRL_CPU_PATH_ENABLE_BIT] && CPU_PATH_PRESENT;
            leaf_enable     <= reg_wr_data[CTRL_LEAF_ENABLE_LSB +: 5] & LEAF_PRESENT;
          end
          REG_LOCAL_MAC_HI:     mac_hi_staged <= reg_wr_data[15:0];
          REG_LOCAL_MAC_LO:     local_mac     <= {mac_hi_staged, reg_wr_data};
          REG_STATIC_IP:        static_ip     <= reg_wr_data;
          REG_NETMASK:          netmask       <= reg_wr_data;
          REG_GATEWAY:          gateway       <= reg_wr_data;
          default: ;
        endcase
      end
    end
  end

  // Counter bases: every count is taken at CNT_CLEAR.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      for (int i = 0; i < N_CNT; i++) cnt_base[i] <= '0;
    end else if (cnt_clear) begin
      for (int i = 0; i < N_CNT; i++) cnt_base[i] <= cnt_now[i];
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
    ctrl_word[CTRL_CPU_PATH_ENABLE_BIT]          = cpu_path_enable;
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
    status_word[STATUS_CPU_RX_FULL_BIT]          = cpu_rx_full;
    status_word[STATUS_CPU_RX_PEND_BIT]          = cpu_rx_pending;
    status_word[STATUS_CPU_TX_PEND_BIT]          = cpu_tx_pending;
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
        REG_CPU_CAPS:          reg_rd_data <= CPU_CAPS_VALUE;
        REG_INGRESS_FRAMES:    reg_rd_data <= cnt_now[C_IN_FRAMES]   - cnt_base[C_IN_FRAMES];
        REG_INGRESS_FILTERED:  reg_rd_data <= cnt_now[C_IN_FILTERED] - cnt_base[C_IN_FILTERED];
        REG_INGRESS_DROPPED:   reg_rd_data <= cnt_now[C_IN_DROPPED]  - cnt_base[C_IN_DROPPED];
        REG_EGRESS_FRAMES:     reg_rd_data <= cnt_now[C_EGRESS]      - cnt_base[C_EGRESS];
        REG_DELIVERED_FRAMES:  reg_rd_data <= cnt_now[C_DELIVERED]   - cnt_base[C_DELIVERED];
        REG_CPU_RX_FRAMES:     reg_rd_data <= cnt_now[C_CPU_RX]      - cnt_base[C_CPU_RX];
        REG_CPU_RX_CLAIMED:    reg_rd_data <= cnt_now[C_CPU_CLAIMED] - cnt_base[C_CPU_CLAIMED];
        REG_CPU_RX_DROPPED:    reg_rd_data <= cnt_now[C_CPU_DROPPED] - cnt_base[C_CPU_DROPPED];
        REG_CPU_TX_FRAMES:     reg_rd_data <= cnt_now[C_CPU_TX]      - cnt_base[C_CPU_TX];
        REG_CPU_TX_DISCARDED:  reg_rd_data <= cnt_now[C_CPU_DISCARD] - cnt_base[C_CPU_DISCARD];
        REG_CPU_TX_REJECTED:   reg_rd_data <= cnt_now[C_CPU_REJECT]  - cnt_base[C_CPU_REJECT];
        default:               reg_rd_data <= '0;
      endcase
    end
  end

endmodule
