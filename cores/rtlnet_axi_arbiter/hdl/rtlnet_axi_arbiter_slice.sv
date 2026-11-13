// -----------------------------------------------------------------------------
// File: rtlnet_axi_arbiter_slice.sv
// Purpose: one-channel register slice (valid/ready with a skid register) for the address channels of rtlnet_axi_arbiter.
// Overview:
//   * Full throughput: one transfer per clock when the downstream side accepts every clock.
//   * Every downstream signal (m_valid, m_data) comes straight from a register. s_ready is the inverse of the skid register's valid flop, a
//     register output: it does not depend on s_valid, s_data or m_ready in the same clock.
//   * The main register holds the transfer offered downstream; the skid register takes one transfer that arrives while the main register is full
//     and the downstream side is not accepting. Data is stable while m_valid is high and m_ready is low (AXI4 rule for the offered transfer).
//   * Latency: one clock from s_valid to m_valid.
// Language: SystemVerilog-2012.
// Revision: 11-12-2026
//   * 11-12-2026: initial version.
// Clocks: clk. Reset: resetn, synchronous, active low (the valid flops only; the data registers are loaded before they are used).
// -----------------------------------------------------------------------------
module rtlnet_axi_arbiter_slice #(
  parameter int W = 32                 // payload width in bits
)(
  input  logic         clk,
  input  logic         resetn,
  input  logic         s_valid,
  output logic         s_ready,
  input  logic [W-1:0] s_data,
  output logic         m_valid,
  input  logic         m_ready,
  output logic [W-1:0] m_data
);

  logic         skid_valid;
  logic [W-1:0] skid_data;

  assign s_ready = !skid_valid;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      m_valid    <= 1'b0;
      skid_valid <= 1'b0;
    end else begin
      if (!m_valid || m_ready) begin
        // The main register is empty or being emptied: refill it from the skid register first, else from the input.
        if (skid_valid) begin
          m_valid    <= 1'b1;
          skid_valid <= 1'b0;
        end else begin
          m_valid    <= s_valid;
        end
      end else if (s_valid && s_ready) begin
        // The main register is full and not accepted: the input goes to the skid register.
        skid_valid <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!m_valid || m_ready) begin
      if (skid_valid) m_data <= skid_data;
      else            m_data <= s_data;
    end else if (s_valid && s_ready) begin
      skid_data <= s_data;
    end
  end

endmodule
