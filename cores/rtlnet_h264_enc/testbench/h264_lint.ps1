<#
-------------------------------------------------------------------------------
File: h264_lint.ps1
Purpose: lint gate of the rtlnet_h264_top RTL: `verilator --lint-only -Wall` on the synthesizable sources
  (cores/rtlnet_h264_enc/hdl, not the benches), plus the reset-policy text scan of fpga.md section 16: no
  asynchronous reset or multi-edge sensitivity list in the core's RTL.
Overview:
  * Verilator and MSYS2 come from Resolve-RtlnetVerilator (rtlnet_tools.ps1). The shared rtlnet_common sources compile
    as dependencies; their own warnings are not part of this gate (only lines naming rtlnet_h264_* count).
  * Passes with zero warnings in the core's files; a warning is either fixed or waived at its declaration with a narrow
    `/* verilator lint_off <RULE> */` / `lint_on` pair and a reason comment.
  * Prints `LINT PASS: rtlnet_h264_top` or `LINT FAIL: ...` and exits 0 / 1.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File h264_lint.ps1
Revision: 11-11-2026
  * 11-09-2026: initial version.
  * 11-11-2026: nested -f filelists are expanded.
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $Repo 'scripts/rtlnet_tools.ps1')
$Vl = Resolve-RtlnetVerilator
$work = Join-Path $Repo '.sim/lint'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$lines = @()
function Add-ListLines([string]$f) {
    foreach ($raw in Get-Content -LiteralPath (Join-Path $Repo $f)) {
        $l = ($raw -replace '#.*$', '').Trim()
        if ($l -match '^-f\s+(.+)$') { Add-ListLines $Matches[1].Trim() }
        elseif ($l -and ($l -notlike '+incdir*')) { $script:lines += $l }
    }
}
foreach ($f in @('cores/rtlnet_common/hdl/rtlnet_common.f', 'cores/rtlnet_h264_enc/hdl/rtlnet_h264_enc.f')) { Add-ListLines $f }
$files = ($lines | Select-Object -Unique) -join ' '
$drive = $Repo.Substring(0, 1).ToLower()
$msysRepo = '/' + $drive + '/' + ($Repo.Substring(3).Replace([string][char]92, '/'))
$sh = @('#!/bin/bash', 'export MSYSTEM=UCRT64', 'export PATH=/ucrt64/bin:/usr/bin:/bin', "cd $msysRepo",
        "verilator --lint-only -Wall --top-module rtlnet_h264_top -Icores/rtlnet_common/hdl +incdir+cores/rtlnet_common/hdl +define+RTLNET_TECH_GENERIC $files > .sim/lint/h264_lint.txt 2>&1",
        'exit 0')
[System.IO.File]::WriteAllText((Join-Path $work 'h264_lint.sh'), (($sh -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
& $Vl.Bash (($work.Replace([string][char]92, '/')) + '/h264_lint.sh')
$out = Get-Content -LiteralPath (Join-Path $work 'h264_lint.txt')
$hits = @($out | Where-Object { $_ -match '^%(Warning|Error)' -and $_ -match 'rtlnet_h264' })
$fatal = @($out | Where-Object { $_ -match '^%Error' -and $_ -notmatch 'Exiting due to' })
# Reset-policy scan: asynchronous reset or edge lists with more than one edge in the core's RTL.
$scan = @()
foreach ($f in Get-ChildItem (Join-Path $Repo 'cores/rtlnet_h264_enc/hdl') -Filter *.sv) {
    $n = 0
    foreach ($l in Get-Content -LiteralPath $f.FullName) {
        $n++
        if ($l -match '^\s*always(_ff)?\s*@\s*\(.*(posedge|negedge).*(or|,).*(posedge|negedge)') { $scan += "$($f.Name):$n $l" }
    }
}
if ($fatal.Count -gt 0 -or $hits.Count -gt 0 -or $scan.Count -gt 0) {
    $hits + $fatal + $scan | ForEach-Object { Write-Output $_ }
    Write-Output "LINT FAIL: rtlnet_h264_top ($($hits.Count) warning(s), $($scan.Count) reset-policy hit(s))"
    exit 1
}
Write-Output 'LINT PASS: rtlnet_h264_top (verilator --lint-only -Wall, 0 warnings in rtlnet_h264_*, no multi-edge sensitivity)'
exit 0
