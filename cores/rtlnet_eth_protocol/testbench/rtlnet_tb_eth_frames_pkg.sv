// -----------------------------------------------------------------------------
// File: rtlnet_tb_eth_frames_pkg.sv
// Purpose: bench-side frame builders for the protocol wrapper bench: ARP
//   requests and the replies a correct ARP leaf sends, ICMP echo requests and
//   the replies a correct ICMP leaf sends. Written from RFC 826 / RFC 792 /
//   RFC 791 field tables with the rtlnet_tb_pkg byte-queue helpers and its
//   RFC 1071 oracle; independent of the RTL.
// Overview:
//   * arp_request / arp_reply: 42-byte request (broadcast destination unless
//     given) and the 42-byte unicast reply (RFC 826 swap).
//   * echo_request / echo_reply: Ethernet II + IPv4 (IHL 5) + ICMP echo; the
//     reply has both checksums fully recomputed, TTL 64, ToS, Identification
//     and flags echoed, length 14 + IP Total Length.
//   * rand_bytes uses a caller-owned seed.
// Language: SystemVerilog-2012 (simulation only).
// Revision: 10-22-2026
//   * 10-22-2026: initial version.
// -----------------------------------------------------------------------------
package rtlnet_tb_eth_frames_pkg;

  import rtlnet_tb_pkg::*;

  function automatic bytes_t rand_bytes(ref int seed, input int n);
    bytes_t q;
    for (int i = 0; i < n; i++) begin
      q.push_back(8'($urandom(seed)));
      seed++;
    end
    return q;
  endfunction

  function automatic bytes_t arp_request(input bit [47:0] sha, input bit [31:0] spa, input bit [31:0] tpa,
                                         input bit [47:0] dst = 48'hFFFF_FFFF_FFFF);
    bytes_t q;
    q = eth_header(dst, sha, 16'h0806);
    push16(q, 16'h0001); push16(q, 16'h0800); q.push_back(8'd6); q.push_back(8'd4); push16(q, 16'h0001);
    push48(q, sha); push32(q, spa); push48(q, 48'h0); push32(q, tpa);
    return q;
  endfunction

  function automatic bytes_t arp_reply(input bytes_t req, input bit [47:0] mac, input bit [31:0] ip);
    bytes_t q;
    q = eth_header(get48(req, 22), mac, 16'h0806);
    push16(q, 16'h0001); push16(q, 16'h0800); q.push_back(8'd6); q.push_back(8'd4); push16(q, 16'h0002);
    push48(q, mac); push32(q, ip); push48(q, get48(req, 22)); push32(q, get32(req, 28));
    return q;
  endfunction

  function automatic bytes_t echo_request(input bit [47:0] dst_mac, input bit [47:0] src_mac,
                                          input bit [31:0] src_ip, input bit [31:0] dst_ip,
                                          input bit [15:0] icmp_id, input bit [15:0] icmp_seq,
                                          input bytes_t data, input bit [15:0] ip_id = 16'h0100);
    bytes_t    q;
    bytes_t    ip;
    bytes_t    icmp;
    bit [15:0] c;
    icmp.push_back(8'd8); icmp.push_back(8'd0); push16(icmp, 16'h0000); push16(icmp, icmp_id); push16(icmp, icmp_seq);
    for (int i = 0; i < $size(data); i++) icmp.push_back(data[i]);
    c = inet_checksum(icmp, 0, icmp.size());
    icmp[2] = c[15:8]; icmp[3] = c[7:0];
    q  = eth_header(dst_mac, src_mac, 16'h0800);
    ip = ipv4_header(16'(20 + icmp.size()), ip_id, 8'd1, src_ip, dst_ip, 8'd128, 16'h0000, 8'h00);
    for (int i = 0; i < $size(ip); i++)   q.push_back(ip[i]);
    for (int i = 0; i < $size(icmp); i++) q.push_back(icmp[i]);
    return q;
  endfunction

  function automatic bytes_t echo_reply(input bytes_t req, input bit [47:0] mac, input bit [31:0] ip);
    bytes_t    q;
    bytes_t    hdr;
    bytes_t    icmp;
    bit [15:0] total;
    bit [15:0] c;
    total = get16(req, 16);
    q   = eth_header(get48(req, 6), mac, 16'h0800);
    hdr = ipv4_header(total, get16(req, 18), 8'd1, ip, get32(req, 26), 8'd64, get16(req, 20), req[15]);
    for (int i = 0; i < $size(hdr); i++) q.push_back(hdr[i]);
    icmp.push_back(8'd0); icmp.push_back(8'd0); push16(icmp, 16'h0000);
    for (int i = 38; i < 14 + total; i++) icmp.push_back(req[i]);
    c = inet_checksum(icmp, 0, icmp.size());
    icmp[2] = c[15:8]; icmp[3] = c[7:0];
    for (int i = 0; i < $size(icmp); i++) q.push_back(icmp[i]);
    return q;
  endfunction

endpackage
