#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File: tcp_echo_client.py
# Purpose: host-side test of the firmware TCP echo server (lwIP raw API,
#   port 7, microblaze/firmware/src/rtlnet_tcp_echo.c) over the board's CPU
#   network path. Python standard library only.
# Overview:
#   * Opens --conns concurrent connections to <host>:<port>; each connection
#     runs the same payload plan: every size of --sizes (default 1 byte to
#     64 KiB, including the segment boundaries around the 1460-byte MSS, the
#     5840-byte window and powers of two), --rounds times, each payload random
#     (seeded per connection) and different from the last.
#   * Per message: send and receive run interleaved on a non-blocking socket
#     (select), so a payload larger than the server's window never deadlocks;
#     the echo must return exactly the bytes sent, in order (byte-exact
#     compare, first differing offset reported). Latency = first byte sent to
#     last byte received.
#   * Report: per size the message count, bytes, min/mean/max latency; per
#     connection bytes and errors; total bytes both ways, wall time and
#     throughput (echoed payload bits per second, one direction).
#   * Ends with exactly one anchored line:
#       TCP_ECHO_TEST: PASS conns=<n> messages=<m> bytes=<b> throughput=<kbit/s> kbit/s
#       TCP_ECHO_TEST: FAIL <reason>
#     exit code 0 on PASS, 1 on FAIL, 2 on bad arguments.
# Usage:
#   python tcp_echo_client.py <host> [--port 7] [--conns 4] [--rounds 1]
#          [--sizes 1,2,...] [--timeout 10] [--seed 1]
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------
import argparse
import random
import select
import socket
import sys
import threading
import time

DEFAULT_SIZES = [1, 2, 7, 8, 9, 63, 64, 65, 255, 256, 511, 512, 1023, 1024, 1025, 1459, 1460, 1461,
                 1500, 2047, 2048, 2919, 2920, 2921, 4095, 4096, 4380, 5839, 5840, 5841, 8191, 8192,
                 11680, 16384, 32767, 32768, 65535, 65536]
CHUNK = 16384


class Result:
    """Outcome of one connection."""

    def __init__(self, index):
        self.index = index
        self.error = None
        self.messages = 0
        self.bytes = 0
        self.latency = {}  # size -> list of seconds


def echo_once(sock, payload, timeout):
    """Send payload and receive the same number of bytes, interleaved.

    Returns (echo_bytes, seconds). Raises RuntimeError on timeout or close.
    """
    out = memoryview(payload)
    sent = 0
    got = bytearray()
    t0 = time.perf_counter()
    deadline = t0 + timeout
    while len(got) < len(payload):
        now = time.perf_counter()
        if now > deadline:
            raise RuntimeError(f"timeout after {timeout} s: sent {sent} of {len(payload)}, "
                               f"received {len(got)}")
        wlist = [sock] if sent < len(payload) else []
        r, w, _ = select.select([sock], wlist, [], min(0.5, deadline - now))
        if w:
            try:
                sent += sock.send(out[sent:sent + CHUNK])
            except BlockingIOError:
                pass
        if r:
            try:
                data = sock.recv(min(CHUNK, len(payload) - len(got)))
            except BlockingIOError:
                continue
            if not data:
                raise RuntimeError(f"connection closed by the server after {len(got)} of {len(payload)} bytes")
            got += data
    return bytes(got), time.perf_counter() - t0


def run_connection(args, index, plan, res, start_evt):
    """One client connection: the whole payload plan, byte-exact checks."""
    rng = random.Random(args.seed * 1000 + index)
    try:
        sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
    except OSError as e:
        res.error = f"connect: {e}"
        return
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setblocking(False)
        start_evt.wait()
        for size in plan:
            payload = rng.randbytes(size)
            echo, dt = echo_once(sock, payload, args.timeout)
            if echo != payload:
                bad = next(i for i in range(size) if echo[i] != payload[i])
                res.error = (f"size {size}: echo differs at offset {bad} "
                             f"(sent 0x{payload[bad]:02X}, got 0x{echo[bad]:02X})")
                return
            res.messages += 1
            res.bytes += size
            res.latency.setdefault(size, []).append(dt)
        # Orderly close: FIN, then the server closes its side (recv returns b"").
        sock.setblocking(True)
        sock.settimeout(args.timeout)
        sock.shutdown(socket.SHUT_WR)
        tail = sock.recv(1)
        if tail:
            res.error = "unexpected data after the last echo"
    except (OSError, RuntimeError) as e:
        res.error = str(e)
    finally:
        sock.close()


