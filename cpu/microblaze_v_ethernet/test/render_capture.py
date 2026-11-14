#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File: render_capture.py
# Purpose: render a text transcript (console session, ping, iperf, test output) as an SVG "screen capture": monospace
#   text on a dark terminal-style background with a title bar that names the capture. Python standard library only.
# Overview:
#   * Input: a UTF-8 text file. Output: <name>.svg; with --png the SVG is also converted to PNG by a tool that is
#     already installed (Microsoft Edge or Chrome in headless mode, else LibreOffice soffice, else Inkscape or
#     ImageMagick); nothing is installed and the conversion is skipped with a message when none is found.
#   * --lines A:B renders lines A..B (1-based, inclusive; either end may be left out). --max-cols clips long lines.
#   * --redact replaces every IPv4 address by a documentation address (192.0.2.x, 198.51.100.x, 203.0.113.x, by
#     first appearance) and every MAC address by a documentation value (00:00:5E:00:53:xx), so a capture can be
#     published without a real address of the lab network.
#   * Tabs become eight-column stops; control characters other than newline are dropped; XML special characters are
#     escaped. Text colour is one light grey; prompt lines (a line starting with "rtlnet" and ending in # or >) are
#     drawn in green, lines that contain FAIL or ERROR in red and lines that contain PASS in green.
# Usage:
#   python -I render_capture.py <transcript.txt> [-o out.svg] [--title "name"] [--lines 3:40] [--redact]
#                               [--max-cols 110] [--png]
#   python -I render_capture.py --all <folder> --out-dir <folder> [--redact] [--png]   (every *.txt of a folder)
# Language: Python 3.
# Revision: 11-14-2026
#   * 11-14-2026: initial version.
# -----------------------------------------------------------------------------
import argparse
import os
import re
import shutil
import subprocess
import sys
from xml.sax.saxutils import escape

FONT_PX = 14
CHAR_W = 8.4          # advance of the monospace font at 14 px (Consolas / DejaVu Sans Mono ~ 0.6 em)
LINE_H = 19
PAD_X = 16
BAR_H = 34
PAD_BOTTOM = 14

IPV4 = re.compile(r'\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b')
MAC = re.compile(r'\b([0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5})\b')
DOC_NETS = ['192.0.2.', '198.51.100.', '203.0.113.']


