#!/usr/bin/env python3
"""
File: hp_board_table.py
Purpose: summarise stream_test.ps1 run logs (boards/nexys_video/build/<prefix>_run.txt) into the rows of the three-way table
  (Constrained Baseline CAVLC, High CABAC 4x4, High CABAC 8x8) of rtlnet_nexys_video.md section 6.19.
Usage: python hp_board_table.py <run.txt> [<run.txt> ...]
  One line per run and mode: file, mode, pictures sent, dropped, ES kb/s (ES bytes of show stream over the pictures at 30 per s), PSNR minimum
  and mean, clocks per macroblock of both engines and the encode time per picture (the larger engine, 90 MHz), the ffprobe profile, the JM
  result, the number of failing gates and the STREAM_TEST line.
Revision: 11-12-2026
  * 11-12-2026: initial version.
"""
import re
import sys


def num(rx, text, cast=float, default=None):
    m = re.search(rx, text)
    return cast(m.group(1)) if m else default


def blocks(text):
    parts = re.split(r'^--- mode (\S+)\s*$', text, flags=re.M)
    out = []
    for i in range(1, len(parts), 2):
        out.append((parts[i], parts[i + 1]))
    return out


def main():
    print("file | mode | pics | dropped | ES kb/s | PSNR min / mean | clk/MB e0 / e1 | ms per picture (cycles / clk x MB) | profile | JM | mux load % | backlog max / skipped | failing gates | verdict")
    for path in sys.argv[1:]:
        text = open(path, encoding='utf-8', errors='replace').read()
        verdict = (re.findall(r'^STREAM_TEST: .*$', text, flags=re.M) or ['no STREAM_TEST line'])[-1]
        for mode, b in blocks(text):
            pics = num(r'Pictures\s+: (\d+) sent', b, int, 0)
            drop = num(r'sent, (\d+) dropped', b, int, -1)
            es = num(r'Bytes\s+: (\d+) ES', b, int, 0)
            kbps = es * 8.0 / 1000.0 / (pics / 30.0) if pics else 0.0
            pmin = num(r'PSNR_STAT min=([\d.]+)', b)
            pmean = num(r'PSNR_STAT min=[\d.]+ mean=([\d.]+)', b)
            if pmin is None:   # the bars have no PSNR_STAT line, only the minimum of the check
                pmin = num(r'CHECK psnr PASS .*?minimum ([\d.]+) dB', b)
            eng = re.findall(r'Engine (\d)\s+: (\d+) macroblocks, picture (\d+) cycles \((\d+) per macroblock\)', b)
            clk = [int(e[3]) for e in eng]
            ms = max(int(e[2]) for e in eng) / 90000.0 if eng else 0.0   # the picture's cycles of the slower engine at 90 MHz
            mbpic = (4080 if mode.startswith('1080') else 1800)
            ms_mb = max(clk) * mbpic / 90000.0 if clk else 0.0           # clocks per macroblock x macroblocks per engine (the 6.18 figure)
            prof = (re.findall(r'probe: stream, size, rate\s+\d+ stream\(s\), h264 (.*?) \d+x\d+', b) or ['?'])[0]
            jm = (re.findall(r'jm: ldecod decode\s+(.*)$', b, flags=re.M) or ['not run'])[0]
            jm = 'ok' if re.search(r'exit 0, (\d+) frames decoded of \1 access units', jm) else jm
            if 'identical to FFmpeg' in b or 'compared' in b and 'not compared' not in b:
                jm += ' (compared)'
            mux = num(r'TS mux (\d+\.\d) %', b)
            blog = (re.findall(r'Mux backlog\s+: \d+ queued now, max (\d+) \(limit \d+\); (\d+) frames skipped', b) or [('?', '?')])[0]
            fails = len(re.findall(r'^  FAIL ', b, flags=re.M))
            print("%s | %s | %d | %d | %.0f | %s / %s | %s | %.1f / %.1f | %s | %s | %.1f | %s / %s | %d | %s" % (
                path.replace('\\', '/').split('/')[-1], mode, pics, drop, kbps,
                '-' if pmin is None else '%.2f' % pmin, '-' if pmean is None else '%.2f' % pmean,
                ' / '.join(str(c) for c in clk), ms, ms_mb, prof, jm, mux if mux is not None else -1, blog[0], blog[1], fails, verdict))


if __name__ == '__main__':
    main()
