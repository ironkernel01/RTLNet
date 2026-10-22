// -----------------------------------------------------------------------------
// File: rtlnet_tb_pkg.sv
// Purpose: shared bench support for every RTLNet testbench: the check counter
//   and the one verdict line, plus oracles written independently of the RTL
//   (bit-serial CRC-32, RFC 1071 checksum) and byte-queue frame builders.
// Overview:
//   * tb_check(cond, msg) counts a check and records a failure; tb_verdict(bench)
//     prints exactly one anchored line, `TEST PASS: <bench> checks=<n>` or
//     `TEST FAIL: <bench> fails=<n> checks=<n> first=<msg>`, and finishes.
//     +INJECT_FAILURE forces a failure (the negative control every bench runs).
//   * crc32_serial_fcs is an MSB-first shift register over the octets in wire
//     bit order (LSB of each octet first), polynomial 0x04C11DB7, deliberately
//     not the reflected byte function of rtlnet_pkg. It returns the 4 FCS
//     octets in transmission order.
//   * inet_sum folds a byte queue as 16-bit big-endian words (odd final byte
//     zero padded, RFC 1071 section 1).
//   * Frame builders return byte queues (byte 0 = first wire byte).
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// -----------------------------------------------------------------------------
package rtlnet_tb_pkg;

  typedef byte unsigned bytes_t[$];

  int    tb_checks    = 0;
  int    tb_fails     = 0;
  string tb_first_msg = "";

  // Count one check; report and record a failure.
  function automatic void tb_check(input bit cond, input string msg);
    tb_checks++;
    if (!cond) begin
      tb_fails++;
      if (tb_first_msg == "") tb_first_msg = msg;
      $display("CHECK FAILED @%0t: %s", $time, msg);
    end
  endfunction

  // Unconditional failure (e.g. a timeout).
  function automatic void tb_error(input string msg);
    tb_check(1'b0, msg);
  endfunction

  // Print the single verdict line and end the simulation.
  task automatic tb_verdict(input string bench);
    if ($test$plusargs("INJECT_FAILURE")) tb_check(1'b0, "INJECT_FAILURE negative control");
    if (tb_fails == 0 && tb_checks > 0) begin
      $display("TEST PASS: %s checks=%0d", bench, tb_checks);
    end else begin
      $display("TEST FAIL: %s fails=%0d checks=%0d first=%s", bench, tb_fails, tb_checks,
               (tb_checks == 0) ? "no checks ran" : tb_first_msg);
    end
    $finish;
  endtask

  // ---------------------------------------------------------------------------
  // Independent CRC-32 oracle (IEEE 802.3 clause 3.2.9), MSB-first register.
  // ---------------------------------------------------------------------------
  function automatic bytes_t crc32_serial_fcs(input bytes_t frame);
    bit [31:0] r;
    bit        fb;
    bytes_t    fcs;
    byte unsigned b;
    r = 32'hFFFFFFFF;
    for (int i = 0; i < $size(frame); i++) begin
      for (int k = 0; k < 8; k++) begin
        fb = r[31] ^ frame[i][k];
        r  = {r[30:0], 1'b0};
        if (fb) r = r ^ 32'h04C11DB7;
      end
    end
    r = ~r;
    // Transmission order: r[31] first. Octet n carries r[31-8n .. 24-8n],
    // first transmitted bit in the octet's LSB.
    for (int n = 0; n < 4; n++) begin
      for (int k = 0; k < 8; k++) b[k] = r[31 - 8*n - k];
      fcs.push_back(b);
    end
    return fcs;
  endfunction

  // CRC-32 of "123456789" in the usual reflected-register form (0xCBF43926),
  // derived from the serial oracle, to self-test it.
  function automatic bit [31:0] crc32_check_value(input bytes_t data);
    bytes_t f;
    f = crc32_serial_fcs(data);
    return {f[3], f[2], f[1], f[0]};
  endfunction

  // ---------------------------------------------------------------------------
  // RFC 1071 ones'-complement sum over bytes[start .. start+len-1].
  // ---------------------------------------------------------------------------
  function automatic bit [15:0] inet_sum(input bytes_t data, input int start, input int len);
    bit [31:0] s;
    s = 0;
    for (int i = 0; i < len; i += 2) begin
      bit [15:0] w;
      w[15:8] = data[start + i];
      w[7:0]  = (i + 1 < len) ? data[start + i + 1] : 8'h00;
      s = s + w;
    end
    while (s[31:16] != 0) s = s[15:0] + s[31:16];
    return s[15:0];
  endfunction

  // Checksum field value for a region whose checksum field is currently zero.
  function automatic bit [15:0] inet_checksum(input bytes_t data, input int start, input int len);
    return ~inet_sum(data, start, len);
  endfunction

  // ---------------------------------------------------------------------------
  // Frame builders (byte queues, wire order).
  // ---------------------------------------------------------------------------
  function automatic void push16(ref bytes_t q, input bit [15:0] v);
    q.push_back(v[15:8]); q.push_back(v[7:0]);
  endfunction

  function automatic void push32(ref bytes_t q, input bit [31:0] v);
    q.push_back(v[31:24]); q.push_back(v[23:16]); q.push_back(v[15:8]); q.push_back(v[7:0]);
  endfunction

  function automatic void push48(ref bytes_t q, input bit [47:0] v);
    for (int i = 5; i >= 0; i--) q.push_back(v[8*i +: 8]);
  endfunction

  function automatic bit [15:0] get16(input bytes_t q, input int at);
    return {q[at], q[at + 1]};
  endfunction

  function automatic bit [31:0] get32(input bytes_t q, input int at);
    return {q[at], q[at + 1], q[at + 2], q[at + 3]};
  endfunction

  function automatic bit [47:0] get48(input bytes_t q, input int at);
    return {q[at], q[at + 1], q[at + 2], q[at + 3], q[at + 4], q[at + 5]};
  endfunction

  // Ethernet II header.
  function automatic bytes_t eth_header(input bit [47:0] dst, input bit [47:0] src, input bit [15:0] etype);
    bytes_t q;
    push48(q, dst); push48(q, src); push16(q, etype);
    return q;
  endfunction

  // IPv4 header (IHL 5) with a correct header checksum.
  function automatic bytes_t ipv4_header(input bit [15:0] total_len, input bit [15:0] ident,
                                         input bit [7:0] proto, input bit [31:0] src, input bit [31:0] dst,
                                         input bit [7:0] ttl = 8'd64, input bit [15:0] flags_frag = 16'h4000,
                                         input bit [7:0] tos = 8'h00);
    bytes_t q;
    bit [15:0] c;
    q.push_back(8'h45); q.push_back(tos);
    push16(q, total_len); push16(q, ident); push16(q, flags_frag);
    q.push_back(ttl); q.push_back(proto);
    push16(q, 16'h0000);
    push32(q, src); push32(q, dst);
    c = inet_checksum(q, 0, 20);
    q[10] = c[15:8]; q[11] = c[7:0];
    return q;
  endfunction

  // Complete Ethernet/IPv4/UDP frame (UDP checksum 0 unless with_csum).
  function automatic bytes_t udp_frame(input bit [47:0] dst_mac, input bit [47:0] src_mac,
                                       input bit [31:0] src_ip, input bit [31:0] dst_ip,
                                       input bit [15:0] src_port, input bit [15:0] dst_port,
                                       input bytes_t payload, input bit [15:0] ident = 16'h0001,
                                       input bit with_csum = 1'b0);
    bytes_t q;
    bytes_t ip;
    bytes_t udp;
    bytes_t pseudo;
    bit [15:0] c;
    push16(udp, src_port); push16(udp, dst_port); push16(udp, 16'(8 + payload.size())); push16(udp, 16'h0000);
    for (int i = 0; i < $size(payload); i++) udp.push_back(payload[i]);
    if (with_csum) begin
      push32(pseudo, src_ip); push32(pseudo, dst_ip); pseudo.push_back(8'h00); pseudo.push_back(8'd17);
      push16(pseudo, 16'(udp.size()));
      for (int i = 0; i < $size(udp); i++) pseudo.push_back(udp[i]);
      c = inet_checksum(pseudo, 0, pseudo.size());
      if (c == 16'h0000) c = 16'hFFFF;
      udp[6] = c[15:8]; udp[7] = c[7:0];
    end
    q  = eth_header(dst_mac, src_mac, 16'h0800);
    ip = ipv4_header(16'(20 + udp.size()), ident, 8'd17, src_ip, dst_ip);
    for (int i = 0; i < $size(ip); i++)  q.push_back(ip[i]);
    for (int i = 0; i < $size(udp); i++) q.push_back(udp[i]);
    return q;
  endfunction

  // Pad to the 60-byte Ethernet minimum with zeros (what a sending NIC does).
  function automatic bytes_t pad60(input bytes_t q);
    bytes_t r;
    r = q;
    while (r.size() < 60) r.push_back(8'h00);
    return r;
  endfunction

  // Hex dump of up to `max` bytes, for failure messages.
  function automatic string hexdump(input bytes_t q, input int max = 64);
    string s;
    s = "";
    for (int i = 0; i < q.size() && i < max; i++) s = {s, $sformatf("%02x", q[i]), ((i % 8) == 7) ? " " : ""};
    if (q.size() > max) s = {s, "..."};
    return s;
  endfunction

  // Byte-exact comparison with a reported first difference.
  function automatic bit bytes_equal(input bytes_t got, input bytes_t exp, output string why);
    why = "";
    if (got.size() != exp.size()) begin
      why = $sformatf("length %0d, expected %0d", got.size(), exp.size());
      return 1'b0;
    end
    for (int i = 0; i < $size(exp); i++) begin
      if (got[i] !== exp[i]) begin
        why = $sformatf("byte %0d = %02x, expected %02x", i, got[i], exp[i]);
        return 1'b0;
      end
    end
    return 1'b1;
  endfunction

endpackage
