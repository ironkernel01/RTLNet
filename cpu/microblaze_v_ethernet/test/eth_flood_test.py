#!/usr/bin/env python3
"""
eth_flood_test.py -- host load generator of the Ethernet demo's protection profile test

Copyright (C) 2026 IronKernel. All rights reserved.

Role: bound to the PC adapter's address (--bind), it loads the CPU network path of the board with the traffic classes
  the classifier's protection profile limits while one TCP echo connection to the lwIP echo server keeps exchanging data:
  * UDP broadcast datagrams to the subnet broadcast address (class "udp" of the profile: UDP the hardware did not claim);
  * UDP multicast datagrams (the board's ingress filter discards them: they never reach the CPU path, the board counts
    them as filtered);
  * ARP load: UDP datagrams to unused addresses of the subnet, so the PC's IP stack broadcasts an ARP request for each
    (class "arp");
  * ICMP load through the Windows ICMP API (IcmpSendEcho, no administrator rights): echo requests to the subnet
    broadcast address (not answered by the hardware responder, they reach the CPU path: class "icmp") and echo requests
    to the board itself (answered by the hardware responder).
  Limitation: only what ordinary sockets and the Windows ICMP API can send. Raw Ethernet frames (a broadcast frame
  that is not ARP, ICMP or UDP, unicast ARP replies, ICMP types other than echo) need Npcap or Scapy, which this
  test does not use; the "broadcast" class therefore sees none of this traffic (UDP broadcast counts in "udp").
  Python 3 standard library only.

Usage:
  python eth_flood_test.py <board ip> --bind <pc ip> --net <subnet address> --prefix <bits> --bcast <subnet broadcast>
         [--seconds 20] [--bcast-rate 2000] [--mcast-rate 500] [--arp-rate 200] [--icmp-rate 300]
         [--echo-port 7] [--chunk 1460]

Output: progress lines, then one anchored line
  ETH_FLOOD: DONE tcp_errors=<n> tcp_bytes=<n> tcp_max_rtt_ms=<ms> tcp_rounds=<n> sent_udp_bcast=<n> sent_mcast=<n>
                  sent_arp_dst=<n> sent_icmp_bcast=<n> sent_icmp_board=<n>
  or ETH_FLOOD: FAIL <reason>.
Exit status: 0 DONE, 1 FAIL, 2 bad arguments.
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


class Counters:
    """Thread-safe counters of what each generator sent."""

    def __init__(self):
        self.lock = threading.Lock()
        self.v = {"udp_bcast": 0, "mcast": 0, "arp_dst": 0, "icmp_bcast": 0, "icmp_board": 0,
                  "tcp_errors": 0, "tcp_bytes": 0, "tcp_rounds": 0}
        self.tcp_max_rtt = 0.0

    def add(self, key, n=1):
        with self.lock:
            self.v[key] += n

    def rtt(self, seconds):
        with self.lock:
            if seconds > self.tcp_max_rtt:
                self.tcp_max_rtt = seconds


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


def udp_bcast(args, deadline, cnt):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind((args.bind, 0))
    data = bytes(range(64))

    def one():
        try:
            s.sendto(data, (args.bcast, 9))
            cnt.add("udp_bcast")
        except OSError:
            pass
    paced(args.bcast_rate, deadline, one)
    s.close()


def udp_mcast(args, deadline, cnt):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(args.bind))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    data = bytes(range(64))

    def one():
        try:
            s.sendto(data, ("239.255.42.42", 9))
            cnt.add("mcast")
        except OSError:
            pass
    paced(args.mcast_rate, deadline, one)
    s.close()


def arp_load(args, deadline, cnt):
    """UDP to the unused addresses of the subnet: the PC broadcasts an ARP request for each unresolved one."""
    net = ipaddress.ip_network(f"{args.net}/{args.prefix}", strict=False)
    skip = {str(ipaddress.ip_address(args.board)), args.bind}
    hosts = [str(h) for h in net.hosts() if str(h) not in skip][:4094]
    if not hosts:
        return
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((args.bind, 0))
    idx = [0]

    def one():
        h = hosts[idx[0] % len(hosts)]
        idx[0] += 1
        try:
            s.sendto(b"x", (h, 9))
            cnt.add("arp_dst")
        except OSError:
            pass
    paced(args.arp_rate, deadline, one)
    s.close()


def icmp_load(args, deadline, cnt, dest, key, rate):
    """Echo requests through iphlpapi IcmpSendEcho (one worker per destination)."""
    if os.name != "nt":
        return
    iph = ctypes.WinDLL("iphlpapi")
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
        cnt.add(key)
    paced(rate, deadline, one)
    iph.IcmpCloseHandle(ctypes.c_void_p(handle))


def tcp_echo(args, deadline, cnt):
    """One TCP echo connection exchanging --chunk byte blocks, each echoed block compared byte for byte."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind((args.bind, 0))
        s.settimeout(TCP_IO_TIMEOUT_S)
        s.connect((args.board, args.echo_port))
    except OSError as e:
        print(f"eth_flood: TCP connect failed: {e}")
        cnt.add("tcp_errors")
        return
    seq = 0
    try:
        while time.perf_counter() < deadline:
            block = bytes(((seq * 17 + i * 31) & 0xFF) for i in range(args.chunk))
            t0 = time.perf_counter()
            s.sendall(block)
            got = bytearray()
            while len(got) < len(block):
                part = s.recv(len(block) - len(got))
                if not part:
                    raise OSError("connection closed by the board")
                got += part
            cnt.rtt(time.perf_counter() - t0)
            if bytes(got) != block:
                raise OSError(f"echo mismatch in round {seq}")
            cnt.add("tcp_bytes", len(block))
            cnt.add("tcp_rounds")
            seq += 1
    except OSError as e:
        print(f"eth_flood: TCP error: {e}")
        cnt.add("tcp_errors")
    finally:
        s.close()


