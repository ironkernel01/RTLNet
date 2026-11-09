// -----------------------------------------------------------------------------
// File: tb_rtlnet_h264_bitpack.sv
// Purpose: self-checking bench of rtlnet_h264_bitpack: exp-Golomb ue(v) and se(v), fixed fields, ALIGN,
//   rbsp trailing bits, Annex B start codes, emulation prevention and the first/last/kind sideband,
//   against reference functions written here from the text of ITU-T Rec. H.264.
// Overview:
//   * The reference builds each NAL unit as a queue of single bits (ue(v) per clause 9.1: leadingZeroBits
//     zeros, a one, leadingZeroBits info bits; se(v) per Table 9-3), applies rbsp_trailing_bits
//     (clause 7.3.2.11), converts to bytes and inserts emulation_prevention_three_byte after every two
//     zero bytes before a byte 0..3 (clause 7.4.1.1 / 7.4.1), prepends the start code.
//   * Directed NAL units carry zero runs followed by each of the bytes 00, 01, 02, 03, 04; the random NAL units mix
//     commands and favor zero bytes. Command gaps and output back-pressure are random.
//   * +INJECT_FAILURE is the negative control (forces one failed check).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: clk, 100 MHz.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rtlnet_h264_bitpack;

  import rtlnet_tb_pkg::*;
  import rtlnet_h264_pkg::*;

  localparam int RANDOM_NALS = 400;

  logic        clk = 1'b0;
  logic        resetn = 1'b0;
  logic        cmd_valid = 1'b0;
  logic        cmd_ready;
  logic [2:0]  cmd_op = '0;
  logic [31:0] cmd_val = '0;
  logic [5:0]  cmd_len = '0;
  logic        cmd_kind = 1'b0;
  logic        o_valid;
  logic        o_ready = 1'b0;
  logic [7:0]  o_data;
  logic        o_first;
  logic        o_last;
  logic        o_kind;
  logic        idle;

  always #5 clk = ~clk;

  rtlnet_h264_bitpack dut (
    .clk(clk), .resetn(resetn),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_op(cmd_op), .cmd_val(cmd_val), .cmd_len(cmd_len),
    .cmd_kind(cmd_kind),
    .o_valid(o_valid), .o_ready(o_ready), .o_data(o_data), .o_first(o_first), .o_last(o_last), .o_kind(o_kind),
    .idle(idle)
  );

  // ---------------------------------------------------------------------------
  // Reference model
  // ---------------------------------------------------------------------------
  bit     ref_bits[$];
  bytes_t exp_bytes;
  bit     exp_first[$];
  bit     exp_last[$];
  bit     exp_kind[$];
  int     exp_nals = 0;
  bit     cur_kind;

  function automatic void ref_put(input longint unsigned v, input int n);
    for (int i = n - 1; i >= 0; i--) ref_bits.push_back(v[i]);
  endfunction

  function automatic void ref_ue(input longint unsigned v);
    longint unsigned m;
    int              n;
    m = v + 1;
    n = 0;
    while ((m >> n) != 0) n++;
    for (int i = 0; i < n - 1; i++) ref_bits.push_back(1'b0);
    ref_put(m, n);
  endfunction

  function automatic void ref_se(input int k);
    if (k > 0) ref_ue(2 * k - 1);
    else       ref_ue(-2 * k);
  endfunction

  function automatic void ref_align();
    while ((ref_bits.size() % 8) != 0) ref_bits.push_back(1'b0);
  endfunction

  // Close the NAL unit: trailing bits, bytes, emulation prevention, start code.
  function automatic void ref_end_nal();
    int unsigned zeros;
    byte unsigned b;
    int unsigned  first_idx;
    ref_bits.push_back(1'b1);
    ref_align();
    exp_bytes.push_back(8'h00);
    exp_bytes.push_back(8'h00);
    exp_bytes.push_back(8'h00);
    exp_bytes.push_back(8'h01);
    first_idx = exp_bytes.size() - 4;
    zeros = 0;
    for (int i = 0; i < ref_bits.size(); i += 8) begin
      b = 8'h00;
      for (int k = 0; k < 8; k++) b[7 - k] = ref_bits[i + k];
      if ((zeros >= 2) && (b <= 8'h03)) begin
        exp_bytes.push_back(8'h03);
        zeros = 0;
      end
      exp_bytes.push_back(b);
      if (b == 8'h00) zeros++;
      else            zeros = 0;
    end
    for (int i = first_idx; i < exp_bytes.size(); i++) begin
      exp_first.push_back(i == first_idx);
      exp_last.push_back(i == (exp_bytes.size() - 1));
      exp_kind.push_back(cur_kind);
    end
    ref_bits.delete();
    exp_nals++;
  endfunction

  // ---------------------------------------------------------------------------
  // Driver
  // ---------------------------------------------------------------------------
  // Race-free driving: inputs change at the falling edge, ready and valid are sampled at the falling edge, and the
  // transfer happens at the rising edge that follows.
  task automatic send(input logic [2:0] op, input logic [31:0] val, input logic [5:0] len, input logic kind);
    int gap;
    gap = ($urandom % 4 == 0) ? ($urandom % 3) : 0;
    cmd_valid = 1'b0;
    repeat (gap) @(negedge clk);
    cmd_valid = 1'b1;
    cmd_op    = op;
    cmd_val   = val;
    cmd_len   = len;
    cmd_kind  = kind;
    while (!cmd_ready) @(negedge clk);
    @(negedge clk);
    cmd_valid = 1'b0;
  endtask

  task automatic do_start(input logic kind);
    cur_kind = kind;
    send(PK_START, 32'd0, 6'd0, kind);
  endtask

  task automatic do_field(input logic [31:0] val, input int len);
    send(PK_FIELD, val, 6'(len), 1'b0);
    ref_put(longint'(val) & ((64'd1 << len) - 1), len);
  endtask

  task automatic do_ue(input int val);
    send(PK_UE, 32'(val), 6'd0, 1'b0);
    ref_ue(val);
  endtask

  task automatic do_se(input int val);
    send(PK_SE, 32'(val), 6'd0, 1'b0);
    ref_se(val);
  endtask

  task automatic do_align();
    send(PK_ALIGN, 32'd0, 6'd0, 1'b0);
    ref_align();
  endtask

  task automatic do_end();
    send(PK_END, 32'd0, 6'd0, 1'b0);
    ref_end_nal();
  endtask

  task automatic random_nal();
    int n;
    int sel;
    int v;
    do_start($urandom % 2);
    n = 3 + ($urandom % 30);
    for (int i = 0; i < n; i++) begin
      sel = $urandom % 12;
      case (sel)
        0, 1: begin
          v = $urandom % 33;
          do_field($urandom, (v == 0) ? 1 : v);
        end
        2: do_field(32'd0, 8);
        3: do_field(32'd0, 16);
        4: begin
          do_align();
          do_field($urandom % 5, 8);
        end
        5: do_ue($urandom % 8);
        6: do_ue($urandom % 40);
        7: do_ue($urandom % 8200);
        8: do_ue($urandom % 65535);
        9: do_se(($urandom % 21) - 10);
        10: do_se(($urandom % 65535) - 32767);
        default: do_field($urandom % 4, 8);
      endcase
    end
    do_end();
  endtask

  task automatic directed_nals();
    // Zero runs followed by 00, 01, 02, 03, 04 and 0xFF.
    for (int t = 0; t < 7; t++) begin
      do_start(NAL_SLICE);
      do_field(32'h0000_0001, 8);
      do_field(32'd0, 8);
      do_field(32'd0, 8);
      do_field((t == 5) ? 32'd4 : ((t == 6) ? 32'd255 : t), 8);
      do_field(32'd0, 8);
      do_field(32'd0, 8);
      do_field(32'd0, 8);
      do_field(32'd1, 8);
      do_end();
    end
    // ue/se edge values, a NAL unit of a single trailing bit pattern, and a NAL that ends on a
    // byte boundary (the trailing byte is 0x80).
    do_start(NAL_AUD);
    do_field(7, 3);
    do_end();
    do_start(NAL_SLICE);
    do_ue(0); do_ue(1); do_ue(2); do_ue(65534); do_ue(8159);
    do_se(0); do_se(1); do_se(-1); do_se(2); do_se(-2); do_se(26); do_se(-26); do_se(32767); do_se(-32767);
    do_end();
    do_start(NAL_SLICE);
    do_ue(25);
    do_align();
    do_field(32'hFF, 8);
    do_end();
  endtask

  // ---------------------------------------------------------------------------
  // Monitor
  // ---------------------------------------------------------------------------
  bytes_t got_bytes;
  bit     got_first[$];
  bit     got_last[$];
  bit     got_kind[$];

  always @(posedge clk) o_ready <= (($urandom % 10) < 7);

  always @(negedge clk) begin
    if (resetn && o_valid && o_ready) begin
      got_bytes.push_back(o_data);
      got_first.push_back(o_first);
      got_last.push_back(o_last);
      got_kind.push_back(o_kind);
    end
  end

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  int  idle_wait;
  int  mism;
  initial begin
    resetn = 1'b0;
    repeat (5) @(negedge clk);
    resetn = 1'b1;
    repeat (3) @(negedge clk);
    directed_nals();
    for (int i = 0; i < RANDOM_NALS; i++) random_nal();
    idle_wait = 0;
    while (!idle && idle_wait < 2000) begin
      @(posedge clk);
      idle_wait++;
    end
    repeat (5) @(posedge clk);
    tb_check(idle, "packer idle after the last NAL unit");
    tb_check(got_bytes.size() == exp_bytes.size(),
             $sformatf("output byte count %0d, expected %0d", got_bytes.size(), exp_bytes.size()));
    mism = 0;
    for (int i = 0; (i < got_bytes.size()) && (i < exp_bytes.size()); i++) begin
      if ((got_bytes[i] !== exp_bytes[i]) || (got_first[i] !== exp_first[i]) || (got_last[i] !== exp_last[i]) ||
          (got_kind[i] !== exp_kind[i])) begin
        if (mism == 0) begin
          tb_error($sformatf("byte %0d: got %02x f%0d l%0d k%0d, expected %02x f%0d l%0d k%0d", i, got_bytes[i],
                             got_first[i], got_last[i], got_kind[i], exp_bytes[i], exp_first[i], exp_last[i],
                             exp_kind[i]));
        end
        mism++;
      end
    end
    tb_check(mism == 0, $sformatf("%0d mismatching bytes", mism));
    tb_check(exp_nals == (RANDOM_NALS + 7 + 3), "NAL count");
    $display("NOTE: tb_rtlnet_h264_bitpack: %0d NAL units, %0d bytes compared", exp_nals, exp_bytes.size());
    tb_verdict("tb_rtlnet_h264_bitpack");
  end

  initial begin
    #500ms;
    tb_error("timeout");
    tb_verdict("tb_rtlnet_h264_bitpack");
  end

endmodule