class Redactor:
    """Stable mapping of real addresses to documentation addresses (same input, same output within one run)."""

    def __init__(self):
        self.ip = {}
        self.mac = {}

    def _ip(self, m):
        real = m.group(0)
        octets = [int(g) for g in m.groups()]
        if any(o > 255 for o in octets):
            return real                      # not an address (version numbers and similar)
        if real == '0.0.0.0' or real.startswith(('127.', '255.')):
            return real                      # unspecified, loopback, netmasks and the limited broadcast
        if real.startswith(tuple(DOC_NETS)):
            return real                      # already a documentation address
        if real not in self.ip:
            n = len(self.ip)
            net = DOC_NETS[(n // 250) % len(DOC_NETS)]
            self.ip[real] = '%s%d' % (net, 1 + (n % 250))
        return self.ip[real]

    def _mac(self, m):
        real = m.group(0).lower().replace('-', ':')
        if real == 'ff:ff:ff:ff:ff:ff':
            return m.group(0)
        if real not in self.mac:
            self.mac[real] = '00:00:5e:00:53:%02x' % (len(self.mac) + 1)
        return self.mac[real]

    def apply(self, line):
        return IPV4.sub(self._ip, MAC.sub(self._mac, line))


def line_class(text):
    s = text.strip()
    if re.search(r'\b(FAIL|FAILED|ERROR)\b', s):
        return 'bad'
    if re.search(r'\bPASS(ED)?\b', s):
        return 'good'
    if re.match(r'^rtlnet\S*[#>]', s):
        return 'prompt'
    return 'txt'


def clean(line, max_cols):
    line = line.rstrip('\r\n').expandtabs(8)
    line = ''.join(ch for ch in line if ch == '\t' or ord(ch) >= 32)
    if max_cols and len(line) > max_cols:
        line = line[:max_cols - 1] + '…'
    return line


def render(lines, title, width_cols):
    width = int(PAD_X * 2 + CHAR_W * max(width_cols, len(title) + 12, 40))
    height = BAR_H + PAD_X + LINE_H * max(len(lines), 1) + PAD_BOTTOM
    out = []
    out.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
               'font-family="Consolas, \'DejaVu Sans Mono\', \'Courier New\', monospace" font-size="%d">'
               % (width, height, width, height, FONT_PX))
    out.append('<defs><style>.t{fill:#d4d4d4;white-space:pre}.prompt{fill:#7ec699;white-space:pre}'
               '.good{fill:#7ec699;white-space:pre}.bad{fill:#f47067;white-space:pre}'
               '.title{fill:#b0b0b0;font-family:Segoe UI, Arial, sans-serif;font-size:13px}</style></defs>')
    out.append('<rect width="%d" height="%d" rx="8" fill="#1e1e1e"/>' % (width, height))
    out.append('<path d="M0 8a8 8 0 0 1 8-8h%da8 8 0 0 1 8 8v%dH0z" fill="#323233"/>' % (width - 16, BAR_H - 8))
    for i, col in enumerate(('#ff5f56', '#ffbd2e', '#27c93f')):
        out.append('<circle cx="%d" cy="%d" r="6" fill="%s"/>' % (PAD_X + 6 + i * 20, BAR_H // 2, col))
    out.append('<text class="title" x="%d" y="%d" text-anchor="middle">%s</text>' % (width // 2, BAR_H // 2 + 4, escape(title)))
    y = BAR_H + PAD_X + LINE_H - 5
    for text in lines:
        cls = {'txt': 't', 'prompt': 'prompt', 'good': 'good', 'bad': 'bad'}[line_class(text)]
        out.append('<text class="%s" x="%d" y="%d" xml:space="preserve">%s</text>' % (cls, PAD_X, y, escape(text)))
        y += LINE_H
    out.append('</svg>')
    return '\n'.join(out) + '\n', width, height


def find_png_tool():
    """First installed tool that converts SVG to PNG: (kind, path) or None."""
    candidates = []
    for var in ('ProgramFiles', 'ProgramFiles(x86)'):
        base = os.environ.get(var)
        if base:
            candidates.append(('browser', os.path.join(base, 'Microsoft', 'Edge', 'Application', 'msedge.exe')))
            candidates.append(('browser', os.path.join(base, 'Google', 'Chrome', 'Application', 'chrome.exe')))
            candidates.append(('soffice', os.path.join(base, 'LibreOffice', 'program', 'soffice.exe')))
    for kind, exe in (('inkscape', 'inkscape'), ('magick', 'magick'), ('soffice', 'soffice')):
        p = shutil.which(exe)
        if p:
            candidates.append((kind, p))
    for kind, p in candidates:
        if os.path.isfile(p):
            return kind, p
    return None


def to_png(svg_path, png_path, width, height):
    tool = find_png_tool()
    if tool is None:
        print('render_capture: no SVG to PNG converter found (Edge, Chrome, LibreOffice, Inkscape, ImageMagick); kept the SVG')
        return False
    kind, exe = tool
    if kind == 'browser':
        uri = 'file:///' + os.path.abspath(svg_path).replace('\\', '/')
        cmd = [exe, '--headless', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
               '--default-background-color=00000000', '--window-size=%d,%d' % (width, height),
               '--screenshot=' + os.path.abspath(png_path), uri]
    elif kind == 'inkscape':
        cmd = [exe, os.path.abspath(svg_path), '--export-type=png', '--export-filename=' + os.path.abspath(png_path)]
    elif kind == 'magick':
        cmd = [exe, '-background', 'none', os.path.abspath(svg_path), os.path.abspath(png_path)]
    else:  # soffice
        outdir = os.path.dirname(os.path.abspath(png_path))
        cmd = [exe, '--headless', '--convert-to', 'png', '--outdir', outdir, os.path.abspath(svg_path)]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    except (OSError, subprocess.SubprocessError) as exc:
        print('render_capture: %s failed: %s' % (kind, exc))
        return False
    ok = os.path.isfile(png_path) and os.path.getsize(png_path) > 0
    print('render_capture: PNG by %s: %s' % (kind, 'ok' if ok else 'no file written'))
    return ok


def parse_range(spec, n):
    if not spec:
        return 0, n
    a, _, b = spec.partition(':')
    lo = int(a) - 1 if a else 0
    hi = int(b) if b else n
    return max(lo, 0), min(hi, n)


def one(src, dst, title, lines_spec, redact, max_cols, png):
    with open(src, 'r', encoding='utf-8', errors='replace') as fh:
        raw = fh.read().splitlines()
    lo, hi = parse_range(lines_spec, len(raw))
    red = Redactor() if redact else None
    lines = []
    for ln in raw[lo:hi]:
        c = clean(ln, max_cols)
        lines.append(red.apply(c) if red else c)
    svg, w, h = render(lines, title, max((len(s) for s in lines), default=0))
    with open(dst, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(svg)
    print('render_capture: %s -> %s (%d lines)' % (src, dst, len(lines)))
    if png:
        to_png(dst, os.path.splitext(dst)[0] + '.png', w, h)


def main(argv):
    ap = argparse.ArgumentParser(description='Render a text transcript as an SVG terminal capture.')
    ap.add_argument('input', nargs='?', help='transcript text file')
    ap.add_argument('-o', '--output', help='output SVG (default: next to the input)')
    ap.add_argument('--title', help='title bar text (default: the file name)')
    ap.add_argument('--lines', help='line range A:B (1-based, inclusive)')
    ap.add_argument('--redact', action='store_true', help='IPv4 and MAC addresses to documentation values')
    ap.add_argument('--max-cols', type=int, default=120, help='clip lines longer than this (default 120)')
    ap.add_argument('--png', action='store_true', help='also convert to PNG with an installed tool')
    ap.add_argument('--all', metavar='FOLDER', help='render every *.txt transcript of a folder')
    ap.add_argument('--out-dir', help='output folder for --all')
    a = ap.parse_args(argv)
    if a.all:
        outdir = a.out_dir or a.all
        os.makedirs(outdir, exist_ok=True)
        for name in sorted(os.listdir(a.all)):
            if name.lower().endswith('.txt'):
                stem = os.path.splitext(name)[0]
                one(os.path.join(a.all, name), os.path.join(outdir, stem + '.svg'), stem, a.lines, a.redact, a.max_cols, a.png)
        return 0
    if not a.input:
        ap.error('an input file or --all is required')
    dst = a.output or os.path.splitext(a.input)[0] + '.svg'
    one(a.input, dst, a.title or os.path.splitext(os.path.basename(a.input))[0], a.lines, a.redact, a.max_cols, a.png)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
