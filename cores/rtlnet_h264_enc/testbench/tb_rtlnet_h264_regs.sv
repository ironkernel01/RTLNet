// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_regs.sv
// Purpose: self-checking bench of the register file rtlnet_h264_enc_regs: the interrupt registers (IRQ_STATUS, IRQ_ENABLE, IRQ_FORCE,
//   CTRL.IRQ_EN, the irq output) and the unchanged polled STATUS behaviour.
// Overview:
//   * The events (done, the error pulses, ring_stall, hp_chg, hp_licensed, busy) are driven directly, one clock each; the register
//     strobes are driven as rtlnet_axil_slave does (one write strobe per word, read data due the clock after the read strobe).
//   * Checks: reset state (silent, version, capability bits); each source sets exactly its own bit; a masked source sets the status bit and
//     not irq; the global enable; write 1 to clear; an event in the clock of its clear keeps the bit set (picture done, error, ring stall
//     edge); IRQ_FORCE sets implemented bits only; irq is a level that falls only when no enabled bit is pending; the ring stall is
//     an edge source (one event per stall); hp_licensed falling; a start while busy is not a PIC_START event; the polled STATUS flags
//     (DONE, ERR, ERR_CODE, BUSY, RING_STALL, CTRL readback) are independent of IRQ_STATUS and behave as before.
//   * TB_HP (define) builds HIGH_PROFILE = 1: sources 3 and 4 exist; without it they are not implemented (forced and enabled bits stay 0).
//   * +INJECT_FAILURE is the negative control of the bench (forces one failed check); the logic negative controls are mutated copies of the
//     register file that this bench must fail.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-12-2026
//   * 11-12-2026: initial version (interrupt controller).
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_regs;

  import rtlnet_tb_pkg::*;

`ifdef TB_HP
  localparam bit HP = 1'b1;
`else
  localparam bit HP = 1'b0;
