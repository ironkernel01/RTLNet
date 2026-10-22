#!/usr/bin/env python3
"""
File: iperf_header_capture.py
Purpose: capture and decode the TCP test header an iperf 2 client sends first on
  its data connection, so the firmware parser (rtlnet_lwiperf.c) rests on bytes
  seen on the wire rather than on a reading of the sources.
Overview:
  * Listens on a TCP port, accepts connections for a few seconds, and for each
    one reads the first bytes the client sends (up to --bytes, until --wait
    seconds pass without data) and prints a hex dump and the decoded fields.
  * The listener never sends data and closes the connection after the capture,
    so the client ends at once.
  * Decoded fields (all big-endian): the 24-byte legacy header
    (flags, numThreads, mPort, bufferlen, mWinBand, mAmount) and, when the
    client sends more, the extension words that follow.
How to run:
  python microblaze/firmware/test/iperf_header_capture.py --port 5101 --run "plain=-t 2" \
      --run "R=-t 2 -R" --run "r=-t 2 -r" --run "d=-t 2 -d"
  (--run starts C:/IronKernel/tools/iperf/iperf.exe -c 127.0.0.1 -p <port> with the
  given options for each capture; without --run the listener waits for any client.)
Revision: 10-22-2026
"""
import argparse
import socket
import struct
import subprocess
import sys
import time

IPERF = r"C:/IronKernel/tools/iperf/iperf.exe"
ACCEPT_MAX = 6          # connections per capture
LEGACY_FIELDS = ("flags", "numThreads", "mPort", "bufferlen", "mWinBand", "mAmount")


def hexdump(data):
    lines = []
    for off in range(0, len(data), 16):
        chunk = data[off:off + 16]
        lines.append("  %04x  %-47s  %s" % (
            off, " ".join("%02x" % b for b in chunk),
            "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)))
    return "\n".join(lines)


def decode(data):
    out = []
    n = min(len(data) // 4, 6)
    for i in range(n):
        v = struct.unpack_from(">I", data, 4 * i)[0]
        sv = struct.unpack_from(">i", data, 4 * i)[0]
        extra = " (signed %d)" % sv if i == 5 else ""
        out.append("  [%2d] %-10s 0x%08x %d%s" % (4 * i, LEGACY_FIELDS[i], v, v, extra))
    if len(data) > 24:
        words = [struct.unpack_from(">I", data, o)[0] for o in range(24, len(data) - 3, 4)]
        out.append("  extension words from byte 24: " + " ".join("%08x" % w for w in words))
    return "\n".join(out)


def capture(srv, nbytes, wait):
    """Accept up to ACCEPT_MAX connections; return a list of (peer, bytes)."""
    got = []
    srv.settimeout(wait)
    for _ in range(ACCEPT_MAX):
        try:
            c, peer = srv.accept()
        except socket.timeout:
            break
        c.settimeout(wait)
        buf = b""
        try:
            while len(buf) < nbytes:
                d = c.recv(nbytes - len(buf))
                if not d:
                    break
                buf += d
                c.settimeout(0.5)
        except socket.timeout:
            pass
        c.close()
        got.append((peer, buf))
    return got


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--port", type=int, default=5101)
    ap.add_argument("--bytes", type=int, default=128)
    ap.add_argument("--wait", type=float, default=3.0)
    ap.add_argument("--run", action="append", default=[], help="label=iperf options")
    a = ap.parse_args()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(8)
    runs = [r.split("=", 1) for r in a.run] or [("any", None)]
    for label, opts in runs:
        proc = None
        if opts is not None:
            cmd = [IPERF, "-c", "127.0.0.1", "-p", str(a.port)] + opts.split()
            print("== %s: %s" % (label, " ".join(cmd)))
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        else:
            print("== waiting for a client on port %d" % a.port)
        for peer, buf in capture(srv, a.bytes, a.wait):
            print(" connection from %s:%d, %d bytes" % (peer[0], peer[1], len(buf)))
            print(hexdump(buf))
            print(decode(buf))
        if proc is not None:
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        time.sleep(0.3)
    srv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
