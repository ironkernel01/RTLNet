#!/usr/bin/env python3
"""
make_summary.py -- combine results_10.csv, results_100.csv and results_1000.csv into results_summary.md

Copyright (C) 2026 IronKernel. All rights reserved.

Rows are the metrics of the hardware tests (test, metric), columns the link speeds 10, 100 and 1000 Mb/s; a speed that
has not been run shows "-". Usage: python make_summary.py <out dir>
"""
import csv
import os
import sys


def load(path):
    rows = {}
    if not os.path.isfile(path):
        return rows
    with open(path, newline="", encoding="ascii", errors="replace") as fh:
        for r in csv.DictReader(fh):
            rows[(r["test"], r["metric"])] = "%s %s %s" % (r["value"], r["unit"], "" if r["verdict"] == "PASS" else "(FAIL)")
    return rows


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    data = {s: load(os.path.join(out, "results_%d.csv" % s)) for s in (10, 100, 1000)}
    keys = []
    for s in (1000, 100, 10):
        for k in data[s]:
            if k not in keys:
                keys.append(k)
    lines = ["# Ethernet demo hardware test results", "", "| test | metric | 10 Mb/s | 100 Mb/s | 1000 Mb/s |", "|---|---|---|---|---|"]
    for k in keys:
        cells = [data[s].get(k, "-").strip().replace("|", "/") for s in (10, 100, 1000)]
        lines.append("| %s | %s | %s | %s | %s |" % (k[0], k[1], cells[0], cells[1], cells[2]))
    with open(os.path.join(out, "results_summary.md"), "w", encoding="ascii") as fh:
        fh.write("\n".join(lines) + "\n")
    print("results_summary.md: %d rows" % len(keys))


if __name__ == "__main__":
    main()
