#!/usr/bin/env python3
"""
File: iperf_board_emulator.py
Purpose: the board's TCP iperf server behavior (src/lwip/rtlnet_lwiperf.c) written a second
  time in Python, to check what the stock iperf 2.2.2 Windows client does with it before the
  firmware runs on the board: the client's summary lines for plain, -R, -r and -d.
Overview:
  * Listens on a TCP port; for each connection reads the client test header (length from the
    flags: EXTEND and LEN_BIT give twice the length in the low byte), then
      plain     counts the bytes until the client closes;
      -R        (VERSION2 flag and upperflags 0x0400) sends the pattern on the same
                connection for mAmount (negative: 10 ms units; positive: bytes), then closes;
      -r        after the client closed, connects back to the client's address and mPort,
                writes the 24-byte header (flags 0) and sends the pattern for mAmount;
      -d        (flags 0xC0010081) connects back at once, while receiving.
  * Prints the server-side counts; run iperf.exe against it with --run to see the client side.
How to run:
  python cpu/microblaze_v_h264/firmware/test/iperf_board_emulator.py --port 5001 \
      --run "plain=-t 3" --run "R=-t 3 -R" --run "r=-t 3 -r" --run "d=-t 3 -d"
  Without --run the emulator serves until interrupted. The iperf client of a -r or -d test
  listens on its own port 5001 (-L / -p): use a port the client can also bind (the default).
Revision: 11-14-2026
  * 11-14-2026: moved to cpu/microblaze_v_h264/ (was microblaze/).
"""
import argparse
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time

IPERF = (os.environ.get("RTLNET_IPERF") or shutil.which("iperf")
         or os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          "..", "..", "..", "..", "..", "tools", "iperf", "iperf.exe")))
PATTERN = (b"0123456789" * 160)
SEG = 1460


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        d = sock.recv(n - len(buf))
        if not d:
            return buf
        buf += d
    return buf


def send_pattern(sock, amount, hdr=b""):
    """Send hdr, then the pattern for the amount (negative: 10 ms units; positive: bytes)."""
    sent = 0
    start = time.time()
    if hdr:
        sock.sendall(hdr)
    if amount == 0:
        amount = -1000
    while True:
        if amount < 0:
            if time.time() - start >= (-amount) / 100.0:
                break
            n = SEG
        else:
            if sent >= amount:
                break
            n = min(SEG, amount - sent)
        sock.sendall(PATTERN[sent % 10: sent % 10 + n])
        sent += n
    return sent, time.time() - start


def connect_back(peer_ip, mport, amount, label):
    s = socket.create_connection((peer_ip, mport), timeout=5)
    hdr = struct.pack(">IIIIII", 0, 1, mport, 0, 0, amount & 0xFFFFFFFF)
    sent, dt = send_pattern(s, amount, hdr)
    s.close()
    print("  [%s] connect-back to %s:%d sent %d bytes in %.2f s" % (label, peer_ip, mport, sent, dt))


def serve(conn, peer):
    hdr = read_exact(conn, 4)
    flags = struct.unpack(">I", hdr)[0]
    hlen = 24
    if (flags & 0x40000000) and (flags & 0x00010000) and ((flags & 0xFE) >> 1) >= 24:
        hlen = (flags & 0xFE) >> 1
    hdr += read_exact(conn, hlen - 4)
    mport = struct.unpack(">I", hdr[8:12])[0] & 0xFFFF
    amount = struct.unpack(">i", hdr[20:24])[0]
    upper = struct.unpack(">H", hdr[32:34])[0] if hlen >= 34 else 0
    reverse = bool(flags & 0x04000000) and bool(upper & 0x0400)
    mode = "reverse" if reverse else ("dual" if flags == 0xC0010081 or (flags & 0x80000001) == 0x80000001 else
                                      "tradeoff" if flags & 0x80000000 else "plain")
    print("  [%s] header %d bytes flags 0x%08x mPort %d amount %d upper 0x%04x -> %s" %
          (peer[0], hlen, flags, mport, amount, upper, mode))
    if reverse:
        sent, dt = send_pattern(conn, amount)
        print("  [reverse] sent %d bytes in %.2f s" % (sent, dt))
        conn.close()
        return
    back = None
    if mode == "dual":
        back = threading.Thread(target=connect_back, args=(peer[0], mport, amount, "dual"))
        back.start()
    total = 0
    t0 = time.time()
    while True:
        d = conn.recv(65536)
        if not d:
            break
        total += len(d)
    print("  [%s] received %d bytes in %.2f s" % (mode, total, time.time() - t0))
    conn.close()
    if mode == "tradeoff":
        connect_back(peer[0], mport, amount, "tradeoff")
    if back is not None:
        back.join()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--port", type=int, default=5001)
    ap.add_argument("--run", action="append", default=[], help="label=iperf options")
    a = ap.parse_args()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(4)

    def acceptor():
        while True:
            try:
                c, p = srv.accept()
            except OSError:
                return
            threading.Thread(target=serve, args=(c, p), daemon=True).start()

    threading.Thread(target=acceptor, daemon=True).start()
    if not a.run:
        print("serving on port %d" % a.port)
        while True:
            time.sleep(1)
    for label, opts in (r.split("=", 1) for r in a.run):
        cmd = [IPERF, "-c", "127.0.0.1", "-p", str(a.port)] + opts.split()
        print("== %s: %s" % (label, " ".join(cmd)))
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        for line in (out.stdout + out.stderr).splitlines():
            if line.strip():
                print("  client: " + line)
        time.sleep(0.5)
    srv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
