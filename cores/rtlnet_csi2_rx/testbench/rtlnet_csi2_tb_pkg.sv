// -----------------------------------------------------------------------------
// File: rtlnet_csi2_tb_pkg.sv
// Purpose: bench-side CSI-2 packet builders for the camera receiver benches, written independently of the RTL: the header ECC from the
//   parity equations (explicit bit lists), the payload CRC-16 as a bit-serial MSB-first shift register over the bit-reversed bytes, short
//   and long packet builders, RAW10 packing and the pair stream helper.
// Overview:
//   * ecc_of(d24): the six parity bits P0..P5 of the CSI-2 header ECC as the XOR of the listed data bits, returned as the ECC byte.
//   * crc16_of(bytes): register 0xFFFF, polynomial 0x1021 shifted MSB first, every byte fed least significant bit first; the CRC to
//     transmit is the register with its bit order reversed (low byte sent first). Equal to the reflected 0x8408 byte-wise algorithm.
//   * short_pkt(vc, dt, wc) gives the four bytes; long_pkt(vc, dt, payload) the header, payload and CRC bytes (flip_crc inverts one CRC bit).
//   * raw10_payload(pixels) packs groups of four 10-bit pixels into five bytes (four high bytes, then the four low bit pairs).
//   * to_pairs(bytes) splits a byte list into the pair stream of two lanes ({byte 2n + 1, byte 2n}); a trailing odd byte is paired with 0x00.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 11-15-2026
//   * 11-15-2026: initial version.
// -----------------------------------------------------------------------------
package rtlnet_csi2_tb_pkg;

  import rtlnet_tb_pkg::*;

  typedef bit [9:0] pix_q_t[$];

  function automatic bit [7:0] ecc_of(input bit [23:0] d);
    bit [5:0] p;
    p[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
    p[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
    p[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
    p[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
    p[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
    p[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
    return {2'b00, p};
  endfunction

  function automatic bit [15:0] crc16_of(input bytes_t b);
    bit [15:0] r;
    bit        fb;
    bit [15:0] rr;
    r = 16'hFFFF;
    for (int i = 0; i < b.size(); i++) begin
      for (int k = 0; k < 8; k++) begin
        fb = r[15] ^ b[i][k];
        r  = {r[14:0], 1'b0};
        if (fb) r = r ^ 16'h1021;
      end
    end
    for (int k = 0; k < 16; k++) rr[k] = r[15 - k];
    return rr;
  endfunction

  function automatic bytes_t header_bytes(input bit [1:0] vc, input bit [5:0] dt, input bit [15:0] wc);
    bytes_t h;
    bit [23:0] d;
    d = {wc[15:8], wc[7:0], vc, dt};
    h.push_back(d[7:0]);
    h.push_back(d[15:8]);
    h.push_back(d[23:16]);
    h.push_back(ecc_of(d));
    return h;
  endfunction

  function automatic bytes_t short_pkt(input bit [1:0] vc, input bit [5:0] dt, input bit [15:0] wc);
    return header_bytes(vc, dt, wc);
  endfunction

  function automatic bytes_t long_pkt(input bit [1:0] vc, input bit [5:0] dt, input bytes_t payload, input int flip_crc_bit = -1);
    bytes_t p;
    bit [15:0] c;
    p = header_bytes(vc, dt, 16'(payload.size()));
    for (int i = 0; i < payload.size(); i++) p.push_back(payload[i]);
    c = crc16_of(payload);
    if (flip_crc_bit >= 0) c[flip_crc_bit] = ~c[flip_crc_bit];
    p.push_back(c[7:0]);
    p.push_back(c[15:8]);
    return p;
  endfunction

  function automatic bytes_t raw10_payload(input pix_q_t px);
    bytes_t b;
    for (int g = 0; g + 3 < px.size(); g += 4) begin
      b.push_back(px[g + 0][9:2]);
      b.push_back(px[g + 1][9:2]);
      b.push_back(px[g + 2][9:2]);
      b.push_back(px[g + 3][9:2]);
      b.push_back({px[g + 3][1:0], px[g + 2][1:0], px[g + 1][1:0], px[g + 0][1:0]});
    end
    return b;
  endfunction

  // Pair stream words {byte 2n + 1, byte 2n}.
  function automatic bit [15:0] pair_at(input bytes_t b, input int n);
    bit [7:0] lo, hi;
    lo = (2 * n < b.size()) ? b[2 * n] : 8'h00;
    hi = (2 * n + 1 < b.size()) ? b[2 * n + 1] : 8'h00;
    return {hi, lo};
  endfunction

  // Flip one bit of one byte of a packet (header bit positions 0..31, then payload).
  function automatic bytes_t flip_bit(input bytes_t b, input int bitpos);
    bytes_t r;
    byte unsigned t;
    r = b;
    t = r[bitpos / 8];
    t[bitpos % 8] = ~t[bitpos % 8];
    r[bitpos / 8] = t;
    return r;
  endfunction

endpackage
