<#
-------------------------------------------------------------------------------
File: h264_dbk_mutation.ps1
Purpose: negative controls of the deblocking filter bench: each mutation of rtlnet_h264_deblock.sv / rtlnet_h264_dbk_line.sv (a table entry, a boundary
  strength rule, a threshold, an edge selection, the strobe pattern of the delayed write) is applied to a copy of the RTL, the bench
  (h264_dbk_run.ps1 -Rtl <copy>) must FAIL; the real files are never touched.
Overview: prints `MUTANT n <name>: caught` or `MISSED`, then `TEST PASS: h264_dbk_mutation (<n> of <n> caught)`.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_dbk_mutation.ps1 [-Sets 20] [-Only 3,5]
Revision: 11-12-2026
-------------------------------------------------------------------------------
#>
param([int]$Sets = 20, [int[]]$Only = @())
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$Hdl = "$Repo/cores/rtlnet_h264_enc/hdl"
$Run = "$PSScriptRoot/h264_dbk_run.ps1"
$enc = New-Object System.Text.UTF8Encoding($false)
# name, file, old text, new text
$muts = @(
    @('alpha table entry', 'rtlnet_h264_deblock.sv', "6'd30: return 8'd25;", "6'd30: return 8'd26;"),
    @('alpha table, last entries', 'rtlnet_h264_deblock.sv', "6'd51: return 8'd255;", "6'd51: return 8'd254;"),
    @('beta table entry', 'rtlnet_h264_deblock.sv', "6'd38, 6'd39: return 5'd12;", "6'd38, 6'd39: return 5'd11;"),
    @('tC0 table entry', 'rtlnet_h264_deblock.sv', "6'd45: return {5'd13, 5'd8, 5'd6};", "6'd45: return {5'd13, 5'd8, 5'd7};"),
    @('tC0 table bS 1 column', 'rtlnet_h264_deblock.sv', "6'd40: return {5'd7, 5'd5, 5'd4};", "6'd40: return {5'd7, 5'd5, 5'd3};"),
    @('chroma QP table', 'rtlnet_h264_deblock.sv', "6'd44: return 6'd37;", "6'd44: return 6'd38;"),
    @('bS 3 for an internal intra edge', 'rtlnet_h264_deblock.sv', "return mbedge ? 3'd4 : 3'd3;", "return mbedge ? 3'd4 : 3'd2;"),
    @('bS 2 for coded levels', 'rtlnet_h264_deblock.sv', "if (nz_p || nz_q)       return 3'd2;", "if (nz_q)       return 3'd2;"),
    @('vector threshold 4 -> 5', 'rtlnet_h264_deblock.sv', "return ((dx >= 4) || (dx <= -4) || (dy >= 4) || (dy <= -4));", "return ((dx >= 5) || (dx <= -5) || (dy >= 4) || (dy <= -4));"),
    @('vector threshold 4 -> 3', 'rtlnet_h264_deblock.sv', "return ((dx >= 4) || (dx <= -4) || (dy >= 4) || (dy <= -4));", "return ((dx >= 4) || (dx <= -4) || (dy >= 3) || (dy <= -3));"),
    @('8x8 transform edge skip (vertical)', 'rtlnet_h264_deblock.sv', "(c_t8 ? (fc[3:2] == 2'd2) : 1'b1);", "1'b1;"),
    @('8x8 transform edge skip (horizontal)', 'rtlnet_h264_deblock.sv', "(c_t8 ? (fc[4:3] == 2'd2) : 1'b1);", "1'b1;"),
    @('top edge across a slice', 'rtlnet_h264_deblock.sv', "assign top_ok  = c_avt && (row_i != 8'd0);", "assign top_ok  = (row_i != 8'd0);"),
    @('I_PCM qP', 'rtlnet_h264_deblock.sv', "c_qp    <= mb_pcm ? 6'd0 : qp_p;", "c_qp    <= qp_p;"),
    @('offset scaling', 'rtlnet_h264_deblock.sv', "+ 2 * int'(off);", "+ int'(off);"),
    @('left block of the left edge', 'rtlnet_h264_deblock.sv', "nzp = p_nz[4 * qby + 3]; ip = p_intra; big = mvbig_l; end`r`n          else              begin nzp = c_nz[4 * qby + qbx - 1]; end", "nzp = p_nz[4 * qby + 2]; ip = p_intra; big = mvbig_l; end`r`n          else              begin nzp = c_nz[4 * qby + qbx - 1]; end"),
    @('chroma bS rows', 'rtlnet_h264_deblock.sv', "qbx = 2 * int'(d0.e);    qby = 2 * int'(d0.g) + h;", "qbx = 2 * int'(d0.e);    qby = 2 * int'(d0.g);"),
    @('late burst strobes', 'rtlnet_h264_deblock.sv', "(w_popped >= 6'd5) ? 16'hFFFF", "(w_popped >= 6'd4) ? 16'hFFFF"),
    @('main burst strobes', 'rtlnet_h264_deblock.sv', "(w_popped <= 6'd12) ? 16'hFFFF", "(w_popped <= 6'd13) ? 16'hFFFF"),
    @('retire of the previous macroblock', 'rtlnet_h264_deblock.sv', "assign ret_set = ret_cur ? cs : ~cs;", "assign ret_set = cs;"),
    @('line: strong filter limit', 'rtlnet_h264_dbk_line.sv', "((int'(alpha) >> 2) + 2)", "((int'(alpha) >> 2) + 1)"),
    @('line: chroma tC', 'rtlnet_h264_dbk_line.sv', "(int'(tc0) + 1) :", "(int'(tc0) + 0) :"),
    @('line: p1 correction', 'rtlnet_h264_dbk_line.sv', "(p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >>> 1);", "(p2 + ((p0 + q0) >> 1) - (p1 << 1)) >>> 1);"),
    @('line: bS 4 weak filter', 'rtlnet_h264_dbk_line.sv', "np[0] = 8'((2 * sp1 + sp0 + sq1 + 2) >> 2);`r`n        end`r`n        if (aql1", "np[0] = 8'((2 * sp1 + sp0 + sq1 + 1) >> 2);`r`n        end`r`n        if (aql1"),
    @('line: delta rounding', 'rtlnet_h264_dbk_line.sv', "(p1 - q1) + 4) >>> 3;", "(p1 - q1) + 3) >>> 3;")
)
$caught = 0
$total = 0
for ($i = 0; $i -lt $muts.Count; $i++) {
    if ($Only.Count -gt 0 -and $Only -notcontains $i) { continue }
    $m = $muts[$i]
    $dir = "$Repo/.sim/dbk/mutsrc$i"
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in 'rtlnet_h264_deblock.sv', 'rtlnet_h264_dbk_line.sv') { Copy-Item "$Hdl/$f" "$dir/$f" }
    $path = "$dir/$($m[1])"
    $txt = [System.IO.File]::ReadAllText($path)
    $old = $m[2]
    if ($txt.IndexOf($old) -lt 0) { $old = $old.Replace("`r`n", "`n"); $new = $m[3].Replace("`r`n", "`n") } else { $new = $m[3] }
    if ($txt.IndexOf($old) -lt 0) { Write-Output "MUTANT $i $($m[0]): pattern not found"; $total++; continue }
    $pos = $txt.IndexOf($old)
    $txt = $txt.Substring(0, $pos) + $new + $txt.Substring($pos + $old.Length)
    [System.IO.File]::WriteAllText($path, $txt, $enc)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Run -Sets $Sets -Rtl $dir -Tag "mut$i" 2>&1 | Out-String
    $total++
    if ($out -match 'TEST FAIL' -or $out -match 'build failed') { $caught++; Write-Output "MUTANT $i $($m[0]): caught" }
    else { Write-Output "MUTANT $i $($m[0]): MISSED" }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($caught -eq $total) { Write-Output "TEST PASS: h264_dbk_mutation ($caught of $total caught)"; exit 0 }
Write-Output "TEST FAIL: h264_dbk_mutation ($caught of $total caught)"
exit 1
