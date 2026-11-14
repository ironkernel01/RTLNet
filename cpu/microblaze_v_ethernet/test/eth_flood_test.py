#!/usr/bin/env python3
"""
eth_flood_test.py -- load generator of the Ethernet demo's protection profile test (normal sockets only)

Copyright (C) 2026 IronKernel. All rights reserved.

Role: bound to the PC adapter's address (--bind), it floods the board with one kind of traffic for --seconds at --rate
  per second while one TCP echo connection to the lwIP echo server keeps exchanging data (--no-tcp disables it). Python 3
  standard library only; the ICMP and ARP kinds call the Windows IP helper API (iphlpapi) through ctypes. No administrator
  rights, nothing to install.

Kinds (--kind):
  udp-closed    UDP unicast to the board, closed port 9           (CPU path, class udp)
  udp-echo      UDP unicast to the board, hardware echo port 7    (claimed by the hardware echo: expected not to reach the CPU)
  udp-bcast-lim UDP to the limited broadcast 255.255.255.255      (class udp)
  udp-bcast-net UDP to the subnet broadcast (--bcast)             (class udp)
  mcast         UDP to 239.255.42.42, a group the board never joined (the ingress filter discards it: never reaches the CPU)
  icmp-board    ICMP echo requests to the board (IcmpSendEcho)    (answered by the hardware responder)
  icmp-bcast    ICMP echo requests to the subnet broadcast        (not answered by the hardware: class icmp)
  arp           iphlpapi SendARP for unused subnet addresses      (one ARP request per call for an address that is not
                cached; each call blocks until it times out, so the rate is bounded by --arp-threads / timeout; whether
                a call puts a request on the wire is not checked by this script)

Usage:
  python eth_flood_test.py <board ip> --bind <pc ip> --net <subnet> --prefix <bits> --bcast <subnet broadcast>
         --kind <kind> [--rate 1000] [--seconds 10] [--no-tcp] [--echo-port 7] [--chunk 1460]
         [--icmp-threads 4] [--arp-threads 32]
  python eth_flood_test.py --selftest     (loopback: the UDP sender against a local listener, TCP echo against a local server)
Example addresses: board 192.0.2.50, PC 192.0.2.10, subnet 192.0.2.0/24, broadcast 192.0.2.255.

Output: progress lines, then one anchored line
  ETH_FLOOD: DONE kind=<k> sent=<n> seconds=<s> tcp_errors=<n> tcp_bytes=<n> tcp_max_rtt_ms=<ms> tcp_rounds=<n>
  or ETH_FLOOD: FAIL <reason>; the self test prints ETH_FLOOD_SELFTEST: PASS|FAIL.
Exit status: 0 DONE or PASS, 1 FAIL, 2 bad arguments.
"""
import argparse
import ctypes
import ipaddress
import os
import socket
import sys
import threading
import time

PACE_SLICE_S = 0.01          # senders work in 10 ms slices (Windows timer granularity)
TCP_IO_TIMEOUT_S = 5.0       # one echo round must complete within this, else it is an error
ICMP_PAYLOAD = b"RTLNetFloodTestPing0123456789ABCDEF"
ICMP_TIMEOUT_MS = 1          # do not wait for replies: this is a load generator
MCAST_GROUP = "239.255.42.42"
KINDS = ("udp-closed", "udp-echo", "udp-bcast-lim", "udp-bcast-net", "mcast", "icmp-board", "icmp-bcast", "arp")


class Counters:
    """Thread-safe counters."""

    def __init__(self):
        self.lock = threading.Lock()
        self.sent = 0
        self.tcp_errors = 0
        self.tcp_bytes = 0
        self.tcp_rounds = 0
        self.tcp_max_rtt = 0.0

    def add_sent(self, n=1):
        with self.lock:
            self.sent += n

    def tcp_ok(self, nbytes, rtt):
        with self.lock:
            self.tcp_bytes += nbytes
            self.tcp_rounds += 1
            if rtt > self.tcp_max_rtt:
                self.tcp_max_rtt = rtt

    def tcp_error(self):
        with self.lock:
            self.tcp_errors += 1


def paced(rate, deadline, fn):
    """Call fn() about `rate` times per second until the deadline, in 10 ms slices."""
    per_slice = rate * PACE_SLICE_S
    owed = 0.0
    nxt = time.perf_counter()
    while time.perf_counter() < deadline:
        owed += per_slice
        n = int(owed)
        owed -= n
        for _ in range(n):
            fn()
        nxt += PACE_SLICE_S
        delay = nxt - time.perf_counter()
        if delay > 0:
            time.sleep(delay)
        else:
            nxt = time.perf_counter()