def main(argv):
    ap = argparse.ArgumentParser(description="Load generator of the protection profile test")
    ap.add_argument("board")
    ap.add_argument("--bind", required=True)
    ap.add_argument("--net", required=True, help="subnet address, e.g. 192.169.1.0")
    ap.add_argument("--prefix", type=int, required=True)
    ap.add_argument("--bcast", required=True, help="subnet broadcast address")
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--bcast-rate", dest="bcast_rate", type=float, default=2000.0)
    ap.add_argument("--mcast-rate", dest="mcast_rate", type=float, default=500.0)
    ap.add_argument("--arp-rate", dest="arp_rate", type=float, default=200.0)
    ap.add_argument("--icmp-rate", dest="icmp_rate", type=float, default=300.0)
    ap.add_argument("--echo-port", dest="echo_port", type=int, default=7)
    ap.add_argument("--chunk", type=int, default=1460)
    args = ap.parse_args(argv)
    if args.seconds <= 0 or args.chunk <= 0 or args.prefix < 8 or args.prefix > 30:
        print("ETH_FLOOD: FAIL bad arguments")
        return 2
    cnt = Counters()
    deadline = time.perf_counter() + args.seconds
    workers = [
        ("tcp echo", tcp_echo, (args, deadline, cnt)),
        ("udp broadcast", udp_bcast, (args, deadline, cnt)),
        ("udp multicast", udp_mcast, (args, deadline, cnt)),
        ("arp load", arp_load, (args, deadline, cnt)),
        ("icmp to broadcast", icmp_load, (args, deadline, cnt, args.bcast, "icmp_bcast", args.icmp_rate)),
        ("icmp to board", icmp_load, (args, deadline, cnt, args.board, "icmp_board", args.icmp_rate / 3.0)),
    ]
    threads = []
    for name, fn, a in workers:
        t = threading.Thread(target=fn, args=a, name=name, daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join(args.seconds + TCP_IO_TIMEOUT_S + 5.0)
    v = cnt.v
    print(f"ETH_FLOOD: DONE tcp_errors={v['tcp_errors']} tcp_bytes={v['tcp_bytes']} "
          f"tcp_max_rtt_ms={cnt.tcp_max_rtt * 1000.0:.1f} tcp_rounds={v['tcp_rounds']} "
          f"sent_udp_bcast={v['udp_bcast']} sent_mcast={v['mcast']} sent_arp_dst={v['arp_dst']} "
          f"sent_icmp_bcast={v['icmp_bcast']} sent_icmp_board={v['icmp_board']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