`endif
  localparam logic [7:0] IMPL = HP ? 8'h3F : 8'h27;

  localparam logic [11:0] R_VERSION = 12'h004, R_CAPS = 12'h008, R_CTRL = 12'h00C, R_STATUS = 12'h010, R_ERR_CODE = 12'h014,
                          R_IRQ_STATUS = 12'h0D0, R_IRQ_ENABLE = 12'h0D4, R_IRQ_FORCE = 12'h0D8, R_PIC_COUNT = 12'h090;

  logic        clk = 1'b0;
  logic        resetn = 1'b0;
  logic        reg_wr_en = 1'b0;
  logic [11:0] reg_wr_addr = '0;
  logic [31:0] reg_wr_data = '0;
  logic        reg_rd_en = 1'b0;
  logic [11:0] reg_rd_addr = '0;
  logic [31:0] reg_rd_data;
  logic        start, ring_reset;
  logic        busy = 1'b0, done = 1'b0, slice_pulse = 1'b0;
  logic        err_cfg = 1'b0, err_axi = 1'b0, err_rptr = 1'b0, err_busy = 1'b0;
  logic [0:0]  ring_stall = 1'b0;
  logic        hp_licensed = 1'b1, hp_chg = 1'b0;
  logic        irq;
  logic        dbk_en;
  logic signed [3:0] dbk_a, dbk_b;

  always #5 clk = ~clk;

  rtlnet_h264_enc_regs #(.MAX_MB_W(120), .MAX_MB_H(68), .NUM_ENGINES(1), .HIGH_PROFILE(HP)) dut (
    .clk(clk), .resetn(resetn),
    .reg_wr_en(reg_wr_en), .reg_wr_addr(reg_wr_addr), .reg_wr_data(reg_wr_data),
    .reg_rd_en(reg_rd_en), .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data),
    .start(start), .ring_reset(ring_reset),
    .cfg_mb_w(), .cfg_mb_h(), .cfg_slices(), .cfg_in_base(), .cfg_in_stride(), .cfg_ry_base(), .cfg_ru_base(), .cfg_p(),
    .cfg_refy_base(), .cfg_refu_base(), .cfg_qp(), .cfg_mb_pcm(), .cfg_frame_num(), .cfg_idr_pic_id(), .cfg_idr(), .cfg_log2_fn(),
    .cfg_pic_no(), .cfg_ring_base(), .cfg_ring_size(), .cfg_idx_base(), .cfg_idx_entries(),
    .rptr_wr(), .rptr_val(), .idx_rptr_wr(), .idx_rptr_val(),
    .hp_enable(), .hp_t8_enable(), .hp_t8_auto(), .hp_t8_n8(16'd0), .hp_t8_n4(16'd0),
    .hp_present(HP), .hp_licensed(hp_licensed), .hp_active(1'b0), .hp_caps(HP ? 4'h7 : 4'h0), .hp_seconds_left(16'hFFFF), .hp_chg(hp_chg),
    .cfg_dbk_en(dbk_en), .cfg_dbk_a(dbk_a), .cfg_dbk_b(dbk_b),
    .busy(busy), .done(done), .slice_pulse(slice_pulse),
    .err_cfg(err_cfg), .err_axi(err_axi), .err_rptr(err_rptr), .err_busy(err_busy),
    .ring_stall(ring_stall), .ring_wptr(32'd0), .ring_fill(32'd0), .idx_wptr(32'd0), .idx_fill(32'd0),
    .st_mb_count(32'd0), .st_cyc_last(32'd0), .st_cyc_max(32'd0), .st_pic_cyc(32'd0), .st_rd_cyc(32'd0), .st_pk_cyc(32'd0), .st_wr_cyc(32'd0),
    .irq(irq)
  );

  logic [31:0] v;

  // One register write strobe (one clock), with a picture-done event and/or an error event in that same clock.
  task automatic wr_ev(input logic [11:0] a, input logic [31:0] d, input logic ev_done, input logic ev_err);
    @(negedge clk);
    reg_wr_en = 1'b1; reg_wr_addr = a; reg_wr_data = d;
    done = ev_done; err_cfg = ev_err;
    @(negedge clk);
    reg_wr_en = 1'b0; done = 1'b0; err_cfg = 1'b0;
  endtask

  task automatic wr(input logic [11:0] a, input logic [31:0] d);
    wr_ev(a, d, 1'b0, 1'b0);
  endtask

  task automatic rd(input logic [11:0] a, output logic [31:0] d);
    @(negedge clk);
    reg_rd_en = 1'b1; reg_rd_addr = a;
    @(negedge clk);
    reg_rd_en = 1'b0;
    d = reg_rd_data;
  endtask

  // One-clock event pulses: 0 picture done, 1 error (AXI), 5 profile change.
  task automatic ev_pulse(input int src);
    @(negedge clk);
    case (src)
      0: done = 1'b1;
      1: err_axi = 1'b1;
      5: hp_chg = 1'b1;
      default: begin end
    endcase
    @(negedge clk);
    done = 1'b0; err_axi = 1'b0; hp_chg = 1'b0;
  endtask

  task automatic expect_status(input logic [7:0] exp, input string what);
    logic [31:0] s;
    rd(R_IRQ_STATUS, s);
    tb_check(s == {24'd0, exp}, $sformatf("%s: IRQ_STATUS %08x expected %02x", what, s, exp));
  endtask

  task automatic expect_irq(input logic exp, input string what);
    tb_check(irq === exp, $sformatf("%s: irq %b expected %b", what, irq, exp));
  endtask

  // Raise source k with its natural event; k = 0 done, 1 err, 2 ring stall rising edge, 3 profile change, 4 license lost, 5 picture start.
  task automatic raise(input int k);
    case (k)
      0: ev_pulse(0);
      1: ev_pulse(1);
      2: begin @(negedge clk); ring_stall = 1'b1; @(negedge clk); ring_stall = 1'b0; end
      3: ev_pulse(5);
      4: begin @(negedge clk); hp_licensed = 1'b0; @(negedge clk); hp_licensed = 1'b1; end
      5: wr(R_CTRL, 32'h1);   // CTRL.START while idle (IRQ_EN written 0)
      default: begin end
    endcase
  endtask

  // Clear every source and the legacy flags between tests.
  task automatic clean();
    wr(R_IRQ_STATUS, 32'hFF);
    wr(R_STATUS, 32'h6);
    wr(R_IRQ_ENABLE, 32'd0);
    wr(R_CTRL, 32'd0);
  endtask

  initial begin
    repeat (4) @(negedge clk);
    // Reset state: silent, version, capability.
    expect_irq(1'b0, "in reset");
    resetn = 1'b1;
    repeat (3) @(negedge clk);
    expect_irq(1'b0, "after reset");
    expect_status(8'h00, "reset");
    rd(R_IRQ_ENABLE, v);
    tb_check(v == 32'd0, "IRQ_ENABLE reset value");
    rd(R_CTRL, v);
    tb_check(v == 32'd0, "CTRL reset value (global enable off)");
    rd(R_VERSION, v);
    tb_check(v == 32'h1112_2C04, $sformatf("VERSION %08x", v));
    rd(R_CAPS, v);
    tb_check(v[21] === 1'b1, "CAPS bit 21 (interrupt registers)");
    tb_check(v[20] === HP, "CAPS bit 20 (HP_SEAM)");
    tb_check(v[31:24] == IMPL, $sformatf("CAPS[31:24] source mask %02x expected %02x", v[31:24], IMPL));
    tb_check(v[7:0] == 8'd120 && v[15:8] == 8'd68, "CAPS sizes");

    // Each source sets its own bit; nothing is enabled, irq stays low; write 1 to clear removes it.
    for (int k = 0; k < 6; k++) begin
      logic [7:0] m;
      m = 8'(1 << k);
      raise(k);
      if ((m & IMPL) != 8'd0) expect_status(m, $sformatf("source %0d", k));
      else expect_status(8'h00, $sformatf("source %0d (not implemented)", k));
      expect_irq(1'b0, $sformatf("source %0d unmasked", k));
      wr(R_IRQ_STATUS, 32'(m));
      expect_status(8'h00, $sformatf("source %0d cleared", k));
      clean();
    end

    // Masked: IRQ_EN set (global), IRQ_ENABLE for another source: status sets, irq not.
    wr(R_CTRL, 32'h100);
    wr(R_IRQ_ENABLE, 32'h02);
    ev_pulse(0);
    expect_status(8'h01, "masked source");
    expect_irq(1'b0, "masked source");
    ev_pulse(1);
    expect_status(8'h03, "both set");
    expect_irq(1'b1, "enabled source");
    // Level: clear the enabled bit, irq falls; the masked bit stays pending.
    wr(R_IRQ_STATUS, 32'h02);
    expect_irq(1'b0, "enabled bit cleared");
    expect_status(8'h01, "masked bit kept");
    // Enable the pending one: irq rises with no new event; two enabled pending bits, clear one: irq stays.
    wr(R_IRQ_ENABLE, 32'h03);
    expect_irq(1'b1, "enable of a pending bit");
    ev_pulse(1);
    wr(R_IRQ_STATUS, 32'h01);
    expect_irq(1'b1, "one of two cleared");
    wr(R_IRQ_STATUS, 32'h02);
    expect_irq(1'b0, "both cleared");
    // Global enable off: irq low with enabled pending bit; on again: high.
    ev_pulse(0);
    expect_irq(1'b1, "global on");
    wr(R_CTRL, 32'h000);
    expect_irq(1'b0, "global off");
    expect_status(8'h01, "global off keeps status");
    wr(R_CTRL, 32'h100);
    expect_irq(1'b1, "global on again");
    rd(R_CTRL, v);
    tb_check(v == 32'h100, "CTRL readback of IRQ_EN");
    clean();

    // Writing 0 to a status bit clears nothing; a clear of a bit that is not set does nothing.
    ev_pulse(0);
    wr(R_IRQ_STATUS, 32'h00);
    expect_status(8'h01, "write 0 clears nothing");
    wr(R_IRQ_STATUS, 32'h02);
    expect_status(8'h01, "clear of another bit");
    clean();

    // Set wins over clear in the same clock: picture done and error.
    ev_pulse(0);
    wr_ev(R_IRQ_STATUS, 32'h01, 1'b1, 1'b0);
    expect_status(8'h01, "done in the clock of its clear");
    wr(R_IRQ_STATUS, 32'h01);
    expect_status(8'h00, "done cleared afterwards");
    ev_pulse(1);
    wr_ev(R_IRQ_STATUS, 32'h02, 1'b0, 1'b1);
    expect_status(8'h02, "error in the clock of its clear");
    wr(R_IRQ_STATUS, 32'h02);
    expect_status(8'h00, "error cleared afterwards");
    // A clear of done with an error event in the same clock clears done and sets error.
    ev_pulse(0);
    wr_ev(R_IRQ_STATUS, 32'h01, 1'b0, 1'b1);
    expect_status(8'h02, "clear of done, error event");
    clean();
    // Ring stall rising edge in the clock of its clear.
    @(negedge clk); ring_stall = 1'b1; @(negedge clk); ring_stall = 1'b0; @(negedge clk);
    expect_status(8'h04, "stall edge");
    wr(R_IRQ_STATUS, 32'h04);
    @(negedge clk);
    reg_wr_en = 1'b1; reg_wr_addr = R_IRQ_STATUS; reg_wr_data = 32'h04; ring_stall = 1'b1;
    @(negedge clk);
    reg_wr_en = 1'b0; ring_stall = 1'b0;
    expect_status(8'h04, "stall edge in the clock of its clear");
    clean();
    // The stall is an edge source: a long stall is one event; cleared while the stall stays, it does not come back.
    @(negedge clk); ring_stall = 1'b1;
    repeat (3) @(negedge clk);
    expect_status(8'h04, "long stall");
    wr(R_IRQ_STATUS, 32'h04);
    repeat (3) @(negedge clk);
    expect_status(8'h00, "stall still high, no new event");
    @(negedge clk); ring_stall = 1'b0;
    repeat (2) @(negedge clk);
    expect_status(8'h00, "stall ended");
    @(negedge clk); ring_stall = 1'b1;
    repeat (2) @(negedge clk);
    expect_status(8'h04, "second stall");
    @(negedge clk); ring_stall = 1'b0;
    clean();

    // IRQ_FORCE: implemented bits only; zeros change nothing; irq follows.
    wr(R_CTRL, 32'h100);
    wr(R_IRQ_ENABLE, 32'hFF);
    rd(R_IRQ_ENABLE, v);
    tb_check(v == {24'd0, IMPL}, $sformatf("IRQ_ENABLE implemented bits only: %08x", v));
    wr(R_IRQ_FORCE, 32'h00);
    expect_status(8'h00, "force 0");
    expect_irq(1'b0, "force 0");
    wr(R_IRQ_FORCE, 32'hC0);
    expect_status(8'h00, "force of reserved bits");
    expect_irq(1'b0, "force of reserved bits");
    wr(R_IRQ_FORCE, 32'h04);
    expect_status(8'h04, "force 4");
    expect_irq(1'b1, "force 4");
    wr(R_IRQ_FORCE, 32'h01);
    expect_status(8'h05, "force accumulates");
    wr(R_IRQ_FORCE, 32'hFF);
    expect_status(IMPL, "force all");
    rd(R_IRQ_FORCE, v);
    tb_check(v == 32'd0, "IRQ_FORCE reads 0");
    wr(R_IRQ_STATUS, 32'hFF);
    expect_status(8'h00, "all cleared");
    expect_irq(1'b0, "all cleared");
    clean();

    // Profile change and license lost exist only in a HIGH_PROFILE build; a rising hp_licensed is no event.
    if (HP) begin
      ev_pulse(5);
      expect_status(8'h08, "profile change");
      clean();
      @(negedge clk); hp_licensed = 1'b0;
      repeat (3) @(negedge clk);
      expect_status(8'h10, "license lost");
      wr(R_IRQ_STATUS, 32'h10);
      @(negedge clk); hp_licensed = 1'b1;
      repeat (3) @(negedge clk);
      expect_status(8'h00, "license regained is no event");
      clean();
    end else begin
      ev_pulse(5);
      @(negedge clk); hp_licensed = 1'b0;
      repeat (3) @(negedge clk);
      hp_licensed = 1'b1;
      expect_status(8'h00, "no profile source in a baseline build");
      clean();
    end

    // PIC_START: a start while idle is an event, a start while busy is not.
    @(negedge clk); busy = 1'b1;
    wr(R_CTRL, 32'h1);
    expect_status(8'h00, "start while busy");
    @(negedge clk); busy = 1'b0;
    wr(R_CTRL, 32'h1);
    expect_status(8'h20, "start while idle");
    clean();

    // Deblocking filter registers (CAPS bit 22, DBK_CTRL 0x0E0, DBK_STATUS 0x0E4): reset values, offset range, latching at the accepted start.
    rd(R_CAPS, v);
    tb_check(v[22] === 1'b1, "CAPS bit 22 (deblocking filter)");
    rd(12'h0E0, v);
    tb_check(v == 32'h1, $sformatf("DBK_CTRL reset value %08x", v));
    rd(12'h0E4, v);
    tb_check(v == 32'h3, $sformatf("DBK_STATUS after the earlier starts %08x (present, reset state applied)", v));
    tb_check((dbk_en === 1'b1) && (dbk_a === 4'sd0) && (dbk_b === 4'sd0), "applied state is the reset state");
    wr(12'h0E0, {20'd0, 4'hA, 4'h3, 3'd0, 1'b1});          // alpha 3, beta -6
    rd(12'h0E0, v);
    tb_check(v == {20'd0, 4'hA, 4'h3, 3'd0, 1'b1}, $sformatf("DBK_CTRL written %08x", v));
    wr(12'h0E0, {20'd0, 4'h7, 4'h9, 3'd0, 1'b1});          // alpha -7 (out of range, kept 3), beta 7 (out of range, kept -6)
    rd(12'h0E0, v);
    tb_check(v == {20'd0, 4'hA, 4'h3, 3'd0, 1'b1}, $sformatf("DBK_CTRL out-of-range fields kept %08x", v));
    wr(12'h0E0, {20'd0, 4'h6, 4'hA, 3'd0, 1'b0});          // alpha -6, beta 6, off
    rd(12'h0E0, v);
    tb_check(v == {20'd0, 4'h6, 4'hA, 3'd0, 1'b0}, $sformatf("DBK_CTRL range limits %08x", v));
    tb_check((dbk_en === 1'b1) && (dbk_a === 4'sd0), "the applied state does not change before a start");
    wr(R_CTRL, 32'h1);
    repeat (2) @(negedge clk);
    rd(12'h0E4, v);
    tb_check(v == {16'd0, 4'h6, 4'hA, 6'd0, 1'b0, 1'b1}, $sformatf("DBK_STATUS after a start %08x", v));
    wr(12'h0E0, {20'd0, 4'h0, 4'h0, 3'd0, 1'b1});
    @(negedge clk); busy = 1'b1;
    wr(R_CTRL, 32'h1);
    rd(12'h0E4, v);
    tb_check(v == {16'd0, 4'h6, 4'hA, 6'd0, 1'b0, 1'b1}, $sformatf("DBK_STATUS unchanged by a start while busy %08x", v));
    @(negedge clk); busy = 1'b0;
    wr(R_CTRL, 32'h1);
    repeat (2) @(negedge clk);
    rd(12'h0E4, v);
    tb_check(v == {16'd0, 4'h0, 4'h0, 6'd0, 1'b1, 1'b1}, $sformatf("DBK_STATUS second start %08x", v));
    wr(R_IRQ_STATUS, 32'hFF);
    clean();

    // Polled STATUS unchanged: DONE and ERR flags, ERR_CODE, BUSY and RING_STALL, independent of IRQ_STATUS; IRQ_EN and the sources do not touch them.
    rd(R_STATUS, v);
    tb_check(v == 32'd0, "STATUS idle");
    ev_pulse(0);
    rd(R_STATUS, v);
    tb_check(v == 32'h2, $sformatf("STATUS after done %08x", v));
    rd(R_PIC_COUNT, v);
    tb_check(v != 32'd0, "PIC_COUNT counts");
    wr(R_IRQ_STATUS, 32'hFF);
    rd(R_STATUS, v);
    tb_check(v == 32'h2, "clearing IRQ_STATUS leaves STATUS.DONE");
    wr(R_STATUS, 32'h2);
    rd(R_STATUS, v);
    tb_check(v == 32'h0, "STATUS.DONE write 1 to clear");
    ev_pulse(0);
    wr(R_STATUS, 32'h2);
    expect_status(8'h01, "clearing STATUS.DONE leaves IRQ_STATUS");
    wr_ev(R_STATUS, 32'h2, 1'b1, 1'b0);
    rd(R_STATUS, v);
    tb_check(v == 32'h2, "STATUS.DONE: event in the clock of the clear wins (legacy rule)");
    wr(R_STATUS, 32'h2);
    ev_pulse(1);
    rd(R_STATUS, v);
    tb_check(v == 32'h4, $sformatf("STATUS after error %08x", v));
    rd(R_ERR_CODE, v);
    tb_check(v[7:0] != 8'd0, "ERR_CODE set");
    wr(R_STATUS, 32'h4);
    rd(R_STATUS, v);
    tb_check(v == 32'h0, "STATUS.ERR cleared");
    rd(R_ERR_CODE, v);
    tb_check(v == 32'h0, "ERR_CODE cleared");
    @(negedge clk); busy = 1'b1; ring_stall = 1'b1;
    rd(R_STATUS, v);
    tb_check(v == 32'h9, $sformatf("STATUS busy and stall %08x", v));
    @(negedge clk); busy = 1'b0; ring_stall = 1'b0;
    rd(R_STATUS, v);
    tb_check(v == 32'h0, "STATUS live bits fall");
    clean();

    // An enabled source with the global enable off never raises irq, whatever happens.
    wr(R_IRQ_ENABLE, 32'h3F);
    ev_pulse(0);
    ev_pulse(1);
    expect_irq(1'b0, "enabled, global off");
    tb_verdict("tb_rtlnet_h264_regs");
  end

endmodule
