#!/usr/bin/env python3
"""
eth_echo_test.py -- host test client of the Ethernet demo's two echo servers

Copyright (C) 2026 IronKernel. All rights reserved.

Role: bound to the PC adapter's address (--bind), it exercises
  * the hardware UDP echo (rtlnet_udp_echo in the FPGA fabric, port 7): N datagrams of the chosen sizes, every reply
    checked byte for byte against what was sent; reports loss, late replies, mismatches and the round-trip time
    (min, mean, median, 99th percentile, max);
  * the lwIP TCP echo server of the firmware (port 7): several concurrent connections, each sends messages of the
    chosen sizes and reads the same number of bytes back, compared byte for byte.
  Payloads are derived from the sequence number and size, so a late reply to an earlier datagram is recognised.
  Python 3 standard library only.

Usage:
  python eth_echo_test.py udp <board ip> --bind <pc ip> [-n 400] [--sizes 0,1,64,512,1472] [--timeout 0.5] [--max-loss 0]
  python eth_echo_test.py tcp <board ip> --bind <pc ip> [--conns 4] [--sizes 1,100,1460,1461,4096,65536]

Last output line: ETH_ECHO_UDP: PASS ... / FAIL ...   or   ETH_ECHO_TCP: PASS ... / FAIL ...
Exit status: 0 PASS, 1 FAIL, 2 bad arguments or a socket error.
"""
import argparse
import socket
import statistics
import sys
import threading
import time

UDP_MAX_PAYLOAD = 1472   # 1500-byte IPv4 MTU - 20 IPv4 - 8 UDP: no fragmentation
TCP_DEFAULT_SIZES = "1,7,64,100,1459,1460,1461,2920,4096,16384,65536"


def payload(seq, size):
    base = (seq * 131 + size * 7) & 0xFF
    return bytes(((base + i * 29 + (i >> 5)) & 0xFF) for i in range(size))


def parse_sizes(text):
    out = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            out.extend(range(int(lo), int(hi) + 1))
        else:
            out.append(int(part))
    return out


def pct(values, p):
    if not values:
        return 0.0
    values = sorted(values)
    k = (len(values) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def run_udp(args):
    sizes = parse_sizes(args.sizes)
    if any(s < 0 or s > UDP_MAX_PAYLOAD for s in sizes):
        print("sizes must be 0..%d" % UDP_MAX_PAYLOAD)
        return 2
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, 0))
    sock.settimeout(args.timeout)
    sent = got = lost = late = bad = 0
    rtt = []
    pending = {}
    for seq in range(args.count):
        size = sizes[seq % len(sizes)]
        data = payload(seq, size)
        t0 = time.perf_counter()
        sock.sendto(data, (args.host, args.port))
        sent += 1
        deadline = t0 + args.timeout
        ok = False
        while True:
            remain = deadline - time.perf_counter()
            if remain <= 0:
                break
            sock.settimeout(remain)
            try:
                reply, _ = sock.recvfrom(4096)
            except socket.timeout:
                break
            if reply == data:
                rtt.append((time.perf_counter() - t0) * 1000.0)
                got += 1
                ok = True
                break
            # a reply to an earlier datagram (late) or a corrupt one
            if any(reply == payload(s, len(reply)) for s in range(max(0, seq - 8), seq)):
                late += 1
            else:
                bad += 1
                if args.verbose:
                    print("mismatch seq %d size %d: got %d bytes" % (seq, size, len(reply)))
        if not ok:
            lost += 1
    loss_pct = 100.0 * lost / sent if sent else 100.0
    ok = (bad == 0) and (loss_pct <= args.max_loss) and got > 0
    print("udp echo: sent %d, echoed %d, lost %d (%.2f %%), late %d, mismatched %d" % (sent, got, lost, loss_pct, late, bad))
    if rtt:
        print("udp echo round trip ms: min %.3f mean %.3f median %.3f p99 %.3f max %.3f" %
              (min(rtt), statistics.mean(rtt), statistics.median(rtt), pct(rtt, 99), max(rtt)))
    print("ETH_ECHO_UDP: %s sent=%d lost=%d mismatched=%d mean_ms=%.3f max_ms=%.3f" %
          ("PASS" if ok else "FAIL", sent, lost, bad, statistics.mean(rtt) if rtt else 0.0, max(rtt) if rtt else 0.0))
    return 0 if ok else 1


def tcp_worker(idx, args, sizes, result):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind((args.bind, 0))
        s.settimeout(args.timeout)
        s.connect((args.host, args.port))
        total = 0
        for rnd in range(args.rounds):
            for k, size in enumerate(sizes):
                data = payload(idx * 1000 + rnd * 100 + k, size)
                s.sendall(data)
                buf = bytearray()
                while len(buf) < size:
                    chunk = s.recv(min(65536, size - len(buf)))
                    if not chunk:
                        raise RuntimeError("connection closed after %d of %d bytes (message %d)" % (len(buf), size, k))
                    buf += chunk
                if bytes(buf) != data:
                    first = next(i for i in range(size) if buf[i] != data[i])
                    raise RuntimeError("mismatch in message %d (%d bytes) at byte %d" % (k, size, first))
                total += size
        s.close()
        result[idx] = (True, total, "")
    except Exception as e:  # report every failure of a connection
        result[idx] = (False, 0, "%s: %s" % (type(e).__name__, e))


def run_tcp(args):
    sizes = parse_sizes(args.sizes)
    result = {}
    threads = [threading.Thread(target=tcp_worker, args=(i, args, sizes, result)) for i in range(args.conns)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    dt = time.perf_counter() - t0
    fails = [(i, r[2]) for i, r in sorted(result.items()) if not r[0]]
    total = sum(r[1] for r in result.values())
    for i, why in fails:
        print("connection %d: %s" % (i, why))
    ok = (not fails) and len(result) == args.conns
    print("tcp echo: %d connections, %d bytes echoed in %.2f s (%.2f Mbit/s each way, all connections)" %
          (args.conns, total, dt, total * 8.0 * 2 / dt / 1e6 if dt > 0 else 0.0))
    print("ETH_ECHO_TCP: %s connections=%d bytes=%d" % ("PASS" if ok else "FAIL", args.conns, total))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["udp", "tcp"])
    ap.add_argument("host", help="board IPv4 address")
    ap.add_argument("--bind", required=True, help="IPv4 address of the PC adapter the traffic leaves on")
    ap.add_argument("-p", "--port", type=int, default=7)
    ap.add_argument("-n", "--count", type=int, default=400, help="UDP datagrams")
    ap.add_argument("--sizes", default=None)
    ap.add_argument("--timeout", type=float, default=None)
    ap.add_argument("--max-loss", type=float, default=0.0, help="UDP loss percentage still counted as a pass")
    ap.add_argument("--conns", type=int, default=4, help="TCP connections")
    ap.add_argument("--rounds", type=int, default=1, help="TCP passes over the size list per connection")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    try:
        if args.mode == "udp":
            if args.sizes is None:
                args.sizes = "0,1,2,3,7,8,9,63,64,65,100,255,256,511,512,1000,1400,1471,1472"
            if args.timeout is None:
                args.timeout = 0.5
            return run_udp(args)
        if args.sizes is None:
            args.sizes = TCP_DEFAULT_SIZES
        if args.timeout is None:
            args.timeout = 30.0
        return run_tcp(args)
    except OSError as e:
        print("socket error: %s" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
