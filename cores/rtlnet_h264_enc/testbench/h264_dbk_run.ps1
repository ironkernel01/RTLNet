<#
-------------------------------------------------------------------------------
File: h264_dbk_run.ps1
Purpose: the module bench of the deblocking filter (tb_rtlnet_h264_dbk, Verilator) against the clause 8.7 model: generates random and directed
  vector sets (h264_dbk_vec.py), builds the bench once and runs every set with the compiled binary.
Overview:
  * Sets: kinds rand, mv (vectors that differ by 0..8 quarter samples: bS 0 below 4, bS 1 from 4), intra, t8 (8x8 transform macroblocks), slices
    (several slices: no filtering across a slice boundary), filter off, picture sizes from one macroblock to 12 x 9, every QP range, random slice
    offsets -6..+6; random handshakes of the write master and random pauses between macroblocks (+GAP).
  * Prints `TEST PASS: tb_rtlnet_h264_dbk (<n> sets)` when every set passes. -Inject runs the negative control (+INJECT_FAILURE must fail).
    -Mutation <name> is used by h264_dbk_mutation.ps1 (the bench is built from a mutated copy of the RTL).
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_dbk_run.ps1 [-Sets 60] [-Inject] [-Rtl <directory with the two RTL files>]
Revision: 11-12-2026
-------------------------------------------------------------------------------
#>
param(
    [int]$Sets = 60,
    [switch]$Inject,
    [string]$Rtl = '',
    [string]$Tag = 'dbkrun'
)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Py = Resolve-RtlnetPython
$Vl = Resolve-RtlnetVerilator
$Tb = "$Repo/cores/rtlnet_h264_enc/testbench"
$work = $Repo.Replace([string][char]92, "/") + "/.sim/dbk/$Tag"
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

# The set list: (kind, mbw, mbh, seed, extra generator arguments)
$list = @()
$kinds = @('rand', 'mv', 'intra', 't8', 'slices', 'step')
$sizes = @(@(1, 1), @(2, 1), @(1, 3), @(3, 2), @(5, 4), @(6, 3), @(12, 9), @(4, 5))
for ($i = 0; $i -lt $Sets; $i++) {
    $k = $kinds[$i % $kinds.Count]
    $sz = $sizes[[int]([math]::Floor($i / 2)) % $sizes.Count]
    $x = @()
    if ($i % 11 -eq 5) { $x += @('--en', '0') }
    if ($i % 7 -eq 3) { $x += @('--qp', "$((16 + 3 * $i) % 52)") }
    $list += ,@($k, $sz[0], $sz[1], (100 + $i), $x)
}
# One pair of sets per QP from 16 to 51 with zero offsets (every table entry is the entry of indexA = QP for luma; the chroma QP table covers the same range):
# inter macroblocks with levels and vector differences (bS 1 and 2) and intra macroblocks (bS 3 and 4).
for ($q = 16; $q -le 51; $q++) {
    $list += ,@('mv', 3, 2, (500 + $q), @('--qp', "$q", '--aoff', '0', '--boff', '0'))
    $list += ,@('rand', 3, 2, (600 + $q), @('--qp', "$q", '--aoff', '0', '--boff', '0'))
}
# Steps of up to 255 between flat blocks at the largest alpha and beta (indexA 51).
for ($k = 0; $k -lt 8; $k++) { $list += ,@('step', 3, 2, (700 + $k), @()) }
$pa0 = $null
$simExe = $null
$pass = 0
$fail = 0
$n = 0
foreach ($c in $list) {
    $pre = "$work/s$n"
    $gen = & $Py -I "$Tb/h264_dbk_vec.py" --out $pre --kind $c[0] --mbw $c[1] --mbh $c[2] --seed $c[3] @($c[4])
    if ($LASTEXITCODE -ne 0) { throw "vector generation failed: $gen" }
    $gap = @(0, 0, 40, 300)[$n % 4]
    $pa = @("VEC=$pre", "SEED=$($n + 1)", "GAP=$gap")
    if ($Inject) { $pa += 'INJECT_FAILURE' }
    if ($null -eq $simExe) {
        $fl = 'cores/rtlnet_h264_enc/testbench/tb_rtlnet_h264_dbk.f'
        if ($Rtl -ne '') {
            # a filelist that takes the two RTL files from the given directory
            $fl = "$work/tb.f"
            $txt = (Get-Content -LiteralPath "$Tb/tb_rtlnet_h264_dbk.f" -Raw) -replace 'cores/rtlnet_h264_enc/hdl/', ($Rtl.Replace('\', '/').TrimEnd('/') + '/')
            [System.IO.File]::WriteAllText($fl, $txt)
        }
        $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Repo/scripts/rtlnet_run_verilator.ps1" -Bench tb_rtlnet_h264_dbk -Filelist $fl -Tag $Tag -PlusArgs ($pa -join ',') $(if ($Inject) { '-ExpectFail' })
        $simExe = "$Repo/.sim/verilator/tb_rtlnet_h264_dbk_$Tag/obj/simv.exe"
        $log = Get-Content -LiteralPath "$Repo/.sim/verilator/tb_rtlnet_h264_dbk_$Tag/run.log" -Raw -ErrorAction SilentlyContinue
        $ok = ($log -match 'TEST PASS')
        if ($Inject) { $ok = ($log -match 'TEST FAIL') }
        if (-not (Test-Path -LiteralPath $simExe)) { Write-Output "build failed: $o"; exit 1 }
    } else {
        $env:PATH = "$($Vl.Root)/ucrt64/bin;$env:PATH"
        $log = (& $simExe ($pa | ForEach-Object { "+$_" }) 2>&1 | Out-String)
        $ok = ($log -match 'TEST PASS')
        if ($Inject) { $ok = ($log -match 'TEST FAIL') }
    }
    $beats = [regex]::Match($log, 'NOTE: [^\r\n]*').Value
    if ($ok) { $pass++ } else { $fail++; Write-Output "FAIL set $n ($($c[0]) $($c[1])x$($c[2]) seed $($c[3])): $gen"; ($log -split "`n" | Select-String 'ERROR|mismatch|FAIL' | Select-Object -First 4) | ForEach-Object { Write-Output "  $_" } }
    if ($n -lt 3 -or -not $ok) { Write-Output "set ${n}: $gen | $beats" }
    $n++
}
# Disk rule: the object tree of the bench build and the vector files go when the run is over.
Remove-Item -LiteralPath "$Repo/.sim/verilator/tb_rtlnet_h264_dbk_$Tag/obj" -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $work -Filter *.hex -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
if ($Inject) {
    if ($fail -eq 0 -and $pass -eq $n) { Write-Output "TEST PASS: tb_rtlnet_h264_dbk_neg (negative control: $n of $n sets failed as required)"; exit 0 }
    Write-Output 'TEST FAIL: tb_rtlnet_h264_dbk_neg'; exit 1
}
if ($fail -eq 0) { Write-Output "TEST PASS: tb_rtlnet_h264_dbk ($n sets)"; exit 0 }
Write-Output "TEST FAIL: tb_rtlnet_h264_dbk ($fail of $n sets failed)"
exit 1
