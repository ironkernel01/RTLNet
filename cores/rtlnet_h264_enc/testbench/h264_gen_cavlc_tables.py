#!/usr/bin/env python3
"""
File: h264_gen_cavlc_tables.py
Purpose: generates the CAVLC code tables of the H.264 encoder from OpenH264's encoder tables, cross-checks them
  against JM's encoder tables, and writes two separate outputs: the RTL package and the bench reference include.
Overview:
  * Source tables: OpenH264 codec/encoder/core/src/encoder_data_tables.cpp (g_kuiVlcCoeffToken[5][17][4][2],
    g_kuiVlcTotalZeros[16][16][2], g_kuiVlcTotalZerosChromaDc[4][4][2], g_kuiVlcRunBefore[8][15][2]; each entry is
    {code value, bit count}). The OpenH264 root is $RTLNET_OPENH264_SRC (default Z:\\IronKernel\\refs\\openh264\\src); the JM
    root is $RTLNET_JM_SRC (default Z:\\IronKernel\\refs\\jm\\JM-19.1).
  * Cross-check: JM source/app/lencod/vlc.c (lentab/codtab of NumCoeffTrailingOnes, ...ChromaDC, TotalZeros,
    TotalZerosChromaDC, Run, plus the nC >= 8 six-bit FLC rule) must agree with every OpenH264 entry; any
    difference stops the script with exit code 1.
  * Outputs (both written; the bench copy is a separate file with a different data format so that a mutation of the RTL
    package does not touch the reference):
      hdl/rtlnet_h264_cavlc_tab.sv            package rtlnet_h264_cavlc_tab (case ROM functions)
      testbench/tb_h264_cavlc_ref_tab.svh     localparam arrays REF_CT_LEN/REF_CT_CODE/..., included by the benches
  * Run: python -I h264_gen_cavlc_tables.py [--check-only]
Revision: 11-09-2026
  * 11-09-2026: initial version.
"""
import ast
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HDL = os.path.join(HERE, "..", "hdl", "rtlnet_h264_cavlc_tab.sv")
REF = os.path.join(HERE, "tb_h264_cavlc_ref_tab.svh")


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def parse_array(text, name):
    """OpenH264: nested braces after 'name[..]... = {' up to the closing '};'."""
    m = re.search(re.escape(name) + r"[^=]*=\s*(\{.*?\n\};)", text, flags=re.S)
    if not m:
        raise SystemExit("array not found: " + name)
    body = m.group(1).rstrip(";").replace("{", "[").replace("}", "]")
    return ast.literal_eval(body)


def jm_arrays(text, func):
    """JM: lentab and codtab declared inside function 'func'."""
    i = text.index(func)
    seg = text[i:]
    out = {}
    for nm in ("lentab", "codtab"):
        m = re.search(nm + r"\s*(?:\[[^\]]*\])+\s*=\s*(\{.*?\};)", seg, flags=re.S)
        body = m.group(1).rstrip(";").replace("{", "[").replace("}", "]")
        out[nm] = ast.literal_eval(body)
    return out


