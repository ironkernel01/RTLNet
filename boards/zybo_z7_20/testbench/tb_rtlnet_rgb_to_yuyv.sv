// Purpose: check colorimetry, pixel packing, frame flags, stalls and recovery.
// Overview: real-valued BT.709 oracle is independent of the RTL's Q16 matrix.
//   A one-code tolerance covers coefficient quantization; flags and byte order
//   are exact. Primary/secondary colors, grayscale and random pairs exercise it.
// Revision: 11-14-2026. Initial adapter bench. No foreach loops.
`timescale 1ns/1ps
module tb_rtlnet_rgb_to_yuyv;
  import rtlnet_tb_pkg::*;
  logic clk = 0;
  always #3.333 clk = ~clk;
  logic resetn = 0;
  logic [23:0] s_data = 0;
  logic s_valid = 0;
  wire s_ready;
  logic s_user = 0;
  logic s_last = 0;
  wire [31:0] m_data;
  wire m_valid;
  logic m_ready = 0;
  wire m_user;
  wire m_last;
  wire format_error;
  logic random_ready = 1;
  logic [31:0] expected [0:8191];
  logic expected_user [0:8191];
  logic expected_last [0:8191];
  integer wr = 0;
  integer rd = 0;
  integer lane;
  integer actual_byte;
  integer expected_byte;
  logic stalled = 0;
  logic [33:0] held;
  logic [23:0] palette [0:7];

  rtlnet_rgb_to_yuyv dut (
    .clk(clk), .resetn(resetn),
    .s_axis_tdata(s_data), .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
    .s_axis_tuser(s_user), .s_axis_tlast(s_last),
    .m_axis_tdata(m_data), .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
    .m_axis_tuser(m_user), .m_axis_tlast(m_last), .format_error(format_error)
  );

  // A floating-point reference derives chroma from the color-difference definition.
  function automatic real y_linear(input logic [23:0] p);
    return (0.2126 * p[23:16]) + (0.7152 * p[7:0]) + (0.0722 * p[15:8]);
  endfunction
  function automatic integer code_value(input real v, input integer upper);
    integer q;
    q = $rtoi($floor(v + 0.5));
    if (q < 16) q = 16;
    if (q > upper) q = upper;
    return q;
  endfunction
  function automatic logic [31:0] reference_pair(input logic [23:0] a, input logic [23:0] b);
    integer y0;
    integer y1;
    integer cb;
    integer cr;
    real l0;
    real l1;
    l0 = y_linear(a);
    l1 = y_linear(b);
    y0 = code_value(16.0 + (219.0 * l0 / 255.0), 235);
    y1 = code_value(16.0 + (219.0 * l1 / 255.0), 235);
    cb = code_value(128.0 + (224.0 / 255.0) *
                    ((a[15:8] - l0) + (b[15:8] - l1)) / (4.0 * (1.0 - 0.0722)), 240);
    cr = code_value(128.0 + (224.0 / 255.0) *
                    ((a[23:16] - l0) + (b[23:16] - l1)) / (4.0 * (1.0 - 0.2126)), 240);
    return {cr[7:0], y1[7:0], cb[7:0], y0[7:0]};
  endfunction

  // The driver holds each offered pixel through every backpressure cycle.
  task automatic pixel(input logic [23:0] p, input bit sof, input bit eol);
    @(negedge clk);
    s_data = p;
    s_user = sof;
    s_last = eol;
    s_valid = 1;
    do @(posedge clk); while (!s_ready);
    @(negedge clk);
    s_valid = 0;
  endtask
  task automatic pair_pixels(input logic [23:0] a, input logic [23:0] b,
                             input bit sof, input bit eol);
    expected[wr] = reference_pair(a, b);
    expected_user[wr] = sof;
    expected_last[wr] = eol;
    wr++;
    pixel(a, sof, 0);
    pixel(b, 0, eol);
  endtask

  // Ready randomization includes runs of blocked output cycles.
  always @(negedge clk) begin
    if (random_ready) m_ready = (($urandom % 4) != 0);
  end

  // Scoreboard checks output ownership on every clock, including stalled cycles.
  always @(posedge clk) begin
    if (!resetn) begin
      stalled = 0;
    end else begin
      if (stalled) begin
        tb_check(m_valid === 1'b1, "valid held while stalled");
        tb_check({m_user, m_last, m_data} === held, "payload held while stalled");
      end
      stalled = m_valid && !m_ready;
      held = {m_user, m_last, m_data};
      if (m_valid && m_ready) begin
        tb_check(rd < wr, "no unexpected output pair");
        if (rd < wr) begin
          for (lane = 0; lane < 4; lane++) begin
            actual_byte = m_data[lane*8 +: 8];
            expected_byte = expected[rd][lane*8 +: 8];
            tb_check((actual_byte >= expected_byte - 1) && (actual_byte <= expected_byte + 1),
                     $sformatf("pair %0d byte %0d got %0d expected %0d", rd, lane, actual_byte, expected_byte));
          end
          tb_check(m_user === expected_user[rd], "SOF preserved");
          tb_check(m_last === expected_last[rd], "EOL preserved");
          rd++;
        end
      end
    end
  end

  // Directed malformed inputs and reset prove pairing state recovers.
  initial begin
    palette[0] = 24'h000000;
    palette[1] = 24'hffffff;
    palette[2] = 24'hff0000;
    palette[3] = 24'h0000ff;
    palette[4] = 24'h00ff00;
    palette[5] = 24'hff00ff;
    palette[6] = 24'hffff00;
    palette[7] = 24'h00ffff;
    repeat (5) @(negedge clk);
    resetn = 1;
    for (int a = 0; a < 8; a++) begin
      for (int b = 0; b < 8; b++) pair_pixels(palette[a], palette[b], b == 0, b == 7);
    end
    for (int g = 0; g < 256; g++) pair_pixels({3{g[7:0]}}, {3{g[7:0]}}, g == 0, g == 255);
    for (int n = 0; n < 2048; n++) pair_pixels($urandom, $urandom, (n % 32) == 0, (n % 32) == 31);
    wait (rd == wr);
    @(negedge clk);
    tb_check(!format_error, "legal input has no framing error");
    random_ready = 0;
    m_ready = 0;
    fork
      begin
        pair_pixels(24'h000000, 24'hffffff, 1, 0);
        pair_pixels(24'hff0000, 24'h0000ff, 0, 1);
      end
      begin
        repeat (100) @(negedge clk);
        m_ready = 1;
      end
    join
    wait (rd == wr);
    pixel(24'h123456, 1, 1);
    // Permit registered conversion latency before checking the sticky error.
    for (int n = 0; n < 16 && !format_error; n++) @(negedge clk);
    tb_check(format_error, "odd line sets framing error");
    pixel(24'h987654, 1, 0);
    pair_pixels(24'h000000, 24'hffffff, 1, 1);
    wait (rd == wr);
    pixel(24'h123456, 1, 0);
    @(negedge clk);
    resetn = 0;
    repeat (3) @(negedge clk);
    resetn = 1;
    tb_check(!m_valid && !format_error, "reset clears pending state and errors");
    pair_pixels(24'hff0000, 24'h0000ff, 1, 1);
    wait (rd == wr);
    repeat (5) @(negedge clk);
    tb_check(rd == 2372, "all expected pixel pairs arrive");
    tb_verdict("tb_rtlnet_rgb_to_yuyv");
  end

  // A lost handshake or deadlock produces a verdict rather than a hung runner.
  initial begin
    #2000000;
    tb_error("watchdog");
    tb_verdict("tb_rtlnet_rgb_to_yuyv");
  end
endmodule