def udp_flood(bind, dest, port, rate, deadline, cnt, broadcast=False, mcast=False):
    """UDP datagrams to dest:port; cnt counts the datagrams the socket accepted."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if broadcast:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    if mcast:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(bind))
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    if bind:
        s.bind((bind, 0))
    data = bytes(range(64))

    def one():
        try:
            s.sendto(data, (dest, port))
            cnt.add_sent()
        except OSError:
            pass
    paced(rate, deadline, one)
    s.close()


def iphlpapi():
    if os.name != "nt":
        raise OSError("this kind needs Windows (iphlpapi)")
    return ctypes.WinDLL("iphlpapi")


def icmp_flood(dest, rate, deadline, cnt):
    """Echo requests through IcmpSendEcho (one worker thread)."""
    iph = iphlpapi()
    iph.IcmpCreateFile.restype = ctypes.c_void_p
    iph.IcmpSendEcho.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint16, ctypes.c_void_p,
                                 ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32]
    handle = iph.IcmpCreateFile()
    if not handle or handle == ctypes.c_void_p(-1).value:
        return
    reply = ctypes.create_string_buffer(512)
    addr = int.from_bytes(socket.inet_aton(dest), "little")

    def one():
        iph.IcmpSendEcho(ctypes.c_void_p(handle), addr, ICMP_PAYLOAD, len(ICMP_PAYLOAD), None, reply, len(reply),
                         ICMP_TIMEOUT_MS)
        cnt.add_sent()
    paced(rate, deadline, one)
    iph.IcmpCloseHandle(ctypes.c_void_p(handle))


def arp_flood(args, hosts, first, deadline, cnt):
    """SendARP for unused subnet addresses (blocking per call); cnt counts the calls made."""
    iph = iphlpapi()
    iph.SendARP.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p]
    src = int.from_bytes(socket.inet_aton(args.bind), "little")
    mac = ctypes.create_string_buffer(8)
    mlen = ctypes.c_ulong(6)
    i = first
    while time.perf_counter() < deadline:
        h = hosts[i % len(hosts)]
        i += args.arp_threads
        mlen.value = 6
        iph.SendARP(int.from_bytes(socket.inet_aton(h), "little"), src, mac, ctypes.byref(mlen))
        cnt.add_sent()


def tcp_echo(board, bind, port, chunk, deadline, cnt):
    """One TCP echo connection exchanging chunk-byte blocks, each echoed block compared byte for byte."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if bind:
            s.bind((bind, 0))
        s.settimeout(TCP_IO_TIMEOUT_S)
        s.connect((board, port))
    except OSError as e:
        print(f"eth_flood: TCP connect failed: {e}")
        cnt.tcp_error()
        return
    seq = 0
    try:
        while time.perf_counter() < deadline:
            block = bytes(((seq * 17 + i * 31) & 0xFF) for i in range(chunk))
            t0 = time.perf_counter()
            s.sendall(block)
            got = bytearray()
            while len(got) < len(block):
                part = s.recv(len(block) - len(got))
                if not part:
                    raise OSError("connection closed by the board")
                got += part
            rtt = time.perf_counter() - t0
            if bytes(got) != block:
                raise OSError(f"echo mismatch in round {seq}")
            cnt.tcp_ok(len(block), rtt)
            seq += 1
    except OSError as e:
        print(f"eth_flood: TCP error: {e}")
        cnt.tcp_error()
    finally:
        s.close()


def run_flood(args, cnt):
    """Start the sender threads of args.kind (and the TCP echo) and wait for them."""
    deadline = time.perf_counter() + args.seconds
    threads = []

    def start(name, fn, *a):
        t = threading.Thread(target=fn, args=a, name=name, daemon=True)
        t.start()
        threads.append(t)

    if not args.no_tcp:
        start("tcp echo", tcp_echo, args.board, args.bind, args.echo_port, args.chunk, deadline, cnt)
    k = args.kind
    if k == "udp-closed":
        start(k, udp_flood, args.bind, args.board, 9, args.rate, deadline, cnt)
    elif k == "udp-echo":
        start(k, udp_flood, args.bind, args.board, 7, args.rate, deadline, cnt)
    elif k == "udp-bcast-lim":
        start(k, udp_flood, args.bind, "255.255.255.255", 9, args.rate, deadline, cnt, True)
    elif k == "udp-bcast-net":
        start(k, udp_flood, args.bind, args.bcast, 9, args.rate, deadline, cnt, True)
    elif k == "mcast":
        start(k, udp_flood, args.bind, MCAST_GROUP, 9, args.rate, deadline, cnt, False, True)
    elif k in ("icmp-board", "icmp-bcast"):
        dest = args.board if k == "icmp-board" else args.bcast
        for n in range(args.icmp_threads):
            start(f"{k} {n}", icmp_flood, dest, args.rate / args.icmp_threads, deadline, cnt)
    elif k == "arp":
        net = ipaddress.ip_network(f"{args.net}/{args.prefix}", strict=False)
        skip = {args.board, args.bind}
        hosts = [str(h) for h in net.hosts() if str(h) not in skip][:4094]
        for n in range(args.arp_threads):
            start(f"arp {n}", arp_flood, args, hosts, n, deadline, cnt)
    for t in threads:
        t.join(args.seconds + TCP_IO_TIMEOUT_S + 8.0)