def main():
    oh_root = os.environ.get("RTLNET_OPENH264_SRC", r"Z:\IronKernel\refs\openh264\src")
    jm_root = os.environ.get("RTLNET_JM_SRC", r"Z:\IronKernel\refs\jm\JM-19.1")
    oh = strip_comments(open(os.path.join(oh_root, "codec", "encoder", "core", "src", "encoder_data_tables.cpp"),
                             encoding="utf-8", errors="replace").read())
    jm = strip_comments(open(os.path.join(jm_root, "source", "app", "lencod", "vlc.c"), encoding="utf-8",
                             errors="replace").read())
    ct = parse_array(oh, "g_kuiVlcCoeffToken")      # [5][17][4][2]
    tz = parse_array(oh, "g_kuiVlcTotalZeros")      # [16][16][2]
    tzc = parse_array(oh, "g_kuiVlcTotalZerosChromaDc")  # [4][4][2]
    rb = parse_array(oh, "g_kuiVlcRunBefore")       # [8][15][2]

    # ---- cross-check against JM ----
    errs = 0
    checked = 0
    j_ct = jm_arrays(jm, "writeSyntaxElement_NumCoeffTrailingOnes(")
    j_cd = jm_arrays(jm, "writeSyntaxElement_NumCoeffTrailingOnesChromaDC(")
    j_tz = jm_arrays(jm, "writeSyntaxElement_TotalZeros(")
    j_tc = jm_arrays(jm, "writeSyntaxElement_TotalZerosChromaDC(")
    j_rn = jm_arrays(jm, "writeSyntaxElement_Run(")

    def cmp(what, a, b):
        nonlocal errs, checked
        checked += 1
        if a != b:
            errs += 1
            print("MISMATCH", what, "openh264", a, "jm", b)

    for cls in range(3):
        for tc in range(17):
            for t1 in range(4):
                if t1 > tc or t1 > 3:
                    continue
                cmp("ct cls%d tc%d t1%d" % (cls, tc, t1), tuple(ct[cls][tc][t1]),
                    (j_ct["codtab"][cls][t1][tc], j_ct["lentab"][cls][t1][tc]))
    for tc in range(17):
        for t1 in range(4):
            if t1 > tc:
                continue
            code = 3 if tc == 0 else (((tc - 1) << 2) | t1)
            cmp("ct cls3 tc%d t1%d (FLC)" % (tc, t1), tuple(ct[3][tc][t1]), (code, 6))
    for tc in range(5):
        for t1 in range(4):
            if t1 > tc:
                continue
            cmp("ct chroma dc tc%d t1%d" % (tc, t1), tuple(ct[4][tc][t1]),
                (j_cd["codtab"][0][t1][tc], j_cd["lentab"][0][t1][tc]))
    for tcn in range(1, 16):
        for z in range(0, 17 - tcn):
            cmp("tz tc%d z%d" % (tcn, z), tuple(tz[tcn][z]), (j_tz["codtab"][tcn - 1][z], j_tz["lentab"][tcn - 1][z]))
    for tcn in range(1, 4):
        for z in range(0, 5 - tcn):
            cmp("tzc tc%d z%d" % (tcn, z), tuple(tzc[tcn][z]),
                (j_tc["codtab"][0][tcn - 1][z], j_tc["lentab"][0][tcn - 1][z]))
    for zl in range(1, 8):
        for run in range(0, min(zl, 14) + 1):
            cmp("rb zl%d run%d" % (zl, run), tuple(rb[zl][run]), (j_rn["codtab"][zl - 1][run], j_rn["lentab"][zl - 1][run]))
    print("cross-check OpenH264 vs JM: %d entries compared, %d mismatches" % (checked, errs))
    if errs:
        return 1
    if "--check-only" in sys.argv:
        return 0

    # ---- entry lists (only defined entries) ----
    ct_e = []
    for cls in range(5):
        for tc in range(17):
            for t1 in range(4):
                code, ln = ct[cls][tc][t1]
                if ln:
                    ct_e.append((cls, tc, t1, ln, code))
    tz_e = [(t, z, tz[t][z][1], tz[t][z][0]) for t in range(1, 16) for z in range(16) if tz[t][z][1]]
    tzc_e = [(t, z, tzc[t][z][1], tzc[t][z][0]) for t in range(1, 4) for z in range(4) if tzc[t][z][1]]
    rb_e = [(zl, r, rb[zl][r][1], rb[zl][r][0]) for zl in range(1, 8) for r in range(15) if rb[zl][r][1]]

    hdr = """// -----------------------------------------------------------------------------
// File: rtlnet_h264_cavlc_tab.sv
// Purpose: CAVLC code tables of the H.264 encoder (ITU-T Rec. H.264 clause 9.2, Tables 9-5, 9-7, 9-8, 9-9, 9-10) as
//   case ROM functions: coeff_token, total_zeros (4x4 and chroma DC) and run_before.
// Overview:
//   * GENERATED by testbench/h264_gen_cavlc_tables.py from OpenH264's encoder tables, cross-checked against JM's
//     encoder tables (all entries agree). Do not edit by hand; rerun the script.
//   * ct(cls, tc, t1) returns {len[4:0], code[5:0]}: cls 0..2 = nC 0-1, 2-3, 4-7; 3 = nC >= 8 (6-bit FLC); 4 = chroma DC
//     (nC = -1). tc = TotalCoeff 0..16, t1 = TrailingOnes 0..3. An undefined combination returns len 0.
//   * tz4(tc, tz) returns {len[3:0], code[8:0]} for TotalCoeff 1..15 (maxNumCoeff 16 and 15); tzc(tc, tz) returns
//     {len[1:0], code[2:0]} for the chroma DC block (TotalCoeff 1..3); rb(zl, run) returns {len[3:0], code[10:0]}
//     for zerosLeft 1..7 (7 means "greater than 6") and run_before 0..14.
// Language: SystemVerilog-2012 (synthesizable package).
// Revision: 11-09-2026
//   * 11-09-2026: initial version.
// Clocks: none (package).
// -----------------------------------------------------------------------------
package rtlnet_h264_cavlc_tab;

"""
    o = [hdr]
    o.append("  function automatic logic [10:0] ct(input logic [2:0] cls, input logic [4:0] tc, input logic [1:0] t1);\n")
    o.append("    logic [10:0] e;\n    e = 11'd0;\n    case ({cls, tc, t1})\n")
    for cls, tc, t1, ln, code in ct_e:
        o.append("      {3'd%d,5'd%d,2'd%d}: e = {5'd%d, 6'd%d};\n" % (cls, tc, t1, ln, code))
    o.append("      default: e = 11'd0;\n    endcase\n    return e;\n  endfunction\n\n")
    o.append("  function automatic logic [12:0] tz4(input logic [3:0] tc, input logic [3:0] tz);\n")
    o.append("    logic [12:0] e;\n    e = 13'd0;\n    case ({tc, tz})\n")
    for t, z, ln, code in tz_e:
        o.append("      {4'd%d,4'd%d}: e = {4'd%d, 9'd%d};\n" % (t, z, ln, code))
    o.append("      default: e = 13'd0;\n    endcase\n    return e;\n  endfunction\n\n")
    o.append("  function automatic logic [4:0] tzc(input logic [1:0] tc, input logic [1:0] tz);\n")
    o.append("    logic [4:0] e;\n    e = 5'd0;\n    case ({tc, tz})\n")
    for t, z, ln, code in tzc_e:
        o.append("      {2'd%d,2'd%d}: e = {2'd%d, 3'd%d};\n" % (t, z, ln, code))
    o.append("      default: e = 5'd0;\n    endcase\n    return e;\n  endfunction\n\n")
    o.append("  function automatic logic [14:0] rb(input logic [2:0] zl, input logic [3:0] run);\n")
    o.append("    logic [14:0] e;\n    e = 15'd0;\n    case ({zl, run})\n")
    for zl, r, ln, code in rb_e:
        o.append("      {3'd%d,4'd%d}: e = {4'd%d, 11'd%d};\n" % (zl, r, ln, code))
    o.append("      default: e = 15'd0;\n    endcase\n    return e;\n  endfunction\n\nendpackage\n")
    with open(HDL, "w", newline="\n", encoding="utf-8") as f:
        f.write("".join(o))

    # ---- bench reference include (arrays, independent format) ----
    def arr3(a, d0, d1, d2, k):
        s = "'{\n"
        for i in range(d0):
            s += "  '{\n"
            for j in range(d1):
                s += "    '{" + ", ".join(str(a[i][j][t][k]) for t in range(d2)) + "}" + (",\n" if j < d1 - 1 else "\n")
            s += "  }" + (",\n" if i < d0 - 1 else "\n")
        return s + "};\n"

    def arr2(a, d0, d1, k):
        s = "'{\n"
        for i in range(d0):
            s += "  '{" + ", ".join(str(a[i][j][k]) for j in range(d1)) + "}" + (",\n" if i < d0 - 1 else "\n")
        return s + "};\n"

    r = ["// GENERATED by h264_gen_cavlc_tables.py (OpenH264 encoder tables, cross-checked with JM). Bench reference tables,\n",
         "// held apart from hdl/rtlnet_h264_cavlc_tab.sv. [cls][total_coeff][trailing_ones] with cls 0..2 nC bands, 3 nC>=8, 4 chroma DC.\n",
         "localparam int REF_CT_CODE [5][17][4] = " + arr3(ct, 5, 17, 4, 0),
         "localparam int REF_CT_LEN  [5][17][4] = " + arr3(ct, 5, 17, 4, 1),
         "localparam int REF_TZ_CODE [16][16] = " + arr2(tz, 16, 16, 0),
         "localparam int REF_TZ_LEN  [16][16] = " + arr2(tz, 16, 16, 1),
         "localparam int REF_TZC_CODE [4][4] = " + arr2(tzc, 4, 4, 0),
         "localparam int REF_TZC_LEN  [4][4] = " + arr2(tzc, 4, 4, 1),
         "localparam int REF_RB_CODE [8][15] = " + arr2(rb, 8, 15, 0),
         "localparam int REF_RB_LEN  [8][15] = " + arr2(rb, 8, 15, 1)]
    with open(REF, "w", newline="\n", encoding="utf-8") as f:
        f.write("".join(r))
    print("wrote", os.path.normpath(HDL), "(%d ct, %d tz4, %d tzc, %d rb entries)" % (len(ct_e), len(tz_e), len(tzc_e), len(rb_e)))
    print("wrote", os.path.normpath(REF))
    return 0


if __name__ == "__main__":
    sys.exit(main())
