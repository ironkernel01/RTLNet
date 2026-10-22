// -----------------------------------------------------------------------------
// File: rtlnet_axil_decoder.sv
// Purpose: route one AXI4-Lite master to N AXI4-Lite slaves by address window.
// Overview:
//   * Slave i owns addresses with (addr & ~(SLAVE_SIZE[i]-1)) == SLAVE_BASE[i]
//     (power-of-two window sizes, bases aligned to their size).
//   * One transaction in flight. The decoder registers the request, drives the
//     selected slave port from registers, and returns the slave's response.
//     An address that matches no window is answered DECERR (read data 0).
//   * Every output is a flop; the decoder adds a few clocks per access, which
//     is irrelevant for control registers and keeps timing trivial.
//   * Outputs to slave i carry the full ADDR_W address; each slave decodes its
//     own low bits.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: aclk only; aresetn synchronous to it, active low.
// -----------------------------------------------------------------------------
module rtlnet_axil_decoder #(
  parameter int                       N          = 2,       // slave ports
  parameter int                       ADDR_W     = 32,
  parameter logic [N*ADDR_W-1:0]      SLAVE_BASE = '0,      // base of slave i at [i*ADDR_W +: ADDR_W]
  parameter logic [N*ADDR_W-1:0]      SLAVE_SIZE = '0       // window size in bytes, power of two
)(
  // Clock and synchronous active-low reset.
  input  logic                aclk,
  input  logic                aresetn,

  // AXI4-Lite slave port from the master (CPU).
  input  logic [ADDR_W-1:0]   s_axi_awaddr,
  input  logic                s_axi_awvalid,
  output logic                s_axi_awready,
  input  logic [31:0]         s_axi_wdata,
  input  logic [3:0]          s_axi_wstrb,
  input  logic                s_axi_wvalid,
  output logic                s_axi_wready,
  output logic [1:0]          s_axi_bresp,
  output logic                s_axi_bvalid,
  input  logic                s_axi_bready,
  input  logic [ADDR_W-1:0]   s_axi_araddr,
  input  logic                s_axi_arvalid,
  output logic                s_axi_arready,
  output logic [31:0]         s_axi_rdata,
  output logic [1:0]          s_axi_rresp,
  output logic                s_axi_rvalid,
  input  logic                s_axi_rready,

  // N AXI4-Lite master ports, slave i at [i*W +: W] of each packed bus.
  output logic [N*ADDR_W-1:0] m_axi_awaddr,
  output logic [N-1:0]        m_axi_awvalid,
  input  logic [N-1:0]        m_axi_awready,
  output logic [N*32-1:0]     m_axi_wdata,
  output logic [N*4-1:0]      m_axi_wstrb,
  output logic [N-1:0]        m_axi_wvalid,
  input  logic [N-1:0]        m_axi_wready,
  input  logic [N*2-1:0]      m_axi_bresp,
  input  logic [N-1:0]        m_axi_bvalid,
  output logic [N-1:0]        m_axi_bready,
  output logic [N*ADDR_W-1:0] m_axi_araddr,
  output logic [N-1:0]        m_axi_arvalid,
  input  logic [N-1:0]        m_axi_arready,
  input  logic [N*32-1:0]     m_axi_rdata,
  input  logic [N*2-1:0]      m_axi_rresp,
  input  logic [N-1:0]        m_axi_rvalid,
  output logic [N-1:0]        m_axi_rready
);

  localparam int  SEL_W  = (N > 1) ? $clog2(N) : 1;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  localparam logic [2:0] S_IDLE  = 3'd0;
  localparam logic [2:0] S_WADDR = 3'd1;   // AW/W outstanding to the selected slave
  localparam logic [2:0] S_WRESP = 3'd2;   // waiting for that slave's B
  localparam logic [2:0] S_RADDR = 3'd3;   // AR outstanding
  localparam logic [2:0] S_RRESP = 3'd4;   // waiting for that slave's R
  localparam logic [2:0] S_BOUT  = 3'd5;   // B to the master
  localparam logic [2:0] S_ROUT  = 3'd6;   // R to the master

  logic [2:0]        state;
  logic [SEL_W-1:0]  sel;
  logic              aw_done;
  logic              w_done;
  logic [ADDR_W-1:0] req_addr;
  logic [31:0]       req_wdata;
  logic [3:0]        req_wstrb;

  // Window match of an address against every slave.
  function automatic logic [N-1:0] decode(input logic [ADDR_W-1:0] addr);
    logic [N-1:0] hit;
    for (int i = 0; i < N; i++) begin
      hit[i] = ((addr & ~(SLAVE_SIZE[i*ADDR_W +: ADDR_W] - 1'b1)) == SLAVE_BASE[i*ADDR_W +: ADDR_W]);
    end
    return hit;
  endfunction

  // Lowest-index hit (windows are expected not to overlap).
  function automatic logic [SEL_W:0] first_hit(input logic [N-1:0] hit);
    logic [SEL_W:0] r;
    r = '0;
    for (int i = N - 1; i >= 0; i--) if (hit[i]) r = {1'b1, SEL_W'(i)};
    return r;
  endfunction

  logic [SEL_W:0] aw_pick;
  logic [SEL_W:0] ar_pick;
  assign aw_pick = first_hit(decode(s_axi_awaddr));
  assign ar_pick = first_hit(decode(s_axi_araddr));

  // Request routing, response return; one transaction at a time.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state         <= S_IDLE;
      sel           <= '0;
      aw_done       <= 1'b0;
      w_done        <= 1'b0;
      req_addr      <= '0;
      req_wdata     <= '0;
      req_wstrb     <= '0;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_bresp   <= 2'b00;
      s_axi_rvalid  <= 1'b0;
      s_axi_rresp   <= 2'b00;
      s_axi_rdata   <= '0;
      m_axi_awvalid <= '0;
      m_axi_wvalid  <= '0;
      m_axi_bready  <= '0;
      m_axi_arvalid <= '0;
      m_axi_rready  <= '0;
    end else begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;
      case (state)
        S_IDLE: begin
          if (s_axi_awvalid && s_axi_wvalid && !s_axi_awready) begin
            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b1;
            req_addr      <= s_axi_awaddr;
            req_wdata     <= s_axi_wdata;
            req_wstrb     <= s_axi_wstrb;
            if (aw_pick[SEL_W]) begin
              sel                         <= aw_pick[SEL_W-1:0];
              m_axi_awvalid[aw_pick[SEL_W-1:0]] <= 1'b1;
              m_axi_wvalid[aw_pick[SEL_W-1:0]]  <= 1'b1;
              aw_done                     <= 1'b0;
              w_done                      <= 1'b0;
              state                       <= S_WADDR;
            end else begin
              s_axi_bresp  <= RESP_DECERR;
              s_axi_bvalid <= 1'b1;
              state        <= S_BOUT;
            end
          end else if (s_axi_arvalid && !s_axi_arready) begin
            s_axi_arready <= 1'b1;
            req_addr      <= s_axi_araddr;
            if (ar_pick[SEL_W]) begin
              sel                         <= ar_pick[SEL_W-1:0];
              m_axi_arvalid[ar_pick[SEL_W-1:0]] <= 1'b1;
              state                       <= S_RADDR;
            end else begin
              s_axi_rresp  <= RESP_DECERR;
              s_axi_rdata  <= '0;
              s_axi_rvalid <= 1'b1;
              state        <= S_ROUT;
            end
          end
        end
        S_WADDR: begin
          if (m_axi_awvalid[sel] && m_axi_awready[sel]) begin
            m_axi_awvalid[sel] <= 1'b0;
            aw_done            <= 1'b1;
          end
          if (m_axi_wvalid[sel] && m_axi_wready[sel]) begin
            m_axi_wvalid[sel] <= 1'b0;
            w_done            <= 1'b1;
          end
          if ((aw_done || (m_axi_awvalid[sel] && m_axi_awready[sel])) &&
              (w_done  || (m_axi_wvalid[sel]  && m_axi_wready[sel]))) begin
            m_axi_bready[sel] <= 1'b1;
            state             <= S_WRESP;
          end
        end
        S_WRESP: begin
          if (m_axi_bvalid[sel] && m_axi_bready[sel]) begin
            m_axi_bready[sel] <= 1'b0;
            s_axi_bresp       <= m_axi_bresp[sel*2 +: 2];
            s_axi_bvalid      <= 1'b1;
            state             <= S_BOUT;
          end
        end
        S_RADDR: begin
          if (m_axi_arvalid[sel] && m_axi_arready[sel]) begin
            m_axi_arvalid[sel] <= 1'b0;
            m_axi_rready[sel]  <= 1'b1;
            state              <= S_RRESP;
          end
        end
        S_RRESP: begin
          if (m_axi_rvalid[sel] && m_axi_rready[sel]) begin
            m_axi_rready[sel] <= 1'b0;
            s_axi_rresp       <= m_axi_rresp[sel*2 +: 2];
            s_axi_rdata       <= m_axi_rdata[sel*32 +: 32];
            s_axi_rvalid      <= 1'b1;
            state             <= S_ROUT;
          end
        end
        S_BOUT: begin
          if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            state        <= S_IDLE;
          end
        end
        S_ROUT: begin
          if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            state        <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  // Every slave port sees the registered request; only the selected port's
  // valid is ever raised.
  always_comb begin
    for (int i = 0; i < N; i++) begin
      m_axi_awaddr[i*ADDR_W +: ADDR_W] = req_addr;
      m_axi_araddr[i*ADDR_W +: ADDR_W] = req_addr;
      m_axi_wdata[i*32 +: 32]          = req_wdata;
      m_axi_wstrb[i*4 +: 4]            = req_wstrb;
    end
  end

endmodule
