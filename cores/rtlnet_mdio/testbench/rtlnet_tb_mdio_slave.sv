// -----------------------------------------------------------------------------
// File: rtlnet_tb_mdio_slave.sv
// Purpose: bench model of a Clause 22 MDIO slave (PHY management port), used
//   to check frames that firmware or a bench bit-bangs through rtlnet_mdio.
// Overview:
//   * Samples the resolved MDIO line on every rising MDC edge (IEEE 802.3
//     clause 22.2.4.5): at least 32 preamble ones, ST 01, OP, PHYAD, REGAD,
//     TA, 16 data bits MSB first. Fewer than 32 preamble ones is a frame
//     error (this model does not accept preamble suppression).
//   * Read addressed to PHY_ADDR: releases the line for TA bit 1, then drives
//     TA bit 2 = 0 and the 16 data bits, each T_VALID_NS after the rising
//     MDC edge that ends the previous slot (RTL8211E datasheet Table 61 t6,
//     0..300 ns), and releases the line T_VALID_NS after the rising edge of
//     the last data slot. Any other PHYAD: the line is never driven.
//   * Write addressed to PHY_ADDR: TA must be 10; the register is written on
//     the 16th data bit.
//   * 32 plain registers, reset values of the RTL8211E page 0 for BMCR, BMSR,
//     PHYID1, PHYID2, ANAR, GBCR; others 0.
//   * Counters: frames_read, frames_write, frames_ignored (other PHYAD),
//     frame_errors (short preamble, bad ST, bad write TA).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// Clocks: mdc (the MDIO master's MDC, idle low).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module rtlnet_tb_mdio_slave #(
  parameter logic [4:0] PHY_ADDR   = 5'd1,   // Clause 22 address this slave answers
  parameter int         T_VALID_NS = 100     // output delay after a rising MDC edge
)(
  // Management interface: MDC from the master; mdio is the resolved line.
  input  logic mdc,
  input  logic mdio,

  // Slave output driver: drive_en 1 pulls the line to drive_val.
  output logic drive_en,
  output logic drive_val
);

  localparam int ST_PRE  = 0;   // counting preamble ones
  localparam int ST_ST1  = 1;   // ST second bit (1)
  localparam int ST_HDR  = 2;   // OP, PHYAD, REGAD: 12 bits
  localparam int ST_TA1  = 3;   // TA first bit
  localparam int ST_TA2  = 4;   // TA second bit
  localparam int ST_DATA = 5;   // 16 data bits
  localparam int ST_SKIP = 6;   // frame for another address or in error: wait for idle

  logic [15:0] regs [0:31];
  int          state;
  int          ones;
  int          nbits;
  logic [11:0] hdr;
  logic [15:0] shreg;
  logic [15:0] wdata;
  logic        is_read;
  logic        mine;
  logic [1:0]  ta_bits;

  int frames_read    = 0;
  int frames_write   = 0;
  int frames_ignored = 0;
  int frame_errors   = 0;

  initial begin
    for (int i = 0; i < 32; i++) regs[i] = 16'h0000;
    regs[0]   = 16'h1140;   // BMCR
    regs[1]   = 16'h7949;   // BMSR
    regs[2]   = 16'h001C;   // PHYID1
    regs[3]   = 16'hC915;   // PHYID2
    regs[4]   = 16'h05E1;   // ANAR
    regs[9]   = 16'h0200;   // GBCR
    drive_en  = 1'b0;
    drive_val = 1'b1;
    state     = ST_PRE;
    ones      = 0;
    nbits     = 0;
  end

  // Drive the line T_VALID_NS after the current rising edge.
  task automatic drive_later(input logic en, input logic val);
    fork
      begin
        #(T_VALID_NS);
        drive_en  = en;
        drive_val = val;
      end
    join_none
  endtask

  // Frame receiver and read responder, one step per rising MDC edge.
  always @(posedge mdc) begin
    case (state)
      ST_PRE: begin
        if (mdio === 1'b1) begin
          ones++;
        end else begin
          // A 0 after the ones is the first ST bit.
          if (ones >= 32) begin
            state = ST_ST1;
          end else begin
            frame_errors++;
            $display("MDIO SLAVE @%0t: short preamble (%0d ones)", $time, ones);
            state = ST_SKIP;
          end
          ones = 0;
        end
      end
      ST_ST1: begin
        if (mdio === 1'b1) begin
          state = ST_HDR;
          nbits = 0;
          hdr   = '0;
        end else begin
          frame_errors++;
          $display("MDIO SLAVE @%0t: bad start of frame", $time);
          state = ST_SKIP;
        end
      end
      ST_HDR: begin
        hdr = {hdr[10:0], (mdio === 1'b1)};
        nbits++;
        if (nbits == 12) begin
          is_read = (hdr[11:10] == 2'b10);
          mine    = (hdr[9:5] == PHY_ADDR) && (hdr[11:10] == 2'b10 || hdr[11:10] == 2'b01);
          if (!mine) begin
            frames_ignored++;
            state = ST_SKIP;
          end else begin
            state = ST_TA1;
          end
        end
      end
      ST_TA1: begin
        ta_bits[1] = (mdio === 1'b1);
        if (is_read) begin
          // TA bit 1 slot ends here: drive TA bit 2 = 0 for the next slot.
          shreg = regs[hdr[4:0]];
          drive_later(1'b1, 1'b0);
        end
        state = ST_TA2;
      end
      ST_TA2: begin
        ta_bits[0] = (mdio === 1'b1);
        nbits = 0;
        if (is_read) begin
          drive_later(1'b1, shreg[15]);
          shreg = {shreg[14:0], 1'b0};
          state = ST_DATA;
        end else if (ta_bits != 2'b10) begin
          frame_errors++;
          $display("MDIO SLAVE @%0t: write TA %b, expected 10", $time, ta_bits);
          state = ST_SKIP;
        end else begin
          wdata = '0;
          state = ST_DATA;
        end
      end
      ST_DATA: begin
        nbits++;
        if (is_read) begin
          if (nbits == 16) begin
            drive_later(1'b0, 1'b1);
            frames_read++;
            state = ST_PRE;
            ones  = 0;
          end else begin
            drive_later(1'b1, shreg[15]);
            shreg = {shreg[14:0], 1'b0};
          end
        end else begin
          wdata = {wdata[14:0], (mdio === 1'b1)};
          if (nbits == 16) begin
            regs[hdr[4:0]] = wdata;
            frames_write++;
            state = ST_PRE;
            ones  = 0;
          end
        end
      end
      default: begin
        // ST_SKIP: wait for a run of 16 ones, then keep counting them as
        // preamble.
        if (mdio === 1'b1) begin
          ones++;
          if (ones >= 16) begin
            state = ST_PRE;
          end
        end else begin
          ones = 0;
        end
      end
    endcase
  end

endmodule
