// -----------------------------------------------------------------------------
// File: rtlnet_axil_cdc.sv
// Purpose: carry AXI4-Lite transactions from one clock to another so a core's
//   register file can live in the core's own clock.
// Overview:
//   * Slave side (s_clk) accepts one whole transaction (write: address, data,
//     strobe; read: address) into a held request bundle and flips req_toggle.
//   * Master side (m_clk) sees the flip through rtlnet_sync (u_req_sync),
//     issues the transaction on its AXI4-Lite master port, captures the
//     response (bresp, or rresp + rdata) into a held response bundle and flips
//     ack_toggle.
//   * Slave side sees the flip through rtlnet_sync (u_ack_sync) and answers on
//     its B or R channel.
//   * The bundles do not change while their toggle crosses, so they are
//     bounded by scripts/rtlnet_constrain_cdc.tcl (set_max_delay
//     -datapath_only of the destination period) rather than synchronized bit
//     by bit. Register names `req_*_hold` and `rsp_*_hold` are that interface.
//   * One transaction in flight. Both sides must be reset together (derive
//     both resets from one assertion); a one-sided reset mid-transaction is
//     not supported.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: s_clk (AXI4-Lite slave side), m_clk (AXI4-Lite master side).
// -----------------------------------------------------------------------------
module rtlnet_axil_cdc #(
  parameter int ADDR_W = 12,               // address bits carried
  parameter int STAGES = 3,                // toggle synchronizer depth
  parameter bit SYNC   = 1'b0              // 1: s_clk and m_clk are the same clock, direct pass-through, no crossing
)(
  // AXI4-Lite slave, s_clk domain.
  input  logic              s_clk,
  input  logic              s_resetn,      // synchronous to s_clk, active low
  input  logic [ADDR_W-1:0] s_axi_awaddr,
  input  logic              s_axi_awvalid,
  output logic              s_axi_awready,
  input  logic [31:0]       s_axi_wdata,
  input  logic [3:0]        s_axi_wstrb,
  input  logic              s_axi_wvalid,
  output logic              s_axi_wready,
  output logic [1:0]        s_axi_bresp,
  output logic              s_axi_bvalid,
  input  logic              s_axi_bready,
  input  logic [ADDR_W-1:0] s_axi_araddr,
  input  logic              s_axi_arvalid,
  output logic              s_axi_arready,
  output logic [31:0]       s_axi_rdata,
  output logic [1:0]        s_axi_rresp,
  output logic              s_axi_rvalid,
  input  logic              s_axi_rready,

  // AXI4-Lite master, m_clk domain (to the core's register slave).
  input  logic              m_clk,
  input  logic              m_resetn,      // synchronous to m_clk, active low
  output logic [ADDR_W-1:0] m_axi_awaddr,
  output logic              m_axi_awvalid,
  input  logic              m_axi_awready,
  output logic [31:0]       m_axi_wdata,
  output logic [3:0]        m_axi_wstrb,
  output logic              m_axi_wvalid,
  input  logic              m_axi_wready,
  input  logic [1:0]        m_axi_bresp,
  input  logic              m_axi_bvalid,
  output logic              m_axi_bready,
  output logic [ADDR_W-1:0] m_axi_araddr,
  output logic              m_axi_arvalid,
  input  logic              m_axi_arready,
  input  logic [31:0]       m_axi_rdata,
  input  logic [1:0]        m_axi_rresp,
  input  logic              m_axi_rvalid,
  output logic              m_axi_rready
);

  // SYNC = 1: the master side runs on the slave side's clock. The register slave on the master side answers the handshakes itself, so the
  // two ports are wired straight through (no flop, no crossing, nothing for rtlnet_constrain_cdc.tcl to constrain).
  if (SYNC) begin : g_sync
    assign m_axi_awaddr  = s_axi_awaddr;
    assign m_axi_awvalid = s_axi_awvalid;
    assign s_axi_awready = m_axi_awready;
    assign m_axi_wdata   = s_axi_wdata;
    assign m_axi_wstrb   = s_axi_wstrb;
    assign m_axi_wvalid  = s_axi_wvalid;
    assign s_axi_wready  = m_axi_wready;
    assign s_axi_bresp   = m_axi_bresp;
    assign s_axi_bvalid  = m_axi_bvalid;
    assign m_axi_bready  = s_axi_bready;
    assign m_axi_araddr  = s_axi_araddr;
    assign m_axi_arvalid = s_axi_arvalid;
    assign s_axi_arready = m_axi_arready;
    assign s_axi_rdata   = m_axi_rdata;
    assign s_axi_rresp   = m_axi_rresp;
    assign s_axi_rvalid  = m_axi_rvalid;
    assign m_axi_rready  = s_axi_rready;
  end else begin : g_cdc

  // ---------------------------------------------------------------------------
  // Slave side (s_clk)
  // ---------------------------------------------------------------------------
  localparam logic [1:0] SS_IDLE = 2'd0;
  localparam logic [1:0] SS_WAIT = 2'd1;   // request crossing, waiting for the acknowledge
  localparam logic [1:0] SS_RESP = 2'd2;   // B or R handshake

  logic [1:0]        s_state;
  logic              req_toggle;
  logic              req_is_write_hold;
  logic [ADDR_W-1:0] req_addr_hold;
  logic [31:0]       req_wdata_hold;
  logic [3:0]        req_wstrb_hold;
  logic              ack_sync;
  logic              ack_seen;

  // ---------------------------------------------------------------------------
  // Master side (m_clk)
  // ---------------------------------------------------------------------------
  localparam logic [2:0] MS_IDLE  = 3'd0;
  localparam logic [2:0] MS_WADDR = 3'd1;  // AW and W outstanding
  localparam logic [2:0] MS_WRESP = 3'd2;  // waiting for B
  localparam logic [2:0] MS_RADDR = 3'd3;  // AR outstanding
  localparam logic [2:0] MS_RRESP = 3'd4;  // waiting for R

  logic [2:0]        m_state;
  logic              req_sync;
  logic              req_seen;
  logic              ack_toggle;
  logic [1:0]        rsp_resp_hold;
  logic [31:0]       rsp_rdata_hold;
  logic              aw_done;
  logic              w_done;

  // Request toggle into m_clk; acknowledge toggle into s_clk.
  rtlnet_sync #(.WIDTH(1), .STAGES(STAGES)) u_req_sync (
    .clk(m_clk), .resetn(m_resetn), .d(req_toggle), .q(req_sync));
  rtlnet_sync #(.WIDTH(1), .STAGES(STAGES)) u_ack_sync (
    .clk(s_clk), .resetn(s_resetn), .d(ack_toggle), .q(ack_sync));

  assign s_axi_bresp = rsp_resp_hold;      // stable from the acknowledge on
  assign s_axi_rresp = rsp_resp_hold;

  // Slave side: capture one transaction, hold it while it crosses, answer it.
  always_ff @(posedge s_clk) begin
    if (!s_resetn) begin
      s_state           <= SS_IDLE;
      req_toggle        <= 1'b0;
      req_is_write_hold <= 1'b0;
      req_addr_hold     <= '0;
      req_wdata_hold    <= '0;
      req_wstrb_hold    <= '0;
      ack_seen          <= 1'b0;
      s_axi_awready     <= 1'b0;
      s_axi_wready      <= 1'b0;
      s_axi_arready     <= 1'b0;
      s_axi_bvalid      <= 1'b0;
      s_axi_rvalid      <= 1'b0;
      s_axi_rdata       <= '0;
    end else begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;
      case (s_state)
        SS_IDLE: begin
          if (s_axi_awvalid && s_axi_wvalid && !s_axi_awready) begin
            req_is_write_hold <= 1'b1;
            req_addr_hold     <= s_axi_awaddr;
            req_wdata_hold    <= s_axi_wdata;
            req_wstrb_hold    <= s_axi_wstrb;
            s_axi_awready     <= 1'b1;
            s_axi_wready      <= 1'b1;
            req_toggle        <= ~req_toggle;
            s_state           <= SS_WAIT;
          end else if (s_axi_arvalid && !s_axi_arready) begin
            req_is_write_hold <= 1'b0;
            req_addr_hold     <= s_axi_araddr;
            s_axi_arready     <= 1'b1;
            req_toggle        <= ~req_toggle;
            s_state           <= SS_WAIT;
          end
        end
        SS_WAIT: begin
          if (ack_sync != ack_seen) begin
            ack_seen <= ack_sync;
            if (req_is_write_hold) s_axi_bvalid <= 1'b1;
            else begin
              s_axi_rvalid <= 1'b1;
              s_axi_rdata  <= rsp_rdata_hold;
            end
            s_state <= SS_RESP;
          end
        end
        SS_RESP: begin
          if ((s_axi_bvalid && s_axi_bready) || (s_axi_rvalid && s_axi_rready)) begin
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_state      <= SS_IDLE;
          end
        end
        default: s_state <= SS_IDLE;
      endcase
    end
  end

  // Master side: issue the held transaction, capture the response, acknowledge.
  always_ff @(posedge m_clk) begin
    if (!m_resetn) begin
      m_state        <= MS_IDLE;
      req_seen       <= 1'b0;
      ack_toggle     <= 1'b0;
      rsp_resp_hold  <= 2'b00;
      rsp_rdata_hold <= '0;
      m_axi_awaddr   <= '0;
      m_axi_awvalid  <= 1'b0;
      m_axi_wdata    <= '0;
      m_axi_wstrb    <= '0;
      m_axi_wvalid   <= 1'b0;
      m_axi_bready   <= 1'b0;
      m_axi_araddr   <= '0;
      m_axi_arvalid  <= 1'b0;
      m_axi_rready   <= 1'b0;
      aw_done        <= 1'b0;
      w_done         <= 1'b0;
    end else begin
      case (m_state)
        MS_IDLE: begin
          if (req_sync != req_seen) begin
            req_seen <= req_sync;
            if (req_is_write_hold) begin
              m_axi_awaddr  <= req_addr_hold;
              m_axi_wdata   <= req_wdata_hold;
              m_axi_wstrb   <= req_wstrb_hold;
              m_axi_awvalid <= 1'b1;
              m_axi_wvalid  <= 1'b1;
              aw_done       <= 1'b0;
              w_done        <= 1'b0;
              m_state       <= MS_WADDR;
            end else begin
              m_axi_araddr  <= req_addr_hold;
              m_axi_arvalid <= 1'b1;
              m_state       <= MS_RADDR;
            end
          end
        end
        MS_WADDR: begin
          if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
            aw_done       <= 1'b1;
          end
          if (m_axi_wvalid && m_axi_wready) begin
            m_axi_wvalid <= 1'b0;
            w_done       <= 1'b1;
          end
          if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
              (w_done  || (m_axi_wvalid  && m_axi_wready))) begin
            m_axi_bready <= 1'b1;
            m_state      <= MS_WRESP;
          end
        end
        MS_WRESP: begin
          if (m_axi_bvalid && m_axi_bready) begin
            m_axi_bready  <= 1'b0;
            rsp_resp_hold <= m_axi_bresp;
            ack_toggle    <= ~ack_toggle;
            m_state       <= MS_IDLE;
          end
        end
        MS_RADDR: begin
          if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b1;
            m_state       <= MS_RRESP;
          end
        end
        MS_RRESP: begin
          if (m_axi_rvalid && m_axi_rready) begin
            m_axi_rready   <= 1'b0;
            rsp_resp_hold  <= m_axi_rresp;
            rsp_rdata_hold <= m_axi_rdata;
            ack_toggle     <= ~ack_toggle;
            m_state        <= MS_IDLE;
          end
        end
        default: m_state <= MS_IDLE;
      endcase
    end
  end

  end

endmodule
