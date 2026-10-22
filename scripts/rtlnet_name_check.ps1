<#
-------------------------------------------------------------------------------
File: rtlnet_name_check.ps1
Purpose: release gate for the RTLNet naming rule: no tracked file may name
  another company or carry identifiers from earlier designs.
Overview:
  * The patterns are kept OUTSIDE the repository, one case-insensitive regular
    expression per line, in %LOCALAPPDATA%/RTLNet/forbidden_names.txt (the list
    itself must not appear in RTLNet sources). A missing or empty list fails.
  * Scans every file tracked by git (plus staged new files) and prints each hit
    as path:line. Exit 0 when clean, 1 on any hit or a missing list.
Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/rtlnet_name_check.ps1
Revision: 10-22-2026
  * 10-22-2026: initial version.
-------------------------------------------------------------------------------
#>
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ListPath = Join-Path $env:LOCALAPPDATA 'RTLNet/forbidden_names.txt'
if (-not (Test-Path -LiteralPath $ListPath)) { Write-Output "RTLNET_NAMES: FAIL pattern list missing ($ListPath)"; exit 1 }
$patterns = @(Get-Content -LiteralPath $ListPath | Where-Object { $_.Trim() -ne '' })
if ($patterns.Count -eq 0) { Write-Output 'RTLNET_NAMES: FAIL pattern list empty'; exit 1 }
$rx = [regex]::new('(' + ($patterns -join '|') + ')', 'IgnoreCase')
Push-Location $Repo
try {
    $files = @(git ls-files --cached --others --exclude-standard)
} finally { Pop-Location }
$hits = 0
foreach ($f in $files) {
    $p = Join-Path $Repo $f
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
    $n = 0
    foreach ($line in [System.IO.File]::ReadLines($p)) {
        $n++
        if ($rx.IsMatch($line)) { Write-Output ("{0}:{1}" -f $f, $n); $hits++ }
    }
    if ($rx.IsMatch($f)) { Write-Output ("{0}: (file name)" -f $f); $hits++ }
}
if ($hits -gt 0) { Write-Output "RTLNET_NAMES: FAIL $hits hit(s)"; exit 1 }
Write-Output ("RTLNET_NAMES: PASS {0} files" -f $files.Count)
exit 0
