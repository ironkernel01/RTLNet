// -----------------------------------------------------------------------------
// File: tb_rtlnet_csi2_rx_cdc.sv
// Purpose: self-checking bench for rtlnet_csi2_rx_cdc, the byte clock to core clock FIFO of the camera receiver.
// Cases:
//   1. Reset: empty, nothing valid.
//   2. Writer slower than the reader (write clock 19 ns, read clock 11 ns, random valid and random ready): 4000 entries come out in order
//      with no loss and no overflow event.
//   3. Writer faster than the reader (11 ns and 19 ns), the writer paced so that the FIFO never fills: the same.
//   4. Overflow: the reader stalled while 200 entries are written into the 128-entry FIFO: exactly 71 overflow pulses, one per dropped entry
//      (the FIFO holds its 128 RAM entries and the one in the output register);
//      when the reader is released the first 129 entries come out in order and nothing else; the FIFO then works again.
//   5. The writer keeps writing while the reader takes one entry in about sixteen clocks (sustained overflow): every entry that did not raise an
//      overflow pulse comes out, in order, once; none of the dropped ones does.
// Plusargs: INJECT_FAILURE (the verdict fails), MUTATE (one expected entry is perturbed: the compare must fail).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_csi2_rx_cdc;

  import rtlnet_tb_pkg::*;
  import rtlnet_csi2_rx_pkg::*;

  real wper = 19.0;
  real rper = 11.0;
  logic w_clk = 1'b0, r_clk = 1'b0;
  always begin #(wper / 2.0); w_clk = ~w_clk; end
  always begin #(rper / 2.0); r_clk = ~r_clk; end
  logic arstn = 1'b0;
  logic w_resetn, r_resetn;
  rtlnet_reset_sync u_rw (.clk(w_clk), .arstn(arstn), .resetn(w_resetn));
  rtlnet_reset_sync u_rr (.clk(r_clk), .arstn(arstn), .resetn(r_resetn));

  logic             w_valid = 1'b0;
  logic [ENT_W-1:0] w_data = '0;
  logic             ev_overflow;
  logic             m_valid;
  logic [ENT_W-1:0] m_data;
  logic             m_ready = 1'b0;

  rtlnet_csi2_rx_cdc #(.RAM_STYLE("block"), .FIFO_KB(1)) dut (
    .w_clk(w_clk), .w_resetn(w_resetn), .w_valid(w_valid), .w_data(w_data), .ev_overflow(ev_overflow),
    .r_clk(r_clk), .r_resetn(r_resetn), .m_valid(m_valid), .m_data(m_data), .m_ready(m_ready));

  bit mutate = 1'b0;
  int ready_mode = 0;       // 0 stalled, 1 random 75 percent, 2 one in sixteen, 3 always
  logic [31:0] lfsr = 32'hCAFE_0001;
  always @(posedge r_clk) lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

  always @(posedge r_clk) begin
    case (ready_mode)
      0: m_ready <= 1'b0;
      1: m_ready <= (lfsr[3:2] != 2'b00);
      2: m_ready <= (lfsr[7:4] == 4'd0);
      default: m_ready <= 1'b1;
    endcase
  end

  // Reader: collect.
  bit [ENT_W-1:0] got [$];
  always @(posedge r_clk) if (r_resetn && m_valid && m_ready) got.push_back(m_data);

  // Writer side bookkeeping: the entry written in a clock whose overflow pulse comes in the next clock was dropped.
  int ovf_count = 0;
  bit [ENT_W-1:0] sent [$];
  bit [ENT_W-1:0] accepted [$];
  bit last_valid = 1'b0;
  bit [ENT_W-1:0] last_data;
  always @(posedge w_clk) begin
    if (w_resetn) begin
      if (ev_overflow) ovf_count++;
      else if (last_valid) accepted.push_back(last_data);
      last_valid <= w_valid;
      last_data  <= w_data;
    end
  end

  task automatic write_entries(input int n, input int seed, input int duty);   // duty: 0 every clock, k: valid with probability 1/k
    logic [31:0] l;
    l = 32'h1234_5678 + seed;
    for (int i = 0; i < n; i++) begin
      if (duty > 1) begin
        l = {l[30:0], l[31] ^ l[21] ^ l[1] ^ l[0]};
        repeat (int'(l[7:0]) % duty) begin
          w_valid <= 1'b0;
          @(posedge w_clk);
        end
      end
      w_valid <= 1'b1;
      w_data  <= {14'(seed), 32'(i + seed * 100000)};
      sent.push_back({14'(seed), 32'(i + seed * 100000)});
      @(posedge w_clk);
    end
    w_valid <= 1'b0;
    @(posedge w_clk);
  endtask

  task automatic reset_state();
    got.delete(); sent.delete(); accepted.delete(); ovf_count = 0; last_valid = 1'b0;
  endtask

  task automatic compare(input string tag, input bit [ENT_W-1:0] exp [$]);
    int bad;
    tb_check(got.size() == exp.size(), $sformatf("%s: %0d entries read, %0d expected", tag, got.size(), exp.size()));
    bad = 0;
    for (int i = 0; i < exp.size() && i < got.size(); i++) begin
      bit [ENT_W-1:0] e;
      e = exp[i];
      if (mutate && i == 3) e = e ^ 46'h4;
      if (got[i] !== e) bad++;
    end
    tb_check(bad == 0, $sformatf("%s: %0d entry mismatches", tag, bad));
  endtask

  initial begin
    mutate = $test$plusargs("MUTATE");
    repeat (8) @(posedge w_clk);
    tb_check(!m_valid, "valid during reset");
    arstn = 1'b1;
    repeat (12) @(posedge w_clk);
    tb_check(!m_valid, "valid with an empty FIFO");

    // 2. Reader faster.
    reset_state();
    ready_mode = 1;
    write_entries(4000, 1, 2);
    repeat (400) @(posedge r_clk);
    tb_check(ovf_count == 0, $sformatf("overflow pulses %0d with a fast reader", ovf_count));
    compare("fast reader", sent);

    // 3. Writer faster (paced).
    wper = 11.0; rper = 19.0;
    repeat (20) @(posedge w_clk);
    reset_state();
    ready_mode = 1;
    write_entries(1500, 2, 5);
    repeat (800) @(posedge r_clk);
    tb_check(ovf_count == 0, $sformatf("overflow pulses %0d with a paced writer", ovf_count));
    compare("fast writer", sent);

    // 4. Overflow with a stalled reader.
    reset_state();
    ready_mode = 0;
    write_entries(200, 3, 0);
    repeat (60) @(posedge w_clk);
    tb_check(ovf_count == 71, $sformatf("overflow pulses %0d, expected 71", ovf_count));
    ready_mode = 3;
    repeat (600) @(posedge r_clk);
    begin
      bit [ENT_W-1:0] first128 [$];
      for (int i = 0; i < 129; i++) first128.push_back(sent[i]);
      compare("after overflow", first128);
    end
    reset_state();
    ready_mode = 3;
    write_entries(50, 4, 3);
    repeat (200) @(posedge r_clk);
    compare("after the overflow recovery", sent);
    tb_check(ovf_count == 0, "overflow pulses after recovery");

    // 5. Sustained overflow.
    reset_state();
    ready_mode = 2;
    write_entries(3000, 5, 0);
    ready_mode = 3;
    repeat (600) @(posedge r_clk);
    tb_check(ovf_count > 0, "no overflow with a one in sixteen reader");
    tb_check(accepted.size() + ovf_count == sent.size(), $sformatf("accepted %0d + dropped %0d != sent %0d", accepted.size(), ovf_count, sent.size()));
    compare("sustained overflow", accepted);

    tb_verdict("tb_rtlnet_csi2_rx_cdc");
  end

  initial begin
    #20ms;
    tb_error("bench timeout");
    tb_verdict("tb_rtlnet_csi2_rx_cdc");
  end

endmodule