def selftest():
    """Loopback: the UDP sender against a local listener, and the TCP echo client against a local echo server."""
    ok = True
    lis = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    lis.bind(("127.0.0.1", 0))
    lis.settimeout(0.2)
    port = lis.getsockname()[1]
    got = [0]
    stop = threading.Event()

    def listen():
        while not stop.is_set():
            try:
                lis.recvfrom(2048)
                got[0] += 1
            except socket.timeout:
                pass
            except OSError:
                return
    lt = threading.Thread(target=listen, daemon=True)
    lt.start()
    cnt = Counters()
    udp_flood("127.0.0.1", "127.0.0.1", port, 500.0, time.perf_counter() + 1.0, cnt)
    time.sleep(0.4)
    stop.set()
    lt.join(1.0)
    lis.close()
    print(f"selftest: UDP sent {cnt.sent}, listener received {got[0]}")
    if cnt.sent < 300 or got[0] < cnt.sent * 0.9:
        ok = False
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    tport = srv.getsockname()[1]

    def echo():
        c, _ = srv.accept()
        c.settimeout(2.0)
        try:
            while True:
                d = c.recv(4096)
                if not d:
                    break
                c.sendall(d)
        except OSError:
            pass
        c.close()
    et = threading.Thread(target=echo, daemon=True)
    et.start()
    cnt2 = Counters()
    tcp_echo("127.0.0.1", "127.0.0.1", tport, 1460, time.perf_counter() + 0.5, cnt2)
    srv.close()
    print(f"selftest: TCP echo rounds {cnt2.tcp_rounds}, bytes {cnt2.tcp_bytes}, errors {cnt2.tcp_errors}")
    if cnt2.tcp_rounds < 1 or cnt2.tcp_errors != 0:
        ok = False
    print("ETH_FLOOD_SELFTEST: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv):
    ap = argparse.ArgumentParser(description="Load generator of the protection profile test (normal sockets only)")
    ap.add_argument("board", nargs="?", default="")
    ap.add_argument("--bind", default="")
    ap.add_argument("--net", default="")
    ap.add_argument("--prefix", type=int, default=24)
    ap.add_argument("--bcast", default="")
    ap.add_argument("--kind", choices=KINDS)
    ap.add_argument("--rate", type=float, default=1000.0, help="frames per second (arp: see --arp-threads)")
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--no-tcp", dest="no_tcp", action="store_true")
    ap.add_argument("--echo-port", dest="echo_port", type=int, default=7)
    ap.add_argument("--chunk", type=int, default=1460)
    ap.add_argument("--icmp-threads", dest="icmp_threads", type=int, default=4)
    ap.add_argument("--arp-threads", dest="arp_threads", type=int, default=32)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    need = [args.board, args.bind, args.kind]
    if args.kind in ("udp-bcast-net", "icmp-bcast"):
        need.append(args.bcast)
    if args.kind == "arp":
        need.append(args.net)
    if not all(need) or args.seconds <= 0 or args.rate <= 0 or args.chunk <= 0 or args.icmp_threads < 1 or \
            args.arp_threads < 1 or args.prefix < 8 or args.prefix > 30:
        print("ETH_FLOOD: FAIL bad arguments")
        return 2
    cnt = Counters()
    t0 = time.perf_counter()
    try:
        run_flood(args, cnt)
    except OSError as e:
        print(f"ETH_FLOOD: FAIL {e}")
        return 1
    wall = time.perf_counter() - t0
    print(f"ETH_FLOOD: DONE kind={args.kind} sent={cnt.sent} seconds={wall:.1f} tcp_errors={cnt.tcp_errors} "
          f"tcp_bytes={cnt.tcp_bytes} tcp_max_rtt_ms={cnt.tcp_max_rtt * 1000.0:.1f} tcp_rounds={cnt.tcp_rounds}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