def parse_sizes(text):
    sizes = []
    for part in text.split(","):
        v = int(part.strip(), 0)
        if v < 1 or v > 1 << 20:
            raise ValueError(f"size {v} out of range 1..1048576")
        sizes.append(v)
    return sizes


def main(argv):
    ap = argparse.ArgumentParser(description="TCP echo test client (RTLNet firmware, port 7)")
    ap.add_argument("host")
    ap.add_argument("--port", type=int, default=7)
    ap.add_argument("--conns", type=int, default=4, help="concurrent connections")
    ap.add_argument("--rounds", type=int, default=1, help="passes over the size list per connection")
    ap.add_argument("--sizes", default=",".join(str(s) for s in DEFAULT_SIZES))
    ap.add_argument("--timeout", type=float, default=10.0, help="seconds per message and for connect")
    ap.add_argument("--seed", type=int, default=1)
    try:
        args = ap.parse_args(argv)
        sizes = parse_sizes(args.sizes)
        if args.conns < 1 or args.rounds < 1:
            raise ValueError("conns and rounds must be at least 1")
    except (SystemExit, ValueError) as e:
        print(f"TCP_ECHO_TEST: FAIL bad arguments ({e})")
        return 2

    plan = sizes * args.rounds
    results = [Result(i) for i in range(args.conns)]
    start_evt = threading.Event()
    threads = [threading.Thread(target=run_connection, args=(args, i, plan, results[i], start_evt), daemon=True)
               for i in range(args.conns)]
    print(f"tcp_echo_client: {args.host}:{args.port}, {args.conns} connection(s), {len(plan)} messages each, "
          f"{sum(plan)} bytes each")
    for t in threads:
        t.start()
    time.sleep(0.2)
    t0 = time.perf_counter()
    start_evt.set()
    for t in threads:
        t.join(args.timeout * (len(plan) + 2))
    wall = time.perf_counter() - t0

    # Per-size latency summary over all connections.
    lat = {}
    for r in results:
        for size, vals in r.latency.items():
            lat.setdefault(size, []).extend(vals)
    print(f"{'size':>7} {'msgs':>5} {'min ms':>9} {'mean ms':>9} {'max ms':>9}")
    for size in sorted(lat):
        v = lat[size]
        print(f"{size:>7} {len(v):>5} {min(v) * 1e3:>9.2f} {sum(v) / len(v) * 1e3:>9.2f} {max(v) * 1e3:>9.2f}")
    for r in results:
        print(f"conn {r.index}: messages {r.messages}, bytes {r.bytes}, {'ok' if r.error is None else 'ERROR ' + r.error}")
    total = sum(r.bytes for r in results)
    msgs = sum(r.messages for r in results)
    kbps = total * 8 / wall / 1e3 if wall > 0 else 0.0
    print(f"total: {msgs} messages, {total} bytes echoed (each way) in {wall:.2f} s, {kbps:.1f} kbit/s")

    alive = [t for t in threads if t.is_alive()]
    errors = [r for r in results if r.error is not None]
    expect = len(plan) * args.conns
    if alive:
        print(f"TCP_ECHO_TEST: FAIL {len(alive)} connection(s) did not finish")
        return 1
    if errors:
        print(f"TCP_ECHO_TEST: FAIL conn {errors[0].index}: {errors[0].error}")
        return 1
    if msgs != expect:
        print(f"TCP_ECHO_TEST: FAIL {msgs} of {expect} messages echoed")
        return 1
    print(f"TCP_ECHO_TEST: PASS conns={args.conns} messages={msgs} bytes={total} throughput={kbps:.1f} kbit/s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
