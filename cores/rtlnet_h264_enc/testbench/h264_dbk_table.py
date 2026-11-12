#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File: h264_dbk_table.py
# Purpose: the filter on / off tables of documentation section 19.4 from the harness output of the d_* configurations (h264_harness.ps1 -Tag on and
#   -DbkCtl 0 -Tag off): per configuration the PSNR (overall, mean of the pictures; pictures 1.. are the P pictures) and the bits per picture with the
#   filter on and off, and the clocks per macroblock.
# Usage: h264_dbk_table.py <harness log> [<harness log> ...]
# Language: Python 3. Revision: 11-12-2026
# -----------------------------------------------------------------------------
import re
import sys
from collections import defaultdict

rows = defaultdict(dict)
for path in sys.argv[1:]:
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\[(d_\S+?)_(on|off)\] (.*)", line.strip())
        if not m:
            continue
        cfg, mode, rest = m.group(1), m.group(2), m.group(3)
        d = rows[cfg].setdefault(mode, {"psnr": {}, "bits": {}, "cpm": {}})
        p = re.match(r"PSNR pic(\d+) Y ([\d.]+) Cb ([\d.]+) Cr ([\d.]+) all ([\d.]+)", rest)
        if p:
            d["psnr"][int(p.group(1))] = float(p.group(5))
        b = re.match(r"BITS pic(\d+) (\d+)", rest)
        if b:
            d["bits"][int(b.group(1))] = int(b.group(2))
        c = re.match(r"CLK_PER_MB ([IP]) pictures x engines \d+: min (\d+) mean (\d+) max (\d+)", rest)
        if c:
            d["cpm"][c.group(1)] = int(c.group(3))

print("| configuration | PSNR on / off (dB, pictures 1..2) | bits on / off (P pictures) | bits change | clocks per macroblock on / off (I, P) |")
print("|---|---|---|---|---|")
tp_on = tp_off = tb_on = tb_off = 0
for cfg in sorted(rows):
    r = rows[cfg]
    if "on" not in r or "off" not in r:
        continue
    on, off = r["on"], r["off"]
    ps_on = [on["psnr"][i] for i in sorted(on["psnr"]) if i >= 1]
    ps_off = [off["psnr"][i] for i in sorted(off["psnr"]) if i >= 1]
    b_on = sum(on["bits"][i] for i in on["bits"] if i >= 1)
    b_off = sum(off["bits"][i] for i in off["bits"] if i >= 1)
    if not ps_on or not ps_off:
        continue
    mo, mf = sum(ps_on) / len(ps_on), sum(ps_off) / len(ps_off)
    print("| %s | %.2f / %.2f (%+.2f) | %d / %d | %+.1f %% | I %s / %s, P %s / %s |" % (
        cfg, mo, mf, mo - mf, b_on, b_off, 100.0 * (b_on - b_off) / b_off if b_off else 0.0,
        on["cpm"].get("I", "-"), off["cpm"].get("I", "-"), on["cpm"].get("P", "-"), off["cpm"].get("P", "-")))
