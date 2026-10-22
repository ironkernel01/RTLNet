// -----------------------------------------------------------------------------
// File: rtlnet_axil_slave.sv
// Purpose: AXI4-Lite slave to register-strobe bridge, shared by every RTLNet
//   core so a core only implements its register file.
// Overview:
//   * Write: when AW and W are both valid the transaction is accepted;
//     reg_wr_en pulses one clock with reg_wr_addr/reg_wr_data, but only for a
//     full-word write (wstrb == 4'hF). A partial write is answered OKAY and
//     ignored (RTLNet register rule: all or nothing).
//   * Read: reg_rd_en pulses one clock with reg_rd_addr; the register file
//     presents reg_rd_data on the NEXT clock (registered read mux).
//   * One transaction at a time, writes before reads, every response OKAY.
//   * One registered state variable; synchronous active-low reset.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: s_axi_aclk only; s_axi_aresetn is synchronous to it.
// -----------------------------------------------------------------------------
module rtlnet_axil_slave #(
  parameter int ADDR_W = 12                // byte-address bits decoded by the core
)(
  // AXI4-Lite slave, s_axi_aclk domain, 32-bit data.
  input  logic              s_axi_aclk,
  input  logic              s_axi_aresetn,
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

  // Register-file strobes, same clock. Read data is due one clock after
  // reg_rd_en.
  output logic              reg_wr_en,
  output logic [ADDR_W-1:0] reg_wr_addr,
  output logic [31:0]       reg_wr_data,
  output logic              reg_rd_en,
  output logic [ADDR_W-1:0] reg_rd_addr,
  input  logic [31:0]       reg_rd_data
);

  localparam logic [2:0] S_IDLE  = 3'd0;
  localparam logic [2:0] S_WACK  = 3'd1;   // AW/W handshake this clock, write strobe next
  localparam logic [2:0] S_WRESP = 3'd2;   // B channel
  localparam logic [2:0] S_RADDR = 3'd3;   // AR handshake this clock, read strobe next
  localparam logic [2:0] S_RWAIT = 3'd4;   // register file registers its mux
  localparam logic [2:0] S_RCAP  = 3'd5;   // capture reg_rd_data
  localparam logic [2:0] S_RRESP = 3'd6;   // R channel

  logic [2:0] state;
  logic       wr_full_word;

  assign s_axi_bresp = 2'b00;
  assign s_axi_rresp = 2'b00;

  // One transaction at a time: accept, strobe the register file, respond.
  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      state         <= S_IDLE;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= '0;
      reg_wr_en     <= 1'b0;
      reg_wr_addr   <= '0;
      reg_wr_data   <= '0;
      reg_rd_en     <= 1'b0;
      reg_rd_addr   <= '0;
      wr_full_word  <= 1'b0;
    end else begin
      reg_wr_en     <= 1'b0;
      reg_rd_en     <= 1'b0;
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_arready <= 1'b0;

      case (state)
        S_IDLE: begin
          if (s_axi_awvalid && s_axi_wvalid) begin
            reg_wr_addr   <= s_axi_awaddr;
            reg_wr_data   <= s_axi_wdata;
            wr_full_word  <= (s_axi_wstrb == 4'hF);
            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b1;
            state         <= S_WACK;
          end else if (s_axi_arvalid) begin
            reg_rd_addr   <= s_axi_araddr;
            s_axi_arready <= 1'b1;
            state         <= S_RADDR;
          end
        end
        S_WACK: begin
          reg_wr_en    <= wr_full_word;
          s_axi_bvalid <= 1'b1;
          state        <= S_WRESP;
        end
        S_WRESP: begin
          if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            state        <= S_IDLE;
          end
        end
        S_RADDR: begin
          reg_rd_en <= 1'b1;
          state     <= S_RWAIT;
        end
        S_RWAIT: begin
          state <= S_RCAP;
        end
        S_RCAP: begin
          s_axi_rdata  <= reg_rd_data;
          s_axi_rvalid <= 1'b1;
          state        <= S_RRESP;
        end
        S_RRESP: begin
          if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            state        <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
