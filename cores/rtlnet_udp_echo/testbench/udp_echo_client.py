#!/usr/bin/env python3
"""
udp_echo_client.py -- host test client for the RTLNet UDP echo server

Copyright (C) 2026 IronKernel. All rights reserved.

Role: sends N datagrams of chosen or random sizes to <ip>:<port>, waits for
each reply, checks it byte for byte against what was sent, and reports loss,
mismatches and round-trip latency. Python 3 standard library only.

The board answers each datagram with the same payload from the echo socket's
port to the client's port (rtlnet_udp_echo on rtlnet_udp_socket). Payloads
are at most 1472 bytes so no datagram is fragmented (the socket layer drops
fragments). Every payload is derived from its sequence number and size, so a
late reply to an earlier datagram is recognised and counted as late, not as
a mismatch.

Examples:
  python udp_echo_client.py 192.168.1.220                    # 100 datagrams, sizes 0..1472 random
  python udp_echo_client.py 192.168.1.220 -p 7 -n 1473 --sweep   # every size 0..1472 once
  python udp_echo_client.py 192.168.1.220 --sizes 0,1,64,512,1472 -n 50 --timeout 0.5

Exit status: 0 when every datagram was answered correctly (or the loss stays
within --max-loss), 1 on loss above the limit or any mismatch, 2 on bad
arguments or a socket error.
"""
import argparse
import random
import socket
import statistics
import sys
import time

MAX_PAYLOAD = 1472   # 1500-byte IPv4 MTU - 20 IPv4 - 8 UDP; matches RTLNET_UDPS_MAX_PAYLOAD


def make_payload(seq, size):
    """Deterministic payload of `size` bytes for datagram `seq`."""
    base = (seq * 131 + size * 7) & 0xFF
    return bytes(((base + i * 29 + (i >> 5)) & 0xFF) for i in range(size))


def parse_sizes(text):
    sizes = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            sizes.extend(range(int(lo), int(hi) + 1))
        else:
            sizes.append(int(part))
    return sizes


def percentile(sorted_values, pct):
    if not sorted_values:
        return 0.0
    k = (len(sorted_values) - 1) * pct / 100.0
    lo = int(k)
    hi = min(lo + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (k - lo)


def main():
    ap = argparse.ArgumentParser(description="RTLNet UDP echo test client")
    ap.add_argument("host", help="board IPv4 address")
    ap.add_argument("-p", "--port", type=int, default=7, help="echo socket's UDP port (default 7)")
    ap.add_argument("-n", "--count", type=int, default=100, help="datagrams to send (default 100)")
    grp = ap.add_mutually_exclusive_group()
    grp.add_argument("--sizes", help="comma-separated sizes or ranges, cycled (e.g. 0,1,64,100-110,1472)")
    grp.add_argument("--sweep", action="store_true", help="sizes 0..1472 in order, cycled")
    ap.add_argument("--min-size", type=int, default=0, help="smallest random size (default 0)")
    ap.add_argument("--max-size", type=int, default=MAX_PAYLOAD, help="largest random size (default 1472)")
    ap.add_argument("--timeout", type=float, default=1.0, help="seconds to wait for each reply (default 1.0)")
    ap.add_argument("--interval", type=float, default=0.0, help="pause between datagrams, seconds")
    ap.add_argument("--max-loss", type=float, default=0.0, help="loss percentage still counted as a pass")
    ap.add_argument("--seed", type=int, default=1, help="random size seed (default 1)")
    ap.add_argument("--bind-port", type=int, default=0, help="local UDP port (default: any)")
    ap.add_argument("-v", "--verbose", action="store_true", help="print every datagram")
    args = ap.parse_args()

    if args.sizes:
        try:
            size_list = parse_sizes(args.sizes)
        except ValueError:
            print("error: --sizes must be integers or ranges", file=sys.stderr)
            return 2
    elif args.sweep:
        size_list = list(range(0, MAX_PAYLOAD + 1))
    else:
        size_list = None
    check_sizes = size_list if size_list is not None else [args.min_size, args.max_size]
    if not check_sizes or min(check_sizes) < 0 or max(check_sizes) > MAX_PAYLOAD or args.min_size > args.max_size:
        print("error: sizes must lie in 0..%d" % MAX_PAYLOAD, file=sys.stderr)
        return 2
    if args.count < 1:
        print("error: --count must be at least 1", file=sys.stderr)
        return 2

    rng = random.Random(args.seed)
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("", args.bind_port))
        sock.settimeout(args.timeout)
        target = (socket.gethostbyname(args.host), args.port)
    except OSError as exc:
        print("error: socket setup failed: %s" % exc, file=sys.stderr)
        return 2

    sent = 0
    received = 0
    lost = 0
    mismatched = 0
    late = 0
    foreign = 0
    bytes_sent = 0
    rtts_ms = []
    lost_seqs = {}          # seq -> payload of datagrams that timed out (for late detection)
    first_mismatch = None

    t_start = time.perf_counter()
    for seq in range(args.count):
        size = size_list[seq % len(size_list)] if size_list is not None else rng.randint(args.min_size, args.max_size)
        payload = make_payload(seq, size)
        try:
            t0 = time.perf_counter()
            sock.sendto(payload, target)
        except OSError as exc:
            print("error: send failed at datagram %d: %s" % (seq, exc), file=sys.stderr)
            return 2
        sent += 1
        bytes_sent += size
        answered = False
        deadline = t0 + args.timeout
        while not answered:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                break
            sock.settimeout(remaining)
            try:
                data, peer = sock.recvfrom(65535)
            except socket.timeout:
                break
            except OSError as exc:
                print("error: receive failed: %s" % exc, file=sys.stderr)
                return 2
            t1 = time.perf_counter()
            if peer != target:
                foreign += 1
                continue
            if data == payload:
                answered = True
                received += 1
                rtts_ms.append((t1 - t0) * 1000.0)
                if args.verbose:
                    print("seq %6d size %4d ok  %.3f ms" % (seq, size, rtts_ms[-1]))
                continue
            late_seq = next((s for s, p in lost_seqs.items() if p == data), None)
            if late_seq is not None:
                late += 1
                del lost_seqs[late_seq]
                continue
            mismatched += 1
            if first_mismatch is None:
                first_mismatch = (seq, size, len(data))
            if args.verbose:
                print("seq %6d size %4d MISMATCH (got %d bytes)" % (seq, size, len(data)))
        if not answered:
            lost += 1
            lost_seqs[seq] = payload
            if args.verbose:
                print("seq %6d size %4d LOST" % (seq, size))
        if args.interval > 0:
            time.sleep(args.interval)
    elapsed = time.perf_counter() - t_start

    loss_pct = 100.0 * lost / sent
    print("target            %s:%d" % target)
    print("sent              %d datagrams, %d payload bytes, %.2f s" % (sent, bytes_sent, elapsed))
    print("answered exactly  %d" % received)
    print("lost              %d (%.2f %%), %d of them answered late" % (lost, loss_pct, late))
    print("mismatched        %d" % mismatched)
    if foreign:
        print("from other hosts  %d (ignored)" % foreign)
    if first_mismatch is not None:
        print("first mismatch    seq %d, sent %d bytes, got %d bytes" % first_mismatch)
    if rtts_ms:
        s = sorted(rtts_ms)
        print("latency ms        min %.3f  avg %.3f  p50 %.3f  p99 %.3f  max %.3f" %
              (s[0], statistics.mean(s), percentile(s, 50), percentile(s, 99), s[-1]))
    ok = (mismatched == 0) and (loss_pct <= args.max_loss)
    print("RESULT            %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
