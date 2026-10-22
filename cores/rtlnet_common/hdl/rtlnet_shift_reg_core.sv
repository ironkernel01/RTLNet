// -----------------------------------------------------------------------------
// File: rtlnet_shift_reg_core.sv
// Purpose: the one fixed-delay shift register of RTLNet (delay lines such as
//   the classifier's frame delay). A retarget to another technology changes
//   this file only.
// Overview:
//   * q is d delayed by exactly DEPTH clocks in which ce is high (ce low holds
//     every stage). DEPTH >= 2.
//   * The technology is `RTLNET_TARGET from rtlnet_technology.svh:
//       AMD     : LUT shift-register RAM, a direct instance of SRLC32E per bit,
//                 cascaded through Q31 for depths above 32, followed by one
//                 output register (the SRL part is DEPTH - 1 deep), so the
//                 output is a flip-flop for timing.
//       ALTERA  : inferred array, ramstyle MLAB (Quartus shift-tap mapping).
//       LATTICE : inferred array, syn_srlstyle distributed.
//       GENERIC : plain register array (simulation, ASIC front end).
//   * The storage has NO reset (LUT shift registers cannot be reset). Callers
//     keep any qualifier that must clear on reset (e.g. a valid bit) in their
//     own flip-flops, or flush the line after reset. Power-up contents are 0.
// Language: SystemVerilog-2012.
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: clk only.
// -----------------------------------------------------------------------------
`include "rtlnet_technology.svh"

module rtlnet_shift_reg_core #(
  parameter int DATA_W = 8,                // bits per stage
  parameter int DEPTH  = 16                // delay in enabled clocks, >= 2
)(
  // Clock and shift enable (ce low holds every stage).
  input  logic              clk,
  input  logic              ce,

  // Data in; the same data DEPTH enabled clocks later.
  input  logic [DATA_W-1:0] d,
  output logic [DATA_W-1:0] q
);

  localparam string TARGET   = `RTLNET_TARGET;
  localparam int    SRL_LEN  = DEPTH - 1;              // AMD: SRL part, then one register
  localparam int    SRL_N    = (SRL_LEN + 31) / 32;    // SRLC32E per bit in the cascade
  localparam int    LAST_LEN = SRL_LEN - 32 * (SRL_N - 1);

  generate
    if (DEPTH < 2) begin : g_bad_depth
      $fatal(1, "rtlnet_shift_reg_core: DEPTH=%0d, must be at least 2", DEPTH);
    end
  endgenerate

  generate
    if (TARGET == "AMD") begin : g_amd
      // AMD/Xilinx: LUT shift-register RAM (UG953 SRLC32E). Stage k of the
      // cascade is a full 32-deep SRL feeding the next through Q31; the last
      // SRL taps at LAST_LEN - 1, giving SRL_LEN clocks, then q_reg adds one.
      logic [DATA_W-1:0] srl_q;
      genvar gb, gs;
      for (gb = 0; gb < DATA_W; gb++) begin : g_bit
        logic [SRL_N:0] cas;
        assign cas[0] = d[gb];
        for (gs = 0; gs < SRL_N; gs++) begin : g_srl
          logic q_tap;
          SRLC32E #(
            .INIT (32'h0000_0000)
          ) u_srl (
            .CLK (clk),
            .CE  (ce),
            .A   ((gs == SRL_N - 1) ? 5'(LAST_LEN - 1) : 5'd31),
            .D   (cas[gs]),
            .Q   (q_tap),
            .Q31 (cas[gs+1])
          );
          if (gs == SRL_N - 1) begin : g_last
            assign srl_q[gb] = q_tap;
          end
        end
      end

      // Output register: the last delay stage is a flip-flop.
      logic [DATA_W-1:0] q_reg = '0;
      always_ff @(posedge clk) begin
        if (ce) q_reg <= srl_q;
      end
      assign q = q_reg;
    end else begin : g_inferred
      // Other technologies: an inferred array; each tool maps it by its own
      // literal attribute (each ignores the others').
      if (TARGET == "ALTERA") begin : g_altera
        (* ramstyle = "MLAB" *) logic [DATA_W-1:0] sr [0:DEPTH-1] = '{default: '0};
        always_ff @(posedge clk) begin
          if (ce) begin
            sr[0] <= d;
            for (int i = 1; i < DEPTH; i++) sr[i] <= sr[i-1];
          end
        end
        assign q = sr[DEPTH-1];
      end else if (TARGET == "LATTICE") begin : g_lattice
        (* syn_srlstyle = "distributed" *) logic [DATA_W-1:0] sr [0:DEPTH-1] = '{default: '0};
        always_ff @(posedge clk) begin
          if (ce) begin
            sr[0] <= d;
            for (int i = 1; i < DEPTH; i++) sr[i] <= sr[i-1];
          end
        end
        assign q = sr[DEPTH-1];
      end else begin : g_generic
        logic [DATA_W-1:0] sr [0:DEPTH-1] = '{default: '0};
        always_ff @(posedge clk) begin
          if (ce) begin
            sr[0] <= d;
            for (int i = 1; i < DEPTH; i++) sr[i] <= sr[i-1];
          end
        end
        assign q = sr[DEPTH-1];
      end
    end
  endgenerate

endmodule
