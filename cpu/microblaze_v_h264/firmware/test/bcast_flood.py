#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File: bcast_flood.py
# Purpose: host-side broadcast load for the storm-control test of the CPU
#   network path: UDP broadcasts at a fixed rate, so `show storm-control` on
#   the board shows the classifier's policer passing its limit per window and
#   dropping the rest. Python standard library only.
# Overview:
#   * Sends --rate datagrams per second for --seconds to each --dest address
#     (default the subnet broadcast 192.169.1.255 and 255.255.255.255), UDP
#     port --port (default 9, discard), --size payload bytes, paced with a
#     monotonic clock (no burst catch-up beyond one interval).
#   * Prints the datagrams sent per destination and the achieved rate; ends
#     with one anchored line: BCAST_FLOOD: DONE sent=<n> rate=<r>/s, or
#     BCAST_FLOOD: FAIL <reason> (socket error).
#   * --bind selects the local interface address (the PC's address on the
#     board's network) when the PC has several networks.
# Usage:
#   python bcast_flood.py [--rate 300] [--seconds 10] [--dest 192.169.1.255,255.255.255.255]
#          [--port 9] [--size 64] [--bind 192.169.1.130]
# Revision: 10-22-2026
#   * 10-22-2026: initial version.
# -----------------------------------------------------------------------------
import argparse
import socket
import sys
import time


def main(argv):
    ap = argparse.ArgumentParser(description="UDP broadcast load for storm-control tests")
    ap.add_argument("--rate", type=float, default=300.0, help="datagrams per second, all destinations together")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--dest", default="192.169.1.255,255.255.255.255")
    ap.add_argument("--port", type=int, default=9)
    ap.add_argument("--size", type=int, default=64)
    ap.add_argument("--bind", default="")
    args = ap.parse_args(argv)
    dests = [d.strip() for d in args.dest.split(",") if d.strip()]
    if args.rate <= 0 or args.seconds <= 0 or not dests:
        print("BCAST_FLOOD: FAIL bad arguments")
        return 2
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        if args.bind:
            s.bind((args.bind, 0))
    except OSError as e:
        print(f"BCAST_FLOOD: FAIL socket: {e}")
        return 1
    payload = bytes(range(256)) * (args.size // 256 + 1)
    payload = payload[:args.size]
    period = 1.0 / args.rate
    sent = {d: 0 for d in dests}
    t0 = time.monotonic()
    nxt = t0
    i = 0
    try:
        while True:
            now = time.monotonic()
            if now - t0 >= args.seconds:
                break
            if now < nxt:
                time.sleep(min(nxt - now, 0.01))
                continue
            d = dests[i % len(dests)]
            s.sendto(payload, (d, args.port))
            sent[d] += 1
            i += 1
            nxt = max(nxt + period, now - period)
    except OSError as e:
        print(f"BCAST_FLOOD: FAIL send: {e}")
        return 1
    finally:
        s.close()
    wall = time.monotonic() - t0
    for d in dests:
        print(f"bcast_flood: {d}:{args.port} sent {sent[d]}")
    total = sum(sent.values())
    print(f"BCAST_FLOOD: DONE sent={total} rate={total / wall:.1f}/s seconds={wall:.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
