<#
-------------------------------------------------------------------------------
File: rtlnet_regression.ps1
Purpose: run every bench in scripts/rtlnet_regression.txt through
  rtlnet_run_sim.ps1, sequentially (one Active-HDL seat), and fail if any
  bench fails.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_regression.ps1 [-Match <regex>]
Revision: 10-22-2026
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
param([string]$Match = '.')
$ErrorActionPreference = 'Stop'
$Repo   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Runner = Join-Path $PSScriptRoot 'rtlnet_run_sim.ps1'
$list   = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'rtlnet_regression.txt')
$pass = 0; $fail = 0; $failed = @()
foreach ($raw in $list) {
    $line = ($raw -replace '#.*$', '').Trim()
    if (-not $line) { continue }
    $tok = $line -split '\s+'
    $bench = $tok[0]; $fl = $tok[1]
    if ("$bench $line" -notmatch $Match) { continue }
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Runner, '-Bench', $bench, '-Filelist', $fl)
    foreach ($t in $tok[2..($tok.Count - 1)]) {
        if (-not $t) { continue }
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
