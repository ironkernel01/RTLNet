// -----------------------------------------------------------------------------
// Purpose: adapt RTLNet full-width 128-bit AXI4 bursts to 64-bit Zynq AXI3 HP.
// Overview: one transaction per direction; reads and writes progress independently.
//   Input contract: aligned 16-byte INCR beats, 1..16 beats, no 4 KiB crossing,
//   no exclusives. Each beat becomes low then high 64-bit halves with the exact
//   corresponding eight byte strobes. Bursts split at 16 HP beats. One upstream
//   B aggregates all child responses; read RRESP aggregates each pair of halves.
//   IDs remain unchanged; AXI3 WID equals the accepted AWID. No W interleaving.
//   Responses use OKAY/SLVERR/DECERR; EXOKAY is outside the no-exclusive contract.
// Language: SystemVerilog-2012. Clock: aclk, synchronous active-low aresetn.
// Revision: 11-14-2026. Initial HP bridge for the Zybo integration.
// -----------------------------------------------------------------------------
module rtlnet_axi_hp_bridge #(
  parameter int ID_W = 6
) (
  // Core/HP clock; both sides reset together with the PS/PL memory subsystem.
  input logic aclk,
  input logic aresetn,

  // RTLNet AXI4 input, 128 bits, full-width INCR only, up to sixteen beats.
  input logic [ID_W-1:0] s_axi_awid,
  input logic [31:0] s_axi_awaddr,
  input logic [7:0] s_axi_awlen,
  input logic [2:0] s_axi_awsize,
  input logic [1:0] s_axi_awburst,
  input logic s_axi_awvalid,
  output logic s_axi_awready,
  input logic [127:0] s_axi_wdata,
  input logic [15:0] s_axi_wstrb,
  input logic s_axi_wlast,
  input logic s_axi_wvalid,
  output logic s_axi_wready,
  output logic [ID_W-1:0] s_axi_bid,
  output logic [1:0] s_axi_bresp,
  output logic s_axi_bvalid,
  input logic s_axi_bready,
  input logic [ID_W-1:0] s_axi_arid,
  input logic [31:0] s_axi_araddr,
  input logic [7:0] s_axi_arlen,
  input logic [2:0] s_axi_arsize,
  input logic [1:0] s_axi_arburst,
  input logic s_axi_arvalid,
  output logic s_axi_arready,
  output logic [ID_W-1:0] s_axi_rid,
  output logic [127:0] s_axi_rdata,
  output logic [1:0] s_axi_rresp,
  output logic s_axi_rlast,
  output logic s_axi_rvalid,
  input logic s_axi_rready,

  // PS HP AXI3, 64 bits, at most sixteen beats per burst; no optional sidebands.
  output logic [ID_W-1:0] m_axi_awid,
  output logic [31:0] m_axi_awaddr,
  output logic [3:0] m_axi_awlen,
  output logic [2:0] m_axi_awsize,
  output logic [1:0] m_axi_awburst,
  output logic m_axi_awvalid,
  input logic m_axi_awready,
  output logic [ID_W-1:0] m_axi_wid,
  output logic [63:0] m_axi_wdata,
  output logic [7:0] m_axi_wstrb,
  output logic m_axi_wlast,
  output logic m_axi_wvalid,
  input logic m_axi_wready,
  input logic [ID_W-1:0] m_axi_bid,
  input logic [1:0] m_axi_bresp,
  input logic m_axi_bvalid,
  output logic m_axi_bready,
  output logic [ID_W-1:0] m_axi_arid,
  output logic [31:0] m_axi_araddr,
  output logic [3:0] m_axi_arlen,
  output logic [2:0] m_axi_arsize,
  output logic [1:0] m_axi_arburst,
  output logic m_axi_arvalid,
  input logic m_axi_arready,
  input logic [ID_W-1:0] m_axi_rid,
  input logic [63:0] m_axi_rdata,
  input logic [1:0] m_axi_rresp,
  input logic m_axi_rlast,
  input logic m_axi_rvalid,
  output logic m_axi_rready
);
  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_ADDR = 3'd1;
  localparam logic [2:0] S_DATA = 3'd2;
  localparam logic [2:0] S_RESP = 3'd3;
  localparam logic [2:0] S_DONE = 3'd4;
  logic [2:0] w_state;
  logic [2:0] r_state;
  logic [ID_W-1:0] write_id;
  logic [ID_W-1:0] read_id;
  logic [31:0] write_addr;
  logic [31:0] read_addr;
  logic [5:0] write_left;
  logic [5:0] read_left;
  logic [4:0] write_chunk;
  logic [4:0] read_chunk;
  logic [4:0] write_in_chunk;
  logic [4:0] read_in_chunk;
  logic [127:0] write_word;
  logic [15:0] write_strobes;
  logic write_have_word;
  logic write_upper;
  logic [1:0] write_response;
  logic [63:0] read_lower;
  logic [1:0] read_lower_response;
  logic read_upper;

  // Child address fields remain unchanged while their valid is held.
  assign s_axi_awready = aresetn && (w_state == S_IDLE);
  assign s_axi_wready = aresetn && (w_state == S_DATA) && !write_have_word;
  assign s_axi_bid = write_id;
  assign s_axi_bresp = write_response;
  assign s_axi_bvalid = (w_state == S_DONE);
  assign m_axi_awid = write_id;
  assign m_axi_awaddr = write_addr;
  assign m_axi_awlen = write_chunk[3:0] - 1'b1;
  assign m_axi_awsize = 3'd3;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awvalid = (w_state == S_ADDR);
  assign m_axi_wid = write_id;
  assign m_axi_wdata = write_upper ? write_word[127:64] : write_word[63:0];
  assign m_axi_wstrb = write_upper ? write_strobes[15:8] : write_strobes[7:0];
  assign m_axi_wlast = (write_in_chunk == 1);
  assign m_axi_wvalid = (w_state == S_DATA) && write_have_word;
  assign m_axi_bready = (w_state == S_RESP);
  assign s_axi_arready = aresetn && (r_state == S_IDLE);
  assign s_axi_rid = read_id;
  assign m_axi_arid = read_id;
  assign m_axi_araddr = read_addr;
  assign m_axi_arlen = read_chunk[3:0] - 1'b1;
  assign m_axi_arsize = 3'd3;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arvalid = (r_state == S_ADDR);
  assign m_axi_rready = (r_state == S_DATA) && (!read_upper || !s_axi_rvalid || s_axi_rready);

  // Write splitter holds the original word until both halves leave the bridge.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      w_state <= S_IDLE;
      write_id <= '0;
      write_addr <= '0;
      write_left <= '0;
      write_chunk <= '0;
      write_in_chunk <= '0;
      write_word <= '0;
      write_strobes <= '0;
      write_have_word <= 1'b0;
      write_upper <= 1'b0;
      write_response <= 2'b00;
    end else begin
      case (w_state)
        S_IDLE: if (s_axi_awvalid && s_axi_awready) begin
          write_id <= s_axi_awid;
          write_addr <= s_axi_awaddr;
          write_left <= ({2'd0, s_axi_awlen[3:0]} + 1'b1) << 1;
          write_chunk <= (s_axi_awlen >= 7) ? 5'd16 : (({1'd0, s_axi_awlen[3:0]} + 1'b1) << 1);
          write_response <= 2'b00;
          w_state <= S_ADDR;
        end
        S_ADDR: if (m_axi_awready) begin
          write_in_chunk <= write_chunk;
          w_state <= S_DATA;
        end
        S_DATA: begin
          if (s_axi_wvalid && s_axi_wready) begin
            write_word <= s_axi_wdata;
            write_strobes <= s_axi_wstrb;
            write_have_word <= 1'b1;
            write_upper <= 1'b0;
          end
          if (m_axi_wvalid && m_axi_wready) begin
            write_left <= write_left - 1'b1;
            write_in_chunk <= write_in_chunk - 1'b1;
            write_upper <= !write_upper;
            if (write_upper) write_have_word <= 1'b0;
            if (write_in_chunk == 1) w_state <= S_RESP;
          end
        end
        S_RESP: if (m_axi_bvalid) begin
          write_response <= write_response | m_axi_bresp;
          if (write_left == 0) w_state <= S_DONE;
          else begin
            write_addr <= write_addr + 32'd128;
            write_chunk <= (write_left > 16) ? 5'd16 : write_left[4:0];
            w_state <= S_ADDR;
          end
        end
        S_DONE: if (s_axi_bready) w_state <= S_IDLE;
        default: w_state <= S_IDLE;
      endcase
    end
  end

  // Read joiner buffers one low half and one complete upstream beat under stalls.
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      r_state <= S_IDLE;
      read_id <= '0;
      read_addr <= '0;
      read_left <= '0;
      read_chunk <= '0;
      read_in_chunk <= '0;
      read_lower <= '0;
      read_lower_response <= '0;
      read_upper <= 1'b0;
      s_axi_rdata <= '0;
      s_axi_rresp <= '0;
      s_axi_rlast <= 1'b0;
      s_axi_rvalid <= 1'b0;
    end else begin
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
      case (r_state)
        S_IDLE: if (s_axi_arvalid && s_axi_arready) begin
          read_id <= s_axi_arid;
          read_addr <= s_axi_araddr;
          read_left <= ({2'd0, s_axi_arlen[3:0]} + 1'b1) << 1;
          read_chunk <= (s_axi_arlen >= 7) ? 5'd16 : (({1'd0, s_axi_arlen[3:0]} + 1'b1) << 1);
          read_upper <= 1'b0;
          r_state <= S_ADDR;
        end
        S_ADDR: if (m_axi_arready) begin
          read_in_chunk <= read_chunk;
          r_state <= S_DATA;
        end
        S_DATA: if (m_axi_rvalid && m_axi_rready) begin
          read_left <= read_left - 1'b1;
          read_in_chunk <= read_in_chunk - 1'b1;
          read_upper <= !read_upper;
          if (!read_upper) begin
            read_lower <= m_axi_rdata;
            read_lower_response <= m_axi_rresp;
          end else begin
            s_axi_rdata <= {m_axi_rdata, read_lower};
            s_axi_rresp <= m_axi_rresp | read_lower_response;
            s_axi_rlast <= (read_left == 1);
            s_axi_rvalid <= 1'b1;
          end
          if (read_in_chunk == 1) begin
            if (read_left == 1) r_state <= S_DONE;
            else begin
              read_addr <= read_addr + 32'd128;
              read_chunk <= ((read_left - 1'b1) > 16) ? 5'd16 : (read_left[4:0] - 1'b1);
              r_state <= S_ADDR;
            end
          end
        end
        S_DONE: if (s_axi_rvalid && s_axi_rready) r_state <= S_IDLE;
        default: r_state <= S_IDLE;
      endcase
    end
  end

  // Simulation rejects upstream traffic outside the documented fixed-width contract.
  // synthesis translate_off
  always @(posedge aclk) begin
    if (aresetn) begin
      if (s_axi_awvalid && s_axi_awready &&
          (s_axi_awlen > 15 || s_axi_awsize != 4 || s_axi_awburst != 1 || s_axi_awaddr[3:0] != 0))
        $error("rtlnet_axi_hp_bridge: unsupported write burst");
      if (s_axi_arvalid && s_axi_arready &&
          (s_axi_arlen > 15 || s_axi_arsize != 4 || s_axi_arburst != 1 || s_axi_araddr[3:0] != 0))
        $error("rtlnet_axi_hp_bridge: unsupported read burst");
      if (s_axi_wvalid && s_axi_wready && (s_axi_wlast != (write_left == 2)))
        $error("rtlnet_axi_hp_bridge: WLAST mismatch");
      if (m_axi_rvalid && m_axi_rready &&
          ((m_axi_rlast != (read_in_chunk == 1)) || m_axi_rid != read_id))
        $error("rtlnet_axi_hp_bridge: HP read response mismatch");
      if (m_axi_bvalid && m_axi_bready && m_axi_bid != write_id)
        $error("rtlnet_axi_hp_bridge: HP write response ID mismatch");
    end
  end
  // synthesis translate_on
endmodule
