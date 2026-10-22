// -----------------------------------------------------------------------------
// File: rtlnet_axis_reg_slice.sv
// Purpose: full-throughput AXI4-Stream register slice (one output register
//   plus one skid register) for the RTLNet stream. Every output is a flop:
//   s_tready to the source; m_tdata/m_tkeep/m_tlast/m_tvalid to the sink.
// Overview:
//   * s_tready = "skid register empty" (registered), so the source's ready
//     path ends at a flop and the sink's ready never reaches the source
//     combinationally.
//   * When the sink stalls while the source offers a beat, that beat lands in
//     the skid register and s_tready drops the next cycle. No beat is lost,
//     duplicated or reordered. Capacity two beats, latency one clock.
//   * resetn is synchronous, active low; both valid flags clear. With
//     RESET_DATA = 1 the payload registers also clear (known idle values on a
//     boundary that a bench checks every cycle).
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk is the stream clock; resetn is synchronous to it.
// -----------------------------------------------------------------------------
module rtlnet_axis_reg_slice #(
  parameter int DATA_W     = 64,           // tdata width; tkeep is DATA_W/8
  parameter bit RESET_DATA = 1'b0          // also clear payload registers in reset
)(
  // Stream clock and synchronous active-low reset.
  input  logic                clk,
  input  logic                resetn,

  // Upstream (slave) side: RTLNet stream in.
  input  logic [DATA_W-1:0]   s_tdata,
  input  logic [DATA_W/8-1:0] s_tkeep,
  input  logic                s_tlast,
  input  logic                s_tvalid,
  output logic                s_tready,

  // Downstream (master) side: the same beats, one clock later.
  output logic [DATA_W-1:0]   m_tdata,
  output logic [DATA_W/8-1:0] m_tkeep,
  output logic                m_tlast,
  output logic                m_tvalid,
  input  logic                m_tready
);

  localparam int W = DATA_W + DATA_W / 8 + 1;    // {tlast, tkeep, tdata}

  logic [W-1:0] out_beat  = '0;
  logic         out_valid;
  logic [W-1:0] skid_beat = '0;
  logic         skid_valid;
  logic [W-1:0] s_beat;
  logic         out_take;
  logic         s_ready_q;

  assign s_beat   = {s_tlast, s_tkeep, s_tdata};
  assign out_take = m_tready || !out_valid;
  assign {m_tlast, m_tkeep, m_tdata} = out_beat;
  assign m_tvalid = out_valid;
  assign s_tready = s_ready_q;

  // Output register loads from the skid register first, else from the source;
  // a beat accepted while the output is stalled waits in the skid register.
  always_ff @(posedge clk) begin
    if (!resetn) begin
      out_valid  <= 1'b0;
      skid_valid <= 1'b0;
      s_ready_q  <= 1'b0;
      if (RESET_DATA) begin
        out_beat  <= '0;
        skid_beat <= '0;
      end
    end else begin
      if (out_take) begin
        if (skid_valid) begin
          out_beat   <= skid_beat;
          out_valid  <= 1'b1;
          skid_valid <= 1'b0;
          s_ready_q  <= 1'b1;
        end else begin
          out_beat   <= s_beat;
          out_valid  <= s_tvalid && s_ready_q;
          s_ready_q  <= 1'b1;
        end
      end else if (s_tvalid && s_ready_q) begin
        skid_beat  <= s_beat;
        skid_valid <= 1'b1;
        s_ready_q  <= 1'b0;
      end
    end
  end

endmodule
