<#
-------------------------------------------------------------------------------
File: rtlnet_regression.ps1
Purpose: run every bench listed in scripts/rtlnet_regression.txt and in each
  core's cores/<core>/testbench/regression.txt and, when the folders exist, in every regression.txt under
  cpu/ (every cpu/<cpu>/) and boards/ (same line format) through
  rtlnet_run_sim.ps1, sequentially (one Active-HDL seat), and fail if any
  bench fails.
  A line may carry the token sim=verilator (run through rtlnet_run_verilator.ps1 instead of Active-HDL) and
  threads=N (Verilator --threads N). A line whose second field is script:<path> runs that host script with the
  remaining fields as arguments and passes on exit code 0 (decoder harness, driver host test).
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1 [-Match <regex>]
Revision: 11-14-2026
  * 11-14-2026: the optional root is cpu/ (one folder per CPU, every cpu/<cpu>/ regression.txt is collected); was microblaze/.
  * 11-13-2026: cpu/ and boards/ are optional folders, so that the regression of the cores runs without them.
  * 11-09-2026: sim=verilator and threads=N tokens (rtlnet_run_verilator.ps1).
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
param([string]$Match = '.')
$ErrorActionPreference = 'Stop'
$Repo   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Runner = Join-Path $PSScriptRoot 'rtlnet_run_sim.ps1'
$VlRunner = Join-Path $PSScriptRoot 'rtlnet_run_verilator.ps1'
$list   = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'rtlnet_regression.txt'))
# cores/ always; cpu/ and boards/ only on the branches that have them.
$roots = @('cores', 'cpu', 'boards') | ForEach-Object { Join-Path $Repo $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
foreach ($f in (Get-ChildItem -Path $roots -Recurse -Filter regression.txt | Sort-Object FullName)) {
    $list += Get-Content -LiteralPath $f.FullName
}
$pass = 0; $fail = 0; $failed = @()
foreach ($raw in $list) {
    $line = ($raw -replace '#.*$', '').Trim()
    if (-not $line) { continue }
    $tok = $line -split '\s+'
    $bench = $tok[0]; $fl = $tok[1]
    if ("$bench $line" -notmatch $Match) { continue }
    if ($fl -like 'script:*') {
        # A host script entry (decoder harness, driver test): <name> script:<path> [arguments...]; passes on exit code 0.
        $scriptPath = $fl.Substring(7)
        $scriptArgs = @(); if ($tok.Count -gt 2) { $scriptArgs = $tok[2..($tok.Count - 1)] }
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo $scriptPath) @scriptArgs
        $out | Select-Object -Last 1 | Write-Output
        if ($LASTEXITCODE -eq 0) { $pass++ } else { $fail++; $failed += $line }
        continue
    }
    $useVl = ($tok -contains 'sim=verilator')
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $(if ($useVl) { $VlRunner } else { $Runner }), '-Bench', $bench, '-Filelist', $fl)
    foreach ($t in $tok[2..($tok.Count - 1)]) {
        if (-not $t) { continue }
        if ($t -eq 'sim=verilator') { continue }
        if ($t -like 'threads=*')   { $runArgs += @('-Threads', ($t.Substring(8))); continue }
        if ($t -like 'defines=*')      { $runArgs += @('-Defines', ($t.Substring(8))) }
        elseif ($t -like 'plusargs=*') { $runArgs += @('-PlusArgs', ($t.Substring(9))) }
        elseif ($t -eq 'expectfail')   { $runArgs += '-ExpectFail' }
        elseif ($t -ne $fl)            { $runArgs += @('-Tag', $t) }
    }
    $out = & powershell.exe @runArgs
    $out | Select-Object -Last 1 | Write-Output
    if ($LASTEXITCODE -eq 0) { $pass++ } else { $fail++; $failed += "$bench $($tok[2..($tok.Count-1)] -join ' ')" }
}
Write-Output ("RTLNET_REGRESSION: {0} passed, {1} failed" -f $pass, $fail)
foreach ($f in $failed) { Write-Output "  FAILED: $f" }
if ($fail -ne 0 -or $pass -eq 0) { exit 1 }
exit 0
